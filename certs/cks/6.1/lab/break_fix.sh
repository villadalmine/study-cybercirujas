#!/bin/bash
#
# ==============================================================================
#  CKS 1.34 -- Domain 6: Monitoring, Logging and Runtime Security
#  Topic 6.1  -- Perform behavioral analytics to detect malicious activities
#  Exam weight: 4%
#
#  BREAK & FIX lab -- Falco runtime behavioral detection
#
#  Reference: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#             https://falco.org/docs/reference/rules/
#             https://falco.org/docs/reference/daemon/config-options/
#
#  WARNING: this script edits /etc/falco/* and restarts the Falco service.
#           Run it ONLY on a disposable lab VM. Never on a real node.
#
#  Usage:
#     sudo ./break_fix.sh break     # (default) sabotage the detection pipeline
#     sudo ./break_fix.sh attack    # replay the three simulated attacks
#     sudo ./break_fix.sh verify    # grade the lab (attack + alert correlation)
#     sudo ./break_fix.sh reset     # restore the pristine Falco configuration
#
#  The step-by-step solution is at the bottom of this file, commented out.
# ==============================================================================

set -Eeuo pipefail

FALCO_CFG="/etc/falco/falco.yaml"
FALCO_RULES_DIR="/etc/falco/rules.d"
LAB_RULES="${FALCO_RULES_DIR}/cks-6.1-behavioral.yaml"
LAB_HOME="/opt/cks-lab/6.1"
DECOY_WEBSERVER="${LAB_HOME}/bin/cks-nginx"
IMPLANT_PATH="/usr/local/bin/cks-implant"
BACKUP_DIR="/root/.cks-lab/6.1"
STATE_FILE="${BACKUP_DIR}/state"
FALCO_UNIT=""

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

