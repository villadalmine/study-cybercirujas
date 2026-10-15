# Graph Report - teach-plat  (2026-10-15)

## Corpus Check
- 147 files · ~191,488 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 14 file(s) not represented in the graph (top: (none) 11, .example 1, .service 1)

## Summary
- 1937 nodes · 3917 edges · 121 communities (87 shown, 34 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 133 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `ed1b2688`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Backlog
- lab/cli.py
- api.py
- models_live.py
- video.py
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- claims.py
- generator.py
- labs.py
- Which backend authors better material?
- certs.py
- SnapshotStatusTest
- runner.py
- check
- snapshot_topics
- Changelog
- Platform Architecture Plan
- Removed K8s API Checks
- teach/cli.py
- RejectsDamagedTranslations
- Syllabus Coverage Tests
- _verify_translation
- yaml
- Verifying the material is true — design notes
- ServerSmokeTests
- topic_cost.py
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- main
- Roadmap — where this is and where it goes
- API Facts Verification
- check_claims.py
- DeterminismTests
- make
- problems
- json
- verdict
- Milestone Run Script
- CheckPrTests
- Resume Generation Script
- Project Root
- pathlib
- StoredShapeTests
- search_topics
- has_subscription
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- 1. The code graph (Graphify)
- fix_corrupted_content.py
- steer.py
- ProtocolTests
- publish_if_complete.py
- _agent_completer
- check_provenance.py
- AI certification roadmap
- pipeline.py
- Within one certification (the only fair comparisons; authoring language `en` only)
- EnvScopeTests
- response
- subprocess
- model_comparison.py
- Check curriculum updates
- translation_study.py
- generate_topic
- OpenWiki scope for teach-plat
- video_languages
- The phases
- probe_models.py
- tracker.py
- bot_loop_check.js
- Study bot — design
- login
- catalog.py
- re
- ComprehensionTests
- get
- study.cybercirujas — free, open study material for IT certifications
- CatalogueStateTests
- next_work.py
- FixtureTests
- LanguageTests
- CheckDocsTests
- CLEANUP.md
- Operating the pipeline — for maintainers
- lab.md
- translation.md
- PathLanguageTests
- argparse
- video.md
- check_syllabus.py
- clone_and_run.sh
- Client
- pull_request_template.md
- code.md
- content.md
- docs.md
- prove_labs_cka_pilot.sh
- bad.md
- good.md
- Content Workflow
- normalise_weights
- README.md
- Principles
- probe_languages
- EndpointTests
- Governance
- lab_step.sh
- RegenerateTests
- .teach
- Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)
- LabStepIsolationTests
- .mcp.json
- ReferencesTest
- k8s/study-lab-init.sh
- LabRunnerLifecycleTests
- linux/study-lab-init.sh
- kind/break_fix.sh
- linux/break_fix.sh

## God Nodes (most connected - your core abstractions)
1. `Changelog` - 27 edges
2. `load()` - 25 edges
3. `generate_topic()` - 24 edges
4. `Lab` - 21 edges
5. `run()` - 20 edges
6. `search_topics()` - 19 edges
7. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 19 edges
8. `_verify_translation()` - 18 edges
9. `snapshot_topics()` - 18 edges
10. `kubectl()` - 17 edges

## Surprising Connections (you probably didn't know these)
- `2026-09-10` --references--> `survey()`  [INFERRED]
  CHANGELOG.md → scripts/check_versions.py
- `State of the 548 curated labs (validate, 2026-10-15)` --references--> `kubectl()`  [INFERRED]
  docs/LABS-RUNNER.md → scripts/clean_registry.py
- `Practice: break-and-fix labs` --references--> `kubectl()`  [INFERRED]
  README.md → scripts/clean_registry.py
- `Phase 1 — SHIPPED 2026-09-09` --references--> `usage()`  [INFERRED]
  docs/STUDY_BOT_DESIGN.md → scripts/clean_registry.py
- `2026-07-29` --references--> `find_bad_combos()`  [INFERRED]
  CHANGELOG.md → scripts/fix_corrupted_content.py

## Import Cycles
- None detected.

## Communities (121 total, 34 thin omitted)

### Community 0 - "Backlog"
Cohesion: 0.14
Nodes (12): Backlog, Deploy — Technical Debt, In Progress / Next (Ordering), Labs — Execution Modes (see PLAN.md, SDD section), Pipeline Automation, RAG Study Bot — Proposal Under Review (`chart/`) — superseded, Repo Hygiene, Verifying the material is TRUE (docs/AUDITOR_DESIGN.md) (+4 more)

