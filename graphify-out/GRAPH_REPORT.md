# Graph Report - sc13  (2026-10-16)

## Corpus Check
- 162 files · ~216,020 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 16 file(s) not represented in the graph (top: (none) 12, .example 1, .service 1)

## Summary
- 2334 nodes · 4700 edges · 162 communities (111 shown, 51 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 153 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `ece8b836`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- topic_content
- lab/cli.py
- re
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
- The routine, start to finish
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- load
- Roadmap — where this is and where it goes
- check_pr.py
- RejectsDamagedTranslations
- DeterminismTests
- check_groundedness.py
- argparse
- json
- probe_models.py
- Milestone Run Script
- CheckPrTests
- Resume Generation Script
- Project Root
- pathlib
- StoredShapeTests
- search_topics
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
- test_source_chain.py
- Study bot — design
- run
- QualityOnlyTests
- The phases
- quota_facts.py
- tracker.py
- bot_loop_check.js
- topics
- Operating the pipeline — for maintainers
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
- quality.py
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
- test_runner_guard.py
- LabStepIsolationTests
- .mcp.json
- test_corpus.py
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
- mcp_server.py
- MainTests
- path
- Backlog
- check_claims.py
- test_legal_notice.py
- The routine, start to finish
- sitecustomize.py
- collections
- metrics_report.py
- Automated review (Copilot)
- corpus.py
- ReferencesTest
- EndpointTests
- next_work.py
- _split_answer
- milestone
- ContractTests
- topic_cost.py
- check_config.py
- Development Guidelines for teach-plat
- check_api_facts.py
- _cli_env
- test_source_chain.py
- CheckUpdatesDocTests
- 1.1 Title
- CitationsHeadingTests
- test_images.py
- Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)
- OpenWiki scope for teach-plat
- authorship
- Determinism
- cited_runs
- _glob
- _BlockDumper

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
- `2026-07-29` --references--> `find_bad_combos()`  [INFERRED]
  CHANGELOG.md → scripts/fix_corrupted_content.py

## Import Cycles
- None detected.

## Communities (162 total, 51 thin omitted)

### Community 0 - "topic_content"
Cohesion: 0.18
Nodes (6): In Progress / Next (Ordering), 2026-08-20, topic_content(), summary(), VisibleTests, 6. Publish — only for a complete certification

### Community 1 - "lab/cli.py"
Cohesion: 0.11
Nodes (23): Tests, docker_ok(), git_repo(), image_ok(), run_cli(), test_all_curated_labs_pass_the_schema(), test_curated_pilot_labs_are_strict_valid_and_verified(), test_from_repo_path_cannot_escape() (+15 more)

### Community 2 - "re"
Cohesion: 0.19
Nodes (10): anchors(), check_file(), generated_checks(), main(), make_targets(), prose_lines(), slug(), teach_commands() (+2 more)

### Community 3 - "models_live.py"
Cohesion: 0.16
Nodes (9): main(), annotate(), compare(), moved(), per_million(), AnnotateTests, catalogue(), CompareTests (+1 more)

