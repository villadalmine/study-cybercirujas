#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Exam Prep
# Domain 4: Container & Workload Security
# Topic 4.7: Privilege Escalation (Weight: 2.29%)
#
# References:
# - Official CNCF Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
# - Pod Security Context Mechanics: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
# - K8s RBAC Privilege Escalation Prevention: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping
# ==============================================================================

set -euo pipefail

LAB_NAMESPACE="kcsa-privesc-lab"

echo "========================================================================"
echo " KCSA Topic 4.7: Privilege Escalation - Break & Fix Laboratory"
echo "========================================================================"

# Step 1: Pre-flight Verification
if ! command -v kubectl &>/dev/null; then
    echo "[ERROR] 'kubectl' CLI tool is required but not found in PATH." >&2
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    echo "[ERROR] Cannot connect to target Kubernetes cluster via kubectl." >&2
    exit 1
fi

echo "[+] Pre-flight checks passed."

# Step 2: Cleanup potential prior runs
echo "[+] Initializing lab environment..."
kubectl delete namespace "${LAB_NAMESPACE}" --ignore-not-found=true --wait=true &>/dev/null || true

# Step 3: Create isolated laboratory namespace
kubectl create namespace "${LAB_NAMESPACE}" >/dev/null

# Step 4: Enforce Pod Security Standards (Restricted Profile) on Namespace
# Reference: https://kubernetes.io/docs/concepts/security/pod-security-admission/
echo "[+] Enforcing Pod Security Standard 'restricted' on namespace '${LAB_NAMESPACE}'..."
kubectl label namespace "${LAB_NAMESPACE}" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest \
    --overwrite >/dev/null

# Step 5: Inject Misconfigured Workloads & RBAC (The "Break" Phase)
echo "[+] Deploying insecure payment-api service and overly permissive RBAC..."

# Deployment 1: Insecure SecurityContext breaking Pod Security Admission
kubectl apply -f - <<EOF >/dev/null 2>&1 || true
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: ${LAB_NAMESPACE}
  labels:
    app.kubernetes.io/name: payment-api
    app.kubernetes.io/part-of: financial-suite
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-api
  template:
    metadata:
      labels:
        app: payment-api
    spec:
      serviceAccountName: payment-sa
      containers:
      - name: api-server
        image: nginx:1.25-alpine
        securityContext:
          allowPrivilegeEscalation: true
          privileged: false
          runAsUser: 0
          capabilities:
            add:
            - SYS_ADMIN
            - NET_RAW
        resources:
          limits:
            cpu: 100m
            memory: 128Mi
          requests:
            cpu: 50m
            memory: 64Mi
EOF

