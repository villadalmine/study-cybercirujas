#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO 3.1 - Describe AI data center management and monitoring essentials
# Break & fix lab: "The GPU telemetry pipeline is blind"
#
# lab-resources: cpus=1 ram_mb=512
#
# What this lab simulates (no physical GPU required):
#   An 8x H100 node whose GPU telemetry is exposed by NVIDIA DCGM Exporter
#   (the Prometheus exporter built on DCGM, the Data Center GPU Manager).
#   In this VM the exporter is a faithful *simulation*: a small Python service
#   that reads a dcgm-exporter style collectors CSV and serves Prometheus text
#   format on /metrics, with the same metric names (DCGM_FI_*) and labels
#   (gpu, UUID, device, modelName, Hostname) as the real exporter.
#
# Concepts exercised:
#   - DCGM / dcgm-exporter as the GPU health and telemetry source
#     https://developer.nvidia.com/dcgm
#   - The collectors CSV decides which DCGM fields become Prometheus metrics:
#     a field you do not collect is a failure you cannot alert on.
#   - systemd service lifecycle: crash loops, start limits, journal diagnosis.
#   - Monitoring -> action: XID and double-bit ECC errors mean the GPU must be
#     taken out of scheduling (cordoned) before jobs land on it.
#     https://www.nvidia.com/en-us/data-center/base-command/
#     https://kubernetes.io/docs/home/
#
# Modes (runner contract, teach/lab/spec.py):
#   ./break_fix.sh            same as "break"
#   ./break_fix.sh break      install the simulated exporter and break it
#   ./break_fix.sh verify     exit 0 only when the student fixed everything
#   ./break_fix.sh cleanup    remove everything this lab created
# All three modes are idempotent.
# =============================================================================
set -u -o pipefail

LAB_NAME="aiio-3.1-dcgm-telemetry"
UNIT_NAME="aiio-dcgm-exporter.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
OPT_DIR="/opt/aiio-lab"
ETC_DIR="/etc/aiio-lab"
STATE_DIR="/var/lib/aiio-lab"
EXPORTER_BIN="${OPT_DIR}/dcgm-exporter"
COLLECTORS_DIR="${ETC_DIR}/dcgm-exporter"
COLLECTORS_CSV="${COLLECTORS_DIR}/default-counters.csv"
STATE_JSON="${STATE_DIR}/gpu-state.json"
CORDON_FILE="${ETC_DIR}/cordoned-gpus"
EXPECTED_PORT="9400"

log()  { printf '[%s] %s\n' "$LAB_NAME" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$LAB_NAME" "$*" >&2; exit 2; }

# ----------------------------------------------------------------------------
# Privileges: systemd units and /etc need root. Never prompt for a password.
# ----------------------------------------------------------------------------
ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      exec sudo -n -E bash "$0" "$@"
    fi
    die "this lab must run as root (or with passwordless sudo)."
  fi
}

# ----------------------------------------------------------------------------
# Confirmation: skipped when the runner drives us (no terminal, ever).
# ----------------------------------------------------------------------------
confirm_disposable() {
  if [ "${STUDY_LAB:-}" = "1" ] || [ "${LAB_DISPOSABLE:-}" = "yes" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 0
  fi
  printf 'This lab installs and breaks a systemd service on THIS machine.\n'
  printf 'Use it only on a disposable lab VM. Continue? [y/N] '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) log "aborted by user."; exit 1 ;;
  esac
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  log "python3 not found, trying to install it..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q python3 >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --quiet python3 >/dev/null 2>&1 || true
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 is required and could not be installed."
}

ensure_curl_best_effort() {
  command -v curl >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --quiet curl >/dev/null 2>&1 || true
  fi
  return 0
}

ensure_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemd is required for this lab."
  [ -d /run/systemd/system ] || die "systemd is not PID 1 in this VM."
}

