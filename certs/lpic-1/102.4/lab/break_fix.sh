#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 (101-500 / 102-500) v5.0 — Topic 102.4: Use Debian package management
#  Weight: 4.69
#
#  BREAK & FIX LAB — "The dpkg database, APT sources and a half-configured package"
#
#  Reference: LPI Exam 101 / 102 Objectives
#             https://www.lpi.org/our-certifications/exam-101-objectives/
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It injects four independent, reversible faults into the Debian package
#  management stack of a DISPOSABLE lab VM:
#
#    FAULT 1 — An APT source list pointing at a non-resolvable mirror, plus a
#              malformed line, so `apt-get update` fails loudly.
#    FAULT 2 — A pinning file in /etc/apt/preferences.d/ that pins a package to
#              a priority that makes it uninstallable / held back.
#    FAULT 3 — A package left in the "half-configured / iF" state by planting a
#              postinst script that exits non-zero (dpkg --configure -a fails).
#    FAULT 4 — A file owned by a package deleted from disk, so `dpkg --verify`
#              (and `debsums`, if present) reports it as missing.
#
#  It NEVER touches the network, NEVER removes libc/dpkg/apt themselves, and
#  NEVER writes outside the paths it backs up first. Everything it modifies is
#  copied to a backup directory under /var/backups/lpic-102.4-lab/ so the
#  instructor (or the student, after giving up) can restore the box.
#
#  REQUIREMENTS
#  ------------
#    * Debian 11/12 or Ubuntu 20.04/22.04/24.04, throwaway VM or container.
#    * root privileges.
#    * A working snapshot you can roll back to. THIS SCRIPT BREAKS THINGS.
#
#  USAGE
#  -----
#    sudo ./102.4-break-and-fix.sh break     # inject the faults, print the brief
#    sudo ./102.4-break-and-fix.sh check     # grade yourself: pass/fail per fault
#    sudo ./102.4-break-and-fix.sh restore   # emergency reset (spoils the lab)
#    sudo ./102.4-break-and-fix.sh solution  # print the step-by-step solution
#
# =============================================================================

set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly LAB_ID="lpic-102.4"
readonly BACKUP_DIR="/var/backups/lpic-102.4-lab"
readonly STATE_FILE="${BACKUP_DIR}/lab.state"

readonly BROKEN_SOURCE="/etc/apt/sources.list.d/lpi-lab-mirror.list"
readonly BROKEN_PIN="/etc/apt/preferences.d/99-lpi-lab-pin"
readonly VICTIM_PKG_DEB_DIR="${BACKUP_DIR}/victim-pkg"
readonly VICTIM_PKG="lpi-lab-victim"
readonly VICTIM_PKG_VERSION="1.0"

# Package whose shipped file we delete for FAULT 4. Chosen because it is present
# on every Debian/Ubuntu base install, is not required to boot, and its files are
# trivially restorable with `apt-get install --reinstall`.
readonly VERIFY_PKG_CANDIDATES=("hostname" "bash" "coreutils" "grep" "sed")

# Colours (disabled when not a TTY, e.g. when piping to a file).
if [ -t 1 ]; then
    readonly C_RED=$'\033[1;31m'
    readonly C_GREEN=$'\033[1;32m'
    readonly C_YELLOW=$'\033[1;33m'
    readonly C_BLUE=$'\033[1;34m'
    readonly C_BOLD=$'\033[1m'
    readonly C_OFF=$'\033[0m'
else
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_OFF=""
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()  { printf '%s[ lab ]%s %s\n' "${C_BLUE}" "${C_OFF}" "$*"; }
ok()   { printf '%s[  OK ]%s %s\n' "${C_GREEN}" "${C_OFF}" "$*"; }
warn() { printf '%s[ !!  ]%s %s\n' "${C_YELLOW}" "${C_OFF}" "$*"; }
fail() { printf '%s[FAIL ]%s %s\n' "${C_RED}" "${C_OFF}" "$*"; }
die()  { fail "$*"; exit 1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This lab must run as root. Try: sudo $0 $*"
    fi
}

require_debian() {
    if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
        die "dpkg/apt-get not found. This lab only runs on a Debian-family system."
    fi
    if [ ! -f /etc/debian_version ]; then
        die "/etc/debian_version missing. Refusing to run on a non-Debian system."
    fi
}

