#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-3 303 Security  (exam 303-300, version 3.0.0)
#  Topic 333.1 - Discretionary Access Control       (exam weight: 5)
#  Objectives: https://www.lpi.org/our-certifications/exam-303-objectives/
#
#  BREAK & FIX LAB: file/directory permissions, SUID/SGID/sticky, POSIX ACLs,
#                   ACL mask, default ACLs, umask, extended attributes.
# ==============================================================================
#
#  *** DESTRUCTIVE BY DESIGN. DISPOSABLE LAB VM / THROWAWAY CONTAINER ONLY. ***
#
#  What this script touches, and nothing else:
#    - /srv/dac-lab                     (created, then wrecked, then removed)
#    - /etc/profile.d/99-dac-lab-umask.sh
#    - local users  dac-alice, dac-bob  and groups  dacteam, dacapp, dacsecret
#
#  It creates a world-executable SGID copy of /usr/bin/cat owned by group
#  "dacsecret". That is a real (if contained) privilege gadget: any local user
#  can read files whose group is dacsecret. Only fake lab files are in that
#  group, and "--cleanup" removes the binary. Do not run this on a machine you
#  care about.
#
#  Usage:
#    ./333.1-dac-break-fix.sh                # build the lab and break it
#    ./333.1-dac-break-fix.sh --verify       # grade your repair
#    ./333.1-dac-break-fix.sh --solution     # print the answer key
#    ./333.1-dac-break-fix.sh --cleanup      # remove every artifact
#
#  Non-interactive confirmation:  DAC_LAB_CONFIRM=yes ./333.1-dac-break-fix.sh
# ==============================================================================

set -euo pipefail

LAB_ROOT=/srv/dac-lab
MARKER="${LAB_ROOT}/.dac-lab-marker"
APOLLO="${LAB_ROOT}/projects/apollo"
REPORT="${LAB_ROOT}/reports/q3-summary.txt"
APPCONF="${LAB_ROOT}/etc/app.conf"
HELPER="${LAB_ROOT}/bin/showsecret"
TOKEN="${LAB_ROOT}/secret/token.txt"
DROPIN=/etc/profile.d/99-dac-lab-umask.sh

LAB_USERS=(dac-alice dac-bob)
LAB_GROUPS=(dacteam dacapp dacsecret)

CHECK_FAILED=0
IMMUTABLE_SUPPORTED=1

# ------------------------------------------------------------------ helpers --

die()  { printf '\nERROR: %s\n' "$1" >&2; exit 1; }
note() { printf '  -> %s\n' "$1"; }
pass() { printf '  [ PASS ] %s\n' "$1"; }
fail() { printf '  [ FAIL ] %s\n' "$1"; printf '           hint: %s\n' "$2"; CHECK_FAILED=1; }

# Run a command string as a lab user in a LOGIN shell, so that /etc/profile.d
# (the umask drop-in) and the supplementary group list are actually applied.
as_user() {
    local user=$1 cmd=$2
    if command -v runuser >/dev/null 2>&1; then
        runuser -l "$user" -c "$cmd"
    else
        su -l "$user" -c "$cmd"
    fi
}

require_root() {
    [[ $(id -u) -eq 0 ]] || die "run this as root (uid 0); DAC repair needs it."
}

require_tools() {
    local missing=()
    for t in setfacl getfacl chattr lsattr useradd groupadd stat; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "missing tools: ${missing[*]}
       Debian/Ubuntu: apt-get install acl e2fsprogs
       RHEL/Fedora:   dnf install acl e2fsprogs"
    fi
}

require_acl_filesystem() {
    local probe
    mkdir -p "${LAB_ROOT}"
    probe=$(mktemp "${LAB_ROOT}/.acl-probe.XXXXXX")
    if ! setfacl -m u:root:rw "$probe" 2>/dev/null; then
        rm -f "$probe"
        die "the filesystem holding ${LAB_ROOT} does not support POSIX ACLs.
       Check with:  mount | grep ' / '   and remount with the 'acl' option
       (ext4/xfs/btrfs enable ACLs by default; tmpfs does not support them)."
    fi
    rm -f "$probe"
}

