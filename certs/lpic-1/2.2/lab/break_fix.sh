#!/bin/bash
# Break & Fix: Interfaces and Desktops (Topic 2.2)

# Ensure the system has lightdm and xorg installed for the lab
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lightdm xserver-xorg xfce4 >/dev/null

# 1. Break the system: Misconfigure the LightDM configuration to point to a non-existent user session
mkdir -p /etc/lightdm/lightdm.conf.d
cat << 'EOF' > /etc/lightdm/lightdm.conf.d/50-autologin.conf
[Seat:*]
autologin-user=vdi-user
autologin-user-timeout=0
user-session=non-existent-desktop
EOF

# 2. Break Xorg configuration: Invalid monitor configuration syntax
mkdir -p /etc/X11/xorg.conf.d
cat << 'EOF' > /etc/X11/xorg.conf.d/10-monitor.conf
Section "Monitor"
    Identifier  "DP-1"
    Option      "Primary" "true"
    Option      "PreferredMode" "1920x1080"
# Missing EndSection to intentionally break Xorg parser
EOF

# Present the challenge to the student
cat << 'CHALLENGE'

======================================================================
LAB CHALLENGE: INTERFACES AND DESKTOPS
======================================================================

Symptoms:
1. The Display Manager (LightDM) is failing to start the graphical session.
2. If the X server tries to parse manual configurations, it will encounter errors.

Your Task:
1. Diagnose why LightDM is failing by inspecting its status and logs.
2. Fix the Xorg configuration in /etc/X11/xorg.conf.d/10-monitor.conf.
3. Fix the LightDM user session configuration in /etc/lightdm/lightdm.conf.d/50-autologin.conf
   so it points to a valid session (e.g., 'xfce').
4. Successfully restart lightdm.service.

Good luck!
======================================================================
CHALLENGE

# --------------------------------------------------------------------
# SOLUTION (SPOILER WARNING)
# --------------------------------------------------------------------
# To fix the lab, follow these steps:
#
# 1. Check LightDM status:
#    systemctl status lightdm
#    journalctl -u lightdm -e
#
# 2. Fix the Xorg parser error:
#    echo 'EndSection' >> /etc/X11/xorg.conf.d/10-monitor.conf
#
# 3. Fix the LightDM session setting:
#    sed -i 's/user-session=non-existent-desktop/user-session=xfce/' /etc/lightdm/lightdm.conf.d/50-autologin.conf
#
# 4. Restart the Display Manager:
#    systemctl restart lightdm