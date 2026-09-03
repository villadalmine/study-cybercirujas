#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
# Topic 1.4: Continuous Integration and Continuous Delivery (Weight: 8.34)
# Production-Grade "Break & Fix" Hands-On Laboratory Script
#
# Official Reference URLs:
# - https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# - https://wiki.lpi.org/wiki/LPIC-OT_DevOps_Tools_Engineer_Objectives_V1.0
#
# Author: Senior SRE & Principal Platform Architect
# Target OS: Ubuntu 22.04 LTS / Debian 12 / RHEL 9 (Disposable Lab VM)
# ==============================================================================

set -euo pipefail

# Color Codes for CLI Diagnostics Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LOG_PREFIX="${CYAN}[CI/CD LAB SETUP]${NC}"

# Check for root permissions
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}ERROR: This lab script must be executed as root to configure users, systemd services, and file ACLs.${NC}" >&2
    exit 1
fi

echo -e "${LOG_PREFIX} Initializing LPI DevOps 701-100 Topic 1.4 Production Scenario..."

# ------------------------------------------------------------------------------
# LAB ENVIRONMENT SETUP: Mock Enterprise CI/CD Pipeline
# ------------------------------------------------------------------------------

LAB_DIR="/opt/production-cicd"
ARTIFACT_DIR="/var/opt/ci-artifacts"
RUNNER_USER="ci-runner"
RUNNER_GROUP="ci-runner"
SERVICE_NAME="enterprise-ci-agent"

echo -e "${LOG_PREFIX} Creating unprivileged CI/CD execution service user (${RUNNER_USER})..."
if ! id -u "${RUNNER_USER}" &>/dev/null; then
    useradd --system --shell /bin/bash --home-dir "${LAB_DIR}" "${RUNNER_USER}"
fi

echo -e "${LOG_PREFIX} Provisioning lab directory structure at ${LAB_DIR}..."
mkdir -p "${LAB_DIR}/repo.git"
mkdir -p "${LAB_DIR}/workspace"
mkdir -p "${LAB_DIR}/bin"
mkdir -p "${LAB_DIR}/config"
mkdir -p "${ARTIFACT_DIR}/v1.0.0"

# Initialize a bare Git repository representing the production upstream
git init --bare "${LAB_DIR}/repo.git" &>/dev/null

# Clone repository into workspace
rm -rf "${LAB_DIR}/workspace/app"
git clone "${LAB_DIR}/repo.git" "${LAB_DIR}/workspace/app" &>/dev/null

# Populate sample application code and pipeline manifest
cd "${LAB_DIR}/workspace/app"
git config user.name "CI System"
git config user.email "ci@internal.domain"

cat << 'EOF' > main.go
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "OK - Pipeline Release v1.0.0\n")
	})
	http.ListenAndServe(":8080", nil)
}
EOF

cat << 'EOF' > pipeline.env
APP_NAME="core-api-service"
BUILD_TARGET="main.go"
RELEASE_VERSION="1.0.0"
CHECKSUM_ALGO="sha256sum"
ENABLE_ARTIFACT_SIGNING="true"
PUBLISH_ENDPOINT="http://localhost:8081/artifactory/generic-local"
EOF

git add main.go pipeline.env
git commit -m "feat(core): initialize application code and pipeline configuration" &>/dev/null
git push origin master &>/dev/null || git push origin main &>/dev/null

# Create the CI Pipeline Runner Engine script
cat << 'EOF' > "${LAB_DIR}/bin/runner-engine.sh"
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/opt/production-cicd/workspace/app"
ARTIFACT_STORE="/var/opt/ci-artifacts"
CONFIG_FILE="${WORKSPACE}/pipeline.env"

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] === STARTING CI/CD PIPELINE EXECUTION ==="

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[ERROR] Pipeline configuration file missing at ${CONFIG_FILE}" >&2
    exit 1
fi

source "${CONFIG_FILE}"

echo "[STAGE: 1/4 - FETCH CODE & VALIDATE ENVIRONMENT]"
echo "Sanity checking build tools in PATH: ${PATH}"
if ! command -v git &>/dev/null; then
    echo "[ERROR] 'git' utility not found in PATH." >&2
    exit 127
fi

cd "${WORKSPACE}"
git pull origin main &>/dev/null || git pull origin master &>/dev/null

echo "[STAGE: 2/4 - COMPILE & TEST ARTIFACT]"
BUILD_TIME=$(date +%s)
ARTIFACT_NAME="${APP_NAME}-${RELEASE_VERSION}-${BUILD_TIME}.tar.gz"
TEMP_BUILD_DIR=$(mktemp -d)

cp main.go "${TEMP_BUILD_DIR}/"
tar -czf "${TEMP_BUILD_DIR}/${ARTIFACT_NAME}" -C "${TEMP_BUILD_DIR}" main.go

echo "[STAGE: 3/4 - GENERATE INTEGRITY CHECKSUM]"
if ! command -v "${CHECKSUM_ALGO}" &>/dev/null; then
    echo "[ERROR] Configured hashing algorithm tool '${CHECKSUM_ALGO}' was not found or is invalid." >&2
    exit 2
