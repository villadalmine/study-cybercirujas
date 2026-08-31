# LPIC-1 — Topic 107.2: Automate System Administration Tasks by Scheduling Jobs
## Guided Exercises

**Exam:** 102-500 (LPIC-1 v5.0), Topic 107
**Official objective list:** <https://www.lpi.org/our-certifications/exam-102-objectives/> (companion objective set for exam 101: <https://www.lpi.org/our-certifications/exam-101-objectives/>)

**Key files, terms and utilities exercised here:** `/etc/cron.{d,daily,hourly,monthly,weekly}`, `/etc/at.deny`, `/etc/at.allow`, `/etc/crontab`, `/etc/cron.allow`, `/etc/cron.deny`, `/var/spool/cron/`, `crontab`, `at`, `atq`, `atrm`, `systemctl`, `systemd-run`.

---

### Lab environment

These exercises **write to system files and schedule real jobs**. Use a disposable VM or container with systemd (Debian 12 / Ubuntu 22.04+ / Rocky 9 / openSUSE Leap all work). You need `root` (via `sudo`) and one unprivileged user.

Distro differences are called out inline. Where the text says `cron`, RHEL-family systems use the service name `crond` and the `cronie` implementation; Debian-family systems use the service `cron` and Vixie-derived `cron`. Both implement the same crontab syntax.

**Step 0 — prepare the environment. Run this before Exercise 1:**

```bash
# Identify the implementation and service name
if systemctl list-unit-files | grep -qE '^crond\.service'; then CRON=crond; else CRON=cron; fi
echo "Cron unit on this host: $CRON"

# Install what the lab needs (pick your family)
sudo apt-get update && sudo apt-get install -y cron at anacron util-linux   # Debian/Ubuntu
sudo dnf install -y cronie cronie-anacron at util-linux                      # RHEL/Rocky/Alma/Fedora

sudo systemctl enable --now "$CRON" atd
systemctl is-active "$CRON" atd

# Create the lab user used from Exercise 6 onward
sudo useradd -m -s /bin/bash lpicstudent 2>/dev/null || true

# A scratch directory for job output
sudo install -d -m 0777 /srv/lab107
```

Expected:

```
Cron unit on this host: cron
active
active
```

---

## Exercise 1 — The user crontab: where it lives and who owns it

**Steps**

1. Print your current user crontab. On a fresh account it does not exist yet:

   ```bash
   crontab -l
   ```

   ```
   no crontab for dalmine
   ```

2. Set a non-interactive editor and create a crontab. Using `crontab -e` (not an editor on the spool file directly) is the only supported path:

   ```bash
   export EDITOR=nano   # or: export EDITOR=vim
   crontab -e
   ```

   Enter exactly this content, then save and exit:

   ```crontab
   # Lab 107.2 — user crontab
   * * * * * date +\%FT\%T >> /srv/lab107/every-minute.log 2>&1
   ```

3. Confirm the installation message and re-read the crontab:

   ```bash
   crontab -l
   ```

   ```
   # Lab 107.2 — user crontab
   * * * * * date +\%FT\%T >> /srv/lab107/every-minute.log 2>&1
   ```

4. Find the on-disk spool file and inspect its metadata. **Do not edit it.**

   ```bash
   sudo ls -l /var/spool/cron/crontabs/"$USER"    # Debian/Ubuntu
   sudo ls -l /var/spool/cron/"$USER"             # RHEL/Rocky/Fedora
   ```

   Debian:

   ```
   -rw------- 1 dalmine crontab 226 Aug 27 18:41 /var/spool/cron/crontabs/dalmine
   ```

5. Wait ~90 seconds, then verify the job actually fired:

   ```bash
   sleep 90; cat /srv/lab107/every-minute.log
   ```

   ```
   2026-08-27T18:42:01
   2026-08-27T18:43:01
   ```

**Checkpoint questions — block A**

1. `crontab -e` did not open `/var/spool/cron/crontabs/dalmine` directly; it opened a temporary copy. Name **two** things `crontab` does when you save that editing a spool file by hand would skip.
2. The spool file is mode `0600`, owned by the user, group `crontab` (Debian). Why is the `crontab` command installed setgid rather than making the spool directory world-writable?
3. Which environment variable does `crontab -e` consult **first**, before `EDITOR`?

**Steps (continued)**

6. Back up the crontab to a regular file — this is the only safe pattern:

   ```bash
   crontab -l > ~/crontab.bak
   wc -l ~/crontab.bak
   ```

   ```
   2 /home/dalmine/crontab.bak
   ```

7. Look at the **danger pair** on your keyboard. Run `crontab -r`, then restore:

   ```bash
   crontab -r
   crontab -l
   crontab ~/crontab.bak
   crontab -l | head -1
   ```

   ```
   no crontab for dalmine
   # Lab 107.2 — user crontab
   ```

8. Inspect another user's crontab as root:

   ```bash
   sudo crontab -u lpicstudent -l
   ```

   ```
   no crontab for lpicstudent
   ```

**Checkpoint questions — block B**

4. `crontab -r` and `crontab -e` are one key apart and `-r` asks for no confirmation. Which option makes removal interactive?
5. What does `crontab ~/crontab.bak` do to an **existing** crontab — append or replace?
6. Write the command root uses to install `/root/jobs.cron` as the crontab of user `backup`.

---

## Exercise 2 — Field semantics, step values, and the day-of-month / day-of-week trap

**Steps**

1. Reopen your crontab and replace its contents with these entries. Read each comment before saving:

   ```crontab
   # min hour dom mon dow  command
   #  Every 5 minutes, all day
   */5 * * * *        echo "five" >> /srv/lab107/fields.log

   #  09:00 and 17:00, Monday to Friday
   0 9,17 * * 1-5     echo "office" >> /srv/lab107/fields.log

   #  Every 10 minutes between 22:00 and 23:59
   */10 22-23 * * *   echo "night" >> /srv/lab107/fields.log

   #  Every 2 hours on the half hour
   30 */2 * * *       echo "even-hours" >> /srv/lab107/fields.log

   #  THE TRAP: day-of-month AND day-of-week both restricted
   0 3 13 * 5         echo "trap" >> /srv/lab107/fields.log

   #  Special string form
   @reboot            echo "booted $(date)" >> /srv/lab107/boot.log
   ```

2. Verify the ranges each field accepts by deliberately submitting an invalid one:

   ```bash
   echo '0 25 * * * /bin/true' | crontab -
   ```

   ```
   "-":1: bad hour
   errors in crontab file, can't install.
   ```

   The old crontab survives — installation is atomic.

3. Test whether names may be combined with ranges (this is implementation-defined and a favourite exam detail):

   ```bash
   crontab -l > /tmp/keep.cron
   echo '0 4 * * mon-fri /bin/true' | crontab -
   crontab -l | tail -1
   crontab /tmp/keep.cron
   ```

   On Debian's Vixie cron and on cronie this is accepted in recent versions; the historical Vixie `crontab(5)` states ranges and lists of *names* are not allowed. Portable crontabs use numbers.

**Checkpoint questions — block C**

