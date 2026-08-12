#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-3 306 (exam 306-300, v3.0)
#  Topic 361.1 — High Availability Concepts and Theory
#  Break & Fix lab: QUORUM LOSS IN A TWO-NODE CLUSTER (the classic HA deadlock)
#
#  Source of objectives:
#    https://www.lpi.org/our-certifications/exam-306-objectives/
#  Concepts exercised:
#    single point of failure (SPOF), redundancy, active/passive failover,
#    quorum & votequorum, the two-node quorum special case, wait_for_all,
#    split-brain, fencing (STONITH), no-quorum-policy.
#  Reference docs (read them, do not memorise):
#    man 5 votequorum        (two_node, wait_for_all, expected_votes)
#    man 8 corosync-quorumtool
#    https://clusterlabs.org/pacemaker/doc/  (Quorum & Fencing)
#
#  WHAT THIS SCRIPT DOES
#    1. Bootstraps a self-contained, clearly-labelled *lab* cluster on THIS VM:
#       a two-node Corosync/Pacemaker cluster whose node2 is a phantom that
#       never boots (RFC-5737 TEST-NET address 192.0.2.2). two_node:1 keeps the
#       lone survivor quorate — exactly the mechanism this topic is about.
#    2. Adds a Dummy resource (stand-in for a floating VIP / service) and shows
#       it Started while the node is quorate.
#    3. BREAKS it: removes the two-node quorum special-casing, so the healthy
#       lone node suddenly considers itself OUT of quorum and Pacemaker stops
#       every resource.
#    4. Hands the challenge to you. The step-by-step SOLUTION is commented at
#       the very end of this file — try to solve it before you read it.
#
#  !!  DISPOSABLE LAB VMs ONLY  !!
#      This OVERWRITES /etc/corosync/corosync.conf and drives cluster services.
#      NEVER run it on a node that belongs to a cluster you care about.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME="lab-ha-361"
SENTINEL="# MANAGED-BY: lpic3-306-361.1-break-fix-lab"
CONF="/etc/corosync/corosync.conf"
BACKUP_DIR="/root/ha-lab-backups"
RES_ID="lab_dummy"
PHANTOM_ADDR="192.0.2.2"      # RFC 5737 TEST-NET-1: guaranteed non-routable
STAMP="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Pretty logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_R="\033[31m"; C_G="\033[32m"; C_Y="\033[33m"; C_B="\033[36m"; C_0="\033[0m"
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
log()  { printf "%b[lab]%b %s\n"  "$C_B" "$C_0" "$*"; }
ok()   { printf "%b[ ok]%b %s\n"  "$C_G" "$C_0" "$*"; }
warn() { printf "%b[!! ]%b %s\n"  "$C_Y" "$C_0" "$*"; }
die()  { printf "%b[err]%b %s\n"  "$C_R" "$C_0" "$*" >&2; exit 1; }
rule() { printf '%b%s%b\n' "$C_B" "----------------------------------------------------------------------" "$C_0"; }

usage() {
    cat <<EOF
Usage: $0 [command]

Commands:
  arm        (default) bootstrap the lab cluster, then break quorum
  status     show current quorum + resource state
  solve      apply the correct fix automatically (only if you give up)
  destroy    tear the lab cluster down and clean up

Environment:
  LAB_CONFIRM=yes   skip the interactive confirmation (for automation)
  FORCE=yes         proceed even if a non-lab cluster config is detected
EOF
}

# ---------------------------------------------------------------------------
# Safety guards
# ---------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root (cluster tooling needs it)."
}

require_tools() {
    local missing=() t
    for t in corosync pacemakerd corosync-quorumtool corosync-cfgtool \
             cibadmin crm_attribute crm_mon crm_resource systemctl; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        warn "Missing tools: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            die "Install with: apt-get install -y pacemaker corosync"
        elif command -v dnf >/dev/null 2>&1; then
            die "Install with: dnf install -y pacemaker corosync pcs resource-agents"
        else
            die "Install pacemaker + corosync + resource-agents for your distro."
        fi
    fi
}

confirm_lab() {
    # Refuse to clobber a real cluster unless it is ours or FORCE is set.
    if [ -f "$CONF" ] && ! grep -q "$SENTINEL" "$CONF"; then
        if [ "${FORCE:-no}" != "yes" ]; then
            die "$CONF exists and is NOT this lab's config. Refusing (set FORCE=yes to override on a throwaway VM)."
        fi
        warn "Overriding a pre-existing corosync.conf because FORCE=yes."
    fi
    if [ "${LAB_CONFIRM:-no}" = "yes" ]; then return 0; fi
    warn "This will OVERWRITE $CONF and restart cluster services on $(uname -n)."
    printf "Type YES to confirm this is a disposable lab VM: "
    local ans; read -r ans
    [ "$ans" = "YES" ] || die "Aborted by user."
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
primary_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "$ip" ] && ip="127.0.0.1"
    printf '%s' "$ip"
}

wait_cib() { # wait until the CIB (Pacemaker) is answering
    local t="${1:-40}"
    while [ "$t" -gt 0 ]; do
        cibadmin -Q >/dev/null 2>&1 && return 0
        sleep 1; t=$((t-1))
    done
    return 1
}

quorate_state() { # prints "Yes" or "No"; corosync-quorumtool exits 1 when not quorate
    local out
    out="$(corosync-quorumtool -s 2>/dev/null || true)"
    printf '%s' "$out" | awk -F': *' 'tolower($1) ~ /^quorate$/ {print $2; exit}'
}

wait_quorate() { # $1 = Yes|No, $2 = timeout
    local want="$1" t="${2:-15}"
    while [ "$t" -gt 0 ]; do
        [ "$(quorate_state)" = "$want" ] && return 0
        sleep 1; t=$((t-1))
    done
    return 1
}

resource_started() {
    crm_mon -1 -r 2>/dev/null | grep -Eq "${RES_ID}[[:space:]].*Started"
}

apply_quorum_change() { # $1 = expected quorate state after change (Yes|No)
    # First try the graceful in-place reload an admin would use...
    corosync-cfgtool -R >/dev/null 2>&1 || true
    if wait_quorate "$1" 8; then return 0; fi
    # ...fall back to a clean restart for a deterministic lab symptom.
    log "Live reload was not enough; performing a clean corosync restart."
    systemctl stop pacemaker  >/dev/null 2>&1 || true
    systemctl restart corosync
    systemctl start pacemaker
    wait_cib 40 || true
    wait_quorate "$1" 30 || true
}

# ---------------------------------------------------------------------------
# Bootstrap the healthy baseline cluster
# ---------------------------------------------------------------------------
bootstrap() {
    local node_name node_addr
    node_name="$(uname -n)"
    node_addr="$(primary_ip)"

    mkdir -p "$BACKUP_DIR" /var/log/corosync
    if [ -f "$CONF" ]; then
        cp -a "$CONF" "$BACKUP_DIR/corosync.conf.$STAMP.bak"
        log "Backed up existing config to $BACKUP_DIR/corosync.conf.$STAMP.bak"
    fi

    log "Writing baseline HA config (node1=$node_name/$node_addr, node2=phantom/$PHANTOM_ADDR)."
    cat > "$CONF" <<EOF
$SENTINEL
totem {
    version: 2
    cluster_name: $CLUSTER_NAME
    transport: udpu
    crypto_cipher: none
    crypto_hash: none
}

logging {
    to_syslog: yes
    to_logfile: yes
    logfile: /var/log/corosync/corosync.log
    timestamp: on
}

quorum {
    provider: corosync_votequorum
    two_node: 1
    wait_for_all: 0
}

nodelist {
    node {
        name: $node_name
        nodeid: 1
        ring0_addr: $node_addr
    }
    node {
        name: lab-phantom-node2
        nodeid: 2
        ring0_addr: $PHANTOM_ADDR
    }
}
EOF

    systemctl enable corosync pacemaker >/dev/null 2>&1 || true
    systemctl restart corosync
    systemctl restart pacemaker
    wait_cib 40 || die "Pacemaker CIB did not come up."
    wait_quorate "Yes" 20 || warn "Node is not quorate yet; continuing anyway."

    # Lab cluster policy: no real fence device on a single throwaway VM, and
    # make quorum enforcement explicit so the break is visible.
    crm_attribute -t crm_config -n stonith-enabled  -v false >/dev/null 2>&1 || true
    crm_attribute -t crm_config -n no-quorum-policy  -v stop  >/dev/null 2>&1 || true

    # Add a Dummy resource (stands in for a floating VIP / managed service).
    if ! cibadmin -Q -o resources 2>/dev/null | grep -q "id=\"$RES_ID\""; then
        cibadmin --create --scope resources --xml-text \
"<primitive id=\"$RES_ID\" class=\"ocf\" provider=\"pacemaker\" type=\"Dummy\">
   <operations>
     <op id=\"$RES_ID-monitor-10s\" name=\"monitor\" interval=\"10s\" timeout=\"20s\"/>
   </operations>
 </primitive>" >/dev/null
    fi

    local t=25
    while [ "$t" -gt 0 ] && ! resource_started; do sleep 1; t=$((t-1)); done
    ok "Baseline is up: node quorate, resource '$RES_ID' Started."
}

# ---------------------------------------------------------------------------
# The controlled break
# ---------------------------------------------------------------------------
break_it() {
    cp -a "$CONF" "$BACKUP_DIR/corosync.conf.prebreak.$STAMP.bak"
    log "Introducing the fault into $CONF ..."
    # THE FAULT: remove the two-node quorum special case. Now the surviving
    # lone node needs 2 of 2 votes and can never reach it while node2 is down.
    sed -i 's/^\([[:space:]]*two_node:\)[[:space:]]*1[[:space:]]*$/\1 0/' "$CONF"
    apply_quorum_change "No"
    ok "Fault injected."
}

# ---------------------------------------------------------------------------
# Status / mission briefing
# ---------------------------------------------------------------------------
show_status() {
    rule
    echo "corosync-quorumtool -s:"
    corosync-quorumtool -s 2>/dev/null || true
    echo
    echo "crm_mon -1 -r  (resource view):"
    crm_mon -1 -r 2>/dev/null || true
    rule
}

briefing() {
    rule
    printf "%b  361.1 CHALLENGE — the cluster just lost quorum%b\n" "$C_Y" "$C_0"
    rule
    cat <<'EOF'
SYMPTOM you will observe:
  * `corosync-quorumtool -s`  -> "Quorate:  No"  (Total votes 1, Expected 2).
  * `crm_mon -1` / `pcs status` -> "partition WITHOUT quorum".
  * The resource 'lab_dummy' is Stopped — nothing runs, even though THIS node
    is perfectly healthy. A single-node outage has taken the whole service down:
    that is precisely the quorum deadlock HA is supposed to avoid.

YOUR OBJECTIVE:
  Bring the surviving node back to a quorate state so Pacemaker restarts the
  resource — and do it the RIGHT way. Understand *why* one healthy node thinks
  it has lost quorum in a two-node cluster.

RULES OF THE EXERCISE (this is a concepts topic — reason, do not brute-force):
  * Do NOT "solve" it with `no-quorum-policy=ignore`. That silences the alarm
    and invites split-brain; it is the classic wrong answer.
  * The second node is GONE for good in this lab — you must recover with the
    node you have, using the two-node quorum mechanism correctly.

Useful commands while you work:
  corosync-quorumtool -s
  grep -E 'two_node|wait_for_all|expected_votes' /etc/corosync/corosync.conf
  man 5 votequorum
  crm_mon -1 -r

When you have restored quorum:  Quorate = Yes  and  lab_dummy = Started.
(If you get stuck, the full solution is commented at the bottom of this script,
 or run:  sudo bash "$0" solve )
EOF
    rule
}

# ---------------------------------------------------------------------------
# Automatic solver (spoiler) + teardown
# ---------------------------------------------------------------------------
solve() {
    log "Applying the correct fix: restore two-node quorum semantics."
    sed -i 's/^\([[:space:]]*two_node:\)[[:space:]]*0[[:space:]]*$/\1 1/' "$CONF"
    apply_quorum_change "Yes"
    local t=25
    while [ "$t" -gt 0 ] && ! resource_started; do sleep 1; t=$((t-1)); done
    if [ "$(quorate_state)" = "Yes" ] && resource_started; then
        ok "Recovered: Quorate=Yes, '$RES_ID' Started."
    else
        warn "Not fully recovered yet. Try: crm_resource --refresh ; then re-check crm_mon -1 -r"
    fi
    show_status
}

destroy() {
    log "Tearing down the lab cluster."
    systemctl stop pacemaker corosync >/dev/null 2>&1 || true
    systemctl disable pacemaker corosync >/dev/null 2>&1 || true
    rm -f /var/lib/pacemaker/cib/cib.xml* /var/lib/pacemaker/cib/shadow.* 2>/dev/null || true
    if [ -f "$CONF" ] && grep -q "$SENTINEL" "$CONF"; then
        rm -f "$CONF"
        log "Removed lab corosync.conf (backups kept in $BACKUP_DIR)."
    fi
    ok "Lab destroyed. Backups (if any) remain in $BACKUP_DIR."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local cmd="${1:-arm}"
    case "$cmd" in
        arm)
            require_root; require_tools; confirm_lab
            bootstrap
            break_it
            show_status
            briefing
            ;;
        status)  require_root; require_tools; show_status ;;
        solve)   require_root; require_tools; solve ;;
        destroy) require_root; require_tools; destroy ;;
        -h|--help|help) usage ;;
        *) usage; die "Unknown command: $cmd" ;;
    esac
}
main "$@"

