# main

> 20 nodes · cohesion 0.17

## Key Concepts

- **pipeline.py** (39 connections) — `teach/core/pipeline.py`
- **run_batch.py** (15 connections) — `scripts/run_batch.py`
- **main()** (11 connections) — `scripts/run_batch.py`
- **generate_with_retries()** (8 connections) — `scripts/run_batch.py`
- **budget()** (8 connections) — `teach/core/pipeline.py`
- **is_fatal()** (6 connections) — `teach/core/pipeline.py`
- **topics_per_run()** (6 connections) — `teach/core/pipeline.py`
- **pending()** (5 connections) — `scripts/run_batch.py`
- **mine()** (5 connections) — `teach/core/pipeline.py`
- **owner()** (5 connections) — `teach/core/pipeline.py`
- **generate()** (3 connections) — `scripts/run_batch.py`
- **is_retryable()** (3 connections) — `teach/core/pipeline.py`
- **_sort_key()** (2 connections) — `scripts/run_batch.py`
- **Generate a bounded batch of topics, honouring the budget in pipeline.yaml.…** (1 connections) — `scripts/run_batch.py`
- **Topics still missing for this combination, in syllabus order.** (1 connections) — `scripts/run_batch.py`
- **One topic, start to finish. Returns done | failed | skipped | fatal. The claim…** (1 connections) — `scripts/run_batch.py`
- **Reader for pipeline.yaml — the declarative definition of what the content…** (1 connections) — `teach/core/pipeline.py`
- **Which agent takes this certification by default; 'any' if unassigned. NOT a…** (1 connections) — `teach/core/pipeline.py`
- **Maximum topics one invocation may generate. 0 means unbounded, which is…** (1 connections) — `teach/core/pipeline.py`
- **True for errors where retrying cannot help (quota exhausted), as opposed to…** (1 connections) — `teach/core/pipeline.py`

## Relationships

- [Community 50](Community_50.md) (14 shared connections)
- [fix_corrupted_content.py](fix_corrupted_content.py.md) (7 shared connections)
- [Community 43](Community_43.md) (6 shared connections)
- [Community 61](Community_61.md) (3 shared connections)
- [Community 6](Community_6.md) (3 shared connections)
- [Community 7](Community_7.md) (3 shared connections)
- [Community 56](Community_56.md) (3 shared connections)
- [Community 69](Community_69.md) (2 shared connections)
- [Community 89](Community_89.md) (2 shared connections)
- [Community 36](Community_36.md) (2 shared connections)
- [Community 140](Community_140.md) (2 shared connections)
- [Community 22](Community_22.md) (2 shared connections)

## Source Files

- `scripts/run_batch.py`
- `teach/core/pipeline.py`

## Audit Trail

- EXTRACTED: 89 (99%)
- INFERRED: 1 (1%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*