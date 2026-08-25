# 332.3 Resource Control — Guided Exercises

> **Exam:** LPIC-3 303-300 (Security), version 3.0.0 · **Topic 332.3** · **Weight 5**
> **Objective source:** <https://www.lpi.org/our-certifications/exam-303-objectives/>
>
> These exercises assume a **disposable VM** with root access, systemd ≥ 252 and a
> kernel ≥ 5.15 running the **unified cgroup hierarchy** (cgroup v2). Several steps
> deliberately provoke OOM kills, `fork()` exhaustion and I/O starvation. **Do not
> run them on a machine you care about, and never on a host shared with other users.**
>
> Reference documentation used throughout:
> - Kernel cgroup v2 — <https://docs.kernel.org/admin-guide/cgroup-v2.html>
> - Kernel cgroup v1 — <https://docs.kernel.org/admin-guide/cgroup-v1/index.html>
> - `systemd.resource-control(5)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
> - `systemd.exec(5)` (`Limit*=`) — <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
> - `limits.conf(5)` — <https://man7.org/linux/man-pages/man5/limits.conf.5.html>
> - `pam_limits(8)` — <https://man7.org/linux/man-pages/man8/pam_limits.8.html>
> - `cgroup_namespaces(7)` — <https://man7.org/linux/man-pages/man7/cgroup_namespaces.7.html>
> - systemd cgroup delegation contract — <https://systemd.io/CGROUP_DELEGATION/>
> - Pressure Stall Information — <https://docs.kernel.org/accounting/psi.html>

**Packages you will need:** `systemd` (already present), `python3`, `util-linux`
(`prlimit`, `unshare`, `lsns`), and optionally `stress-ng` and `libcgroup-tools`
(`libcgroup-tools` on RHEL/Fedora, `cgroup-tools` on Debian/Ubuntu).

---

## Exercise 1 — Identify which cgroup hierarchy the system is actually running

Before touching anything you must know whether you are on **v2 (unified)**,
**v1 (legacy)** or **hybrid**. Every later exercise depends on the answer, and the
exam expects you to tell them apart from the filesystem alone.

1. Look at the filesystem type mounted at the cgroup root:

   ```bash
   stat -fc %T /sys/fs/cgroup/
   ```

   ```
   cgroup2fs
   ```

   `cgroup2fs` means **unified/v2**. `tmpfs` means v1 or hybrid — in that case
   `/sys/fs/cgroup/` is only a tmpfs holding one mount point per controller.

2. Confirm with the mount table and list what is underneath:

   ```bash
   findmnt -t cgroup2,cgroup
   ```

   ```
   TARGET         SOURCE  FSTYPE  OPTIONS
   /sys/fs/cgroup cgroup2 cgroup2 rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursive_prot
   ```

3. Ask the kernel which controllers were compiled in and how many hierarchies each
   is attached to:

   ```bash
   cat /proc/cgroups
   ```

   ```
   #subsys_name    hierarchy       num_cgroups     enabled
   cpuset          0               108             1
   cpu             0               108             1
   cpuacct         0               108             1
   blkio           0               108             1
   memory          0               108             1
   devices         0               108             1
   freezer         0               108             1
   net_cls         0               108             1
   pids            0               108             1
   ```

   A `hierarchy` column of `0` for every row is the v2 signature: nothing is mounted
   on a separate v1 hierarchy.

4. See which controllers are actually *available for delegation* at the root of the
   unified tree, and which the root has enabled for its children:

   ```bash
   cat /sys/fs/cgroup/cgroup.controllers
   cat /sys/fs/cgroup/cgroup.subtree_control
   ```

   ```
   cpuset cpu io memory hugetlb pids rdma misc
   cpuset cpu io memory pids
   ```

5. Find your own shell's cgroup:

   ```bash
   cat /proc/self/cgroup
   ```

   ```
   0::/user.slice/user-1000.slice/session-3.scope
   ```

   On v2 there is exactly one line, always `0::<path>`, and the path is relative to
   the cgroup root (or to your cgroup namespace root — see Exercise 13).

**Check your understanding**

- **Q1.** Your `/proc/self/cgroup` shows several lines such as `8:memory:/system.slice/nginx.service` and `0::/system.slice/nginx.service`. Which hierarchy mode is this, and what does the `0::` line mean?
- **Q2.** Which kernel command-line parameter forces a systemd system back to the legacy v1 hierarchy, and which one selects hybrid?
- **Q3.** `cgroup.controllers` lists `io` but `cgroup.subtree_control` does not. What is the practical consequence for a cgroup you create one level down?

---

## Exercise 2 — Read the unified hierarchy through systemd's eyes

systemd is the **single writer** of the cgroup tree on a modern distribution. Its
tooling is faster and safer than walking `/sys/fs/cgroup` by hand.

1. Print the whole tree:

   ```bash
   systemd-cgls --no-pager | head -40
   ```

   ```
   Control group /:
   -.slice
   ├─user.slice
   │ └─user-1000.slice
   │   ├─user@1000.service …
   │   │ ├─app.slice
   │   │ │ └─dbus.service
   │   │ │   └─1183 /usr/bin/dbus-daemon --session …
   │   │ └─init.scope
   │   │   ├─1170 /usr/lib/systemd/systemd --user
   │   │   └─1172 (sd-pam)
   │   └─session-3.scope
   │     ├─1301 sshd-session: student [priv]
   │     ├─1315 -bash
   │     └─1402 systemd-cgls --no-pager
   ├─init.scope
   │ └─1 /usr/lib/systemd/systemd --system --deserialize 31
   └─system.slice
     ├─sshd.service
     │ └─902 sshd: /usr/sbin/sshd -D …
     └─nginx.service
       ├─1021 nginx: master process /usr/sbin/nginx
       └─1022 nginx: worker process
   ```

2. Note the three unit types visible above and map them to their roles:

   ```bash
   systemctl list-units --type=slice --no-pager
   systemctl list-units --type=scope --no-pager
   ```

   ```
   UNIT              LOAD   ACTIVE SUB    DESCRIPTION
   -.slice           loaded active active Root Slice
   system.slice      loaded active active System Slice
   user-1000.slice   loaded active active User Slice of UID 1000
   user.slice        loaded active active User and Session Slice
   ```

3. Watch live consumption per cgroup (press `q` to quit; `c`/`m`/`i`/`t` reorder by
   CPU, memory, I/O and task count):

   ```bash
   systemd-cgtop --depth=3
   ```

   ```
   Control Group                  Tasks   %CPU   Memory  Input/s Output/s
   /                                214    3.1     1.2G        -        -
   system.slice                      96    2.4   712.4M        -        -
   system.slice/nginx.service         3    1.9    24.1M        -        -
   user.slice                        41    0.6   402.8M        -        -
   ```

4. Read the accounting counters for one unit through the unit interface rather than
   the filesystem:

   ```bash
   systemctl show nginx.service \
     -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec -p TasksCurrent -p ControlGroup
   ```

   ```
   MemoryCurrent=25264128
   MemoryPeak=31948800
   CPUUsageNSec=4128993000
   TasksCurrent=3
   ControlGroup=/system.slice/nginx.service
   ```

5. Verify the same numbers at the source:

   ```bash
   cat /sys/fs/cgroup/system.slice/nginx.service/memory.current
   cat /sys/fs/cgroup/system.slice/nginx.service/pids.current
   ```

**Check your understanding**

- **Q4.** Define **slice**, **scope** and **service** in one sentence each, and say which of the three systemd creates for processes it did *not* fork itself.
- **Q5.** You create a slice unit named `lab-db.slice`. Where does it land in the tree, and why?
- **Q6.** `MemoryCurrent` reads `[not set]` for a unit. What is the most likely cause and how do you fix it?

---

## Exercise 3 — rlimits for interactive sessions: `ulimit`, `limits.conf`, `pam_limits.so`

`ulimit` exposes the per-process `setrlimit(2)` limits
(<https://man7.org/linux/man-pages/man2/getrlimit.2.html>). They are **inherited
across `fork()`/`exec()`**, which is exactly why the login stack is where they get set.

1. Inspect the current shell's limits, soft and hard:

   ```bash
   ulimit -Sa
   ulimit -Ha
   ```

   ```
   core file size          (blocks, -c) 0
   data seg size           (kbytes, -d) unlimited
   max locked memory       (kbytes, -l) 8192
   open files                      (-n) 1024
   max user processes              (-u) 15043
   virtual memory          (kbytes, -v) unlimited
   ```

2. Read the same values from `/proc`, which works for *any* PID, not just your shell:

   ```bash
   cat /proc/self/limits
   ```

   ```
   Limit                     Soft Limit  Hard Limit  Units
   Max open files            1024        524288      files
   Max processes             15043       15043       processes
   Max locked memory         8388608     8388608     bytes
   ```

3. Demonstrate the soft/hard asymmetry. A soft limit can be raised by an unprivileged
   process **up to** the hard limit, and lowering a hard limit is irreversible for
   that process tree:

   ```bash
   bash -c 'ulimit -Sn 512; ulimit -Sn; ulimit -Sn 2048; ulimit -Sn'
   bash -c 'ulimit -Hn 4096; ulimit -Hn 8192'
   ```

   ```
   512
   2048
   bash: line 1: ulimit: open files: cannot modify limit: Operation not permitted
   ```

4. Create a per-user policy file. Never edit `/etc/security/limits.conf` when a
   drop-in will do:

   ```bash
   install -d -m 0755 /etc/security/limits.d
   cat > /etc/security/limits.d/90-lab.conf <<'EOF'
   # <domain>      <type>  <item>          <value>
   student         soft    nofile          2048
   student         hard    nofile          4096
   @developers     -       nproc           256
   *               hard    core            0
   %developers     -       maxlogins       4
   EOF
   ```

5. Confirm `pam_limits.so` is in the PAM stack for the service you are testing:

   ```bash
   grep -R pam_limits /etc/pam.d/
   ```

   ```
   /etc/pam.d/system-auth:session     required      pam_limits.so
   /etc/pam.d/sshd:session            required      pam_limits.so
   ```

   If it is missing, add `session required pam_limits.so` to the relevant stack.

6. Open a **new** login session (the limits are applied by PAM at session setup —
   your existing shell will not change) and verify:

   ```bash
   ssh student@localhost -- 'ulimit -Sn; ulimit -Hn'
   ```

   ```
   2048
   4096
   ```

7. Change a limit on an *already running* process without restarting it:

   ```bash
   pgrep -u student -x bash
   prlimit --pid 1315 --nofile
   prlimit --pid 1315 --nofile=3000:4096
   prlimit --pid 1315 --nofile
   ```

   ```
   RESOURCE DESCRIPTION                    SOFT HARD UNITS
   NOFILE   max number of open files       2048 4096 files
   RESOURCE DESCRIPTION                    SOFT HARD UNITS
   NOFILE   max number of open files       3000 4096 files
   ```

**Check your understanding**

- **Q7.** In `limits.conf`, what do the domain prefixes `@developers` and `%developers` mean, and what does a `type` of `-` do?
- **Q8.** A user reports `Too many open files` although you set `nofile` in `limits.d`. Give three distinct causes to check before blaming PAM.
- **Q9.** Why can `prlimit --pid` raise a hard limit while the process itself cannot, and what capability is involved?

---

## Exercise 4 — The `limits.conf` trap: rlimits for **services**

This is the single most frequently missed point of the objective: **`pam_limits.so`
only runs inside a PAM session.** A daemon started by systemd at boot never
traverses a PAM stack, so `/etc/security/limits.conf` is irrelevant to it.

1. Prove it. Set a deliberately tiny `nofile` for root in `limits.d`, then inspect a
   running system service:

   ```bash
   echo 'root hard nofile 64' > /etc/security/limits.d/91-lab-root.conf
   systemctl restart nginx.service
   cat /proc/$(systemctl show -p MainPID --value nginx.service)/limits | grep -i 'open files'
   ```

   ```
   Max open files            1024        524288      files
   ```

   Unchanged — the service ignored the file entirely.

2. Set the limit the correct way, with a unit drop-in:

   ```bash
   systemctl edit nginx.service
   ```

   ```ini
   [Service]
   LimitNOFILE=8192:16384
   LimitCORE=0
   LimitNPROC=512
   ```

   ```bash
   systemctl daemon-reload && systemctl restart nginx.service
   cat /proc/$(systemctl show -p MainPID --value nginx.service)/limits | grep -i 'open files'
   ```

   ```
   Max open files            8192        16384       files
   ```

3. Inspect and change the **fallback defaults** applied to every unit that does not
   set its own value:

   ```bash
   systemd-analyze cat-config systemd/system.conf | grep -i '^#\?DefaultLimit' | head
   systemctl show -p DefaultLimitNOFILESoft -p DefaultLimitNOFILE
   ```

   ```
   DefaultLimitNOFILESoft=1024
   DefaultLimitNOFILE=524288
   ```

   To change them, drop a file in `/etc/systemd/system.conf.d/` (system services) or
   `/etc/systemd/user.conf.d/` (user services) and reboot, or `systemctl
   daemon-reexec` plus a restart of the affected units.

4. Clean up the sabotage from step 1:

   ```bash
   rm -f /etc/security/limits.d/91-lab-root.conf
   ```

**Check your understanding**

- **Q10.** Name the two configuration surfaces that set rlimits and state precisely which processes each one governs.
- **Q11.** `LimitNOFILE=8192:16384` — which number is which, and what happens if you write a single value?
- **Q12.** A `systemd --user` session *does* go through PAM. Does `limits.conf` therefore apply to user services? Explain the path the limit takes.

---

## Exercise 5 — Transient memory control with `systemd-run`

`systemd-run` is the fastest way to put an arbitrary command inside a controlled
cgroup, and the properties it accepts are exactly the `systemd.resource-control(5)`
directives.

1. Write a predictable memory allocator:

   ```bash
   cat > /root/memhog.py <<'EOF'
   import sys, time
   chunk = 8 * 1024 * 1024
   blocks = []
   for i in range(1, 1000):
       blocks.append(bytearray(chunk))          # touch it: bytearray is zero-filled
       print(f"allocated {i*8} MiB", flush=True)
       time.sleep(0.2)
   EOF
   ```

2. Run it under a hard memory ceiling in a named scope inside a new slice:

   ```bash
   systemd-run --scope --unit=memhog --slice=lab.slice \
       -p MemoryMax=64M -p MemorySwapMax=0 \
       python3 /root/memhog.py
   ```

   ```
   Running scope as unit: memhog.scope
   allocated 8 MiB
   allocated 16 MiB
   …
   allocated 56 MiB
   Killed
   ```

3. Confirm the kernel, not systemd, did the killing:

   ```bash
   journalctl -k -n 15 --no-pager | grep -i -A3 'out of memory'
   ```

   ```
   kernel: memhog.scope: Memory cgroup out of memory: Killed process 5192 (python3)
           total-vm:139572kB, anon-rss:63108kB, file-rss:2216kB, shmem-rss:0kB,
           UID:0 pgtables:224kB oom_score_adj:0
   ```

4. Now compare `MemoryHigh=` (throttle + aggressive reclaim, **no** kill) with
   `MemoryMax=` (hard wall, OOM kill). Run the allocator again with only a soft limit:

   ```bash
   systemd-run --scope --unit=memhog --slice=lab.slice \
       -p MemoryHigh=64M -p MemoryMax=infinity \
       python3 /root/memhog.py
   ```

   It keeps allocating past 64 MiB but visibly slows down as the kernel reclaims and
   throttles the allocating task.

5. While it runs, read the event counters from a second terminal:

   ```bash
   watch -n1 cat /sys/fs/cgroup/lab.slice/memhog.scope/memory.events
   ```

   ```
   low 0
   high 2841
   max 0
   oom 0
   oom_kill 0
   ```

6. Inspect the full memory picture of the cgroup:

   ```bash
   cd /sys/fs/cgroup/lab.slice/memhog.scope
   cat memory.current memory.max memory.high memory.swap.max
   head -8 memory.stat
   ```

   ```
   201326592
   max
   67108864
   0
   anon 197132288
   file 2224128
   kernel 1187840
   slab 819200
   ```

**Check your understanding**

- **Q13.** Distinguish `memory.min`, `memory.low`, `memory.high` and `memory.max`, and give the systemd directive that maps to each.
- **Q14.** In step 3, which component chose the victim and by what rule — and how does that differ from the *global* OOM killer?
- **Q15.** Why does `MemorySwapMax=0` make the `MemoryMax=` demonstration deterministic on a machine with swap enabled?
- **Q16.** `lab.slice` did not exist before step 2 and there is no `lab.slice` unit file on disk. Why did it work?

---

## Exercise 6 — CPU control: weight versus quota

Two mechanisms with different semantics: **`cpu.weight`** is proportional and only
matters under contention; **`cpu.max`** is an absolute ceiling enforced even on an
idle machine.

1. Start two CPU burners with a 4:1 weight ratio, in the background:

   ```bash
   systemd-run --unit=cpu-a --slice=lab.slice -p CPUWeight=400 \
       bash -c 'while :; do :; done'
   systemd-run --unit=cpu-b --slice=lab.slice -p CPUWeight=100 \
       bash -c 'while :; do :; done'
   ```

2. **Pin the contention to one CPU**, otherwise both simply get a core each and the
   weights never come into play:

   ```bash
   systemctl set-property --runtime cpu-a.service AllowedCPUs=0
   systemctl set-property --runtime cpu-b.service AllowedCPUs=0
   ```

3. Observe the split:

   ```bash
   systemd-cgtop --depth=2 -n 5 | grep -E 'cpu-[ab]'
   ```

   ```
   lab.slice/cpu-a.service    1   79.8     1.1M     -     -
   lab.slice/cpu-b.service    1   19.9     1.1M     -     -
   ```

   Roughly 400:100 → 80 % / 20 % of the single allowed CPU.

4. Verify the translation to kernel files:

   ```bash
   cat /sys/fs/cgroup/lab.slice/cpu-a.service/cpu.weight
   cat /sys/fs/cgroup/lab.slice/cpu-a.service/cpuset.cpus.effective
   ```

   ```
   400
   0
   ```

5. Replace weight with an absolute quota and remove the pin:

   ```bash
   systemctl set-property --runtime cpu-a.service CPUQuota=20% AllowedCPUs=
   cat /sys/fs/cgroup/lab.slice/cpu-a.service/cpu.max
   ```

   ```
   20000 100000
   ```

   The pair is `$MAX $PERIOD` in microseconds: 20 000 µs of runtime per 100 000 µs
   period = 20 % of **one** CPU. `CPUQuota=250%` would be `250000 100000` — two and a
   half CPUs' worth, only meaningful on a multi-core box.

6. Confirm the ceiling holds with the machine otherwise idle:

   ```bash
   top -b -n 2 -d 2 | grep -m2 'while'
   ```

   ```
   5411 root  20 0  8896 4480 3200 R  20.0  0.1  0:14.22 bash
   ```

7. Stop the burners:

   ```bash
   systemctl stop cpu-a.service cpu-b.service
   ```

**Check your understanding**

- **Q17.** On an otherwise idle 8-core machine, a service has `CPUWeight=10`. How much CPU does it get? Now the same service has `CPUQuota=10%`. How much does it get?
- **Q18.** What is the valid range and default of `CPUWeight=`, and which v1 knob does it replace?
- **Q19.** `CPUAffinity=` in `[Service]` and `AllowedCPUs=` both restrict which CPUs a unit uses. What is the mechanical difference, and which one is inherited by a child that calls `sched_setaffinity()`?
- **Q20.** Why did step 2 use `systemctl set-property --runtime` rather than plain `set-property`?

---

## Exercise 7 — Making limits persistent: drop-ins and `systemctl set-property`

1. Create a small service to experiment on:

   ```bash
   cat > /etc/systemd/system/lab-web.service <<'EOF'
   [Unit]
   Description=Lab HTTP service for resource control exercises

   [Service]
   ExecStart=/usr/bin/python3 -m http.server 8080 --directory /usr/share/doc
   Restart=on-failure

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl start lab-web.service
   ```

2. Apply limits at runtime and watch where they land:

   ```bash
   systemctl set-property lab-web.service MemoryMax=128M TasksMax=64 CPUQuota=50%
   find /etc/systemd/system/lab-web.service.d/ -type f -printf '%p\n' -exec cat {} \;
   ```

   ```
   /etc/systemd/system/lab-web.service.d/50-MemoryMax.conf
   # This is a drop-in unit file extension, created via "systemctl set-property"
   [Service]
   MemoryMax=134217728
   /etc/systemd/system/lab-web.service.d/50-TasksMax.conf
   [Service]
   TasksMax=64
   /etc/systemd/system/lab-web.service.d/50-CPUQuota.conf
   [Service]
   CPUQuota=50%
   ```

   Note two things: `set-property` **applies immediately and persists**, and it wrote
   one drop-in per property. With `--runtime` the same files go under
   `/run/systemd/system/…` and vanish at reboot.

3. Confirm the running values and the kernel files agree:

   ```bash
   systemctl show lab-web.service -p MemoryMax -p TasksMax -p CPUQuotaPerSecUSec
   cat /sys/fs/cgroup/system.slice/lab-web.service/{memory.max,pids.max,cpu.max}
   ```

   ```
   MemoryMax=134217728
   TasksMax=64
   CPUQuotaPerSecUSec=500ms
   134217728
   64
   50000 100000
   ```

4. See the full effective configuration, including every drop-in, in load order:

   ```bash
   systemctl cat lab-web.service
   systemd-analyze cat-config systemd/system/lab-web.service
   ```

5. Remove one property cleanly — assigning the empty/`infinity` value resets it:

   ```bash
   systemctl set-property lab-web.service CPUQuota=
   ls /etc/systemd/system/lab-web.service.d/
   ```

**Check your understanding**

- **Q21.** Give the three ways to attach a resource limit to a service and rank them by persistence.
- **Q22.** Why does setting *any* `Memory*=` or `Tasks*=` property implicitly turn on accounting for that unit, and what is the historical cost of accounting that made it opt-in on cgroup v1?
- **Q23.** You want a limit that survives a package upgrade replacing `/etc/systemd/system/lab-web.service`. Which mechanism do you choose and why?

---

## Exercise 8 — Slices: hierarchical, enforceable envelopes

A slice imposes a ceiling on **everything beneath it**, which is how you stop a whole
class of workloads from starving the system — not just one runaway process.

1. Write a slice unit with a real budget:

   ```bash
   cat > /etc/systemd/system/lab.slice <<'EOF'
   [Unit]
   Description=Lab workloads — hard resource envelope
   Before=slices.target

   [Slice]
   MemoryAccounting=yes
   MemoryHigh=256M
   MemoryMax=512M
   CPUAccounting=yes
   CPUQuota=100%
   TasksAccounting=yes
   TasksMax=200
   IOAccounting=yes
   IOWeight=50
   EOF
   systemctl daemon-reload
   ```

2. Move the service into the slice:

   ```bash
   systemctl set-property lab-web.service Slice=lab.slice
   systemctl restart lab-web.service
   systemctl show lab-web.service -p Slice -p ControlGroup
   ```

   ```
   Slice=lab.slice
   ControlGroup=/lab.slice/lab-web.service
   ```

3. Add a second consumer and demonstrate that the **slice** total is what is capped,
   not the individual units. Each child asks for 400 MiB; the slice allows 512 MiB:

   ```bash
   systemd-run --unit=hog1 --slice=lab.slice -p MemoryMax=400M python3 /root/memhog.py
   systemd-run --unit=hog2 --slice=lab.slice -p MemoryMax=400M python3 /root/memhog.py
   sleep 20
   cat /sys/fs/cgroup/lab.slice/memory.current
   cat /sys/fs/cgroup/lab.slice/memory.events
   ```

   ```
   536870912
   low 0
   high 5122
   max 913
   oom 4
   oom_kill 1
   ```

   Neither child individually breached its own 400 MiB, yet one was killed: the
   **parent's** `memory.max` was the binding constraint.

4. Visualise the resulting subtree:

   ```bash
   systemd-cgls /lab.slice
   ```

   ```
   Control group /lab.slice:
   ├─lab-web.service
   │ └─6021 /usr/bin/python3 -m http.server 8080 …
   ├─hog1.service
   │ └─6103 python3 /root/memhog.py
   └─hog2.service
   ```

5. Build a nested slice and confirm the dash-naming rule:

   ```bash
   systemd-run --unit=nested --slice=lab-batch.slice --slice-inherit sleep 300
   systemctl show nested.service -p ControlGroup
   ls -d /sys/fs/cgroup/lab.slice/lab-batch.slice
   ```

   ```
   ControlGroup=/lab.slice/lab-batch.slice/nested.service
   /sys/fs/cgroup/lab.slice/lab-batch.slice
   ```

6. Stop the hogs:

   ```bash
   systemctl stop hog1.service hog2.service nested.service 2>/dev/null
   ```

**Check your understanding**

- **Q24.** `lab-batch.slice` was created implicitly under `lab.slice`. State the general rule, and give the parent of `machine-qemu\x2dvm1.slice`.
- **Q25.** Limits are hierarchical. If `lab.slice` has `MemoryMax=512M` and `lab-web.service` has `MemoryMax=1G`, what is the service's effective ceiling?
- **Q26.** Name the four slices systemd creates by default and state what each contains.
- **Q27.** What is the operational advantage of capping `user.slice` rather than capping each user's services individually?

---

## Exercise 9 — The `pids` controller: containing `fork()` storms

`TasksMax=` is the cheapest defence against fork bombs and thread leaks, and unlike
`ulimit -u` it is **per-cgroup**, not per-UID — so it cannot be evaded by a second
login or a setuid transition.

1. Write a **bounded, self-terminating** fork test (safer and more informative than
   the classic `:(){ :|:& };:`):

   ```bash
   cat > /root/forktest.sh <<'EOF'
   #!/bin/bash
   n=0
   while [ $n -lt 500 ]; do
       sleep 60 &
       if [ $? -ne 0 ]; then
           echo "fork() failed after $n children"
           break
       fi
       n=$((n+1))
   done
   echo "spawned $n children"
   kill $(jobs -p) 2>/dev/null
   EOF
   chmod +x /root/forktest.sh
   ```

2. Run it inside a cgroup that allows 20 tasks:

   ```bash
   systemd-run --scope --unit=forkhog --slice=lab.slice -p TasksMax=20 \
       /root/forktest.sh
   ```

   ```
   Running scope as unit: forkhog.scope
   /root/forktest.sh: fork: retry: Resource temporarily unavailable
   fork() failed after 17 children
   spawned 17 children
   ```

3. Confirm the counter and the limit:

   ```bash
   systemd-run --scope --unit=forkhog2 --slice=lab.slice -p TasksMax=20 \
       bash -c 'for i in $(seq 15); do sleep 30 & done;
                cat /sys/fs/cgroup/lab.slice/forkhog2.scope/pids.{current,max,events};
                wait' &
   ```

   ```
   16
   20
   max 0
   ```

4. Show that `TasksMax` counts **threads**, not only processes:

   ```bash
   systemd-run --scope --unit=threadhog -p TasksMax=5 \
       python3 -c '
   import threading, time
   def w(): time.sleep(30)
   for i in range(10):
       try:
           threading.Thread(target=w).start()
       except RuntimeError as e:
           print(f"thread {i} refused: {e}"); break
   '
   ```

   ```
   thread 4 refused: can't start new thread
   ```

5. Check the system-wide default that systemd applies to every unit:

   ```bash
   systemctl show -p DefaultTasksMax
   cat /proc/sys/kernel/pid_max
   cat /proc/sys/kernel/threads-max
   ```

   ```
   DefaultTasksMax=38207
   4194304
   126743
   ```

**Check your understanding**

- **Q28.** Give two concrete ways a hostile or buggy process defeats `ulimit -u` that `TasksMax=` still blocks.
- **Q29.** `TasksMax=15%` is legal. Percent of what?
- **Q30.** `pids.events` shows `max 913`. What exactly does that number count, and what syscall did the workload see?
- **Q31.** Why is the pids controller the one controller with essentially no runtime cost, and why is that an argument for enabling it everywhere?

---

## Exercise 10 — I/O control: weights, ceilings and the writeback caveat

1. Identify the block device and its `major:minor` — the cgroup I/O interface is
   addressed by device number, never by path:

   ```bash
   lsblk -o NAME,MAJ:MIN,TYPE,SIZE
   ```

   ```
   NAME   MAJ:MIN TYPE  SIZE
   vda    252:0   disk   40G
   ├─vda1 252:1   part    1G
   └─vda2 252:2   part   39G
   ```

2. Create a test file large enough to defeat the page cache:

   ```bash
   dd if=/dev/urandom of=/var/tmp/iotest.bin bs=1M count=512 status=none
   sync
   ```

3. Measure the unthrottled baseline with **direct I/O** so the page cache is bypassed:

   ```bash
   dd if=/var/tmp/iotest.bin of=/dev/null bs=1M count=512 iflag=direct
   ```

   ```
   512+0 records in
   512+0 records out
   536870912 bytes (537 MB, 512 MiB) copied, 1.41 s, 381 MB/s
   ```

4. Now impose a read-bandwidth ceiling:

   ```bash
   systemd-run --scope --unit=iohog --slice=lab.slice \
       -p IOReadBandwidthMax='/dev/vda 20M' \
       dd if=/var/tmp/iotest.bin of=/dev/null bs=1M count=512 iflag=direct
   ```

   ```
   536870912 bytes (537 MB, 512 MiB) copied, 25.6 s, 21.0 MB/s
   ```

5. Read the kernel's view of the setting:

   ```bash
   cat /sys/fs/cgroup/lab.slice/iohog.scope/io.max
   ```

   ```
   252:0 rbps=20971520 wbps=max riops=max wiops=max
   ```

6. Inspect per-device accounting:

   ```bash
   cat /sys/fs/cgroup/lab.slice/io.stat
   ```

   ```
   252:0 rbytes=536870912 wbytes=8192 rios=512 wios=2 dbytes=0 dios=0
   ```

7. Repeat step 4 **without** `iflag=direct` and note that the first run may complete
   far faster than 20 MB/s — the read was served from the page cache and never
   reached the block layer, so `io.max` never saw it.

   ```bash
   sync; echo 3 > /proc/sys/vm/drop_caches     # required for a fair buffered test
   ```

8. (Optional) Compare proportional weighting. `IOWeight=` maps to `io.weight`, which
   requires either the **BFQ** scheduler or the `blk-iocost` cost model to be active:

   ```bash
   cat /sys/block/vda/queue/scheduler
   ```

   ```
   [none] mq-deadline kyber bfq
   ```

   ```bash
   echo bfq > /sys/block/vda/queue/scheduler
   systemctl set-property --runtime lab.slice IOWeight=50
   cat /sys/fs/cgroup/lab.slice/io.weight
   ```

   ```
   default 50
   ```

**Check your understanding**

- **Q32.** Why does buffered write throttling behave differently from read throttling under cgroup v2, and which two controllers must both be enabled for writeback to be attributed correctly?
- **Q33.** State the difference between `IOWeight=` and `IOReadBandwidthMax=`, and name the v1 knobs they replace.
- **Q34.** `IOWeight=` appears to do nothing on your NVMe device. Give the two most likely reasons.
- **Q35.** Why is `io.max` keyed by `major:minor` and what breaks if you write `/dev/vda` into it directly?

---

## Exercise 11 — Raw cgroup v2 by hand, the "no internal processes" rule, and delegation

You must be able to do this without systemd — and you must know why doing it *behind*
systemd's back is wrong.

1. First, the **wrong but instructive** way. Create a cgroup directly under the root:

   ```bash
   mkdir /sys/fs/cgroup/manual
   ls /sys/fs/cgroup/manual/
   ```

   ```
   cgroup.controllers  cgroup.events  cgroup.freeze  cgroup.max.depth
   cgroup.max.descendants  cgroup.procs  cgroup.stat  cgroup.subtree_control
   cgroup.threads  cgroup.type  cpu.max  cpu.pressure  cpu.stat  cpu.weight
   io.max  io.pressure  io.stat  memory.current  memory.events  memory.high
   memory.max  memory.pressure  memory.stat  pids.current  pids.events  pids.max
   ```

   The `memory.*`, `cpu.*`, `io.*` and `pids.*` files exist here **only because the
   root's `cgroup.subtree_control` already enables those controllers** (Exercise 1,
   step 4).

2. Set a limit and move a process in:

   ```bash
   echo 32M > /sys/fs/cgroup/manual/memory.max
   echo 10  > /sys/fs/cgroup/manual/pids.max
   sleep 300 &
   echo $! > /sys/fs/cgroup/manual/cgroup.procs
   cat /proc/$!/cgroup
   ```

   ```
   0::/manual
   ```

   Note: `cgroup.procs` accepts **one PID per write**, and writing a PID moves the
   whole process (all its threads) — `cgroup.threads` is what moves an individual
   thread, and only in threaded mode.

3. Demonstrate the **"no internal processes"** rule. Try to enable a controller for
   children of a cgroup that itself holds processes:

   ```bash
   mkdir /sys/fs/cgroup/manual/child
   echo "+memory" > /sys/fs/cgroup/manual/cgroup.subtree_control
   ```

   ```
   bash: echo: write error: Device or resource busy
   ```

   Move the process down one level and retry:

   ```bash
   echo $! > /sys/fs/cgroup/manual/child/cgroup.procs
   echo "+memory +pids" > /sys/fs/cgroup/manual/cgroup.subtree_control
   cat /sys/fs/cgroup/manual/cgroup.subtree_control
   ```

   ```
   memory pids
   ```

4. Tear it down. A cgroup can only be removed when empty, and only with `rmdir`:

   ```bash
   kill %1
   rmdir /sys/fs/cgroup/manual/child /sys/fs/cgroup/manual
   ```

5. Now the **correct** way on a systemd host: ask for a delegated subtree, and own it
   exclusively (<https://systemd.io/CGROUP_DELEGATION/>):

   ```bash
   systemd-run --unit=deleg --slice=lab.slice \
       -p Delegate=yes -p MemoryMax=256M \
       sleep 600
   ROOT=/sys/fs/cgroup/lab.slice/deleg.service
   cat $ROOT/cgroup.controllers
   mkdir $ROOT/worker-a $ROOT/worker-b
   echo "+memory +pids" > $ROOT/cgroup.subtree_control
   echo 64M > $ROOT/worker-a/memory.max
   systemd-cgls $ROOT
   ```

   ```
   memory pids cpu io
   Control group /lab.slice/deleg.service:
   ├─ 7213 sleep 600
   ├─worker-a
   └─worker-b
   ```

   Everything under `deleg.service` is now yours; systemd will not touch it, and the
   ceiling you set on the unit still binds the whole subtree.

6. (Optional) The `libcgroup` toolset, still named in the objectives. On v2 it
   requires libcgroup ≥ 3.0:

   ```bash
   cgcreate -g memory,pids:/lab-manual
   cgset -r memory.max=64M lab-manual
   cgget -g memory:lab-manual | head -4
   cgexec -g memory,pids:lab-manual -- sleep 60 &
   cgdelete -g memory,pids:/lab-manual
   ```

   Persistent v1 configuration lived in `/etc/cgconfig.conf` (definitions) and
   `/etc/cgrules.conf` (automatic classification by user/group/command, enforced by
   `cgrulesengd`); `cgclassify` moves already-running PIDs.

**Check your understanding**

- **Q36.** State the "no internal processes" rule precisely and explain why the root cgroup is exempt.
- **Q37.** Why can you only add a controller to `cgroup.subtree_control` if it appears in that cgroup's own `cgroup.controllers`?
- **Q38.** What does `Delegate=yes` actually change — name the two things systemd does differently for that unit.
- **Q39.** Why is manually creating `/sys/fs/cgroup/manual` on a systemd host a policy violation even though the kernel permits it?
- **Q40.** Which cgroup v1 features have **no** v2 equivalent through the filesystem, and how is one of them handled instead on v2?

---

## Exercise 12 — Pressure Stall Information and `systemd-oomd`

PSI measures *how long tasks were stalled* waiting for a resource — a far better
early-warning signal than utilisation, and the input `systemd-oomd` acts on.

1. Confirm PSI is available:

   ```bash
   cat /proc/pressure/memory
   cat /proc/pressure/io
   ```

   ```
   some avg10=0.00 avg60=0.00 avg300=0.00 total=1842991
   full avg10=0.00 avg60=0.00 avg300=0.00 total=402118
   ```

   If these files are absent, the kernel lacks `CONFIG_PSI` or was booted with
   `psi=0`; add `psi=1` to the kernel command line.

2. Read the per-cgroup counters, which is what makes PSI actionable per workload:

   ```bash
   cat /sys/fs/cgroup/lab.slice/memory.pressure
   cat /sys/fs/cgroup/lab.slice/cpu.pressure
   ```

3. Generate real pressure and watch `avg10` climb:

   ```bash
   systemd-run --unit=press --slice=lab.slice -p MemoryHigh=64M \
       python3 /root/memhog.py
   watch -n1 cat /sys/fs/cgroup/lab.slice/press.service/memory.pressure
   ```

   ```
   some avg10=71.42 avg60=38.11 avg300=9.02 total=18422991
   full avg10=64.88 avg60=33.70 avg300=8.14 total=16102118
   ```

   `some` = at least one task stalled; `full` = **every** runnable task stalled, i.e.
   the cgroup did no useful work at all during that fraction of time.

4. Configure `systemd-oomd` to act on that signal
   (<https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html>):

   ```bash
   systemctl status systemd-oomd.service --no-pager
   systemd-analyze cat-config systemd/oomd.conf
   ```

   ```
   [OOM]
   #SwapUsedLimit=90%
   #DefaultMemoryPressureLimit=60%
   #DefaultMemoryPressureDurationSec=30s
   ```

5. Opt a slice in — `systemd-oomd` only monitors cgroups that explicitly ask for it:

   ```bash
   systemctl set-property lab.slice \
       ManagedOOMMemoryPressure=kill \
       ManagedOOMMemoryPressureLimit=50% \
       ManagedOOMSwap=kill
   systemctl show lab.slice -p ManagedOOMMemoryPressure -p ManagedOOMMemoryPressureLimit
   ```

   ```
   ManagedOOMMemoryPressure=kill
   ManagedOOMMemoryPressureLimit=50%
   ```

6. Watch it decide:

   ```bash
   journalctl -u systemd-oomd.service -f
   ```

   ```
   systemd-oomd[721]: Memory pressure for /lab.slice is greater than 50% for
                      more than 30s with reclaim activity: 62.11% > 50% for 31s
   systemd-oomd[721]: Killed /lab.slice/press.service due to memory pressure
   ```

7. Control which unit gets sacrificed and how the kill is scoped:

   ```bash
   systemctl set-property press.service ManagedOOMPreference=avoid   # or: omit
   systemctl set-property press.service OOMPolicy=stop OOMScoreAdjust=500
   ```

**Check your understanding**

- **Q41.** Distinguish `some` from `full` in a PSI line, and explain why `full` is meaningless at the system-wide CPU level.
- **Q42.** Three different components can kill a process for memory reasons here. Name them and give the signal/mechanism each uses.
- **Q43.** `systemd-oomd` is running but never kills anything in your overloaded slice. Give the two configuration prerequisites you would check first.
- **Q44.** What does `OOMPolicy=` control, and how does it differ from `OOMScoreAdjust=`?

---

## Exercise 13 — Cgroup namespaces (awareness)

The objective requires awareness of cgroup namespaces: they virtualise the *view* of
the hierarchy, which is what lets a container see itself at `/` instead of at
`/system.slice/docker-abc123.scope`.

1. Note your real path, then enter a new cgroup namespace:

   ```bash
   cat /proc/self/cgroup
   ```

   ```
   0::/user.slice/user-1000.slice/session-3.scope
   ```

   ```bash
   unshare --cgroup --mount --pid --fork --mount-proc bash
   cat /proc/self/cgroup
   ```

   ```
   0::/
   ```

   Same cgroup, same limits — only the *name* changed. The namespace root was pinned
   to the cgroup that was current at `unshare()` time.

2. Confirm the limits still apply by reading a relative path inside the namespace:

   ```bash
   mount -t cgroup2 none /sys/fs/cgroup
   ls /sys/fs/cgroup/
   cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "root of namespace: no limit file"
   exit
   ```

3. Enumerate cgroup namespaces on the host:

   ```bash
   lsns -t cgroup
   ```

   ```
   NS         TYPE   NPROCS PID  USER  COMMAND
   4026531835 cgroup    214   1  root  /usr/lib/systemd/systemd --system …
   4026532741 cgroup      2 8123 root  bash
   ```

4. Enter an existing namespace by PID:

   ```bash
   nsenter -t 8123 -C -m -p -- cat /proc/self/cgroup
   ```

5. Observe that the `nsdelegate` mount option (visible in Exercise 1, step 2) makes
   the namespace root a **delegation boundary**: a process inside cannot migrate
   itself out of its namespace root, even with write access to an ancestor's
   `cgroup.procs`.

**Check your understanding**

- **Q45.** Does entering a cgroup namespace change the resource limits that apply to a process? What exactly does it change?
- **Q46.** Why is `--mount` (plus remounting `/sys/fs/cgroup`) usually combined with `--cgroup`?
- **Q47.** What does the `nsdelegate` mount option enforce, and why does it matter for unprivileged containers?

---

## Cleanup

```bash
systemctl stop lab-web.service cpu-a.service cpu-b.service \
               hog1.service hog2.service press.service deleg.service 2>/dev/null
