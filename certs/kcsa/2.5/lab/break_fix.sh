#!/usr/bin/env bash
# ==============================================================================
# KCSA Certification Practice Lab - Topic 2.5: Container Runtime Security
# Scenario: Broken Containerd CRI Security Profile & Default Runtime Spec
#
# Target Exam: KCSA (Kubernetes and Cloud Native Security Associate)
# Curriculum Topic 2.5: Container Runtime (Security profiles, CRI, containerd)
# Official Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# ==============================================================================

set -euo pipefail

RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] This script must be executed with root privileges (sudo).${NC}" >&2
   exit 1
fi

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} KCSA Lab 2.5: Container Runtime Security - Injecting Failure...      ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# 1. Backup existing containerd configuration if available
CONTAINERD_CONFIG="/etc/containerd/config.toml"
BACKUP_CONFIG="/etc/containerd/config.toml.bak.kcsa"

if [[ -f "$CONTAINERD_CONFIG" ]]; then
    cp "$CONTAINERD_CONFIG" "$BACKUP_CONFIG"
    echo -e "${GREEN}[+] Backed up original $CONTAINERD_CONFIG to $BACKUP_CONFIG${NC}"
else
    mkdir -p /etc/containerd
    containerd config default > "$BACKUP_CONFIG" 2>/dev/null || true
    echo -e "${GREEN}[+] Created baseline backup at $BACKUP_CONFIG${NC}"
fi

# 2. Inject misconfiguration into containerd config.toml
# We simulate a broken default seccomp profile reference and invalid CRI runtime spec path
cat << 'EOF' > "$CONTAINERD_CONFIG"
version = 2

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.9"
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
            BinaryName = "/usr/bin/runc"
    [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime]
      base_runtime_spec = "/etc/containerd/nonexistent_hardened_seccomp.json"
EOF

echo -e "${YELLOW}[!] Modified containerd CRI plugin config to reference invalid base_runtime_spec.${NC}"

# 3. Restart containerd service if active
if systemctl is-active --quiet containerd 2>/dev/null; then
    systemctl restart containerd || true
    echo -e "${GREEN}[+] Restarted containerd service.${NC}"
else
    echo -e "${YELLOW}[!] containerd service is not running or not managed by systemd. Please restart manually if needed.${NC}"
fi

# 4. Generate test workload manifest
TEST_POD_MANIFEST="/tmp/kcsa-runtime-test-pod.yaml"
cat << 'EOF' > "$TEST_POD_MANIFEST"
apiVersion: v1
kind: Pod
metadata:
  name: hardened-app-test
  namespace: default
  labels:
    app: secure-workload
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test-container
    image: registry.k8s.io/e2e-test-images/agnhost:2.40
    args: ["pause"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
EOF

echo -e "${GREEN}[+] Generated test Pod manifest at $TEST_POD_MANIFEST${NC}"

# Attempt to apply Pod if kubectl is available
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    kubectl delete pod hardened-app-test --now 2>/dev/null || true
    kubectl apply -f "$TEST_POD_MANIFEST" 2>/dev/null || true
fi

echo -e "\n${RED}======================================================================${NC}"
echo -e "${RED} LAB BREAKAGE COMPLETE - STUDENT INSTRUCTIONS                         ${NC}"
echo -e "${RED}======================================================================${NC}"
echo -e "Scenario: A cluster node is rejecting new container creations."
echo -e "The Security Operations team reported that workloads specifying seccomp"
echo -e "or default CRI security profiles fail to start on this node."
echo -e ""
echo -e "${YELLOW}SYMPTOMS TO OBSERVE:${NC}"
echo -e " 1. Pods remain stuck in 'CreateContainerError' or 'ContainerCreating'."
echo -e " 2. 'kubectl describe pod hardened-app-test' shows failure during sandbox/container creation."
echo -e " 3. Container runtime logs ('journalctl -u containerd -n 50') display CRI plugin errors."
echo -e ""
echo -e "${YELLOW}YOUR GOAL:${NC}"
echo -e " 1. Investigate the container runtime (containerd) configuration."
echo -e " 2. Identify the misconfigured CRI security profile spec path in /etc/containerd/config.toml."
echo -e " 3. Fix the configuration file and restart containerd."
echo -e " 4. Ensure the test pod ('hardened-app-test') reaches the Running state."
echo -e "${RED}======================================================================${NC}\n"

exit 0

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (COMMENTED OUT)
# ==============================================================================
#
# STEP 1: Diagnose the Pod Failure
# ------------------------------------------------------------------------------
# Check the pod status in Kubernetes:
#   $ kubectl get pod hardened-app-test
#   NAME                READY   STATUS                 RESTARTS   AGE
#   hardened-app-test   0/1     CreateContainerError   0          45s
#
# Inspect the events for exact error messages:
#   $ kubectl describe pod hardened-app-test
# Look for output similar to:
#   Events:
#     Type     Reason     Age                From               Message
#     ----     ------     ----               ----               -------
#     Warning  Failed     10s (x3 over 30s)  kubelet            Failed to create pod sandbox: rpc error: code = Unknown desc = failed to load base runtime spec: open /etc/containerd/nonexistent_hardened_seccomp.json: no such file or directory
#
# STEP 2: Inspect Container Runtime Logs & Configuration
# ------------------------------------------------------------------------------
# View containerd systemd service logs:
#   $ journalctl -u containerd -n 50 --no-pager
# Notice errors regarding CRI base_runtime_spec loading.
#
# Inspect containerd config file:
#   $ cat /etc/containerd/config.toml
# Locate the broken section under [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime]:
#   base_runtime_spec = "/etc/containerd/nonexistent_hardened_seccomp.json"
#
# STEP 3: Remediate the Container Runtime Configuration
# ------------------------------------------------------------------------------
# Option A: Restore from backup (if created during lab setup):
#   $ sudo cp /etc/containerd/config.toml.bak.kcsa /etc/containerd/config.toml
#
# Option B: Edit /etc/containerd/config.toml manually:
# Remove or comment out the invalid base_runtime_spec directive, or set default config:
#   $ sudo containerd config default | sudo tee /etc/containerd/config.toml
#
# Ensure systemd_cgroup is enabled if required by kubelet:
#   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
#     SystemdCgroup = true
#
# STEP 4: Restart Service & Verify Workload
# ------------------------------------------------------------------------------
# Restart containerd daemon:
#   $ sudo systemctl restart containerd
#
# Re-check pod status:
#   $ kubectl delete pod hardened-app-test --now
#   $ kubectl apply -f /tmp/kcsa-runtime-test-pod.yaml
#   $ kubectl get pod hardened-app-test -w
#
# Verify pod reaches 'Running' status:
#   NAME                READY   STATUS    RESTARTS   AGE
#   hardened-app-test   1/1     Running   0          12s
# ==============================================================================