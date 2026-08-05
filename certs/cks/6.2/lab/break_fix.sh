#!/usr/bin/env bash
#
# ==============================================================================
#  CKS 1.34 — Domain 6: Monitoring, Logging and Runtime Security
#  Topic 6.2 — Detect threats within physical infrastructure, apps, networks,
#              data, users and workloads          (exam weight: 4 %)
#
#  BREAK & FIX LAB
#
#  Reference syllabus:
#    https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#  Reference documentation used to build this lab:
#    https://falco.org/docs/reference/rules/
#    https://falco.org/docs/reference/daemon/config-options/
#    https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
#    https://man7.org/linux/man-pages/man8/auditctl.8.html
#    https://man7.org/linux/man-pages/man8/ausearch.8.html
#
# ------------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES
#
#  It simulates a post-exploitation scenario on ONE node: an intruder that
#  already owns root on the box does NOT try to hide the payload — it blinds the
#  three detection surfaces that would have caught it:
#
#     LAYER 1  workloads / apps   -> Falco runtime sensor (syscall level)
#     LAYER 2  physical host      -> Linux Audit (auditd) kernel rules
#     LAYER 3  users / API access -> kube-apiserver audit backend
#
#  Then it deploys a benign "malicious-looking" workload that keeps generating
#  the exact behaviour those three layers are supposed to catch. Every sensor
#  stays GREEN in `systemctl status`, and every alert is gone.
#
#  This is the single most common failure mode of a detection stack in
#  production: the sensor is not down, the sensor is deaf.
#
#  !!!  RUN ONLY ON A DISPOSABLE SINGLE-NODE KUBEADM LAB VM.  !!!
#  It rewrites /etc/falco/*, flushes the kernel audit ruleset and patches the
#  kube-apiserver static Pod manifest. Never run it on anything you care about.
#
# ------------------------------------------------------------------------------
#  USAGE
#     sudo ./break_fix.sh --break     # inject the incident (default)
#     sudo ./break_fix.sh --verify    # grade your fix, layer by layer
#     sudo ./break_fix.sh --restore   # emergency rollback (escape hatch)
#     sudo ./break_fix.sh --help
# ==============================================================================

set -euo pipefail

readonly LAB_ID="cks-6.2"
readonly STATE_DIR="/var/lib/${LAB_ID}-lab"
readonly BACKUP_DIR="/var/backups/${LAB_ID}-breakfix"
readonly MANIFEST="${BACKUP_DIR}/MANIFEST.txt"
readonly STATE_FILE="${STATE_DIR}/broken.state"

readonly FALCO_CFG="/etc/falco/falco.yaml"
readonly FALCO_RULESD="/etc/falco/rules.d"
readonly FALCO_OVERRIDE="${FALCO_RULESD}/zz-baseline-tuning.yaml"

readonly AUDITD_RULES="/etc/audit/rules.d/${LAB_ID}-baseline.rules"
readonly AUDIT_KEY_ID="cks-identity"
readonly AUDIT_KEY_K8S="cks-k8s-config"
readonly AUDIT_KEY_EXEC="cks-rootexec"

readonly APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
readonly AUDIT_POLICY_DIR="/etc/kubernetes/audit"
readonly AUDIT_POLICY="${AUDIT_POLICY_DIR}/policy.yaml"
readonly AUDIT_LOG_DIR="/var/log/kubernetes/audit"
readonly AUDIT_LOG="${AUDIT_LOG_DIR}/audit.log"

readonly NS="threat-hunt"
readonly DEPLOY="invoice-worker"

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
  C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BOLD=""
fi

info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step()  { printf '\n%s=== %s ===%s\n' "$C_BOLD" "$*" "$C_RESET"; }
have()  { command -v "$1" >/dev/null 2>&1; }

die() { err "$*"; exit 1; }

# ------------------------------------------------------------------------------
# kubectl wrapper: prefer the admin kubeconfig, we always run as root here
# ------------------------------------------------------------------------------
KUBECTL=""
detect_kubectl() {
  if ! have kubectl; then return 1; fi
  if [[ -r /etc/kubernetes/admin.conf ]]; then
    KUBECTL="kubectl --kubeconfig=/etc/kubernetes/admin.conf"
  else
    KUBECTL="kubectl"
  fi
  $KUBECTL version --request-timeout=10s >/dev/null 2>&1 || return 1
  return 0
}

apiserver_healthy() {
  $KUBECTL get --raw='/livez' --request-timeout=5s >/dev/null 2>&1
}

wait_apiserver() {
  local timeout="${1:-240}" start=$SECONDS
  info "Waiting for kube-apiserver to become live (timeout ${timeout}s)..."
  while (( SECONDS - start < timeout )); do
    if apiserver_healthy; then
      ok "kube-apiserver is live again ($((SECONDS - start))s)"
      return 0
    fi
    sleep 3
  done
  return 1
}

# Force the kubelet to re-create the static Pod: move the manifest out and back.
restart_apiserver() {
  local tmp="/tmp/.${LAB_ID}.kube-apiserver.yaml"
  info "Restarting kube-apiserver (static Pod manifest cycle)..."
  mv "$APISERVER_MANIFEST" "$tmp"
  sleep 15
  mv "$tmp" "$APISERVER_MANIFEST"
  wait_apiserver 240
}

