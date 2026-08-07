#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (701-100) - Topic 5.1: IT Operations & Monitoring
# Production SRE Break & Fix Laboratory Script
#
# Official Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# Weight: 6.67
# Description: Safely breaks Prometheus Node Exporter service and Journald metric 
#              ingestion pipeline on a disposable Linux VM for hands-on SRE troubleshooting.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be executed as root.${NC}" 1>&2
   exit 1
fi

echo -e "${BLUE}[*] Initializing SRE Break & Fix Lab: Topic 5.1 IT Operations & Monitoring...${NC}"

# ------------------------------------------------------------------------------
# 1. Dependency Resolution & Installation
# ------------------------------------------------------------------------------
echo -e "${BLUE}[*] Provisioning environment dependencies (Prometheus Node Exporter, iptables, curl)...${NC}"

if command -v apt-get &> /dev/null; then
    apt-get update -qq && apt-get install -y -qq prometheus-node-exporter iptables curl systemd > /dev/null
elif command -v dnf &> /dev/null; then
    dnf install -y -q prometheus-node-exporter iptables curl systemd > /dev/null
elif command -v yum &> /dev/null; then
    yum install -y -q prometheus-node-exporter iptables curl systemd > /dev/null
else
    echo -e "${YELLOW}[!] Package manager not detected. Downloading Node Exporter binary manually...${NC}"
    VERSION="1.7.0"
    ARCH="linux-amd64"
    curl -sSL "https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.${ARCH}.tar.gz" | tar -xz -C /tmp/
    cp "/tmp/node_exporter-${VERSION}.${ARCH}/node_exporter" /usr/local/bin/node_exporter
    useradd -rs /bin/false prometheus 2>/dev/null || true
fi

EXPORTER_BIN=""
if command -v prometheus-node-exporter &> /dev/null; then
    EXPORTER_BIN="$(command -v prometheus-node-exporter)"
elif [[ -f /usr/local/bin/node_exporter ]]; then
    EXPORTER_BIN="/usr/local/bin/node_exporter"
else
    EXPORTER_BIN="/usr/bin/node_exporter"
fi

# Create target directories for custom textfile collector metrics
mkdir -p /var/lib/prometheus/node-exporter/textfile_collector
mkdir -p /var/log/sre-monitoring

# Create a sample custom metric file
cat << 'EOF' > /var/lib/prometheus/node-exporter/textfile_collector/custom_app.prom
# HELP custom_app_status Status of external application service (1 = UP, 0 = DOWN)
# TYPE custom_app_status gauge
custom_app_status{app="billing"} 1
EOF

# ------------------------------------------------------------------------------
# 2. Inject Controlled Faults
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[!] Injecting multi-layer infrastructure monitoring faults...${NC}"

# Fault A: Broken systemd unit file (Permission, capability isolation, and path mismatches)
cat << EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter (SRE Managed)
Documentation=https://prometheus.io/docs/guides/node-exporter/
After=network.target

[Service]
User=nobody
Group=nogroup
Type=simple
ExecStart=${EXPORTER_BIN} --collector.textfile.directory=/var/lib/prometheus/node-exporter/textfile_collector --web.listen-address=127.0.0.1:9100
Restart=always
RestartSec=3

# Security & Sandbox Over-isolation (Causes failure reading system metrics & textfile collector)
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/tmp
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# Fault B: Restrict file permissions on textfile collector directory so 'nobody' cannot access it
chown -R root:root /var/lib/prometheus/node-exporter
chmod 0700 /var/lib/prometheus/node-exporter
chmod 0700 /var/lib/prometheus/node-exporter/textfile_collector

# Fault C: Firewall packet filtering dropping traffic on TCP 9100
iptables -A INPUT -p tcp --dport 9100 -j DROP 2>/dev/null || true

# Fault D: Broken journald log forwarder daemon script (missing execution permissions)
cat << 'EOF' > /usr/local/bin/sre_journal_watcher.sh
#!/usr/bin/env bash
# Journald log ingestion monitor script for high-severity kernel and OOM events
journalctl -f -p err -o json | grep --line-buffered "Out of memory" >> /var/log/sre-monitoring/oom_events.log
EOF
chmod 0644 /usr/local/bin/sre_journal_watcher.sh # Missing executable bit!

cat << EOF > /etc/systemd/system/sre-journal-watcher.service
[Unit]
Description=SRE Journald OOM Monitoring Pipeline
After=systemd-journald.service