# ----------------------------------------------------------------------------
# Simulated dcgm-exporter (same CLI flags, metric names and labels as the
# real one for the subset used here).
# ----------------------------------------------------------------------------
write_exporter() {
  install -d -m 0755 "$OPT_DIR"
  cat > "$EXPORTER_BIN" <<'PY'
#!/usr/bin/env python3
"""Lab simulation of NVIDIA dcgm-exporter (NCA-AIIO 3.1).

Reads a dcgm-exporter style collectors CSV:
    DCGM FIELD, Prometheus metric type, help message
and serves the selected fields for every simulated GPU in Prometheus text
exposition format on /metrics.
"""
import argparse
import json
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser(prog="dcgm-exporter")
parser.add_argument("-f", "--collectors", required=True,
                    help="Path to the collectors CSV file")
parser.add_argument("-a", "--address", default=":9400",
                    help="Address to listen on, e.g. :9400")
parser.add_argument("--state", default="/var/lib/aiio-lab/gpu-state.json",
                    help="Simulated GPU state (lab only)")
args = parser.parse_args()


def fatal(msg, **kv):
    extra = " ".join(f"{k}={v}" for k, v in kv.items())
    print(f'level=fatal msg="{msg}" {extra}'.rstrip(), file=sys.stderr, flush=True)
    sys.exit(1)


collectors = []
try:
    with open(args.collectors, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            parts = [p.strip() for p in s.split(",", 2)]
            if len(parts) != 3 or parts[1] not in ("gauge", "counter"):
                fatal("Invalid collectors line", file=args.collectors, line=lineno)
            collectors.append(tuple(parts))
except FileNotFoundError:
    fatal("Failed to read collectors file: no such file or directory",
          file=args.collectors)

if not collectors:
    fatal("Collectors file selects no fields", file=args.collectors)

try:
    with open(args.state, encoding="utf-8") as fh:
        state = json.load(fh)
except (OSError, ValueError) as exc:
    fatal("Cannot initialize DCGM (simulated state unavailable)", error=repr(str(exc)))

host, _, port = args.address.rpartition(":")
try:
    port = int(port)
except ValueError:
    fatal("Invalid listen address", address=args.address)

hostname = socket.gethostname()
print(f'level=info msg="Collecting DCGM fields" count={len(collectors)} '
      f'file={args.collectors}', file=sys.stderr, flush=True)


def render():
    out = []
    for field, mtype, helptext in collectors:
        samples = []
        for gpu in state["gpus"]:
            value = gpu["metrics"].get(field)
            if value is None:
                continue
            labels = (f'gpu="{gpu["index"]}",UUID="{gpu["uuid"]}",'
                      f'device="nvidia{gpu["index"]}",'
                      f'modelName="{state["model"]}",Hostname="{hostname}",'
                      f'DCGM_FI_DRIVER_VERSION="{state["driver"]}"')
            samples.append(f"{field}{{{labels}}} {value}")
        if samples:
            out.append(f"# HELP {field} {helptext}")
            out.append(f"# TYPE {field} {mtype}")
            out.extend(samples)
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] == "/metrics":
            body = render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
        elif self.path == "/health":
            body = b"OK\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        else:
            body = b"404 page not found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        return


try:
    srv = ThreadingHTTPServer((host, port), Handler)
except OSError as exc:
    fatal("Failed to listen", address=args.address, error=repr(str(exc)))
print(f'level=info msg="Starting webserver" address={args.address}',
      file=sys.stderr, flush=True)
srv.serve_forever()
PY
  chmod 0755 "$EXPORTER_BIN"
}

