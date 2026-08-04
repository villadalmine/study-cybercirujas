#!/usr/bin/env bash
#
# ==============================================================================
#  CKS (exam version 1.34) — Domain 5: Microservice Vulnerability Minimization
#  Topic 5.1 — Minimize host OS footprint (reduce attack surface)
#  Exam weight: 2.5
# ==============================================================================
#
#  BREAK & FIX LAB — "the hardening that went sideways"
#
#  A junior SRE was told to "minimize the host OS footprint" of this node.
#  They did two things wrong at the same time:
#
#    BLOCK A — they removed surface that the node actually NEEDS,
#              so the Kubernetes data plane is now broken.
#    BLOCK B — they left behind (and even added) surface that the node
#              does NOT need, so the attack surface actually grew.
#
#  Minimizing a host OS footprint is not "delete everything". It is
#  "keep exactly the kernel modules, sysctls, services, ports, SUID binaries
#  and privileged principals that the workload requires, and nothing else".
#  This lab makes you prove you can tell the two apart.
#
#  REQUIREMENTS
#    * A DISPOSABLE lab VM. Preferably a single-node kubeadm cluster
#      (control-plane node) with containerd + kubelet. The lab also runs on a
#      plain Linux VM; the Kubernetes-specific symptoms are then skipped.
#    * systemd, root privileges, and one of: python3 or socat (for the rogue
#      service). Debian/Ubuntu and RHEL-family both work.
#
#  SAFETY
#    * Every file this script modifies is backed up under
#      /var/lib/cks-lab/cks-5.1/backup before the first edit.
#    * It never touches sshd_config, never changes passwords, never opens a
#      remote shell, never removes distribution packages, and never reboots.
#    * `cleanup --give-up` restores everything (use only if you are stuck).
#    * DO NOT REBOOT while the lab is broken: systemd-modules-load.service is
#      masked on purpose, so required modules would not come back at boot.
#      Fix the lab (or run cleanup) first, then reboot if you want.
#
#  USAGE
#    sudo CKS_LAB_DISPOSABLE=yes ./cks-5.1-break-fix.sh break
#    sudo ./cks-5.1-break-fix.sh status      # read-only recon helper
#    sudo ./cks-5.1-break-fix.sh verify      # grades your fix
#    sudo ./cks-5.1-break-fix.sh cleanup --give-up
#
#  REFERENCES (official)
#    * CKS curriculum v1.34
#      https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#    * Container runtimes / required kernel modules and sysctls
#      https://kubernetes.io/docs/setup/production-environment/container-runtimes/
#    * Network plugin requirements (bridge-nf-call-iptables)
#      https://kubernetes.io/docs/concepts/cluster-administration/addons/
#    * modprobe.d(5), sysctl.d(5), systemd.unit(5), systemd-modules-load.service(8)
#    * CIS Benchmarks — "Ensure unused filesystems/protocols are disabled"
#      https://www.cisecurity.org/cis-benchmarks
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Lab constants
# ------------------------------------------------------------------------------
LAB_ID="cks-5.1"
STATE_DIR="/var/lib/cks-lab/${LAB_ID}"
BACKUP_DIR="${STATE_DIR}/backup"
WWW_DIR="${STATE_DIR}/www"
TOUCHED_LIST="${STATE_DIR}/touched-files.list"

ROGUE_UNIT="cks-lab-legacy-metrics.service"
ROGUE_UNIT_PATH="/etc/systemd/system/${ROGUE_UNIT}"
ROGUE_PORT="${LAB_PORT:-8080}"

SUID_BIN="/usr/local/bin/lab-find"
SUDOERS_DROPIN="/etc/sudoers.d/99-cks-lab-ops"
LAB_USER="cks-lab-ops"

SYSCTL_BREAK="/etc/sysctl.d/99-cks-lab-break.conf"
MODPROBE_BREAK="/etc/modprobe.d/99-cks-lab-break.conf"
MODULES_LOAD_DIR="/etc/modules-load.d"

NOISY_MODULES=(dccp sctp)

PASS=0
FAIL=0

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

