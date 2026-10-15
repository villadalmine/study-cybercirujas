# LPIC-2 · Topic 200.1 — Measure and Troubleshoot Resource Usage
## Guided exercises (LPI weight 6 · exam 201-450, objectives version 4.5.0)

> **What this topic really asks of you.** Not "name a tool", but: given a box that is *slow*, decide **which of the four resources** (CPU, memory, disk I/O, network I/O) is saturated, **prove it with a number**, **attribute it to a process or a client**, and **estimate whether the number is near the hardware's ceiling**. Every exercise below ends in a number you can defend.
>
> LPI's partial list of files, terms and utilities for this objective is, verbatim: `iostat`, `iotop`, `vmstat`, `netstat`, `ss`, `iptraf`, `pstree`, `ps`, `w`, `lsof`, `top`, `htop`, `uptime`, `sar`, swap, processes blocked on I/O, blocks in, blocks out. Confirm the current list on the official objectives page — LPI revises it: <https://www.lpi.org/our-certifications/exam-201-202-objectives/>. The exercises add the modern equivalents a production engineer is expected to reach for (`mpstat`, `pidstat`, `nstat`, `nft`, PSI, cgroup v2), because in a real incident you will be judged on the diagnosis, not on tool vintage.

### Lab requirements

- A **throwaway VM or container host** with `sudo`. Several steps load the machine deliberately, write sysctls, and install firewall rules. Do not do this on anything you care about.
- Kernel 5.x/6.x, `systemd`, cgroup v2 (`stat -fc %T /sys/fs/cgroup` → `cgroup2fs`).
- Packages: `sysstat procps iproute2 util-linux lsof psmisc stress-ng fio iperf3 nftables conntrack iotop iftop nethogs iptraf-ng jq bc gawk ethtool`.
- Two terminals side by side (one generates load, one measures). A third helps.

### How to use it

Run the numbered steps in order inside a lab. After each block answer the **Checkpoint** questions *before* reading on — the answers are in the collapsible section at the end. Numbers in the sample outputs are from one particular lab machine; yours will differ, the *relationships* between them will not.

---

## Lab 0 — Baseline, and the method

Measuring without a baseline produces opinions. This lab is five minutes of work that makes every later lab interpretable.

1. Install the toolchain and confirm the clock tick, which every `/proc` counter in this topic is denominated in:

```bash
sudo apt-get install -y sysstat procps iproute2 util-linux lsof psmisc \
  stress-ng fio iperf3 nftables conntrack iotop iftop nethogs iptraf-ng jq bc gawk ethtool
getconf CLK_TCK
nproc
```

```
100
8
```

2. Take a baseline snapshot into a file you can diff against later. Note that each tool is asked for *two* samples, so the second one is an interval measurement, not an average since boot:

```bash
ts=$(date +%Y%m%dT%H%M%S); out=~/baseline-$ts.txt
{
  echo "=== uptime ==="      ; uptime
  echo "=== w ==="           ; w
  echo "=== vmstat 1 2 ===" ; vmstat 1 2
  echo "=== mpstat 1 2 ===" ; mpstat -P ALL 1 2
  echo "=== free -w ==="     ; free -w
  echo "=== iostat -x 1 2 ===" ; iostat -xz 1 2
  echo "=== sar -n DEV 1 2 ===" ; sar -n DEV 1 2
  echo "=== ss -s ==="       ; ss -s
  echo "=== psi ==="         ; grep . /proc/pressure/*
} | tee "$out" >/dev/null
echo "$out"
```

3. Look at the two load-average sources and at who is logged in:

```bash
cat /proc/loadavg
uptime
w
```

```
0.52 0.61 0.58 2/412 31844
 12:03:58 up 4 days,  2:11,  2 users,  load average: 0.52, 0.61, 0.58
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
root     pts/0    10.0.0.5         11:58    0.00s  0.03s  0.00s w
deploy   pts/1    10.0.0.9         09:12   2:41m  1:12   1:12  ./report.sh
```

4. Identify the shape of the process tree you are about to perturb:

```bash
pstree -ap | head -20
ps -eo pid,ppid,stat,pcpu,pmem,rss,wchan:16,comm --sort=-pcpu | head -10
```

**Checkpoint — Q1–Q3**

- **Q1.** `/proc/loadavg` shows `0.52 0.61 0.58 2/412 31844`. What exactly are the last two fields, and what are the first three counting on Linux specifically (the answer differs from classic UNIX)?
- **Q2.** `w` shows `JCPU 1:12` and `PCPU 1:12` for `deploy`. What is the difference between those two columns, and why is `IDLE 2:41m` not evidence that the user is consuming nothing?
- **Q3.** Why does step 2 ask every tool for **two** samples at a one-second interval instead of one?

---

## Lab 1 — CPU: from `/proc/stat` arithmetic to the guilty thread

### 1A — Compute utilization by hand, then check a tool against it

1. Read the aggregate CPU line and the per-CPU lines:

```bash
grep -E '^cpu' /proc/stat | head -3
```

```
cpu  4812344 11204 1398221 884213996 412884 0 88412 0 0 0
cpu0 601122 1402 174883 110512441 51214 0 12044 0 0 0
cpu1 598412 1388 173994 110538112 50882 0 11388 0 0 0
```

The ten fields after the label are, in order: `user nice system idle iowait irq softirq steal guest guest_nice`, each in units of `1/CLK_TCK` seconds.

2. Write the calculator. Read the comment on which fields are summed — that choice is the whole lesson:

```bash
cat > ~/cpu-util.sh <<'EOF'
#!/bin/bash
# cpu-util.sh [interval] -- CPU utilisation from two /proc/stat samples.
# total = fields 2..9 (user..steal) ONLY: guest/guest_nice are already
# included inside user/nice by the kernel, so adding them double-counts.
snap() { awk '/^cpu /{ idle=$5+$6; total=0; for (i=2;i<=9;i++) total+=$i;
                       print idle, total }' /proc/stat; }
iv=${1:-1}
read -r i1 t1 < <(snap); sleep "$iv"; read -r i2 t2 < <(snap)
awk -v i1="$i1" -v t1="$t1" -v i2="$i2" -v t2="$t2" -v iv="$iv" 'BEGIN{
  dt=t2-t1; di=i2-i1;
  printf "interval=%ss  ticks=%d  busy=%.2f%%  idle+iowait=%.2f%%\n",
         iv, dt, 100*(dt-di)/dt, 100*di/dt }'
EOF
chmod +x ~/cpu-util.sh
~/cpu-util.sh 5
```

```
interval=5s  ticks=4000  busy=7.35%  idle+iowait=92.65%
```

3. Verify the tick accounting: with `CLK_TCK=100` and 8 CPUs, a 5-second interval must yield ≈ `5 × 100 × 8 = 4000` ticks across all fields. Confirm the printed `ticks` matches.

4. Now load exactly one CPU and compare your script with `mpstat`:

```bash
# terminal 1
stress-ng --cpu 1 --cpu-method matrixprod --timeout 60s
```

```bash
# terminal 2
~/cpu-util.sh 5
mpstat -P ALL 1 3
```

```
12:14:11     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
12:14:12     all   12.52    0.00    0.38    0.00    0.00    0.12    0.00    0.00    0.00   86.98
12:14:12       0   99.01    0.00    0.99    0.00    0.00    0.00    0.00    0.00    0.00    0.00
12:14:12       1    0.00    0.00    1.01    0.00    0.00    0.00    0.00    0.00    0.00   98.99
```

**Checkpoint — Q4–Q7**

- **Q4.** One CPU is pinned at 100% but `all` reads `%usr 12.52`. Compute 100/8 and explain why the aggregate line is the single most dangerous number on a multi-core box.
- **Q5.** Convert the `user` field of the first `/proc/stat` output (`4812344`) into seconds, then into CPU-hours. What command gave you the conversion factor?
- **Q6.** Why does the script sum only fields 2–9? What specifically would be wrong about the result on a KVM host running guests, if you summed all ten?
- **Q7.** A colleague computes utilization as `100 - %idle`. On which workload does that overstate CPU demand, and which field is responsible?

### 1B — `%iowait`, `%steal` and the two kinds of "not running"

1. Generate pure I/O wait with no CPU work, and observe:

```bash
# terminal 1 -- synchronous reads straight from the device, no page cache
sudo dd if=/dev/sda of=/dev/null bs=4k count=200000 iflag=direct
```

```bash
# terminal 2
mpstat -P ALL 1 5
vmstat 1 5
```

```
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 0  1      0 241664  85320 5120228    0    0 38124     0 1844 3122  1  3 71 25  0  0
 0  1      0 241664  85320 5120228    0    0 39012     0 1902 3188  1  3 70 26  0  0
```

2. Note the `b` column (processes blocked on uninterruptible I/O) and that `wa` is high while `us`+`sy` stay near zero.

3. Compare the run queue with the load average under *CPU* load versus under *I/O* load:

```bash
stress-ng --cpu 4 --timeout 30s &
sleep 20; cat /proc/loadavg; vmstat 1 3 | tail -2; wait
```

4. Find uninterruptible-sleep processes and what they are blocked on:

```bash
ps -eo pid,stat,wchan:24,comm | awk 'NR==1 || $2 ~ /^D/'
sudo cat /proc/$(pgrep -n dd)/stack 2>/dev/null | head
```

```
    PID STAT WCHAN                    COMMAND
  31902 D+   blk_mq_get_tag           dd
```

5. On a virtual machine, check for stolen time — the hypervisor running someone else on your vCPU:

```bash
mpstat -P ALL 1 3 | awk '{print $2, $NF, $(NF-3)}' | head
grep -c . /proc/pressure/cpu && cat /proc/pressure/cpu
```

### 1C — Pressure Stall Information: saturation, not utilization

1. Read the PSI files. Values are percentages of wall time over 10/60/300-second decaying windows; `total` is cumulative microseconds:

```bash
grep . /proc/pressure/*
```

```
/proc/pressure/cpu:some avg10=0.00 avg60=0.12 avg300=0.08 total=18412334
/proc/pressure/cpu:full avg10=0.00 avg60=0.00 avg300=0.00 total=0
/proc/pressure/io:some avg10=0.00 avg60=0.04 avg300=0.02 total=9122841
/proc/pressure/io:full avg10=0.00 avg60=0.01 avg300=0.01 total=4011223
/proc/pressure/memory:some avg10=0.00 avg60=0.00 avg300=0.00 total=0
/proc/pressure/memory:full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

2. Oversubscribe the CPUs by 4× and watch `cpu some` climb while `%idle` stays at zero in both the healthy and the overloaded case:

```bash
stress-ng --cpu $(( $(nproc) * 4 )) --timeout 30s &
for i in $(seq 6); do sleep 5; echo -n "$(date +%T) "; cat /proc/pressure/cpu | head -1; done
wait
```

```
12:22:04 some avg10=71.44 avg60=22.18 avg300=4.91 total=41223884
12:22:09 some avg10=88.02 avg60=36.44 avg300=8.12 total=45812990
```

3. Attribute it. `top -H` and `pidstat -t` work at thread granularity, which `ps`'s default process view hides:

```bash
pidstat -u -t 1 3 | head -20
top -b -H -n 1 -o %CPU | head -15
```

**Checkpoint — Q8–Q13**

- **Q8.** `vmstat` shows `r 0`, `b 1`, `wa 25`, `us 1`. Is the CPU a bottleneck? What *is* the bottleneck, and which single `vmstat` column is the strongest hint about which device to look at next?
- **Q9.** Under `stress-ng --cpu 4` the load average converges near 4.00. Under the `dd iflag=direct` run, load average also rises although the CPU is idle. Explain mechanically why, and name the process state involved.
- **Q10.** `WCHAN` reads `blk_mq_get_tag`. What layer is the process blocked in, and what does that tell you about queue depth on that device?
- **Q11.** `%steal` is 18% sustained on a cloud instance. Which three remediations are available to you as the *guest* administrator, and which one is not (and why)?
- **Q12.** Explain the difference between `cpu some` and the `cpu full` line, which is always zero in `/proc/pressure/cpu`. Why is `full` meaningful for `io` and `memory` system-wide but not for `cpu`, and where is `cpu full` meaningful?
- **Q13.** Utilization is 100% in two different incidents; in one, PSI `cpu some avg10` is 2%, in the other it is 85%. Which one is healthy, and what word distinguishes the two conditions?

---

## Lab 2 — Memory: free, available, cached, and who actually owns a page

### 2A — Reconcile `free` with `/proc/meminfo` exactly

1. Capture both at the same moment:

```bash
free -w; echo; grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|Dirty|Writeback|AnonPages|Mapped|Shmem|Slab|SReclaimable|SUnreclaim|SwapTotal|SwapFree|CommitLimit|Committed_AS):' /proc/meminfo
```

```
               total        used        free      shared     buffers       cache   available
