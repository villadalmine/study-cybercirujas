#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Security (Exam 303-300, Version 3.0)
# Topic 303.1 / 6.1: Threats and Vulnerability Assessment
# Lab Exercise: OpenSCAP / SCAP Automation & Vulnerability Pipeline Break & Fix
#
# Target Audience: Senior SRE & Platform Security Engineers
# Author: Senior SRE Instructor & Principal Platform Architect
# Official Reference: https://www.lpi.org/our-certifications/lpic-3-303-overview/
# Additional Standards: NIST SP 800-126 (SCAP v1.3), OpenSCAP Documentation
# ==============================================================================
# 
# SCENARIO OVERVIEW:
# An automated Security Content Automation Protocol (SCAP) compliance and 
# vulnerability scanner was deployed to continuously assess Linux nodes using 
# OpenSCAP (`oscap`), XCCDF tailoring profiles, OVAL vulnerability streams, 
# and custom reporting handlers. 
# 
# Following a recent infrastructure update, the automated vulnerability assessment 
# pipeline (`oscap-scanner.service`) started failing during nightly execution. 
# Security operations reports that vulnerability reports are no longer being generated, 
# and manual execution attempts return cryptic validation and path errors.
#
# YOUR MISSION:
# 1. Execute this script as root to simulate the production failure scenario.
# 2. Inspect system state, logs, XML profiles, and OSCAP engine outputs.
# 3. Diagnose and fix all broken components without removing security controls.
# 4. Verify that `oscap-scanner.service` runs clean and generates HTML/XML reports.
# ==============================================================================

set -euo pipefail

# Ensure execution as root
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This break & fix script must be executed as root." >&2
   exit 1
fi

LOG_FILE="/var/log/lpic3-break-fix-topic6.1.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================================================"
echo "[+] Initializing Environment for Topic 6.1 Threat Assessment Lab..."
echo "======================================================================"

# Step 1: Install prerequisite packages if missing
PACKAGES_TO_INSTALL=()
for pkg in openscap-scanner libxml2-utils; do
    if ! command -v "$pkg" &>/dev/null && ! dpkg -l "$pkg" &>/dev/null && ! rpm -q "$pkg" &>/dev/null; then
        PACKAGES_TO_INSTALL+=("$pkg")
    fi
done

if [[ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]]; then
    echo "[+] Installing required packages: ${PACKAGES_TO_INSTALL[*]}..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq openscap-scanner ssg-base ssg-deb-derived libxml2-utils &>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q openscap-scanner scap-security-guide libxml2 &>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y -q openscap-scanner scap-security-guide libxml2 &>/dev/null || true
    fi
fi

# Step 2: Establish directory structure for OSCAP assessment lab
CONF_DIR="/etc/oscap"
DATA_DIR="/var/lib/oscap"
REPORT_DIR="/var/log/oscap-reports"

mkdir -p "${CONF_DIR}" "${DATA_DIR}" "${REPORT_DIR}"