# ----------------------------------------------------------------------------
# Simulated node: 8x H100. One GPU has an XID 48 (double-bit ECC error).
# One GPU runs hot but is healthy (decoy: temperature alone is not a cordon
# criterion in this lab).
# ----------------------------------------------------------------------------
write_state() {
  install -d -m 0700 "$STATE_DIR"
  cat > "$STATE_JSON" <<'JSON'
{
  "model": "NVIDIA H100 80GB HBM3",
  "driver": "550.90.07",
  "gpus": [
    {"index": 0, "uuid": "GPU-3f1c9a2e-7b4d-4e61-9c0a-1d2e3f4a5b60",
     "metrics": {"DCGM_FI_DEV_GPU_UTIL": 97, "DCGM_FI_DEV_FB_USED": 71230, "DCGM_FI_DEV_FB_FREE": 10273,
                 "DCGM_FI_DEV_GPU_TEMP": 64, "DCGM_FI_DEV_POWER_USAGE": 641.2,
                 "DCGM_FI_DEV_XID_ERRORS": 0, "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": 0}},
    {"index": 1, "uuid": "GPU-8a27d4c1-52e9-4b0f-a613-7c9e0b2d4f11",
     "metrics": {"DCGM_FI_DEV_GPU_UTIL": 96, "DCGM_FI_DEV_FB_USED": 71198, "DCGM_FI_DEV_FB_FREE": 10305,
                 "DCGM_FI_DEV_GPU_TEMP": 66, "DCGM_FI_DEV_POWER_USAGE": 655.8,
                 "DCGM_FI_DEV_XID_ERRORS": 0, "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": 0}},
    {"index": 2, "uuid": "GPU-c5e09b73-1d48-4a2c-8f57-29b6e3a1c0d2",
     "metrics": {"DCGM_FI_DEV_GPU_UTIL": 98, "DCGM_FI_DEV_FB_USED": 71305, "DCGM_FI_DEV_FB_FREE": 10198,
                 "DCGM_FI_DEV_GPU_TEMP": 83, "DCGM_FI_DEV_POWER_USAGE": 699.1,
                 "DCGM_FI_DEV_XID_ERRORS": 0, "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": 0}},
    {"index": 3, "uuid": "GPU-1b9f6e20-a3c7-4d85-b0e4-5f2a8c71d9e3",
     "metrics": {"DCGM_FI_DEV_GPU_UTIL": 95, "DCGM_FI_DEV_FB_USED": 71110, "DCGM_FI_DEV_FB_FREE": 10393,
                 "DCGM_FI_DEV_GPU_TEMP": 63, "DCGM_FI_DEV_POWER_USAGE": 628.4,
                 "DCGM_FI_DEV_XID_ERRORS": 0, "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": 0}},
    {"index": 4, "uuid": "GPU-e4d27a58-9f13-4c6b-87a0-b3c5d1e2f8a4",
     "metrics": {"DCGM_FI_DEV_GPU_UTIL": 97, "DCGM_FI_DEV_FB_USED": 71244, "DCGM_FI_DEV_FB_FREE": 10259,
                 "DCGM_FI_DEV_GPU_TEMP": 65, "DCGM_FI_DEV_POWER_USAGE": 644.7,
                 "DCGM_FI_DEV_XID_ERRORS": 0, "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": 0}},
    {"index": 5, "uuid": "GPU-7d6c13f9-0e2a-4b97-a5d8-4c1f9e3b7a05",
     "metrics": {"DCGM_FI_DEV_GPU_UTIL": 0, "DCGM_FI_DEV_FB_USED": 0, "DCGM_FI_DEV_FB_FREE": 81503,
                 "DCGM_FI_DEV_GPU_TEMP": 38, "DCGM_FI_DEV_POWER_USAGE": 71.3,
                 "DCGM_FI_DEV_XID_ERRORS": 48, "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": 2}},
    {"index": 6, "uuid": "GPU-2a8e5f04-b6d1-4e39-9c72-8d0a4b6e1f26",
     "metrics": {"DCGM_FI_DEV_GPU_UTIL": 96, "DCGM_FI_DEV_FB_USED": 71187, "DCGM_FI_DEV_FB_FREE": 10316,
                 "DCGM_FI_DEV_GPU_TEMP": 67, "DCGM_FI_DEV_POWER_USAGE": 659.0,
                 "DCGM_FI_DEV_XID_ERRORS": 0, "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": 0}},
    {"index": 7, "uuid": "GPU-9f0b4c67-3e85-4a1d-b2f9-6e7c0d5a3b47",
     "metrics": {"DCGM_FI_DEV_GPU_UTIL": 97, "DCGM_FI_DEV_FB_USED": 71266, "DCGM_FI_DEV_FB_FREE": 10237,
                 "DCGM_FI_DEV_GPU_TEMP": 64, "DCGM_FI_DEV_POWER_USAGE": 647.5,
                 "DCGM_FI_DEV_XID_ERRORS": 0, "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": 0}}
  ]
}
JSON
  chmod 0600 "$STATE_JSON"
}

