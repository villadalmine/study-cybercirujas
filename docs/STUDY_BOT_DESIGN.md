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

## Phase 1 — topic chat, browser-only (no backend work at all)

Flow:

1. **Menu** — career → certification → topic, built from the endpoints the
   SPA already calls: `/api/paths`, `/api/catalog`, `/api/certs/{id}`.
2. **Key** — the student pastes an OpenRouter key. It lives in
   `localStorage` and is sent **only** to `openrouter.ai`, never to our
   server. Verified 2026-09-09: OpenRouter answers browser preflight with
   `Access-Control-Allow-Origin: *` and accepts `Authorization`, so the
   call goes direct from the page.
3. **Context** — the page fetches
   `/api/certs/{cert}/topics/{topic}?lang={lang}` (already returns content,
   exercises and provenance) and puts the material in the system prompt.
4. **Ask** — POST to `openrouter.ai/api/v1/chat/completions`, stream the
   answer, render it with the SPA's existing `md()`.
5. **Prompt buttons** for the common asks: *give me an exercise*,
   *explain this differently*, *quiz me on this*, *what would the exam ask*.

What ships: one view in `index.html`, seven translations of its strings,
zero server changes, zero recurring cost.

### Rules this design must keep

- **The key never touches our server.** Not logged, not proxied, not sent.
  Say so in the UI, in the reader's language, next to the input.
- **Answers are AI-generated too** — the same Article 50 disclosure the
  topic pages carry applies to the bot's output, and it must name the model
  the student chose.
- **Cite the loaded topic** in every answer header, so the student always
  knows what the model was actually given.
- **Never claim the answer is verified.** The material passed the quality
  floor; a model's improvisation on top of it did not. This is the
  `docs/AUDITOR_DESIGN.md` gap restated: a confident wrong explanation
  looks exactly like a right one.

## Phase 2 — whole-certification questions, still without a vector DB

When the question spans a certification ("where does X appear in CKS?"),
send the **topic index** (ids, titles, weights — a few hundred tokens) and
let the model name which topics it needs; the page then loads those files
and asks again. Two round trips, exact material, still no embeddings. This
is agentic retrieval over a catalogue that is already keyed by
`(cert, topic, lang)` — the audit's "skip the graph layer" conclusion,
carried one step further: skip the vectors too.

Only if this proves insufficient does a vector index earn its place — and
then it is one table in the Postgres that does not exist yet, not a chart
of four subsystems.

## Phase 3 — practice that outlives the session

Everything above is ephemeral by design. If the owner later wants progress
tracking, the anonymous `X-Session-ID` variant already proposed in
BACKLOG.md is the route, and it needs the persistence decision settled
first. Deliberately out of scope here.

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
