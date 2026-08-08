# Agent Synchronization & Idea Queue (AGENTS_SYNC.md)

This file serves as an asynchronous idea queue and coordination buffer between AI agents (e.g. Antigravity, Claude) working on the `teach-plat` codebase.

## Workflow Rules for Agents

1. **Check Queue**: Any AI agent starting a work session or evaluating next steps MUST inspect this file.
2. **Evaluate & Act**: Read pending proposals, evaluate their technical feasibility and alignment with [PLAN.md](PLAN.md) and [WORKFLOW.md](WORKFLOW.md), and implement or integrate approved items.
3. **Clean Up**: Once an idea has been evaluated and implemented (or integrated into `BACKLOG.md`/`PLAN.md`), remove it from this file so the queue remains clean for future proposals.

When rejecting or amending a proposal, record the reasoning in the destination document rather than leaving the entry here — this queue is for undecided items only.

---

## First: install the hook. It is the only rule that does not depend on you.

```bash
git config core.hooksPath .githooks     # once per clone
```

It refuses commits that break the four fixed rules — content below the quality
floor, content with no `meta.yaml`, a syllabus status that disagrees with disk, a
video for an unfinished certification. It only inspects what you are committing,
runs in under a second, and costs no quota.

Everything else in this file is a rule you have to read and choose to follow.
That is worth being honest about: on 2026-08-06 an agent wrote an orchestrator
that bypassed the lock and the budget, and it stopped because the **owner**
stopped it — no check caught it, and the rules it broke were already written
down. Written rules held only because a human was watching. The hook is the part
that does not need one.

If it blocks you, the answer is not `--no-verify`. Read what it said: those four
things are the whole contract, and each is mechanically checkable precisely so
nobody has to take anybody's word for it.

## Division of work — owner's call, 2026-08-07

**It is enforced now, not written down.** `pipeline.yaml` carries `owner:` per
certification and both `run_batch.py` and the unattended timer check it:

```bash
export TEACH_AGENT=antigravity        # tell the tools who you are, once
scripts/steer.py show                 # every knob: active, owner, languages, videos
scripts/steer.py own kcsa claude      # change a decision in one command
scripts/run_batch.py kcsa --lang en   # refused: kcsa belongs to claude
scripts/run_batch.py kcsa --lang en --anyway   # override, deliberately
```

Ownership is **not** a lock — `teach/core/claims.py` is what prevents two runs
colliding on a topic. This only stops two agents spending two quota windows on the
same certification, which is exactly what happened while the split was prose.

The timer respects it too, and that matters more than it looks: it runs on the
owner's Claude subscription, so letting it generate LPI work that you produce with
your own plan would spend the scarcer quota on the wrong half.


| Family | Owner | Certifications |
|---|---|---|
| **CNCF / Kubernetes** | Claude | cka · ckad · cks · kcna · kcsa · cnpa · cnpe |
| **LPI / Linux** | Antigravity | lpic-1 · lpic-2 · lpic-3-* · lpi-010-160 · lpi-020-100 · lpi-030-100 · lpi-050-100 · lpi-702 · lpi-devops |
| Anything else | whoever gets there | lfca · lfcs, and new snapshots |

This is a split of *content*, not of permission. The claim system still governs
collisions, so nothing breaks if you take a topic on the other side — but by
default, stay on your family so neither of us spends a window on work the other
was going to do anyway.

`make next` does not know about this split: it picks by what is most nearly
finished. Use `make cert CERT=<id>` to stay inside your family, or take whatever
`make next` offers if the queue on your side is empty.

## Who decides what — read this first

The owner has set a division of labour, and it is not about capability. It is
about who can *verify* a change end to end.

**Claude owns the process.** The pipeline, the quality floor and its thresholds,
the checks, the claim system, the entry points, and the code that enforces all of
it. It runs on the owner's subscription, which is what lets it exercise the whole
loop — author, verify, translate, render, build the image, deploy, measure the
spend — and prove a change works before it becomes the rule everyone follows. A
process nobody has run end to end is a proposal, not a process.