systemctl disable lab-web.service 2>/dev/null
rm -rf /etc/systemd/system/lab-web.service /etc/systemd/system/lab-web.service.d
rm -f  /etc/systemd/system/lab.slice
rm -f  /etc/security/limits.d/90-lab.conf /etc/security/limits.d/91-lab-root.conf
rm -f  /root/memhog.py /root/forktest.sh /var/tmp/iotest.bin
systemctl daemon-reload
systemctl reset-failed
rmdir /sys/fs/cgroup/manual 2>/dev/null
echo mq-deadline > /sys/block/vda/queue/scheduler   # only if you changed it
systemd-cgls /lab.slice 2>/dev/null || echo "lab.slice gone"
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1 — hierarchy identification

**A1.** That is **hybrid** mode. `/sys/fs/cgroup/unified` carries a cgroup v2
hierarchy alongside the per-controller v1 mounts. Numbered lines (`8:memory:…`) are
v1 hierarchies, each with its own controller list and its own path. The `0::` line is
the v2 hierarchy: hierarchy ID 0, empty controller field, one path for all
controllers. In hybrid mode systemd uses the v2 hierarchy purely for *organisation*
and process tracking, while resource *control* still goes through the v1 controllers —
which is why a hybrid system will show `0::` but ignore `memory.max`.

