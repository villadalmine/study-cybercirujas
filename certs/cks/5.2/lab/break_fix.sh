#!/usr/bin/env bash
# =============================================================================
#  CKS 1.34 — Domain 5: Microservice Vulnerabilities
#  Topic 5.2 — Using least-privilege identity and access management
#  Exam weight: 2.5
#
#  BREAK & FIX LAB — controlled damage on a DISPOSABLE single-node lab cluster.
#
#  What this lab teaches (production reality, not toy RBAC):
#    * Workload identity: ServiceAccount -> projected token -> API server
#      authentication (system:serviceaccount:<ns>:<name>).
#    * The difference between AUTHENTICATION failures (401, no token / bad
#      token) and AUTHORIZATION failures (403, RBAC denies the verb).
#    * Namespace-qualified subjects in RoleBindings — the single most common
#      real-world RBAC mistake.
#    * resourceNames scoping: granting get on ONE object instead of a resource
#      type.
#    * Token automount hygiene: a workload that never calls the API server must
#      not carry an API credential.
#    * Removing standing privilege (cluster-admin bindings) and re-granting the
#      minimum, plus the anonymous-access blind spot.
#
#  Authoritative references:
#    - CKS curriculum v1.34
#      https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#    - RBAC authorization
#      https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#    - RBAC good practices
#      https://kubernetes.io/docs/concepts/security/rbac-good-practices/
#    - Configure Service Accounts for Pods
#      https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
#    - Authenticating (anonymous requests, service account tokens)
#      https://kubernetes.io/docs/reference/access-authn-authz/authentication/
#    - Managing Service Accounts / bound tokens
#      https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
#
#  Requirements:
#    * A THROWAWAY cluster you own (kubeadm VM, kind, minikube, k3s).
#    * kubectl with cluster-admin (impersonation is used by the verifier).
#    * Egress to a container registry, or preload an image and export
#      APP_IMAGE=<your/curl-capable-image>.
#
#  WARNING: this script intentionally creates an insecure cluster state
#  (a cluster-admin binding for a workload identity and a binding for
#  system:unauthenticated). NEVER run it against anything you care about.
#  Run `$0 cleanup` when you are done.
#
#  Usage:
#     ./cks-5.2-break-fix.sh setup      # build the healthy baseline only
#     ./cks-5.2-break-fix.sh break      # baseline + inject the faults (default)
#     ./cks-5.2-break-fix.sh verify     # grade your fix
#     ./cks-5.2-break-fix.sh hint       # progressive hints, no spoilers
#     ./cks-5.2-break-fix.sh solution   # print the commented solution
#     ./cks-5.2-break-fix.sh cleanup    # delete every object this lab created
#     (add --yes to skip the interactive confirmation)
# =============================================================================

set -Eeuo pipefail

# ------------------------------- parameters ----------------------------------
KUBECTL="${KUBECTL:-kubectl}"
NS="${NS:-payments}"
APP_SA="checkout-sa"
BOT_SA="deploy-bot"
APP_IMAGE="${APP_IMAGE:-docker.io/curlimages/curl:8.11.1}"
LAB_DIR="${LAB_DIR:-$HOME/cks-5.2-lab}"
ASSUME_YES="${ASSUME_YES:-no}"

CRB_ADMIN="legacy-ops-cluster-admin"
CRB_ANON="anonymous-view"

# ------------------------------- presentation --------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_R="$(tput setaf 1)"; C_G="$(tput setaf 2)"; C_Y="$(tput setaf 3)"
  C_B="$(tput setaf 4)"; C_BOLD="$(tput bold)"; C_0="$(tput sgr0)"
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_BOLD=""; C_0=""
fi

hr()   { printf '%s\n' "-------------------------------------------------------------------------------"; }
say()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
good() { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
bad()  { printf '%s[-]%s %s\n' "$C_R" "$C_0" "$*"; }
die()  { bad "$*"; exit 1; }

trap 'bad "aborted at line $LINENO (exit $?) — the cluster may be half-broken; run: $0 cleanup"' ERR

# ------------------------------- safety guard --------------------------------
require_lab_cluster() {
  command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl not found in PATH"
  "$KUBECTL" cluster-info >/dev/null 2>&1 || die "no reachable cluster (check KUBECONFIG)"

  local ctx nodes server
  ctx="$("$KUBECTL" config current-context 2>/dev/null || echo '<none>')"
  server="$("$KUBECTL" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '?')"
  nodes="$("$KUBECTL" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  hr
  printf '%sTARGET CLUSTER%s\n' "$C_BOLD" "$C_0"
  printf '  context : %s\n  server  : %s\n  nodes   : %s\n' "$ctx" "$server" "$nodes"
  hr

  case "$ctx" in
    *prod*|*prd*|*production*|*staging*|*stg*)
      die "context name '$ctx' looks like a real environment. Refusing." ;;
  esac
  [ "$nodes" -gt 3 ] && warn "this cluster has $nodes nodes — is it really disposable?"

  if [ "$ASSUME_YES" != "yes" ]; then
    printf '\n%sThis lab will grant cluster-admin to a ServiceAccount and bind the\n' "$C_Y"
    printf 'system:unauthenticated group to a ClusterRole. The cluster stays insecure\n'
    printf 'until you fix it or run "%s cleanup".%s\n\n' "$0" "$C_0"
    read -r -p 'Type BREAK to proceed: ' answer
    [ "$answer" = "BREAK" ] || die "confirmation not given, nothing was changed"
  fi
  mkdir -p "$LAB_DIR"
}

