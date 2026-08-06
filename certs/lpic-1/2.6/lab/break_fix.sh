#!/bin/bash
# Break & Fix: Security (Topic 2.6)

# Create a test user for the lab
useradd -m -s /bin/bash sec_admin 2>/dev/null || true
echo "sec_admin:labpassword" | chpasswd

# 1. Break sudo: Create a syntax error in a sudoers drop-in file
mkdir -p /etc/sudoers.d
cat << 'EOF' > /etc/sudoers.d/99-broken
# Intentional syntax error below
sec_admin ALL=(root) NOPASSWD /usr/bin/systemctl restart
EOF
chmod 0440 /etc/sudoers.d/99-broken

# 2. Break SSH: Disable password authentication and root login (good practice, but locks out our test user who has no keys)
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

# 3. Create a rogue SUID binary to simulate a vulnerability
cp /bin/cp /tmp/rogue_cp
chown root:root /tmp/rogue_cp
chmod 4755 /tmp/rogue_cp

# Present the challenge to the student
cat << 'CHALLENGE'

======================================================================
LAB CHALLENGE: SECURITY
======================================================================

Symptoms:
1. The user 'sec_admin' (password: labpassword) cannot run sudo. It fails 
   with a parse error.
2. The user 'sec_admin' cannot SSH into the local machine because public key 
   authentication is required, and they have no keys.
3. An attacker left a rogue SUID binary somewhere in `/tmp/`.

Your Task:
1. Fix the syntax error in `/etc/sudoers.d/99-broken` using the correct tool.
   (The line should be: sec_admin ALL=(root) NOPASSWD: /usr/bin/systemctl restart)
2. Temporarily re-enable `PasswordAuthentication` in `/etc/ssh/sshd_config` 
   and restart the SSH daemon so you can test logging in.
3. Find the rogue SUID binary in `/tmp/` and remove the SUID bit so it can 
   no longer execute as root.

Good luck!
======================================================================
CHALLENGE

# --------------------------------------------------------------------
# SOLUTION (SPOILER WARNING)
# --------------------------------------------------------------------
# To fix the lab, follow these steps:
#
# 1. Fix the sudoers file using visudo:
#    visudo -f /etc/sudoers.d/99-broken
#    # Change the line to: sec_admin ALL=(root) NOPASSWD: /usr/bin/systemctl restart
#
# 2. Re-enable PasswordAuthentication:
#    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
#    systemctl restart sshd
#    # Verify: ssh sec_admin@localhost
#
# 3. Find and neutralize the rogue SUID binary:
#    find /tmp -perm -4000 -type f
#    # It will find /tmp/rogue_cp
#    chmod u-s /tmp/rogue_cp