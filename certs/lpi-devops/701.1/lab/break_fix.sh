#!/usr/bin/env bash
#
# ============================================================================
#  LPI DevOps Tools Engineer (701-100 v2.0.0)
#  Topic 701.1 - Modern Software Development
#
#  BREAK & FIX LAB: "the session that only exists on one instance"
#
#  Weight in the exam: 10.0
#  Key concepts exercised: service-based architectures, REST API design,
#  session handling, load balancing, application state, backing services,
#  and factors III (config), IV (backing services) and VI (stateless
#  processes) of the Twelve-Factor App.
#
#  Official reference: https://www.lpi.org/our-certifications/exam-701-objectives/
#  Twelve-Factor App:  https://12factor.net/processes
#                      https://12factor.net/backing-services
#                      https://12factor.net/config
#  OWASP session guidance:
#    https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html
#
#  SAFETY CONTRACT - read before running:
#    * Runs entirely as your normal user. It never needs root, never calls
#      sudo, never installs packages and never touches system services.
#    * Everything lives under one directory (default ~/lab-701.1-session-state)
#      and every process binds to 127.0.0.1 only. Nothing is exposed to the
#      network.
#    * Only Python 3 standard library and curl are used. No internet access
#      is required once the script has run.
#    * Undo everything with:  ./break-fix-701.1.sh --cleanup
#    * Even so: run it on a DISPOSABLE lab VM. That is the habit the exam
#      objectives are trying to build.
# ============================================================================

set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/lab-701.1-session-state}"
LB_PORT="${LB_PORT:-8080}"
A_PORT="${A_PORT:-8081}"
B_PORT="${B_PORT:-8082}"
MARKER=".lab-701.1"

