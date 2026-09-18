# 701.3 — Source Code Management

**LPI DevOps Tools Engineer — Exam 701-100, v2.0.0 · Topic 701: Software Engineering · Weight: 10**

---

## 1. The architectural problem: the repository is the system of record

Every other stage of a delivery platform is a *derivation* of source control. The container image is a function of a commit. The Kubernetes manifest applied in production is a function of a commit. The SBOM, the provenance attestation, the audit answer to "who approved this change and when" — all functions of a commit. If the SCM layer is weak, nothing downstream can be stronger than it, because you cannot sign, reproduce or roll back what you cannot address.

This is why Source Code Management carries disproportionate weight for an SRE. The failures are not "I lost my work"; they are architectural:

| Failure class | Concrete production symptom | Root cause in the SCM layer |
|---|---|---|
| **Irreproducible build** | The image tagged `v2.4.1` cannot be rebuilt byte-for-byte; the tag was moved | Mutable tags, no annotated/signed tags, no `git describe` in the build |
| **Unattributable change** | Incident review cannot determine who authored a config line | Unsigned commits, shared service accounts, rewritten history on a shared branch |
| **Secret exposure** | A leaked `kubeconfig` remains reachable in history for years after "deleting the file" | Git is append-only by design; deletion is a new commit, not an erasure |
| **Integration collapse** | Twelve long-lived branches, merge takes days, semantic conflicts pass CI | Branching model mismatched to team size and deploy cadence |
| **Clone-time cliff** | A 40 GB monorepo makes every CI job spend 6 minutes on `git clone` | Full history + full blobs fetched when only a tree is needed |
| **Desired-state drift** | The cluster runs something no commit describes | GitOps not enforced; `kubectl apply` from laptops |

The mechanics below exist to make each of those rows impossible by construction, not by discipline.

---

## 2. The object model: what Git actually stores

Git is a content-addressable object database with a filesystem-shaped index on top. Understanding the four object types is the difference between using Git and diagnosing it.

| Object | Contains | Addressed by | Mutable? |
|---|---|---|---|
| **blob** | Raw file bytes. No name, no mode, no history | Hash of `blob <len>\0<content>` | No |
| **tree** | List of `(mode, type, hash, name)` entries — a directory | Hash of its serialized entries | No |
| **commit** | One tree hash, zero or more parents, author, committer, message, optional `gpgsig` | Hash of the commit header + message | No |
| **tag** (annotated) | Pointer to an object + tagger + message + optional signature | Hash of the tag object | No |

Everything else — branches, `HEAD`, remote-tracking refs, the stash, notes — is a *reference*: a 41-byte file (or a line in `packed-refs`) holding a hash. Branches are cheap because a branch is a filename containing a hash.

### 2.1 Proving it on a live repository

```
$ git init --initial-branch=main /tmp/objmodel
Initialized empty Git repository in /tmp/objmodel/.git/

$ cd /tmp/objmodel
$ printf 'apiVersion: v1\n' > note.txt
$ git add note.txt
$ git commit -q -m 'chore: seed the object database'
$ git cat-file -p HEAD
tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
author Ada Lovelace <ada@example.org> 1758153600 +0000
committer Ada Lovelace <ada@example.org> 1758153600 +0000

chore: seed the object database
```

Walk one level down, from commit to tree to blob:

```
$ git cat-file -p HEAD^{tree}
100644 blob 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f    note.txt

$ git cat-file -p 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
apiVersion: v1

$ git cat-file -t 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
blob
```

The hash is not assigned, it is *computed*. Reproduce it without Git's help:

```
$ printf 'blob 15\0apiVersion: v1\n' | sha1sum
3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f  -
```

**Architectural consequence:** identical content stored in a thousand directories is one blob. Renames are not stored — Git records two trees and *infers* the rename at read time with a similarity heuristic (`git log --follow`, `diff.renames`). That is why `git mv` is a convenience wrapper over `rm` + `add`, not a distinct operation.

### 2.2 The three areas, and the index as a real file

```
$ git ls-files --stage
100644 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f 0    note.txt
```

Stage number `0` means "not conflicted". During a merge conflict the same path appears three times, with stages `1` (common ancestor / base), `2` (ours), `3` (theirs):

```
$ git ls-files --stage -- deploy/values.yaml
100644 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 1    deploy/values.yaml
100644 b2c3d4e5f60718293a4b5c6d7e8f90123456789a 2    deploy/values.yaml
100644 c3d4e5f60718293a4b5c6d7e8f90123456789abc 3    deploy/values.yaml
```

This is the mechanical definition of a conflict: the index holds three versions of one path and refuses to produce a tree. `git checkout --ours`/`--theirs` selects stage 2 or 3; `git add` collapses to stage 0 and the merge can complete.

| Area | Physical location | Populated by | Discarded by |
|---|---|---|---|
| Working tree | Files on disk | `git checkout` / `git switch` / `git restore` | `git restore <path>` |
| Index (staging area) | `.git/index`, binary | `git add`, `git rm`, `git mv` | `git restore --staged <path>` |
| Object DB + refs | `.git/objects`, `.git/refs` | `git commit`, `git fetch` | `git gc` after unreachability |

### 2.3 Refs, HEAD, and the reflog

```
$ cat .git/HEAD
ref: refs/heads/main

$ git symbolic-ref HEAD
refs/heads/main

$ git rev-parse HEAD
9c1f0a4d7b2e3a5c8d1f6b0e4a7c9d2f5b8e1a03

$ git for-each-ref --format='%(refname) %(objecttype) %(objectname:short)'
refs/heads/main commit 9c1f0a4
refs/remotes/origin/main commit 9c1f0a4
refs/tags/v2.4.1 tag 7d3b9e1
```

A **detached HEAD** is simply `.git/HEAD` containing a raw hash instead of `ref: refs/heads/...`. Commits made there are reachable from nothing but the reflog, and `git gc` will eventually delete them. That is the entire mystery.

The reflog is the local, per-ref journal of every value a ref has held — it is what makes almost every destructive Git operation recoverable *locally*, and it is **never pushed**:

```
$ git reflog show main --date=iso
9c1f0a4 main@{2026-09-17 11:04:22 +0000}: commit: feat: add readiness probe
1a2b3c4 main@{2026-09-17 10:51:07 +0000}: reset: moving to HEAD~2
5d6e7f8 main@{2026-09-17 10:12:44 +0000}: rebase (finish): refs/heads/main onto 8899aab
```

Default expiry: 90 days for reachable entries (`gc.reflogExpire`), 30 days for unreachable ones (`gc.reflogExpireUnreachable`).

### 2.4 SHA-1, SHA-256 and integrity

Git's SHA-1 usage has been hardened with collision detection (`sha1dc`) since 2.13 — a crafted SHAttered-style collision aborts the operation rather than silently corrupting the DB. A SHA-256 object format exists and is usable, but **there is no interoperability between a SHA-1 and a SHA-256 repository**; you cannot push between them.

