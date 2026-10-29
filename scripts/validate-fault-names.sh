#!/usr/bin/env bash
#
# Guards the naming invariants that the chaos-runner depends on.
#
# The runner derives the experiment Job's name from the ChaosExperiment's own
# metadata.name as "<name>-<6 random chars>", and reuses that string verbatim as
# spec.template.spec.containers[0].name and as a pod-template label value. Both are
# capped at 63 characters by Kubernetes, so a fault name longer than 56 characters makes
# the Job fail admission with:
#
#   Job.batch "<name>-xxxxxx" is invalid:
#     spec.template.labels: must be no more than 63 bytes,
#     spec.template.spec.containers[0].name: must be no more than 63 characters
#
# That happens at Job-admission time inside the runner, so nothing in the fault's own
# image ever runs and the ChaosEngine simply stalls -- which makes it easy to ship a
# fault that is dead on arrival. Hence this check.
#
# It also pins directory name == metadata.name == engine experiment name. Letting those
# drift apart silently de-syncs the generated aggregates (experiments.yaml, the harness
# ConfigMap bundle) from the per-fault sources and leaves the operator unable to resolve
# the ChaosExperiment an engine references.

set -euo pipefail

# 63 (DNS-1123 label limit) - 1 separator - 6 random characters appended by the runner.
readonly MAX_FAULT_NAME_LEN=56

cd "$(dirname "$0")/.."

failures=0

fail() {
  printf '  FAIL %s\n' "$1"
  failures=$((failures + 1))
}

shopt -s nullglob
for fault_yaml in faults/*/*/fault.yaml; do
  dir="$(dirname "$fault_yaml")"
  dir_name="$(basename "$dir")"

  name="$(grep -m1 -oP '^  name: \K\S+' "$fault_yaml" || true)"
  if [[ -z "$name" ]]; then
    fail "$fault_yaml: could not read metadata.name"
    continue
  fi

  if (( ${#name} > MAX_FAULT_NAME_LEN )); then
    fail "$fault_yaml: metadata.name is ${#name} chars (max $MAX_FAULT_NAME_LEN) -- the runner's Job name '$name-xxxxxx' would be $(( ${#name} + 7 )) chars and exceed the 63-char limit"
  fi

  if [[ "$dir_name" != "$name" ]]; then
    fail "$dir: directory name does not match metadata.name ('$name')"
  fi

  engine_yaml="$dir/engine.yaml"
  if [[ -f "$engine_yaml" ]]; then
    engine_name="$(grep -m1 -oP '^    - name: \K\S+' "$engine_yaml" || true)"
    if [[ "$engine_name" != "$name" ]]; then
      fail "$engine_yaml: spec.experiments[0].name is '$engine_name', expected '$name'"
    fi
  fi
done

if (( failures > 0 )); then
  printf '\n%d fault naming violation(s) found.\n' "$failures" >&2
  exit 1
fi

echo "All fault names are within $MAX_FAULT_NAME_LEN characters and consistent with their directory and engine."
