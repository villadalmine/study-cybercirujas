# 101.3 — Change runlevels / boot targets and shutdown or reboot system

**Exam:** LPIC-1 101-500 (v5.0) · **Weight:** 4.69
**Key files, terms and utilities:** `/etc/inittab`, `shutdown`, `init`, `/etc/init.d/`, `telinit`, `systemd`, `systemctl`, `/etc/systemd/`, `/usr/lib/systemd/`, `wall`

---

## Lab environment and safety

> **Run every exercise inside a throwaway VM or a snapshot you can roll back.** Several steps change the default boot target, isolate targets, kill processes and reboot the machine. Never run them on a workstation you depend on, and never on a shared host without a maintenance window.

Recommended lab:

| Node | Purpose | Suggested image |
|---|---|---|
| `node01` | systemd host with a graphical session installed | Rocky Linux 9 / Fedora / Debian 12 |
| `node02` (optional) | second SSH session to observe `wall` broadcasts | any |
| container | read-only inspection of a SysV-style `/etc/inittab` | `docker.io/library/debian:8` or Devuan |

All commands are run as `root` unless noted. Where output is shown, treat it as *representative* — timestamps, PIDs and inode paths will differ on your system. What must match is the **shape** of the output.

---

## Exercise 1 — Map the target space before touching it

**Goal:** describe the running system in systemd's own vocabulary (units, targets, isolatable targets) instead of guessing from runlevel folklore.

1. Confirm that PID 1 really is systemd, and read its version:

   ```console
   # ps -p 1 -o pid,comm,args --no-headers
       1 systemd /usr/lib/systemd/systemd --switched-root --system --deserialize 31
   # systemctl --version | head -n 1
   systemd 252 (252-46.el9)
   ```

2. Ask which target the system boots into by default, and where that answer physically lives:

   ```console
   # systemctl get-default
   graphical.target
   # ls -l /etc/systemd/system/default.target
   lrwxrwxrwx. 1 root root 40 Aug 20 11:02 /etc/systemd/system/default.target -> /usr/lib/systemd/system/graphical.target
   ```

3. List every target unit currently loaded and active:

   ```console
   # systemctl list-units --type=target --state=active --no-pager
   UNIT                   LOAD   ACTIVE SUB    DESCRIPTION
   basic.target           loaded active active Basic System
   cryptsetup.target      loaded active active Local Encrypted Volumes
   getty.target           loaded active active Login Prompts
   graphical.target       loaded active active Graphical Interface
   local-fs.target        loaded active active Local File Systems
   multi-user.target      loaded active active Multi-User System
   network-online.target  loaded active active Network is Online
   ...
   ```

4. Read the definition of `graphical.target` — including any drop-ins — with `systemctl cat`:

   ```console
   # systemctl cat graphical.target
   # /usr/lib/systemd/system/graphical.target
   [Unit]
   Description=Graphical Interface
   Documentation=man:systemd.special(7)
   Requires=multi-user.target
   Wants=display-manager.service
   Conflicts=rescue.service rescue.target
   After=multi-user.target rescue.service rescue.target display-manager.service
   AllowIsolate=yes
   ```

5. Walk the dependency tree downward one level:

   ```console
   # systemctl list-dependencies graphical.target --type=target
   graphical.target
   ● └─multi-user.target
   ●   ├─basic.target
   ●   │ ├─paths.target
   ●   │ ├─slices.target
   ●   │ ├─sockets.target
   ●   │ ├─sysinit.target
   ●   │ └─timers.target
   ●   ├─getty.target
   ●   ├─nfs-client.target
   ●   └─remote-fs.target
   ```

6. Find out which targets are legal arguments to `isolate`:

   ```console
   # grep -l 'AllowIsolate=yes' /usr/lib/systemd/system/*.target
   /usr/lib/systemd/system/emergency.target
   /usr/lib/systemd/system/graphical.target
   /usr/lib/systemd/system/multi-user.target
   /usr/lib/systemd/system/rescue.target
   ...
   ```

**Check your understanding**

- **Q1.1** `graphical.target` declares `Requires=multi-user.target` *and* `After=multi-user.target`. What would break if the unit only had `Requires=` and not `After=`?
- **Q1.2** Why does `default.target` live under `/etc/systemd/system/` rather than `/usr/lib/systemd/system/`, and what does that tell you about how a package upgrade will treat your choice?
- **Q1.3** `graphical.target` says `Wants=display-manager.service`. If GDM fails to start, will `graphical.target` still be reached? Justify with the semantics of `Wants=` vs `Requires=`.
- **Q1.4** `basic.target` appears under `multi-user.target`, not the other way around. What does that ordering say about where you should hook a unit that needs the network *and* local filesystems?

---

## Exercise 2 — Change the default boot target and prove it took effect

**Goal:** perform the exam's core task — set the default boot target — and verify it by inspecting the artefact rather than trusting the command's exit status.

1. Record the current state so you can restore it:

   ```console
   # systemctl get-default > /root/original-default-target.txt
   # cat /root/original-default-target.txt
   graphical.target
   ```

2. Change the default to a text-mode boot:

   ```console
   # systemctl set-default multi-user.target
   Removed "/etc/systemd/system/default.target".
   Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/multi-user.target.
   ```

3. Verify twice — once through the API, once on disk:

   ```console
   # systemctl get-default
   multi-user.target
   # readlink -f /etc/systemd/system/default.target
   /usr/lib/systemd/system/multi-user.target
   ```

4. Confirm this changed **only** the next boot, not the running system:

   ```console
   # systemctl is-active graphical.target
   active
   ```

5. Now make the same change by hand, the way you would on a rescue shell where `systemctl` cannot talk to PID 1:

   ```console
   # rm -f /etc/systemd/system/default.target
   # ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
   # systemctl get-default
   graphical.target
   ```

6. Try to set a target that is not isolatable and read the refusal carefully:

   ```console
   # systemctl set-default basic.target
   Removed "/etc/systemd/system/default.target".
   Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/basic.target.
   # systemctl isolate basic.target
   Failed to isolate basic.target: Operation refused, unit basic.target may be requested by dependency only (it is configured to refuse manual start/stop).
   ```

7. Restore the original default before continuing:

   ```console
   # systemctl set-default "$(cat /root/original-default-target.txt)"
   ```

**Check your understanding**

- **Q2.1** Step 5 produced the identical result with `ln -sf`. Under what circumstances is the manual symlink the *only* option?
- **Q2.2** Step 6 shows that `set-default` happily accepted `basic.target` even though it cannot be isolated. What happens at the next boot, and what does this teach you about `set-default`'s validation?
- **Q2.3** A colleague edits `/usr/lib/systemd/system/default.target` directly. Give two independent reasons why this is wrong.
- **Q2.4** After `systemctl set-default multi-user.target`, does `systemctl daemon-reload` need to be run for the change to survive a reboot? Why or why not?

---

## Exercise 3 — Switch targets at runtime, including single-user mode

**Goal:** change the *running* system's target and understand what `isolate` stops, not just what it starts.

> Do this from a **physical/virtual console**, not over SSH. `systemctl isolate multi-user.target` from a graphical session kills your desktop; `systemctl rescue` will drop your SSH connection.

1. Note the current target and the set of running services, so you can diff afterwards:

   ```console
   # systemctl list-units --type=service --state=running --no-legend | wc -l
   38
   # systemctl is-active graphical.target
   active
   ```

2. Switch the live system to text mode:

   ```console
   # systemctl isolate multi-user.target
   ```

