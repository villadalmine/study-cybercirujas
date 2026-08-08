#!/usr/bin/env bash
# ==============================================================================
# KCSA Certification Lab: Topic 2.9 - Container Networking Security
# Exam Weight: 2.0 | Target: Kubernetes and Cloud Native Security Associate (KCSA)
# Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# ==============================================================================
# DESCRIPTION:
# This script injects a real-world container networking security incident into
# a Kubernetes cluster. It enforces strict NetworkPolicies (zero-trust architecture)
# but introduces subtle misconfigurations in label selectors and egress DNS rules.
#
# PREREQUISITES:
# - A disposable Kubernetes cluster (Minikube, Kind, k3s, or test control-plane)
# - A CNI plugin supporting NetworkPolicy enforcement (Calico, Cilium, Kube-router)
# - kubectl CLI configured with cluster-admin access
# ==============================================================================

set -euo pipefail

NAMESPACE="kcsa-netsec-lab"

echo "[+] Checking environment prerequisites..."
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: 'kubectl' executable not found in PATH." >&2
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster via kubectl context." >&2
    exit 1
fi

echo "[+] Initializing clean laboratory environment in namespace '${NAMESPACE}'..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true &> /dev/null || true
kubectl create namespace "${NAMESPACE}"

echo "[+] Deploying target workload architecture..."

# 1. Deploy API Backend Service (Internal target)
kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-backend
  labels:
    app: backend
    tier: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
      tier: api
  template:
    metadata:
      labels:
        app: backend
        tier: api
    spec:
      containers:
      - name: hashicorp-http-echo
        image: hashicorp/http-echo:0.2.3
        args:
        - "-text=KCSA_CONTAINER_NETWORKING_SUCCESS"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: api-backend-svc
  labels:
    app: backend
    tier: api
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
    name: http
    protocol: TCP
  selector:
    app: backend
    tier: api
EOF

# 2. Deploy Web Frontend Workload (Client component)
kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  labels:
    app: frontend
    tier: ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
      tier: ui
  template:
    metadata:
      labels:
        app: frontend
        tier: ui
    spec:
      containers:
      - name: client
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
EOF

echo "[+] Waiting for pod deployments to reach Ready state..."
kubectl wait --namespace="${NAMESPACE}" \
  --for=condition=ready pod \
  --selector=tier=api \
  --timeout=60s

kubectl wait --namespace="${NAMESPACE}" \
  --for=condition=ready pod \
  --selector=tier=ui \
  --timeout=60s

echo "[+] Applying Zero-Trust Security Baseline & Injected NetworkPolicy Faults..."

# 3. Apply Global Default-Deny-All Policy (Zero-Trust Baseline)
kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: kcsa-netsec-lab
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# 4. Inject Faulty Egress Policy on Frontend Pods (Broken DNS & Selector Mismatch)
kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress-policy
  namespace: kcsa-netsec-lab
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress:
  # FAULT 1: Selector uses 'app: backend-api' instead of actual pod label 'app: backend'
  - to:
    - podSelector:
        matchLabels:
          app: backend-api
    ports:
    - protocol: TCP
      port: 8080
  # FAULT 2: Missing Egress rule for CoreDNS (UDP/TCP 53) to namespace 'kube-system'
EOF

# 5. Inject Faulty Ingress Policy on Backend Pods (Selector Mismatch)
kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-ingress-policy
  namespace: kcsa-netsec-lab
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  # FAULT 3: Ingress from selector uses 'role: web-client' instead of 'app: frontend'
  - from:
    - podSelector:
        matchLabels:
          role: web-client
    ports:
    - protocol: TCP
      port: 8080
EOF

cat <<'EOF'

================================================================================
  KCSA LAB BREAK & FIX: CONTAINER NETWORKING & SECURITY INCIDENT (TOPIC 2.9)
================================================================================

[!] INCIDENT SUMMARY:
The SRE security team configured a Zero-Trust Network Policy model in namespace 
'kcsa-netsec-lab' using a 'default-deny-all' baseline. However, after applying 
the custom Egress and Ingress NetworkPolicies, communication between the frontend 
and backend workloads failed completely.

[!] OBSERVED SYMPTOMS:
1. Executing a DNS resolution lookup or HTTP request from the 'web-frontend' pod 
   to 'api-backend-svc.kcsa-netsec-lab.svc.cluster.local:8080' times out.
