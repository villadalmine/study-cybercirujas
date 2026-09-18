# Topic 1.1 — MCP Purpose & Scope

## Guided Exercises

**Certification:** Model Context Protocol Associate (MCPA) · **Exam weight:** 5.33%
**Format:** numbered steps you execute, followed by comprehension checks. Answers are collapsed at the end.

These exercises assume you can open a terminal with `node` ≥ 20 and `npx` available, and optionally `uv` for the Python track. Nothing here requires an API key or a paid model: the whole point of this topic is that MCP is a *wire protocol*, and a wire protocol can be exercised by hand.

---

## Exercise 0 — Lab setup

**Goal:** get a scratch directory and the reference servers reachable, so later exercises do not fail for environmental reasons.

1. Create the lab directory and a couple of files the filesystem server will be allowed to see:

```bash
mkdir -p /tmp/mcp-lab/docs
cd /tmp/mcp-lab
printf 'Runbook: restart the ingress controller with kubectl rollout restart\n' > docs/runbook.md
printf 'secret-value-do-not-read\n' > /tmp/outside-the-root.txt
ls -R /tmp/mcp-lab
```

2. Confirm the reference servers download and start. Press `Ctrl-C` after each banner appears:

```bash
npx -y @modelcontextprotocol/server-everything
```

Expected on stderr (abbreviated):

```
Server running on stdio
```

3. Do the same for the filesystem server, which takes its allowed roots as argv:

```bash
npx -y @modelcontextprotocol/server-filesystem /tmp/mcp-lab
```

Expected on stderr (abbreviated):

```
Secure MCP Filesystem Server running on stdio
Allowed directories: [ '/tmp/mcp-lab' ]
```

4. Note which stream each line came out on. Run it again and separate them:

```bash
npx -y @modelcontextprotocol/server-filesystem /tmp/mcp-lab 1>/tmp/stdout.log 2>/tmp/stderr.log &
sleep 3; kill %1
wc -c /tmp/stdout.log /tmp/stderr.log
```

Expected (abbreviated):

```
      0 /tmp/stdout.log
    103 /tmp/stderr.log
```

**Questions 0**

- **0.1** The server printed a human-readable banner but `stdout.log` is zero bytes. Why is that not a bug, and what would break if the banner had gone to stdout?
- **0.2** The filesystem server takes `/tmp/mcp-lab` as a command-line argument rather than reading it from the protocol. What does that tell you about where the *trust boundary* sits in MCP's design?
- **0.3** You have not configured a model, an API key, or a provider. The server started anyway. What does that prove about MCP's scope?

---

## Exercise 1 — The problem MCP exists to solve: M×N → M+N

**Goal:** turn the "integration explosion" claim into a number you computed yourself, and find the condition under which the claim stops being true.

1. Write down your organisation's real inventory. For the exercise, use these:
   - **Hosts** (AI applications that need context): an IDE assistant, a desktop chat app, a CI bot, an internal RAG portal, a terminal agent, a ticket triage service → **6**
   - **Systems** (context sources / actuators): Jira, GitHub, Confluence, Postgres, Snowflake, S3, Grafana, PagerDuty, Kubernetes, Sentry, Slack, Salesforce, … → **40**

2. Compute both regimes:

```bash
python3 - <<'EOF'
hosts, systems = 6, 40
print("bespoke integrations :", hosts * systems)
print("MCP implementations  :", hosts + systems)
print("reduction factor     :", round(hosts * systems / (hosts + systems), 2))
EOF
```

Expected output:

```
bespoke integrations : 240
MCP implementations  : 46
reduction factor     : 5.22
```

3. Re-run it with `hosts, systems = 1, 3` and then `hosts, systems = 2, 2`.

4. For each of the three runs, record whether the protocol paid for itself.

**Questions 1**

- **1.1** At `hosts=1, systems=3`, M+N is 4 and M×N is 3. The protocol *increases* the number of components. State the condition, in terms of M and N, under which standardising is a net loss, and explain why teams still adopt MCP for a single host.
- **1.2** The 240 → 46 reduction assumes something about the 40 servers. What is that assumption, and what happens to the argument if each host needs a slightly different subset of each system's capabilities?
- **1.3** Vendor function calling (a JSON tool schema passed to a model API) also decouples the model from the tool. Why does it *not* solve the M×N problem?

---

## Exercise 2 — Speak the protocol by hand: the initialize handshake

