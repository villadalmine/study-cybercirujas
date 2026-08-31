# LPIC-1 · 108.1 Maintain system time — Guided Exercises

> **Lab requirements.** A disposable VM (not a container, not your workstation) with `sudo`/root, a real RTC device (`/dev/rtc0`), and outbound UDP/123. Distribution-neutral: commands are shown for both `systemd`+`chrony` (RHEL/Fedora/openSUSE, Debian/Ubuntu server) and classic `ntpd` where they differ.
>
> **You will deliberately break the clock.** Never run these steps on a host that participates in Kerberos, TLS-terminating services, a database cluster, or a Kubernetes control plane: a clock step of more than a few minutes will invalidate certificates and tickets and can corrupt Raft/etcd state.
>
> Install the tooling first:
> ```bash
> # Debian/Ubuntu
> sudo apt-get install -y util-linux tzdata chrony ntpdate ntpsec-ntpdig
> # RHEL/Fedora/Rocky
> sudo dnf install -y util-linux tzdata chrony
> ```

---

## Exercise 1 — Identify the two clocks

A Linux host maintains **two independent clocks**: the *system clock* (a counter in kernel memory, advanced by a timer interrupt/TSC, always conceptually in UTC seconds since the Unix epoch) and the *hardware clock* — RTC, CMOS clock, BIOS clock — a battery-backed chip that keeps ticking while the machine is powered off. They are only related at the moments something explicitly copies one to the other.

1. Read the system clock in the local timezone, then in UTC:

   ```bash
   date
   date -u
   ```

   ```
   Wed Aug 26 16:41:07 CEST 2026
   Wed Aug 26 14:41:07 UTC 2026
   ```

2. Read the hardware clock. This requires root, because it opens `/dev/rtc0`:

   ```bash
   sudo hwclock --show
   ```

   ```
   2026-08-26 16:41:08.512394+02:00
   ```

3. Ask `hwclock` to narrate what it is actually doing:

   ```bash
   sudo hwclock --show --verbose
   ```

   ```
   hwclock from util-linux 2.39.3
   System Time: 1756219268.514902
   Trying to open: /dev/rtc0
   Using the rtc interface to the clock.
   Assuming hardware clock is kept in UTC time.
   Waiting for clock tick...
   ...got clock tick
   Time read from Hardware Clock: 2026/08/26 14:41:08
   Hw clock time : 2026/08/26 14:41:08 = 1756219268 seconds since 1969
   Time since last adjustment is 0 seconds
   Calculated Hardware Clock drift is 0.000000 seconds
   2026-08-26 16:41:08.512394+02:00
   ```

4. Get the consolidated `systemd` view of both clocks plus the timezone and synchronization state:

   ```bash
   timedatectl
   ```

   ```
                  Local time: Wed 2026-08-26 16:41:09 CEST
              Universal time: Wed 2026-08-26 14:41:09 UTC
                    RTC time: Wed 2026-08-26 14:41:09
                   Time zone: Europe/Madrid (CEST, +0200)
   System clock synchronized: yes
                 NTP service: active
             RTC in local TZ: no
   ```

5. Read the system clock as a raw epoch value, and convert an epoch value back to a human date:

   ```bash
   date +%s
   date -d @1756219269
   date -u -d @1756219269
   ```

   ```
   1756219269
   Wed Aug 26 16:41:09 CEST 2026
   Wed Aug 26 14:41:09 UTC 2026
   ```

**Check your understanding**

1. Line 3 of `timedatectl` output shows `RTC time` *without* a timezone suffix. Why does `timedatectl` refuse to label it, and what does the `RTC in local TZ: no` line tell you about how that number must be interpreted?
2. `date` needed no privileges, `hwclock --show` did. Explain the difference in terms of what each command reads.
3. In step 5, `date +%s` and `date -u +%s` would print exactly the same number. Why is `-u` meaningless for `%s` but meaningful for `%H:%M`?
4. Your VM has been powered off for a week. Which of the two clocks advanced during that week, and which one is authoritative at the next boot?

---

## Exercise 2 — `date`: formatting, parsing and setting

6. Practice the format specifiers that appear in real scripts and in the exam:

   ```bash
   date '+%Y-%m-%d %H:%M:%S'        # sortable log stamp
   date +%Y%m%d-%H%M%S              # filename-safe stamp
   date -Is                         # ISO 8601, seconds precision
   date -R                          # RFC 5322 (email/HTTP style)
   date -u +%Y-%m-%dT%H:%M:%SZ      # the canonical UTC "Zulu" form
   date '+%j day-of-year, week %V, %A'
   ```

   ```
   2026-08-26 16:41:10
   20260826-164110
   2026-08-26T16:41:10+02:00
   Wed, 26 Aug 2026 16:41:10 +0200
   2026-08-26T14:41:10Z
   238 day-of-year, week 35, Wednesday
   ```

7. Use the relative-date parser (`-d` / `--date`), which is a GNU coreutils extension and extremely common in backup and retention scripts:

   ```bash
   date -d 'now + 90 days' +%F
   date -d 'yesterday' +%F
   date -d '2026-03-29 01:59:59 UTC' +'%F %T %Z'
   date -d 'next friday 09:00' -Is
   ```

   ```
   2026-11-24
   2026-08-25
   2026-03-29 02:59:59 CET
   2026-08-28T09:00:00+02:00
   ```

8. Set the system clock manually. First observe what happens on a host where an NTP service is running:

   ```bash
   sudo date -s '2026-08-26 16:45:00'
   ```

   ```
   Wed Aug 26 16:45:00 CEST 2026
   ```

   ```bash
   sudo timedatectl set-time '2026-08-26 16:45:00'
   ```

   ```
   Failed to set time: Automatic time synchronization is enabled
   ```

9. Set the clock in absolute UTC terms, which is what you want in a script that must not depend on the machine's timezone:

   ```bash
   sudo date -u -s '2026-08-26 14:45:00'
   date
   ```

**Check your understanding**

5. `date -s` succeeded while `timedatectl set-time` was refused on the very same host, one second apart. What is `timedatectl` protecting you from, and why can't it protect you from `date -s`?
6. In step 7, `2026-03-29 01:59:59 UTC` printed as `02:59:59 CET`, but adding one more second in `Europe/Madrid` would print `04:00:00 CEST`. What happened, and what does that prove about wall-clock arithmetic?
7. Write a single command that prints the epoch second at which a TLS certificate expiring on `2027-01-15 23:59:59 UTC` becomes invalid.
8. Why is `date +%s` a safer key for computing an elapsed interval in a script than `date +%H%M%S`?

---

## Exercise 3 — Timezones: `/usr/share/zoneinfo`, `/etc/localtime`, `TZ`

