# MCPA 2.1 — Schemas & Structured Data

## Guided Exercises

> **What this topic is really about.** MCP is JSON-RPC 2.0 plus a contract language. Almost every capability a server advertises is described by a JSON Schema document, and almost every interoperability bug in the wild is a schema that lies about what the server actually accepts or returns. These exercises make you write the contracts, break them, and watch exactly where the failure surfaces — client side, server side, or silently not at all.
>
> **Time:** ~2.5 h. **Prerequisites:** Python 3.12, a shell, no network access to any MCP host required — you drive the server yourself over stdio.

---

## Exercise 0 — Lab setup

### Steps

1. Create the workspace and a virtualenv:

```bash
mkdir -p ~/mcpa-2.1/schemas && cd ~/mcpa-2.1
python3 -m venv .venv
```

2. Install the MCP SDK and two independent JSON Schema validators. You want a validator that is *not* the one embedded in the SDK, so that "the SDK accepted it" and "it is a valid schema" stay distinguishable:

```bash
.venv/bin/pip install --quiet "mcp[cli]" jsonschema check-jsonschema uritemplate
.venv/bin/python -c "import jsonschema, mcp; print('jsonschema', jsonschema.__version__)"
```

Expected (versions will differ):

```
jsonschema 4.23.0
```

3. Confirm which JSON Schema dialect your validator defaults to:

```bash
.venv/bin/python -c "
from jsonschema import Draft202012Validator
print(Draft202012Validator.META_SCHEMA['\$id'])"
```

Expected:

```
https://json-schema.org/draft/2020-12/schema
```

**Q0.1** MCP specifies JSON Schema *draft 2020-12* for `inputSchema` and `outputSchema`. Why does it matter that you checked the dialect before writing a single schema, rather than after the first validation failure?

**Q0.2** A colleague says "JSON Schema is JSON Schema, the draft is a detail." Name one construct that is valid in draft-07 and *rejected outright* by the 2020-12 metaschema.

---

## Exercise 1 — Hand-write a tool descriptor and prove it is well-formed

A `tools/list` response is an array of `Tool` objects. The interesting part is that a `Tool` has two nested documents — `inputSchema` and `outputSchema` — which are themselves JSON Schemas, and nothing in the JSON-RPC layer checks that they are valid schemas. That check is yours.

### Steps

1. Write the descriptor:

```bash
cat > schemas/tool-disk-usage.json <<'JSON'
{
  "name": "disk_usage",
  "title": "Disk usage report",
  "description": "Report disk usage for a mount point on the host.",
  "inputSchema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Absolute path of the mount point to measure."
      },
      "unit": {
        "type": "string",
        "enum": ["bytes", "mib", "gib"],
        "default": "bytes",
        "description": "Unit used for the byte counters in the result."
      }
    },
    "required": ["path"],
    "additionalProperties": false
  },
  "outputSchema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
      "path": { "type": "string" },
      "used_bytes": { "type": "integer", "minimum": 0 },
      "total_bytes": { "type": "integer", "minimum": 0 },
      "percent_used": { "type": "number", "minimum": 0, "maximum": 100 }
    },
    "required": ["path", "used_bytes", "total_bytes", "percent_used"],
    "additionalProperties": false
  },
  "annotations": {
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
  }
}
JSON
```

2. Split the two nested schemas out and validate each one *against the 2020-12 metaschema*:

```bash
.venv/bin/python - <<'PY'
import json
tool = json.load(open("schemas/tool-disk-usage.json"))
for key in ("inputSchema", "outputSchema"):
    with open(f"schemas/{key}.json", "w") as handle:
        json.dump(tool[key], handle, indent=2)
PY
.venv/bin/check-jsonschema --check-metaschema schemas/inputSchema.json schemas/outputSchema.json
```

Expected:

```
ok -- schema validates
```

3. Now break it on purpose. Replace `"required": ["path"]` with `"required": "path"` and re-run step 2:

```bash
sed -i 's/"required": \["path"\]/"required": "path"/' schemas/tool-disk-usage.json
.venv/bin/python - <<'PY'
import json
tool = json.load(open("schemas/tool-disk-usage.json"))
json.dump(tool["inputSchema"], open("schemas/inputSchema.json", "w"), indent=2)
PY
.venv/bin/check-jsonschema --check-metaschema schemas/inputSchema.json
```

Expected (abridged):

```
Schema validation errors were encountered.
  schemas/inputSchema.json::$.required: 'path' is not of type 'array'
```

4. Restore the file:

```bash
sed -i 's/"required": "path"/"required": ["path"]/' schemas/tool-disk-usage.json
```

**Q1.1** MCP requires `inputSchema.type` to be `"object"`. Why can it not be `"string"` or `"array"`, even though JSON Schema would happily allow either?

**Q1.2** `annotations.readOnlyHint` is `true` here. Is a client allowed to *rely* on that to skip a confirmation prompt? What is the word "hint" doing in the field name?

**Q1.3** The broken schema in step 3 would have been served to every client without complaint by most servers. At which point in the request lifecycle would the damage actually show up, and who would report it?

**Q1.4** `additionalProperties: false` on the **input** schema and on the **output** schema have very different operational consequences. Describe each.

---

## Exercise 2 — Watch a real server generate schemas, and drive it by hand

### Steps

1. Write the server:

```bash
cat > server.py <<'PY'
"""Minimal MCP server used to observe schema generation and structured output."""

import shutil

from mcp.server.fastmcp import FastMCP
from pydantic import BaseModel, Field

mcp = FastMCP("schema-lab")


class DiskUsage(BaseModel):
    path: str = Field(description="Absolute path that was measured.")
    used_bytes: int = Field(ge=0)
    total_bytes: int = Field(ge=0)
    percent_used: float = Field(ge=0, le=100)


@mcp.tool()
def disk_usage(path: str, unit: str = "bytes") -> DiskUsage:
    """Report disk usage for a mount point on the host."""
    usage = shutil.disk_usage(path)
    return DiskUsage(
        path=path,
        used_bytes=usage.used,
        total_bytes=usage.total,
        percent_used=round(100 * usage.used / usage.total, 2),
    )


@mcp.tool()
def host_label(path: str) -> str:
    """Return a human-readable label for a mount point."""
    return f"mount {path}"


@mcp.tool()
def broken_usage(path: str) -> DiskUsage:
    """Deliberately return a payload that violates this tool's own output schema."""
    # total_bytes is missing, used_bytes is negative, percent_used is out of range.
    return {"path": path, "used_bytes": -1, "percent_used": 1200.0}  # type: ignore[return-value]


if __name__ == "__main__":
    mcp.run()
PY
```

2. Write a driver that speaks raw JSON-RPC over the server's stdin/stdout. Do not use a client library here — the point is to see the frames:

```bash
cat > drive.py <<'PY'
"""Drive an MCP stdio server by hand and print the raw JSON-RPC frames."""

import json
import subprocess
import sys

REQUESTS = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "by-hand", "version": "0.1"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]

proc = subprocess.Popen(
    [sys.executable, "server.py"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
    bufsize=1,
)

for request in REQUESTS:
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    if "id" not in request:
        continue
    print(json.dumps(json.loads(proc.stdout.readline()), indent=2))

proc.stdin.close()
proc.wait(timeout=10)
PY
.venv/bin/python drive.py
```

Expected, first frame (abridged — your `version` strings will differ):

```
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "experimental": {},
      "prompts": {"listChanged": false},
      "resources": {"subscribe": false, "listChanged": false},
      "tools": {"listChanged": false}
    },
    "serverInfo": {"name": "schema-lab", "version": "1.13.1"}
  }
}
```

