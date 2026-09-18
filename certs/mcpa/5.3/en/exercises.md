# 5.3 — Ecosystem & Portability

## Guided Exercises

**Exam domain:** Ecosystem & Portability (6.66% weight) · **Level:** production / architect

The claim this topic makes is easy to say and hard to earn: *write an MCP server once, run it under any host.* These exercises test that claim in the only way that counts — by taking a server that works on your laptop and breaking it on purpose, in each of the four places portability actually fails: **the protocol version**, **the transport**, **the client's capabilities**, and **the configuration envelope the host wraps around your process**.

---

### Prerequisites

| Requirement | Check |
|---|---|
| Node.js ≥ 20 | `node --version` |
| Python ≥ 3.10 + `uv` | `uv --version` |
| `jq` | `jq --version` |
| `curl` ≥ 7.76 | `curl --version` |

```bash
mkdir -p ~/mcpa-5.3 && cd ~/mcpa-5.3
node --version && uv --version && jq --version
```

---

## Exercise 1 — Map the ecosystem before you depend on it

The MCP ecosystem is not one artifact. It is a **specification** (versioned by date), a set of **SDKs** that implement it at different speeds, a set of **reference servers**, a **registry**, an **inspector**, and the **hosts** that embed clients. Portability problems almost always trace back to two of these being at different spec versions.

**Step 1.** Clone the specification repository — it is the normative artifact; the website renders it.

```bash
git clone --depth 1 https://github.com/modelcontextprotocol/modelcontextprotocol.git spec
cd spec
ls docs/specification/
```

Expected (the exact set of dated directories grows over time):

```
2024-11-05/  2025-03-26/  2025-06-18/  draft/
```

**Step 2.** Find the protocol version constant the schema itself declares, and diff two versions to see what "a new version" actually means.

```bash
ls schema/
git log --oneline -5 -- schema/
diff <(ls schema/2025-03-26/) <(ls schema/2025-06-18/) || true
```

**Step 3.** Enumerate the official SDKs and note that they are *separate repositories with separate release cadences*.

```bash
curl -s 'https://api.github.com/orgs/modelcontextprotocol/repos?per_page=100' \
  | jq -r '.[] | select(.name | test("-sdk$")) | "\(.name)\t\(.pushed_at[0:10])\t\(.description)"' \
  | sort
```

Expected shape (names and dates will differ):

```
csharp-sdk      2026-08-30      The official C# SDK for Model Context Protocol
go-sdk          2026-09-02      The official Go SDK for Model Context Protocol
java-sdk        2026-08-27      The official Java SDK for Model Context Protocol
kotlin-sdk      2026-08-11      The official Kotlin SDK for Model Context Protocol
python-sdk      2026-09-05      The official Python SDK for Model Context Protocol
ruby-sdk        2026-08-19      The official Ruby SDK for Model Context Protocol
rust-sdk        2026-09-01      The official Rust SDK for Model Context Protocol
swift-sdk       2026-07-22      The official Swift SDK for Model Context Protocol
typescript-sdk  2026-09-08      The official TypeScript SDK for Model Context Protocol
```

> **Q1.** The specification is versioned `YYYY-MM-DD`, not `MAJOR.MINOR.PATCH`. What does that choice tell you about how breaking changes are communicated, and what does it *fail* to tell you that semver would?
>
> **Q2.** You are choosing an SDK for a server that must support a spec feature released three months ago. Two SDKs both claim "official" status. Which repository-level signals decide the choice, and why is "official" not sufficient?
>
> **Q3.** The spec, the SDKs, the registry, and the inspector live in separate repositories. Name the specific portability failure mode this creates, and the defensive measure a server author takes against it.

---

## Exercise 2 — Version negotiation: the handshake decides portability

MCP is JSON-RPC 2.0. The first message is `initialize`, and it is where client and server agree on a protocol version. Most engineers assume a mismatch produces an error. It does not — and understanding why is the point of this exercise.

**Step 1.** Send a raw `initialize` to a reference server over stdio, claiming a current version.

```bash
cd ~/mcpa-5.3
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"portability-probe","version":"0.1.0"}}}' \
  | npx -y @modelcontextprotocol/server-everything 2>/dev/null \
  | jq -c '.result | {protocolVersion, serverInfo, caps: (.capabilities | keys)}'
```

Expected:

```
{"protocolVersion":"2025-06-18","serverInfo":{"name":"example-servers/everything","version":"1.0.0"},"caps":["completions","logging","prompts","resources","tools"]}
```

**Step 2.** Now claim a version that does not exist. Do **not** expect an error.

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"portability-probe","version":"0.1.0"}}}' \
  | npx -y @modelcontextprotocol/server-everything 2>/dev/null \
  | jq -c '.result.protocolVersion'
