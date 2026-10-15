# Contributing

Thank you. This project is a curriculum maintained like software
([docs/PRINCIPLES.md](docs/PRINCIPLES.md)), so contributing works like it does
in a code repository: a branch, a change, checks that pass, a review. You do
not need an AI key or any paid service for any of it.

## Set up, once

Linux or macOS (on Windows use WSL — Ubuntu — the tooling assumes a POSIX
shell and `.venv/bin`). You need `git`, `make` and Python ≥ 3.11 with `venv`.

```bash
git clone https://github.com/<you>/study-cybercirujas.git    # your fork
cd study-cybercirujas
make setup        # checks prerequisites, creates .venv, installs `teach`, enables the git hooks
make test         # every fast test, offline (~1.5 min)
```

`make setup` runs `make preflight` first and stops with the exact package to
install if something is missing. It also sets `core.hooksPath` to `.githooks`:
the pre-commit hook refuses content below the quality floor, content without
provenance, a syllabus status that disagrees with disk, and anything shaped
like an API key. It runs in under a second. Do not bypass it with
`--no-verify`; if you must, say why in the commit message.

## What you can contribute

| You want to… | Do this | Open first |
|---|---|---|
| **report a wrong explanation** | an issue with the *Content error* template: certification, topic, language, the wrong sentence, and the **official source** that shows it | issue |
| **fix a translation** | edit `certs/<cert>/<topic>/<lang>/content.md` or `exercises.md`; keep code blocks, commands, URLs and headings exactly as in English | PR (*Translation* issue optional) |
| **fix content in English** | edit the `en` file, cite the official source in the PR; translations will follow from it | issue first if it is more than a typo |
| **add or fix a lab** | `teach lab new <cert> <topic>` creates `lab.yaml` + a `break_fix.sh` template (no AI); fill in the TODOs, then `teach lab validate <cert> <topic>`. The runner and the full lab format: `docs/LABS-RUNNER.md` (arriving with the `labs-runner` branch) | *Lab* issue |
| **fix a bug or add a feature** | code in `teach/` or `scripts/`, with a test | *Bug* issue for bugs |
| **change a rule, add a certification family or a language** | a proposal, see [GOVERNANCE.md](GOVERNANCE.md) | *Proposal (RFC)* issue |

### Provenance is mandatory

Every `certs/<cert>/<topic>/<lang>/` has a `meta.yaml` saying who or what wrote
it. Generated material records `backend`, `model`, `generated_at` and
`sources` automatically. **When you edit material by hand, keep those fields
and append a record of your edit:**

```yaml
human_edits:
  - date: 2026-10-15
    author: github-handle
    summary: fixed the PV reclaim policy default
    source: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
```

With AI or without it, the same rule: nothing enters the corpus without
saying where it came from.

<a id="no-braindumps"></a>

### No braindumps, no NDA material

Material is written from the **public** official syllabi and documentation
only. We do not accept:

- questions or answers leaked from real exams (*braindumps*), whether copied,
  paraphrased or "remembered";
- anything covered by a non-disclosure agreement (NDA): exam content, beta
  exam items, vendor training material that is not public.

A PR that adds any of it is closed without merging, and the content is removed
if it ever landed. If you find some in the repository, report it with the
*Content error* issue form (say it is a braindump or NDA material and where it
is), or privately to the maintainer; it is removed first and discussed after.
Exam candidates sign the vendors' NDAs: this rule protects them as much as the
project.

## Conventions

- **Branches:** `<type>/<short-topic>`, e.g. `fix/cka-1.1-reclaim-policy`,
  `i18n/es-cks-3.2`, `lab/lpi-010-160-2.3`.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/):
  `fix(cka): …`, `feat(labs): …`, `docs: …`, `test: …`, `i18n(es): …`. The body
  says *why*.
- **Language:** English is the standard for PRs, commits and code; a PR
  description in your own language is welcome too — everything gets
  translated. Study material in the language it is written for.
- **Small pull requests**, one concern each. Generated files (STATUS.md,
  MODELS.md, the README table, the API table) are regenerated, never edited
  by hand: `teach status`, `scripts/gen_readme_table.py`, `scripts/gen_api_docs.py`.

## Pull requests

One template per kind of change, in
[`.github/PULL_REQUEST_TEMPLATE/`](.github/PULL_REQUEST_TEMPLATE/):
`content.md`, `translation.md`, `lab.md`, `video.md`, `code.md`, `docs.md`
(pick one with `?template=<name>.md` on the compare URL). Every PR has the same
required sections — **What and why · Kind · Provenance · Evidence · How to test
it from a clean clone · Risk and rollback · Depends on** — and each template
adds only what its kind needs (a translation: the gate result and three
paragraphs picked with a stated seed; a lab: break → verify fails, fix → verify
passes; a video: duration, a frame, the audio language).

**Provenance** says *human* or *AI*; for AI, the backend, the model, the date
and the cost, plus the official source. It is verified, not trusted:
`scripts/check_pr.py` runs on every PR and compares what the PR declares with
the `meta.yaml` of every topic it touches. A person and a model pass the same
filter.

**Where it ran.** Every PR proves where it ran: under *Evidence*, a
`### Where it ran` subsection links the green CI run on the PR's **current
head commit** (plus the machine or local environment, if you ran anything
there), and a `### Known gaps` subsection says what that evidence does *not*
cover. After each push CI posts a *where-it-ran* comment with the exact line to
paste; `pr-format` checks, with the API, that a cited run belongs to this
repository, is on the head commit and is green. A new push makes the old link
stale on purpose, so the description has to be updated — that keeps "it passed"
attached to the code that is actually being merged.