confirm_disposable() {
    if [ "${LPI_LAB_ASSUME_YES:-0}" = "1" ]; then
        return 0
    fi
    cat <<'EOF'

  ####################################################################
  #                                                                  #
  #   WARNING — THIS SCRIPT DELIBERATELY BREAKS PACKAGE MANAGEMENT   #
  #                                                                  #
  #   Run it ONLY on a disposable lab VM or container that you can   #
  #   destroy or roll back to a snapshot. Do NOT run it on a         #
  #   workstation, a build host, or anything you care about.         #
  #                                                                  #
  ####################################################################

EOF
    printf 'Type exactly BREAK to continue: '
    local answer
    read -r answer
    [ "${answer}" = "BREAK" ] || die "Aborted by the user. Nothing was changed."
}

backup_file() {
    # backup_file <path> — copies <path> into the backup dir, preserving the
    # full path so restore is a straight `cp -a` back. Records "absent" markers
    # for files that did not exist, so restore knows to delete them.
    local src="$1"
    local dst="${BACKUP_DIR}/files${src}"
    mkdir -p "$(dirname "${dst}")"
    if [ -e "${src}" ]; then
        cp -a "${src}" "${dst}"
        printf 'existed\t%s\n' "${src}" >> "${STATE_FILE}"
    else
        printf 'absent\t%s\n' "${src}" >> "${STATE_FILE}"
    fi
}

# -----------------------------------------------------------------------------
# FAULT 1 — Broken APT source lists
# -----------------------------------------------------------------------------
break_sources() {
    log "FAULT 1: injecting a broken APT source list"
    backup_file "${BROKEN_SOURCE}"

    # Line 1: a syntactically valid entry pointing at a host that will never
    #         resolve  -> "Could not resolve 'mirror.invalid'".
    # Line 2: a malformed entry (missing the distribution/components fields)
    #         -> "Malformed entry ... in list file".
    # RFC 2606 reserves .invalid, so this can never accidentally hit a real host.
    cat > "${BROKEN_SOURCE}" <<'EOF'
# Installed by the LPIC-1 102.4 break & fix lab. It is not a real mirror.
deb http://mirror.lpi-lab.invalid/debian stable main
deb http://deb.debian.org/debian
EOF
    chmod 0644 "${BROKEN_SOURCE}"
    ok "wrote ${BROKEN_SOURCE}"
}

# -----------------------------------------------------------------------------
# FAULT 2 — A pin that holds a package back
# -----------------------------------------------------------------------------
break_pinning() {
    log "FAULT 2: injecting an APT pin that makes a package uninstallable"
    backup_file "${BROKEN_PIN}"

    # Priority -1 tells APT to never select this version, no matter what. The
    # student sees the package as uninstallable with a confusing message from
    # `apt-cache policy`, not from `apt-get install`.
    cat > "${BROKEN_PIN}" <<'EOF'
# Installed by the LPIC-1 102.4 break & fix lab.
Package: tree
Pin: release *
Pin-Priority: -1
EOF
    chmod 0644 "${BROKEN_PIN}"

    # Belt and braces: also mark a commonly-updated package as held, so
    # `apt-mark showhold` has something to show.
    if dpkg-query -W -f='${Status}\n' hostname 2>/dev/null | grep -q '^install ok installed'; then
        apt-mark hold hostname >/dev/null 2>&1 && \
            printf 'hold\thostname\n' >> "${STATE_FILE}"
    fi
    ok "wrote ${BROKEN_PIN} and placed a dpkg hold"
}

