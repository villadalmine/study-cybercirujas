#!/usr/bin/env bash
# ==============================================================================
# CNPE (Certified Network / Platform Engineer) - Lab Scenario 4.3
# Topic: Deploying Applications Using Progressive Delivery Strategies (Blue/Green or Canary)
# Curriculum Reference: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# Progressive Delivery Specs: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#canary
# Argo Rollouts Concepts: https://argo-rollouts.readthedocs.io/en/stable/concepts/architecture/
# ==============================================================================
# 
# DESCRIPTION:
# This script sets up a simulated progressive delivery (Canary) release 
# environment on Kubernetes using weighted ingress rules and service selectors.
# It introduces a subtle, production-impacting configuration fault during a 
# canary deployment phase.
#
# DO NOT RUN IN PRODUCTION - Intended for disposable lab environments.
# ==============================================================================

set -euo pipefail

NAMESPACE="cnpe-canary-lab"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}[+] Initializing CNPE Topic 4.3 Break & Fix Lab Environment...${NC}"

# Check cluster prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[!] Error: kubectl command not found. Please run on a node with cluster access.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[!] Error: Cannot connect to Kubernetes cluster via kubectl.${NC}"
    exit 1
fi

# Clean up existing lab resources if present
echo -e "${YELLOW}[*] Cleaning up any previous lab state...${NC}"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true &> /dev/null || true

# Create Lab Namespace
echo -e "${BLUE}[+] Creating namespace '${NAMESPACE}'...${NC}"
kubectl create namespace "${NAMESPACE}"

# 1. Deploy Stable Application (v1.0.0)
echo -e "${BLUE}[+] Deploying Production Stable Release (v1.0.0)...${NC}"
cat << 'EOF' | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service-stable
  labels:
    app: payment-service
    tier: api
    track: stable
    version: v1.0.0
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-service
      track: stable
  template:
    metadata:
      labels:
        app: payment-service
        tier: api
        track: stable
        version: v1.0.0
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:0.2.3
        args:
        - "-text=VERSION_1.0.0_STABLE_OK"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
          name: http
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 3
EOF

# 2. Deploy Canary Application (v2.0.0)
echo -e "${BLUE}[+] Deploying Progressive Canary Release (v2.0.0)...${NC}"
cat << 'EOF' | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service-canary
  labels:
    app: payment-service
    tier: api
    track: canary
    version: v2.0.0
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-service
      track: canary
  template:
    metadata:
      labels:
        app: payment-service
        tier: api
        track: canary
        version: v2.0.0
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:0.2.3
        args:
        - "-text=VERSION_2.0.0_CANARY_NEW_FEATURE"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
          name: http
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 3
EOF

# 3. Create Stable Service
echo -e "${BLUE}[+] Creating Stable Service routing baseline traffic...${NC}"
cat << 'EOF' | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: Service
metadata:
  name: payment-service-stable-svc
  labels:
    app: payment-service
    service: stable
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8080
    name: http
    protocol: TCP
  selector:
    app: payment-service
    track: stable
EOF

# 4. Inject Breaking Configuration Bug in Canary Service & Ingress Progressive Weights
# BUG EXPLANATION FOR ARCHITECT: 
# The SRE automation script configured the canary service with a targetPort mismatch (8081 instead of 8080)
# and set an illegal label selector key ('track: stable' instead of 'track: canary'), causing:
# 1) Stable pods to be load balanced into Canary service endpoints.
# 2) Canary ingress routing to fail with 502 Bad Gateway / Connection Refused when hitting port 8081.
# 3) Traffic split metrics to register 100% loss on canary traffic while polluting stable logs.

echo -e "${YELLOW}[!] Injecting progressive delivery misconfiguration (Breaking state)...${NC}"
cat << 'EOF' | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: Service
metadata:
  name: payment-service-canary-svc
  labels:
    app: payment-service
    service: canary
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8081 # <--- FAULT: Container listens on 8080!
    name: http
    protocol: TCP
  selector:
    app: payment-service
    track: stable    # <--- FAULT: Selecting stable track instead of canary track!
EOF

# 5. Create Primary & Canary Ingress Resources
echo -e "${BLUE}[+] Configuring NGINX Ingress Controller Canary Routing (20% Weight)...${NC}"
cat << 'EOF' | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: payment-service-primary-ingress
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  rules:
  - host: payment.internal.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: payment-service-stable-svc
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: payment-service-canary-ingress
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "20"
spec:
  rules:
  - host: payment.internal.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: payment-service-canary-svc
            port:
              number: 80
EOF

