# Community 10

> 14 nodes · cohesion 0.24

## Key Concepts

- **StaleCycleTest** (10 connections) — `tests/test_stale_cycle.py`
- **get_topic()** (10 connections) — `teach/core/certs.py`
- **._outdated()** (7 connections) — `tests/test_stale_cycle.py`
- **._regenerate()** (5 connections) — `tests/test_stale_cycle.py`
- **.test_cycle_closes_when_none_are_left()** (5 connections) — `tests/test_stale_cycle.py`
- **.test_regenerating_default_does_not_release_the_rest()** (5 connections) — `tests/test_stale_cycle.py`
- **.test_unreadable_meta_counts_as_outdated()** (5 connections) — `tests/test_stale_cycle.py`
- **.test_without_a_timestamp_nothing_is_outdated()** (4 connections) — `tests/test_stale_cycle.py`
- **.test_content_older_than_the_change_is_flagged()** (2 connections) — `tests/test_stale_cycle.py`
- **.setUp()** (1 connections) — `tests/test_stale_cycle.py`
- **.tearDown()** (1 connections) — `tests/test_stale_cycle.py`
- **A topic that never changed reports no outdated languages, however old its…** (1 connections) — `tests/test_stale_cycle.py`
- **When in doubt, regenerate: if freshness cannot be proven, it is not assumed.** (1 connections) — `tests/test_stale_cycle.py`
- **The case that drove the design: rebuilding Spanish cannot mark the topic…** (1 connections) — `tests/test_stale_cycle.py`

## Relationships

- [Community 131](Community_131.md) (5 shared connections)
- [Community 167](Community_167.md) (2 shared connections)
- [Community 263](Community_263.md) (2 shared connections)
- [Community 43](Community_43.md) (1 shared connections)
- [Community 103](Community_103.md) (1 shared connections)
- [Community 7](Community_7.md) (1 shared connections)
- [Community 8](Community_8.md) (1 shared connections)
- [Community 74](Community_74.md) (1 shared connections)

## Source Files

- `teach/core/certs.py`
- `tests/test_stale_cycle.py`

## Audit Trail

- EXTRACTED: 36 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*