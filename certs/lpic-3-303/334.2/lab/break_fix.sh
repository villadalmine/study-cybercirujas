#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-3 303 (Security) -- Exam 303-300, version 3.0.0
#  Topic 334.2: Network Intrusion Detection   (exam weight: 6.67)
#
#  BREAK & FIX LAB -- Snort 2.9 NIDS: it loads, it captures, it stays silent.
#
#  What this lab teaches (all of it is exam surface):
#    * The Snort configuration pipeline: variables -> preprocessors ->
#      output plugins -> rule includes, and the order in which snort
#      evaluates them at start-up.
#    * ipvar HOME_NET / EXTERNAL_NET semantics -- the single most common
#      cause of a "working" IDS that has never generated a single alert.
#    * Rule anatomy: header (action proto src sport dir dst dport) plus body
#      options, and the non-negotiable ones (msg, sid, rev).
#    * config logdir: vs. the -l command-line override, and why snort
#      refuses to start when it cannot write there.
#    * Output plugins: alert_fast (text) vs. unified2 (binary, consumed by
#      barnyard2 / u2spewfoo). An empty /var/log/snort/alert does NOT mean
#      "no detections".
#    * Event suppression (threshold.conf / suppress) -- a loaded, correct,
#      matching rule that still produces nothing.
#    * Reading the Action Stats block that snort prints on SIGTERM: it is
#      the ground truth that separates "no packets" from "no matches" from
#      "no output".
#
#  Official references:
#    * LPI exam 303-300 objectives:
#        https://www.lpi.org/our-certifications/exam-303-objectives/
#    * Snort Users Manual 2.9 (configuration, preprocessors, output plugins,
#      writing rules, event filtering and suppression):
#        https://www.snort.org/documents
#    * Snort downloads / release notes:
#        https://www.snort.org/downloads
#    * Snort 3 documentation set (for the snort.lua successor to snort.conf):
#        https://docs.snort.org/
#
# -----------------------------------------------------------------------------
#  !! READ BEFORE RUNNING !!
#
#  This script REWRITES /etc/snort/*, disables the packaged snort service and
#  deliberately introduces five faults. Run it ONLY on a disposable lab VM or
#  container that you can throw away. It refuses to start without an explicit
#  acknowledgement flag, and refuses on bare metal unless FORCE=1.
#
#  It touches nothing outside: /etc/snort, /var/log/snort, /var/lib/lab-*,
#  and the snort system user. It performs no network activity beyond the
#  loopback interface (127.0.0.1) and, if snort is not installed, your
#  distribution's package manager.
#
#  Target platform: Debian 12 / Ubuntu 22.04+ with the packaged Snort 2.9.x
#  (the objective lists /etc/snort/* explicitly). Snort 3 uses snort.lua and
#  is detected and rejected with a message.
#
#  Usage:
#    ./334.2-break-and-fix.sh setup  --i-am-in-a-disposable-lab-vm
#    ./334.2-break-and-fix.sh break  --i-am-in-a-disposable-lab-vm
#    ./334.2-break-and-fix.sh check          # grade yourself, repeatable
#    ./334.2-break-and-fix.sh traffic        # replay the test traffic only
#    ./334.2-break-and-fix.sh hint 1..5      # progressive hints
#    ./334.2-break-and-fix.sh reset          # give up: restore the good lab
#    ./334.2-break-and-fix.sh purge          # remove the lab entirely
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until you have spent real time with snort -T, the
#  Action Stats block and /var/log/snort/.
# =============================================================================

set -euo pipefail

readonly LAB_ID="lpic3-303-334.2"
readonly STATE_DIR="/var/lib/lab-${LAB_ID}"
readonly BACKUP_DIR="${STATE_DIR}/backup"
readonly STATE_FILE="${STATE_DIR}/state"
readonly RUN_LOG="${STATE_DIR}/snort-run.log"
readonly TEST_LOG="${STATE_DIR}/snort-test.log"
readonly STUB_PY="${STATE_DIR}/http_stub.py"

readonly SNORT_ETC="/etc/snort"
readonly SNORT_CONF="${SNORT_ETC}/snort.conf"
readonly RULE_DIR="${SNORT_ETC}/rules"
readonly LOCAL_RULES="${RULE_DIR}/local.rules"
readonly CLASS_CONF="${SNORT_ETC}/lab-classification.config"
readonly THRESHOLD_CONF="${SNORT_ETC}/threshold.conf"
readonly DEFAULT_LOGDIR="/var/log/snort"
readonly BROKEN_LOGDIR="/var/log/snort-ids"

readonly IFACE="lo"
readonly SNORT_USER="snort"
readonly SNORT_GROUP="snort"

readonly SID_ICMP="1000001"
readonly SID_HTTP="1000002"
readonly SID_UDP="1000003"

LAB_ACK="no"
CMD=""
HINT_N=""

# ---------------------------------------------------------------- ui helpers

if [[ -t 1 ]]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail() { printf '%s[-]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()  { fail "$*"; exit 1; }
rule() { printf '%s%s%s\n' "$C_DIM" "-------------------------------------------------------------------------------" "$C_OFF"; }

usage() {
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------- guards

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "this lab must run as root (snort binds a capture handle and edits /etc/snort)"
}

require_lab_ack() {
    [[ "$LAB_ACK" == "yes" ]] || die "refusing to modify this host: pass --i-am-in-a-disposable-lab-vm"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if ! systemd-detect-virt --quiet; then
            warn "systemd-detect-virt reports no virtualisation: this looks like bare metal."
            [[ "${FORCE:-0}" == "1" ]] || die "set FORCE=1 to override, or move to a throwaway VM"
        fi
    fi
}

# --------------------------------------------------------- install & fixtures

detect_snort() {
    command -v snort >/dev/null 2>&1 || return 1
    local v
    v="$(snort -V 2>&1 | awk '/Version/ {print $3; exit}')"
    case "$v" in
        2.9*|2.*) return 0 ;;
        3.*) die "Snort ${v} detected. This lab targets Snort 2.9.x (/etc/snort/snort.conf), which is what objective 334.2 lists. Snort 3 replaces snort.conf with snort.lua; install the 2.9 package or use a Debian 12 / Ubuntu 22.04 lab VM." ;;
        *)   warn "could not parse snort version ('${v}'), continuing"; return 0 ;;
    esac
}

