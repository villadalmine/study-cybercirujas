# Graph Report - teach-plat  (2026-08-18)

## Corpus Check
- 74 files · ~96,024 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 854 nodes · 1455 edges · 63 communities (55 shown, 8 thin omitted)
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
- certs.py
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
- load_env
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
- main
- quality.py
- Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)
- fetch_text
- status_matrix.py
- check_versions.py
- generation
- publish_if_complete.py
- catalog.py
- _english
- quota.py
- run_cert.py
- sync_cncf
- graphify
- run_until_complete.py
- post-commit
- core/__init__.py

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

## Communities (63 total, 8 thin omitted)

### Community 0 - "fix_corrupted_content.py"
Cohesion: 0.13
Nodes (23): _cert_topic_ids(), find_bad_combos(), find_missing_videos(), _finish(), main(), _publish_if_complete(), A veces el backend envuelve la respuesta entera en ```markdown ... ``` (visto…, [(cert, lang), ...] declared in pipeline.yaml but not rendered. Kept OUT of… (+15 more)

### Community 1 - "generator.py"
Cohesion: 0.12
Nodes (28): Completer, _agent_completer(), _antigravity_completer(), _comparable_code(), _dominant_model(), GeneratorConfigError, _litellm_completer(), make_completer() (+20 more)

### Community 2 - "pipeline.py"
Cohesion: 0.11
Nodes (29): RuntimeError, main(), _cert_block(), create_block(), main(), (start, end) line indices of a certification's block, so edits are surgical.…, Add a certification to pipeline.yaml that is not there yet. `activate` used to…, Set one key inside one certification. True if the file changed. (+21 more)

### Community 3 - "tracker.py"
Cohesion: 0.14
Nodes (23): save(), _ai_yaml(), _apply_snapshot_status(), generate_paths(), _get_bytes(), normalise_weights(), Exception, Tracker/scraper: nothing is static — the whole catalog derives from sources. -… (+15 more)

### Community 4 - "video.py"
Cohesion: 0.13
Nodes (40): FreeTypeFont, Image, ImageDraw, _ask_scenes(), _base_slide(), _cert_domains(), cert_media_dir(), _concat() (+32 more)

### Community 5 - "Agent Synchronization & Idea Queue (AGENTS_SYNC.md)"
Cohesion: 0.05
Nodes (42): Agent Synchronization & Idea Queue (AGENTS_SYNC.md), Blocked: Gemini API 403 (ongoing since ~05:00 UTC 2026-08-08), Changed, do not redo, Checks that cost no quota — run them, they are free, Decisions left to the owner, not to us, Division of work — owner's call, 2026-08-07, First: install the hook. It is the only rule that does not depend on you., From claude — 2026-08-11: seven LPI syllabi were the table of contents, not the objectives (+34 more)

### Community 6 - "claims.py"
Cohesion: 0.07
Nodes (27): check_cert(), main(), _topics(), main(), observations(), (cert, topic, lang) -> tokens and minutes, from the recorded completions., One row per generated topic/language, attributed to the model in meta.yaml.…, usage_by_topic() (+19 more)

### Community 7 - "certs.py"
Cohesion: 0.06
Nodes (64): BaseModel, FileResponse, Request, Response, get_catalog(), get_cert(), get_cert_video(), get_langs() (+56 more)

### Community 8 - "cli.py"
Cohesion: 0.08
Nodes (34): command, cert_add(), cert_list(), cert_show(), cert_snapshot(), cert_translate(), cert_video(), cert_video_script() (+26 more)

### Community 9 - "datetime"
Cohesion: 0.10
Nodes (29): datetime, backend_of(), _fmt(), in_tokens(), main(), rows(), session_windows(), by_topic() (+21 more)

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

### Community 18 - "load_env"
Cohesion: 0.23
Nodes (6): load_env(), Path, Read KEY=VALUE lines into the environment. Returns how many were set.…, EnvScopeTests, Path, `.env` may configure translation and nothing else. It exists for one purpose —…

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

### Community 45 - "main"
Cohesion: 0.16
Nodes (18): generate(), generate_with_retries(), main(), pending(), Topics still missing for this combination, in syllabus order., One topic, start to finish. Returns done | failed | skipped | fatal. The claim…, _sort_key(), budget() (+10 more)

### Community 46 - "quality.py"
Cohesion: 0.20
Nodes (12): evaluate(), main(), master_key(), Run the pipeline's own two gates. Verdict plus the reasons it failed., Read the proxy key from the cluster rather than from a file on disk. It is only…, One completion through the proxy. Returns text plus what it cost., translate(), check() (+4 more)

### Community 47 - "Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith)"
Cohesion: 0.17
Nodes (11): 1. Graphify — measured pilot, 2026-08-18, 2. OpenWiki — studied, not yet run (every run spends), 3. LangSmith — optional visibility, narrow fit, 4. The plan, 5. Costs, summarized, 6. Where the value actually is (owner's question, 2026-08-18), 7. Decisions that belong to the owner, Agentic Tooling Study: Graphify + OpenWiki (+ LangSmith) (+3 more)

### Community 48 - "fetch_text"
Cohesion: 0.24
Nodes (11): load_syllabus(), main(), Path, How many objectives the official page publishes. Network, no model., Structural signs the topic list was computed rather than read. Offline.…, smells(), upstream_objectives(), fetch_text() (+3 more)

### Community 49 - "status_matrix.py"
Cohesion: 0.27
Nodes (11): cert_topics(), check(), lab_cell(), lang_cell(), Path, [] if STATUS.md matches the filesystem; the differing lines otherwise.…, Count only material that meets the quality floor in pipeline.yaml. `wanted` is…, Regenerate STATUS.md from disk. True if it changed. The single implementation… (+3 more)

### Community 50 - "check_versions.py"
Cohesion: 0.25
Nodes (10): frozen(), main(), (version, snapshot_date) as the syllabus records them — what we built on., True/False if both versions are known and comparable, else None. "3.0" and…, current | outdated | unknown. `unknown` is a real answer and is reported as…, _same_version(), state(), survey() (+2 more)

### Community 51 - "generation"
Cohesion: 0.29
Nodes (9): dominant(), effective(), main(), (model, effort, notes) as the generator would resolve them right now. Resolved…, recent(), Append one line per completion: what it was for, and what it cost. Never…, _record_usage(), generation() (+1 more)

### Community 52 - "publish_if_complete.py"
Cohesion: 0.33
Nodes (9): complete_certs(), is_complete(), main(), publish(), Build in-cluster, then deploy — with the SAME tag passed to both. `TAG`…, (complete, why not). Everything the certification declares must be there.…, _record(), _save() (+1 more)

### Community 53 - "catalog.py"
Cohesion: 0.33
Nodes (9): add_cert(), catalog_path(), get_cert(), list_certs(), load(), Path, Global certification catalog (catalog.yaml). Written by the tracker (and `cert…, Root of the data repo. Override with TEACH_ROOT. (+1 more)

### Community 54 - "_english"
Cohesion: 0.32
Nodes (5): AcceptsCorrectTranslations, _english(), The source with its prose in English, code block untouched., Comments are prose. The authored English material has English comments, so…, ASCII diagrams are prose too, and this one is not a retry away: `cheap`…

### Community 55 - "quota.py"
Cohesion: 0.53
Nodes (5): main(), probe(), Returns (exit-style status, detail). Cheap by construction: the prompt asks for…, record(), show_history()

### Community 56 - "run_cert.py"
Cohesion: 0.60
Nodes (4): main(), pending_topics(), # NOTE: --to, not --lang. `--lang` re-authors from the syllabus and, run()

### Community 57 - "sync_cncf"
Cohesion: 0.50
Nodes (4): Scrape the official sources and update the catalog., tracker_sync(), Each curriculum's version is the date of the last commit touching its PDF., sync_cncf()

## Knowledge Gaps
- **171 isolated node(s):** `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script`, `run_milestone.sh script`, `TEACH_AGENT` (+166 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **8 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `load_env()` connect `load_env` to `core/__init__.py`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Why does `make_completer()` connect `generator.py` to `fix_corrupted_content.py`, `tracker.py`, `video.py`, `certs.py`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **What connects `.venv/bin/python3`, `teach-plat`, `resume-generation.sh script` to the rest of the system?**
  _171 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `fix_corrupted_content.py` be split into smaller, more focused modules?**
  _Cohesion score 0.13405797101449277 - nodes in this community are weakly interconnected._
- **Should `generator.py` be split into smaller, more focused modules?**
  _Cohesion score 0.11724137931034483 - nodes in this community are weakly interconnected._
- **Should `pipeline.py` be split into smaller, more focused modules?**
  _Cohesion score 0.11088709677419355 - nodes in this community are weakly interconnected._
- **Should `tracker.py` be split into smaller, more focused modules?**
  _Cohesion score 0.14130434782608695 - nodes in this community are weakly interconnected._