7. Give the numeric range of each of the five time fields, in order. Which single value appears **twice** with two meanings, and what are they?
8. The entry `0 3 13 * 5` — on which days does it run: only Friday the 13th, or every 13th **and** every Friday? State the rule that decides it.
9. Rewrite `0 3 13 * 5` so it runs **only** on Friday the 13th, using a shell test in the command field.
10. Translate to crontab syntax: *"every 15 minutes during the first hour of every quarter's first month"* — i.e. minutes 0,15,30,45 of hour 0 on day 1 of January, April, July and October.
11. Which special string is equivalent to `0 0 * * 0`? Which one has no time-field equivalent at all, and why?

---

## Exercise 3 — The cron execution environment: the number-one cause of "it works in my shell"

**Steps**

1. Capture the exact environment cron gives a job:

   ```bash
   ( crontab -l; echo '* * * * * { env; echo "---"; id; } > /srv/lab107/cronenv.txt 2>&1' ) | crontab -
   sleep 70
   cat /srv/lab107/cronenv.txt
   ```

   ```
   SHELL=/bin/sh
   PWD=/home/dalmine
   LOGNAME=dalmine
   HOME=/home/dalmine
   PATH=/usr/bin:/bin
   ---
   uid=1000(dalmine) gid=1000(dalmine) groups=1000(dalmine)
   ```

2. Compare with your interactive shell:

   ```bash
   echo "$PATH"; echo "$SHELL"
   ```

   ```
   /home/dalmine/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
   /bin/bash
   ```

3. Prove the failure mode. Create a script in a directory that is **not** on cron's `PATH`:

   ```bash
   mkdir -p ~/bin
   printf '#!/bin/sh\necho "ran at $(date)" >> /srv/lab107/mybin.log\n' > ~/bin/labjob
   chmod +x ~/bin/labjob
   labjob && echo "works interactively"
   ( crontab -l; echo '* * * * * labjob' ) | crontab -
   sleep 70
   cat /srv/lab107/mybin.log
   ```

   ```
   works interactively
   ran at Thu Aug 27 18:55:01 -03 2026     <- only the interactive run
   ```

4. Read the failure in the log:

   ```bash
   journalctl -t CRON --since "-3 min" | tail -5        # Debian
   journalctl -t CROND --since "-3 min" | tail -5       # RHEL
   ```

   ```
   Aug 27 18:56:01 lab CRON[4412]: (dalmine) CMD (labjob)
   Aug 27 18:56:01 lab CRON[4411]: (dalmine) MAIL (mailed 1 byte of output; but got status 0x004b...)
   ```

5. Fix it three different ways. Replace the crontab with:

   ```crontab
   SHELL=/bin/bash
   PATH=/usr/local/bin:/usr/bin:/bin:/home/dalmine/bin
   MAILTO=""

   # 1. PATH set above
   * * * * * labjob
   # 2. Absolute path — always correct, needs no variable
   * * * * * /home/dalmine/bin/labjob
   # 3. Explicit login shell if the job genuinely needs your profile
   * * * * * /bin/bash -lc 'labjob'
   ```

6. Demonstrate the percent sign. Install this and observe the result:

   ```bash
   ( crontab -l; echo '* * * * * date +%F > /srv/lab107/pct.log' ) | crontab -
   sleep 70; cat /srv/lab107/pct.log
   ```

   ```
   (empty file)
   ```

   Now escape it:

   ```bash
   crontab -l | sed 's|date +%F|date +\\%F|' | crontab -
   sleep 70; cat /srv/lab107/pct.log
   ```

   ```
   2026-08-27
   ```

**Checkpoint questions — block D**

12. Cron sets only a handful of variables. Which four does it define for a user job, and which of them comes from `/etc/passwd`?
13. Your job runs `mysqldump` and fails with `command not found`, yet it works when you type it. Give two fixes and say which one you would put in a production crontab and why.
14. Explain precisely what cron did to `date +%F > /srv/lab107/pct.log`. What is the general rule for `%` in the command field, and how do you get a literal one?
15. `MAILTO=""` versus omitting `MAILTO` entirely versus `MAILTO=ops@example.com` — describe the behaviour of each, and state what happens to job output on a host with no MTA installed.
16. A crontab variable assignment placed *after* an entry — does it affect that entry? Where must `PATH=` appear?

---

## Exercise 4 — System crontabs: `/etc/crontab`, `/etc/cron.d`, and the `run-parts` directories

**Steps**

1. Read the system crontab and note the extra column:

   ```bash
   cat /etc/crontab
   ```

   Debian:

   ```
   SHELL=/bin/sh
   PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

   17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
   25 6    * * *   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.daily; }
   47 6    * * 7   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.weekly; }
   52 6    1 * *   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.monthly; }
   ```

2. Create a drop-in in `/etc/cron.d` — the correct place for package- and configuration-managed jobs:

   ```bash
   sudo tee /etc/cron.d/lab107-report >/dev/null <<'EOF'
   # Lab 107.2 — system drop-in; note the user field in position 6
   SHELL=/bin/bash
   PATH=/usr/local/bin:/usr/bin:/bin
   MAILTO=root

   */2 * * * *   lpicstudent   id -un >> /srv/lab107/dropin.log 2>&1
   EOF
   sudo chmod 0644 /etc/cron.d/lab107-report
   sleep 130
   cat /srv/lab107/dropin.log
   ```

   ```
   lpicstudent
   ```

3. Now break it on purpose, the way real deployments break it:

   ```bash
   sudo mv /etc/cron.d/lab107-report /etc/cron.d/lab107-report.conf
   sudo truncate -s 0 /srv/lab107/dropin.log
   sleep 130
   cat /srv/lab107/dropin.log
   ```

   ```
   (empty)
   ```

   Restore:

   ```bash
   sudo mv /etc/cron.d/lab107-report.conf /etc/cron.d/lab107-report
   ```

4. Add a `run-parts` script and observe the second naming rule:

   ```bash
   sudo tee /etc/cron.hourly/lab107-hourly.sh >/dev/null <<'EOF'
   #!/bin/sh
   echo "hourly $(date -Is)" >> /srv/lab107/hourly.log
   EOF
   sudo chmod +x /etc/cron.hourly/lab107-hourly.sh
   run-parts --test /etc/cron.hourly
   ```

   ```
   /etc/cron.hourly/0anacron
   /etc/cron.hourly/logrotate
   ```

   Your script is absent. Rename it and re-test:

   ```bash
   sudo mv /etc/cron.hourly/lab107-hourly.sh /etc/cron.hourly/lab107-hourly
   run-parts --test /etc/cron.hourly
   ```

   ```
   /etc/cron.hourly/0anacron
   /etc/cron.hourly/lab107-hourly
   /etc/cron.hourly/logrotate
   ```

5. Confirm the executable-bit requirement:

   ```bash
   sudo chmod -x /etc/cron.hourly/lab107-hourly
   run-parts --test /etc/cron.hourly | grep lab107 || echo "skipped: not executable"
   sudo chmod +x /etc/cron.hourly/lab107-hourly
   ```

   ```
   skipped: not executable
   ```

**Checkpoint questions — block E**

17. State the single structural difference between a line in `/etc/crontab` and a line in a user crontab, and explain why that difference exists.
18. Your `/etc/cron.d/lab107-report.conf` never ran. Give the rule about file naming in `/etc/cron.d`, and give the *different but related* rule `run-parts` applies to `/etc/cron.daily`.
19. Besides the name, list two other conditions a file in `/etc/cron.hourly` must satisfy to be executed.
20. You edited `/etc/cron.d/lab107-report`. Do you need to restart or reload the cron daemon? Justify your answer in terms of how cron detects changes to (a) `/etc/cron.d`, (b) `/etc/crontab`, and (c) user spool files.
21. A job must run as `www-data` every night. Compare putting it in `/etc/cron.d` versus `crontab -u www-data -e` — give one operational advantage of each.

