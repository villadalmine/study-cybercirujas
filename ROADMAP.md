# Roadmap — where this is and where it goes

Read this first after time away. [CHANGELOG.md](CHANGELOG.md) says what was
delivered; this says what is **next and why**. Finished work is deleted from
this file rather than ticked — an item here means it is still open.

Everything below is derived from the tree. Verify any line with `make status`,
`make check-updates` or [STATUS.md](STATUS.md) rather than trusting the date.

Last reviewed: **2026-09-11** · site: study.cybercirujas.club

## Where it is

**26 certifications published and studyable**, 38 in the catalogue:

| Family | Published | Outstanding |
|---|---|---|
| ☸️ CNCF / Kubernetes | 14 / 15 | `cba` — unreadable PDF, needs the OCR route and a human to check the result |
| 🐧 Linux / LPI | 9 / 14 | `lpic-2` (41), `lpic-3-300` (20), `lpi-020-100` (17), `lfcs` (5), `lfca` (6) |
| ☁️ Cloud providers | 3 / 3 | — AWS, Azure and Google careers exist end to end |
| 🤖 AI | 0 / 6 | syllabi frozen, visible as coming-soon: `aws-aif` (14), `gcp-gail` (15), `ai-901` (7), `nca-aiio` (22), `nca-genl` (31), `ncp-aii` (39) |

**The study bot is live** (phase 1): pick a topic, bring your own OpenRouter
key, ask. Zero platform cost.

**The machinery is idle and spends nothing** until a milestone is declared:
`scripts/steer.py milestone <cert> en es` then `make milestone`.

**`make verify` is green** and runs in CI on every push and pull request.

## Current focus — set 2026-09-11

**Collect feedback on the study bot. Generate no content until there is some.**

The bot is the first thing on this site that is not study material, it went
public days ago, and every phase after it is speculative until a real student
asks something phase 1 cannot answer. Building phase 2 now would be guessing
at a problem nobody has reported.

**The first feedback arrived on 2026-09-11 and has been acted on**: *some
models do not work, and the reasoning control is not understandable*. Both were
true and neither was visible to `check_models.py`, which reads OpenRouter's
catalogue rather than calling the models. `scripts/probe_models.py`
(`make probe-models`) now calls each one — 51 requests, $0.0077 a pass, on the
bot's own limited key — and the page is built from what it measured: 12 of 18
models think even when reasoning is switched off, 4 cannot be stopped at all,
and 2 ignore the effort setting entirely. Findings and method in
[docs/STUDY_BOT_DESIGN.md](docs/STUDY_BOT_DESIGN.md).

That closes the feedback, not the phase: phase 2 still waits for a question
phase 1 cannot answer.

Nothing is running and nothing is spending: no milestone is declared, so the
timer wakes, finds nothing to do, and sleeps. To resume content work later,
pick an item below and declare it — the machinery needs no other setup.

## What is next

Ordered by what each one buys, not by size.

1. **Feedback on the bot** ← *current focus*. It is the only thing on the site that is not
   content and it just went public. Phase 2 is speculative until someone asks
   a question phase 1 cannot answer — collect first, build second. The first
   round (models that do not answer, an unintelligible reasoning control) is
   fixed and deployed; what is still open from it:

   - **re-probe after every catalogue change** — `make probe-models UPDATE=1`,
     and always after changing `max_tokens` in the page, because OpenRouter
     derives each provider's thinking budget from it and the verdicts stop
     being true for a request nobody sends;
   - **the two `:free` models that answered nothing** (`gemma-4-31b`,
     `nemotron-3-ultra`) are marked `flaky` and still offered. Replacing a
     model is a judgement call against the criteria at the top of
     `models.yaml` — the probe reports, a human decides;
   - **`gpt-5-mini` stays the default** even though its thinking cannot be
     switched off: it answered every probe, and the page now says so instead
     of promising a cheaper option that does not exist.

2. **`lpic-2` — 41 objectives.** The last certification whose published
   material predates its own re-snapshot: the site serves topics built on a
   syllabus that no longer exists. Regenerating it is what makes the catalogue
   true, which is why it outranks any new certification.

   **It is also the first real test of the prompt change.** The code-block
   conventions shipped on 2026-09-11 and nothing has been generated since;
   `scripts/manifest_rate.py` answers whether new topics arrive broken once ten
   exist. Run it after this certification and read the result.

