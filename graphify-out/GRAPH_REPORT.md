# Graph Report - teach-plat  (2026-10-15)

## Corpus Check
- 154 files · ~206,016 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 15 file(s) not represented in the graph (top: (none) 12, .example 1, .service 1)

## Summary
- 2163 nodes · 4338 edges · 156 communities (96 shown, 60 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 147 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `96b024b4`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Backlog
- test_cli.py
- scaffold
- models_live.py
- video.py
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- claim
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
- RejectsDamagedTranslations
- Syllabus Coverage Tests
- _verify_translation
- check_versions.py
- Verifying the material is true — design notes
- ServerSmokeTests
- topic_cost.py
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- translation_study.py
- Roadmap — where this is and where it goes
- check_pr.py
- load
- DeterminismTests
- Contributing
- problems
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
- The routine, start to finish
- snapshot_topics
- AI certification roadmap
- lab/cli.py
- Within one certification (the only fair comparisons; authoring language `en` only)
- EnvScopeTests
- response
- subprocess
- _stream
- study-lab — break/fix labs in a throwaway container
- check_citations.py
- generate_topic
- OpenWiki scope for teach-plat
- argparse
- The phases
- probe_tools
- tracker.py
- bot_loop_check.js
- Study bot — design
- post_bot_used
- catalog.py
- check_docs.py
- ComprehensionTests
- api.py
- study.cybercirujas — free, open study material for IT certifications
- CatalogueStateTests
- Operating the pipeline — for maintainers
- FixtureTests
- LanguageTests
- CheckDocsTests
- Documentation audit — 2026-10-14
- get_syllabus
- lab.md
- translation.md
- PathLanguageTests
- test_runner_guard.py
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
- get_models
- model_comparison.py
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- check_source_chain.py
- probe_languages
- EndpointTests
- CONTRIBUTING.md
- lab_step.sh
- RegenerateTests
- .teach
- Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)
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
- re
- get
- CitedRunTests
- OwnedTeardownTests
- MainTests
- test_legal_notice.py
- check_k8s_apis.py
- topic_content
- _script_user
- _exec_script_cmd
- sitecustomize.py
- mcp_server.py
- make
- Automated review (Copilot)
- _owner_label
- ReferencesTest
- IncrementalContractTests
- generation
- _split_answer
- WhereItRanTests
- ContractTests
- EnterHintTests
- check_config.py
- Development Guidelines for teach-plat
- VerdictTests
- authorship
- verify_workflow
- CheckUpdatesDocTests
- OffSwitchTests
- CitationsHeadingTests
- test_model_probe.py
- _glob

## God Nodes (most connected - your core abstractions)
1. `Changelog` - 27 edges
2. `load()` - 25 edges
3. `generate_topic()` - 24 edges
4. `Lab` - 21 edges
5. `run()` - 20 edges
6. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 20 edges
7. `search_topics()` - 19 edges
8. `_verify_translation()` - 19 edges
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

## Communities (156 total, 60 thin omitted)

### Community 0 - "Backlog"
Cohesion: 0.25
Nodes (8): Backlog, Content, Deploy — Technical Debt, Labs — Execution Modes (see PLAN.md, SDD section), Pipeline Automation, RAG Study Bot — Proposal Under Review (`chart/`) — superseded, Repo Hygiene, Verifying the material is TRUE (docs/AUDITOR_DESIGN.md)

### Community 1 - "test_cli.py"
Cohesion: 0.09
Nodes (25): Tests, docker_ok(), git_repo(), image_ok(), new_lab(), run_cli(), test_all_curated_labs_pass_the_schema(), test_curated_pilot_labs_are_strict_valid_and_verified() (+17 more)

### Community 2 - "scaffold"
Cohesion: 0.18
Nodes (4): default_spec(), scaffold(), validate_spec(), ContractTests

### Community 3 - "models_live.py"
Cohesion: 0.08
Nodes (18): main(), Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos, Spend (measured) (+10 more)

