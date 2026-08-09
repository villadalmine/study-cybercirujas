#!/usr/bin/env bash
#
# PCA — Topic 4.1: Dashboarding basics — BREAK & FIX lab
# ---------------------------------------------------------------------------
# Scenario: Grafana is provisioned with a Prometheus data source and a starter
# dashboard, but the data source points at the WRONG port. Every panel is dead.
# Your job: make the dashboard show live data again.
#
# SAFETY: Run this ONLY on a disposable lab VM. It creates throwaway Docker
# containers (prom-lab, grafana-lab) and a network (pca-lab-net), and writes
# files under a temp lab directory. Tear everything down with:  "$0" cleanup
#
# References (official):
#   - Grafana Prometheus data source:
#       https://grafana.com/docs/grafana/latest/datasources/prometheus/
#   - Grafana provisioning (data sources & dashboards):
#       https://grafana.com/docs/grafana/latest/administration/provisioning/
#   - Prometheus health & readiness endpoints:
#       https://prometheus.io/docs/prometheus/latest/management_api/
#   - PCA curriculum:
#       https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
# ---------------------------------------------------------------------------

set -euo pipefail

LAB_DIR="${LAB_DIR:-/tmp/pca-4.1-dashboarding-lab}"
NET="pca-lab-net"
PROM_IMAGE="prom/prometheus:v2.53.0"
GRAFANA_IMAGE="grafana/grafana:11.1.0"
PROM_CT="prom-lab"
GRAFANA_CT="grafana-lab"
GRAFANA_PORT="3000"
PROM_PORT="9090"

# The controlled fault: Prometheus listens on 9090, but the data source is
# provisioned to talk to 9099. This is the single line the student must find.
BROKEN_PORT="9099"

log()  { printf '\033[1;36m[lab]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed. Install Docker Engine on this disposable VM and re-run."
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    err "Cannot talk to the Docker daemon. Start it, or add your user to the 'docker' group (or re-run with sudo)."
    exit 1
  fi
}

cleanup() {
  log "Tearing down the lab..."
  docker rm -f "$PROM_CT" "$GRAFANA_CT" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  log "Done. All lab containers, the network, and $LAB_DIR are gone."
}

write_lab_files() {
  mkdir -p "$LAB_DIR/provisioning/datasources" "$LAB_DIR/provisioning/dashboards"

  # Prometheus scrapes itself, so 'up{job="prometheus"}' == 1 once the wiring is correct.
  cat > "$LAB_DIR/prometheus.yml" <<'EOF'
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
EOF

  # Data source provisioning — THIS FILE CONTAINS THE FAULT (:9099 instead of :9090).
  # Provisioned data sources are read-only in the UI (editable: false): the fix
  # lives in this file, not in a text box.
  cat > "$LAB_DIR/provisioning/datasources/datasource.yml" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    uid: pca-prom
    type: prometheus
    access: proxy
    url: http://${PROM_CT}:${BROKEN_PORT}
    isDefault: true
    editable: false
EOF

  # Dashboard provider: load any *.json dropped in this directory.
  cat > "$LAB_DIR/provisioning/dashboards/dashboards.yml" <<'EOF'
apiVersion: 1

providers:
  - name: pca-lab
    type: file
    disableDeletion: false
    allowUiUpdates: false
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: false
EOF

  # Starter dashboard: one timeseries panel graphing 'up' (target health).
  # Its datasource uid must match the provisioned one (pca-prom).
  cat > "$LAB_DIR/provisioning/dashboards/pca-lab.json" <<'EOF'
{
  "uid": "pca-lab-4-1",
  "title": "PCA 4.1 — Target Health",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "refresh": "5s",
  "time": { "from": "now-15m", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "up (target health)",
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "pca-prom" },
      "fieldConfig": {
        "defaults": {
          "min": 0,
          "max": 1,
          "unit": "short",
          "custom": { "drawStyle": "line", "fillOpacity": 20, "lineWidth": 2 }
        },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "table", "placement": "bottom" },
        "tooltip": { "mode": "multi" }
      },
      "targets": [
        {
          "refId": "A",
          "datasource": { "type": "prometheus", "uid": "pca-prom" },
          "expr": "up",
          "legendFormat": "{{job}} / {{instance}}"
        }
      ]
    }
  ]
}
EOF
}

