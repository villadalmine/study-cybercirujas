# Topic 5.1 — Roles, Responsibilities & Adoption
## Guided exercises (MCPA, exam version 2026-07-28)

**Exam weight:** 6.67 %

This topic is the one candidates under-prepare, because it looks like "soft" material. It is not. Every question in this domain reduces to a hard, checkable statement about **which participant in an MCP deployment is obligated to do a thing** — and the specification is explicit about most of those obligations. The exercises below make you *derive* the boundary from the wire protocol and the spec, not memorise an org chart.

**Learning outcomes**

By the end you can:

1. Separate the three **protocol roles** (host, client, server) from the **organisational roles** (server owner, host/app owner, platform, security, data governance) and explain why they do not map 1:1.
2. Read an `initialize` handshake and state which side owes which capability.
3. Assign each of the spec's Trust & Safety principles to the participant that can actually enforce it.
4. Locate the authorization boundary: who is the OAuth 2.1 **Resource Server**, who is the client, and who owns the IdP.
5. Design an adoption path from a single pilot server to a paved road with a registry, ownership metadata, a contract gate in CI, and an on-call rotation.

**Prerequisites:** Node.js ≥ 20 (for `npx`), `curl`, `jq`, `git`, a text editor. No cloud account required. Roughly 90–120 minutes.

---

## Exercise 0 — Build the lab

### Steps

1. Create a scratch workspace and confirm your tooling:

```bash
mkdir -p ~/mcpa-5.1/{contracts,policy,runbooks} && cd ~/mcpa-5.1
node --version
npx --version
jq --version
```

2. Pull the two reference servers you will inspect. The first exercises every primitive; the second is a realistic least-privilege example:

```bash
npx -y @modelcontextprotocol/server-everything --help
npx -y @modelcontextprotocol/server-filesystem ~/mcpa-5.1 &
```

3. Stop the backgrounded filesystem server for now — you will drive it through the Inspector instead:

```bash
kill %1
```

4. Launch the MCP Inspector against the everything server. The Inspector is the reference **host + client** implementation; you are standing in for the human operator:

```bash
npx -y @modelcontextprotocol/inspector npx -y @modelcontextprotocol/server-everything
```

Open the URL it prints (it includes a session token), then click **Connect**.

**Checkpoint questions**

- **Q1.** In the command you just ran, exactly one process is the MCP *server*. Which one, and what makes it the server — the fact that it was spawned, or something about the message flow?
- **Q2.** The Inspector spawned the server as a child process over stdio. Name one organisational consequence of that transport choice for who is accountable when the server misbehaves.

---

## Exercise 1 — Derive the protocol roles from the wire

The spec defines three participants: a **host** (the AI application), an **MCP client** (a connector inside the host, one per server, maintaining a 1:1 session), and an **MCP server** (the program exposing context and capabilities). Ownership arguments in real organisations collapse when people conflate "host" with "client".

### Steps

1. In the Inspector, open the **History** pane at the bottom and find the first message of the session. It is the client's `initialize` request. It looks like this:

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
      "name": "acme-ide",
      "title": "Acme IDE",
      "version": "4.2.0"
    }
  }
}
```

2. Now read the server's `initialize` result in the History pane. Elided, it has this shape:

```
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools":     { "listChanged": true },
      "resources": { "subscribe": true, "listChanged": true },
      "prompts":   { "listChanged": true },
      "logging":   {},
      "completions": {}
    },
    "serverInfo": { "name": "example-servers/everything", "version": "..." },
    "instructions": "..."
  }
}
```

3. Reproduce the same handshake headlessly, so you can script it later:

```bash
npx -y @modelcontextprotocol/inspector --cli \
  npx -y @modelcontextprotocol/server-everything \
  --method tools/list | jq '.tools | length'
```

4. Write down, as a two-column list in `policy/roles-wire.md`, which capabilities were declared by the client and which by the server.

**Checkpoint questions**

- **Q3.** `sampling` and `elicitation` appear in the *client's* capability object, not the server's. What does each one mean, and why does putting them on the client side determine who owns the user-facing approval flow?
- **Q4.** A vendor tells you "our product is an MCP client, so we don't need a consent UI." Using the host/client distinction, explain what is wrong with the sentence and who actually owes the consent UI.
- **Q5.** `protocolVersion` is negotiated, not configured. If the client offers `2025-06-18` and the server only supports an earlier revision, what is the server expected to do, and which team's backlog does the resulting incompatibility land on?

---

## Exercise 2 — The control boundary: who *decides* a primitive fires

The three server primitives differ by **who is in control**, and that single axis drives most responsibility assignments in this domain.

| Primitive | Controlled by | Typical organisational owner of the decision |
|---|---|---|
| **Tools** | the model | server owner defines them; host owner gates execution |
| **Resources** | the application (host) | host owner selects; data governance classifies |
| **Prompts** | the user | user invokes; server owner curates |

### Steps

1. List the three primitive families of the everything server:

```bash
for m in tools/list resources/list prompts/list; do
  echo "== $m"
  npx -y @modelcontextprotocol/inspector --cli \
    npx -y @modelcontextprotocol/server-everything --method "$m" \
    | jq -r '(.tools // .resources // .prompts)[].name' | head -5
