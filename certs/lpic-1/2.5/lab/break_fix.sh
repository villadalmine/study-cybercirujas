#!/bin/bash
# Break & Fix: Networking Fundamentals (Topic 2.5)

apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 netcat-openbsd >/dev/null

# 1. Break the network: delete the default route
ip route del default 2>/dev/null || true

# 2. Break DNS resolution: manipulate /etc/resolv.conf
# We use a non-existent local IP to cause timeouts
rm -f /etc/resolv.conf
cat << 'EOF' > /etc/resolv.conf
nameserver 10.255.255.254
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true

# 3. Bind a dummy process to a critical port to simulate a conflict
nc -l -p 8080 >/dev/null 2>&1 &
NC_PID=$!

# Present the challenge to the student
cat << 'CHALLENGE'

======================================================================
LAB CHALLENGE: NETWORKING FUNDAMENTALS
======================================================================

Symptoms:
1. You cannot ping external IP addresses (e.g., 'ping 8.8.8.8' fails 
   with "Network is unreachable").
2. Domain names fail to resolve (e.g., 'ping google.com' fails).
3. A web application you are trying to deploy on port 8080 cannot start 
   because the port is "already in use".

Your Task:
1. Fix the routing table by adding a default route via your local 
   gateway. (If you don't know your gateway, assume '10.0.2.2' for 
   this lab environment).
2. Fix DNS resolution by pointing `/etc/resolv.conf` to a valid public 
   DNS server (e.g., '8.8.8.8'). Note: The file might be immutable!
3. Find the process holding TCP port 8080 and terminate it so your 
   application can bind to it.

Good luck!
======================================================================
CHALLENGE

# --------------------------------------------------------------------
# SOLUTION (SPOILER WARNING)
# --------------------------------------------------------------------
# To fix the lab, follow these steps:
#
# 1. Add the default route:
#    ip route add default via 10.0.2.2
#    # Verify: ping -c 1 8.8.8.8
#
# 2. Fix DNS resolution:
#    # Remove the immutable attribute if present:
#    chattr -i /etc/resolv.conf 2>/dev/null || true
#    echo "nameserver 8.8.8.8" > /etc/resolv.conf
#    # Verify: ping -c 1 google.com
#
# 3. Free up port 8080:
#    # Find the process:
#    ss -tlnp | grep 8080
#    # It will show 'nc' or 'netcat'. Kill it:
#    killall nc