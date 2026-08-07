# LPI DevOps Tools Engineer (701-100) — Topic 701.3: Source Code Management

---

## 1. Production Architectural Motivation & Internal Mechanics

### 1.1 Centralized vs. Distributed Source Code Management (SCM)
In legacy enterprise environments, Centralized SCM systems (such as Subversion/SVN and CVS) operated on a client-server architecture with a single authoritative central database. Operations such as history inspection (`svn log`), diff generation (`svn diff`), and commit operations required network round-trips to the central repository server. Centralized systems enforce file locking (exclusive checkout) or server-side merge resolutions, introducing single-point-of-failure (SPOF) risks, network latency bottlenecks, and severe scalability limits when CI/CD pipelines generate hundreds of concurrent read/write operations.

Modern cloud-native platform engineering relies on Distributed SCM (Git). In Git, every local clone is a fully functional repository containing the complete commit history, object database, and ref metadata. This decentralization enables:
- **Offline Autonomy:** Developers and automated pipelines can commit, branch, rebase, and inspect history without network dependencies.
- **High Concurrency:** Read operations execute locally with zero network overhead; network interaction occurs asynchronously via delta-packed network fetches and pushes.
- **Cryptographic Tamper-Resistance:** All states are represented inside an append-only Directed Acyclic Graph (DAG) protected by cryptographic hashing.

---

### 1.2 Git Internal Mechanics & Object Database DAG
Git operates as a content-addressable key-value file system underlying a high-level version control system. All objects inside `.git/objects/` are immutable and identified by a 40-character SHA-1 (or 64-character SHA-256) hash computed over the object type, content length, a null byte delimiter, and the payload content.

```
       +-------------------------------------------------------------+
       |                     Commit Object                           |
       |  SHA: 8f3a1d...                                             |
       |  tree: e9a2b4...                                            |
       |  parent: 4c1d8e...                                          |
       |  author: Dev <dev@company.com>                              |
       |  committer: CI <ci@company.com>                             |
       |                                                             |
       |  feat(api): implement auth middleware                       |
       +------------------------------+------------------------------+
                                      |
                                      v
                       +--------------+---------------+
                       |   Root Tree Object (e9a2b4)  |
                       |  100644 blob a1b2c3... src/  |
                       |  040000 tree d4e5f6... app/  |
                       +--------------+---------------+
                                      |
              +-----------------------+-----------------------+
              |                                               |
              v                                               v
+-------------+----------------+               +--------------+---------------+
|   Blob Object (a1b2c3)       |               | Sub-Tree Object (d4e5f6)     |
|   (src/main.go)              |               | (app/)                       |
|   package main               |               | 100644 blob f7e8d9... server |
|   ...                        |               +--------------+---------------+
+------------------------------+                              |
                                                              v
                                               +--------------+---------------+
                                               |   Blob Object (f7e8d9)       |
                                               |   (app/server.go)            |
                                               +------------------------------+
```

Git manages four primary object types within the object store:

1. **Blob (`blob`):** Stores raw file data without file metadata, permissions, directory structure, or file names. Two identical files anywhere in the repository point to the exact same blob SHA.
2. **Tree (`tree`):** Represents directory structures. A tree object contains directory entry pointers consisting of POSIX file modes (`100644` for standard files, `100755` for executables, `040000` for sub-directories), object types, SHA hashes, and file/directory names.
3. **Commit (`commit`):** Points to a root tree object, zero or more parent commit SHAs (zero for root commit, one for standard commit, two or more for merge commits), author timestamp, committer timestamp, and commit message.
4. **Annotated Tag (`tag`):** Points to a specific commit SHA (or any object), containing tagger identity, timestamp, GPG signature, and explicit message.

---

### 1.3 Packfiles and Delta Compression
Loose objects are stored as individual zlib-compressed files inside `.git/objects/XX/YYYY...`. As the repository grows, storing thousands of loose files leads to filesystem inode exhaustion and poor I/O performance.

Git addresses this using **Packfiles** (`.pack`) and **Pack Indexes** (`.idx`):
- **Packfile Generation (`git gc` / `git pack-objects`):** Git scans loose objects, groups related objects using sliding window algorithms, and performs directed byte-level delta compression (storing file differences rather than full copies).
- **Pack Indexing:** The `.idx` file provides a binary search offset table mapping SHA hashes directly to byte offsets inside the `.pack` file, enabling $O(1)$ object lookups.