```
$ git init --object-format=sha256 /tmp/sha256repo
Initialized empty Git repository in /tmp/sha256repo/.git/

$ git -C /tmp/sha256repo rev-parse --show-object-format
sha256
```

Treat SHA-256 repositories as a forward-looking experiment; do not migrate a shared platform repository to it today. Instead, enforce integrity checks on transfer, which are off by default for performance:

```
$ git config --global transfer.fsckObjects true
$ git config --global fetch.fsckObjects true
$ git config --system receive.fsckObjects true
```

---

## 3. Integration mechanics: merge, rebase, and what each one destroys

### 3.1 Fast-forward vs three-way

A **fast-forward** is not a merge: if `HEAD` is an ancestor of the target, Git moves the ref. No new object is created, no conflict is possible, and the branch's existence disappears from the graph.

A **three-way merge** computes the merge base (`git merge-base A B`), diffs base→ours and base→theirs, and combines them. Since Git 2.34 the default strategy is **`ort`** ("Ostensibly Recursive's Twin"), a rewrite of `recursive` that is dramatically faster on large trees and handles rename detection and criss-cross histories (multiple merge bases) better.

```
$ git merge-base --all main feature/probe
8899aabbccddeeff00112233445566778899aabb

$ git merge --no-ff feature/probe
Auto-merging deploy/values.yaml
CONFLICT (content): Merge conflict in deploy/values.yaml
Automatic merge failed; fix conflicts and then commit the result.

$ git status --short
UU deploy/values.yaml
M  deploy/deployment.yaml
```

Set a conflict style that shows the *base*, so you can see what each side changed rather than guessing:

```
$ git config --global merge.conflictStyle zdiff3
```

With `zdiff3` the markers carry a base section:

```
<<<<<<< HEAD
  replicas: 6
||||||| 8899aab
  replicas: 3
=======
  replicas: 4
>>>>>>> feature/probe
```

Now the decision is informed: ours scaled 3→6, theirs scaled 3→4. With the default `merge` style you would only see 6 vs 4 and would not know which side moved.

### 3.2 Rebase: replaying patches, creating new objects

`git rebase` takes the commits unique to your branch, computes their patches, and re-applies them onto a new base. **Every rebased commit is a new object with a new hash** — the tree may be identical, the parent is not. This is why rebasing a branch that others have pulled is an outage in miniature.

```
$ git rebase --onto origin/main HEAD~3 feature/probe
Successfully rebased and updated refs/heads/feature/probe.

$ git range-diff origin/main HEAD@{1} HEAD
1:  4f5a6b7 = 1:  a1b2c3d feat: add readiness probe
2:  6c7d8e9 ! 2:  b2c3d4e feat: expose /healthz
    @@ internal/server/health.go
     -   w.WriteHeader(http.StatusOK)
     +   w.WriteHeader(http.StatusNoContent)
3:  8e9f0a1 = 3:  c3d4e5f test: cover the probe path
```

`git range-diff` is the correct review tool after a force-push: it diffs two *series* of commits and shows exactly which patches changed, which is invisible to a plain diff.

### 3.3 Trade-off table: integration strategies

| Strategy | Graph shape | History fidelity | Bisectability | Revert granularity | Safe on shared branch | Best for |
|---|---|---|---|---|---|---|
| `merge --ff-only` | Linear | Exact | Excellent | Per commit | Yes | Protected `main` in trunk-based flow |
| `merge --no-ff` | Merge bubbles | Exact + records integration point | Good (`--first-parent`) | Whole feature (revert the merge with `-m 1`) | Yes | Release branches, audit-heavy environments |
| `rebase` then ff | Linear | Rewritten (dates, hashes, possibly semantics) | Excellent | Per commit | **No** | Private feature branches before review |
| `merge --squash` | Linear, one commit per feature | Lossy — intermediate steps gone | Coarse but very clean | Whole feature | Yes | High-churn repos with noisy WIP commits |
| `cherry-pick` | Duplicated patches | Duplicates content under new hashes | Confusing (same change, two hashes) | Per pick | Yes | Backporting a hotfix to a release branch |

Two operational rules that follow directly from the mechanics:

1. **Rebase rewrites history; never rebase a ref other people fetch.** If you must, use `--force-with-lease --force-if-includes` so you cannot silently clobber a commit you never saw:

```
$ git push --force-with-lease --force-if-includes origin feature/probe
To ssh://git@git.example.org/platform/api.git
 + 6c7d8e9...b2c3d4e feature/probe -> feature/probe (forced update)
```

Plain `--force` overwrites unconditionally. `--force-with-lease` refuses if the remote ref moved since your last fetch. `--force-if-includes` (Git 2.30+) closes the remaining hole where a background `git fetch` updated your remote-tracking ref without you having integrated it.

2. **Teach Git to reuse conflict resolutions** on repeated rebases of long-lived branches:

```
$ git config --global rerere.enabled true
$ git config --global rerere.autoUpdate true
```

`rerere` records the conflict hunk and its resolution under `.git/rr-cache/`; the next time the identical conflict appears it is resolved automatically. It is a large time saver on release branches — and a hazard if the first resolution was wrong, since it will be replayed silently. `git rerere forget <path>` clears one entry.

---

## 4. Branching models: choosing a topology, not a preference

| Model | Long-lived branches | Merge frequency | Release mechanism | Feature isolation | Cost of a hotfix | Fits |
|---|---|---|---|---|---|---|
| **Trunk-based** | `main` only | Multiple times/day, branches < 24 h | Tag on `main` + promote artifact | Feature flags | Trivial — commit to `main`, promote | CD, high-trust teams, platform repos |
| **GitHub Flow** | `main` only | Per PR | Deploy on merge | Branch lifetime hours–days | Same as any change | SaaS, single production version |
| **GitLab Flow** | `main` + environment branches (`staging`, `production`) | Downstream merges only | Merge `main`→`staging`→`production` | Branch + environment gate | Cherry-pick to `production` | Regulated promotion gates |
| **Git Flow** | `main`, `develop`, `release/*`, `hotfix/*` | Weeks | `release/*` stabilization then tag | Strong, long-lived | Dedicated `hotfix/*` + double merge | Shipped/on-prem software, many supported versions |
| **Release train** | `main` + `release-X.Y` | Continuous to `main`, cherry-pick back | Cut a branch on a calendar | Backport policy | Cherry-pick per supported release | Kubernetes-style projects |

**The decisive variable is not team taste, it is how many versions you must support in production simultaneously.** One version → trunk-based. Many → you need release branches, and you must accept the backport tax.

### 4.1 Semantic conflicts and merge queues

The failure that branching models rarely address: two PRs each pass CI against `main`, conflict in no file, and break `main` when both land — one renamed a function, the other added a caller. A textual merge cannot see it.

