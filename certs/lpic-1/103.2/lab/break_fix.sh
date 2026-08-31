#!/usr/bin/env bash
#===============================================================================
# LPIC-1 v5.0 / Exam 101-500 — Topic 103.2  "Process text streams using filters"
# Weight: 3.12
#
# BREAK & FIX LABORATORY  —  run ONLY on a disposable lab VM.
#
# What this script does:
#   * Creates a self-contained lab tree under $LAB_ROOT (default ~/lpic1-103.2-lab)
#   * Installs a small "production" reporting tool (bin/report.sh) built entirely
#     out of text filters: cut, sort, uniq, head, tail, tr, sed, nl, wc, zcat
#   * Records the checksum of the CORRECT output of every section
#   * Then breaks four things — three in the pipelines, one in the data itself
#   * Gives you the symptom and the objective for each break
#   * './lab.sh check' tells you, section by section, whether you fixed it
#
# What this script NEVER does: touch /etc, systemd units, packages, users,
# networking or anything outside $LAB_ROOT. Everything is reversible with
# './lab.sh reset' (re-break) or './lab.sh clean' (delete the whole lab tree).
#
# Official objective reference:
#   https://www.lpi.org/our-certifications/exam-101-objectives/
# Utility documentation used by this lab:
#   https://www.gnu.org/software/coreutils/manual/coreutils.html
#   https://www.gnu.org/software/sed/manual/sed.html
#   https://www.gnu.org/software/gzip/manual/gzip.html
#===============================================================================

set -Eeuo pipefail

LAB_ROOT="${LAB_ROOT:-$HOME/lpic1-103.2-lab}"
DATA="$LAB_ROOT/data"
BIN="$LAB_ROOT/bin"
STATE="$LAB_ROOT/.lab"
REPORT="$BIN/report.sh"
GOLDEN="$STATE/golden.sha256"
MARKER="$STATE/lab.marker"

EX_TITLE_1="Top 5 client IPs               (cut / sort / uniq / head)"
EX_TITLE_2="Slowest latency budgets        (tail / cut / sort / sed / tr)"
EX_TITLE_3="Archived 5xx responses         (zcat / cut / sed / wc)"
EX_TITLE_4="Primary on-call rotation       (tail / cut / tr / nl)"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

require_tools() {
    local missing=() t
    for t in cut sort uniq head tail tr sed nl od wc paste split cat gzip zcat sha256sum md5sum; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]} (install coreutils and gzip)"
}

confirm_disposable() {
    [ "${LAB_ASSUME_YES:-0}" = "1" ] && return 0
    rule
    info "This lab writes ONLY inside: $LAB_ROOT"
    info "It does not modify /etc, services, packages, or any file outside that tree."
    info "Even so: run it on a throwaway lab VM, never on a workstation you care about."
    rule
    [ -t 0 ] || die "non-interactive shell: re-run with LAB_ASSUME_YES=1 to accept"
    local answer
    read -r -p "Type 'break' to build and break the lab: " answer
    [ "$answer" = "break" ] || die "aborted by user"
}

