#!/usr/bin/env bash
#
# =============================================================================
#  KCA 5.5 — Generation Rules  ·  break & fix lab  (exam weight 2.91%)
# =============================================================================
#
#  Kyverno Certified Associate (KCA) — Kyverno policy types: generate rules.
#
#  Scenario
#  --------
#  You run the platform team of a multi-tenant cluster. Every namespace labelled
#  `kca.lab/tenant=true` must be born with a full baseline: a default-deny
#  NetworkPolicy, a ResourceQuota, a cloned ConfigMap coming from the platform
#  namespace, and a custom `TenantGuard` object consumed by an internal
#  controller. All of that is produced by ONE Kyverno ClusterPolicy made of four
#  `generate` rules.
#
#  It worked. This script proves it works, then breaks it in four different and
#  very realistic ways, and hands the cluster to you.
#
#  What this script does NOT do
#  ----------------------------
#  It never touches Kyverno's own RBAC, never edits kube-system, never deletes a
#  resource it did not create. Every object it creates carries the label
#  `app.kubernetes.io/part-of=kca-5-5-lab` and `clean` removes exactly those.
#  Still: run it ONLY on a disposable lab cluster (kind / k3d / minikube / a
#  throwaway kubeadm VM). It refuses unfamiliar kube-contexts unless you force it.
#
#  Usage
#  -----
#    ./kca-5.5-generation-rules-breakfix.sh install-kyverno   # optional
#    ./kca-5.5-generation-rules-breakfix.sh setup             # green baseline + proof
#    ./kca-5.5-generation-rules-breakfix.sh break             # inject the 4 faults
#    ./kca-5.5-generation-rules-breakfix.sh status            # triage dashboard
#    ./kca-5.5-generation-rules-breakfix.sh hints [1|2|3]     # progressive hints
#    ./kca-5.5-generation-rules-breakfix.sh verify            # grade your fix
#    ./kca-5.5-generation-rules-breakfix.sh clean             # remove the lab
#
#  Requirements: kubectl >= 1.27, a Kyverno install with the background
#  controller enabled (Kyverno >= 1.10 for `spec.generateExisting`), cluster-admin.
#
#  Reference sources (official)
#  ----------------------------
#   - KCA curriculum (CNCF):
#       https://github.com/cncf/curriculum
#       https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#   - Kyverno documentation root:            https://kyverno.io/docs/
#   - Generate rules:                        https://kyverno.io/docs/writing-policies/generate/
#       (docs were restructured in 1.13; if that path redirects, use
#        https://kyverno.io/docs/policy-types/cluster-policy/generate/)
#   - Customizing Kyverno permissions (RBAC aggregation for the background
#     controller):                           https://kyverno.io/docs/installation/customization/
#   - Troubleshooting:                       https://kyverno.io/docs/troubleshooting/
#   - Kyverno source / CRDs:                 https://github.com/kyverno/kyverno
#   - Kubernetes aggregated ClusterRoles:
#       https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#   - Kubernetes NetworkPolicy / ResourceQuota:
#       https://kubernetes.io/docs/concepts/services-networking/network-policies/
#       https://kubernetes.io/docs/concepts/policy/resource-quotas/
#
#  ****  THE FULL STEP-BY-STEP SOLUTION IS AT THE BOTTOM OF THIS FILE,  ****
#  ****  COMMENTED OUT. DO NOT SCROLL THERE UNTIL YOU HAVE TRIED.       ****
# =============================================================================

set -Eeuo pipefail
trap 'printf "\n[!] %s: line %s exited %s\n" "${BASH_SOURCE[0]}" "$LINENO" "$?" >&2' ERR

# ------------------------------- constants ----------------------------------
readonly LAB_KEY="app.kubernetes.io/part-of"
readonly LAB_VAL="kca-5-5-lab"
readonly LAB_SEL="${LAB_KEY}=${LAB_VAL}"

readonly POLICY="tenant-namespace-baseline"
readonly EXTRA_ROLE="kyverno:background-controller:kca-lab"
readonly AGG_LABEL="rbac.kyverno.io/aggregate-to-background-controller"

readonly SRC_NS="platform-system"        # where the clone source lives at setup
readonly SRC_NS_MOVED="platform-baselines"  # where "a refactor" moved it
readonly SRC_CM="tenant-baseline"

readonly GREEN_NS="lab-green"            # used only to prove the green state
readonly TENANT_NS="lab-tenant-a"        # created AFTER the break
readonly LEGACY_NS="lab-legacy"          # exists BEFORE the policy is re-applied

readonly CRD_GROUP="lab.kca.local"
readonly CRD_PLURAL="tenantguards"
readonly CRD_NAME="${CRD_PLURAL}.${CRD_GROUP}"
readonly GUARD_NAME="baseline-guard"

KYVERNO_NS=""
BG_SA=""
BG_DEPLOY=""
KYVERNO_IMAGE=""

# ------------------------------- output -------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
  C_Y=$'\033[33m'; C_C=$'\033[36m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_C" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "-------------------------------------------------------------------------------"; }
head1(){ printf '\n%s%s%s\n' "$C_B" "$*" "$C_RST"; hr; }

run() {  # echo the command, then run it — the student should be able to replay it
  printf '%s$ %s%s\n' "$C_C" "$*" "$C_RST"
  "$@" || true
}

# ------------------------------- helpers ------------------------------------
need_bin() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }

wait_for() {  # wait_for <timeout-seconds> <command...>
  local timeout="$1"; shift
  local deadline=$(( SECONDS + timeout ))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS >= deadline )) && return 1
    sleep 3
  done
  return 0
}

