# ITBench Fault-Studio Conformance — Handoff

**Status as of this handoff: 2 of 6 fault bundles complete. Work paused mid-task at the user's request, to hand off to a fresh session (different account, after a GitHub ownership transfer).**

If you are picking this up cold: read this whole file before touching anything. It is written to be self-contained — you should not need access to the prior conversation, the original ITBench repo, or any external ITBench clone. Everything required is inlined below.

---

## 1. The goal

Integrate ITBench SRE misconfiguration scenarios (from https://github.com/itbench-hub/ITBench) into ACE's chaos-injection platform **with true architectural conformance** — meaning each fault must be a first-class ChaosHub catalog entry (a proper `ChaosExperiment`/`ChaosEngine` pair, like the built-in `pod-delete` fault), not a one-off shell script bolted onto a hand-rolled Argo Workflow.

This was an explicit user correction mid-project. An earlier, faster implementation (still present and working — see §7) hardcoded raw `kubectl patch/scale/set-image` commands directly as Argo Workflow container steps. That version runs, but:
- it never appears in AgentCert's Fault Studio UI as a selectable/toggleable fault
- it can't be scheduled/mixed with other faults via a Fault Studio
- it bypasses the GraphQL App-Registry / Agent-Registry / Fault-Studio composition flow entirely

The user said: **"I want true architectural conformance."** That is the task. Do not silently fall back to the shortcut version.

---

## 2. How ACE's ChaosHub fault discovery actually works (verified by reading source, not assumed)

Read `chaos-charts/scripts/combine-all-crs.go` yourself to confirm — but the short version:

- Every fault lives at `chaos-charts/faults/kubernetes/<fault-name>/`, containing:
  - `fault.yaml` — a `ChaosExperiment` CR (the actual injection logic: image, command, args, env, RBAC permissions)
  - `engine.yaml` — a sample `ChaosEngine` CR referencing the experiment by name
  - `<fault-name>.chartserviceversion.yaml` — per-fault display metadata
  - `ground_truth.yaml` — optional but expected; consumed by the certifier's SLA-aware hypothesis tests (H06/H07). Confirmed via `certifier/main/services/pipeline_service.py:521-531`: **ground_truth is optional** — if absent, those two hypothesis tests are skipped gracefully; everything else in the certification pipeline still works. Confirmed via `certifier/fault_analyzer/scripts/{classifier,fault_bucketing}.py`: fault bucketing is pure LLM-driven trace classification with **zero dependency on ChaosEngine/ChaosResult CRs existing**. So a raw-script-based fault (no litmus-go SDK) is fine for certification purposes.
- `make combineExpCR` (in `chaos-charts/Makefile`, running `chaos-charts/scripts/combine-all-crs.go`) walks every subdirectory under `faults/kubernetes/`, and for each one that has a `fault.yaml`, appends its content into the category-level aggregate `faults/kubernetes/experiments.yaml`. **This aggregate file is what ChaosHub sync actually reads for discovery.** Adding a `fault.yaml` alone is not enough — you must regenerate this file (§6 below).
- Two additional category-level index files must also be updated by hand for every new fault:
  - `chaos-charts/faults/kubernetes/kubernetes.package.yaml` — a flat list of `{name, CSV, desc}` entries
  - `chaos-charts/faults/kubernetes/kubernetes.chartserviceversion.yaml` — a `ChartServiceVersion` whose `spec.faults` list needs `{name, description, displayName}` entries
  Look at how `pod-delete`, `install-application`, etc. are registered in both files as your exact template — just append in the same shape.

**Key design decision already made and validated:** since no compiled custom Go experiment binary exists for these ITBench-style faults (unlike `pod-delete`, which depends on the `litmus-go` binary baked into `litmuschaos/go-runner`), each new fault's `ChaosExperiment.spec.definition` uses `image: litmuschaos/k8s:latest` (a plain kubectl-capable image, already used elsewhere in this exact repo — e.g. `chaos-charts/experiments/sock-shop/experiment.yaml`'s cleanup step) with `command: [/bin/sh]` / `args: [-c, <inject→sleep→revert script>]`. This is the same precedent `chaos-charts/faults/kubernetes/install-application/fault.yaml` set (custom AgentCert image + command + args, no dependency on the go-runner binary) — read that file if you want the exact template for "custom, non-go-runner ChaosExperiment."

