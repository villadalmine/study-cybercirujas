#!/usr/bin/env bash
# ==============================================================================
# CNCF Certified Cloud Native Platform Engineer (CNPE) Exam Preparation Material
# Topic 3.3: Generating Audit Trails and Enforcing Policy Compliance (SBOM, Compliance Reports, etc.)
# Exam Weight: 3
#
# Official Curriculum Reference:
#   - https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# Official Technical References:
#   - K8s Audit Logging: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
#   - CNCF WG Policy (PolicyReport CRD Spec): https://github.com/kubernetes-sigs/wg-policy-prototypes
#   - Kyverno Image Verification & SBOM: https://kyverno.io/docs/writing-policies/verify-images/
#   - Sigstore Cosign Attestations & In-Toto: https://docs.sigstore.dev/cosign/overview/
# ==============================================================================
#
# LAB SCENARIO:
# In a secure cloud-native production environment, platform engineers must enforce
# image provenance/SBOM attestations and ensure that non-compliant workloads emit
# immutable Kubernetes API audit trails while generating PolicyReport CRs for security observability.
#
# WHAT IS BROKEN:
# 1. The Kubernetes API Server Audit Policy fails to log compliance evaluation events for 'wgpolicyk8s.io'.
# 2. API Server audit logs are not being persisted to disk due to a hostPath path mismatch in kube-apiserver.yaml.
# 3. Kyverno SBOM attestation ClusterPolicy is configured with invalid validation schema syntax and background auditing disabled.
# 4. Policy Reporter RBAC lacks necessary permissions to write PolicyReport custom resources.
#
# EXPECTED SYMPTOMS:
# - No audit entries found in /var/log/kubernetes/audit/audit.log matching 'wgpolicyk8s.io' or 'kyverno.io'.
# - Non-compliant pods without SBOM attestations fail to produce 'PolicyReport' or 'ClusterPolicyReport' CRs.
# - Kyverno webhooks fail silently without generating compliance evaluation status logs.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/cnpe-lab-3.3"
AUDIT_POLICY_PATH="/etc/kubernetes/audit-policy.yaml"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
AUDIT_LOG_DIR="/var/log/kubernetes/audit"

echo "[+] Initializing CNPE Topic 3.3 Break-and-Fix Environment on Disposable VM..."

# Create necessary lab directory paths safely
mkdir -p "${LAB_DIR}"
mkdir -p "${AUDIT_LOG_DIR}"
mkdir -p /etc/kubernetes/manifests

# ------------------------------------------------------------------------------
# STEP 1: Inject Fault 1 & 2 - Flawed Audit Policy Config
# ------------------------------------------------------------------------------
echo "[+] Writing broken AuditPolicy manifest to ${AUDIT_POLICY_PATH}..."
cat << 'EOF' > "${AUDIT_POLICY_PATH}"
apiVersion: audit.k8s.io/v1
kind: AuditPolicy
rules:
  # FAULT 1: Audit level set to 'None' for compliance policy resources, suppressing audit trails
  - level: None
    resources:
      - group: "wgpolicyk8s.io"
        resources: ["policyreports", "clusterpolicyreports"]
  # FAULT 2: Invalid API group specification causing audit rule drop
  - level: RequestResponse
    resources:
      - group: "kyverno.io.invalid-domain"
        resources: ["clusterpolicies"]
  # FAULT 3: Omitting 'ResponseComplete' drops final audit trail stage containing decision results
  - level: Metadata
    omitStages:
      - "RequestReceived"
      - "ResponseStarted"
      - "ResponseComplete"
EOF

