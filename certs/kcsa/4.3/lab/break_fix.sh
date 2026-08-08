#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate)
# Topic 4.3: Denial of Service (DoS) Mitigation & Resource Protection
# Script Type: Break & Fix Production-Grade Hands-on Laboratory
# Author: Senior SRE & Principal Platform Security Architect
# ==============================================================================
#
# INTERNAL MECHANICS & ARCHITECTURE OVERVIEW:
# ------------------------------------------------------------------------------
# Kubernetes clusters are vulnerable to Denial of Service (DoS) attacks at two 
# primary operational planes:
#
# 1. Data Plane (Node/Pod Resource Exhaustion):
#    - Without a `LimitRange`, pods without explicit `resources.requests` and 
#      `resources.limits` can consume all CPU, Memory, and Ephemeral Storage on 
#      a Node. This triggers Linux Cgroups OOM-Killer, evicts critical workloads, 
#      and induces Node `MemoryPressure` or `DiskPressure` conditions.
#    - Without a `ResourceQuota`, a single tenant or compromised deployment can 
#      saturate namespace-wide compute limits, object counts, or storage quotas, 
#      denying service to legitimate applications.
#    - Without PID limiting (`podPidsLimit`), a fork-bomb inside a container can 
#      exhaust host OS process IDs, crashing the underlying Node kernel.
#
# 2. Control Plane (kube-apiserver Starvation & APF Misconfigurations):
#    - The Kubernetes API Server utilizes API Priority and Fairness (APF) to 
#      categorize incoming requests into FlowSchemas and queue them in 
#      PriorityLevelConfigurations.
#    - Misconfigured APF rules (or missing rate limits) allow unauthenticated 
#      or rogue workloads to flood the API server, triggering HTTP 429 
#      (Too Many Requests) or causing ETCD/kube-apiserver latency spikes.
#
# TRADE-OFFS & SECURITY BEST PRACTICES:
# ------------------------------------------------------------------------------
# - Strict Limits vs. Throttling: Over-constraining CPU limits leads to CFS 
#   throttling and latency spikes; under-constraining Memory leads to OOMKills.
# - BestEffort vs. Guaranteed QoS: Pods without resource requests are assigned 
#   `BestEffort` QoS class and are the first candidates for eviction during 
#   Node resource starvation.
# - APF Concurrency: Overly restrictive `PriorityLevelConfiguration` limits can 
#   accidentally drop critical health checks (`/healthz`, `/livez`) or operator 
#   reconciliation loops.
#
# OFFICIAL REFERENCES:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
# - Kubernetes Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
# - API Priority and Fairness: https://kubernetes.io/docs/concepts/api-extension/apf/
# ==============================================================================

set -euo pipefail

LAB_NAMESPACE="kcsa-dos-lab"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}====================================================================${NC}"
echo -e "${BLUE}  KCSA 4.3: Denial of Service (DoS) - Break & Fix Environment Setup ${NC}"
echo -e "${BLUE}====================================================================${NC}"

# Step 0: Check Prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERROR] 'kubectl' CLI is required but not installed or not in PATH.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[ERROR] Unable to communicate with Kubernetes cluster. Check KUBECONFIG.${NC}"
    exit 1
fi

echo -e "${YELLOW}[INFO] Cleaning up any previous lab state...${NC}"
kubectl delete namespace "${LAB_NAMESPACE}" --ignore-not-found=true --wait=true &> /dev/null || true

echo -e "${GREEN}[SETUP] Creating target namespace: ${LAB_NAMESPACE}${NC}"
kubectl create namespace "${LAB_NAMESPACE}"

# ------------------------------------------------------------------------------
# BREAK PHASE: Injecting Denial of Service Vulnerabilities & Failures
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[BREAKING] Injecting DoS scenarios into namespace '${LAB_NAMESPACE}'...${NC}"

# 1. Deploy Mission-Critical Application (Payment Service)
echo -e "${GREEN}[SETUP] Deploying critical workload 'payment-gateway'...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway
  namespace: ${LAB_NAMESPACE}
  labels:
    tier: critical
    app: payment-gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-gateway
  template:
    metadata:
      labels:
        app: payment-gateway
    spec:
      containers:
      - name: nginx
        image: registry.k8s.io/e2e-test-images/agnhost:2.43
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
EOF

# 2. Inject Vulnerability #1: Flawed ResourceQuota blocking deployment updates & scaling
# A misconfigured quota is set that allocates 0 requests for unconstrained pods, 
# while total namespace CPU limit is capped too low, preventing payment-gateway pods from operating.
echo -e "${YELLOW}[BREAKING] Applying restrictive/misconfigured ResourceQuota...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: restrictive-dos-quota
  namespace: ${LAB_NAMESPACE}