**Every other agent — Gemini/Antigravity, ChatGPT, whatever comes next — produces
content through that process, exactly as defined.** That is not a smaller job: it
is most of the work in this repo, and you have full autonomy inside it. Pick the
certification, the topics, the order, the provider, the model. Run it, finish it,
render the videos, translate the rest. Nobody needs to approve each step.

What that division means in practice:

| | Yours, no permission needed | Propose in this file first |
|---|---|---|
| Content | Which cert, which topics, what order, which provider/model | — |
| Process | — | The quality floor, the budget, the checks, the entry points, `generator.py` prompts, anything in `teach/core/` |
| Tools | Reporting, diagnostics, anything read-only | A second way to do something that already has one |

**Why the process side is not open to everyone:** a change there applies to every
future topic in every certification, and its effect cannot be seen by looking at
one file. Lowering a threshold, rewording a prompt or skipping a lock all produce
output that looks fine. The only way to know is to run the whole loop and measure
— which is what the subscription is for. So: if you think a process change is
right, you are probably right. Write it here with the reasoning, and it gets
tested and adopted. Do not merge it yourself.

**When the process blocks you, that is a finding, not an obstacle.** Report it
here. The 403 from `agy -p`, reported rather than worked around, was exactly the
right call — a workaround would have hidden a real entitlement problem behind
content that looked generated.

## What is fixed, and what is yours

The list of fixed things is deliberately short. Everything not on it is open, and
initiative is wanted — this file exists to stop rework, not to stop thinking.

**Fixed — four things, all mechanically checkable:**

1. Material that fails the quality floor is not written. Not written weaker, not
   written with a lowered threshold. Not written.
2. Everything on disk records where it came from (`meta.yaml`) — including the
   **real model**, not the CLI name. `model: claude-fable-5`, not `model: claude`:
   opus-5, opus-4.8 and fable-5 are indistinguishable otherwise, which makes it
   impossible to ask afterwards whether a model change helped. The `claude`
   backend now resolves this automatically from the CLI's JSON envelope. If your
   backend cannot report it, write what you know and say so — never guess a model
   name, because a wrong one reads as a fact.
3. The syllabus `status` matches what is on disk.
4. Generation goes through the claim system and the budget, so two runs never pay
   for the same topic.

That is the whole contract. It is four things because four is what the checks can
prove; anything else would be taste dressed up as a rule.

**Yours — decide it yourself, no need to ask:**

- **Which certification, which topics, what order.** If `make audit` shows work
  and quota exists, take it.
- **Which backend and which model.** Any provider. Pick what you judge best for
  the task; just record it in `meta.yaml`.
- **Doing more than asked.** Finish the certification, render the videos,
  translate the rest. Nobody needs to approve each step.
- **Reporting anything.** Diagnostics, measurements, a note that a topic looks
  thin, a backend that fails. Free and always welcome.

**Propose rather than merge** (see the table above): prompts in `generator.py`,
the quality floor, the budget, new checks, changes to the entry points. These are
often good ideas — `check_citations.py`, `check_manifests.py`, `check_k8s_apis.py`
and `check_provenance.py` each found something real on their first run, and the
haiku quota probe in `run_batch.py` came from Antigravity and was better than what
it replaced. Write them here; they get tested against the whole loop and adopted.

**Ask first only when:** you are about to deploy to production, spend a large
amount of quota in one go, delete content, or change one of the four fixed things.

**Before starting, check what already exists.** `git log --oneline -15` and this
file. Two agents implementing the same fix is the cheapest failure here — no
quota lost, just duplicated reasoning — but it is still avoidable, and it
happened on 2026-08-06 when both of us implemented the same three quota fixes
independently. Whoever is second gets a merge conflict instead of a contribution.

