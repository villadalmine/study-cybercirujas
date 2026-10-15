# Graph Report - pr9  (2026-10-15)

## Corpus Check
- 155 files · ~207,674 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 15 file(s) not represented in the graph (top: (none) 12, .example 1, .service 1)

## Summary
- 2208 nodes · 4410 edges · 145 communities (95 shown, 50 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 149 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `5bb56d88`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Backlog
- lab/cli.py
- scaffold
- models_live.py
- video.py
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- claims.py
- make_completer
- labs.py
- Which backend authors better material?
- certs.py
- SnapshotStatusTest
- runner.py
- check
- topic_content
- Changelog
- Platform Architecture Plan
- Removed K8s API Checks
- teach/cli.py
- json
- Syllabus Coverage Tests
- _verify_translation
- check_versions.py
- Verifying the material is true — design notes
- ServerSmokeTests
- collections
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- main
- Roadmap — where this is and where it goes
- re
- metrics_report.py
- DeterminismTests
- Contributing
- check_manifests.py
- argparse
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
- get
- AI certification roadmap
- Operating the pipeline — for maintainers
- Within one certification (the only fair comparisons; authoring language `en` only)
- EnvScopeTests
- tempfile
- subprocess
- steer.py
- status_matrix.py
- test_source_chain.py
- generate_topic
- OpenWiki scope for teach-plat
- run_cert.py
- The phases
- check_syllabus.py
- tracker.py
- bot_loop_check.js
- rules
- Content Workflow
- catalog.py
- steer.py
- ComprehensionTests
- topic_content
- study.cybercirujas — free, open study material for IT certifications
- CatalogueStateTests
- response
- FixtureTests
- LanguageTests
- CheckDocsTests
- Documentation audit — 2026-10-14
- _video_info
- lab.md
- translation.md
- PathLanguageTests
- check_provenance.py
- video.md
- topics
- clone_and_run.sh
- Client
- pull_request_template.md
- code.md
- content.md
- docs.md
- prove_labs_cka_pilot.sh
- bad.md
- good.md
- Pull requests
- model_comparison.py
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- check_source_chain.py
- EndpointTests
- CONTRIBUTING.md
- lab_step.sh
- RegenerateTests
- .teach
- Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)
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
- re
- api.py
- CitedRunTests
- OwnedTeardownTests
- MainTests
- test_legal_notice.py
- check_k8s_apis.py
- check_claims.py
- _script_user
- _exec_script_cmd
- sitecustomize.py
- Automated review (Copilot)
- _owner_label
- ReferencesTest
- generation
- _split_answer
- test_mcp_server.py
- EnterHintTests
- check_config.py
- check_api_facts.py
- test_check_pr.py
- CheckUpdatesDocTests
- CitationsHeadingTests

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
10. `read()` - 18 edges

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

## Communities (145 total, 50 thin omitted)

### Community 0 - "Backlog"
Cohesion: 0.25
Nodes (8): Backlog, Content, Deploy — Technical Debt, Labs — Execution Modes (see PLAN.md, SDD section), Pipeline Automation, RAG Study Bot — Proposal Under Review (`chart/`) — superseded, Repo Hygiene, Verifying the material is TRUE (docs/AUDITOR_DESIGN.md)

### Community 1 - "lab/cli.py"
Cohesion: 0.05
Nodes (56): Tests, _banner(), _clone(), cmd_hint(), cmd_list(), cmd_migrate(), cmd_new(), cmd_validate() (+48 more)

### Community 2 - "scaffold"
Cohesion: 0.18
Nodes (4): default_spec(), scaffold(), validate_spec(), ContractTests

### Community 3 - "models_live.py"
Cohesion: 0.07
Nodes (20): main(), Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos, Spend (measured) (+12 more)

### Community 4 - "video.py"
Cohesion: 0.11
Nodes (32): Video — Technical Debt, 2026-07-17, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat(), _domains_voiceover() (+24 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.05
Nodes (38): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails, From claude — 2026-08-14: where this stands, and how to resume (+30 more)

### Community 6 - "claims.py"
Cohesion: 0.06
Nodes (25): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+17 more)

