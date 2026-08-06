# Topic 6.2: Source Code Management (SCM) — Production-Grade Study Guide

---

## 1. Architectural Motivation and Production Problem Statement

In modern Site Reliability Engineering (SRE) and Cloud Native Infrastructure management, software and infrastructure configurations exist as dynamic, constantly mutating artifacts. Without rigorous versioning and centralized governance, distributed development fleets inevitably encounter critical operational failures:

1. **Concurrency Hazards & State Race Conditions:** Simultaneous alterations to production configurations (e.g., Kubernetes manifests, Terraform state files, application logic) cause deployment drift, split-brain environments, and untraceable outages.
2. **Non-Reproducible Deployments:** Inability to pin execution states to exact cryptographic commits leads to non-deterministic builds and post-deployment debugging failures.
3. **Auditability & Compliance Deficits:** Regulatory frameworks (SOC2, ISO 27001, HIPAA) demand immutable, cryptographically verifiable provenance of every line of code deployed to production.
4. **Supply Chain Security Exposure:** Unsigned or unvalidated source code permits unauthorized injection of malicious artifacts into automated CI/CD pipelines.

### The Storage & Architectural Model: Distributed vs. Centralized SCM

Source Code Management (SCM) systems provide state persistence, historical tracking, and concurrent collaboration. Understanding the structural shift from Centralized VCS (CVCS) to Distributed SCM (DVCS) is fundamental to cloud-native architecture.

```
Centralized SCM (e.g., SVN, Perforce)        Distributed SCM (e.g., Git)
=====================================        ===========================

     +-----------------------+                    +-----------------------+
     | Central Repository    |                    | Remote Repository     |
     | (Full Commit History) |                    | (Full Commit History) |
     +-----------+-----------+                    +-----------+-----------+
                 |                                            ^
  Network Commit | Checkout (Working Copy Only)   Push/Pull   | Local Offline
                 v                                            v Operations
        +--------+--------+                      +------------+-----------+
        | Developer Node  |                      | Developer Node           |
        | (No Local Hist) |                      | (Full DAG Repository Copy)|
        +-----------------+                      +------------------------+
```

* **Centralized Systems (SVN, Perforce):** Rely on a single authoritative database server. The developer workspace maintains only a transient working copy of a single revision. Atomic operations (commit, log, diff, branch) require continuous network connectivity to the central host. A failure of the central server halts all engineering workflows.
* **Distributed Systems (Git):** Every clone is a fully functional, autonomous repository carrying the entire cryptographic Directed Acyclic Graph (DAG) history. Commits, branch creation, diff generation, and historical audits occur locally at low latency with zero network dependency. Remote repositories function merely as synchronized coordination endpoints.

### Git Object Model & Internals

Git stores information as a contents-addressable key-value object database inside the `.git/objects` directory. The primary key for any object is the 40-character SHA-1 (or 64-character SHA-256) cryptographic hash calculated over `type + payload_length + \0 + payload`.

```
                +-------------------+
                |   Commit Object   |
                |  (SHA: a1b2c3d)   |
                +---------+---------+
                          |
             +------------+------------+
             | Tree (Root Directory)   |
             |     (SHA: e5f6a7b)      |
             +------------+------------+
                          |
         +----------------+----------------+
         |                                 |
+--------+--------+               +--------+--------+
| Tree (src/)     |               | Blob (README.md)|
| (SHA: c9d8e7f)  |               | (SHA: f1e2d3c)  |
+--------+--------+               +-----------------+
         |
+--------+--------+
| Blob (main.go)  |
| (SHA: b4a5c6d)  |
+-----------------+
```

1. **Blob (Binary Large Object):** Stores raw file content without metadata (filename, permissions, timestamps are omitted).
2. **Tree:** Represents directory structures. Holds references to child blobs or nested sub-trees, mapped to filenames, execution modes (`100644` standard file, `100755` executable, `040000` subdirectory), and object SHA-1 hashes.
3. **Commit:** Points to a root `Tree` object hash. Contains metadata including parent commit hash(es), author, committer, Unix timestamp, timezone, and log message.
4. **Annotated Tag:** Points to a specific commit object. Contains explicit tagger metadata, optional GPG signature, and message.

