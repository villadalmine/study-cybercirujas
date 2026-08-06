# Which backend authors better material?

Measured 2026-08-06 across the whole corpus — 434 authored topics, translations
excluded. Reproduce with `scripts/check_manifests.py`, `check_k8s_apis.py`,
`check_citations.py` and `quality.check_file`; none of it costs API quota.

## The headline: on every objective check, they tie

| Check | `claude` (opus-5 / fable-5) | `gemini` (agy) |
|---|---|---|
| Sample | 310 topics | 31 topics |
| Below the quality floor | **0%** (1 of 620 files) | **0%** (0 of 62) |
| Embedded manifests parse | 40/40 | 31/31 |
| Removed Kubernetes APIs taught as current | none | none |
| Citations that resolve | 100% | 100% |

No hallucinated sources, no broken YAML, no deprecated APIs, on either. The
quality floor and the checkers cannot separate them, and those are the only
things that can be verified mechanically.

## Where they differ: volume and shape

| Median per topic | `claude` | `gemini` |
|---|---|---|
| content.md | 8,820 bytes | **28,995 bytes** |
| exercises.md | 11,917 bytes | 27,731 bytes |
| Code blocks | 14 | **31** |
| Headings | 17 | **55** |
| Comparison tables | **4** | 0 |
| Cited URLs | 8 | 8 |

`gemini` writes **3.3x more material** with more than twice the examples. It also
fragments it far more finely (55 headings against 17) and, notably, produces
**no comparison tables** where `claude` averages four. Same citation discipline.

**More is not automatically better.** Three-times-longer material takes three
times as long to read, and a student's time is a real cost. What can be said with
evidence: `gemini` is not thinner, and it is not less accurate. Whether 29 KB per
topic is better pedagogy than 9 KB is a judgement about the reader, not a
measurement — decide it deliberately rather than by which backend happened to be
configured.

## The 62% figure, and why it is not what it looks like

A first pass showed `antigravity` with 73 of 118 files below the floor — 62% — and
that number is misleading. Broken down by date:

| Date | Topics | Below floor |
|---|---|---|
| 2026-07-30 | 39 | **34 (87%)** |
| 2026-08-05 | 1 | 0 |
| 2026-08-06 | 19 | **0** |

Almost all of it is the July 30 run — the one that **motivated creating the
quality floor** (`pipeline.yaml` records it: ~2999 and ~1109 bytes per topic,
about a ninth of the median). It is legacy content that predates the guard, not
evidence about the backend.

Everything produced on August 5–6, through the paved path, clears the floor. That
is the real result: **the guard works, and it works for every backend equally.**

## What this means for the choice

- **Any backend may author.** There is no measurable quality reason to prefer one,
  which is why `CLAUDE.md` restricts traceability rather than provider.
- **The floor is what protects quality, not the model.** The same backend produced
  87% substandard material before the floor existed and 0% after. That is the
  strongest evidence in this document, and it is about the process rather than
  about any model.
- **Cost still differs and is worth watching.** `claude` on the owner's
  subscription costs quota windows, not money: ~$2.10–2.75 and ~40–80k output
  tokens per authored topic, roughly four topics per ~4.2 h window
  (`scripts/usage_report.py` has the live numbers). Price `gemini` the same way
  before assuming either is cheaper.

## Caveats

31 `gemini` topics against 310 `claude` ones is an unbalanced sample, and they are
not the same topics: `gemini` authored the LPIC-3 branch, `claude` most of the
CNCF ones. Subject matter affects length — the cks English content runs 2.55x its
own Spanish while cka, ckad and lpi sit at 0.91–1.05, so a single certification
can skew a median. A same-topic head-to-head would settle it and has not been run.