### Community 7 - "make_completer"
Cohesion: 0.22
Nodes (7): _usable_translate_backend(), _agent_completer(), _antigravity_completer(), complete(), GeneratorConfigError, complete(), make_completer()

### Community 8 - "labs.py"
Cohesion: 0.17
Nodes (20): Labs — what an audit found, 2026-08-08 (design parked, not started), _break_args(), down(), _down_cluster(), enter_hint(), lab_dir(), _lab_name(), LabError (+12 more)

### Community 9 - "Which backend authors better material?"
Cohesion: 0.25
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 10 - "certs.py"
Cohesion: 0.21
Nodes (4): content_dir(), get_topic(), topic_outdated_langs(), StaleCycleTest

### Community 12 - "runner.py"
Cohesion: 0.06
Nodes (54): Create a lab that follows the template, How it works, Measured (WSL2 Ubuntu 24.04 on the workstation, Docker 29.8, 2026-10-15), Not done yet, Pinned versions, Quick start, Run a lab from another repository, State of the 548 curated labs (validate, 2026-10-15) (+46 more)

### Community 14 - "topic_content"
Cohesion: 0.15
Nodes (12): In Progress / Next (Ordering), 2026-08-20, topic_content(), 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 4. Status (+4 more)

### Community 15 - "Changelog"
Cohesion: 0.10
Nodes (21): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-19, 2026-07-27, 2026-07-28, 2026-09-10, 2026-09-14 (+13 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.14
Nodes (14): Catalog by Categories, CLI, Code Architecture, Data Model, Decoupled Lab Runner (Future, Go), Design Principles, Educational Platform, Execution Modes + Exercise Videos (SDD — evaluation, pending implementation) (+6 more)

### Community 18 - "teach/cli.py"
Cohesion: 0.08
Nodes (20): cert_add(), cert_generate(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+12 more)

### Community 19 - "json"
Cohesion: 0.14
Nodes (11): 2026-09-11, main(), probe(), record(), show_history(), evaluate(), main(), master_key() (+3 more)

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.12
Nodes (8): From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives, What I need from you, What is now enforced, so this cannot recur, What this means for your work, normalise_weights(), objective_ids(), _reject_unreadable_syllabus(), SyllabusCoverageTests

### Community 21 - "_verify_translation"
Cohesion: 0.07
Nodes (16): 2026-08-03, 2026-09-11, Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results, Three bugs this study found in our own checks (+8 more)

### Community 22 - "check_versions.py"
Cohesion: 0.21
Nodes (6): frozen(), main(), _same_version(), state(), survey(), published_version()

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 26 - "collections"
Cohesion: 0.21
Nodes (7): main(), _money(), rows(), _tokens(), _cmd(), test_job_ids_are_unique_across_workflows(), test_k8s_inner_dockerd_listens_on_the_unix_socket_only()

### Community 27 - "Developers — use the API, run your own copy, build on it"
Cohesion: 0.20
Nodes (10): Building features on it, Developers — use the API, run your own copy, build on it, DORA, concretely, Keeping this page true, Licence, Staying in sync with upstream, ⚠️ The API is beta, and hosted on a home cluster, ⚠️ The content is AI-generated — and that carries real risk (+2 more)

### Community 28 - "clean_registry.py"
Cohesion: 0.42
Nodes (5): deployed_tags(), in_registry(), kubectl(), main(), usage()

### Community 29 - "main"
Cohesion: 0.13
Nodes (13): find_missing_videos(), main(), _record_quota_block(), strip_fences_in_place(), generate_with_retries(), main(), budget(), is_fatal() (+5 more)

### Community 30 - "Roadmap — where this is and where it goes"
Cohesion: 0.25
Nodes (8): Current focus — set 2026-09-11, Roadmap — where this is and where it goes, Smaller things, when there is an appetite, Standing decisions worth not re-litigating, Study bot — the phases after this one, What is next, Where it is, Where we left off — 2026-09-30

### Community 31 - "re"
Cohesion: 0.07
Nodes (30): anchors(), check_file(), generated_checks(), main(), make_targets(), prose_lines(), slug(), teach_commands() (+22 more)

### Community 32 - "metrics_report.py"
Cohesion: 0.17
Nodes (11): backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), cooldown_until(), exhaustions() (+3 more)