```

Expected:

```
"2025-06-18"
```

**Step 3.** Claim an old-but-real version and observe that the server *accepts* it rather than upgrading you.

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"portability-probe","version":"0.1.0"}}}' \
  | npx -y @modelcontextprotocol/server-everything 2>/dev/null \
  | jq -c '.result.protocolVersion'
```

Expected:

```
"2024-11-05"
```

**Step 4.** Read the normative rule you just watched execute.

```bash
sed -n '/protocolVersion/,/^##/p' spec/docs/specification/2025-06-18/basic/lifecycle.mdx | head -40
```

> **Q4.** In Step 2 the server answered `2025-06-18` to a client that asked for `1999-01-01`. Reconstruct the rule: what exactly does a server return when it does not support the requested version, and whose responsibility is it to end the connection?
>
> **Q5.** In Step 3 the server downgraded itself to `2024-11-05`. What is the operational consequence for a server author who has written code assuming a feature added in `2025-06-18`, and where in the server must the guard live?
>
> **Q6.** The handshake is not complete after `initialize` returns. What third message closes it, and why does the spec forbid the client from issuing normal requests before sending it?

---

## Exercise 3 — Transport portability: the same server, two wires

A server's *logic* is transport-agnostic; its *deployment* is not. stdio gives you a subprocess with a private pipe. Streamable HTTP gives you a network endpoint with sessions, resumability, and an entirely new security surface. Portability means the same handler code serves both.

**Step 1.** Start the reference server on its HTTP transport and read the startup line for the real URL.

```bash
npx -y @modelcontextprotocol/server-everything streamableHttp
```

Expected (port may differ — use what it prints):

```
MCP Streamable HTTP Server listening on port 3001
Server is running at http://localhost:3001/mcp
```

**Step 2.** In a second terminal, initialize over HTTP. Note the `Accept` header carrying **both** content types — this is mandatory, not optional.

```bash
curl -i -sS -X POST http://127.0.0.1:3001/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-probe","version":"0.1.0"}}}'
```

Expected:

```
HTTP/1.1 200 OK
content-type: text/event-stream
mcp-session-id: 1c8f7a30-6b2e-4f51-9a0d-3e7d8c2b41f9
cache-control: no-cache, no-transform
connection: keep-alive

event: message
data: {"result":{"protocolVersion":"2025-06-18","capabilities":{"prompts":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"tools":{"listChanged":true},"logging":{},"completions":{}},"serverInfo":{"name":"example-servers/everything","version":"1.0.0"}},"jsonrpc":"2.0","id":1}
```

**Step 3.** Capture the session id and complete the handshake, then list tools. Every post-initialization HTTP request carries **two** headers that stdio never needs.

```bash
SID=1c8f7a30-6b2e-4f51-9a0d-3e7d8c2b41f9   # paste yours

curl -sS -X POST http://127.0.0.1:3001/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SID" \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

curl -sS -X POST http://127.0.0.1:3001/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SID" \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | sed -n 's/^data: //p' | jq -r '.result.tools[].name'
```

Expected:

```
echo
add
longRunningOperation
printEnv
sampleLLM
getTinyImage
annotatedMessage
getResourceReference
structuredContent
```

**Step 4.** Break it on purpose — drop the session header.

```bash
curl -i -sS -X POST http://127.0.0.1:3001/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' | head -12
```

Expected:

```
HTTP/1.1 400 Bad Request
content-type: application/json

{"jsonrpc":"2.0","error":{"code":-32000,"message":"Bad Request: Mcp-Session-Id header is required"},"id":null}
```

**Step 5.** Terminate the session explicitly and confirm it is gone.

```bash
curl -i -sS -X DELETE http://127.0.0.1:3001/mcp \
  -H "Mcp-Session-Id: $SID" \
  -H 'MCP-Protocol-Version: 2025-06-18' | head -3
```

Expected:

```
HTTP/1.1 200 OK
```

> **Q7.** `MCP-Protocol-Version` is sent on every HTTP request but never on a stdio one. Why does the transport change the answer, given that both carry identical JSON-RPC payloads?
>
> **Q8.** A server receives an HTTP request with **no** `MCP-Protocol-Version` header at all. What does the spec say it should assume, and why is that specific default value — rather than "the latest" — the one that preserves compatibility?
>
> **Q9.** You are containerizing a server that customers currently run over stdio via `npx`. List three properties that exist only in the HTTP deployment and must therefore be designed, not inherited — and name the single security control the spec calls out for locally-bound HTTP servers.
>
> **Q10.** The `everything` server also accepts an `sse` argument. What is that transport, what replaced it, and what is the concrete reason a production server might still expose both endpoints for a period?

