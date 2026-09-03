#!/usr/bin/env bash
#
# =============================================================================
#  LPI DevOps Tools Engineer -- Exam 701-100, version 2.0.0
#  Topic 704.2: Prometheus Monitoring (exam weight: 10)
#
#  BREAK & FIX LAB -- "The monitoring stack went dark"
#
#  WHAT THIS IS
#    A self-contained lab that installs a real Prometheus + node_exporter
#    stack on a THROWAWAY virtual machine, proves it healthy, then injects
#    four independent, realistic faults. Your job is to restore full
#    observability. The script grades you (`check`) and can undo everything
#    (`reset`). The full step-by-step solution is at the BOTTOM of this file,
#    commented out. Do not scroll there first -- the diagnosis is the lesson.
#
#  WARNING -- DISPOSABLE VM ONLY
#    This script creates a system user, writes /etc/prometheus, /var/lib/
#    prometheus and two systemd units, and will stop/mask a distribution
#    Prometheus if one is already running. Never run it on a machine you
#    care about. Snapshot the VM before you start.
#
#  REQUIREMENTS
#    - Linux with systemd, root privileges (sudo -i)
#    - curl, tar, and outbound HTTPS to github.com for the first `setup`
#      (or pre-place the binaries in /usr/local/bin and export SKIP_DOWNLOAD=1)
#    - ~500 MB free disk, ports 9090 and 9100 free
#
#  USAGE
#    ./704.2-break-fix.sh setup      # install + start + prove baseline health
#    ./704.2-break-fix.sh break      # inject the faults (all four by default)
#    ./704.2-break-fix.sh break 2 4  # inject only selected faults
#    ./704.2-break-fix.sh hint       # symptoms + the tools that expose them
#    ./704.2-break-fix.sh check      # grade your repair, item by item
#    ./704.2-break-fix.sh reset      # restore the known-good stack
#    ./704.2-break-fix.sh purge      # remove everything this lab created
#
#  OFFICIAL SOURCES
#    LPI 701-100 objectives .......... https://www.lpi.org/our-certifications/exam-701-objectives/
#    Configuration reference ......... https://prometheus.io/docs/prometheus/latest/configuration/configuration/
#    Recording rules ................. https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
#    Alerting rules .................. https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
#    Relabeling .................. https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
#    Querying basics ................. https://prometheus.io/docs/prometheus/latest/querying/basics/
#    Management API (/-/reload) ...... https://prometheus.io/docs/prometheus/latest/management_api/
#    node_exporter ................... https://github.com/prometheus/node_exporter
#    promtool ........................ https://prometheus.io/docs/prometheus/latest/command-line/promtool/
# =============================================================================

set -euo pipefail

# ------------------------------- parameters ----------------------------------
PROM_VER="${PROM_VER:-3.5.0}"          # Prometheus LTS line; override if you mirror another
NODE_VER="${NODE_VER:-1.9.1}"          # node_exporter
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
NODE_PORT_GOOD=9100
NODE_PORT_BAD=9110                     # nothing listens here -- that is the point

LAB_DIR=/opt/lab-704.2
STATE_FILE="$LAB_DIR/state"
OWNER_MARK="$LAB_DIR/OWNED_BY_LAB"
CONF_DIR=/etc/prometheus
RULE_DIR="$CONF_DIR/rules"
DATA_DIR=/var/lib/prometheus
UNIT_PROM=/etc/systemd/system/lab-prometheus.service
UNIT_NODE=/etc/systemd/system/lab-node-exporter.service
SVC_PROM=lab-prometheus.service
SVC_NODE=lab-node-exporter.service
LAB_USER=prometheus

# --------------------------------- helpers -----------------------------------
c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_warn=$'\033[33m'; c_hi=$'\033[1m'; c_off=$'\033[0m'
[ -t 1 ] || { c_ok=""; c_bad=""; c_warn=""; c_hi=""; c_off=""; }