The timezone database (IANA `tzdata`) is a set of **compiled binary** files under `/usr/share/zoneinfo/`, each describing UTC offsets and DST transitions for one zone across history. The system default is selected by `/etc/localtime`; a per-process override is the `TZ` environment variable.

10. Explore the database and inspect the current selection:

    ```bash
    ls /usr/share/zoneinfo | head
    ls /usr/share/zoneinfo/America/Argentina/
    file /usr/share/zoneinfo/Europe/Madrid
    ls -l /etc/localtime
    ```

    ```
    Africa
    America
    Antarctica
    Arctic
    Asia
    Atlantic
    Australia
    Brazil
    ...
    Buenos_Aires  Catamarca  Cordoba  Jujuy  La_Rioja  Mendoza  ...

    /usr/share/zoneinfo/Europe/Madrid: timezone data, version 2, 7 gmt time flags, ...

    lrwxrwxrwx 1 root root 33 Aug 20 09:12 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
    ```

11. Override the timezone for a single command using `TZ` — no root, no configuration change:

    ```bash
    date
    TZ='UTC' date
    TZ='America/Argentina/Buenos_Aires' date
    TZ='Asia/Tokyo' date '+%F %T %Z (%z)'
    ```

    ```
    Wed Aug 26 16:45:20 CEST 2026
    Wed Aug 26 14:45:20 UTC 2026
    Wed Aug 26 11:45:20 -03 2026
    2026-08-27 04:45:20 JST (+0900)
    ```

12. Inspect DST transition rules with `zdump`, the tool that reads a zoneinfo file directly:

    ```bash
    zdump Europe/Madrid
    zdump -v Europe/Madrid | grep 2026
    ```

    ```
    Europe/Madrid  Wed Aug 26 16:45:25 2026 CEST

    Europe/Madrid  Sun Mar 29 00:59:59 2026 UT = Sun Mar 29 01:59:59 2026 CET isdst=0 gmtoff=3600
    Europe/Madrid  Sun Mar 29 01:00:00 2026 UT = Sun Mar 29 03:00:00 2026 CEST isdst=1 gmtoff=7200
    Europe/Madrid  Sun Oct 25 00:59:59 2026 UT = Sun Oct 25 02:59:59 2026 CEST isdst=1 gmtoff=7200
    Europe/Madrid  Sun Oct 25 01:00:00 2026 UT = Sun Oct 25 02:00:00 2026 CET  isdst=0 gmtoff=3600
    ```

13. Change the system timezone. The modern, distribution-neutral way:

    ```bash
    timedatectl list-timezones | grep -i madrid
    sudo timedatectl set-timezone America/Argentina/Buenos_Aires
    ls -l /etc/localtime
    date
    ```

    ```
    Europe/Madrid
    lrwxrwxrwx 1 root root 51 Aug 26 16:46 /etc/localtime -> ../usr/share/zoneinfo/America/Argentina/Buenos_Aires
    Wed Aug 26 11:46:02 -03 2026
    ```

14. Reproduce the same change the traditional way, and inspect the Debian-family name file:

    ```bash
    sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
    cat /etc/timezone 2>/dev/null || echo '(no /etc/timezone on this distribution)'
    ```

    On Debian/Ubuntu you would also refresh the name file — never edit it alone:

    ```bash
    sudo dpkg-reconfigure tzdata     # interactive; rewrites /etc/timezone AND /etc/localtime
    ```

    And the interactive helper that only *suggests* a value:

    ```bash
    tzselect
    ```

    ```
    Please identify a location so that time zone rules can be set correctly.
    Please select a continent, ocean, "coord", "TZ", "time", or "Ctrl-D" to quit:
     1) Africa
     2) Americas
    ...
    You can make this change permanent for yourself by appending the line
            TZ='Europe/Madrid'; export TZ
    to the file '.profile' in your home directory
    ```

15. Verify that a running service does **not** pick up the change:

    ```bash
    sudo timedatectl set-timezone UTC
    journalctl -n 3 --no-pager        # journald re-reads it; long-lived daemons often do not
    ```

**Check your understanding**

9. `/etc/localtime` and `/etc/timezone` both encode "the system timezone". What is stored in each, which one do the C library functions actually consult, and what breaks if they disagree?
10. `tzselect` printed a suggestion instead of changing anything. Why is that the correct behaviour, and which two commands *do* change the system default?
11. `TZ='Asia/Tokyo' date` printed a date one day ahead. Did the system clock change? Explain what the C library did with `TZ`.
12. From the `zdump` output in step 12: how many times does the wall clock read `2026-10-25 02:30:00` in Madrid, and what does that imply for a `cron` job scheduled at `30 2 * * *`?
13. `timedatectl set-timezone` needed root but `TZ=...` did not. Explain the scope of each change.

---

## Exercise 4 — The hardware clock, `/etc/adjtime`, and UTC vs LOCAL

16. Read the RTC configuration file. This three-line file is the whole persistent state of `hwclock`:

    ```bash
    cat /etc/adjtime
    ```

    ```
    0.000000 1756219268 0.000000
    1756219268
    UTC
    ```

    Field by field:

    | Position | Meaning |
    |---|---|
    | line 1, field 1 | **drift factor** — systematic RTC error in seconds gained per day |
    | line 1, field 2 | epoch of the last time `hwclock` adjusted or set the RTC |
    | line 1, field 3 | remaining fractional second not yet applied |
    | line 2 | epoch of the last **calibration** (`--set` / `--systohc`), `0` if never |
    | line 3 | `UTC` or `LOCAL` — how the value in the RTC must be interpreted |

17. Copy the system clock **to** the RTC, then the RTC **to** the system clock:

    ```bash
    sudo hwclock --systohc          # equivalent: hwclock -w  ("write")
    sudo hwclock --hctosys          # equivalent: hwclock -s  ("set from hardware")
    ```

18. Set the RTC to an explicit value without touching the system clock, then observe the divergence:

    ```bash
    sudo hwclock --set --date='2026-08-26 12:00:00'
    date; sudo hwclock --show
    ```

    ```
    Wed Aug 26 16:47:31 CEST 2026
    2026-08-26 12:00:04.117482+02:00
    ```

19. Switch the RTC interpretation to local time and watch the same hardware register change meaning:

    ```bash
    sudo timedatectl set-local-rtc 1
    tail -1 /etc/adjtime
    timedatectl
    ```

    ```
    LOCAL
                   Local time: Wed 2026-08-26 16:48:03 CEST
               Universal time: Wed 2026-08-26 14:48:03 UTC
                     RTC time: Wed 2026-08-26 16:48:03
                    Time zone: Europe/Madrid (CEST, +0200)
    System clock synchronized: yes
                  NTP service: active
              RTC in local TZ: yes

    Warning: The system is configured to read the RTC time in the local time zone.
             This mode cannot be fully supported. It will create various problems
             with time zone changes and daylight saving time adjustments. ...
    ```

