# Environment Loading

> 16 nodes · cohesion 0.19

## Key Concepts

- **core/__init__.py** (10 connections) — `teach/core/__init__.py`
- **load_env()** (8 connections) — `teach/core/__init__.py`
- **EnvScopeTests** (8 connections) — `tests/test_env_scope.py`
- **._write()** (5 connections) — `tests/test_env_scope.py`
- **test_env_scope.py** (3 connections) — `tests/test_env_scope.py`
- **.test_a_missing_file_is_not_an_error()** (3 connections) — `tests/test_env_scope.py`
- **.test_loads_translation_variables()** (3 connections) — `tests/test_env_scope.py`
- **.test_refuses_to_change_the_authoring_backend()** (3 connections) — `tests/test_env_scope.py`
- **.test_the_real_environment_wins()** (3 connections) — `tests/test_env_scope.py`
- **Path** (2 connections)
- **Path** (1 connections)
- **Loads `.env` from the repository root, once, before anything reads a variable.…** (1 connections) — `teach/core/__init__.py`
- **Read KEY=VALUE lines into the environment. Returns how many were set.…** (1 connections) — `teach/core/__init__.py`
- **.tearDown()** (1 connections) — `tests/test_env_scope.py`
- **.test_authoring_backend_is_not_in_the_allowed_set()** (1 connections) — `tests/test_env_scope.py`
- **`.env` may configure translation and nothing else. It exists for one purpose —…** (1 connections) — `tests/test_env_scope.py`

## Relationships

- [Topic Content Generation](Topic_Content_Generation.md) (2 shared connections)
- [Web API & Auth](Web_API_&_Auth.md) (1 shared connections)
- [CLI Commands](CLI_Commands.md) (1 shared connections)
- [Lab Lifecycle Management](Lab_Lifecycle_Management.md) (1 shared connections)
- [Translation Study & Quality](Translation_Study_&_Quality.md) (1 shared connections)
- [Syllabus Snapshot Checks](Syllabus_Snapshot_Checks.md) (1 shared connections)
- [Video Slide Rendering](Video_Slide_Rendering.md) (1 shared connections)

## Source Files

- `teach/core/__init__.py`
- `tests/test_env_scope.py`

## Audit Trail

- EXTRACTED: 31 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*