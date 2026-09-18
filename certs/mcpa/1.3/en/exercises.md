# Topic 1.3 — Interoperability & Value

## Guided Exercises

> **Certification:** Model Context Protocol Associate (MCPA), exam version 2026-07-28
> **Exam weight:** 5.33%
> **Estimated time:** 90–120 minutes
> **Primary sources:**
> - Linux Foundation — MCPA certification page: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
> - MCP specification (revision 2025-06-18): https://modelcontextprotocol.io/specification/2025-06-18/
> - JSON-RPC 2.0 specification: https://www.jsonrpc.org/specification

---

### What this topic is really asking

"Interoperability & Value" is the only part of Domain 1 that is not about *how* MCP works but about *why anyone would pay for it*. The exam tests whether you can defend three claims with evidence from the wire, not from marketing:

1. **The integration economics claim** — MCP converts an M×N integration matrix into M+N.
2. **The substitutability claim** — the same server works against any conformant host, over any conformant transport, with any model vendor, because the contract is JSON-RPC 2.0 plus JSON Schema, not a vendor SDK.
3. **The negotiated-compatibility claim** — a client and server that were built years apart, against different spec revisions, still interoperate *predictably*, because version and capability negotiation happen explicitly during `initialize` rather than being assumed.

Every exercise below ends by producing an artifact you can point at to prove one of those three.

---

### Prerequisites

You need a Linux, macOS, or WSL2 shell with:

- Node.js ≥ 18 (`npx` on `PATH`)
- Python ≥ 3.10 with `uv` or `pip`
- `curl` and `jq`

Install the reference tooling once:

```bash
# Python SDK, including the `mcp` CLI helper
python3 -m venv .venv
.venv/bin/pip install "mcp[cli]"

# Verify
.venv/bin/python -c "import mcp; print(mcp.__version__ if hasattr(mcp,'__version__') else 'ok')"
node --version
jq --version
```

Expected output (versions will differ; the point is that all three resolve):

```
ok
v22.11.0
jq-1.7.1
```

---

## Exercise 1 — Measure the M×N problem before you claim to have solved it

**Objective:** produce a concrete number for the integration cost with and without a shared protocol, and verify the "M+N" claim by attaching *one* server to *two* different hosts without editing the server.

### Steps

1. Write down the inventory of a realistic platform team. Create `interop/inventory.yaml`:

```yaml
hosts:
  - name: "IDE assistant"
    vendor: "Vendor A"
  - name: "Chat desktop app"
    vendor: "Vendor B"
  - name: "CI remediation agent"
    vendor: "in-house, LangGraph"
  - name: "Support copilot"
    vendor: "Vendor C"
integrations:
  - name: "Jira"
  - name: "Postgres read replica"
  - name: "Internal runbook wiki"
  - name: "Kubernetes read-only API"
  - name: "PagerDuty"
  - name: "Grafana / Loki"
```

2. Compute both costs. The pre-protocol world needs one adapter per (host, integration) pair; the protocol world needs one client implementation per host plus one server per integration:

```bash
cd interop
HOSTS=$(grep -c 'name:' <(sed -n '/^hosts:/,/^integrations:/p' inventory.yaml) )
```

That is fragile. Use the parser instead — this is also the habit the exam rewards, since "the YAML parses" is a checkable claim:

```bash
.venv/bin/python - <<'PY'
import yaml
d = yaml.safe_load(open("interop/inventory.yaml"))
m, n = len(d["hosts"]), len(d["integrations"])
print(f"hosts M={m}  integrations N={n}")
print(f"bespoke adapters   M*N = {m*n}")
print(f"MCP components     M+N = {m+n}   ({m} clients + {n} servers)")
print(f"artifacts avoided        {m*n-(m+n)}")
PY
```

Expected output:

```
hosts M=4  integrations N=6
bespoke adapters   M*N = 24
MCP components     M+N = 10   (4 clients + 6 servers)
artifacts avoided        14
```

3. Now prove the M+N side is real rather than arithmetic. Attach one unmodified, third-party server to host #1 — the MCP Inspector, a generic debugging host:

```bash
npx -y @modelcontextprotocol/inspector npx -y @modelcontextprotocol/server-filesystem /tmp
```

The Inspector prints a local URL and an auth token. Open it, press **Connect**, then open the **Tools** tab and click **List Tools**.

4. Attach the *same* server to host #2 — a project-scoped config file consumed by a different host application. Create `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    }
  }
}
```

5. Record what you had to change in the server to support the second host:

```bash
echo "server source edits required: 0"
```

**Check your understanding**

- **Q1.** In the M+N formula, what exactly are the "M" artifacts and the "N" artifacts? Which side of the equation does a platform team usually *not* write itself?
- **Q2.** The `.mcp.json` file and the Inspector's command line both contain `npx -y @modelcontextprotocol/server-filesystem /tmp`. Is that duplication evidence that MCP failed to remove per-host work? Justify your answer in terms of what is duplicated — configuration or code.
- **Q3.** The Language Server Protocol made the same M×N → M+N argument for editors and languages a decade earlier. Name one structural property LSP and MCP share that makes the argument valid, and one property of the *AI* case that LSP never had to handle.
- **Q4.** Your inventory grows by one host and one integration (M=5, N=7). By how much does the bespoke-adapter count grow, and by how much does the MCP component count grow? Which growth rate is the actual business argument?

---

## Exercise 2 — The wire is the contract: drive a server with nothing but `printf`

**Objective:** confirm that an MCP server's public contract is newline-delimited JSON-RPC 2.0 on stdio — no SDK, no vendor library, no language runtime in common with the client.

### Steps

1. Write the `initialize` request. This is the exact shape a conformant client sends first — read it carefully, because three of its fields are graded material:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "roots": { "listChanged": true },
      "sampling": {}
    },
    "clientInfo": {
      "name": "printf-client",
      "version": "0.1.0"
    }
  }
}
```

