#!/usr/bin/env bash
# =============================================================================
#  gcp-cdl — Topic 1.1: Explain why and how the cloud is revolutionizing
#  businesses
#  Cloud Digital Leader — exam version 2026-08-12 — objective weight 9.0
#
#  BREAK & FIX LAB — "The night capacity planning lost"
#
#  WHY A CONCEPTUAL OBJECTIVE GETS A HANDS-ON LAB
#  ----------------------------------------------
#  1.1 is examined with business vocabulary — capex vs opex, elasticity, TCO,
#  time to market, managed services — but that vocabulary describes a physical
#  fact: on premises, capacity is a decision made months in advance and frozen
#  into hardware. This lab reproduces that fact on one disposable VM. You get a
#  "datacenter" whose block storage was sized in a purchase order and whose CPU
#  allocation was fixed by the blade you were given. Then Black Friday arrives.
#  What you have to do to survive is exactly what a cloud provider turns into an
#  API call, and that difference — not the words — is the objective.
#
#  WHAT THIS SCRIPT TOUCHES (disposable lab VM only)
#    - creates  /var/tmp/gcp-cdl-lab-1.1/            (app, disk image, mountpoint)
#    - mounts   a 48 MiB ext4 loop device on that mountpoint
#    - installs /etc/systemd/system/lab-orders-api@.service  (+ a drop-in)
#    - listens  on 127.0.0.1:8080 (and 8081/8082 if you scale out)
#  It changes nothing else. `cleanup` reverses all of it.
#
#  USAGE
#    sudo bash "$0"            # build the lab and break it (default)
#    sudo bash "$0" verify     # grade your fix — this is the exit criteria
#    sudo bash "$0" cleanup    # remove every artifact
#
#  SOURCES
#    - Cloud Digital Leader exam guide
#      https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#    - Resize a persistent disk (online, no downtime)
#      https://cloud.google.com/compute/docs/disks/resize-persistent-disk
#    - Change the machine type of an instance
#      https://cloud.google.com/compute/docs/instances/changing-machine-type-of-stopped-instance
#    - Autoscaling groups of instances
#      https://cloud.google.com/compute/docs/autoscaler
#    - Cloud Load Balancing overview
#      https://cloud.google.com/load-balancing/docs/load-balancing-overview
#    - Google Cloud Architecture Framework — Cost optimization
#      https://cloud.google.com/architecture/framework/cost-optimization
# =============================================================================

set -euo pipefail

LAB_ROOT="/var/tmp/gcp-cdl-lab-1.1"
APP_DIR="$LAB_ROOT/app"
IMG="$LAB_ROOT/ledger-lun.img"
MNT="$LAB_ROOT/mnt"
LOG_DIR="$MNT/logs"
LOG_PATH="$LOG_DIR/orders.log"
UNIT="/etc/systemd/system/lab-orders-api@.service"
DROPIN_DIR="/etc/systemd/system/lab-orders-api@8080.service.d"
PORT=8080
BASE_URL="http://127.0.0.1:$PORT"

