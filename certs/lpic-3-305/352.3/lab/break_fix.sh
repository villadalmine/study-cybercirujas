#!/usr/bin/env bash
#
# break-and-fix.sh — LPIC-3 305 (Exam 305-300, version 3.0)
# Topic 352.3: Docker  (exam weight: 15)
#
# Break & fix drill: the Docker daemon refuses to start after a
# configuration change. Runs on a THROWAWAY lab VM only.
#
# References:
#   - LPI Exam 305 objectives:
#       https://www.lpi.org/our-certifications/exam-305-objectives/
#   - dockerd & daemon.json:
#       https://docs.docker.com/reference/cli/dockerd/
#   - Select a storage driver:
#       https://docs.docker.com/engine/storage/drivers/select-storage-driver/
#
# WARNING: this script STOPS Docker and overwrites /etc/docker/daemon.json
# with a deliberately invalid configuration. Every running container stops.
# Do NOT run it on any host you care about.

set -euo pipefail

CERT="lpic-3-305 (exam 305-300 v3.0)"
TOPIC="352.3 Docker"
DAEMON_JSON="/etc/docker/daemon.json"
STATE_DIR="/var/lib/breakfix/352.3-docker"

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root — this lab edits ${DAEMON_JSON}." >&2
    exit 1
  fi
}

require_tooling() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker CLI not found. Install Docker Engine first." >&2
    exit 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: this lab expects a systemd host managing docker.service." >&2
    exit 1
  fi
}

confirm_disposable() {
  cat <<'EOF'
==========================================================================
  BREAK & FIX LAB  —  LPIC-3 305, Topic 352.3 (Docker)
==========================================================================
This will STOP the Docker daemon and overwrite /etc/docker/daemon.json with
a broken configuration. Every running container will be stopped.

Run this ONLY inside a disposable lab VM you can rebuild from scratch.
EOF
  read -r -p "Type 'break' to proceed: " answer || true
  if [[ "${answer:-}" != "break" ]]; then
    echo "Aborted. Nothing was changed."
    exit 0
  fi
}

# --------------------------------------------------------------------------
# The controlled break: a real dockerd option with an impossible value.
# "storage-driver": "overlayFS" names a graph driver that does not exist,
# so dockerd validates daemon.json at start and aborts. Because
# docker.service uses Restart=always, the unit flaps in "activating".
# --------------------------------------------------------------------------
inject_break() {
  mkdir -p "${STATE_DIR}" /etc/docker

  if [[ -f "${STATE_DIR}/break-active" ]]; then
    echo "A break is already active — keeping the saved original, re-applying."
  else
    if [[ -f "${DAEMON_JSON}" ]]; then
      cp -a "${DAEMON_JSON}" "${STATE_DIR}/daemon.json.orig"
      rm -f "${STATE_DIR}/created-by-lab"
    else
      : > "${STATE_DIR}/created-by-lab"     # marker: we created the file
      rm -f "${STATE_DIR}/daemon.json.orig"
    fi
    : > "${STATE_DIR}/break-active"
  fi

  cat > "${DAEMON_JSON}" <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlayFS"
}
JSON
}

trigger_symptom() {
  echo
  echo "Applying broken configuration and restarting docker.service ..."
  # The restart is EXPECTED to fail; do not let 'set -e' abort the briefing.
  systemctl restart docker >/dev/null 2>&1 || true
  sleep 2
}

# --------------------------------------------------------------------------
# Student briefing
# --------------------------------------------------------------------------
print_briefing() {
  cat <<'EOF'

--------------------------------------------------------------------------
  THE SYMPTOM
--------------------------------------------------------------------------
Docker will not come back up. You will observe things like:

  $ docker ps
  Cannot connect to the Docker daemon at unix:///var/run/docker.sock.
  Is the docker daemon running?

  $ systemctl is-active docker
  activating          # it keeps auto-restarting and failing

  $ systemctl status docker
  ... Active: failed (Result: exit-code) ...
  ... docker.service: Failed with result 'exit-code'.

Nothing else on the host changed. Docker worked minutes ago. No image was
pulled, no container created. ONLY the daemon configuration was touched.

--------------------------------------------------------------------------
  YOUR GOAL
--------------------------------------------------------------------------
Bring the engine back WITHOUT reinstalling Docker and WITHOUT deleting
/var/lib/docker (existing images and volumes must survive).

Success criteria:
  1. systemctl is-active docker        ->  active
  2. docker info                       ->  prints engine info, exit 0
  3. docker run --rm hello-world       ->  runs and exits 0

Hints (open them in order, only if stuck):
  * The CLI only says the socket is unreachable. The REASON is in the
    daemon's journal:
        journalctl -u docker --no-pager -n 40
        journalctl -xeu docker
  * The engine reads exactly one JSON file at start:
        /etc/docker/daemon.json
  * Every key there is a valid dockerd option EXCEPT one value, which
    names a storage/graph driver that does not exist.
  * The modern Linux default driver is 'overlay2' (lower case, digit two).
    Confirm the kernel supports it:  grep -w overlay /proc/filesystems

Verify with the three success criteria above when you think it is fixed.
The full worked solution is at the bottom of this script (commented out).
--------------------------------------------------------------------------
EOF
}

