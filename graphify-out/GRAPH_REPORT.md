# Graph Report - study-cybercirujas  (2026-10-16)

## Corpus Check
- 165 files · ~226,601 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 17 file(s) not represented in the graph (top: (none) 13, .example 1, .service 1)

## Summary
- 2458 nodes · 4906 edges · 175 communities (113 shown, 62 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 157 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `41246af4`
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
- Content Status
- Verifying the material is true — design notes
- ServerSmokeTests
- publish_if_complete.py
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- load
- Roadmap — where this is and where it goes
- re
- check_pr.py
- DeterminismTests
- check_groundedness.py
- gen_readme_table.py
- quota.py
- probe_models.py
- Milestone Run Script
- CheckPrTests
- Resume Generation Script
- Project Root
- pathlib
- StoredShapeTests
- commit
- has_subscription
- certs.py
- 1. The code graph (Graphify)
- fix_corrupted_content.py
- pipeline.py
- ProtocolTests
- tracker.py
- test_lpic2_200_1_review.py
- api.py
- AI certification roadmap
- _stream
- Within one certification (the only fair comparisons; authoring language `en` only)
- EnvScopeTests
- verdict
- subprocess
- steer.py
- status_matrix.py
- check_syllabus.py
- Study bot — design
- Determinism
- QualityOnlyTests
- The phases
- generate_topic
- make
- bot_loop_check.js
- search_topics
- yaml
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
- model_comparison.py
- lab.md
- translation.md
- PathLanguageTests
- argparse
- video.md
- ExamVersionTests
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
- quota_facts.py
- Operating the pipeline — for maintainers
- check_source_chain.py
- ReviewTests
- EndpointTests
- CONTRIBUTING.md
- lab_step.sh
- RegenerateTests
- .teach
- test_runner_guard.py
- LabStepIsolationTests
- .mcp.json
- pr_check.py
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
- translation_study.py
- MainTests
- yaml
- Backlog
- check_claims.py
- ocr_pdf.py
- window_budget.py
- OwnedTeardownTests
- usage_report.py
- load_models
- Automated review (Copilot)
- metrics_report.py
- ReferencesTest
- EndpointTests
- next_work.py
- _split_answer
- accepted
- ContractTests
- CONTRIBUTING.md
- check_config.py
- collections
- topic_cost.py
- _script_user
- test_source_chain.py
- CheckUpdatesDocTests
- 1.1 Title
- ScopeSectionTests
- test_legal_notice.py
- Content Workflow
- topics
- _exec_script_cmd
- check_api_facts.py
- ExamVersionWiringTests
- fix_fences.py
- _owner_label
- run_until_complete.py
- pipeline.py
- PrCheckTests
- dco
- DisclosureTests
- authorship
- quality.py
- cited_runs
- scope
- IncrementalContractTests
- _glob
- exam_version_changes

## God Nodes (most connected - your core abstractions)
1. `Changelog` - 28 edges
2. `load()` - 25 edges
3. `generate_topic()` - 24 edges
4. `main()` - 23 edges
5. `Lab` - 21 edges
6. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 21 edges
7. `_verify_translation()` - 20 edges
8. `run()` - 20 edges
9. `search_topics()` - 19 edges
10. `block_for()` - 18 edges

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

## Communities (175 total, 62 thin omitted)

### Community 0 - "topic_content"
Cohesion: 0.18
Nodes (6): In Progress / Next (Ordering), 2026-08-20, topic_content(), summary(), VisibleTests, 6. Publish — only for a complete certification

### Community 1 - "lab/cli.py"
Cohesion: 0.12
Nodes (21): Tests, git_repo(), run_cli(), test_all_curated_labs_pass_the_schema(), test_curated_pilot_labs_are_strict_valid_and_verified(), test_from_repo_path_cannot_escape(), test_hint_and_list(), test_migrate_write_roundtrip() (+13 more)

### Community 2 - "scaffold"
Cohesion: 0.18
Nodes (4): default_spec(), scaffold(), validate_spec(), ContractTests

### Community 3 - "models_live.py"
Cohesion: 0.17
Nodes (8): annotate(), compare(), moved(), per_million(), AnnotateTests, catalogue(), CompareTests, priced()

### Community 4 - "video.py"
Cohesion: 0.11
Nodes (32): Video — Technical Debt, 2026-07-17, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat(), _domains_voiceover() (+24 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.05
Nodes (43): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, Every commit is signed off (DCO), First: install the hook. It is the only rule that does not depend on you. (+35 more)

### Community 6 - "claims.py"
Cohesion: 0.05
Nodes (29): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+21 more)

### Community 7 - "generator.py"
Cohesion: 0.14
Nodes (13): _agent_completer(), complete(), _antigravity_completer(), complete(), _dominant_model(), GeneratorConfigError, _litellm_completer(), complete() (+5 more)

### Community 8 - "labs.py"
Cohesion: 0.16
Nodes (21): Labs — what an audit found, 2026-08-08 (design parked, not started), _break_args(), down(), _down_cluster(), enter_hint(), lab_dir(), _lab_name(), LabError (+13 more)

### Community 9 - "Which backend authors better material?"
Cohesion: 0.25
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 10 - "certs.py"
Cohesion: 0.21
Nodes (4): content_dir(), get_topic(), topic_outdated_langs(), StaleCycleTest

### Community 11 - "SnapshotStatusTest"
Cohesion: 0.21
Nodes (3): _apply_snapshot_status(), _topic_identity(), SnapshotStatusTest

### Community 12 - "runner.py"
Cohesion: 0.15
Nodes (25): build(), check(), container_name(), _docker(), down(), ensure_image(), image_for(), _in_time() (+17 more)

### Community 13 - "check"
Cohesion: 0.13
Nodes (5): _reusable(), check(), rules(), QualityFloorTest, QualityThresholdsTest

### Community 14 - "The loop"
Cohesion: 0.25
Nodes (8): 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 4. Status, 5. Commit, The loop, The syllabus-change trigger

### Community 15 - "Changelog"
Cohesion: 0.12
Nodes (16): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-28, 2026-07-29, 2026-09-10, 2026-09-14, 2026-09-15, 2026-09-30 (+8 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.14
Nodes (14): Catalog by Categories, CLI, Code Architecture, Data Model, Decoupled Lab Runner (Future, Go), Design Principles, Educational Platform, Execution Modes + Exercise Videos (SDD — evaluation, pending implementation) (+6 more)

### Community 18 - "teach/cli.py"
Cohesion: 0.09
Nodes (19): cert_add(), cert_generate(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+11 more)

### Community 19 - "lab/cli.py"
Cohesion: 0.19
Nodes (12): _banner(), _clone(), cmd_hint(), cmd_list(), cmd_migrate(), cmd_new(), cmd_validate(), _lab_dir() (+4 more)

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.12
Nodes (8): From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives, What I need from you, What is now enforced, so this cannot recur, What this means for your work, normalise_weights(), objective_ids(), _reject_unreadable_syllabus(), SyllabusCoverageTests

### Community 21 - "_verify_translation"
Cohesion: 0.07
Nodes (17): 2026-08-03, 2026-08-04, 2026-09-11, Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results (+9 more)

### Community 22 - "Content Status"
Cohesion: 0.13
Nodes (11): Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos, Quality, Spend (measured) (+3 more)

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 26 - "publish_if_complete.py"
Cohesion: 0.29
Nodes (7): complete_certs(), is_complete(), main(), publish(), _record(), _save(), _topic_ids()

### Community 27 - "Developers — use the API, run your own copy, build on it"
Cohesion: 0.20
Nodes (10): Building features on it, Developers — use the API, run your own copy, build on it, DORA, concretely, Keeping this page true, Licence, Staying in sync with upstream, ⚠️ The API is beta, and hosted on a home cluster, ⚠️ The content is AI-generated — and that carries real risk (+2 more)

### Community 28 - "clean_registry.py"
Cohesion: 0.42
Nodes (5): deployed_tags(), in_registry(), kubectl(), main(), usage()

### Community 29 - "load"
Cohesion: 0.13
Nodes (21): derived_from(), infer_contract(), load(), load_schema(), migrate(), normalize(), schema_errors(), _verb_present() (+13 more)

### Community 30 - "Roadmap — where this is and where it goes"
Cohesion: 0.29
Nodes (7): Current focus — set 2026-09-11, Roadmap — where this is and where it goes, Smaller things, when there is an appetite, Study bot — the phases after this one, What is next, Where it is, Where we left off — 2026-09-30

### Community 31 - "re"
Cohesion: 0.19
Nodes (10): anchors(), check_file(), generated_checks(), main(), make_targets(), prose_lines(), slug(), teach_commands() (+2 more)

### Community 32 - "check_pr.py"
Cohesion: 0.10
Nodes (20): base_texts(), changed_files(), check(), code_lines_changed(), commits_of(), declared(), declared_scope(), disclosure() (+12 more)

### Community 34 - "check_groundedness.py"
Cohesion: 0.10
Nodes (17): best_windows(), changed(), check_topic(), cited(), claims(), download(), fetch(), fixture() (+9 more)

### Community 35 - "gen_readme_table.py"
Cohesion: 0.47
Nodes (3): main(), status_rows(), table()

### Community 36 - "quota.py"
Cohesion: 0.22
Nodes (7): 2026-09-11, evidence(), main(), main(), probe(), record(), show_history()

### Community 37 - "probe_models.py"
Cohesion: 0.14
Nodes (11): ask(), ask_retrying(), catalogue_state(), main(), material(), _price(), probe_one(), probe_tools() (+3 more)

### Community 44 - "StoredShapeTests"
Cohesion: 0.07
Nodes (24): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Pull requests from agents, Rules, Verification: what is proven, and what is only assumed, 1. Graphify — measured pilot, 2026-08-18 (+16 more)

### Community 45 - "commit"
Cohesion: 0.20
Nodes (3): commit(), DcoMainTests, DcoTests

### Community 46 - "has_subscription"
Cohesion: 0.20
Nodes (8): Platform (Long-Term Roadmap, see PLAN.md), 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, me(), authenticate(), has_subscription()

### Community 47 - "certs.py"
Cohesion: 0.27
Nodes (7): clear_topic_stale(), load(), md_path(), _read(), save(), scaffold(), set_topic_status()

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "fix_corrupted_content.py"
Cohesion: 0.13
Nodes (13): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), _record_quota_block(), _refresh_status() (+5 more)

### Community 50 - "pipeline.py"
Cohesion: 0.17
Nodes (9): generate(), generate_with_retries(), main(), pending(), _sort_key(), me(), mine(), owner() (+1 more)

### Community 52 - "tracker.py"
Cohesion: 0.16
Nodes (8): 2026-07-16, main(), fetch_text(), _get(), _get_bytes(), published_version(), sync_cncf(), TrackerError

### Community 53 - "test_lpic2_200_1_review.py"
Cohesion: 0.07
Nodes (21): AlertsTest, CitationsTest, ConntrackLabTest, ConntrackSizeTest, CpuPressureTest, LabContractTest, ListenQueueTest, MathisTest (+13 more)

### Community 54 - "api.py"
Cohesion: 0.08
Nodes (14): get_bot_stats(), get_catalog(), get_cert_video(), get_langs(), get_path_video(), get_paths(), get_search(), get_status() (+6 more)

### Community 55 - "AI certification roadmap"
Cohesion: 0.22
Nodes (9): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 1 — AI fundamentals (extends the three cloud careers), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters (+1 more)

### Community 56 - "_stream"
Cohesion: 0.17
Nodes (10): _stream(), Lab, test_a_child_that_exits_124_is_not_reported_as_a_timeout(), test_a_stuck_on_timeout_does_not_hang_the_runner(), test_output_and_exit_code_pass_through(), test_scripts_run_under_timeout_inside_the_container(), test_the_backstop_docker_exec_is_bounded(), test_the_message_names_the_phase_timeout_not_the_host_backstop() (+2 more)

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.18
Nodes (11): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, mcpa, Model Comparison (+3 more)

### Community 59 - "verdict"
Cohesion: 0.16
Nodes (7): off_switch(), rejects_reasoning(), thinking_mode(), thought(), tool_call_of(), tool_verdict(), verdict()

### Community 61 - "subprocess"
Cohesion: 0.21
Nodes (10): graphify_bin(), main(), normalized(), rebuild_in_copy(), regenerate(), touches_graph_sources(), docker_ok(), image_ok() (+2 more)

### Community 62 - "steer.py"
Cohesion: 0.18
Nodes (8): 2026-10-15, _cert_block(), create_block(), main(), set_key(), show(), certs(), targets()

### Community 63 - "status_matrix.py"
Cohesion: 0.19
Nodes (10): survey(), cert_topics(), check(), lab_cell(), lang_cell(), _quality_section(), refresh(), _render() (+2 more)

### Community 64 - "check_syllabus.py"
Cohesion: 0.27
Nodes (4): load_syllabus(), main(), smells(), upstream_objectives()

### Community 65 - "Study bot — design"
Cohesion: 0.20
Nodes (10): Alternatives considered, Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Study bot — design, The insight: explicit selection replaces retrieval (+2 more)

### Community 68 - "The phases"
Cohesion: 0.13
Nodes (15): Can it read what we send it? (2026-09-11, second pass), Phase 1.5 — BUILT 2026-09-14 (option A), Phase 1.5 — closing the loop: checks that improve the page, Phase 1 — feedback, and the probe that answers it (2026-09-11), Phase 1 — SHIPPED 2026-09-09, Phase 1 — topic chat with a task harness, Phase 2 — BUILT 2026-09-14, Phase 2 — questions across one certification (+7 more)

### Community 69 - "generate_topic"
Cohesion: 0.16
Nodes (11): 2026-07-11/12, 2026-07-19, 2026-07-27, generate_topic(), _reject_if_recap(), _strip_fence(), _system(), _topic_context() (+3 more)

### Community 70 - "make"
Cohesion: 0.43
Nodes (7): Open — worth someone's time, Set up, once, Running your own copy, Unattended generation timer, Use it in 2 minutes, Standing decisions worth not re-litigating, make()

### Community 71 - "bot_loop_check.js"
Cohesion: 0.06
Nodes (24): fs, KEY, line, ONLY, path, PORT, REPO, SHAPES (+16 more)

### Community 72 - "search_topics"
Cohesion: 0.06
Nodes (18): _fold(), get_syllabus(), get_topic(), _informative(), list_certs(), search_topics(), _terms(), _readable() (+10 more)

### Community 73 - "yaml"
Cohesion: 0.19
Nodes (6): main(), problems(), _skip(), _VendorTagLoader, frozen(), main()

### Community 74 - "catalog.py"
Cohesion: 0.11
Nodes (16): _status_snapshot(), tracker_sync(), add_cert(), _BlockDumper, catalog_path(), get_cert(), list_certs(), load() (+8 more)

### Community 75 - "probe_languages"
Cohesion: 0.29
Nodes (4): Re-probing, and two things the second run taught (2026-09-14), detect_language(), graded(), probe_languages()

### Community 78 - "study.cybercirujas — free, open study material for IT certifications"
Cohesion: 0.15
Nodes (13): AI-generated content, Ask questions about the material with a local model (RAG), ⚖️ Aviso Legal y de Marcas Registradas / Legal & Trademark Disclaimer, Certifications, Contributing, For maintainers, Licence, Practice: break-and-fix labs (+5 more)

### Community 80 - "response"
Cohesion: 0.13
Nodes (4): OffSwitchTests, response(), ThinkingTests, VerdictTests

### Community 84 - "Documentation audit — 2026-10-14"
Cohesion: 0.50
Nodes (4): Documentation audit — 2026-10-14, Fixed in this pass, `graphify-out/` and `openwiki/` — what they are and whether they belong, Needs the owner's decision

### Community 85 - "model_comparison.py"
Cohesion: 0.21
Nodes (7): main(), _md_table(), observations(), render_markdown(), _stats(), usage_by_topic(), write()

### Community 86 - "lab.md"
Cohesion: 0.14
Nodes (13): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Lab cycle (+5 more)

### Community 87 - "translation.md"
Cohesion: 0.14
Nodes (13): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+5 more)

