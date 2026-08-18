# OpenWiki scope for teach-plat

Owner-authored. OpenWiki reads this before writing; it sets what the wiki is
for and what it must leave alone.

## What to document

The **machinery**, for a developer or agent who needs to understand how the
pipeline works before touching it:

- `teach/` — the package: generation (`core/generator.py`), pipeline config
  (`core/pipeline.py` + `pipeline.yaml`), quality floor (`core/quality.py`),
  per-topic claims (`core/claims.py`), quota facts (`core/quota_facts.py`),
  syllabus tracking (`core/tracker.py`), video (`core/video.py`), API + CLI.
- `scripts/` — entry points and checks; especially `run_cert.py` (the ONE
  entry point), `run_batch.py`, and the `check_*.py` family (what each check
  proves, and what it deliberately cannot).
- The workflow: snapshot → generate → audit → status → commit → publish, and
  why the order is fixed (content → verify → video; author in English, then
  translate).
- Deployment: `deploy/`, `make image-cluster` / `make deploy-local`.
- Measurement: `usage.jsonl`, `quota-history.jsonl`, `scripts/usage_report.py`,
  `scripts/window_budget.py`, `scripts/metrics_report.py`.

## What NOT to document

- `certs/` and `media/` — generated product, already excluded by
  `.openwikiignore`. STATUS.md is their ledger; do not duplicate it.
- Credentials, `.env*`, anything under `deploy/*.env*`.
- Do not restate or paraphrase the contract files (CLAUDE.md, AGENTS_SYNC.md,
  WORKFLOW.md) as if the wiki were their source of truth — link to them. The
  wiki describes; those files govern.

## Style

- English only, like everything else in this repository.
- Prefer Mermaid diagrams for the pipeline stages, the backend abstraction,
  and the check ladder.
- Every claim about behavior should name the file (and function) it comes
  from, so a reader can verify instead of trusting.
