#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-3 303 Security  —  exam 303-300, version 3.0.0
#  Topic 332.1  Host Hardening   (exam weight: 8.33)
#
#  break-and-fix.sh — controlled damage laboratory driver
#
#  WHAT THIS IS
#  ------------
#  This script deliberately misconfigures a DISPOSABLE lab VM in ways that a
#  real "hardening" change request produces in production: a vendor drop-in
#  that silently shadows your CIS baseline, a resource limit that starves a
#  service account, a noexec /tmp that breaks a tool, a sandboxed unit with no
#  writable state directory, an ineffective module blacklist, an expired
#  account behind a pam_wheel policy, and a GRUB superuser stanza that does
#  not actually protect anything.
#
#  For every scenario it prints (a) the symptom the student will observe and
#  (b) the objective that must be reached. It then provides a machine
#  verification (`verify`) that only passes when the system is BOTH working
#  AGAIN AND STILL HARDENED — restoring service by removing the hardening is
#  an explicit FAIL, because that is the mistake this topic exists to prevent.
#
#  The full step-by-step solution is at the end of this file, commented out.
#
#  SAFETY MODEL
#  ------------
#   * Refuses to run unless it is root AND (the host reports as a virtual
#     machine OR the marker file /etc/teach-plat-lab exists). Override with
#     --force only if you know the host is expendable.
#   * Every file it touches is backed up under
#     /var/lib/lpic3-303-332.1-breakfix/<scenario>/tree/ before modification;
#     every file it creates is recorded in created.list.
#   * `restore` puts everything back, including runtime state (sysctl values,
#     mount options, loaded modules, systemd units).
#   * It never writes /boot/grub2/grub.cfg. The bootloader scenario is
#     verified against a scratch config, exactly as you should do in
#     production before committing a bootloader change.
#   * It never edits /etc/pam.d/system-auth or /etc/pam.d/password-auth. The
#     only PAM file touched is /etc/pam.d/su, and the edit is sanity-checked
#     immediately with an automatic rollback if root's own `su` stops working.
#   * Take a VM snapshot anyway. That is the professional habit this lab is
#     also training.
#
#  USAGE
#  -----
#    ./break-and-fix.sh list
#    ./break-and-fix.sh break  <scenario|all|random>
#    ./break-and-fix.sh verify [scenario|all]
#    ./break-and-fix.sh hint   <scenario>
#    ./break-and-fix.sh status
#    ./break-and-fix.sh restore [scenario|all]
#
#  Flags: --yes (skip the confirmation prompt), --force (skip the VM check).
#
#  REFERENCES (official)
#   LPI 303-300 objectives . https://www.lpi.org/our-certifications/exam-303-objectives/
#   sysctl.d(5) ........... https://man7.org/linux/man-pages/man5/sysctl.d.5.html
#   kernel sysctl docs .... https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html
#   limits.conf(5) ........ https://man7.org/linux/man-pages/man5/limits.conf.5.html
#   pam_limits(8) ......... https://man7.org/linux/man-pages/man8/pam_limits.8.html
#   pam_wheel(8) .......... https://man7.org/linux/man-pages/man8/pam_wheel.8.html
#   login.defs(5) ......... https://man7.org/linux/man-pages/man5/login.defs.5.html
#   shadow(5) / chage(1) .. https://man7.org/linux/man-pages/man5/shadow.5.html
#   mount(8) .............. https://man7.org/linux/man-pages/man8/mount.8.html
#   modprobe.d(5) ......... https://man7.org/linux/man-pages/man5/modprobe.d.5.html
#   systemd.exec(5) ....... https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
#   systemd-analyze(1) .... https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
#   GRUB manual, Security . https://www.gnu.org/software/grub/manual/grub/grub.html#Security
# =============================================================================

set -euo pipefail

VERSION="1.0.0"
LAB_ID="lpic3-303-332.1"
STATE_DIR="/var/lib/${LAB_ID}-breakfix"
LOG_FILE="${STATE_DIR}/lab.log"

# Lab-only accounts. Disposable VM credentials — never reuse these anywhere.
LAB_USER_LIMITS="hardlab"
LAB_USER_PAM="pamlab"
LAB_PASSWORD='L4b-Pass!332'

ASSUME_YES=0
FORCE=0

SCENARIOS=(sysctl limits mounts accounts unit modules boot)

declare -A SCEN_TITLE=(
  [sysctl]="Kernel parameters: a vendor drop-in shadows the CIS baseline, ASLR is off"
  [limits]="pam_limits: a service account cannot fork or open files"
  [mounts]="Mount options: /tmp is noexec and the reporting tool stopped working"
  [accounts]="Accounts and PAM: expired/locked account behind a pam_wheel su policy"
  [unit]="systemd sandboxing: ProtectSystem=strict with no writable state"
  [modules]="Kernel modules: a blacklist that does not block anything"
  [boot]="Bootloader: a GRUB superuser stanza that protects nothing"
)

declare -A SCEN_NEEDS_VM=(
  [sysctl]=1 [limits]=0 [mounts]=1 [accounts]=0 [unit]=1 [modules]=1 [boot]=1
)

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'
  BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; BLU=""; BLD=""; RST=""
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%b[*]%b %s\n' "$BLU" "$RST" "$*"; }
warn()  { printf '%b[!]%b %s\n' "$YEL" "$RST" "$*"; }
err()   { printf '%b[x]%b %s\n' "$RED" "$RST" "$*" >&2; }
head1() { printf '\n%b%s%b\n' "$BLD" "$*" "$RST"; }
rule()  { printf '%s\n' "-----------------------------------------------------------------------"; }

audit() {
  mkdir -p "$STATE_DIR"
  printf '%s  %s\n' "$(date -Is)" "$*" >>"$LOG_FILE"
}

PASSED=0; FAILED=0; SKIPPED=0

assert() {
  local desc="$1"; shift
  local code="$*"
  if eval "$code" >/dev/null 2>&1; then
    printf '  %b[ PASS ]%b %s\n' "$GRN" "$RST" "$desc"
    PASSED=$((PASSED + 1))
  else
    printf '  %b[ FAIL ]%b %s\n' "$RED" "$RST" "$desc"
    FAILED=$((FAILED + 1))
  fi
}

skip_check() {
  printf '  %b[ SKIP ]%b %s\n' "$YEL" "$RST" "$1"
  SKIPPED=$((SKIPPED + 1))
}

# ----------------------------------------------------------------------------
# Distribution facts
# ----------------------------------------------------------------------------
OS_ID="unknown"; OS_LIKE=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"
fi

admin_group() {
  if getent group wheel >/dev/null 2>&1; then say wheel
  elif getent group sudo >/dev/null 2>&1; then say sudo
  else say wheel; fi
}

grub_mkconfig_bin() {
  command -v grub2-mkconfig 2>/dev/null || command -v grub-mkconfig 2>/dev/null || true
}

grub_cfg_path() {
  local p
  for p in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
    [[ -f "$p" ]] && { say "$p"; return 0; }
  done
  say ""
}

# ----------------------------------------------------------------------------
# Backup / restore plumbing
# ----------------------------------------------------------------------------
scen_dir()     { say "${STATE_DIR}/$1"; }
scen_tree()    { say "${STATE_DIR}/$1/tree"; }
scen_created() { say "${STATE_DIR}/$1/created.list"; }
scen_state()   { say "${STATE_DIR}/$1/state.env"; }

scen_init() {
  local id="$1"
  mkdir -p "$(scen_tree "$id")"
  : >>"$(scen_created "$id")"
  : >>"$(scen_state "$id")"
}

# Back up an existing file, or record it as "created by the lab" if absent.
backup_file() {
  local id="$1" path="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a --parents "$path" "$(scen_tree "$id")/"
    audit "backup ${id} ${path}"
  else
    grep -qxF -- "$path" "$(scen_created "$id")" 2>/dev/null || printf '%s\n' "$path" >>"$(scen_created "$id")"
    audit "will-create ${id} ${path}"
  fi
}

remember() { # remember <id> KEY VALUE
  local id="$1" key="$2"; shift 2
  printf '%s=%q\n' "$key" "$*" >>"$(scen_state "$id")"
}

recall() { # recall <id> KEY  -> value on stdout
  local id="$1" key="$2" line val=""
  [[ -r "$(scen_state "$id")" ]] || { say ""; return 0; }
  while IFS= read -r line; do
    [[ "$line" == "${key}="* ]] || continue
    val="${line#*=}"
    eval "val=${val}"
  done <"$(scen_state "$id")"
  say "$val"
}

is_broken() { [[ -f "${STATE_DIR}/$1/BROKEN" ]]; }
mark_broken()  { mkdir -p "$(scen_dir "$1")"; : >"${STATE_DIR}/$1/BROKEN"; }
clear_broken() { rm -f "${STATE_DIR}/$1/BROKEN"; }

