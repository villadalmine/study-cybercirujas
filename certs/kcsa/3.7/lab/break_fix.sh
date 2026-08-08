#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes & Cloud Native Security Associate) Exam Study Material
# Domain 3.7: Network Policy (Exam Weight: 3.14)
# Lab Exercise: "Break & Fix: Multi-Tier Zero-Trust Isolation & DNS Blackhole"
#
# Role: Principal Platform Architect & Senior SRE Instructor
# Target Audience: Platform Engineers, Security Engineers, SREs preparing for KCSA
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# PRE-FLIGHT CHECK
# ------------------------------------------------------------------------------
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: 'kubectl' command line tool is not installed or not in PATH." >&2
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "ERROR: Unable to connect to the Kubernetes cluster. Check your KUBECONFIG." >&2
    exit 1
fi

echo "[+] Initializing KCSA 3.7 Network Policy Break & Fix Environment..."

# ------------------------------------------------------------------------------
# SETUP PHASE: Provision Multi-Tier Architecture & Namespaces
# ------------------------------------------------------------------------------
# Clean up previous runs if existing
kubectl delete ns kcsa-frontend-ns kcsa-backend-ns kcsa-db-ns --ignore-not-found=true > /dev/null 2>&1

echo "[+] Creating production-like namespaces with standardized security labels..."
kubectl create ns kcsa-frontend-ns > /dev/null
kubectl label ns kcsa-frontend-ns tier=frontend environment=production --overwrite > /dev/null

kubectl create ns kcsa-backend-ns > /dev/null
kubectl label ns kcsa-backend-ns tier=backend environment=production --overwrite > /dev/null

kubectl create ns kcsa-db-ns > /dev/null
kubectl label ns kcsa-db-ns tier=database environment=production --overwrite > /dev/null

echo "[+] Deploying workload pods across namespaces..."
# Target Database Pod & Service in kcsa-db-ns
kubectl run database --image=nginx:alpine -n kcsa-db-ns \
    --labels="app=database,role=db" \
    --port=5432 > /dev/null
kubectl expose pod database -n kcsa-db-ns --port=5432 --target-port=80 > /dev/null

# Middle-tier Backend Pod & Service in kcsa-backend-ns
kubectl run backend --image=nginx:alpine -n kcsa-backend-ns \
    --labels="app=backend,role=api" \
    --port=8080 > /dev/null
kubectl expose pod backend -n kcsa-backend-ns --port=8080 --target-port=80 > /dev/null

# Edge Frontend Pod in kcsa-frontend-ns
kubectl run frontend --image=nginx:alpine -n kcsa-frontend-ns \
    --labels="app=frontend,role=web" \
    --port=80 > /dev/null

echo "[+] Waiting for workloads to reach Ready state..."
kubectl wait --for=condition=Ready pod/database -n kcsa-db-ns --timeout=60s > /dev/null
kubectl wait --for=condition=Ready pod/backend -n kcsa-backend-ns --timeout=60s > /dev/null
kubectl wait --for=condition=Ready pod/frontend -n kcsa-frontend-ns --timeout=60s > /dev/null

# ------------------------------------------------------------------------------
# BREAK PHASE: Inject Misconfigured NetworkPolicy
# ------------------------------------------------------------------------------
echo "[+] Applying broken NetworkPolicy 'backend-security-policy' to namespace 'kcsa-backend-ns'..."

cat << 'EOF_BROKEN_NETPOL' | kubectl apply -f - > /dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-security-policy
  namespace: kcsa-backend-ns
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          tier: front-end   # BUG 1: Typo in namespace label selector ('front-end' instead of 'frontend')
      podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          tier: database
      podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 5433           # BUG 2: Port mismatch (Database listens on 5432, egress allows 5433)
  # BUG 3: Missing Egress rule for CoreDNS (UDP/TCP Port 53 to kube-system).
  # Enabling 'Egress' policyType enforces an implicit default-deny egress rule.
EOF_BROKEN_NETPOL

echo "[+] Injection complete. The cluster network control plane has been restricted."

# ------------------------------------------------------------------------------
# STUDENT LAB INSTRUCTIONS & DIAGNOSTIC OBJECTIVES
# ------------------------------------------------------------------------------
cat << 'EOF_STUDENT_GUIDE'

================================================================================
KCSA 3.7 TROUBLESHOOTING TASK: RECOVER MULTI-TIER ZERO-TRUST NETWORKING
================================================================================

