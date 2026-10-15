# main

> 14 nodes · cohesion 0.21

## Key Concepts

- **run_batch.py** (15 connections) — `scripts/run_batch.py`
- **main()** (11 connections) — `scripts/run_batch.py`
- **generate_with_retries()** (8 connections) — `scripts/run_batch.py`
- **me()** (6 connections) — `teach/core/pipeline.py`
- **pending()** (5 connections) — `scripts/run_batch.py`
- **mine()** (5 connections) — `teach/core/pipeline.py`
- **owner()** (5 connections) — `teach/core/pipeline.py`
- **generate()** (3 connections) — `scripts/run_batch.py`
- **_sort_key()** (2 connections) — `scripts/run_batch.py`
- **Generate a bounded batch of topics, honouring the budget in pipeline.yaml.…** (1 connections) — `scripts/run_batch.py`
- **Topics still missing for this combination, in syllabus order.** (1 connections) — `scripts/run_batch.py`
- **One topic, start to finish. Returns done | failed | skipped | fatal. The claim…** (1 connections) — `scripts/run_batch.py`
- **Which agent takes this certification by default; 'any' if unassigned. NOT a…** (1 connections) — `teach/core/pipeline.py`
- **This agent's name, from TEACH_AGENT. Unset means 'claude' — the historical…** (1 connections) — `teach/core/pipeline.py`

## Relationships

- [pipeline.py](pipeline.py.md) (9 shared connections)
- [fix_corrupted_content.py](fix_corrupted_content.py.md) (4 shared connections)
- [Community 61](Community_61.md) (3 shared connections)
- [Community 6](Community_6.md) (3 shared connections)
- [Community 43](Community_43.md) (3 shared connections)
- [Community 69](Community_69.md) (2 shared connections)
- [Community 89](Community_89.md) (2 shared connections)
- [steer.py](steer.py.md) (1 shared connections)

## Source Files

- `scripts/run_batch.py`
- `teach/core/pipeline.py`

## Audit Trail

- EXTRACTED: 45 (98%)
- INFERRED: 1 (2%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*