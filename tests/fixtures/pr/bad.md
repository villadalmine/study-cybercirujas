## What and why

Fixes the default reclaim policy in CKA 1.1 (English).

## Kind

content — cka / 1.1 / en
- Site: image-rebuild

## Provenance

- Author: ai
- Backend: claude
- Model: claude-opus-5-5
- Date: 2026-07-16
- Cost: none
- Official source: https://kubernetes.io/docs/concepts/storage/persistent-volumes/

## Evidence

```
scripts/check_provenance.py   -> OK
```

### Where it ran

- CI: https://github.com/villadalmine/study-cybercirujas/actions/runs/123 on the head commit

## How to test it from a clean clone

```bash
make setup && make test
```

## Risk and rollback


## Depends on

nothing