---

### 1.4 Enterprise Scalability, LFS, and SCM Security Architecture
In large enterprise platforms, scale limits manifest when tracking binary artifacts (e.g., machine learning models, database dumps) or operating multi-gigabyte repositories:

- **Git LFS (Large File Storage):** Replaces large binary blobs inside Git commit trees with lightweight pointer files (text files containing `version`, `oid sha256`, and `size`). The actual binary content is transferred via HTTPS/S3 API to an external object store during checkout/push workflows.
- **Server-Side Policy Enforcement:** Enterprise SCM platforms (GitLab, GitHub Enterprise, Gitea) enforce strict compliance using Git server hooks (`pre-receive`, `update`). These hooks parse incoming push operations to enforce signed commits (GPG/SSH), secret scanning prevention, branch protection rules, and semantic commit standards before mutating reference logs (`refs/heads/*`).

---

## 2. Technical Architecture Comparisons & Trade-Off Analysis

### Table 2.1: Centralized SCM vs. Distributed SCM Architecture

| Architectural Dimension | Centralized SCM (Subversion / SVN) | Distributed SCM (Git) |
| :--- | :--- | :--- |
| **Data Storage Topology** | Single central relational/file database server | Fully replicated local DAG on every client node |
| **Commit Operation** | Synchronous network transaction to central server | Local atomic write to local `.git/objects/` DAG |
| **Branching Mechanics** | Copy directory inside central repository tree | Lightweight text file containing 40-char SHA pointer |
| **Branch Creation Latency** | $O(N)$ where $N$ is directory tree scale | $O(1)$ allocation of 41 bytes (40 SHA + newline) |
| **Offline Capability** | Non-existent; status, log, diff require server connection | 100% operation offline except push/fetch |
| **History Integrity** | Server-side database ACL; mutable server history | Immutable SHA-indexed DAG; cryptographic hashing |
| **Storage Efficiency** | Centralized delta storage | Local loose objects + sliding-window delta packfiles |
| **Concurrent Access Limit** | High database lock contention under heavy CI load | Zero local lock contention; lock-free local read/write |

---

### Table 2.2: Git Branch Integration Strategies (Merge vs. Rebase vs. Squash)

| Strategy | Command Pattern | DAG Structure | History Preservation | Rollback & Audit Complexity | Suitable Production Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Non-Fast-Forward Merge** | `git merge --no-ff feature` | Explicit multi-parent merge nodes; dual-line graph | Preserves true chronological history and author context | Clear merge boundaries; simple `git revert -m 1 <SHA>` | Feature branch completion to `main` / `release` |
| **Fast-Forward Merge** | `git merge --ff-only feature` | Linear; target ref advances directly to feature tip | Eliminates branch boundary context completely | Difficult to identify feature boundary for batch revert | Short-lived topic branches with no CI context loss |
| **Interactive Rebase** | `git rebase -i main` | Re-applies commits on new base; creates new SHAs | Rewrites history into a clean linear sequence | Harder to debug chronological production bugs | Local cleanup before opening Pull Requests |
| **Squash Merge** | `git merge --squash feature` | Combines feature branch commits into 1 new commit | Destroys intermediate feature commit history | Single clean commit revert; minimal commit noise | Microservice deployments with strict 1-commit-per-feature |

---

### Table 2.3: Enterprise Repository Topology (Monorepo vs. Polyrepo)

| Metric / Dimension | Monorepo Topology | Polyrepo Topology |
| :--- | :--- | :--- |
| **Dependency Management** | Atomic cross-service refactoring in a single commit | Multi-repository PR orchestration, semantic versioning |
| **CI/CD Build Overhead** | High; requires change detection (Bazel, Nx, Turborepo) | Isolated pipeline execution per service repository |
| **Access Control (RBAC)** | Complex; requires path-based permissions (CODEOWNERS) | Simple; repository-level RBAC and deploy keys |
| **Git Object Store Scale** | Exponential object growth; requires `scalar` / sparse-checkout | Distributed object storage footprint per team |
| **Tooling Requirements** | Git LFS, sparse checkout, Virtual File Systems (VFS) | Standard Git CLI without specialized extensions |

---