log()  { printf '%s[704.2]%s %s\n' "$c_hi" "$c_off" "$*"; }
ok()   { printf '  %s[ PASS ]%s %s\n' "$c_ok" "$c_off" "$*"; }
bad()  { printf '  %s[ FAIL ]%s %s\n' "$c_bad" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%s[fatal]%s %s\n' "$c_bad" "$c_off" "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root on a disposable VM (sudo -i)"; }

need_systemd() {
  [ -d /run/systemd/system ] || die "systemd is required; this lab drives units, not background shells"
}

pkg_install() {
  # Best effort only: the lab never depends on the distro for Prometheus itself.
  local pkgs=("$@")
  if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq "${pkgs[@]}"
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q "${pkgs[@]}"
  elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install -y "${pkgs[@]}"
  elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm "${pkgs[@]}"
  else warn "unknown package manager; install manually: ${pkgs[*]}"; return 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l)        echo armv7 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

# Return the first sample value of an instant query, or empty string.
q_value() {
  local expr="$1" out
  out="$(curl -fsS --get --data-urlencode "query=${expr}" "${PROM_URL}/api/v1/query" 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.data.result[0].value[1] // empty' <<<"$out"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
r = d.get("data", {}).get("result", [])
print(r[0]["value"][1] if r else "")
PY
  else
    die "need jq or python3 to read the query API"
  fi
}

# Poll a query until it returns a value (or times out). $1 expr, $2 seconds.
wait_series() {
  local expr="$1" secs="${2:-30}" v i
  for ((i = 0; i < secs; i++)); do
    v="$(q_value "$expr" 2>/dev/null || true)"
    [ -n "$v" ] && { echo "$v"; return 0; }
    sleep 1
  done
  return 1
}

wait_http() {
  local url="$1" secs="${2:-30}" i
  for ((i = 0; i < secs; i++)); do
    curl -fsS -o /dev/null "$url" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

state_set() { mkdir -p "$LAB_DIR"; printf '%s\n' "$1" > "$STATE_FILE"; }
state_get() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "none"; }

# --------------------------- configuration writers ---------------------------
# Everything is generated, never sed-patched: reset is therefore exact.

write_prometheus_yml() {
  # $1 = node_exporter port to scrape, $2 = "drop" to inject the relabel fault
  local node_port="$1" relabel="${2:-}"
  {
    cat <<EOF
# Managed by the 704.2 break & fix lab. Regenerated by setup/break/reset.
# Reference: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
global:
  scrape_interval: 5s
  scrape_timeout: 4s
  evaluation_interval: 5s
  external_labels:
    monitor: lab-704-2

rule_files:
  - ${RULE_DIR}/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
EOF
    if [ "$relabel" = "drop" ]; then
      cat <<'EOF'
    relabel_configs:
      - source_labels: [__address__]
        regex: 'localhost:9090'
        action: drop
EOF
    fi
    cat <<EOF

  - job_name: node
    static_configs:
      - targets: ['localhost:${node_port}']
        labels:
          env: lab
EOF
  } > "$CONF_DIR/prometheus.yml"
  chown root:"$LAB_USER" "$CONF_DIR/prometheus.yml"
  chmod 0644 "$CONF_DIR/prometheus.yml"
}

write_rules_yml() {
  # $1 = "broken" to inject an invalid `for` duration
  local mode="${1:-good}" for_value="30s"
  [ "$mode" = "broken" ] && for_value="30"
  cat > "$RULE_DIR/node.rules.yml" <<EOF
# Managed by the 704.2 break & fix lab.
# Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
# Alerting rules:  https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
groups:
  - name: node-lab
    interval: 5s
    rules:
      - record: job:node_cpu_seconds:rate5m
        expr: sum by (job) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))

      - alert: NodeExporterDown
        expr: up{job="node"} == 0
        for: ${for_value}
        labels:
          severity: critical
        annotations:
          summary: "node_exporter target {{ \$labels.instance }} has been down for 30s"
EOF
  chown -R root:"$LAB_USER" "$RULE_DIR"
  chmod 0644 "$RULE_DIR/node.rules.yml"
}

write_prometheus_unit() {
  cat > "$UNIT_PROM" <<'EOF'
[Unit]
Description=Lab Prometheus (LPI 701-100 topic 704.2)
Documentation=https://prometheus.io/docs/prometheus/latest/
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=2h \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
StartLimitBurst=3
StartLimitIntervalSec=120

[Install]
WantedBy=multi-user.target
EOF
}

