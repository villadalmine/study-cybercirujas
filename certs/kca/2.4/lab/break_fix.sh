#!/usr/bin/env bash
#
# ==============================================================================
#  KCA — Kyverno Certified Associate
#  Topic 2.4: Configuring Kyverno RBAC, roles, and permissions   (exam weight 3.0)
#  Lab type: BREAK & FIX  (run ONLY on a disposable lab VM / throwaway cluster)
#
#  Reference syllabus:
#    - https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#  Reference documentation (official Kyverno):
#    - RBAC & permissions:  https://kyverno.io/docs/installation/customization/#role-based-access-controls
#    - generate rules:      https://kyverno.io/docs/writing-policies/generate/
#    - controllers layout:  https://kyverno.io/docs/high-availability/
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  Kyverno is NOT one process with god-mode over the API. Since v1.10 it is split
#  into four controllers, each with its OWN ServiceAccount and its OWN aggregated
#  ClusterRole:
#
#      kyverno-admission-controller   -> ClusterRole kyverno:admission-controller
#      kyverno-background-controller  -> ClusterRole kyverno:background-controller
#      kyverno-cleanup-controller     -> ClusterRole kyverno:cleanup-controller
#      kyverno-reports-controller     -> ClusterRole kyverno:reports-controller
#
#  Each of those ClusterRoles is an *aggregated* role: it owns no rules directly,
#  it has an `aggregationRule` that unions every ClusterRole carrying the matching
#  label. For the background controller (the one that executes `generate` and
#  `mutateExisting` rules) that label is:
#
#      rbac.kyverno.io/aggregate-to-background-controller: "true"
#
#  Kyverno ships deliberately LEAST-PRIVILEGE. It CANNOT create arbitrary target
#  resources (NetworkPolicy, Secret, etc.) out of the box. You extend it by
#  creating your own ClusterRole with that aggregation label — NEVER by editing
#  the built-in `kyverno:*` roles (an upgrade would revert your edit).
#
#  This script builds a working generate policy (Kyverno auto-creates a
#  `default-deny` NetworkPolicy in labeled namespaces), then BREAKS the RBAC so
#  generation silently fails. Your job: diagnose and restore it the RIGHT way.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Tunables (override via environment)
# ------------------------------------------------------------------------------
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.13.4}"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
LAB_NS_A="${LAB_NS_A:-kyverno-rbac-lab-a}"      # namespace created BEFORE the break
LAB_NS_B="${LAB_NS_B:-kyverno-rbac-lab-b}"      # namespace created AFTER the break
LAB_LABEL_KEY="kyverno-rbac-lab"
LAB_LABEL_VAL="enabled"
LAB_CLUSTERROLE="kyverno:lab-netpol-generator"  # OUR extension role (not a built-in)
LAB_POLICY="lab-add-default-netpol"
BG_SA="system:serviceaccount:${KYVERNO_NS}:kyverno-background-controller"
AGG_LABEL="rbac.kyverno.io/aggregate-to-background-controller"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
say()  { printf '%s\n' "${CYA}==>${RST} $*"; }
ok()   { printf '%s\n' "${GRN}[ ok ]${RST} $*"; }
warn() { printf '%s\n' "${YEL}[warn]${RST} $*"; }
die()  { printf '%s\n' "${RED}[fail]${RST} $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Safety rail — refuse to run against anything that is not clearly a throwaway
# ------------------------------------------------------------------------------
guard() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster / kubeconfig."
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  printf '%s\n' "${BLD}Current kube-context:${RST} ${ctx}"
  printf '%s\n' "${BLD}API server:${RST} $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  echo
  warn "This script CREATES ClusterRoles/ClusterPolicies and DELETES RBAC labels."
  warn "It is meant for a DISPOSABLE lab cluster only (kind/minikube/k3s/VM)."
  if [[ "${LAB_CONFIRM:-}" != "yes" ]]; then
    read -r -p "Type 'yes' to proceed on the context above: " ans
    [[ "$ans" == "yes" ]] || die "Aborted by user."
  fi
}

