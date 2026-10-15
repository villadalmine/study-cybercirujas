#!/usr/bin/env bash
# LPIC-2 200.1 - Measure and Troubleshoot Resource Usage. Break & fix lab.
#
# Contract (docs/LABS-RUNNER.md): break | verify | cleanup, no argument = break.
#   study-lab run lpic-2 200.1      environment (Debian 12, systemd) + break
#   study-lab check lpic-2 200.1    verify: exit 0 only when both faults are fixed
#   study-lab down lpic-2 200.1     cleanup + remove the container
#
# Needs root and systemd as PID 1: the study-lab:linux image gives both. The
# tools it expects (ps, top, vmstat, uptime, w, pstree, lsof) are on LPI's
# list for 200.1 and are in that image (procps, psmisc, lsof).
#
# Two faults, both found by measuring, not by guessing:
#   1. A systemd service burns one CPU in a busy loop and is restarted
#      whenever it is killed (Restart=always). Killing the PID is not a fix.
#   2. A process keeps a 64 MiB file open after it was deleted: df counts the
#      space, du does not find it, and `lsof +L1` shows who holds it.
#
# The solution is at the end of the file, commented out.
set -euo pipefail

UNIT=report-cache.service
WORKER=/usr/local/sbin/report-cache-worker
HOLDER=/usr/local/sbin/spool-flusher
SPOOL=/var/tmp/lab-200.1
MARK=/var/lib/lab-200.1.broken

need_runner() {
  if [[ $EUID -ne 0 || ! -d /run/systemd/system ]]; then
    echo "This lab needs root and systemd as PID 1. Run it with: study-lab run lpic-2 200.1" >&2
    exit 1
  fi
  local tool
  for tool in ps top vmstat uptime w pstree lsof; do
    command -v "$tool" >/dev/null || { echo "missing $tool: apt-get install procps psmisc lsof" >&2; exit 1; }
  done
}

holders() {
  # PIDs with an open file under $SPOOL that has been deleted.
  local fd
  for fd in /proc/[0-9]*/fd/*; do
    if [[ "$(readlink "$fd" 2>/dev/null)" == "$SPOOL/"*" (deleted)" ]]; then
      fd=${fd#/proc/}
      echo "${fd%%/*}"
    fi
  done 2>/dev/null | sort -u
}

do_break() {
  need_runner
  if [[ -f $MARK ]]; then
    echo "Already broken (nothing changed). Fix it, then run: study-lab check lpic-2 200.1"
    return 0
  fi
  install -d -m 0755 "$SPOOL"

  # Fault 1: a CPU burner that systemd brings back.
  cat > "$WORKER" <<'EOF'
#!/bin/bash
# "rebuilds the report cache" - in fact an endless busy loop
while :; do :; done
EOF
  chmod 0755 "$WORKER"
  cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=Report cache refresher

[Service]
ExecStart=$WORKER
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT" >/dev/null 2>&1

  # Fault 2: a deleted file still held open.
  cat > "$HOLDER" <<EOF
#!/bin/bash
# keeps its spool file open forever, after deleting it
exec 3>"$SPOOL/flush.dat"
head -c 67108864 /dev/zero >&3
rm -f "$SPOOL/flush.dat"
exec sleep infinity
EOF
  chmod 0755 "$HOLDER"
  setsid "$HOLDER" </dev/null >/dev/null 2>&1 &
  local i
  for i in $(seq 1 50); do
    [[ -n "$(holders)" ]] && break
    sleep 0.2
  done

  touch "$MARK"
  cat <<'EOF'
BROKEN. Users report two things on this server:
  1. "It is slow": the load average stays near 1 with nobody logged in.
  2. "The disk is filling": df shows the space used, but du cannot find the files.
Measure before you touch anything (uptime, top, vmstat 1 5, ps, pstree, df, du, lsof).
Fix both so they stay fixed, then run: study-lab check lpic-2 200.1
EOF
}

do_verify() {
  need_runner
  local ok=0
  if systemctl is-active --quiet "$UNIT" || systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
    echo "NOT YET: $UNIT is still active or enabled (killing its PID is not enough: Restart=always)."
    ok=1
  elif pgrep -f "$WORKER" >/dev/null; then
    echo "NOT YET: a $WORKER process is still running."
    ok=1
  else
    echo "OK: the CPU burner is stopped and will not come back at boot."
  fi
  if [[ -n "$(holders)" ]]; then
    echo "NOT YET: a process still holds a deleted file under $SPOOL (lsof +L1)."
    ok=1
  else
    echo "OK: no process holds deleted space under $SPOOL."
  fi
  if [[ $ok -eq 0 ]]; then echo "SOLVED"; fi
  return $ok
}

do_cleanup() {
  if [[ -d /run/systemd/system ]]; then
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  fi
  pkill -f "$WORKER" 2>/dev/null || true
  local pid
  for pid in $(holders); do kill "$pid" 2>/dev/null || true; done
  pkill -f "$HOLDER" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT" "$WORKER" "$HOLDER" "$MARK"
  rm -rf "$SPOOL"
  if [[ -d /run/systemd/system ]]; then systemctl daemon-reload; fi
  echo "clean"
}

case "${1:-break}" in
  break) do_break ;;
  verify) do_verify ;;
  cleanup) do_cleanup ;;
  *) echo "usage: $0 [break|verify|cleanup]" >&2; exit 2 ;;
esac

# --- SOLUTION (not executed) -------------------------------------------------
# Measure 1:
#   uptime                      load average climbing towards 1.00 on an idle box
#   vmstat 1 5                  r >= 1 in every sample, us high, id low
#   top -b -n 1 | head -15      report-cache-worker near 100 %CPU
#   pstree -p 1 | grep report   its parent is systemd (PID 1)
#   p=$(systemctl show -p MainPID --value report-cache.service); kill $p; sleep 3
#   systemctl show -p MainPID --value report-cache.service   it is back, new PID
#   systemctl status report-cache.service                 Restart=always
# Fix 1:
#   systemctl disable --now report-cache.service
# Measure 2:
#   df -h /var/tmp ; du -sh /var/tmp   df counts about 64 MiB more than du finds
#   lsof +L1                           spool-flusher holds flush.dat (deleted)
# Fix 2:
#   kill <pid of spool-flusher>        the space is freed when the last fd closes
# Check:
#   study-lab check lpic-2 200.1