# RBAC 1: Overly Permissive Role allowing RBAC privilege escalation (escalate / bind verbs)
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-sa
  namespace: ${LAB_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: payment-operator-role
  namespace: ${LAB_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "create", "update", "escalate", "bind"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payment-operator-binding
  namespace: ${LAB_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: payment-sa
  namespace: ${LAB_NAMESPACE}
roleRef:
  kind: Role
  name: payment-operator-role
  apiGroup: rbac.authorization.k8s.io
EOF

echo ""
echo "========================================================================"
echo " LAB SCENARIO SETUP COMPLETE - BREAKAGE APPLIED"
echo "========================================================================"
echo ""
echo "STUDENT TASK INSTRUCTIONS:"
echo "------------------------------------------------------------------------"
echo "You are an SRE / Security Engineer handling a broken deployment in namespace:"
echo "  Namespace: ${LAB_NAMESPACE}"
echo ""
echo "SYMPTOMS OBSERVED:"
echo "1. The Deployment 'payment-api' is stuck with 0/2 available replicas."
echo "2. Pod Security Admission is rejecting Pod creation or ReplicaSet rollout."
echo "3. The security audit identified two major Privilege Escalation risks:"
echo "   a) Container SecurityContext enables process-level privilege escalation"
echo "      (allowPrivilegeEscalation: true, runAsUser: 0, added capabilities)."
echo "   b) The associated ServiceAccount 'payment-sa' holds RBAC permission"
echo "      to escalate permissions and bind arbitrary roles ('escalate', 'bind')."
echo ""
echo "YOUR GOAL TO FIX:"
echo "1. Modify 'payment-api' Deployment manifest so it complies fully with the"
echo "   Namespace's enforced 'restricted' Pod Security Standard:"
echo "   - Set allowPrivilegeEscalation: false"
echo "   - Configure runAsNonRoot: true and runAsUser: 10001 (non-root UID)"
echo "   - Set readOnlyRootFilesystem: true"
echo "   - Drop ALL capabilities (capabilities.drop: ['ALL'])"
echo "   - Ensure seccompProfile is set to type: RuntimeDefault"
echo "2. Audit and remediate 'payment-operator-role' Role in namespace '${LAB_NAMESPACE}':"
echo "   - Remove dangerous RBAC verbs ('escalate', 'bind') that allow privilege"
echo "     escalation via RBAC management."
echo "3. Verify all replicas of 'payment-api' reach '2/2 Running' state."
echo ""
echo "DIAGNOSTIC COMMANDS TO GET STARTED:"
echo "  kubectl get events -n ${LAB_NAMESPACE} --field-selector type=Warning"
echo "  kubectl describe deployment payment-api -n ${LAB_NAMESPACE}"
echo "  kubectl describe rs -n ${LAB_NAMESPACE}"
echo "  kubectl get role payment-operator-role -n ${LAB_NAMESPACE} -o yaml"
echo ""
echo "========================================================================"
echo " Scroll down to inspect the detailed solution script (commented out)."
echo "========================================================================"

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (FOR STUDENT REFERENCE)
# ==============================================================================
#
# MECHANICS OF PRIVILEGE ESCALATION IN KUBERNETES:
# 1. Linux Process-Level Privilege Escalation:
#    - `allowPrivilegeEscalation: true` controls the `PR_SET_NO_NEW_PRIVS` kernel flag.
#      When true, child processes inside the container can acquire more privileges than
#      their parent process (e.g. via setuid/setgid binaries like `sudo`, `gpasswd`,
#      or binaries with Linux file capabilities).
#    - Setting `allowPrivilegeEscalation: false` enforces `PR_SET_NO_NEW_PRIVS=1`,
#      preventing execution of setuid binaries from escalating rights even if run by root.
#    - Adding capabilities like `CAP_SYS_ADMIN` allows breaking out of container isolation.
#
# 2. Kubernetes Pod Security Standards (PSS) - Restricted Profile:
#    - Requires: `allowPrivilegeEscalation: false`
#    - Requires: `runAsNonRoot: true`
#    - Requires: `capabilities.drop: ["ALL"]`
#    - Requires: `seccompProfile.type: RuntimeDefault` or `Localhost`
#
# 3. RBAC Privilege Escalation Prevention:
#    - Kubernetes API server prevents users/SAs from creating or updating Roles/ClusterRoles
#      with permissions they do not already possess, UNLESS they hold the `escalate` verb on
#      `roles` or `clusterroles` resources.
#    - Granting `escalate` or `bind` allows an attacker inside a compromised container to
#      grant themselves Cluster-Admin rights.
#
# ------------------------------------------------------------------------------
# STEP 1: DIAGNOSE REASON FOR DEPLOYMENT FAILURE
# ------------------------------------------------------------------------------
# Run the following commands:
#   kubectl get pods -n kcsa-privesc-lab
#   kubectl get rs -n kcsa-privesc-lab
#   kubectl describe rs -n kcsa-privesc-lab
#
# Expected output snippet in replica set events:
#   "violates PodSecurity 'restricted:latest': allowPrivilegeEscalation != false,
#   unconfined seccompProfile, runAsNonRoot != true, runAsUser=0,
#   container has forbidden capabilities (SYS_ADMIN, NET_RAW)"
#
# ------------------------------------------------------------------------------
# STEP 2: REMEDIATE WORKLOAD SECURITYCONTEXT (CONTAINER PRIVILEGE ESCALATION)
# ------------------------------------------------------------------------------
# Apply the hardened Deployment manifest matching Restricted PSS requirements:
#
# kubectl apply -f - <<'EOF'
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-api
#   namespace: kcsa-privesc-lab
#   labels:
#     app.kubernetes.io/name: payment-api
# spec:
#   replicas: 2
#   selector:
#     matchLabels:
#       app: payment-api
#   template:
#     metadata:
#       labels:
#         app: payment-api
#     spec:
#       serviceAccountName: payment-sa
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         runAsGroup: 10001
#         fsGroup: 10001
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: api-server
#         image: nginx:1.25-alpine
#         securityContext:
#           allowPrivilegeEscalation: false
#           readOnlyRootFilesystem: true
#           capabilities:
#             drop:
#             - ALL
#         resources:
#           limits:
#             cpu: 100m
#             memory: 128Mi
#           requests:
#             cpu: 50m
#             memory: 64Mi
#         volumeMounts:
#         - name: tmp-vol
#           mountPath: /tmp
#         - name: cache-vol
#           mountPath: /var/cache/nginx
#         - name: pid-vol
#           mountPath: /var/run
#       volumes:
#       - name: tmp-vol
#         emptyDir: {}
#       - name: cache-vol
#         emptyDir: {}
#       - name: pid-vol
#         emptyDir: {}
# EOF
#
# ------------------------------------------------------------------------------
# STEP 3: REMEDIATE RBAC PRIVILEGE ESCALATION RISKS
# ------------------------------------------------------------------------------
# Inspect existing RBAC role:
#   kubectl get role payment-operator-role -n kcsa-privesc-lab -o yaml
#
# Remove 'escalate' and 'bind' verbs from the Role manifest to prevent RBAC
# privilege escalation attacks:
#
# kubectl apply -f - <<'EOF'
# apiVersion: rbac.authorization.k8s.io/v1
# kind: Role
# metadata:
#   name: payment-operator-role
#   namespace: kcsa-privesc-lab
# rules:
# - apiGroups: [""]
#   resources: ["pods"]
#   verbs: ["get", "list", "watch"]
# - apiGroups: ["rbac.authorization.k8s.io"]
#   resources: ["roles", "rolebindings"]
#   verbs: ["get", "list"]
# EOF
#
# ------------------------------------------------------------------------------
# STEP 4: VERIFY RECOVERY AND SECURITY POSTURE
# ------------------------------------------------------------------------------
# 1. Verify Deployment Rollout:
#    kubectl rollout status deployment/payment-api -n kcsa-privesc-lab --timeout=60s
#
# 2. Check Pod Status:
#    kubectl get pods -n kcsa-privesc-lab -o wide
#
# 3. Verify Container SecurityContext parameters on running pod:
#    kubectl get pod -l app=payment-api -n kcsa-privesc-lab \
#      -o jsonpath='{.items[0].spec.containers[0].securityContext}' | jq .
#
# Expected output snippet:
# {
#   "allowPrivilegeEscalation": false,
#   "capabilities": { "drop": ["ALL"] },
#   "readOnlyRootFilesystem": true
# }
#
# 4. Verify RBAC permissions for ServiceAccount:
#    kubectl auth can-i escalate roles -n kcsa-privesc-lab --as=system:serviceaccount:kcsa-privesc-lab:payment-sa
#    Expected output: no
#
# ==============================================================================