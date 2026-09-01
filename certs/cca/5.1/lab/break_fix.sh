#!/usr/bin/env bash
#
# ==============================================================================
#  CCA — Cilium Certified Associate
#  Domain 5: Cilium Security  ·  Topic 5.1 "Securing Workloads with Cilium" (20%)
#  BREAK & FIX LAB — identity-based policy, DNS egress, and L7 HTTP enforcement
# ==============================================================================
#
#  WHAT THIS SCRIPT DOES
#    Deploys a self-contained demo workload into a dedicated namespace and then
#    seeds THREE deliberate faults into two CiliumNetworkPolicy objects. The
#    faults are layered, so the failure symptom CHANGES as you repair each one:
#    a DNS resolution failure, then an L3/L4 identity drop, then an L7 HTTP 403.
#    You must restore full service without weakening the security posture.
#
#  SAFETY / BLAST RADIUS
#    * Everything lives in a single namespace ($NS) and is removed by `clean`.
#    * NOTHING outside that namespace is modified. The script never touches the
#      Cilium ConfigMap, never changes cluster-wide policy enforcement mode,
#      never edits kube-system, and never installs or upgrades Cilium.
#    * Intended for a DISPOSABLE lab VM (kind / minikube / k3s / single-node
#      kubeadm) running Cilium as the CNI. It refuses to run against a context
#      whose name looks like production, and asks for typed confirmation.
#
#  REQUIREMENTS
#    kubectl, a reachable cluster, Cilium >= 1.14 as CNI, Hubble enabled
#    (cilium hubble enable  --or--  helm ... --set hubble.enabled=true \
#     --set hubble.relay.enabled=true).
#
#  OFFICIAL SOURCES (read these, not blog posts)
#    CCA curriculum ....... https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
#    Policy reference ..... https://docs.cilium.io/en/stable/security/policy/
#    Identity concept ..... https://docs.cilium.io/en/stable/gettingstarted/terminology/#labels
#    L7 HTTP policy ....... https://docs.cilium.io/en/stable/security/http/
#    DNS-based policy ..... https://docs.cilium.io/en/stable/security/dns/
#    Policy troubleshoot .. https://docs.cilium.io/en/stable/operations/troubleshooting/#policy-troubleshooting
#    Hubble observability . https://docs.cilium.io/en/stable/observability/hubble/
#    cilium-dbg CLI ....... https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
#
#  USAGE
#    ./cca-5.1-break-fix.sh            # deploy + break + print the briefing
#    ./cca-5.1-break-fix.sh verify     # grade your fix (exit 0 == solved)
#    ./cca-5.1-break-fix.sh status     # current policy + endpoint view
#    ./cca-5.1-break-fix.sh hint 1|2|3 # progressive diagnostic hints (no answers)
#    ./cca-5.1-break-fix.sh reset      # re-seed the faults from scratch
#    ./cca-5.1-break-fix.sh clean      # delete the whole lab namespace
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until `verify` has beaten you at least twice.
# ==============================================================================

set -euo pipefail

NS="${NS:-cca-lab-51}"
CILIUM_NS="${CILIUM_NS:-kube-system}"
CURL_TIMEOUT="${CURL_TIMEOUT:-8}"
AUTO_CONFIRM="${LAB_AUTO_CONFIRM:-0}"

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; C=""; BOLD=""; N=""
fi

log()  { printf '%s[ lab ]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[  ok ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '%s[fail ]%s %s\n' "$R" "$N" "$*"; }
die()  { printf '%s[fatal]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$C" "--------------------------------------------------------------------------" "$N"; }

# ------------------------------------------------------------------------------
# Guard rails
# ------------------------------------------------------------------------------
require_tools() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl version -o json >/dev/null 2>&1 || die "No reachable cluster (check your kubeconfig / context)."
}

guard_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  log "kubectl context: ${BOLD}${ctx}${N}"

  shopt -s nocasematch
  if [[ "$ctx" =~ (prod|production|live|corp|staging) ]]; then
    die "Context '${ctx}' looks like a real environment. This lab only runs on a disposable VM cluster."
  fi
  shopt -u nocasematch

  if [[ "$AUTO_CONFIRM" != "1" ]]; then
    printf '%s' "${Y}Type BREAK to seed the faults into context '${ctx}' (namespace ${NS}): ${N}"
    local answer=""
    read -r answer || true
    [[ "$answer" == "BREAK" ]] || die "Aborted by the operator. Nothing was changed."
  fi
}