2. Send it — plus the mandatory `notifications/initialized` and a `tools/list` — as three lines of JSON on stdin. The `sleep` matters: several servers exit as soon as stdin closes, before they have flushed their reply.

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{}},"clientInfo":{"name":"printf-client","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 3
} | npx -y @modelcontextprotocol/server-filesystem /tmp 2>/dev/null
```

The output is **JSON Lines** — several JSON documents, one per line — which is why it is shown here in an unlabelled block rather than a `json` block:

```
{"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"secure-filesystem-server","version":"0.2.0"}},"jsonrpc":"2.0","id":1}
{"result":{"tools":[{"name":"read_file","description":"Read the complete contents of a file...","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]},"jsonrpc":"2.0","id":2}
```

3. Extract only the negotiated facts:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"printf-client","version":"0.1.0"}}}'
  sleep 2
} | npx -y @modelcontextprotocol/server-filesystem /tmp 2>/dev/null \
  | jq -c 'select(.id==1) | {protocolVersion:.result.protocolVersion, serverCaps:(.result.capabilities|keys), server:.result.serverInfo.name}'
```

Expected output:

```
{"protocolVersion":"2025-06-18","serverCaps":["tools"],"server":"secure-filesystem-server"}
```

4. Break the contract deliberately and observe that the failure is a *protocol* failure, not a crash. Ask for a method the server never declared:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"printf-client","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"resources/list"}'
  sleep 3
} | npx -y @modelcontextprotocol/server-filesystem /tmp 2>/dev/null | jq -c 'select(.id==9)'
```

Expected output:

```
{"jsonrpc":"2.0","id":9,"error":{"code":-32601,"message":"Method not found"}}
```

**Check your understanding**

- **Q5.** You drove a TypeScript server from `bash`. Which two specifications — not SDKs — were sufficient to do that, and what does that imply for a team whose agent runtime is written in Go or Rust?
- **Q6.** In step 3 the server declared `capabilities: {"tools": ...}` and nothing else. In step 4 `resources/list` returned `-32601`. Was the server non-conformant, or was the *client* at fault? What is the rule a conformant client must follow before issuing `resources/list`?
- **Q7.** `notifications/initialized` carries no `id`. What is the JSON-RPC 2.0 term for such a message, and what is the observable consequence for the sender?
- **Q8.** `-32601` is a JSON-RPC transport-level error. Contrast it with a `tools/call` response that returns `"isError": true` inside its result. Which of the two is the model expected to see and reason about, and why does MCP separate them?

---

## Exercise 3 — Version negotiation: interoperating with code written before or after you

**Objective:** demonstrate that MCP's forward/backward compatibility is *negotiated and observable*, not assumed — the property that lets an estate of servers and hosts upgrade independently.

### Steps

1. Claim a protocol revision from the future:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{},"clientInfo":{"name":"time-traveller","version":"0.1.0"}}}'
  sleep 2
} | npx -y @modelcontextprotocol/server-filesystem /tmp 2>/dev/null | jq -c '.result.protocolVersion'
```

Expected output — the server does **not** echo your version and does **not** disconnect; it counter-offers the latest revision it actually supports:

```
"2025-06-18"
```

2. Claim a revision from the past:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"legacy-client","version":"0.1.0"}}}'
  sleep 2
} | npx -y @modelcontextprotocol/server-filesystem /tmp 2>/dev/null | jq -c '.result.protocolVersion'
```

Expected output — the server supports that older revision and agrees to speak it:

```
"2024-11-05"
```

3. Record the decision table the client must now implement. The negotiation is three-valued, and the third value is the one candidates forget:

| Server's response `protocolVersion` | Client's obligation |
|---|---|
| Equal to what the client offered | Proceed |
| A different revision the client also supports | Proceed **using that revision**, not the offered one |
| A revision the client does not support | Disconnect; do not attempt requests |

4. Show that the negotiated revision changes what is *legal*, not just what is labelled. Compare the feature sets:

```bash
cat > interop/revisions.yaml <<'YAML'
revisions:
  - id: "2024-11-05"
    transports: ["stdio", "HTTP+SSE (two endpoints)"]
    notable: "initial public revision"
  - id: "2025-03-26"
    transports: ["stdio", "Streamable HTTP (single endpoint)"]
    notable: "tool annotations; OAuth 2.1 authorization framework"
  - id: "2025-06-18"
    transports: ["stdio", "Streamable HTTP (single endpoint)"]
    notable: "elicitation; structured tool output; resource indicators (RFC 8707); MCP-Protocol-Version header on HTTP"
YAML
.venv/bin/python -c "import yaml,sys; print(len(yaml.safe_load(open('interop/revisions.yaml'))['revisions']), 'revisions parsed')"
```

Expected output:

```
3 revisions parsed
```

5. Confirm on your own installation which revisions are in play, rather than trusting the table:

```bash
npx -y @modelcontextprotocol/server-everything 2>/dev/null <<'EOF' | jq -c 'select(.id==1) | .result.protocolVersion'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.1.0"}}}
EOF
```

**Check your understanding**

- **Q9.** In step 1 the server replied `2025-06-18` to a client that asked for `2099-01-01`. What must that client do next, and what must it **not** do?
- **Q10.** A host upgrades to a client library supporting `2025-06-18` and starts sending `elicitation` in its client capabilities. Eleven of its twelve configured servers were built against `2024-11-05`. What happens to those eleven, and which single field in the handshake is what protects them?
- **Q11.** Your platform pins every server image to an exact digest and upgrades them on a quarterly cycle, but the desktop host auto-updates weekly. Why is this *not* a coordination problem in MCP, and what would it have been in a bespoke-adapter architecture?
- **Q12.** Over Streamable HTTP, revision 2025-06-18 requires the client to send an `MCP-Protocol-Version` header on every request after the handshake. Over stdio there is no such header. Why does HTTP need it and stdio does not?

---

## Exercise 4 — One server, two transports, zero code changes

**Objective:** prove the substitutability claim along the transport axis. You will write one server, run it over stdio and over Streamable HTTP, and diff the tool contract it publishes.

### Steps

1. Write the server. Note the last three lines: transport is a *runtime* choice, not an architectural one.

```python
# interop/interop_server.py
import sys

