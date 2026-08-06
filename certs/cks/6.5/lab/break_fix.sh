#!/usr/bin/env bash
#
# =============================================================================
#  CKS 1.34 — Domain 6: Monitoring, Logging and Runtime Security (weight 20%)
#  Topic 6.5 — Use Kubernetes audit logs to monitor access (topic weight: 4)
#
#  BREAK & FIX laboratory script.
#
#  WHAT IT DOES
#    Seeds a small "incident" scenario (a namespace with a Secret and a
#    low-privilege ServiceAccount), then installs a DELIBERATELY BROKEN audit
#    configuration into the kube-apiserver static Pod. The control plane will
#    go down. Your job is to bring it back AND to end up with an audit trail
#    that actually answers the question "who read that Secret?".
#
#  WHERE TO RUN IT
#    A DISPOSABLE single-node kubeadm VM that you can rebuild. It rewrites
#    /etc/kubernetes/manifests/kube-apiserver.yaml. NEVER run it on a cluster
#    you care about. Every file it touches is backed up under /var/backups.
#
#  USAGE
#    sudo ./break_fix.sh break     # seed the scenario and break the cluster
#    sudo ./break_fix.sh verify    # grade your fix (8 checks, exit 0 = pass)
#    sudo ./break_fix.sh access    # replay the "suspicious access" traffic
#    sudo ./break_fix.sh hint      # progressive hints, no spoilers
#    sudo ./break_fix.sh restore   # emergency escape hatch: undo everything
#
#  Flags: --yes (skip confirmation), --force (skip the multi-node guard)
#
#  Reference: CKS Curriculum v1.34
#    https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#  Upstream docs:
#    https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
#    https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
# =============================================================================

set -euo pipefail

readonly MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
readonly AUDIT_DIR="/etc/kubernetes/audit"
readonly POLICY_FILE="${AUDIT_DIR}/policy.yaml"
readonly LOG_DIR="/var/log/kubernetes/audit"
readonly LOG_FILE="${LOG_DIR}/audit.log"
readonly BACKUP_ROOT="/var/backups/cks-6.5"
readonly ADMIN_KUBECONFIG="/etc/kubernetes/admin.conf"
readonly INTERN_KUBECONFIG="/root/intern.kubeconfig"
readonly MATCH_TMP="/tmp/.cks65-match.json"

readonly LAB_NS="finance"
readonly LAB_SA="intern"
readonly LAB_SECRET="db-credentials"
readonly LAB_PASSWORD='S3cr3t-Lab-P4ssw0rd'
readonly SA_USER="system:serviceaccount:finance:intern"

ASSUME_YES="no"
FORCE="no"

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_OFF=$'\033[0m'

info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail() { printf '%s[-]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()  { fail "$*"; exit 1; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

k() { kubectl --kubeconfig="$ADMIN_KUBECONFIG" "$@"; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
    [[ "$(id -u)" -eq 0 ]] || die "Run me as root (sudo). I rewrite static Pod manifests."
    command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
    command -v awk >/dev/null 2>&1     || die "awk not found in PATH."
    [[ -f "$MANIFEST" ]] || die "No $MANIFEST. This lab needs a kubeadm control-plane node."
    [[ -f "$ADMIN_KUBECONFIG" ]] || die "No $ADMIN_KUBECONFIG. This lab needs a kubeadm control-plane node."

    # The manifest must look like the stock kubeadm one, otherwise the surgical
    # edits below would land in the wrong place.
    grep -qE '^[[:space:]]*- kube-apiserver$' "$MANIFEST" || die "Unexpected manifest layout: no '- kube-apiserver' command entry."
    grep -qE '^    volumeMounts:$'            "$MANIFEST" || die "Unexpected manifest layout: no container volumeMounts block."
    grep -qE '^  volumes:$'                   "$MANIFEST" || die "Unexpected manifest layout: no pod volumes block."
}

guard_disposable_cluster() {
    local nodes
    nodes="$(k get nodes --no-headers 2>/dev/null | wc -l || echo 0)"
    if [[ "$nodes" -gt 1 && "$FORCE" != "yes" ]]; then
        die "This cluster has ${nodes} nodes — it does not look disposable. Re-run with --force if you are sure."
    fi
}

confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    rule
    warn "This will TAKE THE API SERVER DOWN on this machine, on purpose."
    warn "Backups go to ${BACKUP_ROOT}/<timestamp>; 'restore' undoes everything."
    rule
    local answer
    read -r -p "Type BREAK to continue: " answer
    [[ "$answer" == "BREAK" ]] || die "Aborted. Nothing was modified."
}

