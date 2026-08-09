#!/usr/bin/env bash
#
# ============================================================================
#  PCA — Prometheus / Cloud Native Admin track
#  Domain 3: Observability   ·   Topic 3.2: Understand logs and events
#  Exam weight: 3
# ----------------------------------------------------------------------------
#  BREAK & FIX LAB  —  "The pod that won't stay up, and the two places that
#                       tell you why."
#
#  This script deliberately deploys a broken workload into a DISPOSABLE,
#  single-node lab cluster (kind / minikube / k3s / a throwaway VM). It does
#  NOT touch anything outside its own namespace, pulls no untrusted images,
#  and can be fully removed with `./break-fix.sh clean`.
#
#  What you will practice: the two independent observability planes that every
#  Kubernetes operator confuses at least once —
#
#    1. EVENTS  — the control plane's narration of *what the system did to the
#                 object* (scheduled, pulled, started, backed-off, killed).
#                 Source: the kube-apiserver events API, TTL-bounded (~1h).
#    2. LOGS    — *what the process wrote to stdout/stderr*, captured by the
#                 kubelet's logging pipeline on the node.
#                 They are NOT the same data, and a CrashLoopBackOff is the
#                 classic case where you need BOTH: events tell you it is
#                 crash-looping, logs tell you why it crashed.
#
#  Official references (read these, do not memorise):
#    - Logging architecture:
#      https://kubernetes.io/docs/concepts/cluster-administration/logging/
#    - Debug a running pod:
#      https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
#    - kubectl logs:
#      https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/
#    - kubectl events:
#      https://kubernetes.io/docs/reference/kubectl/generated/kubectl_events/
# ============================================================================

set -euo pipefail

NS="pca-lab-3-2"
DEPLOY="cache-warmer"
IMAGE="busybox:1.36"

# --- Safety guardrails -------------------------------------------------------
# This lab MUTATES a cluster. It refuses to run against anything that smells
# like production. Override only if you are certain: FORCE=1 ./break-fix.sh
require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }; }
require kubectl

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: no reachable cluster. Point KUBECONFIG at a disposable lab cluster." >&2
  exit 1
fi

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
if [[ "${FORCE:-0}" != "1" && "$CTX" =~ (prod|production|live|prd) ]]; then
  echo "REFUSING to run: context '$CTX' looks like production." >&2
  echo "This lab is for a THROWAWAY cluster only. Re-run with FORCE=1 if you are sure." >&2
  exit 1
fi

banner() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

# --- Sub-commands ------------------------------------------------------------
cmd_clean() {
  banner "Tearing down lab namespace '$NS' ..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=true
  echo "Done. Cluster is back to its previous state."
}

cmd_verify() {
  banner "Checking whether you have fixed the workload ..."
  local ready
  ready="$(kubectl -n "$NS" get deploy "$DEPLOY" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  ready="${ready:-0}"
  if [[ "$ready" -ge 1 ]]; then
    printf '\033[1;32m  PASS ✔  %s has %s ready replica(s). The pod is Running and stable.\033[0m\n' "$DEPLOY" "$ready"
    echo "  You correctly used events + logs to locate and repair the root cause."
    exit 0
  else
    printf '\033[1;31m  NOT YET ✘  %s still has 0 ready replicas.\033[0m\n' "$DEPLOY"
    echo "  Keep going — read the events, then read the PREVIOUS container's logs."
    exit 1
  fi
}

