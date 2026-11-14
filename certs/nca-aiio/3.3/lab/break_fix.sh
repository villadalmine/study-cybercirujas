#!/usr/bin/env bash
# lab-resources: cpus=1 ram_mb=512
#
# NCA-AIIO 3.3: Articulate the key measures and criteria related to monitoring GPUs
# Break & fix lab: "The GPU node that went dark on the dashboard"
#
# Scenario
#   This disposable VM plays the role of a 4x H100 GPU node. Real GPUs are not
#   needed. A small simulator, fake-dcgm-exporter, behaves like NVIDIA
#   dcgm-exporter (https://developer.nvidia.com/dcgm). It reads a collectors CSV
#   (the same format as dcgm-exporter's default-counters.csv). It exposes
#   Prometheus metrics with the same names and labels (DCGM_FI_DEV_*,
#   DCGM_FI_PROF_*, gpu, UUID, modelName, Hostname...). The fleet's Prometheus
#   scrapes this node on :9400/metrics.
#
#   Someone "trimmed" the exporter configuration to cut down cardinality. Now the
#   node is missing from the dashboards. The metrics that decide whether a GPU is
#   healthy (temperature, framebuffer, XID, ECC double-bit errors) are gone. One
#   of the GPUs is failing in silence.
#
# Usage
#   sudo ./break_fix.sh            # same as "break": install + break
#   sudo ./break_fix.sh break
#   sudo ./break_fix.sh verify     # exit 0 only when fixed
#   sudo ./break_fix.sh cleanup    # remove everything this lab created
#
# Safety: everything lives under /opt/gpu-mon-lab, /etc/dcgm-exporter-lab,
# /etc/default/fake-dcgm-exporter and one systemd unit. Nothing else is touched.

set -euo pipefail

LAB_DIR="/opt/gpu-mon-lab"
BIN="${LAB_DIR}/bin/fake-dcgm-exporter.py"
CONF_DIR="/etc/dcgm-exporter-lab"
COLLECTORS="${CONF_DIR}/default-counters.csv"
ENV_FILE="/etc/default/fake-dcgm-exporter"
UNIT="fake-dcgm-exporter.service"
UNIT_FILE="/etc/systemd/system/${UNIT}"
CORDON_FILE="${LAB_DIR}/cordon-list.txt"
SCRAPE_FILE="${LAB_DIR}/prometheus-scrape.yaml"
MARKER="${LAB_DIR}/.lab-installed"

REQUIRED_METRICS=(
  DCGM_FI_DEV_GPU_TEMP
  DCGM_FI_DEV_POWER_USAGE
  DCGM_FI_DEV_GPU_UTIL
  DCGM_FI_DEV_FB_USED
  DCGM_FI_DEV_FB_FREE
  DCGM_FI_DEV_XID_ERRORS
  DCGM_FI_DEV_ECC_DBE_VOL_TOTAL
  DCGM_FI_PROF_GR_ENGINE_ACTIVE
)

log()  { printf '[lab] %s\n' "$*"; }
fail() { printf '[lab][FAIL] %s\n' "$*" >&2; }
ok()   { printf '[lab][ OK ] %s\n' "$*"; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -n -E bash "$0" "$@"
    fi
    echo "This lab must run as root." >&2
    exit 1
  fi
}

confirm() {
  if [ "${STUDY_LAB:-}" = "1" ] || [ "${LAB_DISPOSABLE:-}" = "yes" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    echo "No terminal and STUDY_LAB/LAB_DISPOSABLE not set: refusing to run." >&2
    exit 1
  fi
  read -r -p "This lab installs a systemd service on THIS machine. Disposable VM? [y/N] " ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) echo "Aborted."; exit 1 ;; esac
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1; then return 0; fi
  log "python3 not found, installing it..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q python3 >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q python3 >/dev/null
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install python3 >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 >/dev/null
  else
    echo "Cannot install python3: unknown package manager." >&2
    exit 1
  fi
}

ensure_systemd() {
  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo "This lab needs systemd (systemctl + /run/systemd/system)." >&2
    exit 1
  fi
}

