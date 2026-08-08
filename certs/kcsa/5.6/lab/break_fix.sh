#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes & Cloud Native Security Associate) Exam Preparation
# Topic 5.6: Connectivity (Exam Weight: 2.29%)
# Official Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# Kubernetes Docs Reference: https://kubernetes.io/docs/concepts/services-networking/network-policies/
#
# Lab Type: Break & Fix Scenario
# Target Environment: Disposable Kubernetes Cluster (minikube, kind, k3s, or cloud VM)
# ==============================================================================

set -euo pipefail

NAMESPACE="k8s-connectivity-lab"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BLUE}         KCSA Topic 5.6: Connectivity - Break & Fix Environment Setup         ${NC}"
echo -e "${BLUE}==============================================================================${NC}"

# Pre-flight check: kubectl availability
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl CLI tool is not installed or not in PATH.${NC}"
    exit 1
fi

# Pre-flight check: Cluster reachability
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Unable to connect to Kubernetes cluster. Verify KUBECONFIG.${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/4] Provisioning isolated lab namespace '${NAMESPACE}'...${NC}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Ensure standard labels exist for network policy selectors
kubectl label namespace "${NAMESPACE}" environment=production security-zone=restricted --overwrite
kubectl label namespace kube-system kubernetes.io/metadata.name=kube-system --overwrite

echo -e "${YELLOW}[2/4] Deploying target application workloads (Frontend & Backend)...${NC}"

# Deploy Payment API Backend Service & Pod
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-backend
  labels:
    tier: backend
    app: payment-api
spec:
  replicas: 1
  selector:
    matchLabels:
      tier: backend
      app: payment-api
  template:
    metadata:
      labels:
        tier: backend
        app: payment-api
    spec:
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: api-backend-svc
  labels:
    tier: backend
    app: payment-api
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
  selector:
    tier: backend
    app: payment-api
EOF

# Deploy Web Client Frontend Pod
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  labels:
    tier: frontend
    app: customer-portal
spec:
  replicas: 1
  selector:
    matchLabels:
      tier: frontend
      app: customer-portal
  template:
    metadata:
      labels:
        tier: frontend
        app: customer-portal
    spec:
      containers:
      - name: client
        image: curlimages/curl:8.5.0
        command: ["sh", "-c", "sleep 3600"]
EOF

echo -e "${YELLOW}[3/4] Waiting for application workloads to become Ready...${NC}"
kubectl rollout status deployment/api-backend -n "${NAMESPACE}" --timeout=60s
kubectl rollout status deployment/web-frontend -n "${NAMESPACE}" --timeout=60s

echo -e "${YELLOW}[4/4] Injecting flawed NetworkPolicy security objects (Breaking connectivity)...${NC}"

# Apply broken NetworkPolicies:
# 1. Default-deny-all for Ingress & Egress across namespace.
# 2. Ingress NetworkPolicy for backend containing a podSelector label typo ('tier: api' vs 'tier: backend').
# 3. Egress NetworkPolicy for frontend missing UDP/TCP port 53 egress rules for CoreDNS resolution.

cat <<EOF | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels:
      tier: api  # MISCONFIGURATION 1: Incorrect selector label. Backend has 'tier: backend'.
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: frontend
    ports:
    - protocol: TCP
      port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-egress
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          tier: backend
    ports:
    - protocol: TCP
      port: 80
    # MISCONFIGURATION 2: Missing DNS resolution egress rule to CoreDNS (kube-system namespace, UDP/TCP port 53).
EOF

echo -e "\n${GREEN}==============================================================================${NC}"
echo -e "${GREEN}             LAB ENVIRONMENT HAS BEEN BROKEN SUCCESSFULLY                     ${NC}"
echo -e "${GREEN}==============================================================================${NC}\n"

cat <<'BRIEFING'
--------------------------------------------------------------------------------
STUDENT INCIDENT BRIEFING & TROUBLESHOOTING GOALS
--------------------------------------------------------------------------------
Domain: CNCF KCSA - Section 5.6 Connectivity
Scenario: Zero-Trust NetworkPolicy Enforcement Failure & Pod Inter-Connectivity Outage

INCIDENT DESCRIPTION:
Security Engineering applied micro-segmentation policies using NetworkPolicy objects 
in the namespace 'k8s-connectivity-lab'. Immediately after deployment, the client pod
'web-frontend' lost all connectivity to 'api-backend-svc'.

SYMPTOMS OBSERVED BY SRE MONITORING:
1. HTTP requests to service DNS 'http://api-backend-svc' fail due to domain lookup timeout.
2. HTTP requests directly targeting the Backend Pod IP address fail with connection timeouts.

YOUR TASK:
1. Investigate the active NetworkPolicies in 'k8s-connectivity-lab'.
2. Fix the NetworkPolicies without removing the 'default-deny-all' policy.
3. Ensure 'web-frontend' can resolve internal cluster DNS via CoreDNS (port 53 UDP/TCP in kube-system).
4. Ensure 'web-frontend' can connect to 'api-backend-svc' on port 80/TCP.
5. Verify that unauthorized pods in the namespace remain isolated (Zero-Trust principle).

