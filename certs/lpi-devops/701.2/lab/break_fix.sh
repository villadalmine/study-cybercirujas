#!/usr/bin/env bash
#
# =============================================================================
#  LPI DevOps Tools Engineer (701-100, v2.0.0)
#  Topic 701.2 -- Standard Components and Platforms for Software
#  Lab type: BREAK & FIX   |   Run ONLY on a disposable lab VM
# =============================================================================
#
#  WHAT THIS LAB IS ABOUT
#  ----------------------
#  Objective 701.2 is not about one product. It is about recognising the
#  standard building blocks that every service-based application is assembled
#  from -- object storage, a cache, a message queue, an application runtime and
#  a load balancer / API gateway in front of them -- and understanding that, per
#  the twelve-factor methodology, those blocks are *attached resources* whose
#  addresses arrive through the environment, never hardcoded.
#
#  This script deploys exactly such a stack on the VM, using nothing but
#  python3 and systemd (no containers, no packages to install), proves it
#  healthy, and then injects three faults -- one per layer. The faults are
#  LAYERED on purpose: the outermost one masks the next. You peel them off in
#  order, exactly as you would during an incident.
#
#  COMPONENT MAP (all listeners bound to 127.0.0.1 by default)
#
#      client -> :8080  shopfront-gw          API gateway / load balancer
#                         |-> :9201  shopfront-api@1   application runtime
#                         `-> :9202  shopfront-api@2   application runtime
#                                       |-> :9101  shopfront-object  object store
#                                       |-> :9102  shopfront-cache   cache
#                                       `-> :9103  shopfront-queue   message queue
#
#  Source of truth for the objective:
#    https://www.lpi.org/our-certifications/exam-701-objectives/
#  Twelve-factor, III (Config) and IV (Backing services):
#    https://12factor.net/config   https://12factor.net/backing-services
#  systemd unit/template semantics:
#    https://www.freedesktop.org/software/systemd/man/systemd.unit.html
#    https://www.freedesktop.org/software/systemd/man/systemd.exec.html
#
#  USAGE
#    sudo ./break_fix.sh            deploy, prove healthy, then break (default)
#    sudo ./break_fix.sh deploy     deploy and prove healthy only
#    sudo ./break_fix.sh break      inject the faults into a healthy stack
#    sudo ./break_fix.sh status     show the stack as systemd and the gateway see it
#    sudo ./break_fix.sh verify     grade your repair (exit 0 = all green)
#    sudo ./break_fix.sh reset      restore the pristine stack (give-up button)
#    sudo ./break_fix.sh cleanup    remove every trace of the lab from the VM
#    sudo ./break_fix.sh solution   print the step-by-step solution
#
#  SAFETY: touches only /opt/shopfront, /etc/shopfront, /var/lib/shopfront,
#  /etc/systemd/system/shopfront-*, and the system user 'shopfront'. It never
#  modifies networking, firewalling, package state or any pre-existing unit.
# =============================================================================

set -Eeuo pipefail
trap 'printf "\n[!] aborted at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR

APP_DIR=/opt/shopfront
CFG_DIR=/etc/shopfront
DATA_DIR=/var/lib/shopfront
OBJ_DIR="$DATA_DIR/objects"
BACKUP_DIR="$DATA_DIR/.pristine"
UNIT_DIR=/etc/systemd/system
SVC_USER=shopfront
GW=http://127.0.0.1:8080
UNITS=(shopfront-object.service shopfront-cache.service shopfront-queue.service
       shopfront-api@1.service shopfront-api@2.service shopfront-gw.service)
PORTS=(9101 9102 9103 9201 9202 8080)
SELF="$(basename "$0")"

if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi

say()  { printf '%s[*]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "-------------------------------------------------------------------------------"; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root: sudo ./$SELF ${1:-}"
  [[ -d /run/systemd/system ]] || die "systemd is not PID 1 here; this lab needs systemd"
  command -v systemctl >/dev/null || die "systemctl not found"
  command -v python3   >/dev/null || die "python3 not found (install python3 and rerun)"
  command -v curl      >/dev/null || die "curl not found (install curl and rerun)"
  python3 - <<'PY' || die "python3 >= 3.7 required (ThreadingHTTPServer)"
import sys
raise SystemExit(0 if sys.version_info >= (3, 7) else 1)
PY
}

confirm() {
  [[ "${LAB_ASSUME_YES:-0}" == "1" ]] && return 0
  local answer=""
  printf '%s\n' "This VM must be disposable. The lab creates the user '$SVC_USER', writes to"
  printf '%s\n' "$APP_DIR, $CFG_DIR, $DATA_DIR and $UNIT_DIR/shopfront-*, and binds ports ${PORTS[*]}."
  printf 'Type %sYES%s to continue: ' "$B" "$N"
  read -r answer </dev/tty || true
  [[ "$answer" == "YES" ]] || die "cancelled"
}

port_is_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(0.5)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    s.close(); sys.exit(0)
s.close(); sys.exit(1)
PY
}