3. From tty2, verify the transition and count services again:

   ```console
   # systemctl is-active graphical.target
   inactive
   # systemctl is-active multi-user.target
   active
   # systemctl list-units --type=service --state=running --no-legend | wc -l
   24
   # systemctl status gdm.service | head -n 4
   ○ gdm.service - GNOME Display Manager
        Loaded: loaded (/usr/lib/systemd/system/gdm.service; enabled; preset: enabled)
        Active: inactive (dead) since Tue 2026-08-25 10:07:11 -03; 42s ago
   ```

4. Inspect the queued/finished jobs of the transition:

   ```console
   # systemctl list-jobs
   No jobs running.
   ```

5. Go back to graphical mode:

   ```console
   # systemctl isolate graphical.target
   ```

6. Enter rescue mode (single-user equivalent). You will be prompted for the root password on the console:

   ```console
   # systemctl rescue
   Broadcast message from root@node01 (Tue 2026-08-25 10:11:44 -03):

   The system will now be rebooted into rescue mode!
   ```

   On the console:

   ```
   You are in rescue mode. After logging in, type "journalctl -xb" to view
   system logs, "systemctl reboot" to reboot, or "exit" to boot into default mode.
   Give root password for maintenance
   (or press Control-D to continue):
   ```

7. Inside rescue mode, verify the reduced environment:

   ```console
   # systemctl is-active rescue.target
   active
   # systemctl list-units --type=service --state=running --no-legend
     dbus-broker.service   loaded active running D-Bus System Message Bus
     systemd-journald.service loaded active running Journal Service
     systemd-udevd.service loaded active running Rule-based Manager for Device Events and Files
   # findmnt -no SOURCE,TARGET,OPTIONS /
   /dev/mapper/rl-root / rw,relatime,seclabel
   # ip -brief addr show
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   enp1s0           DOWN
   ```

8. Suppress the emergency prompt's password requirement question by comparing to `emergency.target` without entering it:

   ```console
   # systemctl cat emergency.target | sed -n '1,20p'
   # /usr/lib/systemd/system/emergency.target
   [Unit]
   Description=Emergency Mode
   Documentation=man:systemd.special(7)
   Requires=emergency.service
   After=emergency.service
   AllowIsolate=yes
   ```

9. Return to the default target:

   ```console
   # systemctl default
   ```

**Check your understanding**

- **Q3.1** In step 3, `gdm.service` is `inactive (dead)` but still `enabled`. Explain the difference between those two words and why `isolate` did not disable anything.
- **Q3.2** What exactly does `isolate` do that `systemctl start multi-user.target` does not?
- **Q3.3** In rescue mode the root filesystem is mounted `rw` and the network is down. In *emergency* mode, what changes about the filesystem, and what single command do you usually need before you can edit `/etc/fstab` there?
- **Q3.4** Why is running `systemctl isolate multi-user.target` over SSH a bad idea, and what makes `systemctl rescue` even worse over SSH?
- **Q3.5** You are in rescue mode and press `Ctrl-D` at the maintenance prompt. What happens, and which unit did that prompt come from?

---

## Exercise 4 — SysV compatibility: `runlevel`, `telinit`, `/etc/inittab`, `/etc/init.d/`

**Goal:** read the classic init vocabulary that the exam still tests, and see precisely how systemd emulates it.

1. Ask the classic questions on a systemd host:

   ```console
   # runlevel
   N 5
   # who -r
            run-level 5  2026-08-25 09:14
   ```

   > **Diagnostic note:** on very recent systemd releases `utmp` support is deprecated/disabled, and `runlevel` may print `unknown`. In that case the authoritative answers are `systemctl get-default` and `systemctl list-units --type=target`.

2. Expose the compatibility layer — runlevel targets are symlinks:

   ```console
   # ls -l /usr/lib/systemd/system/runlevel?.target
   lrwxrwxrwx. 1 root root 15 Jul  3 00:00 /usr/lib/systemd/system/runlevel0.target -> poweroff.target
   lrwxrwxrwx. 1 root root 13 Jul  3 00:00 /usr/lib/systemd/system/runlevel1.target -> rescue.target
   lrwxrwxrwx. 1 root root 17 Jul  3 00:00 /usr/lib/systemd/system/runlevel2.target -> multi-user.target
   lrwxrwxrwx. 1 root root 17 Jul  3 00:00 /usr/lib/systemd/system/runlevel3.target -> multi-user.target
   lrwxrwxrwx. 1 root root 17 Jul  3 00:00 /usr/lib/systemd/system/runlevel4.target -> multi-user.target
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /usr/lib/systemd/system/runlevel5.target -> graphical.target
   lrwxrwxrwx. 1 root root 13 Jul  3 00:00 /usr/lib/systemd/system/runlevel6.target -> reboot.target
   ```

3. Confirm that `telinit` and `init` are themselves compatibility shims:

   ```console
   # ls -l /sbin/telinit /sbin/init
   lrwxrwxrwx. 1 root root 22 Jul  3 00:00 /sbin/init -> ../lib/systemd/systemd
   lrwxrwxrwx. 1 root root 21 Jul  3 00:00 /sbin/telinit -> ../bin/systemctl
   ```

4. From a console, switch runlevels the old way and watch what systemd actually does:

   ```console
   # telinit 3
   # systemctl is-active multi-user.target
   active
   # runlevel
   5 3
   ```

5. Read a genuine SysV `/etc/inittab` — either from a legacy container or from this reference copy. Save it as `/root/inittab.sample` and study it:

   ```
   # /etc/inittab — SysV init (RHEL 6 style)
   id:5:initdefault:
   si::sysinit:/etc/rc.d/rc.sysinit

   l0:0:wait:/etc/rc.d/rc 0
   l1:1:wait:/etc/rc.d/rc 1
   l2:2:wait:/etc/rc.d/rc 2
   l3:3:wait:/etc/rc.d/rc 3
   l5:5:wait:/etc/rc.d/rc 5
   l6:6:wait:/etc/rc.d/rc 6

   ca::ctrlaltdel:/sbin/shutdown -t3 -r now
   pf::powerfail:/sbin/shutdown -f -h +2 "Power Failure; System Shutting Down"
   pr:12345:powerokwait:/sbin/shutdown -c "Power Restored; Shutdown Cancelled"

   1:2345:respawn:/sbin/mingetty tty1
   2:2345:respawn:/sbin/mingetty tty2
   x:5:respawn:/etc/X11/prefdm -nodaemon
   ```

6. Decompose the record format with a one-liner so the four fields are unmistakable:

   ```console
   # awk -F: '!/^#/ && NF>=4 {printf "id=%-3s runlevels=%-6s action=%-12s process=%s\n", $1,$2,$3,$4}' /root/inittab.sample
   id=id  runlevels=5     action=initdefault  process=
   id=si  runlevels=      action=sysinit      process=/etc/rc.d/rc.sysinit
   id=l3  runlevels=3     action=wait         process=/etc/rc.d/rc 3
   id=ca  runlevels=      action=ctrlaltdel   process=/sbin/shutdown -t3 -r now
   id=1   runlevels=2345  action=respawn      process=/sbin/mingetty tty1
   ```

7. Inspect the SysV script directories still present on your distribution:

   ```console
   # ls -l /etc/init.d/ 2>/dev/null | head
   # ls -l /etc/rc3.d/ 2>/dev/null | head
   lrwxrwxrwx 1 root root 17 Aug 20 11:02 K01apache2 -> ../init.d/apache2
   lrwxrwxrwx 1 root root 14 Aug 20 11:02 S01cron -> ../init.d/cron
   lrwxrwxrwx 1 root root 14 Aug 20 11:02 S01ssh -> ../init.d/ssh
   ```

