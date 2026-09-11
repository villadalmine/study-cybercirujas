# Changelog

Record of what has been delivered. Free-form, reverse chronological order (most recent first). Design details live in [PLAN.md](PLAN.md); pending items live in [BACKLOG.md](BACKLOG.md).

## 2026-09-11

- **The study bot's models are now verified by calling them, not by reading the
  catalogue.** Phase 1 feedback was that some models do not work and that the
  reasoning control is not understandable. Both were true, and `check_models.py`
  could not see either: it compares `models.yaml` against what OpenRouter
  *publishes*, and all eighteen models publish `reasoning: true`.
  `scripts/probe_models.py` (`make probe-models`) sends each one a fixed
  one-word question through the same endpoint, headers and `max_tokens` the
  browser uses, and grades the reply mechanically — `temperature: 0`, a seed,
  one substring, no model judging anything. **A full pass is ~51 calls and cost
  $0.0077**, on `LITELLM_API_KEY_BOT`: a second OpenRouter key with its own
  limit, so a probe can never reach the translation budget. `--dry-run` prints
  the worst case and sends nothing; a `--budget` stop (default $0.25) holds even
  if a provider starts thinking for the whole cap.

  What it found: 16 of 18 answered; two free models returned nothing on that run
  and are marked `flaky` rather than dropped. **Twelve models think when
  reasoning is switched off** — including `gpt-5-mini`, the bot's default, which
  spent 64 thinking tokens on a request that never mentioned reasoning, under a
  control labelled "No reasoning (cheapest)". Twelve stop when sent
  `reasoning: {enabled: false}`; four cannot be stopped at all ("Reasoning is
  mandatory for this endpoint and cannot be disabled"); and two — `sonnet-5`,
  `gpt-5.6-sol` — ignore the effort setting at every level including `high`.
  Two models classified differently on two runs, which is itself the finding:
  they decide per question whether to think, so `always` is the conservative
  verdict and the page sends the explicit off switch rather than trusting a
  default.

  The page now builds its menu and its effort selector from those verdicts:
  broken models are not offered, "no reasoning" sends the explicit off switch
  where that was proven to work, and where the setting does nothing the control
  is disabled with a line saying so — in all seven languages. The catalogue
  carries `probe`, `thinking`, `thinking_off` and `probed` per model, written by
  `--update`; `max_tokens` is probed at the page's own value because OpenRouter
  derives each provider's thinking budget from it. Findings table in
  [docs/STUDY_BOT_DESIGN.md](docs/STUDY_BOT_DESIGN.md).

- **Second pass: can the model read the material, and in which languages?** The
  first probe proved the models are alive. "Paris" says nothing about the thing
  the bot actually does, so the probe now sends each model an excerpt of a REAL
  topic of this corpus (`lpi-010-160/5.2`) with the page's own *use ONLY the
  material* prompt, and asks — in each of the seven languages the site offers —
  a question the excerpt answers. The expected answer is `/etc/passwd`: a path,
  identical in every translation, so one substring grades all seven and nothing
  is judged by a second model. The excerpt is read from the tree at probe time
  rather than frozen into the fixture, so it always asks about the material the
  site serves; `make verify` fails for free if that topic stops containing the
  answer.

  **164 calls, $0.27**: all fourteen paid models answered from the material in
  all seven languages. The free tier is where it shows — `nemotron-3-ultra`
  returns HTTP 200 with no content in Spanish, German and Chinese, `-super` in
  French, and both Gemmas were rate-limited before they could be asked. So
  `models.yaml` carries `langs:` per model and **the page offers a model only in
  the languages where it was proven**, with a line saying how many were hidden.
  A language with no proven model falls back to offering everything that answers
  rather than an empty menu — the rule is never to claim what was not measured,
  in either direction. The comprehension request also carries the reasoning off
  switch where the model accepts one, which is both what the page sends by
  default and most of why the pass costs cents.

  Built and deployed as `2026-09-11-bot-models` (helm revision 61) and verified
  live: study.cybercirujas.club serves all eighteen models carrying a probe
  date, two of them marked `flaky`. No model had to be replaced — every one
  still answers; what changed is that the page no longer claims things about
  them that were never measured.

## 2026-09-10

- **Study bot, phase 1 — the platform's first feature that is not content.** A
  Bot section where the student picks career → certification → topic, pastes
  their **own OpenRouter key**, and asks questions against that material. The
  key lives in `localStorage` and goes straight to openrouter.ai: no proxy, no
  account, no server state, and therefore **zero platform inference cost** —
  which is what makes it safe to offer on a public site after this project hit
  its monthly spend limit twice in three days. Design, phases and full token
  accounting in [docs/STUDY_BOT_DESIGN.md](docs/STUDY_BOT_DESIGN.md).

  Two design calls worth recording. **Explicit selection replaces retrieval**:
  because the student names the topic, the exact file is known, so it is sent
  whole (15–35k tokens, fits any modern model) instead of approximated by
  embeddings — no pgvector, no embedder, no new pods, and better accuracy than
  chunked search. And **the task harness ships in phase 1**: four intents with
  specialised prompts that know this corpus' conventions (the exercise writer
  follows the `<details>` solution format, the examiner weighs questions by
  syllabus domain weight, the explainer may cite only references already in the
  material). Without them the model improvises formats the corpus already
  defines — which is what "dumping raw material at the model" actually looks
  like.

