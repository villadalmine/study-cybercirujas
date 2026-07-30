# Content Workflow

How study content gets created, verified and published, and how to continue the
work with a different AI backend. Design rationale lives in [PLAN.md](PLAN.md);
what is pending is in [BACKLOG.md](BACKLOG.md).

## First, the thing that surprises everyone

**`--lang en` does not translate anything.** It regenerates the topic from
scratch, in English, from the syllabus metadata alone.

`generate_topic()` in `teach/core/generator.py` builds its prompt from
`_topic_context()` — certification, exam, topic id, title, exam weight, and the
official source URLs. It never opens `certs/<cert>/<topic>/es/content.md`. The
only thing the target language changes is one line in the system prompt
("write in \<language\>").

Three consequences that matter:

1. **Language versions are siblings, not copies.** The English version of a
   topic can use different examples, a different structure, even a different
   heading style from the Spanish one. Diffing them is meaningless.
2. **Cost is authoring cost, not translation cost.** Measured at ~7 minutes and
   two full completions per topic (content + exercises), regardless of whether
   another language already exists.
3. **A small/cheap model is the wrong tool for this.** It is writing exam-grade
   technical material from a one-line syllabus entry, not restating existing
   prose. Model quality shows up directly in the output.

If what you actually want is cheap translation — feed the existing Spanish
content to a small model and ask for the same text in another language — that is
a **different feature that does not exist yet**. See "Real translation" in
BACKLOG.md. It would be far cheaper and would keep languages in sync, at the
cost of every language inheriting the Spanish version's structure.

## Everything the pipeline produces is declared in `pipeline.yaml`

Which certifications are active, which languages each is expected to have, how
many topics one run may generate, which errors are worth retrying, and which
languages get a video. Scripts read it; none of them keeps its own list.

That is not a style preference. Two scripts used to hold their own copy of
"which certs in which languages" and both drifted, silently: the audit reported
*0 corrupt* for combinations it had simply never been told about, three separate
times. A missing entry produced a clean bill of health rather than an error.

```yaml
languages:
  default: [es, en]              # every active cert is expected to have these
  on_demand: [pt, fr, de, zh, ja]

budget:
  topics_per_run: 2              # a run generates at most this many
  fatal_errors: ["spend limit"]  # stop; retrying cannot help
  retry_errors: ["529", "500"]   # transient; try again

certs:
  cks: {active: true, video: [es]}
  lfcs: {active: false}          # declared, not automated yet
```

`active: false` keeps a certification out of automatic work, so one nobody has
started does not flood the audit. Flip it in the same commit that starts it.

Read it from Python via `teach.core.pipeline`:

```python
from teach.core import pipeline
pipeline.targets()          # [(cert, [langs]), ...] for active certs
pipeline.topics_per_run()   # batch budget
pipeline.is_fatal(msg)      # quota exhausted vs transient
```

## The loop

```
snapshot  →  generate  →  audit  →  status  →  commit  →  publish
(once per     (per topic   (always) (always)   (freely)  (only when a cert
 syllabus)     × language)                                is COMPLETE)
```

Language order is Spanish, then English, then the on-demand tier — `es` is the
source language everything else is checked against, and `en` is the widest
audience. Videos come last, after content exists and has been audited.

### The syllabus-change trigger

Re-snapshotting a certification detects what actually changed and marks only
those topics for regeneration:

```bash
teach cert snapshot cks --force
#   cks: 26 topics congelados (v1.34)
#   stale (2): 3.2, 4.1
#   → cambió el temario; regenerar con 'teach cert generate cks --lang <idioma>'
```

`snapshot_topics` compares each incoming topic against the stored one on
**title, domain and weight** — the three things that reach the model as prompt,
weight included because it sets the requested depth. Anything else changing
(most often the source URL, which gains a version number without the material
changing) does not invalidate content, or every re-snapshot would mark
everything stale. Unchanged topics keep their status; new ones are `pending`.

**A `stale` topic regenerates in every language, not just Spanish.** This is the
part that is easy to get wrong. The status lives on the topic, but content
exists once per language and is regenerated one language at a time — so clearing
the flag as soon as Spanish is rebuilt would leave the translations describing
the old syllabus, silently and permanently. The topic therefore records
`stale_since`, and each language is compared against it via its own
`meta.yaml.generated_at`:

```
topic 1.1  status: stale, stale_since: 2026-07-30T03:00
  es/meta.yaml  generated_at: 2026-07-30T04:00   → current
  en/meta.yaml  generated_at: 2026-07-28T10:00   → outdated, regenerates
```

The topic returns to `generated` and drops `stale_since` only once no language
is behind. A language whose `meta.yaml` is missing or unreadable counts as
outdated — if freshness cannot be proven, it is regenerated.

**Content marked `edited`** (enriched by hand) is never overwritten. When the
syllabus changes underneath one, the snapshot reports it separately so a person
decides, rather than discarding manual work automatically.

The cycle is covered by `tests/test_stale_cycle.py` — including the ordering
case above, which is the one worth protecting.

Still manual: **re-rendering the certification video** after a syllabus change.
Its domain-weight scene is derived from the topics that just changed, so it goes
out of date with them.

### 1. Snapshot the syllabus — once per certification

```bash
teach cert snapshot <cert> --backend <ai>
```

Downloads the official objectives (HTML or PDF) and freezes them as YAML topics
in `certs/<cert>.md`. Existing per-topic statuses are preserved.

Two traps, both hit for real:

- **Weights.** CNCF PDFs give a weight per *domain*, not per sub-topic. Copying
  the domain weight onto each sub-topic makes the total sum to 360 instead of
  100. `tracker.py::snapshot_topics` now rejects a snapshot whose weights do not
  sum to ~100, so this fails loudly — but check the number anyway.
- **Copyright.** Scraped text is processed in memory and never written to disk.
  Only structured metadata (id, title, topic, weight, source URL) is persisted.
  Do not change this.

### 2. Generate

```bash
teach cert generate <cert> --lang <lang> --backend <ai>            # all pending topics
teach cert generate <cert> --topic <id> --lang <lang> --backend <ai>   # one topic
```

Writes `certs/<cert>/<topic>/<lang>/content.md` and `exercises.md`, plus a
shared `lab/break_fix.sh` (one per topic, not per language — only regenerated
when `lang` is the default).

**Idempotent, per language.** `generate_topic` skips a topic when the target
language directory already has content (`already = lang in topic_langs(...)`),
so an interrupted run is resumed by simply re-running the same command. Nothing
to clean up, no flags to remember. `--force` overrides; topics marked
`status: edited` are never overwritten without it.

**Generate in small batches.** Two or three topics per launch, not a whole
certification. API credits are a real constraint here and a long run that dies
halfway leaves a partial cert either way.

### 2b. The quality floor — the same standard for every backend

A different model must not mean a different standard. The floor lives in
`pipeline.yaml` under `quality` and is applied in three places from that one
definition:

- **The generator, before writing.** Substandard output raises and nothing is
  saved. This is the important one: material written to disk gets marked
  `generated`, and is then only discovered by an audit somebody has to remember
  to run.
- **The audit** (`fix_corrupted_content.py`), which queues it for regeneration.
- **`STATUS.md`**, which counts only material that passes. A file that exists
  but is below the floor is pending work, not finished work.

It checks two things — size, and the structure the prompt explicitly asked for:

| | content.md | exercises.md |
|---|---|---|
| minimum size | 4000 bytes | 1700 bytes |
| must start with | `#` | `#` |
| must contain | a references section (any of the 7 languages) | the `<details>` collapsible answers |

The thresholds are calibrated against 270 files of verified content, whose
observed minimums are 4577 and 1778 bytes — the floor sits deliberately below
those, so it never rejects material already known to be good. It is a floor,
not a target; the median of good content is roughly 8700 bytes.

The structural half matters more than the byte count. A run can hit the size
and still ship exercises with no answers section, which is exactly what
happened: a certification generated 18 of 18 exercises without `<details>`
while reporting 100% complete.

```bash
scripts/quality_report.py             # what passes, what does not, and why
scripts/quality_report.py cnpe cnpa   # specific certs, including inactive ones
```

This costs nothing to run — it reads files, it does not generate.

### 2c. What "quality" can and cannot be proven mechanically

The floor above proves the material is not a stub. It does **not** prove the
explanation is correct, and no check in this repo does. That is worth stating
plainly, because a 10 000-byte topic with a references section and valid YAML
can still teach something false with complete confidence.

What is checked, and what each one actually establishes:

| Check | Command | Proves | Does not prove |
|---|---|---|---|
| Structural floor | `make quality` | Not a stub; has the sections the prompt required | Anything about correctness |
| Recap guard | automatic, in the generator | The backend returned material, not a summary of its own actions | — |
| Citation liveness | `scripts/check_citations.py` | The cited sources exist | That they support the claim made |
| Manifest syntax | `scripts/check_manifests.py` | Embedded YAML/JSON parses | That the fields are real API fields |

**Citation liveness is the closest thing to a hallucination detector here**, and
it is still indirect. It catches a specific and common signature: the invented
documentation URL — plausible, correctly shaped for the official site, and
nonexistent. Two real examples found in this repo:

```
https://kubernetes.io/docs/tasks/debug/debug-application/debug-ephemeral-container/
    → real page is .../debug-running-pod/#ephemeral-container
https://kubernetes.io/docs/reference/config-api/apiserver-encryption.v1/
    → does not exist
```

A model that invents the source backing a claim is often inventing the claim
too. Roughly 1–3% of citations fail this way. It only inspects the References
section — URLs inside code blocks are examples (`http://app.example.com`,
cluster addresses), not citations.

Both checkers were tuned against real content until they stopped crying wolf,
which matters more than coverage: a check that reports false positives gets
ignored, and then reports nothing. The manifest checker skips Helm/Go templates
(invalid as plain YAML **by design**), shell heredocs mislabelled as `yaml`,
indented fragments of a larger manifest, and elided output. With those
exclusions it currently reports **0 defects across 685 files** — the embedded
manifests are clean, and its value from here is as a regression guard.

**What would actually verify correctness**, none of it implemented:

- **Schema validation against the real Kubernetes API** (`kubeconform`, or
  `kubectl apply --dry-run=server`). This is the big one for this project:
  syntax checking accepts an invented field like `spec.replicaCount`, and schema
  validation rejects it. Deterministic, free, no model. The clearest next step.
- **Running the labs.** `break_fix.sh` is executable ground truth: if the
  content teaches something wrong about a topic, the lab exercising it fails.
  This is blocked on the same untested-labs item in BACKLOG.md.
- **Judging claims against the cited page**, by fetching the source and asking a
  model which assertions it does not support. The only approach that addresses
  prose directly, and the only one that costs API budget per check.

### 3. Audit — never skip this

```bash
.venv/bin/python3 scripts/fix_corrupted_content.py
```

Reports corrupt or missing combos and regenerates them. Two failure modes it
exists to catch:

- **Recap stubs**: the agent CLI acting as a coding agent and returning *"Wrote
  certs/.../content.md"* instead of the content. `generator.py` now blocks this
  at the source (`--disallowedTools` for the claude backend, plus
  `_reject_if_recap` on every completion, checking first *and* last line), but
  the audit is the backstop.
- **Holes**: topics that were never generated, or half-generated when a process
  died between the content and exercises completions.

**Add the cert/language pair to `TARGETS` in the same commit that generates it.**
The audit only sees what is listed there. This has been the source of three
separate blind spots — an audit reporting "0 corrupt" proves only that the
combos it scans are clean. There is a second list in
`scripts/resume-generation.sh`; keep both in sync.

### 4. Status

```bash
.venv/bin/python3 scripts/status_matrix.py
```

Regenerates `STATUS.md` by counting files on disk. Never edit it by hand, and
trust it over any status field. Partial translations show as `🔶 8/26c·8/26e`.

### 5. Commit

Commit partial progress freely — it is safe and expected.

### 6. Publish — only for a complete certification

Content is baked into the image, so publishing means rebuild + upgrade:

```bash
make image-cluster TAG=20260730020000
make deploy-local  TAG=20260730020000
```

**Pass the same explicit `TAG` to both.** `TAG` defaults to
`$(shell date +%Y%m%d%H%M%S)`, evaluated per invocation — omit it and the two
commands generate different timestamps, so the deploy points at an image that
was never built.

**Do not publish a partially translated certification.** It is technically safe
(`certs.py::topic_content` falls back to Spanish for any missing language and
reports `lang_fallback`), but the rule is one image build per finished cert.

## Backends

Selected by `--backend`, `BACKEND=` or `$TEACH_BACKEND`. Default: `litellm`.