Mem:        16037324     2142056      241664      412332       85320    13568284    13093116
Swap:        4194300       12288     4182012

MemTotal:       16037324 kB
MemFree:          241664 kB
MemAvailable:   13093116 kB
Buffers:           85320 kB
Cached:         13211952 kB
SwapCached:         4096 kB
Dirty:            412664 kB
Writeback:          8192 kB
AnonPages:       1944312 kB
Mapped:           612480 kB
Shmem:            412332 kB
Slab:             498132 kB
SReclaimable:     356332 kB
SUnreclaim:       141800 kB
SwapTotal:        4194300 kB
SwapFree:         4182012 kB
CommitLimit:    12212960 kB
Committed_AS:    6421884 kB
```

2. Derive `free`'s columns yourself, with `bc`:

```bash
awk '/^(MemTotal|MemFree|Buffers|Cached|SReclaimable|Shmem):/{gsub(":","");m[$1]=$2}
     END{ cache=m["Cached"]+m["SReclaimable"];
          used=m["MemTotal"]-m["MemFree"]-m["Buffers"]-cache;
          printf "derived cache  = %d kB\nderived used   = %d kB\nderived shared = %d kB\n",
                 cache, used, m["Shmem"] }' /proc/meminfo
```

```
derived cache  = 13568284 kB
derived used   = 2142056 kB
derived shared = 412332 kB
```

3. Compare `free + buffers + cache` against `MemAvailable` and quantify the gap:

```bash
awk '/^(MemFree|Buffers|Cached|SReclaimable|MemAvailable|Shmem):/{gsub(":","");m[$1]=$2}
     END{ naive=m["MemFree"]+m["Buffers"]+m["Cached"]+m["SReclaimable"];
          printf "naive free-ish = %d kB\nMemAvailable   = %d kB\ngap            = %d kB (Shmem=%d)\n",
                 naive, m["MemAvailable"], naive-m["MemAvailable"], m["Shmem"] }' /proc/meminfo
```

```
naive free-ish = 13895268 kB
MemAvailable   = 13093116 kB
gap            = 802152 kB (Shmem=412332)
```

**Checkpoint — Q14–Q17**

- **Q14.** Write the identity that `free -w` satisfies, and state which `/proc/meminfo` field `free` folds into its `cache` column besides `Cached`. Why is that field included?
- **Q15.** `MemAvailable` is 802 MB *below* `free + buffers + cache`. Name two distinct categories of memory that are counted in `Cached` or in the LRU lists but cannot be handed to a new allocation.
- **Q16.** `Dirty` is 412 MB. What happens to `MemAvailable` if that number is instead 6 GB, and what latency symptom does a large `Dirty` predict?
- **Q17.** `CommitLimit` is 12.2 GB while `MemTotal` is 15.3 GB. Which sysctl pair produced that number, and what does `Committed_AS 6.4 GB` mean operationally — is it memory in use?

### 2B — Page cache is not a leak

1. Observe cache fill and the fact that it is free memory in disguise:

```bash
free -w | awk 'NR==2'
dd if=/dev/zero of=/var/tmp/cachefill bs=1M count=2048 oflag=sync status=none
free -w | awk 'NR==2'
grep -E '^(Dirty|Writeback):' /proc/meminfo
```

2. Read the file back to populate the cache, then prove it is reclaimable without killing anything:

```bash
cat /var/tmp/cachefill > /dev/null
free -w | awk 'NR==2'
sync; sudo sh -c 'echo 1 > /proc/sys/vm/drop_caches'   # lab only, never in production
free -w | awk 'NR==2'
```

3. Measure the cache's effect, which is the only reason it exists:

```bash
sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
time cat /var/tmp/cachefill > /dev/null     # cold
time cat /var/tmp/cachefill > /dev/null     # warm
```

```
real	0m8.412s     # cold
real	0m0.372s     # warm
```

### 2C — Per-process memory: RSS lies, PSS does not

1. Compare the three views of one process's footprint:

```bash
pid=$(pgrep -n -f sshd || pgrep -n bash)
ps -o pid,vsz,rss,comm -p "$pid"
sudo pmap -x "$pid" | tail -3
sudo cat /proc/"$pid"/smaps_rollup
```

```
    PID    VSZ   RSS COMMAND
   1844  17204  9612 sshd

total kB           17204    9612    1120

Rss:                9612 kB
Pss:                3284 kB
Shared_Clean:       6912 kB
Shared_Dirty:          0 kB
Private_Clean:       416 kB
Private_Dirty:      2284 kB
Swap:                  0 kB
```

2. Sum RSS across all processes and compare with physically used memory — the sum will exceed it:

```bash
ps -eo rss= | awk '{s+=$1} END{printf "sum(RSS) = %d kB\n", s}'
awk '/^(MemTotal|MemFree|Buffers|Cached|SReclaimable):/{gsub(":","");m[$1]=$2}
     END{printf "used     = %d kB\n", m["MemTotal"]-m["MemFree"]-m["Buffers"]-m["Cached"]-m["SReclaimable"]}' /proc/meminfo
```

3. Rank by PSS instead, which is additive:

```bash
for p in $(ps -eo pid=); do
  v=$(sudo awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null) || continue
  [ -n "$v" ] && echo "$v $p $(cat /proc/$p/comm 2>/dev/null)"
done | sort -nr | head -8
```

4. Find what a process has open, which frequently explains both its RSS and its I/O:

```bash
sudo lsof -p "$pid" | head
sudo lsof +L1 | head        # deleted files still held open: invisible disk usage
sudo fuser -vm /var/tmp 2>&1 | head
```

**Checkpoint — Q18–Q21**

- **Q18.** `sum(RSS)` over all processes is larger than the memory actually used. Give the mechanism, and name the field in `smaps_rollup` that fixes the arithmetic.
- **Q19.** For `sshd`: `VSZ 17204`, `RSS 9612`, `Pss 3284`. Explain each, and say which one you would alert on for a 500-process fleet of forked workers.
- **Q20.** After `echo 1 > drop_caches` the `cache` column falls but `free` rises by slightly less than the drop. Where did the difference go? And what does `echo 3` drop that `echo 1` does not?
- **Q21.** `lsof +L1` reports a 40 GB file with link count 0. Which tool reported the space as used, which reported it as free, and what is the fix that does *not* involve a reboot?

### 2D — Swap, thrashing, and two different OOM kills

1. Distinguish "swap is used" from "the system is swapping":

```bash
free -w | awk 'NR==3'
vmstat 1 5 | awk 'NR<3 || 1'
cat /proc/vmstat | grep -E '^(pswpin|pswpout|pgmajfault|pgfault)'
cat /proc/sys/vm/swappiness
```

2. Force real swap traffic and watch `si`/`so` become non-zero (this will make the box briefly unpleasant — it is the point):

```bash
stress-ng --vm 2 --vm-bytes 80% --vm-keep --timeout 45s &
vmstat 1 10
wait
```

```
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 3  2 1884412  98124   4120  212884 48124 71220  912  2104 8412 24188  8 31  9 52  0  0
```

3. Now constrain a workload with cgroup v2 instead, and read the cgroup's own counters — this is how container memory incidents actually look:

```bash
sudo systemd-run --unit=memlab --scope -p MemoryMax=256M -p MemorySwapMax=0 \
  stress-ng --vm 1 --vm-bytes 1G --vm-keep --timeout 30s
```

```bash
# in another terminal, while it runs
cg=/sys/fs/cgroup/system.slice/memlab.scope
grep . $cg/memory.current $cg/memory.max $cg/memory.events $cg/memory.pressure
grep -E '^(pgmajfault|pgscan|pgsteal)' $cg/memory.stat
```

```
/sys/fs/cgroup/system.slice/memlab.scope/memory.current:268435456
/sys/fs/cgroup/system.slice/memlab.scope/memory.max:268435456
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:low 0
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:high 0
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:max 184122
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:oom 3
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:oom_kill 1
/sys/fs/cgroup/system.slice/memlab.scope/memory.pressure:some avg10=94.12 avg60=41.08 avg300=8.44 total=28412991
```

4. Read the kill record:

```bash
sudo dmesg -T | grep -iE 'oom|killed process' | tail -5
journalctl -k --since '-5 min' | grep -i oom | tail -5
```

```
[Wed Oct 15 12:41:02 2026] stress-ng-vm invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0, oom_score_adj=0
[Wed Oct 15 12:41:02 2026] memory: usage 262144kB, limit 262144kB, failcnt 184122
[Wed Oct 15 12:41:02 2026] Memory cgroup out of memory: Killed process 32114 (stress-ng-vm) total-vm:1061320kB, anon-rss:252884kB, file-rss:1280kB
```

**Checkpoint — Q22–Q25**

- **Q22.** `swpd` is 1.8 GB but `si` and `so` have been `0` for an hour. Is there a memory problem? Which two counters, and which PSI line, decide the question?
- **Q23.** Distinguish a minor fault from a major fault, and say which `/proc/vmstat` counter tracks each. Which one is the one that costs milliseconds?
- **Q24.** The `dmesg` line says **"Memory cgroup out of memory"**, and `MemAvailable` on the host was 13 GB at the time. Explain how both are true, and which number you must look at to size the fix.
- **Q25.** `memory.events` shows `max 184122` and `oom_kill 1`. What is the operational difference between those two counters, and which one indicates a limit that is too low but still *working*?

---

## Lab 3 — Disk I/O: `/proc/diskstats`, Little's law, and who is writing

### 3A — Decode `/proc/diskstats` and rebuild `iostat`

1. Find your device and read its raw counters:

```bash
lsblk -d -o NAME,ROTA,SIZE,MODEL
dev=$(lsblk -dno NAME | head -1); echo "dev=$dev"
awk -v d="$dev" '$3==d' /proc/diskstats
```

```
NAME    ROTA   SIZE MODEL
nvme0n1    0 476.9G SAMSUNG MZVLB512HBJQ

 259       0 nvme0n1 2841223 118412 284122334 412884 1884112 221884 198412008 884122 0 1124882 1988004 0 0 0 0 11244 28412
```

The fields after the device name: 1 reads completed · 2 reads merged · 3 **sectors** read · 4 ms reading · 5 writes completed · 6 writes merged · 7 **sectors** written · 8 ms writing · 9 I/Os in flight · 10 ms doing I/Os · 11 weighted ms doing I/Os · (12–15 discards, 16–17 flushes on newer kernels).

2. Build your own `iostat`:

```bash
cat > ~/disk-delta.sh <<'EOF'
#!/bin/bash
# disk-delta.sh <device> [interval] -- rebuild iostat -x from /proc/diskstats.
# diskstats sectors are ALWAYS 512 B, regardless of the device's logical block size.
dev=${1:?usage: disk-delta.sh <device> [interval]}; iv=${2:-5}
snap() { awk -v d="$dev" '$3==d {print $4, $6, $7, $8, $10, $11, $13, $14}' /proc/diskstats; }
read -r r1 sr1 tr1 w1 sw1 tw1 t1 wt1 < <(snap); sleep "$iv"
read -r r2 sr2 tr2 w2 sw2 tw2 t2 wt2 < <(snap)
awk -v iv="$iv" -v r=$((r2-r1)) -v sr=$((sr2-sr1)) -v tr=$((tr2-tr1)) \
    -v w=$((w2-w1)) -v sw=$((sw2-sw1)) -v tw=$((tw2-tw1)) \
    -v t=$((t2-t1)) -v wt=$((wt2-wt1)) 'BEGIN{
  printf "r/s=%.1f  rkB/s=%.1f  r_await=%.2fms\n", r/iv, sr*512/1024/iv, (r?tr/r:0);
  printf "w/s=%.1f  wkB/s=%.1f  w_await=%.2fms\n", w/iv, sw*512/1024/iv, (w?tw/w:0);
  printf "aqu-sz=%.2f  %%util=%.1f\n", wt/(iv*1000), 100*t/(iv*1000);
  printf "little's law check: (r/s+w/s)*await/1000 = %.2f\n",
         ((r+w)/iv) * ((r+w) ? (tr+tw)/(r+w) : 0) / 1000 }'
