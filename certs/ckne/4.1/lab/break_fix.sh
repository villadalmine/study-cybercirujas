#!/usr/bin/env bash
# =============================================================================
# CKNE 4.1 - Securing Traffic with Network Policies
# Break & Fix lab: "The zero-trust rollout that broke checkout"
#
# Run this ONLY on a disposable lab cluster (kind, k3s, minikube, kubeadm VM)
# whose CNI enforces NetworkPolicy (Calico, Cilium, kube-router/k3s, Antrea,
# kindnet >= kind v0.24). Everything the script creates lives in one namespace
# (ckne-np-lab), so `./np-break-fix.sh cleanup` removes it all.
#
# Usage:
#   ./np-break-fix.sh break     # deploy the app, check the baseline, inject the faults
#   ./np-break-fix.sh verify    # check your fix
#   ./np-break-fix.sh status    # show pods, services and policies
#   ./np-break-fix.sh cleanup   # delete the lab namespace
#
#   ASSUME_YES=1 skips the kube-context confirmation prompt.
#
# References (official):
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://kubernetes.io/docs/concepts/services-networking/network-policies/
#   https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
#   https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
#   https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
# =============================================================================
set -euo pipefail

NS="ckne-np-lab"
BUSYBOX_IMAGE="busybox:1.36"
BACKEND_IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.53"
PROBE_TIMEOUT=20   # hard ceiling (seconds) for a single connectivity probe

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
info() { printf '%s[INFO]%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*"; }
die()  { fail "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  command -v timeout >/dev/null 2>&1 || die "coreutils 'timeout' not found in PATH."
  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "Cannot reach the API server. Check your kubeconfig / cluster."

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  info "Current kube-context: ${BOLD}${ctx}${RESET}"
  if [[ "${ASSUME_YES:-0}" != "1" ]]; then
    read -r -p "Is this a DISPOSABLE lab cluster? Type 'yes' to continue: " answer
    [[ "$answer" == "yes" ]] || die "Aborted by user."
  fi

  if ! kubectl -n kube-system get pods -l k8s-app=kube-dns -o name 2>/dev/null | grep -q .; then
    warn "No pods labeled k8s-app=kube-dns in kube-system. The DNS part of the fix"
    warn "must then select whatever label your cluster DNS pods actually carry."
  fi
}

# -----------------------------------------------------------------------------
# Probes: exit 0 = connection succeeded, non-zero = blocked / timed out
# -----------------------------------------------------------------------------
probe() {
  local from="$1" url="$2"
  timeout "$PROBE_TIMEOUT" kubectl -n "$NS" exec "deploy/${from}" -- \
    wget -qO- -T 4 "$url" >/dev/null 2>&1
}

pod_ip() {
  kubectl -n "$NS" get pod -l "app=$1" -o jsonpath='{.items[0].status.podIP}'
}

# -----------------------------------------------------------------------------
# Workloads
# -----------------------------------------------------------------------------
deploy_app() {
  info "Creating namespace ${NS} and workloads..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    purpose: ckne-break-fix
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: api
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: netexec
          image: ${BACKEND_IMAGE}
          args: ["netexec", "--http-port=8080"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: ${NS}
spec:
  selector:
    app: backend
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
        tier: web
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: client
          image: ${BUSYBOX_IMAGE}
          command: ["sh", "-c", "trap 'exit 0' TERM; while true; do sleep 3600 & wait; done"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: intruder
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: intruder
  template:
    metadata:
      labels:
        app: intruder
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: httpd
          image: ${BUSYBOX_IMAGE}
          command: ["sh", "-c", "mkdir -p /www && echo intruder > /www/index.html && exec httpd -f -p 8080 -h /www"]
          ports:
            - containerPort: 8080
              protocol: TCP
EOF

  for d in backend frontend intruder; do
    kubectl -n "$NS" rollout status "deploy/${d}" --timeout=180s >/dev/null \
      || die "Deployment ${d} did not become ready (image pull problem?)."
  done
  ok "Workloads are running."
}

baseline_check() {
  info "Baseline check (no policies yet)..."
  probe frontend "http://backend/hostname" \
    || die "Baseline failed: frontend cannot reach backend with no policies. Fix the cluster (DNS/kube-proxy) first."
  probe intruder "http://$(pod_ip backend):8080/hostname" \
    || die "Baseline failed: intruder cannot reach backend with no policies."
  ok "Baseline: frontend -> backend works, intruder -> backend works."
}

# -----------------------------------------------------------------------------
# The break: a "zero-trust" rollout with three independent mistakes
# -----------------------------------------------------------------------------
inject_faults() {
  info "Applying the security team's new NetworkPolicies..."
  kubectl apply -f - <<EOF
# 1) Namespace-wide default deny, both directions. This one is CORRECT and must stay.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# 2) Lets backend accept traffic from the frontend.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-from-frontend
  namespace: ${NS}
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: front
      ports:
        - protocol: TCP
          port: 8080
---
# 3) Lets the frontend open connections to the backend.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-allow-to-backend
  namespace: ${NS}
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - protocol: TCP
          port: 80
---
# 4) Test harness: the intruder pod is fully open in BOTH directions, so any
#    blocked connection to/from it is decided by the OTHER pod's policies.
#    Do not modify or delete this policy.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: lab-harness-intruder-open
  namespace: ${NS}
spec:
  podSelector:
    matchLabels:
      app: intruder
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - {}
  egress:
    - {}
EOF

  info "Giving the CNI a few seconds to program the dataplane..."
  sleep 5

  # Enforcement probe: intruder egress is open, backend ingress only admits
  # app=front. If the intruder still gets through, the CNI ignores policies.
  if probe intruder "http://$(pod_ip backend):8080/hostname"; then
    fail "intruder can still reach backend after default-deny."
    die  "Your CNI does NOT enforce NetworkPolicy (e.g. plain flannel). Use Calico, Cilium, k3s or kind >= v0.24, then rerun. Clean up with: $0 cleanup"
  fi
  ok "NetworkPolicy enforcement confirmed on this cluster."
}

mission() {
  cat <<EOF

${BOLD}=====================================================================
 INCIDENT: checkout is down after the zero-trust rollout
=====================================================================${RESET}
Namespace: ${NS}

The security team rolled out NetworkPolicies to ${NS}. Since then the
frontend cannot talk to the backend.

${BOLD}What you will see${RESET}
  kubectl -n ${NS} exec deploy/frontend -- wget -qO- -T 4 http://backend/hostname
    -> "wget: bad address 'backend'" after a few seconds (DNS times out)
  Fix DNS and it still fails, with "download timed out" this time.
  More than one thing is wrong.

${BOLD}What you must achieve${RESET}
  1. From the frontend, this command returns the backend pod name:
       wget -qO- -T 4 http://backend/hostname      (Service name, port 80)
  2. The intruder pod (app=intruder) still CANNOT reach the backend.
  3. The frontend still CANNOT open connections to arbitrary pods
     (for example the intruder pod IP on 8080) or to the Internet.
     Its only allowed egress is DNS plus the backend.
  4. default-deny-all stays exactly as it is (podSelector {}, Ingress+Egress).
  5. lab-harness-intruder-open is not modified or deleted.
  6. Do not edit the Deployments, the Service or the pod labels. Fix the policies.

${BOLD}Useful commands${RESET}
  kubectl -n ${NS} get netpol
  kubectl -n ${NS} describe netpol <name>
  kubectl -n ${NS} get pods --show-labels -o wide
  kubectl -n ${NS} get svc,endpointslices
  kubectl -n kube-system get pods --show-labels | grep -i dns
  kubectl -n ${NS} exec deploy/frontend -- nslookup backend

Check your work with:  $0 verify
The solution is commented at the bottom of this script. Try without it first.
EOF
}

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
verify() {
  kubectl get ns "$NS" >/dev/null 2>&1 || die "Namespace ${NS} not found. Run: $0 break"
  local rc=0

  # Guard rails: default-deny-all untouched
  local sel types
  sel="$(kubectl -n "$NS" get netpol default-deny-all -o jsonpath='{.spec.podSelector}' 2>/dev/null || echo MISSING)"
  types="$(kubectl -n "$NS" get netpol default-deny-all -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null || echo MISSING)"
  if [[ "$sel" == "{}" && "$types" == *Ingress* && "$types" == *Egress* ]] \
     && [[ -z "$(kubectl -n "$NS" get netpol default-deny-all -o jsonpath='{.spec.ingress}{.spec.egress}')" ]]; then
    ok "default-deny-all intact (all pods, Ingress+Egress, no allow rules)."
  else
    fail "default-deny-all was deleted or modified."; rc=1
  fi

  if kubectl -n "$NS" get netpol lab-harness-intruder-open >/dev/null 2>&1; then
    ok "lab-harness-intruder-open present."
  else
    fail "lab-harness-intruder-open was deleted; the intruder tests would prove nothing."; rc=1
  fi

  local lbl
  lbl="$(kubectl -n "$NS" get deploy frontend -o jsonpath='{.spec.template.metadata.labels.app}')"
  [[ "$lbl" == "frontend" ]] || { fail "frontend pod label changed (app=${lbl}). Fix the policy, not the pod."; rc=1; }

  # Functional checks
  if probe frontend "http://backend/hostname"; then
    ok "frontend -> http://backend/hostname works (DNS + Service + policies)."
  else
    fail "frontend -> http://backend/hostname still fails."; rc=1
  fi

  if probe intruder "http://$(pod_ip backend):8080/hostname"; then
    fail "intruder -> backend:8080 is ALLOWED. Backend ingress is too broad."; rc=1
  else
    ok "intruder -> backend:8080 blocked."
  fi

  if probe frontend "http://$(pod_ip intruder):8080/"; then
    fail "frontend -> intruder:8080 is ALLOWED. Frontend egress is too broad."; rc=1
  else
    ok "frontend -> intruder:8080 blocked (frontend egress is scoped)."
  fi

  if probe frontend "http://1.1.1.1/"; then
    fail "frontend -> Internet (1.1.1.1:80) is ALLOWED. Frontend egress is too broad."; rc=1
  else
    ok "frontend -> Internet blocked (weak check: also passes on an offline VM)."
  fi

  echo
  if [[ $rc -eq 0 ]]; then
    printf '%s%sALL CHECKS PASSED. Checkout is back and zero trust still holds.%s\n' "$GREEN" "$BOLD" "$RESET"
  else
    printf '%s%sNot fixed yet. Keep going.%s\n' "$RED" "$BOLD" "$RESET"
  fi
  return $rc
}

status() {
  kubectl -n "$NS" get pods --show-labels -o wide
  echo
  kubectl -n "$NS" get svc
  echo
  kubectl -n "$NS" get netpol
}

cleanup() {
  info "Deleting namespace ${NS}..."
  kubectl delete ns "$NS" --ignore-not-found --wait=true --timeout=120s
  ok "Lab removed."
}

case "${1:-}" in
  break)
    preflight
    kubectl get ns "$NS" >/dev/null 2>&1 && die "Namespace ${NS} already exists. Run '$0 cleanup' first."
    deploy_app
    baseline_check
    inject_faults
    mission
    ;;
  verify)  verify ;;
  status)  status ;;
  cleanup) cleanup ;;
  *)
    echo "Usage: $0 {break|verify|status|cleanup}"
    exit 2
    ;;
