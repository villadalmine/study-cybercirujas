# Graph Report - teach-plat  (2026-08-25)

## Corpus Check
- 77 files · ~103,284 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 907 nodes · 1526 edges · 59 communities (52 shown, 7 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 5 edges (avg confidence: 0.56)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `76906872`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- status_matrix.py
- certs.py
- pipeline.py
- tracker.py
- video.py
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- claims.py
- generator.py
- cli.py
- datetime
- Lab Lifecycle Management
- Staleness Detection Tests
- Architecture Context Doc
- QualityFloorTest
- Content Workflow Guide
- Changelog
- Platform Architecture Plan
- Removed K8s API Checks
- load_env
- Translation Damage Tests
- Syllabus Coverage Tests
- Project Backlog
- teach-plat
- Truth Auditor Design
- Translation Cost Study
- Helm Chart Docs
- run_until_complete.py
- Which backend authors better material?
- Citation Source Checks
- Development Guidelines
- API Facts Verification
- Citation Claim Checking
- Content Status
- Citation URL Checks
- Manifest Validation
- Usage Reporting
- Model Backfill Script
- Milestone Run Script
- Pre-commit Hook
- Resume Generation Script
- Project Root
- main
- quality.py
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- 1. The code graph (Graphify)
- fix_corrupted_content.py
- steer.py
- publish_if_complete.py
- DEVTOOLS.md
- run_cert.py
- Within one certification (the only fair comparisons; authoring language `en` only)
- MCP Graph Config
- Post-commit Hook
- quota.py

## God Nodes (most connected - your core abstractions)
1. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 19 edges
2. `Changelog` - 19 edges
3. `generate_topic()` - 18 edges
4. `main()` - 16 edges
5. `make_completer()` - 15 edges
6. `load()` - 15 edges
7. `_get()` - 15 edges
8. `load()` - 14 edges
9. `_render()` - 13 edges
10. `snapshot_topics()` - 13 edges

## Surprising Connections (you probably didn't know these)
- `status()` --calls--> `refresh()`  [INFERRED]
  teach/cli.py → scripts/status_matrix.py
- `RejectsDamagedTranslations` --uses--> `GeneratorConfigError`  [INFERRED]
  tests/test_translation_verify.py → teach/core/generator.py
- `check_cert()` --calls--> `video_languages()`  [EXTRACTED]
  scripts/check_provenance.py → teach/core/pipeline.py
- `main()` --calls--> `targets()`  [EXTRACTED]
  scripts/check_provenance.py → teach/core/pipeline.py
- `_usable_translate_backend()` --calls--> `make_completer()`  [EXTRACTED]
  scripts/fix_corrupted_content.py → teach/core/generator.py

## Import Cycles
- None detected.

## Communities (59 total, 7 thin omitted)

### Community 0 - "status_matrix.py"
Cohesion: 0.27
Nodes (11): cert_topics(), check(), lab_cell(), lang_cell(), Path, Regenerate STATUS.md from disk. True if it changed. The single implementation…, [] if STATUS.md matches the filesystem; the differing lines otherwise.…, Count only material that meets the quality floor in pipeline.yaml. `wanted` is… (+3 more)

### Community 1 - "certs.py"
Cohesion: 0.06
Nodes (58): BaseModel, FileResponse, Request, Response, get_catalog(), get_cert(), get_cert_video(), get_langs() (+50 more)

### Community 2 - "pipeline.py"
Cohesion: 0.15
Nodes (21): RuntimeError, main(), certs(), default_languages(), in_milestone(), languages_for(), load(), milestone() (+13 more)

### Community 3 - "tracker.py"
Cohesion: 0.06
Nodes (62): load_syllabus(), main(), Path, How many objectives the official page publishes. Network, no model., Structural signs the topic list was computed rather than read. Offline.…, smells(), upstream_objectives(), frozen() (+54 more)

### Community 4 - "video.py"
Cohesion: 0.12
Nodes (42): FreeTypeFont, Image, ImageDraw, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat() (+34 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.04
Nodes (46): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails (+38 more)

### Community 6 - "claims.py"
Cohesion: 0.08
Nodes (22): check_cert(), main(), _topics(), main(), Every active certification with what it still needs, most urgent first., survey(), _topic_count(), main() (+14 more)

### Community 7 - "generator.py"
Cohesion: 0.06
Nodes (57): Completer, dominant(), effective(), main(), (model, effort, notes) as the generator would resolve them right now. Resolved…, recent(), evaluate(), main() (+49 more)

### Community 8 - "cli.py"
Cohesion: 0.08
Nodes (36): command, cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+28 more)

### Community 9 - "datetime"
Cohesion: 0.07
Nodes (44): datetime, backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main() (+36 more)

### Community 10 - "Lab Lifecycle Management"
Cohesion: 0.23
Nodes (23): CompletedProcess, down(), _down_cluster(), _down_container(), lab_dir(), _lab_name(), LabError, _load_spec() (+15 more)

### Community 11 - "Staleness Detection Tests"
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
Cohesion: 0.11
Nodes (19): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-16, 2026-07-17, 2026-07-19, 2026-07-27, 2026-07-28 (+11 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.11
Nodes (18): 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, Catalog by Categories, CLI, Code Architecture, Data Model (+10 more)

### Community 17 - "Removed K8s API Checks"
Cohesion: 0.18
Nodes (9): _deliberate(), findings(), main(), Path, Path, Detection of removed Kubernetes APIs. What is tested is the judgement, not the…, Mentioning 'removed' in another paragraph cannot give a free pass to a stale…, Istio and Tekton version independently: their v1beta1 may be current. (+1 more)

### Community 18 - "load_env"
Cohesion: 0.23
Nodes (6): load_env(), Path, Read KEY=VALUE lines into the environment. Returns how many were set.…, EnvScopeTests, Path, `.env` may configure translation and nothing else. It exists for one purpose —…

### Community 19 - "Translation Damage Tests"
Cohesion: 0.21
Nodes (6): Blanking comment text must not let a model drop the line entirely: the '#'…, Re-padding is the model's job: a diagram whose borders no longer line up is…, |' and '-' are excluded from the box character set on purpose, so an ordinary…, The cheap-model failure the length band exists for., The failure that silently breaks every example: the model translates the…, RejectsDamagedTranslations

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.14
Nodes (3): A snapshot must be refused when the source document does not support it. Seven…, A snapshot must be refused when the document does not support it. Seven…, SyllabusCoverageTests

### Community 21 - "Project Backlog"
Cohesion: 0.17
Nodes (12): Backlog, Content, Deploy — Technical Debt, In Progress / Next (Ordering), Labs — Execution Modes (see PLAN.md, SDD section), Labs — what an audit found, 2026-08-08 (design parked, not started), Pipeline Automation, Platform (Long-Term Roadmap, see PLAN.md) (+4 more)

### Community 22 - "teach-plat"
Cohesion: 0.15
Nodes (13): AI-generated content — disclosure, Content process, Deploying to Kubernetes, Environment variables, Generation backends, Languages, Licence, Public Docker image (+5 more)

### Community 24 - "Truth Auditor Design"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 25 - "Translation Cost Study"
Cohesion: 0.22
Nodes (9): Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results, Three bugs this study found in our own checks, Translating is not the same deliverable as authoring, What this actually saves (+1 more)

### Community 26 - "Helm Chart Docs"
Cohesion: 0.25
Nodes (7): Configuration, Install, License, Local Development, Philosophy, Prerequisites, Study CyberCirujas Helm Chart

### Community 28 - "Which backend authors better material?"
Cohesion: 0.25
Nodes (8): Caveats, fable-5 vs opus-5, within cgoa (2026-08-19), The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 29 - "Citation Source Checks"
Cohesion: 0.43
Nodes (6): catalogue(), cited_domains(), main(), Path, (domain -> project, neutral domains, raw config)., Hosts cited in the references section only. URLs in the body are examples and…

### Community 30 - "Development Guidelines"
Cohesion: 0.33
Nodes (6): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Rules, Verification: what is proven, and what is only assumed

### Community 31 - "API Facts Verification"
Cohesion: 0.53
Nodes (5): check(), main(), {(apiVersion, kind)} served by that release, from the published spec., spec_kinds(), tracked_versions()

### Community 32 - "Citation Claim Checking"
Cohesion: 0.47
Nodes (5): ask(), main(), (label, url) from the references section only. URLs in the body are examples…, Fetch and judge. Deliberately a separate process per claim: one failure should…, references()

### Community 33 - "Content Status"
Cohesion: 0.29
Nodes (7): Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos, Spend (measured)

### Community 34 - "Citation URL Checks"
Cohesion: 0.70
Nodes (4): citations(), main(), Path, status()

### Community 35 - "Manifest Validation"
Cohesion: 0.70
Nodes (4): main(), problems(), Path, _skip()

### Community 36 - "Usage Reporting"
Cohesion: 0.70
Nodes (4): main(), _money(), rows(), _tokens()

### Community 37 - "Model Backfill Script"
Cohesion: 0.67
Nodes (3): evidence(), main(), (cert, topic, lang) -> model, from the most recent completion for it.

### Community 45 - "main"
Cohesion: 0.16
Nodes (18): generate(), generate_with_retries(), main(), pending(), Topics still missing for this combination, in syllabus order., One topic, start to finish. Returns done | failed | skipped | fatal. The claim…, _sort_key(), budget() (+10 more)

### Community 46 - "quality.py"
Cohesion: 0.40
Nodes (5): check(), Quality floor for generated material, identical for every backend. A different…, Rules for 'content' or 'exercises'. With no `quality` block in the YAML there…, Return the problems found. An empty list means the floor is met. `kind` is…, rules()

### Community 47 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.18
Nodes (11): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 6. Where the value actually is (owner's question, 2026-08-18), 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith) (+3 more)

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "fix_corrupted_content.py"
Cohesion: 0.14
Nodes (22): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), A veces el backend envuelve la respuesta entera en ```markdown ... ``` (visto…, [(cert, lang), ...] declared in pipeline.yaml but not rendered. Kept OUT of… (+14 more)

### Community 50 - "steer.py"
Cohesion: 0.33
Nodes (8): _cert_block(), create_block(), main(), (start, end) line indices of a certification's block, so edits are surgical.…, Add a certification to pipeline.yaml that is not there yet. `activate` used to…, Set one key inside one certification. True if the file changed., set_key(), show()

### Community 52 - "publish_if_complete.py"
Cohesion: 0.29
Nodes (10): complete_certs(), is_complete(), main(), publish(), Build in-cluster, then deploy — with the SAME tag passed to both. `TAG`…, (complete, why not). Everything the certification declares must be there.…, _record(), _save() (+2 more)

### Community 53 - "DEVTOOLS.md"
Cohesion: 0.29
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 56 - "run_cert.py"
Cohesion: 0.60
Nodes (4): main(), pending_topics(), # NOTE: --to, not --lang. `--lang` re-authors from the syllabus and, run()

### Community 57 - "Within one certification (the only fair comparisons; authoring language `en` only)"
Cohesion: 0.22
Nodes (9): cgoa, cnpa, kca, kcsa, lpic-3-303, Model Comparison, What a quota window buys (759,943 output tokens/window, measured on this machine), Whole corpus, per model (context, not a verdict) (+1 more)

### Community 64 - "quota.py"
Cohesion: 0.53
Nodes (5): main(), probe(), Returns (exit-style status, detail). Cheap by construction: the prompt asks for…, record(), show_history()

## Knowledge Gaps
- **200 isolated node(s):** `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script`, `run_milestone.sh script`, `TEACH_AGENT` (+195 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` to `README.md`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Why does `make_completer()` connect `generator.py` to `fix_corrupted_content.py`, `tracker.py`, `video.py`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **Why does `load_env()` connect `load_env` to `certs.py`?**
  _High betweenness centrality (0.018) - this node is a cross-community bridge._
- **What connects `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script` to the rest of the system?**
  _200 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `certs.py` be split into smaller, more focused modules?**
  _Cohesion score 0.0597567424643046 - nodes in this community are weakly interconnected._
- **Should `pipeline.py` be split into smaller, more focused modules?**
  _Cohesion score 0.14624505928853754 - nodes in this community are weakly interconnected._
- **Should `tracker.py` be split into smaller, more focused modules?**
  _Cohesion score 0.056535504296698326 - nodes in this community are weakly interconnected._