20. Restore the sane configuration:

    ```bash
    sudo timedatectl set-local-rtc 0 --adjust-system-clock
    tail -1 /etc/adjtime
    sudo hwclock --systohc --utc
    ```

21. Inspect who else writes the RTC. With `chrony`, the kernel does it:

    ```bash
    grep -E '^(rtcsync|rtcfile|rtconutc)' /etc/chrony/chrony.conf /etc/chrony.conf 2>/dev/null
    ```

    ```
    /etc/chrony.conf:rtcsync
    ```

**Check your understanding**

14. `/etc/adjtime` line 3 says `UTC`, and the RTC register holds `14:48:03` while `date` says `16:48:03`. Are the clocks in agreement? Show the reasoning.
15. A dual-boot machine with Windows shows the correct time in Windows and a two-hour-shifted time in Linux at every boot. Which line of `/etc/adjtime` explains this, and give the two possible fixes (one on each OS).
16. What is the difference between `hwclock --systohc` and `hwclock --hctosys`? Which one runs implicitly at shutdown on a systemd host, and which one is largely obsolete at boot, and why?
17. `hwclock --adjust` exists but you did not run it. What does it use the drift factor for, and why does it become actively harmful on a host running `chronyd` with `rtcsync`?
18. Explain why `RTC in local TZ: yes` "cannot be fully supported", using the October transition from Exercise 3 as the example.

---

## Exercise 5 — `systemd-timesyncd`: the minimal SNTP client

`systemd-timesyncd` is an **SNTP client only** — it queries one server at a time, has no server mode, and implements none of NTP's clock-selection algorithms. It is the default on desktop Debian/Ubuntu images. It cannot coexist with `chronyd` or `ntpd`.

22. Determine which time daemon is actually in charge:

    ```bash
    timedatectl show --property=NTP --property=NTPSynchronized
    systemctl is-active systemd-timesyncd chronyd chrony ntpd ntpsec 2>/dev/null
    ```

    ```
    NTP=yes
    NTPSynchronized=yes
    active
    inactive
    inactive
    inactive
    inactive
    ```

23. Read its configuration and the compiled-in defaults:

    ```bash
    grep -vE '^\s*(#|$)' /etc/systemd/timesyncd.conf
    systemd-analyze cat-config systemd/timesyncd.conf | grep -E '^(NTP|FallbackNTP|RootDistanceMaxSec|PollInterval)'
    ```

    ```
    [Time]
    NTP=time.cloudflare.com
    FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org
    ```

24. Inspect the live synchronization state:

    ```bash
    timedatectl timesync-status
    ```

    ```
           Server: 162.159.200.1 (time.cloudflare.com)
    Poll interval: 34min 8s (min: 32s; max 34min 8s)
             Leap: normal
          Version: 4
          Stratum: 3
        Reference: A29FC87B
    Precision: 1us (-20)
    Root distance: 12.345ms (max: 5s)
           Offset: +291us
            Delay: 11.204ms
           Jitter: 1.417ms
     Packet count: 9
        Frequency: -13.483ppm
    ```

25. Toggle synchronization off and on, and confirm the effect:

    ```bash
    sudo timedatectl set-ntp false
    timedatectl | grep -E 'synchronized|NTP service'
    sudo timedatectl set-ntp true
    systemctl is-active systemd-timesyncd
    ```

26. Replace it with `chrony` — note that installation normally masks `timesyncd` automatically:

    ```bash
    sudo systemctl disable --now systemd-timesyncd
    sudo systemctl enable --now chronyd 2>/dev/null || sudo systemctl enable --now chrony
    timedatectl | grep 'NTP service'
    ```

**Check your understanding**

19. `timedatectl set-ntp true` did not name a daemon, yet a specific unit started. How does `systemd-timedated` decide which one to enable?
20. `timesync-status` reports `Root distance: 12.345ms (max: 5s)`. What is root distance measuring, and what does `systemd-timesyncd` do if it exceeds `RootDistanceMaxSec`?
21. Give two concrete production requirements that `systemd-timesyncd` cannot satisfy but `chrony` can.
22. Why do `chronyd` and `systemd-timesyncd` refuse to run simultaneously? Name the resource they contend for at both the network and the kernel level.

---

## Exercise 6 — `chrony`: `chronyd`, `chrony.conf`, `chronyc`

27. Locate and read the configuration (path is `/etc/chrony.conf` on RHEL-family, `/etc/chrony/chrony.conf` on Debian-family):

    ```bash
    CHRONY_CONF=$(ls /etc/chrony.conf /etc/chrony/chrony.conf 2>/dev/null | head -1)
    grep -vE '^\s*(#|$)' "$CHRONY_CONF"
    ```

    ```
    pool 2.debian.pool.ntp.org iburst
    driftfile /var/lib/chrony/chrony.drift
    makestep 1.0 3
    rtcsync
    keyfile /etc/chrony/chrony.keys
    ntsdumpdir /var/lib/chrony
    leapsectz right/UTC
    logdir /var/log/chrony
    ```

    | Directive | Effect |
    |---|---|
    | `server HOST iburst` | one specific source; `iburst` sends 4 rapid packets at start to converge in seconds instead of minutes |
    | `pool NAME iburst` | resolves to many addresses, keeps a working set, replaces unreachable members |
    | `driftfile PATH` | persists the measured oscillator error (ppm) so the next start is already accurate |
    | `makestep THRESHOLD LIMIT` | **step** (jump) instead of slew if the offset exceeds `THRESHOLD` seconds, for the first `LIMIT` updates only |
    | `rtcsync` | enables the kernel's 11-minute mode, which copies the system clock to the RTC |
    | `allow SUBNET` | act as a server for that subnet (default: serve nobody) |
    | `local stratum 10` | keep serving with a synthetic stratum when all upstreams are lost — an isolated-island fallback |

28. Query the daemon's own view of its discipline:

    ```bash
    chronyc tracking
    ```

    ```
    Reference ID    : A29FC87B (time.cloudflare.com)
    Stratum         : 4
    Ref time (UTC)  : Wed Aug 26 14:52:11 2026
    System time     : 0.000023145 seconds fast of NTP time
    Last offset     : +0.000012345 seconds
    RMS offset      : 0.000103456 seconds
    Frequency       : 13.483 ppm slow
    Residual freq   : +0.001 ppm
    Skew            : 0.123 ppm
    Root delay      : 0.012345678 seconds
    Root dispersion : 0.001234567 seconds
    Update interval : 64.2 seconds
    Leap status     : Normal
    ```