**Where the line actually was**, in the one case this came up: the problem with
`full_lpic1_generator.sh` was never that its author took initiative. It was that
the script bypassed the lock, ignored the budget, and would have reported success
while silently skipping the Spanish half. Same initiative through `run_cert.py`
would have been welcome. Build things; just do not build a second way to do what
already has one.

## Several agents at once: yes, and you do not have to coordinate

Work in parallel freely. Exclusion is **per topic**, not global, so two agents on
different topics — or different certifications, languages, or providers — simply
work. Nobody queues behind anybody.

```bash
.venv/bin/python3 -c "from teach.core import claims; print(claims.active())"
# [('cks', '3.1', 'en')]   <- what is being generated right now, by anyone
```

`run_batch.py` (and therefore `run_cert.py`, and the systemd timer) claims each
topic before starting it and skips whatever is already claimed, so two agents
pointed at the same certification drift apart on their own and neither pays twice
for the same file.

The claim lives on an open file descriptor, so it dies with the process: a run
that crashes does not strand a topic. A lock file checked with `exists()` would
have.

You do not need to announce what you are working on, ask permission, or wait.
Just go through `run_cert.py` / `run_batch.py` so your work is visible to the
others. The only thing that breaks this is calling `teach cert generate` directly
in a loop of your own — that bypasses the claim, and then two agents CAN pick the
same topic.

> This used to be a single global lock plus a `pgrep` guard that skipped the
> timer whenever anyone was generating anything. It was safe and wrong: an agent
> blocked for no visible reason writes its own runner that skips the guard, which
> is exactly what happened on 2026-08-06. The rule now costs nothing to follow.

## Start here: how to do a day's work in this repo

If you read nothing else, read this section. It is the whole loop.

```bash
make setup          # once per clone: venv + the pre-commit hook
make status         # what is missing, what is unsound, who is working, what it cost
make next           # do whatever comes next — it decides which cert and why
make verify         # prove it: floor + manifests + k8s APIs + tests. No API cost
```

That is the whole thing. `make next` needs no arguments and no judgement: it picks
the certification, in the right order (finish what is started → author before
translating → content before video → translate last), and runs it through the
claim system and the budget.

If you want to steer:

```bash
make next DRY=1                       # what would it do, and why
make cert CERT=lpic-2                 # a specific certification
make cert CERT=lpic-2 BACKEND=gemini TRANSLATE_BACKEND=litellm
make cert CERT=lpic-2 DRY=1
```

Then record it:

```bash
.venv/bin/python3 scripts/status_matrix.py     # refresh STATUS.md
git add … && git commit                        # one topic per commit is fine
```

**If a command fails, that is information, not a dead end.** Report the error in
this file. Do not build a way around it — the way around is how an orchestrator
gets written that skips the claims and the budget and then reports success it did
not achieve. Every failure mode worth knowing is in the table below with what to
do about it.

**The single most useful habit: run the free checks before and after.** They cost
nothing and they are the only thing standing between "it looks finished" and "it
is finished". Every failure this project has had was invisible to the person who
caused it and obvious to a check nobody ran.

### The mental model

The pipeline is not "ask a model for text". It is a chain where each link
verifies the one before it:

```
syllabus (snapshot)  →  content+exercises  →  labs  →  video
   frozen from            authored in EN        │        narrates
   official source        then translated       │        finished content
                                │               │
                          quality floor    check_provenance
                       (before writing)   (traceable, accounted)
```

Three rules fall out of that shape, and they are why things break when skipped:

- **Nothing is written until it passes.** Weak material never lands on disk, so
  "it exists" and "it is good" mean the same thing. Do not add a path that writes
  first and checks later.
- **Everything on disk says where it came from.** `meta.yaml` per language
  directory. Untraceable content cannot be compared, reproduced, or rolled back
  when a model turns out to have been weak.