### Community 89 - "argparse"
Cohesion: 0.20
Nodes (6): main(), main(), table(), main(), pending_topics(), run()

### Community 90 - "video.md"
Cohesion: 0.14
Nodes (13): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+5 more)

### Community 92 - "clone_and_run.sh"
Cohesion: 0.33
Nodes (7): fail(), get(), ok(), PYTHONPATH, clone_and_run.sh script, step(), TEACH_OFFLINE

### Community 94 - "pull_request_template.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+4 more)

### Community 95 - "code.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+4 more)

### Community 96 - "content.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+4 more)

### Community 97 - "docs.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+4 more)

### Community 99 - "bad.md"
Cohesion: 0.17
Nodes (11): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Provenance, Risk and rollback (+3 more)

### Community 100 - "good.md"
Cohesion: 0.17
Nodes (11): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Provenance, Risk and rollback (+3 more)

### Community 101 - "Contributing"
Cohesion: 0.15
Nodes (13): Agents, Check before you push, Contributing, Conventions, How big is my change?, How issue forms work, Labels, Licence and conduct (+5 more)

### Community 102 - "quota_facts.py"
Cohesion: 0.21
Nodes (6): _spend_section(), cooldown_until(), exhaustions(), limit_kind(), _rows(), tokens_per_window()