**A2.** `systemd.unified_cgroup_hierarchy=0` forces legacy v1;
`systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=0`
selects hybrid. `systemd.unified_cgroup_hierarchy=1` (the default since systemd v243
on most distributions) selects unified v2. Set them via the bootloader — e.g.
`grubby --update-kernel=ALL --args=...` or `GRUB_CMDLINE_LINUX` plus
`grub2-mkconfig`.

**A3.** The child cgroup will have **no `io.*` files at all**. In v2 a controller's
interface files appear in a cgroup only if the **parent** enabled that controller in
its `cgroup.subtree_control`. A controller you cannot see is a controller you cannot
configure — this is the top cause of "I created the cgroup but `io.max` doesn't
exist".

### Exercise 2 — systemd's view

**A4.**
- **Slice** — a purely organisational unit that owns no processes itself; it groups
  other units into a tree node so limits can be applied to an entire branch.
- **Service** — a unit for processes systemd **started itself** via `ExecStart=`.
- **Scope** — a unit for processes that were **already forked by something else**
  (a login session, `systemd-run --scope`, a container manager) and are then
  *registered* with systemd.

  The scope is the one for foreign processes.

**A5.** `/sys/fs/cgroup/lab.slice/lab-db.slice`. For **slice units only**, the dash is
the hierarchy separator: `a-b-c.slice` is a child of `a-b.slice`, which is a child of
`a.slice`. (This does not apply to service or scope names, where `Slice=` alone
determines placement.)