### Community 4 - "video.py"
Cohesion: 0.11
Nodes (32): Video — Technical Debt, 2026-07-17, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat(), _domains_voiceover() (+24 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.05
Nodes (42): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails, From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives (+34 more)

### Community 6 - "claim"
Cohesion: 0.13
Nodes (7): claim(), is_claimed(), _path(), _try_lock(), _unlock(), ClaimTest, _try_claim()

### Community 7 - "generator.py"
Cohesion: 0.16
Nodes (12): _agent_completer(), complete(), _antigravity_completer(), complete(), _dominant_model(), GeneratorConfigError, _litellm_completer(), complete() (+4 more)

### Community 8 - "labs.py"
Cohesion: 0.17
Nodes (20): Labs — what an audit found, 2026-08-08 (design parked, not started), _break_args(), down(), _down_cluster(), enter_hint(), lab_dir(), _lab_name(), LabError (+12 more)

### Community 9 - "Which backend authors better material?"
Cohesion: 0.25
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

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
Cohesion: 0.09
Nodes (23): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-19, 2026-07-27, 2026-07-28, 2026-07-29, 2026-09-10 (+15 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.14
Nodes (14): Catalog by Categories, CLI, Code Architecture, Data Model, Decoupled Lab Runner (Future, Go), Design Principles, Educational Platform, Execution Modes + Exercise Videos (SDD — evaluation, pending implementation) (+6 more)

### Community 18 - "teach/cli.py"
Cohesion: 0.08
Nodes (20): cert_add(), cert_generate(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+12 more)

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.15
Nodes (4): normalise_weights(), objective_ids(), _reject_unreadable_syllabus(), SyllabusCoverageTests

### Community 21 - "_verify_translation"
Cohesion: 0.11
Nodes (15): 2026-08-03, 2026-08-04, Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results, Three bugs this study found in our own checks (+7 more)

### Community 22 - "check_versions.py"
Cohesion: 0.21
Nodes (6): frozen(), main(), _same_version(), state(), survey(), published_version()

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 26 - "topic_cost.py"
Cohesion: 0.16
Nodes (7): by_topic(), dominant(), main(), records(), _cmd(), test_job_ids_are_unique_across_workflows(), test_k8s_inner_dockerd_listens_on_the_unix_socket_only()

### Community 27 - "Developers — use the API, run your own copy, build on it"
Cohesion: 0.20
Nodes (10): Building features on it, Developers — use the API, run your own copy, build on it, DORA, concretely, Keeping this page true, Licence, Staying in sync with upstream, ⚠️ The API is beta, and hosted on a home cluster, ⚠️ The content is AI-generated — and that carries real risk (+2 more)

### Community 28 - "clean_registry.py"
Cohesion: 0.42
Nodes (5): deployed_tags(), in_registry(), kubectl(), main(), usage()

### Community 29 - "translation_study.py"
Cohesion: 0.12
Nodes (12): 6. Where the value actually is (owner's question, 2026-08-18), Languages, generate(), generate_with_retries(), pending(), _sort_key(), main(), pending() (+4 more)

### Community 30 - "Roadmap — where this is and where it goes"
Cohesion: 0.25
Nodes (8): Current focus — set 2026-09-11, Roadmap — where this is and where it goes, Smaller things, when there is an appetite, Standing decisions worth not re-litigating, Study bot — the phases after this one, What is next, Where it is, Where we left off — 2026-09-30

### Community 31 - "check_pr.py"
Cohesion: 0.13
Nodes (15): changed_files(), check(), cited_runs(), code_lines_changed(), declared(), image_paths(), judge_run(), kinds() (+7 more)

### Community 32 - "load"
Cohesion: 0.13
Nodes (22): 2026-10-15, derived_from(), infer_contract(), load(), load_schema(), migrate(), normalize(), schema_errors() (+14 more)

### Community 34 - "Contributing"
Cohesion: 0.14
Nodes (14): Agents, Checks that must pass, Contributing, Conventions, Labels, Licence and conduct, Merging and deploying the site, No braindumps, no NDA material (+6 more)

### Community 35 - "problems"
Cohesion: 0.16
Nodes (8): main(), problems(), _skip(), _VendorTagLoader, main(), status_rows(), table(), main()

### Community 36 - "json"
Cohesion: 0.12
Nodes (13): evidence(), main(), gh_api(), classify(), main(), main(), probe(), record() (+5 more)

### Community 37 - "probe_models.py"
Cohesion: 0.14
Nodes (11): catalogue_state(), main(), off_switch(), _price(), probe_one(), reasoning_mandatory(), rejects_reasoning(), tally() (+3 more)

### Community 44 - "StoredShapeTests"
Cohesion: 0.09
Nodes (10): Verification: what is proven, and what is only assumed, accepted(), _blank(), _known_models(), load(), path(), record(), _write() (+2 more)

### Community 45 - "search_topics"
Cohesion: 0.17
Nodes (5): _fold(), _informative(), search_topics(), _terms(), SearchTests

### Community 46 - "has_subscription"
Cohesion: 0.14
Nodes (13): Platform (Long-Term Roadmap, see PLAN.md), 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, login(), LoginBody, logout() (+5 more)

### Community 47 - "certs.py"
Cohesion: 0.23
Nodes (9): clear_topic_stale(), get_topic(), load(), md_path(), _read(), save(), scaffold(), set_topic_status() (+1 more)

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "fix_corrupted_content.py"
Cohesion: 0.07
Nodes (21): check_cert(), main(), _topics(), _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main() (+13 more)

### Community 50 - "pipeline.py"
Cohesion: 0.08
Nodes (25): main(), main(), _cert_block(), create_block(), main(), set_key(), show(), budget() (+17 more)

### Community 52 - "publish_if_complete.py"
Cohesion: 0.29
Nodes (7): complete_certs(), is_complete(), main(), publish(), _record(), _save(), _topic_ids()

### Community 53 - "The routine, start to finish"
Cohesion: 0.12
Nodes (17): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+9 more)

### Community 54 - "snapshot_topics"
Cohesion: 0.16
Nodes (13): 2026-07-16, Phase 1 — AI fundamentals (extends the three cloud careers), tracker_sync(), add_cert(), load(), save(), _ai_yaml(), generate_paths() (+5 more)

### Community 55 - "AI certification roadmap"
Cohesion: 0.25
Nodes (8): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters, Watchlist — official, but they fail a filter today

### Community 56 - "lab/cli.py"
Cohesion: 0.20
Nodes (11): _banner(), _clone(), cmd_hint(), cmd_list(), cmd_migrate(), cmd_new(), cmd_validate(), _lab_dir() (+3 more)

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.18
Nodes (11): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, mcpa, Model Comparison (+3 more)

### Community 61 - "subprocess"
Cohesion: 0.16
Nodes (12): graphify_bin(), main(), normalized(), rebuild_in_copy(), regenerate(), touches_graph_sources(), embedded_text(), fetch() (+4 more)

### Community 62 - "_stream"
Cohesion: 0.16
Nodes (11): _stream(), _why(), Lab, test_a_child_that_exits_124_is_not_reported_as_a_timeout(), test_a_stuck_on_timeout_does_not_hang_the_runner(), test_output_and_exit_code_pass_through(), test_scripts_run_under_timeout_inside_the_container(), test_the_backstop_docker_exec_is_bounded() (+3 more)

### Community 63 - "study-lab — break/fix labs in a throwaway container"
Cohesion: 0.15
Nodes (11): Create a lab that follows the template, How it works, Measured (WSL2 Ubuntu 24.04 on the workstation, Docker 29.8, 2026-10-15), Not done yet, Pinned versions, Quick start, Run a lab from another repository, State of the 548 curated labs (validate, 2026-10-15) (+3 more)

### Community 64 - "check_citations.py"
Cohesion: 0.13
Nodes (8): check(), main(), spec_kinds(), tracked_versions(), citations(), main(), status(), section()

### Community 65 - "generate_topic"
Cohesion: 0.22
Nodes (6): topic_langs(), topic_outdated_langs(), generate_topic(), _topic_context(), _write_meta(), First, the thing that surprises everyone

### Community 66 - "OpenWiki scope for teach-plat"
Cohesion: 0.33
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 67 - "argparse"
Cohesion: 0.13
Nodes (9): ask(), main(), references(), main(), main(), table(), main(), pending_topics() (+1 more)

### Community 68 - "The phases"
Cohesion: 0.13
Nodes (15): Can it read what we send it? (2026-09-11, second pass), Phase 1.5 — BUILT 2026-09-14 (option A), Phase 1.5 — closing the loop: checks that improve the page, Phase 1 — feedback, and the probe that answers it (2026-09-11), Phase 1 — SHIPPED 2026-09-09, Phase 1 — topic chat with a task harness, Phase 2 — BUILT 2026-09-14, Phase 2 — questions across one certification (+7 more)

### Community 69 - "probe_tools"
Cohesion: 0.20
Nodes (5): material(), probe_tools(), tool_call_of(), tool_verdict(), verdict()

### Community 70 - "tracker.py"
Cohesion: 0.18
Nodes (6): _apply_snapshot_status(), fetch_text(), _get(), _get_bytes(), sync_cncf(), _topic_identity()

### Community 71 - "bot_loop_check.js"
Cohesion: 0.06
Nodes (24): fs, KEY, line, ONLY, path, PORT, REPO, SHAPES (+16 more)

### Community 72 - "Study bot — design"
Cohesion: 0.20
Nodes (10): Alternatives considered, Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Study bot — design, The insight: explicit selection replaces retrieval (+2 more)

### Community 74 - "catalog.py"
Cohesion: 0.22
Nodes (6): _BlockDumper, catalog_path(), load_models(), models_path(), root(), save_models()

### Community 75 - "check_docs.py"
Cohesion: 0.18
Nodes (10): anchors(), check_file(), generated_checks(), main(), make_targets(), prose_lines(), slug(), teach_commands() (+2 more)

### Community 77 - "api.py"
Cohesion: 0.12
Nodes (7): get_cert_video(), get_path_video(), get_paths(), get_topic(), get_topic_preview(), _valid_lang(), _video_info()

### Community 78 - "study.cybercirujas — free, open study material for IT certifications"
Cohesion: 0.15
Nodes (13): AI-generated content, Ask questions about the material with a local model (RAG), ⚖️ Aviso Legal y de Marcas Registradas / Legal & Trademark Disclaimer, Certifications, Contributing, For maintainers, Licence, Practice: break-and-fix labs (+5 more)

### Community 80 - "Operating the pipeline — for maintainers"
Cohesion: 0.15
Nodes (13): Checking curriculum updates, Content process, Deploying to Kubernetes, Environment variables, Keeping it honest over time, Operating the pipeline — for maintainers, Quality, Quickstart (maintainers) (+5 more)

### Community 84 - "Documentation audit — 2026-10-14"
Cohesion: 0.50
Nodes (4): Documentation audit — 2026-10-14, Fixed in this pass, `graphify-out/` and `openwiki/` — what they are and whether they belong, Needs the owner's decision

### Community 85 - "get_syllabus"
Cohesion: 0.20
Nodes (7): get_syllabus(), list_certs(), serve(), get_syllabus(), list_certs(), search_topics(), ListAndSyllabusTests

### Community 86 - "lab.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Lab cycle (+4 more)

### Community 87 - "translation.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+4 more)

### Community 89 - "test_runner_guard.py"
Cohesion: 0.29
Nodes (8): docker_calls(), FakeLab, test_check_shell_exec_refuse_a_foreign_container(), test_down_refuses_a_foreign_container(), test_node_image_for_supported_minors(), test_ours_passes_study_lab_containers(), test_run_refuses_a_foreign_container(), test_run_refuses_a_kubernetes_minor_without_a_node_image()

### Community 90 - "video.md"
Cohesion: 0.15
Nodes (12): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+4 more)

### Community 91 - "check_syllabus.py"
Cohesion: 0.31
Nodes (4): load_syllabus(), main(), smells(), upstream_objectives()

### Community 92 - "clone_and_run.sh"
Cohesion: 0.33
Nodes (7): fail(), get(), ok(), PYTHONPATH, clone_and_run.sh script, step(), TEACH_OFFLINE

### Community 93 - "Client"
Cohesion: 0.24
Nodes (3): ask(), ask_retrying(), Client

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

### Community 102 - "model_comparison.py"
Cohesion: 0.06
Nodes (30): backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main(), _md_table() (+22 more)

### Community 103 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.18
Nodes (10): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith), Integration cautions (this repo specifically) (+2 more)

