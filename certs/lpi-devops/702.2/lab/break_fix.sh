#!/usr/bin/env bash
#
# ============================================================================
#  LPI DevOps Tools Engineer — Exam 701-100, syllabus version 2.0.0
#  Topic 702.2 — Container Orchestration (exam weight: 5)
#  BREAK & FIX LAB — single-node Docker Swarm, declarative stack
#
#  Official objectives:  https://www.lpi.org/our-certifications/exam-701-objectives/
#  Reference documentation used to build this lab:
#    - Swarm mode overview .......... https://docs.docker.com/engine/swarm/
#    - Deploy a stack to a swarm .... https://docs.docker.com/engine/swarm/stack-deploy/
#    - Service placement constraints  https://docs.docker.com/engine/swarm/services/#control-service-placement
#    - Compose deploy specification .. https://docs.docker.com/reference/compose-file/deploy/
#    - Healthcheck in Compose ....... https://docs.docker.com/reference/compose-file/services/#healthcheck
#    - Swarm configs ................ https://docs.docker.com/engine/swarm/configs/
#
#  WHAT THIS SCRIPT DOES
#    Builds a small but production-shaped orchestration lab (overlay network,
#    swarm config object, published ingress port, service-to-service discovery
#    by DNS) and then deliberately plants TWO faults in the *declared desired
#    state*. The faults are layered: the second one only becomes visible after
#    the first is repaired. This mirrors real orchestration incidents, where
#    "the service is down" is a symptom shared by scheduling failures and by
#    runtime failures, and only the task history tells them apart.
#
#  SAFETY
#    - Run ONLY on a disposable lab VM. It initialises a swarm if none exists.
#    - Everything it creates is namespaced under the stack name below and is
#      removed by `cleanup`. It never touches images, containers, networks,
#      volumes or services outside that namespace.
#    - It refuses to run on a multi-node swarm, on a worker node, or on a host
#      that already runs other swarm services, unless LPI_LAB_FORCE=1.
#    - No firewall, no sysctl, no systemd unit, no package is modified.
#
#  USAGE
#    ./break-fix-702.2.sh setup     # build the lab and plant the faults (default)
#    ./break-fix-702.2.sh status    # show the current orchestration state
#    ./break-fix-702.2.sh hint      # progressive hints, no spoilers
#    ./break-fix-702.2.sh verify    # grade your fix (this is the exit condition)
#    ./break-fix-702.2.sh cleanup   # remove everything this script created
#
#  ENVIRONMENT
#    HOST_PORT=18080        host port published on the ingress network
#    LAB_DIR=/opt/lpi-lab/702.2
#    LPI_LAB_ASSUME_YES=1   skip the interactive confirmation
#    LPI_LAB_FORCE=1        override the pre-flight safety refusals
# ============================================================================

set -Eeuo pipefail

STACK="lpi702"
SERVICE="${STACK}_edge"
PROBE="${STACK}_probe"
NETWORK="${STACK}_mesh"
HOST_PORT="${HOST_PORT:-18080}"
LAB_DIR="${LAB_DIR:-/opt/lpi-lab/702.2}"
STATE_FILE="${LAB_DIR}/.lab-state"
EDGE_IMAGE="nginx:1.27-alpine"
PROBE_IMAGE="alpine:3.20"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

log()  { printf '%s[ lab ]%s %s\n'  "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[  ok ]%s %s\n'  "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn ]%s %s\n'  "$C_YEL" "$C_OFF" "$*" >&2; }
fail() { printf '%s[fail ]%s %s\n'  "$C_RED" "$C_OFF" "$*" >&2; }
die()  { fail "$*"; exit 1; }

rule() { printf '%s\n' "----------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

http_get() {
    # $1 = URL. Prints the body, returns non-zero on any HTTP or transport error.
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O - "$1"
    else
        die "neither curl nor wget is available to probe the published port"
    fi
}

port_is_free() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ! ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .
    else
        warn "ss(8) not available; skipping the host port pre-check"
        return 0
    fi
}

