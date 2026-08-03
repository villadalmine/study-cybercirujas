# Changelog

Record of what has been delivered. Free-form, reverse chronological order (most recent first). Design details live in [PLAN.md](PLAN.md); pending items live in [BACKLOG.md](BACKLOG.md).

## 2026-08-03

- **Translation Cost/Quality Study — Measured, Not Estimated** ([docs/TRANSLATION_STUDY.md](docs/TRANSLATION_STUDY.md), reproducible with `scripts/translation_study.py`). Same topic, same prompts imported from `generator.py` so the study cannot drift from what the pipeline does, `temperature: 0`, six models through the LiteLLM proxy, every output through both gates. Result: **`cheap` (Qwen Turbo) is safe for translation and `claude` stays for authoring.** `cheap` passed 3/4 topics first try and 4/4 with one retry, at $0.0007/file against $0.05 for `claude-sonnet`, with prose read by hand and found indistinguishable. `free2` and `deepseek-free` were rejected on substance — one summarised 10 KB into 1.7 KB, the other dropped a citation URL — which is exactly the class of damage that must never ship silently. The saving that matters is **Claude quota, not dollars**: of 117 pending combos, 32 have a good Spanish source and translating them frees ~3.7 h of authoring quota for the 85 that have none.
- **`_verify_translation` Was Rejecting Every Correct Translation** — found by the study, and it would have blocked translation on *any* model including Claude. It demanded code blocks be byte-identical, but comments inside them are prose that must be translated: the authored English cks/1.1 has 12 English comments against 2 Spanish ones in its source, so translating them is the standard the material itself sets. Fixed by blanking comment text before comparing while keeping the `#` marker, so a *deleted* comment line is still caught. Placeholders are deliberately left strict: `<none>` is real `kubectl` output and appears identically in both languages, no pattern separates it from `<pod-ip-destino>` reliably, and a false rejection costs one $0.0008 retry while a false acceptance ships corrupted output. New `tests/test_translation_verify.py` covers both directions (8 tests; suite 23 → 31, all passing).
- **Cluster Access Fixed at the Source** (in `projects/leloir`, left uncommitted — a push there triggers CI + ArgoCD). `connect-cluster.sh` only knew how to reach the cluster from outside: it always built an SSH tunnel and always pointed the kubeconfig at `127.0.0.1:6443`, so on the LAN, with no tunnel up, kubectl simply failed. Added a `lan` mode (direct to node1, no tunnel or Tailscale) and made `status` read-only — it used to rewrite the kubeconfig back to `127.0.0.1`, so *checking* the state broke a working LAN connection. This is what unblocked the study: the LiteLLM key lives in the cluster.

## 2026-07-29

- **Third Instance of the Same Audit Blind Spot Found and Fixed** — and this one invalidated yesterday's fix. `find_bad_combos()` enumerated language directories with `cert_dir.glob("*/{lang}")`, which only sees directories that already exist. A topic never generated in a language has no directory at all, so it was skipped entirely and the audit reported **0 corrupt for `cks/en` while only 6 of 26 topics existed**. Adding `en` to `TARGETS` (done yesterday) was therefore necessary but not sufficient — the audit still could not see the gap. Fixed by enumerating topics from the syllabus frontmatter instead of from disk, the same approach the lab check has used since 2026-07-16; that fix closed the hole for files missing *inside* an existing directory, this one closes it for the missing directory itself. Re-audit now reports exactly the 20 missing `cks/en` topics and **zero false positives** across every other combo (lpi-010-160 ×7, ckad ×2, cka ×2, kcna, cks/es), which is what confirms the change is a real detection improvement and not just noise.
- **CKS English Translation Started — 6/26, Incomplete.** Domain 1 complete (1.1–1.5) plus 2.1, all clean (well above the 1500-byte floor, correct `#` heading, exercises closing with the collapsible `<details>` answers section). The run stopped at topic 2.2 on **"You've hit your monthly spend limit"** from the `claude` CLI. Note the failure was silent at the shell level: the command is piped through `tee`, so the pipeline exited 0 and the background task reported success — the error was only visible in the log body and in the file count on disk. Resuming needs no special handling (`teach cert generate cks --lang en --backend claude` skips what exists, per-language), it just needs quota.

## 2026-07-28

