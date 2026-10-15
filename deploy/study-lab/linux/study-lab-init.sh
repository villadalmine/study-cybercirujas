#!/usr/bin/env bash
# Waits until systemd finished booting. Idempotent.
set -euo pipefail
for _ in $(seq 1 60); do
  state="$(systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) echo "[study-lab-init] systemd $state"; exit 0 ;; esac
  sleep 1
done
echo "[study-lab-init] systemd did not finish booting (state: ${state:-unknown})"; exit 1