# ---------------------------------------------------------------------------
# Presentation helpers (plain text when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
ok()    { printf '%s[ ok ]%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[warn]%s %s\n'   "$C_YELLOW" "$C_RESET" "$*"; }
die()   { printf '%s[fail]%s %s\n'   "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: break-fix-701.1.sh [--break] [--cleanup] [--help]

  --break     (default) build the lab, break it, show the symptom and the goal
  --cleanup   stop every lab process and delete the lab directory
  --help      this text

Environment overrides:
  LAB_DIR   lab directory              (default ~/lab-701.1-session-state)
  LB_PORT   load balancer port         (default 8080)
  A_PORT    instance-a port            (default 8081)
  B_PORT    instance-b port            (default 8082)
  LAB_ASSUME_YES=1   skip the interactive confirmation
USAGE
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
port_free() {
    python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

preflight() {
    head1 "== Preflight =="

    command -v python3 >/dev/null 2>&1 || die "python3 not found. Install Python 3 and retry."
    command -v curl    >/dev/null 2>&1 || die "curl not found. Install curl and retry."

    python3 - <<'PY' || die "Python 3.8 or newer is required."
import sys
sys.exit(0 if sys.version_info >= (3, 8) else 1)
PY
    ok "python3 $(python3 -c 'import platform; print(platform.python_version())') and curl present"

    if [ "$(id -u)" -eq 0 ]; then
        warn "You are root. This lab does not need root; the files will be owned by root."
    fi

    local p
    for p in "$LB_PORT" "$A_PORT" "$B_PORT"; do
        if ! port_free "$p"; then
            die "127.0.0.1:$p is already in use. Re-run with e.g. LB_PORT=9080 A_PORT=9081 B_PORT=9082"
        fi
    done
    ok "ports $LB_PORT, $A_PORT and $B_PORT are free on 127.0.0.1"

    if [ -e "$LAB_DIR" ] && [ ! -e "$LAB_DIR/$MARKER" ]; then
        die "$LAB_DIR exists and is not a lab directory. Refusing to touch it."
    fi

    if [ "${LAB_ASSUME_YES:-0}" != "1" ]; then
        if [ ! -t 0 ]; then
            die "Not a terminal and LAB_ASSUME_YES is not set. Re-run with LAB_ASSUME_YES=1."
        fi
        say ""
        say "This will create $LAB_DIR and start three local Python processes."
        printf 'Continue on this disposable lab VM? [y/N] '
        local answer; read -r answer
        case "$answer" in
            y|Y|yes|YES) : ;;
            *) die "Aborted by the student. Nothing was created." ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# Lab construction - the application under test
# ---------------------------------------------------------------------------
write_app() {
    cat >"$LAB_DIR/app.py" <<'PY'
#!/usr/bin/env python3
"""Profile API - one process, one instance, standard library only.

This is the service the lab runs twice behind a load balancer. It exposes a
tiny REST surface:

    POST /login    {"user": "...", "password": "..."}  -> 200 {"token": "..."}
    GET  /profile  Authorization: Bearer <token>       -> 200 {"user": "..."}
    GET  /healthz                                      -> 200 {"status": "ok"}

Configuration comes from the environment (twelve-factor III):
    INSTANCE_NAME   label reported in responses and logs
    PORT            TCP port to bind on 127.0.0.1
    SESSION_DB      exported by lab.env - NOTHING IN THIS FILE READS IT YET
"""

import json
import os
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INSTANCE = os.environ.get("INSTANCE_NAME", "unknown")
PORT = int(os.environ.get("PORT", "8081"))
SESSION_TTL = int(os.environ.get("SESSION_TTL", "3600"))

# A toy user directory. Real services delegate this to an identity provider.
USERS = {"alice": "s3cret", "bob": "hunter2"}

# ---------------------------------------------------------------------------
# Session store.
#
# Right here is the whole lesson: the store is a dict on the process heap.
# It is fast, it needs no dependency, and it is invisible to every other
# replica of this same service. The moment a second instance exists - which
# is the moment you put a load balancer in front - half of the authenticated
# traffic lands on a process that has never heard of the token.
# ---------------------------------------------------------------------------
SESSIONS = {}


def session_put(token, username):
    now = time.time()
    SESSIONS[token] = {"username": username, "created": now, "expires": now + SESSION_TTL}


def session_get(token):
    if not token:
        return None
    entry = SESSIONS.get(token)
    if entry is None or entry["expires"] < time.time():
        return None
    return entry


class Handler(BaseHTTPRequestHandler):
    server_version = "profile-api/1.0"
    protocol_version = "HTTP/1.1"

    # -- helpers ------------------------------------------------------------
    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Served-By", INSTANCE)
        self.end_headers()
        self.wfile.write(body)

    def _bearer(self):
        auth = self.headers.get("Authorization", "")
        return auth[len("Bearer "):].strip() if auth.startswith("Bearer ") else ""

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw or b"{}")

    def log_message(self, fmt, *args):
        print("%s %s %s" % (time.strftime("%H:%M:%S"), INSTANCE, fmt % args), flush=True)

    # -- routes -------------------------------------------------------------
    def do_GET(self):
        if self.path == "/healthz":
            self._json(200, {"status": "ok", "instance": INSTANCE,
                             "sessions_in_memory": len(SESSIONS)})
            return
        if self.path == "/profile":
            entry = session_get(self._bearer())
            if entry is None:
                self._json(401, {"error": "unknown session", "instance": INSTANCE})
                return
            self._json(200, {"user": entry["username"], "instance": INSTANCE})
            return
        self._json(404, {"error": "not found", "path": self.path})

    def do_POST(self):
        if self.path != "/login":
            self._json(404, {"error": "not found", "path": self.path})
            return
        try:
            body = self._read_json()
        except json.JSONDecodeError:
            self._json(400, {"error": "request body must be JSON"})
            return
        username = body.get("user")
        password = body.get("password")
        if not isinstance(username, str) or USERS.get(username) != password:
            self._json(401, {"error": "bad credentials"})
            return
        token = secrets.token_hex(16)
        session_put(token, username)
        self._json(200, {"token": token, "user": username, "instance": INSTANCE})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("%s listening on 127.0.0.1:%d" % (INSTANCE, PORT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
PY
    cp "$LAB_DIR/app.py" "$LAB_DIR/app.py.broken"
}

# ---------------------------------------------------------------------------
# Lab construction - the load balancer (OFF LIMITS to the student)
# ---------------------------------------------------------------------------
write_balancer() {
    cat >"$LAB_DIR/balancer.py" <<'PY'
#!/usr/bin/env python3
"""Round-robin reverse proxy - stands in for nginx/HAProxy/a Service VIP.

Strict round robin, one passive failover retry if a backend refuses the
connection. It adds an X-Upstream response header so the test harness can
prove which replica answered. Do not edit this file: it is the part of the
platform you do not control in production either.
"""

import itertools
import json
import os
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKENDS = [b.strip() for b in os.environ.get("BACKENDS", "").split(",") if b.strip()]
PORT = int(os.environ.get("LB_PORT", "8080"))

_cycle = itertools.cycle(BACKENDS)
_lock = threading.Lock()


def next_backend():
    with _lock:
        return next(_cycle)


class Balancer(BaseHTTPRequestHandler):
    server_version = "lab-lb/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return  # the backends already log every request

    def _forward(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None

        attempts = []
        for _ in range(min(2, len(BACKENDS))):
            backend = next_backend()
            if backend in attempts:
                continue
            attempts.append(backend)
            request = urllib.request.Request(backend + self.path, data=body, method=method)
            for header in ("Authorization", "Content-Type", "Accept"):
                value = self.headers.get(header)
                if value:
                    request.add_header(header, value)
            try:
                with urllib.request.urlopen(request, timeout=5) as response:
                    return self._relay(response.status, response.read(), backend)
            except urllib.error.HTTPError as exc:
                return self._relay(exc.code, exc.read(), backend)
            except urllib.error.URLError:
                continue  # backend down: try the next one

        payload = json.dumps({"error": "no healthy backend", "tried": attempts}).encode()
        return self._relay(502, payload, "none")

    def _relay(self, status, payload, backend):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Upstream", backend)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self._forward("GET")

    def do_POST(self):
        self._forward("POST")


def main():
    if not BACKENDS:
        raise SystemExit("BACKENDS is empty")
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Balancer)
    print("balancer on 127.0.0.1:%d -> %s" % (PORT, ", ".join(BACKENDS)), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
PY
}

# ---------------------------------------------------------------------------
# Lab construction - environment, process control, acceptance test
# ---------------------------------------------------------------------------
write_env() {
    cat >"$LAB_DIR/lab.env" <<EOF
# Config for the 701.1 lab, in the environment (twelve-factor III).
LAB_DIR="$LAB_DIR"
LB_PORT=$LB_PORT
A_PORT=$A_PORT
B_PORT=$B_PORT

# A shared, process-external location for state. Already exported for you.
# Nothing in app.py reads it yet. That is not an accident.
SESSION_DB="\$LAB_DIR/state/sessions.db"
export SESSION_DB
EOF
}

write_labctl() {
    cat >"$LAB_DIR/lab-ctl" <<'SH'
#!/usr/bin/env bash
# lab-ctl - process control for the 701.1 session-state lab
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lab.env"

mkdir -p "$HERE/logs" "$HERE/run" "$HERE/state"

pidfile() { printf '%s\n' "$HERE/run/$1.pid"; }

running() {
    local f; f="$(pidfile "$1")"
    [ -f "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null
}

wait_http() {
    local url="$1" i
    for i in $(seq 1 60); do
        curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}

start_backend() {
    local name="$1" port="$2"
    if running "$name"; then echo "$name already running"; return 0; fi
    (
        cd "$HERE" || exit 1
        INSTANCE_NAME="$name" PORT="$port" SESSION_DB="$SESSION_DB" \
            nohup python3 "$HERE/app.py" >>"$HERE/logs/$name.log" 2>&1 &
        echo $! >"$HERE/run/$name.pid"
    )
    if wait_http "http://127.0.0.1:$port/healthz"; then
        echo "$name up on 127.0.0.1:$port"
    else
        echo "$name FAILED to start - tail -n 30 $HERE/logs/$name.log"
        return 1
    fi
}

start_lb() {
    if running balancer; then echo "balancer already running"; return 0; fi
    (
        cd "$HERE" || exit 1
        BACKENDS="http://127.0.0.1:$A_PORT,http://127.0.0.1:$B_PORT" LB_PORT="$LB_PORT" \
            nohup python3 "$HERE/balancer.py" >>"$HERE/logs/balancer.log" 2>&1 &
        echo $! >"$HERE/run/balancer.pid"
    )
    if wait_http "http://127.0.0.1:$LB_PORT/healthz"; then
        echo "balancer up on 127.0.0.1:$LB_PORT"
    else
        echo "balancer FAILED to start - tail -n 30 $HERE/logs/balancer.log"
        return 1
    fi
}

stop_one() {
    local name="$1" f pid
    f="$(pidfile "$name")"
    [ -f "$f" ] || return 0
    pid="$(cat "$f" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$pid" 2>/dev/null
        echo "$name stopped (pid $pid)"
    fi
    rm -f "$f"
}

case "${1:-status}" in
    start)
        start_backend instance-a "$A_PORT"
        start_backend instance-b "$B_PORT"
        start_lb
        ;;
    stop)
        stop_one balancer; stop_one instance-a; stop_one instance-b
        ;;
    restart)
        "$0" stop; sleep 0.3; "$0" start
        ;;
    restart-a)
        # Simulates a rolling deploy, an OOM kill, or a node drain.
        stop_one instance-a; sleep 0.3; start_backend instance-a "$A_PORT"
        ;;
    status)
        for name in instance-a instance-b balancer; do
            if running "$name"; then
                printf '%-12s running (pid %s)\n' "$name" "$(cat "$(pidfile "$name")")"
            else
                printf '%-12s stopped\n' "$name"
            fi
        done
        printf '\nentrypoint : http://127.0.0.1:%s\n' "$LB_PORT"
        printf 'instance-a : http://127.0.0.1:%s\n' "$A_PORT"
        printf 'instance-b : http://127.0.0.1:%s\n' "$B_PORT"
        printf 'SESSION_DB : %s\n' "$SESSION_DB"
        ;;
    logs)
        tail -n 40 "$HERE"/logs/*.log
        ;;
    test)
        exec "$HERE/check.sh"
        ;;
    reset)
        "$0" stop
        cp "$HERE/app.py.broken" "$HERE/app.py"
        rm -f "$HERE"/state/sessions.db* "$HERE"/logs/*.log
        echo "app.py restored to the broken version, state and logs wiped"
        "$0" start
        ;;
    *)
        echo "usage: lab-ctl {start|stop|restart|restart-a|status|logs|test|reset}" >&2
        exit 2
        ;;
esac
SH
    chmod +x "$LAB_DIR/lab-ctl"
}

write_check() {
    cat >"$LAB_DIR/check.sh" <<'SH'
#!/usr/bin/env bash
# check.sh - the acceptance test. DO NOT EDIT THIS FILE.
#
# It asserts the contract a load-balanced service must honour:
#   phase 1  one login, then every request succeeds no matter which replica
#            answers, and both replicas must actually take traffic
#   phase 2  the same token still works after one replica is restarted
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lab.env"

LB="http://127.0.0.1:$LB_PORT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'
else
    G=''; R=''; B=''; Z=''
fi

field() {
    python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("")' "$1" "$2"
}

upstream_of() {
    grep -i '^x-upstream:' "$1" | tr -d '\r' | awk '{print $2}' | tail -n 1
}

pass=0
fail=0
upstreams=""

probe() {
    local label="$1" code up state
    code="$(curl -s -o "$TMP/body.json" -D "$TMP/head.txt" -w '%{http_code}' \
        --max-time 5 -H "Authorization: Bearer $TOKEN" "$LB/profile")"
    up="$(upstream_of "$TMP/head.txt")"
    [ -n "$up" ] && upstreams="$upstreams $up"
    if [ "$code" = "200" ]; then
        state="${G}200 OK${Z}"; pass=$((pass + 1))
    else
        state="${R}${code} $(field "$TMP/body.json" error)${Z}"; fail=$((fail + 1))
    fi
    printf '  %-10s upstream=%-24s %s\n' "$label" "${up:-?}" "$state"
}

printf '%s\n' "${B}Phase 1 - one login, ten authenticated requests through the balancer${Z}"

code="$(curl -s -o "$TMP/login.json" -D "$TMP/loginhead.txt" -w '%{http_code}' \
    --max-time 5 -X POST "$LB/login" \
    -H 'Content-Type: application/json' \
    -d '{"user": "alice", "password": "s3cret"}')"

if [ "$code" != "200" ]; then
    printf '  %sLogin failed with HTTP %s%s - is the lab running? (./lab-ctl status)\n' "$R" "$code" "$Z"
    exit 1
fi

TOKEN="$(field "$TMP/login.json" token)"
if [ -z "$TOKEN" ]; then
    printf '  %sLogin returned no token%s\n' "$R" "$Z"
    exit 1
fi
printf '  login     upstream=%-24s %s200 OK%s  token=%s...\n' \
    "$(upstream_of "$TMP/loginhead.txt")" "$G" "$Z" "${TOKEN:0:8}"

for i in $(seq 1 10); do
    probe "req $(printf '%02d' "$i")"
done

distinct="$(printf '%s\n' $upstreams | sort -u | grep -c . || true)"
printf '\n  replicas that took traffic: %s\n' "$distinct"

printf '\n%s\n' "${B}Phase 2 - restart instance-a (rolling deploy) and reuse the SAME token${Z}"
"$HERE/lab-ctl" restart-a >/dev/null 2>&1
sleep 0.5
for i in $(seq 1 6); do
    probe "req $(printf '%02d' "$i")"
done

printf '\n%s\n' "${B}Result${Z}"
printf '  successful : %s\n' "$pass"
printf '  failed     : %s\n' "$fail"

if [ "$fail" -eq 0 ] && [ "$distinct" -ge 2 ]; then
    printf '  %sPASS%s - the session survives any replica and any restart.\n' "$G" "$Z"
    exit 0
fi

if [ "$distinct" -lt 2 ]; then
    printf '  %sFAIL%s - only one replica served traffic. Both instances must run;\n' "$R" "$Z"
    printf '         shutting one down is not a fix, it is an outage waiting.\n'
else
    printf '  %sFAIL%s - %s requests were rejected. Session state is not shared.\n' "$R" "$Z" "$fail"
fi
exit 1
SH
    chmod +x "$LAB_DIR/check.sh"
}

# ---------------------------------------------------------------------------
# Build, break, brief
# ---------------------------------------------------------------------------
build_lab() {
    head1 "== Building the lab =="
    mkdir -p "$LAB_DIR/logs" "$LAB_DIR/run" "$LAB_DIR/state"
    : >"$LAB_DIR/$MARKER"
    write_app
    write_balancer
    write_env
    write_labctl
    write_check
    ok "lab written to $LAB_DIR"
    say "    app.py        the service (the only file you may edit)"
    say "    balancer.py   round-robin load balancer  [off limits]"
    say "    check.sh      acceptance test            [off limits]"
    say "    lab-ctl       start|stop|restart-a|status|logs|test|reset"
}

break_it() {
    head1 "== Breaking it (starting two replicas with process-local sessions) =="
    "$LAB_DIR/lab-ctl" start
    sleep 0.4
    ok "two replicas of the service are live behind one balancer"
}

show_symptom() {
    head1 "== The symptom, reproduced right now =="
    say ""
    "$LAB_DIR/check.sh" || true
}

briefing() {
    cat <<EOF

$C_BOLD$C_CYAN== Your briefing ==$C_RESET

$C_BOLD The story $C_RESET
  The profile service ran happily as a single process for a year. Last sprint
  it was scaled to two replicas behind a round-robin load balancer - nothing
  else changed, no code was touched. Support is now drowning in tickets that
  all say the same thing: "it logs me out at random".

$C_BOLD What you will see $C_RESET
  * POST /login through http://127.0.0.1:$LB_PORT always returns 200 and a token.
  * GET /profile with that token returns 200 and 401 in strict alternation.
  * The 401 body is {"error": "unknown session"} - never "bad credentials".
  * curl -i shows a different X-Served-By / X-Upstream on each request.
  * Restarting a replica invalidates every token it had issued.

$C_BOLD What you must achieve $C_RESET
  Make this command print PASS:

      $LAB_DIR/lab-ctl test

  which means, concretely:
    1. one login, then ten authenticated requests, all 200;
    2. both replicas keep serving traffic - stopping one is not a fix;
    3. the very same token still works after instance-a is restarted.

$C_BOLD Rules of engagement $C_RESET
  * You may edit only app.py. balancer.py and check.sh are the platform; in
    production you do not get to rewrite the load balancer to hide a bug in
    the application.
  * Standard library only. No pip, no Redis to install, no root.
  * The environment already exports SESSION_DB=$LAB_DIR/state/sessions.db
    and no code reads it yet. Ask yourself why that variable exists.
  * Configuring sticky sessions would be a workaround, not the fix - and
    phase 2 of the test is designed to expose exactly why.

$C_BOLD Useful commands while you work $C_RESET
  curl -i -X POST http://127.0.0.1:$LB_PORT/login \\
       -H 'Content-Type: application/json' \\
       -d '{"user": "alice", "password": "s3cret"}'
  curl -i -H "Authorization: Bearer \$TOKEN" http://127.0.0.1:$LB_PORT/profile
  curl -s http://127.0.0.1:$A_PORT/healthz; curl -s http://127.0.0.1:$B_PORT/healthz
  $LAB_DIR/lab-ctl status
  $LAB_DIR/lab-ctl logs
  $LAB_DIR/lab-ctl reset      # back to the broken starting point
  $0 --cleanup   # remove everything

$C_BOLD The question behind the exercise $C_RESET
  Topic 701.1 asks you to reason about service-based applications, session
  handling and the twelve-factor model. This bug is factor VI in one line:
  a process that keeps state in its own memory cannot be replicated, cannot
  be restarted and cannot be deployed without dropping user sessions.

  The solution is at the bottom of this script, commented out. Try first.

EOF
}

cleanup() {
    head1 "== Cleanup =="
    if [ ! -e "$LAB_DIR/$MARKER" ]; then
        warn "$LAB_DIR does not look like a lab directory - nothing removed."
        exit 0
    fi
    [ -x "$LAB_DIR/lab-ctl" ] && "$LAB_DIR/lab-ctl" stop || true
    rm -rf -- "$LAB_DIR"
    ok "removed $LAB_DIR and stopped every lab process"
}

main() {
    case "${1:---break}" in
        --break|break)
            preflight
            build_lab
            break_it
            show_symptom
            briefing
            ;;
        --cleanup|cleanup) cleanup ;;
        --help|-h) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

# ============================================================================
#  ####################################################################
#  #                                                                  #
#  #   S O L U T I O N   -   stop reading if you have not tried yet   #
#  #                                                                  #
#  ####################################################################
#
# ---------------------------------------------------------------------------
# STEP 1 - Reproduce deliberately, and read the status code
# ---------------------------------------------------------------------------
#   TOKEN=$(curl -s -X POST http://127.0.0.1:8080/login \
#             -H 'Content-Type: application/json' \
#             -d '{"user": "alice", "password": "s3cret"}' \
#           | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
#
#   for i in 1 2 3 4; do
#     curl -s -i -H "Authorization: Bearer $TOKEN" \
#          http://127.0.0.1:8080/profile | grep -E '^(HTTP|X-Served-By)'
#   done
#
# Expected output - the pattern is the diagnosis:
#
#   HTTP/1.1 200 OK
#   X-Served-By: instance-b
#   HTTP/1.1 401 Unauthorized
#   X-Served-By: instance-a
#   HTTP/1.1 200 OK
#   X-Served-By: instance-b
#   HTTP/1.1 401 Unauthorized
#   X-Served-By: instance-a
#
# Two facts worth naming out loud:
#   * The failure is 401 "unknown session", not 401 "bad credentials". The
#     credentials were never re-checked; the token was simply not recognised.
#   * Failure correlates perfectly with X-Served-By. It is not intermittent,
#     it is not a race, it is not the network. It is per-replica.
#
# ---------------------------------------------------------------------------
# STEP 2 - Confirm where the state lives
# ---------------------------------------------------------------------------
#   curl -s http://127.0.0.1:8081/healthz; echo
#   curl -s http://127.0.0.1:8082/healthz; echo
#
#   {"status": "ok", "instance": "instance-a", "sessions_in_memory": 0}
#   {"status": "ok", "instance": "instance-b", "sessions_in_memory": 1}
#
# The session exists on exactly one process. Now restart the one that has it:
#
#   ./lab-ctl restart-a          # and repeat with instance-b if you wish
#
# Every token it issued dies with it. That is the second half of the bug: it
# breaks under horizontal scaling AND under any restart - a deploy, an OOM
# kill, a node drain, an autoscaler scaling in.
#
# ---------------------------------------------------------------------------
# STEP 3 - Name the principle
# ---------------------------------------------------------------------------
# Twelve-factor VI, "Processes: execute the app as one or more stateless
# processes" (https://12factor.net/processes):
#
#   "Twelve-factor processes are stateless and share-nothing. Any data that
#    needs to persist must be stored in a stateful backing service, typically
#    a database."
#
# Memory and local disk are a single-transaction scratchpad, never a session
# store. The corollary is factor IV, "Backing services are attached resources"
# (https://12factor.net/backing-services): the store is reached through a URL
# or path taken from config - which is factor III (https://12factor.net/config)
# and is precisely why SESSION_DB is already exported in lab.env.
#
# ---------------------------------------------------------------------------
# STEP 4 - Apply the fix: externalise the session store
# ---------------------------------------------------------------------------
# Edit app.py. Add sqlite3 to the imports and replace the SESSIONS dict and
# its two helper functions with the block below. SQLite on a shared path is
# the lab's stand-in for Redis/Memcached/Postgres: it is a real out-of-process
# backing service reached through configuration, which is the property that
# matters here.
#
#   import sqlite3
#
#   SESSION_DB = os.environ.get("SESSION_DB", "/tmp/sessions.db")
#
#   def _connect():
#       # isolation_level=None -> autocommit; timeout -> wait out the writer
#       # lock instead of raising "database is locked" under concurrency.
#       conn = sqlite3.connect(SESSION_DB, timeout=5.0, isolation_level=None)
#       conn.execute("PRAGMA journal_mode=WAL")   # concurrent readers + writer
#       return conn
#
#   def session_init():
#       os.makedirs(os.path.dirname(SESSION_DB) or ".", exist_ok=True)
#       with _connect() as conn:
#           conn.execute(
#               "CREATE TABLE IF NOT EXISTS sessions ("
#               " token TEXT PRIMARY KEY,"
#               " username TEXT NOT NULL,"
#               " created REAL NOT NULL,"
#               " expires REAL NOT NULL)"
#           )
#
#   def session_put(token, username):
#       now = time.time()
#       with _connect() as conn:
#           conn.execute(
#               "INSERT OR REPLACE INTO sessions"
#               " (token, username, created, expires) VALUES (?, ?, ?, ?)",
#               (token, username, now, now + SESSION_TTL),
#           )
#
#   def session_get(token):
#       if not token:
#           return None
#       now = time.time()
#       with _connect() as conn:
#           conn.execute("DELETE FROM sessions WHERE expires < ?", (now,))
#           row = conn.execute(
#               "SELECT username, created, expires FROM sessions WHERE token = ?",
#               (token,),
#           ).fetchone()
#       if row is None or row[2] < now:
#           return None
#       return {"username": row[0], "created": row[1], "expires": row[2]}
#
# Then call session_init() once in main(), before serve_forever():
#
#   def main():
#       session_init()
#       server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
#       ...
#
# And in /healthz, replace len(SESSIONS) - the dict no longer exists:
#
#   with _connect() as conn:
#       count = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
#   self._json(200, {"status": "ok", "instance": INSTANCE, "sessions": count})
#
# Note the parameterised queries. String-formatting a token into SQL is the
# textbook injection path, and 701.1 expects you to know both the SQL and the
# risk (https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html).
#
# ---------------------------------------------------------------------------
# STEP 5 - Restart and verify
# ---------------------------------------------------------------------------
#   ./lab-ctl restart
#   ./lab-ctl test
#
# Expected:
#
#   Phase 1 - one login, ten authenticated requests through the balancer
#     login     upstream=http://127.0.0.1:8081  200 OK  token=9f3ac1d2...
#     req 01    upstream=http://127.0.0.1:8082  200 OK
#     req 02    upstream=http://127.0.0.1:8081  200 OK
#     ...
#     replicas that took traffic: 2
#
#   Phase 2 - restart instance-a (rolling deploy) and reuse the SAME token
#     req 01    upstream=http://127.0.0.1:8081  200 OK
#     ...
#
#   Result
#     successful : 16
#     failed     : 0
#     PASS - the session survives any replica and any restart.
#
# Inspect the shared state directly:
#
#   sqlite3 ~/lab-701.1-session-state/state/sessions.db 'SELECT * FROM sessions;'
#
# or, if the sqlite3 CLI is not installed:
#
#   python3 -c 'import sqlite3, sys; \
#     print(sqlite3.connect(sys.argv[1]).execute("SELECT token, username FROM sessions").fetchall())' \
#     ~/lab-701.1-session-state/state/sessions.db
#
# ---------------------------------------------------------------------------
# STEP 6 - The trade-offs the exam actually asks about
# ---------------------------------------------------------------------------
# Three ways to make a load-balanced service authenticate consistently:
#
# a) Sticky sessions (nginx ip_hash / HAProxy cookie affinity)
#    Pin each client to one replica, no code change, works today. But: the
#    session still dies with the replica, so every deploy logs users out;
#    traffic distributes by client, not by load; scaling out does not relieve
#    the already-hot replica; and NAT collapses many clients onto one node.
#    A transitional measure, not a design. Phase 2 of the test fails it.
#
# b) Shared session store - what you just built
#    Redis or Memcached in production: sub-millisecond, native TTL so expiry
#    is not your problem, and horizontal scaling and rolling deploys become
#    invisible to the user. The cost is a new dependency in the request path:
#    it needs HA, its eviction policy must not be allkeys-lru for sessions,
#    and the app must degrade sensibly when it is unreachable.
#
# c) Stateless signed tokens (JWT and friends)
#    No server-side store at all: the token carries the claims and a
#    signature. Perfect horizontal scaling. The cost is revocation - a signed
#    token is valid until it expires, so logout, password change and ban need
#    short lifetimes plus a refresh flow or a deny-list, which quietly brings
#    back a shared store. Never put secrets in the payload; it is signed, not
#    encrypted. (https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html)
#
# Whichever you pick, the session-management hygiene from OWASP still applies:
# a token from a CSPRNG with >= 128 bits of entropy (secrets.token_hex(16) is
# exactly that), an absolute and an idle TTL, rotation of the identifier on
# privilege change to defeat session fixation, and transport only over TLS.
#
# ---------------------------------------------------------------------------
# STEP 7 - The generalisation to carry into the exam
# ---------------------------------------------------------------------------
# The same question applies to every piece of state a service holds:
#
#   uploaded files      -> object storage, not the container filesystem
#   background jobs     -> a queue, not an in-process thread
#   caches              -> shared, or per-replica and provably disposable
#   scheduled tasks     -> a leader or an external scheduler, not every replica
#   logs                -> stdout as an event stream (factor XI), not a local file
#
# One test reveals all of them: can I kill any single replica, at any moment,
# and can a user notice? If the answer is yes, that is state in the wrong
# place - and in Kubernetes, where a Pod is evicted, rescheduled and replaced
# as a matter of routine, "at any moment" is not hypothetical.
#
# Reference: https://www.lpi.org/our-certifications/exam-701-objectives/
# ============================================================================