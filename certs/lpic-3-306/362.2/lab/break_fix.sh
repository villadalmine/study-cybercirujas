#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-3 306  (Exam 306-300, version 3.0)
#  Topic 362.2 — Cluster Storage Access   (exam weight: 5)
#
#  BREAK & FIX LAB  —  iSCSI shared-storage access denied by an ACL mismatch
# =============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  In a High Availability storage cluster the shared block device that later
#  feeds CLVM / GFS2 / OCFS2 (and is arbitrated by the Distributed Lock
#  Manager, DLM) is almost never a local disk: it is a LUN exported over a SAN.
#  On Linux the software SAN is Linux-IO (LIO) on the target side, driven by
#  'targetcli', and open-iscsi ('iscsiadm' + 'iscsid') on the initiator side.
#
#  A LUN is only visible to an initiator whose IQN matches an ACL entry on the
#  target's TPG (when generate_node_acls=0, ACLs are strictly enforced). Get
#  that identity wrong and the node simply cannot see the storage — the classic
#  "the cluster came up but /dev/sdX never appeared" incident.
#
#  This script builds a self-contained, loopback-only (127.0.0.1) iSCSI SAN,
#  proves it works, then breaks the target ACL so the initiator loses the LUN.
#  Your job is to restore access. Nothing outside this VM is touched.
#
#  SAFE FOR:   a disposable/throwaway lab VM ONLY. It rewrites
#              /etc/iscsi/initiatorname.iscsi (backed up) and creates one LIO
#              target. Do NOT run on a host with real iSCSI storage.
#
#  USAGE:      sudo ./362.2-break-and-fix.sh          # build + break the lab
#              sudo ./362.2-break-and-fix.sh cleanup  # tear everything down
#
#  SOURCES (official):
#    - LPI Exam 306 Objectives:
#        https://www.lpi.org/our-certifications/exam-306-objectives/
#    - Linux-IO (LIO) / targetcli:            http://linux-iscsi.org/
#        man 8 targetcli   —   man 5 targetcli
#    - open-iscsi (iscsiadm/iscsid):
#        https://github.com/open-iscsi/open-iscsi   —   man 8 iscsiadm
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Lab configuration (all identifiers are lab-scoped and reversible)
# ---------------------------------------------------------------------------
PORTAL_IP="127.0.0.1"
PORTAL_PORT="3260"
TARGET_IQN="iqn.2026-08.lab.lpic3:target01"
INIT_IQN="iqn.2026-08.lab.lpic3:initiator01"
ROGUE_IQN="iqn.2026-08.lab.lpic3:rogue"          # the wrong identity we inject
BACKSTORE="disk01"
BACKING_DIR="/var/lib/lab362"
BACKING_FILE="${BACKING_DIR}/${BACKSTORE}.img"
BACKING_SIZE="100M"
INIT_NAME_FILE="/etc/iscsi/initiatorname.iscsi"
INIT_NAME_BAK="/etc/iscsi/initiatorname.iscsi.lab362-bak"

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_R="$(printf '\033[0;31m')"; C_G="$(printf '\033[0;32m')"
  C_Y="$(printf '\033[0;33m')"; C_B="$(printf '\033[0;34m')"
  C_BOLD="$(printf '\033[1m')";  C_0="$(printf '\033[0m')"
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_BOLD=""; C_0=""
fi
info()  { printf '%s[*]%s %s\n'  "${C_B}"   "${C_0}" "$*"; }
ok()    { printf '%s[+]%s %s\n'  "${C_G}"   "${C_0}" "$*"; }
warn()  { printf '%s[!]%s %s\n'  "${C_Y}"   "${C_0}" "$*"; }
die()   { printf '%s[x]%s %s\n'  "${C_R}"   "${C_0}" "$*" >&2; exit 1; }
rule()  { printf '%s----------------------------------------------------------------------%s\n' "${C_BOLD}" "${C_0}"; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root (sudo). This lab manipulates the kernel LIO target and iscsid."
}

ensure_packages() {
  local need_targetcli=0 need_iscsi=0
  command -v targetcli >/dev/null 2>&1 || need_targetcli=1
  command -v iscsiadm  >/dev/null 2>&1 || need_iscsi=1
  [ "$need_targetcli" -eq 0 ] && [ "$need_iscsi" -eq 0 ] && return 0

  info "Installing missing packages (targetcli / open-iscsi)..."
  if   command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y targetcli-fb open-iscsi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y targetcli iscsi-initiator-utils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y targetcli iscsi-initiator-utils
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install targetcli iscsi-initiator-utils
  else
    die "No supported package manager found. Install 'targetcli' and 'open-iscsi/iscsi-initiator-utils' manually."
  fi
  command -v targetcli >/dev/null 2>&1 || die "targetcli still not available."
  command -v iscsiadm  >/dev/null 2>&1 || die "iscsiadm still not available."
}

