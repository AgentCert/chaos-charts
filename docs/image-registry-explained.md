# How Litmus Chaos Images Work — and What Image Registry Actually Patches

When you run a chaos experiment in Litmus, it is not one pod pulling one image. It is a **chain of five different Kubernetes entities**, each pulling a different image for a different purpose. The Image Registry UI in Litmus only touches three of those images — and in ACE's case, even that has a catch.

This document explains what each image does, where it appears in the YAML, and exactly what the registry setting changes.

---

## The five-layer execution chain

When you trigger a chaos workflow (for example, `pod-cpu-hog` on the sock-shop `carts` deployment), this is what Kubernetes actually runs:

```
Argo Workflow (Argo Controller)
│
├── Step: install-chaos-faults
│   └── Pod: litmuschaos/k8s:latest
│       Applies ChaosExperiment CRDs to the cluster via kubectl
│
├── Step: pod-cpu-hog
│   └── Pod: litmuschaos/litmus-checker:latest
│       Applies ChaosEngine CR, then polls until complete
│
│       └── [Litmus Chaos Operator watches ChaosEngine]
│           └── Pod: go-runner   ← THE CHAOS RUNNER
│               Reads the ChaosExperiment definition
│               Injects the fault
│               │
│               └── Helper Pod: stress-ng  ← INSIDE the target namespace
│                   Actually writes to /dev/zero to consume CPU/memory
```

Five distinct images. Four distinct image control points. The Litmus UI Image Registry only controls the bottom two.

---

## Image 1: `litmuschaos/k8s:latest` — the kubectl runner

**What it does:**
This is just an Alpine container with `kubectl` baked in. When the Argo Workflow reaches the `install-chaos-faults` step, it runs this image as a pod and uses `kubectl apply` to push the `ChaosExperiment` custom resource definitions into the cluster.

**Where in ACE:**
```yaml
# chaos-charts/experiments/sock-shop/experiment.yaml, line 784
- name: install-chaos-faults
  container:
    image: litmuschaos/k8s:latest     # ← this image
    command: [sh, -c]
    args:
      - kubectl apply -f /tmp/pod-cpu-hog-2sf.yaml ...
```

**Is this patched by the UI Image Registry?** No. It is hardcoded in the Argo Workflow template.

---

## Image 2: `litmuschaos/litmus-checker:latest` — the ChaosEngine applier

**What it does:**
After the ChaosExperiment definition is in the cluster, each fault step runs `litmus-checker`. This image applies the `ChaosEngine` CR (which tells Litmus _which_ app to target and _which_ experiment to run) and then polls `chaosresult` until the engine finishes.

**Where in ACE:**
```yaml
# chaos-charts/experiments/sock-shop/experiment.yaml, line 862
- name: pod-cpu-hog
  container:
    image: litmuschaos/litmus-checker:latest   # ← this image
    args: ["-file=/tmp/chaosengine.yaml", "-saveName=/tmp/engine-name"]
```

**Is this patched by the UI Image Registry?** No. Also hardcoded in the Argo Workflow template.

---

## Image 3: `go-runner` — the chaos executor

**Full image name:** `litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest`

**What it does:**
This is the actual fault injection engine. The Litmus Chaos Operator (already running in your cluster) watches for `ChaosEngine` resources. When it sees one, it reads the referenced `ChaosExperiment` CR, finds the `spec.definition.image` field, and spawns a Kubernetes **Job** using that image.

The `go-runner` binary inside the pod runs the experiment logic: it identifies the target pods, kills them, or spins up helper pods to inject stress.

**Where in the ChaosExperiment CR:**
```yaml
# This CR is embedded as raw.data inside the Argo Workflow
kind: ChaosExperiment
metadata:
  name: pod-cpu-hog
spec:
  definition:
    image: "litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest"  # ← POD IMAGE
    imagePullPolicy: Always
    args:
      - -c
      - ./experiments -name pod-cpu-hog    # ← the binary inside go-runner
    command:
      - /bin/bash
    env:
      - name: LIB_IMAGE
        value: "litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest"  # ← also go-runner
```

Notice two things:
- `spec.definition.image` — the image the Chaos Operator uses to launch the runner Job
- `LIB_IMAGE` env var — tells go-runner which image to use when it needs to spawn a helper pod that also runs go-runner logic (used for some fault variants)

**Is this patched by the UI Image Registry?** Yes — but only under specific conditions (see caveat below).

---

## Image 4: `stress-ng` — the actual CPU/memory injector

**Full image name:** `alexeiled/stress-ng:latest-ubuntu`

**What it does:**
`go-runner` does not directly consume CPU or memory in the target pod. It spawns a **separate helper pod** inside the target namespace using the `stress-ng` image. That pod runs `stress-ng` — a Linux stress testing tool — which writes to `/dev/zero` to consume CPU cycles or allocate memory.

`go-runner` knows which image to use for this helper pod because of the `STRESS_IMAGE` env var in the ChaosExperiment definition.

