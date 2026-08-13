#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Kubernetes and Cloud Native Associate
#  Domain 2. Kubernetes Cluster Management  ·  Topic 2.1 (weight 3.0)
#  "Helm-based Installation and Configuration"
#
#  BREAK & FIX LAB — a failed `helm upgrade` and how to recover a release
#
#  Reference (official):
#    - CNCF KCA Curriculum:
#        https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    - Helm docs — Helm Upgrade & Rollback:
#        https://helm.sh/docs/helm/helm_upgrade/
#        https://helm.sh/docs/helm/helm_rollback/
#        https://helm.sh/docs/helm/helm_history/
#
#  WHAT THIS SCRIPT DOES
#    1. Installs a known-good Helm release (revision 1) — the baseline.
#    2. Performs a controlled, SAFE break: a `helm upgrade --wait` that pins a
#       non-existent image tag. Helm records a new revision, the readiness
#       gate never passes, and the release lands in `failed` status.
#    3. Prints the symptom the student will observe and the goal to reach.
#
#  This only touches a dedicated namespace on a DISPOSABLE lab cluster.
#  It never deletes data, never edits kubeconfig, never leaves the namespace.
#
#  USAGE
#    ./kca-2.1-helm-breakfix.sh            # run the break (default)
#    ./kca-2.1-helm-breakfix.sh clean      # remove everything this lab created
#
#  The step-by-step SOLUTION is at the very bottom, commented out.
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
NS="kca-lab-helm"
RELEASE="webapp"
CHART_DIR="$(mktemp -d)/demo"      # local, self-contained chart (no repo needed)
BROKEN_TAG="v0.0.0-does-not-exist" # an image tag that can never be pulled
UPGRADE_TIMEOUT="60s"

# Contexts we consider "safe / disposable". Override the guard on purpose with:
#   LAB_CONFIRM=yes ./kca-2.1-helm-breakfix.sh
SAFE_CONTEXT_REGEX='^(kind-|minikube$|k3d-|docker-desktop$|rancher-desktop$)'

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mXX %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

guard_disposable_cluster() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [ -n "$ctx" ] || die "No current kubectl context. Point KUBECONFIG at a LAB cluster."
  kubectl cluster-info >/dev/null 2>&1 || die "Cluster '$ctx' is unreachable."

  if [[ "$ctx" =~ $SAFE_CONTEXT_REGEX ]] || [ "${LAB_CONFIRM:-no}" = "yes" ]; then
    say "Using context: $ctx"
  else
    die "Context '$ctx' does not look like a disposable lab (kind/minikube/k3d/...).
     If you are SURE this is a throwaway cluster, re-run with: LAB_CONFIRM=yes $0"
  fi
}

# ----------------------------------------------------------------------------
# clean — tear the lab down completely
# ----------------------------------------------------------------------------
if [ "${1:-break}" = "clean" ]; then
  require kubectl; require helm
  guard_disposable_cluster
  say "Uninstalling release '$RELEASE' (ignore 'not found')..."
  helm uninstall "$RELEASE" -n "$NS" 2>/dev/null || true
  say "Deleting namespace '$NS'..."
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  say "Lab cleaned. Nothing else was modified."
  exit 0
fi

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
require kubectl
require helm
guard_disposable_cluster

# ----------------------------------------------------------------------------
# Scaffold a minimal, self-contained chart so the lab needs no chart repo.
# `helm create` produces a valid nginx-based chart with a Deployment + Service.
# ----------------------------------------------------------------------------
say "Scaffolding a local demo chart at $CHART_DIR ..."
helm create "$CHART_DIR" >/dev/null
# Pin a real, small, pullable baseline image so revision 1 is genuinely healthy.
cat >>"$CHART_DIR/values.yaml" <<'EOF'

# --- lab overrides (baseline: a real, pullable image) ---
image:
  repository: nginx
  tag: "1.25-alpine"
  pullPolicy: IfNotPresent
EOF

# ----------------------------------------------------------------------------
# STEP 1 — Baseline: a healthy release (revision 1)
# ----------------------------------------------------------------------------
say "Installing baseline release '$RELEASE' in namespace '$NS' (revision 1)..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NS" \
  --wait --timeout "120s" >/dev/null
say "Baseline is healthy:"
helm status "$RELEASE" -n "$NS" | sed -n '1,6p'
kubectl get pods -n "$NS"

# ----------------------------------------------------------------------------
# STEP 2 — The controlled break: upgrade to a broken image tag (revision 2)
#   `--wait` makes Helm block on readiness; the pods never become Ready because
#   the image cannot be pulled, so the release is marked FAILED on revision 2.
#   `|| true` keeps the lab script alive after the intended failure.
# ----------------------------------------------------------------------------
say "Applying the controlled break: helm upgrade --set image.tag=$BROKEN_TAG"
helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NS" \
  --set "image.tag=$BROKEN_TAG" \
  --wait --timeout "$UPGRADE_TIMEOUT" || true

# ----------------------------------------------------------------------------
# STEP 3 — Brief the student
# ----------------------------------------------------------------------------
cat <<EOF

============================================================================
 BREAK APPLIED — your investigation starts now
