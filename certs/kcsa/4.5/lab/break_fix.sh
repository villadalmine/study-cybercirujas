#!/usr/bin/env bash
# ==============================================================================
# KCSA Certification Lab: Topic 4.5 - Attacker on the Network
# Break & Fix Scenario: Network Isolation & Lateral Movement Prevention
# Target Exam Weight: 2.29%
# Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# ==============================================================================

set -euo pipefail

COLOR_RESET="\033[0m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[0;36m"

echo -e "${COLOR_CYAN}[+] Checking environment prerequisites...${COLOR_RESET}"
if ! command -v kubectl &> /dev/null; then
    echo -e "${COLOR_RED}[!] Error: 'kubectl' is required but not installed on this system.${COLOR_RESET}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${COLOR_RED}[!] Error: Unable to connect to a valid Kubernetes cluster.${COLOR_RESET}"
    exit 1
fi

echo -e "${COLOR_GREEN}[+] Kubernetes cluster connectivity verified.${COLOR_RESET}"

# Cleanup routine
cleanup() {
    echo -e "${COLOR_YELLOW}[+] Cleaning up existing lab environment...${COLOR_RESET}"
    kubectl delete namespace production attacker-space --ignore-not-found=true --wait=false
    echo -e "${COLOR_GREEN}[+] Cleanup completed successfully.${COLOR_RESET}"
}

if [[ "${1:-}" == "--clean" ]]; then
    cleanup
    exit 0
fi

cleanup

echo -e "${COLOR_CYAN}[+] Deploying KCSA 4.5 Lab Infrastructure...${COLOR_RESET}"

# Create Namespaces with explicit environment metadata labels
kubectl create namespace production
kubectl label namespace production environment=production tier=backend security-zone=restricted --overwrite

kubectl create namespace attacker-space
kubectl label namespace attacker-space environment=untrusted security-zone=untrusted --overwrite

