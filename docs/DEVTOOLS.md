# Developer tools: code graph, wiki, and real metrics

How to use Graphify and OpenWiki from the CLI, what happens when the code
changes, and where the real spend numbers live. Background and the adoption
reasoning: [AGENTIC_TOOLING_STUDY.md](AGENTIC_TOOLING_STUDY.md).

Three ideas, one sentence each:

- **Graphify** keeps a queryable map of the machinery — free (tree-sitter
  AST, no LLM), rebuilt automatically on every commit.
- **OpenWiki** writes and maintains a prose wiki of the machinery — every
  run costs API credits, so it runs manually, never unattended.
- **Metrics** are recorded per completion at the moment they happen and
  reported by stage/day/window — measured, never estimated.

---

## 1. The code graph (Graphify)

### Setup, once per clone

```bash
make graph-setup     # pip-installs graphifyy into .venv
make graph           # build: graph.json, graph.html, GRAPH_REPORT.md in graphify-out/
```

`graph.json` and `GRAPH_REPORT.md` are committed — they are the shared map
every agent reads. `graph.html` and the cache are per-machine (gitignored);
`make graph` regenerates the HTML whenever you want the visual.

`.graphifyignore` scopes the graph to the machinery. `certs/` and `media/`
stay out: they are product, not architecture.

### Using it from the CLI

```bash
.venv/bin/graphify query "what enforces the budget during generation?"
.venv/bin/graphify explain "teach/core/quality.py"     # node + neighbors
.venv/bin/graphify path "run_cert.py" "generator.py"   # how A reaches B
```

`query` runs a BFS over the graph and returns a scoped subgraph with
file:line anchors (~2k tokens) — use it instead of a grep session when the
question is "what connects to what". `explain` wants a repo-relative path or
node id when a name is ambiguous; it tells you the candidates.

Open `graphify-out/graph.html` in a browser for the interactive map: 45
communities, force-directed, searchable. `GRAPH_REPORT.md` is the text
version — hubs, god nodes, surprising cross-module edges.

### Using it from an agent (MCP)

`.mcp.json` registers the graph as an MCP server (`graphify` →
`python -m graphify.serve graphify-out/graph.json`). Claude Code picks it up
per-project and gets `query_graph`, `get_node`, `get_neighbors`,
`shortest_path`. Ask the graph before fanning out file searches — it is
cheaper and it is current.

For other assistants or shared access there is an HTTP mode:

```bash
.venv/bin/python3 -m graphify.serve graphify-out/graph.json \
    --transport http --port 8080 --api-key "$SECRET"
```

### When the code changes

Nothing to remember:

1. **Every commit** → `.githooks/post-commit` runs `graphify update .`
   (seconds, no API call). The refreshed graph lands in the working
   tree and rides along with the *next* commit — the committed graph lags
   HEAD by exactly one commit, by design.
2. **`make verify`** runs `scripts/check_graph.py`, which says stale/OK.
   Fresh means: the report's commit stamp is HEAD, or the hook's scan marker
   (`graphify-out/.last-scan`) is HEAD, or nothing the graph covers changed
   since that baseline — `update` deliberately leaves outputs (stamp
   included) untouched when no topology changed, so the stamp alone lags on
   docs-only commits. Warn-only by default; `--strict` for anything that
   relies on the graph.
3. Manual at any time: `make graph` (also regenerates `graph.html`).

The hook needs `git config core.hooksPath .githooks`, which `make setup`
already sets — same switch that installs the pre-commit contract hook.

Do **not** use `graphify hook install` or `graphify claude install` here:
the first fights `core.hooksPath`, the second appends to hand-authored
contract files (CLAUDE.md / AGENTS.md). Both are replaced by the two files
above.

### The derived wiki (free — no LLM at all)

```bash
.venv/bin/graphify export wiki    # also runs as part of `make graph`
```

Writes `graphify-out/wiki/` — one Markdown article per community and per god
node, plus `index.md` as the agent entry point. It is generated
deterministically from the graph (`graphify/wiki.py` contains no LLM call),
so it costs nothing and never drifts from graph.json. The community *names*
it uses come from the one paid step below. Done 2026-08-18: 69 articles.

### Optional, costs completions

```bash
.venv/bin/graphify label . --backend claude-cli   # LLM names for communities
```

