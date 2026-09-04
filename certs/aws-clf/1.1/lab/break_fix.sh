#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02)
#  Domain 1 - Cloud Concepts | Task Statement 1.1: Define the benefits of the AWS Cloud
#  Exam weight of the domain: 24% | Weight of this task statement: 6.0
#
#  LAB TYPE : break & fix (destructive, offline simulation)
#  RUNTIME  : disposable lab VM ONLY. Never run this on a workstation you care
#             about and never on an EC2 instance you did not create for this lab.
#
#  WHY A BREAK & FIX LAB FOR A "BENEFITS" TASK STATEMENT
#  ------------------------------------------------------
#  Task statement 1.1 is examined as vocabulary - high availability, elasticity,
#  agility, economies of scale, global reach - but the vocabulary only becomes
#  durable knowledge once you have felt the failure mode that each benefit
#  removes. This lab builds a deliberately bad "on-premises" architecture in
#  miniature on a single Linux host: one hardcoded server, one fixed capacity
#  limit, one region. Then it breaks it in the three ways the AWS Cloud claims
#  to fix. Your job is to re-architect it, locally, using the same patterns
#  AWS implements at planetary scale.
#
#  There is no AWS account, no billing and no network egress required. The
#  simulation is 100% local so it is free, repeatable and safe.
#
#  OFFICIAL SOURCES (verify every claim against these, not against this script)
#  - CLF-C02 Exam Guide (authoritative task statement wording):
#      https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#  - AWS Well-Architected Framework - Reliability Pillar:
#      https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
#  - AWS Global Infrastructure (Regions and Availability Zones):
#      https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
#  - Amazon EC2 Auto Scaling User Guide:
#      https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
#  - Elastic Load Balancing - health checks:
#      https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
#  - AWS Shared Responsibility Model:
#      https://aws.amazon.com/compliance/shared-responsibility-model/
# ==============================================================================

set -uo pipefail
# NOTE: 'set -e' is deliberately NOT enabled. This lab must survive the failures
# it creates on purpose; an early exit would hide the very symptom you must see.

LAB_ROOT="/opt/clf-lab-1-1"
APP_DIR="${LAB_ROOT}/app"
CFG_DIR="${LAB_ROOT}/etc"
LOG_DIR="${LAB_ROOT}/log"
STATE_DIR="${LAB_ROOT}/state"
BACKUP_DIR="${LAB_ROOT}/.backup"
CLIENT="${LAB_ROOT}/bin/client.sh"
MARKER="${LAB_ROOT}/.lab-marker"