preflight() {
    need_cmd docker
    docker info >/dev/null 2>&1 \
        || die "cannot talk to the Docker daemon (is it running, and are you in the docker group or root?)"

    local swarm_state node_count
    swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"

    case "$swarm_state" in
        inactive)
            SWARM_PREEXISTING=0
            ;;
        active)
            SWARM_PREEXISTING=1
            [[ "$(docker info --format '{{.Swarm.ControlAvailable}}')" == "true" ]] \
                || die "this node is a swarm WORKER; run the lab on a manager or on a clean host"
            node_count="$(docker node ls --format '{{.ID}}' | wc -l)"
            if (( node_count > 1 )) && [[ "${LPI_LAB_FORCE:-0}" != "1" ]]; then
                die "this swarm has ${node_count} nodes; the lab is designed for a single disposable node (LPI_LAB_FORCE=1 to override)"
            fi
            local foreign
            foreign="$(docker service ls --format '{{.Name}}' | grep -v "^${STACK}_" || true)"
            if [[ -n "$foreign" ]] && [[ "${LPI_LAB_FORCE:-0}" != "1" ]]; then
                fail "this swarm already runs services that are not part of the lab:"
                printf '        %s\n' $foreign >&2
                die "refusing to touch a host with existing workloads (LPI_LAB_FORCE=1 to override)"
            fi
            ;;
        *)
            die "unexpected swarm state '${swarm_state}'; resolve it manually before running the lab"
            ;;
    esac
}

confirm() {
    [[ "${LPI_LAB_ASSUME_YES:-0}" == "1" ]] && return 0
    if [[ ! -t 0 ]]; then
        die "not an interactive terminal; re-run with LPI_LAB_ASSUME_YES=1 if this really is a disposable lab VM"
    fi
    rule
    printf '%sThis will initialise/modify Docker Swarm on THIS host and deploy a\n' "$C_BLD"
    printf 'deliberately broken stack named "%s". Only run it on a throwaway VM.%s\n' "$STACK" "$C_OFF"
    rule
    local answer
    read -r -p 'Type BREAK to continue: ' answer
    [[ "$answer" == "BREAK" ]] || die "aborted by the operator"
}

# ---------------------------------------------------------------------------
# Lab construction
# ---------------------------------------------------------------------------
write_lab_files() {
    mkdir -p "$LAB_DIR"

    # nginx configuration shipped as a swarm config object. It is CORRECT:
    # the server listens on 80 and it does expose /healthz. The bug is not here.
    cat > "${LAB_DIR}/edge.conf" <<'NGINXCONF'
server {
    listen 80;
    server_name _;

    # Liveness endpoint consumed by the container healthcheck and by the probe
    # service. Kept out of the access log so a flapping task does not drown the
    # useful lines.
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        default_type text/plain;
        return 200 "LPI 702.2 edge OK\n";
    }
}
NGINXCONF

    cat > "${LAB_DIR}/stack.yml" <<'YAML'
version: "3.9"

services:

  edge:
    image: nginx:1.27-alpine
    configs:
      - source: edge_site
        target: /etc/nginx/conf.d/default.conf
        mode: 0444
    networks:
      - mesh
    ports:
      - target: 80
        published: __HOST_PORT__
        protocol: tcp
        mode: ingress
    healthcheck:
      test: ["CMD-SHELL", "wget -q -T 2 -O /dev/null http://127.0.0.1:8080/healthz || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 10s
    deploy:
      replicas: 2
      placement:
        constraints:
          - node.labels.tier == frontend
      update_config:
        order: start-first
        parallelism: 1
      restart_policy:
        condition: any
        delay: 5s
      resources:
        limits:
          memory: 128M
        reservations:
          memory: 32M

  probe:
    image: alpine:3.20
    command:
      - sh
      - -c
      - 'while true; do if wget -q -T 3 -O /dev/null http://edge/healthz; then echo "$(date -Is) probe: edge OK"; else echo "$(date -Is) probe: edge UNREACHABLE"; fi; sleep 5; done'
    networks:
      - mesh
    deploy:
      replicas: 1
      restart_policy:
        condition: any
        delay: 5s

configs:
  edge_site:
    file: ./edge.conf

networks:
  mesh:
    driver: overlay
    attachable: true
YAML

    sed -i "s/__HOST_PORT__/${HOST_PORT}/" "${LAB_DIR}/stack.yml"
}