write_node_unit() {
  # $1 = "nocollectors" to inject the disabled-collectors fault
  local mode="${1:-good}" extra=""
  [ "$mode" = "nocollectors" ] && extra=" --collector.disable-defaults"
  cat > "$UNIT_NODE" <<EOF
[Unit]
Description=Lab node_exporter (LPI 701-100 topic 704.2)
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:${NODE_PORT_GOOD}${extra}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------- setup ------------------------------------
install_binaries() {
  local arch tmp
  arch="$(detect_arch)"
  if [ "${SKIP_DOWNLOAD:-0}" = "1" ]; then
    command -v /usr/local/bin/prometheus >/dev/null || die "SKIP_DOWNLOAD=1 but /usr/local/bin/prometheus is missing"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || pkg_install curl || die "curl is required"
  command -v tar  >/dev/null 2>&1 || pkg_install tar  || die "tar is required"
  command -v jq   >/dev/null 2>&1 || pkg_install jq   || warn "jq unavailable; falling back to python3"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  if [ ! -x /usr/local/bin/prometheus ]; then
    log "downloading prometheus ${PROM_VER} (${arch})"
    curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-${arch}.tar.gz" \
      -o "$tmp/prom.tgz" || die "download failed; mirror the tarball and re-run with SKIP_DOWNLOAD=1"
    tar -xzf "$tmp/prom.tgz" -C "$tmp"
    install -m 0755 "$tmp/prometheus-${PROM_VER}.linux-${arch}/prometheus" /usr/local/bin/prometheus
    install -m 0755 "$tmp/prometheus-${PROM_VER}.linux-${arch}/promtool"   /usr/local/bin/promtool
  fi

  if [ ! -x /usr/local/bin/node_exporter ]; then
    log "downloading node_exporter ${NODE_VER} (${arch})"
    curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VER}/node_exporter-${NODE_VER}.linux-${arch}.tar.gz" \
      -o "$tmp/node.tgz" || die "download failed; mirror the tarball and re-run with SKIP_DOWNLOAD=1"
    tar -xzf "$tmp/node.tgz" -C "$tmp"
    install -m 0755 "$tmp/node_exporter-${NODE_VER}.linux-${arch}/node_exporter" /usr/local/bin/node_exporter
  fi
}

stop_distro_stack() {
  local u
  for u in prometheus.service prometheus-node-exporter.service node_exporter.service; do
    if systemctl list-unit-files --no-legend | grep -q "^${u}"; then
      warn "stopping and masking distribution unit ${u} (it would fight for ports 9090/9100)"
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      systemctl mask "$u" >/dev/null 2>&1 || true
    fi
  done
}

do_setup() {
  need_root; need_systemd

  if [ -d "$CONF_DIR" ] && [ ! -f "$OWNER_MARK" ] && [ "${FORCE:-0}" != "1" ]; then
    die "$CONF_DIR already exists and was not created by this lab. Refusing to overwrite a real Prometheus. Re-run with FORCE=1 on a disposable VM if you are sure."
  fi

  mkdir -p "$LAB_DIR" "$CONF_DIR" "$RULE_DIR" "$DATA_DIR"
  touch "$OWNER_MARK"

  id -u "$LAB_USER" >/dev/null 2>&1 || \
    useradd --system --no-create-home --shell /usr/sbin/nologin "$LAB_USER" 2>/dev/null || \
    useradd --system --no-create-home --shell /sbin/nologin "$LAB_USER"

  install_binaries
  stop_distro_stack

  write_prometheus_yml "$NODE_PORT_GOOD" ""
  write_rules_yml good
  write_prometheus_unit
  write_node_unit good
  chown -R "$LAB_USER":"$LAB_USER" "$DATA_DIR"

  systemctl daemon-reload
  systemctl enable --now "$SVC_NODE" >/dev/null
  systemctl enable --now "$SVC_PROM" >/dev/null

  log "waiting for Prometheus to become healthy"
  wait_http "${PROM_URL}/-/healthy" 40 || die "Prometheus did not come up; check: journalctl -u $SVC_PROM -n 50"

  log "verifying the baseline before breaking anything"
  local up_node up_self cpu rec
  up_node="$(wait_series 'up{job="node"}' 30 || true)"
  up_self="$(wait_series 'up{job="prometheus"}' 30 || true)"
  cpu="$(wait_series 'count(node_cpu_seconds_total)' 30 || true)"
  rec="$(wait_series 'job:node_cpu_seconds:rate5m' 40 || true)"

  [ "$up_node" = "1" ] || die "baseline broken: up{job=\"node\"} is '$up_node'"
  [ "$up_self" = "1" ] || die "baseline broken: up{job=\"prometheus\"} is '$up_self'"
  [ -n "$cpu" ]        || die "baseline broken: no node_cpu_seconds_total series"
  [ -n "$rec" ]        || die "baseline broken: recording rule produced no series"

  state_set "healthy"
  ok "up{job=\"node\"} = 1, up{job=\"prometheus\"} = 1, ${cpu} CPU series, recording rule live"
  cat <<EOF

  Baseline is healthy and proven, not assumed.
    Web UI ......... ${PROM_URL}
    Targets ........ ${PROM_URL}/targets
    Rules .......... ${PROM_URL}/rules
    Raw metrics .... http://127.0.0.1:${NODE_PORT_GOOD}/metrics

  Next: sudo $0 break

EOF
}