require_disposable_vm() {
    if [[ "${DAC_LAB_CONFIRM:-}" == "yes" ]]; then return 0; fi
    printf '\n'
    printf 'This script creates local users and DELIBERATELY BREAKS permissions\n'
    printf 'under %s. Use a disposable lab VM only.\n\n' "${LAB_ROOT}"
    [[ -t 0 ]] || die "no TTY. Re-run with DAC_LAB_CONFIRM=yes if this really is a lab VM."
    local answer
    read -r -p 'Type BREAK to continue, anything else to abort: ' answer
    [[ "$answer" == "BREAK" ]] || die "aborted by the operator. Nothing was changed."
}

# -------------------------------------------------------------------- setup --

setup_lab() {
    printf '\n== Building the lab ==\n'

    for g in "${LAB_GROUPS[@]}"; do
        getent group "$g" >/dev/null || groupadd "$g"
    done
    for u in "${LAB_USERS[@]}"; do
        getent passwd "$u" >/dev/null || useradd -m -s /bin/bash "$u"
    done
    # Both engineers are in the project group and may call the helper binary.
    # Neither of them is in dacsecret: that is the whole point of the SGID bit.
    usermod -aG dacteam,dacapp dac-alice
    usermod -aG dacteam,dacapp dac-bob

    mkdir -p "${APOLLO}" "${LAB_ROOT}/reports" "${LAB_ROOT}/etc" \
             "${LAB_ROOT}/bin" "${LAB_ROOT}/secret"
    : > "${MARKER}"
    chmod 0755 "${LAB_ROOT}" "${LAB_ROOT}/projects" "${LAB_ROOT}/bin"

    # --- known-good state #1: shared team directory ---------------------------
    # SGID (2770) makes every new entry inherit the group; the default ACL makes
    # the creator's umask irrelevant inside this directory.
    chown root:dacteam "${APOLLO}"
    chmod 2770 "${APOLLO}"
    setfacl -d -m u::rwx,g::rwx,o::--- "${APOLLO}"
    printf 'apollo mission log\n' > "${APOLLO}/mission.log"
    chgrp dacteam "${APOLLO}/mission.log"
    chmod 0660 "${APOLLO}/mission.log"

    # --- known-good state #2: single-file ACL grant ----------------------------
    printf 'Q3 revenue summary - internal\n' > "${REPORT}"
    chown root:root "${REPORT}"
    chmod 0640 "${REPORT}"
    setfacl -m u:dac-bob:rw- "${REPORT}"      # named user entry, mask rw-

    # --- known-good state #3: mutable configuration file -----------------------
    printf 'log_level=info\nlisten=127.0.0.1:8080\n' > "${APPCONF}"
    chmod 0644 "${APPCONF}"

    # --- known-good state #4: SGID helper --------------------------------------
    printf 'LAB-SECRET-TOKEN-333-1\n' > "${TOKEN}"
    chown root:dacsecret "${TOKEN}"
    chmod 0640 "${TOKEN}"
    chown root:dacsecret "${LAB_ROOT}/secret"
    chmod 0750 "${LAB_ROOT}/secret"
    cp -f /usr/bin/cat "${HELPER}" 2>/dev/null || cp -f /bin/cat "${HELPER}"
    chown root:dacsecret "${HELPER}"
    chmod 2711 "${HELPER}"                    # -rwx--s--x : SGID dacsecret

    note "users dac-alice, dac-bob and groups ${LAB_GROUPS[*]} ready"
    note "lab tree created under ${LAB_ROOT}"
}

# -------------------------------------------------------------------- break --