### Community 34 - "Contributing"
Cohesion: 0.15
Nodes (15): Open — worth someone's time, Checks that must pass, Contributing, Conventions, Licence and conduct, Merging and deploying the site, No braindumps, no NDA material, Provenance is mandatory (+7 more)

### Community 35 - "check_manifests.py"
Cohesion: 0.17
Nodes (8): main(), problems(), _skip(), _VendorTagLoader, main(), status_rows(), table(), main()

### Community 36 - "argparse"
Cohesion: 0.15
Nodes (9): evidence(), main(), classify(), main(), main(), by_topic(), dominant(), main() (+1 more)

### Community 37 - "probe_models.py"
Cohesion: 0.09
Nodes (20): ask_retrying(), catalogue_state(), detect_language(), graded(), main(), material(), off_switch(), _price() (+12 more)

### Community 44 - "StoredShapeTests"
Cohesion: 0.07
Nodes (19): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Pull requests from agents, Rules, Verification: what is proven, and what is only assumed, 6. Where the value actually is (owner's question, 2026-08-18) (+11 more)

### Community 45 - "search_topics"
Cohesion: 0.06
Nodes (18): _fold(), get_syllabus(), get_topic(), _informative(), list_certs(), search_topics(), _terms(), _readable() (+10 more)

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
Cohesion: 0.09
Nodes (15): 2026-07-29, 2026-08-04, _cert_topic_ids(), find_bad_combos(), _finish(), _publish_if_complete(), _refresh_status(), render_ready_videos() (+7 more)

### Community 50 - "pipeline.py"
Cohesion: 0.19
Nodes (9): default_languages(), in_milestone(), load(), milestone(), milestone_targets(), on_demand_languages(), path_video_languages(), PipelineError (+1 more)

### Community 52 - "publish_if_complete.py"
Cohesion: 0.23
Nodes (8): complete_certs(), is_complete(), main(), publish(), _record(), _save(), _topic_ids(), check_file()

### Community 53 - "test_lpic2_200_1_review.py"
Cohesion: 0.07
Nodes (21): AlertsTest, CitationsTest, ConntrackLabTest, ConntrackSizeTest, CpuPressureTest, LabContractTest, ListenQueueTest, MathisTest (+13 more)

### Community 54 - "get"
Cohesion: 0.13
Nodes (7): get_bot_stats(), get_catalog(), get_langs(), get_search(), get_status(), healthz(), index()

### Community 55 - "AI certification roadmap"
Cohesion: 0.22
Nodes (9): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 1 — AI fundamentals (extends the three cloud careers), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters (+1 more)

### Community 56 - "Operating the pipeline — for maintainers"
Cohesion: 0.14
Nodes (14): Checking curriculum updates, Content process, Deploying to Kubernetes, Environment variables, Keeping it honest over time, Languages, Operating the pipeline — for maintainers, Quality (+6 more)

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.18
Nodes (11): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, mcpa, Model Comparison (+3 more)

### Community 59 - "tempfile"
Cohesion: 0.24
Nodes (4): embedded_text(), fetch(), main(), ocr()

### Community 61 - "subprocess"
Cohesion: 0.15
Nodes (10): graphify_bin(), main(), normalized(), rebuild_in_copy(), regenerate(), touches_graph_sources(), main(), main() (+2 more)

### Community 62 - "steer.py"
Cohesion: 0.25
Nodes (7): main(), create_block(), main(), show(), certs(), languages_for(), targets()

### Community 63 - "status_matrix.py"
Cohesion: 0.21
Nodes (8): cert_topics(), check(), lab_cell(), lang_cell(), refresh(), _render(), _spend_section(), _write()

### Community 64 - "test_source_chain.py"
Cohesion: 0.19
Nodes (5): citations(), main(), status(), section(), _free_port()

### Community 65 - "generate_topic"
Cohesion: 0.16
Nodes (8): topic_langs(), generate_topic(), _reusable(), _reject_if_substandard(), _topic_context(), translate_topic(), _write_meta(), First, the thing that surprises everyone

### Community 66 - "OpenWiki scope for teach-plat"
Cohesion: 0.33
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 67 - "run_cert.py"
Cohesion: 0.47
Nodes (3): main(), pending_topics(), run()

### Community 68 - "The phases"
Cohesion: 0.08
Nodes (26): Alternatives considered, Can it read what we send it? (2026-09-11, second pass), Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Phase 1.5 — BUILT 2026-09-14 (option A) (+18 more)

### Community 69 - "check_syllabus.py"
Cohesion: 0.27
Nodes (4): load_syllabus(), main(), smells(), upstream_objectives()

### Community 70 - "tracker.py"
Cohesion: 0.12
Nodes (13): 2026-07-16, tracker_sync(), _ai_yaml(), _apply_snapshot_status(), fetch_text(), _get(), _get_bytes(), snapshot_topics() (+5 more)

### Community 71 - "bot_loop_check.js"
Cohesion: 0.06
Nodes (24): fs, KEY, line, ONLY, path, PORT, REPO, SHAPES (+16 more)

### Community 73 - "Content Workflow"
Cohesion: 0.25
Nodes (8): Backends, Content Workflow, Everything the pipeline produces is declared in `pipeline.yaml`, Failure modes worth knowing, Language flow: author once in English, translate outwards, Switching to Gemini (or any CLI agent), Translating instead of re-authoring, Unattended runs and quota

### Community 74 - "catalog.py"
Cohesion: 0.13
Nodes (15): _status_snapshot(), add_cert(), _BlockDumper, catalog_path(), get_cert(), list_certs(), load(), load_models() (+7 more)

### Community 77 - "topic_content"
Cohesion: 0.29
Nodes (4): get_paths(), get_topic(), get_topic_preview(), _valid_lang()

### Community 78 - "study.cybercirujas — free, open study material for IT certifications"
Cohesion: 0.15
Nodes (13): AI-generated content, Ask questions about the material with a local model (RAG), ⚖️ Aviso Legal y de Marcas Registradas / Legal & Trademark Disclaimer, Certifications, Contributing, For maintainers, Licence, Practice: break-and-fix labs (+5 more)

### Community 80 - "response"
Cohesion: 0.13
Nodes (4): OffSwitchTests, response(), ThinkingTests, VerdictTests

### Community 84 - "Documentation audit — 2026-10-14"
Cohesion: 0.50
Nodes (4): Documentation audit — 2026-10-14, Fixed in this pass, `graphify-out/` and `openwiki/` — what they are and whether they belong, Needs the owner's decision

### Community 85 - "_video_info"
Cohesion: 0.33
Nodes (3): get_cert_video(), get_path_video(), _video_info()

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

### Community 91 - "topics"
Cohesion: 0.50
Nodes (3): 2026-09-17, get_cert(), topics()

### Community 92 - "clone_and_run.sh"
Cohesion: 0.33
Nodes (7): fail(), get(), ok(), PYTHONPATH, clone_and_run.sh script, step(), TEACH_OFFLINE

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

### Community 101 - "Pull requests"
Cohesion: 0.50
Nodes (4): Agents, Labels, Pull requests, Size and scope

### Community 102 - "model_comparison.py"
Cohesion: 0.13
Nodes (11): main(), _md_table(), observations(), render_markdown(), _stats(), usage_by_topic(), write(), _kind() (+3 more)

### Community 103 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.22
Nodes (8): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 5. Costs, summarized, 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith), Integration cautions (this repo specifically), Optional, costs completions (cheap, LiteLLM-able), What Graphify gives agents

