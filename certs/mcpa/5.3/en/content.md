# 5.3 Ecosystem & Portability

**Certification:** Model Context Protocol Associate (MCPA) · Exam version 2026-07-28
**Exam weight:** 6.66 %
**Profile:** Platform Architect / SRE — production depth

---

## 1. Motivation: the architectural problem portability actually solves

### 1.1 The M×N problem, and the one MCP did *not* solve

The canonical pitch for the Model Context Protocol is the integration-count argument: with `M` AI applications and `N` data sources or tools, ad-hoc integration costs `M × N` connectors. A shared protocol turns that into `M + N`. That is true at the **wire level** and it is the reason MCP exists.

The mistake platform teams make is assuming the wire level is the whole problem. It is not. In production, a single "MCP server" that works perfectly under `npx` on a staff engineer's laptop inside Claude Desktop routinely fails when the same team tries to expose it to:

- a VS Code / GitHub Copilot agent on a locked-down corporate image,
- a CI job running a headless agent with no interactive OAuth flow,
- an internal LangGraph agent running in Kubernetes,
- a JetBrains IDE on Windows,
- a browser-based host that can only reach the network over HTTPS.

Every one of those failures is a **portability** failure, not a protocol failure. The JSON-RPC messages were fine. What differed was the transport, the negotiated protocol revision, the client capability set, the packaging, the configuration file shape, or the identity model.

### 1.2 A concrete production scenario

Assume the platform group at a 400-engineer company. Inventory after nine months of organic MCP adoption:

| Dimension | Count | Consequence |
|---|---|---|
| Distinct hosts in use | 6 (Claude Desktop, Claude Code, VS Code+Copilot, Cursor, JetBrains AI Assistant, internal agent runtime) | 6 config formats, 6 capability profiles |
| Internal MCP servers | 31 (Python 14, TypeScript 12, Go 5) | 3 packaging toolchains |
| Transports in use | stdio (27), Streamable HTTP (3), legacy HTTP+SSE (1) | 1 deprecated transport still in prod |
| Protocol revisions pinned in code | 3 (`2024-11-05`, `2025-03-26`, `2025-06-18`) | negotiation failures across pairs |
| Secrets distribution methods | 4 (env in config file, `.env`, keychain, OAuth) | 1 of them is plaintext on 400 laptops |

The support matrix is **6 × 31 = 186 cells**. Nobody tests 186 cells. What actually happens is that each cell is discovered broken by a user, in a Slack thread, at the worst possible time. This is the operational definition of a non-portable estate: *the number of distinct runbooks grows with the product of hosts and servers instead of their sum.*

### 1.3 Portability, defined on five independent axes

An MCP server is portable to the degree that it is invariant across each of these. They fail independently, so they must be verified independently.

| Axis | Question | Governed by | Fails as |
|---|---|---|---|
| **A1 — Wire** | Do both sides speak a common protocol revision over a transport both implement? | Spec revision + transport | `initialize` fails, or connection drops silently |
| **A2 — Capability** | Does the host actually implement the features the server assumes (sampling, roots, elicitation)? | `capabilities` negotiation | Tool hangs or returns "method not found" mid-call |
| **A3 — Packaging** | Can the artifact be obtained and executed on the target OS/runtime? | Distribution format | "Server failed to start", `ENOENT`, `spawn npx` |
| **A4 — Configuration** | Can the host be *told about* the server without hand-editing per-host JSON? | Host config schema | Works for the author, nobody else |
| **A5 — Identity** | Can credentials reach the server without being copied into a config file? | OAuth 2.1 / secret store | Plaintext tokens, or no non-interactive path |

> **SRE framing.** Portability is not a developer-experience nicety. It is an **availability property of the tool plane**. A server that only works in one host has a hard dependency on that host's release cadence, its PATH resolution, its OAuth implementation and its bug backlog. You cannot fail over to a different host during an incident. Treat "runs unmodified in ≥ 2 hosts over ≥ 2 transports" as a production readiness gate in the same class as "has a readiness probe".

---

## 2. The ecosystem map

### 2.1 Layers

MCP's ecosystem is a stack, and each layer has a different change-control regime. Knowing *which* layer a breaking change came from is most of the diagnostic work.

| Layer | Artifacts | Change control | Portability impact when it moves |
|---|---|---|---|
| **Specification** | Protocol revisions (`YYYY-MM-DD`), JSON Schema, SEP process | Open governance, versioned, dated | Highest — breaks `initialize` |
| **Schema/SDK** | TypeScript, Python, Java, Kotlin, C#, Go, Ruby, Rust, PHP, Swift SDKs | Per-SDK semver, tracks spec with lag | High — an SDK that lags a revision blocks adoption |
| **Servers** | Reference servers, vendor servers, community servers | Independent semver, no coordination | Medium — per-server blast radius |
| **Hosts / clients** | Claude Desktop, Claude Code, VS Code, Cursor, Zed, JetBrains, custom agents | Vendor release cycles | High — capability variance lives here |
| **Registry / discovery** | Official MCP Registry, subregistries, curated catalogues | Registry API versioning | Medium — affects install, not runtime |
| **Gateway / runtime** | MCP gateways, K8s operators, proxies, bridges | Vendor / OSS | Medium — your own control plane |
| **Governance** | Linux Foundation stewardship, SEP (Specification Enhancement Proposal) process, trademark, registry namespaces | Foundation charter | Low frequency, very high leverage |

**Why vendor-neutral governance is a portability control, not a press release.** Three concrete mechanisms:

1. **Change control on the spec.** A dated revision with a public enhancement-proposal process means a breaking change is observable *before* it ships, and is attributable to a document you can diff — not to a vendor's client update that landed overnight.
2. **Namespace authority.** A neutral registry can assert that `com.acme/inventory` belongs to whoever controls `acme.com`. Without a neutral authority, name squatting turns discovery into a supply-chain problem.
3. **Conformance definition.** "MCP-compatible" only constrains behaviour if some body defines what the claim means. This is exactly what the MCPA certification tests you on, and why the Linux Foundation runs it.

### 2.2 SDK landscape

The practical question for a platform team is not "which language do I like" but "which SDK will still be on the current spec revision in six months, and does it implement both transports on both sides."

| SDK | Typical role | Server | Client | Both transports | Notes for portability |
|---|---|---|---|---|---|
| TypeScript | Reference implementation; most servers | ✅ | ✅ | ✅ | Largest ecosystem; `npx` distribution is trivial and unpinned by default |
| Python | Data/ML-adjacent servers | ✅ | ✅ | ✅ | `FastMCP`-style high-level API; `uvx` distribution |
| Java / Kotlin | JVM enterprise integration | ✅ | ✅ | ✅ | Spring AI integration is common; heavier startup for stdio |
| C# / .NET | Windows-heavy estates | ✅ | ✅ | ✅ | Single-file publish gives a clean static binary |
| Go | Infra/platform servers | ✅ | ✅ | ✅ | Best fit for a scratch-image container; no runtime on the host |
| Rust | Latency/footprint-sensitive | ✅ | ✅ | ✅ | Same advantages as Go |
| Ruby / PHP / Swift | Niche / platform-specific hosts | ✅ | partial | varies | Verify client-side and transport coverage before committing |

> **Verify before you depend.** SDK feature coverage per spec revision moves. Check the SDK's own README and its declared `LATEST_PROTOCOL_VERSION` constant rather than trusting a table — including this one.

```
$ python3 -c "import mcp.types as t; print(t.LATEST_PROTOCOL_VERSION)"
2025-06-18

$ node -e "const {LATEST_PROTOCOL_VERSION, SUPPORTED_PROTOCOL_VERSIONS} = require('@modelcontextprotocol/sdk/types.js'); console.log(LATEST_PROTOCOL_VERSION, SUPPORTED_PROTOCOL_VERSIONS)"
2025-06-18 [ '2025-06-18', '2025-03-26', '2024-11-05' ]
```

That second command is the single most useful portability probe you can run on a server codebase. It tells you the exact negotiation envelope the server will accept.

### 2.3 Where MCP sits among adjacent protocols

Exam-relevant and architecture-relevant: MCP is not a competitor to everything that looks like it.

| Protocol / mechanism | Scope | Relationship to MCP | When you choose it instead |
|---|---|---|---|
| **MCP** | Model ↔ context/tools, stateful session, bidirectional | — | Attaching tools, resources and prompts to an agent |
| **OpenAPI + native function calling** | Model ↔ HTTP API, stateless per call | Complementary; many MCP servers wrap an OpenAPI surface | You control both model and API, need no host-side reuse |
| **A2A (Agent2Agent)** | Agent ↔ agent delegation | Orthogonal layer; an agent can be an MCP host *and* an A2A peer | Delegating a whole task to another autonomous agent |
| **LSP (Language Server Protocol)** | Editor ↔ language tooling | Design ancestor: JSON-RPC, capability negotiation, stdio | Never — different domain, cited only as prior art |
| **Vendor plugin formats** | One host only | MCP's replacement target | Never, for new work — this is the non-portable case by construction |