detect_kyverno() {
  KYVERNO_NS="$(kubectl get deploy -A -l app.kubernetes.io/component=background-controller \
      -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [[ -n "$KYVERNO_NS" ]] || die "Kyverno background controller not found. Run: $0 install-kyverno"

  BG_DEPLOY="$(kubectl -n "$KYVERNO_NS" get deploy -l app.kubernetes.io/component=background-controller \
      -o jsonpath='{.items[0].metadata.name}')"
  BG_SA="$(kubectl -n "$KYVERNO_NS" get deploy "$BG_DEPLOY" \
      -o jsonpath='{.spec.template.spec.serviceAccountName}')"
  KYVERNO_IMAGE="$(kubectl -n "$KYVERNO_NS" get deploy "$BG_DEPLOY" \
      -o jsonpath='{.spec.template.spec.containers[0].image}')"
}

bg_user() { printf 'system:serviceaccount:%s:%s' "$KYVERNO_NS" "$BG_SA"; }

can_bg_create() {  # can_bg_create <resource> <namespace>
  [[ "$(kubectl auth can-i create "$1" --as="$(bg_user)" -n "$2" 2>/dev/null)" == "yes" ]]
}

guard_lab() {
  local ctx nodes
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  head1 "SAFETY CHECK"
  say "  kube-context : ${ctx}"
  say "  nodes        : ${nodes}"
  local pattern="${LAB_CONTEXT_REGEX:-^(kind-|k3d-|minikube|rancher-desktop|colima|docker-desktop|kca-lab|vagrant|kubernetes-admin@)}"
  if [[ "$ctx" =~ $pattern && "$nodes" -le 5 ]]; then
    ok "context looks like a disposable lab"
    return 0
  fi
  warn "This context does not look like a throwaway lab cluster."
  if [[ "${KCA_LAB_CONFIRM:-}" == "yes" ]]; then
    warn "KCA_LAB_CONFIRM=yes — proceeding anyway."
    return 0
  fi
  die "Refusing to touch it. Re-run with KCA_LAB_CONFIRM=yes if you are sure."
}

# ------------------------------- manifests ----------------------------------
render_crd() {
  cat <<YAML
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${CRD_NAME}
  labels:
    ${LAB_KEY}: ${LAB_VAL}
spec:
  group: ${CRD_GROUP}
  scope: Namespaced
  names:
    kind: TenantGuard
    listKind: TenantGuardList
    plural: ${CRD_PLURAL}
    singular: tenantguard
    shortNames: [tg]
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                tier:
                  type: string
                contact:
                  type: string
YAML
}

render_extra_clusterrole() {  # $1 = "aggregated" | "orphan"
  local labels="    ${LAB_KEY}: ${LAB_VAL}"
  if [[ "${1:-aggregated}" == "aggregated" ]]; then
    labels="${labels}
    ${AGG_LABEL}: \"true\""
  fi
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${EXTRA_ROLE}
  labels:
${labels}
rules:
  - apiGroups: ["${CRD_GROUP}"]
    resources: ["${CRD_PLURAL}"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
YAML
}

# The policy. Four generate rules, one trigger (Namespace with kca.lab/tenant=true).
#   rule 0  data  -> NetworkPolicy   (synchronize is the variable under test)
#   rule 1  data  -> ResourceQuota   (downstream namespace expression under test)
#   rule 2  clone -> ConfigMap       (clone source under test)
#   rule 3  data  -> TenantGuard CR  (background-controller RBAC under test)
render_policy() {
  local variant="${1:-healthy}"
  local gen_existing="true" netpol_sync="true" quota_ns='{{request.object.metadata.name}}'
  if [[ "$variant" == "broken" ]]; then
    gen_existing="false"
    netpol_sync="false"
    quota_ns='{{request.namespace}}'
  fi
  cat <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY}
  labels:
    ${LAB_KEY}: ${LAB_VAL}
  annotations:
    policies.kyverno.io/title: Tenant namespace baseline
    policies.kyverno.io/category: Multi-Tenancy
    policies.kyverno.io/subject: Namespace, NetworkPolicy, ResourceQuota, ConfigMap, TenantGuard
spec:
  background: true
  generateExisting: ${gen_existing}
  rules:
    - name: gen-default-deny-netpol
      match:
        any:
          - resources:
              kinds:
                - Namespace
              selector:
                matchLabels:
                  kca.lab/tenant: "true"
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-ingress
        namespace: "{{request.object.metadata.name}}"
        synchronize: ${netpol_sync}
        data:
          metadata:
            labels:
              ${LAB_KEY}: ${LAB_VAL}
          spec:
            podSelector: {}
            policyTypes:
              - Ingress

    - name: gen-tenant-quota
      match:
        any:
          - resources:
              kinds:
                - Namespace
              selector:
                matchLabels:
                  kca.lab/tenant: "true"
      generate:
        apiVersion: v1
        kind: ResourceQuota
        name: tenant-quota
        namespace: "${quota_ns}"
        synchronize: true
        data:
          metadata:
            labels:
              ${LAB_KEY}: ${LAB_VAL}
          spec:
            hard:
              requests.cpu: "4"
              requests.memory: 8Gi
              limits.cpu: "8"
              limits.memory: 16Gi
              pods: "20"

    - name: clone-platform-baseline
      match:
        any:
          - resources:
              kinds:
                - Namespace
              selector:
                matchLabels:
                  kca.lab/tenant: "true"
      generate:
        apiVersion: v1
        kind: ConfigMap
        name: ${SRC_CM}
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        clone:
          namespace: ${SRC_NS}
          name: ${SRC_CM}

    - name: gen-tenant-guard
      match:
        any:
          - resources:
              kinds:
                - Namespace
              selector:
                matchLabels:
                  kca.lab/tenant: "true"
      generate:
        apiVersion: ${CRD_GROUP}/v1
        kind: TenantGuard
        name: ${GUARD_NAME}
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          metadata:
            labels:
              ${LAB_KEY}: ${LAB_VAL}
          spec:
            tier: standard
            contact: platform@example.invalid
YAML
}

