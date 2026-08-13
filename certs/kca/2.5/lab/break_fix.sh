#!/usr/bin/env bash
# =============================================================================
#  KCA — Domain 2 (Installation & Configuration) — Topic 2.5
#  HIGH AVAILABILITY INSTALLATIONS — exam weight 3.0
#
#  BREAK & FIX laboratory.  DISPOSABLE VM ONLY.
#
#  WHAT IT DOES
#    Injects ONE controlled, reversible fault into the control plane of a
#    kubeadm lab node, prints the symptom the student is about to meet and the
#    goal they must reach, and can later grade the repair (--verify).
#
#    Scenario is auto-selected from the topology it finds:
#      lb        an HAProxy control-plane load balancer is present
#                -> its backend is pointed at a dead port (LB fails, API alive)
#      endpoint  controlPlaneEndpoint is a DNS name (VIP in front of the API)
#                -> the name is blackholed to 192.0.2.10 (RFC 5737 TEST-NET-1)
#      etcd      plain stacked-etcd node (default fallback)
#                -> etcd's client port is moved off the kubeadm default 2379
#
#  SAFETY CONTRACT
#    * Requires root and an explicit confirmation (KCA_LAB_CONFIRM=yes, the
#      sentinel file /etc/kca-lab, or typing BREAK-MY-LAB at the prompt).
#    * Refuses to inject into an already-unhealthy or already-broken cluster.
#    * Every file it edits is copied to /var/lib/kca-2.5-ha/backup FIRST.
#    * It never touches /var/lib/etcd (etcd data), /etc/kubernetes/pki, any
#      workload, or any cloud/infra resource. Only text config is modified.
#    * --restore rolls everything back from those backups.
#
#  USAGE
#    sudo ./ha-break-fix.sh                    # inject (auto scenario)
#    sudo ./ha-break-fix.sh --scenario etcd    # force a scenario
#    sudo ./ha-break-fix.sh --brief            # reprint the briefing
#    sudo ./ha-break-fix.sh --verify           # grade the repair
#    sudo ./ha-break-fix.sh --restore          # emergency rollback
#
#  SOURCES
#    KCA curriculum ....... https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    HA topologies ........ https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/
#    HA with kubeadm ...... https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
#    Static pods .......... https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
#    etcd clustering ...... https://etcd.io/docs/v3.5/op-guide/clustering/
#    etcd recovery ........ https://etcd.io/docs/v3.5/op-guide/recovery/
# =============================================================================

set -Eeuo pipefail

LAB="kca-2.5-ha"
STATE_DIR="/var/lib/${LAB}"
BACKUP_DIR="${STATE_DIR}/backup"
STATE_FILE="${STATE_DIR}/state.env"

K8S_DIR="/etc/kubernetes"
MANIFESTS="${K8S_DIR}/manifests"
ETCD_MF="${MANIFESTS}/etcd.yaml"
APISERVER_MF="${MANIFESTS}/kube-apiserver.yaml"
ADMIN_CONF="${K8S_DIR}/admin.conf"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

ETCD_GOOD_PORT=2379
ETCD_BAD_PORT=2382
LB_GOOD_PORT=6443
LB_BAD_PORT=6444
BLACKHOLE_IP="192.0.2.10"      # RFC 5737 TEST-NET-1, guaranteed non-routable

SCENARIO=""
ACTION="inject"

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; BLD=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; BLD=""; N=""
fi

log()  { printf '%s[ lab ]%s %s\n' "${B}" "${N}" "$*"; }
ok()   { printf '%s[  ok ]%s %s\n' "${G}" "${N}" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "${Y}" "${N}" "$*"; }
bad()  { printf '%s[fail ]%s %s\n' "${R}" "${N}" "$*"; }
die()  { bad "$*"; exit 1; }
rule() { printf '%s%s%s\n' "${BLD}" "$(printf '=%.0s' {1..78})" "${N}"; }

trap 'bad "aborted at line ${LINENO}. Nothing else was changed; run --restore if unsure."' ERR

# ---------------------------------------------------------------- helpers ----
kc() { kubectl --kubeconfig "${ADMIN_CONF}" "$@"; }

have() { command -v "$1" >/dev/null 2>&1; }

is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

save_state() { install -d -m 0700 "${STATE_DIR}"; printf '%s\n' "$@" >> "${STATE_FILE}"; }

load_state() { [[ -f "${STATE_FILE}" ]] && . "${STATE_FILE}" || true; }

