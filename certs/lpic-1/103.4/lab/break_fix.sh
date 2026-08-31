#!/usr/bin/env bash
#
# lab-103.4-break-and-fix.sh
#
# LPIC-1 v5.0 - Exam 101-500 - Topic 103.4 "Use streams, pipes and redirects"
# Exam weight: 6.25
# Objective reference: https://www.lpi.org/our-certifications/exam-101-objectives/
#
# WHAT THIS IS
#   A controlled break & fix drill. It seeds five real, reversible faults that
#   can only be diagnosed and repaired with stream/redirection knowledge:
#   file descriptors 0/1/2, truncate vs append, the ORDER of `2>&1`, pipes and
#   the subshell they create, FIFOs, here-documents, `noclobber`, and the
#   character device /dev/null itself.
#
# WHERE TO RUN IT
#   ONLY on a disposable lab VM or container that you can throw away, ideally
#   with a snapshot taken first. It runs as root, it replaces /dev/null with a
#   regular file, and it drops a file into /etc/profile.d. Never run it on a
#   workstation, a build agent, or anything you care about.
#
# USAGE
#   sudo ./lab-103.4-break-and-fix.sh break        # seed the faults (default)
#   sudo ./lab-103.4-break-and-fix.sh verify       # grade your repair
#   sudo ./lab-103.4-break-and-fix.sh hint         # progressive hints, no spoilers
#   sudo ./lab-103.4-break-and-fix.sh reset-data   # restore the sample data only
#   sudo ./lab-103.4-break-and-fix.sh status       # what is currently broken
#   sudo ./lab-103.4-break-and-fix.sh restore      # undo everything
#
#   Non-interactive consent: LAB_I_UNDERSTAND=yes ./lab-103.4-break-and-fix.sh break
#
# The complete step-by-step solution is at the BOTTOM of this file, commented.
# Do not read it until `verify` has beaten you at least twice.

set -uo pipefail

LAB_ID="103.4"
LAB_ROOT="/opt/lab1034"
DATA_DIR="$LAB_ROOT/data"
PRISTINE_DIR="$LAB_ROOT/pristine"
LOG_DIR="/var/log/labcollect"
LOG_FILE="$LOG_DIR/report.log"
STATE_DIR="/var/lib/lab1034"
STATE_FILE="$STATE_DIR/seeded"
PROFILE_FAULT="/etc/profile.d/lab-noclobber.sh"
BIN_COLLECT="/usr/local/bin/lab-collect"
BIN_PROBE="/usr/local/bin/lab-probe"
BIN_INVENTORY="/usr/local/bin/lab-inventory"
HOST_COUNT=5

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

PASS_COUNT=0
FAIL_COUNT=0

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BLD$C_BLU" "$*" "$C_OFF"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[fatal]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  %s[ PASS ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  %s[ FAIL ]%s %s\n' "$C_RED" "$C_OFF" "$*"; }

require_root() {
    [[ $EUID -eq 0 ]] || die "run me as root (sudo $0 $*) - I touch /dev, /etc and /usr/local/bin."
}