restore_files() {
  local id="$1" tree created f rel
  tree="$(scen_tree "$id")"; created="$(scen_created "$id")"

  if [[ -r "$created" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      [[ -e "$f" || -L "$f" ]] && rm -rf -- "$f" && audit "removed ${id} ${f}"
    done <"$created"
  fi

  if [[ -d "$tree" ]]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$tree"}"
      install -d "$(dirname "$rel")"
      cp -a "$f" "$rel"
      audit "restored ${id} ${rel}"
    done < <(find "$tree" \( -type f -o -type l \) -print0)
  fi
}

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "This lab rewires PAM, mounts, sysctl and systemd. Run it as root."
    exit 1
  fi
}

preflight() {
  require_root
  mkdir -p "$STATE_DIR"; chmod 0700 "$STATE_DIR"

  local virt="unknown"
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"

  if [[ "$virt" == "none" && ! -e /etc/teach-plat-lab && ${FORCE} -eq 0 ]]; then
    err "This host does not look like a lab VM (systemd-detect-virt: none)."
    err "Create /etc/teach-plat-lab to declare it disposable, or pass --force."
    exit 1
  fi

  local users
  users="$(who 2>/dev/null | awk '{print $1}' | sort -u | wc -l || echo 0)"
  if [[ "$users" -gt 1 ]]; then
    warn "More than one user is logged in. This lab locks accounts and remounts /tmp."
  fi

  warn "Take a VM snapshot before continuing. 'restore' is best effort, a snapshot is not."
}

confirm() {
  local phrase="BREAK MY LAB" answer=""
  [[ ${ASSUME_YES} -eq 1 ]] && return 0
  [[ "${LAB_ASSUME_YES:-0}" == "1" ]] && return 0
  printf '\n%bType exactly "%s" to proceed:%b ' "$BLD" "$phrase" "$RST"
  IFS= read -r answer || true
  if [[ "$answer" != "$phrase" ]]; then
    err "Not confirmed. Nothing was changed."
    exit 1
  fi
}

scenario_available() { # scenario_available <id> -> 0 usable, 1 skip (reason on stdout)
  local id="$1" ctr
  ctr="$(systemd-detect-virt -c 2>/dev/null || echo none)"
  if [[ "${SCEN_NEEDS_VM[$id]}" -eq 1 && "$ctr" != "none" ]]; then
    say "container detected (${ctr}): needs a real kernel namespace / bootloader"
    return 1
  fi
  case "$id" in
    modules)
      command -v modprobe >/dev/null 2>&1 || { say "modprobe not available"; return 1; }
      modinfo usb_storage >/dev/null 2>&1 || { say "usb_storage module not present in this kernel"; return 1; }
      if usb_disk_in_use; then say "a USB disk is currently mounted, refusing to touch usb-storage"; return 1; fi
      ;;
    boot)
      [[ -n "$(grub_mkconfig_bin)" ]] || { say "grub-mkconfig/grub2-mkconfig not installed"; return 1; }
      [[ -d /etc/grub.d ]] || { say "/etc/grub.d does not exist"; return 1; }
      ;;
    unit)
      command -v systemctl >/dev/null 2>&1 || { say "systemd not available"; return 1; }
      ;;
  esac
  return 0
}

usb_disk_in_use() {
  local name mp
  while read -r name tran; do
    [[ "$tran" == "usb" ]] || continue
    mp="$(lsblk -no MOUNTPOINTS "/dev/${name}" 2>/dev/null | tr -d ' \n')"
    [[ -n "$mp" ]] && return 0
  done < <(lsblk -S -no NAME,TRAN 2>/dev/null || true)
  return 1
}

ensure_lab_user() { # ensure_lab_user <name>
  local u="$1"
  if ! id -u "$u" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "LPIC-3 332.1 lab account" "$u"
    printf '%s:%s\n' "$u" "$LAB_PASSWORD" | chpasswd
    audit "created lab user ${u}"
    warn "Lab account '${u}' created with a well-known password. Disposable VM only."
  fi
}

briefing() { # briefing <id> <symptom> <objective>
  local id="$1" symptom="$2" objective="$3"
  rule
  printf '%bSCENARIO: %s%b\n' "$BLD" "$id" "$RST"
  printf '%s\n' "${SCEN_TITLE[$id]}"
  rule
  printf '%bSYMPTOM — what you are going to see%b\n%s\n\n' "$BLD" "$RST" "$symptom"
  printf '%bOBJECTIVE — what you must achieve%b\n%s\n' "$BLD" "$RST" "$objective"
  rule
  printf 'Check your work with:  %s verify %s\n\n' "$0" "$id"
}

# =============================================================================
# SCENARIO 1 — sysctl: a 99- drop-in shadows the baseline and disables ASLR
# =============================================================================
break_sysctl() {
  local id=sysctl
  scen_init "$id"

  remember "$id" ORIG_ASLR      "$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo 2)"
  remember "$id" ORIG_SUIDDUMP  "$(sysctl -n fs.suid_dumpable 2>/dev/null || echo 0)"
  remember "$id" ORIG_DMESG     "$(sysctl -n kernel.dmesg_restrict 2>/dev/null || echo 1)"
  remember "$id" ORIG_KPTR      "$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo 1)"

  backup_file "$id" /etc/sysctl.d/10-cis-hardening.conf
  backup_file "$id" /etc/sysctl.d/99-zz-vendor-compat.conf

  cat >/etc/sysctl.d/10-cis-hardening.conf <<'EOF'
# Site security baseline - reviewed and signed off by the security team.
# LPIC-3 303 topic 332.1 lab. Do not remove.
kernel.randomize_va_space = 2
fs.suid_dumpable          = 0
kernel.dmesg_restrict     = 1
kernel.kptr_restrict      = 1
EOF

  cat >/etc/sysctl.d/99-zz-vendor-compat.conf <<'EOF'
# Installed by "acme-legacy-agent" during an upgrade.
# The vendor support note said: "required for the profiler to resolve symbols".
kernel.randomize_va_space = 0
fs.suid_dumpable          = 2
kernel.dmesg_restrict     = 0
kernel.kptr_restrict      = 0
EOF

  sysctl --system >/dev/null 2>&1 || true
  mark_broken "$id"

  briefing "$id" \
"Your baseline file /etc/sysctl.d/10-cis-hardening.conf says ASLR is on, yet
the running kernel disagrees. Reproduce it:

    sysctl -n kernel.randomize_va_space          # prints 0, not 2
    for i in 1 2 3; do awk '/\\[stack\\]/{print \$1}' /proc/self/maps; done

The three stack ranges are IDENTICAL. Address space layout randomization is
off, so every exploit gets fixed addresses for free. On top of that,
fs.suid_dumpable=2 lets set-UID programs write core dumps (credential
material on disk), and kptr_restrict=0 leaks kernel pointers via
/proc/kallsyms to unprivileged users." \
"1. Explain WHY the baseline lost, in terms of sysctl.d(5) precedence: all of
   /usr/lib/sysctl.d, /run/sysctl.d and /etc/sysctl.d are merged and applied
   in lexicographic order of FILE NAME across directories, last setting wins.
   On systemd distributions /etc/sysctl.conf itself participates through the
   compatibility symlink /usr/lib/sysctl.d/99-sysctl.conf.
2. Make the baseline win persistently, without deleting the audit trail of
   what the vendor asked for.
3. After a full 'sysctl --system' the running kernel must report:
       kernel.randomize_va_space = 2
       fs.suid_dumpable          = 0
       kernel.dmesg_restrict     = 1
       kernel.kptr_restrict      >= 1
4. No file anywhere under /usr/lib/sysctl.d, /run/sysctl.d, /etc/sysctl.d or
   /etc/sysctl.conf may still set randomize_va_space to 0 or 1."
}

verify_sysctl() {
  head1 "verify: sysctl"
  sysctl --system >/dev/null 2>&1 || true
  assert "ASLR fully enabled (kernel.randomize_va_space = 2)" \
    '[[ "$(sysctl -n kernel.randomize_va_space)" == "2" ]]'
  assert "set-UID core dumps disabled (fs.suid_dumpable = 0)" \
    '[[ "$(sysctl -n fs.suid_dumpable)" == "0" ]]'
  assert "dmesg restricted to privileged users (kernel.dmesg_restrict = 1)" \
    '[[ "$(sysctl -n kernel.dmesg_restrict)" == "1" ]]'
  assert "kernel pointers hidden (kernel.kptr_restrict >= 1)" \
    '[[ "$(sysctl -n kernel.kptr_restrict)" -ge 1 ]]'
  assert "no config file re-disables ASLR on the next boot" \
    '! grep -RhsE "^[[:space:]]*kernel\.randomize_va_space[[:space:]]*=[[:space:]]*[01]([^0-9]|$)" \
        /etc/sysctl.conf /etc/sysctl.d /run/sysctl.d /usr/lib/sysctl.d 2>/dev/null | grep -q .'
  assert "the value survives a full reload from disk (persistence proven)" \
    'sysctl --system >/dev/null 2>&1; [[ "$(cat /proc/sys/kernel/randomize_va_space)" == "2" ]]'
}

hint_sysctl() {
  cat <<'EOF'
  systemd-analyze cat-config sysctl.d | less     # the merged, final view
  sysctl --system                                # prints every file, in order
  grep -Rn randomize_va_space /etc/sysctl.conf /etc/sysctl.d /run/sysctl.d /usr/lib/sysctl.d
  ls -l /usr/lib/sysctl.d/99-sysctl.conf         # the /etc/sysctl.conf compat symlink
  man 5 sysctl.d                                 # read the PRECEDENCE section
EOF
}

restore_sysctl() {
  restore_files sysctl
  sysctl --system >/dev/null 2>&1 || true
  sysctl -qw "kernel.randomize_va_space=$(recall sysctl ORIG_ASLR)"     2>/dev/null || true
  sysctl -qw "fs.suid_dumpable=$(recall sysctl ORIG_SUIDDUMP)"          2>/dev/null || true
  sysctl -qw "kernel.dmesg_restrict=$(recall sysctl ORIG_DMESG)"        2>/dev/null || true
  sysctl -qw "kernel.kptr_restrict=$(recall sysctl ORIG_KPTR)"          2>/dev/null || true
}

# =============================================================================
# SCENARIO 2 — pam_limits: a service account that cannot work
# =============================================================================
break_limits() {
  local id=limits
  scen_init "$id"
  ensure_lab_user "$LAB_USER_LIMITS"

  backup_file "$id" /etc/security/limits.conf
  backup_file "$id" "/etc/security/limits.d/99-lab-hardening.conf"
  install -d -m 0755 /etc/security/limits.d

  cat >"/etc/security/limits.d/99-lab-hardening.conf" <<EOF
# "Hardening" applied by a junior admin after reading a fork-bomb article.
# LPIC-3 303 topic 332.1 lab.
${LAB_USER_LIMITS}   soft   nproc     12
${LAB_USER_LIMITS}   hard   nproc     12
${LAB_USER_LIMITS}   soft   nofile    32
${LAB_USER_LIMITS}   hard   nofile    32
*                    hard   core      unlimited
EOF

  mark_broken "$id"

  briefing "$id" \
"The batch account '${LAB_USER_LIMITS}' can log in but cannot do any work.
Reproduce it as root:

    su -s /bin/bash - ${LAB_USER_LIMITS} -c 'ulimit -Hn; ulimit -Hu'
    su -s /bin/bash - ${LAB_USER_LIMITS} -c 'for i in \$(seq 1 40); do sleep 5 & done; wait'

You get 'fork: retry: Resource temporarily unavailable' and, in longer runs,
'Too many open files'. Note that root is unaffected, and that a plain
'ulimit -a' typed by root tells you nothing about this user.

A second, quieter problem: core dumps were just made unlimited for EVERY
account, which combined with a set-UID binary is a credential disclosure." \
"1. Diagnose through PAM, not by guessing: limits are applied by pam_limits.so
   at session setup, so they only appear in a session opened THROUGH PAM.
2. Restore the account to a workable state while keeping a real ceiling:
       hard nproc  >= 200   and NOT unlimited
       hard nofile >= 1024  and NOT unlimited
3. Disable core dumps properly for all users: 'hard core 0'.
4. pam_limits.so must still be in the session stack — do not fix this by
   removing the module."
}

