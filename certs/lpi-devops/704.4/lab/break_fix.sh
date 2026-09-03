#!/usr/bin/env bash
#
# ==============================================================================
#  LPI DevOps Tools Engineer (Exam 701-100, v2.0.0)
#  Topic 704.4 - Tracing   |   Exam weight: 3.33
#  BREAK & FIX LAB - "The day the traces disappeared"
# ==============================================================================
#
#  WHAT THIS IS
#  ------------
#  A self-contained, dependency-free distributed-tracing lab plus a controlled
#  outage injected into it. You get a two-service request path behind an API
#  gateway, exporting spans over OTLP/HTTP JSON to a trace backend, exactly the
#  topology the objective asks you to reason about:
#
#      curl --> checkout-frontend --> edge-proxy --> payments-api
#                       |                                  |
#                       +---------- OTLP/HTTP -------------+
#                                       |
#                                       v
#                               minicollector (:14318)
#                        /v1/traces  +  Jaeger-style query API
#
#  Everything is implemented with the Python 3 standard library. There is no
#  pip install, no container runtime, no root, no systemd unit, no firewall
#  change, and every socket binds to 127.0.0.1 only. The wire format IS the real
#  OTLP/HTTP JSON encoding and the propagation format IS real W3C Trace Context,
#  so the same services can be re-pointed at a genuine OpenTelemetry Collector
#  or Jaeger all-in-one (port 4318) by editing a single variable.
#
#  SAFETY
#  ------
#  Designed for a DISPOSABLE lab VM. It writes only inside $LAB_HOME
#  (default: ~/lpi-704.4-tracing-lab), listens only on loopback on high ports
#  (14318 / 18080 / 18081 / 18082), and `clean` removes every trace of it.
#
#  OFFICIAL REFERENCES
#  -------------------
#    LPI 701-100 objectives ... https://www.lpi.org/our-certifications/exam-701-objectives/
#    W3C Trace Context ........ https://www.w3.org/TR/trace-context/
#    OTLP specification ....... https://opentelemetry.io/docs/specs/otlp/
#    OTel sampling ............ https://opentelemetry.io/docs/concepts/sampling/
#    OTel SDK env vars ........ https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
#    Jaeger architecture ...... https://www.jaegertracing.io/docs/latest/architecture/
#
#  USAGE
#  -----
#    ./704.4-tracing-breakfix.sh              # setup + inject faults + briefing
#    ./704.4-tracing-breakfix.sh status       # processes, ports, SDK self-telemetry
#    ./704.4-tracing-breakfix.sh logs <svc>   # collector|checkout-frontend|payments-api|edge-proxy
#    ./704.4-tracing-breakfix.sh load [n]     # send n requests through the path
#    ./704.4-tracing-breakfix.sh traces       # list traces held by the backend
#    ./704.4-tracing-breakfix.sh trace <id>   # ASCII waterfall of one trace
#    ./704.4-tracing-breakfix.sh restart      # apply config changes
#    ./704.4-tracing-breakfix.sh verify       # grade your fix (exit 0 == solved)
#    ./704.4-tracing-breakfix.sh solution     # spoiler: print the commented answer
#    ./704.4-tracing-breakfix.sh clean        # stop everything and delete $LAB_HOME
#
# ==============================================================================

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
LAB_HOME="${LAB_HOME:-$HOME/lpi-704.4-tracing-lab}"
LAB_ASSUME_YES="${LAB_ASSUME_YES:-0}"

COLLECTOR_PORT=14318
COLLECTOR_BAD_PORT=14317
PROXY_PORT=18080
FRONTEND_PORT=18081
PAYMENTS_PORT=18082

SERVICES="collector payments-api edge-proxy checkout-frontend"

C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
fi

log()     { printf '%s[lab]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn()    { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf '%s[fatal]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
rule()    { printf '%s\n' "------------------------------------------------------------------------"; }

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------
require_tools() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required (stdlib only, no pip packages)."
  python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)' \
    || die "python3 >= 3.7 is required (time.time_ns)."
  command -v curl >/dev/null 2>&1 || warn "curl not found: the lab still works, but the manual drills in the briefing assume it."
}

confirm_disposable() {
  [ "$LAB_ASSUME_YES" = "1" ] && return 0
  section "This lab starts four loopback services and injects a controlled outage."
  cat <<TXT
It writes only under: $LAB_HOME
It binds only:        127.0.0.1:$COLLECTOR_PORT, :$PROXY_PORT, :$FRONTEND_PORT, :$PAYMENTS_PORT
It never touches:     packages, systemd, firewall, /etc, any remote host

Run it on a DISPOSABLE lab VM, not on a workstation you care about.
TXT
  printf '\nType "yes" to continue: '
  local answer=''
  read -r answer || true
  [ "$answer" = "yes" ] || die "Aborted by the student."
}

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

