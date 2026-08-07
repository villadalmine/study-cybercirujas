#!/usr/bin/env bash
#
# CNPA — Cloud Native Platform Engineering Associate (exam version 2025-04-01)
# Domain 3 — Continuous Integration / Continuous Delivery
# Topic 3.3 — Continuous Integration Pipelines: Overview and Architecture  (exam weight 2.3)
#
# Reference syllabus: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# Tool references (official):
#   - Tekton Pipelines concepts:  https://tekton.dev/docs/pipelines/pipelines/
#   - Tekton Workspaces:          https://tekton.dev/docs/pipelines/workspaces/
#   - Tekton Tasks:               https://tekton.dev/docs/pipelines/tasks/
#   - CI/CD in cloud native:      https://glossary.cncf.io/continuous-integration/
#
# ---------------------------------------------------------------------------
# WHAT THIS LAB TEACHES
# ---------------------------------------------------------------------------
# A CI pipeline is not a single script; it is a DAG of isolated stages. In a
# cloud native runner (Tekton, Argo Workflows, GitLab, GitHub Actions) every
# stage/step runs in its OWN ephemeral container with its OWN filesystem. The
# ONLY things that survive across stages are what you deliberately publish to
# a shared medium: a workspace (Tekton), an artifact store, a cache, or an
# output parameter. Whatever a stage writes to its private container filesystem
# is destroyed when that step's pod terminates.
#
# The most common architectural failure in a CI pipeline is therefore NOT a
# stage that crashes — it is a stage that "passes" while quietly failing to
# hand its output to the next stage. The build is green, the artifact is gone,
# and the failure only surfaces one stage downstream. This lab reproduces
# exactly that failure mode, in a controlled and reversible way, on a
# throwaway cluster.
#
# ---------------------------------------------------------------------------
# SAFETY
# ---------------------------------------------------------------------------
#   * Runs ONLY against a disposable local cluster (kind / minikube / k3d /
#     docker-desktop). Against any other kube-context it refuses to run unless
#     you export I_UNDERSTAND_THIS_IS_A_LAB=yes.
#   * All objects live in the dedicated namespace 'cnpa-ci'. Nothing outside it
#     is touched. Tear everything down with:  ./break_fix.sh reset
#   * Idempotent: re-running any subcommand converges to the same state.
#
# Usage:
#   ./break_fix.sh          # provision, prove it works, then BREAK it (default)
#   ./break_fix.sh solve    # apply the fix and prove the pipeline is green
#   ./break_fix.sh reset    # delete the lab namespace
# ---------------------------------------------------------------------------

set -Eeuo pipefail

NS="cnpa-ci"
PIPELINE="ci"
TEKTON_RELEASE="https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml"
# For a reproducible lab, pin the line above to a fixed release, e.g.:
#   .../tekton-releases/pipeline/previous/v0.68.0/release.yaml
IMG="docker.io/library/busybox:1.36"
CREATED_KIND=0

# ---- pretty logging -------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; C=$'\033[0;36m'; N=$'\033[0m'; else B=; R=; G=; Y=; C=; N=; fi
log()  { printf '%s[ lab ]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[fail ]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ---- preconditions --------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

guard_context() {
  need kubectl
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo none)"
  case "$ctx" in
    kind-*|minikube|k3d-*|docker-desktop|none) : ;;
    *)
      if [ "${I_UNDERSTAND_THIS_IS_A_LAB:-no}" != "yes" ]; then
        die "current kube-context is '$ctx' — this does not look like a disposable lab.
       Refusing to mutate it. Switch to a kind/minikube context, or, if you are
       certain this cluster is disposable, re-run with:  I_UNDERSTAND_THIS_IS_A_LAB=yes"
      fi
      warn "operating on non-lab context '$ctx' because the override was set." ;;
  esac
}