29. List the sources and read the selection state:

    ```bash
    chronyc sources -v
    ```

    ```
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
    ^* 162.159.200.1                 3   6   377    21    +12us[  +14us] +/-   11ms
    ^+ 51.15.191.239                 2   6   377    23  -1234us[-1232us] +/-   28ms
    ^- 194.58.204.148                2   6   377    19  +8901us[+8903us] +/-   41ms
    ^? 185.125.190.56               16   6     0     -     +0ns[   +0ns] +/-    0ns
    ```

30. Look at the per-source statistics used to estimate frequency:

    ```bash
    chronyc sourcestats -v
    ```

    ```
    Name/IP Address            NP  NR  Span  Frequency  Freq Skew  Offset  Std Dev
    ==============================================================================
    162.159.200.1              18   9   17m     +0.021      0.187    +14us    98us
    51.15.191.239              17  10   16m     -0.104      0.412  -1232us   331us
    ```

31. Inspect one association at packet level, and check daemon activity:

    ```bash
    chronyc ntpdata 162.159.200.1 | head -20
    chronyc activity
    ```

    ```
    8 sources online
    0 sources offline
    0 sources doing burst (return to online)
    0 sources doing burst (return to offline)
    0 sources with unknown address
    ```

32. Force an immediate correction and add a source at runtime (runtime commands require authorisation, hence `-a` or running as root over the Unix socket):

    ```bash
    sudo chronyc makestep
    sudo chronyc add server time.cloudflare.com iburst
    sudo chronyc burst 4/4
    sudo chronyc sources
    ```

    ```
    200 OK
    200 OK
    200 OK
    ```

33. Use the one-shot modes, which are the modern replacement for `ntpdate`:

    ```bash
    sudo systemctl stop chronyd
    sudo chronyd -Q 'pool pool.ntp.org iburst'    # measure only, do NOT touch the clock
    sudo chronyd -q  'pool pool.ntp.org iburst'   # set the clock once, then exit
    sudo systemctl start chronyd
    ```

    ```
    2026-08-26T14:53:40Z chronyd version 4.5 starting (+CMDMON +NTP ...)
    2026-08-26T14:53:44Z System clock wrong by -1.428301 seconds (ignored)
    2026-08-26T14:53:44Z chronyd exiting
    ```

**Check your understanding**

23. In step 29, source `194.58.204.148` is marked `-`. Is it broken? What is the difference between `-`, `x` and `?` in that column?
24. `Reach` reads `377`. What base is that number, how many polls does it summarise, and what would `357` mean?
25. `makestep 1.0 3` is in the configuration, yet in step 33 `chronyd -Q` refused to correct a 1.4-second error. Reconcile the two observations.
26. Explain the practical difference between **stepping** and **slewing** the clock, and name one class of application that is corrupted by a backward step but tolerates a slew.
27. `chronyc tracking` reports `Stratum: 4` while `sources` shows the selected server at stratum 3. Where does the extra hop come from, and what does `Stratum: 16` mean anywhere in NTP?
28. Why does the `driftfile` make a *cold boot with no network* more accurate than it would otherwise be?

---

## Exercise 7 — Classic `ntpd`, `ntpq` and `ntpdate`

The reference implementation `ntpd` (and its fork `ntpsec`) is still the exam's baseline. Do not install it alongside `chrony`.

34. Read a typical `/etc/ntp.conf`:

    ```bash
    grep -vE '^\s*(#|$)' /etc/ntp.conf
    ```

    ```
    driftfile /var/lib/ntp/ntp.drift
    restrict default kod nomodify notrap nopeer noquery limited
    restrict 127.0.0.1
    restrict ::1
    restrict 192.168.10.0 mask 255.255.255.0 nomodify notrap
    pool 0.pool.ntp.org iburst
    server 192.168.10.1 iburst prefer
    server 127.127.1.0
    fudge  127.127.1.0 stratum 10
    ```

    | Directive | Effect |
    |---|---|
    | `server HOST [iburst] [prefer]` | one upstream; `prefer` biases selection toward it |
    | `pool NAME iburst` | DNS-based dynamic set of servers |
    | `driftfile PATH` | persisted frequency error, written roughly hourly |
    | `restrict ... noquery nomodify` | access control — `noquery` blocks `ntpq`/`ntpdc` from that peer, `nomodify` blocks runtime reconfiguration |
    | `server 127.127.1.0` + `fudge ... stratum 10` | the **local clock driver**: keep serving at a poor stratum when isolated |

35. Query the peer list — always with `-n` first, so DNS failures cannot masquerade as NTP failures:

    ```bash
    ntpq -pn
    ```

    ```
         remote           refid      st t when poll reach   delay   offset  jitter
    ==============================================================================
    *162.159.200.1   10.176.6.109     3 u   35   64  377    9.123   -0.234   0.456
    +51.15.191.239   193.204.114.232  2 u   41   64  377   18.456   +0.789   1.012
    -194.58.204.148  .GPS.            1 u   12   64  377   45.678  +12.345   2.345
     185.125.190.56  .INIT.          16 u    -   64    0    0.000   +0.000   0.000
    x203.0.113.7     .STEP.          16 u   19   64  377   31.002 +998.123  15.771
    ```

    The first character is the **tally code**:

    | Code | Meaning |
    |---|---|
    | (space) | rejected — unreachable, or failed a sanity check |
    | `x` | falseticker — the intersection algorithm proved it wrong |
    | `-` | outlier discarded by the clustering algorithm |
    | `+` | survivor, eligible for the combining algorithm |
    | `#` | good, but not among the first six by synchronization distance |
    | `*` | **system peer** — the one currently disciplining the clock |
    | `o` | system peer, disciplined via a PPS signal |

36. Read the daemon's own variables:

    ```bash
    ntpq -c rv
    ```

    ```
    associd=0 status=0615 leap_none, sync_ntp, 1 event, clock_sync,
    version="ntpd 4.2.8p17@1.4004-o", processor="x86_64", system="Linux/6.8.0",
    leap=00, stratum=4, precision=-24, rootdelay=21.004, rootdisp=38.112,
    refid=162.159.200.1, reftime=ec6a1f3c.9a3b1e50, clock=ec6a1f78.10c4a2f1,
    peer=41234, tc=6, mintc=3, offset=-0.234, frequency=-13.483, sys_jitter=0.456,
    clk_jitter=0.311, clk_wander=0.021
    ```

37. Query a server **without** setting anything — the safe reconnaissance step before any correction:

    ```bash
    ntpdate -q pool.ntp.org
    # or, on ntpsec:
    ntpdig -d pool.ntp.org
    ```

    ```
    server 162.159.200.1, stratum 3, offset -1.428301, delay 0.03212
    server 51.15.191.239, stratum 2, offset -1.427905, delay 0.04117
    26 Aug 16:55:02 ntpdate[4711]: adjust time server 162.159.200.1 offset -1.428301 sec
    ```