# ---------------------------------- break ------------------------------------
do_break() {
  need_root; need_systemd
  [ -f "$OWNER_MARK" ] || die "run '$0 setup' first"

  local f1=0 f2=0 f3=0 f4=0 n
  if [ "$#" -eq 0 ]; then
    f1=1; f2=1; f3=1; f4=1
  else
    for n in "$@"; do
      case "$n" in
        1) f1=1 ;; 2) f2=1 ;; 3) f3=1 ;; 4) f4=1 ;;
        *) die "unknown fault id '$n' (valid: 1 2 3 4)" ;;
      esac
    done
  fi

  # Keep a pristine copy so `reset` is a restore, not a guess.
  mkdir -p "$LAB_DIR/backup"
  cp -a "$CONF_DIR/prometheus.yml"      "$LAB_DIR/backup/prometheus.yml"
  cp -a "$RULE_DIR/node.rules.yml"      "$LAB_DIR/backup/node.rules.yml"
  cp -a "$UNIT_NODE"                    "$LAB_DIR/backup/lab-node-exporter.service"

  local node_port="$NODE_PORT_GOOD" relabel="" rules=good node_mode=good
  [ "$f1" = 1 ] && rules=broken
  [ "$f2" = 1 ] && node_port="$NODE_PORT_BAD"
  [ "$f3" = 1 ] && relabel="drop"
  [ "$f4" = 1 ] && node_mode=nocollectors

  write_prometheus_yml "$node_port" "$relabel"
  write_rules_yml "$rules"
  write_node_unit "$node_mode"

  systemctl daemon-reload
  systemctl restart "$SVC_NODE" || true
  systemctl restart "$SVC_PROM" >/dev/null 2>&1 || true   # expected to fail when fault 1 is on
  sleep 3

  state_set "broken:${f1}${f2}${f3}${f4}"

  cat <<'EOF'

===============================================================================
  THE STACK IS NOW BROKEN. YOU ARE ON CALL.
===============================================================================

SCENARIO
  A colleague "cleaned up" the monitoring host during the last maintenance
  window and pushed the change without running any validation. Since then the
  dashboards are empty and nobody trusts the alerts any more. Nothing was
  documented. You have the machine, systemd, the Prometheus binaries and
  promtool. Restore full observability.

SYMPTOMS YOU WILL OBSERVE
  1. The Prometheus web UI at http://<vm>:9090 does not answer at all.
     `systemctl status lab-prometheus` shows the unit dead or in a restart
     loop, ending in `failed`. curl returns "connection refused".
  2. Once Prometheus is finally running, /targets shows the `node` job in
     state DOWN with an error mentioning a refused connection -- even though
     the node_exporter process itself is alive and answering on the host.
  3. The `prometheus` job is not merely DOWN: it is ABSENT from /targets.
     No error line, no red row -- the job simply has zero targets, and
     `up{job="prometheus"}` returns "Empty query result". This is the subtle
     one: an absent target produces no `up` series at all, so an alert written
     as `up == 0` can never fire for it.
  4. After the `node` target finally turns UP (green), the panels are STILL
     empty: `node_cpu_seconds_total`, `node_filesystem_avail_bytes` and every
     other `node_*` series return nothing. The exporter answers HTTP 200 and
     exposes only `go_*`, `process_*` and `promhttp_*` metrics. UP means
     "the scrape succeeded", never "the metrics you need are there".

WHAT YOU MUST ACHIEVE (this is exactly what `check` grades)
  a. lab-prometheus.service is active (running) and GET /-/healthy returns 200.
  b. `up{job="node"} == 1`      -- the exporter target is scraped successfully.
  c. `up{job="prometheus"} == 1`-- Prometheus scrapes itself again.
  d. `count(node_cpu_seconds_total) > 0` -- real host metrics are ingested.
  e. The rule group `node-lab` is loaded: the recording rule
     `job:node_cpu_seconds:rate5m` returns a value AND the alerting rule
     `NodeExporterDown` appears in /api/v1/rules.

