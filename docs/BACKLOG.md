# Backlog

Pending items, without strict ordering unless specified. Open work is now tracked as issues, milestones and epics (see the README, *Where we are now*); this file keeps the design questions that have no issue yet. Resolved items are closed in their issue or PR and show up in the release notes ([CHANGELOG.md](../CHANGELOG.md); the dated record up to 2026-10-16 is [docs/HISTORY.md](HISTORY.md)); design details live in [docs/ORIGINAL_DESIGN.md](ORIGINAL_DESIGN.md).

## In Progress / Next (Ordering)

Standing rule for any generation run: after finishing, re-run `scripts/fix_corrupted_content.py` **and** check that the cert/language is actually listed in its `TARGETS` — an audit reporting "0 corrupt" only proves the combos it scans are clean. Add the new language to `TARGETS` in the same commit that generates it.

1. **Verify the local lab provider against real Docker and kind.** The plain-container half now runs for real: on 2026-10-14 `teach lab up lpi-010-160 2.1` on a fresh clone started the container, but the confirmation prompt inside `break_fix.sh` read EOF (no `-i` on `docker exec`), so the script cancelled itself and the lab was reported as running with nothing broken. Fixed (`labs._exec_script_cmd`, `tests/test_labs.py`), and `lab up` now prints the command to enter the lab. Still unverified: the kind half (`teach lab up --host cka 1.1`, now opt-in; the default for kubectl labs is `study-lab run`) on a machine with `kind`/`kubectl`.

   **Publishing rule: do not build or deploy the image until a cert is complete in the language being worked on.** Partial translations are safe on the site (`certs.py::topic_content` falls back to English, then Spanish, and flags `lang_fallback`), but they are not published — one image build per finished cert. Committing partial progress to git is fine and expected.
2. **Content for `lfcs` (5 topics) and `lfca` (6 topics)** — both have a snapshotted syllabus but zero generated content in any language, so they are the cheapest way to widen the catalog (no scraping step needed).
3. **Videos for paths without one**: `linux-devops`, `kubernetes-security`, `gitops-platform`, `observabilidad`, `service-mesh-networking`, `linux-foundation`. The `kubernetes` path is already done (es/en/de).

   *Removed 2026-10-14 as done:* translating `cks`/`kcna` to English (both complete in en+es), the `cnpe` snapshot (18 topics, complete), and the BYO-key study bot (live, all four phases — [docs/STUDY_BOT_DESIGN.md](STUDY_BOT_DESIGN.md)).
4. **See [docs/ROADMAP.md](ROADMAP.md) for what is next and why.** This file holds
   design detail and open investigations; the ordered queue lives there.

## Verifying the material is TRUE (docs/AUDITOR_DESIGN.md)

The gap nothing else covers: a confident wrong explanation passes the quality
floor, the citation check, the manifest check and the provenance check. Demonstrated
on 2026-08-06 — fresh kcsa/1.1 cited a kubernetes.io page for the 4Cs model that no
longer contains it. The URL resolves; the page was restructured.

Built so far:
- `scripts/check_sources.py` + `docs/sources.yaml` — 52 projects catalogued, 85% of
  4,277 citations attributed to an official source. **Extending it is one entry.**
- `scripts/check_api_facts.py` — apiVersion/kind checked against the tracked
  release's OpenAPI spec. Free, exact, version-aware, and it replaces a
  hand-maintained list that was drifting.
- `scripts/check_claims.py` — fetches a cited page and asks whether it covers the
  subject. Costs a completion per citation, so it samples.

Next, in order (the design argues at length for this order):
1. **Extend the spec lookup beyond kind existence** — field names, feature gates,
   defaults, ports. Same free mechanism, more of the errors that mislead a reader.
2. **A claim extractor.** Pull the checkable assertions out of a topic (versions,
   numbers, API shapes, flags). Useful alone; both remaining layers consume it.
3. **Crawl + diff the cited pages weekly, without judging.** Catches staleness —
   the failure already observed — for the price of bandwidth.
4. **Retrieval and adversarial judging last.** Ask for contradiction and absence,
   never "is this consistent?" — a confirmation-shaped judge agrees far too often.
   A claim with neither support nor contradiction is *unverified*, not fine.

Also open: 637 citations from 269 uncatalogued domains. `check_sources.py
--unknown-only` lists them; adding the legitimate ones is bookkeeping, no quota.

## Pipeline Automation