break_lab() {
    printf '\n== Breaking the lab (controlled) ==\n'

    # FAULT 1 - a "helpful" chown/chmod sweep destroyed the shared directory:
    #           group ownership reset to root, SGID gone, group write gone,
    #           default ACL wiped.
    chown root:root "${APOLLO}"
    chmod 0750 "${APOLLO}"
    setfacl -b -k "${APOLLO}"
    chgrp root "${APOLLO}/mission.log"
    chmod 0640 "${APOLLO}/mission.log"
    note "fault 1 armed: shared project directory"

    # FAULT 2 - the ACL mask was clamped to r--, silently disabling every
    #           named-user and named-group write grant on the file.
    setfacl -m m::r-- "${REPORT}"
    note "fault 2 armed: ACL mask on ${REPORT##*/}"

    # FAULT 3 - the file was made immutable; even root is refused.
    if chattr +i "${APPCONF}" 2>/dev/null; then
        note "fault 3 armed: extended attribute on ${APPCONF##*/}"
    else
        IMMUTABLE_SUPPORTED=0
        note "fault 3 SKIPPED: this filesystem does not support the immutable flag"
    fi

    # FAULT 4 - the SGID bit was stripped from the helper binary.
    chmod 0711 "${HELPER}"
    note "fault 4 armed: mode bits on ${HELPER##*/}"

    # FAULT 5 - a global umask drop-in now creates every file as 0600.
    cat > "${DROPIN}" <<'EOF'
# Installed by "the security hardening ticket". Overly strict for shared work:
# every new file is created 0600 and every new directory 0700.
umask 077
EOF
    chmod 0644 "${DROPIN}"
    note "fault 5 armed: default umask for login shells"
}

# ----------------------------------------------------------------- briefing --

briefing() {
cat <<EOF

==============================================================================
 STUDENT BRIEFING - 333.1 Discretionary Access Control
==============================================================================

SCENARIO
  Two engineers, dac-alice and dac-bob, share the project directory
  ${APOLLO}. Both belong to the groups "dacteam" and "dacapp".
  Neither belongs to "dacsecret". A change window closed badly: someone ran a
  recursive ownership sweep, "tightened" an ACL, set a global umask and locked
  a config file. Five things are now broken. Fix all five WITHOUT weakening
  security - the grader fails you for the lazy fixes.

--- SYMPTOM 1 - nobody can write in the shared directory ---------------------
  \$ runuser -u dac-bob -- touch ${APOLLO}/notes.txt
  touch: cannot touch '${APOLLO}/notes.txt': Permission denied

  GOAL: dac-alice and dac-bob can both create files there, and every new file
        automatically belongs to group "dacteam" and is group-writable, with
        no access at all for "other". Do not add anyone to a new group and do
        not make the directory world-writable.

--- SYMPTOM 2 - an ACL that says rw but behaves as r ------------------------
  \$ getfacl ${REPORT}
  user:dac-bob:rw-                #effective:r--
  \$ runuser -u dac-bob -- bash -c 'echo x >> ${REPORT}'
  bash: ${REPORT}: Permission denied

  GOAL: dac-bob writes the file through his ACL entry. "other" must keep no
        permission bit at all - chmod 666 is a failing answer.

--- SYMPTOM 3 - root itself is denied ---------------------------------------
  \$ touch ${APPCONF}
  touch: setting times of '${APPCONF}': Operation not permitted
  \$ rm -f ${APPCONF}
  rm: cannot remove '${APPCONF}': Operation not permitted

  GOAL: root can modify the file again. The mode bits are already 0644, so the
        answer is not in "ls -l". Find the layer that outranks DAC.

--- SYMPTOM 4 - the reader helper lost its privilege ------------------------
  \$ runuser -u dac-bob -- ${HELPER} ${TOKEN}
  showsecret: ${TOKEN}: Permission denied

  GOAL: dac-bob reads the token THROUGH the helper. dac-bob must still be
        unable to read ${TOKEN} directly, so adding him to
        "dacsecret" or chmod-ing the token to 0644 are failing answers.

--- SYMPTOM 5 - new files are born unreadable by the team -------------------
  \$ runuser -l dac-alice -c 'umask'
  0077
  \$ runuser -l dac-alice -c 'touch ${APOLLO}/design.md; ls -l ${APOLLO}/design.md'
  -rw-------. 1 dac-alice dacteam 0 ... design.md

  GOAL: a file that dac-alice creates inside the project directory is writable
        by dac-bob, whatever umask her shell happens to carry. There are two
        valid repairs; the one that survives the next hardening ticket is the
        one that lives on the directory, not in a profile script.

DIAGNOSTIC TOOLBOX
  ls -ld DIR                       stat -c '%A %a %U:%G %n' FILE
  namei -om /path/to/file          id dac-bob
  getfacl FILE                     setfacl -m / -x / -b / -k / -d
  lsattr FILE                      chattr +i / -i / +a / -a
  find ${LAB_ROOT} -perm /6000 -type f -ls
  find ${LAB_ROOT} -perm -0002 ! -type l -ls
  runuser -u USER -- CMD           runuser -l USER -c 'CMD'   (login shell)

GRADE YOUR WORK
  $0 --verify
  $0 --solution        # answer key, step by step
  $0 --cleanup         # remove users, groups and ${LAB_ROOT}
==============================================================================

EOF
}