- **The model catalogue became data.** `models.yaml` freezes the ids and prices
  the UI shows (top / mid / low / **free** tiers across Claude, OpenAI,
  DeepSeek, Qwen, Kimi, MiniMax and Gemma), `/api/models` serves it, and the
  page builds its selector from that — nothing about models is typed into
  JavaScript any more. The first draft had **invented model ids**, caught by
  the owner; the second had a free tier picked by context length alone, which
  included two **domain-tuned** models (finance and health) that would have
  answered IT questions from the wrong prior. The selection criteria now live
  inside the file so the next replacement is made against a standard.

- **`scripts/check_models.py`** compares that catalogue against OpenRouter's
  live API and reports models that vanished, prices that moved, `:free` models
  that started charging, and models that dropped `reasoning` support. It runs
  inside `make check-updates` **and** as a weekly CronJob in the cluster — the
  one part of the pipeline that belongs there, because it needs the network and
  neither quota nor the owner's subscription.

- **`make check-updates` + the `check-updates` skill**: one trigger that
  refreshes every frozen syllabus against what its vendor publishes today and
  rewrites the **Exam versions** table in STATUS.md. First run found lpi-devops
  sitting on v1.0 while LPI had shipped a v2.0 overhaul.

- **The site tells its own truth.** `/api/status` projects the *same functions*
  STATUS.md renders from — versions via `check_versions.survey()`, language
  coverage via the quality floor — so the public page and the repository cannot
  disagree on definitions, only on timing, and every row carries its dates. The
  **Status** section renders it in all seven languages.

- **EU AI Act Article 50 disclosure reached the student.** Every topic page
  names the model that produced what is being served, the date, whether it is a
  translation, and links the vendor exam guide it derives from; the footer
  links the repository. Certification pages link their official sources.

- **Certifications**: cgoa, lpic-3-303, lpic-1 (42 objectives, replacing the
  pre-resnapshot corpus), cca, lpi-devops v2.0 (re-snapshotted to the real 15
  objectives), aws-clf, az-900 and gcp-cdl completed and published — the three
  public-cloud careers now exist end to end. cks' Spanish was rebuilt from the
  rich English (579 KB → 2.9 MB, parity 0.98x) after the review found it was
  the old independently-authored sibling.

- **Nine bugs found and fixed, each with its cost measured**: the CLI exiting 0
  on failed translations (19 re-paid attempts on one topic), systemd killing
  passes at a 40-minute ceiling (12 discarded translation cycles), the video
  encoder present in the toolbox and absent on the host (136 silent render
  failures), a placeholder pseudo-URL failing the translation verifier (20+
  rejections of a correct translation), a bash comment satisfying the quality
  floor's `starts_with: "#"` (a decapitated topic), prompts over ~128 KB
  breaking `execve`, non-authoring languages being authored directly, the
  secret scanner flagging `sk-ssh-` key types and substrings inside words, and
  three API endpoints shipping broken because the container lacked data files
  the toolbox had.

