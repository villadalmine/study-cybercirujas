#!/usr/bin/env bash
#
# CNPE 2.1 — Implementing Monitoring, Alerting, Logging, and Tracing Solutions
# Break & Fix lab: a Prometheus scrape target goes silently DOWN.
#
# Reference (CNPE curriculum):
#   https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
# Prometheus configuration & Kubernetes service discovery:
#   https://prometheus.io/docs/prometheus/latest/configuration/configuration/
#   https://prometheus.io/docs/prometheus/latest/configuration/kubernetes_sd_config/
# The `up` metric and target health:
#   https://prometheus.io/docs/concepts/jobs_instances/
# Alerting rules:
#   https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
#
# WHAT THIS SCRIPT DOES
#   1. Provisions a fully self-contained observability stack (Prometheus scraping
#      a node-exporter target, plus one alerting rule) inside its OWN namespace on
#      a disposable Kubernetes cluster (kind / minikube / k3s / k3d).
#   2. Proves the stack is healthy: the target is UP and the alert is inactive.
#   3. Breaks ONE field of the Prometheus scrape configuration in a controlled,
#      fully reversible way, then reloads Prometheus.
#   4. Explains the symptom the student will observe and the goal to reach.
#
# SAFETY
#   Everything lives in namespace 'cnpe-obs-lab' plus one ClusterRole/Binding
#   (Prometheus needs cluster-scoped read for service discovery). Nothing on the
#   host or in other namespaces is touched. Run './break_fix.sh cleanup' to remove
#   every object. Intended for a DISPOSABLE lab VM only.
#
# USAGE
#   ./break_fix.sh            # deploy the stack (if needed) and inject the fault
#   ./break_fix.sh break      # same as above
#   ./break_fix.sh status     # show current target health / up value
#   ./break_fix.sh reset      # restore the correct config (ANSWER KEY shortcut)
#   ./break_fix.sh cleanup    # delete everything this lab created
#
set -euo pipefail

NS="cnpe-obs-lab"
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-prom/prometheus:v2.54.1}"
NODE_EXPORTER_IMAGE="${NODE_EXPORTER_IMAGE:-quay.io/prometheus/node-exporter:v1.8.2}"
GOOD_PORT=9100      # the port node-exporter actually listens on
BAD_PORT=9199       # the wrong port we relabel the scrape address to

# ---------------------------------------------------------------------------
# Pretty output (only colorize on a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_CYN=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_RST=""
fi
info() { printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

ensure_cluster() {
  need_cmd kubectl
  kubectl cluster-info >/dev/null 2>&1 || die "no reachable Kubernetes cluster (start kind/minikube/k3s first)"
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo '?')"
  info "Using kube-context: ${C_BLD}${ctx}${C_RST}"
}

