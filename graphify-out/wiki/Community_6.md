# Community 6

> 21 nodes · cohesion 0.13

## Key Concepts

- **claim()** (13 connections) — `teach/core/claims.py`
- **ClaimTest** (9 connections) — `tests/test_claims.py`
- **is_claimed()** (9 connections) — `teach/core/claims.py`
- **_try_lock()** (4 connections) — `teach/core/claims.py`
- **.test_a_claim_does_not_survive_the_process_that_held_it()** (4 connections) — `tests/test_claims.py`
- **_try_claim()** (4 connections) — `tests/test_claims.py`
- **_path()** (3 connections) — `teach/core/claims.py`
- **.test_a_claim_is_released_when_the_block_exits()** (3 connections) — `tests/test_claims.py`
- **.test_a_different_topic_is_granted_at_the_same_time()** (3 connections) — `tests/test_claims.py`
- **.test_active_lists_what_is_being_worked_on()** (3 connections) — `tests/test_claims.py`
- **_unlock()** (2 connections) — `teach/core/claims.py`
- **.test_a_free_topic_is_granted()** (2 connections) — `tests/test_claims.py`
- **.test_the_same_topic_is_refused_while_held()** (2 connections) — `tests/test_claims.py`
- **.setUp()** (1 connections) — `tests/test_claims.py`
- **.tearDown()** (1 connections) — `tests/test_claims.py`
- **Non-blocking exclusive lock. False if someone else holds it.** (1 connections) — `teach/core/claims.py`
- **Claim one (cert, topic, lang). Yields False if someone else holds it. Never…** (1 connections) — `teach/core/claims.py`
- **Whether someone is working on it right now. Advisory: a topic can be claimed…** (1 connections) — `teach/core/claims.py`
- **Claim from a separate PROCESS: flock is per open file description, so a second…** (1 connections) — `tests/test_claims.py`
- **The whole reason this is per topic and not global.** (1 connections) — `tests/test_claims.py`
- **A lock file checked with exists() would strand a topic forever after a crash.…** (1 connections) — `tests/test_claims.py`

## Relationships

- [fix_corrupted_content.py](fix_corrupted_content.py.md) (8 shared connections)
- [Community 43](Community_43.md) (3 shared connections)
- [Community 29](Community_29.md) (1 shared connections)
- [Community 50](Community_50.md) (1 shared connections)

## Source Files

- `teach/core/claims.py`
- `tests/test_claims.py`

## Audit Trail

- EXTRACTED: 40 (98%)
- INFERRED: 1 (2%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*