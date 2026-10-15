<!-- Title: a Conventional Commit, e.g. "docs: clarify the lab contract". English is the standard;
     a description in your own language is welcome too. Every section below is
     required — scripts/check_pr.py fails the PR if one is missing or empty. -->

## What and why

<!-- One concern per PR. Link the issue or RFC it answers. -->

## Kind

docs — files: 
- Site: none | image-rebuild  <!-- computed by scripts/check_pr.py from the changed files; see CONTRIBUTING → Merging and deploying the site -->

## Provenance

<!-- Who or what wrote it. For AI, these must match meta.yaml of every topic you touch. -->
- Author: human | ai
- Backend: none | claude | ...
- Model: none | <model id>
- Date: YYYY-MM-DD
- Cost: <!-- e.g. "subscription quota, 1 window" / "$0.07 API" / "none" -->
- Official source: <!-- vendor/project documentation this is based on -->

## Evidence

<!-- Commands you ran and their short output. -->
```
make test
...
link check / rendered preview
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

## How to test it from a clean clone

```bash
git clone https://github.com/villadalmine/study-cybercirujas.git && cd study-cybercirujas
git fetch origin pull/<N>/head:pr && git checkout pr
make setup && make test
make verify-ci
```

## Risk and rollback

<!-- What could break, for whom, and how to undo it (usually: revert this PR). -->

## Depends on

<!-- "#N", or "nothing". -->