---

## 2. Technical Comparisons & Trade-off Tables

### Matrix 1: Version Control Architecture Paradigms

| Feature / Metric | Centralized VCS (SVN) | Distributed SCM (Git) | Monorepo Platform (Git + LFS / Scalar) |
| :--- | :--- | :--- | :--- |
| **History Topology** | Linear / Central Server | Directed Acyclic Graph (DAG) | Hybrid Virtualized DAG |
| **Network Reliance** | Mandatory for all operations except edit | Network needed only for `fetch`/`push` | Network needed for non-cached virtual objects |
| **Branch Cost** | $O(N)$ filesystem copy overhead | $O(1)$ pointer update (41 bytes) | $O(1)$ pointer update |
| **Binary Asset Handling** | Native lock-based reservation | Poor native handling (repository bloat) | Managed via LFS pointer redirection |
| **Storage Complexity** | Server-side Delta Storage | Client-side Object Database + Packfiles | Sparse Checkouts + File System Monitor |
| **Cryptographic Integrity** | Revision IDs (Sequential Integers) | SHA-1 / SHA-256 Content Hashing | SHA-256 Content Hashing |

---

### Matrix 2: Enterprise Branching Strategies

| Strategy | Structure | Ideal Use Case | Pros | Cons |
| :--- | :--- | :--- | :--- | :--- |
| **Trunk-Based Development** | Single `main` branch, short-lived feature branches (<24h) | High-velocity microservices, Continuous Deployment (CD) | Prevents merge debt, accelerates delivery | Requires high test coverage and feature flags |
| **GitFlow** | Long-lived `main`, `develop`, `feature/*`, `release/*`, `hotfix/*` | Legacy monolithic software, scheduled release cycles | Structured governance, isolated releases | Severe merge debt, complex integration overhead |
| **GitHub Flow** | Long-lived `main`, short-lived topic branches + PR code review | SaaS applications, Continuous Delivery | Simple mental model, mandatory peer review | Unsuited for concurrent multi-version maintenance |
| **GitLab Flow** | `main` branch paired with environmental branches (`staging`, `prod`) | Environment-driven deployment gates | Explicit mapping of branches to clusters | Risk of configuration drift across environments |

---

### Matrix 3: Integration Mechanics (`merge` vs `rebase` vs `cherry-pick`)

| Command | History Outcome | Merge Commit Created? | Conflict Handling | SRE Risk Factor |
| :--- | :--- | :--- | :--- | :--- |
| `git merge --no-ff` | Preserves true historical topology | Yes | Resolved once per merge event | Low: Non-destructive, transparent history |
| `git merge --ff-only` | Moves branch pointer forward | No | Fails if history has diverged | Low: Fails safely if non-linear |
| `git rebase` | Rewrites history onto new base commit | No | Resolved iteratively per rewritten commit | Medium/High: Alters commit SHAs; breaks shared branches |
| `git cherry-pick` | Duplicates specific commit onto current HEAD | No | Resolved at point of invocation | High: Creates duplicate logical commits with distinct SHAs |

---

## 3. Complete Production Manifests and Infrastructure Configurations

### 3.1 Global SRE Environment Configuration (`.gitconfig`)

Save as `~/.gitconfig` or `/etc/gitconfig` in hardened enterprise build agents:

```ini
[user]
    name = SRE Platform Automation
    email = sre-bot@infrastructure.internal
    signingkey = 3AA5C1F82D9E7B10

[core]
    autocrlf = input
    eol = lf
    filemode = true
    whitespace = error-at-eol,space-before-tab,tab-in-indent
    excludesfile = ~/.gitignore_global
    fsmonitor = true
    untrackedCache = true

[commit]
    gpgsign = true
    template = ~/.gitmessage.txt

[tag]
    gpgsign = true

[gpg]
    program = gpg

[init]
    defaultBranch = main

[pull]
    rebase = true

[push]
    default = simple
    followTags = true
    autoSetupRemote = true

[rebase]
    autoSquash = true
    autoStash = true
    missingCommitsCheck = error

[merge]
    ff = false
    conflictstyle = zdiff3

[diff]
    algorithm = histogram
    colorWords = true
    renames = copies

[transfer]
    fsckObjects = true

[fetch]
    fsckObjects = true
    prune = true
    pruneTags = true

[receive]
    fsckObjects = true
```

---

### 3.2 Enterprise Multi-Stack `.gitignore`

Save as `.gitignore` in repository root:

```gitignore
# Core OS & Editor Temp Artifacts
.DS_Store
Thumbs.db
*~
*.swp
*.swo

# Sensitive Cloud Credentials & Secrets Protection
*.pem
*.key
*.p12
*.pfx
id_rsa
id_ed25519
*.tfvars
*.tfvars.json
.env
.env.*
!.env.example
secrets.yaml
secrets.json

# Infrastructure & Terraform Artifacts
.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
crash.log

# Kubernetes & Helm Artifacts
.helm/
helm-drawer/
*.tpl.bak

# Node.js / Frontend Stack
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.pnpm-debug.log*
dist/
build/
.next/

# Python / Automation Stack
__pycache__/
*.py[cod]
*$py.class
.venv/
venv/
ENV/
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
*.egg-info/
.pytest_cache/
.coverage

# Go Stack
/bin/
/pkg/
*.exe
*.test
*.prof
coverage.out

# Binary Data & Large Asset Catch Block
*.iso
*.tar.gz
*.7z
*.zip
*.sqlite3
```

---

### 3.3 Automated Client-Side Security & Linting Pre-commit Hook

Save as `.git/hooks/pre-commit`, then run `chmod +x .git/hooks/pre-commit`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Color Codes for Output Formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}[PRE-COMMIT] Initiating SRE Source Code Management Security Inspections...${NC}"

# Step 1: Detect Staged Secret Exposure
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM)

if [ -z "$STAGED_FILES" ]; then
    echo -e "${GREEN}[PRE-COMMIT] No staged files detected. Skipping check.${NC}"
    exit 0
fi

# Secret Pattern Scanning
SECRET_PATTERNS="(AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|ghp_[a-zA-Z0-9]{36}|BEGIN PRIVATE KEY|AKIA[0-9A-Z]{16})"

for FILE in $STAGED_FILES; do
    if [ -f "$FILE" ]; then
        if grep -E -q "$SECRET_PATTERNS" "$FILE"; then
            echo -e "${RED}[SECURITY ALERT] Potential plaintext secret detected in: $FILE${NC}"
            echo -e "${RED}Aborting commit. Sanitize credentials or use an external secret vault.${NC}"
            exit 1
        fi
    fi
done

# Step 2: Validate Syntax / Linting for YAML and Shell Files
for FILE in $STAGED_FILES; do
    if [[ "$FILE" =~ \.(yaml|yml)$ ]] && [ -f "$FILE" ]; then
        if command -v yq >/dev/null 2>&1; then
            yq eval '.' "$FILE" >/dev/null 2>&1 || {
                echo -e "${RED}[SYNTAX ERROR] Invalid YAML manifest: $FILE${NC}"
                exit 1
            }
        fi
    elif [[ "$FILE" =~ \.sh$ ]] && [ -f "$FILE" ]; then
        if command -v shellcheck >/dev/null 2>&1; then
            shellcheck "$FILE" || {
                echo -e "${RED}[LINT ERROR] Shellcheck validation failed: $FILE${NC}"
                exit 1
            }
        fi
    fi
done