EOF
chmod +x ~/disk-delta.sh
```

3. Apply a known, controlled load and run both tools against it:

```bash
# terminal 1 -- 4 KiB random reads, O_DIRECT, queue depth 32
fio --name=rr --filename=/var/tmp/fio.dat --size=2G --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --direct=1 --time_based --runtime=60 \
    --group_reporting
```

```bash
# terminal 2
~/disk-delta.sh "$dev" 5
iostat -xz 5 2
```

```
Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   w_await  aqu-sz  %util
nvme0n1       8123.00  32492.00     0.00   0.00    3.84     4.00    0.00      0.00      0.00   31.19   99.80
```

```
r/s=8121.4  rkB/s=32485.6  r_await=3.84ms
w/s=0.0  wkB/s=0.0  w_await=0.00ms
aqu-sz=31.19  %util=99.8
little's law check: (r/s+w/s)*await/1000 = 31.19
```

**Checkpoint — Q26–Q30**

- **Q26.** Verify Little's law on the numbers above: compute `(r/s) × r_await / 1000` and compare with `aqu-sz`. State the law in words, and say what `aqu-sz` physically is.
- **Q27.** `%util` is 99.8% on an NVMe device that is delivering 8 100 IOPS at 3.84 ms. The same device benchmarks at 400 000 IOPS. Explain precisely what `%util` measures and why it is nearly useless as a saturation signal on multi-queue devices — and which column replaces it.
- **Q28.** `rareq-sz` is exactly `4.00` KiB and `rrqm/s` is `0.00`. What do those two together tell you about the workload, and what would `rrqm/s` of 800/s have meant?
- **Q29.** Your `disk-delta.sh` multiplies sectors by 512 even on a 4 Kn drive with a 4096-byte logical block size. Why is that correct?
- **Q30.** Older `iostat` printed `svctm` and `avgqu-sz`; current sysstat prints `aqu-sz` and no `svctm`. Why was `svctm` removed, and what mistake did it encourage?

### 3B — The page cache changes the answer

1. Run the same size of work twice, with and without `O_DIRECT`, and watch where the bytes go:

```bash
fio --name=sw --filename=/var/tmp/fio2.dat --size=1G --rw=write --bs=1M \
    --ioengine=psync --direct=1 --end_fsync=1 --group_reporting | grep -E 'WRITE|IOPS'
grep -E '^(Dirty|Writeback):' /proc/meminfo

fio --name=sw --filename=/var/tmp/fio3.dat --size=1G --rw=write --bs=1M \
    --ioengine=psync --direct=0 --group_reporting | grep -E 'WRITE|IOPS'
grep -E '^(Dirty|Writeback):' /proc/meminfo
```

2. Watch the writeback thresholds do their job:

```bash
sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
( dd if=/dev/zero of=/var/tmp/big bs=1M count=4096 conv=notrunc status=none & \
  for i in $(seq 12); do grep -E '^(Dirty|Writeback|NFS_Unstable):' /proc/meminfo | tr '\n' ' '; echo; sleep 1; done )
time sync
```

```
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
Dirty: 412664 kB Writeback: 0 kB
Dirty: 1284112 kB Writeback: 118412 kB
Dirty: 1601248 kB Writeback: 412884 kB
...
real	0m6.214s
```

### 3C — Attribute I/O to a process

1. Per-process block I/O, three ways:

```bash
sudo iotop -b -o -n 3 -d 2 | head -20
pidstat -d 2 3
sudo cat /proc/$(pgrep -n fio)/io
```

```
Total DISK READ:        31.72 M/s | Total DISK WRITE:         0.00 B/s
    TID  PRIO  USER     DISK READ  DISK WRITE  COMMAND
  33114 be/4 root       31.72 M/s    0.00 B/s fio --name=rr ...
```

```
rchar: 2142338560
wchar: 0
syscr: 522543
syscw: 0
read_bytes: 2141847552
write_bytes: 0
cancelled_write_bytes: 0
```

2. Find which files are being hit:

```bash
sudo lsof -p $(pgrep -n fio)
sudo lsof /var/tmp
sudo fuser -vm /var/tmp
```

**Checkpoint — Q31–Q34**

- **Q31.** In `/proc/<pid>/io`, `rchar` is 2 142 338 560 and `read_bytes` is 2 141 847 552. Define both. Under what workload would `rchar` be enormous and `read_bytes` be zero?
- **Q32.** `cancelled_write_bytes` is non-zero for a process. What happened?
- **Q33.** `iotop` run as a normal user prints an error about missing kernel support. Which kernel config option and which privilege does it require, and which of the three tools in step 1 needs neither?
- **Q34.** A nightly job makes the whole box lag for 4 seconds every 30 seconds, and `iostat` shows `w_await` spikes of 2 000 ms with near-zero `wkB/s` in between. Which two sysctls would you examine first, and what is the mechanism?

---

## Lab 4 — Network I/O: counters, per-connection state, and the ceiling

### 4A — Interface counters, by hand and by tool

1. Read `/proc/net/dev` and build the delta tool:

```bash
IF=$(ip -o -4 route show default | awk '{print $5; exit}'); echo "IF=$IF"
sed 's/:/ /' /proc/net/dev | awk 'NR<3 || $1=="'"$IF"'"'
```

```
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
 ens18 884122334 1284112    0   12    0     0          0    88412 412884221  984112    0    0    0     0       0          0
```

```bash
cat > ~/net-delta.sh <<'EOF'
#!/bin/bash
# net-delta.sh <iface> [interval]
i=${1:?usage: net-delta.sh <iface> [interval]}; iv=${2:-5}
snap() { sed 's/:/ /' /proc/net/dev | awk -v i="$i" '$1==i {print $2, $3, $5, $10, $11, $13}'; }
read -r rb1 rp1 rd1 tb1 tp1 td1 < <(snap); sleep "$iv"
read -r rb2 rp2 rd2 tb2 tp2 td2 < <(snap)
awk -v iv="$iv" -v rb=$((rb2-rb1)) -v rp=$((rp2-rp1)) -v rd=$((rd2-rd1)) \
    -v tb=$((tb2-tb1)) -v tp=$((tp2-tp1)) -v td=$((td2-td1)) 'BEGIN{
  printf "rx %.2f Mbit/s  %.0f pps  avg %.0f B/pkt  drops %d\n", rb*8/1e6/iv, rp/iv, (rp?rb/rp:0), rd;
  printf "tx %.2f Mbit/s  %.0f pps  avg %.0f B/pkt  drops %d\n", tb*8/1e6/iv, tp/iv, (tp?tb/tp:0), td }'
EOF
chmod +x ~/net-delta.sh
```

2. Cross-check against the objective's tools and their modern replacements:

```bash
sar -n DEV 1 3 | grep -E "IFACE|$IF"
netstat -i        # legacy; note the columns
ip -s link show "$IF"
~/net-delta.sh "$IF" 5
```

```
12:51:02        IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
12:51:03        ens18   8412.00  12884.00   1021.44  11884.12      0.00      0.00      2.00      9.74
```

3. Socket-level summary and the `netstat` → `ss` translation:

```bash
ss -s
ss -tuln
ss -tanp state established | head
netstat -s | grep -iE 'segments retransmit|listen|overflow' 
nstat -az | grep -E 'TcpRetransSegs|TcpOutSegs|TcpInSegs|ListenOverflows|ListenDrops|TCPBacklogDrop'
```

```
Total: 412
TCP:   188 (estab 64, closed 98, orphaned 0, timewait 96)
```

### 4B — One connection's ceiling: `ss -ti` and the bandwidth–delay product

1. Start a server and a 10-second transfer:

```bash
# terminal 1
iperf3 -s -1
```

```bash
# terminal 2
iperf3 -c 127.0.0.1 -t 10          # loopback first, to see the no-bottleneck case
```

2. While a *real* transfer runs across a network, inspect the connection internals:

```bash
ss -tim dst 10.10.2.2
```

```
ESTAB 0 1196480 10.10.1.2:52244 10.10.2.2:5201
	 cubic wscale:7,7 rto:244 rtt:40.12/0.18 mss:1448 pmtu:1500 advmss:1448
	 cwnd:112 ssthresh:84 bytes_sent:412334592 bytes_acked:411138113
	 segs_out:284812 segs_in:12044 send 32.4Mbps pacing_rate 38.9Mbps
	 delivery_rate 31.8Mbps busy:10012ms retrans:0/18 rcv_space:14480 minrtt:40.02
```

3. Do the arithmetic that `send 32.4Mbps` is hiding:

```bash
# throughput of one TCP flow  ~=  cwnd * mss / rtt
echo "scale=2; 112 * 1448 * 8 / (40.12/1000) / 1000000" | bc
# bandwidth-delay product needed to fill a 1 Gbit/s path at this RTT
echo "scale=2; 1000000000 * (40.12/1000) / 8 / 1024 / 1024" | bc
```

```
32.34
4.78
```

4. Check the kernel's autotuning limits and the window-scaling state:

```bash
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max \
       net.ipv4.tcp_window_scaling net.ipv4.tcp_moderate_rcvbuf
```

5. Separate a per-flow limit from a path limit:

```bash
iperf3 -c 10.10.2.2 -t 10          # single stream
iperf3 -c 10.10.2.2 -t 10 -P 8     # eight streams
iperf3 -c 10.10.2.2 -t 10 -R       # reverse direction
iperf3 -c 10.10.2.2 -u -b 900M -t 10   # UDP: offered vs delivered rate, and loss
```

**Checkpoint — Q35–Q39**

- **Q35.** Compute the BDP for a 1 Gbit/s path at 40 ms RTT (step 3 did it in MiB). Then compute the maximum throughput of a TCP connection whose peer advertised a 64 KiB window **without** window scaling, at the same RTT. Which sysctl makes the difference, and which field of `ss -ti` reveals that scaling is in effect?
- **Q36.** `retrans:0/18` — explain both numbers. Then explain why `TcpRetransSegs` from `nstat` can rise while `ss` shows `retrans:0/0` for every current connection.
- **Q37.** Single stream gives 32 Mbit/s; eight parallel streams give 240 Mbit/s on the same path. What have you just proven, and what have you *not* proven? Which measurement would you add?
- **Q38.** `/proc/net/dev` reports an average of 24 000 bytes per received packet on a 1500-MTU interface with no jumbo frames configured. Which feature is responsible, and what does it do to any packets-per-second budget you compute from these counters? Which `ethtool` command confirms it?
- **Q39.** `rx drop` is incrementing but `rx errs` is zero. What is the difference between those two counters, and where would you look next (name the file and one sysctl)?

---

## Lab 5 — Firewalling and routing throughput

This lab builds a real three-node router topology inside network namespaces, so you can forward packets, count them, and saturate the forwarding path without any extra hardware.

### 5A — Build the router

1. Create the topology `cli (10.10.1.2) ── [rtr] ── srv (10.10.2.2)`:

```bash
sudo ip netns add cli; sudo ip netns add srv; sudo ip netns add rtr
sudo ip link add vc type veth peer name vc-r
sudo ip link add vs type veth peer name vs-r
sudo ip link set vc  netns cli
sudo ip link set vc-r netns rtr
sudo ip link set vs  netns srv
sudo ip link set vs-r netns rtr

sudo ip -n cli addr add 10.10.1.2/24 dev vc
sudo ip -n rtr addr add 10.10.1.1/24 dev vc-r
sudo ip -n srv addr add 10.10.2.2/24 dev vs
sudo ip -n rtr addr add 10.10.2.1/24 dev vs-r

for ns in cli srv rtr; do sudo ip -n $ns link set lo up; done
sudo ip -n cli link set vc up;   sudo ip -n srv link set vs up
sudo ip -n rtr link set vc-r up; sudo ip -n rtr link set vs-r up