cmd_break() {
  banner "Deploying the (intentionally) broken workload into namespace '$NS' ..."

  # Idempotent: apply, so re-running the break simply resets to the broken state.
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # The workload: a fake "cache warmer" that validates its own configuration on
  # boot. The env var MAX_CONNECTIONS is set to a bad value, so the process logs
  # a FATAL line to stderr and exits 78. The kubelet restarts it, over and over,
  # with exponential backoff -> CrashLoopBackOff.
  kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels: { app: ${DEPLOY} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${DEPLOY} }
  template:
    metadata:
      labels: { app: ${DEPLOY} }
    spec:
      containers:
      - name: ${DEPLOY}
        image: ${IMAGE}
        imagePullPolicy: IfNotPresent
        env:
        - name: MAX_CONNECTIONS
          value: "-1"            # <-- the planted defect. A student must find this.
        command: ["/bin/sh","-c"]
        args:
        - |
          echo "boot: cache-warmer v1.4 starting (pid \$\$)"
          echo "boot: reading configuration from environment"
          # Guard: MAX_CONNECTIONS must be a positive integer.
          if ! echo "\${MAX_CONNECTIONS}" | grep -Eq '^[0-9]+\$' || [ "\${MAX_CONNECTIONS}" -le 0 ]; then
            echo "FATAL: MAX_CONNECTIONS must be a positive integer, got '\${MAX_CONNECTIONS}'" >&2
            echo "hint: set it via an env var or ConfigMap and redeploy" >&2
            exit 78
          fi
          echo "ready: warming cache with \${MAX_CONNECTIONS} connections"
          exec sleep 3600
        resources:
          requests: { cpu: "10m", memory: "16Mi" }
          limits:   { cpu: "50m", memory: "32Mi" }
YAML

  banner "=============================  YOUR BRIEFING  ============================="
  cat <<BRIEF

  CONTEXT
    A Deployment called '${DEPLOY}' has just been rolled out to namespace
    '${NS}'. It never becomes Ready. Your on-call job: find out why and fix it,
    using ONLY the observability tooling — do not delete-and-pray.

  THE SYMPTOM YOU WILL SEE
    'kubectl -n ${NS} get pods' shows the pod cycling through:
        Running  ->  Error  ->  CrashLoopBackOff
    with a RESTARTS counter that keeps climbing. It never reaches 1/1 Ready.

  WHY THIS TOPIC
    The pod is dead by the time you look at it, so 'kubectl logs <pod>' returns
    the logs of the CURRENT (not-yet-crashed or empty) container. The evidence
    you need is split across the two observability planes:
      - EVENTS  will confirm the failure MODE  (BackOff, restart count, exit).
      - The PREVIOUS container's LOGS hold the failure CAUSE (the FATAL line).

  YOUR GOAL (definition of done)
    'kubectl -n ${NS} get deploy ${DEPLOY}' shows READY 1/1 and the pod stays
    Running with a stable RESTARTS count. You must fix the ROOT CAUSE — a
    configuration value — not mask it by removing the health check or the guard.

  WHEN YOU THINK YOU ARE DONE
    ./break-fix.sh verify      # grades you
    ./break-fix.sh clean       # removes the whole lab namespace

  START HERE (the two commands this topic exists to teach):
    kubectl -n ${NS} describe pod -l app=${DEPLOY}      # scroll to Events
    kubectl -n ${NS} logs -l app=${DEPLOY} --previous   # the crash log

BRIEF
  banner "=========================================================================="
}

case "${1:-break}" in
  break)  cmd_break  ;;
  verify) cmd_verify ;;
  clean)  cmd_clean  ;;
  *) echo "usage: $0 [break|verify|clean]" >&2; exit 2 ;;
esac

