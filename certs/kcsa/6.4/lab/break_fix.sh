#!/usr/bin/env bash
# ==============================================================================
# KCSA Exam Preparation - Topic 6.4: Automation and Tooling (Weight: 2.5%)
# Break & Fix Scenario: Broken Automated Security Admission Webhook
#
# Official Reference Documentation:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Dynamic Admission Control: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
# - Kubernetes Admission Webhook Security: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#validatingadmissionwebhook
# ==============================================================================

set -euo pipefail

COLOR_RESET="\033[0m"
COLOR_RED="\033[1;31m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[1;36m"

echo -e "${COLOR_CYAN}[+] Initializing KCSA Lab 6.4: Automation and Tooling...${COLOR_RESET}"

# 1. Verification of cluster access
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${COLOR_RED}[!] Error: kubectl cannot reach a working Kubernetes cluster.${COLOR_RESET}"
    echo "Please run this script inside a disposable Kubernetes environment (kind/minikube/k3s)."
    exit 1
fi

# 2. Setup Lab Namespaces
echo -e "${COLOR_CYAN}[+] Creating lab namespaces: 'sec-automation' and 'prod-workloads'...${COLOR_RESET}"
kubectl create namespace sec-automation --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace prod-workloads --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace prod-workloads security-scan=enabled --overwrite

# 3. Deploy Mock Security Automation Tooling (Policy Validation Webhook Server)
echo -e "${COLOR_CYAN}[+] Deploying automated security enforcement webhook service...${COLOR_RESET}"

# Generate self-signed CA and server certificates for webhook TLS
TMPDIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${TMPDIR}/ca.key" -out "${TMPDIR}/ca.crt" -days 365 -subj "/CN=Admission CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "${TMPDIR}/server.key" -out "${TMPDIR}/server.csr" -subj "/CN=sec-validator-svc.sec-automation.svc" 2>/dev/null
openssl x509 -req -in "${TMPDIR}/server.csr" -CA "${TMPDIR}/ca.crt" -CAkey "${TMPDIR}/ca.key" -CAcreateserial -out "${TMPDIR}/server.crt" -days 365 2>/dev/null

CABUNDLE_BASE64=$(base64 -w0 < "${TMPDIR}/ca.crt")

# Create Secret with TLS Certs
kubectl create secret tls sec-validator-tls \
    --cert="${TMPDIR}/server.crt" \
    --key="${TMPDIR}/server.key" \
    -n sec-automation \
    --dry-run=client -o yaml | kubectl apply -f -

rm -rf "${TMPDIR}"

# Deploy the Webhook Deployment & Service
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sec-validator
  namespace: sec-automation
  labels:
    app.kubernetes.io/name: sec-validator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sec-validator
  template:
    metadata:
      labels:
        app: sec-validator
    spec:
      containers:
      - name: webhook
        image: registry.k8s.io/e2e-test-images/agnhost:2.40
        args:
        - test-webserver
        ports:
        - containerPort: 8443
---
apiVersion: v1
kind: Service
metadata:
  name: sec-validator-svc
  namespace: sec-automation
spec:
  ports:
  - port: 443
    targetPort: 8443
  selector:
    app: sec-validator
EOF

# 4. Inject controlled failure into Automation Tooling (ValidatingWebhookConfiguration)
echo -e "${COLOR_YELLOW}[!] Injecting failure into automated security policy engine...${COLOR_RESET}"

# INTENTIONAL BUG 1: Service port mismatched (pointing to 9443 instead of 443)
# INTENTIONAL BUG 2: FailurePolicy set to Fail blocking all workloads when automation fails
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: automated-security-enforcer
webhooks:
  - name: validate.security.automation.internal
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        name: sec-validator-svc
        namespace: sec-automation
        path: "/always-allow"
        port: 9443
      caBundle: "${CABUNDLE_BASE64}"
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 3
    failurePolicy: Fail
    namespaceSelector:
      matchLabels:
        security-scan: enabled
EOF

echo -e "${COLOR_GREEN}[+] Lab setup complete! The automated security tooling is now BROKEN.${COLOR_RESET}"
echo ""
echo "================================================================================"
echo -e "${COLOR_RED}LAB SCENARIO: BROKEN AUTOMATED ADMISSION POLICY TOOLING${COLOR_RESET}"
echo "================================================================================"
echo -e "${COLOR_YELLOW}SYMPTOM:${COLOR_RESET}"
echo "Your organization enforces automated security compliance checks via a"
echo "ValidatingWebhookConfiguration on namespaces labeled 'security-scan=enabled'."
echo "Engineers report that any deployment to the 'prod-workloads' namespace fails instantly."
echo ""
echo -e "${COLOR_YELLOW}REPRODUCTION STEPS:${COLOR_RESET}"
echo "Run the following command to observe the error:"
echo "  kubectl run test-app --image=nginx:alpine -n prod-workloads"
echo ""
echo -e "${COLOR_YELLOW}EXPECTED ERROR OUTPUT:${COLOR_RESET}"
echo "  Error from server (InternalError): Internal error occurred: failed calling webhook"
echo "  \"validate.security.automation.internal\": connection refused / call failed"
echo ""
echo -e "${COLOR_YELLOW}YOUR OBJECTIVE:${COLOR_RESET}"
echo "1. Diagnose why the automated security webhook 'automated-security-enforcer' fails."
echo "2. Fix the webhook configuration without disabling security automation."
echo "3. Verify that new Pods can be successfully created in namespace 'prod-workloads'."
echo "================================================================================"
echo ""

# ==============================================================================
# SOLUTION (STEP-BY-STEP GUIDANCE FOR THE STUDENT)
# ==============================================================================
# To reveal the step-by-step solution, read below:
#
# STEP 1: Diagnose the error when launching a test pod
# $ kubectl run test-pod --image=nginx:alpine -n prod-workloads
# Output: Error from server (InternalError): Internal error occurred: failed calling webhook "validate.security.automation.internal"...
#
# STEP 2: Inspect admission webhooks configured in the cluster
# $ kubectl get validatingwebhookconfigurations
# $ kubectl get validatingwebhookconfigurations automated-security-enforcer -o yaml
#
# STEP 3: Inspect the clientConfig section of the ValidatingWebhookConfiguration
# Notice the service target configuration:
# clientConfig:
#   caBundle: ...
#   service:
#     name: sec-validator-svc
#     namespace: sec-automation
#     path: /always-allow
#     port: 9443
#
# STEP 4: Inspect the backing Service in namespace 'sec-automation'
# $ kubectl get svc sec-validator-svc -n sec-automation
# Output shows the Service listens on port 443 (forwarding to targetPort 8443).
# Port 9443 configured in the webhook clientConfig does NOT match port 443 on the Service.
#
# STEP 5: Fix the ValidatingWebhookConfiguration
# Edit the resource:
# $ kubectl edit validatingwebhookconfiguration automated-security-enforcer
#
# Change:
#   port: 9443
# To:
#   port: 443
#
# Save and exit.
#
# STEP 6: Verify resolution
# $ kubectl run test-pod --image=nginx:alpine -n prod-workloads
# Output: pod/test-pod created
#
# STEP 7: Cleanup lab resources (Optional)
# $ kubectl delete namespace sec-automation prod-workloads
# $ kubectl delete validatingwebhookconfiguration automated-security-enforcer
# ==============================================================================