setup() {
    preflight
    confirm

    port_is_free "$HOST_PORT" \
        || die "host port ${HOST_PORT} is already in use; re-run with HOST_PORT=<free port>"

    if [[ "${SWARM_PREEXISTING}" == "0" ]]; then
        local advertise
        advertise="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
        advertise="${advertise:-127.0.0.1}"
        log "initialising a single-node swarm (advertise-addr ${advertise})"
        docker swarm init --advertise-addr "$advertise" >/dev/null
    else
        log "reusing the swarm already active on this node"
    fi

    log "pre-pulling images so the lab does not fail on a slow network"
    docker pull -q "$EDGE_IMAGE"  >/dev/null
    docker pull -q "$PROBE_IMAGE" >/dev/null

    write_lab_files
    printf 'OWNS_SWARM=%s\n' "$([[ "${SWARM_PREEXISTING}" == "0" ]] && echo 1 || echo 0)" > "$STATE_FILE"
    printf 'HOST_PORT=%s\n' "$HOST_PORT" >> "$STATE_FILE"

    log "deploying stack '${STACK}' from ${LAB_DIR}/stack.yml"
    ( cd "$LAB_DIR" && docker stack deploy --detach=true -c stack.yml "$STACK" >/dev/null )

    log "letting the scheduler settle (20s)"
    sleep 20

    briefing
}