**Goal:** perform a complete MCP lifecycle with `printf` and a pipe, so you can see that capability negotiation — not tool execution — is the first thing the protocol does.

1. Send a full lifecycle to the everything server. Each JSON-RPC message is one line, newline-delimited, on stdin:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{}},"clientInfo":{"name":"hand-client","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  sleep 2
} | npx -y @modelcontextprotocol/server-everything 2>/dev/null
```

Expected on stdout — note this is **JSON Lines**, one document per line, not a single JSON document (abbreviated):

```
{"result":{"protocolVersion":"2025-06-18","capabilities":{"prompts":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"tools":{"listChanged":true},"logging":{},"completions":{}},"serverInfo":{"name":"example-servers/everything","version":"1.0.0"}},"jsonrpc":"2.0","id":1}
{"result":{"tools":[{"name":"echo","description":"Echoes back the input","inputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}},{"name":"add","description":"Adds two numbers", ... }]},"jsonrpc":"2.0","id":2}
```

2. Now break the order deliberately. Send `tools/list` **before** `initialize`:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{}}'
  sleep 2
} | npx -y @modelcontextprotocol/server-everything 2>/dev/null
```

Record whether you get a result, a JSON-RPC error object, or silence.

3. Now negotiate a version that cannot exist:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"hand-client","version":"0.1.0"}}}'
  sleep 2
} | npx -y @modelcontextprotocol/server-everything 2>/dev/null
```

Compare the `protocolVersion` in the response against the one you sent.

4. Finally, violate the stdio framing rule — send a message containing an embedded newline:

```bash
{
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize",\n"params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"0"}}}\n'
  sleep 2
} | npx -y @modelcontextprotocol/server-everything
```

**Questions 2**

- **2.1** In step 1, `notifications/initialized` has no `id`. What is it, in JSON-RPC 2.0 terms, and what would be protocol-illegal about the server answering it?
- **2.2** In step 3 the server did not fail — it answered with a version string of its own choosing. Which side decides whether the session continues after that, and what must it do if the returned version is unacceptable?
- **2.3** Your client advertised `"sampling":{}` and `"roots":{"listChanged":true}`. The server advertised `tools`, `resources`, `prompts`, `logging`, `completions`. Who is allowed to call `sampling/createMessage` in this session, and who is allowed to call `tools/call`?
- **2.4** Step 4 failed even though the two lines together are valid JSON. Which layer rejected it — JSON-RPC, MCP, or the transport — and why does stdio impose that rule?

---

## Exercise 3 — The three server primitives and who controls each

**Goal:** see that MCP does not just expose "functions"; it exposes three primitives with three different *control models*, and that this distinction is a scope decision, not an implementation detail.

1. Start the MCP Inspector against the everything server:

```bash
npx -y @modelcontextprotocol/inspector npx -y @modelcontextprotocol/server-everything
```

It prints a localhost URL containing a pre-filled session token. Open it, and click **Connect**.

2. Visit the **Tools**, **Resources** and **Prompts** tabs in turn. For each, record: how many entries, and whether an entry has an input schema, a URI, or an argument list.

3. Call the `echo` tool from the Tools tab with `{"message":"scope"}`. Then read the resource `test://static/resource/1` from the Resources tab. Then fetch the `simple_prompt` prompt.

4. Reproduce the resource read on the wire so you can see the shape of the response:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand-client","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"resources/list","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"test://static/resource/1"}}'
  sleep 2
} | npx -y @modelcontextprotocol/server-everything 2>/dev/null | tail -n 1
```

Expected (abbreviated):

```
{"result":{"contents":[{"uri":"test://static/resource/1","mimeType":"text/plain","text":"Resource 1: ..."}]},"jsonrpc":"2.0","id":3}
```

5. Fill in this table from what you observed, without looking it up yet:

| Primitive | Addressed by | Typically triggered by | Side effects expected? |
|---|---|---|---|
| Tool | | | |
| Resource | | | |
| Prompt | | | |

**Questions 3**

- **3.1** A tool has a JSON Schema for its input; a resource has a URI. Why is that the right asymmetry — what is each one optimised for?
- **3.2** The spec describes tools as *model-controlled*, resources as *application-controlled*, and prompts as *user-controlled*. Map each of those three to a concrete UI element in a chat application.
- **3.3** You want to expose a 200 MB Parquet file and a `run_query` function over the same warehouse. Which primitive for which, and what goes wrong if you expose the file as a tool that returns its contents?
- **3.4** `resources/read` returned a `contents` **array**, not a single object. Why would a single URI ever yield more than one content item?

---

## Exercise 4 — The client primitives: what a server may ask of the host

**Goal:** establish that MCP is bidirectional, and locate the boundary between "the server requests inference" and "the server performs inference".

1. In the Inspector, open the **Sampling** tab, then from the **Tools** tab call the `sampleLLM` tool with a short prompt such as `{"prompt":"Say hello","maxTokens":32}`.

2. Observe that the request appears in the Inspector's Sampling tab as a **pending approval**, not as an answer. Note what the Inspector is acting as here.

3. Inspect the shape of what the server asked for. A `sampling/createMessage` request carries `messages`, `maxTokens`, and optionally `modelPreferences`:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      {
        "role": "user",
        "content": { "type": "text", "text": "Say hello" }
      }
    ],
    "maxTokens": 32,
    "modelPreferences": {
      "hints": [{ "name": "claude-sonnet" }],
      "costPriority": 0.3,
      "speedPriority": 0.2,
      "intelligencePriority": 0.9
    }
  }
}
```