install_snort() {
    if detect_snort; then
        ok "snort present: $(snort -V 2>&1 | awk '/Version/{print $3,$4,$5}')"
        return 0
    fi
    info "snort not found, installing from the distribution repositories"
    if command -v apt-get >/dev/null 2>&1; then
        # Preseed the two debconf questions so the install stays non-interactive.
        if command -v debconf-set-selections >/dev/null 2>&1; then
            printf 'snort snort/address_range string 127.0.0.0/8\n' | debconf-set-selections
            printf 'snort snort/interface string lo\n'              | debconf-set-selections
            printf 'snort snort/start_mode select boot\n'           | debconf-set-selections
        fi
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed, trying the install anyway"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq snort iputils-ping python3 \
            || die "snort installation failed -- install it manually and re-run setup"
    else
        die "no apt-get on this host. Install Snort 2.9 manually (package 'snort' on Debian/Ubuntu; Snort 2.9 is not in RHEL/Fedora repositories and must be built from https://www.snort.org/downloads) and re-run setup."
    fi
    detect_snort || die "snort still not usable after installation"
    ok "snort installed"
}

check_deps() {
    command -v ping    >/dev/null 2>&1 || die "ping is required for the ICMP test traffic (install iputils-ping)"
    command -v python3 >/dev/null 2>&1 || die "python3 is required for the throwaway HTTP listener on 127.0.0.1:80"
    command -v pkill   >/dev/null 2>&1 || die "pkill is required (install procps)"
}

ensure_snort_user() {
    if ! id -u "$SNORT_USER" >/dev/null 2>&1; then
        info "creating the unprivileged '${SNORT_USER}' account snort drops to (-u/-g)"
        groupadd -r "$SNORT_GROUP" 2>/dev/null || true
        useradd -r -g "$SNORT_GROUP" -M -d /nonexistent -s /usr/sbin/nologin "$SNORT_USER" 2>/dev/null || true
    fi
    id -u "$SNORT_USER" >/dev/null 2>&1 || die "could not create the ${SNORT_USER} user"
}

stop_packaged_service() {
    # The Debian package starts snort on a real interface at boot. This lab runs
    # snort by hand in the foreground so the student can read its output.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop    snort.service >/dev/null 2>&1 || true
        systemctl disable snort.service >/dev/null 2>&1 || true
    fi
    pkill -f "snort " >/dev/null 2>&1 || true
    sleep 1
}

backup_once() {
    local src="$1" name="$2"
    [[ -e "$src" ]] || return 0
    [[ -e "${BACKUP_DIR}/${name}" ]] && return 0
    cp -a "$src" "${BACKUP_DIR}/${name}"
}

write_classification() {
    cat > "$CLASS_CONF" <<'EOF'
# LAB 334.2 -- classification map.
# Every classtype referenced by a rule MUST be defined before the rule is
# parsed, or snort aborts with "Unknown ClassType". Format:
#   config classification: <shortname>,<description>,<default priority>
config classification: misc-activity,Misc Activity,3
config classification: web-application-activity,Access to a potentially vulnerable web application,2
config classification: bad-unknown,Potentially Bad Traffic,2
EOF
}

write_good_rules() {
    mkdir -p "$RULE_DIR"
    cat > "$LOCAL_RULES" <<'EOF'
# =============================================================================
# LAB 334.2 -- local ruleset.
#
# Rule header:  action proto src_ip src_port direction dst_ip dst_port
# Rule body:    ( option:value; option:value; ... )
#
# Local rules must use SIDs >= 1,000,000 (100-1,000,000 is reserved for the
# Snort distribution, < 100 for the engine itself). Every rule needs msg, sid
# and rev, or the ruleset will not load at all.
# =============================================================================

alert icmp $EXTERNAL_NET any -> $HOME_NET any (msg:"LAB-334.2 ICMP echo request into HOME_NET"; itype:8; classtype:misc-activity; sid:1000001; rev:1;)

alert tcp $EXTERNAL_NET any -> $HOME_NET 80 (msg:"LAB-334.2 HTTP request for /lab-secret"; flow:to_server,established; content:"GET /lab-secret"; depth:20; nocase; classtype:web-application-activity; sid:1000002; rev:1;)

alert udp $EXTERNAL_NET any -> $HOME_NET 53 (msg:"LAB-334.2 marker payload on UDP/53"; content:"lab334udp"; classtype:bad-unknown; sid:1000003; rev:1;)
EOF
}

write_good_conf() {
    mkdir -p "$SNORT_ETC"
    cat > "$SNORT_CONF" <<'EOF'
# =============================================================================
# LAB 334.2 -- minimal, self-contained Snort 2.9 configuration.
#
# Evaluation order at start-up:
#   1. variables      (ipvar / portvar / var)
#   2. config directives
#   3. preprocessors  (decode -> frag3 -> stream5 -> service preprocs)
#   4. output plugins
#   5. includes (classification map, rules, event filters)
# A rule can only fire if every stage above it did its job.
# =============================================================================

# --- 1. variables ------------------------------------------------------------
# HOME_NET is the network you are DEFENDING. EXTERNAL_NET is everything else.
# This lab generates traffic on loopback, so both endpoints live in 127.0.0.0/8.
ipvar HOME_NET 127.0.0.0/8
ipvar EXTERNAL_NET any
var RULE_PATH /etc/snort/rules

# --- 2. config directives ----------------------------------------------------
# logdir is where every output plugin writes unless -l overrides it on the
# command line. snort refuses to start if it cannot write here.
config logdir: /var/log/snort

# Loopback and offloaded NICs hand snort packets with unfinished checksums.
# Without this, snort silently drops them before detection ever runs.
config checksum_mode: none

config disable_decode_alerts
config pcre_match_limit: 3500
config pcre_match_limit_recursion: 1500

# --- 3. preprocessors --------------------------------------------------------
preprocessor frag3_global: max_frags 65536
preprocessor frag3_engine: policy linux detect_anomalies

# stream5 rebuilds TCP sessions. Without it, flow:established never matches.
preprocessor stream5_global: track_tcp yes, track_udp yes, track_icmp no
preprocessor stream5_tcp: policy linux
preprocessor stream5_udp: timeout 30

# --- 4. output plugins -------------------------------------------------------
# alert_fast writes one human-readable line per event to <logdir>/alert.
# Production sensors normally use unified2 + barnyard2 instead.
output alert_fast: alert

# --- 5. includes -------------------------------------------------------------
include /etc/snort/lab-classification.config
include $RULE_PATH/local.rules
EOF
}

