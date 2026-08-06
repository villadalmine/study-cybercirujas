#!/usr/bin/env bash
#
# KCSA — Kubernetes and Cloud Native Security Associate
# Domain 1.2: Cloud Provider and Infrastructure Security (exam weight 2.33)
#
# BREAK & FIX LAB — "The exposed cloud metadata endpoint"
# ---------------------------------------------------------------------------
# What this lab teaches:
#   Every cloud instance (EC2, GCE, Azure VM) exposes a link-local metadata
#   service at 169.254.169.254. That endpoint hands out the node's identity:
#   IAM/service-account credentials, user-data, SSH keys. A node that lets an
#   ordinary workload reach it turns a single container SSRF or RCE into a full
#   cloud-account takeover (this is the Capital One 2019 breach class). Node
#   hardening therefore MUST restrict egress to 169.254.169.254 to the system
#   agents that legitimately need it (cloud-controller-manager, kubelet,
#   cloud-init) and deny it to workloads.
#
#   This script builds a *self-contained* model of that control on a throwaway
#   VM: a fake metadata server on 169.254.169.254, plus a host firewall rule
#   that blocks an unprivileged "workload" identity from reaching it. Then it
#   BREAKS the control (someone flushed the rule) so you can see the leak and
#   restore the block yourself.
#
# SAFE / REVERSIBLE: it only touches a dummy loopback address, one appended
# iptables OUTPUT rule, a temp dir under /tmp, and a dedicated system user.
# `./this.sh cleanup` removes everything. RUN ONLY ON A DISPOSABLE LAB VM.
#
# Sources:
#   - KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#   - Kubernetes, Securing a Cluster > Restricting cloud metadata API access:
#     https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
#   - Kubernetes Security concepts: https://kubernetes.io/docs/concepts/security/
#   - AWS IMDSv2 hardening: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
#   - GKE metadata concealment / Workload Identity: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
# ---------------------------------------------------------------------------

set -euo pipefail

LAB_DIR="/tmp/kcsa-1.2-breakfix"
IMDS_PY="${LAB_DIR}/imds_sim.py"
PIDFILE="${LAB_DIR}/imds_sim.pid"
META_IP="169.254.169.254"
META_PORT="80"
WORKLOAD_USER="metaworkload"
ROLE="lab-node-role"
CREDS_PATH="/latest/meta-data/iam/security-credentials/${ROLE}"

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
rule() { printf '%s\n' "-------------------------------------------------------------"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This lab manipulates iptables, ip addr and users. Run it as root:"
    err "    sudo $0 ${1:-run}"
    exit 1
  fi
}

confirm_lab() {
  # Refuse to run on anything that is not clearly a throwaway machine.
  if [ "${LAB_CONFIRM:-}" = "1" ]; then
    return 0
  fi
  warn "This will add a dummy ${META_IP} address, an iptables rule and a"
  warn "system user, then deliberately break a security control."
  warn "Do this ONLY on a disposable lab VM you can destroy."
  if [ -t 0 ]; then
    read -r -p "Type 'yes' to confirm this is a disposable lab VM: " ans
    [ "$ans" = "yes" ] || { err "Aborted."; exit 1; }
  else
    err "Non-interactive run: set LAB_CONFIRM=1 to acknowledge this is a lab VM."
    exit 1
  fi
}

preflight() {
  local missing=0
  for bin in iptables ip curl python3 useradd runuser; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      err "Missing required tool: $bin"; missing=1
    fi
  done
  [ "$missing" -eq 0 ] || { err "Install the missing tools and retry."; exit 1; }
  mkdir -p "$LAB_DIR"
}

ensure_workload_user() {
  if ! id "$WORKLOAD_USER" >/dev/null 2>&1; then
    useradd -r -M -s /usr/sbin/nologin "$WORKLOAD_USER" 2>/dev/null \
      || useradd -r -M -s /bin/false "$WORKLOAD_USER"
    ok "Created unprivileged identity '${WORKLOAD_USER}' (stands in for a Pod)."
  else
    info "Workload identity '${WORKLOAD_USER}' already present."
  fi
}

