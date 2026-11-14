# Community 107

> 26 nodes · cohesion 0.09

## Key Concepts

- **login()** (6 connections) — `teach/api.py`
- **has_subscription()** (6 connections) — `teach/core/auth.py`
- **post_bot_used()** (5 connections) — `teach/api.py`
- **rate_limit()** (5 connections) — `teach/api.py`
- **authenticate()** (5 connections) — `teach/core/auth.py`
- **auth.py** (5 connections) — `teach/core/auth.py`
- **BotUsage** (4 connections) — `teach/api.py`
- **Request** (4 connections)
- **Architecture — 3 Components** (4 connections) — `docs/ORIGINAL_DESIGN.md`
- **LoginBody** (3 connections) — `teach/api.py`
- **logout()** (3 connections) — `teach/api.py`
- **me()** (3 connections) — `teach/api.py`
- **post** (3 connections)
- **Platform (Long-Term Roadmap, see docs/ORIGINAL_DESIGN.md)** (3 connections) — `docs/BACKLOG.md`
- **3. Web: Public Landing + Paid Study Zone** (3 connections) — `docs/ORIGINAL_DESIGN.md`
- **require_user()** (2 connections) — `teach/api.py`
- **BaseModel** (2 connections)
- **1. Catalog Tracker (Scraper — nothing is static)** (2 connections) — `docs/ORIGINAL_DESIGN.md`
- **middleware** (1 connections)
- **2. Generator (AI, on-demand)** (1 connections) — `docs/ORIGINAL_DESIGN.md`
- **Per-client request budget on /api (in-process, per worker; see…** (1 connections) — `teach/api.py`
- **What the page reports after an answer. Six closed-set fields, no more. Pydantic…** (1 connections) — `teach/api.py`
- **Count one bot answer, anonymously and only if the student left it on. The page…** (1 connections) — `teach/api.py`
- **Authentication — a minimal interface so real users/OIDC can be plugged in later…** (1 connections) — `teach/core/auth.py`
- **Always denies. Real auth pending (OIDC/social login).** (1 connections) — `teach/core/auth.py`
- *... and 1 more nodes in this community*

## Relationships

- [Community 125](Community_125.md) (10 shared connections)
- [Community 215](Community_215.md) (1 shared connections)
- [Community 170](Community_170.md) (1 shared connections)
- [Community 43](Community_43.md) (1 shared connections)
- [Community 209](Community_209.md) (1 shared connections)
- [Community 28](Community_28.md) (1 shared connections)
- [Community 157](Community_157.md) (1 shared connections)

## Source Files

- `docs/BACKLOG.md`
- `docs/ORIGINAL_DESIGN.md`
- `teach/api.py`
- `teach/core/auth.py`

## Audit Trail

- EXTRACTED: 41 (89%)
- INFERRED: 5 (11%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*