_ulimit_as() { # _ulimit_as <user> <ulimit-flag>
  LC_ALL=C su -s /bin/bash - "$1" -c "ulimit $2" 2>/dev/null | tr -d '[:space:]'
}

verify_limits() {
  head1 "verify: limits"
  local u="$LAB_USER_LIMITS" n p c

  if ! id -u "$u" >/dev/null 2>&1; then
    skip_check "lab account ${u} does not exist"
    return
  fi
  if ! su -s /bin/bash - "$u" -c true >/dev/null 2>&1; then
    skip_check "cannot open a session for ${u} (fix the 'accounts' scenario first)"
    return
  fi

  n="$(_ulimit_as "$u" -Hn)"; p="$(_ulimit_as "$u" -Hu)"; c="$(_ulimit_as "$u" -Hc)"

  assert "hard nofile is workable and bounded (>=1024, not unlimited): got '${n}'" \
    '[[ "'"$n"'" != "unlimited" && "'"$n"'" =~ ^[0-9]+$ && "'"$n"'" -ge 1024 ]]'
  assert "hard nproc is workable and bounded (>=200, not unlimited): got '${p}'" \
    '[[ "'"$p"'" != "unlimited" && "'"$p"'" =~ ^[0-9]+$ && "'"$p"'" -ge 200 ]]'
  assert "core dumps disabled (hard core = 0): got '${c}'" \
    '[[ "'"$c"'" == "0" ]]'
  assert "no limits file leaves core dumps unlimited" \
    '! grep -RhsE "^[^#]*[[:space:]]core[[:space:]]+unlimited" /etc/security/limits.conf /etc/security/limits.d 2>/dev/null | grep -q .'
  assert "pam_limits.so is still enforced in the PAM stack" \
    'grep -Rqs "pam_limits\.so" /etc/pam.d/'
  assert "the account can actually fork 60 concurrent processes" \
    'su -s /bin/bash - '"$u"' -c "for i in \$(seq 1 60); do sleep 2 & done; wait" 2>&1 | grep -qv "Resource temporarily"'
}

hint_limits() {
  cat <<EOF
  su -s /bin/bash - ${LAB_USER_LIMITS} -c 'ulimit -a'      # limits as seen by the user
  grep -Rn "" /etc/security/limits.conf /etc/security/limits.d/
  grep -Rn pam_limits /etc/pam.d/                          # who applies them, and where
  man 5 limits.conf                                        # soft vs hard, %group, @group, *
  systemctl show -p DefaultLimitNOFILE                     # systemd services do NOT use PAM
EOF
}

restore_limits() { restore_files limits; }

# =============================================================================
# SCENARIO 3 — mount options: noexec on /tmp
# =============================================================================
TMP_MARK="lab-report-ok-332.1"

break_mounts() {
  local id=mounts
  scen_init "$id"

  local orig_opts fstype via
  orig_opts="$(findmnt -no OPTIONS /tmp 2>/dev/null || true)"
  fstype="$(findmnt -no FSTYPE /tmp 2>/dev/null || true)"

  if [[ "$fstype" == "tmpfs" ]] && systemctl is-active --quiet tmp.mount 2>/dev/null; then
    via="unit"
    backup_file "$id" /etc/systemd/system/tmp.mount.d/10-lab-hardening.conf
    install -d -m 0755 /etc/systemd/system/tmp.mount.d
    cat >/etc/systemd/system/tmp.mount.d/10-lab-hardening.conf <<'EOF'
# CIS 1.1.2 - /tmp must be nodev, nosuid, noexec.  LPIC-3 332.1 lab.
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,noexec
EOF
    systemctl daemon-reload
    mount -o remount,nosuid,nodev,noexec /tmp
  else
    via="bind"
    backup_file "$id" /etc/fstab
    if ! mountpoint -q /tmp; then
      mount --bind /tmp /tmp
      remember "$id" CREATED_BIND 1
    fi
    mount -o remount,bind,nosuid,nodev,noexec /tmp
    printf '%s\n' "/tmp  /tmp  none  rw,bind,nosuid,nodev,noexec,nofail  0 0" >>/etc/fstab
    if ! findmnt --verify --quiet >/dev/null 2>&1; then
      warn "findmnt --verify rejected the new /etc/fstab, rolling that part back"
      restore_files "$id"
    fi
  fi

  remember "$id" VIA "$via"
  remember "$id" ORIG_OPTS "$orig_opts"

  backup_file "$id" /tmp/lab-report.sh
  cat >/tmp/lab-report.sh <<EOF
#!/usr/bin/env bash
# Nightly reporting helper, historically dropped in /tmp by the ETL job.
printf '%s\n' "${TMP_MARK}"
EOF
  chmod 0755 /tmp/lab-report.sh

  mark_broken "$id"

  briefing "$id" \
"The nightly reporting helper stopped running after last night's CIS
remediation. Reproduce it:

    /tmp/lab-report.sh          -> bash: /tmp/lab-report.sh: Permission denied
    ls -l /tmp/lab-report.sh    -> -rwxr-xr-x  (the mode is fine!)
    bash /tmp/lab-report.sh     -> works, prints ${TMP_MARK}

The permission bits are correct and the file is readable, yet execve(2) is
refused while invoking the interpreter explicitly succeeds. That difference
is the whole lesson: noexec is enforced by the KERNEL at execve time on the
mount, it is not a file permission, and it does not stop an interpreter from
reading the script as data." \
"1. Prove the cause with findmnt, not with ls.
2. Keep the hardening. /tmp must remain nosuid, nodev and noexec, and it must
   stay that way across a reboot (persist it in /etc/fstab or in a tmp.mount
   drop-in, and validate the fstab with 'findmnt --verify').
3. Make the tool work again the correct way: relocate the executable to a
   filesystem that is meant to hold executables (/usr/local/bin), owned by
   root, mode 0755, so that running 'lab-report.sh' from PATH prints
   ${TMP_MARK}.
4. Remove the /tmp copy. Leaving a world-writable executable path in place is
   the reason /tmp is noexec to begin with."
}

verify_mounts() {
  head1 "verify: mounts"
  local opts
  opts="$(findmnt -no OPTIONS /tmp 2>/dev/null || echo '')"

  assert "/tmp is a separate mount point" 'mountpoint -q /tmp'
  assert "/tmp is noexec (options: ${opts:-none})" '[[ ",'"$opts"'," == *,noexec,* ]]'
  assert "/tmp is nosuid"                  '[[ ",'"$opts"'," == *,nosuid,* ]]'
  assert "/tmp is nodev"                   '[[ ",'"$opts"'," == *,nodev,* ]]'
  assert "the options are persistent (fstab entry or tmp.mount drop-in)" \
    'grep -Esq "^[^#]+[[:space:]]/tmp[[:space:]].*noexec" /etc/fstab || \
     grep -Rsq "noexec" /etc/systemd/system/tmp.mount.d/ /etc/systemd/system/tmp.mount 2>/dev/null'
  assert "/etc/fstab still parses cleanly (findmnt --verify)" \
    'findmnt --verify --quiet'
  assert "lab-report.sh resolves from PATH outside /tmp" \
    'p=$(command -v lab-report.sh) && [[ -n "$p" && "$p" != /tmp/* ]]'
  assert "lab-report.sh is root-owned and 0755" \
    'p=$(command -v lab-report.sh) && [[ "$(stat -c %U:%a "$p")" == "root:755" ]]'
  assert "lab-report.sh executes and prints the expected token" \
    '[[ "$(lab-report.sh 2>/dev/null)" == "'"$TMP_MARK"'" ]]'
  assert "the world-writable copy under /tmp is gone" '[[ ! -e /tmp/lab-report.sh ]]'
}

hint_mounts() {
  cat <<'EOF'
  findmnt /tmp                       # target, source, fstype and EFFECTIVE options
  findmnt -no OPTIONS /tmp
  mount | grep ' /tmp '
  strace -f -e trace=execve /tmp/lab-report.sh 2>&1 | tail -3   # EACCES from execve
  systemd-analyze cat-config systemd/system/tmp.mount           # if /tmp is a unit
  findmnt --verify --verbose         # ALWAYS run this before rebooting after an fstab edit
EOF
}

restore_mounts() {
  local via orig created_bind
  via="$(recall mounts VIA)"
  orig="$(recall mounts ORIG_OPTS)"
  created_bind="$(recall mounts CREATED_BIND)"

  restore_files mounts
  rm -f /etc/systemd/system/tmp.mount.d/10-lab-hardening.conf
  rmdir /etc/systemd/system/tmp.mount.d 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  if [[ -n "$orig" ]]; then
    mount -o "remount,${orig}" /tmp 2>/dev/null || \
      mount -o remount,exec,suid,dev /tmp 2>/dev/null || true
  fi
  if [[ "$via" == "bind" && "$created_bind" == "1" ]]; then
    umount /tmp 2>/dev/null || umount -l /tmp 2>/dev/null || true
  fi
  rm -f /usr/local/bin/lab-report.sh
}

