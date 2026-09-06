#!/usr/bin/env bash
# =============================================================================
#  teach-plat — break & fix laboratory
#  Certification : AZ-900 — Microsoft Azure Fundamentals (exam version 2026-07-20)
#  Domain        : 3. Describe Azure management and governance
#  Topic         : 3.4 Describe monitoring tools in Azure        (exam weight 8.33 %)
#  Study guide   : https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  AZ-900 3.4 asks you to *describe* Azure Advisor, Azure Service Health and Azure
#  Monitor (Log Analytics, Azure Monitor Alerts, Application Insights). Descriptions
#  stick when you have watched the telemetry pipeline break. This lab breaks the
#  guest-side half of that pipeline on a throwaway Linux VM and makes you restore
#  it until fresh Heartbeat and Syslog records reach the workspace again.
#
#  The pipeline you are operating on:
#
#     [ VM: rsyslog ] --unix socket--> [ Azure Monitor Agent ] --HTTPS 443-->
#         [ Log Analytics workspace ] --KQL--> [ Workbooks / Alerts / Advisor ]
#                                            \--> [ Azure Monitor Alerts -> Action Group ]
#
#  Every layer above has its own failure signature, and only one of them is visible
#  from the Azure portal. That asymmetry is the lesson: Azure Monitor can only show
#  you what the agent managed to ship. "No data" in a workbook is not "nothing
#  happened" — it is "no telemetry arrived", which is a completely different
#  incident, and Service Health is where you rule out that the platform is at fault.
#
#  REFERENCES (official Microsoft Learn documentation)
#    Azure Monitor overview .......... https://learn.microsoft.com/en-us/azure/azure-monitor/overview
#    Azure Monitor Agent ............. https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-overview
#    AMA network configuration ....... https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-network-configuration
#    Troubleshoot AMA on Linux ....... https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-linux-vm
#    Data Collection Rules ........... https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview
#    Log Analytics / KQL ............. https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-query-overview
#    Azure Monitor Alerts ............ https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview
#    Application Insights ............ https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview
#    Azure Advisor ................... https://learn.microsoft.com/en-us/azure/advisor/advisor-overview
#    Azure Service Health ............ https://learn.microsoft.com/en-us/azure/service-health/overview
#    Azure Instance Metadata Service . https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service
#
#  SAFETY CONTRACT
#  ---------------
#    * Run this ONLY on a disposable lab VM you can delete. It stops a systemd unit,
#      edits /etc/hosts, may insert one tagged iptables OUTPUT rule, and moves an
#      rsyslog drop-in aside. All of it is recorded and reversible with `restore`.
#    * It never touches user data, never deletes an Azure resource, never opens an
#      inbound port, and never writes outside the paths listed under PATHS below.
#    * It refuses to run unless you confirm explicitly, and it aborts if the Azure
#      Instance Metadata Service reports production tags on this VM.
#    * TWO MODES, detected automatically:
#        real — a genuine Azure VM with the Azure Monitor Agent installed.
#        sim  — any Linux VM. A faithful mock agent + mock ingestion endpoint are
#               installed so the same three faults and the same diagnosis path
#               work with no subscription and no cost.
#
#  USAGE
#      sudo TEACH_LAB_CONFIRM=yes ./az900-3.4-breakfix.sh arm       # prepare + baseline
#      sudo TEACH_LAB_CONFIRM=yes ./az900-3.4-breakfix.sh break     # inject the faults
#                                 ./az900-3.4-breakfix.sh brief     # re-read the mission
#                                 ./az900-3.4-breakfix.sh status    # raw system facts
#                                 ./az900-3.4-breakfix.sh verify    # grade yourself
#                                 ./az900-3.4-breakfix.sh hint 1|2|3
#      sudo TEACH_LAB_CONFIRM=yes ./az900-3.4-breakfix.sh restore   # escape hatch
#      sudo TEACH_LAB_CONFIRM=yes ./az900-3.4-breakfix.sh purge     # remove the lab
#
#  Optional cloud-side fault (real Azure metric alert rule, opt-in):
#      export TEACH_LAB_CLOUD=1 AZ_RG=<resource-group> AZ_ALERT_RULE=<alert-rule-name>
#  Optional Log Analytics grading from the data plane (real mode):
#      export AZ_WORKSPACE_ID=<workspace GUID>   # needs: az extension add -n log-analytics
# =============================================================================

# -e is deliberately NOT set: the verifier runs commands that are *expected* to
# fail (that is how it detects a broken layer). Failures are handled explicitly.
set -uo pipefail

# ----------------------------- PATHS AND CONSTANTS ---------------------------
LAB_ID="az-900-3.4"
STATE_DIR="/var/lib/teach-plat/${LAB_ID}"
WORKSPACE_DIR="${STATE_DIR}/workspace"          # stands in for the Log Analytics workspace
SPOOL="${STATE_DIR}/spool/syslog"               # stands in for the AMA syslog socket
BACKUP_DIR="${STATE_DIR}/backup"
STATE_FILE="${STATE_DIR}/state.env"
CONF_DIR="/etc/teach-plat/${LAB_ID}"
SIM_DIR="/opt/teach-plat/${LAB_ID}"
LOG_DIR="/var/log/teach-plat"
AGENT_LOG="${LOG_DIR}/agent.log"

SIM_AGENT_UNIT="teachplat-ama.service"
SIM_INGEST_UNIT="teachplat-ingest.service"
REAL_AGENT_UNIT="azuremonitoragent.service"
SIM_PORT="18443"
SIM_ENDPOINT="lab-workspace.ods.opinsights.azure.invalid"   # .invalid never resolves publicly (RFC 6761)
BLACKHOLE_IP="198.51.100.13"                                # TEST-NET-2, guaranteed unroutable (RFC 5737)

SIM_RSYSLOG_CONF="/etc/rsyslog.d/10-teachplat-ama.conf"
REAL_RSYSLOG_CONF="/etc/rsyslog.d/10-azuremonitoragent-omfwd.conf"