from mcp.server.fastmcp import FastMCP
from pydantic import BaseModel, Field

mcp = FastMCP("interop-demo")


class Severity(BaseModel):
    """Canonical severity, independent of the emitting system."""

    canonical: str = Field(description="one of: info, warning, critical")
    numeric: int = Field(description="0=info, 1=warning, 2=critical")
    source_vendor: str = Field(description="system the code came from")


_TABLE = {
    ("pagerduty", "P1"): ("critical", 2),
    ("pagerduty", "P3"): ("warning", 1),
    ("nagios", "CRITICAL"): ("critical", 2),
    ("nagios", "WARNING"): ("warning", 1),
    ("prometheus", "page"): ("critical", 2),
    ("prometheus", "ticket"): ("warning", 1),
}


@mcp.tool()
def normalize_severity(vendor: str, code: str) -> Severity:
    """Translate a vendor-specific alert code into a canonical severity."""
    key = (vendor.lower(), code)
    canonical, numeric = _TABLE.get(key, ("info", 0))
    return Severity(canonical=canonical, numeric=numeric, source_vendor=vendor)


if __name__ == "__main__":
    transport = sys.argv[1] if len(sys.argv) > 1 else "stdio"
    mcp.run(transport=transport)
```

2. Publish the contract over **stdio** and save it:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 3
} | .venv/bin/python interop/interop_server.py stdio 2>/dev/null \
  | jq -S 'select(.id==2) | .result.tools' > interop/contract-stdio.json

jq -c '.[0] | {name, hasInput:(.inputSchema!=null), hasOutput:(.outputSchema!=null)}' interop/contract-stdio.json
```

Expected output:

```
{"name":"normalize_severity","hasInput":true,"hasOutput":true}
```

> If `hasOutput` is `false`, your SDK predates structured tool output (introduced in revision 2025-06-18). Keep going — question **Q16** is about exactly that case.

3. Start the *same file* over **Streamable HTTP**, in a second terminal:

```bash
.venv/bin/python interop/interop_server.py streamable-http
```

Expected output:

```
INFO:     Started server process [48122]
INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)
```

4. Perform the handshake with `curl`. Two headers are mandatory and both are graded: the client must accept *both* content types, because the server chooses whether to answer with a single JSON body or an SSE stream.

```bash
curl -sS -D interop/headers.txt -X POST http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-client","version":"0.1.0"}}}' \
  | sed -n 's/^data: //p' | jq -c '.result | {protocolVersion, server:.serverInfo.name}'

grep -i '^mcp-session-id' interop/headers.txt
```

Expected output:

```
{"protocolVersion":"2025-06-18","server":"interop-demo"}
mcp-session-id: 7c1f0a6e4b9d4a2e8b3c5d1f0a6e4b9d
```

5. Capture the session and finish the handshake, then list tools over HTTP:

```bash
SID=$(grep -i '^mcp-session-id' interop/headers.txt | tr -d '\r' | awk '{print $2}')

curl -sS -X POST http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' -o /dev/null -w '%{http_code}\n'

curl -sS -X POST http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | sed -n 's/^data: //p' | jq -S '.result.tools' > interop/contract-http.json
```

Expected output from the first command:

```
202
```

6. Diff the two contracts:

```bash
diff interop/contract-stdio.json interop/contract-http.json && echo "IDENTICAL CONTRACT"
```

Expected output:

```
IDENTICAL CONTRACT
```

7. Call the tool over HTTP and inspect *both* result channels:

```bash
curl -sS -X POST http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"normalize_severity","arguments":{"vendor":"pagerduty","code":"P1"}}}' \
  | sed -n 's/^data: //p' | jq -c '.result | {text:.content[0].text, structured:.structuredContent}'
```

Expected output:

```
{"text":"{\"canonical\":\"critical\",\"numeric\":2,\"source_vendor\":\"pagerduty\"}","structured":{"canonical":"critical","numeric":2,"source_vendor":"pagerduty"}}
```

8. Deploy the HTTP variant so other teams' hosts can reach it. This is where transport choice becomes an organisational decision:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-interop-demo
  namespace: platform-mcp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mcp-interop-demo
  template:
    metadata:
      labels:
        app: mcp-interop-demo
    spec:
      containers:
        - name: server
          image: registry.internal.example.com/platform/mcp-interop-demo:1.4.0
          args: ["streamable-http"]
          ports:
            - name: http
              containerPort: 8000
          env:
            - name: MCP_LOG_LEVEL
              value: "info"
          readinessProbe:
            httpGet:
              path: /mcp
              port: http
            initialDelaySeconds: 3