8. Find systemd's replacement for the `ctrlaltdel` line, and mask it on a server where an accidental keypress must not reboot the box:

   ```console
   # systemctl cat ctrl-alt-del.target | head -n 3
   # /usr/lib/systemd/system/reboot.target
   [Unit]
   Description=Reboot
   # systemctl mask ctrl-alt-del.target
   Created symlink /etc/systemd/system/ctrl-alt-del.target → /dev/null.
   # systemctl unmask ctrl-alt-del.target
   Removed "/etc/systemd/system/ctrl-alt-del.target".
   ```

**Check your understanding**

- **Q4.1** In step 4, `runlevel` printed `5 3`. Name each field.
- **Q4.2** Name the four colon-separated fields of an `/etc/inittab` record, and explain why the `initdefault` record's fourth field is empty.
- **Q4.3** Why must `id:0:initdefault:` and `id:6:initdefault:` never be written?
- **Q4.4** In classic SysV, which command makes `init` re-read `/etc/inittab` without rebooting, and what is its systemd counterpart?
- **Q4.5** In `/etc/rc3.d/`, explain the meaning of the `S`/`K` prefix and of the two digits, and say which runlevel-3 action `K01apache2` encodes.
- **Q4.6** `respawn` on the `mingetty` lines — what does it guarantee, and what does `init` do if the process exits immediately in a tight loop?
- **Q4.7** On a systemd host, what is the concrete effect of editing `/etc/inittab` and setting `id:3:initdefault:`?

---

## Exercise 5 — Alert users before a disruptive event

**Goal:** meet the objective "alert users before switching runlevels or other major system events" with the actual tooling, and know which channel reaches whom.

Open a second, unprivileged session (`node02` or another tty) logged in as a normal user; leave it visible.

1. Send an immediate broadcast and observe it in the other session:

   ```console
   # wall "Maintenance window opens in 15 minutes. Please save your work."
   ```

   In the user's session:

   ```
   Broadcast message from root@node01 (pts/0) (Tue Aug 25 10:14:31 2026):

   Maintenance window opens in 15 minutes. Please save your work.
   ```

2. Send a longer notice from a file, and suppress the banner line:

   ```console
   # cat > /root/notice.txt <<'EOF'
   Scheduled kernel upgrade — node01
   Start:  10:30  End (expected): 10:45
   Impact: all sessions terminated; NFS exports unavailable.
   EOF
   # wall -n /root/notice.txt
   ```

3. Show that `mesg` controls reception — but not for `root`:

   ```console
   $ tty
   /dev/pts/2
   $ mesg
   is y
   $ mesg n
   $ mesg
   is n
   ```

   Now broadcast again as root and as an unprivileged user, and compare who sees it.

4. Schedule a real shutdown with a warning window, and read the automatic broadcast:

   ```console
   # shutdown -h +10 "Kernel upgrade; the node returns at 10:45"
   Shutdown scheduled for Tue 2026-08-25 10:24:31 -03, use 'shutdown -c' to cancel.
   ```

   Other sessions receive:

   ```
   Broadcast message from root@node01 (Tue 2026-08-25 10:14:31 -03):

   Kernel upgrade; the node returns at 10:45

   The system is going down for poweroff at Tue 2026-08-25 10:24:31 -03!
   ```

5. Inspect where the scheduled action is recorded:

   ```console
   # cat /run/systemd/shutdown/scheduled
   USEC=1787670271000000
   WARN_WALL=1
   MODE=poweroff
   WALL_MESSAGE=Kernel upgrade; the node returns at 10:45
   # systemctl list-jobs
   No jobs running.
   ```

6. Cancel it before it fires:

   ```console
   # shutdown -c
   ```

   ```
   Broadcast message from root@node01 (Tue 2026-08-25 10:16:02 -03):

   The system shutdown has been cancelled at Tue 2026-08-25 10:17:02 -03!
   ```

7. Warn without committing — the "nag only" form:

   ```console
   # shutdown -k +5 "Rehearsal only: no shutdown will occur"
   ```

8. Test the login lockout that a scheduled shutdown produces. Schedule one four minutes out, then try to log in from `node02`:

   ```console
   # shutdown -h +4 "lockout test"
   # sleep 90; ls -l /run/nologin
   -rw-r--r--. 1 root root 55 Aug 25 10:19 /run/nologin
   # cat /run/nologin
   System is going down. Unprivileged users are not permitted to log in anymore. For technical details, see pam_nologin(8).
   ```

   From `node02`:

   ```console
   $ ssh alice@node01
   alice@node01's password:
   System is going down. Unprivileged users are not permitted to log in anymore.
   Connection closed by 192.0.2.11 port 22
   ```

9. Cancel and confirm the lockout file is removed:

   ```console
   # shutdown -c
   # ls -l /run/nologin
   ls: cannot access '/run/nologin': No such file or directory
   ```

**Check your understanding**

- **Q5.1** `wall` from `root` reached the session that had run `mesg n`. Why, and what is the security reasoning behind that exception?
- **Q5.2** Distinguish `wall`, `write` and `/etc/motd` by *when* each one reaches the user.
- **Q5.3** What does `shutdown -k` do, and what is the operational reason to use it before a real window?
- **Q5.4** Which component creates `/run/nologin`, how far ahead of the deadline, and which PAM module enforces it? Name the traditional SysV path for the same file.
- **Q5.5** `root` could still log in during the lockout in step 8. Is that a bug? Explain from the semantics of `pam_nologin`.
- **Q5.6** You scheduled `shutdown -h +60` yesterday from an SSH session that has since disconnected. How do you find out whether it is still pending, and how do you cancel it?

---

## Exercise 6 — Shutdown, reboot, halt, poweroff and their systemd equivalents

**Goal:** stop conflating the five commands, and know which ones skip the orderly stop of services.

1. Build the equivalence table empirically. First, confirm what the legacy names actually are:

   ```console
   # ls -l /sbin/shutdown /sbin/reboot /sbin/halt /sbin/poweroff
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /sbin/halt -> ../bin/systemctl
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /sbin/poweroff -> ../bin/systemctl
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /sbin/reboot -> ../bin/systemctl
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /sbin/shutdown -> ../bin/systemctl
   ```

2. Practise the time argument forms without executing them, by scheduling and immediately cancelling each:

   ```console
   # shutdown -r +1  "reboot in one minute";      shutdown -c
   # shutdown -h 23:30 "power-off tonight";       shutdown -c
   # shutdown -P +2  "explicit power-off";        shutdown -c
   # shutdown -H +2  "halt, do not cut power";    shutdown -c
   ```

3. Compare `halt` and `poweroff` semantics on the ACPI level:

   ```console
   # systemctl cat halt.target | sed -n '1,12p'
   # /usr/lib/systemd/system/halt.target
   [Unit]
   Description=Halt
   Documentation=man:systemd.special(7)
   DefaultDependencies=no
   Requires=systemd-halt.service
   After=systemd-halt.service
   AllowIsolate=yes
   JobTimeoutSec=30min
   JobTimeoutAction=poweroff-force
   ```

4. Check what is currently blocking a shutdown (inhibitor locks):

   ```console
   # systemd-inhibit --list
   WHO             UID USER PID  COMM            WHAT                    WHY                                              MODE
   NetworkManager  0   root 1123 NetworkManager  sleep                   NetworkManager needs to turn off networks        block
   UPower          0   root 1301 upowerd         sleep                   Pause device polling                             delay
   alice           1000 alice 4102 gnome-session shutdown:sleep:idle     User session inhibited                           block

   3 inhibitors listed.
   ```

