#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
# Topic 4.2: Other Configuration Management Tools (Weight: 3.34)
# Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# Official Salt Documentation: https://docs.saltproject.io/en/latest/topics/transports/zeromq.html
#
# ARCHITECTURAL CONTEXT & INTERNALS:
# Topic 4.2 evaluates understanding of agent-based vs agentless CM architectures,
# push vs pull state delivery, PKI authentication key handling, and state declaration.
# Unlike Ansible (agentless over SSH), SaltStack relies on lightweight agent daemons
# (salt-minion) communicating with a central orchestrator (salt-master) via ZeroMQ
# (ports 4505 for Publisher and 4506 for Request Server). Authentication uses 2048-bit
# RSA keys exchanged during minion registration, validated via AES encryption.
#
# THIS LAB BREAKS:
# 1. PKI Key Fingerprint Pinning Mismatch (Master Key Verification Failure).
# 2. Corrupted Minion Key Permissions & Stale Pre-accepted Key Registry.
# 3. Invalid SLS State Declaration Syntax in Salt Master's /srv/salt/ space.
# ==============================================================================

set -euo pipefail

RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}ERROR: This lab script must be executed as root on a disposable lab VM.${NC}" >&2
    exit 1
fi

echo -e "${BLUE}[+] Initializing LPI 701-100 Topic 4.2 Lab Environment...${NC}"

# 1. Install SaltStack packages if missing
if ! command -v salt-master &>/dev/null || ! command -v salt-minion &>/dev/null; then
    echo -e "${YELLOW}[*] Installing salt-master and salt-minion packages...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq salt-master salt-minion
    elif command -v dnf &>/dev/null; then
        dnf install -y salt-master salt-minion
    else
        echo -e "${RED}Unsupported package manager. Please install salt-master and salt-minion manually.${NC}" >&2
        exit 1
    fi
fi