```

**Check your understanding**

- **Q13.** You changed exactly one thing between step 2 and step 3. Name it, and state the layer of the protocol it belongs to. Why does the `tools/list` result not change as a result?
- **Q14.** The `Accept` header carried two media types. What decision does that leave to the server, and what breaks if a client sends `Accept: application/json` alone?
- **Q15.** `notifications/initialized` returned HTTP `202` with no body, while `tools/list` returned a body. Explain the difference using the JSON-RPC message taxonomy from Q7.
- **Q16.** `tools/call` returned both `content[0].text` and `structuredContent` carrying the same data. Who is each one for? If your SDK produced no `outputSchema` in step 2, which of the two would be missing, and what must a client that needs machine-readable output do instead?
- **Q17.** For a server that must read files on the user's laptop, which transport is correct, and why is the Kubernetes Deployment in step 8 the wrong shape for it?
- **Q18.** The Deployment runs `replicas: 2`. What property of the Streamable HTTP session makes that non-trivial, and which header identifies the affinity requirement?

---

## Exercise 5 — JSON Schema as the lingua franca: reuse one server across model vendors

**Objective:** demonstrate the substitutability claim along the *model vendor* axis — the strongest form of the value argument, because it is what prevents lock-in.

### Steps

1. Take the contract you captured and translate it into a foreign function-calling format with a single `jq` expression. Nothing about the server is consulted except its published schema:

```bash
jq -S '[.[] | {type:"function", function:{name:.name, description:.description, parameters:.inputSchema}}]' \
  interop/contract-stdio.json > interop/tools-openai-style.json

jq -c '.[0].function | {name, required:.parameters.required}' interop/tools-openai-style.json
```

Expected output:

```
{"name":"normalize_severity","required":["vendor","code"]}
```

2. Translate into a second foreign format — the same source, a different target shape:

```bash
jq -S '[.[] | {name:.name, description:.description, input_schema:.inputSchema}]' \
  interop/contract-stdio.json > interop/tools-anthropic-style.json

jq -c '.[0] | {name, type:.input_schema.type}' interop/tools-anthropic-style.json
```

Expected output:

```
{"name":"normalize_severity","type":"object"}
```

3. Confirm that no semantic information was lost — the schema is the same object in both:

```bash
diff <(jq -S '.[0].function.parameters' interop/tools-openai-style.json) \
     <(jq -S '.[0].input_schema' interop/tools-anthropic-style.json) \
  && echo "SCHEMA PRESERVED ACROSS VENDORS"
```

Expected output:

```
SCHEMA PRESERVED ACROSS VENDORS
```

4. Find the boundary of the claim. Some vendors' strict function-calling modes constrain the JSON Schema dialect. Test your schema against one such constraint:

```bash
jq -e '.[0].inputSchema | (.type=="object") and (has("additionalProperties")|not)' interop/contract-stdio.json \
  && echo "WARNING: no additionalProperties:false — strict mode would reject this"
```

Expected output:

```
true
WARNING: no additionalProperties:false — strict mode would reject this
```

5. Record the direction of travel for the *other* half of interoperability — wrapping an existing REST API, so that an OpenAPI description becomes an MCP server rather than N more adapters:

```bash
cat > interop/wrapping-decision.yaml <<'YAML'
candidate: "internal runbook wiki"
existing_interface: "OpenAPI 3.1, 41 operations"
decision: "expose 6 curated tools, not 41"
rationale:
  - "tool lists are loaded into the model context window on every turn"
  - "41 near-identical CRUD operations produce tool-selection errors"
  - "a curated tool encodes the workflow, an endpoint encodes the storage"
naming: "search_runbooks, get_runbook, list_recent_incidents"
annotations:
  readOnlyHint: true
  openWorldHint: true
YAML
.venv/bin/python -c "import yaml; d=yaml.safe_load(open('interop/wrapping-decision.yaml')); print(d['decision'])"
```

Expected output:

```
expose 6 curated tools, not 41
```

**Check your understanding**

- **Q19.** Steps 1 and 2 produced two vendor-specific tool lists from one MCP server, using only `jq`. Which single design decision in MCP made that a field-renaming exercise rather than a porting exercise?
- **Q20.** You swap your agent's model from Vendor A to Vendor B. Which of these must change: the MCP servers, the MCP client, the tool schemas, the `tools/call` handling code? Which one is the *only* legitimate answer, and why is that the anti-lock-in argument?
- **Q21.** Step 4 produced a warning. Is the MCP server non-conformant? Distinguish "valid JSON Schema", "valid MCP tool definition", and "accepted by a particular vendor's strict mode".
- **Q22.** Step 5 rejects a mechanical OpenAPI-to-MCP conversion of all 41 operations. Give the two independent costs of a 41-tool server — one measured in tokens, one measured in accuracy.
- **Q23.** `openWorldHint: true` and `readOnlyHint: true` appear in that file. What are tool annotations *not* allowed to be relied upon for, and who is responsible for enforcement instead?

---

## Exercise 6 — Sampling and elicitation: the value inversion

**Objective:** observe the two capabilities that invert the usual integration direction — the server borrowing the client's model, and the server borrowing the client's user. These are the features that have no equivalent in a plain REST integration, and they are the sharpest answer to "why not just call the API?".

### Steps

1. Add a tool that needs an LLM but owns no model, no API key, and no billing relationship:

```python
# append to interop/interop_server.py, above the __main__ block
from mcp.server.fastmcp import Context
from mcp.types import SamplingMessage, TextContent


@mcp.tool()
async def summarize_incident(raw_log: str, ctx: Context) -> str:
    """Summarize an incident log. The summary is produced by the CLIENT's model."""
    result = await ctx.session.create_message(
        messages=[
            SamplingMessage(
                role="user",
                content=TextContent(
                    type="text",
                    text=f"Summarize this incident log in three bullets:\n\n{raw_log}",
                ),
            )
        ],
        max_tokens=300,
    )
    return result.content.text if result.content.type == "text" else "(non-text reply)"