**A6.** Accounting is off for that unit. Enable it with `systemctl set-property
<unit> MemoryAccounting=yes`, or globally with `DefaultMemoryAccounting=yes` in
`/etc/systemd/system.conf`. Setting any `Memory*=` limit turns accounting on
implicitly. On cgroup v2 with modern systemd the defaults are already `yes` for
memory, CPU, tasks and IO, so `[not set]` usually means an explicit
`MemoryAccounting=no` or a very old systemd.

### Exercise 3 — rlimits and PAM

**A7.**
- `@developers` — the **group** `developers`; matches any user who is a member.
- `%developers` — used **only** with `maxlogins`; it limits the *aggregate* number of
  simultaneous logins for all members of that group, rather than per user.
- Type `-` sets the **soft and hard limits simultaneously** to the same value.

  (Domains may also be a username, `*` as a catch-all applied last, a UID/GID range
  like `@1000:1999`, or `:1000` / `1000:` open-ended ranges.)

**A8.** (1) `pam_limits.so` is absent from the PAM stack for that particular service
(`/etc/pam.d/sshd` vs `/etc/pam.d/login` vs `/etc/pam.d/su` are all separate).
(2) The process is a **systemd service**, not a login session, so `limits.conf` never
applied — it needs `LimitNOFILE=` (Exercise 4). (3) The application never raised its
*soft* limit toward the hard limit, or hard-codes its own `setrlimit()` call. Also
check the system-wide ceiling `fs.file-max` and per-user `fs.nr_open`, and whether a
later `*` catch-all line in `limits.conf` is overriding the specific one.

