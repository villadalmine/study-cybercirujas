<!-- The human summary of the NEXT release. Add a line here in your PR when the change is visible
     to a user or an operator. On release, .github/workflows/release-please.yml puts this text on
     top of the GitHub Release (release-please's changelog stays below a `---`), adds the thanks to
     the outside contributors it finds by itself, and opens a PR that empties this file again.
     Do not edit the three headings; a section with no line under it is left out of the release.
     Rules and the script: CONTRIBUTING -> Releases, scripts/release_notes.py. -->

## Highlights

<!-- One line per change a user will notice: `- **Short name:** what changed and why it matters.` -->
- **Self-audit:** `docs/audit/` publishes the rubric we check this repo with, `scripts/audit_compare.py` compares auditors, and anyone can submit a result or propose a criterion.
- **CKA and CKAD on Kubernetes v1.37:** the catalog now tracks the v1.37 exam (the vendor's objectives are unchanged, byte for byte). The material, the labs and the lab runner image moved to 1.37 by script (220 version lines, no model call), and every lab that runs something was proved on kind and k3s v1.37.

## Upgrade notes

<!-- What an operator must do or watch when upgrading (a new required value, a changed default). -->

## Thanks

<!-- Only for credit the script cannot find, e.g. a reviewer or a reporter: `- @user for what (#N)`.
     Authors of merged outside PRs are added automatically as `@user (#N)`. -->