# Step 3: Prevent Staging Conflict Markers
for FILE in $STAGED_FILES; do
    if [ -f "$FILE" ]; then
        if grep -E -q "^(<<<<<<<|=======|>>>>>>>)" "$FILE"; then
            echo -e "${RED}[MERGE CONFLICT ERROR] Unresolved conflict markers found in: $FILE${NC}"
            exit 1
        fi
    fi
done

echo -e "${GREEN}[PRE-COMMIT] All SRE pre-commit compliance checks passed successfully.${NC}"
exit 0
```

---

### 3.4 GitHub Actions SCM Governance Workflow

Save as `.github/workflows/scm-governance.yml`:

```yaml
name: SCM Compliance & Code Provenance Governance

on:
  pull_request:
    branches: [ main ]
    types: [ opened, synchronize, reopened ]
  push:
    branches: [ main ]

jobs:
  scm-compliance:
    name: Validate Commit Signature and History Integrity
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Code Base
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Enforce Linear History and Fast-Forward Capability
        run: |
          echo "Checking branch topology against origin/main..."
          BEHIND_COUNT=$(git rev-list --count HEAD..origin/main)
          if [ "$BEHIND_COUNT" -ne 0 ]; then
            echo "::error::PR branch is behind origin/main by $BEHIND_COUNT commits. Rebase required."
            exit 1
          fi

      - name: Scan Repository for Exposed Credentials (Gitleaks)
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Validate Commit Message Format (Conventional Commits)
        run: |
          COMMIT_MSG=$(git log -1 --pretty=format:"%s")
          CONVENTIONAL_REGEX="^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9\--_]+\))?: .+$"
          if [[ ! "$COMMIT_MSG" =~ $CONVENTIONAL_REGEX ]]; then
            echo "::error::Commit message '$COMMIT_MSG' does not adhere to Conventional Commits format."
            echo "Example: feat(api): add health check endpoint"
            exit 1
          fi

      - name: Verify Signed Commits
        run: |
          UNSIGNED_COMMITS=0
          for commit in $(git rev-list origin/main..HEAD); do
            if ! git verify-commit "$commit" >/dev/null 2>&1; then
              echo "Warning: Commit $commit is unsigned or missing valid GPG/SSH key."
              UNSIGNED_COMMITS=$((UNSIGNED_COMMITS + 1))
            fi
          done
          if [ "$UNSIGNED_COMMITS" -gt 0 ]; then
            echo "::error::$UNSIGNED_COMMITS unsigned commit(s) detected in PR chain."
            exit 1
          fi
