#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (701-100 v1.0) - Practice Lab Break & Fix Script
# Topic 2.3: Container Infrastructure (Weight: 6.67)
# Target Environment: Disposable Linux Lab VM (Ubuntu 22.04 / Debian 12 / RHEL 9)
# Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# Official Docker Documentation: https://docs.docker.com/engine/daemon/
# Official OCI / Networking Docs: https://docs.docker.com/engine/network/
# ==============================================================================
#
# PURPOSE:
# This script injects realistic, production-grade failures into the local
# container infrastructure (Docker Daemon, iptables forwarding, sysctl kernel
# parameters, custom bridge network DNS, and storage volume permissions).
# 
# WARNING: Run this script ONLY on a disposable lab virtual machine.
# ==============================================================================

set -euo pipefail

# Style definitions
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOG_FILE="/var/log/break_and_fix_lab.log"

log() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be executed as root. Run: sudo $0"
    fi

    if ! command -v docker &> /dev/null; then
        error "Docker CLI is not installed. Please install Docker Engine prior to running this lab."
    fi

    if ! systemctl is-active --quiet docker; then
        error "Docker daemon service is not active. Start Docker with: systemctl start docker"
    fi
}

setup_lab_infrastructure() {
    log "Initializing lab container infrastructure..."

    # Cleanup existing lab artifacts if re-run
    docker rm -f prod-api prod-db &>/dev/null || true
    docker network rm prod-bridge &>/dev/null || true
    rm -rf /var/lib/prod-data
    rm -f /etc/docker/daemon.json.bak

    # Create persistent volume directory
    mkdir -p /var/lib/prod-data/db
    echo "db_initialized=true" > /var/lib/prod-data/db/status.conf

    # Create isolated user-defined bridge network
    docker network create \
        --driver bridge \
        --subnet 172.28.0.0/16 \
        --gateway 172.28.0.1 \
        prod-bridge >/dev/null

    # Run Database Container
    docker run -d \
        --name prod-db \
        --network prod-bridge \
        --ip 172.28.0.10 \
        -v /var/lib/prod-data/db:/var/lib/db \
        alpine:3.19 sh -c "while true; do sleep 3600; done" >/dev/null

    # Run API Gateway Container
    docker run -d \
        --name prod-api \
        --network prod-bridge \
        --ip 172.28.0.20 \
        alpine:3.19 sh -c "while true; do sleep 3600; done" >/dev/null

    log "Lab container infrastructure deployed successfully."
}

