# Can a cheap model do the translation step?

Measured on 2026-08-03, not estimated. Reproduce with `scripts/translation_study.py`.

The rule being tested is the one written into `pipeline.yaml`: **quality first, cost
second — a cheaper model is only acceptable where it provably does not degrade the
material.** This is the proof, or the refusal.

## Why translating and authoring are different problems

Authoring turns a one-line syllabus entry into 10 KB of correct technical material.
Its quality tracks model strength directly, and there is no way to check the result
mechanically — a confident wrong explanation looks exactly like a right one.

Translating restates material whose substance is already fixed by the source. Its
failure modes are mechanical, and every one of them is detectable: summarising
instead of translating, dropping sections, translating command flags or YAML keys,
losing citation URLs. `_verify_translation` checks all of them deterministically.

So the question is not "is the cheap model as smart" — it is "does the cheap model
damage the material in a way the checks would catch". That is measurable.

## Method

Same topic, same prompts (imported from `generator.py`, never re-typed, so the study
cannot drift from what the pipeline does), `temperature: 0`, through the LiteLLM
proxy. Every output goes through both gates the pipeline applies: `_verify_translation`
and the `pipeline.yaml` quality floor.

Source: `certs/cks/1.1/es/content.md` — 10023 bytes, 20 code blocks, 11 headings.

## Results

| Model | Verdict | Time | Cost / file | Failure |
|---|---|---|---|---|
| `claude-sonnet` | **PASS** 4/4 topics | ~30 s | $0.046–0.062 | — |
| `cheap` (Qwen Turbo) | **PASS** 3/4 first try, 4/4 with one retry | ~25 s | $0.0007–0.0008 | one translated placeholder |
| `kimi-free` | PASS 1/1 | 87 s | free | — |
| `gemini-free` | PASS 1/1 | 241 s | free | — |
| `deepseek-free` | REJECTED | 26 s | $0.0008 | dropped a citation URL |
| `free2` (Gemini Flash) | REJECTED | 29 s | free | summarised — 1.7 KB out of 10 KB |

`free` (Qwen3 Coder) is no longer available on the free tier and returns HTTP 404.

**Prose quality is indistinguishable.** The same paragraph, translated by `cheap`,
`kimi-free` and `claude-sonnet`, differs only in whether inline code markers around
`ingress`/`egress` survive — Claude keeps them, the cheap models drop them. The
technical content is identical. This is the half no automated check covers, so it was
read by hand rather than asserted.

**The cheap model's failures are variance, not incapacity.** The one rejected topic
(cks 2.4) passed on both retries. That matters: a rejection costs $0.0008 and 27
seconds and writes nothing, so the retry policy already in `pipeline.yaml` absorbs it.

## Three bugs this study found in our own checks

**`_verify_translation` rejected every correct translation.** It demanded code blocks
be byte-identical, but comments inside them are prose: the Spanish material explains a
manifest with `# a qué pods se aplica`, and the English a student reads has to say
`# which pods this applies to`. The authored English content does exactly that — 12
English comments in cks/1.1 against 2 Spanish ones in the source. Every model failed
this, including Claude. Fixed: comment text is blanked before comparing, the `#`
marker kept so a deleted comment line is still caught. Covered by
`tests/test_translation_verify.py`.

**ASCII diagrams were rejected, and no retry could fix it.** `cheap` translated
`│ cloud-controller-manager (opcional) │` on 3 of 3 attempts — correctly, since a
diagram label is prose. Unlike the cks 2.4 placeholder, this was deterministic, so
kcna/1.1 could never have been translated at all. Fixed: on lines drawn with box
characters, labels are blanked but the box characters must keep their exact column
positions, so a translation that re-pads correctly passes and one that leaves the
diagram misaligned is still rejected. `+`, `-` and `|` are excluded from the box
character set on purpose — they appear in ordinary commands, and a shell pipeline
must stay compared exactly.

**Placeholders are left strict, deliberately.** The authored English content also
translates placeholders (`<namespace>`, `<serviceaccount>`), so `<pod-ip-destino>` →
`<destination-pod-ip>` is arguably correct. It is still rejected, because `<none>`
appears identically in both languages — it is real `kubectl` output, and no pattern
separates the two cases reliably. Rejecting costs a cheap retry; accepting would let
corrupted terminal output ship silently. Quality first, cost second.

## What this actually saves

Dollars are not the constraint — Claude is free within its windows, and the whole
remaining translation workload costs about **$0.05** on `cheap` either way. The
constraint is *Claude quota*, and that is what translating buys back.

Of 117 pending combinations:

- **32 are translatable** (a good Spanish source exists): cks/en 14, kcna/en 13,
  cnpe/en 5.
- **85 must be authored** (no source to translate from): cnpa es+en 54, cnpe es 18,
  cnpe/en 13.

Authoring those 32 on Claude costs roughly **3.7 hours of quota** (~7 min/topic).
Translating them costs ~$0.05 and about 25 minutes, and frees that entire quota window
for the 85 that genuinely need a strong model. Once cnpa/es and cnpe/es are authored,
their English siblings become translatable too.

## Translating is not the same deliverable as authoring

Worth stating plainly, because the cost numbers above make translation look strictly
better and it is not. Where English was **authored**, it came out substantially richer
than its Spanish sibling: across the 12 cks topics that have both, the English is a
median **2.34×** the size of the Spanish (up to 10.27×). A translation is ~0.98×, by
construction — it restates the source and nothing more.

So the choice is per certification, and it is about consistency:

- **cks** already has 12 authored English topics. Translating the remaining 14 would
  leave half the certification rich and half thin. Finish it by authoring.
- **kcna** has no English at all. Translating all 13 produces a uniform certification
  that faithfully matches the Spanish, and costs ~$0.02 instead of ~1.5 h of quota.
- **cnpe / cnpa** have no usable Spanish yet, so there is nothing to translate from.
  Author Spanish first; the English decision comes after.

## Recommendation

- **Translate with `cheap`**, retries on. Verified equal in prose, 60× cheaper than
  `claude-sonnet`, and every failure mode it has is one the gates catch before writing.
- **Author with `claude`.** Unchanged. Nothing here argues for a weaker model on the
  reasoning half, and nothing can check that half automatically.
- **Do not use `free2` or `deepseek-free`.** They fail on substance — summarising and
  dropping citations — which is the one thing that must never happen silently.
- Re-run this study before trusting a new model. It is one command.

## Caveat

Single-topic samples for the free models; `cheap` and `claude-sonnet` were measured
across four topics. `free2` returned a passing-length output on one run and a 1.7 KB
summary on the next, so variance between runs is real and one sample is not a verdict
— it is why the gates run on every file, every time, rather than on a sample.
