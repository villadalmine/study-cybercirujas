# MCP Hosts, Clients and Servers

**Certification:** Model Context Protocol Associate (MCPA) — exam version 2026-07-28
**Topic:** 2.2 — MCP Hosts, Clients and Servers
**Exam weight:** 4.67
**Reference protocol revision used throughout:** `2025-06-18`

---

## 1. The architectural problem this topic solves

Before MCP, every integration between an LLM application and an external system was a bespoke adapter. If you operated `H` agent surfaces (a desktop assistant, an IDE plugin, a CI bot, an on-call triage agent) and `M` backing systems (Prometheus, Jira, S3, a runbook repository, a ticketing API), you owned `H × M` adapters. Each one re-implemented authentication, schema description, error mapping, pagination, and rate limiting. Each one had its own blast radius when it broke.

MCP collapses this to `H + M` by standardising the wire contract between the *application that hosts the model* and the *process that exposes a capability*. That is the economic argument, and it is the one most integration protocols make.

The architectural argument is more interesting and is what the exam actually tests: **MCP does not merely standardise a transport, it standardises a trust boundary.** The protocol assigns three distinct roles with three distinct security postures, and it deliberately prevents the most dangerous topology — a capability provider that can read the entire conversation and act on it unsupervised.

Consider the production failure this prevents. An engineer connects a third-party MCP server that summarises Grafana dashboards. In a naive plugin architecture, that plugin would receive the full conversation transcript — including the contents of a `kubeconfig` the user pasted three turns earlier, and the incident channel excerpt with a customer name in it. Under MCP, the server sees only the arguments of the tool call the host chose to forward, and the host is the component that decided to forward them. The server has no channel to the conversation at all.

This is why the three-role decomposition is not bureaucratic. It is the mechanism by which an operator can reason about what a given server can and cannot observe.

---

## 2. The three roles, precisely

### 2.1 Host

The **host** is the LLM application itself: the process the human interacts with, which owns the model connection and the conversation state. Claude Desktop, Claude Code, an IDE extension, or your own agent runtime built on an LLM SDK are all hosts.

The host is the **policy enforcement point**. Its responsibilities:

| Responsibility | What it means operationally |
|---|---|
| Client lifecycle | Spawns, supervises and tears down one client per configured server |
| Consent and authorisation | Decides which tool invocations require human approval and presents them |
| Context aggregation | Merges tools, resources and prompts from many servers into one model-visible surface |
| Namespacing | Disambiguates colliding names across servers (`prom-mcp:query_range` vs `mimir-mcp:query_range`) |
| Security boundary | Enforces that server A cannot observe server B's data or the full conversation |
| Sampling gateway | Owns the model credentials; a server that wants a completion must ask the host |
| Context budget | Decides which of the N available tools are actually put in the model's context |

That last row is the one platform teams under-estimate. Tool definitions are tokens. Thirty servers exposing twelve tools each is 360 JSON Schemas in the system prompt on every single turn. Host-side tool filtering is a cost-control and accuracy control, not a nicety.

### 2.2 Client

The **client** is a protocol connector living *inside* the host process. It is not a user-facing component and it is not separately deployable. The defining invariant:

> **One client maintains exactly one stateful session with exactly one server. The relationship is 1:1 and the session is isolated from every other session in the host.**

A host with five configured servers instantiates five clients. There is no such thing as a client multiplexing two servers — if you find yourself writing one, you have written a *gateway*, which is a different thing (see §9.4).

The client's job is narrow and mechanical: JSON-RPC framing, protocol version negotiation, capability negotiation, request/response correlation by `id`, notification dispatch, progress and cancellation handling, and transport management. It is deliberately dumb about semantics. It does not decide whether a tool call is safe — that is the host.

### 2.3 Server

The **server** is a separate program that exposes capabilities. It may be:

- a **local** process the host spawns as a subprocess, speaking over stdio;
- a **remote** service reachable over HTTP, shared across many hosts and users.

A server is focused. The reference pattern is one server per bounded domain — a Prometheus server, a Git server, a filesystem server — rather than one "enterprise MCP server" exposing 200 tools. Focus is what makes the capability list legible to the model and the permission grant legible to the human.

Critically, the server **cannot see the conversation**. It receives tool arguments, resource URIs and prompt arguments. If it needs model reasoning, it must request it via `sampling/createMessage`, and the host may refuse.

### 2.4 The topology in one diagram

```
┌─────────────────────────── HOST PROCESS ───────────────────────────┐
│                                                                    │
│   conversation state · model credentials · consent UI · policy     │
│                                                                    │
│   ┌──────────┐      ┌──────────┐      ┌──────────┐                 │
│   │ Client A │      │ Client B │      │ Client C │   (1:1, isolated)│
│   └────┬─────┘      └────┬─────┘      └────┬─────┘                 │
└────────┼─────────────────┼─────────────────┼───────────────────────┘
         │ stdio           │ Streamable HTTP │ Streamable HTTP
         │ (subprocess)    │ (in-cluster)    │ (third party, OAuth)
   ┌─────▼──────┐    ┌─────▼──────┐    ┌─────▼──────┐
   │ fs-runbooks│    │  prom-mcp  │    │ vendor-mcp │
   │  (server)  │    │  (server)  │    │  (server)  │
   └────────────┘    └─────┬──────┘    └────────────┘
                           │
                    ┌──────▼───────┐
                    │  Prometheus  │   ← the server's own upstream,
                    └──────────────┘     invisible to MCP
```

Note what is *absent*: there is no edge from `vendor-mcp` to the conversation, and no edge between servers. Both absences are load-bearing.

---

## 3. Protocol layering

MCP is two layers, and separating them is how you debug it.

| Layer | Concern | Failure signature |
|---|---|---|
| **Data layer** | JSON-RPC 2.0 messages, lifecycle, capabilities, tools/resources/prompts/sampling/roots/elicitation | `-32601 Method not found`, capability missing from `initialize` result, schema validation failure |
| **Transport layer** | How bytes move: stdio framing or Streamable HTTP + SSE, plus auth and session identity | Process exits immediately, HTTP 404 on session id, SSE stream closes at 60 s, TLS failure |

Every message is one of exactly three JSON-RPC shapes:

**Request** — has an `id`, expects a response:

```json
{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "query_instant", "arguments": {"expr": "up{job=\"kubelet\"}"}}}
```

**Response** — correlates by `id`, carries `result` **or** `error`, never both:

```json
{"jsonrpc": "2.0", "id": 7, "result": {"content": [{"type": "text", "text": "12 series returned"}], "isError": false}}
```

**Notification** — no `id`, no response, fire-and-forget:

```json
{"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}
```

Both directions can send all three. The server issuing `sampling/createMessage` is a *server-originated request* travelling to the client — this bidirectionality is why stdio needs two pipes and why Streamable HTTP needs the GET/SSE channel.