### Community 4 - "video.py"
Cohesion: 0.11
Nodes (32): Video — Technical Debt, 2026-07-17, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat(), _domains_voiceover() (+24 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.05
Nodes (37): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails, From claude — 2026-08-14: where this stands, and how to resume (+29 more)

### Community 6 - "claims.py"
Cohesion: 0.10
Nodes (9): main(), active(), claim(), is_claimed(), _path(), _try_lock(), _unlock(), ClaimTest (+1 more)

### Community 7 - "generator.py"
Cohesion: 0.11
Nodes (18): _agent_completer(), complete(), _antigravity_completer(), complete(), _dominant_model(), generate_cert(), generate_topic(), GeneratorConfigError (+10 more)

### Community 8 - "labs.py"
Cohesion: 0.05
Nodes (33): Labs — what an audit found, 2026-08-08 (design parked, not started), _break_args(), default_spec(), down(), _down_cluster(), _down_container(), enter_hint(), _exec_script_cmd() (+25 more)

### Community 9 - "Which backend authors better material?"
Cohesion: 0.22
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 10 - "certs.py"
Cohesion: 0.21
Nodes (4): content_dir(), get_topic(), topic_outdated_langs(), StaleCycleTest

### Community 12 - "runner.py"
Cohesion: 0.16
Nodes (24): build(), check(), container_name(), _docker(), down(), ensure_image(), image_for(), _in_time() (+16 more)

### Community 13 - "check"
Cohesion: 0.13
Nodes (5): _reusable(), check(), rules(), QualityFloorTest, QualityThresholdsTest

### Community 14 - "The loop"
Cohesion: 0.12
Nodes (17): 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 3. Audit — never skip this, 4. Status, 5. Commit, Backends (+9 more)

### Community 15 - "Changelog"
Cohesion: 0.10
Nodes (22): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-19, 2026-07-27, 2026-07-28, 2026-07-29, 2026-09-10 (+14 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.14
Nodes (14): Catalog by Categories, CLI, Code Architecture, Data Model, Decoupled Lab Runner (Future, Go), Design Principles, Educational Platform, Execution Modes + Exercise Videos (SDD — evaluation, pending implementation) (+6 more)

### Community 18 - "teach/cli.py"
Cohesion: 0.08
Nodes (20): cert_add(), cert_generate(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+12 more)

### Community 19 - "lab/cli.py"
Cohesion: 0.19
Nodes (12): _banner(), _clone(), cmd_hint(), cmd_list(), cmd_migrate(), cmd_new(), cmd_validate(), _lab_dir() (+4 more)

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.12
Nodes (8): From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives, What I need from you, What is now enforced, so this cannot recur, What this means for your work, normalise_weights(), objective_ids(), _reject_unreadable_syllabus(), SyllabusCoverageTests

### Community 21 - "_verify_translation"
Cohesion: 0.11
Nodes (15): 2026-08-03, 2026-08-04, Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results, Three bugs this study found in our own checks (+7 more)

### Community 22 - "Content Status"
Cohesion: 0.13
Nodes (11): Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos, Quality, Spend (measured) (+3 more)

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 26 - "The routine, start to finish"
Cohesion: 0.22
Nodes (9): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+1 more)

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
Cohesion: 0.25
Nodes (8): Current focus — set 2026-09-11, Roadmap — where this is and where it goes, Smaller things, when there is an appetite, Standing decisions worth not re-litigating, Study bot — the phases after this one, What is next, Where it is, Where we left off — 2026-09-30

### Community 31 - "check_pr.py"
Cohesion: 0.13
Nodes (15): base_texts(), changed_files(), check(), code_lines_changed(), declared(), image_paths(), judge_run(), kinds() (+7 more)

### Community 34 - "check_groundedness.py"
Cohesion: 0.10
Nodes (17): best_windows(), changed(), check_topic(), cited(), claims(), download(), fetch(), fixture() (+9 more)

### Community 35 - "argparse"
Cohesion: 0.10
Nodes (12): main(), classify(), main(), main(), status_rows(), table(), main(), main() (+4 more)

### Community 36 - "json"
Cohesion: 0.13
Nodes (13): 2026-09-11, evidence(), main(), gh_api(), complete_certs(), main(), publish(), _record() (+5 more)

### Community 37 - "probe_models.py"
Cohesion: 0.14
Nodes (11): ask(), ask_retrying(), catalogue_state(), main(), material(), _price(), probe_one(), probe_tools() (+3 more)

### Community 44 - "StoredShapeTests"
Cohesion: 0.12
Nodes (7): accepted(), _blank(), _known_models(), load(), record(), AcceptanceTests, StoredShapeTests

### Community 46 - "has_subscription"
Cohesion: 0.22
Nodes (7): Platform (Long-Term Roadmap, see PLAN.md), 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, authenticate(), has_subscription()

### Community 47 - "certs.py"
Cohesion: 0.27
Nodes (7): clear_topic_stale(), load(), md_path(), _read(), save(), scaffold(), set_topic_status()

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "fix_corrupted_content.py"
Cohesion: 0.11
Nodes (15): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), _record_quota_block(), _refresh_status() (+7 more)

