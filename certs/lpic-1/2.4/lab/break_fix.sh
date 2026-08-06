#!/bin/bash
# Break & Fix: Essential System Services (Topic 2.4)

apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chrony >/dev/null

# 1. Break chrony configuration
cat << 'EOF' > /etc/chrony/chrony.conf
# Intentionally broken configuration: invalid server address
server ntp.invalid.example.com iburst
# Remove all pool directives
EOF

systemctl restart chrony

# 2. Break systemd-journald
mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' > /etc/systemd/journald.conf.d/99-broken.conf
[Journal]
# Invalid syntax to cause journald to fall back or fail parsing
Storage=invalid_value
EOF

systemctl restart systemd-journald

# Present the challenge to the student
cat << 'CHALLENGE'

======================================================================
LAB CHALLENGE: ESSENTIAL SYSTEM SERVICES
======================================================================

Symptoms:
1. The system clock is not synchronizing with any NTP servers.
2. The `systemd-journald` configuration contains an invalid parameter, 
   which might be silently ignored or cause unexpected logging behavior.

Your Task:
1. Diagnose why `chrony` is failing to synchronize. Inspect its sources.
2. Fix the `/etc/chrony/chrony.conf` file by replacing the invalid server 
   with a valid pool (e.g., 'pool 2.debian.pool.ntp.org iburst') and restart chrony.
3. Fix the journald configuration in `/etc/systemd/journald.conf.d/99-broken.conf`
   by setting `Storage=persistent`. Restart `systemd-journald`.

Good luck!
======================================================================
CHALLENGE

# --------------------------------------------------------------------
# SOLUTION (SPOILER WARNING)
# --------------------------------------------------------------------
# To fix the lab, follow these steps:
#
# 1. Check chrony sources:
#    chronyc sources -v
#    # Output will show the invalid server with no reachability.
#
# 2. Fix the chrony configuration:
#    sed -i 's/server ntp.invalid.example.com iburst/pool 2.debian.pool.ntp.org iburst/' /etc/chrony/chrony.conf
#    systemctl restart chrony
#    # Wait a few seconds, then verify with: chronyc sources -v
#
# 3. Fix the journald configuration:
#    sed -i 's/Storage=invalid_value/Storage=persistent/' /etc/systemd/journald.conf.d/99-broken.conf
#    systemctl restart systemd-journald