### Community 103 - "Operating the pipeline — for maintainers"
Cohesion: 0.15
Nodes (13): Checking curriculum updates, Content process, Deploying to Kubernetes, Environment variables, Keeping it honest over time, Operating the pipeline — for maintainers, Quality, Quickstart (maintainers) (+5 more)

### Community 104 - "check_source_chain.py"
Cohesion: 0.05
Nodes (19): citations(), main(), status(), baseline(), Chain, frontmatter(), load_yaml(), main() (+11 more)

### Community 107 - "CONTRIBUTING.md"
Cohesion: 0.33
Nodes (6): Becoming a maintainer, Code of conduct, Day-to-day changes, Governance, Proposals (RFCs) — for anything that changes how the project works, Who maintains what, today

### Community 108 - "lab_step.sh"
Cohesion: 0.53
Nodes (4): fail(), ok(), ours(), lab_step.sh script

### Community 110 - ".teach"
Cohesion: 0.31
Nodes (4): Checks that must pass, Groundedness (advisory), Command line, StudentCliSmokeTests

### Community 111 - "test_runner_guard.py"
Cohesion: 0.29
Nodes (8): docker_calls(), FakeLab, test_check_shell_exec_refuse_a_foreign_container(), test_down_refuses_a_foreign_container(), test_node_image_for_supported_minors(), test_ours_passes_study_lab_containers(), test_run_refuses_a_foreign_container(), test_run_refuses_a_kubernetes_minor_without_a_node_image()

