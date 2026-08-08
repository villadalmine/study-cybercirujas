#!/usr/bin/env bash
# ==============================================================================
# CNCF CNPE (Certified Cloud Native Platform Engineer) Lab Exercise
# Topic 3.5: Integrating Security Scanning and Compliance Checks into Deployment Pipelines
# Exam Weight: 3
# 
# Description:
# This script sets up a simulated production CI/CD deployment pipeline security gate
# using Trivy vulnerability scanning, Kyverno policy validation, and Cosign image 
# verification. The script deliberately breaks the pipeline configuration to simulate
# a production failure during security compliance enforcement.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LAB_DIR="/tmp/cnpe-lab-3.5"

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BLUE}       CNPE Topic 3.5: Security Scanning & Compliance Pipeline Lab            ${NC}"
echo -e "${BLUE}==============================================================================${NC}"
echo -e "Initializing lab workspace in ${LAB_DIR}..."

# Setup Lab Directory
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}"/{manifests,policies,scripts,logs}
cd "${LAB_DIR}"

# 1. Create Target Deployment Manifest
cat << 'EOF' > manifests/production-api.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: production
  labels:
    app: payment-api
    tier: backend
    compliance.org/pci-dss: "true"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-api
  template:
    metadata:
      labels:
        app: payment-api
        tier: backend
      annotations:
        cosign.sigstore.dev/verified: "true"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: api-server
        image: nginx:1.25.3-alpine
        ports:
        - containerPort: 8080
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
EOF

# 2. Create OPA / Rego Compliance Policy
cat << 'EOF' > policies/compliance.rego
package main

# Rule 1: Must define PCI-DSS compliance label
deny[msg] {
    input.kind == "Deployment"
    not input.metadata.labels["compliance.org/pci-dss"]
    msg := "COMPLIANCE ERROR: Deployment missing required label 'compliance.org/pci-dss'"
}

# Rule 2: Enforce Pod Security Standard - Restricted Level
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.securityContext.readOnlyRootFilesystem == true
    msg := sprintf("SECURITY ERROR: Container '%s' must have readOnlyRootFilesystem set to true", [container.name])
}

# Rule 3: Image Vulnerability Gate Annotation Check
deny[msg] {
    input.kind == "Deployment"
    not input.spec.template.metadata.annotations["security.org/scan-status"] == "PASSED"
    msg := sprintf("SECURITY ERROR: Deployment '%s' missing required annotation 'security.org/scan-status: PASSED'", [input.metadata.name])
}
EOF

# 3. Create Kyverno Policy Manifest
cat << 'EOF' > policies/kyverno-restrict-tags.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-and-untrusted
spec:
  validationFailureAction: Enforce
  background: false
  rules:
  - name: validate-image-source
    match:
      any:
      - resources:
          kinds:
          - Deployment
    validate:
      message: "Security Policy Violation: Images must use specific tags and come from trusted registry (internal-ecr.company.internal)"
      pattern:
        spec:
          template:
            spec:
              containers:
              - image: "internal-ecr.company.internal/*:v*"
EOF

# 4. Create CI/CD Security Pipeline Execution Script
cat << 'EOF' > scripts/run-pipeline.sh
#!/usr/bin/env bash
set -eo pipefail

MANIFEST="../manifests/production-api.yaml"
POLICY="../policies/compliance.rego"
LOG_FILE="../logs/pipeline.log"

echo "=== STAGE 1: Static Manifest Compliance Audit (OPA/Conftest) ===" | tee -a "$LOG_FILE"

# Simulating OPA Conftest evaluation
if command -v opa &> /dev/null; then
    opa eval --data "$POLICY" --input "$MANIFEST" "data.main.deny" | tee -a "$LOG_FILE"
else
    echo "[MOCK OPA] Evaluating $MANIFEST against $POLICY..." | tee -a "$LOG_FILE"
    # Simple simulated policy check
    if ! grep -q "compliance.org/pci-dss" "$MANIFEST"; then
        echo "FAIL: Missing compliance label" | tee -a "$LOG_FILE"
        exit 1
    fi
fi

echo "=== STAGE 2: Image Vulnerability Scanning (Trivy Gate) ===" | tee -a "$LOG_FILE"
# Extract image from manifest
IMAGE=$(grep -E '^\s*image:' "$MANIFEST" | awk '{print $2}')
echo "Target Image: $IMAGE" | tee -a "$LOG_FILE"

# Vulnerability scan threshold check
CRITICAL_SEVERITY_THRESHOLD=0
HIGH_SEVERITY_THRESHOLD=5

# Simulating vulnerability scan result analysis
MOCK_CRITICAL_COUNT=0
MOCK_HIGH_COUNT=2

echo "Scan Results: CRITICAL=$MOCK_CRITICAL_COUNT (Threshold=$CRITICAL_SEVERITY_THRESHOLD), HIGH=$MOCK_HIGH_COUNT (Threshold=$HIGH_SEVERITY_THRESHOLD)" | tee -a "$LOG_FILE"

if [ "$MOCK_CRITICAL_COUNT" -gt "$CRITICAL_SEVERITY_THRESHOLD" ] || [ "$MOCK_HIGH_COUNT" -gt "$HIGH_SEVERITY_THRESHOLD" ]; then
    echo "SECURITY GATE FAILED: Vulnerability threshold exceeded!" | tee -a "$LOG_FILE"
    exit 1
fi

echo "=== STAGE 3: Image Signature & Compliance Provenance Validation ===" | tee -a "$LOG_FILE"

