# LPIC-1 · Exam 102-500 · Topic 108.4 — Manage printers and printing
## Guided lab: CUPS from the scheduler down to the spool file

**Objective coverage.** Basic CUPS configuration for local and remote printers · managing user print queues · adding and removing jobs from queues · troubleshooting general printing problems · `/etc/cups/` · the legacy LPD interface (`lpr`, `lprm`, `lpq`).

**What you need.** One Linux host (Debian 12 / Ubuntu 22.04+ / Fedora / openSUSE), `sudo`, and **no physical printer** — every queue in this lab writes to a file through the CUPS `file` backend, which exercises the *exact* same scheduler, filter chain, job and spool machinery a real printer uses.

**How to work through it.** Run every numbered step in order. After each block, answer the checkpoint questions *before* opening the collapsed answer section at the end. Commands that must run as root are shown with `sudo`.

> ⚠️ **Production safety note.** Two settings in this lab (`FileDevice Yes` and `--debug-logging`) are deliberately *not* production defaults. `FileDevice` lets any authorized submitter make a root-owned backend write to an arbitrary path; debug logging can fill `/var/log` in minutes on a busy server. Block 12 reverts both.

---

## Block 0 — Prepare the lab environment

1. Install the scheduler, the client tools and the filter stack:

   ```bash
   # Debian / Ubuntu
   sudo apt-get install -y cups cups-client cups-filters cups-bsd file
   # Fedora / RHEL derivatives
   sudo dnf install -y cups cups-client cups-filters file
   ```

   `cups` provides `cupsd` and the admin tools, `cups-client` the SysV user tools (`lp`, `lpstat`, `cancel`, `lpadmin`), and `cups-bsd` the Berkeley/LPD-compatible ones (`lpr`, `lpq`, `lprm`).

2. Confirm which package owns each command family — this distinction is examinable:

   ```bash
   command -v lp lpr lpq lprm lpstat cancel lpadmin lpinfo lpoptions lpmove
   ```

   Expected: user tools in `/usr/bin`, administrative tools (`lpadmin`, `lpinfo`, `cupsaccept`, `cupsenable`) in `/usr/sbin`.

3. Create the directory the lab queues will "print" into and a test document:

   ```bash
   sudo install -d -m 0755 -o root -g lp /var/spool/lab-out
   printf 'LPIC-1 108.4 lab page\nHost: %s\nDate: %s\n' "$(hostname)" "$(date)" > ~/report.txt
   file ~/report.txt
   ```

4. Verify the CUPS version you are testing against; option semantics and deprecations differ between 1.x, 2.x and 3.x:

   ```bash
   sudo cupsd --version 2>/dev/null || (dpkg -l cups 2>/dev/null || rpm -q cups)
   ```

**Checkpoint questions**

- **Q0.1** — Which of `lp`, `lpr`, `lpq`, `lprm`, `lpstat`, `cancel` belong to the System V family and which to the Berkeley (LPD) family, and why are both present on a CUPS system?
- **Q0.2** — Why are `lpadmin` and `cupsenable` in `/usr/sbin` while `lp` is in `/usr/bin`?
- **Q0.3** — You install `cups` but not `cups-bsd` on Debian. `lpr` is missing. Does that mean the system cannot print via the LPD protocol?

---

## Block 1 — The scheduler: units, socket activation, config test

1. Look at *all* the units, not just the service:

   ```bash
   systemctl list-unit-files 'cups*'
   systemctl status cups.service --no-pager
   systemctl status cups.socket --no-pager
   ```

   Typical output includes `cups.service`, `cups.socket`, `cups.path` and often `cups-browsed.service`.

2. Stop the service only, then immediately issue a client request:

   ```bash
   sudo systemctl stop cups.service
   systemctl is-active cups.service      # inactive
   lpstat -r                             # forces a connection to /run/cups/cups.sock
   systemctl is-active cups.service      # active again
   ```

   The client connected to the socket; systemd activated `cupsd` on demand.

3. Confirm which listening endpoints exist:

   ```bash
   lpstat -H                             # the server the client will talk to
   sudo ss -lnptu | grep -E 'cupsd|631'
   ```

   Expected: a UNIX domain socket `/run/cups/cups.sock` and, by default, `127.0.0.1:631`.

4. Validate the configuration *before* restarting — the single most valuable habit in this topic:

   ```bash
   sudo cupsd -t
   ```

   Expected on success: an "is OK" line naming `/etc/cups/cupsd.conf` (exact wording varies by version). On failure it prints the offending file and line number and exits non-zero.

5. Introduce a deliberate error and re-test:

   ```bash
   sudo cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
   echo 'LogLevel bananas' | sudo tee -a /etc/cups/cupsd.conf >/dev/null
   sudo cupsd -t ; echo "exit=$?"
   sudo cp /etc/cups/cupsd.conf.bak /etc/cups/cupsd.conf
   sudo cupsd -t ; echo "exit=$?"
   ```

6. Reload vs restart:

   ```bash
   sudo systemctl reload cups     # cupsd re-reads cupsd.conf, keeps the job queue running
   sudo systemctl restart cups    # full restart; needed after editing cups-files.conf
   ```

**Checkpoint questions**

- **Q1.1** — You ran `systemctl stop cups.service` and the daemon came back seconds later. Explain the mechanism and give the exact command sequence that really keeps CUPS down until you say otherwise.
- **Q1.2** — What is the operational value of `cupsd -t` on a remote print server you administer over SSH?
- **Q1.3** — Under what circumstances is `systemctl reload cups` insufficient?
- **Q1.4** — `lpstat -r` prints `scheduler is running`. Which transport did the client most likely use, and how would you prove it?

---

## Block 2 — The configuration tree under `/etc/cups`

1. Inventory the directory and note ownership and modes:

   ```bash
   sudo ls -la /etc/cups
   ```

   Key entries: `cupsd.conf`, `cups-files.conf`, `printers.conf`, `classes.conf`, `subscriptions.conf`, `lpoptions`, `ppd/`, `ssl/`, `cupsd.conf.default`.

2. Read the active directives only, stripping comments and blanks:

   ```bash
   sudo grep -vE '^\s*(#|$)' /etc/cups/cupsd.conf
   ```

   Identify: `LogLevel`, `MaxLogSize`, `Listen`, `Browsing`, `BrowseLocalProtocols`, `DefaultAuthType`, `WebInterface`, and the `<Location …>` / `<Policy …>` blocks.

3. Now the *other* file — since CUPS 1.6 the path and privilege directives live separately:

   ```bash
   sudo grep -vE '^\s*(#|$)' /etc/cups/cups-files.conf
   ```

   Identify: `ErrorLog`, `AccessLog`, `PageLog`, `RequestRoot`, `ServerRoot`, `TempDir`, `Printcap`, `SystemGroup`, `User`, `Group`, `FileDevice`.

4. Inspect the machine-maintained state files:

   ```bash
   sudo cat /etc/cups/printers.conf
   sudo cat /etc/cups/classes.conf 2>/dev/null
   ```

   These are written by `cupsd` itself. Note the header comment warning you not to edit them by hand.

5. Query and change runtime settings without touching a text editor:

   ```bash
   sudo cupsctl                       # dumps current settings, e.g. _debug_logging=0
   sudo cupsctl --no-remote-admin --no-remote-any
   sudo cupsctl                       # confirm the change
   ```

6. Locate the packaged defaults so you can always recover:

   ```bash
   ls -l /etc/cups/cupsd.conf.default
   ```

**Checkpoint questions**

- **Q2.1** — Which file contains `ErrorLog` and which contains `LogLevel`? Why were they split, and what security property does that split enforce?
- **Q2.2** — Why must you never edit `/etc/cups/printers.conf` while `cupsd` is running, and what is the correct procedure if you truly must edit it?
- **Q2.3** — Give the `cupsctl` equivalents of "share my local printers on the network" and "allow administration from remote hosts", and state which underlying `cupsd.conf` constructs each one rewrites.
- **Q2.4** — A colleague deleted `/etc/cups/cupsd.conf`. What is the fastest recovery on a standard distribution package?

