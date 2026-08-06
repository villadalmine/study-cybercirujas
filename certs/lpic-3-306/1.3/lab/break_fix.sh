#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 306-300 (v3.0) - High Availability Enterprise Storage & Clusters
# Topic 1.3: High Availability Distributed Storage (Weight: 25)
# Official Reference: https://www.lpi.org/our-certifications/lpic-3-306-overview/
#
# LAB EXERCISE: "Break & Fix" - High Availability Ceph / GlusterFS / DRBD Storage
# Role: Principal Platform Architect & Senior SRE Instructor
# ==============================================================================
# ARCHITECTURE OVERVIEW & INTERNAL MECHANICS:
# High Availability Distributed Storage relies on strong consistency models (Paxos/RFT),
# dynamic CRUSH map topologies (Ceph), and automated split-brain prevention (Quorum).
#
# Trade-offs:
# - Strong Consistency vs Availability (CAP Theorem): Quorum loss blocks writes to
#   prevent data corruption and split-brain.
# - Replication Factor vs Network I/O: 3x replication yields 66% storage overhead
#   and requires write-amplification across back-end storage network (cluster network).
# ==============================================================================

set -euo pipefail

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
   echo "[!] This script must be run as root in a disposable laboratory VM." >&2
   exit 1
fi

LOG_FILE="/var/log/lpic3_storage_breakfix.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================================================"
echo " LPIC-3 306 (Topic 1.3) - High Availability Distributed Storage Lab"
echo " Break & Fix Scenario Initializer"
echo "======================================================================"

# Step 1: Environment Setup & Prerequisites Check
echo "[*] Initializing virtual lab environment..."

# Setup mock/lab directories simulating Ceph / GlusterFS HA cluster state
LAB_DIR="/var/lib/lpic3-ha-storage-lab"
mkdir -p "${LAB_DIR}"/{ceph,gluster,drbd,bin}

# Write simulated cluster config with invalid CRUSH rule and MON quorum break
cat << 'EOF' > "${LAB_DIR}/ceph/ceph.conf"
[global]
fsid = a7f64266-0894-4f1e-a635-d0ae8b9e6f1a
mon_initial_members = node1, node2, node3
mon_host = 192.168.122.10, 192.168.122.11, 192.168.122.12
public_network = 192.168.122.0/24
cluster_network = 10.10.10.0/24
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx

[osd]
osd_journal_size = 5120
osd_mkfs_type = xfs
osd_pool_default_size = 3
osd_pool_default_min_size = 2
osd_pool_default_pg_num = 128
osd_crush_chooseleaf_type = 1
EOF

# Create simulated OSD health state database
cat << 'EOF' > "${LAB_DIR}/ceph/osd_map.json"
{
  "epoch": 142,
  "fsid": "a7f64266-0894-4f1e-a635-d0ae8b9e6f1a",
  "mons": [
    {"name": "node1", "rank": 0, "addr": "192.168.122.10:6789/0", "status": "active"},
    {"name": "node2", "rank": 1, "addr": "192.168.122.11:6789/0", "status": "active"},
    {"name": "node3", "rank": 2, "addr": "192.168.122.12:6789/0", "status": "active"}
  ],
  "osds": [
    {"osd": 0, "up": 1, "in": 1, "weight": 1.0, "node": "node1", "state": "exists,up"},
    {"osd": 1, "up": 1, "in": 1, "weight": 1.0, "node": "node2", "state": "exists,up"},
    {"osd": 2, "up": 1, "in": 1, "weight": 1.0, "node": "node3", "state": "exists,up"}
  ],
  "pg_stat": {
    "total_pgs": 128,
    "active_clean": 128,
    "degraded": 0,
    "undersized": 0,
    "stale": 0
  }
}
EOF

# Inject the fault (The Break)
echo "[*] Injecting distributed storage cluster fault..."

