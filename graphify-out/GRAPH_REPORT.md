# Graph Report - teach-plat  (2026-09-10)

## Corpus Check
- 87 files · ~126,161 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1018 nodes · 1675 edges · 71 communities (63 shown, 8 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 6 edges (avg confidence: 0.6)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `9a08abc4`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- status_matrix.py
- The routine, start to finish
- api.py
- tracker.py
- video.py
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- claims.py
- generator.py
- cli.py
- ocr_pdf.py
- Lab Lifecycle Management
- StaleCycleTest
- Architecture Context Doc
- QualityFloorTest
- Content Workflow Guide
- Changelog
- Platform Architecture Plan
- Removed K8s API Checks
- core/__init__.py
- RejectsDamagedTranslations
- Syllabus Coverage Tests
- certs.py
- classify
- README.md
- Verifying the material is true — design notes
- fetch_text
- Helm Chart Docs
- Developers — use the API, run your own copy, build on it
- clean_registry.py
- check_sources.py
- ClaimTest
- API Facts Verification
- Citation Claim Checking
- quality.py
- Citation URL Checks
- problems
- Usage Reporting
- Model Backfill Script
- Milestone Run Script
- Pre-commit Hook
- Resume Generation Script
- Project Root
- generate_topic
- main
- check_models.py
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- 1. The code graph (Graphify)
- fix_corrupted_content.py
- languages_for
- gen_api_docs.py
- publish_if_complete.py
- generation
- catalog.py
- AI certification roadmap
- pipeline.py
- Within one certification (the only fair comparisons; authoring language `en` only)
- MCP Graph Config
- translation_study.py
- Post-commit Hook
- datetime
- Check curriculum updates
- _english
- QualityThresholdsTest
- _get
- run_cert.py
- Study bot — design
- root
- teach-plat

## God Nodes (most connected - your core abstractions)
1. `Changelog` - 21 edges
2. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 19 edges
3. `generate_topic()` - 18 edges
4. `_get()` - 17 edges
5. `main()` - 16 edges
6. `load()` - 15 edges
7. `make_completer()` - 15 edges
8. `load()` - 15 edges
9. `teach-plat` - 15 edges
10. `_render()` - 13 edges

## Surprising Connections (you probably didn't know these)
- `status()` --calls--> `refresh()`  [INFERRED]
  teach/cli.py → scripts/status_matrix.py
- `RejectsDamagedTranslations` --uses--> `GeneratorConfigError`  [INFERRED]
  tests/test_translation_verify.py → teach/core/generator.py
- `effective()` --calls--> `_agent_completer()`  [EXTRACTED]
  scripts/check_config.py → teach/core/generator.py
- `check_cert()` --calls--> `video_languages()`  [EXTRACTED]
  scripts/check_provenance.py → teach/core/pipeline.py
- `main()` --calls--> `targets()`  [EXTRACTED]
  scripts/check_provenance.py → teach/core/pipeline.py

## Import Cycles
- None detected.

## Communities (71 total, 8 thin omitted)

### Community 0 - "status_matrix.py"
Cohesion: 0.14
Nodes (20): frozen(), (version, snapshot_date) as the syllabus records them — what we built on., True/False if both versions are known and comparable, else None. "3.0" and…, current | outdated | unknown. `unknown` is a real answer and is reported as…, _same_version(), state(), survey(), cert_topics() (+12 more)

### Community 1 - "The routine, start to finish"
Cohesion: 0.12
Nodes (17): 1. The container registry (the one that actually fills), 2. Rejected generation output (`.rejected/`), 3. Orphaned topic directories, 4. Local state (`~/.local/state/teach-plat/`), 5. Scratch files in the repository root, Check first, Cleanup — what fills up, and how to reclaim it, Delete (+9 more)

### Community 2 - "api.py"
Cohesion: 0.13
Nodes (21): BaseModel, Request, get_cert_video(), get_path_video(), login(), LoginBody, logout(), me() (+13 more)

### Community 3 - "tracker.py"
Cohesion: 0.15
Nodes (20): _ai_yaml(), _apply_snapshot_status(), generate_paths(), _get_bytes(), normalise_weights(), published_version(), Exception, Tracker/scraper: nothing is static — the whole catalog derives from sources. -… (+12 more)

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
Cohesion: 0.13
Nodes (26): Completer, _agent_completer(), _antigravity_completer(), _comparable_code(), _dominant_model(), GeneratorConfigError, _litellm_completer(), make_completer() (+18 more)

### Community 8 - "cli.py"
Cohesion: 0.08
Nodes (34): command, cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+26 more)

