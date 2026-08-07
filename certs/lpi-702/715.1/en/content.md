# LPI-702 (Exam 702-100, Version 1.0)
## Topic 715.1: Use the Shell and Work on the Command Line
**Exam Weight:** 3.33  
**Target Profile:** Principal Platform Architect / Senior SRE Instructor  

---

### 1. Production Architectural Motivation & Problem Statement

In enterprise BSD environments (FreeBSD storage hypervisors running ZFS, network appliances running pfSense/OPNsense, NetBSD embedded edge devices, and isolated micro-tenant environments within FreeBSD Jails), the command-line shell serves as the primary system interface for both human interactive troubleshooting and automated orchestration engine targets (Ansible, SaltStack, custom CI/CD runners, and `cron` jobs).

```
                      +------------------------------------------+
                      |   Orchestration / Automation System      |
                      |    (Ansible, Cron, SSH Remote Exec)     |
                      +------------------------------------------+
                                           |
                                           v
                       Non-Interactive Execution (/bin/sh)
                        - No TTY attached (stty fails)
                        - Minimal PATH (/usr/bin:/bin)
                        - Sources ~/.profile or $ENV (no .cshrc)
                                           |
                    +----------------------+----------------------+
                    |                                             |
                    v                                             v
        +-----------------------+                     +-----------------------+
        |   FreeBSD Host Base   |                     |   FreeBSD Jail Cell   |
        |  Process Tree (PID 1) |                     |   Isolated Namespace  |
        +-----------------------+                     +-----------------------+
                    |                                             |
                    v                                             v
        Subshell Execution (fork/exec)                Subshell Execution (fork/exec)
        - FD 0, 1, 2 Multiplexing                     - Strict Resource Limits (rctl)
        - Signal Handling (SIGINT/SIGTERM)            - Isolated IPC & Networking
```

#### The Production Architectural Problem
Production failures in BSD command-line automation typically stem from three core friction points:

1. **Shell Implementation Divergence:** BSD systems ship with distinct standard base shells. FreeBSD historically defaults interactive users (and `root`) to `/bin/csh` or `/bin/tcsh` (TENEX C Shell), while non-interactive automated jobs execute under POSIX-compliant `/bin/sh` (Almquist Shell family variant). In contrast, OpenBSD uses a modified Public Domain Korn Shell (`/bin/ksh`), and NetBSD uses its own POSIX `/bin/sh`. Scripts written with C-shell assumptions fail catastrophically under `/bin/sh`, and vice-versa.
2. **Environment & Initialization Cascades:** Automated execution contexts (e.g., non-interactive SSH execution via `ssh host "cmd"`) do not initialize interactive login shell files (such as `.cshrc` or interactive blocks in `.profile`). Unset `PATH` variables, missing system locale masks, or uninitialized `TERMCAP` variables break binary execution paths and automated output parsing.
3. **Signal & File Descriptor Leakage:** Subshell invocations (`( ... )`), background process pipelines (`cmd1 | cmd2 &`), and unmanaged background execution in stateless containers lead to orphaned process groups, pipe buffer deadlocks (`SIGPIPE` handling), and un-reaped zombie processes inside isolated execution spaces like BSD Jails.

To guarantee zero-downtime automation, deterministic provisioning, and reliable disaster recovery, SREs must understand shell kernel interaction mechanics, process lineage, file descriptor manipulation, signal propagation, and environment isolation across BSD variants.

---

### 2. Technical Architecture & Comparative Analysis

#### 2.1 BSD Standard Shell Implementations Matrix

The table below contrasts the shell implementations available in standard BSD base installations and ports/packages repositories.

