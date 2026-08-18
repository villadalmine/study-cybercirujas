# Development Guidelines for teach-plat

## Commands

- **Install Dependencies**: `make install`
- **Start Web Application/API**: `make serve`
- **List Certifications**: `make list`
- **Show Certification Details**: `make show CERT=<cert_id>` (e.g. `make show CERT=lpi-010-160`)
- **Generate Content for Certification**: `make generate CERT=<cert_id> [TOPIC=<topic_id>] [BACKEND=<backend_id>] [LANG=<lang_id>]` (e.g. `make generate CERT=lpi-010-160 TOPIC=1.1 BACKEND=claude`)
- **Build Docker Image**: `make image-cluster TAG=<tag>`
- **Deploy to Kubernetes**: `make deploy-local TAG=<tag>`
- **Run Status Matrix Script**: `.venv/bin/python3 scripts/status_matrix.py`
- **Run Corruption Fix Script**: `.venv/bin/python3 scripts/fix_corrupted_content.py`
- **Model Comparison Dashboard**: [MODELS.md](MODELS.md) — generated, regenerates with STATUS.md; per-cert tables are the only fair model comparisons
- **Rebuild Code Graph**: `make graph` (tree-sitter AST — free, no LLM; auto-refreshed by the post-commit hook)
- **Spend Metrics**: `make metrics` (per stage / day / quota window, from records)
- **Update Wiki**: `make wiki` (OpenWiki — COSTS API credits, manual only)

## Content Workflow

Full process in [WORKFLOW.md](WORKFLOW.md) — read it before generating, translating or publishing content. The essentials:

- **English is the authoring language; every other language is a translation.** Since 2026-08-04 everything is written in English first — content, exercises, labs, video scripts, validation — then translated to Spanish, and the rest (`pt fr de zh ja`) only on demand. `certs.DEFAULT_LANG` is `en`; `certs.FALLBACK_LANGS` is the chain `[en, es]`, because Spanish is still the complete corpus for certifications whose English is unfinished. Material authored before that date has independently written Spanish and English — those are siblings, not translations, which is why they drifted in size.
- **`--lang <x>` does not translate.** It regenerates the topic from scratch in that language, from syllabus metadata only; it never reads existing content. Use it ONLY for the authoring language. For every other language use `teach cert translate`, which reuses the source and verifies structure — see [docs/TRANSLATION_STUDY.md](docs/TRANSLATION_STUDY.md).
- **The loop is** snapshot → generate → audit → status → commit → publish. Never skip the audit and status steps.
- **Generate in small batches** (2–3 topics per launch), not whole certifications. API credits are a real constraint. Generation is idempotent per language, so stopping early costs nothing and resuming needs no flags.
- **Publish only a complete certification.** Commit partial progress freely, but run `make image-cluster` / `make deploy-local` only when a cert is finished in that language — and pass the SAME explicit `TAG=` to both, since `TAG` defaults to a fresh timestamp per invocation. Never deploy unprompted.
- **Audits only see what is in their `TARGETS` list.** Add the cert/language pair to `scripts/fix_corrupted_content.py` (and `scripts/resume-generation.sh`) in the same commit that generates it. "0 corrupt" proves only that the scanned combos are clean — this has caused three separate blind spots.
- **Verify counts independently**, per file and per language, not just topic status. Never pipe a generation run through `tee`: the pipeline exit status hides failures as exit 0.
- **`teach-resume.timer` is deliberately disabled.** It spends API quota autonomously; do not enable it without explicit approval.

## Verification: what is proven, and what is only assumed

Everything here is code, generated and re-runnable. Nothing is asserted from
memory. The checks form a ladder, and it matters which rung a claim rests on —
"the sources exist" and "the sources say this" are different statements.

| Question | Tool | Cost |
|---|---|---|
| Is it a stub, or missing required structure? | quality floor, **before writing** | free |
| Does the cited URL resolve? | `scripts/check_citations.py` | free |
| Is the citation an official project source, and whose? | `scripts/check_sources.py` + [docs/sources.yaml](docs/sources.yaml) | free |
| Does the embedded YAML parse? | `scripts/check_manifests.py` | free |
| Does it teach a removed Kubernetes API? | `scripts/check_k8s_apis.py` | free |
| Is it traceable, accounted for, in order? | `scripts/check_provenance.py` | free |
| Does the cited page **say** what the material claims? | `scripts/check_claims.py` | one completion per citation — sample |
| Is the explanation **true**? | nothing yet — see [docs/AUDITOR_DESIGN.md](docs/AUDITOR_DESIGN.md) | — |