- **Audit Blind Spot Closed in `scripts/fix_corrupted_content.py`**: `TARGETS` only listed `es` for `ckad`/`cka`, so the newly generated English content was never scanned — the same class of blind spot as the 2026-07-16 missing-files bug (the audit reports "0 corrupt" for what it does not look at). Added `en` to both. Re-audited with the widened targets: **0 corrupt combos** (no new findings, the English content was already clean). Certs still Spanish-only (`cks`, `kcna`) keep a single language until they are translated.
- **Backlog Reconciled Against `STATUS.md`**: the blocking regeneration item and the CKA item were still listed as pending despite being done; moved here. `STATUS.md` re-generated from the filesystem — no diff, so the committed matrix was already current. Also corrected two stale claims: `LFCS`/`LFCA` do have snapshots (at domain granularity, not sub-topic), and the admin/admin auth stub described under Platform was already removed on 2026-07-19.
- **RAG Study Bot Proposal Audited** (the untracked `chart/`, generated with Kimi AI on 2026-07-27) and written up as a backlog section with a phased split. Rendered rather than merely read, which surfaced blockers a review of the YAML would have missed: the chart does not `helm template` at all (`redis.service.port` is referenced but absent from values), and Go template expressions embedded in `values.yaml` are never expanded by Helm, so every service hostname (`POSTGRES_HOST`, `OLLAMA_HOST`, `REDIS_HOST`) reaches the pods as a literal `{{ .Release.Name }}-postgres` string. Also flagged: 4 subsystems configured with no manifests, default credentials, a 70b model that does not fit the stated 8 GB GPU, and a direct conflict with this repo's standing "no third-party labs on the home cluster" decision. Kept untracked pending fixes. The two `study-cybercirujas-full.zip` copies were byte-identical archives of `chart/` (`diff -r` clean) and were deleted.

## 2026-07-27

- **CKAD and CKA Translated to English**: both certs now have complete English content + exercises (ckad 24/24, cka 27/27 for both `content.md` and `exercises.md`), regenerated topic by topic across 8 commits. No file below 1500 bytes and no recap stubs — the `generator.py` fixes from 2026-07-12/16 (`--disallowedTools`, `_reject_if_recap` checking first *and* last line, `_strip_fence`) held for the whole run.
- **Corrupted-Content Regeneration Closed (was the blocking backlog item)**: `fix_corrupted_content.py` reports 0 corrupt combos across lpi-010-160 (7 languages), ckad, cka, cks and kcna. The deploy freeze on translations/CKAD declared in the 2026-07-12 entry no longer applies.

## 2026-07-19

- **Repository Published on GitHub**: https://github.com/villadalmine/study-cybercirujas (public). Before publishing: generalized internal cluster hostnames in README/values-study.example.yaml (not secret, but home network topology), added `LICENSE` (Apache 2.0), and confirmed no tracked secrets (checked for api-key/token/password patterns, `.env`, `.pem`, `kubeconfig`, etc. — 0 real results, the only match was the placeholder in values example).
- **Copyright Audit & AI Content Generation Verification**, requested before trusting the public release:
  - **No scraped text is persisted**: `tracker.py` (`fetch_text`) loads official HTML/PDF content strictly in-memory for the LLM prompt and never saves it to disk/repo — the only thing frozen in `certs/*.md` is structured metadata (id/title/topic/weight), never third-party prose.
  - **The generator forbids copying literal text** (`_system()` in `generator.py`: "Never copy literal text from third-party materials") and content is 100% generated via real calls to an AI backend (litellm/claude/codex/gemini) — also verified empirically: 0 `content.md`/`exercises.md`/`break_fix.sh` files are byte-for-byte duplicates across topics (any hardcoded templates would show up as exact duplicates).
  - **CNCF (`github.com/cncf/curriculum`) is CC-BY 4.0** — verified against the actual repo README, matches what was already in the website footer. LPI does not publish an explicit license tag for its objectives pages, but the approach (metadata only + `robots.txt` allows scraping those routes + 100% original final content) is the same used by any third-party prep book/course — LPI prose is not copied anywhere.
  - **No third-party logos/branding**: the only tracked binaries are 11 `thumbnail.png` rendered with Pillow (text on solid backgrounds, no external images embedded) — confirmed visually. TTS voices are Piper (open voices from `rhasspy/piper-voices`), no third-party audio.
  - **Real bug found**: `certs/lpi-010-160/2.3/de/content.md` had full real content (186 lines) + an LLM meta-comment appended at the end ("Ich habe in dieser Session keinen Zugriff auf Datei-Tools... hier ist der vollständige Inhalt zum manuellen Einfügen") — same family of bug as the known recap-stub, but at the END of the file rather than the beginning, so it slipped past `_reject_if_recap` in `generator.py` and `fix_corrupted_content.py` which only checked the first line. Fixed in both files to check the last line as well; the file was regenerated clean. Full repo scan with the expanded pattern: **0 more cases** (it was an isolated case, 1 of 476 content `.md` files).

## 2026-07-17