### Community 1 - "lab/cli.py"
Cohesion: 0.05
Nodes (55): Tests, _banner(), _clone(), cmd_hint(), cmd_list(), cmd_migrate(), cmd_new(), cmd_validate() (+47 more)

### Community 2 - "api.py"
Cohesion: 0.13
Nodes (6): get_cert_video(), get_path_video(), get_paths(), get_topic_preview(), _valid_lang(), _video_info()

### Community 3 - "models_live.py"
Cohesion: 0.06
Nodes (20): main(), Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos, Spend (measured) (+12 more)

### Community 4 - "video.py"
Cohesion: 0.10
Nodes (35): From claude — 2026-08-19: video renders failed 136 times overnight; root cause and fix, Content, Video — Technical Debt, 2026-07-17, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir() (+27 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.06
Nodes (36): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails, From claude — 2026-08-14: where this stands, and how to resume (+28 more)

### Community 6 - "claims.py"
Cohesion: 0.06
Nodes (25): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+17 more)

### Community 7 - "generator.py"
Cohesion: 0.12
Nodes (15): Generation backends, _agent_completer(), complete(), _antigravity_completer(), complete(), _dominant_model(), GeneratorConfigError, _litellm_completer() (+7 more)

### Community 8 - "labs.py"
Cohesion: 0.05
Nodes (34): Labs — what an audit found, 2026-08-08 (design parked, not started), lab_up(), _break_args(), default_spec(), down(), _down_cluster(), _down_container(), enter_hint() (+26 more)

### Community 9 - "Which backend authors better material?"
Cohesion: 0.22
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 10 - "certs.py"
Cohesion: 0.11
Nodes (14): get_cert(), clear_topic_stale(), content_dir(), get_topic(), load(), md_path(), _read(), save() (+6 more)

### Community 12 - "runner.py"
Cohesion: 0.06
Nodes (53): Create a lab that follows the template, How it works, Measured (WSL2 Ubuntu 24.04 on the workstation, Docker 29.8, 2026-10-15), Not done yet, Pinned versions, Quick start, Run a lab from another repository, State of the 548 curated labs (validate, 2026-10-15) (+45 more)

### Community 13 - "check"
Cohesion: 0.13
Nodes (5): _reusable(), check(), rules(), QualityFloorTest, QualityThresholdsTest

### Community 14 - "snapshot_topics"
Cohesion: 0.14
Nodes (12): 2026-07-16, _apply_snapshot_status(), snapshot_topics(), _topic_identity(), 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically (+4 more)