> **Exam trap:** the `2025-03-26` revision permitted JSON-RPC batching (an array of messages). `2025-06-18` **removed** it. Do not implement or expect batch arrays against a modern server.

---

## 4. Lifecycle: the three phases

### 4.1 Phase 1 — Initialization

The client MUST send `initialize` as the first request. It MUST NOT send any other request (except `ping`) until it has received the response and sent `notifications/initialized`.

A complete, real wire trace — request, response, then notification — shown as raw framing:

```
--> {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{}},"clientInfo":{"name":"acme-agent-runtime","title":"Acme Agent Runtime","version":"4.2.0"}}}

<-- {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-06-18","capabilities":{"logging":{},"completions":{},"prompts":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"tools":{"listChanged":true}},"serverInfo":{"name":"prom-mcp","title":"Prometheus MCP","version":"1.4.0"},"instructions":"Query Prometheus. Always prefer query_range over repeated query_instant when the user asks about a time window."}}

--> {"jsonrpc":"2.0","method":"notifications/initialized"}
```

Three things are negotiated in that exchange:

**Protocol version.** The client offers the latest revision it supports. If the server supports it, it echoes it. If not, the server responds with the latest version *it* supports. The client then either proceeds — if it supports what the server offered — or **disconnects**. There is no partial-compatibility mode. Versions are date strings, not semver.

**Capabilities.** Each side declares what it can do. A capability that is not declared MUST NOT be used. If the server's result contains no `"tools"` key, calling `tools/list` is a protocol error, not an empty list.

**Implementation identity.** `clientInfo` / `serverInfo` carry `name`, `version` and optionally `title`. These are for logs and UI, never for authorisation decisions — they are self-asserted and trivially spoofed.

The `instructions` field is under-used and worth calling out: it is free-text guidance the host may inject into the system prompt. It is how a server tells the model *how* to use its tools, without burning schema space.

### 4.2 Phase 2 — Operation

Normal request/response and notification traffic, constrained by the negotiated capabilities. Two utilities matter to operators:

**`ping`** — either side may send it; the receiver MUST respond promptly with an empty result. This is the protocol-level liveness check.

```
--> {"jsonrpc":"2.0","id":"hb-1841","method":"ping"}
<-- {"jsonrpc":"2.0","id":"hb-1841","result":{}}
```

**Cancellation and progress** — a long-running tool reports progress via `notifications/progress` keyed by a `progressToken` the caller placed in `params._meta`; the caller aborts via `notifications/cancelled`. If your server does not honour cancellation, a user pressing Escape leaves a 90-second Prometheus range query running in your pod. That is a real capacity leak on a busy incident.

### 4.3 Phase 3 — Shutdown

There is no `shutdown` message in the data layer. Termination is a **transport-layer** concern:

- **stdio:** the client closes the server's stdin, waits for exit, then `SIGTERM`, then `SIGKILL`. A server that ignores stdin EOF becomes an orphan.
- **Streamable HTTP:** the client issues `HTTP DELETE` to the MCP endpoint with the `Mcp-Session-Id` header. A server that does not implement DELETE returns `405`, which is allowed — sessions then expire by TTL.

---

## 5. Capability negotiation reference

| Declared by | Capability | Unlocks | Sub-flags |
|---|---|---|---|
| Server | `tools` | `tools/list`, `tools/call` | `listChanged` |
| Server | `resources` | `resources/list`, `resources/read`, `resources/templates/list` | `subscribe`, `listChanged` |
| Server | `prompts` | `prompts/list`, `prompts/get` | `listChanged` |
| Server | `logging` | `notifications/message`, `logging/setLevel` | — |
| Server | `completions` | `completion/complete` (argument autocomplete) | — |
| Client | `roots` | server may call `roots/list` | `listChanged` |
| Client | `sampling` | server may call `sampling/createMessage` | — |
| Client | `elicitation` | server may call `elicitation/create` | — |

### 5.1 Who controls what — the trust triad

This table is the single most examinable thing in the topic.

| Primitive | Controlled by | Meaning | Typical surface |
|---|---|---|---|
| **Tools** | **Model** | The model decides to invoke it, based on the schema | Function calling, gated by host approval |
| **Resources** | **Application (host)** | The host decides what context to attach | `@`-mentions, file pickers, auto-attached context |
| **Prompts** | **User** | The human explicitly selects it | Slash commands, template menus |

Read it as an escalating supervision requirement in the opposite direction: prompts are safest (a human chose them), resources are next (the application chose them), tools are the risk surface (a probabilistic model chose them, possibly influenced by text it just read from an untrusted resource). Every serious MCP security control exists because of that last clause.

The client-side primitives invert the direction:

| Primitive | Direction | Purpose | Operational hazard |
|---|---|---|---|
| **Roots** | Client → tells server | URI boundaries the server may operate within (typically `file://` paths) | Advisory, not enforced by the OS — a malicious server ignores them |
| **Sampling** | Server → asks client | "Run this completion for me" | Server-induced token spend on the user's account; requires human-in-the-loop |
| **Elicitation** | Server → asks client | "Ask the user for this structured input" | Phishing surface — servers MUST NOT request secrets here |

Elicitation schemas are deliberately restricted to **flat objects of primitive types** (string, number, boolean, enum) so that a host can render a trustworthy form without executing arbitrary schema logic.

---

## 6. Transports: the operational fork in the road

### 6.1 stdio

The host spawns the server as a child process. Messages are newline-delimited JSON on stdin/stdout. **stdout is the protocol channel and nothing else may be written to it.** Logging goes to stderr.

This single rule causes more first-day failures than everything else combined. A Python server whose dependency prints a deprecation warning to stdout, a Node server printing a startup banner, a shell wrapper that `echo`es — all of them corrupt the stream and the host reports "server failed to start" with no useful detail.

### 6.2 Streamable HTTP

A single HTTP endpoint (conventionally `/mcp`) handling three methods:

| Method | Purpose | Response |
|---|---|---|
| `POST` | Client → server messages | `202 Accepted` (notifications only), or `application/json` (single response), or `text/event-stream` (a stream that may carry server requests before the final response) |
| `GET` | Open a server → client SSE channel for unsolicited messages | `text/event-stream`, or `405` if unsupported |
| `DELETE` | Terminate the session | `204`, or `405` if unsupported |

Required headers after initialization:

- `MCP-Protocol-Version: 2025-06-18` on every HTTP request (added in `2025-06-18`; absence means the server assumes `2025-03-26`)
- `Mcp-Session-Id: <opaque>` if the server returned one on `initialize`
- `Accept: application/json, text/event-stream` on POST
- `Origin` must be validated server-side to prevent DNS-rebinding attacks against localhost servers

Resumability: SSE events carry an `id`; a client reconnecting sends `Last-Event-ID` and the server replays from that point on that stream only.