write_http_stub() {
    cat > "$STUB_PY" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", 80))
except OSError as e:
    print("bind-failed:%s" % e, file=sys.stderr)
    sys.exit(1)
s.listen(4)
s.settimeout(12)
print("ready", flush=True)
try:
    while True:
        c, _ = s.accept()
        c.recv(4096)
        c.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nlab\n")
        c.close()
except Exception:
    pass
finally:
    s.close()
PY
}

# ------------------------------------------------------------ traffic engine

current_logdir() {
    local d
    d="$(awk -F: '/^[[:space:]]*config[[:space:]]+logdir[[:space:]]*:/ {sub(/^[ \t]+/,"",$2); sub(/[ \t]+$/,"",$2); print $2; exit}' "$SNORT_CONF" 2>/dev/null || true)"
    [[ -n "$d" ]] && printf '%s\n' "$d" || printf '%s\n' "$DEFAULT_LOGDIR"
}

generate_traffic() {
    # 1) ICMP echo request  -> sid 1000001
    ping -c 3 -i 0.3 -W 1 127.0.0.1 >/dev/null 2>&1 || true

    # 2) UDP payload to port 53 -> sid 1000003 (no listener needed; the packet
    #    still traverses lo and the decoder sees it)
    (printf 'lab334udp-probe-334-2' > /dev/udp/127.0.0.1/53) 2>/dev/null || true

    # 3) A complete TCP handshake carrying the HTTP request -> sid 1000002.
    #    flow:to_server,established requires a real session, so we need a
    #    listener; a bare SYN answered with RST would never match.
    local stub_pid=""
    if [[ -f "$STUB_PY" ]]; then
        python3 "$STUB_PY" >/dev/null 2>&1 &
        stub_pid=$!
        sleep 1
        if exec 3<>/dev/tcp/127.0.0.1/80 2>/dev/null; then
            printf 'GET /lab-secret HTTP/1.0\r\nHost: 127.0.0.1\r\nUser-Agent: lpic3-334.2-lab\r\n\r\n' >&3
            timeout 3 cat <&3 >/dev/null 2>&1 || true
            exec 3<&- 2>/dev/null || true
            exec 3>&- 2>/dev/null || true
        else
            warn "could not open 127.0.0.1:80 -- the TCP signature will not be exercised"
        fi
        [[ -n "$stub_pid" ]] && { kill "$stub_pid" >/dev/null 2>&1 || true; wait "$stub_pid" 2>/dev/null || true; }
    fi
}

snort_config_test() {
    : > "$TEST_LOG"
    if snort -T -c "$SNORT_CONF" -i "$IFACE" >"$TEST_LOG" 2>&1; then
        return 0
    fi
    return 1
}

# Runs snort in the foreground, replays the test traffic, then SIGTERMs it so
# it flushes its Action Stats block. Returns 0 if snort reached packet
# processing, 1 if it died during start-up.
snort_run_and_capture() {
    local logdir alertfile pid waited=0 marker=0
    logdir="$(current_logdir)"
    alertfile="${logdir}/alert"

    pkill -f "snort -c ${SNORT_CONF}" >/dev/null 2>&1 || true
    sleep 1
    rm -f "$alertfile" 2>/dev/null || true
    : > "$RUN_LOG"

    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL -eL snort -c "$SNORT_CONF" -i "$IFACE" -u "$SNORT_USER" -g "$SNORT_GROUP" >"$RUN_LOG" 2>&1 &
    else
        snort -c "$SNORT_CONF" -i "$IFACE" -u "$SNORT_USER" -g "$SNORT_GROUP" >"$RUN_LOG" 2>&1 &
    fi
    pid=$!

    while [[ $waited -lt 25 ]]; do
        if grep -q "Commencing packet processing" "$RUN_LOG" 2>/dev/null; then
            marker=1; break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            return 1
        fi
        sleep 1; waited=$((waited+1))
    done

    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        return 1
    fi
    # Output may be block-buffered; if the marker never showed, give snort a
    # moment anyway. The verdicts are computed from the flushed log after exit.
    [[ $marker -eq 1 ]] || sleep 3

    generate_traffic
    sleep 2
    generate_traffic          # second pass widens the capture window
    sleep 2

    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 0
}

alerts_counted() {
    local n
    n="$(awk '/^Action Stats:/{f=1;next} f && /Alerts:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$RUN_LOG" 2>/dev/null || true)"
    [[ -n "$n" ]] && printf '%s\n' "$n" || printf '0\n'
}

packets_analyzed() {
    local n
    n="$(awk '/Packet Statistics/{f=1} f && /Analyzed:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$RUN_LOG" 2>/dev/null || true)"
    [[ -n "$n" ]] && printf '%s\n' "$n" || printf '0\n'
}

# ------------------------------------------------------------------- actions