snapshot() {
  say "saving a pre-lab snapshot under $LAB_DIR"
  "$KUBECTL" get clusterrolebinding -o yaml > "$LAB_DIR/clusterrolebindings.before.yaml" 2>/dev/null || true
  "$KUBECTL" get clusterrole -o name     > "$LAB_DIR/clusterroles.before.txt"           2>/dev/null || true
  "$KUBECTL" get -n "$NS" sa,role,rolebinding -o yaml > "$LAB_DIR/ns-rbac.before.yaml"  2>/dev/null || true
}

# ------------------------------ healthy baseline -----------------------------
write_probe_script() {
  cat > "$LAB_DIR/probe.sh" <<'PROBE'
#!/bin/sh
# checkout service — it only ever needs ONE ConfigMap from the API server.
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
API=https://kubernetes.default.svc
TARGET=checkout-config

while true; do
  if [ ! -r "$SA_DIR/token" ]; then
    echo "$(date +%FT%T%z) RESULT=000 stage=auth detail=no-serviceaccount-token-mounted"
    sleep 10
    continue
  fi
  NS=$(cat "$SA_DIR/namespace" 2>/dev/null || echo payments)
  TOKEN=$(cat "$SA_DIR/token")
  RESP=$(curl -sS --max-time 5 \
           --cacert "$SA_DIR/ca.crt" \
           -H "Authorization: Bearer $TOKEN" \
           -w '\nHTTPCODE=%{http_code}' \
           "$API/api/v1/namespaces/$NS/configmaps/$TARGET" 2>&1 || true)
  CODE=$(printf '%s' "$RESP" | sed -n 's/^HTTPCODE=//p' | tail -1)
  [ -z "$CODE" ] && CODE=000
  BODY=$(printf '%s' "$RESP" | sed '/^HTTPCODE=/d' | tr -d '\n' | cut -c1-220)
  case "$CODE" in
    200) echo "$(date +%FT%T%z) RESULT=200 stage=ready detail=configmap/$TARGET-loaded" ;;
    401) echo "$(date +%FT%T%z) RESULT=401 stage=authn detail=$BODY" ;;
    403) echo "$(date +%FT%T%z) RESULT=403 stage=authz detail=$BODY" ;;
    *)   echo "$(date +%FT%T%z) RESULT=$CODE stage=unknown detail=$BODY" ;;
  esac
  sleep 10
done
PROBE
}