# Deploy Target Sensitive Backend Service in production namespace
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-backend
  namespace: production
  labels:
    app: payment-backend
    tier: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-backend
  template:
    metadata:
      labels:
        app: payment-backend
        tier: api
    spec:
      containers:
      - name: api
        image: python:3.9-slim
        command: ["python3", "-c"]
        args:
          - |
            import http.server, socketserver
            class Handler(http.server.SimpleHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.send_header('Content-type', 'application/json')
                    self.end_headers()
                    self.wfile.write(b'{"status":"EXPOSED","data":"CONFIDENTIAL_PAYMENT_DATA_REDACTED"}')
            with socketserver.TCPServer(("", 8080), Handler) as httpd:
                httpd.serve_forever()
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: payment-backend-svc
  namespace: production
  labels:
    app: payment-backend
spec:
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
    name: http
  selector:
    app: payment-backend
EOF

# Deploy Authorized Frontend Client in production namespace
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-client
  namespace: production
  labels:
    app: frontend-client
    tier: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend-client
  template:
    metadata:
      labels:
        app: frontend-client
        tier: frontend
    spec:
      containers:
      - name: client
        image: curlimages/curl:8.5.0
        command: ["sh", "-c", "while true; do sleep 3600; done"]
EOF

# Deploy Compromised/Adversary Pod in attacker-space namespace
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rogue-attacker
  namespace: attacker-space
  labels:
    app: rogue-attacker
    role: adversary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rogue-attacker
  template:
    metadata:
      labels:
        app: rogue-attacker
        role: adversary
    spec:
      containers:
      - name: attacker
        image: curlimages/curl:8.5.0
        command: ["sh", "-c", "while true; do sleep 3600; done"]
EOF

echo -e "${COLOR_CYAN}[+] Waiting for workloads to stabilize...${COLOR_RESET}"
kubectl rollout status deployment/payment-backend -n production --timeout=90s
kubectl rollout status deployment/frontend-client -n production --timeout=90s
kubectl rollout status deployment/rogue-attacker -n attacker-space --timeout=90s

echo -e "${COLOR_YELLOW}[!] Injecting Flawed Network Policy (BREAK STEP)...${COLOR_RESET}"

# Injecting misconfigured NetworkPolicy containing a syntactic wildcard vulnerability
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payment-isolation-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: payment-backend
  ingress:
  - from:
    # VULNERABILITY: Empty object item inside list acts as a wildcard, allowing ALL ingress traffic across all namespaces!
    - {}
    ports:
    - protocol: TCP
      port: 8080
  policyTypes:
  - Ingress
EOF

echo -e "${COLOR_RED}"
echo "=========================================================================="
echo "                   KCSA LAB 4.5: ATTACKER ON THE NETWORK                  "
echo "=========================================================================="
echo -e "${COLOR_RESET}"
echo -e "${COLOR_CYAN}SCENARIO CONTEXT:${COLOR_RESET}"
echo "A rogue pod in namespace 'attacker-space' has achieved Remote Code Execution (RCE)."
echo "Due to a misconfigured NetworkPolicy in 'production', the attacker can perform"
echo "lateral movement and query sensitive API data directly over the unsegmented cluster network."
echo ""
echo -e "${COLOR_YELLOW}OBSERVED SYMPTOM:${COLOR_RESET}"
echo "The attacker pod CAN reach the sensitive internal payment API:"
echo "Command: kubectl exec -n attacker-space deployment/rogue-attacker -- curl -s --max-time 3 http://payment-backend-svc.production.svc.cluster.local:8080"
echo ""
echo "Output:"
kubectl exec -n attacker-space deployment/rogue-attacker -- curl -s --max-time 3 http://payment-backend-svc.production.svc.cluster.local:8080 || true
echo ""
echo ""
echo -e "${COLOR_CYAN}YOUR OBJECTIVE:${COLOR_RESET}"
echo "1. Diagnose why 'payment-isolation-policy' fails to restrict untrusted ingress."
echo "2. Enforce a Default Deny All (Ingress & Egress) security baseline in namespace 'production'."
echo "3. Authorize ingress to 'app: payment-backend' ONLY from pods labeled 'app: frontend-client'"
echo "   originating from namespaces labeled 'environment: production' on port 8080/TCP."
echo "4. Authorize essential Egress for 'frontend-client' (DNS port 53 & payment backend port 8080)."
echo "5. Confirm the rogue pod times out/is blocked while the legitimate client succeeds."
echo ""
echo -e "${COLOR_GREEN}Review the step-by-step solution commented at the end of this script file.${COLOR_RESET}"
echo "=========================================================================="


# ==============================================================================
# TECHNICAL INSTRUCTOR GUIDE & COMPLETE RESOLUTION MANUAL
# Certification: KCSA (Kubernetes and Cloud Native Security Associate)
# Topic 4.5: Attacker on the Network (Exam Weight: 2.29%)
# ==============================================================================
#
# ------------------------------------------------------------------------------
# 1. DEEP TECHNICAL MECHANICS & THREAT LANDSCAPE
# ------------------------------------------------------------------------------
# Kubernetes uses a flat, unsegmented network model by default. Any pod can route
# traffic to any other pod IP across namespaces unless explicit NetworkPolicies are
# enforced by an active CNI plugin (e.g., Calico, Cilium, Antrea).
#
# Threat Vector - Lateral Movement:
# An attacker on the network who compromises a perimeter workload can scan internal
# subnets, connect to unauthenticated internal microservices, exfiltrate data, or
# query cloud provider metadata services (e.g., 169.254.169.254).
#
# NetworkPolicy YAML Mechanics & Pitfalls:
# 1. Wildcard Ingress Flaw:
#    spec:
#      ingress:
#      - from:
#        - {}   <-- An empty element in a list creates an 'allow all' wildcard match.
#
# 2. Logical OR vs Logical AND in Selectors:
#    Logical OR (Two separate array elements):
#    ingress:
#    - from:
#      - namespaceSelector: { matchLabels: { environment: production } }
#      - podSelector: { matchLabels: { app: frontend-client } }
#    Matches traffic from ANY pod in 'production' OR ANY pod matching 'app: frontend-client' in the local namespace.
#
#    Logical AND (Combined single array element):
#    ingress:
#    - from:
#      - namespaceSelector: { matchLabels: { environment: production } }
#        podSelector: { matchLabels: { app: frontend-client } }
#    Matches traffic ONLY from pods with 'app: frontend-client' inside namespaces labeled 'environment: production'.
#
# ------------------------------------------------------------------------------
# 2. STEP-BY-STEP REMEDIATION MANIFESTS
# ------------------------------------------------------------------------------
# Step 2.1: Apply Default Deny Ingress & Egress Baseline for Namespace `production`
#
# Create file `default-deny-all.yaml`:
# ------------------------------------------------------------------------------
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: default-deny-all
#   namespace: production
# spec:
#   podSelector: {}
#   policyTypes:
#   - Ingress
#   - Egress
# ------------------------------------------------------------------------------
# Execute:
# $ kubectl apply -f default-deny-all.yaml
#
# Step 2.2: Delete Broken Policy and Apply Strict Ingress Policy
#
# Execute:
# $ kubectl delete netpol payment-isolation-policy -n production
#
# Create file `allow-frontend-to-payment.yaml`:
# ------------------------------------------------------------------------------
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: allow-frontend-to-payment
#   namespace: production
# spec:
#   podSelector:
#     matchLabels:
#       app: payment-backend
#   policyTypes:
#   - Ingress
#   ingress:
#   - from:
#     - namespaceSelector:
#         matchLabels:
#           environment: production
#       podSelector:
#         matchLabels:
#           app: frontend-client
#     ports:
#     - protocol: TCP
#       port: 8080
# ------------------------------------------------------------------------------
# Execute:
# $ kubectl apply -f allow-frontend-to-payment.yaml
#
# Step 2.3: Grant Frontend Egress to Payment Backend and Cluster DNS
#
# Create file `allow-frontend-egress.yaml`:
# ------------------------------------------------------------------------------
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: allow-frontend-egress
#   namespace: production
# spec:
#   podSelector:
#     matchLabels:
#       app: frontend-client
#   policyTypes:
#   - Egress
#   egress:
#   # Allow CoreDNS name resolution
#   - to:
#     - namespaceSelector: {}
#       podSelector:
#         matchLabels:
#           k8s-app: kube-dns
#     ports:
#     - protocol: UDP
#       port: 53
#     - protocol: TCP
#       port: 53
#   # Allow HTTP communication to payment backend
#   - to:
#     - podSelector:
#         matchLabels:
#           app: payment-backend
#     ports:
#     - protocol: TCP
#       port: 8080
# ------------------------------------------------------------------------------
# Execute:
# $ kubectl apply -f allow-frontend-egress.yaml
#
# ------------------------------------------------------------------------------
# 3. VERIFICATION COMMANDS AND EXPECTED OUTPUTS
# ------------------------------------------------------------------------------
# Command 1: Test Rogue Attacker (Must fail / timeout)
# $ kubectl exec -n attacker-space deployment/rogue-attacker -- curl -s --max-time 3 http://payment-backend-svc.production.svc.cluster.local:8080
# Expected Output:
# (Command hangs for 3 seconds and exits with status 28 / Connection timed out)
#
# Command 2: Test Authorized Frontend Client (Must return 200 OK JSON)
# $ kubectl exec -n production deployment/frontend-client -- curl -s --max-time 3 http://payment-backend-svc.production.svc.cluster.local:8080
# Expected Output:
# {"status":"EXPOSED","data":"CONFIDENTIAL_PAYMENT_DATA_REDACTED"}
#
# Command 3: Audit active policies in production namespace
# $ kubectl get netpol -n production
# Expected Output:
# NAME                        POD-SELECTOR          AGE
# allow-frontend-egress       app=frontend-client   1m
# allow-frontend-to-payment   app=payment-backend   1m
# default-deny-all            <none>                1m
#
# ------------------------------------------------------------------------------
# 4. ARCHITECTURAL TRADE-OFFS & PRODUCTION REASONING
# ------------------------------------------------------------------------------
# - CNI Support: Native NetworkPolicies are non-enforcing unless a supporting CNI
#   dataplane (Calico, Cilium, Antrea) is configured. Flannel alone ignores policies.
# - Dataplane Performance: Legacy iptables evaluation scales O(N) with the number of rules.
#   For large-scale production clusters (>10,000 pods), eBPF-based CNIs (Cilium) evaluate
#   network rules in kernel space using hash maps with O(1) efficiency.
# - Zero-Trust & Service Mesh: L3/L4 NetworkPolicies do not validate payload signatures
#   or cryptographic identity. Combine NetworkPolicies with mTLS (Istio/Linkerd)
#   and eBPF transparent encryption (WireGuard/IPsec) for comprehensive network defense.
#
# ------------------------------------------------------------------------------
# 5. OFFICIAL REFERENCE SOURCES
# ------------------------------------------------------------------------------
# - CNCF KCSA Curriculum Specification:
#   https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Official Network Policies Documentation:
#   https://kubernetes.io/docs/concepts/services-networking/network-policies/
# - Kubernetes Securing Cluster Networking Guide:
#   https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
# - Cilium Network Policy & eBPF Security Architecture:
#   https://docs.cilium.io/en/stable/security/policy/
# - Project Calico Network Policy Best Practices:
#   https://docs.tigera.io/calico/latest/network-policy/get-started/