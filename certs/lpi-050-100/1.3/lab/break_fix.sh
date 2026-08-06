#!/bin/bash
# ==============================================================================
# LPI 050-100 Open Source Essentials - Topic 1.3: On-Premises and Cloud Computing
# Advanced Production Lab: Cloud Metadata Service & Hybrid Interconnect Failure
# Role: Senior SRE Instructor & Principal Platform Architect
# Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# ==============================================================================
# OVERVIEW:
# In modern hybrid architecture, workloads running on cloud infrastructure (IaaS)
# depend on the Link-Local Instance Metadata Service (IMDS) at 169.254.169.254 to
# obtain dynamic networking, IAM role credentials, and cloud-init bootstrap configs.
# Unlike traditional On-Premises bare-metal servers, Cloud IaaS VMs use virtualized 
# link-local interfaces and hypervisor routing tables.
#
# SCENARIO:
# A legacy On-Premises application was migrated to a Cloud IaaS Virtual Machine.
# After applying baseline security hardening iptables rules intended for on-premise
# firewalls, cloud-init and cloud monitoring agents failed to communicate with the
# Cloud Metadata Service (169.254.169.254).
#
# OBJECTIVE:
# 1. Inspect the system symptoms and identify why requests to 169.254.169.254 fail.
# 2. Troubleshoot network interfaces, kernel routing tables, and firewall filter chains.
# 3. Restore connectivity to the Cloud Metadata Service without compromising system security.
# ==============================================================================

set -euo pipefail

# Ensure script is executed with root privileges
if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This script requires administrative privileges. Please run with sudo or as root." >&2
    exit 1
fi

LOG_FILE="/tmp/lpi_break_fix_lab.log"
MOCK_META_PORT="8080"
METADATA_IP="169.254.169.254"
DUMMY_IF="cloud-md0"

echo "=========================================================================="
echo "  LPI 050-100 (Topic 1.3) Lab Setup: On-Premises vs Cloud Infrastructure  "
echo "=========================================================================="
echo "[+] Initializing environment setup..."

# Step 1: Clean up any previous lab artifacts
cleanup_previous_env() {
    echo "[+] Cleaning existing lab environment..."
    iptables -D OUTPUT -d "${METADATA_IP}/32" -j DROP 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp -d "${METADATA_IP}/32" --dport 80 -j REDIRECT --to-ports "${MOCK_META_PORT}" 2>/dev/null || true
    pkill -f "python3 -m http.server ${MOCK_META_PORT}" 2>/dev/null || true
    ip link delete "${DUMMY_IF}" 2>/dev/null || true
    rm -rf /tmp/mock_metadata
}

cleanup_previous_env

# Step 2: Provision Mock Cloud Metadata Service (IaaS Emulator)
echo "[+] Provisioning mock Cloud Instance Metadata Service (IMDS v1/v2)..."
mkdir -p /tmp/mock_metadata/latest/meta-data/
cat <<'EOF' > /tmp/mock_metadata/latest/meta-data/instance-id
i-0a8f9c12345678ab9
EOF

cat <<'EOF' > /tmp/mock_metadata/latest/meta-data/local-ipv4
10.0.1.42
EOF

cat <<'EOF' > /tmp/mock_metadata/latest/meta-data/placement-availability-zone
us-east-1a
EOF

# Start lightweight HTTP server acting as Cloud Provider Metadata Hypervisor daemon
python3 -m http.server "${MOCK_META_PORT}" --directory /tmp/mock_metadata > "${LOG_FILE}" 2>&1 &
MOCK_PID=$!
sleep 1

if ! kill -0 "${MOCK_PID}" 2>/dev/null; then
    echo "[ERROR] Failed to start mock cloud metadata HTTP daemon." >&2
    exit 1
fi

# Step 3: Setup Virtual Link-Local Interface & NAT Redirects
echo "[+] Configuring link-local dummy network interface (${DUMMY_IF})..."
ip link add "${DUMMY_IF}" type dummy
ip addr add "${METADATA_IP}/32" dev "${DUMMY_IF}"
ip link set dev "${DUMMY_IF}" up