**A9.** Raising a hard limit requires `CAP_SYS_RESOURCE`. `prlimit` run as root has
it; the target process does not. `prlimit` uses the `prlimit64(2)` syscall, which
operates on *another* process — it needs `CAP_SYS_RESOURCE` in the target's user
namespace, plus the usual ptrace-access permissions over the target.

### Exercise 4 — the limits.conf trap

**A10.**
- `/etc/security/limits.conf` + `/etc/security/limits.d/*.conf`, applied by
  `pam_limits.so`, govern **only processes that start inside a PAM session**:
  interactive logins, `ssh`, `su`, `sudo`, `cron` jobs (via `pam_limits` in
  `/etc/pam.d/crond`), display managers.
- `Limit*=` in a systemd unit (`systemd.exec(5)`), with
  `DefaultLimit*=` in `/etc/systemd/system.conf` and `/etc/systemd/user.conf` as
  fallbacks, govern **units systemd starts** — i.e. every daemon on the machine.

**A11.** `soft:hard`. A single value sets **both** soft and hard to the same number.
`infinity` is accepted for either field.

**A12.** Not directly. PAM applies `limits.conf` to the **`systemd --user` manager
process** at session setup, and the manager's rlimits are then inherited by the user
services it spawns — unless the user unit overrides them with its own `Limit*=`, or
`/etc/systemd/user.conf`'s `DefaultLimit*=` does. So the value arrives by inheritance
through the manager, not by PAM evaluating each user service.

