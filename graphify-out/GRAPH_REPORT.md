# Graph Report - study-cybercirujas  (2026-10-20)

## Corpus Check
- 231 files · ~250,365 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 17 file(s) not represented in the graph (top: (none) 13, .example 1, .service 1)

## Summary
- 2840 nodes · 5633 edges · 215 communities (125 shown, 90 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 161 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `74007087`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- teach/cli.py
- lab/cli.py
- Operating the pipeline — for maintainers
- models_live.py
- video.py
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- claims.py
- generator.py
- scaffold
- Which backend authors better material?
- certs.py
- SnapshotStatusTest
- runner.py
- check
- snapshot_topics
- History
- Platform Architecture Plan
- Removed K8s API Checks
- re
- The routine, start to finish
- Syllabus Coverage Tests
- _verify_translation
- Content Status
- Verifying the material is true — design notes
- ServerSmokeTests
- lab/cli.py
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- load
- Roadmap — where this is and where it goes
- re
- check_pr.py
- DeterminismTests
- check_groundedness.py
- CheckLabelsTests
- publish_if_complete.py
- probe_models.py
- Milestone Run Script
- CheckPrTests
- Resume Generation Script
- Project Root
- StoredShapeTests
- verdict
- has_subscription
- get_topic
- 1. The code graph (Graphify)
- fix_corrupted_content.py
- translation_study.py
- ProtocolTests
- check_labels.py
- test_lpic2_200_1_review.py
- get
- AI certification roadmap
- test_kc_meta.py
- Within one certification (the only fair comparisons; authoring language `en` only)
- EnvScopeTests
- catalog.py
- subprocess
- pipeline.py
- status_matrix.py
- release-please-config.json
- RejectsDamagedTranslations
- test_groundedness.py
- QualityOnlyTests
- The phases
- steer.py
- test_kc_test.py
- bot_loop_check.js
- get_syllabus
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- tracker.py
- search_topics
- ComprehensionTests
- BlockTests
- study.cybercirujas — free, open study material for IT certifications
- CatalogueStateTests
- response
- FixtureTests
- LanguageTests
- CheckDocsTests
- Documentation audit — 2026-10-14
- test_web_render.py
- lab.md
- translation.md
- test_api_404_paths.py
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
- make
- model_comparison.py
- test_corpus.py
- check_source_chain.py
- ReviewTests
- EndpointTests
- CONTRIBUTING.md
- lab_step.sh
- RegenerateTests
- .teach
- pytest
- labs.py
- .mcp.json
- pr_check.py
- k8s/study-lab-init.sh
- ext_os_release
- linux/study-lab-init.sh
- kind/break_fix.sh
- linux/break_fix.sh
- up
- _prompt_on_stdin
- AuthorshipTests
- quality_score.py
- api.py
- study-lab — break/fix labs in a throwaway container
- check_citations.py
- MainTests
- test_killercoda_publish.py
- Backlog
- StaleCycleTest
- Study bot — design
- topic_content
- Pull requests
- check_syllabus.py
- OwnedTeardownTests
- Automated review (Copilot)
- milestone
- ReferencesTest
- EndpointTests
- next_work.py
- _split_answer
- probe_languages
- test_helm_secret_required.py
- OpenWiki scope for teach-plat
- quota.py
- check_config.py
- PathLanguageTests
- ImageHardeningTests
- verify_workflow
- CheckUpdatesDocTests
- 1.1 Title
- ScopeSectionTests
- test_legal_notice.py
- ScopeTests
- exam_version
- Content Workflow
- Development Guidelines for teach-plat
- ExamVersionWiringTests
- _cli_env
- check_api_facts.py
- DisclosureTests
- _script_user
- PrCheckTests
- is_bot_pr
- _exec_script_cmd
- Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)
- 1-1-demo-linux-lab/background.sh
- 1-1-demo-linux-lab/cleanup.sh
- scope
- CitationsHeadingTests
- _glob
- exam_version_changes
- 1-1-demo-linux-lab/verify.sh
- 1-2-demo-kind-lab/background.sh
- 1-2-demo-kind-lab/cleanup.sh
- 1-2-demo-kind-lab/verify.sh
- IncrementalContractTests
- LabRunnerLifecycleTests
- bootstrap-kubeadm.sh
- ContractTests
- publish.sh
- cka-1.1.sh
- lpic-2-200.1.sh
- killercoda/probe/k8s/intro.md
- killercoda/probe/ubuntu/intro.md
- check_provenance.py
- 1-1-demo-linux-lab/assets/break_fix.sh
- 1-1-demo-linux-lab/finish.md
- 1-1-demo-linux-lab/foreground.sh
- 1-1-demo-linux-lab/intro.md
- 1-1-demo-linux-lab/step1.md
- 1-1-demo-linux-lab/step2.md
- 1-2-demo-kind-lab/assets/break_fix.sh
- 1-2-demo-kind-lab/finish.md
- 1-2-demo-kind-lab/foreground.sh
- 1-2-demo-kind-lab/intro.md
- 1-2-demo-kind-lab/step1.md
- 1-2-demo-kind-lab/step2.md
- democert/README.md
- golden/probe/k8s/intro.md
- golden/probe/ubuntu/intro.md
- lab_kc/kind/break_fix.sh
- lab_kc/linux/break_fix.sh
- _owner_label
- corpus.py
- Check before you push
- HostGuardTests
- mcp_server.py
- _BlockDumper
- [0.3.0](https://github.com/villadalmine/study-cybercirujas/compare/v0.2.0...v0.3.0) (2026-10-16)
- WhereItRanTests
- verify_runs

## God Nodes (most connected - your core abstractions)
1. `load()` - 37 edges
2. `History` - 28 edges
3. `ExamVersionTests` - 27 edges
4. `main()` - 24 edges
5. `generate_topic()` - 24 edges
6. `main()` - 22 edges
7. `scenario()` - 22 edges
8. `CheckPrTests` - 22 edges
9. `Lab` - 21 edges
10. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 21 edges

## Surprising Connections (you probably didn't know these)
- `2026-09-10` --references--> `survey()`  [INFERRED]
  docs/HISTORY.md → scripts/check_versions.py
- `State of the 548 curated labs (validate, 2026-10-15)` --references--> `kubectl()`  [INFERRED]
  docs/LABS-RUNNER.md → scripts/clean_registry.py
- `Practice: break-and-fix labs` --references--> `kubectl()`  [INFERRED]
  README.md → scripts/clean_registry.py
- `Phase 1 — SHIPPED 2026-09-09` --references--> `usage()`  [INFERRED]
  docs/STUDY_BOT_DESIGN.md → scripts/clean_registry.py
- `2026-07-29` --references--> `find_bad_combos()`  [INFERRED]
  docs/HISTORY.md → scripts/fix_corrupted_content.py

## Import Cycles
- None detected.

## Communities (215 total, 90 thin omitted)

### Community 0 - "teach/cli.py"
Cohesion: 0.09
Nodes (17): cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script(), lab_down() (+9 more)

### Community 1 - "lab/cli.py"
Cohesion: 0.11
Nodes (24): Tests, docker_ok(), git_repo(), image_ok(), run_cli(), test_all_curated_labs_pass_the_schema(), test_curated_pilot_labs_are_strict_valid_and_verified(), test_from_repo_path_cannot_escape() (+16 more)

### Community 2 - "Operating the pipeline — for maintainers"
Cohesion: 0.15
Nodes (13): Checking curriculum updates, Content process, Deploying to Kubernetes, Environment variables, Keeping it honest over time, Operating the pipeline — for maintainers, Quality, Quickstart (maintainers) (+5 more)

### Community 3 - "models_live.py"
Cohesion: 0.16
Nodes (9): main(), annotate(), compare(), moved(), per_million(), AnnotateTests, catalogue(), CompareTests (+1 more)

### Community 4 - "video.py"
Cohesion: 0.11
Nodes (32): Video — Technical Debt, 2026-07-17, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat(), _domains_voiceover() (+24 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.05
Nodes (39): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, Every commit is signed off (DCO), First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails (+31 more)

### Community 6 - "claims.py"
Cohesion: 0.11
Nodes (8): active(), claim(), is_claimed(), _path(), _try_lock(), _unlock(), ClaimTest, _try_claim()

### Community 7 - "generator.py"
Cohesion: 0.11
Nodes (19): cert_generate(), _agent_completer(), complete(), _antigravity_completer(), complete(), _dominant_model(), generate_cert(), generate_topic() (+11 more)

### Community 8 - "scaffold"
Cohesion: 0.17
Nodes (5): default_spec(), lab_dir(), scaffold(), validate_spec(), ContractTests

### Community 9 - "Which backend authors better material?"
Cohesion: 0.25
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 10 - "certs.py"
Cohesion: 0.19
Nodes (11): clear_topic_stale(), content_dir(), get_topic(), load(), md_path(), _read(), save(), scaffold() (+3 more)

### Community 11 - "SnapshotStatusTest"
Cohesion: 0.21
Nodes (3): _apply_snapshot_status(), _topic_identity(), SnapshotStatusTest

### Community 12 - "runner.py"
Cohesion: 0.08
Nodes (42): build(), check(), container_name(), _docker(), down(), ensure_image(), image_for(), _in_time() (+34 more)

### Community 13 - "check"
Cohesion: 0.13
Nodes (5): _reusable(), check(), rules(), QualityFloorTest, QualityThresholdsTest

### Community 14 - "snapshot_topics"
Cohesion: 0.18
Nodes (11): 2026-07-16, snapshot_topics(), TrackerError, 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 4. Status (+3 more)

### Community 15 - "History"
Cohesion: 0.09
Nodes (25): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-19, 2026-07-27, 2026-07-28, 2026-07-29, 2026-09-10 (+17 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.14
Nodes (14): Catalog by Categories, CLI, Code Architecture, Data Model, Decoupled Lab Runner (Future, Go), Design Principles, Educational Platform, Execution Modes + Exercise Videos (SDD — evaluation, pending implementation) (+6 more)

### Community 18 - "re"
Cohesion: 0.08
Nodes (29): cmd_export(), bash_n(), cert_names(), check_tree(), _env(), ExportError, _fence(), _footer() (+21 more)

### Community 19 - "The routine, start to finish"
Cohesion: 0.12
Nodes (17): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+9 more)

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

### Community 26 - "lab/cli.py"
Cohesion: 0.13
Nodes (14): _banner(), _clone(), cmd_hint(), cmd_list(), cmd_migrate(), cmd_new(), cmd_validate(), _lab_dir() (+6 more)

### Community 27 - "Developers — use the API, run your own copy, build on it"
Cohesion: 0.20
Nodes (10): Building features on it, Developers — use the API, run your own copy, build on it, DORA, concretely, Keeping this page true, Licence, Staying in sync with upstream, ⚠️ The API is beta, and hosted on a home cluster, ⚠️ The content is AI-generated — and that carries real risk (+2 more)

### Community 28 - "clean_registry.py"
Cohesion: 0.42
Nodes (5): deployed_tags(), in_registry(), kubectl(), main(), usage()

### Community 29 - "load"
Cohesion: 0.17
Nodes (19): infer_contract(), load(), load_schema(), normalize(), schema_errors(), _verb_present(), test_crlf_script_rejected(), test_declared_modes_override_inference() (+11 more)

### Community 30 - "Roadmap — where this is and where it goes"
Cohesion: 0.25
Nodes (8): Current focus — set 2026-09-11, Roadmap — where this is and where it goes, Smaller things, when there is an appetite, Standing decisions worth not re-litigating, Study bot — the phases after this one, What is next, Where it is, Where we left off — 2026-09-30

### Community 31 - "re"
Cohesion: 0.19
Nodes (10): anchors(), check_file(), generated_checks(), main(), make_targets(), prose_lines(), slug(), teach_commands() (+2 more)

### Community 32 - "check_pr.py"
Cohesion: 0.09
Nodes (21): authorship(), base_texts(), _cells(), changed_files(), check(), cited_runs(), code_lines_changed(), commits_of() (+13 more)

### Community 34 - "check_groundedness.py"
Cohesion: 0.09
Nodes (18): best_windows(), changed(), check_topic(), cited(), claims(), download(), fetch(), fixture() (+10 more)

### Community 36 - "publish_if_complete.py"
Cohesion: 0.29
Nodes (7): complete_certs(), is_complete(), main(), publish(), _record(), _save(), _topic_ids()

### Community 37 - "probe_models.py"
Cohesion: 0.14
Nodes (11): ask(), ask_retrying(), catalogue_state(), main(), material(), _price(), probe_one(), probe_tools() (+3 more)

### Community 40 - "CheckPrTests"
Cohesion: 0.06
Nodes (4): CheckPrTests, commit(), DcoMainTests, DcoTests

### Community 44 - "StoredShapeTests"
Cohesion: 0.12
Nodes (7): accepted(), _blank(), _known_models(), load(), record(), AcceptanceTests, StoredShapeTests

### Community 45 - "verdict"
Cohesion: 0.16
Nodes (7): off_switch(), rejects_reasoning(), thinking_mode(), thought(), tool_call_of(), tool_verdict(), verdict()

### Community 46 - "has_subscription"
Cohesion: 0.20
Nodes (8): Platform (Long-Term Roadmap, see PLAN.md), 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, me(), authenticate(), has_subscription()

### Community 47 - "get_topic"
Cohesion: 0.17
Nodes (6): get_cert(), get_paths(), get_topic(), get_topic_preview(), _not_found(), _valid_lang()

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "fix_corrupted_content.py"
Cohesion: 0.12
Nodes (12): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), _record_quota_block(), _refresh_status() (+4 more)

### Community 50 - "translation_study.py"
Cohesion: 0.13
Nodes (10): 6. Where the value actually is (owner's question, 2026-08-18), Languages, main(), table(), evaluate(), main(), master_key(), translate() (+2 more)

### Community 52 - "check_labels.py"
Cohesion: 0.30
Nodes (6): check(), load_labels(), main(), references(), _split(), _walk_label_inputs()

### Community 53 - "test_lpic2_200_1_review.py"
Cohesion: 0.07
Nodes (21): AlertsTest, CitationsTest, ConntrackLabTest, ConntrackSizeTest, CpuPressureTest, LabContractTest, ListenQueueTest, MathisTest (+13 more)

### Community 54 - "get"
Cohesion: 0.10
Nodes (10): get_bot_stats(), get_catalog(), get_cert_video(), get_langs(), get_path_video(), get_search(), get_status(), healthz() (+2 more)

### Community 55 - "AI certification roadmap"
Cohesion: 0.25
Nodes (8): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters, Watchlist — official, but they fail a filter today

### Community 56 - "test_kc_meta.py"
Cohesion: 0.12
Nodes (20): banner(), decorate(), human_record(), lab_hash(), provenance(), source_commit(), syllabus(), _yaml() (+12 more)

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.18
Nodes (11): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, mcpa, Model Comparison (+3 more)

### Community 59 - "catalog.py"
Cohesion: 0.13
Nodes (17): main(), _status_snapshot(), add_cert(), catalog_path(), get_cert(), list_certs(), load(), load_models() (+9 more)

### Community 61 - "subprocess"
Cohesion: 0.11
Nodes (14): graphify_bin(), main(), normalized(), rebuild_in_copy(), regenerate(), touches_graph_sources(), embedded_text(), fetch() (+6 more)

### Community 62 - "pipeline.py"
Cohesion: 0.11
Nodes (19): generate(), generate_with_retries(), main(), pending(), _sort_key(), budget(), default_languages(), is_fatal() (+11 more)

### Community 63 - "status_matrix.py"
Cohesion: 0.12
Nodes (13): frozen(), _same_version(), state(), survey(), cert_topics(), check(), lab_cell(), lang_cell() (+5 more)

### Community 64 - "release-please-config.json"
Cohesion: 0.18
Nodes (10): bootstrap-sha, bump-minor-pre-major, bump-patch-for-minor-pre-major, changelog-path, changelog-sections, include-component-in-tag, include-v-in-tag, packages (+2 more)

### Community 66 - "test_groundedness.py"
Cohesion: 0.20
Nodes (5): Determinism, NoNetwork, overlap(), run(), Segmentation

### Community 68 - "The phases"
Cohesion: 0.13
Nodes (15): Can it read what we send it? (2026-09-11, second pass), Phase 1.5 — BUILT 2026-09-14 (option A), Phase 1.5 — closing the loop: checks that improve the page, Phase 1 — feedback, and the probe that answers it (2026-09-11), Phase 1 — SHIPPED 2026-09-09, Phase 1 — topic chat with a task harness, Phase 2 — BUILT 2026-09-14, Phase 2 — questions across one certification (+7 more)

### Community 69 - "steer.py"
Cohesion: 0.16
Nodes (10): 2026-10-15, main(), _cert_block(), create_block(), main(), set_key(), show(), certs() (+2 more)

### Community 70 - "test_kc_test.py"
Cohesion: 0.08
Nodes (26): cmd_test(), load_envs(), evidence(), measure(), parse_cni(), resolve_env(), run_scenario(), stage() (+18 more)

### Community 71 - "bot_loop_check.js"
Cohesion: 0.06
Nodes (24): fs, KEY, line, ONLY, path, PORT, REPO, SHAPES (+16 more)

### Community 72 - "get_syllabus"
Cohesion: 0.24
Nodes (5): syllabus(), topics(), get_syllabus(), list_certs(), ListAndSyllabusTests

### Community 73 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.18
Nodes (10): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith), Integration cautions (this repo specifically) (+2 more)

### Community 74 - "tracker.py"
Cohesion: 0.15
Nodes (8): Phase 1 — AI fundamentals (extends the three cloud careers), tracker_sync(), fetch_text(), _get(), _get_bytes(), published_version(), sync_clouds(), sync_cncf()

### Community 78 - "study.cybercirujas — free, open study material for IT certifications"
Cohesion: 0.15
Nodes (13): AI-generated content, Ask questions about the material with a local model (RAG), ⚖️ Aviso Legal y de Marcas Registradas / Legal & Trademark Disclaimer, Certifications, Contributing, For maintainers, Licence, Practice: break-and-fix labs (+5 more)

### Community 80 - "response"
Cohesion: 0.13
Nodes (4): OffSwitchTests, response(), ThinkingTests, VerdictTests

### Community 84 - "Documentation audit — 2026-10-14"
Cohesion: 0.50
Nodes (4): Documentation audit — 2026-10-14, Fixed in this pass, `graphify-out/` and `openwiki/` — what they are and whether they belong, Needs the owner's decision

### Community 85 - "test_web_render.py"
Cohesion: 0.26
Nodes (4): renderer_source(), RendererTests, run_js(), StaticTests

### Community 86 - "lab.md"
Cohesion: 0.14
Nodes (13): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Lab cycle (+5 more)

### Community 87 - "translation.md"
Cohesion: 0.14
Nodes (13): Authorship, Depends on, Evidence, Findings ledger, How to test it from a clean clone, Kind, Known gaps, Provenance (+5 more)

### Community 89 - "argparse"
Cohesion: 0.07
Nodes (18): evidence(), main(), main(), classify(), main(), main(), status_rows(), table() (+10 more)

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

### Community 101 - "make"
Cohesion: 0.15
Nodes (14): Open — worth someone's time, Checks that must pass, Contributing, Conventions, Groundedness (advisory), Licence and conduct, Merging and deploying the site, Releases (+6 more)

### Community 102 - "model_comparison.py"
Cohesion: 0.05
Nodes (30): backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main(), _md_table() (+22 more)

### Community 103 - "test_corpus.py"
Cohesion: 0.18
Nodes (4): get_topic(), get_topic(), ContractTests, TopicTests

### Community 104 - "check_source_chain.py"
Cohesion: 0.09
Nodes (11): baseline(), Chain, frontmatter(), load_yaml(), main(), rel(), chain_sha256(), translation_source_sha256() (+3 more)

### Community 107 - "CONTRIBUTING.md"
Cohesion: 0.18
Nodes (8): Code of Conduct, Becoming a maintainer, Code of conduct, Day-to-day changes, Governance, Proposals (RFCs) — for anything that changes how the project works, Releases, Who maintains what, today

### Community 108 - "lab_step.sh"
Cohesion: 0.53
Nodes (4): fail(), ok(), ours(), lab_step.sh script

### Community 111 - "pytest"
Cohesion: 0.25
Nodes (11): url_allowed(), validate_envs(), _envs(), test_allowed_urls_pass(), test_bad_cilium_supported_minor(), test_bad_cilium_tag_reaching_cilium_install(), test_bad_kubernetes_patch(), test_bad_runtime_and_cli_versions() (+3 more)

### Community 112 - "labs.py"
Cohesion: 0.17
Nodes (9): lab_up(), _down_cluster(), enter_hint(), _lab_name(), _run(), status(), _status_cluster(), _status_container() (+1 more)

### Community 113 - ".mcp.json"
Cohesion: 0.67
Nodes (3): .venv/bin/python3, graphify, teach

### Community 114 - "pr_check.py"
Cohesion: 0.31
Nodes (9): changed(), check(), graph_status(), groundedness_cached(), label(), main(), report(), run() (+1 more)

### Community 116 - "ext_os_release"
Cohesion: 0.22
Nodes (4): probe.sh script, probe.sh script, probe.sh script, probe.sh script

### Community 121 - "up"
Cohesion: 0.27
Nodes (12): Labs — what an audit found, 2026-08-08 (design parked, not started), _break_args(), down(), LabError, _load_spec(), _needs_cluster(), _require(), _terraform() (+4 more)

### Community 124 - "quality_score.py"
Cohesion: 0.06
Nodes (34): _deliberate(), findings(), main(), main(), problems(), _skip(), _VendorTagLoader, catalogue() (+26 more)

### Community 125 - "api.py"
Cohesion: 0.15
Nodes (7): BotUsage, login(), LoginBody, logout(), post_bot_used(), require_subscriber(), require_user()

### Community 126 - "study-lab — break/fix labs in a throwaway container"
Cohesion: 0.04
Nodes (36): No braindumps, no NDA material, Provenance is mandatory, Raising a topic's quality score, Sign your commits (DCO), What you can contribute, Create a lab that follows the template, How it works, Measured (WSL2 Ubuntu 24.04 on the workstation, Docker 29.8, 2026-10-15) (+28 more)

### Community 127 - "check_citations.py"
Cohesion: 0.10
Nodes (10): citations(), main(), status(), ask(), main(), references(), section(), _connect() (+2 more)

### Community 129 - "test_killercoda_publish.py"
Cohesion: 0.50
Nodes (6): git(), mirror(), publish(), scenario(), test_an_export_without_scenarios_does_not_touch_the_mirror(), test_publish_adds_keeps_what_was_not_reproven_and_is_idempotent()

### Community 130 - "Backlog"
Cohesion: 0.25
Nodes (8): Backlog, Content, Deploy — Technical Debt, Labs — Execution Modes (see PLAN.md, SDD section), Pipeline Automation, RAG Study Bot — Proposal Under Review (`chart/`) — superseded, Repo Hygiene, Verifying the material is TRUE (docs/AUDITOR_DESIGN.md)

### Community 132 - "Study bot — design"
Cohesion: 0.20
Nodes (10): Alternatives considered, Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Study bot — design, The insight: explicit selection replaces retrieval (+2 more)

### Community 133 - "topic_content"
Cohesion: 0.18
Nodes (6): In Progress / Next (Ordering), 2026-08-20, topic_content(), summary(), VisibleTests, 6. Publish — only for a complete certification

### Community 134 - "Pull requests"
Cohesion: 0.29
Nodes (7): Agents, How big is my change?, How issue forms work, Labels, Pull requests, Size and scope, Triage and response times

### Community 135 - "check_syllabus.py"
Cohesion: 0.27
Nodes (4): load_syllabus(), main(), smells(), upstream_objectives()

### Community 137 - "Automated review (Copilot)"
Cohesion: 0.29
Nodes (7): Authorship: who wrote it, who found what, who fixed it, Automated review (Copilot), How it behaves, How we work with it, Recording a review in the material, The graph refresh PR, When a PR is ready

### Community 141 - "next_work.py"
Cohesion: 0.47
Nodes (3): main(), survey(), _topic_count()

### Community 143 - "probe_languages"
Cohesion: 0.29
Nodes (4): Re-probing, and two things the second run taught (2026-09-14), detect_language(), graded(), probe_languages()

### Community 145 - "OpenWiki scope for teach-plat"
Cohesion: 0.40
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 146 - "quota.py"
Cohesion: 0.36
Nodes (5): 2026-09-11, main(), probe(), record(), show_history()

### Community 147 - "check_config.py"
Cohesion: 0.29
Nodes (6): Generation backends, dominant(), effective(), main(), recent(), generation()

### Community 152 - "1.1 Title"
Cohesion: 0.50
Nodes (3): 1.1 Title, Intro, References

### Community 154 - "test_legal_notice.py"
Cohesion: 0.33
Nodes (3): legal_section(), LegalNoticeTests, owner()

### Community 156 - "exam_version"
Cohesion: 0.33
Nodes (3): exam_version(), milestone_mismatch(), version_matches()

### Community 157 - "Content Workflow"
Cohesion: 0.25
Nodes (8): Backends, Content Workflow, Everything the pipeline produces is declared in `pipeline.yaml`, Failure modes worth knowing, Language flow: author once in English, translate outwards, Switching to Gemini (or any CLI agent), Translating instead of re-authoring, Unattended runs and quota

### Community 158 - "Development Guidelines for teach-plat"
Cohesion: 0.29
Nodes (7): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Pull requests from agents, Rules, Verification: what is proven, and what is only assumed

### Community 161 - "check_api_facts.py"
Cohesion: 0.43
Nodes (4): check(), main(), spec_kinds(), tracked_versions()

### Community 165 - "is_bot_pr"
Cohesion: 0.20
Nodes (5): dco(), is_bot_pr(), is_graph_refresh(), is_release_please(), noreply()

### Community 167 - "Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09)"
Cohesion: 0.40
Nodes (5): Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), German translation: working recipe found, blocked on timeout, Queue — Antigravity to Claude, 2026-08-08 (updated 2026-08-09), What I finished, What I need from you

