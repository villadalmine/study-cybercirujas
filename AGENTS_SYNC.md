# Agent Synchronization & Idea Queue (AGENTS_SYNC.md)

This file serves as an asynchronous idea queue and coordination buffer between AI agents (e.g. Antigravity, Claude) working on the `teach-plat` codebase.

## Workflow Rules for Agents

1. **Check Queue**: Any AI agent starting a work session or evaluating next steps MUST inspect this file.
2. **Evaluate & Act**: Read pending proposals, evaluate their technical feasibility and alignment with [PLAN.md](PLAN.md) and [WORKFLOW.md](WORKFLOW.md), and implement or integrate approved items.
3. **Clean Up**: Once an idea has been evaluated and implemented (or integrated into `BACKLOG.md`/`PLAN.md`), remove it from this file so the queue remains clean for future proposals.

When rejecting or amending a proposal, record the reasoning in the destination document rather than leaving the entry here — this queue is for undecided items only.

---

## Pending Proposals & Ideas

*(empty)*

---


## Processed

**2026-07-30** — three proposals evaluated and moved out of the queue.

1. **`teach cert translate`** — Accepted. The premise is confirmed by code: `generate_topic()` builds its prompt from syllabus metadata and never reads the existing content, so `--lang en` authors from scratch rather than translating. Recorded under "Real translation" in BACKLOG.md with the trade-offs — much cheaper and viable on a small model, keeps languages structurally in sync, but every language inherits the Spanish structure, and a weak model translating dense technical prose can mangle command output in a way the current audit cannot catch, since the result is neither a stub nor a short file. Keep it as a separate `--from es` flag so authoring and translating both stay available.

2. **Auto-discovery of audit targets** — Accepted in intent, **rejected in mechanism**. The proposal was to discover `(cert, lang)` pairs by scanning the `certs/` directories. That reintroduces the exact bug it aims to prevent: disk scanning only sees languages that already exist, so a translation never started has no directory and stays invisible — which is precisely how the audit reported "0 corrupt" for `cks/en` while 20 of 26 topics did not exist (fixed in `e8201d7`). Discovery has to come from **declared intent**, not from disk. Implemented as `pipeline.yaml` + `teach/core/pipeline.py`, with `fix_corrupted_content.py` and `resume-generation.sh` both reading from it, and the audit enumerating topics from the syllabus frontmatter so it reports what is missing rather than only what is damaged.

4. **Interactive RAG tutor with anonymous session tracking** — Accepted, merged into the existing RAG bot section of BACKLOG.md rather than tracked separately: it is the same feature as the `chart/` proposal audited on 2026-07-28, and splitting it across two entries would fork the design. One part of it is a genuine improvement and supersedes the earlier design: `X-Session-ID` from `localStorage` instead of `user_profiles` rows removes the auth dependency that blocked personalization, without contradicting the free/no-login stance. Four caveats recorded in BACKLOG.md — the deployment has **no persistent storage whatsoever** (no volumes, no PVC in `deploy/helm/`, content baked into the image), so a local SQLite/JSON session store would be erased on every publish and break above one replica; quiz generation should be pre-computed per topic at build time and baked in like content, since per-request LLM calls make cost scale with public traffic on a project that has hit its monthly spend limit twice in three days; the graph half of "hybrid graph-vector" adds machinery that a metadata filter over `(cert, topic, lang)` already provides for 274 topics; and `X-Session-ID` is client-supplied, so it is forgeable by design and must never become a de facto auth token.

3. **CNPE enablement** — Accepted, deferred. Claims verified: `cnpe` is in `catalog.yaml` with the official CNCF PDF (tracked version 2025-12-03, CC-BY 4.0) and `certs/cnpe.md` has `topics: []`, so `teach cert snapshot cnpe` is the whole first step. Not started because 31 declared topics are already outstanding (`cks/en` 18, `kcna/en` 13) and a new certification would add roughly 26 more ahead of them, against a real API budget constraint. Queued in BACKLOG.md — snapshot it when the queue is shorter, then set `active: true` in `pipeline.yaml`.
