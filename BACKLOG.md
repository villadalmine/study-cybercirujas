# Backlog

Pending items, without strict ordering unless specified. Resolved items go to [CHANGELOG.md](CHANGELOG.md); design details live in [PLAN.md](PLAN.md).

## In Progress / Next (Ordering)

0. **(Blocking) Complete regeneration of corrupted content.** See CHANGELOG.md
   — `scripts/fix_corrupted_content.py` is running (manually + systemd timer) regenerating ~170 files for lpi-010-160 (pt/fr/de/zh/ja, and es/en just in case) and CKAD that had process summaries saved as actual study content. **Do not deploy or commit translations/CKAD until a run of this script reports 0 corrupted combos** — run again and confirm before any `make image-cluster`. The script does not deeply cover `lab/break_fix.sh` for CKAD yet (it checks existence at the end, but the project history shows this file frequently reverts to a stub — verify separately before trusting CKAD labs).
1. **CKA** (Certified Kubernetes Administrator): snapshot of the official syllabus (PDF `cncf/curriculum`) + content/exercises/labs in Spanish. Watch out for the same bug that appeared in CKAD: the CNCF PDF only gives weights per domain — distribute them among sub-topics before generating, do not copy the whole domain weight. Now that the generator is fixed (`--disallowedTools`), this should run clean, but verify with `wc -c` anyway.
2. **Video for another path** — candidate: `kubernetes` (Kubernetes Engineer), as it shares the same content as CKA/CKAD. To be confirmed/assigned.

## Content

- **See [STATUS.md](STATUS.md)** for the complete matrix of cert × language × lab, path × video language, and cert × video language (regenerate with `scripts/status_matrix.py` from actual filesystem — do not trust manual updates).
- ~~CKS in progress~~ **Done (2026-07-17)**: 26/26 in Spanish (content + exercises + labs, verified with `fix_corrupted_content.py` at 0 and per-file counts, not just topic status). Survived an external process `kill` and two Claude API quota cuts in the middle — resumed cleanly each time because topic generation is idempotent.
- Translate CKAD, CKA, CKS, and KCNA to the other 6 languages — currently they only exist in Spanish.
- ~~Review if other CNCF certs already snapshotted (KCNA, KCSA, CKS, etc.) have the same weight-by-domain issue before generating content for them~~ **KCNA had the bug** (weights summed to 360, each sub-topic had the full domain weight copied) — re-snapshoteated with the fixed script, now sums to 100, and content is generated (13/13). `KCSA`/`LFCS`/`LFCA` do not have topics yet (no snapshot) so they do not apply.
- Video for remaining paths without video: `linux-devops`, `kubernetes-security`, `gitops-platform` (see STATUS.md for the full real list).

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

- Multi-provider labs, real user auth (currently admin/admin stub), Go lab-runner working against the `lab.yaml`/`terraform/`/`status.yaml` contract.
- Improve web presentation: currently displays raw content; needs Markdown rendering, styles, navigation. (low priority).
