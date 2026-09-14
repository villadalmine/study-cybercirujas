# Graph Report - teach-plat  (2026-09-14)

## Corpus Check
- 94 files · ~146,629 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1211 nodes · 1978 edges · 88 communities (75 shown, 13 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 9 edges (avg confidence: 0.63)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `8cb0d1ac`
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
- Lab Lifecycle Management
- StaleCycleTest
- Architecture Context Doc
- QualityFloorTest
- Content Workflow Guide
- Changelog
- Platform Architecture Plan
- Removed K8s API Checks
- EnvScopeTests
- RejectsDamagedTranslations
- Syllabus Coverage Tests
- certs.py
- classify
- Verifying the material is true — design notes
- Can a cheap model do the translation step?
- Helm Chart Docs
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- check_sources.py
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
- StoredShapeTests
- pipeline.py
- Content Status
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- 1. The code graph (Graphify)
- fix_corrupted_content.py
- load
- fetch_text
- publish_if_complete.py
- _agent_completer
- Development Guidelines for teach-plat
- AI certification roadmap
- milestone_targets
- Within one certification (the only fair comparisons; authoring language `en` only)
- MCP Graph Config
- response
- Post-commit Hook
- datetime
- Check curriculum updates
- _verify_translation
- check_versions.py
- OpenWiki scope for teach-plat
- video_languages
- The phases
- probe_models.py
- tracker.py
- bot_stats.py
- translation_study.py
- api.py
- models_live.py
- catalog.py
- test_model_probe.py
- ocr_pdf.py
- teach-plat
- CatalogueStateTests
- quality.py
- FixtureTests
- LanguageTests
- VerdictTests
- QualityThresholdsTest
- core/__init__.py
- OffSwitchTests
- _dominant_model

## God Nodes (most connected - your core abstractions)
1. `Changelog` - 23 edges
2. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 19 edges
3. `generate_topic()` - 18 edges
4. `_get()` - 18 edges
5. `main()` - 16 edges
6. `load()` - 15 edges
7. `make_completer()` - 15 edges
8. `load()` - 15 edges
9. `teach-plat` - 15 edges
10. `response()` - 14 edges

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

## Communities (88 total, 13 thin omitted)

### Community 0 - "Backlog"
Cohesion: 0.17
Nodes (12): Backlog, Content, Deploy — Technical Debt, In Progress / Next (Ordering), Labs — Execution Modes (see PLAN.md, SDD section), Labs — what an audit found, 2026-08-08 (design parked, not started), Pipeline Automation, Platform (Long-Term Roadmap, see PLAN.md) (+4 more)

### Community 1 - "The routine, start to finish"
Cohesion: 0.12
Nodes (17): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+9 more)

### Community 2 - "_get"
Cohesion: 0.14
Nodes (17): FileResponse, Response, get_catalog(), get_cert(), get_langs(), get_status(), healthz(), index() (+9 more)

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
Cohesion: 0.06
Nodes (31): check_cert(), main(), _topics(), main(), _md_table(), observations(), Path, The same numbers main() prints, as a dict — shared by the MODELS.md renderer. (+23 more)

### Community 7 - "generator.py"
Cohesion: 0.14
Nodes (26): Completer, cert_generate(), Generate content with AI for pending/stale topics. This AUTHORS from the…, _antigravity_completer(), generate_cert(), generate_topic(), GeneratorConfigError, _litellm_completer() (+18 more)

### Community 8 - "cli.py"
Cohesion: 0.08
Nodes (34): command, cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+26 more)

### Community 9 - "Which backend authors better material?"
Cohesion: 0.22
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 10 - "Lab Lifecycle Management"
Cohesion: 0.23
Nodes (23): CompletedProcess, down(), _down_cluster(), _down_container(), lab_dir(), _lab_name(), LabError, _load_spec() (+15 more)