---

## Exercise 5 — `anacron`: jobs that survive a powered-off machine

**Steps**

1. Read the configuration and note that the format is **not** crontab format:

   ```bash
   cat /etc/anacrontab
   ```

   ```
   SHELL=/bin/sh
   PATH=/sbin:/bin:/usr/sbin:/usr/bin
   MAILTO=root
   RANDOM_DELAY=45
   START_HOURS_RANGE=3-22

   #period in days   delay in minutes   job-identifier   command
   1         5       cron.daily        nice run-parts /etc/cron.daily
   7         25      cron.weekly       nice run-parts /etc/cron.weekly
   @monthly  45      cron.monthly      nice run-parts /etc/cron.monthly
   ```

2. Inspect the state directory that makes anacron work:

   ```bash
   sudo ls -l /var/spool/anacron/
   sudo cat /var/spool/anacron/cron.daily
   ```

   ```
   -rw------- 1 root root 9 Aug 27 07:31 cron.daily
   -rw------- 1 root root 9 Aug 24 07:35 cron.weekly
   -rw------- 1 root root 9 Aug  1 07:12 cron.monthly
   20260827
   ```

3. Add your own anacron job and validate the file before trusting it:

   ```bash
   sudo cp /etc/anacrontab /etc/anacrontab.bak
   echo -e '1\t10\tlab107.daily\t/bin/sh -c "echo anacron-ran $(date -Is) >> /srv/lab107/anacron.log"' \
     | sudo tee -a /etc/anacrontab >/dev/null
   sudo anacron -T && echo "anacrontab syntax OK"
   ```

   ```
   anacrontab syntax OK
   ```

