#!/usr/bin/env bash
#
# ==============================================================================
#  LPI DevOps Tools Engineer (701-100, v2.0.0)
#  Topic 702.1 — Application Container Management        (exam weight: 8.33)
#
#  BREAK & FIX LAB — "the four-service stack that will not serve"
#
#  What this script does
#  ---------------------
#  It builds a small, realistic Docker Compose stack (reverse proxy -> API ->
#  cache, plus a sidecar worker writing to a bind mount) and injects FIVE
#  independent, controlled faults that are representative of what actually
#  breaks container workloads in production:
#
#      * an image whose ENTRYPOINT cannot be exec'd although the file is there
#      * a non-root container denied write access to a bind-mounted host path
#      * two services on disjoint user-defined bridge networks -> no DNS
#      * a reverse proxy whose upstream name does not resolve at startup
#      * a published port that does not match the listening port
#
#  Everything is confined to one directory, one Compose project and two
#  user-defined bridge networks. The script NEVER touches /etc/docker/daemon.json,
#  never restarts the Docker daemon, never modifies images or containers it did
#  not create, and never writes outside ${LAB_ROOT}.
#
#  STILL: run this on a DISPOSABLE lab VM only.
#
#  Usage
#  -----
#      sudo ./lab-702.1-break-fix.sh break      # deploy the stack and break it
#      sudo ./lab-702.1-break-fix.sh verify     # grade your fix (recreates the stack)
#      sudo ./lab-702.1-break-fix.sh hint       # progressive hints, no spoilers
#      sudo ./lab-702.1-break-fix.sh solution   # full walkthrough (last resort)
#      sudo ./lab-702.1-break-fix.sh cleanup    # remove every lab artefact
#
#  Reference
#  ---------
#      LPI Exam 701 objectives .... https://www.lpi.org/our-certifications/exam-701-objectives/
#      Docker CLI reference ....... https://docs.docker.com/reference/cli/docker/
#      Compose file reference ..... https://docs.docker.com/reference/compose-file/
#      Networking overview ........ https://docs.docker.com/engine/network/
#      Storage / bind mounts ...... https://docs.docker.com/engine/storage/bind-mounts/
#      nginx proxy_pass ........... https://nginx.org/en/docs/http/ngx_http_proxy_module.html
# ==============================================================================

set -euo pipefail

LAB_ID="702.1"
LAB_ROOT="${LAB_ROOT:-/opt/lab-702.1}"
PROJECT="lab702"
MARKER="${LAB_ROOT}/.lab-702.1"
API_IMAGE="lab702/api:1.0"
HOST_PORT="8080"
CONTAINERS=(lab702-cache lab702-api lab702-worker lab702-web)

# ------------------------------------------------------------------------------
# Presentation helpers (colour only on a TTY, and never when NO_COLOR is set)
# ------------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
  C_Y=$'\033[33m'; C_C=$'\033[36m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_C" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$C_B" "------------------------------------------------------------------------" "$C_RST"; }
head1(){ rule; printf '%s%s%s\n' "$C_B" "$*" "$C_RST"; rule; }

compose() { docker compose -f "${LAB_ROOT}/compose.yaml" -p "$PROJECT" "$@"; }

# ------------------------------------------------------------------------------
# Preflight: refuse to run anywhere that is not clearly a throw-away lab host
# ------------------------------------------------------------------------------
preflight() {
  [[ ${EUID} -eq 0 ]] || die "run as root (the lab must create root-owned bind mounts): sudo $0 $*"

  command -v docker >/dev/null 2>&1 || die "docker is not installed. See https://docs.docker.com/engine/install/"
  docker info >/dev/null 2>&1       || die "cannot talk to the Docker daemon. Is it running? systemctl status docker"
  docker compose version >/dev/null 2>&1 \
      || die "Compose v2 plugin missing. Install docker-compose-plugin. https://docs.docker.com/compose/install/"
  command -v curl >/dev/null 2>&1   || die "curl is required for the health checks"

  # Do not clobber somebody's real workload.
  local foreign
  foreign="$(docker ps --format '{{.Names}}' \
             | grep -vE '^lab702-' | wc -l | tr -d ' ')"
  if [[ "$foreign" -gt 0 && "${FORCE:-0}" -ne 1 ]]; then
    docker ps --format '  - {{.Names}} ({{.Image}})' | grep -vE '^\s+- lab702-' || true
    die "this host is running $foreign container(s) that are not part of the lab.
    This script is only safe on a disposable VM. Re-run with --force if you are sure."
  fi

  # Do not steal a port somebody is using.
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${HOST_PORT}$"; then
    [[ "${FORCE:-0}" -eq 1 ]] || die "TCP/${HOST_PORT} is already in use. Free it or re-run with --force."
  fi
}

