#!/usr/bin/env bash

# ==============================================================================
# LPI DevOps Tools Engineer (701-100) - Topic 2.1: Container Usage
# Production Break & Fix SRE Lab Scenario
#
# Exam Topic Weight: 11.67
# Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# Reference: https://wiki.lpi.org/wiki/LPIC-OT_Topic_701
# ==============================================================================
#
# INSTRUCTIONS FOR THE INSTRUCTOR / STUDENT:
# Run this script without arguments to setup the broken environment:
#   $ chmod +x break_and_fix_2_1.sh
#   $ ./break_and_fix_2_1.sh
#
# To verify if your fix is successful:
#   $ ./break_and_fix_2_1.sh verify
#
# To clean up the environment:
#   $ ./break_and_fix_2_1.sh cleanup
# ==============================================================================

set -euo pipefail

CONTAINER_NAME="cart-service-prod"
NETWORK_NAME="ecommerce-bridge"
DATA_DIR="/var/tmp/cart-service-data"
HOST_PORT="8080"
EXPECTED_USER="1001"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC} $1"; }

check_prerequisites() {
    log_info "Checking lab prerequisites..."
    if ! command -v docker &>/dev/null; then
        log_error "Docker CLI is not installed or not in PATH."
        exit 1
    fi
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running or current user lacks socket permissions."
        exit 1
    fi
}

cleanup_lab() {
    log_info "Cleaning up existing lab artifacts..."
    docker rm -f "${CONTAINER_NAME}" &>/dev/null || true
    docker network rm "${NETWORK_NAME}" &>/dev/null || true
    rm -rf "${DATA_DIR}" &>/dev/null || true
    log_pass "Cleanup completed."
}

setup_broken_scenario() {
    cleanup_lab

    log_info "Injecting controlled production defect for Topic 2.1..."

    # Create host bind directory and payload
    mkdir -p "${DATA_DIR}"
    echo "<h1>Cart Service Operational - Version 2.1.0</h1>" > "${DATA_DIR}/index.html"
    
    # INTENTIONAL BUG 1: File permissions set to 0700 owned by root:root.
    # The container will run under non-root UID 1001, causing EACCES (Permission Denied).
    chown -R root:root "${DATA_DIR}"
    chmod 0700 "${DATA_DIR}"

    # Create custom bridge network
    docker network create --driver bridge "${NETWORK_NAME}" &>/dev/null

    # INTENTIONAL BUG 2 & 3:
    # - Port mapping mismatch: Host 8080 mapped to Container 8080 (-p 8080:8080),
    #   but Nginx inside container listens on standard port 80.
    # - Low memory cgroup limit: --memory=4m causes cgroup OOM termination upon request processing.
    # - Running as non-root user 1001:1001 (Security requirement, but triggers BUG 1).
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --network "${NETWORK_NAME}" \
        --user "${EXPECTED_USER}:${EXPECTED_USER}" \
        --memory="4m" \
        -p "${HOST_PORT}:${HOST_PORT}" \
        -v "${DATA_DIR}:/usr/share/nginx/html:ro" \
        --restart always \
        nginx:alpine &>/dev/null

    sleep 2

    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${CYAN}  LPI DevOps (701-100) Topic 2.1: Container Usage - SRE Incident Lab   ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo
    echo -e "${YELLOW}[INCIDENT DESCRIPTION]${NC}"
    echo "The production container '${CONTAINER_NAME}' was deployed by an automated pipeline."
    echo "The monitoring system reports that 'http://localhost:${HOST_PORT}' is failing."
    echo "SRE Security Policy mandates that containers MUST run as unprivileged user (UID ${EXPECTED_USER})."
    echo
    echo -e "${YELLOW}[SYMPTOMS REPORTED]${NC}"
    echo " 1. Executing 'curl http://localhost:${HOST_PORT}' returns Connection Refused, 403 Forbidden, or fails."
    echo " 2. Container inspection reveals crashes, restart loops, or HTTP access errors."
    echo
    echo -e "${YELLOW}[STUDENT OBJECTIVES]${NC}"
    echo " Analyze the running/stopped container using Docker CLI tools:"
    echo "   - 'docker ps', 'docker inspect', 'docker logs', 'docker port'"
    echo " Fix all root causes so that:"
    echo "   a) 'curl -s http://localhost:${HOST_PORT}' returns 'Cart Service Operational'."
    echo "   b) Container runs as non-root UID ${EXPECTED_USER} without EACCES errors."
    echo "   c) Container memory cgroup limits allow stable Nginx execution (>= 32m)."
    echo "   d) Container port mapping correctly forwards host port ${HOST_PORT} to container port 80."
    echo
    echo -e "${YELLOW}[VERIFICATION]${NC}"
    echo " When you believe the issue is resolved, execute:"
    echo "   $ ./break_and_fix_2_1.sh verify"
    echo -e "${CYAN}========================================================================${NC}"
}