### Table 2.4: Git Security & Policy Enforcement Mechanisms

| Enforcement Level | Execution Point | Bypass Potential | Performance Cost | Primary Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **Client-Side Hooks** | `.git/hooks/pre-commit` | High (`git commit --no-verify`) | Executes on local developer CPU | Linting, formatting, local sanity tests |
| **Server Pre-Receive** | `/git-hooks/pre-receive` | Impossible (Server Root enforced) | Blocks `git-receive-pack` push session | GPG verification, Secret scanning, Branch locks |
| **CI/CD Pipeline Gate** | External Worker Runner | Cannot bypass merge protection rules | Asynchronous; decoupled from git push latency | Unit/Integration testing, SAST/DAST scanning |

---

## 3. Complete Infrastructure & Manifest Specifications

### Manifest 3.1: Enterprise HA SCM Stack with Git LFS (Kubernetes Production Spec)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: scm-system
  labels:
    tier: infrastructure
    app.kubernetes.io/name: git-server
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitea-config
  namespace: scm-system
data:
  app.ini: |
    APP_NAME = Enterprise Production SCM Engine
    RUN_MODE = prod
    RUN_USER = git

    [repository]
    ROOT = /data/git/repositories
    DEFAULT_BRANCH = main
    ENABLE_PUSH_CREATE_USER = false
    ENABLE_PUSH_CREATE_ORG = false
    MAX_CREATION_LIMIT = 50
    DEFAULT_PRIVATE = private

    [server]
    PROTOCOL = http
    DOMAIN = git.enterprise.internal
    HTTP_PORT = 3000
    ROOT_URL = https://git.enterprise.internal/
    DISABLE_SSH = false
    SSH_PORT = 2222
    SSH_LISTEN_PORT = 2222
    LFS_START_SERVER = true
    LFS_JWT_SECRET = c7a9e3f1b4d8a2c6e9f1a3b5c7d9e1f3

    [lfs]
    STORAGE_TYPE = minio
    PATH = /data/git/lfs
    MINIO_ENDPOINT = minio.storage.svc.cluster.local:9000
    MINIO_ACCESS_KEY_ID = scm-lfs-admin
    MINIO_SECRET_ACCESS_KEY = SuperSecretEnterpriseLFSKey2026!
    MINIO_BUCKET = git-lfs-objects
    MINIO_LOCATION = us-east-1
    MINIO_USE_SSL = false

    [database]
    DB_TYPE = postgres
    HOST = postgres-ha.database.svc.cluster.local:5432
    NAME = gitea_db
    USER = gitea_user
    PASSWD = SecurePostgresPassword2026!
    SSL_MODE = verify-full

    [security]
    INSTALL_LOCK = true
    SECRET_KEY = e1f3a5b7c9d1e3f5a7b9c1d3e5f7a9b1
    REVERSE_PROXY_TRUSTED_PROXIES = 10.244.0.0/16
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: gitea-scm
  namespace: scm-system
  labels:
    app.kubernetes.io/name: gitea-scm
spec:
  replicas: 1
  serviceName: gitea-scm-headless
  selector:
    matchLabels:
      app.kubernetes.io/name: gitea-scm
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gitea-scm
    spec:
      containers:
        - name: gitea
          image: gitea/gitea:1.21.11
          imagePullPolicy: IfNotPresent
          env:
            - name: USER_UID
              value: "1000"
            - name: USER_GID
              value: "1000"
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
            - name: ssh
              containerPort: 2222
              protocol: TCP
          volumeMounts:
            - name: gitea-data
              mountPath: /data
            - name: config-volume
              mountPath: /data/gitea/conf/app.ini
              subPath: app.ini
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "4"
              memory: 8Gi
          livenessProbe:
            httpGet:
              path: /api/v1/healthz
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /api/v1/healthz
              port: http
            initialDelaySeconds: 15
            periodSeconds: 5
      volumes:
        - name: config-volume
          configMap:
            name: gitea-config
  volumeClaimTemplates:
    - metadata:
        name: gitea-data
      spec:
        accessModes: [ "ReadWriteOnce" ]
        storageClassName: "gp3-encrypted"
        resources:
          requests:
            storage: 200Gi