# -----------------------------------------------------------------------------
# The stack itself: one python file, five roles
# -----------------------------------------------------------------------------
write_application() {
  install -d -m 0755 "$APP_DIR"
  cat > "$APP_DIR/shopfront.py" <<'PYEOF'
#!/usr/bin/env python3
"""shopfront -- a miniature service-based application stack.

One executable, five roles, so that a single VM can host the standard
components of a cloud application without installing anything:

    object  : object storage    (blobs on disk, PUT/GET by key)
    cache   : cache             (in-memory, volatile by design)
    queue   : message queue     (in-memory FIFO per queue name)
    api     : application runtime, stateless, horizontally scalable
    gw      : API gateway / load balancer, round-robin over the runtimes

Every backing service is an attached resource: its URL comes from the
environment and nothing else. A missing URL is a startup failure with
EX_CONFIG (78), never a silent default -- a runtime that invents its own
database address is the bug, not the environment that forgot to set one.
"""

import itertools
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = sys.argv[1] if len(sys.argv) > 1 else ""
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
OBJECT_DIR = os.environ.get("OBJECT_DIR", "/var/lib/shopfront/objects")
KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

OBJECT_URL = CACHE_URL = QUEUE_URL = ""
INSTANCE_ID = "0"
UPSTREAMS = []
_RR = itertools.count()


def die_config(name):
    sys.stderr.write(
        "FATAL: %s is not set. Backing services are attached resources; their "
        "addresses must be supplied through the environment.\n" % name)
    raise SystemExit(78)


def env_or_die(name):
    value = os.environ.get(name, "").strip()
    if not value:
        die_config(name)
    return value.rstrip("/")


def call(method, url, data=None, timeout=3.0):
    """Return (status, body). status 0 means the peer could not be reached."""
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/octet-stream")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except OSError as exc:
        return 0, str(exc).encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "shopfront/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s %s\n" % (ROLE, self.address_string(), fmt % args))

    def reply(self, code, payload, ctype="application/json", extra=None):
        if isinstance(payload, (dict, list)):
            body = (json.dumps(payload) + "\n").encode()
        elif isinstance(payload, str):
            body = payload.encode()
        else:
            body = payload
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def tail(self, prefix):
        if not self.path.startswith(prefix):
            return None
        key = self.path[len(prefix):].split("?", 1)[0]
        return key if KEY_RE.match(key) else None


# --------------------------------------------------------------------------
# object storage
# --------------------------------------------------------------------------
class ObjectHandler(Handler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"role": "object", "status": "ok",
                                    "dir": OBJECT_DIR,
                                    "writable": os.access(OBJECT_DIR, os.W_OK)})
        key = self.tail("/objects/")
        if key is None:
            return self.reply(404, {"error": "no such route", "path": self.path})
        try:
            with open(os.path.join(OBJECT_DIR, key), "rb") as fh:
                return self.reply(200, fh.read(), "application/octet-stream")
        except FileNotFoundError:
            return self.reply(404, {"error": "no such object", "key": key})
        except OSError as exc:
            sys.stderr.write("object read failed: %r\n" % exc)
            return self.reply(500, {"error": "object read failed", "detail": str(exc)})

    def do_PUT(self):
        key = self.tail("/objects/")
        payload = self.read_body()
        if key is None:
            return self.reply(400, {"error": "invalid object key", "path": self.path})
        try:
            with open(os.path.join(OBJECT_DIR, key), "wb") as fh:
                fh.write(payload)
        except OSError as exc:
            sys.stderr.write("object write failed: %r\n" % exc)
            return self.reply(500, {"error": "object write failed",
                                    "key": key, "detail": str(exc)})
        return self.reply(201, {"key": key, "bytes": len(payload)})


# --------------------------------------------------------------------------
# cache
# --------------------------------------------------------------------------
_CACHE = {}
_CACHE_LOCK = threading.Lock()
_CACHE_STATS = {"hits": 0, "misses": 0, "stores": 0}


class CacheHandler(Handler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"role": "cache", "status": "ok"})
        if self.path == "/stats":
            with _CACHE_LOCK:
                return self.reply(200, dict(_CACHE_STATS, entries=len(_CACHE)))
        key = self.tail("/cache/")
        if key is None:
            return self.reply(404, {"error": "no such route", "path": self.path})
        with _CACHE_LOCK:
            value = _CACHE.get(key)
            _CACHE_STATS["hits" if value is not None else "misses"] += 1
        if value is None:
            return self.reply(404, {"error": "cache miss", "key": key})
        return self.reply(200, value, "application/octet-stream")

    def do_PUT(self):
        key = self.tail("/cache/")
        payload = self.read_body()
        if key is None:
            return self.reply(400, {"error": "invalid cache key"})
        with _CACHE_LOCK:
            _CACHE[key] = payload
            _CACHE_STATS["stores"] += 1
        return self.reply(201, {"key": key, "bytes": len(payload)})

    def do_DELETE(self):
        key = self.tail("/cache/")
        if key is None:
            return self.reply(400, {"error": "invalid cache key"})
        with _CACHE_LOCK:
            _CACHE.pop(key, None)
        return self.reply(200, {"key": key, "evicted": True})


# --------------------------------------------------------------------------
# message queue
# --------------------------------------------------------------------------
_QUEUES = {}
_QUEUE_LOCK = threading.Lock()


class QueueHandler(Handler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"role": "queue", "status": "ok"})
        if self.path == "/stats":
            with _QUEUE_LOCK:
                depth = dict((name, len(q)) for name, q in _QUEUES.items())
            return self.reply(200, {"queues": depth})
        name = self.tail("/queues/")
        if name is None:
            return self.reply(404, {"error": "no such route", "path": self.path})
        with _QUEUE_LOCK:
            queue = _QUEUES.get(name) or deque()
            message = queue.popleft() if queue else None
        if message is None:
            return self.reply(200, {"queue": name, "empty": True})
        return self.reply(200, {"queue": name, "message": message.decode(errors="replace")})

    def do_POST(self):
        name = self.tail("/queues/")
        payload = self.read_body()
        if name is None:
            return self.reply(400, {"error": "invalid queue name"})
        with _QUEUE_LOCK:
            _QUEUES.setdefault(name, deque()).append(payload)
            depth = len(_QUEUES[name])
        return self.reply(201, {"queue": name, "depth": depth})