# =============================================================================
# SCENARIO 4 — accounts, shadow aging, pam_wheel and login.defs
# =============================================================================
break_accounts() {
  local id=accounts
  scen_init "$id"
  ensure_lab_user "$LAB_USER_PAM"

  backup_file "$id" /etc/pam.d/su
  backup_file "$id" /etc/login.defs
  backup_file "$id" /etc/shadow

  # --- account state: expired and password-locked --------------------------
  chage -E "$(date -d 'yesterday' +%Y-%m-%d)" "$LAB_USER_PAM"
  chage -M 99999 -m 0 -W 0 "$LAB_USER_PAM"
  passwd -l "$LAB_USER_PAM" >/dev/null 2>&1 || true

  # --- su restricted to the admin group, target user is not a member -------
  local ag; ag="$(admin_group)"
  if grep -Eq '^[[:space:]]*#[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so' /etc/pam.d/su; then
    sed -i -E 's/^[[:space:]]*#[[:space:]]*(auth[[:space:]]+required[[:space:]]+pam_wheel\.so.*)$/\1/' /etc/pam.d/su
  elif ! grep -Eq '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so' /etc/pam.d/su; then
    if grep -q 'pam_rootok\.so' /etc/pam.d/su; then
      sed -i "0,/pam_rootok\.so/s//pam_rootok.so\nauth\t\trequired\tpam_wheel.so use_uid group=${ag}/" /etc/pam.d/su
    else
      sed -i "1i auth\t\tsufficient\tpam_rootok.so\nauth\t\trequired\tpam_wheel.so use_uid group=${ag}" /etc/pam.d/su
    fi
  fi

  # Guard: root must still be able to su. pam_rootok.so is evaluated first.
  if ! su -s /bin/bash - root -c true >/dev/null 2>&1; then
    err "The /etc/pam.d/su edit broke root's own su. Rolling it back automatically."
    cp -a "$(scen_tree "$id")/etc/pam.d/su" /etc/pam.d/su
  fi

  # --- login.defs weakened --------------------------------------------------
  _set_login_def UMASK 000
  _set_login_def PASS_MAX_DAYS 99999
  _set_login_def PASS_MIN_DAYS 0
  _set_login_def PASS_WARN_AGE 0
  _set_login_def ENCRYPT_METHOD MD5

  mark_broken "$id"

  briefing "$id" \
"Three failures stacked on one host.

(a) The service account '${LAB_USER_PAM}' cannot log in at all:
        su -s /bin/bash - ${LAB_USER_PAM} -c id      (as root: works)
        on tty/ssh the user gets: 'Your account has expired; please contact
        your system administrator' and, before that, an authentication
        failure, because the password hash was also locked with a '!' prefix.
        Inspect the raw truth:   getent shadow ${LAB_USER_PAM}

(b) Any non-privileged user now gets 'su: Permission denied' when running
    'su -', even with the correct root password. Root itself is unaffected,
    because pam_rootok.so is evaluated first in /etc/pam.d/su.

(c) New files are being created world-writable and passwords never expire:
        grep -E '^(UMASK|PASS_|ENCRYPT_METHOD)' /etc/login.defs
        su -s /bin/bash - ${LAB_USER_PAM} -c 'umask; touch /tmp/x; ls -l /tmp/x'" \
"1. Bring '${LAB_USER_PAM}' back to a usable state WITHOUT deleting or
   recreating the account: usable password hash, no account expiry.
2. Apply a real aging policy to that account:
       PASS_MAX_DAYS 90, PASS_MIN_DAYS >= 1, PASS_WARN_AGE 7.
   Verify with 'chage -l' and with the raw fields of getent shadow.
3. KEEP the su restriction — it is the correct control. Make it usable by
   putting the intended administrators in the admin group (${ag}) and confirm
   the group is not empty. Removing the pam_wheel line is a FAIL.
4. Fix the defaults for every future account:
       UMASK 027, PASS_MAX_DAYS 90, PASS_MIN_DAYS 1, PASS_WARN_AGE 7,
       ENCRYPT_METHOD SHA512 (or yescrypt).
   Explain why fixing login.defs does NOT retroactively fix existing users."
}

_set_login_def() { # _set_login_def KEY VALUE
  local k="$1" v="$2"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${k}[[:space:]]" /etc/login.defs; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${k}[[:space:]].*|${k}\t${v}|" /etc/login.defs
  else
    printf '%s\t%s\n' "$k" "$v" >>/etc/login.defs
  fi
}

_shadow_field() { # _shadow_field <user> <n>
  getent shadow "$1" 2>/dev/null | awk -F: -v n="$2" '{print $n}'
}

_login_def() { # _login_def KEY
  awk -v k="$1" '$1==k {print $2; exit}' /etc/login.defs 2>/dev/null
}

verify_accounts() {
  head1 "verify: accounts"
  local u="$LAB_USER_PAM" ag; ag="$(admin_group)"

  if ! id -u "$u" >/dev/null 2>&1; then
    skip_check "lab account ${u} does not exist"
    return
  fi

  assert "password hash is usable (not locked with '!' and not empty)" \
    'h=$(_shadow_field '"$u"' 2); [[ -n "$h" && "$h" != "!"* && "$h" != "*" && "$h" != "!!" ]]'
  assert "account has no expiry date (shadow field 8 empty)" \
    '[[ -z "$(_shadow_field '"$u"' 8)" ]]'
  assert "PASS_MAX_DAYS on the account is 90" \
    '[[ "$(_shadow_field '"$u"' 5)" == "90" ]]'
  assert "PASS_MIN_DAYS on the account is >= 1" \
    'v=$(_shadow_field '"$u"' 4); [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 ]]'
  assert "PASS_WARN_AGE on the account is 7" \
    '[[ "$(_shadow_field '"$u"' 6)" == "7" ]]'
  assert "a session can actually be opened for ${u}" \
    'su -s /bin/bash - '"$u"' -c true'
  assert "su is STILL restricted by pam_wheel (control kept, not removed)" \
    'grep -Eq "^[[:space:]]*auth[[:space:]]+(required|requisite)[[:space:]]+pam_wheel\.so" /etc/pam.d/su'
  assert "pam_wheel uses use_uid (checks the real, not the effective, uid)" \
    'grep -Eq "^[[:space:]]*auth[[:space:]]+(required|requisite)[[:space:]]+pam_wheel\.so.*use_uid" /etc/pam.d/su'
  assert "the admin group '${ag}' has at least one member" \
    'm=$(getent group '"$ag"' | cut -d: -f4); [[ -n "$m" ]]'
  assert "root can still su (pam_rootok.so path intact)" \
    'su -s /bin/bash - root -c true'
  assert "login.defs UMASK is 027" '[[ "$(_login_def UMASK)" == "027" ]]'
  assert "login.defs PASS_MAX_DAYS is 90" '[[ "$(_login_def PASS_MAX_DAYS)" == "90" ]]'
  assert "login.defs PASS_MIN_DAYS is >= 1" \
    'v=$(_login_def PASS_MIN_DAYS); [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 ]]'
  assert "login.defs PASS_WARN_AGE is 7" '[[ "$(_login_def PASS_WARN_AGE)" == "7" ]]'
  assert "login.defs ENCRYPT_METHOD is SHA512 or yescrypt" \
    'v=$(_login_def ENCRYPT_METHOD); [[ "$v" == "SHA512" || "$v" == "yescrypt" ]]'
}

hint_accounts() {
  cat <<EOF
  getent shadow ${LAB_USER_PAM}        # fields: name:hash:lastchg:min:max:warn:inactive:expire:
  chage -l ${LAB_USER_PAM}             # the same thing, human readable
  passwd -S ${LAB_USER_PAM}            # P = usable, L = locked, NP = no password
  cat /etc/pam.d/su                    # read it top to bottom: rootok, then wheel
  man 8 pam_wheel                      # use_uid, group=, trust, deny, root_only
  getent group $(admin_group)
  grep -E '^(UMASK|PASS_|ENCRYPT_METHOD|CREATE_HOME)' /etc/login.defs
  journalctl -t su -t sshd --since '-10 min'    # PAM tells you exactly which module denied
EOF
}

restore_accounts() {
  restore_files accounts
  if id -u "$LAB_USER_PAM" >/dev/null 2>&1; then
    chage -E -1 -M 99999 -m 0 -W 7 "$LAB_USER_PAM" 2>/dev/null || true
    printf '%s:%s\n' "$LAB_USER_PAM" "$LAB_PASSWORD" | chpasswd 2>/dev/null || true
  fi
}

# =============================================================================
# SCENARIO 5 — systemd unit sandboxing without writable state
# =============================================================================
UNIT_NAME="hardening-lab.service"
UNIT_TOKEN="agent-state-332.1"

break_unit() {
  local id=unit
  scen_init "$id"

  backup_file "$id" /usr/local/libexec/hardening-lab-agent
  backup_file "$id" "/etc/systemd/system/${UNIT_NAME}"
  backup_file "$id" "/etc/systemd/system/${UNIT_NAME}.d/10-sandbox.conf"

  install -d -m 0755 /usr/local/libexec /var/lib/hardening-lab /var/log/hardening-lab
  remember "$id" MADE_DIRS 1

  cat >/usr/local/libexec/hardening-lab-agent <<EOF
#!/usr/bin/env bash
# Minimal stand-in for a real agent: writes state and a log line, then exits.
set -euo pipefail
STATE_DIR="\${STATE_DIRECTORY:-/var/lib/hardening-lab}"
LOG_DIR="\${LOGS_DIRECTORY:-/var/log/hardening-lab}"
printf '%s %s\n' "\$(date -Is)" "${UNIT_TOKEN}" >"\${STATE_DIR}/state"
printf '%s agent run ok\n' "\$(date -Is)" >>"\${LOG_DIR}/agent.log"
EOF
  chmod 0755 /usr/local/libexec/hardening-lab-agent

  cat >"/etc/systemd/system/${UNIT_NAME}" <<'EOF'
[Unit]
Description=LPIC-3 332.1 lab agent
Documentation=https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/hardening-lab-agent

[Install]
WantedBy=multi-user.target
EOF

  install -d -m 0755 "/etc/systemd/system/${UNIT_NAME}.d"
  cat >"/etc/systemd/system/${UNIT_NAME}.d/10-sandbox.conf" <<'EOF'
# Sandbox drop-in pushed by the platform team to lower the exposure score.
# It was never tested against the agent's actual write paths.
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
RestrictAddressFamilies=AF_UNIX
SystemCallArchitectures=native
SystemCallFilter=@system-service
CapabilityBoundingSet=
EOF

  systemctl daemon-reload
  systemctl start "$UNIT_NAME" >/dev/null 2>&1 || true
  mark_broken "$id"

  briefing "$id" \
"${UNIT_NAME} fails on every start since the sandbox drop-in landed.
Reproduce it:

    systemctl status ${UNIT_NAME}
    journalctl -u ${UNIT_NAME} -n 20 --no-pager

You will see the agent abort with 'Read-only file system' on its own state
and log paths. The binary is intact, the permissions are 0755 root:root, and
running /usr/local/libexec/hardening-lab-agent by hand from a shell works
perfectly — which is exactly what makes this class of failure confusing.
The service is executing inside a mount namespace where ProtectSystem=strict
made the ENTIRE filesystem hierarchy read-only except /dev, /proc and /sys." \
"1. Read the effective, merged configuration with 'systemctl cat' and
   'systemd-analyze cat-config', and confirm the namespace theory with
   'systemd-analyze security ${UNIT_NAME}'.
2. Make the service start successfully (systemctl is-active -> active) and
   actually write its state file on every restart.
3. Do it WITHOUT weakening the sandbox. All of these must still be in effect
   on the running unit:
       ProtectSystem=strict, ProtectHome=yes, PrivateTmp=yes,
       NoNewPrivileges=yes
   The supported way to punch a hole is ReadWritePaths=, or better,
   StateDirectory=/LogsDirectory=, which create the directories with the
   right ownership and expose \$STATE_DIRECTORY / \$LOGS_DIRECTORY.
4. Keep the overall exposure level at or below 4.5."
}