# ------------------------------------------------------------------------------
# STEP 2: Inject Fault 3 & 4 - Misconfigured Kyverno SBOM Attestation Policy
# ------------------------------------------------------------------------------
echo "[+] Writing broken ClusterPolicy to ${LAB_DIR}/kyverno-sbom-policy.yaml..."
cat << 'EOF' > "${LAB_DIR}/kyverno-sbom-policy.yaml"
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-sbom-attestation
spec:
  validationFailureAction: Audit
  # FAULT 4: Background scanning disabled; existing workloads won't generate PolicyReport CRs
  background: false
  rules:
    - name: verify-image-sbom
      match:
        any:
        - resources:
            kinds:
              - Pod
      verifyImages:
        - imageReferences:
            - "*"
          attestations:
            - predicateType: https://spdx.dev/Document
              attestors:
                - count: 1
                  entries:
                    - keys:
                        # FAULT 5: Malformed PEM formatting and invalid public key string format
                        publicKeys: "INVALID_INLINE_PUBLIC_KEY_PEM_FORMAT"
EOF

# ------------------------------------------------------------------------------
# STEP 3: Inject Fault 5 & 6 - Broken Policy Reporter RBAC
# ------------------------------------------------------------------------------
echo "[+] Writing flawed RBAC configuration to ${LAB_DIR}/policy-reporter-rbac.yaml..."
cat << 'EOF' > "${LAB_DIR}/policy-reporter-rbac.yaml"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: policy-reporter-role
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  # FAULT 6: Missing write verbs ('create', 'update', 'patch') for wgpolicyk8s.io API group
  - apiGroups: ["wgpolicyk8s.io"]
    resources: ["policyreports", "clusterpolicyreports"]
    verbs: ["get", "list"] 
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: policy-reporter-binding
subjects:
  - kind: ServiceAccount
    name: policy-reporter-sa
    namespace: kyverno
roleRef:
  kind: ClusterRole
  name: policy-reporter-role
  apiGroup: rbac.authorization.k8s.io
EOF

# ------------------------------------------------------------------------------
# STEP 4: Inject Fault 7 & 8 - Kube-APIServer Audit Mount Misconfiguration
# ------------------------------------------------------------------------------
echo "[+] Generating flawed APIServer manifest snippet at ${LAB_DIR}/kube-apiserver-snippet.yaml..."
cat << 'EOF' > "${LAB_DIR}/kube-apiserver-snippet.yaml"
# Snippet representing /etc/kubernetes/manifests/kube-apiserver.yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    volumeMounts:
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      # FAULT 7: Mismatched hostPath directory prevents audit.log persistence to host filesystem
      path: /var/log/kubernetes/wrong-audit-path
      type: DirectoryOrCreate
EOF

echo ""
echo "=========================================================================="
echo " [!] CNPE LAB 3.3 BREAK-AND-FIX ENVIRONMENT SUCCESSFULLY PREPARED"
echo "=========================================================================="
echo "Lab Directory: ${LAB_DIR}"
echo "Audit Policy File: ${AUDIT_POLICY_PATH}"
echo "APIServer Snippet: ${LAB_DIR}/kube-apiserver-snippet.yaml"
echo ""
echo "DIAGNOSTIC TASK:"
echo "1. Identify why Kubernetes APIServer audit log (/var/log/kubernetes/audit/audit.log)"
echo "   fails to log PolicyReport ('wgpolicyk8s.io') and Kyverno policy events."
echo "2. Fix ${AUDIT_POLICY_PATH} and APIServer hostPath volume mounts."
echo "3. Fix Kyverno SBOM attestation policy (${LAB_DIR}/kyverno-sbom-policy.yaml)"
echo "   so background compliance scans generate PolicyReport CRs."
echo "4. Correct RBAC rules in ${LAB_DIR}/policy-reporter-rbac.yaml."
echo ""
echo "Review the end of this script file for the full step-by-step solution."
echo "=========================================================================="

exit 0


# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (CNPE EXAM LEVEL)
# ==============================================================================
#
# ROOT CAUSE ANALYSIS:
# 1. Audit Policy Level 'None': In /etc/kubernetes/audit-policy.yaml, audit level for
#    'wgpolicyk8s.io' was set to 'None', explicitly silencing audit trails for compliance reports.
# 2. Invalid API Group: 'kyverno.io.invalid-domain' is an unrecognized group, causing rule drops.
# 3. Suppressed Stages: 'ResponseComplete' was omitted in omitStages, preventing the API server
#    from recording final execution status of policy audit evaluations.
# 4. HostPath Mismatch: The APIServer pod volume 'audit-log' mapped container path
#    '/var/log/kubernetes/audit' to host directory '/var/log/kubernetes/wrong-audit-path'.
# 5. Background Scanning Disabled: Kyverno ClusterPolicy set 'background: false', preventing
#    existing running pods from being audited into PolicyReport CRs.
# 6. Invalid Public Key Format: 'publicKeys' contained an invalid string instead of a valid PEM string.
# 7. Insufficient RBAC Verbs: 'policy-reporter-role' lacked 'create', 'update', and 'patch'
#    verbs on 'wgpolicyk8s.io' resources.
#
# ------------------------------------------------------------------------------
# RECOVERY STEPS:
# ------------------------------------------------------------------------------
#
# STEP 1: Fix /etc/kubernetes/audit-policy.yaml
# Execute the following command to apply a valid audit policy:
#
# cat << 'EOF' > /etc/kubernetes/audit-policy.yaml
# apiVersion: audit.k8s.io/v1
# kind: AuditPolicy
# rules:
#   # Log PolicyReport creation and update events at RequestResponse level
#   - level: RequestResponse
#     resources:
#       - group: "wgpolicyk8s.io"
#         resources: ["policyreports", "clusterpolicyreports"]
#   # Log Kyverno policy evaluations at Metadata level
#   - level: Metadata
#     resources:
#       - group: "kyverno.io"
#         resources: ["clusterpolicies", "policies"]
#   # Default fallback rule for cluster metadata
#   - level: Metadata
#     omitStages:
#       - "RequestReceived"
# EOF
#
# STEP 2: Fix APIServer Manifest HostPath Volume Mount
# Edit /etc/kubernetes/manifests/kube-apiserver.yaml and update the volumes block:
#
#   volumes:
#   - name: audit-log
#     hostPath:
#       path: /var/log/kubernetes/audit
#       type: DirectoryOrCreate
#
# STEP 3: Fix Kyverno SBOM ClusterPolicy Syntax (${LAB_DIR}/kyverno-sbom-policy.yaml)
# Reconfigure the ClusterPolicy with background scanning enabled and valid public key format:
#
# cat << 'EOF' > /tmp/cnpe-lab-3.3/kyverno-sbom-policy.yaml
# apiVersion: kyverno.io/v1
# kind: ClusterPolicy
# metadata:
#   name: check-sbom-attestation
# spec:
#   validationFailureAction: Audit
#   background: true
#   rules:
#     - name: verify-image-sbom
#       match:
#         any:
#         - resources:
#             kinds:
#               - Pod
#       verifyImages:
#         - imageReferences:
#             - "*"
#           attestations:
#             - predicateType: https://spdx.dev/Document
#               attestors:
#                 - count: 1
#                   entries:
#                     - keys:
#                         publicKeys: |
#                           -----BEGIN PUBLIC KEY-----
#                           MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N/2pC5+...
#                           -----END PUBLIC KEY-----
# EOF
#
# STEP 4: Fix Policy Reporter RBAC Permissions (${LAB_DIR}/policy-reporter-rbac.yaml)
# Update ClusterRole to include full lifecycle verbs for PolicyReport resources:
#
# cat << 'EOF' > /tmp/cnpe-lab-3.3/policy-reporter-rbac.yaml
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRole
# metadata:
#   name: policy-reporter-role
# rules:
#   - apiGroups: ["wgpolicyk8s.io"]
#     resources: ["policyreports", "clusterpolicyreports"]
#     verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# EOF
#
# STEP 5: Verification Commands
# 1. Verify API server audit logging stream:
#    tail -f /var/log/kubernetes/audit/audit.log | grep -E "wgpolicyk8s.io|kyverno.io"
# 2. Inspect generated compliance PolicyReport CRs:
#    kubectl get policyreports.wgpolicyk8s.io -A -o wide
#    kubectl get clusterpolicyreports.wgpolicyk8s.io -o jsonpath='{.items[*].summary}'
# ==============================================================================