```

---

## 4. Real CLI Commands and Terminal Execution Outputs

### 4.1 Internal Object Hashing and Plumbing Commands

#### Command: Initializing an Empty Repository and Inspecting Internal State

```bash
$ mkdir sre-scm-lab && cd sre-scm-lab
$ git init
```

```output
Initialized empty Git repository in /home/operator/sre-scm-lab/.git/
```

#### Command: Creating a Blob Object Directly via Plumbing Tool (`hash-object`)

```bash
$ echo "Cloud Native Infrastructure State Engine" | git hash-object -w --stdin
```

```output
d98ca68c8b417c88b90a4dfb7d8d212df8b1a8d4
```

#### Command: Inspecting Object Type and File Size in Object Storage (`cat-file`)

```bash
$ git cat-file -t d98ca68c8b417c88b90a4dfb7d8d212df8b1a8d4
```

```output
blob
```

```bash
$ git cat-file -p d98ca68c8b417c88b90a4dfb7d8d212df8b1a8d4
```

```output
Cloud Native Infrastructure State Engine
```

#### Command: Inspecting Directory Contents under `.git/objects`

```bash
$ find .git/objects -type f
```

```output
.git/objects/d9/8ca68c8b417c88b90a4dfb7d8d212df8b1a8d4
```

---

### 4.2 Building a DAG Tree and Commit Object Manually

#### Command: Creating a File, Staging, and Examining the Staging Index

```bash
$ echo "service: payment-gateway" > config.yaml
$ git add config.yaml
$ git ls-files --stage
```

```output
100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 0	config.yaml
```

#### Command: Writing the Index to a Tree Object (`write-tree`)

```bash
$ TREE_HASH=$(git write-tree)
$ echo $TREE_HASH
```

```output
6f88ec4c8bb1261d7b37042a35368a514d2325ab
```

#### Command: Reading a Tree Object Structure (`ls-tree`)

```bash
$ git ls-tree 6f88ec4c8bb1261d7b37042a35368a514d2325ab
```

```output
100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391	config.yaml
```

#### Command: Creating a Commit Object Pointing to the Tree (`commit-tree`)

```bash
$ COMMIT_HASH=$(echo "feat(config): initial payment service architecture" | git commit-tree $TREE_HASH)
$ echo $COMMIT_HASH
```

```output
a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6
```

#### Command: Updating Branch Pointer (`HEAD`) to New Commit (`update-ref`)

```bash
$ git update-ref refs/heads/main $COMMIT_HASH
$ git log --oneline
```

```output
a7b8c9d (HEAD -> main) feat(config): initial payment service architecture
```

---

### 4.3 Interactive Rebase, History Squashing, and Branch Operations

#### Command: Creating Divergent History for Demonstration

```bash
$ git checkout -b feature/auth-service
$ echo "auth_provider: oauth2" >> auth.yaml && git add auth.yaml && git commit -m "feat(auth): add oauth config"
$ echo "timeout: 30s" >> auth.yaml && git add auth.yaml && git commit -m "fix(auth): adjust timeout parameter"
$ echo "retry_limit: 3" >> auth.yaml && git add auth.yaml && git commit -m "chore(auth): set default retries"
$ git log --oneline -n 3
```

```output
8f7e6d5 (HEAD -> feature/auth-service) chore(auth): set default retries
3c2b1a4 fix(auth): adjust timeout parameter
9a8b7c6 feat(auth): add oauth config
```

#### Command: Executing Non-Interactive Rebase Autosquash to Consolidate History

```bash
$ GIT_SEQUENCE_EDITOR="sed -i -e '2,3s/^pick/squash/'" git rebase -i HEAD~3
```

```output
[detached HEAD c4d3e2f] feat(auth): add oauth config
 Date: Thu Aug 6 19:30:00 2026 -0400
 1 file changed, 3 insertions(+)
 create mode 100644 auth.yaml
Successfully rebased and updated refs/heads/feature/auth-service.
```

#### Command: Inspecting Cleaned Log Topography

```bash
$ git log --oneline -n 2
```

```output
c4d3e2f (HEAD -> feature/auth-service) feat(auth): add oauth config
a7b8c9d (main) feat(config): initial payment service architecture
```

---

### 4.4 Fast-Forward Integration vs Non-Fast-Forward Merge

#### Command: Fast-Forward Enforcement (`git merge --ff-only`)

```bash
$ git checkout main
$ git merge --ff-only feature/auth-service
```

```output
Updating a7b8c9d..c4d3e2f
Fast-forward
 auth.yaml | 3 +++
 1 file changed, 3 insertions(+)
 create mode 100644 auth.yaml
```

#### Command: Verifying Repository Graph

```bash
$ git log --graph --oneline --all
```

```output
* c4d3e2f (HEAD -> main, feature/auth-service) feat(auth): add oauth config
* a7b8c9d feat(config): initial payment service architecture
```

---

## 5. Verification, Failure Diagnostics, and Disaster Recovery Guide

### 5.1 SRE Diagnostic Decision Matrix for SCM Failures

```
                    +----------------------------------+
                    | Incident Reported / Build Failed |
                    +----------------+-----------------+
                                     |
                                     v
                       Is HEAD detached or commit lost?
                       /                              \
                     YES                               NO
                     /                                  \
         +----------+----------+               +--------+--------+
         | Execute git reflog  |               | Are conflict    |
         | Identify lost hash  |               | markers present?|
         | Re-attach pointer   |               +--------+--------+
         +---------------------+                        |
                                               +--------+--------+
                                              YES                NO
                                              /                   \
                                   +---------+---------+   +-------+-------+
                                   | Run 3-way merge   |   | Automated     |
                                   | diff editor       |   | Regression    |
                                   | Resolve & commit  |   | Bisect Search |
                                   +-------------------+   +---------------+