# Step 3: Generate sample XCCDF DataStream Benchmark (Minimal Valid SCAP DataStream)
DATASTREAM_FILE="${DATA_DIR}/ssg-benchmark-ds.xml"
cat <<'EOF' > "${DATASTREAM_FILE}"
<?xml version="1.0" encoding="UTF-8"?>
<ds:data-stream-collection xmlns:ds="http://scap.nist.gov/schema/scap/source/1.2"
                           xmlns:xlink="http://www.w3.org/1999/xlink"
                           id="scap_org.open-scap_collection_comp"
                           schematron-version="1.3">
  <ds:data-stream id="scap_org.open-scap_datastream_from_xccdf_ssg-rhel-xccdf.xml"
                  scap-version="1.3" use-case="CONFIGURATION">
    <ds:checklists>
      <ds:component-ref id="scap_org.open-scap_cref_ssg-rhel-xccdf.xml"
                        xlink:href="#scap_org.open-scap_comp_ssg-rhel-xccdf.xml"/>
    </ds:checklists>
  </ds:data-stream>
  <ds:component id="scap_org.open-scap_comp_ssg-rhel-xccdf.xml" timestamp="2026-08-01T00:00:00">
    <xccdf-1.2:Benchmark xmlns:xccdf-1.2="http://checklists.nist.gov/xccdf/1.2" id="xccdf_org.ssgproject.content_benchmark_OS">
      <xccdf-1.2:status date="2026-08-01">accepted</xccdf-1.2:status>
      <xccdf-1.2:title xml:lang="en-US">Production Linux Server Security Baseline</xccdf-1.2:title>
      <xccdf-1.2:description xml:lang="en-US">Baseline threat assessment checklist for enterprise servers.</xccdf-1.2:description>
      <xccdf-1.2:version>1.0</xccdf-1.2:version>
      <xccdf-1.2:Profile id="xccdf_org.ssgproject.content_profile_standard">
        <xccdf-1.2:title xml:lang="en-US">Standard System Security Profile</xccdf-1.2:title>
        <xccdf-1.2:description xml:lang="en-US">Standard CIS/STIG aligned benchmark profile.</xccdf-1.2:description>
        <xccdf-1.2:select idref="xccdf_org.ssgproject.content_rule_etc_passwd_permissions" selected="true"/>
      </xccdf-1.2:Profile>
      <xccdf-1.2:Rule id="xccdf_org.ssgproject.content_rule_etc_passwd_permissions" severity="high">
        <xccdf-1.2:title xml:lang="en-US">Verify Permissions on /etc/passwd</xccdf-1.2:title>
        <xccdf-1.2:description xml:lang="en-US">Ensure /etc/passwd has 0644 permissions.</xccdf-1.2:description>
        <xccdf-1.2:check system="http://oval.mitre.org/XMLSchema/oval-definitions-5">
          <xccdf-1.2:check-content-ref href="#scap_org.open-scap_comp_ssg-rhel-oval.xml" name="oval:ssg-etc_passwd_permissions:def:1"/>
        </xccdf-1.2:check>
      </xccdf-1.2:Rule>
    </xccdf-1.2:Benchmark>
  </ds:component>
</ds:data-stream-collection>
EOF

# Step 4: Create Tailoring XML file
TAILORING_FILE="${CONF_DIR}/ssg-custom-tailoring.xml"
cat <<'EOF' > "${TAILORING_FILE}"
<?xml version="1.0" encoding="UTF-8"?>
<xccdf-1.2:Tailoring xmlns:xccdf-1.2="http://checklists.nist.gov/xccdf/1.2"
                    id="xccdf_org.ssgproject.content_tailoring_custom">
  <xccdf-1.2:benchmark version="1.0" idref="xccdf_org.ssgproject.content_benchmark_OS"/>
  <xccdf-1.2:Profile id="xccdf_org.ssgproject.content_profile_hardened_pci" extends="xccdf_org.ssgproject.content_profile_standard">
    <xccdf-1.2:title xml:lang="en-US">Hardened PCI-DSS Tailored Baseline</xccdf-1.2:title>
    <xccdf-1.2:description xml:lang="en-US">Customized baseline overriding standard profile rules.</xccdf-1.2:description>
    <xccdf-1.2:select idref="xccdf_org.ssgproject.content_rule_etc_passwd_permissions" selected="true"/>
  </xccdf-1.2:Profile>
</xccdf-1.2:Tailoring>
EOF

# Step 5: Deploy the assessment runner script
RUNNER_SCRIPT="/usr/local/bin/oscap-vulnerability-checker.sh"
cat <<'EOF' > "${RUNNER_SCRIPT}"
#!/usr/bin/env bash
set -euo pipefail

BENCHMARK_DS="/var/lib/oscap/ssg-benchmark-ds.xml"
TAILORING_XML="/etc/oscap/ssg-custom-tailoring.xml"
REPORT_OUTPUT="/var/log/oscap-reports/scan-report.html"
RESULTS_OUTPUT="/var/log/oscap-reports/scan-results.xml"
PROFILE_ID="xccdf_org.ssgproject.content_profile_hardened_pci_v2"