ensure_meta_ip() {
  if ip addr show dev lo | grep -qw "$META_IP"; then
    info "Metadata address ${META_IP} already assigned to lo."
  else
    ip addr add "${META_IP}/32" dev lo
    ok "Assigned dummy metadata address ${META_IP}/32 to lo."
  fi
}

write_sim() {
  cat > "$IMDS_PY" <<PY
import http.server, socketserver
HOST, PORT = "${META_IP}", ${META_PORT}
ROLE = "${ROLE}"
CREDS = """{
  "Code": "Success",
  "Type": "AWS-HMAC",
  "AccessKeyId": "ASIAFAKELABEXAMPLE01",
  "SecretAccessKey": "FAKE/lab/secret/DO-NOT-USE/EXAMPLE0000000000",
  "Token": "FAKE-SESSION-TOKEN-lab-example-not-a-real-credential",
  "Expiration": "2099-01-01T00:00:00Z"
}"""
BASE = "/latest/meta-data/iam/security-credentials/"
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, body, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body.encode())
    def do_GET(self):
        p = self.path
        if p.startswith(BASE) and len(p) > len(BASE):
            self._send(CREDS)                 # the crown jewels: node credentials
        elif p == BASE:
            self._send(ROLE + "\n")           # enumerate the attached role
        elif p.startswith("/latest/") or p.startswith("/computeMetadata"):
            self._send("lab-metadata-ok\n")
        else:
            self._send("lab-imds-simulator\n")
    def log_message(self, *a):
        return
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer((HOST, PORT), H) as httpd:
    httpd.serve_forever()
PY
}

sim_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

start_sim() {
  if sim_running; then
    info "Metadata simulator already running (pid $(cat "$PIDFILE"))."
    return 0
  fi
  write_sim
  nohup python3 "$IMDS_PY" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  # wait for the listener to come up
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s --max-time 2 "http://${META_IP}:${META_PORT}${CREDS_PATH}" >/dev/null 2>&1; then
      ok "Fake cloud metadata service is up on ${META_IP}:${META_PORT}."
      return 0
    fi
    sleep 0.3
  done
  err "Metadata simulator failed to start; check python3 and port ${META_PORT}."
  exit 1
}

# The protective control: deny the workload identity egress to the metadata IP.
BLOCK_RULE=(OUTPUT -d "${META_IP}/32" -p tcp --dport "${META_PORT}"
            -m owner --uid-owner "${WORKLOAD_USER}"
            -m comment --comment "kcsa-1.2-metadata-guard"
            -j REJECT --reject-with icmp-port-unreachable)

block_present() { iptables -C "${BLOCK_RULE[@]}" 2>/dev/null; }

ensure_block() {
  if block_present; then
    info "Metadata egress guard already in place."
  else
    iptables -A "${BLOCK_RULE[@]}"
    ok "Installed egress guard: '${WORKLOAD_USER}' -> ${META_IP} is REJECTed."
  fi
}

remove_block() {
  while block_present; do
    iptables -D "${BLOCK_RULE[@]}"
  done
}

# Probe the metadata endpoint AS the unprivileged workload identity.
# Prints the response body (empty if the firewall denied it).
probe() {
  runuser -u "$WORKLOAD_USER" -- \
    curl -s --connect-timeout 3 --max-time 5 \
    "http://${META_IP}:${META_PORT}${CREDS_PATH}" 2>/dev/null || true
}

# Returns 0 (LEAKING) if the workload can read credentials, 1 (BLOCKED) if not.
is_leaking() {
  local body; body="$(probe)"
  printf '%s' "$body" | grep -q "AccessKeyId"
}

setup() {
  info "Building the lab (idempotent)..."
  ensure_workload_user
  ensure_meta_ip
  start_sim
  ensure_block
  if is_leaking; then
    err "Guard is installed but workload still reaches metadata — aborting."
    exit 1
  fi
  ok "Baseline is HEALTHY: the workload is denied access to ${META_IP}."
}

do_break() {
  info "Introducing the fault..."
  # THE BREAK: an operator 'cleaned up' the firewall and dropped the guard.
  remove_block
  ok "Fault injected: the metadata egress guard was removed."
}