### Community 11 - "StaleCycleTest"
Cohesion: 0.13
Nodes (9): Invalidation cycle triggered by a syllabus change. Tested because the delicate…, A topic that never changed reports no outdated languages, however old its…, When in doubt, regenerate: if freshness cannot be proven, it is not assumed., Change detection in the snapshot, touching no disk and spending no budget., Weight sets the depth requested from the model, so changing it changes the…, Hand-enriched content is preserved and reported separately so a person decides,…, The case that drove the design: rebuilding Spanish cannot mark the topic…, SnapshotStatusTest (+1 more)

### Community 12 - "Architecture Context Doc"
Cohesion: 0.11
Nodes (18): CONTENT GENERATION PIPELINE, Date: 2026-07-27, DIFFERENTIATION vs EXISTING PLATFORMS, Generated from conversation with Kimi AI, HARDWARE INFRASTRUCTURE, HELM CHART, KEY DESIGN DECISIONS, Lab Lifecycle (+10 more)

### Community 13 - "QualityFloorTest"
Cohesion: 0.18
Nodes (4): QualityFloorTest, The references section is explicitly requested by the prompt, and it is what…, The real case: CNPE produced 18 of 18 exercises with no collapsible answers…, Material is generated in seven languages; the heading changes and the floor…

### Community 14 - "Content Workflow Guide"
Cohesion: 0.11
Nodes (19): 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 3. Audit — never skip this, 4. Status, 5. Commit, 6. Publish — only for a complete certification (+11 more)