preflight_cilium() {
  kubectl -n "$CILIUM_NS" get daemonset cilium >/dev/null 2>&1 \
    || die "No 'cilium' DaemonSet in namespace ${CILIUM_NS}. This lab requires Cilium as the CNI."

  CILIUM_POD="$(kubectl -n "$CILIUM_NS" get pods -l k8s-app=cilium \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${CILIUM_POD:-}" ]] || die "Could not find a running Cilium agent pod."

  # Cilium >= 1.15 ships the in-agent CLI as 'cilium-dbg'; older releases as 'cilium'.
  if kubectl -n "$CILIUM_NS" exec "$CILIUM_POD" -c cilium-agent -- which cilium-dbg >/dev/null 2>&1; then
    CILIUM_BIN="cilium-dbg"
  else
    CILIUM_BIN="cilium"
  fi
  ok "Cilium agent: ${CILIUM_POD} (in-pod CLI: ${CILIUM_BIN})"

  if kubectl -n "$CILIUM_NS" exec "$CILIUM_POD" -c cilium-agent -- hubble observe --last 1 >/dev/null 2>&1; then
    ok "Hubble is enabled on the agent — flow-level debugging available."
  else
    warn "Hubble does not answer on the agent. You can still solve the lab with"
    warn "  '${CILIUM_BIN} monitor --type drop', but enabling Hubble is strongly advised:"
    warn "  cilium hubble enable   (Cilium CLI)"
  fi

  # Informational only: the student needs these labels for the DNS egress rule.
  DNS_NS="$(kubectl get svc -A -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo kube-system)"
  log "Cluster DNS service found in namespace '${DNS_NS}' with label k8s-app=kube-dns"
}

# ------------------------------------------------------------------------------
# Workload: a minimal HTTP application with two client identities
# ------------------------------------------------------------------------------
deploy_app() {
  log "Creating namespace ${NS} and deploying the demo workload..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -f - >/dev/null <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deathstar
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: deathstar
spec:
  replicas: 2
  selector:
    matchLabels:
      org: empire
      class: deathstar
  template:
    metadata:
      labels:
        org: empire
        class: deathstar
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - name: deathstar
        image: docker.io/cilium/starwars
        ports:
        - containerPort: 80
          name: http
        resources:
          requests: {cpu: "20m", memory: "32Mi"}
          limits:   {cpu: "200m", memory: "128Mi"}
---
apiVersion: v1
kind: Service
metadata:
  name: deathstar
  namespace: ${NS}
spec:
  type: ClusterIP
  selector:
    org: empire
    class: deathstar
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
---
apiVersion: v1
kind: Pod
metadata:
  name: tiefighter
  namespace: ${NS}
  labels:
    org: empire
    class: tiefighter
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: spaceship
    image: docker.io/tgraf/netperf
    resources:
      requests: {cpu: "10m", memory: "32Mi"}
      limits:   {cpu: "100m", memory: "128Mi"}
---
apiVersion: v1
kind: Pod
metadata:
  name: xwing
  namespace: ${NS}
  labels:
    org: alliance
    class: xwing
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: spaceship
    image: docker.io/tgraf/netperf
    resources:
      requests: {cpu: "10m", memory: "32Mi"}
      limits:   {cpu: "100m", memory: "128Mi"}
EOF

  log "Waiting for pods to become Ready (image pull can take a minute)..."
  kubectl -n "$NS" rollout status deployment/deathstar --timeout=180s >/dev/null \
    || die "deathstar did not become Ready. Check 'kubectl -n ${NS} describe deploy/deathstar'."
  kubectl -n "$NS" wait --for=condition=Ready pod/tiefighter --timeout=180s >/dev/null \
    || die "tiefighter did not become Ready."
  kubectl -n "$NS" wait --for=condition=Ready pod/xwing --timeout=180s >/dev/null \
    || die "xwing did not become Ready."
  ok "Workload is up: deathstar (2 replicas), tiefighter (org=empire), xwing (org=alliance)"
}