`--backend claude-cli` spends the owner's subscription window (one batched
call named all 59 communities on 2026-08-18); the same flags accept
`openai` + `OPENAI_BASE_URL` for the cluster LiteLLM proxy. Code extraction
and the wiki export never need any of this.

### Semantic enrichment — documented, deliberately not run

```bash
.venv/bin/graphify extract docs --backend claude-cli   # or a scoped path
.venv/bin/graphify export wiki                         # refresh derived wiki
git add graphify-out/ && git commit                    # share the new layer
```

What it adds: today the graph sees prose only *structurally* (headings,
explicit links). The semantic pass has an LLM read the text and extract
concepts and relations that are written but not linked — "the quality floor
is applied before writing", "the timer respects ownership" — as nodes with
edges bridging docs ↔ code where no import or link exists. Conceptual
queries ("why is the timer disabled?") start returning connected answers
instead of section titles.

Why it stays off by default (decision with the owner, 2026-08-18):
- Its edges are `INFERRED` with partial confidence; the current graph is
  100% `EXTRACTED` — everything provable. Reach up, certainty down.
- Agents mostly ask the graph structural questions, which are already
  covered; conceptual ones are answered by the docs themselves.
- **It ages while costing**: the semantic layer goes stale on every doc
  edit and refreshing it costs LLM each time, unlike the AST layer the
  post-commit hook refreshes for free. A half-stale inferred layer gets
  believed, which is worse than none.

When to turn it on: the first time an agent's conceptual graph query comes
back empty and that mattered. Run it scoped (a path, not the repo root),
re-export the wiki, commit, and note the spend — it lands in graphify's own
accounting, not `usage.jsonl`.

## 2. The wiki (OpenWiki)

**Every OpenWiki run spends API credits.** It has no subscription route —
provider is an API key or an OpenAI-compatible endpoint. Run it by hand,
watch the first bill, never schedule it (same policy as the disabled
`teach-resume.timer`).

### Setup, once

```bash
npm install -g openwiki
export OPENWIKI_TELEMETRY_DISABLED=1
openwiki --init          # interactive: pick provider, key, model
```

**There is no Claude-subscription route** — settled 2026-08-18 against the
installed package's source, not the README: `SELECTABLE_OPENWIKI_PROVIDERS`
in `dist/config/constants.js` is exactly `openai, openai-chatgpt, anthropic,
copilot, gemini, gemini-enterprise, openrouter, openai-compatible, bedrock,
fireworks, baseten, nebius, nvidia` — no `claude`. The `claude-*` strings in
that file are MODEL ids under the `anthropic` provider
(`OPENWIKI_MODEL_ID=claude-opus-4-8`), and the only external-CLI auth
adapter in the codebase is `github-cli` (Copilot). The `anthropic` provider
takes `ANTHROPIC_API_KEY` only — though it also honors `ANTHROPIC_BASE_URL`,
so a proxy that speaks the Anthropic API format (LiteLLM does) is usable
with real API keys behind it;
the subscription-based providers OpenWiki does have are `openai-chatgpt`
(browser OAuth against a ChatGPT plan) and `copilot` (an existing GitHub
Copilot plan), neither of which is Anthropic. No provider shells out to a
local CLI. Wrapping the claude CLI behind a local OpenAI-compatible bridge
would technically fit the `openai-compatible` provider, but routing a
Claude subscription through an unofficial API bridge is outside the
subscription's terms — not prepared here. (If a free wiki is the goal,
`graphify export wiki` above already produces one from the graph at zero
cost.)

Provider choice, in order of preference:
1. **OpenAI-compatible → cluster LiteLLM proxy** (cheapest; wiki synthesis is
   translation-grade work). Needs the tunnel: `kubectl port-forward -n ai
   svc/litellm-proxy 14000:4000`, then:
   ```
   OPENWIKI_PROVIDER=openai-compatible
   OPENAI_COMPATIBLE_BASE_URL=http://localhost:14000/v1
   OPENAI_COMPATIBLE_API_KEY=<LiteLLM key>
   OPENWIKI_MODEL_ID=<model id on the proxy>
   ```
2. **Anthropic API key** (real money, higher quality — owner approved spend
   2026-08-18): `OPENWIKI_PROVIDER=anthropic`, `ANTHROPIC_API_KEY=...`.
3. `openai-chatgpt` / `copilot` only if the owner happens to hold those
   subscriptions.

