#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Kubernetes Certified Associate
#  Domain 2: Cluster Architecture, Installation & Configuration
#  Topic 2.3 — Controller Configuration with Flags   (exam weight: 3.0)
# ============================================================================
#
#  BREAK & FIX LAB  —  "The green control plane that silently stops working"
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  On a DISPOSABLE kubeadm lab VM it edits the kube-controller-manager static
#  Pod manifest and adds a single flag that disables ONE controller loop
#  (the Job controller) via the --controllers flag, while leaving the
#  kube-controller-manager process itself perfectly healthy and Running.
#
#  This is the whole point of topic 2.3: kube-controller-manager is not a
#  monolith, it is a bag of independent control loops (deployment, replicaset,
#  job, cronjob, endpointslice, garbagecollector, nodelifecycle, ...) and the
#  --controllers flag decides which of them are started. A one-character typo
#  in that flag can switch off an entire Kubernetes subsystem with zero errors,
#  zero crashes and a Pod that stays 1/1 Running. Every dashboard is green and
#  yet Jobs never run. Learning to correlate "a specific kind of object never
#  gets acted upon" with "a controller flag" is the skill under test.
#
#  This is SAFE and fully reversible: it does not crash the API server, does
#  not touch etcd, does not delete data, and a pristine backup of the manifest
#  is kept outside the manifests directory so the fix is a one-line restore.
#
#  Official references (read these):
#   - kube-controller-manager flags:
#     https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
#   - Controllers (the control-loop model):
#     https://kubernetes.io/docs/concepts/architecture/controller/
#   - Static Pods (how the control plane is configured on kubeadm):
#     https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
#   - Jobs (the object our disabled controller is responsible for):
#     https://kubernetes.io/docs/concepts/workloads/controllers/job/
# ============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
MANIFEST="/etc/kubernetes/manifests/kube-controller-manager.yaml"
BACKUP_DIR="/var/lib/kca-lab/2.3"
PRISTINE="${BACKUP_DIR}/kube-controller-manager.yaml.orig"
NS="kca-lab-2-3"
JOB="kca-demo-job"
BROKEN_CONTROLLER="job"                    # the control loop we switch off
KCM_LABEL="component=kube-controller-manager"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
banner() { printf '\n\033[1;33m=== %s ===\033[0m\n' "$*"; }
info()   { printf '  \033[0;36m%s\033[0m\n' "$*"; }
warn()   { printf '  \033[0;33m! %s\033[0m\n' "$*"; }
die()    { printf '\n\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Safety guardrails — refuse to run anywhere that might not be a throwaway VM
# --------------------------------------------------------------------------
banner "Safety checks"

[ "$(id -u)" -eq 0 ] || die "must run as root (it edits /etc/kubernetes/manifests)."

if [ "${KCA_LAB_CONFIRM:-}" != "yes" ]; then
  die "refusing to run without confirmation.
     This modifies the control plane. Run ONLY on a disposable lab VM:

         KCA_LAB_CONFIRM=yes $0
"
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
[ -f "$MANIFEST" ] || die "static Pod manifest not found: $MANIFEST
     This lab targets a kubeadm control-plane node."
kubectl get --raw='/readyz?verbose' >/dev/null 2>&1 || kubectl get nodes >/dev/null 2>&1 \
  || die "kubectl cannot reach a healthy API server."

info "Root: yes.  kubeadm manifest: found.  API server: reachable."

# --------------------------------------------------------------------------
# Backup (idempotent: keep a pristine copy exactly once)
# --------------------------------------------------------------------------
banner "Backing up the original manifest"
mkdir -p "$BACKUP_DIR"
if [ ! -f "$PRISTINE" ]; then
  cp -a "$MANIFEST" "$PRISTINE"
  info "Pristine copy saved: $PRISTINE"
else
  info "Pristine copy already exists (kept): $PRISTINE"
fi
# Always keep a timestamped snapshot too, for auditability.
cp -a "$MANIFEST" "${BACKUP_DIR}/kube-controller-manager.yaml.$(date +%Y%m%d-%H%M%S).bak"

# --------------------------------------------------------------------------
# Apply the break: disable the "job" controller via the --controllers flag
#
#   --controllers accepts a comma list. "*" means "all controllers that are
#   on by default"; prefixing a name with "-" turns that single one off.
#   So "*,-job" == everything as usual, EXCEPT the Job controller.
# --------------------------------------------------------------------------
banner "Injecting the fault into the --controllers flag"

if grep -Eo -- '--controllers=[^[:space:]"]+' "$MANIFEST" | grep -qF -- "-${BROKEN_CONTROLLER}"; then
  info "Fault already present (job controller already disabled). Nothing to change."
elif grep -q -- '--controllers=' "$MANIFEST"; then
  # A --controllers flag already exists: append our disable to it.
  sed -i -E "s#(--controllers=[^[:space:]\"]+)#\\1,-${BROKEN_CONTROLLER}#" "$MANIFEST"
  info "Appended ',-${BROKEN_CONTROLLER}' to the existing --controllers flag."
else
  # No --controllers flag (the kubeadm default): insert one right after the
  # container command binary line, matching its indentation.
  TMP="$(mktemp)"
  awk -v ctrl="$BROKEN_CONTROLLER" '
    /- kube-controller-manager$/ && !done {
      print
      match($0, /^[[:space:]]*/)
      indent = substr($0, 1, RLENGTH)
      print indent "- --controllers=*,-" ctrl
      done = 1
      next
    }
    { print }
  ' "$MANIFEST" > "$TMP"
  cat "$TMP" > "$MANIFEST"      # preserve original perms/owner of the manifest
  rm -f "$TMP"
  info "Inserted new flag:  - --controllers=*,-${BROKEN_CONTROLLER}"
fi

# --------------------------------------------------------------------------
# Wait for the kubelet to restart the static Pod with the new configuration
# --------------------------------------------------------------------------
banner "Waiting for the kubelet to reload the static Pod"
info "The kubelet watches $MANIFEST and recreates the Pod automatically..."
ok=""
for _ in $(seq 1 30); do
  if kubectl -n kube-system get pods -l "$KCM_LABEL" \
       -o jsonpath='{range .items[*]}{.spec.containers[0].command}{"\n"}{end}' 2>/dev/null \
     | grep -qF -- "--controllers=*,-${BROKEN_CONTROLLER}"; then
    ok="yes"; break
  fi
  sleep 2
done
if [ -n "$ok" ]; then
  info "kube-controller-manager is Running again — WITH the fault, and looking healthy."
else
  warn "Could not confirm the new flag within timeout; check the Pod manually:"
  warn "  kubectl -n kube-system get pods -l $KCM_LABEL"
fi

# --------------------------------------------------------------------------
# Deploy the demonstrator: a trivial Job that should finish in seconds
# --------------------------------------------------------------------------
banner "Deploying a demonstrator Job that SHOULD complete"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kca-demo-job
  namespace: kca-lab-2-3
spec:
  backoffLimit: 2
  completions: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sh", "-c", "echo 'work done by the Job controller'; sleep 2"]
EOF
info "Job '$JOB' created in namespace '$NS'."

# --------------------------------------------------------------------------
# Brief the student
# --------------------------------------------------------------------------
cat <<EOF

============================================================================
  YOUR LAB IS NOW BROKEN.  Here is what you will observe and what you must fix.
============================================================================

THE SYMPTOM
-----------
  * The control plane looks 100% healthy. Prove it and be misled:
        kubectl -n kube-system get pods -l ${KCM_LABEL}
        kubectl get componentstatuses     # (or: kubectl get --raw='/readyz')
    kube-controller-manager is Running, Ready 1/1, no restarts, no errors.

  * Yet the Job you just created never runs. Watch it stay stuck at 0/1:
        kubectl -n ${NS} get job ${JOB}
        kubectl -n ${NS} get pods
    -> There is NO Pod. COMPLETIONS stays 0/1 forever.

  * 'describe' shows the object exists but nothing ever acted on it — there is
    no "SuccessfulCreate" event, because the loop that would create the Pod
    is not running:
        kubectl -n ${NS} describe job ${JOB}

  This is the trap of topic 2.3: the API server accepted the Job, etcd stored
  it, every health probe is green — but one control loop inside
  kube-controller-manager was switched off by a flag, so a whole class of
  objects is silently ignored.

WHAT YOU MUST ACHIEVE (definition of "fixed")
---------------------------------------------
  Make the Job controller run again WITHOUT recreating the cluster, until:

        kubectl -n ${NS} get job ${JOB}
    shows   COMPLETIONS  1/1   and a Pod reached STATUS 'Completed'.

  You are NOT allowed to "cheat" by manually creating the Pod yourself. The
  goal is to restore the controller, not to do its job by hand.

HINTS (try before revealing the solution at the bottom of this script)
----------------------------------------------------------------------
  1. If a specific KIND of object is ignored while the control plane is healthy,
     suspect the controller responsible for that kind — and the --controllers flag.
  2. Inspect the flags the running controller-manager was actually started with:
        kubectl -n kube-system get pods -l ${KCM_LABEL} \\
          -o jsonpath='{.items[0].spec.containers[0].command}' ; echo
  3. Read its logs — a disabled controller is simply never "Started":
        kubectl -n kube-system logs -l ${KCM_LABEL} | grep -i 'controller'
  4. The truth lives in the static Pod manifest on this node:
        grep -n controllers ${MANIFEST}

  When you are done experimenting, scroll to the very bottom of this file for
  the full step-by-step solution.
============================================================================
EOF

exit 0

# ############################################################################
# #                                                                          #
# #   SOLUTION  —  do not read until you have diagnosed it yourself.         #
# #                                                                          #
# ############################################################################
#
# ROOT CAUSE
# ----------
#   The kube-controller-manager static Pod was started with the flag:
#
#       --controllers=*,-job
#
#   "*" enables every controller that is on by default; "-job" then subtracts
#   the Job controller. The process is healthy because ALL the other loops
#   (deployment, replicaset, endpointslice, garbagecollector, nodelifecycle,
#   serviceaccount, ...) started normally. Only the loop that turns a Job
#   object into a Pod was never launched, so Jobs are accepted but never acted
#   on. No crash, no error, no failing probe — just one dead subsystem.
#
# DIAGNOSIS (the reasoning to reproduce)
# --------------------------------------
#   1. Jobs are stuck, but Deployments/Services/etc. still work  -> not a
#      global control-plane outage, it is scoped to ONE object kind.
#   2. The object kind (Job) maps to one controller (the "job" controller),
#      which lives inside kube-controller-manager.
#   3. kube-controller-manager Pod is Running/Ready, so the process is fine —
#      the loop itself must have been turned off. That is exactly what the
#      --controllers flag does.
#   4. Confirm which flags it really got, straight from the running Pod spec:
#
#        kubectl -n kube-system get pods -l component=kube-controller-manager \
#          -o jsonpath='{.items[0].spec.containers[0].command}' ; echo
#
#      You will see the smoking gun: "--controllers=*,-job".
#
#      And in the logs, the "job" controller is simply absent from the
#      "Started \"...\" controller" lines the others print at boot:
#
#        kubectl -n kube-system logs -l component=kube-controller-manager \
#          | grep -iE 'Started .* controller|is disabled'
#
# FIX (option A — precise edit, the exam-realistic path)
# ------------------------------------------------------
#   Edit the static Pod manifest and remove the fault. Either delete the whole
#   line, or set the flag back to the default of all controllers ("*"):
#
#        sudo vi /etc/kubernetes/manifests/kube-controller-manager.yaml
#          # delete the line:   - --controllers=*,-job
#          # (equivalently, set it to:   - --controllers=*   )
#
#   Save and exit. Do NOT restart anything by hand: the kubelet watches the
#   manifests directory, notices the change, and automatically recreates the
#   kube-controller-manager static Pod with the corrected flags.
#
# FIX (option B — restore the pristine backup this script kept)
# -------------------------------------------------------------
#        sudo cp -a /var/lib/kca-lab/2.3/kube-controller-manager.yaml.orig \
#                   /etc/kubernetes/manifests/kube-controller-manager.yaml
#
# VERIFY THE FIX
# --------------
#   1. Controller-manager came back with the clean flag (no ",-job"):
#
#        kubectl -n kube-system get pods -l component=kube-controller-manager \
#          -o jsonpath='{.items[0].spec.containers[0].command}' ; echo
#
#   2. The Job controller now does its work — a Pod appears and completes:
#
#        kubectl -n kca-lab-2-3 get job kca-demo-job -w
#        # COMPLETIONS goes 0/1 -> 1/1
#        kubectl -n kca-lab-2-3 get pods
#        # STATUS: Completed
#
#      (If the Job had already exceeded backoffLimit while broken, just
#       re-apply it — the point is that new Jobs now run:
#        kubectl -n kca-lab-2-3 delete job kca-demo-job --ignore-not-found
#        kubectl -n kca-lab-2-3 create job kca-demo-job --image=busybox:1.36 \
#          -- sh -c 'echo fixed; sleep 2' )
#
# CLEAN UP THE LAB
# ----------------
#        kubectl delete namespace kca-lab-2-3
#
# KEY TAKEAWAYS FOR THE EXAM
# --------------------------
#   * kube-controller-manager is a collection of independent control loops;
#     --controllers=<list> selects which ones run. "*" = all defaults,
#     "-name" disables one, "foo" (without "*") means ONLY foo.
#   * A disabled controller produces NO error and NO failing health check —
#     the symptom is always "objects of one kind are accepted but never
#     reconciled". Map the stuck object kind to its controller, then check the
#     flag.
#   * On kubeadm, control-plane components are static Pods. You configure them
#     by editing files under /etc/kubernetes/manifests/, and the kubelet
#     applies changes automatically — never 'kubectl edit' them (the Pod is
#     mirror-only) and never 'kubectl delete' them expecting a fix.
#   * Always inspect the flags a component was ACTUALLY started with
#     (.spec.containers[0].command), not the flags you assume are set.
# ############################################################################