# 108.1 — Maintain System Time

**LPIC-1 (101-500 / 102-500, v5.0) — Topic 108: Essential System Services**

---

## 1. The architectural problem: time is shared mutable state across your entire fleet

Every other subsystem you operate has an owner. Time does not. `CLOCK_REALTIME` is a global, unsynchronised, silently-mutable variable that every process on every node reads, that no application controls, and that has no transactional semantics. When it is wrong, nothing crashes — things become *subtly, expensively wrong*, and the failure surfaces three layers away from the cause.

### 1.1 The three clocks a Linux system actually has

A production engineer must stop saying "the clock" and start naming which of three independent things is meant:

| Clock | Source | Survives reboot | Monotonic | Adjusted by NTP | Read via |
|---|---|---|---|---|---|
| **Hardware clock (RTC)** | Battery-backed CMOS oscillator on the mainboard, `/dev/rtc0` | Yes | No | Only indirectly (11-minute mode / `hwclock -w`) | `hwclock`, `/sys/class/rtc/rtc0/time` |
| **System clock — `CLOCK_REALTIME`** | Kernel counter seeded at boot from the RTC, ticked by the *clocksource* | No | **No — can step backwards** | Yes (step and slew) | `clock_gettime(2)`, `date` |
| **System clock — `CLOCK_MONOTONIC` / `CLOCK_BOOTTIME`** | Same clocksource, zero-based at boot | No | **Yes — never steps** | Frequency only (slew), never stepped | `clock_gettime(2)` |

The single most important consequence, and the one that separates a correct distributed system from a broken one:

> **`CLOCK_REALTIME` is not a clock; it is a distributed consensus value about what UTC currently is.** Never measure a duration with it. Never use it as a monotonic sequence. Timeouts, latency histograms, rate limiters, retry backoff, lease expiry and TTL arithmetic all belong on `CLOCK_MONOTONIC`.

```console
$ cat > /tmp/clocks.c <<'EOF'
#include <stdio.h>
#include <time.h>
int main(void) {
    struct timespec r, m, b;
    clock_gettime(CLOCK_REALTIME,  &r);
    clock_gettime(CLOCK_MONOTONIC, &m);
    clock_gettime(CLOCK_BOOTTIME,  &b);
    printf("REALTIME  %ld.%09ld\n", r.tv_sec, r.tv_nsec);
    printf("MONOTONIC %ld.%09ld\n", m.tv_sec, m.tv_nsec);
    printf("BOOTTIME  %ld.%09ld\n", b.tv_sec, b.tv_nsec);
    return 0;
}
EOF
$ gcc -O2 -o /tmp/clocks /tmp/clocks.c && /tmp/clocks
REALTIME  1787841125.123456789
MONOTONIC 942317.884512003
BOOTTIME  951204.117338442
```

`BOOTTIME - MONOTONIC` is 8887 s — the time this machine spent suspended. That difference is why `CLOCK_MONOTONIC` is the wrong clock for anything that must survive a laptop lid, and `CLOCK_BOOTTIME` is the right one.

### 1.2 The production failure catalogue

Clock skew does not produce a stack trace. It produces the following, each of which has cost real incidents:

| Skew magnitude | Systems that break | Symptom you will actually be paged for |
|---|---|---|
| **> 30 s** | TOTP / MFA (RFC 6238, 30 s step, ±1 window) | "MFA rejects every code" for a single node's users |
| **> 300 s** | Kerberos / AD (`clockskew = 300` in `krb5.conf`) | `KRB_AP_ERR_SKEW: Clock skew too great`; SSSD auth failures fleet-wide |
| **> 900 s** | AWS SigV4, most cloud APIs | `RequestTimeTooSkewed: The difference between the request time and the current time is too large` |
| **Any, if backwards** | JWT `nbf`/`iat`, TLS `notBefore` | Freshly issued certificate or token is rejected as "not yet valid" by the *issuer's own* peers |
| **~1 s between peers** | etcd / Raft | `the clock difference against peer 8211f1d0f64f3269 is too high [1.523s > 1s]` — then leader-election flapping |
| **Sub-second, cross-node** | Cassandra / DynamoDB LWW, Kafka log retention, distributed tracing | Silent write loss (last-write-wins picks the *older* write), spans with negative duration, retention deleting the wrong segments |
| **Any** | `at`, `cron`, log correlation, SIEM, billing | Jobs skipped or double-run; incident timelines that cannot be reconstructed |
| **Backwards step of any size** | Anything using `CLOCK_REALTIME` for timeouts | Hung threads with an effectively infinite timeout |

The last row is why `ntpd` has a *panic threshold*: correcting a large error by stepping is itself a hazard. See §6.2.

### 1.3 Why the fix is not "run `ntpdate` at boot"

The naive design — read a server once at boot, `settimeofday()`, done — fails in three ways that matter at scale:

1. **Crystal drift is continuous.** A commodity RTC/TSC crystal is specified at ±20–50 ppm. At 50 ppm a node gains or loses **4.3 s/day** — Kerberos-breaking within 70 hours of a clean boot.
2. **Stepping is destructive.** A one-shot correction at boot is a `CLOCK_REALTIME` discontinuity in the middle of a running system.
3. **A single source is a single point of *being wrong*.** One misconfigured server, and every client faithfully synchronises to the wrong time. NTP's value is not "ask a server"; it is the *selection and clustering algorithms* that discard falsetickers (§6.1).

The correct model is a **control loop**: continuously measure the local oscillator's error against multiple independent references, estimate its *frequency* error, and correct the frequency so the clock stays right on its own between polls. That is what `ntpd` and `chronyd` are — PLL/FLL disciplinarians, not time setters.

---

## 2. Kernel timekeeping mechanics

### 2.1 The clocksource

The kernel does not read the RTC to tick. It reads a free-running counter, the **clocksource**, and converts cycles to nanoseconds.

```console
$ cat /sys/devices/system/clocksource/clocksource0/available_clocksource
kvm-clock tsc acpi_pm
$ cat /sys/devices/system/clocksource/clocksource0/current_clocksource
kvm-clock
```

| Clocksource | Typical resolution | Read cost | vDSO-capable | Notes |
|---|---|---|---|---|
| `tsc` | ~0.3 ns | ~15–25 ns (register read) | **Yes** | Requires `constant_tsc` + `nonstop_tsc`; the only source with acceptable performance |
| `kvm-clock` | ns | ~20–30 ns | Yes | Paravirtualised; host propagates its own discipline to the guest |
| `hpet` | ~70 ns | **~500–1000 ns (MMIO)** | No | Fallback. A silent 30× regression on `clock_gettime()` |
| `acpi_pm` | ~280 ns | **~1000+ ns (port I/O)** | No | Last resort. Catastrophic for syscall-heavy workloads |
| `arch_sys_counter` | ns | ~20 ns | Yes | ARM64 generic timer |

**The production trap.** The kernel runs a *watchdog* that cross-checks the TSC. If a CPU's TSC is found unstable it is demoted at runtime:

```console
$ dmesg -T | grep -iE 'tsc|clocksource'
[Thu Aug 27 03:14:22 2026] clocksource: timekeeping watchdog on CPU3: Marking clocksource 'tsc' as unstable because the skew is too large:
[Thu Aug 27 03:14:22 2026] clocksource:                       'hpet' wd_nsec: 498776745 wd_now: 6d3a91f2
[Thu Aug 27 03:14:22 2026] clocksource:                       'tsc' cs_nsec: 499115281 cs_now: 3f2a8b71c992
[Thu Aug 27 03:14:22 2026] clocksource: Switched to clocksource hpet
```

Because `hpet` cannot be served from the vDSO, every `clock_gettime()` becomes a real syscall. A Go or Java service doing millions of timestamp calls per second will show a p99 latency cliff with no application-level change. **Add `dmesg | grep 'Switched to clocksource'` to your node triage runbook.** This is the single highest-value diagnostic in this topic that is not about correctness at all.

### 2.2 How NTP actually moves the clock: `adjtimex(2)`

Neither `ntpd` nor `chronyd` calls `settimeofday()` in steady state. They call `adjtimex(2)`, handing the kernel a frequency correction and letting the kernel's own NTP discipline apply it smoothly.

```console
$ adjtimex --print
         mode: 0
       offset: -12
    frequency: 807567
     maxerror: 16000
     esterror: 254
       status: 8193
time_constant: 7
    precision: 1
    tolerance: 32768000
         tick: 10000
     raw time:  1787841125s 419834112us = 1787841125.419834112
   return value = 0 (clock synchronized)
```

Field decoding, which is what the `node_timex_*` Prometheus metrics expose verbatim:

- `frequency` is in units of 2⁻¹⁶ ppm. `807567 / 65536 = 12.32 ppm` — this crystal runs 12.32 parts per million slow, and the kernel is compensating.
- `status: 8193` = `0x2001` = `STA_PLL (0x0001) | STA_NANO (0x2000)`. **`STA_UNSYNC` is `0x0040`; its absence means the clock is disciplined.**
- `maxerror` grows monotonically between updates at the `tolerance` rate. When it exceeds 16 s the kernel declares itself unsynchronised — this is the basis of the `NodeClockNotSynchronising` alert.
- `return value = 0` is `TIME_OK`. `5` is `TIME_ERROR` (unsynchronised).

### 2.3 The 11-minute mode

When the kernel is NTP-disciplined (`STA_UNSYNC` clear), it **automatically writes `CLOCK_REALTIME` back to the RTC every 11 minutes**. This is legacy behaviour from the original `ntpd` design, and it has two operational consequences:

1. You almost never need `hwclock --systohc` on a synchronised machine. The kernel is already doing it.
2. `hwclock --adjust` drift correction is meaningless while 11-minute mode is active — the RTC is being overwritten faster than any drift file can model it. Modern `util-linux` is explicit about this, and most distributions no longer run drift correction at boot.

```console
$ awk '{ printf "status=0x%x  UNSYNC=%s\n", $1, and($1,0x40)?"set":"clear" }' \
    <(adjtimex --print | awk '/status:/{print $2}')
status=0x2001  UNSYNC=clear
```

---

## 3. The hardware clock (RTC)

### 3.1 UTC or local time — an architectural decision, not a preference

The RTC stores a naked broken-down time with **no timezone information whatsoever**. Whether those digits mean UTC or local time is a convention recorded in `/etc/adjtime`, and the kernel/`hwclock` applies the current `TZ` to interpret them.

| RTC contents | Correct for | Failure mode |
|---|---|---|
| **UTC** (`hwclock --utc`, the default) | **Every server, every container host, every cloud VM** | None. DST transitions are invisible to the RTC. |
| **Local time** (`hwclock --localtime`) | Windows dual-boot desktops only | The RTC jumps at DST. Two OSes each "correct" it. Boot inside the ambiguous 01:00–02:00 autumn hour and the system clock is wrong by an hour. `timedatectl` warns that this mode is *not fully supported and will create various problems*. |

