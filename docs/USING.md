# Using it, in detail

The long form of what the README summarises: what you get, the Curriculum-as-Code idea, and every way to run and query the material (site, Docker, local model, your own agent, REST API, command line).

## What you get

For each certification you get the **official syllabus**, frozen from the
vendor's own document, and for every objective in it: **theory**
(`content.md`), **exercises** (`exercises.md`) and a **break-and-fix lab**
(`lab/break_fix.sh`) that breaks something on purpose for you to repair.

The project treats a curriculum like software — **Curriculum-as-Code**:

- **the catalogue is code**: `catalog.yaml` lists every certification and its
  official sources; each syllabus is a file in git, snapshotted from the
  vendor's document and compared against it when the vendor publishes a new
  version;
- **the pipeline is declared**: `pipeline.yaml` says which certifications and
  languages must exist, the quality floor and the budget — no script keeps its
  own list;
- **validations run like tests**: quality floor, citations, embedded manifests,
  removed Kubernetes APIs and provenance are checked on every push
  ([`verify.yml`](../.github/workflows/verify.yml)) and by a pre-commit hook;
- **provenance is data**: every topic carries a `meta.yaml` with the model, the
  date and the official sources it was written from;
- **everything else is a projection**: the site, the REST API, the Docker image,
  [docs/STATUS.md](STATUS.md) and the table below are derived from the same files.
  No database, nothing hand-maintained twice.

**The principles** ([docs/PRINCIPLES.md](PRINCIPLES.md)): *information
sovereignty* — everything you need runs on your own machine, with no account
and no third party; *determinism* — the site, the API, the CLI, the validators
and the labs give the same result every time and need no AI, and CI proves it
with the network blocked (`make determinism`); *with AI or without it, the same
pipeline and the same validator* — AI only drafts and translates, and its output
meets the same checks as anything written by hand.