setup() {
  say "building the healthy baseline in namespace '$NS'"

  "$KUBECTL" create namespace "$NS" --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null

  # Data the workload legitimately needs, plus two decoys it must NEVER reach.
  "$KUBECTL" -n "$NS" create configmap checkout-config \
      --from-literal=CURRENCY=EUR \
      --from-literal=GATEWAY_URL=https://payments.internal.svc:8443 \
      --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
  "$KUBECTL" -n "$NS" create configmap billing-config \
      --from-literal=LEDGER=primary \
      --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
  "$KUBECTL" -n "$NS" create secret generic payments-db \
      --from-literal=username=svc_payments \
      --from-literal=password='n0t-f0r-the-checkout-pod' \
      --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null

  write_probe_script
  "$KUBECTL" -n "$NS" create configmap checkout-probe \
      --from-file=probe.sh="$LAB_DIR/probe.sh" \
      --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null

  cat <<YAML | "$KUBECTL" apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP_SA}
  namespace: ${NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${BOT_SA}
  namespace: ${NS}
---
# Least privilege, correct version: get on ONE named ConfigMap. Nothing else.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: checkout-config-reader
  namespace: ${NS}
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["checkout-config"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: checkout-config-reader
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: checkout-config-reader
subjects:
  - kind: ServiceAccount
    name: ${APP_SA}
    namespace: ${NS}
---
# The CI robot: it rolls out images, so it needs read + patch on Deployments
# in this namespace only. No delete, no other namespace, no secrets.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployment-patcher
  namespace: ${NS}
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployment-patcher
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deployment-patcher
subjects:
  - kind: ServiceAccount
    name: ${BOT_SA}
    namespace: ${NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: ${NS}
  labels: {app: checkout}
spec:
  replicas: 1
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      serviceAccountName: ${APP_SA}
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: checkout
          image: ${APP_IMAGE}
          command: ["/bin/sh", "/probe/probe.sh"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 10m, memory: 32Mi}
            limits:   {cpu: 200m, memory: 128Mi}
          volumeMounts:
            - name: probe
              mountPath: /probe
              readOnly: true
      volumes:
        - name: probe
          configMap:
            name: checkout-probe
            defaultMode: 0555
---
# The frontend never talks to the API server. It still gets a token today.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: ${NS}
  labels: {app: frontend}
spec:
  replicas: 1
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: frontend
          image: ${APP_IMAGE}
          command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 10m, memory: 32Mi}
            limits:   {cpu: 100m, memory: 64Mi}
YAML

  say "waiting for the baseline rollout (image pull can take a while)"
  "$KUBECTL" -n "$NS" rollout status deploy/checkout --timeout=180s || \
      warn "checkout did not become ready — check 'kubectl -n $NS describe pod -l app=checkout' (image pull?)"
  "$KUBECTL" -n "$NS" rollout status deploy/frontend --timeout=120s || true

  sleep 8
  say "baseline log sample:"
  "$KUBECTL" -n "$NS" logs deploy/checkout --tail=3 2>/dev/null || true
  good "baseline ready — the checkout pod should be printing RESULT=200"
}

# --------------------------------- the break ---------------------------------
break_it() {
  say "injecting faults"

  # FAULT 1 (authentication): the workload identity is no longer projected.
  "$KUBECTL" -n "$NS" patch serviceaccount "$APP_SA" \
      --type=merge -p '{"automountServiceAccountToken": false}' >/dev/null

  # FAULT 2 (authorization): the binding points at a ServiceAccount with the
  # right NAME in the wrong NAMESPACE. Kubernetes will not complain: RBAC
  # subjects are not validated against existing objects.
  "$KUBECTL" -n "$NS" patch rolebinding checkout-config-reader --type=merge \
      -p '{"subjects":[{"kind":"ServiceAccount","name":"'"$APP_SA"'","namespace":"default"}]}' >/dev/null

  # FAULT 3 (authorization): the Role now grants the wrong resource — and it
  # happens to be the database Secret. Wrong AND over-privileged.
  "$KUBECTL" -n "$NS" patch role checkout-config-reader --type=merge -p \
      '{"rules":[{"apiGroups":[""],"resources":["secrets"],"resourceNames":["payments-db"],"verbs":["get","list"]}]}' >/dev/null

  # FAULT 4 (standing privilege): somebody "fixed" the CI robot the fast way.
  "$KUBECTL" -n "$NS" delete rolebinding deployment-patcher --ignore-not-found >/dev/null
  "$KUBECTL" -n "$NS" delete role deployment-patcher --ignore-not-found >/dev/null
  "$KUBECTL" create clusterrolebinding "$CRB_ADMIN" \
      --clusterrole=cluster-admin \
      --serviceaccount="${NS}:${BOT_SA}" \
      --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null

  # FAULT 5 (anonymous access): a debugging binding that was never removed.
  "$KUBECTL" create clusterrolebinding "$CRB_ANON" \
      --clusterrole=view --group=system:unauthenticated \
      --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null

  # FAULT 6 is not injected: the frontend already carries a token it never uses.
  # The insecure default IS the finding.

  "$KUBECTL" -n "$NS" rollout restart deploy/checkout >/dev/null
  "$KUBECTL" -n "$NS" rollout status deploy/checkout --timeout=120s >/dev/null 2>&1 || true
  sleep 8
  good "faults injected"
}

briefing() {
  hr
  printf '%sCKS 5.2 — BREAK & FIX: least-privilege identity and access management%s\n' "$C_BOLD" "$C_0"
  hr
  cat <<'BRIEF'

SCENARIO
  Namespace "payments" runs two workloads and is automated by one robot:
    * Deployment/checkout  — reads ConfigMap "checkout-config" from the API
                             server at start-up and every 10s.
    * Deployment/frontend  — serves static assets; never calls the API server.
    * ServiceAccount/deploy-bot — the CI identity that patches Deployments.
  A night-shift change "to unblock the pipeline" went in without review.

SYMPTOMS YOU WILL SEE
  1) The checkout pod is Running but useless. Its log line is:
         RESULT=000 stage=auth  detail=no-serviceaccount-token-mounted
     There is NO /var/run/secrets/kubernetes.io/serviceaccount inside the
     container. This is an authentication problem, not an RBAC one.
  2) Once the identity is restored, the failure MOVES, it does not disappear:
         RESULT=403 stage=authz detail=... "configmaps ... is forbidden:
         User "system:serviceaccount:payments:checkout-sa" cannot get resource
         "configmaps" ... in the namespace "payments"
     Now it is an authorization problem — and there is more than one cause.
  3) `kubectl auth can-i --list --as=system:serviceaccount:payments:deploy-bot`
     answers with a single line: *.* on *.*  — the robot is cluster-admin.
  4) An unauthenticated caller can read the whole cluster.

