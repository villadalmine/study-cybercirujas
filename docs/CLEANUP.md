# Cleanup — what fills up, and how to reclaim it

Every command here is destructive. They are written out because the failure
they prevent is worse: on 2026-09-10 the cluster registry hit **100% of 98 GB**
and every image push in the cluster started failing — not just this project's.

Read the "check first" line of each section before the "delete" line.

## The routine, start to finish

Run in this order. Each step says what to look at, what decides the action, and
whether it is safe to automate later. **Steps 1–4 are mechanical; step 5 is a
judgement call and should stay manual.**

### Step 0 — measure before touching anything

```bash
kubectl exec -n registry deploy/registry -- df -h /var/lib/registry
du -sh .rejected/ 2>/dev/null
du -sh ~/.local/state/teach-plat/*.log 2>/dev/null
git status --short | grep '^??'
```

Decision: if the registry is under ~70% and the rest is small, stop here.
Cleaning a system that is not full is how something in use gets deleted.

### Step 1 — orphaned registry uploads · *safe to automate*

Debris from pushes that died mid-flight. Referenced by nothing, always safe.

```bash
kubectl exec -n registry deploy/registry -- sh -c \
  'rm -rf /var/lib/registry/docker/registry/v2/repositories/*/_uploads/*'
```

### Step 2 — old image tags · *automatable with a rule, not blindly*

The rule must be "keep the N most recent **and** anything deployed", never
"keep N". Get the deployed set first, then prune per repository:

```bash
kubectl get deploy -A -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' | sort -u
kubectl exec -n registry deploy/registry -- sh -c \
  'for r in $(ls /var/lib/registry/docker/registry/v2/repositories/); do \
     echo "$r: $(ls /var/lib/registry/docker/registry/v2/repositories/$r/_manifests/tags | wc -l)"; done'
```

Prune whichever repository actually holds the tags — in the 2026-09-10
incident that was `online-game` (229) and `online-game-test` (124), not
`teach-plat`. Chasing the wrong repository frees nothing.

### Step 3 — garbage collection · *safe to automate, but slow*

The only step that frees bytes. Takes minutes with thousands of blobs.

```bash
kubectl exec -n registry deploy/registry -- \
  registry garbage-collect /etc/docker/registry/config.yml --delete-untagged
kubectl exec -n registry deploy/registry -- df -h /var/lib/registry
```

`0 blobs eligible` means the space belongs to tags you have not pruned — go
back to step 2 with the counts, do not repeat the GC.

### Step 4 — logs and diagnosed rejections · *safe to automate*

```bash
ls -la .rejected/ | tail       # read the reasons first; this is evidence
rm -rf .rejected/*
: > ~/.local/state/teach-plat/resume.log
```

Never `usage.jsonl` or `quota-history.jsonl` — every spend figure and forecast
in this project is derived from them.

### Step 5 — orphaned topics and scratch files · *keep manual*

Both need someone to look. Orphaned topic directories hold real material that
might be salvaged into new ids; scratch files are usually junk but `chart/` is
not. The listing script is in section 3 below.

### Steps 1–3, automated · `make clean-registry`

Written 2026-09-11; steps 1–3 above are now one command.

```bash
make clean-registry                  # the plan, nothing written
make clean-registry APPLY=1          # prune, clear uploads, garbage-collect
make clean-registry KEEP=5 APPLY=1   # keep more per repository
```

Three safeties, in this order:

1. **Dry run by default.** `APPLY=1` is required to delete anything.
2. **A deployed tag is never pruned.** Every deployment, statefulset and
   daemonset in every namespace is read first and its tags are kept
   regardless of age. If that list cannot be read the run **aborts** rather
   than guessing — pruning blind would delete a tag in use and the next pod
   start would fail.
3. **Keep-N on top**, newest first, so a rollback target always survives.

It then does what the manual steps did, in the order that works: prune tag
manifests, clear orphaned uploads, garbage-collect, and print usage before and
after. First real run pruned 11 tags across three repositories.

Steps 4–5 stay manual because both destroy evidence: `.rejected/` explains
repeated failures, and orphaned topics are unfinished salvage, not garbage.

## 1. The container registry (the one that actually fills)

**Symptom**: `make image-cluster` fails with

    error pushing image: ... UNKNOWN: unknown error; map[... Err:28 Op:mkdir ...]