baseline_check() {
  log "Baseline connectivity BEFORE any policy is applied (expect: Ship landed)."
  local out
  out="$(land_from tiefighter || true)"
  printf '        tiefighter -> deathstar : %s\n' "${out:-<no output>}"
  if [[ "$out" != *"Ship landed"* ]]; then
    warn "Baseline did not return 'Ship landed'. Fix the environment before continuing:"
    warn "  kubectl -n ${NS} get pods -o wide ; kubectl -n ${NS} get endpoints deathstar"
    die "Refusing to seed faults on top of a broken baseline."
  fi
  ok "Baseline healthy. Now breaking it on purpose."
}

# ------------------------------------------------------------------------------
# The break: two policies carrying three seeded faults
# ------------------------------------------------------------------------------
seed_faults() {
  log "Applying the (deliberately flawed) CiliumNetworkPolicy set..."

  kubectl apply -f - >/dev/null <<EOF
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: tiefighter-egress
  namespace: ${NS}
  labels:
    cca-lab: "5.1"
spec:
  description: "Egress: tiefighter is only allowed to reach the deathstar HTTP port"
  endpointSelector:
    matchLabels:
      org: empire
      class: tiefighter
  egress:
  - toEndpoints:
    - matchLabels:
        org: empire
        class: deathstar
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deathstar-l7-landing
  namespace: ${NS}
  labels:
    cca-lab: "5.1"
spec:
  description: "Ingress: only empire ships may request a landing; nothing else on the API"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
  - fromEndpoints:
    - matchLabels:
        org: alliance
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/requestlanding"
EOF

  sleep 5
  ok "Policies applied. The workload is now broken in three independent places."
}

# ------------------------------------------------------------------------------
# Probes
# ------------------------------------------------------------------------------
land_from() {   # POST /v1/request-landing — the legitimate business call
  local pod="$1"
  kubectl -n "$NS" exec "$pod" -c spaceship -- \
    curl -sS --max-time "$CURL_TIMEOUT" \
    -XPOST "deathstar.${NS}.svc.cluster.local/v1/request-landing" 2>&1 || true
}

exhaust_from() { # PUT /v1/exhaust-port — the call that must NEVER be allowed
  local pod="$1"
  kubectl -n "$NS" exec "$pod" -c spaceship -- \
    curl -sS --max-time "$CURL_TIMEOUT" \
    -XPUT "deathstar.${NS}.svc.cluster.local/v1/exhaust-port" 2>&1 || true
}

classify() {
  local out="$1"
  if   [[ "$out" == *"Ship landed"*        ]]; then echo "ALLOWED"
  elif [[ "$out" == *"Access denied"*      ]]; then echo "L7_DENIED"
  elif [[ "$out" == *"Could not resolve"* || "$out" == *"Resolving timed out"* || "$out" == *"(6)"* ]]; then echo "DNS_FAIL"
  elif [[ "$out" == *"timed out"* || "$out" == *"(28)"* || "$out" == *"(7)"* || -z "$out" ]]; then echo "L34_DROP"
  else echo "OTHER"
  fi
}

