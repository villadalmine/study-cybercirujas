# Graph Report - w11  (2026-10-15)

## Corpus Check
- 158 files · ~212,732 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 15 file(s) not represented in the graph (top: (none) 12, .example 1, .service 1)

## Summary
- 2285 nodes · 4600 edges · 143 communities (90 shown, 53 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 152 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `d7bd8520`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- topic_content
- lab/cli.py
- scaffold
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
- The loop
- Changelog
- Platform Architecture Plan
- Removed K8s API Checks
- teach/cli.py
- lab/cli.py
- Syllabus Coverage Tests
- _verify_translation
- check_versions.py
- Verifying the material is true — design notes
- ServerSmokeTests
- The routine, start to finish
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- main
- Roadmap — where this is and where it goes
- check_pr.py
- RejectsDamagedTranslations
- DeterminismTests
- make
- argparse
- json
- probe_models.py
- Milestone Run Script
- CheckPrTests
- Resume Generation Script
- Project Root
- StoredShapeTests
- search_topics
- has_subscription
- certs.py
- 1. The code graph (Graphify)
- fix_corrupted_content.py
- pipeline.py
- ProtocolTests
- publish_if_complete.py
- test_lpic2_200_1_review.py
- api.py
- AI certification roadmap
- Content Status
- Within one certification (the only fair comparisons; authoring language `en` only)
- EnvScopeTests
- verdict
- subprocess
- steer.py
- status_matrix.py
- test_source_chain.py
- Study bot — design
- OpenWiki scope for teach-plat
- QualityOnlyTests
- The phases
- check_syllabus.py
- tracker.py
- bot_loop_check.js
- run_batch.py
- EndpointTests
- catalog.py
- probe_languages
- ComprehensionTests
- BlockTests
- study.cybercirujas — free, open study material for IT certifications
- CatalogueStateTests
- response
- FixtureTests
- LanguageTests
- CheckDocsTests
- Documentation audit — 2026-10-14
- IncrementalContractTests
- lab.md
- translation.md
- PathLanguageTests
- check_provenance.py
- video.md
- WhereItRanTests
- clone_and_run.sh
- Client
- pull_request_template.md
- code.md
- content.md
- docs.md
- prove_labs_cka_pilot.sh
- bad.md
- good.md
- Contributing
- model_comparison.py
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- check_source_chain.py
- ReviewTests
- EndpointTests
- CONTRIBUTING.md
- lab_step.sh
- RegenerateTests
- .teach
- LabStepIsolationTests
- .mcp.json
- k8s/study-lab-init.sh
- LabRunnerLifecycleTests
- linux/study-lab-init.sh
- kind/break_fix.sh
- linux/break_fix.sh
- ScopeTests
- _prompt_on_stdin
- AuthorshipTests
- quality_score.py
- api.py
- study-lab — break/fix labs in a throwaway container
- OwnedTeardownTests
- MainTests
- test_legal_notice.py
- re
- _script_user
- _exec_script_cmd
- sitecustomize.py
- Automated review (Copilot)
- _owner_label
- ReferencesTest
- _split_answer
- test_mcp_server.py
- EnterHintTests
- check_config.py
- check_api_facts.py
- verify_workflow
- CheckUpdatesDocTests
- CitationsHeadingTests

## God Nodes (most connected - your core abstractions)
1. `Changelog` - 27 edges
2. `load()` - 25 edges
3. `generate_topic()` - 24 edges
4. `Lab` - 21 edges
5. `_verify_translation()` - 20 edges
6. `run()` - 20 edges
7. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 20 edges
8. `search_topics()` - 19 edges
9. `block_for()` - 18 edges
10. `snapshot_topics()` - 18 edges

## Surprising Connections (you probably didn't know these)
- `2026-09-10` --references--> `survey()`  [INFERRED]
  CHANGELOG.md → scripts/check_versions.py
- `State of the 548 curated labs (validate, 2026-10-15)` --references--> `kubectl()`  [INFERRED]
  docs/LABS-RUNNER.md → scripts/clean_registry.py
- `Practice: break-and-fix labs` --references--> `kubectl()`  [INFERRED]
  README.md → scripts/clean_registry.py
- `Phase 1 — SHIPPED 2026-09-09` --references--> `usage()`  [INFERRED]
  docs/STUDY_BOT_DESIGN.md → scripts/clean_registry.py
- `2026-09-14` --references--> `probe_languages()`  [INFERRED]
  CHANGELOG.md → scripts/probe_models.py

## Import Cycles
- None detected.

## Communities (143 total, 53 thin omitted)

### Community 0 - "topic_content"
Cohesion: 0.12
Nodes (13): Backlog, Content, Deploy — Technical Debt, In Progress / Next (Ordering), Labs — Execution Modes (see PLAN.md, SDD section), Pipeline Automation, RAG Study Bot — Proposal Under Review (`chart/`) — superseded, Repo Hygiene (+5 more)

### Community 1 - "lab/cli.py"
Cohesion: 0.06
Nodes (45): Tests, derived_from(), infer_contract(), load(), load_schema(), migrate(), normalize(), schema_errors() (+37 more)

### Community 2 - "scaffold"
Cohesion: 0.18
Nodes (4): default_spec(), scaffold(), validate_spec(), ContractTests

### Community 3 - "models_live.py"
Cohesion: 0.15
Nodes (9): main(), annotate(), compare(), moved(), per_million(), AnnotateTests, catalogue(), CompareTests (+1 more)

### Community 4 - "video.py"
Cohesion: 0.11
Nodes (32): Video — Technical Debt, 2026-07-17, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat(), _domains_voiceover() (+24 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.05
Nodes (42): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails, From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives (+34 more)

### Community 6 - "claims.py"
Cohesion: 0.10
Nodes (9): main(), active(), claim(), is_claimed(), _path(), _try_lock(), _unlock(), ClaimTest (+1 more)

### Community 7 - "generator.py"
Cohesion: 0.12
Nodes (18): Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), German translation: working recipe found, blocked on timeout, Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09), What I finished, What I need from you, _agent_completer(), complete(), _antigravity_completer() (+10 more)