`Err:28` is ENOSPC. The registry is out of disk.

**Why it happens**: this project publishes one image per finished
certification, each carrying `certs/` and `media/` (~250 MB), and nothing ever
prunes. Other repositories in the same registry do the same — in the 2026-09-10
incident `teach-plat` had 55 tags but `online-game` had **229** and
`online-game-test` **124**, and those were the real weight.

### Check first

```bash
kubectl exec -n registry deploy/registry -- df -h /var/lib/registry
kubectl exec -n registry deploy/registry -- sh -c \
  'for r in $(ls /var/lib/registry/docker/registry/v2/repositories/); do \
     echo "$r: $(ls /var/lib/registry/docker/registry/v2/repositories/$r/_manifests/tags 2>/dev/null | wc -l) tags"; done'
```

**Never delete a tag something is running.** List what is deployed:

```bash
kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

### Delete

Three steps, in this order. Steps 1 and 2 free nothing on their own — only
step 3 does, and only for blobs no surviving tag references.

```bash
# 1. Orphaned uploads: debris from builds that failed mid-push. Always safe.
kubectl exec -n registry deploy/registry -- sh -c \
  'rm -rf /var/lib/registry/docker/registry/v2/repositories/*/_uploads/*'

# 2. Old tag manifests, keeping the N most recent per repository.
#    Adjust N per repo; keep at least the one in production plus a rollback.
kubectl exec -n registry deploy/registry -- sh -c \
  'cd /var/lib/registry/docker/registry/v2/repositories/teach-plat/_manifests/tags && ls -t | tail -n +4 | xargs rm -rf'

# 3. Garbage collection — this is the step that frees space.
kubectl exec -n registry deploy/registry -- \
  registry garbage-collect /etc/docker/registry/config.yml --delete-untagged