# 2. Reset Salt configuration to base standard state
systemctl stop salt-master salt-minion &>/dev/null || true
rm -rf /etc/salt/pki /etc/salt/minion.d/* /etc/salt/master.d/* /var/cache/salt /srv/salt/*
mkdir -p /srv/salt /etc/salt/pki/master /etc/salt/pki/minion /etc/salt/minion.d

# Generate fresh keys for master and minion
salt-key --gen-keys=master --gen-keys-dir=/etc/salt/pki/master --user=root &>/dev/null || true
salt-key --gen-keys=lab-node-01 --gen-keys-dir=/etc/salt/pki/minion --user=root &>/dev/null || true

# Standard Minion config pointing to localhost master
cat << 'EOF' > /etc/salt/minion
id: lab-node-01
master: 127.0.0.1
pubkey_verify: True
EOF

# Standard State file
cat << 'EOF' > /srv/salt/top.sls
base:
  'lab-node-01':
    - webserver
EOF

# ==============================================================================
# INTRODUCING CONTROLLED PRODUCTION BREAKAGES (LAB SETUP)
# ==============================================================================

# Breakage 1: Inject invalid Master Fingerprint pinning configuration in minion.d
cat << 'EOF' > /etc/salt/minion.d/99-security-pinning.conf
# SECURITY POLICY: Pin Master Public Key Fingerprint
master_finger: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
EOF

# Breakage 2: Corrupt minion key permissions (0666) & inject mismatched accepted key on master
chmod 0666 /etc/salt/pki/minion/lab-node-01.pem
mkdir -p /etc/salt/pki/master/minions
# Put a dummy mismatched key under master's accepted minions to simulate key collision
echo "CORRUPTED_DUMMY_PUBLIC_KEY" > /etc/salt/pki/master/minions/lab-node-01

# Breakage 3: Inject syntax error into Salt SLS state (using invalid state module mapping)
cat << 'EOF' > /srv/salt/webserver.sls
# Salt State for Nginx Webserver Deployment
nginx_pkg:
  service.installed:    # INVALID: service.installed does not exist in Salt state modules (should be pkg.installed)
    - name: nginx

nginx_service:
  service.running:
    - name: nginx
    - enable: True
    - require:
      - service: nginx_pkg  # INVALID: Wrong state module reference
EOF

# Start services
systemctl start salt-master
systemctl start salt-minion

# Clear terminal output for clean student prompt
sleep 2

echo -e "\n================================================================================"
echo -e "${RED}  LPI DEVOPS TOOLS ENGINEER (701-100) - BREAK & FIX LAB: TOPIC 4.2${NC}"
echo -e "================================================================================"
echo -e "  ${YELLOW}SYSTEM STATE:${NC} SaltStack Master & Minion services are running."
echo -e "  ${YELLOW}PROBLEM STATEMENT:${NC} The automated state enforcement pipeline is failing."
echo -e "  The SRE team reports that minion 'lab-node-01' cannot receive configuration"
echo -e "  states from the Salt Master, and execution of 'state.apply' fails."
echo -e ""
echo -e "  ${YELLOW}OBSERVED SYMPTOMS:${NC}"
echo -e "    1. Running: ${BLUE}salt 'lab-node-01' test.ping${NC}"
echo -e "       Returns: ${RED}Minion did not return. [No response]${NC} or PKI fingerprint rejection."
echo -e "    2. Running: ${BLUE}salt-call --local state.apply webserver${NC}"
echo -e "       Returns: SLS rendering error / Invalid State Module errors."
echo -e "    3. Salt minion log (${BLUE}/var/log/salt/minion${RED}) shows master key verification failure."
echo -e ""
echo -e "  ${YELLOW}YOUR OBJECTIVE:${NC}"
echo -e "    - Diagnose and fix the PKI Master Fingerprint pinning mismatch."
echo -e "    - Fix insecure PKI key permissions and clear stale accepted key registries."
echo -e "    - Fix the SLS syntax in ${BLUE}/srv/salt/webserver.sls${NC} so it strictly adheres"
echo -e "      to valid Salt State Compiler standards."
echo -e "    - Confirm success when ${BLUE}salt 'lab-node-01' test.ping${NC} returns ${GREEN}True${NC}"
echo -e "      and ${BLUE}salt 'lab-node-01' state.apply${NC} applies successfully with 0 failures."
echo -e "================================================================================\n"

exit 0

# ==============================================================================
# STUDENT SOLUTION GUIDE (STEP-BY-STEP DIAGNOSTICS & RESOLUTION)
# ==============================================================================
#
# STEP 1: DIAGNOSE PKI AUTHENTICATION & FINGERPRINT MISMATCH
# ------------------------------------------------------------------------------
# Run test.ping to check minion availability:
#   $ salt 'lab-node-01' test.ping
# Output:
#   Minion did not return. [No response]
#
# Inspect minion log for underlying ZeroMQ / PKI errors:
#   $ tail -n 25 /var/log/salt/minion
# Observed log error:
#   [CRITICAL] The Salt Master server key fingerprint did not match specified fingerprint!
#
# Check the actual Master Public Key fingerprint on the Salt Master:
#   $ salt-key -F master
# Output:
#   Local Keys:
#   master.pub:  ab:cd:12:34:... (Actual SHA256 fingerprint)
#
# Inspect minion configuration overlays:
#   $ cat /etc/salt/minion.d/99-security-pinning.conf
#
# Fix: Calculate actual master fingerprint and update configuration, or remove
# invalid pinning file if unneeded:
#   $ ACTUAL_FINGER=$(salt-key -F master | grep master.pub | awk '{print $2}')
#   $ echo "master_finger: '$ACTUAL_FINGER'" > /etc/salt/minion.d/99-security-pinning.conf
#
# ------------------------------------------------------------------------------
# STEP 2: FIX CORRUPTED PKI KEY PERMISSIONS & RE-ACCEPT MINION KEY
# ------------------------------------------------------------------------------
# Salt minion enforces strict POSIX file mode permissions on private keys (0400 or 0600).
#   $ ls -l /etc/salt/pki/minion/lab-node-01.pem
# Fix permissions:
#   $ chmod 0600 /etc/salt/pki/minion/lab-node-01.pem
#
# Remove stale/corrupted pre-accepted key on the master:
#   $ salt-key -d lab-node-01 -y
#
# Restart minion to re-initiate PKI handshake:
#   $ systemctl restart salt-minion
#
# List pending keys on master and accept the authentic minion key:
#   $ salt-key -L
#   $ salt-key -a lab-node-01 -y
#
# Verify connectivity:
#   $ salt 'lab-node-01' test.ping
# Expected output:
#   lab-node-01:
#       True
#
# ------------------------------------------------------------------------------
# STEP 3: RECTIFY SALT SLS STATE COMPILER SYNTAX ERRORS
# ------------------------------------------------------------------------------
# Test state execution on target node:
#   $ salt 'lab-node-01' state.apply webserver
# Observed Error:
#   State 'service.installed' was not found in SLS 'webserver'
#
# Explanation of Salt State Architecture vs Modules:
# - Salt has Execution Modules (e.g., `pkg.install`, `service.start`) used in CLI call commands.
# - Salt has State Modules (e.g., `pkg.installed`, `service.running`) used in declarative `.sls` files.
# - `service.installed` is invalid. Software package installation MUST use `pkg.installed`.
#
# Correct `/srv/salt/webserver.sls`:
# Edit the file using your editor of choice (e.g. `vim /srv/salt/webserver.sls`) so it reads:
#
# cat << 'EOF' > /srv/salt/webserver.sls
# nginx_pkg:
#   pkg.installed:
#     - name: nginx
# 
# nginx_service:
#   service.running:
#     - name: nginx
#     - enable: True
#     - require:
#       - pkg: nginx_pkg
# EOF
#
# ------------------------------------------------------------------------------
# STEP 4: FINAL VERIFICATION
# ------------------------------------------------------------------------------
# Re-run state application from master:
#   $ salt 'lab-node-01' state.apply
# Expected Output:
#   Summary for lab-node-01
#   ------------
#   Succeeded: 2 (changed=2)
#   Failed:    0
#   Total states run:     2
# ==============================================================================