### Community 50 - "pipeline.py"
Cohesion: 0.11
Nodes (18): Generation backends, generate(), generate_with_retries(), main(), pending(), _sort_key(), budget(), generation() (+10 more)

### Community 52 - "tracker.py"
Cohesion: 0.15
Nodes (9): 2026-07-16, _apply_snapshot_status(), fetch_text(), _get(), _get_bytes(), snapshot_topics(), sync_cncf(), _topic_identity() (+1 more)

### Community 53 - "test_lpic2_200_1_review.py"
Cohesion: 0.07
Nodes (21): AlertsTest, CitationsTest, ConntrackLabTest, ConntrackSizeTest, CpuPressureTest, LabContractTest, ListenQueueTest, MathisTest (+13 more)

### Community 54 - "api.py"
Cohesion: 0.08
Nodes (16): get_bot_stats(), get_catalog(), get_cert_video(), get_langs(), get_path_video(), get_paths(), get_search(), get_status() (+8 more)

### Community 55 - "AI certification roadmap"
Cohesion: 0.18
Nodes (10): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 1 — AI fundamentals (extends the three cloud careers), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters (+2 more)

### Community 56 - "_stream"
Cohesion: 0.15
Nodes (11): _stream(), _why(), Lab, test_a_child_that_exits_124_is_not_reported_as_a_timeout(), test_a_stuck_on_timeout_does_not_hang_the_runner(), test_output_and_exit_code_pass_through(), test_scripts_run_under_timeout_inside_the_container(), test_the_backstop_docker_exec_is_bounded() (+3 more)

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
Cohesion: 0.15
Nodes (11): 2026-10-15, main(), _cert_block(), create_block(), main(), set_key(), show(), certs() (+3 more)

### Community 63 - "status_matrix.py"
Cohesion: 0.20
Nodes (9): cert_topics(), check(), lab_cell(), lang_cell(), _quality_section(), refresh(), _render(), _write() (+1 more)

### Community 64 - "test_source_chain.py"
Cohesion: 0.12
Nodes (9): citations(), main(), status(), load_syllabus(), main(), smells(), upstream_objectives(), section() (+1 more)

### Community 65 - "Study bot — design"
Cohesion: 0.22
Nodes (9): Alternatives considered, Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Study bot — design, The insight: explicit selection replaces retrieval (+1 more)

### Community 66 - "run"
Cohesion: 0.33
Nodes (3): Model, NoNetwork, run()

### Community 68 - "The phases"
Cohesion: 0.13
Nodes (15): Can it read what we send it? (2026-09-11, second pass), Phase 1.5 — BUILT 2026-09-14 (option A), Phase 1.5 — closing the loop: checks that improve the page, Phase 1 — feedback, and the probe that answers it (2026-09-11), Phase 1 — SHIPPED 2026-09-09, Phase 1 — topic chat with a task harness, Phase 2 — BUILT 2026-09-14, Phase 2 — questions across one certification (+7 more)

### Community 69 - "quota_facts.py"
Cohesion: 0.22
Nodes (6): _spend_section(), cooldown_until(), exhaustions(), limit_kind(), _rows(), tokens_per_window()

### Community 70 - "tracker.py"
Cohesion: 0.19
Nodes (6): frozen(), main(), _same_version(), state(), survey(), published_version()

### Community 71 - "bot_loop_check.js"
Cohesion: 0.06
Nodes (24): fs, KEY, line, ONLY, path, PORT, REPO, SHAPES (+16 more)

### Community 72 - "topics"
Cohesion: 0.21
Nodes (6): get_cert(), topic_langs(), topics(), get_syllabus(), list_certs(), ListAndSyllabusTests

### Community 73 - "Operating the pipeline — for maintainers"
Cohesion: 0.15
Nodes (13): Checking curriculum updates, Content process, Deploying to Kubernetes, Environment variables, Keeping it honest over time, Operating the pipeline — for maintainers, Quality, Quickstart (maintainers) (+5 more)

### Community 74 - "catalog.py"
Cohesion: 0.15
Nodes (15): add_cert(), catalog_path(), get_cert(), list_certs(), load(), load_models(), models_path(), root() (+7 more)