The structural inheritance from LSP matters for the exam: **JSON-RPC 2.0 messaging, an `initialize` handshake carrying declared capabilities, and stdio as the default local transport** are all LSP patterns. LSP proved the model works: one language server, dozens of editors.

---

## 3. Axis A1 — Wire portability: revisions and negotiation

### 3.1 The versioning scheme

MCP uses **date-based revisions**, `YYYY-MM-DD`, denoting the date the revision's backwards-incompatible changes were finalised. There is no semver, no major/minor. The negotiated string is opaque and must be compared for equality, never parsed for ordering by clients that do not maintain an explicit supported-version list.

| Revision | Headline changes | Portability impact |
|---|---|---|
| `2024-11-05` | Initial revision. stdio + HTTP+SSE (two endpoints: `GET /sse` + `POST /messages`). | Baseline. Servers still pinned here cannot use modern auth. |
| `2025-03-26` | **Streamable HTTP** replaces HTTP+SSE; OAuth 2.1-based authorization framework; tool annotations; audio content; JSON-RPC batching added; progress notification `message` field. | Transport break. Old clients + new servers need a compatibility path. |
| `2025-06-18` | **JSON-RPC batching removed**; `elicitation` (server asks the user for input via the client); structured tool output; resource links in tool results; `MCP-Protocol-Version` header mandatory on HTTP; auth split into Resource Server + Authorization Server with RFC 9728 Protected Resource Metadata and RFC 8707 Resource Indicators; `_meta`/`title` fields. | Batching removal breaks clients that emitted arrays. Header requirement breaks naive proxies that strip unknown headers. |
| `2025-11-25` and later | Continued additions under the SEP process (async/long-running work, extension namespacing, server identity refinements). | Check `specification/versioning` for the current list before pinning. |

> **Do not hardcode the revision string from memory — including from this document.** Read it from the SDK constant at build time, and assert the negotiated value at runtime. The authoritative list is at `https://modelcontextprotocol.io/specification/versioning`.

### 3.2 The negotiation handshake, exactly

Client sends `initialize` proposing the **latest revision it supports**:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "roots": { "listChanged": true },
      "sampling": {},
      "elicitation": {}
    },
    "clientInfo": {
      "name": "acme-agent",
      "title": "Acme Platform Agent",
      "version": "1.4.2"
    }
  }
}
```

Server responds with the **same revision if it supports it, otherwise another revision it does support**:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "logging": {},
      "tools": { "listChanged": true },
      "resources": { "subscribe": true, "listChanged": true },
      "prompts": { "listChanged": true },
      "completions": {}
    },
    "serverInfo": {
      "name": "com.acme/inventory",
      "title": "Acme Inventory",
      "version": "2.1.0"
    },
    "instructions": "Read-only access to warehouse inventory. Call inventory_search before inventory_reserve."
  }
}
```

Client confirms, and only then may it send other requests:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized"
}
```

The three rules that produce nearly every negotiation bug:

1. **The client proposes; the server decides.** If the server answers with a revision the client does not support, the **client** must disconnect. A client that shrugs and continues will emit messages the server cannot parse, and the failure will surface later as a mysterious hang.
2. **`initialize` must not be batched** — and since `2025-06-18` nothing may be batched at all.
3. **The client must not send requests other than pings before the `initialized` notification**, and the server must not send requests other than pings and logging before it.

### 3.3 The HTTP revision header

Since `2025-06-18`, every HTTP request after initialization **must** carry the negotiated revision:

```
MCP-Protocol-Version: 2025-06-18
```

Server behaviour that you must implement and must test for:

| Condition | Required server response |
|---|---|
| Header present, revision supported | Process normally |
| Header present, revision unsupported or malformed | `400 Bad Request` |
| Header absent | **Assume `2025-03-26`** for backwards compatibility |

That last row is a live production trap. A reverse proxy, WAF or service mesh that drops unknown request headers will silently downgrade every session to `2025-03-26` — and then `elicitation` and structured tool output vanish with no error anywhere. Header allow-lists on the ingress path are a portability hazard; audit them.

### 3.4 Dual-revision support for server authors

The portable pattern is: **support N and N−1, gate features on the negotiated value, never on your own build version.**

```python
from mcp.server.lowlevel import Server
from mcp.shared.session import RequestContext

SUPPORTED = ("2025-06-18", "2025-03-26")

def supports_structured_output(negotiated: str) -> bool:
    # Structured tool output landed in 2025-06-18. Older peers get text only.
    return negotiated >= "2025-06-18"   # safe: dates sort lexicographically

async def inventory_search(ctx: RequestContext, sku: str) -> dict | str:
    rows = await query(sku)
    if supports_structured_output(ctx.session.negotiated_protocol_version):
        return {"items": rows, "count": len(r
ows)}
    return "\n".join(f"{r['sku']}\t{r['qty']}" for r in rows)
```

> Lexicographic comparison of `YYYY-MM-DD` strings is ordering-correct, which is convenient — but only compare against revisions you have explicitly listed in `SUPPORTED`. Treat an unknown future revision as "negotiate down", never as "assume it has everything".

---

## 4. Axis A1 (continued) — Transport portability

### 4.1 The three transports

| | **stdio** | **Streamable HTTP** | **HTTP+SSE (legacy)** |
|---|---|---|---|
| Status | Current, mandatory-to-support in practice | Current | **Deprecated** since `2025-03-26` |
| Endpoints | none (process pipes) | one (e.g. `POST/GET/DELETE /mcp`) | two (`GET /sse`, `POST /messages`) |
| Server-initiated messages | inherent (full duplex pipe) | SSE stream on `GET`, or SSE response to `POST` | SSE stream |
| Process model | one server process **per client session** | one server, many sessions | one server, many sessions |
| Auth | inherited process env / OS user | OAuth 2.1 bearer, mTLS, headers | as Streamable HTTP |
| Multi-tenancy | none | yes | yes |
| Horizontal scale | no | yes (stateless mode) or sticky sessions | sticky only |
| Observability | stderr only, no request IDs at L7 | full L7: access logs, traces, metrics | partial |
| Network policy | nothing to filter — and nothing to *enforce* | standard egress/ingress controls apply | same |
| Host support | universal | broad and growing | shrinking |
| Latency | lowest (no network) | +RTT | +RTT |
| Secret exposure | env vars visible in host config files and `/proc` | token never leaves the server side | same |
| Blast radius of a crash | one user | all users on that replica | all users |

### 4.2 The architectural consequence

There is a genuine tension, and the exam expects you to be able to state it:

> **stdio is the most portable transport and the least operable one. Streamable HTTP is the most operable and, historically, the less uniformly supported one.**

stdio is portable because it needs no network, no TLS, no auth server and no DNS — every host implements it. It is unoperable because there is no request log, no metric endpoint, no central upgrade path (each of 400 laptops has its own copy at its own version), and the server runs with the user's full local privileges holding secrets in plaintext environment variables.

Streamable HTTP is operable because it is just HTTP: you get access logs, distributed tracing, rate limits, WAF, mTLS, OAuth, canary deploys and one place to patch a CVE. It is less portable because a host that only implements stdio cannot reach it, and because OAuth flows need an interactive browser that a CI runner does not have.

### 4.3 The bridge pattern — the single most important production technique in this topic

You do not choose. You **run the server once, centrally, over Streamable HTTP, and expose a thin stdio shim** to hosts that need stdio. The shim is a proxy: it speaks stdio to the host and Streamable HTTP to the real server, and it holds no business logic.

```
                    ┌────────────────────────────────────────┐
  Claude Desktop ──stdio──▶ stdio↔HTTP bridge ──┐             │
  JetBrains      ──stdio──▶ stdio↔HTTP bridge ──┤             │
                                                │             │
  VS Code        ────────── Streamable HTTP ────┼──▶ Gateway ─┼──▶ mcp-inventory (3 replicas)
  Claude Code    ────────── Streamable HTTP ────┤   (authN,   │──▶ mcp-deploys   (2 replicas)
  CI agent       ────────── Streamable HTTP ────┘    authZ,   │──▶ mcp-runbooks  (2 replicas)
                                                     audit,   │
                                                     quota)   │
                    ┌───────────────────────────────┘         │
                    │  one upgrade path, one audit log,       │
                    │  one secret store, one CVE patch        │
                    └─────────────────────────────────────────┘
