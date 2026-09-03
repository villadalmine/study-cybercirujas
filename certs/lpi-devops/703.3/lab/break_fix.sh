#!/usr/bin/env bash
#
# ============================================================================
#  LPI DevOps Tools Engineer (701-100, v2.0.0)
#  Topic 703.3 - Kubernetes Package Management   (exam weight: 3.33)
#
#  BREAK & FIX LAB  ::  Helm 3 - repositories, releases and chart dependencies
#
#  Reference objectives:
#    https://www.lpi.org/our-certifications/exam-701-objectives/
#  Upstream documentation used to build this lab:
#    https://helm.sh/docs/helm/helm_repo_index/
#    https://helm.sh/docs/helm/helm_dependency/
#    https://helm.sh/docs/topics/charts/#chart-dependencies
#    https://helm.sh/docs/faq/troubleshooting/#helm-fails-with-another-operation-in-progress
#    https://helm.sh/docs/topics/advanced/#storage-backends
#
#  WHAT THIS SCRIPT DOES
#    1. Builds a self-contained Helm lab: a local chart repository served over
#       127.0.0.1, one installed release, and one umbrella chart.
#    2. Breaks three things, on purpose, in three different layers of Helm:
#         FAULT 1 - the repository index (packaging / distribution layer)
#         FAULT 2 - the release storage in Kubernetes (state layer)
#         FAULT 3 - the chart dependency lock (chart authoring layer)
#    3. Tells the student the symptoms and the goal, and gives a machine
#       checkable `verify` subcommand.
#    4. Ships the full solution, commented, at the bottom of this file.
#
#  SAFETY CONTRACT - read before running
#    * DISPOSABLE LAB VM ONLY (k3s / kind / minikube / rancher-desktop).
#    * Everything cluster-side lives in ONE namespace: helm-lab.
#      The script refuses to touch a pre-existing namespace it did not create.
#    * Everything host-side lives under $LAB_HOME (default ~/helm-lab).
#      HELM_REPOSITORY_CONFIG / HELM_REPOSITORY_CACHE / HELM_CACHE_HOME are
#      redirected there, so your real ~/.config/helm is never modified.
#    * The chart repository binds to 127.0.0.1 only - nothing is exposed to
#      the LAN.
#    * The workload template is disabled by default so the lab needs no image
#      pull and works on an air-gapped VM. Set workload.enabled=true if you
#      want real Pods.
#    * `reset` undoes everything: namespace, workspace, background server.
#
#  USAGE
#    ./703.3-break-fix-helm.sh            # setup + break + briefing
#    ./703.3-break-fix-helm.sh brief      # print the briefing again
#    ./703.3-break-fix-helm.sh verify     # grade your repair
#    ./703.3-break-fix-helm.sh reset      # destroy the lab
#
#    LAB_I_UNDERSTAND=yes  skips the interactive confirmation
#    LAB_FORCE_CONTEXT=yes allows a kube-context outside the allowlist
# ============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LAB_HOME="${LAB_HOME:-$HOME/helm-lab}"
NS="${NS:-helm-lab}"
REPO_NAME="labrepo"
REPO_PORT="${REPO_PORT:-8879}"          # historical `helm serve` port
REPO_URL="http://127.0.0.1:${REPO_PORT}"
RELEASE="site"
UMBRELLA="platform"
NS_LABEL_KEY="lpi-lab"
NS_LABEL_VAL="703-3"

SRC_DIR="$LAB_HOME/src"
REPO_DIR="$LAB_HOME/repo"
STATE_DIR="$LAB_HOME/.state"
ENV_FILE="$LAB_HOME/env.sh"
PID_FILE="$STATE_DIR/repo-server.pid"
LOG_FILE="$STATE_DIR/repo-server.log"

# Lab-scoped Helm configuration. This is the single most important safety
# control in the script: no Helm state outside $LAB_HOME is ever written.
export HELM_REPOSITORY_CONFIG="$LAB_HOME/helm/repositories.yaml"
export HELM_REPOSITORY_CACHE="$LAB_HOME/helm/cache"
export HELM_CACHE_HOME="$LAB_HOME/helm/cache"
export HELM_CONFIG_HOME="$LAB_HOME/helm"
export HELM_DATA_HOME="$LAB_HOME/helm/data"

ALLOWED_CONTEXTS_RE='^(k3s-default|kind-.*|minikube|docker-desktop|rancher-desktop|default)$'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_OFF=''
fi

log()  { printf '%s[ lab ]%s %s\n'  "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n'  "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn ]%s %s\n'  "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[fail ]%s %s\n'  "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

trap 'die "aborted at line $LINENO (command: $BASH_COMMAND)"' ERR

