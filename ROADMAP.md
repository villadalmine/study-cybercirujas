# Roadmap — where this is and where it goes

Read this first after time away. [CHANGELOG.md](CHANGELOG.md) says what was
delivered; this says what is **next and why**. Finished work is deleted from
this file rather than ticked — an item here means it is still open.

Everything below is derived from the tree. Verify any line with `make status`,
`make check-updates` or [STATUS.md](STATUS.md) rather than trusting the date.

Last reviewed: **2026-09-18** · site: study.cybercirujas.club

## Where it is

**26 certifications published and studyable**, 38 in the catalogue:

| Family | Published | Outstanding |
|---|---|---|
| ☸️ CNCF / Kubernetes | 14 / 15 | `cba` — unreadable PDF, needs the OCR route and a human to check the result |
| 🐧 Linux / LPI | 9 / 14 | `lpic-2` (41), `lpic-3-300` (20), `lpi-020-100` (17), `lfcs` (5), `lfca` (6) |
| ☁️ Cloud providers | 3 / 3 | — AWS, Azure and Google careers exist end to end |
| 🤖 AI | 0 / 7 | `mcpa` complete in English, needs Spanish (17). Syllabi frozen, coming-soon: `aws-aif` (14), `gcp-gail` (15), `ai-901` (7), `nca-aiio` (22), `nca-genl` (31), `ncp-aii` (39) |

**The study bot is live**, all four phases: one topic, a whole certification
(the model asks for what it needs through tools), a whole career (one pass per
certification plus a synthesis), and progress kept in the student's own browser.
Bring your own OpenRouter key. Zero platform cost.

## Where we left off — 2026-09-18

Everything below is open. Nothing is running and nothing spends until someone
starts it.

**Two certifications went in through `teach cert snapshot`:**

- **`mcpa`** (Model Context Protocol Associate) — 17 topics, **complete in
  English**, live. Needs Spanish: 17 translations.
- **`ckne`** (Certified Kubernetes Network Engineer) — 22 topics, syllabus only,
  `active: false` on purpose. **Its beta is closed and GA has not landed**, so
  the objectives can still move. Flip it when upstream publishes the final
  curriculum, not before — material written against an unsettled syllabus is
  what cost this project seven LPI re-snapshots. Re-check the page before
  spending anything.

**`lpi-devops` is even again.** Five of its fifteen topics were `agy` at 22–35 KB
against ten at 65–117 KB, and four of those five were the whole *701 Software
Engineering* domain — a third of the exam weight at a third of the depth.
Regenerated and re-translated; `es` ratios are back to 1.05–1.08.

**Depth across the corpus, measured 2026-09-18.** Of 511 authored topics only
147 are at the opus-5 standard (78 KB average); 119 are `agy` (23 KB), 94 are
`claude` with the model unresolved (20 KB), 144 are `claude-opus-4-8` (31 KB).
**Size is not quality** — every one passes the floor, and the jump came from the
deliberate model/effort change of 2026-08-13, not a defect. A certification
written uniformly on an older model is *even*, and a student hits no hole. What
is worth fixing is unevenness *inside* one exam. Five have it:

| Cert | To redo | Worth it? |
|---|---|---|
| `lpi-devops` | — | done |
| `cgoa` | 2 of 4 | yes, cheap |
| `kca` | 17 of 31 | genuinely half and half — owner's call, 17 topics of real quota |
| `kcsa` | 41 of 42 | **no** — it is even; the outliers are one or two *upgraded* topics |
| `cnpa` | 25 of 27 | **no** — same shape |

**`cca` is stale.** The Cilium certification is already catalogued, frozen at
`2024-10-21` while upstream last changed the curriculum on `2025-11-28`, and it
carries five topics, one per domain — a coarse snapshot. That is a re-snapshot,
not a new entry.

**Two traps worth knowing before resuming:**

- **`teach cert generate <cert>` with no `--topic` authors every pending topic in
  one invocation**, ignoring `budget.topics_per_run`. It did 15 MCPA topics in
  114 minutes when 2 were intended. AGENTS_SYNC.md warns about this in those
  words. Always pass `--topic`.
- **`fix_corrupted_content.py` does not only report — it fills.** `pt` is
  declared for `lpi-devops` with 3 of 15 topics done, so an audit run starts
  translating the missing 12. Either finish them, or drop `pt` from
  `pipeline.yaml` **and** delete the three directories, since material nothing
  audits is the blind spot this repo has hit three times.

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
(`make probe-models`) now calls each one — 164 requests, $0.27 a full pass, on
the bot's own limited key — and the page is built from what it measured: 12 of
18 models think even when reasoning is switched off, 4 cannot be stopped at all,
and 2 ignore the effort setting entirely. A second pass sends each model a real
topic of this corpus and asks about it in all seven languages; a model is now
offered only where it answered from that material, in that language. Findings
and method in [docs/STUDY_BOT_DESIGN.md](docs/STUDY_BOT_DESIGN.md).

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
     being true for a request nobody sends. `LANGS=""` is the cent-priced
     liveness pass; the full one fills `langs:`;
   - **the comprehension fixture is one topic** (`lpi-010-160/5.2`,
     `/etc/passwd`). It proves a model reads what we send it; it does not prove
     the answer is any good, which is still the honest gap —
     [docs/AUDITOR_DESIGN.md](docs/AUDITOR_DESIGN.md);
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
| 1.5 · **BUILT 2026-09-14** | it fired for real: a 67%-wrong price sat in a pod log for days | `/api/models` validates the catalogue against OpenRouter out-of-band and marks unavailable models so the page stops offering them — automating the guard, never the choice of replacement. **Done** (option A): `teach/core/models_live.py` is the one comparison — `check_models.py` imports it instead of keeping a copy — and `/api/models` runs it in a background task every six hours, annotating `live_in`/`live_out`/`gone` without ever touching the frozen numbers or making a student wait on openrouter.ai. An unreachable provider degrades to today's behaviour, with a test that holds it |
| 2 | students ask questions spanning topics of one certification | The topic index goes to the model, it names what it needs, the page loads those files — tool calling where supported (84% of models), two round trips as fallback. Still no vector store |
| 3 · **MCP half BUILT 2026-09-14** | the contract existed once phase 2 needed it | `teach/mcp_server.py` serves `list_certs`, `get_syllabus`, `get_topic`, `search_topics` over stdio (`make mcp-setup`, then `.mcp.json`). Multi-pass **also built 2026-09-14, on the owner's call, ahead of this entry condition** — the condition was demand for career-level work and none has been observed yet, so whether it earns its several-calls-per-question is still open |
| 4 · **BUILT 2026-09-15** | the owner decided: in the browser, not on the server | Progress lives in `localStorage` beside the key: no endpoint, no id to forge, no retention rule, and the server still holds nothing about anyone. Gives up syncing between devices, which is what accounts are for. Records only what the page knows as fact — which topics were opened — never inferred mastery |

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
