#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-3 305 (Exam 305-300, v3.0) -- Objective 351.2: Xen
#  Break & Fix lab: DomU virtual network interface bound to a missing bridge
# ============================================================================
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It takes ONE existing paravirtualized/HVM guest config from /etc/xen, makes
#  a timestamped backup, and rewrites the guest's `vif = [ ... ]` line so the
#  virtual interface tries to plug into a bridge that does not exist. The Xen
#  vif-bridge hotplug script then fails when the domain is created, which is a
#  very common real-world DomU networking fault.
#
#  Everything happens on a DISPOSABLE Dom0 lab host. Nothing is scraped, nothing
#  leaves the machine, and every change is fully reversible with `restore`.
#
#  USAGE
#  -----
#     sudo ./351.2-xen-breakfix.sh break     # introduce the fault
#     sudo ./351.2-xen-breakfix.sh verify     # grade your fix
#     sudo ./351.2-xen-breakfix.sh restore    # undo everything (last resort)
#
#  Reference: https://www.lpi.org/our-certifications/exam-305-objectives/
#  Reference: https://xenproject.org/  (xl toolstack, xl.cfg(5), vif-bridge)
# ============================================================================

set -euo pipefail

STATE_DIR="/var/tmp/xen-breakfix-351.2"
STATE_FILE="${STATE_DIR}/state.env"
BROKEN_BRIDGE="xenbr-lab-broken"   # a bridge that deliberately does not exist

# --- colours (fall back to nothing if not a tty) ----------------------------
if [[ -t 1 ]]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
    RED=""; GRN=""; YEL=""; BLD=""; RST=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$BLD" "$RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
#  Safety gates -- this must only ever run on a throwaway Xen Dom0.
# ----------------------------------------------------------------------------
preflight() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root (Dom0 management needs it)."

    command -v xl >/dev/null 2>&1 || die "'xl' not found. This is not a Xen Dom0."

    # /proc/xen and the 'Domain-0' entry together prove we are inside Dom0,
    # not on a random Linux box where we would be editing nothing useful.
    [[ -d /proc/xen ]] || die "/proc/xen missing. Not running under the Xen hypervisor."
    if ! xl list 2>/dev/null | awk '{print $1}' | grep -qx "Domain-0"; then
        die "'xl list' does not show Domain-0. Aborting to avoid touching a non-lab host."
    fi

    mkdir -p "$STATE_DIR"
}

# Pick a guest config to sabotage: first arg, $CFG env, or first *.cfg in /etc/xen.
pick_config() {
    local candidate="${1:-${CFG:-}}"
    if [[ -n "$candidate" ]]; then
        [[ -f "$candidate" ]] || die "Config '$candidate' does not exist."
        printf '%s\n' "$candidate"; return
    fi
    candidate="$(find /etc/xen -maxdepth 1 -type f -name '*.cfg' 2>/dev/null | sort | head -n1 || true)"
    [[ -n "$candidate" ]] || die "No *.cfg found in /etc/xen. Create a lab DomU first, or pass CFG=/path."
    printf '%s\n' "$candidate"
}

# Detect a real bridge on the host so the briefing can name a valid target.
detect_real_bridge() {
    ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | head -n1
}