# ------------------------------------------------------------------- verify --

verify_lab() {
    printf '\n== Verifying the repair ==\n\n'
    CHECK_FAILED=0
    local f mode grp others

    [[ -f "${MARKER}" ]] || die "lab not found. Run '$0' first."

    # --- check 1: bob can create files in the shared directory ---------------
    f="${APOLLO}/.verify-bob.$$"
    rm -f "$f"
    if as_user dac-bob "touch $f" >/dev/null 2>&1 && [[ -e "$f" ]]; then
        pass "1a. dac-bob can create files in the shared project directory"
    else
        fail "1a. dac-bob still cannot create files in ${APOLLO}" \
             "look at the group owner and at the group write bit: stat -c '%A %U:%G' ${APOLLO}"
    fi
    rm -f "$f"

    others=$(stat -c '%A' "${APOLLO}" | cut -c8-10)
    if [[ "$others" == "---" ]]; then
        pass "1b. the shared directory grants nothing to 'other'"
    else
        fail "1b. the shared directory is open to 'other' ($others)" \
             "you widened access instead of fixing ownership; chmod 2770 is the target"
    fi

    # --- check 2 + 5: inheritance of group and of usable permissions ---------
    f="${APOLLO}/.verify-alice.$$"
    rm -f "$f"
    if as_user dac-alice "touch $f" >/dev/null 2>&1 && [[ -e "$f" ]]; then
        grp=$(stat -c '%G' "$f")
        mode=$(stat -c '%A' "$f")
        if [[ "$grp" == "dacteam" ]]; then
            pass "2. a file created by dac-alice inherits group 'dacteam' (SGID works)"
        else
            fail "2. a file created by dac-alice landed in group '$grp'" \
                 "group inheritance comes from the SGID bit on the directory, not from an ACL"
        fi
        if as_user dac-bob "printf 'bob-was-here\n' >> $f" >/dev/null 2>&1; then
            pass "5. dac-bob can write a file created by dac-alice (mode $mode)"
        else
            fail "5. dac-bob cannot write dac-alice's new file (mode $mode)" \
                 "her umask is 0077; fix the drop-in ${DROPIN} or, better, give the directory a default ACL"
        fi
    else
        fail "2/5. dac-alice cannot create files in ${APOLLO}" \
             "fix check 1 first"
    fi
    rm -f "$f"

    # --- check 3: the ACL mask ------------------------------------------------
    if as_user dac-bob "printf 'row\n' >> ${REPORT}" >/dev/null 2>&1; then
        pass "3a. dac-bob can write ${REPORT##*/} through his ACL entry"
    else
        fail "3a. dac-bob still cannot write ${REPORT##*/}" \
             "getfacl shows '#effective:r--'; the mask entry (m::) is the ceiling for named entries"
    fi
    others=$(stat -c '%A' "${REPORT}" | cut -c8-10)
    if [[ "$others" == "---" ]]; then
        pass "3b. ${REPORT##*/} still grants nothing to 'other'"
    else
        fail "3b. ${REPORT##*/} is now open to 'other' ($others)" \
             "chmod 666 is not a fix; raise only the ACL mask: setfacl -m m::rw- FILE"
    fi

    # --- check 4: extended attributes ----------------------------------------
    if [[ $IMMUTABLE_SUPPORTED -eq 1 || -e "${APPCONF}" ]]; then
        if touch "${APPCONF}" 2>/dev/null; then
            pass "4. root can modify ${APPCONF##*/} again"
        else
            fail "4. root is still refused on ${APPCONF##*/}" \
                 "no mode bit explains this: run 'lsattr ${APPCONF}'"
        fi
    fi

    # --- check 6: the SGID helper --------------------------------------------
    if as_user dac-bob "${HELPER} ${TOKEN}" 2>/dev/null | grep -q 'LAB-SECRET-TOKEN'; then
        pass "6a. dac-bob reads the token through the SGID helper"
    else
        fail "6a. the helper still cannot read the token" \
             "compare 'stat -c %A ${HELPER}' with the target -rwx--s--x (mode 2711)"
    fi
    if as_user dac-bob "cat ${TOKEN}" >/dev/null 2>&1; then
        fail "6b. dac-bob can read the token DIRECTLY - the secret is no longer protected" \
             "you widened the token or added dac-bob to dacsecret; restore 0640 root:dacsecret and use the SGID bit instead"
    else
        pass "6b. dac-bob still cannot read the token directly (privilege stays in the binary)"
    fi

    printf '\n'
    if [[ $CHECK_FAILED -eq 0 ]]; then
        printf 'ALL CHECKS PASSED. Run "%s --cleanup" to release the lab.\n\n' "$0"
        return 0
    fi
    printf 'Some checks failed. Keep digging, or run "%s --solution".\n\n' "$0"
    return 1
}

