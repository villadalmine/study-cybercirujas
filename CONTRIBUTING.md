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
| **run a lab somewhere else** | the same lab runs in Docker, on Killercoda or on your own cluster: [docs/RUN-A-LAB-ANYWHERE.md](docs/RUN-A-LAB-ANYWHERE.md). Export to Killercoda: `make killercoda-export` | issue |
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

### Sign your commits (DCO)

Every commit in a pull request carries a `Signed-off-by:` line:

```bash
git commit -s -m "fix(api): ..."      # adds: Signed-off-by: Your Name <you@example.org>
```

**What it means.** The line is your word that you wrote the change, or have the right to
send it, under this project's licence (Apache 2.0). It is the
[Developer Certificate of Origin](DCO) 1.1, the same one the Linux kernel uses. It is not
a paper to sign and nobody reviews it: `scripts/check_pr.py` only checks that the line is
there and that the email is the commit author's (or your GitHub `noreply` address).

**You forgot it.** The check tells you which commits:

```bash
git commit --amend -s                  # only the last commit
git rebase --signoff origin/main       # every commit of your branch
git push --force-with-lease            # update the PR
```

**Why no CLA.** The project is open source and its licence is not going to change, so we
do not ask anyone to assign rights, sign an agreement or promise anything beyond the DCO.
You keep the copyright of what you wrote. No NDA material either (see below).

**AI policy.** AI-assisted work is welcome **when it is declared**. In the PR's
*Provenance* section write `Author: ai` (also when an AI only helped) and name the
`Backend` and `Model`; `check_pr.py` fails the PR if that is missing. The `Signed-off-by:`
is a human's: whoever signs takes responsibility for the change, whatever wrote it. Our own
agents sign their commits too.

Every commit of the PR that is not on `main` yet needs it, whatever the PR's number (a reopened old
PR gets the full check; `git rebase --signoff origin/main` fixes it). Merged history is never rewritten.
The graph bot's PR is the one exemption, decided by who opened it, from which repository and branch and
which files it touches, never by a commit's author email, which anyone can set.

**Thanks.** When a pull request from someone outside the maintainers is merged, the
maintainer adds a line to [CHANGELOG.md](CHANGELOG.md): `Thanks @user (#N)`.

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

### Raising a topic's quality score

Every `certs/<cert>/<topic>/<lang>/meta.yaml` has a `quality:` block: the
score (0-100), the level (*Verified*, *AI beta*, *Draft*) and every check
behind it, each `pass`, `fail` or `not_run` with its evidence. It is written by
`make quality` (`scripts/quality_score.py`), **never by hand**, and CI fails
if a block is not what the files give — so after generating or editing
material, run `make quality CERT=<cert>` and commit the meta.yaml it changed.
The weights and thresholds are in `quality_weights.yaml`.

To raise a topic's score, turn its `not_run` and `fail` entries into `pass`:

| Check | How it passes |
|---|---|
| `quality_floor` | content.md and exercises.md meet the floor in `pipeline.yaml` |
| `provenance` | meta.yaml names a real backend and model (not `unknown`) |
| `sources` | a References section whose URLs mostly belong to projects in `docs/sources.yaml` |
| `k8s_manifests` | every YAML/JSON block parses; no removed Kubernetes API |
| `translation_gate` | the translation keeps the source's code blocks, URLs, headings and length |
| `source_chain` | the link declares its origin (docs/PRINCIPLES.md → The source chain) and it has not changed since |
| `lab` | the topic's lab ran in the study-lab runner and its `lab.yaml` records `verified` |
| `independent_review` | a `reviews:` entry in meta.yaml: `{by, link, date, result: pass}` — `fable (revisor-pr)` or Copilot, with the review's link |
| `human_review` | a `human_edits:` entry (see *Provenance is mandatory*) |
| `citations_resolve` | not run in CI today (network); it stays `not_run` |
| `groundedness` | `make groundedness DIRS=certs/<cert>/<topic>/<lang>` and commit the `meta.yaml` it writes (see *Groundedness (advisory)* below); CI reports the same run but does not commit, so the entry stays `not_run` until you run it |

