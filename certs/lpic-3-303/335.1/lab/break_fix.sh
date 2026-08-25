#!/usr/bin/env bash
#
# ==============================================================================
#  break-and-fix.sh
#  LPIC-3 303 Security -- Exam 303-300, version 3.0.0
#  Topic 335.1: Common Security Vulnerabilities and Threats  (exam weight: 3.33)
#
#  Scenario: Local Privilege Escalation via a misconfigured SUID root binary.
#  This is the most directly demonstrable of the 335.1 threat classes on a
#  Linux host. The others in the objective -- buffer overflow, XSS, CSRF,
#  SQL injection, race conditions (TOCTOU), DoS/DDoS, man-in-the-middle, and
#  malware (rootkits/trojans/viruses/worms) -- are discussed in the theory
#  block and in the commented solution at the end of this file.
#
#  Reference (official):
#    LPI Exam 303 Objectives
#    https://www.lpi.org/our-certifications/exam-303-objectives/
#
#  ----------------------------------------------------------------------------
#  !!!  DESTRUCTIVE BY DESIGN  !!!
#  This script intentionally installs a working local root-escalation vector.
#  Run it ONLY inside a disposable lab VM that you can snapshot and revert.
#  Never run it on a shared, staging, or production host.
#  ----------------------------------------------------------------------------
#
#  Usage:
#    sudo LAB_CONFIRM=yes ./break-and-fix.sh break     # install the vulnerability + briefing
#    sudo ./break-and-fix.sh check                     # grade your remediation (safe, read-only test)
#    sudo ./break-and-fix.sh restore                   # apply the reference fix (spoiler)
#    ./break-and-fix.sh help
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
readonly LAB_USER="labuser"
readonly LAB_PASS="labpass123"                 # lab-only credential, never reuse
readonly VULN_BIN="/usr/local/bin/.sysdiag"    # deliberately innocuous-looking name
readonly BASELINE_SUID="/root/.suid_baseline.txt"
readonly C_RED=$'\033[1;31m'
readonly C_GRN=$'\033[1;32m'
readonly C_YEL=$'\033[1;33m'
readonly C_CYA=$'\033[1;36m'
readonly C_OFF=$'\033[0m'

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log()  { printf '%s[*]%s %s\n'  "$C_CYA" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n'  "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%s[x]%s %s\n'  "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This script must run as root (use sudo)."
}

safety_gate() {
  # A cheap, honest guard. It is not a sandbox -- it is a speed bump that forces
  # the operator to acknowledge the blast radius before arming the vulnerability.
  [[ "${LAB_CONFIRM:-}" == "yes" ]] || die \
    "Refusing to arm the vulnerability. Confirm this is a disposable lab VM by
       setting LAB_CONFIRM=yes, e.g.:  sudo LAB_CONFIRM=yes $0 break"

  # Loud, obvious production markers. Not exhaustive -- a snapshot is your real net.
  if [[ -f /etc/kubernetes/admin.conf ]] || pgrep -x kubelet >/dev/null 2>&1; then
    die "Kubernetes control-plane/kubelet detected. This looks like a real node. Aborting."
  fi
  if systemctl is-active --quiet nginx 2>/dev/null || systemctl is-active --quiet apache2 2>/dev/null; then
    warn "A web server is running here. Make absolutely sure this host is disposable."
  fi
}

ensure_lab_user() {
  if ! id "$LAB_USER" >/dev/null 2>&1; then
    log "Creating unprivileged demo account '$LAB_USER'..."
    useradd -m -s /bin/bash "$LAB_USER"
    echo "${LAB_USER}:${LAB_PASS}" | chpasswd
    ok "Created '$LAB_USER' (password: $LAB_PASS)"
  else
    log "Demo account '$LAB_USER' already present -- reusing it."
  fi
}