_unit_prop() { systemctl show -p "$2" --value "$1" 2>/dev/null; }

verify_unit() {
  head1 "verify: unit"
  local before after exposure

  if ! systemctl cat "$UNIT_NAME" >/dev/null 2>&1; then
    skip_check "${UNIT_NAME} is not installed"
    return
  fi

  before="$(stat -c %Y /var/lib/hardening-lab/state 2>/dev/null || echo 0)"
  sleep 1
  systemctl restart "$UNIT_NAME" >/dev/null 2>&1 || true
  after="$(stat -c %Y /var/lib/hardening-lab/state 2>/dev/null || echo 0)"

  assert "the unit is active after a restart" \
    '[[ "$(systemctl is-active '"$UNIT_NAME"')" == "active" ]]'
  assert "the unit has no failed result" \
    '[[ "$(_unit_prop '"$UNIT_NAME"' Result)" == "success" ]]'
  assert "the agent wrote its state file during this restart" \
    '[[ "'"$after"'" -gt "'"$before"'" ]]'
  assert "the state file carries the expected token" \
    'grep -q "'"$UNIT_TOKEN"'" /var/lib/hardening-lab/state'
  assert "ProtectSystem is still strict" \
    '[[ "$(_unit_prop '"$UNIT_NAME"' ProtectSystem)" == "strict" ]]'
  assert "ProtectHome is still enabled" \
    'v=$(_unit_prop '"$UNIT_NAME"' ProtectHome); [[ "$v" == "yes" || "$v" == "tmpfs" || "$v" == "read-only" ]]'
  assert "PrivateTmp is still enabled" \
    '[[ "$(_unit_prop '"$UNIT_NAME"' PrivateTmp)" == "yes" ]]'
  assert "NoNewPrivileges is still enabled" \
    '[[ "$(_unit_prop '"$UNIT_NAME"' NoNewPrivileges)" == "yes" ]]'
  assert "the fix uses a supported write path (ReadWritePaths / StateDirectory / LogsDirectory)" \
    'systemctl cat '"$UNIT_NAME"' | grep -Eq "^(ReadWritePaths|StateDirectory|LogsDirectory)="'

  if command -v systemd-analyze >/dev/null 2>&1; then
    exposure="$(systemd-analyze security --no-pager "$UNIT_NAME" 2>/dev/null \
                | grep -i 'Overall exposure level' | grep -oE '[0-9]+\.[0-9]+' | tail -1)"
    if [[ -n "$exposure" ]]; then
      assert "overall exposure level ${exposure} is <= 4.5" \
        'awk "BEGIN{exit !('"$exposure"' <= 4.5)}"'
    else
      skip_check "could not parse the exposure level from systemd-analyze security"
    fi
  else
    skip_check "systemd-analyze is not available"
  fi
}

hint_unit() {
  cat <<EOF
  systemctl status ${UNIT_NAME}
  journalctl -u ${UNIT_NAME} -n 30 --no-pager -o short-precise
  systemctl cat ${UNIT_NAME}                       # unit + every drop-in, in order
  systemctl show ${UNIT_NAME} | grep -E 'Protect|Private|ReadWrite|NoNewPriv'
  systemd-analyze security ${UNIT_NAME}            # per-directive exposure scoring
  systemd-run -p ProtectSystem=strict --pty ls -l /var/log    # reproduce the namespace by hand
  man 5 systemd.exec                               # ReadWritePaths, StateDirectory, LogsDirectory
  # Exit code 226/NAMESPACE means the namespace setup itself failed, not your program.
EOF
}

restore_unit() {
  systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
  systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  restore_files unit
  rm -rf "/etc/systemd/system/${UNIT_NAME}.d"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
  if [[ "$(recall unit MADE_DIRS)" == "1" ]]; then
    rm -rf /var/lib/hardening-lab /var/log/hardening-lab
  fi
}

# =============================================================================
# SCENARIO 6 — a module blacklist that blacklists nothing
# =============================================================================
break_modules() {
  local id=modules
  scen_init "$id"

  remember "$id" WAS_LOADED "$(lsmod | awk '$1=="usb_storage"{print 1}' | head -1)"
  backup_file "$id" /etc/modprobe.d/lab-usb.blacklist
  backup_file "$id" /etc/modprobe.d/99-lab-usb.conf

  # Deliberately wrong extension: modprobe.d(5) only reads *.conf
  cat >/etc/modprobe.d/lab-usb.blacklist <<'EOF'
# "USB mass storage disabled per data-loss-prevention policy."
# Ticket SEC-4471, closed as done. LPIC-3 332.1 lab.
blacklist usb-storage
EOF

  modprobe usb_storage >/dev/null 2>&1 || true
  mark_broken "$id"

  briefing "$id" \
"The DLP ticket says USB mass storage is disabled on this host. The auditor
disagrees. Reproduce both halves of the failure:

    ls /etc/modprobe.d/
    modprobe -n -v usb-storage      # still prints 'insmod .../usb-storage.ko*'
    lsmod | grep usb_storage        # the module is loaded RIGHT NOW
    plug in a USB stick             # it appears as /dev/sdX and mounts

Two independent bugs are stacked here, and both are classic exam material:
  (a) modprobe.d(5) only parses files whose name ends in '.conf'. The policy
      file is named lab-usb.blacklist, so it was never read at all.
  (b) even with the right extension, 'blacklist' only prevents AUTOMATIC
      loading by udev/kmod on device or alias matching. It does not stop an
      explicit 'modprobe usb-storage', it does not stop loading as a
      dependency of another module, and it does nothing about a module that
      is already resident in the running kernel." \
"1. Make the control genuinely effective:
       modprobe -n -v usb-storage   must resolve to 'install /bin/true'
                                    (or /bin/false)
       lsmod                        must not list usb_storage
2. Put the configuration in a file that modprobe actually reads:
   /etc/modprobe.d/<name>.conf
3. Remove or rename the misleading file so the next auditor is not fooled.
4. Understand, and be able to explain, what still remains to do in production:
   the module may be present in the initramfs (dracut/update-initramfs), and
   a hard guarantee needs either CONFIG_MODULE_SIG_FORCE plus
   kernel.modules_disabled=1, or a kernel built without the driver."
}

verify_modules() {
  head1 "verify: modules"
  assert "modprobe resolves usb-storage to an install override" \
    'modprobe -n -v usb-storage 2>&1 | grep -Eq "install[[:space:]]+(/usr)?/bin/(true|false)"'
  assert "usb_storage is not loaded in the running kernel" \
    '! lsmod | awk "\$1==\"usb_storage\"{found=1} END{exit !found}"'
  assert "the policy lives in a file modprobe actually reads (*.conf)" \
    'grep -lsE "^[[:space:]]*install[[:space:]]+usb[-_]storage" /etc/modprobe.d/*.conf | grep -q .'
  assert "a blacklist line is present as well (defence in depth)" \
    'grep -hsqE "^[[:space:]]*blacklist[[:space:]]+usb[-_]storage" /etc/modprobe.d/*.conf'
  assert "the misleadingly named non-.conf file is gone" \
    '[[ ! -e /etc/modprobe.d/lab-usb.blacklist ]]'
}

hint_modules() {
  cat <<'EOF'
  man 5 modprobe.d                 # "files ... with the .conf extension" + blacklist vs install
  modprobe -n -v usb-storage       # dry run: shows EXACTLY what modprobe would do
  modprobe -c | grep -i usb-storage
  lsmod | grep usb_storage         # third column = use count; non-zero means in use
  modprobe -r usb_storage          # fails if the module is in use
  lsblk -S -o NAME,TRAN            # never unload usb-storage if you booted from USB
  lsinitrd 2>/dev/null | grep -i usb-storage   # Fedora/RHEL: is it still in the initramfs?
EOF
}

restore_modules() {
  restore_files modules
  rm -f /etc/modprobe.d/99-lab-usb.conf /etc/modprobe.d/lab-usb.blacklist
  if [[ "$(recall modules WAS_LOADED)" != "1" ]] && ! usb_disk_in_use; then
    modprobe -r usb_storage >/dev/null 2>&1 || true
  fi
}

# =============================================================================
# SCENARIO 7 — GRUB superuser stanza that protects nothing (offline verified)
# =============================================================================
GRUB_SNIPPET="/etc/grub.d/01_lab_superuser"