## 2026-09-11

- **`make clean-registry`** makes the 98 GB registry incident repeatable
  instead of hand-fixed. Dry run by default; a deployed tag is never pruned
  (deployments, statefulsets and daemonsets across all namespaces are read
  first, and the run **aborts** if that list is unreadable rather than
  guessing); keep-N on top so a rollback target survives. It prunes tags,
  clears orphaned uploads, garbage-collects and reports usage before and
  after. Also fixed reading `df`: the device name wraps onto two lines and
  `--output` is coreutils-only, so positional parsing had reported free space
  as used.

- **`make verify` is green for the first time: 144 broken manifests → 0.** The
  method, which is the point: **when a check fires en masse, verify the check
  before repairing the content.** Of the 144, **116 were false positives** and
  the checker was what needed fixing — CloudFormation intrinsic tags
  (`!Ref`, `!Sub`, `!Equals`) that `safe_load` refuses by design, systemd unit
  files and Terraform HCL tagged as `yaml`, `${...}` templating, and blocks
  labelled `json` that held console output, JSON Lines, or several documents.
  Two scripts now encode those rules: the vendor-tag loader in
  `check_manifests.py`, and `scripts/fix_fences.py` (two narrow retag rules,
  diff by default, `--apply` to write).

  **28 were real**, and every one of them broke the actual tool rather than
  just our parser: a missing space after a key, an unquoted `*.host` that YAML
  reads as an alias, two mappings joined by a semicolon, a JMESPath expression
  used as a mapping key, container indentation one level too deep, a JSON
  comment inside a JSON document, and block scalars whose PromQL division sat
  left of the scalar indent — the `pca` defect, found in four more places.

- **`check_config.py` stopped reporting a designed decision as drift.** It
  sampled translations, which deliberately run at the CLI default effort since
  2026-08-24, and flagged them against the authoring pin. Authoring only now.

