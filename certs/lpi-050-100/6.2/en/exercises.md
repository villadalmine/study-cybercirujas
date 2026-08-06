# Exam Preparation & Production Engineering Guide: LPI 050-100
## Topic 6.2: Source Code Management (Weight: 7.5)

### Reference & Official Documentation Sources
- [LPI Open Source Essentials Certification Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- [LPI Open Source Essentials Official Objectives (Topic 056.2)](https://wiki.lpi.org/wiki/Open_Source_Essentials_Objectives_V1.0)
- [Official Git Documentation & Core Architecture Specifications](https://git-scm.com/doc)

---

## Technical Overview & Architectural Foundations

Source Code Management (SCM) systems are the core operational foundation of modern software engineering, SRE, and Cloud-Native DevOps ecosystems. In open-source and enterprise infrastructure workflows, SCM enables concurrent development, auditability, immutable version control, continuous integration (CI/CD) pipelines, and disaster recovery.

### Centralized vs. Distributed SCM Systems

| Feature / Architecture | Centralized SCM (CSCM) (e.g., Subversion / SVN) | Distributed SCM (DSCM) (e.g., Git) |
| :--- | :--- | :--- |
| **Repository Model** | Single central server holds complete revision history. Local clients retain only a working copy. | Every client maintains a full clone of the object database and revision history DAG. |
| **Network Dependency** | Required for commits, diffs, history inspection, and branching operations. | Commits, history queries, branches, and diffs are executed locally offline. Network is used only for sync (`push`/`fetch`). |
| **Single Point of Failure** | Central server outage halts all version control operations and poses total data loss risk if unbacked. | Decentralized resilience; every local peer acts as a full backup of the canonical repository structure. |
| **Branching Performance** | Expensive directory copy or server-side metadata manipulation; slow over latency-heavy WANs. | Near-instantaneous reference manipulation (`O(1)` pointer updates pointing to immutable commit SHA hashes). |

### Git Internal Object Storage Architecture

Git is a content-addressable key-value object database stored under `.git/objects/`. Objects are hashed using standard SHA-1 (40 hex characters) or SHA-256 (64 hex characters) and compressed via `zlib`.

```
                    +------------------------------------+
                    |        Commit Object               |
                    | Hash: e4b2c1...                    |
                    |  - tree: 8a3f91...                 |
                    |  - parent: 12d7a4...               |
                    |  - author: Dev <dev@example.com>   |
                    |  - message: "Feat: Add API spec"   |
                    +-----------------+------------------+
                                      |
                                      v
                    +------------------------------------+
                    |         Tree Object                |
                    | Hash: 8a3f91...                    |
                    |  - 100644 blob c23a10... README.md |
                    |  - 040000 tree b91e03... src       |
                    +--------+------------------+--------+
                             |                  |
                             v                  v
          +----------------------+   +----------------------+
          |     Blob Object      |   |     Tree Object      |
          | Hash: c23a10...      |   | Hash: b91e03...      |
          | Content: "# Project" |   |  - 100644 blob ...   |
          +----------------------+   +----------------------+
```

1. **Blob (`blob`)**: Stores raw file content (binary or text). It stores no metadata (filename, permissions, timestamps).
2. **Tree (`tree`)**: Represents a directory layer. Maps filenames, mode flags (e.g., `100644` standard file, `100755` executable), and child hashes (blobs or nested trees).
3. **Commit (`commit`)**: Points to a top-level directory tree hash, records parent commit hash(es), author/committer identities, Unix timestamps, and log message.
4. **Annotated Tag (`tag`)**: An explicit object pointing directly to a specific commit hash, containing tagger metadata, signature, and message.

---

## Lab Block 1: Architecture & Internal Mechanics of Git Object Store

In this lab, you will manually initialize a repository, inspect the low-level metadata directory layout, craft raw Git objects directly inside the key-value database, and reconstruct a commit without invoking standard high-level Porcelain wrapper commands.

### Hands-on Guided Steps

1. Create a workspace directory and initialize a fresh Git repository:
```bash
mkdir -p ~/scm-internals-lab && cd ~/scm-internals-lab
git init
```
**Expected Output:**
```text
Initialized empty Git repository in /home/user/scm-internals-lab/.git/
```

2. Inspect the `.git` metadata storage architecture:
```bash
ls -la .git/
```
**Expected Output:**
```text
total 32
drwxr-rf- 7 user user 4096 Aug  6 19:30 .
drwxr-rf- 3 user user 4096 Aug  6 19:30 ..
-rw-r--r-- 1 user user   23 Aug  6 19:30 HEAD
-rw-r--r-- 1 user user  130 Aug  6 19:30 config
-rw-r--r-- 1 user user   73 Aug  6 19:30 description
drwxr-rf- 2 user user 4096 Aug  6 19:30 hooks
drwxr-rf- 2 user user 4096 Aug  6 19:30 info
drwxr-rf- 4 user user 4096 Aug  6 19:30 objects
drwxr-rf- 4 user user 4096 Aug  6 19:30 refs
```

3. Generate a content blob directly in the object database using `git hash-object`:
```bash
BLOB_SHA=$(echo "Production Platform Config v1" | git hash-object -w --stdin)
echo "Generated Blob SHA: ${BLOB_SHA}"
```
**Expected Output:**
```text
Generated Blob SHA: cb12803f27ae55734df2dd93b8aa9c3c0422c544
```

4. Verify how Git stores this compressed object on disk under `.git/objects/`:
```bash
ls -la .git/objects/${BLOB_SHA:0:2}/
```
**Expected Output:**
```text
total 12
drwxr-rf- 2 user user 4096 Aug  6 19:31 .
drwxr-rf- 4 user user 4096 Aug  6 19:31 ..
-r--r--r-- 1 user user   51 Aug  6 19:31 12803f27ae55734df2dd93b8aa9c3c0422c544
```

5. Inspect the object type and decompressed contents using Plumbing command `git cat-file`:
```bash
git cat-file -t ${BLOB_SHA}
git cat-file -p ${BLOB_SHA}
```
**Expected Output:**
```text
blob
Production Platform Config v1
```

6. Manually stage the object into the index buffer (`.git/index`) using `git update-index`:
```bash
git update-index --add --cacheinfo 100644 ${BLOB_SHA} config.txt
git ls-files -s
```
**Expected Output:**
```text
100644 cb12803f27ae55734df2dd93b8aa9c3c0422c544 0	config.txt
```

7. Write the index state into a Tree object and capture its tree SHA:
```bash
TREE_SHA=$(git write-tree)
echo "Written Tree SHA: ${TREE_SHA}"
git cat-file -p ${TREE_SHA}
```
**Expected Output:**
```text
Written Tree SHA: d3542cfb8c56c2d1b7dfb3d2bbf40adcd023ae81
100644 blob cb12803f27ae55734df2dd93b8aa9c3c0422c544	config.txt
```

8. Create an initial commit object referencing this tree hash:
```bash
COMMIT_SHA=$(echo "Initial production config commit" | git commit-tree ${TREE_SHA})
echo "Written Commit SHA: ${COMMIT_SHA}"
git cat-file -p ${COMMIT_SHA}
```
**Expected Output:**
```text
Written Commit SHA: 8f420a811c7694931a788b776bd3114cf60d3d52
tree d3542cfb8c56c2d1b7dfb3d2bbf40adcd023ae81
author SRE Lead <sre@example.com> 1754518315 -0400
committer SRE Lead <sre@example.com> 1754518315 -0400

Initial production config commit
```

9. Update the default branch reference (`refs/heads/main`) to point to this new commit hash:
```bash
git update-ref refs/heads/main ${COMMIT_SHA}
git symbolic-ref HEAD refs/heads/main
git log -n 1
```
**Expected Output:**
```text
commit 8f420a811c7694931a788b776bd3114cf60d3d52 (HEAD -> main)
Author: SRE Lead <sre@example.com>
Date:   Thu Aug 6 19:31:55 2026 -0400

    Initial production config commit
```

---

### Verification Questions (Lab Block 1)

**Question 1.1:** A developer creates two separate files named `app-dev.env` and `app-prod.env` in different subdirectories. Both files contain the exact same content string: `DB_PORT=5432`. How many blob objects will Git create in `.git/objects/`?
- A) 2 blob objects, because filenames and folder paths differ.
- B) 1 blob object, because Git computes SHA hash solely based on content header and payload bytes.
- C) 2 blob objects, because permissions and directory paths are embedded into the blob header.
- D) 0 blob objects, because files in staging are stored in `.git/index` only until committed.

