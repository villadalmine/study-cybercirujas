# StoredShapeTests

> 18 nodes · cohesion 0.20

## Key Concepts

- **StoredShapeTests** (13 connections) — `tests/test_bot_stats.py`
- **record()** (13 connections) — `teach/core/bot_stats.py`
- **load()** (10 connections) — `teach/core/bot_stats.py`
- **.test_the_file_does_not_grow_with_the_number_of_answers()** (5 connections) — `tests/test_bot_stats.py`
- **._shape()** (3 connections) — `tests/test_bot_stats.py`
- **._stored()** (3 connections) — `tests/test_bot_stats.py`
- **.test_a_corrupt_file_does_not_take_the_endpoint_down()** (3 connections) — `tests/test_bot_stats.py`
- **.test_no_timestamp_is_written_per_request()** (3 connections) — `tests/test_bot_stats.py`
- **.test_since_is_the_first_day_and_never_moves()** (3 connections) — `tests/test_bot_stats.py`
- **.test_the_breakdown_counts_each_characteristic_independently()** (3 connections) — `tests/test_bot_stats.py`
- **_blank()** (2 connections) — `teach/core/bot_stats.py`
- **.test_a_refused_event_writes_nothing_at_all()** (2 connections) — `tests/test_bot_stats.py`
- **.test_an_unwritable_path_is_swallowed()** (2 connections) — `tests/test_bot_stats.py`
- **.setUp()** (1 connections) — `tests/test_bot_stats.py`
- **.tearDown()** (1 connections) — `tests/test_bot_stats.py`
- **Count one answer. Returns whether it was accepted. Never raises. `today` is the…** (1 connections) — `teach/core/bot_stats.py`
- **Counters, never rows — the property the whole design rests on.** (1 connections) — `tests/test_bot_stats.py`
- **The file's structure with every count blanked — what must not grow.** (1 connections) — `tests/test_bot_stats.py`

## Relationships

- [Community 43](Community_43.md) (4 shared connections)
- [Community 50](Community_50.md) (3 shared connections)
- [Community 125](Community_125.md) (1 shared connections)
- [Community 107](Community_107.md) (1 shared connections)
- [Community 221](Community_221.md) (1 shared connections)

## Source Files

- `teach/core/bot_stats.py`
- `tests/test_bot_stats.py`

## Audit Trail

- EXTRACTED: 40 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*