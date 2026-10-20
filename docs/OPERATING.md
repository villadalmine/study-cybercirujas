# Operating the pipeline — for maintainers

Everything here is for whoever **generates, checks and publishes** the
material. To study, or to run your own copy, you do not need any of it: see
[README.md](../README.md) and [DEVELOPERS.md](../DEVELOPERS.md). The full
content cycle and its failure modes are in [WORKFLOW.md](../WORKFLOW.md).

## Quickstart (maintainers)

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
git add -A certs media STATUS.md && git commit -s && git push
```

Step 2 is a loop around the single pass, because one pass generates
`budget.topics_per_run` topics and exits — right for a timer every 20 minutes,
wrong for "finish this". It stops three ways and says which: the goal is met, the
quota window closed (probed before each pass, so nothing is wasted), or the pass
cap. Safe to run twice — each pass rescans from disk and claims per topic, so a
second copy takes different topics.

**There is no separate publish step.** When a certification becomes complete —
every topic, every declared language, above the quality floor, videos rendered —
the pass renders the video, refreshes STATUS.md, and builds and deploys the
image. Completeness is derived from the tree, not from a status field, so a run
that dies half way through cannot produce a publishable state. It fires only when
the set of complete certifications changes, so a pass that finishes nothing
rebuilds nothing.

```bash
make publish-complete                       # force it, or DRY=1 to see the plan
```

**See what is true** (all free, none of these call a model):

```bash
make audit                                  # pending/corrupt combos + unrendered videos
teach status                                # regenerate STATUS.md from disk
scripts/check_config.py                     # is it running on what it says it runs on?
scripts/check_units.py                      # installed systemd units vs the repo
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
export TEACH_AGENT=<agent-name>             # tell the tools who you are
scripts/run_batch.py kcsa --lang en         # refused if kcsa belongs to someone else
scripts/run_batch.py kcsa --lang en --anyway   # override deliberately
```

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

**What authors is declared in `pipeline.yaml`**, under `generation`:

```yaml
generation:
  model: claude-opus-5
  effort: xhigh
```

Every path reads it — the timer, `make milestone`, `make cert`, a command typed
by hand — so none of them can quietly use something else. `TEACH_CLAUDE_MODEL`
and `TEACH_CLAUDE_EFFORT` still win when set, for a deliberate one-off
comparison; `scripts/check_config.py` reports when something is overriding the
declaration, and reads the usage log to check what recent content *actually* ran
on, which is the only way to catch an override path nobody anticipated.

Use the full model id, not the `opus` alias: the alias means "the latest Opus"
and the CLI can fall back mid-run, which makes two topics incomparable. Measured differences between models
are in [docs/BACKEND_COMPARISON.md](BACKEND_COMPARISON.md); translation
specifically is the one step where a cheap model is measured safe, in
[docs/TRANSLATION_STUDY.md](TRANSLATION_STUDY.md).

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
core.hooksPath .githooks`. This repository is public, and a working copy is often
synced or backed up somewhere besides git — a key that lands in it has left the
machine, and one that is ever pushed must be rotated, not deleted.

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
blocks, URLs, headings and length survive. See [WORKFLOW.md](../WORKFLOW.md).

## Content process

[WORKFLOW.md](../WORKFLOW.md) documents the full cycle (snapshot → generate →
audit → status → commit → publish), how to switch backends mid-way, and the
known failure modes.

What gets generated is declared in [pipeline.yaml](../pipeline.yaml): which
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
make quality                      # floor report, then rescore and write each meta.yaml quality block (CERT=<cert> for one)
make audit                        # pending/corrupt combos, and unrendered videos
make test                         # floor and stale-invalidation tests
scripts/check_citations.py        # do the cited sources exist?
scripts/check_manifests.py        # do the embedded manifests parse?
scripts/check_k8s_apis.py         # are any removed Kubernetes APIs still taught?
scripts/check_api_facts.py        # do manifests use APIs the tracked release serves?
scripts/check_sources.py          # is each citation an official project source?
scripts/check_provenance.py       # traceable, accounted for, content before video
scripts/check_source_chain.py     # does every link declare its origin? (PRINCIPLES -> The source chain)
scripts/quality_score.py --check  # is every topic's quality block what the files give?
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
which is a different question — see [docs/AUDITOR_DESIGN.md](AUDITOR_DESIGN.md)
for what is verified, what is not, and why the obvious RAG approach is last on the
list rather than first.