# ------------------------------------------------------------------------------
# Briefing
# ------------------------------------------------------------------------------
briefing() {
  rule
  printf '%sCCA 5.1 — BREAK & FIX: "The landing requests never arrive"%s\n' "$BOLD" "$N"
  rule
  cat <<EOF

SCENARIO
  Namespace ${NS} runs an HTTP service (deathstar, ClusterIP :80) that exposes
  two API endpoints:

      POST /v1/request-landing   -> legitimate, must work for empire ships
      PUT  /v1/exhaust-port      -> catastrophic, must NEVER be reachable

  Two clients exist, distinguished ONLY by their Kubernetes labels — which is
  exactly what Cilium turns into a security identity:

      pod/tiefighter   org=empire,   class=tiefighter   (authorized client)
      pod/xwing        org=alliance, class=xwing        (must stay locked out)

  A colleague pushed two CiliumNetworkPolicy objects to "harden" the namespace.
  The next deploy broke the application. The policies are:

      cnp/tiefighter-egress      (egress enforcement on tiefighter)
      cnp/deathstar-l7-landing   (ingress + L7 HTTP enforcement on deathstar)

SYMPTOM YOU WILL SEE RIGHT NOW
  From tiefighter, the landing call fails at name resolution:

      \$ kubectl -n ${NS} exec tiefighter -- \\
          curl -sS -XPOST deathstar.${NS}.svc.cluster.local/v1/request-landing
      curl: (6) Could not resolve host: deathstar.${NS}.svc.cluster.local

  The application code did not change and CoreDNS is perfectly healthy — verify
  that yourself before you touch anything. This is the FIRST of three layered
  faults; as you repair each one the symptom will MUTATE:

      stage 1  ->  DNS resolution failure          (curl: (6))
      stage 2  ->  connection hangs / times out    (curl: (28)) : L3/L4 drop
      stage 3  ->  HTTP 403 "Access denied"                     : L7 drop
      stage 4  ->  "Ship landed"                                : solved

YOUR OBJECTIVE — all four conditions must hold simultaneously
  1. tiefighter CAN execute  POST /v1/request-landing  -> "Ship landed".
  2. tiefighter CANNOT execute PUT /v1/exhaust-port    -> "Access denied".
  3. xwing CANNOT land, and cannot reach the API at all.
  4. Both CiliumNetworkPolicy objects still exist and still enforce.
     Deleting the policies, replacing a selector with an empty '{}', adding
     'fromEntities: [all]', or dropping the L7 'rules:' block is CHEATING and
     the grader will fail you for it. Least privilege must survive the repair.

RULES OF ENGAGEMENT
  * Do not modify pod labels — the labels ARE the identities and they are correct.
  * Do not touch kube-system, the Cilium ConfigMap, or CoreDNS.
  * Work only inside namespace ${NS}.

WHERE TO LOOK (this is the actual exam skill)
  Live drop feed, both directions:
      kubectl -n ${CILIUM_NS} exec ${CILIUM_POD} -c cilium-agent -- \\
        hubble observe --namespace ${NS} --verdict DROPPED --follow
  Layer 7 verdicts specifically (the HTTP proxy writes these):
      kubectl -n ${CILIUM_NS} exec ${CILIUM_POD} -c cilium-agent -- \\
        hubble observe --namespace ${NS} --protocol http --last 20
  Which endpoints are actually enforcing, and in which direction:
      kubectl -n ${CILIUM_NS} exec ${CILIUM_POD} -c cilium-agent -- ${CILIUM_BIN} endpoint list
  The compiled policy for one endpoint (identity-level allow list):
      kubectl -n ${CILIUM_NS} exec ${CILIUM_POD} -c cilium-agent -- ${CILIUM_BIN} policy get
  The identity behind a label set:
      kubectl -n ${NS} get cep       # CiliumEndpoint: identity + policy state
      kubectl get ciliumidentities -l k8s:org=empire

GRADE YOURSELF
      $0 verify         # exits 0 only when all four conditions pass
      $0 hint 1|2|3     # progressive hints, no spoilers
      $0 reset          # re-seed the faults
      $0 clean          # remove namespace ${NS} entirely

EOF
  rule
}

# ------------------------------------------------------------------------------
# Hints (direction, never the answer)
# ------------------------------------------------------------------------------
hint() {
  local level="${1:-1}"
  case "$level" in
    1) cat <<'EOF'
HINT 1 — the default-deny trap
  In Cilium, an endpoint is in "default allow" for a direction until SOME policy
  selects it in that direction; from that instant it becomes default-DENY for
  everything not explicitly allowed. Ask yourself: which direction did the new
  egress policy switch on for tiefighter, and what OTHER traffic does a pod
  need before it can talk to a Service by name at all?
  Check: cilium-dbg endpoint list  -> the POLICY (ingress)/(egress) columns.
  Reference: https://docs.cilium.io/en/stable/security/policy/#policy-enforcement-modes
