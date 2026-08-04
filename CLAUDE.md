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

## Rules

- **English is the base language of the repository.** **ALL** code, scripts, comments, docstrings, variable and function names, log and error messages, CLI help text, documentation, BACKLOG, PLAN, CHANGELOG, STATUS, and commit messages MUST be written in English. This applies to new files and to any file you touch. The single exception is study content generated for the student, under `certs/<cert>/<topic>/<lang>/`, which is written in that topic's language.
- **Code Style**: Python 3.12, FastAPI backend, Vanilla CSS/JS single-page app frontend.
- **Idempotency**: All CLI actions (snapshotting, generation, translation) must be idempotent. If interrupted, running the command again must safely skip already generated work.
- **Copyright Guard**: Never persist scraped official syllabus text directly. Scraped texts are to be processed in-memory by the LLM and outputted as custom original summaries with correct source attributions.
- **Backends are interchangeable**: all satisfy `complete(system, user) -> str`, so a cert can be started with one and finished with another (`litellm` | `claude` | `codex` | `gemini` | `custom`). CLI-agent backends other than `claude` are invoked without tool-restriction flags and can return process recaps instead of content; `_reject_if_recap` fails loudly rather than saving a stub.
- **Authoring is ALWAYS `--backend claude`.** That is the owner's subscription: it costs no money, it costs a ~4.2 h quota window. Never move authoring to a paid API to go faster — the quality of authored material tracks model strength directly and cannot be checked mechanically. The only resource question worth asking is how to spend fewer *windows*, not fewer dollars.
- **Translation is the one place a cheaper model is even considered**, because there the substance is fixed by the source and every failure mode is mechanically detectable (`_verify_translation`). Measured in [docs/TRANSLATION_STUDY.md](docs/TRANSLATION_STUDY.md): the whole remaining translation workload costs about **$0.07** on OpenRouter and saves roughly **half the calendar time**, because those windows go to authoring instead. If that trade ever stops being worth it, fall back to `--backend claude` for translation too — never the reverse.

## Agent Idea Synchronization (AGENTS_SYNC.md)

- **Idea Exchange Buffer**: [AGENTS_SYNC.md](AGENTS_SYNC.md) is an asynchronous proposal queue for AI agents (Antigravity, Claude, etc.) working on this repository.
- **Mandatory Agent Check**: All AI agents MUST inspect [AGENTS_SYNC.md](AGENTS_SYNC.md) during context initialization or task evaluation. Read pending ideas, evaluate them technically, implement or transfer accepted items to [BACKLOG.md](BACKLOG.md) / [PLAN.md](PLAN.md), and delete processed entries from [AGENTS_SYNC.md](AGENTS_SYNC.md) so the queue remains clean for future proposals.