mission() {
  echo
  rule
  printf '%s%sKCSA 1.2 — BREAK & FIX: exposed cloud metadata endpoint%s\n' "$C_BLD" "$C_YEL" "$C_RST"
  rule
  echo
  printf '%sSYMPTOM YOU WILL OBSERVE%s\n' "$C_BLD" "$C_RST"
  echo "  An unprivileged workload identity ('${WORKLOAD_USER}', standing in"
  echo "  for a compromised Pod) can now reach the node's cloud metadata"
  echo "  service and read its IAM credentials. Reproduce it:"
  echo
  echo "    runuser -u ${WORKLOAD_USER} -- curl -s http://${META_IP}${CREDS_PATH}"
  echo
  echo "  Live output right now:"
  local body; body="$(probe)"
  if [ -n "$body" ]; then
    printf '%s' "$body" | sed 's/^/      /'
    echo
    printf '  %s==> CREDENTIALS ARE LEAKING. The node is exposed.%s\n' "$C_RED" "$C_RST"
  else
    printf '  %s(no data — is the lab set up? run: %s setup)%s\n' "$C_YEL" "$0" "$C_RST"
  fi
  echo
  printf '%sYOUR GOAL%s\n' "$C_BLD" "$C_RST"
  echo "  Restore infrastructure hardening so that the SAME probe is DENIED"
  echo "  (empty output / connection refused), WITHOUT deleting the metadata"
  echo "  service or its address — you must fix the control, not the target."
  echo "  A correct fix blocks the workload identity's egress to ${META_IP}."
  echo
  printf '%sCHECK YOUR WORK%s\n' "$C_BLD" "$C_RST"
  echo "    $0 verify        # PASS when the workload is blocked again"
  echo
  printf '%sHINTS%s\n' "$C_BLD" "$C_RST"
  echo "  - Which host firewall table governs locally-originated traffic?"
  echo "  - iptables can match the *owner* of a socket (-m owner --uid-owner)."
  echo "  - In a real cluster the equivalent controls are: a default-deny"
  echo "    NetworkPolicy egress to 169.254.169.254/32, IMDSv2 with"
  echo "    hop-limit 1, and GKE metadata concealment / Workload Identity."
  echo "  - Undo the whole lab at any time with: $0 cleanup"
  echo
  rule
}

verify() {
  if ! sim_running; then
    err "Lab not running. Start it with: $0 setup && $0 break"
    exit 2
  fi
  info "Probing ${META_IP} as '${WORKLOAD_USER}'..."
  if is_leaking; then
    err "FAIL — metadata credentials are still reachable by the workload."
    err "       The egress guard is not (correctly) in place yet."
    exit 1
  else
    ok "PASS — the workload is denied access to the cloud metadata endpoint."
    ok "You restored infrastructure hardening for KCSA 1.2. Well done."
    exit 0
  fi
}

# Instructor-only shortcut: apply the reference solution automatically.
solve() {
  info "Applying reference solution (instructor mode)..."
  ensure_block
  verify
}

cleanup() {
  info "Tearing down the lab..."
  remove_block || true
  if sim_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$IMDS_PY"
  if ip addr show dev lo | grep -qw "$META_IP"; then
    ip addr del "${META_IP}/32" dev lo 2>/dev/null || true
  fi
  if id "$WORKLOAD_USER" >/dev/null 2>&1; then
    userdel "$WORKLOAD_USER" 2>/dev/null || true
  fi
  rmdir "$LAB_DIR" 2>/dev/null || true
  ok "Lab removed. The VM is back to its pre-lab state."
}

usage() {
  cat <<USAGE
KCSA 1.2 Break & Fix — exposed cloud metadata endpoint

Usage: sudo $0 [command]

Commands:
  run        (default) build the lab, inject the fault, print the mission
  setup      build the healthy lab only (no fault)
  break      inject the fault into an already-built lab
  verify     check whether you have fixed it (exit 0 = PASS)
  solve      apply the reference fix (instructor demo)
  cleanup    remove everything this lab created
  help       show this text

Set LAB_CONFIRM=1 to skip the interactive disposable-VM confirmation.
USAGE
}