make_tenant_ns() {  # make_tenant_ns <name>
  kubectl create namespace "$1" >/dev/null 2>&1 || true
  kubectl label namespace "$1" "kca.lab/tenant=true" "${LAB_SEL}" --overwrite >/dev/null
}

# ------------------------------- subcommands --------------------------------
cmd_install_kyverno() {
  need_bin kubectl; need_bin helm
  guard_lab
  head1 "INSTALLING KYVERNO (helm)"
  run helm repo add kyverno https://kyverno.github.io/kyverno
  run helm repo update
  local args=(install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
              --set backgroundController.enabled=true
              --set admissionController.replicas=1)
  [[ -n "${KYVERNO_CHART_VERSION:-}" ]] && args+=(--version "${KYVERNO_CHART_VERSION}")
  run helm "${args[@]}"
  detect_kyverno
  ok "Kyverno ready in namespace '${KYVERNO_NS}' (image ${KYVERNO_IMAGE})"
}

cmd_setup() {
  need_bin kubectl
  guard_lab
  detect_kyverno

  head1 "PRE-FLIGHT"
  say "  kyverno namespace          : ${KYVERNO_NS}"
  say "  background controller      : deploy/${BG_DEPLOY}"
  say "  background controller SA   : $(bg_user)"
  say "  kyverno image              : ${KYVERNO_IMAGE}"
  kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 \
    || die "kyverno CRDs missing"
  kubectl get crd updaterequests.kyverno.io >/dev/null 2>&1 \
    || warn "updaterequests CRD not found — generate telemetry will be limited"
  kubectl -n "$KYVERNO_NS" rollout status "deploy/${BG_DEPLOY}" --timeout=120s >/dev/null \
    || die "background controller is not ready"
  case "$KYVERNO_IMAGE" in
    *:v1.[0-9].*|*:v1.10.*) warn "Kyverno < 1.11 detected: 'spec.generateExisting' may be named 'generateExistingOnPolicyUpdate'";;
  esac
  ok "pre-flight passed"

  head1 "1/5 · custom resource the platform controller consumes"
  render_crd | kubectl apply -f - >/dev/null
  kubectl wait --for=condition=Established "crd/${CRD_NAME}" --timeout=60s >/dev/null
  ok "CRD ${CRD_NAME} established"
  info "restarting the background controller so its discovery cache sees the new CRD"
  kubectl -n "$KYVERNO_NS" rollout restart "deploy/${BG_DEPLOY}" >/dev/null
  kubectl -n "$KYVERNO_NS" rollout status "deploy/${BG_DEPLOY}" --timeout=180s >/dev/null
  ok "background controller restarted"

  head1 "2/5 · RBAC for the background controller (aggregated ClusterRole)"
  say "Kyverno generates downstream resources with the background controller's"
  say "ServiceAccount. It cannot create a kind nobody granted it. Baseline first:"
  if can_bg_create "$CRD_PLURAL" "default"; then
    warn "the background controller can ALREADY create ${CRD_PLURAL} — fault #1 will be inert"
  else
    ok "as expected, $(bg_user) cannot create ${CRD_PLURAL} yet"
  fi
  render_extra_clusterrole aggregated | kubectl apply -f - >/dev/null
  sleep 5
  if can_bg_create "$CRD_PLURAL" "default"; then
    ok "aggregation worked: it can now create ${CRD_PLURAL}"
  else
    warn "aggregation has not propagated yet; continuing"
  fi

  head1 "3/5 · clone source"
  kubectl create namespace "$SRC_NS" >/dev/null 2>&1 || true
  kubectl label namespace "$SRC_NS" "${LAB_SEL}" --overwrite >/dev/null
  kubectl -n "$SRC_NS" create configmap "$SRC_CM" \
    --from-literal=tenant-tier=standard \
    --from-literal=log-endpoint=https://logs.platform.svc.cluster.local:9200 \
    --from-literal=owner=platform-team \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$SRC_NS" label configmap "$SRC_CM" "${LAB_SEL}" --overwrite >/dev/null
  ok "source ConfigMap ${SRC_NS}/${SRC_CM} in place"

  head1 "4/5 · the ClusterPolicy (healthy)"
  render_policy healthy | kubectl apply -f - >/dev/null
  sleep 3
  run kubectl get clusterpolicy "$POLICY"
  ok "policy applied"

  head1 "5/5 · GREEN PROOF — this is what 'working' looks like"
  make_tenant_ns "$GREEN_NS"
  local green_ok=1
  wait_for 90 kubectl -n "$GREEN_NS" get netpol default-deny-ingress || green_ok=0
  wait_for 90 kubectl -n "$GREEN_NS" get resourcequota tenant-quota   || green_ok=0
  wait_for 90 kubectl -n "$GREEN_NS" get configmap "$SRC_CM"          || green_ok=0
  wait_for 90 kubectl -n "$GREEN_NS" get "${CRD_PLURAL}.${CRD_GROUP}" "$GUARD_NAME" || green_ok=0
  run kubectl -n "$GREEN_NS" get netpol,resourcequota,configmap,"${CRD_PLURAL}.${CRD_GROUP}"
  say ""
  say "Every downstream carries the provenance labels Kyverno stamps on generated"
  say "resources — memorise them, they are your fastest triage tool:"
  run kubectl -n "$GREEN_NS" get netpol default-deny-ingress -o jsonpath='{.metadata.labels}'
  say ""
  if (( green_ok == 1 )); then
    ok "green state confirmed: 4 downstream resources generated from 1 namespace"
  else
    warn "the green state is INCOMPLETE — fix the environment before breaking it"
    run kubectl -n "$KYVERNO_NS" get updaterequests.kyverno.io
    die "aborting: a lab must start green"
  fi
  kubectl delete namespace "$GREEN_NS" --wait=false >/dev/null 2>&1 || true
  info "tearing down ${GREEN_NS}; run '$0 break' when you are ready"
}