verify_solution() {
    log_info "Executing automated verification suite..."
    local errors=0

    # Test 1: Container existence and running state
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Verification Failed: Container '${CONTAINER_NAME}' is not running."
        ((errors++))
    else
        log_pass "Check 1: Container '${CONTAINER_NAME}' is active."
    fi

    # Test 2: Check security compliance (User UID 1001)
    if [ $errors -eq 0 ]; then
        local running_user
        running_user=$(docker inspect --format '{{.Config.User}}' "${CONTAINER_NAME}")
        if [[ "${running_user}" != "${EXPECTED_USER}:${EXPECTED_USER}" && "${running_user}" != "${EXPECTED_USER}" ]]; then
            log_error "Verification Failed: Container user is '${running_user}'. SRE Policy requires UID '${EXPECTED_USER}'."
            ((errors++))
        else
            log_pass "Check 2: Security compliance satisfied (Running as UID ${EXPECTED_USER})."
        fi
    fi

    # Test 3: Check memory limits (>= 32MB)
    if [ $errors -eq 0 ]; then
        local mem_bytes
        mem_bytes=$(docker inspect --format '{{.HostConfig.Memory}}' "${CONTAINER_NAME}")
        # 33554432 bytes = 32MB
        if [ "${mem_bytes}" -lt 33554432 ] && [ "${mem_bytes}" -ne 0 ]; then
            log_error "Verification Failed: Memory limit (${mem_bytes} bytes) is too restrictive for stable execution."
            ((errors++))
        else
            log_pass "Check 3: Memory cgroup limits adequately allocated."
        fi
    fi

    # Test 4: Check HTTP endpoint response
    if [ $errors -eq 0 ]; then
        local http_response
        http_response=$(curl -s --max-time 3 "http://localhost:${HOST_PORT}" || true)
        if echo "${http_response}" | grep -q "Cart Service Operational"; then
            log_pass "Check 4: HTTP GET http://localhost:${HOST_PORT} returned valid payload."
        else
            log_error "Verification Failed: HTTP GET returned unexpected output: '${http_response}'"
            ((errors++))
        fi
    fi

    echo
    if [ $errors -eq 0 ]; then
        echo -e "${GREEN}========================================================================${NC}"
        echo -e "${GREEN}  SUCCESS: You have resolved all issues in Topic 2.1 Container Usage!   ${NC}"
        echo -e "${GREEN}========================================================================${NC}"
        exit 0
    else
        echo -e "${RED}========================================================================${NC}"
        echo -e "${RED}  FAIL: Scenario remains broken. Keep inspecting docker logs/inspect!   ${NC}"
        echo -e "${RED}========================================================================${NC}"
        exit 1
    fi
}

# Main Execution Routing
check_prerequisites

case "${1:-setup}" in
    setup|break)
        setup_broken_scenario
        ;;
    verify|--verify)
        verify_solution
        ;;
    cleanup|--cleanup)
        cleanup_lab
        ;;
    *)
        echo "Usage: $0 {setup|verify|cleanup}"
        exit 1
        ;;
esac

# ==============================================================================
# DISCORD / INSTRUCTOR STEP-BY-STEP SOLUTION (COMMENTED OUT)
# ==============================================================================
#
# STEP 1: DIAGNOSE THE INCIDENT
# ------------------------------------------------------------------------------
# A) Check running container status and port mappings:
#    $ docker ps -a --filter "name=cart-service-prod"
#    Output shows container created, but curl http://localhost:8080 fails.
#
# B) Inspect container networking and port bindings:
#    $ docker port cart-service-prod
#    Output: 8080/tcp -> 0.0.0.0:8080
#    $ docker inspect cart-service-prod --format '{{json .HostConfig.PortBindings}}'
#    ROOT CAUSE A: Nginx inside the image listens on port 80, but host port 8080
#    was bound to container port 8080 instead of container port 80 (-p 8080:80).
#
# C) Inspect container logs:
#    $ docker logs cart-service-prod
#    Output: 2026/08/07 [error] ... "/usr/share/nginx/html/index.html" failed (13: Permission denied)
#    ROOT CAUSE B: Host directory /var/tmp/cart-service-data permissions are 0700 owned by root.
#    Since container runs as UID 1001 (--user 1001:1001), it receives EACCES when accessing mounted HTML files.
#
# D) Inspect resource limits:
#    $ docker inspect cart-service-prod --format '{{.HostConfig.Memory}}'
#    Output: 4194304 (4MB)
#    ROOT CAUSE C: Extremely low memory allocation (4MB) triggers cgroup OOMKilled
#    when worker processes fork.
#
# STEP 2: APPLY THE SRE PRODUCTION FIX
# ------------------------------------------------------------------------------
# 1) Fix host volume permissions so UID 1001 can read directory and files:
#    $ sudo chmod 0755 /var/tmp/cart-service-data
#    $ sudo chmod 0644 /var/tmp/cart-service-data/index.html
#    (Alternatively, chown to 1001:1001: $ sudo chown -R 1001:1001 /var/tmp/cart-service-data)
#
# 2) Stop and remove the broken container:
#    $ docker rm -f cart-service-prod
#
# 3) Re-deploy container with corrected port mapping (-p 8080:80) and memory (--memory=64m):
#    $ docker run -d \
#        --name cart-service-prod \
#        --network ecommerce-bridge \
#        --user 1001:1001 \
#        --memory="64m" \
#        -p 8080:80 \
#        -v /var/tmp/cart-service-data:/usr/share/nginx/html:ro \
#        --restart always \
#        nginx:alpine
#
# STEP 3: VERIFY THE FIX
# ------------------------------------------------------------------------------
#    $ curl -s http://localhost:8080
#    Output: <h1>Cart Service Operational - Version 2.1.0</h1>
#
#    $ ./break_and_fix_2_1.sh verify
# ==============================================================================