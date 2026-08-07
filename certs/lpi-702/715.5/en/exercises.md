# BSD Specialist (702-100) — Topic 715.5: Perform Basic File Editing Operations

**Exam Weight:** 3.34  
**Target Level:** BSD Specialist / Production Systems Engineer  
**Official Reference:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## 1. Architectural & Technical Deep Dive: The BSD `nvi` Engine

On modern BSD operating systems (FreeBSD, OpenBSD, NetBSD), the default `/usr/bin/vi` command is typically implemented by **`nvi`** (New VI), Keith Bostic's clean-room rewrite of the classic Berkeley `vi`. Understanding `nvi` internal mechanics is critical for SREs operating in constrained boot, recovery, and production environments.

### 1.1 Memory Architecture and Buffer Recovery
`nvi` does not hold the entire file in active process heap space as a simple contiguous buffer. Instead, it utilizes a line-oriented database structure backed by dynamic page allocation and temporary persistent files.

```
                    +------------------------------------+
                    |        User Terminal (TTY)         |
                    +------------------------------------+
                                      |  ^
                Input (RAW Mode)      |  | Rendering / ANSI escape
                                      v  |
                    +------------------------------------+
                    |       nvi Process Engine           |
                    |  - Command Parser                  |
                    |  - Register Bank (a-z, 1-9, ")     |
                    +------------------------------------+
                                      |
                      Page Cache / Line Pointer Map
                                      |
         +----------------------------+----------------------------+
         v                                                         v
+-------------------------------+                       +-------------------------------+
| Memory-Mapped Working Pages   |                       | Recovery Log Files            |
| (Active buffers in RAM)       |                       | /var/tmp/vi.recover/vi.XXXXXX |
+-------------------------------+                       +-------------------------------+
```

* **Temporary Buffer & Recovery Logs:** When editing a file (e.g., `/etc/pf.conf`), `nvi` creates a recovery file in `/var/tmp/vi.recover/` (or `/tmp`). Every modification is written to this recovery database via synced append-only logging before updating the visual frame.
* **Signal Handling & Crash Safety:** Upon receiving `SIGHUP` or `SIGTERM` (e.g., an interrupted SSH session), `nvi` catches the signal, flushes out uncommitted changes to `/var/tmp/vi.recover/`, and emails the user notification via `sendmail` or system log mechanisms. The session can later be reconstructed using `vi -r <filename>`.

### 1.2 Modal Execution and State Machine
`nvi` operates as a finite state machine with three core modes:

1. **Command Mode (Normal Mode):** Default state upon invocation. Keys are interpreted as editing commands (`d`, `y`, `p`, `u`, `h`, `j`, `k`, `l`).
2. **Insert Mode:** Text entered by the user is written into the active insertion stream. Entered via `i`, `a`, `o`, `O`, `A`, `I`, `c`, `s`. Exit back to Command Mode via `<ESC>`.
3. **Ex Mode / Line Mode:** Entered via `:` from Command Mode. Passes line-oriented commands to the underlying Ex editor engine (`:w`, `:q`, `:s`, `:set`).

### 1.3 Read-Only Override Mechanics (`:w!`)
When editing read-only files (e.g., owned by `root` with `0444` permissions), `nvi` checks both the process Effective User ID (EUID) and filesystem write bits.
* If the file is read-only for the current user but the user is `root` (or owns the file), standard write commands (`:w`) will fail with `Permission denied` or `Read-only file`.
* Executing **`:w!`** forces `nvi` to issue an un-link / re-open system call (`open(2)` with `O_WRONLY | O_CREAT | O_TRUNC`), overriding file permission flags on POSIX/BSD filesystems provided the underlying directory permissions permit `w` operations.

---

## 2. Production Guided Exercises

### Exercise 1: Core Editing Mechanics, Navigation, and Buffer Operations

In this exercise, you will initialize a mock production system configuration, perform text insertions, yank/put (copy/paste) line buffers, and test atomic undo operations.

#### Step 1.1: Environment Setup
Log in to your BSD system shell (`sh` or `csh`) and construct a baseline environment configuration file:

```syslog
cat << 'EOF' > /tmp/syslog.conf
# /tmp/syslog.conf - Baseline BSD Logging Configuration
*.err;kern.warning;auth.notice;mail.crit        /dev/console
*.notice;authpriv.none;kern.debug;mail.crit     /var/log/messages
security.*                                      /var/log/security
auth.info;authpriv.info                         /var/log/auth.log
mail.info                                       /var/log/maillog
cron.info                                       /var/log/cron
EOF
```