# ---------------------------------------------------------------------------
# Preflight - refuse to break anything we are not sure about
# ---------------------------------------------------------------------------
preflight() {
    local cmd
    for cmd in helm kubectl python3 gzip base64 sed; do
        command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
    done

    case "$(helm version --short 2>/dev/null)" in
        v3.*) : ;;
        *)    die "Helm 3 is required (found: $(helm version --short 2>/dev/null || echo none))" ;;
    esac

    kubectl cluster-info >/dev/null 2>&1 \
        || die "no reachable Kubernetes cluster (check your kubeconfig / tunnel)"

    local ctx; ctx="$(kubectl config current-context 2>/dev/null || echo '')"
    if ! [[ "$ctx" =~ $ALLOWED_CONTEXTS_RE ]]; then
        if [ "${LAB_FORCE_CONTEXT:-no}" != "yes" ]; then
            die "kube-context '$ctx' is not a known disposable lab cluster.
       This lab creates and deletes namespace '$NS' and writes Secrets.
       If '$ctx' really is throwaway, re-run with LAB_FORCE_CONTEXT=yes"
        fi
        warn "running against non-allowlisted context '$ctx' (forced)"
    fi

    # Do not adopt a namespace that belongs to somebody else.
    if kubectl get ns "$NS" >/dev/null 2>&1; then
        local mark
        mark="$(kubectl get ns "$NS" -o jsonpath="{.metadata.labels.$NS_LABEL_KEY}" 2>/dev/null || true)"
        [ "$mark" = "$NS_LABEL_VAL" ] \
            || die "namespace '$NS' already exists and was not created by this lab. Refusing to touch it."
    fi

    if (echo >"/dev/tcp/127.0.0.1/$REPO_PORT") 2>/dev/null; then
        die "TCP port $REPO_PORT is already in use. Run '$0 reset', or export REPO_PORT=<free port>."
    fi

    ok "preflight passed (context: $ctx, helm: $(helm version --short))"
}

confirm() {
    [ "${LAB_I_UNDERSTAND:-no}" = "yes" ] && return 0
    rule
    printf '%sThis script intentionally breaks Helm state on this cluster.%s\n' "$C_BLD" "$C_OFF"
    printf 'Cluster context : %s\n' "$(kubectl config current-context)"
    printf 'Namespace used  : %s (created and deleted by this lab)\n' "$NS"
    printf 'Host workspace  : %s\n' "$LAB_HOME"
    rule
    read -r -p "Type 'lab' to continue: " answer
    [ "$answer" = "lab" ] || die "confirmation not given"
}