Expected, second frame (abridged to the two tools that matter):

```
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "disk_usage",
        "description": "Report disk usage for a mount point on the host.",
        "inputSchema": {
          "properties": {
            "path": {"title": "Path", "type": "string"},
            "unit": {"default": "bytes", "title": "Unit", "type": "string"}
          },
          "required": ["path"],
          "title": "disk_usageArguments",
          "type": "object"
        },
        "outputSchema": {
          "properties": {
            "path": {"description": "Absolute path that was measured.", "title": "Path", "type": "string"},
            "used_bytes": {"minimum": 0, "title": "Used Bytes", "type": "integer"},
            "total_bytes": {"minimum": 0, "title": "Total Bytes", "type": "integer"},
            "percent_used": {"maximum": 100.0, "minimum": 0.0, "title": "Percent Used", "type": "number"}
          },
          "required": ["path", "used_bytes", "total_bytes", "percent_used"],
          "title": "DiskUsage",
          "type": "object"
        }
      },
      {
        "name": "host_label",
        "description": "Return a human-readable label for a mount point.",
        "inputSchema": { "...": "elided" },
        "outputSchema": {
          "properties": {"result": {"title": "Result", "type": "string"}},
          "required": ["result"],
          "title": "host_labelOutput",
          "type": "object"
        }
      }
    ]
  }
}
```

3. Compare the generated `disk_usage.inputSchema` against the one you hand-wrote in Exercise 1.

**Q2.1** `host_label` returns a plain `str`, yet its `outputSchema` describes an *object* with a single `result` property. What constraint in the MCP specification forces that wrapping?

**Q2.2** The generated input schema does **not** contain `additionalProperties: false`, and `unit` has no `enum`. Your hand-written one had both. Which is safer to ship, and what is the cost of the safer choice?

**Q2.3** `notifications/initialized` has no `id`. What does the absence of `id` mean in JSON-RPC 2.0, and what would happen if you sent `tools/list` *before* the `initialize` response came back?

**Q2.4** The client proposed `protocolVersion: "2025-06-18"` and the server echoed it. What is the server supposed to do if it does not support the version the client proposed?

---

## Exercise 3 — `structuredContent`, and the text block that shadows it

### Steps

1. Append a `tools/call` to `drive.py`'s `REQUESTS` list and re-run:

```bash
.venv/bin/python - <<'PY'
import re
source = open("drive.py").read()
call = '''    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "disk_usage", "arguments": {"path": "/"}},
    },
]'''
open("drive.py", "w").write(source.replace("]\n\nproc", call + "\n\nproc", 1))
PY
.venv/bin/python drive.py | tail -n 20
```

Expected (byte counts will differ):

```
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"path\":\"/\",\"used_bytes\":48318382080,\"total_bytes\":137438953472,\"percent_used\":35.16}"
      }
    ],
    "structuredContent": {
      "path": "/",
      "used_bytes": 48318382080,
      "total_bytes": 137438953472,
      "percent_used": 35.16
    },
    "isError": false
  }
}
```

2. Notice that the same data appears twice. Confirm they are byte-for-byte equivalent after parsing:

```bash
.venv/bin/python - <<'PY'
import json, subprocess, sys

proc = subprocess.Popen([sys.executable, "server.py"], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, text=True, bufsize=1)
for request in [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "by-hand", "version": "0.1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
     "params": {"name": "disk_usage", "arguments": {"path": "/"}}},
]:
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    if "id" in request:
        frame = json.loads(proc.stdout.readline())

result = frame["result"]
mirrored = json.loads(result["content"][0]["text"])
print("equivalent:", mirrored == result["structuredContent"])
proc.stdin.close()
PY
```

Expected:

```
equivalent: True
```

3. Call the deliberately broken tool:

```bash
.venv/bin/python - <<'PY'
import json, subprocess, sys

proc = subprocess.Popen([sys.executable, "server.py"], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, text=True, bufsize=1)
for request in [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "by-hand", "version": "0.1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
     "params": {"name": "broken_usage", "arguments": {"path": "/"}}},
]:
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    if "id" in request:
        frame = json.loads(proc.stdout.readline())
print(json.dumps(frame, indent=2))
proc.stdin.close()
PY
```

Expected (wording varies by SDK version; the shape is what matters):

```
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Error executing tool broken_usage: 3 validation errors for DiskUsage ..."
      }
    ],
    "isError": true
  }
}
```

**Q3.1** Why does the specification tell servers that return `structuredContent` to *also* emit the serialized JSON in a text content block? Name the concrete failure this prevents.

**Q3.2** In step 3 the response has `isError: true` but it is still a JSON-RPC **result**, not a JSON-RPC **error**. State the rule that decides which of the two a server should use, and explain why the rule exists in terms of what the model can see.

**Q3.3** Note what is *absent* from the step-3 response: there is no `structuredContent` key at all. Why is omitting it strictly better than emitting the invalid object alongside `isError: true`?

**Q3.4** A server declares an `outputSchema` but returns only a `content` text block and no `structuredContent`. Is that conformant?

---

## Exercise 4 — Validation is the client's job too

A spec-compliant client validates `structuredContent` against the advertised `outputSchema`. Most do not. Build the check so you know what it catches.

### Steps

1. Write a validating client shim:

```bash
cat > validate_result.py <<'PY'
"""Validate a tool result against the outputSchema the server advertised."""

import json
import sys

from jsonschema import Draft202012Validator


def check(output_schema: dict, result: dict) -> list[str]:
    problems = []
    structured = result.get("structuredContent")

    if output_schema is not None and structured is None and not result.get("isError"):
        problems.append("server advertises outputSchema but returned no structuredContent")

    if structured is not None:
        if output_schema is None:
            problems.append("server returned structuredContent for a tool with no outputSchema")
        else:
            validator = Draft202012Validator(output_schema)
            for error in sorted(validator.iter_errors(structured), key=lambda e: list(e.path)):
                pointer = "/" + "/".join(str(p) for p in error.path)
                problems.append(f"{pointer}: {error.message}")

    blocks = result.get("content") or []
    text_blocks = [b for b in blocks if b.get("type") == "text"]
    if structured is not None and text_blocks:
        try:
            if json.loads(text_blocks[0]["text"]) != structured:
                problems.append("text mirror does not match structuredContent")
        except json.JSONDecodeError:
            problems.append("text mirror is not parseable JSON")

    return problems


if __name__ == "__main__":
    schema = json.load(open(sys.argv[1]))
    payload = json.load(open(sys.argv[2]))
    found = check(schema, payload)
    print("VALID" if not found else "INVALID")
    for problem in found:
        print(f"  - {problem}")
    sys.exit(0 if not found else 1)
PY
```

2. Feed it a result that a careless server might send:

```bash
cat > schemas/bad-result.json <<'JSON'
{
  "content": [
    {
      "type": "text",
      "text": "{\"path\": \"/\", \"used_bytes\": 48318382080, \"percent_used\": 35.16}"
    }
  ],
  "structuredContent": {
    "path": "/",
    "used_bytes": "48318382080",
    "total_bytes": 137438953472,
    "percent_used": 135.16,
    "inode_free": 91234
  },
  "isError": false
}
JSON
.venv/bin/python validate_result.py schemas/outputSchema.json schemas/bad-result.json
```

Expected:

```
INVALID
  - : Additional properties are not allowed ('inode_free' was unexpected)
  - /percent_used: 135.16 is greater than the maximum of 100
  - /used_bytes: '48318382080' is not of type 'integer'
  - text mirror does not match structuredContent
```

**Q4.1** Four distinct defects are in that one payload. Rank them by how likely each is to reach a user as a *wrong answer* rather than a visible crash, and justify the ranking.