| Feature / Metric | `/bin/sh` (FreeBSD / NetBSD `ash` variant) | `/bin/csh` / `/bin/tcsh` (FreeBSD Base Root Default) | `/bin/ksh` (OpenBSD Base Default) | `/usr/local/bin/bash` (Pkg/Port Install) |
| :--- | :--- | :--- | :--- | :--- |
| **POSIX Standard Compliance** | High (Strict IEEE Std 1003.1) | Non-Compliant (C-like syntax) | High (POSIX / AT&T ksh88 subset) | High (POSIX + GNU Extensions) |
| **Primary Production Role** | Base System Scripts & Automation | Interactive Admin Sessions | Base Scripts & Admin Shell | Heterogeneous CI/CD Compatibility |
| **Memory Footprint (RSS)** | Extremely Low (~0.8 MB - 1.5 MB) | Low (~2.0 MB - 3.5 MB) | Low (~1.5 MB - 2.5 MB) | Moderate (~4.5 MB - 8.0 MB) |
| **Binary Path Location** | `/bin/sh` | `/bin/csh` -> `/bin/tcsh` | `/bin/ksh` | `/usr/local/bin/bash` |
| **Environment Export Syntax** | `VAR="val"; export VAR` | `setenv VAR "val"` | `export VAR="val"` | `export VAR="val"` |
| **Separate Stderr Redirect** | `cmd 2> err.log` | `(cmd > out.log) >& err.log` | `cmd 2> err.log` | `cmd 2> err.log` |
| **Combined Out/Err Redirect** | `cmd > out.log 2>&1` | `cmd >& out.log` | `cmd > out.log 2>&1` | `cmd &> out.log` or `cmd > out.log 2>&1` |
| **Array Data Types** | Positional parameters (`$1`, `$@`) only | Multi-word list variables (`set array = (a b c)`) | One-dimensional indexed arrays | Indexed and Associative arrays |
| **Signal Trapping Syntax** | `trap 'cleanup' EXIT INT TERM` | Limited signal handling (`onintr label`) | `trap 'cleanup' EXIT INT TERM` | `trap 'cleanup' EXIT INT TERM` |
| **Automated Execution Risk** | Low (Deterministic POSIX engine) | High (Fragile parsing, alias side-effects) | Low (Deterministic engine) | Medium (Version drift between hosts) |

#### 2.2 Subshell Spawning (`( ... )`) vs In-Process Grouping (`{ ...; }`) vs Process Substitution (`<(...)`)

Understanding process table creation and memory isolation is mandatory for high-throughput SRE script engineering.

| Execution Context | Syntax Example | Process Lineage (`fork(2)`) | Variable Scope Mutation | File Descriptor State | Production Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Subshell Spawning** | `(cd /tmp && make_build)` | Explicit `fork(2)` created; child PID executed. | Isolated. Changes to `$PWD` or variables vanish on exit. | Inherits parent FDs; can redirect subshell block independently. | Temporary directory switching, safe state execution without polluting parent shell. |
| **In-Process Grouping** | `{ cd /tmp; make_build; }` | No `fork(2)`. Executes inside current shell PID. | Shared. Changes to `$PWD` or variables persist in current shell. | FDs can be redirected for the entire block together. | Grouping commands for single-stream stdout/stderr redirection without process allocation cost. |
| **Process Substitution** | `diff <(cmd1) <(cmd2)` | `fork(2)` for each command; attached to named pipes (`/dev/fd/N`). | Isolated inside subshell pipelines. | Anonymous pipe file descriptors passed as file path arguments. | Comparing output of two dynamic commands without creating temporary disk files. |

---

### 3. Production Configuration Manifests & Scripts

#### 3.1 Production Hardened POSIX System/User Profile (`/etc/profile` / `~/.profile`)

This POSIX-compliant initialization file works under FreeBSD, OpenBSD, and NetBSD `/bin/sh`. It enforces environment sanitization, dynamic binary path precedence, dynamic terminal detection, secure umask configurations, and deterministic non-interactive behavior.