DIAGNOSTIC COMMANDS TO BEGIN WITH:

# Test 1: DNS Resolution & Service HTTP reachability from Frontend Pod (Expected output: Failure/Timeout)
FRONTEND_POD=$(kubectl get pod -n k8s-connectivity-lab -l tier=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n k8s-connectivity-lab "${FRONTEND_POD}" -- curl -v --connect-timeout 5 http://api-backend-svc

# Test 2: Direct Pod IP reachability bypassing DNS (Expected output: Failure/Timeout)
BACKEND_IP=$(kubectl get pod -n k8s-connectivity-lab -l tier=backend -o jsonpath='{.items[0].metadata.podIP}')
kubectl exec -n k8s-connectivity-lab "${FRONTEND_POD}" -- curl -v --connect-timeout 5 "http://${BACKEND_IP}:80"

# Test 3: Inspect existing NetworkPolicies and Label selectors
kubectl get netpol -n k8s-connectivity-lab -o wide
kubectl get pods -n k8s-connectivity-lab --show-labels

--------------------------------------------------------------------------------
BRIEFING

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & EXPLANATION (OFFICIAL INSTRUCTOR GUIDANCE)
# ==============================================================================
#
# TECHNICAL ROOT CAUSE ANALYSIS:
# 1. Default Deny Policy: 'default-deny-all' selects all pods (`podSelector: {}`) and
#    enforces default isolation for both Ingress and Egress traffic.
# 2. Ingress Misconfiguration: 'allow-frontend-to-backend' uses `matchLabels: tier: api`.
#    However, the backend deployment pod template uses `tier: backend`. The selector matches 0 pods,
#    leaving the backend pod isolated by the default-deny-all policy.
# 3. Egress Misconfiguration: 'allow-frontend-egress' restricts egress from 'web-frontend' to
#    only destination pods matching `tier: backend` on TCP 80. When curl attempts to resolve
#    'api-backend-svc', the OS sends a DNS query to CoreDNS (10.96.0.10 / kube-dns pod IP on UDP/TCP 53).
#    Because DNS egress is not explicitly allowed, the CNI plugin drops outgoing DNS packets.
#
# STEP-BY-STEP FIX PROCEDURE:
#
# 1. Correct the Ingress NetworkPolicy selector so it matches `tier: backend`.
# 2. Add an Egress rule in the frontend NetworkPolicy allowing egress to namespace `kube-system`
#    on UDP and TCP port 53 for CoreDNS resolution.
#
# SYNTACTICALLY VALID PRODUCTION FIX MANIFEST:
# Execute the command below to re-apply the corrected NetworkPolicies:
#
# cat <<EOF | kubectl apply -n k8s-connectivity-lab -f -
# ---
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: default-deny-all
# spec:
#   podSelector: {}
#   policyTypes:
#   - Ingress
#   - Egress
# ---
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: allow-frontend-to-backend
# spec:
#   podSelector:
#     matchLabels:
#       tier: backend
#   policyTypes:
#   - Ingress
#   ingress:
#   - from:
#     - podSelector:
#         matchLabels:
#           tier: frontend
#     ports:
#     - protocol: TCP
#       port: 80
# ---
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: allow-frontend-egress
# spec:
#   podSelector:
#     matchLabels:
#       tier: frontend
#   policyTypes:
#   - Egress
#   egress:
#   # Rule 1: Allow TCP port 80 to Backend workloads
#   - to:
#     - podSelector:
#         matchLabels:
#           tier: backend
#     ports:
#     - protocol: TCP
#       port: 80
#   # Rule 2: Allow DNS resolution (UDP/TCP 53) to CoreDNS in kube-system
#   - to:
#     - namespaceSelector:
#         matchLabels:
#           kubernetes.io/metadata.name: kube-system
#       podSelector:
#         matchLabels:
#           k8s-app: kube-dns
#     ports:
#     - protocol: UDP
#       port: 53
#     - protocol: TCP
#       port: 53
# EOF
#
# SOLUTION VERIFICATION:
#
# 1. Verify DNS + Ingress + Egress path end-to-end:
#    FRONTEND_POD=$(kubectl get pod -n k8s-connectivity-lab -l tier=frontend -o jsonpath='{.items[0].metadata.name}')
#    kubectl exec -n k8s-connectivity-lab "${FRONTEND_POD}" -- curl -s -I --connect-timeout 5 http://api-backend-svc
#    Expected output: HTTP/1.1 200 OK
#
# 2. Verify Zero-Trust posture (unauthorized pods are still denied access):
#    kubectl run unauthorized-test -n k8s-connectivity-lab --image=curlimages/curl:8.5.0 --rm -i --tty -- restart=Never -- curl -v --connect-timeout 3 http://api-backend-svc
#    Expected output: curl: (28) Connection timed out
# ==============================================================================