sudo ip -n cli route add default via 10.10.1.1
sudo ip -n srv route add default via 10.10.2.1
sudo ip netns exec rtr sysctl -w net.ipv4.ip_forward=1
```

2. Verify forwarding before measuring it:

```bash
sudo ip netns exec cli ping -c 2 10.10.2.2
sudo ip netns exec rtr ip -s link show vc-r
sudo ip netns exec rtr sysctl net.ipv4.ip_forward
```

3. Make packet counts meaningful by turning off the offloads that `veth` enables by default:

```bash
for d in vc-r vs-r; do sudo ip netns exec rtr ethtool -K $d tso off gso off gro off 2>/dev/null; done
sudo ip netns exec cli ethtool -K vc tso off gso off gro off 2>/dev/null
sudo ip netns exec srv ethtool -K vs tso off gso off gro off 2>/dev/null
```

4. Baseline the forwarding throughput and the CPU cost of forwarding it:

```bash
# terminal 1
sudo ip netns exec srv iperf3 -s -1
```

```bash
# terminal 2
sudo ip netns exec cli iperf3 -c 10.10.2.2 -t 10
```

```bash
# terminal 3 -- where does the time go?
mpstat -P ALL 1 10 | awk 'NR<4 || $3=="all"'
sudo ip netns exec rtr nstat -az | grep -E 'IpForwDatagrams|IpInReceives|IpOutRequests'
```

5. Introduce a known bottleneck and a known RTT, then confirm the queue that forms:

```bash
sudo ip netns exec rtr tc qdisc add dev vs-r root netem rate 100mbit delay 20ms limit 10000
sudo ip netns exec rtr tc qdisc add dev vc-r root netem rate 100mbit delay 20ms limit 10000
sudo ip netns exec cli ping -c 3 10.10.2.2 | tail -2
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -t 10
sudo ip netns exec rtr tc -s qdisc show dev vs-r
```

```
rtt min/avg/max/mdev = 40.112/40.284/40.512/0.171 ms
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.00  sec   113 MBytes  94.8 Mbits/sec   12   sender

qdisc netem 8001: root refcnt 2 limit 10000 delay 20ms rate 100Mbit
 Sent 118412334 bytes 81792 pkt (dropped 12, overlimits 0 requeues 0)
 backlog 262144b 181p requeues 0
```

**Checkpoint — Q40–Q42**

- **Q40.** `netem delay 20ms` was applied to **both** router interfaces, and `ping` reports an RTT of 40 ms. Derive that: how many times does one ICMP echo request/reply pair traverse a `netem` egress qdisc, and what RTT would a single-sided 20 ms delay have produced?
- **Q41.** The `netem` qdisc shows `backlog 181p` and `dropped 12`. Combine that with the `Retr 12` from `iperf3` and explain the complete causal chain, naming the resource that is saturated.
- **Q42.** Forwarding at 94.8 Mbit/s, `mpstat` shows `%soft` of 8% and `%sys` of 3%. Which kernel context does forwarding run in, which process would you see in `top` if it ran out of budget, and why does the forwarded traffic not appear as any user process's CPU time?

### 5B — The cost of a firewall ruleset

1. Measure the forwarding rate of the empty ruleset in packets per second, using small packets so the CPU, not the bandwidth, is the limit:

```bash
sudo ip netns exec rtr tc qdisc del dev vs-r root 2>/dev/null
sudo ip netns exec rtr tc qdisc del dev vc-r root 2>/dev/null
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -u -b 0 -l 64 -t 10 | tail -4
sudo ip netns exec rtr nstat -az | grep IpForwDatagrams
```

2. Install a deliberately pathological **linear** ruleset and repeat:

```bash
sudo ip netns exec rtr nft -f - <<'EOF'
table inet linear {
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
}
EOF
for i in $(seq 1 2000); do
  o=$(( i / 256 )); h=$(( i % 256 ))
  echo "add rule inet linear forward ip saddr 198.51.$o.$h drop"
done | sudo ip netns exec rtr nft -f -
sudo ip netns exec rtr nft list ruleset | grep -c 'ip saddr'
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -u -b 0 -l 64 -t 10 | tail -4
mpstat -P ALL 1 5 | awk '$3=="all"'
```

3. Replace the 2 000 rules with **one** rule plus a set holding the same 2 000 addresses, and measure again:

```bash
sudo ip netns exec rtr nft flush table inet linear
sudo ip netns exec rtr nft -f - <<'EOF'
table inet linear {
    set blocked {
        type ipv4_addr
        flags interval
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        ip saddr @blocked drop
    }
}
EOF
for i in $(seq 1 2000); do o=$(( i / 256 )); h=$(( i % 256 )); echo -n "198.51.$o.$h, "; done \
  | sed 's/, $//' > /tmp/blocked.txt
sudo ip netns exec rtr nft add element inet linear blocked "{ $(cat /tmp/blocked.txt) }"
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -u -b 0 -l 64 -t 10 | tail -4
```

4. If `perf` is available, see where the cycles actually go:

```bash
sudo perf top -e cycles --sort symbol -d 5 2>/dev/null | head -12   # look for nft_do_chain
```

**Checkpoint — Q43–Q44**

- **Q43.** Forwarding pps with 0 rules, with 2 000 linear rules, and with 1 rule + a 2 000-element set. Describe the expected ordering and give the asymptotic cost of each (per packet). Which data structure backs an `nftables` set, and what does `flags interval` change about it?
- **Q44.** Which single `mpstat` column is the measurement that proves the firewall, and not the link, is the bottleneck? And why is UDP with `-l 64` the right test instead of TCP with the default payload?

### 5C — Connection tracking: the resource nobody sizes

1. Look at the current state of the table:

```bash
sudo modprobe nf_conntrack 2>/dev/null
sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max \
       net.netfilter.nf_conntrack_buckets net.netfilter.nf_conntrack_tcp_timeout_established
sudo conntrack -S | head -4
sudo conntrack -C
```

```
net.netfilter.nf_conntrack_count = 1842
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 432000
cpu=0 found=0 invalid=1244 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=118
```

2. Make the table small, force it full from the lab namespaces, and observe the failure mode. The limit applies to the whole VM while it is set: new connections in the VM's own namespace are dropped too once it holds more than 32 entries, so keep your current SSH session open and do not open a new one until step 3:

```bash
# nf_conntrack_max is global: the kernel makes it read-only in every namespace
# but the initial one (net/netfilter/nf_conntrack_standalone.c), so it is set on
# the lab VM itself. Each namespace counts its own entries against it: 32 is
# below the 64 streams iperf3 opens through rtr, so the table fills.
orig_max=$(sysctl -n net.netfilter.nf_conntrack_max)
sudo sysctl -w net.netfilter.nf_conntrack_max=32
sudo ip netns exec rtr nft -f - <<'EOF'
table inet ct {
    chain forward {
        type filter hook forward priority filter; policy accept;
        ct state new counter
    }
}
EOF
sudo ip netns exec srv iperf3 -s &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -P 64 -t 10 2>&1 | tail -5
sudo ip netns exec rtr sh -c 'cat /proc/sys/net/netfilter/nf_conntrack_count; conntrack -S | awk -F: "/drop|insert_failed/" ' 2>/dev/null
sudo dmesg -T | grep -i conntrack | tail -3
```

```
nf_conntrack: nf_conntrack: table full, dropping packet
```

3. Restore a sane limit and note the memory cost of the alternative:

```bash
sudo sysctl -w net.netfilter.nf_conntrack_max="$orig_max"
```

**Checkpoint — Q45–Q46**

- **Q45.** A router drops a *small fraction* of new connections at peak while existing connections are fine, CPU is at 30%, and the links are at 40%. Which single pair of numbers do you read first, and what is the arithmetic that tells you whether `nf_conntrack_established` timeout or `nf_conntrack_max` is the thing to change?
- **Q46.** `conntrack -S` shows rising `insert_failed` but `drop` stays at 0. What is the difference, and which traffic pattern produces `insert_failed` without the table being full?

### 5D — Softirq budget and receive drops

1. Decode `/proc/net/softnet_stat`, which is in hex and has no header:

```bash
awk '{ printf "cpu%-3d processed=%-10d dropped=%-8d time_squeeze=%-8d backlog_len=%s\n",
       NR-1, strtonum("0x"$1), strtonum("0x"$2), strtonum("0x"$3), ($0 ~ /./ ? strtonum("0x"$12) : 0) }' \
    /proc/net/softnet_stat
sysctl net.core.netdev_budget net.core.netdev_budget_usecs net.core.netdev_max_backlog
grep -E 'NET_RX|NET_TX' /proc/softirqs | cut -c1-100
```

```
cpu0   processed=128412     dropped=0        time_squeeze=412      backlog_len=0
cpu1   processed=98412      dropped=0        time_squeeze=18       backlog_len=0
net.core.netdev_budget = 300
net.core.netdev_budget_usecs = 2000
net.core.netdev_max_backlog = 1000
```

2. Correlate with per-CPU softirq time while the pps test from 5B runs:

```bash
mpstat -P ALL 1 5 | awk 'NR<4 || $4!="%usr"' | grep -vE '^$'
pidof ksoftirqd/0 >/dev/null && top -b -n 1 -o %CPU | grep ksoftirqd | head -4
```

**Checkpoint — Q47**

- **Q47.** `dropped` is 0 but `time_squeeze` is 412 and climbing on cpu0 only, while `%soft` on cpu0 is 70% and ~1% elsewhere. Interpret each of the three signals, say what `time_squeeze` literally counts, and name the two mechanisms that would spread the work across CPUs.

---

## Lab 6 — Map client bandwidth usage

The objective says "map client bandwidth usage" — which client, not just how much. Four tools answer four different questions; this lab makes the difference concrete.

1. Install per-client named counters on the router, in both directions:

```bash
sudo ip netns exec rtr nft -f - <<'EOF'
table inet acct {
    chain acct_fwd {
        type filter hook forward priority filter; policy accept;
    }
}
EOF

for ip in 10.10.1.2 10.10.2.2; do
  k="${ip//./_}"
  sudo ip netns exec rtr nft add counter inet acct "out_$k"
  sudo ip netns exec rtr nft add counter inet acct "in_$k"
  sudo ip netns exec rtr nft add rule inet acct acct_fwd ip saddr "$ip" counter name "out_$k"
  sudo ip netns exec rtr nft add rule inet acct acct_fwd ip daddr "$ip" counter name "in_$k"
done

sudo ip netns exec rtr nft list counters table inet acct
```

```
table inet acct {
	counter out_10_10_1_2 {
		packets 81792 bytes 118412334
	}
	counter in_10_10_1_2 {
		packets 12044 bytes 884122
	}
	...
}
```

2. Turn the counters into a bandwidth report:

```bash
cat > ~/client-bw.sh <<'EOF'
#!/bin/bash
# client-bw.sh [interval] -- per-client bandwidth from nft named counters.
iv=${1:-5}
snap() { ip netns exec rtr nft -j list counters table inet acct |
         jq -r '.nftables[] | select(.counter) | "\(.counter.name) \(.counter.bytes)"'; }
a=$(snap); sleep "$iv"; b=$(snap)
join <(sort <<<"$a") <(sort <<<"$b") |
awk -v iv="$iv" '{ printf "%-18s %10.2f Mbit/s\n", $1, ($3-$2)*8/1e6/iv }' | sort -k2 -nr
EOF
chmod +x ~/client-bw.sh
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -t 20 >/dev/null &
sudo ~/client-bw.sh 5
```

```
out_10_10_1_2          943.12 Mbit/s
in_10_10_2_2           943.12 Mbit/s
in_10_10_1_2             1.88 Mbit/s
out_10_10_2_2            1.88 Mbit/s
```

3. Compare with the atomic read-and-zero variant, which needs a single sample per interval:

```bash
sudo ip netns exec rtr nft reset counters table inet acct >/dev/null
sleep 5
sudo ip netns exec rtr nft reset counters table inet acct | grep -A2 counter | head -12
```

4. Now the other three tools, each answering a different question:

```bash
# which peers, live, on one interface (press q to quit)
sudo iftop -n -N -i "$IF"

# which LOCAL PROCESS -- the only tool here that maps bytes to a PID
sudo nethogs "$IF"

# per-interface / per-protocol / per-port breakdown, with a logfile
sudo iptraf-ng -i "$IF"

