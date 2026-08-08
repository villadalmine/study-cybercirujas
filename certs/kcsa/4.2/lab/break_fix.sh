#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA Certification Lab - Domain 4.2: Persistence (Weight: 2.29%)
# Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#
# Scenario: Threat Persistence via Malicious CronJob & Static Pod Injection
#
# DESCRIPTION:
# An attacker obtained temporary access to the cluster and established stealthy
# persistence mechanisms to maintain long-term access across host/cluster state.
#
# SYMPTOMS:
# 1. An unrecognized recurring process runs inside 'kube-system' namespace with
#    privileged host access (`hostPID: true`, `hostPath: /`).
# 2. An unmanaged Control Plane Pod (`kube-service-monitor-backdoor`) runs continuously 
#    without any backing Deployment, DaemonSet, or StatefulSet.
#
# STUDENT OBJECTIVES:
# - Discover and inspect all unauthorized persistence vectors.
# - Eradicate the rogue Kubernetes CronJob and associated execution artifacts.
# - Identify and remove the rogue Static Pod manifest from the Kubelet manifest directory.
# - Execute `./break_and_fix_persistence.sh --verify` to validate successful cleanup.
# ==============================================================================

set -euo pipefail

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_BLUE="\033[0;34m"
COLOR_RESET="\033[0m"

LAB_NAMESPACE="kube-system"
PERSISTENCE_CRONJOB="kube-telemetry-sync"
STATIC_POD_MANIFEST="/etc/kubernetes/manifests/kube-service-monitor.yaml"

function log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
}

function log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

function log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"
}

function log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"
}

function check_prerequisites() {
    log_info "Validating environment prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH."
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Unable to connect to Kubernetes cluster. Verify KUBECONFIG."
        exit 1
    fi
}

function break_environment() {
    log_warn "Simulating Attacker Persistence scenario..."

    # Persistence Vector 1: Unauthorized CronJob in cluster system namespace
    log_info "Injecting vector 1: Malicious CronJob (${PERSISTENCE_CRONJOB})..."
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${PERSISTENCE_CRONJOB}
  namespace: ${LAB_NAMESPACE}
  labels:
    k8s-app: kube-telemetry
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: kube-telemetry-sync
        spec:
          restartPolicy: OnFailure
          hostPID: true
          containers:
          - name: sync-agent
            image: busybox:1.36
            command:
            - /bin/sh
            - -c
            - "echo 'Persistence agent active' && sleep 10"
            securityContext:
              privileged: true
            volumeMounts:
            - name: host-root
              mountPath: /host
          volumes:
          - name: host-root
            hostPath:
              path: /
              type: Directory
EOF

    # Persistence Vector 2: Static Pod planted in Kubelet manifest directory
    if [ -d "/etc/kubernetes/manifests" ]; then
        log_info "Injecting vector 2: Static Pod manifest (${STATIC_POD_MANIFEST})..."
        cat <<EOF | sudo tee "${STATIC_POD_MANIFEST}" > /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: kube-service-monitor-backdoor
  namespace: ${LAB_NAMESPACE}
  labels:
    tier: control-plane
spec:
  hostNetwork: true
  containers:
  - name: backdoor-listener
    image: busybox:1.36
    command:
    - /bin/sh
    - -c
    - "while true; do sleep 3600; done"
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "SYS_ADMIN"]
EOF
    else
        log_warn "/etc/kubernetes/manifests not found. Static Pod vector skipped; CronJob vector active."
    fi

    echo ""
    log_warn "======================================================================"
    log_warn " ATTACK SCENARIO DEPLOYED: Persistence Mechanisms Active              "
    log_warn "======================================================================"
    log_warn "Student Tasks:"
    log_warn "1. Find and analyze unauthorized CronJobs in namespace '${LAB_NAMESPACE}'."
    log_warn "2. Detect unmanaged Static Pods running on node filesystem."
    log_warn "3. Remove all persistence artifacts."
    log_warn "4. Validate fix by running: $0 --verify"
    log_warn "======================================================================"
}

function verify_remediation() {
    log_info "Running KCSA persistence remediation verification..."
    local failures=0

    # Test CronJob Removal
    if kubectl get cronjob "${PERSISTENCE_CRONJOB}" -n "${LAB_NAMESPACE}" &> /dev/null; then
        log_error "FAIL: CronJob '${PERSISTENCE_CRONJOB}' is still present in '${LAB_NAMESPACE}'!"
        failures=$((failures + 1))
    else
        log_success "PASS: CronJob persistence mechanism successfully removed."
    fi

    # Test Static Pod Manifest Removal
    if [ -f "${STATIC_POD_MANIFEST}" ]; then
        log_error "FAIL: Static Pod manifest '${STATIC_POD_MANIFEST}' still exists on disk!"
        failures=$((failures + 1))
    else
        log_success "PASS: Static Pod manifest successfully removed from host filesystem."
    fi

    # Test Active Static Pod Status
    if kubectl get pod -n "${LAB_NAMESPACE}" | grep -q "kube-service-monitor-backdoor"; then
        log_error "FAIL: Rogue Static Pod is still running in cluster context!"
        failures=$((failures + 1))
    fi

    if [ ${failures} -eq 0 ]; then
        echo ""
        log_success "EXCELLENT WORK! All persistence vectors have been eliminated."
        exit 0
    else
        echo ""
        log_error "Verification failed with ${failures} remaining issue(s)."
        exit 1
    fi
}

function main() {
    check_prerequisites

    if [[ "${1:-}" == "--verify" ]]; then
        verify_remediation
    else
        break_environment
    fi
}

main "$@"

# ==============================================================================
# INSTRUCTOR SOLUTION & STEP-BY-STEP REMEDIATION GUIDE
# ==============================================================================
#
# STEP 1: Audit Cluster CronJobs for Host-level Escalation & Persistence
# Command:
#   kubectl get cronjobs -n kube-system
# Output:
#   NAME                  SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
#   kube-telemetry-sync   * * * * *   False     0        5s              45s
#
# STEP 2: Inspect CronJob Security Context & Host Mounts
# Command:
#   kubectl get cronjob kube-telemetry-sync -n kube-system -o yaml
# Note: Notice `hostPID: true`, `privileged: true`, and `hostPath: /` volume mounts.
#
# STEP 3: Delete Malicious CronJob and Associated Active Jobs
# Command:
#   kubectl delete cronjob kube-telemetry-sync -n kube-system
#   kubectl delete jobs -n kube-system -l app=kube-telemetry-sync
#
# STEP 4: Detect Unmanaged Control Plane Static Pods
# Command:
#   kubectl get pods -n kube-system
# Note: Identify `kube-service-monitor-backdoor-<node-name>`. Notice it has no 
# Deployment/ReplicaSet owner reference.
#
# STEP 5: Locate and Remove Kubelet Static Pod Manifest on Control Plane Node
# Command:
#   ls -la /etc/kubernetes/manifests/
#   sudo rm -f /etc/kubernetes/manifests/kube-service-monitor.yaml
#
# STEP 6: Validate Eradication
# Command:
#   ./break_and_fix_persistence.sh --verify
# ==============================================================================