### Community 113 - ".mcp.json"
Cohesion: 0.67
Nodes (3): .venv/bin/python3, graphify, teach

### Community 114 - "pr_check.py"
Cohesion: 0.31
Nodes (9): changed(), check(), graph_status(), groundedness_cached(), label(), main(), report(), run() (+1 more)

### Community 124 - "quality_score.py"
Cohesion: 0.07
Nodes (30): _deliberate(), findings(), main(), catalogue(), cited_domains(), duplicate_keys(), main(), block_for() (+22 more)

### Community 125 - "api.py"
Cohesion: 0.15
Nodes (7): BotUsage, login(), LoginBody, logout(), post_bot_used(), require_subscriber(), require_user()

### Community 126 - "study-lab — break/fix labs in a throwaway container"
Cohesion: 0.05
Nodes (29): No braindumps, no NDA material, Provenance is mandatory, Raising a topic's quality score, Sign your commits (DCO), What you can contribute, Create a lab that follows the template, How it works, Measured (WSL2 Ubuntu 24.04 on the workstation, Docker 29.8, 2026-10-15) (+21 more)

### Community 127 - "translation_study.py"
Cohesion: 0.24
Nodes (5): Languages, evaluate(), main(), master_key(), translate()

### Community 130 - "Backlog"
Cohesion: 0.25
Nodes (8): Backlog, Content, Deploy — Technical Debt, Labs — Execution Modes (see PLAN.md, SDD section), Pipeline Automation, RAG Study Bot — Proposal Under Review (`chart/`) — superseded, Repo Hygiene, Verifying the material is TRUE (docs/AUDITOR_DESIGN.md)