# ---------------------------------------------------------------------------
# Chart scaffolding - written by hand so every line is explainable
# ---------------------------------------------------------------------------
write_webapp_chart() {
    local d="$SRC_DIR/webapp"
    mkdir -p "$d/templates"

    cat >"$d/Chart.yaml" <<'YAML'
apiVersion: v2
name: webapp
description: Lab chart for LPI 701 topic 703.3 - Kubernetes Package Management
type: application
version: 0.1.0
appVersion: "1.27"
maintainers:
  - name: teach-plat lab
YAML

    cat >"$d/values.yaml" <<'YAML'
# Message rendered into the ConfigMap. Overridable with --set / -f.
message: "hello from webapp"

service:
  type: ClusterIP
  port: 80

# Disabled on purpose: the lab must run on an air-gapped VM with no registry
# access. Enable it only if your lab VM can pull images.
workload:
  enabled: false
  image: nginx:1.27-alpine
  replicas: 1
YAML

    cat >"$d/templates/_helpers.tpl" <<'YAML'
{{- define "webapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "webapp.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "webapp.labels" -}}
app.kubernetes.io/name: {{ include "webapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
YAML

    cat >"$d/templates/configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
data:
  index.html: |
    <!doctype html>
    <html><body><h1>{{ .Values.message }}</h1></body></html>
  chart-version: {{ .Chart.Version | quote }}
  release-revision: {{ .Release.Revision | quote }}
YAML

    cat >"$d/templates/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: {{ include "webapp.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
YAML

    cat >"$d/templates/deployment.yaml" <<'YAML'
{{- if .Values.workload.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.workload.replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "webapp.name" . }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "webapp.name" . }}
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: web
          image: {{ .Values.workload.image }}
          ports:
            - name: http
              containerPort: 80
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html
      volumes:
        - name: content
          configMap:
            name: {{ include "webapp.fullname" . }}
{{- end }}
YAML
}

write_umbrella_chart() {
    local d="$SRC_DIR/$UMBRELLA"
    mkdir -p "$d/templates"

    cat >"$d/Chart.yaml" <<YAML
apiVersion: v2
name: $UMBRELLA
description: Umbrella chart that consumes webapp from the $REPO_NAME repository
type: application
version: 1.0.0
appVersion: "1.0.0"
dependencies:
  - name: webapp
    version: "0.1.0"
    repository: "@$REPO_NAME"
    condition: webapp.enabled
YAML

    cat >"$d/values.yaml" <<'YAML'
webapp:
  enabled: true
  message: "hello from the platform umbrella chart"

banner: "platform stack"
YAML

    cat >"$d/templates/configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-banner
  labels:
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
data:
  banner: {{ .Values.banner | quote }}
YAML
}

# ---------------------------------------------------------------------------
# Local chart repository (packaging + index + static HTTP server)
# ---------------------------------------------------------------------------
start_repo_server() {
    mkdir -p "$STATE_DIR"
    nohup python3 -m http.server "$REPO_PORT" \
        --bind 127.0.0.1 --directory "$REPO_DIR" >"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    local i
    for i in $(seq 1 30); do
        if (echo >"/dev/tcp/127.0.0.1/$REPO_PORT") 2>/dev/null; then
            ok "chart repository serving $REPO_DIR on $REPO_URL (pid $(cat "$PID_FILE"))"
            return 0
        fi
        sleep 0.2
    done
    die "chart repository did not come up; see $LOG_FILE"
}

stop_repo_server() {
    [ -f "$PID_FILE" ] || return 0
    local pid; pid="$(cat "$PID_FILE")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        # Only kill it if it really is our http.server on our workspace.
        if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q "http.server"; then
            kill "$pid" 2>/dev/null || true
            sleep 0.3
            kill -9 "$pid" 2>/dev/null || true
            log "stopped chart repository (pid $pid)"
        else
            warn "pid $pid is not our http.server - leaving it alone"
        fi
    fi
    rm -f "$PID_FILE"
}

# ---------------------------------------------------------------------------
# Setup: a healthy world, so the student can see the difference
# ---------------------------------------------------------------------------
setup_lab() {
    log "building lab workspace under $LAB_HOME"
    mkdir -p "$SRC_DIR" "$REPO_DIR" "$STATE_DIR" "$HELM_REPOSITORY_CACHE" "$HELM_DATA_HOME"

    write_webapp_chart
    write_umbrella_chart

    cat >"$ENV_FILE" <<EOF
# Source this file in every shell you use for topic 703.3.
# It scopes Helm to the lab workspace - your real ~/.config/helm is untouched.
export LAB_HOME="$LAB_HOME"
export HELM_REPOSITORY_CONFIG="$HELM_REPOSITORY_CONFIG"
export HELM_REPOSITORY_CACHE="$HELM_REPOSITORY_CACHE"
export HELM_CACHE_HOME="$HELM_CACHE_HOME"
export HELM_CONFIG_HOME="$HELM_CONFIG_HOME"
export HELM_DATA_HOME="$HELM_DATA_HOME"
export NS="$NS"
export REPO_URL="$REPO_URL"
EOF

    log "packaging webapp-0.1.0 into the repository"
    helm package "$SRC_DIR/webapp" --destination "$REPO_DIR" >/dev/null
    helm repo index "$REPO_DIR" --url "$REPO_URL"

    start_repo_server

    helm repo add "$REPO_NAME" "$REPO_URL" --force-update >/dev/null
    helm repo update "$REPO_NAME" >/dev/null
    ok "repository '$REPO_NAME' registered and indexed"

    kubectl create namespace "$NS" >/dev/null 2>&1 || true
    kubectl label namespace "$NS" "$NS_LABEL_KEY=$NS_LABEL_VAL" --overwrite >/dev/null

    log "installing release '$RELEASE' from ${REPO_NAME}/webapp"
    helm upgrade --install "$RELEASE" "$REPO_NAME/webapp" \
        --namespace "$NS" \
        --version 0.1.0 \
        --set message="production greeting v1" \
        --wait --timeout 2m >/dev/null
    ok "release '$RELEASE' is deployed (revision $(helm get metadata "$RELEASE" -n "$NS" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("revision","1"))' 2>/dev/null || echo 1))"

    # Vendor the dependency once so the student can see a working umbrella
    # chart before we sabotage it.
    helm dependency update "$SRC_DIR/$UMBRELLA" >/dev/null
    ok "umbrella chart '$UMBRELLA' resolved its dependency"
}

# ---------------------------------------------------------------------------
# FAULT 1 - the repository index no longer describes the artifacts on disk
# ---------------------------------------------------------------------------
break_repo_index() {
    log "FAULT 1: rewriting $REPO_DIR/index.yaml so it lies about its contents"

    cp "$REPO_DIR/index.yaml" "$STATE_DIR/index.yaml.orig"

    # A hand-written index that advertises a version nobody ever packaged and
    # hides the one that actually exists. This is exactly what happens in
    # production when a CI job uploads the tarball but the index step fails,
    # or when two publishers race and one overwrites the other's index.
    cat >"$REPO_DIR/index.yaml" <<YAML
apiVersion: v1
entries:
  webapp:
  - apiVersion: v2
    appVersion: "1.29"
    created: "2026-01-01T00:00:00.000000000Z"
    description: Lab chart for LPI 701 topic 703.3 - Kubernetes Package Management
    digest: 0000000000000000000000000000000000000000000000000000000000000000
    name: webapp
    type: application
    urls:
    - $REPO_URL/webapp-0.2.0.tgz
    version: 0.2.0
generated: "2026-01-01T00:00:00.000000000Z"
YAML

    # Poison the client cache too, so the failure survives a naive retry.
    helm repo update "$REPO_NAME" >/dev/null 2>&1 || true
    ok "FAULT 1 injected"
}

# ---------------------------------------------------------------------------
# FAULT 2 - the release storage says an operation is still running
#
# Helm 3 stores each revision as a Secret of type helm.sh/release.v1 named
# sh.helm.release.v1.<release>.v<revision>. The payload in .data.release is
# base64( gzip( JSON ) ), which Kubernetes then base64-encodes again.
# We forge a revision 2 stuck in "pending-upgrade" - byte-for-byte what a
# `helm upgrade` killed mid-flight (OOM, CI timeout, laptop lid) leaves behind.
# ---------------------------------------------------------------------------
break_release_state() {
    log "FAULT 2: forging a stuck 'pending-upgrade' revision for release '$RELEASE'"

    local v1_secret="sh.helm.release.v1.${RELEASE}.v1"
    local v2_secret="sh.helm.release.v1.${RELEASE}.v2"

    kubectl -n "$NS" get secret "$v1_secret" >/dev/null 2>&1 \
        || die "expected $v1_secret to exist - is the release installed?"

    local payload
    payload="$(kubectl -n "$NS" get secret "$v1_secret" -o jsonpath='{.data.release}' \
        | base64 -d | base64 -d | gunzip \
        | python3 -c '
import json, sys
rel = json.load(sys.stdin)
rel["version"] = 2
rel["info"]["status"] = "pending-upgrade"
rel["info"]["description"] = "Preparing upgrade"
json.dump(rel, sys.stdout, separators=(",", ":"))
' | gzip -n -c | base64 -w0)"

    kubectl -n "$NS" create secret generic "$v2_secret" \
        --type=helm.sh/release.v1 \
        --from-literal=release="$payload" >/dev/null

    kubectl -n "$NS" label secret "$v2_secret" \
        owner=helm \
        name="$RELEASE" \
        status=pending-upgrade \
        version=2 \
        "modifiedAt=$(date +%s)" >/dev/null

    ok "FAULT 2 injected"
}

# ---------------------------------------------------------------------------
# FAULT 3 - Chart.lock no longer matches Chart.yaml, and charts/ is empty
# ---------------------------------------------------------------------------
break_chart_dependency() {
    log "FAULT 3: desynchronising Chart.lock and emptying charts/ in '$UMBRELLA'"

    local d="$SRC_DIR/$UMBRELLA"
    rm -rf "$d/charts"
    mkdir -p "$d/charts"

    cat >"$d/Chart.lock" <<YAML
dependencies:
- name: webapp
  repository: "@$REPO_NAME"
  version: 0.0.9
digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
generated: "2020-01-01T00:00:00.000000000Z"
YAML

    ok "FAULT 3 injected"
}

# ---------------------------------------------------------------------------
# The briefing
# ---------------------------------------------------------------------------
brief() {
    cat <<EOF

$(rule)
${C_BLD}LPI 701-100 - Topic 703.3 - Kubernetes Package Management${C_OFF}
${C_BLD}BREAK & FIX: three faults, three layers of Helm${C_OFF}
$(rule)

${C_BLD}FIRST, PREPARE YOUR SHELL${C_OFF} (every new terminal):

    source $ENV_FILE
    kubectl config current-context     # must be your disposable lab cluster

That file redirects HELM_REPOSITORY_CONFIG and the Helm caches into
$LAB_HOME, so nothing you do here can damage your normal Helm setup.

$(rule)
${C_BLD}FAULT 1 - "the chart I need does not exist any more"${C_OFF}
$(rule)
SYMPTOM. The repository is registered and reachable, but it advertises the
wrong content:

    \$ helm repo update $REPO_NAME
    ...Successfully got an update from the "$REPO_NAME" chart repository

    \$ helm search repo $REPO_NAME/webapp --versions
    NAME             CHART VERSION  APP VERSION  DESCRIPTION
    $REPO_NAME/webapp  0.2.0          1.29         Lab chart for LPI 701 topic 703.3...

    \$ helm pull $REPO_NAME/webapp --version 0.1.0
    Error: chart "webapp" version "0.1.0" not found in $REPO_URL repository

    \$ helm pull $REPO_NAME/webapp --version 0.2.0
    Error: failed to fetch $REPO_URL/webapp-0.2.0.tgz : 404 Not Found

YOUR GOAL. Make \`helm search repo $REPO_NAME/webapp --version 0.1.0\` return
version 0.1.0 again, and make \`helm pull\` of that version succeed.
Look at what is physically present in $REPO_DIR and compare it with what
index.yaml claims. Do NOT hand-edit index.yaml: an index is a generated
artifact, and the exam expects you to know which command generates it.

$(rule)
${C_BLD}FAULT 2 - "another operation is in progress"${C_OFF}
$(rule)
SYMPTOM. The release '$RELEASE' cannot be upgraded, rolled forward, or
uninstalled cleanly:

    \$ helm status $RELEASE -n $NS
    NAME: $RELEASE
    STATUS: pending-upgrade
    REVISION: 2

    \$ helm upgrade $RELEASE $REPO_NAME/webapp -n $NS --set message=v2
    Error: UPGRADE FAILED: another operation (install/upgrade/rollback)
    is in progress

Nothing is actually running. This is stale state left by a \`helm upgrade\`
that was killed between "write the pending revision" and "write the result".

YOUR GOAL. Get \`helm status $RELEASE -n $NS\` back to ${C_BLD}deployed${C_OFF}, with no
release Secret left in a pending state, and then prove it by running a real
upgrade that changes the message. Remember where Helm 3 keeps release state:
it is not a file, and it is not an annotation on the Deployment.

    \$ kubectl -n $NS get secrets -l owner=helm --show-labels

$(rule)
${C_BLD}FAULT 3 - "found in Chart.yaml, but missing in charts/ directory"${C_OFF}
$(rule)
SYMPTOM. The umbrella chart $SRC_DIR/$UMBRELLA will not install:

    \$ helm install $UMBRELLA $SRC_DIR/$UMBRELLA -n $NS
    Error: An error occurred while checking for chart dependencies. You may
    need to run \`helm dependency build\` to fetch missing dependencies:
    found in Chart.yaml, but missing in charts/ directory: webapp

    \$ helm dependency build $SRC_DIR/$UMBRELLA
    Error: the lock file (Chart.lock) is out of sync with the dependencies
    file (Chart.yaml). Please update the dependencies

YOUR GOAL. Install the release '$UMBRELLA' in namespace $NS with its webapp
subchart rendered, so that:

    \$ kubectl -n $NS get configmap ${UMBRELLA}-webapp
    \$ kubectl -n $NS get configmap ${UMBRELLA}-banner

both exist. Note the ordering: this fault cannot be fixed before FAULT 1,
because the dependency is resolved ${C_BLD}from the repository index${C_OFF}. That
coupling is the lesson.

$(rule)
${C_BLD}GRADING${C_OFF}
$(rule)
    $0 verify      # checks all three faults, exits non-zero while any fails
    $0 reset       # deletes namespace $NS, $LAB_HOME and the repo server

The full step-by-step solution is at the bottom of this script, commented:

    sed -n '/^# === SOLUTION/,\$p' $0 | less

$(rule)

EOF
}

# ---------------------------------------------------------------------------
# Grading
# ---------------------------------------------------------------------------
rel_status() {
    helm status "$1" -n "$NS" -o json 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["info"]["status"])
except Exception: print("absent")' 2>/dev/null || echo absent
}

verify() {
    local failures=0
    local pass="${C_GRN}PASS${C_OFF}" fail="${C_RED}FAIL${C_OFF}"

    rule
    printf '%sVERIFY - topic 703.3 break & fix%s\n' "$C_BLD" "$C_OFF"
    rule

    # --- FAULT 1 ---------------------------------------------------------
    helm repo update "$REPO_NAME" >/dev/null 2>&1 || true
    if helm search repo "$REPO_NAME/webapp" --version 0.1.0 2>/dev/null | grep -q "$REPO_NAME/webapp"; then
        printf '  [%s] 1a  repository index advertises webapp 0.1.0\n' "$pass"
    else
        printf '  [%s] 1a  repository index does not advertise webapp 0.1.0\n' "$fail"; failures=$((failures+1))
    fi

    local tmp; tmp="$(mktemp -d)"
    if helm pull "$REPO_NAME/webapp" --version 0.1.0 --destination "$tmp" >/dev/null 2>&1; then
        printf '  [%s] 1b  webapp-0.1.0.tgz is downloadable (index matches artifacts)\n' "$pass"
    else
        printf '  [%s] 1b  helm pull of webapp 0.1.0 still fails\n' "$fail"; failures=$((failures+1))
    fi
    rm -rf "$tmp"

    # --- FAULT 2 ---------------------------------------------------------
    local st; st="$(rel_status "$RELEASE")"
    if [ "$st" = "deployed" ]; then
        printf '  [%s] 2a  release %s is deployed\n' "$pass" "$RELEASE"
    else
        printf '  [%s] 2a  release %s status is "%s"\n' "$fail" "$RELEASE" "$st"; failures=$((failures+1))
    fi

    local pend
    pend="$(kubectl -n "$NS" get secrets -l 'owner=helm,status in (pending-install,pending-upgrade,pending-rollback)' \
            -o name 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$pend" = "0" ]; then
        printf '  [%s] 2b  no release Secret left in a pending state\n' "$pass"
    else
        printf '  [%s] 2b  %s release Secret(s) still pending\n' "$fail" "$pend"; failures=$((failures+1))
    fi

    # --- FAULT 3 ---------------------------------------------------------
    st="$(rel_status "$UMBRELLA")"
    if [ "$st" = "deployed" ]; then
        printf '  [%s] 3a  umbrella release %s is deployed\n' "$pass" "$UMBRELLA"
    else
        printf '  [%s] 3a  umbrella release %s status is "%s"\n' "$fail" "$UMBRELLA" "$st"; failures=$((failures+1))
    fi

    if kubectl -n "$NS" get configmap "${UMBRELLA}-webapp" >/dev/null 2>&1; then
        printf '  [%s] 3b  subchart resource %s-webapp exists\n' "$pass" "$UMBRELLA"
    else
        printf '  [%s] 3b  subchart resource %s-webapp is missing\n' "$fail" "$UMBRELLA"; failures=$((failures+1))
    fi

    if [ -f "$SRC_DIR/$UMBRELLA/charts/webapp-0.1.0.tgz" ]; then
        printf '  [%s] 3c  dependency vendored in charts/ (Chart.lock regenerated)\n' "$pass"
    else
        printf '  [%s] 3c  charts/webapp-0.1.0.tgz not vendored\n' "$fail"; failures=$((failures+1))
    fi

    rule
    if [ "$failures" -eq 0 ]; then
        printf '%sALL CHECKS PASSED%s - topic 703.3 objectives met.\n' "$C_GRN$C_BLD" "$C_OFF"
        rule
        return 0
    fi
    printf '%s%d check(s) failing%s - keep going, or read the SOLUTION block at the end of %s\n' \
        "$C_RED$C_BLD" "$failures" "$C_OFF" "$0"
    rule
    return 1
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
reset_lab() {
    trap - ERR
    log "tearing down the lab"
    stop_repo_server

    if kubectl get ns "$NS" >/dev/null 2>&1; then
        local mark
        mark="$(kubectl get ns "$NS" -o jsonpath="{.metadata.labels.$NS_LABEL_KEY}" 2>/dev/null || true)"
        if [ "$mark" = "$NS_LABEL_VAL" ]; then
            kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
            ok "namespace $NS deletion requested"
        else
            warn "namespace $NS is not labelled $NS_LABEL_KEY=$NS_LABEL_VAL - not deleting it"
        fi
    fi

    # Guard against a mis-set LAB_HOME wiping something real.
    case "$LAB_HOME" in
        "$HOME"/*/) : ;;
        "$HOME"/*)  : ;;
        *) warn "refusing to remove '$LAB_HOME' (outside \$HOME)"; return 0 ;;
    esac
    [ "$LAB_HOME" = "$HOME" ] && { warn "refusing to remove \$HOME"; return 0; }
    rm -rf "$LAB_HOME"
    ok "workspace $LAB_HOME removed"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    case "${1:-run}" in
        run)
            preflight
            confirm
            setup_lab
            break_repo_index
            break_release_state
            break_chart_dependency
            brief
            ;;
        brief)  brief ;;
        verify) trap - ERR; verify ;;
        reset)  reset_lab ;;
        *)
            cat <<EOF
usage: $0 [run|brief|verify|reset]

  run     build the lab, inject the three faults, print the briefing (default)
  brief   print the briefing again
  verify  grade your repair (exit 0 when all checks pass)
  reset   destroy namespace $NS, workspace $LAB_HOME and the repo server
EOF
            exit 2
            ;;
    esac
}

main "$@"
exit $?

# ============================================================================
# === SOLUTION - step by step ================================================
# ============================================================================
#
# Preparation, in every shell:
#
#   source ~/helm-lab/env.sh
#   echo "$HELM_REPOSITORY_CONFIG"     # ~/helm-lab/helm/repositories.yaml
#
# ----------------------------------------------------------------------------
# FAULT 1 - the repository index does not describe the artifacts on disk
# ----------------------------------------------------------------------------
#
# Step 1.1 - Confirm what the client believes:
#
#   $ helm repo list
#   NAME      URL
#   labrepo   http://127.0.0.1:8879
#
#   $ helm search repo labrepo/webapp --versions
#   NAME            CHART VERSION   APP VERSION     DESCRIPTION
#   labrepo/webapp  0.2.0           1.29            Lab chart for LPI 701 ...
#
# Step 1.2 - Confirm what actually exists. An index is a claim; the tarballs
# are the truth:
#
#   $ ls -1 ~/helm-lab/repo/
#   index.yaml
#   webapp-0.1.0.tgz
#
#   $ curl -s http://127.0.0.1:8879/index.yaml | head -20
#   $ curl -sI http://127.0.0.1:8879/webapp-0.2.0.tgz | head -1
#   HTTP/1.0 404 File not found
#
#   The index advertises 0.2.0 (which nobody ever packaged) and omits 0.1.0
#   (which is sitting right there). Its digest field is all zeros, so even if
#   the tarball existed the checksum verification would fail.
#
# Step 1.3 - Regenerate the index from the artifacts. This is the whole point
# of `helm repo index`: it walks the directory, reads each .tgz, and writes
# name/version/appVersion/digest/urls for what is really there.
#
#   $ helm repo index ~/helm-lab/repo --url http://127.0.0.1:8879
#
#   (Use --merge <old-index> when you are appending to a large public repo and
#    do not want to lose entries whose tarballs live elsewhere.)
#
# Step 1.4 - Refresh the client cache. Helm does not re-read the remote index
# on every command; it uses ~/.cache/helm/repository/<repo>-index.yaml
# (here redirected to $HELM_REPOSITORY_CACHE).
#
#   $ helm repo update labrepo
#   ...Successfully got an update from the "labrepo" chart repository
#   Update Complete. Happy Helming!
#
#   $ helm search repo labrepo/webapp --versions
#   NAME            CHART VERSION   APP VERSION     DESCRIPTION
#   labrepo/webapp  0.1.0           1.27            Lab chart for LPI 701 ...
#
#   $ helm pull labrepo/webapp --version 0.1.0 --destination /tmp && ls /tmp/webapp-0.1.0.tgz
#   /tmp/webapp-0.1.0.tgz
#
#   Diagnostic worth remembering: if `helm search repo` disagrees with `curl`
#   on the index, the problem is the cache; if `curl` itself shows the wrong
#   content, the problem is the repository, and only `helm repo index` (or
#   your CI publishing job) fixes it.
#
# ----------------------------------------------------------------------------
# FAULT 2 - release stuck in pending-upgrade
# ----------------------------------------------------------------------------
#
# Step 2.1 - Read the state. Helm 3's default storage backend is a Secret per
# revision, in the release namespace, of type helm.sh/release.v1:
#
#   $ helm status site -n helm-lab
#   NAME: site
#   STATUS: pending-upgrade
#   REVISION: 2
#
#   $ helm history site -n helm-lab
#   REVISION  UPDATED  STATUS           CHART         APP VERSION  DESCRIPTION
#   1         ...      deployed         webapp-0.1.0  1.27         Install complete
#   2         ...      pending-upgrade  webapp-0.1.0  1.27         Preparing upgrade
#
#   $ kubectl -n helm-lab get secrets -l owner=helm --show-labels
#   NAME                        TYPE                 DATA  AGE  LABELS
#   sh.helm.release.v1.site.v1  helm.sh/release.v1   1     5m   ...,status=deployed,version=1
#   sh.helm.release.v1.site.v2  helm.sh/release.v1   1     5m   ...,status=pending-upgrade,version=2
#
# Step 2.2 - Prove nothing is really running before you touch anything. A
# genuine in-flight upgrade must not be interrupted:
#
#   $ kubectl -n helm-lab get jobs,pods
#   No resources found in helm-lab namespace.
#   $ ps -ef | grep -c "[h]elm upgrade"
#   0
#
#   Only when both are empty is the pending revision stale.
#
# Step 2.3 - Preferred fix, `helm rollback` to the last good revision. It is
# transactional, it is auditable in `helm history`, and it is the documented
# remedy:
#
#   $ helm rollback site 1 -n helm-lab --wait --timeout 2m
#   Rollback was a success! Happy Helming!
#
#   $ helm status site -n helm-lab | head -4
#   NAME: site
#   STATUS: deployed
#   REVISION: 3
#
# Step 2.3-bis - Alternative fix when rollback is not viable (for example the
# pending revision is 1, so there is nothing to roll back to): delete the
# pending revision Secret. Surgery on release storage - do it deliberately,
# and only after step 2.2:
#
#   $ kubectl -n helm-lab delete secret sh.helm.release.v1.site.v2
#   secret "sh.helm.release.v1.site.v2" deleted
#
#   If the remaining latest revision is still labelled pending, promote it:
#
#   $ kubectl -n helm-lab patch secret sh.helm.release.v1.site.v1 \
#       --type=merge -p '{"metadata":{"labels":{"status":"deployed"}}}'
#
#   (The label is what `helm list` filters on; the status inside the gzipped
#    payload is what `helm status` prints. Deleting the bad revision entirely
#    keeps the two consistent, which is why it beats patching labels.)
#
# Step 2.4 - Prove the release is operable again with a real upgrade:
#
#   $ helm upgrade site labrepo/webapp -n helm-lab --version 0.1.0 \
#       --set message="production greeting v2" --wait --atomic --timeout 2m
#   Release "site" has been upgraded. Happy Helming!
#
#   $ kubectl -n helm-lab get configmap site-webapp -o jsonpath='{.data.index\.html}'
#   <!doctype html>
#   <html><body><h1>production greeting v2</h1></body></html>
#
#   Note --atomic: it rolls back automatically on failure, which is precisely
#   the flag that prevents this fault class in the first place. Pair it with
#   --timeout, and in CI add `--wait`.
#
# ----------------------------------------------------------------------------
# FAULT 3 - Chart.lock out of sync, charts/ empty
# ----------------------------------------------------------------------------
#
# Step 3.1 - Read the two files that disagree:
#
#   $ cat ~/helm-lab/src/platform/Chart.yaml | sed -n '/dependencies/,$p'
#   dependencies:
#     - name: webapp
#       version: "0.1.0"
#       repository: "@labrepo"
#       condition: webapp.enabled
#
#   $ cat ~/helm-lab/src/platform/Chart.lock
#   dependencies:
#   - name: webapp
#     repository: "@labrepo"
#     version: 0.0.9
#   digest: sha256:0000...
#
#   $ ls -A ~/helm-lab/src/platform/charts/
#   (empty)
#
#   Chart.yaml is the declaration, Chart.lock is the pinned resolution, and
#   charts/ holds the vendored artifacts. `helm dependency build` installs
#   exactly what the lock says and refuses to run when the lock's digest does
#   not match Chart.yaml. `helm dependency update` re-resolves and rewrites
#   the lock. Here Chart.lock is wrong, so `build` is not the command.
#
# Step 3.2 - Re-resolve. This requires FAULT 1 to be fixed already, because
# "@labrepo" is resolved through the repository index:
#
#   $ helm dependency update ~/helm-lab/src/platform
#   Hang tight while we grab the latest from your chart repositories...
#   ...Successfully got an update from the "labrepo" chart repository
#   Update Complete. Happy Helming!
#   Saving 1 charts
#   Downloading webapp from repo http://127.0.0.1:8879
#   Deleting outdated charts
#
#   $ ls -1 ~/helm-lab/src/platform/charts/
#   webapp-0.1.0.tgz
#
#   $ cat ~/helm-lab/src/platform/Chart.lock
#   dependencies:
#   - name: webapp
#     repository: "@labrepo"
#     version: 0.1.0
#   digest: sha256:<real digest>
#   generated: "<now>"
#
# Step 3.3 - Render before you install. Always check that the subchart values
# land where you think they do; parent values address a subchart under a key
# named after the chart (or its alias):
#
#   $ helm template platform ~/helm-lab/src/platform -n helm-lab | grep -A2 'name: platform-webapp'
#
# Step 3.4 - Install:
#
#   $ helm install platform ~/helm-lab/src/platform -n helm-lab --wait --timeout 2m
#   NAME: platform
#   STATUS: deployed
#   REVISION: 1
#
#   $ kubectl -n helm-lab get configmap platform-webapp platform-banner
#   NAME              DATA   AGE
#   platform-webapp   3      10s
#   platform-banner   1      10s
#
#   $ kubectl -n helm-lab get configmap platform-webapp -o jsonpath='{.data.index\.html}'
#   <!doctype html>
#   <html><body><h1>hello from the platform umbrella chart</h1></body></html>
#
#   That last line proves the parent's values.yaml (webapp.message) overrode
#   the subchart default - the mechanism the exam asks about.
#
# ----------------------------------------------------------------------------
# GRADE AND CLEAN UP
# ----------------------------------------------------------------------------
#
#   $ ./703.3-break-fix-helm.sh verify
#   $ ./703.3-break-fix-helm.sh reset
#
# ----------------------------------------------------------------------------
# WHAT TO TAKE TO THE EXAM
# ----------------------------------------------------------------------------
#   * `helm repo index DIR --url URL` generates the index from the tarballs;
#     `helm repo update` only refreshes the local cache. Different layers,
#     different failures.
#   * Helm 3 keeps release state in Secrets of type helm.sh/release.v1 named
#     sh.helm.release.v1.<release>.v<rev>, in the release namespace. No Tiller,
#     no cluster-wide state. `helm history` + `kubectl get secrets -l owner=helm`
#     is the diagnostic pair.
#   * "another operation is in progress" means a pending revision, not a
#     running process. `helm rollback` first; delete the pending Secret only
#     when there is nothing to roll back to.
#   * `helm dependency build` = install what Chart.lock pins (reproducible, use
#     in CI). `helm dependency update` = re-resolve and rewrite Chart.lock.
#   * `--atomic --wait --timeout` on every upgrade is what stops fault 2 from
#     ever happening in production.
# ============================================================================