# ----------------------------------------------------------------------------
#  BREAK
# ----------------------------------------------------------------------------
do_break() {
    preflight
    [[ -f "$STATE_FILE" ]] && die "A break is already active. Run 'verify' or 'restore' first."

    local cfg dom real_bridge backup
    cfg="$(pick_config "${1:-}")"
    dom="$(awk -F'=' '/^[[:space:]]*name[[:space:]]*=/{gsub(/[ "'\''\t]/,"",$2); print $2; exit}' "$cfg")"
    dom="${dom:-$(basename "$cfg" .cfg)}"
    real_bridge="$(detect_real_bridge)"
    backup="${STATE_DIR}/$(basename "$cfg").orig"

    grep -Eq '^[[:space:]]*vif[[:space:]]*=' "$cfg" \
        || die "No 'vif =' line in $cfg. Pick a networked guest (pass CFG=/etc/xen/<guest>.cfg)."

    cp -a "$cfg" "$backup"

    # If the guest happens to be running, stop it cleanly so the student's
    # re-create is what exercises the fault.
    if xl list 2>/dev/null | awk '{print $1}' | grep -qx "$dom"; then
        info "Guest '$dom' is running; shutting it down for a clean lab."
        xl shutdown -w "$dom" >/dev/null 2>&1 || xl destroy "$dom" >/dev/null 2>&1 || true
    fi

    # THE FAULT: rewrite every bridge=... token in the vif line to a bridge
    # that does not exist. Any explicitly-named bridge becomes the bad one;
    # a bare vif (no bridge= key) gets one appended so the failure is explicit.
    if grep -Eq '^[[:space:]]*vif[[:space:]]*=.*bridge[[:space:]]*=' "$cfg"; then
        sed -i -E "/^[[:space:]]*vif[[:space:]]*=/ s/bridge[[:space:]]*=[[:space:]]*[A-Za-z0-9_.-]+/bridge=${BROKEN_BRIDGE}/g" "$cfg"
    else
        sed -i -E "/^[[:space:]]*vif[[:space:]]*=/ s/'([^']*)'/'\\1,bridge=${BROKEN_BRIDGE}'/" "$cfg"
    fi

    {
        echo "CFG=$cfg"
        echo "DOM=$dom"
        echo "BACKUP=$backup"
        echo "REAL_BRIDGE=${real_bridge:-<none-detected>}"
        echo "BROKEN_BRIDGE=$BROKEN_BRIDGE"
    } > "$STATE_FILE"

    cat <<EOF

${BLD}================= BREAK APPLIED — Objective 351.2 (Xen) =================${RST}

  Target guest config : ${cfg}
  Guest (domain) name : ${dom}
  Sabotaged element   : the 'vif' line now points at bridge '${BROKEN_BRIDGE}'

${BLD}SYMPTOM YOU WILL SEE${RST}
  Boot the guest:

      # xl create -c ${cfg}

  The domain object is created, but the virtual NIC never attaches. You will
  see the vif hotplug script fail, e.g.:

      libxl: error: libxl_device.c: ... Domain ${dom}:hotplug script vif failed
      /etc/xen/scripts/vif-bridge: could not find bridge device ${BROKEN_BRIDGE}
      libxl: error: libxl_exec.c: ... vif-bridge  add [<pid>] exited with error status 1

  Inside the guest, eth0 stays link-down / has no address. From Dom0:

      # xl network-list ${dom}          -> shows the vif in an error/absent state
      # xl list                          -> ${dom} may be present but unusable

${BLD}YOUR GOAL${RST}
  Restore network connectivity to guest '${dom}' by hand:
    1. Find WHERE the guest is told which bridge to use.
    2. Discover WHICH bridges actually exist on this Dom0.
    3. Correct the guest so its vif attaches to a real bridge.
    4. Re-create the guest and PROVE the interface is up.

  When you think it works:  sudo $0 verify

