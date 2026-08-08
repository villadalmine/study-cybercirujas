#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Security Associate) - Production Lab
# Topic 4.4: Malicious Code Execution and Compromised Applications in Containers
# Exam Weight: 2.29%
# ==============================================================================
# OFFICIAL REFERENCES:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - K8s Security Context: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
# - Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
# - Restricting Syscalls with Seccomp: https://kubernetes.io/docs/tutorials/security/seccomp/
# - Container Runtime Security Architecture: https://kubernetes.io/docs/concepts/security/container-isolation/
# ==============================================================================
# ARCHITECTURE & TECHNICAL MECHANICS OVERVIEW:
# ------------------------------------------------------------------------------
# In containerized environments, malicious code execution typically occurs when an
# application vulnerability (e.g., Remote Code Execution, command injection, or
# compromised third-party dependencies) allows an attacker to spawn arbitrary
# processes within the container boundary.
#
# Unhardened containers expose key vectors:
# 1. Writable Root Filesystem: Allows attackers to download, compile, or execute
#    standalone malicious binaries (e.g., cryptominers, reverse shells, C2 agents)
#    in writable directories such as /tmp, /var/tmp, or /app.
# 2. Root User Execution (UID 0): Provides full privileges inside the container namespace,
#    allowing package installation (apt/apk), modification of system binaries, and
#    easier container breakout if Linux kernel vulnerabilities exist.
# 3. Privilege Escalation (allowPrivilegeEscalation: true): Permits SUID/SGID binaries
#    to escalate effective privileges beyond the parent process.
# 4. Excessive Linux Capabilities: Retaining capabilities like CAP_SYS_ADMIN, CAP_NET_RAW,
#    or CAP_SYS_PTRACE enables raw network crafting, process injection, and host access.
# 5. Unfiltered System Calls: Absence of a Seccomp profile leaves dangerous syscalls
#    (e.g., ptrace, unshare, kexec_load) accessible to compromised binaries.
#
# HARDENING & ARCHITECTURAL TRADE-OFFS:
# - ReadOnlyRootFilesystem: Enforces immutability at the storage layer. If an app
#   requires transient state (e.g., scratch space, sockets), emptyDir volumes must be
#   explicitly mounted at target paths (e.g., /tmp) with tight size limits.
# - Non-Root Execution (runAsNonRoot + runAsUser): Prevents host root equivalence.
#   Trade-off: Applications cannot bind to privileged low ports (<1024) directly without
#   CAP_NET_BIND_SERVICE or service routing, and files must have correct ownership.
# - Capabilities Drop (drop: ["ALL"]): Implements least privilege. Specific capabilities
#   must be added back only when strictly required by domain logic.
# - Seccomp RuntimeDefault: Restricts available kernel syscalls to ~40% of standard Linux
#   syscalls, drastically reducing the kernel attack surface with zero performance overhead.
# ==============================================================================

set -euo pipefail

COLOR_GREEN="\033[0;32m"
COLOR_RED="\033[0;31m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_RESET="\033[0m"

NAMESPACE="kcsa-compromised-app"
DEPLOYMENT_NAME="payment-gateway"

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }
log_success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl binary is not installed or not in PATH."
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Unable to connect to Kubernetes cluster. Ensure your KUBECONFIG is valid."
        exit 1
    fi
}

inject_vulnerability() {
    log_info "Creating namespace '${NAMESPACE}'..."
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    log_warn "Deploying vulnerable and compromised workload '${DEPLOYMENT_NAME}'..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${DEPLOYMENT_NAME}
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOYMENT_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOYMENT_NAME}
    spec:
      containers:
      - name: payment-api
        image: bash:5.2
        command: ["/usr/local/bin/bash", "-c"]
        args:
        - |
          echo "[PAYMENT-API] Starting Payment Gateway service..."
          
          # Simulating unauthorized malicious payload download & execution in writable /tmp
          echo '#!/usr/local/bin/bash' > /tmp/xmrig_miner.sh
          echo 'echo "[COMPROMISED] Cryptomining payload executed in background (PID $$)"' >> /tmp/xmrig_miner.sh
          echo 'while true; do echo "[MALICIOUS_PROCESS] Mining crypto... CPU usage 98%" >> /tmp/miner.log; sleep 5; done' >> /tmp/xmrig_miner.sh
          chmod +x /tmp/xmrig_miner.sh
          
          /tmp/xmrig_miner.sh &
          
          # Main application execution loop
          while true; do
            echo "[PAYMENT-API] Processing legitimate payment transactions..."
            sleep 10
          done
        securityContext:
          privileged: false
          runAsUser: 0
          readOnlyRootFilesystem: false
          allowPrivilegeEscalation: true
          capabilities:
            add:
            - SYS_ADMIN
            - NET_RAW
