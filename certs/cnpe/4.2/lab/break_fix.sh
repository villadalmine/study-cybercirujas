#!/usr/bin/env bash
# ==============================================================================
# CNPE Certification Lab: Topic 4.2 - Building & Configuring CI/CD Pipelines
# Integrated with Kubernetes
# 
# Scenario: Break & Fix - Production CI/CD Pipeline RBAC & Deployment Rollout Failure
# Target Environment: Disposable Kubernetes Lab Cluster (minikube/kind/k3s)
# Reference: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# ==============================================================================

set -euo pipefail

# Color Codes for Output
RED='\030[0;31m'
GREEN='\030[0;32m'
YELLOW='\030[1;33m'
BLUE='\030[0;34m'
NC='\030[0m' # No Color

LAB_NS_CICD="cicd-runner-system"
LAB_NS_PROD="production-workloads"
SA_NAME="gitlab-pipeline-runner"
DEPLOY_NAME="order-processing-api"

echo -e "${BLUE}[+] Checking cluster connectivity and prerequisites...${NC}"
if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}[ERROR] Cannot connect to Kubernetes cluster. Please ensure kubectl is configured.${NC}"
    exit 1
fi

echo -e "${BLUE}[+] Initializing lab environment...${NC}"
kubectl create namespace "${LAB_NS_CICD}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${LAB_NS_PROD}" --dry-run=client -o yaml | kubectl apply -f -

# 1. Create Target Production Deployment
echo -e "${BLUE}[+] Deploying target workload '${DEPLOY_NAME}' in namespace '${LAB_NS_PROD}'...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${LAB_NS_PROD}
  labels:
    app.kubernetes.io/name: order-processing
    app.kubernetes.io/managed-by: cicd-pipeline
spec:
  replicas: 2
  selector:
    matchLabels:
      app: order-processing
  template:
    metadata:
      labels:
        app: order-processing
    spec:
      containers:
      - name: api
        image: nginx:1.24.0
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
          requests:
            cpu: "50m"
            memory: "64Mi"
EOF

# 2. Create Pipeline ServiceAccount
echo -e "${BLUE}[+] Creating CI/CD ServiceAccount '${SA_NAME}' in '${LAB_NS_CICD}'...${NC}"
kubectl create serviceaccount "${SA_NAME}" -n "${LAB_NS_CICD}" --dry-run=client -o yaml | kubectl apply -f -

# 3. Inject Fault: Broken RBAC Role & Scoped RoleBinding
# The role deliberately omits 'patch' and 'update' verbs on deployments, and omits apps group resource scope.
echo -e "${YELLOW}[!] Injecting CI/CD Pipeline configuration failure (Broken RBAC & Permissions)...${NC}"

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pipeline-deployer-role
  namespace: ${LAB_NS_PROD}
spec:
  rules:
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"] # FAULT: Missing 'update', 'patch'
EOF

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pipeline-deployer-binding
  namespace: ${LAB_NS_PROD}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${LAB_NS_CICD}
roleRef:
  kind: Role
  name: pipeline-deployer-role
  apiGroup: rbac.authorization.k8s.io
EOF

# 4. Trigger Simulated CI/CD Pipeline Execution & Capture Failure
echo -e "${YELLOW}[!] Executing automated deployment pipeline simulation...${NC}"
PIPELINE_CMD="kubectl set image deployment/${DEPLOY_NAME} api=nginx:1.25.4 -n ${LAB_NS_PROD} --as=system:serviceaccount:${LAB_NS_CICD}:${SA_NAME}"

echo -e "\n${RED}==============================================================================${NC}"
echo -e "${RED}                      LAB BROKEN - CI/CD FAILURE DETECTED                    ${NC}"
echo -e "${RED}==============================================================================${NC}"
echo -e "${YELLOW}SYMPTOMS OBSERVED IN CI/CD PIPELINE LOGS:${NC}"
echo -e "Running deployment command as pipeline agent:\n$ ${PIPELINE_CMD}"
echo -e "\n${RED}--- PIPELINE STDERR OUTPUT ---${NC}"
eval "${PIPELINE_CMD}" 2>&1 || true
echo -e "${RED}------------------------------${NC}\n"