> The `2024-11-05` "HTTP+SSE" transport used two endpoints (`GET /sse` plus `POST /messages`). It was replaced by Streamable HTTP in `2025-03-26`. You will still meet it in the wild; recognise it by the separate endpoints and the lack of `Mcp-Session-Id`.

### 6.3 Trade-off table

| Dimension | stdio | Streamable HTTP |
|---|---|---|
| Deployment unit | Subprocess of the host | Independent service |
| Multi-tenancy | Impossible — one process per host session | Native |
| Authentication | Inherited from the user's OS session; secrets via env vars | OAuth 2.1 Resource Server; per-user tokens |
| Latency | Sub-millisecond, no network | Network RTT + TLS |
| Horizontal scaling | N/A (scales with hosts) | HPA, but see session affinity below |
| Observability | stderr only; no scrape target | Standard `/metrics`, tracing, access logs |
| Upgrade path | User must update their local install | Deploy once, all hosts get it |
| Blast radius of a bad server | User's laptop, user's credentials | Shared service, shared credentials — worse |
| Filesystem/local device access | Yes, natural | No, and should not be |
| Correct default for | Local dev tooling, filesystem, git, editor state | Platform capabilities, SaaS connectors, anything shared |
| Session state | Implicit in the process | Explicit `Mcp-Session-Id`, must be externalised to scale |

**The decision rule:** if the capability is intrinsically local to the operator's machine, use stdio. Everything else on the platform goes over Streamable HTTP, because only then can you patch it, meter it, audit it and rotate its credentials without touching a hundred laptops.

---

## 7. Authorization for remote servers

Local stdio servers inherit the user's session and are out of scope. Remote servers follow OAuth 2.1 with the MCP server acting as a **Resource Server**, never as an Authorization Server.

The discovery chain:

1. Unauthenticated request → `401` with `WWW-Authenticate: Bearer resource_metadata="https://mcp.example.internal/.well-known/oauth-protected-resource"`
2. Client fetches Protected Resource Metadata (RFC 9728) → learns the `authorization_servers` list and the canonical `resource` identifier
3. Client fetches Authorization Server Metadata (RFC 8414)
4. Client registers dynamically if needed (RFC 7591)
5. Authorization Code flow **with PKCE** (mandatory), including the `resource` parameter (RFC 8707) bound to the MCP server's canonical URI
6. Client presents the access token as `Authorization: Bearer …`

Two anti-patterns the spec names explicitly, both of which show up in exams and in real incidents:

**Token passthrough.** The MCP server MUST validate that the token's audience is *itself*. Accepting a token minted for a different resource and forwarding it upstream turns the server into a confused deputy: any client holding any token for your IdP gets to drive your server's upstream privileges. RFC 8707 `resource` indicators exist to make the audience check possible.

**Static client id with an open redirect.** A server that proxies a third-party IdP using one shared client id, combined with a permissive `redirect_uri`, lets an attacker harvest authorization codes. Bind redirects exactly, always.

---

## 8. A complete server implementation

A production-shaped Prometheus MCP server, with tool annotations, structured output, correct error semantics and both transports.

```python
"""Prometheus MCP server.

Exposes read-only PromQL access as MCP tools, the alert catalogue as a
resource, and an incident-triage prompt. Transport is selected at startup so
the same binary serves laptops over stdio and the cluster over HTTP.
"""

from __future__ import annotations

import logging
import os
import sys
from typing import Annotated, Any, Literal

import httpx
from mcp.server.fastmcp import Context, FastMCP
from pydantic import BaseModel, Field

# stdout belongs to the protocol. Every byte of logging goes to stderr.
logging.basicConfig(
    stream=sys.stderr,
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("prom-mcp")

PROMETHEUS_URL = os.environ["PROMETHEUS_URL"]
QUERY_TIMEOUT = float(os.environ.get("QUERY_TIMEOUT_SECONDS", "30"))
MAX_SERIES = int(os.environ.get("MAX_SERIES", "10000"))

mcp = FastMCP(
    name="prom-mcp",
    instructions=(
        "Query Prometheus for metrics and alerts. Prefer query_range over "
        "repeated query_instant when the user asks about a time window. "
        "Series are capped; narrow the selector rather than raising the cap."
    ),
)

_http = httpx.AsyncClient(timeout=QUERY_TIMEOUT, verify=True)


class Sample(BaseModel):
    """One metric series with its most recent value."""

    metric: dict[str, str] = Field(description="Label set of the series")
    value: float = Field(description="Sample value at the evaluation instant")
    timestamp: float = Field(description="Unix timestamp of the sample")


class InstantResult(BaseModel):
    """Structured output of an instant query."""

    expr: str
    series_count: int
    truncated: bool
    samples: list[Sample]


@mcp.tool(
    annotations={
        "title": "Instant PromQL query",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": True,
    }
)
async def query_instant(
    expr: Annotated[str, Field(description="PromQL expression, e.g. up{job='kubelet'}")],
    ctx: Context,
) -> InstantResult:
    """Evaluate a PromQL expression at the current instant."""
    await ctx.info(f"evaluating instant query: {expr}")

    response = await _http.get(
        f"{PROMETHEUS_URL}/api/v1/query", params={"query": expr}
    )
    response.raise_for_status()
    body: dict[str, Any] = response.json()

    if body.get("status") != "success":
        # A domain failure, not a protocol failure: raising here is turned into
        # a tool result with isError=true, which the model can read and retry.
        raise ValueError(f"prometheus rejected the query: {body.get('error')}")

    raw = body["data"]["result"]
    truncated = len(raw) > MAX_SERIES

    samples = [
        Sample(
            metric=item["metric"],
            value=float(item["value"][1]),
            timestamp=float(item["value"][0]),
        )
        for item in raw[:MAX_SERIES]
    ]

    return InstantResult(
        expr=expr,
        series_count=len(raw),
        truncated=truncated,
        samples=samples,
    )


@mcp.tool(
    annotations={
        "title": "Silence an alert",
        "readOnlyHint": False,
        "destructiveHint": True,
        "idempotentHint": False,
        "openWorldHint": True,
    }
)
async def silence_alert(
    alertname: Annotated[str, Field(description="Exact alertname label to silence")],
    duration: Annotated[
        Literal["15m", "1h", "4h", "24h"],
        Field(description="How long the silence lasts"),
    ],
    ctx: Context,
) -> str:
    """Create an Alertmanager silence. Destructive: suppresses paging."""
    # destructiveHint tells the host to demand explicit human approval.
    await ctx.warning(f"creating silence for {alertname} lasting {duration}")
    ...
    return f"Silenced {alertname} for {duration}."


@mcp.resource(
    "prometheus://alerts/firing",
    name="Firing alerts",
    description="Every alert currently in the firing state",
    mime_type="application/json",
)
async def firing_alerts() -> str:
    """Application-controlled context: the host decides when to attach this."""
    response = await _http.get(f"{PROMETHEUS_URL}/api/v1/alerts")
    response.raise_for_status()
    return response.text


@mcp.prompt(name="triage_incident", description="Structured incident triage")
def triage_incident(service: str, since: str = "30m") -> str:
    """User-controlled template, surfaced as a slash command in the host."""
    return (
        f"You are triaging an incident on the service '{service}'.\n"
        f"Look back {since}.\n"
        "1. List firing alerts scoped to that service.\n"
        "2. For each, query the underlying metric and state whether it is "
        "still degrading, recovering, or flat.\n"
        "3. Name the single most likely proximate cause and the evidence for it.\n"
        "4. State explicitly what you could not determine."
    )


if __name__ == "__main__":
    transport = os.environ.get("MCP_TRANSPORT", "stdio")
    if transport == "streamable-http":
        mcp.settings.host = "0.0.0.0"
        mcp.settings.port = int(os.environ.get("PORT", "8080"))
        mcp.settings.streamable_http_path = "/mcp"
        log.info("serving streamable-http on %s:%s/mcp",
                 mcp.settings.host, mcp.settings.port)
        mcp.run(transport="streamable-http")
    else:
        log.info("serving stdio")
        mcp.run(transport="stdio")
```