### Exercise 5 — memory control

**A13.**
| File | systemd | Semantics |
|---|---|---|
| `memory.min` | `MemoryMin=` | **Hard protection.** Memory below this is never reclaimed, even under global pressure; can push the system to OOM to honour it. |
| `memory.low` | `MemoryLow=` | **Best-effort protection.** Reclaim avoids this cgroup until other candidates are exhausted. |
| `memory.high` | `MemoryHigh=` | **Throttle.** Above it, allocating tasks are heavily throttled and reclaim is forced. Never triggers the OOM killer. |
| `memory.max` | `MemoryMax=` | **Hard ceiling.** Reclaim first, then invoke the cgroup OOM killer on failure. |

Also `memory.swap.max` / `MemorySwapMax=`, and `memory.zswap.max` / `MemoryZSwapMax=`.

**A14.** The **cgroup OOM killer**, invoked by the memory controller when the cgroup
hits `memory.max` and reclaim cannot make room. It chooses a victim from **within
that cgroup only**, ranked by `oom_score` (roughly proportional to RSS, adjusted by
`oom_score_adj`). The *global* OOM killer fires when the whole machine is out of
memory and picks from **all** processes system-wide. The practical difference is
containment: a cgroup OOM kills the offender and leaves the rest of the machine
untouched. Setting `memory.oom.group=1` (systemd: `OOMPolicy=` interactions / cgroup
attribute) makes the kill apply to every process in the cgroup atomically instead of
one victim.

