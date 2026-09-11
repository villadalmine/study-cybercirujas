# Study bot — design

Owner's proposal (2026-09-09): a bot section where the student picks a
career / certification / topic from a menu, the material is fed to an LLM,
and they can ask things like *"give me an exercise on this"*. Inference runs
against **OpenRouter with the student's own API key**, loaded into their
session — no accounts, no login, no session management on our side.

This supersedes the `chart/` RAG proposal audited in BACKLOG.md. That audit
found the idea sound and the corpus ready, but listed blockers that the
owner's variant **removes rather than solves**:

| Audit blocker | What the BYO-key design does |
|---|---|
| Unbounded inference cost on a public site (the project hit its spend limit twice in three days) | The student pays for their own inference. Platform cost stays **zero**. |
| Personalisation needs identity, but content is deliberately login-free | Nothing is stored server-side; there is nothing to identify. |
| No persistent storage in the deployment; `helm upgrade` wipes the pod | No server state to lose. |
| pgvector + Ollama + embedder CronJob + three non-existent images | None of it is needed — see below. |

## The insight: explicit selection replaces retrieval

RAG exists to find the relevant chunk when you do not know which one it is.
**Here the student says which one**: they pick the certification and the
topic from a menu. At that point the exact material is a known file, and
the honest move is to send it whole rather than approximate it with
embeddings.

The corpus fits: authored topics run ~50–130 KB of markdown, roughly
15–35k tokens — comfortable in any current model's context, and every
modern OpenRouter model takes 128k+. Sending the real file also beats
retrieval on accuracy: no chunk boundaries, no missed section, no
similarity threshold to tune. And it is verifiable — the student sees which
topic is loaded.

So: **no vector database, no embedder, no Postgres, no new pods.** Phase 1
is frontend-only against endpoints that already exist.

## The phases

Each phase ships something usable on its own, has an explicit entry
condition, and states what it costs. No phase starts because the previous
one finished — it starts because its entry condition is met.

### Phase 1 — topic chat with a task harness

**Entry**: none. Buildable today.
**Ships**: a Bot section in the SPA. The student picks career →
certification → topic from menus built on `/api/paths`, `/api/catalog` and
`/api/certs/{id}`, pastes an OpenRouter key (stored in `localStorage`,
sent only to openrouter.ai — verified 2026-09-09: browser preflight
answers `Access-Control-Allow-Origin: *`), and asks questions. The page
fetches `/api/certs/{cert}/topics/{topic}?lang=` — which already returns
content, exercises and provenance — puts the material in the system
prompt, POSTs to `openrouter.ai/api/v1/chat/completions`, streams the
answer and renders it with the SPA's existing `md()`.

**The task harness is part of phase 1, not a later refinement.** Four
intents, four specialised prompts, chosen by which button the student
presses:

| Intent | What its prompt must know |
|---|---|
| Explain differently | cite the topic's own references section; never invent sources |
| Give me an exercise | follow `exercises.md` conventions: guided steps, answers inside `<details>` |
| Quiz me | read the syllabus domain weights and ask in proportion, as the real exam does |
| What would the exam ask | the certification's level and format, from the catalogue entry |

All four must refuse to go beyond the loaded material and say so.

**Cost**: platform zero, student pays their own inference. One code path,
no tool calling, no backend change, no new service.

### Phase 1 — SHIPPED 2026-09-09

Implemented in `teach/web/index.html` as the **Bot** section. What a student
sees, and exactly where their tokens go:

**The request.** One call to `openrouter.ai/api/v1/chat/completions`,
straight from the browser. Nothing is proxied through this server, so the
platform spends nothing and the student's key is never seen by us. The
message that goes out is:

    system  = task-harness prompt (see below)
            + the loaded material  ← the big part
    history = last 6 turns, ONLY if "remember the conversation" is on
    user    = the question

**Where the tokens go, and every lever to spend fewer:**