# Forward port 80 requests directed at metadata IP to local mock daemon
iptables -t nat -A OUTPUT -p tcp -d "${METADATA_IP}/32" --dport 80 -j REDIRECT --to-ports "${MOCK_META_PORT}"

# Step 4: Inject Controlled Breakage (Simulating On-Premises Security Policy Misconfiguration)
echo "[!] INJECTING FAILURE: Applying legacy on-premise firewall rule..."
# Legacy on-prem firewall rule blocking API API link-local subnets (169.254.0.0/16)
iptables -A OUTPUT -d "${METADATA_IP}/32" -j DROP

echo "[+] Lab setup completed successfully."
echo ""
echo "=========================================================================="
echo "                           STUDENT INSTRUCTIONS                           "
echo "=========================================================================="
echo "Symptom Reported by Cloud Operator:"
echo "--------------------------------------------------------------------------"
echo "The application post-migration to the Cloud platform cannot retrieve its"
echo "Instance ID or Availability Zone from the provider metadata service."
echo "Running the following command hangs or times out:"
echo ""
echo "  curl -m 3 -s http://${METADATA_IP}/latest/meta-data/instance-id"
echo ""
echo "Expected Behavior in Cloud IaaS:"
echo "--------------------------------------------------------------------------"
echo "Should return the instance identifier: 'i-0a8f9c12345678ab9'."
echo ""
echo "Your Mission:"
echo "--------------------------------------------------------------------------"
echo "1. Diagnose why outbound traffic to ${METADATA_IP} is failing."
echo "2. Analyze network interfaces, routes, and packet filtering rules."
echo "3. Remove the blocking policy without breaking the local HTTP redirect rule."
echo "4. Verify metadata retrieval succeeds via curl."
echo "=========================================================================="
echo ""

# ==============================================================================
#                               SOLUTION (HIDDEN)
# ==============================================================================
# To reveal the step-by-step solution, read the commented section below.
#
# STEP-BY-STEP TROUBLESHOOTING & RESOLUTION GUIDE:
#
# 1. DIAGNOSIS & RECONNAISSANCE:
#    Test connectivity to the cloud metadata service:
#    $ curl -v -m 3 http://169.254.169.254/latest/meta-data/instance-id
#    Output: Connection timed out after 3000 milliseconds.
#
# 2. CHECK NETWORK INTERFACES & ROUTING:
#    Verify if link-local route/interface exists:
#    $ ip addr show dev cloud-md0
#    $ ip route show | grep 169.254
#    (Interface exists and IP 169.254.169.254 is configured properly).
#
# 3. INSPECT FIREWALL (IPTABLES) FILTER CHAINS:
#    Examine OUTPUT chain in the filter table:
#    $ sudo iptables -L OUTPUT -v -n --line-numbers
#    
#    Sample Output:
#    Chain OUTPUT (policy ACCEPT 10 packets, 600 bytes)
#    num   pkts bytes target     prot opt in     out     source               destination         
#    1        3   180 DROP       all  --  *      *       0.0.0.0/0            169.254.169.254
#
# 4. IDENTIFY THE ROOT CAUSE:
#    Rule #1 in the OUTPUT chain explicitly drops all packets destined for 169.254.169.254.
#    This rule was ported from an on-premises baseline where link-local metadata 
#    endpoints were treated as unrouted APIPA addresses or unauthorized traffic.
#
# 5. REMOVE THE BLOCKING RULE:
#    Delete rule #1 from the OUTPUT filter chain:
#    $ sudo iptables -D OUTPUT 1
#
#    Alternatively, target by rule specification:
#    $ sudo iptables -D OUTPUT -d 169.254.169.254/32 -j DROP
#
# 6. VERIFICATION:
#    Execute the curl request again:
#    $ curl -m 3 -s http://169.254.169.254/latest/meta-data/instance-id
#    Expected Output:
#    i-0a8f9c12345678ab9
#
# 7. CLEANUP (OPTIONAL AFTER LAB):
#    $ sudo iptables -t nat -D OUTPUT -p tcp -d 169.254.169.254/32 --dport 80 -j REDIRECT --to-ports 8080
#    $ sudo pkill -f "python3 -m http.server 8080"
#    $ sudo ip link delete cloud-md0
# ==============================================================================