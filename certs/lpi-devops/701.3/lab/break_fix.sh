#!/bin/bash
# ==============================================================================
# LPI DevOps Tools Engineer (701-100) - Topic 1.3: Source Code Management
# LAB BREAK & FIX: Troubleshooting Git Hooks, Refspecs, & Submodules
# ==============================================================================
# Official Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# Target Topic: 1.3 Source Code Management (Weight: 8.33)
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_devops_scm_lab"

echo "[+] Initializing disposable lab environment at ${LAB_DIR}..."
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/upstream/core-lib.git"
mkdir -p "${LAB_DIR}/upstream/app-repo.git"
mkdir -p "${LAB_DIR}/developer"

# 1. Setup Bare Upstream Repositories
git init --bare --initial-branch=main "${LAB_DIR}/upstream/core-lib.git" > /dev/null
git init --bare --initial-branch=main "${LAB_DIR}/upstream/app-repo.git" > /dev/null

# Populate core-lib upstream repository
TMP_CORE=$(mktemp -d)
git init --initial-branch=main "${TMP_CORE}" > /dev/null
cd "${TMP_CORE}"
git config user.name "CI System"
git config user.email "ci@company.internal"
echo "v1.0.0" > VERSION
git add VERSION
git commit -m "feat: initial core-lib release" > /dev/null
git remote add origin "${LAB_DIR}/upstream/core-lib.git"
git push origin main > /dev/null
rm -rf "${TMP_CORE}"

# Populate app-repo upstream repository with submodule
TMP_APP=$(mktemp -d)
git init --initial-branch=main "${TMP_APP}" > /dev/null
cd "${TMP_APP}"
git config user.name "CI System"
git config user.email "ci@company.internal"
echo "print('App Service Active')" > main.py
git add main.py
git commit -m "feat: initial app service layout" > /dev/null

# Add submodule referencing core-lib
git submodule add "${LAB_DIR}/upstream/core-lib.git" libs/core-lib > /dev/null
git commit -m "chore: integrate core-lib dependency submodule" > /dev/null
git remote add origin "${LAB_DIR}/upstream/app-repo.git"
git push origin main > /dev/null
rm -rf "${TMP_APP}"

# 2. Setup Developer Working Copy & Inject Deliberate Enterprise Breakages
cd "${LAB_DIR}/developer"
git clone "${LAB_DIR}/upstream/app-repo.git" app-repo > /dev/null 2>&1
cd app-repo

git config user.name "Senior SRE Engineer"
git config user.email "sre@company.internal"

# Failure 1: Custom git hook directory configured with bash syntax error & policy blocks
mkdir -p .githooks
cat << 'EOF' > .githooks/pre-push
#!/bin/bash
echo "[HOOK] Executing Enterprise Pre-Push Validation..."
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
    echo "[HOOK ERROR] Detached HEAD state detected! Push blocked by SRE policy." >&2
    exit 1
fi
if [ -f "main.py" ];
    echo "[HOOK] Validating Python syntax..."
    python3 -m py_compile main.py || exit 1
fi
exit 0
EOF
chmod +x .githooks/pre-push
git config core.hooksPath .githooks

# Failure 2: Corrupt submodule endpoint in .gitmodules
sed -i "s|core-lib.git|core-lib-unreachable-path.git|g" .gitmodules
git add .gitmodules
git commit -m "refactor: update dependency pointer" > /dev/null

# Failure 3: Malformed fetch refspec in repository configuration
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/invalid_namespace/*"

# Failure 4: Detach HEAD state with uncommitted hotfix staged in index
git checkout --detach HEAD > /dev/null 2>&1
echo "# Critical hotfix change" >> main.py
git add main.py

echo ""
echo "========================================================================"
echo "                LPI DEVOPS (701-100) - TOPIC 1.3 LAB BREAK"
echo "========================================================================"
echo "STATUS: Lab environment initialized with 4 production failure states."
echo "LOCATION: ${LAB_DIR}/developer/app-repo"
echo ""
echo "SYMPTOMS OBSERVED BY DEVELOPER / CI PIPELINE:"
echo " 1. 'git push origin main' fails immediately with syntax error from pre-push hook."
echo " 2. 'git submodule update --init --recursive' fails to fetch the upstream dependency."
echo " 3. 'git fetch origin' creates broken tracking refs in invalid_namespace/*."
echo " 4. 'git status' shows repository stuck in a 'Detached HEAD' state with staged changes."
echo ""
echo "OBJECTIVES TO REPAIR THE ENVIRONMENT:"
echo " [ ] Fix the script syntax error in .githooks/pre-push."
echo " [ ] Re-attach work to the 'main' branch without losing staged hotfix changes."
echo " [ ] Repair the submodule URL in .gitmodules and update local submodule objects."
echo " [ ] Restore standard fetch refspec for origin remote (+refs/heads/*:refs/remotes/origin/*)."
echo " [ ] Successfully execute 'git push origin main' and achieve clean 'git status'."
echo "========================================================================"
echo ""

# ==============================================================================
# STEP-BY-STEP SOLUTION (EXAM STUDY REFERENCE):
# ==============================================================================
#
# STEP 1: Fix Bash syntax error in custom pre-push hook
# ------------------------------------------------------------------------------
# Inspect `.githooks/pre-push`. Line 9 is missing `then` after the semicolon:
#
# Incorrect syntax:
#   if [ -f "main.py" ];
#       echo "[HOOK] Validating Python syntax..."
#
# Correct syntax:
#   if [ -f "main.py" ]; then
#       echo "[HOOK] Validating Python syntax..."
#   fi
#
# STEP 2: Recover from Detached HEAD state without losing staged changes
# ------------------------------------------------------------------------------
# 1. Commit the staged hotfix on the detached HEAD:
#      git commit -m "fix: apply critical hotfix to main.py"
#
# 2. Switch back to main branch and merge the detached commit:
#      git checkout main
#      git merge HEAD@{1}
#
# STEP 3: Repair broken submodule URL and update tracking refs
# ------------------------------------------------------------------------------
# 1. Edit `.gitmodules` and update the URL to point back to valid upstream path:
#      url = /tmp/lpi_devops_scm_lab/upstream/core-lib.git
#
# 2. Sync the updated configuration to `.git/config` and initialize submodule:
#      git submodule sync
#      git submodule update --init --recursive
#      git add .gitmodules
#      git commit -m "fix: restore valid submodule upstream URL"
#
# STEP 4: Restore correct Git Fetch Refspec
# ------------------------------------------------------------------------------
# Reset the fetch refspec for remote 'origin' back to standard layout:
#
#   git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
#
# Verify configuration in `.git/config`:
#   git config --get remote.origin.fetch
#
# STEP 5: Verification & Push to Upstream
# ------------------------------------------------------------------------------
# 1. Fetch remote references to verify refspec resolution:
#      git fetch origin
#
# 2. Push local commits to upstream repository (triggers fixed pre-push hook):
#      git push origin main
#
# 3. Verify clean state across repository and submodules:
#      git status
#      git submodule status
# ==============================================================================