**A15.** Without it, the kernel can satisfy the allocation by swapping out anonymous
pages. The cgroup's `memory.current` stays at the ceiling while the workload keeps
growing into swap, so the OOM kill happens late, slowly, or not at all — timing
becomes disk-speed-dependent. `MemorySwapMax=0` removes swap as an escape valve and
makes the wall hard and immediate.

**A16.** systemd **generates slice units implicitly**. Any name ending in `.slice`
that has no unit file on disk is instantiated with default (unlimited) properties.
That makes ad-hoc grouping cheap, but it also means a typo in `--slice=` silently
creates a new empty slice instead of failing — verify with `systemctl show <unit> -p
Slice`.

### Exercise 6 — CPU

**A17.** With `CPUWeight=10` on an idle machine: **all 8 CPUs, 800 %** if it can use
them. Weight is proportional and only binds under contention — it is never a ceiling.
With `CPUQuota=10%`: **0.1 of one CPU**, always, idle machine or not.

**A18.** `CPUWeight=` accepts **1–10000**, default **100**. It maps to `cpu.weight`
and replaces cgroup v1's `cpu.shares` (whose range was 2–262144, default 1024).
systemd converts between the two ranges automatically when running on v1.

**A19.** `CPUAffinity=` calls `sched_setaffinity(2)` on the process at exec time — it
is a **process attribute** and a child can call `sched_setaffinity()` to widen itself
back out (subject to permissions). `AllowedCPUs=` sets `cpuset.cpus` in the cgroup —
it is a **cgroup attribute**, enforced by the kernel for every task in the cgroup, and
cannot be escaped from inside. For containment, use `AllowedCPUs=`. `AllowedMemoryNodes=`
is the NUMA-node equivalent (`cpuset.mems`).

**A20.** `--runtime` writes the drop-in to `/run/systemd/system/…` instead of
`/etc/systemd/system/…`, so the change is applied immediately but **disappears at
reboot**. It is the right choice for lab experiments, incident mitigation and anything
you do not want to leave behind on the filesystem.

### Exercise 7 — persistence

**A21.** In increasing order of persistence:
1. `systemd-run -p …` — transient; the unit and its limits vanish when the process
   exits.
2. `systemctl set-property --runtime` — applied immediately, lives in
   `/run/systemd/system/`, lost at reboot.
3. `systemctl set-property` (no flag) or `systemctl edit` — drop-in under
   `/etc/systemd/system/<unit>.d/`, survives reboots **and** package upgrades of the
   base unit file.

**A22.** A limit is meaningless without a counter: the kernel must track the resource
to know when the threshold is crossed, so systemd enables the corresponding
`*Accounting=` implicitly. Historically, on cgroup v1 the memory controller carried a
measurable per-page overhead (a separate page-counter hierarchy, roughly 1 % of
memory plus a fault-path cost), so distributions left `DefaultMemoryAccounting=no`.
cgroup v2 folded accounting into the page cache path and made it essentially free,
which is why modern systemd defaults it to `yes`.

**A23.** A **drop-in** in `/etc/systemd/system/lab-web.service.d/override.conf`
(created by `systemctl edit`). Package upgrades replace the vendor unit under
`/usr/lib/systemd/system/` — or, if the package ships to `/etc`, the package manager
prompts — but drop-in directories are never touched, and their `[Section]` values are
merged on top of whatever the vendor file says. Replacing the whole unit file in
`/etc` also works but silently diverges from upstream changes.

### Exercise 8 — slices

**A24.** For slice units, `-` separates path components: `a-b-c.slice` lives at
`/a.slice/a-b.slice/a-b-c.slice`. The parent of `machine-qemu\x2dvm1.slice` is
`machine.slice` — the `\x2d` is a **systemd-escaped literal hyphen** in the VM's name
`qemu-vm1`, so it does not create another level. Use `systemd-escape -u` to decode.

**A25.** **512 MiB.** Limits compose down the tree by intersection: a child can only
ever be *more* restrictive than the sum available from its ancestors. Setting a child
limit higher than its parent's is legal and silently ineffective — a common
misconfiguration to look for when a limit "isn't working".

**A26.** `-.slice` (the root), `system.slice` (system services), `user.slice`
(user sessions, subdivided into `user-<UID>.slice`), and `machine.slice`
(VMs and containers registered with `systemd-machined`). `init.scope` also sits at
the root, holding PID 1 itself, but it is a scope, not a slice.

**A27.** It gives you an enforceable **aggregate** ceiling. Per-service limits do not
compose: N users each within their individual limits can still exhaust the machine
together. Capping `user.slice` guarantees a fixed reserve for `system.slice` — sshd,
the monitoring agent, the audit daemon stay responsive — so you can still log in and
diagnose a machine that interactive users have overloaded. This is the standard
"keep the box reachable" pattern.

### Exercise 9 — pids

**A28.** (1) `ulimit -u` (`RLIMIT_NPROC`) counts processes **per real UID across the
whole system**, so a workload that drops privileges to a second UID, or a `setuid`
helper, gets a fresh budget; `TasksMax` counts per cgroup regardless of UID.
(2) A privileged process with `CAP_SYS_RESOURCE` can raise its own `RLIMIT_NPROC` at
runtime; it cannot raise `pids.max`, which is written from outside the cgroup. Also:
`RLIMIT_NPROC` is not enforced for root at all on many kernels, while `pids.max` is.

**A29.** Percent of `/proc/sys/kernel/threads-max` — the kernel's system-wide maximum
number of tasks. `DefaultTasksMax=15%` is the historical systemd default expressed
that way.