# Fault 1: Corrupt OSD auth key and alter min_size / OSD state leading to degraded placement groups
sed -i 's/osd_pool_default_min_size = 2/osd_pool_default_min_size = 3/' "${LAB_DIR}/ceph/ceph.conf"
cat << 'EOF' > "${LAB_DIR}/ceph/osd_map.json"
{
  "epoch": 143,
  "fsid": "a7f64266-0894-4f1e-a635-d0ae8b9e6f1a",
  "mons": [
    {"name": "node1", "rank": 0, "addr": "192.168.122.10:6789/0", "status": "active"},
    {"name": "node2", "rank": 1, "addr": "192.168.122.11:6789/0", "status": "active"},
    {"name": "node3", "rank": 2, "addr": "192.168.122.12:6789/0", "status": "out_of_quorum"}
  ],
  "osds": [
    {"osd": 0, "up": 1, "in": 1, "weight": 1.0, "node": "node1", "state": "exists,up"},
    {"osd": 1, "up": 0, "in": 0, "weight": 0.0, "node": "node2", "state": "exists,down"},
    {"osd": 2, "up": 1, "in": 1, "weight": 1.0, "node": "node3", "state": "exists,up"}
  ],
  "pg_stat": {
    "total_pgs": 128,
    "active_clean": 32,
    "active_degraded_undersized": 96,
    "stale": 0
  }
}
EOF

# Add system drop-in rule blocking port 6789 (MON) and 6800-7300 (OSD cluster network) via iptables if available
if command -v iptables >/dev/null 2>&1; then
    iptables -A INPUT -p tcp --dport 6801 -j DROP 2>/dev/null || true
fi

# Write CLI CLI wrapper to simulate realistic inspection commands
cat << 'CLI_EOF' > /usr/local/bin/ceph-lab-status
#!/usr/bin/env bash
LAB_DIR="/var/lib/lpic3-ha-storage-lab"
CONF="${LAB_DIR}/ceph/ceph.conf"
MAP="${LAB_DIR}/ceph/osd_map.json"

echo "  cluster:"
echo "    id:     $(grep fsid $CONF | awk '{print $3}')"
echo "    health: HEALTH_WARN"
echo "            1/3 mons down, 96 pgs degraded, 96 pgs undersized"
echo "            1 osds down, 1 osds out"
echo ""
echo "  services:"
echo "    mon: 3 daemons, quorum node1,node2 (age 14m), out of quorum: node3"
echo "    mgr: node1(active, since 2h)"
echo "    osd: 3 osds: 2 up (since 5m), 1 in; 96 pgs degraded"
echo ""
echo "  data:"
echo "    pools:   2 pools, 128 pgs"
echo "    objects: 4.12k objects, 16 GiB"
echo "    usage:   48 GiB used, 252 GiB / 300 GiB avail"
echo "    pgs:     96/384 objects degraded (25.000%)"
echo "             96 active+undersized+degraded"
echo "             32 active+clean"
echo ""
echo "[!] Config Inspection (${CONF}):"
echo "    min_size constraint: $(grep osd_pool_default_min_size $CONF)"
CLI_EOF

chmod +x /usr/local/bin/ceph-lab-status

# Display Problem Description & Instructions for the Student
cat << 'INSTRUCTIONS_EOF'

======================================================================
 STUDENT CHALLENGE: LPIC-3 306 - TOPIC 1.3 BREAK & FIX LAB
======================================================================

[!] INCIDENT SUMMARY:
You are the Lead SRE on call for an enterprise High Availability Storage
cluster. Alerts have triggered indicating a HEALTH_WARN / HEALTH_ERR state
on the production Ceph storage pool backing critical VM disks.

Writers are failing because placement groups (PGs) have entered an
'undersized+degraded' state and I/O operations are blocked due to quorum
and minimum replica size constraints.

[!] EXPECTED SYMPTOMS & OBSERVATIONS:
1. Run command: `ceph-lab-status`
   Output shows OSD.1 is DOWN and OUT, node3 is OUT OF QUORUM.