require_consent() {
    if [[ "${LAB_I_UNDERSTAND:-}" == "yes" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "no TTY and LAB_I_UNDERSTAND is not 'yes'. Refusing to break an unattended host."
    fi
    rule
    say "${C_BLD}You are about to deliberately break this machine.${C_OFF}"
    say "Faults seeded: /dev/null replaced by a regular file, a system-wide"
    say "noclobber, a log file turned into a FIFO, and two broken scripts."
    say "This is safe ONLY on a disposable lab VM or container with a snapshot."
    rule
    local answer=""
    read -r -p "Type BREAK to continue, anything else to abort: " answer
    [[ "$answer" == "BREAK" ]] || die "aborted - nothing was changed."
}

devnull_is_sane() {
    [[ -c /dev/null ]] || return 1
    [[ "$(stat -c '%t:%T' /dev/null 2>/dev/null)" == "1:3" ]] || return 1
    [[ "$(stat -c '%a'   /dev/null 2>/dev/null)" == "666" ]] || return 1
    return 0
}

fix_devnull() {
    rm -f /dev/null
    mknod -m 0666 /dev/null c 1 3
    chown root:root /dev/null
}

write_sample_data() {
    mkdir -p "$PRISTINE_DIR" "$DATA_DIR"

    cat > "$PRISTINE_DIR/app.log" <<'APPLOG_EOF'
# lab sample application log - lines starting with # are comments
2026-08-26T09:00:01 INFO  boot sequence complete
2026-08-26T09:00:02 ERROR disk latency above threshold dev=vda
2026-08-26T09:00:03 WARN  cache miss ratio 0.42
2026-08-26T09:00:04 ERROR backend timeout upstream=db01
2026-08-26T09:00:05 INFO  service recovered
2026-08-26T09:00:02 ERROR disk latency above threshold dev=vda
APPLOG_EOF

    cat > "$PRISTINE_DIR/hosts.txt" <<'HOSTS_EOF'
web01.lab.internal
web02.lab.internal
db01.lab.internal
cache01.lab.internal
edge01.lab.internal
HOSTS_EOF

    cp -f "$PRISTINE_DIR/app.log"   "$DATA_DIR/app.log"
    cp -f "$PRISTINE_DIR/hosts.txt" "$DATA_DIR/hosts.txt"
    chmod 0644 "$DATA_DIR"/*.log "$DATA_DIR"/*.txt
}

install_probe() {
    cat > "$BIN_PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
# lab-probe - simulated service probe.
# THIS SCRIPT IS CORRECT. Do not change it: it models a real-world daemon that
# writes normal output to stdout (fd 1) and everything abnormal to stderr (fd 2).
echo "INFO  probe started pid=$$"
for unit in web db cache; do
    echo "INFO  unit=$unit state=running"
done
echo "WARN  unit=db replication lag 42s"   >&2
echo "WARN  unit=cache evictions rising"   >&2
echo "INFO  probe finished"
exit 0
PROBE_EOF
    chmod 0755 "$BIN_PROBE"
}

install_broken_collect() {
    cat > "$BIN_COLLECT" <<'COLLECT_EOF'
#!/usr/bin/env bash
#
# lab-collect - host report collector.
#
# CONTRACT (this is what the tool is supposed to do):
#   1. Every run APPENDS a "=== run <timestamp> ===" block to
#      /var/log/labcollect/report.log. History across runs must survive.
#   2. NOTHING is ever printed on the terminal: stdout AND stderr of every
#      collected command must land inside the report file.
#   3. The report contains the number of WARN lines emitted by lab-probe.
#   4. The report contains the number of ERROR lines left in the sample log
#      after comments are stripped and duplicates are removed - and the sample
#      log must still be there afterwards.
#
# It currently satisfies none of that. Four redirection faults are seeded.

LOG=/var/log/labcollect/report.log
DATA=/opt/lab1034/data/app.log

echo "=== run $(date -Is) ===" > "$LOG"

uptime                                   2>&1 > "$LOG"
free -m                                  2>&1 >> "$LOG"
cat /proc/loadavg /proc/lab-does-not-exist 2>&1 >> "$LOG"

printf 'warnings: ' >> "$LOG"
lab-probe | grep -c '^WARN' >> "$LOG"

grep -v '^#' "$DATA" | sort -u > "$DATA"

echo "errors: $(grep -c 'ERROR' "$DATA")" >> "$LOG"

exit 0
COLLECT_EOF
    chmod 0755 "$BIN_COLLECT"
}

install_broken_inventory() {
    cat > "$BIN_INVENTORY" <<'INVENTORY_EOF'
#!/usr/bin/env bash
#
# lab-inventory - prints the lab inventory summary.
#
# CONTRACT:
#   * Prints a here-document header.
#   * "host count : N" must show the real number of lines in hosts.txt.
#   * The pricing line must print the LITERAL text: $50 per node
#   * "counted hosts: N" must show the same real number, computed by a loop.
#
# Three faults are seeded: one in the here-document delimiter, one in
# here-document quoting, one in the way the loop is fed.

count=$(wc -l < /opt/lab1034/data/hosts.txt)

cat << EOF
    Lab inventory
    -------------
    hosts file : /opt/lab1034/data/hosts.txt
    host count : $count
    cost model : $50 per node
    EOF

total=0
cat /opt/lab1034/data/hosts.txt | while read -r h; do
    total=$((total + 1))
done
echo "counted hosts: $total"

exit 0
INVENTORY_EOF
    chmod 0755 "$BIN_INVENTORY"
}

seed_faults() {
    head1 "Seeding faults for topic $LAB_ID"

    mkdir -p "$LAB_ROOT" "$DATA_DIR" "$PRISTINE_DIR" "$LOG_DIR" "$STATE_DIR"

    write_sample_data
    say "  * sample data written to $DATA_DIR (pristine copy in $PRISTINE_DIR)"

    install_probe
    say "  * installed $BIN_PROBE (correct by design)"

    install_broken_collect
    say "  * installed $BIN_COLLECT              [FAULTS 4a-4d]"

    install_broken_inventory
    say "  * installed $BIN_INVENTORY            [FAULTS 5a-5c]"

    rm -f "$LOG_FILE"
    mkfifo -m 0644 "$LOG_FILE"
    say "  * $LOG_FILE is now a FIFO             [FAULT 3]"

    cat > "$PROFILE_FAULT" <<'PROFILE_FAULT_EOF'
# Seeded by the LPIC-1 103.4 break & fix lab. Remove me when you find me.
set -o noclobber
PROFILE_FAULT_EOF
    chmod 0644 "$PROFILE_FAULT"
    say "  * $PROFILE_FAULT sets noclobber       [FAULT 2]"

    # Done last on purpose: after this line, /dev/null is no longer a bit bucket.
    rm -f /dev/null
    : > /dev/null
    chown root:root /dev/null
    chmod 0600 /dev/null
    say "  * /dev/null replaced by a regular file [FAULT 1]"

    date -Is > "$STATE_FILE"
    briefing
}

briefing() {
    head1 "MISSION BRIEFING - LPIC-1 103.4 - Use streams, pipes and redirects"
    rule
    cat <<'BRIEF_EOF'
Five faults are live on this machine. All of them are about file descriptors,
redirection or pipes. You may edit the two scripts, recreate files and device
nodes, and change shell options. You may NOT edit lab-probe, and you may NOT
edit this lab script or its verifier.

SYMPTOMS YOU WILL SEE
---------------------
S1  A regular user runs `somecmd 2>/dev/null` and gets "Permission denied".
    As root the same redirection "works" but the noise is not discarded - it is
    being stored. `cat /dev/null` returns data instead of nothing, and
    `ls -l /dev/null` does not look like it does on a healthy system.

S2  In a NEW login shell (`bash -l`), `echo hi > /tmp/x` works once and then
    fails with "cannot overwrite existing file". Your current shell may still
    look fine - the fault only arrives with a fresh login shell.

S3  `lab-collect` hangs forever and never returns to the prompt. Ctrl-C is the
    only way out. Nothing is ever written to the report. `ls -l` on the report
    path shows a file type that is not a regular file.

S4  Once it stops hanging, `lab-collect` still misbehaves:
      a) each run wipes the previous report instead of adding to it;
      b) the error message from a missing /proc file is printed on YOUR
         terminal instead of being stored in the report, even though the
         command line clearly contains `2>&1`;
      c) the report says "warnings: 0" although lab-probe clearly emits two
         WARN lines;
      d) the sample log /opt/lab1034/data/app.log becomes EMPTY after the run,
         and the report then says "errors: 0".

S5  `lab-inventory` prints its own source code after the header, bash warns
    about a "here-document ... delimited by end-of-file", the price line shows
    "0 per node" instead of "$50 per node", and once that is fixed the loop
    still reports "counted hosts: 0".

WHAT YOU MUST ACHIEVE (the verifier grades exactly this)
--------------------------------------------------------
V1  /dev/null is a character device, major 1 minor 3, mode 666, root:root.
V2  A fresh login shell can overwrite an existing file with `>` again.
V3  /var/log/labcollect/report.log is a regular file.
V4  `lab-collect` returns immediately, prints NOTHING on the terminal, appends
    one "=== run" block per invocation, captures the `cat` error message inside
    the report, reports "warnings: 2", leaves app.log intact and reports a
    non-zero error count.
V5  `lab-inventory` prints "host count : 5", the literal string "$50 per node",
    and "counted hosts: 5".

TOOLS THAT MATTER HERE
----------------------
  >  >>  <  <<  <<-  <<<  2>  2>&1  &>  >|  |  |&  tee  xargs  exec  mkfifo
  mknod  stat  file  ls -l  lsof  set -o noclobber  shopt -s lastpipe
  /proc/<pid>/fd  /dev/fd  /dev/stdin  /dev/stdout  /dev/stderr

  Remember the two rules the exam loves:
    * the shell processes redirections LEFT TO RIGHT, and `2>&1` copies the
      CURRENT target of fd 1 - it is not a promise about the future;
    * the shell opens and TRUNCATES a `>` target before the command on the
      left of the pipeline ever reads it.

GRADE YOURSELF
--------------
  sudo /path/to/lab-103.4-break-and-fix.sh verify
  sudo /path/to/lab-103.4-break-and-fix.sh hint        (progressive, no spoilers)
  sudo /path/to/lab-103.4-break-and-fix.sh reset-data  (if you flattened app.log)
  sudo /path/to/lab-103.4-break-and-fix.sh restore     (give up / clean the VM)
BRIEF_EOF
    rule
}

show_status() {
    head1 "Current state"
    if devnull_is_sane; then
        say "  /dev/null            : OK ($(stat -c '%A %t:%T' /dev/null))"
    else
        say "  /dev/null            : BROKEN ($(stat -c '%A' /dev/null 2>/dev/null || echo missing))"
    fi
    if [[ -e "$PROFILE_FAULT" ]]; then
        say "  $PROFILE_FAULT : present"
    else
        say "  $PROFILE_FAULT : absent"
    fi
    if [[ -p "$LOG_FILE" ]]; then
        say "  report.log           : FIFO"
    elif [[ -f "$LOG_FILE" ]]; then
        say "  report.log           : regular file ($(stat -c '%s' "$LOG_FILE") bytes)"
    else
        say "  report.log           : missing"
    fi
    say "  app.log              : $(wc -l < "$DATA_DIR/app.log" 2>/dev/null || echo 0) lines"
    say "  seeded at            : $(cat "$STATE_FILE" 2>/dev/null || echo 'not seeded')"
}

check_devnull() {
    head1 "V1 - /dev/null is a real bit bucket"
    if devnull_is_sane; then
        pass "/dev/null is character device 1:3 with mode 666"
    else
        fail "/dev/null is not a 666 character device 1:3 (see: stat -c '%F %t:%T %a' /dev/null)"
    fi
}

check_noclobber() {
    head1 "V2 - a fresh login shell can truncate with >"
    local probe out
    probe="$(mktemp /tmp/lab1034.XXXXXX)"
    printf 'seed\n' > "$probe"
    out="$(bash -l -c "echo one > '$probe'; echo two > '$probe'" 2>&1)"
    if [[ -z "$out" && "$(cat "$probe")" == "two" ]]; then
        pass "login shell overwrote an existing file with > (noclobber is gone)"
    else
        fail "login shell still refuses to overwrite: ${out:-unexpected content}"
    fi
    rm -f "$probe"
}

check_logfile_type() {
    head1 "V3 - the report path is a regular file"
    if [[ -p "$LOG_FILE" ]]; then
        fail "$LOG_FILE is still a FIFO - any writer will block on open()"
        return 1
    fi
    if [[ -e "$LOG_FILE" && ! -f "$LOG_FILE" ]]; then
        fail "$LOG_FILE exists but is not a regular file"
        return 1
    fi
    pass "$LOG_FILE is a regular file (or absent, which lab-collect must create)"
    return 0
}

check_collect() {
    head1 "V4 - lab-collect behaves"
    if [[ -p "$LOG_FILE" ]]; then
        fail "skipping the run: report.log is a FIFO and the collector would block"
        return
    fi

    cp -f "$PRISTINE_DIR/app.log" "$DATA_DIR/app.log"
    rm -f "$LOG_FILE"

    local term rc
    term="$(mktemp /tmp/lab1034.term.XXXXXX)"

    timeout 20 "$BIN_COLLECT" > "$term" 2>&1
    rc=$?
    if [[ $rc -eq 124 ]]; then
        fail "lab-collect timed out after 20s - it is still blocking on a writer"
        rm -f "$term"
        return
    fi

    if [[ -s "$term" ]]; then
        fail "lab-collect wrote to the terminal instead of the report:"
        sed 's/^/           | /' "$term"
    else
        pass "lab-collect printed nothing on stdout/stderr"
    fi

    if [[ ! -s "$LOG_FILE" ]]; then
        fail "no report was produced at $LOG_FILE"
        rm -f "$term"
        return
    fi

    if grep -q 'lab-does-not-exist' "$LOG_FILE"; then
        pass "the stderr message from cat was captured inside the report"
    else
        fail "the report does not contain the 'lab-does-not-exist' error (check the ORDER of 2>&1)"
    fi

    if grep -q 'warnings: 2' "$LOG_FILE"; then
        pass "warnings counted correctly (2)"
    else
        fail "expected 'warnings: 2', found '$(grep -o 'warnings: .*' "$LOG_FILE" | head -1)' - stderr never entered the pipe"
    fi

    if [[ -s "$DATA_DIR/app.log" ]] && grep -q 'backend timeout' "$DATA_DIR/app.log"; then
        pass "app.log survived the deduplication pipeline"
    else
        fail "app.log was truncated by its own pipeline (the > target is opened before grep reads it)"
    fi

    if grep -qE 'errors: [1-9][0-9]*' "$LOG_FILE"; then
        pass "error count is non-zero ($(grep -o 'errors: .*' "$LOG_FILE" | head -1))"
    else
        fail "expected a non-zero 'errors:' line, found '$(grep -o 'errors: .*' "$LOG_FILE" | head -1)'"
    fi

    timeout 20 "$BIN_COLLECT" >> "$term" 2>&1
    local runs
    runs="$(grep -c '^=== run' "$LOG_FILE")"
    if [[ "$runs" -eq 2 ]]; then
        pass "two runs produced two '=== run' blocks (append, not truncate)"
    else
        fail "after two runs the report holds $runs '=== run' block(s) - the report is being clobbered"
    fi

    rm -f "$term"
}

check_inventory() {
    head1 "V5 - lab-inventory behaves"
    local out
    out="$(timeout 10 "$BIN_INVENTORY" 2>&1)"

    if printf '%s' "$out" | grep -qE 'host count[[:space:]]*:[[:space:]]*'"$HOST_COUNT"'\b'; then
        pass "host count expanded to $HOST_COUNT"
    else
        fail "host count line is wrong or missing"
    fi

    if printf '%s' "$out" | grep -qF '$50 per node'; then
        pass "the pricing line printed the literal \$50"
    else
        fail "expected the literal '\$50 per node' - the here-document is expanding it"
    fi

    if printf '%s' "$out" | grep -q 'here-document'; then
        fail "bash still warns about an unterminated here-document"
    elif printf '%s' "$out" | grep -qE '^[[:space:]]*(EOF|total=0|done)[[:space:]]*$'; then
        fail "the here-document swallowed the rest of the script (terminator not recognised)"
    else
        pass "the here-document is properly terminated"
    fi

    if printf '%s' "$out" | grep -qE "counted hosts: $HOST_COUNT\b"; then
        pass "the loop counted $HOST_COUNT hosts (no lost subshell variable)"
    else
        fail "expected 'counted hosts: $HOST_COUNT', got '$(printf '%s' "$out" | grep -o 'counted hosts: .*')'"
    fi
}

run_verify() {
    PASS_COUNT=0
    FAIL_COUNT=0
    check_devnull
    check_noclobber
    check_logfile_type
    check_collect
    check_inventory
    head1 "Result"
    rule
    if [[ $FAIL_COUNT -eq 0 ]]; then
        printf '%s  ALL %d CHECKS PASSED - topic %s repaired.%s\n' "$C_GRN$C_BLD" "$PASS_COUNT" "$LAB_ID" "$C_OFF"
        say "  Clean the VM with: sudo $0 restore"
        rule
        return 0
    fi
    printf '%s  %d passed, %d still failing.%s\n' "$C_RED$C_BLD" "$PASS_COUNT" "$FAIL_COUNT" "$C_OFF"
    say "  Need a nudge without the answer:  sudo $0 hint"
    rule
    return 1
}

show_hints() {
    head1 "Hints (each one is a question, not an answer)"
    cat <<'HINT_EOF'
H1  What does `ls -l /dev/null` print on a healthy system, and what do the two
    numbers where the size normally is actually mean? Which command creates a
    node with those numbers? (`man 1 mknod`, `man 4 null`)

H2  Which files does a LOGIN shell read that an interactive non-login shell
    does not? `grep -rn noclobber /etc/profile /etc/profile.d /etc/bash.bashrc`
    And what is the one-character escape hatch that forces `>` to truncate even
    when noclobber is set?

H3  `ls -l`, `file` and `stat -c %F` disagree with your assumption about the
    report path. What happens to `open(O_WRONLY)` on a FIFO when nobody has it
    open for reading?

H4  Read `uptime 2>&1 > "$LOG"` out loud, left to right, saying "fd 2 now points
    where fd 1 points RIGHT NOW" for the `2>&1` part. Where did fd 1 point at
    that instant? Now swap the two operators and read it again.
    For the pipe: `|` connects fd 1 only. What is the operator that connects
    both, and what is its portable long form?
    For the vanishing app.log: in `cmd < f | cmd2 > f`, which of the two files
    does the shell open first, and with which flag?

H5  A here-document terminator must be at the START of the line - unless you
    use the variant that strips leading TABS (only tabs). And an UNQUOTED
    delimiter makes the body behave like a double-quoted string. Which two ways
    do you have to print a literal dollar sign?
    Finally: `cat f | while read x; do y=1; done` - in bash, which member of a
    pipeline runs in the current shell, and which run in subshells? What does a
    subshell take with it when it exits?
HINT_EOF
    rule
}

reset_data() {
    write_sample_data
    say "sample data restored from $PRISTINE_DIR"
}

restore_all() {
    head1 "Restoring"
    fix_devnull
    say "  * /dev/null recreated as character device 1:3, mode 666"
    rm -f "$PROFILE_FAULT"
    say "  * $PROFILE_FAULT removed"
    rm -f "$LOG_FILE"
    rmdir "$LOG_DIR" 2>/dev/null
    say "  * report FIFO/file removed"
    rm -f "$BIN_COLLECT" "$BIN_PROBE" "$BIN_INVENTORY"
    say "  * lab binaries removed"
    rm -rf "$LAB_ROOT"
    say "  * $LAB_ROOT removed"
    rm -f "$STATE_FILE"
    rmdir "$STATE_DIR" 2>/dev/null
    say ""
    say "Open a NEW login shell to drop the old noclobber setting."
}

main() {
    local action="${1:-break}"
    case "$action" in
        break)
            require_root "$@"
            require_consent
            if [[ -e "$STATE_FILE" ]]; then
                warn "faults were already seeded on $(cat "$STATE_FILE"). Re-seeding."
            fi
            seed_faults
            ;;
        verify)     require_root "$@"; run_verify ;;
        hint)       show_hints ;;
        status)     show_status ;;
        reset-data) require_root "$@"; reset_data ;;
        restore)    require_root "$@"; restore_all ;;
        brief|briefing) briefing ;;
        *)
            say "usage: $0 {break|verify|hint|status|reset-data|restore|brief}"
            exit 2
            ;;
    esac
}

main "$@"

# =====================================================================
# ===============  SOLUTION - STOP READING IF STILL TRYING  ===========
# =====================================================================
#
# FAULT 1 - /dev/null is a regular file
# -------------------------------------
# Diagnosis:
#     $ ls -l /dev/null
#     -rw------- 1 root root 1483 Aug 26 09:14 /dev/null      <-- '-' not 'c'
#     $ stat -c '%F %t:%T %a' /dev/null
#     regular file 0:0 600
#   A healthy system shows:
#     crw-rw-rw- 1 root root 1, 3 Aug 26 09:14 /dev/null
#     character special file 1:3 666
#   The "1, 3" are the major and minor numbers of the kernel's null driver.
#   Because the impostor is mode 600 and root-owned, an unprivileged
#   `cmd 2>/dev/null` fails with EACCES; as root it silently GROWS a file that
#   was supposed to discard bytes, and `cmd < /dev/null` feeds the command
#   whatever junk accumulated instead of EOF.
#
# Fix:
#     rm -f /dev/null
#     mknod -m 0666 /dev/null c 1 3
#     chown root:root /dev/null
#   Verify:
#     echo test > /dev/null && cat /dev/null | wc -c     # -> 0
#   Note: on a systemd host you can also let udev rebuild it
#   (`udevadm trigger --name-match=null`), and inside a container the node is
#   normally provided by the runtime, not by udev.
#
#
# FAULT 2 - noclobber set system-wide
# -----------------------------------
# Diagnosis:
#     $ bash -l
#     $ echo hi > /tmp/x ; echo hi > /tmp/x
#     bash: /tmp/x: cannot overwrite existing file
#     $ set -o | grep noclobber
#     noclobber       on
#     $ grep -rn noclobber /etc/profile /etc/profile.d/ 2>/dev/null
#     /etc/profile.d/lab-noclobber.sh:2:set -o noclobber
#   noclobber makes `>` refuse to truncate an EXISTING regular file. It does not
#   affect `>>`, and it is bypassed per-redirection by `>|`.
#
# Fix:
#     rm -f /etc/profile.d/lab-noclobber.sh
#     set +o noclobber            # for the shell you are sitting in
#   Escape hatch worth knowing for the exam, when you cannot change the setting:
#     echo hi >| /tmp/x
#
#
# FAULT 3 - the report file is a FIFO
# -----------------------------------
# Diagnosis:
#     $ ls -l /var/log/labcollect/report.log
#     prw-r--r-- 1 root root 0 Aug 26 09:14 report.log      <-- leading 'p'
#     $ stat -c %F /var/log/labcollect/report.log
#     fifo
#   Opening a FIFO for writing BLOCKS until some process opens it for reading.
#   That is why lab-collect hung on its very first redirection and never printed
#   anything. Proof, from a second terminal while it hangs:
#     $ ls -l /proc/$(pgrep -f lab-collect)/fd
#     l-wx------ 1 root root 64 ... 1 -> /var/log/labcollect/report.log
#   (Reading the other end with `cat report.log` also unblocks it - a useful
#   trick to confirm the diagnosis before you change anything.)
#
# Fix:
#     rm -f /var/log/labcollect/report.log
#     : > /var/log/labcollect/report.log        # or let lab-collect create it
#     chmod 0644 /var/log/labcollect/report.log
#
#
# FAULT 4 - lab-collect, four redirection bugs
# --------------------------------------------
# 4a  Truncate instead of append.
#       BROKEN: echo "=== run $(date -Is) ===" > "$LOG"
#       FIXED : echo "=== run $(date -Is) ===" >> "$LOG"
#     `>` opens with O_TRUNC, `>>` with O_APPEND. Only O_APPEND is safe when
#     several writers share a log file: the offset is re-evaluated at every
#     write, so records cannot land on top of each other.
#
# 4b  `2>&1` on the wrong side of the redirection.
#       BROKEN: cat /proc/loadavg /proc/lab-does-not-exist 2>&1 >> "$LOG"
#       FIXED : cat /proc/loadavg /proc/lab-does-not-exist >> "$LOG" 2>&1
#     Redirections are applied LEFT TO RIGHT. In the broken form, `2>&1` first
#     makes fd 2 a duplicate of fd 1 *as it is at that moment* - the terminal -
#     and only then is fd 1 moved to the file. fd 2 keeps pointing at the
#     terminal: it copied the destination, not the name. In the fixed form fd 1
#     is moved to the file first, then fd 2 is pointed at the same open file
#     description. The compact bash-only synonym is `&>>` for append and `&>`
#     for truncate; `>file 2>&1` is the POSIX-portable spelling you should write
#     in scripts that may run under dash.
#     Apply the same fix to the `uptime` and `free -m` lines, and give the
#     header line an append too:
#       uptime  >> "$LOG" 2>&1
#       free -m >> "$LOG" 2>&1
#
# 4c  Only stdout enters a pipe.
#       BROKEN: lab-probe | grep -c '^WARN' >> "$LOG"
#       FIXED : lab-probe 2>&1 | grep -c '^WARN' >> "$LOG"
#       (bash >= 4 shorthand: lab-probe |& grep -c '^WARN' >> "$LOG")
#     `|` connects the writer's fd 1 to the reader's fd 0 and nothing else.
#     lab-probe emits its WARN lines on fd 2, so they went straight to the
#     terminal and grep counted an empty stream - hence "warnings: 0" while the
#     warnings were visible on screen. Note the ORDER again: here `2>&1` must
#     come BEFORE the pipe on the command line, because the pipe has already
#     redirected fd 1 by the time the command's own redirections are processed.
#     If you ever need the opposite - keep stderr out of the pipe but on screen
#     - the idiom is `cmd 2>/dev/null | ...`, and to send only stderr down the
#     pipe: `cmd 2>&1 1>/dev/null | ...`.
#
# 4d  A pipeline that truncates its own input.
#       BROKEN: grep -v '^#' "$DATA" | sort -u > "$DATA"
#       FIXED : tmp=$(mktemp)
#               grep -v '^#' "$DATA" | sort -u > "$tmp" && mv -f "$tmp" "$DATA"
#     The shell sets up ALL redirections of a pipeline before executing any
#     member, so `> "$DATA"` truncates the file to zero length before grep gets
#     a chance to read a single byte. The result is an empty file and, as a
#     side effect, "errors: 0". Alternatives to the temp file: `sponge` from
#     moreutils (`grep -v '^#' "$DATA" | sort -u | sponge "$DATA"`), or reading
#     the whole file into a variable first. `tee "$DATA"` does NOT save you -
#     tee opens the file with O_TRUNC just as early.
#
#   Corrected body of lab-collect:
#       LOG=/var/log/labcollect/report.log
#       DATA=/opt/lab1034/data/app.log
#       tmp=$(mktemp)
#
#       echo "=== run $(date -Is) ===" >> "$LOG"
#
#       uptime                                     >> "$LOG" 2>&1
#       free -m                                    >> "$LOG" 2>&1
#       cat /proc/loadavg /proc/lab-does-not-exist >> "$LOG" 2>&1
#
#       printf 'warnings: ' >> "$LOG"
#       lab-probe 2>&1 | grep -c '^WARN' >> "$LOG"
#
#       grep -v '^#' "$DATA" | sort -u > "$tmp" && mv -f "$tmp" "$DATA"
#
#       echo "errors: $(grep -c 'ERROR' "$DATA")" >> "$LOG"
#
#   A tidier idiom worth showing the student - redirect the WHOLE script once
#   with exec, so every later command inherits the report as fd 1 and fd 2:
#       exec >> "$LOG" 2>&1
#   after which the individual `>> "$LOG" 2>&1` suffixes are unnecessary. And if
#   you also want the output on screen while it is being stored, the tool is
#   `tee -a`:
#       { uptime; free -m; } 2>&1 | tee -a "$LOG"
#   Remember why `sudo echo x > /root/f` fails but `echo x | sudo tee -a /root/f`
#   works: the redirection is performed by YOUR shell, before sudo ever runs.
#
#
# FAULT 5 - lab-inventory, here-documents and the pipeline subshell
# ----------------------------------------------------------------
# 5a  Here-document terminator not recognised.
#     The delimiter line was written as "    EOF" (four spaces). With `<<EOF`
#     the terminator must be alone at the very start of the line, so bash never
#     found it, swallowed the rest of the file into the document and warned:
#       bash: warning: here-document at line 6 delimited by end-of-file
#     Two valid fixes:
#       * put EOF in column 0, or
#       * use `<<-EOF` and indent the terminator with TAB characters only
#         (`<<-` strips leading tabs from the body and the terminator; spaces
#         are NOT stripped - this is the classic trap when an editor expands
#         tabs to spaces).
#
# 5b  Unquoted delimiter expanded the price.
#     With `<<EOF` the body behaves like a double-quoted string: `$50` is read
#     as the positional parameter `$5` (unset, empty) followed by `0`, so the
#     line printed "cost model : 0 per node". Fixes, in order of preference for
#     this script, which still needs `$count` to expand:
#       cost model : \$50 per node
#     If NOTHING in the body should expand, quote the delimiter instead -
#     `<<'EOF'` or `<<"EOF"` - and inject the dynamic value another way.
#
# 5c  The counter is lost in a subshell.
#       BROKEN: cat hosts.txt | while read -r h; do total=$((total+1)); done
#       FIXED : while read -r h; do total=$((total+1)); done < /opt/lab1034/data/hosts.txt
#     Every member of a bash pipeline runs in its own subshell, so `total` was
#     incremented in a child process and discarded when that child exited -
#     the parent still printed 0. Feeding the loop with an input redirection
#     keeps it in the current shell. Other legitimate answers:
#       * shopt -s lastpipe  (plus `set +m`, and only in a non-interactive
#         shell) makes the LAST pipeline member run in the current shell;
#       * process substitution: while read -r h; do ...; done < <(cat hosts.txt)
#       * do the arithmetic where the data already is: total=$(wc -l < hosts.txt)
#     The `cat file |` prefix was also a useless use of cat: `wc -l < file` and
#     `done < file` avoid an extra process and an extra pipe entirely.
#
#   Corrected body of lab-inventory:
#       count=$(wc -l < /opt/lab1034/data/hosts.txt)
#
#       cat << EOF
#           Lab inventory
#           -------------
#           hosts file : /opt/lab1034/data/hosts.txt
#           host count : $count
#           cost model : \$50 per node
#       EOF
#
#       total=0
#       while read -r h; do
#           total=$((total + 1))
#       done < /opt/lab1034/data/hosts.txt
#       echo "counted hosts: $total"
#
#
# CLOSING DRILL (do this before you call the topic done)
# ------------------------------------------------------
#   1. Send stdout to one file and stderr to another:
#        cat /etc/hostname /nope > out.txt 2> err.txt
#   2. Send stderr into the pipe and drop stdout:
#        cat /etc/hostname /nope 2>&1 1>/dev/null | wc -l
#   3. Store and display at the same time, and feed a third consumer:
#        lab-probe 2>&1 | tee -a /tmp/probe.log | grep -c WARN
#   4. Build a command line from stdin, one argument per line, safely:
#        printf '%s\0' /tmp/a /tmp/b | xargs -0 -r -n1 basename
#   5. Herestring instead of an echo pipeline:
#        read -r a b <<< "left right"; echo "$b/$a"
#   6. Prove that fd 3 exists too:
#        exec 3> /tmp/fd3.log; echo "via fd 3" >&3; exec 3>&-; cat /tmp/fd3.log
#   7. Look at a running process's descriptors:
#        sleep 300 > /tmp/s.out 2>/dev/null & ls -l /proc/$!/fd; kill %1
#
# Sources:
#   LPI Exam 101-500 objectives, topic 103.4
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#   GNU Bash Reference Manual - Redirections
#     https://www.gnu.org/software/bash/manual/bash.html#Redirections
#   GNU Bash Reference Manual - Pipelines / The Set Builtin (noclobber, lastpipe)
#     https://www.gnu.org/software/bash/manual/bash.html#Pipelines
#     https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
#   POSIX.1-2024 Shell Command Language - Redirection
#     https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_07
#   Linux man-pages: null(4), fifo(7), mknod(1), mkfifo(1), tee(1), xargs(1)
#     https://man7.org/linux/man-pages/man4/null.4.html
#     https://man7.org/linux/man-pages/man7/fifo.7.html