done
```

2. Call a tool directly and observe that nothing asked you for permission — because the Inspector's CLI mode is not a consent-bearing host:

```bash
npx -y @modelcontextprotocol/inspector --cli \
  npx -y @modelcontextprotocol/server-everything \
  --method tools/call --tool-name echo --tool-arg message=hello
```

3. Now inspect a tool's declared safety metadata. Tool definitions may carry annotations that are **hints for the host**, not enforcement:

```bash
npx -y @modelcontextprotocol/inspector --cli \
  npx -y @modelcontextprotocol/server-everything --method tools/list \
  | jq '.tools[] | {name, annotations}' | head -30
```

4. Record in `policy/control-boundary.md` one concrete failure mode for each primitive if its owner is unassigned (e.g. tools with no owner → an unreviewed destructive verb reaches production).

**Checkpoint questions**

- **Q6.** `readOnlyHint`, `destructiveHint`, `idempotentHint` and `openWorldHint` are supplied by the server. Why must a host treat them as **untrusted hints**, and what is the responsibility split that follows?
- **Q7.** Your data governance team asks to "approve every file the model reads". Which primitive do they actually need to govern, and which team implements the control — the server team or the host team?
- **Q8.** A product manager wants a "one-click summarise" button. Should that ship as a tool, a resource, or a prompt? Justify by control ownership, not by convenience.

---

## Exercise 3 — Map the Trust & Safety principles to an enforcing owner

The specification states security and trust principles that implementers **SHOULD** build for: user consent and control, data privacy, tool safety, and LLM sampling controls. The exam tests whether you know that the protocol itself does *not* enforce them — the host does.

### Steps

1. Create `policy/trust-safety-owners.yaml` and fill in the `owner` and `enforced_at` fields yourself before reading the answers:

```yaml
# policy/trust-safety-owners.yaml
apiVersion: internal.example.com/v1
kind: ResponsibilityMatrix
metadata:
  name: mcp-trust-and-safety
  spec_revision: "2025-06-18"
principles:
  - id: user-consent-and-control
    statement: "Users must explicitly consent to and understand all data access and operations."
    owner: ""
    enforced_at: ""
    evidence: "Screenshot of the approval dialog plus the audit log entry it writes."
  - id: data-privacy
    statement: "Hosts must not transmit user data elsewhere without explicit consent."
    owner: ""
    enforced_at: ""
    evidence: "Egress review of the host build; DPIA record."
  - id: tool-safety
    statement: "Tools represent arbitrary code execution and must be treated with caution."
    owner: ""
    enforced_at: ""
    evidence: "Tool review record; annotations are hints, not guarantees."
  - id: llm-sampling-controls
    statement: "Users must explicitly approve any LLM sampling request and control what is sent."
    owner: ""
    enforced_at: ""
    evidence: "Sampling approval prompt showing the exact messages to be sent."