### Size and scope

| Kind of PR | Scope | Checked by `check_pr.py` |
|---|---|---|
| content or translation | **one topic in one language** | more than one `certs/<cert>/<topic>/<lang>/` fails |
| lab | **one lab** | more than one `certs/<cert>/<topic>/lab/` fails |
| code | **≤ ~400 changed lines** (generated files excluded) | over 400 fails; split into stacked PRs, each saying `Depends on: #N` |
| any | material and code are never mixed; generated files (`STATUS.md`, `MODELS.md`) are regenerated, never edited by hand | fails |

A maintainer can waive scope or size for one PR with the label
`scope-exception` or `size-exception`, saying why in the PR.

### Labels

Applied automatically, no external bot: `site:none` / `site:image-rebuild`
by `pr-format`, and `type:content|lab|video|code|ci|docs` and
`lang:en|es|other` by path ([`.github/labeler.yml`](.github/labeler.yml),
`actions/labeler`).

### Agents

AI agents (Claude Code, Codex, Gemini, …) open PRs exactly like people: the
same templates, the same required sections, provenance that names the model,
"Where it ran" on the head commit, and the commit trailers their tool adds
(`Co-Authored-By:` and a session link). The checks do not care who wrote the
PR — that is the point.

## Reviews and merging

| What | Reviewed against | By |
|---|---|---|
| content | the official source it cites | maintainer of the area |
| translation | the structural gate, plus three paragraphs picked with the seed stated in the PR | maintainer, or a fluent contributor |
| lab | the cycle in the PR: break → verify fails, fix → verify passes, down leaves nothing | maintainer |
| video | duration, a frame, the audio language | maintainer |
| code | tests and CI | maintainer |

[`.github/CODEOWNERS`](.github/CODEOWNERS) requests the right reviewer
automatically; today every path belongs to the one maintainer, and areas get
their own owners as maintainers join ([GOVERNANCE.md](GOVERNANCE.md)).

Automated review by Copilot runs alongside and has its own rules:
[docs/REVIEWS.md](docs/REVIEWS.md).

**Merging:** squash merge only — the PR title becomes the single commit on
`main`, which is why it must be a Conventional Commit. The branch is deleted on
merge. Nobody merges their own PR, except the maintainer for maintenance
changes; an agent never merges.

## Merging and deploying the site

Every PR is labelled by CI from the files it changes —
`scripts/check_pr.py` computes it, the PR declares it on its `Site:` line, and
a mismatch fails the check. The list of what the image is built from lives in
one place: the `paths` of `.github/workflows/docker.yml`, which match what
`deploy/Dockerfile` copies.

| Label | Means | Merge |
|---|---|---|
| `site:none` | docs, tests, `.github/`, `Makefile`, helm values… nothing the image is built from | as soon as CI is green |
| `site:image-rebuild` | `teach/`, `certs/`, `scripts/`, `media/`, root `*.yaml`, `pyproject.toml`, `deploy/Dockerfile` | mergeable to `main` — `main` is the source. On merge GitHub Actions rebuilds the **public** image (`ghcr.io/villadalmine/study-cybercirujas:latest`, what people who clone or `docker run` get) |

**No PR deploys production.** The site at study.cybercirujas.club is released
by the maintainer in a separate step: build the image on their machine or
cluster, `helm upgrade` with an explicit tag ([docs/OPERATING.md](docs/OPERATING.md)),
and tag the released commit `site-YYYY-MM-DD` so anyone can see what is
published: `git tag -l 'site-*'`.

## Checks that must pass

All of them run without keys, without a model, and without network beyond
installing dependencies. CI runs the same targets.

| Flow | Test | Command |
|---|---|---|
| clone → setup → serve → site, API, CLI → Docker lab → cleanup | `tests/e2e/clone_and_run.sh` | `make test-e2e` (needs Docker for the lab step; clones your **committed** HEAD) |
| the site, the API and the student CLI, offline | `tests/test_smoke.py` | `make smoke` |
| determinism: derived files and validators twice, byte for byte, network and models blocked | `tests/test_determinism.py` | `make determinism` |
| labs: every lab honours the contract; `lab new` produces a valid lab; broken specs are caught; `lab up` attaches stdin | `tests/test_labs.py` | `make test` |
| translation: the structural gate a translation must pass (code blocks, URLs, headings, length) | `tests/test_translation_verify.py` | `make test` |
| content: quality floor, manifests, Kubernetes APIs, provenance, sources, syllabus, versions; README/API tables up to date | `scripts/check_*.py`, `gen_*.py --check` | `make verify-ci` |
| the PR description: required sections, Conventional Commit title, declared provenance = `meta.yaml`, Where it ran on the head commit, size and scope | `scripts/check_pr.py`, `tests/test_check_pr.py` | `scripts/check_pr.py --title "<title>" --body-file <body.md> --base origin/main` (CI runs it on every PR) |
| everything fast above, in one go | `tests/` | `make test` |

Lab lifecycle in a container (run → break → verify → cleanup per lab) joins
`make test-e2e` with the lab runner; until then `tests/test_labs.py` carries a
skipped placeholder so the gap is visible.

A lab that is known to be broken is listed, with the reason, in
`tests/fixtures/labs_known_broken.txt`; fixing it means deleting its line.

## Licence and conduct

By contributing you agree your contribution is licensed under
[Apache 2.0](LICENSE), and you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