### Community 104 - "check_source_chain.py"
Cohesion: 0.07
Nodes (21): 2026-10-15, 1. Information sovereignty, 2. Curriculum-as-Code, 3. Determinism, 4. With AI or without AI: the same pipeline and the same validator, 5. Honest about limits, 6. Open by default, 7. The source chain (+13 more)

### Community 107 - "CONTRIBUTING.md"
Cohesion: 0.22
Nodes (7): Code of Conduct, Becoming a maintainer, Code of conduct, Day-to-day changes, Governance, Proposals (RFCs) — for anything that changes how the project works, Who maintains what, today

### Community 108 - "lab_step.sh"
Cohesion: 0.53
Nodes (4): fail(), ok(), ours(), lab_step.sh script

### Community 111 - "Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)"
Cohesion: 0.29
Nodes (8): Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), German translation: working recipe found, blocked on timeout, Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09), What I finished, What I need from you, 3. LangSmith — optional visibility, narrow fit, 4. The plan, _litellm_completer()

### Community 113 - ".mcp.json"
Cohesion: 0.67
Nodes (3): .venv/bin/python3, graphify, teach

### Community 124 - "re"
Cohesion: 0.29
Nodes (4): catalogue(), cited_domains(), duplicate_keys(), main()

### Community 125 - "api.py"
Cohesion: 0.15
Nodes (7): BotUsage, login(), LoginBody, logout(), post_bot_used(), require_subscriber(), require_user()