# --------------------------------------------------------------------------
# application runtime
# --------------------------------------------------------------------------
class ApiHandler(Handler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"role": "api", "instance": INSTANCE_ID, "status": "ok"})
        order_id = self.tail("/orders/")
        if order_id is None:
            return self.reply(404, {"error": "no such route", "path": self.path})

        code, body = call("GET", CACHE_URL + "/cache/" + order_id)
        if code == 200:
            return self.reply(200, {"instance": INSTANCE_ID, "source": "cache",
                                    "order": json.loads(body.decode())})

        code, body = call("GET", OBJECT_URL + "/objects/" + order_id)
        if code == 200:
            call("PUT", CACHE_URL + "/cache/" + order_id, body)
            return self.reply(200, {"instance": INSTANCE_ID, "source": "object-store",
                                    "order": json.loads(body.decode())})
        if code == 404:
            return self.reply(404, {"error": "no such order", "order_id": order_id})
        return self.reply(502, {"error": "object store unreachable",
                                "upstream": OBJECT_URL, "upstream_status": code,
                                "upstream_detail": body.decode(errors="replace").strip()})

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/orders":
            return self.reply(404, {"error": "no such route", "path": self.path})
        raw = self.read_body()
        try:
            payload = json.loads(raw.decode()) if raw else {}
        except ValueError:
            return self.reply(400, {"error": "body is not valid JSON"})

        order_id = "ord-" + uuid.uuid4().hex[:10]
        record = {"order_id": order_id, "created_at": int(time.time()),
                  "served_by": INSTANCE_ID, "payload": payload}
        blob = json.dumps(record).encode()

        # The object store is the system of record: its failure is fatal.
        code, body = call("PUT", OBJECT_URL + "/objects/" + order_id, blob)
        if code not in (200, 201):
            return self.reply(502, {"error": "object store write failed",
                                    "upstream": OBJECT_URL, "upstream_status": code,
                                    "upstream_detail": body.decode(errors="replace").strip()})

        # The cache is an optimisation: its failure degrades, it does not fail.
        ccode, _ = call("PUT", CACHE_URL + "/cache/" + order_id, blob)

        # A lost order event is not acceptable: the queue's failure is fatal.
        qcode, qbody = call("POST", QUEUE_URL + "/queues/orders", blob)
        if qcode not in (200, 201):
            return self.reply(502, {"error": "queue publish failed",
                                    "upstream": QUEUE_URL, "upstream_status": qcode,
                                    "upstream_detail": qbody.decode(errors="replace").strip()})

        return self.reply(201, {"order_id": order_id, "instance": INSTANCE_ID,
                                "persisted": True, "queued": True,
                                "cache_warm": ccode in (200, 201)})


# --------------------------------------------------------------------------
# API gateway / load balancer
# --------------------------------------------------------------------------
class GatewayHandler(Handler):
    def do_GET(self):
        if self.path == "/_gw/healthz":
            return self.reply(200, {"role": "gw", "status": "ok", "pool": UPSTREAMS})
        if self.path == "/_gw/status":
            members = []
            for upstream in UPSTREAMS:
                code, body = call("GET", upstream + "/healthz", timeout=2.0)
                members.append({"upstream": upstream, "healthz_status": code,
                                "reachable": code == 200,
                                "detail": body.decode(errors="replace").strip()[:160]})
            healthy = sum(1 for m in members if m["reachable"])
            return self.reply(200, {"pool_size": len(UPSTREAMS), "healthy": healthy,
                                    "members": members})
        return self.forward("GET", None)

    def do_POST(self):
        return self.forward("POST", self.read_body())

    def do_PUT(self):
        return self.forward("PUT", self.read_body())

    def forward(self, method, data):
        target = UPSTREAMS[next(_RR) % len(UPSTREAMS)]
        code, body = call(method, target + self.path, data, timeout=5.0)
        if code == 0:
            return self.reply(502, {"error": "upstream unreachable", "upstream": target,
                                    "detail": body.decode(errors="replace")},
                              extra={"X-Shopfront-Upstream": target})
        return self.reply(code, body, "application/json",
                          extra={"X-Shopfront-Upstream": target})


def serve(handler_cls, port):
    srv = ThreadingHTTPServer((LISTEN_ADDR, port), handler_cls)
    srv.daemon_threads = True
    sys.stderr.write("%s listening on %s:%d\n" % (ROLE, LISTEN_ADDR, port))
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


def main():
    global OBJECT_URL, CACHE_URL, QUEUE_URL, INSTANCE_ID, UPSTREAMS
    port = int(env_or_die("PORT"))
    if ROLE == "object":
        try:
            os.makedirs(OBJECT_DIR, exist_ok=True)
        except OSError as exc:
            sys.stderr.write("WARN: cannot ensure %s: %s\n" % (OBJECT_DIR, exc))
        serve(ObjectHandler, port)
    elif ROLE == "cache":
        serve(CacheHandler, port)
    elif ROLE == "queue":
        serve(QueueHandler, port)
    elif ROLE == "api":
        INSTANCE_ID = os.environ.get("INSTANCE_ID", "0")
        OBJECT_URL = env_or_die("OBJECT_URL")
        CACHE_URL = env_or_die("CACHE_URL")
        QUEUE_URL = env_or_die("QUEUE_URL")
        serve(ApiHandler, port)
    elif ROLE == "gw":
        UPSTREAMS = [u.strip().rstrip("/") for u in env_or_die("UPSTREAMS").split(",") if u.strip()]
        if not UPSTREAMS:
            die_config("UPSTREAMS")
        serve(GatewayHandler, port)
    else:
        sys.stderr.write("usage: shopfront.py {object|cache|queue|api|gw}\n")
        raise SystemExit(64)


if __name__ == "__main__":
    main()
PYEOF
  chmod 0755 "$APP_DIR/shopfront.py"
}

write_config() {
  install -d -m 0755 "$CFG_DIR"
  cat > "$CFG_DIR/backing-services.env" <<'EOF'
# Twelve-factor III/IV: the application runtime learns where its attached
# resources live from here, and from nowhere else. Swapping the object store
# for S3 or the cache for a Redis cluster is an edit to this file plus a
# restart -- no code change, no rebuild.
OBJECT_URL=http://127.0.0.1:9101
CACHE_URL=http://127.0.0.1:9102
QUEUE_URL=http://127.0.0.1:9103
EOF
  cat > "$CFG_DIR/gateway.env" <<'EOF'
# Load-balancer pool membership. One entry per application runtime instance.
UPSTREAMS=http://127.0.0.1:9201,http://127.0.0.1:9202
EOF
  chmod 0644 "$CFG_DIR/backing-services.env" "$CFG_DIR/gateway.env"
}