```

Properties this buys you, stated as SRE outcomes:

- **Upgrade latency drops from weeks to one rollout.** Patching an `npx`-distributed server means waiting for 400 caches to expire.
- **Secrets leave the laptop.** The bridge forwards an OAuth token or nothing; the API key lives in the cluster.
- **Per-tool SLOs become measurable.** You cannot put a latency SLO on a subprocess on someone's laptop.
- **Revocation becomes possible.** Terminating a compromised user's access is a token revocation, not a fleet-wide config edit.

The cost: the bridge is a new dependency on every workstation, and it must be version-pinned like any other. Budget for it.

### 4.4 Session semantics and load balancing

Streamable HTTP sessions are established by the server returning a session identifier on the `initialize` response:

```
Mcp-Session-Id: 1868a90c-5b1f-4c3e-9a8b-3b7f6a2d11e4
```

The client must echo that header on every subsequent request. Rules with direct operational consequences:

| Event | Spec behaviour | What it means for your load balancer |
|---|---|---|
| Server returns `Mcp-Session-Id` | Client must include it thereafter | The session is **server-side state** |
| Request with expired/unknown session | Server returns `404 Not Found` | Client must start a **new `initialize`** — so a rolling restart *will* interrupt sessions unless stateless |
| Request missing a required session id | `400 Bad Request` | A proxy stripping the header breaks every call after the first |
| `DELETE` with session id | Server should terminate; may return `405` if it does not allow client termination | Not all servers let you clean up |
| SSE stream drops | Client may resume with `Last-Event-ID` on `GET` | Requires per-stream event IDs and a replay buffer on the server |

**The load balancing decision:**

| Mode | Implementation | Trade-off |
|---|---|---|
| **Stateless** (recommended) | Server keeps no per-session memory; each request self-contained; no `Mcp-Session-Id` issued, or one that any replica accepts | Scales horizontally, survives rolling restarts, no affinity needed. Costs you `resources/subscribe` and server-initiated notifications unless backed by shared state. |
| **Sticky by header hash** | Gateway consistent-hashes on `Mcp-Session-Id` | Preserves full feature set. Requires L7 gateway support, and a replica loss still kills its sessions. |
| **Sticky by client IP** | `sessionAffinity: ClientIP` on the Service | **Wrong in almost every real topology.** Behind corporate NAT or an egress gateway, thousands of users share one source IP and land on one replica. |
| **Shared session store** | Redis-backed session state | Full features + horizontal scale, at the cost of a stateful dependency and a new failure domain. |

> **Exam-relevant and production-relevant:** `sessionAffinity: ClientIP` is the trap answer. Source-IP affinity does not survive NAT, and it is not what the protocol's session identifier is for.

---

## 5. Axis A2 — Capability portability

### 5.1 The capability contract

`initialize` is a bilateral declaration. Neither side may use a feature the other did not declare.

**Server-declared capabilities** (server → client): `tools`, `resources`, `prompts`, `logging`, `completions`, plus sub-flags `listChanged` and `subscribe`.

**Client-declared capabilities** (client → server): `roots`, `sampling`, `elicitation`.

The client-side three are where portability breaks hardest, because **a server author's laptop host supports all of them and the user's host may support none**.

### 5.2 Host capability variance

| Feature | Direction | What it does | Portability reality |
|---|---|---|---|
| `tools` | server → client | Model-invoked actions | Universal. Every host supports tools. |
| `resources` | server → client | Application-controlled context data | Widely supported, but *how* the user attaches them differs wildly per host |
| `prompts` | server → client | User-invoked templates (slash commands, menus) | Common, surfaced very differently |
| `logging` | server → client | Structured log messages to the client | Often accepted and then discarded |
| `completions` | server → client | Argument autocompletion | Sparse |
| `roots` | client → server | Filesystem/URI boundaries the server may operate in | Inconsistent; many hosts declare it but supply one root |
| `sampling` | client → server | Server asks the client's model to complete something | **Least supported.** Never make it a hard dependency. |
| `elicitation` | client → server | Server asks the user a structured question mid-call | Newest; support is thin |

> The maintained, authoritative version of this matrix is `https://modelcontextprotocol.io/clients`. It changes often. **Re-read it before you design a server around a client capability**, and design so that the answer "no" is survivable.

### 5.3 The degradation ladder

Every dependency on a client capability must have a declared fallback. This is the portability equivalent of a circuit breaker.

| Server wants to… | Preferred | Fallback 1 | Fallback 2 (always available) |
|---|---|---|---|
| Summarise a large document | `sampling/createMessage` | Return the raw text and let the host's model do it in-band | Return a truncated extract plus a `resource_link` |
| Ask the user to pick an environment | `elicitation/create` | Expose one tool per environment (`deploy_staging`, `deploy_prod`) | Require the argument, return a validation error listing valid values |
| Scope file access | `roots/list` | Server-side configured allow-list | Reject absolute paths outside a configured base directory |
| Report progress | progress notifications | `logging/message` | Return a final result only |

```typescript
// Feature-detect once, at initialize. Never per call.
const caps = server.getClientCapabilities();

async function summarise(text: string): Promise<string> {
  if (caps?.sampling) {
    const res = await server.createMessage({
      messages: [{ role: "user", content: { type: "text", text: `Summarise:\n\n${text}` } }],
      maxTokens: 500,
    });
    return res.content.type === "text" ? res.content.text : text.slice(0, 2000);
  }
  // Degrade, do not throw. The host is not broken; it is just different.
  return text.slice(0, 2000);
}
```

The anti-pattern to recognise instantly: calling `sampling/createMessage` without checking `caps.sampling`. On a host that did not declare it, the request either errors out or hangs until timeout — and the user sees "the tool is broken", not "this host lacks a feature".

### 5.4 Extension fields and forward compatibility

Two mechanisms let the ecosystem evolve without shattering:

- **`_meta`** — an object permitted on most types for implementation-specific data. Keys should be namespaced by a reverse-DNS prefix you control (`com.acme.tracing/traceparent`). Peers that do not understand a `_meta` key must ignore it.
- **`experimental`** in the capabilities object — for non-standard capabilities, negotiated the same way as standard ones.

The rule: **put vendor extensions in `_meta` or `experimental`, never as bare top-level fields.** A bare unknown top-level field is the single most common cause of strict-validation rejections between SDKs, because SDKs differ in how aggressively they validate.

---

## 6. Axis A3 — Packaging and distribution portability

### 6.1 Format comparison

| Format | Invocation | Requires on host | Startup | Version pinning | Supply-chain posture | Best for |
|---|---|---|---|---|---|---|
| `npx` | `npx -y @scope/server` | Node.js + network | ~1–3 s cold | Weak by default (`@latest` implied) | Executes newest published tarball, unattended | Demos, personal use |
| `uvx` | `uvx mcp-server-foo` | `uv` + network | ~0.5–2 s cold | Supports `==` pins | Same class as `npx`, better cache semantics | Python servers, dev |
| Global install | `pipx install` / `npm i -g` | Runtime + manual upgrades | fast | Explicit | Auditable, but drifts across a fleet | Small teams |
| **OCI image** | `docker run -i --rm img` | Container runtime | ~0.3–1 s | **Digest-pinnable** (`@sha256:…`) | Signable, scannable, SBOM-able | **Production stdio** |
| **Static binary** | `/usr/local/bin/mcp-foo` | nothing | ~10 ms | Explicit | Signable; no runtime CVEs | Locked-down images, Windows |
| **Bundle** (`.mcpb`/`.dxt`) | host installs it | that specific host | fast | Manifest-pinned | Host-managed | One-click install — **single-host only** |
| **Remote (hosted)** | URL in config | network + auth | 0 (already running) | Server-side | Centrally patched | **Production, at scale** |

### 6.2 The `npx @latest` problem

This configuration appears in thousands of READMEs:

```json
{
  "mcpServers": {
    "inventory": {
      "command": "npx",
      "args": ["-y", "@acme/mcp-inventory"]
    }
  }
}
```

It means: *on every start, fetch and execute whatever version of this package was most recently published, by whoever currently holds publish rights, with no review.* That is an unpinned production dependency with arbitrary code execution, running as the user, with access to whatever is in `env`. It is also non-reproducible: two engineers running "the same" config get different code.

The portable, auditable form pins an exact version and, better, moves to a digest-pinned image:

```json
{
  "mcpServers": {
    "inventory": {
      "command": "npx",
      "args": ["-y", "@acme/mcp-inventory@2.1.0"],
      "env": { "ACME_API_BASE": "https://inventory.internal.acme.com" }
    }
  }
}
```

