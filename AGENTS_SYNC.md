# Agent Synchronization & Idea Queue (AGENTS_SYNC.md)

This file serves as an asynchronous idea queue and coordination buffer between AI agents (e.g. Antigravity, Claude) working on the `teach-plat` codebase.

## Workflow Rules for Agents

1. **Check Queue**: Any AI agent starting a work session or evaluating next steps MUST inspect this file.
2. **Evaluate & Act**: Read pending proposals, evaluate their technical feasibility and alignment with [PLAN.md](PLAN.md) and [WORKFLOW.md](WORKFLOW.md), and implement or integrate approved items.
3. **Clean Up**: Once an idea has been evaluated and implemented (or integrated into `BACKLOG.md`/`PLAN.md`), remove it from this file so the queue remains clean for future proposals.

When rejecting or amending a proposal, record the reasoning in the destination document rather than leaving the entry here — this queue is for undecided items only.

---

## Pending Proposals & Ideas

### 4. Interactive RAG Tutor & Anonymous Lab Tracking (`/api/tutor/...`)
- **Context**: The user wants an interactive AI bot/tutor system for online students that operates without user login/auth (using browser session storage + `X-Session-ID`), allows selecting course preferences, indexes course content (via Vector / Hybrid Graph-Vector RAG), asks interactive questions based on real course material, evaluates answers with feedback, and tracks completed labs to provide personalized recommendations (what the user did well vs needs to review).
- **Architecture Proposal**:
  1. **Hybrid Graph-Vector RAG**: Index `certs/*/*/content.md` and `exercises.md` chunks into a lightweight vector index (or in-memory embeddings), filtered by graph node `(cert_id, topic_id)`.
  2. **No-Auth Session**: Browser generates `UUIDv4` stored in `localStorage`, sent as `X-Session-ID` header. Session state (selected cert, lab attempts, quiz history) saved in lightweight backend storage (SQLite/JSON).
  3. **API-Oriented Tutor Endpoints** (`teach/api.py` & `teach/core/tutor.py`):
     - `POST /api/tutor/quiz/generate`: Generates grounded quiz questions from target topic RAG chunks.
     - `POST /api/tutor/quiz/evaluate`: Evaluates student answers against material and returns feedback.
     - `POST /api/tutor/ask`: Answers student questions with strict RAG grounding and citations to topics.
     - `GET /api/tutor/recommendations`: Recommends topics/labs based on session quiz scores and lab break-fix performance.

---


## Processed

**2026-07-30** — three proposals evaluated and moved out of the queue.

1. **`teach cert translate`** — Accepted. The premise is confirmed by code: `generate_topic()` builds its prompt from syllabus metadata and never reads the existing content, so `--lang en` authors from scratch rather than translating. Recorded under "Real translation" in BACKLOG.md with the trade-offs — much cheaper and viable on a small model, keeps languages structurally in sync, but every language inherits the Spanish structure, and a weak model translating dense technical prose can mangle command output in a way the current audit cannot catch, since the result is neither a stub nor a short file. Keep it as a separate `--from es` flag so authoring and translating both stay available.

2. **Auto-discovery of audit targets** — Accepted in intent, **rejected in mechanism**. The proposal was to discover `(cert, lang)` pairs by scanning the `certs/` directories. That reintroduces the exact bug it aims to prevent: disk scanning only sees languages that already exist, so a translation never started has no directory and stays invisible — which is precisely how the audit reported "0 corrupt" for `cks/en` while 20 of 26 topics did not exist (fixed in `e8201d7`). Discovery has to come from **declared intent**, not from disk. Implemented as `pipeline.yaml` + `teach/core/pipeline.py`, with `fix_corrupted_content.py` and `resume-generation.sh` both reading from it, and the audit enumerating topics from the syllabus frontmatter so it reports what is missing rather than only what is damaged.

3. **CNPE enablement** — Accepted, deferred. Claims verified: `cnpe` is in `catalog.yaml` with the official CNCF PDF (tracked version 2025-12-03, CC-BY 4.0) and `certs/cnpe.md` has `topics: []`, so `teach cert snapshot cnpe` is the whole first step. Not started because 31 declared topics are already outstanding (`cks/en` 18, `kcna/en` 13) and a new certification would add roughly 26 more ahead of them, against a real API budget constraint. Queued in BACKLOG.md — snapshot it when the queue is shorter, then set `active: true` in `pipeline.yaml`.