### Community 8 - "labs.py"
Cohesion: 0.17
Nodes (20): Labs — what an audit found, 2026-08-08 (design parked, not started), _break_args(), down(), _down_cluster(), enter_hint(), lab_dir(), _lab_name(), LabError (+12 more)

### Community 9 - "Which backend authors better material?"
Cohesion: 0.22
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 11 - "SnapshotStatusTest"
Cohesion: 0.21
Nodes (3): _apply_snapshot_status(), _topic_identity(), SnapshotStatusTest

### Community 12 - "runner.py"
Cohesion: 0.07
Nodes (43): build(), check(), container_name(), _docker(), down(), ensure_image(), image_for(), _in_time() (+35 more)

### Community 13 - "check"
Cohesion: 0.13
Nodes (5): _reusable(), check(), rules(), QualityFloorTest, QualityThresholdsTest

### Community 14 - "The loop"
Cohesion: 0.12
Nodes (16): 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 4. Status, 5. Commit, Backends, Content Workflow (+8 more)

### Community 15 - "Changelog"
Cohesion: 0.07
Nodes (30): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-19, 2026-07-27, 2026-07-28, 2026-08-03, 2026-09-10 (+22 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.14
Nodes (14): Catalog by Categories, CLI, Code Architecture, Data Model, Decoupled Lab Runner (Future, Go), Design Principles, Educational Platform, Execution Modes + Exercise Videos (SDD — evaluation, pending implementation) (+6 more)

### Community 18 - "teach/cli.py"
Cohesion: 0.09
Nodes (18): cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script(), lab_down() (+10 more)

### Community 19 - "lab/cli.py"
Cohesion: 0.20
Nodes (11): _banner(), _clone(), cmd_hint(), cmd_list(), cmd_migrate(), cmd_new(), cmd_validate(), _lab_dir() (+3 more)

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.18
Nodes (3): objective_ids(), _reject_unreadable_syllabus(), SyllabusCoverageTests

### Community 21 - "_verify_translation"
Cohesion: 0.12
Nodes (13): Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results, Three bugs this study found in our own checks, Translating is not the same deliverable as authoring, What this actually saves (+5 more)

### Community 22 - "check_versions.py"
Cohesion: 0.16
Nodes (11): frozen(), main(), _same_version(), state(), survey(), add_cert(), load(), save() (+3 more)

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 26 - "The routine, start to finish"
Cohesion: 0.12
Nodes (17): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+9 more)

### Community 27 - "Developers — use the API, run your own copy, build on it"
Cohesion: 0.20
Nodes (10): Building features on it, Developers — use the API, run your own copy, build on it, DORA, concretely, Keeping this page true, Licence, Staying in sync with upstream, ⚠️ The API is beta, and hosted on a home cluster, ⚠️ The content is AI-generated — and that carries real risk (+2 more)

