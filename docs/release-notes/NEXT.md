<!-- The human summary of the NEXT release. Add a line here in your PR when the change is visible
     to a user or an operator. On release, .github/workflows/release-please.yml puts this text on
     top of the GitHub Release (release-please's changelog stays below a `---`), adds the thanks to
     the outside contributors it finds by itself, and opens a PR that empties this file again.
     Do not edit the three headings; a section with no line under it is left out of the release.
     Rules and the script: CONTRIBUTING -> Releases, scripts/release_notes.py. -->

## Highlights

<!-- One line per change a user will notice: `- **Short name:** what changed and why it matters.` -->
- **LPI objective pages can be frozen:** `curriculum_diff.py extract --html` reads an LPI objectives page (hashed, dated, weights as each objective's share of the questions), so LPIC-1/LPIC-2 can move to the canonical LPI pages through the deterministic upgrade process (#235).

- **Switch writes topic weights from a page:** when the target snapshot states a weight per objective (an LPI page), `curriculum_diff.py switch` writes each topic's `weight:` in `certs/<cert>.md` from the objective it maps to, summing to exactly 100; PDF snapshots keep their weights. LPIC-1's frozen weights (101-105 on a /64 scale, 106-110 at 0) get corrected by its switch (#235).

- **LPIC-1 and LPIC-2 switched to canonical objective pages:** both certifications now pin `exam-101-102-objectives/` and `exam-201-202-objectives/` across `catalog.yaml`, frozen syllabi, topic sources, and 294 material/lab files; LPIC-1's 42 frozen weights, 125 weight headings, and Exam 101/102 labels in topics `105`–`110` now match the official LPI 5.0 objective table (#235).

- **Lab credit needs proof:** a topic's quality score counts its lab only when `deploy/lab-evidence.yaml` proves the lab as it is now (run link or log sha256 and the current lab hash); a bare `verified:` in `lab.yaml` now shows as "claimed, not proven", so 11 labs lost that credit until their runs are recorded (#217).

- **Fenced code blocks in the material are syntax-checked:** `scripts/lint_content.py` (`make lint-content`, and in `make verify-ci`) runs `bash -O extglob -n` on `bash`/`sh`/`shell`/`console` blocks (prompt lines only in transcripts, `<placeholder>` tokens masked) and PyYAML on `yaml`/`yml` blocks against a shrink-only baseline of 192 legacy blocks (`tests/fixtures/lint_content_baseline.txt`), with optional `--shellcheck` and `--kubeconform` flags (#207).

## Upgrade notes

<!-- What an operator must do or watch when upgrading (a new required value, a changed default). -->

## Thanks

<!-- Only for credit the script cannot find, e.g. a reviewer or a reporter: `- @user for what (#N)`.
     Authors of merged outside PRs are added automatically as `@user (#N)`. -->
