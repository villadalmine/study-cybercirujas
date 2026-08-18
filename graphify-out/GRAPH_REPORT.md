# Graph Report - teach-plat  (2026-08-18)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 875 nodes · 1478 edges · 59 communities (53 shown, 6 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 5 edges (avg confidence: 0.56)
- Token cost: 33,763 input · 2,810 output

## Graph Freshness
- Built from commit: `2ee91f23`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Content Corruption Audit
- Web API & Auth
- Pipeline Config & Quality
- Syllabus Snapshot Checks
- Video Slide Rendering
- Agent Sync Queue
- Provenance & Usage Reports
- Topic Content Generation
- CLI Commands
- Spend Metrics & Quota
- Lab Lifecycle Management
- Staleness Detection Tests
- Architecture Context Doc
- Quality Floor Tests
- Content Workflow Guide
- Changelog
- Platform Architecture Plan
- Removed K8s API Checks
- Environment Loading
- Translation Damage Tests
- Syllabus Coverage Tests
- Project Backlog
- Project README
- Truth Auditor Design
- Translation Cost Study
- Helm Chart Docs
- PDF OCR Extraction
- Backend Comparison Study
- Citation Source Checks
- Development Guidelines
- API Facts Verification
- Citation Claim Checking
- Content Status Matrix
- Citation URL Checks
- Manifest Validation
- Usage Reporting
- Model Backfill Script
- Milestone Run Script
- Pre-commit Hook
- Resume Generation Script
- Project Root
- Batch Generation Runner
- Translation Study & Quality
- Agentic Tooling Study
- Developer Tools Guide
- Status Matrix Generation
- Pipeline Steering Tool
- Config & Usage Recording
- Publish Complete Certs
- OpenWiki Documentation Scope
- Certification Run Script
- MCP Graph Config
- Run Until Complete
- Post-commit Hook

## God Nodes (most connected - your core abstractions)
1. `generate_topic()` - 18 edges
2. `Changelog` - 18 edges
3. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 18 edges
4. `main()` - 16 edges
5. `load()` - 15 edges
6. `_get()` - 15 edges
7. `load()` - 14 edges
8. `make_completer()` - 14 edges
9. `snapshot_topics()` - 13 edges
10. `Purpose: Analyze with another AI for architecture review` - 13 edges

## Surprising Connections (you probably didn't know these)
- `RejectsDamagedTranslations` --uses--> `GeneratorConfigError`  [INFERRED]
  tests/test_translation_verify.py → teach/core/generator.py
- `status()` --calls--> `refresh()`  [INFERRED]
  teach/cli.py → scripts/status_matrix.py
- `main()` --calls--> `claim()`  [EXTRACTED]
  scripts/fix_corrupted_content.py → teach/core/claims.py
- `main()` --calls--> `in_milestone()`  [EXTRACTED]
  scripts/fix_corrupted_content.py → teach/core/pipeline.py
- `main()` --calls--> `is_fatal()`  [EXTRACTED]
  scripts/fix_corrupted_content.py → teach/core/pipeline.py

## Import Cycles
- None detected.

## Communities (59 total, 6 thin omitted)

### Community 0 - "Content Corruption Audit"
Cohesion: 0.13
Nodes (23): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), A veces el backend envuelve la respuesta entera en ```markdown ... ``` (visto…, [(cert, lang), ...] declared in pipeline.yaml but not rendered. Kept OUT of… (+15 more)

### Community 1 - "Web API & Auth"
Cohesion: 0.11
Nodes (24): BaseModel, FileResponse, Request, get_cert_video(), get_langs(), get_path_video(), index(), login() (+16 more)

### Community 2 - "Pipeline Config & Quality"
Cohesion: 0.16
Nodes (19): RuntimeError, main(), budget(), certs(), default_languages(), is_fatal(), is_retryable(), languages_for() (+11 more)

### Community 3 - "Syllabus Snapshot Checks"
Cohesion: 0.05
Nodes (64): Response, load_syllabus(), main(), Path, How many objectives the official page publishes. Network, no model., Structural signs the topic list was computed rather than read. Offline.…, smells(), upstream_objectives() (+56 more)

### Community 4 - "Video Slide Rendering"
Cohesion: 0.13
Nodes (40): FreeTypeFont, Image, ImageDraw, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat() (+32 more)

### Community 5 - "Agent Sync Queue"
Cohesion: 0.05
Nodes (43): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives (+35 more)

### Community 6 - "Provenance & Usage Reports"
Cohesion: 0.07
Nodes (27): check_cert(), main(), _topics(), main(), observations(), (cert, topic, lang) -> tokens and minutes, from the recorded completions., One row per generated topic/language, attributed to the model in meta.yaml.…, usage_by_topic() (+19 more)

### Community 7 - "Topic Content Generation"
Cohesion: 0.06
Nodes (66): Completer, get_cert(), get_topic(), get_topic_preview(), Public teaser: first lines of the material + what the topic includes., _valid_lang(), cert_generate(), Generate content with AI for pending/stale topics. This AUTHORS from the… (+58 more)

### Community 8 - "CLI Commands"
Cohesion: 0.08
Nodes (34): command, cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+26 more)