**Q4.2** `used_bytes` is the string `"48318382080"`. JSON Schema calls that invalid. Would a language model consuming the text mirror notice? What does that tell you about where validation must live?

**Q4.3** The `inode_free` extra property only fails because the schema sets `additionalProperties: false`. Argue both sides: should a *client* enforce `additionalProperties: false` on output it receives?

---

## Exercise 5 — Three schema traps that pass every superficial review

### Steps

1. **`format` is an annotation, not a constraint** — by default:

```bash
.venv/bin/python - <<'PY'
from jsonschema import Draft202012Validator

schema = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {"owner": {"type": "string", "format": "email"}},
    "required": ["owner"],
}
payload = {"owner": "not-an-email"}

lax = Draft202012Validator(schema)
strict = Draft202012Validator(schema, format_checker=Draft202012Validator.FORMAT_CHECKER)

print("lax   :", [e.message for e in lax.iter_errors(payload)])
print("strict:", [e.message for e in strict.iter_errors(payload)])
PY
```

Expected:

```
lax   : []
strict: ["'not-an-email' is not a 'email'"]
```

2. **Tuple `items` is a draft-07 idiom and is a hard error in 2020-12:**

```bash
.venv/bin/python - <<'PY'
from jsonschema import Draft7Validator, Draft202012Validator

tuple_style = {"type": "array", "items": [{"type": "string"}, {"type": "integer"}]}

Draft7Validator.check_schema(tuple_style)
print("draft-07: schema accepted")
try:
    Draft202012Validator.check_schema(tuple_style)
    print("2020-12 : schema accepted")
except Exception as exc:
    print("2020-12 :", type(exc).__name__)
PY
```

Expected:

```
draft-07: schema accepted
2020-12 : SchemaError
```

The 2020-12 spelling:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "array",
  "prefixItems": [{ "type": "string" }, { "type": "integer" }],
  "items": false,
  "minItems": 2
}
```

3. **`additionalProperties: false` does not see through `allOf`:**

```bash
.venv/bin/python - <<'PY'
from jsonschema import Draft202012Validator

schema = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "allOf": [{"type": "object", "properties": {"path": {"type": "string"}}}],
    "type": "object",
    "properties": {"unit": {"type": "string"}},
    "additionalProperties": False,
}
print([e.message for e in Draft202012Validator(schema).iter_errors({"path": "/", "unit": "gib"})])
PY
```

Expected:

```
["Additional properties are not allowed ('path' was unexpected)"]
```

The 2020-12 fix is `unevaluatedProperties`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "allOf": [
    {
      "type": "object",
      "properties": { "path": { "type": "string" } }
    }
  ],
  "type": "object",
  "properties": { "unit": { "type": "string" } },
  "unevaluatedProperties": false
}
```

**Q5.1** Your `inputSchema` declares `"format": "uri"` on a parameter that your tool passes to an HTTP client. Which component in the MCP chain is responsible for making that `format` bite, and what is the security consequence if nobody does?

**Q5.2** In step 3, why is `path` "additional" when it is plainly declared two lines above? Explain in terms of *which* subschema evaluates it.

**Q5.3** You generate schemas from Python type hints (Exercise 2) rather than writing them by hand. Which of these three traps does that eliminate, and which does it not?

---

## Exercise 6 — Resources: `mimeType`, `text` vs `blob`, and URI templates

### Steps

1. A concrete resource descriptor, and a template that stands for a family of them:

```json
{
  "uriTemplate": "logs://{cluster}/{+path}",
  "name": "cluster-log-file",
  "title": "Cluster log file",
  "description": "A log file inside a cluster's log root.",
  "mimeType": "text/plain"
}
```

2. Expand the template both ways and see why the `+` is load-bearing (RFC 6570 reserved expansion):

```bash
.venv/bin/python - <<'PY'
from uritemplate import URITemplate

values = {"cluster": "leloir", "path": "kube-system/apiserver/2026-09-17.log"}
print("plain   :", URITemplate("logs://{cluster}/{path}").expand(**values))
print("reserved:", URITemplate("logs://{cluster}/{+path}").expand(**values))
PY
```

Expected:

```
plain   : logs://leloir/kube-system%2Fapiserver%2F2026-09-17.log
reserved: logs://leloir/kube-system/apiserver/2026-09-17.log
```

3. The two legal shapes of a `resources/read` result, as raw frames:

```
{"jsonrpc":"2.0","id":11,"result":{"contents":[{"uri":"logs://leloir/kube-system/apiserver/2026-09-17.log","mimeType":"text/plain","text":"I0917 04:12:03.118 1 trace.go:236] Trace[901]: \"Get\" ...\n"}]}}
{"jsonrpc":"2.0","id":12,"result":{"contents":[{"uri":"artifact://leloir/heap-2026-09-17.pprof","mimeType":"application/octet-stream","blob":"H4sIAAAAAAAAA+3RsQ3CMBBA0S9..."}]}}
```

4. And the two ways a **tool** can hand a resource back inside a `CallToolResult` — a pointer versus the bytes:

```
{"type":"resource_link","uri":"logs://leloir/kube-system/apiserver/2026-09-17.log","name":"apiserver-2026-09-17","mimeType":"text/plain","description":"API server log for the incident window"}
{"type":"resource","resource":{"uri":"logs://leloir/kube-system/apiserver/2026-09-17.log","mimeType":"text/plain","text":"I0917 04:12:03.118 1 trace.go:236] ...\n"}}
```

**Q6.1** `contents` is an array even for a single file. What does that plural buy you, given a template like `logs://{cluster}/{+path}`?

**Q6.2** A `ResourceContents` object carries `text` **or** `blob`. What breaks if a server sends both?

**Q6.3** You are returning a 40 MB heap profile from a tool. `resource_link` or embedded `resource`? Give the two reasons — one about tokens, one about authorization.

**Q6.4** Your template is `logs://{cluster}/{path}` (no `+`) and a student reports that reads of nested paths 404. Reconstruct the bug from the step-2 output.

**Q6.5** Why does `mimeType` matter to a *client* that will only feed the bytes to a model? Name a decision the client makes from it.

---

## Exercise 7 — Elicitation: a deliberately impoverished schema subset

`elicitation/create` lets a server ask the *user* — not the model — for a value mid-execution. Its `requestedSchema` is **not** full JSON Schema. It is a flat object of primitives, and the restriction is the whole point.

### Steps

1. A conformant request schema:

```bash
cat > schemas/elicit-ok.json <<'JSON'
{
  "type": "object",
  "properties": {
    "confirm": {
      "type": "boolean",
      "title": "Proceed with the migration?",
      "default": false
    },
    "ticket": {
      "type": "string",
      "title": "Change ticket",
      "minLength": 6,
      "maxLength": 32
    },
    "window": {
      "type": "string",
      "title": "Maintenance window",
      "enum": ["now", "tonight", "next-weekend"],
      "enumNames": ["Immediately", "Tonight 02:00 UTC", "Next weekend"]
    },
    "notify": {
      "type": "string",
      "format": "email",
      "title": "Notification address"
    },
    "batch_size": {
      "type": "integer",
      "minimum": 1,
      "maximum": 500
    }
  },
  "required": ["confirm", "ticket", "window"]
}
JSON
```

2. One that a developer used to writing tool schemas would write without thinking:

```bash
cat > schemas/elicit-bad.json <<'JSON'
{
  "type": "object",
  "properties": {
    "owner": {
      "type": "object",
      "properties": {
        "name": { "type": "string" },
        "email": { "type": "string", "format": "email" }
      }
    },
    "hosts": {
      "type": "array",
      "items": { "type": "string" }
    },
    "policy": { "$ref": "#/$defs/policy" },
    "starts_at": { "type": "string", "format": "duration" }
  },
  "required": ["owner"],
  "$defs": {
    "policy": { "type": "string", "enum": ["strict", "lax"] }
  }
}
JSON
```

3. Write the linter that your CI should have:

```bash
cat > lint_elicit.py <<'PY'
"""Reject requestedSchema documents that exceed the elicitation subset."""

import json
import sys

PRIMITIVES = {"string", "number", "integer", "boolean"}
ALLOWED_FORMATS = {"email", "uri", "date", "date-time"}
FORBIDDEN_AT_ROOT = ("$ref", "$defs", "oneOf", "anyOf", "allOf", "not")


def lint(schema: dict) -> list[str]:
    problems = []
    if schema.get("type") != "object":
        problems.append("top level must be type: object")
    for key in FORBIDDEN_AT_ROOT:
        if key in schema:
            problems.append(f"top level uses {key}, which the subset forbids")
    for name, prop in schema.get("properties", {}).items():
        if "$ref" in prop:
            problems.append(f"{name}: $ref is not allowed, inline the definition")
            continue
        kind = prop.get("type")
        if kind not in PRIMITIVES:
            problems.append(f"{name}: type {kind!r} is not a primitive")
        fmt = prop.get("format")
        if fmt is not None and fmt not in ALLOWED_FORMATS:
            problems.append(f"{name}: format {fmt!r} is outside the subset")
    return problems


for path in sys.argv[1:]:
    found = lint(json.load(open(path)))
    print(f"{path}: {'OK' if not found else 'REJECTED'}")
    for problem in found:
        print(f"  - {problem}")
PY
.venv/bin/python lint_elicit.py schemas/elicit-ok.json schemas/elicit-bad.json
```

Expected:

```
schemas/elicit-ok.json: OK
schemas/elicit-bad.json: REJECTED
  - top level uses $defs, which the subset forbids
  - owner: type 'object' is not a primitive
  - hosts: type 'array' is not a primitive
  - policy: $ref is not allowed, inline the definition
  - starts_at: format 'duration' is outside the subset
```

4. The exchange, as raw frames — note there are three possible `action` values and only one of them carries `content`:

```
{"jsonrpc":"2.0","id":7,"method":"elicitation/create","params":{"message":"Confirm the migration window before I drain the node pool.","requestedSchema":{"type":"object","properties":{"confirm":{"type":"boolean","title":"Proceed?"},"ticket":{"type":"string","minLength":6}},"required":["confirm","ticket"]}}}
{"jsonrpc":"2.0","id":7,"result":{"action":"accept","content":{"confirm":true,"ticket":"CHG-4471"}}}
{"jsonrpc":"2.0","id":7,"result":{"action":"decline"}}
{"jsonrpc":"2.0","id":7,"result":{"action":"cancel"}}
```

**Q7.1** Why is the subset restricted to a *flat* object of primitives? Give the architectural reason, not "because the spec says so."

**Q7.2** `enumNames` sits next to `enum`. What is it for, and why would putting the human label in `enum` itself be a bug?

**Q7.3** Distinguish `decline` from `cancel`. Write the one-sentence rule a server should apply to each, and name the bug that appears if a server treats both as "user said no, use defaults."

**Q7.4** Your server needs a list of hostnames from the user, but `type: "array"` is forbidden. Give two conformant designs.

**Q7.5** A server sends `elicitation/create` asking for an API token. What is wrong with that, independent of any schema question?

---

## Exercise 8 — Prompt arguments are *not* JSON Schema

This asymmetry is deliberate and is a reliable exam target.

### Steps

1. A prompt descriptor as returned by `prompts/list`:

```json
{
  "name": "incident_review",
  "title": "Incident review",
  "description": "Draft a post-incident review from a set of signals.",
  "arguments": [
    {
      "name": "severity",
      "title": "Severity",
      "description": "Incident severity, one of SEV1 through SEV4.",
      "required": true
    },
    {
      "name": "cluster",
      "title": "Cluster",
      "description": "Cluster identifier, for example leloir-prod.",
      "required": false
    }
  ]
}
```

2. Try to find a place in that document to declare `severity ∈ {SEV1, SEV2, SEV3, SEV4}` as machine-readable data. There is none. The enumeration is instead *offered* at request time:

```
{"jsonrpc":"2.0","id":9,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"incident_review"},"argument":{"name":"severity","value":"SEV"},"context":{"arguments":{}}}}
{"jsonrpc":"2.0","id":9,"result":{"completion":{"values":["SEV1","SEV2","SEV3","SEV4"],"total":4,"hasMore":false}}}
```

3. And a context-dependent completion, where the candidate set for one argument depends on an argument already filled in:

```
{"jsonrpc":"2.0","id":10,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"incident_review"},"argument":{"name":"cluster","value":"lel"},"context":{"arguments":{"severity":"SEV1"}}}}
{"jsonrpc":"2.0","id":10,"result":{"completion":{"values":["leloir-prod","leloir-staging"],"total":2,"hasMore":false}}}
```

**Q8.1** A tool's parameters get a full JSON Schema; a prompt's arguments get `name`/`title`/`description`/`required` and nothing else. What is the difference between the two consumers that justifies this?

**Q8.2** Given that `severity` has no `enum` anywhere in the descriptor, where must the "SEV1..SEV4" constraint actually be enforced, and what does a server return when it is violated?

**Q8.3** `completion/complete` responses carry `values`, `total` and `hasMore`. Why is `hasMore` needed when `total` is already there? (Consider the 100-item response cap.)

**Q8.4** Is `completion/complete` a validation mechanism? Answer precisely.

---

## Exercise 9 — Schema evolution: replay a corpus before you ship

This is the exercise that maps directly onto production incidents. An input schema and an output schema evolve under *opposite* compatibility rules, and getting the polarity backwards is the classic mistake.

### Steps

1. Freeze v1 (your Exercise 1 input schema) and draft v2:

```bash
cp schemas/inputSchema.json schemas/input-v1.json
cat > schemas/input-v2.json <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "path": { "type": "string" },
    "unit": {
      "type": "string",
      "enum": ["bytes", "gib"],
      "default": "bytes"
    },
    "recursive": { "type": "boolean" }
  },
  "required": ["path", "recursive"],
  "additionalProperties": false
}
JSON
```

2. Record a corpus of real call arguments (JSON Lines — one document per line, which is why this is not a single JSON file):

```bash
cat > schemas/corpus.jsonl <<'EOF'
{"path": "/"}
{"path": "/var", "unit": "mib"}
{"path": "/var", "unit": "gib", "recursive": true}
{"unit": "bytes"}
EOF
```

3. Replay:

```bash
cat > replay_corpus.py <<'PY'
"""Replay recorded tool-call arguments against two input-schema versions."""

import json

from jsonschema import Draft202012Validator

V1 = Draft202012Validator(json.load(open("schemas/input-v1.json")))
V2 = Draft202012Validator(json.load(open("schemas/input-v2.json")))

with open("schemas/corpus.jsonl") as handle:
    for index, line in enumerate(handle, start=1):
        args = json.loads(line)
        v1_ok = not list(V1.iter_errors(args))
        v2_errors = sorted(error.message for error in V2.iter_errors(args))
        verdict = "ok" if not v2_errors else "BREAKS: " + "; ".join(v2_errors)
        print(f"{index}. v1={'ok' if v1_ok else 'invalid'}  v2={verdict}")
PY
.venv/bin/python replay_corpus.py
```

Expected:

```
1. v1=ok  v2=BREAKS: 'recursive' is a required property
2. v1=ok  v2=BREAKS: 'mib' is not one of ['bytes', 'gib']; 'recursive' is a required property
3. v1=invalid  v2=ok
4. v1=invalid  v2=BREAKS: 'path' is a required property; 'recursive' is a required property
```

4. Make v2 non-breaking without losing the intent, then re-run:

```bash
cat > schemas/input-v2.json <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "path": { "type": "string" },
    "unit": {
      "type": "string",
      "enum": ["bytes", "mib", "gib"],
      "default": "bytes",
      "description": "The value 'mib' is deprecated and will be removed after 2027-03-01."
    },
    "recursive": {
      "type": "boolean",
      "default": false,
      "description": "Descend into submounts. Defaults to false, which is the v1 behaviour."
    }
  },
  "required": ["path"],
  "additionalProperties": false
}
JSON
.venv/bin/python replay_corpus.py
```

Expected:

```
1. v1=ok  v2=ok
2. v1=ok  v2=ok
3. v1=invalid  v2=ok
4. v1=invalid  v2=BREAKS: 'path' is a required property
```

5. Wire it into CI so the rule is enforced rather than remembered:

```bash
cat > export_schemas.py <<'PY'
"""Write every tool's advertised inputSchema/outputSchema to schemas/generated/."""

import asyncio
import json
import pathlib

from server import mcp

OUT = pathlib.Path("schemas/generated")


async def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for tool in await mcp.list_tools():
        dumped = tool.model_dump(by_alias=True, exclude_none=True)
        for kind in ("inputSchema", "outputSchema"):
            if kind not in dumped:
                continue
            target = OUT / f"{tool.name}.{kind}.json"
            target.write_text(json.dumps(dumped[kind], indent=2) + "\n")
            print(f"wrote {target}")


if __name__ == "__main__":
    asyncio.run(main())
PY
.venv/bin/python export_schemas.py
```

Expected:

```
wrote schemas/generated/disk_usage.inputSchema.json
wrote schemas/generated/disk_usage.outputSchema.json
wrote schemas/generated/host_label.inputSchema.json
wrote schemas/generated/host_label.outputSchema.json
wrote schemas/generated/broken_usage.inputSchema.json
wrote schemas/generated/broken_usage.outputSchema.json
```

```yaml
name: mcp-schema-gate
"on":
  pull_request:
    paths:
      - "schemas/**"
      - "server.py"
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install validators
        run: pip install "mcp[cli]" jsonschema check-jsonschema
      - name: Every advertised schema must be a valid 2020-12 schema
        run: |
          python export_schemas.py
          check-jsonschema --check-metaschema schemas/generated/*.json
      - name: Elicitation schemas must stay inside the subset
        run: python lint_elicit.py schemas/elicit-*.json
      - name: Recorded calls must still validate against the new input schema
        run: python replay_corpus.py
```

**Q9.1** For an **input** schema, classify each as breaking or non-breaking, from the perspective of an already-deployed client: (a) add an optional property; (b) add a property to `required`; (c) remove a property from `required`; (d) add a value to an `enum`; (e) remove a value from an `enum`; (f) add `additionalProperties: false`.

**Q9.2** Now do (b) and (c) again for an **output** schema, from the perspective of a client that validates results. Why does the polarity invert?

**Q9.3** Corpus line 3 is `v1=invalid`. It was a *recorded real call*. What does that tell you about how the corpus was collected, and what should you do about it?

**Q9.4** The fixed v2 keeps `"mib"` in the enum but marks it deprecated in `description`. A validator will never enforce that sentence. What is it for, then — who reads it?

**Q9.5** `recursive` has `"default": false`. Does JSON Schema *inject* that default into the request when the client omits the key? Where must the default actually be applied?

**Q9.6** The CI job regenerates schemas from `server.py` rather than validating checked-in files. Name the class of bug this catches that a checked-in-file check cannot.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1** Because the two dialects disagree on *which documents are schemas at all*, not merely on edge-case validation results. A draft-07-shaped schema can be rejected by the 2020-12 metaschema (see A0.2), and conversely a 2020-12 keyword like `prefixItems` or `unevaluatedProperties` is simply an unknown annotation to a draft-07 validator — it is silently ignored, so your constraint evaporates without a single error message. Establishing the dialect first turns "my constraint did not fire" into a loud failure instead of a silent one. MCP pins draft 2020-12 for `inputSchema` and `outputSchema`, so everything downstream — your CI validator, your client-side output check, your code generator — must be pinned to the same thing.

**A0.2** Tuple-form `items`, i.e. `"items": [ {...}, {...} ]`. In draft-07 an array of schemas positionally constrains array elements. In 2020-12 `items` must be a single schema (or a boolean); the positional form moved to `prefixItems`, and the 2020-12 metaschema rejects the array form outright. Demonstrated in Exercise 5 step 2. Other examples: `definitions` → `$defs`, `dependencies` → `dependentRequired`/`dependentSchemas`.

### Exercise 1

**A1.1** Because `tools/call` carries arguments as `params.arguments`, a named key/value mapping. The schema describes that mapping, so its root must be an object type — there is no positional-argument form in MCP for a client to fill from an array schema, and a string-typed root would have nothing to bind a parameter name to. This is also what makes the schema directly usable as a function-calling declaration for the model: every mainstream tool-calling API expects a named-parameter object.

**A1.2** No — a client may not treat it as a guarantee. `annotations` is untrusted metadata supplied by the server itself, and MCP explicitly states that clients must consider tool annotations untrusted unless the server is trusted. A malicious or merely buggy server can declare `readOnlyHint: true` on a tool that deletes things. The word "hint" is doing exactly that work: it is input to the client's UX policy (how prominently to confirm, whether to allow auto-approval for this server), not a security boundary. The boundary is the human approval step and whatever the server's own authorization layer enforces.

**A1.3** It shows up at the *model* layer, not the protocol layer. The malformed `required` is nested inside `inputSchema`, which JSON-RPC treats as an opaque object — the frame parses, `tools/list` returns 200-equivalent, and nothing in the transport objects. The client then hands the schema to the model as a tool declaration. Depending on the provider it either gets rejected by the model API with an opaque "invalid function declaration" error, or gets accepted with the constraint quietly dropped, in which case the model starts calling `disk_usage` with no `path` and the server raises a runtime error the user sees as "the tool is broken." The party who reports it is the end user, days later, with no useful diagnostic — which is precisely why `--check-metaschema` belongs in CI.

**A1.4**
- On the **input** schema, `additionalProperties: false` is a server-side guard: it rejects arguments the tool does not understand, catching model hallucination of plausible-but-nonexistent parameters (`"recursive": true` before you implemented it) at the boundary instead of letting them be silently dropped. Cost: it makes adding a parameter a two-sided deployment, and it can reject clients that attach vendor extensions.
- On the **output** schema, it is a promise to consumers that the result shape is closed. That makes it a *forward-compatibility hazard*: the moment you add a field to the result, every strict client validating against the old schema starts failing on perfectly good data. For outputs, closed schemas are usually the wrong default — see A9.2.

### Exercise 2

**A2.1** `structuredContent` in a `CallToolResult` is specified as a JSON **object**, not an arbitrary JSON value. A bare `"mount /"` is a JSON string and cannot be assigned to an object-typed field. FastMCP therefore synthesises a single-key wrapper object, `{"result": "mount /"}`, and generates an `outputSchema` describing exactly that wrapper. The practical consequence for a client author: never assume the shape of `structuredContent` mirrors the tool's conceptual return value — read the advertised `outputSchema`, which is the only authoritative description, and expect a `result` key for primitive-returning tools.