[Service]
Type=simple
ExecStart=/usr/local/bin/sre_journal_watcher.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start broken services
systemctl daemon-reload
systemctl enable node_exporter.service sre-journal-watcher.service > /dev/null 2>&1 || true
systemctl restart node_exporter.service sre-journal-watcher.service > /dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 3. Print Student Briefing
# ------------------------------------------------------------------------------
clear
echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}  LPI DevOps Tools Engineer (701-100) - Topic 5.1: IT Operations & Monitoring ${NC}"
echo -e "${GREEN}  TROUBLESHOOTING SCENARIO: Metric Scrape & Log Pipeline Outage               ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""
echo -e "${YELLOW}[INCIDENT SUMMARY]${NC}"
echo "An alert fired in Prometheus: 'HostMetricsCollectionFailed' and 'LogPipelineDown'."
echo "The infrastructure monitoring stack on this node is failing to expose system metrics"
echo "to Prometheus scrapers on port 9100 and fails to capture critical journald log events."
echo ""
echo -e "${YELLOW}[OBSERVED SYMPTOMS]${NC}"
echo "1. 'systemctl status node_exporter' reports a failing or constantly restarting service."
echo "2. 'curl http://127.0.0.1:9100/metrics' hangs, times out, or fails to connect."
echo "3. Custom textfile collector metrics (/var/lib/prometheus/node-exporter/textfile_collector)"
echo "   are not visible in metric outputs."
echo "4. 'systemctl status sre-journal-watcher' reports 'status=203/EXEC'."
echo ""
echo -e "${YELLOW}[YOUR OBJECTIVES]${NC}"
echo "1. Diagnose and fix 'node_exporter.service' so it starts clean and remains active (running)."
echo "2. Ensure security sandbox parameters (ProtectSystem, ReadWritePaths) allow reading"
echo "   the custom textfile metrics directory without breaking systemd isolation."
echo "3. Diagnose network packet filtering preventing local scraping of TCP port 9100."
echo "4. Fix the 'sre-journal-watcher.service' execution failure."
echo "5. Verify that 'curl -s http://127.0.0.1:9100/metrics' returns HTTP 200 with both standard"
echo "   node exporter metrics and 'custom_app_status'."
echo ""
echo -e "${BLUE}Reference Documentation: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo ""

# Exit cleanly after setting up the lab environment
exit 0

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (FOR INSTRUCTORS AND VERIFICATION)
# ==============================================================================
#
# STEP 1: Diagnose systemd unit failure for node_exporter
# ------------------------------------------------------------------------------
# Run:
#   systemctl status node_exporter.service
#   journalctl -u node_exporter.service -n 50 --no-pager
#
# Root Cause 1: Permission Denied on /var/lib/prometheus/node-exporter/textfile_collector
# The service runs as user 'nobody', but directory ownership is 'root:root' with '0700' permissions.
#
# Fix 1 (File Permissions):
#   chown -R nobody:nogroup /var/lib/prometheus/node-exporter
#   chmod -R 0755 /var/lib/prometheus/node-exporter
#   (Note: on RHEL/CentOS systems, use 'nobody:nobody')
#
# Root Cause 2: Overly strict systemd sandbox settings in /etc/systemd/system/node_exporter.service
# 'ProtectSystem=strict' mounts the entire filesystem read-only.
# 'ReadWritePaths=/tmp' does not allow Node Exporter to read /var/lib/prometheus or write runtime state if needed.
#
# Fix 2 (Update systemd unit configuration):
# Edit /etc/systemd/system/node_exporter.service and update ReadWritePaths:
#   ReadWritePaths=/var/lib/prometheus/node-exporter/textfile_collector
# Or adjust ProtectSystem to 'full'.
#
# STEP 2: Diagnose journald log pipeline watcher
# ------------------------------------------------------------------------------
# Run:
#   systemctl status sre-journal-watcher.service
# Output shows: Status 203/EXEC -> Means systemd failed to execute script due to missing permissions.
#
# Fix:
#   chmod +x /usr/local/bin/sre_journal_watcher.sh
#   systemctl restart sre-journal-watcher.service
#   systemctl status sre-journal-watcher.service
#
# STEP 3: Reload and restart systemd services
# ------------------------------------------------------------------------------
# Run:
#   systemctl daemon-reload
#   systemctl restart node_exporter.service
#   systemctl status node_exporter.service
#
# STEP 4: Diagnose TCP Port 9100 network filtering
# ------------------------------------------------------------------------------
# Run:
#   curl -v http://127.0.0.1:9100/metrics
#   (Connection times out or hangs)
# Check listening sockets:
#   ss -tulpn | grep 9100
# Node Exporter IS listening on 127.0.0.1:9100.
# Check firewall rules:
#   iptables -L INPUT -v -n --line-numbers
# You will see a DROP rule targeting tcp dpt:9100.
#
# Fix:
#   iptables -D INPUT -p tcp --dport 9100 -j DROP
#   (Or flush rules: iptables -F INPUT)
#
# STEP 5: Final Empirical Verification
# ------------------------------------------------------------------------------
# Run:
#   curl -s http://127.0.0.1:9100/metrics | grep "node_cpu_seconds_total"
#   curl -s http://127.0.0.1:9100/metrics | grep "custom_app_status"
#   systemctl is-active node_exporter.service sre-journal-watcher.service
#
# Both commands should return active status and valid Prometheus metric strings!
# ==============================================================================