```json
{
  "mcpServers": {
    "inventory": {
      "command": "docker",
      "args": [
        "run", "-i", "--rm",
        "--network", "none",
        "--read-only",
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--env", "ACME_API_TOKEN",
        "ghcr.io/acme/mcp-inventory@sha256:3f1c0d0f0a9f2b5c7e4a1d8b6c9e2f0a4b7d3e5c1a8f6b2d4e7c9a0b3f5d8e1c"
      ],
      "env": { "ACME_API_TOKEN": "${ACME_API_TOKEN}" }
    }
  }
}
```

> Three flags people get wrong on Docker stdio: you need **`-i`** (keep stdin open) and you must **not** pass `-t` (a TTY injects control characters into the JSON-RPC framing), and `--rm` is required or you accumulate one dead container per session. `--network none` only works if the server talks exclusively over stdio; drop it the moment the server needs to reach an API.

### 6.3 A complete, production-grade Dockerfile for a stdio + HTTP server

```dockerfile
# syntax=docker/dockerfile:1.7
FROM node:22-bookworm-slim AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM gcr.io/distroless/nodejs22-debian12:nonroot
WORKDIR /app
COPY --from=build /src/node_modules ./node_modules
COPY --from=build /src/build ./build
COPY --from=build /src/package.json ./package.json

# Dual-mode: MCP_TRANSPORT=stdio (default) or MCP_TRANSPORT=http
ENV MCP_TRANSPORT=stdio \
    MCP_HTTP_PORT=8080 \
    NODE_ENV=production

USER nonroot
EXPOSE 8080
ENTRYPOINT ["/nodejs/bin/node", "build/index.js"]
```

The critical property of this image is that **the same artifact serves both transports**, selected by one environment variable. One image, one digest, one CVE scan, one SBOM — deployed to Kubernetes as an HTTP service and pulled to laptops as a stdio subprocess. That is packaging portability made concrete.

### 6.4 Registry and `server.json`

The official MCP Registry provides a vendor-neutral metadata catalogue: what the server is called, who publishes it, which package formats exist, and which remote endpoints it offers. It is a **discovery and metadata** layer — it does not host or execute code, and subregistries (internal catalogues, host-curated lists) are expected to mirror and filter it.

A complete `server.json`:

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-07-09/server.schema.json",
  "name": "com.acme/inventory",
  "description": "Read and reserve warehouse inventory across Acme distribution centres.",
  "status": "active",
  "version": "2.1.0",
  "repository": {
    "url": "https://github.com/acme/mcp-inventory",
    "source": "github"
  },
  "websiteUrl": "https://developer.acme.com/mcp/inventory",
  "packages": [
    {
      "registryType": "oci",
      "registryBaseUrl": "https://ghcr.io",
      "identifier": "acme/mcp-inventory",
      "version": "2.1.0",
      "transport": { "type": "stdio" },
      "environmentVariables": [
        {
          "name": "ACME_API_TOKEN",
          "description": "Acme platform API token with scope inventory:read",
          "isRequired": true,
          "isSecret": true
        },
        {
          "name": "ACME_API_BASE",
          "description": "Base URL of the inventory API",
          "isRequired": false,
          "default": "https://inventory.acme.com"
        }
      ]
    },
    {
      "registryType": "npm",
      "registryBaseUrl": "https://registry.npmjs.org",
      "identifier": "@acme/mcp-inventory",
      "version": "2.1.0",
      "transport": { "type": "stdio" },
      "environmentVariables": [
        {
          "name": "ACME_API_TOKEN",
          "description": "Acme platform API token with scope inventory:read",
          "isRequired": true,
          "isSecret": true
        }
      ]
    }
  ],
  "remotes": [
    {
      "type": "streamable-http",
      "url": "https://mcp.acme.com/inventory/mcp",
      "headers": [
        {
          "name": "X-Acme-Tenant",
          "description": "Tenant slug; omit for the token's default tenant",
          "isRequired": false
        }
      ]
    }
  ]
}
```

Note the shape of the portability claim this document makes: *the same logical server* is available as an OCI image, an npm package **and** a hosted remote. A host picks whichever it can run. That is the correct publishing posture for anything you expect to be consumed by more than one host.

**Namespace verification** is the anti-squatting control. `io.github.<owner>/<name>` is proven by authenticating as that GitHub owner; `com.acme/<name>` is proven by a DNS TXT record on `acme.com`. Publishing:

```
$ mcp-publisher init
✔ Created server.json from detected project metadata (npm: @acme/mcp-inventory)