| Backend | Invocation | Configuration |
|---|---|---|
| `litellm` | OpenAI-compatible HTTP API | `LITELLM_BASE_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL` (all three required) |
| `claude` | `claude -p --disallowedTools ... --` | Claude Code CLI on `PATH` |
| `codex` | `codex exec` | Codex CLI on `PATH` |
| `gemini` | `gemini -p` | Gemini CLI on `PATH` |
| `custom` | `$TEACH_AGENT_CMD` | any command; receives `"<system>\n\n<user>"` as its last argument |

All of them satisfy one interface — `complete(system, user) -> str` — so a
backend is interchangeable at any point. You can generate half a certification
with one and finish it with another; nothing in the content records a
dependency on the tool that produced it beyond `meta.yaml`.

### Switching to Gemini (or any CLI agent)

```bash
teach cert generate cks --topic 3.2 --lang en --backend gemini
```

One caveat specific to CLI-agent backends. The `claude` entry passes
`--disallowedTools` to stop the CLI from behaving like a coding agent — the bug
where it explores the repo, writes files itself, and returns a summary of that
action, which then gets saved *as* the study content. `gemini` and `codex` are
invoked without an equivalent flag, so they can in principle do the same thing.
`_reject_if_recap` catches it and fails the run loudly rather than saving a
stub, so nothing corrupt reaches disk — but if a backend fails this way
repeatedly, add its tool-restriction flag to `AGENT_COMMANDS` rather than
working around it.

For `litellm` there is no such concern: it is a plain chat completion with no
tool loop.

## Failure modes worth knowing

| Symptom | Cause | What to do |
|---|---|---|
| Run reports success, few files produced | Command piped through `tee` — the pipeline exit status is `tee`'s, so failures surface as exit 0 | Redirect instead of piping; check the file count |
| `You've hit your monthly spend limit` | Quota exhausted | Retrying will not help. Stop, resume when it resets |
| `API Error: 529 Overloaded` | Transient server-side | Retry; a single 529 otherwise kills a multi-hour run |
| Audit says 0 corrupt but content is missing | The combo is not in `TARGETS` | Add it, re-audit |
| Empty log while a run is clearly working | Python block-buffers stdout when it is not a tty | `PYTHONUNBUFFERED=1` |

## Unattended runs and quota

**The window cannot be computed, only observed.** The spend limit that stopped
generation on 2026-07-29/30 came back partway through a day and then ran out
again, so it is not a simple monthly reset and no arithmetic will predict it.
The only reliable answer is a cheap probe:

```bash
scripts/quota.py              # probe now, exit 0 if quota is available
scripts/quota.py --quiet      # exit code only, for use as a gate
scripts/quota.py --history 20 # when it changed, marked <-- CHANGED
scripts/quota.py --wait 7200  # block until it returns, giving up after N seconds
```

The probe asks for two characters, so it costs almost nothing, and it
classifies the result with the same `fatal_errors` list from `pipeline.yaml`
that the batch runner uses — "out of quota" means one thing project-wide. Every
probe is appended to `~/.local/state/teach-plat/quota-history.jsonl`, which
after a few days is the actual empirical record of when windows reopen.

`scripts/resume-generation.sh` runs one bounded pass per firing: it probes
quota first and exits without spending anything when the window is closed, it
holds a `flock`, and it skips when a generation is already running. The work
itself comes from `fix_corrupted_content.py`, which derives the queue from
`pipeline.yaml` and stops at `budget.topics_per_run`.

The units are versioned in `deploy/systemd/`. Two failure modes were found in
the original ones and are worth not reintroducing:

- **`OnBootSec` + `OnUnitActiveSec` silently stop scheduling.** On a machine up
  for days those deadlines elapse and `systemctl list-timers` shows
  `Trigger: n/a` — enabled, active, and never firing again. The timer now uses
  a wall-clock `OnCalendar=*:0/20`, which always has a next elapse. Check with
  `systemctl --user list-timers teach-resume.timer`; if `NEXT` is empty, it is
  not going to run.
- **The unattended pass used to be unbounded.** It looped
  `teach cert generate <cert> --lang <lang>` with no `--topic`, generating every
  pending topic for that combination and ignoring the batch budget entirely.

```bash
systemctl --user enable --now teach-resume.timer   # spends quota on its own schedule
systemctl --user list-timers teach-resume.timer    # confirm NEXT is populated
tail -f ~/.local/state/teach-plat/resume.log
```