# ############################################################################
# #                                                                          #
# #   SOLUTION — step by step. Try the lab first; only unfold this after.    #
# #                                                                          #
# ############################################################################
#
# ----------------------------------------------------------------------------
# STEP 0 — Confirm the symptom
# ----------------------------------------------------------------------------
#   kubectl -n pca-lab-3-2 get pods
#
#   Expected (RESTARTS keeps growing on each poll):
#     NAME                            READY   STATUS             RESTARTS      AGE
#     cache-warmer-6c8f9b7d4d-4xk2p   0/1     CrashLoopBackOff   3 (25s ago)   90s
#
#   Reading it: 0/1 Ready, status CrashLoopBackOff. The "(25s ago)" is the time
#   since the LAST restart; the number is how many times the kubelet has already
#   restarted the container. CrashLoopBackOff is not an error itself — it is the
#   kubelet deliberately WAITING (exponential backoff, capped at 5 min) before
#   the next restart, to avoid a hot loop.
#
# ----------------------------------------------------------------------------
# STEP 1 — Read the EVENTS: confirm the failure MODE
# ----------------------------------------------------------------------------
#   kubectl -n pca-lab-3-2 describe pod -l app=cache-warmer
#
#   Scroll to the Events block at the bottom. Expected tail:
#     Type     Reason     Age                 From     Message
#     ----     ------     ----                ----     -------
#     Normal   Scheduled  2m                  ...      Successfully assigned ...
#     Normal   Pulled     2m (x4 over 2m)     kubelet  Container image "busybox:1.36" already present
#     Normal   Created    2m (x4 over 2m)     kubelet  Created container cache-warmer
#     Normal   Started    2m (x4 over 2m)     kubelet  Started container cache-warmer
#     Warning  BackOff    30s (x8 over 2m)    kubelet  Back-off restarting failed container
#
#   The stand-alone, TTL-bounded events feed (great for a namespace-wide view,
#   sorted, no object noise):
#     kubectl -n pca-lab-3-2 events --for pod/<pod-name> --types=Warning
#     kubectl -n pca-lab-3-2 get events --sort-by=.lastTimestamp
#
#   Also inspect the container's last termination — events summarise, this is
#   the machine-readable truth:
#     kubectl -n pca-lab-3-2 get pod -l app=cache-warmer \
#       -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
#     -> 78
#
#   Interpretation: the image pulls fine, the container STARTS fine, then it
#   exits non-zero and the kubelet backs off. So this is NOT ImagePullBackOff
#   and NOT a scheduling/quota problem. The container is running our code and
#   our code is choosing to die with exit 78. Events cannot tell you WHY it
#   chose to die — for that, read the logs.
#
# ----------------------------------------------------------------------------
# STEP 2 — Read the LOGS of the PREVIOUS container: find the CAUSE
# ----------------------------------------------------------------------------
#   The current container may be freshly (re)started or gone; the useful log is
#   the one from the instance that JUST crashed. The '--previous' / '-p' flag is
#   the whole point of this topic:
#
#   kubectl -n pca-lab-3-2 logs -l app=cache-warmer --previous --tail=20
#
#   Expected:
#     boot: cache-warmer v1.4 starting (pid 1)
#     boot: reading configuration from environment
#     FATAL: MAX_CONNECTIONS must be a positive integer, got '-1'
#     hint: set it via an env var or ConfigMap and redeploy
#
#   There it is. Without --previous you would often get an empty result or the
#   partial log of a container that has not failed yet — the #1 reason students
#   "can't find the error." (Note: --previous keeps working only while the
#   crashed container's log is still on the node; after enough restarts+GC it
#   may vanish, which is exactly why events + exit code are the durable record.)
#
# ----------------------------------------------------------------------------
# STEP 3 — Fix the ROOT CAUSE (a bad configuration value)
# ----------------------------------------------------------------------------
#   The defect is env MAX_CONNECTIONS="-1". Set a valid positive integer.
#   Any ONE of these is a correct, minimal fix:
#
#   (a) Imperative — patch the env var (triggers a rollout):
#       kubectl -n pca-lab-3-2 set env deployment/cache-warmer MAX_CONNECTIONS=100
#
#   (b) Declarative — edit and re-apply the manifest:
#       kubectl -n pca-lab-3-2 edit deployment/cache-warmer
#         # change:  value: "-1"   ->   value: "100"
#
#   (c) Strategic-merge patch:
#       kubectl -n pca-lab-3-2 patch deployment/cache-warmer --type=strategic -p \
#         '{"spec":{"template":{"spec":{"containers":[{"name":"cache-warmer","env":[{"name":"MAX_CONNECTIONS","value":"100"}]}]}}}}'
#
#   Do NOT "fix" it by scaling to 0, deleting the guard, or removing the pod —
#   that hides the fault instead of resolving it.
#
# ----------------------------------------------------------------------------
# STEP 4 — Confirm the fix through the same two planes
# ----------------------------------------------------------------------------
#   kubectl -n pca-lab-3-2 rollout status deploy/cache-warmer
#     -> deployment "cache-warmer" successfully rolled out
#
#   kubectl -n pca-lab-3-2 get pods
#     NAME                            READY   STATUS    RESTARTS   AGE
#     cache-warmer-7d9c5f6b8c-abcde   1/1     Running   0          20s
#
#   kubectl -n pca-lab-3-2 logs -l app=cache-warmer --tail=3
#     boot: cache-warmer v1.4 starting (pid 1)
#     boot: reading configuration from environment
#     ready: warming cache with 100 connections
#
#   ./break-fix.sh verify     # -> PASS
#
# ----------------------------------------------------------------------------
# THE TAKEAWAY
# ----------------------------------------------------------------------------
#   Events and logs answer different questions and neither replaces the other:
#     * Events (apiserver, ~1h TTL): WHAT the platform observed about the object
#       — scheduling, pulls, restarts, backoff, probe failures, OOMKills.
#     * Logs (kubelet, on the node): WHAT the process itself said — and for a
#       crashed container that means `--previous`.
#   Diagnosing a CrashLoopBackOff is the canonical exercise that forces you to
#   cross both planes: events prove it is crash-looping and give you the exit
#   code; the previous container's logs give you the sentence that explains why.
# ----------------------------------------------------------------------------