cmd_break() {
  need_bin kubectl
  guard_lab
  detect_kyverno

  kubectl get clusterpolicy "$POLICY" >/dev/null 2>&1 || die "run '$0 setup' first"

  head1 "INJECTING FAULTS"

  # --- prepare the "pre-existing namespace" case ------------------------------
  info "removing the policy so a tenant namespace can pre-date it"
  kubectl delete clusterpolicy "$POLICY" --ignore-not-found >/dev/null
  sleep 4
  make_tenant_ns "$LEGACY_NS"
  ok "namespace ${LEGACY_NS} exists and is labelled, with NO policy in force"

  # --- fault 1: RBAC aggregation ---------------------------------------------
  info "fault 1/4 — de-aggregating the custom ClusterRole"
  kubectl label clusterrole "$EXTRA_ROLE" "${AGG_LABEL}-" >/dev/null 2>&1 || true
  sleep 5
  if can_bg_create "$CRD_PLURAL" "default"; then
    warn "fault 1 did not bite: something else still grants ${CRD_PLURAL}"
  else
    ok "background controller can no longer create ${CRD_PLURAL}"
  fi

  # --- fault 2: clone source relocated ---------------------------------------
  info "fault 2/4 — 'platform refactor': moving the clone source namespace"
  kubectl create namespace "$SRC_NS_MOVED" >/dev/null 2>&1 || true
  kubectl label namespace "$SRC_NS_MOVED" "${LAB_SEL}" --overwrite >/dev/null
  kubectl -n "$SRC_NS" get configmap "$SRC_CM" -o yaml 2>/dev/null \
    | sed -e "s/^  namespace: ${SRC_NS}\$/  namespace: ${SRC_NS_MOVED}/" \
    | kubectl -n "$SRC_NS_MOVED" apply -f - >/dev/null 2>&1 || \
    kubectl -n "$SRC_NS_MOVED" create configmap "$SRC_CM" \
      --from-literal=tenant-tier=standard \
      --from-literal=log-endpoint=https://logs.platform.svc.cluster.local:9200 \
      --from-literal=owner=platform-team >/dev/null
  kubectl -n "$SRC_NS_MOVED" label configmap "$SRC_CM" "${LAB_SEL}" --overwrite >/dev/null
  kubectl -n "$SRC_NS" delete configmap "$SRC_CM" --ignore-not-found >/dev/null
  ok "${SRC_CM} now lives in ${SRC_NS_MOVED}; ${SRC_NS} still exists but is empty"

  # --- faults 3 and 4: policy fields -----------------------------------------
  info "fault 3/4 and 4/4 — re-applying the policy with two altered fields"
  render_policy broken | kubectl apply -f - >/dev/null
  sleep 5
  ok "policy re-applied"

  # --- the trigger the student will look at -----------------------------------
  info "onboarding a brand-new tenant namespace under the broken policy"
  make_tenant_ns "$TENANT_NS"
  sleep 12

  cat <<BRIEF

${C_B}=============================== YOUR BRIEFING ===============================${C_RST}

A "harmless" platform change window just closed. Since then the tenant
onboarding baseline is not landing. Two namespaces are in play:

  ${C_B}${TENANT_NS}${C_RST}  — created AFTER the change window (admission-time trigger)
  ${C_B}${LEGACY_NS}${C_RST}   — already existed BEFORE the current policy was applied

${C_B}SYMPTOMS YOU WILL SEE${C_RST}

1) The new tenant namespace is missing most of its baseline:

     \$ kubectl -n ${TENANT_NS} get netpol,resourcequota,configmap,${CRD_PLURAL}.${CRD_GROUP}
     NAME                                            POD-SELECTOR   AGE
     networkpolicy.networking.k8s.io/default-deny-ingress   <none>   1m
     NAME                       DATA   AGE
     configmap/kube-root-ca.crt   1    1m
     No resources found ...        <- no ResourceQuota, no cloned ConfigMap, no TenantGuard

2) The legacy namespace got ${C_B}nothing at all${C_RST}, not even the NetworkPolicy:

     \$ kubectl -n ${LEGACY_NS} get netpol
     No resources found in ${LEGACY_NS} namespace.

3) UpdateRequests — Kyverno's work queue for generate/mutate-existing — are
   piling up in state Failed instead of being consumed and garbage-collected:

     \$ kubectl -n ${KYVERNO_NS} get updaterequests.kyverno.io \\
         -o custom-columns='NAME:.metadata.name,POLICY:.spec.policy,STATE:.status.state,MSG:.status.message'
     NAME       POLICY                      STATE    MSG
     ur-x7k2p   ${POLICY}   Failed   ... is forbidden: User "$(bg_user)" cannot create resource "${CRD_PLURAL}" ...
     ur-q9m4t   ${POLICY}   Failed   ... source resource ${SRC_NS}/${SRC_CM} not found ...
   (column names differ slightly between Kyverno versions; fall back to -o yaml)

4) The one resource that IS created no longer self-heals. Delete it and it stays
   deleted — a tenant can silently opt out of the default-deny NetworkPolicy:

     \$ kubectl -n ${TENANT_NS} delete netpol default-deny-ingress
     \$ sleep 20; kubectl -n ${TENANT_NS} get netpol
     No resources found in ${TENANT_NS} namespace.

5) PolicyReports will NOT help you here — generate rules do not emit them.
   Your telemetry is: UpdateRequests, events on the ClusterPolicy, and the
   background controller logs.