log()  { printf '%s[lab]%s %s\n' "${C_BLU}" "${C_RST}" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "${C_GRN}" "${C_RST}" "$*"; }
warn() { printf '%s[warn]%s %s\n' "${C_YEL}" "${C_RST}" "$*"; }
err()  { printf '%s[fail]%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }
title(){ hr; printf '%s%s%s\n' "${C_BLD}" "$*" "${C_RST}"; hr; }

die() { err "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Guards
# ------------------------------------------------------------------------------
need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "run as root (sudo $0 $*)"
}

require_lab_ack() {
    if [[ "${CKS_LAB_DISPOSABLE:-}" != "yes" && "${LAB_ACK:-0}" != "1" ]]; then
        cat <<'ACK'
REFUSING TO RUN.

This script deliberately degrades the host: it disables IP forwarding, unloads
and blacklists br_netfilter, masks systemd-modules-load.service, installs a
root-owned network listener, a SUID binary, a passwordless sudo rule and a
local account.

Run it ONLY on a throwaway lab VM you can rebuild, and confirm with either:

    sudo CKS_LAB_DISPOSABLE=yes  ./cks-5.1-break-fix.sh break
    sudo ./cks-5.1-break-fix.sh break --i-know-this-is-a-lab-vm
ACK
        exit 2
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------
# Backup / restore primitives
# ------------------------------------------------------------------------------
backup_file() {
    local f="$1" dest
    [[ -e "$f" ]] || return 0
    dest="${BACKUP_DIR}${f}"
    mkdir -p "$(dirname "$dest")"
    [[ -e "$dest" ]] || cp -a "$f" "$dest"
    grep -qxF "$f" "$TOUCHED_LIST" 2>/dev/null || echo "$f" >>"$TOUCHED_LIST"
}

restore_backups() {
    [[ -f "$TOUCHED_LIST" ]] || return 0
    local f src
    while IFS= read -r f; do
        src="${BACKUP_DIR}${f}"
        if [[ -e "$src" ]]; then
            cp -a "$src" "$f"
            log "restored ${f}"
        fi
    done <"$TOUCHED_LIST"
}

# ------------------------------------------------------------------------------
# Fact collectors (used by break, status and verify)
# ------------------------------------------------------------------------------
sysctl_value() { sysctl -n "$1" 2>/dev/null || echo "<absent>"; }

module_loaded() { [[ -d "/sys/module/${1//-/_}" ]]; }

port_listening() {
    local p="$1"
    if have ss; then
        [[ -n "$(ss -H -lnt "sport = :${p}" 2>/dev/null)" ]]
    elif have netstat; then
        netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    else
        return 1
    fi
}

unit_exists() { systemctl list-unit-files "$1" >/dev/null 2>&1 && [[ -e "$ROGUE_UNIT_PATH" ]]; }

kubelet_present() { systemctl list-unit-files kubelet.service >/dev/null 2>&1 && [[ -n "$(systemctl list-unit-files kubelet.service --no-legend 2>/dev/null)" ]]; }

modprobe_config_has() {
    # $1 = regex, matched against the effective modprobe configuration
    modprobe --showconfig 2>/dev/null | grep -qE "$1"
}

# ==============================================================================
# BREAK
# ==============================================================================
do_break() {
    require_lab_ack
    mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$WWW_DIR"
    touch "$TOUCHED_LIST"

    title "CKS 5.1 — breaking the host on purpose"

    # --- BLOCK A.1: kill IP forwarding, at runtime and persistently ------------
    backup_file "$SYSCTL_BREAK"
    cat >"$SYSCTL_BREAK" <<EOF
# Installed by the CKS 5.1 break & fix lab.
# "Hardening" applied without checking what the node actually needs.
net.ipv4.ip_forward = 0
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
EOF
    grep -qxF "$SYSCTL_BREAK" "$TOUCHED_LIST" 2>/dev/null || echo "$SYSCTL_BREAK" >>"$TOUCHED_LIST"
    sysctl -w net.ipv4.ip_forward=0 >/dev/null
    sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 || true
    log "A.1 net.ipv4.ip_forward -> 0 (runtime + ${SYSCTL_BREAK})"

    # --- BLOCK A.2: comment out br_netfilter autoload -------------------------
    if [[ -d "$MODULES_LOAD_DIR" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            backup_file "$f"
            sed -i -E 's|^[[:space:]]*br_netfilter[[:space:]]*$|# br_netfilter   # "unused module", removed during host hardening (CKS lab 5.1)|' "$f"
            log "A.2 disabled br_netfilter autoload in ${f}"
        done < <(grep -rlE '^[[:space:]]*br_netfilter[[:space:]]*$' "$MODULES_LOAD_DIR" 2>/dev/null || true)
    fi

    # --- BLOCK A.3: blacklist + unload br_netfilter ---------------------------
    backup_file "$MODPROBE_BREAK"
    cat >"$MODPROBE_BREAK" <<'EOF'
# Installed by the CKS 5.1 break & fix lab.
# br_netfilter is REQUIRED by kube-proxy/CNI on a bridged pod network.
blacklist br_netfilter
install br_netfilter /bin/false
EOF
    grep -qxF "$MODPROBE_BREAK" "$TOUCHED_LIST" 2>/dev/null || echo "$MODPROBE_BREAK" >>"$TOUCHED_LIST"
    if module_loaded br_netfilter; then
        modprobe -r br_netfilter 2>/dev/null || rmmod br_netfilter 2>/dev/null || \
            warn "A.3 br_netfilter is busy and stayed loaded; the blacklist still bites after reboot"
    fi
    log "A.3 br_netfilter blacklisted (${MODPROBE_BREAK})"

    # --- BLOCK A.4: mask systemd-modules-load.service -------------------------
    systemctl mask systemd-modules-load.service >/dev/null 2>&1 || true
    log "A.4 masked systemd-modules-load.service (module autoload is dead at boot)"

    # --- BLOCK B.1: rogue always-restarting root listener ---------------------
    echo "legacy node metrics — replaced by kube-state-metrics in 2023" >"${WWW_DIR}/index.html"
    local exec_line=""
    if have python3; then
        exec_line="$(command -v python3) -m http.server ${ROGUE_PORT} --bind 0.0.0.0 --directory ${WWW_DIR}"
    elif have socat; then
        exec_line="$(command -v socat) -T5 TCP-LISTEN:${ROGUE_PORT},fork,reuseaddr SYSTEM:'echo legacy-metrics'"
    fi
    if [[ -n "$exec_line" ]]; then
        backup_file "$ROGUE_UNIT_PATH"
        cat >"$ROGUE_UNIT_PATH" <<EOF
[Unit]
Description=Legacy node metrics exporter (CKS lab 5.1 — unnecessary on purpose)
Documentation=https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=${exec_line}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        grep -qxF "$ROGUE_UNIT_PATH" "$TOUCHED_LIST" 2>/dev/null || echo "$ROGUE_UNIT_PATH" >>"$TOUCHED_LIST"
        systemctl daemon-reload
        systemctl enable --now "$ROGUE_UNIT" >/dev/null 2>&1 || warn "could not start ${ROGUE_UNIT}"
        echo "rogue_unit=1" >"${STATE_DIR}/features"
        log "B.1 ${ROGUE_UNIT} listening as root on 0.0.0.0:${ROGUE_PORT} (Restart=always)"
    else
        echo "rogue_unit=0" >"${STATE_DIR}/features"
        warn "B.1 skipped: neither python3 nor socat is installed"
    fi

    # --- BLOCK B.2: SUID root binary ------------------------------------------
    if [[ -x /usr/bin/find ]]; then
        install -m 0755 /usr/bin/find "$SUID_BIN"
        chown root:root "$SUID_BIN"
        chmod 4755 "$SUID_BIN"
        grep -qxF "$SUID_BIN" "$TOUCHED_LIST" 2>/dev/null || echo "$SUID_BIN" >>"$TOUCHED_LIST"
        log "B.2 ${SUID_BIN} installed with mode 4755 (SUID root)"
    fi

    # --- BLOCK B.3: unnecessary kernel modules loaded --------------------------
    local m
    for m in "${NOISY_MODULES[@]}"; do
        modprobe "$m" 2>/dev/null && log "B.3 loaded unnecessary module: ${m}" || \
            warn "B.3 module ${m} not available on this kernel (that check will auto-pass)"
    done

    # --- BLOCK B.4: passwordless sudo principal --------------------------------
    if ! id "$LAB_USER" >/dev/null 2>&1; then
        useradd --system --create-home --shell /bin/bash "$LAB_USER" 2>/dev/null || \
            useradd -r -m -s /bin/bash "$LAB_USER" 2>/dev/null || true
    fi
    if id "$LAB_USER" >/dev/null 2>&1; then
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$LAB_USER" >"$SUDOERS_DROPIN"
        chmod 0440 "$SUDOERS_DROPIN"
        if have visudo && ! visudo -cf "$SUDOERS_DROPIN" >/dev/null 2>&1; then
            rm -f "$SUDOERS_DROPIN"
            warn "B.4 sudoers drop-in rejected by visudo, skipped"
        else
            grep -qxF "$SUDOERS_DROPIN" "$TOUCHED_LIST" 2>/dev/null || echo "$SUDOERS_DROPIN" >>"$TOUCHED_LIST"
            log "B.4 ${LAB_USER} has NOPASSWD:ALL via ${SUDOERS_DROPIN}"
        fi
    fi

    date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/broken-at"
    print_briefing
}

# ------------------------------------------------------------------------------
# Student briefing
# ------------------------------------------------------------------------------
print_briefing() {
    cat <<EOF

$(title "SYMPTOMS YOU ARE ABOUT TO SEE")

1) Pod networking is dead for anything that crosses the bridge or a Service IP.
   On a kubeadm node, a test pod cannot resolve DNS or reach a ClusterIP:

     \$ kubectl run probe --image=busybox:1.36 --restart=Never -it --rm -- \\
         nslookup kubernetes.default.svc.cluster.local
     ;; connection timed out; no servers could be reached
     pod "probe" deleted
     pod default/probe terminated (Error)

   Existing pods may keep working; new cross-pod / Service traffic does not.

2) kubeadm preflight refuses to run anything on this node:

     \$ sudo kubeadm upgrade plan
     [ERROR FileContent--proc-sys-net-ipv4-ip_forward]: /proc/sys/net/ipv4/ip_forward contents are not set to 1
     [preflight] If you know what you are doing, you can make a check non-fatal with --ignore-preflight-errors=...

3) The bridge sysctls are gone entirely, not just set to 0:

     \$ sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
     net.ipv4.ip_forward = 0
     sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory

     \$ lsmod | grep br_netfilter
     (no output)

4) An unknown root process is listening on every interface, and it comes back
   two seconds after you kill it:

     \$ sudo ss -lntp | grep :${ROGUE_PORT}
     LISTEN 0 5 0.0.0.0:${ROGUE_PORT} 0.0.0.0:* users:(("python3",pid=1421,fd=3))
     \$ sudo pkill -f 'http.server'   # ... and it is listening again

5) Recon on the host finds surface that has no business being there:
   a SUID-root binary under /usr/local/bin, exotic network protocol modules
   loaded in the kernel, and a local account with NOPASSWD sudo.

