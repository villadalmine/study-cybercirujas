#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate)
# Topic 1.6: Workload and Application Code Security
# Exam Weight: 2.33%
# Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# ==============================================================================
# 
# LAB TITLE: Troubleshooting Pod Security Standards (PSS) & SecurityContext Enforcement
# 
# DESCRIPTION:
# This break-and-fix lab creates a production-grade namespace enforced with the
# Pod Security Standards (PSS) "restricted" profile via Pod Security Admission (PSA).
# A deployment named 'payment-processor' fails to run due to multi-layered security
# context violations and runtime immutability constraints.
# 
# SCENARIO SYMPTOMS:
# 1. Deployment replicas remain 0/1 ready.
# 2. ReplicaSet events show Pod Security Admission admission webhook rejections.
# 3. After fixing admission rejections, the Pod enters CrashLoopBackOff due to
#    readOnlyRootFilesystem write failures on ephemeral paths (/app/run, /tmp).
# 
# STUDENT OBJECTIVES:
# - Diagnose PSS Restricted enforcement rejections via ReplicaSet event logs.
# - Configure container & pod SecurityContext (runAsNonRoot, runAsUser, seccompProfile,
#   allowPrivilegeEscalation, capabilities drop ALL).
# - Resolve readOnlyRootFilesystem constraints using ephemeral emptyDir volume mounts.
# ==============================================================================

set -euo pipefail

COLOR_RESET="\033[0m"
COLOR_RED="\033[1;31m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[1;36m"
COLOR_BOLD="\033[1m"

NAMESPACE="kcsa-workload-sec"
DEPLOYMENT_NAME="payment-processor"

log_info() {
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"
}

check_prerequisites() {
    log_info "Checking lab prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not available in PATH."
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Unable to connect to Kubernetes cluster. Ensure KUBECONFIG is valid."
        exit 1
    fi
    log_success "Kubernetes cluster connection verified."
}

cleanup_environment() {
    log_info "Cleaning up namespace '${NAMESPACE}'..."
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true
    log_success "Cleanup complete."
}

inject_breakage() {
    log_info "Setting up lab namespace: '${NAMESPACE}'..."
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    log_info "Enforcing PSS Restricted profile on namespace..."
    # Apply official Pod Security Admission labels for PSS Restricted level
    kubectl label namespace "${NAMESPACE}" \
        pod-security.kubernetes.io/enforce=restricted \
        pod-security.kubernetes.io/enforce-version=latest \
        pod-security.kubernetes.io/warn=restricted \
        pod-security.kubernetes.io/warn-version=latest \
        --overwrite > /dev/null

    log_info "Deploying broken workload manifest '${DEPLOYMENT_NAME}'..."
    
    # Manifest intentionally introduces:
    # 1. PSS Restricted Admission Rejections (missing seccomp, capabilities, privilege escalation flag)
    # 2. Runtime error (readOnlyRootFilesystem=true without writable volume mounts for logs/pid)
    cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: financial-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      containers:
      - name: payment-api
        image: busybox:1.36.1
        command:
        - sh
        - -c
        - |
          echo "Starting Payment API daemon..."
          echo "\$(date -u) - Init sequence starting" > /app/run/payment.pid
          touch /tmp/session_cache.db
          echo "Payment API is ready."
          exec sleep 3600
        # BROKEN SECURITY CONTEXT & FILESYSTEM CONFIGURATION:
        securityContext:
          readOnlyRootFilesystem: true
          # Missing PSS Restricted mandatory fields:
          # - allowPrivilegeEscalation: false
          # - capabilities: drop: ["ALL"]
          # - runAsNonRoot: true
          # - runAsUser / runAsGroup: >10000
          # - seccompProfile: type: RuntimeDefault
EOF

    log_warn "Lab breakage injected successfully!"
}

print_student_instructions() {
    echo -e "\n${COLOR_BOLD}==============================================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}   KCSA LAB 1.6: WORKLOAD & APPLICATION CODE SECURITY - BREAK & FIX           ${COLOR_RESET}"
    echo -e "${COLOR_BOLD}==============================================================================${COLOR_RESET}\n"
    
    echo -e "${COLOR_YELLOW}SITUATION REPORT:${COLOR_RESET}"
    echo -e "The production workload '${DEPLOYMENT_NAME}' in namespace '${NAMESPACE}' is failing."
    echo -e "Security auditing requires enforcing the PSS 'restricted' profile on the namespace.\n"

    echo -e "${COLOR_YELLOW}YOUR TASKS:${COLOR_RESET}"
    echo -e "1. Inspect why the Deployment fails to create Pods."
    echo -e "2. Update the Deployment manifest to satisfy PSS Restricted requirements:"
    echo -e "   - Enforce non-root execution (runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001)."
    echo -e "   - Disable privilege escalation (allowPrivilegeEscalation: false)."
    echo -e "   - Drop all Linux capabilities (capabilities: drop: [\"ALL\"])."
    echo -e "   - Configure seccomp profile (seccompProfile: type: RuntimeDefault)."
    echo -e "3. Fix runtime CrashLoopBackOff caused by 'readOnlyRootFilesystem: true':"
    echo -e "   - Mount ephemeral 'emptyDir' volumes at '/app/run' and '/tmp' so the app can write runtime files."
    echo -e "4. Verify that the Pod transitions to status 'Running (1/1)' without violating PSS policies.\n"

    echo -e "${COLOR_YELLOW}RECOMMENDED DIAGNOSTIC COMMANDS:${COLOR_RESET}"
    echo -e "  kubectl get deployment -n ${NAMESPACE}"
    echo -e "  kubectl get replicaset -n ${NAMESPACE}"
    echo -e "  kubectl describe replicaset -n ${NAMESPACE} -l app=${DEPLOYMENT_NAME}"
    echo -e "  kubectl get events -n ${NAMESPACE} --field-selector reason=FailedCreate"
    echo -e "  kubectl logs -n ${NAMESPACE} -l app=${DEPLOYMENT_NAME}\n"

    echo -e "${COLOR_CYAN}Note: Detailed step-by-step solution is embedded at the bottom of this script file.${COLOR_RESET}\n"
}