**A2.2** The hand-written one is safer, and the cost is maintenance coupling. The generated schema permits `{"path": "/", "unit": "furlongs", "recursive": true}`: `unit` is an unconstrained string, and unknown keys pass. Your tool then either silently ignores `recursive` — the user believes it recursed and it did not — or crashes on `furlongs` deep inside the implementation where the error message names nothing the user can act on. The `enum` and `additionalProperties: false` move both failures to the protocol boundary, where the error is precise and the *model itself* can see the legal values and self-correct. The cost: every new parameter and every new enum value is now a schema change that old clients will reject, so you own a compatibility process (Exercise 9). In Python you buy most of this back for free with `Literal["bytes", "mib", "gib"]` and a Pydantic model configured to forbid extras, which keeps the schema generated rather than hand-maintained.

**A2.3** In JSON-RPC 2.0 a message without `id` is a **notification**: the receiver must not send any response to it, and the sender cannot know whether it was processed. `notifications/initialized` is the client telling the server "handshake complete, I am ready" — there is nothing to wait for. Sending `tools/list` before the `initialize` response arrives violates the lifecycle: the client has not yet learned the negotiated protocol version or the server's capabilities, so it does not even know whether `tools/list` is a supported method. A conformant server should reject the request; in practice you will see anything from a `-32600`-class error to a hang. The rule is: `initialize` request → `initialize` response → `notifications/initialized` → everything else.

**A2.4** It responds with a version it *does* support (protocol versions are date strings, so the server picks the latest it supports that is not newer than requested, commonly falling back to its own latest). The client then inspects the version in the `initialize` result and, if it cannot work with what came back, it must disconnect rather than proceed. The negotiation is a proposal/counter-proposal, not a demand — and critically, the client must read the *response's* `protocolVersion`, not assume its own proposal was accepted, because feature availability (`outputSchema`, `structuredContent`, `elicitation`, `resource_link`) depends on it.

### Exercise 3

**A3.1** Backwards compatibility with clients — and with models — that were written before structured output existed, and with clients that ignore `structuredContent` entirely. Those consumers only ever look at `content`. The concrete failure prevented: a server upgrades, starts returning data exclusively in `structuredContent`, and every older client suddenly shows the user an empty tool result. Empty, not errored — the call "succeeded" and returned nothing visible. The duplication is redundant on the wire and worth it, because the alternative degradation mode is silent.

**A3.2** The rule: a **JSON-RPC error** (`error` object with a code) signals that the protocol-level operation failed — unknown tool, malformed params, server internal fault. **`isError: true` inside a successful result** signals that the tool ran and the *domain operation* failed — file not found, API returned 503, validation rejected the output. The reason the distinction exists is visibility to the model: a JSON-RPC error is handled by the client's transport layer and typically never reaches the model, whereas an `isError` result is delivered to the model as tool output, so the model can read "no such mount point /varr" and retry with `/var`. Collapsing tool failures into JSON-RPC errors removes the model's ability to recover; collapsing protocol errors into `isError` hides real bugs inside a conversation transcript.

**A3.3** Because a client that validates would have to choose between two contradictory signals, and a client that does not validate would consume garbage. If you emit `structuredContent: {"path": "/", "used_bytes": -1, "percent_used": 1200.0}` alongside `isError: true`, a downstream consumer that branches on the presence of `structuredContent` before checking `isError` — a very common ordering — will happily report 1200% disk usage. Omitting the key makes the absence structural: there is no valid structured result, so there is no structured result. The general principle: never emit a value that violates a contract you published, even flagged; make the invalid state unrepresentable in the payload.

**A3.4** No. If a tool declares an `outputSchema`, it must return `structuredContent` conforming to it for every successful call. The declaration is a promise; a text-only response breaks it, and a validating client is entitled to treat that as a protocol violation. (The reverse is fine in the compatibility direction: `content` must be present too, carrying the serialized mirror.) The one exemption is the error path — an `isError: true` result carries no `structuredContent`, per A3.3.

### Exercise 4

**A4.1** Ranked most-dangerous to least:

1. **`percent_used: 135.16`** — structurally perfect JSON, correct type, plausible-looking number. Nothing crashes. A model summarising it says "the disk is 135% full" or, worse, rounds it into a confident recommendation. Only the schema's `maximum: 100` catches it, and only if someone runs the check.
2. **the text mirror disagreeing with `structuredContent`** — the mirror is missing `total_bytes`. The model reads the text, code reads the structured object, and the two halves of the system now believe different things. This is the hardest to debug because each half is internally consistent.
3. **`used_bytes` as a string** — dangerous in a typed consumer (`"48318382080" + 1` is a TypeError in Python, a string concatenation in JavaScript — the JS case is the silent one), but a model reading the text mirror will interpret it correctly, so the blast radius is narrower.
4. **`inode_free` unexpected** — the least harmful. Extra data is usually ignorable; it fails here only because of a policy choice (see A4.3).

**A4.2** A model would not notice, and would answer correctly anyway: `"48318382080"` and `48318382080` read identically to a language model, which has no type system. That is exactly the problem. The model is the most forgiving consumer in the chain and therefore the worst place to rely on for correctness — it will paper over type errors right up until the value flows into code (a chart, a threshold comparison, a billing calculation) that does care. Validation must live in the **client, before the result enters the model's context**, because that is the last point where a type error is still a type error rather than a plausible sentence.

**A4.3** *For:* if the server declared `additionalProperties: false`, the client is enforcing the server's own published contract, and an unexpected key means the server is either misconfigured, an impostor, or silently a different version than advertised — all worth failing loudly on, especially in a multi-tenant or untrusted-server deployment. *Against:* it makes every additive server change a client outage, which is the single most common cause of "we can't upgrade the server" paralysis; and the client typically has no legitimate interest in keys it does not read. **Practical stance:** the client should validate the *declared* properties strictly (types, ranges, required) and treat unknown properties as a warning, not a hard failure — even when the schema says `false`. Log it, surface it in a health metric, do not break the user's session. Reserve hard rejection for deployments where the server is untrusted.

### Exercise 5

**A5.1** Nobody, by default — and that is the finding. In draft 2020-12 `format` belongs to the *format-annotation* vocabulary: validators are required only to collect it as an annotation, and asserting on it is opt-in. So `"format": "uri"` in your `inputSchema` constrains nothing unless (a) the client's validator has format assertion enabled *and* the client validates arguments before sending, and (b) your server's validator has it enabled on the receiving side. Assume both are off. The security consequence: a parameter documented as a URI arrives as `file:///etc/shadow`, `http://169.254.169.254/latest/meta-data/`, or `gopher://…`, and your tool dutifully fetches it — classic SSRF, reached through a schema everyone believed was validating. **The tool implementation must re-validate every argument itself**: parse the URI, allowlist the scheme, resolve and allowlist the host. Treat `format` as documentation for the model and the UI, never as a control.

**A5.2** Because `additionalProperties` only considers properties matched by `properties` and `patternProperties` **in the same schema object**. The `allOf` branch is a *different* schema object; properties it declares are invisible to the outer `additionalProperties`. So the outer schema sees an instance key `path` that its own `properties` (which lists only `unit`) does not match, and rejects it. The fix is `unevaluatedProperties: false`, a 2020-12 keyword that runs *after* all applicators — `allOf`, `anyOf`, `$ref`, conditionals — and considers any property any of them successfully evaluated. This is the single most common schema-composition bug, and it bites hardest in generated schemas that use `$ref` into `$defs`.