# Exit criteria, in one place. These are outcome-based on purpose: the lab does
# not care HOW you restore service, only that the business transaction works.
REQUIRED_FREE_MIB=200      # more than the 48 MiB LUN holds -> deleting files cannot pass
LOAD_TOTAL=40              # transactions in the burst
LOAD_CONCURRENCY=8         # simultaneous customers
LOAD_BUDGET_S=12           # wall-clock SLO for the whole burst

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$c_bld" "$*" "$c_off"; }
ok()   { printf '  %sPASS%s  %s\n' "$c_grn" "$c_off" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$c_red" "$c_off" "$*"; }
warn() { printf '  %s!%s     %s\n' "$c_yel" "$c_off" "$*"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || { say "This lab manages systemd units and loop devices: run it with sudo."; exit 1; }
}

preflight() {
  local missing=()
  for bin in systemctl python3 curl losetup mkfs.ext4 resize2fs truncate df xargs; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    say "Missing required tools: ${missing[*]}"
    say "Install e2fsprogs / util-linux / python3 / curl and re-run."
    exit 1
  fi
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$PORT|\*:$PORT|:::$PORT"; then
    if ! systemctl is-active --quiet "lab-orders-api@$PORT.service"; then
      say "Port $PORT is already in use by something that is not this lab. Free it first."
      exit 1
    fi
  fi
}

confirm() {
  if [ "${LAB_I_UNDERSTAND:-0}" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then
    say "Non-interactive run: set LAB_I_UNDERSTAND=1 to confirm this is a disposable VM."
    exit 1
  fi
  say "This creates systemd units, mounts a loop device and fills it to 100%."
  say "Run it ONLY on a throwaway lab VM."
  read -r -p "Type 'lab' to continue: " answer
  [ "$answer" = "lab" ] || { say "Aborted."; exit 1; }
}

# --- the "datacenter" ---------------------------------------------------------

write_app() {
  mkdir -p "$APP_DIR"
  cat > "$APP_DIR/orders_api.py" <<'PY'
#!/usr/bin/env python3
"""orders-api - simulation of a fixed-capacity on-premises monolith.

/healthz  liveness only. Touches no storage, does no work. Always cheap.
/orders   the business transaction. Costs CPU, and must durably append an
          8 KiB order document to the ledger volume before it may answer 200.

The split is deliberate: a probe that only proves the process is alive will
stay green through a total loss of revenue.
"""
import hashlib
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
LOG_PATH = os.environ.get("ORDERS_LOG", "/tmp/orders.log")
NODE = os.environ.get("ORDERS_NODE", "node-unknown")
ITERS = int(os.environ.get("ORDERS_WORK_ITERS", "250000"))
PADDING = "x" * 8192  # an order document is not 80 bytes


def settle(order_id):
    """Bounded CPU-only settlement cost: scales with the CPU you were given."""
    digest = hashlib.pbkdf2_hmac("sha256", order_id.encode(), b"orders-lab", ITERS)
    return digest.hex()[:16]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "orders-api/1.0"

    def _reply(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Served-By", NODE)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._reply(200, "ok node=%s\n" % NODE)
            return
        if path != "/orders":
            self._reply(404, "not found\n")
            return

        order_id = "%d" % (time.time_ns() % 1000000)
        receipt = settle(order_id)
        record = "%.3f node=%s order=%s receipt=%s payload=%s\n" % (
            time.time(), NODE, order_id, receipt, PADDING)
        try:
            with open(LOG_PATH, "a") as fh:
                fh.write(record)
                fh.flush()
                os.fsync(fh.fileno())
        except OSError as exc:
            self._reply(500, "order %s NOT settled: ledger write failed: %s\n" % (order_id, exc))
            return
        self._reply(200, "order %s settled node=%s receipt=%s\n" % (order_id, NODE, receipt))

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (NODE, fmt % args))


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY
  chmod 0644 "$APP_DIR/orders_api.py"
}

calibrate_work() {
  # Pin one transaction at roughly 60 ms of CPU on THIS machine, so the lab
  # behaves the same on a laptop and on a c4-standard-8.
  python3 - <<'PY'
import hashlib, time
n = 50000
t0 = time.perf_counter()
hashlib.pbkdf2_hmac("sha256", b"calibrate", b"orders-lab", n)
dt = max(time.perf_counter() - t0, 1e-6)
print(max(20000, int(n * (0.060 / dt))))
PY
}

provision_storage() {
  mkdir -p "$MNT"
  if ! mountpoint -q "$MNT"; then
    truncate -s 48M "$IMG"
    # -m 0: no root-reserved blocks, so "full" means full for everyone.
    mkfs.ext4 -q -F -m 0 -L LEDGER-LUN "$IMG"
    mount -o loop "$IMG" "$MNT"
  fi
  mkdir -p "$LOG_DIR"
}

install_unit() {
  local iters="$1"
  cat > "$UNIT" <<EOF
[Unit]
Description=orders-api (port %i) - fixed-capacity on-prem monolith [gcp-cdl 1.1 lab]
After=network.target

[Service]
Type=simple
Environment=ORDERS_LOG=$LOG_PATH
Environment=ORDERS_NODE=node-%i
Environment=ORDERS_WORK_ITERS=$iters
ExecStart=/usr/bin/env python3 $APP_DIR/orders_api.py %i
Restart=no

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

wait_for_http() {
  local url="$1" tries="${2:-40}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS --max-time 3 -o /dev/null "$url" 2>/dev/null; then return 0; fi
    sleep 0.25
  done
  return 1
}

build_lab() {
  head1 "[1/3] Racking the on-prem stack"
  write_app
  provision_storage
  local iters; iters="$(calibrate_work)"
  install_unit "$iters"
  rm -rf "$DROPIN_DIR"
  systemctl daemon-reload
  systemctl restart "lab-orders-api@$PORT.service"
  if ! wait_for_http "$BASE_URL/healthz"; then
    bad "orders-api did not come up. journalctl -u lab-orders-api@$PORT -n 40"
    exit 1
  fi
  say "  ledger LUN : 48 MiB ext4 on $MNT (loop)"
  say "  settlement : $iters PBKDF2 iterations (~60 ms of CPU per order)"
  local baseline; baseline="$(curl -s --max-time 10 "$BASE_URL/orders" || true)"
  say "  baseline   : ${baseline%$'\n'}"
  ok "Service healthy before the incident."
}

break_it() {
  head1 "[2/3] Applying the capacity decisions made 14 months ago"

  # BREAK #1 - capex storage. The LUN was sized from last year's order volume.
  # Nightly dumps were never rotated. There is no more room on the array, and
  # the next shelf is a purchase order away.
  dd if=/dev/zero of="$MNT/legacy_nightly_dump.bin" bs=1M status=none 2>/dev/null || true
  sync

  # BREAK #2 - capex compute. This workload was assigned a fraction of a shared
  # blade. Growing it means a maintenance window and a hardware request.
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN_DIR/10-capex-allocation.conf" <<'EOF'
# Fixed hardware allocation from the 2025 capacity plan. Not elastic.
[Service]
CPUQuota=10%
MemoryMax=128M
TasksMax=48
EOF
  systemctl daemon-reload
  systemctl restart "lab-orders-api@$PORT.service"
  wait_for_http "$BASE_URL/healthz" || true
  ok "Incident armed."
}

brief() {
  local free_mib total_mib
  total_mib="$(df -BM --output=size "$MNT" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"
  free_mib="$(df -BM --output=avail "$MNT" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"

  head1 "[3/3] YOUR SHIFT STARTS NOW"
  cat <<EOF

  It is 20:40 on the biggest sales day of the year. You own an order-settlement
  service running on hardware someone else sized in 2025. Marketing did not tell
  you about the campaign.

  THE SYMPTOM YOU WILL SEE
  ------------------------
  1) Every purchase fails, and the failure blames storage:

       curl -s $BASE_URL/orders
       -> HTTP 500 "order NOT settled: ledger write failed: [Errno 28] No space
          left on device"

     The ledger volume is ${free_mib} MiB free of ${total_mib} MiB. Total capacity is
     what was bought; it is not a slider.

  2) Monitoring is green. This is the part that ends careers:

       curl -s $BASE_URL/healthz     -> HTTP 200 ok

     The liveness probe never writes to storage, so it reports a perfectly
     healthy service while revenue is zero. Availability of a process is not
     availability of a business transaction.

  3) Even ignoring storage, the box cannot absorb the burst. Settlement costs
     ~60 ms of CPU and the service is capped at CPUQuota=10% of one core, so
     transactions serialize into a queue that never drains:

       systemctl show lab-orders-api@$PORT -p CPUQuota,MemoryMax,TasksMax
       systemd-cgtop -1 -n 2 | grep lab-orders

  WHAT YOU MUST ACHIEVE (graded, outcome-based)
  ---------------------------------------------
    [1] $BASE_URL/healthz still answers 200.
    [2] 20 consecutive GET /orders all return 200 — the ledger write succeeds.
    [3] The ledger volume has at least ${REQUIRED_FREE_MIB} MiB free.
        Note the number: the LUN is 48 MiB. Deleting files CANNOT satisfy this.
        You have to grow capacity while the service stays up.
    [4] A burst of $LOAD_TOTAL orders at $LOAD_CONCURRENCY concurrent customers finishes with
        zero failures in under ${LOAD_BUDGET_S}s.

  HOW is your call: more capacity on this node, or more nodes behind a front
  door on :$PORT. A template unit is already installed for the second path —
  'systemctl start lab-orders-api@8081' gives you another instance. What the
  lab measures is the customer's experience on :$PORT.

  Grade yourself:   sudo bash $0 verify
  Tear it all down: sudo bash $0 cleanup

  Keep a stopwatch on how long your fix takes, and how long each step WOULD
  take if the capacity had to be bought, shipped, racked and cabled. That delta
  is the whole of objective 1.1.

EOF
}