kubectl exec -n registry deploy/registry -- df -h /var/lib/registry
```

**If GC reports `0 blobs eligible for deletion`**, every remaining blob is
still referenced by a live tag — meaning the space is held by repositories you
have not pruned yet, not by garbage. That is exactly what happened when only
`teach-plat` had been cleaned: 52 tags gone, zero bytes freed, because its
remaining three tags shared those layers. Prune the repository that actually
holds the tags (see the counts above) and run GC again.

Result on 2026-09-10 after pruning `online-game` and `online-game-test`:
**100% → 15% used, 83 GB reclaimed.**

### Worth doing once

The registry has no retention policy. Either add one, or make pruning part of
publishing — a `make publish-complete` that drops tags older than the last N
would keep this from recurring.

## 2. Rejected generation output (`.rejected/`)

Text that failed the quality floor or a translation check is kept on purpose:
it is the only evidence of *why* a topic keeps failing, and discarding it once
cost this project six regenerations of the same topic across four quota
windows.

It is gitignored and grows slowly. Safe to clear after a failure is diagnosed:

```bash
ls -la .rejected/ | tail -20          # look before deleting — it is evidence
rm -rf .rejected/*
```

## 3. Orphaned topic directories

When a syllabus is re-snapshotted with new ids (LPI renumbering `1.1` to
`101.1`, for example), the old directories stay on disk: **not served, not
counted, not audited**. Roughly 188 of them exist.

They are deliberately kept because they contain real material that could be
salvaged into the new ids. Deleting them is a decision, not maintenance:

```bash
# See what would go: directories whose id is not in the current syllabus
.venv/bin/python3 - <<'EOF'
import frontmatter
from pathlib import Path
for syl in sorted(Path('certs').glob('*.md')):
    ids = {str(t['id']) for t in (frontmatter.load(syl).metadata.get('topics') or [])}
    d = Path('certs') / syl.stem
    if not d.is_dir() or not ids: continue
    orphans = [p.name for p in d.iterdir() if p.is_dir() and p.name not in ids]
    if orphans: print(f"{syl.stem}: {len(orphans)} orphaned — {', '.join(sorted(orphans)[:6])}")
EOF
```

Only delete after deciding they will never be salvaged.

## 4. Local state (`~/.local/state/teach-plat/`)

| File | Delete? |
|---|---|
| `usage.jsonl` | **No.** Every spend figure, model comparison and forecast is derived from it. Deleting it makes `make metrics`, `docs/MODELS.md` and `topic_cost.py` lie by omission |
| `quota-history.jsonl` | **No.** Same: window measurements come from here |
| `resume.log`, `milestone.log` | Yes, once read — they are append-only narration |
| `claims/` | Only while nothing is generating (`claims.active()` empty). Claims die with their process anyway |

## 5. Scratch files in the repository root

Notes and one-off probes accumulate (`hola`, `seguir`, `test_agy.py`,
`lpic-1-text.txt` were cleared on 2026-09-10). They are untracked, so:

```bash
git status --short | grep '^??'    # look at the list before acting
```

`chart/` is the exception — an audited design proposal kept untracked on
purpose; see the RAG-bot section of docs/BACKLOG.md before removing it.

---

# Documentation audit — 2026-10-14

A pass over every root `.md`, `docs/`, `openwiki/` and `graphify-out/`, plus a
fresh `git clone` followed exactly as the README says. Internal markdown links
were checked mechanically (21 files, 0 broken links or anchors). What was
mechanical is already fixed in the same branch; the rest needs the owner's
call and is listed here so it is not lost.

## Fixed in this pass

| What | Where | Fix |
|---|---|---|
| README opened with an internal "where we left off" note, the maintainer pipeline, the workstation timer and `.env` handling | `README.md` | Rewritten for someone arriving from outside; the maintainer material moved verbatim to [OPERATING.md](OPERATING.md) |
| Disclosure named `claude-opus-5`, `opus-4-8`, `fable-5` while `ckne` and part of `mcpa` are `claude-opus-5-5` | `README.md` | Model families named, exact ids left to `meta.yaml` / [docs/MODELS.md](MODELS.md), which cannot drift |
| "Anthropic embeds invisible watermarks (SynthID-Text based) … so the material is machine-detectable" | `README.md` | The cited TechCrunch piece (2026-08-11) does not mention SynthID (Google's technology), and says watermarking is automatic only for models released after 2 August 2026, with older models "later". Most of this corpus predates that. Claim removed |
| `make setup` fails on stock Ubuntu (`ensurepip is not available`) | README, DEVELOPERS | `python3-venv` listed as a prerequisite |
| `make verify` fails on any fresh clone (`status_matrix --check` counts gitignored videos) | Makefile, CI | New `make verify-ci` = what CI runs = what a contributor runs; `verify.yml` calls it instead of a copied list |
| "Every push to main publishes the image" — but the 2026-10-12 `models.yaml` refresh never reached GHCR | `.github/workflows/docker.yml` | The path filter listed `catalog.yaml` only; the Dockerfile ships every root `*.yaml` and `scripts/`. Filter widened, `workflow_dispatch` added |
| Deploy command used `--set image.registry=…` (no such key) and the chart default was `ghcr.io/villadalmine/teach-plat` (no such image) | OPERATING, `deploy/helm/values.yaml` | `image.repository=ghcr.io/villadalmine/study-cybercirujas`; the copy-`values-local.yaml` step now comes before the command that needs it |
| `teach lab up` reported "running" with nothing broken | `teach/core/labs.py` | `docker exec` had no `-i`, so the confirmation prompt read EOF and the script cancelled. Fixed with a test; `lab up` now prints how to enter the lab |
| BACKLOG said the fallback is "to Spanish" | `docs/BACKLOG.md` | It is `en`, then `es` (`certs.FALLBACK_LANGS`) |
| BACKLOG "Next" listed done work (cks/kcna translations, cnpe snapshot, the study bot) | `docs/BACKLOG.md` | Removed with a dated note; the `chart/` RAG proposal marked superseded |
| ROADMAP said 27 published and AI 0/7, header dated 09-18 over 09-30 content | `docs/ROADMAP.md` | 28 published (mcpa, ckne in English), header 09-30 |
| PLAN described a paid login zone and admin/admin | `docs/ORIGINAL_DESIGN.md` | Banner: original design, superseded points listed, code wins |
| DEVELOPERS said the registry has no retention | `docs/DEVELOPERS.md` | `make clean-registry` exists; reworded |
| The README certification table was a hand-kept list waiting to rot | `scripts/gen_readme_table.py` | Generated from docs/STATUS.md between markers, `--check` in `make verify` and CI |

## Needs the owner's decision

1. **`docs/AGENTS_SYNC.md` (1 017 lines).** Its own rule says a processed proposal is
   removed, yet it still carries the August queues between Claude and
   Antigravity (`## Queue — … 2026-08-06`, `2026-08-08`) and dated status
   letters (`From claude — 2026-08-11 … 08-19`). Proposal: keep the rules
   (first ~400 lines), move the dated letters into docs/HISTORY.md or delete them
   (git keeps them), empty the queue.
2. **`docs/ROADMAP.md` "Where we left off"** is a session note, not a roadmap. Keep
   it short (open items only) or move it to docs/HISTORY.md at the end of each
   session; the README no longer links to it.
3. **`docs/ORIGINAL_DESIGN.md`** is mostly history now. Trim it to the principles
   (snapshot, state in files, generate once, CLI first, separate roles — the
   Curriculum-as-Code core). The rename from `PLAN.md` is done.
4. **`docs/BACKLOG.md` vs `docs/ROADMAP.md`** both carry "what is next"; BACKLOG says the
   ordered queue lives in ROADMAP. Merging them would remove one source of drift.
5. **272 topics with model `claude (unresolved)`** and 207 `agy (unresolved)`
   in [docs/MODELS.md](MODELS.md); the API serves `generated_by.model: "claude"`
   (e.g. `cka/1.1`). The disclosure is honest about this, but provenance is
   weakest exactly where the corpus is oldest.
6. **`lpi-devops` has `pt` declared with 3 of 15 topics** — the ROADMAP trap
   (`fix_corrupted_content.py` would start 12 translations). Finish or undeclare.
7. **UI language leak**: catalogue values are Spanish data (`validity: 5 años`),
   so the English page shows "expires: 5 años".
8. **Labs are mostly in Spanish** even for English topics (`break_fix.sh` text).
9. **Source comments still largely in Spanish** (already in BACKLOG → Repo
   Hygiene), e.g. `deploy/Dockerfile`, `deploy/helm/values*.yaml`.
10. **`docs/CLEANUP.md` itself** documents the owner's cluster registry
    (`kubectl exec -n registry …`); useful to a maintainer, meaningless to a
    fork. Fine where it is, but it is operations, not project docs.

## `graphify-out/` and `openwiki/` — what they are and whether they belong

**`graphify-out/`** (`graph.json`, `GRAPH_REPORT.md`, generated wiki pages) is
a tree-sitter map of the *machinery* (`teach/`, `scripts/`, tests, configs and
the docs), so agents can query it over MCP. graphify is a free pip install
(no LLM, no key), pinned in `make graph-setup`.

**Decided (2026-10-15, by the maintainer): `graphify-out/` stays committed.**
Main keeps it fresh, not each PR: after a merge that touches what the graph covers
(`teach/`, `scripts/`, `tests/`, `Makefile`), `.github/workflows/graph.yml` runs
`scripts/check_graph.py --regenerate --strict` and, if the graph is stale, opens one
bot PR (`bot/graph-refresh`) with the rebuilt graph. A feature PR does not run
`make graph` and does not rebase for it: CI's `docs-consistency` job rebuilds the graph and
only warns when the committed one is not what the tree builds (`--regenerate` without
`--strict` exits 0). The rejected alternative was to stop committing it and build it in CI
or on demand.

**`openwiki/`** holds only `INSTRUCTIONS.md`: the scope file for an OpenWiki run
that costs API credits and has never produced a committed wiki. It is a
configuration for a tool that is not in use. It is never regenerated in a PR, because it
costs credits; `make wiki` stays a manual, owner-only command.

Recommendations still open (nothing removed — owner decides):

- **Where a graph would pay off is the curriculum, not the code.** The repo
  already has the data for a *curriculum graph*: certification → domain →
  topic → official source, plus `requires` between certifications and the
  career paths. Rendered on the site ("which CKS topics build on CKA 3.x?",
  "what do KCSA and CKS share?"), that is a student-facing feature and pure
  Curriculum-as-Code: derived from `catalog.yaml` and the syllabi, no model,
  regenerated on every build. `/api/search` and the MCP `search_topics` tool
  are the start of it.
- **OpenWiki:** drop `openwiki/` and the `make wiki` target unless there is a
  concrete reader for a paid, unattended-forbidden wiki; docs/DEVELOPERS.md and the
  generated API table already document the machinery for free.