#------------------------------------------------------------------------------
# Data set (pristine)
#------------------------------------------------------------------------------
build_data() {
    mkdir -p "$DATA" "$BIN" "$STATE"

    # --- today's access log: space separated, 10 fields ------------------------
    # $1 client IP   $3 user   $9 HTTP status   $10 bytes
    cat > "$DATA/access.log" <<'ACCESS_EOF'
10.20.0.11 - alice [12/Aug/2026:09:15:02 +0000] "GET /api/v1/orders HTTP/1.1" 200 1240
10.20.0.11 - alice [12/Aug/2026:09:15:07 +0000] "GET /api/v1/orders/88 HTTP/1.1" 200 980
10.20.0.35 - bob [12/Aug/2026:09:16:11 +0000] "POST /api/v1/orders HTTP/1.1" 201 310
10.20.0.77 - carol [12/Aug/2026:09:17:44 +0000] "GET /api/v1/cart HTTP/1.1" 500 217
10.20.0.11 - alice [12/Aug/2026:09:18:03 +0000] "GET /api/v1/orders HTTP/1.1" 200 1240
10.20.0.35 - bob [12/Aug/2026:09:18:52 +0000] "GET /healthz HTTP/1.1" 200 12
10.20.0.98 - dave [12/Aug/2026:09:19:30 +0000] "GET /api/v1/search HTTP/1.1" 404 88
10.20.0.11 - alice [12/Aug/2026:09:20:15 +0000] "GET /api/v1/cart HTTP/1.1" 500 217
10.20.0.35 - bob [12/Aug/2026:09:21:02 +0000] "GET /api/v1/cart HTTP/1.1" 200 640
10.20.0.77 - carol [12/Aug/2026:09:22:19 +0000] "GET /media/logo.png HTTP/1.1" 200 3312
10.20.0.11 - alice [12/Aug/2026:09:23:41 +0000] "GET /api/v1/orders HTTP/1.1" 200 1240
10.20.0.12 - erin [12/Aug/2026:09:24:05 +0000] "GET /healthz HTTP/1.1" 200 12
10.20.0.35 - bob [12/Aug/2026:09:25:33 +0000] "POST /api/v1/orders HTTP/1.1" 503 91
10.20.0.11 - alice [12/Aug/2026:09:26:12 +0000] "GET /api/v1/orders HTTP/1.1" 200 1240
10.20.0.98 - dave [12/Aug/2026:09:27:49 +0000] "GET /api/v1/search HTTP/1.1" 200 4321
10.20.0.77 - carol [12/Aug/2026:09:28:30 +0000] "GET /api/v1/cart HTTP/1.1" 500 217
10.20.0.11 - alice [12/Aug/2026:09:29:11 +0000] "GET /api/v1/orders HTTP/1.1" 200 1240
10.20.0.35 - bob [12/Aug/2026:09:30:44 +0000] "GET /api/v1/cart HTTP/1.1" 200 640
10.20.0.12 - erin [12/Aug/2026:09:31:27 +0000] "GET /api/v1/report HTTP/1.1" 401 73
10.20.0.11 - alice [12/Aug/2026:09:32:58 +0000] "GET /api/v1/orders HTTP/1.1" 200 1240
10.20.0.77 - carol [12/Aug/2026:09:33:36 +0000] "GET /media/logo.png HTTP/1.1" 200 3312
10.20.0.35 - bob [12/Aug/2026:09:34:19 +0000] "GET /healthz HTTP/1.1" 200 12
10.20.0.11 - alice [12/Aug/2026:09:35:02 +0000] "GET /api/v1/orders HTTP/1.1" 200 1240
10.20.0.98 - dave [12/Aug/2026:09:36:41 +0000] "GET /healthz HTTP/1.1" 200 12
ACCESS_EOF

    # --- service catalogue: CSV with a header row ------------------------------
    cat > "$DATA/services.csv" <<'CSV_EOF'
service,owner,budget_ms
orders-api,payments,250
cart-api,checkout,180
auth-api,identity,90
search-api,discovery,400
media-api,content,600
billing-api,payments,320
notify-api,comms,150
report-api,analytics,900
CSV_EOF

    # --- yesterday's rotated log, compressed -----------------------------------
    cat > "$DATA/access-archive.log" <<'ARCHIVE_EOF'
10.20.0.11 - alice [11/Aug/2026:22:01:03 +0000] "GET /api/v1/orders HTTP/1.1" 200 1100
10.20.0.35 - bob [11/Aug/2026:22:04:12 +0000] "GET /api/v1/cart HTTP/1.1" 503 88
10.20.0.77 - carol [11/Aug/2026:22:07:31 +0000] "POST /api/v1/orders HTTP/1.1" 500 212
10.20.0.12 - erin [11/Aug/2026:22:09:55 +0000] "GET /healthz HTTP/1.1" 200 12
10.20.0.98 - dave [11/Aug/2026:22:11:02 +0000] "GET /api/v1/search HTTP/1.1" 200 4321
10.20.0.11 - alice [11/Aug/2026:22:15:44 +0000] "GET /api/v1/orders HTTP/1.1" 502 91
10.20.0.35 - bob [11/Aug/2026:22:18:20 +0000] "GET /api/v1/cart HTTP/1.1" 200 640
10.20.0.77 - carol [11/Aug/2026:22:21:09 +0000] "GET /media/logo.png HTTP/1.1" 304 0
10.20.0.12 - erin [11/Aug/2026:22:25:41 +0000] "GET /api/v1/report HTTP/1.1" 500 205
10.20.0.98 - dave [11/Aug/2026:22:29:17 +0000] "GET /healthz HTTP/1.1" 200 12
10.20.0.11 - alice [11/Aug/2026:22:31:58 +0000] "POST /api/v1/orders HTTP/1.1" 201 318
10.20.0.35 - bob [11/Aug/2026:22:36:02 +0000] "GET /api/v1/cart HTTP/1.1" 200 655
ARCHIVE_EOF
    rm -f "$DATA/access-archive.log.gz"
    gzip -n "$DATA/access-archive.log"

    # --- on-call roster: real TAB separated values -----------------------------
    printf '%s\t%s\t%s\t%s\n' \
        week     primary secondary escalation \
        2026-W33 alice   bob       carol      \
        2026-W34 bob     carol     dave       \
        2026-W35 carol   dave      erin       \
        2026-W36 dave    erin      alice      > "$DATA/oncall.tsv"

    : > "$MARKER"
}