start_iscsid() {
  modprobe iscsi_tcp 2>/dev/null || true
  systemctl start iscsid 2>/dev/null || service iscsid start 2>/dev/null || true
  # iscsid may be socket-activated; a discovery below will spin it up regardless.
}

# ---------------------------------------------------------------------------
# Helper: current iSCSI block device (by-path) for our portal/target, if any
# ---------------------------------------------------------------------------
lun_device() {
  ls -l /dev/disk/by-path/ 2>/dev/null \
    | grep -F "${PORTAL_IP}:${PORTAL_PORT}" \
    | grep -F "iscsi-${TARGET_IQN}" \
    | grep -oE '[a-z]*/(sd[a-z]+)$' | awk -F/ '{print $NF}' | head -n1
}

# ---------------------------------------------------------------------------
# BUILD: target (LIO) side
# ---------------------------------------------------------------------------
setup_target() {
  info "Building the iSCSI target (Linux-IO) ..."
  mkdir -p "${BACKING_DIR}"
  if [ ! -f "${BACKING_FILE}" ]; then
    truncate -s "${BACKING_SIZE}" "${BACKING_FILE}"
    ok "Created backing file ${BACKING_FILE} (${BACKING_SIZE})"
  fi

  # fileio backstore (idempotent: ignore 'already exists')
  targetcli /backstores/fileio create "${BACKSTORE}" "${BACKING_FILE}" "${BACKING_SIZE}" 2>/dev/null || true

  # target IQN + TPG
  targetcli /iscsi create "${TARGET_IQN}" 2>/dev/null || true

  # Bind the portal to loopback only (delete the default 0.0.0.0 wildcard)
  targetcli "/iscsi/${TARGET_IQN}/tpg1/portals" delete 0.0.0.0 3260 2>/dev/null || true
  targetcli "/iscsi/${TARGET_IQN}/tpg1/portals" create "${PORTAL_IP}" "${PORTAL_PORT}" 2>/dev/null || true

  # Map the LUN
  targetcli "/iscsi/${TARGET_IQN}/tpg1/luns" create "/backstores/fileio/${BACKSTORE}" 2>/dev/null || true

  # No CHAP; enforce explicit ACLs (generate_node_acls=0 -> the ACL matters)
  targetcli "/iscsi/${TARGET_IQN}/tpg1" set attribute authentication=0            >/dev/null
  targetcli "/iscsi/${TARGET_IQN}/tpg1" set attribute generate_node_acls=0        >/dev/null
  targetcli "/iscsi/${TARGET_IQN}/tpg1" set attribute demo_mode_write_protect=0   >/dev/null

  # The correct ACL: only our initiator IQN may see the LUN
  targetcli "/iscsi/${TARGET_IQN}/tpg1/acls" create "${INIT_IQN}" 2>/dev/null || true

  targetcli saveconfig >/dev/null
  systemctl enable --now target >/dev/null 2>&1 || true
  ok "Target ${TARGET_IQN} exporting 1 LUN on ${PORTAL_IP}:${PORTAL_PORT}, ACL=${INIT_IQN}"
}

# ---------------------------------------------------------------------------
# BUILD: initiator (open-iscsi) side + verify the LUN really appears
# ---------------------------------------------------------------------------
setup_initiator() {
  info "Configuring the iSCSI initiator (open-iscsi) ..."
  [ -f "${INIT_NAME_FILE}" ] && [ ! -f "${INIT_NAME_BAK}" ] && cp -a "${INIT_NAME_FILE}" "${INIT_NAME_BAK}"
  echo "InitiatorName=${INIT_IQN}" > "${INIT_NAME_FILE}"
  start_iscsid
  systemctl restart iscsid 2>/dev/null || service iscsid restart 2>/dev/null || true
  sleep 1

  info "Discovery (SendTargets) against ${PORTAL_IP}:${PORTAL_PORT} ..."
  iscsiadm -m discovery -t sendtargets -p "${PORTAL_IP}:${PORTAL_PORT}" >/dev/null
  # Expected:  127.0.0.1:3260,1 iqn.2026-08.lab.lpic3:target01

  info "Logging in ..."
  iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_IP}:${PORTAL_PORT}" --login >/dev/null
  # Expected:  Login to [iface: default, target: ...:target01, portal: 127.0.0.1,3260] successful.

  # Wait for udev to publish the block device
  local dev="" i
  for i in 1 2 3 4 5 6 7 8; do
    dev="$(lun_device || true)"; [ -n "${dev}" ] && break; sleep 1
  done
  [ -n "${dev}" ] || die "LUN did not appear after login — the base lab failed to build."
  ok "LUN is visible as /dev/${dev} — the SAN path works end to end."
}