main() {
  local cmd="${1:-run}"
  case "$cmd" in
    run)
      need_root run; confirm_lab; preflight; setup; do_break; mission ;;
    setup)
      need_root setup; confirm_lab; preflight; setup ;;
    break)
      need_root break; preflight; do_break; mission ;;
    verify)
      need_root verify; verify ;;
    solve)
      need_root solve; solve ;;
    cleanup)
      need_root cleanup; cleanup ;;
    help|-h|--help)
      usage ;;
    *)
      err "Unknown command: $cmd"; usage; exit 2 ;;
  esac
}

main "$@"

# ===========================================================================
# SOLUTION — step by step (do not read until you have tried it)
# ===========================================================================
#
# The fault: the iptables OUTPUT rule that denied the workload identity egress
# to the cloud metadata IP (169.254.169.254) was removed, so a compromised Pod
# can now steal the node's cloud credentials. The fix is to reinstate that
# host-level egress restriction. Locally-originated packets traverse the
# OUTPUT chain, and the `owner` match lets us scope the block to the workload
# uid while leaving system agents (root, cloud-init, kubelet) unaffected.
#
# 1) Confirm the leak the way the exam scenario would — as the workload:
#
#      runuser -u metaworkload -- \
#        curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/lab-node-role
#
#    You will see the fake AccessKeyId / SecretAccessKey / Token. That is the
#    node identity any pod on this host could exfiltrate.
#
# 2) Inspect the OUTPUT chain and confirm no guard rule is present:
#
#      iptables -S OUTPUT | grep -i metadata || echo "no guard rule present"
#
# 3) Reinstate the egress guard (REJECT is used here for an instant, teachable
#    failure; production hardening typically uses DROP so the endpoint appears
#    to simply not exist):
#
#      iptables -A OUTPUT -d 169.254.169.254/32 -p tcp --dport 80 \
#        -m owner --uid-owner metaworkload \
#        -m comment --comment "kcsa-1.2-metadata-guard" \
#        -j REJECT --reject-with icmp-port-unreachable
#
# 4) Verify the same probe is now denied (empty body / "Connection refused"):
#
#      runuser -u metaworkload -- \
#        curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/lab-node-role
#      echo "exit=$?"
#
#    Or use the built-in checker:
#
#      sudo ./this.sh verify        # expect: PASS
#
# 5) (Optional) Persist the rule so a reboot does not silently re-expose the
#    node — the same lesson as making hardening declarative:
#
#      # Debian/Ubuntu:  apt-get install -y iptables-persistent && netfilter-persistent save
#      # RHEL/Fedora:    iptables-save > /etc/sysconfig/iptables
#
# ---------------------------------------------------------------------------
# How this maps to real clusters (KCSA 1.2, Cloud Provider & Infrastructure
# Security). The single host rule above is a model of controls you apply for
# real:
#
#   * Kubernetes NetworkPolicy — default-deny egress from workload namespaces,
#     explicitly blocking 169.254.169.254/32, so pods cannot reach the IMDS:
#
#       apiVersion: networking.k8s.io/v1
#       kind: NetworkPolicy
#       metadata:
#         name: deny-cloud-metadata
#         namespace: apps
#       spec:
#         podSelector: {}
#         policyTypes: ["Egress"]
#         egress:
#           - to:
#               - ipBlock:
#                   cidr: 0.0.0.0/0
#                   except:
#                     - 169.254.169.254/32
#
#   * AWS IMDSv2 with a hop limit of 1 (metadata requests require a signed
#     token and cannot be relayed through a pod's extra network hop):
#       aws ec2 modify-instance-metadata-options \
#         --instance-id <id> --http-tokens required --http-put-response-hop-limit 1
#
#   * GKE: enable Workload Identity, which conceals the node metadata endpoint
#     from pods and issues per-workload identities instead of node-wide creds.
#
# References:
#   - Securing a Cluster (restricting cloud metadata API access):
#     https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
#   - IMDSv2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
#   - GKE Workload Identity: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
# ===========================================================================