5. Take an inhibitor lock yourself and observe a non-root shutdown attempt being refused:

   ```console
   # systemd-inhibit --what=shutdown --who="dbadmin" --why="pg_basebackup in progress" --mode=block sleep 300 &
   [1] 4711
   # systemd-inhibit --list | grep dbadmin
   dbadmin  0  root  4711  systemd-inhibit  shutdown  pg_basebackup in progress  block
   ```

   As a normal user:

   ```console
   $ systemctl poweroff
   Operation inhibited by "dbadmin" (PID 4711 "systemd-inhibit", user root), reason is "pg_basebackup in progress".
   Please retry operation after closing inhibitors and logging out other users.
   Alternatively, ignore inhibitors and users with 'systemctl poweroff -i'.
   ```

6. Kill the lock and confirm it is gone:

   ```console
   # kill %1
   # systemd-inhibit --list | grep -c dbadmin
   0
   ```

7. Read — do **not** run — the force variants, and be able to explain each:

   ```console
   # systemctl reboot            # orderly: stop all units, unmount, then reboot
   # systemctl reboot -i         # orderly, but ignore inhibitors and logged-in users
   # systemctl reboot -f         # skip the orderly stop of units; still sync/unmount
   # systemctl reboot -ff        # immediate reboot(2); no unmount, no sync — data loss risk
   ```

8. Reboot the machine cleanly and time the shutdown phase from the journal of the previous boot:

   ```console
   # systemctl reboot
   ```

   After it comes back:

   ```console
   # journalctl -b -1 -o short-precise | tail -n 8
   Aug 25 10:41:22.118 node01 systemd[1]: Reached target Unmount All Filesystems.
   Aug 25 10:41:22.140 node01 systemd[1]: Reached target Late Shutdown Services.
   Aug 25 10:41:22.152 node01 systemd[1]: Finished System Reboot.
   Aug 25 10:41:22.160 node01 systemd[1]: Shutting down.
   Aug 25 10:41:22.310 node01 systemd-shutdown[1]: Syncing filesystems and block devices.
   Aug 25 10:41:22.480 node01 systemd-shutdown[1]: Sending SIGTERM to remaining processes...
   Aug 25 10:41:22.610 node01 systemd-shutdown[1]: Sending SIGKILL to remaining processes...
   Aug 25 10:41:23.004 node01 systemd-shutdown[1]: Rebooting.
   ```

**Check your understanding**

- **Q6.1** Write the single command for each: (a) reboot in 5 minutes with a message; (b) power off at 02:00; (c) reboot immediately; (d) cancel a pending shutdown.
- **Q6.2** `shutdown -h now` — does it halt or power off? Explain the `-h`/`-H`/`-P` relationship in the systemd implementation.
- **Q6.3** In step 3, `halt.target` carries `JobTimeoutAction=poweroff-force`. What real-world failure is that line defending against?
- **Q6.4** A user runs `systemctl poweroff` and gets "Operation inhibited". Give two legitimate ways to proceed and say which one you would choose on a production database node.
- **Q6.5** Explain the practical difference between `systemctl reboot -f` and `systemctl reboot -ff`, and name the one situation where `-ff` is the correct choice.
- **Q6.6** `shutdown` is a symlink to `systemctl`, yet `shutdown -h +5` works and `systemctl -h +5` does not. How does one binary implement several behaviours?

---

## Exercise 7 — Properly terminate processes

**Goal:** the second half of the objective. Signals, the escalation ladder, and the cases where killing does not work.

1. List the signals and locate the four that matter for this objective:

   ```console
   # kill -l | head -n 4
    1) SIGHUP       2) SIGINT       3) SIGQUIT      4) SIGILL       5) SIGTRAP
    6) SIGABRT      7) SIGBUS       8) SIGFPE       9) SIGKILL     10) SIGUSR1
   11) SIGSEGV     12) SIGUSR2     13) SIGPIPE     14) SIGALRM     15) SIGTERM
   16) SIGSTKFLT   17) SIGCHLD     18) SIGCONT     19) SIGSTOP     20) SIGTSTP
   ```

2. Start a controlled victim process and find it every way the exam asks:

   ```console
   # sleep 3000 &
   [1] 5120
   # pgrep -a sleep
   5120 sleep 3000
   # pidof sleep
   5120
   # ps -o pid,ppid,stat,cmd -p 5120
       PID    PPID STAT CMD
      5120    4800 S    sleep 3000
   ```

3. Practise the escalation ladder — polite first:

   ```console
   # kill 5120                      # implicit SIGTERM (15)
   # kill -0 5120 2>&1 || echo "gone"
   bash: kill: (5120) - No such process
   gone
   ```

4. Demonstrate a process that *ignores* SIGTERM, so escalation is required:

   ```console
   # cat > /usr/local/sbin/stubborn.sh <<'EOF'
   #!/bin/bash
   trap '' TERM
   echo "stubborn pid $$ ignoring SIGTERM"
   while :; do sleep 5; done
   EOF
   # chmod 755 /usr/local/sbin/stubborn.sh
   # /usr/local/sbin/stubborn.sh &
   [1] 5233
   stubborn pid 5233 ignoring SIGTERM
   # kill 5233; sleep 1; kill -0 5233 && echo "still alive"
   still alive
   # kill -9 5233; sleep 1; kill -0 5233 2>/dev/null || echo "killed"
   killed
   ```

5. Use the name-based tools, and note the difference between matching the command and matching the full command line:

   ```console
   # sleep 4000 & sleep 4001 &
   # killall sleep
   # sleep 5000 &
   # pkill -f "sleep 5000"
   # pkill -u alice                  # every process owned by alice
   # pkill -HUP -x sshd              # exact name match, reload config
   ```

6. Show the two categories of process that resist `kill -9`:

   ```console
   # ps -eo pid,ppid,stat,cmd | awk '$3 ~ /^Z/'
      5310    5299 Z    [defunct-child] <defunct>
   # ps -eo pid,stat,wchan:24,cmd | awk '$2 ~ /D/'
      5401 D    nfs_wait_bit_killable  /usr/bin/cp /mnt/nfs/big.img /tmp/
   ```

7. Now the systemd-aware version. Kill a *service* process and watch supervision undo you:

   ```console
   # systemctl show sshd.service -p Restart -p KillMode -p TimeoutStopUSec
   Restart=on-failure
   KillMode=process
   TimeoutStopUSec=1min 30s
   # systemd-cgls -u sshd.service
   Unit sshd.service (/system.slice/sshd.service):
   └─1187 "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups"
   # kill -9 1187
   # sleep 2; systemctl is-active sshd.service
   active
   ```

8. Do it correctly — through the unit, and with a targeted signal:

   ```console
   # systemctl stop stubborn.service          # orderly: SIGTERM → wait → SIGKILL
   # systemctl kill --signal=SIGHUP sshd.service
   # systemctl kill --signal=SIGKILL --kill-whom=all stubborn.service
   ```

   > On systemd older than v252 the option is spelled `--kill-who`.

