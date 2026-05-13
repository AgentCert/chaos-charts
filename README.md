<div align="center">

# chaos-charts (AgentCert fork)

**The fault catalogue and scenario workflows that AgentCert ChaosCenter pulls from.**

A fork of [`litmuschaos/chaos-charts`](https://github.com/litmuschaos/chaos-charts) that
preserves the upstream Kubernetes chaos primitives (pod-delete, node-restart, network
corruption, disk-fill, etc.) and extends them with **AgentCert-specific scenarios** —
agent install/uninstall faults, OpenAI/LiteLLM/Langfuse parameters baked into every
experiment, and Argo workflows for the Sock Shop benchmark.

![Litmus](https://img.shields.io/badge/LitmusChaos-3.0.0-7E47C5?style=flat-square)
![Argo](https://img.shields.io/badge/Argo-Workflows-EF7B4D?style=flat-square)
![Kubernetes](https://img.shields.io/badge/Kubernetes-CRD-326CE5?style=flat-square&logo=kubernetes)
![License](https://img.shields.io/badge/License-Apache--2.0-lightgrey?style=flat-square)

</div>

> **Upstream credit** — this repository is derived from
> [LitmusChaos](https://litmuschaos.io/)'s `chaos-charts`. The individual fault
> implementations and CRD shapes are the work of the LitmusChaos community. AgentCert
> additions are described below.

---

## Table of Contents

- [What's a Chaos Chart?](#whats-a-chaos-chart)
- [What's AgentCert-specific in this fork](#whats-agentcert-specific-in-this-fork)
- [Repository layout](#repository-layout)
- [Kubernetes chaos fault inventory](#kubernetes-chaos-fault-inventory)
- [Scenario workflows](#scenario-workflows)
- [Building the aggregated `experiments.yaml`](#building-the-aggregated-experimentsyaml)
- [How AgentCert consumes this](#how-agentcert-consumes-this)
- [Installing faults directly (without ChaosCenter)](#installing-faults-directly-without-chaoscenter)
- [Security artifacts](#security-artifacts)
- [Licensing](#licensing)

---

## What's a Chaos Chart?

A *Chaos Chart* is a directory tree that ships, for each chaos fault, the YAML you need
to run it on a Kubernetes cluster:

```
faults/kubernetes/<fault-name>/
├── fault.yaml                  # ChaosExperiment CRD (litmuschaos.io/v1alpha1)
├── engine.yaml                 # ChaosEngine binding the experiment to a target
├── chartserviceversion.yaml    # Metadata (description, category, image, version)
└── ground_truth.yaml           # (optional) baseline / expected post-conditions
```

The catalogue is consumed by **ChaosCenter** as a Git-backed *ChaosHub* — the UI
browses the directory tree, the operator picks a fault, and the platform installs the
ChaosExperiment CRD into the cluster.

---

## What's AgentCert-specific in this fork

The upstream chart catalogue is preserved verbatim where possible; the differences are:

1. **Agent lifecycle faults** under `faults/kubernetes/`:
   - `install-agent` — runs the [`agent-charts/install-agent`](../agent-charts/install-agent)
     installer image as part of an Argo workflow step.
   - `install-application` — runs [`app-charts/install-app`](../app-charts/install-app).
   - `uninstall-agent`, `uninstall-application` — teardown counterparts.

2. **OpenAI / LiteLLM / Langfuse parameters** plumbed through every experiment that
   touches an agent. Defaults:
   - `openaiBaseUrl: http://litellm.litellm.svc.cluster.local:4000/v1`
   - `openaiModel`, `openaiApiKey`, `litellmUpstream`, `otelEndpoint` are surfaced as
     experiment env vars so agents installed by the workflow inherit them.

3. **Sock Shop scenarios** under `experiments/`:
   - `sock-shop/` — full resiliency test: `install-app → install-agent → load-test →
     pod-delete + cpu-hog + memory-hog + network-loss + disk-fill` in parallel.
   - `sock-shop-single/` — minimal: `pod-delete` only, 900 s duration.
   - `sock-shop-parallel/`, `sock-shop-sequential/` — same fault set, different
     scheduling strategy.

4. **OTEL tracing** — workflow steps emit Langfuse-compatible spans for the certifier.

Everything else (CRDs, RBAC, Kyverno policies) tracks upstream.

---

## Repository layout

```
chaos-charts/
├── faults/kubernetes/                # 36 fault definitions (one directory each)
│   ├── pod-delete/, pod-cpu-hog/, pod-memory-hog/, pod-io-stress/
│   ├── pod-network-latency/, pod-network-loss/, pod-network-corruption/
│   ├── pod-network-duplication/, pod-network-partition/, pod-network-rate-limit/
│   ├── pod-dns-error/, pod-dns-spoof/
│   ├── pod-http-latency/, pod-http-modify-body/, pod-http-modify-header/,
│   │   pod-http-reset-peer/, pod-http-status-code/
│   ├── pod-autoscaler/, container-kill/, disk-fill/
│   ├── node-cpu-hog/, node-drain/, node-io-stress/, node-memory-hog/,
│   │   node-poweroff/, node-restart/, node-taint/
│   ├── kubelet-service-kill/, docker-service-kill/
│   └── install-agent/, install-application/,
│       uninstall-agent/, uninstall-application/    ← AgentCert-specific
│
├── experiments/                      # Argo workflow templates (AgentCert-specific)
│   ├── sock-shop/                    # full resiliency test
│   ├── sock-shop-single/             # pod-delete only
│   ├── sock-shop-parallel/           # parallel fault injection
│   └── sock-shop-sequential/         # sequential fault injection
│
├── crds/                             # ChaosExperiment CRD definition
│   └── chaosexperiment_crd.yaml
│
├── scripts/
│   ├── combine-all-crs.go            # aggregates fault.yaml → experiments.yaml
│   └── version/
│       ├── version_maker.sh
│       ├── version_validator.py
│       └── push.sh                   # CI auto-bump + push
│
├── monitoring/
│   └── dashboards/litmus-portal/     # Grafana dashboards for the chaos runner
│
├── security/
│   ├── kyverno-policies/             # 6 ClusterPolicy YAMLs (privesc, host-ns, caps, …)
│   └── pod-security-policy/
│       └── psp-litmus.yaml
│
├── service-accounts/
│   ├── argo-access.yaml              # ServiceAccount + Role for Argo
│   ├── argowf-chaos-admin.yaml       # Elevated RBAC for Argo chaos workflows
│   └── litmus-admin-rbac.yaml        # ServiceAccount + ClusterRole for Litmus operator
│
├── CONTRIBUTING.md
├── Makefile
├── LICENSE                           # Apache-2.0 (upstream)
└── README.md
```

---

## Kubernetes chaos fault inventory

| Category | Faults |
|---|---|
| **Pod resource** | `pod-cpu-hog`, `pod-cpu-hog-exec`, `pod-memory-hog`, `pod-memory-hog-exec`, `pod-io-stress`, `disk-fill`, `container-kill` |
| **Pod network** | `pod-network-latency`, `pod-network-loss`, `pod-network-corruption`, `pod-network-duplication`, `pod-network-partition`, `pod-network-rate-limit` |
| **Pod HTTP/DNS** | `pod-http-latency`, `pod-http-modify-body`, `pod-http-modify-header`, `pod-http-reset-peer`, `pod-http-status-code`, `pod-dns-error`, `pod-dns-spoof` |
| **Pod lifecycle** | `pod-delete`, `pod-autoscaler` |
| **Node** | `node-cpu-hog`, `node-drain`, `node-io-stress`, `node-memory-hog`, `node-poweroff`, `node-restart`, `node-taint` |
| **K8s management** | `kubelet-service-kill`, `docker-service-kill` |
| **AgentCert lifecycle** | `install-agent`, `install-application`, `uninstall-agent`, `uninstall-application` |

The fault list maps directly to the categories the [`certifier`](../certifier) reports
on — `application_fault`, `network_fault`, `resource_fault` — defined in
[`certifier/configs/fault_categories.json`](../certifier/configs/fault_categories.json).

---

## Scenario workflows

Each scenario in `experiments/` is an **Argo Workflow** (`apiVersion: argoproj.io/v1alpha1`)
that strings together the install/load/inject/observe steps a benchmark needs:

```
install-app (sock-shop)
    │
    ▼
install-agent (flash-agent + sidecar)
    │
    ▼
load-test  (warm the SUT)
    │
    ▼
┌──── pod-delete ────┐
├──── pod-cpu-hog ──┤    ← parallel (sock-shop) or sequential (sock-shop-sequential)
├──── pod-memory-hog┤
├── pod-network-loss┤
└──── disk-fill ────┘
    │
    ▼
uninstall-agent + uninstall-app
```

The workflows reference the installer images directly:

```yaml
- name: install-agent
  image: agentcert/agentcert-install-agent:latest
  args: ["--folder=flash-agent", "--namespace=flash-agent", "--create-namespace"]
```

---

## Building the aggregated `experiments.yaml`

The Makefile aggregates the per-fault `fault.yaml` files into one
`faults/kubernetes/experiments.yaml` multi-document file — the shape ChaosCenter installs
in a single `kubectl apply`.

```bash
make deps              # pip install packaging (used by version_validator.py)
make versionmaker      # extracts version metadata from each chartserviceversion.yaml
make combineExpCR      # runs scripts/combine-all-crs.go
                       # → faults/kubernetes/experiments.yaml (deduplicated by CRD name)
make push              # auto-increment versions + git push (CI)
```

There is no chart packaging step: the Git repository **is** the distribution. Releases
are consumed as source tarballs.

---

## How AgentCert consumes this

ChaosCenter is configured with this repo as the default ChaosHub via
`DEFAULT_HUB_GIT_URL=https://github.com/agentcert/chaos-charts`. When a user clicks
*Browse Hub* in the UI, the GraphQL server clones the repo, walks
`faults/kubernetes/`, and renders each fault as a card. Selecting a fault stages its
`fault.yaml` for inclusion in the next scenario.

The chaoscenter side of this contract is documented in
[`AgentCert/docs/EXPERIMENT_E2E_FLOW.md`](../AgentCert/docs/EXPERIMENT_E2E_FLOW.md) and
in the integration tests under
`AgentCert/chaoscenter/graphql/server/pkg/chaos_hub/`.

---

## Installing faults directly (without ChaosCenter)

The upstream `chaos-charts` install recipe still works (no release tags are cut on this
fork yet — use `master`):

```bash
# Clone and apply the aggregated kubernetes chart in the sock-shop namespace
git clone https://github.com/AgentCert/chaos-charts.git
find chaos-charts/faults/kubernetes -name experiments.yaml \
  | xargs kubectl apply -n sock-shop -f -
```

Install a single fault (e.g. `pod-delete`):

```bash
kubectl apply -n sock-shop -f chaos-charts/faults/kubernetes/pod-delete/fault.yaml
kubectl apply -n sock-shop -f chaos-charts/faults/kubernetes/pod-delete/engine.yaml
```

Service accounts and RBAC come from `service-accounts/` — apply
`argo-access.yaml`, `argowf-chaos-admin.yaml`, and `litmus-admin-rbac.yaml` once per
cluster.

---

## Security artifacts

| Path | Contents |
|---|---|
| [`security/kyverno-policies/`](security/kyverno-policies/) | 6 Kyverno `ClusterPolicy` resources covering privilege escalation, host-namespace access, capabilities, etc. |
| [`security/pod-security-policy/psp-litmus.yaml`](security/pod-security-policy/psp-litmus.yaml) | Pod Security Policy for the Litmus operator (legacy, pre-PSA) |

Apply these alongside the chaos faults if your cluster enforces admission control.

---

## Licensing

Apache 2.0 — see [LICENSE](LICENSE).

Upstream attribution: this fork preserves the original LitmusChaos copyright headers in
every `fault.yaml` and `chartserviceversion.yaml`. AgentCert-added files are likewise
Apache 2.0.