---

## Exercise 4 — Capability negotiation: portable servers degrade, they do not assume

A server that calls `sampling/createMessage` works beautifully in a host that supports sampling and **fails outright** in one that does not. Many hosts implement tools and resources but not sampling, roots, or elicitation. Capability negotiation exists so your server can find this out at handshake time rather than at tool-call time.

**Step 1.** Ask the reference server what a client's declared capabilities do to its behaviour. First, declare nothing:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bare","version":"0.1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sampleLLM","arguments":{"prompt":"hello","maxTokens":16}}}' \
  | npx -y @modelcontextprotocol/server-everything 2>/dev/null | tail -1 | jq -c '.'
```

Expected (the server attempts a sampling round-trip the bare client cannot answer):

```
{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"MCP error -32603: Client does not support sampling"}}
```

**Step 2.** Write a server that refuses to make that mistake. Create `portable_server.py`:

```python
"""A tool that is useful on every host, and better on capable ones."""
import re
import sys

from mcp.server.fastmcp import Context, FastMCP
from mcp.types import SamplingMessage, TextContent

mcp = FastMCP("portability-demo")

ERROR_LINE = re.compile(r"\b(ERROR|FATAL|panic|Traceback)\b")


def extractive_fallback(log: str, limit: int = 5) -> str:
    """Deterministic, dependency-free summary. Works on any client."""
    hits = [ln for ln in log.splitlines() if ERROR_LINE.search(ln)]
    if not hits:
        return "No error-level lines found in %d lines of input." % len(log.splitlines())
    head = "\n".join(hits[:limit])
    return "%d error-level lines; first %d:\n%s" % (len(hits), min(limit, len(hits)), head)


def client_supports_sampling(ctx: Context) -> bool:
    params = ctx.session.client_params
    return bool(params and params.capabilities and params.capabilities.sampling)


@mcp.tool()
async def summarize_incident(log: str, ctx: Context) -> str:
    """Summarize an incident log. Uses client-side sampling when the host offers it."""
    if not client_supports_sampling(ctx):
        print("sampling unavailable; using extractive fallback", file=sys.stderr)
        return extractive_fallback(log)

    result = await ctx.session.create_message(
        messages=[
            SamplingMessage(
                role="user",
                content=TextContent(type="text", text="Summarize this incident log:\n" + log),
            )
        ],
        max_tokens=300,
    )
    if isinstance(result.content, TextContent):
        return result.content.text
    return extractive_fallback(log)


if __name__ == "__main__":
    mcp.run()
```

**Step 3.** Install and smoke-test it through the Inspector's CLI mode — a host-independent conformance harness.

```bash
uv init --bare portable && cd portable
uv add "mcp[cli]"
cp ../portable_server.py .
npx -y @modelcontextprotocol/inspector --cli uv run portable_server.py --method tools/list
```

Expected:

```
{
  "tools": [
    {
      "name": "summarize_incident",
      "description": "Summarize an incident log. Uses client-side sampling when the host offers it.",
      "inputSchema": {
        "type": "object",
        "properties": { "log": { "title": "Log", "type": "string" } },
        "required": ["log"],
        "title": "summarize_incidentArguments"
      }
    }
  ]
}
```

**Step 4.** Call it from a client that declares no capabilities and confirm the fallback path runs instead of erroring.

```bash
npx -y @modelcontextprotocol/inspector --cli uv run portable_server.py \
  --method tools/call --tool-name summarize_incident \
  --tool-arg 'log=ok
ERROR disk full on /var
ok
FATAL exiting'
```

Expected:

```
{
  "content": [
    { "type": "text", "text": "2 error-level lines; first 2:\nERROR disk full on /var\nFATAL exiting" }
  ],
  "isError": false
}
```

> **Q11.** `client_supports_sampling` reads `ctx.session.client_params`. At what point in the connection lifecycle does that field become populated, and what would the function return if a tool were somehow invoked before that point?
>
> **Q12.** Name the three *client* capabilities a server may find absent, and for each, state a concrete degradation strategy that keeps the tool useful rather than failing.
>
> **Q13.** The fallback in Step 2 logs to `stderr`, not `stdout`. Explain precisely what a single `print("...")` to stdout does to a stdio-transport connection, and why the same line is harmless under Streamable HTTP.
>
> **Q14.** An alternative design is to *hide* `summarize_incident` from `tools/list` when the client lacks sampling. Argue for and against that versus the degradation shown here, and name the notification that would make the dynamic approach legal.

---

## Exercise 5 — The configuration envelope: portable binary, host-specific wrapper

Your server process is portable. The JSON that tells a host how to launch it is not. Three major hosts, three schemas, three secret-handling models — and the differences are exactly where "works on my machine" lives.

**Step 1.** Write the Claude Desktop form. Secrets are literals in a file on disk.

```json
{
  "mcpServers": {
    "weather": {
      "command": "npx",
      "args": ["-y", "@example/weather-mcp"],
      "env": {
        "WEATHER_API_KEY": "wk_live_REPLACE_ME"
      }
    }
  }
}
```

**Step 2.** Write the VS Code form (`.vscode/mcp.json`). Different top-level key, explicit transport type, and secrets are *prompted*, not stored.

```json
{
  "inputs": [
    {
      "type": "promptString",
      "id": "weather-key",
      "description": "Weather API key",
      "password": true
    }
  ],
  "servers": {
    "weather": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@example/weather-mcp"],
      "env": {
        "WEATHER_API_KEY": "${input:weather-key}"
      }
    }
  }
}
```

**Step 3.** Write the Claude Code form by CLI, which materializes a project-scoped `.mcp.json` intended to be committed.

```bash
claude mcp add weather --scope project \
  --env WEATHER_API_KEY=wk_live_REPLACE_ME \
  -- npx -y @example/weather-mcp