ensure_cluster() {
  if kubectl cluster-info >/dev/null 2>&1; then return 0; fi
  if command -v kind >/dev/null 2>&1; then
    log "no reachable cluster — creating disposable kind cluster 'cnpa-ci'..."
    kind create cluster --name cnpa-ci >/dev/null
    CREATED_KIND=1
    ok "kind cluster 'cnpa-ci' created (context: kind-cnpa-ci)."
  else
    die "no reachable Kubernetes cluster and 'kind' is not installed.
       Install kind (https://kind.sigs.k8s.io) or start minikube, then re-run."
  fi
}

ensure_tekton() {
  if kubectl get deploy tekton-pipelines-controller -n tekton-pipelines >/dev/null 2>&1; then
    return 0
  fi
  log "installing Tekton Pipelines (the CI engine for this lab)..."
  kubectl apply -f "$TEKTON_RELEASE" >/dev/null
  log "waiting for the Tekton control plane to become Available..."
  kubectl -n tekton-pipelines wait --for=condition=Available deploy --all --timeout=240s >/dev/null
  ok "Tekton Pipelines is ready."
}

ensure_namespace() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# ---- pipeline definitions -------------------------------------------------
# Note: $(workspaces.source.path) is a Tekton variable, NOT a shell expansion.
# The quoted heredoc (<<'YAML') guarantees bash writes it verbatim into the YAML.

apply_build_good() {
  # BUILD stage — CORRECT: publishes the artifact INTO the shared workspace,
  # so the downstream stage can consume it.
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: build
  namespace: cnpa-ci
spec:
  description: Compile the app and publish the artifact to the shared workspace.
  workspaces:
    - name: source
      description: Shared medium used to hand artifacts to downstream stages.
  steps:
    - name: compile
      image: docker.io/library/busybox:1.36
      script: |
        #!/bin/sh
        set -e
        echo "build: compiling..."
        echo "build-id=42" > "$(workspaces.source.path)/app.txt"
        echo "build: published artifact -> $(workspaces.source.path)/app.txt"
YAML
}

apply_build_broken() {
  # BUILD stage — BROKEN: writes the artifact to the step container's OWN
  # /tmp filesystem instead of the shared workspace. This step still exits 0
  # (it "passes"), but the artifact vanishes when the pod terminates.
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: build
  namespace: cnpa-ci
spec:
  description: (intentionally broken) writes the artifact to ephemeral /tmp.
  workspaces:
    - name: source
  steps:
    - name: compile
      image: docker.io/library/busybox:1.36
      script: |
        #!/bin/sh
        set -e
        echo "build: compiling..."
        echo "build-id=42" > /tmp/app.txt
        echo "build: wrote /tmp/app.txt (private to this container — LOST on exit)"
YAML
}

apply_test() {
  # TEST stage — consumes the artifact produced by BUILD via the shared
  # workspace. This stage is CORRECT and must not be weakened by the student.
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: test
  namespace: cnpa-ci
spec:
  description: Consume the build artifact from the shared workspace and verify it.
  workspaces:
    - name: source
  steps:
    - name: verify
      image: docker.io/library/busybox:1.36
      script: |
        #!/bin/sh
        set -e
        echo "test: reading artifact from previous stage..."
        cat "$(workspaces.source.path)/app.txt"
        grep -q "build-id=" "$(workspaces.source.path)/app.txt"
        echo "test: artifact present and valid."
YAML
}

apply_pipeline() {
  # PIPELINE — the DAG: test runAfter build, both bound to the same workspace.
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: ci
  namespace: cnpa-ci
spec:
  description: Minimal CI pipeline — build then test, sharing one workspace.
  workspaces:
    - name: shared-data
  tasks:
    - name: build
      taskRef:
        name: build
      workspaces:
        - name: source
          workspace: shared-data
    - name: test
      runAfter: ["build"]
      taskRef:
        name: test
      workspaces:
        - name: source
          workspace: shared-data
YAML
}

# ---- run helpers ----------------------------------------------------------
start_run() {
  # Each execution is a NEW immutable PipelineRun (this is how Tekton works:
  # you never edit a run, you fix the definitions and start another one).
  local run="ci-run-$(date +%s)"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: ${run}
  namespace: ${NS}
spec:
  pipelineRef:
    name: ${PIPELINE}
  workspaces:
    - name: shared-data
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 64Mi
YAML
  echo "$run"
}

wait_run() {
  # returns 0 = Succeeded, 1 = Failed, 2 = timeout
  local run="$1" timeout="${2:-300}" elapsed=0 status
  while :; do
    status="$(kubectl -n "$NS" get pipelinerun "$run" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)"
    case "$status" in
      True)  return 0 ;;
      False) return 1 ;;
    esac
    [ "$elapsed" -ge "$timeout" ] && return 2
    sleep 5; elapsed=$((elapsed + 5))
  done
}

