# LPI 702 Study Guide: Topic 713.2 – Automate System Administration Tasks by Scheduling Jobs

**Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic 713:** Basic BSD System Administration  
**Objective:** 713.2 Automate System Administration Tasks by Scheduling Jobs  
**Weight:** 3.33  

---

## 1. Motivation & Production Architectural Problem

### 1.1 The Operational Challenge in Mission-Critical BSD Infrastructure
In enterprise-grade BSD production environments—ranging from FreeBSD core routers and Storage Area Networks (SANs utilizing ZFS) to OpenBSD edge firewalls—unattended execution of administrative tasks is required for operational resilience. System processes such as log rotation (`newsyslog`), ZFS pool scrubbing (`zpool scrub`), security audit reporting (`periodic security`), package updates, and database dumps must execute deterministically without manual human intervention.

However, uncoordinated asynchronous job execution introduces severe architectural hazards:
1. **Resource Contention & Thundering Herd Problem:** Simultaneous execution of I/O-intensive jobs (e.g., full disk backups alongside ZFS scrub and database maintenance) during peak operational hours degrades system responsiveness, causing storage queue depth saturation and CPU throttling.
2. **Silent Failure & Absence of Observability:** Standard crontabs send failure outputs via local Mail Transfer Agents (MTA such as `sendmail` or `dma`). In headless server environments lacking active local mailbox delivery, failed cron jobs terminate silently, creating hidden operational drift.
3. **Environment Isolation Anomalies:** The `cron(8)` daemon initializes a stripped-down environment (`SHELL=/bin/sh`, restricted `PATH=/usr/bin:/bin`). Administrative scripts relying on full interactive login profiles (`.bashrc`, `.zshrc`, `/etc/profile`) fail at runtime due to missing binary lookup paths or uninitialized environment variables.
4. **Race Conditions & Overlapping Executions:** Long-running scheduled tasks that exceed their invocation interval risk spawning concurrent child processes. Without concurrency locking (e.g., `lockf(1)` on BSD or atomic lock files), duplicate tasks collide on locked database files or shared file descriptors, risking data corruption.

---

### 1.2 Mechanics of Job Scheduling in BSD Systems

#### The BSD `cron(8)` Daemon Architecture
The BSD `cron(8)` daemon runs continuously in the background as a system service initialized during runlevel processing by `/etc/rc.d/cron`. Unlike standard Linux implementations that wake up every 60 seconds via polling, BSD `cron(8)` computes the exact time to wait until the next scheduled minute boundary, calling `sleep()` or `nanosleep()` accordingly.

```
                      +-----------------------------+
                      |    /etc/rc.d/cron (Daemon)  |
                      +--------------+--------------+
                                     |
                +--------------------+--------------------+
                |                                         |
    +-----------v-----------+                 +-----------v-----------+
    |  System Crontab File  |                 |     User Spool Tabs   |
    |    /etc/crontab       |                 |   /var/cron/tabs/*    |
    +-----------+-----------+                 +-----------+-----------+
                |                                         |
                | (Includes 'who' field)                  | (No 'who' field)
                +--------------------+--------------------+
                                     |
                             +-------v-------+
                             |   fork() /    |
                             |   setuid()    |
                             +-------+-------+
                                     |
                             +-------v-------+
                             | Exec Command  |
                             | via /bin/sh   |
                             +---------------+
```

When changes occur to user spool files (`/var/cron/tabs/<username>`), the `crontab(1)` command updates the file modification timestamp (`mtime`). BSD `cron(8)` checks the directory timestamp every minute and dynamically reloads modified tables into memory without requiring a daemon restart or `SIGHUP` signal.