### Community 168 - "1-1-demo-linux-lab/background.sh"
Cohesion: 0.40
Nodes (4): I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM, LAB_DISPOSABLE, background.sh script, STUDY_LAB

### Community 169 - "1-1-demo-linux-lab/cleanup.sh"
Cohesion: 0.40
Nodes (4): I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM, LAB_DISPOSABLE, cleanup.sh script, STUDY_LAB

### Community 172 - "_glob"
Cohesion: 0.33
Nodes (3): _glob(), image_paths(), site_impact()

### Community 173 - "exam_version_changes"
Cohesion: 0.40
Nodes (3): exam_version_changes(), load(), objectives_document()

### Community 175 - "1-1-demo-linux-lab/verify.sh"
Cohesion: 0.40
Nodes (4): I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM, LAB_DISPOSABLE, verify.sh script, STUDY_LAB

### Community 176 - "1-2-demo-kind-lab/background.sh"
Cohesion: 0.40
Nodes (4): I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM, LAB_DISPOSABLE, background.sh script, STUDY_LAB

### Community 177 - "1-2-demo-kind-lab/cleanup.sh"
Cohesion: 0.40
Nodes (4): I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM, LAB_DISPOSABLE, cleanup.sh script, STUDY_LAB

### Community 178 - "1-2-demo-kind-lab/verify.sh"
Cohesion: 0.40
Nodes (4): I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM, LAB_DISPOSABLE, verify.sh script, STUDY_LAB