${C_B}WHAT YOU MUST ACHIEVE (definition of done)${C_RST}

  A. ${TENANT_NS} carries all four downstream resources:
     NetworkPolicy/default-deny-ingress, ResourceQuota/tenant-quota,
     ConfigMap/${SRC_CM}, TenantGuard/${GUARD_NAME}.
  B. ${LEGACY_NS} — which pre-dates the policy — carries them too, without you
     creating a single one of them by hand.
  C. Deleting a generated resource makes Kyverno restore it within ~30s.
  D. Editing the clone source propagates to every tenant copy.
  E. No UpdateRequest is left in state Failed.

${C_B}RULES OF THE GAME${C_RST}

  * You may edit the ClusterPolicy, RBAC and the platform namespaces.
  * You may NOT create the downstream resources by hand, and you may NOT
    delete the tenant namespaces to "start over" — in production you cannot
    delete a tenant to fix your policy.
  * There are ${C_B}four independent faults${C_RST}. Two live in the ClusterPolicy,
    one in RBAC, one in the platform namespaces.

${C_B}COMMANDS${C_RST}

  $0 status        triage dashboard
  $0 hints 1|2|3   progressive hints
  $0 verify        grade yourself
  $0 clean         wipe the lab

BRIEF
}

cmd_status() {
  need_bin kubectl
  detect_kyverno

  head1 "POLICY"
  run kubectl get clusterpolicy "$POLICY" -o wide
  run kubectl get clusterpolicy "$POLICY" \
      -o jsonpath='generateExisting={.spec.generateExisting}{"\n"}rule0.synchronize={.spec.rules[0].generate.synchronize}{"\n"}rule1.namespace={.spec.rules[1].generate.namespace}{"\n"}rule2.clone={.spec.rules[2].generate.clone}{"\n"}'
  say ""

  head1 "UPDATE REQUESTS (the generate work queue)"
  run kubectl -n "$KYVERNO_NS" get updaterequests.kyverno.io \
      -o custom-columns='NAME:.metadata.name,POLICY:.spec.policy,TYPE:.spec.requestType,STATE:.status.state,RETRY:.status.retryCount'
  say ""
  say "Full failure text of the first failed UR:"
  local ur
  ur="$(kubectl -n "$KYVERNO_NS" get updaterequests.kyverno.io \
        -o jsonpath='{range .items[?(@.status.state=="Failed")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  if [[ -n "$ur" ]]; then
    run kubectl -n "$KYVERNO_NS" get updaterequests.kyverno.io "$ur" -o jsonpath='{.status.message}{"\n"}'
  else
    ok "no UpdateRequest in state Failed"
  fi

  head1 "DOWNSTREAM RESOURCES"
  for ns in "$TENANT_NS" "$LEGACY_NS"; do
    say "${C_B}${ns}${C_RST}"
    run kubectl -n "$ns" get netpol,resourcequota,configmap,"${CRD_PLURAL}.${CRD_GROUP}" 2>/dev/null
    say ""
  done
  say "Anything Kyverno generated anywhere, found by provenance label:"
  run kubectl get netpol,resourcequota,configmap,"${CRD_PLURAL}.${CRD_GROUP}" -A \
      -l generate.kyverno.io/policy-name="$POLICY"

  head1 "RBAC OF THE BACKGROUND CONTROLLER"
  say "  identity: $(bg_user)"
  for res in networkpolicies.networking.k8s.io resourcequotas configmaps "$CRD_PLURAL"; do
    printf '  can-i create %-34s -> %s\n' "$res" \
      "$(kubectl auth can-i create "$res" --as="$(bg_user)" -n "$TENANT_NS" 2>/dev/null || echo '?')"
  done
  say ""
  run kubectl get clusterrole "$EXTRA_ROLE" -o jsonpath='labels={.metadata.labels}{"\n"}'

  head1 "CLONE SOURCE"
  run kubectl get configmap -A -l "${LAB_SEL}" -o wide

  head1 "CONTROLLER LOGS (last generate-related lines)"
  printf '%s$ kubectl -n %s logs deploy/%s --tail=200 | grep -iE "generate|updaterequest|forbidden"%s\n' \
    "$C_C" "$KYVERNO_NS" "$BG_DEPLOY" "$C_RST"
  kubectl -n "$KYVERNO_NS" logs "deploy/${BG_DEPLOY}" --tail=200 2>/dev/null \
    | grep -iE 'generate|updaterequest|forbidden' | tail -n 15 || true
}

cmd_hints() {
  local level="${1:-1}"
  head1 "HINT LEVEL ${level}"
  case "$level" in
    1)
      cat <<'H1'
  * A generate rule has two halves: WHAT to create (data / clone) and WHO
    creates it. The "who" is never the user who triggered the rule — it is the
    Kyverno background controller ServiceAccount. Ask what that identity is
    allowed to do:  kubectl auth can-i create <resource> --as=system:serviceaccount:...
  * The queue object is the UpdateRequest. Read .status.message on every UR in
    state Failed; each one names its own root cause verbatim.
  * A `clone` generate rule has a source. Prove the source still exists, in the
    namespace the policy names, with `kubectl get -A`.
  * Compare the two namespaces: one was created after the policy, the other
    before it. That difference is a policy field, not an accident.
H1
      ;;
    2)
      cat <<H2
  * Fault A — RBAC. Kyverno grants its controllers permissions through
    ${C_B}aggregated ClusterRoles${C_RST}. A ClusterRole is picked up by the background
    controller only if it carries the label ${AGG_LABEL}="true".
    Inspect: kubectl get clusterrole ${EXTRA_ROLE} --show-labels
  * Fault B — the clone source is no longer where the policy points.
    kubectl get cm -A | grep ${SRC_CM}
  * Fault C — the ResourceQuota rule builds its target namespace from a
    variable. The trigger is a ${C_B}cluster-scoped${C_RST} Namespace object. What does
    {{request.namespace}} evaluate to for a cluster-scoped resource?
  * Fault D — two things: downstream drift is not repaired, and pre-existing
    triggers were never processed. Look at spec.rules[0].generate.synchronize
    and at spec.generateExisting.
  * ${C_B}And one trap${C_RST}: an UpdateRequest retries a bounded number of times. Fixing
    the root cause does not necessarily re-run an already-exhausted UR.