### Community 104 - "check_source_chain.py"
Cohesion: 0.07
Nodes (19): 1. Information sovereignty, 2. Curriculum-as-Code, 3. Determinism, 4. With AI or without AI: the same pipeline and the same validator, 5. Honest about limits, 6. Open by default, 7. The source chain, Principles (+11 more)

### Community 105 - "probe_languages"
Cohesion: 0.29
Nodes (4): Re-probing, and two things the second run taught (2026-09-14), detect_language(), graded(), probe_languages()

### Community 107 - "CONTRIBUTING.md"
Cohesion: 0.22
Nodes (7): Code of Conduct, Becoming a maintainer, Code of conduct, Day-to-day changes, Governance, Proposals (RFCs) — for anything that changes how the project works, Who maintains what, today

### Community 108 - "lab_step.sh"
Cohesion: 0.53
Nodes (4): fail(), ok(), ours(), lab_step.sh script

### Community 111 - "Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)"
Cohesion: 0.40
Nodes (5): Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), German translation: working recipe found, blocked on timeout, Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09), What I finished, What I need from you

### Community 113 - ".mcp.json"
Cohesion: 0.67
Nodes (3): .venv/bin/python3, graphify, teach

### Community 124 - "re"
Cohesion: 0.27
Nodes (4): catalogue(), cited_domains(), duplicate_keys(), main()