**All study material is AI-generated** — read [the disclosure](../README.md#ai-generated-content)
before relying on it.

## Use it in 2 minutes

**1. Online** — open <https://study.cybercirujas.club>. Nothing to install.

**2. Docker** — the whole site on your machine, offline after the pull
(~480 MB download):

```bash
docker run --rm -p 8000:8000 ghcr.io/villadalmine/study-cybercirujas:latest
# site: http://localhost:8000   API docs: http://localhost:8000/docs
```

**3. From the source** — you need `git`, `make` and Python ≥ 3.11 with `venv`.
On Debian/Ubuntu: `sudo apt install git make python3-venv` (without
`python3-venv`, `make setup` fails with *ensurepip is not available*). On
Windows, use WSL (Ubuntu); on macOS, `xcode-select --install` gives you `git`
and `make`.

```bash
git clone https://github.com/villadalmine/study-cybercirujas.git
cd study-cybercirujas
make setup        # creates .venv and installs the `teach` CLI (~20 s)
make serve        # site + API on http://127.0.0.1:8000
```

**Windows without WSL** works for studying (site, API, CLI), not for the
`make` targets or the labs. In PowerShell, from the clone:

```powershell
py -m venv .venv
.venv\Scripts\pip install --require-hashes -r requirements.lock
.venv\Scripts\pip install --no-deps -e .
.venv\Scripts\teach serve        # http://127.0.0.1:8000
```

The clone is ~130 MB. `make serve` binds to `127.0.0.1`; use
`make serve HOST=0.0.0.0` to reach it from another device on your network.

The material is plain markdown, so you can also just read it in your editor:

```
certs/<cert>.md                          syllabus: objectives, weights
certs/<cert>/<topic>/<lang>/content.md   theory
certs/<cert>/<topic>/<lang>/exercises.md exercises with solutions
certs/<cert>/<topic>/<lang>/meta.yaml    provenance: model, date, official sources
certs/<cert>/<topic>/lab/                break-and-fix lab
```

## Practice: break-and-fix labs

Each topic ships a script that breaks something for you to fix. Linux topics
run in a throwaway Docker container with `teach lab up`; Kubernetes topics
(the ones that use `kubectl`) run in the containerized runner, `study-lab run
<cert> <topic>`, which needs only Docker. `teach lab up` refuses those topics;
`teach lab up --host` exists, runs the script on your own machine and is at
your own risk. **Never run `break_fix.sh` directly on your own machine** — that
is what the container is for.

```bash
.venv/bin/teach lab up lpi-010-160 2.1     # asks for confirmation, then breaks it
# Enter it:  docker exec -it -u student -w /home/student teach-lpi-010-160-2-1 bash
.venv/bin/teach lab status lpi-010-160 2.1
.venv/bin/teach lab down lpi-010-160 2.1   # delete it
```

The scenario and the hints are in the topic's `exercises.md`; the solution is
commented at the end of `break_fix.sh`. Some labs are written in Spanish only.
Labs whose `lab.yaml` says `provider: terraform` create cloud resources and
**can cost money** — read them before running.

## Study offline, sovereign

Everything below runs on your own hardware, with no account and nothing leaving
your machine.

### Ask questions about the material with a local model (RAG)

The simplest setup that works today: **[Ollama](https://ollama.com)** runs the
models, **[Open WebUI](https://openwebui.com)** gives you a chat with a
*Knowledge* base you fill with this repository's markdown.

**Hardware, realistically:** 8 GB of RAM and any recent CPU work (answers at a
few words per second); a GPU with 6 GB+ of VRAM makes it conversational.
Docker is needed for Open WebUI. Disk:
~6.5 GB for the Open WebUI image plus ~4 GB of models.

1. **Install Ollama** (<https://ollama.com/download>) and pull two models: a
   multilingual **embedding** model, so Spanish questions find English text and
   vice versa, and a small **chat** model.

   ```bash
   ollama pull bge-m3      # embeddings, 1.2 GB, 100+ languages
   ollama pull qwen3:4b    # chat, 2.5 GB; qwen3:8b if you have 8 GB of VRAM
   ```

   **Cap the context window.** Recent Ollama releases load a model with its
   *maximum* context unless told otherwise: `qwen3:4b` asked for 256k tokens
   and took 43 GB, spilling to the CPU and stalling for minutes. 8k is plenty
   for a few retrieved chunks; a named variant makes it stick for every client:

   ```bash
   printf 'FROM qwen3:4b
PARAMETER num_ctx 8192
' > Modelfile
   ollama create study-qwen3-4b -f Modelfile     # 3.9 GB loaded, fits a 6 GB GPU
   ```

2. **Start Open WebUI**, pointed at Ollama on your host:

   ```bash
   docker run -d --name open-webui -p 3000:8080 \
     --add-host=host.docker.internal:host-gateway \
     -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
     -e RAG_EMBEDDING_ENGINE=ollama -e RAG_EMBEDDING_MODEL=bge-m3 \
     -v open-webui:/app/backend/data \
     ghcr.io/open-webui/open-webui:v0.12.2
   ```

   That is the Docker Desktop form (Windows, macOS, WSL), where
   `host.docker.internal` reaches the host — the one tested here. **On native
   Linux** Ollama listens on `127.0.0.1:11434`, which a bridged container
   cannot reach through `host-gateway`. Share the host's network instead, and
   keep Open WebUI on loopback too (with host networking `-p` is ignored and
   it would otherwise listen on every interface):

   ```bash
   docker run -d --name open-webui --network host \
     -e HOST=127.0.0.1 -e PORT=3000 \
     -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
     -e RAG_EMBEDDING_ENGINE=ollama -e RAG_EMBEDDING_MODEL=bge-m3 \
     -v open-webui:/app/backend/data \
     ghcr.io/open-webui/open-webui:v0.12.2
   ```

   Do not make Ollama listen on `0.0.0.0` to work around it: its API has no
   authentication, so that exposes it to your whole network.

   Open <http://localhost:3000> and create the first account (it is local and
   becomes the admin). Pin a release tag rather than `main`.

3. **Copy the material of one certification in one language**, with names that
   say where each file came from (every topic file is called `content.md`, so
   citations would otherwise all read the same):

   ```bash
   CERT=cka LANG_=en; mkdir -p ~/study-kb/$CERT-$LANG_
   for f in certs/$CERT/*/$LANG_/*.md; do
     topic=$(basename "$(dirname "$(dirname "$f")")")
     cp "$f" ~/study-kb/$CERT-$LANG_/$CERT-$topic-$(basename "$f")
   done
   ```

   One certification in one language keeps the model from mixing seven
   translations of the same text.

4. **Workspace → Knowledge → New**, name it `cka-en`, and upload the folder.
   In a new chat pick the model `study-qwen3-4b`, type `#` and pick `cka-en`
   to attach it, then ask: *"Explain how a PersistentVolumeClaim binds to a
   PersistentVolume."* Answers cite the chunks they came from (`[1]`, `[2]`).

**Measured on 2026-10-14** (Ollama 0.40, Open WebUI v0.12.2, a 16 GB AMD GPU):
the 54 CKA files in English indexed in 105 s, and a question asked in Spanish
against the English material was answered in Spanish, with citations, in under
90 s including the first model load. On a CPU only, expect indexing in minutes
and answers at a few words per second.

Treat answers like the material itself: check them against the official
documentation each topic links to.

*Simpler still, with no Docker:* [AnythingLLM Desktop](https://anythingllm.com)
is a single installer that bundles its own vector store and can use the same
Ollama models; drag the same folder into a workspace.

### Use it from your own AI agent (MCP)

The repository ships an [MCP](https://modelcontextprotocol.io) server with four
read-only tools — `list_certs`, `get_syllabus`, `get_topic`, `search_topics` —
so any MCP-capable agent, including one on a local model, can study against
the corpus:

```bash
make mcp-setup    # once: installs the MCP SDK into .venv
make mcp-check    # drives the server over stdio and prints what it answers
```

[`.mcp.json`](../.mcp.json) is the configuration; point your client at
`.venv/bin/python3 -m teach.mcp_server`, run from the repository root.

### The study bot on the site (not sovereign — your own key)

The site's **Study bot** answers questions about a topic using **your own
[OpenRouter](https://openrouter.ai/keys) key**. The key stays in your browser
and goes straight to OpenRouter; this server never sees it, and the platform
pays nothing. It is the easiest option, but your questions do go to a third
party. Model tiers, prices and the free models are shown before you send:
[docs/STUDY_BOT_DESIGN.md](STUDY_BOT_DESIGN.md).

## REST API

Same data as the site, JSON, `GET`, no key. Hosted at
`https://study.cybercirujas.club` (a home server, beta, no uptime guarantee —
run your own for anything serious) or at `http://localhost:8000` on your copy.
Interactive reference at `/docs`, schema at `/openapi.json`.

```bash
API=http://localhost:8000

curl -s $API/api/langs                          # {"langs":["es","en",...],"default":"en"}
curl -s $API/api/catalog | jq 'keys'            # every certification id
curl -s $API/api/certs/cka | jq '.topics[] | {id, title, langs}'
curl -s "$API/api/certs/cka/topics/1.1?lang=es" \
  | jq '{lang, lang_fallback, generated_by, chars: (.content|length)}'
curl -s "$API/api/search?q=etcd%20backup&limit=3" | jq '.hits[] | {cert, id, title}'
curl -s $API/api/status | jq '.[] | {id, generated, topics, langs, state}'
```

Full endpoint table, licence of the material and how to build on it:
[docs/DEVELOPERS.md](DEVELOPERS.md).

## Command line

`make setup` installs `teach`. What a student uses, all offline and free:

```bash
.venv/bin/teach cert list            # every certification, version, upstream state
.venv/bin/teach cert show cka        # syllabus: id, weight, title of every topic
.venv/bin/study-lab run cka 1.1       # break-and-fix lab in a container (see above)
.venv/bin/teach serve                # same as make serve
```

The rest of the CLI (`cert generate`, `cert translate`, `tracker sync`, …)
calls a model and is for maintainers: [docs/OPERATING.md](OPERATING.md).
