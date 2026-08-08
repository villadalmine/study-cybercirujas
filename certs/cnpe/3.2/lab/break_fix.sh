#!/usr/bin/env bash
#
# CNPE 3.2 — Applying RBAC and Security Controls Across Platform Resources
# Break & Fix lab :: RBAC least-privilege regression on a tenant ServiceAccount
#
# WHAT THIS TEACHES
#   Kubernetes RBAC authorization is (apiGroup, resource, verb)-scoped. The most
#   common — and most silent — platform RBAC defect is an apiGroup mismatch: a
#   Role that names the right *resource* and the right *verb* but the wrong *API
#   group*. `deployments` live in the `apps` group, not the core ("") group, so a
#   rule that grants them under "" authorizes nothing while looking correct.
#
#   This script provisions a working, least-privilege tenant RBAC bundle
#   (ServiceAccount + Role + RoleBinding), proves it works, then injects that
#   exact regression. The student must diagnose why one verb is now Forbidden and
#   restore least-privilege access WITHOUT resorting to a broad grant.
#
# SAFETY
#   * Runs only against a disposable lab cluster. It refuses contexts whose name
#     looks like prod/production/live unless LAB_ALLOW=1 is exported.
#   * All objects live in the dedicated namespace 'cnpe-rbac-lab' and are fully
#     removed by:  ./break_fix.sh --cleanup
#   * Idempotent: re-running --break re-applies the broken state safely.
#
# USAGE
#   ./break_fix.sh --break     # provision, prove it works, then break it (default)
#   ./break_fix.sh --verify    # check whether the student has fixed it
#   ./break_fix.sh --cleanup   # remove every object this lab created
#
# Sources (official):
#   * RBAC authorization ....... https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#   * kubectl auth can-i ....... https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access
#   * API groups & versioning .. https://kubernetes.io/docs/reference/using-api/#api-groups
#   * CNPE Curriculum .......... https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf

set -euo pipefail

NS="cnpe-rbac-lab"
SA="app-deployer"
ROLE="tenant-deployer"
BINDING="tenant-deployer-binding"
SUBJECT="system:serviceaccount:${NS}:${SA}"
MODE="${1:---break}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ok] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster. Point KUBECONFIG at your disposable lab cluster."
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  if printf '%s' "$ctx" | grep -Eiq 'prod|production|live'; then
    [ "${LAB_ALLOW:-0}" = "1" ] || die "Context '$ctx' looks like production. Refusing. Export LAB_ALLOW=1 only if this is truly disposable."
  fi
  ok "Using context: ${ctx}"
}

# --- baseline: a correct, least-privilege tenant RBAC bundle -----------------
provision_working() {
  log "Provisioning baseline least-privilege RBAC in namespace '${NS}'"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" create serviceaccount "$SA" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE}
  namespace: ${NS}
rules:
  # core ("") group resources the tenant deployer legitimately manages
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # workload controllers live in the "apps" group — this is the correct grant
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
YAML

  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BINDING}
  namespace: ${NS}
subjects:
  - kind: ServiceAccount
    name: ${SA}
    namespace: ${NS}
roleRef:
  kind: Role
  name: ${ROLE}
  apiGroup: rbac.authorization.k8s.io
YAML
  ok "Baseline applied."

  log "Proving the baseline works (as ${SUBJECT})"
  kubectl auth can-i create deployments.apps -n "$NS" --as="$SUBJECT" >/dev/null \
    && ok "can-i create deployments.apps  -> yes (expected)"
  kubectl auth can-i create pods           -n "$NS" --as="$SUBJECT" >/dev/null \
    && ok "can-i create pods              -> yes (expected)"
}

# --- the controlled break ----------------------------------------------------
inject_break() {
  log "Injecting the regression (apiGroup mismatch on workload controllers)"
  # A well-meaning 'consolidation' collapses every rule into the core group.
  # 'deployments'/'replicasets' are still listed by name, so the change looks
  # harmless in review — but they no longer resolve, because they belong to
  # the 'apps' group, not "".
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE}
  namespace: ${NS}
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "deployments", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
YAML
  ok "Break applied."
}

show_symptom() {
  log "SYMPTOM — reproduce it yourself"
  echo "The tenant's GitOps/deploy ServiceAccount can still manage Pods, Services and"
  echo "ConfigMaps, but every attempt to reconcile a Deployment now fails. A real"
  echo "apply from the ${SA} identity produces a Forbidden error:"
  echo
  echo '  $ kubectl -n '"$NS"' create deployment web --image=nginx \'
  echo '      --as='"$SUBJECT"
  set +e
  kubectl -n "$NS" create deployment web --image=nginx:1.27 --as="$SUBJECT" 2>&1 | sed 's/^/    /'
  echo
  echo "  Contrast the two authorization checks:"
  printf '    can-i create pods              -> %s\n' "$(kubectl auth can-i create pods           -n "$NS" --as="$SUBJECT" 2>/dev/null)"
  printf '    can-i create deployments.apps  -> %s\n' "$(kubectl auth can-i create deployments.apps -n "$NS" --as="$SUBJECT" 2>/dev/null)"
  set -e

  log "YOUR MISSION"
  cat <<'EOF'
  Restore the tenant deployer's ability to manage Deployments and ReplicaSets,
  WITHOUT widening the blast radius:

    1. The fix must keep least privilege — no wildcards, no cluster-admin, no
       binding to a broad built-in ClusterRole like 'edit' or 'admin'.
    2. Only the Role should change. The ServiceAccount, the RoleBinding and its
       (immutable) roleRef must stay as they are.
    3. When done, run:  ./break_fix.sh --verify

  Diagnostic hints:
    * kubectl auth can-i --list -n cnpe-rbac-lab --as=SUBJECT
    * kubectl -n cnpe-rbac-lab get role tenant-deployer -o yaml
    * kubectl api-resources | grep -E 'deployments|replicasets'   # note the APIGROUP column
    * Ask: does the verb work? the resource name? the API GROUP?
EOF
}

