# LPI 702-100 (BSD Specialist v1.0) — Production Engineering & SRE Guide
## Topic 713.2: Automate System Administration Tasks by Scheduling Jobs (Weight: 3.33)

---

### Official References & Technical Documentation
* **LPI BSD Specialist Certification Overview**: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD `cron(8)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8)
* **FreeBSD `crontab(5)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=crontab&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=crontab&sektion=5)
* **FreeBSD `periodic(8)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8)
* **FreeBSD `periodic.conf(5)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=periodic.conf&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=periodic.conf&sektion=5)
* **FreeBSD `at(1)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1)

---

### Architectural Overview & Internal Mechanics

```
                             +-------------------------------------------------------+
                             |                     cron(8) Daemon                    |
                             |  - Wakes up every 60s at minute boundary (sleep(60))  |
                             |  - Parses system /etc/crontab & user /var/cron/tabs/*  |
                             +---------------------------+---------------------------+
                                                         |
                   +-------------------------------------+-------------------------------------+
                   |                                                                           |
                   v                                                                           v
     +---------------------------+                                               +---------------------------+
     |   System Crontab (7-col)  |                                               |    User Crontab (6-col)    |
     |   /etc/crontab            |                                               |    /var/cron/tabs/<user>  |
     +-------------+-------------+                                               +-------------+-------------+
                   |                                                                           |
                   | (Invokes periodic scripts)                                                | (Direct command)
                   v                                                                           v
     +---------------------------+                                               +---------------------------+
     |        periodic(8)        |                                               |  Non-interactive Shell    |
     |  /usr/sbin/periodic       |                                               |  (SHELL=/bin/sh, HOME)    |
     +-------------+-------------+                                               +---------------------------+
                   |
     +-------------+-------------+-------------+
     |             |             |             |
     v             v             v             v
  daily        weekly        monthly       atrun(8)
(/etc/periodic/ /etc/periodic/ /etc/periodic/    |
 daily/*)       weekly/*)      monthly/*)        v
                                          Processes queued jobs in
                                          /var/at/jobs/
```

#### 1. BSD Cron Subsystem Architecture (`cron(8)` & `crontab(5)`)
The BSD job scheduling architecture centers on `cron(8)`, a background daemon started at boot time by `rc(8)`. 
* **Execution Loop**: `cron(8)` calculates the sleep interval to wake up exactly at the zero-second mark of the next minute. Upon waking, it checks the modification timestamps (`mtime`) of `/etc/crontab`, `/etc/cron.d` (if enabled), and `/var/cron/tabs/` to refresh its in-memory task tables without requiring a daemon restart.
* **System vs User Crontabs**:
  * **System Crontab (`/etc/crontab`)**: Contains **7 fields**. Field 6 explicitly specifies the **username** under which the command (Field 7) will execute.
    $$\text{Format: } \langle\text{min}\rangle \quad \langle\text{hour}\rangle \quad \langle\text{mday}\rangle \quad \langle\text{month}\rangle \quad \langle\text{wday}\rangle \quad \mathbf{\langle\text{username}\rangle} \quad \langle\text{command}\rangle$$
  * **User Crontabs (`/var/cron/tabs/<user>`)**: Contains **6 fields**. The execution context is strictly locked to the owner of the crontab file.
    $$\text{Format: } \langle\text{min}\rangle \quad \langle\text{hour}\rangle \quad \langle\text{mday}\rangle \quad \langle\text{month}\rangle \quad \langle\text{wday}\rangle \quad \langle\text{command}\rangle$$
* **Environment Execution Context**: `cron(8)` runs jobs in a minimal non-interactive shell. Default environment variables populated at runtime:
  * `PATH=/usr/bin:/bin` (FreeBSD defaults to a restrictive path; explicit binary paths are mandatory in production scripts).
  * `SHELL=/bin/sh`
  * `HOME=<home_directory_of_target_user>`
  * `LOGNAME=<target_user>` / `USER=<target_user>`
  * `MAILTO=<target_user>` (Standard output and standard error are captured and piped via local MTA to `MAILTO`. If `MAILTO=""`, email notifications are suppressed).

#### 2. The BSD `periodic(8)` Maintenance Framework
Unlike Linux systems that often rely on `anacron` or `systemd.timer` units, BSD systems use `periodic(8)` to orchestrate regular maintenance tasks.
* **Invocation**: Executed by `cron(8)` from `/etc/crontab` at specific time windows (daily, weekly, monthly).
* **Directory Hierarchy & Precedence**:
  1. Base system scripts: `/etc/periodic/daily/`, `/etc/periodic/weekly/`, `/etc/periodic/monthly/`, `/etc/periodic/security/`
  2. Ports/Third-party packages: `/usr/local/etc/periodic/daily/`, `/usr/local/etc/periodic/weekly/`, etc.
* **Configuration Cascade**:
  * Default configuration: `/etc/defaults/periodic.conf` (MUST NOT be edited directly).
  * System overrides: `/etc/periodic.conf`
  * Local overrides: `/etc/periodic.conf.local`
* **Execution Flow**: `periodic` parses the target directory, sorts scripts lexicographically (e.g., `100.clean-disks`, `200.backup`), evaluates corresponding control variables in `/etc/periodic.conf` (e.g., `daily_clean_disks_enable="YES"`), runs enabled scripts, and collects output into a log or email report.
* **Standard Return Codes for Periodic Scripts**:
  * `0`: Success, no notable output generated.
  * `1`: Task executed, informational output generated (included in report).
  * `2`: Warning / non-fatal error encountered.
  * `3`: Fatal error encountered.

#### 3. One-Time Job Scheduling (`at(1)` & `atrun(8)`)
* **Architecture**: The `at(1)` utility queues shell commands to be executed at a specific future time.
* **BSD Spool Mechanism**: Jobs are stored as shell scripts in `/var/at/jobs/` (or `/var/at/spool/`), prefixed by execution timestamp bitmasks.
* **Execution Engine (`atrun(8)`)**: Unlike systems running a persistent `atd` daemon, classic BSD executes `/usr/libexec/atrun` periodically via `/etc/crontab` (typically `*/5 * * * * root /usr/libexec/atrun`). `atrun(8)` checks `/var/at/jobs/` for jobs whose execution timestamp is equal to or earlier than the current epoch, executes them under `setuid` to the owner, and deletes the job file.

#### 4. Access Control Architecture
* **Cron Access Control**:
  * `/var/cron/allow`: If present, only users listed here may use `crontab -e`.
  * `/var/cron/deny`: Evaluated ONLY if `/var/cron/allow` does NOT exist. Users listed here are prohibited.
  * If neither file exists, only `root` (or all users, depending on system configuration) can submit user crontabs.
* **At Access Control**:
  * `/etc/at.allow` (or `/var/at/at.allow` depending on BSD distribution): Whitelist for `at(1)` usage.
  * `/etc/at.deny` (or `/var/at/at.deny`): Blacklist evaluated only when allow file is absent.

---

### Guided Practical Exercises

#### Exercise 1: System-wide vs User Crontabs, Environment Traps, and Concurrency Locking

##### Objective
Configure both a system-wide `/etc/crontab` and a user-level crontab. Diagnose environment variable discrepancies and enforce job concurrency prevention using FreeBSD `lockf(1)`.

##### Step 1: Inspect and verify `/etc/crontab` syntax
Inspect the existing `/etc/crontab` structure to verify the 7-field format.

```bash
cat /etc/crontab
```

###### Expected Output
```text
# /etc/crontab - root's crontab for FreeBSD
#
SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
#
#minute	hour	mday	month	wday	who	command
#
*/5	*	*	*	*	root	usr/libexec/atrun
# Perform daily/weekly/monthly maintenance.
1	3	*	*	*	root	periodic daily
15	4	*	*	1	root	periodic weekly
30	5	1	*	*	root	periodic monthly
```

##### Step 2: Create a failure scenario due to PATH environment mismatch
Create a script at `/usr/local/bin/db_backup.sh` that relies on binaries not standard in `/bin`.

```bash
sudo mkdir -p /usr/local/bin
sudo tee /usr/local/bin/db_backup.sh > /dev/null << 'EOF'
#!/bin/sh
echo "=== Execution timestamp: $(date) ==="
echo "PATH inside cron is: $PATH"
which zfs > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: zfs executable not found in PATH!" >&2
    exit 100