Target resolution inside every script uses the standard, well-documented public LitmusChaos convention: the chaos-operator auto-injects `APP_NAMESPACE` / `APP_LABEL` / `APP_KIND` into the experiment pod from `ChaosEngine.spec.appinfo.{appns,applabel,appkind}`. **This was NOT independently verified against actual `litmus-go` source in the prior session** — two attempts to fetch `github.com/AgentCert/litmus-go` (a full `git submodule update --init litmus-go`, and a direct `curl` of `pkg/types/types.go`) both timed out after 2 minutes, likely a sandbox network restriction on raw.githubusercontent.com specifically (other network calls, e.g. `gh api`, `helm pull oci://...`, worked fine in that same session). **Verify this before trusting it** — either retry the fetch, or just test it empirically once a cluster is available.

---

## 3. What's done (safe, committed, complete)

Two fault bundles are **fully built and committed** in `chaos-charts` on branch `feature/itbench-scenarios`, matching the template above exactly:

1. `chaos-charts/faults/kubernetes/scaled-to-zero-kubernetes-workload/`
2. `chaos-charts/faults/kubernetes/nonexistent-kubernetes-workload-container-image/`

Each has all 4 files (`fault.yaml`, `engine.yaml`, `<name>.chartserviceversion.yaml`, `ground_truth.yaml`). **Use `scaled-to-zero-kubernetes-workload/fault.yaml` as your literal copy-paste template** for the remaining four — the script skeleton (resolve target by label → capture original state → inject → `sleep "${TOTAL_CHAOS_DURATION}"` → revert using the captured original state) is identical across all of them; only the inject/revert kubectl commands differ per fault.

Run `git log --oneline -5` in `chaos-charts` after cloning to confirm these commits are present.

---

## 4. What's NOT done — the remaining 4 fault bundles

Each needs the same 4 files as the 2 completed ones. Full ITBench source data is inlined below so you don't need external access.

### 4a. `misconfigured-kubernetes-workload-container-readiness-probe`

**ITBench scenario reference** (scenario index 49, targets otel-demo `frontend`):
```json
{
  "description": "This scenario simulates OpenTelemetry Demo's `frontend` service having a malformed readiness probe.",
  "disruptions": [{"injections": [{
    "args": {
      "container": {"name": "frontend"},
      "kubernetesObject": {"apiVersion": "apps/v1", "kind": "Deployment",
        "metadata": {"name": "frontend", "namespace": "otel-demo"}}
    },
    "id": "misconfigured-kubernetes-workload-container-readiness-probe"
  }]}],
  "solutions": [[{"steps": [{"command": "kubectl -n otel-demo rollout undo deployment/frontend"}]}],
                 [{"steps": [{"command": "kubectl -n otel-demo edit deployment frontend",
                              "text": "remove the faulty readiness probe"}]}]]
}
```

**ITBench's own Ansible fault injection** (the exact patch body to replicate):
```yaml
spec:
  template:
    spec:
      containers:
        - name: "{{ faults_container.name }}"
          readinessProbe:
            failureThreshold: 3
            httpGet:
              path: /ready
              port: 40          # deliberately unreachable port
              scheme: HTTP
            periodSeconds: 5
            successThreshold: 1
            timeoutSeconds: 3
```

**Design note — the tricky part:** the container may or may not have had a `readinessProbe` originally. Capture it first:
```sh
ORIG_PROBE=$(kubectl get "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].readinessProbe}")
```
This returns either a JSON object string, or an empty string if no probe existed. On revert, Kubernetes' strategic-merge-patch treats an explicit JSON `null` as "delete this field" — so:
```sh
if [ -z "$ORIG_PROBE" ]; then PROBE_JSON="null"; else PROBE_JSON="$ORIG_PROBE"; fi
kubectl patch "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${CONTAINER}\",\"readinessProbe\":${PROBE_JSON}}]}}}}"
```
Inject with the same `--type=strategic` pattern, substituting the broken-probe JSON literal shown above (build it as a JSON string in the script, `port` env var default `40`, `path` default `/ready`).