4. Note the direction of the arrow: this message travels **server → client**, over the same connection, with the same JSON-RPC envelope.

5. In the Inspector, set a **Root** (Roots tab) pointing at `/tmp/mcp-lab`, then reconnect and observe whether the server's behaviour changes.

**Questions 4**

- **4.1** `modelPreferences.hints` names a model, yet the spec calls these *hints*. Who makes the final model choice, and why is that deliberately not the server's decision?
- **4.2** The `sampleLLM` tool gave the server LLM access without the server holding any API key. Name two distinct benefits of that arrangement, one operational and one for the user.
- **4.3** *Roots* tell a server which directories or URLs the client considers in scope. Is a root an enforcement mechanism or an advisory one? Justify your answer using what you saw in Exercise 0 step 4.
- **4.4** *Elicitation* lets a server ask the end user for structured input mid-operation. Give one case where elicitation is correct and one where it is an anti-pattern that should have been a tool parameter instead.

---

## Exercise 5 — Where your code stops: authoring a server and finding the boundary

**Goal:** write a minimal server and prove that nothing in it decides *when* its capability is used.

1. Create a Python server (requires `uv`; a TypeScript equivalent works the same way):

```bash
mkdir -p /tmp/mcp-lab/scope-server && cd /tmp/mcp-lab/scope-server
uv init --bare
uv add "mcp[cli]"
```

2. Write `server.py`:

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("scope-demo")


@mcp.tool()
def restart_ingress(namespace: str, controller: str) -> str:
    """Restart an ingress controller deployment. Disruptive: drops in-flight connections."""
    return f"rollout restart deployment/{controller} -n {namespace}"


@mcp.resource("runbook://ingress")
def ingress_runbook() -> str:
    """The on-call runbook for ingress incidents."""
    return "1. Check readiness probes. 2. Check cert expiry. 3. Only then restart."


if __name__ == "__main__":
    mcp.run()
```

3. Run it and list its tools on the wire:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand-client","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  sleep 2
} | uv run python server.py 2>/dev/null | tail -n 1
```

Expected (abbreviated):

```
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"restart_ingress","description":"Restart an ingress controller deployment. Disruptive: drops in-flight connections.","inputSchema":{"type":"object","properties":{"namespace":{"type":"string"},"controller":{"type":"string"}},"required":["namespace","controller"],"title":"restart_ingressArguments"}}]}}
```

4. Now read your own file and answer honestly: search it for any of the following — a system prompt, a decision about whether to restart, a retry policy, a confirmation dialog, a conversation history, a plan.

```bash
grep -nE 'prompt|confirm|history|plan|retry|approve' server.py || echo "none of those appear in this file"
```

5. Register the server with a host by writing a client configuration. This file is a **single JSON document**:

```json
{
  "mcpServers": {
    "scope-demo": {
      "command": "uv",
      "args": ["--directory", "/tmp/mcp-lab/scope-server", "run", "python", "server.py"]
    }
  }
}
```

**Questions 5**