do_setup() {
    need_root; require_lab_ack
    mkdir -p "$STATE_DIR" "$BACKUP_DIR"
    chmod 0700 "$STATE_DIR"

    install_snort
    check_deps
    ensure_snort_user
    stop_packaged_service

    info "backing up any pre-existing configuration to ${BACKUP_DIR}"
    backup_once "$SNORT_CONF"   "snort.conf.prelab"
    backup_once "$LOCAL_RULES"  "local.rules.prelab"
    backup_once "$THRESHOLD_CONF" "threshold.conf.prelab"

    info "installing the known-good lab configuration"
    write_good_conf
    write_good_rules
    write_classification
    write_http_stub
    rm -f "$THRESHOLD_CONF"
    rm -rf "$BROKEN_LOGDIR"

    mkdir -p "$DEFAULT_LOGDIR"
    chown "${SNORT_USER}:${SNORT_GROUP}" "$DEFAULT_LOGDIR"
    chmod 0750 "$DEFAULT_LOGDIR"

    cp -a "$SNORT_CONF"  "${BACKUP_DIR}/snort.conf.good"
    cp -a "$LOCAL_RULES" "${BACKUP_DIR}/local.rules.good"
    printf 'state=good\n' > "$STATE_FILE"

    rule
    info "validating the baseline before breaking anything"
    if ! snort_config_test; then
        tail -n 20 "$TEST_LOG"
        die "the baseline configuration does not even pass snort -T. Fix the environment first; the lab will not break a system that never worked."
    fi
    ok "snort -T passes"

    if ! snort_run_and_capture; then
        tail -n 25 "$RUN_LOG"
        die "snort died during start-up on the baseline configuration"
    fi

    local alertfile; alertfile="$(current_logdir)/alert"
    local missing=0 sid
    for sid in "$SID_ICMP" "$SID_HTTP" "$SID_UDP"; do
        grep -Fq "[1:${sid}:" "$alertfile" 2>/dev/null || { fail "baseline: sid ${sid} did not fire"; missing=1; }
    done
    if [[ $missing -ne 0 ]]; then
        say ""
        say "--- snort run log (tail) ---"; tail -n 30 "$RUN_LOG"
        say "--- alert file ---"; cat "$alertfile" 2>/dev/null || true
        die "baseline detection is incomplete; refusing to hand you a lab whose 'fixed' state does not pass"
    fi
    ok "baseline: all three signatures fire ($(alerts_counted) alerts, $(packets_analyzed) packets analyzed)"
    rule
    ok "lab is armed and healthy. Now run:  $0 break --i-am-in-a-disposable-lab-vm"
}

do_break() {
    need_root; require_lab_ack
    [[ -f "${BACKUP_DIR}/snort.conf.good" ]] || die "run setup first"
    stop_packaged_service

    # ---- FAULT 1: a rule that cannot be parsed ------------------------------
    cat >> "$LOCAL_RULES" <<'EOF'

alert tcp $EXTERNAL_NET any -> $HOME_NET 22 (msg:"LAB-334.2 SSH connection attempt"; flow:to_server; rev:1;)
EOF

    # ---- FAULT 2: logdir points at a directory that does not exist ----------
    sed -i "s#^config logdir:.*#config logdir: ${BROKEN_LOGDIR}#" "$SNORT_CONF"
    rm -rf "$BROKEN_LOGDIR"

    # ---- FAULT 3: the sensor is defending the wrong network -----------------
    sed -i 's#^ipvar HOME_NET .*#ipvar HOME_NET 192.0.2.0/24#'     "$SNORT_CONF"
    sed -i 's#^ipvar EXTERNAL_NET .*#ipvar EXTERNAL_NET !$HOME_NET#' "$SNORT_CONF"

    # ---- FAULT 4: alerts go to a binary plugin, not to the text file --------
    sed -i 's#^output alert_fast: alert#output unified2: filename snort.u2, limit 128#' "$SNORT_CONF"

    # ---- FAULT 5: the ICMP signature is suppressed --------------------------
    cat > "$THRESHOLD_CONF" <<'EOF'
# Event filtering / suppression, loaded after the ruleset.
suppress gen_id 1, sig_id 1000001
EOF
    printf 'include %s\n' "$THRESHOLD_CONF" >> "$SNORT_CONF"

    printf 'state=broken\nfaults=5\n' > "$STATE_FILE"
    rm -f "$(current_logdir)/alert" "${DEFAULT_LOGDIR}/alert" 2>/dev/null || true

    briefing
}