**Question 1.2:** Which file inside `.git/` determines the active working branch reference?
- A) `.git/config`
- B) `.git/refs/heads/main`
- C) `.git/HEAD`
- D) `.git/index`

---

## Lab Block 2: Working Directory, Index/Staging Lifecycle & Ignore Architecture

Git operates on a **Three-State Model**:
1. **Working Directory**: The local sandbox filesystem where files are actively edited.
2. **Staging Area (Index)**: A binary file (`.git/index`) listing pathnames, permissions, and object hashes preparing the precise state of the upcoming commit.
3. **Git Repository (Object Store)**: The permanent, immutable history database storing DAG commits, trees, and blobs.

```
+------------------+      git add       +------------------+     git commit     +------------------+
|                  | -----------------> |                  | -----------------> |                  |
| Working Directory|                    | Staging Area     |                    | Git Repository   |
| (Sandbox Files)  | <----------------- | (Binary Index)   | <----------------- | (Object Database)|
+------------------+     git checkout   +------------------+     git reset      +------------------+
```

### Hands-on Guided Steps

1. Create working files representing microservice source code, logs, and sensitive secrets:
```bash
cd ~/scm-internals-lab
echo "package main" > main.go
echo "PORT=8080" > .env
mkdir -p logs && echo "runtime error log" > logs/app.log
```

