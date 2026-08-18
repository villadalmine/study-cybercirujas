# Web API & Auth

> 26 nodes · cohesion 0.11

## Key Concepts

- **api.py** (24 connections) — `teach/api.py`
- **login()** (6 connections) — `teach/api.py`
- **_video_info()** (5 connections) — `teach/api.py`
- **has_subscription()** (5 connections) — `teach/core/auth.py`
- **Request** (4 connections)
- **get_cert_video()** (4 connections) — `teach/api.py`
- **get_path_video()** (4 connections) — `teach/api.py`
- **require_subscriber()** (4 connections) — `teach/api.py`
- **auth.py** (4 connections) — `teach/core/auth.py`
- **index()** (3 connections) — `teach/api.py`
- **LoginBody** (3 connections) — `teach/api.py`
- **logout()** (3 connections) — `teach/api.py`
- **me()** (3 connections) — `teach/api.py`
- **require_user()** (3 connections) — `teach/api.py`
- **authenticate()** (3 connections) — `teach/core/auth.py`
- **get_langs()** (2 connections) — `teach/api.py`
- **post** (2 connections)
- **BaseModel** (1 connections)
- **FileResponse** (1 connections)
- **Platform API. Public (no login): catalog, syllabi and paths — the landing page…** (1 connections) — `teach/api.py`
- **Info about a video (path or cert) if it has been generated: URL of the mp4…** (1 connections) — `teach/api.py`
- **A path's video (if it has been generated).** (1 connections) — `teach/api.py`
- **A single certification's video (if it has been generated).** (1 connections) — `teach/api.py`
- **Authentication — a minimal interface so real users/OIDC can be plugged in later…** (1 connections) — `teach/core/auth.py`
- **Always denies. Real auth pending (OIDC/social login).** (1 connections) — `teach/core/auth.py`
- *... and 1 more nodes in this community*

## Relationships

- [Syllabus Snapshot Checks](Syllabus_Snapshot_Checks.md) (9 shared connections)
- [Topic Content Generation](Topic_Content_Generation.md) (6 shared connections)
- [Environment Loading](Environment_Loading.md) (1 shared connections)
- [Lab Lifecycle Management](Lab_Lifecycle_Management.md) (1 shared connections)

## Source Files

- `teach/api.py`
- `teach/core/auth.py`

## Audit Trail

- EXTRACTED: 54 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*