---
apiVersion: v1
kind: Service
metadata:
  name: gitea-scm-service
  namespace: scm-system
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: 3000
    - name: ssh
      port: 22
      targetPort: 2222
  selector:
    app.kubernetes.io/name: gitea-scm
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea-scm-ingress
  namespace: scm-system
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/proxy-body-size: "512m"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
    - hosts:
        - git.enterprise.internal
      secretName: git-tls-cert
  rules:
    - host: git.enterprise.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitea-scm-service
                port:
                  number: 80
```

---

### Manifest 3.2: Enterprise Git Server Pre-Receive Hook Script (`/git-hooks/pre-receive`)

```bash
#!/usr/bin/env bash
# ==============================================================================
# Production Server-Side Pre-Receive Security & Compliance Hook
# Enforces:
# 1. Blocked Secret Detection (AWS Keys, Private Keys, Generic Tokens)
# 2. Branch Protection (Direct Pushes to 'main' or 'release-*' Forbidden)
# 3. Conventional Commit Message Syntax Compliance
# ==============================================================================

set -euo pipefail

ZERO_REG="0000000000000000000000000000000000000000"
REGEX_AWS_KEY="AKIA[0-9A-Z]{16}"
REGEX_PRIVATE_KEY="-----BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY-----"
REGEX_CONVENTIONAL_COMMIT="^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9_-]+\))?: .+"

exit_code=0

while read -r oldrev newrev refname; do
    # 1. Enforce Protected Branch Rules
    branch_name="${refname#refs/heads/}"
    if [[ "${branch_name}" == "main" || "${branch_name}" =~ ^release-.* ]]; then
        # Allow deletion of branch if explicitly permitted, otherwise block direct push
        if [[ "${newrev}" != "${ZERO_REG}" ]]; then
            # Check if this push is an initial creation or bypass attempt
            echo "[ERROR] [SCM-POLICY] Direct push to protected branch '${branch_name}' is forbidden." >&2
            echo "[ERROR] [SCM-POLICY] You must submit changes via a Pull/Merge Request." >&2
            exit_code=1
            continue
        fi
    fi

    # Skip commit inspection if branch is being deleted
    if [[ "${newrev}" == "${ZERO_REG}" ]]; then
        continue
    fi

    # Determine revision range for commit evaluation
    if [[ "${oldrev}" == "${ZERO_REG}" ]]; then
        # New branch being pushed: check commits relative to main
        commit_range="$(git rev-parse --not main | git rev-list --stdin "${newrev}")"
    else
        commit_range="$(git rev-list "${oldrev}..${newrev}")"
    fi

    # 2. Iterate Over Incoming Commits
    for commit in ${commit_range}; do
        # Extract Commit Message
        commit_msg="$(git log --format=%B -n 1 "${commit}")"
        commit_subject="$(echo "${commit_msg}" | head -n 1)"

        # Validate Conventional Commits Standard
        if [[ ! "${commit_subject}" =~ ${REGEX_CONVENTIONAL_COMMIT} ]]; then
            echo "[ERROR] [SCM-POLICY] Invalid commit message structure in commit ${commit:0:8}." >&2
            echo "[ERROR] [SCM-POLICY] Subject: '${commit_subject}'" >&2
            echo "[ERROR] [SCM-POLICY] Commit message must follow format: type(scope): description" >&2
            exit_code=1
        fi

        # Extract File Changes & Check for Secrets
        changed_files="$(git diff-tree --no-commit-id --name-only -r "${commit}")"
        for file in ${changed_files}; do
            # Skip deleted files inside commit
            if ! git cat-file -e "${commit}:${file}" 2>/dev/null; then
                continue
            fi

            file_content="$(git cat-file -p "${commit}:${file}")"

            # Secret Scan: AWS Access Key ID
            if echo "${file_content}" | grep -E -q "${REGEX_AWS_KEY}"; then
                echo "[FATAL] [SCM-SECURITY] Hardcoded AWS Key detected in commit ${commit:0:8}, file: ${file}" >&2
                exit_code=1
            fi

            # Secret Scan: Private Key Material
            if echo "${file_content}" | grep -E -q "${REGEX_PRIVATE_KEY}"; then
                echo "[FATAL] [SCM-SECURITY] Unencrypted Private Key material detected in commit ${commit:0:8}, file: ${file}" >&2
                exit_code=1
            fi
        done
    done
done