show_status() { kubectl -n "$NS" get pipelinerun "$1" -o wide 2>/dev/null || true; }

show_logs() {
  local run="$1"
  echo
  kubectl -n "$NS" logs --selector "tekton.dev/pipelineRun=$run" \
    --all-containers --prefix --tail=-1 2>/dev/null || true
}

# ---- subcommands ----------------------------------------------------------
provision() {
  guard_context
  ensure_cluster
  ensure_tekton
  ensure_namespace
  apply_test
  apply_pipeline
}

do_break() {
  provision
  apply_build_good
  log "baseline: running the pipeline while it is CORRECT (proves it can be green)..."
  local base; base="$(start_run)"
  if wait_run "$base" 300; then
    ok "baseline PipelineRun '$base' Succeeded — build handed the artifact to test."
  else
    warn "baseline did not go green in time (slow image pull?). Continuing anyway."
  fi

  echo
  log "INJECTING THE FAULT: replacing the 'build' Task with a version that writes"
  log "the artifact to its private /tmp instead of the shared workspace."
  apply_build_broken
  local run; run="$(start_run)"
  log "started the failing PipelineRun: $run"
  wait_run "$run" 300 || true
  echo
  show_status "$run"
  show_logs "$run"

  cat <<EOF

${B}================= YOUR TASK ==================================================${N}

${B}SYMPTOM${N}
  * The 'build' TaskRun reports ${G}Succeeded${N} — its step exits 0.
  * Yet the PipelineRun as a whole is ${R}Failed${N}:
        \$ kubectl -n ${NS} get pipelinerun
        NAME          SUCCEEDED   REASON    ...
        ${run}   False       Failed    ...
  * The failure is in the DOWNSTREAM stage. The 'test' step log ends with:
        cat: can't open '/workspace/source/app.txt': No such file or directory
  * A green build with a red pipeline is the classic CI architecture bug:
    the stage passed, the artifact was never handed off.

${B}GOAL${N}
  Make ${B}one full PipelineRun reach Succeeded=True${N}, with BOTH the 'build'
  and 'test' TaskRuns Succeeded. Constraints:
    - Do NOT weaken or delete the 'test' Task (no 'exit 0', no removing the check).
    - Do NOT drop the workspace or the runAfter ordering.
    - The artifact must reach 'test' through the ${B}shared workspace${N}, the way a
      real CI stage publishes to an artifact store / cache for the next stage.

${B}INVESTIGATE WITH${N}
    kubectl -n ${NS} get pipelinerun
    kubectl -n ${NS} get taskrun
    kubectl -n ${NS} logs --selector tekton.dev/pipelineRun=${run} --all-containers --prefix
    kubectl -n ${NS} get task build -o yaml        # <-- where does 'build' write?
    kubectl -n ${NS} get task test  -o yaml        # <-- where does 'test' read?

When you think it is fixed, start a fresh run and confirm it is green:
    kubectl -n ${NS} create -f - <<'RUN'   # or re-run:  ./break_fix.sh solve
    ...a PipelineRun referencing pipeline '${PIPELINE}' with the shared-data workspace...
    RUN

Clean up when done:   ./break_fix.sh reset
${B}=============================================================================${N}
EOF
}

do_solve() {
  guard_context
  ensure_namespace
  log "applying the fix: 'build' now publishes the artifact into the shared workspace."
  apply_build_good
  apply_test
  apply_pipeline
  local run; run="$(start_run)"
  log "verifying with a fresh PipelineRun: $run"
  if wait_run "$run" 300; then
    echo; show_status "$run"
    ok "GREEN. Both stages Succeeded — the artifact was handed off correctly."
  else
    echo; show_status "$run"; show_logs "$run"
    die "still not green — inspect the logs above."
  fi
}

do_reset() {
  guard_context
  log "deleting namespace '$NS' (all lab objects)..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  ok "lab namespace removed."
  log "Tekton and the cluster were left in place. To delete a lab kind cluster:"
  echo "    kind delete cluster --name cnpa-ci"
}