### Community 15 - "Changelog"
Cohesion: 0.09
Nodes (23): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-19, 2026-07-27, 2026-07-28, 2026-07-29, 2026-09-10 (+15 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.14
Nodes (14): Catalog by Categories, CLI, Code Architecture, Data Model, Decoupled Lab Runner (Future, Go), Design Principles, Educational Platform, Execution Modes + Exercise Videos (SDD — evaluation, pending implementation) (+6 more)

### Community 18 - "teach/cli.py"
Cohesion: 0.09
Nodes (17): cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script(), lab_down() (+9 more)

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.18
Nodes (3): objective_ids(), _reject_unreadable_syllabus(), SyllabusCoverageTests

### Community 21 - "_verify_translation"
Cohesion: 0.08
Nodes (21): 2026-08-03, 2026-08-04, Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Rules, Verification: what is proven, and what is only assumed (+13 more)

### Community 22 - "yaml"
Cohesion: 0.14
Nodes (11): frozen(), _same_version(), state(), survey(), cert_topics(), check(), lab_cell(), lang_cell() (+3 more)

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 25 - "ServerSmokeTests"
Cohesion: 0.16
Nodes (4): _connect(), _connect_ex(), _host(), ServerSmokeTests

### Community 26 - "topic_cost.py"
Cohesion: 0.16
Nodes (7): by_topic(), dominant(), main(), records(), _cmd(), test_job_ids_are_unique_across_workflows(), test_k8s_inner_dockerd_listens_on_the_unix_socket_only()

### Community 27 - "Developers — use the API, run your own copy, build on it"
Cohesion: 0.20
Nodes (10): Building features on it, Developers — use the API, run your own copy, build on it, DORA, concretely, Keeping this page true, Licence, Staying in sync with upstream, ⚠️ The API is beta, and hosted on a home cluster, ⚠️ The content is AI-generated — and that carries real risk (+2 more)

### Community 28 - "clean_registry.py"
Cohesion: 0.42
Nodes (5): deployed_tags(), in_registry(), kubectl(), main(), usage()

### Community 29 - "main"
Cohesion: 0.21
Nodes (8): generate(), generate_with_retries(), main(), pending(), _sort_key(), me(), mine(), owner()

### Community 30 - "Roadmap — where this is and where it goes"
Cohesion: 0.25
Nodes (8): Current focus — set 2026-09-11, Roadmap — where this is and where it goes, Smaller things, when there is an appetite, Standing decisions worth not re-litigating, Study bot — the phases after this one, What is next, Where it is, Where we left off — 2026-09-30

### Community 31 - "API Facts Verification"
Cohesion: 0.43
Nodes (4): check(), main(), spec_kinds(), tracked_versions()

### Community 32 - "check_claims.py"
Cohesion: 0.36
Nodes (3): ask(), main(), references()

### Community 34 - "make"
Cohesion: 0.15
Nodes (14): Open — worth someone's time, 2026-10-15, Checks that must pass, Contributing, Conventions, Merging and deploying the site, Provenance is mandatory, Pull requests (+6 more)

### Community 35 - "problems"
Cohesion: 0.28
Nodes (4): main(), problems(), _skip(), _VendorTagLoader

### Community 36 - "json"
Cohesion: 0.12
Nodes (13): 2026-09-11, evidence(), main(), classify(), main(), main(), probe(), record() (+5 more)

### Community 37 - "verdict"
Cohesion: 0.16
Nodes (7): off_switch(), rejects_reasoning(), thinking_mode(), thought(), tool_call_of(), tool_verdict(), verdict()

### Community 44 - "StoredShapeTests"
Cohesion: 0.10
Nodes (9): accepted(), _blank(), _known_models(), load(), path(), record(), _write(), AcceptanceTests (+1 more)

### Community 45 - "search_topics"
Cohesion: 0.06
Nodes (18): _fold(), get_syllabus(), get_topic(), _informative(), list_certs(), search_topics(), _terms(), _readable() (+10 more)

### Community 46 - "has_subscription"
Cohesion: 0.20
Nodes (8): Platform (Long-Term Roadmap, see PLAN.md), 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, me(), authenticate(), has_subscription()

### Community 47 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.18
Nodes (10): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith), Integration cautions (this repo specifically) (+2 more)

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "fix_corrupted_content.py"
Cohesion: 0.13
Nodes (11): _cert_topic_ids(), find_bad_combos(), _finish(), main(), _publish_if_complete(), _record_quota_block(), _refresh_status(), render_ready_videos() (+3 more)

### Community 50 - "steer.py"
Cohesion: 0.20
Nodes (8): main(), _cert_block(), create_block(), main(), set_key(), show(), languages_for(), targets()

### Community 52 - "publish_if_complete.py"
Cohesion: 0.39
Nodes (5): complete_certs(), main(), publish(), _record(), _save()

### Community 53 - "_agent_completer"
Cohesion: 0.43
Nodes (4): dominant(), effective(), main(), recent()

### Community 54 - "check_provenance.py"
Cohesion: 0.22
Nodes (7): check_cert(), main(), _topics(), find_missing_videos(), is_complete(), _topic_ids(), video_languages()

### Community 55 - "AI certification roadmap"
Cohesion: 0.22
Nodes (9): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 1 — AI fundamentals (extends the three cloud careers), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters (+1 more)

### Community 56 - "pipeline.py"
Cohesion: 0.13
Nodes (13): budget(), certs(), default_languages(), in_milestone(), is_fatal(), is_retryable(), load(), milestone() (+5 more)

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.25
Nodes (8): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, mcpa, Within one certification (the only fair comparisons; authoring language `en` only)