# ----------------------------------------------------------------------------
# BREAK #1: the error/health fields are commented out of the collectors CSV.
# ----------------------------------------------------------------------------
write_broken_collectors() {
  install -d -m 0755 "$COLLECTORS_DIR"
  cat > "$COLLECTORS_CSV" <<'CSV'
# Format
# If line starts with a '#' it is considered a comment
# DCGM FIELD, Prometheus metric type, help message

# Clocks and utilization
DCGM_FI_DEV_GPU_UTIL,          gauge,   GPU utilization (in %).

# Memory usage
DCGM_FI_DEV_FB_USED,           gauge,   Framebuffer memory used (in MiB).
DCGM_FI_DEV_FB_FREE,           gauge,   Framebuffer memory free (in MiB).

# Temperature and power
DCGM_FI_DEV_GPU_TEMP,          gauge,   GPU temperature (in C).
DCGM_FI_DEV_POWER_USAGE,       gauge,   Power draw (in W).

# Errors and violations
# (disabled during a "reduce cardinality" change, ticket OPS-4411)
# DCGM_FI_DEV_XID_ERRORS,        gauge,   Value of the last XID error encountered.
# DCGM_FI_DEV_ECC_DBE_VOL_TOTAL, counter, Total number of double-bit volatile ECC errors.
CSV
  chmod 0644 "$COLLECTORS_CSV"
}

# ----------------------------------------------------------------------------
# BREAK #2 and #3: wrong collectors path (typo) and wrong listen port.
# ----------------------------------------------------------------------------
write_broken_unit() {
  cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=NVIDIA DCGM Exporter (lab simulation, NCA-AIIO 3.1)
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${EXPORTER_BIN} --address=:9401 -f ${COLLECTORS_DIR}/default-counter.csv
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$UNIT_PATH"
}

write_cordon_template() {
  cat > "$CORDON_FILE" <<'TXT'
# GPUs taken out of scheduling on this node.
# One GPU UUID per line (as reported by the UUID label of dcgm-exporter).
# Lines starting with '#' are ignored.
TXT
  chmod 0644 "$CORDON_FILE"
}

print_briefing() {
  cat <<EOF

==============================================================================
 NCA-AIIO 3.1 | Break & fix: "The GPU telemetry pipeline is blind"
==============================================================================
 Situation
   This node (8x NVIDIA H100) belongs to an AI training cluster. Prometheus
   scrapes GPU telemetry from dcgm-exporter at http://<node>:${EXPECTED_PORT}/metrics.
   Since this morning the GPU dashboards for this node are empty, and the
   scheduler keeps placing training jobs on it that fail after a few minutes.

 Symptoms you will see
   - systemctl status ${UNIT_NAME}   -> failed / restart loop
   - curl -s localhost:${EXPECTED_PORT}/metrics      -> connection refused
   - Even after the service runs, alerting on GPU faults is impossible:
     some health fields are not being exported.

 Your goals (verify checks all of them)
   1. ${UNIT_NAME} is active and enabled (survives a reboot).
   2. It serves Prometheus metrics on port ${EXPECTED_PORT}.
   3. The metrics include, for all 8 GPUs:
        DCGM_FI_DEV_GPU_UTIL, DCGM_FI_DEV_GPU_TEMP,
        DCGM_FI_DEV_XID_ERRORS, DCGM_FI_DEV_ECC_DBE_VOL_TOTAL
   4. Using ONLY the telemetry, find the GPU(s) with hardware faults
      (non-zero XID or double-bit ECC errors) and cordon them by writing
      their UUID(s) into ${CORDON_FILE}. Do not cordon healthy GPUs.

 Useful files and tools
   ${UNIT_PATH}
   ${COLLECTORS_DIR}/
   ${EXPORTER_BIN} --help
   systemctl, journalctl -u ${UNIT_NAME}, curl, grep, ss -ltnp

 When done:   $0 verify
 To reset:    $0 cleanup
==============================================================================
EOF
}

do_break() {
  ensure_root "$@"
  confirm_disposable
  ensure_systemd
  ensure_python
  ensure_curl_best_effort

  # Reset to a known state so "break" is idempotent.
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -rf "/etc/systemd/system/${UNIT_NAME}.d"

  install -d -m 0755 "$ETC_DIR"
  write_exporter
  write_state
  write_broken_collectors
  write_broken_unit
  write_cordon_template

  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
  systemctl start "$UNIT_NAME" >/dev/null 2>&1 || true
  # Let the restart loop hit the start limit so the symptom is visible.
  sleep 8

  log "lab is broken and ready."
  print_briefing
}

