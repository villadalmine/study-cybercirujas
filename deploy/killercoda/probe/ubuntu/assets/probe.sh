#!/bin/bash
# Prints what this Killercoda image really is, to paste into deploy/killercoda/killercoda_envs.yaml (status: measured).
echo "== study-cybercirujas environment probe =="
. /etc/os-release; echo "os: $PRETTY_NAME"; uname -r
echo "cpu: $(nproc)"; free -m | head -2; df -h / | tail -1
echo "docker: $(docker --version 2>&1)"; echo "podman: $(podman --version 2>&1)"; echo "python3: $(python3 --version 2>&1)"
echo "systemd: $(systemctl is-system-running 2>&1)"

echo "== end of probe: copy everything between the markers =="