break_boot() {
  local id=boot
  scen_init "$id"

  local mk cfg scratch
  mk="$(grub_mkconfig_bin)"
  cfg="$(grub_cfg_path)"
  scratch="${STATE_DIR}/boot/grub.scratch.cfg"
  install -d -m 0700 "${STATE_DIR}/boot"

  remember "$id" MKCONFIG "$mk"
  remember "$id" REAL_CFG "$cfg"
  remember "$id" SCRATCH "$scratch"
  if [[ -n "$cfg" ]]; then
    remember "$id" REAL_CFG_SUM "$(sha256sum "$cfg" | awk '{print $1}')"
  fi

  backup_file "$id" "$GRUB_SNIPPET"

  cat >"$GRUB_SNIPPET" <<'EOF'
#!/bin/sh
# Bootloader password, per SEC-4472. LPIC-3 332.1 lab.
cat <<'GRUBEOF'
set superuser="labadmin"
password labadmin LabPass123
GRUBEOF
EOF
  chmod 0755 "$GRUB_SNIPPET"

  if ! "$mk" -o "$scratch" >/dev/null 2>&1; then
    warn "grub-mkconfig failed on this host, rolling back the boot scenario"
    restore_files "$id"
    return 1
  fi

  mark_broken "$id"

  briefing "$id" \
"A bootloader password was 'installed' and the ticket was closed. It protects
nothing. This scenario NEVER writes ${cfg:-your real grub.cfg}; everything is
verified against a scratch file, which is how you should do this in
production. Reproduce it:

    cat ${GRUB_SNIPPET}
    ${mk} -o ${scratch}
    grep -nE 'superuser|password' ${scratch}

Three defects:
  * 'set superuser=' is not a GRUB variable. The variable GRUB honours is
    'superusers' (plural). With it misspelled, GRUB has no superuser at all
    and therefore enforces nothing.
  * the password is stored in cleartext, in a file that is world readable,
    and it will be copied verbatim into grub.cfg.
  * because no superuser is defined, every menu entry stays fully editable:
    at the boot menu, 'e' then appending init=/bin/bash yields an
    unauthenticated root shell on the local console. A BIOS/UEFI password and
    a locked boot order are the other half of this control; a GRUB password
    alone does not stop booting from external media." \
"1. Rewrite ${GRUB_SNIPPET} so that the generated configuration contains:
       set superusers=\"labadmin\"
       password_pbkdf2 labadmin grub.pbkdf2.sha512.10000.<salt>.<hash>
   Generate the hash with 'grub2-mkpasswd-pbkdf2' (Debian/Ubuntu:
   'grub-mkpasswd-pbkdf2') and paste the full string it prints.
2. No cleartext 'password <user> <secret>' directive may remain.
3. The snippet must be executable and correctly ordered in /etc/grub.d.
4. Verify by regenerating into the SCRATCH file only:
       ${mk} -o ${scratch}
   ${cfg:-The real grub.cfg} must remain byte-for-byte unchanged; this lab
   checks its SHA-256.
5. Be ready to explain '--unrestricted' on menuentry lines: without it,
   booting the DEFAULT entry will also prompt for the password, which is
   usually not what you want on an unattended server."
}

verify_boot() {
  head1 "verify: boot"
  local mk scratch cfg sum now
  mk="$(recall boot MKCONFIG)"; scratch="$(recall boot SCRATCH)"
  cfg="$(recall boot REAL_CFG)"; sum="$(recall boot REAL_CFG_SUM)"

  if [[ -z "$mk" || ! -x "$mk" ]]; then
    skip_check "grub-mkconfig is not available"
    return
  fi

  assert "the snippet exists and is executable" '[[ -x "'"$GRUB_SNIPPET"'" ]]'
  assert "the snippet has a numeric ordering prefix in /etc/grub.d" \
    '[[ "$(basename "'"$GRUB_SNIPPET"'")" =~ ^[0-9]{2}_ ]]'

  if ! "$mk" -o "$scratch" >/dev/null 2>&1; then
    assert "grub-mkconfig regenerates a scratch configuration" 'false'
    return
  fi

  assert "generated config defines superusers (plural, the real variable)" \
    'grep -Eq "^[[:space:]]*set[[:space:]]+superusers=" "'"$scratch"'"'
  assert "the superuser is labadmin" \
    'grep -Eq "^[[:space:]]*set[[:space:]]+superusers=\"?labadmin\"?" "'"$scratch"'"'
  assert "a PBKDF2 hash is used (password_pbkdf2 + grub.pbkdf2.sha512.)" \
    'grep -Eq "^[[:space:]]*password_pbkdf2[[:space:]]+labadmin[[:space:]]+grub\.pbkdf2\.sha512\.[0-9]+\.[0-9A-Fa-f]+\.[0-9A-Fa-f]+" "'"$scratch"'"'
  assert "no cleartext 'password' directive remains" \
    '! grep -Eq "^[[:space:]]*password[[:space:]]+[^[:space:]]+[[:space:]]+" "'"$scratch"'"'
  assert "the misspelled 'set superuser=' is gone" \
    '! grep -Eq "^[[:space:]]*set[[:space:]]+superuser=" "'"$scratch"'"'

  if [[ -n "$cfg" && -n "$sum" && -f "$cfg" ]]; then
    now="$(sha256sum "$cfg" | awk '{print $1}')"
    assert "the real ${cfg} was NOT modified during the exercise" \
      '[[ "'"$now"'" == "'"$sum"'" ]]'
  else
    skip_check "no installed grub.cfg to compare against"
  fi
}

hint_boot() {
  cat <<EOF
  grub2-mkpasswd-pbkdf2      # Debian/Ubuntu: grub-mkpasswd-pbkdf2
  ls -l /etc/grub.d/         # execution order is lexicographic; only executables run
  $(grub_mkconfig_bin) -o ${STATE_DIR}/boot/grub.scratch.cfg   # NEVER straight to /boot first
  grep -nE 'superusers|password_pbkdf2|--unrestricted' ${STATE_DIR}/boot/grub.scratch.cfg
  # GRUB manual, Security: https://www.gnu.org/software/grub/manual/grub/grub.html#Security
  # Only after the scratch file is correct:
  #   cp -a /boot/grub2/grub.cfg /boot/grub2/grub.cfg.bak && grub2-mkconfig -o /boot/grub2/grub.cfg
EOF
}

restore_boot() {
  restore_files boot
  rm -f "$GRUB_SNIPPET"
}

# =============================================================================
# Dispatcher
# =============================================================================
valid_scenario() {
  local s
  for s in "${SCENARIOS[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

cmd_list() {
  head1 "LPIC-3 303 / 332.1 Host Hardening — break & fix scenarios"
  local s reason
  for s in "${SCENARIOS[@]}"; do
    if reason="$(scenario_available "$s")"; then
      printf '  %b%-9s%b %s\n' "$BLD" "$s" "$RST" "${SCEN_TITLE[$s]}"
    else
      printf '  %b%-9s%b %s  %b(unavailable: %s)%b\n' \
        "$BLD" "$s" "$RST" "${SCEN_TITLE[$s]}" "$YEL" "$reason" "$RST"
    fi
  done
  printf '\n  all / random are also accepted by "break".\n\n'
}

cmd_status() {
  head1 "lab status"
  local s
  for s in "${SCENARIOS[@]}"; do
    if is_broken "$s"; then
      printf '  %b%-9s BROKEN%b   backups: %s\n' "$RED" "$s" "$RST" "$(scen_dir "$s")"
    else
      printf '  %b%-9s clean%b\n' "$GRN" "$s" "$RST"
    fi
  done
  printf '\n  state directory: %s\n  audit log: %s\n\n' "$STATE_DIR" "$LOG_FILE"
}

cmd_break() {
  local target="${1:-}" s reason
  [[ -n "$target" ]] || { err "usage: $0 break <scenario|all|random>"; exit 2; }

  local -a list=()
  case "$target" in
    all)    list=("${SCENARIOS[@]}") ;;
    random) list=("${SCENARIOS[$((RANDOM % ${#SCENARIOS[@]}))]}") ;;
    *)      valid_scenario "$target" || { err "unknown scenario: ${target}"; cmd_list; exit 2; }
            list=("$target") ;;
  esac

  preflight
  head1 "About to deliberately misconfigure this host: ${list[*]}"
  confirm

  for s in "${list[@]}"; do
    if ! reason="$(scenario_available "$s")"; then
      warn "skipping '${s}': ${reason}"
      continue
    fi
    if is_broken "$s"; then
      warn "scenario '${s}' is already broken; skipping (run 'restore ${s}' first)"
      continue
    fi
    audit "break ${s}"
    "break_${s}" || warn "scenario '${s}' could not be applied on this host"
  done

  head1 "Ready."
  say "  Diagnose, fix, then run:  $0 verify ${target}"
  say "  Stuck?                    $0 hint <scenario>"
  say "  Emergency undo:           $0 restore ${target}"
  say "  Full solution:            tail -n 320 $0"
  say ""
}

cmd_verify() {
  local target="${1:-all}" s
  require_root
  local -a list=()
  if [[ "$target" == "all" ]]; then list=("${SCENARIOS[@]}")
  else valid_scenario "$target" || { err "unknown scenario: ${target}"; exit 2; }; list=("$target"); fi

  PASSED=0; FAILED=0; SKIPPED=0
  for s in "${list[@]}"; do
    if [[ "$target" == "all" ]] && ! is_broken "$s"; then continue; fi
    "verify_${s}"
  done

  rule
  printf 'passed: %b%d%b   failed: %b%d%b   skipped: %b%d%b\n' \
    "$GRN" "$PASSED" "$RST" "$RED" "$FAILED" "$RST" "$YEL" "$SKIPPED" "$RST"
  audit "verify ${target} passed=${PASSED} failed=${FAILED} skipped=${SKIPPED}"

  if [[ "$FAILED" -eq 0 && "$PASSED" -gt 0 ]]; then
    printf '%bAll checks passed. The host works AND is still hardened.%b\n\n' "$GRN" "$RST"
    for s in "${list[@]}"; do clear_broken "$s"; done
    return 0
  fi
  printf '%bNot there yet. Re-read the FAIL lines — each one is a control, not a formality.%b\n\n' "$YEL" "$RST"
  return 1
}

cmd_hint() {
  local s="${1:-}"
  valid_scenario "${s}" || { err "usage: $0 hint <scenario>"; cmd_list; exit 2; }
  head1 "diagnostic commands for: ${s}"
  "hint_${s}"
  say ""
}

