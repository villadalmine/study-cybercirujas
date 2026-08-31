#!/usr/bin/env bash
#
# =============================================================================
#  lpic1-102.5-rpm-yum-breakfix.sh
#
#  LPIC-1 (exams 101-500 / 102-500, syllabus version 5.0)
#  Topic 102.5 — "Use RPM and YUM package management"   (exam weight: 4.69)
#
#  Break & Fix laboratory. This script injects five controlled, fully
#  reversible faults into the RPM / DNF-YUM stack of a DISPOSABLE lab VM,
#  prints the symptoms the student will observe, states the acceptance
#  criteria, and can grade the repair (`verify`) or undo everything
#  (`restore`).
#
#  Official references
#    LPI 101 objectives ....... https://www.lpi.org/our-certifications/exam-101-objectives/
#    LPI 102 objectives ....... https://www.lpi.org/our-certifications/exam-102-objectives/
#    rpm(8) / rpm macros ...... https://rpm-software-management.github.io/rpm/manual/
#    dnf configuration ........ https://dnf.readthedocs.io/en/latest/conf_ref.html
#    dnf command reference .... https://dnf.readthedocs.io/en/latest/command_ref.html
#    dnf5 documentation ....... https://dnf5.readthedocs.io/en/latest/
#    RHEL package management .. https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_software_with_the_dnf_tool/index
#
#  DANGER
#    Run ONLY on a throw-away virtual machine or container you can rebuild.
#    Never on a workstation, a build host, or anything in production.
#
#  Usage
#    ./lpic1-102.5-rpm-yum-breakfix.sh break    [--yes] [--skip-baseline]
#    ./lpic1-102.5-rpm-yum-breakfix.sh status
#    ./lpic1-102.5-rpm-yum-breakfix.sh verify
#    ./lpic1-102.5-rpm-yum-breakfix.sh hint
#    ./lpic1-102.5-rpm-yum-breakfix.sh restore  [--yes]
#
#  The step-by-step solution is at the END of this file, commented out.
#  Do not read it until `verify` has beaten you at least twice.
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
readonly LAB_ID="lpic1-102.5"
readonly LAB_ROOT="/var/tmp/${LAB_ID}-breakfix"
readonly BACKUP_DIR="${LAB_ROOT}/backup"
readonly STATE_FILE="${LAB_ROOT}/state.env"
readonly LOG_FILE="${LAB_ROOT}/lab.log"

# Fault 1 artefacts. /etc/rpm/macros.* is read AFTER /usr/lib/rpm/macros.d/*,
# so a file dropped here overrides the distribution defaults.
readonly MACRO_FILE="/etc/rpm/macros.zz-${LAB_ID}"
readonly BROKEN_DBPATH="/var/lib/rpm.${LAB_ID}.missing"

# Fault 2 artefact. Port 9 (discard) on loopback: connection refused in
# milliseconds, no DNS lookup, no traffic leaves the VM.
readonly FAKE_BASEURL="http://127.0.0.1:9/${LAB_ID}/broken/os/"
readonly REPO_MARKER="#${LAB_ID}-disabled"

# Fault 5 artefact.
readonly CONF_MARKER="# ${LAB_ID} lab marker - do not keep this line"

# Candidate lab packages, in order of preference. The first one that is NOT
# installed and IS available in the enabled repositories wins.
readonly -a PKG_CANDIDATES=(tree zsh htop jq nmap-ncat bind-utils tcpdump lsof)

# -----------------------------------------------------------------------------
# Presentation helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;36m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_OFF=''
fi

