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

## Rules

- **Documentation Language**: **ALL documentation, BACKLOG, PLAN, CHANGELOG, STATUS, and comments/commit messages MUST be written in English.** Never write or generate documentation or code comments in Spanish or other languages, except for content translations intended for the student (under `certs/<cert>/<topic>/<lang>/`).
- **Code Style**: Python 3.12, FastAPI backend, Vanilla CSS/JS single-page app frontend.
- **Idempotency**: All CLI actions (snapshotting, generation, translation) must be idempotent. If interrupted, running the command again must safely skip already generated work.
- **Copyright Guard**: Never persist scraped official syllabus text directly. Scraped texts are to be processed in-memory by the LLM and outputted as custom original summaries with correct source attributions.
