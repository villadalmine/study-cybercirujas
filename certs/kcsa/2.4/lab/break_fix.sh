#!/usr/bin/env bash
# ==============================================================================
# CNCF KCSA (Kubernetes and Cloud Native Security Associate) Exam Prep
# Topic 2.4: Kubelet Security Architecture & Hardening
# Weight: 2.0%
# Reference: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
# Official K8s Doc: https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet-authentication-authorization/
# ==============================================================================
# Description: This script simulates an emergency security incident on a 
# Kubernetes node where Kubelet authentication and authorization settings have 
# been misconfigured, exposing unauthenticated endpoints and breaking API Server 
# control plane integration.
# ==============================================================================

set -euo pipefail

# Color definitions for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] This break script must be executed as root (sudo).${NC}" >&2
   exit 1
fi

echo -e "${BLUE}====================================================================${NC}"
echo -e "${BLUE}        KCSA LAB 2.4: KUBELET HARDENING & AUTHENTICATION BREAK       ${NC}"
echo -e "${BLUE}====================================================================${NC}"

# Locate Kubelet configuration file dynamically
KUBELET_CONFIG=""
POSSIBLE_PATHS=(
    "/var/lib/kubelet/config.yaml"
    "/etc/kubernetes/kubelet/config.yaml"
    "/var/snap/microk8s/current/args/kubelet"
)

for path in "${POSSIBLE_PATHS[@]}"; do
    if [[ -f "$path" ]]; then
        KUBELET_CONFIG="$path"
        break
    fi
done

if [[ -z "$KUBELET_CONFIG" ]]; then
    echo -e "${RED}[ERROR] Could not find Kubelet config file in standard locations.${NC}" >&2
    echo -e "Searched paths: ${POSSIBLE_PATHS[*]}" >&2
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_CONFIG="${KUBELET_CONFIG}.kcsa_bak_${TIMESTAMP}"

echo -e "${YELLOW}[+] Backing up original configuration to: ${BACKUP_CONFIG}${NC}"
cp "$KUBELET_CONFIG" "$BACKUP_CONFIG"

echo -e "${YELLOW}[+] Injecting Kubelet security misconfigurations...${NC}"

# 1. Enable Anonymous Authentication
# 2. Set Authorization Mode to AlwaysAllow (disabling Webhook RBAC checks)
# 3. Expose legacy unauthenticated Read-Only Port (10255)
# 4. Point clientCAFile to a non-existent path breaking X509 client cert validation

python3 - <<EOF
import re

config_path = "${KUBELET_CONFIG}"
with open(config_path, 'r') as f:
    content = f.read()

# Break client CA File path
if 'clientCAFile:' in content:
    content = re.sub(r'clientCAFile:\s*.*', 'clientCAFile: /etc/kubernetes/pki/non_existent_ca.crt', content)
else:
    content += "\nauthentication:\n  x509:\n    clientCAFile: /etc/kubernetes/pki/non_existent_ca.crt\n"

# Enable anonymous authentication
if 'anonymous:' in content:
    content = re.sub(r'(anonymous:\s*\n\s*enabled:\s*)false', r'\1true', content)
    content = re.sub(r'enabled:\s*false', 'enabled: true', content)
else:
    content += "\nauthentication:\n  anonymous:\n    enabled: true\n"

# Change authorization mode from Webhook to AlwaysAllow
if 'mode:' in content:
    content = re.sub(r'mode:\s*Webhook', 'mode: AlwaysAllow', content)

# Open insecure read-only port 10255
if 'readOnlyPort:' in content:
    content = re.sub(r'readOnlyPort:\s*\d+', 'readOnlyPort: 10255', content)
else:
    content += "\nreadOnlyPort: 10255\n"

with open(config_path, 'w') as f:
    f.write(content)
EOF

echo -e "${YELLOW}[+] Restarting Kubelet service...${NC}"
systemctl restart kubelet || true

sleep 3