**Rule: servers keep the RTC in UTC and the system timezone in UTC.** Local time is a presentation-layer concern belonging to the user's browser or the `TZ` environment variable, never to the fleet.

### 3.2 `/etc/adjtime`

```console
$ cat /etc/adjtime
0.000000 1787840000 0.000000
1787840000
UTC
```

| Line | Field | Meaning |
|---|---|---|
| 1 | `0.000000` | Systematic drift, **seconds per day** |
| 1 | `1787840000` | UNIX time of the last adjustment |
| 1 | `0.000000` | Fractional second remainder carried forward |
| 2 | `1787840000` | UNIX time of the last calibration (`hwclock --set`/`--systohc`) |
| 3 | `UTC` \| `LOCAL` | **How to interpret the RTC registers** |

If this file is absent, `hwclock` assumes UTC. If line 3 says `LOCAL` on a server, you have found your bug.

### 3.3 `hwclock` in practice

```console
# hwclock --show
2026-08-27 14:32:06.482913+00:00

# hwclock --show --utc --verbose
hwclock from util-linux 2.38.1
System Time: 1787841126.123456
Trying to open: /dev/rtc0
Using the rtc interface to the clock.
Assuming hardware clock is kept in UTC time.
Waiting for clock tick...
...got clock tick
Time read from Hardware Clock: 2026/08/27 14:32:06
Hw clock time : 2026/08/27 14:32:06 = 1787841126 seconds since 1969
Time since last adjustment is 1126 seconds
Calculated Hardware Date: 2026/08/27 14:32:06
2026-08-27 14:32:06.482913+00:00
```

(`seconds since 1969` is genuinely what `hwclock` prints — an off-by-one in the wording, not in the arithmetic.)

| Command | Direction | Use |
|---|---|---|
| `hwclock -r` / `--show` | RTC → stdout | Read the RTC |
| `hwclock -w` / `--systohc` | **System → RTC** | Persist a corrected system clock before a reboot |
| `hwclock -s` / `--hctosys` | **RTC → System** | Seed the system clock on an air-gapped/offline boot |
| `hwclock --set --date="2026-08-27 14:32:00"` | literal → RTC | Set the RTC directly (rare) |
| `hwclock --systz` | Apply TZ to system clock | Used at boot when the RTC is `LOCAL` |
| `hwclock --utc` / `--localtime` | — | Declare the RTC convention; **rewrites line 3 of `/etc/adjtime`** |

Mnemonic for the exam: **`s` = system is the *destination*** (`--hctosys`), **`w` = write to hardware** (`--systohc`).

The raw sysfs path, useful when `hwclock` is unavailable in a minimal image:

```console
$ cat /sys/class/rtc/rtc0/time /sys/class/rtc/rtc0/date /sys/class/rtc/rtc0/hctosys
14:32:06
2026-08-27
1
```

`hctosys=1` means this RTC was the one used to seed the system clock at boot.

---

## 4. Timezones

### 4.1 The data model

The IANA tz database (`tzdata`) is compiled into **TZif** binary files under `/usr/share/zoneinfo/`. Each file contains the complete history of UTC offsets, DST rules and abbreviations for one zone, plus a trailing POSIX TZ string for extrapolating beyond the last recorded transition.

```console
$ file /usr/share/zoneinfo/Europe/Madrid
/usr/share/zoneinfo/Europe/Madrid: timezone data, version 2, 10 gmt time flags, \
10 std time flags, no leap seconds, 88 transition times, 10 abbreviation chars

$ zdump -v Europe/Madrid | grep 2026
Europe/Madrid  Sun Mar 29 00:59:59 2026 UT = Sun Mar 29 01:59:59 2026 CET isdst=0 gmtoff=3600
Europe/Madrid  Sun Mar 29 01:00:00 2026 UT = Sun Mar 29 03:00:00 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 00:59:59 2026 UT = Sun Oct 25 02:59:59 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 01:00:00 2026 UT = Sun Oct 25 02:00:00 2026 CET isdst=0 gmtoff=3600
```

Read those four lines carefully — they are the whole DST problem:

- **March 29, 02:00–02:59 local does not exist.** A cron job at `02:30` never runs that day.
- **October 25, 02:00–02:59 local occurs twice.** A cron job at `02:30` runs *twice*, and two log lines an hour apart carry the same local timestamp.

This is the argument for UTC on servers, stated as a fact rather than a preference: **local civil time is not a total order.**

### 4.2 Resolution order

The kernel knows nothing about timezones. Resolution happens entirely in userspace, in glibc, per process, in this order:

1. **`$TZ`** environment variable, if set.
   - `TZ=Europe/Madrid` — named zone, read from `/usr/share/zoneinfo`
   - `TZ=:/usr/share/zoneinfo/Asia/Tokyo` — explicit path
   - `TZ=CET-1CEST,M3.5.0,M10.5.0/3` — a self-contained POSIX rule: standard abbrev `CET`, **offset −1 h expressed with inverted sign**, DST abbrev `CEST`, starting month 3 week 5 (= last) day 0 (= Sunday), ending month 10 week 5 day 0 at 03:00
   - `TZ=UTC0` or `TZ=""` — UTC
2. **`/etc/localtime`** — must be a *symlink* into `/usr/share/zoneinfo` for `systemd` to report the zone name.
3. Fallback: UTC.

`/etc/timezone` (Debian/Ubuntu) is a plain-text *label* consumed by `dpkg-reconfigure tzdata` and some tooling. **It does not affect glibc.** If `/etc/localtime` and `/etc/timezone` disagree, glibc follows `/etc/localtime` and your configuration management reports the other — a classic drift bug.

```console
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 27 Aug 12 09:41 /etc/localtime -> /usr/share/zoneinfo/Etc/UTC

$ cat /etc/timezone
Etc/UTC

$ TZ=Asia/Tokyo date -R
Thu, 27 Aug 2026 23:32:05 +0900

$ TZ=America/Argentina/Buenos_Aires date -R
Thu, 27 Aug 2026 11:32:05 -0300

$ date -R
Thu, 27 Aug 2026 14:32:05 +0000
```

### 4.3 Setting the zone

```console
# timedatectl list-timezones | grep -i madrid
Europe/Madrid

# timedatectl set-timezone Europe/Madrid
# ls -l /etc/localtime
lrwxrwxrwx 1 root root 33 Aug 27 14:33 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
```

Non-systemd or manual:

```console
# ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
# echo 'Etc/UTC' > /etc/timezone          # Debian family
```

Interactive selector (exam-relevant, writes nothing — it only prints the `TZ` value):

```console
$ tzselect
Please identify a location so that time zone rules can be set correctly.
Please select a continent, ocean, "coord", "TZ" or "time".
 1) Africa
 2) Americas
...
#? 8
...
The following information has been given:
        Spain
Therefore TZ='Europe/Madrid' will be used.
...
You can make this change permanent for yourself by appending the line
        TZ='Europe/Madrid'; export TZ
to the file '.profile' in your home directory.
```

**`tzdata` is a moving dataset.** Governments change DST rules with weeks of notice. A stale `tzdata` package is a correctness bug, not a hygiene issue: patch it like a security update.

---

## 5. `date` and `timedatectl`

### 5.1 `date`

```console
$ date
Thu Aug 27 14:32:05 UTC 2026

$ date -u
Thu Aug 27 14:32:05 UTC 2026

$ date -Is                      # ISO 8601, second precision
2026-08-27T14:32:05+00:00

$ date -u +%Y-%m-%dT%H:%M:%S.%3NZ
2026-08-27T14:32:05.123Z

$ date +%s                      # UNIX epoch seconds
1787841125

$ date -d @1787841125 -u
Thu Aug 27 14:32:05 UTC 2026

$ date -d 'now + 90 minutes' -Is
2026-08-27T16:02:05+00:00

$ date -d '2026-10-25 02:30:00 Europe/Madrid' -u --iso-8601=seconds
2026-10-25T00:30:00+00:00
```

That last one is the ambiguous autumn hour; glibc silently resolves it to the *first* (DST) occurrence. If your application parses user-supplied local timestamps, this is where the data-loss bug lives.

**Setting the time manually** (requires `CAP_SYS_TIME`):

```console
# date -s "2026-08-27 14:32:00"
Thu Aug 27 14:32:00 UTC 2026
```

The format for `date --set` (`MMDDhhmmCCYY.ss`) is a legacy alternative:

```console
# date 082714322026.00
Thu Aug 27 14:32:00 UTC 2026
```

Guard rails you should internalise:

- `date -s` performs an **unconditional step**. On a running production node this is a `CLOCK_REALTIME` discontinuity — see §6.2.
- With `chronyd`/`ntpd` running, your manual step will be measured as an error and corrected back within a poll interval. Stop the daemon first, or use its own tooling.
- `date -s` **does not touch the RTC.** Follow with `hwclock --systohc` if you need it to survive a reboot.

### 5.2 `timedatectl`

The systemd front-end that unifies the three concerns: system clock, RTC, timezone.