### Community 131 - "check_claims.py"
Cohesion: 0.36
Nodes (3): ask(), main(), references()

### Community 132 - "ocr_pdf.py"
Cohesion: 0.36
Nodes (4): embedded_text(), fetch(), main(), ocr()

### Community 133 - "window_budget.py"
Cohesion: 0.33
Nodes (4): _kind(), _load(), main(), _week()

### Community 135 - "usage_report.py"
Cohesion: 0.53
Nodes (4): main(), _money(), rows(), _tokens()

### Community 136 - "load_models"
Cohesion: 0.29
Nodes (5): main(), load_models(), models_path(), save_models(), CatalogueWriterTests

### Community 137 - "Automated review (Copilot)"
Cohesion: 0.29
Nodes (7): Authorship: who wrote it, who found what, who fixed it, Automated review (Copilot), How it behaves, How we work with it, Recording a review in the material, The graph refresh PR, When a PR is ready

### Community 138 - "metrics_report.py"
Cohesion: 0.43
Nodes (6): backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows()

### Community 141 - "next_work.py"
Cohesion: 0.47
Nodes (3): main(), survey(), _topic_count()

### Community 143 - "accepted"
Cohesion: 0.29
Nodes (3): accepted(), _known_models(), AcceptanceTests

### Community 145 - "CONTRIBUTING.md"
Cohesion: 0.21
Nodes (5): Code of Conduct, OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 146 - "check_config.py"
Cohesion: 0.17
Nodes (8): Generation backends, dominant(), effective(), main(), recent(), _cli_env(), generation(), CliEnvTest