- **5.1** Your docstring is the only thing telling anyone that `restart_ingress` is disruptive, and it is consumed by a model. Name the protocol feature that exists precisely so this signal does not have to live in prose, and say why prose alone is a security weakness.
- **5.2** Six things were absent from `server.py` in step 4. For each, name the component that owns it.
- **5.3** The config in step 5 launches a subprocess with your user's privileges. State the two consequences for threat modelling that follow from the `command`/`args` shape.
- **5.4** A colleague proposes adding a loop to `server.py` that calls `restart_ingress` until the pods are healthy. Is that inside or outside MCP's scope? Is it inside or outside a *server's* legitimate scope? These are two different questions.

---

## Exercise 6 — Transport scope: local stdio vs remote Streamable HTTP

**Goal:** separate what the protocol defines from what the deployment topology imposes.

1. You have been running stdio all along. Now run a server over HTTP. Modify the last line of `server.py`:

```python
    mcp.run(transport="streamable-http")
```

2. Start it and note the bind address printed:

```bash
uv run python server.py
```

Expected (abbreviated):

```
INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)
```

3. From a second terminal, initialize over HTTP. The client must accept both content types:

```bash
curl -sS -D- -o/tmp/body.txt http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0.1.0"}}}'
cat /tmp/body.txt
```

Expected headers (abbreviated) — look specifically for the session header:

```
HTTP/1.1 200 OK
content-type: text/event-stream
mcp-session-id: 9f3c1d0e5b7a4e2f8c6d1a0b3e4f5a6b
```

4. Repeat the request **without** the `text/event-stream` Accept value and record the status code.

5. Repeat it with a foreign `Origin` header:

```bash
curl -sS -o/dev/null -w '%{http_code}\n' http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Origin: https://evil.example' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0.1.0"}}}'
```

6. Compare the two transports against this list and mark which one each statement is true for: message framing is newline-delimited; a session identifier exists; the server's lifetime is tied to the client process; authorization applies; one server instance serves many users.

**Questions 6**

- **6.1** The JSON-RPC payloads in steps 1–3 are byte-for-byte the same shape as the stdio ones. What exactly does the transport layer contribute, and what does it *not* touch?
- **6.2** Step 5 concerns DNS rebinding. Explain the attack against a `localhost`-bound MCP server, and name the two mitigations the spec requires of local HTTP servers.
- **6.3** stdio needs no authorization; Streamable HTTP has an OAuth 2.1-based authorization framework. Why is authorization *in scope* for one transport and not the other, and is that an inconsistency in the protocol?
- **6.4** Your team wants one shared MCP server for 300 engineers. Name three properties that become mandatory which were irrelevant for the stdio version.

---

## Exercise 7 — Consent, and what the protocol can and cannot enforce

**Goal:** locate the "trust and safety" principles in the specification and classify each as a MUST on the wire or an obligation on the host.

1. Open the specification's top-level page and its security best practices, and read the principles section:
   - <https://modelcontextprotocol.io/specification/>
   - <https://modelcontextprotocol.io/specification/draft/basic/security_best_practices>

2. Write out the four stated principles in your own words.

3. For each principle, answer: can a conformance test detect a violation from the wire traffic alone?