# ------------------------------------------------------------------------------
# Backup bookkeeping — every original file is copied before it is touched
# ------------------------------------------------------------------------------
backup_file() {
  local src="$1" dst
  [[ -e "$src" ]] || { printf 'ABSENT %s\n' "$src" >> "$MANIFEST"; return 0; }
  dst="${BACKUP_DIR}/files${src}"
  mkdir -p "$(dirname "$dst")"
  [[ -e "$dst" ]] || cp -a "$src" "$dst"
  printf 'SAVED  %s\n' "$src" >> "$MANIFEST"
}

restore_file() {
  local src="$1" dst="${BACKUP_DIR}/files$1"
  if [[ -e "$dst" ]]; then
    mkdir -p "$(dirname "$src")"
    cp -a "$dst" "$src"
    ok "restored $src"
  elif grep -qx "ABSENT ${src}" "$MANIFEST" 2>/dev/null; then
    rm -f "$src" && ok "removed $src (did not exist before the lab)"
  fi
}

# ==============================================================================
# LAYER 1 — Falco: the workload/app runtime sensor
# ==============================================================================
falco_present() { have falco || [[ -f "$FALCO_CFG" ]]; }

falco_unit() {
  local u
  for u in falco-modern-bpf falco-bpf falco-kmod falco; do
    if systemctl list-unit-files "${u}.service" >/dev/null 2>&1 && \
       systemctl cat "${u}.service" >/dev/null 2>&1; then
      printf '%s' "$u"; return 0
    fi
  done
  return 1
}

break_layer_falco() {
  step "LAYER 1 — blinding the workload sensor (Falco)"

  if ! falco_present; then
    warn "Falco is not installed on this node — layer skipped."
    warn "Install it before working on this lab:"
    warn "  curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \\"
    warn "    | gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg"
    warn "  echo 'deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg]"\
         "https://download.falco.org/packages/deb stable main' \\"
    warn "    > /etc/apt/sources.list.d/falcosecurity.list"
    warn "  apt-get update && apt-get install -y falco"
    echo "falco=skipped" >> "$STATE_FILE"
    return 0
  fi

  backup_file "$FALCO_CFG"
  backup_file "$FALCO_OVERRIDE"
  mkdir -p "$FALCO_RULESD"

  # Fault 1.a — raise the global priority threshold. Everything below CRITICAL
  # is evaluated by the engine and then silently dropped before output.
  if grep -qE '^[[:space:]]*priority:' "$FALCO_CFG"; then
    sed -i -E 's|^[[:space:]]*priority:.*$|priority: critical|' "$FALCO_CFG"
  else
    printf '\npriority: critical\n' >> "$FALCO_CFG"
  fi

  # Fault 1.b — a "tuning" file that looks like legitimate noise reduction but
  # disables the three rules that would fire on this incident.
  cat > "$FALCO_OVERRIDE" <<'EOF'
# Baseline tuning applied by change CHG-4471 ("reduce alert fatigue").
# Reviewed by: <unknown>
- rule: Write below binary dir
  enabled: false

- rule: Read sensitive file untrusted
  enabled: false

- rule: Terminal shell in container
  enabled: false
EOF
  chmod 0644 "$FALCO_OVERRIDE"

  local unit
  if unit="$(falco_unit)"; then
    systemctl restart "$unit" || warn "could not restart ${unit}.service"
    echo "falco_unit=${unit}" >> "$STATE_FILE"
    ok "Falco muted; ${unit}.service is still $(systemctl is-active "$unit")"
  else
    warn "No Falco systemd unit found; restart the sensor manually."
  fi
  echo "falco=broken" >> "$STATE_FILE"
}

# ==============================================================================
# LAYER 2 — auditd: the physical/host detection surface
# ==============================================================================
auditd_present() { have auditctl && have ausearch; }

break_layer_auditd() {
  step "LAYER 2 — blinding the host sensor (Linux Audit)"

  if ! auditd_present; then
    warn "auditd/auditctl not installed — layer skipped."
    warn "Install it first:  apt-get install -y auditd  |  dnf install -y audit"
    echo "auditd=skipped" >> "$STATE_FILE"
    return 0
  fi

  mkdir -p /etc/audit/rules.d
  backup_file "$AUDITD_RULES"

  # Stage the fleet baseline this node is supposed to run...
  cat > "$AUDITD_RULES" <<EOF
## Fleet detection baseline (${LAB_ID})
-w /etc/shadow -p rwa -k ${AUDIT_KEY_ID}
-w /etc/kubernetes/ -p wa -k ${AUDIT_KEY_K8S}
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k ${AUDIT_KEY_EXEC}
EOF
  chmod 0640 "$AUDITD_RULES"

  # ...and now the tampering: the file is parked with a harmless-looking
  # extension (auditd only loads *.rules) and the live ruleset is flushed,
  # so nothing survives even before the next reboot.
  mv "$AUDITD_RULES" "${AUDITD_RULES}.disabled"
  auditctl -D >/dev/null 2>&1 || true

  ok "Kernel audit ruleset flushed: $(auditctl -l 2>/dev/null | head -n1 || echo 'No rules')"
  if have systemctl; then
    info "auditd.service is still $(systemctl is-active auditd 2>/dev/null || echo unknown)"
  fi
  echo "auditd=broken" >> "$STATE_FILE"
}