```

2. Trigger a sampling request so you can see the control point with your own eyes. In the Inspector UI (not the CLI), open **Tools**, run the `sampleLLM` tool, and watch the **Sampling** tab light up with a pending request that you must approve or reject.

3. Reject it. Confirm in the History pane that the server received an error result, not a silent hang.

4. Fill in the YAML. For each principle, `enforced_at` must be one of `host`, `client`, `server`, `gateway`, or `idp`.

**Checkpoint questions**

- **Q9.** Why can a *server* never be the enforcement point for "LLM sampling controls", even a well-written one?
- **Q10.** The spec says a server "SHOULD NOT" be trusted to describe its own tools honestly. Name two organisational controls that compensate, and say which team runs each.
- **Q11.** Your host application auto-approves tools whose `readOnlyHint` is `true`. Write the attack in one sentence and name the accountable role.

---

## Exercise 4 — Locate the authorization boundary

Since revision **2025-06-18**, an HTTP-transport MCP server is an **OAuth 2.1 Resource Server**. This single sentence settles a large number of ownership disputes: the MCP server team does *not* run an authorization server, and the client team does *not* get to invent token handling.

### Steps

1. Probe any remote MCP server you are authorised to test. An unauthenticated request must return `401` with a `WWW-Authenticate` header pointing at the protected resource metadata (RFC 9728):

```bash
curl -si -X POST https://mcp.example.com/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | head -20
```

Expected shape of the response head:

```
HTTP/2 401
www-authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"
content-type: application/json
```

2. Fetch the metadata document the header advertises:

```bash
curl -s https://mcp.example.com/.well-known/oauth-protected-resource | jq .
```

```
{
  "resource": "https://mcp.example.com/mcp",
  "authorization_servers": [
    "https://login.example.com"
  ],
  "scopes_supported": [
    "mcp:tools:read",
    "mcp:tools:write"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

3. Draw the boundary in `policy/authz-boundary.md`. Three artefacts, three owners:

```yaml
# policy/authz-boundary.md (embedded fragment)
boundary:
  - artifact: "Authorization Server / IdP"
    examples: "Entra ID, Okta, Keycloak"
    owner: identity-team
    mcp_role: "issues tokens; never sees MCP traffic"
  - artifact: "MCP server"
    owner: server-owner
    mcp_role: "OAuth 2.1 Resource Server: validates signature, expiry and audience"
  - artifact: "MCP client inside the host"
    owner: host-owner
    mcp_role: "performs the auth code + PKCE flow and sends RFC 8707 resource indicators"
```

4. Add the negative rule — the one the exam likes — to the same file:

```yaml
prohibitions:
  - id: token-passthrough
    rule: "An MCP server MUST NOT accept a token that was not issued for it, and MUST NOT forward the client's token to an upstream API."
    rationale: "Audience confusion: the upstream API cannot distinguish a legitimate caller from a relay."
    owner: server-owner
  - id: confused-deputy
    rule: "A server proxying a third-party IdP MUST obtain user consent per dynamically registered client before forwarding an authorization request."
    rationale: "A static upstream client_id plus a pre-existing consent cookie lets a crafted redirect_uri harvest an auth code."
    owner: server-owner
```

**Checkpoint questions**

- **Q12.** A team proposes "the MCP server will accept the user's Google access token and call the Google Drive API with it." Which prohibition does that violate, and what should they do instead?
- **Q13.** Who owns the `resource` indicator being correct — the client team, the server team, or the identity team? What breaks if it is omitted?
- **Q14.** Your platform puts an API gateway in front of twelve MCP servers and terminates OAuth there. List one responsibility that transfers to the gateway team and one that emphatically does **not**.
- **Q15.** For a stdio-transport server running as a local subprocess, who is the authorization boundary? (Careful — this is a trick with a real answer.)

---

## Exercise 5 — From pilot to paved road: catalogue and namespace ownership

Adoption fails at the same place in every organisation: server number seven. Up to six, people know who wrote each one. At seven you need a registry, a namespace scheme, and mandatory ownership metadata.

### Steps

1. Look at how the official registry models identity. Namespaces are reverse-DNS and **proved**, not claimed — via GitHub OAuth for `io.github.*` or a DNS TXT record for a company domain:

```bash
curl -s "https://registry.modelcontextprotocol.io/v0/servers?limit=3" | jq '.servers[].name'
```

2. Author an internal `server.json` for a pilot server. Copy the current `$schema` URL from the registry documentation; the value below is representative:

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-07-09/server.schema.json",
  "name": "com.acme/incident-timeline",
  "description": "Read-only access to incident timelines and postmortem records.",
  "version": "0.3.1",
  "repository": {
    "url": "https://github.com/acme/mcp-incident-timeline",
    "source": "github"
  },
  "remotes": [
    {
      "type": "streamable-http",
      "url": "https://mcp.acme.internal/incident-timeline/mcp"
    }
  ]
}
```

3. The registry schema does not model your org chart, so add a sidecar that your platform enforces. This is the file your CI gate will require:

```yaml
# contracts/ownership.yaml
server: "com.acme/incident-timeline"
owner:
  team: sre-tooling
  slack: "#sre-tooling"
  pagerduty_service: "PDSVC-4417"
classification:
  data: internal
  pii: false
  writes: false
review:
  security_review: "2026-08-19"
  next_due: "2027-02-19"
adoption_tier: paved-road
```

4. Score your pilot against a four-tier adoption rubric. Write it once and reuse it for every server:

```yaml
# policy/adoption-tiers.yaml
tiers:
  - id: experiment
    gate: "Runs on a developer laptop over stdio. No production data."
    requires: ["named owner"]
  - id: pilot
    gate: "One team, read-only, non-production data, manual approval for every tool call."
    requires: ["named owner", "ownership.yaml", "tool inventory"]
  - id: paved-road
    gate: "Listed in the internal registry, OAuth-protected, SLO and on-call defined."
    requires:
      - "named owner"
      - "ownership.yaml"
      - "security review within 6 months"
      - "contract test in CI"
      - "runbook"
  - id: tier-0
    gate: "Write access to systems of record; two-person tool review; change freeze policy applies."
    requires:
      - "everything in paved-road"
      - "destructive tools individually approved"
      - "quarterly access recertification"
```

**Checkpoint questions**

- **Q16.** Why does the official registry verify namespace ownership instead of accepting a self-declared name? Translate that reasoning into a rule for an internal registry.
- **Q17.** Your `ownership.yaml` lists a team, a Slack channel and a PagerDuty service. Which of those three is the one that makes the ownership *real*, and why are the other two insufficient on their own?
- **Q18.** A server sits at `pilot` but is already read by three teams' agents. Name the specific responsibility that is currently unassigned and the failure it produces.

---

## Exercise 6 — Change management: a tool schema is a public API

The single most common adoption injury is a server owner renaming a tool parameter on a Tuesday. Models bound to the old schema fail silently, and the blast radius is every host connected to that server.

### Steps

1. Freeze the current contract of a server as a baseline artefact:

```bash
npx -y @modelcontextprotocol/inspector --cli \
  npx -y @modelcontextprotocol/server-filesystem ~/mcpa-5.1 \
  --method tools/list | jq -S '.' > contracts/tools-main.json
wc -c contracts/tools-main.json
```

2. Write the gate that makes the contract binding. Note that the diff runs on every PR that touches the tool surface, and that the job is owned by the server team but the *policy* is owned by the platform team:

```yaml
name: mcp-server-contract
on:
  pull_request:
    paths:
      - "src/tools/**"
      - "server.json"
      - "contracts/**"
jobs:
  contract:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: "Export the tool schema from the PR build"
        run: |
          npm ci
          npm run build
          npx -y @modelcontextprotocol/inspector --cli node dist/index.js \
            --method tools/list | jq -S '.' > /tmp/tools-head.json
      - name: "Fail on a breaking change without a version bump"
        run: |
          .ci/diff-tool-contract.py \
            --base contracts/tools-main.json \
            --head /tmp/tools-head.json \
            --server-json server.json
      - name: "Require an owner record"
        run: |
          test -f contracts/ownership.yaml
          grep -q "pagerduty_service" contracts/ownership.yaml
```

3. Define what "breaking" means, so the gate is not a matter of opinion:

```yaml
# policy/contract-rules.yaml
breaking:
  - "Removing a tool."
  - "Renaming a tool or an input property."
  - "Adding a required input property."
  - "Narrowing an input type or enum."
  - "Changing a tool from read-only to destructive behaviour."
non_breaking:
  - "Adding an optional input property."
  - "Adding a new tool."
  - "Widening an enum."
  - "Improving a description without changing semantics."
deprecation:
  notice_period_days: 90
  mechanism: "Mark in the description, emit a logging notification on call, keep behaviour intact, then remove in the next major version."
  notification: "notifications/tools/list_changed after the removal ships."
```

4. Simulate a breaking change: edit your local baseline to rename one parameter, re-run the diff mentally, and record who must be notified and through which channel.

**Checkpoint questions**

- **Q19.** The protocol has `notifications/tools/list_changed`. Why is that notification **not** a substitute for a deprecation policy?
- **Q20.** Semantic versioning in `server.json` describes the *server package*. What is versioned that the package version does not capture, and who owns communicating it?
- **Q21.** Who signs off a change that flips a tool's `destructiveHint` from `false` to `true` — server owner, host owner, security, or all three? Justify with the control boundary from Exercise 2.

---

## Exercise 7 — Operate it: SLOs, paging, and incident roles

### Steps

1. Define the two golden signals that matter for an MCP server and encode a burn alert. Keep every line of the block scalar at the same indentation:

```yaml
groups:
  - name: mcp-server-slo
    rules:
      - alert: MCPToolCallErrorRatioHigh
        expr: |
          sum(rate(mcp_tool_calls_total{outcome="error"}[5m]))
          /
          sum(rate(mcp_tool_calls_total[5m]))
          > 0.05
        for: 10m
        labels:
          severity: page
          owner: server-owner
        annotations:
          summary: "tools/call error ratio above 5% for 10 minutes"
          runbook_url: "https://runbooks.acme.internal/mcp/tool-call-errors"
      - alert: MCPInitializeLatencyP99
        expr: |
          histogram_quantile(
            0.99,
            sum by (le) (rate(mcp_initialize_duration_seconds_bucket[5m]))
          )
          > 2
        for: 15m
        labels:
          severity: ticket
          owner: platform
        annotations:
          summary: "p99 initialize latency above 2s — sessions are slow to establish"
          runbook_url: "https://runbooks.acme.internal/mcp/slow-initialize"
```

2. Write the routing table that turns an alert into a human. This is the artefact the exam is really about:

```yaml
# runbooks/paging.yaml
routes:
  - symptom: "tools/call returns 500 from one server"
    page: server-owner
    reason: "Business logic and upstream dependency belong to the server team."
  - symptom: "All servers 401 after an IdP change"
    page: identity-team
    reason: "Token issuance, not resource validation."
  - symptom: "Host shows no servers; gateway healthy; servers healthy"
    page: host-owner
    reason: "Client-side session or capability negotiation failure."
  - symptom: "A tool deleted production data after a model called it"
    page: incident-commander
    reason: "Consent and gating failure spans host and server; escalate, do not route."
  - symptom: "A server logged the contents of a Bearer token"
    page: security
    reason: "Credential exposure — rotation is owned by identity, containment by security."
```

3. Reproduce one of these signals locally. Kill the server mid-session and watch what the client reports:

```bash
npx -y @modelcontextprotocol/inspector npx -y @modelcontextprotocol/server-everything
# connect in the UI, then in another terminal:
pkill -f server-everything
```

4. Note in `runbooks/notes.md` whether the *host* surfaced a usable error to you, the human. That observation is the host owner's SLO, not the server's.

**Checkpoint questions**

- **Q22.** A student argues that MCP server availability should be the platform team's SLO because the platform runs the containers. Give the counter-argument in terms of error budget ownership.
- **Q23.** During the "tool deleted production data" incident, three roles are in the room. Name them and state the one decision each owns in the first fifteen minutes.
- **Q24.** Which of the two alerts above should *never* page the server owner, and why does its `owner` label matter more than its `severity` label?

---

## Exercise 8 — Capstone: the adoption charter

### Steps

1. Create `policy/adoption-charter.md` with exactly five sections: **Scope**, **Roles**, **Gates**, **Prohibitions**, **Review cadence**. No section may exceed 150 words.

2. Populate **Roles** with this matrix and resolve every `?` yourself:

```yaml
# policy/raci.yaml
activities:
  - id: define-tool-surface
    responsible: server-owner
    accountable: server-owner
    consulted: ["security", "data-governance"]
    informed: ["host-owner"]
  - id: approve-tool-execution-at-runtime
    responsible: "?"
    accountable: "?"
    consulted: []
    informed: ["security"]
  - id: classify-resources-exposed
    responsible: "?"
    accountable: data-governance
    consulted: ["server-owner"]
    informed: ["security"]
  - id: run-the-transport-and-gateway
    responsible: platform
    accountable: platform
    consulted: ["security"]
    informed: ["server-owner", "host-owner"]
  - id: issue-and-rotate-credentials
    responsible: "?"
    accountable: "?"
    consulted: ["security"]
    informed: ["platform"]
  - id: accept-a-server-into-the-registry
    responsible: platform
    accountable: "?"
    consulted: ["security", "data-governance"]
    informed: ["all-teams"]
  - id: retire-a-server
    responsible: server-owner
    accountable: platform
    consulted: ["host-owner"]
    informed: ["all-teams"]
```

3. Validate the file parses and that no activity has more than one accountable party:

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('policy/raci.yaml')); \
[print(a['id'], '->', a['accountable']) for a in d['activities']]"
```

4. Finally, locate the *upstream* roles. Adoption does not stop at your org boundary: the specification itself has maintainers and a proposal process, and your organisation's ability to influence it is an adoption decision.

```bash
# Read, do not guess:
#   https://modelcontextprotocol.io/community/governance
#   https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/CONTRIBUTING.md
```

**Checkpoint questions**

- **Q25.** Identify the two `"?"` entries in `raci.yaml` where the responsible and accountable parties are *different* organisational teams, and explain why splitting them there is correct rather than sloppy.
- **Q26.** Your charter's **Prohibitions** section can hold only three lines. Which three prohibitions from this entire topic earn the slots?
- **Q27.** Name the mechanism by which an external contributor proposes a normative change to the MCP specification, and state one reason an enterprise adopter would care about who maintains the spec.

---

<details>
<summary><strong>Answers — expand only after attempting every checkpoint</strong></summary>

**Q1.** `npx -y @modelcontextprotocol/server-everything` is the server. What makes it the server is not that it was spawned — a server can be a remote HTTP endpoint that nobody spawned — but its position in the message flow: it *responds* to `initialize`, declares server capabilities (`tools`, `resources`, `prompts`), and exposes context. The Inspector is the host, and the connector object inside it that holds the 1:1 session is the client.

**Q2.** With stdio the server inherits the user's local identity, environment variables and filesystem access, and it runs on the user's machine. Consequences you could name: there is no network authorization boundary to audit, so accountability for what the server can reach falls on whoever provisioned the *host* and its configuration — endpoint/EDR and desktop engineering become stakeholders, not the platform team. Equally valid: versioning is uncontrolled, because `npx -y` fetches the latest package at launch, so "which version ran during the incident" has no owner unless someone pins it.

**Q3.** `sampling` means the client will let a server request an LLM completion through the host's model — the server borrows the host's inference. `elicitation` means the client will let a server request additional information from the *user* mid-operation. Both are declared client-side because both are re-entrant calls *back into* the host's trust domain: only the host has a user to ask, a model to spend, and a screen on which to show what is about to be sent. Whoever owns the host application therefore owns the approval flow, its wording, its default (which must not be auto-approve), and its audit trail.

**Q4.** The sentence conflates two roles. The MCP client is a protocol-level connector — it manages one session, negotiates capabilities, and routes JSON-RPC. The **host** is the application that embeds one or more clients, holds the model, holds the user relationship, and enforces consent. There is no such thing as a shipping product that is "only a client"; if it has users, it is a host, and the host owes the consent UI. The spec places user consent and control, data privacy and sampling approval on the host precisely because the client has no user to ask.

**Q5.** The server responds with the protocol version it *does* support; if the client cannot work with that version it must disconnect. The negotiation is a two-message affair, not a configuration flag. The incompatibility lands on whichever side is behind: in practice the server owner's backlog, because one server is shared by many hosts and upgrading it fixes N clients, whereas upgrading hosts fixes one each. Over HTTP transport, subsequent requests carry the negotiated version in the `MCP-Protocol-Version` header; if the header is absent, the server should assume `2025-03-26` for backward compatibility — which is itself an argument for the server team owning a deprecation calendar.

**Q6.** The annotations are strings and booleans supplied by the server in its own tool description. A compromised, buggy or simply optimistic server can claim `readOnlyHint: true` on a tool that deletes rows; nothing in the protocol verifies the claim. The split that follows: the **server owner** is accountable for the annotations being *truthful* (and for that being checked in review), while the **host owner** is accountable for not treating them as an authorization decision. A host may use hints to order or style a prompt; it may not use them to skip one for anything it has not independently verified.

**Q7.** They need to govern **resources**, which are application-controlled: the host decides which resources enter context, so a resource-selection policy is enforceable. The *implementation* is the host team's — the server can only offer resources, it cannot decide which get read. Data governance supplies the classification (the `classification` block in `ownership.yaml`); the host team supplies the filter. If they instead ask the server team to "not expose sensitive files", they have written a policy with no enforcement point.

**Q8.** A **prompt**. Prompts are user-controlled primitives, surfaced as explicit, user-invoked entry points — slash commands, menu items, buttons. A tool would let the model decide to summarise unprompted; a resource would only supply the text. The control axis, not the implementation effort, is what decides.

**Q9.** Because the sampling request *originates* from the server. The party making the request cannot be the party approving it — that is the definition of a missing control. Only the host possesses the two things approval requires: the user, and the conversation content that is about to be transmitted. A server can be well written and still be the wrong enforcement point; the spec's phrasing is that users must explicitly approve any LLM sampling request and control what is sent.

**Q10.** Two compensating controls, with owners: (a) **tool review before registry admission** — a human reads the tool definitions, verifies that behaviour matches the description and annotations, and signs the `security_review` date in `ownership.yaml`; owned by security with the server owner as author. (b) **runtime gating in the host** — approval prompts for anything not on an explicit allowlist, plus logging of every `tools/call` with its arguments; owned by the host team. A third acceptable answer: pinned server versions plus a contract diff in CI, owned by the platform team, so that a reviewed tool surface cannot change without re-review.

**Q11.** A malicious or compromised server declares `readOnlyHint: true` on a tool that exfiltrates data or writes to an upstream system, and the host executes it with no human in the loop. The accountable role is the **host owner**: the server told a lie, but the host made an authorization decision from an untrusted input, which is the defect. (The server owner is accountable for the lie if the server is internal; the design flaw remains the host's.)

**Q12.** It violates the **token passthrough** prohibition: an MCP server must not accept tokens that were not issued for it, and must not relay the caller's token to an upstream API. The audience claim would name Google, not the MCP server, so the server cannot validate it meaningfully and the upstream cannot attribute the call. Instead, the MCP server validates a token whose audience is the MCP server itself, and then obtains its own credential for Drive — a separate delegated grant held by the server, or a token exchange performed against the IdP — so that two distinct, separately revocable identities appear in the two hops.

**Q13.** The **client team** (i.e. the host) is responsible for sending the RFC 8707 `resource` parameter in authorization and token requests; the **identity team** is responsible for the IdP honouring it and minting an audience-restricted token; the **server team** is responsible for rejecting any token whose audience is not itself. If it is omitted, the IdP may issue a broadly scoped token accepted by several resource servers, and a malicious or compromised MCP server can replay it against a different one. Note that the failure is only *detected* at the server, which is why audience validation is a hard server-side requirement even though the omission happened at the client.

**Q14.** Transfers to the gateway team: terminating TLS, validating the token signature and expiry, rate limiting, and emitting the access log — i.e. the coarse perimeter. Does **not** transfer: **audience validation tied to the specific server**, and per-tool authorization. A gateway that accepts any token valid for "the MCP estate" and forwards it to twelve servers has recreated the confused deputy internally. Each server must still confirm the token was minted for *it*, or the gateway must mint a fresh, per-server internal credential.

**Q15.** For a local stdio subprocess, the OAuth authorization framework in the spec does not apply — the spec says stdio servers should take credentials from the environment instead. The boundary becomes the **operating system's user account**: the server runs with the user's privileges and can reach anything the user can. The responsibility therefore sits with whoever controls the host's configuration and the machine's posture (desktop/endpoint engineering plus the host owner), and the practical controls are file-system roots, environment scoping and pinned versions — not scopes and tokens.

**Q16.** Self-declared names let anyone publish `com.stripe/payments` and impersonate a trusted publisher; verification (GitHub OAuth for `io.github.*`, a DNS TXT record for a custom domain) binds the namespace to an identity that can be held accountable. The internal rule that follows: **an internal registry entry must be bound to an authenticated team identity, not to a string typed in a PR** — derive the namespace from the owning group in your identity provider or from the repository's CODEOWNERS, and reject entries whose claimed owner does not match.

**Q17.** The **PagerDuty service** is what makes ownership real, because it is the only one of the three that produces an obligation at 03:00 with a named human attached and an escalation policy behind it. A team name is an abstraction that survives reorgs by becoming stale; a Slack channel is a place where a message can go unanswered. Ownership is only meaningful where it has a response-time commitment.

**Q18.** **Consumer notification on change** is unassigned — nobody owes the three consuming teams a deprecation notice, because at `pilot` tier there is no registry entry recording who depends on the server. The failure it produces: the server owner makes a schema change they correctly believe is safe for their own team, and two other teams' agents begin failing with no attribution, usually presenting as "the model got dumber" rather than as an error.

**Q19.** `notifications/tools/list_changed` tells a connected client that the list changed *after the fact*, and only for sessions that are currently open. It is a cache-invalidation signal, not a communication channel: it reaches no human, gives no notice period, carries no rationale or migration path, and does nothing for a host that connects an hour later with hard-coded expectations or with prompts and evaluations built around the old tool names. A deprecation policy provides advance notice, a stable overlap window and a named contact; the notification just keeps caches honest.

**Q20.** The **tool contract** — the set of tool names, input schemas, required fields and behavioural semantics — is versioned independently of the package. A patch-level package bump can carry a breaking tool-schema change, and a major package bump can leave the contract untouched. Communicating it is the **server owner's** responsibility, and the mechanism is the frozen contract artefact plus the CI diff from Exercise 6; the platform team owns making that gate mandatory.

**Q21.** **All three**, and they are signing different things. The server owner attests that the new annotation is truthful and that the behaviour change is intended. Security reviews whether a destructive verb is acceptable on this data classification at all. The host owner must act, because the host's gating logic keys off the hint: a tool that was silently auto-approved yesterday must now route through an approval path, and possibly through a different one for tier-0 systems. This is exactly the control boundary from Exercise 2 — the server *describes*, the host *decides*, and security sets the policy both obey.

**Q22.** Error budget ownership must sit with whoever can spend it. The platform team can keep the container running; it cannot fix a tool that returns 500 because the upstream incident API changed its response shape, and it cannot decide whether shipping a risky tool change is worth burning budget. Splitting it is the correct resolution: the platform owns an *infrastructure* SLO (scheduling, ingress, transport availability), the server owner owns the *service* SLO (`tools/call` success ratio and latency). One alert, `MCPInitializeLatencyP99` in the example, is genuinely a platform signal; `MCPToolCallErrorRatioHigh` is not.

**Q23.** (a) **Incident commander** — owns the decision to declare and to escalate, and owns nothing technical. (b) **Host owner** — owns the containment decision that matters first: disconnect the server from the host fleet / revoke its registry entry, so no further tool calls can be issued. (c) **Server owner** — owns the technical assessment of blast radius: which tool, which arguments, which rows, and whether the operation is reversible. Security and data governance join immediately after, for credential rotation and for the disclosure assessment, but the first fifteen minutes belong to those three decisions.

**Q24.** `MCPInitializeLatencyP99` should never page the server owner: slow session establishment across the estate is a transport, gateway or IdP symptom, and paging the owner of one server produces an investigation they cannot conclude. The `owner` label matters more than `severity` because severity only decides *how loudly* someone is woken; `owner` decides *whether the woken person can act*. A correctly severe alert routed to the wrong role is worse than no alert, since it consumes the budget of trust that keeps people responding to pages at all.

**Q25.** The two are **`approve-tool-execution-at-runtime`** and **`accept-a-server-into-the-registry`**.
- For runtime approval, *responsible* is the **host owner** (they build and operate the gating), but *accountable* is properly **security**, which sets the policy defining what may be auto-approved and what may not. Splitting is correct because the team that implements a control should not be the team that sets its threshold.
- For registry admission, *responsible* is the **platform** team (they run the mechanics of the registry), but *accountable* should be **security** or an architecture review body, because admission is the moment a server becomes reachable by every host in the organisation. Splitting prevents the registry from degrading into a self-service form.
The remaining `"?"` entries: `classify-resources-exposed` is *responsible* = **data-governance** (same team as accountable, correctly so); `issue-and-rotate-credentials` is *responsible* and *accountable* = **identity-team**, and keeping both on one team is right because credential issuance has no legitimate second opinion.

**Q26.** The three that each prevent a class of incident no other control catches:
1. *No MCP server accepts a token whose audience is not itself, and no server forwards a caller's token upstream.* (Token passthrough / confused deputy.)
2. *No host auto-approves a tool call on the basis of server-supplied annotations alone.* (Untrusted hints as authorization.)
3. *No server reaches paved-road tier without a named PagerDuty service and a contract test in CI.* (Unowned and silently drifting servers.)

**Q27.** Normative changes go through the **SEP** process — a Specification Enhancement Proposal raised in the `modelcontextprotocol/modelcontextprotocol` repository, sponsored by a maintainer, discussed in the relevant working group, and merged into a dated specification revision (`2024-11-05`, `2025-03-26`, `2025-06-18`, and subsequent revisions — check the changelog for the current one rather than trusting any list from memory). An enterprise adopter cares about the maintainership because it determines whether the protocol can be changed unilaterally by a single vendor: MCP's move to open, foundation-hosted governance under the Linux Foundation is precisely the fact that makes "we standardised on MCP" a defensible architectural decision rather than a bet on one company's roadmap. Verify the current governance structure and working-group list at the governance page before quoting it in a design document — this is the fastest-moving fact in the whole topic.

</details>

---

## Sources

- Linux Foundation — *Model Context Protocol Associate (MCPA)* certification page: <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>
- MCP specification, architecture and participants: <https://modelcontextprotocol.io/specification/2025-06-18/architecture>
- MCP specification — key principles, security and trust & safety: <https://modelcontextprotocol.io/specification/2025-06-18>
- MCP specification — lifecycle and version negotiation: <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
- MCP specification — authorization (OAuth 2.1 Resource Server, RFC 9728, RFC 8707): <https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization>
- MCP security best practices (confused deputy, token passthrough, session hijacking): <https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices>
- MCP specification — tools and tool annotations: <https://modelcontextprotocol.io/specification/2025-06-18/server/tools>
- MCP specification — sampling and elicitation: <https://modelcontextprotocol.io/specification/2025-06-18/client/sampling> and <https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation>
- MCP Registry documentation and `server.json` schema: <https://github.com/modelcontextprotocol/registry>
- MCP Inspector: <https://github.com/modelcontextprotocol/inspector>
- MCP community governance and contribution process: <https://modelcontextprotocol.io/community/governance>
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: <https://datatracker.ietf.org/doc/html/rfc9728>
- RFC 8707 — Resource Indicators for OAuth 2.0: <https://datatracker.ietf.org/doc/html/rfc8707>