write_simulator() {
  mkdir -p "${LAB_DIR}/bin"
  cat > "$BIN" <<'PY'
#!/usr/bin/env python3
"""fake-dcgm-exporter: a dcgm-exporter look-alike for GPU-less labs.

Reads DCGM_EXPORTER_COLLECTORS (CSV: field, type, help) and serves the listed
fields on DCGM_EXPORTER_LISTEN (default ":9400") at /metrics, for 4 simulated
H100 GPUs. Like the real exporter, it refuses to start on an unknown field or
an invalid metric type.
"""
import os
import random
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VALID_TYPES = {"gauge", "counter", "histogram", "label"}
MODEL = "NVIDIA H100 80GB HBM3"
FB_TOTAL_MIB = 81559

GPUS = [
    {"gpu": "0", "uuid": "GPU-3b1f0c2e-7a44-4d0e-9c1a-0a1b2c3d4e50", "bus": "00000000:18:00.0",
     "temp": 54, "mem_temp": 61, "power": 412.0, "util": 97, "fb_used": 71210,
     "gr": 0.91, "xid": 0, "dbe": 0, "sbe": 2},
    {"gpu": "1", "uuid": "GPU-8c62d9a1-1f3e-4b57-a2d8-1b2c3d4e5f61", "bus": "00000000:2A:00.0",
     "temp": 66, "mem_temp": 70, "power": 655.0, "util": 100, "fb_used": 79870,
     "gr": 0.98, "xid": 0, "dbe": 0, "sbe": 0},
    {"gpu": "2", "uuid": "GPU-e4a7b305-92cd-4f18-8e6b-2c3d4e5f6a72", "bus": "00000000:3A:00.0",
     "temp": 49, "mem_temp": 57, "power": 118.0, "util": 0, "fb_used": 1024,
     "gr": 0.00, "xid": 48, "dbe": 3, "sbe": 151},
    {"gpu": "3", "uuid": "GPU-51d0f6b9-c8e2-47a3-b9f4-3d4e5f6a7b83", "bus": "00000000:5D:00.0",
     "temp": 57, "mem_temp": 63, "power": 498.0, "util": 88, "fb_used": 64012,
     "gr": 0.84, "xid": 0, "dbe": 0, "sbe": 1},
]


def jitter(v, spread):
    return v + random.uniform(-spread, spread) if v else v


FIELDS = {
    "DCGM_FI_DEV_GPU_TEMP":          lambda g: round(jitter(g["temp"], 1)),
    "DCGM_FI_DEV_MEMORY_TEMP":       lambda g: round(jitter(g["mem_temp"], 1)),
    "DCGM_FI_DEV_POWER_USAGE":       lambda g: round(jitter(g["power"], 8.0), 3),
    "DCGM_FI_DEV_GPU_UTIL":          lambda g: max(0, min(100, round(jitter(g["util"], 2)))),
    "DCGM_FI_DEV_FB_USED":           lambda g: g["fb_used"],
    "DCGM_FI_DEV_FB_FREE":           lambda g: FB_TOTAL_MIB - g["fb_used"],
    "DCGM_FI_DEV_XID_ERRORS":        lambda g: g["xid"],
    "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": lambda g: g["dbe"],
    "DCGM_FI_DEV_ECC_SBE_VOL_TOTAL": lambda g: g["sbe"],
    "DCGM_FI_DEV_SM_CLOCK":          lambda g: 1980 if g["util"] else 345,
    "DCGM_FI_PROF_GR_ENGINE_ACTIVE": lambda g: round(max(0.0, jitter(g["gr"], 0.02)), 6),
}


def load_collectors(path):
    out = []
    try:
        fh = open(path, encoding="utf-8")
    except OSError as e:
        sys.exit(f"level=fatal msg=\"cannot open collectors file\" path={path} err=\"{e}\"")
    with fh:
        for n, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",", 2)]
            if len(parts) < 2:
                sys.exit(f"level=fatal msg=\"malformed collectors line\" file={path} line={n}")
            field, mtype = parts[0], parts[1]
            help_ = parts[2] if len(parts) == 3 else field
            if mtype not in VALID_TYPES:
                sys.exit(f"level=fatal msg=\"invalid metric type '{mtype}'\" field={field} "
                         f"file={path} line={n} valid=\"gauge,counter,histogram,label\"")
            if field not in FIELDS:
                sys.exit(f"level=fatal msg=\"could not find DCGM field '{field}'\" file={path} line={n}")
            out.append((field, mtype, help_))
    if not out:
        sys.exit(f"level=fatal msg=\"no collectors configured\" file={path}")
    return out


def render(collectors):
    host = socket.gethostname()
    lines = []
    for field, mtype, help_ in collectors:
        if mtype == "label":
            continue
        lines.append(f"# HELP {field} {help_}")
        lines.append(f"# TYPE {field} {mtype}")
        for i, g in enumerate(GPUS):
            labels = (f'gpu="{g["gpu"]}",UUID="{g["uuid"]}",pci_bus_id="{g["bus"]}",'
                      f'device="nvidia{i}",modelName="{MODEL}",Hostname="{host}"')
            lines.append(f"{field}{{{labels}}} {FIELDS[field](g)}")
    return "\n".join(lines) + "\n"