log()  { printf '%s[*]%s %s\n' "${C_BLU}" "${C_OFF}" "$*"; }
ok()   { printf '%s[+]%s %s\n' "${C_GRN}" "${C_OFF}" "$*"; }
warn() { printf '%s[!]%s %s\n' "${C_YEL}" "${C_OFF}" "$*"; }
err()  { printf '%s[-]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "aborted at line ${LINENO}"' ERR

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------

require_root() {
    [[ ${EUID} -eq 0 ]] || die "this lab must run as root (use sudo)."
}

confirm_disposable_vm() {
    [[ "${CKS_LAB_CONFIRM:-}" == "yes" ]] && return 0
    if [[ ! -t 0 ]]; then
        die "non-interactive run: export CKS_LAB_CONFIRM=yes to acknowledge this is a throwaway VM."
    fi
    printf '%s\n' "${C_YEL}This script modifies Falco's configuration and rules on THIS host.${C_OFF}"
    read -r -p "Type 'yes' if this is a disposable lab VM: " answer
    [[ "${answer}" == "yes" ]] || die "aborted by the user."
}

detect_falco_unit() {
    local candidate
    for candidate in falco-modern-bpf.service falco-bpf.service falco-kmod.service \
                     falco.service falco-custom.service; do
        systemctl cat "${candidate}" >/dev/null 2>&1 || continue
        if systemctl is-active --quiet "${candidate}"; then
            FALCO_UNIT="${candidate}"; return 0
        fi
        [[ -z "${FALCO_UNIT}" ]] && FALCO_UNIT="${candidate}"
    done
    [[ -n "${FALCO_UNIT}" ]]
}

install_falco() {
    warn "Falco is not installed. Installing from the official falcosecurity repository (needs Internet)."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive FALCO_FRONTEND=noninteractive
        curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
            | gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main" \
            > /etc/apt/sources.list.d/falcosecurity.list
        apt-get update -y
        apt-get install -y dialog "linux-headers-$(uname -r)" || true
        apt-get install -y falco
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        local pm; pm="$(command -v dnf || command -v yum)"
        rpm --import https://falco.org/repo/falcosecurity-packages.asc
        curl -fsSL -o /etc/yum.repos.d/falcosecurity.repo https://falco.org/repo/falcosecurity-rpm.repo
        "${pm}" install -y dialog "kernel-devel-$(uname -r)" || true
        FALCO_FRONTEND=noninteractive "${pm}" install -y falco
    else
        die "unsupported package manager: install Falco manually (https://falco.org/docs/install-operate/installation/)."
    fi
}

ensure_falco_running() {
    command -v falco >/dev/null 2>&1 || install_falco
    detect_falco_unit || die "no falco systemd unit found after installation."

    if [[ ! -e /sys/kernel/btf/vmlinux ]]; then
        warn "no BTF at /sys/kernel/btf/vmlinux: the modern_ebpf driver may be unavailable on this kernel."
    fi

    if ! systemctl is-active --quiet "${FALCO_UNIT}"; then
        log "starting ${FALCO_UNIT} ..."
        systemctl enable --now "${FALCO_UNIT}" >/dev/null 2>&1 || true
    fi
    systemctl is-active --quiet "${FALCO_UNIT}" \
        || die "${FALCO_UNIT} will not start; check 'journalctl -u ${FALCO_UNIT} -n 80' (driver problem)."
    ok "Falco is running as ${FALCO_UNIT} ($(falco --version 2>/dev/null | head -n1))"
}

restart_falco() {
    systemctl restart "${FALCO_UNIT}"
    sleep 4
    systemctl is-active --quiet "${FALCO_UNIT}" \
        || die "${FALCO_UNIT} failed to restart: journalctl -u ${FALCO_UNIT} -n 80"
}

# ------------------------------------------------------------------------------
# Lab assets: detection rules and the simulated attacker
# ------------------------------------------------------------------------------

write_lab_rules() {
    mkdir -p "${FALCO_RULES_DIR}"
    # NOTE: this ruleset is intentionally shipped with ONE defective condition.
    cat > "${LAB_RULES}" <<'YAML'
#
# CKS 6.1 -- behavioral analytics lab ruleset.
# Deployed by the platform team to detect post-exploitation behaviour on nodes
# and inside containers. Every alert is tagged CKS-6.1-Rn for SIEM correlation.
#

- list: cks_shell_binaries
  items: [sh, bash, dash, ash, zsh, ksh, csh, tcsh, busybox]

- list: cks_web_binaries
  items: [cks-nginx, nginx, httpd, apache2, node, gunicorn, uwsgi, php-fpm, java]

- list: cks_credential_files
  items: [/etc/shadow, /etc/gshadow, /root/.ssh/id_rsa, /etc/kubernetes/pki/ca.key]

- list: cks_credential_readers
  items: [sshd, sudo, su, login, passwd, chage, useradd, usermod, groupadd,
          newgrp, gpasswd, unix_chkpwd, systemd, systemd-logind, agetty,
          polkitd, sssd, falco, vipw]

- list: cks_binary_dirs
  items: [/bin, /sbin, /usr/bin, /usr/sbin, /usr/local/bin, /usr/local/sbin]

- list: cks_package_managers
  items: [dpkg, dpkg-deb, apt, apt-get, rpm, rpmdb, dnf, yum, zypper, pacman,
          update-alternat, ln, containerd, dockerd, kubelet, falcoctl, cp-pkg]

- macro: cks_spawned_process
  condition: (evt.type in (execve, execveat) and evt.dir=<)

- macro: cks_open_read
  condition: (evt.type in (open, openat, openat2) and evt.is_open_read=true
              and fd.typechar='f' and fd.num>=0)

- macro: cks_open_write
  condition: (evt.type in (open, openat, openat2, creat) and evt.is_open_write=true
              and fd.typechar='f' and fd.num>=0)

- rule: CKS-6.1-R1 Shell Spawned by Web Server Binary
  desc: >
    A shell was executed with a web/application server process as its parent or
    grandparent. This is the canonical footprint of remote code execution being
    turned into interactive access (MITRE ATT&CK T1059). A web server that has
    never needed a shell in production suddenly needing one is a behavioral
    anomaly, not a signature -- which is exactly what runtime analytics buys you.
  condition: >
    cks_spawned_process
    and proc.name in (cks_shell_binaries)
    and (proc.pname in (cks_web_binaries) or proc.aname[2] in (cks_web_binaries))
  output: >
    CKS-6.1-R1 shell spawned by a web server process
    (user=%user.name uid=%user.uid shell=%proc.name parent=%proc.pname
     cmdline=%proc.cmdline container_id=%container.id
     image=%container.image.repository)
  priority: CRITICAL
  tags: [host, container, process, mitre_execution, T1059]

- rule: CKS-6.1-R2 Credential File Read
  desc: >
    A non-authentication process opened a credential store (/etc/shadow, node
    SSH keys, cluster CA key). Credential access is stage two of almost every
    node compromise (MITRE ATT&CK T1552.001).
  condition: >
    cks_open_write
    and fd.name in (cks_credential_files)
    and not proc.name in (cks_credential_readers)
  output: >
    CKS-6.1-R2 credential file accessed
    (user=%user.name uid=%user.uid proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname file=%fd.name container_id=%container.id
     image=%container.image.repository)
  priority: WARNING
  tags: [host, container, filesystem, mitre_credential_access, T1552.001]

- rule: CKS-6.1-R3 Write Below Binary Dir
  desc: >
    A file was created or modified inside a system binary directory by a process
    that is not a package manager. Attackers drop implants there for persistence
    and to hijack the PATH of other workloads (MITRE ATT&CK T1543).
  condition: >
    cks_open_write
    and fd.directory in (cks_binary_dirs)
    and not proc.name in (cks_package_managers)
  output: >
    CKS-6.1-R3 write below a binary directory
    (user=%user.name uid=%user.uid proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname file=%fd.name container_id=%container.id
     image=%container.image.repository)
  priority: NOTICE
  tags: [host, container, filesystem, mitre_persistence, T1543]
YAML
    chmod 0644 "${LAB_RULES}"
}

write_decoy_workload() {
    mkdir -p "${LAB_HOME}/bin"
    # Plain '#!/bin/bash' shebang on purpose: the kernel sets comm from the script
    # name, so Falco reports proc.name=cks-nginx for this process. With
    # '#!/usr/bin/env bash' the second execve would rewrite comm to "bash".
    cat > "${DECOY_WEBSERVER}" <<'EOS'
#!/bin/bash
# Decoy application server used by the CKS 6.1 lab. It simulates an RCE by
# spawning a child shell -- no network listener, nothing is exposed.
/bin/sh -c 'id -u >/dev/null 2>&1'
EOS
    chmod 0755 "${DECOY_WEBSERVER}"
}

# ------------------------------------------------------------------------------
# Falco configuration surgery
# ------------------------------------------------------------------------------

rules_list_key() {
    if   grep -qE '^rules_files:' "${FALCO_CFG}"; then echo "rules_files"
    elif grep -qE '^rules_file:'  "${FALCO_CFG}"; then echo "rules_file"
    else echo ""; fi
}

ensure_rules_dir_entry() {
    local key; key="$(rules_list_key)"
    if [[ -z "${key}" ]]; then
        cat >> "${FALCO_CFG}" <<'EOS'

rules_files:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/falco_rules.local.yaml
  - /etc/falco/rules.d
EOS
        return
    fi
    grep -qE '^[[:space:]]*#?[[:space:]]*-[[:space:]]*/etc/falco/rules\.d/?[[:space:]]*$' "${FALCO_CFG}" \
        || sed -ri "0,/^${key}:/s||${key}:\n  - /etc/falco/rules.d|" "${FALCO_CFG}"
}

backup_pristine_state() {
    mkdir -p "${BACKUP_DIR}"
    [[ -f "${BACKUP_DIR}/falco.yaml.orig" ]] || cp -a "${FALCO_CFG}" "${BACKUP_DIR}/falco.yaml.orig"
}

# ------------------------------------------------------------------------------
# The three faults
# ------------------------------------------------------------------------------

apply_faults() {
    # Fault 1 -- the rules.d entry is commented out, so no custom rule is loaded.
    sed -ri 's|^([[:space:]]*)-([[:space:]]*)(/etc/falco/rules\.d/?)[[:space:]]*$|\1#-\2\3|' "${FALCO_CFG}"

    # Fault 2 -- the engine's minimum priority is raised, silently dropping every
    #            rule below CRITICAL at load time.
    if grep -qE '^priority:' "${FALCO_CFG}"; then
        sed -ri 's|^priority:.*|priority: critical|' "${FALCO_CFG}"
    else
        printf '\n# minimum severity a rule must have to be loaded\npriority: critical\n' >> "${FALCO_CFG}"
    fi

    # Fault 3 -- R2 already ships with an inverted condition (cks_open_write on a
    #            read-only access pattern); see write_lab_rules().

    printf 'broken_at=%s\nunit=%s\nfaults=3\n' "$(date -Is)" "${FALCO_UNIT}" > "${STATE_FILE}"
}

# ------------------------------------------------------------------------------
# Attack simulation
# ------------------------------------------------------------------------------

run_attacks() {
    log "replaying the simulated attack chain ..."
    "${DECOY_WEBSERVER}" >/dev/null 2>&1 || true          # R1: web server spawns a shell
    /bin/cat /etc/shadow >/dev/null 2>&1 || true          # R2: credential file read
    /bin/cp /bin/true "${IMPLANT_PATH}" >/dev/null 2>&1 || true   # R3: implant dropped
    rm -f "${IMPLANT_PATH}"
    ok "attack chain executed (3 techniques)."
}

falco_log_since() {
    local since="$1"
    journalctl -u "${FALCO_UNIT}" --since "${since}" --no-pager -o cat 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Grading
# ------------------------------------------------------------------------------

verify() {
    require_root
    detect_falco_unit || die "Falco is not installed on this host."
    [[ -f "${DECOY_WEBSERVER}" ]] || die "lab assets missing: run '$(basename "$0") break' first."

    local since deadline logs r1=1 r2=1 r3=1
    since="$(date -d '3 seconds ago' '+%Y-%m-%d %H:%M:%S')"
    run_attacks

    log "correlating alerts in the journal of ${FALCO_UNIT} (up to 30s) ..."
    deadline=$((SECONDS + 30))
    while :; do
        logs="$(falco_log_since "${since}")"
        grep -qF 'CKS-6.1-R1' <<<"${logs}" && r1=0
        grep -qF 'CKS-6.1-R2' <<<"${logs}" && r2=0
        grep -qF 'CKS-6.1-R3' <<<"${logs}" && r3=0
        { [[ ${r1} -eq 0 && ${r2} -eq 0 && ${r3} -eq 0 ]] || (( SECONDS >= deadline )); } && break
        sleep 3
    done

    echo
    printf '%s--- CKS 6.1 grading -------------------------------------------%s\n' "${C_BLD}" "${C_OFF}"
    [[ ${r1} -eq 0 ]] && ok   "R1 CRITICAL  shell spawned by web server binary ..... DETECTED" \
                      || err  "R1 CRITICAL  shell spawned by web server binary ..... MISSING"
    [[ ${r2} -eq 0 ]] && ok   "R2 WARNING   credential file read .................. DETECTED" \
                      || err  "R2 WARNING   credential file read .................. MISSING"
    [[ ${r3} -eq 0 ]] && ok   "R3 NOTICE    write below binary dir ................. DETECTED" \
                      || err  "R3 NOTICE    write below binary dir ................. MISSING"
    echo

    if [[ ${r1} -eq 0 && ${r2} -eq 0 && ${r3} -eq 0 ]]; then
        ok "${C_BLD}LAB PASSED${C_OFF} -- the behavioral detection pipeline is healthy end to end."
        return 0
    fi
    warn "LAB NOT PASSED yet. Useful next commands:"
    printf '    falco -L | grep CKS-6.1\n'
    printf '    journalctl -u %s -n 60 --no-pager | grep -Ei "rule|priority|load"\n' "${FALCO_UNIT}"
    printf '    grep -nE "^(rules_file|rules_files|priority)|rules\\.d" %s\n' "${FALCO_CFG}"
    return 1
}

# ------------------------------------------------------------------------------
# Reset
# ------------------------------------------------------------------------------

reset_lab() {
    require_root
    detect_falco_unit || die "Falco is not installed on this host."
    [[ -f "${BACKUP_DIR}/falco.yaml.orig" ]] || die "no pristine backup found in ${BACKUP_DIR}."
    cp -a "${BACKUP_DIR}/falco.yaml.orig" "${FALCO_CFG}"
    rm -f "${LAB_RULES}" "${IMPLANT_PATH}" "${STATE_FILE}"
    rm -rf "${LAB_HOME}"
    restart_falco
    ok "lab reset: Falco configuration restored and lab assets removed."
}

# ------------------------------------------------------------------------------
# Briefing
# ------------------------------------------------------------------------------

print_briefing() {
    cat <<EOF

${C_BLD}================================================================================
 CKS 1.34 -- 6.1 Perform behavioral analytics to detect malicious activities
 BREAK & FIX -- "the SOC went blind"
================================================================================${C_OFF}

${C_BLD}SCENARIO${C_OFF}
  This node runs Falco (${FALCO_UNIT}) as the runtime behavioral-analytics
  sensor. The platform team ships three detections in
  ${LAB_RULES}:

    CKS-6.1-R1  CRITICAL  a shell spawned by a web/application server binary
    CKS-6.1-R2  WARNING   a credential file (/etc/shadow, node keys) is read
    CKS-6.1-R3  NOTICE    a file is written below a system binary directory

  Overnight, "a change" reached this node. Falco is up, the driver is loaded,
  the service is green -- and the attack chain now runs from end to end without
  producing a single alert. Detection is broken in ${C_BLD}three independent places${C_OFF},
  and each one hides the next: you will only see the second symptom after fixing
  the first.

${C_BLD}SYMPTOMS YOU WILL SEE${C_OFF}
  1. \`systemctl is-active ${FALCO_UNIT}\` returns ${C_GRN}active${C_OFF}: the sensor is NOT down.
  2. \`sudo ${LAB_HOME}/bin/cks-nginx\` (a decoy web server that spawns a shell),
     \`sudo cat /etc/shadow\` and \`sudo cp /bin/true /usr/local/bin/cks-implant\`
     all execute normally and \`journalctl -u ${FALCO_UNIT} -f\` stays silent.
  3. \`falco -L | grep CKS-6.1\` returns nothing at all.
  4. Once rules start loading you will notice that only ${C_BLD}some${C_OFF} severities alert:
     the same syscall activity produces a CRITICAL line and nothing else.

  A healthy pipeline emits lines like:

    14:02:11.093214781: Critical CKS-6.1-R1 shell spawned by a web server process
      (user=root uid=0 shell=sh parent=cks-nginx cmdline=sh -c id -u ...)

${C_BLD}YOUR OBJECTIVE${C_OFF}
  Restore full-fidelity behavioral detection: the three rules must be LOADED by
  the engine and must FIRE on the corresponding activity, on the host and inside
  containers alike.

  Rules of engagement:
    - Do NOT disable, mask or bypass Falco, and do NOT delete the lab ruleset.
    - Do NOT copy back the pristine file from ${BACKUP_DIR}
      (that is only there for '$(basename "$0") reset'). Diagnose, then fix.
    - Fix the detection ${C_BLD}logic${C_OFF} where it is wrong -- do not weaken a rule to make
      it fire (a rule that alerts on everything is not a detection).

${C_BLD}GRADE YOURSELF${C_OFF}
    sudo $(basename "$0") attack     # replay the three techniques
    sudo $(basename "$0") verify     # attack + correlate alerts, prints 3/3
    sudo $(basename "$0") reset      # start over from a pristine configuration

${C_BLD}HINTS -- the three questions of runtime detection triage${C_OFF}
  a) Is the rule ${C_BLD}loaded${C_OFF}?      falco -L | grep CKS-6.1
  b) Is the engine ${C_BLD}allowed${C_OFF} to load it?
                              journalctl -u ${FALCO_UNIT} | grep -i -E 'skip|priority'
  c) Does the ${C_BLD}condition${C_OFF} actually match the observed syscalls?
                              falco -V ${LAB_RULES}
                              falco -l 'CKS-6.1-R2 Credential File Read'

EOF
}

# ------------------------------------------------------------------------------
# Entry points
# ------------------------------------------------------------------------------

do_break() {
    require_root
    confirm_disposable_vm
    ensure_falco_running
    backup_pristine_state
    write_lab_rules
    write_decoy_workload
    ensure_rules_dir_entry
    apply_faults
    restart_falco
    log "sanity check: the attack chain must stay silent right now."
    run_attacks
    print_briefing
    warn "Detection is broken in 3 places. Good hunting."
}

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    case "${1:-break}" in
        break)          do_break ;;
        attack)         require_root; detect_falco_unit || die "Falco not installed."; run_attacks ;;
        verify|check)   verify ;;
        reset)          reset_lab ;;
        -h|--help|help) usage ;;
        *)              die "unknown subcommand '$1' (try --help)." ;;
    esac
}

main "$@"

# ==============================================================================
#  SOLUTION -- step by step
# ==============================================================================
#
#  Mental model first. A Falco alert only exists if FOUR layers all work:
#
#      driver (syscall capture) -> rule LOADED -> condition MATCHES -> output CHANNEL
#
#  Triage always walks that chain in order. This lab breaks layers 2, 2 and 3;
#  layer 1 and 4 are healthy, which is why the service looks perfectly green.
#
# ------------------------------------------------------------------------------
#  STEP 0 -- confirm the sensor itself is alive (layer 1)
# ------------------------------------------------------------------------------
#
#     systemctl status falco-modern-bpf.service      # or falco-bpf / falco-kmod
#     journalctl -u falco-modern-bpf.service -n 60 --no-pager
#
#  Expect: "Falco initialized with configuration files", "Starting health
#  webserver", "Loading rules from file ...". If you see driver errors instead
#  ("cannot open BPF probe", "kernel module not loaded") that is a layer-1
#  problem and nothing else matters -- it is NOT the case here.
#
#  Also confirm events are actually flowing (no capture, no analytics):
#
#     journalctl -u falco-modern-bpf.service | grep -i 'syscall event drop'
#     curl -s localhost:8765/healthz          # if the health webserver is on
#
# ------------------------------------------------------------------------------
#  STEP 1 -- FAULT #1: the ruleset is never loaded
# ------------------------------------------------------------------------------
#
#     falco -L | grep CKS-6.1        # -> empty: the engine does not know the rules
#     ls -l /etc/falco/rules.d/cks-6.1-behavioral.yaml   # the file IS on disk
#
#  So the file exists but is not in the load list. Inspect it:
#
#     grep -nE '^(rules_file|rules_files):' -A6 /etc/falco/falco.yaml
#
#  You will find the directory entry commented out:
#
#     rules_files:
#       - /etc/falco/falco_rules.yaml
#       - /etc/falco/falco_rules.local.yaml
#       #- /etc/falco/rules.d          <-- sabotage
#
#  Fix -- uncomment it (order matters: later files override earlier ones, which
#  is exactly how falco_rules.local.yaml is meant to customise the defaults):
#
#     sudo sed -ri 's|^([[:space:]]*)#-([[:space:]]*)(/etc/falco/rules\.d/?)$|\1-\2\3|' \
#          /etc/falco/falco.yaml
#     sudo systemctl restart falco-modern-bpf.service
#     falco -L | grep CKS-6.1
#
#  (With the default `watch_config_files: true`, Falco also hot-reloads on file
#   changes; an explicit restart or `kill -HUP $(pidof falco)` removes doubt.)
#
#  Now only ONE rule appears: "CKS-6.1-R1 Shell Spawned by Web Server Binary".
#  Two rules are still missing -> the next fault.
#
# ------------------------------------------------------------------------------
#  STEP 2 -- FAULT #2: the minimum priority threshold hides two rules
# ------------------------------------------------------------------------------
#
#  The engine tells you, if you read its startup log:
#
#     journalctl -u falco-modern-bpf.service -n 80 --no-pager | grep -iE 'skip|priority'
#
#  Falco skips at LOAD TIME every rule whose priority is below the configured
#  minimum. Confirm the knob:
#
#     grep -nE '^priority:' /etc/falco/falco.yaml
#     priority: critical            <-- sabotage (default is `debug`)
#
#  Severity order (highest to lowest):
#     emergency > alert > critical > error > warning > notice > informational > debug
#
#  With `critical`, R2 (WARNING) and R3 (NOTICE) are never even compiled. That is
#  the subtle part: they do not "fail to match", they do not exist for the engine.
#
#  Fix:
#
#     sudo sed -ri 's|^priority:.*|priority: debug|' /etc/falco/falco.yaml
#     sudo systemctl restart falco-modern-bpf.service
#     falco -L | grep -c CKS-6.1     # -> 3
#
#  Production note: raising this threshold is a legitimate noise-control lever,
#  but it is the wrong one. Prefer tuning the offending rule with an override /
#  exception (`- rule: X` + `override: {exceptions: append}`) so you keep the
#  detection and drop only the known-benign path.
#
# ------------------------------------------------------------------------------
#  STEP 3 -- FAULT #3: R2's condition is logically inverted
# ------------------------------------------------------------------------------
#
#     sudo /opt/cks-lab/6.1/bin/cks-nginx      # -> R1 fires (CRITICAL)
#     sudo cp /bin/true /usr/local/bin/x; sudo rm /usr/local/bin/x   # -> R3 fires
#     sudo cat /etc/shadow > /dev/null         # -> silence, still
#
#  The rule is loaded (`falco -l 'CKS-6.1-R2 Credential File Read'`) but never
#  matches. Read the condition:
#
#     - rule: CKS-6.1-R2 Credential File Read
#       condition: >
#         cks_open_write                       <-- wrong: this is a READ detection
#         and fd.name in (cks_credential_files)
#         and not proc.name in (cks_credential_readers)
#
#  `cks_open_write` requires evt.is_open_write=true. An attacker EXFILTRATING
#  /etc/shadow opens it O_RDONLY, so the rule can only fire if the attacker
#  writes to the file -- a detection that describes the wrong behaviour. This is
#  the most dangerous class of failure in behavioral analytics: green pipeline,
#  loaded rule, zero coverage.
#
#  Fix -- swap the macro for the read one:
#
#     sudo sed -i '/CKS-6.1-R2 Credential File Read/,/priority:/ s/cks_open_write/cks_open_read/' \
#          /etc/falco/rules.d/cks-6.1-behavioral.yaml
#
#  Validate the syntax BEFORE restarting (this is the habit that saves you in the
#  exam and in production -- a bad rules file makes Falco refuse to start):
#
#     falco -V /etc/falco/rules.d/cks-6.1-behavioral.yaml
#     sudo systemctl restart falco-modern-bpf.service
#
#  The corrected rule:
#
#     - rule: CKS-6.1-R2 Credential File Read
#       desc: A non-authentication process opened a credential store.
#       condition: >
#         cks_open_read
#         and fd.name in (cks_credential_files)
#         and not proc.name in (cks_credential_readers)
#       output: >
#         CKS-6.1-R2 credential file accessed
#         (user=%user.name uid=%user.uid proc=%proc.name cmdline=%proc.cmdline
#          parent=%proc.pname file=%fd.name container_id=%container.id
#          image=%container.image.repository)
#       priority: WARNING
#       tags: [host, container, filesystem, mitre_credential_access, T1552.001]
#
# ------------------------------------------------------------------------------
#  STEP 4 -- verify
# ------------------------------------------------------------------------------
#
#     sudo ./break_fix.sh verify        # -> R1, R2, R3 DETECTED, LAB PASSED
#
#  Watch it live in a second terminal while the attacks replay:
#
#     journalctl -u falco-modern-bpf.service -f | grep CKS-6.1
#
#  Same detections inside a container (the fields container.id / container.image
#  stop being <NA>, which is how you separate node activity from workload
#  activity in the SIEM):
#
#     kubectl run rce-sim --image=busybox --restart=Never -it -- \
#         sh -c 'cat /etc/shadow > /dev/null; cp /bin/true /usr/local/bin/implant'
#
# ------------------------------------------------------------------------------
#  CHECKLIST -- why a Falco detection is silent, in triage order
# ------------------------------------------------------------------------------
#
#   1. Sensor/driver:  unit active? driver loaded? `syscall event drop` messages?
#                      -> drops mean the buffer overflowed: raise
#                         syscall_buf_size_preset / tune base_syscalls.
#   2. Rule loaded:    `falco -L`; is the file in rules_files? is it shadowed by
#                      a later definition with the same name? `falco -V <file>`.
#   3. Load filters:   falco.yaml `priority:` threshold; `load_plugins`;
#                      rule `enabled: false`; `-T <tag>` / `-t <tag>` in the unit's
#                      ExecStart; `--disable-source`.
#   4. Condition:      does it describe the behaviour you are hunting (read vs
#                      write, evt.dir=< vs >, container vs host)? Test the field
#                      values with `falco -l <rule>` and by reading %evt.args.
#   5. Exceptions:     an over-broad `not proc.name in (...)` allow-list is how
#                      real detections die quietly -- attackers rename binaries
#                      to whatever your exception list contains.
#   6. Output channel: `stdout_output`, `file_output`, `json_output`,
#                      `buffered_outputs`, the `outputs` rate limiter, and
#                      whether falcosidekick/the SIEM forwarder is alive.
#
#  Sources:
#    - CKS v1.34 curriculum: https://github.com/cncf/curriculum
#    - Falco rules reference: https://falco.org/docs/reference/rules/
#    - Falco config reference: https://falco.org/docs/reference/daemon/config-options/
#    - Supported fields: https://falco.org/docs/reference/rules/supported-fields/
#    - MITRE ATT&CK for Containers: https://attack.mitre.org/matrices/enterprise/containers/
# ==============================================================================