EOF
       ;;
    2) cat <<'EOF'
HINT 2 — identity, not IP
  Once the client can resolve names, run the drop feed while you curl:
      hubble observe --namespace <ns> --verdict DROPPED --follow
  Read the SOURCE and DESTINATION identity labels Hubble prints on the dropped
  flow, then read the ingress rule's fromEndpoints selector next to them,
  label by label. Cilium matched exactly what was written; the question is
  whether what was written matches the client that must be allowed.
  Reference: https://docs.cilium.io/en/stable/security/policy/#endpoints-based
EOF
       ;;
    3) cat <<'EOF'
HINT 3 — the proxy answers, so it is not a drop
  A 403 "Access denied" body is NOT a packet drop: the connection completed at
  L3/L4 and Cilium's Envoy-based HTTP proxy rejected the request against the L7
  allow list. Compare, character by character, the method+path the application
  actually receives with the method+path in the policy's http rule:
      hubble observe --namespace <ns> --protocol http --last 20
  An L7 rule is an allow list: anything not listed is denied by design — which
  is precisely why /v1/exhaust-port must remain unlisted.
  Reference: https://docs.cilium.io/en/stable/security/http/
EOF
       ;;
    *) die "hint level must be 1, 2 or 3" ;;
  esac
}

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------
status() {
  rule; log "Pods"; kubectl -n "$NS" get pods -o wide --show-labels 2>/dev/null || true
  rule; log "CiliumNetworkPolicies"; kubectl -n "$NS" get cnp 2>/dev/null || true
  rule; log "CiliumEndpoints (identity + enforcement state)"
  kubectl -n "$NS" get cep 2>/dev/null || true
  rule; log "Live probes"
  printf '        tiefighter POST /v1/request-landing : %s\n' "$(classify "$(land_from tiefighter)")"
  printf '        tiefighter PUT  /v1/exhaust-port    : %s\n' "$(classify "$(exhaust_from tiefighter)")"
  printf '        xwing      POST /v1/request-landing : %s\n' "$(classify "$(land_from xwing)")"
  rule
}