---

## Block 3 — Devices, drivers and queue creation with `lpadmin`

1. List the backends and discovered devices:

   ```bash
   sudo lpinfo -v
   ```

   Sample:

   ```
   network beh
   direct usb://HP/LaserJet%20P2055dn?serial=VNB3S12345
   network lpd
   network socket
   network ipp
   network ipps
   network https
   ```

   The first column is the device *class*; the second is a device URI. Backends live in `/usr/lib/cups/backend/`:

   ```bash
   ls -l /usr/lib/cups/backend/
   ```

2. List available drivers/models (this queries `cups-driverd`):

   ```bash
   sudo lpinfo -m | wc -l
   sudo lpinfo -m | grep -iE 'generic|everywhere|raw' | head
   ```

3. Enable the file pseudo-device for the lab and restart (it is read at startup):

   ```bash
   sudo sed -i 's/^#\?FileDevice .*/FileDevice Yes/' /etc/cups/cups-files.conf
   grep -n '^FileDevice' /etc/cups/cups-files.conf || echo 'FileDevice Yes' | sudo tee -a /etc/cups/cups-files.conf
   sudo cupsd -t && sudo systemctl restart cups
   ```

4. Create the first queue. Pick a model string that `lpinfo -m` actually listed on your system:

   ```bash
   sudo lpadmin -p labps \
     -v file:/var/spool/lab-out/labps.ps \
     -m drv:///sample.drv/generic.ppd \
     -D "Lab PostScript queue (writes to a file)" \
     -L "Rack 4 / lab" \
     -o printer-is-shared=false \
     -E
   ```

   If `drv:///sample.drv/generic.ppd` is not offered, substitute any generic PostScript entry from step 2. Omitting `-m`/`-P` entirely creates a **raw** queue (no PPD, no filtering); modern CUPS prints a deprecation warning when you do.

5. Verify what was created, in three independent places:

   ```bash
   lpstat -v labps
   lpstat -l -p labps
   sudo ls -l /etc/cups/ppd/
   sudo grep -A12 '<Printer labps>' /etc/cups/printers.conf
   ```

6. Create a second queue to use later for job moves:

   ```bash
   sudo lpadmin -p labps2 -v file:/var/spool/lab-out/labps2.ps \
     -m drv:///sample.drv/generic.ppd -D "Second lab queue" -E
   lpstat -a
   ```

7. Inspect and change driver-level options:

   ```bash
   lpoptions -p labps -l | head -20        # PPD options: key/Choices, * marks the default
   sudo lpadmin -p labps -o PageSize=A4
   lpoptions -p labps -l | grep -i pagesize
   ```

> **AppArmor caveat (Ubuntu).** If nothing is ever written to `/var/spool/lab-out/`, check `journalctl -k | grep -i apparmor` for `DENIED` lines naming the `file` backend, and either choose a path the profile permits or run `sudo aa-complain /usr/sbin/cupsd` for the duration of the lab.

**Checkpoint questions**

- **Q3.1** — `lpadmin -E -p labps -v …` and `lpadmin -p labps -v … -E` are *not* equivalent. Explain precisely what `-E` means in each position.
- **Q3.2** — After step 4, where exactly does CUPS store the PPD for `labps`, and what happens to that file when you run `lpadmin -x labps`?
- **Q3.3** — What is a *raw* queue, when is it the correct choice, and what is the practical consequence of sending a PDF to one?
- **Q3.4** — Explain the difference between `lpadmin -m <model>` and `lpadmin -P <file.ppd>`.
- **Q3.5** — Decompose the device URI `socket://192.0.2.40:9100` and `ipp://printer.example.com/ipp/print`: which backend handles each, and which TCP port does each use?

---

## Block 4 — Submitting jobs: the two command families

1. Submit with the System V client and read the job ID it returns:

   ```bash
   lp -d labps ~/report.txt
   ```

   ```
   request id is labps-1 (1 file(s))
   ```

2. Submit with the Berkeley client, requesting two copies and a job title:

   ```bash
   lpr -P labps -#2 -T "berkeley-test" ~/report.txt
   ```

   Note that `lpr` prints nothing on success.

3. Watch the queue with both tools while jobs are pending:

   ```bash
   lpstat -o                 # jobs on all destinations
   lpstat -o labps -l        # long form: size, priority, user, time
   lpq -P labps              # Berkeley view
   lpq -a                    # all queues
   ```

   Sample `lpq`:

   ```
   labps is ready and printing
   Rank    Owner   Job     File(s)                         Total Size
   active  student 1       report.txt                      1024 bytes
   ```

4. Confirm the job actually reached the "printer":

   ```bash
   ls -l /var/spool/lab-out/
   head -5 /var/spool/lab-out/labps.ps
   ```

5. Submit three jobs in a row and re-check the output file size:

   ```bash
   for i in 1 2 3; do lp -d labps -t "job-$i" ~/report.txt; done
   sleep 3; ls -l /var/spool/lab-out/labps.ps
   ```

6. Exercise the common option set (identical spelling for `lp` and `lpr` when using `-o`):

   ```bash
   lp -d labps -n 3 -o media=A4 -o sides=two-sided-long-edge -o number-up=2 ~/report.txt
   lpr -P labps -o fit-to-page -o page-ranges=1-2 ~/report.txt
   ```

7. Cancel jobs both ways:

   ```bash
   lp -d labps -H hold ~/report.txt      # keep something in the queue to cancel
   lpstat -o labps
   cancel labps-8                        # SysV: by job ID
   lprm -P labps 9                       # Berkeley: by job number
   cancel -a labps                       # everything on one queue
   lprm -                                # all of *your* jobs
   ```

8. Explore the default-destination environment variables:

   ```bash
   lpstat -d
   LPDEST=labps2 lp ~/report.txt ; lpstat -W completed -o labps2 | head -3
   PRINTER=labps2 lpr ~/report.txt
   ```

9. Read completed history rather than the live queue:

   ```bash
   lpstat -W completed -o
   lpstat -W not-completed -o
   ```

**Checkpoint questions**

- **Q4.1** — Write the command for "5 copies of `manual.pdf` to queue `hp2055`" in both families.
- **Q4.2** — In step 5 you sent three jobs to a `file:` device URI. Did the file grow to three documents? Explain the behaviour of the `file` backend and why that matters when someone proposes it as a "PDF printer".
- **Q4.3** — Exactly which sources determine the destination when a user types `lp report.txt` with no `-d`, and in what precedence order?
- **Q4.4** — `cancel` and `lprm` both remove jobs. Name two behavioural differences.
- **Q4.5** — A user says "my job vanished, `lpstat -o` shows nothing, but nothing printed". Which single command tells you whether CUPS believes the job completed?

---

## Block 5 — The two orthogonal axes: accepting vs enabled

1. Establish the baseline:

   ```bash
   lpstat -p -d
   lpstat -a
   ```

2. Close the queue to *new* submissions:

   ```bash
   sudo cupsreject -r "Toner order pending" labps
   lpstat -a labps
   lp -d labps ~/report.txt
   ```

   Expected:

   ```
   labps not accepting requests since Thu 27 Aug 2026 10:31:44 AM -03 -
       Toner order pending
   lp: Destination "labps" is not accepting jobs.
   ```

3. Re-open it and confirm submissions succeed again:

   ```bash
   sudo cupsaccept labps
   lpstat -a labps
   lp -d labps ~/report.txt
   ```

4. Now stop *printing* while still accepting work:

   ```bash
   sudo cupsdisable -r "Scheduled maintenance window" labps
   lpstat -p labps
   lp -d labps ~/report.txt          # succeeds
   lpstat -o labps                   # job sits in the queue
   ```