wait_rollout() {  # wait_rollout <deployment>
  kubectl -n "$KYVERNO_NS" rollout status "deploy/$1" --timeout=180s >/dev/null 2>&1 \
    && ok "rollout ready: $1" || warn "rollout not confirmed: $1 (continuing)"
}

wait_for_netpol() {  # wait_for_netpol <ns> <timeout_seconds> ; 0 = appeared
  local ns="$1" timeout="${2:-60}" i=0
  while (( i < timeout )); do
    kubectl get networkpolicy default-deny -n "$ns" >/dev/null 2>&1 && return 0
    sleep 3; (( i += 3 ))
  done
  return 1
}

# ------------------------------------------------------------------------------
# Step 0 — ensure Kyverno is installed
# ------------------------------------------------------------------------------
ensure_kyverno() {
  if kubectl -n "$KYVERNO_NS" get deploy kyverno-background-controller >/dev/null 2>&1; then
    ok "Kyverno already installed in namespace '${KYVERNO_NS}'."
    return
  fi
  say "Installing Kyverno ${KYVERNO_VERSION} (server-side apply)..."
  kubectl apply --server-side -f \
    "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
  wait_rollout kyverno-admission-controller
  wait_rollout kyverno-background-controller
}

# ------------------------------------------------------------------------------
# Step 1 — the RBAC extension that MAKES generation work (correct baseline)
# ------------------------------------------------------------------------------
apply_rbac() {
  say "Applying the aggregation ClusterRole that grants Kyverno NetworkPolicy rights..."
  kubectl apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${LAB_CLUSTERROLE}
  labels:
    ${AGG_LABEL}: "true"
rules:
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["create", "update", "delete", "get", "list", "watch"]
YAML
  ok "ClusterRole ${LAB_CLUSTERROLE} applied (aggregates into kyverno:background-controller)."
}

# ------------------------------------------------------------------------------
# Step 2 — the generate policy: every labeled namespace gets a default-deny NetPol
# ------------------------------------------------------------------------------
apply_policy() {
  say "Applying generate ClusterPolicy '${LAB_POLICY}'..."
  kubectl apply -f - <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${LAB_POLICY}
spec:
  background: true
  rules:
    - name: default-deny
      match:
        any:
          - resources:
              kinds: ["Namespace"]
              selector:
                matchLabels:
                  ${LAB_LABEL_KEY}: ${LAB_LABEL_VAL}
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes: ["Ingress", "Egress"]
YAML
  ok "ClusterPolicy ${LAB_POLICY} applied."
}

