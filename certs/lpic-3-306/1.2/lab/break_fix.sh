#!/usr/bin/env bash
# ==============================================================================
# CNCF / LPI-3 SRE ADVANCED PRODUCTION LAB: BREAK & FIX SCENARIO
# Certification: LPIC-3 High Availability and Storage Clusters (Exam 306-300, v3.0)
# Topic 1.2: High Availability Cluster Storage (Weight: 25)
# Reference: https://www.lpi.org/our-certifications/lpic-3-306-overview/
#
# OBJECTIVE:
# Diagnose and resolve a DRBD (Distributed Replicated Block Device) Split-Brain
# state and fix misconfigured auto-recovery net handlers in /etc/drbd.d/r0.res.
#
# SYMPTOMS OBSERVED BY THE STUDENT:
# 1. DRBD resource 'r0' displays connection state 'StandAlone'.
# 2. Block replication between cluster nodes is halted; changes on one node
#    are not replicated to the partner node.
# 3. Kernel logs (dmesg / journalctl -u drbd) show:
#    "Split-Brain detected, dropping connection!"
# 4. Manual execution of `drbdadm connect r0` fails instantly with connection refusal.
#
# REQUIRED FIX:
# 1. Inspect DRBD connection and node states using `drbdadm status` / `drbdsetup status`.
# 2. Force the designated victim node into secondary role and discard its local modifications
#    using `drbdadm connect --discard-my-data r0`.
# 3. Re-connect the survivor node to initiate resynchronization.
# 4. Update `/etc/drbd.d/r0.res` with correct `net` handlers (`after-sb-0pri`,
#    `after-sb-1pri`, `after-sb-2pri`, and `fencing`) to allow automatic split-brain
#    fencing and recovery policies in production.
# ==============================================================================

set -euo pipefail

# Visual Formatting Helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 1. Safety & Environment Verification
if [[ $EUID -ne 0 ]]; then
   log_error "This lab setup script must be executed as root."
   exit 1
fi

log_warn "=== LPIC-3 306 Topic 1.2: High Availability Cluster Storage Break & Fix Setup ==="
log_warn "This script will inject a controlled failure into a DRBD storage resource."
log_warn "Ensure you are running this in a disposable laboratory VM."

# 2. Install / Verify Dependencies
log_info "Verifying required packages (drbd-utils, losetup)..."
if ! command -v drbdadm &> /dev/null; then
    log_info "Installing drbd-utils..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq drbd-utils kmod &> /dev/null
    elif command -v dnf &> /dev/null; then
        dnf install -y -q drbd-utils kmod &> /dev/null
    else
        log_error "Unsupported package manager. Please install drbd-utils manually."
        exit 1
    fi
fi

# Load DRBD kernel module if available
if ! lsmod | grep -q drbd; then
    log_info "Loading DRBD kernel module..."
    modprobe drbd || log_warn "Could not load drbd kernel module. Proceeding with simulated block configuration."
fi

# 3. Create Loopback Storage Devices for Lab Simulation
LAB_DIR="/var/tmp/drbd_lab"
NODE1_IMG="${LAB_DIR}/node1_disk.img"
NODE2_IMG="${LAB_DIR}/node2_disk.img"

log_info "Setting up loopback storage backend in ${LAB_DIR}..."
mkdir -p "${LAB_DIR}"

# Create 256MB raw disk images if not existing
if [[ ! -f "${NODE1_IMG}" ]]; then
    dd if=/dev/zero of="${NODE1_IMG}" bs=1M count=256 status=none
fi
if [[ ! -f "${NODE2_IMG}" ]]; then
    dd if=/dev/zero of="${NODE2_IMG}" bs=1M count=256 status=none
fi

# Detach old loop devices if remaining from previous runs
for dev in $(losetup -j "${NODE1_IMG}" -O NAME --noheadings 2>/dev/null || true); do
    losetup -d "${dev}" || true
done
for dev in $(losetup -j "${NODE2_IMG}" -O NAME --noheadings 2>/dev/null || true); do
    losetup -d "${dev}" || true
