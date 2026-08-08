#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA Certification Lab - Topic 3.3: Authentication
# Break & Fix Scenario: X.509 Client Certificate & Kubeconfig Misconfiguration
# 
# Official References:
# - KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - K8s Authentication: https://kubernetes.io/docs/reference/access-authn-authz/authentication/
# - K8s CSR Management: https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
# ==============================================================================

set -euo pipefail

# Visual Formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LAB_NS="kcsa-auth-lab"
TARGET_USER="jane-dev"
KUBECONFIG_PATH="/tmp/kcsa-jane.kubeconfig"
CSR_NAME="jane-dev-csr"

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  KCSA Topic 3.3: Authentication - Break & Fix Laboratory Setup       ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# Step 1: Pre-flight Checks
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERROR] 'kubectl' command not found. Please run this in a Kubernetes lab node.${NC}"
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    echo -e "${RED}[ERROR] 'openssl' command not found. Please install openssl.${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}[ERROR] Unable to connect to Kubernetes cluster via kubectl.${NC}"
    exit 1
fi

# Step 2: Cleanup Previous Runs
echo -e "${YELLOW}[+] Cleaning up any existing lab artifacts...${NC}"
kubectl delete namespace "${LAB_NS}" --ignore-not-found=true &> /dev/null || true
kubectl delete csr "${CSR_NAME}" --ignore-not-found=true &> /dev/null || true
kubectl delete clusterrolebinding kcsa-jane-binding --ignore-not-found=true &> /dev/null || true
rm -f /tmp/jane.* "${KUBECONFIG_PATH}" /tmp/rogue-ca.*

# Step 3: Setup Lab Environment
echo -e "${YELLOW}[+] Provisioning target namespace and workloads...${NC}"
kubectl create namespace "${LAB_NS}"

# Create dummy pod for testing access later
kubectl run secure-app --image=nginx:alpine -n "${LAB_NS}"

# Step 4: Generate Valid X.509 Private Key and CSR
echo -e "${YELLOW}[+] Generating PKI assets for user '${TARGET_USER}'...${NC}"
openssl genrsa -out /tmp/jane.key 2048 &> /dev/null
openssl req -new -key /tmp/jane.key -out /tmp/jane.csr -subj "/CN=${TARGET_USER}/O=developers" &> /dev/null

CSR_BASE64=$(base64 -w 0 < /tmp/jane.csr)

# Step 5: Submit K8s CertificateSigningRequest API Object
cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF

# Step 6: Approve CSR & Extract Valid Signed Certificate
echo -e "${YELLOW}[+] Approving CSR via Kubernetes API server...${NC}"
kubectl certificate approve "${CSR_NAME}" &> /dev/null
kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}' | base64 -d > /tmp/jane.crt

# Step 7: Create RoleBinding for Authorization
cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jane-pod-reader
  namespace: ${LAB_NS}
subjects:
- kind: User
  name: ${TARGET_USER}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
EOF

# Step 8: INTENTIONAL BREAKAGE (Authentication Mechanics Failure)
# Break 1: Generate a fake/rogue CA authority file to break TLS trust chain in Kubeconfig
openssl req -x509 -newkey rsa:2048 -keyout /tmp/rogue-ca.key -out /tmp/rogue-ca.crt -days 1 -nodes -subj "/CN=Fake-K8s-CA" &> /dev/null

# Extract Server Endpoint
CLUSTER_SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')

# Construct BROKEN Kubeconfig:
# - Uses rogue CA certificate (TLS Handshake failure: unknown authority)
# - Embeds broken/mismatched client certificate data
echo -e "${YELLOW}[+] Injecting deliberate authentication faults into ${KUBECONFIG_PATH}...${NC}"
kubectl config --kubeconfig="${KUBECONFIG_PATH}" set-cluster production-cluster \
  --server="${CLUSTER_SERVER}" \
  --certificate-authority=/tmp/rogue-ca.crt \
  --embed-certs=true &> /dev/null

kubectl config --kubeconfig="${KUBECONFIG_PATH}" set-credentials "${TARGET_USER}" \
  --client-certificate=/tmp/jane.crt \
  --client-key=/tmp/jane.key \
  --embed-certs=true &> /dev/null

kubectl config --kubeconfig="${KUBECONFIG_PATH}" set-context production-context \
  --cluster=production-cluster \
  --namespace="${LAB_NS}" \
  --user="${TARGET_USER}" &> /dev/null