${BLD}HINTS (tools 351.2 expects you to know)${RST}
  xl create / xl destroy / xl network-list / xl console
  ip link show type bridge     brctl show     bridge link
  /etc/xen/*.cfg   /etc/xen/scripts/vif-bridge   /var/log/xen/
  xl dmesg     xenstore-ls -f

========================================================================

EOF
    ok "Fault injected. Do NOT read the solution at the bottom of this file yet."
}

# ----------------------------------------------------------------------------
#  VERIFY -- grade the student's fix
# ----------------------------------------------------------------------------
do_verify() {
    preflight
    [[ -f "$STATE_FILE" ]] || die "No active break. Nothing to verify."
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    local fail=0

    info "Checking that no vif still references '${BROKEN_BRIDGE}' ..."
    if grep -Eq "bridge[[:space:]]*=[[:space:]]*${BROKEN_BRIDGE}" "$CFG"; then
        warn "The config still points at the missing bridge '${BROKEN_BRIDGE}'."; fail=1
    else
        ok "Config no longer references the broken bridge."
    fi

    info "Checking that the vif now names a bridge that really exists ..."
    local cfg_bridge exists=0 b
    cfg_bridge="$(grep -Eo "bridge[[:space:]]*=[[:space:]]*[A-Za-z0-9_.-]+" "$CFG" | head -n1 | sed -E 's/.*=[[:space:]]*//' || true)"
    if [[ -n "$cfg_bridge" ]]; then
        while read -r b; do [[ "$b" == "$cfg_bridge" ]] && exists=1; done \
            < <(ip -o link show type bridge | awk -F': ' '{print $2}')
        if [[ "$exists" -eq 1 ]]; then ok "vif bridge '$cfg_bridge' exists on this host."
        else warn "vif bridge '$cfg_bridge' is not a real bridge here."; fail=1; fi
    else
        warn "Could not read a bridge= value from the vif line."; fail=1
    fi

    info "Checking that guest '${DOM}' is running with an attached vif ..."
    if xl list 2>/dev/null | awk '{print $1}' | grep -qx "$DOM"; then
        if xl network-list "$DOM" 2>/dev/null | grep -Eq '^[[:space:]]*[0-9]'; then
            ok "Guest '${DOM}' is running and has a listed vif."
        else
            warn "Guest '${DOM}' is running but 'xl network-list' shows no vif."; fail=1
        fi
    else
        warn "Guest '${DOM}' is not running. Re-create it: xl create ${CFG}"; fail=1
    fi

    if [[ "$fail" -eq 0 ]]; then
        echo
        ok "${BLD}LAB PASSED.${RST} The DomU vif is bound to a real bridge and the guest is up."
        rm -f "$STATE_FILE"
        say "Backup left at: ${BACKUP} (safe to delete once you are happy)."
    else
        echo
        die "Not fixed yet. Review the symptoms above and try again."
    fi
}

# ----------------------------------------------------------------------------
#  RESTORE -- give up and revert to the pristine config
# ----------------------------------------------------------------------------
do_restore() {
    preflight
    [[ -f "$STATE_FILE" ]] || die "No active break recorded. Nothing to restore."
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    xl list 2>/dev/null | awk '{print $1}' | grep -qx "$DOM" && { xl destroy "$DOM" >/dev/null 2>&1 || true; }
    if [[ -f "$BACKUP" ]]; then
        cp -a "$BACKUP" "$CFG"
        ok "Original config restored from ${BACKUP}."
    else
        warn "Backup ${BACKUP} missing; restore the vif line by hand."
    fi
    rm -f "$STATE_FILE"
    say "Re-create when ready:  xl create -c ${CFG}"
}

# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
LPIC-3 305 / 351.2 Xen -- Break & Fix

  sudo $0 break [CFG]   Inject the fault (optionally target a specific *.cfg)
  sudo $0 verify        Grade your fix
  sudo $0 restore       Revert to the original config

Env: CFG=/etc/xen/<guest>.cfg to choose the guest explicitly.
EOF
}

case "${1:-}" in
    break)   shift; do_break "${1:-}";;
    verify)  do_verify;;
    restore) do_restore;;
    *)       usage; exit 1;;
esac

