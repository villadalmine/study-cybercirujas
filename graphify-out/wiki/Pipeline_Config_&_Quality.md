# Pipeline Config & Quality

> 21 nodes · cohesion 0.16

## Key Concepts

- **pipeline.py** (37 connections) — `teach/core/pipeline.py`
- **load()** (15 connections) — `teach/core/pipeline.py`
- **languages_for()** (12 connections) — `teach/core/pipeline.py`
- **targets()** (8 connections) — `teach/core/pipeline.py`
- **budget()** (7 connections) — `teach/core/pipeline.py`
- **certs()** (6 connections) — `teach/core/pipeline.py`
- **is_fatal()** (6 connections) — `teach/core/pipeline.py`
- **main()** (4 connections) — `scripts/quality_report.py`
- **quality_report.py** (3 connections) — `scripts/quality_report.py`
- **default_languages()** (3 connections) — `teach/core/pipeline.py`
- **is_retryable()** (3 connections) — `teach/core/pipeline.py`
- **PipelineError** (3 connections) — `teach/core/pipeline.py`
- **on_demand_languages()** (2 connections) — `teach/core/pipeline.py`
- **path_video_languages()** (2 connections) — `teach/core/pipeline.py`
- **RuntimeError** (1 connections)
- **Path** (1 connections)
- **Reader for pipeline.yaml — the declarative definition of what the content…** (1 connections) — `teach/core/pipeline.py`
- **Certifications declared in the pipeline, as {cert_id: config}.** (1 connections) — `teach/core/pipeline.py`
- **Languages a certification is expected to have. A per-cert `languages` key…** (1 connections) — `teach/core/pipeline.py`
- **[(cert_id, [langs]), ...] — what the audit and the unattended resume script…** (1 connections) — `teach/core/pipeline.py`
- **True for errors where retrying cannot help (quota exhausted), as opposed to…** (1 connections) — `teach/core/pipeline.py`

## Relationships

- [Batch Generation Runner](Batch_Generation_Runner.md) (8 shared connections)
- [Status Matrix Generation](Status_Matrix_Generation.md) (7 shared connections)
- [Pipeline Steering Tool](Pipeline_Steering_Tool.md) (6 shared connections)
- [Content Corruption Audit](Content_Corruption_Audit.md) (5 shared connections)
- [Provenance & Usage Reports](Provenance_&_Usage_Reports.md) (4 shared connections)
- [Translation Study & Quality](Translation_Study_&_Quality.md) (3 shared connections)
- [Config & Usage Recording](Config_&_Usage_Recording.md) (3 shared connections)
- [Publish Complete Certs](Publish_Complete_Certs.md) (3 shared connections)
- [Run Until Complete](Run_Until_Complete.md) (3 shared connections)
- [Spend Metrics & Quota](Spend_Metrics_&_Quota.md) (2 shared connections)
- [Certification Run Script](Certification_Run_Script.md) (2 shared connections)
- [CLI Commands](CLI_Commands.md) (2 shared connections)

## Source Files

- `scripts/quality_report.py`
- `teach/core/pipeline.py`

## Audit Trail

- EXTRACTED: 84 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*