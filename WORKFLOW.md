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

## The loop

```
snapshot  →  generate  →  audit  →  status  →  commit  →  publish
(once per     (per topic   (always) (always)   (freely)  (only when a cert
 syllabus)     × language)                                is COMPLETE)
```

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

## Unattended runs

`scripts/resume-generation.sh` retries generation via a systemd user timer,
holds a `flock`, refuses to start if a generation is already running, and is
safe to call when there is nothing pending.

**`teach-resume.timer` is deliberately disabled.** Enabling it means the machine
spends API quota autonomously on its own schedule. Turn it on knowingly:

```bash
systemctl --user enable --now teach-resume.timer
```
