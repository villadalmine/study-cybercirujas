#!/usr/bin/env bash
#
# ==============================================================================
#  CNPA 4.1 — Kubernetes Reconciliation Loop and Control Plane Architecture
#  Break & Fix laboratory exercise
# ==============================================================================
#
#  WHAT THIS TEACHES
#  -----------------
#  The Kubernetes control plane is declarative: you write *desired state* to the
#  API server (it lands in etcd) and a set of independent controllers run an
#  endless reconciliation loop —  observe actual state -> diff against spec ->
#  act to close the gap -> repeat. Almost every built-in controller (Deployment,
#  ReplicaSet, Job, Node lifecycle, EndpointSlice, ServiceAccount, ...) lives in
#  a single binary: kube-controller-manager. On a kubeadm cluster that binary
#  runs as a *static pod*, meaning the kubelet — itself a reconciler — starts and
#  stops it purely from a file in /etc/kubernetes/manifests.
#
#  This script removes the kube-controller-manager static pod manifest. That
#  halts every reconciliation loop *without touching the API server, scheduler,
#  etcd or your workloads*, so the cluster stays reachable and the break is
#  fully reversible. You will see writes succeed but never converge.
#
#  SAFE / CONTROLLED / REVERSIBLE
#  ------------------------------
#    * Only the controller-manager manifest is moved (backed up, not deleted).
#    * API server, etcd, scheduler and the kubelet keep running.
#    * `bash break_fix.sh restore` puts everything back.
#
#  RUN THIS ONLY ON A DISPOSABLE SINGLE-NODE KUBEADM LAB VM.
#
#  Usage:
#     sudo bash break_fix.sh          # break it (default) and print the mission
#     sudo bash break_fix.sh status   # inspect current control-plane state
#     sudo bash break_fix.sh restore  # undo the break (the exam-style fix)
#
#  Source: CNCF CNPA Curriculum — https://github.com/cncf/curriculum
#          Static Pods — https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
#          kube-controller-manager —
#          https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
# ==============================================================================

set -uo pipefail   # NOT -e: we deliberately run commands that are expected to fail

# ------------------------------- configuration --------------------------------
MANIFEST_DIR="/etc/kubernetes/manifests"
TARGET="kube-controller-manager.yaml"
SRC_MANIFEST="${MANIFEST_DIR}/${TARGET}"
BACKUP_DIR="/root/cnpa-4.1-lab-backup"
BACKUP_MANIFEST="${BACKUP_DIR}/${TARGET}"

NS="cnpa41"
DEPLOY="web"
REPLICAS=3
# pause is already cached on any kubeadm node (used as the sandbox image), so the
# demo works fully offline and pods become Ready instantly.
IMAGE="registry.k8s.io/pause:3.9"

KUBECTL="${KUBECTL:-kubectl}"

# --------------------------------- helpers ------------------------------------
c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'
c_blu=$'\033[0;34m'; c_bold=$'\033[1m';   c_off=$'\033[0m'