log()   { printf '%s\n' "$*" | tee -a "$LOG_FILE" >/dev/null 2>&1 || true; }
info()  { printf '%s[*]%s %s\n'    "$C_BLU" "$C_OFF" "$*"; log "[*] $*"; }
ok()    { printf '%s[OK]%s %s\n'   "$C_GRN" "$C_OFF" "$*"; log "[OK] $*"; }
warn()  { printf '%s[!]%s %s\n'    "$C_YEL" "$C_OFF" "$*" >&2; log "[!] $*"; }
fail()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; log "[FAIL] $*"; }
die()   { printf '%s[FATAL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; log "[FATAL] $*"; exit 1; }

rule()  { printf '%s\n' "-----------------------------------------------------------------------"; }
title() { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF"; rule; }

# -----------------------------------------------------------------------------
# Package-manager abstraction (dnf5 / dnf / yum)
# -----------------------------------------------------------------------------
PM=""            # binary name
PM_CONF=""       # main configuration file
PM_FAMILY=""     # dnf5 | dnf | yum

detect_pm() {
    if command -v dnf5 >/dev/null 2>&1; then
        PM="dnf5"; PM_FAMILY="dnf5"; PM_CONF="/etc/dnf/dnf.conf"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"; PM_CONF="/etc/dnf/dnf.conf"
        if dnf --version 2>/dev/null | head -n1 | grep -q '^5\.'; then
            PM_FAMILY="dnf5"
        else
            PM_FAMILY="dnf"
        fi
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"; PM_FAMILY="yum"; PM_CONF="/etc/yum.conf"
    else
        die "No dnf/dnf5/yum found. This lab targets RPM-based distributions."
    fi
    [[ -f "$PM_CONF" ]] || PM_CONF="/etc/yum.conf"
    [[ -f "$PM_CONF" ]] || die "Cannot locate the package manager main config file."
}

# `dnf list --available X` (dnf4/dnf5) vs `yum list available X` (yum3)
pm_pkg_is_available() {
    local pkg="$1"
    if [[ "$PM_FAMILY" == "yum" ]]; then
        yum -q list available "$pkg" >/dev/null 2>&1
    else
        "$PM" -q list --available "$pkg" >/dev/null 2>&1 || "$PM" -q info "$pkg" >/dev/null 2>&1
    fi
}

pm_makecache() {
    if [[ "$PM_FAMILY" == "yum" ]]; then
        timeout 300 yum -q makecache >/dev/null 2>&1
    else
        timeout 300 "$PM" -q makecache --refresh >/dev/null 2>&1
    fi
}

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
REPO_FILE=""; REPO_ID=""; GPG_KEYS=""; PASSWD_BIN=""; PASSWD_PKG=""
LAB_PKG=""; BROKEN_AT=""
F1=0; F2=0; F3=0; F4=0; F5=0     # 1 = fault injected

save_state() {
    umask 077
    cat >"$STATE_FILE" <<EOF
# ${LAB_ID} lab state - generated by ${SCRIPT_NAME}
REPO_FILE='${REPO_FILE}'
REPO_ID='${REPO_ID}'
GPG_KEYS='${GPG_KEYS}'
PASSWD_BIN='${PASSWD_BIN}'
PASSWD_PKG='${PASSWD_PKG}'
LAB_PKG='${LAB_PKG}'
BROKEN_AT='${BROKEN_AT}'
F1=${F1}; F2=${F2}; F3=${F3}; F4=${F4}; F5=${F5}
EOF
}

load_state() {
    [[ -f "$STATE_FILE" ]] || return 1
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    return 0
}

# -----------------------------------------------------------------------------
# Safety gate
# -----------------------------------------------------------------------------
ASSUME_YES="no"
SKIP_BASELINE="no"

guard() {
    [[ "${EUID}" -eq 0 ]] || die "Root privileges are required."
    command -v rpm >/dev/null 2>&1 || die "rpm(8) not found. Wrong distribution family."

    local pretty="unknown"
    [[ -r /etc/os-release ]] && pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID}")"

    local virt="unknown"
    command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt 2>/dev/null || true)"
    [[ -z "$virt" ]] && virt="unknown"

    title "SAFETY GATE"
    printf '  Host ............ %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf '  Distribution .... %s\n' "$pretty"
    printf '  Virtualisation .. %s\n' "$virt"
    printf '  Package manager . %s (%s), config %s\n' "$PM" "$PM_FAMILY" "$PM_CONF"
    printf '  rpm version ..... %s\n' "$(rpm --version | awk '{print $NF}')"
    rule

    if [[ "$virt" == "none" ]]; then
        warn "This looks like BARE METAL, not a virtual machine."
    fi
    if [[ -d /var/lib/kubelet || -S /run/containerd/containerd.sock ]]; then
        warn "Container runtime artefacts detected - is this really a scratch VM?"
    fi

    if [[ "$ASSUME_YES" == "yes" ]]; then
        warn "--yes given: skipping interactive confirmation."
        return 0
    fi

    printf '%sThis will deliberately damage the package management stack.%s\n' "$C_YEL" "$C_OFF"
    printf 'Type exactly %sBREAK THIS LAB VM%s to continue: ' "$C_BLD" "$C_OFF"
    local reply=""
    read -r reply || true
    [[ "$reply" == "BREAK THIS LAB VM" ]] || die "Aborted by the operator. Nothing was modified."
}