2. Configure advanced file ignore patterns via `.gitignore`:
```bash
cat << 'EOF' > .gitignore
# Ignore all environment secret files
*.env

# Ignore all contents of logs directory
logs/

# Exception: keep logs/keep.me directory placeholder
!logs/keep.me
EOF
touch logs/keep.me
```

3. Query the status of tracked, untracked, and ignored files using Plumbing status flag `git status --short`:
```bash
git status --short --branch
```
**Expected Output:**
```text
## main
?? .gitignore
?? main.go
```

4. Validate why `.env` and `logs/app.log` were ignored using `git check-ignore`:
```bash
git check-ignore -v .env logs/app.log logs/keep.me
```
**Expected Output:**
```text
.gitignore:2:*.env	.env
.gitignore:5:logs/	logs/app.log
```

5. Stage the codebase files into the Index database:
```bash
git add main.go .gitignore logs/keep.me
git ls-files -s
```
**Expected Output:**
```text
100644 1e0062b8813a89052b947a1610e74f1b203c9d74 0	.gitignore
100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 0	logs/keep.me
100644 b62cb174e2d3e1208a0d92233f2a89849206d203 0	main.go
```

6. Modify `main.go` in the working directory to observe state divergence between Working Directory, Index, and HEAD:
```bash
echo 'func main() { println("Service Running") }' >> main.go
git diff
```
**Expected Output:**
```text
diff --git a/main.go b/main.go
index b62cb17..5d10b77 100644
--- a/main.go
+++ b/main.go
@@ -1 +1,2 @@
 package main
+func main() { println("Service Running") }
```

7. Inspect differences between the Staged Index and the current HEAD commit:
```bash
git diff --staged
```
**Expected Output:**
```text
diff --git a/.gitignore b/.gitignore
new file mode 100644
index 0000000..1e0062b
--- /dev/null
+++ b/.gitignore
@@ -0,0 +1,8 @@
+# Ignore all environment secret files
+*.env
+
+# Ignore all contents of logs directory
+logs/
+
+# Exception: keep logs/keep.me directory placeholder
+!logs/keep.me
diff --git a/logs/keep.me b/logs/keep.me
new file mode 100644
index 0000000..e69de29
diff --git a/main.go b/main.go
index 0000000..b62cb17
--- /dev/null
+++ b/main.go
@@ -0,0 +1 @@
+package main
```

8. Commit the staged changes to form a second commit node in the DAG:
```bash
git commit -m "Feat: Add core app entrypoint and ignore rules"
```
**Expected Output:**
```text
[main 4f1a92e] Feat: Add core app entrypoint and ignore rules
 3 files changed, 10 insertions(+)
 create mode 100644 .gitignore
 create mode 100644 logs/keep.me
 create mode 100644 main.go
```

---

### Verification Questions (Lab Block 2)

**Question 2.1:** What is the exact operational effect of the command `git diff --staged` (synonymous with `git diff --cached`)?
- A) It compares differences between the Working Directory and the local Git Repository HEAD.
- B) It compares differences between the Staging Area (Index) and the latest commit (`HEAD`).
- C) It compares differences between the local branch `HEAD` and the remote tracking branch.
- D) It checks uncommitted working tree edits against untracked files.

