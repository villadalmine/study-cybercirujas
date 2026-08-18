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

## The same-topic head-to-head, which reverses the conclusion above

Run 2026-08-06 on `lpic-1/1.1` "System Architecture" — identical topic, identical
prompt, the only variable being the model. This is the comparison the corpus-level
numbers could not make, and it disagrees with them:

| | `gemini` (agy) | `claude-opus-5[1m]` |
|---|---|---|
| content.md | 10,115 bytes | **67,783** (6.7x) |
| Code blocks | 5 | **52** (10x) |
| Cited URLs | 4 | **39** (10x) |
| Headings | 21 | 60 |
| Comparison tables | 0 | **54** |
| Quality floor | OK | OK |
| Cost | not measured | $2.55 (incl. one retried completion) |

**Why this contradicts the corpus medians.** Those compared *different topics*:
`gemini` authored the LPIC-3 branch — dense, advanced material — while the
`claude` sample spans 310 topics across many months, models and prompt versions.
Subject matter was the confound, and it was large enough to invert the result.

Take the same-topic number as the better evidence, with the obvious caveat that it
is **one topic**. On this one, opus-5 produced an order of magnitude more examples
and citations, and 54 comparison tables where `gemini` produced none — which
matches the corpus-level observation that `claude` uses tables and `gemini` does
not, and suggests that difference is a real stylistic property rather than noise.

What has NOT been shown: that longer is better for a student. 68 KB is a long read.
The honest summary is that opus-5 produces markedly more *material* per topic, both
backends produce *sound* material, and whether the extra 58 KB earns its place is a
judgement about the reader that no check here can make.

## Caveats

31 `gemini` topics against 310 `claude` ones is an unbalanced sample, and they are
not the same topics: `gemini` authored the LPIC-3 branch, `claude` most of the
CNCF ones. Subject matter affects length — the cks English content runs 2.55x its
own Spanish while cka, ckad and lpi sit at 0.91–1.05, so a single certification
can skew a median. A same-topic head-to-head would settle it and has not been run.

## fable-5 vs opus-5, within cgoa (2026-08-19)

The owner asked which model delivers better material. Designed as the clean
in-cert experiment: cgoa freshly snapshotted, four domains, `1.1`+`2.1`
authored on `claude-fable-5` (explicit `TEACH_CLAUDE_MODEL` pin), `3.1`+`4.1`
on `claude-opus-5` (the pipeline declaration), same day, same prompts, same
`effort: xhigh`, same quality floor. Authoring language only — the overnight
run demonstrated why that filter exists: es translations rode into the table
attributed to the translating model until `--lang en` was added.

Numbers at the time of writing (`scripts/model_comparison.py --cert cgoa
--lang en`; MODELS.md regenerates them continuously):

| model | topics | KB/topic | ktok/topic | KB/1k | min/topic | topics/window | KB/window |
|---|---|---|---|---|---|---|---|
| claude-fable-5 | 2 | 52.0 | 58.3 | 0.89 | 12.6 | 12.2 | 637 |
| claude-opus-5 | 1–2* | 164.7 | 206.3 | 0.80 | 42.2 | 3.5 | 570 |

\* one opus topic was claim-excluded (being translated) when this was written;
MODELS.md shows the settled figures.

**Reading, with the thin-evidence caveat (n=2 per side):**

- **Per topic, opus-5 writes ~3x the material** (165 vs 52 KB) with more code
  blocks and citations — same pattern as the kca comparison (opus-5 2.1x
  opus-4-8). fable-5's topics pass every floor and check; they are simply a
  third the depth.
- **Per window they deliver similar total material** (637 vs 570 KB), split
  differently: fable finishes ~3.5x more topics, each shallower; opus
  produces fewer, deeper ones.
- **Both models are equally traceable and equally clean** — 100% floor pass,
  citations resolving. Nothing here measures truth (docs/AUDITOR_DESIGN.md).

**Verdict for this repo:** unchanged. The owner's declared constraint is
depth/quality per topic, not topics per window ("no me importan las
ventanas", 2026-08-13) — so `claude-opus-5` at `xhigh` stays the authoring
setting. fable-5 is a reasonable choice where breadth-per-window matters
more than depth, which is not this project's trade.