### Community 28 - "clean_registry.py"
Cohesion: 0.42
Nodes (5): deployed_tags(), in_registry(), kubectl(), main(), usage()

### Community 29 - "main"
Cohesion: 0.17
Nodes (9): find_missing_videos(), main(), strip_fences_in_place(), _usable_translate_backend(), main(), me(), mine(), owner() (+1 more)

### Community 30 - "Roadmap — where this is and where it goes"
Cohesion: 0.25
Nodes (8): Current focus — set 2026-09-11, Roadmap — where this is and where it goes, Smaller things, when there is an appetite, Standing decisions worth not re-litigating, Study bot — the phases after this one, What is next, Where it is, Where we left off — 2026-09-30

### Community 31 - "check_pr.py"
Cohesion: 0.09
Nodes (21): authorship(), base_texts(), _cells(), changed_files(), check(), cited_runs(), code_lines_changed(), declared() (+13 more)

### Community 34 - "make"
Cohesion: 0.25
Nodes (7): Open — worth someone's time, Set up, once, Running your own copy, Unattended generation timer, Use it in 2 minutes, new_lab(), make()

### Community 35 - "argparse"
Cohesion: 0.12
Nodes (10): main(), main(), table(), main(), status_rows(), table(), main(), main() (+2 more)

### Community 36 - "json"
Cohesion: 0.10
Nodes (15): 2026-09-11, evidence(), main(), gh_api(), _record_quota_block(), classify(), main(), main() (+7 more)

### Community 37 - "probe_models.py"
Cohesion: 0.14
Nodes (11): ask(), ask_retrying(), catalogue_state(), main(), material(), _price(), probe_one(), probe_tools() (+3 more)

### Community 44 - "StoredShapeTests"
Cohesion: 0.10
Nodes (9): accepted(), _blank(), _known_models(), load(), path(), record(), _write(), AcceptanceTests (+1 more)

### Community 45 - "search_topics"
Cohesion: 0.06
Nodes (18): topics(), _fold(), get_syllabus(), get_topic(), _informative(), list_certs(), search_topics(), _terms() (+10 more)

### Community 46 - "has_subscription"
Cohesion: 0.20
Nodes (8): Platform (Long-Term Roadmap, see PLAN.md), 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, me(), authenticate(), has_subscription()

### Community 47 - "certs.py"
Cohesion: 0.13
Nodes (16): cert_generate(), clear_topic_stale(), content_dir(), load(), md_path(), _read(), save(), scaffold() (+8 more)

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "fix_corrupted_content.py"
Cohesion: 0.10
Nodes (13): 2026-07-29, 2026-08-04, _cert_topic_ids(), find_bad_combos(), _finish(), _publish_if_complete(), _refresh_status(), render_ready_videos() (+5 more)

### Community 50 - "pipeline.py"
Cohesion: 0.16
Nodes (12): budget(), default_languages(), in_milestone(), is_fatal(), is_retryable(), load(), milestone(), milestone_targets() (+4 more)

### Community 52 - "publish_if_complete.py"
Cohesion: 0.29
Nodes (7): complete_certs(), is_complete(), main(), publish(), _record(), _save(), _topic_ids()

### Community 53 - "test_lpic2_200_1_review.py"
Cohesion: 0.07
Nodes (21): AlertsTest, CitationsTest, ConntrackLabTest, ConntrackSizeTest, CpuPressureTest, LabContractTest, ListenQueueTest, MathisTest (+13 more)

### Community 54 - "api.py"
Cohesion: 0.08
Nodes (15): get_bot_stats(), get_catalog(), get_cert(), get_cert_video(), get_langs(), get_path_video(), get_paths(), get_search() (+7 more)

### Community 55 - "AI certification roadmap"
Cohesion: 0.25
Nodes (8): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters, Watchlist — official, but they fail a filter today

### Community 56 - "Content Status"
Cohesion: 0.13
Nodes (11): Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos, Quality, Spend (measured) (+3 more)

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.18
Nodes (11): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, mcpa, Model Comparison (+3 more)

### Community 59 - "verdict"
Cohesion: 0.16
Nodes (7): off_switch(), rejects_reasoning(), thinking_mode(), thought(), tool_call_of(), tool_verdict(), verdict()

### Community 61 - "subprocess"
Cohesion: 0.15
Nodes (12): graphify_bin(), main(), normalized(), rebuild_in_copy(), regenerate(), touches_graph_sources(), embedded_text(), fetch() (+4 more)

### Community 62 - "steer.py"
Cohesion: 0.16
Nodes (10): 2026-10-15, main(), _cert_block(), create_block(), main(), set_key(), show(), certs() (+2 more)