9. Watch the stop timeout escalate, using the stubborn process as a unit:

   ```console
   # cat > /etc/systemd/system/stubborn.service <<'EOF'
   [Unit]
   Description=Stubborn demo daemon that ignores SIGTERM

   [Service]
   Type=simple
   ExecStart=/usr/local/sbin/stubborn.sh
   TimeoutStopSec=15
   KillMode=control-group
   EOF
   # systemctl daemon-reload
   # systemctl start stubborn.service
   # time systemctl stop stubborn.service
   real    0m15.048s
   # journalctl -u stubborn.service -n 6 --no-pager
   Aug 25 10:41:07 node01 systemd[1]: Stopping Stubborn demo daemon that ignores SIGTERM...
   Aug 25 10:41:22 node01 systemd[1]: stubborn.service: State 'stop-sigterm' timed out. Killing.
   Aug 25 10:41:22 node01 systemd[1]: stubborn.service: Killing process 5512 (stubborn.sh) with signal SIGKILL.
   Aug 25 10:41:22 node01 systemd[1]: stubborn.service: Main process exited, code=killed, status=9/KILL
   Aug 25 10:41:22 node01 systemd[1]: stubborn.service: Failed with result 'timeout'.
   Aug 25 10:41:22 node01 systemd[1]: Stopped Stubborn demo daemon that ignores SIGTERM.
   ```

10. Read the system-wide default that governs every unit without an explicit `TimeoutStopSec=`:

    ```console
    # grep -E '^#?Default(Timeout|Restart)' /etc/systemd/system.conf
    #DefaultTimeoutStartSec=90s
    #DefaultTimeoutStopSec=90s
    #DefaultRestartSec=100ms
    ```

11. Clean up:

    ```console
    # systemctl disable --now stubborn.service
    # rm -f /etc/systemd/system/stubborn.service /usr/local/sbin/stubborn.sh
    # systemctl daemon-reload
    ```

**Check your understanding**

- **Q7.1** Why is `kill -9` the wrong first move on a database process? Describe what SIGTERM lets a well-written daemon do that SIGKILL does not.
- **Q7.2** Give the numeric value and the customary meaning of SIGHUP, SIGTERM and SIGKILL, and name the two signals a process can never catch, block or ignore.
- **Q7.3** In step 6, one process is `Z` and one is `D`. For each, explain why `kill -9` has no effect and what the correct remedy is.
- **Q7.4** In step 7, `kill -9 1187` did not remove sshd from the system. Which two unit properties explain that, and what is the correct command to actually stop the service?
- **Q7.5** `killall sleep` vs `pkill -f "sleep 5000"` — describe a scenario where the first is dangerous and the second is safe.
- **Q7.6** A shutdown takes exactly 90 seconds longer than it should, every time. Name the two settings you would inspect first and the journal line that would confirm your hypothesis.
- **Q7.7** Explain `KillMode=process` versus `KillMode=control-group`, and why `process` is risky for a daemon that forks workers.

---

## Exercise 8 — Boot-time target selection and shutdown diagnostics

**Goal:** recover a machine whose default target is wrong, and quantify boot/shutdown time.

1. Reboot into the GRUB menu, highlight the default entry, press **`e`**, and locate the `linux` line:

   ```
   linux ($root)/vmlinuz-5.14.0-427.el9.x86_64 root=/dev/mapper/rl-root ro rd.lvm.lv=rl/root rhgb quiet
   ```

2. Append a one-shot target override at the end of that line, then boot with **`Ctrl-X`**:

   ```
   ... rd.lvm.lv=rl/root ro systemd.unit=rescue.target
   ```

3. Once booted, prove the override applied and that it was not persisted:

   ```console
   # systemctl is-active rescue.target
   active
   # cat /proc/cmdline
   BOOT_IMAGE=(hd0,gpt2)/vmlinuz-5.14.0-427.el9.x86_64 root=/dev/mapper/rl-root ro rd.lvm.lv=rl/root systemd.unit=rescue.target
   # systemctl get-default
   graphical.target
   ```

4. Repeat with the SysV-compatible spellings and confirm they land in the same place:

   ```
   ... ro single
   ... ro 1
   ... ro 3
   ```

5. Now the last-resort form. Boot with `init=/bin/bash`, and note what you must do before you can write anything:

   ```console
   bash-5.1# findmnt -no OPTIONS /
   ro,relatime,seclabel
   bash-5.1# mount -o remount,rw /
   bash-5.1# passwd root
   bash-5.1# touch /.autorelabel          # required on SELinux systems
   bash-5.1# exec /sbin/reboot -f
   ```

6. Back in the normal system, measure boot:

   ```console
   # systemd-analyze
   Startup finished in 1.905s (kernel) + 3.114s (initrd) + 21.488s (userspace) = 26.508s
   graphical.target reached after 21.401s in userspace.
   # systemd-analyze blame | head -n 5
           9.612s NetworkManager-wait-online.service
           4.031s dnf-makecache.service
           1.882s systemd-udev-settle.service
            921ms firewalld.service
            402ms lvm2-monitor.service
   # systemd-analyze critical-chain graphical.target
   graphical.target @21.401s
   └─multi-user.target @21.400s
     └─sshd.service @2.109s +48ms
       └─network.target @2.106s
         └─NetworkManager.service @1.771s +333ms
   ```

7. Find anything that failed during the last transition:

   ```console
   # systemctl --failed
     UNIT                LOAD   ACTIVE SUB    DESCRIPTION
   ● stubborn.service    loaded failed failed Stubborn demo daemon that ignores SIGTERM

   1 loaded units listed.
   # journalctl -b -p err --no-pager | tail -n 5
   ```

8. Enable shutdown-time logging when a power-off hangs and you cannot see why:

   ```console
   # systemd-analyze log-level debug
   # mkdir -p /run/initramfs; systemctl reboot
   ```

   After the reboot, read the previous boot's tail:

   ```console
   # journalctl -b -1 -o short-precise | grep -E 'systemd-shutdown|Unmount|timed out' | tail
   # systemd-analyze log-level info
   ```

**Check your understanding**

- **Q8.1** `systemd.unit=rescue.target` on the kernel command line versus `systemctl set-default rescue.target` — state the two differences that matter operationally.
- **Q8.2** Why is the root filesystem read-only under `init=/bin/bash`, and which single command makes it writable?
- **Q8.3** Under `init=/bin/bash`, why must you use `exec /sbin/reboot -f` rather than plain `reboot`?
- **Q8.4** `systemd-analyze blame` lists `NetworkManager-wait-online.service` at 9.6 s. Is that unit "slow"? Explain why `blame` alone can mislead and which command corrects the picture.
- **Q8.5** You forgot the root password and the machine uses SELinux in enforcing mode. Which extra step is mandatory after `passwd root` in a `init=/bin/bash` shell, and what happens if you skip it?
- **Q8.6** A poweroff hangs after "Reached target Unmount All Filesystems." Outline the diagnostic path using the tools in this exercise.

---

## Exercise 9 — Consolidation drill

Perform these end to end without consulting the earlier sections. Each line is one command or a short pipeline.

1. Report the default boot target and the physical file that encodes it.
2. Change the default to text mode, verify, and restore the original in a single reversible sequence.
3. Warn all logged-in users, then schedule a reboot 12 minutes out with an explanatory message.
4. From another terminal, discover that a shutdown is pending, read its scheduled time and mode, and cancel it.
5. Switch the running system to `multi-user.target` and back, from tty2.
6. Determine the current and previous runlevel using two different commands.
7. Take an inhibitor lock named `backup` for 10 minutes, prove a non-root `systemctl poweroff` is refused, then release it.
8. Start a process that ignores SIGTERM, terminate it correctly using escalation, and prove it is gone.
9. Find every unit that failed during the current boot and print the error lines for one of them.
10. Boot once into rescue mode without changing any file on disk.

**Check your understanding**