# ---------------------------------------------------------------------------
# Manifest renderers
# ---------------------------------------------------------------------------
render_manifests() {
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    app.kubernetes.io/part-of: cnpe-obs-lab
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cnpe-obs-lab-prometheus
rules:
  - apiGroups: [""]
    resources: [nodes, services, endpoints, pods]
    verbs: [get, list, watch]
  - nonResourceURLs: ["/metrics"]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cnpe-obs-lab-prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cnpe-obs-lab-prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: ${NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-exporter
  namespace: ${NS}
  labels: {app: node-exporter}
spec:
  replicas: 1
  selector:
    matchLabels: {app: node-exporter}
  template:
    metadata:
      labels: {app: node-exporter}
    spec:
      containers:
        - name: node-exporter
          image: ${NODE_EXPORTER_IMAGE}
          args: ["--web.listen-address=:9100"]
          ports:
            - {name: metrics, containerPort: 9100}
          readinessProbe:
            httpGet: {path: /metrics, port: 9100}
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests: {cpu: 25m, memory: 32Mi}
            limits: {cpu: 100m, memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: node-exporter
  namespace: ${NS}
  labels: {app: node-exporter}
spec:
  selector: {app: node-exporter}
  ports:
    - {name: metrics, port: 9100, targetPort: 9100}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: ${NS}
  labels: {app: prometheus}
spec:
  replicas: 1
  selector:
    matchLabels: {app: prometheus}
  template:
    metadata:
      labels: {app: prometheus}
    spec:
      serviceAccountName: prometheus
      securityContext: {runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534}
      containers:
        - name: prometheus
          image: ${PROMETHEUS_IMAGE}
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
            - --storage.tsdb.retention.time=1h
            - --web.enable-lifecycle
          ports:
            - {name: web, containerPort: 9090}
          readinessProbe:
            httpGet: {path: /-/ready, port: 9090}
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus}
            - {name: data, mountPath: /prometheus}
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {cpu: 500m, memory: 512Mi}
      volumes:
        - name: config
          configMap: {name: prometheus-config}
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: ${NS}
  labels: {app: prometheus}
spec:
  selector: {app: prometheus}
  ports:
    - {name: web, port: 9090, targetPort: 9090}
EOF
}

# render_config <scrape_port> — the ConfigMap is the ONLY thing that changes
# between the healthy stack and the broken one. The fault is a single number.
render_config() {
  local port="$1"
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: ${NS}
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
    rule_files:
      - /etc/prometheus/alert.rules.yml
    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets: ['localhost:9090']
      - job_name: node-exporter
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [${NS}]
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app]
            action: keep
            regex: node-exporter
          - source_labels: [__meta_kubernetes_pod_ip]
            target_label: __address__
            regex: (.+)
            replacement: \${1}:${port}
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
  alert.rules.yml: |
    groups:
      - name: cnpe-obs-lab.rules
        rules:
          - alert: SampleTargetDown
            expr: up{job="node-exporter"} == 0
            for: 30s
            labels:
              severity: critical
            annotations:
              summary: "node-exporter scrape target is DOWN"
              description: "Prometheus has failed to scrape node-exporter for 30s in ${NS}."
EOF
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
deploy_baseline() {
  info "Applying baseline observability stack into namespace '${NS}'..."
  render_manifests | kubectl apply -f - >/dev/null
  render_config "${GOOD_PORT}" | kubectl apply -f - >/dev/null
  info "Waiting for node-exporter and Prometheus to become ready..."
  kubectl -n "${NS}" rollout status deploy/node-exporter --timeout=180s
  kubectl -n "${NS}" rollout status deploy/prometheus     --timeout=180s
}

# Query the up{job="node-exporter"} sample from inside the Prometheus pod.
# %7B..%7D is the URL-encoded {job="node-exporter"} selector.
query_up() {
  kubectl -n "${NS}" exec deploy/prometheus -c prometheus -- \
    /bin/sh -c 'wget -qO- "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22node-exporter%22%7D"' \
    2>/dev/null || true
}

# wait_for_up_value <0|1> [tries] — poll until up equals the wanted value
wait_for_up_value() {
  local want="$1" tries="${2:-30}" i out
  for ((i=1; i<=tries; i++)); do
    out="$(query_up)"
    if printf '%s' "$out" | grep -Eq "\"value\":\[[0-9.]+,\"${want}\"\]"; then
      return 0
    fi
    sleep 4
  done
  return 1
}

confirm_healthy() {
  info "Confirming the target scrapes correctly before we break it..."
  if wait_for_up_value 1 30; then
    ok "up{job=\"node-exporter\"} == 1  (target is UP)"
  else
    warn "Could not confirm up==1 automatically (cluster may be slow or busybox/wget absent)."
    warn "Proceeding anyway — verify manually in the Prometheus UI if unsure."
  fi
}

do_break() {
  warn "Injecting the fault: rewriting the scrape address port ${GOOD_PORT} -> ${BAD_PORT}"
  render_config "${BAD_PORT}" | kubectl apply -f - >/dev/null
  kubectl -n "${NS}" rollout restart deploy/prometheus >/dev/null
  kubectl -n "${NS}" rollout status  deploy/prometheus --timeout=180s
  info "Waiting for the target to flip to DOWN..."
  if wait_for_up_value 0 30; then
    ok "Fault confirmed: up{job=\"node-exporter\"} == 0  (target is DOWN)"
  else
    warn "Could not confirm up==0 automatically — check /targets in the UI."
  fi
}

do_reset() {
  info "Restoring the correct scrape configuration (ANSWER KEY shortcut)..."
  render_config "${GOOD_PORT}" | kubectl apply -f - >/dev/null
  kubectl -n "${NS}" rollout restart deploy/prometheus >/dev/null
  kubectl -n "${NS}" rollout status  deploy/prometheus --timeout=180s
  if wait_for_up_value 1 30; then
    ok "Restored: up{job=\"node-exporter\"} == 1  (target is UP again)"
  else
    warn "Reset applied but up==1 not confirmed yet — give it a scrape interval and recheck."
  fi
}

do_status() {
  ensure_cluster
  kubectl get ns "${NS}" >/dev/null 2>&1 || die "namespace ${NS} not found — run './break_fix.sh' first"
  info "Pods:"
  kubectl -n "${NS}" get pods -o wide || true
  echo
  info "Current up{job=\"node-exporter\"} sample:"
  query_up; echo
  info "Effective scrape target port in the ConfigMap:"
  kubectl -n "${NS}" get cm prometheus-config -o jsonpath='{.data.prometheus\.yml}' \
    | grep -E 'replacement:.*:[0-9]+' || true
}

cleanup() {
  ensure_cluster
  info "Removing all objects created by this lab..."
  kubectl delete namespace "${NS}" --ignore-not-found
  kubectl delete clusterrole        cnpe-obs-lab-prometheus --ignore-not-found
  kubectl delete clusterrolebinding cnpe-obs-lab-prometheus --ignore-not-found
  ok "Cleanup complete."
}

print_symptom() {
  cat <<EOF

${C_BLD}=====================================================================${C_RST}
${C_BLD} CNPE 2.1 — BREAK & FIX: a monitoring target has gone dark${C_RST}
${C_BLD}=====================================================================${C_RST}

${C_YEL}THE SYMPTOM YOU WILL SEE${C_RST}
  Open the Prometheus UI:
      kubectl -n ${NS} port-forward deploy/prometheus 9090:9090
      # then browse http://localhost:9090

  * Status -> Targets: the job ${C_BLD}node-exporter${C_RST} is ${C_RED}DOWN${C_RST}, with an
    error similar to:
        Get "http://10.x.x.x:${BAD_PORT}/metrics": dial tcp 10.x.x.x:${BAD_PORT}:
        connect: connection refused
  * Graph tab, run PromQL:  ${C_BLD}up{job="node-exporter"}${C_RST}  ->  returns ${C_RED}0${C_RST}
  * Any node_* series (e.g. node_time_seconds) stops receiving new samples.
  * Alerts tab: after ~30s the rule ${C_BLD}SampleTargetDown${C_RST} moves
    Inactive -> Pending -> ${C_RED}Firing${C_RST}. This is the alerting half of the
    topic: a broken scrape becomes a paging-worthy alert.
  * In a real platform, Grafana panels fed by this job would show "No data",
    and downstream SLO burn-rate alerts would fire.

${C_YEL}IMPORTANT — THE APPLICATION IS HEALTHY${C_RST}
  The node-exporter workload itself is fine. Prove it:
      kubectl -n ${NS} port-forward deploy/node-exporter 9100:9100
      curl -s localhost:9100/metrics | head
  Metrics are served on :${GOOD_PORT}. So this is an ${C_BLD}observability-pipeline${C_RST}
  fault, not an application outage — exactly the failure mode a platform
  engineer must recognize and not misroute to the app team.

${C_YEL}YOUR GOAL${C_RST}
  Without deleting or recreating the node-exporter Deployment, make the target
  return to ${C_GRN}UP${C_RST} (up{job="node-exporter"} == 1) and the SampleTargetDown
  alert return to ${C_GRN}Inactive${C_RST}. Fix the ${C_BLD}monitoring configuration only${C_RST}.

${C_YEL}WHERE TO LOOK (hints, not the answer)${C_RST}
  1. Read the target's error string in Status -> Targets: which host:port is
     Prometheus dialing, and does it match the port node-exporter listens on?
  2. Inspect the live scrape config:
         kubectl -n ${NS} get cm prometheus-config -o jsonpath='{.data.prometheus\.yml}'
     Focus on the relabel_configs of job 'node-exporter' — how is __address__
     being built?
  3. Remember a ConfigMap change does not reload a running Prometheus by itself;
     you must trigger a reload (lifecycle endpoint or a pod restart).

  Stuck? './break_fix.sh reset' applies the correct config for you.
  Done experimenting? './break_fix.sh cleanup' removes everything.
${C_BLD}=====================================================================${C_RST}

EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
  local action="${1:-break}"
  case "$action" in
    break|"")
      ensure_cluster
      deploy_baseline
      confirm_healthy
      do_break
      print_symptom
      ;;
    reset)   ensure_cluster; do_reset ;;
    status)  do_status ;;
    cleanup) cleanup ;;
    *) die "unknown action '$action' (use: break | reset | status | cleanup)" ;;
  esac
}