- **Syllabus-change trigger — the `stale` status is dead code.** It is in `certs.py::VALID_STATUS` and both `cli.py` and `generator.py` claim to regenerate "pending/stale" topics, but nothing ever assigns it: `tracker.py::snapshot_topics` copies the previous status verbatim, so a re-snapshot with a changed title or weight leaves the topic `generated` and its content is never revisited. docs/ORIGINAL_DESIGN.md's "only changed topics are regenerated" describes an intention, not the code. Implementation order and the reason each step matters is in docs/WORKFLOW.md — detect the diff in `snapshot_topics`, invalidate **every** language rather than just Spanish (generation currently skips on file existence and ignores status entirely, so a naive fix would update `es` and leave the translations describing the old syllabus), then re-render the certification video since its domain-weight scene comes from the topics that changed.
- **`teach cert translate` — real translation as a separate mode.** Proposed via docs/AGENTS_SYNC.md; the design and trade-offs are under "Real translation" in the Content section below. Keep it as its own flag (`--from es`), not a change to `--lang`, so both authoring and translating stay available.
- **A `teach pipeline` command** wrapping the loop end to end (snapshot → generate → audit → status → video) driven by `pipeline.yaml`, so the whole thing is one entry point rather than four scripts run in the right order. `scripts/run_batch.py` is the bounded generation step; the rest is still manual.

## Content

- **See [docs/STATUS.md](STATUS.md)** for the complete matrix of cert × language × lab, path × video language, and cert × video language (regenerate with `scripts/status_matrix.py` from actual filesystem — do not trust manual updates).
- ~~CKS in progress~~ **Done (2026-07-17)**: 26/26 in Spanish (content + exercises + labs, verified with `fix_corrupted_content.py` at 0 and per-file counts, not just topic status). Survived an external process `kill` and two Claude API quota cuts in the middle — resumed cleanly each time because topic generation is idempotent.
- ~~Translate CKAD, CKA, CKS, and KCNA to the other 6 languages — currently they only exist in Spanish.~~ **Partially done (2026-07-27)**: CKAD and CKA now have English (24/24 and 27/27). Remaining: fr/de/zh/ja/pt for those two, and every non-Spanish language for CKS and KCNA — see item 2 above.
- ~~Review if other CNCF certs already snapshotted (KCNA, KCSA, CKS, etc.) have the same weight-by-domain issue before generating content for them~~ **KCNA had the bug** (weights summed to 360, each sub-topic had the full domain weight copied) — re-snapshotted with the fixed script, now sums to 100, and content is generated (13/13). `KCSA` still has no snapshot (0 topics) so it does not apply. `LFCS` (5) and `LFCA` (6) do have snapshots and their weights sum to 100 correctly — but only at **domain level**, one topic per domain, unlike cka/ckad/cks which are snapshotted at sub-topic granularity (27/24/26). Decide before generating: 5 enormous topics, or re-snapshot into sub-topics for a comparable reading unit.
- Certification videos exist only in Spanish (5 certs). Path videos reach German at most. `ja` is blocked on TTS (see below); the rest is just render time.
- **Real translation (not implemented, worth considering).** What the CLI calls translating is not translating: `--lang en` regenerates a topic from scratch from syllabus metadata and never reads the Spanish content (see docs/WORKFLOW.md). That is why every language costs full authoring price — ~7 min and two completions per topic — and why language versions drift apart in structure and examples. A genuine translation mode would read `certs/<cert>/<topic>/es/content.md` and ask for the same text in the target language. Trade-offs, both real: it would be **much cheaper and viable on a small model** (restating existing prose, not authoring exam material) and would keep languages in sync — but every language would inherit the Spanish version's structure, and a weak model translating dense technical prose can quietly mangle command output and terminology, which the current audit would not catch because the result is neither a stub nor a short file. If added, it belongs as a separate flag (e.g. `--from es`) rather than as a change to the existing behaviour, so both modes stay available.

## Video — Technical Debt

