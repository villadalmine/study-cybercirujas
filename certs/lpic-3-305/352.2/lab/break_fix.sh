#!/usr/bin/env bash
#
# =============================================================================
#  teach-plat :: LPIC-3 305 (Exam 305-300, v3.0)
#  Topic 352.2 — LXC  |  Break & Fix laboratory drill
# =============================================================================
#
#  WHAT THIS IS
#  ------------
#  A self-contained "break & fix" exercise for the LXC objective of the
#  LPIC-3 Virtualization and Containerization exam. It deliberately introduces
#  ONE controlled, fully reversible fault into a throw-away LXC container and
#  then hands control back to you. Your job is to diagnose it with the standard
#  LXC toolchain (lxc-ls, lxc-info, lxc-start -F, the container config file)
#  and bring the container back to a RUNNING state with working networking.
#
#  The step-by-step solution is at the BOTTOM of this file, commented out, so
#  you can (and should) struggle first. Reveal it with:  ./352.2-lxc-breakfix.sh --solution
#
#  Reference: LPI Exam 305 Objectives — https://www.lpi.org/our-certifications/exam-305-objectives/
#  Reference: LXC container config — man 5 lxc.container.conf
#             https://linuxcontainers.org/lxc/manpages/man5/lxc.container.conf.5.html
#
#  SAFETY MODEL
#  ------------
#  * Runs ONLY on a disposable lab VM. It refuses to run unless you opt in
#    explicitly (see the guard below). Do NOT run this on anything you care
#    about — it edits a container's config file (a backup is taken regardless).
#  * It never touches host networking, never deletes data, and every change it
#    makes is undone by `--reset` or by following the solution.
#
#  USAGE
#  -----
#     sudo ./352.2-lxc-breakfix.sh            # set up the lab and break it
#     sudo ./352.2-lxc-breakfix.sh --reset    # restore the pristine config (give up)
#          ./352.2-lxc-breakfix.sh --solution # print the walkthrough and exit
#
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
CT_NAME="${CT_NAME:-lab305}"          # container used for the drill
CT_TEMPLATE="${CT_TEMPLATE:-busybox}" # busybox: tiny, offline, self-contained
LXC_PATH="$(lxc-config lxc.lxcpath 2>/dev/null || echo /var/lib/lxc)"
CT_DIR="${LXC_PATH}/${CT_NAME}"
CT_CONFIG="${CT_DIR}/config"
PRISTINE_BAK="${CT_DIR}/config.pristine.bak"   # golden copy, taken once
BROKEN_BRIDGE="lxcbr-ghost0"          # a bridge that intentionally does NOT exist

# ANSI helpers (degrade gracefully if not a tty)
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"
  YEL="$(printf '\033[33m')"; CYN="$(printf '\033[36m')"; RST="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$CYN" "$RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# --solution : print the walkthrough (the commented block at EOF) and exit
# ----------------------------------------------------------------------------
if [ "${1:-}" = "--solution" ]; then
  # Extract the SOLUTION heredoc-style block at the end of this file.
  sed -n '/^# >>> SOLUTION START/,/^# <<< SOLUTION END/p' "$0" \
    | sed 's/^# \{0,1\}//'
  exit 0
fi

# ----------------------------------------------------------------------------
# Safety guard — must be an opted-in disposable lab
# ----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root (sudo). LXC system containers live under ${LXC_PATH}."

if [ ! -e /etc/teach-plat-lab ] && [ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB:-}" != "yes" ]; then
  die "Refusing to run: this is a destructive lab drill.
    Opt in on your throw-away VM with ONE of:
      touch /etc/teach-plat-lab
      I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes sudo -E $0"
fi

command -v lxc-create >/dev/null 2>&1 || die "LXC tools not found. Install: apt-get install -y lxc lxc-templates (Debian/Ubuntu) or lxc lxc-templates (openSUSE/EL)."

# ----------------------------------------------------------------------------
# --reset : restore the pristine config and stop (the 'give up' path)
# ----------------------------------------------------------------------------
if [ "${1:-}" = "--reset" ]; then
  [ -f "$PRISTINE_BAK" ] || die "No pristine backup at ${PRISTINE_BAK}. Nothing to reset."
  lxc-stop -n "$CT_NAME" -k >/dev/null 2>&1 || true
  cp -a "$PRISTINE_BAK" "$CT_CONFIG"
  ok "Restored pristine config for '${CT_NAME}'. Try: lxc-start -n ${CT_NAME} && lxc-info -n ${CT_NAME}"
  exit 0