- **Implemented Local Lab Provider (Docker), first step of SDD roadmap in PLAN.md** — until now, `labs.py` only had Terraform code, so `teach lab up` failed on 100% of existing labs (all declare `provider: local` in their `lab.yaml`, none `terraform`). Now it dispatches in two variants depending on what `break_fix.sh` needs (detected reading the script, without having to regenerate 100+ existing `lab.yaml` files): a `kind` cluster (Kubernetes-in-Docker) for labs using `kubectl` (all CKA/CKAD/CKS/KCNA), or a simple Debian/Ubuntu container for those that don't (LPI Linux Essentials). `teach lab status` now checks actual docker/kind process status instead of blindly trusting `status.yaml`. **Not verified against real Docker/kind** (not installed on the writing machine) — dry-run with mocked subprocess only. See BACKLOG.md before using with real students.
- **Certification Videos Scaled to all 5 Content-Complete Certs** (cka, ckad, cks, kcna, lpi-010-160), in Spanish. Two real bugs found and fixed along the way:
  - **Syllabus script YAML broken by unquoted `:` in sentences** (reproduced with `cks`: `"No es teoría: es defender..."` — a `: ` inside a plain scalar is ambiguous for the YAML parser and breaks it). This is a format issue, not a content or backend one; `_ask_scenes` now retries up to 3 times (asking the model explicitly to quote any sentence containing `:`) before failing.
  - **`lpi-010-160` weights its domains in points summing to 40, not % summing to 100** (unlike CNCF temarios, which use %) — without normalization, the domain video scene would show "7%" for a domain that is actually "7 out of 40 points", which is incorrect. `_cert_domains()` now normalizes to percentage of total before displaying.
- **CKS Added to Catalog**: snapshot of the official syllabus (`CKS_Curriculum v1.34` PDF, 26 topics, correct domain weights) + content/exercises/labs in Spanish, 26/26 clean. Survived an external process `kill` (at 14/26) and two Claude API quota cuts (at 19/26 and 24/26) — resumed each time without losing progress because `teach cert generate` skips already generated topics. 2 labs remained half-generated due to cuts; `fix_corrupted_content.py` detected them (now checks missing labs too) and completed them automatically.
- **KCNA Added to Catalog**: same weight-by-domain bug as CKAD found when reviewing `STATUS.MD` (weights summed to 360 instead of 100, each sub-topic had the full domain weight) — re-snapshotted with the fixed `tracker.py`, now sums to 100 clean (44/16/28/12). Content generated, 13/13 in Spanish. **This completes the `kubernetes` career path (KCNA → CKA/CKAD → CKS) across all 4 certs.**
- **Video in More Languages**: Piper does have German and Chinese voices (`de_DE-thorsten-high`, `zh_CN-huayan-medium` — verified against the supported list in `rhasspy/piper-voices` repo; Japanese has no Piper voice and remains blocked). Videos of `linux-admin` and `kubernetes` generated in English and German. `core/video.py` now chooses fonts per language (Noto Sans CJK for zh/ja if installed, falls back to Liberation Sans) so Chinese slides do not render square tofu blocks.
- **STATUS.MD (New)** + `scripts/status_matrix.py`: matrix of completed cert/language/lab/video, generated from actual filesystem counts — run the script after any generation. Already helped spot the KCNA bug above.
- **New Feature: Certification-Specific Video** (not just career paths). Same pipeline (Piper + Pillow + ffmpeg) as path videos, with a new deterministic "exam domains" scene (bars showing the real weight of each domain, summed from `cert.md` topics — never hallucinated by AI) replacing the certification map. `teach cert video-script`/`teach cert video` (new), `/api/certs/{id}/video` endpoint (new, same language fallback as paths), video visible on the cert page. Tested on `cka` (52s, 4 scenes) before scaling.
- `cks` added to `TARGETS` in `scripts/fix_corrupted_content.py` and `scripts/resume-generation.sh` (same fence and missing files check as lpi-010-160/ckad/cka).

## 2026-07-16