SCENARIO OVERVIEW:
You are an SRE responding to a P1 Incident: The API backend in 'kcsa-backend-ns'
has lost connectivity to both ingress traffic from 'kcsa-frontend-ns' and egress
communication to the database in 'kcsa-db-ns'. Additionally, application logs show
DNS resolution timeouts.

A zero-trust NetworkPolicy ('backend-security-policy') was recently deployed to
the 'kcsa-backend-ns' namespace to enforce microsegmentation.

YOUR OBJECTIVE:
Diagnose and repair the 'backend-security-policy' NetworkPolicy in 'kcsa-backend-ns'
without disabling zero-trust isolation (do not delete policyTypes or set wildcards).

--------------------------------------------------------------------------------
OBSERVED SYMPTOMS:
--------------------------------------------------------------------------------
1. Frontend cannot reach Backend API on HTTP port 8080:
   $ kubectl exec -n kcsa-frontend-ns pod/frontend -- wget -T 3 -qO- http://backend.kcsa-backend-ns.svc.cluster.local:8080
   Result: Connection timed out / bad address.

2. Backend cannot resolve CoreDNS hostnames:
   $ kubectl exec -n kcsa-backend-ns pod/backend -- nslookup database.kcsa-db-ns.svc.cluster.local
   Result: Connection timed out; no servers could be reached.

3. Backend cannot reach Database on TCP port 5432 (even via direct IP):
   $ DB_IP=$(kubectl get pod database -n kcsa-db-ns -o jsonpath='{.status.podIP}')
   $ kubectl exec -n kcsa-backend-ns pod/backend -- nc -z -w 3 $DB_IP 5432
   Result: nc: download/connection timeout.

--------------------------------------------------------------------------------
DEEP ARCHITECTURAL MECHANICS & EXAMINATION POINTS (KCSA):
--------------------------------------------------------------------------------
1. IMPLICIT DEFAULT DENY:
   When a pod is selected by a NetworkPolicy containing `policyTypes: ["Ingress", "Egress"]`,
   it enters an isolated state. Any traffic not explicitly whitelisted in `ingress.from` 
   or `egress.to` is dropped by the Container Network Interface (CNI) plugin.

2. COREDNS EGRESS BLACKHOLE:
   Enforcing `policyTypes: [Egress]` blocks all outbound UDP/TCP port 53 packets to
   CoreDNS (typically in `kube-system`). Without an explicit egress rule targeting 
   CoreDNS or the `kube-system` namespace, pod hostname lookups immediately fail.

3. SELECTOR EVALUATION SEMANTICS (AND vs OR):
   - Combining `namespaceSelector` and `podSelector` within a SINGLE list element:
     ```yaml
     from:
     - namespaceSelector: { matchLabels: { tier: frontend } }
       podSelector: { matchLabels: { app: frontend } }
     ```
     Enforces LOGICAL AND: Traffic must originate from a pod labeled `app=frontend` 
     INSIDE a namespace labeled `tier=frontend`.

   - Separating `namespaceSelector` and `podSelector` into SEPARATE list elements:
     ```yaml
     from:
     - namespaceSelector: { matchLabels: { tier: frontend } }
     - podSelector: { matchLabels: { app: frontend } }
     ```
     Enforces LOGICAL OR: Traffic can originate from ANY pod in namespace `tier=frontend` 
     OR from pod `app=frontend` in the CURRENT namespace.

4. CNI ENFORCEMENT ENGINE:
   Kubernetes NetworkPolicies are non-enforcing API specifications. The underlying 
   CNI plugin (Calico, Cilium, Weave Net, Kube-router) translates NetworkPolicy specs
   into lower-level dataplane constructs:
   - Calico / Kube-router: Linux `iptables` chains (e.g., `cali-pi-*`, `KUBE-NWPLCY-*`) or IPSet entries.
   - Cilium: Linux `eBPF` maps (e.g., `cilium_lxc`, `cilium_policy_*`) attached to eBPF socket/tc filters.

--------------------------------------------------------------------------------
DIAGNOSTIC CHECKLIST FOR THE STUDENT:
--------------------------------------------------------------------------------
1. Inspect labels on namespaces to verify selector alignment:
   $ kubectl get ns --show-labels

2. Inspect labels on workload pods:
   $ kubectl get pods --all-namespaces --show-labels