H2
      ;;
    3)
      cat <<H3
  * Restore the aggregation label:
      kubectl label clusterrole ${EXTRA_ROLE} ${AGG_LABEL}=true
  * Point the clone rule at the namespace where the ConfigMap actually lives now
    (spec.rules[2].generate.clone.namespace), or move the ConfigMap back.
  * For a Namespace trigger the downstream namespace is
    {{request.object.metadata.name}} — {{request.namespace}} is the empty string
    for a cluster-scoped object.
  * spec.rules[0].generate.synchronize: true    -> self-healing downstreams
    spec.generateExisting: true                 -> process triggers that already exist
  * Then force a re-evaluation, e.g.
      kubectl label ns ${TENANT_NS} kca.lab/reconcile=\$(date +%s) --overwrite
    and confirm no UR is left Failed.
H3
      ;;
    *) die "hint levels are 1, 2 or 3" ;;
  esac
}

cmd_verify() {
  need_bin kubectl
  detect_kyverno
  local pass=0 fail=0
  check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
      printf ' %s[PASS]%s %s\n' "$C_G" "$C_RST" "$desc"; pass=$((pass+1))
    else
      printf ' %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$desc"; fail=$((fail+1))
    fi
  }

  quota_is_correct() {
    [[ "$(kubectl -n "$TENANT_NS" get resourcequota tenant-quota \
          -o jsonpath='{.spec.hard.requests\.cpu}' 2>/dev/null)" == "4" ]]
  }
  clone_has_data() {
    [[ "$(kubectl -n "$TENANT_NS" get configmap "$SRC_CM" \
          -o jsonpath='{.data.tenant-tier}' 2>/dev/null)" == "standard" ]]
  }
  no_failed_urs() {
    local n
    n="$(kubectl -n "$KYVERNO_NS" get updaterequests.kyverno.io \
         -o jsonpath='{range .items[?(@.status.state=="Failed")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
         | grep -c . || true)"
    [[ "${n:-0}" -eq 0 ]]
  }
  netpol_self_heals() {
    kubectl -n "$TENANT_NS" get netpol default-deny-ingress >/dev/null 2>&1 || return 1
    kubectl -n "$TENANT_NS" delete netpol default-deny-ingress >/dev/null 2>&1 || return 1
    wait_for 60 kubectl -n "$TENANT_NS" get netpol default-deny-ingress
  }
  clone_propagates() {
    local stamp="verified-$RANDOM"
    local src_ns
    src_ns="$(kubectl get clusterpolicy "$POLICY" \
              -o jsonpath='{.spec.rules[2].generate.clone.namespace}' 2>/dev/null)"
    [[ -n "$src_ns" ]] || return 1
    kubectl -n "$src_ns" patch configmap "$SRC_CM" --type=merge \
      -p "{\"data\":{\"sync-probe\":\"${stamp}\"}}" >/dev/null 2>&1 || return 1
    wait_for 60 bash -c \
      "[[ \"\$(kubectl -n ${TENANT_NS} get cm ${SRC_CM} -o jsonpath='{.data.sync-probe}' 2>/dev/null)\" == '${stamp}' ]]"
  }

  head1 "GRADING — objective A: the new tenant namespace (${TENANT_NS})"
  check "NetworkPolicy/default-deny-ingress exists" \
        kubectl -n "$TENANT_NS" get netpol default-deny-ingress
  check "ResourceQuota/tenant-quota exists in the RIGHT namespace" \
        kubectl -n "$TENANT_NS" get resourcequota tenant-quota
  check "ResourceQuota carries the baseline values (requests.cpu=4)" quota_is_correct
  check "ConfigMap/${SRC_CM} was cloned with its data" clone_has_data
  check "TenantGuard/${GUARD_NAME} exists (background-controller RBAC)" \
        kubectl -n "$TENANT_NS" get "${CRD_PLURAL}.${CRD_GROUP}" "$GUARD_NAME"

  head1 "GRADING — objective B: the pre-existing namespace (${LEGACY_NS})"
  check "NetworkPolicy generated for a trigger that pre-dates the policy" \
        kubectl -n "$LEGACY_NS" get netpol default-deny-ingress
  check "ResourceQuota generated" kubectl -n "$LEGACY_NS" get resourcequota tenant-quota
  check "ConfigMap cloned"        kubectl -n "$LEGACY_NS" get configmap "$SRC_CM"
  check "TenantGuard generated"   kubectl -n "$LEGACY_NS" get "${CRD_PLURAL}.${CRD_GROUP}" "$GUARD_NAME"

  head1 "GRADING — objective C: self-healing (destructive probe)"
  info "deleting ${TENANT_NS}/networkpolicy/default-deny-ingress and waiting for Kyverno"
  check "downstream restored automatically (synchronize: true)" netpol_self_heals

  head1 "GRADING — objective D: clone synchronisation"
  check "a change in the clone source reaches the tenant copy" clone_propagates

  head1 "GRADING — objective E: clean work queue"
  check "no UpdateRequest left in state Failed" no_failed_urs

  hr
  if (( fail == 0 )); then
    printf '%s RESULT: %d/%d — topic 5.5 objectives met.%s\n' "$C_G" "$pass" "$((pass+fail))" "$C_RST"
    say "Now explain out loud, without looking: why does a generate rule need"
    say "background mode, and why is its RBAC different from the admission path?"
  else
    printf '%s RESULT: %d passed, %d failed — keep going ('"$0"' hints 2).%s\n' \
      "$C_Y" "$pass" "$fail" "$C_RST"
    return 1
  fi
}

