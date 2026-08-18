# Batch Generation Runner

> 13 nodes · cohesion 0.23

## Key Concepts

- **main()** (9 connections) — `scripts/run_batch.py`
- **run_batch.py** (8 connections) — `scripts/run_batch.py`
- **generate_with_retries()** (7 connections) — `scripts/run_batch.py`
- **me()** (6 connections) — `teach/core/pipeline.py`
- **mine()** (5 connections) — `teach/core/pipeline.py`
- **owner()** (5 connections) — `teach/core/pipeline.py`
- **pending()** (4 connections) — `scripts/run_batch.py`
- **generate()** (2 connections) — `scripts/run_batch.py`
- **_sort_key()** (2 connections) — `scripts/run_batch.py`
- **Topics still missing for this combination, in syllabus order.** (1 connections) — `scripts/run_batch.py`
- **One topic, start to finish. Returns done | failed | skipped | fatal. The claim…** (1 connections) — `scripts/run_batch.py`
- **Which agent takes this certification by default; 'any' if unassigned. NOT a…** (1 connections) — `teach/core/pipeline.py`
- **This agent's name, from TEACH_AGENT. Unset means 'claude' — the historical…** (1 connections) — `teach/core/pipeline.py`

## Relationships

- [Pipeline Config & Quality](Pipeline_Config_&_Quality.md) (8 shared connections)
- [Content Corruption Audit](Content_Corruption_Audit.md) (3 shared connections)
- [Provenance & Usage Reports](Provenance_&_Usage_Reports.md) (3 shared connections)
- [Run Until Complete](Run_Until_Complete.md) (1 shared connections)
- [Pipeline Steering Tool](Pipeline_Steering_Tool.md) (1 shared connections)

## Source Files

- `scripts/run_batch.py`
- `teach/core/pipeline.py`

## Audit Trail

- EXTRACTED: 33 (97%)
- INFERRED: 1 (3%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*