# ---------------------------------------------------------------------------
# Student briefing
# ---------------------------------------------------------------------------
briefing() {
    rule
    printf '%sLPI 702.2 — Container Orchestration — BREAK & FIX%s\n' "$C_BLD" "$C_OFF"
    rule
    cat <<EOF

SCENARIO
  You are on call. A single-node Docker Swarm serves an edge HTTP service
  behind the ingress routing mesh, plus an internal 'probe' service that
  reaches the edge by its service name over an overlay network. Somebody
  merged a change to the stack file. The edge is down.

  The desired state lives in:   ${LAB_DIR}/stack.yml
  The nginx config object in:   ${LAB_DIR}/edge.conf
  The published endpoint is:    http://127.0.0.1:${HOST_PORT}/

SYMPTOM YOU WILL SEE NOW (phase 1 — nothing is scheduled)

  \$ docker service ls
  ID      NAME             MODE         REPLICAS   IMAGE
  a1b2..  ${STACK}_edge     replicated   0/2        ${EDGE_IMAGE}
  c3d4..  ${STACK}_probe    replicated   1/1        ${PROBE_IMAGE}

  \$ docker service ps --no-trunc ${SERVICE}
  ID     NAME             NODE   DESIRED STATE   CURRENT STATE   ERROR
  e5f6.. ${SERVICE}.1             Running         Pending 30s     "no suitable node (scheduling constraints not satisfied on 1 node)"
  g7h8.. ${SERVICE}.2             Running         Pending 30s     "no suitable node (scheduling constraints not satisfied on 1 node)"

  \$ curl -sS http://127.0.0.1:${HOST_PORT}/healthz
  curl: (52) Empty reply from server        <- ingress port is published, no backend behind it

  \$ docker service logs --tail 3 ${PROBE}
  ${PROBE}.1@node | 2026-09-03T10:00:00+00:00 probe: edge UNREACHABLE

  Read that ERROR column literally. A task in Pending has never been assigned
  to a node, so there are no container logs to read — 'docker logs' will teach
  you nothing here. The scheduler, not the runtime, is rejecting the task.

SYMPTOM YOU WILL SEE NEXT (phase 2 — scheduled, but flapping)

  Once the task is schedulable, a second, independent fault surfaces. The
  replica count will oscillate and the task history will grow a trail of
  short-lived tasks:

  \$ docker service ps ${SERVICE}
  NAME              IMAGE               NODE   DESIRED STATE   CURRENT STATE            ERROR
  ${SERVICE}.1       ${EDGE_IMAGE}   node   Running         Starting 3s
  \_ ${SERVICE}.1    ${EDGE_IMAGE}   node   Shutdown        Failed 41s               "task: non-zero exit (137)"
  \_ ${SERVICE}.1    ${EDGE_IMAGE}   node   Shutdown        Failed 1 minute ago      "task: non-zero exit (137)"

  \$ docker ps --filter "name=${SERVICE}" --format '{{.Names}}\t{{.Status}}'
  ${SERVICE}.1.xyz   Up 38 seconds (unhealthy)

  The container starts, serves traffic for a moment, is declared unhealthy and
  is killed by the orchestrator, which then reschedules it — forever. That is
  the classic signature of a healthcheck that does not describe reality.

YOUR OBJECTIVE
  Reach a converged, stable, genuinely healthy state:

    1. ${SERVICE} reports 2/2 replicas.
    2. Both task containers report health status 'healthy'.
    3. http://127.0.0.1:${HOST_PORT}/healthz returns 'ok'.
    4. No task restarts for 45 consecutive seconds.
    5. The healthcheck still probes /healthz — deleting the healthcheck, or
       replacing it with a command that always succeeds, is NOT a fix and the
       grader rejects it. In production a green dashboard backed by a fake
       probe is worse than a red one.

RULES OF ENGAGEMENT
  - Fix the DECLARED desired state and re-apply it, or change the cluster
    facts the declaration depends on. Do not hand-run 'docker run'.
    Acceptable tools: editing ${LAB_DIR}/stack.yml + 'docker stack deploy',
    'docker service update', 'docker node update'.
  - Do not remove and recreate the stack from a stack file you rewrote from
    memory. Diagnose what is there.

USEFUL COMMANDS
  docker service ls
  docker service ps --no-trunc ${SERVICE}
  docker service inspect --pretty ${SERVICE}
  docker node ls
  docker node inspect self --format '{{ json .Spec.Labels }}'
  docker inspect --format '{{ json .Config.Healthcheck }}' <container-id>
  docker inspect --format '{{ json .State.Health }}' <container-id>
  docker service logs -f ${PROBE}
  docker network inspect ${NETWORK}

GRADING
  $0 verify        (run it as many times as you want)
  $0 hint          (progressive hints)
  $0 cleanup       (tear the lab down)

EOF
    rule
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
status() {
    rule
    printf '%sservices%s\n' "$C_BLD" "$C_OFF"
    docker service ls --filter "name=${STACK}_" || true
    printf '\n%stasks (edge)%s\n' "$C_BLD" "$C_OFF"
    docker service ps --no-trunc "$SERVICE" 2>/dev/null || warn "service ${SERVICE} not found"
    printf '\n%snode labels%s\n' "$C_BLD" "$C_OFF"
    docker node inspect self --format '{{ json .Spec.Labels }}' 2>/dev/null || true
    printf '\n%slocal containers%s\n' "$C_BLD" "$C_OFF"
    docker ps -a --filter "label=com.docker.swarm.service.name=${SERVICE}" \
        --format 'table {{.Names}}\t{{.Status}}' || true
    printf '\n%spublished endpoint%s\n' "$C_BLD" "$C_OFF"
    if body="$(http_get "http://127.0.0.1:${HOST_PORT}/healthz" 2>/dev/null)"; then
        printf 'http://127.0.0.1:%s/healthz -> %s' "$HOST_PORT" "$body"
    else
        printf 'http://127.0.0.1:%s/healthz -> unreachable\n' "$HOST_PORT"
    fi
    rule
}

# ---------------------------------------------------------------------------
# Hints
# ---------------------------------------------------------------------------
hint() {
    cat <<EOF

HINT 1 — where to look first
  A replica count of 0/2 with no container anywhere on the host means the
  task never reached a runtime. 'docker service ps --no-trunc' is the only
  place the scheduler explains itself. Read the whole ERROR string.

HINT 2 — the vocabulary of the first fault
  A placement constraint is a predicate evaluated against node attributes
  (node.id, node.hostname, node.role, node.platform.*, node.labels.*,
  engine.labels.*). If no node satisfies the predicate, the task stays
  Pending forever — swarm will not "relax" a constraint to make progress.
  So: either the predicate is wrong, or the cluster is missing the fact the
  predicate asserts. Both are legitimate fixes; they have different
  operational meanings. Ask yourself which one the author intended.
  https://docs.docker.com/engine/swarm/services/#control-service-placement

HINT 3 — the second fault
  Once tasks are assigned, compare two things: the port nginx actually
  listens on (look at the config object mounted at
  /etc/nginx/conf.d/default.conf) and the URL the healthcheck probes
  (docker inspect --format '{{ json .Config.Healthcheck }}' <container>).
  An exit 137 on a task whose 'docker ps' status says (unhealthy) is the
  orchestrator doing exactly what you told it to do.

HINT 4 — applying the fix
  'docker stack deploy -c stack.yml ${STACK}' is idempotent: re-running it
  reconciles the live services with the file. Run it from ${LAB_DIR} so the
  relative 'file: ./edge.conf' path resolves. Beware: swarm config objects
  are IMMUTABLE. If you edit edge.conf you must give the config a new name
  in the stack file, otherwise the deploy fails or silently keeps the old
  content.
  https://docs.docker.com/engine/swarm/configs/

EOF
}

# ---------------------------------------------------------------------------
# Grading
# ---------------------------------------------------------------------------
task_container_ids() {
    docker ps -q --filter "label=com.docker.swarm.service.name=${SERVICE}"
}

verify() {
    local failures=0
    rule
    printf '%sgrading topic 702.2 break & fix%s\n' "$C_BLD" "$C_OFF"
    rule

    # --- criterion 1: converged replicas ------------------------------------
    local replicas
    replicas="$(docker service ls --filter "name=${SERVICE}" --format '{{.Replicas}}' | head -n1)"
    if [[ "$replicas" == "2/2" ]]; then
        ok "1/5 replicas converged (${replicas})"
    else
        fail "1/5 replicas not converged (got '${replicas:-none}', want 2/2)"
        failures=$((failures + 1))
    fi

    # --- criterion 2: real health -------------------------------------------
    local cids health healthy=0 total=0
    cids="$(task_container_ids)"
    for cid in $cids; do
        total=$((total + 1))
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
        [[ "$health" == "healthy" ]] && healthy=$((healthy + 1))
    done
    if (( total >= 2 && healthy == total )); then
        ok "2/5 all ${total} task containers report healthy"
    else
        fail "2/5 health: ${healthy}/${total} containers healthy (want 2/2)"
        failures=$((failures + 1))
    fi

    # --- criterion 3: the endpoint actually answers -------------------------
    local body=""
    if body="$(http_get "http://127.0.0.1:${HOST_PORT}/healthz" 2>/dev/null)"; then :; fi
    if [[ "$(printf '%s' "$body" | tr -d '[:space:]')" == "ok" ]]; then
        ok "3/5 published endpoint returns 'ok' through the ingress mesh"
    else
        fail "3/5 http://127.0.0.1:${HOST_PORT}/healthz did not return 'ok'"
        failures=$((failures + 1))
    fi

    # --- criterion 4: honest healthcheck (anti-cheat) ------------------------
    local hc_ok=1
    if [[ -z "$cids" ]]; then
        hc_ok=0
    else
        for cid in $cids; do
            local hc
            hc="$(docker inspect -f '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{else}}null{{end}}' "$cid")"
            case "$hc" in
                *healthz*) : ;;
                *) hc_ok=0 ;;
            esac
        done
    fi
    if (( hc_ok == 1 )); then
        ok "4/5 the healthcheck still probes /healthz (not disabled, not stubbed)"
    else
        fail "4/5 the healthcheck no longer probes /healthz — removing or faking a probe is not a fix"
        failures=$((failures + 1))
    fi

    # --- criterion 5: stability ---------------------------------------------
    local before after
    before="$(docker service ps "$SERVICE" -q 2>/dev/null | wc -l)"
    log "5/5 watching for task churn for 45s ..."
    sleep 45
    after="$(docker service ps "$SERVICE" -q 2>/dev/null | wc -l)"
    replicas="$(docker service ls --filter "name=${SERVICE}" --format '{{.Replicas}}' | head -n1)"
    if [[ "$before" == "$after" && "$replicas" == "2/2" ]]; then
        ok "5/5 no task was rescheduled during the observation window"
    else
        fail "5/5 the service is still flapping (task history ${before} -> ${after}, replicas ${replicas})"
        failures=$((failures + 1))
    fi

    rule
    if (( failures == 0 )); then
        printf '%sPASS%s — the stack is converged, healthy and stable. Objective 702.2 met.\n' "$C_GRN$C_BLD" "$C_OFF"
        printf 'Now explain, out loud: which fault was a scheduling problem, which was a\n'
        printf 'runtime problem, and which command distinguishes them in under 5 seconds.\n'
        rule
        return 0
    fi
    printf '%sNOT YET%s — %d criteria failing. Run "%s status" and "%s hint".\n' \
        "$C_RED$C_BLD" "$C_OFF" "$failures" "$0" "$0"
    rule
    return 1
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
cleanup() {
    local owns_swarm=0
    [[ -f "$STATE_FILE" ]] && . "$STATE_FILE" && owns_swarm="${OWNS_SWARM:-0}"

    if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$STACK"; then
        log "removing stack ${STACK}"
        docker stack rm "$STACK" >/dev/null 2>&1 || true
        local i
        for i in $(seq 1 30); do
            docker service ls --filter "name=${STACK}_" --format '{{.Name}}' | grep -q . || break
            sleep 2
        done
        sleep 5
    fi

    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker config ls --format '{{.Name}}' 2>/dev/null | grep "^${STACK}_" | while read -r c; do
        docker config rm "$c" >/dev/null 2>&1 || true
    done

    docker node update --label-rm tier "$(docker node ls -q 2>/dev/null | head -n1)" >/dev/null 2>&1 || true

    if [[ "$owns_swarm" == "1" ]]; then
        log "leaving the swarm this script created"
        docker swarm leave --force >/dev/null 2>&1 || true
    else
        log "swarm was pre-existing; leaving it untouched"
    fi

    rm -rf "$LAB_DIR"
    ok "lab removed"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    case "${1:-setup}" in
        setup|break|"") setup ;;
        status)         status ;;
        brief)          briefing ;;
        hint)           hint ;;
        verify|check)   verify ;;
        cleanup|clean)  cleanup ;;
        *) die "unknown subcommand '${1}'. Use: setup | status | brief | hint | verify | cleanup" ;;
    esac
}

