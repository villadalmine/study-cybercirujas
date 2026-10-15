# Automated review (Copilot)

GitHub Copilot code review comments on pull requests here. It is useful and it
is not the judge: the checks in CI and the maintainer are. This is how it
behaves and how authors — people or AI agents — work with it.

Verified against GitHub's documentation on 2026-10-15
([Using GitHub Copilot code review](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review))
and observed on PR #1.

## How it behaves

- **When it runs.** On a new push, if the repository has automatic review
  enabled with *review new pushes* (as here). Otherwise, or to ask again:
  *Reviewers → Copilot → re-request* in the PR, or
  `gh pr edit <n> --add-reviewer @copilot` (`gh pr create --reviewer @copilot`
  when opening). Each review is limited by the requesting account's Copilot
  quota; when it runs out, the review says so and does not run.
- **It does not block the merge.** Its review is a *comment*; it does not
  count toward required approvals. It does not replace `verify`, `e2e` and
  `pr-format`, which are the checks that count.
- **It does not read replies.** Replies to its comments are for people; it
  will not see them or answer. It re-reads the code on each review, compares
  with its previous one ("resolved since last review"), and can raise findings
  in code that did not change ("previously missed") or repeat one already
  dismissed.
- **"Outdated"** on a comment means the lines it pointed at changed in a later
  commit. Often that is the fix, not always; and a comment that is *not*
  outdated may be fixed elsewhere (another line or file).

## How we work with it

1. **No "Commit suggestion".** Fixes go in their own commits, with a test where
   one applies, through the same checks as everything else.
2. **Triage comment, mandatory for the author, human or AI:**
   `Triage of the Copilot review (<review id>) — head <sha>`, a table with every
   finding — inline or in the review body — its verdict (*valid*, *invalid* or
   *partially*, with the reason), severity, and the commit that fixes it. An
   invalid finding is answered with the argument and the evidence, never
   ignored.
3. **One commit per finding** (`fix:`, `test:`, `docs:`), and a reply in each
   thread naming the commit.
4. **Push**, wait for CI and for the new review, update *Where it ran*, and
   repeat until a review brings no new valid finding.
5. **Threads** are resolved after the fix is pushed and checked — by the
   maintainer, or by the author when the maintainer has said so.
6. **If Copilot cannot run** (quota), the author says so in the PR and the
   diff it did not review is reviewed by hand.

## Authorship: who wrote it, who found what, who fixed it

The same record for every PR, whoever reviews it (Copilot, the `revisor-pr`
agent, a person) and whoever wrote it. It answers two questions from the PR
alone: *who is the author* and *who found and who fixed each problem*.

**Commits.** Besides the trailers the tool adds (`Co-Authored-By:`, a session
link), an agent's commits carry:

```
Agent: study-author (general-purpose)
Model: claude-opus-5-5
```

and a commit that fixes a finding also carries:

```
Found-by: fable (revisor-pr) https://github.com/<owner>/<repo>/pull/<n>#discussion_r<id>
Fixed-by: study-author/claude-opus-5-5
Fixes-review: https://github.com/<owner>/<repo>/pull/<n>#discussion_r<id>
```

A person writes `Found-by:` and `Fixes-review:` the same way when fixing a
finding by hand. Commits already pushed are not rewritten to add them.

**`## Authorship` in the description** (required, `check_pr.py`):

| Role | Who | What | Link |
| :--- | :--- | :--- | :--- |
| Author | AI: study-author · claude-opus-5-5 | commits `7c53077..6fd099f` | session |
| Reviewer | Copilot code review | head `a1c8200` — no review (quota) | review id |
| Reviewer | AI: fable (`revisor-pr`) | head `cbe35a5` — 2 medium, 4 low | review link |
| Approval and merge | the maintainer (human) | pending | — |

The Author row starts with `Human:` or `AI:` and must agree with
*Provenance* (`Author: human|ai`; for AI it names the declared model).

**`### Findings ledger`** under it, one row per finding:

| # | Found by | Head | Severity | Finding | Fixed by | Fix | Verified by | Status |
| :- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | fable `revisor-pr` r123 | `cbe35a5` | medium | … | study-author / claude-opus-5-5 | `db8db53` | fable, round 2 (link) | fixed |

*Found by* is Copilot, `revisor-pr`, CI (with the run) or a person, with the
link to the comment. *Verified by* is filled in when the next round confirms
the fix (a Copilot review lists it as "resolved since last review"; a
`revisor-pr` round says so); until then it says *pending*. *Status* is
`fixed`, `open`, or `rejected — <reason>`: a rejected finding keeps its row,
with the argument. `check_pr.py` checks the shape (9 columns, *Found by*
present, a valid status, *Fixed by* and *Fix* for a fixed row); the content is
for the reviewer and the maintainer.

The author updates both tables on every round, in the same edit that updates
*Where it ran*.

## The graph refresh PR

`graphify-out/` (the committed code graph) is not part of anyone's feature PR.
Whoever merges first no longer makes the other rebase to refresh it:
`.github/workflows/graph.yml` regenerates it on `main` and opens one bot PR,
`chore(graph): regenerate code graph`, from the branch `bot/graph-refresh`
([docs/DEVTOOLS.md](DEVTOOLS.md)). A feature PR that shows a stale graph
warning in `make verify` is fine; one that touches `graphify-out/` is asked to
drop that from the diff. The bot PR is reviewed like any PR, minus the
description: `scripts/check_pr.py` checks only its title when the branch is
`bot/graph-refresh` and every changed file is under `graphify-out/`. Its
required checks are started by the workflow itself (it dispatches `verify.yml` on the
branch with `GITHUB_TOKEN`; no secret). The
maintainer merges it; an agent never does.

## When a PR is ready

- the latest Copilot review is triaged and has no open valid finding (or the
  PR says it could not run and how the diff was reviewed instead);
- CI is green on the head commit and *Where it ran* links that run;
- no thread is left unresolved;
- *Authorship* and its *Findings ledger* list every review and every finding
  of the last round.

Then the maintainer merges. An agent never does.