### Community 129 - "test_legal_notice.py"
Cohesion: 0.33
Nodes (3): legal_section(), LegalNoticeTests, owner()

### Community 130 - "check_k8s_apis.py"
Cohesion: 0.24
Nodes (3): _deliberate(), findings(), main()

### Community 131 - "check_claims.py"
Cohesion: 0.36
Nodes (3): ask(), main(), references()

### Community 134 - "sitecustomize.py"
Cohesion: 0.47
Nodes (3): _connect(), _connect_ex(), _host()

### Community 137 - "Automated review (Copilot)"
Cohesion: 0.33
Nodes (5): Authorship: who wrote it, who found what, who fixed it, Automated review (Copilot), How it behaves, How we work with it, When a PR is ready

### Community 141 - "generation"
Cohesion: 0.28
Nodes (4): complete(), _cli_env(), _dominant_model(), CliEnvTest

### Community 146 - "check_config.py"
Cohesion: 0.29
Nodes (6): Generation backends, dominant(), effective(), main(), recent(), generation()

### Community 148 - "check_api_facts.py"
Cohesion: 0.36
Nodes (4): check(), main(), spec_kinds(), tracked_versions()

### Community 150 - "test_check_pr.py"
Cohesion: 0.14
Nodes (4): IncrementalContractTests, verify_workflow(), VerifyWorkflowTests, WhereItRanTests

## Knowledge Gaps
- **4 isolated node(s):** `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE`, `PYTHONPATH`
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 928 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **50 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `kubectl()` connect `clean_registry.py` to `Backlog`, `Contributing`, `video.py`, `labs.py`, `runner.py`, `topic_content`, `study.cybercirujas — free, open study material for IT certifications`, `_verify_translation`, `Developers — use the API, run your own copy, build on it`, `subprocess`, `Roadmap — where this is and where it goes`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **What connects `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE` to the rest of the system?**
  _4 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `lab/cli.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05005107252298264 - nodes in this community are weakly interconnected._
- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` to `Contributing`, `Syllabus Coverage Tests`, `Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)`, `README.md`?**
  _High betweenness centrality (0.030) - this node is a cross-community bridge._
- **Should `models_live.py` be split into smaller, more focused modules?**
  _Cohesion score 0.0666049953746531 - nodes in this community are weakly interconnected._
- **Why does `Changelog` connect `Changelog` to `video.py`, `tracker.py`, `check_source_chain.py`, `topic_content`, `fix_corrupted_content.py`, `json`, `_verify_translation`, `README.md`, `topics`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._
- **Should `video.py` be split into smaller, more focused modules?**
  _Cohesion score 0.10730804810360776 - nodes in this community are weakly interconnected._