# ---------------------------------------------------------------------------
# THE BREAK: swap the target ACL to a wrong IQN, drop the live session.
# Controlled, reversible, and confined to this VM.
# ---------------------------------------------------------------------------
do_break() {
  rule
  info "Injecting the fault ..."
  # 1) Replace the correct ACL with a rogue IQN the initiator will never match.
  targetcli "/iscsi/${TARGET_IQN}/tpg1/acls" delete "${INIT_IQN}"  2>/dev/null || true
  targetcli "/iscsi/${TARGET_IQN}/tpg1/acls" create "${ROGUE_IQN}" 2>/dev/null || true
  targetcli saveconfig >/dev/null
  # 2) Tear down the currently established session so the LUN disappears.
  iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_IP}:${PORTAL_PORT}" --logout >/dev/null 2>&1 || true
  sleep 1
  ok "Fault injected. The target no longer authorizes this initiator."
}

# ---------------------------------------------------------------------------
# CLEANUP: full teardown, restore initiator name
# ---------------------------------------------------------------------------
cleanup() {
  require_root
  info "Tearing down lab 362.2 ..."
  iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_IP}:${PORTAL_PORT}" --logout          >/dev/null 2>&1 || true
  iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_IP}:${PORTAL_PORT}" -o delete          >/dev/null 2>&1 || true
  targetcli "/iscsi" delete "${TARGET_IQN}"               2>/dev/null || true
  targetcli "/backstores/fileio" delete "${BACKSTORE}"    2>/dev/null || true
  targetcli saveconfig >/dev/null 2>&1 || true
  rm -f "${BACKING_FILE}"
  rmdir "${BACKING_DIR}" 2>/dev/null || true
  if [ -f "${INIT_NAME_BAK}" ]; then
    mv -f "${INIT_NAME_BAK}" "${INIT_NAME_FILE}"
    systemctl restart iscsid 2>/dev/null || service iscsid restart 2>/dev/null || true
    ok "Restored original ${INIT_NAME_FILE}"
  fi
  ok "Lab removed."
}

# ---------------------------------------------------------------------------
# Challenge briefing
# ---------------------------------------------------------------------------
briefing() {
  rule
  printf '%s  LPIC-3 306 · 362.2 Cluster Storage Access — YOUR MISSION%s\n' "${C_BOLD}" "${C_0}"
  rule
  cat <<EOF
CONTEXT
  A single-node loopback iSCSI SAN has just been built and was working:
  target ${C_BOLD}${TARGET_IQN}${C_0}
  exported one LUN on ${C_BOLD}${PORTAL_IP}:${PORTAL_PORT}${C_0}, and the initiator
  ${C_BOLD}${INIT_IQN}${C_0} could see it as a block device.

  A change was then applied to the target and the session was lost.

SYMPTOM YOU WILL OBSERVE
  * 'lsblk' no longer shows the iSCSI LUN; there is no active session
    ('iscsiadm -m session' reports "No active sessions").
  * Trying to log back in FAILS, e.g.:

      # iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_IP}:${PORTAL_PORT} --login
      iscsiadm: Could not login to [iface: default, target: ${TARGET_IQN}, \
                portal: ${PORTAL_IP},${PORTAL_PORT}].
      iscsiadm: initiator reported error (24 - iSCSI login failed due to \
                authorization failure)

    (LIO logs the reason as "Security negotiation failed" / reason 02,
     authorization failure — the target refuses the initiator.)

YOUR GOAL
  Restore the initiator's access to the LUN WITHOUT recreating the target or
  the backstore, and WITHOUT weakening security (do not disable ACLs, do not
  turn on demo/generate_node_acls). Success =
      - 'iscsiadm ... --login' reports "successful", and
      - 'lsblk' again shows the LUN as a local block device.

USEFUL STARTING POINTS
  cat ${INIT_NAME_FILE}
  iscsiadm -m session -P3
  targetcli ls /iscsi/${TARGET_IQN}/tpg1/acls
  journalctl -k | tail   # kernel/LIO messages about the rejected login

  When you are done experimenting, reset the VM with:
      sudo $0 cleanup
EOF
  rule
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  case "${1:-run}" in
    cleanup) cleanup; exit 0 ;;
    run) : ;;
    *) die "Unknown argument '${1}'. Use no argument to build the lab, or 'cleanup'." ;;
  esac

  require_root
  ensure_packages
  setup_target
  setup_initiator
  do_break
  briefing
}
main "$@"

