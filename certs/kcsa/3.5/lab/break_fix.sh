#!/usr/bin/env bash

# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Exam Preparation
# Topic 3.5: Isolation and Segmentation
# Script Type: Break & Fix Hands-on Production Lab
#
# Official References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
# - Kubernetes Securing Cluster Infrastructure: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
# ==============================================================================

set -euo pipefail

COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_SUCCESS="\033[1;32m"
COLOR_ERROR="\033[1;31m"
COLOR_WARN="\033[1;33m"

echo -e "${COLOR_INFO}[+] Initializing KCSA Topic 3.5 Break & Fix Scenario: Isolation and Segmentation...${COLOR_RESET}"

# 1. Verification of Prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${COLOR_ERROR}[!] Error: 'kubectl' CLI tool is not installed or not in PATH.${COLOR_RESET}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${COLOR_ERROR}[!] Error: Unable to communicate with Kubernetes cluster via kubectl.${COLOR_RESET}"
    exit 1
fi

# 2. Cleanup previous runs
echo -e "${COLOR_INFO}[+] Cleaning up any pre-existing lab namespaces...${COLOR_RESET}"
kubectl delete namespace corp-finance corp-hr --ignore-not-found=true --wait=true &> /dev/null || true

# 3. Create Namespaces with production-grade metadata labels
echo -e "${COLOR_INFO}[+] Provisioning target namespaces with security labels...${COLOR_RESET}"
kubectl create namespace corp-finance
kubectl label namespace corp-finance tier=secure domain=finance kubernetes.io/metadata.name=corp-finance --overwrite

kubectl create namespace corp-hr
kubectl label namespace corp-hr tier=internal domain=hr kubernetes.io/metadata.name=corp-hr --overwrite

# 4. Deploy Workloads in corp-finance
echo -e "${COLOR_INFO}[+] Deploying finance-db (PostgreSQL mock) in namespace 'corp-finance'...${COLOR_RESET}"
kubectl apply -n corp-finance -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: finance-db
  labels:
    app.kubernetes.io/name: finance-db
    tier: database
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: finance-db
  template:
    metadata:
      labels:
        app.kubernetes.io/name: finance-db
        tier: database
    spec:
      containers:
      - name: db
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: finance-db-svc
spec:
  ports:
  - port: 5432
    targetPort: 80
    protocol: TCP
    name: postgresql
  selector:
    app.kubernetes.io/name: finance-db
EOF

echo -e "${COLOR_INFO}[+] Deploying finance-api in namespace 'corp-finance'...${COLOR_RESET}"
kubectl apply -n corp-finance -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: finance-api
  labels:
    app.kubernetes.io/name: finance-api
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: finance-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: finance-api
        tier: backend
    spec:
      containers:
      - name: api
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
EOF

# 5. Deploy Workloads in corp-hr (Cross-Tenant Workload)
echo -e "${COLOR_INFO}[+] Deploying hr-app in namespace 'corp-hr'...${COLOR_RESET}"
kubectl apply -n corp-hr -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hr-app
  labels:
    app.kubernetes.io/name: hr-app
    tier: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: hr-app
  template:
    metadata:
      labels:
        app.kubernetes.io/name: hr-app
        tier: frontend
    spec:
      containers:
      - name: hr
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
EOF

# Wait for deployments to be ready
echo -e "${COLOR_INFO}[+] Waiting for workloads to stabilize...${COLOR_RESET}"
kubectl rollout status deployment/finance-db -n corp-finance --timeout=60s
kubectl rollout status deployment/finance-api -n corp-finance --timeout=60s
kubectl rollout status deployment/hr-app -n corp-hr --timeout=60s

# 6. Apply Broken Network Policies (Injected Vulnerabilities & Misconfigurations)
echo -e "${COLOR_WARN}[!] Injecting isolation policy misconfigurations...${COLOR_RESET}"