# ------------------------------------------------------------------------------
# Grader
# ------------------------------------------------------------------------------
verify() {
  local failures=0

  rule
  printf '%sGRADING CCA 5.1 break & fix%s\n' "$BOLD" "$N"
  rule

  # --- Anti-cheat: both policies must still exist ---------------------------
  local have_egress have_ingress
  have_egress="$(kubectl -n "$NS" get cnp tiefighter-egress -o name 2>/dev/null || true)"
  have_ingress="$(kubectl -n "$NS" get cnp deathstar-l7-landing -o name 2>/dev/null || true)"
  if [[ -z "$have_egress" || -z "$have_ingress" ]]; then
    bad "Both CiliumNetworkPolicy objects must still exist (tiefighter-egress, deathstar-l7-landing)."
    bad "Removing a policy is not a fix — it removes the security control."
    failures=$((failures+1))
  else
    ok "Both policies are still present and enforcing."
  fi

  # --- Anti-cheat: the L7 allow list must still be an allow list ------------
  local l7
  l7="$(kubectl -n "$NS" get cnp deathstar-l7-landing -o jsonpath='{.spec.ingress[*].toPorts[*].rules.http[*].path}' 2>/dev/null || true)"
  if [[ -z "$l7" ]]; then
    bad "The ingress policy no longer carries an L7 http rule. Layer 7 enforcement was lost."
    failures=$((failures+1))
  else
    ok "L7 HTTP rules still present (paths: ${l7})."
  fi

  # --- Condition 1: the legitimate call must succeed ------------------------
  local out v
  out="$(land_from tiefighter)"; v="$(classify "$out")"
  case "$v" in
    ALLOWED)   ok "1/4 tiefighter POST /v1/request-landing -> Ship landed." ;;
    DNS_FAIL)  bad "1/4 STILL AT STAGE 1: DNS resolution fails from tiefighter."
               printf '        %s\n' "$out"; failures=$((failures+1)) ;;
    L34_DROP)  bad "1/4 STAGE 2: packets are dropped before reaching the app (L3/L4 identity mismatch)."
               printf '        %s\n' "$out"; failures=$((failures+1)) ;;
    L7_DENIED) bad "1/4 STAGE 3: connection established, HTTP proxy returned Access denied (L7 rule mismatch)."
               failures=$((failures+1)) ;;
    *)         bad "1/4 Unexpected result: ${out}"; failures=$((failures+1)) ;;
  esac

  # --- Condition 2: the dangerous call must remain denied -------------------
  out="$(exhaust_from tiefighter)"; v="$(classify "$out")"
  if [[ "$v" == "L7_DENIED" || "$v" == "L34_DROP" ]]; then
    ok "2/4 tiefighter PUT /v1/exhaust-port is denied (${v})."
  else
    bad "2/4 SECURITY REGRESSION: /v1/exhaust-port is reachable. Your L7 rule is too permissive."
    printf '        %s\n' "$out"; failures=$((failures+1))
  fi

  # --- Condition 3: the untrusted identity must stay out --------------------
  out="$(land_from xwing)"; v="$(classify "$out")"
  if [[ "$v" == "ALLOWED" ]]; then
    bad "3/4 SECURITY REGRESSION: xwing (org=alliance) can land. The ingress selector is wrong."
    failures=$((failures+1))
  else
    ok "3/4 xwing is denied (${v}) — the untrusted identity stays out."
  fi

  # --- Condition 4: egress remains scoped, not wide open --------------------
  local egress_ents
  egress_ents="$(kubectl -n "$NS" get cnp tiefighter-egress -o jsonpath='{.spec.egress[*].toEntities[*]}' 2>/dev/null || true)"
  if [[ "$egress_ents" == *"all"* || "$egress_ents" == *"world"* ]]; then
    bad "4/4 The egress policy now allows entity '${egress_ents}'. That is not least privilege."
    failures=$((failures+1))
  else
    ok "4/4 Egress from tiefighter is still scoped to named endpoints."
  fi

  rule
  if [[ $failures -eq 0 ]]; then
    printf '%sPASS%s — the workload is healthy AND still least-privileged.\n' "$G$BOLD" "$N"
    printf 'Now explain out loud, as if to an auditor, why each of the three faults produced\n'
    printf 'a DIFFERENT symptom. If you can do that, you own CCA topic 5.1.\n'
    rule
    return 0
  fi
  printf '%s%d check(s) failing.%s Re-read the Hubble verdicts and try again: %s hint 1|2|3\n' \
         "$R$BOLD" "$failures" "$N" "$0"
  rule
  return 1
}

cleanup() {
  log "Deleting namespace ${NS} (policies, pods and service go with it)..."
  kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
  ok "Cleanup requested. Nothing outside ${NS} was ever modified."
}

usage() {
  sed -n '1,40p' "$0"
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------
main() {
  local cmd="${1:-break}"
  case "$cmd" in
    break|"")
      require_tools; guard_context; preflight_cilium
      deploy_app; baseline_check; seed_faults; briefing ;;
    reset)
      require_tools; preflight_cilium
      kubectl -n "$NS" delete cnp --all >/dev/null 2>&1 || true
      seed_faults; briefing ;;
    verify)
      require_tools; preflight_cilium >/dev/null; verify ;;
    status)
      require_tools; preflight_cilium >/dev/null; status ;;
    hint)
      hint "${2:-1}" ;;
    clean)
      require_tools; cleanup ;;
    -h|--help|help)
      usage ;;
    *)
      die "Unknown command '${cmd}'. Try: break | verify | status | hint N | reset | clean" ;;
  esac
}

main "$@"