fi

# ----------------------------------------------------------------------------
# 1) Ensure a healthy lab container exists (idempotent)
# ----------------------------------------------------------------------------
if ! lxc-ls -1 2>/dev/null | grep -qx "$CT_NAME"; then
  info "Creating disposable container '${CT_NAME}' from the '${CT_TEMPLATE}' template ..."
  # busybox template is host-local and needs no image download — ideal for labs.
  lxc-create -n "$CT_NAME" -t "$CT_TEMPLATE" >/dev/null \
    || die "lxc-create failed. On a networked VM you can instead use:
       lxc-create -n ${CT_NAME} -t download -- -d debian -r bookworm -a amd64"
  ok "Container '${CT_NAME}' created."
else
  info "Container '${CT_NAME}' already present — reusing it."
fi

# Take the pristine backup exactly once, BEFORE we ever break anything.
if [ ! -f "$PRISTINE_BAK" ]; then
  cp -a "$CT_CONFIG" "$PRISTINE_BAK"
  ok "Saved pristine config -> ${PRISTINE_BAK}"
fi

# Discover the real bridge this container is currently wired to (for our records).
CURRENT_LINK="$(awk -F'=' '/^[[:space:]]*lxc\.net\.0\.link/{gsub(/[[:space:]]/,"",$2); print $2}' "$CT_CONFIG" | tail -n1)"
CURRENT_LINK="${CURRENT_LINK:-lxcbr0}"

# Make sure it starts cleanly before we sabotage it, so the fault is unambiguous.
lxc-stop -n "$CT_NAME" -k >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# 2) THE CONTROLLED BREAK
#    Re-point the container's veth to a bridge that does not exist. Everything
#    else about the container is fine; only lxc.net.0.link is poisoned.
# ----------------------------------------------------------------------------
info "Injecting the fault into ${CT_CONFIG} ..."
if grep -qE '^[[:space:]]*lxc\.net\.0\.link' "$CT_CONFIG"; then
  sed -i -E "s|^[[:space:]]*lxc\.net\.0\.link.*|lxc.net.0.link = ${BROKEN_BRIDGE}|" "$CT_CONFIG"
else
  # If the template produced no net stanza, synthesize a broken veth one.
  cat >> "$CT_CONFIG" <<EOF
lxc.net.0.type = veth
lxc.net.0.link = ${BROKEN_BRIDGE}
lxc.net.0.flags = up
EOF
fi
ok "Fault injected."

# ----------------------------------------------------------------------------
# 3) Brief the student
# ----------------------------------------------------------------------------
cat <<EOF

${BOLD}================ LPIC-3 305 · 352.2 LXC · BREAK & FIX ================${RST}

I have broken container ${BOLD}${CT_NAME}${RST} in ONE specific way.

${BOLD}SYMPTOM you will observe${RST}
  * The container refuses to start. Reproduce it:

        lxc-start -n ${CT_NAME}
        echo "exit code: \$?"          # non-zero
        lxc-info -n ${CT_NAME}          # State: STOPPED

  * Running it in the FOREGROUND with logging reveals the real cause:

        lxc-start -n ${CT_NAME} -F -l DEBUG -o /tmp/${CT_NAME}.log
        # ... then read the error, or:
        grep -iE 'network|bridge|link|veth|ERROR' /tmp/${CT_NAME}.log

    You will see a failure to set up the container network — LXC cannot
    attach the container's veth endpoint to its configured bridge.

${BOLD}YOUR GOAL${RST}
  Bring ${CT_NAME} to a ${GRN}RUNNING${RST} state with a working network interface:

        lxc-start -n ${CT_NAME}
        lxc-info -n ${CT_NAME}          # State: RUNNING, plus an IP line
        lxc-ls -f                       # ${CT_NAME} shown RUNNING with an address

${BOLD}HINTS${RST} (use, in order, only as many as you need)
  1. The rootfs is fine — this is a ${BOLD}networking${RST} fault. Focus on lxc.net.*
  2. Inspect the container config:   less ${CT_CONFIG}
     Compare lxc.net.0.link against the bridges that actually exist:
         ip -br link show type bridge      (or: brctl show / lxc-checkconfig)
  3. Either re-point lxc.net.0.link at an existing bridge (the standard one is
     'lxcbr0', provided by the lxc-net service) OR make the referenced bridge
     real. Then restart the container.

