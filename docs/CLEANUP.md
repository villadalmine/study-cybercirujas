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
| `usage.jsonl` | **No.** Every spend figure, model comparison and forecast is derived from it. Deleting it makes `make metrics`, `MODELS.md` and `topic_cost.py` lie by omission |
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
purpose; see the RAG-bot section of BACKLOG.md before removing it.