YOUR MISSION (every item is graded by "verify")
  A. Make the checkout pod print RESULT=200 again.
  B. checkout-sa must end up able to GET exactly configmaps/checkout-config in
     namespace payments — and nothing else:
        - no get on configmaps/billing-config
        - no list on configmaps
        - no access to secrets/payments-db
        - no cluster-scoped permission at all
  C. deploy-bot must be able to get/list/watch/patch Deployments in payments
     and NOTHING more:
        - no delete on deployments
        - no permission in kube-system or any other namespace
        - no secrets anywhere
  D. No workload identity may hold cluster-admin.
  E. Anonymous / system:unauthenticated callers must not be able to read
     cluster resources.
  F. The frontend pod must not carry an API credential at all.

CONSTRAINTS
  * Do not grant cluster-admin, admin, edit or view to fix anything.
  * Do not delete the Secret or the decoy ConfigMap — the point is that they
    exist and stay unreachable.
  * Do not change the probe script or the container command.

DIAGNOSTIC COMMANDS WORTH KNOWING
  kubectl -n payments logs deploy/checkout --tail=5
  kubectl -n payments exec deploy/checkout -- ls /var/run/secrets/kubernetes.io/serviceaccount
  kubectl -n payments get rolebinding checkout-config-reader -o yaml
  kubectl -n payments describe role checkout-config-reader
  kubectl auth can-i --list --as=system:serviceaccount:payments:checkout-sa -n payments
  kubectl auth can-i get configmaps/checkout-config \
      --as=system:serviceaccount:payments:checkout-sa -n payments
  kubectl get clusterrolebinding -o wide | grep -E 'cluster-admin|unauthenticated'
  kubectl auth can-i list secrets -A --as=system:anonymous --as-group=system:unauthenticated

BRIEF
  printf '  Grade your work with: %s%s verify%s\n' "$C_BOLD" "$0" "$C_0"
  printf '  Stuck? %s hint      Give up? %s solution\n\n' "$0" "$0"
  hr
}

# --------------------------------- verifier ----------------------------------
PASS=0; FAIL=0
pass_c() { good "PASS  $*"; PASS=$((PASS+1)); }
fail_c() { bad  "FAIL  $*"; FAIL=$((FAIL+1)); }

cani() {  # cani <subject> <args...>  -> prints yes|no
  local as="$1"; shift
  "$KUBECTL" auth can-i "$@" --as="$as" 2>/dev/null || true
}
cani_anon() {
  "$KUBECTL" auth can-i "$@" --as=system:anonymous --as-group=system:unauthenticated 2>/dev/null || true
}
expect() {  # expect <yes|no> <actual> <description>
  if [ "$2" = "$1" ]; then pass_c "$3"; else fail_c "$3 (expected '$1', got '${2:-<error>}')"; fi
}