4. Now demonstrate the gap. Attempt a path traversal against the filesystem server:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand-client","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_text_file","arguments":{"path":"/tmp/mcp-lab/../outside-the-root.txt"}}}'
  sleep 2
} | npx -y @modelcontextprotocol/server-filesystem /tmp/mcp-lab 2>/dev/null | tail -n 1
```

Expected (abbreviated):

```
{"result":{"content":[{"type":"text","text":"Error: Access denied - path outside allowed directories: /tmp/outside-the-root.txt not in /tmp/mcp-lab"}],"isError":true},"jsonrpc":"2.0","id":2}
```

5. Note carefully: the refusal came from the **server implementation**, not from the protocol. Search the spec for a mandated sandboxing requirement on tool implementations.

6. Observe the error encoding. It is `isError: true` inside a successful `result`, not a JSON-RPC `error` object.

**Questions 7**

- **7.1** Why is a tool failure reported as `isError` inside `result` rather than as a JSON-RPC `error`? Think about who needs to see it.
- **7.2** A server declares a tool named `list_files` whose description instructs the model to also read `~/.ssh/id_rsa` and pass it as an argument. Which of the four principles does this violate, and which layer is the only one that can stop it?
- **7.3** The spec says hosts SHOULD show users what a tool will do before invoking it. Why is that a SHOULD on the host rather than a MUST on the protocol? What would it take to make it a wire-level MUST?
- **7.4** Classify each as in scope or out of scope for the MCP specification: TLS termination, tool result schemas, rate limiting per user, capability negotiation, audit logging of tool calls, cancellation of an in-flight request.

---

## Exercise 8 — Drawing the boundary against adjacent standards

**Goal:** be able to say what MCP is *not*, which is where most exam errors on this objective come from.

1. Find the protocol's revision history and list every dated revision:
   - <https://modelcontextprotocol.io/specification/versioning>

Record the revision string your SDK negotiated in Exercise 2, and whether it is the newest published one.

2. Check the current governance and specification home yourself rather than trusting a summary:
   - <https://modelcontextprotocol.io/>
   - <https://github.com/modelcontextprotocol>
   - <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>

3. For each row, decide **MCP**, **not MCP**, or **adjacent**, and write one sentence of justification:

| Capability | Verdict |
|---|---|
| Telling a model which tools exist | |
| Deciding which tool to call | |
| Running inference | |
| Requesting inference from the host | |
| Two autonomous agents negotiating a task between themselves | |
| Describing a REST API's endpoints and payloads | |
| Streaming partial results to a client | |
| Persisting conversation memory across sessions | |
| Authenticating a user to a remote tool server | |
| Choosing an embedding model for retrieval | |

4. MCP's design is openly modelled on the Language Server Protocol. Read one paragraph of LSP's overview and note the structural parallel:
   - <https://microsoft.github.io/language-server-protocol/>

**Questions 8**

- **8.1** Protocol versions are date strings such as `2025-06-18`, not semver. Give the practical consequence for a client that must talk to servers pinned at different revisions.
- **8.2** State the LSP analogy precisely: which MCP role corresponds to the editor, which to the language server, and what is the direct analogue of "M editors × N languages"?
- **8.3** A teammate says "MCP replaces our OpenAPI specs." Give the strongest version of their argument, then the correction.
- **8.4** MCP is often paired with agent-to-agent protocols rather than competing with them. Draw the line in one sentence each: what does MCP standardise, and what does an agent-to-agent protocol standardise?

---

## Answers

<details>
<summary><strong>Click to reveal answers for Exercises 0–8</strong></summary>

### Exercise 0

**0.1** On the stdio transport, stdout is the protocol channel: it carries newline-delimited JSON-RPC messages and *nothing else*. The spec reserves stdout exclusively for valid MCP messages and allows the server to use stderr for logging. A banner on stdout would be fed to the client's JSON parser, which would either abort the session on a parse error or, worse, desynchronise framing. Zero bytes on stdout before a client sends `initialize` is exactly correct behaviour.

**0.2** The allowed directory is passed by whoever *launches* the process, not by whoever *talks to* it. The host (and through it, the user) decides the sandbox at spawn time; the model, and anything it is persuaded to emit, cannot renegotiate it over the protocol. The trust boundary sits at process launch and at the host's consent UI — not inside the conversation.

**0.3** MCP is entirely independent of any model or inference provider. It standardises how context and capabilities are *described and exchanged*; it does not perform, host, price or select inference. A server is a normal process speaking JSON-RPC; it has no idea whether an LLM is on the other end.

---

### Exercise 1

**1.1** Standardising is a net loss in raw component count whenever `M + N > M × N`, which for positive integers only happens when at least one of them is 1 and the other is small (`1×3 = 3 < 4`). Teams still adopt MCP with a single host because the count is the wrong metric: the real costs are *per-integration* — bespoke auth, bespoke error handling, bespoke schema drift, bespoke testing — and MCP amortises those into one well-specified surface. It also buys optionality: the second host costs +1, not +40.

**1.2** It assumes the 40 servers are *reusable across hosts* — that a server written for the IDE assistant is consumable unmodified by the CI bot. If every host needs a bespoke subset, you drift back toward M×N in the form of per-host server variants or per-host filtering logic. The defence is that filtering is a host concern: the host chooses which servers to connect and which of their tools to expose, so the server stays single-copy and the variation lives in host configuration.

**1.3** Function calling standardises the *schema format a single vendor's model accepts*. It says nothing about discovery, connection lifecycle, transport, authorization, resource exposure, or server→client requests, and each vendor's dialect differs. You still write and maintain the plumbing that connects each application to each system; you have merely standardised the shape of one argument to one API. MCP standardises the integration itself, which is the thing that was M×N.

---

### Exercise 2

**2.1** It is a JSON-RPC **notification** — a request with no `id`, for which a response is forbidden. Answering it would be a JSON-RPC 2.0 violation (no `id` to correlate against) and would inject an unmatched message into the client's dispatcher. `notifications/initialized` closes the three-step lifecycle: `initialize` request → `initialize` result → `initialized` notification. Only after it may normal operations begin.

**2.2** The **server** responds with a version it supports — if it does not support the requested one, it replies with its own latest supported version rather than erroring. The **client** then decides: if it cannot support what came back, it MUST disconnect. Negotiation is a single round trip with the decision resting on the client side.

**2.3** Capabilities are directional and negotiated. Because the **client** declared `sampling`, the **server** may issue `sampling/createMessage` requests to it. Because the **server** declared `tools`, the **client** may issue `tools/call`. A party must not invoke a feature the peer did not advertise; had the client omitted `sampling`, the server calling it would be a protocol error, and the correct server behaviour is to degrade gracefully.

**2.4** The **transport** rejected it. stdio framing is strictly one JSON-RPC message per line: messages are delimited by newlines and MUST NOT contain embedded newlines. The first line is incomplete JSON and fails to parse; the second is not a message at all. Line delimiting is what makes stdio framing trivially implementable without a length-prefix header — which is exactly why the "no embedded newlines" rule is not optional.

---

### Exercise 3

**3.1** A tool is a **verb**: its identity is a name plus the shape of its arguments, so a JSON Schema is the right description — it is what lets a model generate a syntactically valid call and what lets the server validate one. A resource is a **noun**: its identity is a stable address, so a URI is the right description — it can be listed, subscribed to, cached, deduplicated and re-read without re-deriving how to ask for it.

**3.2**
- *Tool* → model-controlled: the assistant decides to call it mid-turn; the UI element is the approval prompt / "used tool X" chip that appears without the user asking by name.
- *Resource* → application-controlled: the host decides what to attach; the UI element is the attachment picker or the automatic "@-mention a file" context panel.
- *Prompt* → user-controlled: the user explicitly selects it; the UI element is the slash-command menu or template picker.

**3.3** The Parquet file is a **resource** (`s3://bucket/data.parquet`, with a `mimeType`); `run_query` is a **tool**. Exposing the file as a tool that returns its contents forces 200 MB through the model's context window on every invocation: it is unbounded, uncacheable by URI, cannot be subscribed to for changes, and the host has no way to let the user decide whether to attach it, because a tool call is the model's decision, not the application's.