# ------------------------------------------------------------------ cleanup --

cleanup_lab() {
    printf '\n== Removing the lab ==\n'
    if [[ "${LAB_ROOT}" == "/srv/dac-lab" && -f "${MARKER}" ]]; then
        find "${LAB_ROOT}" -type f -exec chattr -i -a {} + 2>/dev/null || true
        rm -rf "${LAB_ROOT}"
        note "removed ${LAB_ROOT}"
    else
        note "no lab marker at ${MARKER}; leaving the filesystem untouched"
    fi
    rm -f "${DROPIN}"
    for u in "${LAB_USERS[@]}"; do
        getent passwd "$u" >/dev/null && userdel -r "$u" 2>/dev/null || true
    done
    for g in "${LAB_GROUPS[@]}"; do
        getent group "$g" >/dev/null && groupdel "$g" 2>/dev/null || true
    done
    note "removed lab users, lab groups and ${DROPIN}"
    printf '\n'
}

print_solution() {
    sed -n '/^# =\{4,\} SOLUTION BEGIN/,/^# =\{4,\} SOLUTION END/p' "$0" \
        | sed -e 's/^#\( \|$\)//'
}

usage() {
cat <<EOF
Usage: $0 [--break|--setup|--verify|--solution|--cleanup|--help]

  (no option)  build the lab, break it and print the student briefing
  --setup      build the known-good lab only, without breaking anything
  --break      same as no option
  --verify     grade the repair; exits non-zero while any check fails
  --solution   print the commented answer key
  --cleanup    remove every artifact this script created
EOF
}

# --------------------------------------------------------------------- main --