# -----------------------------------------------------------------------------
# Backup / restore
# -----------------------------------------------------------------------------
backup_now() {
    local stamp dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="${BACKUP_ROOT}/${stamp}"
    mkdir -p "$dir"
    cp -a "$MANIFEST" "${dir}/kube-apiserver.yaml"
    [[ -f "$POLICY_FILE" ]] && cp -a "$POLICY_FILE" "${dir}/policy.yaml"
    ln -sfn "$dir" "${BACKUP_ROOT}/latest"
    ok "Backup saved: ${dir}"
}

do_restore() {
    preflight
    local dir="${BACKUP_ROOT}/latest"
    [[ -L "$dir" || -d "$dir" ]] || die "No backup found under ${BACKUP_ROOT}."
    [[ -f "${dir}/kube-apiserver.yaml" ]] || die "Backup is incomplete: no kube-apiserver.yaml."

    info "Restoring the original kube-apiserver manifest..."
    install -m 0600 "${dir}/kube-apiserver.yaml" "${MANIFEST}.new"
    mv -f "${MANIFEST}.new" "$MANIFEST"
    rm -f "$POLICY_FILE"
    restart_apiserver
    if wait_for_api 180; then
        ok "Control plane is back on the pre-lab configuration."
        warn "The lab objects (namespace ${LAB_NS}, SA ${LAB_SA}) were left in place. Delete with: kubectl delete ns ${LAB_NS}"
    else
        fail "API server did not come back. Inspect: crictl ps -a --name kube-apiserver ; journalctl -u kubelet -n 100"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Static Pod helpers
# -----------------------------------------------------------------------------
restart_apiserver() {
    # The kubelet watches the manifest directory. Moving the file out and back
    # forces a full recreate instead of an in-place update.
    info "Forcing the kubelet to recreate the kube-apiserver static Pod..."
    mv "$MANIFEST" /tmp/kube-apiserver.yaml.reload
    sleep 8
    mv /tmp/kube-apiserver.yaml.reload "$MANIFEST"
}

wait_for_api() {
    local timeout="${1:-180}" waited=0
    while (( waited < timeout )); do
        if k get --raw='/healthz' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5; waited=$(( waited + 5 ))
        printf '.'
    done
    printf '\n'
    return 1
}

# -----------------------------------------------------------------------------
# Scenario seeding — done BEFORE the break, while the API is still up
# -----------------------------------------------------------------------------
seed_scenario() {
    info "Seeding the incident scenario (namespace ${LAB_NS})..."
    k get --raw='/healthz' >/dev/null 2>&1 || die "API server is not healthy right now. Run 'restore' first, then retry."

    k apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: finance
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: intern
  namespace: finance
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: finance-secret-reader
  namespace: finance
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: intern-reads-finance-secrets
  namespace: finance
subjects:
  - kind: ServiceAccount
    name: intern
    namespace: finance
roleRef:
  kind: Role
  name: finance-secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF

    k -n "$LAB_NS" create secret generic "$LAB_SECRET" \
        --from-literal=username=svc_billing \
        --from-literal=password="$LAB_PASSWORD" \
        --dry-run=client -o yaml | k apply -f - >/dev/null

    ok "Scenario ready: Secret ${LAB_NS}/${LAB_SECRET}, ServiceAccount ${LAB_NS}/${LAB_SA} (get,list on secrets)."
}

# -----------------------------------------------------------------------------
# The break
# -----------------------------------------------------------------------------
write_broken_policy() {
    mkdir -p "$AUDIT_DIR" "$LOG_DIR"
    chmod 0700 "$LOG_DIR"

    # A policy that is syntactically valid and semantically useless: the first
    # rule matches every request, and rule evaluation stops at the first match.
    cat > "$POLICY_FILE" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Silenced during last week's log-volume incident, "temporarily".
  - level: None

  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
EOF
    chmod 0644 "$POLICY_FILE"

    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
        # Not part of the puzzle: let the container read/write the hostPaths.
        chcon -Rt container_file_t "$AUDIT_DIR" "$LOG_DIR" 2>/dev/null || true
    fi
    ok "Audit policy written to ${POLICY_FILE}"
}

patch_manifest_broken() {
    local flags mounts volumes tmp
    tmp="$(mktemp)"

    flags=$(cat <<'EOF'
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=1
    - --audit-log-maxbackup=1
    - --audit-log-maxsize=1
EOF
)
    # Fault A: the policy hostPath volume exists, but it is NEVER mounted into
    # the container. Fault B: the log directory is mounted read-only.
    mounts=$(cat <<'EOF'
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
      readOnly: true
EOF
)
    volumes=$(cat <<'EOF'
  - hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
    name: audit-policy
  - hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
    name: audit-log
EOF
)

    awk -v flags="$flags" -v mounts="$mounts" -v volumes="$volumes" '
        { print }
        /^[[:space:]]*- kube-apiserver$/ && !f { print flags;   f = 1; next }
        /^    volumeMounts:$/           && !m { print mounts;  m = 1; next }
        /^  volumes:$/                  && !v { print volumes; v = 1; next }
    ' "$MANIFEST" > "$tmp"

    # Sanity: all three injections must have landed.
    grep -q -- '--audit-policy-file' "$tmp" || { rm -f "$tmp"; die "Injection failed (flags). Manifest untouched."; }
    grep -q 'name: audit-log'        "$tmp" || { rm -f "$tmp"; die "Injection failed (mounts). Manifest untouched."; }
    grep -q 'name: audit-policy'     "$tmp" || { rm -f "$tmp"; die "Injection failed (volumes). Manifest untouched."; }

    chmod 0600 "$tmp"
    mv -f "$tmp" "$MANIFEST"
    ok "kube-apiserver manifest patched (with faults)."
}

print_briefing() {
    rule
    printf '%sCKS 6.5 — BREAK & FIX: the audit trail that was not there%s\n' "$C_BLD" "$C_OFF"
    rule
    cat <<EOF

SCENARIO
  Last night someone read the Secret ${LAB_NS}/${LAB_SECRET} and the billing
  database credentials showed up in a paste site. Security asks you for the
  audit trail. There is an audit configuration on this control plane — it was
  added in a hurry after the previous incident — and right now the API server
  is not even starting.

SYMPTOMS YOU WILL SEE
  1. Every kubectl command fails, roughly like this:

       \$ kubectl get nodes
       The connection to the server 127.0.0.1:6443 was refused - did you
       specify the right host or port?

     kubectl is useless: the API server is the thing that is down. You must
     debug the static Pod from the node itself (crictl, journalctl, /var/log/pods).

  2. Once you get past the first error, the container will die AGAIN with a
     different message. Static Pod debugging is iterative: read the log, fix
     one thing, watch it restart, read the log again.

  3. When the API finally answers, the audit log will still be worthless.
     ${LOG_FILE} will stay empty (or nearly), even though
     the flags are clearly there. That part is not a mount problem.

WHAT YOU MUST ACHIEVE (this is what 'verify' grades)
  R1. The API server is healthy again:  kubectl get --raw='/healthz' -> ok
  R2. Auditing is really enabled: --audit-policy-file=${POLICY_FILE}
      and --audit-log-path=${LOG_FILE}, and the log file grows.
  R3. Retention fit for an investigation: --audit-log-maxage >= 30,
      --audit-log-maxbackup >= 10, --audit-log-maxsize >= 100 (MB).
  R4. EVERY access to Secrets, in ANY namespace, by ANY user, is logged at
      least at 'Metadata' level.
  R5. Authorization failures are visible: a 403 must land in the log
      (responseStatus code 403).
  R6. Secret material must NEVER appear in the log. The password of
      ${LAB_NS}/${LAB_SECRET} must not be greppable, in clear text or base64.
  R7. Probe/metrics noise is dropped: no events for the non-resource URLs
      /healthz*, /livez*, /readyz*, /version, /metrics.
  R8. The 'RequestReceived' stage is omitted (it doubles the log volume and
      tells you nothing you will not learn from ResponseComplete).

TOOLBOX
  sudo crictl ps -a --name kube-apiserver
  sudo crictl logs --tail=40 <container-id>
  sudo ls -t /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/
  sudo journalctl -u kubelet -n 100 --no-pager | grep -i apiserver
  sudo tail -f ${LOG_FILE} | jq -c '{u:.user.username, v:.verb, r:.objectRef.resource, c:.responseStatus.code}'

COMMANDS
  sudo $0 access    # replay the intern's access, to generate audit traffic
  sudo $0 verify    # grade yourself
  sudo $0 hint      # progressive hints
  sudo $0 restore   # give up and roll back

EOF
    rule
}

do_break() {
    preflight
    if grep -q -- '--audit-policy-file' "$MANIFEST"; then
        die "The manifest already carries audit flags. Run '$0 restore' first, then break again."
    fi
    guard_disposable_cluster
    confirm

    backup_now
    seed_scenario
    write_broken_policy
    patch_manifest_broken

    info "Waiting for the kubelet to notice the new manifest..."
    sleep 15
    if k get --raw='/healthz' >/dev/null 2>&1; then
        warn "The API server is still answering — the old container may not have been recycled yet."
    else
        ok "Control plane is down, as intended."
    fi
    print_briefing
}

# -----------------------------------------------------------------------------
# Traffic generator: the access the student has to be able to prove
# -----------------------------------------------------------------------------
build_intern_kubeconfig() {
    local server token
    server="$(k config view -o jsonpath='{.clusters[0].cluster.server}')"
    [[ -n "$server" ]] || die "Could not read the API server URL from ${ADMIN_KUBECONFIG}."
    token="$(k -n "$LAB_NS" create token "$LAB_SA" --duration=30m 2>/dev/null)" \
        || die "Could not mint a token for ${LAB_NS}/${LAB_SA}. Is the API healthy? Was the scenario seeded?"

    rm -f "$INTERN_KUBECONFIG"
    kubectl --kubeconfig="$INTERN_KUBECONFIG" config set-cluster lab \
        --server="$server" --certificate-authority=/etc/kubernetes/pki/ca.crt --embed-certs=true >/dev/null
    kubectl --kubeconfig="$INTERN_KUBECONFIG" config set-credentials "$LAB_SA" --token="$token" >/dev/null
    kubectl --kubeconfig="$INTERN_KUBECONFIG" config set-context lab \
        --cluster=lab --user="$LAB_SA" --namespace="$LAB_NS" >/dev/null
    kubectl --kubeconfig="$INTERN_KUBECONFIG" config use-context lab >/dev/null
    chmod 0600 "$INTERN_KUBECONFIG"
}

simulate_access() {
    # A bearer token, not impersonation: we want user.username in the audit
    # event to be the ServiceAccount itself, exactly like a real workload.
    build_intern_kubeconfig
    info "Replaying the suspicious access as ${SA_USER} ..."
    kubectl --kubeconfig="$INTERN_KUBECONFIG" -n "$LAB_NS" get secret "$LAB_SECRET" -o name >/dev/null 2>&1 \
        && ok "  200 OK   get secrets/${LAB_SECRET} in ${LAB_NS}" \
        || warn "  the allowed read failed (RBAC changed?)"
    kubectl --kubeconfig="$INTERN_KUBECONFIG" -n kube-system get secrets >/dev/null 2>&1 \
        && warn "  the kube-system read SUCCEEDED — RBAC is looser than the lab expects" \
        || ok "  403 Forbidden   list secrets in kube-system (expected)"
    sleep 3
}

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
PASSED=0
FAILED=0

check() {
    local label="$1"; shift
    if "$@"; then
        ok   "PASS  ${label}"; PASSED=$(( PASSED + 1 ))
    else
        fail "FAIL  ${label}"; FAILED=$(( FAILED + 1 ))
    fi
}

# All patterns must appear on the SAME line (one JSON event per line).
has_event() {
    local tmp="${MATCH_TMP}.work" pat
    [[ -s "$LOG_FILE" ]] || return 1
    cp "$LOG_FILE" "$tmp" 2>/dev/null || return 1
    for pat in "$@"; do
        if ! grep -F -- "$pat" "$tmp" > "${tmp}.f" 2>/dev/null; then
            rm -f "$tmp" "${tmp}.f"; return 1
        fi
        mv -f "${tmp}.f" "$tmp"
    done
    head -n 1 "$tmp" > "$MATCH_TMP" 2>/dev/null || true
    [[ -s "$MATCH_TMP" ]] || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

no_event() { ! has_event "$@"; }

flag_value() {
    sed -n "s/^[[:space:]]*- --${1}=\([0-9]\+\)[[:space:]]*$/\1/p" "$MANIFEST" | head -n 1
}

flag_at_least() {
    local flag="$1" min="$2" value
    value="$(flag_value "$flag")"
    [[ -n "$value" ]] || return 1
    (( value >= min ))
}

api_healthy()      { [[ "$(k get --raw='/healthz' 2>/dev/null)" == "ok" ]]; }
flags_present()    { grep -q -- "--audit-policy-file=${POLICY_FILE}" "$MANIFEST" \
                     && grep -q -- "--audit-log-path=${LOG_FILE}" "$MANIFEST"; }
log_is_alive()     { [[ -s "$LOG_FILE" ]]; }
retention_ok()     { flag_at_least "audit-log-maxage" 30 \
                     && flag_at_least "audit-log-maxbackup" 10 \
                     && flag_at_least "audit-log-maxsize" 100; }
secret_access_logged() {
    has_event '"verb":"get"' '"resource":"secrets"' "\"name\":\"${LAB_SECRET}\"" "\"username\":\"${SA_USER}\""
}
forbidden_logged() {
    has_event '"resource":"secrets"' "\"username\":\"${SA_USER}\"" '"code":403'
}
no_secret_material() {
    local b64
    b64="$(printf '%s' "$LAB_PASSWORD" | base64 -w0)"
    ! grep -qF -- "$b64" "$LOG_FILE" 2>/dev/null && ! grep -qF -- "$LAB_PASSWORD" "$LOG_FILE" 2>/dev/null
}
no_probe_noise() {
    no_event '"requestURI":"/healthz' && no_event '"requestURI":"/livez' \
        && no_event '"requestURI":"/readyz' && no_event '"requestURI":"/metrics'
}
request_received_omitted() { no_event '"stage":"RequestReceived"'; }

do_verify() {
    preflight
    rule
    printf '%sCKS 6.5 — grading your fix%s\n' "$C_BLD" "$C_OFF"
    rule

    if ! api_healthy; then
        fail "The API server is still not answering — nothing else can be graded yet."
        warn "Start here:  sudo crictl ps -a --name kube-apiserver  &&  sudo crictl logs --tail=40 <id>"
        exit 1
    fi
    simulate_access

    check "R1  API server healthy (/healthz = ok)"                       api_healthy
    check "R2a --audit-policy-file and --audit-log-path are set"         flags_present
    check "R2b ${LOG_FILE} exists and is not empty"                      log_is_alive
    check "R3  retention: maxage>=30, maxbackup>=10, maxsize>=100"       retention_ok
    check "R4  read of ${LAB_NS}/${LAB_SECRET} by ${SA_USER} is logged"  secret_access_logged
    check "R5  the 403 on kube-system secrets is logged"                 forbidden_logged
    check "R6  no Secret material in the audit log"                      no_secret_material
    check "R7  probe/metrics endpoints are not logged"                   no_probe_noise
    check "R8  RequestReceived stage omitted"                            request_received_omitted

    rule
    if [[ -s "$MATCH_TMP" ]]; then
        info "Last matching audit event:"
        if command -v jq >/dev/null 2>&1; then
            jq -C '{time:.requestReceivedTimestamp, user:.user.username, verb:.verb,
                    resource:.objectRef, level:.level, code:.responseStatus.code,
                    sourceIPs:.sourceIPs}' < "$MATCH_TMP" || cat "$MATCH_TMP"
        else
            cat "$MATCH_TMP"
        fi
        rule
    fi
    printf '%sPassed: %d   Failed: %d%s\n' "$C_BLD" "$PASSED" "$FAILED" "$C_OFF"
    if (( FAILED == 0 )); then
        ok "Lab complete. You can now answer 'who read that Secret, and when'."
        return 0
    fi
    warn "Not there yet. 'sudo $0 hint' gives you a nudge without the answer."
    return 1
}

# -----------------------------------------------------------------------------
# Hints
# -----------------------------------------------------------------------------
do_hint() {
    cat <<EOF

HINT 1 — the API server will not start (kubectl says "connection refused")
  kubectl cannot help you. Ask the container runtime instead:
      sudo crictl ps -a --name kube-apiserver
      sudo crictl logs --tail=40 \$(sudo crictl ps -a --name kube-apiserver -q | head -1)
  or read the raw file the kubelet writes:
      sudo tail -40 /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log
  Read the FIRST error line, not the last one.

HINT 2 — "no such file or directory" on the policy file
  The file exists on the host. Does the CONTAINER see it? A flag pointing at a
  path is not enough: the path has to be inside the Pod. Compare the entries
  under spec.volumes with the entries under containers[0].volumeMounts. One of
  them has a partner missing.

HINT 3 — "read-only file system" when opening the audit log
  The API server does not read that file, it WRITES it. Look at the readOnly
  attribute of that particular volumeMount. Policy in, log out.

HINT 4 — the API is up but ${LOG_FILE} stays empty
  Nothing is wrong with the mounts anymore; the policy itself is the problem.
  Audit rules are evaluated top to bottom and the FIRST rule that matches a
  request decides its level. Read your rule list again from the top and ask
  which requests reach rule number two.

HINT 5 — noise and retention
  - Non-resource endpoints are matched with 'nonResourceURLs' (they accept a
    trailing * wildcard), not with 'resources'.
  - 'omitStages: ["RequestReceived"]' can be set at policy level or per rule.
  - --audit-log-maxsize is megabytes, --audit-log-maxage is days,
    --audit-log-maxbackup is a file count. A 1 MB / 1 file trail deletes the
    evidence before you finish reading it.

HINT 6 — do not leak what you are trying to protect
  'RequestResponse' on secrets writes the Secret payload into a plain-text file
  on the node. That converts your audit log into a credential store. Metadata
  is the correct level for secrets; keep RequestResponse for things like
  pods/exec and RBAC objects.

EOF
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
main() {
    local action="${1:-break}"
    shift || true
    local arg
    for arg in "$@"; do
        case "$arg" in
            --yes)   ASSUME_YES="yes" ;;
            --force) FORCE="yes" ;;
            *) die "Unknown flag: ${arg}" ;;
        esac
    done

    case "$action" in
        break)   do_break ;;
        verify)  do_verify ;;
        access)  preflight; simulate_access ;;
        hint)    do_hint ;;
        restore) do_restore ;;
        -h|--help|help)
            printf 'Usage: %s {break|verify|access|hint|restore} [--yes] [--force]\n' "$0" ;;
        *) die "Unknown action '${action}'. Try: break | verify | access | hint | restore" ;;
    esac
}