log()  { printf '%s[*]%s %s\n' "$c_blu" "$c_off" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

need_root() { [ "$(id -u)" -eq 0 ] || die "Run as root (sudo): the manifest lives in ${MANIFEST_DIR}."; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH."; }

preflight() {
  need_root
  need_cmd "${KUBECTL%% *}"
  "$KUBECTL" version >/dev/null 2>&1 || die "kubectl cannot reach the API server. Fix cluster access first."
  # Confirm this is a kubeadm control-plane node, not a random box or a worker.
  [ -d "$MANIFEST_DIR" ] || die "${MANIFEST_DIR} does not exist — this is not a kubeadm control-plane node."
  ls "$MANIFEST_DIR"/kube-apiserver.yaml >/dev/null 2>&1 \
    || die "No static control-plane pods under ${MANIFEST_DIR}. Refusing to run on a non-lab node."
}

confirm() {
  [ "${FORCE:-0}" = "1" ] && return 0
  warn "This will stop the reconciliation loop on THIS node (kube-controller-manager)."
  warn "Only do this on a DISPOSABLE lab VM."
  printf 'Type %sBREAK%s to continue: ' "$c_bold" "$c_off"
  read -r ans
  [ "$ans" = "BREAK" ] || die "Aborted by user."
}

cm_pod_present() {
  # A running/pending mirror pod for the controller-manager in kube-system.
  "$KUBECTL" -n kube-system get pods -l component=kube-controller-manager \
    --no-headers 2>/dev/null | grep -q .
}

ensure_demo() {
  log "Ensuring the demo workload exists (namespace ${NS}, deployment ${DEPLOY})..."
  "$KUBECTL" get ns "$NS" >/dev/null 2>&1 || "$KUBECTL" create ns "$NS" >/dev/null
  if ! "$KUBECTL" -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1; then
    "$KUBECTL" -n "$NS" create deployment "$DEPLOY" --image="$IMAGE" --replicas="$REPLICAS" >/dev/null
  else
    "$KUBECTL" -n "$NS" scale deployment "$DEPLOY" --replicas="$REPLICAS" >/dev/null
  fi
  log "Waiting for the deployment to converge while the controller is still healthy..."
  "$KUBECTL" -n "$NS" rollout status deployment "$DEPLOY" --timeout=90s >/dev/null 2>&1 || true
  "$KUBECTL" -n "$NS" get deploy "$DEPLOY"
}

# --------------------------------- actions ------------------------------------
do_status() {
  hr; log "Control-plane static pods (${MANIFEST_DIR}):"
  ls -1 "$MANIFEST_DIR" 2>/dev/null | sed 's/^/    /'
  hr; log "kube-controller-manager pod:"
  if cm_pod_present; then
    "$KUBECTL" -n kube-system get pods -l component=kube-controller-manager
  else
    warn "NOT running."
  fi
  hr; log "Leader-election lease (renewTime goes stale when the controller is down):"
  "$KUBECTL" -n kube-system get lease kube-controller-manager \
    -o custom-columns=HOLDER:.spec.holderIdentity,RENEWED:.spec.renewTime 2>/dev/null \
    || warn "lease not found"
  hr; log "Demo workload:"
  "$KUBECTL" -n "$NS" get deploy,rs,pods 2>/dev/null || warn "demo not created yet"
  hr
}

do_break() {
  preflight
  ensure_demo
  confirm

  [ -f "$SRC_MANIFEST" ] || die "${SRC_MANIFEST} not found — is it already broken? Try: bash $0 status"
  mkdir -p "$BACKUP_DIR"
  log "Backing up and removing the controller-manager static pod manifest..."
  mv -f "$SRC_MANIFEST" "$BACKUP_MANIFEST" || die "Could not move ${SRC_MANIFEST}."
  ok "Manifest moved to ${BACKUP_MANIFEST}"

  log "Waiting for the kubelet to tear down the static pod..."
  for _ in $(seq 1 30); do
    cm_pod_present || break
    sleep 2
  done
  if cm_pod_present; then
    warn "Pod still visible; the kubelet should remove it within ~20s. Continuing."
  else
    ok "kube-controller-manager is gone. The reconciliation loop is now DOWN."
  fi

  # Perturb the actual state so the missing reconciliation becomes observable:
  # delete one Pod (the ReplicaSet controller would normally re-create it).
  victim="$("$KUBECTL" -n "$NS" get pods -l app="$DEPLOY" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -n "${victim:-}" ]; then
    log "Deleting one pod (${victim}) to expose the halted loop..."
    "$KUBECTL" -n "$NS" delete pod "$victim" --wait=false >/dev/null 2>&1 || true
  fi

  hr
  printf '%s%sBREAK COMPLETE — YOUR MISSION%s\n' "$c_bold" "$c_red" "$c_off"
  hr
  cat <<EOF
SYMPTOM you will observe
  * The cluster is fully reachable; the API server still accepts every write.
  * But desired state no longer converges to actual state. Concretely:

      $ ${KUBECTL} -n ${NS} get deploy ${DEPLOY}
      NAME   READY   UP-TO-DATE   AVAILABLE   AGE
      ${DEPLOY}    2/3     3            2         5m      <- stuck below desired

      $ ${KUBECTL} -n ${NS} get pods
      NAME                   READY   STATUS    RESTARTS   AGE
      ${DEPLOY}-xxxxxxxxx-aaaaa   1/1     Running   0          5m
      ${DEPLOY}-xxxxxxxxx-bbbbb   1/1     Running   0          5m
                                                    <- the deleted pod is NEVER recreated

  * Try to scale — the write succeeds but nothing happens:

      $ ${KUBECTL} -n ${NS} scale deployment ${DEPLOY} --replicas=6
      deployment.apps/${DEPLOY} scaled
      $ ${KUBECTL} -n ${NS} get pods        # still stuck, no new pods appear

GOAL
  Restore the reconciliation loop so the Deployment converges back to its
  desired replica count on its own — WITHOUT manually creating any Pod.
  Manually spawning pods is treating the symptom; find and fix the control-plane
  component whose job is to do that for you.

HINTS (peek only if stuck)
  * Is this a workload problem or a control-plane problem? Compare
      ${KUBECTL} -n ${NS} describe deploy ${DEPLOY}   (any scaling events lately?)
    with
      ${KUBECTL} -n kube-system get pods | grep controller-manager
  * Which component runs the Deployment/ReplicaSet loops, and how is it launched
    on a kubeadm node? (Think: static pod, kubelet, ${MANIFEST_DIR}.)
  * Inspect the leader lease: ${KUBECTL} -n kube-system get lease kube-controller-manager -o yaml

Run  'bash $0 status'  to inspect, or  'bash $0 restore'  to auto-fix.
EOF
  hr
}

do_restore() {
  need_root
  if [ -f "$SRC_MANIFEST" ]; then
    ok "Manifest already present at ${SRC_MANIFEST}; nothing to restore."
  else
    [ -f "$BACKUP_MANIFEST" ] || die "No backup at ${BACKUP_MANIFEST}. Cannot restore automatically."
    log "Restoring the controller-manager static pod manifest..."
    mv -f "$BACKUP_MANIFEST" "$SRC_MANIFEST" || die "Restore failed."
    ok "Manifest restored. The kubelet will re-create the static pod shortly."
  fi
  log "Waiting for kube-controller-manager to come back up..."
  for _ in $(seq 1 45); do
    cm_pod_present && break
    sleep 2
  done
  cm_pod_present && ok "kube-controller-manager is Running again." \
                 || warn "Still not up; check 'journalctl -u kubelet' and the manifest YAML."
  log "The Deployment should now reconcile back to ${REPLICAS} replicas on its own:"
  "$KUBECTL" -n "$NS" rollout status deployment "$DEPLOY" --timeout=90s 2>/dev/null || true
  "$KUBECTL" -n "$NS" get deploy "$DEPLOY" 2>/dev/null || true
}

# ---------------------------------- main --------------------------------------
case "${1:-break}" in
  break|"") do_break   ;;
  restore)  do_restore ;;
  status)   preflight; do_status ;;
  *) die "Unknown command '$1'. Use: break | status | restore" ;;