if [[ ${exit_code} -ne 0 ]]; then
    echo "[REJECTED] Push policy violation detected. Transaction aborted." >&2
    exit 1
fi

exit 0
```

---

### Manifest 3.3: Production Repository Configuration Rules (`.gitignore` & `.gitattributes`)

#### File: `.gitignore`
```gitignore
# Operating System Artifacts
.DS_Store
Thumbs.db
*.swp
*.swo

# Infrastructure & Local State Secrets
*.tfstate
*.tfstate.backup
.terraform/
*.pem
*.key
*.pfx
.env
.env.local

# Language Build Output Directories
bin/
obj/
dist/
build/
target/
node_modules/
*.so
*.dylib
*.dll

# IDE & Tooling Directories
.idea/
.vscode/
*.suo
*.user

# Log Files & Crash Dumps
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*
core.[0-9]*
```

#### File: `.gitattributes`
```gitattributes
# Set Default Text Normalization (LF in Repo)
* text=auto eol=lf

# Force Explicit Line Endings for Shell Scripts & Windows Batches
*.sh text eol=lf
*.bat text eol=crlf
*.cmd text eol=crlf

# Git LFS Binary Asset Mapping
*.png filter=lfs diff=lfs merge=lfs -text
*.jpg filter=lfs diff=lfs merge=lfs -text
*.mp4 filter=lfs diff=lfs merge=lfs -text
*.iso filter=lfs diff=lfs merge=lfs -text
*.tar.gz filter=lfs diff=lfs merge=lfs -text
*.onnx filter=lfs diff=lfs merge=lfs -text
*.tflite filter=lfs diff=lfs merge=lfs -text