5. Release the queue and watch the backlog drain:

   ```bash
   sudo cupsenable labps
   sleep 3
   lpstat -o labps
   lpstat -W completed -o labps | head -3
   ```

6. Explore the destructive variants:

   ```bash
   lp -d labps ~/report.txt
   sudo cupsdisable -c -r "Purging spool" labps     # -c cancels queued jobs
   lpstat -o labps
   sudo cupsenable labps
   sudo cupsdisable --hold labps                    # hold the job being printed instead of stopping it
   sudo cupsenable labps
   ```

7. Note the legacy aliases, still present on many systems:

   ```bash
   ls -l /usr/sbin/accept /usr/sbin/reject 2>/dev/null
   ls -l /usr/sbin/enable /usr/sbin/disable 2>/dev/null
   ```

**Checkpoint questions**

- **Q5.1** — Fill in this matrix: for each combination of *accepting/rejecting* × *enabled/disabled*, state what happens to a newly submitted job.
- **Q5.2** — A printer is being replaced tomorrow morning and users must be told now, but no work should be lost. Which of the four commands do you run, and why not the others?
- **Q5.3** — Why is `enable`/`disable` dangerous to type in a shell script, and what did CUPS 1.4 do about it?
- **Q5.4** — Which command *both* stops printing and empties the queue in a single invocation?

---

## Block 6 — Job control: hold, release, move, prioritise, modify

1. Fill a queue with distinguishable jobs while it is stopped:

   ```bash
   sudo cupsdisable labps
   for i in a b c; do lp -d labps -t "doc-$i" ~/report.txt; done
   lpstat -o labps -l
   ```

2. Hold a specific job indefinitely, then inspect its state:

   ```bash
   JOB=$(lpstat -o labps | awk 'NR==1{print $1}')
   lp -i "$JOB" -H hold
   lpstat -o labps -l | head -12
   ```

3. Release it:

   ```bash
   lp -i "$JOB" -H resume
   ```

4. Schedule a job for off-hours using the named `hold-until` values:

   ```bash
   lp -d labps -H night ~/report.txt
   lp -d labps -H 23:30 ~/report.txt
   lpstat -o labps -l | grep -i -A2 'held\|hold'
   ```

5. Change a queued job's attributes without resubmitting it:

   ```bash
   JOB2=$(lpstat -o labps | awk 'NR==2{print $1}')
   lp -i "$JOB2" -n 4 -o media=Letter -q 90
   lpstat -o labps -l | head
   ```

6. Move work between destinations:

   ```bash
   lpmove "$JOB2" labps2          # one job
   sudo lpmove labps labps2       # every remaining job on labps
   lpstat -o
   ```

7. Drain everything and restore normal operation:

   ```bash
   sudo cupsenable labps labps2
   sleep 3
   lpstat -o
   ```

**Checkpoint questions**

- **Q6.1** — Which `lp` option holds an already-submitted job, and which option identifies *which* job it applies to?
- **Q6.2** — List the symbolic `hold-until` keywords CUPS accepts, and state what a bare `HH:MM` value is interpreted as.
- **Q6.3** — What is the valid range of `lp -q`, what is the default, and does raising it affect a job that is already printing?
- **Q6.4** — A printer died mid-shift with 40 queued jobs. Give the two-command sequence that redirects the whole backlog to the identical printer next to it.
- **Q6.5** — `lpmove 12 other` versus `lpmove hp1 other` — how does `lpmove` decide which one you meant?

---

## Block 7 — Classes, default destinations and `lpoptions`

1. Build a class from the two lab queues (the class is created implicitly):

   ```bash
   sudo lpadmin -p labps  -c labpool
   sudo lpadmin -p labps2 -c labpool
   lpstat -c
   lpstat -a
   sudo grep -A6 '<Class labpool>' /etc/cups/classes.conf
   ```

2. Print to the class and observe which member takes the job:

   ```bash
   for i in 1 2 3 4; do lp -d labpool -t "pool-$i" ~/report.txt; done
   sleep 3
   ls -l /var/spool/lab-out/
   lpstat -W completed -o labpool | head
   ```

3. Take one member out for maintenance and confirm the class still works:

   ```bash
   sudo cupsdisable labps
   lp -d labpool ~/report.txt
   sleep 2; ls -l /var/spool/lab-out/labps2.ps
   sudo cupsenable labps
   ```

4. Set the **server-wide** default and check it:

   ```bash
   sudo lpadmin -d labpool
   lpstat -d
   sudo grep -i '^DefaultPrinter\|<DefaultPrinter' /etc/cups/printers.conf /etc/cups/classes.conf 2>/dev/null
   ```

5. Set a **per-user** default and per-user option defaults, then find where they were written:

   ```bash
   lpoptions -d labps2
   lpoptions -p labps2 -o sides=two-sided-long-edge -o media=A4
   cat ~/.cups/lpoptions
   lpstat -d
   ```

6. Set **system-wide** client option defaults as root and compare:

   ```bash
   sudo lpoptions -p labps -o media=Letter
   sudo cat /etc/cups/lpoptions
   ```

7. Remove a user-level setting and a class member:

   ```bash
   lpoptions -x labps2                 # drop this user's saved options for labps2
   sudo lpadmin -p labps2 -r labpool   # remove member from class
   lpstat -c
   ```

**Checkpoint questions**

- **Q7.1** — What is a CUPS class, and what does it give you that a single shared queue does not?
- **Q7.2** — What happens to a class when you remove its last member printer?
- **Q7.3** — Distinguish `lpadmin -d`, `lpoptions -d` run as a user, and the `LPDEST` variable: which of the three affects other users, and which file backs each?
- **Q7.4** — `lpoptions -p q -o media=A4` as root versus as an unprivileged user: which files are written, and which of the two survives a user deleting their home directory?
- **Q7.5** — Why does `lpstat -d` sometimes disagree with what a colleague sees on the same machine?

---

## Block 8 — Access control and quotas on a queue

1. Restrict a queue to named users and verify:

   ```bash
   sudo lpadmin -p labps -u allow:root,"$USER"
   lpstat -l -p labps | sed -n '/Users allowed/,+3p'
   sudo grep -A2 'AllowUser' /etc/cups/printers.conf
   ```

2. Test denial with a second account (create one only if you are comfortable doing so):

   ```bash
   sudo useradd -m -s /bin/bash printtest 2>/dev/null
   sudo -u printtest lp -d labps ~/report.txt
   ```

   Expected: a client-error indicating the user is not authorized for the destination.

3. Switch to a deny-list and then reset to "everyone":

   ```bash
   sudo lpadmin -p labps -u deny:printtest
   sudo lpadmin -p labps -u allow:all
   lpstat -l -p labps | grep -i users
   ```

4. Apply a page quota — 20 pages per rolling 24 hours:

   ```bash
   sudo lpadmin -p labps -o job-quota-period=86400 -o job-page-limit=20
   sudo lpadmin -p labps -o job-k-limit=2048        # 2 MB of data in the same period
   sudo grep -E 'QuotaPeriod|PageLimit|KLimit' /etc/cups/printers.conf
   ```

5. Look at the scheduler-wide limits that back-pressure the whole server:

   ```bash
   sudo grep -iE '^\s*(MaxJobs|MaxJobsPerPrinter|MaxJobsPerUser|MaxCopies)' /etc/cups/cupsd.conf
   ```

6. Look at the IPP operation policy that governs *who may administer*:

   ```bash
   sudo sed -n '/<Policy default>/,/<\/Policy>/p' /etc/cups/cupsd.conf | head -40
   grep -E '^SystemGroup' /etc/cups/cups-files.conf
   getent group lpadmin lpadmin sys wheel 2>/dev/null
   ```

**Checkpoint questions**