briefing() {
    rule
    say "${C_RED}LAB 334.2 -- NETWORK INTRUSION DETECTION: THE SENSOR IS DOWN${C_OFF}"
    rule
    cat <<EOF

SCENARIO
  You inherit a Snort 2.9 sensor that is supposed to watch the loopback
  segment of this host. Three local signatures were written and verified by
  the previous engineer:

    sid ${SID_ICMP}  ICMP echo request into HOME_NET
    sid ${SID_HTTP}  HTTP request for /lab-secret  (tcp/80)
    sid ${SID_UDP}  marker payload "lab334udp"    (udp/53)

  Since the last change window the sensor has produced nothing. There are
  ${C_YEL}five independent faults${C_OFF} between the configuration on disk and a working
  detection pipeline. They surface one at a time, in this order:

  1. ${C_YEL}It will not even start.${C_OFF}
     \$ snort -T -c ${SNORT_CONF} -i ${IFACE}
     ends in a FATAL ERROR that names a file and a line number in the local
     ruleset. Snort parses the whole ruleset before capturing a single packet:
     one malformed rule takes down the entire sensor.

  2. ${C_YEL}It starts parsing, then aborts on logging.${C_OFF}
     A second FATAL ERROR complains that it cannot get write access to a
     logging directory. Find out which directory it was told to use and why.

  3. ${C_YEL}It runs, it counts packets, it alerts on nothing.${C_OFF}
     Send it traffic and SIGTERM it. The Action Stats block reports packets
     analysed but "Alerts: 0". The rules are loaded and syntactically valid.
     Ask yourself what a rule header actually compares an IP address against.

  4. ${C_YEL}It alerts, but the alert file stays empty.${C_OFF}
     Action Stats now reports a non-zero alert count while
     <logdir>/alert is missing or empty. Detection and output are two
     different stages. Look at the output plugin and at what appeared in the
     log directory instead.

  5. ${C_YEL}Two of the three signatures fire.${C_OFF}
     The ICMP one (${SID_ICMP}) never appears, although the rule is loaded and
     the packets are on the wire. Something between "the rule matched" and
     "the event is emitted" is discarding it.

YOUR GOAL
  Make this command print PASS on all five checks:

      $0 check

  which means: snort -T is clean, snort reaches packet processing, it counts
  at least three alerts, the plain-text alert file exists, and it contains
  all three SIDs (${SID_ICMP}, ${SID_HTTP}, ${SID_UDP}).

RULES OF ENGAGEMENT
  * Do not delete the three lab rules and do not rewrite them; they are
    correct. Fix everything around them (one appended fourth rule is not).
  * Every fix belongs in ${SNORT_CONF}, ${LOCAL_RULES},
    ${THRESHOLD_CONF} or the filesystem. Nothing else is broken.
  * You are expected to reach every diagnosis from snort's own output.

TOOLBOX
  snort -T -c ${SNORT_CONF} -i ${IFACE}        # parse and validate, no capture
  snort -c ${SNORT_CONF} -i ${IFACE} -u ${SNORT_USER} -g ${SNORT_GROUP}   # foreground run
  $0 traffic                                   # replay the test traffic
  tail -f <logdir>/alert                       # alert_fast output
  u2spewfoo <logdir>/snort.u2.*                # decode unified2 output
  Ctrl-C / kill -TERM <pid>                    # makes snort print Action Stats

  $0 hint 1 .. 5     progressive hints, one fault at a time
  $0 reset           restores the known-good lab (this is giving up)

EOF
    rule
}

do_check() {
    need_root
    [[ -f "$SNORT_CONF" ]] || die "no ${SNORT_CONF}; run setup first"
    check_deps
    stop_packaged_service

    local pass=0 total=5
    rule
    say "${C_BLU}GRADING LAB 334.2${C_OFF}"
    rule

    # -- 1. configuration parses --------------------------------------------
    if snort_config_test; then
        ok   "1/5 PASS  snort -T parses the configuration and the ruleset"
        pass=$((pass+1))
    else
        fail "1/5 FAIL  snort -T aborts. Its own words:"
        grep -E "FATAL|ERROR" "$TEST_LOG" | tail -n 5 | sed 's/^/          /'
        rule
        say "Stopping here: nothing downstream can be evaluated while the configuration does not parse."
        say "Score: ${pass}/${total}"
        return 1
    fi

    local logdir alertfile
    logdir="$(current_logdir)"
    alertfile="${logdir}/alert"
    info "configured logdir: ${logdir}"

    # -- 2. snort reaches packet processing ----------------------------------
    if snort_run_and_capture; then
        ok   "2/5 PASS  snort started, dropped privileges to ${SNORT_USER} and captured on ${IFACE}"
        pass=$((pass+1))
    else
        fail "2/5 FAIL  snort died during start-up:"
        grep -E "FATAL|ERROR|Permission" "$RUN_LOG" | tail -n 5 | sed 's/^/          /'
        rule
        say "Score: ${pass}/${total}"
        return 1
    fi

    local n_alerts n_packets
    n_alerts="$(alerts_counted)"
    n_packets="$(packets_analyzed)"
    info "Action Stats: ${n_packets} packets analyzed, ${n_alerts} alerts raised"

    # -- 3. the engine actually matches --------------------------------------
    if [[ "$n_alerts" -ge 3 ]]; then
        ok   "3/5 PASS  the detection engine matched the test traffic (${n_alerts} alerts)"
        pass=$((pass+1))
    else
        fail "3/5 FAIL  only ${n_alerts} alerts for ${n_packets} analysed packets."
        say  "          The rules load, so the header is not selecting your traffic."
        say  "          Compare 'ipvar HOME_NET' / 'ipvar EXTERNAL_NET' against 127.0.0.1."
    fi

    # -- 4. text output plugin ------------------------------------------------
    if [[ -s "$alertfile" ]]; then
        ok   "4/5 PASS  ${alertfile} exists and is not empty"
        pass=$((pass+1))
    else
        fail "4/5 FAIL  ${alertfile} is missing or empty."
        if compgen -G "${logdir}/snort.u2.*" >/dev/null 2>&1; then
            say "          But this is in the log directory:"
            ls -l "${logdir}"/snort.u2.* | sed 's/^/          /'
            say "          Which output plugin is configured, and who reads that format?"
        fi
    fi

    # -- 5. every signature emitted ------------------------------------------
    local missing=""
    local sid
    for sid in "$SID_ICMP" "$SID_HTTP" "$SID_UDP"; do
        grep -Fq "[1:${sid}:" "$alertfile" 2>/dev/null || missing="${missing} ${sid}"
    done
    if [[ -z "$missing" ]]; then
        ok   "5/5 PASS  all three signatures emitted events (${SID_ICMP}, ${SID_HTTP}, ${SID_UDP})"
        pass=$((pass+1))
    else
        fail "5/5 FAIL  no event recorded for sid(s):${missing}"
        say  "          A rule can match and still produce nothing. Check what is"
        say  "          included AFTER the ruleset in ${SNORT_CONF}."
    fi

    rule
    if [[ -s "$alertfile" ]]; then
        say "${C_DIM}--- $(basename "$alertfile") ---${C_OFF}"
        sed 's/^/  /' "$alertfile" | head -n 20
        rule
    fi

    if [[ $pass -eq $total ]]; then
        say "${C_GRN}Score: ${pass}/${total} -- sensor restored. All five faults are fixed.${C_OFF}"
        say ""
        say "Before you move on, be able to answer these:"
        say "  * Why does 'ipvar EXTERNAL_NET !\$HOME_NET' break a single-segment sensor?"
        say "  * What would you gain by keeping unified2 and adding barnyard2?"
        say "  * When is 'suppress' the right answer and when is 'event_filter'?"
        say "  * Why is 'config checksum_mode: none' necessary on lo and on"
        say "    interfaces with checksum offload enabled?"
        return 0
    fi
    say "${C_YEL}Score: ${pass}/${total} -- keep going. Try: $0 hint $((pass+1))${C_OFF}"
    return 1
}