echo -e "${BLUE}CHALLENGE OBJECTIVE:${NC}"
echo -e "1. Identify why the CI/CD pipeline agent '${SA_NAME}' in namespace '${LAB_NS_CICD}'"
echo -e "   fails to trigger automated continuous deployment updates in namespace '${LAB_NS_PROD}'."
echo -e "2. Reconfigure the Kubernetes RBAC resources (Role / RoleBinding or ClusterRole / ClusterRoleBinding)"
echo -e "   following the principle of least privilege, allowing the pipeline to:"
echo -e "   - Inspect deployment status and rollout progress ('get', 'list', 'watch')."
echo -e "   - Update container images and patch deployment specs ('update', 'patch')."
echo -e "   - Restart deployments via annotation patches."
echo -e "3. Verify your fix by successfully running the simulated pipeline command:"
echo -e "   ${GREEN}kubectl set image deployment/${DEPLOY_NAME} api=nginx:1.25.4 -n ${LAB_NS_PROD} --as=system:serviceaccount:${LAB_NS_CICD}:${SA_NAME}${NC}"
echo -e "   and ensuring the deployment image updates cleanly without authentication or authorization errors."
echo -e "==============================================================================\n"

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION (UNCOMMENT AND EXECUTE TO SOLVE / VERIFY)
# ==============================================================================
#
# 1. DIAGNOSIS PHASE:
#    Inspect current authorization using kubectl auth can-i:
#    $ kubectl auth can-i patch deployment/${DEPLOY_NAME} \
#        -n production-workloads \
#        --as=system:serviceaccount:cicd-runner-system:gitlab-pipeline-runner
#    Output: no
#
#    Inspect existing Role and RoleBinding in production-workloads namespace:
#    $ kubectl get role pipeline-deployer-role -n production-workloads -o yaml
#    $ kubectl get rolebinding pipeline-deployer-binding -n production-workloads -o yaml
#
#    Root Cause Analysis:
#    The Role 'pipeline-deployer-role' under namespace 'production-workloads' only grants
#    verbs ["get", "list", "watch"] on "apps/deployments". To allow CI/CD pipeline updates
#    (such as image tag modification or rollout triggers), the ServiceAccount requires
#    verbs ["update", "patch"] on "apps/deployments" and "apps/deployments/scale" or status.
#
# 2. REMEDIATION PHASE:
#    Apply a corrected Role definition containing proper API groups, resources, and verbs:
#
# cat <<EOF | kubectl apply -f -
# apiVersion: rbac.authorization.k8s.io/v1
# kind: Role
# metadata:
#   name: pipeline-deployer-role
#   namespace: production-workloads
# spec:
#   rules:
#   - apiGroups: ["apps"]
#     resources: ["deployments", "deployments/rollback", "deployments/scale"]
#     verbs: ["get", "list", "watch", "update", "patch"]
#   - apiGroups: [""]
#     resources: ["pods", "services", "configmaps"]
#     verbs: ["get", "list", "watch"]
# EOF
#
# 3. VERIFICATION PHASE:
#    Test permission with 'kubectl auth can-i':
#    $ kubectl auth can-i patch deployment/order-processing-api \
#        -n production-workloads \
#        --as=system:serviceaccount:cicd-runner-system:gitlab-pipeline-runner
#    Output: yes
#
#    Re-run the automated pipeline deployment step:
#    $ kubectl set image deployment/order-processing-api api=nginx:1.25.4 \
#        -n production-workloads \
#        --as=system:serviceaccount:cicd-runner-system:gitlab-pipeline-runner
#    Output: deployment.apps/order-processing-api image updated
#
#    Verify rollout status:
#    $ kubectl rollout status deployment/order-processing-api -n production-workloads
#
# ==============================================================================