### 8.1 The error semantics that matter

There are two error channels and choosing wrongly breaks the agent loop:

| Situation | Channel | Model sees it? |
|---|---|---|
| Unknown method, malformed params, capability not negotiated | JSON-RPC `error` object | No — the client handles it |
| Tool ran and failed (bad PromQL, upstream 503, permission denied) | `result` with `isError: true` and the message in `content` | **Yes — it can correct itself** |

Returning a JSON-RPC error for a failed tool execution hides the failure from the model, which then confabulates a result or silently drops the step. This is the single most common correctness bug in hand-written servers.

JSON-RPC error codes you should recognise:

| Code | Name | Typical MCP cause |
|---|---|---|
| `-32700` | Parse error | Corrupted stdout on stdio; truncated body |
| `-32600` | Invalid request | Missing `jsonrpc`, wrong shape |
| `-32601` | Method not found | Calling an un-negotiated capability, or a version mismatch |
| `-32602` | Invalid params | Arguments failed the tool's input schema |
| `-32603` | Internal error | Unhandled exception in the server |

---

## 9. Deployment topologies

### 9.1 Trade-off table

| Topology | How | Isolation | Scaling | Best for |
|---|---|---|---|---|
| **Local stdio** | Host spawns a subprocess | Process-level, user's UID | Per-host | Filesystem, git, editor state |
| **Containerised stdio** | Host spawns `docker run -i` | Container + seccomp | Per-host | Untrusted third-party servers on a laptop |
| **Sidecar** | Server as a sidecar to the agent pod | Pod-level | With the agent | Agent-specific capabilities, no sharing |
| **Shared remote** | Deployment + Service + Ingress | Namespace, NetworkPolicy, OAuth | HPA | Platform capabilities |
| **Gateway** | One MCP endpoint fronting many servers | Depends entirely on the gateway | HPA | Fleet governance, central audit |

### 9.2 Containerised stdio — the pragmatic isolation win

```json
{
  "mcpServers": {
    "vendor-analytics": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "--network=none",
        "--read-only",
        "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m",
        "--cap-drop=ALL",
        "--security-opt", "no-new-privileges",
        "--memory=512m",
        "--cpus=0.5",
        "--pids-limit=128",
        "ghcr.io/vendor/analytics-mcp:1.9.3"
      ],
      "env": {
        "LOG_LEVEL": "info"
      }
    }
  }
}
```

`-i` keeps stdin open — without it the transport never establishes. `--network=none` is the strongest single control available for a server that should only transform data handed to it.

### 9.3 Host configuration for mixed transports

```json
{
  "mcpServers": {
    "prom-mcp": {
      "type": "http",
      "url": "https://mcp.example.internal/mcp",
      "headers": {
        "Authorization": "Bearer ${MCP_PROM_TOKEN}"
      }
    },
    "fs-runbooks": {
      "command": "/usr/local/bin/mcp-server-filesystem",
      "args": ["/srv/runbooks"],
      "env": {
        "LOG_LEVEL": "info"
      }
    }
  }
}
```

### 9.4 What a gateway actually is

A gateway is **a server to the host and a host-like aggregator to the downstream servers**. It terminates one MCP session with the agent, runs its own clients against N backing servers, and re-exports a merged, namespaced capability list.

This is legitimate and useful — it is where you put central authorization, audit logging and tool allowlisting. But be honest about what it costs: the per-server isolation guarantee now lives entirely in your gateway code, not in the protocol. A bug there lets server A's data reach server B. Do not describe a gateway as "one client talking to many servers" — that framing violates the 1:1 invariant and is wrong on the exam.

---

## 10. Production manifests

### 10.1 Namespace and configuration

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-platform
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prom-mcp-config
  namespace: mcp-platform
data:
  server.yaml: |
    server:
      name: prom-mcp
      version: "1.4.0"
      transport: streamable-http
      bind: "0.0.0.0:8080"
      endpoint: /mcp
    session:
      backend: redis
      ttl_seconds: 1800
      idle_sse_heartbeat_seconds: 20
      redis_url: "redis://mcp-session-store.mcp-platform.svc.cluster.local:6379/0"
    security:
      allowed_origins:
        - "https://agents.example.internal"
        - "https://ide.example.internal"
      require_protocol_version_header: true
      resource_indicator: "https://mcp.example.internal/mcp"
      authorization_servers:
        - "https://idp.example.internal/realms/platform"
    upstream:
      prometheus_url: "https://prometheus.observability.svc.cluster.local:9090"
      query_timeout_seconds: 30
      max_series: 10000
```

### 10.2 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prom-mcp
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: prom-mcp
    app.kubernetes.io/component: mcp-server
spec:
  replicas: 3
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: prom-mcp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prom-mcp
        app.kubernetes.io/component: mcp-server
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      serviceAccountName: prom-mcp
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: prom-mcp
      containers:
        - name: server
          image: registry.example.internal/platform/prom-mcp:1.4.0
          imagePullPolicy: IfNotPresent
          args:
            - --config
            - /etc/prom-mcp/server.yaml
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          env:
            - name: MCP_TRANSPORT
              value: streamable-http
            - name: LOG_LEVEL
              value: info
            - name: PROMETHEUS_URL
              value: "https://prometheus.observability.svc.cluster.local:9090"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
            - name: OTEL_SERVICE_NAME
              value: prom-mcp
            - name: PROMETHEUS_BEARER_TOKEN
              valueFrom:
                secretKeyRef:
                  name: prom-mcp-upstream
                  key: bearer-token
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              cpu: "1"
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - "sleep 15"
          volumeMounts:
            - name: config
              mountPath: /etc/prom-mcp
              readOnly: true
            - name: tmp
              mountPath: /tmp
      terminationGracePeriodSeconds: 60
      volumes:
        - name: config
          configMap:
            name: prom-mcp-config
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
```