claude mcp list
```

Expected:

```
weather: npx -y @example/weather-mcp - ✓ Connected
```

**Step 4.** Now reproduce the single most common portability bug. Replace the launch line with a path-dependent one and restart the host:

```json
{
  "mcpServers": {
    "weather": {
      "command": "node",
      "args": ["./dist/index.js"],
      "env": {
        "WEATHER_API_KEY": "$WEATHER_API_KEY"
      }
    }
  }
}
```

**Step 5.** Inspect what the host actually hands your process, using the reference server's `printEnv` tool, and compare it to your shell.

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"env-probe","version":"0.1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"printEnv","arguments":{}}}' \
  | npx -y @modelcontextprotocol/server-everything 2>/dev/null \
  | tail -1 | jq -r '.result.content[0].text' | jq 'keys | length'
```

> **Q15.** Step 4 contains **three** separate portability defects. Identify each one and state the condition under which it fails.
>
> **Q16.** VS Code's `inputs` mechanism and Claude Desktop's literal `env` block solve the same problem differently. What does that imply for a server author writing installation documentation — and what should the server itself do at startup to make either model survivable?
>
> **Q17.** A Windows user reports that `"command": "npx"` fails while the identical config works on macOS. What is the underlying cause, and what is the portable remedy that does not require a per-OS config file?

---

## Exercise 6 — The registry: discovery, namespaces, and trust

A protocol without a discovery mechanism produces an ecosystem of copy-pasted JSON snippets. The official MCP Registry is the metadata layer: it does **not** host code, it publishes verified pointers to code, keyed by a namespace whose ownership you must prove.

**Step 1.** Query the registry API directly.

```bash
curl -sS 'https://registry.modelcontextprotocol.io/v0/servers?search=filesystem&limit=3' \
  | jq -r '.servers[] | "\(.name)\t\(.version)\t\(.repository.url)"'
```

Expected shape:

```
io.github.modelcontextprotocol/filesystem   0.6.2   https://github.com/modelcontextprotocol/servers
io.github.example/fs-bridge                 1.1.0   https://github.com/example/fs-bridge
com.acme/secure-filesystem                  2.0.4   https://github.com/acme/secure-fs-mcp
```

**Step 2.** Fetch one full record and note that it describes *how to obtain and launch* the server, not the server itself.

```bash
curl -sS 'https://registry.modelcontextprotocol.io/v0/servers?search=filesystem&limit=1' \
  | jq '.servers[0] | {name, version, packages: [.packages[] | {registryType, identifier, transport}]}'
```