# ------------------------------------------------------------------------------
# THEORY (printed with the briefing)
# ------------------------------------------------------------------------------
print_theory() {
cat <<'EOF'

------------------------------------------------------------------------------
 THEORY -- Why a SUID root shell is a privilege-escalation vulnerability
------------------------------------------------------------------------------
 The CIA triad (Confidentiality, Integrity, Availability) is the frame the
 303 objective uses. Local privilege escalation breaks all three at once: an
 attacker who becomes root can read any secret (C), tamper with any file or
 binary (I), and take the host offline at will (A).

 The SUID (Set-User-ID) bit -- octal 4000, shown as 's' in the owner execute
 field of `ls -l` -- makes a program run with the EFFECTIVE UID of the file's
 owner instead of the caller's. It exists for legitimate tools that need a
 brief, tightly-scoped privilege (e.g. /usr/bin/passwd must edit /etc/shadow).

 The kernel enforces one crucial safety rule: when a SUID program starts, the
 real UID and effective UID differ, so a well-behaved shell DROPS the extra
 privileges immediately (bash resets euid=ruid unless invoked with -p).

 The vulnerability is a SUID root copy of an INTERACTIVE SHELL. `bash -p`
 ("privileged mode") tells bash NOT to drop the inherited euid=0. Any local
 user who can execute that file gets a root shell:

     $ /usr/local/bin/.sysdiag -p
     # id
     uid=1001(labuser) gid=1001(labuser) euid=0(root) groups=...

 This is exactly the class catalogued at GTFOBins for shells and for many
 standard utilities (find, vim, nmap, tar, cp...) when they carry a stray SUID
 bit. Root cause: an over-broad `chmod u+s`, a bad package/postinstall script,
 a backup restored with wrong ownership, or an attacker planting persistence.

 Related 335.1 threats you must be able to recognise (not armed here):
   * Buffer overflow  -- unchecked memory write past a buffer -> code exec.
   * TOCTOU race      -- gap between check (access) and use (open) of a path.
   * SQL injection    -- untrusted input concatenated into a SQL statement.
   * XSS / CSRF       -- injected/forged browser-side requests.
   * DoS / DDoS       -- exhaust CPU, RAM, fds, or bandwidth to kill (A).
   * MITM             -- intercept/alter traffic lacking auth+encryption.
   * Malware          -- rootkits/trojans that often INSTALL exactly this
                         kind of SUID backdoor as their persistence step.
------------------------------------------------------------------------------
EOF
}

# ------------------------------------------------------------------------------
# BREAK -- arm the vulnerability
# ------------------------------------------------------------------------------
do_break() {
  require_root
  safety_gate
  ensure_lab_user

  log "Recording a SUID/SGID baseline for reference (idempotent)..."
  find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null \
    | sort > "$BASELINE_SUID" || true

  log "Planting a SUID root shell at $VULN_BIN ..."
  install -m 0755 /bin/bash "$VULN_BIN"   # copy the real shell (idempotent overwrite)
  chown root:root "$VULN_BIN"
  chmod 4755 "$VULN_BIN"                    # 4000 = SUID  -> owner (root) euid on exec
  ok "Vulnerability armed."

  print_theory

cat <<EOF

------------------------------------------------------------------------------
 BRIEFING -- what you will SEE and what you must ACHIEVE
------------------------------------------------------------------------------
 SYMPTOM (reproduce it yourself):
   A routine SUID audit now shows a binary that does NOT belong to any package
   and that is, in fact, a full shell owned by root:

     # find / -xdev -perm -4000 -type f 2>/dev/null
     ...
     ${VULN_BIN}          <-- anomalous

     # ls -l ${VULN_BIN}
     -rwsr-xr-x 1 root root 1234376 ${VULN_BIN}
        ^--- the 's' in the owner field is the SUID bit

   And any unprivileged user can escalate to root with it:

     # su - ${LAB_USER}          (password: ${LAB_PASS})
     \$ ${VULN_BIN} -p
     # id
     uid=1001(${LAB_USER}) ... euid=0(root)
     # cat /etc/shadow          <-- succeeds; confidentiality is gone

 YOUR OBJECTIVE:
   1. Enumerate every SUID/SGID binary and identify the illegitimate one(s).
   2. Prove to yourself the escalation works, then NEUTRALISE it so that
      '${LAB_USER}' can no longer reach a root context on this host.
   3. Look for persistence you may have missed (a real attacker rarely leaves
      just one door): rogue cron jobs, authorized_keys, /etc/sudoers.d entries,
      writable /etc/passwd, extra SUID files.

 GRADE YOUR WORK (safe, read-only):
     sudo $0 check

 STUCK? The full reference solution is in the commented block at the very
 bottom of this script file, and can be auto-applied with:
     sudo $0 restore
------------------------------------------------------------------------------
EOF
}