write_units() {
  local py; py="$(command -v python3)"

  cat > "$UNIT_DIR/shopfront-object.service" <<EOF
[Unit]
Description=shopfront object storage (standard component: object store)
Documentation=https://www.lpi.org/our-certifications/exam-701-objectives/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
Environment=PORT=9101
Environment=LISTEN_ADDR=127.0.0.1
Environment=OBJECT_DIR=$OBJ_DIR
ExecStart=$py $APP_DIR/shopfront.py object
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/shopfront-cache.service" <<EOF
[Unit]
Description=shopfront cache (standard component: cache, volatile by design)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
Environment=PORT=9102
Environment=LISTEN_ADDR=127.0.0.1
ExecStart=$py $APP_DIR/shopfront.py cache
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/shopfront-queue.service" <<EOF
[Unit]
Description=shopfront message queue (standard component: broker)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
Environment=PORT=9103
Environment=LISTEN_ADDR=127.0.0.1
ExecStart=$py $APP_DIR/shopfront.py queue
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

  # Template unit: one instance per application runtime. %i is the instance
  # name, so instance 1 listens on 9201 and instance 2 on 9202.
  cat > "$UNIT_DIR/shopfront-api@.service" <<EOF
[Unit]
Description=shopfront application runtime, instance %i
After=shopfront-object.service shopfront-cache.service shopfront-queue.service
Wants=shopfront-object.service shopfront-cache.service shopfront-queue.service

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$CFG_DIR/backing-services.env
Environment=INSTANCE_ID=%i
Environment=PORT=920%i
Environment=LISTEN_ADDR=127.0.0.1
ExecStart=$py $APP_DIR/shopfront.py api
Restart=on-failure
RestartSec=2
StartLimitIntervalSec=30
StartLimitBurst=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/shopfront-gw.service" <<EOF
[Unit]
Description=shopfront API gateway / load balancer
After=shopfront-api@1.service shopfront-api@2.service
Wants=shopfront-api@1.service shopfront-api@2.service

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$CFG_DIR/gateway.env
Environment=PORT=8080
Environment=LISTEN_ADDR=${LAB_BIND_ADDR:-127.0.0.1}
ExecStart=$py $APP_DIR/shopfront.py gw
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

save_pristine() {
  install -d -m 0700 "$BACKUP_DIR"
  cp -a "$UNIT_DIR/shopfront-api@.service" "$BACKUP_DIR/"
  cp -a "$CFG_DIR/gateway.env" "$BACKUP_DIR/"
  cp -a "$CFG_DIR/backing-services.env" "$BACKUP_DIR/"
}

# -----------------------------------------------------------------------------
# Lifecycle
# -----------------------------------------------------------------------------
stop_stack() {
  systemctl stop "${UNITS[@]}" >/dev/null 2>&1 || true
  systemctl reset-failed "${UNITS[@]}" >/dev/null 2>&1 || true
}

wait_for() { # wait_for <url> <seconds>
  local url="$1" deadline=$(( SECONDS + ${2:-20} ))
  while (( SECONDS < deadline )); do
    curl -fsS --max-time 2 "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

http_code() { # http_code <method> <url> [body-file-out] [data]
  local method="$1" url="$2" out="${3:-/dev/null}" data="${4:-}"
  if [[ -n "$data" ]]; then
    curl -s -o "$out" -w '%{http_code}' --max-time 6 -X "$method" \
         -H 'Content-Type: application/json' -d "$data" "$url" 2>/dev/null || echo 000
  else
    curl -s -o "$out" -w '%{http_code}' --max-time 6 -X "$method" "$url" 2>/dev/null || echo 000
  fi
}

deploy() {
  preflight deploy
  confirm
  stop_stack

  local busy=()
  local p
  for p in "${PORTS[@]}"; do port_is_free "$p" || busy+=("$p"); done
  (( ${#busy[@]} == 0 )) || die "ports already in use by something else: ${busy[*]} -- use a clean VM"

  say "creating the system user '$SVC_USER'"
  id -u "$SVC_USER" >/dev/null 2>&1 || \
    useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SVC_USER" 2>/dev/null || \
    useradd --system --home-dir "$DATA_DIR" --shell /sbin/nologin "$SVC_USER"

  say "writing the application, its configuration and its units"
  install -d -m 0755 "$DATA_DIR"
  install -d -m 0755 "$OBJ_DIR"
  chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR"
  write_application
  write_config
  write_units
  save_pristine

  say "enabling and starting the stack"
  systemctl enable --now shopfront-object.service shopfront-cache.service \
                         shopfront-queue.service >/dev/null 2>&1
  systemctl enable --now shopfront-api@1.service shopfront-api@2.service >/dev/null 2>&1
  systemctl enable --now shopfront-gw.service >/dev/null 2>&1

  wait_for "$GW/_gw/healthz" 25 || die "the gateway never came up -- check: journalctl -u shopfront-gw -n 40"

  say "proving the baseline: creating one order through the gateway"
  local tmp code seed
  tmp="$(mktemp)"
  code="$(http_code POST "$GW/orders" "$tmp" '{"sku":"LPI-701-100","qty":1,"note":"baseline seed"}')"
  [[ "$code" == "201" ]] || { cat "$tmp"; rm -f "$tmp"; die "baseline order failed with HTTP $code"; }
  seed="$(grep -o '"order_id": "[^"]*"' "$tmp" | head -n1 | cut -d'"' -f4)"
  printf '%s\n' "$seed" > "$DATA_DIR/.seed-id"
  chown "$SVC_USER:$SVC_USER" "$DATA_DIR/.seed-id"
  rm -f "$tmp"

  ok "stack healthy. Seed order persisted as ${B}$seed${N}"
  hr
  cat <<EOF
Baseline you can reproduce right now:

  curl -s $GW/_gw/status            pool view (both members healthy)
  curl -s $GW/healthz               round-robin: instance flips 1 -> 2 -> 1
  curl -s $GW/orders/$seed
  curl -s http://127.0.0.1:9103/stats   queue depth
  curl -s http://127.0.0.1:9102/stats   cache hit/miss counters
EOF
  hr
}

break_it() {
  preflight break
  [[ -f "$APP_DIR/shopfront.py" ]] || die "nothing deployed yet -- run: sudo ./$SELF deploy"
  say "injecting faults"

  # Fault 1 -- the application runtime loses its configuration source.
  # The unit stops reading the environment file, so the runtime has no address
  # for any backing service and refuses to start (EX_CONFIG 78).
  sed -i '/^EnvironmentFile=/d' "$UNIT_DIR/shopfront-api@.service"
  systemctl daemon-reload
  systemctl restart shopfront-api@1.service shopfront-api@2.service >/dev/null 2>&1 || true

  # Fault 2 -- the object store keeps its data directory but loses write access
  # to it. Reads still succeed; every write fails.
  chown -R root:root "$OBJ_DIR"
  chmod 0755 "$OBJ_DIR"
  chmod -R a+r "$OBJ_DIR"
  systemctl restart shopfront-object.service >/dev/null 2>&1 || true

  # Fault 3 -- the load-balancer pool lists a member that does not exist.
  sed -i 's|^UPSTREAMS=.*|UPSTREAMS=http://127.0.0.1:9201,http://127.0.0.1:9209|' \
      "$CFG_DIR/gateway.env"
  systemctl restart shopfront-gw.service >/dev/null 2>&1 || true

  # The cache is volatile by design; restarting it empties it, so every read
  # now has to reach the object store instead of being served from memory.
  systemctl restart shopfront-cache.service >/dev/null 2>&1 || true
  sleep 2

  briefing
}

briefing() {
  local seed; seed="$(cat "$DATA_DIR/.seed-id" 2>/dev/null || echo '<seed-id>')"
  hr
  printf '%s\n' "${B}THE STACK IS BROKEN. THREE FAULTS, ONE PER LAYER, LAYERED ON PURPOSE.${N}"
  hr
  cat <<EOF
${B}Symptom you will see first${N}

  \$ curl -s -o /dev/null -w '%{http_code}\\n' $GW/healthz
  502
  \$ curl -s $GW/healthz
  {"error": "upstream unreachable", "upstream": "http://127.0.0.1:9201", ...}

  Every request through the gateway fails. The gateway itself is up: it is
  answering, and what it answers is that it cannot reach what is behind it.

${B}What you must achieve${N}

  1. Both application runtimes (shopfront-api@1 and shopfront-api@2) are
     'active (running)' and stay that way across a restart.
  2. POST $GW/orders returns HTTP 201 -- an order can be
     persisted to the object store and published to the queue.
  3. Load balancing is real again: consecutive requests through the gateway
     alternate between instance 1 and instance 2, with zero failures over a
     burst of eight.

  When those three hold, run:  ${C}sudo ./$SELF verify${N}

${B}Constraints (this is the part that is graded in real life)${N}

  * Do NOT hardcode backing-service URLs inside $APP_DIR/shopfront.py.
    Configuration belongs to the environment; a runtime that carries its own
    production addresses cannot be moved between stages.
  * Do NOT run the services as root to sidestep a permission problem.
  * Do NOT delete the pool member you cannot reach -- the stack is supposed to
    have two runtimes behind the load balancer, and it must survive one of
    them dying.

${B}Where to look${N}

  systemctl --failed
  systemctl status shopfront-api@1.service
  systemctl cat shopfront-api@.service            # the unit as systemd reads it
  systemctl show shopfront-api@1 -p Environment   # the environment as it ends up
  journalctl -u shopfront-api@1 -n 40 --no-pager
  journalctl -u shopfront-object -n 40 --no-pager
  curl -s $GW/_gw/status                          # pool membership + health
  ss -ltnp | grep -E ':(8080|910[1-3]|920[0-9])'
  sudo -u $SVC_USER test -w $OBJ_DIR && echo writable || echo NOT writable

${B}Hints, in the order the faults surface${N}

  * A service that dies immediately and repeatedly is telling you something in
    its startup path, not its request path. Exit code 78 is EX_CONFIG.
  * Once traffic flows, a read that works while a write fails is never a
    network problem. It is an authorisation problem on the write path.
  * A load balancer that fails exactly every other request is not flapping.
    It is doing precisely what its pool configuration told it to do.
  * Seed order still on disk for read tests: $seed

  Escape hatches:  ${C}sudo ./$SELF status${N}   ${C}sudo ./$SELF solution${N}   ${C}sudo ./$SELF reset${N}
EOF
  hr
}

status() {
  preflight status
  hr
  printf '%s\n' "${B}systemd view${N}"
  local unit state
  for unit in "${UNITS[@]}"; do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then
      printf '  %-34s %s%s%s\n' "$unit" "$G" "$state" "$N"
    else
      printf '  %-34s %s%s%s\n' "$unit" "$R" "${state:-unknown}" "$N"
    fi
  done
  hr
  printf '%s\n' "${B}gateway view${N}"
  curl -s --max-time 5 "$GW/_gw/status" || printf '  gateway unreachable on %s\n' "$GW"
  hr
  printf '%s\n' "${B}object store directory${N}"
  ls -ld "$OBJ_DIR" 2>/dev/null || true
  if sudo -u "$SVC_USER" test -w "$OBJ_DIR" 2>/dev/null; then
    printf '  writable by %s: %syes%s\n' "$SVC_USER" "$G" "$N"
  else
    printf '  writable by %s: %sno%s\n' "$SVC_USER" "$R" "$N"
  fi
  hr
}

verify() {
  preflight verify
  local failures=0 tmp code unit state
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  hr
  printf '%s\n' "${B}GRADING${N}"
  hr

  # --- check 1: every unit active, both runtimes included -------------------
  local down=()
  for unit in "${UNITS[@]}"; do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [[ "$state" == "active" ]] || down+=("$unit=${state:-unknown}")
  done
  if (( ${#down[@]} == 0 )); then
    ok "1/3 all six units are active (both application runtimes included)"
  else
    printf '%s[x]%s 1/3 not active: %s\n' "$R" "$N" "${down[*]}"
    failures=$((failures + 1))
  fi

  # --- check 2: a write survives the whole path ----------------------------
  code="$(http_code POST "$GW/orders" "$tmp" '{"sku":"LPI-701-100","qty":3,"note":"grading"}')"
  if [[ "$code" == "201" ]]; then
    ok "2/3 POST /orders -> 201, order persisted to the object store and queued"
  else
    printf '%s[x]%s 2/3 POST /orders -> HTTP %s\n' "$R" "$N" "$code"
    sed 's/^/        /' "$tmp" 2>/dev/null | head -n 3
    failures=$((failures + 1))
  fi

  # --- check 3: the pool really balances -----------------------------------
  local seen="" inst bad=0 i
  for i in 1 2 3 4 5 6 7 8; do
    code="$(http_code GET "$GW/healthz" "$tmp")"
    [[ "$code" == "200" ]] || bad=$((bad + 1))
    inst="$(grep -o '"instance": "[0-9]*"' "$tmp" 2>/dev/null | grep -o '[0-9]*' || true)"
    [[ -n "$inst" ]] && seen="$seen$inst"
  done
  if (( bad == 0 )) && [[ "$seen" == *1* && "$seen" == *2* ]]; then
    ok "3/3 8/8 requests succeeded and both instances served traffic (seen: $seen)"
  else
    printf '%s[x]%s 3/3 %s failed request(s) out of 8; instances observed: %s\n' \
           "$R" "$N" "$bad" "${seen:-none}"
    failures=$((failures + 1))
  fi

  hr
  if (( failures == 0 )); then
    printf '%s\n' "${G}${B}ALL CHECKS PASSED.${N} The stack is repaired."
    cat <<EOF

What you just proved, in the vocabulary of objective 701.2:

  * The application runtime is stateless and gets its attached resources from
    the environment -- which is why two identical instances can sit behind one
    load balancer and why fixing the config fixed both at once.
  * The object store is the system of record and its failure is fatal to a
    write; the cache is an optimisation and its failure is not. Those are
    different components with different failure contracts on purpose.
  * The load balancer's pool is configuration, not discovery. Nothing told it
    that :9209 was fiction; it kept sending one request in two to a port that
    was never going to answer.
EOF
    hr
    return 0
  fi
  printf '%s\n' "${R}${B}$failures check(s) still failing.${N} Run '${C}sudo ./$SELF status${N}' and keep going."
  hr
  return 1
}

reset_lab() {
  preflight reset
  [[ -d "$BACKUP_DIR" ]] || die "no pristine copy found -- run: sudo ./$SELF deploy"
  warn "restoring the pristine stack (this discards your repair)"
  cp -a "$BACKUP_DIR/shopfront-api@.service" "$UNIT_DIR/"
  cp -a "$BACKUP_DIR/gateway.env" "$CFG_DIR/"
  cp -a "$BACKUP_DIR/backing-services.env" "$CFG_DIR/"
  chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR"
  systemctl daemon-reload
  systemctl reset-failed "${UNITS[@]}" >/dev/null 2>&1 || true
  systemctl restart "${UNITS[@]}" >/dev/null 2>&1 || true
  wait_for "$GW/_gw/healthz" 25 && ok "stack restored and healthy" || die "restore failed"
}

cleanup() {
  preflight cleanup
  warn "removing the lab from this VM"
  systemctl disable --now "${UNITS[@]}" >/dev/null 2>&1 || true
  systemctl reset-failed "${UNITS[@]}" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR"/shopfront-object.service "$UNIT_DIR"/shopfront-cache.service \
        "$UNIT_DIR"/shopfront-queue.service "$UNIT_DIR"/shopfront-api@.service \
        "$UNIT_DIR"/shopfront-gw.service
  rm -rf "$UNIT_DIR"/shopfront-api@.service.d "$UNIT_DIR"/shopfront-gw.service.d
  systemctl daemon-reload
  rm -rf "$APP_DIR" "$CFG_DIR" "$DATA_DIR"
  id -u "$SVC_USER" >/dev/null 2>&1 && userdel "$SVC_USER" >/dev/null 2>&1 || true
  ok "lab removed"
}

solution() {
  sed -n '/^# ==== SOLUTION START ====/,/^# ==== SOLUTION END ====/p' "$0" | sed 's/^#\( \|$\)//'
}

usage() {
  sed -n '2,50p' "$0" | sed 's/^#\( \|$\)//'
}

case "${1:-all}" in
  all)      deploy; break_it ;;
  deploy)   deploy ;;
  break)    break_it ;;
  status)   status ;;
  verify)   verify ;;
  reset)    reset_lab ;;
  cleanup)  cleanup ;;
  solution) solution ;;
  help|-h|--help) usage ;;
  *) die "unknown command '${1}'. Try: $SELF help" ;;