cmd_clean() {
  need_bin kubectl
  guard_lab
  head1 "CLEANING UP"
  kubectl delete clusterpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole "$EXTRA_ROLE" --ignore-not-found >/dev/null 2>&1 || true
  # a mis-targeted ResourceQuota can land in 'default'; remove only ours
  kubectl -n default delete resourcequota tenant-quota --ignore-not-found >/dev/null 2>&1 || true
  for ns in "$GREEN_NS" "$TENANT_NS" "$LEGACY_NS" "$SRC_NS" "$SRC_NS_MOVED"; do
    kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  kubectl delete crd "$CRD_NAME" --ignore-not-found >/dev/null 2>&1 || true
  if [[ -n "${KYVERNO_NS:-}" ]] || detect_kyverno 2>/dev/null; then
    kubectl -n "$KYVERNO_NS" delete updaterequests.kyverno.io --all >/dev/null 2>&1 || true
  fi
  ok "lab objects removed (Kyverno itself was left installed)"
}

usage() {
  cat <<USAGE
KCA 5.5 — Generation Rules · break & fix lab

  $0 install-kyverno   install Kyverno via helm (optional, lab clusters only)
  $0 setup             build the baseline and prove the green state
  $0 break             inject the four faults and print the briefing
  $0 status            triage dashboard
  $0 hints [1|2|3]     progressive hints
  $0 verify            grade the fix
  $0 clean             remove everything this lab created

Environment:
  KCA_LAB_CONFIRM=yes      bypass the disposable-cluster guard
  LAB_CONTEXT_REGEX=...    override the allowed kube-context pattern
  KYVERNO_CHART_VERSION=.. pin the helm chart on install-kyverno
USAGE
}

main() {
  case "${1:-}" in
    install-kyverno) cmd_install_kyverno ;;
    setup)           cmd_setup ;;
    break)           cmd_break ;;
    status)          cmd_status ;;
    hints)           cmd_hints "${2:-1}" ;;
    verify)          cmd_verify ;;
    clean)           cmd_clean ;;
    ""|-h|--help)    usage ;;
    *)               usage; exit 1 ;;
  esac
}
main "$@"