Env vars needed: `APP_NAMESPACE`, `APP_LABEL`, `APP_KIND` (default `deployment`), `TARGET_CONTAINER` (defaults to `$TARGET` if unset, same convention as fault #2), `PROBE_PATH` (default `/ready`), `PROBE_PORT` (default `40`), `TOTAL_CHAOS_DURATION` (default `300`).

---

### 4b. `modified-target-port-kubernetes-service`

**ITBench scenario reference** (scenario index 30, targets otel-demo `ad` service):
```json
{
  "description": "This scenario changes the specified port of OpenTelemetry Demo's `ad` service.",
  "disruptions": [{"injections": [{
    "args": {
      "kubernetesObject": {"apiVersion": "v1", "kind": "Service",
        "metadata": {"name": "ad", "namespace": "otel-demo"}},
      "targetPort": 8080
    },
    "id": "modified-target-port-kubernetes-service"
  }]}],
  "solutions": [[{"steps": [{"command": "kubectl -n otel-demo edit service ad",
                              "text": "replace the target port (8080) with the correct value"}]}]]
}
```
ITBench's own Ansible injection just sets `spec.ports[0].targetPort` to a broken value (`9999` in the earlier draft implementation) via `kubernetes.core.k8s: state: patched`.

**Design note:** `APP_KIND=service`. Confirmed via the actual upstream `opentelemetry-demo` Helm chart (pulled and inspected in the prior session — `helm pull oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-demo --version 0.40.9 --untar`) that the `ad` component only declares `service.port: 8080` (no `.ports` list), so the rendered Service has **exactly one port at index 0** — `/spec/ports/0/targetPort` is a safe JSON-patch path for this component. Don't assume that generalizes to every possible target Service without checking; re-verify port-list length if this experiment is ever pointed at a different Service. Script:
```sh
ORIG_PORT=$(kubectl get "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" -o jsonpath='{.spec.ports[0].targetPort}')
kubectl patch "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/targetPort\",\"value\":${BROKEN_TARGET_PORT}}]"
sleep "${TOTAL_CHAOS_DURATION}"
kubectl patch "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/targetPort\",\"value\":${ORIG_PORT}}]"
```
Env vars: `APP_NAMESPACE`, `APP_LABEL`, `APP_KIND=service`, `BROKEN_TARGET_PORT` (default `9999`), `TOTAL_CHAOS_DURATION`.

---

### 4c. `invalid-kubernetes-service-selector`

**ITBench scenario reference** (scenario index 36, targets bookinfo `details` service):
```json
{
  "description": "This scenario simulates BookInfo's `details` service being unable to accept traffic due to a misconfigured service.",
  "disruptions": [{"injections": [{
    "args": {"kubernetesObject": {"apiVersion": "v1", "kind": "Service",
      "metadata": {"name": "details", "namespace": "book-info"}}},
    "id": "invalid-kubernetes-service-selector"
  }]}],
  "solutions": [[{"steps": [{"command": "kubectl -n book-info edit service details",
                              "text": "replace the selector with the correct value"}]}]]
}
```
ITBench's own Ansible injection (fault index 29 in ITBench's own fault library) patches:
```yaml
spec:
  selector:
    "app.kubernetes.io/name": invalid-workload-{{ 1000 | random }}
```
then waits for the Service's `Endpoints` object to have zero subsets.

**Design note:** capture-then-restore the whole selector object, since it's simpler than reconstructing it field-by-field:
```sh
ORIG_SELECTOR=$(kubectl get "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" -o jsonpath='{.spec.selector}')
kubectl patch "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" --type=merge \
  -p "{\"spec\":{\"selector\":{\"app.kubernetes.io/name\":\"invalid-workload-${RANDOM_SUFFIX:-1}\"}}}"
sleep "${TOTAL_CHAOS_DURATION}"
kubectl patch "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" --type=merge \
  -p "{\"spec\":{\"selector\":${ORIG_SELECTOR}}}"
```
`${ORIG_SELECTOR}` from `jsonpath='{.spec.selector}'` is already valid embeddable JSON — no reformatting needed. Env vars: `APP_NAMESPACE`, `APP_LABEL`, `APP_KIND=service`, `TOTAL_CHAOS_DURATION`.

---

### 4d. `nonexistent-kubernetes-workload-persistent-volume-claim`

**ITBench scenario reference** (scenario index 53, targets bookinfo `reviews-v3`):
```json
{
  "description": "This scenario simulates BookInfo's `reviews-v3` service being unable to start due to lack of persistent storage.",
  "disruptions": [{"injections": [{
    "args": {
      "container": {"name": "reviews"},
      "kubernetesObject": {"apiVersion": "apps/v1", "kind": "Deployment",
        "metadata": {"name": "reviews-v3", "namespace": "book-info"}}
    },
    "id": "nonexistent-kubernetes-workload-persistent-volume-claim"
  }]}],
  "solutions": [[{"steps": [{"command": "kubectl -n book-info rollout undo deployment/reviews-v3"}]},
                 {"steps": [{"command": "kubectl -n book-info edit persistentvolumeclaim reviews-v3",
                              "text": "replace storageClassName with the correct value"}]}]]
}
```
ITBench's own Ansible injection:
```yaml
- name: Create PersistentVolumeClaim
  kubernetes.core.k8s:
    resource_definition:
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata: {name: "{{ faults_kubernetes_object.metadata.name }}", namespace: "..."}
      spec:
        accessModes: [ReadWriteOnce]
        resources: {requests: {storage: 25Mi}}
        storageClassName: invalid-class-name
    state: present
- name: Update workload containers
  # patches in a volumeMount + volume referencing the PVC by claimName
```

