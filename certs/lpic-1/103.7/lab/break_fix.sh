#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-1 (exam 101-500) — Topic 103.7: Search text files using regular
#  expressions
#  Weight: 4.69
#
#  BREAK & FIX LAB — "The log triage script that greps the wrong things"
#
#  WARNING: RUN THIS ONLY ON A DISPOSABLE LABORATORY VM.
#  It creates users, files under /opt, /etc/profile.d and /usr/local/bin, and
#  it deliberately installs a broken script plus a broken system-wide grep
#  default. Do not run it on a machine you care about.
#
#  Reference:
#    - LPI exam 101-500 objectives:
#        https://www.lpi.org/our-certifications/exam-101-objectives/
#    - GNU grep manual:
#        https://www.gnu.org/software/grep/manual/grep.html
#    - POSIX regular expressions (Basic and Extended):
#        https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html
#    - GNU sed manual:
#        https://www.gnu.org/software/sed/manual/sed.html
#
#  Exam-relevant commands and files touched by this lab:
#    grep, egrep, fgrep, grep -E, grep -F, sed, regex(7), GREP_OPTIONS/GREP_COLORS
# ============================================================================

set -o nounset
set -o pipefail

# ----------------------------------------------------------------------------
# Guard rails
# ----------------------------------------------------------------------------

LAB_ROOT="/opt/lpic1-1037-lab"
LAB_BIN="/usr/local/bin/logtriage"
LAB_PROFILE="/etc/profile.d/zz-lab-grep.sh"
LAB_MARKER="${LAB_ROOT}/.lab_installed"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this lab must be run as root (it writes to /opt, /etc and /usr/local/bin)." >&2
    echo "       Try: sudo $0" >&2
    exit 1
fi

if [ ! -e /etc/os-release ]; then
    echo "ERROR: /etc/os-release not found. This does not look like a Linux system." >&2
    exit 1
fi

echo
echo "==============================================================="
echo " LPIC-1 103.7 — Break & Fix lab: regular expressions with grep"
echo "==============================================================="
echo
echo "This script will modify THIS machine. It is meant for a throwaway VM."
echo "Directories/files it will create or overwrite:"
echo "  ${LAB_ROOT}"
echo "  ${LAB_BIN}"
echo "  ${LAB_PROFILE}"
echo
printf 'Type exactly YES-BREAK-MY-LAB-VM to continue: '
read -r CONFIRM
if [ "${CONFIRM}" != "YES-BREAK-MY-LAB-VM" ]; then
    echo "Aborted. Nothing was changed."
    exit 0
fi

# ----------------------------------------------------------------------------
# 1. Build the data set the student will search
# ----------------------------------------------------------------------------

install -d -m 0755 "${LAB_ROOT}"
install -d -m 0755 "${LAB_ROOT}/logs"
install -d -m 0755 "${LAB_ROOT}/conf"
install -d -m 0755 "${LAB_ROOT}/expected"

cat > "${LAB_ROOT}/logs/app.log" <<'EOF'
2026-03-01T06:12:04+00:00 web01 sshd[1201]: Accepted publickey for deploy from 10.0.2.15 port 51422 ssh2
2026-03-01T06:12:44+00:00 web01 sshd[1204]: Failed password for invalid user admin from 203.0.113.7 port 40122 ssh2
2026-03-01T06:12:45+00:00 web01 sshd[1204]: Failed password for invalid user admin from 203.0.113.7 port 40123 ssh2
2026-03-01T06:13:02+00:00 web01 kernel: [  912.334101] EXT4-fs (vda1): mounted filesystem with ordered data mode
2026-03-01T06:14:10+00:00 web01 app[2210]: INFO  request_id=8f2a1c handler=/api/v1/orders status=200 dur=12ms
2026-03-01T06:14:11+00:00 web01 app[2210]: WARN  request_id=8f2a1d handler=/api/v1/orders status=429 dur=3ms rate_limited
2026-03-01T06:14:12+00:00 web01 app[2210]: ERROR request_id=8f2a1e handler=/api/v1/orders status=500 dur=901ms upstream=payments-svc
2026-03-01T06:14:19+00:00 web01 app[2210]: ERROR request_id=8f2a1f handler=/api/v1/users  status=500 dur=755ms upstream=identity-svc
2026-03-01T06:15:00+00:00 web01 app[2210]: INFO  request_id=8f2a20 handler=/healthz       status=200 dur=1ms
2026-03-01T06:15:30+00:00 web01 app[2210]: DEBUG cache miss key=user:1001 ttl=300
2026-03-01T06:16:02+00:00 db01  postgres[880]: LOG:  checkpoint starting: time
2026-03-01T06:16:40+00:00 db01  postgres[880]: ERROR:  deadlock detected
2026-03-01T06:17:01+00:00 db01  postgres[880]: FATAL:  terminating connection due to administrator command
2026-03-01T06:18:00+00:00 web01 app[2210]: INFO  no error here, the word error appears only in prose
2026-03-01T06:18:30+00:00 web01 app[2210]: INFO  retrying after ERROR_BUDGET_EXHAUSTED=false
2026-03-01T06:19:00+00:00 cache1 redis[440]: # Server initialized
2026-03-01T06:19:20+00:00 cache1 redis[440]: * DB loaded from disk: 0.001 seconds
2026-03-01T06:20:00+00:00 web02 app[3311]: ERROR request_id=91bb02 handler=/api/v1/cart   status=503 dur=1200ms upstream=inventory-svc
2026-03-01T06:20:05+00:00 web02 app[3311]: INFO  request_id=91bb03 handler=/api/v1/cart   status=200 dur=8ms
2026-03-01T06:21:00+00:00 web02 sshd[3401]: Failed password for root from 198.51.100.44 port 33012 ssh2
EOF