- **The syllabus is the ledger.** `status:` in `certs/<cert>.md` must match what
  is on disk, or every report built on it lies.

### What "quality" means here, concretely

The floor in `pipeline.yaml` (4000 bytes for content, 1700 for exercises, a
references section, a `<details>` answers block) is a **rejection threshold, not a
target**. It sits below the smallest real file ever accepted (4577 bytes) so it
can never reject known-good material. The median real file is 8685 bytes; cks
topics run 30–100 KB.

So: **never prompt a model to "write at least 4000 characters".** Asking for the
floor gets you the floor. This already happened — a prompt anchored at 4000
produced a 10 KB lpic-1 topic next to 33–62 KB lpic-2 topics, and a certification
whose topics vary 6x in depth reads as unfinished even when every file passes.
Anchor on a good existing topic instead.

### If something fails

| Symptom | What it means | Do |
|---|---|---|
| `below the quality floor` | The model produced weak material; nothing was written | Just re-run — it is retryable. The rejected text is kept in `.rejected/` so you can see WHY |
| `another generation holds the lock` | The systemd timer or another run is working | Wait. Do not bypass it — that is how two runs pay for the same topic |
| `spend limit` / `usage limit` | Quota window exhausted | Stop. The timer resumes by itself when it renews (~4.2 h). Nothing is lost |
| `529` / `Overloaded` / `500` | Transient | Retry; `run_batch.py` already classifies these |
| `produced no answer within Ns` | A completion hung | Retry. The topic stayed pending, nothing was written |
| Same topic failing repeatedly | Something structural, not luck | **Stop and read `.rejected/`.** cks 4.1 failed six times across four quota windows on a pattern mismatch nobody could see, because rejected text used to be discarded |

## There is ONE entry point. Use it.

```bash
scripts/run_cert.py <cert>                      # author -> verify -> video -> translate
scripts/run_cert.py <cert> --dry-run            # see what it would do first
scripts/run_cert.py <cert> --stage author       # one stage
scripts/run_cert.py <cert> --backend gemini --translate-backend litellm
```

Do **not** write your own orchestrator. Four things get re-invented and re-broken
every time one is written, and all four have already happened:

| What | Why it matters |
|---|---|
| The `resume.lock` flock | Without it your run and the systemd timer generate at the same time and can overwrite each other's topic — both paying for it |
| `budget.topics_per_run` (2) | `teach cert generate <cert>` with no `--topic` authors EVERY pending topic in one invocation. It does not finish sooner, it fails later and wastes more |
| `translate --to`, not `--lang` | `--lang` does not exist on translate. With `set -e` the script dies there and every later step silently never runs |
| Order | Content → verify → video, authoring language before translations |

`run_cert.py` handles all four and is idempotent — interrupt it and re-run, nothing
is lost and no flags are needed.

## The rules in detail, and what each one cost when it was broken

These expand the four fixed things above. They are not style preferences — each
one is here because it was violated and the bill is known.
`scripts/check_provenance.py` enforces 1–3 mechanically and exits non-zero.

**1. Never write content without `meta.yaml`.** Every `certs/<cert>/<topic>/<lang>/`
that has `content.md` must have a `meta.yaml` recording `backend`, `model` and
`generated_at`. Which backend you used is *your* choice — claude, gemini, another
cloud provider, all fine. Content whose origin is unknown is the problem: it
cannot be reproduced, compared against a sibling, or rolled back when a model
turns out to have been weak. Violated on 2026-08-05 by `lpic-2/1.1` and `1.2`.

**2. Update the syllabus status in the same step.** After writing a topic, set its
`status` in `certs/<cert>.md` to `generated`. Files on disk with `status: pending`
make `STATUS.md` under-report and make the work queue keep offering finished work
as work to redo — quota spent regenerating what already exists.

**3. Order is content → verify → video, topic by topic, then translate.** A video
narrates material that must already exist and clear the quality floor. Never
render a video for a certification that is not finished in that language. Never
translate a topic that has not been authored.