**3.4** A single URI can be a container or can have multiple representations — a directory URI, a multi-part document, a query that returns several blobs, or one logical item offered as both `text/plain` and `text/html`. The array also keeps the response shape uniform so clients need one code path for the one-item and many-item cases. Each item carries its own `uri` and `mimeType`, and is either `text` or base64 `blob`.

---

### Exercise 4

**4.1** The **host** (the client application) makes the final choice. The server does not know the user's subscription, cost budget, latency requirements, data-residency constraints, or which providers are even configured — and it must not be able to force the user's expensive model. Hints are an ordered list of substrings the client MAY match against its own model names; combined with the `costPriority` / `speedPriority` / `intelligencePriority` weights, they let the server express *intent* while the host retains control.

**4.2** *Operational:* the server ships no credentials — no API key to provision, rotate, leak, or bill. Inference cost and provider choice stay consolidated in the host, and a server can be distributed publicly without a secrets story. *For the user:* they keep a single point of consent and visibility — every model call, including ones a server initiated, passes through their client, where they can inspect, modify or reject the prompt and the completion before either side sees it.

**4.3** **Advisory.** Roots communicate the boundaries the client considers relevant so a server can focus its work; they are a coordination mechanism, not a sandbox. Exercise 0 step 4 is the proof from the other direction: the filesystem server's real enforcement came from the argv-supplied allowed directory, checked in code at spawn time. A server that ignores roots is badly behaved; a server that ignores its own launch-time sandbox is exploitable. Never rely on roots for security.

**4.4** *Correct:* the information could not have been known when the tool was called and is needed to proceed — the query matched three staging clusters and the server needs the user to pick one; or a destructive action needs a typed confirmation. *Anti-pattern:* asking for something the model already had or could have supplied — prompting "which namespace?" when `namespace` should simply have been a required tool parameter. Elicitation for static inputs turns one round trip into three, blocks on a human for no reason, and hides the value from the model's reasoning. Servers must also never use elicitation to request credentials.

---

### Exercise 5