============================================================================

 SYMPTOM you will observe:
   * 'helm list -n $NS' shows the '$RELEASE' release with STATUS = failed.
   * 'helm history $RELEASE -n $NS' shows revision 2 as 'failed', while
     revision 1 is 'superseded' (it was the healthy one).
   * 'kubectl get pods -n $NS' shows the new pod stuck in
     ImagePullBackOff / ErrImagePull; the previous good pod may still be
     lingering, so the app is degraded, not fully down.
   * The Deployment rollout for '$RELEASE' never completes.

 WHY it happened:
   The last 'helm upgrade' pinned image.tag='$BROKEN_TAG', an image that does
   not exist in the registry. Helm committed this as revision 2 but its
   readiness gate ('--wait') timed out, so the release is in 'failed' state.

 YOUR GOAL (success criteria):
   * 'helm list -n $NS'  ->  STATUS = deployed
   * 'kubectl get pods -n $NS'  ->  the pod is Running and READY 1/1
   * The image actually serving traffic is a real, pullable tag again.

 HINTS (Helm mechanics this topic wants you to know):
   * A release is a versioned history, not a single state. Inspect it with
     'helm history' and read each revision's values with 'helm get values'.
   * You can move FORWARD to a corrected revision (another 'helm upgrade')
     or BACKWARD to a known-good one ('helm rollback'). Decide which is
     appropriate and know why each creates a NEW revision number.

 When you are done, verify with:
   helm status $RELEASE -n $NS
   kubectl get pods -n $NS
   kubectl rollout status deploy -n $NS -l app.kubernetes.io/instance=$RELEASE

 To reset the whole lab:  $0 clean
============================================================================
EOF

exit 0

# ############################################################################
# #                                                                          #
# #   INSTRUCTOR SOLUTION — step by step (keep this section commented)       #
# #                                                                          #
# ############################################################################
#
# There are TWO valid recoveries. Pick based on intent:
#   - Roll BACK when the previous revision was good and you just want it back.
#   - Roll FORWARD when you want to keep new config but fix the broken value.
# Both are examinable; understand that each produces a NEW revision number.
#
# ---------------------------------------------------------------------------
# 0) SEE the failure surface (always diagnose before acting)
# ---------------------------------------------------------------------------
#   NS=kca-lab-helm
#   RELEASE=webapp
#
#   helm list -n "$NS"                         # STATUS: failed
#   helm history "$RELEASE" -n "$NS"            # rev 2 failed, rev 1 superseded
#   helm status  "$RELEASE" -n "$NS"            # shows the failed upgrade
#   kubectl get pods -n "$NS"                   # ImagePullBackOff / ErrImagePull
#   kubectl describe pod -n "$NS" -l app.kubernetes.io/instance="$RELEASE" \
#       | sed -n '/Events:/,$p'                 # "Failed to pull image ... not found"
#
#   # Confirm the offending value that revision 2 committed:
#   helm get values "$RELEASE" -n "$NS"         # user-supplied overrides only
#   #   image:
#   #     tag: v0.0.0-does-not-exist            <-- the root cause
#   helm get values "$RELEASE" -n "$NS" --all   # merged values (defaults + overrides)
#
# ---------------------------------------------------------------------------
# OPTION A — Roll BACK to the last healthy revision (fastest recovery)
# ---------------------------------------------------------------------------
#   helm rollback "$RELEASE" 1 -n "$NS" --wait --timeout 120s
#
#   # 'helm rollback <release> <revision>' re-applies revision 1's manifests.
#   # Note: this is recorded as revision 3 (rollback creates a new revision).
#
#   # Verify:
#   helm history "$RELEASE" -n "$NS"            # rev 3: "Rollback to 1", deployed
#   helm status  "$RELEASE" -n "$NS"            # STATUS: deployed
#   kubectl get pods -n "$NS"                   # Running, READY 1/1
#
# ---------------------------------------------------------------------------
# OPTION B — Roll FORWARD by fixing the bad value (keeps other new config)
# ---------------------------------------------------------------------------
#   helm upgrade "$RELEASE" <chart> -n "$NS" \
#       --reuse-values \
#       --set image.tag=1.25-alpine \
#       --wait --timeout 120s
#
#   # '--reuse-values' keeps everything revision 2 set, but we override the
#   # single broken key. This is committed as a NEW revision (4 if you also
#   # did the rollback, otherwise 3). Prefer this when revision 2 also carried
#   # legitimate changes you must not lose.
#
#   # If you no longer have the chart path handy, re-scaffold or use the repo
#   # the release was installed from; the release name and namespace are what
#   # Helm keys on, not the local directory.
#
#   # Verify identically:
#   helm status "$RELEASE" -n "$NS"             # deployed
#   kubectl get pods -n "$NS"                    # Running 1/1
#
# ---------------------------------------------------------------------------
# TEACHING POINTS (why this maps to KCA topic 2.1)
# ---------------------------------------------------------------------------
#   * Helm state lives in a Secret per revision (type helm.sh/release.v1) in
#     the release namespace:
#       kubectl get secret -n "$NS" -l owner=helm
#     That Secret — NOT the pods — is the source of truth for a release.
#   * '--wait' turns "did the objects apply?" into "did they become Ready?".
#     Without it, a broken image would show STATUS: deployed while pods crash;
#     with it, Helm honestly reports 'failed'. Use it in CI and in the exam.
#   * '--atomic' would have auto-rolled-back the failed upgrade for you:
#       helm upgrade ... --atomic --timeout 60s
#     Know the difference: --atomic prevents the broken revision from sticking;
#     'helm rollback' repairs one that already stuck.
#   * A stuck 'pending-upgrade' status (interrupted upgrade) is the sibling
#     failure: recover with 'helm rollback' to the last deployed revision, or
#     'helm history' + 'helm rollback' — never by editing the release Secret.
# ############################################################################