spec:
  hard:
    requests.cpu: "50m"
    requests.memory: "64Mi"
    limits.cpu: "100m"
    limits.memory: "128Mi"
    pods: "10"
EOF

# 3. Inject Vulnerability #2: Unconstrained Noisy Neighbor Deployment (Data Plane DoS)
# Deploying a rogue workload without LimitRanges or enforcing admission controller rules.
# The rogue deployment requests excessive resources and saturates the environment.
echo -e "${YELLOW}[BREAKING] Deploying rogue noisy-neighbor workload 'crypto-miner-rogue'...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: crypto-miner-rogue
  namespace: ${LAB_NAMESPACE}
  labels:
    tier: rogue
spec:
  replicas: 1
  selector:
    matchLabels:
      app: crypto-miner-rogue
  template:
    metadata:
      labels:
        app: crypto-miner-rogue
    spec:
      containers:
      - name: stress
        image: registry.k8s.io/e2e-test-images/agnhost:2.43
        args: ["stress", "--cpu=2", "--mem-alloc-size=50Mi", "--mem-alloc-sleep=5000"]
EOF

# 4. Trigger Pod Scheduling/Runtime Starvation Failure
echo -e "${YELLOW}[BREAKING] Triggering rolling update on 'payment-gateway' to induce quota failure...${NC}"
kubectl rollout restart deployment/payment-gateway -n "${LAB_NAMESPACE}" &> /dev/null || true

sleep 3

# ------------------------------------------------------------------------------
# INSTRUCTOR BRIEFING & STUDENT INSTRUCTIONS
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}====================================================================${NC}"
echo -e "${BLUE}                    STUDENT LAB INSTRUCTIONS                        ${NC}"
echo -e "${BLUE}====================================================================${NC}"
echo -e "${RED}[ALERT] INCIDENT REPORT: Denial of Service (DoS) in namespace '${LAB_NAMESPACE}'!${NC}"
echo -e "The production payment gateway service is degraded/failing. A noisy neighbor workload"
echo -e "has been introduced, and resource policies are misconfigured."
echo -e ""
echo -e "${YELLOW}SYMPTOMS TO OBSERVE:${NC}"
echo -e " 1. 'payment-gateway' pods are stuck in 'Pending' or failing rollout."
echo -e " 2. Pod status events reveal 'exceeded quota' errors during scheduling/admission."
echo -e " 3. Namespace lacks defense against unconstrained workloads (missing default LimitRange)."
echo -e " 4. Rogue pods ('crypto-miner-rogue') can spawn without CPU/Memory boundaries, leading"
echo -e "    to potential Node resource exhaustion and BestEffort QoS eviction risks."
echo -e ""
echo -e "${YELLOW}STUDENT OBJECTIVES:${NC}"
echo -e " 1. Diagnose why 'payment-gateway' pods cannot schedule using 'kubectl describe' and 'kubectl get events'."
echo -e " 2. Adjust or replace the namespace 'ResourceQuota' ('restrictive-dos-quota') to safely accommodate"
echo -e "    production requirements (minimum: CPU requests 500m, Memory 1Gi, Pods 20)."
echo -e " 3. Implement a default 'LimitRange' named 'default-dos-protection' in namespace '${LAB_NAMESPACE}'"
echo -e "    to prevent unconstrained pods from causing Node-level DoS:"
echo -e "      - Default CPU Limit: 200m | Default CPU Request: 100m"
echo -e "      - Default Memory Limit: 256Mi | Default Memory Request: 128Mi"
echo -e "      - Max CPU: 1000m | Max Memory: 1Gi"
echo -e " 4. Evict/Delete the rogue deployment 'crypto-miner-rogue' or restrict its resource usage."
echo -e " 5. Verify that all 'payment-gateway' pods transition to 'Running' and 'Ready' state."
echo -e ""
echo -e "${GREEN}Useful Diagnostic Commands:${NC}"
echo -e "  kubectl get pods -n ${LAB_NAMESPACE}"
echo -e "  kubectl get resourcequotas -n ${LAB_NAMESPACE}"
echo -e "  kubectl describe deployment payment-gateway -n ${LAB_NAMESPACE}"
echo -e "  kubectl get events -n ${LAB_NAMESPACE} --field-selector type=Warning"
echo -e "${BLUE}====================================================================${NC}\n"

exit 0