### Community 15 - "Changelog"
Cohesion: 0.09
Nodes (23): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-16, 2026-07-17, 2026-07-19, 2026-07-27, 2026-07-28 (+15 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.11
Nodes (18): 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, Catalog by Categories, CLI, Code Architecture, Data Model (+10 more)

### Community 17 - "Removed K8s API Checks"
Cohesion: 0.18
Nodes (9): _deliberate(), findings(), main(), Path, Path, Detection of removed Kubernetes APIs. What is tested is the judgement, not the…, Mentioning 'removed' in another paragraph cannot give a free pass to a stale…, Istio and Tekton version independently: their v1beta1 may be current. (+1 more)

### Community 18 - "EnvScopeTests"
Cohesion: 0.21
Nodes (6): load_env(), Path, Read KEY=VALUE lines into the environment. Returns how many were set.…, EnvScopeTests, Path, `.env` may configure translation and nothing else. It exists for one purpose —…

### Community 19 - "RejectsDamagedTranslations"
Cohesion: 0.21
Nodes (6): Blanking comment text must not let a model drop the line entirely: the '#'…, Re-padding is the model's job: a diagram whose borders no longer line up is…, |' and '-' are excluded from the box character set on purpose, so an ordinary…, The cheap-model failure the length band exists for., The failure that silently breaks every example: the model translates the…, RejectsDamagedTranslations

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.14
Nodes (3): A snapshot must be refused when the source document does not support it. Seven…, A snapshot must be refused when the document does not support it. Seven…, SyllabusCoverageTests

### Community 21 - "certs.py"
Cohesion: 0.17
Nodes (21): clear_topic_stale(), content_dir(), get_topic(), load(), md_path(), Path, Post, Read/write the per-certification MD (syllabus snapshot + status). The MD with… (+13 more)

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

### Community 29 - "check_sources.py"
Cohesion: 0.36
Nodes (8): catalogue(), cited_domains(), duplicate_keys(), main(), Path, (domain -> project, neutral domains, raw config)., Hosts cited in the references section only. URLs in the body are examples and…, Project keys that appear twice — YAML keeps the last and drops the first.…

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
Cohesion: 0.23
Nodes (13): cert_topics(), check(), lab_cell(), lang_cell(), Path, Regenerate STATUS.md from disk. True if it changed. The single implementation…, [] if STATUS.md matches the filesystem; the differing lines otherwise.…, The budget footer: what generation has actually consumed, from records.… (+5 more)

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

### Community 44 - "StoredShapeTests"
Cohesion: 0.07
Nodes (8): AcceptanceTests, EndpointTests, Anonymous by construction: what the counters can and cannot hold. The study bot…, The HTTP surface, including the body it must refuse outright., Every field is a closed set. An unknown value is refused, not cleaned., Counters, never rows — the property the whole design rests on., The file's structure with every count blanked — what must not grow., StoredShapeTests

### Community 45 - "pipeline.py"
Cohesion: 0.15
Nodes (21): generate(), generate_with_retries(), main(), pending(), Topics still missing for this combination, in syllabus order., One topic, start to finish. Returns done | failed | skipped | fatal. The claim…, _sort_key(), main() (+13 more)

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
Cohesion: 0.15
Nodes (20): _cert_topic_ids(), find_bad_combos(), _finish(), main(), _publish_if_complete(), A veces el backend envuelve la respuesta entera en ```markdown ... ``` (visto…, Produce videos for certifications whose content is finished. The unattended…, Ids de todos los topics del temario (frontmatter del .md), para poder detectar… (+12 more)

### Community 50 - "load"
Cohesion: 0.12
Nodes (22): RuntimeError, main(), _cert_block(), create_block(), main(), (start, end) line indices of a certification's block, so edits are surgical.…, Add a certification to pipeline.yaml that is not there yet. `activate` used to…, Set one key inside one certification. True if the file changed. (+14 more)

### Community 51 - "fetch_text"
Cohesion: 0.20
Nodes (13): load_syllabus(), main(), Path, How many objectives the official page publishes. Network, no model., Structural signs the topic list was computed rather than read. Offline.…, smells(), upstream_objectives(), fetch_text() (+5 more)

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

### Community 56 - "milestone_targets"
Cohesion: 0.33
Nodes (6): in_milestone(), milestone(), milestone_targets(), Is this cert/language part of the declared goal?, The bounded goal the unattended timer is working toward, or {}. The timer used…, [(cert, [langs])] for the milestone, or None when none is declared. None and []…

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.20
Nodes (10): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, Model Comparison, What a quota window buys (761,850 output tokens/window, measured on this machine) (+2 more)

### Community 59 - "response"
Cohesion: 0.31
Nodes (3): A successful completion, overridden field by field., response(), ThinkingTests

### Community 62 - "datetime"
Cohesion: 0.09
Nodes (34): datetime, backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main() (+26 more)

### Community 63 - "Check curriculum updates"
Cohesion: 0.50
Nodes (3): Check curriculum updates, Notes, Steps

### Community 64 - "_verify_translation"
Cohesion: 0.21
Nodes (10): _comparable_code(), A code block reduced to the parts a translation must not touch. Code blocks are…, Structural checks a translation must satisfy but authoring cannot. This is what…, _verify_translation(), AcceptsCorrectTranslations, _english(), The structural gate that decides whether a translation is usable. Its own…, The source with its prose in English, code block untouched. (+2 more)

### Community 65 - "check_versions.py"
Cohesion: 0.25
Nodes (10): frozen(), main(), (version, snapshot_date) as the syllabus records them — what we built on., True/False if both versions are known and comparable, else None. "3.0" and…, current | outdated | unknown. `unknown` is a real answer and is reported as…, _same_version(), state(), survey() (+2 more)

### Community 66 - "OpenWiki scope for teach-plat"
Cohesion: 0.40
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 67 - "video_languages"
Cohesion: 0.21
Nodes (11): find_missing_videos(), [(cert, lang), ...] declared in pipeline.yaml but not rendered. Kept OUT of…, main(), Every active certification with what it still needs, most urgent first., survey(), _topic_count(), main(), pending_topics() (+3 more)

### Community 68 - "The phases"
Cohesion: 0.09
Nodes (22): Alternatives considered, Can it read what we send it? (2026-09-11, second pass), Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Phase 1.5 — BUILT 2026-09-14 (option A) (+14 more)

### Community 69 - "probe_models.py"
Cohesion: 0.08
Nodes (43): Client, ask(), ask_retrying(), catalogue_state(), detect_language(), graded(), main(), material() (+35 more)

### Community 70 - "tracker.py"
Cohesion: 0.13
Nodes (29): Scrape the official sources and update the catalog., tracker_sync(), add_cert(), load(), save(), _ai_yaml(), _apply_snapshot_status(), generate_paths() (+21 more)

### Community 71 - "bot_stats.py"
Cohesion: 0.16
Nodes (16): main(), table(), get_bot_stats(), The counters, as they are. Public, because the page that shows them is. Soft…, accepted(), _blank(), _known_models(), load() (+8 more)

### Community 72 - "translation_study.py"
Cohesion: 0.36
Nodes (7): evaluate(), main(), master_key(), Run the pipeline's own two gates. Verdict plus the reasons it failed., Read the proxy key from the cluster rather than from a file on disk. It is only…, One completion through the proxy. Returns text plus what it cost., translate()

### Community 73 - "api.py"
Cohesion: 0.09
Nodes (32): BaseModel, Request, BotUsage, get_cert_video(), get_path_video(), get_paths(), get_topic(), get_topic_preview() (+24 more)

### Community 74 - "models_live.py"
Cohesion: 0.16
Nodes (15): BackgroundTasks, main(), get_models(), Compare the catalogue against OpenRouter, at most every few hours. Never raises…, The study bot's model catalogue, from `models.yaml`, plus what is live. Served…, _refresh_live(), annotate(), compare() (+7 more)

### Community 75 - "catalog.py"
Cohesion: 0.23
Nodes (12): _BlockDumper, catalog_path(), load_models(), models_path(), Path, Global certification catalog (catalog.yaml). Written by the tracker (and `cert…, Root of the data repo. Override with TEACH_ROOT., PyYAML, but sequences stay indented under their key. The default dedents every… (+4 more)

### Community 76 - "test_model_probe.py"
Cohesion: 0.20
Nodes (5): CatalogueWriterTests, ComprehensionTests, Grading the study bot's models: the judgement, offline.…, The probe that sends real material and grades one fact from it., models.yaml is rewritten by two scripts; both must leave it readable.

### Community 77 - "ocr_pdf.py"
Cohesion: 0.46
Nodes (7): embedded_text(), fetch(), main(), ocr(), Path, What the PDF's own text layer yields. Empty-ish means OCR is needed., (text, engine). Renders each page, then reads the pixels.

### Community 78 - "teach-plat"
Cohesion: 0.13
Nodes (15): AI-generated content — disclosure, Content process, Deploying to Kubernetes, Environment variables, Generation backends, Keeping it honest over time, Languages, Licence (+7 more)

### Community 80 - "quality.py"
Cohesion: 0.29
Nodes (6): check(), Quality floor for generated material, identical for every backend. A different…, Rules for 'content' or 'exercises'. With no `quality` block in the YAML there…, Return the problems found. An empty list means the floor is met. `kind` is…, rules(), Quality floor: the same standard for every backend. Tested because a floor is…

### Community 84 - "QualityThresholdsTest"
Cohesion: 0.33
Nodes (3): QualityThresholdsTest, The thresholds live in pipeline.yaml and are calibrated against material…, The floor is optional: a repo with no `quality` in the YAML must not break.…

## Knowledge Gaps
- **265 isolated node(s):** `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script`, `run_milestone.sh script`, `TEACH_AGENT` (+260 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **13 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `RejectsDamagedTranslations` connect `RejectsDamagedTranslations` to `_verify_translation`, `generator.py`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **Why does `_verify_translation()` connect `_verify_translation` to `translation_study.py`, `RejectsDamagedTranslations`, `generator.py`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **Why does `load_env()` connect `EnvScopeTests` to `core/__init__.py`?**
  _High betweenness centrality (0.016) - this node is a cross-community bridge._
- **What connects `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script` to the rest of the system?**
  _265 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `The routine, start to finish` be split into smaller, more focused modules?**
  _Cohesion score 0.11764705882352941 - nodes in this community are weakly interconnected._
- **Should `_get` be split into smaller, more focused modules?**
  _Cohesion score 0.13970588235294118 - nodes in this community are weakly interconnected._
- **Should `catalogue` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._