do_verify() {
  ensure_root "$@"
  local fail=0

  if [ ! -f "$UNIT_PATH" ] || [ ! -f "$STATE_JSON" ]; then
    log "FAIL: the lab is not set up. Run: $0 break"
    exit 1
  fi

  if systemctl is-active --quiet "$UNIT_NAME"; then
    log "OK:   ${UNIT_NAME} is active"
  else
    log "FAIL: ${UNIT_NAME} is not active (systemctl status / journalctl -u)"
    fail=1
  fi

  if systemctl is-enabled --quiet "$UNIT_NAME"; then
    log "OK:   ${UNIT_NAME} is enabled"
  else
    log "FAIL: ${UNIT_NAME} is not enabled; it would not survive a reboot"
    fail=1
  fi

  command -v python3 >/dev/null 2>&1 || { log "FAIL: python3 missing"; exit 1; }

  if ! python3 -I - "$EXPECTED_PORT" "$STATE_JSON" "$CORDON_FILE" <<'PY'
import json
import re
import sys
import urllib.request

port, state_path, cordon_path = sys.argv[1], sys.argv[2], sys.argv[3]
required = ["DCGM_FI_DEV_GPU_UTIL", "DCGM_FI_DEV_GPU_TEMP",
            "DCGM_FI_DEV_XID_ERRORS", "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL"]
ok = True


def say(status, msg):
    print(f"[aiio-3.1-dcgm-telemetry] {status} {msg}")


with open(state_path, encoding="utf-8") as fh:
    state = json.load(fh)
all_uuids = {g["uuid"] for g in state["gpus"]}
faulty = {g["uuid"] for g in state["gpus"]
          if g["metrics"].get("DCGM_FI_DEV_XID_ERRORS", 0) != 0
          or g["metrics"].get("DCGM_FI_DEV_ECC_DBE_VOL_TOTAL", 0) != 0}

try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5) as r:
        body = r.read().decode()
    say("OK:  ", f"metrics endpoint answers on port {port}")
except Exception as exc:
    say("FAIL:", f"no metrics on port {port}: {exc}")
    body = ""
    ok = False

if body:
    sample = re.compile(r'^(\w+)\{[^}]*UUID="([^"]+)"[^}]*\}\s+\S+$')
    seen = {}
    for line in body.splitlines():
        m = sample.match(line)
        if m:
            seen.setdefault(m.group(1), set()).add(m.group(2))
    for name in required:
        got = seen.get(name, set())
        if got >= all_uuids:
            say("OK:  ", f"{name} exported for all {len(all_uuids)} GPUs")
        else:
            say("FAIL:", f"{name} exported for {len(got & all_uuids)}/{len(all_uuids)} GPUs")
            ok = False

try:
    with open(cordon_path, encoding="utf-8") as fh:
        cordoned = {l.strip() for l in fh
                    if l.strip() and not l.strip().startswith("#")}
except OSError:
    cordoned = set()

missing = faulty - cordoned
wrong = cordoned - faulty
if not missing and not wrong:
    say("OK:  ", f"exactly the faulty GPU(s) are cordoned ({len(faulty)})")
else:
    if missing:
        say("FAIL:", f"{len(missing)} faulty GPU(s) still schedulable; check the error metrics")
    if wrong & all_uuids:
        say("FAIL:", f"{len(wrong & all_uuids)} healthy GPU(s) cordoned; that wastes capacity")
    if wrong - all_uuids:
        say("FAIL:", "cordon file contains entries that are not GPU UUIDs of this node")
    ok = False

sys.exit(0 if ok else 1)
PY
  then
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    log "SUCCESS: telemetry restored and the faulty GPU is out of scheduling."
    exit 0
  fi
  log "Not fixed yet."
  exit 1
}

do_cleanup() {
  ensure_root "$@"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_PATH"
  rm -rf "/etc/systemd/system/${UNIT_NAME}.d"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$OPT_DIR" "$ETC_DIR" "$STATE_DIR"
  log "cleanup done: service, unit, files and state removed."
}

case "${1:-break}" in
  break)   do_break "$@" ;;
  verify)  do_verify "$@" ;;
  cleanup) do_cleanup "$@" ;;
  *)
    echo "usage: $0 [break|verify|cleanup]" >&2
    exit 2
    ;;
esac