**Question 2.2:** A system engineer runs `git add .` after creating a confidential file `db_pass.key`. However, `.gitignore` already contains `*.key`. What happens?
- A) Git overrides `.gitignore` and stages `db_pass.key` anyway.
- B) Git ignores `db_pass.key` and prints a fatal error aborting the entire command.
- C) Git safely skips `db_pass.key` without staging it, while staging other valid modified files.
- D) Git moves `db_pass.key` into `.git/lost-found/`.

---

## Lab Block 3: Branching, Merging Mechanics, Tagging & Remote Fork Workflows

Git branches are light pointers to specific 40-character commit hashes in `.git/refs/heads/`.
Merging integrates distinct commit histories:
- **Fast-Forward Merge**: If the target branch has no divergent commits relative to the source branch, Git simply moves the ref pointer forward (`O(1)` operation).
- **3-Way Merge**: If both branches diverged, Git calculates a common ancestor commit, evaluates edits from both sides, and generates a new synthetic **Merge Commit** with two parent hashes.

```
Fast-Forward Merge:
main:    C1 ---> C2
                  \
feature:           C3 ---> C4  (main pointer simply advances to C4)

3-Way Merge:
main:    C1 ---> C2 ---------> C5 (Merge Commit: Parents C2, C4)
                  \           /
feature:           C3 ---> C4/
```

### Hands-on Guided Steps

1. Create and switch to a feature branch named `feature/auth`:
```bash
cd ~/scm-internals-lab
git checkout -b feature/auth
```
**Expected Output:**
```text
Switched to a new branch 'feature/auth'
```

2. Inspect the reference file generated inside `.git/refs/heads/`:
```bash
cat .git/refs/heads/feature/auth
```
**Expected Output:**
```text
4f1a92e34c9c1b72e5d91aa8931b6210419a4891
```

3. Make a commit on `feature/auth` to simulate new functionality:
```bash
echo 'func Auth() { println("JWT Auth") }' >> auth.go
git add auth.go
git commit -m "Feat(auth): Add JWT validation logic"
```

4. Switch back to `main` branch and create a conflicting edit on `main.go`:
```bash
git checkout main
echo '// Main entrypoint updated on main branch' >> main.go
git add main.go
git commit -m "Refactor(main): Update main package inline docs"
```

5. View the divergent DAG branches using log graph formatting:
```bash
git log --graph --oneline --all
```
**Expected Output:**
```text
* a1b2c3d (HEAD -> main) Refactor(main): Update main package inline docs
| * 7e8f9a0 (feature/auth) Feat(auth): Add JWT validation logic
|/
* 4f1a92e Feat: Add core app entrypoint and ignore rules
* 8f420a8 Initial production config commit
```

6. Execute a 3-Way Merge from `feature/auth` into `main`:
```bash
git merge feature/auth -m "Merge branch 'feature/auth' into main"
```
**Expected Output:**
```text
Merge made by the 'ort' strategy.
 auth.go | 1 +
 1 file changed, 1 insertion(+)
 create mode 100644 auth.go
```

7. Inspect the newly created Merge Commit object structure:
```bash
git cat-file -p HEAD
```
**Expected Output:**
```text
tree 6f2a89012cd345ef1a2b3c4d5e6f7a8b9c0d1e2f
parent a1b2c3d4e5f67890123456789abcdef012345678
parent 7e8f9a0123456789abcdef0123456789abcdef01
author SRE Lead <sre@example.com> 1754518500 -0400
committer SRE Lead <sre@example.com> 1754518500 -0400

Merge branch 'feature/auth' into main
```

8. Create an **Annotated Release Tag** with cryptographic tagger signature details:
```bash
git tag -a v1.0.0 -m "Production Release Candidate v1.0.0"
git cat-file -p v1.0.0
```
**Expected Output:**
```text
object e4b2c19876543210fedcba9876543210fedcba98
type commit
tag v1.0.0
tagger SRE Lead <sre@example.com> 1754518550 -0400

Production Release Candidate v1.0.0
```

