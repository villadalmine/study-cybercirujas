#!/usr/bin/env bash
#
# LPIC-3 306 (exam 306-300, v3.0) — Topic 361.3: Failover Clusters
# Break & Fix lab — Pacemaker / Corosync / pcs
#
# WHAT THIS IS
#   A self-contained lab that (1) makes sure a tiny single-node Pacemaker
#   cluster with a running resource group exists, (2) breaks it in ONE
#   controlled, fully reversible way, and (3) tells you the symptom to look
#   for and the goal to reach. The step-by-step answer key is COMMENTED at
#   the bottom of this file — try to solve it first, then read it.
#
# RUN THIS ONLY ON A DISPOSABLE LAB VM. It edits the cluster CIB. Never point
# it at a production or shared cluster. It only ever touches a resource group
# named "web" that it creates itself, and it backs up the CIB before breaking.
#
# Official references:
#   - LPI 306 objectives:      https://www.lpi.org/our-certifications/exam-306-objectives/
#   - Pacemaker Explained:     https://clusterlabs.org/pacemaker/doc/
#   - ClusterLabs quickstart:  https://clusterlabs.org/quickstart.html
#   - pcs command reference:   https://clusterlabs.org/pacemaker/pcs/
#   - Corosync:                https://corosync.github.io/corosync/

set -euo pipefail

HAPASS="lab-lpic3-306"
BACKUP="/root/361.3-cib-before-break.xml"

# ── 0. Safety guard ───────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (this configures Pacemaker/Corosync)." >&2
    exit 1
fi

if ! command -v pcs >/dev/null 2>&1; then
    echo "ERROR: 'pcs' not found. Install the HA stack first, e.g.:" >&2
    echo "  RHEL/Rocky/Alma:  dnf install -y pacemaker corosync pcs" >&2
    echo "  Debian/Ubuntu:    apt-get install -y pacemaker corosync pcs" >&2
    echo "  openSUSE/SLES:    zypper install -y pacemaker corosync crmsh pcs" >&2
    exit 1
fi