fi
echo "ZFS binary detected successfully at $(which zfs)"
EOF

sudo chmod +x /usr/local/bin/db_backup.sh
```

##### Step 3: Install a user crontab with an explicit, restrictive PATH
Edit the current user's crontab using `crontab -e` (or pipe via `crontab -` for automation).

```bash
(
cat << 'EOF'
PATH=/bin:/usr/bin
MAILTO=""
* * * * * /usr/local/bin/db_backup.sh >> /tmp/cron_test.log 2>&1
EOF
) | crontab -
```

Verify installation of the crontab file:

```bash
crontab -l
```

###### Expected Output
```text
PATH=/bin:/usr/bin
MAILTO=""
* * * * * /usr/local/bin/db_backup.sh >> /tmp/cron_test.log 2>&1
```

##### Step 4: Validate cron execution and diagnose log output
Wait 60 seconds for `cron(8)` to execute the job, then inspect `/tmp/cron_test.log`.

```bash
sleep 65
cat /tmp/cron_test.log
```

###### Expected Output
```text
=== Execution timestamp: Thu Aug  6 20:45:00 UTC 2026 ===
PATH inside cron is: /bin:/usr/bin
ERROR: zfs executable not found in PATH!
```

##### Step 5: Fix the PATH and apply production lock control (`lockf(1)`)
Update the crontab to include `/sbin` in `PATH` and use `lockf(1)` to ensure that if a backup job takes longer than 60 seconds, concurrent instances are blocked.

```bash
(
cat << 'EOF'
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
MAILTO="admin@example.com"
* * * * * lockf -t 0 /tmp/db_backup.lock /usr/local/bin/db_backup.sh >> /tmp/cron_test.log 2>&1
EOF
) | crontab -
```

Wait for execution and verify output:

```bash
sleep 65
tail -n 5 /tmp/cron_test.log
```

###### Expected Output
```text
=== Execution timestamp: Thu Aug  6 20:46:00 UTC 2026 ===
PATH inside cron is: /sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
ZFS binary detected successfully at /sbin/zfs
```

---

##### Verification Questions — Exercise 1

**Question 1.1**: What is the structural difference between a line in `/etc/crontab` and a line in a user's crontab edited via `crontab -e`?
1. User crontabs contain an extra environment column for `MAILTO`.
2. `/etc/crontab` contains 7 columns (specifying the target user execution context), whereas user crontabs contain 6 columns.
3. User crontabs use 7 columns (specifying user execution context), whereas `/etc/crontab` uses 5 columns.
4. `/etc/crontab` does not support environment variable declarations like `PATH` or `SHELL`.

**Question 1.2**: In Step 5, what is the exact function of the `lockf -t 0 /tmp/db_backup.lock` command wrapper?
1. It encrypts the stdout of `/usr/local/bin/db_backup.sh` before appending to `/tmp/cron_test.log`.
2. It waits up to 0 seconds (fails immediately without executing the new instance) if another process holds an exclusive lock on `/tmp/db_backup.lock`.
3. It limits the execution time of `/usr/local/bin/db_backup.sh` to 0 seconds before sending `SIGKILL`.
4. It changes process ownership of `/usr/local/bin/db_backup.sh` to user `lockf`.

**Question 1.3**: Where are user crontab files stored on a standard FreeBSD system?
1. `/etc/cron.d/<username>`
2. `/var/spool/cron/crontabs/<username>`
3. `/var/cron/tabs/<username>`
4. `/usr/local/etc/cron/tabs/<username>`

---

#### Exercise 2: Advanced BSD `periodic(8)` Engineering and Custom Script Development

##### Objective
Understand the `periodic(8)` execution engine, create a syntactically valid custom maintenance script in `/usr/local/etc/periodic/daily/`, register its configuration in `/etc/periodic.conf`, and execute manual validation runs.

##### Step 1: Inspect the base system periodic default configuration
Examine the master default settings file `/etc/defaults/periodic.conf` to understand how periodic tasks are defined.

```bash
grep -E "daily_clean|daily_show" /etc/defaults/periodic.conf | head -n 10
```

###### Expected Output
```text
daily_clean_disks_enable="NO"
daily_clean_disks_days=3
daily_clean_disks_show_scanned="YES"
daily_clean_tmps_enable="NO"
daily_clean_tmps_days="3"
daily_clean_tmps_ignore="Quota.user Quota.group .snap"
daily_clean_preserve_enable="YES"
daily_clean_preserve_days=7
daily_clean_msgs_enable="YES"
```

##### Step 2: Develop a custom BSD periodic script
Create a custom daily script named `999.zfs-snapshot-audit` under `/usr/local/etc/periodic/daily/`. The script must respect `/etc/periodic.conf` settings and adhere to BSD periodic return code conventions.

```bash
sudo mkdir -p /usr/local/etc/periodic/daily

