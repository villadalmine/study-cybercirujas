## What and why

Fixes the default reclaim policy in CKA 1.1 (English).

## Kind

content — cka / 1.1 / en
- Site: image-rebuild

## Provenance

- Author: ai
- Backend: claude
- Model: claude
- Date: 2026-07-16
- Cost: none
- Official source: https://kubernetes.io/docs/concepts/storage/persistent-volumes/

## Evidence

```
scripts/check_provenance.py   -> OK
```

### Where it ran

- CI: https://github.com/villadalmine/study-cybercirujas/actions/runs/123 on the head commit

## Authorship

| Role | Who | What | Link |
| :--- | :--- | :--- | :--- |
| Author | AI: content-agent · claude | commits `aaaaaaa..bbbbbbb` | session link |
| Reviewer | Copilot code review | head `bbbbbbb` — 1 finding | review 1 |
| Approval and merge | maintainer (human) | pending | — |

### Findings ledger

| # | Found by | Head | Severity | Finding | Fixed by | Fix | Verified by | Status |
| :- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | Copilot r1 | `aaaaaaa` | low | typo | content-agent / claude | `bbbbbbb` | pending | fixed |

## How to test it from a clean clone

```bash
make setup && make test
```

## Risk and rollback

Content only; revert the PR.

## Depends on

nothing
