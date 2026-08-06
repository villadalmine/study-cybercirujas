# Topic 2.3: Administrative Tasks (LPIC-1)

## 1. Motivation and Production Architectural Problem

Managing administrative tasks at scale poses critical security, reliability, and auditability challenges in production. As a Platform Architect, relying on manual user account creation or ad-hoc scheduled scripts leads to configuration drift, orphaned credentials, and silent failures when background jobs stop running. 

The architectural problem is moving from manual operational toil to declarative, automated, and observable state management. Whether you are provisioning local service accounts for a database, scheduling a recurring backup task across thousands of nodes, or configuring locales for a fleet of application servers in different global regions, you must ensure tasks are idempotent, logged, and integrated into modern supervision trees like systemd.

## 2. Technical Comparisons and Trade-offs

### Scheduled Tasks: `cron` vs. `systemd` Timers

| Feature | `cron` | `systemd` Timers |
| :--- | :--- | :--- |
| **Execution Model** | Independent daemon (`crond`) spawning sub-shells. | Native systemd unit integration. |
| **Granularity** | Down to 1 minute. | Down to microsecond precision. |
| **Dependency Management**| None. Scripts must handle their own locking and preconditions. | Full systemd dependency tree (`Requires`, `After`, `Wants`). |
| **Logging** | Sent via local MTA (mail) or basic syslog. | Fully integrated into systemd journal (`journalctl`). |
| **Resource Control** | Difficult (requires wrapper scripts like `cgexec`). | Native cgroups integration (CPU, Memory, IO limits). |

### User Management: Local vs. Centralized

| Scope | Implementation | Use Case |
| :--- | :--- | :--- |
| **Local Accounts** | `/etc/passwd`, `/etc/shadow`, `useradd` | System daemons, break-glass root accounts, single-node labs. |
| **Centralized (SSO)** | LDAP, FreeIPA, Active Directory, SSSD | Enterprise environments, massive fleets, zero-trust architectures. |

## 3. Infrastructure as Code: User and Job Automation

In production, you do not run `useradd` manually. You define state using tools like Ansible or Terraform.

### Ansible Playbook: `admin-tasks.yaml`

This playbook creates a service account for a web server, sets the system locale, and deploys a `systemd` timer (replacing traditional `cron`) to run a backup task.

```yaml
---
- name: Production Administrative Tasks
  hosts: app_servers
  become: yes
  tasks:
    - name: Ensure localized environment
      locale_gen:
        name: en_US.UTF-8
        state: present
    
    - name: Set default system locale
      command: localectl set-locale LANG=en_US.UTF-8

    - name: Create service group
      group:
        name: backup_svc
        state: present

    - name: Create service user without shell access
      user:
        name: backup_svc
        group: backup_svc
        shell: /usr/sbin/nologin
        system: yes
        create_home: no

    - name: Deploy Backup Service Unit
      copy:
        dest: /etc/systemd/system/db-backup.service
        content: |
          [Unit]
          Description=Database Backup Task
          
          [Service]
          Type=oneshot
          User=backup_svc
          ExecStart=/usr/local/bin/run-backup.sh
        mode: '0644'

    - name: Deploy Backup Timer
      copy:
        dest: /etc/systemd/system/db-backup.timer
        content: |
          [Unit]
          Description=Run DB Backup nightly
          
          [Timer]
          OnCalendar=*-*-* 02:00:00
          Persistent=true
          
          [Install]
          WantedBy=timers.target
        mode: '0644'
      notify: Reload systemd and enable timer

  handlers:
    - name: Reload systemd and enable timer
      systemd:
        daemon_reload: yes
        name: db-backup.timer
        enabled: yes
        state: started
```

## 4. CLI Commands and Terminal Outputs

### 4.1 Local User and Group Management

Creating a standard user, adding them to the `wheel` (sudo) group, and inspecting the shadow file.

```bash
$ sudo useradd -m -s /bin/bash -c "SRE Admin" jdoe
$ sudo usermod -aG wheel jdoe
$ sudo passwd jdoe
New password: 
Retype new password: 
passwd: password updated successfully
```