echo -e "${GREEN}====================================================================${NC}"
echo -e "${GREEN}                 SCENARIO DEPLOYED SUCCESSFULLY                     ${NC}"
echo -e "${GREEN}====================================================================${NC}"
echo -e "${YELLOW}SYMPTOMS TO OBSERVE:${NC}"
echo -e " 1. 'kubectl logs <pod-name>' and 'kubectl exec -it ...' fail with x509 / client verification errors."
echo -e " 2. Kubelet API (port 10250) allows unauthenticated requests to read sensitive endpoints."
echo -e " 3. Kubelet legacy read-only HTTP port 10255 is listening on the host interface."
echo -e " 4. CIS Kubernetes Benchmark compliance scans flag Kubelet Section 4.2 as CRITICAL FAILED."
echo
echo -e "${YELLOW}STUDENT OBJECTIVES:${NC}"
echo -e " 1. Inspect Kubelet system logs using 'journalctl -u kubelet' to diagnose auth errors."
echo -e " 2. Modify Kubelet configuration at '${KUBELET_CONFIG}':"
echo -e "    - Disable anonymous authentication ('authentication.anonymous.enabled: false')."
echo -e "    - Set Kubelet authorization mode to Webhook ('authorization.mode: Webhook')."
echo -e "    - Restore the correct Client CA file ('authentication.x509.clientCAFile: /etc/kubernetes/pki/ca.crt')."
echo -e "    - Disable the unauthenticated read-only port ('readOnlyPort: 0')."
echo -e " 3. Restart the Kubelet service ('systemctl restart kubelet')."
echo -e " 4. Verify that control plane logs/exec function properly and port 10255 is closed."
echo -e "${BLUE}====================================================================${NC}"
echo

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (STUDENT REFERENCE)
# ==============================================================================
#
# STEP 1: Diagnose Kubelet status & log errors
# ------------------------------------------------------------------------------
# Check Kubelet service status and journal logs:
#   $ sudo systemctl status kubelet
#   $ sudo journalctl -u kubelet -n 100 --no-pager
#
# Test control plane integration:
#   $ kubectl logs -n kube-system -l app=kube-proxy
#   # Expected Error: Error from server (NotFound): ... or x509: certificate signed by unknown authority
#
# Check open unauthenticated ports:
#   $ sudo ss -tulpn | grep 10255
#   # Output shows Kubelet listening on port 10255
#
# STEP 2: Remediate Kubelet Configuration
# ------------------------------------------------------------------------------
# Open the active configuration file in an editor:
#   $ sudo vi /var/lib/kubelet/config.yaml
#
# Ensure the configuration contains the following security parameters:
#
# authentication:
#   anonymous:
#     enabled: false
#   webhook:
#     cacheTTL: 2m0s
#     enabled: true
#   x509:
#     clientCAFile: /etc/kubernetes/pki/ca.crt
# authorization:
#   mode: Webhook
#   webhook:
#     cacheAuthorizedTTL: 5m0s
#     cacheUnauthorizedTTL: 30s
# readOnlyPort: 0
#
# STEP 3: Restart and Validate Kubelet Service
# ------------------------------------------------------------------------------
# Reload systemd and restart Kubelet:
#   $ sudo systemctl daemon-reload
#   $ sudo systemctl restart kubelet
#   $ sudo systemctl status kubelet
#
# STEP 4: Verification & Compliance Validation
# ------------------------------------------------------------------------------
# 1. Verify legacy read-only port 10255 is disabled:
#    $ sudo ss -tulpn | grep 10255
#    # Output MUST be empty.
#
# 2. Verify anonymous requests to Kubelet HTTPS port 10250 are rejected:
#    $ curl -k https://localhost:10250/metrics
#    # Expected Output: Unauthorized (HTTP 401)
#
# 3. Verify control plane logs & exec work via authenticated API Server client cert:
#    $ kubectl logs -n kube-system -l app=kube-proxy --tail=10
#    $ curl -k --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
#             --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
#             https://localhost:10250/metrics
#    # Expected Output: HTTP 200 OK with Prometheus metrics payload.
# ==============================================================================