#!/usr/bin/env bash
#
# =====================================================================================
#  LPIC-1 (Exams 101-500 + 102-500, version 5.0)
#  Topic 102.3 -- Manage shared libraries        (exam weight: 1.56)
#
#  BREAK & FIX LAB -- run ONLY on a disposable/throwaway lab VM or container.
#
#  What this lab does
#  ------------------
#  It builds a tiny, self-contained "vendor product" (a shared library plus a binary
#  linked against it) under /opt/greet, proves it works, and then breaks the dynamic
#  linker configuration around it in three independent ways. Your job is to diagnose
#  and repair the runtime linking path using the tools of objective 102.3:
#      ldd, ldconfig, /etc/ld.so.conf, /etc/ld.so.conf.d/, /etc/ld.so.cache,
#      LD_LIBRARY_PATH, LD_PRELOAD
#
#  Blast radius (everything this script ever writes or deletes)
#  -----------------------------------------------------------
#      /opt/greet/                      (lab tree: sources, library, decoy)
#      /usr/local/bin/greetctl          (lab binary)
#      /usr/local/bin/greet-lab-check   (self-check helper)
#      /etc/ld.so.conf.d/greet.conf     (lab-owned drop-in, created then deleted)
#      /etc/profile.d/zz-greet-lab.sh   (lab-owned login-shell environment)
#      /etc/ld.so.cache                 (regenerated via ldconfig -- never edited)
#  NO system library, NO package-owned file and NO pre-existing ld.so.conf.d drop-in
#  is modified. The machine stays bootable; only the lab product breaks.
#
#  Usage
#  -----
#      sudo ./102.3-break-and-fix.sh            # build + break + print the briefing
#      sudo ./102.3-break-and-fix.sh --force    # same, skip the interactive confirmation
#      ./102.3-break-and-fix.sh --verify        # score your repair (same as greet-lab-check)
#      sudo ./102.3-break-and-fix.sh --clean    # tear the whole lab down (NOT the fix)
#
#  Requirements: root, a C compiler (cc/gcc/clang), binutils, glibc.
#      Debian/Ubuntu: apt-get install -y build-essential
#      RHEL/Fedora:   dnf install -y gcc binutils
#      openSUSE:      zypper install -y gcc binutils
#
#  Official sources
#  ----------------
#      LPI exam 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
#      LPI exam 102-500 objectives: https://www.lpi.org/our-certifications/exam-102-objectives/
#      ld.so(8)   -- dynamic linker/loader:   https://man7.org/linux/man-pages/man8/ld.so.8.html
#      ldconfig(8) -- cache/link maintenance: https://man7.org/linux/man-pages/man8/ldconfig.8.html
#      ldd(1)     -- print shared deps:       https://man7.org/linux/man-pages/man1/ldd.1.html
#      GNU ld manual (SONAME semantics):      https://sourceware.org/binutils/docs/ld/Options.html
# =====================================================================================

set -Eeuo pipefail

readonly LAB_TAG='lpic1-102.3-shared-libraries'
readonly LAB_ROOT='/opt/greet'
readonly SRC_DIR="${LAB_ROOT}/src"
readonly LIB_DIR="${LAB_ROOT}/lib"
readonly DECOY_DIR="${LAB_ROOT}/decoy"
readonly MARKER="${LAB_ROOT}/.lab-marker"
readonly LDCONF='/etc/ld.so.conf.d/greet.conf'
readonly PROFILE='/etc/profile.d/zz-greet-lab.sh'
readonly BIN='/usr/local/bin/greetctl'
readonly CHECK='/usr/local/bin/greet-lab-check'
readonly REAL_LIB='libgreet.so.1.0.0'
readonly SONAME='libgreet.so.1'
readonly LINKER_NAME='libgreet.so'
readonly BANNER='greetctl: libgreet.so.1 resolved correctly'

CC=''

# ------------------------------------------------------------------ helpers ---
say()  { printf '%s\n' "$*"; }
info() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
rule() { printf '%s\n' '---------------------------------------------------------------------------'; }

trap 'die "unexpected failure at line ${LINENO} (exit ${?}); the lab may be half-built -- rerun with --clean, then rerun the script"' ERR

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "this script must run as root (try: sudo $0 $*)"
}

