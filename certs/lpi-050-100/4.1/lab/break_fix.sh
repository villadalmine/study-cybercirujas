#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials Overview
# Topic 4.1: Software Development Business Models (Weight: 5)
# Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
#
# Production Break & Fix Lab Environment
# Author: Senior SRE & Principal Platform Architect
# ==============================================================================
# LAB OVERVIEW:
# In enterprise platform environments, managing open-source software involves
# navigating various business models: Open Core, Dual Licensing, Subscriptions/
# Support Services, SaaS/Managed Services, and Open Source Foundations.
# 
# In this lab, a critical production service deployment pipeline is failing.
# The service deployment script validates software business model compliance,
# repository access entitlements, dual-licensing keys, and open-core feature 
# enablement flags across your environment.
#
# A misconfiguration has been injected into the application's configuration 
# directory and environment file, causing license validation failures, feature
# lockout, and repository sync errors.
# ==============================================================================

set -euo pipefail

# Work directory setup for safe disposable execution
LAB_DIR="/tmp/lpi-050-100-topic41-lab"
CONFIG_DIR="${LAB_DIR}/etc/open-core-app"
DEFAULT_ENV="${LAB_DIR}/etc/default/app-service"
BIN_DIR="${LAB_DIR}/usr/local/bin"

echo "[+] Initializing LPI 050-100 Topic 4.1 Break & Fix Lab Environment..."

# Clean previous lab runs
rm -rf "${LAB_DIR}"
mkdir -p "${CONFIG_DIR}" "${BIN_DIR}" "$(dirname "${DEFAULT_ENV}")"

# ------------------------------------------------------------------------------
# 1. SETUP LAB INFRASTRUCTURE (Mock Service & Validator)
# ------------------------------------------------------------------------------

# Create the business model compliance validation tool
cat << 'EOF' > "${BIN_DIR}/app-service-check"
#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="/tmp/lpi-050-100-topic41-lab"
CONFIG_FILE="${LAB_DIR}/etc/open-core-app/config.json"
ENV_FILE="${LAB_DIR}/etc/default/app-service"

echo "=== Open Source Software Business Model & Compliance Validator ==="

if [[ ! -f "${CONFIG_FILE}" ]] || [[ ! -f "${ENV_FILE}" ]]; then
    echo "CRITICAL ERROR: Configuration or environment files missing!"
    exit 1
fi

source "${ENV_FILE}"