if [[ "${LPI_LAB_IWILLBREAKTHIS:-}" != "yes" ]]; then
    echo "This lab will MODIFY the local cluster CIB on this VM."
    read -r -p "Type 'yes' if this is a disposable lab VM you can break: " ans
    [[ "${ans}" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

# ── 1. Ensure a running single-node cluster ───────────────────────────────
bootstrap_cluster() {
    echo ">> No running cluster detected — bootstrapping a single-node lab cluster."
    echo "hacluster:${HAPASS}" | chpasswd
    systemctl enable --now pcsd >/dev/null 2>&1 || service pcsd start || true
    sleep 2
    # pcs 0.10/0.11 syntax first, fall back to legacy 0.9 (RHEL7) syntax.
    if pcs host auth "${NODE}" -u hacluster -p "${HAPASS}" >/dev/null 2>&1; then
        pcs cluster setup ha_lab "${NODE}" --force >/dev/null
    else
        pcs cluster auth "${NODE}" -u hacluster -p "${HAPASS}" --force >/dev/null 2>&1 || true
        pcs cluster setup --name ha_lab "${NODE}" --force >/dev/null
    fi
    pcs cluster start --all >/dev/null
    pcs cluster enable --all >/dev/null
    # Single-node lab conveniences: no real fence device, keep quorum trivial.
    pcs property set stonith-enabled=false
    pcs property set no-quorum-policy=ignore
}

NODE="$(crm_node -n 2>/dev/null || uname -n)"

if ! crm_mon -1 >/dev/null 2>&1; then
    bootstrap_cluster
    NODE="$(crm_node -n 2>/dev/null || uname -n)"
else
    echo ">> Existing cluster detected on node '${NODE}'. Reusing it."
fi

# ── 2. Ensure the demo resource group exists and is running ───────────────
if ! pcs resource config web_svc >/dev/null 2>&1; then
    echo ">> Creating demo resource group 'web' (two Dummy resources)."
    pcs resource create web_vip ocf:pacemaker:Dummy op monitor interval=10s timeout=20s >/dev/null
    pcs resource create web_svc ocf:pacemaker:Dummy op monitor interval=10s timeout=20s >/dev/null
    pcs resource group add web web_vip web_svc >/dev/null
fi

# Guarantee a clean healthy baseline before we break anything.
pcs resource enable web >/dev/null 2>&1 || true
pcs resource clear  web >/dev/null 2>&1 || true

wait_state() {  # $1 = Started|Stopped
    for _ in $(seq 1 30); do
        if crm_mon -1 2>/dev/null | grep -Eq "web_svc.*$1"; then return 0; fi
        sleep 2
    done
    return 1
}

if ! wait_state Started; then
    echo "ERROR: the 'web' group would not start on a healthy cluster." >&2
    echo "Investigate with: pcs status ; crm_mon -1rf ; journalctl -u pacemaker" >&2
    exit 1
fi
echo ">> Baseline OK: resource group 'web' is Started on '${NODE}'."

# ── 3. THE CONTROLLED BREAK ───────────────────────────────────────────────
# Back up the exact CIB so recovery is always possible, then strand the group
# the same way a forgotten `pcs resource move`/`ban` does in the real world:
# a leftover -INFINITY location constraint (cli-ban-*) that forbids the node.
echo ">> Backing up CIB to ${BACKUP}"
pcs cluster cib > "${BACKUP}"

echo ">> Breaking: banning resource group 'web' from node '${NODE}'."
pcs resource ban web "${NODE}" >/dev/null

if ! wait_state Stopped; then
    echo "WARN: group did not stop (multi-node cluster?). This lab expects a single node." >&2
fi

# ── 4. Brief the student ──────────────────────────────────────────────────
cat <<EOF

============================================================================
 LPIC-3 306 — 361.3 Failover Clusters — BREAK & FIX  (node: ${NODE})
============================================================================

SYMPTOM you will observe:
  * 'pcs status' shows resources web_vip and web_svc as **Stopped**.
  * There are **no** "Failed Resource Actions" — the monitors never failed.
  * The cluster is quorate and healthy; the resources simply refuse to run.

YOUR GOAL:
  * Get the 'web' group **Started** again on this node.
  * Do it WITHOUT deleting or recreating the resources.
  * Be able to explain WHY the resources were Stopped even though nothing
    "failed", and why the obvious reflex fix does nothing here.

HINTS:
  * A "Stopped" resource is not the same as a "Failed" one.
  * Ask Pacemaker where it is *allowed* to place the resource, and why.
  * Read the location constraints and the allocation scores, not just status.

Starter commands:
  pcs status
  crm_mon -1rf
  pcs constraint --full

The full answer key is COMMENTED at the bottom of this script.
A pre-break CIB backup is saved at: ${BACKUP}
============================================================================
EOF

exit 0

# ============================================================================
# SOLUTION — answer key (read only after attempting the fix)
# ============================================================================
#
# 1. Read the real state. The group is Stopped but there is NO "Failed
#    Resource Actions" section — this is placement policy, not a crash:
#        pcs status
#        crm_mon -1rf
#
# 2. The naive reflex is to "clear failures". Try it and watch nothing
#    change, because there are no failcounts to clear:
#        pcs resource cleanup web        # <-- no effect in this scenario
#
# 3. Inspect location constraints. A ban left behind by `pcs resource
#    move`/`pcs resource ban` appears as an auto-generated cli-ban-* rule
#    scoring the node at -INFINITY:
#        pcs constraint --full
#        pcs constraint location --full
#    Expected line (id/name will match your node):
#        Constraint: cli-ban-web-on-<node>   Rule: score=-INFINITY ...
#
# 4. Confirm it against the allocation scores — this is how Pacemaker decides
#    placement, and -INFINITY forbids the node outright:
#        crm_simulate -sL 2>/dev/null | grep -Ei 'web.*allocation score'
#    You will see something like:
#        ... web_vip allocation score on <node>: -INFINITY
#
# 5. Apply the correct fix — remove the ban (do NOT recreate the resource).
#    Either clear it by resource:
#        pcs resource clear web
#    or delete the constraint by its id:
#        pcs constraint delete cli-ban-web-on-<node>
#
#    crmsh equivalents (SUSE/Debian):
#        crm status
#        crm configure show | grep -i cli-ban
#        crm resource clear web        # or: crm configure delete cli-ban-web-on-<node>
#
# 6. Verify recovery:
#        pcs status                    # web_vip and web_svc -> Started
#        crm_mon -1
#
# Escape hatch (restore the exact pre-break state):
#        pcs cluster cib-push /root/361.3-cib-before-break.xml
#
# ROOT CAUSE / LESSON
#   "Stopped" is not "Failed". A perfectly healthy resource can be unrunnable
#   because a location constraint scores every candidate node at -INFINITY.
#   `pcs resource move` and `pcs resource ban` create exactly such a
#   constraint and DO NOT auto-expire unless you used the lifetime/--wait
#   options or run `pcs resource clear` afterwards — a classic production
#   incident. Failover placement is driven by additive scores (location,
#   colocation, stickiness, INFINITY); always read the constraints and the
#   allocation scores (crm_simulate -sL) before reaching for cleanup.
# ============================================================================