#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 305 (Exam 305-300 v3.0) - Topic 1.2: Container Virtualization
# Lab Scenario: Production Break & Fix - Container Runtime & Daemon Failure
#
# Target Audience: SRE / Platform Engineers preparing for LPIC-3 305 & CNCF CKA/CKS
# References:
#   - https://www.lpi.org/our-certifications/lpic-3-305-overview/
#   - https://docs.docker.com/engine/reference/commandline/dockerd/
#   - https://docs.docker.com/config/daemon/
#   - https://kubernetes.io/docs/setup/production-environment/container-runtimes/
# ==============================================================================

set -euo pipefail

# Visual Formatting Helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BACKUP_DIR="/var/tmp/lpic3_305_lab_backup_$(date +%s)"

print_banner() {
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${BLUE}  LPIC-3 305 (305-300 v3.0) Topic 1.2: Container Virtualization Lab   ${NC}"
    echo -e "${BLUE}======================================================================${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed as root (sudo).${NC}" >&2
        exit 1
    fi
}

check_prerequisites() {
    echo -e "${YELLOW}[*] Checking prerequisites...${NC}"
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}[!] Docker Engine is not installed. Installing docker.io / docker-ce...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y -qq docker.io
        elif command -v dnf &> /dev/null; then
            dnf install -y docker
        elif command -v yum &> /dev/null; then
            yum install -y docker
        else
            echo -e "${RED}[ERROR] Package manager not supported. Please install Docker manually.${NC}" >&2
            exit 1
        fi
    fi

    if ! command -v systemctl &> /dev/null; then
        echo -e "${RED}[ERROR] systemd is required for this lab scenario.${NC}" >&2
        exit 1
    fi
}

create_backups() {
    echo -e "${YELLOW}[*] Creating configuration backups in ${BACKUP_DIR}...${NC}"
    mkdir -p "${BACKUP_DIR}"

    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json "${BACKUP_DIR}/daemon.json.orig"
    fi

    if [[ -d /etc/systemd/system/docker.service.d ]]; then
        cp -r /etc/systemd/system/docker.service.d "${BACKUP_DIR}/docker.service.d.orig"
    fi

    if [[ -f /etc/sysctl.d/99-kubernetes-cri.conf ]]; then
        cp /etc/sysctl.d/99-kubernetes-cri.conf "${BACKUP_DIR}/99-kubernetes-cri.conf.orig"
    fi
}

apply_breakage() {
    echo -e "${YELLOW}[*] Injecting production breakages...${NC}"

    # 1. Inject JSON syntax error and conflicting flags into /etc/docker/daemon.json
    mkdir -p /etc/docker
    cat << 'EOF' > /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "bip": "172.18.0.1/16",
  "default-address-pools": [
    {"base": "172.80.0.0/16", "size": 24}
  ],
}
EOF

    # 2. Inject conflicting command-line flags in systemd drop-in unit file
    mkdir -p /etc/systemd/system/docker.service.d
    cat << 'EOF' > /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock --exec-opt native.cgroupdriver=cgroupfs --storage-driver=vfs
EOF

    # 3. Disable IPv4 packet forwarding at kernel level to break container networking
    echo "net.ipv4.ip_forward=0" > /etc/sysctl.d/99-container-lab-breakage.conf
    sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1 || true

    # 4. Reload systemd daemon and attempt to restart docker service to trigger failure
    systemctl daemon-reload
    systemctl restart docker.service > /dev/null 2>&1 || true

    echo -e "${RED}[!] Breakage successfully applied!${NC}"
}

print_student_instructions() {
    echo ""
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN}                        LAB SCENARIO SUMMARY                          ${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${YELLOW}Topic:${NC} LPIC-3 305 - 1.2 Container Virtualization (Runtime & Daemon Mechanics)"
    echo -e "${YELLOW}Status:${NC} The production container runtime has crashed and failed to restart."
    echo ""
    echo -e "${RED}OBSERVED SYMPTOMS:${NC}"
    echo "  1. 'systemctl status docker' reports service activation failure (Exit Code / Failed)."
    echo "  2. Running 'docker ps' or 'docker info' fails with API connection error."
    echo "  3. Running containers cannot communicate across networks or route traffic externally."
    echo ""
    echo -e "${GREEN}YOUR MISSION / GOALS:${NC}"
    echo "  Goal 1: Identify and resolve syntax errors in '/etc/docker/daemon.json'."
    echo "  Goal 2: Resolve conflict between systemd drop-in override flags and '/etc/docker/daemon.json'."
    echo "          Ensure systemd cgroup driver ('native.cgroupdriver=systemd') and 'overlay2' storage driver are active."
    echo "  Goal 3: Restore Linux kernel networking parameters (net.ipv4.ip_forward=1) for container routing."
    echo "  Goal 4: Verify Docker daemon starts cleanly and passes 'docker info' sanity checks."
    echo ""
    echo -e "${BLUE}DIAGNOSTIC HINTS / TOOLS TO USE:${NC}"
    echo "  - systemctl status docker.service"
    echo "  - journalctl -u docker.service -e -n 50 --no-pager"
    echo "  - dockerd --config-file /etc/docker/daemon.json --validate (or manual JSON validation)"
    echo "  - sysctl net.ipv4.ip_forward"
    echo "  - docker info | grep -E '(Cgroup Driver|Storage Driver)'"
    echo ""
    echo -e "${GREEN}======================================================================${NC}"
}