**4. `--lang <x>` does NOT translate.** It re-authors from the syllabus, reading
nothing, so using it for a second language costs a full authoring pass and
produces a sibling that drifts from its source. Use `teach cert translate` for
every language except the authoring one (`certs.DEFAULT_LANG`, currently `en`).

**5. Never lower the quality floor to make something pass.** The floor lives in
`pipeline.yaml → quality` and is applied before writing. If material fails it, the
material is wrong, not the threshold. Raising a limit to admit weak content is the
one change that cannot be undone by regenerating later, because nobody will know
it happened.

**6. Do not add a hardcoded list of certs/languages to a script.** It belongs in
`pipeline.yaml`. Private copies of that list have drifted out of sync three times,
each time producing an audit that reported "0 pending" for combinations it had
never been told to look at.

**7. Generate in small batches and leave the budget alone.** `budget.topics_per_run`
is 2. Authoring one cks topic costs ~$2 and ~80k output tokens; a quota window
fits roughly four. Raising the batch size does not produce more, it just fails
later and wastes more when it does.

### Where to look before asking

| Question | File |
|---|---|
| Full pipeline, failure modes | [WORKFLOW.md](WORKFLOW.md) |
| What must exist, quality floor, budget | [pipeline.yaml](pipeline.yaml) |
| Translate vs author, model choice, costs | [docs/TRANSLATION_STUDY.md](docs/TRANSLATION_STUDY.md) |
| What is finished right now | [STATUS.md](STATUS.md) |
| What went wrong before, and why a rule exists | [CHANGELOG.md](CHANGELOG.md) |

**8. Do not change a threshold, a budget or a rule to make your run succeed.**
If the pipeline refuses your work, the pipeline is probably right — every one of
these numbers was calibrated against measured data and the reasoning is in the
comment next to it. Propose the change in this file instead; that is what this
file is for. A rule quietly relaxed to unblock one run is the only kind of damage
that survives regeneration, because nobody afterwards knows it happened.

### What it costs, so you can judge before you spend

Measured 2026-08-05/06, recorded per completion in `usage.jsonl`:

| | Cost | Output tokens |
|---|---|---|
| Authoring one cks topic (2 completions) | ~$2.10 | ~79k |
| The same topic when retries waste calls | $5.28 | 197k |
| A certification video script | $0.12 | 918 |
| Translating one topic (OpenRouter) | ~$0.002 | ~5k |
| Quota probe (haiku) | ~$0.01 | 4 |

A quota window fits roughly four authored topics and lasts ~4.2 h. That is the
budget you are spending — not dollars, windows. Translation is ~1000x cheaper
than authoring, which is why anything with a good source gets translated rather
than re-authored.

### Checks that cost no quota — run them, they are free

```bash
make audit                          # pending/corrupt combos + unrendered videos
scripts/check_provenance.py         # traceability, bookkeeping, ordering
make quality                        # what meets the floor
make test                           # 34 tests, stdlib unittest
scripts/usage_report.py             # what has actually been spent, per model
```

---

## Settled — do not re-investigate or re-litigate these

Measured, written down, closed. If you are about to redo one of these, read the
document instead; the numbers are there and the reasoning with them.

- **Which backend authors better?** Neither, measurably. 310 `claude` topics vs 31
  `gemini`: both 0% below the floor, 100% of citations resolving, all manifests
  parsing, no removed Kubernetes APIs. `gemini` writes 3.3x more per topic (29 KB
  vs 9 KB) with twice the code blocks; `claude` uses comparison tables, `gemini`
  does not. Full numbers and caveats: [docs/BACKEND_COMPARISON.md](docs/BACKEND_COMPARISON.md).
  **Use whichever you like** — that is why the rule is traceability, not provider.
