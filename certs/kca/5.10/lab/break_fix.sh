#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Topic 5.10 : Cleanup Policies
#  Break & Fix lab  ·  Kubernetes garbage collection / finalizers
# ============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  Kubernetes never deletes an object the instant you ask. Deletion is a
#  *policy*, driven by three cleanup mechanisms:
#
#    1. Finalizers        — pre-deletion hooks. While an object carries a
#                           finalizer, the API server sets .metadata.deletion-
#                           Timestamp but KEEPS the object until every finalizer
#                           is cleared. This is the cleanup policy we break here.
#    2. Owner references  — cascading deletion (Foreground / Background / Orphan)
#                           and the garbage collector reaping orphaned children.
#    3. TTL / history     — ttlSecondsAfterFinished on Jobs, and CronJob
#                           successfulJobsHistoryLimit / failedJobsHistoryLimit.
#
#  This script BREAKS mechanism #1 in a controlled way: it plants an orphan
#  finalizer on a throwaway Pod so that a normal `kubectl delete` hangs and the
#  Pod is wedged in `Terminating` forever. Nothing outside the `cleanup-lab`
#  namespace is touched.
#
#  RUN ONLY ON A DISPOSABLE LAB VM / THROWAWAY CLUSTER. It is destructive by
#  design. Guarded so it will not fire against a production context.
#
#  Usage:   KCA_LAB_CONFIRM=yes ./5.10-cleanup-policies-breakfix.sh
#
#  Sources (official):
#    - Finalizers ............... https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
#    - Garbage collection ....... https://kubernetes.io/docs/concepts/architecture/garbage-collection/
#    - Cascading deletion ....... https://kubernetes.io/docs/tasks/administer-cluster/use-cascading-deletion/
#    - TTL after finished ....... https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/
#    - Job auto-cleanup ......... https://kubernetes.io/docs/concepts/workloads/controllers/job/#clean-up-finished-jobs-automatically
#    - CronJob history limits ... https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
# ============================================================================

set -euo pipefail

NS="cleanup-lab"
POD="stuck-pod"
FINALIZER="lab.example.com/hold"

log()  { printf '\033[1;34m[lab ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[stop]\033[0m %s\n' "$*" >&2; exit 1; }
rule() { printf '\033[1;30m%s\033[0m\n' "----------------------------------------------------------------------"; }

# --- 0. Guardrails ----------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."

kubectl get --raw='/healthz' >/dev/null 2>&1 \
  || die "Cannot reach a cluster. Point KUBECONFIG at your disposable lab VM first."

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
case "$CTX" in
  *prod*|*production*|*prd*)
    die "Context '$CTX' looks like production. This lab is destructive; run it only on a throwaway cluster." ;;
esac

if [ "${KCA_LAB_CONFIRM:-}" != "yes" ]; then
  die "Refusing to run unconfirmed. This will wedge a Pod in Terminating.
       Re-run on a disposable VM with:  KCA_LAB_CONFIRM=yes $0
       Current context: $CTX"
fi

log "Target context : $CTX"
log "Target namespace: $NS  (nothing outside it is modified)"
rule

# --- 1. Reset any previous run (idempotent) --------------------------------
log "Resetting any leftover state from a prior run ..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Clear a possibly-wedged finalizer from a previous attempt, then remove the Pod.
kubectl -n "$NS" patch pod "$POD" --type=merge \
  -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true

# --- 2. Create a healthy, disposable Pod -----------------------------------
log "Creating a throwaway Pod '$POD' ..."
kubectl -n "$NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: stuck-pod
  labels:
    app: cleanup-lab
spec:
  terminationGracePeriodSeconds: 5
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.9
      resources:
        requests: { cpu: "10m", memory: "16Mi" }
        limits:   { cpu: "50m", memory: "32Mi" }
YAML

log "Waiting for the Pod to become Ready ..."
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=60s >/dev/null

# --- 3. THE BREAK: plant an orphan finalizer, then request deletion ---------
log "Injecting an orphan finalizer '$FINALIZER' (no controller will ever clear it) ..."
kubectl -n "$NS" patch pod "$POD" --type=merge \
  -p "{\"metadata\":{\"finalizers\":[\"$FINALIZER\"]}}" >/dev/null

log "Requesting deletion (non-blocking) — this is where the cleanup policy jams ..."
kubectl -n "$NS" delete "pod/$POD" --wait=false >/dev/null

sleep 3
rule
log "Current state of the Pod:"
kubectl -n "$NS" get "pod/$POD" -o wide || true
rule

# --- 4. Student briefing ----------------------------------------------------
cat <<EOF

========================= BREAK & FIX : YOUR TURN ==========================