do_hint() {
    case "${HINT_N}" in
      1) say "HINT 1 -- snort -T names the file and the line: 'local.rules(NN)'. Read that
            line against a working rule. Snort 2.9 requires msg, sid and rev on
            every rule; the engine refuses to load a ruleset containing a rule it
            cannot key by signature id. Users Manual 2.9, 'Writing Snort Rules'." ;;
      2) say "HINT 2 -- 'Can not get write access to logging directory'. Snort takes that
            path from 'config logdir:' in snort.conf unless -l overrides it on the
            command line. grep the directive; then decide whether the directory
            should be created (with the right owner) or the directive corrected." ;;
      3) say "HINT 3 -- Packets analysed, zero alerts. A rule header matches on IP
            variables, not on interfaces. 'ipvar EXTERNAL_NET !\$HOME_NET' means
            'anything outside HOME_NET'. Your traffic is 127.0.0.1 -> 127.0.0.1.
            Both operands of every rule header must be satisfied simultaneously." ;;
      4) say "HINT 4 -- Alerts are counted but the text file is empty. Detection and
            output are separate stages. 'output unified2' writes a binary spool
            (snort.u2.<epoch>) meant for barnyard2; read it with u2spewfoo. For a
            human-readable file you need 'output alert_fast: alert' (or -A fast)." ;;
      5) say "HINT 5 -- One rule is loaded, matching, and still silent. Look at the last
            include in snort.conf and at ${THRESHOLD_CONF}. 'suppress gen_id 1,
            sig_id NNN' discards events post-detection: generator 1 is the rules
            engine, sig_id is the SID. Users Manual 2.9, 'Event Filtering'." ;;
      *) die "usage: $0 hint <1..5>" ;;
    esac
}

do_traffic() {
    need_root
    check_deps
    [[ -f "$STUB_PY" ]] || write_http_stub
    info "replaying test traffic on 127.0.0.1 (ICMP echo, HTTP GET /lab-secret, UDP/53 marker)"
    generate_traffic
    ok "done -- check your snort output"
}

do_status() {
    [[ -f "$STATE_FILE" ]] || die "lab not initialised; run setup"
    say "lab:        ${LAB_ID}"
    say "state:      $(awk -F= '/^state=/{print $2}' "$STATE_FILE")"
    say "snort:      $(snort -V 2>&1 | awk '/Version/{print $3}' || echo 'not installed')"
    say "config:     ${SNORT_CONF}"
    say "logdir:     $(current_logdir)"
    say "backups:    ${BACKUP_DIR}"
}

do_reset() {
    need_root
    [[ -f "${BACKUP_DIR}/snort.conf.good" ]] || die "no known-good snapshot; run setup"
    stop_packaged_service
    warn "restoring the known-good lab state (this does not teach you anything)"
    cp -a "${BACKUP_DIR}/snort.conf.good"  "$SNORT_CONF"
    cp -a "${BACKUP_DIR}/local.rules.good" "$LOCAL_RULES"
    write_classification
    rm -f "$THRESHOLD_CONF"
    rm -rf "$BROKEN_LOGDIR"
    mkdir -p "$DEFAULT_LOGDIR"
    chown "${SNORT_USER}:${SNORT_GROUP}" "$DEFAULT_LOGDIR"
    chmod 0750 "$DEFAULT_LOGDIR"
    rm -f "${DEFAULT_LOGDIR}/alert"
    printf 'state=good\n' > "$STATE_FILE"
    ok "restored. Re-arm the exercise with: $0 break --i-am-in-a-disposable-lab-vm"
}

do_purge() {
    need_root
    stop_packaged_service
    if [[ -f "${BACKUP_DIR}/snort.conf.prelab" ]]; then
        cp -a "${BACKUP_DIR}/snort.conf.prelab" "$SNORT_CONF"
        ok "restored the pre-lab ${SNORT_CONF}"
    fi
    if [[ -f "${BACKUP_DIR}/local.rules.prelab" ]]; then
        cp -a "${BACKUP_DIR}/local.rules.prelab" "$LOCAL_RULES"
        ok "restored the pre-lab ${LOCAL_RULES}"
    fi
    if [[ -f "${BACKUP_DIR}/threshold.conf.prelab" ]]; then
        cp -a "${BACKUP_DIR}/threshold.conf.prelab" "$THRESHOLD_CONF"
    else
        rm -f "$THRESHOLD_CONF"
    fi
    rm -f "$CLASS_CONF"
    rm -rf "$BROKEN_LOGDIR" "$STATE_DIR"
    warn "the packaged snort service is left stopped and disabled on purpose"
    ok "lab removed"
}

# ---------------------------------------------------------------------- main

[[ $# -gt 0 ]] || { usage; exit 1; }

for arg in "$@"; do
    case "$arg" in
        setup|break|check|hint|reset|purge|traffic|status) CMD="$arg" ;;
        --i-am-in-a-disposable-lab-vm) LAB_ACK="yes" ;;
        1|2|3|4|5) HINT_N="$arg" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: ${arg} (try --help)" ;;
    esac
done

case "$CMD" in
    setup)   do_setup   ;;
    break)   do_break   ;;
    check)   do_check   ;;
    hint)    do_hint    ;;
    traffic) do_traffic ;;
    status)  do_status  ;;
    reset)   do_reset   ;;
    purge)   do_purge   ;;
    *)       usage; exit 1 ;;
esac

exit 0