# which interface, historically, with no live terminal
sar -n DEV -f /var/log/sysstat/sa$(date +%d) | grep -E "IFACE|$IF" | head
```

**Checkpoint — Q48–Q51**

- **Q48.** The report shows `out_10_10_1_2` and `in_10_10_2_2` with identical byte counts. Is that double counting? Explain in terms of how many rules each forwarded packet matches, and how you would restructure the ruleset to bill each packet once per client.
- **Q49.** `nft reset counters` versus two samples five seconds apart: which is correct under two concurrent pollers, and what exactly goes wrong with the other one?
- **Q50.** Your router performs SNAT in `postrouting` and DNAT in `prerouting`. For a packet from a LAN client to the Internet, which address does a counter in the **forward** hook see as `saddr`, and which as `daddr`? Derive it from the hook traversal order, and state the consequence for per-client accounting.
- **Q51.** Match each question to exactly one tool, and say why the others cannot answer it: (a) "which of our 40 customers used the most traffic last night at 03:00?"; (b) "which process on this host is uploading 200 Mbit/s right now?"; (c) "which remote IP is my gateway talking to most, this second?"; (d) "which TCP port is carrying the volume?"

---

## Lab 7 — Historical data: `sar` is the only tool that works after the fact

Every tool so far needs you to be logged in *while* the problem happens. `sysstat` removes that constraint — and the exam expects you to know how it is enabled, where it writes, and what granularity it loses.

1. Enable collection and inspect the mechanism:

```bash
# Debian/Ubuntu
sudo sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat 2>/dev/null
cat /etc/default/sysstat 2>/dev/null
# RHEL-family
cat /etc/sysconfig/sysstat 2>/dev/null
```

```ini
# /etc/default/sysstat
ENABLED="true"
```

```ini
# /etc/sysconfig/sysstat
HISTORY=28
COMPRESSAFTER=31
SADC_OPTIONS="-S DISK"
```

2. Find out *how* the samples are taken on your distribution — cron or systemd timers, both calling the same two helpers:

```bash
systemctl status sysstat sysstat-collect.timer sysstat-summary.timer --no-pager 2>/dev/null | head -20
systemctl list-timers 'sysstat*' --no-pager 2>/dev/null
ls -l /etc/cron.d/sysstat /usr/lib/sysstat/sa1 /usr/lib/sysstat/sa2 2>/dev/null
cat /etc/cron.d/sysstat 2>/dev/null
```

3. Force a sample now and confirm the data files:

```bash
sudo /usr/lib/sysstat/sa1 1 1 || sudo /usr/lib64/sa/sa1 1 1
ls -l /var/log/sysstat/ 2>/dev/null || ls -l /var/log/sa/
```

4. Read history, which is the actual skill:

```bash
f=$(ls -t /var/log/sysstat/sa[0-9]* /var/log/sa/sa[0-9]* 2>/dev/null | head -1); echo "$f"
sar -u -f "$f" | head
sar -q -f "$f" | head -5                   # load average + run queue
sar -r -f "$f" | head -5                   # memory
sar -W -f "$f" | head -5                   # swapping
sar -b -f "$f" | head -5                   # aggregate I/O
sar -d -p -f "$f" | head -8                # per-device, pretty names
sar -n DEV -f "$f" | head -5
sar -u -s 09:00:00 -e 10:30:00 -f "$f"     # bound the window to the incident
```

```
12:00:01        CPU     %user     %nice   %system   %iowait    %steal     %idle
12:10:01        all      4.12      0.00      1.84     21.44      0.00     72.60
12:20:01        all      3.98      0.00      1.72     24.18      0.00     70.12
Average:        all      4.05      0.00      1.78     22.81      0.00     71.36
```

5. Export for a spreadsheet or a time-series database:

```bash
sadf -d -- -u "$f" | head -4          # semicolon-delimited, one row per sample
sadf -j -- -u -n DEV "$f" | head -20  # JSON, for ingestion
```

6. Correlate two subsystems across the same timestamps — the actual diagnostic move:

```bash
join -j 1 \
  <(sar -u -f "$f" | awk '$2=="all"{print $1, $5}') \
  <(sar -d -p -f "$f" | awk '$2=="nvme0n1"{print $1, $8}') \
  | awk 'BEGIN{print "time %iowait await"} {print}' | head -10