esac

# ==============================================================================
#  SOLUTION — step by step (read only after you have tried it yourself)
# ==============================================================================
#
#  1. Separate symptom from cause. The workload is healthy but under-provisioned,
#     and a deleted pod is never replaced — classic sign that the *controller*,
#     not the Pod, is at fault:
#
#         kubectl -n cnpa41 get deploy web         # READY 2/3, stuck
#         kubectl -n cnpa41 delete pod <one>
#         sleep 10; kubectl -n cnpa41 get pods     # deleted pod NOT recreated
#         kubectl -n cnpa41 describe deploy web     # no recent scale/replica events
#
#  2. Localise it to the control plane. The binary that owns the Deployment and
#     ReplicaSet reconciliation loops is kube-controller-manager:
#
#         kubectl -n kube-system get pods | grep controller-manager
#           -> (no rows) : the controller-manager pod is gone
#
#         kubectl -n kube-system get lease kube-controller-manager -o yaml
#           -> spec.renewTime is stale : the holder stopped renewing its leader
#              lease, i.e. no active controller-manager exists to lead.
#
#         kubectl get events -A --sort-by=.lastTimestamp | tail
#           -> no "Scaled up replica set" / "Created pod" events after the break.
#
#  3. Explain WHY it is gone. On a kubeadm cluster the control-plane components
#     are *static pods*: the kubelet watches /etc/kubernetes/manifests and keeps
#     one pod running per YAML file there — the kubelet is itself a reconciler.
#     Remove the file and the kubelet dutifully removes the pod:
#
#         ls -l /etc/kubernetes/manifests/
#           -> kube-controller-manager.yaml is MISSING
#         journalctl -u kubelet | grep -i controller-manager | tail
#           -> kubelet reporting the static pod was removed
#
#  4. Fix: put the manifest back. The kubelet detects the new file (inotify;
#     falls back to a periodic sync ~20s) and recreates the static pod. No
#     'systemctl', no 'kubectl apply' — the file IS the desired state:
#
#         mv /root/cnpa-4.1-lab-backup/kube-controller-manager.yaml \
#            /etc/kubernetes/manifests/kube-controller-manager.yaml
#
#         # equivalent to:  bash break_fix.sh restore
#
#  5. Verify convergence — do NOT create pods by hand:
#
#         kubectl -n kube-system get pods | grep controller-manager   # Running
#         kubectl -n kube-system get lease kube-controller-manager     # renewTime advancing
#         kubectl -n cnpa41 get pods -w                                # replicas climb to desired
#         kubectl -n cnpa41 get deploy web                             # READY 3/3 again
#
#  WHY IT WORKS (the mental model the exam wants)
#  ----------------------------------------------
#  Kubernetes is level-triggered, not edge-triggered. The API server + etcd only
#  *store* desired state; convergence is done by controllers each running:
#        for { observed := informer.Get(); if observed != desired { act() } }
#  kube-controller-manager hosts those loops for the built-in resources. With it
#  down the API still accepts writes (scale, delete) but no loop reads the diff,
#  so actual state freezes. Because Kubernetes is level-triggered, you do not
#  have to replay the missed events after the fix: the moment the controller
#  restarts, its next observation sees "have 2, want 3" and it simply acts —
#  the whole backlog reconciles automatically. And the reason a single 'mv'
#  suffices is the layered reconciliation: the kubelet reconciles static pods
#  from files, and kube-controller-manager reconciles workloads from etcd.
# ==============================================================================