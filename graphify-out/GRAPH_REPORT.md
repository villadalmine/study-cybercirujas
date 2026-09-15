# Graph Report - teach-plat  (2026-09-15)

## Corpus Check
- 100 files · ~157,823 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1316 nodes · 2116 edges · 94 communities (81 shown, 13 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 9 edges (avg confidence: 0.63)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `eb85382f`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Backlog
- The routine, start to finish
- _get
- catalogue
- video.py
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- claims.py
- generator.py
- cli.py
- Which backend authors better material?
- labs.py
- StaleCycleTest
- Architecture Context Doc
- QualityFloorTest
- Content Workflow Guide
- Changelog
- Platform Architecture Plan
- Removed K8s API Checks
- check_versions.py
- RejectsDamagedTranslations
- Syllabus Coverage Tests
- certs.py
- classify
- Verifying the material is true — design notes
- Can a cheap model do the translation step?
- Helm Chart Docs
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- catalog.py
- Roadmap — where this is and where it goes
- API Facts Verification
- Citation Claim Checking
- status_matrix.py
- Citation URL Checks
- problems
- Usage Reporting
- Model Backfill Script
- Milestone Run Script
- Pre-commit Hook
- Resume Generation Script
- Project Root
- bot_stats.py
- EnvScopeTests
- Content Status
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- 1. The code graph (Graphify)
- fix_corrupted_content.py
- languages_for
- corpus.py
- publish_if_complete.py
- _agent_completer
- Development Guidelines for teach-plat
- AI certification roadmap
- pipeline.py
- Within one certification (the only fair comparisons; authoring language `en` only)
- ProtocolTests
- response
- Post-commit Hook
- datetime
- Check curriculum updates
- _verify_translation
- ClaimTest
- OpenWiki scope for teach-plat
- run_cert.py
- The phases
- probe_models.py
- tracker.py
- bot_loop_check.js
- translation_study.py
- api.py
- models_live.py
- test_mcp_server.py
- test_model_probe.py
- fetch_text
- teach-plat
- CatalogueStateTests
- ocr_pdf.py
- FixtureTests
- LanguageTests
- VerdictTests
- Client
- ask_retrying
- OffSwitchTests
- off_switch
- PathLanguageTests
- probe_languages
- verdict
- quota.py
- quality.py
- _dominant_model

## God Nodes (most connected - your core abstractions)
1. `Changelog` - 24 edges
2. `_get()` - 19 edges
3. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 19 edges
4. `generate_topic()` - 18 edges
5. `main()` - 16 edges
6. `The phases` - 16 edges
7. `load()` - 15 edges
8. `make_completer()` - 15 edges
9. `load()` - 15 edges
10. `Client` - 15 edges

## Surprising Connections (you probably didn't know these)
- `status()` --calls--> `refresh()`  [INFERRED]
  teach/cli.py → scripts/status_matrix.py
- `translate()` --indirect_call--> `response()`  [INFERRED]
  scripts/translation_study.py → tests/test_model_probe.py
- `RejectsDamagedTranslations` --uses--> `GeneratorConfigError`  [INFERRED]
  tests/test_translation_verify.py → teach/core/generator.py
- `main()` --calls--> `load_models()`  [EXTRACTED]
  scripts/check_models.py → teach/core/catalog.py
- `main()` --calls--> `save_models()`  [EXTRACTED]
  scripts/check_models.py → teach/core/catalog.py

## Import Cycles
- None detected.

## Communities (94 total, 13 thin omitted)

### Community 0 - "Backlog"
Cohesion: 0.17
Nodes (12): Backlog, Content, Deploy — Technical Debt, In Progress / Next (Ordering), Labs — Execution Modes (see PLAN.md, SDD section), Labs — what an audit found, 2026-08-08 (design parked, not started), Pipeline Automation, Platform (Long-Term Roadmap, see PLAN.md) (+4 more)

### Community 1 - "The routine, start to finish"
Cohesion: 0.12
Nodes (17): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+9 more)