None of these costs API quota. And none of them proves an explanation is
correct: the floor catches stubs and missing structure, the citation check
catches invented sources. [WORKFLOW.md](../WORKFLOW.md) explains what each check
proves, what it does not, and what real correctness verification would take.

## Keeping it honest over time

Nothing here degrades silently, because each moving part has a check that
costs no quota:

```bash
make check-updates      # exam syllabi vs what each vendor publishes today
make check-models       # the bot's model catalogue vs OpenRouter (separate target)
make verify             # quality floor, manifests, k8s APIs, provenance, graph, tests
make metrics            # tokens and quota windows spent, per stage and per day
```

`make check-updates` is the quarterly habit: it refreshes the **Exam versions**
table in STATUS.md and prints what drifted ([how to read and report it](#checking-curriculum-updates)). The same information is served at
`/api/status` and rendered in the site's **Status** section, so the public page
and the repository cannot disagree — they are two projections of the same
functions over the same tree.

## Checking curriculum updates

The question: **is the frozen material built on the exam version each vendor
publishes today?** Two facts are kept apart on purpose
(`scripts/check_versions.py` explains why): what we froze lives in each
`certs/<cert>.md` frontmatter; what upstream publishes lives in
`catalog.yaml`, and only `teach tracker sync` writes it.

### What `make check-updates` does

```bash
make check-updates
```

| Step | What it is | Cost |
|---|---|---|
| `teach tracker sync --backend claude` | the **AI part**: scrapes what each vendor currently publishes and writes only the upstream fields of `catalog.yaml`. It can never touch a frozen syllabus (a sync once overwrote the very comparison it was meant to enable). | a few completions |
| `scripts/status_matrix.py` | regenerates `STATUS.md`, including the **Exam versions** table | free |
| `scripts/check_versions.py` | the **deterministic part**: the verdict per certification, built-on version vs upstream version | free |

The **study bot's model catalogue** (`models.yaml`) is a separate target,
run in the same sitting: `make check-models` (`scripts/check_models.py`, free,
no key) asks OpenRouter's live API for models that vanished, prices that
moved, `:free` models that started charging, and models that dropped
`reasoning`. `make check-updates` does not run it. A `GONE` or `PAID` line
means the bot is showing students something untrue.

### Reading the "Exam versions" table in STATUS.md

It is the record of the check, one row per certification: the version the
material is built on, the snapshot date, the upstream version, when upstream
changed, when it was last checked, and the verdict — ✅ current · ⚠️ outdated ·
– unknown.

### Reporting it, most severe first

1. **Outdated** certifications: name the version gap and estimate the
   re-snapshot's reach honestly. A version bump can be a renumbering or a full
   overhaul (lpi-devops v2.0 dropped Ansible and added a Kubernetes domain;
   only title-exact topics survived the remap). Recommend a re-snapshot with
   the map-exact / author-the-rest procedure, never a blind remap.
2. **Unknown** rows mean **not measured, not "fine"**: say which side lacks a
   version, and whether checking upstream could settle it.
3. **Current** rows need no words beyond the count.

### The rule

**Never re-snapshot without the owner's decision.** A re-snapshot changes the
scope of the content; whoever runs the check presents the table and the
recommendation and stops there — person or agent.

Afterwards, **commit the refreshed `catalog.yaml` and `STATUS.md`**, so the
table on GitHub reflects the latest check.

This section replaces the `check-updates` Claude Code skill that used to live
in `.claude/skills/` (retired 2026-10-15): the procedure belongs in the docs
every contributor and every agent reads, not in one tool's private folder.

## Deploying to Kubernetes

Content is baked into the image, so publishing means a new image and a
`helm upgrade` with an explicit tag. The whole procedure is in
[docs/DEPLOY.md](DEPLOY.md): which image for amd64 or arm64 nodes, the values
file, preflight, verification, rollback, the `site-YYYY-MM-DD` tag and the
upgrade notes per release.
`env.TEACH_SECRET` is required (at least 32 characters, e.g. `openssl rand -hex 32`):
the chart refuses to render without a real one.

Build and deploy only when a certification is complete in that language; commit
partial progress freely.

## Environment variables

| Variable | Use | Default |
|----------|-----|---------|
| `TEACH_ROOT` | Data repo root | `.` (cwd) |
| `TEACH_SECRET` | Session signing key | random; required in the chart (>= 32 chars, not a placeholder) |
| `TEACH_RATE_API` | Requests per minute per client on `/api` (0 = off) | `300` in the app; `0` in the chart |
| `TEACH_RATE_SEARCH` | Requests per minute per client on `/api/search` (0 = off) | `30` in the app; `0` in the chart |
| `TEACH_TRUST_PROXY` | `1` = identify the client from the end of `X-Forwarded-For`. Only behind a proxy you control that appends the peer address | unset; `0` in the chart |
| `TEACH_TRUSTED_HOPS` | With `TEACH_TRUST_PROXY=1`: how many entries from the right are proxy-appended | `1` |
| `TEACH_OFFLINE` | `1` = the API never calls out (no live OpenRouter price check); what the determinism tests use | unset |
| `TEACH_SITE_URL` | Hostname in the video watermark | `study.cybercirujas.club` |
| `TEACH_BACKEND` | Generation backend | `litellm` |
| `LITELLM_BASE_URL` | LiteLLM proxy URL | — |
| `LITELLM_API_KEY` | API key for LiteLLM | — |
| `LITELLM_MODEL` | Model to use through LiteLLM | — |

### Rate limit (off by default in the chart)

The API has a small per-client rate limit (`teach/core/ratelimit.py`). The chart ships it **off**
(`TEACH_RATE_API` and `TEACH_RATE_SEARCH` = `"0"`): behind a TCP-passthrough edge (HAProxy without
PROXY protocol) every visitor reaches the pod from the same address, so they would all share one
bucket and a single heavy client could answer 429 to the whole site. To turn it on, first give the
pod the real client address: enable PROXY protocol at the edge and on the Gateway
(`gatewayAPI.enableProxyProtocol`), check that the app sees distinct addresses, then set
`TEACH_TRUST_PROXY: "1"` and the limits in `values-local.yaml` (for example `TEACH_RATE_API: "300"`,
`TEACH_RATE_SEARCH: "30"`). Never set `TEACH_TRUST_PROXY` when the pod can be reached without that proxy.

## Unattended generation timer

A systemd timer (`teach-resume.timer`) runs `scripts/resume-generation.sh` every
20 minutes to generate content unattended. It probes the quota first and skips
the pass when there is none, and it is idempotent — it skips what is already done.

**It runs on the workstation, not in the cluster, and that is deliberate**: it
authenticates as the owner's Claude subscription through the local CLI, which
has no equivalent inside a pod. There is no CronJob in the `teach-plat`
namespace and adding one would not help generation.

**What the unattended pass can and cannot do** (measured 2026-09-09):

| Stage | Unattended | Why |
|---|---|---|
| author · translate · render video | ✅ | pure Python plus ffmpeg, all available |
| commit to git | ✅ | `git` is on the host |
| **build image · deploy** | ❌ | the host has no `make`, `kubectl` or `helm` — those live in the toolbox container, so `publish_if_complete` reports the failure honestly and the content waits. Publishing is a manual step today: run `make publish-complete` from an environment that has them |

**The one thing that does run in the cluster** is the opposite case: a weekly
CronJob (`{release}-check-models`, in the same namespace as the site) runs
`scripts/check_models.py` to verify the study bot's models still exist at the
prices the UI shows. It needs the network and nothing else — no subscription,
no key, no quota — so a pod is the right home for it, and it uses the same
image the site runs, meaning the catalogue it checks is byte-identical to the
one being served.

Free models are why it exists: they churn, start charging, or disappear. When
that happens the job fails and stays visible:

```bash
kubectl get cronjob,jobs -n teach-plat            # did last week's check pass?
kubectl logs -n teach-plat job/<failed-job>       # GONE / PRICE / PAID / PARAM
helm upgrade ... --set checkModels.enabled=false  # turn it off
```

It changes nothing on its own. Replacing a model is a judgement call against
the selection criteria written into `models.yaml`.

> **It spends API quota on its own.** Do not enable it without the owner's
> explicit approval, and check `quota-history.jsonl` afterwards to see what it
> actually did. A pass that repeatedly regenerates the same topic is burning a
> whole window for nothing (this happened: see docs/HISTORY.md, 2026-08-04).

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