**Step 3.** Author your own `server.json`. Take the `$schema` value from the current registry documentation rather than from memory — the pinned date is what tells a validator which field names apply.

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-09-29/server.schema.json",
  "name": "io.github.villadalmine/weather",
  "description": "Current conditions and forecasts from a public weather API",
  "version": "1.2.0",
  "repository": {
    "url": "https://github.com/villadalmine/weather-mcp",
    "source": "github"
  },
  "packages": [
    {
      "registryType": "npm",
      "identifier": "@example/weather-mcp",
      "version": "1.2.0",
      "transport": { "type": "stdio" },
      "environmentVariables": [
        {
          "name": "WEATHER_API_KEY",
          "description": "API key issued by the weather provider",
          "isRequired": true,
          "isSecret": true
        }
      ]
    }
  ]
}
```

**Step 4.** Prove namespace ownership and publish.

```bash
mcp-publisher login github
mcp-publisher publish
```

Expected:

```
✓ Authenticated as villadalmine (namespace io.github.villadalmine/*)
✓ Validated server.json against schema 2025-09-29
✓ Published io.github.villadalmine/weather@1.2.0
```

**Step 5.** Confirm the record is live.

```bash
curl -sS 'https://registry.modelcontextprotocol.io/v0/servers?search=io.github.villadalmine' \
  | jq -r '.servers[] | "\(.name)\t\(.version)"'
```

> **Q18.** The registry stores `identifier: "@example/weather-mcp"` with `registryType: "npm"` instead of hosting a tarball. Name two consequences of that design — one for supply-chain trust, one for how a host installs the server.
>
> **Q19.** Namespaces are reverse-DNS: `io.github.<user>/<name>` versus `com.acme/<name>`. Describe the ownership proof required for each form, and explain what property of the ecosystem this scheme is defending.
>
> **Q20.** Registry schema field names have changed across pinned `$schema` dates. What does that fact demand of your release tooling, and what would you add to CI to catch a stale `server.json` before it reaches a user?

---

## Exercise 7 — Prove portability in CI, and know the protocol's boundary

The last portability defence is mechanical: a conformance run on every OS and runtime you claim to support. The last *architectural* question is knowing what MCP is not for.

**Step 1.** Add a matrix conformance job. It runs the handshake and a `tools/list` — the two operations every host performs before anything else.

```yaml
name: mcp-portability
on:
  push:
    branches: ["main"]
  pull_request:
jobs:
  conformance:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        node: ["20", "22"]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
      - name: Build
        run: npm ci && npm run build
      - name: Handshake and enumerate tools
        run: npx -y @modelcontextprotocol/inspector --cli node dist/index.js --method tools/list
      - name: Validate registry metadata
        run: npx -y ajv-cli validate -s server.schema.json -d server.json
```

**Step 2.** Add a container target so the server is runnable with no host toolchain at all.

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN pip install --no-cache-dir uv && uv sync --frozen --no-dev
COPY portable_server.py ./
ENTRYPOINT ["uv", "run", "--no-dev", "portable_server.py"]
```

**Step 3.** Verify the container speaks the protocol identically.

```bash
docker build -t weather-mcp:1.2.0 .
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"0.1.0"}}}' \
  | docker run -i --rm weather-mcp:1.2.0 | jq -c '.result.serverInfo'
```

Expected:

```
{"name":"portability-demo","version":"1.14.1"}
```

**Step 4.** Read the governance model that decides what enters the spec, and confirm the current stewardship arrangement yourself rather than trusting any course material — including this one.

```bash
ls spec/docs/community/
sed -n '1,60p' spec/docs/community/governance.mdx
```

> **Q21.** The CI job asserts `tools/list` succeeds on three operating systems. Name two portability defects that this job **cannot** catch, and the kind of test that would.
>
> **Q22.** A colleague proposes using MCP as the wire protocol between two autonomous agents that negotiate a task with each other. Explain what MCP is scoped to, name the protocol class designed for the other problem, and give the one architectural reason the distinction matters for portability.
>
> **Q23.** Spec changes go through a written enhancement-proposal process rather than direct commits. From the perspective of someone operating MCP servers in production, what does that process buy you, and what does it cost?

---

## Answers

<details>
<summary><strong>Show answers (Q1–Q23)</strong></summary>

**Q1.** Date-based versioning communicates a *snapshot of the whole specification at a point in time* — one string identifies the exact set of methods, schema shapes, and rules in force. It makes negotiation trivial (compare two strings, both sides know the full contract) and makes "which spec did this implementation target" a single unambiguous question. What it does **not** encode is the *nature* of the change: semver's `MAJOR` bump announces "this breaks you." A date says nothing about severity, so you cannot infer compatibility from the version string alone — you must read the changelog or diff the schema, which is precisely what Step 2 does. This is why the negotiation rule (Q4) has to be explicit: the version string cannot carry the compatibility signal by itself.

**Q2.** "Official" describes governance, not readiness. The deciding signals are: (a) the most recent release tag and whether its changelog names the target spec version — an SDK that has not shipped since before the feature landed cannot implement it; (b) commit recency on the schema/protocol layer specifically, not the repo overall; (c) open issues referencing the feature; (d) whether the SDK's own tests run against the dated schema. Official SDKs are maintained by different groups at different cadences, so a Go SDK and a Python SDK carrying the same "official" badge can target spec versions months apart.

**Q3.** The failure mode is **version skew across the toolchain**: your server built on an SDK targeting `2025-06-18` gets launched by a host whose client SDK still targets `2025-03-26`, validated by an Inspector build that knows a third version, and described by a `server.json` pinned to a fourth schema. The defensive measure is to **treat the negotiated version as runtime state, not a build constant** — read the version the handshake actually settled on, gate every version-dependent code path on it (Q5), and pin the spec version your CI conformance job asserts against so skew fails in CI rather than in a user's host.

**Q4.** The rule: if the server does not support the client's requested version, it responds **successfully** with the latest version *it* supports. `initialize` does not fail on version mismatch. The client then inspects the returned version; if it cannot support that version, **the client is responsible for terminating the connection** (and for stdio, the host closes the subprocess). This is a negotiation, not a validation — which is why Step 2 returned `2025-06-18` with an ordinary `result` rather than an `error` object.

**Q5.** The server downgraded itself to `2024-11-05`, so any feature added later — elicitation, structured tool output, the resource-link content type, the `MCP-Protocol-Version` header semantics — is now outside the agreed contract. Emitting it anyway produces payloads the client's schema validator rejects, typically surfacing as an opaque parse or validation failure on the host side. The guard must live **after the handshake and before any use of the feature**, reading the negotiated version from session state — not at import time, not from a constant, and not from the value the client *requested* (which may differ from what was agreed).

**Q6.** The client sends the `notifications/initialized` notification. Until it does, the connection is in the initializing state: the server has answered with its capabilities but has no confirmation the client accepted the negotiated version. Issuing normal requests before that point would mean operating under a contract the client has not yet acknowledged — the client might still be about to disconnect over an unacceptable version (Q4). The spec permits only `ping` and logging in that window. Note it is a notification: no `id`, no response, which is why the Step 3 curl returns an empty body.

**Q7.** Under stdio, the process *is* the session: the subprocess was spawned by this client, the pipe carries exactly one connection, and the negotiated version is unambiguous process state for its whole lifetime. Over HTTP, requests are independent, may be load-balanced across server instances, and may arrive from a client that reconnected — the server cannot infer which negotiation a given request belongs to from the payload alone. The header restores, per-request, the context stdio gets for free from process identity. Same JSON-RPC, different amount of implicit context in the channel.

**Q8.** It should assume `2025-03-26`. That is the newest version that predates the header's introduction — so a client omitting the header is, by definition, one that was written before the header existed, and `2025-03-26` is the best-supported guess about what it speaks. Assuming "the latest" would do the opposite of compatibility: it would treat the oldest clients as the newest and offer them features they cannot parse. (A header that is present but *malformed* is a different case and should be rejected with `400`.)

**Q9.** Properties that must be designed rather than inherited: (1) **session lifecycle** — `Mcp-Session-Id` issuance, expiry, and the `404`-on-expired/`DELETE`-to-terminate contract, where stdio had process exit; (2) **authentication and authorization** — stdio inherited the trust of the user who spawned the process; an HTTP endpoint is reachable by anything that can route to it, so it needs the OAuth resource-server model the spec defines; (3) **concurrency and state isolation** — one process now serves many sessions, so any module-level mutable state that was safely per-user under stdio becomes cross-tenant leakage. Also: resumability via SSE event ids, and TLS. The security control the spec explicitly calls out for locally-bound HTTP servers is **`Origin` header validation**, together with binding to `127.0.0.1` rather than `0.0.0.0` — without it, any web page the user visits can drive their local MCP server (DNS-rebinding / CSRF against localhost).

**Q10.** `sse` is the legacy **HTTP+SSE** transport from `2024-11-05`: two endpoints, a long-lived `GET /sse` stream for server→client messages plus a separate `POST` endpoint for client→server. It was replaced by **Streamable HTTP** in `2025-03-26`, which unifies both directions on a single endpoint, makes the long-lived stream optional, and adds sessions and resumability. A production server keeps both for a deprecation window because **host upgrade cycles are not yours to control**: desktop applications and IDE extensions ship on their own schedule, and removing `/sse` the day you ship Streamable HTTP breaks every user pinned to an older host build. Serve both, announce a removal date, and instrument which endpoint real traffic uses.

**Q11.** `client_params` is populated when the server processes `initialize` — it is the deserialized `InitializeRequestParams`, stored on the session. Since tools can only be called after the handshake completes (Q6), it is populated for any legitimate tool invocation. The function nonetheless checks `bool(params and ...)` because in tests, in-process harnesses, and some transport edge cases the field can be `None`; returning `False` there means the code takes the **deterministic fallback path** rather than raising an `AttributeError`. That is the correct bias: an unknown capability is an absent capability.

**Q12.** The three client capabilities are:
- **`sampling`** — the server asks the client's LLM to generate. Absent: fall back to deterministic logic (as in Step 2), or return the raw material and let the host's own model do the reasoning.
- **`roots`** — the client tells the server which filesystem/URI boundaries it may operate within. Absent: fall back to an explicitly configured base path from environment/args, and refuse to operate on an unbounded default like `/`.
- **`elicitation`** — the server asks the user for structured input mid-operation. Absent: promote the needed field to a **required tool parameter** so the model supplies it up front, or return a `isError` result whose text tells the caller exactly which argument to provide and re-invoke.

In all three, the principle is the same: the capable path is an *enhancement*, and the tool's contract must be satisfiable without it.

**Q13.** Under stdio, the transport **is** `stdout`: the framing is newline-delimited JSON-RPC messages, and the client parses every line it reads. A stray `print("...")` injects a line that is not valid JSON-RPC, and the client's parser fails — typically surfacing as `Unexpected token 's' in JSON at position 0` or a silent connection drop at startup, with no indication that the cause was a debug statement. This is the single most common "works in my tests, dies in the host" bug, because a test harness that calls the function directly never touches the pipe. `stderr` is explicitly reserved for logging and is what the host captures into its MCP log files. Under Streamable HTTP the process's stdout is not a protocol channel at all — it goes to the container log — so the same line is inert. Which is exactly why the bug survives HTTP-only testing and then appears in stdio deployments.

**Q14.** *For hiding:* the tool list the model sees is its action space; advertising a tool that will return a degraded result wastes a turn and can mislead the model about what the system can do. *Against hiding:* it makes your server's surface non-deterministic across hosts, which breaks documentation, breaks cached tool lists, breaks any evaluation harness, and makes user-reported bugs unreproducible ("the tool isn't there" — for which of a dozen reasons?). The degradation approach keeps one contract everywhere and moves the variability into the *quality* of the result, which is observable and documentable. If you do go dynamic, the notification that makes it legal is **`notifications/tools/list_changed`**, which tells the client to re-issue `tools/list`; changing the set silently leaves the client holding a stale list. The defensible middle ground is a stable tool list with the capability-dependence stated in the tool description, so the model knows what it is getting.

**Q15.** The three defects:
1. **`"command": "node"` relies on `node` being on the host's `PATH`.** Hosts do not launch servers from your interactive login shell — GUI applications inherit a minimal environment, so `PATH` frequently lacks `nvm`/`asdf`/Homebrew-managed runtimes that work fine in your terminal. Fails for any user whose runtime is version-managed.
2. **`"args": ["./dist/index.js"]` is a relative path.** It resolves against the host's working directory, which is unspecified by the protocol and differs per host (application bundle directory, user home, project root). Fails everywhere except the one host whose cwd happens to match — and `./dist/` additionally assumes the user built from source.
3. **`"WEATHER_API_KEY": "$WEATHER_API_KEY"` assumes shell expansion.** The `env` block is a literal JSON string map passed to the process; no shell interprets it, so the server receives the seven characters `$WEATHER_API_KEY` as its API key. Fails always, and fails *confusingly* — as a `401` from the upstream API, not as a config error.

**Q16.** It means installation documentation cannot be a single JSON snippet: you must document the *server's* contract (executable, arguments, required environment variables, required transport) and then show the envelope for each host you support — or point at the registry record, which is the machine-readable form of exactly that contract. What the **server** must do is validate its own configuration at startup: check every required environment variable is present and non-empty, and exit with a clear message on `stderr` naming the missing variable. Under VS Code's prompted-input model a cancelled prompt yields an empty string; under the literal-`env` model a user may leave the placeholder in place. Both produce the same failure, and a startup check turns it from a confusing upstream `401` into one readable line in the host's MCP log.

**Q17.** On Windows, `npx` is `npx.cmd`, a batch script — not an executable. Process-spawn APIs that do not invoke a shell (Node's `spawn` without `shell: true`, Python's `subprocess` without `shell=True`) cannot execute it, producing `ENOENT` / "file not found" even though `npx` works in the terminal. The portable remedy that avoids per-OS config is to **not depend on a package-runner shim at all**: publish an installable executable and reference it directly, or distribute a container image and use `docker run -i --rm ...` as the command (Exercise 7, Step 3), which is byte-identical across operating systems. Where the shim is unavoidable, hosts commonly require `"command": "cmd"` with `"args": ["/c", "npx", ...]` on Windows — but that is a second config file, which is what the question asks you to avoid.

**Q18.** For **supply-chain trust**: the registry is a metadata index, so it inherits the security properties of npm/PyPI/OCI rather than adding its own. The registry's contribution is *attribution* — it verifies that the publisher controls the namespace (Q19) and links the record to a source repository — not *integrity* of the artifact. Auditing what actually executes still means auditing the upstream package. For **installation**: the host must have the corresponding package manager available and will fetch at launch time (`npx -y`, `uvx`, `docker run`), which means first-run latency, a network dependency at startup, and version resolution that can drift unless the record and the config pin an exact version.

**Q19.** `io.github.<user>/<name>` is proved by **GitHub OAuth**: authenticating as that GitHub account demonstrates control of the namespace, which is why `mcp-publisher login github` is the whole ceremony. A custom namespace like `com.acme/<name>` is proved by **demonstrating control of the DNS domain** — publishing a TXT record containing the publisher's key under the domain — since no OAuth provider can vouch for `acme.com`. The property being defended is **namespace squatting and impersonation**: without ownership proof, anyone could publish `com.stripe/payments` and every host in the ecosystem would present it as Stripe's. Reverse-DNS tied to a provable identity makes the name itself carry an attribution claim.

**Q20.** It demands that the `$schema` pin be treated as a **versioned dependency with an upgrade procedure**, not a URL copied once from a tutorial: a record written against an older pin may use field names (`registry_name`, `name` inside `packages`) that a newer validator rejects, and the failure appears at publish time or, worse, as a record that validates but is interpreted differently. In CI, add a **schema-validation step that fetches the pinned schema and validates `server.json` against it** (the `ajv-cli` step in Exercise 7), plus a check that the `version` in `server.json` matches the package version being released — so a forgotten bump fails the build rather than publishing a record pointing at the wrong artifact.

**Q21.** Two defects the matrix job cannot catch: (1) **capability-dependent behaviour** — the job's client declares whatever the Inspector declares, so a `sampling`-dependent path is never exercised against a client that lacks it; catching that needs a test harness that initializes with explicitly empty client capabilities and asserts the fallback (Exercise 4, Step 4). (2) **Host-environment differences** — the job runs with CI's full `PATH` and environment, so the defects in Q15 (missing runtime on `PATH`, unresolved cwd, unexpanded `env`) all pass; catching those needs a launch test with a deliberately minimal environment (`env -i`) from an unrelated working directory. Also uncaught: transport-specific behaviour if the job only tests stdio, and protocol-version skew if it only tests the current version — both need explicit matrix dimensions of their own.

**Q22.** MCP is scoped to the **application-to-context/tool boundary**: it connects a host application (with its model) to servers that expose tools, resources, and prompts. Its entire vocabulary — `tools/call`, `resources/read`, `prompts/get` — assumes one side offers capabilities and the other consumes them. Agent-to-agent negotiation is a **peer** relationship with different primitives (capability advertisement, task delegation, long-running task state, multi-turn negotiation between equals), and the protocol class designed for it is **A2A (Agent2Agent)**; the two are complementary, not competing — an agent typically speaks A2A to peers and MCP to its tools. The reason this matters for portability: forcing peer negotiation through `tools/call` means encoding your own ad-hoc semantics inside tool arguments, and the moment you do that your server is only interoperable with the one client that shares your convention — you have kept MCP's syntax while leaving its ecosystem. Portability comes from the *shared semantics*, not from the JSON-RPC framing.

**Q23.** What it buys you: **auditability and lead time**. Every change to the contract your production servers depend on arrives with a written rationale, a public discussion, a compatibility analysis, and a draft period before it appears in a dated spec version — so you can read a proposal, assess its impact on your deployment, and object *before* it is normative, rather than discovering it in a changelog. It also means the spec is not a single vendor's unilateral artifact, which matters when you are betting a product on it. What it costs: **latency**. A feature your use case needs urgently moves at the pace of consensus across many implementers, and the correct response — implementing it as a proprietary extension in the meantime — reintroduces exactly the portability problem the standard exists to solve. Verify the current stewardship, maintainer set, and proposal process from the governance document in the specification repository; this is the part of the ecosystem that changes fastest and the part course material is most likely to have stale.

</details>

---

## Sources

- Linux Foundation — *Model Context Protocol Associate (MCPA)*: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
- MCP documentation and architecture: https://modelcontextprotocol.io/
- Specification — lifecycle and version negotiation: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- Specification — transports (stdio, Streamable HTTP): https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Specification — client features (sampling, roots, elicitation): https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- Specification repository, schema and community governance: https://github.com/modelcontextprotocol/modelcontextprotocol
- Reference servers (`everything`, `filesystem`, …): https://github.com/modelcontextprotocol/servers
- MCP Registry — API, `server.json`, `mcp-publisher`: https://github.com/modelcontextprotocol/registry
- MCP Inspector (GUI and `--cli` conformance mode): https://github.com/modelcontextprotocol/inspector
- VS Code — MCP server configuration (`.vscode/mcp.json`, `inputs`): https://code.visualstudio.com/docs/copilot/chat/mcp-servers
- Claude Code — MCP configuration and scopes: https://docs.claude.com/en/docs/claude-code/mcp
- A2A (Agent2Agent) protocol, for the boundary discussed in Q22: https://a2a-protocol.org/