# ------------------------------------------------------------------------------
# Step 3 — prove the baseline works, THEN break it
# ------------------------------------------------------------------------------
setup_and_break() {
  guard
  ensure_kyverno
  apply_rbac
  apply_policy

  say "Creating labeled namespace '${LAB_NS_A}' to prove generation works..."
  kubectl create namespace "$LAB_NS_A" >/dev/null 2>&1 || true
  kubectl label namespace "$LAB_NS_A" "${LAB_LABEL_KEY}=${LAB_LABEL_VAL}" --overwrite >/dev/null

  if wait_for_netpol "$LAB_NS_A" 60; then
    ok "Baseline verified: NetworkPolicy 'default-deny' auto-generated in ${LAB_NS_A}."
    kubectl get networkpolicy -n "$LAB_NS_A"
  else
    warn "Baseline netpol did not appear in ${LAB_NS_A} within 60s."
    warn "Check: kubectl -n ${KYVERNO_NS} logs deploy/kyverno-background-controller"
  fi

  echo
  say "${BLD}>>> BREAKING RBAC NOW <<<${RST}"
  # The controlled, reversible break: strip the aggregation label from OUR
  # ClusterRole. The rule set stays on disk, but kube-controller-manager will
  # recompute kyverno:background-controller WITHOUT our networkpolicies rule.
  kubectl label clusterrole "$LAB_CLUSTERROLE" "${AGG_LABEL}-" >/dev/null
  ok "Removed label '${AGG_LABEL}' from ClusterRole ${LAB_CLUSTERROLE}."
  sleep 6  # give the aggregation controller a moment to reconcile

  say "Triggering a fresh generation against the broken RBAC (namespace ${LAB_NS_B})..."
  kubectl create namespace "$LAB_NS_B" >/dev/null 2>&1 || true
  kubectl label namespace "$LAB_NS_B" "${LAB_LABEL_KEY}=${LAB_LABEL_VAL}" --overwrite >/dev/null

  echo
  cat <<EOF
${BLD}${YEL}========================= STUDENT BRIEF =========================${RST}

A generate policy ('${LAB_POLICY}') is supposed to auto-create a
NetworkPolicy named 'default-deny' in every namespace carrying the label
'${LAB_LABEL_KEY}=${LAB_LABEL_VAL}'. It worked for '${LAB_NS_A}'.

${BLD}SYMPTOM you will observe:${RST}
  - Namespace '${LAB_NS_B}' is labeled correctly, yet it has NO NetworkPolicy:
        kubectl get networkpolicy -n ${LAB_NS_B}
        -> No resources found in ${LAB_NS_B} namespace.
  - The ClusterPolicy still reports READY=True (the policy is VALID; the
    FAILURE is at apply time, in the background controller).
  - The background controller logs show a FORBIDDEN error:
        kubectl -n ${KYVERNO_NS} logs deploy/kyverno-background-controller | grep -i forbidden
        -> ...networkpolicies.networking.k8s.io is forbidden: User
           "${BG_SA}" cannot create resource "networkpolicies" ...
  - The effective permission is gone:
        kubectl auth can-i create networkpolicies.networking.k8s.io \\
           --as=${BG_SA} -n ${LAB_NS_B}
        -> no

${BLD}YOUR GOAL:${RST}
  Restore Kyverno's ability to generate NetworkPolicies THROUGH RBAC
  AGGREGATION — do NOT edit the built-in 'kyverno:*' ClusterRoles, and do NOT
  grant cluster-admin. Success = the 'default-deny' NetworkPolicy appears in
  BOTH '${LAB_NS_A}' and '${LAB_NS_B}', and 'can-i' returns 'yes' for
  ${BG_SA}.

${BLD}Diagnostic starting points:${RST}
  kubectl get clusterrole ${LAB_CLUSTERROLE} -o yaml | grep -A2 labels
  kubectl get clusterrole kyverno:background-controller -o yaml | grep -A4 aggregationRule
  kubectl describe clusterpolicy ${LAB_POLICY}
  kubectl get events -n ${LAB_NS_B} --sort-by=.lastTimestamp | tail

When you think it is fixed, verify with:
  kubectl get networkpolicy -n ${LAB_NS_A} -n ${LAB_NS_B} 2>/dev/null; \\
  kubectl get networkpolicy -A | grep default-deny
${BLD}${YEL}=================================================================${RST}

(Reset everything with:  ${0##*/} cleanup)
EOF
}

# ------------------------------------------------------------------------------
# Teardown
# ------------------------------------------------------------------------------
cleanup() {
  say "Cleaning up lab objects..."
  kubectl delete clusterpolicy "$LAB_POLICY" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole "$LAB_CLUSTERROLE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "$LAB_NS_A" "$LAB_NS_B" --ignore-not-found >/dev/null 2>&1 || true
  ok "Lab objects removed (Kyverno itself left installed)."
  echo "To remove Kyverno entirely:"
  echo "  kubectl delete -f https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
}

case "${1:-break}" in
  break)   setup_and_break ;;
  cleanup) cleanup ;;
  *)       die "Usage: ${0##*/} [break|cleanup]" ;;
esac