BUSINESS_MODEL=$(grep -oP '"business_model"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" || echo "unknown")
LICENSE_TYPE=$(grep -oP '"license_type"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" || echo "unknown")
OPEN_CORE_FEATURES=$(grep -oP '"enterprise_addons_enabled"\s*:\s*\K[^,}]' "${CONFIG_FILE}" || echo "false")
REPO_URL=$(grep -oP '"repository_url"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" || echo "unknown")

ERRORS=0

echo "[*] Auditing Business Model: ${BUSINESS_MODEL}"
echo "[*] Auditing License Type: ${LICENSE_TYPE}"
echo "[*] Auditing Open Core Feature Gate: ${OPEN_CORE_FEATURES}"
echo "[*] Auditing Entitlement Repo: ${REPO_URL}"
echo "-----------------------------------------------------------------"

# Check 1: Open Core Model Requirements
if [[ "${BUSINESS_MODEL}" == "open_core" ]]; then
    if [[ "${OPEN_CORE_FEATURES}" == "true" ]] && [[ "${SERVICE_TIER:-}" != "commercial_subscription" ]]; then
        echo "FAIL [1]: Open Core enterprise add-ons are enabled in config.json, but SERVICE_TIER in app-service environment is set to '${SERVICE_TIER:-none}'. Enterprise features require 'commercial_subscription' tier!"
        ERRORS=$((ERRORS + 1))
    fi
fi

# Check 2: Dual Licensing Requirements
if [[ "${BUSINESS_MODEL}" == "dual_licensing" ]]; then
    if [[ "${LICENSE_TYPE}" == "proprietary_commercial" ]] && [[ -z "${COMMERCIAL_LICENSE_KEY:-}" ]]; then
        echo "FAIL [2]: Dual-licensing model selected with proprietary license, but COMMERCIAL_LICENSE_KEY is missing from ${ENV_FILE}!"
        ERRORS=$((ERRORS + 1))
    fi
    if [[ "${LICENSE_TYPE}" == "gplv3" ]] && [[ -n "${COMMERCIAL_LICENSE_KEY:-}" ]]; then
        echo "WARN: Commercial key present while operating under GPLv3 copyleft terms."
    fi
fi

# Check 3: Subscription & Support Repository Access
if [[ "${SERVICE_TIER:-}" == "commercial_subscription" ]]; then
    if [[ "${REPO_URL}" == *"public-community"* ]]; then
        echo "FAIL [3]: Commercial subscription tier misconfigured to fetch enterprise binaries from community repository (${REPO_URL}). Must point to 'https://enterprise-repo.vendor.com/v1'!"
        ERRORS=$((ERRORS + 1))
    fi
fi

# Check 4: Business Model Alignment
if [[ "${BUSINESS_MODEL}" == "open_core" ]] && [[ "${LICENSE_TYPE}" != "apache2_with_proprietary_plugins" ]]; then
    echo "FAIL [4]: Open Core model alignment error. Base open-core framework license must be 'apache2_with_proprietary_plugins', found '${LICENSE_TYPE}'!"
    ERRORS=$((ERRORS + 1))
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo -e "\nSTATUS: VALIDATION FAILED (${ERRORS} compliance/licensing issues detected)."
    echo "Review Open Source Business Model principles (Open Core, Dual Licensing, Subscription, SaaS)."
    exit 1
else
    echo -e "\nSTATUS: VALIDATION SUCCESSFUL!"
    echo "Software deployment business model configuration is compliant and operational."
    exit 0
fi
EOF

chmod +x "${BIN_DIR}/app-service-check"

# ------------------------------------------------------------------------------
# 2. INJECT BROKEN CONFIGURATION (Break Phase)
# ------------------------------------------------------------------------------

# Inject incorrect configuration for an Open Core + Subscription business model
cat << 'EOF' > "${CONFIG_DIR}/config.json"
{
  "app_name": "DataFlow Engine",
  "business_model": "open_core",
  "license_type": "gplv3_strict",
  "enterprise_addons_enabled": true,
  "repository_url": "https://public-community-mirror.vendor.com/v1",
  "support_level": "community_forum"
}
EOF

cat << 'EOF' > "${DEFAULT_ENV}"
# Environment Variables for DataFlow Engine Service
SERVICE_NAME="dataflow-engine"
SERVICE_TIER="community_free"
COMMERCIAL_LICENSE_KEY=""
SUPPORT_CONTRACT_ID="NONE"
EOF

# ------------------------------------------------------------------------------
# 3. DISPLAY STUDENT SYMPTOMS & INSTRUCTIONS
# ------------------------------------------------------------------------------

cat << EOF

================================================================================
  LPI 050-100 (Topic 4.1) SRE BREAK & FIX LAB: BUSINESS MODELS IN OSS
================================================================================

SCENARIO:
Your organization utilizes an Open Core software suite ("DataFlow Engine") 
with a Commercial Subscription for enterprise add-ons (SSO, Audit Logging) 
and official vendor support.

During a routine automated migration, a developer misconfigured the business 
model settings and environment file. As a result, production validation 
is failing, locking out enterprise add-ons and breaking repository syncs.

SYMPTOMS:
- Executing the verification script returns multiple business model compliance 
  and licensing alignment errors.
- The service is misconfigured between Open Core, Dual Licensing, and 
  Community vs Enterprise subscription tiers.

GOAL:
Reconfigure the application configuration file and environment variables so 
that the business model validation succeeds under the following enterprise 
Open Core requirements:

1. Business Model must be set to "open_core".
2. Base framework license type must be "apache2_with_proprietary_plugins".
3. Enterprise add-ons ("enterprise_addons_enabled") must remain set to true.
4. SERVICE_TIER in the environment file must be updated to "commercial_subscription".
5. Repository URL must point to the official enterprise repo:
   "https://enterprise-repo.vendor.com/v1"
6. Ensure COMMERCIAL_LICENSE_KEY is set in the environment file to:
   "DF-ENT-2026-KEY-99481"

DIAGNOSTIC COMMAND TO RUN:
  ${BIN_DIR}/app-service-check

================================================================================
EOF

exit 0

# ==============================================================================
# SOLUTION PASO A PASO (STEP-BY-STEP SOLUTION)
# ==============================================================================
# To solve this lab, execute the following steps in your terminal:
#
# STEP 1: Run the diagnostic tool to identify failing business model assertions.
# Command:
#   /tmp/lpi-050-100-topic41-lab/usr/local/bin/app-service-check
#
# Expected output will highlight 3 to 4 compliance failures:
# - SERVICE_TIER mismatch for enabled enterprise add-ons.
# - Repository URL pointing to community mirror instead of commercial repo.
# - License type mismatch for Open Core base framework.
#
# STEP 2: Understand the underlying Software Business Model Concepts:
# - Open Core: Core functionality is released under a permissive open-source
#   license (e.g., Apache 2.0 or MIT), while premium/enterprise features 
#   (add-ons) are proprietary and require a commercial subscription.
# - Dual Licensing: Offering the exact same software codebase under both an 
#   open-source copyleft license (e.g., GPLv3) for community use and a 
#   proprietary commercial license for non-GPL compliant commercial embedding.
# - Subscription/Support Model: Charging for technical support, SLAs, 
#   security patches, and enterprise repository access (e.g., Red Hat model).
#
# STEP 3: Fix the JSON configuration file (`/tmp/lpi-050-100-topic41-lab/etc/open-core-app/config.json`).
# Update `license_type` to "apache2_with_proprietary_plugins" and 
# `repository_url` to "https://enterprise-repo.vendor.com/v1".
#
# Command:
# cat << 'EOF' > /tmp/lpi-050-100-topic41-lab/etc/open-core-app/config.json
# {
#   "app_name": "DataFlow Engine",
#   "business_model": "open_core",
#   "license_type": "apache2_with_proprietary_plugins",
#   "enterprise_addons_enabled": true,
#   "repository_url": "https://enterprise-repo.vendor.com/v1",
#   "support_level": "24_7_enterprise_sla"
# }
# EOF
#
# STEP 4: Fix the environment file (`/tmp/lpi-050-100-topic41-lab/etc/default/app-service`).
# Update `SERVICE_TIER` to "commercial_subscription" and populate `COMMERCIAL_LICENSE_KEY`.
#
# Command:
# cat << 'EOF' > /tmp/lpi-050-100-topic41-lab/etc/default/app-service
# SERVICE_NAME="dataflow-engine"
# SERVICE_TIER="commercial_subscription"
# COMMERCIAL_LICENSE_KEY="DF-ENT-2026-KEY-99481"
# SUPPORT_CONTRACT_ID="SUP-88401"
# EOF
#
# STEP 5: Verify the fix.
# Command:
#   /tmp/lpi-050-100-topic41-lab/usr/local/bin/app-service-check
#
# Expected final output:
#   STATUS: VALIDATION SUCCESSFUL!
#   Software deployment business model configuration is compliant and operational.
# ==============================================================================