# -----------------------------------------------------------------------------
# Baseline: prove the system is healthy BEFORE breaking it.
# A fault you cannot distinguish from a pre-existing defect teaches nothing.
# -----------------------------------------------------------------------------
baseline() {
    title "BASELINE HEALTH CHECK"

    local n
    n="$(rpm -qa 2>/dev/null | wc -l)"
    [[ "$n" -gt 10 ]] || die "rpm -qa returned ${n} packages. The rpmdb is already unusable."
    ok "rpmdb readable: ${n} packages installed (dbpath: $(rpm -E '%_dbpath'))."

    local keys
    keys="$(rpm -q gpg-pubkey 2>/dev/null | grep -c '^gpg-pubkey' || true)"
    [[ "$keys" -gt 0 ]] || die "No gpg-pubkey packages imported. Import the distro key first."
    ok "GPG public keys imported into the rpmdb: ${keys}."

    if [[ "$SKIP_BASELINE" == "yes" ]]; then
        warn "--skip-baseline given: repository reachability NOT verified."
    else
        info "Refreshing repository metadata (this needs network access)..."
        if pm_makecache; then
            ok "Repository metadata refreshed successfully."
        else
            die "Baseline metadata refresh FAILED. Fix repositories first, or pass --skip-baseline."
        fi
    fi

    ok "Baseline is green. Proceeding."
}

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------
# Emit "file|section" for every enabled repository section that defines a
# metadata source (baseurl / metalink / mirrorlist).
enumerate_repos() {
    [[ -d /etc/yum.repos.d ]] || return 0
    awk '
        function flush(   ) {
            if (sec != "" && en == 1 && src == 1) print fsaved "|" sec
            sec=""; en=1; src=0
        }
        /^[[:space:]]*\[/ {
            flush()
            fsaved = FILENAME
            sec = substr($0, index($0,"[")+1, index($0,"]") - index($0,"[") - 1)
            next
        }
        /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*0/            { en = 0 }
        /^[[:space:]]*(baseurl|metalink|mirrorlist)[[:space:]]*=/   { src = 1 }
        END { flush() }
    ' /etc/yum.repos.d/*.repo 2>/dev/null
}

pick_repo() {
    local -a rows=()
    mapfile -t rows < <(enumerate_repos)
    [[ ${#rows[@]} -gt 0 ]] && {
        local row
        # Preferred: the distribution base repository.
        for row in "${rows[@]}"; do
            case "${row#*|}" in
                baseos|BaseOS|base|fedora|updates|rocky-baseos|*_baseos_latest|appstream|AppStream)
                    REPO_FILE="${row%%|*}"; REPO_ID="${row#*|}"; return 0 ;;
            esac
        done
        REPO_FILE="${rows[0]%%|*}"; REPO_ID="${rows[0]#*|}"; return 0
    }
    return 1
}

pick_lab_package() {
    local p
    for p in "${PKG_CANDIDATES[@]}"; do
        rpm -q "$p" >/dev/null 2>&1 && continue
        if [[ "$SKIP_BASELINE" == "yes" ]] || pm_pkg_is_available "$p"; then
            LAB_PKG="$p"; return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# Fault injection
# -----------------------------------------------------------------------------
backup_file() {
    local src="$1" dst
    dst="${BACKUP_DIR}/$(printf '%s' "$src" | tr '/' '_')"
    [[ -e "$dst" ]] && return 0
    cp -a --no-preserve=links "$src" "$dst" || die "Backup of ${src} failed."
    ok "Backed up ${src} -> ${dst}"
}

# --- Fault 4: drop the setuid bit from passwd -------------------------------
break_setuid() {
    PASSWD_BIN="$(command -v passwd 2>/dev/null || true)"
    [[ -n "$PASSWD_BIN" && -u "$PASSWD_BIN" ]] || { warn "passwd is missing or not setuid; skipping fault 4."; return 1; }
    PASSWD_PKG="$(rpm -qf --queryformat '%{NAME}\n' "$PASSWD_BIN" 2>/dev/null | head -n1)"
    [[ -n "$PASSWD_PKG" ]] || { warn "passwd is not owned by any package; skipping fault 4."; return 1; }
    chmod u-s "$PASSWD_BIN" || return 1
    F4=1
    ok "Fault 4 injected: setuid bit removed from ${PASSWD_BIN} (package ${PASSWD_PKG})."
    return 0
}

# --- Fault 3: delete every imported GPG public key --------------------------
break_gpg_keys() {
    local -a keys=()
    mapfile -t keys < <(rpm -q gpg-pubkey 2>/dev/null | grep '^gpg-pubkey' || true)
    [[ ${#keys[@]} -gt 0 ]] || { warn "No gpg-pubkey packages; skipping fault 3."; return 1; }

    local k
    for k in "${keys[@]}"; do
        rpm -q --queryformat '%{DESCRIPTION}\n' "$k" >"${BACKUP_DIR}/${k}.asc" 2>/dev/null
        if ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "${BACKUP_DIR}/${k}.asc" 2>/dev/null; then
            rm -f "${BACKUP_DIR}/${k}.asc"
            warn "Could not export ${k}; leaving it in place."
            continue
        fi
        rpm -e --allmatches "$k" >/dev/null 2>&1 && GPG_KEYS="${GPG_KEYS}${k} "
    done
    [[ -n "$GPG_KEYS" ]] || { warn "No key could be removed; skipping fault 3."; return 1; }
    F3=1
    ok "Fault 3 injected: removed GPG keys ->${GPG_KEYS}(armoured copies kept in ${BACKUP_DIR})."
    return 0
}

# --- Fault 2: point the base repository at a dead endpoint ------------------
break_repo() {
    pick_repo || { warn "No usable repository definition found; skipping fault 2."; return 1; }
    backup_file "$REPO_FILE"

    local tmp="${REPO_FILE}.${LAB_ID}.tmp"
    awk -v sec="$REPO_ID" -v url="$FAKE_BASEURL" -v marker="$REPO_MARKER" '
        /^[[:space:]]*\[/ {
            cur = substr($0, index($0,"[")+1, index($0,"]") - index($0,"[") - 1)
            insec = (cur == sec) ? 1 : 0
            print
            if (insec) print "baseurl=" url
            next
        }
        insec && /^[[:space:]]*(baseurl|metalink|mirrorlist)[[:space:]]*=/ {
            print marker " " $0
            next
        }
        { print }
    ' "$REPO_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }

    cat "$tmp" >"$REPO_FILE" && rm -f "$tmp"
    F2=1
    ok "Fault 2 injected: repository [${REPO_ID}] in ${REPO_FILE} now points at ${FAKE_BASEURL}"
    return 0
}

# --- Fault 5: hide the lab package behind a global exclude ------------------
break_exclude() {
    [[ -n "$LAB_PKG" ]] || { warn "No lab package selected; skipping fault 5."; return 1; }
    backup_file "$PM_CONF"

    local tmp="${PM_CONF}.${LAB_ID}.tmp"
    if grep -q '^[[:space:]]*\[main\]' "$PM_CONF"; then
        awk -v marker="$CONF_MARKER" -v pkg="$LAB_PKG" '
            { print }
            !done && /^[[:space:]]*\[main\]/ { print marker; print "exclude=" pkg "*"; done=1 }
        ' "$PM_CONF" >"$tmp" || { rm -f "$tmp"; return 1; }
    else
        { cat "$PM_CONF"; printf '\n[main]\n%s\nexclude=%s*\n' "$CONF_MARKER" "$LAB_PKG"; } >"$tmp"
    fi
    cat "$tmp" >"$PM_CONF" && rm -f "$tmp"
    F5=1
    ok "Fault 5 injected: 'exclude=${LAB_PKG}*' added to the [main] section of ${PM_CONF}."
    return 0
}

# --- Fault 1: override %_dbpath (MUST be injected last) ---------------------
break_dbpath() {
    mkdir -p /etc/rpm
    cat >"$MACRO_FILE" <<EOF
# ${LAB_ID} - laboratory macro override.
# /etc/rpm/macros.* is evaluated after /usr/lib/rpm/macros.d/*, so this wins.
%_dbpath        ${BROKEN_DBPATH}
%_dbpath_rebuild %{_dbpath}
EOF
    rm -rf "$BROKEN_DBPATH"     # the path must NOT exist: rpm must fail loudly
    F1=1
    ok "Fault 1 injected: %_dbpath overridden to ${BROKEN_DBPATH} via ${MACRO_FILE}."
    return 0
}

# -----------------------------------------------------------------------------
# The student's brief
# -----------------------------------------------------------------------------
print_brief() {
    title "LPIC-1 102.5 - BREAK & FIX BRIEF"
    cat <<EOF
Scenario
  You are on call. A colleague "tuned" this host during a maintenance window
  and left. The package management stack no longer works. Nothing was
  reinstalled, no package was deleted from disk, and no RPM database file was
  destroyed - every fault is a configuration or metadata problem you can find
  and repair with rpm(8) and ${PM}(8) alone.

  Faults may MASK each other. Repair them in the order the tooling reports
  them: if rpm itself cannot read its database, every other diagnosis you make
  is worthless.

Symptoms you are going to see
  1) Inventory is gone
       # rpm -qa | wc -l
       error: cannot open ${BROKEN_DBPATH}/Packages index using ...
       0
       # ${PM} list --installed
       Error: Could not open the rpmdb ...

  2) No metadata
       # ${PM} makecache --refresh
       Errors during downloading metadata for repository '${REPO_ID:-<base>}':
         - Curl error (7): Couldn't connect to server for ${FAKE_BASEURL}...
       Error: Failed to download metadata for repo '${REPO_ID:-<base>}'

  3) Signature verification collapses
       # ${PM} install -y ${LAB_PKG:-<pkg>}
       warning: .../${LAB_PKG:-<pkg>}-*.rpm: Header V4 RSA/SHA256 Signature,
                key ID xxxxxxxx: NOKEY
       Public key for ${LAB_PKG:-<pkg>}-*.rpm is not installed. Failing package is: ...
       GPG Keys are configured as: file:///etc/pki/rpm-gpg/RPM-GPG-KEY-...

  4) A package no longer matches what RPM shipped
       # rpm -V ${PASSWD_PKG:-passwd}
       .M.......    /usr/bin/passwd
       As an unprivileged user:
       \$ passwd
       passwd: Authentication token manipulation error

  5) A package that exists in the repository cannot be installed
       # ${PM} install ${LAB_PKG:-<pkg>}
       No match for argument: ${LAB_PKG:-<pkg>}
       Error: Unable to find a match: ${LAB_PKG:-<pkg>}
       ... yet:
       # ${PM} repoquery ${LAB_PKG:-<pkg>}
       ${LAB_PKG:-<pkg>}-0:...noarch

rpm -V output codes (memorise these, they are exam material)
  S size differs      M mode/permissions differs   5 digest (content) differs
  D device major/minor  L symlink path differs     U owner differs
  G group differs     T mtime differs              P capabilities differ
  .  attribute OK     ?  test could not be performed
  Second column: c config, d doc, g ghost, l license, r readme

Acceptance criteria - all five must hold, verified by: ${SCRIPT_NAME} verify
  [1] rpm -E '%_dbpath' prints /var/lib/rpm and 'rpm -qa | wc -l' returns the
      real inventory (hundreds of packages).
  [2] '${PM} repolist --enabled' lists [${REPO_ID:-<base>}] and
      '${PM} makecache --refresh' exits 0, with the repository restored to its
      ORIGINAL metadata source - not to a URL you invented.
  [3] 'rpm -q gpg-pubkey' lists at least one key again and the installation
      passes the signature check.
  [4] 'rpm -V ${PASSWD_PKG:-passwd}' produces no output for /usr/bin/passwd and
      the binary is setuid root again.
  [5] '${PM} install -y ${LAB_PKG:-<pkg>}' succeeds with gpgcheck=1 and WITHOUT
      --nogpgcheck, --disableexcludes, --disablerepo, --nodeps or --force.
      Suppressing a check is not a repair; the verifier inspects the
      configuration files, not just the end result.

Your toolbox for this topic
  Query      rpm -qa | rpm -qi | rpm -ql | rpm -qc | rpm -qd | rpm -qf FILE
             rpm -qa --last | rpm -q --changelog | rpm -q --scripts
             rpm -qp --requires FILE.rpm | rpm -q --whatprovides X
  Verify     rpm -V PKG | rpm -Va | rpm -Vf FILE | rpm -K FILE.rpm
  Repair     rpm --rebuilddb | rpm --restore PKG (rpm >= 4.17)
             rpm --setperms PKG / --setugids PKG (older rpm)
             rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-*
  Macros     rpm --showrc | rpm -E '%_dbpath' | /usr/lib/rpm/macros.d/, /etc/rpm/macros.*
  Repos      ${PM} repolist --all | ${PM} config-manager | ${PM} repoquery -l PKG
             ${PM} clean all | /var/cache/${PM} | ${PM} history | ${PM} history undo N
  Extract    rpm2cpio pkg.rpm | cpio -idmv     (or: rpm2archive / cpio -t)

State, backups and the escape hatch
  Lab state ....... ${STATE_FILE}
  Backups ......... ${BACKUP_DIR}
  Full rollback ... ${SCRIPT_NAME} restore
EOF
    rule
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_break() {
    detect_pm
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$LAB_ROOT"

    if load_state && [[ "${F1}${F2}${F3}${F4}${F5}" != "00000" ]]; then
        die "Faults are already active (see 'status'). Run '${SCRIPT_NAME} restore' first."
    fi
    F1=0; F2=0; F3=0; F4=0; F5=0; GPG_KEYS=""

    guard
    baseline

    title "DISCOVERY"
    pick_repo && ok "Target repository: [${REPO_ID}] in ${REPO_FILE}" || warn "No repository selected."
    pick_lab_package && ok "Lab package: ${LAB_PKG}" || warn "No lab package selected."

    title "INJECTING FAULTS"
    # Order matters: everything that needs to READ the rpmdb runs before the
    # %_dbpath override is put in place.
    break_setuid   || true
    break_gpg_keys || true
    break_repo     || true
    break_exclude  || true
    break_dbpath   || true

    BROKEN_AT="$(date -Is)"
    save_state

    print_brief
    printf '\n%sThe system is now broken. Start with: rpm -qa | wc -l%s\n\n' "$C_BLD" "$C_OFF"
}

cmd_status() {
    detect_pm
    load_state || die "No lab state found. Nothing has been broken from this script."
    title "LAB STATUS"
    printf '  Broken at ....... %s\n' "${BROKEN_AT:-unknown}"
    printf '  Repository ...... [%s] in %s\n' "${REPO_ID:-n/a}" "${REPO_FILE:-n/a}"
    printf '  Lab package ..... %s\n' "${LAB_PKG:-n/a}"
    printf '  Keys removed .... %s\n' "${GPG_KEYS:-none}"
    rule
    printf '  Fault 1 (%%_dbpath override) ...... %s\n' "$([[ $F1 -eq 1 ]] && echo injected || echo skipped)"
    printf '  Fault 2 (dead repo baseurl) ..... %s\n' "$([[ $F2 -eq 1 ]] && echo injected || echo skipped)"
    printf '  Fault 3 (GPG keys removed) ...... %s\n' "$([[ $F3 -eq 1 ]] && echo injected || echo skipped)"
    printf '  Fault 4 (passwd setuid dropped) . %s\n' "$([[ $F4 -eq 1 ]] && echo injected || echo skipped)"
    printf '  Fault 5 (exclude= in main) ...... %s\n' "$([[ $F5 -eq 1 ]] && echo injected || echo skipped)"
    rule
}

cmd_verify() {
    detect_pm
    load_state || die "No lab state found. Run '${SCRIPT_NAME} break' first."

    local passed=0 total=0
    title "GRADING"

    # --- 1: rpm database path -------------------------------------------------
    total=$((total+1))
    local dbpath count
    dbpath="$(rpm -E '%_dbpath' 2>/dev/null)"
    count="$(rpm -qa 2>/dev/null | wc -l)"
    if [[ "$dbpath" == "/var/lib/rpm" && "$count" -gt 10 && ! -f "$MACRO_FILE" ]]; then
        ok "1/5 rpmdb: %_dbpath=${dbpath}, ${count} packages, override file removed."
        passed=$((passed+1))
    else
        fail "1/5 rpmdb: %_dbpath='${dbpath}', rpm -qa returned ${count} package(s)."
        [[ -f "$MACRO_FILE" ]] && fail "     The override file ${MACRO_FILE} is still present."
        warn "     Faults 2-5 cannot be graded reliably until this is fixed."
    fi

    # --- 2: repository --------------------------------------------------------
    total=$((total+1))
    if [[ -z "$REPO_FILE" || ! -f "$REPO_FILE" ]]; then
        warn "2/5 repository: not applicable (fault was skipped)."
        total=$((total-1))
    elif grep -q "$REPO_MARKER" "$REPO_FILE" || grep -qF "$FAKE_BASEURL" "$REPO_FILE"; then
        fail "2/5 repository: ${REPO_FILE} still contains the injected baseurl / commented sources."
    elif ! pm_makecache; then
        fail "2/5 repository: configuration looks clean but '${PM} makecache --refresh' still fails."
    else
        ok "2/5 repository: [${REPO_ID}] restored and metadata downloads correctly."
        passed=$((passed+1))
    fi

    # --- 3: GPG keys ----------------------------------------------------------
    total=$((total+1))
    local keys
    keys="$(rpm -q gpg-pubkey 2>/dev/null | grep -c '^gpg-pubkey' || true)"
    if [[ "$keys" -gt 0 ]]; then
        ok "3/5 GPG: ${keys} public key(s) imported into the rpmdb."
        passed=$((passed+1))
    else
        fail "3/5 GPG: no gpg-pubkey package present. Signature verification is impossible."
    fi

    # --- 4: file integrity ----------------------------------------------------
    total=$((total+1))
    if [[ -z "${PASSWD_BIN:-}" ]]; then
        warn "4/5 integrity: not applicable (fault was skipped)."
        total=$((total-1))
    elif [[ ! -u "$PASSWD_BIN" ]]; then
        fail "4/5 integrity: ${PASSWD_BIN} is not setuid root. 'rpm -V ${PASSWD_PKG}' still reports .M......."
    elif rpm -V "$PASSWD_PKG" 2>/dev/null | grep -q "$PASSWD_BIN"; then
        fail "4/5 integrity: rpm -V ${PASSWD_PKG} still flags ${PASSWD_BIN}."
        rpm -V "$PASSWD_PKG" 2>/dev/null | grep "$PASSWD_BIN" | sed 's/^/       /'
    else
        ok "4/5 integrity: rpm -V ${PASSWD_PKG} is clean and ${PASSWD_BIN} is setuid root."
        passed=$((passed+1))
    fi

    # --- 5: exclude + real installation ---------------------------------------
    total=$((total+1))
    if [[ -z "${LAB_PKG:-}" ]]; then
        warn "5/5 install: not applicable (fault was skipped)."
        total=$((total-1))
    elif grep -q "$CONF_MARKER" "$PM_CONF" 2>/dev/null || \
         grep -Eq "^[[:space:]]*exclude[[:space:]]*=.*${LAB_PKG}" "$PM_CONF" 2>/dev/null; then
        fail "5/5 install: ${PM_CONF} still excludes ${LAB_PKG}."
    elif ! rpm -q "$LAB_PKG" >/dev/null 2>&1; then
        fail "5/5 install: ${LAB_PKG} is not installed yet. Run: ${PM} install -y ${LAB_PKG}"
    elif grep -Eq '^[[:space:]]*gpgcheck[[:space:]]*=[[:space:]]*0' "$PM_CONF" 2>/dev/null; then
        fail "5/5 install: ${LAB_PKG} is installed but gpgcheck was globally disabled in ${PM_CONF}."
    else
        ok "5/5 install: ${LAB_PKG} installed with signature checking enabled."
        passed=$((passed+1))
    fi

    rule
    if [[ "$passed" -eq "$total" ]]; then
        printf '%sRESULT: %d/%d - system restored. Objective 102.5 met.%s\n\n' "$C_GRN" "$passed" "$total" "$C_OFF"
        return 0
    fi
    printf '%sRESULT: %d/%d - keep working. Hints: %s hint%s\n\n' "$C_YEL" "$passed" "$total" "$SCRIPT_NAME" "$C_OFF"
    return 1
}

cmd_hint() {
    detect_pm
    load_state || die "No lab state found."
    title "HINTS (no answers)"
    cat <<EOF
  1) rpm reads macros from several places and the LAST definition wins.
       rpm --showrc | grep -i '_dbpath'
       rpm -E '%_dbpath'
     Where can a macro named %_dbpath be defined? Check /usr/lib/rpm/macros,
     /usr/lib/rpm/macros.d/, /etc/rpm/macros.* and ~/.rpmmacros. One of those
     files is younger than the others:
       ls -lt /etc/rpm/

  2) Compare the repository definition with what the distribution ships.
       ${PM} repolist --all
       grep -n . ${REPO_FILE:-/etc/yum.repos.d/*.repo}
     A repository normally uses metalink or mirrorlist, not a hand-written
     baseurl on loopback. The original lines were not deleted - look closely.
     ${PM} repoquery / ${PM} config-manager --set-enabled are your friends.

  3) 'NOKEY' and 'Public key ... is not installed' are rpm telling you the
     signing key is missing from the database, not from the disk.
       rpm -q gpg-pubkey --qf '%{VERSION}-%{RELEASE} %{SUMMARY}\n'
       ls -l /etc/pki/rpm-gpg/

  4) rpm knows the exact mode every file should have.
       rpm -Vf \$(command -v passwd)
       rpm -q --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' ${PASSWD_PKG:-passwd} | grep passwd
     There is a single rpm subcommand that puts the permissions back without
     you typing an octal mode.

  5) An exclusion can live in the main configuration file, in a repository
     section, or in a ${PM} plugin.
       grep -rn '^[[:space:]]*exclude' ${PM_CONF} /etc/yum.repos.d/
       ${PM} repoquery ${LAB_PKG:-<pkg>}      # visible in the repo...
       ${PM} list --available ${LAB_PKG:-<pkg>}  # ...but not installable
     --disableexcludes=all proves the diagnosis; it is NOT the repair.
EOF
    rule
}

cmd_restore() {
    detect_pm
    load_state || die "No lab state found. Nothing to restore."

    if [[ "$ASSUME_YES" != "yes" ]]; then
        printf 'Undo every injected fault and end the exercise? [y/N] '
        local r=""; read -r r || true
        [[ "$r" == "y" || "$r" == "Y" ]] || die "Aborted."
    fi

    title "RESTORING"

    # Fault 1 first: nothing else works while the rpmdb is unreachable.
    if [[ -f "$MACRO_FILE" ]]; then
        rm -f "$MACRO_FILE" && ok "Removed ${MACRO_FILE}."
    fi
    rm -rf "$BROKEN_DBPATH"

    local b orig
    for b in "$BACKUP_DIR"/_*; do
        [[ -e "$b" ]] || continue
        orig="$(printf '%s' "${b##*/}" | tr '_' '/')"
        if [[ -e "$orig" ]]; then
            cat "$b" >"$orig" && ok "Restored ${orig}."
        fi
    done

    local k
    for k in "$BACKUP_DIR"/gpg-pubkey-*.asc; do
        [[ -e "$k" ]] || continue
        rpm --import "$k" >/dev/null 2>&1 && ok "Re-imported $(basename "$k" .asc)."
    done

    if [[ -n "${PASSWD_BIN:-}" && -e "${PASSWD_BIN}" ]]; then
        chmod u+s "$PASSWD_BIN" && ok "Restored setuid bit on ${PASSWD_BIN}."
    fi

    F1=0; F2=0; F3=0; F4=0; F5=0; GPG_KEYS=""; BROKEN_AT=""
    save_state

    rule
    info "Sanity check:"
    printf '  rpm -E %%_dbpath -> %s\n' "$(rpm -E '%_dbpath')"
    printf '  rpm -qa | wc -l  -> %s\n' "$(rpm -qa 2>/dev/null | wc -l)"
    printf '  gpg-pubkey       -> %s key(s)\n' "$(rpm -q gpg-pubkey 2>/dev/null | grep -c '^gpg-pubkey' || true)"
    rule
    ok "Restore finished. Backups kept in ${BACKUP_DIR} - delete ${LAB_ROOT} when done."
}

usage() {
    cat <<EOF
${SCRIPT_NAME} - LPIC-1 102.5 (RPM / YUM-DNF) break & fix laboratory

  ${SCRIPT_NAME} break   [--yes] [--skip-baseline]   inject the faults
  ${SCRIPT_NAME} status                              show which faults are active
  ${SCRIPT_NAME} verify                              grade the repair
  ${SCRIPT_NAME} hint                                diagnostic hints, no answers
  ${SCRIPT_NAME} restore [--yes]                     undo everything

Run on a disposable VM only. Root required.
EOF
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
main() {
    local action="${1:-}"
    [[ $# -gt 0 ]] && shift
    local a
    for a in "$@"; do
        case "$a" in
            --yes|-y)        ASSUME_YES="yes" ;;
            --skip-baseline) SKIP_BASELINE="yes" ;;
            *) die "Unknown option: ${a}" ;;
        esac
    done

    mkdir -p "$LAB_ROOT" 2>/dev/null || true

    case "$action" in
        break)   cmd_break ;;
        status)  cmd_status ;;
        verify)  cmd_verify ;;
        hint)    cmd_hint ;;
        restore) cmd_restore ;;
        -h|--help|help|"") usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