```

**Checkpoint — Q52–Q54**

- **Q52.** Collection runs every 10 minutes by default. A 45-second stall at 03:14 made the service page. What will `sar` show for the 03:10 interval, and what is the one configuration change that makes such events visible — with what cost?
- **Q53.** `sar -u` and `sar -d` both have a `%util`-like notion of busy. Given `%iowait 22.8` and `await 94 ms` on the same timestamps, which is the cause and which is the symptom? And what third `sar` flag would confirm there is no memory component?
- **Q54.** You need yesterday's data but `/var/log/sysstat` only has `sa15`. Explain the naming scheme, the role of `sa1` versus `sa2`, what `HISTORY` controls, and which file you would read for a date 20 days ago.

---

## Lab 8 — Capstone: triage from symptoms alone

### 8A — Match symptoms to causes

For each symptom set, name the saturated resource, the **one** command that confirms it, and the next action.

| # | Symptom set |
|---|---|
| A | `load average: 24.0`, `vmstat`: `r 1 b 23 us 2 sy 3 wa 71`, `free`: 11 GB available |
| B | `load average: 8.1` on 8 CPUs, `vmstat`: `r 9 b 0 us 92 sy 4 wa 0`, PSI `cpu some avg10=61` |
| C | `vmstat`: `si 42000 so 61000 wa 48`, `free`: available 180 MB, `swpd` growing, `dmesg` quiet |
| D | API p99 jumped from 20 ms to 900 ms; CPU 20%, disk `await` 1 ms, `nstat` `TcpRetransSegs` up 400×, `ss -ti` shows `cwnd:2 ssthresh:2` |
| E | Nightly backup halves in speed; `iostat`: `%util 100`, `aqu-sz 1.1`, `r_await 11 ms`, `rkB/s 92000`, device is a 7 200-rpm SATA disk |
| F | New connections time out at peak; established ones fine; CPU 30%, link 40%, `dmesg`: `table full, dropping packet` |
| G | `top` shows 100% on one core only; the application is single-threaded; `%soft` is 0 |
| H | `free` shows 240 MB free of 16 GB, `cache` 13 GB, `si/so` are 0, PSI memory `some` is 0.00 |

**Checkpoint — Q55.** Produce the table: for each of A–H give resource, confirming command, and action.

### 8B — Estimate the ceiling before you blame anything

Work these with `bc`; the arithmetic is the exam-relevant skill.

1. A backup must move **500 GB** inside a **6-hour** window.

```bash
echo "scale=2; 500*8*1000 / (6*3600)" | bc        # Mbit/s required
echo "scale=2; 500*1000 / (6*3600)" | bc          # MB/s required
```

2. The source is a 7 200-rpm SATA disk. Assume ~80 random IOPS and ~160 MB/s sequential.

```bash
echo "scale=2; 80 * 4 / 1024" | bc                # MB/s if the workload is 4 KiB random
```

3. The link is 1 Gbit/s with 40 ms RTT; packet loss is 0.01%. Apply the Mathis bound for a single Reno-like flow, with MSS = 1448 B:

```bash
echo "scale=2; 1.22 * 1448 * 8 / ( (40/1000) * sqrt(0.0001) ) / 1000000" | bc -l
```

**Checkpoint — Q56–Q58**

- **Q56.** State the required throughput in Mbit/s and MB/s, and whether a 1 Gbit/s link can carry it.
- **Q57.** Compare the required MB/s against the disk's random and sequential numbers. Under which access pattern does the job fit, and what does that imply for how you configure the backup tool?
- **Q58.** Compute the Mathis bound at 0.01% loss. One TCP stream cannot fill the link — give two distinct remedies (one on the hosts, one on the job) and say which `ss -ti` field you would watch to confirm the fix.

---

## Appendix A — Tool → metric map (memorize the columns, not the tools)

| Resource | Raw kernel source | Interval tool | Per-process | Saturation signal |
|---|---|---|---|---|
| CPU | `/proc/stat`, `/proc/loadavg` | `mpstat -P ALL 1`, `vmstat 1` | `pidstat -u -t`, `top -H`, `ps -eo pcpu` | `r` in `vmstat`, `/proc/pressure/cpu` |
| Memory | `/proc/meminfo`, `/proc/vmstat` | `vmstat 1`, `sar -r -W` | `pmap -X`, `smaps_rollup` (PSS) | `si`/`so`, `pgmajfault`, `/proc/pressure/memory` |
| Disk | `/proc/diskstats` | `iostat -xz 1`, `sar -d -p` | `iotop -o`, `pidstat -d`, `/proc/<pid>/io` | `aqu-sz`, `await`, `/proc/pressure/io` |
| Network | `/proc/net/dev`, `/proc/net/snmp` | `sar -n DEV`, `nstat`, `ip -s link` | `nethogs`, `ss -tanp` | `tc -s qdisc` backlog/drops, `TcpRetransSegs`, `rx drop` |
| Firewall / routing | `nft list counters`, `nf_conntrack_count` | `nstat IpForwDatagrams`, `conntrack -S` | per-client `nft` counters | `%soft`, `time_squeeze`, `insert_failed` |
| Connections | `/proc/net/tcp` | `ss -s`, `ss -ti` | `ss -tanp`, `lsof -i` | `ListenOverflows`, `cwnd`/`retrans` |

## Appendix B — Formulas worth knowing cold

- **CPU %busy** = `1 − Δ(idle + iowait) / Δ(user+nice+system+idle+iowait+irq+softirq+steal)`
- **Little's law** → `aqu-sz = IOPS × await(s)`; concurrency = throughput × latency
- **Device throughput** from diskstats = `Δsectors × 512 / Δt` (sectors are always 512 B)
- **BDP** = `bandwidth × RTT` → the window a single flow needs to fill a path
- **Single-flow TCP rate** ≈ `cwnd × MSS / RTT`
- **Mathis bound** ≈ `(MSS / RTT) × (1.22 / √loss)`
- **No-window-scaling ceiling** = `65535 B / RTT`

---

## Cleanup

```bash
# load generators
pkill -f stress-ng; pkill -f fio; pkill -f iperf3
# lab files
rm -f /var/tmp/fio.dat /var/tmp/fio2.dat /var/tmp/fio3.dat /var/tmp/big /var/tmp/cachefill /tmp/blocked.txt
# firewall tables (inside the namespace, and any created on the host)
sudo ip netns exec rtr nft delete table inet acct 2>/dev/null
sudo ip netns exec rtr nft delete table inet linear 2>/dev/null
sudo ip netns exec rtr nft delete table inet ct 2>/dev/null
# namespaces (deleting them removes the veth pairs and qdiscs)
for ns in cli srv rtr; do sudo ip netns del $ns 2>/dev/null; done
ip netns list
# sysctls touched on the host (none persisted; verify)
sysctl net.ipv4.ip_forward net.netfilter.nf_conntrack_max 2>/dev/null
```

---

<details>
<summary><strong>Answers — Q1 to Q58 (open only after attempting the checkpoints)</strong></summary>

### Lab 0

**Q1.** Fields four and five are `runnable/total` kernel scheduling entities (`2/412` = 2 currently runnable, 412 existing) and the PID of the most recently created process (`31844`). The first three are 1-, 5- and 15-minute exponentially damped moving averages of the number of tasks in state **R (runnable) *plus* D (uninterruptible sleep)**. The inclusion of D state is the Linux-specific part: classic UNIX load average counts only runnable tasks, so on Linux a load average of 24 can occur with a completely idle CPU if 24 tasks are blocked on disk or NFS. Load average is therefore a *demand* indicator across CPU **and** I/O, never a CPU utilization figure — which is why you must normalize nothing by `nproc` until you have checked `vmstat`'s `r` and `b` columns.

**Q2.** `JCPU` is the CPU time used by all processes attached to that tty, including finished ones; `PCPU` is the CPU time of the process currently shown in `WHAT`. `IDLE` is only *terminal* idle time — keyboard inactivity. A detached background job, a `nohup`'d loop, or a long-running `./report.sh` keeps burning resources while `IDLE` climbs. `w` tells you about sessions, not about load; use it to find a human to ask, not to find a culprit.

**Q3.** Nearly every tool in this topic reads cumulative counters from `/proc`. With one sample the tool can only divide the counter by the uptime, so the **first line of `vmstat`, `iostat`, `sar`, `mpstat` and `pidstat` is an average since boot** and will cheerfully report 2% utilization on a box that has been pinned for ten minutes. Asking for two samples makes the second line a true interval measurement. The corollary for scripts: always discard the first sample.

### Lab 1

**Q4.** `100 / 8 = 12.5`, which is exactly the `%usr 12.52` on the `all` line. The aggregate line averages over all CPUs, so a fully saturated single thread is indistinguishable from mild, evenly spread load. On a 64-core host a pinned core reads as 1.6%. Always run `mpstat -P ALL`, and remember the same trap applies to `top`'s summary line until you press `1`.

**Q5.** `4812344` ticks ÷ 100 ticks/s = `48123.44` CPU-seconds = **13.37 CPU-hours** spent in user mode since boot, summed across all CPUs. The divisor came from `getconf CLK_TCK`, which reports the USER_HZ that the `/proc` interface is denominated in (conventionally 100, regardless of the kernel's internal `CONFIG_HZ`).

**Q6.** The kernel accounts guest time *inside* `user`, and `guest_nice` inside `nice`. Adding fields 10 and 11 to the total counts that time twice, inflating the denominator and therefore **understating** the busy percentage. On a KVM host where most work is guest execution the error is large — a fully loaded hypervisor could read as ~50% busy. `top` and `mpstat` handle this by subtracting guest from user before displaying `%usr` alongside `%guest`.

**Q7.** On any I/O-bound workload. `100 − %idle` includes `%iowait`, which is time the CPU was **idle with at least one task blocked on I/O** — the CPU was available the whole time. The `dd iflag=direct` run shows `wa 25` with `us 1 sy 3`: `100 − %idle` would claim 29% CPU demand when the real figure is 4%.

**Q8.** No, the CPU is not the bottleneck: `r 0` means nothing is waiting for a CPU and `us+sy` is 4%. The bottleneck is **disk I/O**: `b 1` is a task in uninterruptible sleep and `wa 25` is one of eight CPUs idling while that task waits. The strongest hint about *which* device is the `bi`/`bo` pair (blocks in/out per second, in KiB/s in procps-ng) — a large `bi` with zero `bo` points you at a read-heavy device, which you then identify with `iostat -xz 1`.

**Q9.** Both R and D tasks count toward the load average. Under `stress-ng --cpu 4`, four tasks are permanently runnable → load converges on 4. Under `dd iflag=direct`, the `dd` task spends its life in **D state** waiting for block-layer completions, and D counts identically. So the load average rises in both cases while meaning two completely different things. This is why "load average above core count" is not an alert worth having on its own.

**Q10.** `blk_mq_get_tag` is in the **block multi-queue layer**: the task is waiting for a free *tag*, i.e. a slot in the device's hardware queue. That means the device's queue depth is fully occupied — the request could not even be submitted yet. It is a saturation signal one level deeper than `await`: not "the device is slow to answer" but "there is nowhere to put the next request". Compare with `nr_requests` in `/sys/block/<dev>/queue/`.

**Q11.** `%steal` is time your vCPU was runnable but the hypervisor scheduled someone else. As a guest you can: (1) move the instance to a different host or a dedicated/non-burstable instance type; (2) reduce your own vCPU count so the scheduler has an easier time placing you, or pin latency-sensitive work; (3) escalate to the provider with the measurement. What you **cannot** do is fix it with any guest-side tuning — no sysctl, scheduler policy or nice value reclaims stolen time, because the cycles were never yours. (On a *burstable* instance, also check for CPU-credit exhaustion, which presents the same way.)

**Q12.** `some` is the fraction of wall time in which **at least one** non-idle task was stalled on the resource; `full` is the fraction in which **every** non-idle task was stalled, i.e. zero productive work was possible. System-wide, `cpu full` is always zero: a task stalled waiting for CPU implies some *other* task is running on that CPU, so the system as a whole is never fully stalled on CPU. The kernel has printed the line since 5.13 and sets it to zero for backward compatibility (Documentation/accounting/psi.rst). In a cgroup's `cpu.pressure` it is real: every non-idle task of the group can be waiting at once, for example when `cpu.max` throttles the group.

**Q13.** The one with `cpu some avg10=2%` is healthy: 100% utilization with no queueing is a *well-used* machine, which is what you want from a batch node. The one at 85% is in trouble. The distinguishing word is **saturation** — work queued beyond the resource's ability to serve it. Utilization has a ceiling of 100% and stops conveying information there; saturation (PSI, run queue, `aqu-sz`) keeps rising and is what correlates with latency.

### Lab 2

**Q14.** `total = used + free + buffers + cache`, with `used` *defined* as the residual: `used = MemTotal − MemFree − Buffers − (Cached + SReclaimable)`. Besides `Cached`, `free` folds in **`SReclaimable`** — the reclaimable part of the slab allocator (dentry and inode caches). It belongs with the cache because the kernel can shrink it under pressure, so counting it as `used` would make a normal system look memory-starved. Note `Cached` in `/proc/meminfo` already includes `Shmem`, which is why `free` reports `shared` separately.

**Q15.** (1) **`Shmem` / tmpfs pages** (412 MB here) sit in `Cached` but cannot be dropped — they have no backing store other than swap, and `/dev/shm` content is live data. (2) The **low watermarks** the kernel keeps per zone, plus the portion of the file LRU the kernel assumes is in active use: `MemAvailable` deliberately refuses to promise the last slice of the page cache because reclaiming all of it would thrash. (Also valid: dirty pages, which must be written before reclaim, and `mlock`ed pages.) `MemAvailable` is a conservative *estimate of allocatable memory without swapping*, and it is the number to alert on — `MemFree` is noise.

**Q16.** `MemAvailable` barely moves. The kernel's estimate (`si_mem_available()` in `mm/show_mem.c`) is free memory minus reserves plus the file LRU lists and part of the reclaimable slab, less the low watermarks; it never reads `Dirty` or `Writeback`, and dirty pages stay on the file LRU, so they are counted as available (Documentation/filesystems/proc.rst: "Calculated from MemFree, SReclaimable, the size of the file LRU lists, and the low watermarks"). That is exactly why it over-promises when `Dirty` is large: reclaiming those pages costs a writeback first. The latency symptom is **stalls on allocation and on `sync`/`fsync`** — a 6 GB dirty set means any process that triggers writeback throttling, or any `fsync`, waits for gigabytes to reach the disk. That is the classic "the machine froze for eight seconds" report, and it is tuned with `vm.dirty_background_bytes` / `vm.dirty_bytes` (prefer the `_bytes` forms over the `_ratio` forms on large-memory hosts).

**Q17.** `vm.overcommit_memory` and `vm.overcommit_ratio` (the limit shown applies when `overcommit_memory=2`, strict mode: `CommitLimit = swap + MemTotal × overcommit_ratio/100`). `Committed_AS` is the total address space the kernel has *promised* to all processes — the sum of what they could touch, not what they have touched. It is routinely several times RSS and is **not** memory in use; it only matters because in strict mode an allocation that would push `Committed_AS` past `CommitLimit` fails with `ENOMEM` at `malloc`/`mmap` time instead of later via the OOM killer.

**Q18.** Shared pages — above all the shared text (code) of libc and of every other shared library, plus `fork`ed copy-on-write pages and shared memory segments — are counted in **full** in the RSS of every process that maps them. Summing RSS therefore counts one physical page N times. The field that fixes it is **`Pss`** (Proportional Set Size) in `smaps_rollup`: each shared page is divided by the number of mappers, so PSS *is* additive across processes and sums to roughly the real anonymous+mapped footprint.

**Q19.** `VSZ` is total virtual address space mapped, including never-touched reservations, file mappings and guard pages — it is almost never an interesting number. `RSS` is resident physical pages attributed to this process, shared pages included in full. `Pss` is RSS with shared pages divided among mappers. For 500 forked workers you alert on **PSS** (or better, on the cgroup's `memory.current` for the whole service): the sum of RSS would report several times the machine's physical memory and generate a false page on every deploy.

**Q20.** `drop_caches` with `1` frees the clean page cache, but `free`'s `cache` column also includes `SReclaimable`, which `echo 1` does not touch — and any **dirty** pages cannot be dropped until written back, which is why `sync` precedes it. `echo 3` drops the page cache **and** the reclaimable slab (dentries and inodes). Both are debugging aids only: in production the single consequence is that every subsequent read goes to disk, as step 3 measured (8.4 s versus 0.37 s).

**Q21.** `df` reported the space as **used** (the blocks are still allocated to the inode); `du` reported it as absent, because the directory entry is gone and `du` walks the namespace. The file persists until the last file descriptor closes. The fix without rebooting: identify the holder with `lsof +L1` or `lsof -nP | grep deleted`, then either restart/signal that process (often a log writer after a `rm` instead of a logrotate `copytruncate`), or truncate the file through its procfs descriptor — `: > /proc/<pid>/fd/<n>` — which releases the blocks immediately with the process still running.

**Q22.** There is no memory problem demonstrated. `swpd` is a *stock*: pages that were swapped out at some point, possibly days ago during one batch job, and were never needed again. The *flows* decide the question: `si` and `so` in `vmstat` (from `pswpin`/`pswpout` in `/proc/vmstat`), plus **`/proc/pressure/memory`** — specifically `some`/`full` above a few percent. Sustained non-zero `si` **and** `so` together is thrashing; `so` alone is just the kernel making room; both zero with a large `swpd` is a healthy system that once was busy.

**Q23.** A **minor** fault is resolved without disk I/O: the page is already in memory (page cache hit, copy-on-write, zero-fill of a fresh anonymous page) and only the page table needs updating — sub-microsecond. A **major** fault requires reading from a backing store (file or swap) — hundreds of microseconds on NVMe, milliseconds on rust. `/proc/vmstat` tracks them as `pgfault` (all faults) and **`pgmajfault`** (the expensive ones); per process, `ps -o min_flt,maj_flt`. `pgmajfault` is the counter that turns into user-visible latency.

**Q24.** The cgroup hit **its own** `memory.max` of 256 MB while the host had 13 GB available, so the kernel ran the OOM killer *scoped to that cgroup*. Nothing was wrong with the host; the limit was wrong, or the workload was. The number to size the fix is the cgroup's own: `memory.peak` if available, otherwise the high-water mark of `memory.current` plus the `memory.stat` breakdown (anon versus file) — host `MemAvailable` is irrelevant to a cgroup OOM, which is the single most common misdiagnosis in container operations.

**Q25.** `max` counts how many times an allocation was **refused and reclaim was forced** because the cgroup was at its limit — the limit working as designed, at a cost in latency and in reclaim CPU. `oom_kill` counts processes actually killed. A high `max` with `oom_kill 0` is the signature of a limit that is **too low but still functioning**: the workload fits only because the kernel is continuously evicting its page cache, so throughput suffers (visible as `pgscan`/`pgsteal` in `memory.stat` and as `memory.pressure` well above zero) while nothing crashes. That is exactly the state to catch before it becomes an `oom_kill`.

### Lab 3

**Q26.** `8123 × 3.84 / 1000 = 31.19`, equal to the reported `aqu-sz`. Little's law: **the average number of requests in the system equals the arrival rate times the average time each request spends in the system.** `aqu-sz` is therefore the average number of I/O requests in flight *plus* queued — the device's concurrency. Because it has no upper bound, it is the honest saturation metric, and the identity gives you a free consistency check on any I/O data you are handed.

**Q27.** `%util` is computed from field 10 of `/proc/diskstats` — milliseconds during which the queue was non-empty — divided by the interval. It answers "what fraction of the time was at least one request outstanding?" For a single-queue rotational disk that was a fair proxy for saturation, because one request at a time *was* the device's capacity. An NVMe device serves dozens to thousands of requests concurrently, so one lazy request stream keeps `%util` at 100% while using a fraction of the hardware. The replacement is **`aqu-sz`** (concurrency achieved) compared against the device's useful queue depth, plus `await` against its service-time floor.

**Q28.** `rareq-sz 4.00` KiB with `rrqm/s 0.00` says every request reached the device at exactly the size the application asked for, with **no merging**: the offsets were not adjacent, i.e. the workload is genuinely random — which matches `--rw=randread --bs=4k`. An `rrqm/s` of 800/s would have meant the block layer was coalescing adjacent requests into larger ones, the signature of a *sequential* access pattern (or of a readahead working), and it would have raised `rareq-sz` well above the application's block size.

**Q29.** Because `/proc/diskstats` and the kernel's generic block layer express request sizes in **512-byte sectors by definition**, as a fixed unit of the interface — not in the device's logical or physical block size. A 4 Kn drive reports an 8-sector request for one 4 KiB block. `iostat` does the same multiplication. (The device's own geometry is in `/sys/block/<dev>/queue/logical_block_size` and `physical_block_size`, which matter for alignment, not for this arithmetic.)

**Q30.** `svctm` purported to be the device's *service time* excluding queueing, but it was derived by a model that silently assumed one request in flight at a time. On any concurrent device the number is meaningless, and sysstat 12 removed it rather than keep publishing it. The mistake it encouraged: concluding "the device is fast, `svctm` is 0.2 ms" while applications waited 90 ms, because the queueing delay — which is where the time actually went — was invisible. Use `await` (total, including queue time) and `aqu-sz` to see how much of `await` is queueing: `queue time ≈ await × (1 − 1/aqu-sz)` for a saturated single server, or simply compare `await` against `minrtt`-like best-case service time from a low-depth run.

**Q31.** `rchar` counts bytes transferred by **read-family syscalls**, satisfied from anywhere — page cache included. `read_bytes` counts bytes actually **fetched from the block layer**. `rchar` huge with `read_bytes` zero is the signature of a workload whose data is entirely in the page cache (a warm database, repeated reads of the same files, or reads from `tmpfs`/pipes/sockets). That pair is the cheapest way to decide whether a process is an I/O problem or a cache-hit success story.

**Q32.** The process wrote pages into the page cache (counted in `wchar`, and provisionally in the writeback accounting) and then **deleted or truncated** the file before writeback flushed them, so the kernel cancelled I/O it had already attributed. `cancelled_write_bytes` records that credit. Non-zero values are typical of temp-file churn — compilers, sort spills, upload staging — and mean the process's apparent write volume overstates what reached the disk.

**Q33.** `iotop` needs **`CONFIG_TASK_DELAY_ACCT`** (plus `CONFIG_TASKSTATS`, `CONFIG_TASK_IO_ACCOUNTING`, and the runtime `kernel.task_delayacct` sysctl on modern kernels) and requires **root / `CAP_NET_ADMIN`** to open the taskstats netlink socket. `pidstat -d` has the same taskstats dependency. The one needing neither is reading **`/proc/<pid>/io`** directly — any user can read it for their own processes, and root for all, with no kernel option beyond `CONFIG_TASK_IO_ACCOUNTING`.

**Q34.** **`vm.dirty_background_ratio`/`vm.dirty_background_bytes`** and **`vm.dirty_ratio`/`vm.dirty_bytes`** (with `vm.dirty_expire_centisecs` as the third). The mechanism: the job writes into the page cache with no `fsync`, so nothing reaches the disk and `wkB/s` stays near zero while `Dirty` climbs. When `Dirty` crosses the background threshold, `kworker` flush threads start; when it crosses `dirty_ratio`, **every writing process is throttled synchronously** until the backlog drains. The result is exactly the observed sawtooth: long quiet periods, then multi-second `w_await` while gigabytes are flushed at once. The fix is lower thresholds (expressed in `_bytes`, so they do not scale with RAM), so writeback is continuous rather than bursty.

### Lab 4

**Q35.** BDP = `1 Gbit/s × 0.040 s = 5 000 000 bytes ≈ 4.77 MiB` — a single flow needs about 5 MB in flight to fill that path. Without window scaling the receive window is capped at the 16-bit TCP header field, 65 535 B, giving `65535 / 0.040 = 1.638 MB/s ≈ 13.1 Mbit/s` — 1.3% of the link, no matter how fast the hardware is. The sysctl is **`net.ipv4.tcp_window_scaling`** (on by default; the RFC 7323 window-scale option is negotiated in the SYN, so a middlebox stripping it reproduces the 1990s). `ss -ti` shows **`wscale:7,7`** — the send and receive scale factors; its absence means no scaling.

**Q36.** `retrans:0/18` is `current/total`: zero segments are awaiting retransmission *right now*, and 18 have been retransmitted over the connection's life. The reason `nstat` can show `TcpRetransSegs` rising with every live connection clean is that `nstat` reports a **system-wide counter including connections that have since closed** — a storm of retransmits on short-lived connections leaves no trace in `ss`, which only shows sockets that still exist. Use `nstat` to detect that there is a problem, `ss -ti` on long-lived sockets to characterize it, and `TcpExtTCPLostRetransmit` to find retransmits that were themselves lost.

**Q37.** You have proven that **the per-flow limit, not the path, was the constraint** — the path carries at least 240 Mbit/s, so the single stream was limited by its own window, RTT, or loss-driven congestion response (Mathis), not by capacity. You have **not** proven what the path's actual ceiling is (eight streams may also be short of it), nor that the application can use parallel streams. Add a UDP test at a known offered rate (`iperf3 -u -b <rate>`) to measure capacity and loss independently of TCP's congestion control, and check `ss -ti` `delivery_rate` and `retrans` on the single stream to see which of window or loss was binding.

**Q38.** **GRO** (Generic Receive Offload), or hardware LRO — the NIC/driver coalesces consecutive segments into one large skb before the counters in `/proc/net/dev` are incremented, so the kernel counts one 24 000-byte "packet" where 16 frames crossed the wire. Any pps budget computed from these counters is therefore understated by up to the coalescing factor, which matters precisely when you are sizing an interrupt or softirq budget. Confirm with `ethtool -k <iface>` (look for `generic-receive-offload: on`, `large-receive-offload`) and note the transmit-side twin, TSO/GSO, which does the same to `tx` counts.

**Q39.** `errs` counts frames the hardware or driver rejected as malformed — CRC failures, length errors, FIFO overruns on some drivers: a **physical-layer or cabling** signal. `drop` counts frames the host received intact and then **discarded for lack of resources or because nothing wanted them** — a software-side signal. Next look at **`/proc/net/softnet_stat`** (the `dropped` column, meaning the per-CPU backlog queue overflowed) and tune **`net.core.netdev_max_backlog`**; also check `ethtool -S <iface>` for ring-buffer drops and `ethtool -g` for ring size. (Note that `drop` is also incremented harmlessly by frames for protocols nobody is listening to, so a slow, steady count on a noisy LAN is not a defect.)

### Lab 5

**Q40.** A round trip is: request `cli → rtr → srv`, which traverses the `vs-r` egress qdisc once (+20 ms); reply `srv → rtr → cli`, which traverses the `vc-r` egress qdisc once (+20 ms). Two qdisc traversals per round trip → 40 ms RTT. `netem` delays on **egress only**, so a single-sided 20 ms delay yields a 20 ms RTT. This is the standard mistake in homemade WAN emulation: configuring "20 ms each way" and then measuring 40 ms, or configuring one side and wondering why the RTT is half of what was intended.

**Q41.** Offered load (the sender ramping up) exceeded the shaped 100 Mbit/s rate → packets accumulated in the `netem` queue (`backlog 181p`) → the queue reached its `limit` and tail-dropped 12 packets → the TCP sender detected the loss and retransmitted them (`Retr 12`) while halving its congestion window, settling at 94.8 Mbit/s, just under the shaped rate. The saturated resource is the **egress bandwidth of `vs-r`**, and the queue backlog is the proof — this is the canonical demonstration that drops at a shaper are not an error but the mechanism by which TCP discovers capacity. (Growing backlog with *no* drops would instead be bufferbloat: latency inflation rather than loss.)

**Q42.** Forwarding runs in **softirq context** (`NET_RX_SOFTIRQ`), charged to `%soft`, not to any process. If the per-invocation budget is exhausted repeatedly the kernel defers the remaining work to the per-CPU **`ksoftirqd/<n>`** kernel thread, which *is* visible in `top` and whose appearance at high CPU is the classic sign of a packet-rate problem. Forwarded traffic never enters a user process's accounting because it is never copied to a socket: the packet is received, routed and transmitted entirely inside the kernel's network stack, which is also why `nethogs` can tell you nothing about a router's transit traffic.

**Q43.** Expected ordering: 0 rules fastest, set-based next (very close to it), 2 000 linear rules by far the slowest. Per-packet cost: empty chain ≈ O(1); 2 000 discrete rules = **O(n)** — every packet is evaluated against up to 2 000 rules sequentially before the accept verdict; one rule plus a set = **O(1)** for an exact-match set. `nftables` sets are backed by a **hash table** for exact matches; **`flags interval`** switches the backend to a different data structure (a red-black tree, or `nft_set_pipapo` for concatenations) which supports ranges and prefixes at **O(log n)** instead of O(1) — still vastly better than linear, and the reason `nft` sets / `ipset` exist. This is also the structural answer to "why is `iptables` with thousands of rules slow": its linear `ipt_do_table` walk.

**Q44.** **`%soft`** (per-CPU, from `mpstat -P ALL`). Rule evaluation happens in softirq context, so a ruleset bottleneck shows up as `%soft` saturating one or more CPUs while the link utilization stays well below capacity — and `perf top` will name `nft_do_chain` or `ipt_do_table` outright. UDP with `-l 64` is the right test because a firewall's cost is **per packet, not per byte**: with 64-byte payloads you maximize pps for a given bitrate and the per-packet rule walk dominates. TCP at default sizes would mix in congestion control, offloads (TSO/GSO coalescing hides pps), and ACK clocking, confounding the measurement.

**Q45.** Read **`nf_conntrack_count` against `nf_conntrack_max`** first. The arithmetic is Little's law again: `required entries ≈ new connections/s × average entry lifetime`. If your peak is 2 000 new conn/s and entries live the default `nf_conntrack_tcp_timeout_established` of 432 000 s (5 days), the steady-state requirement is absurd — the fix is the **timeout** (and `tcp_timeout_time_wait`, `udp_timeout`), because you are holding state for connections that ended long ago. If connection lifetime is genuinely long and legitimate, the fix is **`nf_conntrack_max`** (raised together with `nf_conntrack_buckets` to keep the hash chains short — by default the two are equal — at a cost of one slab object of unreclaimable kernel memory per entry: `cat /sys/kernel/slab/nf_conntrack/slab_size`, 256 B on a 6.18 kernel). The diagnostic signature is precise: *new* connections failing while *established* ones are unaffected, with CPU and bandwidth idle.

**Q46.** `drop` counts packets dropped because the table was full or an entry could not be allocated. **`insert_failed`** counts attempts to insert a new entry that collided with an existing, identical tuple — in practice almost always **NAT source-port collisions**: many connections from the same source being SNAT'd to one address, where the kernel could not find a free `(saddr, sport, daddr, dport)` tuple. It is produced by high connection rates from behind a single NAT address with a small port range, not by a full table. Remedies: a larger SNAT pool (`nft ... snat to 198.51.100.1-198.51.100.8`), `--random-fully`-style port randomization, or `fullcone`-free designs — none of which involve `nf_conntrack_max`.

**Q47.** (1) `dropped 0` means the per-CPU input backlog has not overflowed — no packets lost at that stage, so `netdev_max_backlog` is adequate. (2) **`time_squeeze`** counts how many times the NAPI poll loop ran out of its **budget** (`net.core.netdev_budget`, 300 packets, or `netdev_budget_usecs`, 2000 µs) with work still pending, and had to defer to `ksoftirqd` — i.e. the CPU could not drain the ring in one pass. (3) `%soft 70%` on cpu0 alone with ~1% elsewhere means **all receive processing is landing on one CPU**: one hardware queue, or one IRQ, pinned there. The two mechanisms to spread it: **RSS** (Receive Side Scaling — multiple hardware queues, each with its own IRQ, spread via `/proc/irq/*/smp_affinity`, ideally managed by `irqbalance` or explicit pinning) and, where the NIC cannot do it, **RPS** (Receive Packet Steering, software redistribution via `/sys/class/net/<if>/queues/rx-*/rps_cpus`), optionally with RFS for flow locality. Raising `netdev_budget` only makes the single CPU work harder; it does not add capacity.

### Lab 6

**Q48.** It is double counting from the *link's* point of view but not from the *billing* point of view, and you must choose deliberately. Every forwarded packet traverses `acct_fwd` once and, because the chain policy is `accept` and nothing terminates it, matches **both** the `ip saddr` rule for its source and the `ip daddr` rule for its destination — so one packet increments two counters. For `cli → srv` traffic, `out_10_10_1_2` and `in_10_10_2_2` are literally the same bytes seen as "sent by the client" and "received by the server", which is why they are identical. To bill each packet once per client, either (a) count only the direction you bill (e.g. only `saddr` for upload and only `daddr` for download, then sum per client knowing each packet contributes to exactly one of its two clients' meters), or (b) restrict the matching to the subnet you own: `ip saddr 10.10.1.0/24 counter name ...` so transit between two foreign addresses is never counted twice. Always state which convention your dashboard uses.

**Q49.** **`nft reset counters` is correct only if exactly one poller exists.** Read-and-zero is atomic with respect to the packet path, so no bytes are lost between read and reset, and a single sample per interval suffices — that is its advantage over sampling twice. But it is **destructive**: with two pollers (your script and a Prometheus exporter), each one zeroes the counters the other needs, and both report roughly half the real traffic. The two-sample delta is non-destructive and therefore safe for any number of concurrent readers; its weakness is that it can miss a counter wrap or a `nft flush`/reload between samples, which shows up as a negative delta — check for that in the script rather than printing a negative bandwidth.

**Q50.** Netfilter hook order for a forwarded packet is: `prerouting` (where **DNAT** is applied) → routing decision → **`forward`** → `postrouting` (where **SNAT** is applied). So a counter in `forward` sees the **original, pre-SNAT `saddr`** (the private LAN client address — exactly what you want for per-client accounting) and the **already-DNAT-translated `daddr`**. Consequences: per-client *upload* accounting in `forward` works naturally and bills the real internal client; per-client *download* accounting also works, because the reply packet's `daddr` has been reverse-translated by conntrack in `prerouting` before `forward` is reached. But any rule matching on the **public** address of a DNAT'd service must live in `prerouting` (before translation) or use `ct original` to recover the pre-NAT tuple — matching the public address in `forward` will never hit.

**Q51.** (a) **`sar -n DEV` / `sadf`** — the only tool with history; nothing else can answer a question about 03:00 after the fact (per-customer granularity requires that you were collecting per-client `nft` counters into a time series, which is the production form of this lab). (b) **`nethogs`** — the only one of the four that maps bytes to a **PID**, because it associates socket inodes with processes; `nft` counters and `iftop` see addresses, not processes. (c) **`iftop`** — live, sorted, per-peer-pair top-talkers on one interface; built for exactly this, and the only one that gives you the answer in two seconds with no setup. (d) **`iptraf-ng`** — its statistical breakdowns are per-protocol and per-port, which neither `iftop` (peers) nor `nethogs` (processes) provides. (A fifth answer worth knowing: `ss -tanp` plus `nstat` for per-socket and per-protocol state, and `tcpdump`/`nfdump`/NetFlow when you need durable per-flow records.)

### Lab 7

**Q54.** Files are `saDD`, where `DD` is the **day of the month**, in `/var/log/sysstat/` (Debian family) or `/var/log/sa/` (RHEL family) — so the set rotates monthly and `sa15` is the 15th of the current month. **`sa1`** is the collector: it invokes `sadc` to append one binary sample to today's `saDD` file, and is the thing a cron entry or `sysstat-collect.timer` runs every 10 minutes. **`sa2`** is the summarizer: it runs once near end of day, writes the human-readable daily report `sarDD`, and performs the retention cleanup. **`HISTORY`** (in `/etc/sysconfig/sysstat`, or `/etc/sysstat/sysstat` on Debian) is the number of **days** kept; when it exceeds 28, `sadc` switches to `saYYYYMMDD` names so that days do not collide across months. For a date 20 days ago you therefore read either `sa<DD>` of that date — if `HISTORY` is large enough that it has not been overwritten — or `saYYYYMMDD`; check `COMPRESSAFTER`, since older files may be `.xz`/`.gz` and need `sar -f` on the decompressed copy.

**Q52.** The 03:10 interval will show the 45-second stall **averaged over 600 seconds** — roughly 7.5% of the effect — which for most metrics is indistinguishable from noise. `sar` will report an unremarkable data point and you will wrongly conclude "nothing was happening". The change is to shorten the collection interval (edit the `sysstat-collect.timer`'s `OnCalendar`, or the `*/10` in `/etc/cron.d/sysstat`, to 1 minute). The cost is ~10× the disk space and ~10× the `sadc` wakeups, plus it still cannot catch sub-interval spikes — which is the structural argument for a real time-series agent with 10–15 s resolution alongside `sar`, and for reading PSI `total` counters, which are cumulative and therefore lose nothing to averaging.

**Q53.** `await 94 ms` is the **cause**; `%iowait 22.8` is the **symptom**. Causality runs device → task → CPU: requests queue at the device, tasks block in D state, CPUs go idle with blocked tasks and the kernel books that idle time as `%iowait`. Tuning anything CPU-side changes nothing. The third flag is **`sar -B`** (paging statistics: `majflt/s`, `pgscank/s`, `pgsteal/s`, `%vmeff`) — or `sar -r`/`sar -W`: if major faults and scanning are flat, the I/O is application-driven rather than the side effect of memory reclaim paging things back in, which is a completely different fix.

### Lab 8

**Q55.**

| # | Resource | Confirming command | Action |
|---|---|---|---|
| A | **Disk I/O** (23 tasks in D state; CPU idle, memory fine) | `iostat -xz 1` → look at `await`, `aqu-sz`; then `iotop -o` | Identify the device and the process; reduce concurrency or move the workload. Load average 24 here is *not* a CPU signal. |
| B | **CPU** (genuine saturation: `r 9` on 8 CPUs, `us 92`, PSI 61%) | `mpstat -P ALL 1` + `pidstat -u -t 1` | Find the thread, profile it (`perf top`), add cores or cap the workload. |
| C | **Memory** (thrashing: `si` *and* `so` both large, available 180 MB) | `vmstat 1` with `/proc/pressure/memory`; then PSS ranking | Reduce the working set or add RAM. The high `wa` is a *consequence* of swap I/O — do not chase the disk. |
| D | **Network** (loss collapsing the congestion window to 2 segments) | `nstat -az \| grep -i retrans` + `ss -ti` on a live socket | Find the lossy hop (`mtr`), check for a saturated shaper/queue or a faulty link; buffers are not the problem at `cwnd:2`. |
| E | **Disk I/O, and it is at its ceiling** — `aqu-sz 1.1` and `await 11 ms` on a 7 200-rpm disk is one request at a time at seek latency | `iostat -xz 1`; compare `rkB/s` and `r_await` against the device class | Nothing is misconfigured: the hardware is the limit. Change the hardware, the access pattern, or the window. `%util 100` here is honest, unlike on NVMe. |
| F | **Connection tracking table** | `sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max`; `conntrack -S` | Lower the established/time-wait timeouts first; raise `nf_conntrack_max` with `nf_conntrack_buckets` if the demand is real. |
| G | **CPU, single-core, application-limited** | `mpstat -P ALL 1` (one CPU at 100%), `top -H` to confirm one thread | Nothing to tune on the host: more cores will not help a single-threaded hot loop. Parallelize, shard, or get a faster core. `%soft 0` rules out a packet-processing cause. |
| H | **Nothing — this is a healthy system** | `free -w` plus `/proc/pressure/memory` (0.00) and `vmstat` (`si/so` 0) | No action. 240 MB "free" with 13 GB of page cache and zero pressure is a correctly used machine; `MemAvailable`, not `MemFree`, is the number that matters. |

**Q56.** `500 × 8 × 1000 / 21600 = 185.19 Mbit/s`, equivalently `500 × 1000 / 21600 = 23.15 MB/s` sustained for the full six hours, with **no** allowance for protocol overhead, contention, or the fact that real jobs are not perfectly paced. A 1 Gbit/s link carries it with large margin — the link is not the constraint, which is itself the useful conclusion: it directs attention to the disk and to the application.

**Q57.** Required 23.15 MB/s versus `80 × 4 / 1024 = 0.31 MB/s` random and ~160 MB/s sequential. The job fits **only if the access pattern is sequential** — it needs 14% of sequential capacity but **74×** the random capacity. Implication: configure the backup for large sequential reads — big block sizes, few concurrent streams (parallelism on a rotational disk converts sequential into random and destroys the margin), readahead left enabled, and avoid per-file overhead on millions of small files by streaming into an archive. Verify at runtime with `iostat -xz`: `rareq-sz` should be large and `rrqm/s` non-zero. If it is not, you can see the pattern go wrong before the window is missed.

**Q58.** `1.22 × 1448 × 8 / (0.040 × 0.01) / 1e6 = 35.3 Mbit/s` — one Reno-like TCP flow cannot exceed ~35 Mbit/s at 40 ms RTT and 0.01% loss, which is 19% of the 185 Mbit/s the job needs, on a link with ten times the raw capacity. This is why "the link is 1 Gbit/s, so the transfer should be fast" is wrong so often. Two remedies: **on the hosts** — raise the autotuning ceilings (`net.ipv4.tcp_rmem`/`tcp_wmem` and `net.core.rmem_max`/`wmem_max`) so the window can reach the 5 MB BDP, and switch congestion control to a loss-tolerant algorithm (`net.ipv4.tcp_congestion_control = bbr`), which is not governed by the Mathis √loss relationship; **on the job** — use parallel streams (`rsync` fan-out, `rclone --transfers`, multi-stream object upload), since N flows multiply the achievable rate while each remains individually window-limited. Watch **`delivery_rate`** in `ss -ti` (together with `cwnd` and `retrans`) to confirm: a rising `cwnd` that holds without a retransmit cliff is the fix working. And fix the loss if you can — 0.01% is not "almost zero" for a long fat pipe, it is the dominant term.

</details>

---

## Sources

- LPI, *Exam 201-450 Objectives* (LPIC-2, version 4.5.0), objective 200.1 — <https://www.lpi.org/our-certifications/exam-201-202-objectives/>
- Linux kernel documentation, *The /proc Filesystem* — <https://www.kernel.org/doc/html/latest/filesystems/proc.html>
- Linux source, `si_mem_available()` (how `MemAvailable` is computed) — <https://github.com/torvalds/linux/blob/master/mm/show_mem.c>
- Linux kernel documentation, *I/O statistics fields* (`/proc/diskstats`) — <https://www.kernel.org/doc/html/latest/admin-guide/iostats.html>
- Linux kernel documentation, *PSI – Pressure Stall Information* — <https://www.kernel.org/doc/html/latest/accounting/psi.html>
- Linux kernel documentation, *Control Group v2* (memory controller, `memory.events`, `memory.stat`) — <https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html>
- Linux kernel documentation, *Documentation for /proc/sys/vm* (`dirty_ratio`, `swappiness`, `overcommit_memory`) — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html>
- Linux kernel documentation, *Documentation for /proc/sys/net* (`netdev_budget`, `netdev_max_backlog`) — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/net.html>
- Linux kernel documentation, *SNMP counter* (TCP/IP counters behind `nstat` and `netstat -s`) — <https://www.kernel.org/doc/html/latest/networking/snmp_counter.html>
- Linux kernel documentation, *Connection tracking sysctl* — <https://www.kernel.org/doc/html/latest/networking/nf_conntrack-sysctl.html>
- Linux kernel documentation, *Scaling in the Linux Networking Stack* (RSS, RPS, RFS) — <https://www.kernel.org/doc/html/latest/networking/scaling.html>
- sysstat project (`sar`, `iostat`, `mpstat`, `pidstat`, `sadf`, `sa1`/`sa2`) — <https://sysstat.github.io/>
- Linux man-pages project: `proc(5)` <https://man7.org/linux/man-pages/man5/proc.5.html> · `vmstat(8)` <https://man7.org/linux/man-pages/man8/vmstat.8.html> · `iostat(1)` <https://man7.org/linux/man-pages/man1/iostat.1.html> · `sar(1)` <https://man7.org/linux/man-pages/man1/sar.1.html> · `ss(8)` <https://man7.org/linux/man-pages/man8/ss.8.html> · `lsof(8)` <https://man7.org/linux/man-pages/man8/lsof.8.html> · `tc-netem(8)` <https://man7.org/linux/man-pages/man8/tc-netem.8.html> · `ip-netns(8)` <https://man7.org/linux/man-pages/man8/ip-netns.8.html>
- nftables wiki, *Counters* and *Sets* — <https://wiki.nftables.org/wiki-nftables/index.php/Counters> · <https://wiki.nftables.org/wiki-nftables/index.php/Sets>
- iperf3 documentation (ESnet) — <https://software.es.net/iperf/>
- fio documentation — <https://fio.readthedocs.io/en/latest/fio_doc.html>
- M. Mathis et al., *The Macroscopic Behavior of the TCP Congestion Avoidance Algorithm*, ACM SIGCOMM CCR 27(3), 1997 — <https://dl.acm.org/doi/10.1145/263932.264023>