SYMPTOM YOU WILL OBSERVE
------------------------
  * The Pod '$POD' is stuck with STATUS = Terminating and never disappears.
  * A plain \`kubectl -n $NS delete pod $POD\` hangs indefinitely (it is
    waiting for a deletion that the cleanup policy will never complete).
  * The object already carries a .metadata.deletionTimestamp — the API server
    ACCEPTED the delete, but it will not remove the object while a finalizer
    remains. This is deletion-as-policy, not deletion-on-demand.

  Confirm it yourself:
      kubectl -n $NS get pod $POD
      kubectl -n $NS get pod $POD -o jsonpath='{.metadata.deletionTimestamp}{"\n"}'
      kubectl -n $NS get pod $POD -o jsonpath='{.metadata.finalizers}{"\n"}'

WHAT YOU MUST ACHIEVE
---------------------
  Make the Pod actually go away — i.e. let the cleanup policy complete — so
  that \`kubectl -n $NS get pod $POD\` returns "NotFound".

  Think about WHY it is stuck before you force anything:
    - Which finalizer is blocking it?
    - Is there any controller in this cluster that owns
      '$FINALIZER' and is expected to remove it? (There isn't — it is an
      orphan you planted, which is exactly the real-world failure mode when a
      CRD/operator that installed a finalizer has been uninstalled.)
    - The correct cleanup is to clear the blocking finalizer, NOT to
      \`--force --grace-period=0\` (force skips the kubelet handshake but does
      NOT bypass finalizers, so it will still hang).

  When you have fixed it, tear the lab down cleanly:
      kubectl delete namespace $NS

  The full step-by-step solution is at the very bottom of this script,
  commented out. Try it on your own first.

============================================================================
EOF

exit 0

# ============================================================================
#  SOLUTION  (commented — read only after you have tried)
# ============================================================================
#
#  STEP 1 — Diagnose: prove it is a finalizer, not a slow kubelet.
#  --------------------------------------------------------------
#     kubectl -n cleanup-lab get pod stuck-pod
#       # NAME        READY   STATUS        RESTARTS   AGE
#       # stuck-pod   1/1     Terminating   0          30s
#
#     kubectl -n cleanup-lab get pod stuck-pod \
#       -o jsonpath='{.metadata.deletionTimestamp}{"\n"}{.metadata.finalizers}{"\n"}'
#       # 2026-08-13T12:00:00Z
#       # ["lab.example.com/hold"]
#
#     A deletionTimestamp IS set (delete was accepted) but the object survives
#     because a finalizer is still present. That is the cleanup policy at work:
#     "do not garbage-collect until every finalizer has been satisfied."
#
#  STEP 2 — Confirm nobody owns the finalizer.
#  -------------------------------------------
#     There is no controller/operator watching for 'lab.example.com/hold', so
#     it will never be removed automatically. In production the right first
#     move is to REINSTALL or REPAIR the controller that owns the finalizer, so
#     it can run its real cleanup (drain storage, deregister from a cloud LB,
#     etc.). Only when you are certain no cleanup is owed do you strip it by
#     hand — force-removing a finalizer whose controller still has work to do
#     leaks the external resource it was protecting.
#
#  STEP 3 — Clear the blocking finalizer (the actual fix).
#  -------------------------------------------------------
#     Merge patch (set the list to null / empty):
#       kubectl -n cleanup-lab patch pod stuck-pod \
#         --type=merge -p '{"metadata":{"finalizers":null}}'
#
#     Equivalent JSON-patch form (remove the specific entry):
#       kubectl -n cleanup-lab patch pod stuck-pod --type=json \
#         -p='[{"op":"remove","path":"/metadata/finalizers/0"}]'
#
#     The moment the last finalizer is gone AND a deletionTimestamp is present,
#     the API server completes the delete immediately.
#
#  STEP 4 — Verify the cleanup completed.
#  --------------------------------------
#       kubectl -n cleanup-lab get pod stuck-pod
#       # Error from server (NotFound): pods "stuck-pod" not found
#
#  STEP 5 — Tear down the lab.
#  ---------------------------
#       kubectl delete namespace cleanup-lab
#
#  WHY `--force` IS THE WRONG TOOL HERE
#  ------------------------------------
#     kubectl -n cleanup-lab delete pod stuck-pod --grace-period=0 --force
#     still hangs: --force only skips the graceful kubelet shutdown handshake;
#     it does not remove finalizers. Finalizers are cleared by editing the
#     object (patch/edit), never by the delete verb.
#
#  THE OTHER CLEANUP POLICIES (same family, worth knowing for 5.10)
#  ---------------------------------------------------------------
#   * Cascading deletion via ownerReferences — pick the propagation policy:
#       kubectl delete deploy web --cascade=background   # default: children
#                                                        # reaped async by GC
#       kubectl delete deploy web --cascade=foreground   # blocks until every
#                                                        # child is gone first
#       kubectl delete deploy web --cascade=orphan       # keep the ReplicaSet
#                                                        # / Pods, drop owner
#     A ReplicaSet/Pod left with a dangling ownerReference is exactly what the
#     garbage collector cleans up — the inverse of the finalizer jam above.
#
#   * TTL-after-finished for Jobs (auto-delete completed Jobs + their Pods):
#       spec:
#         ttlSecondsAfterFinished: 60   # object is GC'd 60s after it finishes
#     Docs: https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/
#
#   * CronJob history retention (bounds accumulated Jobs/Pods):
#       spec:
#         successfulJobsHistoryLimit: 3   # default 3
#         failedJobsHistoryLimit: 1       # default 1
#     Set either to 0 to keep no history. A too-high limit is a classic
#     "why are there 400 Completed pods?" incident.
#     Docs: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
#
#  Finalizers reference:
#    https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
#  Garbage collection reference:
#    https://kubernetes.io/docs/concepts/architecture/garbage-collection/
# ============================================================================