The mechanical fix is a **merge queue**: serialize the candidates, build each against the *speculated* result of the ones ahead, and only fast-forward `main` when green.

```yaml
name: ci
on:
  pull_request:
    branches:
      - main
  merge_group:
    types:
      - checks_requested
permissions:
  contents: read
concurrency:
  group: "ci-${{ github.ref }}"
  cancel-in-progress: true
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout with full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Verify commit messages against Conventional Commits
        run: |
          base="${{ github.event.pull_request.base.sha }}"
          head="${{ github.event.pull_request.head.sha }}"
          if [ -z "$base" ]; then
            base="$(git rev-parse HEAD~1)"
            head="$(git rev-parse HEAD)"
          fi
          git log --format=%s "${base}..${head}" | while read -r subject; do
            echo "$subject" | grep -Eq '^(feat|fix|docs|chore|refactor|test|perf|build|ci)(\([a-z0-9-]+\))?!?: .+' \
              || { echo "non-conforming subject: $subject" >&2; exit 1; }
          done
      - name: Fail on merge conflict markers
        run: |
          if git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . ':!docs/**'; then
            echo "conflict markers committed" >&2
            exit 1
          fi
      - name: Unit tests
        run: make test
```

Note the two hardening choices: `persist-credentials: false` keeps the job's token out of `.git/config` where any build step could read it, and `fetch-depth: 0` is requested explicitly because history-dependent steps (`git describe`, commit linting, `git log` ranges) silently misbehave under the default shallow clone.

---

## 5. Repository topology: monorepo vs polyrepo, and the scaling tools

| Dimension | Monorepo | Polyrepo |
|---|---|---|
| Atomic cross-service change | One commit, one review | N PRs, coordinated merge, race window |
| Dependency version skew | Structurally impossible (one version of everything) | Normal state; requires a registry and pinning |
| Clone/CI cost | Grows with the whole org; needs partial clone + sparse checkout | Naturally bounded |
| Access control | Path-based, requires forge support (CODEOWNERS, GitLab path rules) | Repository-level, simple and coarse |
| Blast radius of a bad `main` | Everyone | One team |
| Tooling investment required | High (build graph, affected-target detection) | Low |
| Refactor across boundaries | Cheap | Expensive (deprecation cycles) |

A monorepo is a bet that you will invest in build tooling; a polyrepo is a bet that you will invest in release coordination. Both bets are payable — an unfunded monorepo is the common failure.

### 5.1 Making a large repository cheap to clone

Three independent levers, combinable:

```
$ git clone --filter=blob:none --no-checkout ssh://git@git.example.org/platform/mono.git
Cloning into 'mono'...
remote: Enumerating objects: 918442, done.
remote: Total 918442 (delta 0), reused 0 (delta 0), pack-reused 918442
Receiving objects: 100% (918442/918442), 214.66 MiB | 31.22 MiB/s, done.
Resolving deltas: 100% (611930/611930), done.

$ cd mono
$ git sparse-checkout set --cone services/billing platform/lib
$ git checkout main
Updating files: 100% (1894/1894), done.
Your branch is up to date with 'origin/main'.

$ du -sh .git
248M    .git
```

| Technique | Flag | What is omitted | Cost when you need the data | Safe for CI? |
|---|---|---|---|---|
| Shallow clone | `--depth=1` | All history beyond N commits | `git fetch --unshallow` (full refetch) | Only for jobs that never read history |
| Blobless partial clone | `--filter=blob:none` | File contents; trees and commits kept | Lazy fetch per blob on demand | Yes — best default for CI |
| Treeless partial clone | `--filter=tree:0` | Trees and blobs | Lazy fetch, expensive for `git log -- path` | Only for one-shot builds |
| Sparse checkout | `sparse-checkout set --cone` | Working-tree files outside the cone | Extend the cone | Yes |
| Single branch | `--single-branch` | Other branches' refs | `git remote set-branches` + fetch | Yes |

The server must opt in to partial clone, or the filter is silently ignored:

```
$ git config --system uploadpack.allowFilter true
$ git config --system uploadpack.allowAnySHA1InWant true
```

Accelerate graph traversal (`git log`, merge-base, `git describe`) with the commit-graph and multi-pack index, and let Git maintain them on a schedule:

```
$ git commit-graph write --reachable --changed-paths
$ git multi-pack-index write
$ git maintenance start
$ systemctl --user list-timers git-maintenance@*
NEXT                        LEFT     LAST                        PASSED   UNIT                            ACTIVATES
Thu 2026-09-18 15:00:00 UTC 41min    Thu 2026-09-18 14:00:00 UTC 18min    git-maintenance@hourly.timer    git-maintenance@hourly.service
Fri 2026-09-19 00:00:00 UTC 9h       Thu 2026-09-18 00:00:00 UTC 14h      git-maintenance@daily.timer     git-maintenance@daily.service
```

### 5.2 Composing repositories: submodules, subtrees, package registry

| Approach | Where the code lives | Consumer clone | Pinning | Upstream contribution | Typical failure |
|---|---|---|---|---|---|
| **Submodule** | Separate repo; parent stores a gitlink (a tree entry of mode `160000`) | `--recurse-submodules` required | Exact commit, always | Natural — commit in the submodule | Detached HEAD inside the submodule; forgotten `--recurse`; unreachable pinned commit |
| **Subtree** | Vendored into the parent's tree | Plain clone works | By import commit | `git subtree push`, awkward | History pollution; contributors who don't know it is vendored |
| **Package registry** | Artifact, not source | Plain clone | Version range or lock file | Release cycle | Version skew; supply-chain surface |
| **Vendor directory** | Copied files, no link upstream | Plain clone | Manual | None | Silent divergence from upstream fixes |

Submodules in practice — the full lifecycle, including the parts people skip:

```
$ git submodule add -b release-1.29 ssh://git@git.example.org/platform/charts.git vendor/charts
Cloning into '/home/ada/mono/vendor/charts'...
done.

$ cat .gitmodules
[submodule "vendor/charts"]
	path = vendor/charts
	url = ssh://git@git.example.org/platform/charts.git
	branch = release-1.29

$ git ls-files --stage vendor/charts
160000 4d2f8a1b6c9e0f3a5b7d2e4f6a8c0b1d3e5f7a92 0	vendor/charts

$ git commit -q -m 'build: pin platform charts to release-1.29'
```

Mode `160000` is the gitlink: the parent commit stores *a commit hash of another repository*, nothing else. Consequences: the submodule's objects are not in the parent's object DB, and if that commit is force-pushed away upstream, every parent commit referencing it becomes uncloneable.

```
$ git config --global submodule.recurse true
$ git clone --recurse-submodules ssh://git@git.example.org/platform/mono.git
$ git submodule update --init --recursive --depth 1
$ git submodule status
 4d2f8a1b6c9e0f3a5b7d2e4f6a8c0b1d3e5f7a92 vendor/charts (release-1.29-7-g4d2f8a1)
```