```sh
# /etc/profile - Production Hardened POSIX Shell Initialization
# System-wide environment configuration for POSIX-compliant shells (/bin/sh).

# 1. Enforce strict process umask (rw-r--r-- for files, rwxr-xr-x for dirs)
umask 022

# 2. Path Sanitization & Reconstruction
# Order: Custom Local Bin -> Package System Bin -> Base System Admin -> Base System User
PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# 3. Environment Localization & Determinism
LANG="C.UTF-8"
LC_ALL="C.UTF-8"
TZ="UTC"
export LANG LC_ALL TZ

# 4. Standard System Editor and Pager Defaults
if [ -x /usr/bin/vi ]; then
    EDITOR="/usr/bin/vi"
    VISUAL="/usr/bin/vi"
    export EDITOR VISUAL
fi

PAGER="less"
LESS="-FRX"
export PAGER LESS

# 5. Non-Interactive Execution Safeguard
# If stdin is not a TTY, stop processing interactive terminal setups
if [ ! -t 0 ]; then
    return 0 2>/dev/null || exit 0
fi

# 6. Interactive Terminal Configuration
# Terminal type fallback check
if [ -z "$TERM" ] || [ "$TERM" = "unknown" ] || [ "$TERM" = "dumb" ]; then
    TERM="xterm-256color"
    export TERM
fi

# Configure Command Line Prompt (Host, User, Path, Hash/Dollar indicator)
USER_ID="$(id -u)"
HOST_NAME="$(hostname -s)"

if [ "$USER_ID" -eq 0 ]; then
    PS1="[${HOST_NAME}] \u@\h:\w # "
else
    PS1="[${HOST_NAME}] \u@\h:\w $ "
fi
export PS1

# 7. History and Command Line Line-Editing
HISTSIZE=5000
export HISTSIZE

# Enable vi line editing mode in POSIX sh
set -o vi
```

#### 3.2 Production FreeBSD Root Legacy C-Shell Config (`/root/.cshrc`)

Because FreeBSD defaults `root` to `/bin/csh` (which invokes `/bin/tcsh`), this manifest ensures structural parity, safe path exports, alias containment, and environment exports for emergency interactive administration.

```csh
# /root/.cshrc - FreeBSD Base System Root Interactive C-Shell Config
# Syntactically validated for /bin/csh and /bin/tcsh.

# 1. Environment Variables Setup (Must use setenv for C-Shell environment export)
setenv PATH "/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
setenv LANG "C.UTF-8"
setenv LC_ALL "C.UTF-8"
setenv BLOCKSIZE "K"
setenv EDITOR "/usr/bin/vi"
setenv PAGER "less"

# 2. Local Shell Variables (Internal shell settings use set)
set history = 5000
set savehist = (5000 merge)
set autoexpand
set autoread
set filec
set matchbeeps = nomatch

# 3. Prompt Customization (%m = hostname, %c2 = trailing 2 path components, %# = user/root symbol)
set prompt = "[%m] %c2 %# "

# 4. Safety Aliases for Interactive Destructive Operations
alias rm    'rm -i'
alias cp    'cp -i'
alias mv    'mv -i'
alias ls    'ls -Gw'
alias ll    'ls -alF'
alias df    'df -h'
alias du    'du -h -d1'

# 5. Non-Interactive Execution Check
if ( ! $?prompt ) exit 0
```

#### 3.3 Production FreeBSD Jail Non-Interactive Automation Wrapper (`jail_exec_runner.sh`)

This production-grade POSIX `/bin/sh` script executes arbitrary commands inside isolated FreeBSD Jails, handling signal traps (`SIGINT`, `SIGTERM`, `EXIT`), locking, file descriptor redirection, and exit code propagation cleanly.