# ###########################################################################
# #                                                                         #
# #   S O L U T I O N   —   try the challenge before reading this           #
# #                                                                         #
# ###########################################################################
#
# WHY IT BROKE (the theory this topic tests)
# ------------------------------------------
# votequorum decides "quorate" by comparing the votes a partition can see
# against the quorum threshold. With N expected votes, quorum = floor(N/2)+1.
# For a normal two-node cluster that is 2 — meaning a single surviving node
# (1 vote) is NEVER quorate, and with `no-quorum-policy: stop` Pacemaker stops
# everything. One node down => total outage. That is the two-node quorum trap.
#
# The special setting `two_node: 1` exists exactly to escape it: corosync then
# treats a lone surviving node as quorate (effective quorum = 1). It is safe to
# do this ONLY because it is paired with:
#     * wait_for_all — on a cold start the cluster refuses quorum until it has
#       seen BOTH nodes at least once, so two isolated nodes cannot each boot
#       and both claim quorum; and
#     * fencing (STONITH) — the survivor shoots the peer before taking over,
#       so a partitioned (not dead) peer cannot keep running the same service.
# Together they prevent SPLIT-BRAIN. The break simply set `two_node: 0`,
# collapsing back into the two-node trap: healthy node, but "Quorate: No".
#
# STEP-BY-STEP FIX
# ----------------
#   1. Confirm the symptom and read the numbers:
#         corosync-quorumtool -s
#         # Expected votes: 2 | Total votes: 1 | Quorum: 2 | Quorate: No
#         crm_mon -1 -r          # "partition WITHOUT quorum", lab_dummy Stopped
#
#   2. Inspect the quorum stanza and spot the regression:
#         grep -E 'two_node|wait_for_all|expected_votes' /etc/corosync/corosync.conf
#         # -> two_node: 0        <== the fault
#         man 5 votequorum        # confirm what two_node/wait_for_all do
#
#   3. Restore the two-node quorum special case:
#         vi /etc/corosync/corosync.conf
#         # in the quorum { } block:
#         #     provider: corosync_votequorum
#         #     two_node: 1
#         #     wait_for_all: 0        # 0 lets the lone survivor be quorate now;
#         #                            # in PRODUCTION prefer wait_for_all: 1
#         #                            # (safer cold-start) *plus* real fencing.
#
#   4. Apply the change WITHOUT a full outage (live reload):
#         corosync-cfgtool -R
#      Verify quorum returned:
#         corosync-quorumtool -s          # Quorate: Yes, Quorum: 1
#      (If a stubborn build ignores the live change, do a clean restart:
#         systemctl stop pacemaker && systemctl restart corosync && systemctl start pacemaker )
#
#   5. Pacemaker re-evaluates automatically once quorum is back and starts the
#      resource. If it lingers, clear stale state and nudge it:
#         crm_resource --refresh
#         crm_mon -1 -r                   # lab_dummy -> Started
#
#   SUCCESS CRITERIA:  Quorate: Yes   AND   lab_dummy Started.
#
# WHAT NOT TO DO, AND WHY (exam-relevant discussion)
# --------------------------------------------------
#   * `crm_attribute -t crm_config -n no-quorum-policy -v ignore`
#       Makes resources run without quorum. It "works" instantly and is WRONG:
#       in a real two-node cluster a network partition would then let BOTH nodes
#       run the service and corrupt shared data — split-brain.
#   * Faking `expected_votes: 1`
#       Also masks the symptom but throws away the very redundancy HA exists for.
#
# THE PRODUCTION-CORRECT PICTURE (know this for the theory objective)
# -------------------------------------------------------------------
#   Two-node HA done properly = two_node:1 + wait_for_all:1 + working STONITH
#   fencing. If you want a node to survive a partition safely WITHOUT relying on
#   fencing alone, add a lightweight arbitrator: corosync-qdevice with a
#   qnetd tie-breaker turns 2 votes into an odd 3, giving real majority quorum
#   and removing the two-node special case entirely. That is the scalable answer
#   and the direction the LPIC-3 306 objectives point you toward.
#
# Cleanup when finished:   sudo bash "$0" destroy
# ###########################################################################