wait_port() {
  local port="$1" tries="${2:-60}" i=0
  while [ "$i" -lt "$tries" ]; do
    port_busy "$port" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

preflight_ports() {
  local p
  for p in "$COLLECTOR_PORT" "$PROXY_PORT" "$FRONTEND_PORT" "$PAYMENTS_PORT"; do
    if port_busy "$p"; then
      die "127.0.0.1:$p is already in use. Free it, or re-run with different ports in the script header."
    fi
  done
}

# ------------------------------------------------------------------------------
# Lab tree
# ------------------------------------------------------------------------------
write_tree() {
  mkdir -p "$LAB_HOME/bin" "$LAB_HOME/etc" "$LAB_HOME/log" "$LAB_HOME/run" "$LAB_HOME/data"

  # ---------------------------------------------------------------- tracelib.py
  cat >"$LAB_HOME/bin/tracelib.py" <<'PY'
#!/usr/bin/env python3
"""tracelib - the parts of an OpenTelemetry SDK that objective 704.4 is about.

Dependency-free and deliberately small, but not a toy: the context header is
W3C Trace Context (https://www.w3.org/TR/trace-context/), the sampler follows
the OTel parent-based / trace-id-ratio semantics, and the exporter emits the
OTLP/HTTP JSON encoding (https://opentelemetry.io/docs/specs/otlp/).
"""

import json
import os
import random
import time
import urllib.error
import urllib.request

HEX = "0123456789abcdef"
INVALID_TRACE_ID = "0" * 32
INVALID_SPAN_ID = "0" * 16

# OTLP SpanKind enum (opentelemetry/proto/trace/v1/trace.proto)
SPAN_KIND = {
    "UNSPECIFIED": 0,
    "INTERNAL": 1,
    "SERVER": 2,
    "CLIENT": 3,
    "PRODUCER": 4,
    "CONSUMER": 5,
}
KIND_NAME = {v: k for k, v in SPAN_KIND.items()}


def _rand_hex(length):
    return "".join(random.choice(HEX) for _ in range(length))


def new_trace_id():
    return _rand_hex(32)


def new_span_id():
    return _rand_hex(16)


def load_env_file(path):
    """Parse a KEY=VALUE file the way an environment file is parsed."""
    conf = {}
    with open(path) as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            conf[key.strip()] = value.strip().strip('"').strip("'")
    return conf


def parse_traceparent(value):
    """Decode `traceparent: 00-<32 hex>-<16 hex>-<2 hex>` into a span context.

    Returns None for anything malformed, which is exactly what a compliant
    propagator does: an invalid traceparent is ignored and the receiving span
    becomes a new root instead of inheriting garbage.
    """
    if not value:
        return None
    parts = value.strip().split("-")
    if len(parts) != 4:
        return None
    version, trace_id, span_id, flags = parts
    if len(version) != 2 or len(trace_id) != 32 or len(span_id) != 16 or len(flags) != 2:
        return None
    try:
        flag_bits = int(flags, 16)
        int(trace_id, 16)
        int(span_id, 16)
    except ValueError:
        return None
    if trace_id == INVALID_TRACE_ID or span_id == INVALID_SPAN_ID:
        return None
    return {
        "version": version,
        "trace_id": trace_id,
        "span_id": span_id,
        "flags": flags,
        "sampled": bool(flag_bits & 0x01),
    }


def format_traceparent(trace_id, span_id, sampled):
    return "00-%s-%s-%s" % (trace_id, span_id, "01" if sampled else "00")


class Sampler(object):
    """Head-based sampler: always_on | always_off | traceidratio, parent-based.

    parentbased_* means: if there is a remote parent, honour ITS sampling
    decision and do not re-roll the dice. That is what keeps a distributed
    trace whole instead of producing half-sampled fragments.
    """

    def __init__(self, kind, arg):
        self.kind = (kind or "parentbased_always_on").strip().lower()
        try:
            self.ratio = float(arg)
        except (TypeError, ValueError):
            self.ratio = 1.0
        self.ratio = min(max(self.ratio, 0.0), 1.0)
        self.threshold = int(self.ratio * (1 << 64))

    def should_sample(self, trace_id, parent):
        if self.kind.startswith("parentbased") and parent is not None:
            return parent["sampled"]
        if self.kind.endswith("always_off"):
            return False
        if self.kind.endswith("always_on"):
            return True
        # traceidratio: deterministic on the low 64 bits of the trace id, so
        # every service in the path reaches the same verdict for the same trace.
        return int(trace_id[16:], 16) < self.threshold

    def describe(self):
        return "%s(ratio=%.3f)" % (self.kind, self.ratio)


class Span(object):
    def __init__(self, tracer, trace_id, span_id, parent_span_id, name, kind, sampled, attributes):
        self.tracer = tracer
        self.trace_id = trace_id
        self.span_id = span_id
        self.parent_span_id = parent_span_id
        self.name = name
        self.kind = kind
        self.sampled = sampled
        self.attributes = dict(attributes or {})
        self.status_code = 0  # 0=UNSET 1=OK 2=ERROR
        self.status_message = ""
        self.start_ns = time.time_ns()
        self.end_ns = None

    def context(self):
        return {
            "version": "00",
            "trace_id": self.trace_id,
            "span_id": self.span_id,
            "flags": "01" if self.sampled else "00",
            "sampled": self.sampled,
        }

    def traceparent(self):
        return format_traceparent(self.trace_id, self.span_id, self.sampled)

    def set_attribute(self, key, value):
        self.attributes[key] = value

    def set_error(self, message):
        self.status_code = 2
        self.status_message = str(message)[:200]

    def set_ok(self):
        if self.status_code == 0:
            self.status_code = 1

    def end(self):
        if self.end_ns is not None:
            return
        self.end_ns = time.time_ns()
        if self.sampled:
            self.tracer.export(self)
        else:
            self.tracer.dropped_by_sampler += 1

    def to_otlp(self):
        attrs = []
        for key, value in self.attributes.items():
            if isinstance(value, bool):
                item = {"boolValue": value}
            elif isinstance(value, int):
                item = {"intValue": str(value)}
            elif isinstance(value, float):
                item = {"doubleValue": value}
            else:
                item = {"stringValue": str(value)}
            attrs.append({"key": key, "value": item})
        return {
            "traceId": self.trace_id,
            "spanId": self.span_id,
            "parentSpanId": self.parent_span_id or "",
            "name": self.name,
            "kind": SPAN_KIND.get(self.kind, 1),
            "startTimeUnixNano": str(self.start_ns),
            "endTimeUnixNano": str(self.end_ns or time.time_ns()),
            "attributes": attrs,
            "status": {"code": self.status_code, "message": self.status_message},
        }


class Tracer(object):
    """Tracer provider + SimpleSpanProcessor + OTLP/HTTP exporter in one class."""

    def __init__(self, conf, logger):
        self.service = conf.get("OTEL_SERVICE_NAME", "unknown_service")
        self.instance = conf.get("OTEL_SERVICE_INSTANCE_ID", "instance-0")
        self.endpoint = conf.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:14318").rstrip("/")
        self.path = conf.get("OTEL_EXPORTER_OTLP_TRACES_PATH", "/v1/traces")
        try:
            self.timeout = float(conf.get("OTEL_EXPORTER_OTLP_TIMEOUT", "2"))
        except ValueError:
            self.timeout = 2.0
        self.sampler = Sampler(conf.get("OTEL_TRACES_SAMPLER"), conf.get("OTEL_TRACES_SAMPLER_ARG"))
        self.log = logger
        self.started = 0
        self.sampled = 0
        self.dropped_by_sampler = 0
        self.exported_ok = 0
        self.export_failures = 0
        self.last_export_error = ""

    def start_span(self, name, kind="INTERNAL", parent=None, attributes=None):
        self.started += 1
        if parent:
            trace_id = parent["trace_id"]
            parent_span_id = parent["span_id"]
        else:
            trace_id = new_trace_id()
            parent_span_id = ""
        sampled = self.sampler.should_sample(trace_id, parent)
        if sampled:
            self.sampled += 1
        return Span(self, trace_id, new_span_id(), parent_span_id, name, kind, sampled, attributes)

    def export(self, span):
        payload = {
            "resourceSpans": [
                {
                    "resource": {
                        "attributes": [
                            {"key": "service.name", "value": {"stringValue": self.service}},
                            {"key": "service.instance.id", "value": {"stringValue": self.instance}},
                            {"key": "telemetry.sdk.name", "value": {"stringValue": "tracelib"}},
                            {"key": "telemetry.sdk.language", "value": {"stringValue": "python"}},
                        ]
                    },
                    "scopeSpans": [
                        {
                            "scope": {"name": "lpi.704.4.lab", "version": "1.0.0"},
                            "spans": [span.to_otlp()],
                        }
                    ],
                }
            ]
        }
        url = self.endpoint + self.path
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            url, data=data, headers={"Content-Type": "application/json"}, method="POST"
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                response.read()
            self.exported_ok += 1
        except Exception as exc:  # noqa: BLE001 - an exporter must never crash the app
            self.export_failures += 1
            self.last_export_error = "%s: %s" % (type(exc).__name__, exc)
            self.log("OTLP EXPORT FAILED endpoint=%s span=%s error=%s" % (url, span.name, self.last_export_error))

    def stats(self):
        return {
            "service": self.service,
            "sampler": self.sampler.describe(),
            "otlp_endpoint": self.endpoint + self.path,
            "spans_started": self.started,
            "spans_sampled": self.sampled,
            "spans_dropped_by_sampler": self.dropped_by_sampler,
            "spans_exported_ok": self.exported_ok,
            "span_export_failures": self.export_failures,
            "last_export_error": self.last_export_error,
        }
PY

  # --------------------------------------------------------------- collector.py
  cat >"$LAB_HOME/bin/collector.py" <<'PY'
#!/usr/bin/env python3
"""minicollector - OTLP/HTTP JSON receiver, span store and Jaeger-style query API.

Endpoints
  POST /v1/traces        OTLP/HTTP JSON ingest (same path a real Collector or
                         Jaeger exposes on :4318)
  GET  /api/traces       trace summaries
  GET  /api/traces/<id>  every span of one trace
  GET  /api/spans?since=N  raw spans after sequence N (used by the grader)
  GET  /-/healthy        liveness
"""

import json
import os
import sys
import threading

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tracelib import KIND_NAME, load_env_file  # noqa: E402

CONF = load_env_file(sys.argv[1])
ADDR = CONF.get("OTLP_LISTEN_ADDR", "127.0.0.1")
PORT = int(CONF.get("OTLP_LISTEN_PORT", "14318"))
STORE = CONF.get("LAB_STORE", "/tmp/lpi-lab-spans.jsonl")

LOCK = threading.Lock()
SPANS = []


def resource_attr(resource, key, default=""):
    for attr in resource.get("attributes", []):
        if attr.get("key") == key:
            return attr.get("value", {}).get("stringValue", default)
    return default


def flatten_attributes(attributes):
    flat = {}
    for attr in attributes or []:
        value = attr.get("value", {})
        for kind in ("stringValue", "intValue", "doubleValue", "boolValue"):
            if kind in value:
                flat[attr.get("key")] = value[kind]
                break
    return flat


def ingest(payload):
    accepted = []
    with LOCK:
        with open(STORE, "a") as handle:
            for resource_spans in payload.get("resourceSpans", []):
                resource = resource_spans.get("resource", {})
                service = resource_attr(resource, "service.name", "unknown_service")
                for scope_spans in resource_spans.get("scopeSpans", []):
                    for span in scope_spans.get("spans", []):
                        record = {
                            "seq": len(SPANS) + 1,
                            "service": service,
                            "traceId": span.get("traceId", ""),
                            "spanId": span.get("spanId", ""),
                            "parentSpanId": span.get("parentSpanId", ""),
                            "name": span.get("name", ""),
                            "kind": KIND_NAME.get(span.get("kind", 1), "INTERNAL"),
                            "startTimeUnixNano": int(span.get("startTimeUnixNano", "0")),
                            "endTimeUnixNano": int(span.get("endTimeUnixNano", "0")),
                            "attributes": flatten_attributes(span.get("attributes")),
                            "status": span.get("status", {}),
                        }
                        SPANS.append(record)
                        accepted.append(record)
                        handle.write(json.dumps(record) + "\n")
    return accepted


def summarise():
    traces = {}
    with LOCK:
        snapshot = list(SPANS)
    for span in snapshot:
        entry = traces.setdefault(
            span["traceId"],
            {"traceId": span["traceId"], "spans": 0, "services": set(),
             "start": span["startTimeUnixNano"], "end": span["endTimeUnixNano"], "roots": 0},
        )
        entry["spans"] += 1
        entry["services"].add(span["service"])
        entry["start"] = min(entry["start"], span["startTimeUnixNano"])
        entry["end"] = max(entry["end"], span["endTimeUnixNano"])
        if not span["parentSpanId"]:
            entry["roots"] += 1
    result = []
    for entry in traces.values():
        entry = dict(entry)
        entry["services"] = sorted(entry["services"])
        entry["durationNano"] = max(0, entry["end"] - entry["start"])
        result.append(entry)
    result.sort(key=lambda item: item["start"])
    return result


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, body, content_type="application/json"):
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        route = urlparse(self.path).path
        if route != "/v1/traces":
            self._reply(404, json.dumps({"error": "unknown route", "path": route}))
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except ValueError as exc:
            self._reply(400, json.dumps({"error": "bad OTLP JSON: %s" % exc}))
            return
        accepted = ingest(payload)
        for span in accepted:
            sys.stdout.write(
                "ingest service=%-18s trace=%s span=%s parent=%-16s name=%s\n"
                % (span["service"], span["traceId"], span["spanId"],
                   span["parentSpanId"] or "-", span["name"])
            )
        sys.stdout.flush()
        self._reply(200, json.dumps({"partialSuccess": {}}))

    def do_GET(self):
        parsed = urlparse(self.path)
        route = parsed.path
        query = parse_qs(parsed.query)
        if route == "/-/healthy":
            self._reply(200, json.dumps({"status": "ok", "spans": len(SPANS)}))
        elif route == "/api/spans":
            since = int(query.get("since", ["0"])[0])
            with LOCK:
                data = [span for span in SPANS if span["seq"] > since]
            self._reply(200, json.dumps({"count": len(SPANS), "spans": data}))
        elif route == "/api/traces":
            self._reply(200, json.dumps({"traces": summarise()}))
        elif route.startswith("/api/traces/"):
            trace_id = route.rsplit("/", 1)[-1]
            with LOCK:
                data = [span for span in SPANS if span["traceId"] == trace_id]
            self._reply(200, json.dumps({"traceId": trace_id, "spans": data}))
        else:
            self._reply(404, json.dumps({"error": "unknown route", "path": route}))

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    open(STORE, "a").close()
    sys.stdout.write("minicollector listening on %s:%d  otlp=/v1/traces  store=%s\n" % (ADDR, PORT, STORE))
    sys.stdout.flush()
    ThreadingHTTPServer((ADDR, PORT), Handler).serve_forever()
PY

  # ----------------------------------------------------------------- service.py
  cat >"$LAB_HOME/bin/service.py" <<'PY'
#!/usr/bin/env python3
"""An instrumented HTTP service. LAB_ROLE selects frontend or payments behaviour.

frontend  GET  /buy   -> SERVER span, then a CLIENT span around the downstream
                         call, injecting `traceparent` into the outgoing request.
payments  POST /pay   -> extracts `traceparent`, opens a SERVER span as the child
                         of the caller's CLIENT span, then an INTERNAL db span.

Both expose /-/healthy and /-/stats. /-/stats is the SDK self-telemetry: how
many spans were started, how many the sampler dropped, how many the exporter
managed to ship. Instrument your instrumentation - a pipeline that silently
discards data is indistinguishable from an application that receives no traffic.
"""

import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tracelib import Tracer, parse_traceparent  # noqa: E402
from tracelib import load_env_file  # noqa: E402

CONF = load_env_file(sys.argv[1])
ROLE = CONF.get("LAB_ROLE", "frontend")
ADDR = CONF.get("LAB_LISTEN_ADDR", "127.0.0.1")
PORT = int(CONF.get("LAB_LISTEN_PORT", "18081"))
DOWNSTREAM = CONF.get("LAB_DOWNSTREAM_URL", "")


def logline(message):
    sys.stdout.write("%s %s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), CONF.get("OTEL_SERVICE_NAME", ROLE), message))
    sys.stdout.flush()


TRACER = Tracer(CONF, logline)


def call_downstream(url, headers, body):
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.status, response.read()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _admin(self, route):
        if route == "/-/healthy":
            self._reply(200, {"status": "ok", "service": TRACER.service})
            return True
        if route == "/-/stats":
            self._reply(200, TRACER.stats())
            return True
        return False

    def do_GET(self):
        route = urlparse(self.path).path
        if self._admin(route):
            return
        if ROLE == "frontend" and route in ("/buy", "/"):
            self.handle_buy()
            return
        self._reply(404, {"error": "not found", "path": route})

    def do_POST(self):
        route = urlparse(self.path).path
        if self._admin(route):
            return
        if ROLE == "payments" and route == "/pay":
            self.handle_pay()
            return
        self._reply(404, {"error": "not found", "path": route})

    # ---------------------------------------------------------------- frontend
    def handle_buy(self):
        parent = parse_traceparent(self.headers.get("traceparent"))
        server = TRACER.start_span(
            "GET /buy",
            kind="SERVER",
            parent=parent,
            attributes={
                "http.request.method": "GET",
                "url.path": "/buy",
                "server.port": PORT,
                "context.remote_parent": bool(parent),
            },
        )
        client = TRACER.start_span(
            "POST /pay",
            kind="CLIENT",
            parent=server.context(),
            attributes={"http.request.method": "POST", "url.full": DOWNSTREAM, "peer.service": "payments-api"},
        )
        headers = {
            "Content-Type": "application/json",
            "X-Request-Id": "req-%06d" % random.randint(0, 999999),
            # Context injection. If this header does not survive every hop of the
            # path, the trace is cut in two: W3C Trace Context, section 3.2.
            "traceparent": client.traceparent(),
            "tracestate": "lpilab=1",
        }
        status = 500
        try:
            status, body = call_downstream(DOWNSTREAM, headers, json.dumps({"amount": 4200}).encode("utf-8"))
            client.set_attribute("http.response.status_code", status)
            client.set_ok()
            server.set_ok()
            payload = {"order": "ok", "downstream_status": status, "trace_id": server.trace_id,
                       "sampled": server.sampled}
        except Exception as exc:  # noqa: BLE001
            client.set_error(exc)
            server.set_error(exc)
            payload = {"order": "degraded", "error": str(exc), "trace_id": server.trace_id}
            status = 502
        finally:
            client.end()
            server.end()
        self._reply(200 if status == 200 else 502, payload)

    # ---------------------------------------------------------------- payments
    def handle_pay(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        header = self.headers.get("traceparent")
        parent = parse_traceparent(header)
        if parent is None:
            logline("no usable traceparent on inbound request: starting a NEW root trace (raw=%r)" % header)
        server = TRACER.start_span(
            "POST /pay",
            kind="SERVER",
            parent=parent,
            attributes={
                "http.request.method": "POST",
                "url.path": "/pay",
                "context.remote_parent": bool(parent),
                "http.request.header.traceparent": header or "<absent>",
            },
        )
        db = TRACER.start_span(
            "db.query ledger",
            kind="INTERNAL",
            parent=server.context(),
            attributes={"db.system": "postgresql", "db.operation.name": "INSERT", "db.collection.name": "ledger"},
        )
        time.sleep(random.uniform(0.005, 0.020))
        db.set_ok()
        db.end()
        server.set_ok()
        server.end()
        self._reply(200, {"payment": "captured", "trace_id": server.trace_id, "had_parent": bool(parent)})

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    logline("listening on %s:%d role=%s sampler=%s otlp=%s"
            % (ADDR, PORT, ROLE, TRACER.sampler.describe(), TRACER.endpoint + TRACER.path))
    ThreadingHTTPServer((ADDR, PORT), Handler).serve_forever()
PY

  # ------------------------------------------------------------------- proxy.py
  cat >"$LAB_HOME/bin/proxy.py" <<'PY'
#!/usr/bin/env python3
"""edge-proxy - an API gateway that forwards ONLY an explicit header allowlist.

This is how real gateways, meshes and CDNs behave: unknown request headers are
dropped unless declared. It creates no spans of its own, which is precisely why
a header policy mistake here is invisible in the gateway's own telemetry.

  GET /-/config  ->  the effective allowlist
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tracelib import load_env_file  # noqa: E402

CONF = load_env_file(sys.argv[1])
ADDR = CONF.get("PROXY_LISTEN_ADDR", "127.0.0.1")
PORT = int(CONF.get("PROXY_LISTEN_PORT", "18080"))
UPSTREAM = CONF.get("PROXY_UPSTREAM", "http://127.0.0.1:18082").rstrip("/")
ALLOW = [h.strip().lower() for h in CONF.get("PROXY_FORWARD_HEADERS", "").split(",") if h.strip()]
HOP_BY_HOP = {"host", "connection", "keep-alive", "transfer-encoding", "upgrade", "content-length"}


def logline(message):
    sys.stdout.write("%s edge-proxy %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), message))
    sys.stdout.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, raw, content_type="application/json"):
        if isinstance(raw, str):
            raw = raw.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if urlparse(self.path).path == "/-/config":
            self._reply(200, json.dumps({"upstream": UPSTREAM, "forward_headers": ALLOW}))
            return
        self._forward(b"")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self._forward(self.rfile.read(length) if length else b"")

    def _forward(self, body):
        forwarded, stripped = {}, []
        for name, value in self.headers.items():
            lowered = name.lower()
            if lowered in HOP_BY_HOP:
                continue
            if lowered in ALLOW:
                forwarded[name] = value
            else:
                stripped.append(lowered)
        forwarded["X-Forwarded-For"] = self.client_address[0]
        forwarded.setdefault("Content-Type", "application/json")
        logline("%s %s -> %s forwarded=%s stripped=%s"
                % (self.command, self.path, UPSTREAM + self.path,
                   sorted(k.lower() for k in forwarded), sorted(stripped)))
        request = urllib.request.Request(UPSTREAM + self.path, data=body, headers=forwarded, method=self.command)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                self._reply(response.status, response.read())
        except urllib.error.HTTPError as exc:
            self._reply(exc.code, exc.read() or b"{}")
        except Exception as exc:  # noqa: BLE001
            self._reply(502, json.dumps({"error": "upstream unreachable", "detail": str(exc)}))

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    logline("listening on %s:%d upstream=%s forward_headers=%s" % (ADDR, PORT, UPSTREAM, ALLOW))
    ThreadingHTTPServer((ADDR, PORT), Handler).serve_forever()
PY

  # ------------------------------------------------------------------ traceq.py
  cat >"$LAB_HOME/bin/traceq.py" <<'PY'
#!/usr/bin/env python3
"""traceq - query the trace backend and render a waterfall, Jaeger-UI style."""

import json
import sys
import urllib.request


def get(base, path):
    with urllib.request.urlopen(base.rstrip("/") + path, timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))


def ms(nanoseconds):
    return nanoseconds / 1000000.0


def list_traces(base):
    traces = get(base, "/api/traces")["traces"]
    if not traces:
        print("no traces stored (0)")
        return 0
    print("%-34s %6s %10s  %s" % ("TRACE ID", "SPANS", "DURATION", "SERVICES"))
    for trace in traces:
        flag = "" if trace["roots"] == 1 else "   <-- %d root spans" % trace["roots"]
        print("%-34s %6d %8.1fms  %s%s"
              % (trace["traceId"], trace["spans"], ms(trace["durationNano"]),
                 ",".join(trace["services"]), flag))
    print("\n%d trace(s)" % len(traces))
    return 0


def show_trace(base, trace_id):
    spans = get(base, "/api/traces/" + trace_id)["spans"]
    if not spans:
        print("trace %s not found" % trace_id)
        return 1
    spans.sort(key=lambda span: span["startTimeUnixNano"])
    origin = spans[0]["startTimeUnixNano"]
    known = {span["spanId"] for span in spans}
    children = {}
    roots = []
    for span in spans:
        parent = span["parentSpanId"]
        if not parent or parent not in known:
            roots.append(span)
        else:
            children.setdefault(parent, []).append(span)

    total = max(span["endTimeUnixNano"] for span in spans) - origin
    print("Trace %s  spans=%d  duration=%.1fms  services=%s"
          % (trace_id, len(spans), ms(total),
             ",".join(sorted({span["service"] for span in spans}))))
    print("")

    def render(span, depth):
        marker = ""
        if depth == 0 and span["parentSpanId"]:
            marker = "  [ORPHAN: parent %s is not in this trace]" % span["parentSpanId"]
        print("%s[%-8s] %-18s %-22s +%7.1fms  %6.1fms%s"
              % ("  " * depth, span["kind"], span["service"], span["name"],
                 ms(span["startTimeUnixNano"] - origin),
                 ms(span["endTimeUnixNano"] - span["startTimeUnixNano"]), marker))
        for child in sorted(children.get(span["spanId"], []), key=lambda s: s["startTimeUnixNano"]):
            render(child, depth + 1)

    for root in roots:
        render(root, 0)
    if len(roots) > 1:
        print("\n%d root spans in one trace id: the causal chain is not intact." % len(roots))
    return 0


if __name__ == "__main__":
    BASE = sys.argv[1]
    COMMAND = sys.argv[2] if len(sys.argv) > 2 else "list"
    if COMMAND == "list":
        sys.exit(list_traces(BASE))
    if COMMAND == "last":
        found = get(BASE, "/api/traces")["traces"]
        if not found:
            print("no traces stored (0)")
            sys.exit(1)
        sys.exit(show_trace(BASE, found[-1]["traceId"]))
    if COMMAND == "show":
        sys.exit(show_trace(BASE, sys.argv[3]))
    print("usage: traceq.py <base_url> list|last|show <traceId>")
    sys.exit(2)
PY

  # ------------------------------------------------------------------ verify.py
  cat >"$LAB_HOME/bin/verify.py" <<'PY'
#!/usr/bin/env python3
"""Grader. Sends fresh traffic, reads only the spans produced by that traffic,
and checks the five properties a usable distributed trace must have."""

import json
import sys
import time
import urllib.request

FRONTEND, COLLECTOR = sys.argv[1], sys.argv[2].rstrip("/")
REQUESTS = int(sys.argv[3]) if len(sys.argv) > 3 else 5

OK = "\033[32mPASS\033[0m" if sys.stdout.isatty() else "PASS"
NO = "\033[31mFAIL\033[0m" if sys.stdout.isatty() else "FAIL"


def get(url):
    with urllib.request.urlopen(url, timeout=6) as response:
        return json.loads(response.read().decode("utf-8"))


def check(passed, title, detail=""):
    print(" [%s] %s%s" % (OK if passed else NO, title, ("  -- " + detail) if detail else ""))
    return bool(passed)


baseline = get(COLLECTOR + "/api/spans?since=0")["count"]
http_ok = 0
for _ in range(REQUESTS):
    try:
        with urllib.request.urlopen(FRONTEND, timeout=8) as response:
            response.read()
            http_ok += 1 if response.status == 200 else 0
    except Exception as exc:  # noqa: BLE001
        print("request failed: %s" % exc)
    time.sleep(0.05)

time.sleep(0.5)
spans = get(COLLECTOR + "/api/spans?since=%d" % baseline)["spans"]

print("\nGrading %d request(s) through %s" % (REQUESTS, FRONTEND))
print("Spans received by the backend for this run: %d (expected %d)\n" % (len(spans), REQUESTS * 4))

results = []
results.append(check(http_ok == REQUESTS, "the application itself answers HTTP 200",
                     "%d/%d" % (http_ok, REQUESTS)))

by_service = {}
for span in spans:
    by_service.setdefault(span["service"], []).append(span)

results.append(check(len(by_service.get("checkout-frontend", [])) >= REQUESTS * 2,
                     "checkout-frontend spans reach the backend",
                     "%d received" % len(by_service.get("checkout-frontend", []))))
results.append(check(len(by_service.get("payments-api", [])) >= REQUESTS * 2,
                     "payments-api spans reach the backend",
                     "%d received" % len(by_service.get("payments-api", []))))

traces = {}
for span in spans:
    traces.setdefault(span["traceId"], []).append(span)
results.append(check(len(traces) == REQUESTS,
                     "one request produces exactly one trace",
                     "%d trace id(s) for %d request(s)" % (len(traces), REQUESTS)))

complete = 0
for trace_id, group in traces.items():
    ids = {span["spanId"] for span in group}
    roots = [span for span in group if not span["parentSpanId"]]
    services = {span["service"] for span in group}
    linked = all(span["parentSpanId"] in ids for span in group if span["parentSpanId"])
    server = [s for s in group if s["service"] == "payments-api" and s["kind"] == "SERVER"]
    parented = bool(server) and all(
        any(c["spanId"] == s["parentSpanId"] and c["service"] == "checkout-frontend" and c["kind"] == "CLIENT"
            for c in group)
        for s in server
    )
    if len(group) >= 4 and len(roots) == 1 and services == {"checkout-frontend", "payments-api"} and linked and parented:
        complete += 1
results.append(check(complete == REQUESTS,
                     "every trace is a single connected tree across both services",
                     "%d/%d complete" % (complete, len(traces) or REQUESTS)))

print("")
if all(results):
    print("LAB SOLVED - the trace path is healthy end to end.")
    example = sorted(traces.keys())[0] if traces else ""
    if example:
        print("Inspect it:  %s trace %s" % (sys.argv[0].rsplit('/', 1)[-1], example))
    sys.exit(0)

print("Not solved yet. Read the failing lines above as a ladder: telemetry that")
print("never leaves the process, telemetry that never arrives, and telemetry that")
print("arrives without its context are three different faults with three different fixes.")
sys.exit(1)
PY

  # ------------------------------------------------------------- configuration
  cat >"$LAB_HOME/etc/collector.env" <<EOF
# minicollector - the trace backend (stands in for Jaeger / Tempo / OTel Collector)
OTLP_LISTEN_ADDR=127.0.0.1
OTLP_LISTEN_PORT=$COLLECTOR_PORT
LAB_STORE=$LAB_HOME/data/spans.jsonl
EOF

  cat >"$LAB_HOME/etc/checkout-frontend.env" <<EOF
# checkout-frontend - entry point of the request path
LAB_ROLE=frontend
LAB_LISTEN_ADDR=127.0.0.1
LAB_LISTEN_PORT=$FRONTEND_PORT
LAB_DOWNSTREAM_URL=http://127.0.0.1:$PROXY_PORT/pay

OTEL_SERVICE_NAME=checkout-frontend
OTEL_SERVICE_INSTANCE_ID=frontend-0
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:$COLLECTOR_PORT
OTEL_EXPORTER_OTLP_TRACES_PATH=/v1/traces
OTEL_EXPORTER_OTLP_TIMEOUT=2
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=1.0
EOF

  cat >"$LAB_HOME/etc/payments-api.env" <<EOF
# payments-api - downstream service behind the gateway
LAB_ROLE=payments
LAB_LISTEN_ADDR=127.0.0.1
LAB_LISTEN_PORT=$PAYMENTS_PORT

OTEL_SERVICE_NAME=payments-api
OTEL_SERVICE_INSTANCE_ID=payments-0
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:$COLLECTOR_PORT
OTEL_EXPORTER_OTLP_TRACES_PATH=/v1/traces
OTEL_EXPORTER_OTLP_TIMEOUT=2
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=1.0
EOF

  cat >"$LAB_HOME/etc/edge-proxy.env" <<EOF
# edge-proxy - API gateway. Request headers NOT in the allowlist are dropped.
PROXY_LISTEN_ADDR=127.0.0.1
PROXY_LISTEN_PORT=$PROXY_PORT
PROXY_UPSTREAM=http://127.0.0.1:$PAYMENTS_PORT
PROXY_FORWARD_HEADERS=host,content-type,accept,user-agent,x-request-id,traceparent,tracestate
EOF
}

# ------------------------------------------------------------------------------
# Process control
# ------------------------------------------------------------------------------
pidfile()    { printf '%s/run/%s.pid' "$LAB_HOME" "$1"; }
logfile()    { printf '%s/log/%s.log' "$LAB_HOME" "$1"; }

is_running() {
  local pid_path; pid_path="$(pidfile "$1")"
  [ -f "$pid_path" ] || return 1
  local pid; pid="$(cat "$pid_path" 2>/dev/null || echo '')"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_one() {
  local name="$1" script="$2" conf="$3" port="$4"
  is_running "$name" && return 0
  nohup python3 "$LAB_HOME/bin/$script" "$LAB_HOME/etc/$conf" >>"$(logfile "$name")" 2>&1 &
  echo $! >"$(pidfile "$name")"
  if ! wait_port "$port"; then
    warn "$name did not open 127.0.0.1:$port - last log lines:"
    tail -n 15 "$(logfile "$name")" >&2 || true
    die "startup failed for $name"
  fi
  log "started $name (pid $(cat "$(pidfile "$name")")) on 127.0.0.1:$port"
}

start_all() {
  start_one collector          collector.py "collector.env"          "$COLLECTOR_PORT"
  start_one payments-api       service.py   "payments-api.env"       "$PAYMENTS_PORT"
  start_one edge-proxy         proxy.py     "edge-proxy.env"         "$PROXY_PORT"
  start_one checkout-frontend  service.py   "checkout-frontend.env"  "$FRONTEND_PORT"
}

stop_all() {
  local name pid pid_path
  for name in $SERVICES; do
    pid_path="$(pidfile "$name")"
    [ -f "$pid_path" ] || continue
    pid="$(cat "$pid_path" 2>/dev/null || echo '')"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
      log "stopped $name (pid $pid)"
    fi
    rm -f "$pid_path"
  done
}

restart_all() {
  stop_all
  sleep 0.3
  start_all
  log "configuration reloaded (each service re-read its etc/*.env at startup)"
}

# ------------------------------------------------------------------------------
# Fault injection
# ------------------------------------------------------------------------------
set_conf() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

inject_faults() {
  # FAULT 1 - head sampling turned off in the entry service.
  set_conf "$LAB_HOME/etc/checkout-frontend.env" OTEL_TRACES_SAMPLER_ARG "0.0"
  # FAULT 2 - the gateway allowlist no longer carries the context headers.
  set_conf "$LAB_HOME/etc/edge-proxy.env" PROXY_FORWARD_HEADERS \
    "host,content-type,accept,user-agent,x-request-id"
  # FAULT 3 - the downstream exporter points at the gRPC port with an HTTP exporter.
  set_conf "$LAB_HOME/etc/payments-api.env" OTEL_EXPORTER_OTLP_ENDPOINT \
    "http://127.0.0.1:$COLLECTOR_BAD_PORT"
  log "three independent misconfigurations injected into $LAB_HOME/etc/"
}

# ------------------------------------------------------------------------------
# Student-facing commands
# ------------------------------------------------------------------------------
cmd_load() {
  local count="${1:-5}" i=1
  while [ "$i" -le "$count" ]; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS "http://127.0.0.1:$FRONTEND_PORT/buy" >/dev/null || warn "request $i failed"
    else
      python3 -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:$FRONTEND_PORT/buy', timeout=8).read()" \
        || warn "request $i failed"
    fi
    i=$((i + 1))
  done
  log "sent $count request(s) to http://127.0.0.1:$FRONTEND_PORT/buy"
}

cmd_status() {
  section "PROCESSES"
  local name
  for name in $SERVICES; do
    if is_running "$name"; then
      printf '  %-20s %sup%s   pid %s\n' "$name" "$C_GREEN" "$C_RESET" "$(cat "$(pidfile "$name")")"
    else
      printf '  %-20s %sdown%s\n' "$name" "$C_RED" "$C_RESET"
    fi
  done
  section "LISTENERS (127.0.0.1)"
  local pair
  for pair in "collector:$COLLECTOR_PORT" "edge-proxy:$PROXY_PORT" \
              "checkout-frontend:$FRONTEND_PORT" "payments-api:$PAYMENTS_PORT"; do
    if port_busy "${pair##*:}"; then
      printf '  %-20s %s open\n' "${pair%%:*}" "${pair##*:}"
    else
      printf '  %-20s %s closed\n' "${pair%%:*}" "${pair##*:}"
    fi
  done
  section "SDK SELF-TELEMETRY (/-/stats)"
  for pair in "checkout-frontend:$FRONTEND_PORT" "payments-api:$PAYMENTS_PORT"; do
    python3 - "http://127.0.0.1:${pair##*:}/-/stats" <<'PY' || warn "${pair%%:*} stats unavailable"
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=4) as response:
    stats = json.loads(response.read().decode())
print("  %s" % stats.pop("service"))
for key, value in stats.items():
    print("      %-26s %s" % (key, value if value != "" else "-"))
PY
  done
  section "GATEWAY HEADER POLICY (/-/config)"
  python3 - "http://127.0.0.1:$PROXY_PORT/-/config" <<'PY' || true
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=4) as response:
    conf = json.loads(response.read().decode())
print("  upstream          %s" % conf["upstream"])
print("  forward_headers   %s" % ", ".join(conf["forward_headers"]))
PY
  printf '\n'
}

cmd_logs() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $SELF logs collector|checkout-frontend|payments-api|edge-proxy"
  [ -f "$(logfile "$name")" ] || die "no log for '$name'"
  tail -n "${2:-40}" "$(logfile "$name")"
}

cmd_verify() {
  local rc=0
  python3 "$LAB_HOME/bin/verify.py" "http://127.0.0.1:$FRONTEND_PORT/buy" \
    "http://127.0.0.1:$COLLECTOR_PORT" 5 || rc=$?
  return "$rc"
}

cmd_clean() {
  stop_all
  if [ -d "$LAB_HOME" ]; then
    rm -rf -- "$LAB_HOME"
    log "removed $LAB_HOME"
  fi
  log "lab cleaned. Nothing of it remains on this VM."
}

cmd_solution() {
  awk '/^# ===+ SOLUTION/{flag=1} flag' "$SELF" | sed 's/^#\{1,\} \{0,1\}//'
}

# ------------------------------------------------------------------------------
# Briefing
# ------------------------------------------------------------------------------
briefing() {
  cat <<TXT

$(rule)
${C_BOLD}LPI 701-100 / 704.4 TRACING - BREAK & FIX${C_RESET}
$(rule)

${C_BOLD}THE SCENARIO${C_RESET}
  A change window closed twenty minutes ago. Checkout still works: customers are
  paying, dashboards are green, error rate is zero. But the on-call engineer
  opened the tracing UI to investigate a latency complaint and found nothing at
  all. Not a slow trace. Not a broken trace. No traces.

  Request path:

      curl -> checkout-frontend :$FRONTEND_PORT -> edge-proxy :$PROXY_PORT -> payments-api :$PAYMENTS_PORT
                        \\                                                       /
                         '------------ OTLP/HTTP -> minicollector :$COLLECTOR_PORT ---'

${C_BOLD}THE SYMPTOM YOU WILL SEE${C_RESET}
  1. The application is healthy:
       curl -s http://127.0.0.1:$FRONTEND_PORT/buy
     returns HTTP 200 and a payment result. This is NOT an availability incident.
  2. The trace backend is empty after traffic:
       $SELF load 5
       $SELF traces        ->  "no traces stored (0)"
  3. As you fix things, the symptom will MUTATE rather than disappear. Expect to
     pass through these intermediate states, each of which is a distinct and very
     common production failure:
       - spans from only one of the two services,
       - two separate single-service traces for one single user request,
       - a payments-api span that is a root span instead of a child.

${C_BOLD}WHAT YOU MUST ACHIEVE${C_RESET}
  One user request must produce ONE trace containing FOUR spans spanning BOTH
  services, in this exact causal shape, for 100% of requests:

      [SERVER  ] checkout-frontend  GET /buy          <- single root
        [CLIENT  ] checkout-frontend  POST /pay
          [SERVER  ] payments-api     POST /pay       <- child of the CLIENT span
            [INTERNAL] payments-api   db.query ledger

  Done means this exits 0:
       $SELF verify

${C_BOLD}GROUND RULES${C_RESET}
  - Three independent misconfigurations were injected. All three live in
    $LAB_HOME/etc/*.env
  - The service code under $LAB_HOME/bin/ is CORRECT. Do not edit it. This is a
    configuration outage, the kind that ships through a merged pull request.
  - Configuration is read at startup. After editing, run: $SELF restart

${C_BOLD}YOUR DIAGNOSTIC TOOLKIT${C_RESET}
  $SELF status            processes, listeners, SDK counters, gateway header policy
  $SELF logs <service>    collector | checkout-frontend | payments-api | edge-proxy
  $SELF load [n]          generate traffic
  $SELF traces            what the backend actually holds
  $SELF trace <traceId>   waterfall of one trace (also: trace last)
  $SELF verify            graded checklist, exit 0 when solved
  $SELF clean             destroy the lab

  Drill the propagation layer by hand - inject your own context and watch which
  hop loses it:

    curl -s -H 'traceparent: 00-11111111111111111111111111111111-2222222222222222-01' \\
         http://127.0.0.1:$FRONTEND_PORT/buy | python3 -m json.tool
    curl -s -X POST -H 'traceparent: 00-33333333333333333333333333333333-4444444444444444-01' \\
         http://127.0.0.1:$PROXY_PORT/pay
    curl -s http://127.0.0.1:$PROXY_PORT/-/config
    curl -s http://127.0.0.1:$FRONTEND_PORT/-/stats | python3 -m json.tool
    curl -s http://127.0.0.1:$PAYMENTS_PORT/-/stats | python3 -m json.tool
    ss -lntp | grep -E '1(4318|8080|8081|8082)'

${C_BOLD}THREE QUESTIONS THAT SOLVE THIS FASTER THAN GUESSING${C_RESET}
  a) For each service: were spans STARTED, SAMPLED, and EXPORTED? Those are three
     different counters, and a zero in each one has a different root cause.
  b) Does the exporter report failures? Silence is not success. A span that was
     never sampled leaves no error anywhere - by design.
  c) On the receiving side, does the inbound request still carry `traceparent`?
     Every proxy, mesh sidecar, load balancer and CDN between two services is a
     place where a header can be legally and silently dropped.

  Ports to keep in mind: OTLP/gRPC is 4317, OTLP/HTTP is 4318 (this lab shifts
  them to $COLLECTOR_BAD_PORT / $COLLECTOR_PORT). Posting HTTP/JSON at the gRPC port is one of
  the most frequent first-day OpenTelemetry mistakes.

  Spoiler when you want it: $SELF solution
$(rule)

TXT
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------
need_lab() { [ -d "$LAB_HOME/bin" ] || die "lab not installed. Run: $SELF setup"; }

main() {
  local action="${1:-all}"
  case "$action" in
    all|setup)
      require_tools
      confirm_disposable
      [ -d "$LAB_HOME" ] && stop_all || true
      preflight_ports
      write_tree
      log "lab installed in $LAB_HOME"
      inject_faults
      start_all
      cmd_load 3 >/dev/null 2>&1 || true
      briefing
      ;;
    start)    need_lab; start_all ;;
    stop)     need_lab; stop_all ;;
    restart)  need_lab; restart_all ;;
    status)   need_lab; cmd_status ;;
    logs)     need_lab; shift; cmd_logs "$@" ;;
    load)     need_lab; shift; cmd_load "${1:-5}" ;;
    traces)   need_lab; python3 "$LAB_HOME/bin/traceq.py" "http://127.0.0.1:$COLLECTOR_PORT" list ;;
    trace)    need_lab; shift
              if [ "${1:-last}" = "last" ]; then
                python3 "$LAB_HOME/bin/traceq.py" "http://127.0.0.1:$COLLECTOR_PORT" last
              else
                python3 "$LAB_HOME/bin/traceq.py" "http://127.0.0.1:$COLLECTOR_PORT" show "$1"
              fi ;;
    verify)   need_lab; cmd_verify ;;
    break)    need_lab; inject_faults; restart_all; briefing ;;
    solution) cmd_solution ;;
    clean)    cmd_clean ;;
    help|-h|--help)
      sed -n '2,60p' "$SELF" | sed 's/^#\{1,\} \{0,1\}//'
      ;;
    *) die "unknown command '$action'. Try: $SELF help" ;;
  esac
}

main "$@"
exit $?

# ==============================================================================
# ============================ SOLUTION (SPOILER) ==============================
# ==============================================================================
#
# Do not read this until `verify` has beaten you at least twice. Print it with:
#     ./704.4-tracing-breakfix.sh solution
#
# ------------------------------------------------------------------------------
# STEP 0 - Establish what kind of incident this is
# ------------------------------------------------------------------------------
#     curl -s http://127.0.0.1:18081/buy | python3 -m json.tool
#     ./704.4-tracing-breakfix.sh load 5
#     ./704.4-tracing-breakfix.sh traces        # -> no traces stored (0)
#
# The application returns 200. Availability is fine. What is down is the
# OBSERVABILITY PIPELINE, and it is down in three places at once. Work the
# pipeline in the order data flows through it:
#     create span -> sample -> export -> receive -> assemble by context.
#
# ------------------------------------------------------------------------------
# STEP 1 - Fault 3: the exporter is pointed at the wrong OTLP port
# ------------------------------------------------------------------------------
# Symptom: payments-api spans never reach the backend, and the service log is
# shouting about it. This is the loudest fault, so it is the cheapest one to fix.
#
#     ./704.4-tracing-breakfix.sh logs payments-api 20
#       -> OTLP EXPORT FAILED endpoint=http://127.0.0.1:14317/v1/traces
#          error=URLError: <urlopen error [Errno 111] Connection refused>
#     curl -s http://127.0.0.1:18082/-/stats | python3 -m json.tool
#       -> "spans_sampled": N, "spans_exported_ok": 0, "span_export_failures": N
#
# Read that pair of counters carefully: spans ARE being created and sampled, the
# transport is what fails. Confirm nothing listens on the configured port:
#     ss -lntp | grep -E '1431[78]'
#
# Root cause: an HTTP/JSON exporter aimed at the gRPC port. In the real world
# that is OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317 with
# OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf. The two OTLP transports do not share
# a port: 4317 is gRPC, 4318 is HTTP.
#     https://opentelemetry.io/docs/specs/otlp/
#
# Fix:
#     sed -i 's|^OTEL_EXPORTER_OTLP_ENDPOINT=.*|OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318|' \
#         ~/lpi-704.4-tracing-lab/etc/payments-api.env
#     ./704.4-tracing-breakfix.sh restart
#     ./704.4-tracing-breakfix.sh load 3
#     ./704.4-tracing-breakfix.sh traces
#
# New state: traces appear, but every one of them contains ONLY payments-api
# spans, and each has payments-api as the root. The frontend is still invisible.
#
# ------------------------------------------------------------------------------
# STEP 2 - Fault 1: head sampling set to zero in the entry service
# ------------------------------------------------------------------------------
# Symptom: checkout-frontend never appears anywhere, and its log is completely
# silent - no export errors at all. Silence is the diagnosis: an exporter that is
# failing complains; a sampler that decided NOT to record produces nothing to
# complain about.
#
#     curl -s http://127.0.0.1:18081/-/stats | python3 -m json.tool
#       -> "sampler": "parentbased_traceidratio(ratio=0.000)"
#          "spans_started": N, "spans_sampled": 0, "spans_dropped_by_sampler": N
#          "span_export_failures": 0
#     grep SAMPLER ~/lpi-704.4-tracing-lab/etc/checkout-frontend.env
#
# Root cause: OTEL_TRACES_SAMPLER_ARG=0.0. This is head-based sampling: the
# decision is taken when the root span starts, it is recorded in the `sampled`
# bit of the traceparent flags, and every downstream service running a
# parentbased_* sampler obeys it. One wrong ratio at the edge blanks out the
# whole distributed trace, not just one service's spans - which is exactly why a
# sampling ratio belongs in reviewed configuration, not in an ad-hoc override.
#     https://opentelemetry.io/docs/concepts/sampling/
#
# Fix (1.0 = keep everything; in production you would use a value your backend
# can afford, or move to tail sampling in the Collector):
#     sed -i 's|^OTEL_TRACES_SAMPLER_ARG=.*|OTEL_TRACES_SAMPLER_ARG=1.0|' \
#         ~/lpi-704.4-tracing-lab/etc/checkout-frontend.env
#     ./704.4-tracing-breakfix.sh restart
#     ./704.4-tracing-breakfix.sh load 3
#     ./704.4-tracing-breakfix.sh traces
#
# New state: both services now produce spans, but ONE user request yields TWO
# trace ids - one holding the two frontend spans, one holding the two payments
# spans, each with its own root. The data is there; the causality is not.
#
# ------------------------------------------------------------------------------
# STEP 3 - Fault 2: the gateway strips the context headers
# ------------------------------------------------------------------------------
# Symptom: broken/orphan traces. payments-api logs the smoking gun on every call:
#
#     ./704.4-tracing-breakfix.sh logs payments-api 20
#       -> no usable traceparent on inbound request: starting a NEW root trace (raw=None)
#     ./704.4-tracing-breakfix.sh logs edge-proxy 10
#       -> POST /pay -> ... forwarded=['content-type', 'x-request-id', ...]
#                       stripped=['traceparent', 'tracestate']
#     curl -s http://127.0.0.1:18080/-/config
#
# Prove it from the outside, bypassing the gateway to isolate the hop:
#     curl -s -X POST -H 'traceparent: 00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
#          http://127.0.0.1:18082/pay      # direct  -> "had_parent": true
#     curl -s -X POST -H 'traceparent: 00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
#          http://127.0.0.1:18080/pay      # gateway -> "had_parent": false
#
# Root cause: the gateway forwards only an explicit header allowlist and
# `traceparent` / `tracestate` were dropped from it. Trace context is carried in
# ordinary HTTP headers (W3C Trace Context, section 3), so any hop that filters
# headers can sever a trace without producing a single error, a single dropped
# request, or a single failed health check. The same bug appears as: an nginx
# `proxy_set_header` block that does not pass the header, `underscores_in_headers
# off`, an AWS ALB/CloudFront policy, a Kong/Envoy filter, or an application
# HTTP client built without the propagator installed.
#     https://www.w3.org/TR/trace-context/
#
# Fix:
#     sed -i 's|^PROXY_FORWARD_HEADERS=.*|PROXY_FORWARD_HEADERS=host,content-type,accept,user-agent,x-request-id,traceparent,tracestate|' \
#         ~/lpi-704.4-tracing-lab/etc/edge-proxy.env
#     ./704.4-tracing-breakfix.sh restart
#
# ------------------------------------------------------------------------------
# STEP 4 - Verify the end state, and read the trace you repaired
# ------------------------------------------------------------------------------
#     ./704.4-tracing-breakfix.sh verify         # must exit 0, five PASS lines
#     ./704.4-tracing-breakfix.sh traces
#     ./704.4-tracing-breakfix.sh trace last
#
# Expected waterfall - one trace id, one root, four spans, two services:
#
#     Trace 9f2c...  spans=4  duration=41.2ms  services=checkout-frontend,payments-api
#     [SERVER  ] checkout-frontend  GET /buy            +   0.0ms   41.2ms
#       [CLIENT  ] checkout-frontend  POST /pay         +   1.1ms   39.0ms
#         [SERVER  ] payments-api     POST /pay         +   3.4ms   33.0ms
#           [INTERNAL] payments-api   db.query ledger   +   5.2ms   14.7ms
#
# The CLIENT/SERVER pair around one network hop is the point of the whole
# exercise: the difference between those two durations is the time the request
# spent in the network and in the gateway, and you can only measure it when the
# context survives the hop.
#
#     ./704.4-tracing-breakfix.sh clean          # remove the lab
#
# ------------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM AND INTO PRODUCTION
# ------------------------------------------------------------------------------
#  * A trace is not a log stream. It is a causal tree assembled from a trace id
#    plus parent-child span ids, propagated in-band over the request itself.
#  * Three distinct silent failure modes, each with a different signature:
#      not created/sampled -> spans_dropped_by_sampler > 0, no errors anywhere
#      not exported        -> export failures in the producer's log, backend empty
#      not correlated      -> data present, but multiple roots / orphan spans
#  * Head sampling is decided once, at the edge, and is binding for the whole
#    trace via the traceparent sampled flag. Mixed ratios across services produce
#    permanently incomplete traces.
#  * Every hop is a chance to lose the context. Gateways, meshes, message queues,
#    cron-triggered jobs and thread pools all need explicit propagation.
#  * Instrument the instrumentation. Export SDK and Collector self-telemetry
#    (otelcol_receiver_accepted_spans, otelcol_exporter_send_failed_spans) and
#    alert on it; otherwise a broken pipeline looks exactly like a quiet system.
#
# EXTRA CREDIT (not injected - break them yourself)
#  1. Set OTEL_TRACES_SAMPLER_ARG=0.5 on the frontend only, send 20 requests, and
#     confirm you get ~10 COMPLETE traces, never 20 half-traces. That is what
#     parentbased_* buys you.
#  2. Set OTEL_TRACES_SAMPLER=always_on on payments-api while the frontend stays
#     at 0.0, and observe the orphan-root spans that a non-parent-based sampler
#     creates downstream.
#  3. Corrupt the propagated context by hand (traceparent with a 31-hex trace id,
#     or an all-zero span id) and watch the receiver correctly refuse it and start
#     a new root - W3C Trace Context requires exactly that.
#  4. Re-point both services at a real backend and confirm the payloads are
#     genuinely OTLP: docker run --rm -p 4318:4318 -p 16686:16686 \
#     jaegertracing/all-in-one, then set OTEL_EXPORTER_OTLP_ENDPOINT=
#     http://127.0.0.1:4318 in both etc/*.env and open the Jaeger UI on :16686.
# ==============================================================================