9. Configure upstream and origin remotes to simulate an Enterprise Fork / Pull Request workflow:
```bash
git remote add origin git@github.com:my-org-fork/scm-internals-lab.git
git remote add upstream git@github.com:canonical-enterprise/scm-internals-lab.git
git remote -v
```
**Expected Output:**
```text
origin	git@github.com:my-org-fork/scm-internals-lab.git (fetch)
origin	git@github.com:my-org-fork/scm-internals-lab.git (push)
upstream	git@github.com:canonical-enterprise/scm-internals-lab.git (fetch)
upstream	git@github.com:canonical-enterprise/scm-internals-lab.git (push)
```

---

### Verification Questions (Lab Block 3)

**Question 3.1:** What distinguishes an **Annotated Tag** (`git tag -a`) from a **Lightweight Tag** (`git tag <name>`) inside the Git Object Storage architecture?
- A) A lightweight tag creates a compressed tarball in `.git/objects/pack/`.
- B) An annotated tag creates a full Git object in the database storing tagger identity, date, and message, whereas a lightweight tag is purely a reference pointer file stored in `.git/refs/tags/`.
- C) Lightweight tags require GPG signing keys, while annotated tags do not.
- D) Annotated tags can only point to Blob objects, whereas lightweight tags point to Commits.

**Question 3.2:** In a fork-based open-source workflow, what is the standard purpose of configuring an `upstream` remote alongside `origin`?
- A) `upstream` points to your personal fork on GitHub, while `origin` points to the local filesystem.
- B) `upstream` points to the canonical central project repository to fetch changes, while `origin` points to your personal write-enabled fork to push feature branches.
- C) `upstream` automatically merges incoming pull requests without local verification.
- D) `origin` stores non-production code, while `upstream` stores compiled binaries.

---

## Lab Block 4: Production Diagnostics, History Auditing & Recovery Techniques

SREs and Platform Engineers must troubleshoot corrupted states, recover dangling commits lost due to forced resets, and inspect commit DAG history using granular diagnostic CLI options.

### Hands-on Guided Steps

1. Simulate an accidental destructive branch reset losing the latest merge commit:
```bash
cd ~/scm-internals-lab
PREV_COMMIT=$(git rev-parse HEAD~1)
git reset --hard ${PREV_COMMIT}
git log --oneline -n 2
```
**Expected Output:**
```text
HEAD is now at a1b2c3d Refactor(main): Update main package inline docs
a1b2c3d Refactor(main): Update main package inline docs
4f1a92e Feat: Add core app entrypoint and ignore rules
```

2. Inspect the **Git Reflog** to locate the dangling commit lost during the hard reset:
```bash
git reflog
```
**Expected Output:**
```text
a1b2c3d (HEAD -> main) HEAD@{0}: reset: moving to HEAD~1
e4b2c19 (v1.0.0) HEAD@{1}: merge feature/auth: Merge made by the 'ort' strategy.
a1b2c3d (HEAD -> main) HEAD@{2}: commit: Refactor(main): Update main package inline docs
```

3. Recover the dangling merge commit from the reflog pointer:
```bash
git reset --hard HEAD@{1}
git log --oneline -n 3
```
**Expected Output:**
```text
HEAD is now at e4b2c19 Merge branch 'feature/auth' into main
e4b2c19 (HEAD -> main, tag: v1.0.0) Merge branch 'feature/auth' into main
a1b2c3d Refactor(main): Update main package inline docs
7e8f9a0 (feature/auth) Feat(auth): Add JWT validation logic
```

4. Audit repository object integrity and search for unreachable dangling objects using `git fsck`:
```bash
git fsck --full --strict
```
**Expected Output:**
```text
Notice: Checking object directory
Notice: Checking finished craft, 0 dangling objects found.
```

5. Perform low-level object packing optimization and garbage collection:
```bash
git gc --prune=now
ls -la .git/objects/pack/
```
**Expected Output:**
```text
total 16
drwxr-rf- 2 user user 4096 Aug  6 19:35 .
drwxr-rf- 5 user user 4096 Aug  6 19:35 ..
-r--r--r-- 1 user user 2048 Aug  6 19:35 pack-a1b2c3d4e5f67890123456789abcdef012345678.idx
-r--r--r-- 1 user user 4096 Aug  6 19:35 pack-a1b2c3d4e5f67890123456789abcdef012345678.pack
```

---

### Verification Questions (Lab Block 4)