# =============================================================================
# =============================================================================
#
#   S O L U T I O N   --   do not read this until you have earned it
#
# =============================================================================
# =============================================================================
#
# METHOD FIRST. The pipeline is: parse -> capture -> decode -> preprocess ->
# detect -> output. Diagnose it in that order, because a stage never lies about
# the stage below it. Snort tells you where you are:
#
#   snort -T -c /etc/snort/snort.conf -i lo          # stages 1 only
#   snort -c /etc/snort/snort.conf -i lo -u snort -g snort   # stages 1..6
#   kill -TERM <pid>                                  # prints the verdict
#
# The Action Stats / Packet Statistics block that snort prints on SIGTERM is
# the whole diagnosis in six lines:
#
#   Analyzed: 0            -> you are not capturing (wrong interface, BPF,
#                             checksum_mode dropping everything)
#   Analyzed: N, Alerts: 0 -> capture fine, the detection engine matched
#                             nothing (rule headers / variables / preprocessors)
#   Alerts: N, empty file  -> detection fine, output stage misconfigured
#   Alerts short by one    -> post-detection filtering (suppress/event_filter)
#
# -----------------------------------------------------------------------------
# FAULT 1 -- the ruleset does not parse
# -----------------------------------------------------------------------------
# Symptom:
#   ERROR: /etc/snort/rules/local.rules(NN) Each rule must contain a Rule-sid.
#   Fatal Error, Quitting..
#
# Diagnosis:
#   snort -T -c /etc/snort/snort.conf -i lo 2>&1 | tail -n 5
#   sed -n '25,40p' /etc/snort/rules/local.rules
#   The appended tcp/22 rule has msg, flow and rev but no sid. Snort keys every
#   rule by (gen_id, sig_id, rev); without a sid it cannot register the rule,
#   so it aborts the whole load rather than silently skipping one line. That
#   "all or nothing" behaviour is deliberate: a partially loaded ruleset is a
#   false sense of coverage.
#
# Fix (either is acceptable):
#   sed -i 's/msg:"LAB-334.2 SSH connection attempt"; flow:to_server; rev:1;/msg:"LAB-334.2 SSH connection attempt"; flow:to_server; classtype:misc-activity; sid:1000004; rev:1;/' /etc/snort/rules/local.rules
#   # or simply delete the offending rule:
#   sed -i '/LAB-334.2 SSH connection attempt/d' /etc/snort/rules/local.rules
#
# Verify:
#   snort -T -c /etc/snort/snort.conf -i lo && echo "ruleset parses"
#
# Exam note: local SIDs live at 1,000,000 and above. 100-1,000,000 belongs to
# the Snort distribution, below 100 to the engine. Reusing a distribution SID
# is how you end up with two rules silently overwriting each other.
#
# -----------------------------------------------------------------------------
# FAULT 2 -- snort cannot write where it was told to log
# -----------------------------------------------------------------------------
# Symptom:
#   ERROR: Can not get write access to logging directory "/var/log/snort-ids".
#   (directory doesn't exist or permissions are set incorrectly ...)
#   Fatal Error, Quitting..
#
# Diagnosis:
#   grep -n '^config logdir' /etc/snort/snort.conf
#   ls -ld /var/log/snort-ids /var/log/snort
#   The directive points at a directory that does not exist. snort validates
#   the log directory before it opens any output plugin, because a sensor that
#   cannot record what it sees is worse than no sensor at all. Note that -l on
#   the command line overrides config logdir: -- which is exactly how you would
#   have proved the config file was the culprit:
#     snort -T -c /etc/snort/snort.conf -i lo -l /var/log/snort
#
# Fix (option A -- point the sensor back at the standard directory):
#   sed -i 's#^config logdir:.*#config logdir: /var/log/snort#' /etc/snort/snort.conf
#   install -d -o snort -g snort -m 0750 /var/log/snort
#
# Fix (option B -- keep the new path and create it correctly):
#   install -d -o snort -g snort -m 0750 /var/log/snort-ids
#
# Verify:
#   snort -T -c /etc/snort/snort.conf -i lo && echo "logdir usable"
#
# Exam note: ownership matters because snort opens its output files AFTER
# dropping privileges with -u/-g. A directory writable only by root produces a
# permission error at run time, not at -T time.
#
# -----------------------------------------------------------------------------
# FAULT 3 -- the sensor is defending a network that is not there
# -----------------------------------------------------------------------------
# Symptom:
#   snort runs, Packet Statistics shows a non-zero "Analyzed" count, and
#   Action Stats reports "Alerts: 0". No errors anywhere.
#
# Diagnosis:
#   grep -n '^ipvar' /etc/snort/snort.conf
#     ipvar HOME_NET 192.0.2.0/24
#     ipvar EXTERNAL_NET !$HOME_NET
#   Every lab rule header is "$EXTERNAL_NET any -> $HOME_NET <port>". The test
#   traffic is 127.0.0.1 -> 127.0.0.1. With HOME_NET = 192.0.2.0/24 the
#   destination operand can never match, so the rules are never even evaluated
#   against these packets. This is the classic silent-IDS failure: nothing is
#   broken, nothing is logged, and coverage is zero.
#   The second half matters too: EXTERNAL_NET = !$HOME_NET means "everything
#   that is not HOME_NET". Once HOME_NET is corrected to 127.0.0.0/8, the
#   source 127.0.0.1 falls INSIDE HOME_NET, so !$HOME_NET excludes it and the
#   rules still never match. On a single-segment / loopback sensor,
#   EXTERNAL_NET must stay "any".
#
# Fix (both lines, not just the first):
#   sed -i 's#^ipvar HOME_NET .*#ipvar HOME_NET 127.0.0.0/8#'   /etc/snort/snort.conf
#   sed -i 's#^ipvar EXTERNAL_NET .*#ipvar EXTERNAL_NET any#'   /etc/snort/snort.conf
#
# Verify:
#   snort -c /etc/snort/snort.conf -i lo -u snort -g snort &
#   sleep 5; ping -c 3 127.0.0.1 >/dev/null; sleep 2; kill -TERM %1
#   # Action Stats must now report a non-zero alert count.
#
# Exam note: HOME_NET accepts lists and negation, e.g.
#   ipvar HOME_NET [192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]
# and a wrong HOME_NET is the number one reason production sensors report
# nothing after a network renumbering.
#
# -----------------------------------------------------------------------------
# FAULT 4 -- detection works, the text alert file does not exist
# -----------------------------------------------------------------------------
# Symptom:
#   Action Stats: "Alerts: 6" but /var/log/snort/alert is missing or empty.
#   Instead there is /var/log/snort/snort.u2.1756...  growing.
#
# Diagnosis:
#   grep -n '^output' /etc/snort/snort.conf
#     output unified2: filename snort.u2, limit 128
#   ls -l /var/log/snort/
#   u2spewfoo /var/log/snort/snort.u2.*     # the events are all there
#   unified2 is snort's binary spool format. It is the correct production
#   choice -- barnyard2 reads it and forwards to a database, syslog or a SIEM,
#   which keeps snort itself off the I/O path -- but nothing on this host is
#   consuming it, so operationally the sensor is mute.
#
# Fix (restore the human-readable plugin; keeping unified2 as well is fine and
# is what a real sensor does):
#   sed -i 's#^output unified2:.*#output alert_fast: alert#' /etc/snort/snort.conf
#   # or, to keep both:
#   #   output alert_fast: alert
#   #   output unified2: filename snort.u2, limit 128
#
# Verify:
#   snort -T -c /etc/snort/snort.conf -i lo
#   ./334.2-break-and-fix.sh check      # check 4 should now pass
#
# Exam note: -A fast|full|console|none on the command line overrides the
# output directives in snort.conf. Knowing which one wins is exactly the kind
# of detail 303-300 asks about, and it is also the fastest way to prove that
# the engine is matching while the configured plugin is the problem:
#   snort -c /etc/snort/snort.conf -i lo -A console
#
# -----------------------------------------------------------------------------
# FAULT 5 -- a correct, loaded, matching rule that emits nothing
# -----------------------------------------------------------------------------
# Symptom:
#   /var/log/snort/alert contains [1:1000002:1] and [1:1000003:1] but never
#   [1:1000001:1], even though ping traffic is flowing and the rule is loaded
#   (snort -T counts it among the "Option Chains linked into X Chain Headers").
#
# Diagnosis:
#   tail -n 5 /etc/snort/snort.conf
#     include /etc/snort/threshold.conf
#   cat /etc/snort/threshold.conf
#     suppress gen_id 1, sig_id 1000001
#   suppress operates AFTER detection: the rule matches, the event is created,
#   and then it is dropped before reaching any output plugin. gen_id 1 is the
#   rules engine (preprocessor events use their own generator ids, e.g. 116 for
#   the decoder, 129 for stream5); sig_id is the SID.
#
# Fix (remove the suppression, keep the include mechanism):
#   sed -i '/^suppress gen_id 1, sig_id 1000001/d' /etc/snort/threshold.conf
#   # or drop the include entirely:
#   #   sed -i '\#^include /etc/snort/threshold.conf#d' /etc/snort/snort.conf
#
# Verify the whole chain end to end:
#   snort -T -c /etc/snort/snort.conf -i lo
#   ./334.2-break-and-fix.sh check       # expected: 5/5 PASS
#
# Exam note: know the difference between the two post-detection controls.
#   suppress gen_id 1, sig_id 1000001, track by_src, ip 10.1.1.0/24
#       -> drop these events entirely, optionally only for certain addresses.
#   event_filter gen_id 1, sig_id 1000001, type limit, track by_src, count 1, seconds 60
#       -> keep the detection but rate-limit the alerting (type limit / threshold
#          / both). Use event_filter for noisy-but-real signatures; use suppress
#          only for confirmed false positives on known hosts, and document it,
#          because a suppression is an invisible hole in your coverage.
#
# -----------------------------------------------------------------------------
# ONE-SHOT REPAIR (for reference only -- the point of the lab is the diagnosis)
# -----------------------------------------------------------------------------
#   sed -i '/LAB-334.2 SSH connection attempt/d'                 /etc/snort/rules/local.rules
#   sed -i 's#^config logdir:.*#config logdir: /var/log/snort#'  /etc/snort/snort.conf
#   sed -i 's#^ipvar HOME_NET .*#ipvar HOME_NET 127.0.0.0/8#'    /etc/snort/snort.conf
#   sed -i 's#^ipvar EXTERNAL_NET .*#ipvar EXTERNAL_NET any#'    /etc/snort/snort.conf
#   sed -i 's#^output unified2:.*#output alert_fast: alert#'     /etc/snort/snort.conf
#   sed -i '/^suppress gen_id 1, sig_id 1000001/d'               /etc/snort/threshold.conf
#   install -d -o snort -g snort -m 0750 /var/log/snort
#   snort -T -c /etc/snort/snort.conf -i lo
#
# -----------------------------------------------------------------------------
# WHERE THIS SITS IN THE 334.2 OBJECTIVE
# -----------------------------------------------------------------------------
# This lab covers the Snort half of the objective: configuration, rule
# management, and the diagnosis of a sensor that fails open. The objective also
# expects bandwidth-usage monitoring and vulnerability scanning. Extend the
# exercise on the same VM:
#   * iftop -i lo, bandwidthd, ntopng, and Cacti (SNMP-polled RRD graphs) for
#     bandwidth accounting -- ask yourself which of them survives a reboot and
#     which gives you per-flow attribution.
#   * OpenVAS / Greenbone: openvas-nvt-sync (feed update), openvassd + openvasmd
#     (scanner and manager), gsad (web UI), gsd, and omp for scripted scans;
#     NASL is the plugin language the feed is written in.
# Objectives: https://www.lpi.org/our-certifications/exam-303-objectives/
# =============================================================================