- **Q8.1** — Which CUPS accounting file must exist and be maintained for `job-page-limit` to be enforceable at all?
- **Q8.2** — Distinguish `lpadmin -u allow:…` from a `<Location /printers/labps>` block with `Require user …`. Which one blocks the *submission* and which blocks the *HTTP/IPP request*?
- **Q8.3** — `SystemGroup` in `cups-files.conf` lists `lpadmin`. A user is added to that group but still gets "Forbidden" from the web interface. Give two plausible causes.
- **Q8.4** — What is the difference between `MaxJobs 0` and `MaxJobs 1`?

---

## Block 9 — The spool directory, control files and the three logs

1. Park a job so it can be dissected:

   ```bash
   sudo cupsdisable labps
   lp -d labps -t "forensics" ~/report.txt
   JOB=$(lpstat -o labps | awk 'NR==1{print $1}' | sed 's/.*-//')
   echo "job number: $JOB"
   ```

2. Examine the spool as root, including permissions:

   ```bash
   sudo ls -ld /var/spool/cups
   sudo ls -l  /var/spool/cups | head
   ```

   Expected shape: the directory `drwx--x---  root lp`, control files `c<NNNNN>` and data files `d<NNNNN>-001`, mode `0640 root:lp`.

3. Read the control file — it is a binary IPP attribute group, not text:

   ```bash
   sudo strings /var/spool/cups/c$(printf '%05d' "$JOB") | head -30
   ```

   Look for `job-name`, `job-originating-user-name`, `job-originating-host-name`, `document-format`, `job-priority`, `time-at-creation`, `printer-uri`.

4. Identify the data file's real content type:

   ```bash
   sudo file /var/spool/cups/d$(printf '%05d' "$JOB")-001
   ```

5. Release the job and locate the three logs:

   ```bash
   sudo cupsenable labps ; sleep 2
   sudo ls -l /var/log/cups/
   grep -iE '^(ErrorLog|AccessLog|PageLog)' /etc/cups/cups-files.conf
   ```

   On systems configured with `ErrorLog syslog` (common on Fedora/RHEL), read them with `journalctl -u cups -n 50` instead.

6. Read the accounting log and decode its fields:

   ```bash
   sudo tail -3 /var/log/cups/page_log
   ```

   ```
   labps student 12 [27/Aug/2026:10:44:02 -0300] 1 1 - localhost forensics a4 one-sided
   ```

   Fields: `printer user job-id date-time page-number num-copies job-billing hostname job-name media sides`.

7. Read the request log:

   ```bash
   sudo tail -5 /var/log/cups/access_log
   ```

   ```
   localhost - - [27/Aug/2026:10:44:01 -0300] "POST /printers/labps HTTP/1.1" 200 456 Print-Job successful-ok
   ```

   The last two fields are the **IPP operation name** and the **IPP status code** — this is what distinguishes it from an ordinary web server log.

8. Turn on debug logging, reproduce, then read the per-job trace:

   ```bash
   sudo cupsctl --debug-logging
   lp -d labps ~/report.txt
   sleep 2
   sudo grep "\[Job $((JOB+1))\]" /var/log/cups/error_log | head -40
   ```

   Note the single-letter severity prefixes at line start: `E` error, `W` warning, `N` notice, `I` info, `D` debug, `d` debug2.

9. Turn it back off before it fills the disk:

   ```bash
   sudo cupsctl --no-debug-logging
   grep -iE '^(LogLevel|MaxLogSize)' /etc/cups/cupsd.conf
   ```

10. Control history retention:

    ```bash
    grep -iE '^(PreserveJobHistory|PreserveJobFiles)' /etc/cups/cupsd.conf
    lpstat -W completed -o labps | head
    cancel -a -x labps                     # purge job history for this queue
    lpstat -W completed -o labps
    ```

**Checkpoint questions**

- **Q9.1** — What does the `c00042` file contain versus `d00042-001`? Which one disappears first under default settings, and which directive controls each?
- **Q9.2** — `/var/spool/cups` is mode `0710 root:lp`. Explain what that mode permits and why the design chose it over `0755`.
- **Q9.3** — For "who printed how many pages last month, and to which printer", which log do you parse and which fields do you sum?
- **Q9.4** — You need to prove a specific client host submitted a job at a specific time, and the job is long gone. Which log survives it, and which field carries the host?
- **Q9.5** — Debug logging is on, disk is filling, and you must not interrupt printing. Give the command and explain why it does not restart the daemon.

---

## Block 10 — End-to-end failure diagnosis

1. Break the queue in a realistic way — a device the backend cannot reach:

   ```bash
   sudo lpadmin -p labps -v file:/root/definitely/not/there/out.ps
   lpstat -v labps
   ```

2. Submit and observe the failure:

   ```bash
   lp -d labps -t "will-fail" ~/report.txt
   sleep 3
   lpstat -p labps
   lpstat -l -p labps
   lpstat -o labps
   ```

   Expected: the queue is now **disabled** with a `printer-state-message`, and the job is still queued rather than lost.

3. Find the backend's verdict in the log:

   ```bash
   sudo grep -iE 'Backend|status|Unable to (open|write)' /var/log/cups/error_log | tail -20
   ```

   Look for a line reporting the backend exit status; `1` means `CUPS_BACKEND_FAILED`.

4. Inspect the reason codes the scheduler is exporting over IPP:

   ```bash
   lpstat -l -p labps | sed -n '1,6p'
   ```

   Reasons such as `paused`, `filter-failed`, `media-empty-warning`, `toner-low` appear here and drive every GUI status icon.

5. Change the failure policy so the job retries instead of stopping the queue:

   ```bash
   sudo lpadmin -p labps -o printer-error-policy=retry-job
   sudo grep -i 'ErrorPolicy' /etc/cups/printers.conf /etc/cups/cupsd.conf
   ```

   Valid values: `abort-job`, `retry-job`, `retry-current-job`, `stop-printer` (the default). Retry cadence is governed by `JobRetryInterval` / `JobRetryLimit` in `cupsd.conf`.

6. Repair the device URI, re-enable, and confirm recovery:

   ```bash
   sudo lpadmin -p labps -v file:/var/spool/lab-out/labps.ps
   sudo cupsenable labps
   sleep 3
   lpstat -o labps ; lpstat -p labps ; ls -l /var/spool/lab-out/labps.ps
   ```

7. Exercise the filter chain independently of any queue — this isolates "driver problem" from "device problem":

   ```bash
   cupsfilter --list-filters -m application/vnd.cups-postscript ~/report.txt 2>&1 | head
   cupsfilter -m application/pdf ~/report.txt > /tmp/report.pdf 2>/tmp/filter.err
   file /tmp/report.pdf ; head -3 /tmp/filter.err
   ls -l /usr/lib/cups/filter/ | head
   ```

8. Test the transport independently of CUPS, the way you would against real hardware:

   ```bash
   # raw JetDirect port on a real printer:
   #   nc -vz 192.0.2.40 9100
   # IPP endpoint:
   #   curl -s -o /dev/null -w '%{http_code}\n' http://192.0.2.40:631/
   ss -lnt | grep 631
   ```

**Checkpoint questions**

- **Q10.1** — Default CUPS behaviour on backend failure is to stop the printer and *keep* the job. Argue why that is the right default for a shared office printer and wrong for a high-volume unattended batch server, and give the one-line change for the latter.
- **Q10.2** — A user reports "nothing prints". Write the ordered diagnostic sequence — scheduler → queue state → job state → backend/filter → device — as a list of concrete commands.
- **Q10.3** — Output comes out as pages of raw PostScript source code. What is the defect, and which two `lpadmin` facts do you check first?
- **Q10.4** — What does `cupsfilter` let you prove that submitting a test job cannot?
- **Q10.5** — `lpstat -p` says `idle` and `enabled`, jobs disappear from `lpstat -o` immediately, and nothing is printed. Where do you look next?

---

## Block 11 — Remote printing: IPP, discovery and the LPD legacy interface

1. Make `cupsd` listen beyond localhost (lab only — read the warning below):

   ```bash
   sudo cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.lab
   sudo sed -i 's/^Listen localhost:631/Listen 0.0.0.0:631/' /etc/cups/cupsd.conf
   sudo cupsd -t && sudo systemctl restart cups
   sudo ss -lnt | grep 631
   ```