# -----------------------------------------------------------------------------
# FAULT 3 — A package stuck half-configured
# -----------------------------------------------------------------------------
build_victim_package() {
    # Builds a tiny .deb from scratch with dpkg-deb. Its postinst exits 1 the
    # first time it runs, which leaves the package in state "iF" (half
    # configured) and makes every later apt/dpkg operation refuse to proceed
    # until the student deals with it.
    local root="${VICTIM_PKG_DEB_DIR}/${VICTIM_PKG}-${VICTIM_PKG_VERSION}"
    rm -rf "${root}"
    mkdir -p "${root}/DEBIAN" "${root}/usr/share/doc/${VICTIM_PKG}" "${root}/usr/local/bin"

    cat > "${root}/DEBIAN/control" <<EOF
Package: ${VICTIM_PKG}
Version: ${VICTIM_PKG_VERSION}
Section: misc
Priority: optional
Architecture: all
Maintainer: LPIC-1 Lab <lab@example.invalid>
Description: LPIC-1 102.4 lab victim package
 A harmless package whose postinst fails on purpose so the student can practise
 diagnosing and repairing a half-configured dpkg state. Safe to purge.
EOF

    cat > "${root}/usr/local/bin/lpi-lab-hello" <<'EOF'
#!/bin/sh
echo "lpi-lab-victim is installed and configured."
EOF
    chmod 0755 "${root}/usr/local/bin/lpi-lab-hello"

    printf 'LPIC-1 102.4 lab package. Purge with: dpkg --purge %s\n' "${VICTIM_PKG}" \
        > "${root}/usr/share/doc/${VICTIM_PKG}/README"

    # The postinst fails while the sentinel file exists. Removing the sentinel is
    # the intended fix; `dpkg --configure -a` then succeeds.
    cat > "${root}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
SENTINEL=/etc/lpi-lab-victim.block
case "$1" in
    configure)
        if [ -e "$SENTINEL" ]; then
            echo "lpi-lab-victim: configuration blocked by $SENTINEL" >&2
            echo "lpi-lab-victim: remove that file and re-run 'dpkg --configure -a'" >&2
            exit 1
        fi
        echo "lpi-lab-victim: configured successfully."
        ;;
    abort-upgrade|abort-remove|abort-deconfigure)
        ;;
esac
exit 0
EOF
    chmod 0755 "${root}/DEBIAN/postinst"

    cat > "${root}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
exit 0
EOF
    chmod 0755 "${root}/DEBIAN/prerm"

    dpkg-deb --build "${root}" "${VICTIM_PKG_DEB_DIR}/${VICTIM_PKG}_${VICTIM_PKG_VERSION}_all.deb" >/dev/null
    printf '%s\n' "${VICTIM_PKG_DEB_DIR}/${VICTIM_PKG}_${VICTIM_PKG_VERSION}_all.deb"
}

break_half_configured() {
    log "FAULT 3: installing a package whose postinst fails (half-configured state)"
    local deb
    deb="$(build_victim_package)" || die "could not build the victim package"

    # The sentinel makes the postinst fail. It is created BEFORE the install.
    touch /etc/lpi-lab-victim.block
    printf 'sentinel\t/etc/lpi-lab-victim.block\n' >> "${STATE_FILE}"

    # dpkg -i is expected to exit non-zero here — that is the whole point.
    if dpkg -i "${deb}" >/dev/null 2>&1; then
        warn "the victim package configured cleanly; the fault did not take"
    else
        printf 'installed\t%s\n' "${VICTIM_PKG}" >> "${STATE_FILE}"
        ok "${VICTIM_PKG} is now half-configured (dpkg state 'iF')"
    fi
}