Verify line contents and line count using `wc -l`:

```console
$ wc -l /tmp/syslog.conf
       7 /tmp/syslog.conf
```

#### Step 1.2: Modal Text Insertion and Line Creation
Open the file in `vi`:

```console
$ vi /tmp/syslog.conf
```

1. Ensure you are in **Command Mode** by pressing `<ESC>`.
2. Move your cursor to the top of the file by pressing `1G` or `gg`.
3. Open a new line *above* the current line by pressing `O`.
4. Type the following header comment:
   `# PRODUCTION SRE OVERRIDE - DO NOT REMOVE`
5. Press `<ESC>` to return to Command Mode.
6. Move down to the line starting with `security.*` using `/security.*` followed by `<ENTER>`.
7. Append text to the *end of the current line* by pressing `A`, type ` # Audit Log Channel`, and press `<ESC>`.

#### Step 1.3: Yanking, Deleting, and Putting Lines
1. Navigate to the line starting with `cron.info`.
2. Delete the `cron.info` line completely and store it in the unnamed register by typing `dd`.
3. Move cursor to the bottom line using `G`.
4. Paste (put) the deleted line *below* the current cursor line by pressing `p`.
5. Duplicate (yank) the line `auth.info` by positioning the cursor on it and typing `yy`.
6. Paste it *above* the current line by pressing `P`.

#### Step 1.4: Multi-Step Undo and Redo Mechanics
1. Delete the line you just pasted using `dd`.
2. Press `u` to revert the deletion.
3. In standard BSD `nvi`, pressing `u` again acts as an undo of the undo (re-deleting the line). Perform `u` twice to observe `nvi`'s dual-state undo behavior compared to Vim's linear history tree.
4. Save the file and exit by typing `:wq` followed by `<ENTER>`.

---

#### Question Block 1
**Q1.1:** What is the technical result of pressing `u` twice sequentially in traditional BSD `nvi` vs GNU `vim`?  
**Q1.2:** Which sequence of commands allows an engineer to append text to the very end of a line without manually moving the cursor position rightward using `l` or `$`?

---

### Exercise 2: Advanced Pattern Search, Global Line Substitution, and Regex

In this exercise, you will perform high-precision search and bulk regex substitutions on network firewall configuration structures (`/etc/pf.conf`).

#### Step 2.1: Prepare Firewall Manifest
Create a mock FreeBSD Packet Filter configuration:

```pf
cat << 'EOF' > /tmp/pf.conf
# /tmp/pf.conf - Web Tier Filtering
ext_if="vtnet0"
int_if="vtnet1"

table <webservers> { 192.168.1.10, 192.168.1.11, 192.168.1.12 }
table <dbservers>  { 10.0.10.5, 10.0.10.6 }

set skip on lo0
scrub in all

block all
pass out quick on $ext_if keep state
pass in quick on $ext_if proto tcp to <webservers> port 80 keep state
pass in quick on $ext_if proto tcp to <webservers> port 443 keep state
EOF
```

#### Step 2.2: Forward/Backward Search and Navigation
Open `/tmp/pf.conf` with `vi`:

```console
$ vi /tmp/pf.conf
```

1. Search forward for the word `keep` by typing `/keep` and pressing `<ENTER>`.
2. Move to the next occurrence using `n`.
3. Move to the previous occurrence using `N`.
4. Enable visual line numbering by entering Ex mode: `:set number` (or `:set nu`).
5. Observe the left-hand column:

```syslog
     1  # /tmp/pf.conf - Web Tier Filtering
     2  ext_if="vtnet0"
     3  int_if="vtnet1"
     4  
     5  table <webservers> { 192.168.1.10, 192.168.1.11, 192.168.1.12 }
     ...
```

#### Step 2.3: Performing Ex Global Substitutions
1. Substitute all occurrences of interface `vtnet0` with `em0` across the entire document:
   Type `:1,$s/vtnet0/em0/g` or `:%s/vtnet0/em0/g` and press `<ENTER>`.