- **Certification video scripts cannot be translated, only re-authored.** `paths translate` exists for career-path scripts, but there is no equivalent for `certs/*/script.yaml`: `video.generate_cert_script` always authors from the syllabus. Since 2026-08-04 English is the authoring language and everything else is supposed to be a translation, so this is the one place where the pipeline still forces a second authoring pass. The cost is small — a video script is a handful of slides, not 10 KB of content — which is why it is not blocking kcna. Fix by reusing `generator.translate_topic`'s approach: feed the English `script.yaml`, translate only the `voiceover` and title fields, and leave the structure untouched so the slide count and timing cannot drift.
- **Re-render the German path videos.** They are marked complete in docs/STATUS.md but their deterministic scenes were narrated in Spanish by the German voice — `_path_voiceover`/`_domains_voiceover` only handled `en` and fell through to the default for everything else (fixed in `b93418f`). The affected files are `media/paths/*/de/script.yaml`. Re-rendering costs no API budget: the render step calls no model, it only redraws slides and re-runs Piper.
- **Prompt language is an open decision.** The prompt strings in `generator.py`, `tracker.py` and `video.py` are still Spanish while the rest of the code is English, and that is deliberate — they are model input, and the entire existing corpus was produced with them. Translating them would change generated output and invalidate the baseline the quality floor was calibrated against. If they are ever translated, treat it as a content migration: regenerate a sample first, re-measure the floor against it, and decide whether the corpus needs redoing for consistency.

- ~~No Piper voice configured for de/zh~~ **Resolved (2026-07-17)**: Piper does have de/zh voices (`de_DE-thorsten-high`, `zh_CN-huayan-medium`), added to `VOICES` in `core/video.py`. **`ja` remains blocked** — Piper does not have any Japanese voice (full list of supported languages verified against the `rhasspy/piper-voices` repository); another TTS would be needed to narrate in Japanese.
- ~~No CJK font installed~~ **Resolved (2026-07-17)**: `core/video.py` now picks Noto Sans CJK (`google-noto-sans-cjk-fonts`) for zh/ja if installed (falls back to Liberation Sans if not, without breaking) — installed manually on the dev machine with `sudo dnf install google-noto-sans-cjk-fonts`. Only needed on the machine rendering the videos (local Pillow), not in the Docker image — the generated mp4 is baked into the build like any other file in `media/`.

## Labs — what an audit found, 2026-08-08 (design parked, not started)

Full design in `~/.claude/plans/breezy-skipping-spring.md`. Recorded here because
the *measurements* are facts about this repo and would otherwise be lost. Nothing
below is implemented.

**The 342 generated labs share no interface**, because the prompt that writes them
(`generator.py:569-580`) never asked for one:

| Measured over the 342 | |
|---|---|
| With an **executable** `solve`/`fix` arm | **7** |
| With a `verify`/`check` arm | 66 (only 25 signal failure by exit code) |
| Interactive (`read -p`; blocks with no TTY) | 98 |
| Call `sudo`, which `debian:12` does not ship | 94 |
| Require root and exit 1 otherwise | 99 |
| Distinct subcommand names across the corpus | 24 |

The other 335 carry the solution **as a comment**, so `break → verify fails →
solve → verify passes` is impossible today on 98% of the corpus. No codemod turns
a comment into a solution — that number, not the dollar cost, is what decides the
shape of any migration.

**Two defects worth knowing about regardless of whether the design is built:**

1. **Labs are outside the `stale` cycle.** `tracker.py::snapshot_topics` marks a
   topic `stale` when the syllabus changes and `certs.topic_outdated_langs()`
   invalidates content per language — but `generator.py:561` regenerates the lab
   only if the file is absent or `--force` is passed in the authoring language. A
   new exam version leaves the old lab attached to new content, and nothing
   reports it.
2. **`labs.py` runs Kubernetes labs on the student's own machine.** `_up_cluster`
   creates `kind` on the host, calls `kubectl config use-context` **without
   checking the result** (line 148), and then runs an LLM-authored destructive
   script against whatever context was current. The "disposable VM" premise all
   342 headers state is false. Also `_needs_cluster()` picks the environment by
   grepping the script for the string `kubectl`, which misroutes 15 labs.

Measured lab generation cost, from `usage.jsonl` (n=51): median **$0.509**, ~205 s.
Regenerating all 342 is ~**$195** and ~5 quota windows — the windows are the
constraint, not the dollars.

## Labs — Execution Modes (see docs/ORIGINAL_DESIGN.md, SDD section)

Suggested order (each stage reuses the previous one):