done

LOOP_NODE1=$(losetup --find --show "${NODE1_IMG}")
LOOP_NODE2=$(losetup --find --show "${NODE2_IMG}")

log_info "Backing loop devices initialized: Node1 -> ${LOOP_NODE1}, Node2 -> ${LOOP_NODE2}"

# 4. Inject Broken DRBD Configuration File (/etc/drbd.d/r0.res)
log_info "Creating misconfigured DRBD resource configuration file '/etc/drbd.d/r0.res'..."

cat <<EOF > /etc/drbd.d/r0.res
# LPIC-3 306 Storage Cluster Lab Resource Definition
resource r0 {
    protocol C;

    startup {
        wfc-timeout 15;
        degr-wfc-timeout 15;
    }

    # BROKEN NET SECTION: Missing automatic split-brain resolution policy
    net {
        # BUG 1: Crammed invalid parameter that disables auto-recovery
        on-disconnect reconnect;
        
        # BUG 2: Missing 'after-sb-0pri', 'after-sb-1pri', and 'after-sb-2pri' policies.
        # When split-brain occurs, DRBD defaults to manual operator intervention
        # and isolates the node into 'StandAlone' state.
    }

    disk {
        on-io-error detach;
    }

    on node1 {
        device    /dev/drbd0;
        disk      ${LOOP_NODE1};
        address   127.0.0.1:7788;
        meta-disk internal;
    }

    on node2 {
        device    /dev/drbd0;
        disk      ${LOOP_NODE2};
        address   127.0.0.1:7789;
        meta-disk internal;
    }
}
EOF

# 5. Initialize Metadata and Simulate Split-Brain State
log_info "Initializing DRBD metadata and triggering Split-Brain condition..."

# Create internal metadata on backing devices
drbdadm create-md r0 --force &> /dev/null || true

# Simulate split-brain state markers in metadata / state tracker file
SIMULATION_STATE_FILE="${LAB_DIR}/drbd_r0_status.state"
cat <<EOF > "${SIMULATION_STATE_FILE}"
RESOURCE: r0
CONNECTION_STATE: StandAlone
LOCAL_ROLE: Primary
PEER_ROLE: Unknown
LOCAL_DISK: UpToDate
PEER_DISK: DUnknown
LAST_EVENT: Split-Brain detected! Node1 (GI: 0xA1B2C3D4) and Node2 (GI: 0xE5F6A7B8) diverged at Generation Counter 42.
REASON: Both cluster nodes accepted writes concurrently while network interconnect was interrupted.
EOF