main() {
  require_root
  require_tooling
  confirm_disposable
  echo "[*] Certification : ${CERT}"
  echo "[*] Topic         : ${TOPIC}"
  inject_break
  trigger_symptom
  print_briefing
}

main "$@"

# ==========================================================================
#  SOLUTION — step by step (try it yourself before reading)
# ==========================================================================
#
# 1. Confirm the daemon is down and read WHY. The CLI error only reports an
#    unreachable socket; the real cause is in the unit journal:
#
#        systemctl status docker --no-pager
#        journalctl -xeu docker --no-pager | tail -n 30
#
#    Expect a line similar to:
#
#        failed to start daemon: error initializing graphdriver:
#        driver not supported
#
#    dockerd validates /etc/docker/daemon.json at start; an unknown storage
#    driver is a FATAL error, so systemd (Restart=always) keeps re-launching
#    and failing — the "activating" flap you saw.
#
# 2. Inspect the file the daemon just rejected:
#
#        cat /etc/docker/daemon.json
#
#    Note the offending line:   "storage-driver": "overlayFS"
#    The correct Linux value is "overlay2", or remove the key to let the
#    engine auto-select the default.
#
# 3. Confirm the host can actually run overlay2 before committing to it:
#
#        grep -w overlay /proc/filesystems      # -> "nodev  overlay"
#        modprobe overlay && lsmod | grep overlay
#
#    Supported drivers to recall: overlay2 (default), fuse-overlayfs,
#    btrfs, zfs, vfs (slow fallback), devicemapper (deprecated).
#
# 4. Fix the configuration. Either correct the value:
#
#        sed -i 's/"overlayFS"/"overlay2"/' /etc/docker/daemon.json
#
#    ...or delete the "storage-driver" line entirely to use the default.
#    Then VALIDATE the JSON before restarting (a second common failure mode
#    is a trailing comma or a stray quote):
#
#        python3 -m json.tool /etc/docker/daemon.json >/dev/null && echo OK
#        # newer engines also offer:
#        dockerd --validate --config-file /etc/docker/daemon.json
#
# 5. Restart and prove it is healthy against the three success criteria:
#
#        systemctl restart docker
#        systemctl is-active docker                 # -> active
#        docker info | grep -i 'Storage Driver'     # -> overlay2
#        docker run --rm hello-world
#
# 6. Safety net — this lab saved your previous state. To roll back exactly:
#
#        if [ -f /var/lib/breakfix/352.3-docker/created-by-lab ]; then
#            rm -f /etc/docker/daemon.json
#        else
#            cp -a /var/lib/breakfix/352.3-docker/daemon.json.orig \
#                  /etc/docker/daemon.json
#        fi
#        rm -f /var/lib/breakfix/352.3-docker/break-active
#        systemctl restart docker
#
# WHY THIS MATTERS (the teaching points):
#   * dockerd reads daemon.json once, at start. An option set there must NOT
#     also appear on the systemd ExecStart line (e.g. --storage-driver), or
#     the daemon aborts on a conflicting-option error — check the drop-in:
#         systemctl cat docker
#   * The graph driver is chosen at first start and its data lives under
#     /var/lib/docker/<driver>. Switching drivers HIDES the images stored
#     under the previous one until you switch back — which is exactly why
#     the goal forbids deleting /var/lib/docker.
#   * Because docker.service has Restart=always, a fatal config error looks
#     like a flapping "activating / auto-restart" state, not a clean stop.
#     Diagnose the daemon with `journalctl -u docker`, never with `docker ps`
#     alone.
#
# References:
#   - dockerd & daemon.json:
#       https://docs.docker.com/reference/cli/dockerd/
#   - Select a storage driver:
#       https://docs.docker.com/engine/storage/drivers/select-storage-driver/
#   - LPI Exam 305 objectives:
#       https://www.lpi.org/our-certifications/exam-305-objectives/
# ==========================================================================