echo "[+] Starting OpenSCAP Threat & Vulnerability Assessment scan..."

oscap xccdf eval \
    --profile "${PROFILE_ID}" \
    --tailoring-file "${TAILORING_XML}" \
    --results "${RESULTS_OUTPUT}" \
    --report "${REPORT_OUTPUT}" \
    "${BENCHMARK_DS}"

echo "[+] Scan completed successfully. Report generated at ${REPORT_OUTPUT}"
EOF
chmod 755 "${RUNNER_SCRIPT}"

# Step 6: Create systemd service for automated scanning
SERVICE_FILE="/etc/systemd/system/oscap-scanner.service"
cat <<'EOF' > "${SERVICE_FILE}"
[Unit]
Description=Automated OpenSCAP Threat and Vulnerability Scanner
Documentation=https://www.lpi.org/our-certifications/lpic-3-303-overview/
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/oscap-vulnerability-checker.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo "[+] Base SCAP assessment pipeline deployed."
echo "[+] Injecting realistic production faults for LPIC-3 Topic 6.1..."

# ==============================================================================
# INJECTING FAULTS (BREAKING THE ASSESSMENT PIPELINE)
# ==============================================================================

# FAULT 1: XML Syntax/Schema corruption in the Tailoring Profile XML
# We introduce an unclosed XML tag in the tailoring profile.
sed -i 's|</xccdf-1.2:Tailoring>|<xccdf-1.2:Tailoring-BROKEN>|g' "${TAILORING_FILE}"

# FAULT 2: Incorrect Profile ID reference in the scanner script
# The script attempts to evaluate `xccdf_org.ssgproject.content_profile_hardened_pci_v2`
# which does not exist in the XCCDF tailoring stream (the real ID is `xccdf_org.ssgproject.content_profile_hardened_pci`).
# (Already injected in RUNNER_SCRIPT via PROFILE_ID string).

# FAULT 3: Incorrect permissions and Immutable attribute on report destination directory
# Preventing the scanner from writing out the XCCDF results XML and HTML report.
chmod 000 "${REPORT_DIR}"
chattr +i "${REPORT_DIR}" 2>/dev/null || true