**A30.** The number of times a `fork()`/`clone()` in that cgroup was **refused**
because `pids.current` had reached `pids.max`. The workload saw `fork()` return
`-EAGAIN`, i.e. `Resource temporarily unavailable`. (`pids.events.local` distinguishes
refusals caused by this cgroup's own limit from those inherited from an ancestor.)

**A31.** It maintains a single integer counter incremented and decremented at
`fork()`/`exit()` — no per-page bookkeeping, no scheduler involvement, no I/O path
hook. Because the cost is unmeasurable and the failure it prevents (fork bomb, thread
leak, PID exhaustion locking you out of the machine entirely) is catastrophic and
unrecoverable without a reboot, `TasksMax=` is the one limit worth setting on
everything by default.

### Exercise 10 — I/O

**A32.** Reads and direct/synchronous writes are issued in the context of the
requesting task, so the block layer knows which cgroup to charge. **Buffered writes**
are issued much later by kernel writeback threads, in a completely different context.
cgroup v2 solves this by tagging each dirty page with its owning memory cgroup at
fault time and having writeback consult that tag — which requires **both the `memory`
and the `io` controller enabled on the same unified hierarchy**. This is one of the
central reasons v2 exists at all: on v1 the two controllers lived in separate
hierarchies, so buffered-write throttling was fundamentally impossible.

**A33.** `IOWeight=` (→ `io.weight`, range 1–10000, default 100) is **proportional**:
it only divides bandwidth when devices are contended, and never idles a device.
`IOReadBandwidthMax=` / `IOWriteBandwidthMax=` (→ `io.max` `rbps=`/`wbps=`) are
**absolute ceilings**, enforced even when the device is idle; `IOReadIOPSMax=` /
`IOWriteIOPSMax=` are their operation-rate equivalents. On cgroup v1 these were
`blkio.weight` and `blkio.throttle.read_bps_device` in the `blkio` controller.

**A34.** (1) The active I/O scheduler is `none` (typical for NVMe with `mq`), so
nothing implements proportional weighting — you need **BFQ**, or the `blk-iocost`
cost model configured via `io.cost.qos` / `io.cost.model` (systemd exposes it as
`IOReadBandwidthMax`-adjacent `io.cost` tuning, usually via `iocost.conf`).
(2) There is **no contention**: weights are invisible unless two cgroups are
competing for the same device at the same time. A third possibility is that the
`io` controller is not in the parent's `cgroup.subtree_control`.

**A35.** The block layer identifies devices by `dev_t` (major:minor), not by path — a
device can have many `/dev` names via symlinks and `udev` rules, and a path means
nothing to the kernel at that layer. Writing `/dev/vda` directly into `io.max` yields
`write error: Invalid argument`. systemd is friendlier: `IOReadBandwidthMax=/dev/vda
20M` accepts a path (or even a filesystem mount point) and resolves it to
`major:minor` for you at apply time — which is also why it can silently do nothing if
the path does not exist yet when the unit starts.

### Exercise 11 — raw cgroups and delegation

**A36.** **A non-root cgroup may contain processes, or it may distribute resources to
child cgroups, but not both.** Concretely: you cannot write to `cgroup.subtree_control`
while `cgroup.procs` is non-empty, and you cannot move a process into a cgroup that
already has controllers enabled for its children. The root is exempt because it must
hold processes that exist before any cgroup structure does (kernel threads, early
init) and has nowhere to delegate them to. The rule exists so that resource
competition is always **between siblings** — a well-defined distribution problem —
rather than between a parent's own tasks and its children, which has no coherent
answer. (Threaded cgroups, `cgroup.type=threaded`, are the deliberate exception for
CPU-only thread-level control.)

**A37.** Because `cgroup.controllers` is exactly the set the **parent** granted you by
listing it in *its* `cgroup.subtree_control`. Availability propagates strictly
top-down, one level at a time, and this is what makes delegation safe: a delegated
subtree can never enable a controller its delegator withheld, so a container cannot
grant itself I/O control the host did not intend to give it.

**A38.** (1) systemd **stops managing the cgroup's interior** — it will not create,
remove or reassign cgroups below the unit, and it will not reset attributes there.
(2) It **grants write ownership** to the unit's user: `chown`s the unit's cgroup
directory, `cgroup.procs`, `cgroup.subtree_control` and `cgroup.threads` to the
unit's `User=`, and enables the requested controllers in the unit's own
`cgroup.subtree_control` so the subtree can actually use them. `Delegate=memory pids`
grants a specific subset. It also implies `cgroup` namespace support in the delegation
boundary sense (`nsdelegate`).

**A39.** It breaks the **single-writer rule** (<https://systemd.io/CGROUP_DELEGATION/>).
systemd assumes it is the sole owner of the tree outside delegated subtrees; it may
reset attributes, prune "unknown" cgroups on `daemon-reload`, or produce accounting
that does not match reality. Your cgroup can also disappear underneath you without
warning. The supported path is a unit with `Delegate=yes`, which gives you a subtree
systemd contractually promises not to touch.

**A40.** Removed in v2: **`net_cls` and `net_prio`** (classid/priority tagging), the
standalone **`devices`** controller file interface, **`freezer`**'s v1 interface, and
**`cpuacct`** as a separate controller. Their replacements: device access is now an
**eBPF program** attached to the cgroup (`BPF_PROG_TYPE_CGROUP_DEVICE`, exposed by
systemd as `DeviceAllow=`/`DevicePolicy=`); network classification is done with
`bpf_get_cgroup_classid()`/cgroup-attached eBPF (systemd: `IPAddressAllow=`,
`SocketBindAllow=`, `RestrictNetworkInterfaces=`); freezing is now the
`cgroup.freeze` core file (systemd: `systemctl freeze`/`thaw`); and CPU accounting is
folded into `cpu.stat`.

### Exercise 12 — PSI and oomd

**A41.** `some` = the share of wall time in which **at least one** runnable task was
stalled waiting for the resource — a *contention* signal. `full` = the share in which
**every** runnable task was stalled simultaneously — a *total loss of productive
work* signal. `full` is undefined/always zero for CPU at the system level, because if
every task were stalled on CPU there would by definition be no task to run and
therefore nothing stalling — CPU is never "unavailable" globally, only contended. It
*is* meaningful per-cgroup (`cpu.pressure`), where a throttled cgroup genuinely can
have all its tasks stalled while other cgroups run.

**A42.**
1. **Kernel cgroup OOM killer** — fires on `memory.max` when reclaim fails; sends
   `SIGKILL` to the highest-`oom_score` task in that cgroup (or the whole cgroup with
   `memory.oom.group=1`).
2. **Kernel global OOM killer** — fires on system-wide exhaustion; `SIGKILL` to the
   worst offender anywhere.
3. **`systemd-oomd`** — a *userspace* daemon acting on PSI and swap thresholds
   *before* the kernel is out of memory; it kills a whole **cgroup** (all its
   processes) via `SIGKILL`, choosing among units that opted in with
   `ManagedOOM*=kill`. Being proactive is the point: it acts while the machine is
   thrashing but still recoverable, whereas the kernel acts only at true exhaustion.

**A43.** (1) No cgroup opted in — `ManagedOOMMemoryPressure=kill` (or
`ManagedOOMSwap=kill`) must be set on a **slice**, and `systemd-oomd` only ever kills
*descendants* of a monitored slice, never the slice itself if it is a leaf with
processes. (2) Accounting/PSI missing — the slice needs `MemoryAccounting=yes`, and
`/proc/pressure/` must exist (`CONFIG_PSI`, not booted with `psi=0`). Then check that
the pressure genuinely exceeded `ManagedOOMMemoryPressureLimit=` for the full
`DefaultMemoryPressureDurationSec=` (default 30 s) *with reclaim activity* — a brief
spike will not trigger it.

**A44.** `OOMPolicy=` (`continue` | `stop` | `kill`) tells **systemd** what to do with
the rest of the *unit* after the kernel OOM-kills one of its processes: leave it
running, stop the unit, or kill every remaining process in it. `OOMScoreAdjust=`
(−1000…1000) is written to `/proc/PID/oom_score_adj` and biases the **kernel's**
choice of victim — −1000 makes a process effectively immune, +1000 makes it the first
to die. One shapes the aftermath, the other shapes the selection.

### Exercise 13 — cgroup namespaces

**A45.** **No, limits are unchanged.** The process stays in exactly the same cgroup
and every `memory.max`, `cpu.max` and `pids.max` above it still binds. What changes is
the **view**: `/proc/self/cgroup` reports paths relative to the namespace's root
cgroup, so a containerised process sees `0::/` instead of
`0::/system.slice/docker-abc.scope`. This is presentation, not enforcement.

**A46.** Because `/proc/self/cgroup` is only half the picture — the `/sys/fs/cgroup`
mount inherited from the host still exposes the *entire* host hierarchy, leaking
sibling and ancestor cgroup names and paths. A private mount namespace lets you
remount `cgroup2` so its root is your namespace root, making the view consistent and
preventing information disclosure. Container runtimes always do both.

**A47.** `nsdelegate` makes each cgroup namespace root a **delegation boundary** the
kernel enforces: a process inside cannot move itself (or anything else) to a cgroup
**outside** its namespace root, even if it has write permission on the target's
`cgroup.procs`, and it cannot modify resource-control files at or above that root.
For unprivileged containers this is what lets the host hand a subtree to a container
that manages its own internal cgroups freely, with a hard guarantee it cannot escape
the ceiling the host set on the boundary cgroup.

</details>