| Lever | Effect |
|---|---|
| **Material to send** — theory / theory+exercises / none | The dominant cost. A topic runs ~3–35k tokens; "none" sends the question alone, for follow-ups that need no material |
| **Remember the conversation** — off by default | When off, every question is independent: no history is resent, so cost stays flat instead of growing each turn |
| **Model selector, three tiers** | Ids and prices read from `openrouter.ai/api/v1/models` on 2026-09-09, never from memory — an earlier draft shipped invented ids, caught by the owner. Top (Opus 5 $5/$25, GPT-6 Astra $10/$50, Kimi K3 $3/$15) · Mid (Sonnet 5, GPT-5.6 Sol, Qwen3.7 Max, DeepSeek V4 Pro, Kimi K2.5) · Low (Haiku 4.5, GPT-5 Mini **default**, GPT-5 Nano $0.05/$0.40, DeepSeek V4 Flash, Qwen3.7 Flash $0.03/$0.13). Two orders of magnitude between tiers for the same explanation |
| **Reasoning effort** — off by default | OpenRouter exposes a unified `reasoning: {effort}` control and 304 of 435 models support it. Thinking tokens bill as output, so it is opt-in: worth it for "what would the exam ask", wasteful for a definition lookup |
| **`max_tokens: 2000`** | Caps the answer, so a runaway reply cannot drain a key |
| **Estimate before sending** | The exact material size is shown as tokens the moment a topic is picked — nothing is spent to find out |
| **Session counter** | Real `usage` figures from OpenRouter's response, accumulated per session |

Material is fetched once per topic and cached client-side, so switching
between intents on the same topic re-sends the same context without
re-fetching it.

**The task harness** — four intents, four specialised prompts, each one
knowing something about this corpus: the exercise writer follows the
`<details>` solution convention, the quiz weighs questions by what the
syllabus emphasises, the explainer may cite only references already in the
material, and all of them are told to say "that is not in the material"
instead of improvising.

**Disclosure**: every answer is labelled with the model that produced it
and links the topic's official exam guide, plus a standing notice that the
answer is AI-generated and unverified — same standard as the authored
pages, since a bot answer is exactly the kind of confident-and-possibly-
wrong output `AUDITOR_DESIGN.md` warns about.

**Not implemented on purpose**: no streaming (one response, simpler and
identical in cost), no tool calling (phase 2), no server state (phase 4).

### Phase 1 — feedback, and the probe that answers it (2026-09-11)

Two things came back from students using phase 1: **some models do not work**,
and **the reasoning control is not understandable** — it is not clear when it
applies or what it does.

Both were true, and neither was visible to the check that existed.
`check_models.py` asks OpenRouter's public catalogue whether an id still exists
at the price shown. It is free and it is honest, but it reads what the
catalogue *claims*. A model can be listed, priced, and advertised as supporting
`reasoning` and still hand the browser an empty answer, or bill thinking tokens
on a request that switched thinking off. All eighteen models in `models.yaml`
advertise `reasoning: true`. Thirteen of them do something else.

**`scripts/probe_models.py` (`make probe-models`) asks each model directly.**
Same endpoint the browser uses, same headers, same `max_tokens: 2000` — the cap
matters, because OpenRouter derives each provider's thinking budget from it, so
a probe at a different cap answers a question nobody asked. One fixed prompt
("Answer with one word and nothing else." / "What is the capital of France?"),
`temperature: 0`, a fixed seed, one graded substring. Nothing is judged by a
model; two runs differ only where a provider changed.

Three calls per model — reasoning omitted, `effort: low`, and
`reasoning: {enabled: false}` — and every response carries its own real cost,
so the script reports what it spent rather than what it estimated. **A full pass
is ~51 calls and cost $0.0077.** It stops at `--budget` (default $0.25) of real
spend, and `--dry-run` prints the worst case without sending anything. It uses
`LITELLM_API_KEY_BOT`, a second OpenRouter key with its own limit, so a probe
can never reach the translation budget.

**What it found, 2026-09-11** — full report with `--json`; the verdicts are
written back into `models.yaml` by `--update`:

| What | Models |
|---|---|
| Answered correctly | 16 of 18 (and see the comprehension pass below) |
| Answered nothing on that run | `gemma-4-31b:free` (rate-limited upstream), `nemotron-3-ultra:free` (HTTP 200, no content). Both answered on other runs, so they are marked `flaky` and kept, not dropped |
| **Think even when reasoning is switched off** | 12, including **`gpt-5-mini`, the bot's default** — 64 thinking tokens on a request that never mentioned reasoning, under a control labelled "No reasoning (cheapest)" |
| Thinking can be switched off explicitly | 12 models accept `reasoning: {enabled: false}` and stop |
| Thinking **cannot** be switched off at all | `gpt-5-mini`, `gpt-5-nano`, `gpt-6-astra`, `minimax-m2.7` — the endpoint answers *"Reasoning is mandatory for this endpoint and cannot be disabled"* |
| Ignore the effort setting entirely | `claude-sonnet-5`, `gpt-5.6-sol` — zero thinking tokens at every effort, `high` included. The selector spends nothing and changes nothing |
| Honour it as advertised | `claude-haiku-4.5`, `gemma-4-26b:free` — 0 thinking tokens off, 43–56 on `low` |

The thinking that is billed is not always thinking the student can see: OpenAI
returns it encrypted (`reasoning_details`), paid for and invisible. That is
recorded too.

### Can it read what we send it? (2026-09-11, second pass)

Answering is not being useful. "Paris" proves a model is alive; it proves
nothing about the thing the bot actually does, which is answer from a topic of
this corpus — and the same for the seven languages the site offers, where a
model can be perfectly capable and still reply in the wrong one.

So the probe has a second pass. For each model, for each language, it sends an
excerpt of a **real topic** (`lpi-010-160/5.2`, "Creating Users and Groups"),
with the page's own system prompt — *use ONLY the material below* — and asks, in
that language, a question the excerpt answers. The expected answer is
`/etc/passwd`: a filesystem path, identical in all seven translations, so **one
substring grades every language**. No second model, no judgement.

Three properties make it honest rather than convenient:

- **The excerpt is read from the tree at probe time**, never frozen into the
  fixture, so the probe always asks about the material the site serves. If the
  topic is regenerated and stops containing the answer, the run says `DRIFT` and
  refuses to grade — and `make verify` catches it for free before that, in
  `tests/test_model_probe.py`.
- **Language is decided by a fixed rule**: kana for Japanese, Han without kana
  for Chinese, marker counts for the Latin-script five. A reply too short to
  classify counts as passing — a model is excluded from a language only on
  evidence (wrong answer, or measurably the wrong language), never on the
  absence of it.
- **The request is what the page sends**, including the reasoning off switch for
  the models that accept one. That is both faithful and cheaper: the thinking
  those models would otherwise bill is most of the cost.

**Result, 164 calls and $0.27:** all fourteen paid models answered from the
material, in all seven languages. The free tier is where it bites — the two
Nemotrons return HTTP 200 with no content in some languages (`ultra`: es, de,
zh; `super`: fr), and the two Gemmas were rate-limited before they could be
asked at all, so they carry no language verdict and stay offered everywhere.

`models.yaml` now carries `langs:` per model and the page filters the menu by
the interface language, with a line saying how many models that hid. If a
language ever has no proven model, the page falls back to offering everything
that answers rather than an empty menu, and says nothing was hidden — the
guarantee is "never claim what was not measured", in both directions.

**Two models classified differently between runs** (`deepseek-v4-pro`,
`deepseek-v4-flash`: `effort` on one pass, `always` on the next). That is not
noise in the probe — it is the finding. Some models decide per question whether
to think, and OpenRouter may route two identical requests to different upstream
providers. So `always` is deliberately the conservative verdict, and the page
does not rely on the classification for the thing that costs money: when the
student picks "no reasoning" it sends the explicit off switch to every model
that accepts one, rather than omitting the field and hoping the default holds.

**What changed in the page.** The menu and the effort selector are now built on
what was measured, not on what is advertised:

- a model probed `broken` is not offered; one probed `flaky` is offered and
  labelled as such, because a `:free` model saturated for six seconds is not a
  dead model and dropping it would be the worse error;
- choosing "no reasoning" sends `reasoning: {enabled: false}` to the models
  where that was proven to stop the thinking, instead of omitting the field and
  hoping;
- the selector is disabled, with a line saying why, for the models that ignore
  or refuse it;
- for the models that cannot stop thinking, the page says so plainly rather
  than offering a cheaper option that does not exist.

**What is still assumed**: that a model which finds `/etc/passwd` in the
material and writes one correct sentence about it also gives *good* study
answers — full explanations, sound exercises, exam questions worth the student's
time. Liveness, comprehension and language are mechanical; quality is not, and
this probe does not claim it. Same gap
[AUDITOR_DESIGN.md](AUDITOR_DESIGN.md) describes for the material itself, and
the same reason every answer carries the "unverified" notice.