Inspecting the configuration files:

```bash
$ grep jdoe /etc/passwd
jdoe:x:1001:1001:SRE Admin:/home/jdoe:/bin/bash

$ sudo grep jdoe /etc/shadow
jdoe:$y$j9T$R.a/xyz...:19500:0:99999:7:::
```
*(Note: The `$y$` prefix indicates `yescrypt`, a modern password hashing algorithm).*

### 4.2 Locales and Timezones

Managing timezones and locales is essential for timestamp consistency in distributed logging.

```bash
$ localectl status
   System Locale: LANG=en_US.UTF-8
       VC Keymap: us
      X11 Layout: us

$ timedatectl set-timezone UTC
$ timedatectl status
               Local time: Wed 2026-08-05 14:00:00 UTC
           Universal time: Wed 2026-08-05 14:00:00 UTC
                 RTC time: Wed 2026-08-05 14:00:00
                Time zone: UTC (UTC, +0000)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

### 4.3 Scheduling with `cron` and `at`

Creating a one-off delayed job using `at`:

```bash
$ echo "/opt/scripts/cleanup.sh" | at now + 2 hours
warning: commands will be executed using /bin/sh
job 3 at Wed Aug  5 16:00:00 2026

$ atq
3       Wed Aug  5 16:00:00 2026 a root
```

Inspecting a user's crontab:

```bash
$ crontab -l -u backup_svc
# m h  dom mon dow   command
0 2 * * * /usr/local/bin/run-backup.sh >> /var/log/backup.log 2>&1
```

## 5. Troubleshooting and Fault Diagnosis

### Scenario A: Cron Jobs Failing Silently
**Symptoms:** A scheduled database backup via `cron` is not executing, and no logs are generated in `/var/log/backup.log`.
**Diagnosis:**
1. Check if the `cron` daemon is running:
   ```bash
   $ systemctl status cron
   ```
2. Check the system logs for cron execution:
   ```bash
   $ grep CRON /var/log/syslog | grep backup.sh
   ```
3. A common issue is a restricted environment. `cron` does not inherit the user's interactive `PATH`. 
**Resolution:** Explicitly define the `PATH` at the top of the crontab, or use absolute paths for all commands inside the backup script.

### Scenario B: Locked User Accounts
**Symptoms:** An engineer cannot log into the bastion host via SSH, receiving "Permission denied".
**Diagnosis:**
1. Check if the account is locked in `/etc/shadow` (an `!` in the password hash field indicates a locked account).
   ```bash
   $ sudo grep jdoe /etc/shadow
   jdoe:!$y$j9T$R.a/xyz...:19500:0:99999:7:::
   ```
2. Check password expiration status:
   ```bash
   $ sudo chage -l jdoe
   Password expires                                : password must be changed
   Account expires                                 : never
   ```
**Resolution:** Unlock the account using `usermod` or `passwd`.
   ```bash
   $ sudo usermod -U jdoe
   # or force a password change
   $ sudo chage -d 0 jdoe
   ```

### Scenario C: Character Encoding Issues (Locales)
**Symptoms:** Logs generated by an application contain `?` or garbled characters for UTF-8 sequences.
**Diagnosis:**
The application environment might have fallen back to the `C` or `POSIX` locale instead of `en_US.UTF-8`.
```bash
$ locale
LANG=C
LANGUAGE=
LC_CTYPE="C"
```
**Resolution:** Generate the correct locale and set it globally via `localectl`, or pass the specific `LANG=en_US.UTF-8` environment variable in the application's systemd unit (`Environment=LANG=en_US.UTF-8`).

## 6. References

- Systemd Timers: https://www.freedesktop.org/software/systemd/man/systemd.timer.html
- Localectl Documentation: https://www.freedesktop.org/software/systemd/man/localectl.html
- Timedatectl Documentation: https://www.freedesktop.org/software/systemd/man/timedatectl.html
- Shadow Password Suite: https://github.com/shadow-maint/shadow
- LPIC-1 Exam Objectives: https://www.lpi.org/our-certifications/exam-101-objectives/