### Community 125 - "get"
Cohesion: 0.12
Nodes (11): get_bot_stats(), get_catalog(), get_cert(), get_langs(), get_search(), get_status(), healthz(), index() (+3 more)

### Community 129 - "test_legal_notice.py"
Cohesion: 0.33
Nodes (3): legal_section(), LegalNoticeTests, owner()

### Community 130 - "check_k8s_apis.py"
Cohesion: 0.47
Nodes (3): _deliberate(), findings(), main()

### Community 131 - "topic_content"
Cohesion: 0.20
Nodes (7): In Progress / Next (Ordering), 2026-08-20, topic_content(), get_topic(), get_topic(), TopicTests, 6. Publish — only for a complete certification

### Community 134 - "sitecustomize.py"
Cohesion: 0.47
Nodes (3): _connect(), _connect_ex(), _host()

### Community 136 - "make"
Cohesion: 0.43
Nodes (5): Open — worth someone's time, Running your own copy, Unattended generation timer, Use it in 2 minutes, make()

### Community 137 - "Automated review (Copilot)"
Cohesion: 0.33
Nodes (5): Authorship: who wrote it, who found what, who fixed it, Automated review (Copilot), How it behaves, How we work with it, When a PR is ready

### Community 141 - "generation"
Cohesion: 0.22
Nodes (5): Generation backends, _cli_env(), _record_usage(), generation(), CliEnvTest