**A5.3** Generation eliminates trap 2 entirely (the generator emits `prefixItems` or a homogeneous `items`; you never hand-write the tuple form) and largely eliminates trap 3 (a Pydantic model with inheritance emits `$ref`/`allOf` *and* the matching `unevaluatedProperties` or a flattened schema — it will not hand-assemble the broken combination). It does **not** eliminate trap 1. `Field(json_schema_extra={"format": "uri"})` or an `AnyUrl`-typed field emits `"format": "uri"` into the schema, and whether anything enforces it still depends entirely on the *consumer's* validator configuration, which is outside your generator's reach. Pydantic will enforce it inside your own process on `AnyUrl`; nothing enforces it in the client, and nothing enforces it for a hand-built argument dict. Format assertion is a deployment property, not a schema property.

### Exercise 6

**A6.1** A single `uri` — especially an expanded template — can legitimately denote a *set* of things: `logs://leloir/{+path}` where `path` is a directory, a glob, or a query that matches several files. The `contents` array lets one `resources/read` return all of them in one round trip, each with its own concrete `uri` and its own `mimeType`. Note that the `uri` inside each `ResourceContents` is the resolved, specific URI, which may differ from the one the client asked for — that is how the client learns what it actually got.

**A6.2** Nothing "breaks" at the JSON parsing layer, which is why this bug ships. The failure is at the consumer: `text` and `blob` are mutually exclusive by contract, so client implementations branch on `if "text" in contents` versus `if "blob" in contents` in whatever order the author happened to write. Two clients reading the same response then disagree about the content — one decodes the base64, the other renders the text — and if the two representations differ (they always eventually do), you get a data-integrity bug that reproduces on one client and not the other. Validate that exactly one is present, on both send and receive.

**A6.3** Use `resource_link`.
- **Tokens:** an embedded `resource` is inlined into the tool result and therefore into the model's context window. 40 MB of base64 is roughly 53 MB of characters — it will not fit in any context window, and if it did it would cost more than the entire rest of the session. A `resource_link` costs a URI and a description.
- **Authorization:** a `resource_link` puts the read back through `resources/read`, which is a separate, client-mediated operation subject to the client's own resource permissions and the user's consent. The client can decide not to fetch it, fetch it into a file rather than the context, or ask the user first. Embedding bypasses all of that — the tool has unilaterally decided that 40 MB of process memory belongs in the conversation.

**A6.4** Without `+`, RFC 6570 simple expansion percent-encodes every reserved character in the value, including `/`. So `kube-system/apiserver/2026-09-17.log` expands to `kube-system%2Fapiserver%2F2026-09-17.log`, and the server's resolver — which splits on literal `/` to walk the directory tree — looks for a single file whose name contains the characters `%2F`. It does not exist, hence the 404, and hence the fact that flat paths at the root work fine while nested ones do not. Reserved expansion `{+path}` passes `/` through unencoded. The rule of thumb: `{+var}` for anything that is itself a path or a URI fragment; plain `{var}` for opaque identifiers where encoding is what you want.

**A6.5** Several decisions, all made before the bytes reach the model:
- **Whether the model can consume it at all.** `image/png` goes into an image content block for a vision-capable model; `application/octet-stream` cannot go into the context in any useful form and should become a link or a note.
- **Whether to decode `blob` or read `text`.** `application/json` and `text/plain` belong in a text block; anything binary does not.
- **How to render it to the *user*** — syntax highlighting, a download affordance, an inline preview.
- **Whether to truncate and how.** Truncating the middle of a JSON document produces an unparseable fragment; truncating a log file is fine.

A missing or wrong `mimeType` collapses all of these into a guess.

### Exercise 7

**A7.1** Because the rendering client must be able to build a **complete, correct form UI, generically, for a schema it has never seen, with no schema-library dependency and no ambiguity**. Full JSON Schema is Turing-adjacent as a UI specification: `oneOf` needs a discriminator widget, `$ref` needs resolution (and can be recursive, or remote — a fetch, and therefore an SSRF surface), `allOf` with `unevaluatedProperties` needs an annotation-collecting evaluator, nested objects need a tree editor, arrays need add/remove/reorder. A client that implements 80% of that renders *some* elicitations wrong, silently, with the user's credentials or a production change on the line. Restricting to a flat object of primitives means a conformant client is a few hundred lines — text input, number input, checkbox, select — and every client renders every elicitation identically. The restriction is a guarantee of universal, faithful rendering, not a limitation the spec regrets.

**A7.2** `enumNames` supplies the human-readable label for each `enum` value, positionally. `enum` carries the wire values the server will receive (`"next-weekend"`); `enumNames` carries what the user sees (`"Next weekend"`). Putting the label in `enum` is a bug for two reasons: it forces your server to parse display text back into a domain value, and it makes the *labels* your API contract — the moment you improve a label for clarity, or a client localises it, the value the server receives changes and your handler's comparison fails. Keep the machine value stable and opaque; let the label be free to change.

**A7.3**
- **`decline`** — the user saw the request and explicitly refused. Rule: *abort the operation and report the refusal to the model as a definitive negative*; do not retry, do not substitute defaults. The user made a decision and it was "no."
- **`cancel`** — the user dismissed the dialog without deciding (closed the window, navigated away, timed out). Rule: *abort the operation and report that no answer was obtained*; a retry may be reasonable later, but the user's intent is unknown.

The bug from conflating them with "use defaults": your migration prompt has `"confirm": {"type": "boolean", "default": false}`. If the server applies defaults on `decline`, the semantics happen to be safe here. But invert one field — `"skip_backup": {"type": "boolean", "default": true}` — and a user who declined the dialog has just authorised a backup-less migration they never agreed to. The general rule: **a non-`accept` action means you received no values at all**, and defaults declared in the schema are UI pre-fill hints for the form, not a fallback for consent. `content` is present only on `accept`.

**A7.4**
1. **A delimited string with a documented separator and a pattern**: `{"type": "string", "title": "Hostnames (comma-separated)", "pattern": "^[a-z0-9.-]+(,[a-z0-9.-]+)*$", "maxLength": 512}`. The server splits and re-validates each element. Simple, one round trip, poor UX for long lists.
2. **Iterative elicitation**: ask for one hostname plus a boolean `add_another`, and loop until it comes back false. Or, better, elicit a *selection* — if the candidate set is known server-side, present it as a sequence of `enum` choices, or as one `enum` per slot. More round trips, each of which the user can decline.

A third option worth naming: if the list already exists somewhere the user can point at, elicit a single `{"type": "string", "format": "uri"}` naming the source and read it yourself.

**A7.5** Elicitation is the wrong channel for secrets, and the spec says so: servers **must not** use elicitation to request sensitive information. The value travels back through the client as ordinary JSON-RPC `content`, where it is liable to be logged by the client, persisted in a session transcript, included in telemetry, and — most importantly — placed in the model's context, from which it can be echoed into a later completion or exfiltrated by a prompt injection in some other tool's output. Credentials must reach the server out of band: environment, a secret store, or an OAuth flow the client mediates without ever materialising the token as protocol content.

### Exercise 8

**A8.1** The consumers are different agents entirely. A **tool** is invoked by the *model*, autonomously, from a declaration the model has to reason over: the model must infer, without asking anyone, which parameters exist, what types they take, what is optional, and what values are legal. That inference only works if the contract is machine-precise — hence full JSON Schema, which doubles as the function-calling declaration every model API expects. A **prompt** is invoked by the *user*, deliberately, through the client's UI — a slash command, a menu. The user is present, can read a sentence, and can be offered a picker. The client needs only enough to render "this argument is called `severity`, here is what it means, it is mandatory"; anything more structured is better delivered interactively through `completion/complete`, which can consult live state (A8.3) in a way a frozen schema cannot.