# NetworkPolicy 1: Default Deny All Egress & Ingress in corp-finance (Unconditionally blocks CoreDNS and all internal connectivity)
kubectl apply -n corp-finance -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# NetworkPolicy 2: Ingress isolation policy on finance-db with selector label key mismatch
kubectl apply -n corp-finance -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-finance-db-ingress
spec:
  podSelector:
    matchLabels:
      app: finance-db
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          domain: finance
      podSelector:
        matchLabels:
          role: finance-backend
    ports:
    - protocol: TCP
      port: 5432
EOF

# NetworkPolicy 3: Egress policy on finance-api missing UDP/TCP 53 DNS egress permission
kubectl apply -n corp-finance -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-egress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: finance-api
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: finance-db
    ports:
    - protocol: TCP
      port: 5432
EOF

echo -e "${COLOR_SUCCESS}[✓] Environment configured! Break state actively engaged.${COLOR_RESET}"
echo ""
echo "================================================================================"
echo "                   KCSA TOPIC 3.5: ISOLATION & SEGMENTATION LAB                "
echo "================================================================================"
echo -e "STUDENT MISSION BRIEFING:"
echo -e "You are the Lead Platform Security Engineer assigned to secure the 'corp-finance' namespace."
echo -e "A junior administrator attempted to implement Zero-Trust network segmentation, but inadvertently broken intra-tenant communication and failed to correctly enforce egress policy isolation."
echo ""
echo -e "${COLOR_WARN}EXPECTED ARCHITECTURAL COMPLIANCE REQUIREMENTS:${COLOR_RESET}"
echo -e "1. Default-Deny Security Posture: Namespace 'corp-finance' must default-deny all unauthorized ingress and egress traffic."
echo -e "2. Intra-Tenant Communication: Pod 'finance-api' (in 'corp-finance') MUST resolve DNS and establish TCP connections to 'finance-db-svc.corp-finance.svc.cluster.local' on port 5432."
echo -e "3. Strict Multi-Tenancy Isolation: Workloads in 'corp-hr' MUST BE COMPLETELY BLOCKED from accessing any workload or service in 'corp-finance'."
echo -e "4. Explicit DNS Egress Exception: All network policies permitting pod egress must explicitly include DNS egress rules (UDP/TCP port 53 in 'kube-system')."
echo ""
echo -e "${COLOR_ERROR}CURRENT OBSERVED SYMPTOMS:${COLOR_RESET}"
echo -e "- 'finance-api' cannot resolve cluster DNS for 'finance-db-svc.corp-finance.svc.cluster.local' (nslookup times out)."
echo -e "- Direct TCP connections from 'finance-api' to 'finance-db' fail even when using raw Pod IPs due to label selector mismatches."
echo ""
echo -e "${COLOR_INFO}VERIFICATION & DIAGNOSTIC COMMANDS FOR STUDENT:${COLOR_RESET}"
echo "  # Test 1: Test DNS resolution from finance-api (Currently FAILS)"
echo "  kubectl exec -n corp-finance deployment/finance-api -- nslookup finance-db-svc.corp-finance.svc.cluster.local"
echo ""
echo "  # Test 2: Test TCP Connectivity from finance-api to finance-db (Currently FAILS)"
echo "  kubectl exec -n corp-finance deployment/finance-api -- curl -v --connect-timeout 3 http://finance-db-svc.corp-finance.svc.cluster.local:5432"
echo ""
echo "  # Test 3: Test Cross-Tenant Isolation from hr-app (MUST REMAIN BLOCKED)"
echo "  kubectl exec -n corp-hr deployment/hr-app -- curl -v --connect-timeout 3 http://finance-db-svc.corp-finance.svc.cluster.local:5432"
echo ""
echo "  # Inspection Commands:"
echo "  kubectl get netpol -n corp-finance"
echo "  kubectl describe netpol -n corp-finance"
echo "  kubectl get pods -n corp-finance --show-labels"
echo "================================================================================"
echo ""

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (FOR INSTRUCTOR REFERENCE & STUDENT REMEDIATION)
# ==============================================================================
#
# ROOT CAUSE ANALYSIS:
# --------------------
# 1. Label Mismatch on Ingress PodSelector:
#    - 'restrict-finance-db-ingress' specified 'podSelector.matchLabels: app: finance-db',
#      but the actual deployment uses standard recommended labels: 'app.kubernetes.io/name: finance-db'.
#    - Ingress source rule specified 'role: finance-backend', whereas 'finance-api' pod carries 'app.kubernetes.io/name: finance-api' and 'tier: backend'.
#
# 2. Missing CoreDNS Egress Rule:
#    - The policy 'allow-api-egress' on 'finance-api' allows TCP egress to port 5432 on 'finance-db', but under a Default-Deny-Egress model, DNS requests (UDP/TCP 53) to 'kube-system' are dropped.
#    - Without DNS egress permitted, pod name lookup 'finance-db-svc.corp-finance.svc.cluster.local' fails before TCP handshake can even initiate.
#
# 3. Namespace Selector Scope:
#    - Ingress rule combined namespaceSelector and podSelector inside a single array item without specifying the CNI-provided 'kubernetes.io/metadata.name' label or properly structuring cross-namespace rules.
#
# STEP-BY-STEP REMEDIATION MANIFESTS & COMMANDS:
# -----------------------------------------------
# Copy and execute the following commands to remediate the cluster state:
#
# Step 1: Remove erroneous/misconfigured NetworkPolicies
#   kubectl delete netpol restrict-finance-db-ingress allow-api-egress default-deny-all -n corp-finance
#
# Step 2: Apply production-grade zero-trust NetworkPolicies in 'corp-finance'
#
# kubectl apply -n corp-finance -f - <<'EOF_SOLUTION'
# ---
# # Policy 1: Global Default-Deny all Ingress and Egress in namespace corp-finance
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: default-deny-all
#   namespace: corp-finance
# spec:
#   podSelector: {}
#   policyTypes:
#   - Ingress
#   - Egress
# ---
# # Policy 2: Allow DNS Egress to CoreDNS in kube-system for all pods in corp-finance
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: allow-dns-egress
#   namespace: corp-finance
# spec:
#   podSelector: {}
#   policyTypes:
#   - Egress
#   egress:
#   - to:
#     - namespaceSelector:
#         matchLabels:
#           kubernetes.io/metadata.name: kube-system
#     ports:
#     - protocol: UDP
#       port: 53
#     - protocol: TCP
#       port: 53
# ---
# # Policy 3: Allow finance-api pod to egress TCP port 5432 to finance-db pod
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: allow-finance-api-to-db-egress
#   namespace: corp-finance
# spec:
#   podSelector:
#     matchLabels:
#       app.kubernetes.io/name: finance-api
#   policyTypes:
#   - Egress
#   egress:
#   - to:
#     - podSelector:
#         matchLabels:
#           app.kubernetes.io/name: finance-db
#     ports:
#     - protocol: TCP
#       port: 5432
# ---
# # Policy 4: Allow finance-db pod to receive ingress TCP port 5432 from finance-api pod
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: allow-finance-db-ingress-from-api
#   namespace: corp-finance
# spec:
#   podSelector:
#     matchLabels:
#       app.kubernetes.io/name: finance-db
#   policyTypes:
#   - Ingress
#   ingress:
#   - from:
#     - podSelector:
#         matchLabels:
#           app.kubernetes.io/name: finance-api
#     ports:
#     - protocol: TCP
#       port: 5432
# EOF_SOLUTION
#
# Step 3: Execute empirical runtime verification
#   # Test 1: Verify intra-tenant API -> DB connectivity (EXPECTED: Success / Connection open)
#   kubectl exec -n corp-finance deployment/finance-api -- nc -zv finance-db-svc.corp-finance.svc.cluster.local 5432
#
#   # Test 2: Verify cross-tenant HR -> Finance DB isolation (EXPECTED: Connection timed out / Dropped)
#   kubectl exec -n corp-hr deployment/hr-app -- nc -zv -w 3 finance-db-svc.corp-finance.svc.cluster.local 5432
# ==============================================================================