#------------------------------------------------------------------------------
# The tool under repair — written CORRECT first, so the expected output can be
# fingerprinted before anything is broken.
#------------------------------------------------------------------------------
write_report_tool() {
    cat > "$REPORT" <<'REPORT_EOF'
#!/usr/bin/env bash
#
# report.sh — daily text-stream report for the platform team.
# Everything here is done with stream filters: no awk, no perl, no python.
#
# usage: report.sh [1|2|3|4|all]
#
set -u
export LC_ALL=C          # deterministic byte-order collation for sort/uniq

DATA="$(cd "$(dirname "$0")/../data" && pwd)"
LOG="$DATA/access.log"
CSV="$DATA/services.csv"
ARCHIVE="$DATA/access-archive.log.gz"
TSV="$DATA/oncall.tsv"

section_1() {
    echo "== Top 5 client IPs (today) =="
    cut -d' ' -f1 "$LOG" | sort | uniq -c | sort -rn | head -n 5 | sed 's/^ *//'
}

section_2() {
    echo "== Slowest latency budgets =="
    tail -n +2 "$CSV" | cut -d, -f1,3 | sort -t, -k2,2nr | head -n 3 \
        | sed 's/^\(.*\),\(.*\)$/\2 ms  \1/'
}

section_3() {
    echo "== Archived 5xx responses (yesterday) =="
    zcat "$ARCHIVE" | cut -d' ' -f9 | sed -n '/^5/p' | wc -l
}

section_4() {
    echo "== Primary on-call rotation =="
    tail -n +2 "$TSV" | cut -f1,2 | tr '\t' ' ' | nl -w1 -s'. '
}

case "${1:-all}" in
    1)   section_1 ;;
    2)   section_2 ;;
    3)   section_3 ;;
    4)   section_4 ;;
    all) section_1; echo; section_2; echo; section_3; echo; section_4 ;;
    *)   echo "usage: $0 [1|2|3|4|all]" >&2; exit 2 ;;
esac
REPORT_EOF
    chmod 0755 "$REPORT"
}

section_hash() {
    local n="$1" out
    out="$(bash "$REPORT" "$n" 2>/dev/null || true)"
    printf '%s' "$out" | sha256sum | cut -d' ' -f1
}

record_golden() {
    local n
    : > "$GOLDEN"
    for n in 1 2 3 4; do
        printf '%s %s\n' "$n" "$(section_hash "$n")" >> "$GOLDEN"
    done
    chmod 0444 "$GOLDEN"
}