# --- grading ------------------------------------------------------------------

verify() {
  local failures=0
  head1 "GRADING — objective 1.1 break & fix"

  # [1] liveness
  local hcode
  hcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/healthz" || echo 000)"
  if [ "$hcode" = "200" ]; then ok "[1] /healthz answers 200"
  else bad "[1] /healthz returned $hcode — nothing is listening on :$PORT"; failures=$((failures+1)); fi

  # [2] the business transaction
  local seq_fail=0 code
  for _ in $(seq 1 20); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL/orders" || echo 000)"
    [ "$code" = "200" ] || seq_fail=$((seq_fail+1))
  done
  if [ "$seq_fail" -eq 0 ]; then ok "[2] 20/20 sequential orders settled"
  else bad "[2] $seq_fail of 20 orders failed — the ledger write is still broken"; failures=$((failures+1)); fi

  # [3] elastic capacity
  local free_mib=0
  if mountpoint -q "$MNT"; then
    free_mib="$(df -BM --output=avail "$MNT" | tail -n1 | tr -dc '0-9')"
  fi
  if [ "${free_mib:-0}" -ge "$REQUIRED_FREE_MIB" ]; then
    ok "[3] ledger volume has ${free_mib} MiB free (>= ${REQUIRED_FREE_MIB} MiB)"
  else
    bad "[3] ledger volume has ${free_mib} MiB free, needs ${REQUIRED_FREE_MIB} MiB — the volume must GROW"
    failures=$((failures+1))
  fi

  # [4] the burst
  local tmp; tmp="$(mktemp -d)"
  local start end elapsed bad_codes
  start="$(date +%s)"
  seq 1 "$LOAD_TOTAL" | xargs -P "$LOAD_CONCURRENCY" -I{} \
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 "$BASE_URL/orders?id={}" \
    > "$tmp/codes" 2>/dev/null || true
  end="$(date +%s)"
  elapsed=$((end - start))
  bad_codes="$(grep -cv '^200$' "$tmp/codes" 2>/dev/null || true)"
  bad_codes="${bad_codes:-0}"
  rm -rf "$tmp"
  if [ "$bad_codes" -eq 0 ] && [ "$elapsed" -le "$LOAD_BUDGET_S" ]; then
    ok "[4] burst: $LOAD_TOTAL orders, $LOAD_CONCURRENCY concurrent, 0 failures, ${elapsed}s (budget ${LOAD_BUDGET_S}s)"
  else
    bad "[4] burst: $bad_codes failures, ${elapsed}s (budget ${LOAD_BUDGET_S}s) — capacity is still fixed"
    failures=$((failures+1))
  fi

  echo
  if [ "$failures" -eq 0 ]; then
    printf '%sLAB PASSED%s — service restored under load.\n' "$c_grn$c_bld" "$c_off"
    say "Now write down the elapsed time of your fix, and the answer to the exam"
    say "question hiding inside it: which of those steps needed a human to touch"
    say "hardware, and what does a cloud provider charge you for removing that step?"
    return 0
  fi
  printf '%s%d check(s) still failing.%s Keep going — the commented solution is at the\n' "$c_red$c_bld" "$failures" "$c_off"
  say "bottom of this script, but read it only after you have tried."
  return 1
}