backup_file() {
  local f="$1" dest
  install -d -m 0700 "${BACKUP_DIR}"
  dest="${BACKUP_DIR}/$(printf '%s' "${f#/}" | tr '/' '_')"
  [[ -e "${dest}" ]] || cp -a "${f}" "${dest}"
  printf '%s\n' "${dest}"
}

# Full control-plane endpoint the local kubeconfig points at, e.g. https://k8s-api.lab:6443
cp_endpoint_url() {
  awk '/^[[:space:]]*server:[[:space:]]*http/{print $2; exit}' "${ADMIN_CONF}" 2>/dev/null || true
}
cp_endpoint_host() { cp_endpoint_url | sed -E 's#^https?://##; s#:[0-9]+$##; s#^\[##; s#\]$##'; }
cp_endpoint_port() { local u; u="$(cp_endpoint_url)"; [[ "${u}" =~ :([0-9]+)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}" || printf '443\n'; }

api_healthy() {
  local host="${1:-127.0.0.1}" port="${2:-6443}"
  [[ "$(curl -sk --max-time 5 "https://${host}:${port}/healthz" 2>/dev/null || true)" == "ok" ]]
}

wait_until_broken() {
  local host="$1" port="$2" i
  log "waiting for the fault to become visible (kubelet resync / LB reload)..."
  for i in $(seq 1 40); do
    api_healthy "${host}" "${port}" || { ok "fault is live after ~$((i*3))s"; return 0; }
    sleep 3
  done
  warn "the endpoint still answers after 120s — inspect manually before handing this to a student"
}

lb_applicable() {
  [[ -f "${HAPROXY_CFG}" ]] && have haproxy &&
    grep -qE "^[[:space:]]*server[[:space:]]+\S+[[:space:]]+\S+:${LB_GOOD_PORT}([[:space:]]|$)" "${HAPROXY_CFG}"
}

pick_scenario() {
  local host="$1"
  if lb_applicable;                 then printf 'lb\n'
  elif [[ -n "${host}" ]] && ! is_ipv4 "${host}" && [[ "${host}" != "localhost" ]]; then printf 'endpoint\n'
  else printf 'etcd\n'
  fi
}

# ------------------------------------------------------------- preflight ----
preflight() {
  [[ ${EUID} -eq 0 ]] || die "run me as root (sudo $0)"
  [[ -d "${MANIFESTS}" ]] || die "${MANIFESTS} not found — this is not a kubeadm control-plane node"
  [[ -f "${ADMIN_CONF}" ]] || die "${ADMIN_CONF} not found — this is not a kubeadm control-plane node"
  have curl || die "curl is required"
  have sed  || die "sed is required"
}

confirm_disposable() {
  rule
  printf '%s DESTRUCTIVE LAB — this breaks the control plane of THIS machine.%s\n' "${BLD}${R}" "${N}"
  printf ' Node       : %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf ' Endpoint   : %s\n' "$(cp_endpoint_url)"
  if have kubectl && kc get nodes >/dev/null 2>&1; then
    printf ' Nodes seen : %s (ALL of them must be disposable)\n' "$(kc get nodes --no-headers 2>/dev/null | wc -l)"
  fi
  rule
  if [[ "${KCA_LAB_CONFIRM:-}" == "yes" || -f /etc/kca-lab ]]; then
    log "confirmation supplied out of band (KCA_LAB_CONFIRM / /etc/kca-lab)"
    return 0
  fi
  local answer=""
  read -r -p "Type BREAK-MY-LAB to continue, anything else to abort: " answer || true
  [[ "${answer}" == "BREAK-MY-LAB" ]] || die "aborted — nothing was changed"
}

assert_clean_start() {
  [[ ! -f "${STATE_FILE}" ]] || die "a fault is already injected (see ${STATE_FILE}). Run --brief, --verify or --restore."
  api_healthy 127.0.0.1 6443 || die "the local kube-apiserver is already unhealthy — fix the cluster before injecting a lab fault"
  ok "control plane healthy at https://127.0.0.1:6443/healthz — safe to inject"
}

# ------------------------------------------------------------ scenario: etcd -
break_etcd() {
  [[ -f "${ETCD_MF}" ]] || die "${ETCD_MF} not found — no stacked etcd on this node; try --scenario endpoint"
  grep -q -- "--listen-client-urls=.*:${ETCD_GOOD_PORT}" "${ETCD_MF}" \
    || die "etcd is not on the default client port ${ETCD_GOOD_PORT}; refusing to guess"

  backup_file "${ETCD_MF}" >/dev/null
  # Move ONLY the client-facing URLs. Peer (2380), metrics/health (2381) and the
  # data directory are untouched, so the etcd pod itself stays green — which is
  # exactly what makes this a good diagnosis exercise.
  sed -i -E "/--(listen|advertise)-client-urls=/ s/:${ETCD_GOOD_PORT}/:${ETCD_BAD_PORT}/g" "${ETCD_MF}"
  touch "${ETCD_MF}"
  save_state "SCENARIO=etcd" "TARGET=${ETCD_MF}" "BAD_PORT=${ETCD_BAD_PORT}"
  ok "injected: etcd client URLs moved ${ETCD_GOOD_PORT} -> ${ETCD_BAD_PORT}"
  wait_until_broken 127.0.0.1 6443
}

brief_etcd() {
cat <<EOF

$(rule)
${BLD}KCA 2.5 — HIGH AVAILABILITY INSTALLATIONS — INCIDENT #1: "the quorum you did not have"${N}
$(rule)

${BLD}SYMPTOM${N} (reproduce it now)

  \$ kubectl get nodes
  The connection to the server $(cp_endpoint_host):$(cp_endpoint_port) was refused - did you specify the right host or port?

  \$ curl -sk https://127.0.0.1:6443/healthz
  curl: (7) Failed to connect to 127.0.0.1 port 6443: Connection refused

  The node itself is up, the kubelet is running, your workload Pods keep running
  (the kubelet does not need the API server to keep existing containers alive).
  Only the control plane is gone. You have NO kubectl. Everything you do from
  here on is host-level forensics.

${BLD}WHAT IS TRUE${N}

  * Nothing was deleted. No etcd data, no PKI, no manifest file removed.
  * One line of one static Pod manifest under ${MANIFESTS} is wrong.
  * The etcd container is RUNNING and its liveness probe is GREEN. Do not stop
    at "etcd is up, so etcd is fine" — that is the trap.

${BLD}YOUR MISSION${N}

  1. Diagnose without kubectl: crictl, journalctl -u kubelet, /var/log/pods,
     ss -lntp, and the manifests themselves.
  2. Find WHO cannot talk to WHOM, and on which port.
  3. Repair the cluster so that it converges on the kubeadm defaults
     (etcd client 2379, peer 2380). Restoring service on a hand-picked custom
     port is NOT a pass: a node joined later with 'kubeadm join --control-plane'
     writes manifests that assume 2379 and would never reach this member.
  4. Prove the fix with etcdctl endpoint status and /readyz?verbose.

${BLD}RULES${N}

  * Do not 'kubeadm reset'. Do not restore from ${BACKUP_DIR} — the backup is a
    fire escape for the instructor, not the exercise.
  * Do not delete /var/lib/etcd. If you find yourself typing that, stop and read
    the apiserver log again.

${BLD}SUCCESS CRITERIA${N} (checked by: sudo $0 --verify)

  * etcd.yaml and kube-apiserver.yaml agree on 127.0.0.1:2379
  * crictl shows etcd + kube-apiserver Running, not restarting
  * kubectl get --raw='/readyz?verbose' returns ok for every check
  * etcdctl endpoint status --cluster lists the member(s) healthy

${BLD}WHY THIS IS AN HA TOPIC${N}

  On this single stacked-etcd node the blast radius is the whole cluster. In the
  stacked HA topology (3 control-plane nodes, etcd co-located) this same edit on
  ONE node takes that member out of the raft quorum, 2/3 members remain, the API
  stays up through the load balancer and a student would see only a degraded
  member. Quorum is floor(n/2)+1: 3 members survive 1 failure, 5 survive 2, and
  an even number buys you nothing. That difference — total outage vs degraded —
  is the entire argument for HA installations.
  https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/

EOF
}

verify_etcd() {
  local rc=0 out=""
  if grep -q -- "--listen-client-urls=.*:${ETCD_GOOD_PORT}" "${ETCD_MF}" &&
     grep -q -- "--advertise-client-urls=.*:${ETCD_GOOD_PORT}" "${ETCD_MF}" &&
     ! grep -q ":${ETCD_BAD_PORT}" "${ETCD_MF}"; then
    ok "etcd.yaml back on the kubeadm default client port ${ETCD_GOOD_PORT}"
  else
    bad "etcd.yaml still does not serve clients on ${ETCD_GOOD_PORT}"; rc=1
  fi

  if grep -q -- "--etcd-servers=.*127.0.0.1:${ETCD_GOOD_PORT}" "${APISERVER_MF}"; then
    ok "kube-apiserver still targets 127.0.0.1:${ETCD_GOOD_PORT} (you did not paper over it)"
  else
    bad "kube-apiserver --etcd-servers was changed; the cluster must converge on ${ETCD_GOOD_PORT}"; rc=1
  fi

  if api_healthy 127.0.0.1 6443; then ok "local kube-apiserver answers /healthz"
  else bad "kube-apiserver is still not serving on 127.0.0.1:6443"; rc=1; fi

  if have kubectl && out="$(kc get --raw='/readyz?verbose' 2>/dev/null)"; then
    if grep -q '^readyz check passed' <<<"${out}"; then ok "/readyz check passed"
    else bad "/readyz reports failures:"; grep -v '\[+\]' <<<"${out}" | head -5; rc=1; fi
  else
    bad "kubectl cannot reach the API server"; rc=1
  fi
  return "${rc}"
}

restore_etcd() {
  local b="${BACKUP_DIR}/$(printf '%s' "${ETCD_MF#/}" | tr '/' '_')"
  [[ -f "${b}" ]] || die "no backup for ${ETCD_MF}"
  cp -a "${b}" "${ETCD_MF}"; touch "${ETCD_MF}"
  ok "restored ${ETCD_MF}; kubelet will recreate the static Pod within ~20s"
}

# -------------------------------------------------------------- scenario: lb -
break_lb() {
  lb_applicable || die "no usable HAProxy control-plane config at ${HAPROXY_CFG}"
  backup_file "${HAPROXY_CFG}" >/dev/null
  sed -i -E "/^[[:space:]]*server[[:space:]]/ s/:${LB_GOOD_PORT}([[:space:]]|$)/:${LB_BAD_PORT}\1/" "${HAPROXY_CFG}"
  if ! haproxy -c -f "${HAPROXY_CFG}" >/dev/null 2>&1; then
    cp -a "${BACKUP_DIR}/$(printf '%s' "${HAPROXY_CFG#/}" | tr '/' '_')" "${HAPROXY_CFG}"
    die "edited config failed 'haproxy -c'; rolled back, nothing broken. Use --scenario etcd."
  fi
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
  save_state "SCENARIO=lb" "TARGET=${HAPROXY_CFG}" "BAD_PORT=${LB_BAD_PORT}"
  ok "injected: HAProxy control-plane backend moved ${LB_GOOD_PORT} -> ${LB_BAD_PORT}"
  wait_until_broken "$(cp_endpoint_host)" "$(cp_endpoint_port)"
}

brief_lb() {
cat <<EOF

$(rule)
${BLD}KCA 2.5 — HIGH AVAILABILITY INSTALLATIONS — INCIDENT #2: "the API is up, nobody can reach it"${N}
$(rule)

${BLD}SYMPTOM${N} (reproduce it now)

  \$ kubectl get nodes
  Unable to connect to the server: EOF

  \$ curl -sk https://$(cp_endpoint_host):$(cp_endpoint_port)/healthz
  curl: (52) Empty reply from server        # or (56) connection reset by peer

  and yet, on this very node:

  \$ curl -sk https://127.0.0.1:6443/healthz
  ok

  Within a few minutes 'kubectl get nodes' (once it works again) will show nodes
  going NotReady: every kubelet, kube-proxy, controller-manager and scheduler
  reaches the API through the same controlPlaneEndpoint you just lost.

${BLD}WHAT IS TRUE${N}

  * The kube-apiserver process is healthy. etcd is healthy. Certificates are valid.
  * The TCP listener on the VIP is UP — connections are ACCEPTED and then closed.
    That distinction (accept-then-close vs connection refused) is the clue: the
    frontend is fine, the backend is not.
  * One text file on this host is wrong. The load balancer is happily doing
    exactly what it was told.

${BLD}YOUR MISSION${N}

  1. Prove the API server itself is innocent (loopback + client cert, /healthz).
  2. Inspect the LB path: systemctl status haproxy, ss -lntp, the runtime backend
     state, and ${HAPROXY_CFG}.
  3. Repair the load balancer so the controlPlaneEndpoint serves the API again,
     and validate the config BEFORE reloading (never restart a control-plane LB
     on an unvalidated config).
  4. Explain in one sentence why 'kubectl --server https://127.0.0.1:6443' is a
     workaround and not a fix.

${BLD}RULES${N}

  * Do not edit any kubeconfig to bypass the VIP. The endpoint is baked into
    admin.conf, kubelet.conf, controller-manager.conf, scheduler.conf, the
    kubeadm-config ConfigMap and the apiserver certificate SANs.
  * Do not restore from ${BACKUP_DIR}.

${BLD}SUCCESS CRITERIA${N} (checked by: sudo $0 --verify)

  * haproxy -c -f ${HAPROXY_CFG} passes and the unit is active
  * every control-plane backend server targets port ${LB_GOOD_PORT}
  * curl -sk https://$(cp_endpoint_host):$(cp_endpoint_port)/healthz returns ok
  * kubectl get --raw='/readyz?verbose' passes through the endpoint

${BLD}WHY THIS IS AN HA TOPIC${N}

  kubeadm HA is 'N control-plane nodes behind ONE stable endpoint'. The LB is not
  an accessory, it is the cluster's address: --control-plane-endpoint is written
  once at 'kubeadm init' and every later join, every kubelet bootstrap and every
  certificate SAN depends on it. An LB with correct health checks (tcp-check on
  6443, or GET /readyz) removes a failed apiserver from rotation in seconds; an
  LB pointed at the wrong port takes the whole cluster down while three perfectly
  healthy API servers watch. Health-check correctness IS the availability.
  https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/

EOF
}

verify_lb() {
  local rc=0 host port
  host="$(cp_endpoint_host)"; port="$(cp_endpoint_port)"
  if grep -qE "^[[:space:]]*server[[:space:]]+\S+[[:space:]]+\S+:${LB_BAD_PORT}([[:space:]]|$)" "${HAPROXY_CFG}"; then
    bad "a control-plane backend still points at :${LB_BAD_PORT}"; rc=1
  else
    ok "no backend left on the dead port"
  fi
  if haproxy -c -f "${HAPROXY_CFG}" >/dev/null 2>&1; then ok "haproxy config validates"
  else bad "haproxy -c fails on ${HAPROXY_CFG}"; rc=1; fi
  if systemctl is-active --quiet haproxy; then ok "haproxy unit is active"
  else bad "haproxy unit is not active"; rc=1; fi
  if api_healthy "${host}" "${port}"; then ok "https://${host}:${port}/healthz returns ok"
  else bad "the control-plane endpoint still does not serve /healthz"; rc=1; fi
  if have kubectl && kc get --raw='/readyz' >/dev/null 2>&1; then ok "kubectl works through the endpoint"
  else bad "kubectl still cannot reach the API through the endpoint"; rc=1; fi
  return "${rc}"
}

restore_lb() {
  local b="${BACKUP_DIR}/$(printf '%s' "${HAPROXY_CFG#/}" | tr '/' '_')"
  [[ -f "${b}" ]] || die "no backup for ${HAPROXY_CFG}"
  cp -a "${b}" "${HAPROXY_CFG}"
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy || true
  ok "restored ${HAPROXY_CFG} and reloaded haproxy"
}

# -------------------------------------------------------- scenario: endpoint -
break_endpoint() {
  local host orig
  host="$(cp_endpoint_host)"
  [[ -n "${host}" ]] || die "cannot read the control-plane endpoint from ${ADMIN_CONF}"
  is_ipv4 "${host}" && die "controlPlaneEndpoint is a bare IP (${host}); use --scenario etcd or lb"
  orig="$(getent hosts "${host}" | awk '{print $1; exit}' || true)"

  backup_file /etc/hosts >/dev/null
  awk -v h="${host}" '{d=0; for(i=2;i<=NF;i++) if ($i==h) d=1} d==0' /etc/hosts > "${STATE_DIR}/hosts.new"
  install -m 0644 "${STATE_DIR}/hosts.new" /etc/hosts && rm -f "${STATE_DIR}/hosts.new"
  printf '%s %s\n' "${BLACKHOLE_IP}" "${host}" >> /etc/hosts

  save_state "SCENARIO=endpoint" "TARGET=/etc/hosts" "EP_HOST=${host}" "EP_ORIG_IP=${orig:-unknown}"
  ok "injected: ${host} now resolves to ${BLACKHOLE_IP} (was ${orig:-unresolved})"
  wait_until_broken "${host}" "$(cp_endpoint_port)"
}

brief_endpoint() {
  local host port
  host="$(cp_endpoint_host)"; port="$(cp_endpoint_port)"
cat <<EOF

$(rule)
${BLD}KCA 2.5 — HIGH AVAILABILITY INSTALLATIONS — INCIDENT #3: "the VIP went dark"${N}
$(rule)

${BLD}SYMPTOM${N} (reproduce it now)

  \$ kubectl get nodes
  Unable to connect to the server: dial tcp ${BLACKHOLE_IP}:${port}: i/o timeout

  It hangs for ~30s before failing — a timeout, not a refusal: packets leave and
  nothing answers. Meanwhile, on this node:

  \$ curl -sk https://127.0.0.1:6443/healthz
  ok

  \$ journalctl -u kubelet -n 20 --no-pager
  ... "Failed to contact API server" ... dial tcp ${BLACKHOLE_IP}:${port}: i/o timeout

  The kubelet uses the same endpoint, so this node will drift to NotReady and
  node-lease renewal will fail. Running Pods survive; nothing new is scheduled.

${BLD}WHAT IS TRUE${N}

  * The API server, etcd, the certificates and every kubeconfig are correct.
  * The cluster's stable address, ${host}, no longer points where it should.
  * ${BLACKHOLE_IP} is RFC 5737 documentation space: it exists to be a black hole.

${BLD}YOUR MISSION${N}

  1. Separate NAME resolution from ROUTING from SERVICE: getent hosts, then
     'curl -sk --resolve' against a candidate IP, then /healthz.
  2. Discover what ${host} is SUPPOSED to resolve to — without guessing. The
     apiserver serving certificate is the authority; kubeadm put the endpoint in
     its SANs at init time, next to the node IP and the kubernetes.default names.
  3. Repair resolution and confirm the kubelet reattaches on its own.

${BLD}RULES${N}

  * Do not rewrite kubeconfigs to 127.0.0.1. Every joined node and every
    kubeadm-generated cert expects ${host}; bypassing it hides the fault.
  * Do not restore from ${BACKUP_DIR}.

${BLD}SUCCESS CRITERIA${N} (checked by: sudo $0 --verify)

  * getent hosts ${host} resolves to a reachable address
  * curl -sk https://${host}:${port}/healthz returns ok
  * kubectl get --raw='/readyz?verbose' passes and this node is Ready again

${BLD}WHY THIS IS AN HA TOPIC${N}

  In an HA installation the controlPlaneEndpoint is a VIP (keepalived/VRRP) or a
  DNS record in front of N API servers. It is a single logical address on purpose
  — and therefore a single point of failure if the layer that publishes it (DNS,
  VRRP, an LB health check) fails. That is why the endpoint must be set at
  'kubeadm init' even for a single control-plane node you might grow later:
  changing it afterwards means reissuing certificates with new SANs and rewriting
  every kubeconfig in the cluster.
  https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/

EOF
}

verify_endpoint() {
  local rc=0 host port resolved
  load_state
  host="${EP_HOST:-$(cp_endpoint_host)}"; port="$(cp_endpoint_port)"
  resolved="$(getent hosts "${host}" | awk '{print $1; exit}' || true)"
  if [[ -z "${resolved}" ]]; then bad "${host} does not resolve at all"; rc=1
  elif [[ "${resolved}" == "${BLACKHOLE_IP}" ]]; then bad "${host} still resolves to the black hole ${BLACKHOLE_IP}"; rc=1
  else ok "${host} resolves to ${resolved}"; fi

  if api_healthy "${host}" "${port}"; then ok "https://${host}:${port}/healthz returns ok"
  else bad "the endpoint does not serve /healthz"; rc=1; fi

  if have kubectl && kc get --raw='/readyz' >/dev/null 2>&1; then ok "kubectl works through the endpoint"
  else bad "kubectl still cannot reach the API through the endpoint"; rc=1; fi

  if have kubectl && kc get nodes --no-headers 2>/dev/null | grep -qE '\sNotReady'; then
    warn "some nodes are still NotReady — give the kubelet ~60s and re-run --verify"
  fi
  return "${rc}"
}

restore_endpoint() {
  local b="${BACKUP_DIR}/etc_hosts"
  [[ -f "${b}" ]] || die "no backup for /etc/hosts"
  cp -a "${b}" /etc/hosts
  ok "restored /etc/hosts"
}

# ------------------------------------------------------------------- flow ----
do_inject() {
  preflight
  local host; host="$(cp_endpoint_host)"
  [[ -n "${SCENARIO}" ]] || SCENARIO="$(pick_scenario "${host}")"
  log "scenario selected: ${BLD}${SCENARIO}${N}"
  confirm_disposable
  assert_clean_start
  install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}"
  case "${SCENARIO}" in
    etcd)     break_etcd;     brief_etcd ;;
    lb)       break_lb;       brief_lb ;;
    endpoint) break_endpoint; brief_endpoint ;;
    *) die "unknown scenario '${SCENARIO}' (etcd|lb|endpoint)" ;;
  esac
  log "backups live in ${BACKUP_DIR} — instructor fire escape only"
  log "grade the repair with: sudo $0 --verify"
}

do_brief() {
  load_state
  [[ -n "${SCENARIO:-}" ]] || die "no lab in progress (no ${STATE_FILE})"
  case "${SCENARIO}" in etcd) brief_etcd ;; lb) brief_lb ;; endpoint) brief_endpoint ;; esac
}