```console
$ timedatectl
               Local time: Thu 2026-08-27 14:32:05 UTC
           Universal time: Thu 2026-08-27 14:32:05 UTC
                 RTC time: Thu 2026-08-27 14:32:06
                Time zone: Etc/UTC (UTC, +0000)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

The three lines to read as an SRE, in order: **`System clock synchronized`** (is `STA_UNSYNC` clear?), **`NTP service`** (is a disciplinarian even running?), **`RTC in local TZ`** (must be `no` on a server).

```console
# timedatectl set-timezone Etc/UTC
# timedatectl set-ntp true
# timedatectl set-local-rtc 0 --adjust-system-clock
# timedatectl set-time "2026-08-27 14:32:00"
Failed to set time: Automatic time synchronization is enabled
```

That error is correct behaviour and worth memorising: **`set-time` is refused while `set-ntp` is on.** Disable NTP first, or do not set the time by hand.

`set-ntp` does not hardcode `systemd-timesyncd`. It enables whichever unit is registered in `/usr/lib/systemd/ntp-units.d/`:

```console
$ cat /usr/lib/systemd/ntp-units.d/*.list
50-chrony.list:chronyd.service
80-systemd-timesyncd.list:systemd-timesyncd.service
```

Timesync detail, when `systemd-timesyncd` is the implementation:

```console
$ timedatectl timesync-status
       Server: 185.125.190.56 (ntp.ubuntu.com)
Poll interval: 34min 8s (min: 32s; max 34min 8s)
         Leap: normal
      Version: 4
      Stratum: 2
    Reference: 91C57A2D
    Precision: 1us (-24)
Root distance: 8.169ms (max: 5s)
       Offset: -1.286ms
        Delay: 12.229ms
       Jitter: 2.267ms
 Packet count: 3
    Frequency: -8.203ppm
```

---

## 6. NTP: protocol and control theory

### 6.1 What one NTP exchange computes

Four timestamps per transaction:

- **T1** — client transmit (client's clock)
- **T2** — server receive (server's clock)
- **T3** — server transmit (server's clock)
- **T4** — client receive (client's clock)

```
offset θ = ((T2 − T1) + (T3 − T4)) / 2
delay  δ =  (T4 − T1) − (T3 − T2)
```

The critical assumption: **δ is split evenly between the two directions.** Path asymmetry maps directly into offset error at half the asymmetry. This is why NTP over a congested or asymmetric WAN link (or across an SD-WAN that routes differently per direction) plateaus at millisecond accuracy while a LAN reaches tens of microseconds, and why sub-microsecond requirements need PTP with hardware timestamping (§9).

Then, per source, the daemon maintains:

| Quantity | Meaning | Where you see it |
|---|---|---|
| **Stratum** | Hops from a reference clock. Stratum 0 = the physical reference (GPS, caesium); stratum 1 = directly attached; **stratum 16 = unsynchronised** | `st` in `ntpq -p`, `Stratum` in `chronyc tracking` |
| **Offset** | Estimated error of the local clock vs this source | `offset`, `Last offset` |
| **Delay** | Round-trip time | `delay`, `Root delay` |
| **Dispersion** | Accumulated maximum error, grows between polls | `Root dispersion` |
| **Jitter** | RMS variation of recent offsets | `jitter`, `RMS offset` |
| **Root distance** | `root_delay/2 + root_dispersion` — the *provable* upper bound on error | `Root distance` |
| **Reach** | 8-bit shift register of the last 8 polls, **printed in octal**. `377` = all 8 succeeded | `reach` |

`reach` being octal is a favourite exam and interview detail: `377` octal = `11111111` binary = perfect. `376` means the most recent poll was lost. `0` means never heard from.

**Selection is the whole point.** `ntpd` runs Marzullo's intersection algorithm over the sources' correctness intervals `[θ−λ, θ+λ]`, discards *falsetickers* whose interval does not overlap the majority, then clusters the survivors. This is why the classic rule is:

| Sources configured | Behaviour |
|---|---|
| **1** | No cross-check. If it lies, you follow it. |
| **2** | Disagreement is detectable but unresolvable — no majority. |
| **3** | One falseticker can be outvoted. Minimum defensible. |
| **4+** | One falseticker outvoted *and* one source may be down simultaneously. **The production standard.** |

### 6.2 Step versus slew — the fundamental trade-off

| | **Step** (`settimeofday`/`clock_settime`) | **Slew** (`adjtimex` frequency correction) |
|---|---|---|
| Mechanism | Discontinuous jump | Run the clock 1–8% fast/slow until converged |
| `CLOCK_REALTIME` monotonicity | **Violated** | Preserved |
| Speed | Instant | `ntpd`: 500 ppm max → **2000 s per second of error**. `chronyd`: default `maxslewrate 83333.333` ppm → ~12 s per second of error |
| Safe on a running system | **No** — breaks in-flight timeouts, DB transactions, file mtimes | Yes |
| Safe at boot / before workload | Yes | Unnecessarily slow |

The engineering rule: **step early and only once, then slew forever.**

- `ntpd` steps if the offset exceeds **128 ms**; if it exceeds **1000 s** it logs a panic and exits unless started with `-g` (allow one big step at start) or configured with `tinker panic 0`.
- `chronyd`'s `makestep <threshold> <limit>` directive is the modern, explicit form: `makestep 1.0 3` = "step if the offset exceeds 1 s, but only during the first 3 clock updates; after that, always slew."

A node that has been powered off for a month will boot with an enormous offset. `makestep 1.0 3` corrects it instantly *before* workload starts, then never steps again. `makestep 1.0 -1` (step at any time) is a footgun on production nodes and should only be used on hardware with no RTC at all.

### 6.3 Implementation comparison

| | **chrony** (`chronyd`/`chronyc`) | **ntpd** (reference impl.) | **systemd-timesyncd** | **ntpdate** / `sntp` | **linuxptp** (`ptp4l`/`phc2sys`) |
|---|---|---|---|---|---|
| Role | Client + server | Client + server + peer | **Client only (SNTP)** | One-shot client | PTP client/server |
| Algorithm | Linear regression over a sample window | PLL/FLL | Simple SNTP | None | BMCA + servo |
| Accuracy, LAN | **tens of µs** | ~100 µs–1 ms | ~ms | seconds | **sub-µs (HW timestamping)** |
| Converges after cold start | **seconds** (`iburst` + `makestep`) | ~15–20 min | minutes | instant (unsafe step) | seconds |
| Handles intermittent network | **Yes** — designed for it | Poorly | Poorly | N/A | No |
| Handles virtual machines / unstable clocks | **Yes** | Poorly | Poorly | N/A | With `ptp_kvm` |
| Serves time to others | Yes | Yes | **No** | No | Yes (PTP only) |
| NTS (RFC 8915) support | **Yes** | No | No | No | N/A |
| Leap smearing | **Yes** (`smoothtime`) | Server-side only | No | No | N/A |
| Memory footprint | ~2 MB | ~4 MB | ~1 MB | — | ~2 MB |
| Default on | RHEL/Fedora/SUSE, Ubuntu Server (chrony pkg) | Legacy installs | Ubuntu Desktop, minimal systemd images | — | Telco/finance |
| Status | **Recommended default** | Maintained; use only if you need broadcast/multicast/autokey/interleaved symmetric modes | Acceptable for laptops/appliances; **not for fleets** | **Deprecated** — do not use | Required for <1 ms |

**Recommendation for any new build: `chrony`.** The decisive properties are cold-start convergence in seconds (matters for autoscaling nodes and short-lived VMs), correct behaviour across suspend/migration, and NTS.

`systemd-timesyncd` disqualifies itself for fleets on one point: it is an **SNTP** client that talks to **one server at a time**. There is no selection algorithm, so there is no falseticker protection. It is a reasonable default for a laptop and the wrong choice for a database node.

`ntpdate` is deprecated upstream. Its replacements are `sntp -s <server>` (one-shot step) or, better, `chronyd -q 'server <host> iburst'` (one-shot set and exit) / `chronyd -Q 'server <host> iburst'` (**measure and print only, never set** — the safe form for monitoring, see §11.3).

### 6.4 `pool.ntp.org`

The NTP Pool is a volunteer DNS round-robin. `0.pool.ntp.org` resolves to a *different* rotating set of addresses on each lookup:

```console
$ dig +short 0.pool.ntp.org
162.159.200.123
185.125.190.56
193.182.111.14
94.130.49.186

$ dig +short 0.pool.ntp.org
216.239.35.0
5.75.181.19
88.99.75.198
162.159.200.1
```

Operational rules that follow from that design:

1. **Use the numbered subdomains `0.`–`3.`**, not bare `pool.ntp.org` four times. Each numbered zone draws from a distinct slice, so you get four genuinely independent servers instead of four possibly-identical ones.
2. **Use your vendor/country zone** when your distribution provides one: `0.debian.pool.ntp.org`, `0.rhel.pool.ntp.org`, `0.es.pool.ntp.org`. Vendor zones exist so pool operators can measure and manage load per distribution; using them is expected etiquette.
3. **Prefer `pool` over `server` in `chrony.conf`.** The `pool` directive resolves the name to *multiple* addresses and maintains a target count, replacing sources that go bad. `server` binds to one address for the daemon's lifetime.
4. **Never point a whole datacentre at the public pool.** Run 2–4 internal stratum-2 servers that sync upward to the pool (or to a GPS appliance), and point every other node at those. This bounds egress, keeps time consistent *within* your failure domain, and works during an internet partition.
5. **In a cloud, prefer the provider's link-local service.** It is free, off the internet path, and leap-smeared consistently:

| Provider | Endpoint |
|---|---|
| AWS | `169.254.169.123` (also `fd00:ec2::123`) |
| GCP | `metadata.google.internal` / `169.254.169.254` |
| Azure | PTP via `/dev/ptp_hyperv` (preferred), or `time.windows.com` |
| Oracle OCI | `169.254.169.254` |

### 6.5 Source-topology trade-offs

| Topology | Accuracy | Blast radius of one bad source | Internet dependency | Cost |
|---|---|---|---|---|
| Every node → public pool | 1–50 ms | Low (per-node) | **Total** | Free, antisocial at scale |
| Every node → cloud link-local | 0.1–1 ms | Low | None | Free |
| Internal stratum-2 tier → pool/cloud | 0.05–1 ms | **Medium — a bad internal server poisons its clients** | Only at the tier | Low |
| Internal tier → GPS/GNSS appliance | 10–100 µs | Medium | **None** | Hardware + antenna + roof access |
| PTP with HW-timestamped switches | **<1 µs** | Medium | None | High — switch and NIC requirements |

Choose by requirement, honestly: financial trade reporting (MiFID II) and distributed databases with bounded-uncertainty clocks need the bottom rows; almost everything else is correct at the second row.

---

## 7. Configuration — complete, production-ready files

### 7.1 `/etc/chrony/chrony.conf` (Debian) / `/etc/chrony.conf` (RHEL)

```conf
# /etc/chrony.conf — production node profile
# Managed by Ansible. Local edits will be overwritten.

#------------------------------------------------------------------------------
# Time sources
#------------------------------------------------------------------------------
# Internal stratum-2 tier. 'pool' maintains `maxsources` usable sources from the
# resolved address set and replaces sources that become unreachable or falsetick.
pool ntp.internal.example.net    iburst maxsources 4 maxpoll 10

# Fallback to the vendor pool zone if the internal tier is unreachable.
# 'offline' + chronyc online/offline can gate these; here we simply deprioritise
# by giving the internal tier a stratum advantage upstream.
pool 2.debian.pool.ntp.org       iburst maxsources 2 maxpoll 10

# Network Time Security (RFC 8915) — authenticated, unspoofable, over TCP/4460
# for key establishment then authenticated NTP over UDP/123.
server time.cloudflare.com       iburst nts

#------------------------------------------------------------------------------
# Clock discipline
#------------------------------------------------------------------------------
# Step (rather than slew) if the offset exceeds 1 s, but ONLY within the first
# 3 clock updates after chronyd starts. After that, always slew: a running
# workload must never observe a CLOCK_REALTIME discontinuity.
makestep 1.0 3

# Cap slew rate so a large correction cannot distort measured durations by more
# than ~1.2%. Default is 83333.333 ppm; 25000 ppm = 2.5%.
maxslewrate 25000

# Refuse to accept a sample from a source whose root distance exceeds 3 s.
maxdistance 3.0

# Reject any single sample implying a step larger than 5 s after the first hour
# of uptime — protects against a source that suddenly starts lying.
maxchange 5 1 0

# Persist the measured frequency error so a restart does not have to relearn it.
driftfile /var/lib/chrony/chrony.drift

# Persist per-source measurement history across restarts (fast reconvergence).
dumpdir /var/lib/chrony

#------------------------------------------------------------------------------
# Hardware clock
#------------------------------------------------------------------------------
# Track RTC drift and correct the RTC at shutdown. rtcsync (kernel 11-minute
# mode) and rtcfile are mutually exclusive — pick one.
rtcsync

# The RTC is UTC. Never LOCAL on a server.
# (chrony reads /etc/adjtime; this directive is for systems without one.)
# rtconutc

#------------------------------------------------------------------------------
# Leap seconds
#------------------------------------------------------------------------------
# Use the leap-second table shipped with tzdata rather than trusting the
# server's leap indicator bits, and SLEW through the leap instead of stepping.
leapsectz right/UTC
leapsecmode slew

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
logdir /var/log/chrony
log tracking measurements statistics

# Log a syslog message whenever the system clock is corrected by more than 0.5 s.
logchange 0.5

#------------------------------------------------------------------------------
# Access control — this node is a CLIENT ONLY
#------------------------------------------------------------------------------
# No 'allow' directive at all => serve nobody. Explicit and default-deny.
# Do not log client accesses (there are none) — saves memory.
noclientlog

# Disable the command port entirely; chronyc still works over the Unix socket
# at /var/run/chrony/chronyd.sock for local root.
cmdport 0

# Bind only to the management interface if this node is multi-homed.
# bindaddress 10.20.0.15

#------------------------------------------------------------------------------
# Hardening
#------------------------------------------------------------------------------
# Drop privileges after binding.
user _chrony

# Rate-limit responses if this ever becomes a server (defence in depth).
ratelimit interval 3 burst 8
```

The **internal stratum-2 server** profile differs only in the access-control block:

```conf
# /etc/chrony.conf — internal stratum-2 server profile

pool 0.debian.pool.ntp.org iburst maxsources 3
pool 1.debian.pool.ntp.org iburst maxsources 3
server 169.254.169.123     iburst prefer          # cloud link-local, if present

makestep 1.0 3
maxslewrate 25000
driftfile /var/lib/chrony/chrony.drift
rtcsync
leapsectz right/UTC

# Serve time to the internal networks ONLY.
allow 10.0.0.0/8
allow 172.16.0.0/12
allow 192.168.0.0/16
deny  all

# Keep serving from the local clock if all upstreams are lost, but advertise a
# high stratum so clients prefer any healthy peer. Only takes effect after the
# clock has been synchronised at least once.
local stratum 10 orphan

# Serve NTS to internal clients.
ntsservercert /etc/pki/tls/certs/ntp.internal.example.net.crt
ntsserverkey  /etc/pki/tls/private/ntp.internal.example.net.key

ratelimit interval 1 burst 16 leak 2
noclientlog
cmdport 0
```

`local stratum 10 orphan` is the directive that prevents a full-fleet time outage during an internet partition: the tier keeps serving a consistent (if unanchored) time, `orphan` ensures exactly one of them wins the election so the tier does not diverge internally.

### 7.2 `/etc/ntp.conf` (reference `ntpd`)

For fleets already standardised on `ntpd`, and because the exam names this file explicitly:

```conf
# /etc/ntp.conf — production node profile (reference ntpd 4.2.8)

#------------------------------------------------------------------------------
# Drift and statistics
#------------------------------------------------------------------------------
driftfile /var/lib/ntp/ntp.drift

statsdir /var/log/ntpstats/
statistics loopstats peerstats clockstats
filegen loopstats file loopstats type day enable
filegen peerstats file peerstats type day enable
filegen clockstats file clockstats type day enable

#------------------------------------------------------------------------------
# Time sources — 'pool' expands to multiple associations; four independent
# numbered zones so falseticker detection has a real majority to work with.
#------------------------------------------------------------------------------
pool 0.debian.pool.ntp.org iburst
pool 1.debian.pool.ntp.org iburst
pool 2.debian.pool.ntp.org iburst
pool 3.debian.pool.ntp.org iburst

# Internal tier, preferred.
server ntp1.internal.example.net iburst prefer
server ntp2.internal.example.net iburst

# Poll bounds: 2^6 = 64 s minimum, 2^10 = 1024 s maximum.
tinker panic 0          # do NOT exit on a >1000 s offset; step it instead
                        # (only safe when combined with -g and a trusted source)

#------------------------------------------------------------------------------
# Access control — RFC 5905 / CVE-2013-5211 hardening
#------------------------------------------------------------------------------
# Default: reply to time queries only. No mode 6/7 control queries, no peering,
# no trap service, rate-limited, kiss-o'-death on abuse.
restrict default kod nomodify notrap nopeer noquery limited
restrict -6 default kod nomodify notrap nopeer noquery limited

# Localhost may query and control.
restrict 127.0.0.1
restrict ::1

# Internal management subnet may query status but not modify.
restrict 10.20.0.0 mask 255.255.0.0 nomodify notrap nopeer

# Explicitly disable the monlist/mode-7 interface — the NTP reflection
# amplification vector (amplification factor up to ~550x).
disable monitor

#------------------------------------------------------------------------------
# Local clock fallback — DO NOT use the legacy 127.127.1.0 undisciplined-local
# refclock on a modern system; it announces stratum 10 unconditionally and
# will poison clients. Use 'orphan' mode instead.
#------------------------------------------------------------------------------
tos orphan 10

# Bind only where needed.
interface ignore wildcard
interface listen 10.20.0.15
interface listen 127.0.0.1
```

Two lines carry disproportionate security weight: **`restrict default ... noquery`** and **`disable monitor`**. Together they close CVE-2013-5211, the `monlist` DDoS reflection vector that made unpatched `ntpd` one of the largest amplification sources on the internet.

### 7.3 `/etc/systemd/timesyncd.conf`

```ini
# /etc/systemd/timesyncd.conf
# Acceptable for appliances and workstations. NOT for fleet nodes:
# timesyncd is SNTP, talks to one server at a time, and has no
# falseticker-selection algorithm.

[Time]
NTP=ntp1.internal.example.net ntp2.internal.example.net
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org

# Poll interval bounds, seconds.
PollIntervalMinSec=32
PollIntervalMaxSec=2048

# Refuse a source whose root distance exceeds this.
RootDistanceMaxSec=5

# Save the last known good time so a machine without an RTC does not boot in 1970.
SaveIntervalSec=60

# Connection retry backoff.
ConnectionRetrySec=30
```

### 7.4 Boot ordering: services that must not start before the clock is right

A certificate-validating service that starts before the clock is disciplined will reject valid certificates and crash-loop. systemd provides the synchronisation point:

```ini
# /etc/systemd/system/my-tls-service.service.d/10-require-time-sync.conf
[Unit]
After=time-sync.target
Wants=time-sync.target
```

`time-sync.target` is only reached once a *time-wait* unit says so. Enable the matching one:

```console
# systemctl enable --now systemd-time-wait-sync.service    # with timesyncd
# systemctl enable --now chrony-wait.service               # with chrony
```

```console
$ systemctl cat chrony-wait.service
# /lib/systemd/system/chrony-wait.service
[Unit]
Description=Wait for chrony to synchronise system clock
After=chrony.service
Requires=chrony.service
Before=time-sync.target
Wants=time-sync.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/chronyc -h 127.0.0.1,/run/chrony/chronyd.sock waitsync 180 0.1
TimeoutStartSec=180

[Install]
WantedBy=sysinit.target
```

`chronyc waitsync 180 0.1` blocks until the root distance is under 0.1 s or 180 s elapse. Wire it into your image build for any node that runs TLS-terminating or Kerberised workloads.

---

## 8. Infrastructure as code

### 8.1 Ansible role — full playbook

```yaml
---
# playbooks/time.yml
# Converge system time configuration across the fleet.
# Run: ansible-playbook -i inventories/prod playbooks/time.yml
- name: Enforce UTC, disciplined clocks and a UTC RTC on all nodes
  hosts: all
  become: true

  vars:
    time_timezone: "Etc/UTC"
    time_internal_pool: "ntp.internal.example.net"
    time_fallback_pools:
      - "2.debian.pool.ntp.org"
    time_nts_servers:
      - "time.cloudflare.com"
    time_makestep_threshold: 1.0
    time_makestep_limit: 3
    time_max_slew_ppm: 25000
    time_is_ntp_server: false
    time_server_allow_networks:
      - "10.0.0.0/8"
      - "172.16.0.0/12"
      - "192.168.0.0/16"

  handlers:
    - name: restart chronyd
      ansible.builtin.systemd:
        name: "{{ chrony_service }}"
        state: restarted
        daemon_reload: true

  tasks:
    - name: Set distribution-specific facts
      ansible.builtin.set_fact:
        chrony_service: "{{ 'chrony' if ansible_os_family == 'Debian' else 'chronyd' }}"
        chrony_conf: >-
          {{ '/etc/chrony/chrony.conf' if ansible_os_family == 'Debian'
             else '/etc/chrony.conf' }}
        chrony_user: "{{ '_chrony' if ansible_os_family == 'Debian' else 'chrony' }}"

    - name: Remove conflicting time daemons
      ansible.builtin.package:
        name:
          - ntp
          - ntpsec
          - openntpd
        state: absent

    - name: Mask systemd-timesyncd so it cannot race chronyd for the clock
      ansible.builtin.systemd:
        name: systemd-timesyncd.service
        enabled: false
        state: stopped
        masked: true
      failed_when: false

    - name: Install chrony and tzdata
      ansible.builtin.package:
        name:
          - chrony
          - tzdata
        state: present

    - name: Set the system timezone
      community.general.timezone:
        name: "{{ time_timezone }}"
      notify: restart chronyd

    - name: Assert the RTC is interpreted as UTC
      ansible.builtin.lineinfile:
        path: /etc/adjtime
        regexp: '^(UTC|LOCAL)$'
        line: 'UTC'
        create: false
      register: adjtime_fixed
      failed_when: false

    - name: Force RTC to UTC via timedatectl when /etc/adjtime disagreed
      ansible.builtin.command:
        cmd: timedatectl set-local-rtc 0 --adjust-system-clock
      when: adjtime_fixed is changed
      changed_when: true

    - name: Deploy chrony configuration
      ansible.builtin.template:
        src: chrony.conf.j2
        dest: "{{ chrony_conf }}"
        owner: root
        group: root
        mode: '0644'
        validate: '/usr/sbin/chronyd -f %s -p'
      notify: restart chronyd

    - name: Enable and start chronyd
      ansible.builtin.systemd:
        name: "{{ chrony_service }}"
        enabled: true
        state: started
        daemon_reload: true

    - name: Wait for the clock to synchronise within 100 ms
      ansible.builtin.command:
        cmd: chronyc waitsync 60 0.1
      changed_when: false
      register: waitsync
      failed_when: waitsync.rc != 0

    - name: Collect tracking data for assertion
      ansible.builtin.command:
        cmd: chronyc -c tracking
      changed_when: false
      register: tracking

    - name: Assert the residual offset is under 50 ms
      ansible.builtin.assert:
        that:
          - (tracking.stdout.split(',')[4] | float) | abs < 0.050
        fail_msg: >-
          Clock offset {{ tracking.stdout.split(',')[4] }}s exceeds 50ms
          on {{ inventory_hostname }}
        success_msg: "Clock disciplined: offset {{ tracking.stdout.split(',')[4] }}s"

    - name: Assert timedatectl reports a sane state
      ansible.builtin.command:
        cmd: timedatectl show --property=NTPSynchronized --property=LocalRTC --value
      changed_when: false
      register: tdc
      failed_when: >-
        tdc.stdout_lines[0] != 'yes' or tdc.stdout_lines[1] != 'no'
```

`validate: '/usr/sbin/chronyd -f %s -p'` is the line that earns its keep: `chronyd -p` parses the config and exits without touching the clock, so a syntax error is caught at template-render time instead of at handler-restart time on 400 nodes.

### 8.2 `templates/chrony.conf.j2`

```jinja
# {{ ansible_managed }}
# Rendered for {{ inventory_hostname }} ({{ ansible_distribution }} {{ ansible_distribution_version }})

pool {{ time_internal_pool }} iburst maxsources 4 maxpoll 10
{% for p in time_fallback_pools %}
pool {{ p }} iburst maxsources 2 maxpoll 10
{% endfor %}
{% for s in time_nts_servers %}
server {{ s }} iburst nts
{% endfor %}
{% if ansible_virtualization_role == 'guest' and ansible_virtualization_type == 'kvm' %}

# PTP hardware clock exposed by the KVM host via ptp_kvm: a local, network-free
# reference two orders of magnitude better than any NTP source.
refclock PHC /dev/ptp_kvm poll 2 dpoll -2 offset 0 stratum 2
{% endif %}

makestep {{ time_makestep_threshold }} {{ time_makestep_limit }}
maxslewrate {{ time_max_slew_ppm }}
maxdistance 3.0
maxchange 5 1 0
driftfile /var/lib/chrony/chrony.drift
dumpdir /var/lib/chrony
rtcsync
leapsectz right/UTC
leapsecmode slew

logdir /var/log/chrony
log tracking measurements statistics
logchange 0.5

user {{ chrony_user }}

{% if time_is_ntp_server %}
{% for net in time_server_allow_networks %}
allow {{ net }}
{% endfor %}
deny all
local stratum 10 orphan
ratelimit interval 1 burst 16 leak 2
{% else %}
# Client only: no allow directives, serve nobody.
cmdport 0
{% endif %}
noclientlog
```

### 8.3 Prometheus alerting rules

```yaml
# /etc/prometheus/rules/time-sync.yml
# Requires node_exporter with the (default-enabled) 'timex' collector.
groups:
  - name: node-time-sync
    interval: 30s
    rules:

      # ----------------------------------------------------------------------
      # Recording rules
      # ----------------------------------------------------------------------
      - record: instance:node_clock_offset_seconds:abs
        expr: abs(node_timex_offset_seconds)

      # Worst pairwise skew across the fleet: the number that actually breaks
      # Raft, LWW and Kerberos. A fleet can be uniformly 400 ms off UTC and
      # still be internally consistent; it cannot survive nodes 400 ms apart.
      - record: fleet:node_clock_pairwise_skew_seconds:max
        expr: >
          max(node_timex_offset_seconds) - min(node_timex_offset_seconds)

      # ----------------------------------------------------------------------
      # Alerts
      # ----------------------------------------------------------------------
      - alert: NodeClockNotSynchronising
        expr: >
          min_over_time(node_timex_sync_status[5m]) == 0
          and
          node_timex_maxerror_seconds >= 16
        for: 10m
        labels:
          severity: warning
          runbook: time-sync
        annotations:
          summary: "Clock not synchronising on {{ $labels.instance }}"
          description: >-
            The kernel reports STA_UNSYNC and maxerror has reached its 16s
            ceiling. chronyd/ntpd is not disciplining the clock. The node will
            drift at its raw crystal rate (typically 2-4 s/day) from here.

      - alert: NodeClockSkewDetected
        expr: >
          (
            node_timex_offset_seconds > 0.05
            and deriv(node_timex_offset_seconds[5m]) >= 0
          )
          or
          (
            node_timex_offset_seconds < -0.05
            and deriv(node_timex_offset_seconds[5m]) <= 0
          )
        for: 10m
        labels:
          severity: warning
          runbook: time-sync
        annotations:
          summary: "Clock skew >50ms and diverging on {{ $labels.instance }}"
          description: >-
            Offset is {{ $value | humanizeDuration }} and moving further from
            zero. Distributed tracing and LWW conflict resolution are already
            affected; Kerberos fails at 300s.

      - alert: NodeClockSkewCritical
        expr: abs(node_timex_offset_seconds) > 30
        for: 2m
        labels:
          severity: critical
          runbook: time-sync
        annotations:
          summary: "Clock off by >30s on {{ $labels.instance }}"
          description: >-
            TOTP/MFA is already failing for this node. Kerberos fails at 300s
            and cloud API SigV4 at 900s.

      - alert: FleetClockDivergence
        expr: fleet:node_clock_pairwise_skew_seconds:max > 0.5
        for: 5m
        labels:
          severity: critical
          runbook: time-sync
        annotations:
          summary: "Fleet nodes disagree by >500ms"
          description: >-
            etcd warns above 1s pairwise difference and leader election starts
            flapping. Check whether a subset of nodes lost its NTP tier.

      - alert: NodeClocksourceDegraded
        expr: node_timex_frequency_adjustment_ratio < 0.9995
              or node_timex_frequency_adjustment_ratio > 1.0005
        for: 30m
        labels:
          severity: info
        annotations:
          summary: "Crystal frequency error >500ppm on {{ $labels.instance }}"
          description: >-
            The kernel is applying an unusually large frequency correction.
            Check `dmesg | grep clocksource` for a TSC demotion, which also
            costs ~30x on every clock_gettime() because the vDSO fast path is
            lost.

      - alert: NodeNTPDaemonDown
        expr: >
          node_systemd_unit_state{name=~"chronyd?\\.service",state="active"} == 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "chronyd is not active on {{ $labels.instance }}"
```

### 8.4 Kubernetes: a clock-skew exporter DaemonSet

Time on a Kubernetes node is a **node-level** concern. A pod cannot and must not set the clock: `CLOCK_REALTIME` is not virtualised by the time namespace (§9.2), and granting `CAP_SYS_TIME` to a container lets it move the *host's* clock. The correct pattern is therefore to **measure from a pod and set from the node's own `chronyd`**.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: node-observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clock-skew-exporter
  namespace: node-observability
data:
  probe.sh: |
    #!/bin/sh
    # Measure the node's clock offset against a reference WITHOUT setting it.
    # `chronyd -Q` performs the NTP exchange, prints the computed offset and
    # exits, never calling adjtimex() or clock_settime(). It therefore needs
    # no CAP_SYS_TIME, which is exactly why it is safe to run in a pod.
    set -eu
    OUT=/textfile/clock_skew.prom
    TMP="${OUT}.$$"
    while true; do
      RAW=$(chronyd -Q -t 10 \
              "server ${NTP_SERVER} iburst maxsamples 4" 2>&1 || true)
      # Expected: "2026-08-27T14:32:05Z System clock wrong by -0.000123 seconds"
      OFFSET=$(printf '%s\n' "$RAW" \
               | sed -n 's/.*System clock wrong by \(-\?[0-9.]*\) seconds.*/\1/p' \
               | head -n1)
      {
        echo '# HELP node_clock_skew_seconds Offset of CLOCK_REALTIME vs the reference NTP server.'
        echo '# TYPE node_clock_skew_seconds gauge'
        if [ -n "${OFFSET}" ]; then
          echo "node_clock_skew_seconds{server=\"${NTP_SERVER}\"} ${OFFSET}"
          echo '# HELP node_clock_probe_success Whether the last SNTP probe succeeded.'
          echo '# TYPE node_clock_probe_success gauge'
          echo "node_clock_probe_success{server=\"${NTP_SERVER}\"} 1"
        else
          echo "node_clock_probe_success{server=\"${NTP_SERVER}\"} 0"
        fi
      } > "${TMP}"
      mv "${TMP}" "${OUT}"          # atomic: the collector never reads a partial file
      sleep "${PROBE_INTERVAL:-60}"
    done
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: clock-skew-exporter
  namespace: node-observability
  labels:
    app.kubernetes.io/name: clock-skew-exporter
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: clock-skew-exporter
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: clock-skew-exporter
    spec:
      # hostNetwork so the probe measures the node's own network path to the
      # NTP tier, not the CNI overlay's.
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists          # must run on every node, including tainted ones
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: probe
          image: cgr.dev/chainguard/chrony:latest
          command: ["/bin/sh", "/etc/probe/probe.sh"]
          env:
            - name: NTP_SERVER
              value: "ntp.internal.example.net"
            - name: PROBE_INTERVAL
              value: "60"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              # NOTE: no CAP_SYS_TIME. The probe measures; it never sets.
          resources:
            requests:
              cpu: 5m
              memory: 16Mi
            limits:
              memory: 32Mi
          volumeMounts:
            - name: probe-script
              mountPath: /etc/probe
              readOnly: true
            - name: textfile
              mountPath: /textfile
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: probe-script
          configMap:
            name: clock-skew-exporter
            defaultMode: 0555
        - name: textfile
          hostPath:
            # Same directory node_exporter is started with:
            #   --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
            path: /var/lib/node_exporter/textfile_collector
            type: DirectoryOrCreate
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 8Mi
```

Two design points worth stating explicitly, because they are the ones reviewers get wrong:

- **`capabilities: drop: ["ALL"]` with no `CAP_SYS_TIME`.** If a manifest asks for `CAP_SYS_TIME`, it is trying to set the host clock from a container. Reject it in admission control:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-sys-time
  annotations:
    policies.kyverno.io/description: >-
      CLOCK_REALTIME is not namespaced. A container holding CAP_SYS_TIME can
      move the clock for every other workload on the node. Time is set by the
      node's chronyd, never by a pod.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: block-cap-sys-time
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "CAP_SYS_TIME is prohibited: the node owns CLOCK_REALTIME."
        foreach:
          - list: "request.object.spec.containers[]"
            deny:
              conditions:
                any:
                  - key: "SYS_TIME"
                    operator: AnyIn
                    value: "{{ element.securityContext.capabilities.add[] || `[]` }}"
```