fi

cd "${TEMP_BUILD_DIR}"
"${CHECKSUM_ALGO}" "${ARTIFACT_NAME}" > "${ARTIFACT_NAME}.sha256"

echo "[STAGE: 4/4 - PUBLISH TO ARTIFACT REPOSITORY]"
TARGET_DEST="${ARTIFACT_STORE}/v${RELEASE_VERSION}"

if [[ ! -d "${TARGET_DEST}" ]]; then
    echo "[ERROR] Target publication directory ${TARGET_DEST} does not exist." >&2
    exit 3
fi

echo "Copying release artifacts to ${TARGET_DEST}..."
cp "${TEMP_BUILD_DIR}/${ARTIFACT_NAME}" "${TARGET_DEST}/"
cp "${TEMP_BUILD_DIR}/${ARTIFACT_NAME}.sha256" "${TARGET_DEST}/"

rm -rf "${TEMP_BUILD_DIR}"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] === PIPELINE SUCCESS: Release v${RELEASE_VERSION} Published ==="
EOF

chmod +x "${LAB_DIR}/bin/runner-engine.sh"

# Create Systemd Service for CI Runner Daemon
cat << EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=LPI DevOps 701-100 Mock Enterprise CI/CD Runner Agent
After=network.target

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_GROUP}
WorkingDirectory=${LAB_DIR}
Environment="PATH=/usr/bin:/bin"
ExecStart=/bin/bash ${LAB_DIR}/bin/runner-engine.sh
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ------------------------------------------------------------------------------
# FAULT INJECTION (Controlled Degradation of CI/CD Pipeline)
# ------------------------------------------------------------------------------

echo -e "${LOG_PREFIX} Injecting production misconfigurations..."

# Fault 1: Systemd Service restricted PATH variable excluding required checksum binaries (/usr/local/bin, /usr/bin)
# Modifying service environment path to an incomplete path
sed -i 's|Environment="PATH=/usr/bin:/bin"|Environment="PATH=/usr/local/sbin:/sbin"|g' /etc/systemd/system/${SERVICE_NAME}.service

# Fault 2: File System ACL / Ownership mismatch on persistent Artifact Storage
# Changing ownership of /var/opt/ci-artifacts to root with strict 0700 permissions
chown -R root:root "${ARTIFACT_DIR}"
chmod -R 0700 "${ARTIFACT_DIR}"

# Fault 3: Pipeline manifest misconfiguration (Invalid hashing binary string in environment config)
sed -i 's|CHECKSUM_ALGO="sha256sum"|CHECKSUM_ALGO="sha256sum_invalid_binary"|g' "${LAB_DIR}/workspace/app/pipeline.env"

systemctl daemon-reload
systemctl restart ${SERVICE_NAME}.service || true

# ------------------------------------------------------------------------------
# INSTRUCTIONS & SYMPTOMS DISPLAY
# ------------------------------------------------------------------------------

clear
echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}  LPI DEVOPS TOOLS ENGINEER (701-100) - TOPIC 1.4 BREAK & FIX LAB          ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""
echo -e "${YELLOW}[SCENARIO DESCRIPTION]${NC}"
echo "You are an On-Call SRE. The automated CI/CD build agent (${SERVICE_NAME}) fails"
echo "to execute the release pipeline for core-api-service. Developers report that"
echo "builds are crashing during stages 1, 3, and 4."
echo ""
echo -e "${YELLOW}[OBSERVED SYMPTOMS]${NC}"
echo "1. Systemd service '${SERVICE_NAME}' enters a CrashLoopBackOff/Failed state."
echo "2. CI/CD logs report binary lookup failures, permissions errors, and hash mismatches."
echo "3. Artifacts fail to persist to the centralized storage location (/var/opt/ci-artifacts)."
echo ""
echo -e "${YELLOW}[YOUR OBJECTIVES]${NC}"
echo "1. Inspect systemd journal logs and identify why the execution engine fails."
echo "2. Fix the service PATH configuration without compromising system security principles."
echo "3. Resolve file permissions/ACL issues on the artifact store to allow '${RUNNER_USER}' write access."
echo "4. Correct the invalid configuration parameter in the pipeline source repository."
echo "5. Verify successful execution by obtaining a clean exit code (0) from the systemd service."
echo ""
echo -e "${CYAN}[USEFUL DIAGNOSTIC COMMANDS]${NC}"
echo "  - systemctl status ${SERVICE_NAME}.service"
echo "  - journalctl -u ${SERVICE_NAME}.service -n 50 --no-pager"
echo "  - ls -ld ${ARTIFACT_DIR}"
echo "  - cat ${LAB_DIR}/workspace/app/pipeline.env"
echo "  - sudo -u ${RUNNER_USER} ${LAB_DIR}/bin/runner-engine.sh"
echo ""
echo -e "${RED}Do NOT remove the user '${RUNNER_USER}' or run the agent as 'root'!${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""