RULES OF ENGAGEMENT
  - Do not reinstall anything, and do not delete /var/lib/prometheus.
  - Every fault is in a configuration file or a systemd unit. Four faults,
    four different failure classes: invalid rule file, wrong target address,
    a relabeling rule that discards the target, and an exporter started with
    the wrong flags.
  - Fix them in triage order: a process that will not start hides every other
    problem, so make Prometheus run first, then work down /targets.
  - Validate BEFORE you restart. `promtool check config` and
    `promtool check rules` are free and instant; a restart loop is not.

TOOLBOX
  promtool check config /etc/prometheus/prometheus.yml
  promtool check rules  /etc/prometheus/rules/node.rules.yml
  journalctl -u lab-prometheus -n 60 --no-pager
  systemctl cat lab-node-exporter
  curl -s localhost:9100/metrics | head
  curl -s 'localhost:9090/api/v1/targets?state=active' | jq '.data.activeTargets[]|{job:.labels.job,health,lastError}'
  curl -sX POST localhost:9090/-/reload      # hot reload, no restart (--web.enable-lifecycle)

  Grade yourself:  sudo ./704.2-break-fix.sh check
  Give up:         sudo ./704.2-break-fix.sh reset
===============================================================================

EOF
}

# ---------------------------------- hint -------------------------------------
do_hint() {
  cat <<'EOF'

HINTS -- read one, then go back to the terminal.

  H1  If a service refuses to start, the answer is in the journal, not in the
      config file you are staring at. `journalctl -u lab-prometheus -n 40`.
      Prometheus applies its configuration ONCE at startup and treats a rule
      file it cannot parse as a fatal error: it logs the offending file and
      line and exits. Durations in `for:` are Prometheus durations, not bare
      integers -- `30s`, `5m`, `1h30m`, never `30`.

  H2  A target in state DOWN always shows a `lastError`. Read it literally:
      "connection refused" means nothing is listening at the address in
      prometheus.yml. Compare `ss -lntp | grep exporter` (where the exporter
      actually listens) against the `targets:` list (where Prometheus looks).

  H3  A target that is missing entirely was never created. Targets are built
      by the service discovery + relabeling pipeline; `relabel_configs` runs
      BEFORE the scrape, and an `action: drop` whose regex matches removes the
      target completely. Debug it in the UI: /service-discovery shows
      discovered targets, their labels before relabeling, and the reason they
      were dropped.

  H4  UP is a statement about the HTTP request, not about its payload. Fetch
      the exporter's own endpoint and count what is really there:
        curl -s localhost:9100/metrics | grep -c '^node_'
      If that is 0, the exporter was started with collectors turned off.
      `systemctl cat lab-node-exporter` shows the exact ExecStart line, and
      `node_exporter --help` documents the collector flags.

EOF
}