- **Q9.1** Write out your command for each of the ten items and compare against the answers.

---

<details>
<summary><b>Answers</b> — expand only after attempting every exercise</summary>

### Exercise 1

**A1.1** `Requires=` is a *dependency* relation only: it says multi-user.target must be pulled in and must succeed, but it says nothing about *when*. Without `After=`, systemd would start both targets in parallel, so the display manager could be launched before local filesystems, the network and the multi-user services were up — producing an intermittent, load-dependent boot failure. Ordering (`After=`/`Before=`) and requirement (`Requires=`/`Wants=`) are orthogonal in systemd, and both are almost always needed together.

**A1.2** `/usr/lib/systemd/system/` is vendor territory: RPM/DEB packages own it and will overwrite it on upgrade. `/etc/systemd/system/` is administrator territory and takes precedence. Because `set-default` writes the symlink under `/etc`, your choice of boot target survives package upgrades of systemd itself. This is the same precedence rule that makes drop-ins under `/etc/systemd/system/<unit>.d/*.conf` the correct way to customise a vendor unit.

**A1.3** Yes, the target is still reached. `Wants=` is a *weak* requirement: systemd attempts to start the dependency, but its failure does not fail the depending unit. Had it been `Requires=`, a failed `gdm.service` would have caused `graphical.target` to fail as well. In practice: on a broken GDM you end up at a text console with `graphical.target` active — which is exactly why "the target is active" is not the same statement as "the desktop works".

**A1.4** `basic.target` is a *dependency of* `multi-user.target`, i.e. it is reached earlier. It marks the point where sockets, timers, paths, slices and `sysinit.target` are up, but not yet the network-dependent services. A unit that needs the network and local filesystems should order itself `After=network-online.target local-fs.target` and be pulled in by `multi-user.target` — not hook into `basic.target`, which is too early.

### Exercise 2

**A2.1** When PID 1 is not reachable over D-Bus: an offline system mounted from a rescue ISO or an initramfs shell, a chroot, a container image being prepared, or an `init=/bin/bash` emergency shell. `systemctl set-default` needs to talk to the running manager; `ln -sf` only needs a writable filesystem.

**A2.2** At the next boot systemd will try to isolate `basic.target`, which is configured with `AllowIsolate=no`; the boot stalls or drops to emergency mode. The lesson: `set-default` performs essentially no semantic validation — it only creates a symlink. Validating that the chosen target is isolatable (`AllowIsolate=yes`) is *your* job, and step 6's `isolate` refusal is the cheap way to test it before rebooting.

**A2.3** (a) The file is package-owned; the next `dnf`/`apt` upgrade of systemd silently reverts the change, producing a machine whose behaviour changes at an unrelated time. (b) `default.target` under `/usr/lib` is normally itself a symlink shipped by the distribution; editing it breaks the documented `/etc` override mechanism and makes the configuration invisible to anyone who inspects `/etc/systemd/system/` — the first place a colleague will look.

**A2.4** No. `daemon-reload` re-reads unit *files* into the running manager. `default.target` is only consulted by PID 1 at boot, at which point the manager reads the filesystem fresh. `daemon-reload` is required after you create or edit a unit file (Exercise 7, step 9), not after `set-default`.

### Exercise 3

**A3.1** `enabled` describes *persistence*: a symlink exists in a `.wants/` directory, so the unit will be started at the next boot when its target is reached. `inactive (dead)` describes the *current* runtime state. `isolate` operates purely at runtime — it starts what the new target needs and stops everything else — and never touches the enablement symlinks. That is why `isolate` is reversible with a second `isolate` and why it does not survive a reboot.

**A3.2** `start` only *adds* the target and its dependencies to the running set. `isolate` additionally *stops every unit that is not required* by the new target, making it the true equivalent of a SysV runlevel change. It also requires the target to declare `AllowIsolate=yes`.

**A3.3** In emergency mode the root filesystem is mounted **read-only** and essentially nothing else runs — not even `sysinit.target`. You almost always need `mount -o remount,rw /` before you can edit `/etc/fstab`. (This is the standard recovery from an fstab typo that made the boot fail: emergency mode is precisely where a bad fstab lands you.)

**A3.4** `isolate multi-user.target` stops `graphical.target` and anything not required by multi-user; SSH usually survives, but any unit outside the new target's dependency set is stopped without warning — including, on some systems, the very service you rely on. `systemctl rescue` is worse because `rescue.target` stops networking entirely and presents a console-only password prompt: you lose the connection and cannot get back in remotely. Both belong on a console or an out-of-band management interface (IPMI/serial/virsh console).

**A3.5** `Ctrl-D` exits the maintenance shell and lets the boot continue to the default target. The prompt is produced by `rescue.service` (`systemd-sulogin-shell rescue`), which runs `sulogin` — the same mechanism as classic single-user mode, which is why it asks for the root password.

### Exercise 4

**A4.1** `runlevel` prints `<previous> <current>`. `5 3` means the system was in runlevel 5 and is now in runlevel 3. `N` in the first field means "none" — there has been no previous runlevel since boot.

**A4.2** `id:runlevels:action:process`.
- `id` — a 1–4 character unique identifier for the record;
- `runlevels` — the runlevels in which the record applies (empty means "all", or "not runlevel-specific" for actions like `sysinit`/`ctrlaltdel`);
- `action` — how `init` treats the process (`initdefault`, `sysinit`, `wait`, `once`, `respawn`, `boot`, `bootwait`, `ctrlaltdel`, `powerfail`, `powerokwait`, `off`, `ondemand`);
- `process` — the command to run.

The `initdefault` record's fourth field is empty because the record carries no command: it only declares which runlevel `init` should enter after boot. `init` reads the second field and ignores the fourth.

**A4.3** Runlevel 0 is halt/power-off and runlevel 6 is reboot. `id:0:initdefault:` produces a machine that powers itself off the instant init finishes; `id:6:initdefault:` produces an endless reboot loop. Neither can be corrected from a normal login, because there is no usable login — recovery requires editing the file from rescue media or passing a runlevel on the kernel command line.

**A4.4** `telinit q` (equivalently `init q`, or `telinit Q`) makes `init` re-examine `/etc/inittab` without changing runlevel. The systemd counterpart is `systemctl daemon-reload`, which makes PID 1 re-read unit files and rebuild its dependency graph.

**A4.5** `S` = start the service on entering that runlevel; `K` = kill (stop) it. The two digits are the ordering sequence — `rc` executes `K` scripts in ascending numeric order first, then `S` scripts in ascending numeric order, passing `stop` and `start` respectively. `K01apache2` therefore means: on entering runlevel 3, stop Apache, and do it first among the kill scripts. (Note that the symlink target is the real script in `/etc/init.d/`.)

**A4.6** `respawn` guarantees that `init` restarts the process every time it exits, for as long as the current runlevel is in the record's runlevel list — this is how getty prompts reappear after you log out. If the process exits more than 10 times in 2 minutes, `init` considers it to be looping, logs `respawning too fast: disabled for 5 minutes`, and suspends that record for five minutes before trying again.

**A4.7** None. On a systemd host `/sbin/init` is a symlink to systemd, which does not read `/etc/inittab` at all. Distributions that still ship the file usually include a comment saying exactly that; the correct action is `systemctl set-default multi-user.target`.

### Exercise 5

**A5.1** `wall` writes to the terminals of logged-in users; ordinary users' messages are suppressed on terminals where the owner has run `mesg n`, but `root`'s broadcasts bypass that check. The reasoning is that `mesg n` protects against social nuisance from peers, whereas a root broadcast is an *operational* notice — "this machine goes down in ten minutes" — that a user must not be able to opt out of. (Users in the `tty` group with write permission are the boundary case; `wall -n` suppressing the banner is also root-only.)

