# Backlog

Pending items, without strict ordering unless specified. Resolved items go to [CHANGELOG.md](CHANGELOG.md); design details live in [PLAN.md](PLAN.md).

## In Progress / Next (Ordering)

Standing rule for any generation run: after finishing, re-run `scripts/fix_corrupted_content.py` **and** check that the cert/language is actually listed in its `TARGETS` — an audit reporting "0 corrupt" only proves the combos it scans are clean. Add the new language to `TARGETS` in the same commit that generates it.

1. **Verify the local Docker lab provider against real Docker/kind.** Highest-risk open item: the code is implemented but was only dry-run tested with mocked subprocess calls (see the Labs section below). Nothing here should be offered to students until `teach lab up lpi-010-160/2.1` (plain container) and `teach lab up cka/1.1` (kind cluster) both run on a machine that actually has `docker`/`kind`.
2. **Translate `cks` and `kcna` out of Spanish-only.** `cks` → English is **in progress and stalled at 8/26** (1.1–1.5, 2.1–2.3) — the monthly API spend limit cut the run twice. Resume with `teach cert generate cks --lang en --backend claude`, which skips what already exists; the 18 outstanding topics are listed by `fix_corrupted_content.py`. Then `kcna`, then the other 5 languages for all four CNCF certs. Budget ~7 min per topic, measured. Generate in small batches rather than whole-cert runs — the credits are a real constraint.

   **Publishing rule: do not build or deploy the image until a cert is complete in the language being worked on.** Partial translations are safe on the site (`certs.py::topic_content` falls back to Spanish and flags `lang_fallback`), but they are not published — one image build per finished cert. Committing partial progress to git is fine and expected.
3. **Content for `lfcs` (5 topics) and `lfca` (6 topics)** — both have a snapshotted syllabus but zero generated content in any language, so they are the cheapest way to widen the catalog (no scraping step needed).
4. **Videos for paths without one**: `linux-devops`, `kubernetes-security`, `gitops-platform`, `observabilidad`, `service-mesh-networking`, `linux-foundation`. The `kubernetes` path is already done (es/en/de).
5. **RAG study bot, phase 1 (anonymous)** — see the dedicated section below for the audit of the `chart/` proposal. Worth starting whenever there is appetite for a feature rather than more content: the corpus already exists and phase 1 needs no auth and no new cluster.

## Content

- **See [STATUS.md](STATUS.md)** for the complete matrix of cert × language × lab, path × video language, and cert × video language (regenerate with `scripts/status_matrix.py` from actual filesystem — do not trust manual updates).
- ~~CKS in progress~~ **Done (2026-07-17)**: 26/26 in Spanish (content + exercises + labs, verified with `fix_corrupted_content.py` at 0 and per-file counts, not just topic status). Survived an external process `kill` and two Claude API quota cuts in the middle — resumed cleanly each time because topic generation is idempotent.
- ~~Translate CKAD, CKA, CKS, and KCNA to the other 6 languages — currently they only exist in Spanish.~~ **Partially done (2026-07-27)**: CKAD and CKA now have English (24/24 and 27/27). Remaining: fr/de/zh/ja/pt for those two, and every non-Spanish language for CKS and KCNA — see item 2 above.
- ~~Review if other CNCF certs already snapshotted (KCNA, KCSA, CKS, etc.) have the same weight-by-domain issue before generating content for them~~ **KCNA had the bug** (weights summed to 360, each sub-topic had the full domain weight copied) — re-snapshotted with the fixed script, now sums to 100, and content is generated (13/13). `KCSA` still has no snapshot (0 topics) so it does not apply. `LFCS` (5) and `LFCA` (6) do have snapshots and their weights sum to 100 correctly — but only at **domain level**, one topic per domain, unlike cka/ckad/cks which are snapshotted at sub-topic granularity (27/24/26). Decide before generating: 5 enormous topics, or re-snapshot into sub-topics for a comparable reading unit.
- Certification videos exist only in Spanish (5 certs). Path videos reach German at most. `ja` is blocked on TTS (see below); the rest is just render time.

## Video — Technical Debt

- ~~No Piper voice configured for de/zh~~ **Resolved (2026-07-17)**: Piper does have de/zh voices (`de_DE-thorsten-high`, `zh_CN-huayan-medium`), added to `VOICES` in `core/video.py`. **`ja` remains blocked** — Piper does not have any Japanese voice (full list of supported languages verified against the `rhasspy/piper-voices` repository); another TTS would be needed to narrate in Japanese.
- ~~No CJK font installed~~ **Resolved (2026-07-17)**: `core/video.py` now picks Noto Sans CJK (`google-noto-sans-cjk-fonts`) for zh/ja if installed (falls back to Liberation Sans if not, without breaking) — installed manually on the dev machine with `sudo dnf install google-noto-sans-cjk-fonts`. Only needed on the machine rendering the videos (local Pillow), not in the Docker image — the generated mp4 is baked into the build like any other file in `media/`.