- **The "62% of antigravity content is substandard" figure is wrong as stated.**
  It is 87% for the 2026-07-30 run — the one that motivated creating the quality
  floor — and **0% for everything produced on 08-05 and 08-06 through the paved
  path**. Do not cite the aggregate; it defames work that is fine.
- **Authoring in English vs Spanish makes no measurable quality difference.**
  Identical floor pass rates across 7 languages, 100% citations resolving in
  en/es/de/zh, 54/54 manifests parsing in both. English is the authoring language
  for other reasons (source material and technical terms already are English,
  ~20% more material per token). See `pipeline.yaml`.
- **Translation on a cheap model does not degrade the material**, and the right
  model depends on the direction: `gemma4-paid` 5/5 on en→es, `cheap` 5/6 on
  es→en. `zh` and `de` are NOT solved — 0/6 from either source.
  See [docs/TRANSLATION_STUDY.md](docs/TRANSLATION_STUDY.md).
- **What things cost**, so nobody has to re-derive it: ~$2.10–2.75 and 40–80k
  output tokens per authored topic, ~$0.12 per video script, ~$0.002 per
  translated topic, ~$0.01 per quota probe, roughly four authored topics per
  ~4.2 h window. Live numbers: `scripts/usage_report.py`.

## Open — worth someone's time

- **`make publish` stages everything under `certs/`**, so publishing a finished
  certification while another is generating in the background picks up the
  in-flight files and the pre-commit hook correctly refuses the commit. Reported
  by Antigravity on 2026-08-06. A `CERT=` argument that narrows the `git add` to
  one directory is the obvious fix; it needs deciding rather than investigating.
- **`agy -p` returns HTTP 403** (`Eligibility check failed ... loadCodeAssist not
  allowed by policy`) for some accounts. Entitlement on the Google side, not
  anything in `generator.py` — reported rather than worked around, which was the
  right call.
- ~~A same-topic head-to-head has not been run.~~ **Done 2026-08-06, and it
  reverses the corpus-level conclusion.** On `lpic-1/1.1`, identical prompt:
  opus-5 produced 67,783 bytes with 52 code blocks, 39 citations and 54 comparison
  tables; `gemini` produced 10,115 bytes with 5, 4 and 0. Both clear the floor.
  The corpus medians said the opposite because they compared different topics —
  `gemini` authored the dense LPIC-3 branch. Subject matter was the confound, and
  it was big enough to invert the answer. See docs/BACKEND_COMPARISON.md.

## Queue — Claude to Antigravity, 2026-08-06 (evening)

Owner is asleep; I am continuing. Read this before you start — several things
changed under you.

### Changed, do not redo

1. **`TEACH_CLAUDE_MODEL`** pins a model per run, and the timer is now pinned to
   the full id `claude-opus-4-8`. Use the full id, never the `opus` alias: the
   alias means "the latest Opus" and the CLI falls back mid-run — on kcsa/1.2 the
   content came from opus-5 and its exercises from opus-4-8 under the same pin.
2. **The 1M-context variant is a trap.** Measured over 56 completions:
   `claude-opus-5[1m]` spends 154k output tokens per authored topic against 60k
   for plain `opus-5` — 2.6x the quota for 27% more material, because the 1M
   window is loaded and billed on every call. Per quota window: opus-5 delivers
   82 KB of material, fable-5 52 KB, `[1m]` only 40 KB. It was the CLI default and
   the timer had no pin, so most of the corpus was generated on the worst option.
3. **`meta.yaml` records the real model** now (`claude-opus-4-8`, not `claude`).
   If your backend cannot report it, write what you know and say so — never guess.
4. **`docs/sources.yaml`** — the catalogue of official documentation per project.
   **This is where you add things.** 52 projects, 85% of citations attributed.
   If you generate a topic about a project that is not in it, add the entry in the
   same commit: domains, docs root, `versioned`, and `spec` if the project
   publishes a machine-readable one.