### Community 9 - "Spend Metrics & Quota"
Cohesion: 0.09
Nodes (34): datetime, backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main() (+26 more)

### Community 10 - "Lab Lifecycle Management"
Cohesion: 0.23
Nodes (23): CompletedProcess, down(), _down_cluster(), _down_container(), lab_dir(), _lab_name(), LabError, _load_spec() (+15 more)

### Community 11 - "Staleness Detection Tests"
Cohesion: 0.13
Nodes (9): Invalidation cycle triggered by a syllabus change. Tested because the delicate…, A topic that never changed reports no outdated languages, however old its…, When in doubt, regenerate: if freshness cannot be proven, it is not assumed., Change detection in the snapshot, touching no disk and spending no budget., Weight sets the depth requested from the model, so changing it changes the…, Hand-enriched content is preserved and reported separately so a person decides,…, The case that drove the design: rebuilding Spanish cannot mark the topic…, SnapshotStatusTest (+1 more)

### Community 12 - "Architecture Context Doc"
Cohesion: 0.11
Nodes (18): CONTENT GENERATION PIPELINE, Date: 2026-07-27, DIFFERENTIATION vs EXISTING PLATFORMS, Generated from conversation with Kimi AI, HARDWARE INFRASTRUCTURE, HELM CHART, KEY DESIGN DECISIONS, Lab Lifecycle (+10 more)

### Community 13 - "Quality Floor Tests"
Cohesion: 0.11
Nodes (8): QualityFloorTest, QualityThresholdsTest, Quality floor: the same standard for every backend. Tested because a floor is…, The references section is explicitly requested by the prompt, and it is what…, The real case: CNPE produced 18 of 18 exercises with no collapsible answers…, Material is generated in seven languages; the heading changes and the floor…, The thresholds live in pipeline.yaml and are calibrated against material…, The floor is optional: a repo with no `quality` in the YAML must not break.…

### Community 14 - "Content Workflow Guide"
Cohesion: 0.11
Nodes (19): 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 3. Audit — never skip this, 4. Status, 5. Commit, 6. Publish — only for a complete certification (+11 more)

### Community 15 - "Changelog"
Cohesion: 0.11
Nodes (18): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-16, 2026-07-17, 2026-07-19, 2026-07-27, 2026-07-28 (+10 more)

### Community 16 - "Platform Architecture Plan"
Cohesion: 0.11
Nodes (18): 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, Catalog by Categories, CLI, Code Architecture, Data Model (+10 more)

### Community 17 - "Removed K8s API Checks"
Cohesion: 0.18
Nodes (9): _deliberate(), findings(), main(), Path, Path, Detection of removed Kubernetes APIs. What is tested is the judgement, not the…, Mentioning 'removed' in another paragraph cannot give a free pass to a stale…, Istio and Tekton version independently: their v1beta1 may be current. (+1 more)

### Community 18 - "Environment Loading"
Cohesion: 0.19
Nodes (7): load_env(), Path, Loads `.env` from the repository root, once, before anything reads a variable.…, Read KEY=VALUE lines into the environment. Returns how many were set.…, EnvScopeTests, Path, `.env` may configure translation and nothing else. It exists for one purpose —…

### Community 19 - "Translation Damage Tests"
Cohesion: 0.21
Nodes (6): Blanking comment text must not let a model drop the line entirely: the '#'…, Re-padding is the model's job: a diagram whose borders no longer line up is…, |' and '-' are excluded from the box character set on purpose, so an ordinary…, The cheap-model failure the length band exists for., The failure that silently breaks every example: the model translates the…, RejectsDamagedTranslations

### Community 20 - "Syllabus Coverage Tests"
Cohesion: 0.14
Nodes (3): A snapshot must be refused when the source document does not support it. Seven…, A snapshot must be refused when the document does not support it. Seven…, SyllabusCoverageTests

### Community 21 - "Project Backlog"
Cohesion: 0.17
Nodes (12): Backlog, Content, Deploy — Technical Debt, In Progress / Next (Ordering), Labs — Execution Modes (see PLAN.md, SDD section), Labs — what an audit found, 2026-08-08 (design parked, not started), Pipeline Automation, Platform (Long-Term Roadmap, see PLAN.md) (+4 more)

### Community 22 - "Project README"
Cohesion: 0.17
Nodes (12): Content process, Deploying to Kubernetes, Environment variables, Generation backends, Languages, Licence, Public Docker image, Quality (+4 more)

### Community 24 - "Truth Auditor Design"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 25 - "Translation Cost Study"
Cohesion: 0.22
Nodes (9): Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results, Three bugs this study found in our own checks, Translating is not the same deliverable as authoring, What this actually saves (+1 more)