#### The `periodic(8)` Subsystem Architecture
FreeBSD and NetBSD feature an abstraction layer over raw crontab entries: the `periodic(8)` script framework. Instead of scattering dozens of discrete shell scripts across crontab lines, system maintenance is modularized into four lifecycle tiers:
- **`daily`**: Cleans `/tmp`, rotates system logs, checks ZFS pool status, reports disk space usage.
- **`weekly`**: Rebuilds `locate(1)` databases, checks `catman` pages, runs security checks.
- **`monthly`**: Audits user account expiration, checks system accounting (`acct`).
- **`security`**: Parses auth logs, validates file checksums via `setuid` audits, and checks network interface status.

System defaults reside in `/etc/defaults/periodic.conf`. Operators configure site-specific overrides strictly within `/etc/periodic.conf` or `/etc/periodic.conf.local`.

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Job Scheduling Paradigms in BSD & Cloud-Native Architectures

| Metric / Dimension | User Crontab (`crontab -e`) | System Crontab (`/etc/crontab`) | BSD `periodic(8)` Framework | One-Off Execution (`at(1)` / `batch(1)`) | Cloud-Native (`batch/v1 CronJob`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Execution Context** | Non-privileged or privileged user spool | System-wide root-managed file | Structured system maintenance framework | Deferred shell queue execution | Containerized pod engine |
| **Syntax Specification** | 5 time fields + `command` | 5 time fields + `user` + `command` | Controlled via `/etc/periodic.conf` settings | Absolute/relative time string (`now + 2 hours`) | Cron syntax + Kubernetes spec schema |
| **Concurrency Control** | Manual (`lockf` / wrapper script) | Manual (`lockf` / wrapper script) | Serial execution within periodic phases | Built-in via load average limits (`batch`) | Native (`Allow`, `Forbid`, `Replace`) |
| **Environment Handling** | Bare minimal (`PATH=/usr/bin:/bin`) | Explicitly declared top-level vars | Managed by `/etc/periodic.conf` shell context | Captures current caller's shell environment | Container image env & ConfigMaps |
| **Failure Notification** | Local MTA email to owner | Local MTA email to `MAILTO` | Aggregated report generated & emailed | Local MTA email to job creator | K8s events, status probes, alertmanager |
| **Access Control** | Restricted by `/var/cron/allow` or `/var/cron/deny` | Restricted to `root` | Restricted to `root` | Restricted by `/var/cron/at.allow` or `at.deny` | RBAC (`Role`/`RoleBinding`) |

---

### 2.2 Execution Control Trade-off Matrix

| Utility | Primary Use Case | Load-Aware Execution | Persistent Across Reboots | Signal / Process Management |
| :--- | :--- | :--- | :--- | :--- |
| **`cron(8)`** | Recurrent, deterministic tasks | No (Fires strictly on time schedule) | Yes (Parsed from crontab files on startup) | Spawns child shell (`/bin/sh -c`) per line |
| **`at(1)`** | One-time deferred maintenance | No (Fires strictly at scheduled target time) | Yes (Persisted in `/var/at/jobs/`) | Writes spool file, executed by `atrun` / `cron` |
| **`batch(1)`** | Background compilation, heavy IO | Yes (Fires only when load average drops < threshold) | Yes (Persisted in `/var/at/jobs/`) | Monitored by execution queue engine |

---

## 3. Complete Infrastructure & Configuration Manifests

### 3.1 Production FreeBSD System Crontab (`/etc/crontab`)

This file is syntactically valid for FreeBSD systems. Note the presence of the 6th field specifying the executing username.

```crontab
# /etc/crontab - System Crontab for FreeBSD
# Shell environment definitions for system-level executions
SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
MAILTO=sysadmin@example.com
HOME=/var/log

# Minute Hour MonthDay Month DayOfWeek User    Command
# ====================================================================================
# Run FreeBSD periodic maintenance suites
0       2       *       *       *       root    periodic daily
30      3       *       *       6       root    periodic weekly
30      5       1       *       *       root    periodic monthly

# ZFS Storage Maintenance: Scrub tank pool on the 1st and 15th of every month
0       1       1,15    *       *       root    /usr/sbin/lockf -s -t 0 /var/run/zfs_scrub.lock /sbin/zpool scrub tank

# Perform hourly log rotation check using newsyslog
0       *       *       *       *       root    /usr/sbin/newsyslog

# Sync system clock against upstream NTP drift every 6 hours if ntpd is inactive
15      */6     *       *       *       root    /usr/sbin/ntpdate -s pool.ntp.org

# Purge expired application cache files safely with concurrency protection
45      4       *       *       *       www     /usr/sbin/lockf -t 0 /var/run/app_cache_purge.lock /usr/local/bin/php /usr/local/www/app/cron.php --purge-cache
```

---

### 3.2 Production FreeBSD `/etc/periodic.conf` Override File

```sh
# /etc/periodic.conf - System periodic configuration overrides
# Maintainer: Platform Infrastructure Engineering

# ------------------------------------------------------------------------------
# Daily System Maintenance Settings
# ------------------------------------------------------------------------------
daily_clean_tmps_enable="YES"                       # Clean /tmp daily
daily_clean_tmps_days="3"                          # Remove files older than 3 days
daily_clean_preserve="system.journal"              # Retain specific system journal files
daily_status_disks_enable="YES"                    # Report disk storage capacity utilization
daily_status_zfs_enable="YES"                      # Detail ZFS pool health status
daily_status_network_enable="YES"                  # Log network interface packet statistics
daily_status_security_enable="YES"                 # Include daily security check output in daily mail

# ------------------------------------------------------------------------------
# Weekly System Maintenance Settings
# ------------------------------------------------------------------------------
weekly_locate_enable="YES"                         # Rebuild locate(1) database
weekly_catman_enable="NO"                          # Disable pre-formatted man pages generation
weekly_status_zfs_enable="YES"                     # Deep weekly ZFS status verification

# ------------------------------------------------------------------------------
# Security Framework Checks
# ------------------------------------------------------------------------------
security_status_chksetuid_enable="YES"             # Audit changes in setuid/setgid binary permissions
security_status_chkmounts_enable="YES"             # Verify changes in file system mount points
security_status_ipfwdenied_enable="YES"           # Report IPFW firewall drop metrics
security_status_loginfailures_enable="YES"         # Report failed authentication attempts from /var/log/auth.log

# Custom Log Output Redirection
daily_output="/var/log/periodic/daily.log"
weekly_output="/var/log/periodic/weekly.log"
monthly_output="/var/log/periodic/monthly.log"
```

---

### 3.3 Production Custom BSD Periodic Script (`/usr/local/etc/periodic/daily/999.backup-zfs`)

```sh
#!/bin/sh
#
# /usr/local/etc/periodic/daily/999.backup-zfs
# Production script for daily automated ZFS snapshot creation and retention
#

# If source file exists, load system periodic configuration defaults
if [ -r /etc/defaults/periodic.conf ]; then
    . /etc/defaults/periodic.conf
fi

# Define defaults for custom variables
daily_backup_zfs_enable="${daily_backup_zfs_enable:-NO}"
daily_backup_zfs_pools="${daily_backup_zfs_pools:-tank}"
daily_backup_zfs_keep_days="${daily_backup_zfs_keep_days:-7}"

# Evaluate activation flag
case "$daily_backup_zfs_enable" in
    [Yy][Ee][Ss])
        echo ""
        echo "Running Daily ZFS Snapshot Maintenance:"

        TODAY=$(date -u +%Y%m%d)
        
        for POOL in $daily_backup_zfs_pools; do
            SNAPSHOT_NAME="${POOL}@auto-daily-${TODAY}"
            echo "  --> Creating snapshot: ${SNAPSHOT_NAME}"
            /sbin/zfs snapshot -r "${SNAPSHOT_NAME}"
            if [ $? -eq 0 ]; then
                echo "      [SUCCESS] Snapshot created successfully."
            else
                echo "      [ERROR] Failed to create ZFS snapshot ${SNAPSHOT_NAME}." >&2
            fi
        done
        ;;
    *)
        ;;
esac

exit 0
```

---

### 3.4 Hybrid Cloud-Native Kubernetes `CronJob` Manifest (`cronjob-zfs-sync.yaml`)

When extending BSD state management patterns into hybrid enterprise platforms, equivalent cloud-native scheduling is codified using standard Kubernetes API manifests:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: zfs-offsite-backup-sync
  namespace: infrastructure
  labels:
    app.kubernetes.io/name: zfs-sync
    app.kubernetes.io/component: storage-backup
spec:
  schedule: "0 4 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 300
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 3600
      template:
        metadata:
          labels:
            app.kubernetes.io/name: zfs-sync
        spec:
          restartPolicy: OnFailure
          containers:
            - name: zfs-sync-agent
              image: registry.enterprise.internal/sysops/zfs-tools:v1.4.2
              imagePullPolicy: IfNotPresent
              command:
                - /usr/local/bin/zfs-replication.sh
              args:
                - --source-pool=tank/production
                - --remote-target=backup-node.internal.net
                - --retention-days=14
              env:
                - name: LOG_LEVEL
                  value: "INFO"
                - name: METRICS_GATEWAY
                  value: "http://prometheus-pushgateway.monitoring.svc:9091"
              resources:
                requests:
                  cpu: "250m"
                  memory: "256Mi"
                limits:
                  cpu: "1000m"
                  memory: "1Gi"
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                runAsNonRoot: true
                runAsUser: 10001
                capabilities:
                  drop:
                    - ALL
```

---

### 3.5 Infrastructure as Code: Ansible Playbook (`deploy_cron_policy.yml`)

```yaml
---
- name: Deploy BSD Job Automation & Cron Access Controls
  hosts: bsd_servers
  gather_facts: true
  become: true

  tasks:
    - name: Ensure /var/cron/allow contains authorized administrative users
      ansible.builtin.copy:
        dest: /var/cron/allow
        owner: root
        group: wheel
        mode: '0600'
        content: |
          root
          deploy
          sre_automation

    - name: Ensure /var/cron/deny is absent when allow-list policy is enforced
      ansible.builtin.file:
        path: /var/cron/deny
        state: absent

    - name: Configure periodic.conf overrides for ZFS and system checks
      ansible.builtin.blockinfile:
        path: /etc/periodic.conf
        create: true
        owner: root
        group: wheel
        mode: '0644'
        block: |
          daily_clean_tmps_enable="YES"
          daily_status_zfs_enable="YES"
          daily_backup_zfs_enable="YES"
          daily_backup_zfs_pools="tank"

    - name: Deploy custom daily ZFS snapshot periodic script
      ansible.builtin.copy:
        src: files/999.backup-zfs
        dest: /usr/local/etc/periodic/daily/999.backup-zfs
        owner: root
        group: wheel
        mode: '0755'
```

---

## 4. Real CLI Commands & Terminal Output ($)

### 4.1 Managing User Crontabs with `crontab(1)`

#### Inspecting and Modifying Active Crontab
To edit or list crontab files for the active user or target user (`-u`), standard flags are used:

```console
$ crontab -l
# Active User Crontab for user: sre_automation
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
MAILTO=sre-alerts@example.com

# Check application status every 15 minutes
*/15 * * * * /usr/local/bin/healthcheck.sh > /dev/null
```

```console
$ sudo crontab -u www -l
# Crontab for user: www
0 2 * * * /usr/local/bin/php /usr/local/www/app/artisan schedule:run >> /var/log/www/cron.log 2>&1
```

#### Enforcing User Access Control (`/var/cron/allow` vs `/var/cron/deny`)
When a non-authorized user attempts to invoke `crontab(1)` while `/var/cron/allow` is present:

```console
$ whoami
developer

$ crontab -e
crontab: you (developer) are not allowed to use this program.
```

Checking access control files on FreeBSD:

```console
$ ls -la /var/cron/allow /var/cron/deny
ls: /var/cron/deny: No such file or directory
-rw-------  1 root  wheel  28 Aug 6 20:30 /var/cron/allow

$ sudo cat /var/cron/allow
root
sre_automation
deploy
```

---

### 4.2 Managing One-Off Execution Jobs with `at(1)`, `atq(1)`, `atrm(1)`, and `batch(1)`

#### Submitting Deferred Jobs with `at(1)`
Scheduling a task to execute at a specific future timestamp:

```console
$ at 03:00 tomorrow
at> /sbin/zpool scrub tank
at> /usr/local/bin/notify_slack.sh "Scheduled midnight scrub initiated"
at> <EOT>
Job 14 will be executed using /bin/sh at Fri Aug  7 03:00:00 2026
```

Submitting a job using relative time notation:

```console
$ echo "/usr/local/sbin/pkg upgrade -y" | at now + 2 hours
Job 15 will be executed using /bin/sh at Thu Aug  6 22:37:43 2026
```

#### Submitting Load-Dependent Tasks with `batch(1)`
`batch(1)` schedules a job that executes when the system load average falls below the system threshold (typically `1.5` on BSD systems):

```console
$ batch
at> /usr/home/sre_automation/build_kernel.sh
at> <EOT>
Job 16 will be executed using /bin/sh
```

#### Inspecting and Removing Jobs (`atq` & `atrm`)
Viewing the pending job execution queue:

```console
$ atq
Date                    Owner           Queue   Job#
Fri Aug  7 03:00:00 2026 root            c       14
Thu Aug  6 22:37:43 2026 sre_automation  c       15
Thu Aug  6 20:45:00 2026 sre_automation  b       16
```

Removing a queued job prior to execution:

```console
$ atrm 15
15: removed

$ atq
Date                    Owner           Queue   Job#
Fri Aug  7 03:00:00 2026 root            c       14
Thu Aug  6 20:45:00 2026 sre_automation  b       16
```

---

### 4.3 Manual Execution of System Maintenance via `periodic(8)`

To run system periodic scripts manually for testing or on-demand execution:

```console
$ sudo periodic daily
Running Daily System Maintenance:
  --> Cleaning /tmp directory...
  --> Rotating log files via newsyslog...
  --> Checking ZFS storage pool health:
  all pools are healthy
  --> Running Security Checks:
  No setuid changes detected.
  --> Completed daily maintenance phase.
```

To execute a specific target script inside the periodic directory structure:

```console
$ sudo /usr/local/etc/periodic/daily/999.backup-zfs

Running Daily ZFS Snapshot Maintenance:
  --> Creating snapshot: tank@auto-daily-20260806
      [SUCCESS] Snapshot created successfully.
```

---

## 5. Verification & Troubleshooting / Diagnostic Guide

### 5.1 Diagnostic Decision Tree for Job Failures

```
                    +---------------------------------------+
                    | Scheduled Task Failed / Did Not Run   |
                    +-------------------+-------------------+
                                        |
                 +----------------------+----------------------+
                 |                                             |
     +-----------v-----------+                     +-----------v-----------+
     | Check System Cron Log |                     |  Check Access Rules   |
     |  grep cron /var/log/  |                     |  /var/cron/allow|deny |
     +-----------+-----------+                     +-----------+-----------+
                 |                                             |
        +--------+--------+                           +--------+--------+
        |                 |                           |                 |
 +------v------+   +------v------+             +------v------+   +------v------+
 | Job Executed|   | Job Never   |             | Permission  |   | Environment |
 | But Errored |   | Invoked     |             | Denied      |   | Variable    |
 | (Exit != 0) |   | (No Log)    |             | Error       |   | Mismatch    |
 +------+------+   +------+------+             +------+------+   +------+------+
        |                 |                           |                 |
        |                 |                           |                 |
  Check Mail /     Check Timezone /            Verify User in    Set PATH & SHELL
 Redirect stderr   Check Syntax                /var/cron/allow   In Crontab Header
```

---

### 5.2 Common Failure Modes & Resolution Protocols

#### Issue 1: Command Executed Manually Works, But Fails under Cron
- **Root Cause:** Environment variable disparity. Interactive logins source `/etc/profile`, `~/.profile`, or `~/.zshrc`, adding custom directories to `$PATH` (e.g., `/usr/local/bin`, `/opt/bin`). BSD `cron` sets a default `$PATH` of `/usr/bin:/bin`.
- **Diagnostic Procedure:**

```console
$ grep -i "PATH" /etc/crontab
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
```

- **Fix:** Explicitly define the mandatory environment variables at the top of the target `crontab` file or script:

```crontab
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
SHELL=/bin/sh
```

---

#### Issue 2: Overlapping Executions Causing Lock Contention
- **Root Cause:** A backup script executed every hour takes 75 minutes to finish, resulting in concurrent execution.
- **Diagnostic Procedure:** Check active process tree for duplicate running instances:

```console
$ pgrep -fl "backup"
10423 /bin/sh /usr/local/bin/backup.sh
14589 /bin/sh /usr/local/bin/backup.sh
```

- **Fix:** Wrap the command in `lockf(1)` to ensure strict non-blocking execution locking:

```crontab
0 * * * * root /usr/sbin/lockf -s -t 0 /var/run/backup_job.lock /usr/local/bin/backup.sh
```
*Note:* The `-t 0` flag specifies a zero-second timeout, instructing `lockf` to exit immediately with status 0 if the lock cannot be acquired, preventing duplicate process stacking.

---

#### Issue 3: Stale Atjobs or `atd` Queue Delays
- **Root Cause:** The `atrun(8)` daemon process, which processes `/var/at/jobs/`, is disabled or not scheduled in `/etc/crontab`.
- **Diagnostic Procedure:** In BSD systems, `atrun` is invoked by system cron every 5 minutes:

```console
$ grep "atrun" /etc/crontab
*/5     *       *       *       *       root    /usr/libexec/atrun
```

If `atrun` is missing from `/etc/crontab`, jobs submitted via `at(1)` remain in queue indefinitely without processing.

---

### 5.3 Diagnostic Commands & System Log Inspection

#### Inspecting Cron Daemon Logs
On FreeBSD, cron actions are logged via `syslogd(8)` to `/var/log/cron`:

```console
$ sudo tail -n 20 /var/log/cron
Aug  6 20:00:00 bsd-host cron[84201]: (root) CMD (periodic daily)
Aug  6 20:15:00 bsd-host cron[84512]: (root) CMD (/usr/sbin/ntpdate -s pool.ntp.org)
Aug  6 20:30:00 bsd-host cron[85100]: (sre_automation) CMD (/usr/local/bin/healthcheck.sh > /dev/null)
Aug  6 20:30:00 bsd-host cron[85101]: (CRON) ERROR (cannot set uid to 1005): Operation not permitted
```

#### Tracing Execution with `ktrace(1)` / `kdump(1)`
To trace system calls executed by `cron(8)` or a failing periodic script:

```console
$ sudo ktrace -i -p $(pgrep cron)
# Let cron fire the job, then attach and decode
$ sudo kdump -f ktrace.out | grep -E "(NAMI|RET)" | head -n 15
 84201 cron     NAMI  "/etc/crontab"
 84201 cron     RET   open 3
 84201 cron     NAMI  "/var/cron/tabs/root"
 84201 cron     RET   open 4
 84201 cron     NAMI  "/usr/local/bin/healthcheck.sh"
 84201 cron     RET   execve 0
```

---

## 6. References

* **LPI BSD Specialist Certification Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **FreeBSD System Manager's Manual – `cron(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8)

* **FreeBSD File Formats Manual – `crontab(5)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=crontab&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=crontab&sektion=5)

* **FreeBSD System Manager's Manual – `periodic(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8)

* **FreeBSD General Commands Manual – `at(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1)

* **OpenBSD File Formats Manual – `crontab(5)`:**  
  [https://man.openbsd.org/crontab.5](https://man.openbsd.org/crontab.5)