# ==============================================================================
# ============================  SOLUTION (SPOILERS)  ===========================
# ==============================================================================
#
# THE THREE SEEDED FAULTS
#
#   FAULT 1 — cnp/tiefighter-egress has no rule for cluster DNS.
#             The moment ANY egress rule selects tiefighter, that endpoint flips
#             from "default allow" to "default deny" for egress. The policy only
#             allowed TCP/80 to the deathstar identity, so the pod's UDP/53
#             query to CoreDNS was dropped -> curl: (6) Could not resolve host.
#             This is the single most common self-inflicted outage with egress
#             policies. Source: https://docs.cilium.io/en/stable/security/dns/
#
#   FAULT 2 — cnp/deathstar-l7-landing allowed ingress fromEndpoints
#             'org: alliance' instead of 'org: empire'. Cilium matched exactly
#             what was written: the tiefighter identity was not in the allow
#             list, so its packets were dropped with "Policy denied" BEFORE the
#             HTTP proxy ever saw them -> curl: (28) timeout.
#             Source: https://docs.cilium.io/en/stable/security/policy/#endpoints-based
#
#   FAULT 3 — the L7 http rule listed path "/v1/requestlanding" while the
#             application endpoint is "/v1/request-landing" (hyphen). The
#             connection completes, Envoy compares the request against the
#             allow list, finds no match, and returns HTTP 403 "Access denied".
#             Source: https://docs.cilium.io/en/stable/security/http/
#
# ------------------------------------------------------------------------------
# STEP 0 — prove the platform is innocent before blaming it
# ------------------------------------------------------------------------------
#   kubectl -n kube-system get pods -l k8s-app=kube-dns          # CoreDNS healthy
#   kubectl -n cca-lab-51 get endpoints deathstar                # backends present
#   kubectl -n cca-lab-51 get pods --show-labels                 # labels intact
#   kubectl -n cca-lab-51 get cep                                # identities assigned
#
# ------------------------------------------------------------------------------
# STEP 1 — see who is enforcing what
# ------------------------------------------------------------------------------
#   CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium \
#                  -o jsonpath='{.items[0].metadata.name}')
#   kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg endpoint list
#
#   Expected (abridged) — note the enforcement columns:
#     ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS
#     412        Disabled           Enabled           23451      k8s:class=tiefighter,k8s:org=empire
#     980        Enabled            Disabled          17904      k8s:class=deathstar,k8s:org=empire
#     1123       Disabled           Disabled          51002      k8s:class=xwing,k8s:org=alliance
#
#   "Enabled" in a column means default-deny in that direction. tiefighter is
#   egress-enforced -> everything it needs (including DNS) must be listed.
#
# ------------------------------------------------------------------------------
# STEP 2 — watch the drops while reproducing
# ------------------------------------------------------------------------------
#   # terminal A
#   kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- \
#     hubble observe --namespace cca-lab-51 --verdict DROPPED --follow
#
#   # terminal B
#   kubectl -n cca-lab-51 exec tiefighter -- \
#     curl -sS -XPOST deathstar.cca-lab-51.svc.cluster.local/v1/request-landing
#
#   Terminal A prints, for fault 1:
#     cca-lab-51/tiefighter:38210 -> kube-system/coredns-xxxx:53
#       Policy denied DROPPED (UDP)
#
# ------------------------------------------------------------------------------
# STEP 3 — FIX FAULT 1: allow DNS egress (and keep DNS visibility)
# ------------------------------------------------------------------------------
#   cat <<'YAML' | kubectl apply -f -
#   apiVersion: cilium.io/v2
#   kind: CiliumNetworkPolicy
#   metadata:
#     name: tiefighter-egress
#     namespace: cca-lab-51
#     labels:
#       cca-lab: "5.1"
#   spec:
#     description: "Egress: tiefighter may resolve names and reach the deathstar HTTP port"
#     endpointSelector:
#       matchLabels:
#         org: empire
#         class: tiefighter
#     egress:
#     # --- cluster DNS, with the L7 DNS proxy enabled for visibility ---
#     - toEndpoints:
#       - matchLabels:
#           io.kubernetes.pod.namespace: kube-system
#           k8s-app: kube-dns
#       toPorts:
#       - ports:
#         - port: "53"
#           protocol: ANY
#         rules:
#           dns:
#           - matchPattern: "*"
#     # --- the application itself ---
#     - toEndpoints:
#       - matchLabels:
#           org: empire
#           class: deathstar
#       toPorts:
#       - ports:
#         - port: "80"
#           protocol: TCP
#   YAML
#
#   Notes:
#     * 'io.kubernetes.pod.namespace' is how a CNP crosses namespaces; without it
#       the selector only matches endpoints in the policy's own namespace.
#     * protocol ANY covers UDP/53 and TCP/53 (large answers, DoT-less fallback).
#     * The dns matchPattern block turns on Cilium's DNS proxy for this endpoint;
#       it is what makes toFQDNs rules and 'hubble observe --protocol dns' work.
#       If your Cilium build has the DNS proxy disabled, drop the 'rules:' block —
#       plain L3/L4 to port 53 is enough to restore resolution.
#     * Retest: curl now fails differently -> curl: (28) Operation timed out.
#
# ------------------------------------------------------------------------------
# STEP 4 — FIX FAULT 2 and FAULT 3: correct identity, correct path
# ------------------------------------------------------------------------------
#   Hubble now shows the ingress drop with both identities spelled out:
#     cca-lab-51/tiefighter:41022 -> cca-lab-51/deathstar-xxxx:80
#       Policy denied DROPPED (TCP Flags: SYN)
#
#   cat <<'YAML' | kubectl apply -f -
#   apiVersion: cilium.io/v2
#   kind: CiliumNetworkPolicy
#   metadata:
#     name: deathstar-l7-landing
#     namespace: cca-lab-51
#     labels:
#       cca-lab: "5.1"
#   spec:
#     description: "Ingress: only empire ships may POST a landing request; the rest is denied"
#     endpointSelector:
#       matchLabels:
#         org: empire
#         class: deathstar
#     ingress:
#     - fromEndpoints:
#       - matchLabels:
#           org: empire            # FIX 2: empire, not alliance
#       toPorts:
#       - ports:
#         - port: "80"
#           protocol: TCP
#         rules:
#           http:
#           - method: "POST"
#             path: "/v1/request-landing"   # FIX 3: exact application path
#   YAML
#
#   Do NOT add /v1/exhaust-port. An L7 rule is an allow list: everything absent
#   is denied, and that absence is the actual security control being tested.
#
# ------------------------------------------------------------------------------
# STEP 5 — verify the repair AND the posture
# ------------------------------------------------------------------------------
#   kubectl -n cca-lab-51 exec tiefighter -- \
#     curl -sS -XPOST deathstar.cca-lab-51.svc.cluster.local/v1/request-landing
#   # -> Ship landed
#
#   kubectl -n cca-lab-51 exec tiefighter -- \
#     curl -sS -XPUT deathstar.cca-lab-51.svc.cluster.local/v1/exhaust-port
#   # -> Access denied            (L7 allow list working)
#
#   kubectl -n cca-lab-51 exec xwing -- \
#     curl -sS --max-time 5 -XPOST deathstar.cca-lab-51.svc.cluster.local/v1/request-landing
#   # -> curl: (28) Operation timed out   (identity not in the ingress allow list)
#
#   kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- \
#     hubble observe --namespace cca-lab-51 --protocol http --last 10
#   # -> HTTP/1.1 POST .../v1/request-landing  FORWARDED
#   # -> HTTP/1.1 PUT  .../v1/exhaust-port     DROPPED (403)
#
#   ./cca-5.1-break-fix.sh verify     # must exit 0
#
# ------------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM (and into production)
# ------------------------------------------------------------------------------
#   * Direction matters: a policy that selects an endpoint enables default-deny
#     ONLY for the direction(s) it defines. Adding your first egress rule is a
#     breaking change; the DNS rule is not optional boilerplate.
#   * Verdict tells you the layer. "Policy denied DROPPED" on a SYN is L3/L4 —
#     look at identities and selectors. HTTP 403 with a real TCP session is L7 —
#     look at method/path/headers in the http rule.
#   * Identity is derived from labels, so a policy bug and a labelling bug look
#     identical from the app's side; 'cilium-dbg endpoint list' and
#     'kubectl get cep' tell you which one you have.
#   * Never "fix" a policy outage by deleting the policy or widening it to
#     toEntities: [all]. Restore the specific allow, keep the deny.
# ==============================================================================