*Verified* needs a score of 85 or more **and** a passed lab and independent
review; a high score from automatic checks alone stops at *AI beta*.

## Conventions

- **Branches:** `<type>/<short-topic>`, e.g. `fix/cka-1.1-reclaim-policy`,
  `i18n/es-cks-3.2`, `lab/lpi-010-160-2.3`.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/):
  `fix(cka): …`, `feat(labs): …`, `docs: …`, `test: …`, `i18n(es): …`. The body
  says *why*.
- **Language:** English is the standard for PRs, commits and code; a PR
  description in your own language is welcome too — everything gets
  translated. Study material in the language it is written for.
- **Do not commit `graphify-out/`** (the code graph) and do not rebase just to
  refresh it: CI rebuilds it on `main` and opens a bot PR
  (`bot/graph-refresh`). **Nothing changes for you locally:** `make graph`
  stays optional, no secret, token or extra tool is needed, and the graph is
  refreshed after merge. The post-commit hook may dirty `graphify-out/`; run
  `git restore graphify-out` before you stage. A stale graph in a PR is a
  warning, not a failure ([docs/DEVTOOLS.md](docs/DEVTOOLS.md)).
- **Small pull requests**, one concern each. Generated files (STATUS.md,
  MODELS.md, the README table, the API table) are regenerated, never edited
  by hand: `teach status`, `scripts/gen_readme_table.py`, `scripts/gen_api_docs.py`.

## Check before you push

CI takes minutes, and a review round more. `make pr-check` runs, on your
machine, the fast checks CI would run on your PR (about a minute with `QUICK=1`,
about five with the full unit-test suite), so you find the failure before you push instead of after.

```bash
make pr-check QUICK=1                                   # about a minute: everything but the full unit tests
make pr-check                                           # all of it, about five minutes (run it once before asking for review)
make pr-check PR_BODY=body.md PR_TITLE="feat(x): y"     # plus your draft PR description
```

It prints one line per check and a summary, and exits non-zero if any check FAILs:

```text
OK    check_manifests.py  (9.0s)
FAIL  check_source_chain.py  (1.6s)
        chain: certs/cka/3.3/lab/lab.yaml does not declare its origin: derived_from
WARN  code graph fresh (warn-only)
11 OK, 1 WARN, 1 FAIL in 60s
```

