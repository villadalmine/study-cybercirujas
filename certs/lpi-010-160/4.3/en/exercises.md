# Guided Exercises — Topic 4.3: Where Data is Stored

**Certification:** LPI Linux Essentials (010-160, version 1.6) — Exam weight: 3
**Reference:** [LPI Learning Materials, Lesson 4.3](https://learning.lpi.org/en/learning-materials/010-160/4/4.3/)

Work through each block on a Linux machine (a VM or container is fine). Run every command yourself and read the output before answering the questions. You need a regular user account; a few steps use `sudo`.

---

## Exercise 1 — Programs and Their Configuration

Linux keeps programs, their configuration, and their data in separate, predictable places defined by the Filesystem Hierarchy Standard (FHS).

**Steps:**

1. Find out where the `bash` and `ip` programs live:

   ```bash
   which bash
   which ip
   ```

2. List the essential system-wide configuration directory and look for a few well-known files:

   ```bash
   ls /etc | head -20
   ls -l /etc/hostname /etc/hosts /etc/passwd
   ```

3. Display the contents of two of those files:

   ```bash
   cat /etc/hostname
   cat /etc/hosts
   ```

4. Look at per-user configuration ("dotfiles") in your home directory:

   ```bash
   ls -a ~ | head -20
   ```

5. Confirm that `/etc/passwd`, despite its name, stores account information rather than passwords, and check where the actual password hashes are:

   ```bash
   grep $USER /etc/passwd
   sudo head -3 /etc/shadow
   ls -l /etc/shadow
   ```

**Questions:**

**1.1** Based on step 2 and 3, what kind of data is stored in `/etc`, and does it apply to a single user or to the whole system?

**1.2** In step 4 you saw files like `.bashrc` or `.profile`. Why do their names start with a dot, and whose configuration do they store?

**1.3** In step 5, what information does each line of `/etc/passwd` hold, and why are the password hashes kept in `/etc/shadow` instead? (Hint: compare the permissions shown by `ls -l` for both files.)

---

## Exercise 2 — Binaries and Shared Libraries

**Steps:**

1. Compare the traditional directories for binaries:

   ```bash
   ls /bin | head
   ls /usr/bin | head
   ls /sbin | head
   ```

   On many modern distributions, check whether these are symbolic links:

   ```bash
   ls -ld /bin /sbin /lib
   ```

2. Pick a common program and list the shared libraries it depends on:

   ```bash
   ldd /usr/bin/ls
   ```

3. Look inside a library directory:

   ```bash
   ls /lib/x86_64-linux-gnu 2>/dev/null | head || ls /usr/lib64 | head
   ```

4. Find the C standard library entry in the `ldd` output from step 2 (a line mentioning `libc.so.6`).

**Questions:**

**2.1** What is the difference in purpose between `/bin` (or `/usr/bin`) and `/sbin` (or `/usr/sbin`)?

**2.2** What is a shared library, and what advantage does it give compared to every program carrying its own copy of the same code?

**2.3** In step 1 you may have seen `/bin -> usr/bin`. What does this symlink tell you about how modern distributions organize the hierarchy?

---

## Exercise 3 — Processes and the /proc Filesystem

**Steps:**

1. List the processes running in your current session, then list every process on the system:

   ```bash
   ps
   ps aux | head -15
   ```

2. Note the PID of your own shell:

   ```bash
   echo $$
   ```

3. Explore the directory that the kernel exposes for that process (replace `<PID>` with the number from step 2):

   ```bash
   ls /proc/<PID>
   cat /proc/<PID>/cmdline; echo
   ```

4. Check how much disk space `/proc` occupies:

   ```bash
   du -sh /proc 2>/dev/null
   ```

5. Read two system-wide files in `/proc`:

   ```bash
   cat /proc/cpuinfo | head -10
   head -5 /proc/meminfo
   ```

6. Watch processes dynamically for a few seconds, then quit with `q`:

   ```bash
   top
   ```

**Questions:**

**3.1** What is a PID, and which process traditionally has PID 1?

**3.2** In step 4, `du` reports that `/proc` uses (almost) no space. Why? Where does its content actually come from?

**3.3** What is the main difference between `ps aux` and `top` as tools for inspecting processes?

**3.4** What kind of information did you find in `/proc/cpuinfo` and `/proc/meminfo`?

---

## Exercise 4 — Memory: RAM and Swap

**Steps:**

1. Display memory usage in human-readable form:

   ```bash
   free -h
   ```

   Identify the columns `total`, `used`, `free`, `buff/cache`, and `available`, and the two rows `Mem:` and `Swap:`.

2. Compare with the kernel's own view:

   ```bash
   head -3 /proc/meminfo
   ```

3. See which devices or files provide swap space:

   ```bash
   cat /proc/swaps
   ```

4. Confirm the relationship: `free` is essentially a formatted reader of `/proc/meminfo`.

**Questions:**

**4.1** What is swap space used for, and what happens to system performance when the system relies on it heavily?

**4.2** Your system may show a small `free` value but a large `available` value. Why is `available` the better indicator of memory you can still use? (Hint: think about `buff/cache`.)

**4.3** Can swap live somewhere other than a dedicated disk partition?

---

## Exercise 5 — System Logs

**Steps:**

1. List the traditional log directory:

   ```bash
   ls -l /var/log
   ```

   Depending on your distribution you may see files such as `syslog` or `messages`, `auth.log` or `secure`, and directories for individual services.

2. Read the last lines of the main system log (pick whichever file exists):

   ```bash
   sudo tail /var/log/syslog 2>/dev/null || sudo tail /var/log/messages
   ```

3. Now query the systemd journal, which is how most modern distributions store logs:

   ```bash
   sudo journalctl -n 10
   sudo journalctl -b | head -10
   ```

4. Follow the log in real time (open a second terminal, run any command like `sudo ls`, and watch the entry appear; stop with `Ctrl+C`):

   ```bash
   sudo journalctl -f
   ```

5. Check where the journal files are physically stored:

   ```bash
   ls /var/log/journal 2>/dev/null || ls /run/log/journal
   ```

**Questions:**

**5.1** Under which top-level directory does Linux traditionally store log files, and why does that directory make sense for this kind of data given its FHS purpose?

**5.2** What is the key difference in *format* between traditional syslog files and the systemd journal, and what consequence does that have for how you read them?

**5.3** In step 5, what does it mean if the journal is only under `/run/log/journal` and not under `/var/log/journal`?

---

## Exercise 6 — Kernel Messages

**Steps:**

1. Display the kernel ring buffer (use `sudo` if you get a permission error):

   ```bash
   sudo dmesg | head -15
   ```

2. Show the same messages with human-readable timestamps:

   ```bash
   sudo dmesg -T | tail -10
   ```

3. Query only kernel messages through the journal and compare:

   ```bash
   sudo journalctl -k | tail -10
   ```

4. If you have a USB stick available, plug it in and immediately run:

   ```bash
   sudo dmesg | tail -15
   ```

   Look for lines describing the new device.

**Questions:**

**6.1** What is the kernel ring buffer, and what does "ring" imply about old messages?

**6.2** Name two situations where reading `dmesg` output is the natural first troubleshooting step.

**6.3** Kernel boot messages exist from the very first moments of startup, before any log service is running. Where do they live at that point?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1.1** `/etc` stores system-wide configuration files, mostly plain text. Settings there apply to the whole system and every user, unlike per-user configuration kept in each home directory.

**1.2** Filenames beginning with a dot are hidden files, not shown by a plain `ls`. Dotfiles such as `~/.bashrc` store the personal configuration of one specific user; each user has their own copies in their own home directory, and changes there affect only that user.

**1.3** Each `/etc/passwd` line holds one account: username, a password placeholder (`x`), UID, GID, a comment/GECOS field, home directory, and default shell. The actual password hashes were moved to `/etc/shadow` because `/etc/passwd` must remain world-readable for the system to map UIDs to names, while `/etc/shadow` is readable only by root (permissions like `-rw-r-----` or stricter), keeping the hashes away from ordinary users.

### Exercise 2

**2.1** `/bin` and `/usr/bin` hold programs intended for all users (`ls`, `cp`, `bash`). `/sbin` and `/usr/sbin` hold system administration programs (`fdisk`, `mkfs`, `ip` on some systems) meant mainly for root, although regular users can often run them read-only.

**2.2** A shared library is a file (named `lib<name>.so.<version>`) containing code that many programs load and use at runtime. The advantages: the code exists once on disk and in memory instead of being duplicated in every binary, and fixing a bug in the library fixes it for every program that uses it, without recompiling them.

**2.3** It shows the "usrmerge" layout: `/bin`, `/sbin`, and `/lib` are now symbolic links into `/usr`, so all binaries and libraries physically live under `/usr` while the traditional paths keep working for compatibility.

### Exercise 3

**3.1** A PID (Process ID) is the unique number the kernel assigns to each running process. PID 1 belongs to the first process started by the kernel — the init system, which on most modern distributions is `systemd`.

**3.2** `/proc` is a virtual (pseudo) filesystem: its files occupy no disk space because they don't exist on disk at all. The kernel generates their content on the fly, at the moment you read them, directly from its in-memory data structures.

**3.3** `ps aux` prints a one-time snapshot of all processes and exits; `top` is interactive and refreshes continuously, showing live CPU and memory usage, which makes it suited for watching system behavior over time.

**3.4** `/proc/cpuinfo` describes the processor(s): model name, number of cores, flags/features, cache sizes. `/proc/meminfo` reports memory statistics: total and free RAM, buffers, cache, and swap figures — the same data `free` formats for you.

### Exercise 4

**4.1** Swap is space on disk that the kernel uses as an overflow area for RAM: when physical memory runs low, inactive memory pages are moved ("swapped out") to it. Because disk — even SSD — is orders of magnitude slower than RAM, a system that constantly swaps becomes noticeably slow ("thrashing").

**4.2** Linux deliberately uses idle RAM for buffers and cache to speed up disk access, so `free` (truly unused RAM) is naturally small on a healthy system. That cache memory is reclaimable the instant applications need it, so `available` — free memory plus reclaimable cache — is the realistic measure of what new programs can still get.

**4.3** Yes. Swap can be a dedicated partition or a regular swap file on an existing filesystem; `/proc/swaps` lists whichever the system uses, and both work the same way from the kernel's point of view.

### Exercise 5

**5.1** Logs traditionally live under `/var/log`. The FHS designates `/var` for *variable* data — files whose content grows and changes while the system runs (logs, spools, caches) — which is exactly how log files behave.

**5.2** Traditional syslog files are plain text, so you can read them directly with `cat`, `less`, `tail`, or `grep`. The systemd journal is stored in a binary, indexed format, so you must query it through `journalctl` — in exchange you get structured filtering (by boot with `-b`, by unit, by time, kernel-only with `-k`, live-follow with `-f`).

**5.3** `/run` lives in memory and is cleared at every reboot. If the journal exists only under `/run/log/journal`, the journal is volatile: log entries are lost on shutdown. Creating `/var/log/journal` (with appropriate configuration) makes the journal persistent across reboots.

### Exercise 6

**6.1** The kernel ring buffer is a fixed-size area of memory where the kernel writes its own messages (boot events, hardware detection, driver output). "Ring" means that when the buffer fills up, the newest messages overwrite the oldest ones — old entries are silently lost unless a logging service has already saved them.

**6.2** Typical cases: (a) checking whether newly connected hardware — a USB drive, a network card — was detected and which device name (e.g. `/dev/sdb`) the kernel assigned to it; (b) investigating boot problems, driver errors, or kernel-level warnings such as out-of-memory kills or disk I/O errors.

**6.3** They live only in the kernel ring buffer in RAM. Because the buffer exists from the moment the kernel starts, it captures events that occur before any logging daemon runs; once the log service (e.g. `systemd-journald`) starts, it collects those buffered messages and stores them, which is why `journalctl -k` shows the same content as `dmesg`.

</details>

---

*Material original elaborado como guía de estudio; basado en los temas del examen descritos en [LPI Learning Materials — Lesson 4.3](https://learning.lpi.org/en/learning-materials/010-160/4/4.3/).*