# ==============================================================================
# LAYER 3 — kube-apiserver audit backend: the "users" detection surface
# ==============================================================================
apiserver_audit_configured() {
  grep -q -- '--audit-policy-file=' "$APISERVER_MANIFEST" 2>/dev/null
}

patch_apiserver_manifest() {
  local tmp; tmp="$(mktemp)"
  awk '
    BEGIN { a=0; vm=0; v=0 }
    { print }
    /^[[:space:]]*-[[:space:]]kube-apiserver[[:space:]]*$/ && a==0 {
      print "    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml"
      print "    - --audit-log-path=/var/log/kubernetes/audit/audit.log"
      print "    - --audit-log-maxage=7"
      print "    - --audit-log-maxbackup=3"
      print "    - --audit-log-maxsize=50"
      a=1
    }
    /^[[:space:]]{4}volumeMounts:[[:space:]]*$/ && vm==0 {
      print "    - mountPath: /etc/kubernetes/audit"
      print "      name: cks-audit-policy"
      print "      readOnly: true"
      print "    - mountPath: /var/log/kubernetes/audit"
      print "      name: cks-audit-log"
      print "      readOnly: false"
      vm=1
    }
    /^[[:space:]]{2}volumes:[[:space:]]*$/ && v==0 {
      print "  - hostPath:"
      print "      path: /etc/kubernetes/audit"
      print "      type: DirectoryOrCreate"
      print "    name: cks-audit-policy"
      print "  - hostPath:"
      print "      path: /var/log/kubernetes/audit"
      print "      type: DirectoryOrCreate"
      print "    name: cks-audit-log"
      v=1
    }
    END { if (a==0 || vm==0 || v==0) exit 3 }
  ' "$APISERVER_MANIFEST" > "$tmp" || { rm -f "$tmp"; return 1; }

  if have python3; then
    python3 - "$tmp" <<'PY' || { rm -f "$tmp"; return 1; }
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
yaml.safe_load(open(sys.argv[1]))
PY
  fi
  cat "$tmp" > "$APISERVER_MANIFEST"
  rm -f "$tmp"
  return 0
}

break_layer_kubeaudit() {
  step "LAYER 3 — blinding the API access sensor (kube-apiserver audit)"

  if [[ ! -f "$APISERVER_MANIFEST" ]]; then
    warn "No kube-apiserver static Pod manifest on this node — layer skipped."
    warn "Run this lab on the control-plane node of a kubeadm cluster."
    echo "kubeaudit=skipped" >> "$STATE_FILE"
    return 0
  fi

  backup_file "$APISERVER_MANIFEST"
  backup_file "$AUDIT_POLICY"
  mkdir -p "$AUDIT_POLICY_DIR" "$AUDIT_LOG_DIR"

  # The tampered policy: syntactically valid, accepted by the apiserver, and it
  # records absolutely nothing. This is the classic "audit is enabled" lie.
  cat > "$AUDIT_POLICY" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
# CHG-4471: "audit backend was too expensive on this node"
rules:
  - level: None
EOF
  chmod 0600 "$AUDIT_POLICY"

  if ! apiserver_audit_configured; then
    info "Audit backend was not wired up; patching the manifest (flags+volumes)."
    if ! patch_apiserver_manifest; then
      err "Could not patch $APISERVER_MANIFEST safely — layer aborted, nothing changed."
      restore_file "$APISERVER_MANIFEST"
      echo "kubeaudit=skipped" >> "$STATE_FILE"
      return 0
    fi
  fi

  if ! restart_apiserver; then
    err "kube-apiserver did not come back — rolling this layer back automatically."
    restore_file "$APISERVER_MANIFEST"
    restore_file "$AUDIT_POLICY"
    restart_apiserver || err "MANUAL ACTION REQUIRED: inspect 'crictl ps -a' and /var/log/containers"
    echo "kubeaudit=skipped" >> "$STATE_FILE"
    return 0
  fi

  ok "Audit backend enabled and pointed at a policy that logs nothing."
  echo "kubeaudit=broken" >> "$STATE_FILE"
}

# ==============================================================================
# The workload under investigation
# ==============================================================================
deploy_suspicious_workload() {
  step "Deploying the workload you will have to catch"

  if ! detect_kubectl; then
    warn "No reachable cluster — workload not deployed."
    echo "workload=skipped" >> "$STATE_FILE"
    return 0
  fi

  $KUBECTL apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels:
    app: ${DEPLOY}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOY}
  template:
    metadata:
      labels:
        app: ${DEPLOY}
    spec:
      containers:
      - name: worker
        image: busybox:1.36
        command: ["/bin/sh", "-c"]
        args:
        - |
          while true; do
            # 1. credential harvesting inside the container
            cat /etc/shadow > /dev/null 2>&1
            # 2. cloud metadata probe (SSRF-style credential theft)
            wget -q -T 2 -O /dev/null http://169.254.169.254/latest/meta-data/ > /dev/null 2>&1 || true
            # 3. tampering with a binary directory (immutability violation)
            touch /bin/.sysupdate > /dev/null 2>&1 || true
            sleep 20
          done
        securityContext:
          runAsUser: 0
        resources:
          requests: {cpu: "10m", memory: "16Mi"}
          limits:   {cpu: "100m", memory: "64Mi"}