### Community 2 - "_get"
Cohesion: 0.09
Nodes (25): FileResponse, Response, get_bot_stats(), get_catalog(), get_cert(), get_langs(), get_paths(), get_search() (+17 more)

### Community 3 - "catalogue"
Cohesion: 0.14
Nodes (8): AnnotateTests, catalogue(), CompareTests, EndpointTests, priced(), The out-of-band guard: what the page is told when the catalogue goes stale.…, One model as OpenRouter publishes it: per-token strings, not per-million., The guard must never be able to break the page it protects.

### Community 4 - "video.py"
Cohesion: 0.12
Nodes (42): FreeTypeFont, Image, ImageDraw, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat() (+34 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.04
Nodes (47): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails (+39 more)

### Community 6 - "claims.py"
Cohesion: 0.15
Nodes (16): check_cert(), main(), _topics(), main(), Every active certification with what it still needs, most urgent first., survey(), _topic_count(), main() (+8 more)

### Community 7 - "generator.py"
Cohesion: 0.14
Nodes (26): Completer, cert_generate(), Generate content with AI for pending/stale topics. This AUTHORS from the…, _antigravity_completer(), generate_cert(), generate_topic(), GeneratorConfigError, _litellm_completer() (+18 more)

### Community 8 - "cli.py"
Cohesion: 0.08
Nodes (34): command, cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+26 more)

### Community 9 - "Which backend authors better material?"
Cohesion: 0.22
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 10 - "labs.py"
Cohesion: 0.15
Nodes (29): CompletedProcess, Loads `.env` from the repository root, once, before anything reads a variable.…, down(), _down_cluster(), _down_container(), lab_dir(), _lab_name(), LabError (+21 more)

### Community 11 - "StaleCycleTest"
Cohesion: 0.13
Nodes (9): Invalidation cycle triggered by a syllabus change. Tested because the delicate…, A topic that never changed reports no outdated languages, however old its…, When in doubt, regenerate: if freshness cannot be proven, it is not assumed., Change detection in the snapshot, touching no disk and spending no budget., Weight sets the depth requested from the model, so changing it changes the…, Hand-enriched content is preserved and reported separately so a person decides,…, The case that drove the design: rebuilding Spanish cannot mark the topic…, SnapshotStatusTest (+1 more)

### Community 12 - "Architecture Context Doc"
Cohesion: 0.11
Nodes (18): CONTENT GENERATION PIPELINE, Date: 2026-07-27, DIFFERENTIATION vs EXISTING PLATFORMS, Generated from conversation with Kimi AI, HARDWARE INFRASTRUCTURE, HELM CHART, KEY DESIGN DECISIONS, Lab Lifecycle (+10 more)

### Community 13 - "QualityFloorTest"
Cohesion: 0.11
Nodes (8): QualityFloorTest, QualityThresholdsTest, Quality floor: the same standard for every backend. Tested because a floor is…, The references section is explicitly requested by the prompt, and it is what…, The real case: CNPE produced 18 of 18 exercises with no collapsible answers…, Material is generated in seven languages; the heading changes and the floor…, The thresholds live in pipeline.yaml and are calibrated against material…, The floor is optional: a repo with no `quality` in the YAML must not break.…

### Community 14 - "Content Workflow Guide"
Cohesion: 0.11
Nodes (19): 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 3. Audit — never skip this, 4. Status, 5. Commit, 6. Publish — only for a complete certification (+11 more)