EOF

    log_info "Waiting for deployment deployment/${DEPLOYMENT_NAME} to roll out..."
    kubectl rollout status deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --timeout=60s
}

display_briefing() {
    echo ""
    echo "=============================================================================="
    echo "                      KCSA BREAK & FIX LAB BRIEFING                           "
    echo "=============================================================================="
    echo "SCENARIO: Compromised Container with Malicious Process Execution"
    echo "NAMESPACE: ${NAMESPACE}"
    echo "DEPLOYMENT: ${DEPLOYMENT_NAME}"
    echo "------------------------------------------------------------------------------"
    echo "OBSERVED SYMPTOMS:"
    echo " 1. Security telemetry flagged container '${DEPLOYMENT_NAME}' running as root (UID 0)."
    echo " 2. An unauthorized process (/tmp/xmrig_miner.sh) was dropped and executed inside"
    echo "    the container filesystem at runtime."
    echo " 3. The container retains dangerous Linux capabilities (SYS_ADMIN, NET_RAW) and"
    echo "    allows privilege escalation."
    echo " 4. Syscalls are unconstrained due to missing default Seccomp isolation."
    echo ""
    echo "STUDENT OBJECTIVES:"
    echo " Harden the workload deployment manifest to completely prevent runtime execution"
    echo " of arbitrary/malicious binaries and mitigate container compromise vectors."
    echo ""
    echo "REQUIREMENTS TO FIX:"
    echo " 1. Enforce non-root execution: Container must run as user ID 10001."
    echo " 2. Enforce root filesystem immutability: Set readOnlyRootFilesystem to true."
    echo " 3. Disable privilege escalation: Set allowPrivilegeEscalation to false."
    echo " 4. Strip Linux capabilities: Drop ALL capabilities (capabilities.drop = ['ALL'])."
    echo " 5. Enforce Seccomp syscall filtering: Apply profile 'RuntimeDefault'."
    echo " 6. Ensure the main container app remains running, but the malicious script creation"
    echo "    and execution in /tmp fails cleanly due to read-only root filesystem restriction."
    echo ""
    echo "DIAGNOSTIC COMMANDS TO START WITH:"
    echo " - Inspect running processes inside container:"
    echo "   kubectl exec -n ${NAMESPACE} deploy/${DEPLOYMENT_NAME} -- ps aux"
    echo " - Inspect security context:"
    echo "   kubectl get deploy -n ${NAMESPACE} ${DEPLOYMENT_NAME} -o yaml"
    echo " - Inspect file system writability:"
    echo "   kubectl exec -n ${NAMESPACE} deploy/${DEPLOYMENT_NAME} -- touch /tmp/test_file"
    echo ""
    echo "VERIFICATION:"
    echo " Run the following command to test your fix:"
    echo "   kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT_NAME} -o jsonpath='{.items[0].spec.containers[0].securityContext}'"
    echo "=============================================================================="
    echo ""
}

main() {
    check_prerequisites
    inject_vulnerability
    display_briefing
    log_success "Break phase completed. The environment is ready for diagnostic and fix."
}

main "$@"

