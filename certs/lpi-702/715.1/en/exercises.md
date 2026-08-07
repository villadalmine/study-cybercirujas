# LPI BSD Specialist (Exam 702-100) — Topic 715.1: Use the Shell and Work on the Command Line

**Exam Version:** 1.0  
**Weight:** 3.33  
**Target Audience:** SREs, Systems Architects, and Platform Engineers preparing for the [LPI BSD Specialist Certification](https://www.lpi.org/our-certifications/bsd-specialist-overview/).

---

## Technical Deep-Dive & Architecture Overview

### 1. BSD Shell Initialization Architecture and Lifecycle
Under BSD operating systems (FreeBSD, OpenBSD, NetBSD), command-line interaction relies on two primary shell families: POSIX-compliant shells (such as `/bin/sh`, derived from the Almquist Shell `ash`) and C-style shells (such as `/bin/tcsh` or `/bin/csh`).

```
                    +----------------------------------+
                    |       User Authentication        |
                    |      (PAM / login / sshd)        |
                    +----------------------------------+
                                     |
                                     v
                    +----------------------------------+
                    |  Validate Shell in /etc/shells   |
                    |  Fetch Shell path from passwd    |
                    +----------------------------------+
                                     |
               +---------------------+---------------------+
               |                                           |
               v                                           v
    POSIX Shell (/bin/sh)                       C-Shell (/bin/tcsh)
  +-------------------------+                 +-------------------------+
  | 1. /etc/profile         |                 | 1. /etc/csh.cshrc       |
  | 2. ~/.profile           |                 | 2. /etc/csh.login       |
  | 3. ENV file (~/.shrc)   |                 | 3. ~/.tcshrc / ~/.cshrc |
  +-------------------------+                 | 4. ~/.login             |
                                              +-------------------------+
```

When a user authenticates, the login daemon (`login(1)`, `sshd(8)`) reads the user's login shell from `/etc/passwd` (managed safely via `vipw(8)` or `chsh(1)`). The binary must match an entry inside `/etc/shells`.

#### Shell Startup Hierarchy & File Evaluation Order:
- **POSIX Shell (`/bin/sh`)**:
  - **Login Shell**: Evaluates system-wide configuration `/etc/profile`, then user-level `~/.profile`.
  - **Interactive Non-Login Shell**: Evaluates the file defined by the environment variable `$ENV` (typically `~/.shrc`).
- **C-Shell (`/bin/tcsh`)**:
  - **Login Shell**: Evaluates `/etc/csh.cshrc`, `/etc/csh.login`, `~/.tcshrc` (or `~/.cshrc`), and finally `~/.login`.
  - **Interactive Non-Login Shell**: Evaluates `/etc/csh.cshrc` and `~/.tcshrc` (skipping `.login` files).

---

### 2. Kernel File Descriptor Mechanics and Stream Redirection
In BSD systems, process I/O is governed by the kernel file descriptor (FD) table. Every process inherits standard descriptors from its parent:
- `FD 0` (`stdin`) — Standard Input
- `FD 1` (`stdout`) — Standard Output
- `FD 2` (`stderr`) — Standard Error

Redirection alters these pointers prior to process execution via the `dup2(2)` and `open(2)` system calls.

```
       Process File Descriptor Table                Open File Table (Kernel)
      +------------------------------+             +-------------------------+
      | FD 0 (stdin)  -------------->|------------>| /dev/tty (Read)         |
      | FD 1 (stdout) -------------->|-----+       +-------------------------+
      | FD 2 (stderr) -------------->|---| |       | /tmp/app.log (Write)    |
      +------------------------------+   | +------>+-------------------------+
                                         +-------->| /tmp/err.log (Write)    |
                                                   +-------------------------+
```

#### POSIX vs. C-Shell Syntax Comparison:

| Operation | POSIX `sh` / `bash` | `tcsh` / `csh` | Kernel Mechanic |
| :--- | :--- | :--- | :--- |
| Redirect `stdout` to File | `cmd > file` | `cmd > file` | `open(file, O_WRONLY\|O_CREAT)` + `dup2(fd, 1)` |
| Append `stdout` to File | `cmd >> file` | `cmd >> file` | `open(file, O_APPEND)` + `dup2(fd, 1)` |
| Redirect `stderr` to File | `cmd 2> file` | `(cmd > file) >& errfile` | `open(errfile)` + `dup2(fd, 2)` |
| Merge `stderr` into `stdout` | `cmd > file 2>&1` | `cmd >& file` | `dup2(1, 2)` point `stderr` to `stdout` vnode |
| Pipe `stdout` and `stderr` | `cmd 2>&1 \| tee log` | `cmd \|& tee log` | `pipe(2)` syscall creates anonymous pipe vnode |

---

### 3. Job Control, Process Sessions, and Signal Handling
BSD job control associates running tasks with a controlling terminal (`tty`). Process grouping dictates signal delivery across process trees.

- **Session Leader (SID)**: Created when logging in. Manages foreground/background process groups.
- **Process Group ID (PGID)**: Groups processes originating from a single pipeline or command.
- **Terminal Foreground Process Group (`tpgid`)**: Only the process group matching `tpgid` receives direct input and terminal signals (`SIGINT` `Ctrl+C`, `SIGTSTP` `Ctrl+Z`).

#### Core Signals and Operating System Actions:
- `SIGHUP` (1): Terminal hangup / Session termination. Sent to background processes when controlling terminal exits, unless caught or ignored (`nohup`).
- `SIGINT` (2): Interrupt signal sent by keyboard `Ctrl+C`.
- `SIGKILL` (9): Uncatchable, non-ignorable kernel process termination.
- `SIGTERM` (15): Standard software termination request allowing graceful cleanup.
- `SIGTSTP` (18/20): Terminal stop signal sent by `Ctrl+Z`. Pauses execution and moves process to background state (`STOPPED`).

---

## Guided Practical Exercises

### Exercise Block 1: Shell Initialization, User Profile Scoping, and Shell Switching

#### Objective:
Analyze shell registration, safely change a user shell using BSD tooling, and configure distinct startup scripts for both `/bin/sh` and `/bin/tcsh`.

#### Execution Steps:

1. Inspect active allowed shells on the BSD host and verify the current user shell details:
```syslog
$ cat /etc/shells
/bin/sh
/bin/csh
/bin/tcsh
/usr/local/bin/bash

$ finger $USER
Login: sreadmin                         Name: SRE Admin
Directory: /home/sreadmin               Shell: /bin/sh
```

2. Test switching your login shell to `/bin/tcsh` using `chsh`:
```syslog
$ chsh -s /bin/tcsh
chsh: user information updated
```

3. Create environment variable definitions in both POSIX shell (`~/.profile` and `~/.shrc`) and C-shell (`~/.cshrc`) configurations:
```syslog
$ cat << 'EOF' >> ~/.profile
export CLUSTER_ENV="production-us-east"
export ENV="$HOME/.shrc"
EOF

$ cat << 'EOF' >> ~/.shrc
alias ll="ls -laF"
EOF

$ cat << 'EOF' >> ~/.cshrc
setenv CLUSTER_ENV "production-us-east"
alias ll "ls -laF"
EOF
```

4. Verify shell environment inheritance using FreeBSD process diagnostic tool `procstat`:
```syslog
$ sh -c 'echo $CLUSTER_ENV'
production-us-east

$ procstat -e $$ | grep CLUSTER_ENV
 1482 sh               CLUSTER_ENV      production-us-east
```

---

#### Verification Questions (Block 1)

1.1. Why does an interactive non-login execution of `/bin/sh` fail to load environment variables declared in `~/.profile`, and what exact configuration mechanism resolves this behavior?

1.2. If a user sets their shell to `/usr/local/bin/zsh` via `chsh`, but `/usr/local/bin/zsh` is omitted from `/etc/shells`, what security mechanism triggers during `sshd(8)` or `su(1)` authentication, and what is the outcome?

1.3. Compare the syntax and execution mechanics of defining an environment variable and an alias between `/bin/sh` and `/bin/tcsh`.

---

### Exercise Block 2: File Descriptor Plumbing, Stream Splitting, and Pipe Inspection

#### Objective:
Master standard stream redirection, separate `stdout` from `stderr`, and inspect open process descriptors using BSD utilities (`fstat` / `procstat`).

#### Execution Steps:

1. Create a script `stream_app.sh` that writes to both `stdout` and `stderr`:
```syslog
$ cat << 'EOF' > stream_app.sh
#!/bin/sh
echo "[INFO] Processing payload chunk 1" >&1
echo "[ERROR] Failed to resolve DB host" >&2
echo "[INFO] Processing payload chunk 2" >&1
EOF
$ chmod +x stream_app.sh
```

2. Execute the script in POSIX `sh`, routing `stdout` to a file while keeping `stderr` visible on the terminal:
```syslog
$ ./stream_app.sh > app_info.log
[ERROR] Failed to resolve DB host

$ cat app_info.log
[INFO] Processing payload chunk 1
[INFO] Processing payload chunk 2
```

3. Use custom file descriptors (`exec 3>&1`) to send `stdout` to `app.log` while redirecting `stderr` through `tee` to both terminal and `error.log`:
```syslog
$ ( ./stream_app.sh 2>&1 1>&3 | tee error.log ) 3> app.log
[ERROR] Failed to resolve DB host

$ cat error.log
[ERROR] Failed to resolve DB host

$ cat app.log
[INFO] Processing payload chunk 1
[INFO] Processing payload chunk 2
```

4. Run a long-running pipeline in the background and inspect its file descriptors using `fstat`:
```syslog
$ sleep 300 | tail -f /dev/null &
[1] 49122

$ fstat -p 49122
USER     CMD          PID   FD MOUNT      INUM MODE         SZ|DV R/W
sreadmin tail       49122 text /         31204 -rwxr-xr-x  28416  r
sreadmin tail       49122    0 pipe 0xfffffe004a11b220       0  r
sreadmin tail       49122    1 /usr      12045 -rw-r--r--       0  w
sreadmin tail       49122    2 /dev       1102 crw-rw-rw-    null rw
```

---

#### Verification Questions (Block 2)

2.1. In POSIX shell, explain why `cmd > logfile 2>&1` behaves differently than `cmd 2>&1 > logfile`. Describe the internal `dup2(2)` call sequence for both.

2.2. How does `tcsh` accomplish merging `stderr` into a pipe (`|&`), and how would you duplicate `(cmd 2>&1 1>&3 | tee err.log) 3> out.log` inside `/bin/tcsh`?

2.3. Analyze the `fstat` output from Step 4. What does `FD 0 pipe 0xfffffe...` signify at the FreeBSD kernel subsystem layer?

---

### Exercise Block 3: Job Control, Signal Dispatch, Traps, and Session Detachment

#### Objective:
Manipulate job control states (`CTRL+Z`, `bg`, `fg`), configure `trap` signal handling in POSIX `sh`, and manage asynchronous process persistence across session hangup (`SIGHUP`).

#### Execution Steps:

1. Launch a process, suspend it, convert it to a background job, and verify process flags using `ps`:
```syslog
$ ping -i 2 127.0.0.1
^Z
[1]+  Stopped                 ping -i 2 127.0.0.1

$ bg %1
[1]+ ping -i 2 127.0.0.1 &

$ ps -o pid,pgid,sid,tpgid,stat,command -p $(pgrep ping)
  PID  PGID   SID TPGID STAT COMMAND
50122 50122 49001 49001 S    ping -i 2 127.0.0.1
```

2. Construct an SRE daemon simulation `worker.sh` that traps signals for graceful shutdown:
```syslog
$ cat << 'EOF' > worker.sh
#!/bin/sh
trap 'echo "Caught SIGHUP - reloading config..."; reload_config' 1
trap 'echo "Caught SIGTERM - shutting down gracefully"; exit 0' 15

reload_config() {
  echo "[CONFIG] Reloaded at $(date)" >> worker.log
}

echo "[INIT] Worker started with PID $$" >> worker.log
while true; do
  sleep 2
done
EOF
$ chmod +x worker.sh
$ ./worker.sh &
[1] 51204
```

3. Send signals using `kill` and `pkill`, then verify output log:
```syslog
$ kill -1 51204
$ kill -15 51204
[1]+  Done                    ./worker.sh

$ cat worker.log
[INIT] Worker started with PID 51204
Caught SIGHUP - reloading config...
[CONFIG] Reloaded at Thu Aug  6 21:00:10 UTC 2026
Caught SIGTERM - shutting down gracefully
```

4. Demonstrate session immunity using `nohup` vs process detachment:
```syslog
$ nohup sleep 600 > sleep.log 2>&1 &
[1] 52001
$ ps -o pid,ppid,pgid,sid,stat,command -p 52001
  PID  PPID  PGID   SID STAT COMMAND
52001 49001 52001 49001 I    sleep 600
```

---

#### Verification Questions (Block 3)

3.1. In the output of `ps -o pid,pgid,sid,tpgid,stat,command`, what is the relationship between `PGID` and `TPGID` for a foreground process versus a background process?

3.2. What happens to a child process executing inside `/bin/sh` when the parent shell receives a `SIGHUP` signal if `nohup` was **not** used? How does `disown` (or `csh` `nohup` builtin) alter this behavior?

3.3. Why is `SIGKILL` (signal 9) impossible to handle with the shell `trap` builtin, and what SRE operational risk arises from using `kill -9` prematurely on databases or stateful daemons?

---

### Exercise Block 4: Command Path Resolution Order, History Mechanisms, and Environment Manipulation

#### Objective:
Master the resolution hierarchy of executable entities in BSD shells (`alias`, `builtin`, `function`, `$PATH`), configure command history mechanisms, and inspect environment manipulation builtins.

#### Execution Steps:

1. Investigate command type precedence using `type`, `which`, and `whereis`:
```syslog
$ alias ls="ls -G"
$ type ls
ls is an alias for ls -G

$ which ls
/bin/ls

$ whereis ls
ls: /bin/ls /usr/share/man/man1/ls.1.gz
```

2. Test override priority by creating a shell function and an alias with identical names:
```syslog
$ test_func() { echo "Function executed"; }
$ alias test_func="echo Alias executed"

$ test_func
Alias executed

$ \test_func
Function executed
```

3. Configure history variables and test expansion operators:
```syslog
# POSIX / Bash environment settings
$ HISTSIZE=5000
$ HISTFILE="$HOME/.sh_history"

# Execute commands and utilize expansion
$ tail -n 20 /var/log/messages
$ !tail
tail -n 20 /var/log/messages
```

4. Compare environment variable setting and deletion across `sh` and `tcsh`:
```syslog
# POSIX sh
$ WORKER_NODES="node1 node2"
$ export WORKER_NODES
$ unset WORKER_NODES

# C-shell (tcsh)
> setenv WORKER_NODES "node1 node2"
> unsetenv WORKER_NODES
```

---

#### Verification Questions (Block 4)

4.1. Order the following execution entities from **highest priority to lowest priority** during command lookup in a POSIX shell: `Builtin`, `Executable Binary in $PATH`, `Alias`, `Function`.

4.2. How does prepending a backslash (`\command`) or using the `command` builtin alter shell execution lookup mechanics?

4.3. In `tcsh`, what is the key functional difference between `set var = "value"` and `setenv VAR "value"` regarding subshell inheritance?

---

<details>
<summary><b>Answers and Detailed Explanations</b></summary>

### Exercise Block 1 Answers

**1.1 Answer:**  
In POSIX `/bin/sh`, `~/.profile` is parsed exclusively by **login shells** (initiated with a leading hyphen `-sh` or via `--login`). Interactive non-login subshells (such as terminal multiplexers or child script executions) bypass `~/.profile`. To make aliases and functions available in non-login interactive shells, POSIX `sh` evaluates the file path referenced by the `$ENV` variable. Therefore, exporting `export ENV="$HOME/.shrc"` inside `~/.profile` ensures that subsequent non-login interactive shells execute `~/.shrc`.

**1.2 Answer:**  
During authentication (`sshd`, `su`, `login`), system utilities validate the user's assigned shell against `/etc/shells` via the `getusershell(3)` API. If `/usr/local/bin/zsh` is missing from `/etc/shells`, authentication security policies reject the session or fall back to a default restricted shell (`/bin/sh` or deny access entirely). This safeguard prevents execution of arbitrary binaries or unapproved custom shells.

**1.3 Answer:**  
- **Environment Variables**:
  - `sh`: `export VAR="value"` or `VAR="value"; export VAR`. Writes directly to the `environ` pointer array inherited by child processes.
  - `tcsh`: `setenv VAR "value"`. Uses a distinct builtin command syntax without an equals sign (`=`).
- **Aliases**:
  - `sh`: `alias key="command --flag"`. Uses `=` syntax.
  - `tcsh`: `alias key "command --flag"`. Uses whitespace separation instead of `=`.

---

### Exercise Block 2 Answers

**2.1 Answer:**  
Shell redirections are evaluated **left to right**:
- `cmd > logfile 2>&1`:
  1. `> logfile`: Opens `logfile` and uses `dup2(fd, 1)` so `stdout` points to `logfile`.
  2. `2>&1`: Calls `dup2(1, 2)`, duplicating descriptor 1 (`logfile`) onto descriptor 2 (`stderr`). Both `stdout` and `stderr` stream into `logfile`.
- `cmd 2>&1 > logfile`:
  1. `2>&1`: Calls `dup2(1, 2)`, duplicating descriptor 1 (currently terminal `/dev/tty`) onto descriptor 2. `stderr` now points to terminal output.
  2. `> logfile`: Calls `dup2(fd, 1)`, moving `stdout` to `logfile`.
  - **Result**: `stdout` goes to `logfile`, but `stderr` continues outputting to the terminal.

**2.2 Answer:**  
In `/bin/tcsh`, merging stream 2 into stream 1 for piping uses the `|&` operator (`cmd |& tee logfile`). To redirect `stdout` to `out.log` while capturing `stderr` separately into `err.log` without POSIX descriptor manipulation, `tcsh` requires subshell isolation:
```tcsh
(cmd > out.log) >& err.log
```

**2.3 Answer:**  
The line `FD 0 pipe 0xfffffe004a11b220` indicates that File Descriptor 0 (`stdin`) of `tail` has been converted from a character device (`/dev/tty`) to a **BSD Kernel Pipe Vnode** via the `pipe(2)` system call. The hex address `0xfffffe...` points to the kernel memory buffer allocated for inter-process communication between `sleep` (`stdout`) and `tail` (`stdin`).

---

### Exercise Block 3 Answers

**3.1 Answer:**  
- For a **foreground process group**, the Process Group ID (`PGID`) matches the Controlling Terminal's Foreground Process Group ID (`TPGID`). This grants the process group exclusive read access to `stdin` and routes terminal signals (`SIGINT`/`SIGTSTP`) directly to it.
- For a **background process group**, `PGID` does **not** match `TPGID` (`PGID != TPGID`). If a background process attempts to read from `stdin`, the BSD kernel sends a `SIGTTIN` signal, suspending the process until brought to the foreground via `fg`.

**3.2 Answer:**  
When an interactive POSIX shell terminates, the kernel sends a `SIGHUP` (Signal 1) to all jobs in its active process group. Without `nohup`, child processes terminate upon receiving `SIGHUP`. The `nohup` wrapper sets the `SIGHUP` handler to `SIG_IGN` (Ignore). The `disown` builtin removes the target job from the shell's job table, preventing the shell from dispatching `SIGHUP` to that process group upon exit.

**3.3 Answer:**  
`SIGKILL` (signal 9) bypasses user-space signal vector tables completely; it is processed directly by the kernel's process scheduler to immutably revoke allocation contexts and terminate the process structure. Because the process never executes user-space code upon receipt of `SIGKILL`, it cannot catch the signal, perform cleanup routines (such as flushing I/O buffers, removing lock files, or closing active IPC sockets), leading to data corruption in database engines or inconsistent lock states.

---

### Exercise Block 4 Answers

**4.1 Answer:**  
The resolution order in POSIX shells is:
1. **Alias**
2. **Keyword** (e.g., `if`, `while`)
3. **Function**
4. **Builtin** (e.g., `cd`, `echo`, `exec`)
5. **Executable Binary in `$PATH`** (e.g., `/bin/ls`, `/usr/bin/grep`)

**4.2 Answer:**  
Prepending a backslash (`\command`) or invoking `command name`:
- **Disables Alias Expansion**: Suppresses alias lookup entirely, forcing the shell to search for functions, builtins, or `$PATH` executables.
- **`command` Builtin**: Suppresses both **Aliases** and **Shell Functions**, forcing lookup to resolve strictly to builtins or external binaries located in `$PATH`. This prevents infinite loops inside custom wrapper functions.

**4.3 Answer:**  
- `set var = "value"`: Instantiates a **local shell variable** inside `tcsh`. It resides strictly within the internal shell hash table and is **not** exported to child processes or subshells.
- `setenv VAR "value"`: Modifies the C-shell **environment variable array** (`environ`), ensuring that all child processes, scripts, and subshells spawned from this session inherit `VAR`.

</details>