# BROKEN LOGIC INTRODUCED HERE:
# The pipeline attempts to verify Cosign signature via annotation on container instead of pod template metadata,
# AND validates against an invalid Rego query path that evaluates 'security.org/scan-status' key under wrong spec hierarchy.

ANNOTATION_CHECK=$(grep -q "security.org/scan-status" "$MANIFEST" && echo "FOUND" || echo "MISSING")

if [ "$ANNOTATION_CHECK" == "MISSING" ]; then
    echo -e "\033[0;31m[FATAL] Pipeline failed at Stage 3: Deployment manifest is missing security scan provenance metadata 'security.org/scan-status: PASSED'.\033[0m" | tee -a "$LOG_FILE"
    echo -e "\033[0;31m[FATAL] Conftest / OPA Policy Evaluation return code: 1\033[0m" | tee -a "$LOG_FILE"
    exit 1
fi

echo "=== PIPELINE SUCCESS: Deployment manifest passed all security gates ===" | tee -a "$LOG_FILE"
EOF

chmod +x scripts/run-pipeline.sh

# Injecting the Breakage
echo -e "${YELLOW}[!] Injecting break condition into the security scanning pipeline...${NC}"
# The deployment is missing the required annotation for Stage 3 compliance rule,
# and the registry image tag breaks standard enterprise registry policy.

cat << 'EOF' > ${LAB_DIR}/INSTRUCTIONS.txt
==============================================================================
                      CNPE LAB SCENARIO & BREAK DIAGNOSIS
==============================================================================

PROBLEM STATEMENT:
You are the Lead Platform Security Engineer. The CI/CD release pipeline for 
the 'payment-api' service is failing at the automated Security Scanning & 
Compliance Gate stage.

SYMPTOMS:
- Executing `./scripts/run-pipeline.sh` fails at Stage 3 with error:
  "[FATAL] Pipeline failed at Stage 3: Deployment manifest is missing security scan 
   provenance metadata 'security.org/scan-status: PASSED'."
- OPA compliance rules in `policies/compliance.rego` reject the manifest.
- The image source violates enterprise Kyverno security policy standards in `policies/kyverno-restrict-tags.yaml`.

YOUR OBJECTIVES:
1. Diagnose why `manifests/production-api.yaml` fails the OPA compliance gate in `policies/compliance.rego`.
2. Update `manifests/production-api.yaml` to include the exact required security provenance 
   annotation in the correct spec location:
   `security.org/scan-status: "PASSED"`
3. Update the container image in `manifests/production-api.yaml` to comply with the enterprise 
   registry policy in `policies/kyverno-restrict-tags.yaml` (Must use `internal-ecr.company.internal/payment-api:v1.25.3`).
4. Re-run `./scripts/run-pipeline.sh` and ensure all security stages pass cleanly with return code 0.

VERIFICATION COMMAND:
cd /tmp/cnpe-lab-3.5 && ./scripts/run-pipeline.sh

==============================================================================
EOF

echo -e "${GREEN}[+] Lab environment prepared successfully!${NC}"
echo -e "${YELLOW}Read the instructions in ${LAB_DIR}/INSTRUCTIONS.txt to start debugging.${NC}"
echo -e "Run the pipeline script to observe the failure:"
echo -e "  cd ${LAB_DIR} && ./scripts/run-pipeline.sh"

# ==============================================================================
# SOLUTION (STEP-BY-STEP) - DO NOT UNCOMMENT UNTIL YOU HAVE TRIED TO SOLVE IT!
# ==============================================================================
#
# STEP 1: Understand the root causes of the pipeline failure.
# 
# Cause A: OPA / Rego Rule 3 in `policies/compliance.rego` enforces that:
# `input.spec.template.metadata.annotations["security.org/scan-status"] == "PASSED"`
# The manifest `manifests/production-api.yaml` is missing this annotation under 
# `spec.template.metadata.annotations`.
#
# Cause B: Kyverno policy `policies/kyverno-restrict-tags.yaml` enforces image patterns:
# `internal-ecr.company.internal/*:v*`
# The current image is `nginx:1.25.3-alpine`, which violates internal security governance.
#
# STEP 2: Edit `manifests/production-api.yaml` to fix the compliance issues.
#
# Open `manifests/production-api.yaml` and update the template annotations & image:
#
# --- manifests/production-api.yaml ---
# ...
#   template:
#     metadata:
#       labels:
#         app: payment-api
#         tier: backend
#       annotations:
#         cosign.sigstore.dev/verified: "true"
#         security.org/scan-status: "PASSED"    <-- ADD THIS ANNOTATION
#     spec:
#       securityContext:
#         runAsNonRoot: true
# ...
#       containers:
#       - name: api-server
#         image: internal-ecr.company.internal/payment-api:v1.25.3  <-- UPDATE IMAGE TO COMPLY WITH KYVERNO
#
# STEP 3: Validate the fix by executing the pipeline script:
#
# cd /tmp/cnpe-lab-3.5
# ./scripts/run-pipeline.sh
#
# Expected Output:
# === STAGE 1: Static Manifest Compliance Audit (OPA/Conftest) ===
# ...
# === STAGE 2: Image Vulnerability Scanning (Trivy Gate) ===
# ...
# === STAGE 3: Image Signature & Compliance Provenance Validation ===
# === PIPELINE SUCCESS: Deployment manifest passed all security gates ===
# Exit code: 0
# ==============================================================================