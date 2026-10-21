# AGENTS.md

study.cybercirujas is free, open study material for IT certifications (Linux, Kubernetes, cloud, AI): the official syllabus,
frozen, and for each objective theory, exercises and a break/fix lab. AI drafts it; deterministic scripts check it; people review
and merge. This file is the first thing an agent reads.

## Read in this order

1. [docs/CHARTER.md](docs/CHARTER.md): the eleven rules that are not negotiable. A change that breaks one does not go in.
2. [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md): the whole system in levels, with the scripts and what blocks.
3. [docs/GUARDRAILS.md](docs/GUARDRAILS.md): what is checked for truth, labs and code, and what is only a convention.
4. [docs/FAQ.md](docs/FAQ.md): how each part works, with the code that proves it.
5. [CONTRIBUTING.md](CONTRIBUTING.md): conventions, PR templates, labels, provenance, releases.
6. [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md): commands, the content cycle, what each check proves.
7. [docs/PRINCIPLES.md](docs/PRINCIPLES.md): the reasoning behind the charter.

## Hard rules for agents

- **DCO**: every commit is signed off (`git commit -s`); `scripts/check_pr.py` fails the PR otherwise.
- **Docs impact**: before opening the PR, every doc that names a file you changed is updated or listed under
  `## Docs impact` with `not affected: <why>`; `scripts/check_pr.py` fails the PR otherwise and prints the list.
- **AI disclosure**: the PR says an AI wrote it, with the agent, the real model id and the cost, and `meta.yaml` of every topic you touch agrees.
- **No secrets**: no keys, tokens or personal data in a commit, a PR body or a log; credentials come from the environment.
- **One topic per PR**, one concern per PR (code or material or labs, not mixed); more than 400 changed lines of code is split.
- **The FAQ is updated in the same PR** when the change alters something it explains.
- **`make pr-check` before pushing**; the PR links the green CI run on its head commit (`### Where it ran`).
- **An agent never merges.** A second model reviews (`revisor-pr`), findings go in the PR's ledger, a person merges.
- **Do not touch what another agent owns** (check open PRs and the epics: #124 docs, #166 quality, #167 labs).
- **Do not spend money or quota** that a free deterministic check can replace; GPU, API credits and cloud need the maintainer's OK.
- **Idempotent**: running a command twice changes nothing the second time; generated files carry a `--check`.

## Work flow

1. **One issue at a time**, picked by the audit's priority ranking; at most two workstreams open at once.
2. **One small PR per issue**, off `main`, never stacked on another PR, with `Closes #N` (finishes the issue) or `Part of #N`.
3. **`make pr-check` before pushing**; the PR links the green CI run on its head commit.
4. **One independent review** (a model that is not the author): highs and mediums block and are fixed in the PR; lows go to the area's
   umbrella issue with `from-review`, not to new PRs.
5. **Squash merge, by a person.** An agent never merges.
6. `milestone.yml` sets the milestone by itself; release-please makes the Release PR, the tag, the changelog and the notes.
   A `feat` or `fix` a user or operator will notice adds its line to `docs/release-notes/NEXT.md` in the same PR: the Release
   PR fails while a release with a `feat` or a `fix` has no summary there (v0.6.0 shipped without one).
7. **Labels**: CI sets `scope:*`, `site:*`, `type:` by path and `lang:`; `size-exception` and `scope-exception` are set only by the
   maintainer; `triage:needed` means someone from outside the project that nobody has looked at yet.

The long version, with the milestones, every label and the outside-contributor triage: [docs/ISSUE-TO-RELEASE.md](docs/ISSUE-TO-RELEASE.md).

## Where things live

| What | Where |
| :--- | :--- |
| Certifications, syllabi, material, labs | `catalog.yaml`, `certs/<cert>.md`, `certs/<cert>/<topic>/{en,es}/` and `certs/<cert>/<topic>/lab/` |
| Pipeline and quality settings | `pipeline.yaml`, `quality_weights.yaml`, `groundedness.yaml` |
| Code | `teach/` (core, web, `teach/lab` = the `study-lab` runner), `scripts/` (checks and generators), `tests/` |
| CI | `.github/workflows/` and `make pr-check` locally |
| Labs on other targets | `deploy/killercoda/`, [docs/RUN-A-LAB-ANYWHERE.md](docs/RUN-A-LAB-ANYWHERE.md) |
| Docs | `docs/` (generated: `docs/STATUS.md`, `docs/MODELS.md`); history: `CHANGELOG.md` and `docs/HISTORY.md` |
| The idea queue between agents | [docs/AGENTS_SYNC.md](docs/AGENTS_SYNC.md) (check it before starting; delete what you resolve) |