```

2. Inspect the declared capabilities from both sides. Run the server under the Inspector:

```bash
npx -y @modelcontextprotocol/inspector .venv/bin/python interop/interop_server.py stdio
```

Connect, then open the **Tools** tab, select `summarize_incident`, paste any text into `raw_log`, and run it.

3. Watch the request arrive in the Inspector's **Sampling** tab. The Inspector does not have a model attached, so it asks *you* to play the role of one. Approve it with any text and observe the tool result complete.

4. Prove the direction of the call from the wire. Re-run the raw stdio probe, but declare *no* sampling capability, and call the same tool:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"no-sampling-client","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"summarize_incident","arguments":{"raw_log":"OOMKilled x14"}}}'
  sleep 4
} | .venv/bin/python interop/interop_server.py stdio 2>/dev/null | jq -c 'select(.id==5) | {isError:.result.isError, text:.result.content[0].text}'
```

Expected output (wording varies by SDK; the shape is the point):

```
{"isError":true,"text":"Error executing tool summarize_incident: Client does not support sampling"}
```

5. Record the trust boundary. Sampling is the one place where a server can influence what the client's model is asked:

```bash
cat > interop/sampling-controls.yaml <<'YAML'
control: "human in the loop"
spec_requirement: "clients SHOULD present the sampling request for approval"
what_the_client_controls:
  - "whether to forward the request at all"
  - "which model actually serves it (modelPreferences are hints)"
  - "the final prompt text, after user edits"
  - "whether the completion is returned verbatim to the server"
what_the_server_controls:
  - "the messages it asks for"
  - "maxTokens, systemPrompt, modelPreferences"
threat: "a malicious server uses sampling to exfiltrate context or to launder instructions"
YAML
.venv/bin/python -c "import yaml; print(len(yaml.safe_load(open('interop/sampling-controls.yaml'))['what_the_client_controls']), 'client-side controls')"
```

Expected output:

```
4 client-side controls
```

**Check your understanding**

- **Q24.** `summarize_incident` performs an LLM completion but ships with no API key. Trace the path of that completion request and name every component that pays for it. What does this mean for distributing a server to users whose model vendor you do not know?
- **Q25.** In step 4, the failure was reported as a tool result with `isError: true` rather than as JSON-RPC `-32601`. Why is that the correct choice here, and which capability should the server have checked first?
- **Q26.** `modelPreferences` lets a server express `costPriority`, `speedPriority` and `intelligencePriority`. Why are these hints rather than a model identifier, and how does that support interoperability across hosts that have entirely different model catalogues?
- **Q27.** Elicitation (revision 2025-06-18) lets a server ask the *user* for structured input mid-call. Name one integration that is impossible with a stateless REST call but natural with elicitation, and state the reason the request is routed through the client instead of the server prompting directly.

---

## Exercise 7 — Deciding when MCP is worth it

**Objective:** produce the artifact the exam's "Value" half is really testing — a defensible decision, including the cases where the answer is *no*.

### Steps

1. Describe a candidate server for the registry. Publishing metadata is what turns "we wrote a server" into "the organisation can find and reuse it":

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-07-09/server.schema.json",
  "name": "com.example.platform/incident-tools",
  "description": "Read-only access to incident history, runbooks and alert normalization",
  "version": "1.4.0",
  "repository": {
    "url": "https://git.internal.example.com/platform/mcp-incident-tools",
    "source": "gitlab"
  },
  "packages": [
    {
      "registryType": "oci",
      "identifier": "registry.internal.example.com/platform/mcp-interop-demo:1.4.0",
      "transport": {
        "type": "streamable-http",
        "url": "https://mcp.internal.example.com/incident/mcp"
      }
    }
  ]
}
```

2. Validate that it is a single, well-formed JSON document before you publish it anywhere:

```bash
jq -e 'has("name") and has("version") and (.packages|length>0)' interop/server.json \
  && echo "server.json shape OK"
```

Expected output:

```
true
server.json shape OK
```

3. Score four candidate integrations against the criteria that actually decide the question:

```yaml
criteria:
  - key: "reuse_count"
    question: "how many distinct hosts will consume this?"
  - key: "non_determinism"
    question: "does the caller need to choose at runtime which operation to invoke?"
  - key: "human_context"
    question: "does the result only make sense inside a conversation?"
candidates:
  - name: "Incident history lookup"
    reuse_count: 4
    non_determinism: "high"
    human_context: "yes"
    verdict: "MCP server"
  - name: "Nightly ETL: S3 to warehouse"
    reuse_count: 1
    non_determinism: "none"
    human_context: "no"
    verdict: "cron job, not MCP"
  - name: "Payment capture"
    reuse_count: 2
    non_determinism: "none"
    human_context: "no"
    verdict: "direct API call from deterministic code"
  - name: "Runbook search"
    reuse_count: 4
    non_determinism: "high"
    human_context: "yes"
    verdict: "MCP server"
```

Save that as `interop/decision-matrix.yaml` and check it:

```bash
.venv/bin/python - <<'PY'
import yaml
d = yaml.safe_load(open("interop/decision-matrix.yaml"))
for c in d["candidates"]:
    print(f"{c['name']:<32} reuse={c['reuse_count']}  verdict={c['verdict']}")