- **Bug Found and Fixed in `scripts/fix_corrupted_content.py`: only detected corrupt files, not missing ones.** The script audited `cert_dir.glob(".../content.md")` — if the file did not exist, the glob simply skipped it, so a half-generated topic (process killed between the two completions, e.g. from an old session) went unnoticed even if the audit reported "0 corrupt combos". 3 real holes were found: `ckad/5.3/es/exercises.md` (and its entire lab) and labs for `ckad/2.3` and `ckad/3.4` were missing. The "19/19" / "24/24" checks in previous entries only counted `content.md` existence. Fix: the script now loops over language directories (detecting missing `content.md`/`exercises.md`) and the syllabus topic list — not disk — for labs (detecting missing `break_fix.sh`). Regenerated the 3 holes; audit now confirms 0 combos across the three certs. Redeployed.
- **CKA Added to Catalog**: snapshot of the official syllabus (`CKA_Curriculum_v1.35.pdf`, 27 topics) + content/exercises/labs in Spanish, 27/27 clean. The weight-by-domain bug (seen in CKAD) was fixed at the code level in `teach/core/tracker.py::snapshot_topics`: explicit prompt requesting splitting domain weights among sub-topics, plus a validation check that rejects the snapshot (`TrackerError`, not saved) if weights do not sum to ~100. Correct on first attempt.
- **Video of the `kubernetes` Career Path** (Kubernetes Engineer, es, 111s/7 scenes). Also fixed a PATH bug: `piper` (TTS) lives in `.venv/bin`, not system PATH, and failed in environments without the activated venv. `teach/core/video.py` now resolves it via `sys.executable`.
- **New Bug Found and Fixed: Wrapping Code Fences.** The `claude` backend sometimes returns the entire content wrapped in markdown code fences (` ```markdown ` at the start, ` ``` ` at the end) despite prompt rules — not corruption, but breaks web rendering. Seen first in CKA (18 of 81 files). Fix in `teach/core/generator.py::_strip_fence` (applied before saving and before anti-recap validation); `scripts/fix_corrupted_content.py` gets an in-place cleanup step to fix already affected files without wasting AI quota.
- **Confirmed Corrupted Content Cleaned**: `scripts/fix_corrupted_content.py` ran repeatedly via the systemd timer and converged to **0 corrupt combos**. Manual verification: lpi-010-160 complete 19/19 in all 7 languages, ckad 24/24 in es, no files below 1500 bytes. lpi-010-160 and CKAD enabled for deploy.

## 2026-07-11/12

- **Critical Bug Found and Fixed: Generator Saved Process Summaries Instead of Actual Content.** `teach cert generate --backend claude` runs `claude -p` without tool restrictions and with cwd in the repo — the model sometimes acted as a coding agent (explored the repo, tried writing files itself via its write tool) and returned a summary of that action ("Written complete study content to ja/content.md...") instead of the requested content — which the pipeline saved as-is. Deterministically reproduced. Audit found **~170 corrupt files** (73% of reviewed) among lpi-010-160 translations (pt/fr/de/zh/ja) and CKAD.
  **Fix in `teach/core/generator.py`**: (1) `claude -p --disallowedTools "Write,Edit,Bash,Read,Glob,Grep,NotebookEdit,WebFetch,WebSearch,Task" --` forces the model to respond in plain text without tool use; (2) `_reject_if_recap()` validates each response before saving and rejects anything matching this bug.
  `scripts/fix_corrupted_content.py` audits and regenerates (with `--force`) remaining corrupt files. **This invalidates the entry below** ("lpi-010-160 multilingual complete") — the file count (19/19) never measured quality, only existence.
- ~~**lpi-010-160 Multilingual Complete**: content + exercises generated in the 7 supported languages, 19/19 topics each.~~ See entry above.
- **Path Videos (New Feature)**: custom pipeline without external APIs — script written by AI and frozen in `script.yaml` (with the factual certification map always deterministic from `catalog.yaml`), Piper TTS narration, Pillow slides, and ffmpeg render (`libopenh264`). First video: `linux-admin` path in Spanish. Served via `/media` + `/api/paths/{slug}/video`. Module: `teach/core/video.py`.
- **CKAD Added to Catalog**: snapshot of the official syllabus (PDF from `cncf/curriculum`, 24 topics) + content/exercises/labs in Spanish. Corrected snapshot bug: the CNCF PDF only gives weights per domain (20/20/15/25/20 = 100%), not per sub-topic; the snapshot copied the full domain weight to each sub-topic. Fixed by distributing the domain weight among its topics.

## b7a8edb — Open Web

Study content without login (previously required active session + paid plan) + complete English content (19/19) in lpi-010-160.

## 32b929f — Landing Page

Highlights organizations (LPI vs Linux Foundation) within the Linux category.

## deca856 — Local Deploy

`study.cluster.home` served from the cluster (home k3s).

## 12e01a6 — Paths + Linux Foundation

Paths i18n + separate Linux Foundation track (LFCA/LFCS) from LPI. Build without CI workflow.

## 1d4bd14 — Multilingual + Deploy

First multilingual version + style adjustments + Helm chart.

## f6559b5 — Tracker/Scraper

Catalog derived from official sources, nothing static.

## 9302677 — Paths: Nodes with Cert Names

Nodes display certification names in addition to exam codes.

## 28314d8 — teach-plat

Initial commit of the IT certification study platform.