# -----------------------------------------------------------------------------
# FAULT 4 — A packaged file deleted from disk
# -----------------------------------------------------------------------------
pick_verify_pkg() {
    local p
    for p in "${VERIFY_PKG_CANDIDATES[@]}"; do
        if dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -q '^install ok installed'; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

break_missing_file() {
    log "FAULT 4: deleting a file that belongs to an installed package"
    local pkg
    if ! pkg="$(pick_verify_pkg)"; then
        warn "no suitable package found; skipping fault 4"
        return 0
    fi

    # Only ever delete something under /usr/share/doc — documentation, never a
    # binary, a library or a config file. Losing it cannot break the running
    # system, but `dpkg --verify` and `debsums` still flag it as missing.
    local victim
    victim="$(dpkg-query -L "${pkg}" 2>/dev/null \
              | grep -E '^/usr/share/doc/.*/(copyright|changelog\.Debian\.gz|README.*)$' \
              | while read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done \
              | head -n 1)"

    if [ -z "${victim}" ]; then
        warn "package ${pkg} has no deletable doc file; skipping fault 4"
        return 0
    fi

    backup_file "${victim}"
    rm -f "${victim}"
    printf 'deleted\t%s\t%s\n' "${pkg}" "${victim}" >> "${STATE_FILE}"
    ok "removed ${victim} (owned by ${pkg})"
}

# -----------------------------------------------------------------------------
# The student brief
# -----------------------------------------------------------------------------
print_brief() {
    local pkg_hint="(see 'dpkg --verify' output)"
    cat <<EOF

${C_BOLD}================================================================${C_OFF}
${C_BOLD} LPIC-1 102.4 — BREAK & FIX: Debian package management${C_OFF}
${C_BOLD}================================================================${C_OFF}

Four faults have been injected into this VM's package management stack.
Your job is to diagnose each one from its symptom and repair it, WITHOUT
reinstalling the operating system and WITHOUT running this script's
'restore' or 'solution' subcommands.

${C_BOLD}--- SYMPTOM 1: apt-get update fails ---------------------------${C_OFF}

  You will see something like:

    Err:3 http://mirror.lpi-lab.invalid/debian stable InRelease
      Temporary failure resolving 'mirror.lpi-lab.invalid'
    E: Malformed entry 2 in list file /etc/apt/sources.list.d/... (Suite)
    E: The list of sources could not be read.

  ${C_BOLD}Goal:${C_OFF} 'apt-get update' completes with exit status 0 and no Err/E:
  lines. Understand the sources.list line format:

    deb <URI> <distribution> <component1> [component2 ...]

  Relevant tools: apt-get update, ls /etc/apt/sources.list.d/,
  apt-cache policy, apt-config dump, man 5 sources.list

${C_BOLD}--- SYMPTOM 2: a package refuses to install / is held back ----${C_OFF}

  'apt-get install tree' reports the package has no installation candidate,
  or that it will not be installed, even though it exists in the archive.
  'apt-get upgrade' also reports at least one package "kept back".

  Investigate with:

    apt-cache policy tree
    apt-mark showhold

  ${C_BOLD}Goal:${C_OFF} 'apt-cache policy tree' shows a normal candidate with priority
  500 (not -1), and 'apt-mark showhold' prints nothing. Learn where APT
  reads pinning from: /etc/apt/preferences and /etc/apt/preferences.d/.

  Relevant tools: apt-cache policy, apt-mark unhold, man 5 apt_preferences

${C_BOLD}--- SYMPTOM 3: dpkg refuses to do anything ---------------------${C_OFF}

  Every apt/dpkg operation now aborts with:

    dpkg: error processing package ${VICTIM_PKG} (--configure):
      installed ${VICTIM_PKG} package post-installation script subprocess
      returned error exit status 1
    E: Sub-process /usr/bin/dpkg returned an error code (1)

  'dpkg -l ${VICTIM_PKG}' shows state ${C_BOLD}iF${C_OFF} — desired: install,
  status: half-configured.

  ${C_BOLD}Goal:${C_OFF} 'dpkg --configure -a' exits 0 and 'dpkg -l ${VICTIM_PKG}'
  shows state ${C_BOLD}ii${C_OFF}. Read the maintainer script to find out WHY it fails
  — it tells you, in its own error message. The script lives under
  /var/lib/dpkg/info/. Purging the package is a valid last resort, but
  configuring it is the better answer: understand the failure first.

  Relevant tools: dpkg -l, dpkg --configure -a, dpkg -s,
  ls /var/lib/dpkg/info/, dpkg --audit, man 1 dpkg

${C_BOLD}--- SYMPTOM 4: an installed package is missing a file ----------${C_OFF}

  'dpkg --verify' (also written 'dpkg -V') prints a line whose flags start
  with 'missing', pointing at a file under /usr/share/doc/ ${pkg_hint}.

  ${C_BOLD}Goal:${C_OFF} 'dpkg --verify' prints nothing for that package, meaning every
  shipped file is present with the recorded checksum. You must restore the
  file the way a sysadmin does — from the package — not by creating an
  empty file with touch.

  Relevant tools: dpkg --verify, dpkg -S <file>, dpkg -L <pkg>,
  apt-get install --reinstall <pkg>, debsums (if installed)

${C_BOLD}---------------------------------------------------------------${C_OFF}

  ${C_BOLD}Grade yourself:${C_OFF}  sudo $0 check
  ${C_BOLD}Give up:${C_OFF}         sudo $0 solution
  ${C_BOLD}Reset the VM:${C_OFF}    sudo $0 restore

  Note: faults 1 and 2 must be fixed BEFORE fault 4 can be repaired with
  --reinstall, because --reinstall needs a working archive. That ordering
  is deliberate: real incidents come in dependency chains, not in isolation.

EOF
}

# -----------------------------------------------------------------------------
# Grading
# -----------------------------------------------------------------------------
check_lab() {
    local score=0 total=4

    printf '\n%sGrading LPIC-1 102.4 break & fix%s\n\n' "${C_BOLD}" "${C_OFF}"

    # --- Fault 1 ---
    if [ -e "${BROKEN_SOURCE}" ] && grep -qE '^\s*deb\s+http://mirror\.lpi-lab\.invalid' "${BROKEN_SOURCE}" 2>/dev/null; then
        fail "1/4 sources: the bogus mirror entry is still present in ${BROKEN_SOURCE}"
    elif ! apt-get update -qq >/dev/null 2>&1; then
        fail "1/4 sources: 'apt-get update' still exits non-zero"
    else
        ok   "1/4 sources: 'apt-get update' is clean"
        score=$((score + 1))
    fi

    # --- Fault 2 ---
    local pin_bad=0
    if [ -e "${BROKEN_PIN}" ] && grep -qE '^\s*Pin-Priority:\s*-1' "${BROKEN_PIN}" 2>/dev/null; then
        pin_bad=1
    fi
    if apt-mark showhold 2>/dev/null | grep -qx 'hostname'; then
        pin_bad=1
    fi
    if [ "${pin_bad}" -eq 1 ]; then
        fail "2/4 pinning: a negative pin and/or a dpkg hold is still in effect"
    else
        ok   "2/4 pinning: no negative pin, no holds"
        score=$((score + 1))
    fi

    # --- Fault 3 ---
    local st
    st="$(dpkg-query -W -f='${Status}' "${VICTIM_PKG}" 2>/dev/null || true)"
    if [ -z "${st}" ] || [ "${st}" = "unknown ok not-installed" ]; then
        ok   "3/4 dpkg state: ${VICTIM_PKG} is gone (purged) — accepted"
        score=$((score + 1))
    elif [ "${st}" = "install ok installed" ]; then
        ok   "3/4 dpkg state: ${VICTIM_PKG} is fully configured (ii) — best answer"
        score=$((score + 1))
    else
        fail "3/4 dpkg state: ${VICTIM_PKG} is '${st}' — still not repaired"
    fi

    # --- Fault 4 ---
    local deleted_line pkg4 file4
    deleted_line="$(grep -m1 $'^deleted\t' "${STATE_FILE}" 2>/dev/null || true)"
    if [ -z "${deleted_line}" ]; then
        ok   "4/4 verify: fault 4 was never injected on this host — skipped"
        score=$((score + 1))
    else
        pkg4="$(printf '%s' "${deleted_line}" | cut -f2)"
        file4="$(printf '%s' "${deleted_line}" | cut -f3)"
        if [ ! -e "${file4}" ]; then
            fail "4/4 verify: ${file4} is still missing"
        elif [ ! -s "${file4}" ]; then
            fail "4/4 verify: ${file4} exists but is empty — you faked it, restore it from the package"
        elif dpkg --verify "${pkg4}" 2>/dev/null | grep -q .; then
            fail "4/4 verify: 'dpkg --verify ${pkg4}' still reports differences"
        else
            ok   "4/4 verify: ${pkg4} verifies clean"
            score=$((score + 1))
        fi
    fi

    printf '\n%sScore: %d/%d%s\n\n' "${C_BOLD}" "${score}" "${total}" "${C_OFF}"
    [ "${score}" -eq "${total}" ]
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
restore_lab() {
    log "restoring the VM to its pre-lab state"
    [ -f "${STATE_FILE}" ] || die "no state file at ${STATE_FILE}; nothing to restore"

    # Undo the half-configured package first — dpkg blocks on it.
    rm -f /etc/lpi-lab-victim.block
    if dpkg-query -W "${VICTIM_PKG}" >/dev/null 2>&1; then
        dpkg --configure -a >/dev/null 2>&1 || true
        dpkg --purge "${VICTIM_PKG}" >/dev/null 2>&1 || true
        ok "purged ${VICTIM_PKG}"
    fi

    # Undo holds.
    while IFS=$'\t' read -r kind arg _; do
        [ "${kind}" = "hold" ] || continue
        apt-mark unhold "${arg}" >/dev/null 2>&1 || true
    done < "${STATE_FILE}"

    # Restore or delete every file we touched.
    while IFS=$'\t' read -r kind path rest; do
        case "${kind}" in
            existed)
                if [ -e "${BACKUP_DIR}/files${path}" ]; then
                    mkdir -p "$(dirname "${path}")"
                    cp -a "${BACKUP_DIR}/files${path}" "${path}"
                fi
                ;;
            absent)
                rm -f "${path}"
                ;;
            deleted)
                # path holds the package name, rest holds the file path.
                if [ -e "${BACKUP_DIR}/files${rest}" ]; then
                    mkdir -p "$(dirname "${rest}")"
                    cp -a "${BACKUP_DIR}/files${rest}" "${rest}"
                fi
                ;;
        esac
    done < "${STATE_FILE}"

    rm -f "${BROKEN_SOURCE}" "${BROKEN_PIN}"
    rm -f "${STATE_FILE}"
    ok "restore complete. Run 'apt-get update' to confirm."
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
main() {
    local action="${1:-break}"
    require_root "$@"
    require_debian

    case "${action}" in
        break)
            confirm_disposable
            mkdir -p "${BACKUP_DIR}"
            chmod 0700 "${BACKUP_DIR}"
            : > "${STATE_FILE}"
            printf 'lab\t%s\n' "${LAB_ID}" >> "${STATE_FILE}"
            break_sources
            break_pinning
            break_missing_file      # before fault 3: dpkg-query must still work freely
            break_half_configured   # last, because it blocks further dpkg work
            print_brief
            ;;
        check)
            check_lab
            ;;
        restore)
            restore_lab
            ;;
        solution)
            sed -n '/^# =\{10,\} SOLUTION/,/^# =\{10,\} END SOLUTION/p' "$0"
            ;;
        *)
            die "Unknown action '${action}'. Use: break | check | restore | solution"
            ;;
    esac
}

