#!/bin/bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 6.2: Source Code Management (Weight: 7.5)
# Production Break & Fix Exercise: Git Reference Corruption & Index Lock Recovery
#
# Author: Senior SRE & Principal Platform Architect
# Official Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# Additional References:
#   - Git Internals - Git Objects: https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
#   - Git Maintenance & Data Recovery: https://git-scm.com/book/en/v2/Git-Internals-Maintenance-and-Data-Recovery
#   - Git fsck documentation: https://git-scm.com/docs/git-fsck
#   - Git reflog documentation: https://git-scm.com/docs/git-reflog
# ==============================================================================

set -euo pipefail

LAB_DIR="${HOME}/lpi_scm_breakfix_lab"

echo "======================================================================"
echo " [SETUP] Initializing LPI 050-100 Topic 6.2 Break & Fix Laboratory"
echo " Target Path: ${LAB_DIR}"
echo "======================================================================"

# Clean up previous lab workspace if present
if [ -d "${LAB_DIR}" ]; then
    rm -rf "${LAB_DIR}"
fi

mkdir -p "${LAB_DIR}"
cd "${LAB_DIR}"

# Step 1: Initialize Git Repository and build version history
git init -q
git config user.name "SRE Pipeline Agent"
git config user.email "sre-agent@production.internal"

echo "v1.0.0 microservice code" > app.py
echo "# Production Microservice" > README.md
git add app.py README.md
git commit -q -m "feat: initial commit v1.0.0"
COMMIT_1=$(git rev-parse HEAD)

echo "v1.1.0 updated business logic" > app.py
echo "port: 8080" > config.yaml
git add app.py config.yaml
git commit -q -m "feat: upgrade microservice to v1.1.0 with config"
COMMIT_2=$(git rev-parse HEAD)

echo "v1.2.0 emergency security fix" > app.py
git add app.py
git commit -q -m "feat: emergency security patch v1.2.0"
COMMIT_3=$(git rev-parse HEAD)

# Determine active branch name (main or master)
CURRENT_BRANCH=$(git symbolic-ref --short HEAD)

# Step 2: Inject Controlled Production Faults
# Fault 1: Create index.lock to simulate interrupted process / abrupt crash during git write
touch .git/index.lock

# Fault 2: Corrupt branch ref file (simulate disk write truncation or storage corruption)
> ".git/refs/heads/${CURRENT_BRANCH}"

echo ""
echo "======================================================================"
echo " [BROKEN STATE INJECTED SUCCESSFULLY]"
echo "======================================================================"
echo ""
echo "INCIDENT REPORT:"
echo "----------------"
echo "During an automated deployment run on a worker node, a power outage"
echo "abruptly killed the running Git process while updating branch references."
echo "Subsequent CI/CD jobs and developer commands are failing completely."
echo ""
echo "SYMPTOMS OBSERVED:"
echo "1. Every Git modification command (git status, git add, git commit) fails"
echo "   complaining about a locked index file (.git/index.lock)."
echo "2. Git reports that HEAD ref is corrupted or unresolvable ('fatal: bad ref for HEAD')."
echo "3. Branch references (.git/refs/heads/${CURRENT_BRANCH}) have zero length."
echo ""
echo "YOUR OBJECTIVES:"
echo "1. Inspect Git internal directory structure (.git/) to understand the lock."
echo "2. Safely release the index lock without destroying working directory files."
echo "3. Locate the latest valid commit hash (${COMMIT_3:0:7}) using Git low-level tools"
echo "   (reflog logs under .git/logs/ or object store inspection via git fsck)."
echo "4. Restore '.git/refs/heads/${CURRENT_BRANCH}' to point to the valid tip commit."
echo "5. Verify repository health using 'git status', 'git log', and 'git fsck'."
echo ""
echo "Lab Directory Path: ${LAB_DIR}"
echo "To start troubleshooting, run: cd ${LAB_DIR} && git status"
echo "======================================================================"
exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (FOR INSTRUCTOR / STUDENT)
# ==============================================================================
#
# UNDERSTANDING GIT ARCHITECTURE & MECHANICS:
# --------------------------------------------
# Git relies on a simple, robust low-level storage architecture inside `.git/`:
# 1. Objects (`.git/objects/`): Immutable DAG storing Blobs, Trees, Commits, Tags.
# 2. References (`.git/refs/`): Simple text files containing 40-character SHA hashes.
#    - `.git/HEAD`: Contains `ref: refs/heads/<branch>` pointing to active branch.
#    - `.git/refs/heads/<branch>`: Stores the commit hash of the branch tip.
# 3. Index File (`.git/index`): Binary staging area tracking working directory tree.
#    - `.git/index.lock`: Atomic lock file created during write transactions. If a process
#      crashes mid-operation, the lock file remains orphaned, blocking future operations.
# 4. Reflogs (`.git/logs/`): Audit log recording history of HEAD and branch ref updates.
#
# RECOVERY PROCEDURE:
# -------------------
#
# STEP 1: Reproduce & verify the index lock error
#   Command:
#     cd ~/lpi_scm_breakfix_lab
#     git status
#   Output:
#     fatal: Unable to create '/.../lpi_scm_breakfix_lab/.git/index.lock': File exists.
#
# STEP 2: Clear the orphaned index lock file
#   Command:
#     rm -f .git/index.lock
#   Explanation:
#     Deleting `.git/index.lock` frees the repository write lock mutex.
#
# STEP 3: Inspect ref corruption error
#   Command:
#     git status
#   Output:
#     fatal: bad ref for 'HEAD'
#
# STEP 4: Inspect `.git/HEAD` and `.git/refs/heads/`
#   Command:
#     cat .git/HEAD
#   Output:
#     ref: refs/heads/main
#
#   Command:
#     cat .git/refs/heads/main
#   Output:
#     (0 bytes / empty output)
#
# STEP 5: Recover tip commit hash from Reflog or Object Database
#   Method A (Direct Reflog Inspection):
#     cat .git/logs/refs/heads/main | tail -n 1
#     OR
#     cat .git/logs/HEAD | tail -n 1
#   Expected Output snippet:
#     0000000000000000000000000000000000000000 <commit_hash> SRE Pipeline Agent ... commit: feat: emergency security patch v1.2.0
#
#   Method B (Git Filesystem Check):
#     git fsck --full
#   Expected Output snippet:
#     dangling commit <commit_hash>
#
# STEP 6: Repair the branch reference pointer
#   Command (Recommended plumbing command):
#     git update-ref refs/heads/main <recovered_commit_hash>
#   OR (Direct ref writing):
#     echo "<recovered_commit_hash>" > .git/refs/heads/main
#
# STEP 7: Verify workspace state and object integrity
#   Command:
#     git status
#   Output:
#     On branch main
#     nothing to commit, working tree clean
#
#   Command:
#     git log --oneline -n 3
#   Output:
#     <hash> feat: emergency security patch v1.2.0
#     <hash> feat: upgrade microservice to v1.1.0 with config
#     <hash> feat: initial commit v1.0.0
#
#   Command:
#     git fsck --full
#   Output:
#     Checking object directories: 100% (256/256), done.
#
# ==============================================================================