do_verify() {
  preflight; load_state
  [[ -n "${SCENARIO:-}" ]] || die "no lab in progress (no ${STATE_FILE})"
  rule; log "grading scenario '${SCENARIO}'"; rule
  local rc=0
  case "${SCENARIO}" in
    etcd)     verify_etcd     || rc=1 ;;
    lb)       verify_lb       || rc=1 ;;
    endpoint) verify_endpoint || rc=1 ;;
  esac
  rule
  if [[ "${rc}" -eq 0 ]]; then
    printf '%s PASS — the control plane is healthy and the fix is the right one.%s\n' "${G}${BLD}" "${N}"
    printf ' Clear the lab state with: sudo rm -rf %s\n' "${STATE_DIR}"
  else
    printf '%s NOT YET — keep digging. Re-read the briefing: sudo %s --brief%s\n' "${Y}${BLD}" "$0" "${N}"
  fi
  return "${rc}"
}

do_restore() {
  preflight; load_state
  [[ -n "${SCENARIO:-}" ]] || die "no lab in progress (no ${STATE_FILE})"
  warn "rolling back scenario '${SCENARIO}' from ${BACKUP_DIR}"
  case "${SCENARIO}" in
    etcd)     restore_etcd ;;
    lb)       restore_lb ;;
    endpoint) restore_endpoint ;;
  esac
  rm -f "${STATE_FILE}"
  log "give the control plane up to 60s, then: kubectl get --raw='/readyz?verbose'"
}

