# LPI DevOps Tools Engineer (Exam 701-100) — Topic 1.3: Source Code Management
**Weight:** 8.33  
**Target Audience:** SREs, Platform Engineers, and DevOps Engineers  
**Official Reference:** [LPI DevOps Tools Engineer Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/) | [Git Documentation](https://git-scm.com/doc)

---

## 1. Architectural & Theoretical Deep Dive

### 1.1 Centralized vs. Distributed Version Control Architecture

| Attribute | Centralized SCM (e.g., Subversion / SVN) | Distributed SCM (e.g., Git) |
| :--- | :--- | :--- |
| **Data Storage** | Single central database server holds full history. Clients store working copies of specific revisions. | Every clone is a complete repository containing full history, object store, and ref graph. |
| **Network Dependency** | Commits, diffs, blame, and history logs require network connectivity to the central server. | All core operations (`commit`, `log`, `diff`, `branch`, `rebase`) execute locally offline. Network required only for `fetch`/`push`. |
| **Branching Mechanics** | Copy operations within remote tree (e.g., `svn copy trunk/ branches/feature`). O(N) storage or server directory metadata tracking. | Lightweight reference updates (a 41-byte text file containing a 40-character SHA-1/SHA-256 hash pointing to a commit object). O(1) time complexity. |
| **Concurrency & Integrity** | Lock-Modify-Unlock or Copy-Modify-Merge; revision numbers are monotonic integers (e.g., r1042). | Directed Acyclic Graph (DAG) of content-addressable objects hashed with SHA-1/SHA-256 (Merkle Tree architecture). Cryptographically immutable. |
| **Failure Domain** | Central server data corruption or downtime halts all commit/history operations across the organization. | Fully decentralized; every engineer's machine acts as a complete backup of the repository state. |

---

### 1.2 Git Object Storage Engine & Directory Structure

Git operates as a content-addressable filesystem built on top of a Directed Acyclic Graph (DAG). The `.git` directory contains the complete state:

```
.git/
├── HEAD               # Symbolically points to the active branch ref (e.g., ref: refs/heads/main)
├── config             # Repository-specific configuration file
├── description        # Used by GitWeb (default description file)
├── hooks/             # Client-side and server-side lifecycle hook scripts
├── index              # Binary staging area (Cache) mapping working tree to object database
├── info/
│   └── exclude        # Local ignore pattern file (unshared gitignore)
├── objects/           # Object database (Content-addressable store)
│   ├── [0-9a-f][0-9a-f]/ # Loose objects partitioned by first 2 hex digits of SHA
│   ├── info/          # Object pack metadata
│   └── pack/          # Packed objects (.pack) and index files (.idx) for Delta Compression
└── refs/              # References pointers
    ├── heads/         # Local branch pointers
    ├── tags/          # Tag pointers (lightweight and annotated)
    └── remotes/       # Remote-tracking branch pointers
```

#### The Four Core Object Types

1. **Blob (`blob`)**: Stores raw file binary payload. Does not store file names, modification timestamps, directory structures, or permissions (except the executable bit).
2. **Tree (`tree`)**: Represents a directory. Stores directory listings mapping blob SHA hashes to file names, file modes (`100644` standard file, `100755` executable, `120000` symlink, `040000` subdirectory), and child tree SHAs.
3. **Commit (`commit`)**: Points to a top-level `tree` object representing the project root snapshot at that point in time. Contains metadata: parent commit SHA(s), author (name, email, epoch timestamp, timezone offset), committer, GPG signature block (if signed), and commit message.
4. **Annotated Tag (`tag`)**: An explicit object pointing to a specific commit (or any object type). Contains tagger identity, timestamp, custom tagging message, and optional GPG signature.

---

## 2. Guided Production Exercises

---

### Exercise 1: Low-Level Git Object Store Inspection and Manual Plumbing Object Construction

In this exercise, you will bypass high-level "porcelain" commands (`git add`, `git commit`) and use low-level "plumbing" commands to manually construct blobs, trees, and commit objects directly inside `.git/objects`.

#### Step 1: Initialize an empty repository and inspect the directory state

```bash
mkdir -p /tmp/git-internals-lab && cd /tmp/git-internals-lab
git init
ls -la .git/
```

*Expected Output:*
```text
Initialized empty Git repository in /tmp/git-internals-lab/.git/
total 24
drwxr-xr-x 7 student student 4096 Aug 07 04:45 .
drwxr-xr-x 3 student student 4096 Aug 07 04:45 ..
-rw-r--r-- 1 student student   23 Aug 07 04:45 HEAD
-rw-r--r-- 1 student student  130 Aug 07 04:45 config
-rw-r--r-- 1 student student   73 Aug 07 04:45 description
drwxr-xr-x 2 student student 4096 Aug 07 04:45 hooks
drwxr-xr-x 2 student student 4096 Aug 07 04:45 info
drwxr-xr-x 4 student student 4096 Aug 07 04:45 objects
drwxr-xr-x 4 student student 4096 Aug 07 04:45 refs
```

#### Step 2: Manually write a Blob to the Object Database without creating a file in the working tree

```bash
BLOB_SHA=$(echo "DB_HOST=10.0.4.15" | git hash-object -w --stdin)
echo "Generated Blob SHA: ${BLOB_SHA}"
git cat-file -t ${BLOB_SHA}
git cat-file -p ${BLOB_SHA}
find .git/objects -type f
```

*Expected Output:*
```text
Generated Blob SHA: f4e84b8d7010f3c5b5258e727e466bd6e1d7cf9d
blob
DB_HOST=10.0.4.15
.git/objects/f4/e84b8d7010f3c5b5258e727e466bd6e1d7cf9d
```

#### Step 3: Stage the Blob into the Index and write a Tree object

```bash
git update-index --add --cacheinfo 100644 ${BLOB_SHA} config/db.env
TREE_SHA=$(git write-tree)
echo "Generated Tree SHA: ${TREE_SHA}"
git cat-file -p ${TREE_SHA}
```

*Expected Output:*
```text
Generated Tree SHA: a942e61266e74b5c777aa0d6c072c49980d903cd
040000 tree 82cb7f5a6b0c20f1b2b8e3a2b7f32906e5d81a94	config
```

```bash
git cat-file -p 82cb7f5a6b0c20f1b2b8e3a2b7f32906e5d81a94
```

*Expected Output:*
```text
100644 blob f4e84b8d7010f3c5b5258e727e466bd6e1d7cf9d	db.env
```

#### Step 4: Manually create a Commit object pointing to the Tree and update `refs/heads/main`

```bash
COMMIT_SHA=$(echo "feat(config): initialize database connection parameters" | git commit-tree ${TREE_SHA})
echo "Generated Commit SHA: ${COMMIT_SHA}"
git cat-file -p ${COMMIT_SHA}
git update-ref refs/heads/main ${COMMIT_SHA}
git symbolic-ref HEAD refs/heads/main
git log -1
```

*Expected Output:*
```text
Generated Commit SHA: d29f8c14a90a43e7b1a20822649a37e114bc5d09
tree a942e61266e74b5c777aa0d6c072c49980d903cd
author SRE Engineer <sre@company.internal> 1754541929 -0400
committer SRE Engineer <sre@company.internal> 1754541929 -0400

feat(config): initialize database connection parameters

commit d29f8c14a90a43e7b1a20822649a37e114bc5d09 (HEAD -> main)
Author: SRE Engineer <sre@company.internal>
Date:   Thu Aug 7 04:45:29 2026 -0400

    feat(config): initialize database connection parameters
```

---

#### Exercise 1 Comprehension Questions

1. **Question 1.1:** Why does creating two identical files with the exact same content in different subdirectories result in only **one** blob object created in `.git/objects`?
2. **Question 1.2:** What plumbing command would you execute to verify whether a Git object stored at `.git/objects/a9/42e612...` is corrupted without unpacking its content manually?

---

### Exercise 2: Advanced History Rewriting, Interactive Rebase, and Recovery via Reflog

In high-throughput engineering teams, clean commit history is mandatory before merging PRs. You will perform an interactive rebase to squash multiple commits, modify a commit message, and then recover from a destructive rebase failure using `git reflog`.

#### Step 1: Populate repository with synthetic commits

```bash
cd /tmp/git-internals-lab
echo "v1.0" > app.py && git add app.py && git commit -m "feat: base application v1"
echo "v1.1" >> app.py && git commit -am "fix: typo in print statement"
echo "v1.2" >> app.py && git commit -am "WIP: temporary debug logs"
echo "v1.3" >> app.py && git commit -am "feat: added login feature"
git log --oneline
```

*Expected Output:*
```text
e9a2f1c (HEAD -> main) feat: added login feature
7b41d0e WIP: temporary debug logs
3c82a9f fix: typo in print statement
a1f802d feat: base application v1
d29f8c1 feat(config): initialize database connection parameters
```

#### Step 2: Perform non-interactive automated rebase to squash the last 3 commits into one

We simulate squashing the top 3 commits (`e9a2f1c`, `7b41d0e`, `3c82a9f`) onto `a1f802d`.

```bash
GIT_SEQUENCE_EDITOR="sed -i '2,3 s/^pick/squash/'" git rebase -i HEAD~3
git log --oneline
```

*Expected Output:*
```text
[detached HEAD 9f3e1a0] fix: typo in print statement
 Date: Thu Aug 7 04:46:12 2026 -0400
 1 file changed, 3 insertions(+)
Successfully rebased and updated refs/heads/main.

9f3e1a0 (HEAD -> main) fix: typo in print statement
a1f802d feat: base application v1
d29f8c1 feat(config): initialize database connection parameters
```

#### Step 3: Simulate a destructive git reset hard operation

```bash
git reset --hard d29f8c1
git log --oneline
```

*Expected Output:*
```text
HEAD is now at d29f8c1 feat(config): initialize database connection parameters

d29f8c1 (HEAD -> main) feat(config): initialize database connection parameters
```

#### Step 4: Recover lost commits using `git reflog` and `git reset`

```bash
git reflog -n 5
```

*Expected Output:*
```text
d29f8c1 (HEAD -> main) HEAD@{0}: reset: moving to d29f8c1
9f3e1a0 HEAD@{1}: rebase (finish): returning to refs/heads/main
9f3e1a0 HEAD@{2}: rebase (squash): fix: typo in print statement
a1f802d HEAD@{3}: rebase (start): checkout HEAD~3
e9a2f1c HEAD@{4}: commit: feat: added login feature
```

```bash
git reset --hard HEAD@{1}
git log --oneline
```

*Expected Output:*
```text
HEAD is now at 9f3e1a0 fix: typo in print statement

9f3e1a0 (HEAD -> main) fix: typo in print statement
a1f802d feat: base application v1
d29f8c1 feat(config): initialize database connection parameters
```

---

#### Exercise 2 Comprehension Questions

1. **Question 2.1:** What is the fundamental difference between `git reset --soft`, `git reset --mixed`, and `git reset --hard` regarding the working directory, index, and commit history?
2. **Question 2.2:** If a developer runs `git gc` (Garbage Collection) or `git prune` immediately after a destructive `git reset --hard`, can `git reflog` still guarantee recovery of unreachable dangling commits? Explain why or why not.

---

### Exercise 3: Automated Bug Hunting using `git bisect` with Custom Verification Scripts

When regressions hit production across hundreds of commits, binary search via `git bisect` combined with executable scripts isolates broken commits automatically.

#### Step 1: Generate a test suite repository with a hidden regression

```bash
mkdir -p /tmp/git-bisect-lab && cd /tmp/git-bisect-lab
git init

# Commit 1 (Good state)
echo "def calculate(a, b): return a + b" > math_lib.py
echo "assert calculate(2, 3) == 5" > test_app.py
git add . && git commit -m "commit 1: initial math lib"

# Commits 2 to 6 (Normal changes)
for i in {2..6}; do
    echo "# Change iteration $i" >> math_lib.py
    git commit -am "commit $i: update documentation"
done

# Commit 7 (Introduce subtle bug)
echo "def calculate(a, b): return a - b" > math_lib.py
git commit -am "commit 7: refactor core calculation logic"

# Commits 8 to 12 (More commits following the bug)
for i in {8..12}; do
    echo "# Post bug change $i" >> math_lib.py
    git commit -am "commit $i: feature enhancement $i"
done
```

#### Step 2: Create an automated assertion test script

```bash
cat << 'EOF' > /tmp/git-bisect-lab/verify.sh
#!/bin/bash
python3 -c "import math_lib; assert math_lib.calculate(2, 3) == 5" > /dev/null 2>&1
exit $?
EOF
chmod +x /tmp/git-bisect-lab/verify.sh
```

#### Step 3: Run non-interactive `git bisect run`

```bash
GOOD_COMMIT=$(git rev-parse HEAD~11)
BAD_COMMIT=$(git rev-parse HEAD)

git bisect start ${BAD_COMMIT} ${GOOD_COMMIT}
git bisect run /tmp/git-bisect-lab/verify.sh
```

*Expected Output:*
```text
Bisecting: 5 revisions left to test after this (roughly 3 steps)
[a2d8f9e1...] commit 6: update documentation
running /tmp/git-bisect-lab/verify.sh
Bisecting: 2 revisions left to test after this (roughly 2 steps)
[c7f1b2d4...] commit 8: feature enhancement 8
running /tmp/git-bisect-lab/verify.sh
Bisecting: 0 revisions left to test after this (roughly 1 step)
[e4a9c1b2...] commit 7: refactor core calculation logic
running /tmp/git-bisect-lab/verify.sh
e4a9c1b2f8a1c9e3b5d2a4f6e8c0a2b4c6d8e0f1 is the first bad commit
commit e4a9c1b2f8a1c9e3b5d2a4f6e8c0a2b4c6d8e0f1
Author: SRE Engineer <sre@company.internal>
Date:   Thu Aug 7 04:47:15 2026 -0400

    commit 7: refactor core calculation logic

 math_lib.py | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
bisect run success
```

#### Step 4: Reset bisect state back to normal branch HEAD

```bash
git bisect reset
```

*Expected Output:*
```text
Previous HEAD position was e4a9c1b commit 7: refactor core calculation logic
Switched to branch 'main'
```

---

#### Exercise 3 Comprehension Questions

1. **Question 3.1:** What exit codes must the test script pass to `git bisect run` to distinguish between a **good commit**, a **bad commit**, and an **untestable commit** (e.g., code does not build due to a separate dependency syntax error)?
2. **Question 3.2:** How does `git bisect` handle merge commits during a bisect session by default, and what risk occurs if feature branches were merged without linear history?

---

### Exercise 4: Enterprise Access Control and Server-Side Pre-Receive Hook Implementation

Server-side hooks run on the remote Git server (bare repository) to enforce corporate policy before references are updated. In this exercise, you will create a custom `pre-receive` hook blocking un-signed commits or commits containing illegal credentials/secrets.

#### Step 1: Setup a bare central server repository and a local clone

```bash
mkdir -p /tmp/remote-repo.git && cd /tmp/remote-repo.git
git init --bare

cd /tmp
git clone /tmp/remote-repo.git /tmp/local-developer
cd /tmp/local-developer
git config user.name "Developer One"
git config user.email "developer@company.internal"
```

#### Step 2: Implement a server-side `pre-receive` hook in the bare repository

The hook checks each incoming commit payload to prevent hardcoded private keys (e.g., `-----BEGIN RSA PRIVATE KEY-----`) or AWS keys (`AKIA...`) from landing in the server DAG.

```bash
cat << 'EOF' > /tmp/remote-repo.git/hooks/pre-receive
#!/usr/bin/env bash
set -e

# pre-receive reads standard input: <old-value> <new-value> <ref-name>
while read -r oldrev newrev refname; do
    # Zero SHA means branch deletion
    if [ "$newrev" = "0000000000000000000000000000000000000000" ]; then
        continue
    fi

    # Determine revision range for new commits
    if [ "$oldrev" = "0000000000000000000000000000000000000000" ]; then
        REV_RANGE="$newrev"
    else
        REV_RANGE="$oldrev..$newrev"
    fi

    # Scan committed objects for secret patterns
    for commit in $(git rev-list "$REV_RANGE"); do
        # Inspect blob changes in the commit
        if git diff-tree --no-commit-id --name-only -r "$commit" | grep -q ""; then
            if git grep -E "(AKIA[0-9A-Z]{16}|-----BEGIN (RSA|OPENSSH) PRIVATE KEY-----)" "$commit"; then
                echo "--------------------------------------------------------" >&2
                echo "[POLICY ERROR] Security policy violation detected!" >&2
                echo "Commit $commit contains hardcoded secrets/private keys." >&2
                echo "Push rejected by server pre-receive hook." >&2
                echo "--------------------------------------------------------" >&2
                exit 1
            fi
        fi
    done
done
exit 0
EOF

chmod +x /tmp/remote-repo.git/hooks/pre-receive
```

#### Step 3: Test compliant commit push from local developer machine

```bash
cd /tmp/local-developer
echo "hello world" > README.md
git add README.md
git commit -m "docs: add readme file"
git push origin HEAD:refs/heads/main
```

*Expected Output:*
```text
Enumerating objects: 3, done.
Counting objects: 100% (3/3), done.
Writing objects: 100% (3/3), 242 bytes | 242.00 KiB/s, done.
Total 3 (delta 0), reused 0 (delta 0), pack-reused 0
To /tmp/remote-repo.git
 * [new branch]      HEAD -> main
```

#### Step 4: Test non-compliant commit push containing hardcoded AWS secret key

```bash
cd /tmp/local-developer
echo "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" > aws_config.txt
git add aws_config.txt
git commit -m "feat: add aws credentials config"
git push origin HEAD:refs/heads/main
```

*Expected Output:*
```text
Enumerating objects: 4, done.
Counting objects: 100% (4/4), done.
Delta compression using up to 8 threads
Compressing objects: 100% (2/2), done.
Writing objects: 100% (3/3), 340 bytes | 340.00 KiB/s, done.
Total 3 (delta 0), reused 0 (delta 0), pack-reused 0
remote: --------------------------------------------------------
remote: [POLICY ERROR] Security policy violation detected!
remote: Commit c8f2b1d3a4e9f5c... contains hardcoded secrets/private keys.
remote: Push rejected by server pre-receive hook.
remote: --------------------------------------------------------
error: failed to push some refs to '/tmp/remote-repo.git'
```

---

#### Exercise 4 Comprehension Questions

1. **Question 4.1:** Contrast `pre-commit` (client-side) hooks with `pre-receive` (server-side) hooks in terms of enforcement integrity and bypass capabilities (`--no-verify`).
2. **Question 4.2:** What is the execution order of server-side hooks on a Git remote during a push operation (`pre-receive`, `update`, `post-receive`) and which of these can reject a transaction?

---

### Exercise 5: Managing Dependency Graph at Scale with `git worktree` and `git submodule`

Modern monorepos and multi-repo platforms use Git submodules for external modules and `git worktree` to isolate concurrent feature context switching without cloning or stash operations.

#### Step 1: Manage simultaneous hotfixes without switching branches using `git worktree`

```bash
cd /tmp/local-developer
git worktree list
```

*Expected Output:*
```text
/tmp/local-developer  c8f2b1d [main]
```

```bash
git worktree add -b hotfix/db-connection /tmp/hotfix-workspace main
cd /tmp/hotfix-workspace
git status
```

*Expected Output:*
```text
Preparing worktree (new branch 'hotfix/db-connection')
HEAD is now at c8f2b1d docs: add readme file
On branch hotfix/db-connection
nothing to commit, working tree clean
```

#### Step 2: Clean up worktree directory

```bash
cd /tmp/local-developer
git worktree remove /tmp/hotfix-workspace
git branch -D hotfix/db-connection
```

*Expected Output:*
```text
Deleted branch hotfix/db-connection (was c8f2b1d).
```

#### Step 3: Embed an external shared module using `git submodule`

```bash
# Setup dependency repository
mkdir -p /tmp/shared-lib.git && cd /tmp/shared-lib.git
git init --bare

cd /tmp
git clone /tmp/shared-lib.git /tmp/shared-lib-dev
cd /tmp/shared-lib-dev
echo "def logger(msg): print(msg)" > logger.py
git add logger.py && git commit -m "feat: initial logger lib"
git push origin HEAD:refs/heads/main

# Add submodule to main project
cd /tmp/local-developer
git submodule add /tmp/shared-lib.git libs/shared-logger
cat .gitmodules
```

*Expected Output:*
```text
Cloning into '/tmp/local-developer/libs/shared-logger'...
done.
[submodule "libs/shared-logger"]
	path = libs/shared-logger
	url = /tmp/shared-lib.git
```

#### Step 4: Verify pointer representation of submodule inside host repo index

```bash
git ls-files --stage libs/shared-logger
```

*Expected Output:*
```text
160000 7f4a2b1c8e9d3f5a2b1c4e7d9f2a4b6c8e0f1a3b 0	libs/shared-logger
```

---

#### Exercise 5 Comprehension Questions

1. **Question 5.1:** What does file mode `160000` represent in Git tree objects, and why does a host repository store a commit hash instead of file blobs for submodule paths?
2. **Question 5.2:** When a fresh user clones a repository containing submodules using standard `git clone <url>`, why are the submodule directories empty, and what exact CLI commands populate them?

---

## 3. Answer Key and Deep-Dive Explanations

<details>
<summary><strong>Click to expand Answers and Deep-Dive Explanations</strong></summary>

### Answers to Exercise 1

* **1.1 Answer:**  
  Git is a **content-addressable filesystem**. The SHA-1/SHA-256 hash of a blob object is computed strictly from its payload length and byte contents (`SHA("blob " + size + "\0" + content)`). File names, relative directory paths, and file permissions are **not** stored within the blob itself; they are stored in the parent **Tree object**. Therefore, identical files across different directories yield identical hashes and resolve to the exact same single blob in `.git/objects`. This provides implicit deduplication.

* **1.2 Answer:**  
  Use the plumbing command `git fsck --strict` or `git cat-file -e <SHA>`. `git fsck` (FileSystem Check) verifies the SHA-1 checksum integrity of all objects in the database against their compressed payload and checks DAG pointer validity.

---

### Answers to Exercise 2

* **2.1 Answer:**  
  * `git reset --soft <commit>`: Moves the HEAD pointer to `<commit>`. Leaves the **Index (Staging Area)** and **Working Directory** untouched. Changes between original HEAD and target commit remain staged.
  * `git reset --mixed <commit>` (default): Moves HEAD pointer to `<commit>` AND updates the **Index** to match `<commit>`. Leaves the **Working Directory** untouched. Changes appear as unstaged modifications.
  * `git reset --hard <commit>`: Moves HEAD pointer to `<commit>`, updates the **Index**, AND resets the **Working Directory** to match `<commit>`. All uncommitted local changes and untracked staged files are permanently overwritten.

* **2.2 Answer:**  
  **No**, but with a time boundary condition. Running `git reset --hard` removes branch reference pointers, leaving commits unreachable from any branch or tag tip (dangling commits). However, `git reflog` maintains reference entries pointing to those commit SHAs for a configurable retention window (`gc.reflogExpire`, default **90 days** for reachable refs, **30 days** for unreachable refs).  
  `git gc` will **not** purge dangling commits as long as they are referenced by any entry in `.git/logs/HEAD` or `.git/logs/refs/`. Only if `git reflog expire --expire=now --all` is explicitly run prior to `git gc --prune=now` will `git gc` delete unreachable objects from disk.

---

### Answers to Exercise 3

* **3.1 Answer:**  
  * **Exit Code `0`**: Signals to `git bisect` that the current commit is **GOOD** (pass).
  * **Exit Code `1` to `127` (except 125)**: Signals that the commit is **BAD** (fail / regression present).
  * **Exit Code `125`**: Signals that the commit is **UNTESTABLE** (skip). `git bisect` skips this commit and picks an adjacent commit in the DAG graph.

* **3.2 Answer:**  
  By default, `git bisect` traverses the topological DAG across all parent paths of merge commits. If feature branches were merged via non-linear merge topologies containing broken commits inside side-branches, `git bisect` steps down into branch histories to locate the exact breaking commit.  
  If a merge commit itself introduced a conflict resolution error (where parent A and parent B were both good, but the merge result broke code), `git bisect` correctly identifies the merge commit hash as the regression point.

---

### Answers to Exercise 4

* **4.1 Answer:**  
  * `pre-commit` hooks execute on the developer's local workstation. They are easily bypassed by any client running `git commit --no-verify` or removing `.git/hooks/pre-commit`. They cannot be relied upon for organizational security or compliance guarantees.
  * `pre-receive` hooks execute on the remote Git central server (e.g., GitHub Enterprise, GitLab, bare server). They run within an isolated server environment before refs are updated. Developers **cannot** bypass `pre-receive` hooks regardless of client CLI flags, making them mandatory for enterprise security policies.

* **4.2 Answer:**  
  1. `pre-receive`: Executes **once** per push transaction. Accepts standard input containing all proposed reference updates (`old-sha new-sha ref-name`). If it exits non-zero, the **entire push is aborted**, and no references update.
  2. `update`: Executes **once per updated branch/ref**. Accepts arguments: `<ref-name> <old-sha> <new-sha>`. If it exits non-zero for a specific ref, **only that ref update is rejected**.
  3. `post-receive`: Executes **once** after all references have been successfully updated on disk. Used for asynchronous notifications (Slack, CI/CD trigger). It **cannot** reject or abort the push transaction.

---

### Answers to Exercise 5

* **5.1 Answer:**  
  Mode `160000` is a special Git directory mode representing a **Gitlink** (submodule commit binding reference). A host repository does not store submodule files directly; it records a static 40-character commit hash pointing to an exact commit object inside the remote submodule repository. This decouples host lifecycle from module lifecycle.

* **5.2 Answer:**  
  By default, `git clone` only retrieves the host repository tree objects and gitlink SHAs (`160000`), leaving submodule directories empty.  
  To populate submodules during initial clone:  
  `git clone --recurse-submodules <url>`  
  If the repository was already cloned:  
  `git submodule init` followed by `git submodule update` (or `git submodule update --init --recursive`).

</details>

---

## 4. Key Summary Checklist for LPI 701-100 Topic 1.3

- [x] Understand Git internal object storage structure (`.git/objects/`, `blob`, `tree`, `commit`, `tag`).
- [x] Master plumbing inspection commands: `git cat-file`, `git hash-object`, `git write-tree`, `git update-index`, `git update-ref`.
- [x] Differentiate reset modes: `--soft`, `--mixed`, `--hard` and reference recovery via `git reflog`.
- [x] Automate regression isolation using `git bisect run <script_path>` and handle exit code `125`.
- [x] Implement server-side hooks (`pre-receive`, `update`, `post-receive`) to enforce secret scanning and policy compliance.
- [x] Utilize `git worktree` for zero-overhead contextual workspace switching without stash pollution.
- [x] Manage Git submodules, mode `160000` gitlinks, `.gitmodules` specs, and `--recurse-submodules` cloning mechanics.