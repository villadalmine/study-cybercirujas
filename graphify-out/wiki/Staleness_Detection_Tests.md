# Staleness Detection Tests

> 23 nodes · cohesion 0.13

## Key Concepts

- **StaleCycleTest** (10 connections) — `tests/test_stale_cycle.py`
- **SnapshotStatusTest** (6 connections) — `tests/test_stale_cycle.py`
- **._outdated()** (6 connections) — `tests/test_stale_cycle.py`
- **test_stale_cycle.py** (5 connections) — `tests/test_stale_cycle.py`
- **._apply()** (4 connections) — `tests/test_stale_cycle.py`
- **._regenerate()** (4 connections) — `tests/test_stale_cycle.py`
- **.test_regenerating_default_does_not_release_the_rest()** (4 connections) — `tests/test_stale_cycle.py`
- **.test_unreadable_meta_counts_as_outdated()** (4 connections) — `tests/test_stale_cycle.py`
- **.test_edited_is_never_overwritten()** (3 connections) — `tests/test_stale_cycle.py`
- **.test_weight_also_invalidates()** (3 connections) — `tests/test_stale_cycle.py`
- **.test_cycle_closes_when_none_are_left()** (3 connections) — `tests/test_stale_cycle.py`
- **.test_without_a_timestamp_nothing_is_outdated()** (3 connections) — `tests/test_stale_cycle.py`
- **.test_classifies_new_changed_and_unchanged()** (2 connections) — `tests/test_stale_cycle.py`
- **.test_content_older_than_the_change_is_flagged()** (2 connections) — `tests/test_stale_cycle.py`
- **Invalidation cycle triggered by a syllabus change. Tested because the delicate…** (1 connections) — `tests/test_stale_cycle.py`
- **A topic that never changed reports no outdated languages, however old its…** (1 connections) — `tests/test_stale_cycle.py`
- **When in doubt, regenerate: if freshness cannot be proven, it is not assumed.** (1 connections) — `tests/test_stale_cycle.py`
- **Change detection in the snapshot, touching no disk and spending no budget.** (1 connections) — `tests/test_stale_cycle.py`
- **Weight sets the depth requested from the model, so changing it changes the…** (1 connections) — `tests/test_stale_cycle.py`
- **Hand-enriched content is preserved and reported separately so a person decides,…** (1 connections) — `tests/test_stale_cycle.py`
- **The case that drove the design: rebuilding Spanish cannot mark the topic…** (1 connections) — `tests/test_stale_cycle.py`
- **.setUp()** (1 connections) — `tests/test_stale_cycle.py`
- **.tearDown()** (1 connections) — `tests/test_stale_cycle.py`

## Relationships

- [Syllabus Snapshot Checks](Syllabus_Snapshot_Checks.md) (1 shared connections)
- [Topic Content Generation](Topic_Content_Generation.md) (1 shared connections)

## Source Files

- `tests/test_stale_cycle.py`

## Audit Trail

- EXTRACTED: 35 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*