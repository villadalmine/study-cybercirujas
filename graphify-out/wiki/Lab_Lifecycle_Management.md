# Lab Lifecycle Management

> 24 nodes · cohesion 0.23

## Key Concepts

- **labs.py** (24 connections) — `teach/core/labs.py`
- **down()** (10 connections) — `teach/core/labs.py`
- **up()** (10 connections) — `teach/core/labs.py`
- **status()** (9 connections) — `teach/core/labs.py`
- **_run()** (8 connections) — `teach/core/labs.py`
- **LabError** (7 connections) — `teach/core/labs.py`
- **Path** (7 connections)
- **lab_dir()** (6 connections) — `teach/core/labs.py`
- **_needs_cluster()** (6 connections) — `teach/core/labs.py`
- **_up_cluster()** (6 connections) — `teach/core/labs.py`
- **_up_container()** (6 connections) — `teach/core/labs.py`
- **_load_spec()** (5 connections) — `teach/core/labs.py`
- **_terraform()** (5 connections) — `teach/core/labs.py`
- **_write_status()** (5 connections) — `teach/core/labs.py`
- **_lab_name()** (4 connections) — `teach/core/labs.py`
- **_require()** (4 connections) — `teach/core/labs.py`
- **_down_cluster()** (3 connections) — `teach/core/labs.py`
- **_down_container()** (3 connections) — `teach/core/labs.py`
- **_status_cluster()** (3 connections) — `teach/core/labs.py`
- **_status_container()** (3 connections) — `teach/core/labs.py`
- **CompletedProcess** (1 connections)
- **Exception** (1 connections)
- **Lab execution — v1 using local subprocesses. Two providers: terraform Lab IaC…** (1 connections) — `teach/core/labs.py`
- **CKA/CKAD/CKS/KCNA labs run against a real Kubernetes cluster (kubectl); LPI…** (1 connections) — `teach/core/labs.py`

## Relationships

- [CLI Commands](CLI_Commands.md) (4 shared connections)
- [Topic Content Generation](Topic_Content_Generation.md) (3 shared connections)
- [Spend Metrics & Quota](Spend_Metrics_&_Quota.md) (1 shared connections)
- [Environment Loading](Environment_Loading.md) (1 shared connections)
- [Web API & Auth](Web_API_&_Auth.md) (1 shared connections)

## Source Files

- `teach/core/labs.py`

## Audit Trail

- EXTRACTED: 74 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*