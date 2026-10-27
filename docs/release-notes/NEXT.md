<!-- The human summary of the NEXT release. Add a line here in your PR when the change is visible
     to a user or an operator. On release, .github/workflows/release-please.yml puts this text on
     top of the GitHub Release (release-please's changelog stays below a `---`), adds the thanks to
     the outside contributors it finds by itself, and opens a PR that empties this file again.
     Do not edit the three headings; a section with no line under it is left out of the release.
     Rules and the script: CONTRIBUTING -> Releases, scripts/release_notes.py. -->

## Highlights

<!-- One line per change a user will notice: `- **Short name:** what changed and why it matters.` -->

## Upgrade notes

<!-- What an operator must do or watch when upgrading (a new required value, a changed default). -->

- **Groundedness tooling:** `check_groundedness.py` now verifies the pinned sha256 of the weights every time it loads them (a cache that does not match exits with a message; re-run `--download`), and `--write` together with `--dry-run` or `--fixture` is an error instead of a silent no-op. Warn mode and the recorded scores do not change.

## Thanks

<!-- Only for credit the script cannot find, e.g. a reviewer or a reporter: `- @user for what (#N)`.
     Authors of merged outside PRs are added automatically as `@user (#N)`. -->