A leading `-` in `git submodule status` means uninitialized; `+` means the checked-out commit differs from the one the parent pins — the single most common "it works on my machine" cause in submodule repos.

Subtree, for comparison — no extra clone step for consumers, at the cost of a fatter history:

```
$ git subtree add --prefix=vendor/charts ssh://git@git.example.org/platform/charts.git release-1.29 --squash
git fetch ssh://git@git.example.org/platform/charts.git release-1.29
Added dir 'vendor/charts'

$ git subtree pull --prefix=vendor/charts ssh://git@git.example.org/platform/charts.git release-1.29 --squash
```

---

## 6. Integrity and provenance: signing, protection, ownership

An unsigned commit's `author` field is a free-text string. `git commit --author="Linus Torvalds <torvalds@linux-foundation.org>"` is not an attack, it is a documented flag. Attribution therefore requires cryptography.

### 6.1 SSH-based commit signing (Git 2.34+)

Simpler to operate than GPG at platform scale because the key material and distribution mechanism already exist:

```
$ git config --global gpg.format ssh
$ git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub
$ git config --global commit.gpgsign true
$ git config --global tag.gpgsign true
$ git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers

$ cat ~/.config/git/allowed_signers
ada@example.org namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7Qm2v3Xk9Lp0Rr5Ty8Uu1Ii2Oo3Pp4Aa5Ss6Dd7Ff
grace@example.org namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK2Ww3Ee4Rr5Tt6Yy7Uu8Ii9Oo0Pp1Aa2Ss3Dd4Ff5Gg

$ git commit -q -m 'feat: enforce mTLS between gateway and billing'
$ git log --show-signature -1
commit e7a91c5d0b3f8a2e6c4d9b1f7a3e5c8d0b2f4a69
Good "git" signature for ada@example.org with ED25519 key SHA256:9Yk3...q1Zc
Author: Ada Lovelace <ada@example.org>
Date:   Thu Sep 18 14:12:03 2026 +0000

    feat: enforce mTLS between gateway and billing

$ git verify-commit HEAD && echo VERIFIED
Good "git" signature for ada@example.org with ED25519 key SHA256:9Yk3...q1Zc
VERIFIED
```

### 6.2 Tags: the only correct release pointer

| Tag type | Object created | Can be signed | Carries date/tagger | `git describe` default | Use |
|---|---|---|---|---|---|
| Lightweight | None — a ref to a commit | No | No | Needs `--tags` | Local bookmarks |
| Annotated | Yes — a tag object | Yes | Yes | Yes | **Every release** |

```
$ git tag -s -a v2.4.1 -m 'release: v2.4.1 — gateway mTLS'
$ git cat-file -p v2.4.1
object e7a91c5d0b3f8a2e6c4d9b1f7a3e5c8d0b2f4a69
type commit
tag v2.4.1
tagger Ada Lovelace <ada@example.org> 1758204723 +0000

release: v2.4.1 — gateway mTLS
-----BEGIN SSH SIGNATURE-----
U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAg...
-----END SSH SIGNATURE-----

$ git describe --tags --always --dirty
v2.4.1-0-ge7a91c5

$ git push origin v2.4.1
```

Tags are mutable by force-push unless the forge forbids it. Protect them server-side; a moved release tag invalidates every artifact built from it.

### 6.3 Ownership and review policy as code

`CODEOWNERS` (GitHub, GitLab, Gitea — put it in `.github/`, `.gitlab/` or the repo root):

```
# Fallback owner for everything not matched below.
*                               @platform/maintainers

# Kubernetes desired state requires both platform and the owning service team.
/deploy/**                      @platform/sre @platform/maintainers
/deploy/prod/**                 @platform/sre @security/appsec

# Anything that touches identity or crypto needs AppSec.
/internal/auth/**               @security/appsec
/internal/crypto/**             @security/appsec

# CI definitions are a privilege-escalation surface: treat them as code.
/.github/workflows/**           @platform/sre @security/appsec
/.gitlab-ci.yml                 @platform/sre @security/appsec
```

Pair it with branch protection that enforces, at minimum: required review from code owners, required status checks, linear history or required merge commits (pick one and be consistent), signed commits, and no force-push / no deletion on `main` and `release/*`.

### 6.4 Repository hygiene files

`.gitignore` — ignore *generated* artifacts; never rely on it to protect secrets (it does nothing for already-tracked files):

```
# Build output
/bin/
/dist/
*.o
*.test

# Local environment — never commit
.env
.env.*
!.env.example
*.kubeconfig
*.pem
*.key

# Editor and OS noise
.idea/
.vscode/
.DS_Store
```

`.gitattributes` — normalize line endings, mark binaries, and stop noisy diffs. This file is the fix for the CRLF churn that makes every Windows contributor's PR touch 4 000 lines:

```
* text=auto eol=lf
*.sh text eol=lf
*.bat text eol=crlf
*.png binary
*.qcow2 filter=lfs diff=lfs merge=lfs -text
go.sum merge=union
package-lock.json -diff linguist-generated=true
secrets.enc.yaml diff=sops
```

---

## 7. Policy enforcement: hooks on both sides of the wire

| Hook | Side | Runs when | Can block? | Realistic use |
|---|---|---|---|---|
| `pre-commit` | Client | Before the commit message editor | Yes | Format, lint, secret scan |
| `prepare-commit-msg` | Client | Before the editor opens | No (edits template) | Inject ticket ID from branch name |
| `commit-msg` | Client | After the message is written | Yes | Conventional Commits check |
| `pre-push` | Client | Before objects are sent | Yes | Block pushes to protected refs, run fast tests |
| `pre-receive` | **Server** | Once per push, before any ref updates | Yes — atomically rejects the whole push | The only place policy is actually enforced |
| `update` | **Server** | Once per ref | Yes — rejects that ref | Per-branch rules |
| `post-receive` | **Server** | After refs updated | No | Trigger CI, notify, mirror |

**Client hooks are advice; server hooks are policy.** Anyone can pass `--no-verify`. Design accordingly: client hooks for fast feedback, server hooks (or forge push rules) for enforcement.

Distribute client hooks with a tracked directory rather than `.git/hooks`, which is never cloned:

```
$ git config --local core.hooksPath .githooks
$ install -m 0755 /dev/stdin .githooks/pre-push <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
protected='^refs/heads/(main|release/.*)$'
while read -r _local_ref local_sha remote_ref _remote_sha; do
  if [[ "$remote_ref" =~ $protected && "$local_sha" != "0000000000000000000000000000000000000000" ]]; then
    echo "pre-push: direct push to ${remote_ref} is not allowed; open a merge request" >&2
    exit 1
  fi
done
exit 0
EOF
```

A `pre-receive` hook that enforces signatures, message format, and file size — the server-side counterpart:

```bash
#!/usr/bin/env bash
# .git/hooks/pre-receive on the bare repository
set -euo pipefail

ZERO='0000000000000000000000000000000000000000'
MAX_BLOB_BYTES=$((5 * 1024 * 1024))
status=0

while read -r oldrev newrev refname; do
  [ "$newrev" = "$ZERO" ] && continue            # branch deletion

  if [ "$oldrev" = "$ZERO" ]; then
    range="$newrev"
    revs=$(git rev-list "$newrev" --not --all)
  else
    range="${oldrev}..${newrev}"
    revs=$(git rev-list "$range")
  fi

  for rev in $revs; do
    subject=$(git log -1 --format=%s "$rev")
    if ! echo "$subject" | grep -Eq '^(feat|fix|docs|chore|refactor|test|perf|build|ci)(\([a-z0-9-]+\))?!?: .+'; then
      echo "reject ${rev:0:8}: subject does not follow Conventional Commits: $subject" >&2
      status=1
    fi

    if [ "$refname" = "refs/heads/main" ] && ! git verify-commit "$rev" >/dev/null 2>&1; then
      echo "reject ${rev:0:8}: unsigned commit on protected ref $refname" >&2
      status=1
    fi
  done

  while read -r objsize objpath; do
    if [ "$objsize" -gt "$MAX_BLOB_BYTES" ]; then
      echo "reject: $objpath is ${objsize} bytes; use Git LFS for files over ${MAX_BLOB_BYTES}" >&2
      status=1
    fi
  done < <(git rev-list --objects "$range" --not --all \
            | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
            | awk '$1 == "blob" { print $3, $4 }')
done

exit "$status"
```

The rejected push looks like this to the developer — note that **no ref moved**, because `pre-receive` is atomic for the whole push:

```
$ git push origin main
Enumerating objects: 9, done.
Counting objects: 100% (9/9), done.
Writing objects: 100% (5/5), 612 bytes | 612.00 KiB/s, done.
remote: reject 4a9f1c2e: subject does not follow Conventional Commits: wip
remote: reject: assets/demo.mp4 is 41943040 bytes; use Git LFS for files over 5242880
To ssh://git@git.example.org/platform/api.git
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs to 'ssh://git@git.example.org/platform/api.git'
```

### 7.1 The `pre-commit` framework, fully configured

`.pre-commit-config.yaml` in the repository root, installed with `pre-commit install --install-hooks -t pre-commit -t commit-msg`:

```yaml
minimum_pre_commit_version: "3.5.0"
default_install_hook_types:
  - pre-commit
  - commit-msg
  - pre-push
fail_fast: false
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-merge-conflict
      - id: check-added-large-files
        args:
          - "--maxkb=5120"
      - id: check-yaml
        args:
          - "--allow-multiple-documents"
      - id: check-json
      - id: detect-private-key
      - id: no-commit-to-branch
        args:
          - "--branch=main"
          - "--pattern=^release/"
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks:
      - id: yamllint
        args:
          - "--strict"
          - "-d"
          - "{extends: default, rules: {line-length: {max: 160}}}"
  - repo: https://github.com/compilerla/conventional-pre-commit
    rev: v3.4.0
    hooks:
      - id: conventional-pre-commit
        stages:
          - commit-msg
        args:
          - feat
          - fix
          - docs
          - chore
          - refactor
          - test
          - perf
          - build
          - ci
```

```
$ pre-commit run --all-files
trim trailing whitespace.................................................Passed
fix end of files.........................................................Passed
check for merge conflicts................................................Passed
check for added large files..............................................Passed
check yaml...............................................................Passed
check json...............................................................Passed
detect private key.......................................................Failed
- hook id: detect-private-key
- exit code: 1

deploy/prod/tls.yaml:12: BEGIN RSA PRIVATE KEY

yamllint.................................................................Passed
Conventional Commit......................................................Passed
```

---

## 8. The repository as the desired state: GitOps wiring

In a GitOps platform the SCM layer stops being "where developers keep code" and becomes the control-plane input. Two properties become load-bearing: **the revision must be immutable and addressable** (pin to a tag or digest, never a moving branch, for production) and **the reconciler's read access must be least-privilege** (a deploy key with read-only scope, not a personal token).

Argo CD `Application`, pinned to a signed tag, with automated sync and drift correction:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: billing-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ssh://git@git.example.org/platform/deploy.git
    targetRevision: v2.4.1
    path: overlays/prod/billing
  destination:
    server: https://kubernetes.default.svc
    namespace: billing
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
  revisionHistoryLimit: 20
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

The `AppProject` that constrains which repositories Argo CD will even read — without it, a single compromised `Application` can point the cluster at any repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: "Platform-owned workloads, deployed only from the deploy repository"
  sourceRepos:
    - ssh://git@git.example.org/platform/deploy.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: billing
    - server: https://kubernetes.default.svc
      namespace: gateway
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
  signatureKeys:
    - keyID: 4AEE18F83AFDEB23
  roles:
    - name: read-only
      description: "Read-only access for on-call engineers"
      policies:
        - "p, proj:platform:read-only, applications, get, platform/*, allow"
```

`signatureKeys` is the part that ties section 6 to section 8: Argo CD will refuse to sync a revision whose commit is not signed by a listed key. The Git signature becomes an admission control decision.

The equivalent with Flux — the `GitRepository` source, separated from the reconciliation:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-deploy
  namespace: flux-system
spec:
  interval: 1m
  url: ssh://git@git.example.org/platform/deploy.git
  ref:
    tag: v2.4.1
  secretRef:
    name: platform-deploy-key
  verify:
    mode: HEAD
    secretRef:
      name: platform-signing-keys
  ignore: |
    /*
    !/overlays
    !/base
```

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: billing-prod
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: platform-deploy
  path: ./overlays/prod/billing
  targetNamespace: billing
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: billing-api
      namespace: billing
```

The read-only deploy key, mounted as a `Secret` — note `stringData` with placeholder material; the real key is injected by SOPS or an external secrets operator, never committed:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: platform-deploy-key
  namespace: flux-system
type: Opaque
stringData:
  identity: "<ed25519 private key injected by the secrets operator>"
  identity.pub: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7Qm2v3Xk9Lp0Rr5Ty8Uu1Ii2Oo3Pp4Aa5Ss6Dd7Ff flux@example.org"
  known_hosts: "git.example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleHostKeyMaterialGoesHere0123456789"
```

### 8.1 Self-hosted Git server as platform infrastructure

A complete, deployable Gitea instance — the point is that the SCM service is itself declared, versioned and reconciled like any other workload. One document per manifest.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: scm
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitea-config
  namespace: scm