# Wait for deployments to rollout
echo -e "${BLUE}[+] Waiting for workloads to stabilize...${NC}"
kubectl rollout status deployment/payment-service-stable -n "${NAMESPACE}" --timeout=60s
kubectl rollout status deployment/payment-service-canary -n "${NAMESPACE}" --timeout=60s

echo -e "\n=============================================================================="
echo -e "${RED}               LAB BROKEN: PROGRESSIVE DELIVERY INCIDENT                      ${NC}"
echo -e "=============================================================================="
echo -e "${YELLOW}INCIDENT SUMMARY:${NC}"
echo -e "Your automated CI/CD pipeline initiated a 20% Canary rollout for 'payment-service-canary' (v2.0.0)."
echo -e "Synthetic monitoring and user reports show intermittent HTTP 502/503 errors and connection failures"
echo -e "when requests hit the canary endpoint, while canary version v2.0.0 receives ZERO actual traffic."
echo -e ""
echo -e "${YELLOW}SYMPTOMS & OBSERVATIONS:${NC}"
echo -e "1. Direct requests to 'payment-service-canary-svc' fail to reach v2.0.0 pods."
echo -e "2. Endpoints object for 'payment-service-canary-svc' points to the WRONG pod IPs (v1.0.0 pods)."
echo -e "3. Port mapping between service definition and target container port is mismatched."
echo -e ""
echo -e "${YELLOW}STUDENT OBJECTIVES:${NC}"
echo -e "1. Diagnose the Service Endpoints and Selector mapping for namespace: ${NAMESPACE}"
echo -e "2. Fix 'payment-service-canary-svc' so it targets only pods with 'track=canary' on containerPort 8080."
echo -e "3. Verify traffic routing: ClusterIP service 'payment-service-canary-svc' MUST return 'VERSION_2.0.0_CANARY_NEW_FEATURE'."
echo -e "4. Ensure Canary Ingress successfully shifts 20% of traffic to v2.0.0 without errors."
echo -e ""
echo -e "${YELLOW}DIAGNOSTIC COMMANDS TO GET STARTED:${NC}"
echo -e "  kubectl get pods,svc,endpoints -n ${NAMESPACE} --show-labels"
echo -e "  kubectl describe svc payment-service-canary-svc -n ${NAMESPACE}"
echo -e "  kubectl run test-curl --rm -it --image=curlimages/curl -n ${NAMESPACE} -- http://payment-service-canary-svc"
echo -e "==============================================================================\n"

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (KEEP COMMENTED OUT FOR THE STUDENT)
# ==============================================================================
#
# STEP 1: Inspect the broken Service configuration and Endpoints
# ------------------------------------------------------------------------------
# Run:
#   kubectl describe svc payment-service-canary-svc -n cnpe-canary-lab
#
# Output Analysis:
#   Selector:  app=payment-service,track=stable  <-- WRONG: Matching v1 stable pods!
#   Port:      http  80/TCP
#   TargetPort: 8081/TCP                        <-- WRONG: Container listens on 8080!
#
# STEP 2: Inspect Pod Labels and Container Ports
# ------------------------------------------------------------------------------
# Run:
#   kubectl get pods -n cnpe-canary-lab --show-labels
#   kubectl get pod -l track=canary -n cnpe-canary-lab -o jsonpath='{.items[*].spec.containers[*].ports}'
#
# Notice that Canary pods have label `track=canary` and containerPort `8080`.
#
# STEP 3: Patch or Re-apply the Fixed Canary Service Manifest
# ------------------------------------------------------------------------------
# Apply the corrected Service definition:
#
# cat << 'EOF' | kubectl apply -n cnpe-canary-lab -f -
# apiVersion: v1
# kind: Service
# metadata:
#   name: payment-service-canary-svc
#   labels:
#     app: payment-service
#     service: canary
# spec:
#   type: ClusterIP
#   ports:
#   - port: 80
#     targetPort: 8080
#     name: http
#     protocol: TCP
#   selector:
#     app: payment-service
#     track: canary
# EOF
#
# STEP 4: Validate the Fix
# ------------------------------------------------------------------------------
# Check endpoints alignment:
#   kubectl get endpoints payment-service-canary-svc -n cnpe-canary-lab
#
# Test endpoint response directly using a transient curl pod:
#   kubectl run curl-test --rm -i --tty --image=curlimages/curl -n cnpe-canary-lab -- http://payment-service-canary-svc
#
# Expected output:
#   VERSION_2.0.0_CANARY_NEW_FEATURE
#
# Clean up environment after completing the lab:
#   kubectl delete namespace cnpe-canary-lab
# ==============================================================================