### Community 146 - "check_config.py"
Cohesion: 0.43
Nodes (4): dominant(), effective(), main(), recent()

### Community 147 - "Development Guidelines for teach-plat"
Cohesion: 0.33
Nodes (6): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Pull requests from agents, Rules

### Community 149 - "authorship"
Cohesion: 0.40
Nodes (3): authorship(), _cells(), ledger_rows()

## Knowledge Gaps
- **4 isolated node(s):** `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE`, `PYTHONPATH`
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 924 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **60 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `kubectl()` connect `clean_registry.py` to `Backlog`, `topic_content`, `video.py`, `make`, `labs.py`, `study.cybercirujas — free, open study material for IT certifications`, `_verify_translation`, `Developers — use the API, run your own copy, build on it`, `subprocess`, `Roadmap — where this is and where it goes`, `study-lab — break/fix labs in a throwaway container`?**
  _High betweenness centrality (0.051) - this node is a cross-community bridge._
- **What connects `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE` to the rest of the system?**
  _4 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `test_cli.py` be split into smaller, more focused modules?**
  _Cohesion score 0.09291521486643438 - nodes in this community are weakly interconnected._
- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` to `make`, `Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)`, `README.md`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Should `models_live.py` be split into smaller, more focused modules?**
  _Cohesion score 0.07549361207897794 - nodes in this community are weakly interconnected._
- **Why does `study.cybercirujas — free, open study material for IT certifications` connect `study.cybercirujas — free, open study material for IT certifications` to `make`, `.teach`, `README.md`?**
  _High betweenness centrality (0.027) - this node is a cross-community bridge._
- **Should `video.py` be split into smaller, more focused modules?**
  _Cohesion score 0.10730804810360776 - nodes in this community are weakly interconnected._