### Community 181 - "bootstrap-kubeadm.sh"
Cohesion: 0.50
Nodes (3): DEBIAN_FRONTEND, KUBECONFIG, bootstrap-kubeadm.sh script

### Community 188 - "check_provenance.py"
Cohesion: 0.60
Nodes (3): check_cert(), main(), _topics()

### Community 207 - "corpus.py"
Cohesion: 0.32
Nodes (3): _fold(), _informative(), _terms()

### Community 208 - "Check before you push"
Cohesion: 0.50
Nodes (4): Check before you push, How a lab gets proven before it is published, Optional: run it automatically before every `git push`, Run a lab anywhere, and get yours published

### Community 210 - "mcp_server.py"
Cohesion: 0.20
Nodes (6): _readable(), wrapped(), serve(), get_syllabus(), list_certs(), search_topics()

### Community 212 - "[0.3.0](https://github.com/villadalmine/study-cybercirujas/compare/v0.2.0...v0.3.0) (2026-10-16)"
Cohesion: 0.40
Nodes (5): [0.3.0](https://github.com/villadalmine/study-cybercirujas/compare/v0.2.0...v0.3.0) (2026-10-16), Changelog, Changelog, Features, Internals

## Knowledge Gaps
- **24 isolated node(s):** `KUBECONFIG`, `DEBIAN_FRONTEND`, `teach-plat`, `TEACH_AGENT`, `TEACH_OFFLINE` (+19 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1216 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **90 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `kubectl()` connect `clean_registry.py` to `Backlog`, `video.py`, `make`, `topic_content`, `study.cybercirujas — free, open study material for IT certifications`, `_verify_translation`, `Roadmap — where this is and where it goes`, `up`, `Developers — use the API, run your own copy, build on it`, `subprocess`, `study-lab — break/fix labs in a throwaway container`?**
  _High betweenness centrality (0.046) - this node is a cross-community bridge._
- **What connects `KUBECONFIG`, `DEBIAN_FRONTEND`, `teach-plat` to the rest of the system?**
  _24 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `teach/cli.py` be split into smaller, more focused modules?**
  _Cohesion score 0.09446693657219973 - nodes in this community are weakly interconnected._
- **Why does `History` connect `History` to `video.py`, `topic_content`, `steer.py`, `snapshot_topics`, `quota.py`, `_verify_translation`, `README.md`?**
  _High betweenness centrality (0.025) - this node is a cross-community bridge._
- **Should `lab/cli.py` be split into smaller, more focused modules?**
  _Cohesion score 0.10668563300142248 - nodes in this community are weakly interconnected._
- **Why does `Operating the pipeline — for maintainers` connect `Operating the pipeline — for maintainers` to `translation_study.py`, `check_config.py`, `make`, `README.md`?**
  _High betweenness centrality (0.025) - this node is a cross-community bridge._
- **Should `video.py` be split into smaller, more focused modules?**
  _Cohesion score 0.10730804810360776 - nodes in this community are weakly interconnected._