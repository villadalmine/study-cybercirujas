#!/usr/bin/env bash
#
# lab-107.3-break-and-fix.sh
#
# LPIC-1 (exams 101-500 / 102-500, version 5.0)
# Topic 107.3 -- Localisation and internationalisation   (exam weight: 0)
#
# Reference: https://www.lpi.org/our-certifications/exam-101-objectives/
#            https://www.lpi.org/our-certifications/exam-102-objectives/
#
# WHAT THIS IS
#   A controlled "break & fix" drill. It sabotages the locale, timezone and
#   character-encoding configuration of a THROWAWAY lab VM, tells the student
#   what symptoms to expect and what has to be true again for the drill to be
#   considered solved, and ships a self-grader (--verify).
#
#   Everything it touches is backed up first under /var/backups/lab-107.3,
#   and --restore puts the machine back. The step-by-step solution is at the
#   bottom of this file, commented out.
#
# RUN THIS ONLY ON A DISPOSABLE LAB VM OR CONTAINER. NEVER ON A REAL HOST.
#
#   sudo ./lab-107.3-break-and-fix.sh            # break it, then print the briefing
#   sudo ./lab-107.3-break-and-fix.sh --brief    # print the briefing again
#   sudo ./lab-107.3-break-and-fix.sh --verify   # grade your fix
#   sudo ./lab-107.3-break-and-fix.sh --restore  # emergency undo (last resort)
#
set -euo pipefail

BACKUP_DIR=/var/backups/lab-107.3
MANIFEST="$BACKUP_DIR/manifest.txt"
STATE="$BACKUP_DIR/state.env"
LAB_DIR=/srv/lab107.3
CSV="$LAB_DIR/inventory.csv"
PROFILE_SNIPPET=/etc/profile.d/00-lab-107-3.sh

# Targets the student must reach.
TARGET_LANG="en_US.UTF-8"
TARGET_EXTRA_LOCALE="es_AR.UTF-8"
TARGET_TZ="Europe/Madrid"

# What we sabotage things into.
BOGUS_LOCALE="en_XX.UTF-8"
WRONG_TZ="Pacific/Kiritimati"     # UTC+14, impossible to miss
WRONG_TZ_ENV="Asia/Kolkata"       # UTC+05:30, half-hour offset, leaked via TZ

if [ -t 1 ]; then
    B=$'\033[1m'; R=$'\033[0m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
else
    B=""; R=""; RED=""; GRN=""; YEL=""
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s== %s ==%s\n' "$B" "$*" "$R"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$R" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" = "0" ] || die "This script must run as root (try: sudo $0 $*)."
}

detect_family() {
    local id="" like=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"; like="${ID_LIKE:-}"
    fi
    case " ${id} ${like} " in
        *debian*|*ubuntu*)          echo debian ;;
        *rhel*|*fedora*|*centos*)   echo rhel ;;
        *suse*)                     echo suse ;;
        *arch*)                     echo arch ;;
        *)                          echo other ;;
    esac
}
FAMILY="$(detect_family)"

has_systemd() { [ -d /run/systemd/system ] && command -v timedatectl >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Backup / restore plumbing
# ---------------------------------------------------------------------------
backup_path() { printf '%s/%s' "$BACKUP_DIR" "$(printf '%s' "$1" | tr '/' '%')"; }

save_file() {
    local p="$1"
    mkdir -p "$BACKUP_DIR"
    touch "$MANIFEST"
    if grep -qxF -- "F $p" "$MANIFEST" || grep -qxF -- "N $p" "$MANIFEST"; then
        return 0                       # already recorded: keep the pristine copy
    fi
    if [ -e "$p" ] || [ -L "$p" ]; then
        cp -a -- "$p" "$(backup_path "$p")"
        printf 'F %s\n' "$p" >> "$MANIFEST"
    else
        printf 'N %s\n' "$p" >> "$MANIFEST"
    fi
}

restore_all() {
    [ -f "$MANIFEST" ] || die "No backup manifest at $MANIFEST -- nothing to restore."
    local kind p
    while read -r kind p; do
        [ -n "${p:-}" ] || continue
        case "$kind" in
            F) rm -rf -- "$p"; cp -a -- "$(backup_path "$p")" "$p"; say "restored  $p" ;;
            N) rm -rf -- "$p";                                      say "removed   $p" ;;
        esac
    done < "$MANIFEST"

    # Put back anything we pulled out of the locale archive.
    # shellcheck disable=SC1090
    [ -f "$STATE" ] && . "$STATE"
    if [ "${DELETED_ARCHIVE_LOCALE:-}" = "yes" ] && command -v localedef >/dev/null 2>&1; then
        say "regenerating ${TARGET_LANG} with localedef ..."
        localedef -i en_US -f UTF-8 en_US.UTF-8 || warn "localedef failed; install the locales/langpack package."
    fi
    if [ -d "$BACKUP_DIR/usr-lib-locale-en_US.utf8" ]; then
        rm -rf /usr/lib/locale/en_US.utf8
        cp -a "$BACKUP_DIR/usr-lib-locale-en_US.utf8" /usr/lib/locale/en_US.utf8
        say "restored  /usr/lib/locale/en_US.utf8"
    fi
    has_systemd && systemctl daemon-reexec >/dev/null 2>&1 || true
    say ""
    say "${GRN}Restore complete.${R} Log out and back in for a clean environment."
}