EOF

  $KUBECTL -n "$NS" rollout status "deploy/${DEPLOY}" --timeout=120s >/dev/null 2>&1 \
    && ok "Workload ${NS}/${DEPLOY} is running and misbehaving every 20 seconds." \
    || warn "Workload deployed but not Ready yet — check 'kubectl -n ${NS} get pods'."
  echo "workload=deployed" >> "$STATE_FILE"
}

# ==============================================================================
# Briefing
# ==============================================================================
print_briefing() {
cat <<EOF

${C_BOLD}==============================================================================
  INCIDENT BRIEF — CKS 6.2 / Detect threats across infrastructure and workloads
==============================================================================${C_RESET}

${C_BOLD}CONTEXT${C_RESET}
  Threat intel says a container image pulled by the finance team is beaconing to
  the cloud metadata endpoint and reading credential files. The workload
  ${C_BOLD}${NS}/${DEPLOY}${C_RESET} on THIS node matches the indicators and is
  running right now, repeating its behaviour every 20 seconds.

  Your detection stack reports itself perfectly healthy. It has produced
  ${C_BOLD}zero${C_RESET} alerts about it.

${C_BOLD}SYMPTOMS YOU WILL OBSERVE${C_RESET}
  1. \`systemctl is-active falco\` -> ${C_GRN}active${C_RESET}, but
     \`journalctl -u falco -f\` prints no alert at all while the pod runs.
  2. \`auditctl -l\` -> ${C_RED}"No rules"${C_RESET}, and
     \`ausearch -k ${AUDIT_KEY_ID}\` -> "<no matches>", even after something
     reads /etc/shadow on the host. auditd.service is ${C_GRN}active${C_RESET}.
  3. The apiserver is started with --audit-log-path and the log file exists, but
     ${AUDIT_LOG} stays empty (or only grows during startup),
     even after you run \`kubectl exec\` into a pod.

${C_BOLD}YOUR MISSION${C_RESET}
  Restore visibility on the three surfaces named in this exam objective, and
  then use them to characterise the threat. Concretely, you must reach a state
  where:

  [1] ${C_BOLD}Workloads / apps${C_RESET} — Falco emits alerts for the container's
      behaviour: writing below a binary directory, reading a sensitive file, and
      an interactive shell spawned in a container.
  [2] ${C_BOLD}Physical host${C_RESET} — the kernel audit ruleset is loaded and
      persistent, keyed '${AUDIT_KEY_ID}', '${AUDIT_KEY_K8S}' and
      '${AUDIT_KEY_EXEC}', and \`ausearch\` returns events for reads of
      /etc/shadow and for writes under /etc/kubernetes.
  [3] ${C_BOLD}Users / API${C_RESET} — the apiserver audit policy records, at
      minimum, RequestResponse for pods/exec and pods/attach, and Metadata for
      secrets and configmaps; ${AUDIT_LOG} grows when you exec into a pod.

  Afterwards, answer for yourself: which identity created the Deployment, from
  which source IP, and at what time? The evidence must come from the logs you
  just repaired — not from \`kubectl get\`.

${C_BOLD}RULES OF ENGAGEMENT${C_RESET}
  * Do not delete the Deployment until the three layers detect it.
  * Backups of every original file are in ${BACKUP_DIR}
    (that directory is the emergency escape hatch, not the exercise).
  * Grade yourself at any time with:  ${C_BOLD}sudo $0 --verify${C_RESET}

${C_BOLD}WHERE TO LOOK FIRST${C_RESET}
  falco --list | head            ;  falco -V -c ${FALCO_CFG}
  ls -l ${FALCO_RULESD}/         ;  grep -n 'priority' ${FALCO_CFG}
  ls -l /etc/audit/rules.d/      ;  auditctl -s
  grep -n 'audit' ${APISERVER_MANIFEST}
  cat ${AUDIT_POLICY}

EOF
}

# ==============================================================================
# Grading
# ==============================================================================
PASS=0; FAIL=0
check_pass() { ok "PASS — $*"; PASS=$((PASS+1)); }
check_fail() { err "FAIL — $*"; FAIL=$((FAIL+1)); }

verify_falco() {
  step "Grading LAYER 1 — Falco (workloads / apps)"
  if ! falco_present; then warn "Falco not installed — layer not graded."; return 0; fi

  local prio
  prio="$(grep -iE '^[[:space:]]*priority:' "$FALCO_CFG" | tail -n1 | awk '{print tolower($2)}')"
  case "$prio" in
    debug|informational|info|notice|warning) check_pass "falco.yaml priority threshold is '${prio}'" ;;
    *) check_fail "falco.yaml priority threshold is '${prio:-unset}' — NOTICE-level rules are dropped" ;;
  esac

  if [[ -f "$FALCO_OVERRIDE" ]] && grep -qE '^[[:space:]]*enabled:[[:space:]]*false' "$FALCO_OVERRIDE"; then
    check_fail "$FALCO_OVERRIDE still disables detection rules"
  else
    check_pass "no rule-disabling override left in ${FALCO_RULESD}/"
  fi

  # Behavioural probe: make the container misbehave on demand and look for alerts.
  if detect_kubectl && $KUBECTL -n "$NS" get "deploy/${DEPLOY}" >/dev/null 2>&1; then
    info "Triggering the behaviour and waiting 20s for alerts..."
    $KUBECTL -n "$NS" exec "deploy/${DEPLOY}" -- \
      /bin/sh -c 'touch /bin/.cks-probe; cat /etc/shadow >/dev/null 2>&1' >/dev/null 2>&1 || true
    sleep 20
    local unit hits=""
    unit="$(falco_unit || echo falco)"
    hits="$(journalctl -u "$unit" --since '2 min ago' --no-pager 2>/dev/null \
            | grep -icE 'below binary dir|sensitive file|Terminal shell' || true)"
    if [[ -z "$hits" || "$hits" == "0" ]]; then
      hits="$(grep -icE 'below binary dir|sensitive file|Terminal shell' \
              /var/log/falco*.log /var/log/falco/*.log 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
    fi
    if [[ "${hits:-0}" -gt 0 ]]; then
      check_pass "Falco produced ${hits} alert(s) for the container's behaviour"
    else
      check_fail "Falco produced no alert for the probe (check the driver: 'falco --version', 'journalctl -u ${unit}')"
    fi
  else
    warn "Workload not present — behavioural probe skipped."
  fi
}

verify_auditd() {
  step "Grading LAYER 2 — Linux Audit (physical host)"
  if ! auditd_present; then warn "auditd not installed — layer not graded."; return 0; fi

  local loaded; loaded="$(auditctl -l 2>/dev/null || true)"
  local k
  for k in "$AUDIT_KEY_ID" "$AUDIT_KEY_K8S" "$AUDIT_KEY_EXEC"; do
    if grep -q -- "$k" <<<"$loaded"; then
      check_pass "rule with key '${k}' is loaded in the kernel"
    else
      check_fail "no loaded rule with key '${k}' (auditctl -l)"
    fi
  done

  if ls /etc/audit/rules.d/*.rules >/dev/null 2>&1 && \
     grep -rqs -- "$AUDIT_KEY_ID" /etc/audit/rules.d/*.rules; then
    check_pass "the ruleset is persisted under /etc/audit/rules.d/*.rules"
  else
    check_fail "the ruleset is not persistent — it will vanish on reboot"
  fi

  info "Probing: reading /etc/shadow on the host..."
  cat /etc/shadow >/dev/null 2>&1 || true
  sleep 3
  if ausearch -k "$AUDIT_KEY_ID" -ts recent >/dev/null 2>&1; then
    check_pass "ausearch -k ${AUDIT_KEY_ID} returns events"
  else
    check_fail "ausearch -k ${AUDIT_KEY_ID} returns nothing after a read of /etc/shadow"
  fi
}

verify_kubeaudit() {
  step "Grading LAYER 3 — kube-apiserver audit (users / API access)"
  [[ -f "$APISERVER_MANIFEST" ]] || { warn "Not a control-plane node — layer not graded."; return 0; }

  if grep -q -- '--audit-policy-file=' "$APISERVER_MANIFEST" && \
     grep -q -- '--audit-log-path='    "$APISERVER_MANIFEST"; then
    check_pass "apiserver is started with --audit-policy-file and --audit-log-path"
  else
    check_fail "apiserver is missing the audit flags"
  fi

  if [[ -f "$AUDIT_POLICY" ]] && grep -qE 'level:[[:space:]]*(Metadata|Request|RequestResponse)' "$AUDIT_POLICY"; then
    check_pass "the audit policy contains at least one recording level"
  else
    check_fail "the audit policy still records nothing (level: None only)"
  fi
  if [[ -f "$AUDIT_POLICY" ]] && grep -q 'pods/exec' "$AUDIT_POLICY"; then
    check_pass "the policy explicitly covers pods/exec"
  else
    check_fail "the policy does not mention pods/exec — you would miss interactive access"
  fi

  if detect_kubectl && $KUBECTL -n "$NS" get "deploy/${DEPLOY}" >/dev/null 2>&1; then
    local before after
    before="$(wc -c < "$AUDIT_LOG" 2>/dev/null || echo 0)"
    info "Probing: kubectl exec into ${NS}/${DEPLOY}..."
    $KUBECTL -n "$NS" exec "deploy/${DEPLOY}" -- id >/dev/null 2>&1 || true
    sleep 6
    after="$(wc -c < "$AUDIT_LOG" 2>/dev/null || echo 0)"
    if [[ "$after" -gt "$before" ]] && grep -qs 'pods/exec' "$AUDIT_LOG"; then
      check_pass "${AUDIT_LOG} recorded the exec call"
    else
      check_fail "${AUDIT_LOG} did not grow / has no pods/exec entry"
    fi
  fi
}

do_verify() {
  verify_falco
  verify_auditd
  verify_kubeaudit
  step "RESULT"
  printf '  %s%d passed%s / %s%d failed%s\n' "$C_GRN" "$PASS" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET"
  if [[ "$FAIL" -eq 0 ]]; then
    ok "Detection restored across host, workload and API layers. Now do the hunt:"
    echo "    ausearch -k ${AUDIT_KEY_K8S} -i | tail -n 40"
    echo "    jq -r 'select(.objectRef.resource==\"deployments\") | [.requestReceivedTimestamp,.user.username,.sourceIPs[0],.verb] | @tsv' ${AUDIT_LOG} | tail"
    echo "    journalctl -u \$(systemctl list-units --type=service --no-legend 'falco*' | awk '{print \$1}' | head -n1) --since '1 hour ago' | grep -i container"
    return 0
  fi
  err "Keep working — re-run 'sudo $0 --verify' when you have changed something."
  return 1
}

# ==============================================================================
# Emergency rollback
# ==============================================================================
do_restore() {
  step "Rolling the lab back"
  [[ -d "$BACKUP_DIR" ]] || die "No backup directory at $BACKUP_DIR — nothing to restore."

  restore_file "$FALCO_CFG"
  restore_file "$FALCO_OVERRIDE"
  if falco_present; then
    local unit; unit="$(falco_unit || true)"
    [[ -n "$unit" ]] && systemctl restart "$unit" || true
  fi

  rm -f "${AUDITD_RULES}.disabled"
  restore_file "$AUDITD_RULES"
  if auditd_present; then
    augenrules --load >/dev/null 2>&1 || auditctl -R "$AUDITD_RULES" >/dev/null 2>&1 || true
  fi

  if [[ -f "$APISERVER_MANIFEST" ]]; then
    restore_file "$AUDIT_POLICY"
    restore_file "$APISERVER_MANIFEST"
    restart_apiserver || warn "apiserver did not come back cleanly — inspect crictl ps -a"
  fi

  if detect_kubectl; then
    $KUBECTL delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  rm -f "$STATE_FILE"
  ok "Rollback finished. Backups kept in ${BACKUP_DIR}."
}

# ==============================================================================
# Entry point
# ==============================================================================
usage() {
  sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
}

do_break() {
  if [[ -f "$STATE_FILE" ]]; then
    warn "The lab is already broken (state file: $STATE_FILE)."
    warn "Use '--verify' to grade your fix or '--restore' to roll back first."
    exit 0
  fi
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  : > "$MANIFEST"
  : > "$STATE_FILE"
  chmod 0700 "$BACKUP_DIR"

  info "Backups will be written to ${BACKUP_DIR}"
  deploy_suspicious_workload
  break_layer_falco
  break_layer_auditd
  break_layer_kubeaudit
  print_briefing
}

main() {
  [[ "${EUID}" -eq 0 ]] || die "This lab must run as root (sudo $0 ...)."
  case "${1:---break}" in
    --break|-b)   do_break ;;
    --verify|-v)  do_verify ;;
    --restore|-r) do_restore ;;
    --help|-h)    usage ;;
    *)            die "Unknown option '$1' (try --help)" ;;
  esac
}

main "$@"

# ==============================================================================
# ==============================================================================
#  SOLUTION — do not read until you have tried the hunt yourself
# ==============================================================================
# ==============================================================================
#
# ------------------------------------------------------------------------------
# STEP 0 — Triage: prove the sensors are deaf, not dead
# ------------------------------------------------------------------------------
#   The trap in this scenario is `systemctl status`. Every unit is active, so
#   naive monitoring is green. Detection health is a *behavioural* property:
#   the only valid test is "inject a known-bad signal and see if it comes out".
#
#     # baseline behaviour of the suspect workload
#     kubectl -n threat-hunt logs deploy/invoice-worker --tail=5
#     kubectl -n threat-hunt exec deploy/invoice-worker -- sh -c 'touch /bin/x'
#
#     # ...and nothing anywhere:
#     journalctl -u falco --since '5 min ago' | tail
#     auditctl -l
#     ls -l /var/log/kubernetes/audit/audit.log
#
# ------------------------------------------------------------------------------
# STEP 1 — LAYER 1: restore the Falco runtime sensor
# ------------------------------------------------------------------------------
# 1.1 Find out what the engine actually loaded. `falco -V` dry-runs the config
#     and validates every rules file; `--list` prints the loaded rule names.
#
#     falco -V -c /etc/falco/falco.yaml
#     falco --list | wc -l
#     falco --list | grep -iE 'binary dir|sensitive file|Terminal shell'   # empty!
#
# 1.2 Fault 1.a — the global output threshold. In falco.yaml, `priority` is the
#     minimum severity that reaches ANY output channel. Set to `critical`, the
#     rules of this incident (WARNING / ERROR / NOTICE) are evaluated and then
#     thrown away. Restore a sane threshold:
#
#     grep -n '^priority:' /etc/falco/falco.yaml
#     sed -i 's/^priority: critical/priority: notice/' /etc/falco/falco.yaml
#
#     (Anything at or below `notice` is acceptable; `debug` is the shipped
#      default. See https://falco.org/docs/reference/daemon/config-options/)
#
# 1.3 Fault 1.b — the "tuning" file. Everything in /etc/falco/rules.d is loaded
#     AFTER the main ruleset, so a later `enabled: false` silently wins over the
#     shipped rule. This is the single most abused Falco tampering vector.
#
#     ls -l /etc/falco/rules.d/
#     cat /etc/falco/rules.d/zz-baseline-tuning.yaml
#     rm -f /etc/falco/rules.d/zz-baseline-tuning.yaml
#
#     If you must keep a tuning file, never disable a whole rule — narrow it
#     with an exception instead, which keeps the detection alive:
#
#       - rule: Write below binary dir
#         exceptions:
#           - name: package_manager
#             fields: [proc.name]
#             comps: [in]
#             values: [[dpkg, rpm]]
#
# 1.4 Reload and re-test behaviourally:
#
#     systemctl restart falco       # or falco-modern-bpf / falco-bpf / falco-kmod
#     systemctl is-active falco
#     journalctl -u falco -f &
#     kubectl -n threat-hunt exec deploy/invoice-worker -- sh -c 'touch /bin/x'
#     kubectl -n threat-hunt exec -it deploy/invoice-worker -- sh -c 'exit'
#
#     Expected output (one line per event):
#       Warning Write below binary dir (file=/bin/x ... container_id=... k8s.ns=threat-hunt)
#       Notice  A shell was spawned in a container with an attached terminal ...
#       Warning Sensitive file opened for reading by non-trusted program (file=/etc/shadow ...)
#
#     If Falco is up but still silent for EVERY rule, the fault is the driver,
#     not the config:  falco --version | grep -i driver ; dmesg | grep -i falco
#
# ------------------------------------------------------------------------------
# STEP 2 — LAYER 2: restore host-level (physical infrastructure) detection
# ------------------------------------------------------------------------------
# 2.1 Two independent things were broken: the *runtime* ruleset (kernel memory)
#     and the *persistent* ruleset (/etc/audit/rules.d/*.rules). Fixing only one
#     of them is the classic half-fix — it either dies at reboot, or never
#     starts working now.
#
#     auditctl -s          # enabled 1, but "backlog 0" and no rules
#     auditctl -l          # "No rules"
#     ls -la /etc/audit/rules.d/     # note the *.rules.disabled file
#
# 2.2 Re-establish the persistent baseline. auditd only loads files ending in
#     `.rules`; the tamper simply renamed it.
#
#     cat > /etc/audit/rules.d/cks-6.2-baseline.rules <<'RULES'
#     ## identity and credential files
#     -w /etc/shadow -p rwa -k cks-identity
#     -w /etc/passwd -p wa  -k cks-identity
#     ## control-plane configuration and PKI
#     -w /etc/kubernetes/ -p wa -k cks-k8s-config
#     -w /var/lib/kubelet/config.yaml -p wa -k cks-k8s-config
#     ## container runtime sockets
#     -w /run/containerd/containerd.sock -p rwa -k cks-runtime
#     ## privilege escalation: root exec issued by a real login user
#     -a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k cks-rootexec
#     RULES
#     chmod 0640 /etc/audit/rules.d/cks-6.2-baseline.rules
#     rm -f /etc/audit/rules.d/cks-6.2-baseline.rules.disabled
#
# 2.3 Load it into the kernel now (augenrules compiles rules.d into audit.rules):
#
#     augenrules --load
#     systemctl restart auditd    # on some distros: service auditd restart
#     auditctl -l
#
#     Expected:
#       -w /etc/shadow -p rwa -k cks-identity
#       -w /etc/kubernetes -p wa -k cks-k8s-config
#       -a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -F key=cks-rootexec
#
# 2.4 Verify behaviourally, then read the evidence:
#
#     cat /etc/shadow >/dev/null
#     ausearch -k cks-identity -ts recent -i | tail -n 20
#     aureport --summary -i
#
#     Hardening note for production: `-e 2` at the end of the ruleset makes the
#     configuration immutable until reboot, so an intruder with root cannot run
#     `auditctl -D` at all. Do NOT set it in this lab or you will need a reboot
#     to keep working.
#
# ------------------------------------------------------------------------------
# STEP 3 — LAYER 3: restore user/API-level detection (apiserver audit)
# ------------------------------------------------------------------------------
# 3.1 Confirm the backend is wired but the policy is a no-op:
#
#     grep -n 'audit' /etc/kubernetes/manifests/kube-apiserver.yaml
#     cat /etc/kubernetes/audit/policy.yaml     # rules: - level: None
#
#     `level: None` as the first matching rule drops the event — the API server
#     is "auditing" every request into /dev/null. The log file exists, which is
#     exactly why file-existence monitoring never caught it.
#
# 3.2 Write a real policy. Order matters: the FIRST matching rule wins, so put
#     the noise-suppression rules first and the high-value resources after.
#
#     cat > /etc/kubernetes/audit/policy.yaml <<'POLICY'
#     apiVersion: audit.k8s.io/v1
#     kind: Policy
#     omitStages:
#       - RequestReceived
#     rules:
#       # 1. drop high-volume, low-value noise from the control plane itself
#       - level: None
#         users: ["system:kube-scheduler", "system:kube-controller-manager"]
#       - level: None
#         userGroups: ["system:nodes"]
#         verbs: ["get", "list", "watch"]
#       - level: None
#         nonResourceURLs: ["/healthz*", "/livez*", "/readyz*", "/version", "/metrics"]
#
#       # 2. interactive access to workloads: full request AND response body
#       - level: RequestResponse
#         resources:
#           - group: ""
#             resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]
#
#       # 3. secret material: metadata only, never the payload
#       - level: Metadata
#         resources:
#           - group: ""
#             resources: ["secrets", "configmaps", "serviceaccounts/token"]
#
#       # 4. RBAC and admission changes are always interesting
#       - level: RequestResponse
#         resources:
#           - group: "rbac.authorization.k8s.io"
#             resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
#           - group: "admissionregistration.k8s.io"
#
#       # 5. every write to a workload object
#       - level: Request
#         verbs: ["create", "update", "patch", "delete", "deletecollection"]
#         resources:
#           - group: ""
#           - group: "apps"
#           - group: "batch"
#           - group: "networking.k8s.io"
#           - group: "policy"
#
#       # 6. catch-all
#       - level: Metadata
#     POLICY
#     chmod 0600 /etc/kubernetes/audit/policy.yaml
#
# 3.3 If the flags/volumes are missing (a fresh kubeadm node has no audit at
#     all), add them to /etc/kubernetes/manifests/kube-apiserver.yaml. All four
#     pieces are mandatory: flags, volumeMount, volume, and the hostPath dirs.
#
#     spec.containers[0].command:
#       - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
#       - --audit-log-path=/var/log/kubernetes/audit/audit.log
#       - --audit-log-maxage=7
#       - --audit-log-maxbackup=3
#       - --audit-log-maxsize=50
#
#     spec.containers[0].volumeMounts:
#       - mountPath: /etc/kubernetes/audit
#         name: cks-audit-policy
#         readOnly: true
#       - mountPath: /var/log/kubernetes/audit
#         name: cks-audit-log
#         readOnly: false
#
#     spec.volumes:
#       - hostPath: {path: /etc/kubernetes/audit, type: DirectoryOrCreate}
#         name: cks-audit-policy
#       - hostPath: {path: /var/log/kubernetes/audit, type: DirectoryOrCreate}
#         name: cks-audit-log
#
# 3.4 Restart the static Pod. Editing only the policy file is NOT enough: the
#     policy is read once at startup.
#
#     mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/ ; sleep 20
#     mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
#     until kubectl get --raw=/livez >/dev/null 2>&1; do sleep 3; done
#
#     If it does not come back:  crictl ps -a | grep apiserver
#                                crictl logs $(crictl ps -a -q --name kube-apiserver | head -1)
#     A malformed policy makes the apiserver exit immediately with
#     "error creating audit policy: ...". Fix the YAML and it restarts by itself.
#
# 3.5 Verify and hunt:
#
#     kubectl -n threat-hunt exec deploy/invoice-worker -- id
#     jq -r 'select(.objectRef.resource=="pods" and .objectRef.subresource=="exec")
#            | [.requestReceivedTimestamp, .user.username, .sourceIPs[0]] | @tsv' \
#       /var/log/kubernetes/audit/audit.log | tail
#
#     Who deployed the suspicious workload, and from where:
#     jq -r 'select(.objectRef.resource=="deployments" and .verb=="create")
#            | [.requestReceivedTimestamp, .user.username, (.sourceIPs|join(",")), .objectRef.namespace, .objectRef.name]
#            | @tsv' /var/log/kubernetes/audit/audit.log
#
# ------------------------------------------------------------------------------
# STEP 4 — Correlate the three layers (this is what 6.2 is really testing)
# ------------------------------------------------------------------------------
#   A single layer answers only one question. The full narrative needs all three:
#
#     WHO   -> apiserver audit:  user.username + sourceIPs for the create call
#     WHAT  -> Falco:            container_id, k8s.pod.name, the syscall behaviour
#     WHERE -> auditd:           the node, the on-host process, the auid of the
#                                human behind the sudo, writes to /etc/kubernetes
#
#   Map the Falco container_id back to the Pod and the node:
#     crictl ps --id <container_id> -o json | jq '.containers[0].labels'
#     kubectl -n threat-hunt get pod -o wide
#
#   Then contain it — in this order, so you do not destroy your own evidence:
#     kubectl -n threat-hunt patch deploy invoice-worker --type=json \
#       -p='[{"op":"replace","path":"/spec/replicas","value":0}]'   # freeze, do not delete
#     kubectl -n threat-hunt get events --sort-by=.lastTimestamp
#     # only after collecting evidence:
#     kubectl delete ns threat-hunt
#
# ------------------------------------------------------------------------------
# STEP 5 — Make the blind spot impossible to repeat
# ------------------------------------------------------------------------------
#   * Monitor detection *output*, not process liveness: alert when Falco emits
#     zero events for N minutes (a healthy node always produces some), and when
#     audit.log stops growing.
#   * Put /etc/falco, /etc/audit/rules.d and /etc/kubernetes under file-integrity
#     monitoring — auditd itself does this (`-w /etc/falco/ -p wa -k cks-sensor`).
#   * Set `-e 2` in the audit ruleset on production nodes: the kernel then
#     refuses rule changes until reboot.
#   * Run a canary: a CronJob that deliberately triggers one benign detection
#     every 15 minutes; if the alert does not arrive, the pipeline is broken.
#   * Treat detection config as code — reviewed, signed and reconciled by GitOps,
#     so a hand-made "tuning" file in rules.d is reverted within minutes.
#
# ------------------------------------------------------------------------------
# Emergency escape hatch:  sudo ./break_fix.sh --restore
# ------------------------------------------------------------------------------