4. Force the job to run now, ignoring both the timestamp and the delay:

   ```bash
   sudo anacron -d -f -n lab107.daily
   ```

   ```
   Anacron 2.3 started on 2026-08-27
   Will run job `lab107.daily' in 0 min.
   Jobs will be executed sequentially
   Job `lab107.daily' started
   Job `lab107.daily' terminated
   Normal exit (1 job run)
   ```

   ```bash
   cat /srv/lab107/anacron.log; sudo cat /var/spool/anacron/lab107.daily
   ```

   ```
   anacron-ran 2026-08-27T19:14:02-03:00
   20260827
   ```

5. Run it again immediately and observe idempotency at the daily granularity:

   ```bash
   sudo anacron -d lab107.daily
   ```

   ```
   Anacron 2.3 started on 2026-08-27
   Normal exit (0 jobs run)
   ```

6. See how anacron is triggered on your distro:

   ```bash
   cat /etc/cron.hourly/0anacron 2>/dev/null | head -20
   systemctl list-timers anacron.timer 2>/dev/null
   ```

7. Clean up:

   ```bash
   sudo cp /etc/anacrontab.bak /etc/anacrontab
   sudo rm -f /var/spool/anacron/lab107.daily
   ```

**Checkpoint questions — block F**

22. Describe the four fields of an `/etc/anacrontab` job line, in order, including the unit of each of the first two.
23. A laptop is switched off from 06:00 to 10:00 every day. The entry `25 6 * * * root run-parts /etc/cron.daily` never runs. Explain, mechanically, what anacron does differently — and name the exact file it consults to decide.
24. What is the smallest period anacron can express, and what does that tell you about when *not* to use it?
25. What do `RANDOM_DELAY` and `START_HOURS_RANGE` control, and why would a fleet of 500 VMs care about the first one?
26. On a stock Debian system, why does `/etc/crontab` wrap the daily `run-parts` call in `test -x /usr/sbin/anacron || { ...; }`?
27. Which anacron options mean respectively: *test the config file*, *run now with no delay*, *force regardless of timestamp*, and *update timestamps without running*?

---

## Exercise 6 — Access control: `cron.allow` and `cron.deny`

**Steps**

1. Establish the baseline. On most systems neither file, or only an empty `cron.deny`, is present:

   ```bash
   ls -l /etc/cron.allow /etc/cron.deny 2>&1
   ```

   Debian:

   ```
   ls: cannot access '/etc/cron.allow': No such file or directory
   ls: cannot access '/etc/cron.deny': No such file or directory
   ```

   RHEL:

   ```
   ls: cannot access '/etc/cron.allow': No such file or directory
   -rw-r--r-- 1 root root 0 Jun  9 12:44 /etc/cron.deny
   ```

2. Confirm the lab user can currently schedule:

   ```bash
   sudo -u lpicstudent bash -c 'echo "0 4 * * * /bin/true" | crontab -' && echo OK
   sudo -u lpicstudent crontab -l
   ```

   ```
   OK
   0 4 * * * /bin/true
   ```

3. Deny that one user:

   ```bash
   echo lpicstudent | sudo tee -a /etc/cron.deny >/dev/null
   sudo -u lpicstudent crontab -l
   ```

   ```
   You (lpicstudent) are not allowed to use this program (crontab)
   See crontab(1) for more information
   ```

4. Now add an allow-list and watch it take precedence:

   ```bash
   printf 'root\nlpicstudent\n' | sudo tee /etc/cron.allow >/dev/null
   sudo chmod 0600 /etc/cron.allow
   sudo -u lpicstudent crontab -l
   ```

   ```
   0 4 * * * /bin/true
   ```

   The user is listed in **both** files and is allowed.

5. Test a third user against the allow-list:

   ```bash
   sudo useradd -m thirduser 2>/dev/null
   sudo -u thirduser crontab -l
   ```

   ```
   You (thirduser) are not allowed to use this program (crontab)
   ```

6. Verify that access control does **not** apply to root:

   ```bash
   sudo crontab -l >/dev/null; echo "root exit status: $?"
   ```

7. Clean up:

   ```bash
   sudo rm -f /etc/cron.allow
   sudo sed -i '/^lpicstudent$/d' /etc/cron.deny 2>/dev/null
   sudo -u lpicstudent crontab -r
   ```

**Checkpoint questions — block G**

28. State the decision algorithm `crontab(1)` follows, in order, given the possible presence of `/etc/cron.allow` and `/etc/cron.deny`.
29. Both files exist and `alice` appears in both. May she run `crontab -e`? Why?
30. Neither file exists. Is the outcome the same on Debian and on RHEL? What does the manual page say about this case?
31. `/etc/cron.deny` is deleted from a Debian host that had it. Does the set of users who may schedule jobs grow, shrink, or stay the same?
32. Does adding `bob` to `/etc/cron.deny` stop his **already installed** crontab from running? Explain what the file actually gates.
33. What is the equivalent pair of files for the `at` subsystem, and does the same precedence rule apply?

---

## Exercise 7 — One-shot scheduling with `at` and `batch`

**Steps**

1. Confirm the daemon is running — `at` without `atd` silently accumulates jobs that never fire:

   ```bash
   systemctl is-active atd && ls -ld /var/spool/cron/atjobs 2>/dev/null || ls -ld /var/spool/at
   ```

2. Queue a job with a here-doc and read the confirmation carefully:

   ```bash
   at now + 2 minutes <<'EOF'
   echo "at job ran at $(date -Is)" >> /srv/lab107/at.log
   EOF
   ```

   ```
   warning: commands will be executed using /bin/sh
   job 3 at Thu Aug 27 19:31:00 2026
   ```

3. List, inspect, and understand what `at` actually stored:

   ```bash
   atq
   at -c 3 | head -5
   at -c 3 | tail -5
   ```

   ```
   3	Thu Aug 27 19:31:00 2026 a dalmine
   ```

   ```
   #!/bin/sh
   # atrun uid=1000 gid=1000
   # mail dalmine 0
   umask 0022
   XDG_SESSION_ID=41; export XDG_SESSION_ID
   ...
   cd /home/dalmine || {
   	 echo 'Execution directory inaccessible' >&2
   	 exit 1
   }
   echo "at job ran at 2026-08-27T19:29:14-03:00" >> /srv/lab107/at.log
   ```

4. Queue several jobs using the different time formats, then remove one:

   ```bash
   at teatime      <<< 'echo tea   >> /srv/lab107/at.log'
   at midnight     <<< 'echo mid   >> /srv/lab107/at.log'
   at 09:00 tomorrow <<< 'echo tmrw >> /srv/lab107/at.log'
   at 2026-12-24 18:30 <<< 'echo xmas >> /srv/lab107/at.log'
   atq
   ```

   ```
   4	Thu Aug 27 16:00:00 2026 a dalmine
   5	Fri Aug 28 00:00:00 2026 a dalmine
   6	Fri Aug 28 09:00:00 2026 a dalmine
   7	Thu Dec 24 18:30:00 2026 a dalmine
   ```

   ```bash
   atrm 4
   atq | wc -l
   ```

5. Use `batch` and compare the queue letter:

   ```bash
   batch <<< 'echo "batch ran $(date -Is)" >> /srv/lab107/at.log'
   atq
   ```

   ```
   warning: commands will be executed using /bin/sh
   job 8 at Thu Aug 27 19:30:00 2026
   8	Thu Aug 27 19:30:00 2026 b dalmine
   ```

6. Verify the `at` output-delivery model:

   ```bash
   at now + 1 minute <<< 'echo "this goes to mail, not to a terminal"'
   sleep 70
   journalctl -u atd --since "-3 min" | tail -3
   ```

7. Clean up remaining jobs:

   ```bash
   atq | awk '{print $1}' | xargs -r atrm
   atq
   ```

**Checkpoint questions — block H**

34. `at` printed *"warning: commands will be executed using /bin/sh"*. Which shell will actually run your job, and where does `at` record the environment it will restore?
35. Name the three commands that list, delete and read back an `at` job, and give the equivalent `at` options for the first two.
36. What is the functional difference between `at now` and `batch`? Name the condition `batch` waits for and the queue letter it uses.
37. Your `at` job produced output but you never saw it. Where did it go? Which `at` option forces mail even when there is no output?
38. Convert to `at` time syntax: *17:45 today*, *four hours from now*, *the next 3rd of the month at 02:00*.
39. `atd` was stopped for six hours; during that time three `at` jobs came due. What happens when `atd` starts again — are they lost, run immediately, or rescheduled?
40. State the one-line difference in purpose between `cron` and `at` that decides which you choose.

---

## Exercise 8 — systemd timers: the modern equivalent

**Steps**

1. Look at what already exists on the host:

   ```bash
   systemctl list-timers --all | head -8
   ```

   ```
   NEXT                        LEFT     LAST                        PASSED  UNIT                   ACTIVATES
   Thu 2026-08-27 20:00:00 -03 22min    Thu 2026-08-27 19:00:12 -03 37min   anacron.timer          anacron.service
   Fri 2026-08-28 00:00:00 -03 4h 22min Thu 2026-08-27 00:00:11 -03 19h ago logrotate.timer        logrotate.service
   Fri 2026-08-28 06:12:41 -03 10h      Thu 2026-08-27 06:11:03 -03 13h ago man-db.timer           man-db.service
   ```

2. Build a timer + service pair. **Both units are required**; the timer only activates something else:

   ```bash
   sudo tee /etc/systemd/system/lab107.service >/dev/null <<'EOF'
   [Unit]
   Description=Lab 107.2 scheduled job

   [Service]
   Type=oneshot
   User=lpicstudent
   ExecStart=/bin/sh -c 'echo "timer ran $(date -Is)" >> /srv/lab107/timer.log'
   EOF

   sudo tee /etc/systemd/system/lab107.timer >/dev/null <<'EOF'
   [Unit]
   Description=Run lab107.service every 2 minutes

   [Timer]
   OnCalendar=*:0/2
   Persistent=true
   AccuracySec=1s
   Unit=lab107.service

   [Install]
   WantedBy=timers.target
   EOF

   sudo systemctl daemon-reload
   sudo systemctl enable --now lab107.timer
   ```

3. Verify it is armed, then confirm it fires:

   ```bash
   systemctl list-timers lab107.timer
   ```

   ```
   NEXT                        LEFT LAST                        PASSED UNIT          ACTIVATES
   Thu 2026-08-27 19:38:00 -03 41s  Thu 2026-08-27 19:36:00 -03 1min   lab107.timer  lab107.service
   ```

   ```bash
   sleep 130; cat /srv/lab107/timer.log
   journalctl -u lab107.service --since "-5 min" -o short
   ```

4. Learn the calendar syntax by asking systemd instead of guessing:

   ```bash
   systemd-analyze calendar "Mon *-*-* 04:00:00"
   ```

   ```
     Original form: Mon *-*-* 04:00:00
   Normalized form: Mon *-*-* 04:00:00
       Next elapse: Mon 2026-08-31 04:00:00 -03
          (in UTC): Mon 2026-08-31 07:00:00 UTC
          From now: 3 days left
   ```

   ```bash
   systemd-analyze calendar --iterations=3 "*-*-01 02:30"
   systemd-analyze calendar daily weekly "Mon..Fri 09,17:00"
   systemd-analyze calendar "Fri *-*-13 03:00"
   ```

5. Create a **transient** timer with no unit files at all — the closest systemd analogue of `at`:

   ```bash
   sudo systemd-run --on-active=90s --unit=lab107-oneshot \
     /bin/sh -c 'echo "transient $(date -Is)" >> /srv/lab107/timer.log'
   systemctl list-timers lab107-oneshot.timer
   sleep 100
   tail -2 /srv/lab107/timer.log
   ```

   ```
   Running timer as unit: lab107-oneshot.timer
   Will run service as unit: lab107-oneshot.service
   ```

6. Inspect the persistence state that makes `Persistent=true` work:

   ```bash
   sudo ls -l /var/lib/systemd/timers/
   ```

   ```
   -rw-r--r-- 1 root root 0 Aug 27 19:38 stamp-lab107.timer
   -rw-r--r-- 1 root root 0 Aug 27 00:00 stamp-logrotate.timer
   ```

7. Clean up:

   ```bash
   sudo systemctl disable --now lab107.timer
   sudo rm -f /etc/systemd/system/lab107.{timer,service}
   sudo systemctl daemon-reload
   ```

**Checkpoint questions — block I**

41. A systemd timer needs how many unit files, minimum, and what is the default naming convention that lets you omit `Unit=`?
42. Which `[Timer]` directive is the anacron equivalent, what does it require to be meaningful, and which directory holds the state it depends on?
43. Distinguish `OnCalendar=`, `OnBootSec=`, `OnUnitActiveSec=` and `OnActiveSec=` in one sentence each.
44. You wrote `OnCalendar=Fri *-*-13 03:00`. What does it match — and how do you confirm without waiting?
45. Your timer never fires. List, in order, the four commands you run to diagnose it.
46. Give the `systemd-run` command that runs `/usr/local/bin/report` once, 30 minutes from now.
47. Name two capabilities a systemd timer has that a crontab entry does not.

---

## Exercise 9 — Production hygiene: overlap, locking, and log-based diagnosis

**Steps**

1. Create a job that takes longer than its own interval:

   ```bash
   printf '#!/bin/sh\necho "start $$ $(date -Is)" >> /srv/lab107/overlap.log\nsleep 150\necho "end   $$ $(date -Is)" >> /srv/lab107/overlap.log\n' | sudo tee /usr/local/bin/slowjob >/dev/null
   sudo chmod +x /usr/local/bin/slowjob
   ( crontab -l 2>/dev/null; echo '* * * * * /usr/local/bin/slowjob' ) | crontab -
   sleep 200
   cat /srv/lab107/overlap.log
   ```

   ```
   start 5120 2026-08-27T19:50:01-03:00
   start 5188 2026-08-27T19:51:01-03:00
   start 5241 2026-08-27T19:52:01-03:00
   end   5120 2026-08-27T19:52:31-03:00
   ```

   Three copies are running concurrently. Cron does **not** serialise.

2. Fix it with `flock` — the standard, distro-independent answer:

   ```bash
   crontab -l | sed 's|^\* \* \* \* \* /usr/local/bin/slowjob|* * * * * /usr/bin/flock -n /var/lock/slowjob.lock /usr/local/bin/slowjob|' | crontab -
   crontab -l | tail -1
   sudo truncate -s 0 /srv/lab107/overlap.log
   sleep 200
   cat /srv/lab107/overlap.log
   ```

   ```
   * * * * * /usr/bin/flock -n /var/lock/slowjob.lock /usr/local/bin/slowjob
   start 5602 2026-08-27T19:56:01-03:00
   end   5602 2026-08-27T19:58:31-03:00
   start 5771 2026-08-27T19:59:01-03:00
   ```

3. Practise reading the logs for each subsystem:

   ```bash
   journalctl -u cron --since "-15 min" --no-pager | tail        # or -u crond
   journalctl -t CRON --since "-15 min" | tail
   journalctl -u atd --since today | tail -5
   journalctl -u lab107.service -n 20 --no-pager
   grep -iE 'cron|anacron' /var/log/syslog | tail   # systems still using rsyslog
   ```

4. Note what the log does **not** contain — job *output*:

   ```bash
   ( crontab -l; echo '* * * * * echo "stdout line"; echo "stderr line" >&2' ) | crontab -
   sleep 70
   journalctl -t CRON --since "-2 min" | grep -c 'stdout line' || echo "0 — output is not in the journal"
   ```

5. Full teardown of the entire lab:

   ```bash
   crontab -r
   sudo rm -f /etc/cron.d/lab107-report /etc/cron.hourly/lab107-hourly /usr/local/bin/slowjob
   sudo rm -rf /srv/lab107 /var/lock/slowjob.lock
   atq | awk '{print $1}' | xargs -r atrm
   sudo userdel -r lpicstudent 2>/dev/null; sudo userdel -r thirduser 2>/dev/null
   ```

**Checkpoint questions — block J**

48. A job scheduled `* * * * *` takes 150 seconds. How many instances run simultaneously at steady state, and why does cron allow that?
49. Explain what `flock -n /var/lock/job.lock cmd` does. What changes if you drop `-n`? What does `-w 30` add?
50. Which journal identifier shows cron *invocations*, and which unit shows the daemon's own messages? Write both `journalctl` commands.
51. Cron logged `CMD (/usr/local/bin/backup)` but the backup did not happen and you have no email. Give three concrete ways to capture what the job printed.
52. Rewrite `0 2 * * * /usr/local/bin/backup` so that stdout and stderr are both appended to `/var/log/backup.log` with no mail.

---

## Synthesis task

Without looking back, implement all of the following on your lab host and verify each one:

1. A job that runs as `postgres` every 20 minutes, only Monday–Friday, only between 08:00 and 20:00, logging to `/var/log/pgcheck.log`, delivered as a system drop-in file.
2. The same job, guaranteed to run once per day even if the host is powered off at the scheduled time — using `anacron`.
3. The same job as a systemd timer with catch-up semantics and a 5-minute random spread.
4. A one-shot job that runs `/usr/local/bin/migrate` at 03:00 next Sunday, expressed twice: once with `at`, once with `systemd-run`.
5. Configuration that permits only `root` and `postgres` to install crontabs.

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every block</summary>

### Block A — the user crontab

**1.** On save, `crontab` (a) **validates the syntax** and refuses to install a file with a bad field, leaving the previous crontab intact; and (b) **installs the file atomically into the spool with the correct owner, group and mode**, then signals/marks the spool so the daemon re-reads it. Editing `/var/spool/cron/crontabs/<user>` by hand can produce a syntactically invalid crontab, wrong ownership (which makes cron refuse the file entirely), and — on implementations that rely on the spool directory mtime — a change the daemon may not notice. `crontab -e` is the only supported interface.

**2.** Because the spool must be writable *only* through the validating program. A world-writable spool would let any user drop an arbitrary file named after another user, or corrupt an existing one. Making `crontab` setgid `crontab` (Debian) / setuid (cronie) means the *program* holds the privilege, so every write passes through validation and ownership enforcement.

**3.** `VISUAL`. The order is `VISUAL`, then `EDITOR`, then a compiled-in default (`/usr/bin/editor` on Debian, `vi` elsewhere).

### Block B — backup and restore

**4.** `crontab -i -r` prompts before deleting. Many administrators alias `crontab` to `crontab -i` for exactly this reason.

**5.** It **replaces**. `crontab <file>` installs `<file>` as the *entire* crontab, discarding what was there. To append safely: `crontab -l > /tmp/c && echo 'new line' >> /tmp/c && crontab /tmp/c`, or the pipeline used throughout this lab: `( crontab -l; echo 'new line' ) | crontab -`.

**6.** `crontab -u backup /root/jobs.cron`

### Block C — fields

**7.**

| Position | Field | Range |
|---|---|---|
| 1 | minute | 0–59 |
| 2 | hour | 0–23 |
| 3 | day of month | 1–31 |
| 4 | month | 1–12 (or `jan`–`dec`) |
| 5 | day of week | 0–7 (or `sun`–`sat`) |

The duplicated value is **`0` and `7` in the day-of-week field: both mean Sunday**. (Strictly, the repeated *meaning* is Sunday; `0` is the POSIX value and `7` is a Vixie extension for people who count Monday as day 1.)

**8.** It runs on **every 13th of the month AND every Friday** — roughly 16 times a month, not once a year. The rule: *when both the day-of-month and day-of-week fields are restricted (neither is `*`), cron uses logical **OR** — the command runs if either field matches.* When one of them is `*`, the normal AND applies across all five fields. This asymmetry is the single most-tested detail of the crontab format.

**9.**
```crontab
0 3 13 * *   [ "$(date +\%u)" = "5" ] && /path/to/command
```
The date field restricts to the 13th (day-of-week is `*`, so AND applies), and the shell test filters for Friday. `%u` must be escaped as `\%u` in a crontab.

**10.** `0,15,30,45 0 1 1,4,7,10 *` — equivalently `*/15 0 1 */3 *`. Note that `*/3` in the month field means months 1, 4, 7, 10 because stepping starts at the low end of the range.

**11.** `@weekly` ≡ `0 0 * * 0`. **`@reboot`** has no time-field equivalent: it is not a point in time at all — it means *once, when the cron daemon starts*, which the five-field grammar cannot express. (Full set: `@reboot`, `@yearly`/`@annually` = `0 0 1 1 *`, `@monthly` = `0 0 1 * *`, `@weekly` = `0 0 * * 0`, `@daily`/`@midnight` = `0 0 * * *`, `@hourly` = `0 * * * *`.)

### Block D — the cron environment

**12.** `SHELL` (default `/bin/sh`), `PATH` (default `/usr/bin:/bin` for user crontabs), `HOME`, and `LOGNAME` (plus `MAILTO` if set). **`HOME` and `LOGNAME` come from the user's `/etc/passwd` entry** and cannot be overridden meaningfully for the purpose of running the job. Crucially, cron does **not** read `/etc/profile`, `~/.bash_profile` or `~/.bashrc` — it is not a login shell.

**13.** Fixes: (a) call it by absolute path — `/usr/bin/mysqldump`; (b) set `PATH=` at the top of the crontab; (c) wrap in `/bin/bash -lc '...'` to source login files. **Use the absolute path in production**: it has no dependency on crontab-wide state, cannot be broken by someone reordering the file, and documents exactly which binary runs. Option (c) is the worst — it makes the job's behaviour depend on interactive dotfiles that change without review.

**14.** Cron treats `%` in the command field as a **newline**: everything after the *first* unescaped `%` becomes **standard input to the command**, and further `%` characters are additional input newlines. So cron ran `date +` (which errors) and fed `F > /srv/lab107/pct.log` to it on stdin — the redirection never existed, hence the empty file created by your shell earlier. Escape it as `\%` for a literal percent sign. This is why `date +\%F` is the canonical crontab idiom, and it is also a deliberate feature: `0 5 * * * mail -s report ops%Line one%Line two` supplies the body on stdin.

**15.**
- `MAILTO=""` — mail is **disabled**; job output is discarded.
- `MAILTO` omitted — output is mailed to the **crontab owner** (for `/etc/cron.d` and `/etc/crontab`, to the user in the sixth field).
- `MAILTO=ops@example.com` — output is mailed there instead.

With **no MTA installed**, cron cannot deliver: the output is **lost** and the journal records a delivery failure such as `MAIL (mailed N bytes of output but got status 0x0001)`. Never rely on mail for job output on a minimal host — redirect to a file or to `logger`.

**16.** A variable assignment affects only the entries **below** it; cron parses the file top to bottom. `PATH=`, `SHELL=` and `MAILTO=` must appear **before** the entries they should govern — conventionally at the top of the file. (`CRON_TZ=` in Vixie/cronie behaves the same way and changes the timezone used to interpret the following time specifications.)

### Block E — system crontabs

**17.** A system crontab line has a **sixth field, the username**, between the day-of-week field and the command: `min hour dom mon dow user command`. It exists because `/etc/crontab` and `/etc/cron.d` are single files owned by root that must be able to schedule work for *any* account — there is no owning user implied by the file's location, as there is for a spool file named after its owner.

**18.** In **`/etc/cron.d`**, cron ignores files whose names contain a **dot** (and, on Debian, anything outside `[A-Za-z0-9_-]`). `lab107-report.conf` was therefore never parsed. The related rule for **`run-parts`** directories (`/etc/cron.daily` etc.) is the same in effect but different in mechanism: `run-parts` by default only executes files whose names consist of `[A-Za-z0-9_-]` — so `.sh`, `.dpkg-dist`, `.rpmsave` and backup files are skipped. This is a *safety feature*: it prevents a package manager's leftover `.rpmnew`/`.dpkg-old` file from running alongside the real one.

**19.** It must be (a) **executable** (`chmod +x`), and (b) a **regular file, not a directory**, and readable/executable by root. (A useful third: `run-parts --test` lists what would run without running it — use it before trusting a new script.)

**20.** **No restart is needed in any of the three cases.** Cron wakes once per minute and checks modification times: (a) it stats **`/etc/cron.d`** and reloads changed drop-ins; (b) it stats **`/etc/crontab`** and re-reads it when the mtime changes; (c) it detects **user spool** changes because `crontab(1)` updates the spool directory's mtime on install. The only situation requiring `systemctl reload cron` is a crontab written into the spool by hand, bypassing `crontab(1)` — which you should not do.

**21.**
- `/etc/cron.d`: the file is **configuration-manageable** — it can be shipped by a package, templated by Ansible/Puppet, version-controlled, reviewed in a diff, and removed cleanly by uninstalling the package. It also survives deletion of the user's spool.
- `crontab -u www-data -e`: the job is **owned by and visible to the account it belongs to**, `crontab -l` shows the complete picture for that user, and it does not require root to inspect or modify. It also travels with a user-migration that copies spools.

In practice, anything managed by automation goes in `/etc/cron.d`; ad-hoc user work goes in a user crontab.

### Block F — anacron

**22.** `period  delay  job-identifier  command`

| Field | Meaning | Unit |
|---|---|---|
| 1 | period | **days** (or `@daily`, `@weekly`, `@monthly`, `@yearly`) |
| 2 | delay | **minutes** to wait after anacron starts before running this job |
| 3 | job-identifier | unique name; also the filename of the timestamp in `/var/spool/anacron/` |
| 4 | command | the command to run (may contain spaces) |

**23.** Cron is a **wall-clock scheduler**: 06:25 passes while the machine is off, so the moment is simply missed and never revisited. Anacron is an **elapsed-days scheduler**: when it starts (at boot, or hourly via `/etc/cron.hourly/0anacron`, or via `anacron.timer`), it compares today's date against the timestamp in **`/var/spool/anacron/<job-identifier>`** — a file containing a single `YYYYMMDD` date. If `today − timestamp ≥ period`, it waits `delay` minutes and runs the job, then writes today's date into that file.

**24.** **One day.** Anacron cannot express anything sub-daily, so it is the wrong tool for anything that must run hourly or every few minutes — use cron or a systemd timer for those. Anacron exists for maintenance work (`logrotate`, `updatedb`, `man-db`, package cleanup) on machines with unpredictable uptime: laptops, desktops, VMs that are suspended.

**25.** `RANDOM_DELAY` is the **maximum number of additional random minutes** added on top of each job's fixed `delay`; `START_HOURS_RANGE` restricts jobs to starting within a given range of hours (e.g. `3-22`), so a job whose turn comes at 02:00 waits until 03:00. A **fleet of 500 VMs** cares about `RANDOM_DELAY` because without it every VM would start `updatedb`/`logrotate`/a package refresh at the same instant — a synchronised I/O and network storm against shared storage and mirrors. The random spread is a thundering-herd mitigation. (`RANDOM_DELAY` is a cronie/Fedora–Debian extension, not in the original anacron.)

**26.** To prevent **double execution**. If anacron is installed, it owns the daily/weekly/monthly `run-parts` directories, so the `/etc/crontab` entries must stand down. `test -x /usr/sbin/anacron ||` makes each cron entry a no-op whenever anacron is present, and a working fallback when it is not (servers with continuous uptime often omit anacron).

**27.** `anacron -T` (test the config file), `anacron -n` (run now, ignore delays), `anacron -f` (force, ignore timestamps), `anacron -u` (update timestamps without running the jobs). `-d` additionally keeps it in the foreground with debug messages, which is how you watch any of the above.

### Block G — cron access control

**28.**
1. If **`/etc/cron.allow` exists** → only users listed in it may use `crontab`. `cron.deny` is **ignored entirely**.
2. Else if **`/etc/cron.deny` exists** → all users **except** those listed may use `crontab`.
3. Else (**neither exists**) → site-dependent: the manual states that either only the superuser may use `crontab`, or all users may, depending on how the package was built.

`root` is always permitted regardless.

**29.** **Yes.** `cron.allow` takes absolute precedence — once it exists, `cron.deny` is not consulted at all, so alice's presence in the deny file is irrelevant. This is a classic exam question and a classic production surprise: adding a user to `cron.deny` on a host that has a `cron.allow` does nothing.

**30.** **Not necessarily.** Debian's `crontab(1)` describes the neither-file case as site-dependent and Debian ships with neither file, allowing all users. RHEL/cronie ships an **empty `/etc/cron.deny`**, which puts the system in case 2 with an empty deny-list — also allowing all users, but by a different rule. The manual page wording to remember is *"depending on site-dependent configuration parameters, only the super user will be allowed to use this command, or all users will be able to use this command."*

**31.** On Debian, deleting an existing `/etc/cron.deny` moves the system from case 2 to case 3. Because Debian's build permits all users in case 3, the effective set **grows** (the previously-denied users regain access) or stays the same if the file was empty. The safe answer for an exam: it removes all deny-based restrictions, so access can only widen or remain unchanged — and on a cronie system built to restrict in case 3, the correct move is to leave an empty `cron.deny` in place rather than delete it.

**32.** **No.** `cron.allow`/`cron.deny` gate the **`crontab(1)` command** — the ability to *install, list, edit or remove* a crontab. They are not consulted by the **daemon** when it decides what to execute. Bob's existing crontab keeps running; he simply cannot change it. To actually stop the jobs, remove the crontab: `crontab -u bob -r` (after backing it up).

**33.** `/etc/at.allow` and `/etc/at.deny`, and **yes, the identical precedence rule applies**: `at.allow` wins if present, otherwise `at.deny` is a blacklist, otherwise site-dependent (RHEL ships an empty `/etc/at.deny`).

### Block H — `at` and `batch`

**34.** The job runs under **`/bin/sh`** — `at` does not inherit your interactive shell, which is what the warning announces. `at` snapshots your **current environment, umask and working directory** at submission time into the job script itself, in `/var/spool/cron/atjobs/` (Debian) or `/var/spool/at/` (RHEL); `at -c <jobnumber>` prints that script including the full `export`ed environment. Note the consequence: `at` preserves more environment than cron does, but it is the environment *at submission*, frozen — not at execution.

**35.**

| Purpose | Command | `at` equivalent |
|---|---|---|
| list queued jobs | `atq` | `at -l` |
| delete a job | `atrm <n>` | `at -d <n>`, also `at -r <n>` |
| show a job's contents | `at -c <n>` | — |

**36.** `at now` runs the job **immediately, unconditionally**. `batch` queues the job to run **when the system load average drops below a threshold** — 1.5 by default, configurable with `atd -l <load>`. `at` uses queue letter **`a`**, `batch` uses queue **`b`**; `atq` shows the letter in the fourth column. Higher queue letters (`c`–`z`) run with correspondingly higher `nice` values.

**37.** It was **mailed to you** by `atd` (via the local MTA); with no MTA it was discarded, and the journal records the failure. **`at -m`** forces mail even when the job produces no output (useful as a completion notification); **`at -M`** suppresses mail entirely. As with cron, redirect to a file if you want to be sure.

**38.**
- 17:45 today → `at 17:45` (or `at 5:45pm`)
- four hours from now → `at now + 4 hours`
- next 3rd at 02:00 → `at 02:00 next month` is wrong; use an explicit date: `at 02:00 2026-09-03` (ISO form) or `at 2:00am Sep 3`.

Other accepted forms worth knowing: `noon`, `midnight`, `teatime` (16:00), `tomorrow`, `next week`, `HH:MM MMDDYY`, `now + N minutes|hours|days|weeks`.

**39.** They are **run immediately** when `atd` starts. `atd` scans the spool at startup and executes every job whose time has already passed — `at` jobs are not lost by daemon downtime the way cron entries are. (They are, however, lost if the spool file is deleted.)

**40.** **`cron` is for recurring jobs on a repeating schedule; `at` is for a single execution at one future moment.** If you find yourself writing an `at` job that re-submits itself, you wanted cron.

### Block I — systemd timers

**41.** **Two** unit files: a `.timer` and the unit it activates (normally a `.service`, usually `Type=oneshot`). If they share a base name — `foo.timer` and `foo.service` — the `Unit=` directive may be omitted; systemd activates the same-named service by default. `Unit=` is only needed when the names differ.

**42.** **`Persistent=true`**. It is only meaningful together with **`OnCalendar=`**, and it makes systemd run the unit immediately at boot if the last scheduled elapse was missed while the machine was off — the anacron equivalent. The state it depends on lives in **`/var/lib/systemd/timers/stamp-<unit>.timer`** (or `~/.local/share/systemd/timers/` for user timers); the file's **mtime** records the last trigger.

**43.**
- **`OnCalendar=`** — absolute wall-clock schedule, e.g. `Mon..Fri 09:00`; the crontab analogue.
- **`OnBootSec=`** — relative to **system boot**.
- **`OnUnitActiveSec=`** — relative to the **last time the activated unit was started**, giving true "every N after the previous run finished starting" spacing rather than a fixed grid.
- **`OnActiveSec=`** — relative to the moment the **timer unit itself** was activated; combined with `systemd-run --on-active`, this is the `at` analogue.

(`OnStartupSec=` — relative to systemd start — and `OnUnitInactiveSec=` — relative to when the unit last *stopped* — complete the set.)

**44.** It matches **03:00 on any Friday that falls on the 13th of the month**. Unlike crontab, systemd's calendar syntax applies **AND** between the weekday and the date — there is no OR trap. Confirm with:
```bash
systemd-analyze calendar --iterations=5 "Fri *-*-13 03:00"
```
which prints the next five elapse times. Always validate a new `OnCalendar=` this way before deploying it.

**45.**
1. `systemctl status foo.timer` — is it loaded, active, and was the file even parsed?
2. `systemctl list-timers --all foo.timer` — is it armed, and what is `NEXT`? (Empty `NEXT` usually means it is not enabled or the calendar never matches.)
3. `journalctl -u foo.service -u foo.timer -n 50` — did it fire and fail, or never fire?
4. `systemd-analyze verify /etc/systemd/system/foo.timer` plus `systemd-analyze calendar "<your expression>"` — is the unit valid and does the expression mean what you think?

The most common causes: forgot `systemctl daemon-reload` after editing, enabled the `.service` instead of the `.timer`, or no `[Install] WantedBy=timers.target`.

**46.**
```bash
sudo systemd-run --on-active=30min --unit=report-once /usr/local/bin/report
```
(`--on-calendar="..."` gives a recurring transient timer; add `--user` for a per-user one.)

**47.** Any two of:
- **Resource control and isolation** — the job runs as a service unit, so `MemoryMax=`, `CPUQuota=`, `PrivateTmp=`, `ProtectSystem=`, `User=`, `Nice=`, `IOSchedulingClass=` all apply.
- **Dependency ordering** — `After=network-online.target`, `Requires=`, `Wants=`: the job can be made to wait for prerequisites, which cron cannot express at all.
- **Built-in overlap prevention** — systemd will not start a service that is already running, so no `flock` wrapper is needed.
- **Structured logging** — output goes to the journal automatically, correlated with the unit, with no MTA and no redirection.
- **Randomised spread** — `RandomizedDelaySec=`.
- **Monotonic triggers** — `OnBootSec=`/`OnUnitActiveSec=` have no crontab equivalent.
- **Catch-up** — `Persistent=true`, which in cron requires a separate tool (anacron).

### Block J — production hygiene

**48.** At steady state, **three** (a new one starts every 60 s and each lives 150 s: ⌈150/60⌉ = 3). Cron's contract is *"start this command at these times"* — it keeps no record of whether a previous instance is still running and applies no mutual exclusion. Serialisation is the job author's responsibility. Left unmanaged, this is how a slow backup or rsync becomes a fork bomb.

**49.** `flock -n /var/lock/job.lock cmd` acquires an exclusive lock on the file and runs `cmd` only if the lock was free; **`-n` makes it fail immediately** (exit status 1) rather than wait, so an overrun run is *skipped*. Without `-n`, `flock` **blocks indefinitely** until the lock is released — runs are *queued*, and on a job that consistently overruns you accumulate an unbounded backlog of sleeping processes. `-w 30` waits at most 30 seconds and then gives up, which is usually the right middle ground. The lock is released automatically when the process exits, including on kill or crash — this is why `flock` is safer than a hand-rolled PID file.

**50.**
```bash
journalctl -t CRON        # or -t CROND on RHEL — per-invocation CMD/MAIL/session lines
journalctl -u cron        # or -u crond — the daemon's own start/stop/reload/parse messages
```
Add `-f` to follow, `--since "-10 min"` to bound, `-o short-iso` for parseable timestamps. On hosts still writing text logs, `/var/log/syslog` (Debian) or `/var/log/cron` (RHEL) carry the same lines.

**51.**
1. **Redirect inside the crontab entry**: `>> /var/log/backup.log 2>&1`.
2. **Pipe through `logger`** so the output lands in the journal with an identifier you can query: `/usr/local/bin/backup 2>&1 | logger -t backup`, then `journalctl -t backup`.
3. **Reproduce the cron environment by hand** — `env -i HOME=/root SHELL=/bin/sh PATH=/usr/bin:/bin /bin/sh -c /usr/local/bin/backup` — which surfaces `PATH`/environment failures that never appear in your interactive shell. (A fourth: convert it to a systemd service+timer, where output is captured in the journal by construction.)

**52.**
```crontab
MAILTO=""
0 2 * * * /usr/local/bin/backup >> /var/log/backup.log 2>&1
```
The order matters: `>> file 2>&1` sends stderr to where stdout currently points. `2>&1 >> file` is the classic mistake — it duplicates stderr to the *terminal's* stdout first, then redirects only stdout to the file.

### Synthesis task

**1 — system drop-in:**
```bash
sudo tee /etc/cron.d/pgcheck >/dev/null <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=""