### Community 59 - "response"
Cohesion: 0.11
Nodes (7): 6. Where the value actually is (owner's question, 2026-08-18), Languages, translate(), OffSwitchTests, response(), ThinkingTests, VerdictTests

### Community 61 - "subprocess"
Cohesion: 0.14
Nodes (12): graphify_bin(), main(), normalized(), rebuild_in_copy(), regenerate(), touches_graph_sources(), embedded_text(), fetch() (+4 more)

### Community 62 - "model_comparison.py"
Cohesion: 0.07
Nodes (23): backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main(), _md_table() (+15 more)

### Community 63 - "Check curriculum updates"
Cohesion: 0.50
Nodes (3): Check curriculum updates, Notes, Steps

### Community 64 - "translation_study.py"
Cohesion: 0.15
Nodes (7): citations(), main(), status(), evaluate(), main(), master_key(), _free_port()

### Community 65 - "generate_topic"
Cohesion: 0.24
Nodes (6): cert_generate(), generate_cert(), generate_topic(), _topic_context(), _write_meta(), First, the thing that surprises everyone

### Community 66 - "OpenWiki scope for teach-plat"
Cohesion: 0.33
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 67 - "video_languages"
Cohesion: 0.47
Nodes (3): main(), pending_topics(), run()

### Community 68 - "The phases"
Cohesion: 0.13
Nodes (15): Can it read what we send it? (2026-09-11, second pass), Phase 1.5 — BUILT 2026-09-14 (option A), Phase 1.5 — closing the loop: checks that improve the page, Phase 1 — feedback, and the probe that answers it (2026-09-11), Phase 1 — SHIPPED 2026-09-09, Phase 1 — topic chat with a task harness, Phase 2 — BUILT 2026-09-14, Phase 2 — questions across one certification (+7 more)

### Community 69 - "probe_models.py"
Cohesion: 0.14
Nodes (11): ask(), ask_retrying(), catalogue_state(), main(), material(), _price(), probe_one(), probe_tools() (+3 more)

### Community 70 - "tracker.py"
Cohesion: 0.12
Nodes (14): main(), tracker_sync(), save(), _ai_yaml(), fetch_text(), generate_paths(), _get(), _get_bytes() (+6 more)

### Community 71 - "bot_loop_check.js"
Cohesion: 0.06
Nodes (24): fs, KEY, line, ONLY, path, PORT, REPO, SHAPES (+16 more)

### Community 72 - "Study bot — design"
Cohesion: 0.20
Nodes (10): Alternatives considered, Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Study bot — design, The insight: explicit selection replaces retrieval (+2 more)

### Community 73 - "login"
Cohesion: 0.21
Nodes (7): BotUsage, login(), LoginBody, logout(), post_bot_used(), require_subscriber(), require_user()

### Community 74 - "catalog.py"
Cohesion: 0.15
Nodes (12): _status_snapshot(), add_cert(), _BlockDumper, catalog_path(), get_cert(), list_certs(), load(), load_models() (+4 more)

### Community 75 - "re"
Cohesion: 0.07
Nodes (25): anchors(), check_file(), generated_checks(), main(), make_targets(), prose_lines(), slug(), teach_commands() (+17 more)

### Community 77 - "get"
Cohesion: 0.13
Nodes (7): get_bot_stats(), get_catalog(), get_langs(), get_search(), get_status(), healthz(), index()

### Community 78 - "study.cybercirujas — free, open study material for IT certifications"
Cohesion: 0.15
Nodes (13): AI-generated content, Ask questions about the material with a local model (RAG), Certifications, Command line, Contributing, For maintainers, Licence, Practice: break-and-fix labs (+5 more)

### Community 80 - "next_work.py"
Cohesion: 0.47
Nodes (3): main(), survey(), _topic_count()

### Community 84 - "CLEANUP.md"
Cohesion: 0.22
Nodes (7): Documentation audit — 2026-10-14, Fixed in this pass, `graphify-out/` and `openwiki/` — what they are and whether they belong, Needs the owner's decision, Model Comparison, What a quota window buys (761,850 output tokens/window, measured on this machine), Whole corpus, per model (context, not a verdict)

### Community 85 - "Operating the pipeline — for maintainers"
Cohesion: 0.22
Nodes (9): Content process, Deploying to Kubernetes, Environment variables, Keeping it honest over time, Operating the pipeline — for maintainers, Quality, Quickstart (maintainers), Running it yourself, without guessing (+1 more)

### Community 86 - "lab.md"
Cohesion: 0.22
Nodes (8): Depends on, Evidence, How to test it from a clean clone, Kind, Lab cycle, Provenance, Risk and rollback, What and why

### Community 87 - "translation.md"
Cohesion: 0.22
Nodes (8): Depends on, Evidence, How to test it from a clean clone, Kind, Provenance, Risk and rollback, Translation review, What and why

### Community 89 - "argparse"
Cohesion: 0.13
Nodes (9): main(), main(), table(), main(), status_rows(), table(), main(), main() (+1 more)

### Community 90 - "video.md"
Cohesion: 0.22
Nodes (8): Depends on, Evidence, How to test it from a clean clone, Kind, Provenance, Risk and rollback, Video, What and why

### Community 91 - "check_syllabus.py"
Cohesion: 0.31
Nodes (4): load_syllabus(), main(), smells(), upstream_objectives()

### Community 92 - "clone_and_run.sh"
Cohesion: 0.33
Nodes (7): fail(), get(), ok(), PYTHONPATH, clone_and_run.sh script, step(), TEACH_OFFLINE

### Community 94 - "pull_request_template.md"
Cohesion: 0.25
Nodes (7): Depends on, Evidence, How to test it from a clean clone, Kind, Provenance, Risk and rollback, What and why

### Community 95 - "code.md"
Cohesion: 0.25
Nodes (7): Depends on, Evidence, How to test it from a clean clone, Kind, Provenance, Risk and rollback, What and why

### Community 96 - "content.md"
Cohesion: 0.25
Nodes (7): Depends on, Evidence, How to test it from a clean clone, Kind, Provenance, Risk and rollback, What and why

### Community 97 - "docs.md"
Cohesion: 0.25
Nodes (7): Depends on, Evidence, How to test it from a clean clone, Kind, Provenance, Risk and rollback, What and why

### Community 99 - "bad.md"
Cohesion: 0.25
Nodes (7): Depends on, Evidence, How to test it from a clean clone, Kind, Provenance, Risk and rollback, What and why

### Community 100 - "good.md"
Cohesion: 0.25
Nodes (7): Depends on, Evidence, How to test it from a clean clone, Kind, Provenance, Risk and rollback, What and why

### Community 101 - "Content Workflow"
Cohesion: 0.25
Nodes (8): Backends, Content Workflow, Everything the pipeline produces is declared in `pipeline.yaml`, Failure modes worth knowing, Language flow: author once in English, translate outwards, Switching to Gemini (or any CLI agent), Translating instead of re-authoring, Unattended runs and quota

### Community 102 - "normalise_weights"
Cohesion: 0.29
Nodes (5): From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives, What I need from you, What is now enforced, so this cannot recur, What this means for your work, normalise_weights()

### Community 104 - "Principles"
Cohesion: 0.29
Nodes (7): 1. Information sovereignty, 2. Curriculum-as-Code, 3. Determinism, 4. With AI or without AI: the same pipeline and the same validator, 5. Honest about limits, 6. Open by default, Principles

### Community 105 - "probe_languages"
Cohesion: 0.29
Nodes (4): Re-probing, and two things the second run taught (2026-09-14), detect_language(), graded(), probe_languages()

### Community 107 - "Governance"
Cohesion: 0.33
Nodes (6): Becoming a maintainer, Code of conduct, Day-to-day changes, Governance, Proposals (RFCs) — for anything that changes how the project works, Who maintains what, today

### Community 108 - "lab_step.sh"
Cohesion: 0.53
Nodes (4): fail(), ok(), ours(), lab_step.sh script

### Community 111 - "Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)"
Cohesion: 0.40
Nodes (5): Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), German translation: working recipe found, blocked on timeout, Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09), What I finished, What I need from you

### Community 113 - ".mcp.json"
Cohesion: 0.67
Nodes (3): .venv/bin/python3, graphify, teach

## Knowledge Gaps
- **4 isolated node(s):** `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE`, `PYTHONPATH`
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 841 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **34 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `kubectl()` connect `clean_registry.py` to `Backlog`, `make`, `video.py`, `labs.py`, `runner.py`, `study.cybercirujas — free, open study material for IT certifications`, `_verify_translation`, `Operating the pipeline — for maintainers`, `Developers — use the API, run your own copy, build on it`, `subprocess`, `Roadmap — where this is and where it goes`?**
  _High betweenness centrality (0.049) - this node is a cross-community bridge._
- **What connects `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE` to the rest of the system?**
  _4 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Backlog` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._
- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` to `make`, `video.py`, `normalise_weights`, `Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)`, `README.md`?**
  _High betweenness centrality (0.045) - this node is a cross-community bridge._
- **Should `lab/cli.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05067920585161965 - nodes in this community are weakly interconnected._
- **Why does `Backlog` connect `Backlog` to `labs.py`, `video.py`, `has_subscription`, `README.md`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Should `api.py` be split into smaller, more focused modules?**
  _Cohesion score 0.13450292397660818 - nodes in this community are weakly interconnected._