def main():
    listen = os.environ.get("DCGM_EXPORTER_LISTEN", ":9400")
    collectors_path = os.environ.get("DCGM_EXPORTER_COLLECTORS",
                                     "/etc/dcgm-exporter/default-counters.csv")
    collectors = load_collectors(collectors_path)
    host, _, port = listen.rpartition(":")
    try:
        port = int(port)
    except ValueError:
        sys.exit(f"level=fatal msg=\"invalid listen address\" address={listen}")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.split("?")[0] != "/metrics":
                self.send_response(404)
                self.end_headers()
                return
            body = render(collectors).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    srv = ThreadingHTTPServer((host, port), Handler)
    print(f"level=info msg=\"Starting webserver\" address={listen} "
          f"collectors={collectors_path} fields={len(collectors)}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
PY
  chmod 0755 "$BIN"
}

write_broken_config() {
  mkdir -p "$CONF_DIR"
  # Broken on purpose:
  #  - GPU_TEMP commented out
  #  - POWER_USAGE has an invalid type ("gaugee"), so the exporter will not start
  #  - FB_USED, XID_ERRORS and ECC_DBE_VOL_TOTAL removed ("cardinality cleanup")
  cat > "$COLLECTORS" <<'CSV'
# Format
# If line starts with a '#' it is considered a comment
# DCGM FIELD, Prometheus metric type, help message

# Clocks
DCGM_FI_DEV_SM_CLOCK, gauge, SM clock frequency (in MHz).

# Temperature
# DCGM_FI_DEV_GPU_TEMP, gauge, GPU temperature (in C).
DCGM_FI_DEV_MEMORY_TEMP, gauge, Memory temperature (in C).

# Power
DCGM_FI_DEV_POWER_USAGE, gaugee, Power draw (in W).

# Utilization
DCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization (in %).

# Memory usage (cleanup 2026-11: FB_USED removed to reduce series)
DCGM_FI_DEV_FB_FREE, gauge, Framebuffer memory free (in MiB).

# ECC (cleanup 2026-11: only single-bit kept)
DCGM_FI_DEV_ECC_SBE_VOL_TOTAL, counter, Total number of single-bit volatile ECC errors.

# Profiling
DCGM_FI_PROF_GR_ENGINE_ACTIVE, gauge, Ratio of time the graphics engine is active.
CSV

  cat > "$ENV_FILE" <<EOF
# Environment for fake-dcgm-exporter (same variables as NVIDIA dcgm-exporter)
DCGM_EXPORTER_LISTEN=127.0.0.1:9401
DCGM_EXPORTER_COLLECTORS=${COLLECTORS}
EOF

  cat > "$SCRAPE_FILE" <<'YAML'
# Fragment of the fleet Prometheus configuration (read-only reference).
# Prometheus runs on another host, so the exporter must listen on all interfaces.
scrape_configs:
  - job_name: "gpu-nodes"
    scrape_interval: 15s
    metrics_path: /metrics
    static_configs:
      - targets:
          - "gpu-node-07:9400"
        labels:
          cluster: "train-a"
YAML

  cat > "$CORDON_FILE" <<'EOF'
# One GPU UUID per line: GPUs that must be drained and sent to RMA/field diagnostics.
# Lines starting with '#' are ignored.
EOF
}

write_unit() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Fake NVIDIA DCGM exporter (study lab)
After=network.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/env python3 ${BIN}
Restart=no

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

do_break() {
  confirm
  ensure_systemd
  ensure_python
  log "Installing the simulated 4x H100 GPU node..."
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  write_simulator
  write_broken_config
  write_unit
  touch "$MARKER"
  systemctl enable "$UNIT" >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  systemctl restart "$UNIT" >/dev/null 2>&1 || true
  sleep 1

  cat <<EOF

==============================================================================
 LAB 3.3: GPU monitoring: the node that went dark
==============================================================================
 SYMPTOM
  - The "GPU Fleet" dashboard has no data for this node. The Prometheus
    target ${SCRAPE_FILE} (port 9400) is DOWN.
  - systemctl status ${UNIT}  ->  failed
  - Even after it starts, the health dashboard panels stay empty:
    temperature, framebuffer used, XID errors, ECC double-bit errors.
  - The training team reports that one job runs slowly "on some GPU", and
    nobody can see why.

 FILES
  - Exporter collectors : ${COLLECTORS}
  - Exporter env        : ${ENV_FILE}
  - Prometheus fragment : ${SCRAPE_FILE}
  - Drain list          : ${CORDON_FILE}

 GOAL (verified by: $0 verify)
  1. ${UNIT} is active, and Prometheus on another host can scrape it on port
     9400 (it must listen on all interfaces, not loopback).
  2. /metrics exposes, for all 4 GPUs, at least:
       ${REQUIRED_METRICS[*]}
  3. Once you can see the telemetry, find which GPU is unhealthy. Write ONLY its
     UUID in ${CORDON_FILE}. Healthy-but-busy GPUs must NOT be drained.

 HINTS: journalctl -u ${UNIT}; curl -s localhost:9400/metrics | grep ...
        Think about XID 48 and ECC DBE vs SBE, and GPU_UTIL vs GR_ENGINE_ACTIVE.
==============================================================================
EOF
}