main() {
    print_banner
    check_root
    check_prerequisites
    create_backups
    apply_breakage
    print_student_instructions
}

main "$@"

# ==============================================================================
#                      STEP-BY-STEP SOLUTION (DO NOT READ UNTIL ATTEMPTED)
# ==============================================================================
#
# TROUBLESHOOTING WORKFLOW & DIAGNOSTICS:
#
# Step 1: Diagnose the systemd unit failure
#   $ sudo systemctl status docker.service
#   $ sudo journalctl -u docker.service -n 30 --no-pager
#
#   Expected Log Error 1:
#   "unable to configure the Docker daemon with file /etc/docker/daemon.json: invalid character '}' looking for beginning of object key string"
#   Reason: Trailing comma on line 11 of /etc/docker/daemon.json makes it invalid JSON.
#
# Step 2: Fix JSON Syntax Error in /etc/docker/daemon.json
#   Edit /etc/docker/daemon.json and remove the trailing comma after the array:
#
#   Correct content for /etc/docker/daemon.json:
#   {
#     "exec-opts": ["native.cgroupdriver=systemd"],
#     "log-driver": "json-file",
#     "log-opts": {
#       "max-size": "100m"
#     },
#     "storage-driver": "overlay2",
#     "bip": "172.18.0.1/16",
#     "default-address-pools": [
#       {"base": "172.80.0.0/16", "size": 24}
#     ]
#   }
#
# Step 3: Test service restart after JSON fix
#   $ sudo systemctl restart docker.service
#   $ sudo journalctl -u docker.service -n 30 --no-pager
#
#   Expected Log Error 2:
#   "unable to configure the Docker daemon with file /etc/docker/daemon.json: the following directives are specified both as a flag and in the configuration file: exec-opts: (from flag: [native.cgroupdriver=cgroupfs], from file: [native.cgroupdriver=systemd]), storage-driver: (from flag: vfs, from file: overlay2)"
#   Reason: systemd drop-in override (/etc/systemd/system/docker.service.d/override.conf) defines CLI flags that conflict with daemon.json options.
#
# Step 4: Fix systemd drop-in configuration conflict
#   Inspect the drop-in file:
#   $ cat /etc/systemd/system/docker.service.d/override.conf
#
#   Option A: Remove conflicting flags from override.conf:
#   $ sudo rm -rf /etc/systemd/system/docker.service.d/override.conf
#
#   Option B: Edit override.conf to keep standard ExecStart without duplicate storage/cgroup flags:
#   $ sudo bash -c 'cat << EOF > /etc/systemd/system/docker.service.d/override.conf
#   [Service]
#   ExecStart=
#   ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
#   EOF'
#
#   Reload systemd manager configuration:
#   $ sudo systemctl daemon-reload
#
# Step 5: Start Docker service and verify status
#   $ sudo systemctl restart docker.service
#   $ sudo systemctl status docker.service
#
# Step 6: Diagnose and fix Kernel IPv4 Forwarding (Networking Goal)
#   Check current kernel parameter:
#   $ sysctl net.ipv4.ip_forward
#   Output: net.ipv4.ip_forward = 0
#
#   Enable IPv4 forwarding immediately and persistently:
#   $ sudo rm -f /etc/sysctl.d/99-container-lab-breakage.conf
#   $ sudo bash -c 'echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-kubernetes-cri.conf'
#   $ sudo sysctl --system
#
# Step 7: Final Verification & Sanity Checks
#   $ sudo docker info | grep -E '(Cgroup Driver|Storage Driver|Logging Driver)'
#   Expected output:
#     Logging Driver: json-file
#     Cgroup Driver: systemd
#     Storage Driver: overlay2
#
#   Test container execution and outbound network connectivity:
#   $ sudo docker run --rm alpine ping -c 3 8.8.8.8
#   Expected output: 3 packets transmitted, 3 received, 0% packet loss.
# ==============================================================================