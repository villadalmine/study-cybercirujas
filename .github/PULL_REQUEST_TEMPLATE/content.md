<!-- Title: a Conventional Commit, e.g. "fix(cka): PV reclaim policy default in 1.3". English is the standard;
     a description in your own language is welcome too. Every section below is
     required — scripts/check_pr.py fails the PR if one is missing or empty. -->

## What and why

<!-- One concern per PR. Link the issue or RFC it answers. -->

## Kind

content — certification / topic / language: 
- Site: none | image-rebuild  <!-- computed by scripts/check_pr.py from the changed files; see CONTRIBUTING → Merging and deploying the site -->

## Provenance

<!-- Who or what wrote it. For AI, these must match meta.yaml of every topic you touch. -->
- Author: human | ai  <!-- 'ai' also when an AI helped write it; then Backend and Model are required -->
- Backend: none | claude | litellm | gemini | codex | custom
- Model: none | <exact model id from meta.yaml>
- Date: YYYY-MM-DD
- Cost: <!-- e.g. "subscription quota, 1 window" / "$0.07 API" / "none" -->
- Official source: <!-- vendor/project documentation this is based on -->

## Evidence

<!-- Commands you ran and their short output. -->
```
make test
...
scripts/check_provenance.py
make quality CERT=<cert>     # floor report + rescore; commit the meta.yaml it changes
```

### Where it ran

<!-- The CI run on this PR's HEAD commit, green: github.com/villadalmine/study-cybercirujas/actions/runs/<id>.
     CI posts a 'where-it-ran' comment with this line ready to paste after each push; a new push
     makes the old link stale and pr-format fails until it is updated. Add the machine or local
     environment too if you ran anything there. -->
- CI: 
- Local: 

### Known gaps

<!-- What this evidence does NOT cover. Always present; 'none' is a claim, not a default. -->

## Authorship

<!-- Who did what, updated on every review round (CONTRIBUTING → Authorship). The Author
     row starts with "Human:" or "AI:" and agrees with Provenance; for AI it names the
     agent and the model. One Reviewer row per review (Copilot, revisor-pr, a person). -->
| Role | Who | What | Link |
| :--- | :--- | :--- | :--- |
| Author | Human: @you · or · AI: <agent> · <model id> | commits `<first>..<last>` | |
| Reviewer | | head `<sha>` — result | |
| Approval and merge | maintainer (human) | pending | |

### Findings ledger

<!-- One row per finding, from any reviewer, CI or a person. Status: fixed |
     rejected — <reason> | open. "Verified by" is who confirmed the fix next round. -->
| # | Found by | Head | Severity | Finding | Fixed by | Fix | Verified by | Status |
| :- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |

## How to test it from a clean clone

```bash
git clone https://github.com/villadalmine/study-cybercirujas.git && cd study-cybercirujas
git fetch origin pull/<N>/head:pr && git checkout pr
make setup && make test
scripts/check_provenance.py && make quality CERT=<cert> && .venv/bin/python3 scripts/quality_score.py --check
```

## Risk and rollback

- [ ] Docs consistent (`make check-docs` green) / code graph regenerated (`make graph`) or why not
- [ ] Commits signed off (DCO): `git commit -s`; fix a missing one with `git rebase --signoff origin/main`

<!-- What could break, for whom, and how to undo it (usually: revert this PR). -->

## Depends on

<!-- "#N", or "nothing". -->