# ==============================================================================
# SOLUTION & STEP-BY-STEP REMEDIATION GUIDE (DO NOT READ UNTIL ATTEMPTED)
# ==============================================================================
#
# STEP 1: ADVANCED DIAGNOSTICS & THREAT INVESTIGATION
# ------------------------------------------------------------------------------
# 1.1 List running pods in the target namespace:
#     $ kubectl get pods -n kcsa-compromised-app
#     NAME                               READY   STATUS    RESTARTS   AGE
#     payment-gateway-767d4f9b89-x8z9l   1/1     Running   0          45s
#
# 1.2 Inspect active process tree in the container to identify unauthorized execution:
#     $ kubectl exec -n kcsa-compromised-app deploy/payment-gateway -- ps aux
#     PID   USER     TIME  COMMAND
#         1 root      0:00 /usr/local/bin/bash -c ...
#         7 root      0:00 /usr/local/bin/bash /tmp/xmrig_miner.sh
#        12 root      0:00 sleep 5
#        13 root      0:00 sleep 10
#     
#     --> DIAGNOSTIC FINDING: Process PID 7 (/tmp/xmrig_miner.sh) is running as root (UID 0)
#         from a writable path (/tmp).
#
# 1.3 Audit SecurityContext parameters on the current deployment:
#     $ kubectl get deploy -n kcsa-compromised-app payment-gateway -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | jq .
#     {
#       "allowPrivilegeEscalation": true,
#       "capabilities": {
#         "add": [
#           "SYS_ADMIN",
#           "NET_RAW"
#         ]
#       },
#       "privileged": false,
#       "readOnlyRootFilesystem": false,
#       "runAsUser": 0
#     }
#
# 1.4 Inspect container proc filesystem for active capabilities and seccomp status:
#     $ kubectl exec -n kcsa-compromised-app deploy/payment-gateway -- cat /proc/1/status | grep -E "Cap|Seccomp"
#     CapInh:   0000000000000000
#     CapPrm:   00000000a80425fb
#     CapEff:   00000000a80425fb
#     Seccomp:  0
#     --> DIAGNOSTIC FINDING: Seccomp is 0 (disabled/unfiltered). Capabilities are excessive.
#
# ------------------------------------------------------------------------------
# STEP 2: REMEDIATION & HARDENING MANIFEST
# ------------------------------------------------------------------------------
# Apply the hardened production manifest below.
#
# Key Architectural Fixes:
# - Enforces 'seccompProfile.type: RuntimeDefault' at Pod/Container level.
# - Enforces 'runAsNonRoot: true' and explicit non-zero UID/GID (10001).
# - Enforces 'readOnlyRootFilesystem: true' to block binary dropping in /tmp or any path.
# - Drops ALL Linux capabilities ('capabilities.drop: ["ALL"]').
# - Sets 'allowPrivilegeEscalation: false'.
#
# Execute the following CLI command to apply the fix:
#
# cat <<EOF | kubectl apply -f -
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: payment-gateway
#   namespace: kcsa-compromised-app
#   labels:
#     app: payment-gateway
#     tier: backend
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: payment-gateway
#   template:
#     metadata:
#       labels:
#         app: payment-gateway
#     spec:
#       securityContext:
#         runAsNonRoot: true
#         runAsUser: 10001
#         runAsGroup: 10001
#         fsGroup: 10001
#         seccompProfile:
#           type: RuntimeDefault
#       containers:
#       - name: payment-api
#         image: bash:5.2
#         command: ["/usr/local/bin/bash", "-c"]
#         args:
#         - |
#           echo "[PAYMENT-API] Starting Payment Gateway service in hardened container..."
#           
#           # Attempting unauthorized payload execution (This WILL FAIL on read-only rootfs)
#           if echo '#!/usr/local/bin/bash' > /tmp/xmrig_miner.sh 2>/dev/null; then
#             echo "[WARNING] Security bypass: Writable filesystem detected!"
#           else
#             echo "[SECURITY_SUCCESS] File creation in /tmp blocked: Read-only file system."
#           fi
#           
#           # Main application execution loop
#           while true; do
#             echo "[PAYMENT-API] Processing legitimate payment transactions securely..."
#             sleep 10
#           done
#         securityContext:
#           privileged: false
#           allowPrivilegeEscalation: false
#           readOnlyRootFilesystem: true
#           capabilities:
#             drop:
#             - ALL
# EOF
#
# ------------------------------------------------------------------------------
# STEP 3: EMPIRICAL POST-REMEDIATION VERIFICATION
# ------------------------------------------------------------------------------
# 3.1 Verify Deployment Rollout:
#     $ kubectl rollout status deployment/payment-gateway -n kcsa-compromised-app
#     deployment "payment-gateway" successfully rolled out
#
# 3.2 Inspect Pod logs to verify execution block:
#     $ kubectl logs -n kcsa-compromised-app deploy/payment-gateway
#     [PAYMENT-API] Starting Payment Gateway service in hardened container...
#     [SECURITY_SUCCESS] File creation in /tmp blocked: Read-only file system.
#     [PAYMENT-API] Processing legitimate payment transactions securely...
#
# 3.3 Verify running process tree inside container:
#     $ kubectl exec -n kcsa-compromised-app deploy/payment-gateway -- ps aux
#     PID   USER     TIME  COMMAND
#         1 10001     0:00 /usr/local/bin/bash -c ...
#         7 10001     0:00 sleep 10
#     
#     --> VERIFICATION SUCCESS: Process running as UID 10001. No miner process exists.
#
# 3.4 Confirm system is read-only by attempting manual file creation:
#     $ kubectl exec -n kcsa-compromised-app deploy/payment-gateway -- touch /tmp/malicious_bin
#     touch: /tmp/malicious_bin: Read-only file system
#     command terminated with exit code 1
#
# 3.5 Verify active Seccomp profile on container process:
#     $ kubectl exec -n kcsa-compromised-app deploy/payment-gateway -- cat /proc/1/status | grep Seccomp
#     Seccomp:  2
#     
#     --> VERIFICATION SUCCESS: Seccomp state 2 indicates SECCOMP_MODE_FILTER (RuntimeDefault active).
# ==============================================================================