data:
  app.ini: |
    APP_NAME = Example Platform SCM
    RUN_MODE = prod

    [server]
    PROTOCOL = http
    DOMAIN = git.example.org
    ROOT_URL = https://git.example.org/
    HTTP_PORT = 3000
    SSH_DOMAIN = git.example.org
    SSH_PORT = 22
    START_SSH_SERVER = true
    SSH_LISTEN_PORT = 2222
    LFS_START_SERVER = true

    [repository]
    DEFAULT_BRANCH = main
    DEFAULT_PUSH_CREATE_PRIVATE = true

    [repository.signing]
    INITIAL_COMMIT = never
    CRUD_ACTIONS = pubkey, twofa
    MERGES = pubkey, twofa

    [security]
    INSTALL_LOCK = true
    DISABLE_GIT_HOOKS = false

    [service]
    DISABLE_REGISTRATION = true
    REQUIRE_SIGNIN_VIEW = true

    [metrics]
    ENABLED = true

    [log]
    LEVEL = info
```

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: gitea
  namespace: scm
spec:
  serviceName: gitea
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: gitea
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gitea
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "3000"
        prometheus.io/path: /metrics
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: gitea
          image: gitea/gitea:1.22.3-rootless
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 3000
            - name: ssh
              containerPort: 2222
          env:
            - name: GITEA_APP_INI
              value: /etc/gitea/conf/app.ini
            - name: GITEA__database__DB_TYPE
              value: postgres
            - name: GITEA__database__HOST
              value: "postgres.scm.svc.cluster.local:5432"
            - name: GITEA__database__NAME
              value: gitea
            - name: GITEA__database__USER
              valueFrom:
                secretKeyRef:
                  name: gitea-db
                  key: username
            - name: GITEA__database__PASSWD
              valueFrom:
                secretKeyRef:
                  name: gitea-db
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/gitea
            - name: config
              mountPath: /etc/gitea/conf
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: "2"
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /api/healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 60
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
      volumes:
        - name: config
          configMap:
            name: gitea-config
        - name: tmp
          emptyDir:
            sizeLimit: 2Gi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 200Gi
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gitea
  namespace: scm
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: gitea
  ports:
    - name: http
      port: 3000
      targetPort: http
    - name: ssh
      port: 22
      targetPort: ssh
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea
  namespace: scm
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "1024m"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - git.example.org
      secretName: gitea-tls
  rules:
    - host: git.example.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitea
                port:
                  name: http
```

`proxy-body-size` is not cosmetic: the default 1 MiB body limit on NGINX Ingress rejects any push larger than that with an opaque `HTTP 413`, which surfaces to the developer as `RPC failed; HTTP 413`.