fetch_metrics() {
  python3 - "$1" <<'PY'
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=3) as r:
        sys.stdout.write(r.read().decode())
except Exception as e:
    sys.stderr.write(f"scrape error: {e}\n")
    sys.exit(1)
PY
}

do_verify() {
  local rc=0
  if [ ! -f "$MARKER" ]; then
    fail "Lab not installed. Run: $0 break"
    return 2
  fi
  command -v python3 >/dev/null 2>&1 || { fail "python3 missing"; return 1; }

  if systemctl is-active --quiet "$UNIT"; then
    ok "${UNIT} is active"
  else
    fail "${UNIT} is not active (see: journalctl -u ${UNIT} -n 20)"
    rc=1
  fi

  local listen
  listen="$(sed -n 's/^[[:space:]]*DCGM_EXPORTER_LISTEN=//p' "$ENV_FILE" 2>/dev/null | tail -n1 | tr -d '"'"'"' ')"
  case "$listen" in
    ":9400"|"0.0.0.0:9400"|"[::]:9400") ok "Listen address ${listen} is reachable by the remote Prometheus" ;;
    *) fail "DCGM_EXPORTER_LISTEN='${listen}': Prometheus scrapes <node>:9400 from another host"; rc=1 ;;
  esac

  local metrics
  if ! metrics="$(fetch_metrics http://127.0.0.1:9400/metrics)"; then
    fail "Cannot scrape http://127.0.0.1:9400/metrics"
    return 1
  fi

  local m n
  for m in "${REQUIRED_METRICS[@]}"; do
    n="$(printf '%s\n' "$metrics" | grep -c "^${m}{" || true)"
    if [ "$n" -ge 4 ]; then
      ok "${m} exported for ${n} GPUs"
    else
      fail "${m} missing or incomplete (${n}/4 GPUs)"
      rc=1
    fi
  done

  if [ "$rc" -ne 0 ]; then
    fail "Fix the exporter first; the drain list is checked once telemetry is complete."
    return "$rc"
  fi

  local result
  result="$(printf '%s\n' "$metrics" | python3 -c '
import re, sys
cordon_path = sys.argv[1]
bad = set(); all_uuids = set()
for line in sys.stdin:
    m = re.match(r"^(DCGM_FI_DEV_XID_ERRORS|DCGM_FI_DEV_ECC_DBE_VOL_TOTAL)\{.*UUID=\"([^\"]+)\".*\}\s+([0-9.eE+-]+)$", line.strip())
    if m:
        all_uuids.add(m.group(2))
        if float(m.group(3)) > 0:
            bad.add(m.group(2))
listed = set()
with open(cordon_path) as fh:
    for l in fh:
        l = l.strip()
        if l and not l.startswith("#"):
            listed.add(l)
if listed == bad and bad:
    print("OK")
else:
    missing = bad - listed; extra = listed - bad
    msg = []
    if missing: msg.append("unhealthy GPU not drained (" + str(len(missing)) + ")")
    if extra: msg.append("drained GPU(s) that are healthy or unknown: " + ", ".join(sorted(extra)))
    if not listed: msg.append("drain list is empty")
    print("; ".join(msg) or "drain list does not match")
' "$CORDON_FILE")"

  if [ "$result" = "OK" ]; then
    ok "Drain list contains exactly the unhealthy GPU"
  else
    fail "Drain list: ${result}"
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    echo
    ok "Lab solved: the node is observable again and the failing GPU is drained."
  fi
  return "$rc"
}

do_cleanup() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$UNIT" >/dev/null 2>&1 || true
    systemctl disable "$UNIT" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_FILE" "$ENV_FILE"
  rm -rf "$CONF_DIR" "$LAB_DIR"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  log "Cleanup complete (python3 is left installed if the lab installed it)."
}