## Labs — Execution Modes (see PLAN.md, SDD section)

Suggested order (each stage reuses the previous one):

1. ~~**Local Docker (free, first).**~~ **Implemented (2026-07-17), but NOT verified against real Docker/kind** — the dev machine where this was written did not have `docker` or `kind` installed, so it was only dry-run tested with mocked subprocess calls. **Test `teach lab up lpi-010-160/2.1` and `teach lab up cka/1.1` on a machine with Docker before offering this to real students.** `labs.py` now dispatches based on the `provider` field in `lab.yaml` (currently always `local`, `terraform` is left for step 3):
   - If the topic's `break_fix.sh` uses `kubectl` (all CKA/CKAD/CKS/KCNA): boots a `kind` (Kubernetes-in-Docker) cluster and runs the script against it. Requires `kind`+`kubectl`+`docker` installed.
   - Otherwise (LPI Linux Essentials): runs the script inside a simple Debian/Ubuntu container as a non-root user (the scripts refuse to run as root). Requires only `docker`.
   - `teach lab status` now checks the actual docker/kind process status instead of blindly trusting the last written `status.yaml` (if the container/cluster died or was manually deleted, it detects it and marks it `failed`).
   - Pending item: generate the explicit `Dockerfile`/`docker-compose.yml` mentioned in the original PLAN.md — the current version runs the container directly using `docker run` (simpler, same result for v1) instead of a versioned compose file; review if compose is worth it when there is demand for multi-container labs.
2. **Exercise Video — Actual Capture, No Mock.** Same principle as the marketing video (factual data is never written by AI — see the path scene in `core/video.py`): spin up the actual container from `lab.yaml`, run `break_fix.sh` for real, and record the session using **asciinema** (`.cast` file, text format, KB not MB, reproducible/scalable, self-hostable player) instead of mocking the terminal with AI or rendering MP4. The AI only writes the voiceover narration (Piper TTS, as already done).
3. **Paid A — BYO-Cloud + Terraform.** Extends the existing contract in `labs.py` (`up`/`down` over `lab/terraform/`): generate the Terraform module per topic, v1 has the student running `terraform apply` using their own credentials (the platform never touches them). A "one-click" mode where the platform runs Terraform with credentials pasted by the student is more convenient but turns the platform into a custodian of third-party cloud credentials — defer until proven demand.
4. **Paid B — Hosted by Me, "Connect" Button → Auto-destruction.**
   Main risk: the platform runs on a home cluster, publicly exposed. **Do not run third-party labs there** — direct blast radius to the home LAN (lab escape, mining, lateral movement). Alternative: ephemeral VM per session in a separate, cheap cloud provider (Hetzner/DO, billing per minute) using the same "toolbox" image, hard timeout (30-60 min), concurrent session limits, web terminal via xterm.js+websocket, and `terraform destroy` upon session close. Also evaluate existing ephemeral sandboxes (E2B, Coder, Gitpod) before building custom isolation hardening.

## Deploy — Technical Debt

- ~~**`make image-cluster` used a fixed `TAG` that could diverge from the Helm release in production without visible errors.**~~ **Resolved (2026-07-16)**:
  Default `TAG` is now `$(shell date +%Y%m%d%H%M%S)` in the Makefile — a fresh timestamp per invocation, instead of a manual sync number between Makefile and Helm. Note: it is still the deployer's responsibility to pass the SAME explicit `TAG=...` to `make image-cluster` and `make deploy-local` in the same run (running `make` twice without an explicit `TAG=` generates two different timestamps and breaks build↔deploy pairing).

## Platform (Long-Term Roadmap, see PLAN.md)

- Multi-provider labs, and a Go lab-runner working against the `lab.yaml`/`terraform/`/`status.yaml` contract.
- **Real user auth.** The admin/admin stub was removed on 2026-07-19; `teach/core/auth.py` is now a deliberate deny-all placeholder (`authenticate` and `has_subscription` both always return `False`) since all content is public and login-free. This only becomes blocking when the paid lab tier ships — that is the thing that needs a real identity (OIDC/social) plus a payment gateway behind it, not the content.
- Improve web presentation: currently displays raw content; needs Markdown rendering, styles, navigation. (low priority).

## RAG Study Bot — Proposal Under Review (`chart/`)

Untracked design artifact in `chart/`: a Helm chart plus `CONTEXT.md`, generated from a conversation with Kimi AI on 2026-07-27 for architecture review. It proposes a self-hosted RAG assistant (pgvector + Ollama + FastAPI bot + hourly embedder CronJob) on top of the existing content, plus KubeVirt/vcluster labs and Guacamole browser access. **Not deployable as it stands** — see the audit below. The two `study-cybercirujas-full.zip` copies were byte-identical archives of `chart/` itself and were deleted (`diff -r` clean, nothing lost).