# ------------------------------------------------------------------------------
# CHECK -- grade the remediation without giving away the fix
# ------------------------------------------------------------------------------
do_check() {
  require_root
  local failed=0

  log "1/3 Testing whether '$LAB_USER' can still escalate to root..."
  if id "$LAB_USER" >/dev/null 2>&1; then
    # Attempt the exploit AS the unprivileged user against the specific artifact.
    if [[ -f "$VULN_BIN" ]] \
       && runuser -u "$LAB_USER" -- "$VULN_BIN" -p -c 'cat /etc/shadow >/dev/null 2>&1' 2>/dev/null; then
      warn "STILL VULNERABLE: $VULN_BIN yields a root context (read /etc/shadow as $LAB_USER)."
      failed=1
    else
      ok "The planted SUID shell no longer grants root."
    fi
  else
    warn "Demo user '$LAB_USER' not found -- run 'break' first."
    failed=1
  fi

  log "2/3 Scanning for any unexpected SUID/SGID binaries vs. the baseline..."
  local current anomalies
  current="$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort || true)"
  if [[ -f "$BASELINE_SUID" ]]; then
    anomalies="$(comm -13 "$BASELINE_SUID" <(printf '%s\n' "$current") || true)"
    if [[ -n "$anomalies" ]]; then
      warn "SUID/SGID files not present in the baseline (investigate each):"
      printf '      %s\n' $anomalies
      failed=1
    else
      ok "No SUID/SGID drift versus the recorded baseline."
    fi
  else
    warn "No baseline recorded; showing current SUID inventory for manual review:"
    printf '      %s\n' $current
  fi

  log "3/3 Spot-checking common persistence footholds..."
  [[ -w /etc/passwd && "$(stat -c '%a' /etc/passwd)" != "644" ]] \
    && { warn "/etc/passwd permissions are not 644 ($(stat -c '%a' /etc/passwd))."; failed=1; } \
    || ok "/etc/passwd permissions look correct."

  echo
  if [[ "$failed" -eq 0 ]]; then
    ok  "RESULT: PASS -- privilege-escalation vector remediated. Well done."
  else
    warn "RESULT: FAIL -- at least one issue remains. Keep hunting."
    return 1
  fi
}

# ------------------------------------------------------------------------------
# RESTORE -- apply the reference fix (this is the spoiler path)
# ------------------------------------------------------------------------------
do_restore() {
  require_root
  log "Removing the planted SUID root shell..."
  if [[ -f "$VULN_BIN" ]]; then
    chmod u-s "$VULN_BIN" || true    # first drop the dangerous bit
    rm -f "$VULN_BIN"                 # then delete the rogue binary
    ok "Removed $VULN_BIN"
  else
    log "$VULN_BIN already absent."
  fi

  log "Re-asserting safe permissions on /etc/passwd..."
  chown root:root /etc/passwd
  chmod 644 /etc/passwd
  ok "/etc/passwd -> root:root 644"

  ok "Reference remediation applied. Verify with:  sudo $0 check"
  log "Note: '$LAB_USER' is left in place; delete it with 'userdel -r $LAB_USER' when done."
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------
usage() {
cat <<EOF
break-and-fix.sh -- LPIC-3 303 topic 335.1 (privilege escalation via SUID)

  sudo LAB_CONFIRM=yes $0 break     Arm the vulnerability and print the briefing
  sudo $0 check                     Grade your remediation (safe, read-only)
  sudo $0 restore                   Apply the reference fix
  $0 help                           Show this help

Run ONLY on a disposable, snapshotted lab VM.
EOF
}

main() {
  case "${1:-help}" in
    break)   do_break ;;
    check)   do_check ;;
    restore) do_restore ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