# ==============================================================================
#  SOLUTION — step by step (do NOT peek until you have tried!)
# ==============================================================================
#
#  Mental model: the failure is an RBAC problem, not a policy problem. The
#  ClusterPolicy is valid and READY; Kyverno's BACKGROUND controller is the actor
#  that creates generated resources, and it lost the permission to create
#  NetworkPolicies. Permissions reach that controller ONLY via the aggregated
#  ClusterRole `kyverno:background-controller`, which unions every ClusterRole
#  labeled `rbac.kyverno.io/aggregate-to-background-controller: "true"`.
#
#  --- 1. Confirm the policy is fine, the permission is not ---------------------
#  # kubectl get clusterpolicy lab-add-default-netpol
#  #   -> READY True  (so the break is NOT in the policy)
#  # kubectl -n kyverno logs deploy/kyverno-background-controller | grep -i forbidden
#  #   -> "networkpolicies.networking.k8s.io is forbidden: User
#  #       system:serviceaccount:kyverno:kyverno-background-controller cannot
#  #       create resource networkpolicies ..."
#  # kubectl auth can-i create networkpolicies.networking.k8s.io \
#  #     --as=system:serviceaccount:kyverno:kyverno-background-controller \
#  #     -n kyverno-rbac-lab-b
#  #   -> no
#
#  --- 2. Find WHY the aggregated role no longer includes networkpolicies -------
#  # kubectl get clusterrole kyverno:background-controller -o yaml | grep -A4 aggregationRule
#  #   -> aggregationRule selects: rbac.kyverno.io/aggregate-to-background-controller: "true"
#  # kubectl get clusterrole kyverno:lab-netpol-generator --show-labels
#  #   -> our role STILL grants networkpolicies, but the aggregation label is GONE,
#  #      so kube-controller-manager stopped folding it into the background role.
#
#  --- 3. Fix it the SUPPORTED way: re-add the aggregation label ----------------
#  #    (Do NOT edit kyverno:background-controller directly — an upgrade would
#  #     overwrite it. The extension point is your own labeled ClusterRole.)
#  # kubectl label clusterrole kyverno:lab-netpol-generator \
#  #     rbac.kyverno.io/aggregate-to-background-controller=true
#  #
#  #    Equivalent declarative fix (re-apply the ClusterRole with the label):
#  # kubectl apply -f - <<'EOF'
#  # apiVersion: rbac.authorization.k8s.io/v1
#  # kind: ClusterRole
#  # metadata:
#  #   name: kyverno:lab-netpol-generator
#  #   labels:
#  #     rbac.kyverno.io/aggregate-to-background-controller: "true"
#  # rules:
#  #   - apiGroups: ["networking.k8s.io"]
#  #     resources: ["networkpolicies"]
#  #     verbs: ["create","update","delete","get","list","watch"]
#  # EOF
#
#  --- 4. Verify the permission is back (aggregation reconciles in a few sec) ----
#  # kubectl auth can-i create networkpolicies.networking.k8s.io \
#  #     --as=system:serviceaccount:kyverno:kyverno-background-controller \
#  #     -n kyverno-rbac-lab-b
#  #   -> yes
#
#  --- 5. Force Kyverno to re-run the generate rule -----------------------------
#  #    `synchronize: true` makes the background controller reconcile on its own
#  #    within ~1 min, but you can nudge it by re-touching the trigger:
#  # kubectl label namespace kyverno-rbac-lab-b kyverno-rbac-lab=enabled --overwrite
#  #    (or: kubectl annotate ns kyverno-rbac-lab-b kyverno.io/retrigger="1" --overwrite)
#
#  --- 6. Confirm success --------------------------------------------------------
#  # kubectl get networkpolicy -A | grep default-deny
#  #   -> kyverno-rbac-lab-a   default-deny   ...
#  #      kyverno-rbac-lab-b   default-deny   ...
#  # kubectl -n kyverno logs deploy/kyverno-background-controller | grep -i forbidden
#  #   -> (no new forbidden errors)
#
#  KEY TAKEAWAYS
#  -------------
#  * Kyverno's four controllers are separate RBAC subjects; `generate` and
#    `mutateExisting` run in the BACKGROUND controller — grant target-resource
#    rights there, not to the admission controller.
#  * You extend Kyverno's permissions by ADDING a labeled ClusterRole
#    (aggregate-to-<controller>-controller=true), never by editing kyverno:* roles.
#  * A valid, READY policy can still fail silently at generation time; the truth
#    is in the controller logs, `kubectl auth can-i`, and PolicyReport/events.
# ==============================================================================