**Design note (already verified against actual chart source, not assumed):** `chaos-charts` app-charts' `bookinfo/templates/bookinfo/reviews.yaml` shows the `reviews-v3` container is literally named `reviews`, and the Deployment already has existing `volumeMounts` (`tmp`, `wlp-output`) and `volumes` (same names, `emptyDir`). Kubernetes' strategic-merge-patch keys `containers[].volumeMounts` by `mountPath` and pod `volumes` by `name` — so patching in **one new** volumeMount/volume entry is **additive**, it will not clobber the existing two. Script:
```sh
PVC_NAME="${TARGET}-fault-pvc"
kubectl apply -f - <<JSON
{"apiVersion":"v1","kind":"PersistentVolumeClaim",
 "metadata":{"name":"${PVC_NAME}","namespace":"${APP_NAMESPACE}"},
 "spec":{"accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"25Mi"}},
         "storageClassName":"${INVALID_STORAGE_CLASS:-invalid-class-name}"}}
JSON
kubectl patch "${APP_KIND}" -n "${APP_NAMESPACE}" "$TARGET" --type=strategic -p \
  "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${CONTAINER}\",\"volumeMounts\":[{\"name\":\"fault-volume\",\"mountPath\":\"${PVC_MOUNT_PATH:-/data/fault}\"}]}],\"volumes\":[{\"name\":\"fault-volume\",\"persistentVolumeClaim\":{\"claimName\":\"${PVC_NAME}\"}}]}}}}"
sleep "${TOTAL_CHAOS_DURATION}"
kubectl rollout undo -n "${APP_NAMESPACE}" "${APP_KIND}/${TARGET}"
kubectl delete pvc -n "${APP_NAMESPACE}" "${PVC_NAME}" --ignore-not-found
```
Env vars: `APP_NAMESPACE`, `APP_LABEL`, `APP_KIND=deployment`, `TARGET_CONTAINER`, `INVALID_STORAGE_CLASS` (default `invalid-class-name`), `PVC_MOUNT_PATH` (default `/data/fault`), `TOTAL_CHAOS_DURATION`.

RBAC for this one needs an extra permission block vs. the other three: `persistentvolumeclaims: [create, get, list, delete]`.

---

## 5. `ground_truth.yaml` — how to write the remaining 4

Copy the structure from `scaled-to-zero-kubernetes-workload/ground_truth.yaml` (already committed — read it directly). Shape:
```yaml
fault: <fault-name>
version: 0.1.0
description: <one-liner>
ground_truth:
  fault_description_goal_remediation: {symptoms: [...], goal: "...", remediation: "..."}
  ideal_course_of_action: [{step, action, detail}, ...]
  ideal_tool_usage_trajectory: [{step, tool, command, purpose, tool_available}, ...]
  sla: {time_to_detect: {threshold, unit}, time_to_mitigate: {...}, max_tool_calls: {...}}
```
For `ideal_tool_usage_trajectory`, use the same human-readable tool-label style as the existing `pod-delete/ground_truth.yaml` and the two completed bundles (`"Namespaces: List"`, `"Resources: Get"`, `"Resources: Scale"`, `"Events: List"`, `"Execute PromQL Query"`, `"Rollback Deployment"`, etc.) — these are descriptive labels matching `docs/platform/mcp-infrastructure.md`'s description of the kubernetes-mcp-server/prometheus-mcp-server tool surface (pods/deployments/services/events/namespaces/logs + PromQL), not verified literal JSON-RPC method names.

Symptoms/goal/remediation content for each: use the ITBench scenario `description` + `solutions[].steps[].text` fields quoted above in §4 as your source material.

---

## 6. Mechanical steps after all 6 fault bundles exist

1. **Register in the two category-index files** — append entries following the exact existing format:
   - `chaos-charts/faults/kubernetes/kubernetes.package.yaml`
   - `chaos-charts/faults/kubernetes/kubernetes.chartserviceversion.yaml` (under `spec.faults`)
2. **Regenerate the aggregate discovery file:**
   ```sh
   cd chaos-charts/scripts && go run ./combine-all-crs.go
   ```
   This rewrites `chaos-charts/faults/kubernetes/experiments.yaml`. Requires a Go toolchain. If unavailable, read `chaos-charts/scripts/combine-all-crs.go` yourself and replicate its logic by hand (it just concatenates every `faults/kubernetes/*/fault.yaml` with a `\n---\n` separator into that one file, deduped by CR name).