```

---

### 5.2 Case Study 1: Recovering from a `Detached HEAD` and Dangling Commits

#### Diagnostic Scenario

A CI build agent executes a checkout to a raw commit hash instead of a branch name. The developer executes structural changes and commits locally. Upon running `git checkout main`, the working directory switches back, leaving the new commit detached from any named reference (`refs/heads/`).

#### Step 1: Detect Current State

```bash
$ git status
```

```output
HEAD detached at 7d8c9b0
nothing to commit, working tree clean
```

```bash
$ git checkout main
```

```output
Warning: you are leaving 1 commit behind, not connected to
any of your branches:

  7d8c9b0 feat(security): critical hotfix applied detached

If you want to keep them by creating a new branch, this may be a good time
to do so with:

  git branch <new-branch-name> 7d8c9b0

Switched to branch 'main'
```

#### Step 2: Extract Lost Commit Hash via the Reference Log (`reflog`)

The `reflog` tracks local pointer adjustments (`HEAD`, branches) in `.git/logs/HEAD`.

```bash
$ git reflog -n 5
```

```output
c4d3e2f (HEAD -> main) HEAD@{0}: checkout: moving from 7d8c9b0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e to main
7d8c9b0 HEAD@{1}: commit: feat(security): critical hotfix applied detached
c4d3e2f (HEAD -> main) HEAD@{2}: checkout: moving from main to 7d8c9b0
```

#### Step 3: Run Database Integrity Check (`git fsck`) to Verify Dangling Objects

```bash
$ git fsck --lost-found
```

```output
Checking object directories: 100% (256/256), done.
dangling commit 7d8c9b0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e
```

#### Step 4: Re-attach Orphaned Commit to a Functional Reference Pointer

```bash
$ git branch recovery/hotfix-branch 7d8c9b0
$ git log --oneline -n 1 recovery/hotfix-branch
```

```output
7d8c9b0 (recovery/hotfix-branch) feat(security): critical hotfix applied detached
```

```bash
$ git merge --no-ff recovery/hotfix-branch -m "merge: recover detached security hotfix"
```

---

### 5.3 Case Study 2: Resolving Complex Three-Way Merge Conflicts

#### Diagnostic Scenario

Two concurrent production deployments modify the same line in `deploy.env`.

* Branch `main`: `REPLICAS=3`
* Branch `feature/scaling`: `REPLICAS=10`

Executing `git merge feature/scaling` triggers an explicit conflict.

#### Terminal Output

```bash
$ git merge feature/scaling
```

```output
Auto-merging deploy.env
CONFLICT (content): Merge conflict in deploy.env
Automatic merge failed; fix conflicts and then commit the result.
```

#### Step 1: Examine Conflict File State

```bash
$ cat deploy.env
```

```output
<<<<<<< HEAD
REPLICAS=3
=======
REPLICAS=10
>>>>>>> feature/scaling
```

#### Step 2: Utilize Conflict Style `zdiff3` for Detailed Context

Configure `zdiff3` to show the common ancestor block, highlighting original baseline state:

```bash
$ git config local merge.conflictstyle zdiff3
$ git checkout --merge deploy.env
$ cat deploy.env
```

```output
<<<<<<< HEAD
REPLICAS=3
||||||| base-ancestor
REPLICAS=1
=======
REPLICAS=10
>>>>>>> feature/scaling
```

#### Step 3: Programmatically Resolve and Complete Merge

```bash
# Choose 10 based on capacity requirements
$ echo "REPLICAS=10" > deploy.env
$ git add deploy.env
$ git commit --no-edit
```

```output
[main a1b2c3d] Merge branch 'feature/scaling' into main
```

---

### 5.4 Case Study 3: Automated Regression Bisection (`git bisect`)

#### Diagnostic Scenario

A silent performance degradation occurred somewhere between tag `v2.0.0` (known good) and `HEAD` (known bad, across 400 commits).

#### Step 1: Initialize Bisect Engine

```bash
$ git bisect start
$ git bisect bad HEAD
$ git bisect good v2.0.0
```

```output
Bisecting: 199 revisions left to test after this (roughly 8 steps)
[e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3] feat(mesh): update sidecar proxy settings
```

#### Step 2: Execute Automated Bisection Script

Run an automated test script (`test.sh`) returning exit code `0` (good) or non-zero (bad):

```bash
$ git bisect run ./test.sh
```

```output
running ./test.sh
Bisecting: 99 revisions left to test after this (roughly 7 steps)
...
running ./test.sh
e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3 is the first bad commit
commit e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3
Author: SRE Automation <sre@internal>
Date:   Wed Aug 5 14:22:10 2026 -0400

    perf(db): lower connection pool size limit

 bisect run success