3. Describe the active NetworkPolicy to inspect parsed rules:
   $ kubectl describe netpol backend-security-policy -n kcsa-backend-ns

4. Inspect CoreDNS deployment labels in `kube-system`:
   $ kubectl get pods -n kube-system -l k8s-app=kube-dns --show-labels
   OR check `kube-dns` namespace labels:
   $ kubectl get ns kube-system --show-labels

5. Edit and apply the corrected NetworkPolicy manifest.

================================================================================
EOF_STUDENT_GUIDE

exit 0

# ==============================================================================
# COMPLETE STEP-BY-STEP SOLUTION & REFERENCE GUIDE (HIDDEN / COMMENTED OUT)
# ==============================================================================
# To view this solution, read the commented section below or inspect this script file.
#
# ------------------------------------------------------------------------------
# ROOT CAUSE ANALYSIS (RCA)
# ------------------------------------------------------------------------------
# Bug 1: The ingress rule in `backend-security-policy` contains `tier: front-end` under
#        `namespaceSelector`. The actual namespace label set during provisioning is
#        `tier=frontend`. Because of the mismatch, no traffic matches the ingress filter.
#
# Bug 2: The egress rule allows port `5433` to `tier=database`. The target database
#        service listens on port `5432`.
#
# Bug 3: The policy defines `policyTypes: ["Ingress", "Egress"]` but provides no egress
#        rule for CoreDNS on UDP/TCP port 53. Because Kubernetes DNS resolution relies
#        on CoreDNS (in `kube-system`), outbound cluster DNS queries are dropped.
#
# ------------------------------------------------------------------------------
# DIAGNOSTIC COMMANDS & EXPECTED OUTPUTS
# ------------------------------------------------------------------------------
# 1. Audit Namespace Labels:
#    $ kubectl get ns -L tier,environment
#    NAME              STATUS   AGE   TIER       ENVIRONMENT
#    kcsa-backend-ns   Active   2m    backend    production
#    kcsa-db-ns        Active   2m    database   production
#    kcsa-frontend-ns Active   2m    frontend   production
#
# 2. Inspect Broken Policy Details:
#    $ kubectl describe netpol backend-security-policy -n kcsa-backend-ns
#    Name:         backend-security-policy
#    Namespace:    kcsa-backend-ns
#    Spec:
#      PodSelector:     app=backend
#      Allowing ingress traffic:
#        To Port: 8080/TCP
#        From:
#          NamespaceSelector: tier=front-end  <-- INCORRECT LABEL
#          PodSelector: app=frontend
#      Allowing egress traffic:
#        To Port: 5433/TCP                    <-- INCORRECT PORT
#        To:
#          NamespaceSelector: tier=database
#          PodSelector: app=database
#      Policy Types: Ingress, Egress          <-- IMPLICIT DROP FOR DNS (UDP 53)
#
# ------------------------------------------------------------------------------
# CORRECTED SYNTACTICALLY VALID MANIFEST
# ------------------------------------------------------------------------------
# File: backend-security-policy-fixed.yaml
#
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: backend-security-policy
#   namespace: kcsa-backend-ns
# spec:
#   podSelector:
#     matchLabels:
#       app: backend
#   policyTypes:
#   - Ingress
#   - Egress
#   ingress:
#   - from:
#     - namespaceSelector:
#         matchLabels:
#           tier: frontend          # FIXED: Aligned namespace label selector
#       podSelector:
#         matchLabels:
#           app: frontend
#     ports:
#     - protocol: TCP
#       port: 8080
#   egress:
#   # Rule 1: Application Egress to Database Namespace on Port 5432
#   - to:
#     - namespaceSelector:
#         matchLabels:
#           tier: database
#       podSelector:
#         matchLabels:
#           app: database
#     ports:
#     - protocol: TCP
#       port: 5432                  # FIXED: Aligned port to 5432
#   # Rule 2: CoreDNS Egress (Crucial for Zero-Trust Egress Policies)
#   - to:
#     - namespaceSelector: {}       # Matches any namespace (or specifically kube-system)
#     ports:
#     - protocol: UDP
#       port: 53
#     - protocol: TCP
#       port: 53
#
# ------------------------------------------------------------------------------
# REMEDIATION EXECUTION COMMANDS
# ------------------------------------------------------------------------------
# Apply the fixed manifest:
# $ cat << 'EOF_FIX' | kubectl apply -f -
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: backend-security-policy
#   namespace: kcsa-backend-ns
# spec:
#   podSelector:
#     matchLabels:
#       app: backend
#   policyTypes:
#   - Ingress
#   - Egress
#   ingress:
#   - from:
#     - namespaceSelector:
#         matchLabels:
#           tier: frontend
#       podSelector:
#         matchLabels:
#           app: frontend
#     ports:
#     - protocol: TCP
#       port: 8080
#   egress:
#   - to:
#     - namespaceSelector:
#         matchLabels:
#           tier: database
#       podSelector:
#         matchLabels:
#           app: database
#     ports:
#     - protocol: TCP
#       port: 5432
#   - to:
#     - namespaceSelector: {}
#     ports:
#     - protocol: UDP
#       port: 53
#     - protocol: TCP
#       port: 53
# EOF_FIX
#
# ------------------------------------------------------------------------------
# VERIFICATION COMMANDS & EXPECTED OUTPUTS
# ------------------------------------------------------------------------------
# 1. Verify DNS Resolution from Backend:
#    $ kubectl exec -n kcsa-backend-ns pod/backend -- nslookup database.kcsa-db-ns.svc.cluster.local
#    Server:         10.96.0.10
#    Address:        10.96.0.10#53
#    Name:   database.kcsa-db-ns.svc.cluster.local
#    Address: 10.244.0.15
#    (SUCCESS: DNS query resolved)
#
# 2. Verify Frontend -> Backend Ingress Connectivity:
#    $ kubectl exec -n kcsa-frontend-ns pod/frontend -- wget -T 3 -qO- http://backend.kcsa-backend-ns.svc.cluster.local:8080
#    <!DOCTYPE html>
#    <html><head><title>Welcome to nginx!</title></head>...
#    (SUCCESS: HTTP 200 OK returned)
#
# 3. Verify Backend -> Database Egress Connectivity:
#    $ DB_IP=$(kubectl get pod database -n kcsa-db-ns -o jsonpath='{.status.podIP}')
#    $ kubectl exec -n kcsa-backend-ns pod/backend -- nc -z -w 3 $DB_IP 5432
#    Connection to 10.244.0.15 5432 port [tcp/*] succeeded!
#    (SUCCESS: TCP connection established)
#
# 4. Verify Unauthorized Ingress Blocking (Positive Security Test):
#    Run temporary unlabelled pod in default namespace to test isolation:
#    $ kubectl run attacker --image=nginx:alpine -n default --rm -it -- restart=Never -- wget -T 2 http://backend.kcsa-backend-ns.svc.cluster.local:8080
#    wget: download timed out
#    (SUCCESS: Default isolation blocks unauthorized ingress traffic)
#
# ------------------------------------------------------------------------------
# ARCHITECTURAL TRADE-OFFS & PRODUCTION SRE BEST PRACTICES
# ------------------------------------------------------------------------------
# 1. Namespace-Scoped vs. Global Default-Deny Policies:
#    - Trade-off: Deploying a namespace-wide default deny (`podSelector: {}`) forces explicitly
#      authorizing all traffic paths, minimizing attack surfaces. However, it increases operational
#      complexity and risk of outages if developers forget CoreDNS or telemetry egress rules.
#    - Best Practice: Standardize baseline NetworkPolicy templates via GitOps pipelines or Policy-as-Code
#      (Kyverno/OPA Gatekeeper) to auto-inject cluster DNS egress rules.
#
# 2. Performance Overhead of CNI Network Policies:
#    - Large-scale clusters using legacy iptables-based CNIs suffer from O(N) rule evaluation degradation
#      when thousands of NetworkPolicy objects generate complex iptables chains.
#    - Best Practice: Adopt eBPF-native CNIs (such as Cilium) which leverage BPF map lookups with O(1)
#      complexity, enabling scalable microsegmentation without kernel packet filtering bottlenecks.
#
# ------------------------------------------------------------------------------
# OFFICIAL CNCF & KUBERNETES CITATIONS
# ------------------------------------------------------------------------------
# - CNCF KCSA Curriculum Specification:
#   https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Official Documentation: Network Policies:
#   https://kubernetes.io/docs/concepts/services-networking/network-policies/
# - Kubernetes Task Guide: Declare Network Policy:
#   https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
# - CNCF Security Technical Advisory Group (STAG) Best Practices:
#   https://github.com/cncf/tag-security
# ==============================================================================