# Ports for the three simulated "servers". 1 = the only one the client knows.
PORT_A=18081
PORT_B=18082
PORT_C=18083

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BLD$C_BLU" "== $* ==" "$C_OFF"; }
ok()   { printf '%s[ OK ]%s %s\n'    "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n'    "$C_YEL" "$C_OFF" "$*"; }
bad()  { printf '%s[BREAK]%s %s\n'   "$C_RED" "$C_OFF" "$*"; }

# ------------------------------------------------------------------------------
# GUARD RAILS
# The lab refuses to run unless the operator has explicitly declared the host
# disposable. This is not ceremony: the script kills processes, writes under
# /opt and installs a systemd unit. Treat any script that does that with the
# same suspicion you would treat an IAM policy containing "Action": "*".
# ------------------------------------------------------------------------------
preflight() {
  head1 "Preflight"

  if [[ "${I_UNDERSTAND_THIS_VM_IS_DISPOSABLE:-no}" != "yes" ]]; then
    say "${C_RED}Refusing to run.${C_OFF}"
    say ""
    say "This lab creates, breaks and deletes services under ${LAB_ROOT}."
    say "Run it only on a throwaway VM (Vagrant box, cloud sandbox, LXC container,"
    say "or an EC2 instance in a sandbox account that you will terminate afterwards)."
    say ""
    say "To confirm, re-run as:"
    say "  I_UNDERSTAND_THIS_VM_IS_DISPOSABLE=yes sudo -E $0 break"
    exit 1
  fi

  if [[ $EUID -ne 0 ]]; then
    say "${C_RED}Must run as root${C_OFF} (writes to /opt, manages systemd units)."
    exit 1
  fi

  local missing=()
  for b in python3 curl systemctl ss awk sed grep; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if ((${#missing[@]})); then
    say "${C_RED}Missing required tools:${C_OFF} ${missing[*]}"
    say "Debian/Ubuntu : apt-get install -y python3 curl iproute2 systemd"
    say "Amazon Linux  : dnf install -y python3 curl iproute systemd"
    exit 1
  fi

  # Every port we touch must be free AND unclaimed by anything but this lab.
  for p in "$PORT_A" "$PORT_B" "$PORT_C"; do
    if ss -ltnH "sport = :$p" | grep -q . && [[ ! -f "$MARKER" ]]; then
      say "${C_RED}Port $p is already in use by a non-lab process.${C_OFF}"
      say "Pick a different VM or free the port before continuing."
      exit 1
    fi
  done

  ok "Host accepted as disposable. Lab root: ${LAB_ROOT}"
}

# ------------------------------------------------------------------------------
# BUILD: the deliberately bad "on-premises" architecture
#
#   client.sh  --->  hardcoded IP 127.0.0.1:18081  --->  single app instance
#                                                        max 2 concurrent reqs
#                                                        region label: dc-1
#
# Every property below has a named AWS counterpart. Learn the pairing:
#   single instance, hardcoded target  -> no Elastic Load Balancing, no Multi-AZ
#   fixed MAX_CONCURRENCY              -> no EC2 Auto Scaling, no elasticity
#   single region label                -> no global reach / no DR region
#   manual restart by a human          -> no self-healing, no managed service
# ------------------------------------------------------------------------------
build_app() {
  head1 "Building the legacy single-server stack"

  mkdir -p "$APP_DIR" "$CFG_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR" "${LAB_ROOT}/bin"
  : > "$MARKER"

  # --- the application: a tiny HTTP service with an artificial capacity ceiling
  cat > "${APP_DIR}/server.py" <<'PYEOF'
#!/usr/bin/env python3
"""Minimal capacity-limited HTTP service used by the CLF-C02 1.1 lab.

Endpoints:
  /health   -> 200 "ok"           (what an ELB target group health check hits)
  /region   -> 200 "<region>:<node>"
  /work     -> 200 after a short delay, or 503 when the node is already
               serving MAX_CONCURRENCY requests. This is the fixed-capacity
               ceiling that a physical server has and that Auto Scaling removes.
"""
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "18081"))
NODE = os.environ.get("NODE_ID", "node-a")
REGION = os.environ.get("REGION_ID", "dc-1")
MAX_CONCURRENCY = int(os.environ.get("MAX_CONCURRENCY", "2"))
WORK_SECONDS = float(os.environ.get("WORK_SECONDS", "0.35"))

_lock = threading.Lock()
_inflight = 0
_rejected = 0
_served = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Node-Id", NODE)
        self.send_header("X-Region-Id", REGION)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        global _inflight, _rejected, _served
        path = self.path.split("?", 1)[0]

        if path == "/health":
            self._reply(200, "ok")
            return

        if path == "/region":
            self._reply(200, "%s:%s" % (REGION, NODE))
            return

        if path == "/stats":
            self._reply(200, "served=%d rejected=%d inflight=%d cap=%d"
                        % (_served, _rejected, _inflight, MAX_CONCURRENCY))
            return

        if path == "/work":
            with _lock:
                if _inflight >= MAX_CONCURRENCY:
                    _rejected += 1
                    self._reply(503, "capacity exceeded on %s (cap=%d)"
                                % (NODE, MAX_CONCURRENCY))
                    return
                _inflight += 1
            try:
                time.sleep(WORK_SECONDS)
                with _lock:
                    _served += 1
                self._reply(200, "served by %s in %s" % (NODE, REGION))
            finally:
                with _lock:
                    _inflight -= 1
            return

        self._reply(404, "not found")

    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s - %s\n" % (NODE, self.log_date_time_string(), fmt % a))


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write("starting %s on 127.0.0.1:%d region=%s cap=%d\n"
                     % (NODE, PORT, REGION, MAX_CONCURRENCY))
    srv.serve_forever()
PYEOF
  chmod 0755 "${APP_DIR}/server.py"

  # --- the client: the single point of failure lives HERE, not in the server.
  #     Note the hardcoded endpoint. In AWS you would point clients at a stable
  #     DNS name (an ALB or a Route 53 record) and let the platform decide which
  #     healthy target in which AZ answers.
  cat > "$CLIENT" <<'SHEOF'
#!/usr/bin/env bash
# Legacy client. Speaks to exactly one hardcoded backend, forever.
set -uo pipefail
source /opt/clf-lab-1-1/etc/endpoint.conf

N="${1:-10}"
CONCURRENCY="${2:-1}"
ok=0; fail=0

run_one() {
  curl -fsS --max-time 3 "http://${BACKEND_HOST}:${BACKEND_PORT}/work" >/dev/null 2>&1
}

pids=()
for i in $(seq 1 "$N"); do
  run_one & pids+=("$!")
  if (( ${#pids[@]} >= CONCURRENCY )); then
    for p in "${pids[@]}"; do wait "$p" && ok=$((ok+1)) || fail=$((fail+1)); done
    pids=()
  fi
done
for p in "${pids[@]:-}"; do
  [[ -n "$p" ]] && { wait "$p" && ok=$((ok+1)) || fail=$((fail+1)); }
done

total=$((ok+fail))
(( total == 0 )) && total=1
printf 'requests=%d ok=%d failed=%d availability=%d%%\n' \
  "$((ok+fail))" "$ok" "$fail" "$(( ok * 100 / total ))"
[[ $fail -eq 0 ]]
SHEOF
  chmod 0755 "$CLIENT"

  cat > "${CFG_DIR}/endpoint.conf" <<EOF
# Legacy configuration: ONE server, by address, chosen by a human in 2011.
BACKEND_HOST="127.0.0.1"
BACKEND_PORT="${PORT_A}"
EOF

  # --- systemd unit for node-a only. Deliberately no Restart= directive:
  #     recovery is a human's job here. That is the manual toil the AWS
  #     managed-service model removes.
  cat > /etc/systemd/system/clf-lab-node-a.service <<EOF
[Unit]
Description=CLF-C02 lab node-a (legacy single server, no auto-restart)
After=network.target

[Service]
Type=simple
Environment=PORT=${PORT_A}
Environment=NODE_ID=node-a
Environment=REGION_ID=dc-1
Environment=MAX_CONCURRENCY=2
ExecStart=/usr/bin/python3 ${APP_DIR}/server.py
StandardOutput=append:${LOG_DIR}/node-a.log
StandardError=append:${LOG_DIR}/node-a.log
# NOTE: no Restart=, no RestartSec=. This omission is part of the lab.

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now clf-lab-node-a.service >/dev/null 2>&1

  # Wait for readiness instead of sleeping blindly - the same discipline an
  # ELB health check applies before a target is marked healthy.
  local tries=0
  until curl -fsS --max-time 1 "http://127.0.0.1:${PORT_A}/health" >/dev/null 2>&1; do
    tries=$((tries+1))
    (( tries > 30 )) && { say "${C_RED}node-a never became healthy${C_OFF}"; exit 1; }
    sleep 0.2
  done

  cp "${CFG_DIR}/endpoint.conf" "${BACKUP_DIR}/endpoint.conf.orig"
  ok "node-a is up on 127.0.0.1:${PORT_A} (region label: dc-1, capacity: 2)"

  say ""
  say "Baseline behaviour, before anything is broken:"
  "$CLIENT" 6 1
  say ""
}

# ------------------------------------------------------------------------------
# THE THREE BREAKS
# ------------------------------------------------------------------------------
break_1_availability() {
  head1 "BREAK 1 of 3 - High availability"
  systemctl stop clf-lab-node-a.service
  echo "break1" >> "${STATE_DIR}/broken"
  bad "node-a has been stopped. The only backend the client knows is gone."
}

break_2_elasticity() {
  head1 "BREAK 2 of 3 - Elasticity"
  echo "break2" >> "${STATE_DIR}/broken"
  bad "Demand is about to exceed the fixed capacity of a single node (cap=2)."
}

break_3_global_reach() {
  head1 "BREAK 3 of 3 - Global reach / disaster recovery"
  rm -f "${STATE_DIR}/dr-region-available"
  echo "break3" >> "${STATE_DIR}/broken"
  bad "There is exactly one region label (dc-1). No second site exists to fail over to."
}

# ------------------------------------------------------------------------------
# BRIEFING - what the student sees and what they must achieve
# ------------------------------------------------------------------------------
briefing() {
  head1 "SYMPTOMS YOU WILL OBSERVE"

  say ""
  say "${C_BLD}Symptom 1 - total outage from a single failure${C_OFF}"
  say "  Command : ${CLIENT} 6 1"
  say "  Expected: requests=6 ok=0 failed=6 availability=0%"
  say "  Direct  : curl -v http://127.0.0.1:${PORT_A}/work"
  say "            curl: (7) Failed to connect to 127.0.0.1 port ${PORT_A}: Connection refused"
  say "  Reality : one process died and 100% of the service died with it. There"
  say "            is no second instance and nothing in front of the instance"
  say "            that could route around it."
  say ""
  say "${C_BLD}Symptom 2 - requests rejected under load, while hardware idles${C_OFF}"
  say "  Command : ${CLIENT} 20 8      # 20 requests, 8 at a time"
  say "  Expected: a large 'failed=' count once node-a is running again"
  say "  Direct  : curl -s http://127.0.0.1:${PORT_A}/work"
  say "            capacity exceeded on node-a (cap=2)"
  say "            (HTTP 503 - confirm with: curl -o /dev/null -w '%{http_code}\\n' ...)"
  say "  Reality : capacity was sized once, by a human, for an average day."
  say "            Demand is not average. Buying for the peak wastes money for"
  say "            364 days; buying for the average drops traffic on day 365."
  say ""
  say "${C_BLD}Symptom 3 - no second site${C_OFF}"
  say "  Command : curl -s http://127.0.0.1:${PORT_A}/region"
  say "  Expected: dc-1:node-a   ... and no other region answers, ever."
  say "  Reality : if dc-1 is lost - power, flood, fibre cut - recovery time is"
  say "            measured in weeks of procurement, not minutes of API calls."

  head1 "YOUR OBJECTIVE"
  say ""
  say "Re-architect the stack, ON THIS VM, until ${C_BLD}all four${C_OFF} acceptance checks pass:"
  say ""
  say "  ${C_BLD}A. Fault tolerance${C_OFF}"
  say "     Run at least two application nodes. Kill any ONE of them and"
  say "     '${CLIENT} 10 2' must still report availability=100%."
  say "     -> AWS analogue: two or more EC2 instances in different Availability"
  say "        Zones behind an Application Load Balancer, which stops sending"
  say "        traffic to a target that fails its health check."
  say ""
  say "  ${C_BLD}B. Elasticity${C_OFF}"
  say "     Serve a burst of 20 concurrent requests with 0 failures by adding"
  say "     capacity, NOT by raising MAX_CONCURRENCY on the existing node."
  say "     -> AWS analogue: an EC2 Auto Scaling group scaling out on a target"
  say "        tracking policy, then scaling back in when the burst ends so you"
  say "        stop paying for the capacity you no longer need."
  say ""
  say "  ${C_BLD}C. Self-healing${C_OFF}"
  say "     'systemctl kill' any node and it must come back with no human action."
  say "     -> AWS analogue: an ASG health check replacing an unhealthy instance."
  say "        Note what you did NOT have to do: no ticket, no data-centre visit."
  say ""
  say "  ${C_BLD}D. Global reach${C_OFF}"
  say "     Bring up a node labelled with a SECOND region and prove the client"
  say "     can be steered to it when the first region is entirely down."
  say "     -> AWS analogue: a second AWS Region plus Route 53 failover routing."
  say "        Regions are fully isolated from each other by design; that"
  say "        isolation is what makes them a real DR boundary."
  say ""
  say "${C_BLD}CONSTRAINT${C_OFF} - the client must stop hardcoding a backend address."
  say "A stable name that resolves to whatever is healthy is the entire point of"
  say "the load balancer; if you only edit endpoint.conf to a different single"
  say "port, you have moved the single point of failure, not removed it."
  say ""
  say "Grade yourself at any time:   sudo $0 verify"
  say "Give up and read the answer:  sed -n '/SOLUTION WALKTHROUGH/,\$p' $0"
  say "Destroy everything:           sudo $0 clean"
  say ""
  warn "Exam framing: this task statement is scored on the VOCABULARY."
  warn "When you finish, be able to name each fix: high availability, fault"
  warn "tolerance, elasticity, agility, economies of scale, global reach."
}

# ------------------------------------------------------------------------------
# VERIFY - the grader. Deliberately behavioural: it asserts outcomes, never
# implementation. Any design that survives the tests is a correct answer.
# ------------------------------------------------------------------------------
verify() {
  head1 "Acceptance checks"
  local pass=0 fail=0

  # --- A. fault tolerance -----------------------------------------------------
  say ""
  say "${C_BLD}A. Fault tolerance${C_OFF}"
  local live=()
  for p in "$PORT_A" "$PORT_B" "$PORT_C"; do
    curl -fsS --max-time 1 "http://127.0.0.1:${p}/health" >/dev/null 2>&1 && live+=("$p")
  done
  if (( ${#live[@]} >= 2 )); then
    ok "  ${#live[@]} healthy nodes responding (ports: ${live[*]})"
    local victim="${live[0]}"
    local unit
    unit="$(systemctl list-units --type=service --no-legend 'clf-lab-node-*' \
            | awk '{print $1}' | while read -r u; do
                systemctl show "$u" -p Environment --value 2>/dev/null \
                  | grep -q "PORT=${victim}" && echo "$u"; done | head -n1)"
    if [[ -n "$unit" ]]; then
      systemctl stop "$unit" >/dev/null 2>&1
      sleep 1
      if "$CLIENT" 10 2 >/dev/null 2>&1; then
        ok "  survived the loss of ${unit} with availability=100%"; pass=$((pass+1))
      else
        bad "  losing ${unit} still causes failed requests - the client is not"
        bad "  routing around the dead node"; fail=$((fail+1))
      fi
      systemctl start "$unit" >/dev/null 2>&1
      sleep 1
    else
      warn "  could not identify the unit owning port ${victim}; skipping kill test"
      fail=$((fail+1))
    fi
  else
    bad "  only ${#live[@]} healthy node(s). Objective A needs at least 2."
    fail=$((fail+1))
  fi

  # --- B. elasticity ----------------------------------------------------------
  say ""
  say "${C_BLD}B. Elasticity${C_OFF}"
  local total_cap=0
  for p in "${live[@]:-}"; do
    [[ -z "$p" ]] && continue
    local c
    c="$(curl -fsS --max-time 1 "http://127.0.0.1:${p}/stats" 2>/dev/null \
         | sed -n 's/.*cap=\([0-9]*\).*/\1/p')"
    [[ -n "$c" ]] && total_cap=$((total_cap + c))
  done
  say "  aggregate capacity across healthy nodes: ${total_cap}"
  if (( total_cap >= 6 )); then
    if "$CLIENT" 20 8 >/dev/null 2>&1; then
      ok "  absorbed a 20-request burst at concurrency 8 with 0 failures"
      pass=$((pass+1))
    else
      bad "  burst still produced failures"; fail=$((fail+1))
    fi
  else
    bad "  aggregate capacity ${total_cap} is below the required 6"
    fail=$((fail+1))
  fi

  # --- C. self-healing --------------------------------------------------------
  say ""
  say "${C_BLD}C. Self-healing${C_OFF}"
  local healing=0
  while read -r u; do
    [[ -z "$u" ]] && continue
    local r
    r="$(systemctl show "$u" -p Restart --value 2>/dev/null)"
    [[ "$r" == "always" || "$r" == "on-failure" ]] && healing=$((healing+1))
  done < <(systemctl list-units --type=service --no-legend 'clf-lab-node-*' | awk '{print $1}')
  if (( healing >= 2 )); then
    ok "  ${healing} units declare Restart=always|on-failure"; pass=$((pass+1))
  else
    bad "  only ${healing} unit(s) restart themselves; recovery is still manual"
    fail=$((fail+1))
  fi

  # --- D. global reach --------------------------------------------------------
  say ""
  say "${C_BLD}D. Global reach${C_OFF}"
  local regions
  regions="$(for p in "${live[@]:-}"; do
               [[ -z "$p" ]] && continue
               curl -fsS --max-time 1 "http://127.0.0.1:${p}/region" 2>/dev/null \
                 | cut -d: -f1
             done | sort -u | tr '\n' ' ')"
  local rcount
  rcount="$(printf '%s' "$regions" | wc -w)"
  if (( rcount >= 2 )); then
    ok "  ${rcount} distinct regions serving: ${regions}"; pass=$((pass+1))
  else
    bad "  only ${rcount} region label in play (${regions:-none}). No DR boundary."
    fail=$((fail+1))
  fi

  say ""
  if (( fail == 0 )); then
    say "${C_GRN}${C_BLD}4/4 - lab complete.${C_OFF}"
    say "You rebuilt, by hand, what ELB + Auto Scaling + Multi-AZ + multi-Region"
    say "give you as configuration. That labour, and the capital behind it, is"
    say "what 'the benefits of the AWS Cloud' names in task statement 1.1."
  else
    say "${C_YEL}${pass} passed, ${fail} still failing.${C_OFF} Keep going."
  fi
}

clean() {
  head1 "Tearing down"
  [[ -f "$MARKER" ]] || { say "No lab marker at ${MARKER}; refusing to delete ${LAB_ROOT}."; exit 1; }
  while read -r u; do
    [[ -z "$u" ]] && continue
    systemctl disable --now "$u" >/dev/null 2>&1
  done < <(systemctl list-unit-files --no-legend 'clf-lab-node-*.service' | awk '{print $1}')
  rm -f /etc/systemd/system/clf-lab-node-*.service
  systemctl daemon-reload
  rm -rf "$LAB_ROOT"
  ok "Lab removed. Nothing of this exercise remains on the host."
  warn "If you ran this on EC2, terminate the instance too - a stopped instance"
  warn "still bills you for its EBS volumes."
}

usage() {
  say "Usage: I_UNDERSTAND_THIS_VM_IS_DISPOSABLE=yes sudo -E $0 <command>"
  say ""
  say "  break    build the legacy stack, break it three ways, print the briefing"
  say "  verify   grade your fix against the four acceptance checks"
  say "  clean    remove every artifact this lab created"
}

main() {
  case "${1:-}" in
    break)
      preflight
      build_app
      break_1_availability
      break_2_elasticity
      break_3_global_reach
      briefing
      ;;
    verify)
      [[ -f "$MARKER" ]] || { say "Lab not built. Run '$0 break' first."; exit 1; }
      verify
      ;;
    clean)  clean ;;
    *)      usage; exit 1 ;;
  esac
}

main "$@"

# ==============================================================================
#  SOLUTION WALKTHROUGH - do not read until you have genuinely attempted the fix
# ==============================================================================
#
#  The trap in this lab is that three of the four objectives look like they can
#  be solved by editing endpoint.conf. They cannot. Pointing the client at a
#  different single port relocates the single point of failure. The fix is
#  structural, and it is the same structure AWS sells as managed services.
#
#  ---------------------------------------------------------------------------
#  STEP 1 - Add capacity, in a second and third "Availability Zone"
#  ---------------------------------------------------------------------------
#  Objectives B and D both require more than one node, so build them first.
#  Copy the node-a unit twice, changing PORT, NODE_ID and - for node-c - the
#  REGION_ID, and add the Restart= directive node-a is missing (objective C).
#
#    for spec in "b 18082 dc-1" "c 18083 dc-2"; do
#      set -- $spec
#      name=$1; port=$2; region=$3
#      cat > /etc/systemd/system/clf-lab-node-${name}.service <<EOF
#    [Unit]
#    Description=CLF-C02 lab node-${name}
#    After=network.target
#
#    [Service]
#    Type=simple
#    Environment=PORT=${port}
#    Environment=NODE_ID=node-${name}
#    Environment=REGION_ID=${region}
#    Environment=MAX_CONCURRENCY=4
#    ExecStart=/usr/bin/python3 /opt/clf-lab-1-1/app/server.py
#    Restart=always
#    RestartSec=1
#    StandardOutput=append:/opt/clf-lab-1-1/log/node-${name}.log
#    StandardError=append:/opt/clf-lab-1-1/log/node-${name}.log
#
#    [Install]
#    WantedBy=multi-user.target
#    EOF
#    done
#
#  Give node-a the same self-healing property. Never hand-edit a unit file that
#  a tool generated; use the drop-in mechanism, which is the systemd equivalent
#  of not mutating an instance outside its launch template:
#
#    mkdir -p /etc/systemd/system/clf-lab-node-a.service.d
#    printf '[Service]\nRestart=always\nRestartSec=1\n' \
#      > /etc/systemd/system/clf-lab-node-a.service.d/10-self-heal.conf
#
#    systemctl daemon-reload
#    systemctl enable --now clf-lab-node-a clf-lab-node-b clf-lab-node-c
#
#  Confirm all three answer, and note the region labels:
#
#    for p in 18081 18082 18083; do curl -s http://127.0.0.1:$p/region; echo; done
#    dc-1:node-a
#    dc-1:node-b
#    dc-2:node-c
#
#  ---------------------------------------------------------------------------
#  STEP 2 - Put a load balancer in front, and stop hardcoding the backend
#  ---------------------------------------------------------------------------
#  This is the objective-A fix and the one that carries the exam concept. The
#  client must address a STABLE NAME; something else decides which healthy
#  target answers. Write a health-checking dispatcher:
#
#    cat > /opt/clf-lab-1-1/bin/elb.sh <<'EOF'
#    #!/usr/bin/env bash
#    # Minimal Application Load Balancer: health-check, then round-robin over
#    # the targets that passed. Mirrors an ALB target group.
#    set -uo pipefail
#    TARGETS=(18081 18082 18083)
#    STATE=/opt/clf-lab-1-1/state/rr
#
#    healthy=()
#    for p in "${TARGETS[@]}"; do
#      curl -fsS --max-time 1 "http://127.0.0.1:${p}/health" >/dev/null 2>&1 \
#        && healthy+=("$p")
#    done
#    (( ${#healthy[@]} == 0 )) && exit 1        # 503: no healthy targets
#
#    idx=$(( ( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ) % ${#healthy[@]} ))
#    echo "$idx" > "$STATE"
#    curl -fsS --max-time 3 "http://127.0.0.1:${healthy[$idx]}/work"
#    EOF
#    chmod 0755 /opt/clf-lab-1-1/bin/elb.sh
#
#  Then repoint the client's run_one at the balancer instead of the hardcoded
#  host:port. Edit /opt/clf-lab-1-1/bin/client.sh and replace the body of
#  run_one with:
#
#    run_one() { /opt/clf-lab-1-1/bin/elb.sh >/dev/null 2>&1; }
#
#  The health check is what makes this fault tolerant rather than merely
#  redundant: a dead target is excluded on the very next request, with no human
#  in the loop. That is the mechanism behind an ALB target group, and the
#  reason 'unhealthy threshold' and 'health check interval' are tunable knobs -
#  they set how fast the system converges after a failure.
#      https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
#
#  Prove objective A the way the grader does:
#
#    systemctl stop clf-lab-node-b
#    /opt/clf-lab-1-1/bin/client.sh 10 2
#    requests=10 ok=10 failed=0 availability=100%
#    systemctl start clf-lab-node-b
#
#  ---------------------------------------------------------------------------
#  STEP 3 - Elasticity: add nodes, do not enlarge one
#  ---------------------------------------------------------------------------
#  Aggregate capacity is now 2 + 4 + 4 = 10, spread across three nodes, so the
#  20-request burst at concurrency 8 clears:
#
#    /opt/clf-lab-1-1/bin/client.sh 20 8
#    requests=20 ok=20 failed=0 availability=100%
#
#  Why the rule forbade raising MAX_CONCURRENCY on node-a: that is vertical
#  scaling. It has a hard ceiling (the largest instance type in existence), it
#  usually requires a restart, and it leaves you paying peak-sized hardware
#  during the trough. Horizontal scaling has neither property, which is why
#  Auto Scaling groups scale out and in rather than up and down.
#      https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html
#
#  Scaling back IN is the half students forget and the half the exam rewards.
#  Elasticity is bidirectional; releasing capacity is where the cost benefit
#  actually lands:
#
#    systemctl stop clf-lab-node-c      # burst over, stop paying for it
#
#  (Leave it running for the grader - objective D needs region dc-2 alive.)
#
#  ---------------------------------------------------------------------------
#  STEP 4 - Global reach: prove the second region can take over alone
#  ---------------------------------------------------------------------------
#  node-c carries REGION_ID=dc-2. Simulate the total loss of dc-1:
#
#    systemctl stop clf-lab-node-a clf-lab-node-b
#    /opt/clf-lab-1-1/bin/client.sh 10 2
#    requests=10 ok=10 failed=0 availability=100%
#    curl -s http://127.0.0.1:18083/region
#    dc-2:node-c
#
#    systemctl start clf-lab-node-a clf-lab-node-b     # restore before verify
#
#  In AWS the steering is Route 53 failover routing: a primary record with a
#  health check, a secondary record that takes the traffic when the primary is
#  unhealthy. The important architectural fact is that AWS Regions are isolated
#  from each other on purpose - separate control planes, separate failure
#  domains - which is exactly what makes a second Region a real disaster
#  recovery boundary and a second AZ only a facility-level one.
#      https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
#      https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
#
#  ---------------------------------------------------------------------------
#  STEP 5 - Grade and tear down
#  ---------------------------------------------------------------------------
#    sudo /path/to/this-script verify      # expect 4/4
#    sudo /path/to/this-script clean
#
#  ---------------------------------------------------------------------------
#  MAPPING THE LAB TO THE EXAM VOCABULARY
#  ---------------------------------------------------------------------------
#  What you built by hand      | AWS service                | Benefit named in 1.1
#  ----------------------------|----------------------------|---------------------
#  elb.sh + /health polling    | Elastic Load Balancing     | High availability,
#                              |                            | fault tolerance
#  three nodes, two regions    | Multi-AZ / multi-Region    | High availability,
#                              |                            | global reach
#  adding & removing nodes     | EC2 Auto Scaling           | Elasticity, cost
#                              |                            | (pay for what you use)
#  Restart=always              | ASG health-check replace   | Self-healing, less
#                              |                            | undifferentiated toil
#  ~90 seconds to build it     | API-driven provisioning    | Agility, speed to market
#  hardware you never bought   | AWS capital expenditure    | Economies of scale,
#                              |                            | CapEx -> OpEx
#
#  Three exam-grade distinctions this lab makes concrete:
#
#  1. HIGH AVAILABILITY vs FAULT TOLERANCE. Two nodes behind a health-checked
#     balancer is high availability: failures cause a brief, small degradation.
#     Fault tolerance is stronger - zero impact from the defined fault. Note
#     that in step 2 the in-flight request to node-b still failed; only the
#     NEXT one was routed away. Recovery time is never zero.
#
#  2. SCALABILITY vs ELASTICITY. Scalability is the capability to grow.
#     Elasticity is growing AND shrinking automatically with demand. Step 3
#     without the `systemctl stop` in it is scalability only, and it is why an
#     unmonitored Auto Scaling group can still produce a large bill.
#
#  3. WHAT YOU STILL OWN. Nothing here removed your responsibility for the
#     application code, its configuration or its data. Under the AWS Shared
#     Responsibility Model, AWS is responsible for the security OF the cloud;
#     you remain responsible for security IN the cloud. Managed infrastructure
#     is not managed correctness.
#         https://aws.amazon.com/compliance/shared-responsibility-model/
#
#  A closing caveat on the simulation's limits: everything above ran on ONE
#  kernel, ONE disk and ONE power supply. It reproduces the control-flow of a
#  resilient architecture, not its physical independence. Real Availability
#  Zones are discrete facilities with independent power, cooling and networking,
#  meshed with low-latency links - and that physical separation, which no script
#  can simulate, is the part you are actually buying.
#      https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
# ==============================================================================