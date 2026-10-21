---
title: The charter
---
# The charter

Eleven rules that are written in stone: they make this project what it is. If a change breaks one, it does not go in; if a piece of
work serves none of them, it goes last. Each rule is one sentence and the check that enforces it. Where nothing enforces it yet, the
word is **convention**, and the gap is listed in [FAQ → Known gaps](FAQ.md#known-gaps).

[PRINCIPLES.md](PRINCIPLES.md) keeps the reasoning; this page is the short version. **Changing the charter needs an issue of type
`type:rfc` and the maintainer's decision** ([GOVERNANCE.md](GOVERNANCE.md#proposals-rfcs--for-anything-that-changes-how-the-project-works)).

| # | Rule | Enforced by |
| :-: | :--- | :--- |
| 1 | **The truth comes from official sources.** Every topic cites the vendor's own documentation, and nothing is invented; what cannot be backed is left out. | `scripts/check_sources.py` and `check_source_chain.py` block in CI; `check_citations.py` and `check_api_facts.py` are network checks run by hand; `check_claims.py` samples whether a page says what is claimed; groundedness runs in `warn` mode ([#41](https://github.com/villadalmine/study-cybercirujas/issues/41)) |
| 2 | **A lab really breaks and really fixes.** break, then the check FAILS, then fix, then PASS, proven on a named target (`kind`, `k3s-incus`, later Killercoda); what cannot be reproduced is code-only or theory-only, never a lab that says OK while broken. | `teach/lab` + `.github/workflows/labs.yml`; per-target evidence ([#103](https://github.com/villadalmine/study-cybercirujas/issues/103)); the tiers are [RFC #210](https://github.com/villadalmine/study-cybercirujas/issues/210) |
| 3 | **Deterministic and reproducible.** Inputs are pinned (syllabus hash, sources, model, prompt, lockfile), and a check gives the same answer twice without a network. | `tests/test_determinism.py` (`make determinism`), `requirements.lock`, `tests/netguard/` |
| 4 | **Provenance is visible.** Every file says where it comes from: source, the real model (not an alias), date, human edits and where it was proven. | `scripts/check_provenance.py`, `meta.yaml` per topic, `scripts/check_pr.py` |
| 5 | **The code in the material is valid.** Commands, manifests and scripts pass syntax, lint and current APIs. | `scripts/check_manifests.py`, `check_k8s_apis.py`; commands and code blocks are **convention** ([#207](https://github.com/villadalmine/study-cybercirujas/issues/207)) |
| 6 | **Docs are code.** One source of truth per fact, generated files carry a `--check`, and a change that alters behaviour updates the FAQ in the same PR. | `scripts/check_docs.py` in CI (`docs.yml`); the FAQ rule is **convention** (a PR checkbox) |
| 7 | **Independent review, maintainer-controlled merge.** A second model reviews every PR, and high and medium findings block. Merges are done by the maintainer, or by the maintainer's session under these rules: no blocking findings, green CI, and the merge pinned to the reviewed head commit. The author of a change never merges it. | **convention + findings ledger**: `docs/REVIEWS.md` and the ledger checked by `scripts/check_pr.py`; branch protection requires no approvals today |
| 8 | **Sovereign and cheap.** Everything runs on your own machine with no account, and no money is spent where a free deterministic check will do. | `tests/test_smoke.py` offline, `tests/netguard/`, spend in `usage.jsonl` (`make metrics`); spending approval is **convention** |
| 9 | **Honest about the gaps.** What is not met is said: "not tested" never means "broken", and "AI beta" never means "Verified". | [FAQ → Known gaps](FAQ.md#known-gaps), the quality audit ([#166](https://github.com/villadalmine/study-cybercirujas/issues/166)), the quality level shown on every page |
| 10 | **Open to everyone, with credit.** Anyone can contribute or audit with the public rubric, and every outside contribution is thanked in the release notes. | [CONTRIBUTING.md](../CONTRIBUTING.md), `scripts/release_notes.py` (generated Thanks), `.all-contributorsrc` |
| 11 | **What gets fixed becomes a control.** Every fix ships the test, check or guard rule that prevents the same failure from coming back, and its why, what and how are written down: the decision, the issue, the PR and the process document. | the test or check added by the fix itself; the PR template's evidence and known-gaps sections and the findings ledger checked by `scripts/check_pr.py`; whether a given fix really added its control is **convention** checked in review |

## How to use it

- **Reviewing a PR:** a violation of a rule is a high or medium finding. A rule marked **convention** is still a rule; it only has no
  automatic check yet.
- **Prioritising:** work that serves rules 1 and 2 comes first, then 3 and 4, then 5 and 6, then 7 and 8; rules 9, 10 and 11 are always on.
