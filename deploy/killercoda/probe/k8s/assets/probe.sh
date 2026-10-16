#!/bin/bash
# Prints what this Killercoda image really is, to paste into deploy/killercoda/killercoda_envs.yaml (status: measured).
echo "== study-cybercirujas environment probe =="
. /etc/os-release; echo "os: $PRETTY_NAME"; uname -r
echo "cpu: $(nproc)"; free -m | head -2; df -h / | tail -1
echo "docker: $(docker --version 2>&1)"; echo "podman: $(podman --version 2>&1)"; echo "python3: $(python3 --version 2>&1)"
echo "systemd: $(systemctl is-system-running 2>&1)"
if command -v kubectl >/dev/null; then
  until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 2; done
  kubectl version; kubectl get nodes -o wide; kubectl get sc; kubectl get pods -A
  echo "cni binaries: $(ls /opt/cni/bin 2>&1 | tr '\n' ' ')"; ls /etc/cni/net.d 2>&1
  echo "runtime: $(crictl --version 2>&1 | head -1)"
fi
echo "== end of probe: copy everything between the markers =="