### Community 63 - "status_matrix.py"
Cohesion: 0.18
Nodes (10): cert_topics(), check(), lab_cell(), lang_cell(), _quality_section(), refresh(), _render(), _write() (+2 more)

### Community 64 - "test_source_chain.py"
Cohesion: 0.18
Nodes (5): citations(), main(), status(), section(), _free_port()

### Community 65 - "Study bot — design"
Cohesion: 0.22
Nodes (9): Alternatives considered, Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Study bot — design, The insight: explicit selection replaces retrieval (+1 more)

### Community 66 - "OpenWiki scope for teach-plat"
Cohesion: 0.40
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 68 - "The phases"
Cohesion: 0.13
Nodes (15): Can it read what we send it? (2026-09-11, second pass), Phase 1.5 — BUILT 2026-09-14 (option A), Phase 1.5 — closing the loop: checks that improve the page, Phase 1 — feedback, and the probe that answers it (2026-09-11), Phase 1 — SHIPPED 2026-09-09, Phase 1 — topic chat with a task harness, Phase 2 — BUILT 2026-09-14, Phase 2 — questions across one certification (+7 more)

### Community 69 - "check_syllabus.py"
Cohesion: 0.31
Nodes (4): load_syllabus(), main(), smells(), upstream_objectives()

### Community 70 - "tracker.py"
Cohesion: 0.12
Nodes (13): 2026-07-16, Phase 1 — AI fundamentals (extends the three cloud careers), tracker_sync(), _ai_yaml(), fetch_text(), _get(), _get_bytes(), normalise_weights() (+5 more)

### Community 71 - "bot_loop_check.js"
Cohesion: 0.06
Nodes (24): fs, KEY, line, ONLY, path, PORT, REPO, SHAPES (+16 more)

### Community 72 - "run_batch.py"
Cohesion: 0.32
Nodes (4): generate(), generate_with_retries(), pending(), _sort_key()

### Community 74 - "catalog.py"
Cohesion: 0.16
Nodes (10): _status_snapshot(), _BlockDumper, catalog_path(), get_cert(), list_certs(), load_models(), models_path(), root() (+2 more)

### Community 75 - "probe_languages"
Cohesion: 0.29
Nodes (4): Re-probing, and two things the second run taught (2026-09-14), detect_language(), graded(), probe_languages()

### Community 78 - "study.cybercirujas — free, open study material for IT certifications"
Cohesion: 0.15
Nodes (13): AI-generated content, Ask questions about the material with a local model (RAG), ⚖️ Aviso Legal y de Marcas Registradas / Legal & Trademark Disclaimer, Certifications, Contributing, For maintainers, Licence, Practice: break-and-fix labs (+5 more)

### Community 80 - "response"
Cohesion: 0.06
Nodes (20): 6. Where the value actually is (owner's question, 2026-08-18), Checking curriculum updates, Content process, Deploying to Kubernetes, Environment variables, Keeping it honest over time, Languages, Operating the pipeline — for maintainers (+12 more)

### Community 84 - "Documentation audit — 2026-10-14"
Cohesion: 0.50
Nodes (4): Documentation audit — 2026-10-14, Fixed in this pass, `graphify-out/` and `openwiki/` — what they are and whether they belong, Needs the owner's decision

### Community 86 - "lab.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Lab cycle (+4 more)

### Community 87 - "translation.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+4 more)

### Community 89 - "check_provenance.py"
Cohesion: 0.60
Nodes (3): check_cert(), main(), _topics()

### Community 90 - "video.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+4 more)

### Community 92 - "clone_and_run.sh"
Cohesion: 0.33
Nodes (7): fail(), get(), ok(), PYTHONPATH, clone_and_run.sh script, step(), TEACH_OFFLINE

### Community 93 - "Client"
Cohesion: 0.26
Nodes (3): Tools / function calling — evaluated 2026-09-09, wrapped(), Client

### Community 94 - "pull_request_template.md"
Cohesion: 0.17
Nodes (11): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+3 more)

### Community 95 - "code.md"
Cohesion: 0.17
Nodes (11): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+3 more)

### Community 96 - "content.md"
Cohesion: 0.17
Nodes (11): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+3 more)

### Community 97 - "docs.md"
Cohesion: 0.17
Nodes (11): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+3 more)

### Community 99 - "bad.md"
Cohesion: 0.18
Nodes (10): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Provenance, Risk and rollback (+2 more)