### Community 15 - "Changelog"
Cohesion: 0.08
Nodes (24): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-16, 2026-07-17, 2026-07-19, 2026-07-27, 2026-07-28 (+16 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.11
Nodes (18): 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, Catalog by Categories, CLI, Code Architecture, Data Model (+10 more)

### Community 17 - "Removed K8s API Checks"
Cohesion: 0.18
Nodes (9): _deliberate(), findings(), main(), Path, Path, Detection of removed Kubernetes APIs. What is tested is the judgement, not the…, Mentioning 'removed' in another paragraph cannot give a free pass to a stale…, Istio and Tekton version independently: their v1beta1 may be current. (+1 more)

### Community 18 - "check_versions.py"
Cohesion: 0.25
Nodes (10): frozen(), main(), (version, snapshot_date) as the syllabus records them — what we built on., True/False if both versions are known and comparable, else None. "3.0" and…, current | outdated | unknown. `unknown` is a real answer and is reported as…, _same_version(), state(), survey() (+2 more)

### Community 19 - "RejectsDamagedTranslations"
Cohesion: 0.13
Nodes (14): catalogue(), cited_domains(), duplicate_keys(), main(), Path, (domain -> project, neutral domains, raw config)., Hosts cited in the references section only. URLs in the body are examples and…, Project keys that appear twice — YAML keeps the last and drops the first.… (+6 more)

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.14
Nodes (3): A snapshot must be refused when the source document does not support it. Seven…, A snapshot must be refused when the document does not support it. Seven…, SyllabusCoverageTests

### Community 21 - "certs.py"
Cohesion: 0.14
Nodes (26): get_topic(), get_topic_preview(), Public teaser: first lines of the material + what the topic includes., A topic's material: content, exercises, lab, and the provenance of what is…, _valid_lang(), clear_topic_stale(), content_dir(), get_topic() (+18 more)

### Community 22 - "classify"
Cohesion: 0.67
Nodes (3): classify(), main(), console' | 'jsonl' | None — None means leave it alone.

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 25 - "Can a cheap model do the translation step?"
Cohesion: 0.22
Nodes (9): Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results, Three bugs this study found in our own checks, Translating is not the same deliverable as authoring, What this actually saves (+1 more)

### Community 26 - "Helm Chart Docs"
Cohesion: 0.25
Nodes (7): Configuration, Install, License, Local Development, Philosophy, Prerequisites, Study CyberCirujas Helm Chart

### Community 27 - "Developers — use the API, run your own copy, build on it"
Cohesion: 0.18
Nodes (11): Building features on it, Developers — use the API, run your own copy, build on it, DORA, concretely, Keeping this page true, Licence, Running your own copy, Staying in sync with upstream, ⚠️ The API is beta, and hosted on a home cluster (+3 more)

### Community 28 - "clean_registry.py"
Cohesion: 0.50
Nodes (7): deployed_tags(), in_registry(), kubectl(), main(), Every image referenced by a deployment, as `repo:tag`., Disk usage of the registry volume, read by column name rather than index. `df…, usage()

### Community 29 - "catalog.py"
Cohesion: 0.19
Nodes (13): _BlockDumper, catalog_path(), load_models(), models_path(), Path, Global certification catalog (catalog.yaml). Written by the tracker (and `cert…, Root of the data repo. Override with TEACH_ROOT., PyYAML, but sequences stay indented under their key. The default dedents every… (+5 more)

### Community 30 - "Roadmap — where this is and where it goes"
Cohesion: 0.29
Nodes (7): Current focus — set 2026-09-11, Roadmap — where this is and where it goes, Smaller things, when there is an appetite, Standing decisions worth not re-litigating, Study bot — the phases after this one, What is next, Where it is

### Community 31 - "API Facts Verification"
Cohesion: 0.53
Nodes (5): check(), main(), {(apiVersion, kind)} served by that release, from the published spec., spec_kinds(), tracked_versions()

### Community 32 - "Citation Claim Checking"
Cohesion: 0.47
Nodes (5): ask(), main(), (label, url) from the references section only. URLs in the body are examples…, Fetch and judge. Deliberately a separate process per claim: one failure should…, references()

### Community 33 - "status_matrix.py"
Cohesion: 0.15
Nodes (19): cert_topics(), check(), lab_cell(), lang_cell(), Path, Regenerate STATUS.md from disk. True if it changed. The single implementation…, [] if STATUS.md matches the filesystem; the differing lines otherwise.…, The budget footer: what generation has actually consumed, from records.… (+11 more)

### Community 34 - "Citation URL Checks"
Cohesion: 0.70
Nodes (4): citations(), main(), Path, status()

### Community 35 - "problems"
Cohesion: 0.29
Nodes (7): main(), problems(), Path, SafeLoader that tolerates vendor YAML tags instead of failing on them.…, _skip(), _VendorTagLoader, main()

### Community 36 - "Usage Reporting"
Cohesion: 0.70
Nodes (4): main(), _money(), rows(), _tokens()

### Community 37 - "Model Backfill Script"
Cohesion: 0.67
Nodes (3): evidence(), main(), (cert, topic, lang) -> model, from the most recent completion for it.

### Community 44 - "bot_stats.py"
Cohesion: 0.05
Nodes (22): main(), table(), accepted(), _blank(), _known_models(), load(), path(), Which models the study bot is used with — counters, never events. The bot runs… (+14 more)

### Community 45 - "EnvScopeTests"
Cohesion: 0.21
Nodes (6): load_env(), Path, Read KEY=VALUE lines into the environment. Returns how many were set.…, EnvScopeTests, Path, `.env` may configure translation and nothing else. It exists for one purpose —…

### Community 46 - "Content Status"
Cohesion: 0.29
Nodes (7): Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos, Spend (measured)

### Community 47 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.17
Nodes (11): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 6. Where the value actually is (owner's question, 2026-08-18), 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith) (+3 more)

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "fix_corrupted_content.py"
Cohesion: 0.13
Nodes (23): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), A veces el backend envuelve la respuesta entera en ```markdown ... ``` (visto…, [(cert, lang), ...] declared in pipeline.yaml but not rendered. Kept OUT of… (+15 more)

### Community 50 - "languages_for"
Cohesion: 0.16
Nodes (16): main(), _cert_block(), create_block(), main(), (start, end) line indices of a certification's block, so edits are surgical.…, Add a certification to pipeline.yaml that is not there yet. `activate` used to…, Set one key inside one certification. True if the file changed., set_key() (+8 more)

### Community 51 - "corpus.py"
Cohesion: 0.06
Nodes (19): _fold(), get_syllabus(), get_topic(), _informative(), list_certs(), The four functions a study agent needs, and the only four it gets. Phase 2 of…, Lowercase, accent-stripped, so `Kubernetes` finds `kubernetes` and…, Drop the terms that match so much of the corpus they cannot rank it. All of… (+11 more)

### Community 52 - "publish_if_complete.py"
Cohesion: 0.33
Nodes (9): complete_certs(), is_complete(), main(), publish(), Build in-cluster, then deploy — with the SAME tag passed to both. `TAG`…, (complete, why not). Everything the certification declares must be there.…, _record(), _save() (+1 more)

### Community 53 - "_agent_completer"
Cohesion: 0.29
Nodes (10): dominant(), effective(), main(), (model, effort, notes) as the generator would resolve them right now. Resolved…, recent(), _agent_completer(), Append one line per completion: what it was for, and what it cost. Never…, _record_usage() (+2 more)

### Community 54 - "Development Guidelines for teach-plat"
Cohesion: 0.33
Nodes (6): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Rules, Verification: what is proven, and what is only assumed

### Community 55 - "AI certification roadmap"
Cohesion: 0.22
Nodes (9): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 1 — AI fundamentals (extends the three cloud careers), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters (+1 more)

### Community 56 - "pipeline.py"
Cohesion: 0.12
Nodes (27): RuntimeError, generate(), generate_with_retries(), main(), pending(), Topics still missing for this combination, in syllabus order., One topic, start to finish. Returns done | failed | skipped | fatal. The claim…, _sort_key() (+19 more)

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.20
Nodes (10): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, Model Comparison, What a quota window buys (761,850 output tokens/window, measured on this machine) (+2 more)

### Community 58 - "ProtocolTests"
Cohesion: 0.17
Nodes (3): skipUnless, ProtocolTests, Started as a subprocess and driven over stdio, like a real client.

### Community 59 - "response"
Cohesion: 0.31
Nodes (3): A successful completion, overridden field by field., response(), ThinkingTests

### Community 62 - "datetime"
Cohesion: 0.07
Nodes (42): datetime, backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main() (+34 more)

### Community 63 - "Check curriculum updates"
Cohesion: 0.50
Nodes (3): Check curriculum updates, Notes, Steps

### Community 64 - "_verify_translation"
Cohesion: 0.21
Nodes (10): _comparable_code(), A code block reduced to the parts a translation must not touch. Code blocks are…, Structural checks a translation must satisfy but authoring cannot. This is what…, _verify_translation(), AcceptsCorrectTranslations, _english(), The structural gate that decides whether a translation is usable. Its own…, The source with its prose in English, code block untouched. (+2 more)

### Community 65 - "ClaimTest"
Cohesion: 0.14
Nodes (6): ClaimTest, Per-topic claims: several agents at once, never the same topic twice. The…, Claim from a separate PROCESS: flock is per open file description, so a second…, The whole reason this is per topic and not global., A lock file checked with exists() would strand a topic forever after a crash.…, _try_claim()

### Community 66 - "OpenWiki scope for teach-plat"
Cohesion: 0.40
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 67 - "run_cert.py"
Cohesion: 0.60
Nodes (4): main(), pending_topics(), # NOTE: --to, not --lang. `--lang` re-authors from the syllabus and, run()

### Community 68 - "The phases"
Cohesion: 0.08
Nodes (26): Alternatives considered, Can it read what we send it? (2026-09-11, second pass), Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Phase 1.5 — BUILT 2026-09-14 (option A) (+18 more)

### Community 69 - "probe_models.py"
Cohesion: 0.19
Nodes (14): catalogue_state(), main(), _price(), probe_one(), Upper bound in USD, assuming every model burns every cap it is offered. Printed…, Did the endpoint say, in so many words, that it will not stop thinking?…, The verdict as models.yaml records it. See the note at the call site. `rate`…, Add one response's real token counts to the row. Exact numbers, from the… (+6 more)

### Community 70 - "tracker.py"
Cohesion: 0.13
Nodes (29): Scrape the official sources and update the catalog., tracker_sync(), add_cert(), load(), save(), _ai_yaml(), _apply_snapshot_status(), generate_paths() (+21 more)

### Community 71 - "bot_loop_check.js"
Cohesion: 0.12
Nodes (15): API, CERT, els, FALLBACK, fs, KEY, LANGUAGE, line (+7 more)

### Community 72 - "translation_study.py"
Cohesion: 0.36
Nodes (7): evaluate(), main(), master_key(), Run the pipeline's own two gates. Verdict plus the reasons it failed., Read the proxy key from the cluster rather than from a file on disk. It is only…, One completion through the proxy. Returns text plus what it cost., translate()

### Community 73 - "api.py"
Cohesion: 0.12
Nodes (25): BaseModel, Request, BotUsage, get_cert_video(), get_path_video(), login(), LoginBody, logout() (+17 more)

### Community 74 - "models_live.py"
Cohesion: 0.16
Nodes (15): BackgroundTasks, main(), get_models(), Compare the catalogue against OpenRouter, at most every few hours. Never raises…, The study bot's model catalogue, from `models.yaml`, plus what is live. Served…, _refresh_live(), annotate(), compare() (+7 more)

### Community 75 - "test_mcp_server.py"
Cohesion: 0.25
Nodes (5): .venv/bin/python3, graphify, teach, ContractTests, The MCP server: one contract, spoken over the real protocol. Phase 3 hands…

### Community 76 - "test_model_probe.py"
Cohesion: 0.20
Nodes (5): CatalogueWriterTests, ComprehensionTests, Grading the study bot's models: the judgement, offline.…, The probe that sends real material and grades one fact from it., models.yaml is rewritten by two scripts; both must leave it readable.

### Community 77 - "fetch_text"
Cohesion: 0.24
Nodes (11): load_syllabus(), main(), Path, How many objectives the official page publishes. Network, no model., Structural signs the topic list was computed rather than read. Offline.…, smells(), upstream_objectives(), fetch_text() (+3 more)

### Community 78 - "teach-plat"
Cohesion: 0.13
Nodes (15): AI-generated content — disclosure, Content process, Deploying to Kubernetes, Environment variables, Generation backends, Keeping it honest over time, Languages, Licence (+7 more)

### Community 80 - "ocr_pdf.py"
Cohesion: 0.46
Nodes (7): embedded_text(), fetch(), main(), ocr(), Path, What the PDF's own text layer yields. Empty-ish means OCR is needed., (text, engine). Renders each page, then reads the pixels.

### Community 85 - "ask_retrying"
Cohesion: 0.25
Nodes (8): ask(), ask_retrying(), material(), probe_tools(), Two turns: does it ask for the tool, and can it use what comes back? The second…, The excerpt sent to the model: real corpus text, cut deterministically. Read…, One completion. Returns a plain dict; never raises for an HTTP error.…, `ask` plus one retry for a transient failure. Returns (response, calls). A…

### Community 87 - "off_switch"
Cohesion: 0.29
Nodes (8): off_switch(), Did the provider refuse BECAUSE of the `reasoning` field? A 400/422 naming the…, Did this response involve thinking, in any of the three shapes?, How the effort selector behaves for this model, from two probes. off = exactly…, Does `reasoning: {enabled: false}` actually stop this model thinking? Asked of…, rejects_reasoning(), thinking_mode(), thought()

### Community 89 - "probe_languages"
Cohesion: 0.33
Nodes (6): detect_language(), graded(), probe_languages(), Best-effort language of a reply: one of MARKERS, 'zh', 'ja', or 'unclear'. Kana…, (did it find the answer in the material, which language it replied in). Both…, Ask the model, in each language, a question answered by real material. Returns…

### Community 90 - "verdict"
Cohesion: 0.33
Nodes (6): The first tool call in a response, normalised, or None., How well this model drove one tool. calls asked for the tool with the right…, Grade one response. Pure function of the dict — see the tests., tool_call_of(), tool_verdict(), verdict()

### Community 91 - "quota.py"
Cohesion: 0.53
Nodes (5): main(), probe(), Returns (exit-style status, detail). Cheap by construction: the prompt asks for…, record(), show_history()

### Community 92 - "quality.py"
Cohesion: 0.40
Nodes (5): check(), Quality floor for generated material, identical for every backend. A different…, Rules for 'content' or 'exercises'. With no `quality` block in the YAML there…, Return the problems found. An empty list means the floor is met. `kind` is…, rules()

## Knowledge Gaps
- **284 isolated node(s):** `teach-plat`, `fs`, `path`, `REPO`, `MODEL` (+279 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **13 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `load_env()` connect `EnvScopeTests` to `labs.py`?**
  _High betweenness centrality (0.015) - this node is a cross-community bridge._
- **What connects `teach-plat`, `fs`, `path` to the rest of the system?**
  _284 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `The routine, start to finish` be split into smaller, more focused modules?**
  _Cohesion score 0.11764705882352941 - nodes in this community are weakly interconnected._
- **Should `_get` be split into smaller, more focused modules?**
  _Cohesion score 0.09 - nodes in this community are weakly interconnected._
- **Should `catalogue` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._
- **Should `video.py` be split into smaller, more focused modules?**
  _Cohesion score 0.12181616832779624 - nodes in this community are weakly interconnected._
- **Should `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` be split into smaller, more focused modules?**
  _Cohesion score 0.0425531914893617 - nodes in this community are weakly interconnected._