**Question 4.1:** A developer executes `git branch -D hotfix-sec` deleting a feature branch before pushing it to remote. What diagnostic command enables the platform engineer to locate the deleted branch's tip SHA hash for recovery?
- A) `git status --all`
- B) `git reflog`
- C) `git remote show origin`
- D) `git check-ignore`

**Question 4.2:** What is the primary function of `git gc` (Garbage Collection) within a production Git repository?
- A) It deletes untracked files in the working directory that are older than 24 hours.
- B) It compresses individual loose objects into consolidated `.pack` binary index files and removes unreachable orphaned objects.
- C) It automatically merges stale feature branches into `main`.
- D) It synchronizes local commits with the remote `upstream` repository.

---

<details>
<summary>Exercise Answer Key & Deep Architectural Explanations</summary>

### Lab Block 1 Answers

**Question 1.1: B**
- **Deep Explanation:** Git's object store is content-addressable. The object SHA hash is computed exclusively via the cryptographic digest of `SHA-1("blob " + content_length + "\0" + payload_bytes)`. Because both `app-dev.env` and `app-prod.env` contain identical byte payloads (`DB_PORT=5432`), they produce the exact same SHA hash. Git stores only **one** blob object inside `.git/objects/`. The distinct pathnames (`app-dev.env` vs `app-prod.env`) are recorded separately in the **Tree** object pointing to that single shared blob SHA.

**Question 1.2: C**
- **Deep Explanation:** The file `.git/HEAD` defines the active context of the repository working directory. In a normal state, it contains a symbolic reference string (e.g., `ref: refs/heads/main`). When you switch branches via `git checkout` or `git switch`, Git updates `.git/HEAD` to point to the target branch reference file inside `.git/refs/heads/`.

---

### Lab Block 2 Answers

**Question 2.1: B**
- **Deep Explanation:** `git diff` without flags compares the **Working Directory** against the **Staging Area (Index)**. Adding the `--staged` (or `--cached`) flag instructs Git to compute the diff between the **Staging Area (Index)** and the current **HEAD commit** in the repository. This allows engineers to review exactly what will be written to disk before running `git commit`.

**Question 2.2: C**
- **Deep Explanation:** When running `git add .`, Git evaluates all untracked and modified files against the matching rules defined in `.gitignore` files. Files that match ignore expressions (such as `*.key`) are safely bypassed without raising errors. If an engineer explicitly wants to force-stage an ignored file, they must bypass the check using `git add -f <filename>`.

---

### Lab Block 3 Answers

**Question 3.1: B**
- **Deep Explanation:** A **Lightweight Tag** is nothing more than a text reference file inside `.git/refs/tags/<tag_name>` holding a 40-character commit hash string (similar to a branch pointer that does not move). An **Annotated Tag** (`git tag -a`) creates an actual immutable **Tag Object** in `.git/objects/`. This object contains its own SHA hash, the target commit SHA, tagger identity metadata, timestamp string, explicit log message, and optional GPG signature block.

**Question 3.2: B**
- **Deep Explanation:** In standard open-source enterprise fork workflows (e.g., contributing to Kubernetes or CNCF repositories), developer accounts do not possess direct push rights to the canonical repository. Developers fork the project under their own account (`origin`) and register the original canonical repository as `upstream`. The `upstream` remote is fetched locally to keep main branches synchronized, while feature branches are pushed to `origin` to open Pull Requests/Merge Requests back to `upstream`.

---

### Lab Block 4 Answers

**Question 4.1: B**
- **Deep Explanation:** Git maintains a local transactional journal called the **Reflog** (`.git/logs/HEAD` and `.git/logs/refs/heads/<branch>`). The reflog records every movement of `HEAD` and branch references resulting from commits, resets, checkouts, merges, or rebased actions. Even if a local branch reference is deleted via `git branch -D`, the historical commits remain inside `.git/objects/` until garbage collection runs, and their exact SHA hash can be retrieved from `git reflog`.

**Question 4.2: B**
- **Deep Explanation:** Over time, operations generate loose object files under `.git/objects/XX/`. `git gc` (Garbage Collection) optimizes repository storage performance by compressing multiple loose blob, tree, and commit objects into unified delta-compressed **Packfiles** (`.pack`) alongside index mappings (`.idx`). Additionally, it prunes unreachable dangling objects older than the `gc.pruneExpire` threshold (default 2 weeks).

</details>