exit 0

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (FOR INSTRUCTOR / STUDENT)
# ==============================================================================
#
# TECHNICAL ARCHITECTURE & DEEP DIVE:
# In modern CI/CD architectures (Jenkins Agents, GitLab Runners, GitHub Actions Runners),
# pipeline workers execute unprivileged under dedicated service accounts to mitigate
# Remote Code Execution (RCE) vectors via malicious pull requests. 
# Common failure modes in CI/CD infrastructure include:
# 1. Environment Sanitization: Systemd service units stripping critical PATH environment
#    variables required for build toolchains (git, sha256sum, docker, helm).
# 2. Storage Permissions Mismatches: Shared network mounts or local storage locations
#    restricted to root, blocking build agents from publishing release artifacts.
# 3. Pipeline Configuration Drift: Incorrect build manifests checked into source control
#    referencing non-existent tools or algorithms.
#
# ------------------------------------------------------------------------------
# TROUBLESHOOTING & REPAIR STEPS:
# ------------------------------------------------------------------------------
#
# STEP 1: Analyze Systemd Service Logs
#   Execute journalctl to read the runtime output of the failing service:
#
#   $ sudo journalctl -u enterprise-ci-agent.service -n 30 --no-pager
#
#   Expected Log Snippet:
#   [STAGE: 1/4 - FETCH CODE & VALIDATE ENVIRONMENT]
#   Sanity checking build tools in PATH: /usr/local/sbin:/sbin
#   [ERROR] 'git' utility not found in PATH.
#
#   Root Cause: The systemd unit file (/etc/systemd/system/enterprise-ci-agent.service)
#   defines Environment="PATH=/usr/local/sbin:/sbin", which omits /usr/bin where standard
#   binaries like git and sha256sum reside.
#
# STEP 2: Fix Systemd Service Environment PATH
#   Edit the systemd service file:
#
#   $ sudo nano /etc/systemd/system/enterprise-ci-agent.service
#
#   Update line:
#   Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
#
#   Reload systemd daemon:
#   $ sudo systemctl daemon-reload
#
# STEP 3: Diagnose Second Pipeline Failure (Checksum Tool & Artifact Storage)
#   Test run the script or inspect logs again:
#
#   $ sudo systemctl restart enterprise-ci-agent.service
#   $ sudo journalctl -u enterprise-ci-agent.service -n 30 --no-pager
#
#   Expected Log Snippet:
#   [STAGE: 3/4 - GENERATE INTEGRITY CHECKSUM]
#   [ERROR] Configured hashing algorithm tool 'sha256sum_invalid_binary' was not found or is invalid.
#
#   Root Cause: The repository configuration file `/opt/production-cicd/workspace/app/pipeline.env`
#   contains a corrupted algorithm entry `sha256sum_invalid_binary`.
#
# STEP 4: Fix Pipeline Manifest Configuration
#   Edit the repository configuration:
#
#   $ sudo nano /opt/production-cicd/workspace/app/pipeline.env
#
#   Change:
#   CHECKSUM_ALGO="sha256sum_invalid_binary"
#   To:
#   CHECKSUM_ALGO="sha256sum"
#
# STEP 5: Diagnose Third Pipeline Failure (Artifact Publication Directory Ownership)
#   Restart the service and check logs once more:
#
#   $ sudo systemctl restart enterprise-ci-agent.service
#   $ sudo journalctl -u enterprise-ci-agent.service -n 30 --no-pager
#
#   Expected Log Snippet:
#   [STAGE: 4/4 - PUBLISH TO ARTIFACT REPOSITORY]
#   Copying release artifacts to /var/opt/ci-artifacts/v1.0.0...
#   cp: cannot create regular file '/var/opt/ci-artifacts/v1.0.0/core-api-service-1.0.0-...': Permission denied
#
#   Check permissions on artifact directory:
#   $ ls -ld /var/opt/ci-artifacts
#   drwx------ 3 root root 4096 /var/opt/ci-artifacts
#
#   Root Cause: Directory ownership is root:root with 0700 permissions. The `ci-runner` user
#   cannot traverse or write into the directory.
#
# STEP 6: Fix Artifact Storage Permissions
#   Grant appropriate ownership and permissions to the `ci-runner` service user and group:
#
#   $ sudo chown -R ci-runner:ci-runner /var/opt/ci-artifacts
#   $ sudo chmod -R 0755 /var/opt/ci-artifacts
#
# STEP 7: Verification & Final Validation
#   Trigger the pipeline service and verify exit status:
#
#   $ sudo systemctl restart enterprise-ci-agent.service
#   $ sudo systemctl status enterprise-ci-agent.service
#   $ sudo journalctl -u enterprise-ci-agent.service -n 30 --no-pager
#
#   Expected Output:
#   [$(date)] === PIPELINE SUCCESS: Release v1.0.0 Published ===
#
#   Verify publication in persistent store:
#   $ ls -l /var/opt/ci-artifacts/v1.0.0/
#   total 8
#   -rw-r--r-- 1 ci-runner ci-runner 154 core-api-service-1.0.0-XXXXX.tar.gz
#   -rw-r--r-- 1 ci-runner ci-runner  95 core-api-service-1.0.0-XXXXX.tar.gz.sha256
#
# ==============================================================================