verify_fix() {
  preflight
  log "Verifying student fix"
  local fail=0

  # Correct behaviour restored?
  for res in deployments.apps replicasets.apps; do
    if [ "$(kubectl auth can-i create "$res" -n "$NS" --as="$SUBJECT" 2>/dev/null)" = "yes" ]; then
      ok "can-i create ${res} -> yes"
    else
      warn "can-i create ${res} -> no (still broken)"; fail=1
    fi
  done

  # Least privilege preserved? The deployer must NOT gain cluster-wide or secret access.
  if [ "$(kubectl auth can-i create secrets -n "$NS" --as="$SUBJECT" 2>/dev/null)" = "yes" ]; then
    warn "OVER-PRIVILEGED: the deployer can now create Secrets — you granted too much."; fail=1
  else
    ok "least privilege intact: cannot create secrets"
  fi
  if kubectl get clusterrolebinding -o jsonpath='{range .items[*]}{.subjects[*].name}{"\n"}{end}' 2>/dev/null \
       | grep -qx "$SA"; then
    warn "OVER-PRIVILEGED: a ClusterRoleBinding now references '${SA}'. Keep the grant namespaced."; fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    ok "PASS — Deployment access restored at least privilege. Well done."
  else
    die "Not fixed yet. Re-read the mission and the hints above."
  fi
}

cleanup() {
  preflight
  log "Removing all lab objects"
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  ok "Cleanup requested. Namespace '${NS}' is terminating."
}

case "$MODE" in
  --break|"")
    preflight
    provision_working
    inject_break
    show_symptom
    ;;
  --verify)  verify_fix ;;
  --cleanup) cleanup ;;
  *) die "Unknown mode '$MODE'. Use --break | --verify | --cleanup." ;;
esac

# =============================================================================
# SOLUTION (do not read until you have tried) — step by step
# =============================================================================
#
# 1. CONFIRM THE SHAPE OF THE FAILURE
#    Authorization in RBAC is keyed on the triple (apiGroup, resource, verb).
#    A "Forbidden" that hits ONE resource type while others in the same Role
#    still work almost always means the verb and resource are fine but the
#    API GROUP is wrong.
#
#      kubectl auth can-i --list -n cnpe-rbac-lab \
#        --as=system:serviceaccount:cnpe-rbac-lab:app-deployer
#
#    You will see create/delete allowed on pods, services, configmaps, but the
#    'deployments'/'replicasets' entries under the apps group are absent.
#
# 2. FIND WHICH GROUP THE RESOURCE REALLY BELONGS TO
#
#      kubectl api-resources | grep -E 'deployments|replicasets'
#      # NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND
#      # deployments   deploy       apps/v1      true         Deployment
#      # replicasets   rs           apps/v1      true         ReplicaSet
#
#    APIVERSION 'apps/v1' => these resources are in the 'apps' API group, NOT
#    the core ("") group. Listing them under apiGroups: [""] authorizes nothing.
#
# 3. INSPECT THE BROKEN ROLE
#
#      kubectl -n cnpe-rbac-lab get role tenant-deployer -o yaml
#
#    The single rule uses apiGroups: [""] but lists deployments/replicasets —
#    that is the regression.
#
# 4. RESTORE LEAST-PRIVILEGE ACCESS BY SPLITTING THE RULE BY API GROUP
#    Do NOT add a wildcard group ("*") and do NOT bind to the built-in 'edit'
#    ClusterRole — both over-grant. Give each resource its correct group:
#
#      cat <<'YAML' | kubectl apply -f -
#      apiVersion: rbac.authorization.k8s.io/v1
#      kind: Role
#      metadata:
#        name: tenant-deployer
#        namespace: cnpe-rbac-lab
#      rules:
#        - apiGroups: [""]
#          resources: ["pods", "services", "configmaps"]
#          verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
#        - apiGroups: ["apps"]
#          resources: ["deployments", "replicasets"]
#          verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
#      YAML
#
#    Note: the RoleBinding and its roleRef are untouched. roleRef is immutable —
#    if you ever need to change WHICH role is bound, you must delete and recreate
#    the RoleBinding, but here only the Role's rules were wrong.
#
# 5. VERIFY
#
#      kubectl auth can-i create deployments.apps -n cnpe-rbac-lab \
#        --as=system:serviceaccount:cnpe-rbac-lab:app-deployer      # -> yes
#      kubectl auth can-i create secrets -n cnpe-rbac-lab \
#        --as=system:serviceaccount:cnpe-rbac-lab:app-deployer      # -> no  (still least privilege)
#
#      ./break_fix.sh --verify
#
# 6. TEAR DOWN
#
#      ./break_fix.sh --cleanup
#
# PLATFORM-ENGINEERING TAKEAWAYS
#   * RBAC failures are almost never about the verb; they are about the
#     (apiGroup, resource) pair. Read the APIGROUP column of `kubectl api-resources`
#     before writing a rule, and qualify resources in checks (deployments.apps).
#   * `kubectl auth can-i --as / --as-group` lets you audit any subject's
#     effective permissions without impersonating credentials — bake it into
#     platform CI so an over- or under-grant is caught before it reaches a tenant.
#   * The safe fix widens access by exactly one (apiGroup, resource) pair.
#     "Just bind them to edit/admin" fixes the symptom by deleting the security
#     control — the opposite of what this competency is testing.
# =============================================================================