2. Even direct pod IP connections fail due to multi-layered network policy blocks.

[!] REPRODUCTION COMMAND:
Run the following verification command to confirm the breakage:

  FRONTEND_POD=$(kubectl get pod -n kcsa-netsec-lab -l app=frontend -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n kcsa-netsec-lab "${FRONTEND_POD}" -- curl -m 3 http://api-backend-svc:8080

Expected Output during Incident: 
  curl: (6) Could not resolve host: api-backend-svc (or connection timeout)

--------------------------------------------------------------------------------
[?] OBJECTIVE & TASK FOR THE STUDENT:
1. Troubleshoot the NetworkPolicies in namespace 'kcsa-netsec-lab'.
2. Fix 'frontend-egress-policy' so that:
   a) Egress DNS traffic (UDP/TCP Port 53) is permitted to CoreDNS pods in 'kube-system'.
   b) Egress TCP 8080 traffic accurately selects the target backend pod labels.
3. Fix 'backend-ingress-policy' so that:
   a) Ingress TCP 8080 traffic accurately accepts traffic from 'app=frontend' pods.
4. Verify that default isolation remains intact for non-whitelisted traffic.

================================================================================
EOF

# ==============================================================================
# SOLUTION & DIAGNOSTIC STEPS (COMMENTED OUT BELOW)
# ==============================================================================
#
# STEP 1: ROOT CAUSE ANALYSIS & DIAGNOSTICS
# ------------------------------------------------------------------------------
# A) Check pod labels in the namespace:
#    kubectl get pods -n kcsa-netsec-lab --show-labels
#    - Frontend Pod Labels: app=frontend, tier=ui
#    - Backend Pod Labels:  app=backend, tier=api
#
# B) Inspect existing NetworkPolicies:
#    kubectl get netpol -n kcsa-netsec-lab
#    kubectl describe netpol -n kcsa-netsec-lab
#
# C) Identify the 3 root causes:
#    1. 'frontend-egress-policy' specifies podSelector 'app: backend-api' (Does NOT match 'app: backend').
#    2. 'frontend-egress-policy' lacks an Egress rule allowing UDP/TCP port 53 to 'kube-system' (CoreDNS).
#    3. 'backend-ingress-policy' specifies ingress from podSelector 'role: web-client' (Does NOT match 'app: frontend').
#
# ------------------------------------------------------------------------------
# STEP 2: REMEDIATION MANIFESTS
# ------------------------------------------------------------------------------
# Apply the corrected NetworkPolicies using kubectl:
#
# cat <<'SOL_EOF' | kubectl apply -n kcsa-netsec-lab -f -
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: frontend-egress-policy
#   namespace: kcsa-netsec-lab
# spec:
#   podSelector:
#     matchLabels:
#       app: frontend
#   policyTypes:
#   - Egress
#   egress:
#   # Rule 1: Allow Egress to backend workload on TCP 8080
#   - to:
#     - podSelector:
#         matchLabels:
#           app: backend
#     ports:
#     - protocol: TCP
#       port: 8080
#   # Rule 2: Allow Egress to CoreDNS in kube-system namespace for name resolution
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
# ---
# apiVersion: networking.k8s.io/v1
# kind: NetworkPolicy
# metadata:
#   name: backend-ingress-policy
#   namespace: kcsa-netsec-lab
# spec:
#   podSelector:
#     matchLabels:
#       app: backend
#   policyTypes:
#   - Ingress
#   ingress:
#   # Rule 1: Allow Ingress from frontend workload on TCP 8080
#   - from:
#     - podSelector:
#         matchLabels:
#           app: frontend
#     ports:
#     - protocol: TCP
#       port: 8080
# SOL_EOF
#
# ------------------------------------------------------------------------------
# STEP 3: VERIFICATION
# ------------------------------------------------------------------------------
# Execute HTTP request from frontend to backend service:
#
# FRONTEND_POD=$(kubectl get pod -n kcsa-netsec-lab -l app=frontend -o jsonpath='{.items[0].metadata.name}')
# kubectl exec -n kcsa-netsec-lab "${FRONTEND_POD}" -- curl -s http://api-backend-svc:8080
#
# SUCCESSFUL OUTPUT:
# KCSA_CONTAINER_NETWORKING_SUCCESS
# ==============================================================================