*/20 8-19 * * 1-5   postgres   /usr/local/bin/pgcheck >> /var/log/pgcheck.log 2>&1
EOF
sudo chmod 0644 /etc/cron.d/pgcheck
```
Note `8-19`, not `8-20`: hour 20 would include 20:00–20:59. Filename has no dot. Sixth field is the user.

**2 — anacron:**
```
# /etc/anacrontab
1   15   pgcheck   su -s /bin/sh postgres -c '/usr/local/bin/pgcheck >> /var/log/pgcheck.log 2>&1'
```
Anacron always runs as root and has no user field, so the privilege drop is explicit. Verify with `sudo anacron -T`, force with `sudo anacron -d -f -n pgcheck`, state in `/var/spool/anacron/pgcheck`.

**3 — systemd timer:**
```ini
# /etc/systemd/system/pgcheck.service
[Unit]
Description=PostgreSQL health check
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/pgcheck
```
```ini
# /etc/systemd/system/pgcheck.timer
[Unit]
Description=Run pgcheck on schedule

[Timer]
OnCalendar=Mon..Fri 08..19:00/20
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now pgcheck.timer
systemd-analyze calendar --iterations=5 "Mon..Fri 08..19:00/20"
```
Output goes to the journal automatically — `journalctl -u pgcheck.service` — so no redirection is needed.

**4 — one-shot, both ways:**
```bash
at 03:00 next sunday <<< '/usr/local/bin/migrate'
# or, if the date is known:  at 03:00 2026-08-30 -f /dev/stdin <<< '/usr/local/bin/migrate'