- **Atomic `mv` into the textfile directory.** `node_exporter`'s textfile collector reads `*.prom` on every scrape; writing in place produces truncated files and a scrape error roughly as often as your scrape interval divides your write interval.

---

## 9. Virtualisation and containers

### 9.1 Guests

A VM's TSC can jump on live migration, pause/resume, or host CPU frequency changes. Consequences and remedies:

| Situation | Remedy |
|---|---|
| KVM guest | Use `kvm-clock` (default). The host propagates its discipline. Still run `chronyd` in the guest for the residual. |
| KVM guest, high accuracy | `refclock PHC /dev/ptp_kvm poll 2 dpoll -2 offset 0` — reads the host clock over a paravirtual PTP channel, no network involved. Requires the `ptp_kvm` module. |
| Hyper-V / Azure | `refclock PHC /dev/ptp_hyperv poll 3 dpoll -2 offset 0` |
| VMware | Disable VMware Tools time sync **or** disable `chronyd` — never both, they fight and the clock oscillates. Current guidance is to prefer in-guest NTP. |
| Live migration | `chronyd` recovers automatically; `ntpd` frequently needs a restart. |

```console
# modprobe ptp_kvm
# ls -l /dev/ptp*
crw------- 1 root root 249, 0 Aug 27 14:30 /dev/ptp0
# grep -H . /sys/class/ptp/ptp0/clock_name
/sys/class/ptp/ptp0/clock_name:KVM virtual PTP
```

