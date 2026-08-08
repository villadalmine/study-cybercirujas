#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Certification Lab
# Topic 2.6: KubeProxy Architecture, Security Mechanics, and Failure Recovery
#
# References:
# - CNCF KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# - Kube-Proxy Reference: https://kubernetes.io/docs/concepts/services-networking/kube-proxy/
# - KubeProxy Configuration API: https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
# - Kubernetes Security Hardening: https://kubernetes.io/docs/concepts/security/
# ==============================================================================

set -euo pipefail

# Color Output Palette
COLOR_RESET="\033[0m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_BLUE="\033[0;34m"
COLOR_CYAN="\033[0;36m"
COLOR_BOLD="\033[1m"

BACKUP_DIR="/tmp/kcsa-kubeproxy-lab-backup"
TEST_NS="kcsa-kubeproxy-lab"

log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
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
    log_info "Verifying cluster connectivity and admin permissions..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please run this script in a environment with kubectl configured."
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot reach target Kubernetes cluster via kubectl. Verify your KUBECONFIG context."
        exit 1
    fi

    log_success "Kubernetes cluster connection verified."
}

create_backups() {
    log_info "Creating backups in ${BACKUP_DIR}..."
    mkdir -p "${BACKUP_DIR}"

    # Backup kube-proxy ConfigMap if present
    if kubectl get cm kube-proxy -n kube-system &> /dev/null; then
        kubectl get cm kube-proxy -n kube-system -o yaml > "${BACKUP_DIR}/kube-proxy-cm.yaml"
    fi

    # Backup ClusterRole & ClusterRoleBinding for kube-proxy / system:node-proxier
    if kubectl get clusterrole system:node-proxier &> /dev/null; then
        kubectl get clusterrole system:node-proxier -o yaml > "${BACKUP_DIR}/clusterrole-system-node-proxier.yaml"
    fi

    if kubectl get clusterrolebinding system:node-proxier &> /dev/null; then
        kubectl get clusterrolebinding system:node-proxier -o yaml > "${BACKUP_DIR}/clusterrolebinding-system-node-proxier.yaml"
    fi

    if kubectl get clusterrolebinding kube-proxy &> /dev/null; then
        kubectl get clusterrolebinding kube-proxy -o yaml > "${BACKUP_DIR}/clusterrolebinding-kube-proxy.yaml"
    fi

    log_success "Backups created successfully."
}