# =============================================================================
#  SOLUTION - do not read before you have tried, and failed, on your own.
# =============================================================================
#
#  GENERAL METHOD
#  --------------
#  Fix in dependency order. rpm(8) is the foundation: dnf/yum are Python (or
#  C++, in dnf5) front ends built on top of librpm, so if librpm cannot open
#  the database, every higher-level diagnosis is noise. Then repositories
#  (where packages come from), then trust (GPG), then policy (exclude), then
#  on-disk integrity.
#
#  ---------------------------------------------------------------------------
#  FAULT 1 - rpm cannot open its database (%_dbpath override)
#  ---------------------------------------------------------------------------
#  Symptom
#      # rpm -qa | wc -l
#      error: cannot open /var/lib/rpm.lpic1-102.5.missing/Packages index using
#             sqlite: No such file or directory
#      0
#      # dnf list --installed
#      Error: Could not open the rpmdb ...
#
#  Diagnosis
#      # rpm -E '%_dbpath'
#      /var/lib/rpm.lpic1-102.5.missing
#
#      %_dbpath is an RPM macro, not a compiled-in constant. rpm evaluates its
#      macro files in this order (see `rpm --showrc | head -20`):
#          /usr/lib/rpm/macros
#          /usr/lib/rpm/macros.d/macros.*
#          /usr/lib/rpm/platform/<target>/macros
#          /etc/rpm/macros.*          <-- our override lives here
#          /etc/rpm/macros
#          /etc/rpm/<target>/macros
#          ~/.rpmmacros
#      The LAST definition wins, so anything under /etc/rpm beats the
#      distribution defaults.
#
#      # rpm --showrc | grep -i '_dbpath'
#      -14: _dbpath   /var/lib/rpm.lpic1-102.5.missing
#      # ls -lt /etc/rpm/
#      -rw-r--r--. 1 root root 210 ... macros.zz-lpic1-102.5
#      # cat /etc/rpm/macros.zz-lpic1-102.5
#
#      Confirm the real database is untouched (it is - only the pointer moved):
#      # ls -l /var/lib/rpm/
#      # rpm -qa --dbpath /var/lib/rpm | wc -l
#      532
#
#  Repair
#      # rm -f /etc/rpm/macros.zz-lpic1-102.5
#      # rpm -E '%_dbpath'
#      /var/lib/rpm
#      # rpm -qa | wc -l
#      532
#
#      If the database had genuinely been corrupted (stale __db.* locks on the
#      old Berkeley DB backend, an interrupted transaction, a full /var):
#      # cp -a /var/lib/rpm /var/lib/rpm.bak-$(date +%F)
#      # rm -f /var/lib/rpm/__db.*        # BDB backend only (EL7 era)
#      # rpm --rebuilddb -vv
#      On EL9+/Fedora the backend is sqlite (%_db_backend sqlite):
#      # sqlite3 /var/lib/rpm/rpmdb.sqlite 'PRAGMA integrity_check;'
#
#  ---------------------------------------------------------------------------
#  FAULT 2 - repository metadata cannot be downloaded
#  ---------------------------------------------------------------------------
#  Symptom
#      # dnf makecache --refresh
#      Errors during downloading metadata for repository 'baseos':
#        - Curl error (7): Couldn't connect to server for
#          http://127.0.0.1:9/lpic1-102.5/broken/os/repodata/repomd.xml
#      Error: Failed to download metadata for repo 'baseos'
#
#  Diagnosis
#      # dnf repolist --all
#      # dnf config-manager --dump baseos | grep -E 'baseurl|metalink|mirrorlist'
#      # grep -n . /etc/yum.repos.d/<distro>.repo
#      12:[baseos]
#      13:baseurl=http://127.0.0.1:9/lpic1-102.5/broken/os/
#      ...
#      17:#lpic1-102.5-disabled mirrorlist=https://mirrors.rockylinux.org/...
#
#      The original metadata source was commented out, not deleted. A
#      hand-written baseurl pointing at loopback is never a distribution
#      default: base repositories use metalink (Fedora) or mirrorlist (EL).
#
#  Repair (option A - edit the file back to its shipped state)
#      # cp /etc/yum.repos.d/<distro>.repo{,.bak}
#      # sed -i -e '/^baseurl=http:\/\/127\.0\.0\.1:9\//d' \
#               -e 's/^#lpic1-102\.5-disabled //' /etc/yum.repos.d/<distro>.repo
#
#  Repair (option B - reinstall the file from its owning package, the robust way)
#      # rpm -qf /etc/yum.repos.d/<distro>.repo
#      rocky-repos-9.x-...
#      # rpm -V rocky-repos
#      S.5....T.  c /etc/yum.repos.d/rocky.repo
#      # dnf reinstall -y rocky-repos          # .rpmorig/.rpmnew handling applies
#      or, without touching the package:
#      # dnf download rocky-repos && rpm2cpio rocky-repos-*.rpm | \
#            cpio -idmv ./etc/yum.repos.d/rocky.repo
#
#  Validate
#      # dnf clean all && rm -rf /var/cache/dnf/*
#      # dnf makecache --refresh
#      # dnf repolist --enabled
#      repo id      repo name
#      appstream    Rocky Linux 9 - AppStream
#      baseos       Rocky Linux 9 - BaseOS
#
#  ---------------------------------------------------------------------------
#  FAULT 3 - the signing key is gone from the RPM database
#  ---------------------------------------------------------------------------
#  Symptom
#      # dnf install -y tree
#      warning: /var/cache/dnf/.../tree-2.1.0-2.el9.x86_64.rpm: Header V4
#               RSA/SHA256 Signature, key ID 350d275d: NOKEY
#      Public key for tree-2.1.0-2.el9.x86_64.rpm is not installed. Failing
#      package is: tree-2.1.0-2.el9.x86_64
#      GPG Keys are configured as: file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
#
#  Diagnosis
#      Imported keys are stored as pseudo-packages named gpg-pubkey in the
#      rpmdb; the armoured key itself is the package description.
#      # rpm -q gpg-pubkey
#      package gpg-pubkey is not installed        <-- the trust store is empty
#      # ls -l /etc/pki/rpm-gpg/                  <-- but the key files exist
#      # rpm -K /var/cache/dnf/*/packages/tree-*.rpm
#      tree-2.1.0-2.el9.x86_64.rpm: digests SIGNATURES NOT OK
#
#  Repair
#      # rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-*
#      # rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n'
#      gpg-pubkey-350d275d-65e4b7a5   gpg(Rocky Linux 9 Official Signing Key)
#      # rpm -qi gpg-pubkey-350d275d-65e4b7a5     # full armoured key + fingerprint
#      # rpm -K /var/cache/dnf/*/packages/tree-*.rpm
#      tree-2.1.0-2.el9.x86_64.rpm: digests signatures OK
#
#      Never "solve" this with --nogpgcheck or gpgcheck=0: that turns a trust
#      failure into a silent supply-chain hole. Always compare the fingerprint
#      against the vendor's published value before importing.
#
#  ---------------------------------------------------------------------------
#  FAULT 4 - an installed file no longer matches the package metadata
#  ---------------------------------------------------------------------------
#  Symptom
#      $ passwd                       (as an unprivileged user)
#      passwd: Authentication token manipulation error
#
#  Diagnosis
#      # rpm -Va | head
#      .M.......    /usr/bin/passwd
#      # rpm -Vf /usr/bin/passwd
#      .M.......    /usr/bin/passwd
#      # rpm -qf /usr/bin/passwd
#      passwd-0.80-12.el9.x86_64
#      # ls -l /usr/bin/passwd
#      -rwxr-xr-x. 1 root root 32552 ... /usr/bin/passwd     <-- setuid gone
#      # rpm -q --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' passwd | grep passwd
#      -rwsr-xr-x /usr/bin/passwd                            <-- what it should be
#
#      'M' means the mode differs; the leading dot in position 3 means the
#      content digest is still correct, so the binary itself was not tampered
#      with - only its permission bits.
#
#  Repair (preferred: let rpm apply its own metadata, no octal typing)
#      # rpm --restore passwd            # rpm >= 4.17 (EL9, Fedora)
#      # rpm --setperms passwd           # older rpm (EL7/EL8)
#      # rpm -V passwd                   # no output == clean
#      # ls -l /usr/bin/passwd
#      -rwsr-xr-x. 1 root root 32552 ... /usr/bin/passwd
#
#      Manual equivalent (know it, but prefer the above):
#      # chmod 4755 /usr/bin/passwd
#
#      If the digest had also changed (S.5....T.), the file content itself is
#      wrong and permissions are not enough:
#      # dnf reinstall -y passwd
#
#  ---------------------------------------------------------------------------
#  FAULT 5 - a package that exists in the repository cannot be installed
#  ---------------------------------------------------------------------------
#  Symptom
#      # dnf install tree
#      No match for argument: tree
#      Error: Unable to find a match: tree
#
#  Diagnosis
#      The package IS in the metadata, so this is a client-side policy, not a
#      missing package:
#      # dnf repoquery tree
#      tree-0:2.1.0-2.el9.x86_64
#      # dnf --disableexcludes=all list --available tree     # works -> exclusion
#      # grep -rn '^[[:space:]]*exclude' /etc/dnf/dnf.conf /etc/yum.repos.d/
#      /etc/dnf/dnf.conf:6:exclude=tree*
#      # dnf config-manager --dump | grep -i exclude
#
#      exclude= in the [main] section of dnf.conf/yum.conf applies globally;
#      the same key inside a [repo] section applies to that repository only.
#      versionlock and other plugins can produce an identical symptom:
#      # dnf versionlock list ; ls /etc/dnf/plugins/
#
#  Repair
#      # cp /etc/dnf/dnf.conf{,.bak}
#      # sed -i '/^exclude=tree\*/d;/lpic1-102.5 lab marker/d' /etc/dnf/dnf.conf
#      # dnf clean expire-cache
#      # dnf list --available tree
#      Available Packages
#      tree.x86_64            2.1.0-2.el9            baseos
#
#  ---------------------------------------------------------------------------
#  FINAL VALIDATION
#  ---------------------------------------------------------------------------
#      # rpm -E '%_dbpath'                       -> /var/lib/rpm
#      # rpm -qa | wc -l                         -> 532
#      # dnf repolist --enabled                  -> base repositories listed
#      # rpm -q gpg-pubkey | wc -l               -> >= 1
#      # rpm -V passwd                           -> (no output)
#      # dnf install -y tree                     -> Complete!
#      # rpm -q tree && rpm -qi tree | head -12
#      # rpm -ql tree ; rpm -qc tree ; rpm -qd tree
#      # dnf history                             -> the transaction is recorded
#      # ./lpic1-102.5-rpm-yum-breakfix.sh verify
#      RESULT: 5/5 - system restored. Objective 102.5 met.
#
#      Roll back the whole exercise (and remove the lab package) with:
#      # ./lpic1-102.5-rpm-yum-breakfix.sh restore
#      # dnf history undo last          # or: dnf remove -y tree
#      # rm -rf /var/tmp/lpic1-102.5-breakfix
#
#  ---------------------------------------------------------------------------
#  WHY EACH FAULT MATTERS IN PRODUCTION
#  ---------------------------------------------------------------------------
#   1. %_dbpath / rpmdb corruption is the classic aftermath of a full /var, a
#      container image built with two different rpm backends, or a restore that
#      copied /etc/rpm from another host. Symptom: "the server thinks nothing
#      is installed".
#   2. A hard-coded baseurl that survives a distribution major upgrade is the
#      single most common cause of "dnf update stopped working" after a
#      release rebase - $releasever no longer resolves to a live mirror path.
#   3. Missing gpg-pubkey entries appear on golden images built with
#      --nogpgcheck. The fleet then installs unverified packages for years.
#      `rpm -qa gpg-pubkey` belongs in your compliance baseline.
#   4. `rpm -Va` is a poor man's host IDS: it compares every installed file
#      against the signed package metadata. Run it from a rescue environment
#      when you suspect compromise, and remember it trusts the local rpmdb -
#      which an attacker with root can rewrite.
#   5. A stale exclude= (usually added to freeze a kernel during an incident
#      and never removed) silently keeps hosts unpatched. Audit exclude= and
#      versionlock entries the same way you audit firewall rules.
# =============================================================================