**A5.2** `wall` reaches everyone who is logged in **right now**, immediately, on their terminal. `write <user> <tty>` reaches **one** specific user's specific terminal, interactively, and is subject to `mesg`. `/etc/motd` reaches users **at their next login** and nobody who is already logged in — it is the wrong tool for an imminent event and the right tool for a standing notice.

**A5.3** `shutdown -k` broadcasts the shutdown warning **without actually shutting anything down** (in systemd it performs a dry run of the scheduled action). Operationally it lets you rehearse the exact wording and timing of the notice, and lets you nag users in advance of a window without committing the machine to a state change — useful when the go/no-go decision has not been made yet.

**A5.4** systemd (via the scheduled-shutdown machinery in PID 1/logind) creates `/run/nologin` **5 minutes before** the deadline. `pam_nologin(8)` enforces it: if the file exists, non-root logins are refused and the file's contents are displayed. The traditional SysV path for the same purpose is `/etc/nologin`; `pam_nologin` checks both, and on many distributions `/etc/nologin` is a symlink into `/run`. Both are removed when the shutdown is cancelled or completes.

**A5.5** Not a bug — it is the design. `pam_nologin` explicitly exempts `root` (more precisely, accounts with UID 0) so that an administrator can still log in to abort or troubleshoot a shutdown that is going wrong. If root were locked out too, a mistimed `shutdown -h +60` would be uncancellable from a remote session.

**A5.6** Check for the pending job: `cat /run/systemd/shutdown/scheduled` (shows `USEC`, `MODE` and `WALL_MESSAGE`), or `systemctl show --property=ScheduledShutdown`, or simply look for `/run/nologin` once you are inside the last five minutes. Cancel with `shutdown -c` (equivalently `systemctl cancel-shutdown` on recent systemd). The scheduled shutdown lives in PID 1, not in the shell that created it, which is exactly why it survives the disconnect.

### Exercise 6

**A6.1**
(a) `shutdown -r +5 "message"`
(b) `shutdown -h 02:00` (or `-P 02:00`)
(c) `shutdown -r now` — equivalently `systemctl reboot` or `reboot`
(d) `shutdown -c`

**A6.2** In the systemd implementation `-h` means "halt or power off", and it behaves as `-P` (power off) **unless** `-H` is also given. `-H` is an explicit halt: stop the CPU and leave the machine powered. `-P` is an explicit power-off via ACPI. So `shutdown -h now` powers the machine off on any modern system. (On classic sysvinit `-h` meant halt, and `halt -p` was needed to cut power — this is the historical reason the exam asks.)

**A6.3** A hang during shutdown. If the halt transition does not complete within 30 minutes — typically because a filesystem cannot be unmounted, a process is stuck in uninterruptible I/O, or a network mount is unreachable — systemd stops waiting and forces a power-off rather than leaving the machine wedged forever with services already stopped. It converts an indefinite hang into a bounded, recoverable outage.

**A6.4** (a) `systemctl poweroff -i` ignores inhibitors and other logged-in users. (b) Identify the inhibitor with `systemd-inhibit --list`, contact/stop the responsible job, and retry cleanly. On a production database node choose (b): the inhibitor exists precisely because something like a base backup or a WAL flush is in flight, and `-i` would defeat the mechanism that was protecting your data. `-i` is for a machine that must go down now regardless.

**A6.5** `-f` skips the orderly stop of units — systemd goes more or less straight to the shutdown phase — but still syncs and unmounts filesystems. `-ff` calls `reboot(2)` immediately, with no unmount and no sync, so any dirty page cache is lost; on a journalled filesystem you get a replay at next boot, and on a database you may get corruption. The correct use for `-ff` is a machine that is already so broken that an orderly shutdown cannot complete — for example a hung shutdown that has passed the point where any further unit will respond — and where the alternative is a physical power cycle.

**A6.6** `systemctl` inspects `argv[0]` — the name it was invoked under. When called as `shutdown`, `reboot`, `halt`, `poweroff` or `telinit`, it parses that command's classic option syntax and maps it onto the corresponding systemd operation. This is the standard multi-call binary pattern (the same trick `busybox` uses), and it is why the compatibility symlinks in `/sbin` work without any wrapper script.

### Exercise 7

**A7.1** SIGTERM is catchable, so a well-written daemon installs a handler and uses it to: finish or roll back in-flight transactions, flush write buffers and the WAL to disk, close client connections cleanly, release locks, and remove its PID/socket files. SIGKILL is delivered by the kernel and cannot be caught, blocked or ignored — the process stops executing instantly, mid-write, with none of that cleanup. On a database that means recovery on restart at best and corruption at worst. Escalate to `-9` only after SIGTERM has demonstrably failed.

**A7.2** SIGHUP = 1, historically "the controlling terminal went away", conventionally repurposed by daemons as "re-read your configuration". SIGTERM = 15, the polite, catchable termination request and the default sent by `kill`. SIGKILL = 9, immediate unconditional termination. The two signals that can never be caught, blocked or ignored are **SIGKILL (9)** and **SIGSTOP (19)**.

**A7.3**
- **Zombie (`Z`)**: the process has already exited; the entry that remains is only a slot in the process table holding its exit status, waiting for its parent to call `wait()`. There is nothing left to signal, so no signal has any effect. The remedy is to make the parent reap it — send the parent SIGCHLD, or fix/restart the parent; if the parent dies, `init`/systemd inherits the child and reaps it immediately.
- **Uninterruptible sleep (`D`)**: the process is blocked inside a kernel call that cannot be interrupted, typically I/O against a hung NFS mount or a failing disk. Signals are queued but not delivered until the syscall returns. The remedy is to fix the underlying I/O — restore the NFS server, mount with `intr`/`soft`, or replace the failing device; `kill -9` will take effect the moment the syscall completes. The `wchan` column names the kernel function it is stuck in and is the fastest way to identify the cause.

**A7.4** `Restart=on-failure` — systemd treats death by SIGKILL as a failure and restarts the service — combined with the fact that you signalled the process rather than the unit, so systemd's supervision was never told to stand down. The correct command is `systemctl stop sshd.service`, which sets the unit's target state to stopped, performs the SIGTERM → `TimeoutStopSec` → SIGKILL escalation itself, and suppresses the restart.

**A7.5** `killall sleep` kills **every** process named `sleep` on the system, regardless of owner or arguments — including one launched by a backup script or another administrator's session. `pkill -f "sleep 5000"` matches the full command line, so it hits only the specific invocation you intended. On a shared or production host, always narrow the match: add `-u <user>`, use `-x` for exact names, use `-f` with a distinctive argument, and verify first with `pgrep -a` before turning it into a `pkill`. (Note also that on some UNIX systems `killall` means "kill all processes on the system" — another reason to prefer `pkill`.)

**A7.6** `TimeoutStopSec=` on the specific unit, and `DefaultTimeoutStopSec=` in `/etc/systemd/system.conf` (default 90 s) which applies to any unit that does not set its own. The confirming journal line is `<unit>: State 'stop-sigterm' timed out. Killing.` — followed by `Killing process <pid> (<name>) with signal SIGKILL` and `Failed with result 'timeout'`. Find the culprit with `journalctl -b -1 | grep 'timed out'`.