main "$@"

# =============================================================================
#  SOLUTION — STEP BY STEP
#  (read only after you have tried; 'verify' grades the same 8 requirements)
# =============================================================================
#
#  There are FOUR independent faults. Two kill the API server, two silently
#  destroy the value of the audit trail:
#
#    A. The 'audit-policy' hostPath volume is declared, but the matching
#       volumeMount is missing -> the container cannot see /etc/kubernetes/audit.
#    B. The 'audit-log' volumeMount is readOnly: true -> the API server cannot
#       create /var/log/kubernetes/audit/audit.log.
#    C. The policy starts with a bare '- level: None' rule. Rules are evaluated
#       in order and the first match wins, so every request is dropped.
#    D. Retention is set to 1 day / 1 backup / 1 MB, and the policy logs Secrets
#       in a way that is either useless or dangerous.
#
# -----------------------------------------------------------------------------
# STEP 0 — Accept that kubectl is dead and debug the static Pod from the node
# -----------------------------------------------------------------------------
#   $ kubectl get nodes
#   The connection to the server 127.0.0.1:6443 was refused ...
#
#   $ sudo crictl ps -a --name kube-apiserver
#   CONTAINER      IMAGE          CREATED         STATE     NAME             ...
#   9f2a1c4d0b7e   c3994bc696102  8 seconds ago   Exited    kube-apiserver   ...
#
#   $ sudo crictl logs --tail=20 9f2a1c4d0b7e
#   E0806 12:04:11.882119  1 run.go:74] "command failed" err="failed to initialize audit:
#     failed to read audit policy file: open /etc/kubernetes/audit/policy.yaml:
#     no such file or directory"
#
#   Equivalent sources when crictl is not available:
#     sudo tail -40 /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log
#     sudo journalctl -u kubelet -n 100 --no-pager | grep -i apiserver
#
#   Note the file DOES exist on the host:
#     $ sudo ls -l /etc/kubernetes/audit/policy.yaml
#     -rw-r--r--. 1 root root 271 Aug  6 12:03 /etc/kubernetes/audit/policy.yaml
#   ...so this is a mount problem, not a missing-file problem.
#
# -----------------------------------------------------------------------------
# STEP 1 — Fault A: add the missing volumeMount for the policy directory
# -----------------------------------------------------------------------------
#   $ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
#
#   Under spec.containers[0].volumeMounts add (4-space indent, like its siblings):
#
#       - mountPath: /etc/kubernetes/audit
#         name: audit-policy
#         readOnly: true
#
#   The volume itself was already there, under spec.volumes:
#
#     - hostPath:
#         path: /etc/kubernetes/audit
#         type: DirectoryOrCreate
#       name: audit-policy
#
#   RULE OF THUMB for every CKS static-Pod task: a hostPath needs BOTH halves,
#   spec.volumes AND containers[].volumeMounts, and the 'name' must match exactly.
#
#   Save. The kubelet re-creates the Pod within ~20 s. Watch it:
#     $ watch -n2 'sudo crictl ps -a --name kube-apiserver'
#
# -----------------------------------------------------------------------------
# STEP 2 — Fault B: the log directory is mounted read-only
# -----------------------------------------------------------------------------
#   $ sudo crictl logs --tail=20 $(sudo crictl ps -a --name kube-apiserver -q | head -1)
#   E0806 12:07:52.114003  1 run.go:74] "command failed" err="failed to initialize audit:
#     failed to open audit log file: open /var/log/kubernetes/audit/audit.log:
#     read-only file system"
#
#   Policy in = read-only. Log out = read-write. Fix the audit-log mount:
#
#       - mountPath: /var/log/kubernetes/audit
#         name: audit-log
#         readOnly: false
#
#   (Deleting the readOnly line entirely works too; false is the default.)
#
#   Now the API server should start:
#     $ sudo crictl ps --name kube-apiserver
#     $ kubectl get --raw='/healthz'
#     ok
#
# -----------------------------------------------------------------------------
# STEP 3 — Fault C: the catch-all None rule at the top of the policy
# -----------------------------------------------------------------------------
#   $ sudo ls -l /var/log/kubernetes/audit/audit.log
#   -rw-------. 1 root root 0 Aug  6 12:09 /var/log/kubernetes/audit/audit.log
#
#   Zero bytes on a live cluster is the signature of a policy that matches
#   everything with level None. Audit rules are ordered and the FIRST match
#   wins; a bare '- level: None' as rule #1 silences the whole cluster and makes
#   every rule below it dead code.
#
# -----------------------------------------------------------------------------
# STEP 4 — Write a policy that is actually useful (fixes C and D)
# -----------------------------------------------------------------------------
#   $ sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'POLICY'
#   apiVersion: audit.k8s.io/v1
#   kind: Policy
#   # RequestReceived is emitted before the request is even handled: it doubles
#   # the volume and carries no outcome. Drop it globally.
#   omitStages:
#     - RequestReceived
#   rules:
#     # 1. Kill the highest-volume noise FIRST, but only the noise that can
#     #    never be security-relevant: health probes and metrics scrapes.
#     - level: None
#       nonResourceURLs:
#         - /healthz*
#         - /livez*
#         - /readyz*
#         - /version
#         - /metrics
#         - /openapi*
#
#     # 2. Secrets and credential-shaped objects: WHO, WHEN, FROM WHERE, on
#     #    WHICH object -- and never the payload. Metadata, deliberately.
#     #    This rule sits ABOVE the system-component silencing rule on purpose:
#     #    a kubelet or a controller reading a Secret must still be recorded.
#     - level: Metadata
#       resources:
#         - group: ""
#           resources: ["secrets", "configmaps", "serviceaccounts/token"]
#
#     # 3. Interactive access to containers: the command line is the evidence.
#     - level: RequestResponse
#       resources:
#         - group: ""
#           resources: ["pods/exec", "pods/attach", "pods/portforward"]
#
#     # 4. RBAC objects: this is where privilege escalation lands. Full body.
#     - level: RequestResponse
#       resources:
#         - group: "rbac.authorization.k8s.io"
#           resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
#
#     # 5. Now, and only now, silence the read-only chatter of the control plane
#     #    and the kubelets. Their Secret reads were already captured by rule 2.
#     - level: None
#       users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
#       verbs: ["get", "list", "watch"]
#     - level: None
#       userGroups: ["system:nodes"]
#       verbs: ["get", "list", "watch"]
#
#     # 6. Anything that mutates state: keep the request body.
#     - level: Request
#       verbs: ["create", "update", "patch", "delete", "deletecollection"]
#
#     # 7. Catch-all. Without this last rule, everything unmatched is dropped.
#     - level: Metadata
#   POLICY
#
#   Level semantics (worth memorising for the exam):
#     None            -> event discarded
#     Metadata        -> user, verb, resource, namespace, sourceIPs, timestamp, response code
#     Request         -> Metadata + request body
#     RequestResponse -> Request + response body (never for secrets)
#
# -----------------------------------------------------------------------------
# STEP 5 — Fix retention (fault D) in the manifest
# -----------------------------------------------------------------------------
#   The final flag block under 'command:' must read:
#
#       - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
#       - --audit-log-path=/var/log/kubernetes/audit/audit.log
#       - --audit-log-maxage=30      # days of history to keep
#       - --audit-log-maxbackup=10   # rotated files to retain
#       - --audit-log-maxsize=100    # megabytes per file before rotating
#
#   1 MB / 1 backup means the incident scrolls out of the log while you are
#   still opening the ticket. Note that --audit-log-path=- writes to stdout,
#   which is fine when a log shipper collects the Pod's output, but then the
#   maxage/maxbackup/maxsize flags do nothing.
#
# -----------------------------------------------------------------------------
# STEP 6 — Restart, then prove it
# -----------------------------------------------------------------------------
#   The kubelet reloads the static Pod on any manifest write. If it does not:
#     $ sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
#     $ sleep 20
#     $ sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
#     $ until kubectl get --raw='/healthz'; do sleep 3; done
#
#   Generate the traffic and hunt for it:
#     $ sudo ./break_fix.sh access
#     $ sudo grep '"resource":"secrets"' /var/log/kubernetes/audit/audit.log \
#         | jq -c '{t:.requestReceivedTimestamp, u:.user.username, v:.verb,
#                   ns:.objectRef.namespace, n:.objectRef.name,
#                   ip:.sourceIPs[0], code:.responseStatus.code}'
#     {"t":"2026-08-06T12:21:04.771Z","u":"system:serviceaccount:finance:intern",
#      "v":"get","ns":"finance","n":"db-credentials","ip":"10.0.2.15","code":200}
#     {"t":"2026-08-06T12:21:05.019Z","u":"system:serviceaccount:finance:intern",
#      "v":"list","ns":"kube-system","n":null,"ip":"10.0.2.15","code":403}
#
#   Everyday triage one-liners:
#     # who is getting denied, ranked
#     sudo jq -r 'select(.responseStatus.code==403) | .user.username' \
#       /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn
#     # every exec into a container, with the command
#     sudo jq -r 'select(.objectRef.subresource=="exec")
#                 | [.requestReceivedTimestamp,.user.username,.objectRef.namespace,
#                    .objectRef.name,(.requestURI)] | @tsv' \
#       /var/log/kubernetes/audit/audit.log
#     # anonymous access attempts
#     sudo grep '"username":"system:anonymous"' /var/log/kubernetes/audit/audit.log | wc -l
#
#   Confirm you did NOT leak the Secret into the log (requirement R6):
#     $ sudo grep -c "$(printf 'S3cr3t-Lab-P4ssw0rd' | base64 -w0)" \
#         /var/log/kubernetes/audit/audit.log
#     0
#
#   Then grade everything:
#     $ sudo ./break_fix.sh verify
#
# -----------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM (and into production)
# -----------------------------------------------------------------------------
#   * Enabling audit takes FOUR coordinated edits: the flags, the policy file,
#     the volume, and the volumeMount. Forgetting the mount is the single most
#     common way to bring a control plane down in this task.
#   * Rule order is the whole language. First match wins; a broad None rule
#     placed too early is a silent, total outage of your security telemetry.
#   * Never log Secrets at Request/RequestResponse: the audit log is a
#     world-readable-by-root plain-text file on the node, usually shipped
#     off-box. Metadata answers "who and when" without creating a new target.
#   * The audit log lives on the node. A node-local file is not an audit trail:
#     ship it off the host (webhook backend or a DaemonSet collector), because
#     an attacker with node access can truncate it.
#   * Audit only records requests that reach the API server. In-container
#     activity needs Falco/eBPF tooling (topic 6.2/6.3), not audit policy.
#
#   Sources:
#     https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
#     https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
#     https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
#     https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
# =============================================================================