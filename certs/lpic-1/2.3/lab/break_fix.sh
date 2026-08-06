#!/bin/bash
# Break & Fix: Administrative Tasks (Topic 2.3)

# 1. Break the system: Misconfigure a service account and break a systemd timer
# Create a user with a valid shell, but lock the account in shadow.
useradd -m -s /bin/bash lab_admin 2>/dev/null || true
usermod -L lab_admin

# Break local timezone intentionally
rm -f /etc/localtime
ln -s /usr/share/zoneinfo/Antarctica/Troll /etc/localtime

# Create a broken systemd timer and service
cat << 'EOF' > /etc/systemd/system/health-check.service
[Unit]
Description=Health Check Service

[Service]
Type=oneshot
ExecStart=/usr/bin/false
User=non_existent_user
EOF

cat << 'EOF' > /etc/systemd/system/health-check.timer
[Unit]
Description=Run Health Check Every Minute

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now health-check.timer 2>/dev/null || true

# Present the challenge to the student
cat << 'CHALLENGE'

======================================================================
LAB CHALLENGE: ADMINISTRATIVE TASKS
======================================================================

Symptoms:
1. The user 'lab_admin' cannot log in or execute sudo commands because 
   their account is locked.
2. The system timezone is set incorrectly (to Antarctica/Troll).
3. The 'health-check.timer' is triggering a service that constantly fails.

Your Task:
1. Unlock the 'lab_admin' account.
2. Change the system timezone to 'UTC'.
3. Fix the 'health-check.service' so it runs successfully. You will need 
   to change the 'User' to a valid account (e.g. 'root') and change 
   'ExecStart' to '/usr/bin/true'.
4. Ensure the timer runs successfully without failing the service.

Good luck!
======================================================================
CHALLENGE

# --------------------------------------------------------------------
# SOLUTION (SPOILER WARNING)
# --------------------------------------------------------------------
# To fix the lab, follow these steps:
#
# 1. Unlock the user account:
#    usermod -U lab_admin
#    # Verify with: grep lab_admin /etc/shadow (should not have '!' prefix)
#
# 2. Set the timezone to UTC:
#    timedatectl set-timezone UTC
#    # Verify with: timedatectl status
#
# 3. Fix the systemd service:
#    sed -i 's/User=non_existent_user/User=root/' /etc/systemd/system/health-check.service
#    sed -i 's/ExecStart=\/usr\/bin\/false/ExecStart=\/usr\/bin\/true/' /etc/systemd/system/health-check.service
#
# 4. Reload systemd and verify the timer execution:
#    systemctl daemon-reload
#    systemctl restart health-check.service
#    systemctl status health-check.timer