**A7.7** `KillMode=control-group` (the default) sends the stop signals to **every** process in the unit's cgroup, so forked workers, helper scripts and orphaned children all get terminated. `KillMode=process` signals only the **main** process. With a forking daemon, `process` leaves the workers running after the unit reports "stopped" — they keep holding ports, file locks and memory, and the next `systemctl start` fails with "address already in use" or produces two generations of the daemon at once. `process` is appropriate only where surviving children are intentional — the canonical case being `sshd.service`, which uses it so that stopping the listener does not kill established user sessions.

### Exercise 8

**A8.1** (a) **Persistence**: the kernel command line applies to exactly one boot and leaves no trace on disk, so a power cycle returns the machine to its normal target; `set-default` writes a symlink that applies to every subsequent boot. (b) **Reachability**: the kernel command line works on a machine you cannot log into — which is the whole point, since a wrong default target is usually what locked you out in the first place. Use the command line to diagnose, `set-default` to fix.

**A8.2** The bootloader passes `ro` on the kernel command line, and the root filesystem is normally remounted read-write later by `systemd-remount-fs.service` as part of `sysinit.target`. With `init=/bin/bash` systemd never runs, so nothing performs that remount and the filesystem stays as the kernel mounted it. The command is `mount -o remount,rw /`.

**A8.3** Your bash shell **is** PID 1. `/sbin/reboot` on a systemd system is a symlink to `systemctl`, which tries to talk to a running systemd manager over D-Bus — there is none, so it fails. `reboot -f` bypasses that and calls the `reboot(2)` syscall directly, and `exec` replaces PID 1 rather than forking a child of it (PID 1 must not exit). Equivalent alternatives: `echo b > /proc/sysrq-trigger`, or `sync` followed by `mount -o remount,ro /` and a power cycle. Always `sync` first — nothing else will flush your `passwd` change.

**A8.4** Not necessarily. `blame` sorts units by their own initialisation time, in isolation, without regard to whether anything was actually waiting for them. `NetworkManager-wait-online.service` is *designed* to block for up to ~30 s until the network is configured; it is slow by construction, and it only delays the boot if something on the critical path depends on it. `systemd-analyze critical-chain` is the corrective view: it shows the actual serialised dependency path to the target, with `@` (absolute time reached) and `+` (time the unit itself took), so you can see whether the slow unit is on that path at all.

**A8.5** `touch /.autorelabel`, followed by a reboot. Editing `/etc/shadow` from a shell that has no SELinux policy loaded leaves the file with an incorrect security context; on the next normal boot, `sshd` and `login` are denied access to it and **no account can log in at all** — a strictly worse situation than the forgotten password. `/.autorelabel` triggers a full filesystem relabel on the next boot (which takes several minutes and reboots again automatically) and restores correct contexts. Check with `getenforce` / `sestatus` whether the system is enforcing before deciding.

**A8.6** (1) Reboot (forcibly if necessary) and read the previous boot: `journalctl -b -1 -o short-precise | tail -50`, looking for `systemd-shutdown[1]:` lines and `timed out` / `Failed to unmount`. (2) Identify which filesystem or device is refusing to release — typically a network mount, a device-mapper/LVM target, or a loop device — and which process still holds it. (3) For a reproducible hang, set `systemd-analyze log-level debug` before the shutdown and make sure `/run/initramfs` exists so the shutdown can pivot back into an initramfs and log the final unmount phase. (4) Check `JobTimeoutSec=`/`JobTimeoutAction=` on the halt/poweroff target — if the hang is bounded and rare, the timeout already handles it; if it is systematic, fix the mount (e.g. `_netdev`, `soft`/`intr` for NFS, correct ordering with `After=network.target`).

### Exercise 9

**A9.1**
1. `systemctl get-default; readlink -f /etc/systemd/system/default.target`
2. `systemctl get-default > /root/orig; systemctl set-default multi-user.target; systemctl get-default; systemctl set-default "$(cat /root/orig)"`
3. `wall "Reboot in 12 minutes"; shutdown -r +12 "Kernel upgrade — back by 10:45"`
4. `cat /run/systemd/shutdown/scheduled; shutdown -c`
5. `systemctl isolate multi-user.target` … `systemctl isolate graphical.target` (or `systemctl default`)
6. `runlevel` and `who -r` (fall back to `systemctl list-units --type=target` where utmp is unavailable)
7. `systemd-inhibit --what=shutdown --who=backup --why="nightly backup" --mode=block sleep 600 &` → as a normal user `systemctl poweroff` is refused → `kill %1`
8. `bash -c 'trap "" TERM; sleep 600' & kill %1; sleep 1; kill -9 %1; kill -0 <pid> 2>/dev/null || echo gone`
9. `systemctl --failed` then `journalctl -u <unit> -b -p err --no-pager`
10. At GRUB press `e`, append `systemd.unit=rescue.target` to the `linux` line, `Ctrl-X`

</details>

---

## References

- LPI — *Exam 101 Objectives (101-500, v5.0)*, objective 101.3: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `systemd.special(7)` — special targets, including `default.target`, `rescue.target`, `emergency.target`, `runlevelN.target`: <https://www.freedesktop.org/software/systemd/man/systemd.special.html>
- `systemctl(1)` — `get-default`, `set-default`, `isolate`, `rescue`, `emergency`, `kill`, force flags: <https://www.freedesktop.org/software/systemd/man/systemctl.html>
- `shutdown(8)` (systemd) — time arguments, `-c`, `-k`, `/run/nologin`: <https://www.freedesktop.org/software/systemd/man/shutdown.html>
- `systemd.kill(5)` — `KillMode=`, `KillSignal=`, `SendSIGKILL=`, `FinalKillSignal=`: <https://www.freedesktop.org/software/systemd/man/systemd.kill.html>
- `systemd.service(5)` — `TimeoutStopSec=`, `Restart=`: <https://www.freedesktop.org/software/systemd/man/systemd.service.html>
- `systemd-system.conf(5)` — `DefaultTimeoutStopSec=`: <https://www.freedesktop.org/software/systemd/man/systemd-system.conf.html>
- `kernel-command-line(7)` — `systemd.unit=`, `systemd.debug-shell`, SysV-compatible `single`/`1`…`5`: <https://www.freedesktop.org/software/systemd/man/kernel-command-line.html>
- `systemd-inhibit(1)` — inhibitor locks: <https://www.freedesktop.org/software/systemd/man/systemd-inhibit.html>
- `systemd-analyze(1)` — `blame`, `critical-chain`, `log-level`: <https://www.freedesktop.org/software/systemd/man/systemd-analyze.html>
- `inittab(5)` (sysvinit) — record format and actions: <https://man7.org/linux/man-pages/man5/inittab.5.html>
- `init(8)` / `telinit(8)` (sysvinit): <https://man7.org/linux/man-pages/man8/init.8.html>
- `signal(7)` — signal numbers and default dispositions: <https://man7.org/linux/man-pages/man7/signal.7.html>
- `kill(1)`, `killall(1)`, `pkill(1)`/`pgrep(1)`: <https://man7.org/linux/man-pages/man1/kill.1.html> · <https://man7.org/linux/man-pages/man1/killall.1.html> · <https://man7.org/linux/man-pages/man1/pgrep.1.html>
- `wall(1)`, `mesg(1)`, `write(1)`: <https://man7.org/linux/man-pages/man1/wall.1.html> · <https://man7.org/linux/man-pages/man1/mesg.1.html>
- `pam_nologin(8)`: <https://man7.org/linux/man-pages/man8/pam_nologin.8.html>
- `runlevel(8)`: <https://www.freedesktop.org/software/systemd/man/runlevel.html>