# =============================================================================
#  SOLUTION  —  step by step (do not read until you have tried it yourself)
# =============================================================================
#
#  ROOT CAUSE
#  ----------
#  The target's TPG has  generate_node_acls=0, so LIO enforces explicit
#  Node ACLs: an initiator may log in ONLY if its InitiatorName (IQN) exactly
#  matches an ACL entry under the TPG. The break replaced the correct ACL
#  (iqn.2026-08.lab.lpic3:initiator01) with a rogue one
#  (iqn.2026-08.lab.lpic3:rogue). The initiator's own IQN never changed, so it
#  no longer matches any ACL -> the target rejects login with an authorization
#  failure (iscsiadm error 24, iSCSI login reason code 02).
#
#  DIAGNOSIS
#  ---------
#  1) Confirm the LUN is gone and there is no session:
#       lsblk
#       iscsiadm -m session            # -> "iscsiadm: No active sessions."
#
#  2) Reproduce the failure and read the exact error:
#       iscsiadm -m node -T iqn.2026-08.lab.lpic3:target01 \
#                -p 127.0.0.1:3260 --login
#       # iscsiadm: initiator reported error (24 - iSCSI login failed due to
#       #           authorization failure)
#       journalctl -k | tail
#       # LIO: "Rejecting non-authorized login ... reason 02" for our IQN.
#
#  3) Establish the initiator's true identity:
#       cat /etc/iscsi/initiatorname.iscsi
#       # InitiatorName=iqn.2026-08.lab.lpic3:initiator01
#
#  4) Inspect what the target actually authorizes:
#       targetcli ls /iscsi/iqn.2026-08.lab.lpic3:target01/tpg1/acls
#       # o- acls .................................. [ACLs: 1]
#       #   o- iqn.2026-08.lab.lpic3:rogue ......... [Mapped LUNs: 1]
#       #
#       # Mismatch: the ACL lists ':rogue', the initiator is ':initiator01'.
#
#  FIX  (make the target authorize the real initiator; keep ACLs enforced)
#  ----------------------------------------------------------------------
#  5) Remove the wrong ACL and add the correct one:
#       targetcli /iscsi/iqn.2026-08.lab.lpic3:target01/tpg1/acls \
#                 delete iqn.2026-08.lab.lpic3:rogue
#       targetcli /iscsi/iqn.2026-08.lab.lpic3:target01/tpg1/acls \
#                 create iqn.2026-08.lab.lpic3:initiator01
#       targetcli saveconfig
#
#     (Equivalent alternative — if the initiator's IQN were the authoritative
#      value and the ACL were 'correct', you would instead change the node:
#         echo "InitiatorName=iqn.2026-08.lab.lpic3:rogue" \
#              > /etc/iscsi/initiatorname.iscsi ; systemctl restart iscsid
#      Fix ONE side so the two IQNs agree — never both, and never by disabling
#      ACL enforcement.)
#
#  6) Log back in and verify:
#       iscsiadm -m node -T iqn.2026-08.lab.lpic3:target01 \
#                -p 127.0.0.1:3260 --login
#       # Login to [iface: default, target: ...:target01,
#       #           portal: 127.0.0.1,3260] successful.
#       lsblk
#       iscsiadm -m session -P3          # session state: LOGGED_IN, 1 LUN
#
#  WHY THIS MATTERS FOR 362.2
#  --------------------------
#  This same LUN is the foundation of clustered storage: once every node's IQN
#  is ACL-authorized and the LUN is multipathed (multipath/multipathd) so all
#  paths present one /dev/mapper/mpathN, it is handed to CLVM/GFS2/OCFS2, whose
#  concurrent access is serialized by the Distributed Lock Manager (DLM,
#  dlm_tool). An ACL/IQN mismatch on even one node is a silent way for that
#  node to be missing from the shared storage while Pacemaker still believes
#  the cluster is healthy.
# =============================================================================