need_root "$@"

case "${1:-break}" in
  break)   do_break ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  *) echo "Usage: $0 [break|verify|cleanup]" >&2; exit 64 ;;
esac

# =============================================================================
# SOLUTION (step by step). Try the lab on your own before reading this.
# =============================================================================
#
# 1) Read the failure the way an SRE would: service state first, then logs.
#      systemctl status fake-dcgm-exporter
#      journalctl -u fake-dcgm-exporter -n 20 --no-pager
#    Expected:
#      level=fatal msg="invalid metric type 'gaugee'" field=DCGM_FI_DEV_POWER_USAGE ...
#    The real dcgm-exporter behaves the same way: a bad collectors CSV is a
#    startup failure. To Prometheus, the target is just DOWN (up == 0). That is
#    why "up == 0 for the gpu-nodes job" should be an alert of its own.
#
# 2) Repair the collectors file /etc/dcgm-exporter-lab/default-counters.csv:
#      - fix the type:        DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (in W).
#      - uncomment:           DCGM_FI_DEV_GPU_TEMP, gauge, GPU temperature (in C).
#      - add back:            DCGM_FI_DEV_FB_USED, gauge, Framebuffer memory used (in MiB).
#                             DCGM_FI_DEV_XID_ERRORS, gauge, Value of the last XID error encountered.
#                             DCGM_FI_DEV_ECC_DBE_VOL_TOTAL, counter, Total number of double-bit volatile ECC errors.
#    Why these fields: temperature and power show thermal and power limits.
#    FB_USED/FB_FREE predict OOM. GPU_UTIL alone is coarse: it only reports
#    whether *a* kernel was running. PROF_GR_ENGINE_ACTIVE (and SM activity)
#    show how busy the GPU really is. XID and ECC DBE are the hardware health
#    signals that decide a drain/RMA. Removing them to "save cardinality" saves
#    almost nothing, because they cost one series per GPU.
#
# 3) Fix the listen address in /etc/default/fake-dcgm-exporter:
#      DCGM_EXPORTER_LISTEN=:9400
#    127.0.0.1:9401 had two faults: wrong port (the scrape config uses 9400),
#    and loopback-only, so the remote Prometheus could not reach it anyway.
#
# 4) Restart and check:
#      systemctl restart fake-dcgm-exporter
#      systemctl is-active fake-dcgm-exporter          # -> active
#      curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(XID_ERRORS|ECC_DBE_VOL_TOTAL|GPU_UTIL)\{'
#
# 5) Diagnose the GPUs:
#      curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_XID_ERRORS\{' 
#    GPU 2 (UUID GPU-e4a7b305-92cd-4f18-8e6b-2c3d4e5f6a72) reports XID 48 and
#    DCGM_FI_DEV_ECC_DBE_VOL_TOTAL = 3. XID 48 is a double-bit ECC error. DBEs
#    cannot be corrected, so the GPU must be drained and run through field
#    diagnostics (dcgmi diag -r 3) or RMA. Single-bit errors (SBE) are
#    corrected, so a few of them are not, on their own, a reason to drain.
#    It also sits at 0% utilization with ~1 GiB used: the scheduler and the
#    job "lost" it, and that is the slow job.
#    GPU 1 is at 100% util, ~98% GR active and 66 C. That is a healthy GPU at
#    full load. It is NOT a candidate for draining. High utilization is not a
#    fault, but hardware error counters are.
#
# 6) Drain only the faulty GPU:
#      echo GPU-e4a7b305-92cd-4f18-8e6b-2c3d4e5f6a72 >> /opt/gpu-mon-lab/cordon-list.txt
#
# 7) Verify:
#      ./break_fix.sh verify     # -> all [ OK ], exit 0
#
# Production follow-up (what you would add in a real cluster):
#    - alert: up{job="gpu-nodes"} == 0 for 5m
#    - alert: DCGM_FI_DEV_XID_ERRORS > 0, labelled with UUID and Hostname
#    - alert: increase(DCGM_FI_DEV_ECC_DBE_VOL_TOTAL[10m]) > 0
#    - alert: DCGM_FI_DEV_GPU_TEMP sustained near the slowdown threshold
#    - capacity/efficiency panel: avg(DCGM_FI_PROF_GR_ENGINE_ACTIVE) per job,
#      not just GPU_UTIL. On Kubernetes, dcgm-exporter (GPU Operator) adds
#      pod/namespace labels, so idle allocations can be charged back.
#    References: https://developer.nvidia.com/dcgm
#                https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
#                https://kubernetes.io/docs/home/