main "$@"

# ===========================================================================
# SOLUTION (instructor / answer key) — step by step
# ===========================================================================
#
# ROOT CAUSE
#   The scrape job 'node-exporter' rebuilds the target address with a relabel
#   rule that sets __address__ to <pod_ip>:9199, but node-exporter listens on
#   9100. Prometheus discovers the pod correctly (so the target still appears),
#   dials the wrong port, and every scrape fails with "connection refused".
#   Because the scrape fails, the synthetic metric `up` for that target is 0,
#   which is exactly what the SampleTargetDown alerting rule watches, so the
#   alert fires. Classic "target discovered but unreachable" — distinct from a
#   target that is missing entirely (which would be a keep/label selector bug).
#
# STEP 1 — Triage: is it the app or the pipeline?
#   kubectl -n cnpe-obs-lab get pods
#   kubectl -n cnpe-obs-lab port-forward deploy/node-exporter 9100:9100 &
#   curl -s localhost:9100/metrics | head        # works -> app is healthy
#   kill %1
#   Conclusion: the exporter serves metrics on 9100; the fault is in Prometheus.
#
# STEP 2 — Read the exact target error.
#   In the UI (Status -> Targets) the endpoint reads http://<ip>:9199/metrics and
#   the error is "connect: connection refused". The dialed port (9199) does not
#   match the listen port (9100).
#
# STEP 3 — Inspect the live scrape configuration.
#   kubectl -n cnpe-obs-lab get cm prometheus-config \
#     -o jsonpath='{.data.prometheus\.yml}' | sed -n '/job_name: node-exporter/,/pod$/p'
#   You will see, under relabel_configs:
#       - source_labels: [__meta_kubernetes_pod_ip]
#         target_label: __address__
#         regex: (.+)
#         replacement: ${1}:9199     <-- WRONG PORT
#
# STEP 4 — Fix the port in the ConfigMap (change 9199 -> 9100).
#   Option A (surgical, scriptable):
#     kubectl -n cnpe-obs-lab get cm prometheus-config -o yaml \
#       | sed 's/:9199/:9100/' | kubectl apply -f -
#   Option B (interactive):
#     kubectl -n cnpe-obs-lab edit cm prometheus-config
#     # find ${1}:9199 and change it to ${1}:9100
#
# STEP 5 — Reload Prometheus so it re-reads the ConfigMap.
#   A running Prometheus does NOT pick up ConfigMap edits automatically, and the
#   mounted file can take up to a kubelet sync period to update. Force it:
#   Option A (rollout restart — always works, fresh pod reads the new config):
#     kubectl -n cnpe-obs-lab rollout restart deploy/prometheus
#     kubectl -n cnpe-obs-lab rollout status  deploy/prometheus
#   Option B (hot reload via the lifecycle API — no restart, but only after the
#   mounted file has actually updated):
#     kubectl -n cnpe-obs-lab exec deploy/prometheus -c prometheus -- \
#       wget -qO- --post-data='' http://localhost:9090/-/reload
#
# STEP 6 — Verify the fix.
#   kubectl -n cnpe-obs-lab exec deploy/prometheus -c prometheus -- \
#     wget -qO- 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22node-exporter%22%7D'
#   Expect ..."value":[<ts>,"1"]...  -> target UP.
#   In the UI: Status -> Targets shows node-exporter UP; Alerts shows
#   SampleTargetDown back to Inactive after the next evaluations.
#
# ONE-COMMAND SHORTCUT (what STEPS 4-6 amount to):
#   ./break_fix.sh reset
#
# TEARDOWN:
#   ./break_fix.sh cleanup
# ===========================================================================