verify() {
  local app="system:serviceaccount:${NS}:${APP_SA}"
  local bot="system:serviceaccount:${NS}:${BOT_SA}"

  hr; printf '%sGRADING CKS 5.2 break & fix%s\n' "$C_BOLD" "$C_0"; hr

  # --- A. the workload works again ---
  local ready log
  ready="$("$KUBECTL" -n "$NS" get deploy checkout -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [ "${ready:-0}" -ge 1 ] && pass_c "A1 deployment/checkout has a ready replica" \
                          || fail_c "A1 deployment/checkout has no ready replica"

  log="$("$KUBECTL" -n "$NS" logs deploy/checkout --tail=6 2>/dev/null || true)"
  if printf '%s' "$log" | grep -q 'RESULT=200'; then
    pass_c "A2 checkout reads configmap/checkout-config (RESULT=200)"
  else
    fail_c "A2 checkout is not reading its ConfigMap yet"
    printf '      last log lines: %s\n' "$(printf '%s' "$log" | tail -2 | tr '\n' '|')"
  fi

  if "$KUBECTL" -n "$NS" get pods -l app=checkout -o json 2>/dev/null | grep -q 'kubernetes.io/serviceaccount'; then
    pass_c "A3 the checkout pod carries its ServiceAccount token"
  else
    fail_c "A3 no token projected into the checkout pod"
  fi

  # --- B. checkout-sa is scoped to one object ---
  expect yes "$(cani "$app" get configmaps/checkout-config -n "$NS")" "B1 checkout-sa CAN get configmaps/checkout-config"
  expect no  "$(cani "$app" get configmaps/billing-config -n "$NS")"  "B2 checkout-sa cannot get configmaps/billing-config"
  expect no  "$(cani "$app" list configmaps -n "$NS")"                "B3 checkout-sa cannot list configmaps"
  expect no  "$(cani "$app" get secrets/payments-db -n "$NS")"        "B4 checkout-sa cannot get secrets/payments-db"
  expect no  "$(cani "$app" get secrets -n "$NS")"                    "B5 checkout-sa cannot read Secrets"
  expect no  "$(cani "$app" list pods -n "$NS")"                      "B6 checkout-sa has no extra namespaced power"
  expect no  "$(cani "$app" get nodes)"                               "B7 checkout-sa has no cluster-scoped power"

  # --- C. deploy-bot is scoped to deployments in one namespace ---
  expect yes "$(cani "$bot" patch deployments -n "$NS")"          "C1 deploy-bot CAN patch deployments in $NS"
  expect yes "$(cani "$bot" get deployments -n "$NS")"            "C2 deploy-bot CAN get deployments in $NS"
  expect no  "$(cani "$bot" delete deployments -n "$NS")"         "C3 deploy-bot cannot delete deployments"
  expect no  "$(cani "$bot" patch deployments -n kube-system)"    "C4 deploy-bot has no power in kube-system"
  expect no  "$(cani "$bot" get secrets -n "$NS")"                "C5 deploy-bot cannot read Secrets"
  expect no  "$(cani "$bot" create clusterrolebindings)"          "C6 deploy-bot cannot escalate via RBAC"

  # --- D. no standing cluster-admin for workload identities ---
  local admins
  admins="$("$KUBECTL" get clusterrolebinding -o wide --no-headers 2>/dev/null \
            | awk '$2=="ClusterRole/cluster-admin"' | grep -E "${NS}/" || true)"
  if [ -z "$admins" ]; then
    pass_c "D1 no cluster-admin ClusterRoleBinding targets a $NS ServiceAccount"
  else
    fail_c "D1 cluster-admin still bound to a $NS identity:"
    printf '      %s\n' "$admins"
  fi

  # --- E. anonymous is closed ---
  expect no "$(cani_anon list secrets --all-namespaces)" "E1 anonymous cannot list Secrets"
  expect no "$(cani_anon get pods -n "$NS")"             "E2 anonymous cannot read Pods"
  expect no "$(cani_anon list namespaces)"               "E3 anonymous cannot list Namespaces"

  # --- F. no credential where none is needed ---
  if "$KUBECTL" -n "$NS" get pods -l app=frontend -o json 2>/dev/null | grep -q 'kubernetes.io/serviceaccount'; then
    fail_c "F1 the frontend pod still mounts an API token it never uses"
  else
    pass_c "F1 the frontend pod carries no API credential"
  fi

  hr
  if [ "$FAIL" -eq 0 ]; then
    printf '%sALL %d CHECKS PASSED%s — least privilege restored, function intact.\n' "$C_G$C_BOLD" "$PASS" "$C_0"
    printf 'Run "%s cleanup" to remove the lab objects.\n' "$0"
    hr; return 0
  fi
  printf '%s%d passed, %d failed%s — keep going (%s hint).\n' "$C_R$C_BOLD" "$PASS" "$FAIL" "$C_0" "$0"
  hr; return 1
}

# ---------------------------------- hints ------------------------------------
hint() {
  cat <<'HINTS'
HINT 1 — separate authn from authz.
  "no-serviceaccount-token-mounted" is not RBAC. Compare:
      kubectl -n payments get sa checkout-sa -o yaml
  against a healthy ServiceAccount. Which boolean field is set?
  Remember: RBAC changes take effect on the NEXT API request, but token
  projection is decided when the Pod is CREATED. Fixing the field is not
  enough — the running pod must be replaced.

HINT 2 — read the 403 message literally.
  The API server tells you exactly which user, which verb, which resource and
  which namespace were evaluated. Then ask the same question yourself:
      kubectl auth can-i --list --as=system:serviceaccount:payments:checkout-sa -n payments
  If that list does not contain what the pod needs, walk the chain backwards:
  RoleBinding subject -> Role name -> Role rules. Two of the three links are
  wrong. A RoleBinding subject of kind ServiceAccount REQUIRES the correct
  `namespace:` field — the API server accepts a subject that points at nothing.

HINT 3 — resourceNames is the difference between "least privilege" and "close
  enough". A rule with resourceNames grants only `get`-style verbs on the named
  objects; `list` and `watch` cannot be restricted by name.

HINT 4 — you cannot narrow a cluster-admin binding. Delete it and re-create the
  grant at the smallest scope that still works: a namespaced Role + RoleBinding.
  Verify with the negative test, not only the positive one:
      kubectl auth can-i patch deployments -n kube-system --as=...

HINT 5 — grep the cluster for the two groups every CKS candidate should check:
      kubectl get clusterrolebinding -o wide | grep -E 'system:(un)?authenticated'
  Bindings to system:unauthenticated or system:anonymous beyond
  system:public-info-viewer are always a finding.

HINT 6 — a Pod that never calls the API server should not have a token.
  The setting exists at two levels (ServiceAccount and Pod spec); prefer the
  narrowest one so you do not affect other workloads that share the SA.
HINTS
}