# ---------------------------------- check ------------------------------------
do_check() {
  need_root
  [ -f "$OWNER_MARK" ] || die "run '$0 setup' first"
  local rc=0 v rules_json

  log "grading -- allow a few seconds for scrapes and rule evaluations"
  echo

  if systemctl is-active --quiet "$SVC_PROM"; then
    ok "a. ${SVC_PROM} is active (running)"
  else
    bad "a. ${SVC_PROM} is not running -- systemctl status $SVC_PROM"; rc=1
  fi

  if wait_http "${PROM_URL}/-/healthy" 15 >/dev/null; then
    ok "a. ${PROM_URL}/-/healthy returns 200"
  else
    bad "a. /-/healthy is unreachable"; rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    v="$(wait_series 'up{job="node"}' 25 || true)"
    if [ "$v" = "1" ]; then ok "b. up{job=\"node\"} = 1"
    else bad "b. up{job=\"node\"} = '${v:-<empty>}' (expected 1)"; rc=1; fi

    v="$(wait_series 'up{job="prometheus"}' 25 || true)"
    if [ "$v" = "1" ]; then ok "c. up{job=\"prometheus\"} = 1"
    else bad "c. up{job=\"prometheus\"} = '${v:-<empty>}' -- an empty result means the target does not exist"; rc=1; fi

    v="$(wait_series 'count(node_cpu_seconds_total)' 25 || true)"
    if [ -n "$v" ] && [ "${v%%.*}" -gt 0 ] 2>/dev/null; then ok "d. node_cpu_seconds_total present (${v} series)"
    else bad "d. no node_cpu_seconds_total series -- the exporter is exporting nothing useful"; rc=1; fi

    v="$(wait_series 'job:node_cpu_seconds:rate5m' 40 || true)"
    if [ -n "$v" ]; then ok "e. recording rule job:node_cpu_seconds:rate5m = ${v}"
    else bad "e. recording rule produced no series -- is the rule group loaded and are its inputs present?"; rc=1; fi

    rules_json="$(curl -fsS "${PROM_URL}/api/v1/rules" 2>/dev/null || true)"
    if grep -q '"NodeExporterDown"' <<<"$rules_json"; then ok "e. alerting rule NodeExporterDown is loaded"
    else bad "e. NodeExporterDown is not in /api/v1/rules -- the rule file did not load"; rc=1; fi
  else
    warn "skipping the query-based checks: Prometheus must run first"
  fi

  echo
  if [ "$rc" -eq 0 ]; then
    state_set "fixed"
    printf '%s  ALL CHECKS PASSED. Observability restored.%s\n\n' "$c_ok" "$c_off"
    printf '  Now prove you understand it: run `%s break 3` alone and explain,\n' "$0"
    printf '  in one sentence, why an absent target is more dangerous than a DOWN one.\n\n'
  else
    printf '%s  NOT THERE YET.%s Re-read the failing lines above; each maps to one fault.\n' "$c_bad" "$c_off"
    printf '  Stuck? `%s hint`. Truly stuck? the commented solution at the end of this file.\n\n' "$0"
  fi
  return "$rc"
}

# ------------------------------- reset / purge -------------------------------
do_reset() {
  need_root
  [ -f "$OWNER_MARK" ] || die "nothing to reset"
  log "restoring the known-good stack"
  write_prometheus_yml "$NODE_PORT_GOOD" ""
  write_rules_yml good
  write_node_unit good
  systemctl daemon-reload
  systemctl restart "$SVC_NODE"
  systemctl restart "$SVC_PROM"
  wait_http "${PROM_URL}/-/healthy" 40 || die "Prometheus still unhealthy after reset; inspect journalctl -u $SVC_PROM"
  state_set "healthy"
  ok "stack restored -- run '$0 break' to try again"
}

do_purge() {
  need_root
  log "removing everything this lab created"
  systemctl disable --now "$SVC_PROM" "$SVC_NODE" >/dev/null 2>&1 || true
  rm -f "$UNIT_PROM" "$UNIT_NODE"
  systemctl daemon-reload
  rm -rf "$CONF_DIR" "$DATA_DIR" "$LAB_DIR"
  rm -f /usr/local/bin/prometheus /usr/local/bin/promtool /usr/local/bin/node_exporter
  local u
  for u in prometheus.service prometheus-node-exporter.service node_exporter.service; do
    systemctl unmask "$u" >/dev/null 2>&1 || true
  done
  ok "purged (the '$LAB_USER' system user was left in place)"
}

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------- main -------------------------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  setup)  do_setup ;;
  break)  do_break "$@" ;;
  hint)   do_hint ;;
  check)  do_check ;;
  reset)  do_reset ;;
  purge)  do_purge ;;
  status) echo "lab state: $(state_get)" ;;
  help|-h|--help) usage ;;
  *) die "unknown command '$cmd' (setup|break|hint|check|reset|purge|status)" ;;
esac