- **OK**: passed. **WARN**: not blocking, but read it (a stale graph, a skipped
  check, CRLF line endings). **FAIL**: CI would fail too. Read the indented
  lines under it (they are that script's own message), fix, run it again.
- It does not duplicate CI: the content checks are the recipe of `make
  verify-ci` (the same one CI runs, quality score included), plus the secrets
  scan, `scripts/check_docs.py`, the code-graph freshness (warn-only, needs
  `make graph-setup`), `scripts/check_pr.py` on your description when you give
  `PR_BODY`, and the groundedness check. Groundedness
  is advisory and runs only when its weights are already downloaded
  (`make groundedness-setup`, once); otherwise the line says CI-only.
- **Stays CI-only**, because it needs the network, a model, Docker or a
  cluster, or the pushed commit: `make test-e2e`, the Docker image build, the
  kind labs, `check_citations` / `check_api_facts`, `check_claims`, and the
  "Where it ran" check of the cited run.
- **Windows:** native Windows is not supported; use WSL (Ubuntu). On Windows
  git may check files out with CRLF line endings, which changes every sha256
  the source chain compares; `make pr-check` WARNs when a tracked text file has
  them. Fix: `git config core.autocrlf false` and check the files out again (or
  clone inside WSL).

### Optional: run it automatically before every `git push`

A *git hook* is a script that git runs by itself at a fixed moment; this one
runs before `git push`. It is optional, local to your clone and never shared or
forced: nothing installs it for you, and it does nothing until you ask.

```bash
make setup            # once; sets core.hooksPath to .githooks (the pre-commit hook lives there)
make install-hooks    # switch it on: sets `pr-check.prepush true` in this clone's .git/config
make uninstall-hooks  # switch it off (same as: git config --local --unset pr-check.prepush)
```

The hook file, `.githooks/pre-push`, is part of the repository; it exits at
once unless that config key is `true`. When on, every `git push` waits about a
minute for `make pr-check QUICK=1` and is refused if it FAILs. Skip it once
with `git push --no-verify`.

### Run a lab anywhere, and get yours published

Write your lab in `certs/<cert>/<topic>/lab/` (`study-lab new` scaffolds it), prove it locally with
`study-lab run`, `study-lab check` (must FAIL), your fix, `study-lab check` (must PASS), and open a PR here.
CI validates the lab contract (`labs.yml`). Once it is merged, the lab is exported and published on
Killercoda, in the course of its certification: https://killercoda.com/itrestauracion. The same code also runs in
Docker and on your own cluster: [docs/RUN-A-LAB-ANYWHERE.md](docs/RUN-A-LAB-ANYWHERE.md). The Killercoda
repository only receives the generated tree; labs are never edited there.

### How a lab gets proven before it is published

CI validates the lab contract and then runs the generated Killercoda scenario on an Ubuntu 24.04 VM (a kubeadm
cluster for the k8s family): `verify` fails while it is broken, your reference fix makes it pass, `cleanup` is
idempotent. Add the fix as `deploy/killercoda/fixes/<cert>-<topic>.sh`. Without that evidence nothing is published.
Details and limits: [docs/RUN-A-LAB-ANYWHERE.md](docs/RUN-A-LAB-ANYWHERE.md).

## Pull requests

One template per kind of change, in
[`.github/PULL_REQUEST_TEMPLATE/`](.github/PULL_REQUEST_TEMPLATE/):
`content.md`, `translation.md`, `lab.md`, `video.md`, `code.md`, `docs.md`
(pick one with `?template=<name>.md` on the compare URL). Every PR has the same
required sections — **What and why · Kind · Scope · Provenance · Evidence · Authorship ·
How to test it from a clean clone · Risk and rollback · Depends on** — and each template
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
repository, is a run of `.github/workflows/verify.yml` on a `pull_request`
event, is on the head commit, and has its `verify` and `e2e` jobs green. That
proves *this workflow ran green on this commit*, not that the workflow is the
one on `main`: `pr-format` runs from the PR branch, so the maintainer reads
every `.github/` change (CODEOWNERS lists it on its own). A new push makes the old link
stale on purpose, so the description has to be updated — that keeps "it passed"
attached to the code that is actually being merged.

**Authorship.** Every PR records who did what, and keeps it current on every
review round:

- a table with the **author** (`Human: <who>` or `AI: <agent> · <model>`, and
  the range of commits), one row per **review** (Copilot, the `revisor-pr`
  agent, a person: link, the head it read, the result) and the **approval and
  merge** (always a human maintainer);
- a `### Findings ledger`, one row per finding, whoever found it (a reviewer,
  CI, a person): found by (with the link to the comment) · head · severity ·
  fixed by · fix commit · verified by (who confirmed it next round) · status
  (`fixed`, `open`, or `rejected — <reason>`).

`check_pr.py` fails the PR when the section or the ledger is missing, a ledger
row is malformed, or the author row disagrees with *Provenance* (human vs AI,
and for AI the model). Details and an example: [docs/REVIEWS.md](docs/REVIEWS.md).

### Size and scope

| Kind of PR | Scope | Checked by `check_pr.py` |
|---|---|---|
| content or translation | **one topic in one language** | more than one `certs/<cert>/<topic>/<lang>/` fails |
| lab | **one lab** | more than one `certs/<cert>/<topic>/lab/` fails |
| code | **≤ ~400 changed lines** (generated files excluded) | over 400 fails; split into stacked PRs, each saying `Depends on: #N` |
| any | material and code are never mixed; generated files (`STATUS.md`, `MODELS.md`) are regenerated, never edited by hand | fails |

A maintainer can waive scope or size for one PR with the label
`scope-exception` or `size-exception`, saying why in the PR. Setting or
removing the label re-runs `pr-format` on its own (it reads the labels live),
without re-running `verify` and `e2e`.

### How big is my change?

Every PR declares one **Scope** in its description (a required section, checked by `scripts/check_pr.py`).
Pick the biggest line that applies:

| Scope | It is | Why it matters |
| :--- | :--- | :--- |
| `small` | docs, typos or links | normal flow: CI and an independent review |
| `medium` | one topic's content or lab, or one script | normal flow |
| `large` | `.github/`, `Makefile`, `scripts/check_*`, dependencies or weights; more than 1 topic; more than 400 code lines | the maintainer reads it; never merged from a fork without the maintainer's OK |
| `exam-version` | `tracked_version`, the `objectives` document or a frozen syllabus changes | has its own milestone (see below) |

**An exam version never changes by accident.** `tracked_version` and `sources.objectives` in `catalog.yaml`
say which curriculum version the material was built against. Moving them means the whole cert must be re-evaluated
(table of contents, every topic), so it only happens in the **final PR of an upgrade milestone**
([#63](https://github.com/villadalmine/study-cybercirujas/issues/63)). `check_pr` fails any PR that changes them
unless the PR's **real GitHub milestone** is the upgrade milestone of those certs and that version (named like
"CKA & CKAD v1.37 upgrade": it must name every cert whose version or objectives change, and its version must equal
their new `tracked_version`: the last word before "upgrade", with or without a leading `v`, so `v1.37`, `2025-11-24`,
`unknown` or `beta`; for a value like `Terraform 1.12` its last word, `v1.12`) **and**
its description declares `Scope: exam-version`. The `scope:exam-version` label is only classification, and text
in the description cannot authorize anything, so neither is enough. What counts as moving them is deterministic: `tracked_version` changes, or the objectives URL names another curriculum
**document**: another file name (`CKA_Curriculum_v1.35.pdf` -> `..._v1.37.pdf`), host or repo. Re-pinning the same
file name in the same repo to a commit or ref (`/raw/master/` -> `/raw/<sha>/`, or sha -> sha) is link maintenance:
`Scope: small`, no milestone. A dead-link fix that points at a different document is blocked: it
goes into the milestone. If the exam body published a new version, open the "New exam curriculum version" issue form.
The labels are applied by a maintainer today; a script will compute them from the diff
([#62](https://github.com/villadalmine/study-cybercirujas/issues/62)).

### How issue forms work

For maintainers. Each file in `.github/ISSUE_TEMPLATE/*.yml` is a **GitHub issue form**: a YAML description of the
fields (`input`, `textarea`, `dropdown`, `markdown` text) that GitHub draws as a web form on *New issue*. When someone
submits it, GitHub writes the answers into the issue body under each field's `label`, and applies the `labels:` listed
at the top (they must already exist in the repo). `validations: {required: true}` makes a field mandatory; a form
cannot branch, so "if yes, use another form" is a sentence plus a dropdown answer, not a redirect.
`config.yml` sets `blank_issues_enabled: false` (every issue comes through a form) and the contact links. A form is
live as soon as the file is on the default branch; to try one, merge it and open *New issue*. PR templates are different:
they are plain Markdown, one is chosen with `?template=<name>.md` in the compare URL, and `check_pr` reads the headings.

### Labels

Applied automatically, no external bot: `site:none` / `site:image-rebuild`
by `pr-format`, and `type:content|lab|video|code|ci|docs` and
`lang:en|es|other` by path ([`.github/labeler.yml`](.github/labeler.yml),
`actions/labeler`).

### Agents

AI agents (Claude Code, Codex, Gemini, …) open PRs exactly like people: the
same templates, the same required sections, provenance that names the model,
"Where it ran" on the head commit, the commit trailers their tool adds
(`Co-Authored-By:` and a session link), a `Signed-off-by:` (`git commit -s`, see
[Sign your commits (DCO)](#sign-your-commits-dco)), plus `Agent: <role>` and
`Model: <model id>` on every commit, and on a commit that fixes a finding
`Found-by: <reviewer> <link>`, `Fixed-by: <agent>/<model>` and
`Fixes-review: <link>` ([docs/REVIEWS.md](docs/REVIEWS.md) → Authorship). The checks do not care who wrote the
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
| docs consistent with the repo: relative links and anchors, paths in code, `make` targets and `teach` commands exist, generated files fresh | `scripts/check_docs.py`, `tests/test_check_docs.py` | `make check-docs` (CI: job `docs-consistency`) |
| the code graph is what the tree builds (a warning on a PR, never a failure: CI refreshes it on `main` through a bot PR, `make graph` stays optional) | `scripts/check_graph.py --regenerate` | `make graph-setup && make graph` (free, tree-sitter only; CI: job `docs-consistency`) |
| the quality score: every topic's `quality:` block is what the files give (after generating or editing material) | `scripts/quality_score.py --check`, `tests/test_quality_score.py` | `make quality CERT=<cert>`, then commit the meta.yaml it changed |
| the PR description: required sections, Conventional Commit title, declared provenance (human or AI, with the model) = `meta.yaml`, Where it ran on the head commit, size and scope; every commit signed off (DCO) | `scripts/check_pr.py`, `tests/test_check_pr.py` | `scripts/check_pr.py --title "<title>" --body-file <body.md> --base origin/main` (CI runs it on every PR) |
| the checks CI runs on a PR, before you push (one line each) | `scripts/pr_check.py`, `tests/test_pr_check.py` | `make pr-check` (see *Check before you push*) |
| everything fast above, in one go | `tests/` | `make test` |

Lab lifecycle in a container (run → break → verify → cleanup per lab) joins
`make test-e2e` with the lab runner; until then `tests/test_labs.py` carries a
skipped placeholder so the gap is visible.

A lab that is known to be broken is listed, with the reason, in
`tests/fixtures/labs_known_broken.txt`; fixing it means deleting its line.

### Groundedness (advisory)

Is each sentence of a topic supported by the sources it declares — its frozen
syllabus entry and the documents it cites? `scripts/check_groundedness.py`
answers it with models pinned in `groundedness.yaml`
([PRINCIPLES §7](docs/PRINCIPLES.md#7-the-source-chain)). Unlike the checks
above it needs a model and the network (the cited pages and, once, the
weights), so it is not part of `make verify`:

| Command | What it does |
|---|---|
| `make groundedness-setup` | once: torch (CPU) + GLiClass from `requirements-groundedness.txt`, and the pinned weights (~1.7 GB, sha256 checked) into `.cache/groundedness/` |
| `make groundedness` | the GLiClass prefilter on the topics whose `content.md` changed against `BASE` (default `origin/main`), or on `DIRS="certs/<cert>/<topic>/<lang> ..."`; prints the unsupported claims with their score and records the `groundedness` check in each `meta.yaml` `quality:` (about 2 min for a topic of ~40 claims on 4 CPU cores) |
| `make groundedness-deep` | the same, then each suspect through Granite Guardian 4.1 8B on a llama-server you start with the GGUF pinned in `groundedness.yaml` (`--temp 0 --seed 42 -np 1`, port in `deep.url` or `GUARDIAN_URL=`); CPU or a local GPU, ~15–35 s per suspect on CPU |

CI runs the prefilter in the `groundedness` job (`.github/workflows/groundedness.yml`)
on every PR that touches a `content.md` or the check itself: the result is in
the job summary and, with the updated `meta.yaml` files, in its `groundedness`
artifact. It is `mode: warn` — it never fails on a finding, and it is not one
of the required checks. A flagged claim means *look*: reword it to what the
source says, cite the source that says it, or reply in the PR why the
classifier is wrong.

## Licence and conduct

By contributing you agree your contribution is licensed under
[Apache 2.0](LICENSE), certify the [DCO](DCO) with a `Signed-off-by:` on each commit
([Sign your commits](#sign-your-commits-dco)), and you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
