# Community 6

> 28 nodes · cohesion 0.11

## Key Concepts

- **claims.py** (20 connections) — `teach/core/claims.py`
- **claim()** (13 connections) — `teach/core/claims.py`
- **ClaimTest** (9 connections) — `tests/test_claims.py`
- **active()** (9 connections) — `teach/core/claims.py`
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
- **collections_abc** (2 connections)
- **.setUp()** (1 connections) — `tests/test_claims.py`
- **.tearDown()** (1 connections) — `tests/test_claims.py`
- **Per-topic claims, so several agents can work at once without colliding. The…** (1 connections) — `teach/core/claims.py`
- **What is being worked on right now, across every agent on this machine.** (1 connections) — `teach/core/claims.py`
- **Non-blocking exclusive lock. False if someone else holds it.** (1 connections) — `teach/core/claims.py`
- **Claim one (cert, topic, lang). Yields False if someone else holds it. Never…** (1 connections) — `teach/core/claims.py`
- **Whether someone is working on it right now. Advisory: a topic can be claimed…** (1 connections) — `teach/core/claims.py`
- **Claim from a separate PROCESS: flock is per open file description, so a second…** (1 connections) — `tests/test_claims.py`
- **The whole reason this is per topic and not global.** (1 connections) — `tests/test_claims.py`
- *... and 3 more nodes in this community*

## Relationships

- [Community 43](Community_43.md) (7 shared connections)
- [Community 74](Community_74.md) (3 shared connections)
- [Community 36](Community_36.md) (2 shared connections)
- [Community 112](Community_112.md) (2 shared connections)
- [Community 89](Community_89.md) (2 shared connections)
- [Community 49](Community_49.md) (2 shared connections)
- [Community 253](Community_253.md) (2 shared connections)
- [Community 126](Community_126.md) (1 shared connections)
- [Community 50](Community_50.md) (1 shared connections)

## Source Files

- `teach/core/claims.py`
- `tests/test_claims.py`

## Audit Trail

- EXTRACTED: 61 (97%)
- INFERRED: 2 (3%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*