2. Change the subnet addressing scheme for webservers from `192.168.1.` to `172.16.10.` targeting only lines containing the string `table <webservers>`:
   Type `:g/table <webservers>/s/192\.168\.1\./172\.16\.10\./g` and press `<ENTER>`.
3. Verify line modification. The line should now read:
   `table <webservers> { 172.16.10.10, 172.16.10.11, 172.16.10.12 }`
4. Write changes to disk without exiting:
   Type `:w` and press `<ENTER>`. Expected output on status line:
   `"/tmp/pf.conf": 14 lines, 342 characters`

---

#### Question Block 2
**Q2.1:** In the command `:%s/vtnet0/em0/g`, what exact functions do `%` and `g` perform in the Ex syntax engine?  
**Q2.2:** How can you search backward from the current cursor position for the literal term `block`?

---

### Exercise 3: Read-Only Files, Forced Overrides, and Recovery File Diagnostics

This exercise models an operational incident where a system configuration file is set to read-only (`0444`), requiring force-write flags (`:w!`), and simulates an unexpected terminal drop to recover unwritten buffers from `/var/tmp/vi.recover`.

#### Step 3.1: Enforce Read-Only Permissions
Create a protected configuration file owned by your current user:

```console
$ touch /tmp/sysctl.conf
$ chmod 444 /tmp/sysctl.conf
$ echo "net.inet.ip.forwarding=0" > /tmp/sysctl.conf 2>/dev/null || chmod 644 /tmp/sysctl.conf && echo "net.inet.ip.forwarding=0" > /tmp/sysctl.conf && chmod 444 /tmp/sysctl.conf
$ ls -l /tmp/sysctl.conf
-r--r--r--  1 root  wheel  25 Aug  6 21:00 /tmp/sysctl.conf
```

#### Step 3.2: Standard Edit Attempt and Failure Analysis
Open the file using `vi`:

```console
$ vi /tmp/sysctl.conf
```

1. Observe the bottom status line: `"/tmp/sysctl.conf" [Read-only] 1 line, 25 characters`.
2. Navigate to the end of line using `$` and add a line using `o`.
3. Type `net.inet.tcp.blackhole=2` and press `<ESC>`.
4. Attempt a standard write and exit: `:wq`.
5. Observe the error response from `nvi`:
   `sysctl.conf: read-only file; use w! to override` or `Permission denied`.

#### Step 3.3: Force-Write Execution (`:w!`)
1. Force the write back to the filesystem:
   Type `:w!` and press `<ENTER>`.
2. Verify the output line: `"/tmp/sysctl.conf" 2 lines, 51 characters`.
3. Exit `vi`: `:q`.
4. Verify file content from shell:

```console
$ cat /tmp/sysctl.conf
net.inet.ip.forwarding=0
net.inet.tcp.blackhole=2
```

#### Step 3.4: Simulating Process Termination and File Recovery
1. Open `/tmp/sysctl.conf` again:
   `vi /tmp/sysctl.conf`
2. Add a new line at the bottom: `kern.maxfiles=65536`. Do **NOT** run `:w`.
3. Simulate an unexpected SSH connection drop by sending `SIGHUP` to your active `vi` process from a secondary shell, or kill the process using PID lookup:

```console
$ pkill -HUP nvi || pkill -HUP vi
```

4. Check the recovery directory `/var/tmp/vi.recover`:

```console
$ ls -la /var/tmp/vi.recover/
total 4
drwxr-xr-x  2 root  wheel  512 Aug  6 21:05 .
drwxrwxrwt  3 root  wheel  512 Aug  6 21:05 ..
-rw-------  1 root  wheel  896 Aug  6 21:05 recover.vi.XXXXXX
```

5. Recover the lost file session using the `-r` flag:

```console
$ vi -r /tmp/sysctl.conf
```

6. Confirm the unsaved line `kern.maxfiles=65536` is restored in the buffer.
7. Save and quit cleanly: `:wq`.

---

#### Question Block 3
**Q3.1:** What filesystem-level operation does `:w!` perform under the hood when executed by the file owner on a file with mode `0444`?  
**Q3.2:** If `vi -r` shows multiple recovery files for `/etc/rc.conf`, how can an engineer inspect the available recovery snapshots listed by `nvi`?

---

### Exercise 4: Customization via `.exrc` and Production Environment Overrides

In this exercise, you will configure persistent `vi`/`nvi` editor parameters via initialization manifests (`~/.exrc`) and control default editors via shell environment variables (`EDITOR` / `VISUAL`).