# =============================================================================
#  SOLUTION — read only after you have tried
# =============================================================================
#
#  MENTAL MODEL FIRST
#  ------------------
#  A `generate` rule is not an admission-time mutation. The admission webhook
#  only records the intent: it creates an ${C}UpdateRequest${C} (CR
#  updaterequests.kyverno.io, namespaced in the Kyverno namespace), and the
#  ${C}background controller${C} reconciles it out-of-band. Three consequences,
#  and every fault in this lab is one of them:
#
#    1. The creating identity is the background controller ServiceAccount, not
#       the user. RBAC of the requesting user is irrelevant; RBAC of that SA is
#       everything. Kyverno ships a deliberately small default grant and expects
#       you to extend it with AGGREGATED ClusterRoles.
#    2. Generate needs background processing (spec.background), so the rule may
#       not use admission-only variables such as {{request.userInfo.*}} — a rule
#       that does is rejected at policy admission time. Related trap, not used
#       here, but it is exam material.
#    3. Two independent switches decide *when* Kyverno acts:
#         generate.synchronize  -> keep the downstream identical to the rule and
#                                  recreate it if someone deletes or edits it
#         spec.generateExisting -> process triggers that ALREADY existed when the
#                                  policy was created/updated
#                                  (pre-1.10 name: generateExistingOnPolicyUpdate;
#                                   1.13+ also allows it per-rule under generate)
#       Neither implies the other.
#
#  DIAGNOSIS PATH (what an SRE actually types)
#  -------------------------------------------
#    kubectl get clusterpolicy tenant-namespace-baseline -o yaml
#    kubectl describe clusterpolicy tenant-namespace-baseline          # events
#    kubectl -n kyverno get updaterequests.kyverno.io
#    kubectl -n kyverno get updaterequests.kyverno.io <ur> -o yaml     # .status.message
#    kubectl -n kyverno logs deploy/kyverno-background-controller | grep -i generate
#    kubectl get netpol,resourcequota,cm -A -l generate.kyverno.io/policy-name=tenant-namespace-baseline
#    kubectl auth can-i create tenantguards --as=system:serviceaccount:kyverno:kyverno-background-controller -n lab-tenant-a
#  PolicyReports are useless here on purpose: generate rules do not report.
#
#  FAULT 1 — the background controller lost the permission to create TenantGuard
#  ----------------------------------------------------------------------------
#  Symptom: UR .status.message contains
#    "... is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\"
#     cannot create resource \"tenantguards\" in API group \"lab.kca.local\""
#  Cause: the ClusterRole kyverno:background-controller:kca-lab lost the label
#  that aggregates it into the controller's role.
#  Fix:
#    kubectl label clusterrole kyverno:background-controller:kca-lab \
#      rbac.kyverno.io/aggregate-to-background-controller=true
#    # verify (kube-controller-manager recomputes the aggregate in ~1-5s)
#    kubectl auth can-i create tenantguards \
#      --as=system:serviceaccount:kyverno:kyverno-background-controller -n lab-tenant-a
#    yes
#  Note: this is exactly what happens in production the first time you generate a
#  cert-manager Certificate, an Istio PeerAuthentication or any CRD — Kyverno's
#  default grant covers only common core/networking/rbac kinds.
#
#  FAULT 2 — the clone source moved
#  --------------------------------
#  Symptom: UR message "... source resource platform-system/tenant-baseline not found ...".
#  Cause: the ConfigMap now lives in platform-baselines; the rule still points at
#  platform-system.
#  Fix (preferred — follow the source):
#    kubectl patch clusterpolicy tenant-namespace-baseline --type=json \
#      -p '[{"op":"replace","path":"/spec/rules/2/generate/clone/namespace","value":"platform-baselines"}]'
#  Alternative (restore the contract): copy the ConfigMap back into
#  platform-system. Either is defensible; do not do both silently.
#  Remember the source must stay readable by the background controller, and with
#  synchronize: true every later edit of the source is pushed to every clone.
#
#  FAULT 3 — wrong downstream namespace expression on the ResourceQuota rule
#  ------------------------------------------------------------------------
#  Symptom: no ResourceQuota in the tenant namespace; the UR fails or the object
#  materialises somewhere unexpected.
#  Cause: generate.namespace was set to "{{request.namespace}}". The trigger is a
#  Namespace, a CLUSTER-SCOPED object, so request.namespace is the empty string.
#  The name of a namespace trigger lives in request.object.metadata.name.
#  Fix:
#    kubectl patch clusterpolicy tenant-namespace-baseline --type=json \
#      -p '[{"op":"replace","path":"/spec/rules/1/generate/namespace","value":"{{request.object.metadata.name}}"}]'
#  Then delete any stray object the broken expression produced, e.g.
#    kubectl -n default delete resourcequota tenant-quota --ignore-not-found
#
#  FAULT 4 — synchronize + generateExisting both off
#  -------------------------------------------------
#  Symptoms: (a) a deleted NetworkPolicy is never restored; (b) lab-legacy, which
#  pre-dates the policy, received nothing.
#  Fix:
#    kubectl patch clusterpolicy tenant-namespace-baseline --type=json -p '[
#      {"op":"replace","path":"/spec/rules/0/generate/synchronize","value":true},
#      {"op":"replace","path":"/spec/generateExisting","value":true}]'
#  synchronize: true also makes the downstream immutable in practice — a tenant
#  editing the NetworkPolicy is reverted by the sync controller. That is the
#  whole point of a security baseline.
#
#  THE TRAP: fixing the cause does not replay an exhausted UpdateRequest
#  --------------------------------------------------------------------
#  An UpdateRequest retries a bounded number of times and then stays Failed. After
#  repairing RBAC you must produce a new trigger event. Any of these works:
#    # re-trigger via the trigger resource (a Namespace UPDATE matches the rule)
#    kubectl label ns lab-tenant-a kca.lab/reconcile=$(date +%s) --overwrite
#    kubectl label ns lab-legacy   kca.lab/reconcile=$(date +%s) --overwrite
#    # or re-trigger via the policy (with generateExisting: true this sweeps
#    # every already-existing matching namespace)
#    kubectl annotate clusterpolicy tenant-namespace-baseline \
#      kca.lab/reconcile=$(date +%s) --overwrite
#  Finally clear the dead queue entries:
#    kubectl -n kyverno delete updaterequests.kyverno.io \
#      $(kubectl -n kyverno get updaterequests.kyverno.io \
#        -o jsonpath='{range .items[?(@.status.state=="Failed")]}{.metadata.name} {end}')
#
#  ONE-SHOT REPAIR (equivalent to editing the policy by hand)
#  ----------------------------------------------------------
#    kubectl label clusterrole kyverno:background-controller:kca-lab \
#      rbac.kyverno.io/aggregate-to-background-controller=true
#    kubectl patch clusterpolicy tenant-namespace-baseline --type=json -p '[
#      {"op":"replace","path":"/spec/generateExisting","value":true},
#      {"op":"replace","path":"/spec/rules/0/generate/synchronize","value":true},
#      {"op":"replace","path":"/spec/rules/1/generate/namespace","value":"{{request.object.metadata.name}}"},
#      {"op":"replace","path":"/spec/rules/2/generate/clone/namespace","value":"platform-baselines"}]'
#    kubectl label ns lab-tenant-a kca.lab/reconcile=$(date +%s) --overwrite
#    kubectl label ns lab-legacy   kca.lab/reconcile=$(date +%s) --overwrite
#    ./kca-5.5-generation-rules-breakfix.sh verify
#
#  EXPECTED FINAL STATE
#  --------------------
#    $ kubectl -n lab-legacy get netpol,resourcequota,cm,tenantguards.lab.kca.local
#    NAME                                                  POD-SELECTOR   AGE
#    networkpolicy.networking.k8s.io/default-deny-ingress   <none>        40s
#    NAME                      AGE   REQUEST                                          LIMIT
#    resourcequota/tenant-quota 40s  pods: 0/20, requests.cpu: 0/4, requests.memory: 0/8Gi   limits.cpu: 0/8, limits.memory: 0/16Gi
#    NAME                        DATA   AGE
#    configmap/kube-root-ca.crt     1   3m
#    configmap/tenant-baseline      3   40s
#    NAME                                        AGE
#    tenantguard.lab.kca.local/baseline-guard    40s
#
#  WHAT TO CARRY INTO THE EXAM
#  ---------------------------
#   * data vs clone vs cloneList; clone follows the source, data is the spec.
#   * synchronize != generateExisting != orphanDownstreamOnPolicyDelete
#     (the last one decides whether downstreams survive the policy's deletion).
#   * Generated objects are labelled generate.kyverno.io/policy-name,
#     /rule-name and /trigger-* — that is how the sync controller finds them and
#     how you audit them.
#   * The generate path runs as the background controller SA and is invisible to
#     PolicyReports; UpdateRequests are its status surface.
#   * Deleting the TRIGGER deletes the synchronised downstreams; deleting the
#     downstream only makes Kyverno rebuild it.
#
#  Sources: https://kyverno.io/docs/writing-policies/generate/ ,
#           https://kyverno.io/docs/installation/customization/ ,
#           https://kyverno.io/docs/troubleshooting/ ,
#           https://kubernetes.io/docs/reference/access-authn-authz/rbac/ ,
#           https://github.com/cncf/curriculum
# =============================================================================