### 9.2 Containers — the time namespace does not do what people assume

Linux 5.6 added `CLONE_NEWTIME`. It virtualises **only `CLOCK_MONOTONIC` and `CLOCK_BOOTTIME`** (via per-namespace offsets in `/proc/<pid>/timens_offsets`). **`CLOCK_REALTIME` is deliberately excluded** and is global to the host.

Therefore:

- A container **cannot** have its own wall-clock time. Full stop.
- A container that appears to have the wrong time has the wrong *timezone*, not the wrong clock. Fix it by setting `TZ` or mounting `/etc/localtime` — never by trying to set the clock.
- Running an NTP daemon inside a container is an anti-pattern: with `CAP_SYS_TIME` it silently reconfigures the host; without it, it fails.

```console
$ docker run --rm alpine date -s "2020-01-01"
date: can't set date: Operation not permitted

$ docker run --rm alpine date
Thu Aug 27 14:32:05 UTC 2026

$ docker run --rm -e TZ=Europe/Madrid alpine sh -c 'apk add -q tzdata; date'
Thu Aug 27 16:32:05 CEST 2026

$ docker run --rm -v /etc/localtime:/etc/localtime:ro alpine date
Thu Aug 27 14:32:05 UTC 2026
```

The Kubernetes-idiomatic form:

```yaml
spec:
  containers:
    - name: app
      image: registry.example.net/app:1.4.2
      env:
        - name: TZ
          value: "Etc/UTC"        # explicit; never rely on the image default
```

### 9.3 Leap seconds

A positive leap second inserts `23:59:60 UTC`. UNIX time has no representation for it, so the kernel must either repeat a second or slow down.

| Strategy | Behaviour | Where |
|---|---|---|
| **Step (kernel default)** | `CLOCK_REALTIME` repeats the last second — time goes *backwards* by 1 s | Historically caused the 2012 and 2015 Linux hangs (`hrtimer` livelock) |
| **Slew** (`leapsecmode slew`) | Client absorbs the second over ~12 s at the max slew rate | chrony client-side |
| **Smear** (`smoothtime`) | Server distributes the second over 24 h (typically noon-to-noon UTC), ~11.6 ppm frequency error | Google, AWS (`169.254.169.123`), Cloudflare |

**The one rule that matters: never mix smeared and non-smeared sources.** During a smear they disagree by up to 0.5 s, which reads as a falseticker to the selection algorithm and can leave a node with no usable source at all. If you use AWS Time Sync, use it exclusively — do not add `pool.ntp.org` as a fallback in the same `chrony.conf`.

```conf
# Internal server that smears for its clients (server side only):
smoothtime 400 0.001 leaponly
leapsecmode slew
maxslewrate 1000
```

Note for currency: the CGPM resolved in 2022 to stop inserting leap seconds by or before 2035. Systems built today will still outlive at least the transition; the smearing configuration remains the safe default.

---

## 10. Security

### 10.1 Threat model

Unauthenticated NTP is a **time-shifting attack primitive**. An on-path attacker who can move a target's clock forward can make expired certificates valid again, replay revoked credentials past their CRL window, or expire a valid session. Moving it backward stalls TOTP and can defeat HSTS.

| Control | Protects against | Cost |
|---|---|---|
| Multiple independent sources (≥4) | A single lying server | Free |
| `maxchange 5 1 0` (chrony) | Slow-boil offset injection | Free |
| **NTS (RFC 8915)** | On-path modification and spoofing | TLS handshake on TCP/4460; near-zero steady state |
| Symmetric keys (`keyfile`/`ntp.keys`) | Same, for internal tiers | Key distribution burden |
| `restrict ... noquery` + `disable monitor` (ntpd) | Being an amplification reflector | Free |
| `cmdport 0` / `noclientlog` (chrony) | Same | Free |
| Firewall UDP/123 egress to the internal tier only | Nodes bypassing the tier | Free |

### 10.2 NTS in practice

```console
# chronyc -N authdata
Name/IP address             Mode KeyID Type KLen Last Atmp  NAK Cook CLen
=========================================================================
time.cloudflare.com          NTS     1   15  256   55m    0    0    8  100
ntp1.internal.example.net    NTS     1   15  256   17m    0    0    8  100
ntp2.internal.example.net     -      0    0    0     -    0    0    0    0
```

`Mode NTS`, `KLen 256`, `Cook 8` (eight unused cookies in hand) is a healthy NTS association. `NAK` climbing means key-establishment failures — usually an expired server certificate or a middlebox on TCP/4460.

### 10.3 Verify you are not a reflector

```console
$ ntpdc -n -c monlist 203.0.113.10
203.0.113.10: timed out, nothing received
***Request timed out

$ ntpq -c "rv 0" 203.0.113.10
203.0.113.10: timed out, nothing received
***Request timed out
```

Both timing out from an external host is the desired result. If `monlist` returns hundreds of lines, that server is an active DDoS amplifier — fix it now.

---

## 11. Verification and failure diagnosis

### 11.1 The 60-second triage

Run this block on any node suspected of a time problem. It is ordered so the first failing line names the layer.

```bash
#!/usr/bin/env bash
# time-triage.sh — read top to bottom; the first anomaly is the cause.
set -uo pipefail

echo "=== 1. Consensus view ==="
timedatectl

echo -e "\n=== 2. Is a disciplinarian running? ==="
systemctl is-active chronyd chrony ntpd ntpsec systemd-timesyncd 2>/dev/null \
  | paste -d' ' <(echo -e "chronyd\nchrony\nntpd\nntpsec\ntimesyncd") -

echo -e "\n=== 3. Kernel discipline state (authoritative) ==="
adjtimex --print | grep -E 'status|offset|frequency|maxerror|return value'

echo -e "\n=== 4. RTC convention (must be UTC on a server) ==="
cat /etc/adjtime 2>/dev/null || echo "no /etc/adjtime (implies UTC)"

echo -e "\n=== 5. Timezone resolution ==="
ls -l /etc/localtime
cat /etc/timezone 2>/dev/null || true
echo "TZ=${TZ:-<unset>}"

echo -e "\n=== 6. Clocksource (performance, not correctness) ==="
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
dmesg 2>/dev/null | grep -i 'switched to clocksource' | tail -3

echo -e "\n=== 7. Source health ==="
command -v chronyc >/dev/null && { chronyc tracking; echo; chronyc -n sources -v; }
command -v ntpq   >/dev/null && ntpq -pn

echo -e "\n=== 8. Can we even reach UDP/123? ==="
timeout 5 chronyd -Q -t 4 'server ntp.internal.example.net iburst' 2>&1 \
  || echo "PROBE FAILED"

echo -e "\n=== 9. RTC vs system delta ==="
printf 'system: %s\nrtc:    %s\n' \
  "$(date -u +%FT%TZ)" "$(hwclock --show --utc 2>/dev/null || echo 'n/a')"
```

### 11.2 Symptom → cause → fix

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| `System clock synchronized: no` | No daemon running, or all sources unreachable | `systemctl is-active chronyd`; `chronyc sources` | Start the daemon; check UDP/123 egress |
| `NTP service: n/a` | No unit registered in `/usr/lib/systemd/ntp-units.d/` | `ls /usr/lib/systemd/ntp-units.d/` | Install chrony |
| Two daemons installed | `systemd-timesyncd` and `chronyd` both enabled, fighting for the clock | `systemctl is-active systemd-timesyncd chronyd` | `systemctl mask --now systemd-timesyncd` |
| All sources show `Reach 0` | Firewall blocks UDP/123, or DNS fails | `chronyc -n sources`; `ss -ulpn \| grep 123`; `dig +short 0.pool.ntp.org` | Open UDP/123 egress; fix resolver |
| Sources reach `377` but state is `?` or `x` | Root distance above `maxdistance`, or falseticker | `chronyc sourcestats`; `chronyc ntpdata <src>` | Add more independent sources; check for a smeared/non-smeared mix |
| Offset large and **stable** | Daemon is slewing at max rate; be patient | `chronyc tracking` twice, 60 s apart | Wait, or `chronyc makestep` **only if no workload is running** |
| Offset large and **growing** | Not disciplined at all; raw crystal drift | `adjtimex --print` → `status` has `0x40` set | Restart daemon; check `maxchange`/`maxdistance` rejections in the log |
| Time correct, but timestamps show the wrong hour | Timezone, not clock | `date -u` vs `date` | Fix `/etc/localtime` or `TZ` |
| Time is exactly ±1 h off after a reboot | RTC in LOCAL during a DST transition | `tail -1 /etc/adjtime` | `timedatectl set-local-rtc 0 --adjust-system-clock` |
| Time is exactly ±N h off on a VM | Host and guest disagree on RTC convention | `hwclock --show` vs `date -u` | Set the hypervisor's RTC to UTC |
| Clock right, but p99 latency tripled | TSC demoted to HPET | `dmesg \| grep clocksource` | Investigate the host; `tsc=reliable` only with vendor confirmation |
| Correct on reboot, wrong after 3 days | RTC good, no NTP running | `chronyc tracking` fails | Install and enable chrony |
| Wrong immediately on every boot, correct after 5 min | RTC battery dead | `hwclock --show` at boot vs after sync | Replace the CMOS battery; add `chrony-wait.service` |
| Kerberos `Clock skew too great` | Offset > 300 s | `ntpq -p` / `chronyc tracking` on **both** ends | Sync both; check the KDC's own clock |
| `RequestTimeTooSkewed` from a cloud API | Offset > 900 s | `date -u` vs `curl -sI https://s3.amazonaws.com \| grep -i ^date` | Sync |
| etcd leader flapping | Pairwise node skew > 1 s | `fleet:node_clock_pairwise_skew_seconds:max` | Point all etcd members at the *same* NTP tier |