$ mcp-publisher login dns --domain acme.com --private-key "$MCP_DNS_KEY"
✔ Verified TXT record _mcp-registry.acme.com
✔ Authenticated for namespace com.acme/*

$ mcp-publisher publish
✔ Validated server.json against schema 2025-07-09
✔ Published com.acme/inventory@2.1.0
  https://registry.modelcontextprotocol.io/v0/servers?search=com.acme/inventory
```

Querying it back — note this is JSON Lines–style piped output, not a single document, so it is deliberately shown untagged:

```
$ curl -s 'https://registry.modelcontextprotocol.io/v0/servers?search=inventory&limit=2' \
    | jq -r '.servers[] | [.name, .version, (.remotes[0].url // "-")] | @tsv'
com.acme/inventory	2.1.0	https://mcp.acme.com/inventory/mcp
io.github.someone/inventory-lite	0.3.1	-
```

> **`.mcpb` / `.dxt` bundles** are a single-file packaging format for one-click install into a specific desktop host. They are genuinely useful for non-technical users and they are, by construction, **not portable** — a bundle is host-specific packaging around a portable server. Ship one *in addition to* an OCI image or npm package, never instead of.

---

## 7. Axis A4 — Configuration portability

### 7.1 The fragmentation, precisely

The protocol standardises the wire. It does **not** standardise how a host is told a server exists. This is the most-encountered portability tax in day-to-day work.

| Host | File | Top-level key | Remote server declaration | Variable interpolation |
|---|---|---|---|---|
| Claude Desktop | `claude_desktop_config.json` (per-OS app data dir) | `mcpServers` | via connector UI / bundle | limited |
| Claude Code | `.mcp.json` (project) / user + local scopes | `mcpServers` | `"type": "http"` + `url` + `headers` | `${VAR}`, `${VAR:-default}` |
| VS Code | `.vscode/mcp.json` (workspace), user `mcp.json` | **`servers`** (+ `inputs`) | `"type": "http"` + `url` | `${input:id}`, `${env:VAR}`, `${workspaceFolder}` |
| Cursor | `.cursor/mcp.json` / `~/.cursor/mcp.json` | `mcpServers` | `url` | limited |
| Zed | `settings.json` | `context_servers` | varies | editor variables |
| Custom agent | yours | yours | yours | yours |

Two structural incompatibilities to internalise: **VS Code's key is `servers`, not `mcpServers`**, and VS Code adds an `inputs` array so secrets are prompted rather than stored. Everything else is cosmetic by comparison.

### 7.2 The same server, six ways

`.mcp.json` — Claude Code, project scope, checked into the repo:

```json
{
  "mcpServers": {
    "inventory": {
      "type": "stdio",
      "command": "docker",
      "args": ["run", "-i", "--rm", "-e", "ACME_API_TOKEN", "ghcr.io/acme/mcp-inventory:2.1.0"],
      "env": { "ACME_API_TOKEN": "${ACME_API_TOKEN}" }
    },
    "inventory-remote": {
      "type": "http",
      "url": "https://mcp.acme.com/inventory/mcp",
      "headers": { "X-Acme-Tenant": "${ACME_TENANT:-default}" }
    }
  }
}
```

`.vscode/mcp.json` — note the different top-level key and the `inputs` prompt:

```json
{
  "inputs": [
    {
      "id": "acme-token",
      "type": "promptString",
      "description": "Acme API token (scope inventory:read)",
      "password": true
    }
  ],
  "servers": {
    "inventory": {
      "type": "stdio",
      "command": "docker",
      "args": ["run", "-i", "--rm", "-e", "ACME_API_TOKEN", "ghcr.io/acme/mcp-inventory:2.1.0"],
      "env": { "ACME_API_TOKEN": "${input:acme-token}" }
    },
    "inventory-remote": {
      "type": "http",
      "url": "https://mcp.acme.com/inventory/mcp"
    }
  }
}
```

`claude_desktop_config.json` — Claude Desktop, user scope:

```json
{
  "mcpServers": {
    "inventory": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "-e", "ACME_API_TOKEN", "ghcr.io/acme/mcp-inventory:2.1.0"],
      "env": { "ACME_API_TOKEN": "sk-acme-REPLACE-ME" }
    }
  }
}
```

That last file is exactly where secrets end up in plaintext on 400 laptops. It is the strongest single argument for the remote/bridge architecture in §4.3.

### 7.3 One source of truth, rendered per host

Stop hand-maintaining six files. Keep one declarative inventory and generate. This is ordinary platform engineering applied to a problem people keep solving by copy-paste.

`mcp-inventory.yaml` — the source of truth:

```yaml
# Single source of truth for the Acme MCP tool plane.
# Rendered per host by scripts/render-mcp-config.py.
apiVersion: acme.com/v1
kind: MCPServerSet
metadata:
  name: platform-default
  owner: platform-tools@acme.com
servers:
  - name: inventory
    description: "Read and reserve warehouse inventory"
    image: "ghcr.io/acme/mcp-inventory@sha256:3f1c0d0f0a9f2b5c7e4a1d8b6c9e2f0a4b7d3e5c1a8f6b2d4e7c9a0b3f5d8e1c"
    remote: "https://mcp.acme.com/inventory/mcp"
    preferred_transport: remote
    secrets:
      - env: ACME_API_TOKEN
        description: "Acme API token, scope inventory:read"
        source: vault
        path: "secret/data/platform/mcp/inventory#token"
    audience:
      - engineering
      - support

  - name: runbooks
    description: "Search and render the SRE runbook corpus"
    image: "ghcr.io/acme/mcp-runbooks@sha256:9b2e1c7a4f6d0b8e3c5a2f9d1e7b4c0a8f6d3b1e9c7a5f2d0b8e6c4a2f0d9b7e"
    remote: "https://mcp.acme.com/runbooks/mcp"
    preferred_transport: remote
    secrets: []
    audience:
      - engineering
      - sre

  - name: local-fs
    description: "Filesystem access scoped to the current workspace"
    image: "ghcr.io/acme/mcp-filesystem@sha256:1d4f7b2e9c0a6f3d8b5e2c7a4f1d9b6e3c0a8f5d2b7e4c1a9f6d3b0e8c5a2f7d"
    remote: null
    preferred_transport: stdio
    secrets: []
    audience:
      - engineering
```

The renderer emits each host's dialect from that one file, so a version bump is one commit and a `make mcp-config` on every workstation, not six manual edits times four hundred people.

```
$ ./scripts/render-mcp-config.py --host vscode   --audience engineering --out .vscode/mcp.json
rendered 3 servers -> .vscode/mcp.json  (key=servers, inputs=1)

$ ./scripts/render-mcp-config.py --host claude-code --audience engineering --out .mcp.json
rendered 3 servers -> .mcp.json  (key=mcpServers, interpolation=${VAR})

$ ./scripts/render-mcp-config.py --host claude-desktop --audience support \
    --out "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
rendered 1 server -> /Users/jdoe/Library/Application Support/Claude/claude_desktop_config.json
warning: host 'claude-desktop' has no secret-reference support; emitted env placeholder for ACME_API_TOKEN
```

That warning line is the design working. The tool tells you exactly where portability is lost and why, instead of silently writing a secret to disk.

### 7.4 Host CLIs

Most hosts expose a CLI, which is both easier to automate and far less error-prone than editing JSON by hand.

```
$ claude mcp add --transport http inventory https://mcp.acme.com/inventory/mcp
Added HTTP MCP server inventory with URL: https://mcp.acme.com/inventory/mcp to local config

$ claude mcp list
Checking MCP server health...

inventory: https://mcp.acme.com/inventory/mcp (HTTP) - ✓ Connected
runbooks: https://mcp.acme.com/runbooks/mcp (HTTP) - ✓ Connected
local-fs: docker run -i --rm ghcr.io/acme/mcp-filesystem:1.4.0 - ✓ Connected

$ claude mcp get inventory
inventory:
  Scope: Local config (private to you in this project)
  Type: http
  URL: https://mcp.acme.com/inventory/mcp
  Status: ✓ Connected
```

```
$ code --add-mcp '{"name":"inventory","type":"http","url":"https://mcp.acme.com/inventory/mcp"}'
```

---

## 8. Axis A5 and the platform: deploying a portable remote MCP server

### 8.1 Complete Kubernetes manifest set

This is the vendor-neutral deployment. It uses only upstream Kubernetes and Gateway API, which is itself the portability point: it runs on any conformant cluster.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-platform
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    app.kubernetes.io/part-of: acme-tool-plane
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-inventory
  namespace: mcp-platform
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-inventory-config
  namespace: mcp-platform
data:
  MCP_TRANSPORT: "http"
  MCP_HTTP_PORT: "8080"
  MCP_HTTP_PATH: "/mcp"
  MCP_STATELESS: "true"
  MCP_LOG_LEVEL: "info"
  MCP_LOG_FORMAT: "json"
  ACME_API_BASE: "https://inventory.internal.acme.com"
  # Allowed Origin values. DNS-rebinding protection is mandatory for HTTP
  # transports; a wildcard here is quoted because YAML reads a bare
  # leading '*' as an alias anchor.
  MCP_ALLOWED_ORIGINS: "https://chat.acme.com,https://ide.acme.com"
  MCP_OAUTH_ISSUER: "https://auth.acme.com/realms/platform"
  MCP_OAUTH_AUDIENCE: "https://mcp.acme.com/inventory/mcp"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-inventory
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: mcp-inventory
    app.kubernetes.io/component: mcp-server
    app.kubernetes.io/version: "2.1.0"
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-inventory
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-inventory
        app.kubernetes.io/component: mcp-server
        app.kubernetes.io/version: "2.1.0"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: mcp-inventory
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
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-inventory
      containers:
        - name: server
          image: "ghcr.io/acme/mcp-inventory@sha256:3f1c0d0f0a9f2b5c7e4a1d8b6c9e2f0a4b7d3e5c1a8f6b2d4e7c9a0b3f5d8e1c"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          envFrom:
            - configMapRef:
                name: mcp-inventory-config
          env:
            - name: ACME_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: mcp-inventory-secrets
                  key: acme-api-token
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
            - name: OTEL_SERVICE_NAME
              value: "mcp-inventory"
          # The MCP endpoint is NOT a health endpoint: it is POST-only and
          # header-sensitive, so a GET probe against /mcp returns 405 or 406
          # and the pod never becomes ready. Probe a dedicated path.
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              cpu: "1"
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          lifecycle:
            preStop:
              exec:
                # Drain in-flight SSE streams before the process is signalled.
                command: ["/bin/sh", "-c", "sleep 10"]
      terminationGracePeriodSeconds: 45
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-inventory
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: mcp-inventory
spec:
  type: ClusterIP
  # Deliberately NOT sessionAffinity: ClientIP. Behind corporate NAT every
  # user shares a source address, which collapses onto one replica. The
  # server runs stateless (MCP_STATELESS=true) so no affinity is needed.
  selector:
    app.kubernetes.io/name: mcp-inventory
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
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: mcp-inventory
  namespace: mcp-platform
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-inventory
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: mcp-inventory
  namespace: mcp-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: mcp-inventory
  minReplicas: 3
  maxReplicas: 20
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
          averageValue: "120"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mcp-inventory
  namespace: mcp-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mcp-inventory
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: gateway-system
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
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 4317
    # Upstream inventory API and the OAuth issuer, reached over the mesh egress.
    - to:
        - ipBlock:
            cidr: 10.64.0.0/16
      ports:
        - protocol: TCP
          port: 443
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-inventory
  namespace: mcp-platform
spec:
  parentRefs:
    - name: acme-public
      namespace: gateway-system
      sectionName: https
  hostnames:
    - "mcp.acme.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /inventory/mcp
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /mcp
        # MCP-Protocol-Version and Mcp-Session-Id MUST survive the gateway.
        # Header allow-lists that strip them silently downgrade every session
        # to the 2025-03-26 fallback or break session continuity.
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add:
              - name: X-Acme-Edge
                value: "acme-public"
      backendRefs:
        - name: mcp-inventory
          port: 80
          weight: 100
      timeouts:
        # SSE streams are long-lived. A default 30 s route timeout will sever
        # every server-initiated notification stream mid-session.
        request: 0s
        backendRequest: 0s
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mcp-inventory
  namespace: mcp-platform
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-inventory
  namespaceSelector:
    matchNames:
      - mcp-platform
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-inventory
  namespace: mcp-platform
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp-inventory.portability
      rules:
        - alert: MCPProtocolVersionDowngrade
          expr: |
            sum(rate(mcp_sessions_initialized_total{negotiated_version!="2025-06-18"}[15m]))
              /
            sum(rate(mcp_sessions_initialized_total[15m]))
              > 0.05
          for: 15m
          labels:
            severity: warning
            team: platform-tools
          annotations:
            summary: "Over 5% of MCP sessions negotiated an older protocol revision"
            description: >-
              Clients are negotiating below 2025-06-18. Common causes: a gateway
              stripping the MCP-Protocol-Version header, or an outdated host
              rolling out. Check the header allow-list on the acme-public Gateway.
            runbook_url: "https://runbooks.acme.com/mcp/protocol-downgrade"

        - alert: MCPSessionNotFoundRateHigh
          expr: |
            sum(rate(mcp_http_requests_total{code="404"}[5m]))
              /
            sum(rate(mcp_http_requests_total[5m]))
              > 0.02
          for: 10m
          labels:
            severity: warning
            team: platform-tools
          annotations:
            summary: "MCP clients are hitting expired sessions"
            description: >-
              A 404 on an Mcp-Session-Id forces the client to re-initialize.
              Sustained rates indicate replica churn with a stateful server, or
              a load balancer routing session traffic to the wrong replica.
            runbook_url: "https://runbooks.acme.com/mcp/session-expiry"

        - alert: MCPToolErrorRateHigh
          expr: |
            sum by (tool) (rate(mcp_tool_calls_total{result="error"}[5m]))
              /
            sum by (tool) (rate(mcp_tool_calls_total[5m]))
              > 0.10
          for: 10m
          labels:
            severity: critical
            team: platform-tools
          annotations:
            summary: "MCP tool {{ $labels.tool }} is failing above 10%"
            runbook_url: "https://runbooks.acme.com/mcp/tool-errors"
```

> **Block-scalar discipline:** every `expr: |` above keeps all lines — including the bare `/` operators of the PromQL division — at the same indentation. A single less-indented line terminates the scalar and produces a YAML document that either fails to parse or, worse, parses into a silently truncated expression.

### 8.2 Vendor-specific abstractions: the trade-off

Several projects offer a higher-level abstraction — a CRD that turns "an MCP server" into a first-class Kubernetes object, handling sandboxing, secret injection and gateway registration for you.

```yaml
# VENDOR-SPECIFIC. Verify apiVersion and field names against the operator
# version you actually install; CRDs are the least portable layer here.
apiVersion: toolhive.stacklok.dev/v1alpha1
kind: MCPServer
metadata:
  name: inventory
  namespace: mcp-platform
spec:
  image: "ghcr.io/acme/mcp-inventory:2.1.0"
  transport: streamable-http
  port: 8080
  permissionProfile:
    type: builtin
    name: network
  podTemplateSpec:
    spec:
      containers:
        - name: mcp
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              cpu: "1"
              memory: 512Mi
  secrets:
    - name: mcp-inventory-secrets
      key: acme-api-token
      targetEnvName: ACME_API_TOKEN
```

| Approach | Portability | Operational cost | When to choose |
|---|---|---|---|
| Plain Deployment + Service + HTTPRoute | **Highest** — runs on any conformant cluster | You write and maintain the boilerplate | Regulated or multi-cloud estates; anything that must outlive a vendor |
| Operator CRD | Cluster-bound; migration means rewriting manifests | Lowest per-server effort; sandboxing included | Many servers, one cluster, stable vendor relationship |
| Managed MCP gateway (SaaS) | Lowest | Near-zero | Small teams without a platform function |

The honest recommendation for a platform team: **keep the server image vendor-neutral and let the deployment abstraction be whatever your cluster already uses.** The image is the portable artifact; the CRD is not. Losing a vendor should cost you a Helm chart rewrite, never a rebuild of 31 servers.

### 8.3 Sticky sessions when you genuinely need them

If a server cannot be stateless — it holds subscriptions, long-running work or a warm cache — hash on the session header, never the client IP.

```yaml
# Istio: consistent hashing on the MCP session header.
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: mcp-inventory
  namespace: mcp-platform
spec:
  host: mcp-inventory.mcp-platform.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpHeaderName: "Mcp-Session-Id"
    connectionPool:
      http:
        h2UpgradePolicy: UPGRADE
        idleTimeout: 600s
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 60s
```

Even then, understand the residual failure mode: consistent hashing gives you affinity, not durability. Losing a replica still destroys its sessions, and every affected client must re-`initialize`. If that is unacceptable, you need a shared session store — which is a real distributed-systems commitment, not a config flag.

---

## 9. Verification and failure diagnosis

### 9.1 The verification ladder

Diagnose in this order. Each rung is cheap and eliminates a whole class of causes. Skipping rungs is how people spend an afternoon debugging a host UI when the binary was never on `PATH`.

| # | Question | Command | Cost |
|---|---|---|---|
| 1 | Does the artifact exist and execute? | `docker run --rm IMG --version` / `which mcp-foo` | free |
| 2 | Does it start and stay up? | run it, watch stderr | free |
| 3 | Does it complete `initialize`, and at which revision? | raw JSON-RPC over stdio, or `curl` | free |
| 4 | Does it list the tools you expect, with valid schemas? | Inspector `--cli --method tools/list` | free |
| 5 | Does a tool call actually work? | Inspector `--cli --method tools/call` | free |
| 6 | Does the **host** see it? | host CLI (`claude mcp list`) / host logs | free |
| 7 | Does it behave identically over the other transport? | conformance harness (§9.6) | free |
| 8 | Does the model choose it correctly? | evaluation set | model calls |

### 9.2 Rung 3 — the raw handshake

This is the ground truth. No host, no SDK, no UI. If this works, the server is not the problem.

```
$ printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.0.1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | docker run -i --rm -e ACME_API_TOKEN ghcr.io/acme/mcp-inventory:2.1.0 2>/tmp/mcp.err \
  | jq -c 'if .id == 1 then {v: .result.protocolVersion, server: .result.serverInfo.name, caps: (.result.capabilities | keys)} else {tools: [.result.tools[].name]} end'
{"v":"2025-06-18","server":"com.acme/inventory","caps":["completions","logging","prompts","resources","tools"]}
{"tools":["inventory_search","inventory_reserve","inventory_release"]}

$ cat /tmp/mcp.err
{"level":"info","ts":"2026-09-18T09:14:22.104Z","msg":"server started","transport":"stdio","version":"2.1.0"}
```

Two things to read off that output deliberately:

- **`"v":"2025-06-18"`** — the negotiated revision, confirmed, not assumed.
- **stderr contains structured logs and stdout contains only JSON-RPC.** That separation is not stylistic. It is a hard requirement of the stdio transport.

### 9.3 Rung 3 over HTTP

```
$ curl -sD - -o /tmp/body.txt -X POST https://mcp.acme.com/inventory/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.0.1"}}}'
HTTP/2 200
content-type: application/json
mcp-session-id: 1868a90c-5b1f-4c3e-9a8b-3b7f6a2d11e4
x-acme-edge: acme-public

$ jq -r '.result.protocolVersion, .result.serverInfo.name' /tmp/body.txt
2025-06-18
com.acme/inventory
```

And the unauthenticated probe, which must advertise where to get a token:

```
$ curl -sD - -o /dev/null -X POST https://mcp.acme.com/inventory/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
HTTP/2 401
www-authenticate: Bearer resource_metadata="https://mcp.acme.com/.well-known/oauth-protected-resource/inventory/mcp"

$ curl -s https://mcp.acme.com/.well-known/oauth-protected-resource/inventory/mcp | jq
```
```json
{
  "resource": "https://mcp.acme.com/inventory/mcp",
  "authorization_servers": [
    "https://auth.acme.com/realms/platform"
  ],
  "scopes_supported": [
    "inventory:read",
    "inventory:write"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

A missing `WWW-Authenticate` header on a 401 is a portability bug even though the server "works": a conformant client cannot discover the authorization server, so it cannot complete the flow without hand-configuration. Test for the header, not just the status code.

### 9.4 Rung 4–5 — MCP Inspector in CLI mode

The Inspector's UI mode is for exploration; **CLI mode is what you put in CI**.

```
$ npx -y @modelcontextprotocol/inspector --cli \
    docker run -i --rm -e ACME_API_TOKEN ghcr.io/acme/mcp-inventory:2.1.0 \
    --method tools/list
```
```json
{
  "tools": [
    {
      "name": "inventory_search",
      "title": "Search inventory",
      "description": "Search warehouse inventory by SKU, name or distribution centre.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "sku": { "type": "string", "description": "Exact SKU, e.g. ACM-4410-BLK" },
          "query": { "type": "string", "description": "Free-text product name fragment" },
          "dc": { "type": "string", "description": "Distribution centre code, e.g. EU-FRA-01" },
          "limit": { "type": "integer", "minimum": 1, "maximum": 200, "default": 25 }
        },
        "additionalProperties": false
      },
      "annotations": {
        "readOnlyHint": true,
        "idempotentHint": true,
        "openWorldHint": true
      }
    }
  ]
}
```

```
$ npx -y @modelcontextprotocol/inspector --cli \
    https://mcp.acme.com/inventory/mcp --transport http \
    --header "Authorization: Bearer $TOKEN" \
    --method tools/call --tool-name inventory_search \
    --tool-arg sku=ACM-4410-BLK
```
```json
{
  "content": [
    {
      "type": "text",
      "text": "ACM-4410-BLK  Acme Rack Rail 4U (black)  EU-FRA-01: 142  US-IAD-02: 7  reserved: 3"
    }
  ],
  "structuredContent": {
    "items": [
      { "sku": "ACM-4410-BLK", "dc": "EU-FRA-01", "available": 142, "reserved": 3 },
      { "sku": "ACM-4410-BLK", "dc": "US-IAD-02", "available": 7, "reserved": 0 }
    ],
    "count": 2
  },
  "isError": false
}
```

Note that the result carries **both** `content` (portable to every revision) and `structuredContent` (only meaningful from `2025-06-18`). Emitting both is the correct portable behaviour: old clients read the text, new clients read the structure.

### 9.5 Failure catalogue

This table is the one to memorise. Nearly every field report maps to a row.

| Symptom | Root cause | Diagnostic | Fix |
|---|---|---|---|
| Host shows "server failed to start"; works in your terminal | GUI-launched hosts do not inherit your shell `PATH` (no `.zshrc`/`.bashrc` sourced) | `which node` in a terminal vs. absolute path in config | Use an **absolute path** to the interpreter, or `docker` with an absolute path |
| Session dies immediately after start, no error | Server wrote non-JSON-RPC output to **stdout** (a banner, `print()`, a progress bar, a dependency's warning) | `printf … \| server 2>/dev/null \| head -c 200` — is the first byte `{`? | Send **all** logging to stderr; audit transitive dependencies for stray stdout writes |
| `406 Not Acceptable` on POST | Missing or incomplete `Accept` header | `curl -v`, inspect request headers | Send `Accept: application/json, text/event-stream` |
| `400 Bad Request` after the first successful call | `MCP-Protocol-Version` missing or unsupported | Compare the header sent against the negotiated revision | Echo the negotiated revision on every request; stop proxies stripping it |
| Features silently missing (no elicitation, no structured output) | Gateway stripped `MCP-Protocol-Version` → server fell back to `2025-03-26` | Check the `negotiated_version` metric label; inspect the gateway header allow-list | Allow-list the header explicitly at every hop |
| `404` on every request after `initialize` | Session expired, or the LB routed to a different replica | `Mcp-Session-Id` present? Same pod each time? | Go stateless, or hash on the session header (§8.3) |
| `405 Method Not Allowed` on `GET /mcp` | Server does not offer a server-initiated SSE stream — **often legitimate** | Does the server need to push notifications? | If not, ignore. If yes, implement the `GET` handler |
| Pods never become ready | Readiness probe points at `/mcp`, which is POST-only | `kubectl describe pod` → probe returns 405/406 | Expose a dedicated `/healthz` and `/readyz` |
| SSE stream cut at a round 30 s or 60 s | Proxy/route request timeout | Gateway access log shows the upstream reset | Set `timeouts.request: 0s` on the HTTPRoute; raise the idle timeout |
| `spawn npx ENOENT` on Windows | Windows requires the shell wrapper for `npx` | Try the command in `cmd.exe` | `"command": "cmd"`, `"args": ["/c", "npx", "-y", "@acme/mcp-inventory@2.1.0"]` |
| Docker stdio server garbles messages | `-t` allocated a TTY; control characters corrupt the framing | Inspect raw bytes on stdout | Use `-i` only; never `-it` |
| Worked yesterday, broken today, nothing changed | Unpinned `npx`/`uvx` pulled a new version overnight | `npm view @acme/mcp-inventory versions` and compare publish dates | Pin exact versions; prefer digest-pinned images |
| Tool hangs forever on one host only | Server called `sampling/createMessage` without checking `capabilities.sampling` | Compare the client `capabilities` object across hosts | Feature-detect and degrade (§5.3) |
| Server invisible in VS Code, fine in Claude Code | Config used `mcpServers` where VS Code expects `servers` | Inspect `.vscode/mcp.json` top-level key | Render per-host config from one source (§7.3) |
| 401 loop; client never prompts for login | 401 returned without `WWW-Authenticate` / no protected-resource metadata | `curl -D -` on an unauthenticated request | Return `WWW-Authenticate` with `resource_metadata`; serve `/.well-known/oauth-protected-resource` |
| Tokens accepted by the wrong server | Missing audience validation / no Resource Indicator binding | Decode the token's `aud` claim | Validate `aud` against this server's canonical URI; require RFC 8707 `resource` |

### 9.6 A portability conformance harness

Do not test portability by hand. Test it the way you test anything else: an executable suite that runs the **same assertions** against every transport the server claims to support, on every commit.

```python
#!/usr/bin/env python3
"""Portability conformance suite: identical assertions, every transport.

A server is portable when this suite passes over stdio AND Streamable HTTP
with byte-identical tool inventories and schemas.
"""
import asyncio
import json
import os
import sys
from contextlib import asynccontextmanager

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.client.streamable_http import streamablehttp_client

EXPECTED_TOOLS = {"inventory_search", "inventory_reserve", "inventory_release"}
MIN_REVISION = "2025-06-18"


@asynccontextmanager
async def open_stdio(image: str):
    params = StdioServerParameters(
        command="docker",
        args=["run", "-i", "--rm", "-e", "ACME_API_TOKEN", image],
        env={"ACME_API_TOKEN": os.environ["ACME_API_TOKEN"]},
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            yield session


@asynccontextmanager
async def open_http(url: str):
    headers = {"Authorization": f"Bearer {os.environ['ACME_TOKEN']}"}
    async with streamablehttp_client(url, headers=headers) as (read, write, _sid):
        async with ClientSession(read, write) as session:
            yield session


async def probe(session: ClientSession) -> dict:
    """Run the invariant assertions and return a comparable fingerprint."""
    init = await session.initialize()
    assert init.protocolVersion >= MIN_REVISION, (
        f"negotiated {init.protocolVersion}, expected >= {MIN_REVISION}"
    )

    tools = await session.list_tools()
    names = {t.name for t in tools.tools}
    assert names == EXPECTED_TOOLS, f"tool drift: {names ^ EXPECTED_TOOLS}"

    for t in tools.tools:
        assert t.description, f"{t.name} has no description"
        assert t.inputSchema.get("type") == "object", f"{t.name} schema is not an object"

    result = await session.call_tool("inventory_search", {"sku": "ACM-4410-BLK"})
    assert not result.isError, f"inventory_search failed: {result.content}"
    assert result.content, "empty content block: breaks pre-2025-06-18 clients"

    return {
        "protocolVersion": init.protocolVersion,
        "serverName": init.serverInfo.name,
        "capabilities": sorted(k for k, v in init.capabilities if v is not None),
        "tools": sorted(
            {"name": t.name, "schema": t.inputSchema} for t in tools.tools
        ),
    }


async def main() -> int:
    image = os.environ.get("MCP_IMAGE", "ghcr.io/acme/mcp-inventory:2.1.0")
    url = os.environ.get("MCP_URL", "https://mcp.acme.com/inventory/mcp")

    async with open_stdio(image) as s:
        via_stdio = await probe(s)
    async with open_http(url) as s:
        via_http = await probe(s)

    drift = {
        k: (via_stdio[k], via_http[k])
        for k in via_stdio
        if k != "protocolVersion" and via_stdio[k] != via_http[k]
    }
    if drift:
        print("TRANSPORT DRIFT DETECTED", file=sys.stderr)
        print(json.dumps(drift, indent=2, default=str), file=sys.stderr)
        return 1

    print(f"OK  stdio={via_stdio['protocolVersion']}  http={via_http['protocolVersion']}")
    print(f"OK  {len(via_stdio['tools'])} tools identical across both transports")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
```

```
$ ./scripts/conformance.py
OK  stdio=2025-06-18  http=2025-06-18
OK  3 tools identical across both transports

$ MCP_IMAGE=ghcr.io/acme/mcp-inventory:2.2.0-rc1 ./scripts/conformance.py
TRANSPORT DRIFT DETECTED
{
  "tools": [
    [{"name": "inventory_reserve", "schema": {"type": "object", "properties": {"sku": {"type": "string"}, "qty": {"type": "integer"}}}}],
    [{"name": "inventory_reserve", "schema": {"type": "object", "properties": {"sku": {"type": "string"}, "quantity": {"type": "integer"}}}}]
  ]
}
$ echo $?
1
```

That drift is a real class of bug: the HTTP entrypoint had been refactored and the stdio entrypoint registered an older tool module. The suite caught a rename (`qty` → `quantity`) that would have broken every stdio user while every HTTP user saw nothing wrong.

### 9.7 Wiring it into CI

```yaml
name: mcp-portability

on:
  push:
    branches: [main]
  pull_request:
  schedule:
    # Catch upstream host and SDK drift even when nothing in this repo changes.
    - cron: "0 6 * * 1"

permissions:
  contents: read
  packages: read

jobs:
  conformance:
    name: "conformance (${{ matrix.transport }} / ${{ matrix.revision }})"
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        transport: [stdio, http]
        revision: ["2025-06-18", "2025-03-26"]
    env:
      MCP_IMAGE: "ghcr.io/acme/mcp-inventory:${{ github.sha }}"
      MCP_PROTOCOL_VERSION: "${{ matrix.revision }}"
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install harness dependencies
        run: pip install --require-hashes -r requirements-conformance.txt

      - name: Build image
        run: docker build -t "$MCP_IMAGE" .

      - name: Start server (http transport only)
        if: matrix.transport == 'http'
        run: |
          docker run -d --name mcp -p 8080:8080 \
            -e MCP_TRANSPORT=http \
            -e MCP_HTTP_PORT=8080 \
            -e MCP_STATELESS=true \
            -e ACME_API_TOKEN="${{ secrets.ACME_API_TOKEN }}" \
            "$MCP_IMAGE"
          for i in $(seq 1 30); do
            curl -sf http://localhost:8080/healthz && break
            sleep 1
          done

      - name: Run conformance suite
        env:
          ACME_API_TOKEN: "${{ secrets.ACME_API_TOKEN }}"
          ACME_TOKEN: "${{ secrets.ACME_API_TOKEN }}"
          MCP_URL: "http://localhost:8080/mcp"
        run: ./scripts/conformance.py

      - name: Validate registry metadata
        run: |
          npx -y ajv-cli validate \
            -s schemas/server.schema.json \
            -d server.json

      - name: Assert every published package version matches the release
        run: ./scripts/check-version-consistency.sh

      - name: Dump server logs on failure
        if: failure() && matrix.transport == 'http'
        run: docker logs mcp
```

The scheduled Monday run is not decoration. Portability regressions are frequently caused by things outside your repository — a host update, an SDK release, a registry schema bump. A suite that only runs on your commits cannot see them.

### 9.8 Observability contract for a portable server

Emit these regardless of transport, and label by the dimensions that actually vary:

| Signal | Labels that matter | Why |
|---|---|---|
| `mcp_sessions_initialized_total` | `negotiated_version`, `client_name`, `client_version`, `transport` | Detects downgrade and tells you which host fleet is behind |
| `mcp_tool_calls_total` | `tool`, `result`, `negotiated_version` | Per-tool SLO; correlates failures with revision |
| `mcp_tool_duration_seconds` (histogram) | `tool` | Latency SLO — agents time out long before humans do |
| `mcp_http_requests_total` | `code`, `method` | Surfaces the 404/406/400 families from §9.5 |
| `mcp_active_sessions` (gauge) | `transport` | HPA input; leak detection |
| Structured log line per tool call | `session_id`, `request_id`, `tool`, `traceparent` | Ties an agent action to an upstream API call |

> On stdio there is no L7 anywhere to observe you from, so the server's own telemetry is the *only* signal that exists. That asymmetry — full observability on HTTP, self-reported only on stdio — is a further argument for the bridge architecture of §4.3.

---

## 10. Key takeaways

1. **MCP standardises the wire, not the ecosystem.** Portability failures cluster in transport, capability, packaging, configuration and identity — five axes that fail independently and must be verified independently.
2. **Protocol revisions are dates, negotiated at `initialize`.** The client proposes, the server decides, the client disconnects if the answer is unacceptable. Read the supported set from your SDK; never hardcode it from memory.
3. **On HTTP, `MCP-Protocol-Version` is mandatory after initialization, and its absence means `2025-03-26`.** A header-stripping proxy is therefore a silent feature-downgrade machine.
4. **stdio is maximally portable and minimally operable; Streamable HTTP is the reverse.** The production answer is one central HTTP deployment plus stdio bridges, not a choice between them.
5. **Never make a client capability a hard dependency.** Sampling, roots and elicitation are unevenly implemented. Feature-detect at `initialize` and degrade deliberately.
6. **`sessionAffinity: ClientIP` is the wrong answer for MCP sessions.** Run stateless, or hash on `Mcp-Session-Id`.
7. **Publish the same server in several formats** — OCI image, language package, hosted remote — and pin by digest. `npx @latest` in a configuration file is an unreviewed production dependency.
8. **Config fragmentation is real** (`mcpServers` vs `servers`, differing interpolation). Solve it with one source of truth and a renderer, not by hand-editing six files.
9. **The MCP endpoint is not a health endpoint.** Expose `/healthz` and `/readyz`, and disable route timeouts on SSE paths.
10. **Portability is testable.** Run identical assertions over every transport, in CI, on a schedule — because the causes of regression often live outside your repository.

---

## 11. References

**Specification and protocol**

- Model Context Protocol — specification index: https://modelcontextprotocol.io/specification/2025-06-18
- Protocol versioning and revision list: https://modelcontextprotocol.io/specification/versioning
- Lifecycle and `initialize` handshake: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- Transports (stdio, Streamable HTTP): https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Authorization: https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- Changelog of protocol revisions: https://modelcontextprotocol.io/specification/2025-06-18/changelog
- Specification repository and SEP process: https://github.com/modelcontextprotocol/modelcontextprotocol

**Ecosystem, SDKs and tooling**

- Documentation home: https://modelcontextprotocol.io
- Client feature-support matrix (the authoritative capability table): https://modelcontextprotocol.io/clients
- SDK index: https://modelcontextprotocol.io/docs/sdk
- TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk
- Python SDK: https://github.com/modelcontextprotocol/python-sdk
- Go SDK: https://github.com/modelcontextprotocol/go-sdk
- Reference servers: https://github.com/modelcontextprotocol/servers
- MCP Inspector: https://github.com/modelcontextprotocol/inspector

**Registry and distribution**

- Official MCP Registry: https://github.com/modelcontextprotocol/registry
- `server.json` reference: https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/api/server-json.md
- Publishing guide and namespace verification: https://github.com/modelcontextprotocol/registry/blob/main/docs/guides/publishing/publish-server.md
- MCP Bundles (`.mcpb`, formerly `.dxt`): https://github.com/anthropics/mcpb

**Host configuration**

- Claude Code — MCP configuration and scopes: https://docs.claude.com/en/docs/claude-code/mcp
- Claude Desktop / connectors: https://modelcontextprotocol.io/quickstart/user
- VS Code — MCP servers in the workspace (`servers` key, `inputs`): https://code.visualstudio.com/docs/copilot/customization/mcp-servers

**Platform and infrastructure**

- Kubernetes — configure liveness, readiness and startup probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — network policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Horizontal Pod Autoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Gateway API — HTTPRoute: https://gateway-api.sigs.k8s.io/api-types/httproute/
- Istio — DestinationRule (consistent hashing): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Prometheus Operator — ServiceMonitor and PrometheusRule: https://prometheus-operator.dev/docs/api-reference/api/
- Docker — build and run reference: https://docs.docker.com/reference/cli/docker/container/run/
- ToolHive Kubernetes operator (vendor-specific example): https://docs.stacklok.com/toolhive/guides-k8s/

**Standards referenced by MCP authorization**

- RFC 6749 — OAuth 2.0 Authorization Framework: https://datatracker.ietf.org/doc/html/rfc6749
- RFC 7591 — OAuth 2.0 Dynamic Client Registration: https://datatracker.ietf.org/doc/html/rfc7591
- RFC 7636 — Proof Key for Code Exchange (PKCE): https://datatracker.ietf.org/doc/html/rfc7636
- RFC 8414 — OAuth 2.0 Authorization Server Metadata: https://datatracker.ietf.org/doc/html/rfc8414
- RFC 8707 — Resource Indicators for OAuth 2.0: https://datatracker.ietf.org/doc/html/rfc8707
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: https://datatracker.ietf.org/doc/html/rfc9728
- JSON-RPC 2.0 specification: https://www.jsonrpc.org/specification

**Certification**

- Linux Foundation — Model Context Protocol Associate (MCPA): https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/