main() {
    case "${1:-}" in
        --cleanup)
            check_prerequisites
            cleanup_environment
            ;;
        *)
            check_prerequisites
            cleanup_environment
            inject_breakage
            print_student_instructions
            ;;
    esac
}

main "$@"

# ==============================================================================
# STEP-BY-STEP SOLUTION (EDUCATIONAL MATERIAL)
# ==============================================================================
#
# DIAGNOSIS PHASE:
# ------------------------------------------------------------------------------
# Step 1: Check deployment status
#   $ kubectl get deploy -n kcsa-workload-sec
#   NAME                READY   UP-TO-DATE   AVAILABLE   AGE
#   payment-processor   0/1     0            0           30s
#
# Step 2: Check ReplicaSet events to discover admission webhook rejection
#   $ kubectl describe rs -n kcsa-workload-sec -l app=payment-processor
#   ...
#   Events:
#     Type     Reason        Age                   From                   Message
#     ----     ------        ----                  ----                   -------
#     Warning  FailedCreate  12s (x4 over 45s)     replicaset-controller  Error creating: pods "payment-processor-..." is forbidden:
#              violates PodSecurity "restricted:latest":
#              - allowPrivilegeEscalation != false (container "payment-api" must set securityContext.allowPrivilegeEscalation=false)
#              - unrestricted capabilities (container "payment-api" must set securityContext.capabilities.drop=["ALL"])
#              - runAsNonRoot != true (pod or container "payment-api" must set securityContext.runAsNonRoot=true)
#              - seccompProfile (pod or container "payment-api" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
#
# Step 3: Understand the requirement
#   Under KCSA Topic 1.6, workloads in restricted namespaces must adhere to the
#   Pod Security Standards Restricted Profile:
#   Ref: https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted
#
# REMEDIATION PHASE:
# ------------------------------------------------------------------------------
# Execute the following command to apply the syntactically valid, hardened manifest:
#
# kubectl apply -f - <<'EOF'
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-processor
#   namespace: kcsa-workload-sec
#   labels:
#     app.kubernetes.io/name: payment-processor
#     app.kubernetes.io/component: api
#     app.kubernetes.io/part-of: financial-system
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: payment-processor
#   template:
#     metadata:
#       labels:
#         app: payment-processor
#     spec:
#       # Pod-level security context enforcing non-root & seccomp
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         runAsGroup: 10001
#         fsGroup: 10001
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: payment-api
#         image: busybox:1.36.1
#         command:
#         - sh
#         - -c
#         - |
#           echo "Starting Payment API daemon..."
#           echo "$(date -u) - Init sequence starting" > /app/run/payment.pid
#           touch /tmp/session_cache.db
#           echo "Payment API is ready."
#           exec sleep 3600
#         # Container-level security context dropping capabilities & privilege escalation
#         securityContext:
#           allowPrivilegeEscalation: false
#           readOnlyRootFilesystem: true
#           capabilities:
#             drop:
#             - ALL
#         # Writable ephemeral storage mounts for immutable root filesystem
#         volumeMounts:
#         - name: app-run
#           mountPath: /app/run
#         - name: tmp-dir
#           mountPath: /tmp
#       volumes:
#       - name: app-run
#         emptyDir: {}
#       - name: tmp-dir
#         emptyDir: {}
# EOF
#
# VERIFICATION PHASE:
# ------------------------------------------------------------------------------
# 1. Verify Pod transitions to Running status:
#    $ kubectl get pods -n kcsa-workload-sec -l app=payment-processor
#    NAME                                 READY   STATUS    RESTARTS   AGE
#    payment-processor-67448889b4-x9z2p   1/1     Running   0          15s
#
# 2. Verify application logs:
#    $ kubectl logs -n kcsa-workload-sec -l app=payment-processor
#    Starting Payment API daemon...
#    Payment API is ready.
#
# 3. Confirm security context enforcement via Pod API inspection:
#    $ kubectl get pod -n kcsa-workload-sec -l app=payment-processor -o jsonpath='{.items[0].spec.containers[0].securityContext}'
# ==============================================================================