cat > "${LAB_ROOT}/logs/access.log" <<'EOF'
10.0.2.15 - - [01/Mar/2026:06:14:10 +0000] "GET /api/v1/orders HTTP/1.1" 200 1122
203.0.113.7 - - [01/Mar/2026:06:14:11 +0000] "POST /api/v1/orders HTTP/1.1" 429 87
203.0.113.7 - - [01/Mar/2026:06:14:12 +0000] "POST /api/v1/orders HTTP/1.1" 500 512
198.51.100.44 - - [01/Mar/2026:06:14:20 +0000] "GET /../../etc/passwd HTTP/1.1" 400 0
10.0.2.15 - - [01/Mar/2026:06:15:00 +0000] "GET /healthz HTTP/1.1" 200 2
172.16.9.201 - - [01/Mar/2026:06:15:40 +0000] "GET /static/app.js HTTP/1.1" 304 0
999.1.1.1 - - [01/Mar/2026:06:15:41 +0000] "GET /spoofed HTTP/1.1" 200 5
10.0.2.15 - - [01/Mar/2026:06:16:00 +0000] "DELETE /api/v1/cart/17 HTTP/1.1" 204 0
2001:db8::42 - - [01/Mar/2026:06:16:30 +0000] "GET /api/v1/users HTTP/1.1" 500 301
198.51.100.44 - - [01/Mar/2026:06:17:10 +0000] "GET /wp-admin/ HTTP/1.1" 404 153
EOF

# Deliberately awkward file: it contains regex metacharacters as LITERAL text,
# a CRLF line, and a binary-looking line. All three break naive greps.
printf '%s\n' \
'# firewall.conf  (excerpt)' \
'allow 10.0.0.0/8' \
'allow 192.168.0.0/16' \
'deny  203.0.113.7' \
'# the next line is a literal regex written by a human, not a pattern:' \
'comment = "match a.b.c to catch a?b?c and [0-9]+ ranges"' \
'log_prefix = "IN=* OUT=*"' \
'timeout = 30' \
> "${LAB_ROOT}/conf/firewall.conf"
printf 'windows_style_line = yes\r\n' >> "${LAB_ROOT}/conf/firewall.conf"
printf 'binary_ish\x00marker = 1\n' >> "${LAB_ROOT}/conf/firewall.conf"

# The reference answer the student's fixed script must reproduce.
cat > "${LAB_ROOT}/expected/errors.txt" <<'EOF'
2026-03-01T06:14:12+00:00 web01 app[2210]: ERROR request_id=8f2a1e handler=/api/v1/orders status=500 dur=901ms upstream=payments-svc
2026-03-01T06:14:19+00:00 web01 app[2210]: ERROR request_id=8f2a1f handler=/api/v1/users  status=500 dur=755ms upstream=identity-svc
2026-03-01T06:20:00+00:00 web02 app[3311]: ERROR request_id=91bb02 handler=/api/v1/cart   status=503 dur=1200ms upstream=inventory-svc
EOF

cat > "${LAB_ROOT}/expected/offenders.txt" <<'EOF'
198.51.100.44
203.0.113.7
EOF

