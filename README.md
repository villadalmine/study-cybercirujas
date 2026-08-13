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
make setup          # once per clone: venv, CLI, and the pre-commit hook
make status         # what is missing, what is unsound, who is working, what it cost
make next           # do whatever comes next — it decides which certification and why
make verify         # prove it: quality floor + manifests + APIs + provenance + tests
make serve          # API + web on :8000
```

`make next` needs no arguments. It picks the certification, in the right order
(finish what is started → author before translating → content before video →
translate last), takes a per-topic claim so it cannot collide with another agent
or with the timer, and stops at the budget in `pipeline.yaml`.

`make help` lists every target.

## Running it yourself, without guessing

Everything the pipeline does is one command, and every decision it obeys is in
`pipeline.yaml` rather than in someone's head.

**Do work:**

```bash
make next                                   # whatever is most nearly finished
make next DRY=1                             # what would it do, and why
make cert CERT=cks                          # one specific certification, end to end
make cert CERT=cks DRY=1                    # dry run first
make cert CERT=cks BACKEND=gemini TRANSLATE_BACKEND=litellm
```

**Change what it should do** — a decision becomes configuration in one command,
validated, idempotent, and refusing anything the pipeline could not act on:

```bash
scripts/steer.py show                       # every knob and its current value
scripts/steer.py activate lfcs --owner any  # start a certification
scripts/steer.py deactivate lpi-702         # stop working on one
scripts/steer.py own kcsa claude            # who takes it by default
scripts/steer.py languages kcsa en es pt    # which languages it must have
scripts/steer.py video kcsa en es           # which videos to render
scripts/steer.py budget 3                   # topics per run
scripts/steer.py milestone kcsa en es       # what the timer works toward
scripts/steer.py milestone --clear          # timer idles
```

**The milestone is what bounds unattended work.** The timer works only on the
declared goal and stops when it is met; with none declared it generates nothing.
That asymmetry is deliberate — an unattended process that reads "unspecified" as
"everything" is how a single commit re-snapshotting seven syllabi put 162 topics
into the queue overnight. STATUS.md shows the goal and how far it is.

**Finishing one certification, start to published**, is three commands:

```bash
scripts/steer.py milestone kca en es   # 1. declare the goal
make milestone                         # 2. work it to completion, then stop
git add -A certs media STATUS.md && git commit && git push
```

Step 2 is a loop around the single pass, because one pass generates
`budget.topics_per_run` topics and exits — right for a timer every 20 minutes,
wrong for "finish this". It stops three ways and says which: the goal is met, the
quota window closed (probed before each pass, so nothing is wasted), or the pass
cap. Safe to run twice — each pass rescans from disk and claims per topic, so a
second copy takes different topics.

**There is no separate publish step.** Video, STATUS.md, and building and
deploying the image all happen inside the pass, the moment the certification
becomes complete.

**Finishing publishes itself.** When a certification becomes complete — every
topic, every declared language, above the quality floor, videos rendered — the
pass builds and deploys it. It only fires when the set of complete certifications
changes, so a pass that finishes nothing rebuilds nothing.

```bash
make publish-complete                       # or DRY=1 to see what it would do
```

**See what is true** (all free, none of these call a model):

```bash
make audit                                  # pending/corrupt combos + unrendered videos
teach status                                # regenerate STATUS.md from disk
scripts/check_provenance.py                 # traceable? bookkeeping right? order right?
scripts/check_sources.py                    # are citations official, and whose?
scripts/usage_report.py                     # what has been spent, per model and topic
scripts/window_budget.py                    # weekly quota ceiling vs session windows
scripts/topic_cost.py --cert kca            # tokens, context and cost per topic
scripts/topic_cost.py --by-model            # what each model costs per topic
scripts/topic_cost.py --forecast 135        # what N more topics would take
python3 -c "from teach.core import claims; print(claims.active())"   # who is working now
```

**Two agents at once.** Exclusion is per topic, so different topics never
collide. Ownership (`pipeline.yaml → certs.<id>.owner`) stops two agents spending
two quota windows on the same certification:

```bash
export TEACH_AGENT=antigravity              # tell the tools who you are
scripts/run_batch.py kcsa --lang en         # refused if kcsa belongs to someone else
scripts/run_batch.py kcsa --lang en --anyway   # override deliberately
```

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

**Any backend may author; none may author untraceably.** Which provider you use
is your call — `claude` is a subscription, so it costs no money and one quota
window instead. What is not optional is the `meta.yaml` recording the backend,
the real model and the date, because content whose origin is unknown cannot be
reproduced, compared or rolled back. `scripts/check_provenance.py` enforces it.

Pin an exact model with `TEACH_CLAUDE_MODEL=claude-opus-4-8`. Use the full id, not
the `opus` alias: the alias means "the latest Opus" and the CLI can fall back
mid-run, which makes two topics incomparable. Measured differences between models
are in [docs/BACKEND_COMPARISON.md](docs/BACKEND_COMPARISON.md); translation
specifically is the one step where a cheap model is measured safe, in
[docs/TRANSLATION_STUDY.md](docs/TRANSLATION_STUDY.md).

With local backends: generate on your machine → review → `make publish`.

**Translation can be routed elsewhere; authoring should not.** Authoring decides
what is true and is worth the strongest model available. Translation has its
substance fixed by the source and every failure mode is mechanically detectable,
which is why it is the one place a cheap model is measured safe — about **$0.07**
for the whole remaining workload. The saving is not money: on a subscription the
dollar figures are an API-equivalent price, not a bill. The saving is the ~5 h
quota window, and a window spent translating is a window not spent authoring.

```bash
cp .env.example .env && chmod 600 .env && $EDITOR .env
```

**`.env` configures translation and nothing else**, and that is enforced rather
than documented: the loader accepts five variables and refuses the rest out
loud. `TEACH_BACKEND=...` there does nothing, because moving *authoring* to a
cheap model would be invisible afterwards except in the `meta.yaml` of every
topic written while it was set. To change what authors, pass `--backend` or set
the variable in the real environment, where it is a visible decision.

`.env` is git-ignored and loaded by `teach/core/__init__.py`, so every entry
point sees it — CLI, scripts and timer alike. Variables already set in the
environment win, so the file is a default and never an override. **Without it
everything still works**: translation falls back to `claude`, which is the
current setup and costs only more of the scarce resource.

The pre-commit hook refuses to commit `.env`, or an OpenAI/OpenRouter/Google/
GitHub key pasted into any other file. It is a backstop, not the protection:
`--no-verify` bypasses it, and so does a clone that never ran `git config
core.hooksPath .githooks`. This repository is public **and** lives inside a
Nextcloud folder, so a key here is on the sync server and every attached device
regardless of git — and one that is ever pushed must be rotated, not deleted.

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
make verify                       # everything below, in one command
make quality                      # what meets the floor and what does not
make audit                        # pending/corrupt combos, and unrendered videos
make test                         # floor and stale-invalidation tests
scripts/check_citations.py        # do the cited sources exist?
scripts/check_manifests.py        # do the embedded manifests parse?
scripts/check_k8s_apis.py         # are any removed Kubernetes APIs still taught?
scripts/check_api_facts.py        # do manifests use APIs the tracked release serves?
scripts/check_sources.py          # is each citation an official project source?
scripts/check_provenance.py       # traceable, accounted for, content before video
scripts/check_syllabus.py         # does the syllabus cover the exam, or its index?
scripts/check_versions.py         # what we built on vs what the exam publishes now
scripts/status_matrix.py --check  # is STATUS.md still what the filesystem says?
```