main() {
    case "${1:---break}" in
        --help|-h)   usage; exit 0 ;;
        --solution)  print_solution; exit 0 ;;
        --verify)    require_root; require_tools; verify_lab; exit $? ;;
        --cleanup)   require_root; cleanup_lab; exit 0 ;;
        --setup)     require_root; require_tools; require_disposable_vm
                     require_acl_filesystem; setup_lab
                     printf '\nLab built in its known-good state. Nothing is broken yet.\n\n'
                     exit 0 ;;
        --break)     ;;
        *)           usage; die "unknown option: $1" ;;
    esac

    require_root
    require_tools
    require_disposable_vm
    require_acl_filesystem
    setup_lab
    break_lab
    briefing
}

main "$@"
exit 0

# ==============================================================================
# ===== SOLUTION BEGIN =========================================================
#
#  333.1 Discretionary Access Control - answer key
#  Read only after you have tried. Every command below runs as root.
#
#  STEP 0 - map the damage before touching anything
#
#    namei -om /srv/dac-lab/projects/apollo/mission.log
#    stat -c '%A %a %U:%G %n' /srv/dac-lab/projects/apollo
#    getfacl /srv/dac-lab/reports/q3-summary.txt
#    lsattr  /srv/dac-lab/etc/app.conf
#    find /srv/dac-lab -perm /6000 -type f -ls
#    id dac-bob
#
#    "namei -om" walks every component of the path and prints its mode: it is
#    the fastest way to see that a denial comes from a parent directory's
#    missing x bit rather than from the file itself.
#
#  ---------------------------------------------------------------------------
#  FAULT 1 - shared directory: wrong group, no SGID, no group write
#
#    Observed:  drwxr-x---  root:root   /srv/dac-lab/projects/apollo
#    Wanted:    drwxrws---  root:dacteam
#
#      chgrp dacteam /srv/dac-lab/projects/apollo
#      chmod 2770    /srv/dac-lab/projects/apollo
#      chgrp dacteam /srv/dac-lab/projects/apollo/mission.log
#      chmod 0660    /srv/dac-lab/projects/apollo/mission.log
#
#    Check:  ls -ld /srv/dac-lab/projects/apollo
#            drwxrws--- 2 root dacteam 4096 ... apollo
#
#    Why the SGID bit (2 in 2770): on a directory it makes every new entry
#    inherit the DIRECTORY's group instead of the creator's primary group, and
#    it propagates itself to new subdirectories. Without it, dac-alice's files
#    land in group "dac-alice" (her user private group) and dac-bob is locked
#    out even though the directory itself is fine.
#    A capital S in the listing (drwxr-S---) means SGID is set but the group
#    execute bit is missing - a common half-fix.
#    Note the parallel with the sticky bit (chmod 1777 /tmp), which restricts
#    deletion in a world-writable directory to the file owner.
#
#  ---------------------------------------------------------------------------
#  FAULT 5 - umask 0077 kills the inheritance you just restored
#
#    Two valid repairs. Prefer the second.
#
#    (a) Fix the drop-in, which is global and easy to undo by the next ticket:
#          sed -i 's/^umask 077/umask 002/' /etc/profile.d/99-dac-lab-umask.sh
#        umask 002 works only with user private groups (each user's primary
#        group is their own), which is the default on Debian and RHEL alike.
#
#    (b) Attach a DEFAULT ACL to the directory - it belongs to the data, not to
#        the user's shell, and it supersedes the process umask for files created
#        inside that directory:
#          setfacl -d -m u::rwx,g::rwx,o::--- /srv/dac-lab/projects/apollo
#
#        Check:  getfacl /srv/dac-lab/projects/apollo
#                default:user::rwx
#                default:group::rwx
#                default:other::---
#
#    Existing files created while the lab was broken keep their old mode; fix
#    them explicitly:
#          chmod -R g+rw /srv/dac-lab/projects/apollo
#
#  ---------------------------------------------------------------------------
#  FAULT 2 - the ACL mask is clamping a valid grant
#
#    getfacl /srv/dac-lab/reports/q3-summary.txt
#      user::rw-
#      user:dac-bob:rw-        #effective:r--     <-- the grant is there ...
#      group::r--
#      mask::r--                                  <-- ... and the mask kills it
#      other::---
#
#    The mask is the upper bound applied to every named user, every named group
#    and the owning group. Raise the mask only:
#
#      setfacl -m m::rw- /srv/dac-lab/reports/q3-summary.txt
#
#    Check:  getfacl file   -> user:dac-bob:rw-   with no "#effective" comment
#
#    Two traps worth memorising:
#      * "chmod g+w file" on an ACL-bearing file rewrites the MASK, not the
#        owning group entry. That happens to fix this case, but it silently
#        widens every named entry too - say what you mean with m::.
#      * "chmod 666 file" passes the functional test and fails the audit: it
#        grants write to the whole world. The grader rejects it.
#      * setfacl -x u:dac-bob file removes one entry; -b removes all access
#        ACLs; -k removes the default ACL.
#
#  ---------------------------------------------------------------------------
#  FAULT 3 - the immutable extended attribute outranks DAC entirely
#
#    lsattr /srv/dac-lab/etc/app.conf
#      ----i---------e------- /srv/dac-lab/etc/app.conf
#
#      chattr -i /srv/dac-lab/etc/app.conf
#
#    Check:  lsattr file  -> --------------e-------   ; touch file now succeeds
#
#    While +i is set, the file cannot be modified, deleted, renamed, hard-linked
#    or have its metadata changed - by anyone, root included. Removing the flag
#    requires CAP_LINUX_IMMUTABLE, which root normally holds but a hardened
#    container or a securelevel-style lockdown may drop.
#    Related and equally examinable: chattr +a (append-only, the classic
#    protection for log files) and chattr +d (skip this file in dump backups).
#
#  ---------------------------------------------------------------------------
#  FAULT 4 - the SGID bit was stripped from the helper binary
#
#    stat -c '%A %U:%G %n' /srv/dac-lab/bin/showsecret
#      -rwx--x--x root:dacsecret ...        <-- no s : it runs with the caller's
#                                               own egid, so the group-readable
#                                               token is out of reach
#
#      chmod 2711 /srv/dac-lab/bin/showsecret      # or: chmod g+s FILE
#
#    Check:  stat -c '%A' file          -> -rwx--s--x
#            runuser -u dac-bob -- /srv/dac-lab/bin/showsecret \
#                                  /srv/dac-lab/secret/token.txt
#            LAB-SECRET-TOKEN-333-1
#
#    SUID (4000) makes the process run with the FILE OWNER's euid; SGID (2000)
#    on an executable makes it run with the file's group. That is how a normal
#    user reads /etc/shadow through "passwd" without ever holding read access
#    to it. The correct fix is to restore the bit on the binary, never to widen
#    the data: adding dac-bob to "dacsecret" or chmod 0644 on the token gives
#    him permanent, unmediated access and fails check 6b.
#
#    Auditing SUID/SGID is itself an exam objective:
#      find / -xdev -perm /6000 -type f -ls 2>/dev/null
#      find / -xdev -perm -0002 ! -type l -ls 2>/dev/null   # world-writable
#
#  ---------------------------------------------------------------------------
#  STEP FINAL - confirm, then release the lab
#
#    ./333.1-dac-break-fix.sh --verify
#    ./333.1-dac-break-fix.sh --cleanup
#
#  Reference: LPI exam 303-300 objectives, topic 333.1
#             https://www.lpi.org/our-certifications/exam-303-objectives/
#             acl(5), setfacl(1), getfacl(1), chattr(1), lsattr(1),
#             chmod(1), umask(1p), namei(1), runuser(1)
#
# ===== SOLUTION END ===========================================================
# ==============================================================================