HOSTS_BEGIN="# >>> teach-plat ${LAB_ID} BEGIN >>>"
HOSTS_END="# <<< teach-plat ${LAB_ID} END <<<"
IPT_TAG="teach-plat-az900-34"

MODE="${TEACH_LAB_MODE:-}"
CLOUD="${TEACH_LAB_CLOUD:-0}"

# ----------------------------------- OUTPUT ----------------------------------
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }

say()  { printf '%s\n' "$*"; }
info() { printf '%s[ .. ]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[ !! ]%s %s\n' "$C_Y" "$C_0" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; }
die()  { printf '%s[STOP]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 2; }
rule() { printf '%s\n' "-----------------------------------------------------------------------"; }

need_root() { [ "$(id -u)" -eq 0 ] || die "this action needs root: re-run with sudo"; }

# ------------------------------- SAFETY GUARDS -------------------------------
confirm_lab() {
    if [ "${TEACH_LAB_CONFIRM:-}" != "yes" ]; then
        die "refusing to touch this host.
       This script stops a monitoring agent and edits /etc/hosts.
       Run it only on a DISPOSABLE lab VM, and confirm with:
           sudo TEACH_LAB_CONFIRM=yes $0 $*"
    fi
}

# Heuristic production guard: ask the Instance Metadata Service (link-local,
# never leaves the host) whether this VM carries production tags. Best effort —
# a missing IMDS simply means "not an Azure VM", which is allowed.
imds_guard() {
    command -v curl >/dev/null 2>&1 || return 0
    local meta
    meta="$(curl -s -m 2 -H 'Metadata:true' \
        'http://169.254.169.254/metadata/instance?api-version=2021-02-01' 2>/dev/null)"
    [ -n "$meta" ] || return 0
    if printf '%s' "$meta" | tr ',' '\n' | grep -qiE '"(tags|tagsList)".*(prod|production)'; then
        die "IMDS reports production tags on this VM. Aborting. Use a scratch VM."
    fi
    info "IMDS reachable, no production tag found — continuing."
}

# ------------------------------ MODE DETECTION -------------------------------
detect_mode() {
    if [ -n "$MODE" ]; then return 0; fi
    if [ -s "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        MODE="${MODE:-}"
        [ -n "$MODE" ] && return 0
    fi
    if [ -d /etc/opt/microsoft/azuremonitoragent ] \
       || systemctl list-unit-files 2>/dev/null | grep -q "^${REAL_AGENT_UNIT}"; then
        MODE="real"
    else
        MODE="sim"
    fi
}

agent_unit() { [ "$MODE" = "real" ] && echo "$REAL_AGENT_UNIT" || echo "$SIM_AGENT_UNIT"; }
rsyslog_conf() { [ "$MODE" = "real" ] && echo "$REAL_RSYSLOG_CONF" || echo "$SIM_RSYSLOG_CONF"; }

save_state() {
    mkdir -p "$STATE_DIR"
    { printf 'MODE=%s\n' "$MODE"
      printf 'ARMED_AT=%s\n' "${ARMED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
      printf 'BROKEN=%s\n' "${BROKEN:-0}"
      printf 'BROKEN_AT=%s\n' "${BROKEN_AT:-}"
      printf 'CLOUD=%s\n' "$CLOUD"
    } > "$STATE_FILE"
}

# --------------------------- /etc/hosts MANIPULATION -------------------------
hosts_block_clear() {
    [ -f /etc/hosts ] || return 0
    awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
        $0 == b { skip = 1 }
        !skip   { print }
        $0 == e { skip = 0 }
    ' /etc/hosts > "${STATE_DIR}/.hosts.new" 2>/dev/null || return 0
    # cat > preserves the inode, ownership and SELinux label of /etc/hosts
    cat "${STATE_DIR}/.hosts.new" > /etc/hosts
    rm -f "${STATE_DIR}/.hosts.new"
}

sim_map_endpoint() {   # $1 = IP to map the mock ingestion endpoint to
    local escaped="${SIM_ENDPOINT//./\\.}"
    sed -i "/${escaped}/d" /etc/hosts
    printf '%s %s # teach-plat %s mock Log Analytics ingestion endpoint\n' \
        "$1" "$SIM_ENDPOINT" "$LAB_ID" >> /etc/hosts
}

# Real AMA endpoints: whatever the config cache advertises, plus the global
# control-plane endpoint every AMA must reach to fetch its DCR configuration.
real_endpoints() {
    { grep -rhoE '[a-z0-9-]+\.(ods|oms)\.opinsights\.azure\.com' \
          /etc/opt/microsoft/azuremonitoragent 2>/dev/null
      echo "global.handler.control.monitor.azure.com"
    } | sed '/^$/d' | sort -u
}

# ------------------------- SIMULATOR PROVISIONING ----------------------------
install_sim() {
    command -v python3 >/dev/null 2>&1 \
        || die "sim mode needs python3 (it plays the ingestion endpoint). Install it first."
    command -v systemctl >/dev/null 2>&1 || die "this lab requires systemd"

    mkdir -p "$SIM_DIR" "$CONF_DIR" "$WORKSPACE_DIR" "$(dirname "$SPOOL")" "$LOG_DIR" "$BACKUP_DIR"
    : > "$SPOOL"
    touch "${WORKSPACE_DIR}/Heartbeat.jsonl" "${WORKSPACE_DIR}/Syslog.jsonl" "$AGENT_LOG"

    cat > "${CONF_DIR}/agent.conf" <<EOF
# Mock Azure Monitor Agent configuration (AZ-900 3.4 lab).
# Mirrors the fields a real Data Collection Rule pushes to the agent.
ENDPOINT="${SIM_ENDPOINT}"
PORT="${SIM_PORT}"
COMPUTER="$(hostname -s)"
WORKSPACE="${WORKSPACE_DIR}"
SPOOL="${SPOOL}"
AGENT_VERSION="1.33.2-lab"
INTERVAL="15"
EOF

    cat > "${SIM_DIR}/agent.sh" <<'AGENT_EOF'
#!/usr/bin/env bash
# Mock Azure Monitor Agent. Same contract as the real one:
#   1. read the collection configuration pushed by the DCR
#   2. reach the workspace ingestion endpoint over TCP/443
#   3. emit one Heartbeat record per interval
#   4. drain locally buffered Syslog events into the workspace
# If step 2 fails it buffers and logs the error, exactly like mdsd does.
set -uo pipefail
. /etc/teach-plat/az-900-3.4/agent.conf
LOG=/var/log/teach-plat/agent.log

json_escape() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }

while true; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    resolved="$(getent hosts "$ENDPOINT" 2>/dev/null | awk '{print $1}' | paste -sd, -)"
    if timeout 3 bash -c "exec 3<>/dev/tcp/${ENDPOINT}/${PORT}" 2>/dev/null; then
        printf '{"TimeGenerated":"%s","Computer":"%s","Category":"Direct Agent","OSType":"Linux","Version":"%s"}\n' \
            "$ts" "$COMPUTER" "$AGENT_VERSION" >> "${WORKSPACE}/Heartbeat.jsonl"
        if [ -s "$SPOOL" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                printf '{"TimeGenerated":"%s","Computer":"%s","Facility":"user","SyslogMessage":%s}\n' \
                    "$ts" "$COMPUTER" "$(json_escape "$line")" >> "${WORKSPACE}/Syslog.jsonl"
            done < "$SPOOL"
            : > "$SPOOL"
        fi
        printf '%s INFO  upload ok endpoint=%s:%s resolved=%s\n' \
            "$ts" "$ENDPOINT" "$PORT" "${resolved:-NXDOMAIN}" >> "$LOG"
    else
        printf '%s ERROR ingestion endpoint unreachable %s:%s resolved=%s - buffering telemetry\n' \
            "$ts" "$ENDPOINT" "$PORT" "${resolved:-NXDOMAIN}" >> "$LOG"
    fi
    sleep "${INTERVAL:-15}"
done
AGENT_EOF
    chmod 0755 "${SIM_DIR}/agent.sh"

    cat > "/etc/systemd/system/${SIM_INGEST_UNIT}" <<EOF
[Unit]
Description=teach-plat mock Log Analytics ingestion endpoint (AZ-900 3.4 lab)
After=network.target

[Service]
Type=simple
WorkingDirectory=${WORKSPACE_DIR}
ExecStart=/usr/bin/env python3 -m http.server ${SIM_PORT} --bind 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/${SIM_AGENT_UNIT}" <<EOF
[Unit]
Description=teach-plat mock Azure Monitor Agent (AZ-900 3.4 lab)
After=network-online.target ${SIM_INGEST_UNIT}
Wants=${SIM_INGEST_UNIT}

[Service]
Type=simple
ExecStart=${SIM_DIR}/agent.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > "$SIM_RSYSLOG_CONF" <<EOF
# teach-plat ${LAB_ID} — stands in for AMA's rsyslog drop-in
# (${REAL_RSYSLOG_CONF} on a real Azure VM, which forwards to the
#  agent's unix socket /run/azuremonitoragent/default_syslog.socket).
user.*  ${SPOOL}
EOF

    systemctl daemon-reload
    systemctl enable --now "$SIM_INGEST_UNIT" >/dev/null 2>&1
    systemctl unmask "$SIM_AGENT_UNIT" >/dev/null 2>&1
    systemctl enable --now "$SIM_AGENT_UNIT" >/dev/null 2>&1
    sim_map_endpoint "127.0.0.1"
    restart_rsyslog
    ok "sim mode provisioned: mock agent, mock workspace, syslog collection"
}

restart_rsyslog() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^rsyslog\.service'; then
        systemctl restart rsyslog >/dev/null 2>&1 && return 0
        warn "rsyslog restart failed — syslog collection checks may not pass"
    else
        warn "rsyslog is not installed; syslog collection cannot be exercised here"
    fi
}

purge_sim() {
    systemctl disable --now "$SIM_AGENT_UNIT" >/dev/null 2>&1
    systemctl disable --now "$SIM_INGEST_UNIT" >/dev/null 2>&1
    systemctl unmask "$SIM_AGENT_UNIT" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${SIM_AGENT_UNIT}" "/etc/systemd/system/${SIM_INGEST_UNIT}"
    rm -f "$SIM_RSYSLOG_CONF"
    systemctl daemon-reload
    local escaped="${SIM_ENDPOINT//./\\.}"
    sed -i "/${escaped}/d" /etc/hosts
    hosts_block_clear
    rm -rf "$SIM_DIR" "$CONF_DIR" "$STATE_DIR"
    restart_rsyslog
    ok "lab removed"
}

# --------------------------------- ARM ---------------------------------------
do_arm() {
    need_root; confirm_lab arm; imds_guard; detect_mode
    mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$LOG_DIR"
    info "mode: ${MODE}"
    if [ "$MODE" = "sim" ]; then
        install_sim
    else
        systemctl unmask "$REAL_AGENT_UNIT" >/dev/null 2>&1
        systemctl start  "$REAL_AGENT_UNIT" >/dev/null 2>&1
        hosts_block_clear
        ok "real Azure Monitor Agent found and running"
    fi
    ARMED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; BROKEN=0; BROKEN_AT=""
    save_state
    say ""; info "baseline check (this is the healthy state you must restore):"
    do_verify
}

# --------------------------------- BREAK -------------------------------------
do_break() {
    need_root; confirm_lab break; imds_guard; detect_mode
    [ -s "$STATE_FILE" ] || do_arm >/dev/null
    detect_mode
    local unit rsconf
    unit="$(agent_unit)"; rsconf="$(rsyslog_conf)"
    mkdir -p "$BACKUP_DIR"

    # ---- FAULT 1 — control plane of the agent: unit stopped and masked -------
    systemctl stop "$unit" >/dev/null 2>&1
    systemctl mask "$unit" >/dev/null 2>&1
    info "fault 1 injected: ${unit} stopped and masked"

    # ---- FAULT 2 — network path to the workspace ingestion endpoint ----------
    if [ "$MODE" = "sim" ]; then
        sim_map_endpoint "$BLACKHOLE_IP"
    else
        hosts_block_clear
        {   printf '%s\n' "$HOSTS_BEGIN"
            real_endpoints | while IFS= read -r ep; do printf '127.0.0.1 %s\n' "$ep"; done
            printf '%s\n' "$HOSTS_END"
        } >> /etc/hosts
        if command -v iptables >/dev/null 2>&1; then
            iptables -C OUTPUT -d 169.254.169.254 -p tcp --dport 80 \
                -m comment --comment "$IPT_TAG" -j DROP 2>/dev/null \
            || iptables -I OUTPUT 1 -d 169.254.169.254 -p tcp --dport 80 \
                -m comment --comment "$IPT_TAG" -j DROP 2>/dev/null
            info "fault 2b injected: IMDS (169.254.169.254:80) blocked — managed identity token acquisition will fail"
        fi
    fi
    info "fault 2 injected: workspace ingestion endpoint no longer routable"

    # ---- FAULT 3 — data collection: rsyslog stops feeding the agent ----------
    if [ -f "$rsconf" ]; then
        cp -a "$rsconf" "${BACKUP_DIR}/$(basename "$rsconf").bak"
        rm -f "$rsconf"
        restart_rsyslog
        info "fault 3 injected: rsyslog drop-in $(basename "$rsconf") removed"
    else
        warn "fault 3 skipped: ${rsconf} not present"
    fi

    # ---- FAULT 4 (opt-in, cloud) — the alert rule is silently disabled -------
    if [ "$CLOUD" = "1" ]; then
        if command -v az >/dev/null 2>&1 && [ -n "${AZ_RG:-}" ] && [ -n "${AZ_ALERT_RULE:-}" ]; then
            az monitor metrics alert show -g "$AZ_RG" -n "$AZ_ALERT_RULE" -o json \
                > "${BACKUP_DIR}/alert-rule.json" 2>/dev/null
            az monitor metrics alert update -g "$AZ_RG" -n "$AZ_ALERT_RULE" \
                --enabled false -o none 2>/dev/null \
                && info "fault 4 injected: metric alert rule '${AZ_ALERT_RULE}' disabled" \
                || warn "fault 4 skipped: could not update the alert rule (check az login / RBAC)"
        else
            warn "fault 4 skipped: needs az CLI plus AZ_RG and AZ_ALERT_RULE"
        fi
    fi

    BROKEN=1; BROKEN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; save_state
    say ""; print_brief
}

# --------------------------------- BRIEF -------------------------------------
print_brief() {
    detect_mode
    local unit; unit="$(agent_unit)"
    rule
    say " AZ-900 3.4 — INCIDENT BRIEF (mode: ${MODE})"
    rule
    cat <<EOF

 SCENARIO
   You own a Linux VM that reports into a Log Analytics workspace. A workbook
   built on Heartbeat and Syslog was green ten minutes ago. Someone changed the
   host. Nobody wrote it down.

 SYMPTOMS YOU WILL OBSERVE
   1. In the workspace, this query returns no rows for this VM:
          Heartbeat
          | where Computer == "$(hostname -s)"
          | where TimeGenerated > ago(15m)
      The portal blade for the VM shows "No data" on its guest metrics chart.
   2. Any log-search alert rule built on that Heartbeat goes to "Insufficient
      data", NOT to "Fired". Absence of telemetry does not fire an alert unless
      the rule was explicitly written to treat no-data as a failure.
   3. On the VM, '$(basename "$unit" .service)' is not running, and it refuses to start with
      "Unit ... is masked."
   4. Once the agent runs again, Heartbeat comes back but the Syslog table stays
      empty for this Computer: two independent breakages, not one.
   5. Azure Service Health shows NO active incident for Azure Monitor in your
      region — which is the point. The platform is healthy; the fault is yours.

 YOUR MISSION
   Restore end-to-end telemetry flow, working the pipeline from the inside out:
       rsyslog  ->  Azure Monitor Agent  ->  workspace ingestion endpoint
   Success is defined by DATA ARRIVING, not by a green systemctl status.

 SUCCESS CRITERIA (what 'verify' grades)
   [1] the monitoring agent unit is unmasked, enabled and active
   [2] the workspace ingestion endpoint resolves and is reachable again
   [3] the rsyslog drop-in that feeds the agent is back in place
   [4] a Heartbeat record newer than 2 minutes exists for this Computer
   [5] a syslog event generated right now reaches the workspace within 60 s
$( [ "$CLOUD" = "1" ] && echo "   [6] the metric alert rule is enabled again" )

 TOOLBOX (all read-only except the fixes you decide to apply)
   systemctl status/is-active/is-enabled/unmask/start   journalctl -u <unit> -n 50
   getent hosts <fqdn>      grep -n teach-plat /etc/hosts      ss -tnp
   iptables -S OUTPUT       ls -l /etc/rsyslog.d/       logger -p user.notice "..."
   tail -f ${AGENT_LOG}
   az monitor log-analytics query --workspace <GUID> --analytics-query "Heartbeat | take 5"
   az monitor metrics alert list -g <rg> -o table

 COMMANDS
   $0 status      raw facts, no grading
   $0 verify      grade yourself
   $0 hint 1|2|3  progressive hints
   sudo TEACH_LAB_CONFIRM=yes $0 restore   escape hatch (read the solution first)

EOF
    rule
}

# --------------------------------- STATUS ------------------------------------
do_status() {
    detect_mode
    local unit rsconf; unit="$(agent_unit)"; rsconf="$(rsyslog_conf)"
    rule; say " SYSTEM FACTS (mode: ${MODE})"; rule
    printf 'agent unit          : %s\n' "$unit"
    printf '  is-enabled        : %s\n' "$(systemctl is-enabled "$unit" 2>&1)"
    printf '  is-active         : %s\n' "$(systemctl is-active  "$unit" 2>&1)"
    if [ "$MODE" = "sim" ]; then
        printf 'ingestion endpoint  : %s:%s -> %s\n' "$SIM_ENDPOINT" "$SIM_PORT" \
            "$(getent hosts "$SIM_ENDPOINT" | awk '{print $1}' | paste -sd, - )"
        printf 'ingest unit active  : %s\n' "$(systemctl is-active "$SIM_INGEST_UNIT" 2>&1)"
    else
        printf 'hosts override block: %s\n' \
            "$(grep -qF "$HOSTS_BEGIN" /etc/hosts && echo PRESENT || echo absent)"
        real_endpoints | while IFS= read -r ep; do
            printf '  %-52s -> %s\n' "$ep" "$(getent hosts "$ep" | awk '{print $1}' | paste -sd, -)"
        done
        printf 'iptables tag %s : %s\n' "$IPT_TAG" \
            "$(iptables -S OUTPUT 2>/dev/null | grep -c "$IPT_TAG") rule(s)"
    fi
    printf 'rsyslog drop-in     : %s (%s)\n' "$rsconf" \
        "$([ -f "$rsconf" ] && echo present || echo MISSING)"
    printf 'rsyslog active      : %s\n' "$(systemctl is-active rsyslog 2>&1)"
    if [ -f "${WORKSPACE_DIR}/Heartbeat.jsonl" ]; then
        printf 'last Heartbeat      : %s\n' \
            "$(tail -n 1 "${WORKSPACE_DIR}/Heartbeat.jsonl" 2>/dev/null || echo none)"
        printf 'Syslog records      : %s\n' \
            "$(wc -l < "${WORKSPACE_DIR}/Syslog.jsonl" 2>/dev/null || echo 0)"
    fi
    [ -f "$AGENT_LOG" ] && { say "last agent log lines:"; tail -n 5 "$AGENT_LOG"; }
    rule
}

# --------------------------------- VERIFY ------------------------------------
FAILED=0
grade() {  # $1 = 0|1 result, $2 = label, $3 = detail
    if [ "$1" -eq 0 ]; then ok "$2 — $3"; else bad "$2 — $3"; FAILED=$((FAILED+1)); fi
}

check_agent() {
    local unit state enabled r=1 detail
    unit="$(agent_unit)"
    state="$(systemctl is-active "$unit" 2>&1)"
    enabled="$(systemctl is-enabled "$unit" 2>&1)"
    detail="is-active=${state} is-enabled=${enabled}"
    if [ "$state" = "active" ] && [ "$enabled" != "masked" ]; then r=0; fi
    grade "$r" "[1] monitoring agent" "$detail"
}

check_network() {
    local r=0 detail=""
    if [ "$MODE" = "sim" ]; then
        local ip; ip="$(getent hosts "$SIM_ENDPOINT" 2>/dev/null | awk '{print $1; exit}')"
        detail="${SIM_ENDPOINT} -> ${ip:-NXDOMAIN}"
        [ "$ip" = "127.0.0.1" ] || r=1
        if [ "$r" -eq 0 ]; then
            timeout 3 bash -c "exec 3<>/dev/tcp/${SIM_ENDPOINT}/${SIM_PORT}" 2>/dev/null || {
                r=1; detail="${detail} (TCP ${SIM_PORT} refused)"; }
        fi
    else
        if grep -qF "$HOSTS_BEGIN" /etc/hosts; then
            r=1; detail="a teach-plat override block is still in /etc/hosts"
        elif iptables -S OUTPUT 2>/dev/null | grep -q "$IPT_TAG"; then
            r=1; detail="a tagged OUTPUT DROP rule (${IPT_TAG}) is still installed"
        else
            detail="no host override, no tagged firewall rule"
        fi
    fi
    grade "$r" "[2] path to ingestion endpoint" "$detail"
}

check_collection() {
    local rsconf r=0 detail; rsconf="$(rsyslog_conf)"
    if [ ! -f "$rsconf" ]; then
        r=1; detail="$(basename "$rsconf") is missing — nothing feeds the agent"
    elif [ "$(systemctl is-active rsyslog 2>&1)" != "active" ]; then
        r=1; detail="drop-in present but rsyslog is not active"
    else
        detail="$(basename "$rsconf") present, rsyslog active"
    fi
    grade "$r" "[3] syslog collection config" "$detail"
}

check_heartbeat() {
    local r=1 detail="no fresh Heartbeat"
    if [ "$MODE" = "real" ] && [ -n "${AZ_WORKSPACE_ID:-}" ] && command -v az >/dev/null 2>&1; then
        local q out
        q="Heartbeat | where Computer == \"$(hostname -s)\" | where TimeGenerated > ago(10m) | count"
        out="$(az monitor log-analytics query -w "$AZ_WORKSPACE_ID" --analytics-query "$q" -o tsv 2>/dev/null)"
        if [ -n "$out" ] && [ "${out%%[!0-9]*}" != "0" ]; then r=0; detail="workspace returned rows (${out})"; fi
    elif [ "$MODE" = "real" ]; then
        # No data-plane access: fall back to guest-side evidence.
        if [ "$(systemctl is-active "$REAL_AGENT_UNIT" 2>&1)" = "active" ] \
           && [ -S /run/azuremonitoragent/default_syslog.socket ]; then
            r=0; detail="agent active and its syslog socket exists (set AZ_WORKSPACE_ID to grade from KQL)"
        fi
    else
        info "waiting up to 45 s for the agent to ship a Heartbeat..."
        local i last epoch now
        for i in 1 2 3 4 5 6 7 8 9; do
            last="$(tail -n 1 "${WORKSPACE_DIR}/Heartbeat.jsonl" 2>/dev/null \
                    | sed -n 's/.*"TimeGenerated":"\([^"]*\)".*/\1/p')"
            if [ -n "$last" ]; then
                epoch="$(date -u -d "$last" +%s 2>/dev/null || echo 0)"
                now="$(date -u +%s)"
                if [ "$epoch" -gt 0 ] && [ $((now - epoch)) -le 120 ]; then
                    r=0; detail="last Heartbeat ${last} ($((now - epoch))s ago)"; break
                fi
                detail="last Heartbeat ${last} — stale"
            fi
            sleep 5
        done
    fi
    grade "$r" "[4] Heartbeat freshness" "$detail"
}

check_syslog_flow() {
    local marker r=1 detail
    marker="teach-plat-probe-$$-$(date -u +%s)"
    if ! command -v logger >/dev/null 2>&1; then
        warn "[5] syslog end-to-end — skipped: 'logger' not installed"; return 0
    fi
    logger -p user.notice "$marker"
    detail="probe '${marker}' never reached the workspace"
    if [ "$MODE" = "real" ] && [ -n "${AZ_WORKSPACE_ID:-}" ] && command -v az >/dev/null 2>&1; then
        info "waiting up to 3 min for the probe to appear in Log Analytics (ingestion latency)..."
        local i out
        for i in 1 2 3 4 5 6; do
            sleep 30
            out="$(az monitor log-analytics query -w "$AZ_WORKSPACE_ID" \
                   --analytics-query "Syslog | where SyslogMessage has \"${marker}\" | count" \
                   -o tsv 2>/dev/null)"
            if [ -n "$out" ] && [ "${out%%[!0-9]*}" != "0" ]; then
                r=0; detail="probe '${marker}' found in the Syslog table"; break
            fi
        done
    elif [ "$MODE" = "real" ]; then
        if [ -f "$REAL_RSYSLOG_CONF" ] && [ -S /run/azuremonitoragent/default_syslog.socket ]; then
            r=0; detail="drop-in present and agent syslog socket live (set AZ_WORKSPACE_ID for a true end-to-end grade)"
        fi
    else
        info "waiting up to 60 s for the probe to land in the workspace..."
        local i
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
            if grep -q "$marker" "${WORKSPACE_DIR}/Syslog.jsonl" 2>/dev/null; then
                r=0; detail="probe '${marker}' found in Syslog.jsonl"; break
            fi
            sleep 5
        done
    fi
    grade "$r" "[5] syslog end-to-end" "$detail"
}

check_cloud_alert() {
    [ "$CLOUD" = "1" ] || return 0
    command -v az >/dev/null 2>&1 || { warn "[6] alert rule — skipped: no az CLI"; return 0; }
    [ -n "${AZ_RG:-}" ] && [ -n "${AZ_ALERT_RULE:-}" ] \
        || { warn "[6] alert rule — skipped: AZ_RG/AZ_ALERT_RULE unset"; return 0; }
    local enabled r=1
    enabled="$(az monitor metrics alert show -g "$AZ_RG" -n "$AZ_ALERT_RULE" \
               --query enabled -o tsv 2>/dev/null)"
    [ "$enabled" = "true" ] && r=0
    grade "$r" "[6] metric alert rule" "enabled=${enabled:-unknown}"
}

do_verify() {
    detect_mode
    FAILED=0
    rule; say " VERIFICATION (mode: ${MODE})"; rule
    check_agent
    check_network
    check_collection
    check_heartbeat
    check_syslog_flow
    check_cloud_alert
    rule
    if [ "$FAILED" -eq 0 ]; then
        ok "ALL CHECKS PASSED — telemetry flows end to end again."
        say ""
        say " Now answer the AZ-900 questions this incident encodes:"
        say "   * Which Azure Monitor data type was interrupted, logs or metrics?"
        say "   * Why did the alert rule show 'Insufficient data' instead of 'Fired'?"
        say "   * Which of Advisor / Service Health / Monitor would have told you the"
        say "     platform was healthy, and which one told you nothing at all?"
        say "   * Where would Application Insights have fit if this VM ran a web app?"
        return 0
    fi
    bad "${FAILED} check(s) still failing — keep going, or run 'hint 1'."
    return 1
}

# ---------------------------------- HINTS ------------------------------------
do_hint() {
    detect_mode
    case "${1:-1}" in
      1) cat <<EOF
HINT 1 — think in layers, top down, and prove each one before moving on.
  Azure Monitor gives you the top layer only: is data arriving? Answer that first
  (KQL 'Heartbeat | where Computer == "$(hostname -s)"', or 'tail ${AGENT_LOG}').
  Then walk down the guest: is the agent running? if it is, can it reach the
  workspace? if it can, is anything feeding it? Three questions, three commands:
      systemctl status $(agent_unit)
      getent hosts <ingestion endpoint>
      ls -l /etc/rsyslog.d/
EOF
        ;;
      2) cat <<EOF
HINT 2 — the two failures you are most likely to miss.
  a) 'systemctl start' failing with "Unit is masked" is not a permission problem.
     A masked unit is symlinked to /dev/null; it must be unmasked before it can
     start. Check with: systemctl is-enabled $(agent_unit)
  b) A name that resolves is not a name that is *correct*. Compare the resolved
     address against what it should be:
         getent hosts $( [ "$MODE" = sim ] && echo "$SIM_ENDPOINT" || echo "<workspace>.ods.opinsights.azure.com" )
         grep -n -i 'opinsights\|teach-plat' /etc/hosts
     On a real Azure VM also check the outbound path itself:
         iptables -S OUTPUT | grep -i teach-plat
     and remember the agent needs IMDS (169.254.169.254) for its managed identity
     token — block that and it authenticates against nothing.