**Where in the ChaosExperiment CR:**
```yaml
env:
  - name: STRESS_IMAGE
    value: "alexeiled/stress-ng:latest-ubuntu"   # ← go-runner reads this at runtime
                                                 #   to decide which helper image to pull
```

**Is this patched by the UI Image Registry?** Yes — the UI rewrites this env var value.

---

## Image 5: `iproute2` — the network traffic manipulator

**Full image name:** `gaiadocker/iproute2`

**What it does:**
For network faults (`pod-network-latency`, `pod-network-loss`), `go-runner` spawns a helper pod using `iproute2`. That pod runs the Linux `tc` (traffic control) command to manipulate the target pod's network interface — adding artificial latency, packet loss, or corruption via Linux kernel netem queuing disciplines.

**Where in the ChaosExperiment CR:**
```yaml
# network-latency ChaosExperiment
env:
  - name: TC_IMAGE
    value: "gaiadocker/iproute2"   # ← go-runner reads this to pick the helper image
```

**Is this patched by the UI Image Registry?** Yes — the UI rewrites this env var value.

---

## What the Litmus Image Registry UI actually patches

When you configure a custom registry in **Project Setup → Image Registry**, Litmus stores your `registry/repo` prefix and applies it when resolving ChaosExperiment definitions. It modifies:

| Field | Before | After |
|---|---|---|
| `spec.definition.image` | `litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest` | `your-corp.jfrog.io/ace/go-runner:latest` |
| `LIB_IMAGE` env var | `litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest` | `your-corp.jfrog.io/ace/go-runner:latest` |
| `STRESS_IMAGE` env var | `alexeiled/stress-ng:latest-ubuntu` | `your-corp.jfrog.io/ace/stress-ng:latest-ubuntu` |
| `TC_IMAGE` env var | `gaiadocker/iproute2` | `your-corp.jfrog.io/ace/iproute2` |

It does **not** touch:
- `litmuschaos/k8s` (the kubectl runner image)
- `litmuschaos/litmus-checker` (the ChaosEngine applier)
- The Litmus portal images themselves
- Any ACE stack images (graphql, auth, certifier, etc.)
- Any sock-shop images

---

## The ACE-specific caveat — inline YAML

The Litmus Image Registry patch works when Litmus pulls a ChaosExperiment definition from a **ChaosHub** at experiment execution time. At that point it rewrites the image fields before applying the CR to the cluster.

In ACE, however, the ChaosExperiment definitions are **not** pulled from a ChaosHub at runtime. They are embedded inline as `raw.data` artifacts directly inside the Argo Workflow YAML:

```yaml
# chaos-charts/experiments/sock-shop/experiment.yaml
- name: install-chaos-faults
  inputs:
    artifacts:
      - name: pod-cpu-hog-2sf
        path: /tmp/pod-cpu-hog-2sf.yaml
        raw:
          data: |                            # ← the entire ChaosExperiment is
            apiVersion: litmuschaos.io/v1alpha1  #   hardcoded here as a string
            kind: ChaosExperiment
            spec:
              definition:
                image: "litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest"
                env:
                  - name: STRESS_IMAGE
                    value: "alexeiled/stress-ng:latest-ubuntu"
```

The Argo Workflow runner extracts this string, writes it to disk, and `kubectl apply`s it. The Litmus server never intercepts it to apply the registry rewrite. The image names are baked into the file.

**Consequence:** For ACE, the Image Registry UI setting alone is not sufficient. You also need to update the image references directly in `chaos-charts/experiments/sock-shop/experiment.yaml` (and the parallel, sequential, and single variants) before running experiments in a proxy environment.

---

## Summary: what to change for a proxy environment

| Image | Where to change it | Mechanism |
|---|---|---|
| `go-runner` | `chaos-charts/experiments/*/experiment.yaml` — `spec.definition.image` + `LIB_IMAGE` | Edit file directly or fork + sed |
| `stress-ng` | `chaos-charts/experiments/*/experiment.yaml` — `STRESS_IMAGE` | Edit file directly or fork + sed |
| `iproute2` | `chaos-charts/experiments/*/experiment.yaml` — `TC_IMAGE` | Edit file directly or fork + sed |
| `litmuschaos/k8s` | `chaos-charts/experiments/*/experiment.yaml` — `install-chaos-faults` step container | Edit file directly |
| `litmuschaos/litmus-checker` | `chaos-charts/experiments/*/experiment.yaml` — each fault step container | Edit file directly |
| All ACE stack images | `deploy/helm/ace/values-registry.yaml` | Helm `-f` override |
| All sock-shop images | `app-charts/charts/sock-shop/values-registry.yaml` | Helm `-f` override |
| Litmus portal images | `AgentCert/chaoscenter/manifests/litmus-installation.yaml` | sed before `kubectl apply` |

The Litmus UI Image Registry is still worth configuring for any experiments you import and run via the Litmus Chaos Experiments UI (not the Argo Workflow path). For the Argo-based workflow path that ACE uses, the YAML files are the ground truth.