Alerting on the SCM service, including the storage-growth signal that predicts the "someone committed a VM image" incident:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: scm-platform
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: scm.rules
      rules:
        - alert: GitServerDown
          expr: up{job="gitea"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Git server unreachable — all pipelines and GitOps reconciliation are blocked"
        - alert: GitRepositoryStorageGrowth
          expr: |
            (
              max by (instance) (gitea_repositories_size_bytes)
              -
              max by (instance) (gitea_repositories_size_bytes offset 7d)
            )
            /
            max by (instance) (gitea_repositories_size_bytes offset 7d)
            > 0.5
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Repository storage grew more than 50 percent in seven days; check for large binaries committed outside LFS"
        - alert: GitVolumeNearlyFull
          expr: |
            kubelet_volume_stats_available_bytes{namespace="scm"}
            /
            kubelet_volume_stats_capacity_bytes{namespace="scm"}
            < 0.15
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "SCM persistent volume below 15 percent free"
```

---

## 9. Large binaries: Git LFS

Git stores every version of every file forever. A 200 MB binary changed weekly adds ~10 GB of packfile per year that every clone must download. LFS replaces the blob with a small text pointer and moves the bytes to a separate store.

```
$ git lfs install
Updated Git hooks.
Git LFS initialized.

$ git lfs track "*.qcow2" "*.tar.zst"
Tracking "*.qcow2"
Tracking "*.tar.zst"

$ cat .gitattributes
*.qcow2 filter=lfs diff=lfs merge=lfs -text
*.tar.zst filter=lfs diff=lfs merge=lfs -text

$ git add .gitattributes images/base.qcow2
$ git commit -q -m 'build: track VM images with LFS'
$ git show HEAD:images/base.qcow2
version https://git-lfs.github.com/spec/v1
oid sha256:6f1e3c9a8b2d4f7e0a1c5b9d3e6f8a2c4b7d0e3f6a9c2b5d8e1f4a7c0b3d6e9f
size 2147483648

$ git lfs ls-files
6f1e3c9a8b * images/base.qcow2
```

| Consideration | Behaviour |
|---|---|
| Clone without LFS installed | You get pointer files, not content — builds fail with "not a valid image" |
| CI | Needs `lfs: true` on checkout, or `git lfs pull` explicitly |
| Server support | The forge must implement the LFS API; a bare SSH repo alone does not |
| Migration of existing history | `git lfs migrate import --include="*.qcow2" --everything` — **rewrites history**, same blast radius as a filter-repo run |
| Deletion | Removing the pointer does not reclaim server storage; LFS objects are garbage-collected separately |

---

## 10. Secrets committed to history: detection, surgical removal, rotation

**First principle: a secret pushed to a shared repository is compromised. Rotate it. Removal from history is cleanup, not remediation** — clones, forks, CI caches and the forge's own dangling-object storage may retain it.

Detect:

```
$ gitleaks detect --source . --redact --report-format json --report-path /tmp/leaks.json
    ○
    │╲
    │ ○
    ○ ░
    ░    gitleaks

10:41AM INF 1483 commits scanned.
10:41AM INF scanned ~48.2 MB (2.19s)
10:41AM WRN leaks found: 2

$ git log --all --oneline -S 'AKIA' -- .
4a9f1c2 chore: local testing setup
b7e3d80 feat: initial terraform for the artifact bucket
```

`git log -S<string>` is the *pickaxe*: it finds commits where the number of occurrences of the string changed — i.e. where it was introduced or removed. `git log -G<regex>` matches the diff text itself. Both are the correct tools for "when did this line appear", and both are far cheaper than scanning checkouts.

Remove, using `git-filter-repo` (the maintained replacement for the deprecated `git filter-branch`):

```
$ git clone --mirror ssh://git@git.example.org/platform/api.git api-mirror.git
$ cd api-mirror.git
$ git filter-repo --invert-paths --path .env.production --path terraform/secrets.auto.tfvars
Parsed 1483 commits
New history written in 4.12 seconds; now repacking/cleaning...
Repacking your repo and cleaning out old unneeded objects
Completely finished after 9.87 seconds.

$ git filter-repo --replace-text <(printf 'AKIAIOSFODNN7EXAMPLE==>***REMOVED***\n')
Parsed 1483 commits
New history written in 3.64 seconds; now repacking/cleaning...
Completely finished after 8.91 seconds.

$ git count-objects -vH
count: 0
size: 0 bytes
in-pack: 21488
packs: 1
size-pack: 38.11 MiB
prune-packable: 0
garbage: 0
size-garbage: 0 bytes
```

The consequences, which must be communicated before you run it:

1. **Every commit hash after the earliest rewritten commit changes.** Tags, PR references, deployment records, and `git describe` outputs that named old hashes now point at nothing.
2. Every clone must be re-created. A developer who pulls and merges will *reintroduce* the old history.
3. `git-filter-repo` deliberately removes the `origin` remote after rewriting, so you cannot push by accident.
4. The forge still holds unreachable objects until it runs its own GC — open a support/admin request to purge them.

```
$ git remote add origin ssh://git@git.example.org/platform/api.git
$ git push --force --mirror origin
```

Then rotate: revoke the AWS key, re-issue the token, re-seal the SOPS file, and record the incident.

---

## 11. Verification and failure diagnosis

### 11.1 Health of the object database

```
$ git fsck --full --strict --unreachable --dangling
Checking object directories: 100% (256/256), done.
Checking objects: 100% (21488/21488), done.
dangling commit 3f1a9b7c0d2e5f8a1b4c7d0e3f6a9c2b5d8e1f40
dangling blob 7c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4f7a0b3c69

$ git count-objects -vH
count: 1842
size: 12.44 MiB
in-pack: 21488
packs: 3
size-pack: 214.66 MiB
prune-packable: 118
garbage: 0
size-garbage: 0 bytes

$ git gc --prune=now
Enumerating objects: 23330, done.
Counting objects: 100% (23330/23330), done.
Delta compression using up to 8 threads
Compressing objects: 100% (6104/6104), done.
Writing objects: 100% (23330/23330), done.
Total 23330 (delta 15918), reused 21488 (delta 14700), pack-reused 0
```

"Dangling" is normal after a rebase, reset or amend — it is unreferenced history awaiting GC, and it is exactly what you recover from. "Corrupt" is not normal; see the table below.

### 11.2 Finding the commit that broke production

`git bisect` is a binary search over history. `git bisect run` automates it with a script whose exit code decides: `0` = good, `1..124` = bad, `125` = skip (untestable), `>127` = abort.

```
$ git bisect start
$ git bisect bad v2.4.1
$ git bisect good v2.3.0
Bisecting: 61 revisions left to test after this (roughly 6 steps)
[8f3c1a90b2d4e6f8a0c2e4f6a8c0e2f4a6c8e0f2] refactor: split the gateway config loader

$ git bisect run ./hack/repro-regression.sh
running './hack/repro-regression.sh'
Bisecting: 30 revisions left to test after this (roughly 5 steps)
...
d41c8e7b3a5f9c2e6b0d4f8a1c5e9b3d7f0a2c64 is the first bad commit
commit d41c8e7b3a5f9c2e6b0d4f8a1c5e9b3d7f0a2c64
Author: Grace Hopper <grace@example.org>
Date:   Mon Sep 14 09:22:41 2026 +0000

    fix: normalise upstream timeout units

 internal/gateway/config.go | 6 +++---
 1 file changed, 3 insertions(+), 3 deletions(-)
bisect found first bad commit

$ git bisect reset
Previous HEAD position was d41c8e7 fix: normalise upstream timeout units
Switched to branch 'main'
```

Complementary forensics:

```
$ git blame -L 88,96 --show-email -w -C internal/gateway/config.go
d41c8e7b (<grace@example.org> 2026-09-14 09:22:41 +0000 88)     timeout := cfg.UpstreamTimeout * time.Second
d41c8e7b (<grace@example.org> 2026-09-14 09:22:41 +0000 89)     if timeout <= 0 {

$ git log --first-parent --oneline --decorate main..origin/main
$ git log --format='%h %ad %an %s' --date=short --since='7 days ago' -- deploy/prod/
```

`-w` ignores whitespace changes and `-C` follows code moved between files — without them, `blame` frequently credits a reformatting commit instead of the author of the logic.

### 11.3 Recovery from destructive operations

```
$ git reset --hard HEAD~5
HEAD is now at 1a2b3c4 chore: bump base image

$ git reflog
1a2b3c4 HEAD@{0}: reset: moving to HEAD~5
9c1f0a4 HEAD@{1}: commit: feat: add readiness probe
...

$ git reset --hard HEAD@{1}
HEAD is now at 9c1f0a4 feat: add readiness probe
```

If the reflog entry is gone but GC has not run, the commit is still a dangling object:

```
$ git fsck --lost-found
dangling commit 3f1a9b7c0d2e5f8a1b4c7d0e3f6a9c2b5d8e1f40

$ git show --stat 3f1a9b7
$ git branch recovered/probe 3f1a9b7
```

### 11.4 Diagnosis table: symptom → mechanism → resolution

| Message / symptom | What is actually happening | Resolution |
|---|---|---|
| `fatal: refusing to merge unrelated histories` | The two branches share no merge base (two independent `git init`s) | `git merge --allow-unrelated-histories` — and verify it is what you want, not a mis-added remote |
| `! [rejected] main -> main (non-fast-forward)` | Remote has commits you do not | `git fetch && git rebase origin/main` (or merge); never `--force` on a shared ref |
| `! [remote rejected] (pre-receive hook declined)` | Server policy refused the push, atomically | Read the `remote:` lines; fix locally and re-push |
| `You are in 'detached HEAD' state` | `.git/HEAD` holds a hash, not a symref | `git switch -c <branch>` to keep the work, or `git switch -` to discard the position |
| `fatal: Not possible to fast-forward, aborting.` | `pull.ff=only` and histories diverged | `git pull --rebase` or `git pull --no-rebase` explicitly |
| `error: object file .git/objects/ab/cdef… is empty` | Corrupt loose object, usually an unclean shutdown or full disk | Delete the empty file, `git fsck`, then fetch the object from another clone: `git fetch <peer-clone> --tags` |
| `fatal: remote error: upload-pack: not our ref <sha>` | A submodule or CI pin references a commit that was force-pushed away | Restore the commit upstream, or re-pin the submodule to a reachable commit |
| `shallow update not allowed` | Pushing from a `--depth` clone into a full repo | `git fetch --unshallow` before pushing |
| Every file shows as modified after checkout | CRLF/LF normalization mismatch | Add `* text=auto eol=lf` to `.gitattributes`, then `git add --renormalize .` |
| A file appears twice with different case | Case-insensitive filesystem (macOS/Windows) collapsed two paths | `git config core.ignorecase true` locally; fix by removing one path on a case-sensitive host |
| LFS files are small text blobs | LFS filter not installed in that environment | `git lfs install && git lfs pull`; in CI set `lfs: true` on checkout |
| `RPC failed; curl 92 HTTP/2 stream … / HTTP 413` | Proxy or ingress body-size limit on a large push | Raise `proxy-body-size`, or push over SSH; `git config http.postBuffer 524288000` as a stopgap |
| Clone takes minutes in every CI job | Full history + blobs fetched | `--filter=blob:none` + sparse checkout; `--depth=1` only if no history is read |
| `.git` directory grows without bound | Loose objects never packed, or large binaries in history | `git maintenance start`; audit with `git rev-list --objects --all \| git cat-file --batch-check` and move binaries to LFS |
| Commits appear out of order in `git log` | `--date-order` vs author date; or committer clock skew | Use `git log --date-order` / `--topo-order`; fix NTP on the offending host |
| A resolved conflict reappears resolved *wrongly* | `rerere` replayed a bad cached resolution | `git rerere forget <path>`, resolve again |

### 11.5 A verification routine worth automating

```
$ git fsck --full --strict
$ git count-objects -vH
$ git verify-commit HEAD
$ git verify-tag "$(git describe --tags --abbrev=0)"
$ git log --oneline --no-merges origin/main..HEAD
$ git diff --stat origin/main...HEAD
$ git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . || echo 'no conflict markers'
$ git ls-files -z | xargs -0 -n1 -I{} sh -c 'test $(git cat-file -s :{} 2>/dev/null || echo 0) -lt 5242880 || echo "large: {}"'
```

Three dots (`origin/main...HEAD`) in `git diff` means "changes on HEAD since the merge base" — the diff a reviewer sees. Two dots means "difference between the two endpoints", which includes changes made on `origin/main` inverted. Choosing the wrong one is the source of PR diffs that appear to revert other people's work.

---

## 12. Command reference, grouped by mechanism

| Concern | Commands |
|---|---|
| Create / obtain | `git init [--bare] [--initial-branch=main] [--object-format=sha256]`, `git clone [--depth] [--filter] [--recurse-submodules] [--single-branch]` |
| Inspect state | `git status [--short] [--branch]`, `git diff [--staged] [--stat] [A...B]`, `git show`, `git log [--oneline] [--graph] [--first-parent] [-S] [-G] [--follow]`, `git blame [-L] [-w] [-C]` |
| Stage and record | `git add [-p] [--renormalize]`, `git rm [--cached]`, `git mv`, `git commit [-s] [-S] [--amend] [--fixup]`, `git restore [--staged]` |
| Branch and position | `git branch [-a] [-m] [--merged]`, `git switch [-c] [--detach]`, `git checkout`, `git worktree add`, `git tag [-a] [-s] [-d]` |
| Integrate | `git merge [--no-ff] [--ff-only] [--squash] [-s ort]`, `git rebase [-i] [--onto] [--autosquash]`, `git cherry-pick [-x]`, `git revert [-m 1]`, `git range-diff` |
| Exchange | `git remote [-v] [add] [set-url]`, `git fetch [--prune] [--unshallow]`, `git pull [--rebase] [--ff-only]`, `git push [--tags] [--force-with-lease] [--force-if-includes] [--mirror]` |
| Undo | `git reset [--soft|--mixed|--hard]`, `git restore`, `git revert`, `git reflog`, `git stash [push -u] [list] [pop] [drop]` |
| Composition | `git submodule [add] [update --init --recursive] [status] [sync]`, `git subtree [add] [pull] [push]`, `git lfs [install] [track] [ls-files] [migrate]` |
| Forensics | `git bisect [start] [good] [bad] [run] [reset]`, `git fsck [--lost-found]`, `git rev-list --objects --all`, `git cat-file [-t|-s|-p|--batch-check]`, `git hash-object`, `git ls-tree`, `git ls-files --stage`, `git verify-pack -v` |
| Maintenance | `git gc [--prune=now]`, `git repack -adb`, `git commit-graph write --reachable`, `git multi-pack-index write`, `git maintenance [start|run]`, `git count-objects -vH` |
| Provenance | `git commit -S`, `git tag -s`, `git verify-commit`, `git verify-tag`, `git log --show-signature`, `git notes` |

---

## Referencias

- LPI — DevOps Tools Engineer, Exam 701 Objectives (v2.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- Git — Reference manual (all commands): https://git-scm.com/docs
- Git — Pro Git book, "Git Internals": https://git-scm.com/book/en/v2/Git-Internals-Plumbing-and-Porcelain
- Git — `git-merge` and merge strategies (`ort`, `octopus`, `ours`): https://git-scm.com/docs/git-merge
- Git — `git-rebase`: https://git-scm.com/docs/git-rebase
- Git — `git-rerere`: https://git-scm.com/docs/git-rerere
- Git — `git-bisect`: https://git-scm.com/docs/git-bisect
- Git — `git-submodule`: https://git-scm.com/docs/git-submodule
- Git — `gitattributes(5)`: https://git-scm.com/docs/gitattributes
- Git — `gitignore(5)`: https://git-scm.com/docs/gitignore
- Git — `githooks(5)`: https://git-scm.com/docs/githooks
- Git — `git-maintenance`: https://git-scm.com/docs/git-maintenance
- Git — `git-config` (`transfer.fsckObjects`, `uploadpack.allowFilter`, `gpg.ssh.allowedSignersFile`): https://git-scm.com/docs/git-config
- Git — Partial clone design documentation: https://git-scm.com/docs/partial-clone
- Git — `git-sparse-checkout`: https://git-scm.com/docs/git-sparse-checkout
- Git — Hash function transition (SHA-256): https://git-scm.com/docs/hash-function-transition
- Git — `git-filter-branch` deprecation notice and alternatives: https://git-scm.com/docs/git-filter-branch
- git-filter-repo — upstream repository and user manual: https://github.com/newren/git-filter-repo
- Git LFS — specification and documentation: https://github.com/git-lfs/git-lfs/tree/main/docs
- GitHub Docs — About protected branches: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- GitHub Docs — About code owners: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners
- GitHub Docs — Merge queue: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- GitLab Docs — GitLab Flow: https://docs.gitlab.com/ee/topics/gitlab_flow.html
- GitLab Docs — Protected branches: https://docs.gitlab.com/ee/user/project/protected_branches.html
- Conventional Commits 1.0.0: https://www.conventionalcommits.org/en/v1.0.0/
- pre-commit — framework documentation: https://pre-commit.com/
- Gitleaks — documentation: https://github.com/gitleaks/gitleaks
- Argo CD — Application specification and GnuPG signature verification: https://argo-cd.readthedocs.io/en/stable/user-guide/gpg-verification/
- Argo CD — Projects: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Flux — GitRepository API: https://fluxcd.io/flux/components/source/gitrepositories/
- Flux — Kustomization API: https://fluxcd.io/flux/components/kustomize/kustomizations/
- OpenGitOps — Principles v1.0.0: https://opengitops.dev/
- Gitea — Configuration cheat sheet: https://docs.gitea.com/administration/config-cheat-sheet
- Sigstore — Gitsign, keyless Git commit signing: https://docs.sigstore.dev/cosign/signing/gitsign/