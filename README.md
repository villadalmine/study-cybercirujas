# teach-plat

Study platform for IT certifications. All content is generated from official
sources (syllabi scraped from lpi.org, PDFs from github.com/cncf/curriculum,
etc.) — nothing hardcoded.

- **[STATUS.md](STATUS.md)** — which cert/language/lab/video is finished
- **[PLAN.md](PLAN.md)** — full design
- **[BACKLOG.md](BACKLOG.md)** — what is pending
- **[CHANGELOG.md](CHANGELOG.md)** — what has been delivered

## Quickstart

```bash
make install                                   # venv + CLI
make list                                      # catalogue
make show CERT=lpi-010-160                     # syllabus + per-topic status
make generate CERT=lpi-010-160 TOPIC=1.1 BACKEND=claude
make serve                                     # API + web on :8000
```

`make help` lists every target.

## Public Docker image

Every push to `main` publishes the image to GitHub Container Registry:

```bash
docker pull ghcr.io/villadalmine/study-cybercirujas:latest
docker run -p 8000:8000 ghcr.io/villadalmine/study-cybercirujas:latest
```

Web: http://localhost:8000 · API docs: http://localhost:8000/docs

## Generation backends

`BACKEND=` (or `TEACH_BACKEND`):

- `litellm` (default) — any OpenAI-compatible API (LiteLLM, OpenRouter, etc.).
  Requires `LITELLM_BASE_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL`.
- `claude` — local Claude Code CLI (`claude -p`).
- `codex` — local OpenAI Codex CLI (`codex exec`).
- `gemini` — local Gemini CLI (`gemini -p`).
- `custom` — your command in `TEACH_AGENT_CMD` (receives the prompt as its last argument).

**Authoring always uses `claude`.** That backend is a subscription: it costs no
money, it costs a quota window. Authoring quality tracks model strength and
cannot be checked mechanically, so it never moves to a cheaper model. Translation
is the one place a cheaper model is measured and used — see
[docs/TRANSLATION_STUDY.md](docs/TRANSLATION_STUDY.md).

With local backends: generate on your machine → review → `make publish`.

## Languages

Content lives in `certs/<cert>/<topic>/<lang>/` (`en` is the authoring language;
`es`, `fr`, `de`, `zh`, `ja`, `pt` follow). The web has a language selector and
falls back along `en → es`.

**English is authored, everything else is translated:**

```bash
teach cert generate  <cert> --lang en --backend claude    # author (from the syllabus)
teach cert translate <cert> --to es --backend litellm     # translate (from English)
```

The distinction matters and is easy to get wrong: `generate --lang <x>` does
**not** translate. It rewrites the topic from scratch in that language from
syllabus metadata alone, never reading existing content — so it costs a full
authoring pass and produces a sibling that drifts from its source. Use it only
for the authoring language. `translate` reuses the source and verifies that code
blocks, URLs, headings and length survive. See [WORKFLOW.md](WORKFLOW.md).

## Content process

[WORKFLOW.md](WORKFLOW.md) documents the full cycle (snapshot → generate →
audit → status → commit → publish), how to switch backends mid-way, and the
known failure modes.

What gets generated is declared in [pipeline.yaml](pipeline.yaml): which
certifications are active, which languages each one should have, how much a
single run may generate, and the quality floor. No script keeps its own list.

## Quality

The standard does not depend on which model produced the material. The floor
lives in `pipeline.yaml → quality` and three places apply it from that single
definition: the generator **before writing** (weak material fails and is not
saved), the audit, and `STATUS.md` — which counts only what meets the floor, not
files that merely exist.

```bash
make quality                      # what meets the floor and what does not
make audit                        # pending/corrupt combos, and unrendered videos
make test                         # floor and stale-invalidation tests
scripts/check_citations.py        # do the cited sources exist?
scripts/check_manifests.py        # do the embedded manifests parse?
scripts/check_k8s_apis.py         # are any removed Kubernetes APIs still taught?
```

None of these costs API quota. And none of them proves an explanation is
correct: the floor catches stubs and missing structure, the citation check
catches invented sources. [WORKFLOW.md](WORKFLOW.md) explains what each check
proves, what it does not, and what real correctness verification would take.

## Deploying to Kubernetes

Content is baked into the image — publishing means rebuild + upgrade.

```bash
# With the public GHCR image:
helm upgrade --install study deploy/helm -n teach-plat --create-namespace \
  -f deploy/helm/values-local.yaml \
  --set image.registry=ghcr.io \
  --set image.repository=villadalmine/study-cybercirujas

# Or build in-cluster (Kaniko, no GitHub Actions):
make image-cluster TAG=mytag
make deploy-local TAG=mytag
```

Pass the **same explicit `TAG=`** to both targets: `TAG` defaults to a fresh
timestamp per invocation, so omitting it builds one tag and deploys another.

Build and deploy only when a certification is complete in that language; commit
partial progress freely.

For your own cluster, copy `values-study.example.yaml` to `values-local.yaml`
and edit domains/secrets. Prerequisites: Gateway API (Cilium or similar) and
cert-manager with a ClusterIssuer for TLS.

## Environment variables

| Variable | Use | Default |
|----------|-----|---------|
| `TEACH_ROOT` | Data repo root | `.` (cwd) |
| `TEACH_SECRET` | Session signing key | random |
| `TEACH_SITE_URL` | Hostname in the video watermark | `study.cybercirujas.club` |
| `TEACH_BACKEND` | Generation backend | `litellm` |
| `LITELLM_BASE_URL` | LiteLLM proxy URL | — |
| `LITELLM_API_KEY` | API key for LiteLLM | — |
| `LITELLM_MODEL` | Model to use through LiteLLM | — |

## Unattended generation timer

A systemd timer (`teach-resume.timer`) runs `scripts/resume-generation.sh` every
20 minutes to generate content unattended. It probes the quota first and skips
the pass when there is none, and it is idempotent — it skips what is already done.

> **It spends API quota on its own.** Do not enable it without the owner's
> explicit approval, and check `quota-history.jsonl` afterwards to see what it
> actually did. A pass that repeatedly regenerates the same topic is burning a
> whole window for nothing (this happened: see CHANGELOG 2026-08-04).

```bash
# Enable
systemctl --user enable --now teach-resume.timer

# Stop
systemctl --user stop teach-resume.timer && systemctl --user disable teach-resume.timer

# Status and logs
systemctl --user status teach-resume.timer
tail -50 ~/.local/state/teach-plat/resume.log
tail -5  ~/.local/state/teach-plat/quota-history.jsonl   # one line per quota probe

# Manual pass (no timer)
scripts/resume-generation.sh
```

Unit files are versioned in `deploy/systemd/` and installed into
`~/.config/systemd/user/`.

## Licence

[Apache License 2.0](LICENSE)
