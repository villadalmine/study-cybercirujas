# Community 215

> 9 nodes · cohesion 0.28

## Key Concepts

- **Limiter** (7 connections) — `teach/core/ratelimit.py`
- **RateLimitTests** (3 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.hit()** (3 connections) — `teach/core/ratelimit.py`
- **.test_limiter_window()** (3 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.test_different_visitors_behind_the_proxy_have_their_own_bucket()** (2 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.test_rotating_a_spoofed_header_does_not_escape_the_limit()** (2 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.test_search_endpoint_returns_429()** (2 connections) — `tests/test_catalog_cache_ratelimit.py`
- **.__init__()** (1 connections) — `teach/core/ratelimit.py`
- **0 if the request is allowed, else the seconds to wait.** (1 connections) — `teach/core/ratelimit.py`

## Relationships

- [Community 157](Community_157.md) (3 shared connections)
- [Community 43](Community_43.md) (1 shared connections)

## Source Files

- `teach/core/ratelimit.py`
- `tests/test_catalog_cache_ratelimit.py`

## Audit Trail

- EXTRACTED: 13 (93%)
- INFERRED: 1 (7%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*