3. **Rewrite the app-level workflows** to use real `ChaosEngine` CRs instead of the current raw-`kubectl` container steps:
   - `chaos-charts/experiments/otel-demo-itbench/experiment.yaml`
   - `chaos-charts/experiments/bookinfo-itbench/experiment.yaml`

   Pattern to follow: `chaos-charts/experiments/sock-shop/experiment.yaml` — each fault becomes an Argo step that (a) writes the fault's `ChaosEngine` CR as a raw workflow artifact (embed the actual CR content, filling in `appinfo.appns`/`applabel`/`appkind` for the specific target, e.g. `applabel: 'opentelemetry.io/name=frontend'` for otel-demo components, `app=details` / `app=reviews,version=v3` for bookinfo), then (b) a `litmuschaos/litmus-checker:latest` step that applies it and waits for completion — replacing the current `inject-scenario-N`/`revert-scenario-N`/`wait-fault` steps entirely. The currently-committed raw-kubectl version (chaos-charts commit `731d399`) can stay as a reference of "what used to work" until the replacement is validated, or be deleted once the ChaosEngine-based version is confirmed working — that's your call depending on whether you want a fallback path during testing.
4. **Static-validate** all new/changed YAML: parse every `experiment.yaml`/`fault.yaml`/`engine.yaml` with a YAML parser and confirm every Argo `steps[].template` reference resolves to a defined template name (the prior session did this with a throwaway Python venv + `pyyaml`, since the sandbox's system Python lacked it — `python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pyyaml`).
5. **Commit + push** `chaos-charts`, then bump and commit `ace-monorepo`'s `chaos-charts` submodule pointer to the new commit, then push `ace-monorepo`.

---

## 7. What already exists and works (the pre-conformance layer, still in place)

Before this conformance rework was requested, a working-but-non-conformant version was already built, tested (statically), and pushed:

- `app-charts/charts/bookinfo/` and `app-charts/charts/otel-demo/` — full Helm charts, vendored from `istio/istio@1.30.2` and `open-telemetry/opentelemetry-helm-charts@0.40.9` respectively. **This part is done and needs no further work.**
- `chaos-charts/experiments/otel-demo-itbench/experiment.yaml` and `chaos-charts/experiments/bookinfo-itbench/experiment.yaml` — the raw-`kubectl` Argo Workflows implementing the same 6 scenarios via hardcoded `inject-scenario-N`/`wait-fault`/`revert-scenario-N` steps. **This is what §6.3 above replaces.** It's committed at `chaos-charts` commit `731d399` and still runs; keep it working until the ChaosEngine-based replacement is validated.
- `.gitmodules` in `ace-monorepo` was fixed to point `app-charts` and `chaos-charts` at fork remotes rather than the upstream `AgentCert` org (the prior session's GitHub identity lacked push access to `AgentCert/chaos-charts` — confirmed via a 403 on `git push`). **Check `git remote -v` in each repo after the ownership transfer** — the fork URLs may now be under yet another account; update `.gitmodules` and each submodule's `git remote set-url origin ...` + `git submodule sync` accordingly before pushing anything.

---

## 8. Honest list of things nobody has verified against a live cluster

- **No Kubernetes cluster was ever reachable in the prior session.** A `kind-agentcert` kubeconfig context existed but nothing was listening on it, and the sandbox lacked Docker permission to start one (`permission denied ... /var/run/docker.sock`). Every fault bundle here (the 2 done, and the 4 designed above) is **static-review-only** — YAML parses, resource names/labels were cross-checked against actual chart source (not guessed), but nothing has been `kubectl apply`'d or watched running.
- **`APP_NAMESPACE`/`APP_LABEL`/`APP_KIND` env var names** — standard public LitmusChaos convention, unverified against this fork's actual `litmus-go` source in this session (network fetch timeouts, see §2). Verify before relying on it.
- **ChaosResult verdict reporting is not wired.** These scripts are plain shell, not built against the `litmus-go` SDK, so nothing patches the auto-created `ChaosResult` CR's verdict field. It will likely sit in "Awaited" state. Doesn't block certification (§2), but is a UX gap vs. built-in faults in any ChaosCenter pass/fail view. A `kubectl patch chaosresult ... --type=merge -p '{"status":{"experimentStatus":{"verdict":"Pass"}}}'` best-effort call could close this gap, but the exact ChaosResult name/namespace convention wasn't verified against a live chaos-operator.
- **Label-uniqueness assumption**: `kubectl get $KIND -l $LABEL -o jsonpath='{.items[0]...}'` assumes exactly one match. Untested against 0-match or multi-match cases beyond the explicit empty-string check already in the script.