main "$@"
exit $?

# =========================== SOLUTION ========================================
#
# Everything below is commented out. Read it only after you have tried.
#
# -----------------------------------------------------------------------------
# ORDER MATTERS
# -----------------------------------------------------------------------------
# dpkg's half-configured package (fault 3) blocks apt from doing anything else,
# and fault 4's repair needs a working archive (fault 1). So the sane order is:
#
#   3 (unblock dpkg) -> 1 (fix sources) -> 2 (remove the pin) -> 4 (reinstall)
#
# -----------------------------------------------------------------------------
# FAULT 3 — the half-configured package
# -----------------------------------------------------------------------------
#
#   # 1. Confirm the state. The two-letter code is desired-action + current
#   #    status: 'iF' = desired install, status Half-configured.
#   dpkg -l lpi-lab-victim
#   #  Desired=Unknown/Install/Remove/Purge/Hold
#   #  | Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend
#   #  ||/ Name             Version   Architecture Description
#   #  +++-================-=========-============-=========================
#   #  iF  lpi-lab-victim   1.0       all          LPIC-1 102.4 lab victim package
#
#   # `dpkg --audit` lists every package in a broken state, which is the
#   # command to reach for when you do not already know the package name:
#   dpkg --audit
#
#   # 2. Reproduce the failure and READ the error. dpkg prints the maintainer
#   #    script's own stderr:
#   dpkg --configure -a
#   #  Setting up lpi-lab-victim (1.0) ...
#   #  lpi-lab-victim: configuration blocked by /etc/lpi-lab-victim.block
#   #  lpi-lab-victim: remove that file and re-run 'dpkg --configure -a'
#   #  dpkg: error processing package lpi-lab-victim (--configure):
#   #   installed lpi-lab-victim package post-installation script subprocess
#   #   returned error exit status 1
#
#   # 3. Inspect the script yourself. Maintainer scripts are unpacked into
#   #    /var/lib/dpkg/info/<package>.<script>:
#   ls -l /var/lib/dpkg/info/lpi-lab-victim.*
#   cat /var/lib/dpkg/info/lpi-lab-victim.postinst
#
#   # 4. Remove the cause and finish the configuration:
#   rm -f /etc/lpi-lab-victim.block
#   dpkg --configure -a
#   #  Setting up lpi-lab-victim (1.0) ...
#   #  lpi-lab-victim: configured successfully.
#
#   dpkg -l lpi-lab-victim | tail -n1
#   #  ii  lpi-lab-victim   1.0  all  LPIC-1 102.4 lab victim package
#
#   # Alternative (accepted, but inferior): remove the package outright.
#   #   dpkg --remove --force-remove-reinstreq lpi-lab-victim
#   #   dpkg --purge lpi-lab-victim
#   # Note that `dpkg --remove` runs prerm, which may also fail; --purge
#   # additionally deletes the conffiles that --remove leaves behind. Reaching
#   # for --force-* before reading the error is the habit this lab is training
#   # you out of.
#
# -----------------------------------------------------------------------------
# FAULT 1 — the broken sources
# -----------------------------------------------------------------------------
#
#   # 1. See the failure:
#   apt-get update
#   #  Err:3 http://mirror.lpi-lab.invalid/debian stable InRelease
#   #    Temporary failure resolving 'mirror.lpi-lab.invalid'
#   #  E: Malformed entry 2 in list file /etc/apt/sources.list.d/lpi-lab-mirror.list (Suite)
#   #  E: The list of sources could not be read.
#
#   # 2. APT reads /etc/apt/sources.list AND every *.list in
#   #    /etc/apt/sources.list.d/ (plus *.sources in deb822 format on newer
#   #    releases). Enumerate all of them — the offending file is named in the
#   #    error, but learn to list them anyway:
#   ls -l /etc/apt/sources.list.d/
#   cat /etc/apt/sources.list.d/lpi-lab-mirror.list
#   grep -rE '^\s*deb' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
#
#   # 3. Understand the syntax (man 5 sources.list):
#   #      deb [ options ] uri distribution [component1] [component2] ...
#   #    The second line in the lab file has a URI and nothing else — no
#   #    distribution, no components — hence "Malformed entry ... (Suite)".
#   #    The first line is syntactically valid but points at a host that does
#   #    not exist; .invalid is reserved by RFC 2606 precisely for this.
#
#   # 4. The correct repair is to delete the file the lab added, since neither
#   #    line contributes anything real:
#   rm -f /etc/apt/sources.list.d/lpi-lab-mirror.list
#   apt-get update
#   echo "exit status: $?"     # must be 0
#
#   # If instead you wanted to keep a valid entry, it would look like this on
#   # Debian 12 (bookworm):
#   #   deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
#   # or, on Ubuntu 22.04:
#   #   deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
#   # Disabling rather than deleting is also legitimate — comment the lines out
#   # with '#', or rename the file so it no longer ends in .list:
#   #   mv lpi-lab-mirror.list lpi-lab-mirror.list.disabled
#
#   # 5. Confirm which repositories APT now trusts and their priorities:
#   apt-cache policy
#
# -----------------------------------------------------------------------------
# FAULT 2 — the pin and the hold
# -----------------------------------------------------------------------------
#
#   # 1. See the symptom:
#   apt-cache policy tree
#   #  tree:
#   #    Installed: (none)
#   #    Candidate: (none)
#   #    Version table:
#   #       2.1.0-1 -1
#   #          500 http://deb.debian.org/debian bookworm/main amd64 Packages
#   #
#   #    Candidate "(none)" with a version listed at priority -1 is the
#   #    signature of a pin. Any priority < 0 means "never install this".
#
#   # 2. Find where the pin comes from. APT reads /etc/apt/preferences and
#   #    every file in /etc/apt/preferences.d/:
#   ls -l /etc/apt/preferences.d/
#   cat /etc/apt/preferences.d/99-lpi-lab-pin
#   #  Package: tree
#   #  Pin: release *
#   #  Pin-Priority: -1
#
#   # 3. Remove it (or edit the priority to a sane value):
#   rm -f /etc/apt/preferences.d/99-lpi-lab-pin
#   apt-cache policy tree
#   #  Candidate: 2.1.0-1        <- back to the archive priority, 500
#
#   #    Priority reference (man 5 apt_preferences):
#   #      < 0     never install
#   #      1-99    install only if nothing of the package is installed
#   #      100-499 install unless a version from a higher-priority source exists
#   #      500     the default for a normal archive
#   #      990     the default for the target release (-t / APT::Default-Release)
#   #      > 1000  install even if it means downgrading
#
#   # 4. The second half of this fault is a dpkg-level hold, which is a
#   #    different mechanism from pinning and lives in dpkg's own database:
#   apt-mark showhold
#   #  hostname
#   apt-mark unhold hostname
#   #  Canceled hold on hostname.
#   apt-mark showhold          # now prints nothing
#
#   #    Equivalent, lower-level forms worth knowing for the exam:
#   #      echo "hostname hold"    | dpkg --set-selections
#   #      echo "hostname install" | dpkg --set-selections
#   #      dpkg --get-selections | grep -w hold
#
# -----------------------------------------------------------------------------
# FAULT 4 — the missing packaged file
# -----------------------------------------------------------------------------
#
#   # 1. Find it. `dpkg --verify` (short: dpkg -V) compares the md5sums dpkg
#   #    recorded at unpack time against what is on disk:
#   dpkg --verify
#   #  missing     /usr/share/doc/hostname/copyright
#   #
#   #    The flag field is 9 characters, in the style of rpm -V:
#   #      ??5?????? c /path    -> checksum differs, and it is a conffile
#   #      missing     /path    -> the file is not there at all
#   #    Only md5sum ('5') is actually implemented by dpkg today; the other
#   #    positions are placeholders. `debsums -c` gives a second opinion when
#   #    the debsums package is installed.
#
#   # 2. Establish which package owns it — never guess from the path:
#   dpkg -S /usr/share/doc/hostname/copyright
#   #  hostname: /usr/share/doc/hostname/copyright
#
#   #    And the reverse, to see everything that package shipped:
#   dpkg -L hostname
#
#   # 3. Restore it FROM THE PACKAGE. This requires a working archive, which is
#   #    why faults 1 and 2 had to be fixed first:
#   apt-get update
#   apt-get install --reinstall hostname
#   #  ...
#   #  Preparing to unpack .../hostname_3.23+nmu1_amd64.deb ...
#   #  Unpacking hostname (3.23+nmu1) over (3.23+nmu1) ...
#   #  Setting up hostname (3.23+nmu1) ...
#
#   # 4. Verify the repair:
#   dpkg --verify hostname     # prints nothing == clean
#   ls -l /usr/share/doc/hostname/copyright
#
#   # If the machine has no network at all, the offline equivalent is to fetch
#   # the .deb (or find it in /var/cache/apt/archives/) and unpack it by hand:
#   #   apt-get download hostname
#   #   dpkg -i ./hostname_*.deb                 # full reinstall
#   #   # or extract a single file without touching the dpkg database:
#   #   dpkg-deb -x ./hostname_*.deb /tmp/x && \
#   #     cp /tmp/x/usr/share/doc/hostname/copyright /usr/share/doc/hostname/
#   #   # inspect a .deb without installing:
#   #   dpkg-deb -c ./hostname_*.deb     # contents
#   #   dpkg-deb -I ./hostname_*.deb     # control information
#   #   dpkg-deb -e ./hostname_*.deb /tmp/ctrl   # extract maintainer scripts
#   #
#   #   Creating an empty file with touch would silence `ls` but NOT
#   #   `dpkg --verify` — the md5sum still would not match. The grader checks
#   #   for exactly that shortcut.
#
# -----------------------------------------------------------------------------
# FINAL VERIFICATION — the state a healthy Debian box should be in
# -----------------------------------------------------------------------------
#
#   apt-get update            && echo "sources OK"
#   apt-get check             && echo "dependencies OK"   # parses the db, verifies deps
#   dpkg --audit              # prints nothing when no package is in a broken state
#   dpkg --configure -a       # no-op when nothing is pending
#   apt-mark showhold         # empty
#   dpkg --verify             # empty
#   apt-get -f install        # "0 upgraded, 0 newly installed, 0 to remove"
#
#   # Then grade yourself:
#   sudo ./102.4-break-and-fix.sh check
#
# -----------------------------------------------------------------------------
# WHAT THIS MAPS TO IN THE 102.4 OBJECTIVE
# -----------------------------------------------------------------------------
#
#   /etc/apt/sources.list, /etc/apt/sources.list.d/  -> faults 1
#   /etc/apt/preferences.d/, apt-mark, dpkg holds    -> fault 2
#   dpkg, dpkg-deb, /var/lib/dpkg/, maintainer scripts, --configure -> fault 3
#   dpkg -S / -L / --verify, apt-get --reinstall, apt-cache -> fault 4
#
#   Command inventory exercised here, all of it examinable:
#     dpkg -i -l -L -S -s -V -r -P --configure --audit --get-selections
#          --set-selections --force-*
#     dpkg-deb -b -c -e -I -x
#     dpkg-query -W -L -S -f
#     apt-get update / install / --reinstall / -f install / check / download
#     apt-cache policy / show / showpkg / depends / rdepends / search
#     apt-mark hold / unhold / showhold / auto / manual
#     apt-file search / list                (needs `apt-file update` first)
#
#   Sources:
#     LPI Exam 101/102 Objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
#     Debian Administrator's Handbook, ch. 5 "Packaging System" and ch. 6 "Maintenance
#       and Updates: The APT Tools" — https://www.debian.org/doc/manuals/debian-handbook/
#     Debian Policy Manual, ch. 6 "Package maintainer scripts and installation
#       procedure" — https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html
#     man 1 dpkg, man 1 dpkg-deb, man 1 dpkg-query, man 8 apt-get,
#     man 8 apt-cache, man 8 apt-mark, man 5 sources.list, man 5 apt_preferences
#
# ========================= END SOLUTION ======================================