kubectl config --kubeconfig="${KUBECONFIG_PATH}" use-context production-context &> /dev/null

# Break 2: Corrupt client-certificate-data inside kubeconfig with invalid bytes
sed -i 's/client-certificate-data: .*/client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==/' "${KUBECONFIG_PATH}"

echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}  [SUCCESS] LAB ENVIRONMENT BROKEN AND READY FOR DIAGNOSIS            ${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e ""
echo -e "${YELLOW}DESCRIPTION OF THE ISSUE:${NC}"
echo -e "Developer '${TARGET_USER}' cannot access pods in namespace '${LAB_NS}' using their dedicated kubeconfig file."
echo -e ""
echo -e "${YELLOW}SYMPTOMS TO OBSERVE:${NC}"
echo -e "Run the following command to test authentication:"
echo -e "  ${RED}kubectl --kubeconfig=${KUBECONFIG_PATH} get pods${NC}"
echo -e ""
echo -e "${YELLOW}EXPECTED ERROR OUTPUT:${NC}"
echo -e "  - TLS/x509 Certificate Authority distrust errors, OR"
echo -e "  - 401 Unauthorized / Invalid Client Certificate errors."
echo -e ""
echo -e "${YELLOW}YOUR OBJECTIVE:${NC}"
echo -e "Diagnose the authentication failure mechanisms and fix ${KUBECONFIG_PATH} so that user '${TARGET_USER}'"
echo -e "can successfully authenticate against the API server and view pods in '${LAB_NS}'."
echo -e ""
echo -e "Refer to official documentation:"
echo -e "  https://kubernetes.io/docs/reference/access-authn-authz/authentication/"
echo -e "  https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/"
echo -e "======================================================================"

# ==============================================================================
# STEP-BY-STEP SOLUTION & DIAGNOSTIC GUIDE (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# ROOT CAUSE ANALYSIS:
# 1. Kube-apiserver verifies client certificates using its trusted '--client-ca-file'.
# 2. The generated kubeconfig (/tmp/kcsa-jane.kubeconfig) contains two critical flaws:
#    a) 'certificate-authority-data' points to a fake/untrusted CA (/tmp/rogue-ca.crt), causing TLS failure.
#    b) 'client-certificate-data' was corrupted with invalid Base64 data, causing HTTP 401 Unauthorized.
#
# STEP-BY-STEP FIX COMMANDS:
#
# 1. Inspect the broken kubeconfig file:
#    $ kubectl --kubeconfig=/tmp/kcsa-jane.kubeconfig config view --raw
#
# 2. Extract the actual Cluster CA certificate from the working admin config or API server:
#    $ ACTUAL_CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
#
# 3. Retrieve the valid signed X.509 certificate for jane-dev from the K8s CSR object:
#    $ kubectl get csr jane-dev-csr -o jsonpath='{.status.certificate}' > /tmp/jane_valid_base64.crt
#    $ base64 -d /tmp/jane_valid_base64.crt > /tmp/jane_fixed.crt
#
# 4. Re-configure the cluster CA entry in target Kubeconfig:
#    $ kubectl config --kubeconfig=/tmp/kcsa-jane.kubeconfig set-cluster production-cluster \
#        --server=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}') \
#        --certificate-authority= <(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d) \
#        --embed-certs=true
#
# 5. Re-configure user client credentials in target Kubeconfig:
#    $ kubectl config --kubeconfig=/tmp/kcsa-jane.kubeconfig set-credentials jane-dev \
#        --client-certificate=/tmp/jane_fixed.crt \
#        --client-key=/tmp/jane.key \
#        --embed-certs=true
#
# 6. Verify Authentication and Authorization:
#    $ kubectl --kubeconfig=/tmp/kcsa-jane.kubeconfig get pods -n kcsa-auth-lab
#    Expected Output:
#    NAME         READY   STATUS    RESTARTS   AGE
#    secure-app   1/1     Running   0          2m
#
# 7. Verification using self-subject-rules-review:
#    $ kubectl --kubeconfig=/tmp/kcsa-jane.kubeconfig auth whoami
#    $ kubectl --kubeconfig=/tmp/kcsa-jane.kubeconfig auth can-i list pods -n kcsa-auth-lab
#    Expected Output: yes
# ==============================================================================