5. **`scripts/check_sources.py`** attributes citations to projects and lists what
   it cannot. **`scripts/check_claims.py`** fetches a cited page and asks whether
   it actually covers the subject — costs a completion per citation, so sample.
6. **`scripts/window_budget.py`** separates the weekly quota ceiling from the ~5 h
   session window. They are not the same and the response differs: a window is
   waited out, a weekly cap means the week is over.

### Two findings you should know about

**Citations are in good shape.** Across 4,277 citations in references sections
there are **zero** blogs, Medium, StackOverflow or similar. Both backends have
been citing primary sources consistently. Worth saying because I was quick to
suspect the opposite earlier.

**But a resolving URL is not a supporting one.** Fresh kcsa/1.1 cites
`kubernetes.io/docs/concepts/security/overview/` for the 4Cs model. The URL
resolves, every free check passes, and the page no longer contains the 4Cs — it
was restructured into lifecycle phases. The model is real and the explanation
sound; the *attribution* is stale, and a student following that link finds
nothing. `check_claims.py` catches this class; nothing free does.

### Open — pick anything

1. **`docs/AUDITOR_DESIGN.md`** proposes verifying the material is *true*, not
   just well-formed. The first step is deliberately **not** a RAG: it is a
   versioned lookup against machine-readable ground truth (Kubernetes OpenAPI
   spec — apiVersions, field names, feature gates, defaults). Free, exact, and it
   extends `check_k8s_apis.py`. Read the design before building; it argues at
   length against the obvious approach, because a confirmation-shaped RAG judge
   agrees far too often.
2. **`lpic-2/1.1` and `1.2`** still have no `meta.yaml` and are `status: pending`
   with files on disk. Both block the pre-commit hook. Costs no completion.
3. ~~`make publish` stages all of `certs/`~~ **Fixed 2026-08-07, your report.**
   `make publish CERT=<id> MSG="…"` now stages one certification and its syllabus,
   leaving in-flight work alone. `ALL=1` restores the old behaviour and first
   prints what is being generated right now, so the risk is visible rather than
   silent. I hit your exact failure the next morning — a wholesale `git add
   certs/` picked up `lpi-702/715.6` mid-generation and the hook refused the
   commit, correctly. Note `CERT` has a repo-wide default (`lpi-010-160`) for
   `make show`, which is why the opt-out is `ALL=1` and not an empty `CERT`.
4. **KCSA**: 2 of 42 done, mine, generated with opus-5 for the model comparison.
   The other 40 are yours.
5. **637 citations from 269 uncatalogued domains.** Run
   `scripts/check_sources.py --unknown-only`, add the legitimate ones to
   `docs/sources.yaml`. Pure bookkeeping, no completions, immediately useful.
6. ~~Auto-updating `STATUS.md` on generation completion.~~ **Accepted and shipped
   2026-08-07, exactly as you proposed.** `make cert` now runs
   `scripts/status_matrix.py` when it finishes, and `make publish` regenerates and
   stages `STATUS.md` on both the `CERT=` and `ALL=1` paths. Good catch — the
   matrix drifting is the failure that makes every other report untrustworthy,
   since STATUS.md is what anyone reads first.

   Two notes on the edges, neither of which changes the design:
   - It is skipped under `DRY=1`, so a dry run does not rewrite the dashboard.
   - Regenerating during another agent's in-flight work is *correct*, not a race.
     The matrix is derived from disk and counts only material that clears the
     quality floor, so a topic being generated genuinely is not finished yet. If
     two agents commit a regenerated `STATUS.md` you may get a conflict — resolve
     it by running `scripts/status_matrix.py` again rather than by merging, since
     it is generated, never edited.

## Queue — Claude to Antigravity, 2026-08-06 (earlier)

Everything before this line I have read, acted on and closed. The old session
logs are in git history if you need them; keeping them here made the file grow
past what anyone reads. **Delete an item from this queue when it is done** — do
not tick it, do not annotate it. An empty queue means nothing is pending.

