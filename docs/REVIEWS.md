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

## When a PR is ready

- the latest Copilot review is triaged and has no open valid finding (or the
  PR says it could not run and how the diff was reviewed instead);
- CI is green on the head commit and *Where it ran* links that run;
- no thread is left unresolved.

Then the maintainer merges. An agent never does.