chmod 0644 "${LAB_ROOT}"/logs/* "${LAB_ROOT}"/conf/* "${LAB_ROOT}"/expected/*

# ----------------------------------------------------------------------------
# 2. Install the BROKEN triage script
#
#    Every defect below is a real regex mistake seen in production scripts:
#      (a) BRE vs ERE confusion: +, ?, |, () are literal in BRE.
#      (b) An unanchored, unbounded pattern that matches prose.
#      (c) A character class written as [0-9.]* which also matches the empty
#          string and non-IP text.
#      (d) grep -F used where a real regex is required.
#      (e) A metacharacter searched as a pattern instead of as a fixed string.
#      (f) Missing -w / anchors, so "ERROR_BUDGET_EXHAUSTED" is a false hit.
# ----------------------------------------------------------------------------

cat > "${LAB_BIN}" <<'BROKEN'
#!/usr/bin/env bash
#
# logtriage — quick triage of the lab logs.
# STATUS: BROKEN. Every report below returns the wrong lines.
# Your job (LPIC-1 103.7) is to repair the regular expressions.
#
# Data:
#   /opt/lpic1-1037-lab/logs/app.log
#   /opt/lpic1-1037-lab/logs/access.log
#   /opt/lpic1-1037-lab/conf/firewall.conf
#
# Expected output (do NOT edit these files):
#   /opt/lpic1-1037-lab/expected/errors.txt
#   /opt/lpic1-1037-lab/expected/offenders.txt

set -u

LAB_ROOT="/opt/lpic1-1037-lab"
APP_LOG="${LAB_ROOT}/logs/app.log"
ACCESS_LOG="${LAB_ROOT}/logs/access.log"
FW_CONF="${LAB_ROOT}/conf/firewall.conf"

report_errors() {
    # GOAL: print ONLY the application ERROR lines from app.log
    #       (the three app[NNNN]: ERROR lines), and nothing else.
    # BUG:  bare, unanchored, case-insensitive-by-accident match on a word
    #       that also appears in prose and inside ERROR_BUDGET_EXHAUSTED.
    grep -i "error" "${APP_LOG}"
}

report_offenders() {
    # GOAL: print the distinct, sorted, VALID IPv4 addresses that appear in
    #       access.log with a 4xx or 5xx status. Expected: 198.51.100.44 and
    #       203.0.113.7 only.  999.1.1.1 is NOT a valid IPv4 address.
    # BUG:  BRE has no +, no | and no (); [0-9.]* matches the empty string.
    grep "^[0-9.]* .* (4|5)[0-9]+$" "${ACCESS_LOG}" \
        | grep -o "^[0-9.]*" \
        | sort -u
}

report_ports() {
    # GOAL: print every SSH source port from app.log as "port NNNNN".
    # BUG:  \{2,\} style repetition is BRE; here it is mixed with ERE syntax.
    grep -E "port [0-9]\{4,5\}" "${APP_LOG}"
}

report_literal_metachars() {
    # GOAL: show the firewall.conf line that literally contains the string
    #       [0-9]+  (a human comment, not a pattern).
    # BUG:  the brackets and + are being interpreted as a regex.
    grep "[0-9]+" "${FW_CONF}"
}

report_cidr() {
    # GOAL: list the CIDR "allow" networks, matching the literal dot and slash.
    # BUG:  -F disables the regex entirely, so the alternation never works.
    grep -F "allow 10.0.0.0/8|allow 192.168.0.0/16" "${FW_CONF}"
}

report_ipv6() {
    # GOAL: match the IPv6 client (2001:db8::42) in access.log.
    # BUG:  the colon-heavy pattern is unquoted and unescaped where needed.
    grep 2001:db8::42 "${ACCESS_LOG}"
}

echo "=== ERRORS ==="            ; report_errors
echo "=== OFFENDER IPs ==="      ; report_offenders
echo "=== SSH PORTS ==="         ; report_ports
echo "=== LITERAL METACHARS ===" ; report_literal_metachars
echo "=== CIDR ALLOW ==="        ; report_cidr
echo "=== IPV6 CLIENT ==="       ; report_ipv6
BROKEN

chmod 0755 "${LAB_BIN}"

# ----------------------------------------------------------------------------
# 3. Second, sneakier breakage: a system-wide grep default.
#
#    GREP_OPTIONS was removed in GNU grep 2.21+, so on a modern system it does
#    nothing except print a warning — which is itself a teaching moment. The
#    breakage that actually BITES on a modern box is an alias plus a colour
#    setting that injects ANSI escapes into piped output.
# ----------------------------------------------------------------------------

cat > "${LAB_PROFILE}" <<'PROFILE'
# Installed by the LPIC-1 103.7 break & fix lab. Remove me when you are done.
# Two different traps live here:
#
#   1) GREP_OPTIONS: obsolete since GNU grep 2.21. Modern grep prints
#      "grep: warning: GREP_OPTIONS is deprecated" on EVERY invocation, which
#      pollutes stderr and breaks scripts that check for empty stderr.
#   2) An alias that forces --color=always. Colour is fine on a terminal, but
#      --color=always emits ANSI escapes even when stdout is a pipe, so
#      downstream sort/uniq/cut see invisible \033[01;31m garbage.
export GREP_OPTIONS='--color=always'
alias grep='grep --color=always -i'
PROFILE
chmod 0644 "${LAB_PROFILE}"

touch "${LAB_MARKER}"

# ----------------------------------------------------------------------------
# 4. Brief the student
# ----------------------------------------------------------------------------

cat <<'BRIEF'

---------------------------------------------------------------------------
  BREAKAGE INSTALLED.
---------------------------------------------------------------------------

WHAT WAS BROKEN
  * /usr/local/bin/logtriage — a triage script whose six regular expressions
    are all wrong in a different, classic way.
  * /etc/profile.d/zz-lab-grep.sh — a system-wide grep default that sets the
    obsolete GREP_OPTIONS variable and aliases grep to --color=always -i.

SYMPTOMS YOU WILL SEE
  1. Open a NEW login shell (`su - $USER` or log out and back in), then run:

         logtriage

  2. "=== ERRORS ===" prints six lines instead of three: it also catches the
     prose line "no error here...", the ERROR_BUDGET_EXHAUSTED line, and the
     postgres "ERROR:  deadlock detected" line from a different service.
  3. "=== OFFENDER IPs ===" prints nothing at all. The pattern uses ERE syntax
     ( + | ( ) ) while grep is running in BRE mode, so those characters are
     matched literally and never occur in the file.
  4. "=== SSH PORTS ===" prints nothing: it feeds BRE interval syntax
     \{4,5\} to grep -E, where the backslashes make the braces literal.
  5. "=== LITERAL METACHARS ===" prints several unrelated lines, because
     [0-9]+ is being interpreted as "a digit, one or more times" instead of
     as the literal six-character string the config comment contains.
  6. "=== CIDR ALLOW ===" prints nothing: -F turns the whole pattern,
     alternation included, into one fixed string.
  7. "=== IPV6 CLIENT ===" may or may not work, and if you pipe it into
     `cut -d' ' -f1` you get invisible ANSI escapes glued to the address.
  8. Depending on your grep version you will also see, on every single call:
         grep: warning: GREP_OPTIONS is deprecated; use an alias or script

WHAT YOU MUST ACHIEVE
  A. `logtriage` runs with NO warnings on stderr.
  B. These two comparisons both succeed, byte for byte:

         logtriage | sed -n '/^=== ERRORS ===$/,/^=== OFFENDER IPs ===$/p' \
             | grep -v '^===' | diff -u /opt/lpic1-1037-lab/expected/errors.txt -

         logtriage | sed -n '/^=== OFFENDER IPs ===$/,/^=== SSH PORTS ===$/p' \
             | grep -v '^===' | diff -u /opt/lpic1-1037-lab/expected/offenders.txt -

     (Simpler check, if you prefer: make each report function write to a file
      and diff that file against the matching one in expected/.)
  C. SSH PORTS prints exactly the four sshd lines that contain a port number.
  D. LITERAL METACHARS prints exactly one line — the `comment = "..."` line.
  E. CIDR ALLOW prints exactly the two `allow` lines.
  F. IPV6 CLIENT prints exactly the 2001:db8::42 line, and piping it through
     `cut -d' ' -f1` yields a clean address with no escape sequences.
  G. Nothing in expected/ is edited. You fix the patterns, not the answers.

RULES OF THE GAME
  * Only grep/egrep/fgrep/sed and shell built-ins. No awk, no perl, no python.
  * You may change /usr/local/bin/logtriage and /etc/profile.d/zz-lab-grep.sh.
  * Back the script up first:  cp /usr/local/bin/logtriage{,.orig}

USEFUL THINGS TO READ
  man 7 regex      man 1 grep      man 1 sed
  grep --help | less
  https://www.gnu.org/software/grep/manual/grep.html

RESET (start over from scratch):
  rm -f /usr/local/bin/logtriage /etc/profile.d/zz-lab-grep.sh
  rm -rf /opt/lpic1-1037-lab
  ...then re-run this script.

Good luck. The solution is at the bottom of this script, commented out.
Do not read it until you have spent real time with `man 7 regex`.
---------------------------------------------------------------------------

BRIEF

exit 0

# ===========================================================================
#
#                        S O L U T I O N   —   S P O I L E R
#
#   Everything below this line is commented out. Read it only after you have
#   tried. The order below is the order a real operator would work in:
#   stabilise the environment first, then fix one pattern at a time, verifying
#   each against the expected/ files before moving on.
#
# ===========================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 — Understand the two regex dialects. This is the whole objective.
# ---------------------------------------------------------------------------
#
#   grep uses POSIX Basic Regular Expressions (BRE) by default.
#   grep -E (historically `egrep`) uses Extended Regular Expressions (ERE).
#   grep -F (historically `fgrep`) uses NO regular expressions at all: the
#   pattern is a fixed string, metacharacters included.
#
#   In BRE these are LITERAL characters:   +  ?  |  (  )  {  }
#   To get their special meaning in BRE you must backslash-escape them:
#       \+  \?  \|  \(  \)  \{2,5\}
#   In ERE they are special as written, and a backslash makes them LITERAL:
#       +   ?   |   (   )   {2,5}      vs   \+  \?  \|  \(  \)  \{
#
#   That inversion is the single most common source of "my grep matches
#   nothing" in production. Memorise it:
#
#       BRE:  grep  'colou\?r'            ERE:  grep -E 'colou?r'
#       BRE:  grep  '[0-9]\{1,3\}'        ERE:  grep -E '[0-9]{1,3}'
#       BRE:  grep  'cat\|dog'            ERE:  grep -E 'cat|dog'
#       BRE:  grep  '\(ab\)\+'            ERE:  grep -E '(ab)+'
#
#   These are special in BOTH dialects:   .  *  [  ]  ^  $  \
#   And these GNU extensions work in both: \b \< \> \w \W \s \S
#   (they are GNU, not POSIX — do not rely on them on busybox or on macOS.)
#
#   Verify the claim yourself before trusting it:
#
#       $ printf 'colour\ncolor\n' | grep 'colou?r'      # BRE: no match
#       $ printf 'colour\ncolor\n' | grep 'colou\?r'     # BRE escaped: both
#       colour
#       color
#       $ printf 'colour\ncolor\n' | grep -E 'colou?r'   # ERE: both
#       colour
#       color
#
# ---------------------------------------------------------------------------
# STEP 1 — Kill the environment breakage first.
# ---------------------------------------------------------------------------
#
#   Diagnose it before deleting it, so you know what you are looking at:
#
#       $ echo "$GREP_OPTIONS"
#       --color=always
#       $ type grep
#       grep is aliased to `grep --color=always -i'
#       $ grep --version | head -1
#       grep (GNU grep) 3.11
#
#   GREP_OPTIONS was deprecated in GNU grep 2.21 (2014) and removed later;
#   modern grep warns on every invocation. It was removed precisely because a
#   global variable that silently rewrites every grep in every script is a
#   footgun — exactly the bug this lab reproduces. See:
#       https://www.gnu.org/software/grep/manual/grep.html#Environment-Variables
#
#   The alias is worse in a subtle way: --color=always emits SGR escapes even
#   when stdout is not a terminal. Prove it:
#
#       $ grep --color=always 10.0.2.15 /opt/lpic1-1037-lab/logs/access.log \
#             | cut -d' ' -f1 | cat -A | head -1
#       ^[[01;31m^[[K10.0.2.15^[[m^[[K$
#
#       $ grep --color=auto 10.0.2.15 /opt/lpic1-1037-lab/logs/access.log \
#             | cut -d' ' -f1 | cat -A | head -1
#       10.0.2.15$
#
#   `--color=auto` is the correct setting: colour on a TTY, plain bytes in a
#   pipe. Note also that aliases are a shell-interactive feature — they are
#   NOT inherited by scripts — so the alias explains what you see when you
#   type grep by hand, while GREP_OPTIONS (being exported) is what leaks into
#   the script. Two different mechanisms, two different blast radii.
#
#   Fix:
#
#       # rm -f /etc/profile.d/zz-lab-grep.sh
#       # unalias grep 2>/dev/null
#       # unset GREP_OPTIONS
#
#   If you want colour back, do it the supported way — an alias with
#   --color=auto, never an exported options variable:
#
#       # cat > /etc/profile.d/zz-lab-grep.sh <<'EOF'
#       alias grep='grep --color=auto'
#       EOF
#
#   Then open a fresh login shell and confirm the warning is gone:
#
#       $ logtriage 2>&1 >/dev/null | wc -l
#       0
#
# ---------------------------------------------------------------------------
# STEP 2 — report_errors: anchor the match to the field you actually mean.
# ---------------------------------------------------------------------------
#
#   The broken version:   grep -i "error" app.log
#
#   Three separate defects:
#     * -i makes it case-insensitive, so the prose word "error" matches.
#     * No word boundary, so ERROR_BUDGET_EXHAUSTED matches.
#     * No structural anchor, so postgres's "ERROR:  deadlock" matches even
#       though the goal is the app[NNNN] service only.
#
#   Walk the fix in stages, checking the count each time:
#
#       $ grep -ci 'error' app.log
#       6
#       $ grep -c 'ERROR' app.log            # drop -i: case matters here
#       5
#       $ grep -c '\bERROR\b' app.log        # \b kills ERROR_BUDGET_...
#       4                                    # (still catches postgres ERROR:)
#       $ grep -cE 'app\[[0-9]+\]: ERROR ' app.log
#       3
#
#   The final form ties the match to the log's STRUCTURE, not to a bare word.
#   That is the production lesson: match the field, not the substring.
#
#       report_errors() {
#           grep -E 'app\[[0-9]+\]: ERROR ' "${APP_LOG}"
#       }
#
#   Note `\[` — a literal bracket must be escaped, or [0-9] would be read as
#   the start of a bracket expression. `[0-9]+` needs ERE (or `[0-9]\+` in
#   BRE). The trailing space after ERROR is what excludes ERROR_BUDGET.
#
#   Equivalent pure-BRE version, for the exam:
#
#           grep 'app\[[0-9][0-9]*\]: ERROR ' "${APP_LOG}"
#
#   Verify:
#       $ report_errors | diff -u /opt/lpic1-1037-lab/expected/errors.txt -
#       (no output = identical)
#
# ---------------------------------------------------------------------------
# STEP 3 — report_offenders: valid IPv4 + status class, in one ERE.
# ---------------------------------------------------------------------------
#
#   The broken version:
#       grep "^[0-9.]* .* (4|5)[0-9]+$"
#
#   Defects:
#     * `(4|5)` and `+` are LITERAL in BRE — the file contains no parentheses
#       or plus signs in those positions, so zero lines match.
#     * `[0-9.]*` matches the empty string and also matches 999.1.1.1 and
#       even a bare "...", so it is not an IPv4 validator.
#     * The status code is not the last field: the byte count is. `$` after
#       the status can never match.
#
#   Build it up, testing each stage:
#
#       # Stage 1 — an octet, 0-255, as an ERE fragment:
#       #   25[0-5] | 2[0-4][0-9] | [01]?[0-9][0-9]?
#       $ OCT='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
#       $ printf '255\n256\n0\n99\n999\n' | grep -E "^${OCT}$"
#       255
#       0
#       99
#
#       # Stage 2 — a full dotted quad anchored at start of line.
#       #   Note \. : an unescaped dot matches ANY character, so 1x2x3x4
#       #   would pass. Escaping the dot is the point of the exercise.
#       $ IPV4="^${OCT}\.${OCT}\.${OCT}\.${OCT} "
#       $ grep -cE "${IPV4}" access.log
#       9                                     # 999.1.1.1 correctly excluded
#
#       # Stage 3 — the 4xx/5xx status is the second-to-last field.
#       #   "..." <SP> STATUS <SP> BYTES <EOL>
#       $ grep -E '"[^"]*" [45][0-9][0-9] [0-9]+$' access.log | wc -l
#       4
#
#       # Stage 4 — combine, then cut the address off the front.
#       #   grep -o prints only the matched part, which is why the trailing
#       #   space is dropped from the -o pattern.
#
#       report_offenders() {
#           local oct='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
#           local ipv4="^${oct}\.${oct}\.${oct}\.${oct}"
#           grep -E "${ipv4} .*\"[^\"]*\" [45][0-9][0-9] [0-9]+$" "${ACCESS_LOG}" \
#               | grep -oE "${ipv4}" \
#               | sort -u
#       }
#
#   Expected:
#       $ report_offenders
#       198.51.100.44
#       203.0.113.7
#
#   Why `sort -u` and not `uniq`: uniq only collapses ADJACENT duplicates.
#   `sort -u` is the correct idiom for distinct values, and it also gives you
#   the deterministic ordering the expected/ file assumes. (Set LC_ALL=C if
#   you want that ordering to be locale-independent — worth knowing, because
#   collation order silently changes what `sort` and even `[a-z]` mean.)
#
#       $ LC_ALL=C ; export LC_ALL     # in scripts that must be reproducible
#
# ---------------------------------------------------------------------------
# STEP 4 — report_ports: intervals belong to one dialect at a time.
# ---------------------------------------------------------------------------
#
#   The broken version:   grep -E "port [0-9]\{4,5\}"
#
#   Under -E, `\{` is an ESCAPED brace, i.e. a literal `{`. The pattern
#   therefore looks for the text  port <digit>{4,5}  which never occurs.
#   The same string works fine WITHOUT -E, because in BRE `\{4,5\}` is the
#   interval operator. This is the mirror image of the STEP 0 table.
#
#       $ grep -cE 'port [0-9]\{4,5\}' app.log
#       0
#       $ grep -c  'port [0-9]\{4,5\}' app.log     # BRE: correct
#       4
#       $ grep -cE 'port [0-9]{4,5}'   app.log     # ERE: also correct
#       4
#
#   Pick one dialect and be consistent. ERE, to match the rest of the script:
#
#       report_ports() {
#           grep -E 'port [0-9]{4,5}' "${APP_LOG}"
#       }
#
#   If you only want the port numbers rather than whole lines, -o plus a
#   trailing-context trick:
#
#       $ grep -oE 'port [0-9]{4,5}' app.log | sort -u
#       port 33012
#       port 40122
#       port 40123
#       port 51422
#
# ---------------------------------------------------------------------------
# STEP 5 — report_literal_metachars: when the pattern IS the data.
# ---------------------------------------------------------------------------
#
#   The broken version:   grep "[0-9]+"  firewall.conf
#
#   That asks for "a digit followed by a literal plus" in BRE, or "one or
#   more digits" in ERE — either way it matches many lines. The goal is the
#   literal six characters  [0-9]+  as typed by a human in a comment.
#
#   Two correct answers, and knowing both is the exam point:
#
#     (a) Fixed-string mode — no regex engine at all:
#           $ grep -F '[0-9]+' firewall.conf
#           comment = "match a.b.c to catch a?b?c and [0-9]+ ranges"
#
#     (b) Escape every metacharacter by hand (BRE):
#           $ grep '\[0-9\]+' firewall.conf
#           comment = "match a.b.c to catch a?b?c and [0-9]+ ranges"
#
#   (a) is what you want in a script: it is faster, it cannot be broken by a
#   metacharacter appearing in user input, and it states the intent. Use -F
#   whenever the pattern comes from a variable you did not construct.
#
#       report_literal_metachars() {
#           grep -F '[0-9]+' "${FW_CONF}"
#       }
#
#   Related trap in the same file: the CRLF line. A pattern anchored with $
#   will not match `windows_style_line = yes\r` because \r sits between `yes`
#   and end of line:
#
#       $ grep -c 'yes$' firewall.conf
#       0
#       $ grep -c $'yes\r$' firewall.conf
#       1
#       $ sed -i 's/\r$//' firewall.conf   # the usual repair
#
#   And the NUL byte: grep treats the file as binary and, instead of printing
#   matches, says so. Force text mode with -a (or --binary-files=text):
#
#       $ grep 'marker' firewall.conf
#       grep: firewall.conf: binary file matches
#       $ grep -a 'marker' firewall.conf
#       binary_ish<00>marker = 1
#
# ---------------------------------------------------------------------------
# STEP 6 — report_cidr: alternation needs a regex, so drop -F.
# ---------------------------------------------------------------------------
#
#   The broken version:
#       grep -F "allow 10.0.0.0/8|allow 192.168.0.0/16"
#
#   With -F the pipe is just a pipe character, so grep looks for one long
#   string containing it. Nothing matches.
#
#   Three correct forms, cheapest first:
#
#     (a) Simplest — the lines you want all start with `allow`:
#           $ grep -E '^allow ' firewall.conf
#           allow 10.0.0.0/8
#           allow 192.168.0.0/16
#
#     (b) Explicit alternation in ERE, dots escaped, slash literal:
#           $ grep -E '^allow (10\.0\.0\.0/8|192\.168\.0\.0/16)$' firewall.conf
#
#     (c) Multiple fixed patterns — -F does support several patterns, one per
#         line, which is the right tool when the strings come from a file:
#           $ grep -F -e 'allow 10.0.0.0/8' -e 'allow 192.168.0.0/16' firewall.conf
#           $ printf '%s\n' 'allow 10.0.0.0/8' 'allow 192.168.0.0/16' \
#                 > /tmp/nets.txt
#           $ grep -F -f /tmp/nets.txt firewall.conf
#
#   `/` has no special meaning to grep — it is sed where you would need to
#   escape it or change the delimiter (`sed 's|a/b|c|'`). Do not escape it
#   here out of habit; `\/` in an ERE is undefined-but-usually-tolerated.
#
#       report_cidr() {
#           grep -E '^allow (10\.0\.0\.0/8|192\.168\.0\.0/16)$' "${FW_CONF}"
#       }
#
# ---------------------------------------------------------------------------
# STEP 7 — report_ipv6: quoting, and the colon that is not special.
# ---------------------------------------------------------------------------
#
#   The broken version:   grep 2001:db8::42 access.log
#
#   `:` is NOT a regex metacharacter, so the pattern itself is fine — the bug
#   is the missing quotes. Unquoted patterns are exposed to shell globbing
#   and word splitting; the day someone edits it to `2001:db8::4?` the shell
#   may expand it against filenames and grep receives something else entirely.
#
#       $ touch '2001:db8::4X'
#       $ echo 2001:db8::4?
#       2001:db8::4X                      # the shell ate your pattern
#
#   ALWAYS single-quote regex patterns. Then add anchoring so the match is
#   deliberate:
#
#       report_ipv6() {
#           grep -E '^2001:db8::42 ' "${ACCESS_LOG}"
#       }
#
#   Combined with STEP 1's colour fix, the pipe is now clean:
#
#       $ report_ipv6 | cut -d' ' -f1
#       2001:db8::42
#
# ---------------------------------------------------------------------------
# STEP 8 — The complete repaired script.
# ---------------------------------------------------------------------------
#
#   #!/usr/bin/env bash
#   set -u
#   export LC_ALL=C          # reproducible collation and character classes
#
#   LAB_ROOT="/opt/lpic1-1037-lab"
#   APP_LOG="${LAB_ROOT}/logs/app.log"
#   ACCESS_LOG="${LAB_ROOT}/logs/access.log"
#   FW_CONF="${LAB_ROOT}/conf/firewall.conf"
#
#   OCT='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
#   IPV4="^${OCT}\.${OCT}\.${OCT}\.${OCT}"
#
#   report_errors() {
#       grep -E 'app\[[0-9]+\]: ERROR ' "${APP_LOG}"
#   }
#
#   report_offenders() {
#       grep -E "${IPV4} .*\"[^\"]*\" [45][0-9][0-9] [0-9]+$" "${ACCESS_LOG}" \
#           | grep -oE "${IPV4}" \
#           | sort -u
#   }
#
#   report_ports() {
#       grep -E 'port [0-9]{4,5}' "${APP_LOG}"
#   }
#
#   report_literal_metachars() {
#       grep -F '[0-9]+' "${FW_CONF}"
#   }
#
#   report_cidr() {
#       grep -E '^allow (10\.0\.0\.0/8|192\.168\.0\.0/16)$' "${FW_CONF}"
#   }
#
#   report_ipv6() {
#       grep -E '^2001:db8::42 ' "${ACCESS_LOG}"
#   }
#
#   echo "=== ERRORS ==="            ; report_errors
#   echo "=== OFFENDER IPs ==="      ; report_offenders
#   echo "=== SSH PORTS ==="         ; report_ports
#   echo "=== LITERAL METACHARS ===" ; report_literal_metachars
#   echo "=== CIDR ALLOW ==="        ; report_cidr
#   echo "=== IPV6 CLIENT ==="       ; report_ipv6
#
# ---------------------------------------------------------------------------
# STEP 9 — Final verification.
# ---------------------------------------------------------------------------
#
#       $ logtriage 2>&1 >/dev/null | wc -l
#       0
#
#       $ logtriage | sed -n '/^=== ERRORS ===$/,/^=== OFFENDER IPs ===$/p' \
#             | grep -v '^===' \
#             | diff -u /opt/lpic1-1037-lab/expected/errors.txt -
#       $ echo $?
#       0
#
#       $ logtriage | sed -n '/^=== OFFENDER IPs ===$/,/^=== SSH PORTS ===$/p' \
#             | grep -v '^===' \
#             | diff -u /opt/lpic1-1037-lab/expected/offenders.txt -
#       $ echo $?
#       0
#
#   Note the sed idiom used above — it is exam material in its own right:
#   `sed -n '/START/,/END/p'` prints an ADDRESS RANGE delimited by two
#   regular expressions. `-n` suppresses the default print so only `p` emits.
#
# ---------------------------------------------------------------------------
# STEP 10 — Exam-level recap of what this lab exercised.
# ---------------------------------------------------------------------------
#
#   Anchors and boundaries
#       ^  start of line          $  end of line
#       \< start of word          \> end of word         \b either boundary
#       (\< \> \b are GNU extensions, not POSIX)
#
#   Quantifiers                     BRE form        ERE form
#       zero or more                *               *
#       one or more                 \+              +
#       zero or one                 \?              ?
#       exactly n                   \{n\}           {n}
#       n to m                      \{n,m\}         {n,m}
#       n or more                   \{n,\}          {n,}
#
#   Grouping and alternation        \( \)  \|       ( )  |
#   Back-references                 \1 .. \9        \1 .. \9   (both)
#
#   Bracket expressions (identical in BRE and ERE)
#       [abc]  [^abc]  [a-z]  [[:digit:]]  [[:alpha:]]  [[:space:]]
#       [[:alnum:]] [[:upper:]] [[:lower:]] [[:punct:]] [[:xdigit:]]
#       Inside brackets, ] must come FIRST and - must come LAST or first:
#           []-]  matches ] or -
#       Prefer [[:digit:]] over [0-9] when the locale is not C.
#
#   grep options worth knowing cold for 101-500
#       -E  ERE          -F  fixed strings     -G  BRE (default)  -P  PCRE (GNU)
#       -i  ignore case  -v  invert            -c  count          -l  files with
#       -L  files without                      -n  line numbers   -H/-h filename
#       -w  whole word   -x  whole line        -o  matched part only
#       -r/-R recursive  -e PAT (repeatable)   -f FILE (patterns from file)
#       -A/-B/-C n  after/before/around context
#       -a  treat binary as text               -q  quiet, exit status only
#       --include/--exclude GLOB               --color=auto|always|never
#
#   Exit status contract (this is what scripts branch on):
#       0  at least one line matched
#       1  no line matched
#       2  an error occurred (bad pattern, unreadable file)
#       Therefore `if grep -q PAT file; then ...` is correct, and
#       `set -e` will kill your script on a legitimate no-match unless you
#       write  `grep -q PAT file || true`.
#
#   sed essentials that pair with grep in this objective
#       sed -n '/re/p'            print matching lines (grep equivalent)
#       sed '/re/d'               delete matching lines (grep -v equivalent)
#       sed -n '5,10p'            line-number range
#       sed -n '/A/,/B/p'         regex address range
#       sed 's/re/repl/g'         substitute, globally on each line
#       sed -E 's/(a)(b)/\2\1/'   ERE mode, back-references in the replacement
#       sed -i.bak 's/x/y/'       edit in place, keeping file.bak
#       &  in the replacement means "the whole match"
#
#   The one habit that prevents most of these bugs
#       Single-quote every pattern; choose -F when the pattern is data;
#       choose -E when you need + ? | ( ) { }; and test the pattern against a
#       known-good sample with `grep -c` before wiring it into a script.
#
#   Sources
#       LPI 101-500 objectives:
#         https://www.lpi.org/our-certifications/exam-101-objectives/
#       GNU grep manual:
#         https://www.gnu.org/software/grep/manual/grep.html
#       GNU sed manual:
#         https://www.gnu.org/software/sed/manual/sed.html
#       POSIX regular expressions (Base Specifications, Chapter 9):
#         https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html
#
# ===========================================================================
#                             END OF SOLUTION
# ===========================================================================