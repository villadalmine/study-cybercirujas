# Roadmap — where this is and where it goes

Read this first after time away. [CHANGELOG.md](CHANGELOG.md) says what was
delivered; this says what is **next and why**. Everything here is derived from
the tree — verify any line with `make status`, `make check-updates` or
[STATUS.md](STATUS.md) rather than trusting the date at the bottom.

Last reviewed: **2026-09-10** · site: study.cybercirujas.club

## Where it is

**26 certifications published and studyable**, 38 in the catalogue, in four
families:

| Family | Published | Outstanding |
|---|---|---|
| ☸️ CNCF / Kubernetes | 14 / 15 | `cba` — its PDF is unreadable; needs the OCR route and a human to check the result before freezing |
| 🐧 Linux / LPI | 9 / 14 | `lpic-2` (41 objectives — **the last cert still serving pre-resnapshot content**), `lpic-3-300` (20), `lpi-020-100` (17), `lfcs` (5), `lfca` (6) |
| ☁️ Cloud providers | 3 / 3 ✅ | — the AWS, Azure and Google careers exist end to end |
| 🤖 AI | 0 / 6 | syllabi frozen and visible as coming-soon: `aws-aif` (14), `gcp-gail` (15), `ai-901` (7), `nca-aiio` (22), `nca-genl` (31), `ncp-aii` (39) |

**The study bot is live** (phase 1): pick a topic, bring your own OpenRouter
key, ask. Zero platform cost. Feedback is being collected now that the site is
public — that feedback, not this document, decides whether phase 2 happens.

**The machinery is idle and costs nothing** unless a milestone is declared:
`scripts/steer.py milestone <cert> en es` then `make milestone`.

## What is next

Ordered by what each one buys, not by size.

1. **Feedback on the bot.** It is the only thing on the site that is not
   content, it just went public, and phase 2 is speculative until someone asks
   a question phase 1 cannot answer. Collect first, build second.

2. **`lpic-2` — 41 objectives.** The last certification whose published
   material predates its own re-snapshot: the site serves topics built on a
   syllabus that no longer exists. Regenerating it is what makes the catalogue
   true, which is why it outranks any new certification.

3. **AI phase 1 — `aws-aif`, `gcp-gail`, `ai-901` (36 objectives).** Turns the
   roadmap already visible on the site into three studyable second rungs of the
   cloud careers. Rationale and the five filters that admitted them:
   [docs/AI_ROADMAP.md](docs/AI_ROADMAP.md).

4. **NVIDIA — start with `nca-aiio` alone (22).** Its infrastructure branch is
   the natural continuation of the Kubernetes corpus. Doing one associate first
   proves the extraction produces good material before committing the other 70
   objectives.

5. **The rest of LPI** — `lpic-3-300`, `lpi-020-100`, `lfcs`, `lfca` (48
   together). `lfcs` also completes the Golden Kubestronaut coverage.

6. **`cba`** — needs a human OCR session. Small, blocked on attention rather
   than effort.

## Study bot — the phases after this one

Full design: [docs/STUDY_BOT_DESIGN.md](docs/STUDY_BOT_DESIGN.md). Each phase
starts when its **entry condition** is met, not when the previous one finishes.

| Phase | Entry condition | What it adds |
|---|---|---|
| 1 ✅ shipped | — | Topic chat, task harness, cost controls |
| 1.5 | the CronJob reports drift but only to a pod log | `/api/models` validates the catalogue against OpenRouter out-of-band and marks unavailable models so the page stops offering them — automating the guard, never the choice of replacement |
| 2 | students ask questions spanning topics of one certification | The topic index goes to the model, it names what it needs, the page loads those files — tool calling where supported (84% of models), two round trips as fallback. Still no vector store |
| 3 | demand for career-level work: study plans, gap analysis | Multi-pass sub-agents, and the same four-function contract exposed over **MCP** so any external agent can study against the corpus |
| 4 | an owner decision on persistence | Anonymous progress via `X-Session-ID`; blocked on the deployment having no storage |

## Standing decisions worth not re-litigating

- **Generation stays on the workstation.** It authenticates as the owner's
  Claude subscription through the local CLI; a pod has no equivalent. The one
  thing that does belong in the cluster is the weekly `check-models` CronJob,
  which needs the network and no quota.