2. Share a queue and turn on local advertisement:

   ```bash
   sudo lpadmin -p labps -o printer-is-shared=true
   sudo cupsctl --share-printers
   grep -iE '^(Browsing|BrowseLocalProtocols)' /etc/cups/cupsd.conf
   ```

3. Confirm the access-control block that gates it (in `cupsd.conf`):

   ```bash
   sudo sed -n '/<Location \/>/,/<\/Location>/p' /etc/cups/cupsd.conf
   ```

   The canonical safe form is `Order allow,deny` + `Allow @LOCAL`, not `Allow all`.

4. Talk to a CUPS server as a client, without configuring anything locally:

   ```bash
   lpstat -h localhost:631 -p
   lp -h localhost:631 -d labps ~/report.txt
   ```

5. Add a *remote* queue by URI (the normal way to consume another server's printer):

   ```bash
   sudo lpadmin -p remotelab -E -v ipp://localhost:631/printers/labps -m everywhere
   lpstat -v remotelab
   lp -d remotelab ~/report.txt ; sleep 2 ; ls -l /var/spool/lab-out/labps.ps
   ```

   `-m everywhere` builds the driver from the printer's own IPP attributes (IPP Everywhere / driverless) and therefore requires the device URI to be reachable at creation time.

6. Discovery tools:

   ```bash
   ippfind 2>/dev/null | head
   driverless list 2>/dev/null | head
   systemctl status cups-browsed --no-pager 2>/dev/null | head -5
   grep -iE '^(BrowseRemoteProtocols|BrowseProtocols)' /etc/cups/cups-browsed.conf 2>/dev/null
   ```

7. The legacy LPD interface, in both directions:

   ```bash
   # (a) the printcap CUPS generates for LPD-era applications
   grep -i '^Printcap' /etc/cups/cups-files.conf
   cat /etc/printcap

   # (b) serving legacy LPD clients on TCP/515 (not enabled by default)
   systemctl list-unit-files 'cups-lpd*'
   ls -l /usr/lib/cups/daemon/cups-lpd 2>/dev/null

   # (c) consuming a legacy LPD queue from CUPS
   # sudo lpadmin -p oldline -E -v lpd://192.0.2.50/queuename -m drv:///sample.drv/generic.ppd
   ```

8. Firewalling:

   ```bash
   sudo firewall-cmd --list-services 2>/dev/null            # look for "ipp" / "ipp-client" / "mdns"
   sudo ufw status 2>/dev/null
   ```

9. Revert the network exposure:

   ```bash
   sudo cp /etc/cups/cupsd.conf.lab /etc/cups/cupsd.conf
   sudo cupsd -t && sudo systemctl restart cups
   sudo ss -lnt | grep 631
   ```

**Checkpoint questions**

- **Q11.1** — Give the transport protocol and TCP port for: IPP, IPPS, LPD, raw/JetDirect, and mDNS/DNS-SD discovery.
- **Q11.2** — What is the difference between `Listen 631`, `Port 631` and `Listen localhost:631`?
- **Q11.3** — Two mechanisms can make a remote printer appear on a client: `cupsd`'s own IPP sharing, and `cups-browsed`. Explain the division of labour and which one creates local queues.
- **Q11.4** — Who writes `/etc/printcap` on a CUPS system, what is it for, and what happens if you hand-edit it?
- **Q11.5** — A legacy AS/400 host must submit jobs with `lpr` over the network to your Linux server. What must you enable, and on which port?
- **Q11.6** — Contrast `lp -h server -d q file` with creating a local queue whose device URI is `ipp://server/printers/q`. When is each the right answer?

---

## Block 12 — Cleanup and hardening back to a sane state

1. Remove the lab objects:

   ```bash
   sudo lpadmin -x labpool 2>/dev/null
   sudo lpadmin -x remotelab 2>/dev/null
   sudo lpadmin -x labps2
   sudo lpadmin -x labps
   lpstat -a ; lpstat -c
   sudo ls -l /etc/cups/ppd/
   ```

2. Revert the two unsafe settings:

   ```bash
   sudo sed -i 's/^FileDevice Yes/FileDevice No/' /etc/cups/cups-files.conf
   sudo cupsctl --no-debug-logging --no-remote-admin --no-remote-any
   sudo cupsd -t && sudo systemctl restart cups
   sudo cupsctl | grep -E '_debug_logging|_remote'
   ```

3. Remove lab artefacts and the test account:

   ```bash
   sudo rm -rf /var/spool/lab-out /etc/cups/cupsd.conf.lab /etc/cups/cupsd.conf.bak
   rm -f ~/report.txt /tmp/report.pdf /tmp/filter.err
   sudo userdel -r printtest 2>/dev/null
   rm -f ~/.cups/lpoptions
   ```

4. Final verification:

   ```bash
   lpstat -t
   sudo cupsd -t
   ```

**Checkpoint questions**

- **Q12.1** — `lpadmin -x` removed the queue. Name three files or directories whose contents changed as a result.
- **Q12.2** — Why is reverting `FileDevice` to `No` a genuine hardening step and not just tidiness?

---

## Sources

- LPI — *Exam 101-500 Objectives*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — *Exam 102-500 Objectives* (topic 108.4 is examined here): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- OpenPrinting CUPS documentation home: <https://openprinting.github.io/cups/>
- CUPS man pages — `cupsd.conf`: <https://openprinting.github.io/cups/doc/man-cupsd.conf.html> · `cups-files.conf`: <https://openprinting.github.io/cups/doc/man-cups-files.conf.html> · `lpadmin`: <https://openprinting.github.io/cups/doc/man-lpadmin.html> · `lp`: <https://openprinting.github.io/cups/doc/man-lp.html> · `lpr`: <https://openprinting.github.io/cups/doc/man-lpr.html> · `lpstat`: <https://openprinting.github.io/cups/doc/man-lpstat.html> · `cupsenable`/`cupsdisable`: <https://openprinting.github.io/cups/doc/man-cupsenable.html> · `cupsaccept`/`cupsreject`: <https://openprinting.github.io/cups/doc/man-cupsaccept.html> · `lpoptions`: <https://openprinting.github.io/cups/doc/man-lpoptions.html> · `cupsfilter`: <https://openprinting.github.io/cups/doc/man-cupsfilter.html>
- CUPS — *Printer Accounting Basics* (page_log): <https://openprinting.github.io/cups/doc/accounting.html>
- CUPS — *Server Security* and *Network Printers*: <https://openprinting.github.io/cups/doc/security.html> · <https://openprinting.github.io/cups/doc/network.html>
- OpenPrinting cups-filters / cups-browsed: <https://github.com/OpenPrinting/cups-filters>
- RFC 8011 — *Internet Printing Protocol/1.1: Model and Semantics*: <https://www.rfc-editor.org/rfc/rfc8011>
- RFC 1179 — *Line Printer Daemon Protocol*: <https://www.rfc-editor.org/rfc/rfc1179>

---

<details>
<summary><strong>▶ Answers — expand only after attempting every block</strong></summary>

### Block 0

**A0.1** — System V family: `lp`, `lpstat`, `cancel` (plus the admin tools `lpadmin`, `lpmove`, `lpinfo`, `lpoptions`, `cupsaccept`, `cupsenable`). Berkeley/LPD family: `lpr`, `lpq`, `lprm`. CUPS implements *both* front-ends over its native IPP transport so that decades of scripts and applications written for either legacy system keep working unchanged. Neither family speaks the historical SysV `lpsched` or Berkeley `lpd` protocol locally — they are CUPS clients wearing old names.

**A0.2** — `/usr/sbin` is conventionally for administrative binaries expected to be run by root and is not on an unprivileged user's default `PATH` on many distributions. `lpadmin`, `cupsenable`, `cupsaccept`, `lpinfo` change server state; `lp`, `lpr`, `lpq`, `lpstat`, `cancel` are ordinary user operations. Note this is a *convention*: the real enforcement is the IPP operation policy in `cupsd.conf` plus `SystemGroup`, not the directory.

**A0.3** — No. Two independent things share the name. `lpr` is a *client command*; its absence only means users cannot type `lpr`. LPD *protocol* support is separate: outbound via the `lpd://` backend (CUPS printing to a legacy LPD device) and inbound via `cups-lpd`, the daemon that accepts RFC 1179 connections on port 515. Either can be present without the `lpr` binary.

### Block 1

**A1.1** — `cups.socket` (and often `cups.path`) remained active; systemd holds `/run/cups/cups.sock` and starts `cups.service` the moment a client connects. `lpstat -r` was that client. To keep it down:
```bash
sudo systemctl stop cups.socket cups.path cups.service
sudo systemctl disable --now cups.socket cups.path cups.service
# or, in one shot:
sudo systemctl mask cups.socket cups.path cups.service
```
Stopping the service alone is the classic incident-response mistake in this area.

**A1.2** — A syntax error in `cupsd.conf` makes `cupsd` refuse to start. If you `systemctl restart` blind over SSH, you take printing down for everyone with no way to see the error before the fact. `cupsd -t` parses the file, reports the offending file and line, and exits non-zero — it is a safe pre-flight and it composes with `&&`: `sudo cupsd -t && sudo systemctl restart cups`.

**A1.3** — Reload re-reads `cupsd.conf`. It does **not** re-read `cups-files.conf`, whose path/privilege directives (`User`, `Group`, `RequestRoot`, `ErrorLog`, `FileDevice`, `SystemGroup`) are applied at startup — those need a full restart. A restart is also required after changing listening addresses/ports in some versions, and after replacing TLS material.

**A1.4** — Almost certainly the UNIX domain socket `/run/cups/cups.sock`, because the default `cupsd.conf` only has `Listen localhost:631` plus the domain socket, and libcups prefers the domain socket for a local server. Prove it with `lpstat -H` (prints the server endpoint the client resolved) or by tracing: `strace -f -e trace=connect lpstat -r 2>&1 | grep -i sun_path`.

### Block 2

**A2.1** — `ErrorLog` is in **`cups-files.conf`**; `LogLevel` is in **`cupsd.conf`**. The split arrived in CUPS 1.6. `cupsd.conf` can be edited over the network by an authenticated CUPS administrator through the web interface, while `cups-files.conf` cannot. Since directives like `ErrorLog`, `User`, `Group`, `RequestRoot` and `FileDevice` decide *what a root-privileged daemon writes and as whom*, allowing remote edits to them would be a privilege-escalation path. Moving them to a file only editable on disk by root closes it.

**A2.2** — `cupsd` keeps printer state in memory and **rewrites `printers.conf` itself** whenever that state changes (a queue enabled, a default set, a job counter advanced). Your edits are silently overwritten at the next write, and you may be editing a file that is about to be replaced. Correct procedure: use `lpadmin`/`cupsenable`/`cupsaccept`/`cupsctl`. If you genuinely must hand-edit: `systemctl stop cups` → edit → `cupsd -t` → `systemctl start cups`.

**A2.3** — `sudo cupsctl --share-printers` sets `Browsing On` plus the shared flag semantics for queues, and `--remote-any` widens the `<Location>` blocks to accept requests from any address; `sudo cupsctl --remote-admin` rewrites the `<Location /admin>` (and `/admin/conf`) blocks' `Allow` lines to permit non-localhost administration. `cupsctl` is a client that edits `cupsd.conf` through IPP and reloads the server, so it is the scriptable, syntax-safe way to make these changes. Their negations are `--no-share-printers`, `--no-remote-any`, `--no-remote-admin`.

**A2.4** — Copy the packaged default back: `sudo cp /etc/cups/cupsd.conf.default /etc/cups/cupsd.conf && sudo cupsd -t && sudo systemctl restart cups`. CUPS installs that reference copy precisely for this. (Failing that, `dpkg -S`/`rpm -qf` the path and reinstall the package with config restoration.)

### Block 3

**A3.1** — Position is everything:
- `-E` **before** `-p`/`-d`/`-h` (i.e. before the destination is known) means *"force encryption on the connection to the server"* — the `cupsSetEncryption(HTTP_ENCRYPTION_REQUIRED)` sense.
- `-E` **after** `-p <queue>` means *"enable this destination and set it to accept jobs"* — equivalent to `cupsenable queue; cupsaccept queue`.

A queue created without a trailing `-E` exists but is disabled and rejecting, which is the classic "I created the printer and nothing prints" scenario.

**A3.2** — `/etc/cups/ppd/labps.ppd`. CUPS copies and normalises the model you selected into that path; it is the authoritative driver for the queue from then on, so editing the original source PPD later has no effect. `lpadmin -x labps` deletes the queue's stanza from `printers.conf`, removes `/etc/cups/ppd/labps.ppd`, and cancels the queue's jobs.

**A3.3** — A raw queue has **no PPD**, so CUPS performs no filtering: the job data is passed to the backend byte-for-byte. It is correct when the client already produces the printer's native language (a Windows client with the vendor driver printing through a Linux CUPS relay, or a label/receipt printer fed ZPL/ESC-POS). Send a PDF to a raw queue attached to a PCL printer and the printer receives PDF source it cannot interpret — you get garbage pages or nothing. Raw queues are deprecated in current CUPS and are being removed in CUPS 3.x.

**A3.4** — `-m <model>` names a driver from the scheduler's own catalogue as reported by `lpinfo -m` (a URI-ish string such as `everywhere`, `drv:///sample.drv/generic.ppd`, or a `.ppd.gz` path relative to `/usr/share/cups/model/`). `-P <file.ppd>` points at an arbitrary PPD file on the local filesystem, typically one you downloaded from the vendor. Both end with a copy in `/etc/cups/ppd/<queue>.ppd`.

**A3.5** — `socket://192.0.2.40:9100` → the `socket` backend, raw AppSocket/JetDirect over **TCP 9100** (default when the port is omitted); no protocol negotiation, no status beyond "the TCP connection worked". `ipp://printer.example.com/ipp/print` → the `ipp` backend, IPP over HTTP on **TCP 631**, giving real job state, media/supply attributes and driverless capability discovery. Prefer `ipp`/`ipps` whenever the device supports it.

### Block 4

**A4.1** — SysV: `lp -d hp2055 -n 5 manual.pdf`. Berkeley: `lpr -P hp2055 -#5 manual.pdf`. Remember `-n` vs `-#`, and `-d` vs `-P`.

**A4.2** — No — the file contains only the **last** job. The CUPS `file` backend opens the target with create/truncate semantics, so every job overwrites the previous one. That is why `file:` is a debugging device, not a "print to PDF" solution; for the latter use a real virtual-printer backend (`cups-pdf`) that generates a uniquely named output file per job in the submitting user's directory.

**A4.3** — In order, first match wins:
1. the command line (`lp -d`, `lpr -P`);
2. the `LPDEST` environment variable;
3. the `PRINTER` environment variable;
4. the user's default in `~/.cups/lpoptions` (set with `lpoptions -d`);
5. the system-wide client default in `/etc/cups/lpoptions`;
6. the server default set with `lpadmin -d` (recorded in `printers.conf`/`classes.conf` and reported by `lpstat -d`).

**A4.4** — (1) Identifier syntax: `cancel` takes a full CUPS job ID `queue-NN` (or a bare number), while `lprm` takes bare job numbers and needs `-P queue` for a non-default destination. (2) Bulk semantics: `cancel -a [queue]` cancels all jobs on a destination, `cancel -u user` all of a user's; `lprm -` cancels *the invoking user's* jobs, and `lprm` with no argument cancels only the current/first job. `cancel` additionally has `-x` to purge job history, which has no `lprm` equivalent.

**A4.5** — `lpstat -W completed -o` (optionally with the queue name). `lpstat -o` shows only *not-completed* jobs by default, so a job that CUPS believes finished is invisible there. If the job appears as completed, CUPS handed the data to the backend successfully and the problem is downstream (device, driver, output tray); if it never appears at all, the job was cancelled, purged, or never accepted.

### Block 5

**A5.1**

| | **Enabled** (printing) | **Disabled** (`cupsdisable`) |
|---|---|---|
| **Accepting** (`cupsaccept`) | Normal operation: job accepted and printed. | Job **accepted and queued**; nothing prints until `cupsenable`. Nothing is lost. |
| **Rejecting** (`cupsreject`) | Submission fails at once (`Destination "x" is not accepting jobs`); jobs already queued **continue to print** and the queue drains. | Submission fails *and* nothing prints — the fully closed state, used before deleting a queue. |

The two axes are independent: `accept/reject` gates the *front door* (new submissions), `enable/disable` gates the *back door* (sending to the device).

**A5.2** — `sudo cupsreject -r "Printer replaced 08:00 tomorrow — use hp-2f" hp-2e`. It stops new work from piling up and, crucially, gives users the reason string in the error message they get from `lp`, while jobs already queued still print out on the old device. `cupsdisable` would be wrong — it accepts jobs into a queue that will be deleted. `cupsdisable -c` would destroy pending work. Doing nothing leaves users printing to a machine that disappears overnight.

**A5.3** — `enable` and `disable` collide with the **shell built-in** `enable` (bash) and with the SysV names, so `enable hp1` in a script may toggle a shell builtin rather than a print queue, and the result depends on the shell and on `PATH`. CUPS 1.4 renamed the commands to `cupsenable` and `cupsdisable` (keeping `/usr/sbin/enable`/`disable` as compatibility links on some distributions). Always write `cupsenable`/`cupsdisable` in scripts.

**A5.4** — `cupsdisable -c <queue>` — `-c` cancels all jobs on the destination as it stops it. (`cupsdisable --hold` is the gentler variant: it holds the job currently printing so it restarts cleanly rather than being lost.)

### Block 6

**A6.1** — `-H hold` holds it (`-H resume` releases it); `-i <job-id>` selects the existing job to modify. So: `lp -i labps-42 -H hold`. Without `-i`, `lp -H hold file` submits a *new* job in the held state.

**A6.2** — `no-hold` (print immediately), `indefinite` (hold until explicitly released), `day-time`, `evening`, `night`, `weekend`, `second-shift`, `third-shift`. A bare `HH:MM` (or `HH:MM:SS`) is interpreted in **UTC/GMT**, not local time — a very common operational surprise when scheduling overnight batches.

**A6.3** — `1` (lowest) to `100` (highest); the default is `50`. Raising the priority of a job that is **already printing** has no effect on that job — priority only orders *pending* jobs in the queue. To jump a queue you must hold the current job or raise the pending job's priority before the device picks it up.

**A6.4**
```bash
sudo cupsdisable -r "Hardware failure — jobs moved to hp-2f" hp-2e
sudo lpmove hp-2e hp-2f
```
Disable first: if you move jobs while `hp-2e` is still enabled, the scheduler may hand another one to the dead device while you work. Consider `cupsreject hp-2e` as well so nothing new arrives.

**A6.5** — By the form of the argument. A bare number or `queue-NNN` is a **job**, and the command moves that single job. A destination name is a **queue**, and the command moves *all* of that queue's pending jobs to the target. This is why naming a printer something numeric is a bad idea.

### Block 7

**A7.1** — A class is a named set of printers that acts as a single destination; CUPS routes each job to the first available member. It gives you **load distribution and automatic failover** across physically distinct devices — if one member is disabled or busy, the next takes the job — which a single queue pointed at one device cannot provide. Implicit members' states are respected, so maintenance on one printer is invisible to users. Classes may even contain other classes.

**A7.2** — CUPS **deletes the class automatically** when its last member is removed. Classes have no independent existence; they are defined entirely by their membership in `classes.conf`.

**A7.3**
- `lpadmin -d <dest>` — **server-wide** default, affects everyone with no other preference; stored by `cupsd` in `printers.conf`/`classes.conf` and reported by `lpstat -d`.
- `lpoptions -d <dest>` as a user — **that user only**; stored in `~/.cups/lpoptions`.
- `LPDEST` — **that shell/process only**, and it overrides the `lpoptions` default.

Only the first affects other users.

**A7.4** — As root, `lpoptions` writes `/etc/cups/lpoptions` (client defaults for every user on that machine). As an unprivileged user it writes `~/.cups/lpoptions`. The system file survives deletion of any home directory; the per-user file does not. Note both are *client-side* option defaults, distinct from `lpadmin -o`, which stores the default on the **server** in `printers.conf` and therefore applies to remote clients too.

**A7.5** — Because the default resolves per user and per environment: your colleague may have their own `~/.cups/lpoptions` default, or `LPDEST`/`PRINTER` exported in their shell profile, either of which outranks the server default that `lpadmin -d` set. Check `lpoptions -d`-set files and `env | grep -E 'LPDEST|PRINTER'` in their session.

### Block 8

**A8.1** — The **page log**, `/var/log/cups/page_log` (path set by `PageLog` in `cups-files.conf`). Quotas are computed by counting entries in it for that user/printer within `job-quota-period`. If `PageLog` is disabled or redirected in a way CUPS cannot read back, `job-page-limit` and `job-k-limit` silently stop being enforced.

**A8.2** — `lpadmin -u allow:…` / `deny:…` sets the IPP attributes `requesting-user-name-allowed` / `-denied` on the destination: the connection succeeds, the job is *submitted*, and the **scheduler refuses it** based on the requesting user name. A `<Location>` block with `Require user …` (or `AuthType`) works one layer lower, at the **HTTP/IPP request** level, and can demand actual authentication — the request is rejected with `401`/`403` before job semantics are considered. Rule of thumb: `-u` expresses policy about identities CUPS merely *believes*; `<Location>` + `AuthType` is where identities are *proven*.

**A8.3** — (1) The user's group membership has not taken effect in their current session — group changes apply at next login (`id` will show it only after re-login; verify with `id <user>` vs `id` in their shell). (2) The `<Location /admin>` block still restricts by address (`Allow localhost` only) so a remote browser is refused regardless of group, or the `<Policy>` `Require user @SYSTEM` requires an authentication type the client is not offering. Also check that `SystemGroup` names a group that actually exists on this host (`getent group lpadmin`) and that the web interface is enabled (`WebInterface Yes`).

**A8.4** — `MaxJobs 0` means **unlimited** queued jobs (no scheduler-wide cap). `MaxJobs 1` means the scheduler retains at most one job total — as a new job arrives, the oldest completed one is discarded to make room. `0` as "no limit" is a recurring CUPS convention (`MaxLogSize 0` disables rotation, `JobRetryLimit 0` means retry forever).

### Block 9

**A9.1** — `c00042` is the **control file**: the job's IPP attribute set in binary IPP encoding (job name, owner, originating host, priority, copies, requested options, timestamps, destination URI). `d00042-001` is the **data file**: document 1's actual bytes as submitted. By default `PreserveJobFiles` is off/short-lived, so the **data file is removed as soon as the job completes**, while `PreserveJobHistory` keeps the control file (so `lpstat -W completed` still works) until it expires or you run `cancel -x`.

**A9.2** — `0710` = owner (root) full access; group (`lp`) has **execute/search only, no read**; others nothing. Group members can therefore `open()` a spool file *whose exact name they already know* (which is how CUPS's own helpers reach them) but cannot `ls` the directory to enumerate other users' jobs. With `0755`, any local user could list — and with readable files, read — the contents of everyone's print jobs: payslips, contracts, medical records. The mode is a deliberate confidentiality control.

**A9.3** — `/var/log/cups/page_log`. Fields are `printer user job-id [timestamp] page-number num-copies job-billing hostname job-name media sides`. Total pages for a job = sum over its lines of (page-number entries) × `num-copies`; in practice you count lines per job and multiply by copies, or use the `total N` form emitted for some drivers. Group by field 2 (user) and field 1 (printer), filtering on the timestamp in field 4.

**A9.4** — `access_log` records every IPP request with the client address in the first field and the operation name (`Print-Job`) plus IPP status near the end; `page_log` records the originating **hostname** field for each printed page along with the user and timestamp. Both outlive the job itself, whereas the spool control file does not. `page_log` is the stronger record for "this host printed this document at this time".

**A9.5** — `sudo cupsctl --no-debug-logging`. `cupsctl` submits an IPP `CUPS-Set-Default`-style administrative request; `cupsd` rewrites `cupsd.conf` and performs an **internal reload**, not a process restart, so open jobs and the currently printing document are unaffected. Follow up with `MaxLogSize` (e.g. `MaxLogSize 10m`) or logrotate to bound growth structurally.

### Block 10

**A10.1** — For a shared office printer, `stop-printer` is right: the failure is usually transient and physical (paper out, cable pulled, powered off). Keeping the job and halting the queue means the user's document prints untouched once someone fixes the device, and the loud "printer stopped" state is what prompts the fix. On an unattended batch server the same behaviour is a self-inflicted outage: one bad job stops thousands of good ones and nobody is watching the console. There, either retry or drop:
```bash
sudo lpadmin -p batchq -o printer-error-policy=retry-job
```
(tune `JobRetryInterval`/`JobRetryLimit` in `cupsd.conf`), or `-o printer-error-policy=abort-job` if the queue must never stall and losing a job is acceptable.

**A10.2**
```bash
lpstat -r                       # 1. is the scheduler even running?
lpstat -t                       # 2. overview: default, devices, accepting, enabled
lpstat -p -l <queue>            # 3. queue state + printer-state-message/reasons
lpstat -o <queue> -l            # 4. is the job queued, held, or gone?
lpstat -W completed -o <queue>  #    ...or already "completed" (=> problem is past CUPS)
sudo tail -50 /var/log/cups/error_log        # 5. filter/backend errors + exit status
sudo cupsctl --debug-logging                 #    reproduce, then grep "[Job N]"
cupsfilter -m application/vnd.cups-raster f  # 6. filter chain in isolation
nc -vz <printer-ip> 9100                     # 7. transport/device reachability
```
Then reverse: `cupsctl --no-debug-logging`.

**A10.3** — The printer received PostScript it cannot interpret — it is not a PostScript device, or the data bypassed conversion. Check first: (a) is the queue **raw** (no PPD in `/etc/cups/ppd/<queue>.ppd`, `lpstat -l -p` shows no driver)? (b) is the assigned **PPD the wrong driver** for the model (a generic PostScript PPD attached to a PCL-only printer)? Fix by assigning the correct `-m`/`-P` driver, or `-m everywhere` for an IPP Everywhere device. A secondary cause is submitting with `lpr -l`/`-o raw`, which explicitly suppresses filtering.

**A10.4** — `cupsfilter` runs the same filter chain `cupsd` would run, **outside the scheduler**, on the command line, showing you the filter's stderr directly and letting you inspect the produced output. That cleanly separates "the driver/filter chain is broken or missing" from "the device or backend is unreachable" — a distinction a test job cannot make, because both fail the same way from the user's point of view. `--list-filters` additionally prints the chain that *would* be used without executing it.

**A10.5** — The device or its data path, not CUPS: CUPS accepted the job, filtered it, the backend reported success and it was retired to history. Look at (a) the backend/device URI — a `file:` URI or a wrong IP silently "succeeds"; (b) the physical printer (offline, wrong tray, another queue on the same device); (c) `page_log` to confirm CUPS believes pages were produced; (d) the printer's own web page/panel for its job log. Confirm with `lpstat -v <queue>` first — a queue pointed at the wrong device is the single most common cause.

### Block 11

**A11.1**
| Protocol | Transport | Port |
|---|---|---|
| IPP | HTTP over TCP | **631** |
| IPPS | HTTPS over TCP | **631** (TLS; `ipps://`) |
| LPD (RFC 1179) | TCP | **515** |
| Raw / AppSocket / JetDirect | TCP | **9100** (also 9101/9102 for multi-port devices) |
| mDNS / DNS-SD discovery | UDP | **5353** |
| SMB printing | TCP | 445 (139 legacy) |

**A11.2** — `Port 631` is shorthand for listening on **all** addresses (IPv4 and IPv6) on port 631. `Listen 631` is equivalent in effect but uses the address-capable syntax. `Listen localhost:631` restricts to the loopback interface — the default on modern distributions, meaning the server is unreachable from the network until you change it. `Listen /run/cups/cups.sock` adds the UNIX domain socket. Combine explicit `Listen` lines rather than `Port` when you want per-interface control.

**A11.3** — `cupsd` **shares**: it advertises its own shared queues via DNS-SD and answers IPP requests for them. `cups-browsed` **consumes**: it is a separate daemon that listens for advertisements (DNS-SD, and legacy CUPS browsing) and **creates local queues** on the client automatically for the remote printers it discovers, removing them when the advertisement stops. So the server side needs `Browsing`/`printer-is-shared`; the client side needs `cups-browsed` (or a manually created `ipp://` queue). Since CUPS 1.6, `cupsd` no longer implements the old broadcast browsing protocol itself — that job moved to `cups-browsed` in cups-filters.

**A11.4** — **`cupsd` writes it**, at the path given by the `Printcap` directive in `cups-files.conf` (typically `/etc/printcap`), regenerating it whenever queues change. It exists purely as a compatibility shim: older applications parse `/etc/printcap` to build their printer menus. Hand-editing it accomplishes nothing — the file is overwritten on the next queue change or scheduler restart, and CUPS never reads it back. To change what appears there, change the queues with `lpadmin`.

**A11.5** — The `cups-lpd` mini-daemon, which speaks RFC 1179 and translates to IPP. It is socket-activated, not a standalone service: enable `cups-lpd.socket` (systemd) or the `cups-lpd` entry under xinetd, and open **TCP 515** in the firewall. Because RFC 1179 has no authentication and transmits in the clear, restrict it by source address at the firewall and treat it as a legacy bridge, not a general service.

**A11.6** — `lp -h server -d q file` uses the remote server **directly, per invocation**: nothing is configured locally, no local queue exists, and if the server is down the command simply fails. It suits ad-hoc use and scripts on hosts you do not want to configure. A local queue with `ipp://server/printers/q` makes the printer a **first-class local destination**: it appears in `lpstat -a` and every GUI, can be the default, can carry local options and a local driver, and can queue jobs locally when the server is briefly unavailable. Use the local queue for anything users interact with; use `-h` for automation and troubleshooting.

### Block 12

**A12.1** — (1) `/etc/cups/printers.conf` — the `<Printer …>` stanza is gone (rewritten by `cupsd`). (2) `/etc/cups/ppd/<queue>.ppd` — deleted. (3) `/etc/printcap` — regenerated without the queue. Also: `/etc/cups/classes.conf` if the queue was a class member (and the class itself vanishes if it was the last member), the spool under `/var/spool/cups` for that queue's jobs (cancelled), and `/etc/cups/lpoptions` / `~/.cups/lpoptions` may retain now-dangling entries for it.

**A12.2** — With `FileDevice Yes`, any user authorized to create or modify a queue can set a device URI like `file:/etc/shadow` or `file:/etc/cron.d/anything`, and the CUPS `file` backend — which runs with root privileges — will write attacker-controlled job data there. That converts "can administer printers" into "can write arbitrary root-owned files", i.e. full local privilege escalation. The default is `No` for exactly this reason; enable it only on an isolated machine and turn it off again, as in this step.

</details>