### Phase 2 — questions across one certification

**Entry**: students actually ask questions that span topics ("where does X
appear in CKS?") — not before.
**Ships**: the page sends the **topic index** (ids, titles, weights — a few
hundred tokens), the model names the topics it needs, the page loads those
files and asks again. Implementable as two manual round trips or as tool
calling (`get_topic(cert, id)`); tool calling is the better shape where the
model supports it — 364 of 431 OpenRouter models do (84%, measured
2026-09-09) — with the two-round-trip path as fallback for the rest.

This is retrieval over a catalogue already keyed by `(cert, topic, lang)`:
still **no embeddings, no vector store**. The audit's "skip the graph
layer" conclusion, carried one step further.

**Cost**: one extra round trip per question, on the student's key. Two code
paths (tools + fallback) instead of one.

### Phase 3 — career-level work, where sub-agents earn their cost

**Entry**: phase 2 in use and a demand for tasks spanning certifications —
study plans, gap analysis across a career path, comparisons.
**Ships**: multi-pass work where a specialised sub-agent reads a slice and
returns a structured summary, and a synthesiser assembles the answer. Only
here does the multi-call cost buy something a single pass cannot deliver.

**Also here**: expose the same contract over **MCP** (`list_certs`,
`get_syllabus`, `get_topic`, `search_topics`) so any external agent can
study against the corpus. The repo already runs one MCP server (graphify),
so the pattern is proven. The bot's tools and the MCP tools are the same
four functions — design once, ship twice.

**Cost**: several paid calls per question and real latency, on the
student's key. Defensible for a study plan; never for "give me an
exercise".

**If a vector index ever earns its place**, it is here — and it is one
table in a Postgres that does not exist yet, not a chart of four
subsystems.

### Phase 1.5 — closing the loop: checks that improve the page

**Entry**: the `check-models` CronJob exists and reports, but its findings only
reach a pod log nobody reads. This phase turns that information into something
the page acts on.

**The distinction that decides the design**: there are two needs here, and
only one of them should ever be automatic.

| Need | Automate? | Why |
|---|---|---|
| **Protect the student in the moment** — do not offer a model that 404s, do not label as "free" one that started charging | **Yes** | There is no judgement involved. Showing a broken option is simply wrong, and a human in the loop just means the student hits the error first |
| **Fix the catalogue** — choose which model replaces the one that vanished | **No** | This is a judgement call against the criteria written in `models.yaml`, and getting it wrong is how a finance-tuned model ends up teaching Kubernetes |

So: automate the *guard*, never the *decision*.

**Mechanism — three options, with what each really costs:**

**A · The API validates and caches (recommended).** `/api/models` checks the
catalogue against `openrouter.ai/api/v1/models` at most once every few hours,
caches the result in memory, and annotates each entry with `available` and the
live price. The page greys out or hides anything unavailable and shows a note
when a price no longer matches. If OpenRouter is unreachable the catalogue is
served as-is — degraded to today's behaviour, never blank.

- No RBAC, no secrets, no persistent storage, no new moving parts.
- The pod makes one outbound call every few hours; the student's request path
  stays as fast as it is now because the check is out-of-band.
- Survives pod restarts by simply re-checking. Nothing to lose.

**B · The CronJob writes a ConfigMap the API reads.** Keeps the check where it
is and gives the result a home in cluster state. Costs a ServiceAccount, a Role
and a RoleBinding, plus a Kubernetes client inside the image — real surface for
a single boolean per model.

**C · The CronJob opens a pull request.** `check_models.py --update` already
rewrites prices; wrapping it in a commit and a PR would make every catalogue
change reviewable and versioned, which fits this repository's habits better
than anything else. Costs a GitHub token in the cluster, and it only serves the
*decision* half — the student is still unprotected until someone merges.

**Recommendation**: build A now, keep the CronJob as the reporter, and consider
C later as the mechanism for the decision half. Do not build B: it is the most
plumbing for the least benefit.

**Cost**: one background task in the API, no new services, no quota. The check
is the same function `scripts/check_models.py` already implements — it should
move to `teach/core/` so the API and the script share one implementation rather
than two that drift.

### Phase 4 — progress that outlives the session (out of scope for now)

**Entry**: an owner decision on persistence. Everything above is ephemeral
by design, which is what keeps it free of accounts and of server state.
The anonymous `X-Session-ID` route already proposed in BACKLOG.md is how it
would work, and the deployment's lack of persistent storage is what it
would have to solve first.

## Operating it

### Is it all API?

Yes, and deliberately in two directions:

**Inward** — the page is built from endpoints that already existed, plus one
added for it. Nothing about the bot is hardcoded in JavaScript:

| Endpoint | What the bot takes from it |
|---|---|
| `/api/catalog` | the certification list for the menu |
| `/api/certs/{id}` | the topic list, filtered to those with material |
| `/api/certs/{id}/topics/{t}?lang=` | content, exercises, and the provenance line shown under each answer |
| `/api/models` | the model catalogue: ids, display names, prices, context, whether each supports `reasoning` |

**Outward** — one POST to `openrouter.ai/api/v1/chat/completions` per question,
from the browser. The site's own server is not in that path at all, which is
what keeps platform cost at zero and means a student's key is never in our
logs, our memory, or our backups.

### How a student uses it

1. Get a key at `openrouter.ai/keys` (their own account, their own billing).
2. Open the **Bot** section, paste it once — it stays in `localStorage`.
3. Pick certification → topic. The estimate updates immediately: that number
   is what the request will cost in context tokens.
4. Ask, or press an intent shortcut.

Everything is per-browser. Clearing site data removes the key and the session
counter; there is nothing server-side to delete because nothing was stored.

### How it is maintained

The only moving part is the model catalogue, because models change and free
ones churn:

```bash
scripts/check_models.py            # GONE / PRICE / PAID / PARAM, exit 1 on drift
scripts/check_models.py --update   # accept new prices into models.yaml
make check-updates                 # runs it alongside the syllabus check

make probe-models                  # call every model: does it answer, does the
                                   # effort selector do anything, and can it
                                   # read our material in each language
make probe-models UPDATE=1         # write those verdicts into models.yaml
make probe-models LANGS=""         # liveness + reasoning only, ~$0.008
make probe-models LANGS=ja,zh      # re-check the two that fail most often
scripts/probe_models.py --dry-run  # the worst-case cost, sending nothing
```

**The order, when a model changes:** `check_models.py` first (free — is it still
there, at that price), then `probe-models UPDATE=1` (does it still work), then
commit `models.yaml`, then build and deploy. The page reads the catalogue from
the image, so a verdict that is not deployed protects nobody.

The two are not the same question and neither replaces the other: the first
reads what OpenRouter publishes and costs nothing, which is why it runs weekly
in the cluster; the second calls the models and costs about three quarters of a
cent, which is why it stays **manual** — this project does not spend money on a
timer, and the probe would have to carry the bot key into the cluster to do so. Run the probe after any change to the
catalogue, and after any change to `max_tokens` in the page — the reasoning
verdicts are only true for the request the page actually sends.

It also runs **weekly in the cluster** as the `check-models` CronJob (the same
image the site runs, so the catalogue checked is the one served). A failing job
is the signal; the pod log has the detail:

```bash
kubectl get cronjob,jobs -n teach-plat
kubectl logs -n teach-plat job/<name>
```

Replacing a model is a judgement call, not a refresh: the selection criteria
live at the top of `models.yaml` (general purpose over domain-tuned, known
family over unknown provider, context above ~130k is not a tie-breaker). Both
mistakes that got caught in review — invented ids, and a free tier picked by
context length that included finance- and health-tuned models — are why those
criteria are written down rather than remembered.

Prompts are the other thing that ages. The four intent prompts live in
`BOT_INTENTS` in `teach/web/index.html`; each encodes a convention of this
corpus, so if the corpus conventions change (the `<details>` answer block, the
references section) the prompts must change with them.

## Two harnesses, not one (the distinction that sets the phases)

Owner's question, 2026-09-09: *shouldn't specialised skills/agents decide
what to fetch, instead of dumping raw material on the model?* The intuition
is right, but it applies to a different layer than expected, and earlier.
There are **two** harnesses and they have opposite schedules:

**Retrieval harness — "which material to load".** Needed only when the
material does not fit or is not known. With one topic chosen from a menu it
is **neither needed nor better**: 15–35k tokens fit any 128k model, sending
the real file beats any search (no lost chunk, no threshold), and the
student can see exactly what was loaded. This is phase 3 work, not phase 1.

**Task harness — "what to do with that material".** Needed from day one,
and this is where the owner's instinct lands. "Give me an exercise",
"explain it differently" and "quiz me" are different procedures, and each
needs to know things about *this* corpus:

- the exercise writer must follow `exercises.md` conventions — guided
  steps, and answers inside a `<details>` block;
- the examiner must read the syllabus domain weights and ask in proportion,
  because that is what the real exam does;
- the explainer must cite the topic's own references section rather than
  inventing sources;
- every one of them must refuse to answer beyond the loaded material and
  say so, instead of improvising — the `AUDITOR_DESIGN.md` gap applies to
  the bot exactly as it applies to authored content.

These are "skills" in the useful sense: **specialised prompts selected by
intent**. They are text, they cost nothing extra, they need no tool calling
and no extra round trip. Skipping them is what "dumping raw at the model"
actually looks like — the failure the owner intuited, one layer up.

**When real sub-agents earn their cost**: only when a task genuinely needs
several passes over material that will not fit — cross-certification
comparison, a study plan across a whole career. Each sub-agent is another
paid call **on the student's own key**, plus latency. That trade is
defensible for a study plan; it is not defensible for "give me an
exercise".

## Tools / function calling — evaluated 2026-09-09

Owner asked whether giving the bot tools (and whether writing a harness
skill) is worth it. Three different questions, three different answers.

**A harness skill to build this: no.** Skills earn their keep on
*recurring* procedures — `check-updates` runs quarterly and has steps
people forget. Building the bot happens once; a skill for it is
documentation with extra ceremony. This design document already does that
job better.

**Tools for the bot: yes, but they ARE phase 2 — not a separate feature.**
Measured 2026-09-09: **364 of 431 OpenRouter models (84%)** advertise
`tools` in `supported_parameters`.

- In phase 1 tools add nothing: the student already chose the topic and the
  whole file is in context. A `get_topic` tool for a topic already loaded
  is pure complexity.
- In phase 2 tool calling is simply the better shape of the two-round-trip
  design above — the model calls `get_topic(cert, id)` as often as it needs
  instead of the page orchestrating it by hand.
- Real cost: the 16% without tool support needs a fallback path, and the
  tool loop runs in the browser (the page executes the call and returns the
  result). Two code paths where phase 1 has one.

**What is actually worth building, and was missing from this plan: expose
the corpus over MCP.** Today the material is reachable only from our own
page. An MCP server (`list_certs`, `get_syllabus`, `get_topic`,
`search_topics`) would let *any* agent — someone else's Claude Code,
Cursor, a custom bot — study against this corpus directly. The repo already
runs one MCP server (graphify, in `.mcp.json`), so the pattern is proven
here.

The leverage: **the bot's tools and the MCP tools are the same contract.**
Define those four functions once and they serve the browser tool loop and
the MCP server both. Design them together, ship them separately.

Order: phase 1 with no tools (immediate value, one code path) → phase 2
with tool calling if cross-certification questions are actually asked →
MCP as its own piece reusing the same contract.

## Alternatives considered

- **Server-side inference with our key** — rejected: reintroduces the
  unbounded-cost blocker on a public site, and this project has hit its
  monthly limit twice.
- **Local Ollama in the cluster** (the `chart/` route) — a Tesla P4 with
  8 GB VRAM runs an 8b quantised model, and the answer quality gap against
  what the student can pick on OpenRouter is large. It also puts a GPU on
  the critical path of a study session.
- **Other BYO providers** (Anthropic, OpenAI direct) — both are viable
  later with the same shape; OpenRouter is first because one key reaches
  every model and it already permits browser calls. The client should keep
  the provider behind a small adapter so a second one is a config entry,
  not a rewrite.
- **Pre-generated exercise bank** (the audit's suggestion) — still a good
  idea and **orthogonal**: it makes the free path useful for students with
  no key at all. Worth doing, but it is content generation, not this
  feature.

## Effort

Phase 1 is one focused session of frontend work. No new services, no new
images, no quota, nothing to operate. Phase 2 adds one round trip in the
same view.