### Community 75 - "probe_languages"
Cohesion: 0.29
Nodes (4): Re-probing, and two things the second run taught (2026-09-14), detect_language(), graded(), probe_languages()

### Community 78 - "study.cybercirujas — free, open study material for IT certifications"
Cohesion: 0.15
Nodes (13): AI-generated content, Ask questions about the material with a local model (RAG), ⚖️ Aviso Legal y de Marcas Registradas / Legal & Trademark Disclaimer, Certifications, Contributing, For maintainers, Licence, Practice: break-and-fix labs (+5 more)

### Community 80 - "response"
Cohesion: 0.13
Nodes (4): OffSwitchTests, response(), ThinkingTests, VerdictTests

### Community 83 - "CheckDocsTests"
Cohesion: 0.20
Nodes (6): Open — worth someone's time, Running your own copy, Unattended generation timer, Use it in 2 minutes, make(), CheckDocsTests

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

### Community 91 - "quality.py"
Cohesion: 0.19
Nodes (6): 6. Where the value actually is (owner's question, 2026-08-18), Languages, evaluate(), main(), master_key(), translate()

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
Cohesion: 0.18
Nodes (11): Agents, Checks that must pass, Contributing, Conventions, Labels, Licence and conduct, Merging and deploying the site, Pull requests (+3 more)

### Community 102 - "model_comparison.py"
Cohesion: 0.21
Nodes (7): main(), _md_table(), observations(), render_markdown(), _stats(), usage_by_topic(), write()

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

### Community 111 - "test_runner_guard.py"
Cohesion: 0.33
Nodes (8): docker_calls(), FakeLab, test_check_shell_exec_refuse_a_foreign_container(), test_down_refuses_a_foreign_container(), test_node_image_for_supported_minors(), test_ours_passes_study_lab_containers(), test_run_refuses_a_foreign_container(), test_run_refuses_a_kubernetes_minor_without_a_node_image()

### Community 113 - ".mcp.json"
Cohesion: 0.67
Nodes (3): .venv/bin/python3, graphify, teach

### Community 114 - "test_corpus.py"
Cohesion: 0.18
Nodes (4): get_topic(), get_topic(), ContractTests, TopicTests

### Community 124 - "quality_score.py"
Cohesion: 0.06
Nodes (34): _deliberate(), findings(), main(), main(), problems(), _skip(), _VendorTagLoader, catalogue() (+26 more)

### Community 125 - "api.py"
Cohesion: 0.21
Nodes (7): BotUsage, login(), LoginBody, logout(), post_bot_used(), require_subscriber(), require_user()

### Community 126 - "study-lab — break/fix labs in a throwaway container"
Cohesion: 0.06
Nodes (25): No braindumps, no NDA material, Provenance is mandatory, Raising a topic's quality score, What you can contribute, Create a lab that follows the template, How it works, Measured (WSL2 Ubuntu 24.04 on the workstation, Docker 29.8, 2026-10-15), Not done yet (+17 more)

### Community 127 - "mcp_server.py"
Cohesion: 0.22
Nodes (5): _readable(), serve(), get_syllabus(), list_certs(), search_topics()

### Community 129 - "path"
Cohesion: 0.25
Nodes (5): Verification: what is proven, and what is only assumed, main(), table(), path(), _write()

### Community 130 - "Backlog"
Cohesion: 0.25
Nodes (8): Backlog, Content, Deploy — Technical Debt, Labs — Execution Modes (see PLAN.md, SDD section), Pipeline Automation, RAG Study Bot — Proposal Under Review (`chart/`) — superseded, Repo Hygiene, Verifying the material is TRUE (docs/AUDITOR_DESIGN.md)

### Community 131 - "check_claims.py"
Cohesion: 0.36
Nodes (3): ask(), main(), references()

### Community 132 - "test_legal_notice.py"
Cohesion: 0.33
Nodes (3): legal_section(), LegalNoticeTests, owner()

### Community 133 - "The routine, start to finish"
Cohesion: 0.25
Nodes (8): Step 0 — measure before touching anything, Step 1 — orphaned registry uploads · *safe to automate*, Step 2 — old image tags · *automatable with a rule, not blindly*, Step 3 — garbage collection · *safe to automate, but slow*, Step 4 — logs and diagnosed rejections · *safe to automate*, Step 5 — orphaned topics and scratch files · *keep manual*, Steps 1–3, automated · `make clean-registry`, The routine, start to finish

### Community 134 - "sitecustomize.py"
Cohesion: 0.47
Nodes (3): _connect(), _connect_ex(), _host()

### Community 135 - "collections"
Cohesion: 0.16
Nodes (8): main(), _money(), rows(), _tokens(), _kind(), _load(), main(), _week()

### Community 136 - "metrics_report.py"
Cohesion: 0.43
Nodes (6): backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows()

### Community 137 - "Automated review (Copilot)"
Cohesion: 0.33
Nodes (6): Authorship: who wrote it, who found what, who fixed it, Automated review (Copilot), How it behaves, How we work with it, Recording a review in the material, When a PR is ready

### Community 138 - "corpus.py"
Cohesion: 0.32
Nodes (3): _fold(), _informative(), _terms()

### Community 141 - "next_work.py"
Cohesion: 0.47
Nodes (3): main(), survey(), _topic_count()

### Community 143 - "milestone"
Cohesion: 0.29
Nodes (4): What changed in the machinery this session, and why you should not undo it, in_milestone(), milestone(), milestone_targets()

### Community 145 - "topic_cost.py"
Cohesion: 0.43
Nodes (4): by_topic(), dominant(), main(), records()

### Community 146 - "check_config.py"
Cohesion: 0.43
Nodes (4): dominant(), effective(), main(), recent()

### Community 147 - "Development Guidelines for teach-plat"
Cohesion: 0.33
Nodes (6): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Pull requests from agents, Rules

### Community 148 - "check_api_facts.py"
Cohesion: 0.43
Nodes (4): check(), main(), spec_kinds(), tracked_versions()

### Community 150 - "test_source_chain.py"
Cohesion: 0.17
Nodes (3): verify_workflow(), VerifyWorkflowTests, WhereItRanTests

### Community 152 - "1.1 Title"
Cohesion: 0.50
Nodes (3): 1.1 Title, Intro, References

### Community 154 - "test_images.py"
Cohesion: 0.40
Nodes (3): _cmd(), test_job_ids_are_unique_across_workflows(), test_k8s_inner_dockerd_listens_on_the_unix_socket_only()

### Community 155 - "Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)"
Cohesion: 0.40
Nodes (5): Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), German translation: working recipe found, blocked on timeout, Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09), What I finished, What I need from you