38. Correct a large offset at boot. `ntpdate` is deprecated; the supported equivalents are:

    ```bash
    sudo systemctl stop ntpd
    sudo ntpd -gq                 # -g: allow one step of any size; -q: quit after setting
    sudo sntp -sS pool.ntp.org    # ntpsec's step-if-needed one-shot
    sudo systemctl start ntpd
    ```

39. Confirm the daemon is bound where you expect, and that the protocol can leave the host:

    ```bash
    sudo ss -lunp | grep ':123'
    sudo firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | grep -x ntp
    ```

    ```
    UNCONN 0 0        0.0.0.0:123       0.0.0.0:*    users:(("ntpd",pid=880,fd=20))
    UNCONN 0 0           [::]:123          [::]:*    users:(("ntpd",pid=880,fd=21))
    ```

**Check your understanding**

29. In step 35, the stratum-1 GPS-backed server `194.58.204.148` was rejected with `-` while a stratum-3 server was chosen as system peer. Why is "lowest stratum wins" the wrong mental model?
30. What does `refid` `.INIT.` mean, and how does it differ from `.STEP.`? What would a refid of `.GPS.` or `.PPS.` tell you about that peer?
31. `reach` for the last peer is `0` and `when` is `-`. What single hypothesis explains both fields, and which command in step 39 tests it?
32. Explain why `ntpd` needs the `-g` flag at boot. What is the panic threshold, and what does `ntpd` do without `-g` when it is exceeded?
33. A monitoring host runs `ntpq -pn <server>` against a peer and gets `***Server reports a permission error`. Which directive in that peer's `/etc/ntp.conf` is responsible, and why is it the default?
34. Why does `restrict default ... noquery limited` matter for security, not just hygiene? (Consider what an off-path attacker can do with a spoofed source address and a large NTP response.)

---

## Exercise 8 — Diagnostic lab: break it, then repair it

40. **Snapshot the healthy state** so you can prove the repair:

    ```bash
    date -u -Is; sudo hwclock --show; cat /etc/adjtime; chronyc tracking | head -3
    ```

41. **Fault A — the clock is far in the future.** Stop the daemon, jump the clock forward, restart, observe:

    ```bash
    sudo systemctl stop chronyd
    sudo date -u -s '2026-09-05 03:00:00'
    sudo systemctl start chronyd
    sleep 20
    chronyc tracking | grep -E 'Leap|System time'
    journalctl -u chronyd -n 10 --no-pager
    ```

    ```
    Aug 26 16:57:02 lab chronyd[5122]: Selected source 162.159.200.1
    Aug 26 16:57:02 lab chronyd[5122]: System clock wrong by -777421.913 seconds
    Aug 26 16:57:02 lab chronyd[5122]: System clock was stepped by -777421.913 seconds
    ```

42. **Fault B — the RTC is in local time but `/etc/adjtime` says UTC.** Simulate a Windows dual-boot:

    ```bash
    sudo hwclock --set --date="$(date '+%Y-%m-%d %H:%M:%S')" --utc   # write LOCAL wall time as if UTC
    sudo hwclock --hctosys
    date; timedatectl | grep -E 'Local time|RTC time'
    ```

    Diagnose and repair:

    ```bash
    tail -1 /etc/adjtime
    sudo timedatectl set-local-rtc 0 --adjust-system-clock
    sudo chronyc makestep
    sudo hwclock --systohc
    ```

43. **Fault C — UDP/123 is blocked.** Block egress and watch the symptom, which is *silence*, not an error:

    ```bash
    sudo nft add table inet lab 2>/dev/null
    sudo nft add chain inet lab out '{ type filter hook output priority 0; }'
    sudo nft add rule inet lab out udp dport 123 drop
    sudo systemctl restart chronyd; sleep 30
    chronyc sources
    timedatectl | grep synchronized
    ```

    ```
    MS Name/IP address         Stratum Poll Reach LastRx Last sample
    ===============================================================================
    ^? 162.159.200.1                 0   6     0     -     +0ns[   +0ns] +/-    0ns
    ^? 51.15.191.239                 0   6     0     -     +0ns[   +0ns] +/-    0ns
    System clock synchronized: no
    ```

    Prove it is the network and not the daemon, then clean up:

    ```bash
    sudo timeout 5 ntpdate -q 162.159.200.1 ; echo "exit=$?"
    sudo nft delete table inet lab
    sudo chronyc burst 4/4; sleep 20; chronyc sources
    ```

44. **Fault D — timezone regression after a `tzdata` update.** Verify the database version and refresh it:

    ```bash
    zdump -v Europe/Madrid | tail -2
    rpm -q tzdata 2>/dev/null || dpkg -l tzdata | tail -1
    sudo dnf update tzdata 2>/dev/null || sudo apt-get install --only-upgrade tzdata
    ```

45. **Restore and verify the whole chain end to end:**

    ```bash
    sudo timedatectl set-timezone Europe/Madrid
    sudo timedatectl set-local-rtc 0
    sudo systemctl enable --now chronyd
    sleep 15
    timedatectl
    chronyc tracking | grep -E 'Stratum|Leap|System time'
    sudo hwclock --systohc
    sudo hwclock --show; date
    ```

**Check your understanding**

35. In Fault A the log says `System clock was stepped`, yet `makestep 1.0 3` limits stepping to the first 3 updates. Why was a step allowed here, and what would have happened at the *tenth* update instead?
36. In Fault B, name the exact quantity by which `date` was wrong, expressed in terms of the timezone offset. Would the error have been zero in `Etc/UTC`?
37. In Fault C, `chronyc sources` showed `Stratum 0` and `Reach 0` for every source. Why is "stratum 0" here *not* the same "stratum 0" as a caesium reference clock?
38. Fault C blocked only the **output** hook. Explain why blocking the outbound request is sufficient to break NTP, and what a stateful firewall must allow for the reply to return.
39. You applied `hwclock --systohc` at the end of step 45 even though `rtcsync` is configured. Was that redundant? Under exactly which condition is it not?
40. Write the minimal command sequence — three commands — that answers "is this host's time correct, and who says so?" on an unfamiliar systemd host.

---

## Sources

