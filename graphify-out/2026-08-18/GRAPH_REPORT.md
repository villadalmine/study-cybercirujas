# Graph Report - teach-plat  (2026-08-18)

## Corpus Check
- 69 files · ~92,354 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 826 nodes · 1422 edges · 45 communities (41 shown, 4 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 5 edges (avg confidence: 0.56)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `43ef4741`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- fix_corrupted_content.py
- generator.py
- pipeline.py
- tracker.py
- video.py
- Agent Synchronization & Idea Queue (AGENTS_SYNC.md)
- claims.py
- api.py
- cli.py
- datetime
- labs.py
- StaleCycleTest
- Purpose: Analyze with another AI for architecture review
- QualityFloorTest
- The loop
- Changelog
- Educational Platform
- RemovedApiTest
- core/__init__.py
- RejectsDamagedTranslations
- SyllabusCoverageTests
- Backlog
- teach-plat
- Verifying the material is true — design notes
- Can a cheap model do the translation step?
- Study CyberCirujas Helm Chart
- ocr_pdf.py
- Which backend authors better material?
- check_sources.py
- Development Guidelines for teach-plat
- check_api_facts.py
- check_claims.py
- Content Status
- main
- problems
- usage_report.py
- evidence
- run_milestone.sh
- pre-commit
- resume-generation.sh
- teach-plat

## God Nodes (most connected - your core abstractions)
1. `generate_topic()` - 18 edges
2. `Changelog` - 18 edges
3. `Agent Synchronization & Idea Queue (AGENTS_SYNC.md)` - 17 edges
4. `main()` - 16 edges
5. `load()` - 15 edges
6. `_get()` - 15 edges
7. `load()` - 14 edges
8. `make_completer()` - 14 edges
9. `snapshot_topics()` - 13 edges
10. `Educational Platform` - 13 edges

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

## Communities (45 total, 4 thin omitted)

### Community 0 - "fix_corrupted_content.py"
Cohesion: 0.05
Nodes (61): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), A veces el backend envuelve la respuesta entera en ```markdown ... ``` (visto…, [(cert, lang), ...] declared in pipeline.yaml but not rendered. Kept OUT of… (+53 more)

### Community 1 - "generator.py"
Cohesion: 0.06
Nodes (59): Completer, cert_generate(), Generate content with AI for pending/stale topics. This AUTHORS from the…, clear_topic_stale(), content_dir(), get_topic(), load(), md_path() (+51 more)

### Community 2 - "pipeline.py"
Cohesion: 0.06
Nodes (56): RuntimeError, dominant(), effective(), main(), (model, effort, notes) as the generator would resolve them right now. Resolved…, recent(), main(), generate() (+48 more)

### Community 3 - "tracker.py"
Cohesion: 0.06
Nodes (57): load_syllabus(), main(), Path, How many objectives the official page publishes. Network, no model., Structural signs the topic list was computed rather than read. Offline.…, smells(), upstream_objectives(), frozen() (+49 more)

### Community 4 - "video.py"
Cohesion: 0.11
Nodes (44): FreeTypeFont, Image, ImageDraw, cert_video(), paths_video(), Render a certification video (slides + Piper voice + ffmpeg)., Render the video (slides + Piper voice + ffmpeg) from script.yaml., _ask_scenes() (+36 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.05
Nodes (42): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives (+34 more)

### Community 6 - "claims.py"
Cohesion: 0.07
Nodes (27): check_cert(), main(), _topics(), main(), observations(), (cert, topic, lang) -> tokens and minutes, from the recorded completions., One row per generated topic/language, attributed to the model in meta.yaml.…, usage_by_topic() (+19 more)

### Community 7 - "api.py"
Cohesion: 0.09
Nodes (36): BaseModel, FileResponse, Request, Response, get_catalog(), get_cert(), get_cert_video(), get_langs() (+28 more)

### Community 8 - "cli.py"
Cohesion: 0.09
Nodes (30): command, cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video_script(), lab_down() (+22 more)

### Community 9 - "datetime"
Cohesion: 0.09
Nodes (28): datetime, main(), probe(), Returns (exit-style status, detail). Cheap by construction: the prompt asks for…, record(), show_history(), by_topic(), dominant() (+20 more)

### Community 10 - "labs.py"
Cohesion: 0.23
Nodes (23): CompletedProcess, down(), _down_cluster(), _down_container(), lab_dir(), _lab_name(), LabError, _load_spec() (+15 more)

### Community 11 - "StaleCycleTest"
Cohesion: 0.13
Nodes (9): Invalidation cycle triggered by a syllabus change. Tested because the delicate…, A topic that never changed reports no outdated languages, however old its…, When in doubt, regenerate: if freshness cannot be proven, it is not assumed., Change detection in the snapshot, touching no disk and spending no budget., Weight sets the depth requested from the model, so changing it changes the…, Hand-enriched content is preserved and reported separately so a person decides,…, The case that drove the design: rebuilding Spanish cannot mark the topic…, SnapshotStatusTest (+1 more)

### Community 12 - "Purpose: Analyze with another AI for architecture review"
Cohesion: 0.11
Nodes (18): CONTENT GENERATION PIPELINE, Date: 2026-07-27, DIFFERENTIATION vs EXISTING PLATFORMS, Generated from conversation with Kimi AI, HARDWARE INFRASTRUCTURE, HELM CHART, KEY DESIGN DECISIONS, Lab Lifecycle (+10 more)

### Community 13 - "QualityFloorTest"
Cohesion: 0.11
Nodes (8): QualityFloorTest, QualityThresholdsTest, Quality floor: the same standard for every backend. Tested because a floor is…, The references section is explicitly requested by the prompt, and it is what…, The real case: CNPE produced 18 of 18 exercises with no collapsible answers…, Material is generated in seven languages; the heading changes and the floor…, The thresholds live in pipeline.yaml and are calibrated against material…, The floor is optional: a repo with no `quality` in the YAML must not break.…

### Community 14 - "The loop"
Cohesion: 0.11
Nodes (19): 1. Snapshot the syllabus — once per certification, 2. Generate, 2b. The quality floor — the same standard for every backend, 2c. What "quality" can and cannot be proven mechanically, 3. Audit — never skip this, 4. Status, 5. Commit, 6. Publish — only for a complete certification (+11 more)

### Community 15 - "Changelog"
Cohesion: 0.11
Nodes (18): 12e01a6 — Paths + Linux Foundation, 1d4bd14 — Multilingual + Deploy, 2026-07-11/12, 2026-07-16, 2026-07-17, 2026-07-19, 2026-07-27, 2026-07-28 (+10 more)

### Community 16 - "Educational Platform"
Cohesion: 0.11
Nodes (18): 1. Catalog Tracker (Scraper — nothing is static), 2. Generator (AI, on-demand), 3. Web: Public Landing + Paid Study Zone, Architecture — 3 Components, Catalog by Categories, CLI, Code Architecture, Data Model (+10 more)

### Community 17 - "RemovedApiTest"
Cohesion: 0.18
Nodes (9): _deliberate(), findings(), main(), Path, Path, Detection of removed Kubernetes APIs. What is tested is the judgement, not the…, Mentioning 'removed' in another paragraph cannot give a free pass to a stale…, Istio and Tekton version independently: their v1beta1 may be current. (+1 more)

### Community 18 - "core/__init__.py"
Cohesion: 0.19
Nodes (7): load_env(), Path, Loads `.env` from the repository root, once, before anything reads a variable.…, Read KEY=VALUE lines into the environment. Returns how many were set.…, EnvScopeTests, Path, `.env` may configure translation and nothing else. It exists for one purpose —…

### Community 19 - "RejectsDamagedTranslations"
Cohesion: 0.21
Nodes (6): Blanking comment text must not let a model drop the line entirely: the '#'…, Re-padding is the model's job: a diagram whose borders no longer line up is…, |' and '-' are excluded from the box character set on purpose, so an ordinary…, The cheap-model failure the length band exists for., The failure that silently breaks every example: the model translates the…, RejectsDamagedTranslations

### Community 20 - "SyllabusCoverageTests"
Cohesion: 0.14
Nodes (3): A snapshot must be refused when the source document does not support it. Seven…, A snapshot must be refused when the document does not support it. Seven…, SyllabusCoverageTests

### Community 21 - "Backlog"
Cohesion: 0.17
Nodes (12): Backlog, Content, Deploy — Technical Debt, In Progress / Next (Ordering), Labs — Execution Modes (see PLAN.md, SDD section), Labs — what an audit found, 2026-08-08 (design parked, not started), Pipeline Automation, Platform (Long-Term Roadmap, see PLAN.md) (+4 more)

### Community 22 - "teach-plat"
Cohesion: 0.17
Nodes (12): Content process, Deploying to Kubernetes, Environment variables, Generation backends, Languages, Licence, Public Docker image, Quality (+4 more)

### Community 24 - "Verifying the material is true — design notes"
Cohesion: 0.20
Nodes (10): A funnel, cheapest layer first, Honest limits, Layer 0 — what exists (free, deterministic), Layer 1 — a structured fact base, no RAG at all (free, deterministic), Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing), Layer 3 — adversarial judging (costs quota, sample only), The design mistake to avoid, The gap, precisely (+2 more)

### Community 25 - "Can a cheap model do the translation step?"
Cohesion: 0.22
Nodes (9): Can a cheap model do the translation step?, Caveat, Method, Recommendation, Results, Three bugs this study found in our own checks, Translating is not the same deliverable as authoring, What this actually saves (+1 more)

### Community 26 - "Study CyberCirujas Helm Chart"
Cohesion: 0.25
Nodes (7): Configuration, Install, License, Local Development, Philosophy, Prerequisites, Study CyberCirujas Helm Chart

### Community 27 - "ocr_pdf.py"
Cohesion: 0.46
Nodes (7): embedded_text(), fetch(), main(), ocr(), Path, What the PDF's own text layer yields. Empty-ish means OCR is needed., (text, engine). Renders each page, then reads the pixels.

### Community 28 - "Which backend authors better material?"
Cohesion: 0.29
Nodes (7): Caveats, The 62% figure, and why it is not what it looks like, The headline: on every objective check, they tie, The same-topic head-to-head, which reverses the conclusion above, What this means for the choice, Where they differ: volume and shape, Which backend authors better material?

### Community 29 - "check_sources.py"
Cohesion: 0.43
Nodes (6): catalogue(), cited_domains(), main(), Path, (domain -> project, neutral domains, raw config)., Hosts cited in the references section only. URLs in the body are examples and…

### Community 30 - "Development Guidelines for teach-plat"
Cohesion: 0.33
Nodes (6): Agent Idea Synchronization (AGENTS_SYNC.md), Commands, Content Workflow, Development Guidelines for teach-plat, Rules, Verification: what is proven, and what is only assumed

### Community 31 - "check_api_facts.py"
Cohesion: 0.53
Nodes (5): check(), main(), {(apiVersion, kind)} served by that release, from the published spec., spec_kinds(), tracked_versions()

### Community 32 - "check_claims.py"
Cohesion: 0.47
Nodes (5): ask(), main(), (label, url) from the references section only. URLs in the body are examples…, Fetch and judge. Deliberately a separate process per claim: one failure should…, references()

### Community 33 - "Content Status"
Cohesion: 0.33
Nodes (6): Certification Videos, Certifications, Content Status, Exam versions, Milestone, Path Videos

### Community 34 - "main"
Cohesion: 0.70
Nodes (4): citations(), main(), Path, status()

### Community 35 - "problems"
Cohesion: 0.70
Nodes (4): main(), problems(), Path, _skip()

### Community 36 - "usage_report.py"
Cohesion: 0.70
Nodes (4): main(), _money(), rows(), _tokens()

### Community 37 - "evidence"
Cohesion: 0.67
Nodes (3): evidence(), main(), (cert, topic, lang) -> model, from the most recent completion for it.

## Knowledge Gaps
- **161 isolated node(s):** `teach-plat`, `resume-generation.sh script`, `run_milestone.sh script`, `TEACH_AGENT`, `Workflow Rules for Agents` (+156 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `make_completer()` connect `generator.py` to `fix_corrupted_content.py`, `tracker.py`, `video.py`?**
  _High betweenness centrality (0.021) - this node is a cross-community bridge._
- **What connects `teach-plat`, `resume-generation.sh script`, `run_milestone.sh script` to the rest of the system?**
  _161 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `fix_corrupted_content.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05128205128205128 - nodes in this community are weakly interconnected._
- **Should `generator.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06298076923076923 - nodes in this community are weakly interconnected._
- **Should `pipeline.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05734767025089606 - nodes in this community are weakly interconnected._
- **Should `tracker.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06174863387978142 - nodes in this community are weakly interconnected._
- **Should `video.py` be split into smaller, more focused modules?**
  _Cohesion score 0.1111111111111111 - nodes in this community are weakly interconnected._