### Community 156 - "OpenWiki scope for teach-plat"
Cohesion: 0.40
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 157 - "authorship"
Cohesion: 0.40
Nodes (3): authorship(), _cells(), ledger_rows()

## Knowledge Gaps
- **4 isolated node(s):** `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE`, `PYTHONPATH`
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 975 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **51 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `kubectl()` connect `clean_registry.py` to `topic_content`, `Backlog`, `video.py`, `labs.py`, `study.cybercirujas — free, open study material for IT certifications`, `CheckDocsTests`, `_verify_translation`, `Roadmap — where this is and where it goes`, `Developers — use the API, run your own copy, build on it`, `subprocess`, `study-lab — break/fix labs in a throwaway container`?**
  _High betweenness centrality (0.042) - this node is a cross-community bridge._
- **What connects `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE` to the rest of the system?**
  _4 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `lab/cli.py` be split into smaller, more focused modules?**
  _Cohesion score 0.10810810810810811 - nodes in this community are weakly interconnected._
- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` to `CheckDocsTests`, `Syllabus Coverage Tests`, `Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)`, `README.md`?**
  _High betweenness centrality (0.037) - this node is a cross-community bridge._
- **Should `video.py` be split into smaller, more focused modules?**
  _Cohesion score 0.10730804810360776 - nodes in this community are weakly interconnected._
- **Why does `Study bot — design` connect `Study bot — design` to `The phases`, `Client`, `README.md`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Should `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` be split into smaller, more focused modules?**
  _Cohesion score 0.05405405405405406 - nodes in this community are weakly interconnected._