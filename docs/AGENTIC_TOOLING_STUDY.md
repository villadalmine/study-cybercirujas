# Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)

Date: 2026-08-18. Question from the owner: can
[Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify) and
[langchain-ai/openwiki](https://github.com/langchain-ai/openwiki) make this
repository more agent-friendly and more automatic — graph query/explain/update
for navigation, a self-maintaining wiki for documentation, LangSmith for
visualizing runs?

**Verdict up front:** Graphify is free, local, deterministic and already
proven on this repo (pilot below) — adopt it first. OpenWiki works and fits,
but every run spends real completions, so it enters through the same door as
everything else here: a scoped, measured pilot before any automation.
LangSmith is optional and only instruments the `litellm` path; lowest
priority.

---

## 1. Graphify — measured pilot, 2026-08-18

Installed `graphifyy` 0.9.46 in an isolated venv and ran the AST-only build
(`graphify update .`) with `certs/`, `media/` and scratch files excluded via
`.graphifyignore`.

| Fact | Value |
|---|---|
| Build input | 69 files, ~92k words (machinery only, corpus excluded) |
| Graph | 826 nodes · 1,422 edges · 45 communities |
| Token cost | **0 input, 0 output** — tree-sitter AST, no LLM, fully local |
| Build time | seconds; idempotent; `update` re-extracts only changed files |
| Outputs | `graphify-out/graph.json` (802 KB), `graph.html` (694 KB, interactive), `GRAPH_REPORT.md` (15 KB) |
| Freshness | report records the source commit (`43ef4741`) — staleness is mechanically checkable |

Query quality, tested live: `graphify query "what enforces the budget during
generation?"` returned `budget()` at `teach/core/pipeline.py:55` plus the
call chain through `run_batch.py`, `generator.py`, `cli.py` — a correct,
scoped subgraph instead of a grep session. `explain` disambiguates
(e.g. "quality floor" → `teach/core/quality.py` vs its test) and `path A B`
traces connections.

Why this fits teach-plat: the extraction is deterministic and free, so it
obeys the house rule that checks must cost nothing to run. Every edge is
tagged `EXTRACTED` vs `INFERRED` (this build: 100% extracted), which matches
the provenance culture. Nothing leaves the machine.

### What Graphify gives agents

1. **MCP server** — `python -m graphify.serve graphify-out/graph.json`
   (stdio; HTTP mode exists for shared access). Tools: `query_graph`,
   `get_node`, `get_neighbors`, `shortest_path`. Registered in `.mcp.json`,
   every Claude Code / Cursor / Gemini session can ask the graph instead of
   fanning out file searches — cheaper context, faster orientation.
2. **`update` on every commit, for free.** AST-only rebuild costs no API
   call, so the graph can track HEAD automatically.
3. **Team/agent sharing** — commit `graphify-out/graph.json` +
   `GRAPH_REPORT.md`; other agents (Antigravity) read the same map without
   rebuilding. A merge driver union-merges parallel graph commits.

### Integration cautions (this repo specifically)

- **Do not run `graphify hook install`.** This repo pins
  `core.hooksPath=.githooks` and the pre-commit hook there enforces the four
  fixed rules. Instead, add one line to a **post-commit** hook in `.githooks/`
  that runs `graphify update . --no-viz` — same effect, no collision, and the
  contract hook stays untouched.
- **Do not run `graphify claude install`.** It appends nudges to `CLAUDE.md`
  / writes `AGENTS.md`; both are hand-authored contracts here. Write the
  two-line pointer ourselves.
- **`.graphifyignore` is load-bearing.** `certs/` (63 MB) and `media/`
  (104 MB) are outputs, not architecture. Already in place.
- The pilot venv lives in the session scratchpad; adoption needs `graphifyy`
  installed somewhere durable (repo `.venv` via a dev extra, or `uv tool
  install` once `uv` exists on the machine).

### Optional, costs completions (cheap, LiteLLM-able)

- `graphify label` — LLM names for the 45 communities (one batched call).
- Semantic enrichment of `docs/*.md`, `WORKFLOW.md`, `pipeline.yaml`
  commentary into the graph (`--backend openai` + `OPENAI_BASE_URL` pointed
  at the LiteLLM proxy — same route as translation, fractions of a cent).
- `--wiki` / `export callflow-html` — Markdown wiki and Mermaid architecture
  diagrams derived from the graph.

## 2. OpenWiki — studied, not yet run (every run spends)

What it is: an npm CLI (`openwiki`) built on LangChain's Deep Agents. An
agent reads the sources and writes an interlinked Markdown wiki under
`openwiki/` in the repo — YAML front matter, validated Mermaid diagrams,
an index — then `--update` keeps it current incrementally. `openwiki
visualize` serves an interactive node graph + Markdown reader (port 4321)
and can export static HTML. It only rewrites its own
`<!-- OPENWIKI:START/END -->` blocks and honors a user-authored
`openwiki/INSTRUCTIONS.md` for scope.

Why it is interesting here: the repo's real documentation surface
(WORKFLOW.md, AGENTS_SYNC.md, CHANGELOG.md, pipeline.yaml comments) is rich
but hand-maintained and drift-prone; an agent-maintained wiki that re-reads
`teach/` and `scripts/` on change would give every future agent a current
map, and the visualizer gives the owner the "see the whole system" view.

Constraints that shape adoption:

- **It cannot spend the Claude subscription window.** Supported providers are
  API-key based (OpenAI, Anthropic API, Gemini, OpenRouter, **any
  OpenAI-compatible endpoint** — i.e. the cluster LiteLLM proxy). There is no
  claude-CLI/subscription route. So OpenWiki costs real (small) money, not
  windows — which is actually the right direction: like translation, wiki
  synthesis is source-grounded work where a cheaper model is acceptable, and
  the quota windows stay reserved for authoring.
- **Scope must exclude the corpus.** `.openwikiignore` with `certs/`,
  `media/`, plus `INSTRUCTIONS.md` limiting the wiki to the machinery
  (`teach/`, `scripts/`, `tests/`, top-level docs, `pipeline.yaml`).
- **Cost is unmeasured until piloted.** House rule: measure, don't estimate.
  First run = `openwiki --init` against the scoped tree through the LiteLLM
  proxy, with the spend read from the proxy afterwards. Only then decide
  about recurring updates.
- **CI self-update exists** (generated GitHub Actions workflow) but
  unattended spend is exactly what `teach-resume.timer` is disabled for.
  Same policy: manual/`make`-target updates until the owner explicitly
  approves an automated schedule with a capped key.
- Disable telemetry: `OPENWIKI_TELEMETRY_DISABLED=1`.

## 3. LangSmith — optional visibility, narrow fit

OpenWiki has a LangSmith connector that pulls recent traces (tool calls,
outcomes, latency) into the wiki, and LangSmith itself gives a trace UI.
But teach-plat's generation is not LangChain: the `claude` backend shells
out to a CLI (not traceable this way), and only `_litellm_completer()` uses
the OpenAI SDK, which LangSmith can wrap without LangChain
(`langsmith.wrappers.wrap_openai`, `LANGSMITH_TRACING=1`, free tier).

So the honest scope is: **translation-call tracing only**, visualized in
LangSmith and optionally surfaced in the wiki. Useful for debugging
translation failures (timeouts, truncations already seen with `gemma4-paid`
and the 60 s ReadTimeout), irrelevant to the authoring path. Do it last, if
at all. Spend/usage visibility already exists in `usage.jsonl` +
`scripts/usage_report.py` and stays the source of truth.

## 4. The plan

Ordered so that everything free lands before anything that spends, and
nothing spends unattended. Steps 1–3 change process files, so they go
through the normal loop (proposed, tested end-to-end, then adopted).

**Phase 1 — free, deterministic — DONE 2026-08-18** (see
[DEVTOOLS.md](DEVTOOLS.md) for the developer guide; metrics instrumentation
landed the same day: snapshot/litellm/plain-CLI completions now recorded,
`make metrics` reports per stage/day/window)
1. Add `graphifyy` as a dev dependency; keep `.graphifyignore` (done, this
   study).
2. Commit `graphify-out/graph.json` + `GRAPH_REPORT.md` (git-ignore
   `graphify-out/cache/` and `cost.json`; `graph.html` is regenerable —
   commit only if the owner wants it browsable from the repo).
3. `.mcp.json` registering the stdio MCP server → every agent session gets
   `query_graph`/`get_node`/`get_neighbors`/`shortest_path`.
4. Post-commit line in `.githooks/` (NOT `graphify hook install`):
   `graphify update . --no-viz` — graph tracks HEAD at zero cost.
5. Two-line pointer in CLAUDE.md: "query the graph before grepping;
   `GRAPH_REPORT.md` is the map."
6. Optional free check in `make verify`: compare the commit recorded in
   `GRAPH_REPORT.md` with `git rev-parse HEAD`, warn on stale.

**Phase 2 — cents, via LiteLLM proxy**
7. `graphify label` (community names) and semantic enrichment of the docs
   into the graph. Measure via the proxy, record in the usual place.

**Phase 3 — OpenWiki pilot, measured**
8. `npm install -g openwiki`; `--init` scoped by `INSTRUCTIONS.md` +
   `.openwikiignore` (machinery only), provider = OpenAI-compatible →
   LiteLLM proxy, telemetry off. Measure the full cost of the first build.
9. If the number is acceptable: `make wiki` target running
   `openwiki --update` manually after machinery changes (same trigger
   discipline as `status_matrix.py`). `openwiki visualize --export` for a
   static browsable copy.
10. Only with explicit owner approval: scheduled CI self-update with a
    capped key. Default is no.

**Phase 4 — optional**
11. `wrap_openai` in `_litellm_completer()` behind `LANGSMITH_TRACING`;
    OpenWiki LangSmith connector if 8–9 landed. Skip entirely if unused.

## 5. Costs, summarized

| Action | Cost | Recurrence |
|---|---|---|
| Graphify build/update (AST) | $0, 0 tokens | every commit, free |
| Graphify MCP server | $0 (local process) | always-on per session |
| Community labels / doc enrichment | cents via LiteLLM | rare |
| OpenWiki first build (scoped) | **unmeasured — pilot before deciding** | once |
| OpenWiki `--update` | fraction of build (incremental) | manual, per machinery change |
| LangSmith | free tier | passive |

## 6. Where the value actually is (owner's question, 2026-08-18)

The owner asked what this buys: cheaper agent sessions, developer
understanding, or something else — and confirmed that spending subscription
credits on it is acceptable. The honest ranking, most valuable first:

**1. Fewer wasted runs — the big one, and it is not token arithmetic.**
Every expensive failure in this repo's history was an orientation failure:
two agents implementing the same fix (2026-08-06), two agents spending quota
windows on the same certification (KCSA), an orchestrator rewritten because
the lock's purpose was invisible, `--lang` used where `translate` was meant.
One wasted authoring run costs $2.10–5.28 and 80–197k tokens — half a quota
window. A committed, always-current graph that both Claude and Antigravity
query is shared situational awareness; it attacks the failure class
directly. Avoiding one duplicated run per month pays for everything else in
this study combined.

**2. Cheaper session orientation — measured.** The process docs an agent
reads to orient (CLAUDE.md + WORKFLOW.md + AGENTS_SYNC.md + STATUS.md +
PLAN.md + BACKLOG.md) total **126 KB ≈ ~32k tokens**, plus ~15k more for the
core sources (`generator.py`, `pipeline.py`, `cli.py`) — roughly **45–50k
input tokens per session before any work happens**, spent again every
session, plus the grep/read fan-out during the task. A graph query returns a
scoped ~2k-token subgraph with file:line anchors, and the MCP tools replace
most search fan-outs with one call. On a subscription, input spends the same
window that authoring needs; orientation savings convert directly into
authored topics.

**3. The developer's map.** `graph.html` shows the whole machinery on one
screen — 45 communities, hubs, cross-module edges — for "how does it all
work" without reading code. OpenWiki adds the prose layer: linked pages with
Mermaid diagrams, browsable via its visualizer, exportable as static HTML
(could ship with the platform as an architecture page). The two are
complementary: graph = structure, wiki = narrative.

**4. Value nobody asked for but comes free:**
- *Refactor signals*: the report ranks god nodes and surprising
  cross-module connections — a standing answer to "what is too coupled".
- *Docs that cannot lie silently*: a wiki regenerated from code, diffed
  against hand-written WORKFLOW.md, surfaces drift mechanically — the same
  class of failure as the syllabus that was secretly a table of contents.
- *Blast-radius before touching process code*: `path` / `get_pr_impact`
  show what a change reaches — cheap insurance given process changes here
  apply to every future topic.
- *Onboarding the next agent*: AGENTS_SYNC.md is 46 KB because orientation
  is expensive today; a queryable map makes adding a third backend/agent
  nearly free.
- *Optionally, mapping the corpus itself*: a per-cert semantic graph over
  `certs/` would make orphaned content visible (188 orphaned files after
  the re-snapshot) and expose cross-topic links. Costs completions; now
  that spend is approved, feasible per-cert.

**Spend note, corrected by the owner's decision:** subscription credits are
acceptable. That unlocks Graphify's LLM steps on the subscription itself —
it has a `--backend claude-cli` that uses the Claude CLI, no API key — so
community labeling and doc enrichment can run on a window. OpenWiki remains
API-key-only (no subscription route exists); its pilot needs the LiteLLM
proxy or a direct Anthropic API key, and the cost argument for the cheap
route still applies: wiki synthesis is translation-grade work.

## 7. Decisions that belong to the owner

1. Commit `graphify-out/` artifacts to git (graph.json + report ≈ 0.8 MB),
   or keep them local-only and rebuilt per clone? (Committing is what lets
   Antigravity read the same map.)
2. Is `graph.html` wanted in the repo / deployed alongside the platform, or
   is local-only fine?
3. Approve the OpenWiki pilot spend through the LiteLLM proxy (needs the
   `.env` credential mismatch from 2026-08-14 resolved first: it currently
   points OpenRouter-style config at a LiteLLM key).
4. Any appetite for scheduled wiki self-update later, or manual forever?
   (Recommendation: manual until boredom proves otherwise.)