require_compiler() {
    local candidate
    for candidate in cc gcc clang; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            CC="${candidate}"
            return 0
        fi
    done
    die "no C compiler found. Install one: apt-get install build-essential | dnf install gcc binutils"
}

require_tools() {
    local missing=() tool
    for tool in ldconfig ldd readelf install; do
        command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done
    (( ${#missing[@]} == 0 )) || die "missing required tool(s): ${missing[*]}"
}

confirm() {
    local answer
    if [[ "${FORCE:-no}" == 'yes' ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "non-interactive shell: refusing to break anything without --force"
    fi
    rule
    say "This script will BREAK shared-library resolution on THIS machine ($(hostname))."
    say "It is safe and reversible, but it is meant for a disposable lab VM only."
    rule
    read -r -p 'Type exactly "BREAK MY LAB VM" to continue: ' answer
    [[ "${answer}" == 'BREAK MY LAB VM' ]] || die 'aborted by the user; nothing was changed'
}

# ------------------------------------------------------------------- build ----
build_lab() {
    info "building the lab product under ${LAB_ROOT} with ${CC}"
    install -d -m 0755 "${LAB_ROOT}" "${SRC_DIR}" "${LIB_DIR}" "${DECOY_DIR}"

    cat > "${SRC_DIR}/libgreet.c" <<'CSRC'
#include <stdio.h>

/* Exported entry point of the lab's "vendor" shared library. */
void greet_banner(void)
{
    puts("greetctl: libgreet.so.1 resolved correctly");
}
CSRC

    cat > "${SRC_DIR}/greetctl.c" <<'CSRC'
/* Consumer binary: links against libgreet at build time, resolves it at run time
   through the dynamic linker -- i.e. through the cache and the search path. */
void greet_banner(void);

int main(void)
{
    greet_banner();
    return 0;
}
CSRC

    # Real library: the SONAME recorded in the ELF header is what ld.so will look for
    # at run time, and it is also what ldconfig uses to (re)create the version symlink.
    "${CC}" -O2 -fPIC -shared -Wl,-soname,"${SONAME}" \
        -o "${LIB_DIR}/${REAL_LIB}" "${SRC_DIR}/libgreet.c"

    ln -sfn "${REAL_LIB}" "${LIB_DIR}/${SONAME}"     # version symlink (run time)
    ln -sfn "${SONAME}"   "${LIB_DIR}/${LINKER_NAME}" # linker name    (build time, -lgreet)

    # Register the directory the way a real vendor package would, then rebuild the cache.
    printf '%s\n' "${LIB_DIR}" > "${LDCONF}"
    chmod 0644 "${LDCONF}"
    ldconfig

    # No RPATH/RUNPATH on purpose: resolution MUST go through /etc/ld.so.cache,
    # which is exactly what the student has to repair.
    "${CC}" -O2 -o "${BIN}" "${SRC_DIR}/greetctl.c" -L"${LIB_DIR}" -lgreet
    chmod 0755 "${BIN}"

    info 'verifying the product works BEFORE breaking it'
    local out
    out="$("${BIN}")"
    [[ "${out}" == "${BANNER}" ]] || die "the freshly built lab product does not run correctly: ${out}"
    say "    $ greetctl"
    say "    ${out}"

    # Decoy library: valid ELF magic, truncated body. ld.so will accept the path
    # and then reject the file -- a different error class from "not found".
    head -c 64 "${LIB_DIR}/${REAL_LIB}" > "${DECOY_DIR}/${SONAME}"
    chmod 0644 "${DECOY_DIR}/${SONAME}"

    printf '%s\n%s\n' "${LAB_TAG}" "built_at=$(date -Is)" > "${MARKER}"
}

# ------------------------------------------------------------------- break ----
break_lab() {
    info 'introducing fault 1/3 -- the search-path drop-in'
    rm -f "${LDCONF}"
    ldconfig                        # cache rebuilt WITHOUT /opt/greet/lib

    info 'introducing fault 2/3 -- the SONAME and linker-name symlinks'
    rm -f "${LIB_DIR}/${SONAME}" "${LIB_DIR}/${LINKER_NAME}"

    info 'introducing fault 3/3 -- login-shell environment overrides'
    cat > "${PROFILE}" <<PROF
# Greet vendor runtime tuning -- added by the (fictional) greet installer.
# Applies to login shells. Harmless-looking, and completely wrong.
export LD_LIBRARY_PATH="${DECOY_DIR}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
export LD_PRELOAD="${DECOY_DIR}/libaudit-shim.so"
PROF
    chmod 0644 "${PROFILE}"
}

# -------------------------------------------------------------- self-check ----
install_check() {
    cat > "${CHECK}" <<'CHECKEOF'
#!/usr/bin/env bash
# Self-check for the LPIC-1 102.3 break & fix lab. Exit code 0 means: solved.
LIB_DIR='/opt/greet/lib'
BIN='/usr/local/bin/greetctl'
BANNER='greetctl: libgreet.so.1 resolved correctly'
fail=0
ok() { printf '  [ OK ] %s\n' "$1"; }
ko() { printf '  [FAIL] %s\n' "$1"; fail=1; }

printf '\n== LPIC-1 102.3 -- lab self-check ==\n\n'

# 1. Version symlink (SONAME) restored and pointing at the real object.
target="$(readlink "${LIB_DIR}/libgreet.so.1" 2>/dev/null || true)"
if [ "${target}" = 'libgreet.so.1.0.0' ]; then
    ok "SONAME symlink ${LIB_DIR}/libgreet.so.1 -> libgreet.so.1.0.0"
else
    ko "SONAME symlink ${LIB_DIR}/libgreet.so.1 is missing or wrong (points to: '${target:-none}')"
fi

# 2. The cache knows the library, and knows it at the right path.
if ldconfig -p | grep -q "libgreet.so.1 .*=> ${LIB_DIR}/libgreet.so.1"; then
    ok 'ldconfig -p lists libgreet.so.1 from /opt/greet/lib'
else
    ko 'ldconfig -p does not list libgreet.so.1 from /opt/greet/lib (cache/search path still wrong)'
fi

# 3. Static view of the binary: no unresolved dependency.
if ldd "${BIN}" 2>/dev/null | grep -q 'not found'; then
    ko "ldd ${BIN} still reports an unresolved dependency"
else
    ok "ldd ${BIN} resolves every dependency"
fi

# 4. Dynamic view in a LOGIN shell: correct output and a clean stderr
#    (a leftover LD_PRELOAD or LD_LIBRARY_PATH shows up here and nowhere else).
err="$(mktemp)"; out="$(bash -lc "${BIN}" 2>"${err}" || true)"
if [ "${out}" = "${BANNER}" ]; then
    ok 'greetctl prints the expected banner in a login shell'
else
    ko "greetctl output in a login shell is wrong: '${out}'"
fi
if [ -s "${err}" ]; then
    ko "the login shell still emits dynamic-linker noise:"
    sed 's/^/         /' "${err}"
else
    ok 'no LD_PRELOAD / LD_LIBRARY_PATH noise in a login shell'
fi
rm -f "${err}"

# 5. Bonus: the development linker name, needed by `cc -lgreet`.
if [ -L "${LIB_DIR}/libgreet.so" ]; then
    ok 'BONUS: linker name libgreet.so present (cc -lgreet can link again)'
else
    ko 'BONUS: linker name libgreet.so missing -- ldconfig never creates this one'
fi

printf '\n'
if [ "${fail}" -eq 0 ]; then
    printf 'RESULT: lab solved. Every check passed.\n\n'
else
    printf 'RESULT: not solved yet. Re-read the failing lines above.\n\n'
fi
exit "${fail}"
CHECKEOF
    chmod 0755 "${CHECK}"
}

# ---------------------------------------------------------------- briefing ----
briefing() {
    local sample_now sample_login
    sample_now="$("${BIN}" 2>&1 || true)"
    sample_login="$(bash -lc "${BIN}" 2>&1 || true)"

    say ''
    rule
    say ' LPIC-1 102.3 -- MANAGE SHARED LIBRARIES -- BREAK & FIX BRIEFING'
    rule
    say ''
    say ' THE STORY'
    say '   A vendor product is installed: the binary /usr/local/bin/greetctl depends on'
    say '   the shared library libgreet.so.1, which lives in /opt/greet/lib -- a directory'
    say '   that is NOT one of the linker default trusted directories (/lib, /usr/lib).'
    say '   It worked one minute ago. It does not work now. Nothing was recompiled and no'
    say '   package was removed: only the dynamic-linking configuration around it changed.'
    say ''
    say ' SYMPTOM A -- in your current (non-login) shell:'
    say ''
    printf '   $ greetctl\n'
    printf '%s\n' "${sample_now}" | sed 's/^/   /'
    say ''
    say ' SYMPTOM B -- in a fresh LOGIN shell (bash -lc, su - user, ssh, tty login).'
    say '   Note that the error is a DIFFERENT one, and that some commands now print'
    say '   linker warnings on stderr even when they succeed:'
    say ''
    printf '   $ bash -lc greetctl\n'
    printf '%s\n' "${sample_login}" | sed 's/^/   /'
    say ''
    say ' WHY THE TWO ERRORS DIFFER -- this is the whole lesson'
    say '   "cannot open shared object file" = the loader never FOUND a file with that'
    say '   SONAME anywhere in its search order.'
    say '   "file too short" / "invalid ELF header" = the loader DID find a file, opened'
    say '   it, and rejected its contents. Same missing library, opposite root cause.'
    say '   The loader search order is: DT_RPATH (if no RUNPATH) -> LD_LIBRARY_PATH ->'
    say '   DT_RUNPATH -> /etc/ld.so.cache -> the default trusted directories. An'
    say '   environment variable therefore beats a perfectly correct cache, every time.'
    say ''
    say ' YOUR MISSION -- three independent faults, all of them in configuration:'
    say '   1. greetctl must print exactly:  '"${BANNER}"
    say '      both in your current shell and in a fresh login shell.'
    say '   2. "ldd /usr/local/bin/greetctl" must show no "not found" line.'
    say '   3. "ldconfig -p | grep libgreet" must list libgreet.so.1 resolving to'
    say '      /opt/greet/lib/libgreet.so.1.'
    say '   4. A login shell must produce NO dynamic-linker messages on stderr.'
    say '   5. BONUS: "cc -L/opt/greet/lib -lgreet" must be able to link again.'
    say ''
    say ' RULES OF ENGAGEMENT'
    say '   - Do NOT recompile anything under /opt/greet/src. The library object'
    say '     /opt/greet/lib/libgreet.so.1.0.0 is intact and must stay untouched.'
    say '   - Do NOT copy the library into /usr/lib. That hides the fault instead of'
    say '     fixing it, and the self-check will notice.'
    say '   - Fix the configuration, not the symptom.'
    say ''
    say ' TOOLBOX FOR THIS OBJECTIVE'
    say '   ldd BINARY                 which SONAMEs are needed and where each resolves'
    say '   readelf -d BINARY | head   the NEEDED / SONAME / RPATH / RUNPATH entries'
    say '   readelf -d LIB | grep SONAME   the name a library advertises about itself'
    say '   ldconfig -p                dump the current /etc/ld.so.cache'
    say '   ldconfig -v                rebuild the cache, printing every dir and symlink'
    say '   ldconfig -N -X -v DIR      inspect a directory without touching cache/links'
    say '   cat /etc/ld.so.conf ; ls /etc/ld.so.conf.d/'
    say '   env | grep -E "^LD_"       the environment overrides in effect'
    say '   grep -rn "LD_" /etc/profile /etc/profile.d/ /etc/environment ~/.bash_profile'
    say '   LD_DEBUG=libs greetctl     trace the search, path by path (glibc)'
    say ''
    say ' SAFETY NOTE ON ldd: it can execute the binary to resolve dependencies, so never'
    say ' run it on an untrusted file. Use "objdump -p" or "readelf -d" instead.'
    say ''
    say ' SCORE YOURSELF AT ANY TIME'
    say '   sudo greet-lab-check          (or: sudo '"$0"' --verify)'
    say ''
    say ' The full step-by-step solution is at the bottom of this script, commented out.'
    say ' Read it only after you have tried. Tear the lab down with: sudo '"$0"' --clean'
    rule
    say ''
}

# ------------------------------------------------------------------- modes ----
do_verify() {
    [[ -x "${CHECK}" ]] || die "the lab is not installed; run: sudo $0"
    "${CHECK}"
}

do_clean() {
    require_root
    info 'tearing the lab down (this is teardown, NOT the fix)'
    rm -f "${LDCONF}" "${PROFILE}" "${BIN}" "${CHECK}"
    rm -rf "${LAB_ROOT}"
    ldconfig
    info 'lab removed; /etc/ld.so.cache rebuilt'
}

usage() {
    sed -n '2,40p' "$0"
    exit 0
}

main() {
    local mode='break'
    FORCE='no'
    while (( $# )); do
        case "$1" in
            --verify)  mode='verify' ;;
            --clean)   mode='clean' ;;
            --force)   FORCE='yes' ;;
            -h|--help) usage ;;
            *)         die "unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    case "${mode}" in
        verify) do_verify ;;
        clean)  do_clean ;;
        break)
            require_root
            require_tools
            require_compiler
            confirm
            build_lab        # idempotent: rebuilds the product from scratch every time
            install_check
            break_lab
            briefing
            ;;
    esac
}