confirm_or_abort() {
    if systemd-detect-virt --quiet 2>/dev/null; then
        : # we are in a VM/container, good
    else
        warn "systemd-detect-virt says this is BARE METAL. This drill edits"
        warn "/etc/locale.conf, /etc/default/locale, /etc/environment and /etc/localtime."
    fi
    if [ "${LAB_CONFIRM:-}" = "yes" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        die "Non-interactive run. Re-run with LAB_CONFIRM=yes if this host is disposable."
    fi
    say ""
    say "${RED}${B}This will deliberately break locale and time settings on $(hostname).${R}"
    say "Backups go to $BACKUP_DIR, and --restore undoes it."
    printf 'Type exactly BREAK to continue: '
    local answer=""
    read -r answer
    [ "$answer" = "BREAK" ] || die "Aborted. Nothing was changed."
}

# ---------------------------------------------------------------------------
# The sabotage
# ---------------------------------------------------------------------------
break_locale_config() {
    head1 "Breaking the system locale"

    # Layer 1: the systemd-wide locale file, pointed at a locale that does not exist.
    save_file /etc/locale.conf
    cat > /etc/locale.conf <<EOF
# Broken on purpose by lab-107.3
LANG=$BOGUS_LOCALE
LC_ALL=$BOGUS_LOCALE
EOF
    say "  /etc/locale.conf         -> LANG/LC_ALL = $BOGUS_LOCALE"

    # Layer 2: the Debian-family file that localectl actually writes.
    if [ -d /etc/default ]; then
        save_file /etc/default/locale
        cat > /etc/default/locale <<EOF
# Broken on purpose by lab-107.3
LANG=$BOGUS_LOCALE
LC_ALL=$BOGUS_LOCALE
EOF
        say "  /etc/default/locale      -> LANG/LC_ALL = $BOGUS_LOCALE"
    fi

    # Layer 3: /etc/environment, read by PAM at login -- a classic hiding place.
    save_file /etc/environment
    touch /etc/environment
    printf 'LANG=%s\n' "$BOGUS_LOCALE" >> /etc/environment
    say "  /etc/environment         -> LANG = $BOGUS_LOCALE"

    # Layer 4: a shell profile snippet that overrides everything else, including TZ.
    save_file "$PROFILE_SNIPPET"
    cat > "$PROFILE_SNIPPET" <<EOF
# Broken on purpose by lab-107.3
export LANG=$BOGUS_LOCALE
export LC_ALL=$BOGUS_LOCALE
export LC_COLLATE=C
export TZ=$WRONG_TZ_ENV
EOF
    chmod 0644 "$PROFILE_SNIPPET"
    say "  $PROFILE_SNIPPET  -> LANG/LC_ALL/LC_COLLATE/TZ"

    # Layer 5: remove the good locale itself, but ONLY if it can be rebuilt offline.
    printf 'DELETED_ARCHIVE_LOCALE=no\n' > "$STATE"
    if [ -f /etc/locale.gen ]; then
        save_file /etc/locale.gen
        sed -i 's/^\(en_US\.UTF-8 UTF-8\)/# \1/' /etc/locale.gen
        say "  /etc/locale.gen          -> en_US.UTF-8 commented out"
    fi
    local sources_ok=no
    if [ -e /usr/share/i18n/locales/en_US ] && ls /usr/share/i18n/charmaps/UTF-8* >/dev/null 2>&1; then
        sources_ok=yes
    fi
    if [ "$sources_ok" = yes ] && locale -a 2>/dev/null | grep -qix 'en_US\.utf8'; then
        if [ -d /usr/lib/locale/en_US.utf8 ]; then
            mkdir -p "$BACKUP_DIR"
            cp -a /usr/lib/locale/en_US.utf8 "$BACKUP_DIR/usr-lib-locale-en_US.utf8"
            rm -rf /usr/lib/locale/en_US.utf8
        fi
        localedef --delete-from-archive en_US.utf8 2>/dev/null \
            || localedef --delete-from-archive en_US.UTF-8 2>/dev/null || true
        printf 'DELETED_ARCHIVE_LOCALE=yes\n' > "$STATE"
        say "  locale archive           -> en_US.UTF-8 removed (sources present, rebuildable)"
    else
        say "  locale archive           -> left alone (locale sources not installed here)"
    fi
}

break_timezone() {
    head1 "Breaking the timezone"

    local wrong="$WRONG_TZ"
    [ -f "/usr/share/zoneinfo/$wrong" ] || wrong="UTC"

    save_file /etc/localtime
    ln -sfn "/usr/share/zoneinfo/$wrong" /etc/localtime
    say "  /etc/localtime           -> $wrong"

    # Deliberate inconsistency: the Debian text file disagrees with the symlink.
    if [ "$FAMILY" = debian ] || [ -f /etc/timezone ]; then
        save_file /etc/timezone
        printf 'America/Argentina/Buenos_Aires\n' > /etc/timezone
        say "  /etc/timezone            -> America/Argentina/Buenos_Aires (mismatch on purpose)"
    fi
    say "  TZ (login env)           -> $WRONG_TZ_ENV (from $PROFILE_SNIPPET)"
}

break_encoding() {
    head1 "Planting a mis-encoded data file"

    save_file "$LAB_DIR"
    mkdir -p "$LAB_DIR"
    # Written as raw ISO-8859-1 (latin1) bytes: 0xf1=n-tilde, 0xe1=a-acute,
    # 0xf3=o-acute, 0xc1=A-acute, 0xe9=e-acute. Invalid as UTF-8.
    printf 'id,name,city,amount\n' > "$CSV"
    printf '1,Mu\xf1oz,M\xe1laga,120\n'        >> "$CSV"
    printf '2,Pe\xf1a,C\xf3rdoba,80\n'         >> "$CSV"
    printf '3,\xc1lvarez,Legan\xe9s,45\n'      >> "$CSV"
    printf '4,Ren\xe9e Dupr\xe9,Orl\xe9ans,60\n' >> "$CSV"
    printf '5,Mu\xf1oz,Sevilla,15\n'           >> "$CSV"
    chmod 0644 "$CSV"
    say "  $CSV  -> ISO-8859-1 bytes in a UTF-8 world"
}

# ---------------------------------------------------------------------------
# Briefing
# ---------------------------------------------------------------------------
briefing() {
    head1 "LPIC-1 107.3 -- Localisation and internationalisation: BREAK & FIX"
    cat <<EOF

${B}SCENARIO${R}
A colleague "tuned" this machine before going on holiday. Users now get warnings
on every login, timestamps in logs and mail headers are hours off, and the
billing team's CSV export renders as garbage in every tool that touches it.

${B}SYMPTOMS YOU SHOULD SEE${R} (log out and back in first -- some of this only
appears in a fresh login shell, because PAM reads /etc/environment and the shell
reads /etc/profile.d/*.sh):

  1. Almost any command that speaks a language complains, e.g.:
       perl: warning: Setting locale failed.
       perl: warning: Please check that your locale settings:
               LC_ALL = "$BOGUS_LOCALE", LANG = "$BOGUS_LOCALE"
           are supported and installed on your system.
       bash: warning: setlocale: LC_ALL: cannot change locale ($BOGUS_LOCALE)
     And 'locale' itself prints:
       locale: Cannot set LC_CTYPE to default locale: No such file or directory

  2. 'date' is wrong -- not by a whole number of hours, which is the tell:
     the offset is +0530, so something is exporting TZ into your session, while
     'ls -l', 'timedatectl' and cron may disagree with it. /etc/localtime,
     /etc/timezone and the TZ variable tell three different stories.

  3. sort(1) suddenly orders text bytewise (LC_COLLATE=C), so "Zebra" sorts
     before "alpha", and case-insensitive matching behaves differently.

  4. cat $CSV shows mojibake:
       Mu?oz / Mu<fd>oz / Muñoz depending on your terminal
     'grep Muñoz' returns nothing at all, although the name is clearly there.

${B}YOUR MISSION${R} -- make all five of these true, permanently (they must survive
a reboot and a fresh login), then run: ${B}sudo $0 --verify${R}

  [ ] 1. A fresh login shell produces NO locale warnings; 'locale' runs clean.
  [ ] 2. The system locale is LANG=$TARGET_LANG, and LC_ALL is set NOWHERE
         system-wide (LC_ALL is a sledgehammer: it overrides every LC_* and
         belongs in a one-off command, never in a config file).
  [ ] 3. Both $TARGET_LANG and $TARGET_EXTRA_LOCALE exist on the system, so that
             LC_TIME=$TARGET_EXTRA_LOCALE date
         prints Spanish month names without any warning.
  [ ] 4. The system timezone is $TARGET_TZ, consistently: /etc/localtime,
         /etc/timezone (if your distro uses it), timedatectl, and the environment
         of a fresh login shell all agree, and no TZ variable is being injected.
  [ ] 5. $CSV is valid UTF-8 with its content intact:
             grep -c 'Muñoz' $CSV   ->  2

${B}TOOLS THIS OBJECTIVE EXPECTS YOU TO KNOW${R}
  locale, locale -a, localedef, /etc/locale.gen + locale-gen, localectl,
  /etc/locale.conf, /etc/default/locale, /etc/environment, LANG, LC_*, LC_ALL,
  date, TZ, tzselect, timedatectl, /usr/share/zoneinfo, /etc/localtime,
  /etc/timezone, iconv, ASCII / ISO-8859 / UTF-8 / Unicode.

${B}HINTS, NOT ANSWERS${R}
  * There is more than one file setting the locale. Find them all:
      grep -rIl 'LC_ALL\\|LANG=' /etc 2>/dev/null
  * 'locale -a' lists what EXISTS; 'locale' shows what is IN EFFECT. Both matter.
  * A missing locale is generated, not installed by hand: localedef / locale-gen,
    and on RHEL-family systems glibc-langpack-<lang>.
  * 'iconv -f X -t Y' cannot guess X. Look at the raw bytes first:
      file -bi $CSV ; hexdump -C $CSV | head
  * Never redirect iconv's output onto its own input file -- you will truncate it.
  * Escape hatch if you get stuck: sudo $0 --restore

Backups of every file touched: $BACKUP_DIR
EOF
}

# ---------------------------------------------------------------------------
# Grader
# ---------------------------------------------------------------------------
PASS_N=0
FAIL_N=0
ok()   { PASS_N=$((PASS_N+1)); printf '  %s[PASS]%s %s\n' "$GRN" "$R" "$1"; }
no()   { FAIL_N=$((FAIL_N+1)); printf '  %s[FAIL]%s %s\n' "$RED" "$R" "$1"
         [ -n "${2:-}" ] && printf '         hint: %s\n' "$2"; return 0; }

login_shell() { env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/bash -l -c "$1" 2>&1 || true; }

locale_exists() {  # accepts en_US.UTF-8 or en_US.utf8 spellings
    local want norm
    want="$1"
    norm="$(printf '%s' "$want" | tr 'A-Z' 'a-z' | tr -d '-')"
    locale -a 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '-' | grep -qx "$norm"
}

lc_all_set_in_configs() {
    local f
    for f in /etc/locale.conf /etc/default/locale /etc/environment /etc/profile /etc/profile.d/*.sh \
             /etc/sysconfig/language /etc/bashrc /etc/bash.bashrc; do
        [ -f "$f" ] || continue
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?LC_ALL=' "$f"; then
            printf '%s' "$f"; return 0
        fi
    done
    return 1
}

tz_injected_in_configs() {
    local f
    for f in /etc/environment /etc/profile /etc/profile.d/*.sh /etc/bashrc /etc/bash.bashrc; do
        [ -f "$f" ] || continue
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?TZ=' "$f"; then
            printf '%s' "$f"; return 0
        fi
    done
    return 1
}

verify() {
    head1 "Grading LPIC-1 107.3 lab"

    # 1 -- a fresh login shell must be quiet.
    local out
    out="$(login_shell 'locale')"
    if printf '%s' "$out" | grep -qiE 'cannot change locale|Cannot set LC_|setlocale'; then
        no "1. Login shell still emits locale errors" \
           "run 'locale' after a fresh login and read the warning: it names the bad value"
        printf '%s\n' "$out" | sed 's/^/         > /' | head -n 6
    else
        ok "1. A fresh login shell runs 'locale' with no warnings"
    fi

    # 2 -- LANG correct, LC_ALL nowhere.
    local eff_lang eff_lcall culprit
    eff_lang="$(login_shell 'printf %s "${LANG-}"')"
    eff_lcall="$(login_shell 'printf %s "${LC_ALL-}"')"
    if [ "$(printf '%s' "$eff_lang" | tr 'A-Z' 'a-z' | tr -d '-')" = "$(printf '%s' "$TARGET_LANG" | tr 'A-Z' 'a-z' | tr -d '-')" ]; then
        ok "2a. LANG is $TARGET_LANG in a login shell"
    else
        no "2a. LANG in a login shell is '${eff_lang:-<unset>}', expected $TARGET_LANG" \
           "set it in the system locale file, not in ~/.bashrc"
    fi
    if [ -n "$eff_lcall" ]; then
        no "2b. LC_ALL is still exported as '$eff_lcall'" "unset it and remove it from the config that sets it"
    elif culprit="$(lc_all_set_in_configs)"; then
        no "2b. LC_ALL is still configured in $culprit" "delete that line; LC_ALL overrides every other LC_*"
    else
        ok "2b. LC_ALL is not set anywhere system-wide"
    fi
    if grep -qE "$BOGUS_LOCALE" /etc/locale.conf /etc/default/locale /etc/environment 2>/dev/null; then
        no "2c. The bogus locale $BOGUS_LOCALE is still referenced in /etc" \
           "grep -rIl '$BOGUS_LOCALE' /etc"
    else
        ok "2c. No reference to the bogus locale $BOGUS_LOCALE remains in /etc"
    fi

    # 3 -- both locales must exist and actually work.
    if locale_exists "$TARGET_LANG"; then
        ok "3a. $TARGET_LANG exists (locale -a)"
    else
        no "3a. $TARGET_LANG is missing from 'locale -a'" \
           "generate it: localedef -i en_US -f UTF-8 en_US.UTF-8   (or locale-gen)"
    fi
    if locale_exists "$TARGET_EXTRA_LOCALE"; then
        local months
        months="$(LC_ALL=C LC_TIME="$TARGET_EXTRA_LOCALE" date -d 2026-01-15 +%B 2>&1 || true)"
        ok "3b. $TARGET_EXTRA_LOCALE exists (LC_TIME test prints: ${months})"
    else
        no "3b. $TARGET_EXTRA_LOCALE is missing from 'locale -a'" \
           "localedef -i es_AR -f UTF-8 es_AR.UTF-8   (RHEL: dnf install glibc-langpack-es)"
    fi

    # 4 -- timezone consistency across every source of truth.
    local link_tz sd_tz file_tz env_tz want_off got_off
    link_tz="$(readlink -f /etc/localtime 2>/dev/null || true)"
    link_tz="${link_tz#/usr/share/zoneinfo/}"
    if [ "$link_tz" = "$TARGET_TZ" ]; then
        ok "4a. /etc/localtime points at $TARGET_TZ"
    else
        no "4a. /etc/localtime resolves to '${link_tz:-?}', expected $TARGET_TZ" \
           "timedatectl set-timezone $TARGET_TZ   (or: ln -sfn /usr/share/zoneinfo/$TARGET_TZ /etc/localtime)"
    fi
    if has_systemd; then
        sd_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
        if [ "$sd_tz" = "$TARGET_TZ" ]; then
            ok "4b. timedatectl reports $TARGET_TZ"
        else
            no "4b. timedatectl reports '${sd_tz:-?}', expected $TARGET_TZ" "timedatectl set-timezone $TARGET_TZ"
        fi
    else
        ok "4b. (no systemd here -- timedatectl check skipped)"
    fi
    if [ -f /etc/timezone ]; then
        file_tz="$(tr -d '[:space:]' < /etc/timezone)"
        if [ "$file_tz" = "$TARGET_TZ" ]; then
            ok "4c. /etc/timezone agrees: $TARGET_TZ"
        else
            no "4c. /etc/timezone says '${file_tz:-empty}', expected $TARGET_TZ" \
               "on Debian family: dpkg-reconfigure tzdata, or write the zone name into the file"
        fi
    else
        ok "4c. (this distro has no /etc/timezone -- check skipped)"
    fi
    if env_tz="$(tz_injected_in_configs)"; then
        no "4d. A TZ variable is still injected by $env_tz" \
           "the system timezone belongs in /etc/localtime, not in a profile script"
    else
        env_tz="$(login_shell 'printf %s "${TZ-}"')"
        if [ -n "$env_tz" ]; then
            no "4d. TZ is still exported as '$env_tz' in a login shell" "find and remove it"
        else
            ok "4d. No TZ variable leaks into a login shell"
        fi
    fi
    want_off="$(TZ="$TARGET_TZ" date +%z)"
    got_off="$(login_shell 'date +%z')"
    if [ "$want_off" = "$got_off" ]; then
        ok "4e. 'date' in a login shell shows the right offset ($got_off)"
    else
        no "4e. 'date' shows offset $got_off, expected $want_off for $TARGET_TZ" \
           "compare: date ; TZ=$TARGET_TZ date"
    fi

    # 5 -- the CSV must be valid UTF-8 AND still contain the original names.
    if [ ! -f "$CSV" ]; then
        no "5. $CSV is gone" "you deleted the data instead of converting it; --restore and try again"
    elif ! iconv -f UTF-8 -t UTF-8 "$CSV" >/dev/null 2>&1; then
        no "5a. $CSV is not valid UTF-8" \
           "iconv -f ISO-8859-1 -t UTF-8 $CSV > /tmp/fixed && mv /tmp/fixed $CSV"
    else
        ok "5a. $CSV is valid UTF-8"
        local n
        n="$(LC_ALL=$TARGET_LANG grep -c 'Muñoz' "$CSV" 2>/dev/null || true)"
        if [ "${n:-0}" = "2" ]; then
            ok "5b. grep -c 'Muñoz' returns 2 -- content survived the conversion"
        else
            no "5b. grep -c 'Muñoz' returns ${n:-0}, expected 2" \
               "converting is not the same as stripping accents; do not use tr or sed for this"
        fi
    fi

    say ""
    if [ "$FAIL_N" -eq 0 ]; then
        say "${GRN}${B}ALL $PASS_N CHECKS PASSED.${R} Objective 107.3 drill complete."
        say "Reboot and run --verify once more if you want to prove it is persistent."
    else
        say "${YEL}$PASS_N passed, $FAIL_N still failing.${R} Fix and re-run: sudo $0 --verify"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    case "${1:---break}" in
        --verify)
            require_root
            verify
            ;;
        --brief|--briefing)
            briefing
            ;;
        --restore)
            require_root
            restore_all
            ;;
        --break)
            require_root
            confirm_or_abort
            mkdir -p "$BACKUP_DIR"; chmod 0700 "$BACKUP_DIR"; touch "$MANIFEST"
            break_locale_config
            break_timezone
            break_encoding
            has_systemd && systemctl daemon-reexec >/dev/null 2>&1 || true
            briefing
            say ""
            say "${B}Now log out and log back in, then start diagnosing.${R}"
            ;;
        -h|--help)
            sed -n '3,30p' "$0"
            ;;
        *)
            die "Unknown option '$1'. Try --help."
            ;;
    esac
}

main "$@"
exit 0

# ===========================================================================
#  S O L U T I O N   --   do not read until you have tried
# ===========================================================================
#
# The whole drill is one idea in three coats of paint: locale and time are
# resolved from LAYERS, and the innermost layer that is set wins. Fixing the
# outer layer while an inner one still shouts is why this feels unfixable.
#
#   Locale precedence (highest first):
#       LC_ALL  >  LC_<CATEGORY>  >  LANG   ... and per process:
#       shell profile export  >  PAM /etc/environment  >  /etc/locale.conf
#   Timezone precedence:
#       TZ environment variable  >  /etc/localtime  (the glibc symlink)
#       /etc/timezone is only a text label used by Debian tooling; systemd's
#       timedatectl reads the /etc/localtime symlink target.
#
# ---------------------------------------------------------------------------
# STEP 0 -- see the whole picture before changing anything
# ---------------------------------------------------------------------------
#   locale                       # what is IN EFFECT (and it will complain)
#   locale -a | less             # what EXISTS on this system
#   echo "$LANG $LC_ALL $TZ"
#   grep -rIn 'LC_ALL\|LANG=\|^TZ=\|export TZ' /etc 2>/dev/null
#   ls -l /etc/localtime ; cat /etc/timezone 2>/dev/null ; timedatectl
#   file -bi /srv/lab107.3/inventory.csv ; hexdump -C /srv/lab107.3/inventory.csv | head -3
#
#   The grep is the money command: it finds all four locale layers at once
#   (/etc/locale.conf, /etc/default/locale, /etc/environment,
#   /etc/profile.d/00-lab-107-3.sh).
#
# ---------------------------------------------------------------------------
# STEP 1 -- make the working locale exist again
# ---------------------------------------------------------------------------
# Nothing else will hold until en_US.UTF-8 is actually present. Check first:
#   locale -a | grep -i 'en_US'
#
# Debian / Ubuntu:
#   sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
#   grep -q '^es_AR.UTF-8 UTF-8' /etc/locale.gen || echo 'es_AR.UTF-8 UTF-8' >> /etc/locale.gen
#   locale-gen
#   # equivalent interactive route: dpkg-reconfigure locales
#
# RHEL / Fedora / CentOS (locales ship as packages):
#   dnf install -y glibc-langpack-en glibc-langpack-es
#
# Any glibc system, distro-agnostic (this is what locale-gen calls underneath):
#   localedef -i en_US -f UTF-8 en_US.UTF-8
#   localedef -i es_AR -f UTF-8 es_AR.UTF-8
#     -i = input locale source under /usr/share/i18n/locales
#     -f = charmap under /usr/share/i18n/charmaps
#     final argument = the name the locale will be known by in 'locale -a'
#
# Verify:
#   locale -a | grep -Ei 'en_US|es_AR'      # expect en_US.utf8 and es_AR.utf8
#
# ---------------------------------------------------------------------------
# STEP 2 -- remove the bogus locale from every layer
# ---------------------------------------------------------------------------
# 2a. The shell profile snippet is pure sabotage; delete the file:
#   rm -f /etc/profile.d/00-lab-107-3.sh
#
# 2b. /etc/environment is read by PAM at login, so it affects even non-shell
#     sessions. Strip the bad line (leave PATH and anything else alone):
#   sed -i '/^LANG=en_XX\.UTF-8$/d' /etc/environment
#
# 2c. The system locale file. The supported way on any systemd distro:
#   localectl set-locale LANG=en_US.UTF-8
#   localectl status
#     -> localectl rewrites /etc/locale.conf, and on Debian family also
#        /etc/default/locale. It refuses to set a locale that does not exist,
#        which is exactly why STEP 1 comes first.
#
#     By hand, if localectl is unavailable:
#       printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
#       printf 'LANG=en_US.UTF-8\n' > /etc/default/locale     # Debian family
#       # SUSE keeps RC_LANG in /etc/sysconfig/language
#
# 2d. Make sure LC_ALL is set in NONE of them. LC_ALL outranks every LC_*
#     category and LANG; it is a debugging tool ("LC_ALL=C sort file"), never a
#     configuration setting:
#   grep -rn 'LC_ALL' /etc/locale.conf /etc/default/locale /etc/environment /etc/profile.d/
#   unset LC_ALL          # for the current shell
#
# Verify (a NEW login shell -- the current one still carries the old exports):
#   su - $USER -c 'locale'        # no warnings, LANG=en_US.UTF-8, LC_ALL=
#   LC_TIME=es_AR.UTF-8 date      # month name in Spanish, no warning
#   printf 'Zebra\nalpha\nÁlvarez\n' | sort    # locale collation, not byte order
#
# ---------------------------------------------------------------------------
# STEP 3 -- one timezone, agreed on by everybody
# ---------------------------------------------------------------------------
# 3a. The TZ export is already gone with the profile snippet from 2a. Confirm
#     nothing else sets it:
#   grep -rn '^ *\(export \)\?TZ=' /etc 2>/dev/null
#
# 3b. Set the real system timezone:
#   timedatectl list-timezones | grep Madrid
#   timedatectl set-timezone Europe/Madrid
#     -> this replaces the /etc/localtime symlink with
#        /usr/share/zoneinfo/Europe/Madrid. Confirm: ls -l /etc/localtime
#
#     Without systemd:
#       ln -sfn /usr/share/zoneinfo/Europe/Madrid /etc/localtime
#     Interactive helper that prints the right TZ string for a region:
#       tzselect
#
# 3c. Debian family keeps a plain-text copy that tooling reads; keep it in sync:
#   printf 'Europe/Madrid\n' > /etc/timezone
#   # or the supported route: dpkg-reconfigure tzdata
#
# 3d. Anything long-running cached the old zone. Restart or re-exec:
#   systemctl daemon-reexec ; systemctl restart cron rsyslog 2>/dev/null
#
# Verify:
#   date ; date -u ; timedatectl
#   [ "$(date +%z)" = "$(TZ=Europe/Madrid date +%z)" ] && echo TZ-OK
#     Note the hardware clock should stay UTC on a Linux-only box:
#     timedatectl set-local-rtc 0
#
# ---------------------------------------------------------------------------
# STEP 4 -- transcode the CSV, do not mutilate it
# ---------------------------------------------------------------------------
# 4a. Identify the current encoding. 'file' guesses from the byte pattern:
#   file -bi /srv/lab107.3/inventory.csv     # -> text/plain; charset=iso-8859-1
#   hexdump -C /srv/lab107.3/inventory.csv | head -3
#     0xF1 alone is n-tilde in ISO-8859-1; in UTF-8 that same character is the
#     two-byte sequence 0xC3 0xB1. A lone 0xF1 is not valid UTF-8 at all, which
#     is why grep for 'Muñoz' (UTF-8 bytes) never matches the file's bytes.
#
# 4b. Convert. iconv writes to stdout; NEVER redirect it onto its own input,
#     because the shell truncates the file before iconv reads it:
#   iconv -f ISO-8859-1 -t UTF-8 /srv/lab107.3/inventory.csv > /tmp/inventory.utf8
#   mv /tmp/inventory.utf8 /srv/lab107.3/inventory.csv
#
#     Useful variants:
#       iconv -l                       # every encoding this glibc supports
#       iconv -f ISO-8859-1 -t UTF-8//TRANSLIT  # approximate unmappable chars
#       iconv -f UTF-8 -t UTF-8 file >/dev/null # validity test: fails on bad bytes
#
# Verify:
#   file -bi /srv/lab107.3/inventory.csv     # -> charset=utf-8
#   grep -c 'Muñoz' /srv/lab107.3/inventory.csv    # -> 2
#
# ---------------------------------------------------------------------------
# STEP 5 -- prove it, then prove it survives a reboot
# ---------------------------------------------------------------------------
#   sudo ./lab-107.3-break-and-fix.sh --verify
#   reboot
#   sudo ./lab-107.3-break-and-fix.sh --verify
#
# ---------------------------------------------------------------------------
# WHAT THE EXAM ACTUALLY WANTS YOU TO CARRY OUT OF THIS
# ---------------------------------------------------------------------------
#   * LC_ALL > LC_* > LANG. Know which file each one lives in, and that LC_ALL
#     in a config file is always a bug.
#   * 'locale -a' vs 'locale': existence vs effect. A perfectly spelled locale
#     that was never generated still fails.
#   * localedef is the primitive; locale-gen / /etc/locale.gen (Debian) and
#     glibc-langpack-* (RHEL) are distro wrappers around it.
#   * The timezone is the /etc/localtime symlink into /usr/share/zoneinfo.
#     /etc/timezone is a Debian label. TZ in the environment beats both, per
#     process -- which is what makes it such a good disguise for a bug.
#   * ASCII is 7-bit; ISO-8859-x are single-byte 8-bit sets, one per region;
#     UTF-8 is a variable-length encoding of the full Unicode set, ASCII-
#     compatible for the first 128 code points. iconv converts between them and
#     needs you to state the source encoding, because bytes carry no label.
#
# Sources:
#   https://www.lpi.org/our-certifications/exam-101-objectives/
#   https://www.gnu.org/software/libc/manual/html_node/Locales.html
#   man 1 locale ; man 1 localedef ; man 5 locale.conf ; man 1 localectl
#   man 1 timedatectl ; man 3 tzset ; man 1 iconv ; man 7 charsets ; man 7 utf-8
# ===========================================================================