PY
```

Expected output:

```
Incident history lookup          reuse=4  verdict=MCP server
Nightly ETL: S3 to warehouse     reuse=1  verdict=cron job, not MCP
Payment capture                  reuse=2  verdict=direct API call from deterministic code
Runbook search                   reuse=4  verdict=MCP server
```

4. Write the one-paragraph justification a reviewer would accept, and keep it:

```bash
cat > interop/value-statement.md <<'MD'
We adopt MCP for the four integrations whose caller is a model choosing at
runtime among operations, and where the same integration is consumed by more
than one host. For those, M*N = 24 bespoke adapters collapse to 10 components,
and each server is written once against a published specification rather than
against four vendors' SDKs. We do NOT adopt MCP for deterministic pipelines:
a nightly ETL has one caller, no runtime choice, and no conversational context,
so a protocol whose entire purpose is exposing choice to a model adds a hop,
a session, and an approval surface while removing nothing.
MD
wc -l interop/value-statement.md
```

Expected output:

```
9 interop/value-statement.md
```

**Check your understanding**

- **Q28.** "Payment capture" scored `reuse_count: 2` but was still rejected. Which criterion overrode reuse, and what is the general rule about non-deterministic invocation of irreversible operations?
- **Q29.** The registry entry declares `"transport": {"type": "streamable-http", ...}` with an internal URL. What does publishing this metadata buy an organisation that a wiki page listing the same URL does not?
- **Q30.** Summarise the three claims from the opening section, and for each one name the specific artifact you produced in these exercises that proves it.

---

## Answers

<details>
<summary><strong>Show the answer key (Q1–Q30)</strong></summary>

**Q1.** The **M** artifacts are *client* implementations — one per host application (IDE, desktop app, CI agent, copilot). The **N** artifacts are *servers* — one per integration (Jira, Postgres, wiki, Kubernetes, PagerDuty, Grafana). A platform team typically writes neither in full: the M clients ship inside the host applications they did not build, and a growing share of the N servers are published by the integration's own vendor or by the community. The team's actual work is closer to "the servers nobody has written yet, plus configuration".

**Q2.** It is **configuration** that is duplicated, not code. Each host still needs to be told which servers to launch and with which arguments, and that is inherent — a host cannot use a server it has not been told about. What is *not* duplicated is the server's implementation, its schema definitions, its auth handling, its error mapping, or its tests. The M×N argument is about implementations, not about lines in config files; a per-host config entry is O(1) work in minutes, a per-host adapter is O(1) work in weeks.

**Q3.** **Shared:** in both cases the two sides of the matrix are genuinely independent — an editor knows nothing language-specific, a language server knows nothing editor-specific — and the interaction can be fully described as typed request/response messages over a stream, so a single wire specification suffices. Both use JSON-RPC 2.0 for exactly this reason. **Different in the AI case:** the *caller is non-deterministic*. LSP's caller is the editor executing a user's keystroke; MCP's caller is a model choosing at runtime. That forces MCP to carry things LSP never needed — machine-readable descriptions for tool selection, an explicit human-approval/trust model, and inverted requests (sampling, elicitation) where the server asks the client for a model completion or for user input.

**Q4.** Bespoke adapters go 24 → 35, a growth of **11**. MCP components go 10 → 12, a growth of **2**. The business argument is the *rate*: bespoke integration is O(M×N) — each new host multiplies the existing integration estate — while MCP is O(M+N), additive. On a platform that adds hosts and integrations continuously, the first curve is what makes integration work never finish.

**Q5.** **JSON-RPC 2.0** (message framing, ids, notifications, error codes) and the **MCP specification** (method names, the lifecycle, the shape of `params`/`result`). No SDK was involved. For a Go or Rust agent runtime this means the absence of an official SDK in your language is an inconvenience, not a blocker: any language that can write newline-delimited JSON to a subprocess's stdin, or POST to an HTTP endpoint, can be a fully conformant MCP client.

**Q6.** The **client** was at fault. The server correctly declared `capabilities: {"tools": {...}}` and nothing else, which is a complete and honest statement that it offers no resources. The rule: a client MUST NOT issue requests for a feature the server did not declare in its `initialize` result capabilities — capability negotiation is a contract, and `-32601` is the server enforcing it. Conformant clients gate `resources/*`, `prompts/*`, `logging/*` and `completion/*` on the corresponding declared capability.

**Q7.** It is a **notification**: a JSON-RPC message with a `method` but no `id`. The consequence is that the receiver MUST NOT send any response to it — neither a result nor an error. The sender therefore gets no acknowledgement and no error reporting at the JSON-RPC layer; it learns nothing about whether the message was understood. This is why notifications are used for fire-and-forget signals (`notifications/initialized`, `notifications/tools/list_changed`, `notifications/cancelled`, progress) and never for anything whose outcome the sender must know.

**Q8.** `-32601` is a **protocol error**: the request was malformed or the method does not exist. It is handled by the client's transport/plumbing code and is generally *not* something the model should see or try to fix — a model cannot repair a method-not-found. `"isError": true` inside a successful `tools/call` result is a **tool execution error**: the call was valid, the tool ran, and it failed for a domain reason ("file not found", "query timed out"). That one is deliberately delivered *inside* the result so the model receives it as content and can react — retry with a different path, ask the user, choose another tool. MCP separates them so that domain failures become part of the model's reasoning loop while protocol failures do not pollute it.

**Q9.** It must **adopt `2025-06-18` for the remainder of the session** — every subsequent message must conform to that revision, and it must not use any feature exclusive to a later revision. What it must **not** do is continue as if its own offer had been accepted, and must not assume that silence means agreement. If the counter-offered revision had been one the client does not support, the correct action is to disconnect rather than attempt requests.

**Q10.** The eleven older servers are unaffected. They will either counter-offer `2024-11-05` (and the client, supporting it, proceeds on that revision) or accept `2025-06-18` if their SDK was updated. The field that protects them is **`capabilities`** in the handshake — `elicitation` is a *client* capability, and a server that does not know what elicitation is simply never issues `elicitation/create`. Unknown capability keys are ignored, not fatal. Version negotiation and capability negotiation together mean unrecognised features degrade to "unused", never to "error".

**Q11.** Because compatibility is renegotiated on **every connection**, independently, per server. There is no shared build, no shared library version, no lockstep release. The weekly-updating host discovers on each launch what each quarterly-pinned server supports and adapts. In a bespoke-adapter architecture, each of the twelve adapters is compiled against the host's SDK, so a host upgrade is a twelve-way coordination event — which is precisely the cost that M×N hides.

**Q12.** Over **stdio**, the connection *is* the session: one subprocess, one lifetime, one negotiated revision, and the server holds that state in memory for the duration. Over **HTTP**, requests are independent and may hit different server processes, replicas, or intermediaries (proxies, gateways, load balancers) that have no memory of the handshake. The `MCP-Protocol-Version` header restates the negotiated revision on each request so any component handling it can interpret the body correctly without having witnessed `initialize`.

**Q13.** You changed the **transport** — `stdio` to `streamable-http` — which is the lowest layer of the protocol, responsible only for framing and delivering JSON-RPC messages. `tools/list` lives at the application layer, above it. MCP deliberately defines the transport as message-carriage only: it adds no semantics, so no application-layer payload is transport-dependent. That layering is the whole reason one server binary can serve a laptop over a pipe and a cluster over HTTPS.

**Q14.** It leaves the server free to answer either with a **single `application/json` body** or by **opening a `text/event-stream`** — the latter being what lets a server interleave progress notifications, logging, and its own requests (sampling, elicitation, `roots/list`) with the eventual response to your call. A client sending only `Accept: application/json` violates the spec for Streamable HTTP and will typically be rejected (HTTP 406); even if tolerated, it forecloses the server's ability to stream anything back, so long-running tools lose progress reporting and server-initiated requests have nowhere to go.

**Q15.** `notifications/initialized` is a **notification** (no `id`), so no response exists to return; HTTP `202 Accepted` with an empty body is the correct transport-level mapping of "received, nothing to say". `tools/list` is a **request** (`id: 2`), so exactly one response object carrying that same `id` must come back, and it needs a body to carry it.

**Q16.** `content[0].text` is for the **model** — an unstructured text block that goes into the conversation. `structuredContent` is for **code** — a JSON object validated against the tool's `outputSchema`, which a client, a UI, or a downstream automation can consume without re-parsing prose. If your SDK produced no `outputSchema`, then `structuredContent` would be the missing one: the spec ties structured output to a declared output schema. A client needing machine-readable output from such a server must fall back to parsing `content[0].text` itself — brittle, unvalidated, and exactly the failure mode structured output was added to remove.

**Q17.** **stdio**. The server must run on the same machine as the files, as the same OS user, inheriting that user's filesystem permissions, and its lifetime should be bound to the host process. The Kubernetes Deployment is wrong on every count: it runs elsewhere (no access to the laptop's disk), it is long-lived and shared across users (so one user's `roots` would not bound another's), and exposing a filesystem server over the network turns a local-permission model into a remote-access-control problem requiring full authorization. As a rule: local resource, local user identity → stdio; shared service, multiple remote consumers → Streamable HTTP with OAuth 2.1.

**Q18.** Streamable HTTP sessions are **stateful on the server**: the negotiated revision, the capability set, subscriptions, and any in-flight SSE stream live in one replica's memory. The header that identifies the requirement is **`Mcp-Session-Id`** — every request after the handshake carries it, and it must be routed back to the replica that issued it (session affinity), or the session must be externalised to shared storage. Round-robin across two replicas without either will produce sporadic `404`/session-not-found responses that look like flaky networking. Servers may also terminate a session at will and clients must be prepared to re-initialize.

**Q19.** That MCP describes tool inputs with **plain JSON Schema** in the `inputSchema` field, rather than with a bespoke type system or a language-specific signature format. Every major model vendor's function-calling API also takes JSON Schema; so the schema object itself is portable verbatim, and only the *envelope* field names differ (`parameters` vs `input_schema`). Translation is therefore a rename, which is why `jq` was sufficient.

**Q20.** Only the **client** — specifically, the small adapter layer inside the client that reshapes `tools/list` output into the new vendor's tool format and reshapes tool-call requests back into `tools/call`. The servers do not change (they never knew which model existed), the schemas do not change (they are JSON Schema either way), and the `tools/call` handling is identical because the protocol is the same. The anti-lock-in argument is that your integration estate — the expensive, domain-specific, slowly-accumulated part — has **zero coupling to the model vendor**; the coupling is isolated in one replaceable adapter.

**Q21.** The server is conformant. Three distinct statements: (a) **valid JSON Schema** — the document conforms to the JSON Schema dialect; (b) **valid MCP tool definition** — MCP requires `inputSchema` to be a JSON Schema object of `"type": "object"` and imposes no further dialect restriction, so this passes; (c) **accepted by a vendor's strict mode** — an additional, vendor-specific narrowing (commonly: `additionalProperties: false`, all properties `required`, a restricted keyword subset). The last one is not an MCP requirement, and treating a vendor's constraint as a protocol violation is a classic exam distractor. The fix belongs in the client's translation layer or in the server author's schema style, not in the spec.

**Q22.** **Tokens:** the tool list is serialised into the model's context on every turn, so 41 schemas consume context budget continuously, shrinking the room available for the actual conversation and for tool results — and increasing per-turn cost. **Accuracy:** tool-selection error rises with the number of near-identical candidates; 41 CRUD operations over the same resources give the model many plausible-but-wrong choices, and the failure is silent (it calls the wrong one and returns a confident answer). Curated tools that encode a *workflow* rather than a *storage operation* reduce both at once.

**Q23.** Annotations are **hints, not guarantees**, and a client MUST NOT treat them as a security control — they are supplied by the server, which is precisely the party a security control would be protecting against. A malicious or buggy server can label a destructive tool `readOnlyHint: true`. Their legitimate use is UX: deciding what to auto-approve for *trusted* servers, how to word a confirmation dialog, whether to offer an undo. Enforcement belongs to the **host/client** — human approval, sandboxing, credential scoping, network policy, and the permissions the server was actually granted.

**Q24.** The tool calls `ctx.session.create_message`, which sends a **`sampling/createMessage` request from the server to the client** over the same connection. The client decides whether to honour it, selects a model from *its* catalogue, runs the completion against *its* credentials, and returns the text. Therefore: the **user's host** pays, with the **user's** API key or subscription. For distribution this is the key property — you can publish a server that does genuinely model-dependent work without shipping credentials, without knowing which vendor the user runs, without a billing relationship, and without becoming a data processor for their prompts.

**Q25.** Because the request was well-formed and the method exists — `tools/call` for a declared tool is a perfectly valid request, so a `-32601` would be a false statement about the protocol. The failure is a **domain/runtime condition** of that tool, so it belongs in the result with `isError: true`, where the model can see it and choose another approach. What the server *should* have done first is check the **client capabilities captured at `initialize`** — if `sampling` was absent, a well-built server either hides the tool from `tools/list` entirely or returns a clear, early `isError` explaining the requirement, rather than discovering it mid-execution.

**Q26.** Because the server has no idea what models the client has. Hosts differ entirely in catalogue, in what they are licensed to run, in what the user's org permits, and in local-vs-cloud policy; a hard-coded model identifier would make the server work on one host and fail everywhere else — reintroducing exactly the coupling MCP removes. Priority hints let the server express *what it needs* ("this is a bulk classification, favour cost and speed" vs "this is a judgement call, favour capability") in terms every host can map onto its own catalogue. The client retains final authority over model choice, which is also required for it to enforce cost and data-residency policy.

**Q27.** Any interaction requiring information the caller did not know it would need — for example, a deployment tool that discovers mid-run that three clusters match the name and must ask *which one*, or a tool that must collect a change-ticket number before proceeding. A stateless REST call must either fail, guess, or demand every possible parameter upfront. The request is routed **through the client** because the server has no user interface and no channel to the human: the client owns the UI, owns the trust relationship with the user, can render the requested JSON Schema as a form, can let the user decline, and can strip or validate the response. Routing it through the client is also what keeps a server from directly soliciting credentials — the spec explicitly directs that elicitation not be used to request sensitive information, and the client is the enforcement point.

**Q28.** **Non-determinism** overrode reuse. The general rule: an operation that is irreversible, externally visible, or financially consequential should be invoked by **deterministic code** that decided to invoke it, not by a model choosing at runtime among options. MCP's value comes precisely from exposing choice to a model; where that choice must not exist, the protocol's central feature is a liability. If such an operation must be reachable at all, it belongs behind an explicit human confirmation step with `destructiveHint`/`idempotentHint` set honestly — and even then, the reuse benefit rarely justifies the blast radius.

**Q29.** Machine-readable **discovery and installation**. A registry entry has a stable identifier in reverse-DNS namespace, a declared version, a package/transport descriptor, and a schema — so a host, an internal portal, or a provisioning tool can enumerate available servers, resolve a specific version, and configure a connection automatically. A wiki page requires a human to read it and hand-edit a config file, gives no version semantics, and drifts silently. In M+N terms, the registry is what makes the "N" side *reusable in practice* rather than only in principle: the server exists organisation-wide instead of in the team that wrote it.

**Q30.**

| Claim | Artifact that proves it |
|---|---|
| **Integration economics: M×N → M+N** | The computed `24 → 10` in Exercise 1, plus the same unmodified `server-filesystem` attached to two different hosts with zero source edits; growth rate confirmed in Q4 (11 vs 2). |
| **Substitutability** | `diff interop/contract-stdio.json interop/contract-http.json` returning `IDENTICAL CONTRACT` (transport axis); `SCHEMA PRESERVED ACROSS VENDORS` from the two `jq` translations (model-vendor axis); and driving a TypeScript server from `bash` (language axis). |
| **Negotiated compatibility** | The three handshake probes in Exercise 3 — a future revision counter-offered down to `2025-06-18`, a past revision accepted as `2024-11-05`, and `-32601` returned for an undeclared capability. Compatibility is observable on the wire, not assumed. |

</details>

---

## References

- Linux Foundation — *Model Context Protocol Associate (MCPA)*: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
- MCP specification, revision 2025-06-18 — index: https://modelcontextprotocol.io/specification/2025-06-18/
- MCP specification — lifecycle, version and capability negotiation: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- MCP specification — transports (stdio, Streamable HTTP): https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- MCP specification — tools, annotations and structured output: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- MCP specification — sampling: https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- MCP specification — elicitation: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- MCP specification — authorization (OAuth 2.1, RFC 9728, RFC 8707): https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- JSON-RPC 2.0 specification (error codes, notifications): https://www.jsonrpc.org/specification
- JSON Schema: https://json-schema.org/
- MCP Inspector: https://github.com/modelcontextprotocol/inspector
- MCP Registry and `server.json`: https://github.com/modelcontextprotocol/registry
- Language Server Protocol (the M×N precedent): https://microsoft.github.io/language-server-protocol/