inject_breakage() {
    log_warn "Injecting controlled security and networking breakage into KubeProxy..."

    # 1. Deploy test workloads to reproduce East-West traffic failure
    kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f -

    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-target
  namespace: ${TEST_NS}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo-target
  template:
    metadata:
      labels:
        app: echo-target
    spec:
      containers:
      - name: echoserver
        image: registry.k8s.io/e2e-test-images/agnhost:2.40
        command: ["/agnhost", "netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  namespace: ${TEST_NS}
spec:
  type: ClusterIP
  selector:
    app: echo-target
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client-tester
  namespace: ${TEST_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client-tester
  template:
    metadata:
      labels:
        app: client-tester
    spec:
      containers:
      - name: curl-client
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
EOF

    # 2. Break RBAC permissions: Strip 'endpointslices' and 'services' get/list/watch rights from system:node-proxier ClusterRole
    # This simulates a botched security hardening attempt where an SRE over-restricted API permissions.
    if kubectl get clusterrole system:node-proxier &> /dev/null; then
        kubectl patch clusterrole system:node-proxier --type='json' -p='[
            {"op": "replace", "path": "/rules", "value": [
                {
                    "apiGroups": [""],
                    "resources": ["nodes"],
                    "verbs": ["get", "list", "watch"]
                }
            ]}
        ]'
    fi

    # 3. Misconfigure kube-proxy metrics binding address to insecure 0.0.0.0 and break sync period if ConfigMap exists
    if kubectl get cm kube-proxy -n kube-system &> /dev/null; then
        kubectl get cm kube-proxy -n kube-system -o json | \
        sed 's/metricsBindAddress: 127.0.0.1:10249/metricsBindAddress: 0.0.0.0:10249/g' | \
        sed 's/mode: "iptables"/mode: "invalid-mode"/g' | \
        kubectl apply -f - || true
    fi

    # 4. Force restart of kube-proxy DaemonSet pods to pick up the broken state
    log_info "Restarting kube-proxy instances to enforce faulty configuration..."
    kubectl rollout restart daemonset kube-proxy -n kube-system &> /dev/null || \
    kubectl delete pods -n kube-system -l k8s-app=kube-proxy &> /dev/null || true

    log_success "Breakage successfully injected!"
}

print_student_briefing() {
    echo -e "\n${COLOR_BOLD}==============================================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}         CNCF KCSA LAB 2.6: KUBE-PROXY BREAK & FIX CHALLENGE${COLOR_RESET}"
    echo -e "${COLOR_BOLD}==============================================================================${COLOR_RESET}\n"

    echo -e "${COLOR_BOLD}ARCHITECTURAL OVERVIEW:${COLOR_RESET}"
    echo -e "Kube-Proxy is a core Kubernetes network component running on each node. It watches the"
    echo -e "Kubernetes Control Plane (API Server) for Service and EndpointSlice object state updates,"
    echo -e "translating high-level Service abstractions into low-level host kernel routing rules"
    echo -e "(via iptables, IPVS, or nftables datapath drivers).\n"
    echo -e "From a security perspective (KCSA domain), Kube-Proxy must:"
    echo -e "  1. Authenticate with dedicated, least-privilege RBAC bindings (system:node-proxier)."
    echo -e "  2. Protect host interfaces by binding telemetry/health endpoints (e.g. 10249) strictly to 127.0.0.1."
    echo -e "  3. Maintain valid datapath sync without leaking traffic or dropping Service VIP mapping rules.\n"

    echo -e "${COLOR_BOLD}OBSERVED SYMPTOMS:${COLOR_RESET}"
    echo -e "  ${COLOR_RED}*${COLOR_RESET} East-West Pod-to-Service routing is failing across the cluster."
    echo -e "  ${COLOR_RED}*${COLOR_RESET} Applications cannot connect to ClusterIP VIPs (e.g. http://echo-service.${TEST_NS}.svc)."
    echo -e "  ${COLOR_RED}*${COLOR_RESET} Kube-Proxy pods in namespace 'kube-system' are emitting error logs or failing to reconcile datapath states."
    echo -e "  ${COLOR_RED}*${COLOR_RESET} Security audit flags insecure listener binding on node network interfaces.\n"

    echo -e "${COLOR_BOLD}STUDENT OBJECTIVES:${COLOR_RESET}"
    echo -e "  1. ${COLOR_YELLOW}Diagnose Kube-Proxy Control Plane integration:${COLOR_RESET} Identify why Kube-Proxy cannot receive API Server event streams."
    echo -e "  2. ${COLOR_YELLOW}Remediate RBAC Least-Privilege Policies:${COLOR_RESET} Restore correct API rules for 'system:node-proxier' ClusterRole."
    echo -e "  3. ${COLOR_YELLOW}Fix Kube-Proxy Configuration:${COLOR_RESET} Correct invalid datapath configuration modes and lock down metric endpoint exposure."
    echo -e "  4. ${COLOR_YELLOW}Validate Routing & Security:${COLOR_RESET} Confirm East-West traffic to 'echo-service.${TEST_NS}' succeeds.\n"

    echo -e "${COLOR_BOLD}DIAGNOSTIC COMMANDS TO START WITH:${COLOR_RESET}"
    echo -e "  $ kubectl get pods -n kube-system -l k8s-app=kube-proxy"
    echo -e "  $ kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=50"
    echo -e "  $ kubectl auth can-i list endpointslices --as=system:serviceaccount:kube-system:kube-proxy"
    echo -e "  $ kubectl exec -it -n ${TEST_NS} deployment/client-tester -- curl -m 3 http://echo-service\n"

    echo -e "${COLOR_BOLD}==============================================================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}To inspect the step-by-step resolution, read the commented section at the end of this script file.${COLOR_RESET}"
    echo -e "${COLOR_BOLD}==============================================================================${COLOR_RESET}\n"
}

main() {
    check_prerequisites
    create_backups
    inject_breakage
    print_student_briefing
}

main "$@"

# ==============================================================================
# STEP-BY-STEP SOLUTION GUIDE (CNCF KCSA STUDENT REFERENCE)
# ==============================================================================
#
# --- STEP 1: ROOT CAUSE ANALYSIS & DIAGNOSTICS ---
# 
# 1.1 Verify Service connectivity failure from the client pod:
#     $ CLIENT_POD=$(kubectl get pod -n kcsa-kubeproxy-lab -l app=client-tester -o jsonpath='{.items[0].metadata.name}')
#     $ kubectl exec -n kcsa-kubeproxy-lab "${CLIENT_POD}" -- curl -v http://echo-service.kcsa-kubeproxy-lab.svc:80
#     Expected Output: Connection timeout or connection refused (ClusterIP VIP is not programmed into node kernel iptables/IPVS).
#
# 1.2 Inspect Kube-Proxy container logs in kube-system namespace:
#     $ kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=100
#     Expected Log Output:
#     E0807 19:40:12.123456 1 reflector.go:140] pkg/mod/k8s.io/client-go@v0.29.0/tools/cache/reflector.go:140:
#     Failed to watch *v1.EndpointSlice: failed to list *v1.EndpointSlice: endpointslices.discovery.k8s.io is forbidden:
#     User "system:serviceaccount:kube-system:kube-proxy" cannot list resource "endpointslices" in API group "discovery.k8s.io"
#
# 1.3 Test RBAC authorizations using 'kubectl auth can-i':
#     $ kubectl auth can-i list endpointslices --as=system:serviceaccount:kube-system:kube-proxy
#     Output: no
#     $ kubectl auth can-i list services --as=system:serviceaccount:kube-system:kube-proxy
#     Output: no
#
# 1.4 Inspect ClusterRole system:node-proxier configuration:
#     $ kubectl get clusterrole system:node-proxier -o yaml
#     Observation: Rules list only 'nodes', missing 'services', 'endpoints', and 'endpointslices'.
#
# 1.5 Inspect Kube-Proxy ConfigMap for security vulnerabilities:
#     $ kubectl get cm kube-proxy -n kube-system -o yaml
#     Observation: metricsBindAddress set to 0.0.0.0:10249 (exposes metrics publicly on host network without authn/authz).
#                  mode might be misconfigured (e.g. invalid-mode).
#
# --- STEP 2: REMEDIATION & REPAIR ---
#
# 2.1 Restore proper RBAC permissions to ClusterRole 'system:node-proxier':
#     Apply the syntactically valid ClusterRole manifest below:
#
#     cat <<EOF | kubectl apply -f -
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRole
# metadata:
#   name: system:node-proxier
# rules:
# - apiGroups: [""]
#   resources:
#   - endpoints
#   - services
#   - nodes
#   verbs: ["get", "list", "watch"]
# - apiGroups: ["discovery.k8s.io"]
#   resources:
#   - endpointslices
#   verbs: ["get", "list", "watch"]
# - apiGroups: [""]
#   resources:
#   - events
#   verbs: ["create", "patch", "update"]
# EOF
#
# 2.2 Re-verify RBAC permissions:
#     $ kubectl auth can-i list endpointslices --as=system:serviceaccount:kube-system:kube-proxy
#     Output: yes
#     $ kubectl auth can-i list services --as=system:serviceaccount:kube-system:kube-proxy
#     Output: yes
#
# 2.3 Fix Kube-Proxy ConfigMap (Restore mode and secure metrics listener):
#     $ kubectl get cm kube-proxy -n kube-system -o yaml > /tmp/kp-fix.yaml
#     Edit /tmp/kp-fix.yaml:
#       Set 'metricsBindAddress: 127.0.0.1:10249' (Securing KCSA telemetry boundary)
#       Set 'mode: "iptables"' (or "ipvs")
#     $ kubectl apply -f /tmp/kp-fix.yaml
#
# 2.4 Restart Kube-Proxy DaemonSet to apply changes:
#     $ kubectl rollout restart daemonset kube-proxy -n kube-system
#     $ kubectl rollout status daemonset kube-proxy -n kube-system
#
# --- STEP 3: POST-REMEDIATION VERIFICATION ---
#
# 3.1 Verify Kube-Proxy logs are clean:
#     $ kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=50
#     Expected Output: "Successfully synchronized rules" / "Adding service" without 403 Forbidden errors.
#
# 3.2 Validate East-West Service traffic resolution:
#     $ CLIENT_POD=$(kubectl get pod -n kcsa-kubeproxy-lab -l app=client-tester -o jsonpath='{.items[0].metadata.name}')
#     $ kubectl exec -n kcsa-kubeproxy-lab "${CLIENT_POD}" -- curl -s -m 5 http://echo-service.kcsa-kubeproxy-lab.svc:80
#     Expected Output: Successful HTTP response from agnhost netexec server.
#
# 3.3 Cleanup lab resources when finished:
#     $ kubectl delete namespace kcsa-kubeproxy-lab
#     $ rm -rf /tmp/kcsa-kubeproxy-lab-backup /tmp/kp-fix.yaml
# ==============================================================================