# ==============================================================================
#                               STEP-BY-STEP SOLUTION
# ==============================================================================
# Execute the commands below to solve the Denial of Service lab scenario.
# ------------------------------------------------------------------------------
#
# STEP 1: DIAGNOSE THE DOS ISSUE
# Check current pod status in the lab namespace:
#   kubectl get pods -n kcsa-dos-lab
#
# Expected Output:
#   NAME                               READY   STATUS    RESTARTS   AGE
#   crypto-miner-rogue-xxx-yyy         1/1     Running   0          45s
#   payment-gateway-6d77c4447d-abcde   0/1     Pending   0          40s
#
# Inspect deployment replica set events to identify the root cause:
#   kubectl get events -n kcsa-dos-lab --field-selector type=Warning
#
# Expected Output:
#   LAST SEEN   TYPE      REASON        OBJECT                   MESSAGE
#   35s         Warning   FailedCreate  replicaset/payment-...   (combined from similar events): Error creating: pods "payment-gateway-..." is forbidden: exceeded quota: restrictive-dos-quota, requested: limits.cpu=200m,limits.memory=256Mi,requests.cpu=100m,requests.memory=128Mi, used: limits.cpu=0,limits.memory=0,requests.cpu=0,requests.memory=0, limited: limits.cpu=100m,limits.memory=128Mi,requests.cpu=50m,requests.memory=64Mi
#
# ------------------------------------------------------------------------------
# STEP 2: FIX THE RESOURCE QUOTA
# Update the restrictive ResourceQuota so mission-critical workloads can schedule:
#
# cat <<EOF | kubectl apply -f -
# apiVersion: v1
# kind: ResourceQuota
# metadata:
#   name: restrictive-dos-quota
#   namespace: kcsa-dos-lab
# spec:
#   hard:
#     requests.cpu: "1"
#     requests.memory: "1Gi"
#     limits.cpu: "2"
#     limits.memory: "2Gi"
#     pods: "20"
# EOF
#
# ------------------------------------------------------------------------------
# STEP 3: ENFORCE HARDENING VIA LIMITRANGE (PREVENT DATA-PLANE DOS)
# Deploy a LimitRange to force all new pods to have default requests and limits.
# This prevents unconstrained pods from running with BestEffort QoS and causing
# Node-level memory pressure / OOM evictions.
#
# cat <<EOF | kubectl apply -f -
# apiVersion: v1
# kind: LimitRange
# metadata:
#   name: default-dos-protection
#   namespace: kcsa-dos-lab
# spec:
#   limits:
#   - default:
#       cpu: "200m"
#       memory: "256Mi"
#     defaultRequest:
#       cpu: "100m"
#       memory: "128Mi"
#     max:
#       cpu: "1"
#       memory: "1Gi"
#     min:
#       cpu: "50m"
#       memory: "32Mi"
#     type: Container
# EOF
#
# ------------------------------------------------------------------------------
# STEP 4: NEUTRALIZE ROGUE WORKLOAD
# Terminate the unconstrained rogue noisy-neighbor deployment:
#   kubectl delete deployment crypto-miner-rogue -n kcsa-dos-lab
#
# ------------------------------------------------------------------------------
# STEP 5: VERIFY WORKLOAD HEALTH AND QUOTA ENFORCEMENT
# Check pod rollout status:
#   kubectl rollout status deployment/payment-gateway -n kcsa-dos-lab
#
# Expected Output:
#   deployment "payment-gateway" successfully rolled out
#
# Verify namespace ResourceQuota utilization:
#   kubectl describe resourcequota restrictive-dos-quota -n kcsa-dos-lab
#
# Expected Output:
#   Name:            restrictive-dos-quota
#   Namespace:       kcsa-dos-lab
#   Resource         Used   Hard
#   --------         ----   ----
#   limits.cpu       400m   2
#   limits.memory    512Mi  2Gi
#   pods             2      20
#   requests.cpu     200m   1
#   requests.memory  256Mi  1Gi
#
# ------------------------------------------------------------------------------
# ADVANCED DIAGNOSTIC TECHNIQUES FOR PRODUCTION (KCSA EXAM TIPS):
# - API Priority and Fairness (APF) Inspection:
#     kubectl get flowschemas
#     kubectl get prioritylevelconfigurations
#     kubectl get --raw /debug/api_priority_and_fairness/dump_seats
# - Checking Node PID Exhaustion:
#     kubectl get node -o jsonpath='{.items[*].status.conditions[?(@.type=="PIDPressure")]}'
# - Identifying BestEffort (Vulnerable to Eviction) Pods:
#     kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.qosClass}{"\n"}{end}' | grep BestEffort
# ==============================================================================