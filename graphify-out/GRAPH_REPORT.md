# Graph Report - teach-plat  (2026-08-18)

## Corpus Check
- 76 files · ~99,687 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 882 nodes · 1490 edges · 62 communities (56 shown, 6 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 5 edges (avg confidence: 0.56)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b75ff812`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- fix_corrupted_content.py
- api.py
- pipeline.py
- tracker.py
- Video Slide Rendering
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- Provenance & Usage Reports
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
- Content Status
- Citation URL Checks
- Manifest Validation
- Usage Reporting
- Model Backfill Script
- Milestone Run Script
- Pre-commit Hook
- Resume Generation Script
- Project Root
- Batch Generation Runner
- certs.py
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- 1. The code graph (Graphify)
- status_matrix.py
- languages_for
- _agent_completer
- publish_if_complete.py
- OpenWiki scope for teach-plat
- _verify_translation
- generate_topic
- run_cert.py
- translation_study.py
- MCP Graph Config
- QualityThresholdsTest
- Post-commit Hook

## God Nodes (most connected - your core abstractions)
1. `generate_topic()` - 18 edges
2. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 18 edges
3. `Changelog` - 18 edges
4. `main()` - 16 edges
5. `load()` - 15 edges
6. `_get()` - 15 edges
7. `load()` - 14 edges
8. `make_completer()` - 14 edges
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

## Communities (62 total, 6 thin omitted)

### Community 0 - "fix_corrupted_content.py"
Cohesion: 0.14
Nodes (21): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), A veces el backend envuelve la respuesta entera en ```markdown ... ``` (visto…, [(cert, lang), ...] declared in pipeline.yaml but not rendered. Kept OUT of… (+13 more)

### Community 1 - "api.py"
Cohesion: 0.09
Nodes (36): BaseModel, FileResponse, Request, Response, get_catalog(), get_cert(), get_cert_video(), get_langs() (+28 more)

### Community 2 - "pipeline.py"
Cohesion: 0.13
Nodes (21): RuntimeError, main(), pending(), budget(), in_milestone(), is_fatal(), is_retryable(), load() (+13 more)

### Community 3 - "tracker.py"
Cohesion: 0.06
Nodes (57): load_syllabus(), main(), Path, How many objectives the official page publishes. Network, no model., Structural signs the topic list was computed rather than read. Offline.…, smells(), upstream_objectives(), frozen() (+49 more)

### Community 4 - "Video Slide Rendering"
Cohesion: 0.13
Nodes (40): FreeTypeFont, Image, ImageDraw, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat() (+32 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.04
Nodes (45): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., Found while wiring this up, not caused by it: check_manifests fails (+37 more)

### Community 6 - "Provenance & Usage Reports"
Cohesion: 0.07
Nodes (27): check_cert(), main(), _topics(), main(), observations(), (cert, topic, lang) -> tokens and minutes, from the recorded completions., One row per generated topic/language, attributed to the model in meta.yaml.…, usage_by_topic() (+19 more)

### Community 7 - "generator.py"
Cohesion: 0.13
Nodes (22): Completer, _antigravity_completer(), _dominant_model(), GeneratorConfigError, _litellm_completer(), make_completer(), Exception, Path (+14 more)

### Community 8 - "cli.py"
Cohesion: 0.08
Nodes (32): command, cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_video(), cert_video_script(), lab_down() (+24 more)

### Community 9 - "datetime"
Cohesion: 0.08
Nodes (36): datetime, backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), main() (+28 more)

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
Cohesion: 0.18
Nodes (4): QualityFloorTest, The references section is explicitly requested by the prompt, and it is what…, The real case: CNPE produced 18 of 18 exercises with no collapsible answers…, Material is generated in seven languages; the heading changes and the floor…

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

### Community 45 - "Batch Generation Runner"
Cohesion: 0.23
Nodes (12): generate(), generate_with_retries(), main(), pending(), Topics still missing for this combination, in syllabus order., One topic, start to finish. Returns done | failed | skipped | fatal. The claim…, _sort_key(), me() (+4 more)

### Community 46 - "certs.py"
Cohesion: 0.17
Nodes (19): cert_translate(), Translate existing content instead of re-authoring it in another language.…, content_dir(), get_topic(), md_path(), Path, Read/write the per-certification MD (syllabus snapshot + status). The MD with…, Crea el MD template de una cert nueva. El temario se completa a mano (TODO:… (+11 more)

### Community 47 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.17
Nodes (11): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 6. Where the value actually is (owner's question, 2026-08-18), 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith) (+3 more)

### Community 48 - "1. The code graph (Graphify)"
Cohesion: 0.12
Nodes (16): 1. The code graph (Graphify), 2. The wiki (OpenWiki), 3. Real metrics, end to end, Developer tools: code graph, wiki, and real metrics, Optional, costs completions, Reading the numbers, Semantic enrichment — documented, deliberately not run, Setup, once (+8 more)

### Community 49 - "status_matrix.py"
Cohesion: 0.14
Nodes (19): cert_topics(), check(), lab_cell(), lang_cell(), Path, Regenerate STATUS.md from disk. True if it changed. The single implementation…, [] if STATUS.md matches the filesystem; the differing lines otherwise.…, Count only material that meets the quality floor in pipeline.yaml. `wanted` is… (+11 more)

### Community 50 - "languages_for"
Cohesion: 0.16
Nodes (16): main(), _cert_block(), create_block(), main(), (start, end) line indices of a certification's block, so edits are surgical.…, Add a certification to pipeline.yaml that is not there yet. `activate` used to…, Set one key inside one certification. True if the file changed., set_key() (+8 more)

### Community 51 - "_agent_completer"
Cohesion: 0.29
Nodes (10): dominant(), effective(), main(), (model, effort, notes) as the generator would resolve them right now. Resolved…, recent(), _agent_completer(), Append one line per completion: what it was for, and what it cost. Never…, _record_usage() (+2 more)

### Community 52 - "publish_if_complete.py"
Cohesion: 0.33
Nodes (9): complete_certs(), is_complete(), main(), publish(), Build in-cluster, then deploy — with the SAME tag passed to both. `TAG`…, (complete, why not). Everything the certification declares must be there.…, _record(), _save() (+1 more)

### Community 53 - "OpenWiki scope for teach-plat"
Cohesion: 0.40
Nodes (4): OpenWiki scope for teach-plat, Style, What NOT to document, What to document

### Community 54 - "_verify_translation"
Cohesion: 0.21
Nodes (10): _comparable_code(), A code block reduced to the parts a translation must not touch. Code blocks are…, Structural checks a translation must satisfy but authoring cannot. This is what…, _verify_translation(), AcceptsCorrectTranslations, _english(), The structural gate that decides whether a translation is usable. Its own…, The source with its prose in English, code block untouched. (+2 more)

### Community 55 - "generate_topic"
Cohesion: 0.27
Nodes (11): cert_generate(), Generate content with AI for pending/stale topics. This AUTHORS from the…, clear_topic_stale(), load(), Post, Close the cycle for a stale topic: back to 'generated' and drop the timestamp,…, save(), set_topic_status() (+3 more)

### Community 56 - "run_cert.py"
Cohesion: 0.60
Nodes (4): main(), pending_topics(), # NOTE: --to, not --lang. `--lang` re-authors from the syllabus and, run()

### Community 57 - "translation_study.py"
Cohesion: 0.36
Nodes (7): evaluate(), main(), master_key(), Run the pipeline's own two gates. Verdict plus the reasons it failed., Read the proxy key from the cluster rather than from a file on disk. It is only…, One completion through the proxy. Returns text plus what it cost., translate()

### Community 59 - "QualityThresholdsTest"
Cohesion: 0.33
Nodes (3): QualityThresholdsTest, The thresholds live in pipeline.yaml and are calibrated against material…, The floor is optional: a repo with no `quality` in the YAML must not break.…

## Knowledge Gaps
- **189 isolated node(s):** `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script`, `run_milestone.sh script`, `TEACH_AGENT` (+184 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` connect `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` to `AGENTS_SYNC.md`?**
  _High betweenness centrality (0.021) - this node is a cross-community bridge._
- **Why does `make_completer()` connect `generator.py` to `fix_corrupted_content.py`, `tracker.py`, `Video Slide Rendering`, `certs.py`, `_agent_completer`, `generate_topic`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **What connects `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script` to the rest of the system?**
  _189 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `fix_corrupted_content.py` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._
- **Should `api.py` be split into smaller, more focused modules?**
  _Cohesion score 0.08961593172119488 - nodes in this community are weakly interconnected._
- **Should `pipeline.py` be split into smaller, more focused modules?**
  _Cohesion score 0.13438735177865613 - nodes in this community are weakly interconnected._
- **Should `tracker.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06174863387978142 - nodes in this community are weakly interconnected._