EOF
        ;;
      3) cat <<EOF
HINT 3 — you fixed the agent, Heartbeat is back, Syslog is still empty.
  Heartbeat is produced BY the agent. Syslog is produced by rsyslog and handed TO
  the agent. Restoring the agent cannot restore the handoff. Look at what
  disappeared from /etc/rsyslog.d/ ($(basename "$(rsyslog_conf)")), put it back,
  and restart rsyslog so it re-reads its configuration. A backup copy of the file
  was left for you in ${BACKUP_DIR}/ — recovering it is legitimate; deleting the
  grading logic is not.
  If you enabled the cloud fault: an alert rule that exists is not an alert rule
  that is enabled. 'az monitor metrics alert list -g <rg> -o table' shows both.
EOF
        ;;
      *) warn "hints are 1, 2 or 3";;
    esac
}

# --------------------------------- RESTORE -----------------------------------
do_restore() {
    need_root; confirm_lab restore; detect_mode
    local unit rsconf; unit="$(agent_unit)"; rsconf="$(rsyslog_conf)"
    systemctl unmask "$unit" >/dev/null 2>&1
    systemctl enable --now "$unit" >/dev/null 2>&1
    if [ "$MODE" = "sim" ]; then
        systemctl enable --now "$SIM_INGEST_UNIT" >/dev/null 2>&1
        sim_map_endpoint "127.0.0.1"
    else
        hosts_block_clear
        while iptables -D OUTPUT -d 169.254.169.254 -p tcp --dport 80 \
              -m comment --comment "$IPT_TAG" -j DROP 2>/dev/null; do :; done
    fi
    [ -f "${BACKUP_DIR}/$(basename "$rsconf").bak" ] \
        && cp -a "${BACKUP_DIR}/$(basename "$rsconf").bak" "$rsconf"
    restart_rsyslog
    if [ "$CLOUD" = "1" ] && command -v az >/dev/null 2>&1 \
       && [ -n "${AZ_RG:-}" ] && [ -n "${AZ_ALERT_RULE:-}" ]; then
        az monitor metrics alert update -g "$AZ_RG" -n "$AZ_ALERT_RULE" --enabled true -o none 2>/dev/null
    fi
    BROKEN=0; BROKEN_AT=""; save_state
    ok "restored — re-running verification"
    say ""; do_verify
}