confirm() {
  [[ "${ASSUME_YES:-0}" -eq 1 ]] && return 0
  say ""
  warn "This will deploy and deliberately BREAK a container stack under ${LAB_ROOT}."
  warn "Only proceed on a disposable lab VM."
  printf 'Type %sBREAK%s to continue: ' "$C_B" "$C_RST"
  local answer; read -r answer
  [[ "$answer" == "BREAK" ]] || die "aborted by the user."
}

# ------------------------------------------------------------------------------
# Lab material
# ------------------------------------------------------------------------------
write_sources() {
  install -d -m 0755 "${LAB_ROOT}" "${LAB_ROOT}/api" "${LAB_ROOT}/web"
  : > "${MARKER}"

  # --- the application: dependency-free, so the image build needs no pip -------
  cat > "${LAB_ROOT}/api/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""Health API for the LPI 702.1 lab.

Deliberately dependency-free: it speaks raw RESP to Redis over a socket, so the
image build never needs a package index. /healthz is the diagnostic surface of
the whole stack:

    cache  -> can this container resolve AND reach the cache service?
    worker -> is the sidecar actually writing to the shared bind mount?
"""
import json
import os
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CACHE_HOST = os.environ.get("CACHE_HOST", "cache")
CACHE_PORT = int(os.environ.get("CACHE_PORT", "6379"))
HEARTBEAT = os.environ.get("HEARTBEAT_FILE", "/var/lib/worker/heartbeat")
PORT = int(os.environ.get("API_PORT", "8000"))
MAX_AGE = 60


def check_cache():
    """PING the cache with a hand-rolled RESP array: *1\\r\\n$4\\r\\nPING\\r\\n"""
    try:
        with socket.create_connection((CACHE_HOST, CACHE_PORT), timeout=2) as sock:
            sock.sendall(b"*1\r\n$4\r\nPING\r\n")
            reply = sock.recv(32)
    except OSError as exc:
        return "error", "%s: %s" % (type(exc).__name__, exc)
    if reply.startswith(b"+PONG"):
        return "ok", "PONG from %s:%d" % (CACHE_HOST, CACHE_PORT)
    return "error", "unexpected RESP reply: %r" % reply


def check_worker():
    try:
        with open(HEARTBEAT, "r", encoding="utf-8") as handle:
            age = time.time() - float(handle.read().strip())
    except (OSError, ValueError) as exc:
        return "error", "%s: %s" % (type(exc).__name__, exc)
    if age > MAX_AGE:
        return "stale", "heartbeat is %ds old" % int(age)
    return "ok", "heartbeat is %ds old" % int(age)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 - stdlib naming
        cache_state, cache_detail = check_cache()
        worker_state, worker_detail = check_worker()
        healthy = cache_state == "ok" and worker_state == "ok"
        body = json.dumps(
            {
                "status": "ok" if healthy else "degraded",
                "service": "lab702-api",
                "uid": os.getuid(),
                "hostname": socket.gethostname(),
                "cache": {"state": cache_state, "detail": cache_detail},
                "worker": {"state": worker_state, "detail": worker_detail},
            },
            indent=2,
        ).encode()
        self.send_response(200 if healthy else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *fargs):
        print("[api] " + fmt % fargs, flush=True)


if __name__ == "__main__":
    print("[api] listening on 0.0.0.0:%d as uid %d" % (PORT, os.getuid()), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF

  # --- entrypoint: written LF here, mangled to CRLF further down (FAULT 1) -----
  cat > "${LAB_ROOT}/api/entrypoint.sh" <<'SHEOF'
#!/bin/sh
set -eu
echo "[entrypoint] uid=$(id -u) gid=$(id -g) cmd=$*"
exec "$@"
SHEOF

  cat > "${LAB_ROOT}/api/Dockerfile" <<'DOCKEOF'
# Small, non-root, single-purpose image - the shape you want in production.
FROM python:3.12-alpine

RUN adduser -D -u 10001 -h /srv appuser

WORKDIR /srv
COPY app.py /srv/app.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENV API_PORT=8000 \
    CACHE_HOST=cache \
    CACHE_PORT=6379 \
    HEARTBEAT_FILE=/var/lib/worker/heartbeat \
    PYTHONUNBUFFERED=1

USER 10001
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["python3", "/srv/app.py"]
DOCKEOF

  cat > "${LAB_ROOT}/web/nginx.conf" <<'NGXEOF'
# nginx resolves the names inside an upstream{} block ONCE, at configuration
# load time. A name that does not exist is a fatal [emerg], not a 502.
upstream api_backend {
    server api-svc:8000;
}

server {
    listen 80;
    server_name _;

    location = /healthz {
        proxy_pass http://api_backend/healthz;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGXEOF

  cat > "${LAB_ROOT}/compose.yaml" <<'CMPEOF'
name: lab702

services:
  cache:
    image: redis:7-alpine
    container_name: lab702-cache
    command: ["redis-server", "--save", "", "--appendonly", "no"]
    networks: [backend]
    restart: unless-stopped

  api:
    build: ./api
    image: lab702/api:1.0
    container_name: lab702-api
    environment:
      CACHE_HOST: cache
      API_PORT: "8000"
    volumes:
      - ./state:/var/lib/worker:ro
    networks: [frontend]
    restart: unless-stopped

  worker:
    image: alpine:3.20
    container_name: lab702-worker
    user: "10001:10001"
    command:
      - sh
      - -c
      - |
        set -e
        echo "[worker] uid=$$(id -u) writing heartbeats to /var/lib/worker"
        while true; do
          date -u +%s > /var/lib/worker/heartbeat
          sleep 5
        done
    volumes:
      - ./state:/var/lib/worker
    networks: [backend]
    restart: unless-stopped

  web:
    image: nginx:1.27-alpine
    container_name: lab702-web
    ports:
      - "8080:8080"
    volumes:
      - ./web/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [frontend]
    depends_on: [api]
    restart: unless-stopped

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
CMPEOF
}

inject_faults() {
  # FAULT 1 - CRLF line endings. The shebang becomes "#!/bin/sh\r", so the kernel
  # looks for an interpreter literally named "/bin/sh\r" and returns ENOENT. Docker
  # surfaces that as "no such file or directory" ABOUT A FILE THAT EXISTS.
  sed -i 's/$/\r/' "${LAB_ROOT}/api/entrypoint.sh"

  # FAULT 2 - the bind-mount target on the host is root-owned 0755, while the
  # worker runs as uid 10001. Bind mounts carry HOST ownership into the container;
  # there is no ownership translation without user namespaces.
  install -d -m 0755 -o 0 -g 0 "${LAB_ROOT}/state"
  rm -f "${LAB_ROOT}/state/heartbeat"

  # FAULT 3 (compose.yaml)  api is only on 'frontend', cache only on 'backend'.
  # FAULT 4 (nginx.conf)    upstream server name 'api-svc' does not exist.
  # FAULT 5 (compose.yaml)  published "8080:8080" while nginx listens on 80.
  # Those three are already baked into the files written above.
  :
}

deploy() {
  info "Pulling base images (this is the only network-heavy step)..."
  for image in redis:7-alpine alpine:3.20 nginx:1.27-alpine python:3.12-alpine; do
    docker pull -q "$image" >/dev/null || die "cannot pull $image - check egress/DNS on this VM"
  done

  info "Building ${API_IMAGE} ..."
  compose build --quiet api >/dev/null

  info "Starting the stack ..."
  compose up -d --remove-orphans >/dev/null 2>&1 || true
  sleep 6
}

briefing() {
  head1 "LAB ${LAB_ID} - Application Container Management :: BREAK & FIX"
  cat <<BRIEF

${C_B}THE SCENARIO${C_RST}
  A four-service stack has just been rolled out on this host:

      client -> [web] nginx reverse proxy -> [api] health API -> [cache] redis
                                              ^
                                              |
                              [worker] sidecar writing heartbeats into a
                                       bind-mounted directory shared with api

  The Compose project is '${PROJECT}' and its sources live in ${LAB_ROOT}:

      compose.yaml        service, network, volume and port definitions
      api/Dockerfile      the image you own and can rebuild
      api/entrypoint.sh   the container entrypoint
      api/app.py          the application (does NOT need editing)
      web/nginx.conf      reverse proxy configuration
      state/              host directory bind-mounted into worker and api

${C_B}THE SYMPTOMS YOU WILL SEE${C_RST}
  1. 'docker compose -p ${PROJECT} ps -a' shows only ${C_B}cache${C_RST} healthy. ${C_B}api${C_RST},
     ${C_B}worker${C_RST} and ${C_B}web${C_RST} sit in 'Restarting (n)' - restart policies are
     hiding three different crashes behind an infinite loop.
  2. 'docker logs lab702-api' reports the entrypoint does ${C_B}not exist${C_RST} - yet
     'docker run --rm --entrypoint sh ${API_IMAGE} -c "ls -l /usr/local/bin/"'
     proves the file is right there, and executable.
  3. 'docker logs lab702-worker' reports ${C_B}Permission denied${C_RST} writing to a
     directory that is mounted and visible.
  4. 'docker logs lab702-web' ends with an nginx ${C_B}[emerg]${C_RST} about a host that
     cannot be found - nginx never even binds a socket.
  5. 'curl -v http://127.0.0.1:${HOST_PORT}/healthz' from the VM returns
     ${C_B}Connection refused / Empty reply${C_RST}, even once nginx finally stays up.

${C_B}YOUR OBJECTIVE${C_RST}
  Make the stack serve. Concretely, all of the following must hold:

    [ ] all four containers Running, with RestartCount back to 0
    [ ] api and worker still run as ${C_B}uid 10001${C_RST} (fixing by switching to
        root is NOT a fix - it is a regression, and it is graded as one)
    [ ] curl http://127.0.0.1:${HOST_PORT}/healthz returns HTTP 200 with
        "status": "ok", cache "ok" and worker "ok"
    [ ] the heartbeat file on the host keeps refreshing
    [ ] ${C_B}the fix survives a full recreate${C_RST}: it must live in the files under
        ${LAB_ROOT}, not in a 'docker exec' applied to a live container

${C_B}RULES OF ENGAGEMENT${C_RST}
  * Edit ${LAB_ROOT}/{compose.yaml,web/nginx.conf,api/*} and rebuild/redeploy.
  * Do not edit app.py, and do not disable the health checks.
  * Do not touch the Docker daemon configuration; nothing here requires it.

${C_B}COMMANDS TO START FROM${C_RST}
  docker compose -f ${LAB_ROOT}/compose.yaml -p ${PROJECT} ps -a
  docker compose -f ${LAB_ROOT}/compose.yaml -p ${PROJECT} logs --tail=30
  docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' lab702-api
  docker inspect -f '{{json .NetworkSettings.Networks}}' lab702-api
  docker network inspect ${PROJECT}_backend
  docker run --rm --entrypoint sh ${API_IMAGE} -c 'ls -l /usr/local/bin/entrypoint.sh; head -1 /usr/local/bin/entrypoint.sh | od -c'

${C_B}GRADING${C_RST}
  sudo $0 verify     # tears the stack down, brings it back up, then checks
  sudo $0 hint       # three progressive hints
  sudo $0 solution   # the full walkthrough - the commented block at the end
                     # of this very script. Do not read it first.

BRIEF
  rule
  compose ps -a || true
  rule
}

# ------------------------------------------------------------------------------
# Grading
# ------------------------------------------------------------------------------
PASS=0; FAIL=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s[PASS]%s %s\n' "$C_G" "$C_RST" "$desc"; PASS=$((PASS+1))
  else
    printf '  %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$desc"; FAIL=$((FAIL+1))
  fi
}

c_running()  { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
c_norestart(){ [[ "$(docker inspect -f '{{.RestartCount}}' "$1" 2>/dev/null)" == "0" ]]; }
c_uid()      { [[ "$(docker exec "$1" id -u 2>/dev/null | tr -d '\r')" == "$2" ]]; }
c_health()   { curl -fsS --max-time 5 "http://127.0.0.1:${HOST_PORT}/healthz" \
                 | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; }
c_subhealth(){ curl -fsS --max-time 5 "http://127.0.0.1:${HOST_PORT}/healthz" \
                 | tr -d ' \n' | grep -q "\"$1\":{\"state\":\"ok\""; }
c_beat()     { local now age; now=$(date -u +%s)
               age=$(( now - $(stat -c %Y "${LAB_ROOT}/state/heartbeat" 2>/dev/null || echo 0) ))
               [[ $age -lt 60 ]]; }

verify() {
  [[ -f "$MARKER" ]] || die "no lab found at ${LAB_ROOT}. Run: sudo $0 break"

  if [[ "${NO_RECREATE:-0}" -ne 1 ]]; then
    info "Recreating the stack from your files (this is what proves the fix is durable)..."
    compose down --remove-orphans >/dev/null 2>&1 || true
    # NOTE: no --build on purpose. If the image itself is broken, you must have
    # rebuilt it yourself; the grader will not rebuild it for you.
    compose up -d --remove-orphans >/dev/null 2>&1 || true
  fi

  info "Waiting for the stack to settle (up to 75s)..."
  local i
  for i in $(seq 1 25); do c_health && break; sleep 3; done

  head1 "LAB ${LAB_ID} - VERIFICATION"
  for c in "${CONTAINERS[@]}"; do check "container ${c} is running"          c_running "$c"; done
  for c in "${CONTAINERS[@]}"; do check "container ${c} is not restart-looping" c_norestart "$c"; done
  check "api still runs as non-root uid 10001"       c_uid lab702-api 10001
  check "worker still runs as non-root uid 10001"    c_uid lab702-worker 10001
  check "worker heartbeat on the host is fresh"      c_beat
  check "proxy answers on http://127.0.0.1:${HOST_PORT}"  curl -fsS --max-time 5 "http://127.0.0.1:${HOST_PORT}/healthz"
  check "api reports cache reachable"                c_subhealth cache
  check "api reports worker heartbeat ok"            c_subhealth worker
  check "overall health status is ok"                c_health
  rule
  if [[ $FAIL -eq 0 ]]; then
    ok "${PASS}/${PASS} checks passed - the stack is healthy and the fix is durable."
    say ""
    curl -fsS "http://127.0.0.1:${HOST_PORT}/healthz" || true
    say ""
    say "Clean up when you are done:  sudo $0 cleanup"
  else
    warn "${PASS} passed, ${FAIL} failed. Keep going - 'sudo $0 hint' if you are stuck."
    say ""
    compose ps -a || true
    exit 1
  fi
}

hints() {
  cat <<'HINTEOF'
HINT 1 - triage before theory
  Every one of these faults announces itself in a log line or in `docker inspect`.
  Read all four services first, write down the four distinct error strings, and
  only then start fixing. Order matters: fix the API image before the proxy, or
  nginx will fail to resolve a container that is not up.

    docker compose -p lab702 logs --tail=40 api worker web
    docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' lab702-api

HINT 2 - four questions worth asking
  a) "no such file or directory" for a file you can `ls`: what else does exec()
     have to open besides the script itself? Look at the FIRST LINE, byte by byte:
        docker run --rm --entrypoint sh lab702/api:1.0 -c 'head -1 /usr/local/bin/entrypoint.sh | od -c'
  b) A bind mount does not translate ownership. Which uid runs the worker, and
     who owns /opt/lab-702.1/state on the HOST?
  c) Compose's embedded DNS only resolves names for containers that SHARE a
     network. Compare:
        docker inspect -f '{{json .NetworkSettings.Networks}}' lab702-api
        docker inspect -f '{{json .NetworkSettings.Networks}}' lab702-cache
  d) A published port maps HOST:CONTAINER. What port does the nginx config
     actually `listen` on?

HINT 3 - shape of the answer
  Two fixes are in compose.yaml (one network list, one port mapping), one is in
  web/nginx.conf (one hostname), one is a file-content fix inside api/ that
  requires `docker compose build api` afterwards, and one is a host-side
  ownership change on the bind-mount source. No fix requires running anything
  as root inside a container.
HINTEOF
}

print_solution() {
  sed -n '/^#>>> SOLUTION/,$p' "$0" | sed -e 's/^#>>> //' -e 's/^# \{0,1\}//' -e 's/^#$//'
}

cleanup() {
  [[ -f "$MARKER" ]] || die "refusing to clean: ${MARKER} not found (is LAB_ROOT correct?)"
  info "Removing the Compose project, its networks and volumes..."
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  docker image rm -f "$API_IMAGE" >/dev/null 2>&1 || true
  info "Removing ${LAB_ROOT} ..."
  rm -rf -- "${LAB_ROOT}"
  ok "Lab ${LAB_ID} removed. The Docker daemon configuration was never touched."
}

do_break() {
  preflight
  confirm
  if [[ -f "$MARKER" ]]; then
    warn "An existing lab was found at ${LAB_ROOT} - it will be reset."
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf -- "${LAB_ROOT}"
  fi
  write_sources
  inject_faults
  deploy
  briefing
}

main() {
  local action="break"
  for arg in "$@"; do
    case "$arg" in
      break|verify|hint|hints|solution|cleanup|status) action="$arg" ;;
      --force)        FORCE=1 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      --no-recreate)  NO_RECREATE=1 ;;
      -h|--help)      sed -n '2,45p' "$0"; exit 0 ;;
      *) die "unknown argument: $arg (try --help)" ;;
    esac
  done

  case "$action" in
    break)    do_break ;;
    verify)   preflight; verify ;;
    status)   compose ps -a ;;
    hint|hints) hints ;;
    solution) print_solution ;;
    cleanup)  preflight; cleanup ;;
  esac
}

main "$@"
exit 0

#>>> SOLUTION ==================================================================
#>>> LAB 702.1 - Application Container Management :: STEP-BY-STEP SOLUTION
#>>> ==========================================================================
#
# Do not read this until you have tried. Container debugging is a muscle, and the
# only way to build it is to sit with a confusing log line for ten minutes.
#
# ---------------------------------------------------------------------------
# STEP 0 - TRIAGE: get the four error strings before changing anything
# ---------------------------------------------------------------------------
#   cd /opt/lab-702.1
#   docker compose -p lab702 ps -a
#   docker compose -p lab702 logs --tail=40 api worker web
#   for c in lab702-cache lab702-api lab702-worker lab702-web; do
#       docker inspect -f '{{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' "$c"
#   done
#
# Expected output (abridged):
#   lab702-api     exec /usr/local/bin/entrypoint.sh: no such file or directory
#   lab702-worker  sh: can't create /var/lib/worker/heartbeat: Permission denied
#   lab702-web     [emerg] host not found in upstream "api-svc" in /etc/nginx/conf.d/default.conf:6
#   lab702-cache   Ready to accept connections tcp
#
# Production note: `restart: unless-stopped` turned three hard crashes into a
# quiet "Restarting" column. A restart policy is a resilience feature, not a
# health signal - always read RestartCount and the logs, never just `docker ps`.
#
# ---------------------------------------------------------------------------
# FAULT 1 - api: ENOENT on an entrypoint that demonstrably exists (CRLF)
# ---------------------------------------------------------------------------
# Symptom : exec /usr/local/bin/entrypoint.sh: no such file or directory
#           (exit code 127, endless restart loop)
# Proof   : the file is present, executable, and still fails:
#             docker run --rm --entrypoint sh lab702/api:1.0 \
#               -c 'ls -l /usr/local/bin/entrypoint.sh; head -1 /usr/local/bin/entrypoint.sh | od -c'
#           -> 0000000   #   !   /   b   i   n   /   s   h  \r  \n
#
# Mechanics: exec() reads the shebang and executes the interpreter named there.
#           With CRLF endings the interpreter path is literally "/bin/sh\r",
#           which does not exist - so the kernel returns ENOENT and the runtime
#           reports "no such file or directory" ABOUT THE SCRIPT, not about the
#           interpreter. This is the single most misdiagnosed container error;
#           it usually arrives via a Windows checkout or a CI job without
#           `.gitattributes`/`core.autocrlf` discipline.
#
# Fix:
#   sed -i 's/\r$//' /opt/lab-702.1/api/entrypoint.sh
#   file /opt/lab-702.1/api/entrypoint.sh        # must NOT say "CRLF line terminators"
#   docker compose -f /opt/lab-702.1/compose.yaml -p lab702 build api
#   docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d api
#
# Hardening for real pipelines: add a build-time guard so the image can never
# ship a CRLF entrypoint again -
#   RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod 0755 /usr/local/bin/entrypoint.sh
#   RUN sh -n /usr/local/bin/entrypoint.sh
#
# ---------------------------------------------------------------------------
# FAULT 2 - worker: Permission denied on a bind mount (uid mismatch)
# ---------------------------------------------------------------------------
# Symptom : sh: can't create /var/lib/worker/heartbeat: Permission denied, exit 1,
#           restart loop.
# Proof   :
#   docker inspect -f '{{.Config.User}}' lab702-worker      # -> 10001:10001
#   stat -c '%U:%G %a %n' /opt/lab-702.1/state              # -> root:root 755 ...
#
# Mechanics: a bind mount exposes the host inode as-is. There is no ownership
#           mapping (that is what userns-remap or rootless Docker would provide),
#           so the container's uid 10001 hits a root-owned 0755 directory and is
#           denied write. Note the container is NOT misconfigured - the host is.
#
# Fix (host side, keeps the container non-root, which is what you want):
#   chown -R 10001:10001 /opt/lab-702.1/state
#   docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d worker
#   ls -l /opt/lab-702.1/state/heartbeat        # refreshes every 5s
#
# WRONG fixes and why:
#   * removing `user: "10001:10001"`  -> the process becomes root in the container
#     and, on a bind mount, root on the host filesystem too. Graded as a failure.
#   * chmod 0777                       -> world-writable state directory; works,
#     fails any security review.
#   Structurally better in production: use a NAMED VOLUME instead of a bind mount
#   (Docker initialises its ownership from the image path), or pre-create the
#   directory with the right uid in the image and mount the volume there:
#       volumes: [ workerstate:/var/lib/worker ]
#
# ---------------------------------------------------------------------------
# FAULT 3 - api cannot resolve 'cache': disjoint user-defined networks
# ---------------------------------------------------------------------------
# Symptom : once api finally starts, /healthz returns 503 with
#           "cache": {"state":"error","detail":"gaierror: [Errno -2] Name does not resolve"}
# Proof   :
#   docker inspect -f '{{json .NetworkSettings.Networks}}' lab702-api    # lab702_frontend
#   docker inspect -f '{{json .NetworkSettings.Networks}}' lab702-cache  # lab702_backend
#   docker exec lab702-api getent hosts cache                            # empty
#   docker network inspect lab702_backend --format '{{json .Containers}}'
#
# Mechanics: Docker's embedded DNS server (127.0.0.11) only answers for names of
#           containers attached to a network the QUERYING container is also
#           attached to. Default-bridge legacy `--link` behaviour does not apply
#           to user-defined networks; membership IS the service discovery.
#
# Fix - attach api to both networks (proxy tier + data tier is a legitimate
# segmentation; the api is the only thing allowed to talk to the cache):
#   in compose.yaml, service api:
#       networks: [frontend, backend]
#   docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d api
#   docker exec lab702-api getent hosts cache      # now returns 172.x.y.z cache
#
# ---------------------------------------------------------------------------
# FAULT 4 - web: nginx [emerg] host not found in upstream "api-svc"
# ---------------------------------------------------------------------------
# Symptom : lab702-web never binds; exit 1 on every restart.
# Mechanics: names inside an `upstream {}` block are resolved ONCE, during
#           configuration parsing. An unresolvable name is fatal - you get no
#           listener at all, not a 502. (The runtime-resolution alternative is
#           `resolver 127.0.0.11 valid=10s;` plus a variable in proxy_pass:
#              set $up api; proxy_pass http://$up:8000;
#           which survives an upstream that is temporarily down - worth knowing
#           for rolling restarts.)
# Fix:
#   sed -i 's/server api-svc:8000;/server api:8000;/' /opt/lab-702.1/web/nginx.conf
#   docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d web
#   docker exec lab702-web nginx -t          # syntax is ok - test AFTER the fix
#
# Order matters: fix FAULT 1 first. If lab702-api is not running, the name 'api'
# still does not resolve and nginx will keep dying with the same [emerg].
#
# ---------------------------------------------------------------------------
# FAULT 5 - published port does not match the listening port
# ---------------------------------------------------------------------------
# Symptom : curl -v http://127.0.0.1:8080/healthz -> "Empty reply from server"
#           or connection reset, while `docker ps` proudly shows 0.0.0.0:8080->8080/tcp.
# Proof   :
#   docker port lab702-web                              # 8080/tcp -> 0.0.0.0:8080
#   docker exec lab702-web grep -n listen /etc/nginx/conf.d/default.conf   # listen 80;
#   docker exec lab702-web netstat -ltnp 2>/dev/null || docker exec lab702-web ss -ltn
#
# Mechanics: "HOST:CONTAINER". The mapping 8080:8080 forwards to container port
#           8080, where nothing listens; the proxy is bound on 80. Docker happily
#           publishes a port that no process serves - publishing is a NAT rule
#           (see `iptables -t nat -L DOCKER -n`), not a health check.
# Fix (either is acceptable; the first keeps the image's convention):
#   in compose.yaml, service web:  ports: [ "8080:80" ]
#   -- or -- change `listen 80;` to `listen 8080;` in web/nginx.conf.
#   docker compose -f /opt/lab-702.1/compose.yaml -p lab702 up -d web
#
# ---------------------------------------------------------------------------
# FINAL - bring it all up and confirm
# ---------------------------------------------------------------------------
#   cd /opt/lab-702.1
#   docker compose -p lab702 build api
#   docker compose -p lab702 down
#   docker compose -p lab702 up -d
#   docker compose -p lab702 ps
#   curl -s http://127.0.0.1:8080/healthz | python3 -m json.tool
#
# Expected:
#   {
#     "status": "ok",
#     "service": "lab702-api",
#     "uid": 10001,
#     "cache":  { "state": "ok", "detail": "PONG from cache:6379" },
#     "worker": { "state": "ok", "detail": "heartbeat is 3s old" }
#   }
#
#   sudo /path/to/lab-702.1-break-fix.sh verify
#   sudo /path/to/lab-702.1-break-fix.sh cleanup
#
# ---------------------------------------------------------------------------
# WHAT TO CARRY INTO PRODUCTION (and into the 701 exam)
# ---------------------------------------------------------------------------
# * A restart policy without a healthcheck is a blindfold. Add to every service:
#     healthcheck:
#       test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8000/healthz"]
#       interval: 10s
#       timeout: 3s
#       retries: 3
#       start_period: 10s
#   then `depends_on: { api: { condition: service_healthy } }` makes start order
#   mean something instead of merely ordering process launches.
# * "no such file or directory" on an existing file = interpreter problem
#   (CRLF shebang, missing dynamic loader in a scratch/distroless image, or an
#   architecture mismatch - `docker image inspect --format '{{.Architecture}}'`).
# * Bind mounts inherit host uid/gid. Non-root containers plus bind mounts means
#   you own the ownership problem; named volumes or an init step remove it.
# * On user-defined networks, network membership IS service discovery; there is
#   no cross-network DNS. Segment deliberately, then attach deliberately.
# * A published port proves a NAT rule exists, nothing more. Always verify what
#   is actually listening INSIDE the container.
#
# Sources:
#   https://www.lpi.org/our-certifications/exam-701-objectives/
#   https://docs.docker.com/reference/cli/docker/container/run/
#   https://docs.docker.com/reference/compose-file/services/
#   https://docs.docker.com/engine/network/drivers/bridge/
#   https://docs.docker.com/engine/storage/bind-mounts/
#   https://docs.docker.com/engine/containers/start-containers-automatically/
#   https://nginx.org/en/docs/http/ngx_http_upstream_module.html
# ==========================================================================