1. ~~**Local Docker (free, first).**~~ **Implemented (2026-07-17), but NOT verified against real Docker/kind** — the dev machine where this was written did not have `docker` or `kind` installed, so it was only dry-run tested with mocked subprocess calls. **Test `teach lab up lpi-010-160/2.1` and `teach lab up cka/1.1` on a machine with Docker before offering this to real students.** `labs.py` now dispatches based on the `provider` field in `lab.yaml` (currently always `local`, `terraform` is left for step 3):
   - If the topic's `break_fix.sh` uses `kubectl` (all CKA/CKAD/CKS/KCNA): boots a `kind` (Kubernetes-in-Docker) cluster and runs the script against it. Requires `kind`+`kubectl`+`docker` installed.
   - Otherwise (LPI Linux Essentials): runs the script inside a simple Debian/Ubuntu container as a non-root user (the scripts refuse to run as root). Requires only `docker`.
   - `teach lab status` now checks the actual docker/kind process status instead of blindly trusting the last written `status.yaml` (if the container/cluster died or was manually deleted, it detects it and marks it `failed`).
   - Pending item: generate the explicit `Dockerfile`/`docker-compose.yml` mentioned in the original docs/ORIGINAL_DESIGN.md — the current version runs the container directly using `docker run` (simpler, same result for v1) instead of a versioned compose file; review if compose is worth it when there is demand for multi-container labs.
2. **Exercise Video — Actual Capture, No Mock.** Same principle as the marketing video (factual data is never written by AI — see the path scene in `core/video.py`): spin up the actual container from `lab.yaml`, run `break_fix.sh` for real, and record the session using **asciinema** (`.cast` file, text format, KB not MB, reproducible/scalable, self-hostable player) instead of mocking the terminal with AI or rendering MP4. The AI only writes the voiceover narration (Piper TTS, as already done).
3. **Paid A — BYO-Cloud + Terraform.** Extends the existing contract in `labs.py` (`up`/`down` over `lab/terraform/`): generate the Terraform module per topic, v1 has the student running `terraform apply` using their own credentials (the platform never touches them). A "one-click" mode where the platform runs Terraform with credentials pasted by the student is more convenient but turns the platform into a custodian of third-party cloud credentials — defer until proven demand.
4. **Paid B — Hosted by Me, "Connect" Button → Auto-destruction.**
   Main risk: the platform runs on a home cluster, publicly exposed. **Do not run third-party labs there** — direct blast radius to the home LAN (lab escape, mining, lateral movement). Alternative: ephemeral VM per session in a separate, cheap cloud provider (Hetzner/DO, billing per minute) using the same "toolbox" image, hard timeout (30-60 min), concurrent session limits, web terminal via xterm.js+websocket, and `terraform destroy` upon session close. Also evaluate existing ephemeral sandboxes (E2B, Coder, Gitpod) before building custom isolation hardening.

## Deploy — Technical Debt

- ~~**`make image-cluster` used a fixed `TAG` that could diverge from the Helm release in production without visible errors.**~~ **Resolved (2026-07-16)**:
  Default `TAG` is now `$(shell date +%Y%m%d%H%M%S)` in the Makefile — a fresh timestamp per invocation, instead of a manual sync number between Makefile and Helm. Note: it is still the deployer's responsibility to pass the SAME explicit `TAG=...` to `make image-cluster` and `make deploy-local` in the same run (running `make` twice without an explicit `TAG=` generates two different timestamps and breaks build↔deploy pairing).

## Platform (Long-Term Roadmap, see docs/ORIGINAL_DESIGN.md)

- Multi-provider labs, and a Go lab-runner working against the `lab.yaml`/`terraform/`/`status.yaml` contract.
- **Real user auth.** The admin/admin stub was removed on 2026-07-19; `teach/core/auth.py` is now a deliberate deny-all placeholder (`authenticate` and `has_subscription` both always return `False`) since all content is public and login-free. This only becomes blocking when the paid lab tier ships — that is the thing that needs a real identity (OIDC/social) plus a payment gateway behind it, not the content.
- Improve web presentation: currently displays raw content; needs Markdown rendering, styles, navigation. (low priority).

## Repo Hygiene

- `chart/` stays untracked (a rejected RAG-bot proposal, removed from this file on 2026-10-21: it was superseded on 2026-09-09; its record is in git history);
  the study bot that superseded it is in
  [docs/STUDY_BOT_DESIGN.md](STUDY_BOT_DESIGN.md).
- Registry housekeeping is now `make clean-registry` — see
  [docs/CLEANUP.md](CLEANUP.md) for what fills up and the procedure.
- Source comments and docstrings under `teach/` and `scripts/` are still largely in Spanish, which contradicts the English-only rule in `CLAUDE.md`. Mechanical to fix, but it is a wide diff — worth doing in one dedicated pass rather than drip-feeding it into feature commits.
