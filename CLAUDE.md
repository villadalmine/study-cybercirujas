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

- **`--lang <x>` does not translate.** It regenerates the topic from scratch in that language, from syllabus metadata only; it never reads the existing Spanish content. So language versions are siblings rather than copies, cost is authoring cost (~7 min and 2 completions per topic), and a cheap model is the wrong tool for it. Real translation (feed existing content to a small model) is a separate, unimplemented feature.
- **The loop is** snapshot → generate → audit → status → commit → publish. Never skip the audit and status steps.
- **Generate in small batches** (2–3 topics per launch), not whole certifications. API credits are a real constraint. Generation is idempotent per language, so stopping early costs nothing and resuming needs no flags.
- **Publish only a complete certification.** Commit partial progress freely, but run `make image-cluster` / `make deploy-local` only when a cert is finished in that language — and pass the SAME explicit `TAG=` to both, since `TAG` defaults to a fresh timestamp per invocation. Never deploy unprompted.
- **Audits only see what is in their `TARGETS` list.** Add the cert/language pair to `scripts/fix_corrupted_content.py` (and `scripts/resume-generation.sh`) in the same commit that generates it. "0 corrupt" proves only that the scanned combos are clean — this has caused three separate blind spots.
- **Verify counts independently**, per file and per language, not just topic status. Never pipe a generation run through `tee`: the pipeline exit status hides failures as exit 0.
- **`teach-resume.timer` is deliberately disabled.** It spends API quota autonomously; do not enable it without explicit approval.

## Rules

- **Documentation Language**: **ALL documentation, BACKLOG, PLAN, CHANGELOG, STATUS, and comments/commit messages MUST be written in English.** Never write or generate documentation or code comments in Spanish or other languages, except for content translations intended for the student (under `certs/<cert>/<topic>/<lang>/`).
- **Code Style**: Python 3.12, FastAPI backend, Vanilla CSS/JS single-page app frontend.
- **Idempotency**: All CLI actions (snapshotting, generation, translation) must be idempotent. If interrupted, running the command again must safely skip already generated work.
- **Copyright Guard**: Never persist scraped official syllabus text directly. Scraped texts are to be processed in-memory by the LLM and outputted as custom original summaries with correct source attributions.
- **Backends are interchangeable**: all satisfy `complete(system, user) -> str`, so a cert can be started with one and finished with another (`litellm` | `claude` | `codex` | `gemini` | `custom`). CLI-agent backends other than `claude` are invoked without tool-restriction flags and can return process recaps instead of content; `_reject_if_recap` fails loudly rather than saving a stub.