sudo tee /usr/local/etc/periodic/daily/999.zfs-snapshot-audit > /dev/null << 'EOF'
#!/bin/sh

# If source periodic config files exist, read them.
if [ -r /etc/defaults/periodic.conf ]; then
    . /etc/defaults/periodic.conf
fi

# Define local override default if not set in /etc/periodic.conf
: ${daily_zfs_snapshot_audit_enable:="NO"}
: ${daily_zfs_snapshot_audit_pools:="zroot"}

rc=0

case "$daily_zfs_snapshot_audit_enable" in
    [Yy][Ee][Ss])
        echo ""
        echo "Checking ZFS snapshot compliance..."
        for pool in $daily_zfs_snapshot_audit_pools; do
            zfs list -t snapshot -r "$pool" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                snap_count=$(zfs list -t snapshot -H -o name -r "$pool" | wc -l | tr -d ' ')
                echo "  Pool '$pool': $snap_count snapshots present."
            else
                echo "  WARNING: Pool '$pool' does not exist or has no datasets."
                rc=2
            fi
        done
        ;;
    *)
        # Disabled - exit cleanly without output
        rc=0
        ;;
esac

exit $rc
EOF

sudo chmod 755 /usr/local/etc/periodic/daily/999.zfs-snapshot-audit
```

##### Step 3: Test periodic script in disabled state
Execute `periodic` manually for the `daily` queue and verify that our script does NOT produce output because it is disabled by default.

```bash
sudo periodic daily
```

###### Expected Output
*(No output returned, or only output from default enabled base tasks, because `daily_zfs_snapshot_audit_enable` defaults to `"NO"`).*

##### Step 4: Enable the custom periodic script in `/etc/periodic.conf`
Append the activation directives to `/etc/periodic.conf`.

```bash
sudo tee -a /etc/periodic.conf > /dev/null << 'EOF'
# Enable custom ZFS snapshot audit script
daily_zfs_snapshot_audit_enable="YES"
daily_zfs_snapshot_audit_pools="zroot non_existent_pool"
EOF
```

##### Step 5: Execute manual periodic run and verify exit codes and output
Run `periodic daily` manually to execute all enabled daily tasks including our new custom audit module.

```bash
sudo periodic daily
```

###### Expected Output
```text
Checking ZFS snapshot compliance...
  Pool 'zroot': 12 snapshots present.
  WARNING: Pool 'non_existent_pool' does not exist or has no datasets.