- **DEVELOPERS.md — the platform is now usable by other people.** Two honest
  disclaimers first (a beta API on a home cluster with no uptime guarantee, and
  AI-generated content whose risk and Article 50 disclosure obligation travel
  with anyone who redistributes it), then the licence split (Apache 2.0 for
  code and material; the vendors' terms for the syllabi they derive from), how
  to query the hosted API, how to run the whole platform or just the API or
  just take the markdown, how to keep a fork in sync, how to build features on
  it, and how the DevOps loop is measured — CALMS mapped to the commands that
  implement it, and DORA mapped to where each metric is actually visible,
  including where the loop is honest about its gaps.

  **The endpoint table is generated from the running application**
  (`scripts/gen_api_docs.py`, `--check` wired into `make verify`), because a
  hand-written API table rots and gets believed anyway. Writing it exposed five
  endpoints with no docstring and one documented in Spanish — fixed at the
  source, which is the point of generating rather than writing.

- **The generation prompt learned the conventions the corpus kept violating.**
  Every repair before this was retroactive; this is the only change that stops
  the class being produced. Five rules, each citing a defect that actually
  happened rather than a precaution: quote values containing `: `, quote a
  leading `*` (YAML reads it as an alias), keep block-scalar lines at one
  indent, one JSON document per ```json fence with console output in a plain
  fence, and never label systemd units or Terraform HCL as yaml.

  **Deliberately unmeasured for now.** `scripts/manifest_rate.py` will answer
  whether new topics arrive broken, comparing against the rate recorded at
  repair time (14 of 1,225 topics, 1.1%) rather than against the repaired
  corpus, which reads 0% and would flatter the change. It refuses to report a
  rate below ten new topics — the next certification produces that sample for
  free.

- **Reviewed `.rejected/`, and it paid for itself again.** Of the seven
  rejected translations kept there, **five were false positives** — correct
  translations refused over presentation:
  a legend label (`● = customer` → `● = cliente`), **one space** of re-padding
  in a plain-text table, and **trailing whitespace** in a diagram. Two fixes,
  both narrow: legend markers (`●◐○→✓…`) now count as diagram glyphs so their
  labels are compared as prose, and off-diagram runs of internal spaces
  collapse — the leading indent is untouched because in YAML it is structure,
  and lines that *are* diagrams keep exact columns.

  That last constraint came from a test, not from care: collapsing spaces
  everywhere made `test_diagram_that_breaks_alignment` pass a diagram whose
  borders no longer lined up. The fix is surgical because the test refused the
  blunt one.

  Two of the seven stay rejected on purpose: explanatory prose inside code
  blocks with no comment marker (`j j j (down to line 4)`). Loosening further
  would risk letting a translated command through, and the retry policy
  already handles them — both topics are complete today.

- **The 55 orphaned topic directories are gone** — 6.1 MB, 446 files, every
  one committed so git keeps them retrievable. They were left when LPI syllabi
  were re-snapshotted from chapter headings to real objectives and the ids
  changed (`1.1` → `101.1`). Nothing read them: not the site, not the audits,
  and not the generator, which authors from the syllabus and never from old
  material — so they were not even usable as input. 32 belonged to
  certifications since regenerated; the rest covered whole chapters that the
  new syllabi split into several objectives, so there was no 1:1 salvage
  available. `make verify` stayed green through the removal.

- **Citation attribution: 80% → 91%**, in one batch of bookkeeping with no
  quota. 70 domains catalogued (53 → 110 projects): BSD and Debian manuals,
  Ansible, HashiCorp, Flux, cloud-init, Ceph, OpenSSL, systemd, OCI, SPIFFE,
  Suricata and the rest — every one a project's own documentation, none a blog
  or an aggregator, which is what the 2026-08-06 survey predicted. Government
  and standards bodies went to `neutral_domains` instead: they are primary
  sources but publish for many projects, so attributing them to one would lie.

  **A bug this exposed, now checked**: adding a project key that already
  existed made YAML keep the last and silently discard the first, taking its
  domains with it (`debian`, `systemd`, `ubuntu`, `aws`, `azure` were all
  duplicated). `check_sources.py` now refuses to report any number until
  duplicates are merged — a catalogue that loses entries as it grows is worse
  than one that refuses to grow.

- **CI runs the free verification on every push and pull request**
  (`.github/workflows/verify.yml`): nine checks plus a word-anchored secret
  scan, no quota, no cluster. Its first run failed correctly —
  `status_matrix --check` counts rendered videos and `media/**/*.mp4` is
  gitignored for size, so a clean checkout has none. That check describes the
  machine holding the media, like `check_units` and `check_config` describe the
  workstation; all three are excluded with the reason written in the workflow.

## 2026-08-20

- **The AI disclosure now reaches the student, not just the repo reader (EU AI Act Art. 50).** Every topic page shows what actually produced what is being served — `🤖 AI-generated content by <model> · translated from <lang> · <date>` in the reader's language, read from the served language's `meta.yaml` (fallback-aware, so a Spanish fallback shows Spanish's provenance). The site footer links to the GitHub repository, where per-topic provenance, [MODELS.md](MODELS.md) and the whole pipeline are public. API: `topic_content()` returns `generated_by`; the model-side machine-readable marking is upstream (Anthropic watermarks Claude text since 2026-08). Closes BACKLOG item 7.

## 2026-08-04

- **English Is Now the Authoring Language; Everything Else Is a Translation.** Owner's decision. Content, exercises, labs, video scripts and validation are authored in English; Spanish is translated from it, and `pt fr de zh ja` stay on demand. `certs.DEFAULT_LANG` is `en`. The fallback had to become a **chain** (`FALLBACK_LANGS = [en, es]`) rather than a constant, because flipping it alone would have regressed the site: Spanish is complete for certifications whose English is unfinished (cks was 14 of 26), so a reader asking for German would have got a blank page next to a full Spanish version. Verified both directions — cks/5.1 (no English) still falls back to Spanish, cks/1.1 (English present) prefers English. Recorded honestly in `pipeline.yaml`: **no quality difference between authoring in English and in Spanish could be measured** (identical quality-floor pass rates across 7 languages, 100% of citations resolving in en/es/de/zh, 54/54 manifests parsing in both, comparable code-block and heading counts). The case for English is that the source material and the technical terms already are English, plus ~20% more material per token — not a demonstrated quality gain.
- **A Topic That Could Never Pass Was Burning Entire Quota Windows.** `cks 4.1` was regenerated **six times across four windows** and rejected every time for "missing a references section". Each attempt costs ~7 min and two completions, and since nothing is written on rejection the topic came back pending and the next pass picked it up again — which is why the quota vanished within an hour of every renewal with no content to show. The material was fine: the prompt asks for sections numbered 1) to 6), so the model titled the last one `## 6) References`, and the quality pattern anchored the keyword immediately after the `#`. All 41 pre-existing files use a bare `## References`, which is why it had never surfaced. Pattern now allows an optional `6)` / `6.` prefix; 4.1 passed on the next attempt with no prompt change, confirming the diagnosis. **Rejected text is no longer discarded** either — it goes to `.rejected/` and the error names the file, because six identical failures left zero evidence of what the model had actually written.
- **`_verify_translation` Was Rejecting Every Correct Translation** — found by the translation study, and it would have blocked translation on *any* model including Claude. Code blocks were compared byte-for-byte, but they hold prose too: **comments** (the authored English cks/1.1 has 12 English comments against 2 Spanish in its source) and **ASCII diagrams** (`cheap` translated `│ cloud-controller-manager (opcional) │` on 3 of 3 attempts — deterministic, so no retry policy could ever have got kcna/1.1 through). Comment text is now blanked with the `#` marker kept, so a *deleted* comment line is still caught; on box-drawing lines the labels are blanked but the box characters must keep their exact column positions, so a translation that breaks the alignment is still rejected. `+`, `-` and `|` are excluded from the box character set so an ordinary shell pipeline stays compared exactly.
- **KCNA English Complete (13/13), Translated Rather Than Re-Authored** — the first certification produced by translation. Verified with the *same* checks as authored material, which is the point: 26/26 files clear the quality floor, 100% of citations resolve, 26/26 manifests parse, no removed Kubernetes APIs. 11 topics by `cheap`, 2 by `claude-sonnet` after `cheap` failed them deterministically. Escalating the model was the right fix rather than loosening the gate: 242 of the 351 untagged code blocks in the corpus are **not** prose — they hold terminal prompts and command synopses — so "untagged means prose" would have shipped corrupted output.
- **The Audit Ignored Videos Entirely.** It is the work queue, and it only looked at content, exercises and labs, so a video declared in `pipeline.yaml` and never rendered was invisible: "0 pending" could be true of the text and silently wrong about the media. Same blind spot that hit content three times. Reports 4 today (`cks/en`, `kcna/en`, `cnpe/es`, `cnpa/es`). Kept out of `find_bad_combos` on purpose, since that set drives `teach cert generate --topic` and a video is per certification, not per topic.
- **German Path Videos Re-Rendered** — they were still the 2026-07-17 renders narrated in Spanish by a German voice; the fix landed on 07-30 but nothing had been re-rendered, so the defect was live on the published site. Verified: the deterministic voiceover now reads "Du beginnst mit KCNA, danach folgt CKA oder CKAD." Costs no API quota. Note `media/**/*.mp4` is gitignored, so videos reach production only through `make image-cluster` (which tars the working directory); an image built by CI from git alone contains no video at all.
- **README Rewritten.** Four real defects: the four header links were dead (`STATUS.MD` vs `STATUS.md`, on a case-sensitive filesystem), the Languages section still described Spanish as the default and presented `generate --lang <x>` as the way to add a language (now the documented way to get it wrong, with `teach cert translate` unmentioned), the timer section gave enable instructions with no warning that it spends quota unattended, and the whole file was in Spanish against the repo's own English-documentation rule. The CI claim was checked and is accurate.
- **The Translation Tests Were Invisible to `make test`.** Written with pytest, so `unittest discover` skipped the file entirely — the project's own command reported 23 passing while 11 never ran, and the Makefile is explicit that the suite is stdlib with no extra dependencies. Rewritten as `unittest`, verified by uninstalling pytest first: 34 tests, OK.

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