**A syllabus is the list of everything that will be written, so it is checked
first.** Seven LPI certifications were frozen from their *overview* page — chapter
titles, no objectives — and produced material that passes every per-file check
while covering a quarter of the exam. `check_syllabus.py` compares the topic list
against the source document: uniform weights nobody published, sub-numbering with
nothing under it, and (with `--upstream`) fewer topics than the page numbers
objectives. `check_versions.py` answers the other half — whether the exam has
moved since we froze it — by version when both sides publish one, by date
otherwise.

Some official PDFs cannot be read at all: CAPA's has embedded fonts with no
Unicode map, so every extractor returns 44 characters from three pages. That is
what `scripts/ocr_pdf.py` is for. It is not wired into the fetch path on purpose
— OCR makes mistakes, and a syllabus is worth reading before it is frozen.

```bash
scripts/ocr_pdf.py <url> --check  # does this PDF even need OCR?
scripts/ocr_pdf.py <url>          # render it and read the pixels
```

`check_api_facts.py` is the only one that needs the network, and it downloads each
Kubernetes OpenAPI spec once. It is version-aware because it has to be: a claim
true in 1.29 and false in 1.34 is the likeliest real error here, and checking
against "latest" would report correct material as wrong.

One check costs quota and is therefore a sampling tool, not a gate:

```bash
scripts/check_claims.py certs/cks/1.1/en/content.md --sample 3
```

It fetches a cited page and asks whether it actually covers the subject. The free
checks prove a URL **resolves**; this one asks whether it **supports the claim**,
which is a different question — see [docs/AUDITOR_DESIGN.md](docs/AUDITOR_DESIGN.md)
for what is verified, what is not, and why the obvious RAG approach is last on the
list rather than first.

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