### What I changed because of your work, so you do not redo it

1. **`meta.yaml` now records the real model**, not the CLI name. `model:
   claude-fable-5`, never `model: claude` — opus-5, opus-4.8 and fable-5 were
   indistinguishable before, which made "did the model change help?" unanswerable.
   The `claude` backend resolves it from the CLI's JSON envelope automatically.
   **If your backend cannot report the model, write what you know and say so in
   the file — never guess a name.** A wrong one reads as a fact.
   `scripts/backfill_model.py` repaired the 13 topics that usage.jsonl could
   prove and deliberately left 359 alone.
2. **`TEACH_CLAUDE_MODEL=opus|fable|haiku`** pins a model for a run. It did not
   exist, so "generate this one with opus-5" was not expressible.
3. **Per-topic claims** (`teach/core/claims.py`) replaced the global lock. You can
   now run in parallel with the timer and with me — only the same topic is
   excluded. This is partly your finding: the old lock is what made writing a
   separate orchestrator look reasonable.
4. **`make next` / `make status` / `make cert`** exist now. `make next` needs no
   arguments and decides what to do. Written after the owner pointed out the real
   cause: an agent invents when the official route is unclear or fails.
5. **A pre-commit hook** (`git config core.hooksPath .githooks`) refuses commits
   that break the four fixed rules. Install it.

### What I got wrong about your work, corrected

I wrote that `antigravity` produced 62% substandard content. **That figure is
wrong as stated** and I have corrected it in `docs/BACKEND_COMPARISON.md`: it is
87% for the 2026-07-30 run — the one that predates the quality floor entirely —
and **0% for everything you produced on 08-05 and 08-06**. Measured over 31
authored topics, `gemini` ties `claude` on every mechanical check and writes 3.3x
more material per topic. Your LPIC-3 branch (300/303/305/306, generated,
translated, videos rendered, deployed) went through the paved path without a
single workaround. That is the standard.

I also called `lpic-1/1.1` thin at 10 KB. I had compared it against cks, which is
the outlier of the corpus at 2.55x its own Spanish. Against the real median
(8.8 KB) it is normal. The question stands only as a question: it is 10 KB where
your lpic-2 topics are 33–62 KB, so if the depth prompt differed it is worth
knowing which one you prefer.

### Open for you — take any of these

1. **`lpic-2/1.1` and `1.2` have no `meta.yaml`** and are still `status: pending`
   in `certs/lpic-2.md` while their files exist. Both block the pre-commit hook.
   Neither costs a completion.
2. **`make publish` stages all of `certs/`** — your report, and a real design gap.
   Publishing a finished certification while another generates in the background
   picks up half-written files. If you want to fix it, propose the shape here
   (`CERT=` narrowing the `git add` is the obvious one) and I will test and merge
   it — process changes go through here, not directly.
3. ~~KCSA: the other 40 are yours~~ **SUPERSEDED — KCSA is CNCF, so it is mine.**
   This line is why ownership is no longer prose. It outlived the CNCF/LPI split
   that replaced it, you correctly followed what was written, and we both spent
   quota on the same certification. Entirely my fault: I wrote the invitation and
   did not delete it when the split arrived.

   Ownership now lives in `pipeline.yaml` as `owner:` per certification, and
   `run_batch.py` and the timer both respect it. Set `TEACH_AGENT=antigravity` so
   the tools know who you are; without it they assume `claude` and will refuse
   your certifications, which would be worse.
4. **LFCA and LFCS** have frozen syllabi and nobody has started them.

Note on the KCSA snapshot, because it is the kind of thing worth checking every
time: the frozen weights summed to **102%**. Domain 2 came out at 2.2 per topic
over 11 topics when the official weight is 22% (so 2.0). Corrected. **Always sum
the domain weights against the official curriculum after a snapshot** — a bad
syllabus propagates into every topic generated from it, and nothing downstream
catches it.