cleanup() {
  head1 "Removing the lab"
  local unit
  for unit in $(systemctl list-units --all --plain --no-legend 'lab-orders-api@*' 2>/dev/null | awk '{print $1}'); do
    systemctl stop "$unit" >/dev/null 2>&1 || true
  done
  systemctl disable "lab-orders-api@$PORT.service" >/dev/null 2>&1 || true
  rm -rf "$DROPIN_DIR" "$UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if mountpoint -q "$MNT"; then umount "$MNT" || umount -l "$MNT" || true; fi
  local dev
  dev="$(losetup -j "$IMG" 2>/dev/null | cut -d: -f1 | head -n1 || true)"
  [ -n "$dev" ] && losetup -d "$dev" 2>/dev/null || true
  rm -rf "$LAB_ROOT"
  ok "Lab artifacts removed."
  warn "Anything YOU added during the fix (an nginx/haproxy config, extra units)"
  warn "is still there on purpose — review and remove it yourself."
}

usage() {
  cat <<EOF
gcp-cdl 1.1 break & fix lab

  sudo bash $0 [break|verify|cleanup|help]

  break    (default) build the lab, break it, print the incident brief
  verify   grade your fix against the four exit criteria
  cleanup  unmount, remove units and delete $LAB_ROOT
EOF
}