Two decisions in there are MCP-specific and worth stating plainly:

**The probes hit `/healthz` and `/readyz`, not `/mcp`.** It is tempting to make the probe do a real `initialize`. Do not. Every probe would mint a session; at `periodSeconds: 5` across three pods that is 51,840 orphaned sessions a day in your Redis. Expose ordinary HTTP health endpoints and reserve `ping` for manual diagnosis.

**`terminationGracePeriodSeconds: 60` with a 15-second `preStop` sleep.** Long-lived SSE streams are in flight during a rollout. The sleep lets endpoint removal propagate before the process starts refusing; the 60 s grace lets in-flight tool calls drain. With the default 30 s and no preStop, a deploy shows up to users as tool calls hanging and then failing mid-answer.

### 10.3 Service, Ingress, NetworkPolicy, PDB, HPA

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prom-mcp
  namespace: mcp-platform
automountServiceAccountToken: false
---
apiVersion: v1
kind: Service
metadata:
  name: prom-mcp
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: prom-mcp
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: prom-mcp
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: metrics
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prom-mcp
  namespace: mcp-platform
  annotations:
    cert-manager.io/cluster-issuer: internal-ca
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: 4m
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Connection "";
      chunked_transfer_encoding off;
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - mcp.example.internal
      secretName: prom-mcp-tls
  rules:
    - host: mcp.example.internal
      http:
        paths:
          - path: /mcp
            pathType: Prefix
            backend:
              service:
                name: prom-mcp
                port:
                  name: http
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: prom-mcp
  namespace: mcp-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: prom-mcp
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 9090
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 9090
        - protocol: TCP
          port: 4317
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-session-store
      ports:
        - protocol: TCP
          port: 6379
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: prom-mcp
  namespace: mcp-platform
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: prom-mcp
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: prom-mcp
  namespace: mcp-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: prom-mcp
  minReplicas: 3
  maxReplicas: 12
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Pods
      pods:
        metric:
          name: mcp_active_sessions
        target:
          type: AverageValue
          averageValue: "200"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 100
          periodSeconds: 60
```

The NetworkPolicy is the control that makes a shared MCP server defensible. A remote server holds credentials to an upstream on behalf of many users; default-deny egress is what stops a compromised or malicious server from exfiltrating what it reads.

The `scaleDown.stabilizationWindowSeconds: 600` is deliberate: sessions are long-lived and every scale-down event that lands on a pod holding open SSE streams is a visible user-facing reconnect.

### 10.4 The session-affinity question

You will be tempted to write:

```yaml
    nginx.ingress.kubernetes.io/upstream-hash-by: "$http_mcp_session_id"
```

It works for in-session requests and fails badly for `initialize`, which has no `Mcp-Session-Id` header yet. nginx hashes the empty string to one deterministic backend, so every new session in the fleet lands on the same pod. Cookie affinity is worse: MCP clients are not browsers and many do not persist cookies at all.

| Approach | Works for `initialize`? | Survives pod restart? | Verdict |
|---|---|---|---|
| Header consistent hashing | No — single hot pod | No | Avoid |
| Cookie affinity | Yes | No | Only if every client is a browser |
| Shared session store (Redis) | Yes | Yes | **Recommended** |
| Stateless mode (no session id) | Yes | N/A | Fine if the server has no per-session state |

Externalise session state and let any pod serve any request. The one thing that genuinely cannot be shared is an open SSE stream — a pod holding one must be drained gracefully, which is what the preStop hook and grace period above are for.

### 10.5 stdio server as a supervised local service

For a machine-local stdio server managed by the platform rather than the user:

```ini
[Unit]
Description=Runbooks MCP server (stdio, socket-activated wrapper)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mcp
Group=mcp
ExecStart=/usr/local/bin/mcp-server-filesystem /srv/runbooks
Environment=LOG_LEVEL=info
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=2s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/srv/runbooks
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX
MemoryMax=512M
TasksMax=128

[Install]
WantedBy=multi-user.target
```

Note `RestrictAddressFamilies=AF_UNIX`: a filesystem server has no business opening a network socket, and this makes that structural rather than aspirational.

---

## 11. SLOs and alerting

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: prom-mcp-slo
  namespace: mcp-platform
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp-server.rules
      interval: 30s
      rules:
        - alert: MCPInitializeErrorRatioHigh
          expr: |
            (
              sum(rate(mcp_requests_total{service="prom-mcp",method="initialize",outcome="error"}[5m]))
              /
              sum(rate(mcp_requests_total{service="prom-mcp",method="initialize"}[5m]))
            ) > 0.02
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "MCP initialize error ratio above 2%"
            description: "Hosts cannot open sessions. Check the session store and the authorization server."
            runbook_url: "https://runbooks.example.internal/mcp/initialize-errors"

        - alert: MCPToolCallLatencyHigh
          expr: |
            histogram_quantile(
              0.95,
              sum by (le, tool) (
                rate(mcp_tool_duration_seconds_bucket{service="prom-mcp"}[5m])
              )
            ) > 10
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "p95 tool latency above 10s for {{ $labels.tool }}"
            description: "Agent turns stall; the host may time out and drop the call."

        - alert: MCPSessionStoreSaturated
          expr: |
            sum(mcp_active_sessions{service="prom-mcp"})
              /
            sum(mcp_session_capacity{service="prom-mcp"})
              > 0.85
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "MCP session store above 85% capacity"
            description: "New initialize requests will start failing. Scale out or shorten the session TTL."

        - alert: MCPSessionLeak
          expr: |
            (
              sum(rate(mcp_sessions_created_total{service="prom-mcp"}[30m]))
              -
              sum(rate(mcp_sessions_closed_total{service="prom-mcp"}[30m]))
            ) > 0.5
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "MCP sessions created far outpace sessions closed"
            description: "Clients are not sending DELETE, or a probe is minting sessions. Check readiness probe configuration."

        - alert: MCPSSEStreamChurn
          expr: |
            sum(rate(mcp_sse_streams_closed_total{service="prom-mcp",reason="transport"}[5m])) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "SSE streams closing on transport errors"
            description: "Likely an ingress read timeout below the heartbeat interval, or buffering left on."
```

Minimum instrumentation for an MCP server:

| Metric | Type | Labels | Why |
|---|---|---|---|
| `mcp_requests_total` | counter | `method`, `outcome` | RED rate and errors per protocol method |
| `mcp_request_duration_seconds` | histogram | `method` | Protocol-level latency |
| `mcp_tool_duration_seconds` | histogram | `tool` | Per-tool latency; the one users feel |
| `mcp_tool_errors_total` | counter | `tool`, `kind` | Separates `isError` results from protocol errors |
| `mcp_active_sessions` | gauge | — | HPA input and saturation signal |
| `mcp_sessions_created_total` / `_closed_total` | counter | — | Leak detection |
| `mcp_sse_streams_active` | gauge | — | Drain-safety during rollouts |
| `mcp_protocol_version_total` | counter | `version` | Fleet migration tracking — tells you when you can drop an old revision |

---

## 12. Verification and diagnosis

### 12.1 Verifying a stdio server by hand

The fastest way to prove a stdio server is sane is to drive it from a shell. Three newline-delimited messages, in order:

```
$ printf '%s\n' \
  '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"shell-probe","version":"0.1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | PROMETHEUS_URL=http://localhost:9090 .venv/bin/python -m prom_mcp 2>/tmp/prom-mcp.err

{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-06-18","capabilities":{"logging":{},"prompts":{"listChanged":false},"resources":{"subscribe":false,"listChanged":false},"tools":{"listChanged":false}},"serverInfo":{"name":"prom-mcp","version":"1.4.0"},"instructions":"Query Prometheus for metrics and alerts. Prefer query_range over repeated query_instant when the user asks about a time window. Series are capped; narrow the selector rather than raising the cap."}}
{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"query_instant","title":"Instant PromQL query","description":"Evaluate a PromQL expression at the current instant.","inputSchema":{"type":"object","properties":{"expr":{"type":"string","description":"PromQL expression, e.g. up{job='kubelet'}"}},"required":["expr"]},"outputSchema":{"type":"object","properties":{"expr":{"type":"string"},"series_count":{"type":"integer"},"truncated":{"type":"boolean"},"samples":{"type":"array","items":{"$ref":"#/$defs/Sample"}}},"required":["expr","series_count","truncated","samples"]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true}},{"name":"silence_alert","title":"Silence an alert","description":"Create an Alertmanager silence. Destructive: suppresses paging.","inputSchema":{"type":"object","properties":{"alertname":{"type":"string"},"duration":{"type":"string","enum":["15m","1h","4h","24h"]}},"required":["alertname","duration"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}}]}}
```

The first thing to check is that **nothing but JSON appeared on stdout**. Redirecting stderr to a file, as above, is how you prove it.

### 12.2 The stdout-pollution check

```
$ .venv/bin/python -m prom_mcp < /dev/null 2>/dev/null | head -c 200
```

Correct output is empty. Anything printed here — a banner, a warning, a progress bar — will corrupt the very first message and the host will report an opaque startup failure.

A version that catches it in CI:

```
$ .venv/bin/python -m prom_mcp < /dev/null 2>/dev/null \
  | grep -qv '^{' && echo "FAIL: non-JSON on stdout" || echo "OK: stdout clean"
OK: stdout clean
```

### 12.3 MCP Inspector

The Inspector is the reference diagnostic tool and has both a UI and a CLI mode. The CLI mode is what belongs in your pipelines.

```
$ npx @modelcontextprotocol/inspector --cli \
    .venv/bin/python -m prom_mcp --method tools/list

{
  "tools": [
    {
      "name": "query_instant",
      "title": "Instant PromQL query",
      "description": "Evaluate a PromQL expression at the current instant.",
      "annotations": { "readOnlyHint": true, "destructiveHint": false }
    },
    {
      "name": "silence_alert",
      "title": "Silence an alert",
      "description": "Create an Alertmanager silence. Destructive: suppresses paging.",
      "annotations": { "readOnlyHint": false, "destructiveHint": true }
    }
  ]
}
```

Calling a tool with arguments:

```
$ npx @modelcontextprotocol/inspector --cli \
    .venv/bin/python -m prom_mcp \
    --method tools/call \
    --tool-name query_instant \
    --tool-arg 'expr=up{job="kubelet"}'

{
  "content": [
    {
      "type": "text",
      "text": "{\"expr\":\"up{job=\\\"kubelet\\\"}\",\"series_count\":6,\"truncated\":false,\"samples\":[...]}"
    }
  ],
  "structuredContent": {
    "expr": "up{job=\"kubelet\"}",
    "series_count": 6,
    "truncated": false,
    "samples": [
      { "metric": { "instance": "10.0.3.11:10250", "job": "kubelet" }, "value": 1.0, "timestamp": 1789344012.331 }
    ]
  },
  "isError": false
}
```

Against a remote server:

```
$ npx @modelcontextprotocol/inspector --cli \
    https://mcp.example.internal/mcp \
    --transport http \
    --header "Authorization: Bearer ${MCP_PROM_TOKEN}" \
    --method tools/list
```

### 12.4 Driving Streamable HTTP with curl

Initialize, keeping the response headers so you can capture the session id:

```
$ curl -sS -D - -o /tmp/init.out \
    -X POST https://mcp.example.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Authorization: Bearer ${MCP_PROM_TOKEN}" \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-probe","version":"0.1.0"}}}'

HTTP/2 200
content-type: text/event-stream
mcp-session-id: 0f7c4a1e-9d3b-4a55-b0e7-6c2d8a19f4c1
cache-control: no-cache, no-transform
x-request-id: 8c1d2f3a5b6e7d80

$ cat /tmp/init.out
event: message
id: 1
data: {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-06-18","capabilities":{"logging":{},"prompts":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"tools":{"listChanged":true}},"serverInfo":{"name":"prom-mcp","version":"1.4.0"}}}
```

Complete the handshake and list tools:

```
$ SESSION=0f7c4a1e-9d3b-4a55-b0e7-6c2d8a19f4c1

$ curl -sS -o /dev/null -w '%{http_code}\n' \
    -X POST https://mcp.example.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SESSION}" \
    -H "Authorization: Bearer ${MCP_PROM_TOKEN}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
202

$ curl -sS -N \
    -X POST https://mcp.example.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SESSION}" \
    -H "Authorization: Bearer ${MCP_PROM_TOKEN}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
event: message
id: 2
data: {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"query_instant","title":"Instant PromQL query","inputSchema":{"type":"object","properties":{"expr":{"type":"string"}},"required":["expr"]}},{"name":"silence_alert","title":"Silence an alert","inputSchema":{"type":"object","properties":{"alertname":{"type":"string"},"duration":{"type":"string","enum":["15m","1h","4h","24h"]}},"required":["alertname","duration"]}}]}}
```

Close the session cleanly:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' \
    -X DELETE https://mcp.example.internal/mcp \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SESSION}" \
    -H "Authorization: Bearer ${MCP_PROM_TOKEN}"
204
```

Proving the auth discovery chain:

```
$ curl -sS -D - -o /dev/null -X POST https://mcp.example.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-probe","version":"0.1.0"}}}'