$(title "YOUR MISSION")

Restore the MINIMUM surface the node needs, and delete the surface it does not.
Do NOT "fix" block A by reverting the whole hardening effort: kubelet and the
container runtime must still be active when you are done.

  BLOCK A — put back only what Kubernetes requires
    A1. net.ipv4.ip_forward = 1, at runtime AND persisted across reboots.
    A2. br_netfilter loaded now AND autoloaded at boot.
    A3. net.bridge.bridge-nf-call-iptables = 1, at runtime AND persisted.
    A4. systemd-modules-load.service must not be masked.
    A5. kubelet.service and the container runtime still active (if installed).

  BLOCK B — remove what it does not require
    B1. Nothing listening on 0.0.0.0:${ROGUE_PORT}; the unit must be gone for good,
        not merely stopped (Restart=always will beat you otherwise).
    B2. No SUID-root binary under /usr/local.
    B3. dccp and sctp unloaded AND permanently prevented from loading —
        blacklist alone is not enough, an explicit modprobe still wins.
    B4. No passwordless-sudo principal left behind.

Grade yourself at any time:

    sudo $0 verify

Recon helper (read-only, changes nothing):

    sudo $0 status

Stuck and out of time:

    sudo $0 cleanup --give-up

EOF
}

# ==============================================================================
# STATUS — read-only recon
# ==============================================================================
do_status() {
    title "CKS 5.1 — host footprint snapshot"

    printf '%s\n' "sysctl:"
    printf '  net.ipv4.ip_forward                  = %s\n' "$(sysctl_value net.ipv4.ip_forward)"
    printf '  net.bridge.bridge-nf-call-iptables   = %s\n' "$(sysctl_value net.bridge.bridge-nf-call-iptables)"

    printf '\n%s\n' "kernel modules of interest:"
    local m
    for m in br_netfilter overlay "${NOISY_MODULES[@]}"; do
        if module_loaded "$m"; then printf '  %-14s loaded\n' "$m"; else printf '  %-14s not loaded\n' "$m"; fi
    done

    printf '\n%s\n' "effective modprobe policy (blacklist/install lines):"
    modprobe --showconfig 2>/dev/null | grep -E '^(blacklist|install) ' | sed 's/^/  /' | head -n 25 || true

    printf '\n%s\n' "listening TCP sockets:"
    if have ss; then ss -lntp 2>/dev/null | sed 's/^/  /'; else netstat -lntp 2>/dev/null | sed 's/^/  /'; fi

    printf '\n%s\n' "SUID/SGID files under /usr/local and /opt:"
    find /usr/local /opt -xdev -type f \( -perm -4000 -o -perm -2000 \) -printf '  %M %u %g %p\n' 2>/dev/null || true

    printf '\n%s\n' "enabled systemd services (count and non-distro units):"
    printf '  total enabled: %s\n' "$(systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | wc -l)"
    ls -1 /etc/systemd/system/*.service 2>/dev/null | sed 's/^/  /' || true

    printf '\n%s\n' "sudoers drop-ins:"
    ls -l /etc/sudoers.d/ 2>/dev/null | sed 's/^/  /' || true

    printf '\n%s\n' "advisory (not graded, but exam-relevant):"
    if [[ -r /etc/ssh/sshd_config ]]; then
        printf '  sshd PermitRootLogin: %s\n' "$(grep -Ei '^[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config | tail -n1 || echo '<default: prohibit-password>')"
    fi
    printf '  masked units: %s\n' "$(systemctl list-unit-files --state=masked --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    hr
}

# ==============================================================================
# VERIFY
# ==============================================================================
check() {
    # $1 = human description, $2 = 0/1 result, $3 = hint on failure
    if [[ "$2" -eq 0 ]]; then
        ok "$1"; PASS=$((PASS + 1))
    else
        err "$1"; [[ -n "${3:-}" ]] && printf '        hint: %s\n' "$3"
        FAIL=$((FAIL + 1))
    fi
}

do_verify() {
    title "CKS 5.1 — grading"

    printf '%sBLOCK A — required surface restored%s\n' "${C_BLD}" "${C_RST}"

    # A1 runtime + persistent ip_forward
    [[ "$(sysctl_value net.ipv4.ip_forward)" == "1" ]] && r=0 || r=1
    check "A1a net.ipv4.ip_forward is 1 at runtime" "$r" \
          "sysctl -w net.ipv4.ip_forward=1"

    if grep -rhE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' \
            /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ 2>/dev/null \
            | grep -qE '=[[:space:]]*0'; then r=1; else r=0; fi
    check "A1b no persisted sysctl sets ip_forward to 0" "$r" \
          "grep -R ip_forward /etc/sysctl.conf /etc/sysctl.d/ and remove the 0"

    if grep -rhE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' \
            /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null | grep -q .; then r=0; else r=1; fi
    check "A1c ip_forward = 1 is persisted in /etc/sysctl.d" "$r" \
          "echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-kubernetes.conf && sysctl --system"

    # A2 br_netfilter loaded, not blacklisted, autoloaded
    module_loaded br_netfilter && r=0 || r=1
    check "A2a br_netfilter is loaded" "$r" "modprobe br_netfilter"

    if modprobe_config_has '^(blacklist|install)[[:space:]]+br_netfilter'; then r=1; else r=0; fi
    check "A2b br_netfilter is not blacklisted / install-nulled" "$r" \
          "modprobe --showconfig | grep br_netfilter, then clean /etc/modprobe.d"

    if grep -rhE '^[[:space:]]*br_netfilter[[:space:]]*$' "$MODULES_LOAD_DIR" 2>/dev/null | grep -q .; then r=0; else r=1; fi
    check "A2c br_netfilter is autoloaded at boot (/etc/modules-load.d)" "$r" \
          "printf 'overlay\\nbr_netfilter\\n' > /etc/modules-load.d/k8s.conf"

    # A3 bridge sysctl
    [[ "$(sysctl_value net.bridge.bridge-nf-call-iptables)" == "1" ]] && r=0 || r=1
    check "A3a net.bridge.bridge-nf-call-iptables is 1 at runtime" "$r" \
          "the key only exists once br_netfilter is loaded"

    if grep -rhE '^[[:space:]]*net\.bridge\.bridge-nf-call-iptables[[:space:]]*=' \
            /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null | grep -qE '=[[:space:]]*0'; then r=1; else r=0; fi
    check "A3b no persisted sysctl sets bridge-nf-call-iptables to 0" "$r" \
          "remove ${SYSCTL_BREAK} or fix its values"

    # A4 systemd-modules-load
    if [[ "$(systemctl is-enabled systemd-modules-load.service 2>/dev/null || true)" == "masked" ]]; then r=1; else r=0; fi
    check "A4  systemd-modules-load.service is not masked" "$r" \
          "systemctl unmask --now systemd-modules-load.service"

    # A5 the node is still a node
    if kubelet_present; then
        systemctl is-active --quiet kubelet.service && r=0 || r=1
        check "A5a kubelet.service is still active" "$r" "systemctl status kubelet -l"
        local rt found=1
        for rt in containerd.service crio.service docker.service; do
            if systemctl is-active --quiet "$rt" 2>/dev/null; then found=0; break; fi
        done
        check "A5b a container runtime is still active" "$found" "systemctl status containerd -l"
    else
        warn "A5  no kubelet on this host — Kubernetes-specific checks skipped"
    fi

    printf '\n%sBLOCK B — unnecessary surface removed%s\n' "${C_BLD}" "${C_RST}"

    # B1 rogue listener
    if [[ "$(grep -c 'rogue_unit=1' "${STATE_DIR}/features" 2>/dev/null || echo 0)" -eq 0 ]]; then
        warn "B1  rogue service was never installed on this host — skipped"
    else
        port_listening "$ROGUE_PORT" && r=1 || r=0
        check "B1a nothing is listening on TCP/${ROGUE_PORT}" "$r" \
              "ss -lntp 'sport = :${ROGUE_PORT}' then trace the PID back to its unit"

        [[ -e "$ROGUE_UNIT_PATH" ]] && r=1 || r=0
        check "B1b ${ROGUE_UNIT} unit file is gone" "$r" \
              "systemctl disable --now ${ROGUE_UNIT}; rm ${ROGUE_UNIT_PATH}; systemctl daemon-reload"

        if systemctl is-enabled "$ROGUE_UNIT" >/dev/null 2>&1; then r=1; else r=0; fi
        check "B1c ${ROGUE_UNIT} is not enabled" "$r" "systemctl disable ${ROGUE_UNIT}"
    fi

    # B2 SUID
    if [[ -n "$(find /usr/local -xdev -type f -perm -4000 2>/dev/null)" ]]; then r=1; else r=0; fi
    check "B2  no SUID-root binary under /usr/local" "$r" \
          "find / -xdev -perm -4000 -type f 2>/dev/null; then chmod u-s or rm the offender"

    # B3 noisy modules
    local m
    for m in "${NOISY_MODULES[@]}"; do
        module_loaded "$m" && r=1 || r=0
        check "B3a ${m} is not loaded" "$r" "modprobe -r ${m}"

        if modprobe_config_has "^install[[:space:]]+${m}[[:space:]]+/bin/(false|true)"; then
            r=0
        else
            r=1
            if modprobe_config_has "^blacklist[[:space:]]+${m}"; then
                warn "        ${m} is blacklisted but 'modprobe ${m}' still loads it — that is why CIS wants 'install ${m} /bin/false'"
            fi
        fi
        check "B3b ${m} is permanently disabled (install ${m} /bin/false)" "$r" \
              "printf 'install ${m} /bin/false\\nblacklist ${m}\\n' >> /etc/modprobe.d/cis-hardening.conf"
    done

    # B4 sudo principal
    [[ -e "$SUDOERS_DROPIN" ]] && r=1 || r=0
    check "B4a ${SUDOERS_DROPIN} is gone" "$r" "rm -f ${SUDOERS_DROPIN}"

    if grep -rhE 'NOPASSWD:[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null \
         | grep -qE "^[[:space:]]*${LAB_USER}"; then r=1; else r=0; fi
    check "B4b no NOPASSWD:ALL rule for ${LAB_USER}" "$r" "grep -R NOPASSWD /etc/sudoers.d/"

    id "$LAB_USER" >/dev/null 2>&1 && r=1 || r=0
    check "B4c local account ${LAB_USER} is gone" "$r" "userdel -r ${LAB_USER}"

    hr
    printf 'passed: %s%s%s   failed: %s%s%s\n' "${C_GRN}" "$PASS" "${C_RST}" "${C_RED}" "$FAIL" "${C_RST}"
    if [[ "$FAIL" -eq 0 ]]; then
        ok "host footprint minimized without breaking the node. Lab complete."
        printf '\nProve it end to end:\n  kubectl run probe --image=busybox:1.36 --restart=Never -it --rm -- \\\n    nslookup kubernetes.default.svc.cluster.local\n\n'
        return 0
    fi
    err "not there yet — re-read the failing hints, then run: sudo $0 verify"
    return 1
}

# ==============================================================================
# CLEANUP (give up / reset the VM)
# ==============================================================================
do_cleanup() {
    [[ "${1:-}" == "--give-up" ]] || die "cleanup requires --give-up (it hands you the answer)"

    title "CKS 5.1 — rolling the lab back"

    systemctl disable --now "$ROGUE_UNIT" >/dev/null 2>&1 || true
    rm -f "$ROGUE_UNIT_PATH"
    rm -f "$SYSCTL_BREAK" "$MODPROBE_BREAK" "$SUID_BIN" "$SUDOERS_DROPIN"
    restore_backups
    systemctl daemon-reload
    systemctl unmask systemd-modules-load.service >/dev/null 2>&1 || true
    systemctl start systemd-modules-load.service >/dev/null 2>&1 || true

    modprobe br_netfilter 2>/dev/null || true
    local m
    for m in "${NOISY_MODULES[@]}"; do modprobe -r "$m" 2>/dev/null || true; done

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true

    if id "$LAB_USER" >/dev/null 2>&1; then userdel -r "$LAB_USER" 2>/dev/null || userdel "$LAB_USER" 2>/dev/null || true; fi

    rm -rf "$WWW_DIR"
    ok "lab reverted. Backups kept in ${BACKUP_DIR} — delete them when you are done."
}

# ==============================================================================
# Entry point
# ==============================================================================
main() {
    local cmd="${1:-help}"; shift || true
    for a in "$@"; do [[ "$a" == "--i-know-this-is-a-lab-vm" ]] && LAB_ACK=1; done

    case "$cmd" in
        break)   need_root; do_break ;;
        status)  need_root; do_status ;;
        verify)  need_root; do_verify ;;
        cleanup) need_root; do_cleanup "${1:-}" ;;
        brief)   print_briefing ;;
        help|-h|--help)
            cat <<EOF
CKS 5.1 — Minimize host OS footprint — break & fix lab

  sudo CKS_LAB_DISPOSABLE=yes $0 break     break the host and print the briefing
  sudo $0 brief                            reprint the briefing
  sudo $0 status                           read-only footprint recon
  sudo $0 verify                           grade your fix
  sudo $0 cleanup --give-up                revert everything
EOF
            ;;
        *) die "unknown command '${cmd}' (try: $0 help)" ;;
    esac
}

main "$@"

# ==============================================================================
#  SOLUTION — step by step (read only after you have tried)
# ==============================================================================
#
#  METHOD. Two questions, in this order, for every piece of surface you find:
#    1. "Does the workload require it?"  -> if yes, it must be present AND
#       persistent (survive a reboot), not just patched at runtime.
#    2. "Can anything reach or abuse it?" -> if it is not required, it must be
#       impossible to bring back, not merely stopped.
#  A runtime-only fix passes a smoke test and fails the next reboot; a
#  "stop but do not disable" fix passes ss(8) and fails Restart=always.
#
# ------------------------------------------------------------------------------
#  STEP 0 — recon before touching anything
# ------------------------------------------------------------------------------
#    sudo ./cks-5.1-break-fix.sh status
#    sudo ss -lntp
#    sudo systemctl list-unit-files --state=enabled | wc -l
#    sudo systemctl list-units --failed
#    lsmod | wc -l
#    sudo find / -xdev -perm -4000 -type f 2>/dev/null
#    sudo grep -R '' /etc/sysctl.d/ /etc/modprobe.d/ /etc/modules-load.d/
#
#  What you are looking for, and why it matters on the exam:
#    * open ports        -> every listener is a remote entry point
#    * enabled units     -> every unit is code that runs as root at boot
#    * loaded modules    -> every module is kernel-space attack surface (dccp,
#                           sctp, rds, tipc, cramfs, usb-storage, firewire...)
#    * SUID/SGID files   -> every one is a local privilege-escalation candidate
#    * sudoers drop-ins  -> NOPASSWD turns any RCE into instant root
#
# ------------------------------------------------------------------------------
#  BLOCK A — restore the MINIMUM the node requires
# ------------------------------------------------------------------------------
#
#  A.0 Find the offending "hardening" artefacts:
#
#    $ sudo grep -R . /etc/sysctl.d/99-cks-lab-break.conf /etc/modprobe.d/99-cks-lab-break.conf
#    /etc/sysctl.d/99-cks-lab-break.conf:net.ipv4.ip_forward = 0
#    /etc/modprobe.d/99-cks-lab-break.conf:blacklist br_netfilter
#    /etc/modprobe.d/99-cks-lab-break.conf:install br_netfilter /bin/false
#
#  A.1 Delete the bad drop-ins (do NOT edit them into shape — remove the file
#      the "hardening" added, then state the requirement in your own file):
#
#    sudo rm -f /etc/sysctl.d/99-cks-lab-break.conf
#    sudo rm -f /etc/modprobe.d/99-cks-lab-break.conf
#
#      Note: `install br_netfilter /bin/false` is what makes `modprobe
#      br_netfilter` silently do nothing. `blacklist` alone only stops
#      *automatic* loading; `install ... /bin/false` stops explicit loading too.
#      Verify the effective policy, not the file you happen to be reading:
#
#        modprobe --showconfig | grep br_netfilter     # must print nothing
#
#  A.2 Restore module autoload at boot, the kubeadm-documented way:
#
#    cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
#    overlay
#    br_netfilter
#    EOF
#
#    sudo modprobe overlay
#    sudo modprobe br_netfilter
#    lsmod | grep br_netfilter
#    # br_netfilter           32768  0
#    # bridge                311296  1 br_netfilter
#
#  A.3 Unmask the unit that consumes /etc/modules-load.d at boot — without it
#      your k8s.conf is a decorative file:
#
#    systemctl is-enabled systemd-modules-load.service     # masked
#    sudo systemctl unmask systemd-modules-load.service
#    sudo systemctl start  systemd-modules-load.service
#    systemctl is-enabled systemd-modules-load.service     # static
#
#  A.4 Restore the required sysctls, persistently:
#
#    cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
#    net.ipv4.ip_forward                 = 1
#    net.bridge.bridge-nf-call-iptables  = 1
#    net.bridge.bridge-nf-call-ip6tables = 1
#    EOF
#
#    sudo sysctl --system | tail -n 5
#    sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
#    # net.ipv4.ip_forward = 1
#    # net.bridge.bridge-nf-call-iptables = 1
#
#      Ordering matters: the bridge-nf-* keys do not exist in /proc until
#      br_netfilter is loaded, so `sysctl --system` run before the modprobe
#      prints `cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables`.
#      Load the module first — that is exactly why the autoload unit is needed.
#
#  A.5 Confirm the data plane is alive again:
#
#    kubectl run probe --image=busybox:1.36 --restart=Never -it --rm -- \
#      nslookup kubernetes.default.svc.cluster.local
#    # Server:    10.96.0.10
#    # Address:   10.96.0.10:53
#    # Name:      kubernetes.default.svc.cluster.local
#    # Address:   10.96.0.1
#
#    sudo kubeadm upgrade plan   # preflight no longer complains about ip_forward
#
# ------------------------------------------------------------------------------
#  BLOCK B — delete the surface the node does NOT require
# ------------------------------------------------------------------------------
#
#  B.1 The self-resurrecting listener. Go from socket -> PID -> cgroup -> unit;
#      never stop at "I killed the process":
#
#    $ sudo ss -lntp 'sport = :8080'
#    LISTEN 0 5 0.0.0.0:8080 0.0.0.0:* users:(("python3",pid=1421,fd=3))
#
#    $ systemctl status 1421            # systemd resolves a PID to its unit
#    ● cks-lab-legacy-metrics.service - Legacy node metrics exporter ...
#
#    # or, without systemctl:  cat /proc/1421/cgroup
#
#    sudo systemctl disable --now cks-lab-legacy-metrics.service
#    sudo rm -f /etc/systemd/system/cks-lab-legacy-metrics.service
#    sudo systemctl daemon-reload
#    sudo systemctl reset-failed
#    sudo ss -lntp 'sport = :8080'      # empty
#
#      `systemctl stop` alone loses to Restart=always the moment anything
#      restarts it; `disable` alone leaves the unit runnable; when the unit must
#      remain on disk but must never run, use `systemctl mask <unit>`, which
#      symlinks it to /dev/null so even a dependency cannot pull it up.
#      Generalize on the exam: `systemctl list-units --type=service --state=running`
#      and switch off everything the node does not need to be a node.
#
#  B.2 The SUID binary. A SUID copy of find(1) is a textbook local root:
#      `lab-find . -exec /bin/sh -p \;` gives an euid-0 shell.
#
#    sudo find / -xdev -perm -4000 -type f 2>/dev/null
#    # /usr/local/bin/lab-find      <-- not shipped by any package
#    dpkg -S /usr/local/bin/lab-find || rpm -qf /usr/local/bin/lab-find
#    # no path found / file ... is not owned by any package
#
#    sudo chmod u-s /usr/local/bin/lab-find     # minimum viable fix
#    sudo rm -f     /usr/local/bin/lab-find     # correct fix: it is not needed
#
#  B.3 Unnecessary kernel modules (CIS "unused network protocols"):
#
#    lsmod | grep -E '^(dccp|sctp)'
#    sudo modprobe -r dccp sctp
#
#    cat <<'EOF' | sudo tee /etc/modprobe.d/cis-disable-protocols.conf
#    install dccp /bin/false
#    install sctp /bin/false
#    install rds  /bin/false
#    install tipc /bin/false
#    blacklist dccp
#    blacklist sctp
#    blacklist rds
#    blacklist tipc
#    EOF
#
#    sudo modprobe dccp ; lsmod | grep -c dccp     # 0 — the install line wins
#
#      If the module is compiled into a running kernel path you cannot unload
#      (`rmmod: ERROR: Module ... is in use`), find the user first:
#      `lsmod | grep <mod>` shows the refcount and the dependent modules.
#
#  B.4 The passwordless-sudo principal:
#
#    sudo grep -R 'NOPASSWD' /etc/sudoers /etc/sudoers.d/
#    # /etc/sudoers.d/99-cks-lab-ops:cks-lab-ops ALL=(ALL) NOPASSWD: ALL
#
#    sudo rm -f /etc/sudoers.d/99-cks-lab-ops
#    sudo visudo -c                    # ALWAYS re-validate after editing sudoers
#    sudo userdel -r cks-lab-ops
#
#      Then audit the rest of the principals, which is what the exam actually
#      rewards: `awk -F: '($3<1000)&&($7!~/nologin|false/){print}' /etc/passwd`,
#      `getent group sudo wheel`, `awk -F: '($2==""){print $1}' /etc/shadow`.
#
# ------------------------------------------------------------------------------
#  STEP FINAL — grade and reason about it
# ------------------------------------------------------------------------------
#    sudo ./cks-5.1-break-fix.sh verify
#    # passed: 18   failed: 0
#
#  TAKEAWAYS FOR THE EXAM
#    * Minimizing the host footprint is a subtraction with a whitelist, not a
#      subtraction. br_netfilter and ip_forward look like surface; on a node with
#      a bridged CNI they are load-bearing.
#    * Every fix has a runtime half and a persistence half. sysctl -w without
#      /etc/sysctl.d, modprobe without /etc/modules-load.d, and systemctl stop
#      without disable/mask are all half-fixes that die at the next boot.
#    * `blacklist` != `install /bin/false`. Only the second one survives an
#      attacker (or a script) running modprobe explicitly.
#    * Trace a port to a unit, not to a PID: ss -lntp -> systemctl status <pid>
#      -> disable --now + rm + daemon-reload.
#    * The same reasoning applies one layer up in Domain 5: a distroless or
#      scratch image is exactly this exercise applied to the container
#      filesystem — no shell, no package manager, no SUID binaries, no extra
#      listeners. Host and image are the same discipline at two scales.
# ==============================================================================