That last row is the honest gap. A confident wrong explanation passes every other
line. Found in practice on 2026-08-06: fresh content cited a kubernetes.io page
for the 4Cs model that no longer contains it — the URL resolves, every free check
passes, and a student following the link finds nothing.

**[docs/sources.yaml](docs/sources.yaml) is the extension point.** Every topic
rests on some project's official documentation, and adding a project is one entry:
domains, docs root, whether it is versioned, and a machine-readable `spec` when
the project publishes one. 52 projects catalogued, 85% of citations attributed.

**Spend is measured, not estimated.** Every completion — snapshot, authoring,
translation, video, through ANY backend — records what it was for, model, tokens
and cost to `usage.jsonl` at the moment it happens (`claude` and `litellm` with
exact counts; plain-text CLIs with duration/size and honest nulls).
`scripts/metrics_report.py` (`make metrics`) reports it per stage, per day and
per quota window; `scripts/usage_report.py` drills down per model/topic; and
`scripts/window_budget.py` reports the weekly ceiling separately from the ~5 h
session window, because they mean opposite things. On a subscription the dollar
figures are the API-equivalent price, not the bill — the finite resource is the
window.

**The machinery has a queryable map.** `graphify-out/graph.json` (+
`GRAPH_REPORT.md`) is a tree-sitter code graph of `teach/`, `scripts/` and
`tests/` — free to build, refreshed by the post-commit hook, staleness checked
by `scripts/check_graph.py` in `make verify`, served to agents over MCP via
`.mcp.json`. **Query it before grepping**: `.venv/bin/graphify query "..."` /
`explain` / `path`. Full developer guide, including OpenWiki (the wiki costs
credits; the graph never does): [docs/DEVTOOLS.md](docs/DEVTOOLS.md).

## Rules

- **English is the base language of the repository.** **ALL** code, scripts, comments, docstrings, variable and function names, log and error messages, CLI help text, documentation, BACKLOG, PLAN, CHANGELOG, STATUS, and commit messages MUST be written in English. This applies to new files and to any file you touch. The single exception is study content generated for the student, under `certs/<cert>/<topic>/<lang>/`, which is written in that topic's language.
- **Code Style**: Python 3.12, FastAPI backend, Vanilla CSS/JS single-page app frontend.
- **Idempotency**: All CLI actions (snapshotting, generation, translation) must be idempotent. If interrupted, running the command again must safely skip already generated work.
- **Copyright Guard**: Never persist scraped official syllabus text directly. Scraped texts are to be processed in-memory by the LLM and outputted as custom original summaries with correct source attributions.
- **Backends are interchangeable**: all satisfy `complete(system, user) -> str`, so a cert can be started with one and finished with another (`litellm` | `claude` | `codex` | `gemini` | `custom`). CLI-agent backends other than `claude` are invoked without tool-restriction flags and can return process recaps instead of content; `_reject_if_recap` fails loudly rather than saving a stub.
- **Any backend may author; none may author untraceably.** `claude` is the owner's subscription (no money, one ~4.2 h quota window) and is the default choice, but another cloud provider is fine. What is NOT fine is content whose origin is unknown: every `<topic>/<lang>/` must carry a `meta.yaml` with `backend`, `model` and `generated_at`, or it cannot be reproduced, compared or rolled back. `scripts/check_provenance.py` enforces this and exits non-zero.
- **The order is fixed: content → verify → video, and topic by topic.** A video narrates material that must already exist and have passed the floor; rendering one over a half-written certification tells the student the material is there when it is not. Same reason the authoring language is finished before translating: a translation of missing content cannot exist.
- **Translation is the one place a cheaper model is even considered**, because there the substance is fixed by the source and every failure mode is mechanically detectable (`_verify_translation`). Measured in [docs/TRANSLATION_STUDY.md](docs/TRANSLATION_STUDY.md): the whole remaining translation workload costs about **$0.07** on OpenRouter and saves roughly **half the calendar time**, because those windows go to authoring instead. If that trade ever stops being worth it, fall back to `--backend claude` for translation too — never the reverse.

## Agent Idea Synchronization (AGENTS_SYNC.md)

- **Idea Exchange Buffer**: [AGENTS_SYNC.md](AGENTS_SYNC.md) is an asynchronous proposal queue for AI agents (Antigravity, Claude, etc.) working on this repository.
- **Mandatory Agent Check**: All AI agents MUST inspect [AGENTS_SYNC.md](AGENTS_SYNC.md) during context initialization or task evaluation. Read pending ideas, evaluate them technically, implement or transfer accepted items to [BACKLOG.md](BACKLOG.md) / [PLAN.md](PLAN.md), and delete processed entries from [AGENTS_SYNC.md](AGENTS_SYNC.md) so the queue remains clean for future proposals.