### 11.3 Non-destructive offset measurement

The most useful trick in this topic: measure without setting.

```console
# chronyd -Q -t 10 'server ntp.internal.example.net iburst'
2026-08-27T14:32:05Z chronyd version 4.3 starting (+CMDMON +NTP +REFCLOCK +RTC +PRIVDROP +SCFILTER +SIGND +ASYNCDNS +NTS +SECHASH +IPV6 -DEBUG)
2026-08-27T14:32:09Z System clock wrong by -0.000418 seconds (ignored)
2026-08-27T14:32:09Z chronyd exiting
```

`-Q` is read-only: no `adjtimex`, no `clock_settime`, no `CAP_SYS_TIME` needed. `-q` is the same measurement but **does** set the clock once and exit — the modern `ntpdate` replacement. Learn the case distinction; using `-q` where you meant `-Q` steps a production clock.

The `ntpsec`/`ntpd` equivalent:

```console
$ sntp -d ntp.internal.example.net
sntp 4.2.8p15@1.3728-o Mon Feb  1 00:00:00 UTC 2021 (1)
2026-08-27 14:32:09.482913 (+0000) -0.000418 +/- 0.004121 ntp.internal.example.net 10.20.0.5 s2 no-leap
```

### 11.4 Reading `chronyc` output

```console
$ chronyc tracking
Reference ID    : 0A140005 (ntp1.internal.example.net)
Stratum         : 3
Ref time (UTC)  : Thu Aug 27 14:29:41 2026
System time     : 0.000012345 seconds slow of NTP time
Last offset     : -0.000005678 seconds
RMS offset      : 0.000041234 seconds
Frequency       : 12.345 ppm slow
Residual freq   : -0.001 ppm
Skew            : 0.087 ppm
Root delay      : 0.012345678 seconds
Root dispersion : 0.001234567 seconds
Update interval : 64.2 seconds
Leap status     : Normal
```

- **`System time`** — current error. This is the number your alerts should watch.
- **`Frequency 12.345 ppm slow`** — the *crystal's* error being compensated. Stable across restarts (persisted in the driftfile). A value above ~100 ppm suggests failing hardware.
- **`Residual freq`** — how much the current frequency estimate still disagrees with the sources. Should trend to ~0. Persistently non-zero means the loop has not converged.
- **`Skew`** — uncertainty in the frequency estimate. Rising skew = degrading sources.
- **`Root delay + Root dispersion`** — the *provable* error bound back to stratum 0. `Root delay/2 + Root dispersion` is the root distance.
- **`Leap status`** — `Normal`, `Insert second`, `Delete second`, or **`Not synchronised`**.

```console
$ chronyc -n sources -v

  .-- Source mode  '^' = server, '=' = peer, '#' = local clock.
 / .- Source state '*' = current best, '+' = combined, '-' = not combined,
| /             'x' = may be in error, '~' = too variable, '?' = unusable.
||                                                 .- xxxx [ yyyy ] +/- zzzz
||      Reachability register (octal) -.           |  xxxx = adjusted offset,
||      Log2(Polling interval) --.      |          |  yyyy = measured offset,
||                                \     |          |  zzzz = estimated error.
||                                 |    |           \
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* 10.20.0.5                     2   6   377    23   -102us[ -119us] +/-   12ms
^+ 10.20.0.6                     2   6   377    27    +214us[ +197us] +/-   14ms
^- 162.159.200.1                 3   6   377    41    -1841us[-1858us] +/-   31ms
^x 203.0.113.44                  2   6   377    19  +48231us[+48214us] +/-   19ms
^? 198.51.100.7                 16   6     0     -     +0ns[   +0ns] +/-    0ns
```

Reading it as an operator:

- `^*` — the **selected** source. Exactly one.
- `^+` — combined into the final estimate. Healthy.
- `^-` — measured but excluded by the combining algorithm (usually higher root distance). Normal.
- `^x` — **falseticker**. Its correctness interval does not overlap the majority. `203.0.113.44` is 48 ms out and correctly quarantined. If you had only *two* sources, chrony could not have made this determination.
- `^?` — unusable. Stratum 16 and `Reach 0` mean never successfully polled.

```console
$ chronyc sourcestats -v
                            .- Number of sample points in measurement set.
                           /    .- Number of residual runs with same sign.
                          |    /    .- Length of measurement set (time).
                          |   |    /      .- Est. clock freq error (ppm).
                          |   |   |      /           .- Est. error in freq.
                          |   |   |     |           /         .- Est. offset.
                          |   |   |     |          |          |   On +/- of
                          |   |   |     |          |          |   sample point
                          |   |   |     |          |          |    |
                          |   |   |     |          |          |    |
Name/IP Address            NP  NR  Span  Frequency  Freq Skew  Offset  Std Dev
==============================================================================
10.20.0.5                  17   9   264     -0.007      0.288    -14us   231us
10.20.0.6                  16  10   249     +0.021      0.412    +198us  387us
162.159.200.1              14   7   198     -0.114      1.982   -1802us  1.4ms
```

`NR` (residual runs) close to `NP/2` indicates a good linear fit. `NR` near 1 or near `NP` means the residuals are systematically signed — the linear model is wrong, usually from asymmetric network delay.

```console
$ chronyc activity
200 OK
4 sources online
0 sources offline
0 sources doing burst (return to online)
0 sources doing burst (return to offline)
0 sources with unknown address

$ chronyc -n ntpdata 10.20.0.5
Remote address  : 10.20.0.5 (0A140005)
Remote port     : 123
Local address   : 10.20.0.15 (0A14000F)
Leap status     : Normal
Version         : 4
Mode            : Server
Stratum         : 2
Poll interval   : 6 (64 seconds)
Precision       : -25 (0.000000030 seconds)
Root delay      : 0.000320 seconds
Root dispersion : 0.000229 seconds
Reference ID    : A9FEA97B ()
Reference time  : Thu Aug 27 14:29:41 2026
Offset          : -0.000102345 seconds
Peer delay      : 0.000412345 seconds
Peer dispersion : 0.000000123 seconds
Response time   : 0.000041234 seconds
Jitter asymmetry: +0.00
NTP tests       : 111 111 1111
Interleaved     : No
Authenticated   : No
TX timestamping : Kernel
RX timestamping : Kernel
Total TX        : 25
Total RX        : 25
Total valid RX  : 25
```

`NTP tests : 111 111 1111` — all ten RFC 5905 packet sanity tests pass. Any `0` names the exact validation that failed; this is the deepest per-packet diagnostic available.

Machine-readable output for scripts and exporters:

```console
$ chronyc -c tracking
0A140005,ntp1.internal.example.net,3,1787840981.4,0.000012345,-0.000005678,0.000041234,12.345,-0.001,0.087,0.012345678,0.001234567,64.2,Normal
```

Fields in order: refid, refname, stratum, ref time, system time offset, last offset, RMS offset, frequency, residual freq, skew, root delay, root dispersion, update interval, leap status.

Runtime control:

```console
# chronyc makestep                  # step NOW — only with no workload running
200 OK

# chronyc waitsync 60 0.1           # block until root distance < 0.1s or 60s
try: 1, refid: 0A140005, correction: 0.000012, skew: 0.087

# chronyc burst 4/4                 # take 4 measurements immediately
200 OK

# chronyc offline / chronyc online  # for intermittently connected hosts
200 OK

# chronyc serverstats               # only meaningful on a server
NTP packets received       : 1245891
NTP packets dropped        : 0
Command packets received   : 421
Command packets dropped    : 0
Client log records dropped : 0
NTS-KE connections accepted: 3121
NTS-KE connections dropped : 0
Authenticated NTP packets  : 1102337
Interleaved NTP packets    : 0
NTP timestamps held        : 0
NTP timestamp span         : 0
```

### 11.5 Reading `ntpq` output

```console
$ ntpq -pn
     remote           refid      st t when poll reach   delay   offset  jitter
==============================================================================
*10.20.0.5       192.36.143.150   2 u   37   64  377   12.345   -0.512   0.234
+10.20.0.6       193.79.237.14    2 u   41   64  377   15.678   +0.891   0.456
-162.159.200.1   130.133.1.10     3 u   30   64  377   28.901   +3.456   1.234
x203.0.113.44    17.253.34.253    2 u   35   64  377   19.204  +48.231   0.612
 198.51.100.7    .INIT.          16 u    -   64    0    0.000    0.000   0.000
```

The tally code in column 1 — the exam asks about this and so does every real incident:

| Code | Name | Meaning |
|---|---|---|
| (space) | reject | Failed sanity checks, or stratum 16 |
| `x` | falsetick | Rejected by the intersection algorithm — **it disagrees with the majority** |
| `.` | excess | Beyond the first 10 sources by synchronisation distance |
| `-` | outlier | Discarded by the clustering algorithm |
| `+` | candidate | Included in the final combine |
| `#` | selected | Good, but not among the top 6 |
| `*` | **sys.peer** | The selected reference. Exactly one. |
| `o` | pps.peer | Selected, with PPS discipline (hardware reference) |

Column semantics: `st` = stratum, `t` = type (`u` unicast, `l` local, `m` multicast, `b` broadcast, `p` pool), `when` = seconds since last reply, `poll` = current poll interval in seconds, `reach` = **octal** shift register, `delay`/`offset`/`jitter` in **milliseconds** (chrony reports seconds — a units mismatch that has caused real misconfigured alerts).

```console
$ ntpq -c 'rv 0'
associd=0 status=0615 leap_none, sync_ntp, 1 event, clock_sync,
version="ntpd 4.2.8p15@1.3728-o Mon Feb  1 00:00:00 UTC 2021 (1)",
processor="x86_64", system="Linux/6.1.0-18-amd64", leap=00, stratum=3,
precision=-24, rootdelay=25.123, rootdisp=45.678, refid=10.20.0.5,
reftime=eb3c9a45.7b2f1c04  Thu, Aug 27 2026 14:29:41.481,
clock=eb3c9ac9.1f8b3d21  Thu, Aug 27 2026 14:32:09.123, peer=34215, tc=6,
mintc=3, offset=-0.512, frequency=-8.203, sys_jitter=0.234,
clk_jitter=0.198, clk_wander=0.012

$ ntpq -c 'as'
ind assid status  conf reach auth condition  last_event cnt
===========================================================
  1 34215  963a   yes   yes  none  sys.peer    sys_peer  3
  2 34216  9324   yes   yes  none  candidate   reachable 2
  3 34217  9024   yes   yes  none  outlier     reachable 2
  4 34218  90fa   yes   yes  none  falsetick   reachable 15
```