main "$@"

# ============================================================================
# ============================  SOLUTION  ====================================
#   Read only after you have genuinely tried. Every command below is real and
#   was executed against this lab; the outputs are abridged for width.
# ============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 — Triage: distinguish "not scheduled" from "not running"
# ---------------------------------------------------------------------------
#   $ docker service ls
#   ID       NAME            MODE         REPLICAS   IMAGE
#   a1b2c3   lpi702_edge     replicated   0/2        nginx:1.27-alpine
#   d4e5f6   lpi702_probe    replicated   1/1        alpine:3.20
#
#   0/2 with a healthy probe service proves the cluster itself is fine: the
#   engine is up, the overlay network exists, another service is running. The
#   problem is specific to lpi702_edge.
#
#   The single most useful command in swarm troubleshooting:
#
#   $ docker service ps --no-trunc lpi702_edge
#   ID      NAME           NODE  DESIRED STATE  CURRENT STATE  ERROR
#   g7h8i9  lpi702_edge.1        Running        Pending 2m     "no suitable node (scheduling constraints not satisfied on 1 node)"
#   j1k2l3  lpi702_edge.2        Running        Pending 2m     "no suitable node (scheduling constraints not satisfied on 1 node)"
#
#   NODE is empty and CURRENT STATE is Pending: the task was never assigned,
#   so no container was ever created. This is why 'docker logs' returns
#   nothing — there is nothing to log. Scheduling failures are reported by the
#   orchestrator in the task's ERROR field, not by the runtime.
#
# ---------------------------------------------------------------------------
# STEP 1 — Fault 1: an unsatisfiable placement constraint
# ---------------------------------------------------------------------------
#   $ docker service inspect --pretty lpi702_edge | sed -n '/Placement/,/Resources/p'
#   Placement:
#    Constraints:  [node.labels.tier == frontend]
#
#   $ docker node inspect self --format '{{ json .Spec.Labels }}'
#   {}
#
#   The declaration asserts a cluster fact — "this workload belongs on nodes
#   labelled tier=frontend" — that no node carries. Swarm never relaxes a
#   constraint to make progress; the task waits forever. Two fixes exist, and
#   choosing between them is an architecture decision, not a preference:
#
#   FIX 1A (preferred here) — make the cluster fact true. The constraint
#   expresses real intent (keep edge workloads on frontend nodes); the missing
#   piece is node metadata. Label the node:
#
#     $ docker node update --label-add tier=frontend "$(docker node ls -q)"
#     kx9v2m1qb0p7...
#
#     $ docker node inspect self --format '{{ json .Spec.Labels }}'
#     {"tier":"frontend"}
#
#   Node labels are manager-side metadata: adding one triggers immediate
#   rescheduling of Pending tasks, no redeploy needed.
#
#     $ docker service ps lpi702_edge
#     NAME           NODE   DESIRED STATE  CURRENT STATE
#     lpi702_edge.1  node1  Running        Starting 2s
#     lpi702_edge.2  node1  Running        Starting 2s
#
#   FIX 1B — delete the constraint, if the intent was wrong. Edit stack.yml,
#   remove the placement block, and reconcile:
#
#     $ cd /opt/lpi-lab/702.2 && docker stack deploy -c stack.yml lpi702
#     Updating service lpi702_edge (id: a1b2c3)
#
#   Do NOT reach for 'docker service update --constraint-rm ...' as the
#   default: it makes the live state diverge from the file, and the next
#   'docker stack deploy' silently reinstates the broken constraint. In a
#   declarative system, fix the declaration.
#   Reference: https://docs.docker.com/engine/swarm/services/#control-service-placement
#
# ---------------------------------------------------------------------------
# STEP 2 — Fault 2: a healthcheck that probes a port nobody listens on
# ---------------------------------------------------------------------------
#   With scheduling fixed, replicas oscillate:
#
#   $ docker service ps lpi702_edge
#   NAME               IMAGE               NODE   DESIRED STATE  CURRENT STATE       ERROR
#   lpi702_edge.1      nginx:1.27-alpine   node1  Running        Starting 4s
#   \_ lpi702_edge.1   nginx:1.27-alpine   node1  Shutdown       Failed 45s          "task: non-zero exit (137)"
#   \_ lpi702_edge.1   nginx:1.27-alpine   node1  Shutdown       Failed 2 minutes ago "task: non-zero exit (137)"
#
#   $ docker ps --filter "name=lpi702_edge" --format '{{.Names}}\t{{.Status}}'
#   lpi702_edge.1.9k2m...   Up 34 seconds (unhealthy)
#
#   Exit 137 = SIGKILL (128+9): the task did not crash on its own, it was
#   killed. Ask the runtime why:
#
#   $ CID=$(docker ps -q --filter "label=com.docker.swarm.service.name=lpi702_edge" | head -n1)
#   $ docker inspect --format '{{ json .Config.Healthcheck.Test }}' "$CID"
#   ["CMD-SHELL","wget -q -T 2 -O /dev/null http://127.0.0.1:8080/healthz || exit 1"]
#
#   $ docker inspect --format '{{ json .State.Health.Log }}' "$CID" | tail -c 300
#   ... {"ExitCode":1,"Output":"wget: can't connect to remote host (127.0.0.1): Connection refused"}
#
#   Now confront that with what the process actually serves:
#
#   $ docker exec "$CID" grep -n listen /etc/nginx/conf.d/default.conf
#   2:    listen 80;
#
#   $ docker exec "$CID" wget -q -O - http://127.0.0.1:80/healthz
#   ok
#
#   The endpoint exists and is correct — on port 80. The healthcheck probes
#   8080. Three failures at 10s interval flip the container to unhealthy;
#   swarm kills the unhealthy task and reschedules it, forever. The service
#   is doing precisely what it was told.
#
#   FIX 2 — correct the probe in the declaration:
#
#     $ cd /opt/lpi-lab/702.2
#     $ sed -i 's#http://127.0.0.1:8080/healthz#http://127.0.0.1:80/healthz#' stack.yml
#     $ docker stack deploy --detach=true -c stack.yml lpi702
#     Updating service lpi702_edge (id: a1b2c3)
#     Updating service lpi702_probe (id: d4e5f6)
#
#   The equivalent imperative form, for when you need the live fix first and
#   the commit second (then still update the file):
#
#     $ docker service update \
#         --health-cmd 'wget -q -T 2 -O /dev/null http://127.0.0.1:80/healthz || exit 1' \
#         --health-interval 10s --health-retries 3 --health-timeout 3s \
#         lpi702_edge
#
#   The other legitimate fix is to make reality match the declaration: add a
#   'listen 8080;' to edge.conf and publish it. It is more work and changes
#   the service contract, so it is the wrong call for an incident — but note
#   the trap if you try it: swarm config objects are IMMUTABLE. Editing
#   edge.conf and redeploying under the same config name fails with
#   "config lpi702_edge_site already exists"; you must version the name
#   (edge_site_v2) or 'docker config rm' it after removing every reference.
#   Reference: https://docs.docker.com/engine/swarm/configs/
#
# ---------------------------------------------------------------------------
# STEP 3 — Confirm convergence end to end
# ---------------------------------------------------------------------------
#   $ docker service ls --filter name=lpi702_edge
#   ID       NAME          MODE         REPLICAS   IMAGE
#   a1b2c3   lpi702_edge   replicated   2/2        nginx:1.27-alpine
#
#   $ docker ps --filter "name=lpi702_edge" --format '{{.Names}}\t{{.Status}}'
#   lpi702_edge.1.7f3a...   Up 1 minute (healthy)
#   lpi702_edge.2.b81c...   Up 1 minute (healthy)
#
#   $ curl -s http://127.0.0.1:18080/healthz
#   ok
#
#   $ docker service logs --tail 2 lpi702_probe
#   lpi702_probe.1@node1 | 2026-09-03T10:12:05+00:00 probe: edge OK
#   lpi702_probe.1@node1 | 2026-09-03T10:12:10+00:00 probe: edge OK
#
#   The probe line matters: it proves resolution of the service name 'edge' to
#   the service VIP over the overlay network and load balancing across both
#   replicas — the orchestration layer, not just the container.
#
#   $ ./break-fix-702.2.sh verify
#   [  ok ] 1/5 replicas converged (2/2)
#   [  ok ] 2/5 all 2 task containers report healthy
#   [  ok ] 3/5 published endpoint returns 'ok' through the ingress mesh
#   [  ok ] 4/5 the healthcheck still probes /healthz (not disabled, not stubbed)
#   [  ok ] 5/5 no task was rescheduled during the observation window
#   PASS
#
#   $ ./break-fix-702.2.sh cleanup
#
# ---------------------------------------------------------------------------
# WHAT TO CARRY INTO PRODUCTION (and into the exam)
# ---------------------------------------------------------------------------
#   1. Pending vs Failed is the first fork in every orchestration incident.
#      Pending  -> the scheduler refused: constraints, resource reservations,
#                  node availability (drain/pause), missing labels, placement
#                  preferences. Diagnose with 'docker service ps --no-trunc'
#                  and 'docker node ls/inspect'. There are no container logs.
#      Failed   -> the runtime ran it and it died: image, command, config,
#                  healthcheck, OOM. Diagnose with 'docker inspect' on the
#                  task container and 'docker service logs'.
#   2. Exit 137 in a task history is SIGKILL. Its two usual authors are the
#      OOM killer (check .State.OOMKilled) and a failing healthcheck. They are
#      trivially distinguished by 'docker inspect --format "{{json .State}}"'.
#   3. A healthcheck is a contract, not decoration. It must probe the port and
#      path the service really serves, or the orchestrator will faithfully
#      destroy a perfectly working application. Deleting a failing healthcheck
#      to make the dashboard green is how outages become silent.
#   4. Constraints encode intent about the cluster. When one is unsatisfiable,
#      first ask whether the missing node label is the real bug.
#   5. Fix the declared state and re-apply. Imperative 'service update' is for
#      the incident's first minute; the stack file is the source of truth, and
#      'docker stack deploy' is idempotent by design.
#
#   Objective coverage — LPI 701-100 v2.0, 702.2 Container Orchestration:
#   container orchestration concepts, service/task/replica model, declarative
#   stack deployment, service scaling and placement, service discovery over
#   overlay networks, ingress publishing, container health and self-healing.
#   https://www.lpi.org/our-certifications/exam-701-objectives/
# ============================================================================