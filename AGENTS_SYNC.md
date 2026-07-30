# Agent Synchronization & Idea Queue (AGENTS_SYNC.md)

This file serves as an asynchronous idea queue and coordination buffer between AI agents (e.g. Antigravity, Claude) working on the `teach-plat` codebase.

## Workflow Rules for Agents

1. **Check Queue**: Any AI agent starting a work session or evaluating next steps MUST inspect this file.
2. **Evaluate & Act**: Read pending proposals, evaluate their technical feasibility and alignment with [PLAN.md](PLAN.md) and [WORKFLOW.md](WORKFLOW.md), and implement or integrate approved items.
3. **Clean Up**: Once an idea has been evaluated and implemented (or integrated into `BACKLOG.md`/`PLAN.md`), remove it from this file so the queue remains clean for future proposals.

---

## Pending Proposals & Ideas

### 1. Direct Content Translation Command (`teach cert translate`)
- **Context**: Currently, `teach cert generate --lang en` regenerates content from scratch using syllabus metadata rather than translating existing Spanish content.
- **Proposal**: Add a `teach cert translate <cert_id> [--topic <id>] [--from es] [--to <lang>]` CLI command in `teach/core/generator.py` and `teach/cli.py`.
- **Value**: Translating existing `es/content.md` and `es/exercises.md` directly via LLM prompt ensures strict structural parity across languages, reduces prompt token overhead, and drastically lowers generation cost per non-default language.

### 2. Auto-Discovery of Targets in Audit Scripts (`scripts/fix_corrupted_content.py`)
- **Context**: `WORKFLOW.md` highlights that `fix_corrupted_content.py` historically suffered from blind spots because `TARGETS` was hardcoded.
- **Proposal**: Enhance `fix_corrupted_content.py` to auto-discover active `(cert, lang)` combinations by scanning `certs/` directories, while using `TARGETS` as an optional filter.
- **Value**: Prevents newly generated language sets from being silently skipped during corruption audits.

### 3. CNPE Certification Enablement (Cloud Native Platform Engineer)
- **Context**: `cnpe` is registered in `catalog.yaml` with official CNCF PDF sources, but `certs/cnpe.md` has `topics: []`.
- **Proposal**: Run `teach cert snapshot cnpe` to freeze the 2025-12-03 CNPE curriculum, verify that domain weights sum to 100%, and add `cnpe` to the active generation queue.
- **Value**: Unlocks CNPE as a full certification path in `teach-plat`.