`status=0615` decodes to `leap_none, sync_ntp, clock_sync` — synchronised. `status=c016` (`leap_alarm, sync_unspec`) means unsynchronised, and `leap_alarm` is the bit that makes clients refuse this server.

### 11.6 Packet-level

```console
# tcpdump -n -i any -v 'udp port 123' -c 2
tcpdump: listening on any, link-type LINUX_SLL2 (Linux cooked v2), capture size 262144 bytes
14:32:09.482913 IP (tos 0x0, ttl 64, id 0, offset 0, flags [DF], proto UDP (17), length 76)
    10.20.0.15.35123 > 10.20.0.5.123: NTPv4, Client, length 48
        Leap indicator:  (0), Stratum 0 (unspecified), poll 6 (64s), precision -25
        Root Delay: 0.000000, Root dispersion: 0.000000, Reference-ID: (unspec)
          Reference Timestamp:  0.000000000
          Originator Timestamp: 0.000000000
          Receive Timestamp:    0.000000000
          Transmit Timestamp:   3959335929.482913000 (2026-08-27T14:32:09Z)
            Originator - Receive Timestamp:  0.000000000
            Originator - Transmit Timestamp: 3959335929.482913000 (2026-08-27T14:32:09Z)
14:32:09.495241 IP (tos 0x0, ttl 63, id 42311, offset 0, flags [none], proto UDP (17), length 76)
    10.20.0.5.123 > 10.20.0.15.35123: NTPv4, Server, length 48
        Leap indicator:  (0), Stratum 2 (secondary reference), poll 6 (64s), precision -25
        Root Delay: 0.004791, Root dispersion: 0.003448, Reference-ID: 192.36.143.150
          Reference Timestamp:  3959335781.194837000 (2026-08-27T14:29:41Z)
          Originator Timestamp: 3959335929.482913000 (2026-08-27T14:32:09Z)
          Receive Timestamp:    3959335929.489011000 (2026-08-27T14:32:09Z)
          Transmit Timestamp:   3959335929.489102000 (2026-08-27T14:32:09Z)
```

Those are literally T1 (Transmit in the client packet), T2 (Receive), T3 (Transmit in the reply); T4 is the local capture timestamp. You can compute the offset and delay by hand from this capture — a useful exercise when you suspect a middlebox is rewriting timestamps.

If no reply arrives, distinguish "blocked" from "not listening":

```console
$ ss -ulpn | grep :123
UNCONN 0  0    0.0.0.0:123   0.0.0.0:*  users:(("chronyd",pid=821,fd=5))
UNCONN 0  0       [::]:123      [::]:*  users:(("chronyd",pid=821,fd=6))

$ nmap -sU -p 123 --script ntp-info ntp.internal.example.net
PORT    STATE SERVICE
123/udp open  ntp
```

### 11.7 Testing time-dependent code without touching the clock

Never step a shared clock to test an expiry path.

```console
$ faketime '2027-01-01 00:00:00' openssl s_client -connect api.example.net:443 </dev/null 2>&1 | grep -E 'Verify|verify error'
verify error:num=10:certificate has expired
    Verify return code: 10 (certificate has expired)

$ datefudge -s '2026-12-31' date -u
Thu Dec 31 00:00:00 UTC 2026
```

`libfaketime` intercepts `clock_gettime`/`gettimeofday` via `LD_PRELOAD` for that process only. In containers, prefer a `CLONE_NEWTIME` namespace via `unshare --time` for monotonic-clock tests — remembering §9.2: it will not move `CLOCK_REALTIME`.

---

## 12. Exam-facing summary

**Files**

| Path | Purpose |
|---|---|
| `/usr/share/zoneinfo/` | Compiled TZif timezone database |
| `/etc/localtime` | Symlink → the active zone. Consumed by glibc. |
| `/etc/timezone` | Plain-text zone *name* (Debian family). Informational to glibc. |
| `/etc/adjtime` | RTC drift + **`UTC` or `LOCAL`** convention |
| `/etc/ntp.conf` | `ntpd` configuration |
| `/etc/chrony.conf` (RHEL) / `/etc/chrony/chrony.conf` (Debian) | `chronyd` configuration |
| `/etc/systemd/timesyncd.conf` | `systemd-timesyncd` configuration |
| `/var/lib/ntp/ntp.drift`, `/var/lib/chrony/chrony.drift` | Persisted frequency error |
| `/dev/rtc0`, `/sys/class/rtc/rtc0/` | Hardware clock device |

**Commands**

| Command | Purpose |
|---|---|
| `date` | Show/set the system clock; format with `+FMT`; parse with `-d` |
| `hwclock` | Read/write the RTC. `-r` read, `-w`/`--systohc` system→RTC, `-s`/`--hctosys` RTC→system |
| `timedatectl` | systemd front-end: `set-time`, `set-timezone`, `set-ntp`, `set-local-rtc`, `list-timezones`, `timesync-status` |
| `tzselect` | Interactive zone chooser; prints a `TZ` value, changes nothing |
| `zdump -v <zone>` | Dump a zone's DST transitions |
| `ntpd` | Reference NTP daemon |
| `ntpq -p` | **Query NTP peers** — the objective explicitly requires awareness of this |
| `ntpdate` | Deprecated one-shot sync. Replaced by `sntp -s` / `chronyd -q` |
| `sntp` | Modern one-shot SNTP client |
| `chronyd` | chrony daemon. `-q` set-once-and-exit, **`-Q` measure-only**, `-p` config check |
| `chronyc` | chrony control: `tracking`, `sources -v`, `sourcestats`, `activity`, `ntpdata`, `makestep`, `waitsync`, `authdata` |
| `adjtimex` | Read/set kernel NTP discipline variables directly |

**Concepts most often tested**

- **Stratum 16 = unsynchronised.** Stratum 0 is a physical reference, not a server.
- **`reach` is octal; `377` is perfect.**
- **`*` in `ntpq -p` is the selected peer; `x` is a falseticker.**
- **The RTC has no timezone** — `/etc/adjtime` line 3 supplies the convention.
- **`pool.ntp.org` is DNS round-robin**; use `0.`–`3.` or a vendor zone, and four or more sources.
- **`--systohc` writes to hardware; `--hctosys` writes to the system.**
- **`timedatectl set-time` is refused while `set-ntp` is on.**

**The three assertions a production node must satisfy**

```console
$ timedatectl show --property=NTPSynchronized --property=LocalRTC --property=Timezone --value
yes
no
Etc/UTC
```

---

## 13. Referencias

**LPI**

- LPIC-1 Exam 101-500 objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102-500 objectives — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Standards**

- RFC 5905 — Network Time Protocol Version 4: Protocol and Algorithms Specification — https://www.rfc-editor.org/rfc/rfc5905
- RFC 5906 — Network Time Protocol Version 4: Autokey Specification — https://www.rfc-editor.org/rfc/rfc5906
- RFC 8915 — Network Time Security for the Network Time Protocol — https://www.rfc-editor.org/rfc/rfc8915
- RFC 6238 — TOTP: Time-Based One-Time Password Algorithm — https://www.rfc-editor.org/rfc/rfc6238
- IEEE 1588 (PTP) overview — https://standards.ieee.org/ieee/1588/6825/
- POSIX `TZ` environment variable, Base Definitions ch. 8 — https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html

**Timezone data**

- IANA Time Zone Database — https://www.iana.org/time-zones
- `tzdb` theory and pragmatics (`theory.html`) — https://data.iana.org/time-zones/theory.html

**chrony**

- chrony documentation index — https://chrony-project.org/documentation.html
- `chrony.conf(5)` — https://chrony-project.org/doc/4.6/chrony.conf.html
- `chronyc(1)` — https://chrony-project.org/doc/4.6/chronyc.html
- `chronyd(8)` — https://chrony-project.org/doc/4.6/chronyd.html
- chrony FAQ (leap seconds, virtualisation, containers) — https://chrony-project.org/faq.html

**NTP reference implementation**

- NTP Project documentation — https://www.ntp.org/documentation/4.2.8-series/
- `ntp.conf` access restrictions — https://www.ntp.org/documentation/4.2.8-series/accopt/
- `ntpq` — https://www.ntp.org/documentation/4.2.8-series/ntpq/
- Clock select, cluster and combine algorithms — https://www.ntp.org/documentation/4.2.8-series/select/
- NTP Pool project — https://www.ntppool.org/
- NTP Pool usage guidance for vendors — https://www.ntppool.org/vendors.html
- CVE-2013-5211 (`monlist` amplification) — https://nvd.nist.gov/vuln/detail/CVE-2013-5211

**systemd**

- `timedatectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
- `systemd-timesyncd.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-timesyncd.service.html
- `timesyncd.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/timesyncd.conf.html
- `systemd.special(7)` — `time-sync.target` — https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html

**util-linux and the kernel**

- `hwclock(8)` — https://man7.org/linux/man-pages/man8/hwclock.8.html
- `date(1)` — https://man7.org/linux/man-pages/man1/date.1.html
- `adjtimex(2)` — https://man7.org/linux/man-pages/man2/adjtimex.2.html
- `clock_gettime(2)` — https://man7.org/linux/man-pages/man2/clock_gettime.2.html
- `time_namespaces(7)` — https://man7.org/linux/man-pages/man7/time_namespaces.7.html
- `capabilities(7)` — `CAP_SYS_TIME` — https://man7.org/linux/man-pages/man7/capabilities.7.html
- Kernel timekeeping documentation — https://docs.kernel.org/timers/index.html
- Kernel PTP hardware clock infrastructure — https://docs.kernel.org/driver-api/ptp.html

**Leap seconds and cloud time services**

- BIPM leap second announcements (Bulletin C) — https://www.bipm.org/en/bipm-services/timescales/leap-second.html
- CGPM Resolution 4 (2022), on the future of the leap second — https://www.bipm.org/en/committees/cg/cgpm/27-2022/resolution-4
- Google Public NTP and leap smear — https://developers.google.com/time/smear
- Amazon Time Sync Service — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html
- Google Cloud: configure NTP on a VM — https://cloud.google.com/compute/docs/instances/configure-ntp
- Azure: time sync for Linux VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/linux/time-sync

**Monitoring**

- `node_exporter` timex collector — https://github.com/prometheus/node_exporter
- Prometheus node-exporter mixin alerts (`NodeClockSkewDetected`, `NodeClockNotSynchronising`) — https://github.com/prometheus/node_exporter/blob/master/docs/node-mixin/alerts/node.libsonnet

**Distribution guides**

- Red Hat Enterprise Linux — Configuring basic system settings, "Configuring time synchronization" — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/configuring-time-synchronization_configuring-basic-system-settings
- Debian Wiki — DateTime — https://wiki.debian.org/DateTime
- Arch Wiki — System time — https://wiki.archlinux.org/title/System_time
- Arch Wiki — Time synchronization — https://wiki.archlinux.org/title/Time_synchronization