do_purge() { need_root; confirm_lab purge; detect_mode; [ "$MODE" = "sim" ] && purge_sim || {
    do_restore >/dev/null; rm -rf "$STATE_DIR"; ok "lab state removed (real agent left running)"; }; }

# ---------------------------------- MAIN -------------------------------------
case "${1:-help}" in
    arm)     do_arm ;;
    break)   do_break ;;
    brief)   print_brief ;;
    status)  do_status ;;
    verify)  do_verify ;;
    hint)    do_hint "${2:-1}" ;;
    restore) do_restore ;;
    purge)   do_purge ;;
    *) sed -n '/^#  USAGE/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' ;;
esac

# =============================================================================
#  SOLUTION — step by step. Do not read this until you have tried, and until
#  `verify` has told you at least once which layer is still red.
# =============================================================================
#
#  STEP 0 — Frame the incident with the Azure Monitor data flow.
#  ------------------------------------------------------------
#  Azure Monitor collects two kinds of telemetry: metrics (numeric, time-series,
#  stored in a metrics database) and logs (records, stored in a Log Analytics
#  workspace and queried with KQL). Heartbeat and Syslog are LOGS. Everything
#  above the workspace — workbooks, log-search alert rules, Advisor's reliability
#  recommendations for this VM — reads from that workspace. Therefore, if the
#  workspace has no rows, every layer above it is blind, and none of them can
#  tell you why. That is the first conclusion, and it is a conceptual one, not a
#  command:  "No data" != "nothing is wrong".
#      https://learn.microsoft.com/en-us/azure/azure-monitor/overview
#
#  STEP 1 — Confirm the outage from the data plane, not from the VM.
#  ----------------------------------------------------------------
#  In the workspace (Portal > Log Analytics workspace > Logs), or from the CLI:
#
#      az monitor log-analytics query -w "$AZ_WORKSPACE_ID" --analytics-query '
#          Heartbeat
#          | where TimeGenerated > ago(1h)
#          | summarize LastSeen = max(TimeGenerated) by Computer
#          | order by LastSeen asc' -o table
#
#  A Computer whose LastSeen froze at a point in time is a shipping failure, not
#  a workload failure. Note the timestamp — it is your incident start.
#  In sim mode the equivalent evidence is:  tail -n 5 /var/log/teach-plat/agent.log
#
#  STEP 2 — Rule the platform out before you debug your own VM.
#  ------------------------------------------------------------
#  Portal > Service Health > Service issues, filtered to your region and to
#  "Azure Monitor". Azure Service Health reports incidents, planned maintenance
#  and health advisories that affect YOUR resources; Azure Status is the public,
#  global page. If Service Health is clean, the fault is on your side of the
#  shared responsibility line. Thirty seconds spent here saves an hour.
#      https://learn.microsoft.com/en-us/azure/service-health/overview
#
#  STEP 3 — Fault 1: the agent is masked.
#  --------------------------------------
#      systemctl status azuremonitoragent        # (or teachplat-ama in sim mode)
#      #  Loaded: masked (Reason: Unit ... is masked.)
#      systemctl start azuremonitoragent
#      #  Failed to start ...: Unit azuremonitoragent.service is masked.
#
#  A masked unit is symlinked to /dev/null, so start/enable are refused outright.
#  Unmask it, then start and enable it so the fix survives a reboot:
#
#      sudo systemctl unmask azuremonitoragent
#      sudo systemctl enable --now azuremonitoragent
#      systemctl is-active azuremonitoragent      # -> active
#
#  Do NOT stop here. `active` means the process runs; it says nothing about the
#  process succeeding. This is exactly the trap the incident is built around.
#
#  STEP 4 — Fault 2: the agent runs but cannot reach the workspace.
#  ---------------------------------------------------------------
#      journalctl -u azuremonitoragent -n 50 --no-pager
#      tail -n 20 /var/log/teach-plat/agent.log          # sim mode
#      # ... ERROR ingestion endpoint unreachable ... resolved=198.51.100.13
#
#  Resolve the endpoint by hand and compare it with what it should be:
#
#      getent hosts <workspace-id>.ods.opinsights.azure.com
#      grep -n -iE 'opinsights|handler.control.monitor|teach-plat' /etc/hosts
#
#  A monitoring endpoint answering 127.0.0.1 (or a TEST-NET address) is a local
#  override, never DNS. Remove the injected block from /etc/hosts — it is fenced
#  between the two teach-plat markers, so delete from the BEGIN line through the
#  END line inclusive, and leave the rest of the file untouched:
#
#      sudo cp /etc/hosts /root/hosts.bak
#      sudo sed -i '/>>> teach-plat az-900-3.4 BEGIN >>>/,/<<< teach-plat az-900-3.4 END <<</d' /etc/hosts
#      getent hosts <workspace-id>.ods.opinsights.azure.com   # now a public IP
#
#  In sim mode the endpoint entry is a single line; point it back at 127.0.0.1:
#      sudo sed -i 's/^198\.51\.100\.13 lab-workspace/127.0.0.1 lab-workspace/' /etc/hosts
#
#  On a real Azure VM also clear the outbound block. AMA needs HTTPS 443 to the
#  workspace ingestion and control endpoints, and HTTP to the Instance Metadata
#  Service at 169.254.169.254 to obtain its managed identity token; block IMDS
#  and the agent authenticates against nothing, which surfaces as a token error,
#  not as a network error:
#
#      sudo iptables -S OUTPUT | grep teach-plat-az900-34
#      sudo iptables -D OUTPUT -d 169.254.169.254 -p tcp --dport 80 \
#           -m comment --comment teach-plat-az900-34 -j DROP
#      curl -s -H Metadata:true \
#           "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | head -c 200
#
#  Then restart the agent so it re-resolves and re-authenticates immediately
#  instead of waiting out its backoff:
#      sudo systemctl restart azuremonitoragent
#
#  Heartbeat should reappear within a couple of minutes (real Log Analytics
#  ingestion latency is typically 1-3 minutes; do not mistake latency for failure).
#      https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-network-configuration
#
#  STEP 5 — Fault 3: Heartbeat is back, Syslog is still empty.
#  -----------------------------------------------------------
#  This is the discriminating observation of the whole lab. Heartbeat is emitted
#  BY the agent about itself, so it proves only the agent-to-workspace hop.
#  Syslog is produced by rsyslog and handed to the agent over a unix socket; the
#  Data Collection Rule tells the agent which facilities to keep. If the rsyslog
#  drop-in that performs the handoff is gone, the agent is healthy and the table
#  stays empty forever.
#
#      ls -l /etc/rsyslog.d/
#      #  10-azuremonitoragent-omfwd.conf is missing
#      sudo cp /var/lib/teach-plat/az-900-3.4/backup/10-azuremonitoragent-omfwd.conf.bak \
#              /etc/rsyslog.d/10-azuremonitoragent-omfwd.conf
#      sudo systemctl restart rsyslog
#      ls -l /run/azuremonitoragent/default_syslog.socket     # the receiving end
#
#  (On a real VM you can also force AMA to rewrite that drop-in by re-applying the
#  Data Collection Rule association from the portal or with `az monitor
#  data-collection rule association create` — the DCR is the source of truth for
#  what gets collected, the file on disk is only its rendering.)
#
#  Prove it end to end with a marker of your own instead of trusting the config:
#      logger -p user.notice "restore-probe-$(id -u)-$$"
#      # then, after ingestion latency:
#      #   Syslog | where SyslogMessage has "restore-probe" | project TimeGenerated, Computer
#      https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview
#
#  STEP 6 — Fault 4 (only if you enabled the cloud fault): the silent alert rule.
#  -----------------------------------------------------------------------------
#      az monitor metrics alert list -g "$AZ_RG" -o table      # Enabled: False
#      az monitor metrics alert update -g "$AZ_RG" -n "$AZ_ALERT_RULE" --enabled true
#
#  An Azure Monitor alert rule has three parts: a scope (what to watch), a
#  condition (signal + threshold + evaluation frequency) and an action group
#  (who gets told: email, SMS, webhook, Logic App, ITSM). A rule with no action
#  group fires into a dashboard nobody is looking at; a disabled rule does not
#  evaluate at all. Both look like "no alerts" from a distance, which is why the
#  exam insists you can name the three parts separately.
#      https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview
#
#  STEP 7 — Grade and reflect.
#  ---------------------------
#      ./az900-3.4-breakfix.sh verify        # expect [1]..[5] (and [6]) green
#
#  Map the incident back onto the four AZ-900 3.4 tools, in the order they would
#  actually have helped:
#
#    Azure Service Health — scoped to YOUR subscriptions and resources: active
#      incidents, planned maintenance, health advisories, plus resource health
#      per VM. Told you the platform was fine. Cost: nothing. Always check first.
#
#    Azure Monitor — the collection and analysis platform: metrics (numeric,
#      near-real-time) and logs (KQL over a Log Analytics workspace). It showed
#      the absence of data. It could not show the cause, because the cause was
#      upstream of the collector. Log-search alert rules can be configured to
#      alert on that absence — that is the design fix for this incident class.
#
#    Application Insights — the APM member of the Azure Monitor family for
#      applications: requests, dependencies, exceptions, availability tests,
#      distributed tracing, live metrics. Irrelevant to a stopped VM agent, and
#      exactly the tool you would add if this VM served a web application whose
#      users complained about latency rather than about a missing chart.
#
#    Azure Advisor — the recommendation engine across Reliability, Security,
#      Performance, Cost and Operational Excellence. It is advisory, not
#      diagnostic: it would have suggested enabling diagnostics or alert rules
#      BEFORE the incident. It has nothing to say once you are already blind.
#
#  Exam-shaped takeaway: Advisor recommends, Service Health reports on Azure,
#  Azure Monitor observes your resources, Application Insights observes your
#  application code. Any question that asks "which tool would you use to ..."
#  is asking you to place the verb — recommend / report / observe / instrument.
#
#  CLEANUP
#      sudo TEACH_LAB_CONFIRM=yes ./az900-3.4-breakfix.sh purge
#      # then delete the VM. It is a lab VM. It has served its purpose.
# =============================================================================