### Community 26 - "Helm Chart Docs"
Cohesion: 0.25
Nodes (7): Configuration, Install, License, Local Development, Philosophy, Prerequisites, Study CyberCirujas Helm Chart

### Community 27 - "PDF OCR Extraction"
Cohesion: 0.46
Nodes (7): embedded_text(), fetch(), main(), ocr(), Path, What the PDF's own text layer yields. Empty-ish means OCR is needed., (text, engine). Renders each page, then reads the pixels.

### Community 28 - "Backend Comparison Study"
Cohesion: 0.29
Nodes (7): Caveats, The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

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

### Community 33 - "Content Status Matrix"
Cohesion: 0.33
Nodes (6): Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos

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

### Community 45 - "Batch Generation Runner"
Cohesion: 0.23
Nodes (12): generate(), generate_with_retries(), main(), pending(), Topics still missing for this combination, in syllabus order., One topic, start to finish. Returns done | failed | skipped | fatal. The claim…, _sort_key(), me() (+4 more)

### Community 46 - "Translation Study & Quality"
Cohesion: 0.20
Nodes (12): evaluate(), main(), master_key(), Run the pipeline's own two gates. Verdict plus the reasons it failed., Read the proxy key from the cluster rather than from a file on disk. It is only…, One completion through the proxy. Returns text plus what it cost., translate(), check() (+4 more)

### Community 47 - "Agentic Tooling Study"
Cohesion: 0.18
Nodes (11): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 6. Where the value actually is (owner's question, 2026-08-18), 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith) (+3 more)

### Community 48 - "Developer Tools Guide"
Cohesion: 0.14
Nodes (14): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Setup, once, Setup, once per clone (+6 more)

### Community 49 - "Status Matrix Generation"
Cohesion: 0.16
Nodes (17): cert_topics(), check(), lab_cell(), lang_cell(), Path, [] if STATUS.md matches the filesystem; the differing lines otherwise.…, Count only material that meets the quality floor in pipeline.yaml. `wanted` is…, Regenerate STATUS.md from disk. True if it changed. The single implementation… (+9 more)

### Community 50 - "Pipeline Steering Tool"
Cohesion: 0.33
Nodes (8): _cert_block(), create_block(), main(), (start, end) line indices of a certification's block, so edits are surgical.…, Add a certification to pipeline.yaml that is not there yet. `activate` used to…, Set one key inside one certification. True if the file changed., set_key(), show()

### Community 51 - "Config & Usage Recording"
Cohesion: 0.29
Nodes (9): dominant(), effective(), main(), (model, effort, notes) as the generator would resolve them right now. Resolved…, recent(), Append one line per completion: what it was for, and what it cost. Never…, _record_usage(), generation() (+1 more)

### Community 52 - "Publish Complete Certs"
Cohesion: 0.33
Nodes (9): complete_certs(), is_complete(), main(), publish(), Build in-cluster, then deploy — with the SAME tag passed to both. `TAG`…, (complete, why not). Everything the certification declares must be there.…, _record(), _save() (+1 more)

### Community 53 - "OpenWiki Documentation Scope"
Cohesion: 0.29
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 56 - "Certification Run Script"
Cohesion: 0.60
Nodes (4): main(), pending_topics(), # NOTE: --to, not --lang. `--lang` re-authors from the syllabus and, run()

### Community 59 - "Run Until Complete"
Cohesion: 0.50
Nodes (4): main(), pending(), Maximum topics one invocation may generate. 0 means unbounded, which is…, topics_per_run()

## Knowledge Gaps
- **185 isolated node(s):** `CONTENT GENERATION PIPELINE`, `Date: 2026-07-27`, `DIFFERENTIATION vs EXISTING PLATFORMS`, `Generated from conversation with Kimi AI`, `HARDWARE INFRASTRUCTURE` (+180 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Sync Queue` to `Documentation Index`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Why does `make_completer()` connect `Topic Content Generation` to `Content Corruption Audit`, `Syllabus Snapshot Checks`, `Video Slide Rendering`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **What connects `CONTENT GENERATION PIPELINE`, `Date: 2026-07-27`, `DIFFERENTIATION vs EXISTING PLATFORMS` to the rest of the system?**
  _185 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Content Corruption Audit` be split into smaller, more focused modules?**
  _Cohesion score 0.13405797101449277 - nodes in this community are weakly interconnected._
- **Should `Web API & Auth` be split into smaller, more focused modules?**
  _Cohesion score 0.11384615384615385 - nodes in this community are weakly interconnected._
- **Should `Syllabus Snapshot Checks` be split into smaller, more focused modules?**
  _Cohesion score 0.05487269534679543 - nodes in this community are weakly interconnected._
- **Should `Video Slide Rendering` be split into smaller, more focused modules?**
  _Cohesion score 0.12926829268292683 - nodes in this community are weakly interconnected._