Scope is already prepared and committed:
- [.openwikiignore](../.openwikiignore) keeps `certs/` and `media/` out.
- [openwiki/INSTRUCTIONS.md](../openwiki/INSTRUCTIONS.md) tells the agent to
  document the machinery, link (not restate) the contract files, and name
  the file every claim comes from.

The wiki itself is plain Markdown under `openwiki/`, versioned with the code
like any other file. OpenWiki only rewrites its own
`<!-- OPENWIKI:START/END -->` blocks; INSTRUCTIONS.md is never touched.

### Using it

```bash
make wiki                      # openwiki --update (incremental, telemetry off)
openwiki visualize             # interactive graph + reader on :4321
openwiki visualize --export docs/wiki-site   # static HTML, hostable anywhere
```

### When the code changes

Manually, after machinery changes worth documenting (a new script, a changed
entry point, a new check): `make wiki`. It is incremental — unchanged pages
are not rewritten, so a no-op update costs little. Measure the first full
build with `scripts/usage_report.py` on the proxy side before deciding any
recurring cadence; the default cadence is "when someone cares".

CI self-update workflows exist upstream (GitHub Actions). Not enabled here:
unattended spend needs explicit owner approval first.

## 3. Real metrics, end to end

Every completion the pipeline makes — snapshot, catalog sync, authoring,
translation, video script, paths — writes one JSON line at the moment it
happens to `~/.local/state/teach-plat/usage.jsonl`, tagged with what it was
for (`op`, `cert`, `topic`, `lang`, `kind`), which backend and model ran it,
and what it measurably cost:

| Backend | What gets recorded |
|---|---|
| `claude` (CLI JSON envelope) | exact tokens in/out, cache read/write, cost USD, per-model split, effort |
| `litellm` | exact prompt/completion tokens from the API response, duration |
| `codex` / `gemini` / `custom` | duration and output size — token fields stay null, because the CLI reports none and **a null is honest; a guess is not** |

Quota-window events (exhausted/available, and which *kind* of limit — a
session window refills in hours, a weekly/monthly ceiling does not) land in
`quota-history.jsonl`; `teach/core/quota_facts.py` derives window facts from
the two files and returns None below three observed windows.

### Reading the numbers

```bash
make metrics                          # the whole picture, free
scripts/metrics_report.py --since 2026-08-01
scripts/metrics_report.py --json      # machine-readable
scripts/usage_report.py --by topic    # per model / cert / topic / op drill-down
scripts/window_budget.py              # can I generate right now?
scripts/topic_cost.py --forecast N    # what will N topics cost, from history
```

`make metrics` answers, from records alone:
- **per stage**: calls, distinct units touched, tokens in/out, cost — for
  snapshot → author → translate → video-script (plus catalog-sync, paths,
  and an explicit `(untagged)` row: untagged spend is a finding, not noise);
- **per backend**: where completions actually ran;
- **per day**: tokens, cost, *and how many session windows were exhausted
  that day* (a day with tokens and 0 windows fit inside one);
- **per window**: median output tokens a window holds on this machine
  (measured; 48 windows on record as of 2026-08-18).

Dollar figures are API-equivalent prices; on the subscription the real
budget is windows. That is why the daily table counts windows, not dollars.

`MODELS.md` answers "which model delivers better material" the same way:
generated by `scripts/model_comparison.py --write`, refreshed together with
STATUS.md, per-cert tables only (cross-cert comparison confounds model with
subject). Deterministic — same tree, same bytes; an LLM wiki could never be
the vehicle for a table of record, which is why this is code, not OpenWiki.

`STATUS.md` carries the same numbers as a **Spend (measured)** footer,
regenerated on every refresh (`make cert`, `make publish`, `teach status`).
The footer sits below a marker that `status_matrix.py --check` deliberately
ignores: spend moves without content moving (a rejected completion bills
and lands nothing), and the gate must only fail when the content ledger
lies, never because money was spent.

### What changed on 2026-08-18 (blind spots closed)

- Snapshot/catalog/paths completions were recorded **untagged** (no `op`) —
  now tagged at the call site in `tracker.py`.
- `litellm` completions were **not recorded at all** — the token counts in
  the API response were dropped; now they are written like every other row.
- Plain-text CLI backends (codex/gemini) recorded nothing — now they record
  duration and output size, with token fields null rather than invented.
- `usage.jsonl` rows now carry an explicit `backend` field (rows older than
  this date without one are all `claude` — the only recording path that
  existed).