solution() { sed -n '/^# ===== SOLUTION/,$p' "$0"; }

cleanup() {
  say "removing lab objects"
  "$KUBECTL" delete clusterrolebinding "$CRB_ADMIN" "$CRB_ANON" --ignore-not-found >/dev/null 2>&1 || true
  "$KUBECTL" delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  good "cleanup requested (namespace deletion is asynchronous)"
  say  "pre-lab RBAC snapshot kept in $LAB_DIR"
}

# ----------------------------------- main ------------------------------------
main() {
  local cmd="break"
  for a in "$@"; do
    case "$a" in
      --yes|-y) ASSUME_YES=yes ;;
      setup|break|verify|hint|solution|cleanup) cmd="$a" ;;
      -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
      *) die "unknown argument: $a" ;;
    esac
  done

  case "$cmd" in
    verify)   trap - ERR; verify ;;
    hint)     trap - ERR; hint ;;
    solution) trap - ERR; solution ;;
    cleanup)  require_lab_cluster; cleanup ;;
    setup)    require_lab_cluster; snapshot; setup ;;
    break)    require_lab_cluster; snapshot; setup; break_it; briefing ;;
  esac
}

main "$@"
exit 0

# ===== SOLUTION =============================================================
# Do not read this until you have tried. Every command below is copy-pasteable.
#
# ---------------------------------------------------------------------------
# STEP 0 — Triage: is it authentication or authorization?
# ---------------------------------------------------------------------------
#   kubectl -n payments logs deploy/checkout --tail=3
#     ... RESULT=000 stage=auth detail=no-serviceaccount-token-mounted
#
#   kubectl -n payments exec deploy/checkout -- ls -l /var/run/secrets/kubernetes.io/serviceaccount
#     ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
#     command terminated with exit code 1
#
#   No token file => the request reaches the API server as system:anonymous.
#   RBAC is irrelevant while the identity itself is missing.
#
# ---------------------------------------------------------------------------
# STEP 1 — Restore the workload identity (fault 1)
# ---------------------------------------------------------------------------
#   kubectl -n payments get sa checkout-sa -o yaml | grep -i automount
#     automountServiceAccountToken: false
#
#   Re-enable it (either drop the field or set it to true):
#     kubectl -n payments patch sa checkout-sa --type=merge \
#       -p '{"automountServiceAccountToken": true}'
#
#   Token projection is decided at Pod admission, so the running Pod will never
#   get a token. Replace it:
#     kubectl -n payments rollout restart deploy/checkout
#     kubectl -n payments rollout status  deploy/checkout --timeout=120s
#
#   kubectl -n payments logs deploy/checkout --tail=2
#     ... RESULT=403 stage=authz detail={"kind":"Status", ... "configmaps
#     \"checkout-config\" is forbidden: User
#     \"system:serviceaccount:payments:checkout-sa\" cannot get resource
#     \"configmaps\" in API group \"\" in the namespace \"payments\"" ...
#
#   Progress: authenticated, not authorized. 401 -> 403 is the signal.
#
# ---------------------------------------------------------------------------
# STEP 2 — Ask the authorizer directly
# ---------------------------------------------------------------------------
#   kubectl auth can-i --list --as=system:serviceaccount:payments:checkout-sa -n payments
#     Resources          Non-Resource URLs   Resource Names   Verbs
#     selfsubjectreviews []                  []               [create]
#     ...
#     secrets            []                  [payments-db]    [get list]
#
#   Two defects are visible at once: the SA has rights on Secrets (it must not)
#   and none on ConfigMaps (it must). Walk the chain backwards.
#
#   kubectl -n payments get rolebinding checkout-config-reader -o yaml
#     subjects:
#     - kind: ServiceAccount
#       name: checkout-sa
#       namespace: default        <-- wrong namespace: this subject is nobody
#     roleRef:
#       kind: Role
#       name: checkout-config-reader
#
#   Note: the SA listing above still showed secrets because `auth can-i --list`
#   aggregates every binding that matches; re-run it after each fix.
#
# ---------------------------------------------------------------------------
# STEP 3 — Fix the RoleBinding subject (fault 2)
# ---------------------------------------------------------------------------
#   roleRef is immutable; subjects are not, so a patch is enough:
#     kubectl -n payments patch rolebinding checkout-config-reader --type=merge \
#       -p '{"subjects":[{"kind":"ServiceAccount","name":"checkout-sa","namespace":"payments"}]}'
#
#   Equivalent declarative form (recreate if you prefer):
#     kubectl -n payments delete rolebinding checkout-config-reader
#     kubectl -n payments create rolebinding checkout-config-reader \
#       --role=checkout-config-reader \
#       --serviceaccount=payments:checkout-sa
#
# ---------------------------------------------------------------------------
# STEP 4 — Fix the Role rules (fault 3)
# ---------------------------------------------------------------------------
#   kubectl -n payments describe role checkout-config-reader
#     PolicyRule:
#       Resources  Non-Resource URLs  Resource Names  Verbs
#       secrets    []                 [payments-db]   [get list]
#
#   Replace the rule with the minimum the application actually issues: a single
#   GET on one named object.
#
#     cat <<'EOF' | kubectl apply -f -
#     apiVersion: rbac.authorization.k8s.io/v1
#     kind: Role
#     metadata:
#       name: checkout-config-reader
#       namespace: payments
#     rules:
#       - apiGroups: [""]
#         resources: ["configmaps"]
#         resourceNames: ["checkout-config"]
#         verbs: ["get"]
#     EOF
#
#   Imperative equivalent:
#     kubectl -n payments create role checkout-config-reader \
#       --verb=get --resource=configmaps --resource-name=checkout-config \
#       --dry-run=client -o yaml | kubectl apply -f -
#
#   Why resourceNames and not just `get configmaps`: the pod reads ONE object.
#   Granting the resource type would also expose billing-config and every future
#   ConfigMap in the namespace. Caveat to remember for the exam: resourceNames
#   cannot restrict `list`, `watch` or `create` — a client that needs to list is
#   a client you cannot scope by name.
#
#   RBAC is evaluated per request, so no restart is needed:
#     sleep 12; kubectl -n payments logs deploy/checkout --tail=2
#       ... RESULT=200 stage=ready detail=configmap/checkout-config-loaded
#
#   Confirm the negatives too:
#     kubectl auth can-i get configmaps/checkout-config --as=system:serviceaccount:payments:checkout-sa -n payments   # yes
#     kubectl auth can-i get configmaps/billing-config  --as=system:serviceaccount:payments:checkout-sa -n payments   # no
#     kubectl auth can-i list configmaps                --as=system:serviceaccount:payments:checkout-sa -n payments   # no
#     kubectl auth can-i get secrets/payments-db        --as=system:serviceaccount:payments:checkout-sa -n payments   # no
#
# ---------------------------------------------------------------------------
# STEP 5 — Remove standing cluster-admin and re-grant the minimum (fault 4)
# ---------------------------------------------------------------------------
#   Find it:
#     kubectl get clusterrolebinding -o wide | awk 'NR==1 || $2=="ClusterRole/cluster-admin"'
#       NAME                      ROLE                        AGE  USERS  GROUPS  SERVICEACCOUNTS
#       cluster-admin             ClusterRole/cluster-admin   30d          system:masters
#       legacy-ops-cluster-admin  ClusterRole/cluster-admin   4m                   payments/deploy-bot
#
#     kubectl auth can-i --list --as=system:serviceaccount:payments:deploy-bot
#       Resources  Non-Resource URLs  Resource Names  Verbs
#       *.*        []                 []              [*]
#
#   A cluster-admin binding cannot be narrowed — delete it. Do NOT touch the
#   built-in `cluster-admin` binding to system:masters.
#     kubectl delete clusterrolebinding legacy-ops-cluster-admin
#
#   Re-grant only what the CI robot does — patch Deployments in one namespace:
#     cat <<'EOF' | kubectl apply -f -
#     apiVersion: rbac.authorization.k8s.io/v1
#     kind: Role
#     metadata:
#       name: deployment-patcher
#       namespace: payments
#     rules:
#       - apiGroups: ["apps"]
#         resources: ["deployments"]
#         verbs: ["get", "list", "watch", "patch"]
#     ---
#     apiVersion: rbac.authorization.k8s.io/v1
#     kind: RoleBinding
#     metadata:
#       name: deployment-patcher
#       namespace: payments
#     roleRef:
#       apiGroup: rbac.authorization.k8s.io
#       kind: Role
#       name: deployment-patcher
#     subjects:
#       - kind: ServiceAccount
#         name: deploy-bot
#         namespace: payments
#     EOF
#
#   Note the deliberate omissions: no "delete", no "create", no
#   deployments/scale unless the pipeline really scales, and a Role (namespaced)
#   instead of a ClusterRole. A ClusterRole bound with a RoleBinding would also
#   work and is reusable across namespaces — but a ClusterRole bound with a
#   ClusterRoleBinding is what turns a per-namespace grant into a cluster-wide
#   one by accident.
#
#   Verify both directions:
#     kubectl auth can-i patch deployments -n payments    --as=system:serviceaccount:payments:deploy-bot  # yes
#     kubectl auth can-i delete deployments -n payments   --as=system:serviceaccount:payments:deploy-bot  # no
#     kubectl auth can-i patch deployments -n kube-system --as=system:serviceaccount:payments:deploy-bot  # no
#     kubectl auth can-i get secrets -A                   --as=system:serviceaccount:payments:deploy-bot  # no
#
# ---------------------------------------------------------------------------
# STEP 6 — Close anonymous access (fault 5)
# ---------------------------------------------------------------------------
#   kubectl get clusterrolebinding -o wide | grep -E 'system:(un)?authenticated|anonymous'
#     anonymous-view              ClusterRole/view                 5m   system:unauthenticated
#     system:public-info-viewer   ClusterRole/system:public-...    30d  system:authenticated,system:unauthenticated
#
#   system:public-info-viewer is legitimate (nonResourceURLs /version, /healthz).
#   anonymous-view is not:
#     kubectl auth can-i list secrets -A --as=system:anonymous --as-group=system:unauthenticated
#       yes                              <-- every Secret in the cluster, unauthenticated
#     kubectl delete clusterrolebinding anonymous-view
#     kubectl auth can-i list secrets -A --as=system:anonymous --as-group=system:unauthenticated
#       no
#
#   Defence in depth beyond RBAC (do this on a real cluster, not required here):
#   set --anonymous-auth=false in /etc/kubernetes/manifests/kube-apiserver.yaml,
#   or use AuthenticationConfiguration to keep anonymous only for /healthz,
#   /livez and /readyz. Editing the static pod manifest restarts the API server:
#   verify the file is valid before saving, and watch
#   `crictl ps | grep kube-apiserver` come back.
#
# ---------------------------------------------------------------------------
# STEP 7 — No credential where none is needed (fault 6)
# ---------------------------------------------------------------------------
#   kubectl -n payments exec deploy/frontend -- \
#     ls /var/run/secrets/kubernetes.io/serviceaccount
#       ca.crt  namespace  token          <-- a usable API credential in a pod
#                                             that never calls the API server
#
#   Disable it at the Pod level (narrowest blast radius — the `default` SA is
#   shared, so patching the SA would affect anything else that uses it):
#     kubectl -n payments patch deploy frontend --type=merge \
#       -p '{"spec":{"template":{"spec":{"automountServiceAccountToken": false}}}}'
#     kubectl -n payments rollout status deploy/frontend --timeout=120s
#     kubectl -n payments exec deploy/frontend -- \
#       ls /var/run/secrets/kubernetes.io/serviceaccount
#         ls: ...: No such file or directory      <-- expected
#
#   Precedence: the Pod-level field always wins over the ServiceAccount-level
#   field. Hardening pattern for a new namespace — turn the default off and let
#   each workload opt in:
#     kubectl -n payments patch sa default --type=merge \
#       -p '{"automountServiceAccountToken": false}'
#
# ---------------------------------------------------------------------------
# STEP 8 — Grade and clean up
# ---------------------------------------------------------------------------
#   ./cks-5.2-break-fix.sh verify        # expect: ALL 20 CHECKS PASSED
#   ./cks-5.2-break-fix.sh cleanup
#
# ---------------------------------------------------------------------------
# EXAM TAKEAWAYS
# ---------------------------------------------------------------------------
#   * 401 / "no token" => identity problem (automount, expired or wrong token,
#     projected volume). 403 => RBAC problem. Read the verb, resource, apiGroup
#     and namespace straight out of the message; the API server has already done
#     the diagnosis for you.
#   * `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa> -n <ns>`
#     is the fastest RBAC tool in the exam. Always test the negatives too — a
#     fix that only proves "yes" proves nothing about least privilege.
#   * The RoleBinding subject for a ServiceAccount MUST carry `namespace:`.
#     A wrong namespace produces a binding that is syntactically valid, silently
#     accepted, and grants nothing.
#   * roleRef is immutable: to repoint a binding you delete and recreate it.
#   * RBAC decisions apply to the next request; token projection applies at Pod
#     creation. Only the second one needs a rollout.
#   * Prefer Role + RoleBinding over ClusterRole + ClusterRoleBinding. Prefer
#     resourceNames over whole resource types. Never grant `*` verbs, `*`
#     resources, `escalate`, `bind`, `impersonate`, or create/patch on RBAC
#     objects to a workload.
#   * Audit routinely for: bindings to cluster-admin, to system:masters, to
#     system:unauthenticated / system:anonymous, and for SAs with secrets get
#     (equivalent to reading every credential in the namespace).
# ===========================================================================