### Community 100 - "good.md"
Cohesion: 0.18
Nodes (10): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Provenance, Risk and rollback (+2 more)

### Community 101 - "Contributing"
Cohesion: 0.20
Nodes (10): Agents, Checks that must pass, Contributing, Conventions, Labels, Licence and conduct, Merging and deploying the site, Pull requests (+2 more)

### Community 102 - "model_comparison.py"
Cohesion: 0.06
Nodes (30): backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main(), _md_table() (+22 more)

### Community 103 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.18
Nodes (10): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith), Integration cautions (this repo specifically) (+2 more)

### Community 104 - "check_source_chain.py"
Cohesion: 0.09
Nodes (11): baseline(), Chain, frontmatter(), load_yaml(), main(), rel(), chain_sha256(), translation_source_sha256() (+3 more)

### Community 107 - "CONTRIBUTING.md"
Cohesion: 0.22
Nodes (7): Code of Conduct, Becoming a maintainer, Code of conduct, Day-to-day changes, Governance, Proposals (RFCs) — for anything that changes how the project works, Who maintains what, today

### Community 108 - "lab_step.sh"
Cohesion: 0.53
Nodes (4): fail(), ok(), ours(), lab_step.sh script

### Community 113 - ".mcp.json"
Cohesion: 0.67
Nodes (3): .venv/bin/python3, graphify, teach

### Community 124 - "quality_score.py"
Cohesion: 0.06
Nodes (35): _deliberate(), findings(), main(), main(), problems(), _skip(), _VendorTagLoader, catalogue() (+27 more)

### Community 125 - "api.py"
Cohesion: 0.21
Nodes (7): BotUsage, login(), LoginBody, logout(), post_bot_used(), require_subscriber(), require_user()

### Community 126 - "study-lab — break/fix labs in a throwaway container"
Cohesion: 0.06
Nodes (25): No braindumps, no NDA material, Provenance is mandatory, Raising a topic's quality score, What you can contribute, Create a lab that follows the template, How it works, Measured (WSL2 Ubuntu 24.04 on the workstation, Docker 29.8, 2026-10-15), Not done yet (+17 more)

### Community 129 - "test_legal_notice.py"
Cohesion: 0.33
Nodes (3): legal_section(), LegalNoticeTests, owner()

### Community 131 - "re"
Cohesion: 0.13
Nodes (13): ask(), main(), references(), anchors(), check_file(), generated_checks(), main(), make_targets() (+5 more)

### Community 134 - "sitecustomize.py"
Cohesion: 0.47
Nodes (3): _connect(), _connect_ex(), _host()

### Community 137 - "Automated review (Copilot)"
Cohesion: 0.33
Nodes (6): Authorship: who wrote it, who found what, who fixed it, Automated review (Copilot), How it behaves, How we work with it, Recording a review in the material, When a PR is ready

### Community 146 - "check_config.py"
Cohesion: 0.17
Nodes (8): Generation backends, dominant(), effective(), main(), recent(), _cli_env(), generation(), CliEnvTest

### Community 148 - "check_api_facts.py"
Cohesion: 0.18
Nodes (7): check(), main(), spec_kinds(), tracked_versions(), evaluate(), main(), master_key()

## Knowledge Gaps
- **4 isolated node(s):** `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE`, `PYTHONPATH`
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 956 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **53 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `kubectl()` connect `clean_registry.py` to `topic_content`, `make`, `video.py`, `labs.py`, `study.cybercirujas — free, open study material for IT certifications`, `Changelog`, `_verify_translation`, `Roadmap — where this is and where it goes`, `Developers — use the API, run your own copy, build on it`, `subprocess`, `study-lab — break/fix labs in a throwaway container`?**
  _High betweenness centrality (0.041) - this node is a cross-community bridge._
- **What connects `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE` to the rest of the system?**
  _4 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `topic_content` be split into smaller, more focused modules?**
  _Cohesion score 0.11764705882352941 - nodes in this community are weakly interconnected._
- **Why does `_verify_translation()` connect `_verify_translation` to `RejectsDamagedTranslations`, `generator.py`, `The loop`, `Changelog`, `fix_corrupted_content.py`, `check_api_facts.py`, `quality_score.py`, `study-lab — break/fix labs in a throwaway container`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Should `lab/cli.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06095481670929241 - nodes in this community are weakly interconnected._
- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` to `make`, `generator.py`, `README.md`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._
- **Should `models_live.py` be split into smaller, more focused modules?**
  _Cohesion score 0.1452991452991453 - nodes in this community are weakly interconnected._