sudo systemd-run --on-calendar="Sun *-*-* 03:00:00" --unit=migrate-once /usr/local/bin/migrate
```
The `systemd-run` form is technically a recurring timer that you remove after it fires (`sudo systemctl stop migrate-once.timer`); for a strict one-shot use `--on-active=` with a computed offset, e.g. `--on-active="$(( $(date -d '2026-08-30 03:00' +%s) - $(date +%s) ))s"`.

**5 — restrict crontab access:**
```bash
printf 'root\npostgres\n' | sudo tee /etc/cron.allow >/dev/null
sudo chmod 0600 /etc/cron.allow
sudo chown root:root /etc/cron.allow
```
Creating `cron.allow` makes `/etc/cron.deny` irrelevant — remove or leave it, it will not be consulted. Verify with `sudo -u nobody crontab -l`, which must report *"You (nobody) are not allowed to use this program (crontab)"*.

</details>

---

## Sources

- LPI, *LPIC-1 Exam 102 Objectives, version 5.0* — Topic 107.2: <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI, *LPIC-1 Exam 101 Objectives, version 5.0*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `crontab(5)` — crontab file format, field ranges, special strings, `%` handling: <https://man7.org/linux/man-pages/man5/crontab.5.html>
- `crontab(1)` — command interface, `cron.allow`/`cron.deny` precedence: <https://man7.org/linux/man-pages/man1/crontab.1.html>
- `cron(8)` — daemon behaviour, `/etc/cron.d`, mtime-based reload: <https://man7.org/linux/man-pages/man8/cron.8.html>
- `anacrontab(5)` and `anacron(8)` — period/delay/identifier format and timestamp handling: <https://man7.org/linux/man-pages/man5/anacrontab.5.html>, <https://man7.org/linux/man-pages/man8/anacron.8.html>
- `at(1)` / `atd(8)` — time specifications, queues, `batch` load threshold: <https://man7.org/linux/man-pages/man1/at.1.html>
- `run-parts(8)` — filename and permission rules: <https://manpages.debian.org/stable/debianutils/run-parts.8.en.html>
- `flock(1)` — `-n`, `-w`, lock lifetime: <https://man7.org/linux/man-pages/man1/flock.1.html>
- systemd, `systemd.timer(5)` — `OnCalendar`, `Persistent`, monotonic timers: <https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html>
- systemd, `systemd.time(7)` — calendar event syntax: <https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html>
- systemd, `systemd-run(1)` — transient timers and services: <https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html>