${BOLD}TOOLS TO KEEP HANDY${RST}
  lxc-ls -f · lxc-info -n · lxc-start -F -l DEBUG -o · lxc-stop -n · lxc-attach -n
  ip -br addr · ip -br link show type bridge · systemctl status lxc-net

Give up and restore the pristine config with:
      sudo $0 --reset
Reveal the full walkthrough with:
      $0 --solution

${BOLD}=====================================================================${RST}

EOF

warn "For your notes: before the break, this container was wired to bridge '${CURRENT_LINK}'."
info "Good luck. Diagnose from the symptom, not from memory."
exit 0

# =============================================================================
# >>> SOLUTION START
# ================== SOLUTION — 352.2 LXC break & fix ==================
#
# ROOT CAUSE
#   The container's virtual ethernet endpoint (lxc.net.0.type = veth) was told
#   to attach to bridge "lxcbr-ghost0", which does not exist on the host. When
#   LXC brings the container up it creates the veth pair and tries to enslave
#   the host-side end to that bridge; the bridge is missing, network setup
#   fails, and lxc-start aborts the whole start — so the container stays
#   STOPPED even though its rootfs and everything else are perfectly healthy.
#
# STEP 1 — Confirm the symptom and capture the real error
#   lxc-start -n lab305 ; echo $?            # non-zero exit
#   lxc-info -n lab305                        # State: STOPPED
#   lxc-start -n lab305 -F -l DEBUG -o /tmp/lab305.log
#   grep -iE 'bridge|link|veth|network|ERROR' /tmp/lab305.log
#   # The log points at failing to attach the veth to the configured bridge.
#
# STEP 2 — Read the offending configuration
#   grep -n 'lxc.net' /var/lib/lxc/lab305/config
#   # -> lxc.net.0.link = lxcbr-ghost0     <-- the culprit
#
# STEP 3 — List the bridges that ACTUALLY exist
#   ip -br link show type bridge
#   brctl show 2>/dev/null                    # if bridge-utils is installed
#   systemctl status lxc-net                  # lxc-net provides lxcbr0
#   # Typically you will see 'lxcbr0' (or none, if lxc-net is not running).
#
# STEP 4 — Fix it. Two valid approaches:
#
#   (A) Point the container at a real bridge (the usual, correct fix):
#       sed -i -E 's|^\s*lxc.net.0.link.*|lxc.net.0.link = lxcbr0|' \
#           /var/lib/lxc/lab305/config
#       # Ensure the standard LXC bridge is actually up:
#       systemctl enable --now lxc-net        # brings up lxcbr0 + dnsmasq
#
#   (B) OR make the referenced bridge real (valid if that name was intended):
#       ip link add lxcbr-ghost0 type bridge
#       ip link set lxcbr-ghost0 up
#       # (add an address / dnsmasq if you want the container to get an IP)
#
# STEP 5 — Restart and verify the goal state
#   lxc-stop -n lab305 -k 2>/dev/null || true
#   lxc-start -n lab305
#   lxc-info -n lab305                         # State: RUNNING  + IP: a.b.c.d
#   lxc-ls -f                                  # lab305  RUNNING  10.0.3.x
#   # Prove connectivity from inside the container:
#   lxc-attach -n lab305 -- ip -br addr
#   lxc-attach -n lab305 -- ping -c1 <gateway>
#
# STEP 6 — (Optional) restore the exact pristine config
#   sudo ./352.2-lxc-breakfix.sh --reset
#
# WHY THIS MATTERS FOR THE EXAM
#   Objective 352.2 expects you to manage LXC networking (bridged and NAT) and
#   to read the container config file (lxc.net.*, lxc.net.0.link, lxc.net.0.type).
#   The single most common real-world LXC start failure is exactly this: a veth
#   pointed at a bridge that is down, renamed, or never created — most often
#   because the lxc-net service (which owns lxcbr0) is not running. Diagnose it
#   with `lxc-start -F -l DEBUG -o`, not by guessing.
#
# Reference: man 5 lxc.container.conf
#   https://linuxcontainers.org/lxc/manpages/man5/lxc.container.conf.5.html
# Reference: LPI Exam 305 Objectives
#   https://www.lpi.org/our-certifications/exam-305-objectives/
# =====================================================================
# <<< SOLUTION END