# =============================================================================
# SOLUTION (step by step). Try on your own first!
# =============================================================================
#
# 1) Look at the service. It is failed, hit its start limit:
#      systemctl status aiio-dcgm-exporter.service
#      journalctl -u aiio-dcgm-exporter.service -n 20 --no-pager
#    The journal shows:
#      level=fatal msg="Failed to read collectors file: no such file or directory"
#        file=/etc/aiio-lab/dcgm-exporter/default-counter.csv
#    The file on disk is default-counters.csv (with an "s"):
#      ls /etc/aiio-lab/dcgm-exporter/
#
# 2) Fix the unit. Two problems on the ExecStart line: the collectors path
#    typo and the port (Prometheus scrapes :9400, the dcgm-exporter default,
#    the unit says :9401):
#      sudo sed -i \
#        -e 's#default-counter\.csv#default-counters.csv#' \
#        -e 's#--address=:9401#--address=:9400#' \
#        /etc/systemd/system/aiio-dcgm-exporter.service
#    (Or "systemctl edit --full aiio-dcgm-exporter.service".)
#
# 3) Reload systemd, clear the start-limit state, start and keep enabled:
#      sudo systemctl daemon-reload
#      sudo systemctl reset-failed aiio-dcgm-exporter.service
#      sudo systemctl enable --now aiio-dcgm-exporter.service
#      ss -ltnp | grep 9400
#      curl -s localhost:9400/metrics | grep '^# HELP'
#    Only UTIL, FB_USED, FB_FREE, GPU_TEMP and POWER_USAGE appear: no error
#    fields. The dashboard works but GPU faults are invisible.
#
# 4) Re-enable the health fields in the collectors CSV. dcgm-exporter only
#    exports the DCGM fields listed there; uncomment both lines:
#      sudo sed -i \
#        -e 's/^# DCGM_FI_DEV_XID_ERRORS/DCGM_FI_DEV_XID_ERRORS/' \
#        -e 's/^# DCGM_FI_DEV_ECC_DBE_VOL_TOTAL/DCGM_FI_DEV_ECC_DBE_VOL_TOTAL/' \
#        /etc/aiio-lab/dcgm-exporter/default-counters.csv
#      sudo systemctl restart aiio-dcgm-exporter.service
#    (The collectors file is read at startup, so a restart is required.)
#
# 5) Diagnose using the telemetry only:
#      curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(XID_ERRORS|ECC_DBE_VOL_TOTAL)' \
#        | grep -v ' 0$'
#    gpu="5" reports DCGM_FI_DEV_XID_ERRORS 48 (XID 48 = double-bit ECC error)
#    and DCGM_FI_DEV_ECC_DBE_VOL_TOTAL 2; its utilization is 0 because jobs
#    die on it. gpu="2" is hot (83 C) but has no errors: it is a cooling
#    follow-up, not a cordon.
#
# 6) Cordon the faulty GPU by UUID (UUIDs are stable; indexes can change
#    after a reboot or a PCIe re-enumeration):
#      UUID=$(curl -s localhost:9400/metrics \
#        | grep '^DCGM_FI_DEV_XID_ERRORS' | grep -v ' 0$' \
#        | sed -E 's/.*UUID="([^"]+)".*/\1/')
#      echo "$UUID" | sudo tee -a /etc/aiio-lab/cordoned-gpus
#    Expected: GPU-7d6c13f9-0e2a-4b97-a5d8-4c1f9e3b7a05
#
# 7) Verify:
#      sudo ./break_fix.sh verify
#
# Production mapping:
#   - Real dcgm-exporter runs as a DaemonSet (GPU Operator) and reads
#     /etc/dcgm-exporter/default-counters.csv or a ConfigMap; the same
#     "field not in the CSV = no metric = no alert" rule applies.
#   - Alert on DCGM_FI_DEV_XID_ERRORS != 0 and on increases of
#     DCGM_FI_DEV_ECC_DBE_VOL_TOTAL; a DBE usually requires a GPU reset and,
#     if it repeats, an RMA. Run "dcgmi diag -r 3" before returning the GPU.
#   - In Kubernetes the equivalent of the cordon file is draining/cordoning
#     the node (kubectl cordon / drain) or letting the GPU Operator's health
#     checks mark the device unhealthy so the device plugin stops
#     advertising it; in Slurm, "scontrol update nodename=... state=drain".
#   - Out-of-band (BMC/Redfish) monitoring covers what DCGM cannot see when
#     the host OS is down: https://docs.nvidia.com/igx-orin/bmc/latest/introduction.html
# =============================================================================