#------------------------------------------------------------------------------
# The controlled breakage
#------------------------------------------------------------------------------
apply_breaks() {
    # BREAK 1 — drop the sort that feeds uniq.  uniq only collapses ADJACENT
    #           equal lines, so an unsorted stream yields nonsense counts.
    sed -i 's/| sort | uniq -c |/| uniq -c |/' "$REPORT"

    # BREAK 2 — DATA break: rewrite the CSV with DOS (CRLF) line endings, the way
    #           a file exported from a spreadsheet or fetched over Windows SMB
    #           arrives.  The trailing CR becomes part of the last field.
    local cr
    cr="$(printf '\r')"
    sed "s/\$/${cr}/" "$DATA/services.csv" > "$DATA/services.csv.tmp"
    mv -f "$DATA/services.csv.tmp" "$DATA/services.csv"

    # BREAK 3 — read a gzip stream with cat instead of the z-variant.
    sed -i 's/zcat /cat /' "$REPORT"

    # BREAK 4 — cut with an explicit space delimiter over a TAB separated file.
    sed -i "s/cut -f1,2/cut -d' ' -f1,2/" "$REPORT"

    chmod 0755 "$REPORT"
}

#------------------------------------------------------------------------------
# Student-facing briefing
#------------------------------------------------------------------------------
brief() {
    rule
    cat <<BRIEF_EOF
LPIC-1 103.2 — Process text streams using filters — BREAK & FIX

Lab tree : $LAB_ROOT
Tool     : bin/report.sh   (run it: cd "$LAB_ROOT" && ./bin/report.sh all)
Data     : data/access.log  data/services.csv  data/access-archive.log.gz
           data/oncall.tsv
Check    : $0 check         Hints: $0 hint 1|2|3|4
Re-break : $0 reset         Delete lab: $0 clean

Four things are broken. Three live in the pipelines inside bin/report.sh, one
lives in the data. You may fix EITHER the pipeline OR the data — the check only
compares the produced output against the fingerprint of the correct output.
You must not disable a section, hardcode its output, or bypass the filters.

--- EXERCISE 1 : $EX_TITLE_1
SYMPTOM  ./bin/report.sh 1 prints five lines whose counts are all 1 (or nearly
         all 1) and the same IP address shows up more than once in the "top 5".
GOAL     Produce a genuine frequency ranking: each client IP exactly once, its
         real request count, highest first, five lines.
         Sanity anchor: 'wc -l data/access.log' says 24 requests total, so the
         five counts must add up to 24.

--- EXERCISE 2 : $EX_TITLE_2
SYMPTOM  ./bin/report.sh 2 prints three lines that begin with " ms" — the
         millisecond number itself has disappeared from the screen, even though
         'cut -d, -f3 data/services.csv' clearly shows the numbers are there.
         Piping the section through 'cat -A' or 'od -c' shows what the terminal
         is hiding from you.
GOAL     Make each of the three lines read  "<number> ms  <service-name>",
         highest budget first, with no stray control characters in the stream.

--- EXERCISE 3 : $EX_TITLE_3
SYMPTOM  ./bin/report.sh 3 reports an obviously wrong count (typically 0) and
         may spray binary noise on your terminal. If the terminal ends up
         garbled, run 'reset' or 'tput sgr0' to recover it.
GOAL     Report the true number of 5xx responses in the rotated, compressed
         archive, without ever writing a decompressed copy of it to disk.

--- EXERCISE 4 : $EX_TITLE_4
SYMPTOM  ./bin/report.sh 4 numbers the rows correctly but every row still shows
         all four columns (week, primary, secondary, escalation) instead of the
         first two.
GOAL     Print exactly "<n>. <week> <primary>" for the four rotation weeks —
         the header row must not appear and no other columns may leak through.
BRIEF_EOF
    rule
}

hint() {
    case "${1:-}" in
        1) cat <<'H1'
Hint 1: uniq is a streaming filter with a one-line memory. It compares each line
        only with the line immediately before it (see 'man 1 uniq': "filter
        adjacent matching lines"). Ask yourself what has to be true about the
        stream before uniq -c can count anything globally.
        Useful probe: cut -d' ' -f1 data/access.log | uniq -c | head
H1
        ;;
        2) cat <<'H2'