HTTP/2 401
www-authenticate: Bearer resource_metadata="https://mcp.example.internal/.well-known/oauth-protected-resource"

$ curl -sS https://mcp.example.internal/.well-known/oauth-protected-resource | jq .
{
  "resource": "https://mcp.example.internal/mcp",
  "authorization_servers": [
    "https://idp.example.internal/realms/platform"
  ],
  "bearer_methods_supported": [
    "header"
  ],
  "scopes_supported": [
    "mcp:read",
    "mcp:silence"
  ]
}
```

### 12.5 Host-side verification with Claude Code

```
$ claude mcp add --transport http prom-mcp https://mcp.example.internal/mcp
Added HTTP MCP server prom-mcp with URL: https://mcp.example.internal/mcp to local config

$ claude mcp list
Checking MCP server health...

prom-mcp: https://mcp.example.internal/mcp (HTTP) - ✓ Connected
fs-runbooks: /usr/local/bin/mcp-server-filesystem /srv/runbooks - ✓ Connected

$ claude mcp get prom-mcp
prom-mcp:
  Scope: Local config (private to you in this project)
  Type: http
  URL: https://mcp.example.internal/mcp

To remove this server, run: claude mcp remove "prom-mcp" -s local
```

### 12.6 Cluster-side verification

```
$ kubectl -n mcp-platform rollout status deploy/prom-mcp --timeout=120s
deployment "prom-mcp" successfully rolled out

$ kubectl -n mcp-platform get pods -l app.kubernetes.io/name=prom-mcp -o wide
NAME                        READY   STATUS    RESTARTS   AGE   IP           NODE
prom-mcp-7c4f8b9d64-4kx2p   1/1     Running   0          3m    10.42.2.18   worker-02
prom-mcp-7c4f8b9d64-9tqvr   1/1     Running   0          3m    10.42.3.41   worker-03
prom-mcp-7c4f8b9d64-pl6mn   1/1     Running   0          2m    10.42.1.77   worker-01

$ kubectl -n mcp-platform logs -l app.kubernetes.io/name=prom-mcp --tail=5 --prefix
[pod/prom-mcp-7c4f8b9d64-4kx2p/server] 2026-09-17T09:14:02Z INFO prom-mcp serving streamable-http on 0.0.0.0:8080/mcp
[pod/prom-mcp-7c4f8b9d64-4kx2p/server] 2026-09-17T09:14:33Z INFO prom-mcp session opened id=0f7c4a1e client=acme-agent-runtime/4.2.0 protocol=2025-06-18
[pod/prom-mcp-7c4f8b9d64-4kx2p/server] 2026-09-17T09:14:34Z INFO prom-mcp tools/list session=0f7c4a1e duration_ms=3
[pod/prom-mcp-7c4f8b9d64-4kx2p/server] 2026-09-17T09:14:41Z INFO prom-mcp tools/call tool=query_instant session=0f7c4a1e duration_ms=214 outcome=ok
[pod/prom-mcp-7c4f8b9d64-9tqvr/server] 2026-09-17T09:15:02Z INFO prom-mcp session closed id=1b8e5d2f reason=delete

$ kubectl -n mcp-platform port-forward svc/prom-mcp 9090:9090 >/dev/null 2>&1 &
$ curl -s http://127.0.0.1:9090/metrics | grep -E '^mcp_(active_sessions|requests_total)'
mcp_active_sessions 47
mcp_requests_total{method="initialize",outcome="ok"} 1284
mcp_requests_total{method="initialize",outcome="error"} 3
mcp_requests_total{method="tools/list",outcome="ok"} 1279
mcp_requests_total{method="tools/call",outcome="ok"} 8841
mcp_requests_total{method="tools/call",outcome="error"} 112
```

### 12.7 Failure catalogue

| Symptom | Root cause | Probe | Fix |
|---|---|---|---|
| Host: "server failed to start", no detail | Non-JSON on stdout | `server < /dev/null 2>/dev/null \| head -c 200` | Route all logging to stderr; remove banners |
| Client disconnects right after `initialize` | Protocol version mismatch — server offered a revision the client cannot speak | Read `result.protocolVersion` in the trace | Upgrade one side; there is no negotiation fallback |
| `-32601 Method not found` on `tools/list` | Server did not declare the `tools` capability | Inspect the `initialize` result `capabilities` | Declare the capability at registration time |
| HTTP `400 Bad Request` on every non-initialize call | Missing `Mcp-Session-Id` or `MCP-Protocol-Version` header | `curl -D -` and read the request headers back | Persist the session id from the initialize response headers |
| HTTP `404` mid-session, client re-initializes | Session expired or the holding pod was replaced | `mcp_sessions_created_total` spike; pod restart correlation | Externalise session state; `404` is the correct signal for the client to re-initialize |
| SSE stream dies at exactly 60 s | Ingress `proxy-read-timeout` default | `curl -N` and time it | Raise the timeout **and** emit SSE heartbeats below it |
| SSE messages arrive in a burst at the end | Proxy buffering | Same `curl -N`; nothing arrives until close | `proxy-buffering: "off"`, `chunked_transfer_encoding off` |
| Session table grows monotonically | Readiness probe calling `initialize`; or clients never sending DELETE | `mcp_sessions_created_total - mcp_sessions_closed_total` | Probe `/readyz`; add a session TTL sweeper |
| Model never calls a tool that exists | Host filtered it out, or the description is too vague to match intent | `tools/list` via Inspector vs what the host shows | Improve `description`; check host allowlist and namespacing |
| Tool call silently produces no answer | Server returned a JSON-RPC error instead of `isError: true` | Read the raw response: `error` vs `result` | Return execution failures as tool results |
| Two servers both expose `search` and one shadows the other | Name collision; the host's namespacing is weak | `tools/list` from both, compare names | Prefix tool names per domain; rely on host namespacing only as a backstop |
| `401` with no `WWW-Authenticate` | Server is not publishing Protected Resource Metadata | `curl -D -` on an unauthenticated POST | Implement RFC 9728 discovery |
| `403` from the upstream although the user is entitled | Token audience is the IdP or another resource, not this server | Decode the JWT `aud` claim | Send `resource` (RFC 8707) at authorization; validate `aud` server-side |
| Agent turns stall for minutes, then fail | Tool exceeds the host's request timeout and cancellation is unimplemented | `mcp_tool_duration_seconds` p99 | Honour `notifications/cancelled`; emit `notifications/progress` to reset the timeout |
| Orphaned server processes after the host quits | stdio server ignores stdin EOF and SIGTERM | `ps -ef \| grep mcp-server` after quitting the host | Handle EOF and signals; wrap in a container with `--rm` |
| Context window exhausted before any work happens | Too many tools across too many servers | Count tools × schema size | Filter at the host; split monolithic servers |

### 12.8 A minimal conformance client

Useful as a synthetic check in CI — it exercises initialize, negotiation, listing and a call, and shows the client-side callbacks that make sampling and roots work.

```python
"""Synthetic MCP conformance probe. Exit non-zero on any contract violation."""