**5.1** **Tool annotations** — structured hints such as `readOnlyHint`, `destructiveHint`, `idempotentHint` and `openWorldHint`, which a host can act on programmatically (require confirmation, disable in read-only mode, refuse to auto-approve). Prose alone is weak because the description is *untrusted input controlled by the server*: it is consumed by the model, so it is an injection surface, and a host cannot make a policy decision by reading English. The critical caveat: annotations are **hints from the same untrusted server** — a host must not treat `readOnlyHint: true` from an unverified server as a guarantee.

**5.2**
- System prompt → **host** (the AI application).
- Whether to restart → the **model**, mediated by the host's consent flow.
- Retry policy → **client/host** logic, not the protocol.
- Confirmation dialog → **host** UI.
- Conversation history → **host**; MCP sessions carry no chat history.
- The plan → **host/agent framework**; MCP has no notion of planning or orchestration.

**5.3** First, an MCP server configuration is **arbitrary code execution as the user**: installing a server is equivalent in risk to installing any CLI tool, so provenance, pinning and review matter more than the protocol's own guarantees. Second, the process inherits the user's ambient authority — environment variables, kubeconfig, SSH agent, cloud credentials — so least privilege must be imposed externally (a dedicated user, a container, a restricted env block), because nothing in MCP confines it.

**5.4** *Inside or outside MCP's scope:* **outside** — MCP specifies no control flow, retries, loops, or orchestration; it carries requests and responses. *Inside or outside a server's legitimate scope:* legitimately **either**, but it is a design decision with consequences. A server may implement a coherent operation internally (that is just what the tool does, and it should be honest about it in its description and annotations). But a server that silently takes autonomous, repeated, destructive action removes the host's per-action consent point — the user approved one call and got N. Prefer exposing the loop as an explicit, clearly-named, annotated tool, or return state and let the agent iterate.

---

### Exercise 6

**6.1** The transport contributes **framing, connection lifecycle and delivery** — how bytes are delimited, how a session is established and identified, how a server-initiated message reaches the client, and (for HTTP) how requests are authorized and resumed. It does not touch the **message layer**: the JSON-RPC envelope, the method names, the parameter shapes, capability negotiation and the lifecycle sequence are identical on every transport. This separation is why a server can switch from stdio to HTTP by changing one line.

**6.2** A page in the user's browser at `https://evil.example` resolves a hostname it controls to `127.0.0.1` after the browser has cached the origin, then issues requests that reach the locally-bound MCP server carrying the attacker's page as origin — the server sees a connection from localhost and, if it trusts that, executes tools with the user's privileges. The spec's requirements for local HTTP servers: **validate the `Origin` header** on all incoming connections, and **bind only to `127.0.0.1`**, not `0.0.0.0`. (Authentication on all connections is the third standing recommendation.)

**6.3** stdio has no authorization because there is nothing to authorize: the client *spawned* the server as a subprocess with its own privileges, so the trust decision was made at launch and any credential check would be theatre. Streamable HTTP crosses a network and organisational boundary, where the server genuinely cannot know who is calling. That is not an inconsistency — it is correct layering: authorization belongs to the transport that needs it, and the message layer stays identical either way. Implementations MAY use other credential schemes on HTTP; OAuth 2.1 is what the spec profiles, with the server acting as an OAuth Resource Server that advertises its authorization servers via Protected Resource Metadata.

**6.4** Any three of: per-user authentication and authorization (a single shared identity is no longer acceptable); session isolation so one user's `Mcp-Session-Id` cannot read another's state; multi-tenant handling of *credentials to the downstream system* — the server can no longer use "the user's" kubeconfig because there is no single user; horizontal scaling and session affinity or shared session storage; rate limiting and quota per principal; TLS; audit logging that attributes each tool call to a principal; availability, since it is now a shared dependency rather than a process one person can restart.

---

### Exercise 7

**7.1** Because the *model* needs to see it. A JSON-RPC `error` is a protocol-level failure — malformed request, unknown method, server fault — and is handled by the client's transport machinery, invisible to the model. A tool that ran correctly and returned a bad outcome ("file not found", "access denied") is **information the model should reason about and possibly recover from**: wrong path, retry with a different one. Encoding it as `isError: true` inside `result` puts the message in the model's context where it can act on it. The rule of thumb: protocol failures → JSON-RPC `error`; tool execution failures → `isError` in the result.