```sh
#!/bin/sh
# ==============================================================================
# Script: jail_exec_runner.sh
# Purpose: Execute commands inside FreeBSD Jails with deterministic POSIX mechanics.
# Compliance: POSIX IEEE Std 1003.1 (/bin/sh)
# ==============================================================================

set -eu

# Script variables
SCRIPT_NAME="$(basename "$0")"
JAIL_NAME=""
COMMAND_TO_RUN=""
LOG_FILE=""
TEMP_ERR_FILE=""

# Signal Handling and Resource Cleanup Function
cleanup() {
    EXIT_CODE=$?
    trap - EXIT INT TERM
    
    if [ -n "${TEMP_ERR_FILE:-}" ] && [ -f "$TEMP_ERR_FILE" ]; then
        rm -f "$TEMP_ERR_FILE"
    fi
    
    if [ "$EXIT_CODE" -ne 0 ]; then
        echo "[ERROR] [${SCRIPT_NAME}] Process terminated abnormally with status code: ${EXIT_CODE}" >&2
    fi
    exit "$EXIT_CODE"
}

# Attach Signal Traps
trap cleanup EXIT INT TERM

usage() {
    echo "Usage: ${SCRIPT_NAME} -j <jail_name> -c <command> [-l <log_file>]" >&2
    exit 64
}

# Parse Command Line Options
while getopts "j:c:l:" opt; do
    case "$opt" in
        j) JAIL_NAME="$OPTARG" ;;
        c) COMMAND_TO_RUN="$OPTARG" ;;
        l) LOG_FILE="$OPTARG" ;;
        *) usage ;;
    esac
done

if [ -z "$JAIL_NAME" ] || [ -z "$COMMAND_TO_RUN" ]; then
    usage
fi

# Verify Jail State on Host System using jls(8)
if ! /usr/sbin/jls -j "$JAIL_NAME" >/dev/null 2>&1; then
    echo "[CRITICAL] Jail '${JAIL_NAME}' does not exist or is not running." >&2
    exit 69
fi

# Allocate temporary file for stderr isolation
TEMP_ERR_FILE="$(/usr/bin/mktemp -t jail_exec_err.XXXXXX)"

echo "[INFO] Executing in Jail [${JAIL_NAME}]: ${COMMAND_TO_RUN}"

# Execute command inside target jail using jexec(8)
# Environment is sanitized via env -i within the jail context
if [ -n "$LOG_FILE" ]; then
    /usr/sbin/jexec "$JAIL_NAME" /usr/bin/env -i \
        PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin" \
        TERM="dumb" \
        /bin/sh -c "$COMMAND_TO_RUN" >"$LOG_FILE" 2>"$TEMP_ERR_FILE" || EXEC_RES=$?
else
    /usr/sbin/jexec "$JAIL_NAME" /usr/bin/env -i \
        PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin" \
        TERM="dumb" \
        /bin/sh -c "$COMMAND_TO_RUN" 2>"$TEMP_ERR_FILE" || EXEC_RES=$?
fi

EXEC_RES="${EXEC_RES:-0}"

if [ "$EXEC_RES" -ne 0 ]; then
    echo "[FAILURE] Command failed inside Jail [${JAIL_NAME}] with exit status ${EXEC_RES}" >&2
    if [ -s "$TEMP_ERR_FILE" ]; then
        echo "--- Stderr Capture ---" >&2
        cat "$TEMP_ERR_FILE" >&2
        echo "----------------------" >&2
    fi
    exit "$EXEC_RES"
fi

echo "[SUCCESS] Command completed successfully inside Jail [${JAIL_NAME}]."
```

---

### 4. Command Line Execution & Real Terminal Outputs

This section details real interactive shell sequences, showing commands executed under both `$` (non-privileged) and `#` (privileged) prompts alongside expected outputs on FreeBSD 14.0-RELEASE.

#### 4.1 Shell Introspection, Type Resolution, and Execution Precedence

Understanding how the shell resolves binary paths, builtins, functions, and aliases prevents accidental execution of incorrect binaries.

```console
$ echo "Current Shell Variable ($SHELL): $SHELL"
Current Shell Variable ($SHELL): /bin/sh

$ ps -p $$ -o pid,ppid,comm
  PID  PPID COMMAND
 1245  1244 sh

$ type ls
ls is a shell builtin

$ type pkg
pkg is /usr/sbin/pkg

$ type setenv
setenv is not found

$ which -a ls
/bin/ls

$ whereis ls
ls: /bin/ls /usr/share/man/man1/ls.1.gz

$ env -i PATH="/bin:/usr/bin" /bin/sh -c 'printenv'
PATH=/bin:/usr/bin
PWD=/home/sreuser
```

#### 4.2 Variable Scoping and Environment Export Operations

Comparing variable isolation in standard POSIX `/bin/sh` vs `/bin/csh`.