import asyncio
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from mcp.types import (
    CreateMessageRequestParams,
    CreateMessageResult,
    ErrorData,
    TextContent,
)

ENDPOINT = "https://mcp.example.internal/mcp"
REQUIRED_TOOLS = {"query_instant", "silence_alert"}


async def handle_sampling(
    context, params: CreateMessageRequestParams
) -> CreateMessageResult | ErrorData:
    """The host owns the model. A probe refuses, and refusing is a valid answer."""
    return ErrorData(code=-32000, message="sampling not available in probe mode")


async def main() -> int:
    headers = {"Authorization": f"Bearer {sys.argv[1]}"}

    async with streamablehttp_client(ENDPOINT, headers=headers) as (
        read_stream,
        write_stream,
        get_session_id,
    ):
        async with ClientSession(
            read_stream, write_stream, sampling_callback=handle_sampling
        ) as session:
            init = await session.initialize()

            print(f"protocol={init.protocolVersion}")
            print(f"server={init.serverInfo.name}/{init.serverInfo.version}")
            print(f"session={get_session_id()}")

            if init.capabilities.tools is None:
                print("FAIL: server does not declare the tools capability")
                return 1

            listed = await session.list_tools()
            names = {tool.name for tool in listed.tools}
            missing = REQUIRED_TOOLS - names
            if missing:
                print(f"FAIL: missing tools {sorted(missing)}")
                return 1

            result = await session.call_tool("query_instant", {"expr": "vector(1)"})
            if result.isError:
                body = result.content[0]
                text = body.text if isinstance(body, TextContent) else str(body)
                print(f"FAIL: query_instant returned isError: {text}")
                return 1

            print(f"OK: {len(names)} tools, smoke query succeeded")
            return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
```

```
$ .venv/bin/python probe.py "${MCP_PROM_TOKEN}"
protocol=2025-06-18
server=prom-mcp/1.4.0
session=3d9a7c2b-5e41-4f88-9a02-71bc4de8f013
OK: 5 tools, smoke query succeeded

$ echo $?
0
```

---

## 13. Security posture summary

Map each role to what it must enforce. This is the mental model to carry into the exam and into a design review.

| Control | Enforced by | Consequence of omission |
|---|---|---|
| Human approval before a destructive tool runs | **Host** | Prompt injection in a fetched web page silences your alerts |
| No server sees another server's data or the conversation | **Host** | A third-party server exfiltrates credentials the user pasted |
| Origin header validation | **Server** | DNS rebinding drives a localhost server from a malicious web page |
| Bind local servers to `127.0.0.1` | **Server** | Anyone on the LAN owns the server |
| Token audience validation | **Server** | Confused deputy; cross-resource token replay |
| PKCE on every authorization flow | **Client** | Authorization code interception |
| No secrets requested via elicitation | **Server** | Phishing with the host's own trusted UI |
| Roots respected | **Server** (advisory) | Path traversal outside the user's intended scope |
| Sampling gated and reviewable | **Host** | A server drains the user's token budget or launders a prompt injection through the model |
| Default-deny egress | **Platform** | A compromised server exfiltrates at line rate |

The recurring theme: **the host is the only component that can enforce user intent, because it is the only component that can see the user.** Servers enforce their own perimeter; the platform enforces the network. Design reviews that put approval logic in the server are misplacing it.

---

## 14. What to take into the exam

1. Host owns the model, the conversation and the policy; **client is 1:1 with a server**; server exposes capabilities and never sees the conversation.
2. Base protocol is **JSON-RPC 2.0**. Three message shapes. Batching was removed in `2025-06-18`.
3. Lifecycle: `initialize` → `notifications/initialized` → operation → transport-level shutdown. Version mismatch means **disconnect**, not degrade.
4. Capabilities gate features. Undeclared capability ⇒ `-32601`.
5. Control triad: **tools = model-controlled, resources = application-controlled, prompts = user-controlled.**
6. Client features invert the direction: **roots** (client informs), **sampling** and **elicitation** (server asks, host mediates).
7. Two transports: **stdio** (local subprocess, stdout is sacred) and **Streamable HTTP** (one endpoint, POST/GET/DELETE, `Mcp-Session-Id`, `MCP-Protocol-Version`, SSE).
8. Remote auth is **OAuth 2.1** with the server as Resource Server: RFC 9728 discovery, PKCE, RFC 8707 resource indicators, and **no token passthrough**.
9. Tool execution failures go back as `isError: true`, not as JSON-RPC errors.
10. In production: externalise session state, never probe with `initialize`, turn off proxy buffering, raise SSE timeouts above your heartbeat, drain SSE streams on rollout, and default-deny egress.

---

## References

- Linux Foundation — Model Context Protocol Associate (MCPA) certification: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
- MCP specification — Architecture: https://modelcontextprotocol.io/specification/2025-06-18/architecture
- MCP specification — Lifecycle: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- MCP specification — Transports: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- MCP specification — Authorization: https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- MCP specification — Security best practices: https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
- MCP specification — Server: Tools: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- MCP specification — Server: Resources: https://modelcontextprotocol.io/specification/2025-06-18/server/resources
- MCP specification — Server: Prompts: https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
- MCP specification — Client: Roots: https://modelcontextprotocol.io/specification/2025-06-18/client/roots
- MCP specification — Client: Sampling: https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- MCP specification — Client: Elicitation: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- MCP specification — Utilities: Cancellation: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation
- MCP specification — Utilities: Progress: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress
- MCP — Protocol versioning and revision history: https://modelcontextprotocol.io/specification/versioning
- MCP — Example clients and host compatibility matrix: https://modelcontextprotocol.io/clients
- MCP Python SDK: https://github.com/modelcontextprotocol/python-sdk
- MCP TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk
- MCP Inspector: https://github.com/modelcontextprotocol/inspector
- JSON-RPC 2.0 Specification: https://www.jsonrpc.org/specification
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: https://datatracker.ietf.org/doc/html/rfc9728
- RFC 8707 — Resource Indicators for OAuth 2.0: https://datatracker.ietf.org/doc/html/rfc8707
- RFC 8414 — OAuth 2.0 Authorization Server Metadata: https://datatracker.ietf.org/doc/html/rfc8414
- RFC 7591 — OAuth 2.0 Dynamic Client Registration Protocol: https://datatracker.ietf.org/doc/html/rfc7591
- Kubernetes — Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- ingress-nginx — Annotations reference: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- Prometheus Operator — PrometheusRule API reference: https://prometheus-operator.dev/docs/api-reference/api/