main "$@"
exit 0

# =====================================================================================
#  SOLUTION -- do not read until you have worked the lab.
# =====================================================================================
#
#  STEP 0 -- Reproduce and classify the failure
#  --------------------------------------------
#      $ greetctl
#      greetctl: error while loading shared libraries: libgreet.so.1: cannot open
#      shared object file: No such file or directory
#
#      $ ldd /usr/local/bin/greetctl
#              linux-vdso.so.1 (0x00007ffd...)
#              libgreet.so.1 => not found
#              libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f...)
#
#  "not found" means the loader searched and came up empty. Confirm the binary is
#  asking for the right name and is not relying on a baked-in path:
#
#      $ readelf -d /usr/local/bin/greetctl | head -n 5
#       0x0000000000000001 (NEEDED)   Shared library: [libgreet.so.1]
#       0x0000000000000001 (NEEDED)   Shared library: [libc.so.6]
#
#  No RPATH and no RUNPATH entry => resolution depends entirely on LD_LIBRARY_PATH,
#  on /etc/ld.so.cache, and on the default trusted directories.
#
#
#  STEP 1 -- Fault 1: the library directory is no longer in the search path
#  -----------------------------------------------------------------------
#  The file itself is still on disk:
#
#      $ ls -l /opt/greet/lib/
#      -rwxr-xr-x 1 root root 15864 ... libgreet.so.1.0.0
#
#  ...but the cache does not know about it, and neither does the configuration:
#
#      $ ldconfig -p | grep -c libgreet
#      0
#      $ ls /etc/ld.so.conf.d/
#      libc.conf  x86_64-linux-gnu.conf        # the greet.conf drop-in is gone
#      $ grep -v '^#' /etc/ld.so.conf
#      include /etc/ld.so.conf.d/*.conf        # the include line is intact -- good
#
#  Recreate the drop-in. One directory per line; the filename must end in .conf so
#  the glob in /etc/ld.so.conf picks it up:
#
#      # echo '/opt/greet/lib' > /etc/ld.so.conf.d/greet.conf
#      # chmod 0644 /etc/ld.so.conf.d/greet.conf
#
#  STEP 2 -- Fault 2: rebuild the cache, which also repairs the SONAME symlink
#  --------------------------------------------------------------------------
#  Look at what is missing before rebuilding:
#
#      $ ls /opt/greet/lib/
#      libgreet.so.1.0.0                       # no libgreet.so.1, no libgreet.so
#
#  The binary needs libgreet.so.1 -- the SONAME -- not libgreet.so.1.0.0. That
#  version symlink is not something you must create by hand: ldconfig reads the
#  SONAME out of each ELF object it scans and recreates the link itself.
#
#      $ readelf -d /opt/greet/lib/libgreet.so.1.0.0 | grep SONAME
#       0x000000000000000e (SONAME)   Library soname: [libgreet.so.1]
#
#      # ldconfig -v 2>/dev/null | grep -A2 '^/opt/greet/lib'
#      /opt/greet/lib:
#              libgreet.so.1 -> libgreet.so.1.0.0        # created by ldconfig
#
#  Plain `ldconfig` (no options) does the same silently: it walks /etc/ld.so.conf,
#  every *.conf under /etc/ld.so.conf.d/, the trusted directories and any dirs given
#  on the command line, refreshes the version symlinks, and rewrites /etc/ld.so.cache.
#
#      # ldconfig
#      $ ldconfig -p | grep libgreet
#              libgreet.so.1 (libc6,x86-64) => /opt/greet/lib/libgreet.so.1
#
#      $ ldd /usr/local/bin/greetctl | grep greet
#              libgreet.so.1 => /opt/greet/lib/libgreet.so.1 (0x00007f...)
#      $ greetctl
#      greetctl: libgreet.so.1 resolved correctly
#
#  Useful variants to know for the exam:
#      ldconfig -n DIR    process ONLY DIR, update symlinks, do NOT touch the cache
#      ldconfig -N        update symlinks only, skip the cache rebuild
#      ldconfig -X        rebuild the cache only, skip the symlinks
#      ldconfig -p        print the current cache without changing anything
#      ldconfig -r ROOT   chroot to ROOT first (rescue / chroot repair)
#
#
#  STEP 3 -- Fault 3: the environment overrides that outrank your fix
#  -----------------------------------------------------------------
#  The current shell works now, but a login shell still fails, differently:
#
#      $ bash -lc greetctl
#      ERROR: ld.so: object '/opt/greet/decoy/libaudit-shim.so' from LD_PRELOAD cannot
#      be preloaded (cannot open shared object file): ignored.
#      greetctl: error while loading shared libraries: /opt/greet/decoy/libgreet.so.1:
#      file too short
#
#  Two distinct signals:
#    * LD_PRELOAD names a file that does not exist. glibc prints the warning and
#      carries on ("ignored") -- noise, not a fatal error, but it pollutes every
#      command and every script that parses stderr.
#    * LD_LIBRARY_PATH points at /opt/greet/decoy, which is searched BEFORE the
#      cache. It contains a file with the right name and a truncated body, so the
#      loader opens it and dies with "file too short". Your correct cache entry is
#      never even consulted.
#
#  Find where the variables come from -- they are not exported by the binary:
#
#      $ bash -lc 'env | grep ^LD_'
#      LD_LIBRARY_PATH=/opt/greet/decoy
#      LD_PRELOAD=/opt/greet/decoy/libaudit-shim.so
#
#      $ grep -rn 'LD_LIBRARY_PATH\|LD_PRELOAD' /etc/profile /etc/profile.d/ \
#            /etc/environment /etc/bash.bashrc ~/.bash_profile ~/.bashrc 2>/dev/null
#      /etc/profile.d/zz-greet-lab.sh:3:export LD_LIBRARY_PATH="/opt/greet/decoy..."
#      /etc/profile.d/zz-greet-lab.sh:4:export LD_PRELOAD="/opt/greet/decoy/libaudit-shim.so"
#
#  Remove the offending drop-in (it is lab-owned; in production you would inspect it,
#  and back it up, before deleting):
#
#      # rm -f /etc/profile.d/zz-greet-lab.sh
#
#  ...and clear the variables from any shell that already inherited them:
#
#      $ unset LD_LIBRARY_PATH LD_PRELOAD
#
#  Verify in a genuinely fresh login shell -- not in the one you have been editing in:
#
#      $ bash -lc greetctl
#      greetctl: libgreet.so.1 resolved correctly
#
#
#  STEP 4 -- Bonus: the linker name, the one symlink ldconfig will not create
#  -------------------------------------------------------------------------
#      $ cc -L/opt/greet/lib -lgreet -o /tmp/t /opt/greet/src/greetctl.c
#      /usr/bin/ld: cannot find -lgreet: No such file or directory
#
#  `-lgreet` looks for the unversioned name libgreet.so. ldconfig deliberately does
#  not manage it: the version symlink is a RUNTIME concern, while the linker name is
#  a BUILD-TIME concern shipped by the -dev / -devel package. Create it by hand:
#
#      # ln -sfn libgreet.so.1 /opt/greet/lib/libgreet.so
#
#  So the canonical three-name chain for a shared library is:
#      libgreet.so         -> libgreet.so.1        (linker name, dev package)
#      libgreet.so.1       -> libgreet.so.1.0.0    (SONAME, created by ldconfig)
#      libgreet.so.1.0.0                           (real name, the actual object)
#
#
#  STEP 5 -- Final verification
#  ---------------------------
#      # greet-lab-check
#      == LPIC-1 102.3 -- lab self-check ==
#        [ OK ] SONAME symlink /opt/greet/lib/libgreet.so.1 -> libgreet.so.1.0.0
#        [ OK ] ldconfig -p lists libgreet.so.1 from /opt/greet/lib
#        [ OK ] ldd /usr/local/bin/greetctl resolves every dependency
#        [ OK ] greetctl prints the expected banner in a login shell
#        [ OK ] no LD_PRELOAD / LD_LIBRARY_PATH noise in a login shell
#        [ OK ] BONUS: linker name libgreet.so present (cc -lgreet can link again)
#      RESULT: lab solved. Every check passed.
#
#
#  ONE-SHOT REPAIR (after you understand each step)
#  ------------------------------------------------
#      echo '/opt/greet/lib' > /etc/ld.so.conf.d/greet.conf
#      chmod 0644 /etc/ld.so.conf.d/greet.conf
#      ldconfig
#      ln -sfn libgreet.so.1 /opt/greet/lib/libgreet.so
#      rm -f /etc/profile.d/zz-greet-lab.sh
#      unset LD_LIBRARY_PATH LD_PRELOAD
#      greet-lab-check
#
#
#  PRODUCTION NOTES WORTH CARRYING OUT OF THE LAB
#  ----------------------------------------------
#  * LD_LIBRARY_PATH is a debugging and development tool, not a deployment mechanism.
#    Exporting it globally in /etc/profile.d is a recurring production incident: it
#    silently overrides a correct cache for every process started from a login shell,
#    and it is inherited by children, including services launched from that session.
#    The supported alternatives are an /etc/ld.so.conf.d/ drop-in plus ldconfig, or
#    a DT_RUNPATH baked in at link time (cc -Wl,-rpath,/opt/greet/lib), which is per
#    binary and cannot leak into unrelated processes.
#  * The loader ignores LD_LIBRARY_PATH and LD_PRELOAD for set-user-ID/set-group-ID
#    binaries, which is why "it works for me but not under sudo/systemd" is a classic
#    symptom of an environment-based workaround. See ld.so(8), section "Secure mode".
#  * /etc/ld.so.cache is a generated binary file. Never edit it, never copy it between
#    machines, and never restore it from a backup -- regenerate it with ldconfig.
#    If it is deleted, the loader falls back to searching directories, which is slower
#    but still functional; running ldconfig rebuilds it.
#  * After installing or upgrading a library outside a package manager, run ldconfig.
#    Package managers already do this in their post-install scriptlets; tarball and
#    "make install" deployments do not.
#  * When a running process holds an old library open, replacing the file on disk does
#    not affect it. Use "lsof +L1" or "lsof -p PID | grep DEL" to find processes still
#    mapping a deleted library, and restart those services after the upgrade.
#  * LD_DEBUG=libs (also =files, =symbols, =bindings) makes the loader narrate every
#    directory it tries. It is the fastest way to answer "why is it picking THAT copy?".
#
#  References
#      LPI 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
#      LPI 102-500 objectives: https://www.lpi.org/our-certifications/exam-102-objectives/
#      ld.so(8):    https://man7.org/linux/man-pages/man8/ld.so.8.html
#      ldconfig(8): https://man7.org/linux/man-pages/man8/ldconfig.8.html
#      ldd(1):      https://man7.org/linux/man-pages/man1/ldd.1.html
#      GNU ld (-soname, -rpath): https://sourceware.org/binutils/docs/ld/Options.html
# =====================================================================================