```

Verify that the exit code of `periodic daily` reflects the warning (`rc=2` returned by our custom module):

```bash
echo "Periodic execution exit code: $?"
```

###### Expected Output
```text
Periodic execution exit code: 2
```

---

##### Verification Questions — Exercise 2

**Question 2.1**: Why should an administrator NEVER edit `/etc/defaults/periodic.conf` directly to modify periodic job behaviors?
1. `/etc/defaults/periodic.conf` is stored on a read-only kernel ramdisk.
2. System updates (e.g., `freebsd-update`) overwrite `/etc/defaults/periodic.conf`. Custom settings must be declared in `/etc/periodic.conf` or `/etc/periodic.conf.local`.
3. Editing `/etc/defaults/periodic.conf` corrupts the digital signature checked by `cron(8)` at boot.
4. `periodic(8)` only reads `/etc/defaults/periodic.conf` if `/etc/periodic.conf` is completely missing.

**Question 2.2**: Where should third-party system maintenance scripts installed via FreeBSD Ports or custom administration tools be placed to be executed by `periodic daily`?
1. `/etc/periodic/daily/`
2. `/var/cron/periodic/daily/`
3. `/usr/local/etc/periodic/daily/`
4. `/usr/libexec/periodic/daily/`

**Question 2.3**: What is the significance of the return code `1` emitted by a script running inside the `periodic(8)` framework?
1. The script failed with a fatal error; `periodic` aborts subsequent script execution immediately.
2. The script completed successfully and generated informational output that should be included in the periodic summary report.
3. The script was skipped because its controlling variable in `/etc/periodic.conf` was set to `NO`.
4. The script encountered a syntax error during execution.

---

#### Exercise 3: One-off Job Automation via `at(1)`, Spool Inspection, and Access Control Security

##### Objective
Schedule immediate and delayed one-off jobs using `at(1)`, inspect spool files in `/var/at/jobs/`, manage queues via `atq(1)` and `atrm(1)`, and configure strict security access controls using `/var/cron/allow` and `/etc/at.allow`.

##### Step 1: Schedule a delayed task using `at(1)`
Schedule a synthetic system maintenance command to run 15 minutes in the future.

```bash
echo "logger -t AT_TEST 'Executing scheduled one-off task'" | at now + 15 minutes
```

###### Expected Output
```text
Job 1 will be executed using /bin/sh
```

##### Step 2: Query the `at` job queue using `atq(1)`
List all queued jobs pending execution.

```bash
atq
```

###### Expected Output
```text
Date                    Queue   Job#    User
Thu Aug  6 21:05:00 2026  c      1      root
```

##### Step 3: Inspect the internal spool representation in `/var/at/jobs/`
Examine the underlying spool file created by `at(1)`. The spool file contains the environment state captured at submission time.

```bash
sudo ls -l /var/at/jobs/
```

###### Expected Output
```text
total 4
-rwx------  1 root  wheel  2648 Aug  6 20:50 01a52029.00
```

Inspect the contents of the generated spool file to see how environment variables and commands are encapsulated:

```bash
sudo head -n 20 /var/at/jobs/01a52029.00
```

###### Expected Output
```text
#!/bin/sh
# atrun job 1
# mail root 0
umask 022
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin; export PATH
USER=root; export USER
HOME=/root; export HOME
SHELL=/bin/sh; export SHELL
cd /root || exit 1
logger -t AT_TEST 'Executing scheduled one-off task'
```

##### Step 4: Remove a queued job using `atrm(1)`
Delete the scheduled job using its job number.

```bash
atrm 1
atq
```

###### Expected Output
```text
(No output returned; queue is now empty)
```

##### Step 5: Enforce strict access control policies for `crontab` and `at`
Configure access control to restrict `crontab` usage to user `webadmin` and `root`.

Create `/var/cron/allow`:

```bash
sudo tee /var/cron/allow > /dev/null << 'EOF'
root
webadmin
EOF
```

Create `/etc/at.allow` to restrict `at(1)` usage:

```bash
sudo tee /etc/at.allow > /dev/null << 'EOF'
root
webadmin
EOF
```

Verify security enforcement by attempting `crontab` execution as an unauthorized user (e.g., `nobody`):

```bash
sudo -u nobody crontab -l
```

###### Expected Output
```text
crontab: You (nobody) are not allowed to use this program.
```

---

##### Verification Questions — Exercise 3

**Question 3.1**: On FreeBSD, how are scheduled `at(1)` jobs actually triggered and executed at their specified run time?
1. A persistent daemon named `atd(8)` runs continuously in the background and executes jobs via `kqueue(2)` timers.
2. The kernel directly executes queued jobs when reaching the epoch timestamp.
3. The `atrun(8)` utility is invoked periodically (typically every 5 minutes) by `/etc/crontab` as `root` to process pending spool files.
4. `periodic daily` parses `/var/at/jobs/` once per day.

**Question 3.2**: If both `/var/cron/allow` and `/var/cron/deny` exist on a FreeBSD system, which security policy file takes precedence?
1. `/var/cron/deny` takes precedence; any user listed in `/var/cron/deny` is blocked even if listed in `/var/cron/allow`.
2. `/var/cron/allow` takes precedence; only users listed in `/var/cron/allow` are permitted, and `/var/cron/deny` is ignored completely.
3. Both files are merged; users must appear in both files to obtain access.
4. Access is granted to all non-root users by default.

**Question 3.3**: Which command removes job number `42` from the `at` execution queue?
1. `at --delete 42`
2. `crontab -r 42`
3. `atrm 42` (or `at -r 42`)
4. `periodic --remove 42`

---

### Solutions & Deep-Dive Explanations

<details>
<summary><strong>Click to expand Solutions & Detailed Explanations</strong></summary>

#### Exercise 1 Solutions

* **Question 1.1**: **Correct Answer: 2**
  * **Explanation**: The system crontab (`/etc/crontab`) uses 7 fields: `minute hour mday month wday username command`. Field 6 explicitly states the user account context (e.g., `root`, `www`, `nobody`) under which `cron` executes the process. User crontabs created via `crontab -e` have 6 fields (`minute hour mday month wday command`) because the user context is implicitly defined by the owner of the crontab file stored in `/var/cron/tabs/<username>`.

* **Question 1.2**: **Correct Answer: 2**
  * **Explanation**: `lockf(1)` is the standard BSD lock manager utility for mutual exclusion. The flag `-t 0` specifies a timeout of 0 seconds. If `/tmp/db_backup.lock` is already locked by a previous running instance of the script, `lockf` exits immediately with a non-zero exit code without executing the target command. This prevents job overlapping and resource exhaustion when long-running backup processes are invoked by `cron`.

* **Question 1.3**: **Correct Answer: 3**
  * **Explanation**: Under FreeBSD, user crontab files managed by `crontab(1)` are stored in `/var/cron/tabs/<username>`. Access to this directory is strictly restricted to prevent unauthorized reading of sensitive credentials stored inside user crontabs.

---

#### Exercise 2 Solutions

* **Question 2.1**: **Correct Answer: 2**
  * **Explanation**: `/etc/defaults/periodic.conf` defines the base system defaults provided by the FreeBSD OS distribution. Upgrades via `freebsd-update` or source builds (`make installworld`) will overwrite this file. Administrators must declare local modifications in `/etc/periodic.conf` or `/etc/periodic.conf.local`, which override `/etc/defaults/periodic.conf` without being lost during OS upgrades.

* **Question 2.2**: **Correct Answer: 3**
  * **Explanation**: Following the FreeBSD filesystem hierarchy design (`hier(7)`), base system files reside in `/etc/periodic/`, whereas third-party applications, ports, and custom administrator scripts belong under `/usr/local/etc/periodic/<daily|weekly|monthly|security>/`.

* **Question 2.3**: **Correct Answer: 2**
  * **Explanation**: In the `periodic(8)` framework, return codes control log reporting:
    * `0`: Success without output (silent).
    * `1`: Success with output (the captured stdout/stderr is appended to the periodic report email).
    * `2`: Warning message encountered.
    * `3`: Fatal error encountered.

---

#### Exercise 3 Solutions

* **Question 3.1**: **Correct Answer: 3**
  * **Explanation**: Unlike Linux systems which use a continuous `atd` background daemon, standard BSD systems execute `/usr/libexec/atrun` every 5 minutes via a entry in system `/etc/crontab`:
    `*/5 * * * * root /usr/libexec/atrun`
    When invoked, `atrun(8)` scans `/var/at/jobs/`, identifies jobs whose trigger time has passed, executes them under the owner's credentials, and cleans up the spool file.

* **Question 3.2**: **Correct Answer: 2**
  * **Explanation**: BSD `cron(8)` security uses strict allow-list precedence:
    1. If `/var/cron/allow` exists, ONLY users explicitly named inside `/var/cron/allow` are permitted to use `crontab`. The `/var/cron/deny` file is ignored.
    2. If `/var/cron/allow` does NOT exist, `/var/cron/deny` is checked. Users listed in `deny` are blocked.
    3. If neither file exists, default security restrictions apply (on FreeBSD, only `root` is allowed unless configured otherwise).

* **Question 3.3**: **Correct Answer: 3**
  * **Explanation**: `atrm(1)` (or its alias `at -r`) removes jobs from the `at` spool directory using the job identifier displayed by `atq(1)`.

</details>