# =============================================================================
#  SOLUTION -- STEP BY STEP
#  Stop here unless you have already fought with the four faults.
# =============================================================================
#
#  ---------------------------------------------------------------------------
#  STEP 0 -- TRIAGE. Establish what is running before you change anything.
#  ---------------------------------------------------------------------------
#    # systemctl status lab-prometheus --no-pager
#      * lab-prometheus.service - Lab Prometheus (LPI 701-100 topic 704.2)
#         Active: failed (Result: exit-code) since ...; 20s ago
#        Process: 1423 ExecStart=/usr/local/bin/prometheus ... (code=exited, status=1/FAILURE)
#
#    # systemctl status lab-node-exporter --no-pager
#         Active: active (running)          <-- the exporter is fine, Prometheus is not
#
#    Rule: the collector that will not start hides every downstream fault.
#    Fix the process first, then the targets, then the data.
#
#  ---------------------------------------------------------------------------
#  FAULT 1 -- Invalid alerting rule: Prometheus refuses to start
#  ---------------------------------------------------------------------------
#  Diagnose:
#    # journalctl -u lab-prometheus -n 20 --no-pager
#      level=ERROR ... msg="loading failed" file=/etc/prometheus/rules/node.rules.yml
#          err="unmarshal errors: line 15: cannot unmarshal !!int `30` into model.Duration"
#      level=ERROR ... msg="Error loading config (--config.file=/etc/prometheus/prometheus.yml)"
#
#    Confirm without touching the service (free, instant, no restart loop):
#    # promtool check rules /etc/prometheus/rules/node.rules.yml
#      Checking /etc/prometheus/rules/node.rules.yml
#        FAILED: ... cannot unmarshal !!int `30` into model.Duration
#
#  Why it happens: `for:` takes a Prometheus duration string. A bare integer is
#  not a duration. Rule files are parsed at startup and at every reload; a
#  parse error there is fatal at startup and rejected on reload (in which case
#  the previous, still-valid rule set stays in memory -- which is exactly why a
#  reload can "succeed" in your shell yet leave stale rules running).
#  Reference: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
#
#  Fix:
#    # sed -i 's/^\( *for: *\)30$/\130s/' /etc/prometheus/rules/node.rules.yml
#    # promtool check rules /etc/prometheus/rules/node.rules.yml
#      SUCCESS: 2 rules found
#    # systemctl reset-failed lab-prometheus       # clear the start-limit counter
#    # systemctl start lab-prometheus
#    # curl -s -o /dev/null -w '%{http_code}\n' localhost:9090/-/healthy
#      200
#
#  ---------------------------------------------------------------------------
#  FAULT 2 -- Wrong target address: the `node` job is DOWN
#  ---------------------------------------------------------------------------
#  Diagnose:
#    # curl -s 'localhost:9090/api/v1/targets?state=active' \
#        | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastError)"'
#      node    down    Get "http://localhost:9110/metrics": dial tcp 127.0.0.1:9110: connect: connection refused
#
#    Where does the exporter actually listen?
#    # ss -lntp | grep node_exporter
#      LISTEN 0 4096 *:9100 *:* users:(("node_exporter",pid=1391,fd=3))
#
#    9100 exposed, 9110 scraped. The exporter is healthy; the config lies.
#    ("connection refused" = nothing listening. Contrast with "context deadline
#     exceeded" = something listening but too slow -- a scrape_timeout problem,
#     not an address problem. Read the lastError, do not guess.)
#
#  Fix:
#    # sed -i "s/localhost:9110/localhost:9100/" /etc/prometheus/prometheus.yml
#    # promtool check config /etc/prometheus/prometheus.yml
#      SUCCESS: 1 rule file found, 0 rule errors
#    # curl -sX POST localhost:9090/-/reload     # hot reload; no restart needed
#    # curl -s --get --data-urlencode 'query=up{job="node"}' localhost:9090/api/v1/query | jq '.data.result[0].value[1]'
#      "1"
#
#  ---------------------------------------------------------------------------
#  FAULT 3 -- A relabel_configs drop rule deletes the self-scrape target
#  ---------------------------------------------------------------------------
#  Diagnose:
#    # curl -s --get --data-urlencode 'query=up{job="prometheus"}' localhost:9090/api/v1/query | jq '.data.result'
#      []                                   <-- empty, not 0. The series never existed.
#
#    An absent target is invisible in /targets. Use the service discovery view,
#    which shows discovered targets AND the ones relabeling dropped:
#      Web UI -> Status -> Service Discovery -> job "prometheus" -> "0 / 1 active targets"
#    # curl -s localhost:9090/api/v1/targets | jq '.data.droppedTargetCounts'
#      { "prometheus": 1, "node": 0 }
#
#    Then read the config:
#    # sed -n '/job_name: prometheus/,/job_name: node/p' /etc/prometheus/prometheus.yml
#      relabel_configs:
#        - source_labels: [__address__]
#          regex: 'localhost:9090'
#          action: drop
#
#  Why it matters: relabel_configs runs on discovered targets BEFORE the scrape.
#  `action: drop` discards every target whose concatenated source labels match
#  the regex, so the target is never scraped and no `up` series is produced.
#  An alert written as `up{job="prometheus"} == 0` can therefore NEVER fire --
#  the vector is empty, not zero. This is the classic silent blind spot; the
#  defensive pattern is `absent(up{job="prometheus"}) == 1` (or the standard
#  meta-alert on `count(up) < expected`) alongside the `up == 0` alert.
#  Reference: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
#
#  Fix -- delete the three-line relabel block (it has no legitimate purpose here):
#    # python3 - <<'PY'
#    import re, pathlib
#    p = pathlib.Path("/etc/prometheus/prometheus.yml")
#    s = p.read_text()
#    s = re.sub(r"\n *relabel_configs:\n(?: *- source_labels.*\n| *regex:.*\n| *action: drop\n)+", "\n", s)
#    p.write_text(s)
#    PY
#    # promtool check config /etc/prometheus/prometheus.yml && curl -sX POST localhost:9090/-/reload
#    # curl -s --get --data-urlencode 'query=up{job="prometheus"}' localhost:9090/api/v1/query | jq -r '.data.result[0].value[1]'
#      1
#    (Editing the file by hand with vi is perfectly fine -- the point is that
#     the block is removed and the config revalidated before reloading.)
#
#  ---------------------------------------------------------------------------
#  FAULT 4 -- node_exporter started with --collector.disable-defaults
#  ---------------------------------------------------------------------------
#  Diagnose -- the target is UP and yet there is no data:
#    # curl -s localhost:9100/metrics | grep -c '^node_'
#      0
#    # curl -s localhost:9100/metrics | awk '{print $1}' | grep -v '^#' | cut -d'{' -f1 | sort -u | head
#      go_gc_duration_seconds
#      process_cpu_seconds_total
#      promhttp_metric_handler_requests_total
#
#    The exporter answers HTTP 200 with only its own runtime metrics, which is
#    why `up == 1`: `up` records whether the scrape succeeded, never whether it
#    returned anything meaningful. Find out how the process was launched:
#    # systemctl cat lab-node-exporter | grep ExecStart
#      ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:9100 --collector.disable-defaults
#
#  Fix:
#    # sed -i 's/ --collector.disable-defaults//' /etc/systemd/system/lab-node-exporter.service
#    # systemctl daemon-reload && systemctl restart lab-node-exporter
#    # curl -s localhost:9100/metrics | grep -c '^node_'
#      1100          (exact number varies by kernel, filesystems and NICs)
#
#    Prometheus needs no reload here: the target address did not change, and the
#    next scrape (5s) picks the series up. Wait ~15s for the rate() window to
#    have two samples, then:
#    # curl -s --get --data-urlencode 'query=job:node_cpu_seconds:rate5m' \
#        localhost:9090/api/v1/query | jq -r '.data.result[0].value[1]'
#      0.0731...
#
#  ---------------------------------------------------------------------------
#  STEP 5 -- VERIFY, then verify the alert path too
#  ---------------------------------------------------------------------------
#    # sudo ./704.2-break-fix.sh check         # all six lines must read PASS
#
#    Prove the alerting rule actually works, end to end:
#    # systemctl stop lab-node-exporter        # simulate the failure it watches
#    # sleep 45
#    # curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname) \(.state)"'
#      NodeExporterDown firing
#    # systemctl start lab-node-exporter       # and watch it resolve
#
#    An alerting rule you have never seen fire is a hypothesis, not a control.
#
#  ---------------------------------------------------------------------------
#  WHAT TO TAKE TO THE EXAM AND TO PRODUCTION
#  ---------------------------------------------------------------------------
#    * Triage order: process up -> target up -> series present -> rule firing.
#      Each layer can be green while the next is broken.
#    * `up` has exactly three states and they are not interchangeable:
#        1        scrape succeeded
#        0        scrape attempted and failed (read `lastError`)
#        absent   the target does not exist -- discovery or relabeling killed it.
#      Only the first two are alertable with `up == 0`; the third needs
#      `absent()` or a count-based meta-alert.
#    * Validate before restarting: `promtool check config`, `promtool check
#      rules`, and `promtool test rules` for unit-testing alert logic. All free.
#    * Prefer `curl -X POST /-/reload` (needs --web.enable-lifecycle) over a
#      restart: no gap in the time series, no cold TSDB head block. But a
#      rejected reload keeps the OLD configuration in memory -- always confirm
#      with `prometheus_config_last_reload_successful == 1`.
#    * Exporters are dumb HTTP endpoints. When a panel is empty, `curl` the
#      exporter directly before you suspect Prometheus, PromQL or the dashboard.
# =============================================================================