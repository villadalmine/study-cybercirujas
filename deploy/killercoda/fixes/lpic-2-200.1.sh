#!/usr/bin/env bash
# Reference fix for lpic-2 200.1 (from the lab's commented solution): stop the service, free the deleted file.
set -euo pipefail
systemctl disable --now report-cache.service
# lsof +L1 lists the holder of the deleted file (here a `sleep` started by spool-flusher), whatever its name
lsof +L1 2>/dev/null | awk '/lab-200.1/ {print $2}' | sort -u | xargs -r kill
sleep 2