# Linguist & Custom Merge Driver Overrides
docs/* linguist-documentation
vendor/* linguist-vendored
package-lock.json merge=binary
```

---

## 4. Real CLI Execution, Internal Plumbing, & Terminal Output

### 4.1 Low-Level Git Object Mechanics (Creating a Commit Manually via Plumbing)
This walkthrough demonstrates the underlying mechanics of Git object storage by manually constructing a Blob, Tree, and Commit object using Git plumbing commands, bypassing `git add` and `git commit`.

```bash
$ mkdir /tmp/git-plumbing-lab && cd /tmp/git-plumbing-lab
$ git init
Initialized empty Git repository in /tmp/git-plumbing-lab/.git/

$ # Step 1: Create a Blob object directly in .git/objects
$ echo "package main; func main() { println(\"SRE Core v1\") }" | git hash-object -w --stdin
e2380d381ae516c141fa168a9b6c0032b4bfa254

$ # Step 2: Verify the object type and content in the database
$ git cat-file -t e2380d381ae516c141fa168a9b6c0032b4bfa254
blob

$ git cat-file -p e2380d381ae516c141fa168a9b6c0032b4bfa254
package main; func main() { println("SRE Core v1") }

$ # Step 3: Write the Blob into the Staging Index with permissions (100644)
$ git update-index --add --cacheinfo 100644 e2380d381ae516c141fa168a9b6c0032b4bfa254 main.go

$ # Step 4: Write the Staging Index into a Tree Object
$ git write-tree
9b8e217d848149e9e1c142c16182ef89fb6c08bc

$ git cat-file -p 9b8e217d848149e9e1c142c16182ef89fb6c08bc
100644 blob e2380d381ae516c141fa168a9b6c0032b4bfa254	main.go

$ # Step 5: Construct a Commit Object referencing the Tree SHA
$ COMMIT_SHA=$(echo "feat(core): initial manual plumbing commit" | git commit-tree 9b8e217d848149e9e1c142c16182ef89fb6c08bc)
$ echo ${COMMIT_SHA}
a5c89f1d02e49c81b2a731d1029e84b3f11a8c9e

$ git cat-file -p ${COMMIT_SHA}
tree 9b8e217d848149e9e1c142c16182ef89fb6c08bc
author SRE Admin <sre@company.internal> 1775536920 -0400
committer SRE Admin <sre@company.internal> 1775536920 -0400

feat(core): initial manual plumbing commit

$ # Step 6: Update the HEAD reference pointer to the new Commit SHA
$ git update-ref refs/heads/main ${COMMIT_SHA}
$ git log -n 1
commit a5c89f1d02e49c81b2a731d1029e84b3f11a8c9e (HEAD -> main)
Author: SRE Admin <sre@company.internal>
Date:   Tue Aug 7 04:42:00 2026 -0400

    feat(core): initial manual plumbing commit
```

---

### 4.2 Advanced Worktree Isolation (Multi-Branch Engineering)
`git worktree` allows linking multiple working trees to a single shared `.git` object database, eliminating full local re-cloning when switching between hotfix branches and long-running feature branches.

```bash
$ cd /tmp/git-plumbing-lab
$ git branch feature/auth
$ git branch hotfix/vuln-patch

$ # Create a dedicated workspace directory for hotfix development
$ git worktree add ../hotfix-workspace hotfix/vuln-patch
Preparing worktree (checking out 'hotfix/vuln-patch')
HEAD is now at a5c89f1 feat(core): initial manual plumbing commit

$ git worktree list
/tmp/git-plumbing-lab   a5c89f1 [main]
/tmp/hotfix-workspace   a5c89f1 [hotfix/vuln-patch]

$ # Remove worktree after work completion
$ git worktree remove ../hotfix-workspace
$ git worktree list
/tmp/git-plumbing-lab   a5c89f1 [main]
```

---

### 4.3 Automated Fault Localization (`git bisect`)
`git bisect` uses a binary search algorithm across commit history to isolate the exact commit that introduced a software regression.

```bash
$ cd /tmp/git-plumbing-lab
$ # Initiate bisect session
$ git bisect start
$ git bisect bad HEAD                                  # Mark current HEAD as broken
$ git bisect good a5c89f1d02e49c81b2a731d1029e84b3f11a # Mark known good historical SHA
Bisecting: 12 revisions left to test after this (roughly 4 steps)
[3f8a9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a] feat(api): update handler payload

$ # Run automated script test runner over bisect range
$ git bisect run go test -run TestProductionRegression ./...
running go test -run TestProductionRegression ./...
...
3f8a9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a is the first bad commit
commit 3f8a9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a
Author: Dev <dev@company.com>
Date:   Mon Aug 6 14:22:10 2026 -0400

    feat(api): update handler payload

Bisect run success.
$ git bisect reset
Previous HEAD position was 3f8a9b2 feat(api): update handler payload
HEAD is now at a5c89f1 feat(core): initial manual plumbing commit
```

---

## 5. SRE Diagnostic, Failure Recovery, & Maintenance Guide

### Diagnostic Matrix: Production Failure Scenarios & Troubleshooting Paths

```
                             Production Failure Symptoms Detected
                                              |
      +---------------------------------------+---------------------------------------+
      |                                       |                                       |
      v                                       v                                       v
[ Fatal: Corrupt Object ]            [ Head Detached / Lost ]              [ Repository Bloat ]
  - Object SHA mismatched              - Untracked local commits             - Push rejected (>100MB)
  - Loose object zero bytes            - Accidental rebase/reset             - Object store > 10GB
      |                                       |                                       |
      v                                       v                                       v
Run `git fsck --full`               Run `git reflog`                       Run `git-filter-repo`
Check `.git/objects/pack`           Locate last valid SHA                  Remove heavy binary SHAs
Restore from remote mirror          Run `git branch recover <SHA>`         Run `git gc --prune=now`
```

---

### Failure Scenario 5.1: Object Database Corruption Recovery
**Symptom:** `git log` or `git checkout` fails with `error: inflate: data stream error (incorrect header check)` or `fatal: loose object ... is corrupt`.

#### Diagnostic Sequence:
```bash
$ # Step 1: Perform full strict integrity check across all loose and packed objects
$ git fsck --full --strict
error: sha1 mismatch 6b8b4567000e47c3ab37b65c362ba92c8d8d1cfc
error: 6b8b4567000e47c3ab37b65c362ba92c8d8d1cfc: object corrupt or missing
dangling blob 9f8a7c6b5a4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c

$ # Step 2: Locate corrupt loose object file in filesystem
$ find .git/objects/ -type f -empty
.git/objects/6b/8b4567000e47c3ab37b65c362ba92c8d8d1cfc

$ # Step 3: Remove zero-byte / corrupt object
$ rm -f .git/objects/6b/8b4567000e47c3ab37b65c362ba92c8d8d1cfc

$ # Step 4: Fetch missing object directly from upstream authoritative mirror
$ git fetch origin --force
remote: Enumerating objects: 1, done.
remote: Counting objects: 100% (1/1), done.
Unpacking objects: 100% (1/1), 240 bytes | 240.00 KiB/s, done.
From https://git.enterprise.internal/scm/repo
 * [new branch]      main       -> origin/main

$ # Step 5: Verify DAG consistency post-recovery
$ git fsck --full
Notice: Unreachable dangling blob 9f8a7c6b5a4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c
Checking object directories: 100% (256/256), done.
Checking objects: 100% (1420/1420), done.
```

---

### Failure Scenario 5.2: Recovering Lost Commits (Reflog Analysis)
**Symptom:** A developer accidentally executes `git reset --hard HEAD~5` or `git rebase`, losing critical unmerged feature commits.

#### Diagnostic Sequence:
```bash
$ # Step 1: Inspect execution reflog to identify state prior to reset
$ git reflog --date=iso
a5c89f1 HEAD@{2026-08-07 04:20:00 -0400}: reset: moving to HEAD~5
e9f8a7b HEAD@{2026-08-07 04:15:12 -0400}: commit: feat(auth): finalize OAuth2 implementation
8c7b6a5 HEAD@{2026-08-07 04:02:00 -0400}: commit: feat(auth): add PKCE generator

$ # Step 2: Create a recovery branch directly targeting lost commit SHA (e9f8a7b)
$ git checkout -b recovery/lost-oauth-feature e9f8a7b
Switched to a new branch 'recovery/lost-oauth-feature'
HEAD is now at e9f8a7b feat(auth): finalize OAuth2 implementation

$ # Step 3: Verify restored state
$ git log -n 2 --oneline
e9f8a7b (HEAD -> recovery/lost-oauth-feature) feat(auth): finalize OAuth2 implementation
8c7b6a5 feat(auth): add PKCE generator
```

---

### Failure Scenario 5.3: Repository Debloating (Purging Large Accidental Binary Files)
**Symptom:** A 500MB zip file was committed 100 commits ago. The file was deleted in a recent commit, but `.git/objects/pack` remains bloated at >500MB because the object remains referenced in historical commit trees.

#### Remediation Sequence:
```bash
$ # Step 1: Identify heavy objects inside packfiles
$ git verify-pack -v .git/objects/pack/pack-*.idx | sort -k3 -n -r | head -n 5
c1f8a9e2d3b4a5c6d7e8f9a0b1c2d3e4f5a6b7c8 blob 524288000 384021000 120490

$ # Step 2: Find file paths associated with the identified heavy SHA
$ git rev-list --objects --all | grep c1f8a9e2d3b4a5c6d7e8f9a0b1c2d3e4f5a6b7c8
c1f8a9e2d3b4a5c6d7e8f9a0b1c2d3e4f5a6b7c8 storage/db_dump.tar.gz

$ # Step 3: Purge file completely from all historical DAG commit trees using git-filter-repo
$ git-filter-repo --invert-paths --path storage/db_dump.tar.gz
Parsed 1420 commits
New history written in 3.12 seconds.

$ # Step 4: Expire reflogs, prune loose unreferenced objects, and rebuild packfiles
$ git reflog expire --expire=now --all
$ git gc --prune=now --aggressive
Enumerating objects: 910, done.
Counting objects: 100% (910/910), done.
Delta compression using up to 8 threads
Compressing objects: 100% (420/420), done.
Writing objects: 100% (910/910), done.
Total 910 (delta 490), reused 0 (delta 0), pack-reused 0

$ # Step 5: Force push sanitized history to remote authority
$ git push origin --force --all
```

---

## 6. References

- **Linux Professional Institute (LPI) DevOps Tools Engineer Objectives:**  
  https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
- **LPI Wiki — Topic 701.3 Source Code Management Details:**  
  https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0
- **Git Official Internal Documentation (Pro Git - Git Internals):**  
  https://git-scm.com/book/en/v2/Git-Internals-Plumbing-and-Porcelain
- **Git Mechanics: Packfiles and Index Files Standard Specification:**  
  https://git-scm.com/docs/pack-format
- **Git Large File Storage (LFS) Architecture Specification:**  
  https://git-lfs.com/
- **CNCF GitOps Principles & OpenGitOps Standard:**  
  https://opengitops.dev/