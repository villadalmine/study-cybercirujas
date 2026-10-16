# Governance

How decisions are made here. Short on purpose: it will grow when the
community does, through the process it describes.

## Who maintains what, today

| Area | Maintainer |
|---|---|
| Everything (code, content pipeline, site, releases) | [@villadalmine](https://github.com/villadalmine) |

A maintainer reviews and merges pull requests, triages issues, and is the
tie-breaker when a discussion does not converge. Maintainers are listed here
and nowhere else.

## Day-to-day changes

Content corrections, translation fixes, new labs, bug fixes and small
features: open a pull request following [CONTRIBUTING.md](CONTRIBUTING.md).
If the checks pass and a maintainer approves, it is merged. No proposal needed.

## Proposals (RFCs) — for anything that changes how the project works

Use a proposal for: changing [the principles](docs/PRINCIPLES.md) or this
document, adding or dropping a certification family or a language, changing
the lab contract or the provenance format, adding a dependency on any
external service, or changing what the checks enforce.

1. **Open** an issue with the *Proposal (RFC)* form (it is titled
   `RFC: <what>` and labelled `proposal`), or a GitHub Discussion in a
   *Proposals* category once Discussions are enabled, with: the problem, the proposed change, alternatives
   considered, and how it will be checked (a principle without a check is a
   wish).
2. **Comment period: 14 days** from opening. Anyone may comment. The author
   updates the proposal as it evolves.
3. **Decision.** Lazy consensus: if no maintainer and no contributor with a
   merged pull request has raised an unresolved objection by the end of the
   period, it is accepted. Otherwise the maintainers decide, and write down
   why in the discussion.
4. **Record.** An accepted proposal lands as a pull request that changes the
   relevant document, check or code, and links the discussion. The next release's
   CHANGELOG.md records it (written by release-please from the PR title).

## Releases

Versions are SemVer 0.x, cut by release-please from the Conventional Commit titles of merged PRs. The
maintainer decides **when** by merging the Release PR (about every 4 weeks, when the `vX.Y.0` milestone is
done; patches on demand for wrong content, a broken lab or a security fix). Milestones plan a release, the
Release PR records it. The full rules: [CONTRIBUTING.md -> Releases](CONTRIBUTING.md#releases). Moving to
`1.0.0` is a decision under the RFC process above.

## Becoming a maintainer

Anyone with a sustained record of merged, reviewed contributions in an area
can be proposed (or propose themselves) as maintainer of that area, through
the proposal process above. Areas can be as narrow as a certification family
or a language. A maintainer who steps away is moved to an *Emeritus* list.

## Code of conduct

Everyone participating follows the [Code of Conduct](CODE_OF_CONDUCT.md).