cmd_restore() {
  local target="${1:-all}" s
  require_root
  local -a list=()
  if [[ "$target" == "all" ]]; then list=("${SCENARIOS[@]}")
  else valid_scenario "$target" || { err "unknown scenario: ${target}"; exit 2; }; list=("$target"); fi

  for s in "${list[@]}"; do
    [[ -d "$(scen_dir "$s")" ]] || continue
    info "restoring ${s}"
    audit "restore ${s}"
    "restore_${s}" || warn "restore of '${s}' reported errors; inspect $(scen_dir "$s")"
    clear_broken "$s"
    rm -rf "$(scen_dir "$s")"
  done
  info "restore complete. Verify by hand: findmnt /tmp, sysctl -a, systemctl status, getent shadow."
}

usage() {
  cat <<EOF
${0##*/} ${VERSION} — LPIC-3 303 (303-300) topic 332.1 Host Hardening break & fix

  $0 list
  $0 break   <scenario|all|random>   [--yes] [--force]
  $0 verify  [scenario|all]
  $0 hint    <scenario>
  $0 status
  $0 restore [scenario|all]

Scenarios: ${SCENARIOS[*]}
Run it only on a disposable lab VM. Snapshot first.
EOF
}

main() {
  local -a argv=()
  local a
  for a in "$@"; do
    case "$a" in
      --yes|-y)  ASSUME_YES=1 ;;
      --force)   FORCE=1 ;;
      -h|--help) usage; exit 0 ;;
      *)         argv+=("$a") ;;
    esac
  done
  set -- "${argv[@]:-}"

  case "${1:-}" in
    list)    cmd_list ;;
    break)   shift || true; cmd_break "${1:-}" ;;
    verify)  shift || true; cmd_verify "${1:-all}" ;;
    hint)    shift || true; cmd_hint "${1:-}" ;;
    status)  cmd_status ;;
    restore) shift || true; cmd_restore "${1:-all}" ;;
    ""|help) usage ;;
    *)       err "unknown command: $1"; usage; exit 2 ;;
  esac
}

main "$@"