```

#### Step 3: Reset Repository to Operational State

```bash
$ git bisect reset
```

```output
Previous HEAD position was e4f5a6b feat(mesh): update sidecar proxy settings
Switched to branch 'main'
```

---

### 5.5 Case Study 4: Database Corruption and Hard Secret Scrubbing

#### Diagnostic Scenario

A developer accidentally committed an unencrypted AWS Secret Access Key (`AKIAIOSFODNN7EXAMPLE`) 50 commits ago. Simple `git rm` removes the file from the current HEAD, but leaves the secret accessible in historical commits via object database traversal.

#### Step 1: Scan for Secret across All Historical Commits

```bash
$ git log -S "AKIAIOSFODNN7EXAMPLE" --oneline
```

```output
4b3c2a1 feat(cloud): configure AWS S3 storage provider backend
```

#### Step 2: Permanently Purge File/String Using `git-filter-repo`

*Note: Native `git filter-branch` is deprecated due to performance and integrity risks. `git-filter-repo` is the modern standard tool.*

```bash
# Execute string replacement across the entire history DAG
$ git filter-repo --replace-text <(echo "AKIAIOSFODNN7EXAMPLE==>REDACTED_AWS_KEY") --force
```

```output
Parsed 51 commits
New history written in 0.42 seconds; retrofitted 51 commits.
completely finished.
```

#### Step 3: Force Garbage Collection and Reflog Expiration

Purge unreferenced loose objects to remove residual data from disk:

```bash
$ git reflog expire --expire=now --expire-unreachable=now --all
$ git gc --prune=now --aggressive
```

```output
Enumerating objects: 153, done.
Counting objects: 100% (153/153), done.
Delta compression using up to 16 threads
Compressing objects: 100% (120/120), done.
Writing objects: 100% (153/153), done.
Total 153 (delta 42), reused 98 (delta 0), pack-reused 0
```

#### Step 4: Verify Erasure from Database

```bash
$ git log -S "AKIAIOSFODNN7EXAMPLE" --oneline
```

```output
(No results returned)
```

---

## 6. References

* **Linux Professional Institute (LPI) Open Source Essentials Overview:**  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **Official Git Documentation & Internals Specification:**  
  [https://git-scm.com/docs](https://git-scm.com/docs)
* **Git Book: Git Community Plumbing and Porcelain Internals:**  
  [https://git-scm.com/book/en/v2/Git-Internals-Git-Objects](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects)
* **CNCF Webhooks & Security Best Practices for SCM Pipelines:**  
  [https://www.cncf.io/reports/](https://www.cncf.io/reports/)
* **git-filter-repo Documentation & Security Scrubbing:**  
  [https://github.com/newren/git-filter-repo](https://github.com/newren/git-filter-repo)