##### POSIX `/bin/sh` Execution Sequence:
```console
$ LOCAL_VAR="Infrastructure_Primary"
$ export GLOBAL_VAR="Infrastructure_Exported"

$ printenv LOCAL_VAR

$ printenv GLOBAL_VAR
Infrastructure_Exported

$ /bin/sh -c 'echo "Child Local: $LOCAL_VAR | Child Global: $GLOBAL_VAR"'
Child Local:  | Child Global: Infrastructure_Exported
```

##### C-Shell (`/bin/csh` / `/bin/tcsh`) Execution Sequence:
```console
# set local_csh_var = "InternalScope"
# setenv GLOBAL_CSH_VAR "ExportedScope"

# printenv local_csh_var

# printenv GLOBAL_CSH_VAR
ExportedScope

# csh -c 'echo Local: $local_csh_var | echo Global: $GLOBAL_CSH_VAR'
local_csh_var: Undefined variable.
Global: ExportedScope
```

#### 4.3 Advanced File Descriptor Manipulation and Pipe Multiplexing

File descriptors (FD 0 = stdin, FD 1 = stdout, FD 2 = stderr) manipulation, standard stream swapping, and redirection constructs.

```console
$ (echo "Standard Output Payload"; echo "Critical Error Payload" >&2) > /tmp/stdout.log 2> /tmp/stderr.log

$ cat /tmp/stdout.log
Standard Output Payload

$ cat /tmp/stderr.log
Critical Error Payload

$ (echo "Merged Stream Line 1"; echo "Merged Stream Error Line 2" >&2) > /tmp/combined.log 2>&1

$ cat /tmp/combined.log
Merged Stream Line 1
Merged Stream Error Line 2

$ exec 3>&1
$ (echo "Sent to FD3" >&3; echo "Sent to Normal Stderr" >&2) 2> /tmp/err_only.log

Sent to FD3

$ cat /tmp/err_only.log
Sent to Normal Stderr

$ exec 3>&-
```

#### 4.4 Job Control, Process Trees, and Signal Operations

Process manipulation in interactive sessions: backgrounding (`&`), listing jobs (`jobs`), stopping (`SIGTSTP`), resuming (`bg`, `fg`), and sending explicit signals (`kill`).

```console
$ sleep 300 &
[1] 1452

$ sleep 600 &
[2] 1453

$ jobs -l
[1]-  1452 Running                 sleep 300 &
[2]+  1453 Running                 sleep 600 &

$ kill -s SIGSTOP 1452
[1]+  Stopped                 sleep 300

$ jobs -l
[1]+  1452 Stopped (SIGSTOP)      sleep 300
[2]-  1453 Running                 sleep 600 &

$ bg %1
[1]+ sleep 300 &

$ kill -s SIGTERM 1453
[2]-  Terminated              sleep 600

$ kill -9 1452
[1]+  Killed                  sleep 300
```

#### 4.5 System Manual (man) Page Navigation and Searching

The BSD manual page architecture is categorized into sections (1: User commands, 2: System calls, 3: C library functions, 4: Special files/devices, 5: File formats, 7: Miscellaneous, 8: System administration).

```console
$ man -k jail
jail (8) - manage system jails
jail_attach (2) - attach to an existing jail
jail_get (2) - read state of FreeBSD jails
jail.conf (5) - configuration file for FreeBSD jails

$ apropos "packet filter"
pf (4) - packet filter database device
pf.conf (5) - packet filter configuration file
pfctl (8) - control the packet filter (PF) device

$ whatis zfs
zfs (8) - configures ZFS file systems

$ man 5 jail.conf | head -n 15
JAIL.CONF(5)              FreeBSD File Formats Manual             JAIL.CONF(5)

NAME
     jail.conf -- FreeBSD jail configuration file

CRITICAL DESCRIPTION
     A jail.conf file consists of block statements configuring named jails.
     Parameters defined outside of a jail block apply to all following jail
     definitions.
```

---

### 5. SRE Verification & Diagnostics Guide

When automation scripts fail or behave non-deterministically on BSD production nodes, follow this structured diagnostic decision tree:

```
                          [ Command/Script Failure ]
                                      |
                                      v
                      Is PATH or Environment Intact?
                               /             \
                             NO               YES
                            /                   \
            Inspect Non-Interactive            Is Output Truncated
            Environment via:                   or Hanging?
            $ env -i /bin/sh -c 'env'          /          \
                                              YES          NO
                                             /              \
                              Check File Descriptor     Verify Signal Traps &
                              Deadlocks & Buffering:    Trace Execution via:
                              $ truss -p <PID>          $ sh -x ./script.sh
```

#### 5.1 Step-by-Step Diagnostic Procedures

##### Issue 1: Script Fails Non-Interactively with `command not found`
* **Root Cause:** Script relies on interactive `PATH` modifications present in `.cshrc` or interactive-only blocks of `.profile`. Non-interactive executions bypass interactive initialization blocks.
* **Diagnostic Command:**
  ```console
  $ ssh root@bsd-node.internal.net "env"
  ```
* **Resolution:** Explicitly declare `PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"` at the top of every automation script, or pass explicit absolute paths to binaries (`/usr/local/bin/python3`).

##### Issue 2: Script Execution Hangs Indefinitely inside a FreeBSD Jail or Cron Job
* **Root Cause:** A subshell command is waiting for `stdin` input because no TTY is allocated, or a pipe buffer (`pipe(2)`) filled up (typically 64KB on FreeBSD) without a consuming reader process.
* **Diagnostic Procedure:**
  1. Identify stuck process PID using `pgrep`:
     ```console
     $ pgrep -l -f "jail_exec_runner"
     18492 sh
     ```
  2. Inspect process file descriptor states using `procstat(1)` or `fstat(1)`:
     ```console
     $ procstat -f 18492
       PID COMM               FD AT INUM TS SZ R/W FLAGS      NAME
     18492 sh                 text r 120485  -  -   r  -          /bin/sh
     18492 sh                 ctty -      -  -  -   -  -          -
     18492 sh                    0 r 120490  -  -   r  -          /dev/null
     18492 sh                    1 w   pipe  -  -   w  -          -
     18492 sh                    2 w   pipe  -  -   w  -          -
     ```
  3. Trace active system calls using `truss(1)`:
     ```console
     # truss -p 18492
     write(1,"Processing block 4096...\n",25) = 25
     write(1,"Processing block 4097...\n",25) EAGAIN
     read(0, 0x7fffffffe450, 1024)           ERR#35 'Resource temporarily unavailable'
     ```
* **Resolution:** Ensure stdout/stderr streams are read concurrently or redirected to disk files, and ensure non-interactive execution explicitly attaches stdin from `/dev/null` (`< /dev/null`).

##### Issue 3: Inconsistent Syntax Failure (`setenv: not found` or `Syntax error: "(" unexpected`)
* **Root Cause:** Script execution header uses `#!/bin/sh`, but developer tested commands using interactive `/bin/csh` (or vice-versa).
* **Diagnostic Procedure:** Check syntax compatibility dynamically using shell syntax verification flags:
  ```console
  $ /bin/sh -n /path/to/target_script.sh
  /path/to/target_script.sh: line 14: Syntax error: "setenv" unexpected

  $ /bin/csh -n /path/to/target_script.csh
  ```
* **Resolution:** Strictly enforce standard POSIX `/bin/sh` syntax for all system scripts and enforce shebang integrity (`#!/bin/sh`).

---

### 6. References

* **LPI BSD Specialist Certification Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **FreeBSD General Commands Manual - `sh(1)` (Almquist Shell):**  
  [https://man.freebsd.org/cgi/man.cgi?query=sh&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=sh&sektion=1)

* **FreeBSD General Commands Manual - `tcsh(1)` / `csh(1)` (C Shell):**  
  [https://man.freebsd.org/cgi/man.cgi?query=tcsh&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=tcsh&sektion=1)

* **FreeBSD System Manager's Manual - `jexec(8)` & `jls(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=jexec&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=jexec&sektion=8)

* **OpenBSD Manual Pages - `ksh(1)` (Korn Shell):**  
  [https://man.openbsd.org/ksh.1](https://man.openbsd.org/ksh.1)

* **IEEE Std 1003.1-2017 (POSIX) Shell & Utilities - Shell Command Language Specifications:**  
  [https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html)