log_success "=== LAB BREAKAGE COMPLETE ==="
echo ""
echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
echo -e "${YELLOW}STUDENT TROUBLESHOOTING INSTRUCTIONS:${NC}"
echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
echo "1. System alert: DRBD cluster storage resource 'r0' is degraded."
echo "2. Check resource status:"
echo "     cat ${SIMULATION_STATE_FILE}"
echo "     drbdadm status r0 (or drbdsetup status r0)"
echo ""
echo "3. Symptom Checklist:"
echo "   - Connection state reported: StandAlone"
echo "   - Diagnostic message: 'Split-Brain detected, dropping connection!'"
echo "   - Partner nodes cannot resynchronize automatically due to missing net policies."
echo ""
echo "4. Your Task:"
echo "   a) Resolve the active Split-Brain condition manually by picking Node2 as the"
echo "      victim (discard data) and Node1 as the survivor."
echo "   b) Modify '/etc/drbd.d/r0.res' to configure automated Split-Brain resolution"
echo "      handlers so future network partitions automatically recover."
echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
echo ""

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION (COMMENTED FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# STEP 1: DIAGNOSE THE DRBD SPLIT-BRAIN CONDITION
# ------------------------------------------------------------------------------
# Check the status of the DRBD resource using standard management tools:
#
#   # drbdadm status r0
#   # drbdsetup status r0 --verbose
#   # dmesg | grep -i drbd
#   # journalctl -u drbd --no-pager -n 50
#
# Expected output snippet in system logs:
#   drbd r0: Split-Brain detected, dropping connection!
#   drbd r0: ConnState movement change: Connected -> StandAlone
#   drbd r0: Helper process exited with code 0 (no handler configured)
#
#
# STEP 2: MANUAL SPLIT-BRAIN RESOLUTION (VICTIM VS SURVIVOR)
# ------------------------------------------------------------------------------
# In a split-brain scenario, both nodes modified data independently. One node must
# be chosen as the victim (data overwritten) and one as the survivor (source of truth).
#
# Scenario Assumption: Node2 is the victim, Node1 is the survivor.
#
# --- On the Victim Node (Node2 / 127.0.0.1:7789): ---
#
# 1. Demote the resource to Secondary role:
#   # drbdadm secondary r0
#
# 2. Force the victim node to disconnect and discard its local modifications:
#   # drbdadm disconnect r0
#   # drbdadm connect --discard-my-data r0
#
# --- On the Survivor Node (Node1 / 127.0.0.1:7788): ---
#
# 3. Disconnect and re-connect to trigger synchronization toward the victim:
#   # drbdadm disconnect r0
#   # drbdadm connect r0
#
# 4. Verify synchronization progress and state recovery:
#   # drbdadm status r0
#   Expected output:
#     r0 node-id:0 connection:Connected role:Primary
#        volume:0 disk:UpToDate
#        peer node-id:1 role:Secondary disk:UpToDate
#
#
# STEP 3: AUTOMATING SPLIT-BRAIN RECOVERY IN /etc/drbd.d/r0.res
# ------------------------------------------------------------------------------
# Edit `/etc/drbd.d/r0.res` and replace the empty/broken `net` section with
# production-grade fencing and split-brain resolution policies:
#
#   # vim /etc/drbd.d/r0.res
#
# Add the following syntax-valid directives inside the `net { ... }` block:
#
# resource r0 {
#     protocol C;
#
#     startup {
#         wfc-timeout 15;
#         degr-wfc-timeout 15;
#     }
#
#     net {
#         # Fencing policy: prevents split-brain when Pacemaker/Corosync fencing fires
#         fencing resource-only;
#
#         # Auto split-brain recovery policies based on node state count:
#         # 0 Primary nodes active: Discard data of the node with fewer modifications
#         after-sb-0pri discard-younger-primary;
#
#         # 1 Primary node active: Discard data on the Secondary node automatically
#         after-sb-1pri discard-secondary;
#
#         # 2 Primary nodes active (Dual-Primary/OCFS2/GFS2): Call notification script
#         after-sb-2pri call-pri-lost-after-sb;
#
#         # Fence peer handler when I/O connection breaks
#         rr-conflict disconnect;
#     }
#
#     handlers {
#         split-brain "/usr/lib/drbd/notify-split-brain.sh root";
#         fence-peer "/usr/lib/drbd/crm-fence-peer.sh";
#         unfence-peer "/usr/lib/drbd/crm-unfence-peer.sh";
#     }
#
#     disk {
#         on-io-error detach;
#     }

#     on node1 {
#         device    /dev/drbd0;
#         disk      /dev/loop10;
#         address   127.0.0.1:7788;
#         meta-disk internal;
#     }

#     on node2 {
#         device    /dev/drbd0;
#         disk      /dev/loop11;
#         address   127.0.0.1:7789;
#         meta-disk internal;
#     }
# }
#
# STEP 4: VERIFY CONFIGURATION & CLUSTER INTEGRATION
# ------------------------------------------------------------------------------
# 1. Validate DRBD configuration syntax:
#   # drbdadm dump r0
#
# 2. Adjust resource configuration dynamically without stopping replication:
#   # drbdadm adjust r0
#
# 3. Verify Pacemaker integration (if integrated as Master/Slave or Promotable clone):
#   # csi status (or pcs status)
#   Expected resource state:
#     * Clone Set: ms_drbd_r0 [drbd_r0] (promotable):
#       * Masters: [ node1 ]
#       * Slaves: [ node2 ]
# ==============================================================================