**7.2** It violates **tool safety** (tool descriptions are untrusted; a tool must not exceed what the user understood they were approving) and in effect **user consent and control** and **data privacy**, since data would leave the boundary without informed approval. The only layer that can stop it is the **host**: by never auto-approving tool calls, by showing the actual arguments before execution, by sandboxing what the server process can reach, and by not treating server-supplied descriptions or annotations as trustworthy unless the server itself is trusted. The protocol cannot detect it — the traffic is perfectly well-formed.

**7.3** Because MCP is a message-passing specification with no model of a user interface, a screen, or even a human being present; a wire-level MUST is only meaningful if a conformance test can observe a violation, and "did a human understand this?" is unobservable from the traffic. Making it a wire-level MUST would require the protocol to define a UI contract — mandatory approval round trips with structured, machine-checkable descriptions and a signed user decision — which would couple the protocol to one interaction model and make headless and batch hosts non-conformant. The spec deliberately puts these as strong obligations on implementors instead.

**7.4**
- TLS termination → **out of scope** (transport/deployment concern; the spec assumes but does not define it).
- Tool result schemas → **in scope** (content types, `structuredContent`, `outputSchema`, resource links).
- Rate limiting per user → **out of scope** (an implementation and deployment concern).
- Capability negotiation → **in scope** (core base protocol, part of the lifecycle).
- Audit logging of tool calls → **out of scope** as a requirement, though the `logging` capability and the host's own records support it; MCP does not define an audit format.
- Cancellation of an in-flight request → **in scope** (`notifications/cancelled` is a base protocol utility, alongside ping and progress).

---

### Exercise 8

**8.1** Date strings give you an unambiguous total order and nothing else — no encoded promise about compatibility, because a revision may contain breaking changes (JSON-RPC batching, for instance, was added in one revision and removed in a later one). The consequence: a client cannot infer "`2025-06-18` ⊃ `2025-03-26`" the way it could from a semver minor bump. It must negotiate per connection, key its feature usage off the **negotiated version plus the declared capabilities** rather than off the version alone, and hold a compatibility matrix for the revisions it claims to support. Capability negotiation, not version arithmetic, is the reliable mechanism.

**8.2** The **host application** (IDE, chat client) corresponds to the **editor**; the **MCP server** corresponds to the **language server**; the **MCP client** inside the host corresponds to the editor's LSP client, one per server. The direct analogue of "M editors × N languages" is "M AI applications × N context sources": before LSP, each editor implemented completion and go-to-definition for each language separately; LSP made it M+N, and MCP applies the identical move to model context and tooling.

**8.3** *Strongest version:* both are machine-readable descriptions of callable capabilities with typed inputs, usable for discovery and codegen; if you already publish an OpenAPI spec, a large part of an MCP server can be generated from it, and maintaining two descriptions of the same surface is duplication. *Correction:* OpenAPI describes an **HTTP API for developers to program against** — exhaustive, stable, resource-oriented, with the granularity that a programmer wants. MCP describes a **capability surface for a model to use at run time** — a curated, deliberately small set of coherent operations, plus resources, prompts, sampling and an interactive session. They operate at different layers: an MCP server is frequently a *client* of an OpenAPI-described service, and the useful work in writing it is precisely the curation and the descriptions, which a mechanical translation of 200 endpoints does not do. Dumping an OpenAPI spec into tools floods the context window and degrades tool selection.

**8.4** **MCP** standardises how an AI application obtains context and invokes capabilities from external systems — the vertical link between a model-driven host and tools, data and prompts. An **agent-to-agent protocol** standardises how independent, opaque agents discover each other, delegate tasks and exchange results — the horizontal link between peers, where neither side exposes its internal tools. They compose: an agent uses MCP downward to reach its own tools and an A2A-style protocol sideways to delegate to other agents.

</details>

---

## Sources

- Model Context Protocol — specification: <https://modelcontextprotocol.io/specification/>
- MCP architecture overview: <https://modelcontextprotocol.io/docs/learn/architecture>
- Protocol versioning and revision history: <https://modelcontextprotocol.io/specification/versioning>
- Security best practices: <https://modelcontextprotocol.io/specification/draft/basic/security_best_practices>
- Reference servers and SDKs: <https://github.com/modelcontextprotocol>
- MCP Inspector: <https://github.com/modelcontextprotocol/inspector>
- JSON-RPC 2.0 specification: <https://www.jsonrpc.org/specification>
- Language Server Protocol (the structural precedent): <https://microsoft.github.io/language-server-protocol/>
- Linux Foundation — MCPA certification: <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>