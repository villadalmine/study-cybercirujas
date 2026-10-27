# Community 215

> 20 nodes · cohesion 0.15

## Key Concepts

- **ratelimit.py** (10 connections) — `teach/core/ratelimit.py`
- **Limiter** (7 connections) — `teach/core/ratelimit.py`
- **ClientIdentityTests** (6 connections) — `tests/test_catalog_cache_ratelimit.py`
- **client_id()** (6 connections) — `teach/core/ratelimit.py`
- **_Req** (5 connections) — `tests/test_catalog_cache_ratelimit.py`
- **threading** (4 connections)
- **RateLimitTests** (3 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.hit()** (3 connections) — `teach/core/ratelimit.py`
- **.test_extra_trusted_hops_and_missing_header()** (3 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.test_peer_is_used_unless_the_proxy_is_trusted()** (3 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.test_trusted_proxy_uses_the_right_most_entry()** (3 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.test_limiter_window()** (3 connections) — `tests/test_catalog_cache_ratelimit.py`
- **_int_env()** (2 connections) — `teach/core/ratelimit.py`
- **.test_different_visitors_behind_the_proxy_have_their_own_bucket()** (2 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.test_rotating_a_spoofed_header_does_not_escape_the_limit()** (2 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.test_search_endpoint_returns_429()** (2 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.__init__()** (1 connections) — `teach/core/ratelimit.py`
- **.__init__()** (1 connections) — `tests/test_catalog_cache_ratelimit.py`
- **A small in-process rate limiter for the public API (sliding window, per…** (1 connections) — `teach/core/ratelimit.py`
- **0 if the request is allowed, else the seconds to wait.** (1 connections) — `teach/core/ratelimit.py`

## Relationships

- [Community 43](Community_43.md) (5 shared connections)
- [Community 107](Community_107.md) (2 shared connections)
- [Community 50](Community_50.md) (1 shared connections)
- [Community 147](Community_147.md) (1 shared connections)
- [Community 135](Community_135.md) (1 shared connections)
- [Community 266](Community_266.md) (1 shared connections)
- [Community 12](Community_12.md) (1 shared connections)

## Source Files

- `teach/core/ratelimit.py`
- `tests/test_catalog_cache_ratelimit.py`

## Audit Trail

- EXTRACTED: 39 (98%)
- INFERRED: 1 (2%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*