esac

# =============================================================================
# SOLUTION (spoilers: try on your own first)
# =============================================================================
#
# There are THREE independent faults. Each one alone breaks frontend -> backend.
# NetworkPolicies are additive allow-lists: once a pod is selected by any policy
# for a direction, only the union of all allow rules for that direction applies.
# A connection needs an egress allow on the source AND an ingress allow on the
# destination.
#
# -----------------------------------------------------------------------------
# Step 1 - Map what is selected, and by what
# -----------------------------------------------------------------------------
#   kubectl -n ckne-np-lab get pods --show-labels
#   kubectl -n ckne-np-lab describe netpol
#
#   frontend (app=frontend) is selected by: default-deny-all, frontend-allow-to-backend
#   backend  (app=backend)  is selected by: default-deny-all, backend-allow-from-frontend
#
# -----------------------------------------------------------------------------
# Step 2 - Fault #1: DNS egress is denied
# -----------------------------------------------------------------------------
#   kubectl -n ckne-np-lab exec deploy/frontend -- nslookup backend
#   ;; connection timed out; no servers could be reached
#
#   default-deny-all denies ALL egress, including UDP/TCP 53 to CoreDNS in
#   kube-system. Name resolution is just another egress connection. Rules are
#   matched after the Service VIP (kube-dns ClusterIP) is DNAT'ed to a CoreDNS
#   pod IP, so select the CoreDNS pods, not the Service IP. Allow both UDP and
#   TCP: large responses and truncated answers fall back to TCP.
#
#   kubectl apply -f - <<'EOF'
#   apiVersion: networking.k8s.io/v1
#   kind: NetworkPolicy
#   metadata:
#     name: allow-dns-egress
#     namespace: ckne-np-lab
#   spec:
#     podSelector: {}
#     policyTypes:
#       - Egress
#     egress:
#       - to:
#           - namespaceSelector:
#               matchLabels:
#                 kubernetes.io/metadata.name: kube-system
#             podSelector:
#               matchLabels:
#                 k8s-app: kube-dns
#         ports:
#           - protocol: UDP
#             port: 53
#           - protocol: TCP
#             port: 53
#   EOF
#
#   Notes:
#   - namespaceSelector and podSelector sit in the SAME list item (no dash
#     before podSelector), so the peer means "DNS pods IN kube-system" (AND).
#     Two separate items would mean "any pod in kube-system OR any pod labeled
#     k8s-app=kube-dns in THIS namespace" (OR), which is a classic mistake.
#   - kubernetes.io/metadata.name is set automatically on every namespace.
#   - With NodeLocal DNSCache the pods query 169.254.20.10 on the node, so you
#     need an ipBlock rule for that address instead (behaviour is CNI-specific).
#   - podSelector: {} gives DNS to every pod in the namespace, which is the usual
#     pattern. Scoping it to app=frontend also passes this lab.
#
#   After this: nslookup backend works, wget still says "download timed out".
#
# -----------------------------------------------------------------------------
# Step 3 - Fault #2: egress rule uses the SERVICE port instead of the POD port
# -----------------------------------------------------------------------------
#   kubectl -n ckne-np-lab get svc backend
#   PORT(S): 80/TCP  -> targetPort 8080
#
#   frontend-allow-to-backend allows TCP/80 to app=backend pods. The frontend
#   connects to the ClusterIP on port 80, but kube-proxy (or the eBPF service
#   layer) DNATs the packet to <backend-pod-IP>:8080 BEFORE the policy is
#   evaluated. NetworkPolicy peers and ports always refer to POD IPs and POD
#   (container) ports, never to Service VIPs and Service ports.
#
#   kubectl -n ckne-np-lab patch netpol frontend-allow-to-backend --type=json \
#     -p='[{"op":"replace","path":"/spec/egress/0/ports/0/port","value":8080}]'
#
#   Tip: the container port is named "http", so `port: http` also works and
#   keeps working if the container port number changes later.
#
# -----------------------------------------------------------------------------
# Step 4 - Fault #3: ingress rule selects a label nobody has
# -----------------------------------------------------------------------------
#   kubectl -n ckne-np-lab describe netpol backend-allow-from-frontend
#     From: PodSelector: app=front
#   kubectl -n ckne-np-lab get pods -l app=front      -> No resources found
#
#   A selector that matches nothing is not an error: the policy is valid and
#   simply allows nobody. The frontend pods carry app=frontend.
#
#   kubectl -n ckne-np-lab patch netpol backend-allow-from-frontend --type=json \
#     -p='[{"op":"replace","path":"/spec/ingress/0/from/0/podSelector/matchLabels","value":{"app":"frontend"}}]'
#
# -----------------------------------------------------------------------------
# Step 5 - Confirm, and confirm you did not over-open
# -----------------------------------------------------------------------------
#   kubectl -n ckne-np-lab exec deploy/frontend -- wget -qO- -T 4 http://backend/hostname
#   backend-xxxxxxxxxx-xxxxx
#
#   ./np-break-fix.sh verify
#   [ OK ] default-deny-all intact (all pods, Ingress+Egress, no allow rules).
#   [ OK ] lab-harness-intruder-open present.
#   [ OK ] frontend -> http://backend/hostname works (DNS + Service + policies).
#   [ OK ] intruder -> backend:8080 blocked.
#   [ OK ] frontend -> intruder:8080 blocked (frontend egress is scoped).
#   [ OK ] frontend -> Internet blocked (weak check: also passes on an offline VM).
#
#   Shortcuts that verify rejects, and why they are wrong in production:
#   - Deleting default-deny-all: returns to allow-all, so zero trust is gone.
#   - `egress: [{}]` on the frontend: fixes DNS and the port in one go, but lets
#     a compromised frontend reach anything, including the Internet.
#   - `ingress: [{}]` or `podSelector: {}` in the backend's from: any pod in the
#     namespace (the intruder too) reaches the API.
#   - Relabeling the frontend to app=front: "fixes" it by making the workload
#     fit a broken policy. The next Deployment rollout silently undoes it.
#
# -----------------------------------------------------------------------------
# Diagnostic method to keep for the exam
# -----------------------------------------------------------------------------
#   1. Which policies select the SOURCE pod for Egress? Which select the
#      DESTINATION pod for Ingress? Both sides must allow the flow.
#   2. Resolve names first (nslookup): a DNS timeout under default-deny is
#      almost always missing egress to kube-dns on 53/UDP+TCP.
#   3. Compare policy ports with the pod's containerPort / Service targetPort,
#      never with the Service port.
#   4. Check every selector against real labels
#      (kubectl get pods -l <selector>); an empty result means a dead rule.
#   5. Mind the YAML shape of peers: one list item with namespaceSelector and
#      podSelector = AND, two list items = OR.
#   6. Cilium: `hubble observe --verdict DROPPED -n ckne-np-lab`;
#      Calico: `calicoctl` / flow logs. They show exactly which flow is dropped.
#
# Cleanup:  ./np-break-fix.sh cleanup
# =============================================================================