- LPI, *Exam 101 Objectives, version 5.0* — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI, *Exam 102 Objectives, version 5.0* (objective 108.1 lives here) — https://www.lpi.org/our-certifications/exam-102-objectives/
- `date(1)`, GNU coreutils — https://man7.org/linux/man-pages/man1/date.1.html
- `hwclock(8)`, util-linux — https://man7.org/linux/man-pages/man8/hwclock.8.html
- `adjtime_config(5)` — https://man7.org/linux/man-pages/man5/adjtime_config.5.html
- `timedatectl(1)`, systemd — https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
- `systemd-timesyncd.service(8)` and `timesyncd.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-timesyncd.service.html
- chrony project documentation (`chronyd`, `chronyc`, `chrony.conf`) — https://chrony-project.org/documentation.html
- NTP Project, *ntpd / ntpq / ntpdate documentation* — https://www.ntp.org/documentation/4.2.8-series/
- NTP Pool Project — https://www.ntppool.org/
- IANA Time Zone Database — https://www.iana.org/time-zones
- RFC 5905, *Network Time Protocol Version 4: Protocol and Algorithms Specification* — https://datatracker.ietf.org/doc/html/rfc5905

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 1

**1.** The RTC is a bare counter of six numbers (year, month, day, hour, minute, second) with **no timezone information whatsoever** stored in the hardware. Its meaning comes entirely from line 3 of `/etc/adjtime`. `timedatectl` prints it unlabelled because labelling it would be an assertion the hardware does not make; the separate `RTC in local TZ: no` line supplies the missing convention — here, "read those digits as UTC". If that line said `yes`, the identical register value would mean local wall-clock time instead.

**2.** `date` reads the system clock, which is kernel memory exposed through the `clock_gettime(2)` syscall / vDSO — unprivileged, and cheap enough to call millions of times per second. `hwclock` reads the physical RTC chip through the `/dev/rtc0` character device (or, on legacy hardware, direct I/O ports), and that device node is `root`-owned. It is also slow: `hwclock` synchronises to a clock tick, so a read takes up to a second.

**3.** `%s` is seconds since the Unix epoch, an absolute count of elapsed seconds that is timezone-independent by definition — there is nothing for `-u` to change. `%H:%M` is a *rendering* of that count into a human calendar, and rendering requires choosing an offset; `-u` forces that offset to zero. This is the central distinction of the whole objective: **one instant, many representations.**

**4.** Only the RTC advanced — the system clock does not exist while the machine is off; it is created at boot. At the next boot the kernel initialises the system clock from the RTC (via the `rtc_hctosys` kernel option or an early `hwclock --hctosys`), so the RTC is authoritative for exactly that moment, until the NTP daemon obtains a network sample and takes over.

### Exercise 2

**5.** `timedatectl set-time` refuses because an NTP daemon is disciplining the clock; any value you set will be silently undone within one poll interval, and worse, you will have fought the daemon's frequency estimate, degrading it. It cannot protect you from `date -s` because `date` is not a systemd client at all — it calls `clock_settime(2)` directly. Privilege, not policy, is the only gate there. In production the correct sequence is always: stop the daemon, correct, restart the daemon (or just use `chronyc makestep`).

**6.** Madrid's spring DST transition: at `01:00:00 UTC` on 2026-03-29 the offset jumps from `+01:00` (CET) to `+02:00` (CEST), so local wall-clock time skips directly from `01:59:59` to `03:00:00`. The hour `02:00:00–02:59:59` **does not exist** on that date. This proves that local wall-clock arithmetic is not closed: "add one hour" and "add 3600 seconds" are different operations. Schedule and compute in UTC or epoch seconds; render in local time only for humans.

**7.**
```bash
date -u -d '2027-01-15 23:59:59' +%s
```
Or equivalently, `date -d '2027-01-15T23:59:59Z' +%s`. The `Z` suffix / `-u` flag is what makes the answer independent of the host's timezone.

**8.** `%s` is monotonic in the calendar sense and has no discontinuities except when the clock is stepped; `%H%M%S` wraps to zero at midnight and, on DST days, jumps forward or repeats an hour. A duration computed from `%H%M%S` can be negative, off by 3600, or off by 86400. (For interval measurement that must survive even a clock step, the truly correct source is `CLOCK_MONOTONIC` — in shell, `$SECONDS` or `/proc/uptime`.)

### Exercise 3

**9.** `/usr/share/zoneinfo/<Zone>` holds the **compiled binary rules**; `/etc/localtime` is a symlink (or copy) to the one currently in force; `/etc/timezone` (Debian family only) holds the zone **name** as plain text. glibc's `localtime(3)`/`tzset(3)` read `/etc/localtime` — that is what determines what `date` prints. `/etc/timezone` is a Debian bookkeeping file consumed by `dpkg-reconfigure tzdata` and some installers. If they disagree, `date` follows `/etc/localtime` while packaging tools and some applications report the other value, and the next `tzdata` upgrade may silently "restore" `/etc/localtime` from the stale name — which is exactly why you never edit `/etc/timezone` by hand.

**10.** `tzselect` is a *pure helper*: it walks you through continent → country → zone and prints the `TZ` string. Changing the system default is a privileged, system-wide act, and deciding it for you from an interactive menu would be surprising. The two commands that actually change it are `timedatectl set-timezone <Zone>` and the manual `ln -sf /usr/share/zoneinfo/<Zone> /etc/localtime` (plus `dpkg-reconfigure tzdata` on Debian, which does both files).

**11.** No — the system clock (the epoch second) was identical for all four commands in step 11. `TZ` is read by glibc's `tzset(3)` at the start of the process and overrides `/etc/localtime` for **that process only**; `date` then rendered the same instant with a `+09:00` offset, which happened to cross midnight. Scope: one process, one invocation.

**12.** **Twice.** At the autumn transition the clock goes back from `03:00 CEST` to `02:00 CET`, so `02:30:00` occurs once at UTC `00:30` and again at UTC `01:30`. Vixie cron runs a job scheduled inside a repeated hour **once**, and a job scheduled inside a *skipped* hour (spring) once, immediately after the jump — but the behaviour differs between cron implementations and between `cron.d` and `@hourly`-style entries. For anything that must not double-run, schedule in UTC (`TZ=UTC` in the crontab, or `CRON_TZ=UTC`) or use a systemd timer, and make the job idempotent.

**13.** `TZ=` is per-process, per-invocation, unprivileged, and disappears when the command exits. `timedatectl set-timezone` rewrites `/etc/localtime` for every process started afterwards, needs root (via polkit), and does **not** retroactively change already-running daemons — most call `tzset()` once at startup and cache the result, so services must be restarted (or must handle `SIGHUP`) to observe the new zone.

### Exercise 4

**14.** **Yes, they agree perfectly.** `/etc/adjtime` says `UTC`, so the register value `14:48:03` *is* UTC. The system timezone is `Europe/Madrid`, which in August is CEST = UTC+2, so the correct local rendering of that same instant is `16:48:03`. The two-hour difference is the timezone offset, not clock error.

**15.** Line 3 — it reads `UTC` on the Linux side while Windows, by default, writes and reads the RTC in **local time**. Both operating systems apply their own convention to the same register, so Linux over-corrects by the offset. Two fixes:
- On Linux: `sudo timedatectl set-local-rtc 1 --adjust-system-clock` (works, but is the mode systemd warns about).
- On Windows (preferred): set `HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation\RealTimeIsUniversal` = `dword:00000001`, so both systems agree on UTC.
The Windows-side fix is better because the local-RTC mode cannot represent DST transitions unambiguously (see answer 18).

**16.** `--systohc` (`-w`) copies **system → hardware**; `--hctosys` (`-s`) copies **hardware → system**. On a systemd host the RTC is written on clean shutdown (and, with `rtcsync`, continuously by the kernel), so `--systohc` is the one that runs implicitly. `--hctosys` at boot is largely obsolete because the kernel itself initialises the system clock from the RTC during early boot (`CONFIG_RTC_HCTOSYS`), before userspace exists — running it again from an init script is redundant and, on a `local-rtc` system, can be actively wrong.

**17.** `hwclock --adjust` applies the accumulated drift correction: it multiplies the drift factor (seconds/day) by the time elapsed since the last adjustment and writes the corrected value back to the RTC, then updates line 1 of `/etc/adjtime`. It is harmful under `chronyd` with `rtcsync` because the kernel is *already* rewriting the RTC every 11 minutes from the NTP-disciplined system clock. `hwclock` would then measure "drift" that is really NTP's own correction, compute a bogus drift factor, and apply a second correction on top — two controllers fighting over one register. Rule: pick one owner of the RTC.

**18.** In the local-RTC mode the RTC digits mean "local wall-clock time", but wall-clock time is not a function of the instant alone — during the October transition in Madrid, `02:30:00` occurs twice, one hour apart. A boot at either of those instants reads the identical register value, so the system cannot determine which of the two instants it is. There is no field in the hardware to disambiguate, and no way to know at boot whether a previous OS already applied the DST shift. UTC has no such ambiguity, which is why it is the only fully supportable mode.

### Exercise 5

**19.** `systemd-timedated` consults a compiled-in, ordered list of known NTP implementation units, published as `.list` files in `/usr/lib/systemd/ntp-units.d/` (each package drops in its own name — `chrony.list`, `ntpsec.list`, `systemd-timesyncd.list`). `set-ntp true` enables and starts the **first available** unit in that merged, sorted list and disables the rest; `set-ntp false` disables all of them. That is why installing `chrony` transparently displaces `systemd-timesyncd`.

**20.** Root distance is the total accumulated uncertainty back to the stratum-0 reference: half the round-trip root delay plus the root dispersion, plus local jitter — an upper bound on how wrong the server's own time may be. If it exceeds `RootDistanceMaxSec` (default 5 s), `systemd-timesyncd` treats the sample as untrustworthy, does **not** use it to discipline the clock, and moves on to another server; sustained failure means `NTPSynchronized=no`.

**21.** Any two of: (a) serving time to other hosts — `timesyncd` has no server mode at all; (b) combining multiple sources and rejecting falsetickers — `timesyncd` uses one server at a time with no intersection/clustering algorithm; (c) hardware reference clocks (GPS/PPS via `refclock`); (d) NTS (RFC 8915) authenticated time, or symmetric-key authentication; (e) disciplining the RTC and handling asymmetric-delay/hardware-timestamping for sub-microsecond accuracy; (f) precise leap-second handling with `leapsectz`/smearing.

**22.** They both need to bind UDP port 123 as the source port for their queries, and both call `adjtimex(2)`/`clock_adjtime(2)` to discipline the kernel clock. Two independent PLL controllers writing the same kernel frequency and offset registers oscillate against each other, producing worse accuracy than either alone — so the packaging and `ntp-units.d` mechanism enforces exactly one.

### Exercise 6

**23.** No, `-` does not mean broken. `-` means the source is reachable and sane but was **excluded by the clustering algorithm** as a statistical outlier — it is simply not contributing to the combined estimate right now, and it may become a survivor later. `x` is much stronger: the intersection ("Marzullo/falseticker") algorithm proved its claimed interval is inconsistent with the majority — it is *lying* or badly wrong. `?` means unusable/unreachable: no valid samples yet (`Reach 0`), typically DNS resolution, routing or firewall trouble.

**24.** `377` is **octal**, i.e. binary `11111111` — the reachability register is an 8-bit shift register summarising the **last 8 polls**, one bit each, newest shifted in at the low end. `377` = all eight succeeded. `357` = octal `011 101 111` → binary `11101111`, meaning the fourth-most-recent poll was lost and the rest arrived; a single dropped packet, usually harmless. A value that decays toward `0` (`377 → 376 → 374 → 370 …`) is a source going away.

**25.** `chronyd -Q` is explicitly the **query-only** mode: it measures the offset and reports it, but never calls `clock_settime`/`adjtimex` — the log line even says `(ignored)`. `makestep` is a configuration directive for the *daemon* mode; `-Q` overrides all clock-setting behaviour by design. Use `-q` (lowercase) when you actually want the one-shot correction, and `-Q` when you are diagnosing a production host and must not disturb it.

**26.** A **step** writes a new value to the clock instantly — time can jump forward or, worse, backward, so an instant can repeat and monotonicity of wall-clock time is broken. A **slew** leaves the clock monotonic and merely changes its *rate* (typically capped at 500 ppm, or 0.5 ms/s), letting the error bleed off gradually; correcting one second by slewing takes about 33 minutes at that rate. Anything using wall-clock time as an ordering key is corrupted by a backward step: database write-ahead logs and MVCC timestamps, Raft/Paxos leases (etcd, Consul, ZooKeeper), Kerberos ticket validity, Cassandra's last-write-wins conflict resolution, and TLS certificate `notBefore` checks. Those systems tolerate slewing fine. Hence the standard policy `makestep 1.0 3`: allow a step only during the first few updates after boot, never during steady-state operation.

**27.** Stratum is defined as *one more than the stratum of the server you synchronise to*: selecting a stratum-3 server makes this host stratum 4. Stratum 0 is the physical reference (atomic clock, GPS receiver), stratum 1 is a host directly attached to one, and the chain increments per hop up to 15. **Stratum 16 means unsynchronised** — a host that has no usable source, and whose time no client should trust. Seeing 16 in `ntpq`/`chronyc` output is the single clearest "this source is useless" signal.

**28.** The drift file stores the measured systematic frequency error of the local oscillator in ppm (e.g. `-13.483`, meaning the crystal runs ~13.5 microseconds slow per second ≈ 1.16 s/day). On the next start, `chronyd` applies that correction to the kernel **immediately**, before any network sample exists. With no network at all, the clock therefore drifts at the *residual* error (a fraction of a ppm) instead of the raw oscillator error — potentially a hundredfold improvement over hours or days of isolation. It also makes the post-boot convergence with network much faster, since the frequency is already right and only the offset needs correcting.

### Exercise 7

**29.** Stratum measures **distance from the reference clock in hops**, not **accuracy at your host**. NTP selects on *synchronization distance* — root delay, root dispersion, jitter and offset consistency — so a stratum-1 server 250 ms away across a congested asymmetric path is far worse than a stratum-3 server 9 ms away on a symmetric one. The stratum-1 server in the example was rejected as a clustering outlier with a `+12.345 ms` offset and `45.678 ms` delay. Practical consequence: prefer *nearby, well-connected, diverse* servers over low-stratum trophies, and always configure at least four sources so the falseticker algorithm has a majority to work with.

**30.** `.INIT.` means the association exists but no valid reply has ever been received — the peer is initialising or unreachable; it always accompanies `stratum 16` and `reach 0`. `.STEP.` means the peer's own clock was just stepped, so it is temporarily unusable. `.GPS.` and `.PPS.` are **reference clock identifiers** on a stratum-1 server: `.GPS.` = a GPS receiver providing time-of-day, `.PPS.` = a pulse-per-second signal providing precise phase (usually combined with a coarse time source). Other common ones: `.CDMA.`, `.DCFa.`, `.LOCL.` (the undisciplined local clock driver — a warning sign if it is your system peer).

**31.** Both fields say "we have never received a reply from this peer": `reach 0` = all eight polls in the shift register failed, `when -` = there is no "seconds since last packet received" because none was ever received. Single hypothesis: the request or the reply is not getting through — DNS resolved to a dead address, the host is unreachable, or UDP/123 is filtered. Step 39's `ss -lunp | grep :123` plus the firewall check tests the local side; `ntpdate -q <ip>` (step 37) tests the path end to end.

**32.** At boot the offset between the RTC-initialised clock and real time can be arbitrarily large — a dead CMOS battery gives you 1970 or 2000. `ntpd` has a **panic threshold of 1000 seconds** (`tinker panic`): if the offset exceeds it, `ntpd` logs a message telling the operator to set the clock manually and **exits**, on the reasoning that such an error is more likely a fault than a real correction. `-g` (`--panicgate`) allows exactly **one** step of any size, at the first update, after which the panic threshold applies normally. That is why distribution init files historically launched `ntpd -g`, and why `ntpd -gq` replaced `ntpdate`.

**33.** `restrict default kod nomodify notrap nopeer noquery limited` — specifically the `noquery` flag, which blocks mode 6/7 control queries (`ntpq`, `ntpdc`) while still allowing normal time service. It is the default because control queries expose internal state and, historically, because mode 7 `monlist` enabled massive amplification attacks (CVE-2013-5211). To permit monitoring from a specific host, add a narrower rule: `restrict 192.168.10.5 nomodify notrap` (no `noquery`), and consider `restrict source ...` for pool-learned peers.

**34.** With UDP there is no handshake, so an attacker can spoof the victim's source address and have your server send the reply to the victim — a **reflection** attack. If the reply is much larger than the request, it is also an **amplification** attack; `monlist` produced amplification factors in the hundreds. `noquery` removes those large control responses from the attack surface, and `limited`/`kod` enforce rate limiting with Kiss-o'-Death packets so ordinary time responses cannot be used as an amplifier either. This is why a default-deny `restrict default` line plus explicit `allow`/`restrict` exceptions is the only correct posture — the equivalent in `chrony` is that serving is off unless you write `allow`.

### Exercise 8

**35.** `makestep 1.0 3` means "step, rather than slew, if the offset exceeds 1.0 s — but only for the first **3 clock updates** after `chronyd` starts". Restarting `chronyd` in step 41 reset that counter, so the first update after start was within the allowance and a 777421-second (9-day) error was corrected by stepping. At the tenth update, stepping would no longer be permitted: `chronyd` would attempt to **slew** it, and at 500 ppm a 9-day error takes roughly 49 years to remove — in practice the daemon would log that the clock is wrong and the host would remain unsynchronised indefinitely. That is precisely why steady-state clock errors must be corrected with an explicit `chronyc makestep`, not by waiting.

**36.** `date` was wrong by exactly **the local UTC offset** — `+02:00` in Madrid in August, i.e. two hours fast (the local wall-clock digits were written into the RTC, then read back as though they were UTC, and the offset was added a second time). In `Etc/UTC` the offset is zero, so yes, the error would have been exactly zero — which is the reason this class of bug is invisible on UTC-configured servers and appears only on localised desktops and dual-boot machines.

**37.** A source with `Reach 0` has never delivered a valid sample, so `chronyd` has no data at all — the stratum column shows the initial/unknown value `0` as a placeholder, alongside the `?` state marker and the `+0ns` offsets. Real stratum 0 is a physical reference clock, and a *reference clock never appears as a network source row in `chronyc sources`* — it appears in `chronyc sources` only via a `refclock` directive with a `#` mode character. Read the whole row: `? / 0 / 0 / -` together mean "no contact", not "attached to a caesium standard".