echo "======================================================================"
echo "[!] LAB BREAK & FIX ENVIRONMENT READY!"
echo "======================================================================"
echo ""
echo "SYMPTOMS REPORTED BY THE MONITORING SYSTEM:"
echo "----------------------------------------------------------------------"
echo "1. Running 'systemctl start oscap-scanner.service' fails immediately."
echo "2. Inspection via 'journalctl -u oscap-scanner.service' indicates script"
echo "   failures, XML parser failures, missing profile errors, or file IO errors."
echo "3. Security auditors are unable to retrieve HTML vulnerability reports from"
echo "   /var/log/oscap-reports/."
echo ""
echo "EXAM OBJECTIVES COVERED (LPIC-3 303-300, Objective 303.1 / Topic 6.1):"
echo "----------------------------------------------------------------------"
echo " - SCAP standards (XCCDF, OVAL, CPE, CVSS, CVE)."
echo " - OpenSCAP CLI tool usage (`oscap xccdf eval`, validation, tailoring)."
echo " - Vulnerability assessment automation, reporting, and troubleshooting."
echo ""
echo "YOUR INSTRUCTIONS:"
echo "----------------------------------------------------------------------"
echo "1. Run: systemctl start oscap-scanner.service"
echo "2. Analyze log outputs using systemd journalctl, oscap validation tools,"
echo "   and XML syntax checkers (e.g. xmllint)."
echo "3. Fix all structural XML bugs, identifier mismatches, and filesystem locks."
echo "4. Confirm resolution by executing: systemctl start oscap-scanner.service"
echo "   and verifying clean completion with zero errors."
echo "======================================================================"
exit 0

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION GUIDE (LPIC-3 303-300 TOPIC 6.1)
# ==============================================================================
# (Keep commented below for self-study and instructor verification)
#
# STEP 1: REPRODUCE AND DIAGNOSE THE FAILURE
# Execute the automated scanning systemd service:
#   # systemctl start oscap-scanner.service
#   # systemctl status oscap-scanner.service
#   # journalctl -u oscap-scanner.service -n 50 --no-pager
#
# Observed Error Output:
#   OpenSCAP Error: XML document is not well-formed or valid.
#   Unable to parse XML file /etc/oscap/ssg-custom-tailoring.xml
#
# STEP 2: FIX FAULT 1 (XML SYNTAX CORRUPTION IN TAILORING FILE)
# Use `xmllint` to validate XML syntax of the XCCDF tailoring file:
#   # xmllint --noout /etc/oscap/ssg-custom-tailoring.xml
#
# xmllint output will report a mismatching closing tag:
#   /etc/oscap/ssg-custom-tailoring.xml:11: parser error : opening and ending tag mismatch
#
# Edit `/etc/oscap/ssg-custom-tailoring.xml` and fix the closing tag at the end of the file:
#   Change: `<xccdf-1.2:Tailoring-BROKEN>`
#   To:     `</xccdf-1.2:Tailoring>`
#
# Validate the fix:
#   # xmllint --noout /etc/oscap/ssg-custom-tailoring.xml
#   (Should output nothing, indicating valid XML structure).
#
# STEP 3: RE-TEST AND DIAGNOSE FAULT 2 (PROFILE ID MISMATCH)
# Test running the scan script manually:
#   # /usr/local/bin/oscap-vulnerability-checker.sh
#
# Observed Error Output:
#   OpenSCAP Error: Profile 'xccdf_org.ssgproject.content_profile_hardened_pci_v2' was not found in the XCCDF document.
#
# Inspect available profiles inside the DataStream benchmark and Tailoring file using `oscap`:
#   # oscap xccdf info /var/lib/oscap/ssg-benchmark-ds.xml
#   # oscap xccdf info --tailoring-file /etc/oscap/ssg-custom-tailoring.xml /var/lib/oscap/ssg-benchmark-ds.xml
#
# Notice that the tailored profile ID listed is:
#   `xccdf_org.ssgproject.content_profile_hardened_pci`
# (Without the trailing `_v2`).
#
# Edit `/usr/local/bin/oscap-vulnerability-checker.sh` and correct the PROFILE_ID variable:
#   Change: PROFILE_ID="xccdf_org.ssgproject.content_profile_hardened_pci_v2"
#   To:     PROFILE_ID="xccdf_org.ssgproject.content_profile_hardened_pci"
#
# STEP 4: RE-TEST AND DIAGNOSE FAULT 3 (FILESYSTEM LOCK & PERMISSIONS ON REPORT DIR)
# Test running the script again:
#   # /usr/local/bin/oscap-vulnerability-checker.sh
#
# Observed Error Output:
#   OpenSCAP Error: Cannot open report file '/var/log/oscap-reports/scan-report.html' for writing: Permission denied
#
# Inspect filesystem permissions and attributes on `/var/log/oscap-reports`:
#   # ls -ld /var/log/oscap-reports
#   # lsattr -d /var/log/oscap-reports
#
# Notice mode is 000 and the immutable (`i`) attribute is set.
# Remove immutable attribute and restore permissions:
#   # chattr -i /var/log/oscap-reports
#   # chmod 755 /var/log/oscap-reports
#
# STEP 5: FINAL VERIFICATION
# Run the automated scanner service via systemd:
#   # systemctl start oscap-scanner.service
#   # systemctl status oscap-scanner.service
#
# Check that scan results and HTML reports were generated:
#   # ls -la /var/log/oscap-reports/
#   -rw-r--r-- 1 root root scan-report.html
#   -rw-r--r-- 1 root root scan-results.xml
#
# Verify HTML report header:
#   # head -n 20 /var/log/oscap-reports/scan-report.html
#
# You have successfully restored the SCAP Vulnerability Assessment pipeline!
# ==============================================================================