# ############################################################################
# #                                                                          #
# #   SOLUTION — read only after you have genuinely tried to fix it          #
# #   =====================================================================  #
# #                                                                          #
# #   Root cause: the guest's `vif` line in its /etc/xen/<guest>.cfg names   #
# #   a Linux bridge (`bridge=xenbr-lab-broken`) that does not exist. When   #
# #   `xl create` runs, libxl calls the hotplug script                      #
# #   /etc/xen/scripts/vif-bridge, which tries to add the guest's vifX.Y     #
# #   device to that bridge, fails, and tears the interface down. The domain #
# #   object may exist but has no working network.                          #
# #                                                                          #
# #   STEP 1 — Observe the failure and read the logs                        #
# #   ---------------------------------------------------------------------  #
# #     # xl create -c /etc/xen/<guest>.cfg                                  #
# #     # xl dmesg | tail                                                    #
# #     # ls -t /var/log/xen/ | head                                        #
# #     # less /var/log/xen/xl-<guest>.log                                  #
# #   Expected line:                                                         #
# #     /etc/xen/scripts/vif-bridge: could not find bridge device           #
# #     xenbr-lab-broken                                                     #
# #                                                                          #
# #   STEP 2 — List the bridges that ACTUALLY exist on Dom0                 #
# #   ---------------------------------------------------------------------  #
# #     # ip -o link show type bridge                                        #
# #     # brctl show            # (bridge-utils, if installed)               #
# #     # bridge link                                                        #
# #   Expected: a real bridge such as `xenbr0` (or `br0`) is listed. That    #
# #   is the name the guest must reference. If NO bridge exists, the host    #
# #   networking itself is unconfigured — create one, e.g.:                  #
# #     # ip link add name xenbr0 type bridge                                #
# #     # ip link set xenbr0 up                                              #
# #     # ip link set eth0 master xenbr0            # enslave the uplink     #
# #   (or configure it persistently via the distro network stack).          #
# #                                                                          #
# #   STEP 3 — Correlate: where is the wrong name written?                  #
# #   ---------------------------------------------------------------------  #
# #     # grep -n vif /etc/xen/<guest>.cfg                                   #
# #   You will see, for example:                                            #
# #     vif = [ 'mac=00:16:3e:aa:bb:cc,bridge=xenbr-lab-broken' ]           #
# #                                                                          #
# #   STEP 4 — Fix the config: point the vif at the real bridge            #
# #   ---------------------------------------------------------------------  #
# #     # vi /etc/xen/<guest>.cfg                                            #
# #   Change bridge=xenbr-lab-broken  ->  bridge=xenbr0   (your real one)   #
# #     vif = [ 'mac=00:16:3e:aa:bb:cc,bridge=xenbr0' ]                     #
# #                                                                          #
# #   STEP 5 — Recreate the guest and prove the interface is attached      #
# #   ---------------------------------------------------------------------  #
# #     # xl destroy <guest>              # clear the broken instance        #
# #     # xl create /etc/xen/<guest>.cfg                                     #
# #     # xl list                          # <guest> should be running       #
# #     # xl network-list <guest>                                            #
# #   Expected xl network-list output:                                       #
# #     Idx BE Mac Addr.          handle state evt-ch tx-/rx-ring-ref BE-path#
# #     0   0  00:16:3e:aa:bb:cc  0      4     <n>    <..>/<..>       /local..#
# #   state 4 == 'connected'. From Dom0 you should also see the backend vif: #
# #     # ip link show | grep vif                                           #
# #     # brctl show xenbr0            # the guest's vifX.Y is now enslaved   #
# #                                                                          #
# #   STEP 6 — Confirm connectivity from inside the guest                  #
# #   ---------------------------------------------------------------------  #
# #     # xl console <guest>                                                 #
# #     (guest)# ip addr show eth0     # link UP, address present            #
# #     (guest)# ping -c1 <gateway>                                          #
# #     Detach console with:  Ctrl-]                                         #
# #                                                                          #
# #   Grade it:   sudo ./351.2-xen-breakfix.sh verify                        #
# #                                                                          #
# #   Why this matters (exam 351.2): the xl toolstack does not validate      #
# #   that the bridge in a vif exists — it delegates attachment to the       #
# #   vif-bridge hotplug script at create time. Diagnosing DomU networking   #
# #   therefore means reading /var/log/xen/, knowing `xl network-list`       #
# #   state codes, and reconciling the guest config against the real Dom0    #
# #   bridge topology (ip link / brctl).                                     #
# #                                                                          #
# ############################################################################