usage() {
cat <<EOF
KCA 2.5 High Availability Installations — break & fix lab (DISPOSABLE VM ONLY)

  sudo $0 [--scenario etcd|lb|endpoint]   inject a fault (auto-selected by default)
  sudo $0 --brief                         reprint the current briefing
  sudo $0 --verify                        grade the repair
  sudo $0 --restore                       roll back from backups
  sudo $0 --help

  KCA_LAB_CONFIRM=yes  or  /etc/kca-lab   skip the interactive confirmation
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="${2:-}"; shift 2 ;;
    --scenario=*) SCENARIO="${1#*=}"; shift ;;
    --brief)   ACTION="brief";   shift ;;
    --verify)  ACTION="verify";  shift ;;
    --restore) ACTION="restore"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument '$1'" ;;
  esac
done

case "${ACTION}" in
  inject)  do_inject ;;
  brief)   do_brief ;;
  verify)  do_verify ;;
  restore) do_restore ;;
esac

# =============================================================================
#  S O L U T I O N  —  do not read before you have tried
# =============================================================================
#
# -----------------------------------------------------------------------------
# SCENARIO "etcd" — etcd client URLs moved off 2379
# -----------------------------------------------------------------------------
#
# 1. Establish what is dead. kubectl is useless, so start below it.
#
#      $ kubectl get nodes
#      The connection to the server k8s-api.lab:6443 was refused - did you specify the right host or port?
#      $ systemctl is-active kubelet
#      active
#
#    Kubelet alive + API dead => the control plane is static Pods, and static
#    Pods live in /etc/kubernetes/manifests. This is always the first fork.
#
# 2. Look at the control plane through the container runtime, the only view left:
#
#      $ crictl ps -a --name 'kube-apiserver|etcd' -o table
#      CONTAINER     IMAGE          CREATED         STATE      NAME             ATTEMPT
#      9f1c0a...     a0eed15eed44   12 seconds ago  Exited     kube-apiserver   7
#      3b7e41...     4fc9c46a6cfb   9 minutes ago   Running    etcd             0
#
#    etcd Running, apiserver Exited with a climbing ATTEMPT counter => the
#    apiserver is crash-looping. etcd is NOT innocent just because it is green:
#    kubeadm probes etcd on the metrics port 2381, which was never touched.
#
# 3. Read the crash reason:
#
#      $ crictl logs --tail 20 $(crictl ps -a --name kube-apiserver -q | head -1)
#      W ... Failed to get etcd status: ... dial tcp 127.0.0.1:2379: connect: connection refused
#      F ... failed to storage-backend initialization: context deadline exceeded
#
#    Same log without crictl:
#      $ tail -40 /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log
#      $ journalctl -u kubelet -n 50 --no-pager | grep -i etcd
#
# 4. Confront the claim with reality — who is listening?
#
#      $ ss -lntp | grep -E ':(2379|2380|2381|2382)'
#      LISTEN 0 4096 127.0.0.1:2381  users:(("etcd",pid=2411,fd=8))
#      LISTEN 0 4096 127.0.0.1:2382  users:(("etcd",pid=2411,fd=10))   <-- wrong
#      LISTEN 0 4096  10.0.0.11:2380 users:(("etcd",pid=2411,fd=12))
#
#    Port 2379 is absent. etcd is serving clients on 2382 while every client in
#    the cluster is hardcoded to 2379.
#
# 5. Confirm in the manifests, side by side:
#
#      $ grep -E 'client-urls|--etcd-servers' \
#          /etc/kubernetes/manifests/etcd.yaml \
#          /etc/kubernetes/manifests/kube-apiserver.yaml
#      etcd.yaml:    - --advertise-client-urls=https://10.0.0.11:2382
#      etcd.yaml:    - --listen-client-urls=https://127.0.0.1:2382,https://10.0.0.11:2382
#      kube-apiserver.yaml:    - --etcd-servers=https://127.0.0.1:2379
#
# 6. Fix — move etcd back to the kubeadm default, NOT the apiserver to 2382:
#
#      $ cp /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak
#      $ sed -i 's/:2382/:2379/g' /etc/kubernetes/manifests/etcd.yaml
#      (or edit by hand with vi; the file is not watched for syntax, only mtime)
#
#    Why not the other direction: 'kubeadm join --control-plane' renders new
#    manifests from the kubeadm-config ConfigMap using the defaults 2379/2380,
#    and the new member would dial 2379 on this host forever. A cluster whose
#    members disagree about their own port is not highly available, it is a
#    single point of failure with extra steps.
#
# 7. Let the kubelet reconcile. It rescans the manifest directory (inotify plus
#    a 20s fileCheckFrequency sweep) and recreates the Pod:
#
#      $ watch -n2 crictl ps --name 'etcd|kube-apiserver'
#      # only if it does not pick it up within a minute:
#      $ systemctl restart kubelet
#      # if a stale sandbox blocks the new one:
#      $ crictl rmp -f $(crictl pods --name etcd -q)
#
# 8. Verify with etcd's own client, then with the API:
#
#      $ ETCDCTL_API=3 etcdctl \
#          --endpoints=https://127.0.0.1:2379 \
#          --cacert=/etc/kubernetes/pki/etcd/ca.crt \
#          --cert=/etc/kubernetes/pki/etcd/server.crt \
#          --key=/etc/kubernetes/pki/etcd/server.key \
#          endpoint status --cluster --write-out=table
#      +---------------------------+------------------+---------+---------+-----------+
#      |         ENDPOINT          |        ID        | VERSION | DB SIZE | IS LEADER |
#      +---------------------------+------------------+---------+---------+-----------+
#      | https://10.0.0.11:2379    | 8e9e05c52164694d |   3.5.x |  6.1 MB |      true |
#      +---------------------------+------------------+---------+---------+-----------+
#
#      $ ETCDCTL_API=3 etcdctl ... member list -w table    # in HA: 3 or 5 rows, all started
#      $ kubectl get --raw='/readyz?verbose' | tail -3
#      [+]poststarthook/start-kube-apiserver-admission-initializer ok
#      readyz check passed
#      $ kubectl get pods -n kube-system -o wide
#
# 9. HA takeaway. Quorum is floor(n/2)+1. With 3 stacked members this fault costs
#    you one member and zero downtime; with 1 member it costs you the cluster.
#    Sizing: 3 tolerates 1 failure, 5 tolerates 2, even numbers add cost without
#    adding tolerance. Never grow etcd past 5 for availability alone — write
#    latency is bounded by the slowest quorum member.
#    https://etcd.io/docs/v3.5/op-guide/clustering/
#
# -----------------------------------------------------------------------------
# SCENARIO "lb" — HAProxy backend pointed at a dead port
# -----------------------------------------------------------------------------
#
# 1. Prove the API server is innocent before touching the LB:
#
#      $ curl -sk https://127.0.0.1:6443/healthz ; echo
#      ok
#      $ kubectl --kubeconfig /etc/kubernetes/admin.conf --server https://127.0.0.1:6443 \
#          --insecure-skip-tls-verify get --raw='/readyz'
#      ok
#
#    Loopback works, the VIP does not => the fault is between the client and the
#    apiserver, not inside it.
#
# 2. Characterise the failure. 'Empty reply from server' / 'connection reset'
#    means something ACCEPTED the TCP connection and then closed it: a proxy with
#    no live backend. 'Connection refused' would mean nothing is listening at all;
#    'i/o timeout' would mean the packets vanish (routing/DNS/firewall).
#
#      $ ss -lntp | grep -E ':(6443|8443)'
#      LISTEN 0 4096 *:6443 users:(("haproxy",pid=1180,fd=7))
#
# 3. Read the LB state and its config:
#
#      $ systemctl status haproxy --no-pager
#      $ journalctl -u haproxy -n 30 --no-pager
#      ... Server kubernetes-backend/cp1 is DOWN, reason: Layer4 connection problem,
#          info: "Connection refused", check duration: 0ms. 0 active and 0 backup servers left.
#      $ grep -nA6 'backend kubernetes' /etc/haproxy/haproxy.cfg
#      12:backend kubernetes-backend
#      13:  mode tcp
#      14:  option tcp-check
#      15:  balance roundrobin
#      16:  server cp1 10.0.0.11:6444 check fall 3 rise 2     <-- wrong port
#
# 4. Fix, validate, then reload (validate BEFORE reload, always):
#
#      $ sed -i 's/:6444 check/:6443 check/' /etc/haproxy/haproxy.cfg
#      $ haproxy -c -f /etc/haproxy/haproxy.cfg
#      Configuration file is valid
#      $ systemctl reload haproxy        # reload keeps the listener; restart drops connections
#
# 5. Verify end to end, from the endpoint the whole cluster uses:
#
#      $ curl -sk https://k8s-api.lab:6443/healthz ; echo
#      ok
#      $ kubectl get --raw='/readyz?verbose' | tail -1
#      readyz check passed
#      $ kubectl get nodes            # all Ready again within ~1 lease period (40s)
#
# 6. HA takeaway. The load balancer must fail a member FAST and correctly: a TCP
#    check on 6443 only proves the socket is open, while an HTTPS check on
#    /readyz proves the apiserver is actually able to serve. Health-check quality
#    is the difference between "one apiserver died" and "the cluster died". And
#    keep the LB itself redundant (keepalived/VRRP, or a managed LB) — otherwise
#    you have N control-plane nodes behind one SPOF.
#    https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
#
# -----------------------------------------------------------------------------
# SCENARIO "endpoint" — controlPlaneEndpoint blackholed
# -----------------------------------------------------------------------------
#
# 1. Split the problem into name -> address -> service:
#
#      $ grep server: /etc/kubernetes/admin.conf
#          server: https://k8s-api.lab:6443
#      $ getent hosts k8s-api.lab
#      192.0.2.10      k8s-api.lab
#      $ ip -4 -br addr show
#      eth0   UP   10.0.0.11/24
#
#    The endpoint resolves outside every network this node has. 192.0.2.0/24 is
#    RFC 5737 documentation space — it is never a real cluster address.
#
# 2. Find the address it SHOULD have, from the authority that recorded it at
#    'kubeadm init': the apiserver serving certificate SANs.
#
#      $ openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text \
#          | grep -A2 'Subject Alternative Name'
#          DNS:k8s-api.lab, DNS:kubernetes, DNS:kubernetes.default, ...,
#          IP Address:10.96.0.1, IP Address:10.0.0.11
#
#    Cross-check the intent (needs the API up, so keep it as the after-fix check):
#      $ kubectl -n kube-system get cm kubeadm-config -o yaml | grep controlPlaneEndpoint
#
# 3. Confirm the candidate before committing to it:
#
#      $ curl -sk --resolve k8s-api.lab:6443:10.0.0.11 https://k8s-api.lab:6443/healthz ; echo
#      ok
#
# 4. Fix resolution — repair the layer that publishes the VIP. In this lab it is
#    /etc/hosts; in a real HA cluster it is DNS or keepalived/VRRP:
#
#      $ sed -i '/k8s-api.lab/d' /etc/hosts
#      $ echo '10.0.0.11 k8s-api.lab' >> /etc/hosts
#      # real cluster, VIP case:  ip -4 addr show; systemctl status keepalived; journalctl -u keepalived
#
# 5. Verify, and let the kubelet reattach on its own:
#
#      $ getent hosts k8s-api.lab
#      10.0.0.11       k8s-api.lab
#      $ kubectl get --raw='/readyz?verbose' | tail -1
#      readyz check passed
#      $ kubectl get nodes           # NotReady -> Ready within ~40s (node lease)
#      $ journalctl -u kubelet -n 20 --no-pager | tail -3
#
# 6. HA takeaway. --control-plane-endpoint is set once, at init, and everything
#    inherits it: admin.conf, kubelet.conf, controller-manager.conf,
#    scheduler.conf, the kubeadm-config ConfigMap and the apiserver cert SANs.
#    Changing it later means regenerating certificates
#      (kubeadm init phase certs apiserver --apiserver-cert-extra-sans ...)
#    and rewriting every kubeconfig in the cluster. Set it even for a single
#    control-plane node you might scale later; that one flag is the difference
#    between "add a control-plane node" and "rebuild the cluster".
#    https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/
#
# -----------------------------------------------------------------------------
# EMERGENCY (instructor only): sudo ./ha-break-fix.sh --restore
# =============================================================================