### Community 147 - "collections"
Cohesion: 0.33
Nodes (3): _cmd(), test_job_ids_are_unique_across_workflows(), test_k8s_inner_dockerd_listens_on_the_unix_socket_only()

### Community 148 - "topic_cost.py"
Cohesion: 0.43
Nodes (4): by_topic(), dominant(), main(), records()

### Community 150 - "test_source_chain.py"
Cohesion: 0.27
Nodes (3): verify_workflow(), VerifyWorkflowTests, WhereItRanTests

### Community 152 - "1.1 Title"
Cohesion: 0.50
Nodes (3): 1.1 Title, Intro, References

### Community 154 - "test_legal_notice.py"
Cohesion: 0.33
Nodes (3): legal_section(), LegalNoticeTests, owner()

### Community 155 - "Content Workflow"
Cohesion: 0.25
Nodes (8): Backends, Content Workflow, Everything the pipeline produces is declared in `pipeline.yaml`, Failure modes worth knowing, Language flow: author once in English, translate outwards, Switching to Gemini (or any CLI agent), Translating instead of re-authoring, Unattended runs and quota

### Community 156 - "topics"
Cohesion: 0.29
Nodes (5): 2026-09-17, get_cert(), topic_langs(), topics(), generate_cert()

### Community 158 - "check_api_facts.py"
Cohesion: 0.43
Nodes (4): check(), main(), spec_kinds(), tracked_versions()

### Community 163 - "pipeline.py"
Cohesion: 0.15
Nodes (13): What changed in the machinery this session, and why you should not undo it, budget(), default_languages(), in_milestone(), is_fatal(), is_retryable(), languages_for(), load() (+5 more)

### Community 165 - "dco"
Cohesion: 0.33
Nodes (3): dco(), is_graph_refresh(), noreply()

### Community 167 - "authorship"
Cohesion: 0.40
Nodes (3): authorship(), _cells(), ledger_rows()

## Knowledge Gaps
- **4 isolated node(s):** `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE`, `PYTHONPATH`
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1030 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **62 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `_verify_translation()` connect `_verify_translation` to `generator.py`, `StoredShapeTests`, `Content Workflow`, `quality_score.py`, `study-lab — break/fix labs in a throwaway container`, `translation_study.py`?**
  _High betweenness centrality (0.038) - this node is a cross-community bridge._
- **What connects `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE` to the rest of the system?**
  _4 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `lab/cli.py` be split into smaller, more focused modules?**
  _Cohesion score 0.11764705882352941 - nodes in this community are weakly interconnected._
- **Why does `kubectl()` connect `clean_registry.py` to `topic_content`, `Backlog`, `video.py`, `make`, `labs.py`, `study.cybercirujas — free, open study material for IT certifications`, `_verify_translation`, `Developers — use the API, run your own copy, build on it`, `subprocess`, `study-lab — break/fix labs in a throwaway container`?**
  _High betweenness centrality (0.032) - this node is a cross-community bridge._
- **Should `video.py` be split into smaller, more focused modules?**
  _Cohesion score 0.10730804810360776 - nodes in this community are weakly interconnected._
- **Why does `Changelog` connect `Changelog` to `topic_content`, `video.py`, `generate_topic`, `quota.py`, `tracker.py`, `_verify_translation`, `README.md`, `topics`, `steer.py`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._
- **Should `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` be split into smaller, more focused modules?**
  _Cohesion score 0.046511627906976744 - nodes in this community are weakly interconnected._