# ==============================================================================
#  REFERENCE SOLUTION -- step by step  (read only after you have tried)
# ==============================================================================
#
#  GOAL RECAP: an unprivileged user can become root because a SUID-root copy of
#  a shell was planted at /usr/local/bin/.sysdiag. Fix = find it, prove it,
#  neutralise it, and rule out further persistence.
#
#  ---- Step 1: Reproduce the symptom (confirm the finding) --------------------
#
#    # su - labuser            # password: labpass123
#    $ /usr/local/bin/.sysdiag -p
#    # id                      # note: euid=0(root)  -> escalation confirmed
#    # cat /etc/shadow | head  # succeeds -> confidentiality broken
#    # exit
#
#  ---- Step 2: Enumerate every SUID / SGID binary on local filesystems --------
#
#    # find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec ls -l {} \; 2>/dev/null
#
#    -xdev keeps the scan on local mounts. Look for anything that is NOT a
#    known system tool. Compare against a fresh install or a package baseline:
#
#      Debian/Ubuntu:  dpkg -S /usr/local/bin/.sysdiag   # -> "no path found" = not packaged
#      RHEL/Fedora:    rpm -qf  /usr/local/bin/.sysdiag   # -> "not owned by any package"
#
#    A file owned by no package, living under /usr/local/bin, with the SUID bit
#    set, is an immediate red flag.
#
#  ---- Step 3: Identify WHAT the anomalous file is ---------------------------
#
#    # ls -l   /usr/local/bin/.sysdiag      # -rwsr-xr-x root root  -> SUID + root-owned
#    # file    /usr/local/bin/.sysdiag      # ELF ... dynamically linked, interpreter...
#    # sha256sum /usr/local/bin/.sysdiag /bin/bash   # identical hash -> it IS bash
#
#    A SUID-root interactive shell has no legitimate reason to exist.
#
#  ---- Step 4: Neutralise the vector -----------------------------------------
#
#    # chmod u-s /usr/local/bin/.sysdiag    # first remove the dangerous SUID bit
#    # rm -f    /usr/local/bin/.sysdiag     # then delete the rogue binary entirely
#
#    (Removing the SUID bit alone stops the escalation; deleting the planted
#     binary is the correct cleanup once you have identified it as illegitimate.)
#
#  ---- Step 5: Hunt for additional persistence (defence in depth) -------------
#
#    # find /etc/cron* /var/spool/cron -type f 2>/dev/null | xargs -r ls -l
#    # ls -l /etc/sudoers.d/ ; grep -R NOPASSWD /etc/sudoers /etc/sudoers.d 2>/dev/null
#    # for h in /home/* /root; do ls -l "$h/.ssh/authorized_keys" 2>/dev/null; done
#    # stat -c '%A %U:%G %n' /etc/passwd /etc/shadow    # must be 644 root:root / 640 root:shadow
#    # last -n 20 ; lastb -n 20                          # suspicious logins
#
#  ---- Step 6: Verify the fix ------------------------------------------------
#
#    # su - labuser -c '/usr/local/bin/.sysdiag -p -c "id"'   # -> No such file / no root
#    # sudo ./break-and-fix.sh check                          # -> RESULT: PASS
#
#  ---- Step 7: Harden so it cannot recur -------------------------------------
#
#    * Mount non-system filesystems with nosuid,nodev,noexec where feasible
#      (see /etc/fstab; e.g. /tmp, /home, removable media).
#    * Establish a file-integrity baseline and alert on SUID changes:
#        - AIDE:   aideinit ; aide --check
#        - RHEL:   rpm -Va | grep -E '^..5|S...'   (verify installed files)
#        - Debian: debsums -c
#    * Periodically diff live SUID inventory against a trusted baseline (this
#      script records one at /root/.suid_baseline.txt for exactly that purpose).
#    * Apply least privilege: legitimate SUID tools should be few, packaged,
#      and audited; capabilities (setcap) are often a safer alternative.
#
#  Official objective reference:
#    https://www.lpi.org/our-certifications/exam-303-objectives/
# ==============================================================================