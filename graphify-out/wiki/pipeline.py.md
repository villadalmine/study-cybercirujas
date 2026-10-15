# pipeline.py

> 23 nodes · cohesion 0.13

## Key Concepts

- **pipeline.py** (39 connections) — `teach/core/pipeline.py`
- **load()** (17 connections) — `teach/core/pipeline.py`
- **budget()** (8 connections) — `teach/core/pipeline.py`
- **milestone()** (7 connections) — `teach/core/pipeline.py`
- **milestone_targets()** (7 connections) — `teach/core/pipeline.py`
- **certs()** (6 connections) — `teach/core/pipeline.py`
- **is_fatal()** (6 connections) — `teach/core/pipeline.py`
- **topics_per_run()** (6 connections) — `teach/core/pipeline.py`
- **in_milestone()** (4 connections) — `teach/core/pipeline.py`
- **PipelineError** (3 connections) — `teach/core/pipeline.py`
- **default_languages()** (3 connections) — `teach/core/pipeline.py`
- **is_retryable()** (3 connections) — `teach/core/pipeline.py`
- **on_demand_languages()** (2 connections) — `teach/core/pipeline.py`
- **path_video_languages()** (2 connections) — `teach/core/pipeline.py`
- **RuntimeError** (1 connections)
- **Path** (1 connections)
- **Reader for pipeline.yaml — the declarative definition of what the content…** (1 connections) — `teach/core/pipeline.py`
- **Is this cert/language part of the declared goal?** (1 connections) — `teach/core/pipeline.py`
- **Certifications declared in the pipeline, as {cert_id: config}.** (1 connections) — `teach/core/pipeline.py`
- **Maximum topics one invocation may generate. 0 means unbounded, which is…** (1 connections) — `teach/core/pipeline.py`
- **True for errors where retrying cannot help (quota exhausted), as opposed to…** (1 connections) — `teach/core/pipeline.py`
- **The bounded goal the unattended timer is working toward, or {}. The timer used…** (1 connections) — `teach/core/pipeline.py`
- **[(cert, [langs])] for the milestone, or None when none is declared. None and []…** (1 connections) — `teach/core/pipeline.py`

## Relationships

- [main](main.md) (9 shared connections)
- [steer.py](steer.py.md) (9 shared connections)
- [fix_corrupted_content.py](fix_corrupted_content.py.md) (7 shared connections)
- [Community 7](Community_7.md) (5 shared connections)
- [Community 22](Community_22.md) (5 shared connections)
- [Community 54](Community_54.md) (3 shared connections)
- [publish_if_complete.py](publish_if_complete.py.md) (2 shared connections)
- [Community 36](Community_36.md) (2 shared connections)
- [Community 13](Community_13.md) (2 shared connections)
- [Community 89](Community_89.md) (2 shared connections)
- [Community 43](Community_43.md) (2 shared connections)
- [Agent Synchronization & Idea Queue (AGENTS_SYNC.md)](Agent_Synchronization_&_Idea_Queue_AGENTS_SYNC.md.md) (1 shared connections)

## Source Files

- `teach/core/pipeline.py`

## Audit Trail

- EXTRACTED: 87 (99%)
- INFERRED: 1 (1%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*