inject_infrastructure_breakages() {
    log "Injecting controlled production outages into container infrastructure..."

    # 1. Daemon Level: Inject misconfigured cgroup driver and looping loopback DNS server
    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
    fi

    cat <<'EOF' > /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "dns": ["127.0.0.1"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF

    # 2. Kernel Level: Disable IPv4 forwarding globally
    sysctl -w net.ipv4.ip_forward=0 >/dev/null

    # 3. Network Filter Level: Drop forwarded packets originating from the lab bridge interface
    BRIDGE_IFACE=$(docker network inspect prod-bridge --format 'br-{{.Id}}' | cut -c 1-15)
    iptables -I FORWARD 1 -i "$BRIDGE_IFACE" -j DROP
    iptables -I FORWARD 1 -o "$BRIDGE_IFACE" -j DROP

    # 4. Storage Level: Break volume mounts by breaking host directory permissions
    chmod 000 /var/lib/prod-data/db

    # Restart Docker Daemon to pick up daemon.json corruption
    log "Restarting Docker Engine to commit state changes..."
    systemctl restart docker || true

    log "Outage injection completed."
}

display_challenge_brief() {
    echo -e "\n================================================================================"
    echo -e "${BOLD}${RED}INCIDENT REPORT: CRITICAL CONTAINER INFRASTRUCTURE OUTAGE${NC}"
    echo -e "================================================================================"
    echo -e "System Administrator: An automated configuration deployment introduced multiple"
    echo -e "cascading failures in the production container infrastructure."
    echo -e "\n${BOLD}OBSERVED SYMPTOMS:${NC}"
    echo -e " 1. ${YELLOW}DNS Resolution Failure:${NC} Containers on custom networks cannot resolve external DNS names"
    echo -e "    (e.g., running 'docker exec prod-api ping -c 1 google.com' fails with name resolution error)."
    echo -e " 2. ${YELLOW}Container Inter-communication Outage:${NC} Containers on 'prod-bridge' cannot route traffic"
    echo -e "    to each other or host (e.g., 'docker exec prod-api ping -c 1 172.28.0.10' times out)."
    echo -e " 3. ${YELLOW}Volume Access Denied:${NC} Applications fail to access mounted host storage volumes."
    echo -e " 4. ${YELLOW}Cgroup/Runtime Warning:${NC} Systemd logs report cgroup driver mismatch errors between"
    echo -e "    systemd init and Docker daemon execution options."
    echo -e "\n${BOLD}YOUR OBJECTIVES:${NC}"
    echo -e " [ ] Diagnose and fix the Docker Daemon configuration file (/etc/docker/daemon.json)."
    echo -e " [ ] Restore IPv4 packet forwarding at the Linux kernel layer."
    echo -e " [ ] Inspect and clear blocking iptables rules affecting bridge network traffic."
    echo -e " [ ] Fix host volume directory file permission bits without losing data."
    echo -e " [ ] Verify full container connectivity, DNS resolution, and storage access."
    echo -e "\n${BOLD}DIAGNOSTIC TOOLBOX:${NC}"
    echo -e " - docker info | grep -i cgroup"
    echo -e " - docker network inspect prod-bridge"
    echo -e " - sysctl net.ipv4.ip_forward"
    echo -e " - iptables -L FORWARD -v -n --line-numbers"
    echo -e " - journalctl -u docker.service -n 50 --no-pager"
    echo -e "================================================================================\n"
}

main() {
    check_prerequisites
    setup_lab_infrastructure
    inject_infrastructure_breakages
    display_challenge_brief
}

main "$@"

# ==============================================================================
#                      STEP-BY-STEP SOLUTION (SPOILER ALERT)
# ==============================================================================
# To resolve the incident, execute the following commands in sequence and verify:
#
# STEP 1: Fix Docker Daemon Configuration (/etc/docker/daemon.json)
# ------------------------------------------------------------------------------
# Problem: "dns": ["127.0.0.1"] forces container embedded DNS engine into a loop back
# to container loopback interface. "native.cgroupdriver=cgroupfs" conflicts with modern
# systemd cgroup v2 unified hierarchy.
#
# Execute:
# cat <<'EOF' > /etc/docker/daemon.json
# {
#   "exec-opts": ["native.cgroupdriver=systemd"],
#   "dns": ["8.8.8.8", "1.1.1.1"],
#   "log-driver": "json-file",
#   "log-opts": {
#     "max-size": "10m",
#     "max-file": "3"
#   },
#   "live-restore": true
# }
# EOF
#
# Reload daemon:
# systemctl restart docker
#
# STEP 2: Restore Kernel Packet Forwarding
# ------------------------------------------------------------------------------
# Problem: net.ipv4.ip_forward=0 prevents Linux kernel from routing packets between
# container bridge interfaces and physical host NICs.
#
# Execute:
# sysctl -w net.ipv4.ip_forward=1
# echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-docker-forward.conf
# sysctl --system
#
# STEP 3: Clear Blocking Netfilter / IPTables FORWARD Rules
# ------------------------------------------------------------------------------
# Problem: Explicit DROP rules placed in the FORWARD chain block packet flow on the bridge.
#
# Inspect rules:
# BRIDGE_IFACE=$(docker network inspect prod-bridge --format 'br-{{.Id}}' | cut -c 1-15)
# iptables -L FORWARD -v -n --line-numbers
#
# Delete the blocking rules (assuming rule numbers 1 and 2):
# iptables -D FORWARD -i "$BRIDGE_IFACE" -j DROP
# iptables -D FORWARD -o "$BRIDGE_IFACE" -j DROP
#
# Note: If iptables state remains corrupt, restart docker to auto-rebuild iptables chains:
# systemctl restart docker
#
# STEP 4: Fix Host Volume Storage Permissions
# ------------------------------------------------------------------------------
# Problem: Host directory permissions set to 000 deny read/write access to container processes.
#
# Execute:
# chmod 755 /var/lib/prod-data/db
#
# STEP 5: Verification & Validation Commands
# ------------------------------------------------------------------------------
# 1. Verify container-to-container routing:
#    docker exec prod-api ping -c 2 172.28.0.10
#
# 2. Verify external DNS resolution:
#    docker exec prod-api ping -c 2 google.com
#
# 3. Verify volume read access inside container:
#    docker exec prod-db cat /var/lib/db/status.conf
#
# 4. Verify cgroup driver status:
#    docker info | grep -i "Cgroup Driver"
#    (Expected Output: Cgroup Driver: systemd)
# ==============================================================================