**38.** NTP is a request/response protocol over UDP: the client sends a packet to the server's port 123 and correlates the reply by transmit timestamp. Dropping the outbound request means no reply can ever exist, so blocking the `output` hook alone is fully sufficient. For the reply to return through a stateful firewall, the connection-tracking entry for that UDP "flow" must be allowed — `nft`/`iptables` need `ct state established,related accept` on input (or `firewall-cmd --add-service=ntp` on the client side of a NAT). Note also that `chronyd` uses an ephemeral source port by default, while `ntpd` classically uses source port 123, which matters for rules written against ports rather than conntrack state.

**39.** Under `rtcsync` it is *usually* redundant, since the kernel copies the system clock to the RTC every 11 minutes once synchronised. It is **not** redundant when: (a) less than 11 minutes have elapsed since synchronisation — exactly the case after the 15-second `sleep` in step 45; (b) `rtcsync` is not configured, or you are on `systemd-timesyncd`, which has no equivalent directive; (c) `chronyd` is managing the RTC itself via `rtcfile`/`rtcautotrim` rather than delegating to the kernel; (d) you are about to force a power cut and cannot rely on a clean shutdown writing the RTC. Making it explicit costs one syscall and removes the doubt.

**40.**
```bash
timedatectl                    # both clocks, timezone, synchronized yes/no, which service
chronyc tracking               # (or: ntpq -pn) — the offset, the stratum, and the reference ID
chronyc sources -v             # (or: ntpq -pn) — which sources exist, which one is selected, reachability
```
`timedatectl` answers "is it correct and is anything maintaining it"; `tracking` answers "how wrong are we and against what reference"; `sources` answers "who says so, and do we have enough independent sources to trust the answer". If `timedatectl` reports `NTP service: n/a`, skip straight to `systemctl list-units '*chrony*' '*ntp*' '*timesync*'` to find out what, if anything, is installed.

</details>