deploy() {
  require_docker
  log "Preparing a clean lab (removing any previous run)..."
  docker rm -f "$PROM_CT" "$GRAFANA_CT" >/dev/null 2>&1 || true
  docker network create "$NET" >/dev/null 2>&1 || true

  write_lab_files

  log "Pulling images (first run only)..."
  docker pull "$PROM_IMAGE"    >/dev/null
  docker pull "$GRAFANA_IMAGE" >/dev/null

  log "Starting Prometheus (healthy, on :$PROM_PORT)..."
  docker run -d --name "$PROM_CT" --network "$NET" \
    -p "${PROM_PORT}:9090" \
    -v "$LAB_DIR/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    "$PROM_IMAGE" >/dev/null

  log "Starting Grafana (with the broken data source, on :$GRAFANA_PORT)..."
  docker run -d --name "$GRAFANA_CT" --network "$NET" \
    -p "${GRAFANA_PORT}:3000" \
    -e GF_SECURITY_ADMIN_USER=admin \
    -e GF_SECURITY_ADMIN_PASSWORD=admin \
    -e GF_AUTH_ANONYMOUS_ENABLED=false \
    -v "$LAB_DIR/provisioning:/etc/grafana/provisioning:ro" \
    "$GRAFANA_IMAGE" >/dev/null

  VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  VM_IP="${VM_IP:-localhost}"

  cat <<EOF

===========================================================================
  PCA 4.1 — DASHBOARDING BASICS  ::  BREAK & FIX
===========================================================================

The lab is up. Give Grafana ~15 seconds to finish provisioning, then log in:

    URL:   http://${VM_IP}:${GRAFANA_PORT}
    User:  admin
    Pass:  admin   (skip the "change password" prompt for the lab)

Prometheus itself is fine and reachable at:

    http://${VM_IP}:${PROM_PORT}      (try the Graph / Expression browser)

---------------------------------------------------------------------------
SYMPTOM you will observe
---------------------------------------------------------------------------
  * Open the dashboard  Dashboards -> "PCA 4.1 — Target Health".
    The panel "up (target health)" shows NO line and an error/"No data".
  * Open  Explore  and run the query:  up
    You get a red banner instead of a value, e.g.:
        "Post \"http://${PROM_CT}:${BROKEN_PORT}/api/v1/query\":
         dial tcp ...: connect: connection refused"
  * Connections -> Data sources -> Prometheus -> "Save & test" fails with
    that same connection-refused error.
  * Note: the data source form fields are GREYED OUT — it was provisioned
    read-only (editable: false), so you cannot fix it by typing in the UI.

---------------------------------------------------------------------------
YOUR GOAL (definition of done)
---------------------------------------------------------------------------
  1. "Save & test" on the Prometheus data source reports:
         "Successfully queried the Prometheus API."
  2. The "up (target health)" panel draws a flat line at value 1
     for  up{job="prometheus"}.
  3. In Explore, the query  up  returns 1 (not an error).

Diagnose WHY the data source is unreachable, then apply a durable fix.
Hint: Grafana can resolve the host but not the endpoint — is Prometheus
actually listening where the data source is pointed?

When you want the answer, read the commented SOLUTION at the bottom of
this script, or tear the lab down with:   $0 cleanup
===========================================================================

EOF
}

case "${1:-deploy}" in
  deploy)  deploy ;;
  cleanup) cleanup ;;
  *)
    err "Unknown command: ${1:-}"
    echo "Usage: $0 [deploy|cleanup]" >&2
    exit 2
    ;;
esac

# ###########################################################################
# SOLUTION — step by step (read only after you have tried)
# ###########################################################################
#
# ROOT CAUSE
#   The provisioned data source points at http://prom-lab:9099, but Prometheus
#   listens on 9090. DNS on the docker network resolves "prom-lab" fine, so the
#   failure is NOT name resolution — it is a refused TCP connection on the wrong
#   port. Classic "the dashboard is fine, the plumbing is wrong" incident.
#
# STEP 1 — Reproduce and read the error precisely
#   In Grafana: Connections -> Data sources -> Prometheus -> "Save & test".
#   The message names the exact URL it tried:
#       Post "http://prom-lab:9099/api/v1/query": ... connection refused
#   The port 9099 is your prime suspect.
#
# STEP 2 — Prove Prometheus is healthy and find the REAL port
#   From the host:
#       curl -s http://localhost:9090/-/healthy       # -> "Prometheus Server is Healthy."
#       docker port prom-lab                           # -> 9090/tcp -> 0.0.0.0:9090
#   From INSIDE Grafana's network namespace (proves reachability as Grafana sees it):
#       docker exec grafana-lab wget -qO- http://prom-lab:9090/-/healthy   # healthy
#       docker exec grafana-lab wget -qO- http://prom-lab:9099/-/healthy   # refused
#   Conclusion: Prometheus is up on 9090; the data source's 9099 is wrong.
#
# STEP 3 — Understand why you cannot fix it in the UI
#   The data source was provisioned with  editable: false, so the fields are
#   locked. Provisioned config is the source of truth; the durable fix belongs
#   in the file on disk, not in the browser.
#
# STEP 4 — Correct the provisioning file
#       sed -i 's#:9099#:9090#' "$LAB_DIR/provisioning/datasources/datasource.yml"
#   (or edit by hand and change the url line to: url: http://prom-lab:9090)
#
# STEP 5 — Make Grafana reload provisioning
#   Restart the container so it re-reads /etc/grafana/provisioning:
#       docker restart grafana-lab
#   (Alternatively, an admin can POST to /api/admin/provisioning/datasources/reload.)
#
# STEP 6 — Verify against the definition of done
#   * Data sources -> Prometheus -> "Save & test"
#         -> "Successfully queried the Prometheus API."
#   * Dashboards -> "PCA 4.1 — Target Health": the panel now draws up == 1.
#   * Explore -> query  up  -> returns 1 for job="prometheus".
#   Quick CLI confirmation of the underlying signal:
#       curl -s 'http://localhost:9090/api/v1/query?query=up' | grep -o '"value":\[[^]]*\]'
#
# TEARDOWN
#       "$0" cleanup
#
# TAKEAWAY (PCA 4.1)
#   A dashboard is only ever as good as its data source wiring. Before touching
#   panels or PromQL, confirm the data source test passes: separate "the graph
#   is empty" from "the backend is unreachable". Grafana's Prometheus data
#   source is an HTTP proxy — a wrong port/URL/scheme surfaces as a refused
#   connection at "Save & test", never as a query-syntax problem. And because
#   provisioned data sources are read-only, the fix belongs in version-controlled
#   config, which is exactly how you keep dashboards reproducible in production.
# ###########################################################################