3. **AI phase 1 — `aws-aif`, `gcp-gail`, `ai-901` (36 objectives).** Turns the
   roadmap already visible on the site into three studyable second rungs of the
   cloud careers. Rationale and the five filters that admitted them:
   [docs/AI_ROADMAP.md](docs/AI_ROADMAP.md).

4. **NVIDIA — start with `nca-aiio` alone (22).** Its infrastructure branch
   continues the Kubernetes corpus naturally. One associate first proves the
   extraction produces good material before committing the other 70 objectives.

5. **The rest of LPI** — `lpic-3-300`, `lpi-020-100`, `lfcs`, `lfca` (48
   together). `lfcs` also completes Golden Kubestronaut coverage.

6. **`cba`** — needs a human OCR session. Small, blocked on attention.

## Study bot — the phases after this one

Full design: [docs/STUDY_BOT_DESIGN.md](docs/STUDY_BOT_DESIGN.md). Each phase
starts when its **entry condition** is met, not when the previous one finishes.

| Phase | Entry condition | What it adds |
|---|---|---|
| 1.5 | the CronJob reports drift but only to a pod log | `/api/models` validates the catalogue against OpenRouter out-of-band and marks unavailable models so the page stops offering them — automating the guard, never the choice of replacement. **Partly done**: `probe_models.py --update` already writes `probe`/`thinking`/`thinking_off` into `models.yaml` and the page honours them, so the guard exists — as a manual pass, because it spends. What is left is the out-of-band half, and only for the free check |
| 2 | students ask questions spanning topics of one certification | The topic index goes to the model, it names what it needs, the page loads those files — tool calling where supported (84% of models), two round trips as fallback. Still no vector store |
| 3 | demand for career-level work: study plans, gap analysis | Multi-pass sub-agents, and the same four-function contract exposed over **MCP** so any external agent can study against the corpus |
| 4 | an owner decision on persistence | Anonymous progress via `X-Session-ID`; blocked on the deployment having no storage |

## Smaller things, when there is an appetite

- **Wire `make clean-registry` into publishing** so pruning happens without
  being remembered. The tool exists and is safe; only the trigger is missing.
- **The remaining 9% of unattributed citations** — a long tail of one-off
  domains. `scripts/check_sources.py --unknown-only` lists them; good filler
  for a quota-blocked window since it needs no model.
- **Clear `.rejected/`** — reviewed on 2026-09-11 and its findings acted on, so
  `rm -rf .rejected/*` is safe now. It refills as generation runs, and skimming
  it before clearing is how two real bugs were found.
- **`lpi-devops` is one objective short of upstream** (14 of 15 mapped after
  the v2.0 re-snapshot). Deliberately deferred; it is a judgement call about
  orphaning good material to gain one topic.

## Standing decisions worth not re-litigating

- **Generation stays on the workstation.** It authenticates as the owner's
  Claude subscription through the local CLI; a pod has no equivalent. The one
  thing that belongs in the cluster is the weekly `check-models` CronJob, which
  needs the network and no quota.
- **Publishing images is manual.** The host has `git` but no `make`,
  `kubectl` or `helm`, so the unattended pass stops after committing and says
  so. Options are in [AGENTS_SYNC.md](AGENTS_SYNC.md); none has been chosen.
- **Anthropic and OpenAI certifications are wanted but not catalogable.**
  Anthropic's four Pearson VUE exams have the right shape but no publicly
  published objectives (the Partner Academy is organisation-gated); OpenAI's is
  assessed inside ChatGPT and may never have a domain-weighted syllabus.
  Re-check quarterly — next **2026-12**.
- **Never catalogue a syllabus from a third-party summary.** Community guides
  circulate detailed domain lists for exams whose vendors publish none; using
  them is the same defect as scraping the wrong page, which cost this project
  seven certifications once.
- **When a check fires en masse, verify the check before repairing the
  content.** 116 of 144 "broken manifests" and 5 of 7 rejected translations
  were the checker being wrong, not the material. Both times the repair cost
  would have been paid against correct work.