**A8.2** In the server's `prompts/get` handler, and nowhere else. Nothing between the client and the handler knows the constraint exists — the descriptor has no `enum`, the completion response is advisory, and the user can type whatever they like. On violation the server returns a **JSON-RPC error** (invalid params, `-32602`), because this is a malformed request to the protocol operation, not a domain failure the model should reason about — `prompts/get` has no `isError` channel the way `tools/call` does. Its result is a list of messages to hand to the model, and there is no such thing as "a prompt that errored" for the model to read.

**A8.3** They answer different questions. `total` is the size of the full candidate set *if the server knows it*; it is optional precisely because the server often does not — a completion backed by a database prefix scan or a remote API can cheaply produce the first 100 matches and cannot cheaply count all of them. `hasMore` answers the question the UI actually needs: "should I tell the user this list is truncated and they should keep typing?" With the 100-value response cap, a server returning exactly 100 values with `total` omitted is completely ambiguous without `hasMore` — the client cannot tell a set of exactly 100 from a set of 40,000. `hasMore: true` with no `total` is a perfectly ordinary and useful response.

**A8.4** No. It is strictly an **advisory, interactive UX affordance** — the IDE-autocomplete of MCP. Three reasons it cannot be validation: the client is never obliged to call it; the user is never obliged to pick from the returned list and can type anything; and the returned set is explicitly allowed to be incomplete (`hasMore`), so "not in the list" does not imply "invalid." Treat it as a way to make the right answer easy to find, and enforce legality independently in the handler (A8.2). A server that trusts completion as validation is trusting the client to have been polite.

### Exercise 9

**A9.1** From the perspective of an already-deployed client sending arguments:

| Change | Verdict | Why |
|---|---|---|
| (a) add an optional property | **non-breaking** | old clients omit it; the server applies its default |
| (b) add a property to `required` | **breaking** | every old call now fails validation — corpus lines 1, 2 and 4 |
| (c) remove a property from `required` | **non-breaking** | a widening; old clients still send it, which remains valid |
| (d) add a value to an `enum` | **non-breaking** | old clients only send the old values, all still legal |
| (e) remove a value from an `enum` | **breaking** | old clients still send `"mib"` — corpus line 2 |
| (f) add `additionalProperties: false` | **breaking** | any client sending an extra key is now rejected; may also break vendor extensions and `_meta`-adjacent conventions |

The generating principle: for input, **widening is safe, narrowing is breaking**, because the schema is a filter the client's existing traffic must pass through.

**A9.2** For an **output** schema, the client is the validator and the server is the producer, so the direction of trust reverses:

- (b) **adding a property to `required`** is **non-breaking for existing clients** — they receive a field they do not read and, unless they enforce `additionalProperties: false` locally, ignore it. It *is* breaking for any other implementation of the same schema (a second server, a mock, a fixture) that now fails to produce a required field.
- (c) **removing a property from `required`** is **breaking** — a client that was written against `required: ["total_bytes"]` dereferences it unconditionally and gets a `KeyError` on the first response that omits it.

The polarity inverts because compatibility is always about *who must accommodate whom*. On input, the client produces and the server accepts: the server's schema must stay at least as permissive as the client's habits. On output, the server produces and the client accepts: the server's schema must stay at least as *specific* as the client's expectations. Same rule, opposite direction: **be liberal in what you accept, conservative in what you promise to stop sending.**

**A9.3** It means the corpus was recorded from *attempted* calls, not accepted ones — line 3 sends `recursive` against a v1 schema that has `additionalProperties: false`, so it was rejected at the boundary. That is the most valuable line in the file, not a defect. It is direct evidence that a model (or a client) is trying to call the tool with a parameter it expects to exist. Do not filter it out. Do two things with it: (1) keep logging rejected calls, since they are your best demand signal for which parameters to implement next and your best detector of schema/description mismatch — if the model keeps inventing `recursive`, your description implies recursion; (2) tag corpus entries with their accept/reject outcome so the replay report can distinguish "this used to work and now breaks" (a regression) from "this never worked and now does" (a feature).

**A9.4** Two readers, neither of them a validator. First, **the model**: the description is included verbatim in the tool declaration the model sees, so "the value 'mib' is deprecated" measurably shifts which value the model picks — this is the cheapest deprecation mechanism you have, and it takes effect the moment the schema is served, with no client upgrade. Second, **the human** reading generated docs or an IDE hover. That is the whole deprecation strategy in a protocol with no client-version negotiation beyond `protocolVersion`: you cannot force clients to stop sending `"mib"`, so you keep accepting it, steer new traffic away through the description, watch the corpus until `"mib"` stops appearing, and only then remove it from the enum. (JSON Schema also has a `deprecated: true` annotation, which is likewise non-asserting but machine-readable — worth setting alongside the prose so tooling can surface it.)

**A9.5** No. JSON Schema's `default` is an **annotation**: it is metadata describing a sensible value, and the specification is explicit that validators do not modify the instance. A validator run over `{"path": "/"}` against the v2 schema does not produce `{"path": "/", "recursive": false}` — it produces "valid," and the key is still absent. Some validator libraries offer default-injection as a non-standard opt-in extension; relying on it makes your behaviour library-specific and silently wrong when the client's validator differs. The default must be applied **in the tool implementation**, as an ordinary language-level default (`def disk_usage(path: str, recursive: bool = False)`), which is also where it will be correct regardless of which client called you or whether any validator ran at all. The schema's `default` then serves the same role as the description: it tells the model and the UI what happens when the field is omitted.

**A9.6** **Drift between the code and the checked-in contract.** A checked-in-file check proves the file is a valid schema; it cannot prove the file is the schema the server will actually serve. Someone changes a type hint from `str` to `str | None`, renames a parameter, adds a Pydantic field, or bumps the SDK to a version that emits schemas differently — the handwritten JSON in the repo still validates perfectly and now describes a server that no longer exists. Regenerating from `server.py` inside CI makes the *running server's advertised contract* the thing under test, so every one of those changes shows up as a diff in `schemas/generated/` and, if it narrows the input, as a corpus replay failure in the next step. It is the same reason you snapshot-test generated API clients rather than reviewing the generator.

</details>

---

## Sources

- Linux Foundation — *Model Context Protocol Associate (MCPA)* certification: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
- MCP specification, Tools (`inputSchema`, `outputSchema`, `structuredContent`, annotations, error semantics): https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- MCP specification, Resources (`mimeType`, `text`/`blob`, resource templates): https://modelcontextprotocol.io/specification/2025-06-18/server/resources
- MCP specification, Prompts (argument descriptors): https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
- MCP specification, Elicitation (restricted schema subset, `accept`/`decline`/`cancel`): https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- MCP specification, Completion (`completion/complete`, `context`, the 100-value cap): https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/completion
- MCP specification, Lifecycle and version negotiation: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- JSON Schema draft 2020-12, Core (`$defs`, `prefixItems`, `unevaluatedProperties`, applicator scoping): https://json-schema.org/draft/2020-12/json-schema-core.html
- JSON Schema draft 2020-12, Validation (`format` vocabulary, `default` as annotation, `deprecated`): https://json-schema.org/draft/2020-12/json-schema-validation.html
- JSON-RPC 2.0 Specification (notifications, error codes): https://www.jsonrpc.org/specification
- RFC 6570, URI Template (simple vs reserved expansion): https://datatracker.ietf.org/doc/html/rfc6570
- MCP Python SDK: https://github.com/modelcontextprotocol/python-sdk
- MCP Inspector: https://github.com/modelcontextprotocol/inspector