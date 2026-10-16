<!-- Title: a Conventional Commit, e.g. "fix(api): /api/models never calls out when TEACH_OFFLINE=1". English is the standard;
     a description in your own language is welcome too. Every section below is
     required — scripts/check_pr.py fails the PR if one is missing or empty. -->

## What and why

<!-- One concern per PR. Link the issue or RFC it answers. -->

## Kind

code — area (api / cli / labs / pipeline / checks / ci): 
- Site: none | image-rebuild  <!-- computed by scripts/check_pr.py from the changed files; see CONTRIBUTING → Merging and deploying the site -->

## Scope

<!-- How big is this change? Keep exactly ONE value on the first line, and delete the others.
     scripts/check_pr.py fails the PR without it. Rules: CONTRIBUTING -> How big is my change? -->
- Scope: small | medium | large | exam-version

- `exam-version`: `tracked_version`, `objectives` or a frozen syllabus change in `catalog.yaml`.
- `large`: `.github/`, `Makefile`, `scripts/check_*`, dependencies or weights; more than 1 topic; more than 400 code lines.
- `medium`: one topic's content or lab, or one script.
- `small`: docs, typos or links.

An `exam-version` change only happens in its upgrade milestone's final PR. Never in a links fix, never mixed with anything else.

## Provenance

<!-- Who or what wrote it. For AI, these must match meta.yaml of every topic you touch. -->
- Author: human | ai  <!-- 'ai' also when an AI helped write it; then Backend and Model are required -->
- Backend: none | claude | ...
- Model: none | <model id, if an AI wrote the code>
- Date: YYYY-MM-DD
- Cost: <!-- e.g. "subscription quota, 1 window" / "$0.07 API" / "none" -->
- Official source: <!-- vendor/project documentation this is based on -->

## Evidence

<!-- Commands you ran and their short output. -->
```
make pr-check   # CI's PR checks, locally (CONTRIBUTING -> Check before you push)
make test
...
make verify-ci
make determinism
```

### Where it ran

<!-- The CI run on this PR's HEAD commit, green: github.com/villadalmine/study-cybercirujas/actions/runs/<id>.
     CI posts a 'where-it-ran' comment with this line ready to paste after each push; a new push
     makes the old link stale and pr-format fails until it is updated. Add the machine or local
     environment too if you ran anything there. -->
- CI: 
- Local: 

### Known gaps

<!-- What this evidence does NOT cover. Always present; 'none' is a claim, not a default.
     A stale code graph is not a gap and not a reason to rebase: leave graphify-out/ out of the diff,
     CI refreshes it on main through the bot PR (docs/DEVTOOLS.md). -->

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
make verify-ci
```

## Risk and rollback

- [ ] Docs consistent (`make check-docs` green) / code graph regenerated (`make graph`) or why not
- [ ] Commits signed off (DCO): `git commit -s`; fix a missing one with `git rebase --signoff origin/main`

<!-- What could break, for whom, and how to undo it (usually: revert this PR). -->

## Depends on

<!-- "#N", or "nothing". -->
