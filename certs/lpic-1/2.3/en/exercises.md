# Exercises: Administrative Tasks (Topic 2.3)

## Exercise 1: Managing System Locales and Timezones

Timezone mismatches across a cluster will corrupt your distributed tracing and logging. Setting the correct locale ensures character encoding consistency.

1. Check your system's current timezone and locale status:
   ```bash
   timedatectl status
   localectl status
   ```
2. Change the system timezone to UTC:
   ```bash
   sudo timedatectl set-timezone UTC
   ```
3. List all available locales on your system, then set the default locale to `C.UTF-8` (a common minimal locale for containers):
   ```bash
   localectl list-locales
   sudo localectl set-locale LANG=C.UTF-8
   ```

**Question 1.1:** What is the difference between `Universal time` and `Local time` in the output of `timedatectl status`?
**Question 1.2:** Which system configuration file does `localectl set-locale` ultimately modify in modern systemd-based distributions?

---

## Exercise 2: User Account and Group Management

You need to create a dedicated service account for a Prometheus node exporter daemon. The account must not have interactive shell access.

1. Create a group for the service:
   ```bash
   sudo groupadd -r prometheus
   ```
2. Create the system user, assigning it to the newly created group, ensuring no home directory is created, and setting the shell to `/usr/sbin/nologin`:
   ```bash
   sudo useradd -r -g prometheus -s /usr/sbin/nologin -M node_exporter
   ```
3. Verify the user was created correctly by inspecting `/etc/passwd`:
   ```bash
   grep node_exporter /etc/passwd
   ```

**Question 2.1:** What does the `-r` flag do in both `groupadd` and `useradd` commands?
**Question 2.2:** Why is it a security best practice to set the shell to `/usr/sbin/nologin` or `/bin/false` for service accounts?

---

## Exercise 3: Scheduling Tasks with `cron` and `systemd`

You will first schedule a task using traditional `cron`, and then analyze a modern `systemd` timer.

1. Create a cron job for your current user that runs a script every 5 minutes:
   ```bash
   crontab -e
   ```
   Add the following line:
   ```text
   */5 * * * * /usr/bin/echo "Health check" >> /tmp/health.log
   ```
2. Verify your cron job was installed:
   ```bash
   crontab -l
   ```
3. List all active systemd timers on your system to see what background tasks are managed by systemd:
   ```bash
   systemctl list-timers
   ```

**Question 3.1:** In the cron expression `*/5 * * * *`, what do the five fields represent?
**Question 3.2:** If a server is turned off at the time a `cron` job is scheduled to run, what happens to the job when the server is powered back on? How does a systemd timer with `Persistent=true` handle this differently?

---

<details>
<summary><strong>Answers</strong></summary>

**Answer 1.1:** `Universal time` refers to UTC (Coordinated Universal Time), which is standard globally. `Local time` is the time adjusted for the configured system timezone (which you set using `timedatectl set-timezone`). If your timezone is UTC, they will be identical.

**Answer 1.2:** `localectl set-locale` typically modifies `/etc/locale.conf` on modern systemd-based distributions (like RHEL, Fedora, Arch, and newer Debian/Ubuntu).

**Answer 2.1:** The `-r` flag creates a "system" account or group. System accounts typically have UIDs/GIDs below 1000 (depending on the distribution's `/etc/login.defs`), and their passwords do not expire. They are meant for daemons and services, not human users.

**Answer 2.2:** Setting the shell to `/usr/sbin/nologin` prevents anyone (or any exploited service) from acquiring an interactive shell session using that account. It is a fundamental defense-in-depth practice.

**Answer 3.1:** The fields represent: Minute (0-59), Hour (0-23), Day of the month (1-31), Month (1-12), and Day of the week (0-7, where 0 and 7 are Sunday). `*/5` in the first field means "every 5 minutes".

**Answer 3.2:** A standard `cron` job will simply be missed; `cron` does not retroactively execute missed jobs (though `anacron` is sometimes used to solve this for daily/weekly scripts). A systemd timer with `Persistent=true` saves a timestamp when it runs. If the system was off during a scheduled execution, the timer will immediately trigger the job once the system boots.
</details>