# =============================================================================
# =============================================================================
#                        S O L U T I O N   ( spoilers )
#
#  Work each scenario yourself first. Every command below is meant to be typed
#  as root on the lab VM, and every one of them is checked by `verify`.
# =============================================================================
#
# -----------------------------------------------------------------------------
# 1. sysctl — the vendor drop-in shadows the baseline
# -----------------------------------------------------------------------------
#  Diagnose
#    sysctl -n kernel.randomize_va_space              # 0
#    sysctl --system | grep -n randomize_va_space     # every file, in apply order
#    systemd-analyze cat-config sysctl.d              # merged view, with provenance
#    grep -Rn randomize_va_space /etc/sysctl.conf /etc/sysctl.d /run/sysctl.d /usr/lib/sysctl.d
#
#  Why the baseline lost: sysctl.d(5) merges /usr/lib/sysctl.d, /run/sysctl.d
#  and /etc/sysctl.d and applies them sorted by FILE NAME across all three
#  directories; the last assignment of a key wins. "99-zz-vendor-compat.conf"
#  sorts after "10-cis-hardening.conf", so it wins. A file in /etc with the
#  same NAME as one in /usr/lib overrides it entirely — that is the supported
#  way to neutralise a vendor file. On systemd systems /etc/sysctl.conf is
#  applied through the compatibility symlink /usr/lib/sysctl.d/99-sysctl.conf,
#  so it sorts at position "99-sysctl.conf" like any other file. Note also
#  that a value set only with `sysctl -w` is lost on reboot.
#
#  Fix (keep the audit trail, make the baseline authoritative)
#    # a) neutralise the offending keys but keep the file's history
#    sed -i -E 's/^(kernel\.randomize_va_space|fs\.suid_dumpable|kernel\.dmesg_restrict|kernel\.kptr_restrict)/# DISABLED by security review SEC-4470: \1/' \
#      /etc/sysctl.d/99-zz-vendor-compat.conf
#
#    # b) make the baseline win by name regardless of what ships later
#    mv /etc/sysctl.d/10-cis-hardening.conf /etc/sysctl.d/99-zzz-site-baseline.conf
#    cat /etc/sysctl.d/99-zzz-site-baseline.conf
#      kernel.randomize_va_space = 2     # 2 = full ASLR: stack, heap/brk, mmap, VDSO
#      fs.suid_dumpable          = 0     # 0 = no core dumps from set-UID programs
#      kernel.dmesg_restrict     = 1     # dmesg needs CAP_SYSLOG
#      kernel.kptr_restrict      = 1     # hide kernel pointers from unprivileged readers
#
#    sysctl --system
#
#  Prove it
#    sysctl -n kernel.randomize_va_space fs.suid_dumpable kernel.dmesg_restrict kernel.kptr_restrict
#    for i in 1 2 3; do awk '/\[stack\]/{print $1}' /proc/self/maps; done   # 3 different ranges
#    setarch --addr-no-randomize /bin/true   # only root-ish contexts should be able to opt out
#
#  Reference: https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html
#
# -----------------------------------------------------------------------------
# 2. limits — pam_limits starves the account
# -----------------------------------------------------------------------------
#  Diagnose
#    su -s /bin/bash - hardlab -c 'ulimit -a'
#    grep -Rn "" /etc/security/limits.conf /etc/security/limits.d/
#    grep -Rn pam_limits /etc/pam.d/
#
#  Key facts: limits.conf(5) entries are applied by pam_limits.so during
#  session setup, so they exist only inside a PAM session (su -, login, sshd).
#  Files in /etc/security/limits.d/ are read in alphabetical order AFTER
#  /etc/security/limits.conf, and the last matching entry wins. Soft is the
#  running value, hard is the ceiling a user may raise the soft limit to; only
#  root can raise a hard limit. Group and wildcard entries do not apply to
#  root. systemd services do NOT go through PAM: their ceilings come from
#  LimitNOFILE=/LimitNPROC= in the unit and DefaultLimit*= in system.conf.
#
#  Fix
#    cat >/etc/security/limits.d/99-lab-hardening.conf <<'EOF'
#    # Bounded, workable ceilings. Ticket SEC-4473.
#    hardlab   soft   nproc    256
#    hardlab   hard   nproc    512
#    hardlab   soft   nofile   1024
#    hardlab   hard   nofile   4096
#    *         soft   core     0
#    *         hard   core     0
#    root      hard   core     0
#    EOF
#
#  Prove it
#    su -s /bin/bash - hardlab -c 'ulimit -Hn; ulimit -Hu; ulimit -Hc'   # 4096 512 0
#    su -s /bin/bash - hardlab -c 'for i in $(seq 1 60); do sleep 2 & done; wait; echo ok'
#    grep -Rn pam_limits /etc/pam.d/system-auth /etc/pam.d/su            # still enforced
#
#  Note: core dumps also need fs.suid_dumpable=0 (scenario 1), and on systemd
#  hosts a DefaultLimitCORE / coredump.conf policy — 'ulimit -c 0' alone is
#  not the whole control: see /etc/systemd/coredump.conf and Storage=none.
#
# -----------------------------------------------------------------------------
# 3. mounts — noexec on /tmp
# -----------------------------------------------------------------------------
#  Diagnose
#    findmnt /tmp                       # fstype + effective options
#    findmnt -no OPTIONS /tmp
#    strace -f -e trace=execve /tmp/lab-report.sh 2>&1 | tail -3   # execve -> EACCES
#
#  noexec/nosuid/nodev are MOUNT properties enforced by the kernel at execve
#  and at set-UID evaluation. They are not file permissions, and they do not
#  stop `bash script.sh` (the interpreter merely reads the file). That is
#  precisely why noexec on /tmp is a speed bump, not a boundary — the real
#  control is not putting executables in a world-writable directory.
#
#  Fix — keep the hardening, move the executable
#    install -o root -g root -m 0755 /tmp/lab-report.sh /usr/local/bin/lab-report.sh
#    rm -f /tmp/lab-report.sh
#    hash -r; lab-report.sh                       # prints the token
#
#  Persist the mount options
#    # If /tmp is systemd's tmpfs (tmp.mount):
#    mkdir -p /etc/systemd/system/tmp.mount.d
#    printf '[Mount]\nOptions=mode=1777,strictatime,nosuid,nodev,noexec\n' \
#      > /etc/systemd/system/tmp.mount.d/10-hardening.conf
#    systemctl daemon-reload && mount -o remount,nosuid,nodev,noexec /tmp
#
#    # If /tmp is just a directory on / , bind-mount it onto itself:
#    printf '/tmp  /tmp  none  rw,bind,nosuid,nodev,noexec,nofail  0 0\n' >> /etc/fstab
#    findmnt --verify --verbose                   # ALWAYS, before rebooting
#    mount --bind /tmp /tmp && mount -o remount,bind,nosuid,nodev,noexec /tmp
#
#  Prove it
#    findmnt -no OPTIONS /tmp | tr ',' '\n' | grep -E 'noexec|nosuid|nodev'
#    findmnt --verify
#    Apply the same treatment to /dev/shm, /var/tmp and removable media.
#
# -----------------------------------------------------------------------------
# 4. accounts — expired/locked user, pam_wheel, login.defs
# -----------------------------------------------------------------------------
#  Diagnose
#    getent shadow pamlab      # name:hash:lastchg:min:max:warn:inactive:expire:
#    chage -l pamlab
#    passwd -S pamlab          # L = locked
#    cat /etc/pam.d/su
#    journalctl -t su --since '-10 min'
#
#  Fix (a) — unlock and un-expire, without recreating the account
#    passwd -u pamlab                  # drops the '!' prefix from the hash
#    #  If the hash is '!!' (never set), set one instead:
#    #    passwd pamlab
#    chage -E -1 pamlab                # remove the account expiry date
#    chage -M 90 -m 1 -W 7 pamlab      # max 90, min 1, warn 7
#    chage -l pamlab
#
#  Fix (b) — keep the su restriction, make it operable
#    grep -n pam_wheel /etc/pam.d/su
#    #   auth  sufficient  pam_rootok.so                  <- root always passes here
#    #   auth  required    pam_wheel.so use_uid group=wheel
#    usermod -aG wheel <your-admin-user>      # Debian/Ubuntu: group sudo
#    getent group wheel                       # must not be empty
#    #  use_uid makes pam_wheel check the REAL uid of the caller, which is the
#    #  correct choice for su. Do not remove the module: 'su' with an
#    #  unrestricted stack turns any leaked service-account shell into a root
#    #  password-guessing oracle.
#    #  Test from an unprivileged shell BEFORE logging out of your root session.
#
#  Fix (c) — defaults for future accounts
#    sed -i -E 's/^\s*#?\s*UMASK\s+.*/UMASK\t\t027/'                   /etc/login.defs
#    sed -i -E 's/^\s*#?\s*PASS_MAX_DAYS\s+.*/PASS_MAX_DAYS\t90/'      /etc/login.defs
#    sed -i -E 's/^\s*#?\s*PASS_MIN_DAYS\s+.*/PASS_MIN_DAYS\t1/'       /etc/login.defs
#    sed -i -E 's/^\s*#?\s*PASS_WARN_AGE\s+.*/PASS_WARN_AGE\t7/'       /etc/login.defs
#    sed -i -E 's/^\s*#?\s*ENCRYPT_METHOD\s+.*/ENCRYPT_METHOD\tSHA512/' /etc/login.defs
#    grep -E '^(UMASK|PASS_|ENCRYPT_METHOD)' /etc/login.defs
#
#  login.defs is consulted by useradd/usermod/passwd/login when they act. It
#  does not rewrite existing entries in /etc/shadow: that is why step (a) had
#  to touch pamlab explicitly. To sweep every existing account:
#    awk -F: '$3>=1000 && $1!="nobody" {print $1}' /etc/passwd \
#      | xargs -r -n1 chage -M 90 -m 1 -W 7
#
#  Related controls worth knowing for 332.1: 'usermod -s /usr/sbin/nologin' for
#  service accounts, 'faillock --user X' / /etc/security/faillock.conf for
#  lockout after failed attempts, and pam_pwquality for password strength.
#
# -----------------------------------------------------------------------------
# 5. unit — systemd sandbox with no writable state
# -----------------------------------------------------------------------------
#  Diagnose
#    systemctl status hardening-lab.service
#    journalctl -u hardening-lab.service -n 30 --no-pager      # Read-only file system
#    systemctl cat hardening-lab.service                        # unit + drop-ins
#    systemd-analyze security hardening-lab.service
#    systemd-run -p ProtectSystem=strict --pty touch /var/log/x # reproduce by hand
#
#  ProtectSystem=strict mounts the WHOLE hierarchy read-only inside the
#  service's mount namespace, except /dev, /proc and /sys. ProtectHome=yes
#  makes /home, /root and /run/user inaccessible. PrivateTmp=yes gives the
#  service private /tmp and /var/tmp. None of this is visible from your login
#  shell, which is why the program runs fine when you test it by hand. Exit
#  status 226/NAMESPACE means the namespace itself could not be set up;
#  a plain non-zero exit with EROFS means your program hit the read-only view.
#
#  Fix — the supported hole, not a weaker sandbox
#    mkdir -p /etc/systemd/system/hardening-lab.service.d
#    cat >/etc/systemd/system/hardening-lab.service.d/20-state.conf <<'EOF'
#    [Service]
#    StateDirectory=hardening-lab       # /var/lib/hardening-lab, created + writable
#    LogsDirectory=hardening-lab        # /var/log/hardening-lab, created + writable
#    # equivalent, if the paths must be literal:
#    # ReadWritePaths=/var/lib/hardening-lab /var/log/hardening-lab
#    EOF
#    systemctl daemon-reload
#    systemctl restart hardening-lab.service
#
#  Prove it
#    systemctl is-active hardening-lab.service            # active
#    cat /var/lib/hardening-lab/state
#    systemctl show hardening-lab.service | grep -E 'ProtectSystem|ProtectHome|PrivateTmp|NoNewPriv|ReadWritePaths'
#    systemd-analyze security hardening-lab.service       # exposure should drop below 4.5
#
#  StateDirectory=/LogsDirectory=/CacheDirectory=/RuntimeDirectory= are better
#  than ReadWritePaths= because systemd creates the directory with the right
#  owner and mode, exports $STATE_DIRECTORY / $LOGS_DIRECTORY to the process,
#  and cleans up on uninstall. They are also what makes DynamicUser=yes usable.
#
# -----------------------------------------------------------------------------
# 6. modules — a blacklist that blacklists nothing
# -----------------------------------------------------------------------------
#  Diagnose
#    ls /etc/modprobe.d/                          # lab-usb.blacklist -> wrong extension
#    modprobe -n -v usb-storage                   # dry run: still an insmod
#    modprobe -c | grep -i usb-storage            # the effective, merged config
#    lsmod | grep usb_storage                     # loaded, use count in column 3
#
#  modprobe.d(5): only files ending in .conf are read. 'blacklist <module>'
#  suppresses ALIAS-driven automatic loading only — an explicit
#  'modprobe usb-storage' still works, and so does loading as a dependency.
#  The construct that actually blocks both is:
#      install <module> /bin/true      (or /bin/false to make it fail loudly)
#  which replaces the load action with a command that does nothing.
#  Module names normalise '-' and '_', so usb-storage == usb_storage.
#
#  Fix
#    rm -f /etc/modprobe.d/lab-usb.blacklist
#    cat >/etc/modprobe.d/99-lab-usb.conf <<'EOF'
#    # DLP policy SEC-4471: USB mass storage disabled.
#    install usb-storage /bin/true
#    blacklist usb-storage
#    install uas /bin/true
#    blacklist uas
#    EOF
#    lsblk -S -o NAME,TRAN                # confirm you did NOT boot from USB
#    modprobe -r usb_storage              # unload from the running kernel
#
#  Prove it
#    modprobe -n -v usb-storage           # install /bin/true
#    modprobe usb-storage; lsmod | grep usb_storage    # no output
#
#  What still remains in production, and say so out loud:
#    * the driver may be inside the initramfs — Fedora/RHEL: 'lsinitrd | grep
#      usb-storage' then 'dracut -f'; Debian: 'update-initramfs -u'.
#    * anyone with CAP_SYS_MODULE can still insmod the .ko by path. The hard
#      stops are 'sysctl -w kernel.modules_disabled=1' (one-way, until reboot)
#      and CONFIG_MODULE_SIG_FORCE with your own signing key.
#    * for removable media that IS allowed, enforce nosuid,nodev,noexec via
#      udev rules or the automounter, exactly as in scenario 3.
#
# -----------------------------------------------------------------------------
# 7. boot — a GRUB password that protects nothing
# -----------------------------------------------------------------------------
#  Diagnose
#    cat /etc/grub.d/01_lab_superuser
#    grub2-mkconfig -o /var/lib/lpic3-303-332.1-breakfix/boot/grub.scratch.cfg
#    grep -nE 'superuser|password' /var/lib/lpic3-303-332.1-breakfix/boot/grub.scratch.cfg
#
#  Fix
#    grub2-mkpasswd-pbkdf2          # Debian/Ubuntu: grub-mkpasswd-pbkdf2
#      # Enter password: ...
#      # PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.ABC...DEF
#
#    cat >/etc/grub.d/01_lab_superuser <<'EOF'
#    #!/bin/sh
#    # Bootloader superuser, SEC-4472.
#    cat <<'GRUBEOF'
#    set superusers="labadmin"
#    password_pbkdf2 labadmin grub.pbkdf2.sha512.10000.PASTE_SALT.PASTE_HASH
#    GRUBEOF
#    EOF
#    chmod 0755 /etc/grub.d/01_lab_superuser
#
#    # Let the default entry boot unattended, but require the password to EDIT
#    # it or to use the command line. On Fedora/RHEL edit /etc/grub.d/10_linux:
#    #     CLASS="--class gnu-linux --class os --unrestricted"
#    # Debian/Ubuntu ship /etc/grub.d/10_linux with the same CLASS variable.
#
#    # Verify against a scratch file FIRST, never straight into /boot:
#    grub2-mkconfig -o /var/lib/lpic3-303-332.1-breakfix/boot/grub.scratch.cfg
#    grep -nE 'set superusers=|password_pbkdf2|--unrestricted' \
#        /var/lib/lpic3-303-332.1-breakfix/boot/grub.scratch.cfg
#
#    # Only when it is correct, and only outside this lab:
#    #   cp -a /boot/grub2/grub.cfg /boot/grub2/grub.cfg.$(date +%F) \
#    #     && grub2-mkconfig -o /boot/grub2/grub.cfg
#    #   chmod 600 /boot/grub2/grub.cfg    # user.cfg / grub.cfg with hashes
#    # Keep a rescue ISO reachable before you reboot.
#
#  Why 'set superuser=' failed: GRUB reads the variable 'superusers'. With no
#  superusers defined, authentication is disabled entirely and every entry is
#  editable — pressing 'e' and appending init=/bin/bash gives an unauthenticated
#  root shell. And a GRUB password is only one layer: without a BIOS/UEFI
#  supervisor password, a locked boot order, disabled external boot devices and
#  full-disk encryption (LUKS), an attacker with physical access simply boots
#  their own media and mounts your disk.
#
#  Reference: https://www.gnu.org/software/grub/manual/grub/grub.html#Security
#
# -----------------------------------------------------------------------------
# Closing checklist for 332.1 — say these out loud before you call it hardened
# -----------------------------------------------------------------------------
#   * Every control must be verified in its EFFECTIVE form: findmnt, not fstab;
#     'sysctl -n', not the .conf; 'systemctl show', not the unit file;
#     'modprobe -n -v', not the blacklist; 'getent shadow', not login.defs.
#   * Every control must survive a reboot, and you must have proven it does.
#   * A hardening change that breaks the workload gets reverted by the next
#     person on call at 3 a.m., in a hurry, with no ticket. Hardening that
#     stays applied is hardening that left the service working.
#   * Disable what is not used before tuning what is: 'systemctl list-units
#     --type=service --state=running', 'ss -tulpn', then mask what should
#     never come back with 'systemctl mask'.
# =============================================================================