### Community 9 - "ocr_pdf.py"
Cohesion: 0.46
Nodes (7): embedded_text(), fetch(), main(), ocr(), Path, What the PDF's own text layer yields. Empty-ish means OCR is needed., (text, engine). Renders each page, then reads the pixels.

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
Cohesion: 0.10
Nodes (21): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-16, 2026-07-17, 2026-07-19, 2026-07-27, 2026-07-28 (+13 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.11
Nodes (18): 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, Catalog by Categories, CLI, Code Architecture, Data Model (+10 more)

### Community 17 - "Removed K8s API Checks"
Cohesion: 0.18
Nodes (9): _deliberate(), findings(), main(), Path, Path, Detection of removed Kubernetes APIs. What is tested is the judgement, not the…, Mentioning 'removed' in another paragraph cannot give a free pass to a stale…, Istio and Tekton version independently: their v1beta1 may be current. (+1 more)

### Community 18 - "core/__init__.py"
Cohesion: 0.19
Nodes (7): load_env(), Path, Loads `.env` from the repository root, once, before anything reads a variable.…, Read KEY=VALUE lines into the environment. Returns how many were set.…, EnvScopeTests, Path, `.env` may configure translation and nothing else. It exists for one purpose —…

### Community 19 - "RejectsDamagedTranslations"
Cohesion: 0.21
Nodes (6): Blanking comment text must not let a model drop the line entirely: the '#'…, Re-padding is the model's job: a diagram whose borders no longer line up is…, |' and '-' are excluded from the box character set on purpose, so an ordinary…, The cheap-model failure the length band exists for., The failure that silently breaks every example: the model translates the…, RejectsDamagedTranslations

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.14
Nodes (3): A snapshot must be refused when the source document does not support it. Seven…, A snapshot must be refused when the document does not support it. Seven…, SyllabusCoverageTests

### Community 21 - "certs.py"
Cohesion: 0.14
Nodes (26): get_topic(), get_topic_preview(), Public teaser: first lines of the material + what the topic includes., A topic's material: content, exercises, lab, and the provenance of what is…, _valid_lang(), clear_topic_stale(), content_dir(), get_topic() (+18 more)

### Community 22 - "classify"
Cohesion: 0.67
Nodes (3): classify(), main(), console' | 'jsonl' | None — None means leave it alone.

### Community 23 - "README.md"
Cohesion: 0.05
Nodes (41): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Rules, Verification: what is proven, and what is only assumed, Caveats, fable-5 vs opus-5, within cgoa (2026-08-19) (+33 more)

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 25 - "fetch_text"
Cohesion: 0.24
Nodes (11): load_syllabus(), main(), Path, How many objectives the official page publishes. Network, no model., Structural signs the topic list was computed rather than read. Offline.…, smells(), upstream_objectives(), fetch_text() (+3 more)

### Community 26 - "Helm Chart Docs"
Cohesion: 0.25
Nodes (7): Configuration, Install, License, Local Development, Philosophy, Prerequisites, Study CyberCirujas Helm Chart

### Community 27 - "Developers — use the API, run your own copy, build on it"
Cohesion: 0.18
Nodes (11): Building features on it, Developers — use the API, run your own copy, build on it, DORA, concretely, Keeping this page true, Licence, Running your own copy, Staying in sync with upstream, ⚠️ The API is beta, and hosted on a home cluster (+3 more)

### Community 28 - "clean_registry.py"
Cohesion: 0.42
Nodes (8): RuntimeError, deployed_tags(), in_registry(), kubectl(), main(), Every image referenced by a deployment, as `repo:tag`., Disk usage of the registry volume, read by column name rather than index. `df…, usage()

### Community 29 - "check_sources.py"
Cohesion: 0.36
Nodes (8): catalogue(), cited_domains(), duplicate_keys(), main(), Path, (domain -> project, neutral domains, raw config)., Hosts cited in the references section only. URLs in the body are examples and…, Project keys that appear twice — YAML keeps the last and drops the first.…

### Community 30 - "ClaimTest"
Cohesion: 0.14
Nodes (6): ClaimTest, Per-topic claims: several agents at once, never the same topic twice. The…, Claim from a separate PROCESS: flock is per open file description, so a second…, The whole reason this is per topic and not global., A lock file checked with exists() would strand a topic forever after a crash.…, _try_claim()

### Community 31 - "API Facts Verification"
Cohesion: 0.53
Nodes (5): check(), main(), {(apiVersion, kind)} served by that release, from the published spec., spec_kinds(), tracked_versions()

### Community 32 - "Citation Claim Checking"
Cohesion: 0.47
Nodes (5): ask(), main(), (label, url) from the references section only. URLs in the body are examples…, Fetch and judge. Deliberately a separate process per claim: one failure should…, references()

### Community 33 - "quality.py"
Cohesion: 0.29
Nodes (6): check(), Quality floor for generated material, identical for every backend. A different…, Rules for 'content' or 'exercises'. With no `quality` block in the YAML there…, Return the problems found. An empty list means the floor is met. `kind` is…, rules(), Quality floor: the same standard for every backend. Tested because a floor is…

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

### Community 44 - "generate_topic"
Cohesion: 0.22
Nodes (10): cert_generate(), Generate content with AI for pending/stale topics. This AUTHORS from the…, generate_cert(), generate_topic(), Path, Provenance for one language directory: who made it, with what, when. Written…, Generate one topic's content in one language. The lab is shared., _system() (+2 more)

### Community 45 - "main"
Cohesion: 0.23
Nodes (12): generate(), generate_with_retries(), main(), pending(), Topics still missing for this combination, in syllabus order., One topic, start to finish. Returns done | failed | skipped | fatal. The claim…, _sort_key(), me() (+4 more)

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

### Community 52 - "publish_if_complete.py"
Cohesion: 0.33
Nodes (9): complete_certs(), is_complete(), main(), publish(), Build in-cluster, then deploy — with the SAME tag passed to both. `TAG`…, (complete, why not). Everything the certification declares must be there.…, _record(), _save() (+1 more)

### Community 53 - "generation"
Cohesion: 0.29
Nodes (9): dominant(), effective(), main(), (model, effort, notes) as the generator would resolve them right now. Resolved…, recent(), Append one line per completion: what it was for, and what it cost. Never…, _record_usage(), generation() (+1 more)

### Community 54 - "catalog.py"
Cohesion: 0.19
Nodes (17): main(), Scrape the official sources and update the catalog., tracker_sync(), add_cert(), get_cert(), list_certs(), load(), Global certification catalog (catalog.yaml). Written by the tracker (and `cert… (+9 more)

### Community 55 - "AI certification roadmap"
Cohesion: 0.22
Nodes (9): AI certification roadmap, How each course cites its own syllabus, Model-provider certifications — researched in depth 2026-09-09, NVIDIA career track (researched 2026-09-09, owner's request), Phase 1 — AI fundamentals (extends the three cloud careers), Phase 2 — the technical tier, led by market demand, Phase 3 — specialists (need a verification pass before cataloguing), The five filters (+1 more)

### Community 56 - "pipeline.py"
Cohesion: 0.14
Nodes (20): main(), pending(), budget(), in_milestone(), is_fatal(), is_retryable(), load(), milestone() (+12 more)

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.20
Nodes (10): cgoa, cnpa, kca, kcsa, lpic-1, lpic-3-303, Model Comparison, What a quota window buys (761,850 output tokens/window, measured on this machine) (+2 more)

### Community 59 - "translation_study.py"
Cohesion: 0.36
Nodes (7): evaluate(), main(), master_key(), Run the pipeline's own two gates. Verdict plus the reasons it failed., Read the proxy key from the cluster rather than from a file on disk. It is only…, One completion through the proxy. Returns text plus what it cost., translate()

### Community 62 - "datetime"
Cohesion: 0.06
Nodes (47): datetime, backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main() (+39 more)

### Community 63 - "Check curriculum updates"
Cohesion: 0.50
Nodes (3): Check curriculum updates, Notes, Steps

### Community 64 - "_english"
Cohesion: 0.32
Nodes (5): AcceptsCorrectTranslations, _english(), The source with its prose in English, code block untouched., Comments are prose. The authored English material has English comments, so…, ASCII diagrams are prose too, and this one is not a retry away: `cheap`…

### Community 65 - "QualityThresholdsTest"
Cohesion: 0.33
Nodes (3): QualityThresholdsTest, The thresholds live in pipeline.yaml and are calibrated against material…, The floor is optional: a repo with no `quality` in the YAML must not break.…

### Community 66 - "_get"
Cohesion: 0.14
Nodes (14): FileResponse, Response, get_catalog(), get_cert(), get_langs(), get_paths(), healthz(), index() (+6 more)

### Community 67 - "run_cert.py"
Cohesion: 0.60
Nodes (4): main(), pending_topics(), # NOTE: --to, not --lang. `--lang` re-authors from the syllabus and, run()

### Community 68 - "Study bot — design"
Cohesion: 0.12
Nodes (17): Alternatives considered, Effort, How a student uses it, How it is maintained, Is it all API?, Operating it, Phase 1.5 — closing the loop: checks that improve the page, Phase 1 — SHIPPED 2026-09-09 (+9 more)

### Community 69 - "root"
Cohesion: 0.25
Nodes (9): get_models(), get_status(), The study bot's model catalogue, from `models.yaml`. Served rather than…, Per-certification overview: exam versions, coverage, videos, freshness. The…, _status_snapshot(), catalog_path(), Path, Root of the data repo. Override with TEACH_ROOT. (+1 more)

### Community 71 - "teach-plat"
Cohesion: 0.07
Nodes (27): Backlog, Content, Deploy — Technical Debt, In Progress / Next (Ordering), Labs — Execution Modes (see PLAN.md, SDD section), Labs — what an audit found, 2026-08-08 (design parked, not started), Pipeline Automation, Platform (Long-Term Roadmap, see PLAN.md) (+19 more)

## Knowledge Gaps
- **258 isolated node(s):** `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script`, `run_milestone.sh script`, `TEACH_AGENT` (+253 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **8 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` to `README.md`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Why does `QualityFloorTest` connect `QualityFloorTest` to `quality.py`?**
  _High betweenness centrality (0.018) - this node is a cross-community bridge._
- **What connects `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script` to the rest of the system?**
  _258 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `status_matrix.py` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._
- **Should `The routine, start to finish` be split into smaller, more focused modules?**
  _Cohesion score 0.11764705882352941 - nodes in this community are weakly interconnected._
- **Should `api.py` be split into smaller, more focused modules?**
  _Cohesion score 0.13438735177865613 - nodes in this community are weakly interconnected._
- **Should `tracker.py` be split into smaller, more focused modules?**
  _Cohesion score 0.14761904761904762 - nodes in this community are weakly interconnected._