#### Step 4.1: Constructing Syntactically Valid `~/.exrc`
Create a persistent configuration file for `nvi` in your home directory:

```vim
cat << 'EOF' > ~/.exrc
" BSD nvi Runtime Configuration (~/.exrc)
set number
set autoindent
set shiftwidth=4
set tabstop=4
set showmatch
set ignorecase
EOF
```

Verify permissions. In BSD `nvi`, if `~/.exrc` is writable by group or others, `nvi` will **ignore** the file for security reasons to prevent unauthorized macro injection:

```console
$ chmod 600 ~/.exrc
$ ls -l ~/.exrc
-rw-------  1 sradmin  wheel  142 Aug  6 21:10 /home/sradmin/.exrc
```

#### Step 4.2: Testing Environment Variable Overrides (`EDITOR` / `VISUAL`)
Crontab editing (`crontab -e`), `visudo`, and `git commit` rely on process environment variables to invoke text editors.

1. Export `EDITOR` and `VISUAL` in your current shell session:

```console
$ export EDITOR=/usr/bin/vi
$ export VISUAL=/usr/bin/vi
```

2. Test environment precedence with a non-interactive check:

```console
$ env | grep -E 'EDITOR|VISUAL'
EDITOR=/usr/bin/vi
VISUAL=/usr/bin/vi
```

3. Open a file with `vi` to verify `~/.exrc` features (such as line numbers and 4-space indenting) load automatically:

```console
$ vi /tmp/test_config.txt
```

---

#### Question Block 4
**Q4.1:** Why will `nvi` refuse to process a `~/.exrc` file that has permissions set to `0666` (`-rw-rw-rw-`)?  
**Q4.2:** In system administration tools like `visudo` or `crontab -e`, which environment variable typically takes precedence if both `VISUAL` and `EDITOR` are set?

---

<details>
<summary><b>Answers & Detailed Technical Explanations</b></summary>

### Answers for Question Block 1

* **A1.1:** In standard BSD `nvi`, the undo command `u` is togglable and single-level: pressing `u` once reverts the last change, and pressing `u` a second time reverts the undo (effectively re-applying the change). In Vim, `u` walks backward through a multi-level linear history tree.
* **A1.2:** Pressing **`A`** (Shift + `a`) transitions `nvi` into Insert Mode and automatically places the cursor after the last character of the current line.

---

### Answers for Question Block 2

* **A2.1:** `%` specifies the line range address representing all lines in the buffer (equivalent to `1,$`). `g` is the global execution flag instructing the command to replace every match on a line rather than stopping at the first occurrence.
* **A2.2:** Type **`?block`** followed by `<ENTER>`. The `?` initiator performs a reverse/backward regex search upward from the current line.

---

### Answers for Question Block 3

* **A3.1:** Because the file owner has write access to the parent directory, `:w!` bypasses the file's read-only bit (`0444`) by invoking `open(2)` with write/truncate flags or updating file mode bits temporarily during the write call, allowing the owner (or root) to overwrite the file content.
* **A3.2:** Run **`vi -r`** with no filename arguments (`vi -r`). `nvi` will list all existing recovery files saved in `/var/tmp/vi.recover/` along with their creation timestamps and original file paths.

---

### Answers for Question Block 4

* **A4.1:** `nvi` checks the file permissions of `~/.exrc` (and `.nexrc`). If the file is writable by group or world (`group` or `other` write bits set), `nvi` aborts loading it to prevent untrusted local users from injecting malicious Ex commands or shell escapes into another user's editor session.
* **A4.2:** **`VISUAL`** takes precedence over `EDITOR` in standard POSIX/BSD utility implementations (including `visudo` and `crontab`). If `VISUAL` is defined and non-empty, it is used; `EDITOR` serves as the secondary fallback.

</details>

---

## 3. Official References & Citation
* **Linux Professional Institute BSD Specialist Certification:** Objectives 702-100, Topic 715.5  
  URL: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Manual Pages - nvi(1):**  
  URL: [https://man.freebsd.org/cgi/man.cgi?query=nvi](https://man.freebsd.org/cgi/man.cgi?query=nvi)
* **OpenBSD Manual Pages - vi(1):**  
  URL: [https://man.openbsd.org/vi](https://man.openbsd.org/vi)