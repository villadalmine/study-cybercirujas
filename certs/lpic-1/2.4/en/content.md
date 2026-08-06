# Topic 2.4: Essential System Services (LPIC-1)

## 1. Motivation and Production Architectural Problem

Essential system services form the backbone of observability and synchronization in a distributed architecture. If system time drifts across a cluster, TLS certificates fail validation, distributed databases (like Cassandra or Spanner) corrupt their transaction ordering, and log correlation becomes impossible. If logging systems fail to rotate or forward logs, disks fill up causing cascading outages.

The architectural problem is moving from standalone, isolated daemons to robust, aggregated, and synchronized fleets. As a Platform Architect, you must guarantee that time synchronization (`chronyd` or `systemd-timesyncd`) operates within millisecond precision, that logs are structured and shipped reliably (via `systemd-journald` to a central aggregator), and that local MTA (Mail Transfer Agent) stubs can reliably queue and relay alerts without running a full, vulnerable mail server footprint on every node.

## 2. Technical Comparisons and Trade-offs

### Time Synchronization: `chrony` vs. `systemd-timesyncd` vs. `ntpd`

| Service | Architecture & Use Case | Trade-offs |
| :--- | :--- | :--- |
| **systemd-timesyncd** | Minimal SNTP client native to systemd. Good for standard VMs. | Only synchronizes time (cannot act as a server). Lacks advanced hardware timestamping. |
| **chrony** | Modern NTP implementation designed for unstable network connections and VMs. | Fast convergence. Best choice for most modern infrastructure. |
| **ntpd (legacy)** | The classic reference implementation. Good for stable, always-on stratum 1/2 servers. | Slow convergence (can take hours to correct large drifts). Less resilient to network disconnects. |

### Logging: `syslog` (rsyslog) vs. `systemd-journald`

| Feature | `rsyslog` | `systemd-journald` |
| :--- | :--- | :--- |
| **Format** | Plain text (typically `/var/log/syslog`). | Binary, structured, indexed (`/var/log/journal/`). |
| **Metadata** | Minimal (timestamp, host, process). | Rich metadata (cgroup, UID, systemd unit, SELinux context). |
| **Querying** | `grep`, `awk`, `sed`. | `journalctl` (allows querying by unit, time range, severity). |

## 3. Infrastructure as Code: Core Services Configuration

In production, core services like `chrony` and `journald` must be configured deterministically to prevent drift and ensure predictable disk usage.

### Ansible Playbook: `essential-services.yaml`

```yaml
---
- name: Configure Essential System Services
  hosts: all
  become: yes
  tasks:
    - name: Ensure chrony is installed
      apt:
        name: chrony
        state: present

    - name: Configure chrony for production
      copy:
        dest: /etc/chrony/chrony.conf
        content: |
          # Use geographically local pool
          pool 2.debian.pool.ntp.org iburst
          # Step the system clock if the adjustment is larger than 1 second, 
          # but only in the first 3 clock updates.
          makestep 1 3
          # Record the rate of drift
          driftfile /var/lib/chrony/chrony.drift
          # Log chrony tracking
          logdir /var/log/chrony
          # Limit access to local loopback
          bindcmdaddress 127.0.0.1
        mode: '0644'
      notify: Restart chrony

    - name: Configure systemd-journald retention policies
      copy:
        dest: /etc/systemd/journald.conf.d/99-retention.conf
        content: |
          [Journal]
          Storage=persistent
          SystemMaxUse=2G
          SystemKeepFree=5G
          MaxRetentionSec=30day
        mode: '0644'
      notify: Restart journald

  handlers:
    - name: Restart chrony
      systemd:
        name: chrony
        state: restarted

    - name: Restart journald
      systemd:
        name: systemd-journald
        state: restarted
```

## 4. CLI Commands and Terminal Outputs

### 4.1 Time Synchronization (`chronyc` and `timedatectl`)

Verify the NTP synchronization status using `timedatectl`:

```bash
$ timedatectl status
               Local time: Wed 2026-08-05 15:30:00 UTC
           Universal time: Wed 2026-08-05 15:30:00 UTC
                 RTC time: Wed 2026-08-05 15:30:00
                Time zone: UTC (UTC, +0000)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

Query the chrony tracking metrics to evaluate drift and Stratum:

```bash
$ chronyc tracking
Reference ID    : CB00710F (ntp-server.example.com)
Stratum         : 3
Ref time (UTC)  : Wed Aug 05 15:29:10 2026
System time     : 0.000001234 seconds fast of NTP time
Last offset     : +0.000015000 seconds
RMS offset      : 0.000020000 seconds
Frequency       : 5.123 ppm slow
Residual freq   : +0.001 ppm
Skew            : 0.050 ppm
Root delay      : 0.015123456 seconds
Root dispersion : 0.002000000 seconds
```

List the NTP sources chrony is polling:

```bash
$ chronyc sources -v
  .-- Source mode  '^' = server, '=' = peer, '#' = local clock.
 / .- Source state '*' = current best, '+' = combined, '-' = not combined.
| / .- Reachability register (octal) -.
| | |                                 |
MS Name/IP address         Stratum Poll Reach LastRx Last sample               
===============================================================================
^* ntp-server.example.com        2   6   377    10   +15us[  +15us] +/-   17ms
```

### 4.2 Querying Logs (`journalctl`)

Query logs for a specific service since the last boot, displaying them in follow mode:

```bash
$ journalctl -u kubelet.service -b -f
```

Filter logs by severity (error and above) for the last 2 hours:

```bash
$ journalctl -p err..emerg --since "2 hours ago"
Aug 05 13:45:10 node-1 systemd[1]: Failed to start nginx.service.
```

Find out how much disk space the journal is currently using:

```bash
$ journalctl --disk-usage
Archived and active journals take up 800.0M in the file system.
```

### 4.3 Mail Transfer Agent (MTA) Queue Management

In environments where applications rely on a local MTA to relay emails, checking the queue is a standard debugging step.

List the mail queue (using Postfix):
```bash
$ mailq
-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
A1B2C3D4E5      1024 Wed Aug  5 14:00:00  alert@node-1.example.com
(Connection timed out)
                                         admin@example.com
-- 1 Kbytes in 1 Request.
```

Force a flush of the mail queue:
```bash
$ sudo postqueue -f
```

## 5. Troubleshooting and Fault Diagnosis

### Scenario A: TLS Handshakes Failing Due to Clock Drift
**Symptoms:** Applications report `x509: certificate has expired or is not yet valid`, but inspecting the certificate shows it is valid.
**Diagnosis:**
1. Check the system clock status and synchronization:
   ```bash
   $ timedatectl status | grep "System clock synchronized"
   System clock synchronized: no
   ```
2. Check `chronyc tracking` and look for `System time` being wildly off, or `chronyc sources` showing no reachable servers (Reach `0`).
**Resolution:** Ensure UDP port 123 is open outbound. If the clock is skewed by years, chrony might refuse to step it automatically. Force a manual step:
   ```bash
   $ sudo chronyc makestep
   200 OK
   ```

### Scenario B: Journald Consuming Entire Root Partition
**Symptoms:** Root filesystem is at 100%, and `du -sh /var/log/journal` shows it consuming gigabytes.
**Diagnosis:**
The default `systemd-journald` configuration usually caps at 10% of the filesystem size, but on small VMs (e.g., 10GB root), 1GB of logs might trigger `No space left on device` for other critical services.
**Resolution:**
Manually vacuum the journal to free up space immediately:
```bash
$ sudo journalctl --vacuum-size=500M
Vacuuming done, freed 1.5G of archived journals from /var/log/journal.
```
Apply a permanent limit in `/etc/systemd/journald.conf.d/retention.conf` (as shown in the Ansible snippet) and restart `systemd-journald`.

## 6. References

- chrony Documentation: https://chrony.tuxfamily.org/documentation.html
- systemd-journald Documentation: https://www.freedesktop.org/software/systemd/man/systemd-journald.service.html
- Postfix Basic Configuration: http://www.postfix.org/BASIC_CONFIGURATION_README.html
- LPIC-1 Exam Objectives: https://www.lpi.org/our-certifications/exam-101-objectives/