Hint 2: The bytes on disk are not what the terminal draws. Compare:
            head -n 2 data/services.csv
            head -n 2 data/services.csv | cat -A
            head -n 2 data/services.csv | od -c
        A carriage return (\r, 0x0D, shown as ^M) moves the cursor to column 0
        without advancing a line, so anything printed after it overwrites what
        came before. Two filters in the 103.2 list can remove it: one deletes a
        character class from the whole stream, the other edits the end of line.
H2
        ;;
        3) cat <<'H3'
Hint 3: Identify the file before you read it:
            file data/access-archive.log.gz
            od -An -tx1 -N2 data/access-archive.log.gz     # 1f 8b = gzip magic
        Coreutils/gzip ship stream-decompressing readers, one per format:
        zcat (gzip), bzcat (bzip2), xzcat (xz). They write plain text to stdout
        and never create a file on disk.
H3
        ;;
        4) cat <<'H4'
Hint 4: Look at the actual separator:
            head -n 2 data/oncall.tsv | cat -A          # ^I is a TAB
        Then read 'man 1 cut' on two points: what the DEFAULT delimiter is, and
        what cut does with a line that does not contain the delimiter at all
        (that behaviour is why you see whole lines). The -s option is the other
        half of that story.
H4
        ;;
        *) die "usage: $0 hint 1|2|3|4" ;;
    esac
}

#------------------------------------------------------------------------------
# Verification
#------------------------------------------------------------------------------
check() {
    [ -f "$GOLDEN" ] || die "no lab installed — run: $0 setup"
    local n expected actual failed=0 title
    rule
    printf '%-6s %-46s %s\n' "EX" "SECTION" "RESULT"
    rule
    for n in 1 2 3 4; do
        expected="$(sed -n "s/^$n //p" "$GOLDEN")"
        actual="$(section_hash "$n")"
        eval "title=\$EX_TITLE_$n"
        if [ "$expected" = "$actual" ]; then
            printf '%-6s %-46s %s\n' "$n" "$title" "[ OK ]"
        else
            printf '%-6s %-46s %s\n' "$n" "$title" "[FAIL]"
            failed=$((failed + 1))
        fi
    done
    rule
    if [ "$failed" -eq 0 ]; then
        info "All four sections match the expected output. Lab complete."
        info "Read the commented solution at the bottom of this script to compare"
        info "your fixes with the reference ones."
        return 0
    fi
    info "$failed section(s) still broken. Inspect with: ./bin/report.sh <n>"
    info "Need a nudge?  $0 hint <n>"
    return 1
}

#------------------------------------------------------------------------------
# Lifecycle
#------------------------------------------------------------------------------
setup() {
    require_tools
    [ -e "$LAB_ROOT" ] && die "$LAB_ROOT already exists — use '$0 reset' or '$0 clean'"
    confirm_disposable
    mkdir -p "$DATA" "$BIN" "$STATE"
    build_data
    write_report_tool
    record_golden          # fingerprint the CORRECT behaviour...
    apply_breaks           # ...then break it
    info "Lab installed at $LAB_ROOT"
    brief
}

reset_lab() {
    require_tools
    [ -f "$MARKER" ] || die "$LAB_ROOT is not a lab tree built by this script"
    rm -f "$GOLDEN"
    build_data
    write_report_tool
    record_golden
    apply_breaks
    info "Lab reset: data restored and all four breaks re-applied."
    brief
}

clean_lab() {
    [ -f "$MARKER" ] || die "refusing to delete $LAB_ROOT: no lab marker found"
    case "$LAB_ROOT" in
        ""|"/"|"$HOME") die "refusing to delete $LAB_ROOT" ;;
    esac
    rm -rf -- "$LAB_ROOT"
    info "Removed $LAB_ROOT"
}

usage() {
    cat <<USAGE
usage: $0 {setup|check|hint N|brief|reset|clean}

  setup    build the lab tree and apply the four breaks (default)
  check    verify each section against the fingerprint of the correct output
  hint N   diagnostic nudge for exercise N (1-4), not the answer
  brief    reprint symptoms and objectives
  reset    restore pristine data and re-apply the breaks
  clean    delete the whole lab tree

  LAB_ROOT=<dir>       install somewhere other than ~/lpic1-103.2-lab
  LAB_ASSUME_YES=1     skip the interactive confirmation (for automation)
USAGE
}