main() {
  case "${1:-break}" in
    break)   require_root; preflight; confirm; build_lab; break_it; brief ;;
    verify)  require_root; verify ;;
    cleanup) require_root; cleanup ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

# =============================================================================
#  SOLUTION — do not read until you have tried. Every step ends with the one
#  cloud command that replaces it, because that mapping IS objective 1.1.
# =============================================================================
#
#  STEP 0 — Diagnose before touching anything (2 min)
#  --------------------------------------------------
#    curl -s -i http://127.0.0.1:8080/orders | head -n 20
#    curl -s    http://127.0.0.1:8080/healthz
#    df -h /var/tmp/gcp-cdl-lab-1.1/mnt
#    du -h --max-depth=1 /var/tmp/gcp-cdl-lab-1.1/mnt
#    journalctl -u lab-orders-api@8080 -n 50 --no-pager
#    systemctl show lab-orders-api@8080 -p CPUQuota,CPUQuotaPerSecUSec,MemoryMax,TasksMax
#    systemd-cgtop -1 -n 2 | grep lab-orders
#
#  Read: two independent constraints. Storage is at 100% (Errno 28), and CPU is
#  clamped at 10% of one core. Fixing only one leaves the burst failing. Also
#  note that /healthz stayed 200 the entire time — your first post-incident
#  action item is a probe that exercises the ledger write.
#
#  STEP 1 — Reclaim the obvious waste (the on-prem reflex)
#  -------------------------------------------------------
#    ls -lh /var/tmp/gcp-cdl-lab-1.1/mnt
#    rm -f  /var/tmp/gcp-cdl-lab-1.1/mnt/legacy_nightly_dump.bin
#    sync; df -h /var/tmp/gcp-cdl-lab-1.1/mnt
#    curl -s http://127.0.0.1:8080/orders          # 200 again — orders flow
#
#  Orders settle again, and check [3] still fails: 48 MiB of volume cannot show
#  200 MiB free. This is the honest lesson. Deleting files buys hours, not
#  headroom; the ceiling is the purchase order. On premises the next move is a
#  capacity request with a lead time measured in weeks.
#
#  STEP 2 — Grow the volume WITHOUT downtime (elastic block storage)
#  -----------------------------------------------------------------
#    IMG=/var/tmp/gcp-cdl-lab-1.1/ledger-lun.img
#    MNT=/var/tmp/gcp-cdl-lab-1.1/mnt
#    LOOP=$(losetup -j "$IMG" | cut -d: -f1)
#
#    truncate -s 512M "$IMG"      # the array grows                (provider side)
#    losetup -c "$LOOP"           # the block device re-reads size (guest side)
#    resize2fs "$LOOP"            # the filesystem takes the space (guest side)
#
#    df -h "$MNT"                 # ~470 MiB free, service never stopped
#
#  Note that traffic kept flowing: ext4 online resize needs no unmount. That is
#  the point. Three commands, seconds, zero downtime.
#
#    On Google Cloud the first command is the whole first half:
#      gcloud compute disks resize ledger-lun --size=500GB --zone=us-central1-a
#      # then, inside the guest: sudo resize2fs /dev/sdb
#    Persistent Disk grows online, is billed per provisioned GiB-month, and
#    never required anyone to open a rack.
#      https://cloud.google.com/compute/docs/disks/resize-persistent-disk
#
#  STEP 3 — Fix compute. Pick vertical, horizontal, or both.
#  ----------------------------------------------------------
#  3a) VERTICAL — resize the machine (fastest, still one failure domain):
#
#        systemctl edit lab-orders-api@8080
#        # in the drop-in editor:
#        #   [Service]
#        #   CPUQuota=400%
#        #   MemoryMax=512M
#        systemctl restart lab-orders-api@8080
#
#      or edit /etc/systemd/system/lab-orders-api@8080.service.d/10-capex-allocation.conf
#      directly, then: systemctl daemon-reload && systemctl restart lab-orders-api@8080
#
#      Cloud equivalent — a stop, one flag, a start; no hardware, no window:
#        gcloud compute instances stop orders-vm --zone=us-central1-a
#        gcloud compute instances set-machine-type orders-vm \
#          --machine-type=c4-standard-8 --zone=us-central1-a
#        gcloud compute instances start orders-vm --zone=us-central1-a
#        https://cloud.google.com/compute/docs/instances/changing-machine-type-of-stopped-instance
#
#  3b) HORIZONTAL — more instances behind one front door (the cloud answer):
#
#        # move the app off the customer-facing port, then add nodes
#        systemctl stop lab-orders-api@8080
#        systemctl start lab-orders-api@8081
#        systemctl start lab-orders-api@8082
#        curl -s -D- http://127.0.0.1:8081/orders | grep X-Served-By   # node-8081
#
#        # put a load balancer on :8080 (nginx shown; haproxy works the same)
#        cat >/etc/nginx/conf.d/orders-lab.conf <<'NGINX'
#        upstream orders_backends {
#            server 127.0.0.1:8081;
#            server 127.0.0.1:8082;
#        }
#        server {
#            listen 127.0.0.1:8080;
#            location / {
#                proxy_pass http://orders_backends;
#                proxy_next_upstream error timeout http_500;
#            }
#        }
#        NGINX
#        nginx -t && systemctl reload nginx
#
#      If nginx/haproxy is not installed on your lab VM, take path 3a — the
#      grader only measures the customer's experience on :8080.
#
#      Cloud equivalent — capacity that follows demand instead of forecasts:
#        gcloud compute instance-templates create orders-tmpl \
#          --machine-type=c4-standard-4 --image-family=debian-12 \
#          --image-project=debian-cloud
#        gcloud compute instance-groups managed create orders-mig \
#          --template=orders-tmpl --size=2 --zone=us-central1-a
#        gcloud compute instance-groups managed set-autoscaling orders-mig \
#          --max-num-replicas=20 --min-num-replicas=2 --target-cpu-utilization=0.6 \
#          --cool-down-period=90 --zone=us-central1-a
#        # + a global external Application Load Balancer in front of the MIG
#        https://cloud.google.com/compute/docs/autoscaler
#        https://cloud.google.com/load-balancing/docs/load-balancing-overview
#
#      The autoscaler is the sentence "the cloud is revolutionizing businesses"
#      written as a command: the burst adds nodes at 20:40 and removes them at
#      02:00, and you pay for the second-level consumption, not the peak.
#
#  STEP 4 — Prove it
#  ------------------
#    sudo bash THIS_SCRIPT verify
#    # expect: [1] PASS  [2] PASS  [3] PASS  [4] PASS
#
#  If [4] still fails, your CPU allocation is still the bottleneck: check
#  `systemctl show lab-orders-api@<port> -p CPUQuota` on the units that are
#  actually serving, and confirm the load balancer is spreading traffic
#  (`grep X-Served-By` across several requests).
#
#  STEP 5 — Clean up
#  ------------------
#    sudo bash THIS_SCRIPT cleanup
#    rm -f /etc/nginx/conf.d/orders-lab.conf && systemctl reload nginx   # if used
#
#  WHAT YOU JUST PROVED (this is what the exam asks in words)
#  -----------------------------------------------------------
#  * CAPEX -> OPEX. The 48 MiB LUN and the 10% CPU quota were money spent before
#    demand was known. Both were wrong, in the expensive direction and the
#    outage direction at once. Resize and autoscale convert that bet into
#    metered consumption: you pay for the burst during the burst.
#  * ELASTICITY IS NOT "BIG". Overprovisioning for peak is how on-prem survives
#    Black Friday, and it wastes the other 364 days. Elastic means capacity
#    tracks demand in both directions.
#  * TIME TO MARKET. Time your fix. Now price the same fix when the storage
#    shelf must be quoted, approved, shipped, racked and zoned — weeks. Every
#    week is a feature your competitor shipped and you did not. That, not the
#    hourly rate, is the number executives are buying.
#  * TCO IS NOT THE INVOICE. The invoice is a line item; TCO includes the rack,
#    the power, the spare shelf that sits idle, the maintenance window, the
#    on-call night, and the revenue lost during it.
#    https://cloud.google.com/architecture/framework/cost-optimization
#  * MANAGED SERVICES MOVE THE LINE. You still ran resize2fs inside the guest.
#    Move this ledger to a managed database or object storage and even that step
#    disappears; the undifferentiated work becomes the provider's problem while
#    your team keeps the part customers pay for.
#  * MEASURE THE BUSINESS TRANSACTION. /healthz was 200 through the entire
#    outage. A digital transformation that migrates infrastructure but keeps
#    monitoring the process instead of the order is a lift-and-shift with a
#    green dashboard.
#
#  Reference: Cloud Digital Leader exam guide, section 1.1
#  https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
# =============================================================================