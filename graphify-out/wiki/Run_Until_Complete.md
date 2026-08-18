# Run Until Complete

> 5 nodes · cohesion 0.50

## Key Concepts

- **topics_per_run()** (6 connections) — `teach/core/pipeline.py`
- **run_until_complete.py** (4 connections) — `scripts/run_until_complete.py`
- **main()** (3 connections) — `scripts/run_until_complete.py`
- **pending()** (2 connections) — `scripts/run_until_complete.py`
- **Maximum topics one invocation may generate. 0 means unbounded, which is…** (1 connections) — `teach/core/pipeline.py`

## Relationships

- [Pipeline Config & Quality](Pipeline_Config_&_Quality.md) (3 shared connections)
- [Content Corruption Audit](Content_Corruption_Audit.md) (2 shared connections)
- [Batch Generation Runner](Batch_Generation_Runner.md) (1 shared connections)

## Source Files

- `scripts/run_until_complete.py`
- `teach/core/pipeline.py`

## Audit Trail

- EXTRACTED: 11 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*