case "${1:-setup}" in
    setup)  setup ;;
    check)  check ;;
    hint)   hint "${2:-}" ;;
    brief)  brief ;;
    reset)  reset_lab ;;
    clean)  clean_lab ;;
    -h|--help|help) usage ;;
    *)      usage; exit 2 ;;
esac

#===============================================================================
#
#   S O L U T I O N   —   step by step
#   (stop reading here if you have not finished the lab)
#
#===============================================================================
#
# Work from the lab root:
#     cd ~/lpic1-103.2-lab
#
#-------------------------------------------------------------------------------
# EXERCISE 1 — uniq counts only ADJACENT duplicates
#-------------------------------------------------------------------------------
# Diagnosis:
#     ./bin/report.sh 1
#     grep -n 'uniq -c' bin/report.sh
#
# The broken pipeline is:
#     cut -d' ' -f1 "$LOG" | uniq -c | sort -rn | head -n 5 | sed 's/^ *//'
#
# uniq is a *streaming* filter: it holds exactly one line of state and compares
# each input line with its immediate predecessor. On an unsorted stream every
# alternation restarts the run, so 10.20.0.11 is reported many times with count
# 1 instead of once with count 9. This is the single most frequent real-world
# misuse of uniq, and a guaranteed exam question.
#
# Fix (restore the sort that groups equal keys together):
#     sed -i 's/| uniq -c |/| sort | uniq -c |/' bin/report.sh
#
# Corrected pipeline and its meaning, stage by stage:
#     cut -d' ' -f1 access.log   # field 1 of a space-delimited record: the IP
#       | sort                   # bring equal keys adjacent (LC_ALL=C: byte order)
#       | uniq -c                # collapse runs, prefix each with its count
#       | sort -rn               # numeric (-n), descending (-r) on the count
#       | head -n 5              # first five records of the ranked stream
#       | sed 's/^ *//'          # strip the padding uniq -c adds on the left
#
# Expected output:
#     == Top 5 client IPs (today) ==
#     9 10.20.0.11
#     6 10.20.0.35
#     4 10.20.0.77
#     3 10.20.0.98
#     2 10.20.0.12
#     (9+6+4+3+2 = 24 = wc -l data/access.log — always cross-check the total)
#
# Production notes:
#   * 'sort -u' removes duplicates but cannot count them; 'sort | uniq -c' is the
#     canonical frequency counter. 'uniq -d' shows only duplicated keys, 'uniq -u'
#     only unique ones, 'uniq -c -f N' skips N leading fields before comparing.
#   * 'sort -rn' vs 'sort -r': the second is lexicographic, so 9 sorts above 1240.
#     On counters this bites the moment any value reaches three digits.
#   * LC_ALL=C is set at the top of report.sh on purpose: locale collation changes
#     sort order (and therefore uniq grouping) between machines. Pinning it is
#     what makes the report reproducible in CI.
#
#-------------------------------------------------------------------------------
# EXERCISE 2 — CRLF line endings poison the last field
#-------------------------------------------------------------------------------
# Diagnosis (the terminal lies; look at the bytes):
#     head -n 3 data/services.csv | cat -A
#         service,owner,budget_ms^M$
#         orders-api,payments,250^M$
#     head -n 3 data/services.csv | od -c | head
#         ...  2 5 0  \r  \n ...
#     file data/services.csv
#         ASCII text, with CRLF line terminators
#
# Why the number "disappeared": the last field is "900\r". The final sed swaps
# the two capture groups, so the emitted line is "900\r ms  report-api" — the
# terminal prints 900, the CR returns the cursor to column 0, and " ms  report-api"
# overwrites it. The data was never lost, only redrawn. Anything comparing that
# field as a string ("900" != "900\r") or feeding it to a numeric test would fail
# just as silently.
#
# Fix A — clean the data once (idempotent, safe to re-run):
#     sed -i 's/\r$//' data/services.csv
#   or, without -i:
#     tr -d '\r' < data/services.csv > /tmp/services.csv && mv /tmp/services.csv data/services.csv
#
# Fix B — harden the pipeline instead, which is what you want when the file is
# re-delivered by a third party every night:
#     tail -n +2 "$CSV" | tr -d '\r' | cut -d, -f1,3 | sort -t, -k2,2nr | head -n 3 \
#         | sed 's/^\(.*\),\(.*\)$/\2 ms  \1/'
#
# Expected output:
#     == Slowest latency budgets ==
#     900 ms  report-api
#     600 ms  media-api
#     400 ms  search-api
#
# Production notes:
#   * 'tr -d "\r"' deletes EVERY carriage return in the stream; 'sed "s/\r$//"'
#     removes only the one at end of line. Prefer sed when the payload may
#     legitimately contain CR bytes.
#   * 'sort -t, -k2,2nr' — -t sets the field separator, -k2,2 restricts the key to
#     exactly field 2 (writing -k2 alone means "from field 2 to end of line", a
#     classic source of surprise ties).
#   * 'tail -n +2' prints from line 2 onward: the idiomatic header stripper.
#     Do not confuse it with 'tail -n 2' (last two lines).
#   * dos2unix does the same job, but it is not in the 103.2 toolset — and on a
#     minimal container it is usually not installed, while tr and sed always are.
#
#-------------------------------------------------------------------------------
# EXERCISE 3 — cat on a compressed stream
#-------------------------------------------------------------------------------
# Diagnosis:
#     file data/access-archive.log.gz
#         gzip compressed data, ...
#     od -An -tx1 -N2 data/access-archive.log.gz
#         1f 8b                      <- gzip magic number
#     grep -n 'cat "\$ARCHIVE"' bin/report.sh
#
# cat copies bytes; it does not decompress. The DEFLATE stream contains almost no
# newlines, so 'wc -l' returns a meaningless number and the binary garbage can
# leave the terminal in a broken state ('reset' or 'tput sgr0' restores it).
#
# Fix:
#     sed -i 's/cat "\$ARCHIVE"/zcat "\$ARCHIVE"/' bin/report.sh
#
# Corrected pipeline:
#     zcat "$ARCHIVE"          # decompress to stdout, nothing written to disk
#       | cut -d' ' -f9        # field 9 of the combined log format: HTTP status
#       | sed -n '/^5/p'       # -n suppresses default output, p prints matches
#       | wc -l                # count the surviving lines
#
# Expected output:
#     == Archived 5xx responses (yesterday) ==
#     4
#
# Production notes:
#   * One reader per format: zcat/gunzip -c (gzip), bzcat (bzip2), xzcat (xz),
#     zstdcat (zstd). 'zcat -f' passes uncompressed input through unchanged, which
#     is exactly what you want when a directory holds access.log alongside
#     access.log.1.gz: 'zcat -f access.log*' reads the whole retention window as
#     one stream.
#   * Never 'gunzip' a rotated log in place on a production host: you change the
#     file the log rotation state expects and you may fill the filesystem.
#   * The whole family (md5sum, sha256sum, sha512sum) belongs to this objective
#     too. Verifying an archive before parsing it:
#         sha256sum data/access-archive.log.gz > /tmp/archive.sha256
#         sha256sum -c /tmp/archive.sha256
#
#-------------------------------------------------------------------------------
# EXERCISE 4 — cut, the wrong delimiter, and the whole-line fallback
#-------------------------------------------------------------------------------
# Diagnosis:
#     head -n 2 data/oncall.tsv | cat -A
#         week^Iprimary^Isecondary^Iescalation$      <- ^I is TAB
#     grep -n "cut -d' '" bin/report.sh
#
# POSIX says that if a line contains no delimiter, cut without -s prints the line
# unchanged. The file has no spaces at all, so 'cut -d" " -f1,2' matches nothing
# and passes every record through in full — a silent no-op that looks like the
# filter "did not run".
#
# Fix (TAB is cut's default delimiter, so the option simply goes away):
#     sed -i "s/cut -d' ' -f1,2/cut -f1,2/" bin/report.sh
#
# Equivalent explicit forms, useful when the delimiter is not the default:
#     cut -d"$(printf '\t')" -f1,2 data/oncall.tsv
#     cut -d$'\t' -f1,2 data/oncall.tsv          # bash ANSI-C quoting
#
# Corrected pipeline:
#     tail -n +2 "$TSV"     # drop the header row
#       | cut -f1,2         # columns 1 and 2, TAB delimited (cut's default)
#       | tr '\t' ' '       # squash the TAB into a plain space for display
#       | nl -w1 -s'. '     # number the lines: width 1, separator ". "
#
# Expected output:
#     == Primary on-call rotation ==
#     1. 2026-W33 alice
#     2. 2026-W34 bob
#     3. 2026-W35 carol
#     4. 2026-W36 dave
#
# Production notes:
#   * Add -s ('--only-delimited') whenever a missing delimiter should mean "drop
#     this line" rather than "emit it whole". On malformed input that difference
#     is the difference between a truncated report and a corrupted one.
#   * cut always emits fields in FILE order: 'cut -f2,1' and 'cut -f1,2' produce
#     identical output. Reordering columns is a job for paste or sed, not cut.
#   * 'cut -c' slices by character position, 'cut -b' by byte. On UTF-8 data they
#     diverge, and -b can split a multibyte character in half.
#   * nl only numbers non-empty lines by default ('-b t'); use '-b a' to number
#     every line, and '-v N' to start from something other than 1.
#
#-------------------------------------------------------------------------------
# FINAL VERIFICATION
#-------------------------------------------------------------------------------
#     ./bin/report.sh all
#     ./lab.sh check          # expected: [ OK ] on all four sections
#
#-------------------------------------------------------------------------------
# EXTRA DRILLS on the same data (no breakage involved, pure 103.2 practice)
#-------------------------------------------------------------------------------
#   Bytes served today, without awk (paste builds the expression, bc evaluates):
#       cut -d' ' -f10 data/access.log | paste -sd+ - | bc
#
#   Status-code distribution:
#       cut -d' ' -f9 data/access.log | sort | uniq -c | sort -rn
#
#   Two columns side by side, one stream each:
#       cut -d' ' -f1 data/access.log | sort -u > /tmp/ips
#       cut -d' ' -f3 data/access.log | sort -u > /tmp/users
#       paste /tmp/ips /tmp/users
#
#   Split a log for parallel processing, then prove the reassembly is byte-exact:
#       cd /tmp && split -l 10 -d --additional-suffix=.part \
#            ~/lpic1-103.2-lab/data/access.log chunk_
#       sha256sum ~/lpic1-103.2-lab/data/access.log
#       cat chunk_*.part | sha256sum        # must print the same digest
#       (the shell expands chunk_* in collation order — that ordering is the
#        entire correctness argument for reassembling with cat)
#
#   Inspect invisible characters and encodings:
#       od -c data/oncall.tsv | head
#       od -An -tx1 -N16 data/access-archive.log.gz
#       wc -l -w -c -m data/access.log      # lines, words, bytes, characters
#
#   Windows into a stream:
#       head -n 5 data/access.log           # first five records
#       tail -n 5 data/access.log           # last five records
#       tail -n +10 data/access.log | head -n 3   # records 10, 11, 12
#       head -c 64 data/access.log          # first 64 BYTES, not lines
#
#-------------------------------------------------------------------------------
# REFERENCES
#   LPI 101-500 objectives:
#       https://www.lpi.org/our-certifications/exam-101-objectives/
#   GNU coreutils manual (cut, sort, uniq, head, tail, tr, nl, od, wc, paste,
#   split, cat, md5sum, sha256sum, sha512sum):
#       https://www.gnu.org/software/coreutils/manual/coreutils.html
#   GNU sed manual:
#       https://www.gnu.org/software/sed/manual/sed.html
#   gzip manual (zcat and friends):
#       https://www.gnu.org/software/gzip/manual/gzip.html
#===============================================================================