esac

# ==== SOLUTION START ====
#
# =============================================================================
#  SOLUTION -- 701.2 Standard Components and Platforms for Software
# =============================================================================
#
#  Read this only after you have tried. The three faults are peeled in order:
#  each one hides the next, so fixing them out of order is not possible.
#
# -----------------------------------------------------------------------------
#  FAULT 1 -- the application runtime lost its configuration source
# -----------------------------------------------------------------------------
#
#  Triage. The gateway answers, so the gateway is not the problem; it is
#  reporting that the thing behind it is gone.
#
#    $ curl -s http://127.0.0.1:8080/_gw/status
#    {"pool_size": 2, "healthy": 0, "members": [...]}
#
#    $ systemctl --failed
#      UNIT                    LOAD   ACTIVE SUB    DESCRIPTION
#    * shopfront-api@1.service loaded failed failed shopfront application runtime, instance 1
#    * shopfront-api@2.service loaded failed failed shopfront application runtime, instance 2
#
#  Read the journal. A process that dies in milliseconds is failing in its
#  startup path, and it usually says why:
#
#    $ journalctl -u shopfront-api@1 -n 20 --no-pager
#    ... shopfront.py[1421]: FATAL: OBJECT_URL is not set. Backing services are
#                            attached resources; their addresses must be supplied
#                            through the environment.
#    ... systemd[1]: shopfront-api@1.service: Main process exited, code=exited, status=78/CONFIG
#    ... systemd[1]: shopfront-api@1.service: Failed with result 'exit-code'.
#    ... systemd[1]: shopfront-api@1.service: Start request repeated too quickly.
#
#  status=78/CONFIG is EX_CONFIG from sysexits.h: the program started, looked at
#  its configuration, and refused. Compare what the unit provides against what
#  the runtime needs:
#
#    $ systemctl cat shopfront-api@.service | grep -iE 'environment|execstart'
#    Environment=INSTANCE_ID=%i
#    Environment=PORT=920%i
#    Environment=LISTEN_ADDR=127.0.0.1
#    ExecStart=/usr/bin/python3 /opt/shopfront/shopfront.py api
#
#    $ systemctl show shopfront-api@1 -p Environment
#    Environment=INSTANCE_ID=1 PORT=9201 LISTEN_ADDR=127.0.0.1
#
#  The EnvironmentFile= line is gone, so OBJECT_URL / CACHE_URL / QUEUE_URL
#  never reach the process. The file itself is intact:
#
#    $ cat /etc/shopfront/backing-services.env
#    OBJECT_URL=http://127.0.0.1:9101
#    CACHE_URL=http://127.0.0.1:9102
#    QUEUE_URL=http://127.0.0.1:9103
#
#  Fix -- put the reference back. Editing the unit in place is fine:
#
#    $ sudo systemctl edit --full shopfront-api@.service
#      # under [Service], above the Environment= lines, add:
#      EnvironmentFile=/etc/shopfront/backing-services.env
#
#  or, equivalently and without touching the shipped unit, use a drop-in --
#  which is what you would do on a machine where the unit comes from a package:
#
#    $ sudo mkdir -p /etc/systemd/system/shopfront-api@.service.d
#    $ printf '[Service]\nEnvironmentFile=/etc/shopfront/backing-services.env\n' \
#        | sudo tee /etc/systemd/system/shopfront-api@.service.d/10-config.conf
#
#  Then reload, clear the start-rate limit (the units hit it while crash-looping,
#  and until it is cleared systemd answers "Start request repeated too quickly"),
#  and start them:
#
#    $ sudo systemctl daemon-reload
#    $ sudo systemctl reset-failed shopfront-api@1.service shopfront-api@2.service
#    $ sudo systemctl restart shopfront-api@1.service shopfront-api@2.service
#    $ systemctl is-active shopfront-api@1.service shopfront-api@2.service
#    active
#    active
#
#  Why this is the objective and not systemd trivia: the runtime is stateless and
#  identical in both instances. Its knowledge of every backing service arrives
#  from outside. That is what lets you run N copies behind a load balancer, move
#  the same artifact from staging to production, and swap the object store for
#  S3 without a rebuild -- and it is why one missing line took down both
#  instances at once.
#
# -----------------------------------------------------------------------------
#  FAULT 2 -- the object store cannot write, only read
# -----------------------------------------------------------------------------
#
#  With the runtimes back, half the traffic flows. Reads work:
#
#    $ SEED=$(cat /var/lib/shopfront/.seed-id)
#    $ curl -s http://127.0.0.1:8080/orders/$SEED
#    {"instance": "1", "source": "object-store", "order": {"order_id": "ord-...", ...}}
#
#  Writes do not:
#
#    $ curl -s -X POST -H 'Content-Type: application/json' \
#        -d '{"sku":"LPI-701-100","qty":2}' http://127.0.0.1:8080/orders
#    {"error": "object store write failed", "upstream": "http://127.0.0.1:9101",
#     "upstream_status": 500,
#     "upstream_detail": "{\"error\": \"object write failed\", \"key\": \"ord-...\",
#      \"detail\": \"[Errno 13] Permission denied: '/var/lib/shopfront/objects/ord-...'\"}"}
#
#  A read that works while a write fails is never connectivity. Confirm from the
#  component's own health endpoint and from the filesystem:
#
#    $ curl -s http://127.0.0.1:9101/healthz
#    {"role": "object", "status": "ok", "dir": "/var/lib/shopfront/objects", "writable": false}
#
#    $ journalctl -u shopfront-object -n 10 --no-pager
#    ... shopfront.py[1502]: object write failed: PermissionError(13, 'Permission denied')
#
#    $ ls -ld /var/lib/shopfront/objects
#    drwxr-xr-x. 2 root root 4096 ... /var/lib/shopfront/objects
#
#    $ systemctl show shopfront-object -p User
#    User=shopfront
#
#  The service runs as 'shopfront'; the directory belongs to root with 0755, so
#  the process can traverse and read it but cannot create entries in it.
#
#  Fix -- give the component back its own state directory. Do NOT run the
#  service as root, and do NOT chmod 0777:
#
#    $ sudo chown -R shopfront:shopfront /var/lib/shopfront
#    $ sudo -u shopfront test -w /var/lib/shopfront/objects && echo writable
#    writable
#
#  No restart is required -- the permission is evaluated per open(2) -- but
#  restarting is harmless:
#
#    $ curl -s -X POST -H 'Content-Type: application/json' \
#        -d '{"sku":"LPI-701-100","qty":2}' http://127.0.0.1:8080/orders
#    {"order_id": "ord-4f2a1c9b0d", "instance": "1", "persisted": true,
#     "queued": true, "cache_warm": true}
#
#  Note which components cared. The object store is the system of record, so its
#  failure aborted the request with 502. The cache failing would only have set
#  "cache_warm": false -- a cache is an optimisation, and treating it as
#  mandatory turns an optional component into a single point of failure. The
#  queue is mandatory here because a dropped order event is a lost business
#  fact. Those contracts are a design decision per component, not a default.
#
# -----------------------------------------------------------------------------
#  FAULT 3 -- the load-balancer pool points at a member that does not exist
# -----------------------------------------------------------------------------
#
#  Now the stack works exactly half the time:
#
#    $ for i in $(seq 1 6); do curl -s -o /dev/null -w '%{http_code} ' \
#        http://127.0.0.1:8080/healthz; done; echo
#    200 502 200 502 200 502
#
#  Alternating, not flapping. A round-robin balancer that fails every other
#  request is faithfully sending every other request somewhere wrong. Ask it:
#
#    $ curl -s http://127.0.0.1:8080/_gw/status
#    {"pool_size": 2, "healthy": 1, "members": [
#      {"upstream": "http://127.0.0.1:9201", "healthz_status": 200, "reachable": true, ...},
#      {"upstream": "http://127.0.0.1:9209", "healthz_status": 0, "reachable": false,
#       "detail": "[Errno 111] Connection refused"}]}
#
#  Cross-check what is actually listening:
#
#    $ ss -ltnp | grep -E ':(8080|910[1-3]|920[0-9])'
#    LISTEN 0 5 127.0.0.1:9201 ... users:(("python3",pid=1601,fd=3))
#    LISTEN 0 5 127.0.0.1:9202 ... users:(("python3",pid=1608,fd=3))
#    LISTEN 0 5 127.0.0.1:9101 ...
#    LISTEN 0 5 127.0.0.1:8080 ...
#
#  Instance 2 is healthy on 9202. The pool is asking for 9209 -- one transposed
#  digit in configuration, nothing wrong with any service:
#
#    $ cat /etc/shopfront/gateway.env
#    UPSTREAMS=http://127.0.0.1:9201,http://127.0.0.1:9209
#
#  Fix -- correct the pool and restart the gateway. The gateway reads its
#  environment file at startup, so an edit alone changes nothing:
#
#    $ sudo sed -i 's|9209|9202|' /etc/shopfront/gateway.env
#    $ sudo systemctl restart shopfront-gw.service
#
#    $ curl -s http://127.0.0.1:8080/_gw/status | head -c 120
#    {"pool_size": 2, "healthy": 2, "members": [...
#
#    $ for i in $(seq 1 4); do curl -s http://127.0.0.1:8080/healthz \
#        | grep -o '"instance": "[0-9]*"'; done
#    "instance": "1"
#    "instance": "2"
#    "instance": "1"
#    "instance": "2"
#
#  Do not "fix" this by deleting the unreachable member. A pool of one is not a
#  load balancer; it is a single point of failure with extra latency. The point
#  of two runtimes is that either may die without an outage -- which you can
#  prove, and should:
#
#    $ sudo systemctl stop shopfront-api@2.service
#    $ for i in $(seq 1 4); do curl -s -o /dev/null -w '%{http_code} ' \
#        http://127.0.0.1:8080/healthz; done; echo
#    200 502 200 502
#    $ sudo systemctl start shopfront-api@2.service
#
#  That 502 is the honest behaviour of a balancer doing pure round-robin with no
#  health checking and no retry. Real front ends -- HAProxy, NGINX, an ELB, a
#  Kubernetes Service with readiness probes -- close that gap by removing a
#  failing member from rotation until its health check passes again. Recognising
#  that active health checking, not the round-robin itself, is what makes a
#  pool fault-tolerant is the 701.2 lesson here.
#
# -----------------------------------------------------------------------------
#  VERIFY
# -----------------------------------------------------------------------------
#
#    $ sudo ./break_fix.sh verify
#    [+] 1/3 all six units are active (both application runtimes included)
#    [+] 2/3 POST /orders -> 201, order persisted to the object store and queued
#    [+] 3/3 8/8 requests succeeded and both instances served traffic (seen: 12121212)
#    ALL CHECKS PASSED. The stack is repaired.
#
#  Optional, to see the message queue component do its job -- every order you
#  created is still waiting to be consumed:
#
#    $ curl -s http://127.0.0.1:9103/stats
#    {"queues": {"orders": 3}}
#    $ curl -s http://127.0.0.1:9103/queues/orders
#    {"queue": "orders", "message": "{\"order_id\": \"ord-4f2a1c9b0d\", ...}"}
#
#  And the cache, which is empty after a restart by design and fills on demand:
#
#    $ curl -s http://127.0.0.1:9102/stats
#    {"hits": 4, "misses": 2, "stores": 5, "entries": 5}
#
#  Tear the lab down with:  sudo ./break_fix.sh cleanup
#
# -----------------------------------------------------------------------------
#  MAPPING BACK TO THE EXAM OBJECTIVE
# -----------------------------------------------------------------------------
#
#   Component in this lab   Standard component     Typical production form
#   ---------------------   --------------------   ----------------------------
#   shopfront-object        object storage         S3, MinIO, Swift, GCS, Blob
#   shopfront-cache         cache                  Redis, Memcached
#   shopfront-queue         message queue/broker   RabbitMQ, Kafka, SQS, NATS
#   shopfront-api@N         application runtime    a 12-factor process, a Pod
#   shopfront-gw            LB / API gateway       HAProxy, NGINX, ELB, Ingress
#   backing-services.env    config as environment  ConfigMap/Secret, Parameter
#                                                  Store, Vault, PaaS bindings
#
#  On a PaaS (Cloud Foundry, OpenShift) or on Kubernetes the same three faults
#  wear different clothes and behave identically: a missing ConfigMap key or an
#  unbound service instance crash-loops the Pod (fault 1); a read-only or
#  wrongly-owned PersistentVolume lets reads through and rejects writes
#  (fault 2); a Service selector matching the wrong label sends a share of the
#  traffic nowhere (fault 3). The platform changes, the component taxonomy and
#  the failure modes do not.
#
#  Reference: https://www.lpi.org/our-certifications/exam-701-objectives/
# ==== SOLUTION END ====