**The idea is sound and the corpus is already there.** 274 `content.md` + 274 `exercises.md` (~5.5 MB of markdown, 218 es / 140 en / 38 each in fr,de,zh,ja,pt) — enough to be a genuinely useful retrieval corpus, and it is already chunked by cert/topic/language, which is exactly the metadata the proposed `study_embeddings` table wants. `VECTOR(1024)` correctly matches multilingual-e5-large and BGE-M3, and a multilingual embedder is the right call given the 7-language content.

**What the chart gets wrong (verified by rendering it, not by reading it):**

1. **It does not render at all.** `helm template study ./chart` fails: `redis.yaml:51` dereferences `.Values.redis.service.port`, and the `redis:` block in `values.yaml` has no `service:` key. Hard stop before anything else.
2. **Service hostnames are dead on arrival.** `values.yaml` sets `POSTGRES_HOST: "{{ .Release.Name }}-postgres"` (same for `OLLAMA_HOST`, `REDIS_HOST`), but **Helm does not template `values.yaml`** — templates consume it as literal data. Forcing a render confirms the pods receive the literal string `{{ .Release.Name }}-postgres` as a hostname, so bot-api could never reach Postgres, Ollama or Redis. Fix: resolve the names inside the templates, or wrap the value in `tpl`. The `ollama.initContainers` block in `values.yaml` has the same defect (`{{- range .Values.ollama.models }}` never expands), so no model would ever be pulled.
3. **Four subsystems are values-only, with no templates**: `guacamole`, `kubevirt`, `vcluster`, `monitoring` all have configuration blocks and zero manifests. The chart advertises considerably more than it implements.
4. **Default credentials baked in**: `POSTGRES_PASSWORD: "changeme"` ×3 and Grafana `adminPassword: "admin"`. This repo went through a pre-publication secrets audit (see CHANGELOG 2026-07-19); committing this as-is would walk default creds straight back into a public repo. Move to `existingSecret` before any commit.
5. **`llama3.1:70b` will not run on the stated hardware.** `CONTEXT.md` lists a Tesla P4 (8 GB VRAM) and the model list requests 8b *and* 70b. A 4-bit 70b needs roughly 40 GB; it would spill to CPU and be unusable for interactive chat. 8b quantized fits comfortably. Drop 70b or plan for different hardware.
6. **Three images that do not exist**: `study-cybercirujas/bot-api`, `/embedder`, `/web`. The chart also assumes a static-site frontend and an embedder that clones content from `CONTENT_REPO_URL` into a PVC — whereas the real platform is a single FastAPI app serving markdown straight from `certs/` in the image. This is a v2 architecture, not an increment on `deploy/helm/`.

**Two conflicts with decisions already made in this repo — these are judgement calls, not bugs:**

- **Labs on the home cluster.** The Labs section below concluded explicitly: *do not run third-party labs on the home cluster* — direct blast radius to the home LAN. The proposal does exactly that (KubeVirt VMs and vcluster labs on the T7910, quota for 30 VMs, Guacamole exposed). Either the earlier risk analysis is revisited on purpose, or the lab half of this proposal is dropped and only the RAG half is kept.
- **Personalization needs identity.** The `user_profiles` / `user_progress` / `activity_log` tables assume logged-in users, but content is deliberately free and login-free and `auth.py` is a deny-all placeholder. This does not block the bot — it splits it.

**Suggested split — phase 1 is worth doing on its own:**

1. **Anonymous content bot (no auth, no new cluster).** Embed `certs/**/content.md` into pgvector, answer questions with citations back to cert/topic, run it as a route in the existing FastAPI app. Needs Postgres+pgvector and an inference backend — nothing else in the chart. This is the piece that delivers most of the value and conflicts with nothing.
2. **Personalized bot.** Progress tracking and mastery-aware answers — blocked on the real-auth item under Platform.
3. **Lab orchestration.** Revisit only after the home-cluster risk decision, and after the local Docker provider in the Labs section is actually verified.

Keep `chart/` untracked until at least items 1–4 above are fixed; a chart that cannot render should not land in a public repo as if it were deployable.

## Repo Hygiene

- `hola` is a one-line scratch note (a `claude --resume` command), untracked. Harmless, delete when no longer needed.
- Source comments and docstrings under `teach/` and `scripts/` are still largely in Spanish, which contradicts the English-only rule in `CLAUDE.md`. Mechanical to fix, but it is a wide diff — worth doing in one dedicated pass rather than drip-feeding it into feature commits.