- **Publishing images is manual.** The host has `git` but no `make`,
  `kubectl` or `helm`, so the unattended pass stops after committing and says
  so. Options are in [AGENTS_SYNC.md](AGENTS_SYNC.md); none has been chosen.
- **Anthropic and OpenAI certifications are wanted but not catalogable.**
  Anthropic's four Pearson VUE exams have the right shape but no publicly
  published objectives (the Partner Academy is organisation-gated); OpenAI's
  is assessed inside ChatGPT and may never have a domain-weighted syllabus.
  Re-check quarterly — next **2026-12**.
- **Never catalogue a syllabus from a third-party summary.** Community guides
  circulate detailed domain lists for exams whose vendors publish none; using
  them is the same defect as scraping the wrong page, which cost this project
  seven certifications once.

## The technical-debt plan

Ordered by a principle this project keeps re-learning: **when a check fires en
masse, verify the check before repairing the content.** Applied on 2026-09-10
it turned 144 "broken manifests" into 80 in one commit — 64 were CloudFormation
tags that `yaml.safe_load` refuses by design, against material that was
correct all along.

### Step 1 — separate false positives from real ones · *free, mostly done*

- ✅ **CloudFormation tags** (`!Ref`, `!Sub`, `!GetAtt`, `!Equals`) now parse.
  144 → 80.
- **Next: `json` fences holding console output.** ~14 of the remainder are
  blocks tagged `json` whose content starts with a sentence
  (`Successfully loaded configuration:` followed by the object). The material
  is right, the fence label is wrong — the same repair already done by hand in
  `pca` and `cks`. Mechanical rule: a `json` block that does not start with
  `{` or `[` is console output; retag it as a plain fence. Worth doing as a
  script that prints its diff rather than a blind rewrite.

### Step 2 — repair what is genuinely broken · *free, needs eyes*

The ~50 that remain are real: unquoted `: ` inside YAML values, a block scalar
whose indentation ends the scalar early, an alias that never resolves. Each
needs looking at, but they cluster by cert (`lpi-050-100` 24, `kcsa` 12), so a
pass per certification is efficient. **The `pca` repair is the template**: two
of its three were errors that broke the real tool, not just our parser — the
fix improved the material, not only the report.

### Step 3 — stop producing them · *the only step that ends the debt*

Every repair above is retroactive. The generation prompt in `generator.py`
never states the conventions these violate: console output is not `json`,
values containing `: ` need quoting, block scalars must keep their indent. One
paragraph there prevents the next hundred. **This is a prompt change, so it is
propose-and-measure, not hot-patch** — it applies to every future topic and its
effect cannot be seen in one file.

### Step 4 — the rest, in order of what it buys

| Debt | Size | Plan |
|---|---|---|
| **Unattributed citations** | 4,498 of 22,860 (20%) | `scripts/check_sources.py --unknown-only` lists the domains; adding the legitimate ones to `docs/sources.yaml` is bookkeeping with no quota. Do it in batches by frequency — the top 20 domains cover most of the tail |
| **Orphaned topic directories** | 55 | A decision, not maintenance: salvage into current ids, archive, or delete. They hold real material from before a re-snapshot renumbered the syllabus. Listing script in [docs/CLEANUP.md](docs/CLEANUP.md) |
| **`.rejected/` backlog** | 73 files | Skim before clearing: a repeated pattern there is a bug nobody has noticed. That is exactly how the placeholder-URL and decapitated-topic bugs were found |
| **Registry retention** | — | `make clean-registry KEEP=N` covering steps 1–3 of CLEANUP.md, refusing to prune a deployed tag. Ends the 98 GB incident recurring |
| **Unattended publishing** | — | The host lacks make/kubectl/helm. Three options in AGENTS_SYNC.md; none chosen. Lowest urgency — publishing by hand works |

### Sequencing

Steps 1 and 2 first: they are free and they turn `make verify` green, which is
what makes every other check believable. Step 3 next, because without it steps
1–2 repeat. Step 4 is opportunistic — citation bookkeeping is a good filler for
a quota-blocked window, since it needs no model at all.