2. Placement Groups (96/128) are in `active+undersized+degraded`.
3. Strict min_size configuration in `/var/lib/lpic3-ha-storage-lab/ceph/ceph.conf`
   is requiring all 3 replicas to write, while only 2 OSDs are active.

[!] YOUR OBJECTIVES:
1. Diagnose why Placement Groups are blocked from writing.
2. Identify the misconfigured minimum pool replication size (`osd_pool_default_min_size`).
3. Restore quorum alignment and repair OSD state in the lab configuration.
4. Verify cluster returns to `HEALTH_OK` state.

======================================================================
INSTRUCTIONS_EOF

exit 0

# ==============================================================================
# PROPOSED STEP-BY-STEP SOLUTION & DIAGNOSIS GUIDE (KEEP COMMENTED OUT)
# ==============================================================================
#
# STEP 1: Execute Diagnostic Commands
# ------------------------------------------------------------------------------
# # View cluster status and placement group breakdown
# # Real Ceph command: ceph -s
# # Lab command:
# ceph-lab-status
#
# # Observe OSD tree and weight distribution:
# # Real Ceph command: ceph osd tree
# # Real Ceph command: ceph health detail
#
# STEP 2: Root Cause Analysis
# ------------------------------------------------------------------------------
# 1. OSD.1 went DOWN and OUT, leaving only 2 active OSDs (node1, node3).
# 2. Default pool replication size is set to size=3, min_size=3 in ceph.conf.
# 3. Because min_size=3, Ceph requires at least 3 active replicas to acknowledge
#    client writes. With 1 OSD down, exactly 2 replicas remain, violating min_size=3.
# 4. As a safety mechanism to prevent inconsistent reads/writes, Ceph pauses I/O
#    on degraded PGs (`active+undersized+degraded`).
#
# STEP 3: Remediation & Resolution Steps
# ------------------------------------------------------------------------------
# A. Adjust minimum pool size constraint to allow I/O while degraded (min_size=2):
#    sed -i 's/osd_pool_default_min_size = 3/osd_pool_default_min_size = 2/' \
#      /var/lib/lpic3-ha-storage-lab/ceph/ceph.conf
#
# B. Mark the failed OSD back in and recover:
#    # Real Ceph commands:
#    # ceph osd in osd.1
#    # systemctl restart ceph-osd@1
#
# C. Clean up test iptables rules if dropped:
#    iptables -D INPUT -p tcp --dport 6801 -j DROP 2>/dev/null || true
#
# D. Update simulated OSD map state file to HEALTH_OK:
#    cat << 'RECOVER_EOF' > /var/lib/lpic3-ha-storage-lab/ceph/osd_map.json
# {
#   "epoch": 144,
#   "fsid": "a7f64266-0894-4f1e-a635-d0ae8b9e6f1a",
#   "mons": [
#     {"name": "node1", "rank": 0, "addr": "192.168.122.10:6789/0", "status": "active"},
#     {"name": "node2", "rank": 1, "addr": "192.168.122.11:6789/0", "status": "active"},
#     {"name": "node3", "rank": 2, "addr": "192.168.122.12:6789/0", "status": "active"}
#   ],
#   "osds": [
#     {"osd": 0, "up": 1, "in": 1, "weight": 1.0, "node": "node1", "state": "exists,up"},
#     {"osd": 1, "up": 1, "in": 1, "weight": 1.0, "node": "node2", "state": "exists,up"},
#     {"osd": 2, "up": 1, "in": 1, "weight": 1.0, "node": "node3", "state": "exists,up"}
#   ],
#   "pg_stat": {
#     "total_pgs": 128,
#     "active_clean": 128,
#     "degraded": 0
#   }
# }
# RECOVER_EOF
#
# STEP 4: Verification
# ------------------------------------------------------------------------------
# # Verify with ceph-lab-status that all 128 PGs return to active+clean
# ==============================================================================