case "${1:-break}" in
  break) do_break ;;
  solve|fix|solution) do_solve ;;
  reset|clean) do_reset ;;
  *) die "unknown subcommand '$1' (expected: break | solve | reset)" ;;
esac

# =============================================================================
# SOLUTION — step by step (do not read until you have tried it)
# =============================================================================
#
# ROOT CAUSE
#   Every CI stage runs in an isolated, ephemeral container. The 'build' Task
#   was mutated to write its artifact to /tmp/app.txt — a path on the step
#   container's OWN filesystem. That container is destroyed the instant the
#   step finishes, so the file is gone. The 'test' Task (correctly) reads from
#   the SHARED workspace at $(workspaces.source.path)/app.txt, finds nothing,
#   and fails. build is green because writing to /tmp succeeds; the pipeline is
#   red because the hand-off never happened. Nothing is wrong with 'test'.
#
# 1. Confirm the failure is downstream, not in build:
#      $ kubectl -n cnpa-ci get taskrun
#      NAME                    SUCCEEDED   REASON
#      ci-run-...-build        True        Succeeded
#      ci-run-...-test         False       Failed
#
# 2. Read the failing stage's log — it names the missing artifact:
#      $ kubectl -n cnpa-ci logs --selector tekton.dev/pipelineRun=<run> \
#            --all-containers --prefix | tail -n 5
#      [pod/.../step-verify] test: reading artifact from previous stage...
#      [pod/.../step-verify] cat: can't open '/workspace/source/app.txt': No such file or directory
#
# 3. Compare where each stage writes vs. reads:
#      $ kubectl -n cnpa-ci get task build -o jsonpath='{.spec.steps[0].script}'; echo
#        ... echo "build-id=42" > /tmp/app.txt ...              <-- WRONG (private /tmp)
#      $ kubectl -n cnpa-ci get task test  -o jsonpath='{.spec.steps[0].script}'; echo
#        ... cat "$(workspaces.source.path)/app.txt" ...        <-- reads the shared workspace
#      The two paths do not match: the producer and consumer disagree on the medium.
#
# 4. Fix the PRODUCER so it publishes into the shared workspace. Re-apply 'build'
#    changing the write path from /tmp/app.txt to the workspace path:
#
#      kubectl apply -f - <<'YAML'
#      apiVersion: tekton.dev/v1
#      kind: Task
#      metadata:
#        name: build
#        namespace: cnpa-ci
#      spec:
#        workspaces:
#          - name: source
#        steps:
#          - name: compile
#            image: docker.io/library/busybox:1.36
#            script: |
#              #!/bin/sh
#              set -e
#              echo "build-id=42" > "$(workspaces.source.path)/app.txt"
#      YAML
#
#    (Equivalently:  ./break_fix.sh solve  — which does exactly this.)
#
# 5. Start a FRESH PipelineRun (Tekton runs are immutable — you never edit the
#    old one, you launch a new one against the fixed definitions):
#
#      kubectl create -f - <<'YAML'
#      apiVersion: tekton.dev/v1
#      kind: PipelineRun
#      metadata:
#        generateName: ci-run-
#        namespace: cnpa-ci
#      spec:
#        pipelineRef:
#          name: ci
#        workspaces:
#          - name: shared-data
#            volumeClaimTemplate:
#              spec:
#                accessModes: ["ReadWriteOnce"]
#                resources:
#                  requests:
#                    storage: 64Mi
#      YAML
#
# 6. Verify it is green end to end:
#      $ kubectl -n cnpa-ci get pipelinerun
#      NAME           SUCCEEDED   REASON      STARTTIME   COMPLETIONTIME
#      ci-run-xxxxx   True        Succeeded   30s         2s
#
# WHY THIS IS THE POINT OF THE TOPIC
#   Stage isolation is a feature, not a bug: it makes stages reproducible,
#   cacheable and parallelizable. But it forces one architectural rule — a
#   stage's output only exists downstream if it is published to a shared medium
#   (workspace / artifact repository / cache / output parameter). "The build
#   passed" is never sufficient evidence that the pipeline works; you must trace
#   the artifact across the stage boundary. Diagnose CI pipelines at the seam
#   between stages, not inside a single stage.
# =============================================================================