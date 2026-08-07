# LPI BSD Specialist (Exam 702-100) | Topic 715.6: Customize or Write Simple Scripts

## Executive Summary & Architectural Overview

In BSD operating systems (FreeBSD, OpenBSD, NetBSD), shell scripting serves as the foundational automation glue for system initialization (`rc.d` sub-routines), package management hooks (`pkg` scripts), cron execution, and SRE administration tasks. 

Understanding **Topic 715.6: Customize or write simple scripts** requires a precise understanding of shell execution mechanics, kernel-level shebang interpretation, parameter expansion rules, signal handling, and the trade-offs between interactive shells (`csh`/`tcsh`) and system scripting shells (`/bin/sh`).

```
+-------------------------------------------------------------------------------+
|                             Kernel space (execve)                             |
+-------------------------------------------------------------------------------+
                                      | Reads magic bytes: #! /bin/sh
                                      v
+-------------------------------------------------------------------------------+
| /bin/sh Interpreter (Almquist / Korn derivative)                              |
| - Fast startup, minimal memory footprint                                      |
| - POSIX IEEE 1003.2 strict compliance                                          |
| - Standard for system initialization & rc.d sub-routines                      |
+-------------------------------------------------------------------------------+
       |                                      |                               
       v (Positional Parameters)              v (Special Parameters)          
  $1, $2, $@, $*                         $?, $$, $!, $#, $-                   
```

### 1. Kernel Shebang Mechanics (`execve(2)`)
When a script is executed via `./script.sh` or through `execve(2)`:
1. The kernel inspects the first two bytes of the file. If they match the magic number `0x23 0x21` (`#!`), the kernel parses the remainder of the line as an interpreter directive.
2. The kernel invokes the binary path specified after `#!` (e.g., `/bin/sh`) and passes the script file path as an argument to that interpreter.
3. If the execute permission bit (`+x`) is not set on the script file, `execve(2)` fails with `EACCES` (Permission Denied) before the interpreter can be launched.

### 2. Shell Architecture & Trade-Offs: `/bin/sh` vs. `csh`/`tcsh` vs. `bash`

| Feature | BSD POSIX Shell (`/bin/sh`) | C Shell (`csh` / `tcsh`) | GNU Bourne-Again Shell (`bash`) |
| :--- | :--- | :--- | :--- |
| **Primary Use Case** | Base system scripts, `rc.d` services, cron tasks. | Interactive root user shell (historical default). | Interactive user shell (installed via ports/packages). |
| **Portability** | High (POSIX standard across BSD & Linux). | Low (Non-standard control syntax, unique bugs). | Medium (Requires third-party dependency package). |
| **Resource Footprint** | Extremely lightweight (~hundreds of KB). | Moderate (~1 MB). | Heavy (~2-5 MB + external libraries). |
| **Control Flow Syntax** | `if ... then ... fi`, `case ... esac` | `if (...) then ... endif` | POSIX extensions (`[[ ]]`, arrays, etc.) |
| **Redirection Engine** | Clean stdin/stdout/stderr file descriptor control. | Clunky redirection (e.g., missing simple stderr pipes). | Advanced file descriptor redirections. |

> [!IMPORTANT]
> **Production Standard**: System scripts in BSD environments **must** target `/bin/sh`. Relying on `/usr/local/bin/bash` creates an unnecessary dependency on third-party ports (`/usr/local`), which can break during base-system disaster recovery or single-user emergency repair modes.

---

## Guided Exercises

### Exercise 1: Shebang Execution Mechanics, File Permissions, and Shell Selection Trade-offs

#### Objective
Understand how the BSD kernel parses script magic bytes (`#!`), enforce file system execution bits, observe the differences between running scripts under `/bin/sh` versus `/bin/csh`, and verify `noexec` mount flag limitations.

#### Step 1: Create a basic POSIX `/bin/sh` system script
Execute the following command to generate a base system diagnostic script in `/tmp/sys_info.sh`:

```bash
cat << 'EOF' > /tmp/sys_info.sh
#!/bin/sh
# System Diagnostic Script for BSD Specialist 702-100

OS_NAME=$(uname -s)
OS_REL=$(uname -r)

echo "Operating System: ${OS_NAME}"
echo "Kernel Release:   ${OS_REL}"
EOF
```

#### Step 2: Test execution permissions and inspect file attributes
Run `ls -l` and attempt direct execution before setting execute bits:

```bash
ls -l /tmp/sys_info.sh
/tmp/sys_info.sh
```

**Expected Output:**
```text
-rw-r--r--  1 root  wheel  165 Aug  7 04:10 /tmp/sys_info.sh
-sh: /tmp/sys_info.sh: Permission denied
```

#### Step 3: Grant execute permissions and verify binary magic bytes
Use `chmod` to add execution privileges, inspect the file type with `file(1)`, and execute the script:

```bash
chmod 755 /tmp/sys_info.sh
file /tmp/sys_info.sh
/tmp/sys_info.sh
```

**Expected Output:**
```text
/tmp/sys_info.sh: POSIX shell script text executable
Operating System: FreeBSD
Kernel Release:   14.0-RELEASE
```

#### Step 4: Compare `/bin/sh` syntax failure under `csh`
Attempt to execute the POSIX shell script explicitly using `/bin/csh` to observe syntax incompatibility:

```bash
/bin/csh /tmp/sys_info.sh
```

**Expected Output:**
```text
OS_NAME=FreeBSD: Command not found.
OS_REL=14.0-RELEASE: Command not found.
OS_NAME: Undefined variable.
```

---

#### Verification Questions (Block 1)

1. **Why did `/bin/csh` fail to execute `/tmp/sys_info.sh` even though the shebang line `#!/bin/sh` was specified at line 1?**
   - A) The shebang line was ignored because `chmod 755` was not run prior to `csh` execution.
   - B) Passing a script file as a direct argument to an interpreter command (e.g., `/bin/csh script.sh`) bypasses kernel `execve(2)` shebang evaluation and forces the specified binary (`csh`) to parse the file directly.
   - C) `csh` automatically converts POSIX syntax unless the script file extension is `.posix`.
   - D) BSD kernels only parse shebangs if the script resides inside `/usr/bin`.

2. **If `/tmp` is mounted with the `noexec` option in `/etc/fstab`, what happens when a user executes `/tmp/sys_info.sh` directly versus running `sh /tmp/sys_info.sh`?**
   - A) Both commands fail with `Permission denied`.
   - B) Direct execution (`/tmp/sys_info.sh`) fails at the kernel level with `Permission denied`, but `sh /tmp/sys_info.sh` succeeds because `/bin/sh` (located on an executable partition) reads `/tmp/sys_info.sh` as a standard data file.
   - C) Both commands succeed because `root` bypasses `noexec` file system flags.
   - D) Direct execution succeeds, but `sh /tmp/sys_info.sh` fails due to binary integrity checks.

---

### Exercise 2: Positional Parameters, Special Parameters, and Argument Parsing Mechanics

#### Objective
Master the handling of positional parameters (`$1`, `$2`, `$@`, `$*`), parameter shifting (`shift`), count tracking (`$#`), process identification (`$$`), subshell background tracking (`$!`), and exit statuses (`$?`).

#### Step 1: Create a production parameter auditor script
Write the following script to `/tmp/param_auditor.sh`:

```bash
cat << 'EOF' > /tmp/param_auditor.sh
#!/bin/sh
# Audit and process incoming positional parameters

echo "Script Name (\$0):         $0"
echo "Total Parameters (\$#):    $#"
echo "Process ID (\$process):     $$"

echo "\n--- Processing Parameters with \$@ ---"
count=1
for param in "$@"; do
    echo "Param ${count}: ${param}"
    count=$((count + 1))
done

echo "\n--- Demonstrating \$* vs \$@ Difference ---"
echo "Quoted \$*: '$*'"
echo "Quoted \$@: '$@'"

echo "\n--- Shift Operation ---"
if [ $# -ge 2 ]; then
    echo "First parameter before shift: $1"
    shift
    echo "First parameter after shift:  $1"
    echo "Remaining parameters (\$#):    $#"
fi

# Launch background task to demonstrate $!
sleep 2 &
BG_PID=$!
echo "\nBackground process launched with PID (\$!): ${BG_PID}"

wait ${BG_PID}
echo "Background Process Exit Status (\$?): $?"
EOF

chmod +x /tmp/param_auditor.sh
```

#### Step 2: Execute the script with diverse arguments
Run the parameter auditor script passing multiple arguments, including quoted strings containing spaces:

```bash
/tmp/param_auditor.sh "adm service" pkg-update --force
```

**Expected Output:**
```text
Script Name ($0):         /tmp/param_auditor.sh
Total Parameters ($#):    3
Process ID ($process):     48192

--- Processing Parameters with $@ ---
Param 1: adm service
Param 2: pkg-update
Param 3: --force

--- Demonstrating $* vs $@ Difference ---
Quoted $*: 'adm service pkg-update --force'
Quoted $@: 'adm service pkg-update --force'

--- Shift Operation ---
First parameter before shift: adm service
First parameter after shift:  pkg-update
Remaining parameters ($#):    2

Background process launched with PID ($!): 48195
Background Process Exit Status ($?): 0
```

---

#### Verification Questions (Block 2)

3. **What is the critical difference between `"$@"` and `"$*"` when iterating over script positional parameters containing spaces (e.g., `"adm service" "pkg-update"`)?**
   - A) `"$@"` expands to separate words (`"adm service"` `"pkg-update"`), preserving original parameter boundaries, whereas `"$*"` concatenates all parameters into a single string separated by the first character of `IFS` (`"adm service pkg-update"`).
   - B) `"$*"` preserves parameter boundaries, while `"$@"` splits strings on spaces.
   - C) `"$@"` only includes numeric arguments, while `"$*"` includes alphanumeric arguments.
   - D) There is no functional difference in BSD POSIX `/bin/sh`.

4. **In a BSD production maintenance script, what is the value of `$?` immediately after a command fails, and how can an architect ensure the script halts execution on any unhandled error?**
   - A) `$?` contains `0`; run `set -u` to halt on errors.
   - B) `$?` contains a non-zero integer (1-255) representing the command's exit code; include `set -e` at the script header to instruct `/bin/sh` to exit immediately if any simple command returns a non-zero exit status.
   - C) `$?` contains the PID of the failed process; use `trap 'exit'` to stop execution.
   - D) `$?` contains string `"ERROR"`; use `set -o pipefail` only.

---

### Exercise 3: Advanced Control Flow, Signal Handling, and Production Script Diagnostics

#### Objective
Implement clean signal handling (`trap`), standard error redirection (`>&2`), strict error checking (`set -eu`), robust conditional validation using `test`/`[ ]`, syntax checking (`sh -n`), and execution tracing (`sh -x`).

#### Step 1: Create a resilient system cleanup script
Write a production script to `/tmp/bsd_cleaner.sh` that cleans temporary log files, traps termination signals, handles invalid inputs gracefully, and directs errors to standard error:

```bash
cat << 'EOF' > /tmp/bsd_cleaner.sh
#!/bin/sh
# Robust BSD Temp Log Cleaner
set -eu

LOCKFILE="/tmp/bsd_cleaner.lock"

# Cleanup function invoked on signals or exit
cleanup() {
    exit_code=$?
    echo "[DEBUG] Running cleanup trap (Exit Code: ${exit_code})..."
    rm -f "${LOCKFILE}"
}

# Trap signals INT (Ctrl+C), TERM (kill), and EXIT
trap cleanup INT TERM EXIT

# Ensure single instance execution
if [ -e "${LOCKFILE}" ]; then
    echo "ERROR: Lockfile ${LOCKFILE} exists. Script already running." >&2
    exit 1
fi
touch "${LOCKFILE}"

# Validate parameter input
TARGET_DIR="${1:-}"

if [ -z "${TARGET_DIR}" ]; then
    echo "Usage: $0 <target_directory>" >&2
    exit 2
fi

if [ ! -d "${TARGET_DIR}" ]; then
    echo "ERROR: Target directory '${TARGET_DIR}' does not exist." >&2
    exit 3
fi

echo "Cleaning stale files in ${TARGET_DIR}..."
# Perform safe listing instead of aggressive deletion for demonstration
find "${TARGET_DIR}" -name "*.tmp" -type f -mtime +7 -exec echo "Would remove: {}" \;

echo "Operation completed successfully."
EOF

chmod 755 /tmp/bsd_cleaner.sh
```

#### Step 2: Validate syntax without executing the script
Run `/bin/sh` with the `-n` (no-exec / syntax check) flag to verify script syntax validity:

```bash
/bin/sh -n /tmp/bsd_cleaner.sh
echo "Syntax check return code: $?"
```

**Expected Output:**
```text
Syntax check return code: 0
```

#### Step 3: Test parameter validation and standard error redirection
Execute the script without parameters and redirect stdout to `/dev/null` while keeping stderr visible:

```bash
/tmp/bsd_cleaner.sh > /dev/null
echo "Exit status: $?"
```

**Expected Output:**
```text
Usage: /tmp/bsd_cleaner.sh <target_directory>
[DEBUG] Running cleanup trap (Exit Code: 2)...
Exit status: 2
```

#### Step 4: Execute step-by-step tracing with `sh -x`
Run the script against a valid target directory (`/tmp`) with execution tracing enabled (`-x` flag):

```bash
/bin/sh -x /tmp/bsd_cleaner.sh /tmp
```

**Expected Output:**
```text
+ set -eu
+ LOCKFILE=/tmp/bsd_cleaner.lock
+ trap cleanup INT TERM EXIT
+ [ -e /tmp/bsd_cleaner.lock ]
+ touch /tmp/bsd_cleaner.lock
+ TARGET_DIR=/tmp
+ [ -z /tmp ]
+ [ ! -d /tmp ]
+ echo Cleaning stale files in /tmp...
Cleaning stale files in /tmp...
+ find /tmp -name *.tmp -type f -mtime +7 -exec echo Would remove: {} ;
+ echo Operation completed successfully.
Operation completed successfully.
+ cleanup
+ exit_code=0
+ echo [DEBUG] Running cleanup trap (Exit Code: 0)...
[DEBUG] Running cleanup trap (Exit Code: 0)...
+ rm -f /tmp/bsd_cleaner.lock
```

---

#### Verification Questions (Block 3)

5. **In Exercise 3, why was `echo "Usage: ..." >&2` used instead of standard `echo "Usage: ..."`?**
   - A) `>&2` redirects stdout to stderr, ensuring diagnostic and error messages are separated from standard output data, allowing pipeline callers to process valid output without log corruption.
   - B) `>&2` forces the message to write to system log facility (`/var/log/messages`).
   - C) `>&2` escalates process execution privileges to root.
   - D) `>&2` appends text to descriptor 2 without adding a trailing newline.

6. **What is the effect of setting `set -eu` at the beginning of a BSD `/bin/sh` script?**
   - A) `-e` instructs the shell to exit immediately if any command returns a non-zero exit status; `-u` treats unset variables as an error and exits immediately during expansion.
   - B) `-e` enables execution tracing; `-u` disables user signal handlers.
   - C) `-e` executes all commands in background subshells; `-u` elevates execution priority.
   - D) `-e` prevents variable overriding; `-u` forces unicode character processing.

---

## Solutions & Diagnostic Explanations

<details>
<summary>Click to view Comprehension Answers and Detailed Explanations</summary>

### Question 1
**Correct Answer:** **B**
* **Technical Rationale:** When you run `/bin/csh /tmp/sys_info.sh`, the system launches the `csh` executable directly and passes `/tmp/sys_info.sh` as an argument. The kernel's `execve(2)` system call is **not** responsible for reading the shebang line in this scenario because the binary being executed is `/bin/csh`. `csh` reads the commands inside `/tmp/sys_info.sh` line by line. Because `csh` uses a syntax inspired by C (`set variable = value`) rather than Bourne POSIX syntax (`VARIABLE=value`), variable assignments like `OS_NAME=$(uname -s)` result in syntax errors (`Command not found`). Shebang evaluation (`#!/bin/sh`) occurs **only** when the file is executed directly (e.g., `./sys_info.sh`), triggering the kernel's `execve(2)` image activator.

### Question 2
**Correct Answer:** **B**
* **Technical Rationale:** The `noexec` mount option prevents the kernel from executing binaries or scripts directly via `execve(2)`. Direct execution (`/tmp/sys_info.sh`) causes `execve(2)` to return `EACCES` (`Permission denied`). However, running `sh /tmp/sys_info.sh` executes the shell binary `/bin/sh` (which resides on `/bin`, an executable file system). `/bin/sh` opens `/tmp/sys_info.sh` using `open(2)` as a plain text data file, reads its contents, and evaluates the commands.

### Question 3
**Correct Answer:** **A**
* **Technical Rationale:** Under POSIX `/bin/sh`:
  - `"$@"` expands to separate double-quoted strings: `"$1"` `"$2"` `"$3"` ... preserving argument boundaries containing spaces.
  - `"$*"` expands to a single double-quoted string: `"$1c$2c$3"` (where `c` is the first character of the `IFS` variable, defaulting to space).
  If parameters are `"adm service"` and `"pkg-update"`, `"$@"` yields 2 arguments (`"adm service"`, `"pkg-update"`), while `"$*"` yields 1 concatenated argument (`"adm service pkg-update"`).

### Question 4
**Correct Answer:** **B**
* **Technical Rationale:** In Unix shells, `$?` stores the exit status of the most recently executed foreground command. An exit status of `0` signals success, while any non-zero value (`1-255`) denotes failure or an error state. Including `set -e` (or `set -o errexit`) ensures that `/bin/sh` immediately terminates if a simple command fails, avoiding cascading failure states in production systems.

### Question 5
**Correct Answer:** **A**
* **Technical Rationale:** File descriptor `1` represents standard output (`stdout`), and file descriptor `2` represents standard error (`stderr`). In production environments, scripts are often piped into downstream utilities (e.g., `script.sh | grep data`). By redirecting error and usage strings to stderr via `>&2`, error messages remain visible on the user's terminal/logs without polluting stdout data streams.

### Question 6
**Correct Answer:** **A**
* **Technical Rationale:** Combining `set -e` (`errexit`) and `set -u` (`nounset`) forms the baseline of defensive POSIX shell programming:
  - `-e`: Terminates script execution immediately if any command returns a non-zero exit status (unless part of a conditional test like `if` or `||`).
  - `-u`: Triggers an error and aborts execution if an uninitialized or unbound variable is referenced (preventing catastrophic bugs like `rm -rf /${UNSET_VAR}`).

</details>

---

## Official Reference Documentation & Specifications

1. **Linux Professional Institute BSD Specialist Certification Overview**
   - URL: https://www.lpi.org/our-certifications/bsd-specialist-overview/
2. **FreeBSD Manual Pages: `sh(1)` — Built-in Command and Script Interpreter**
   - URL: https://man.freebsd.org/cgi/man.cgi?query=sh&sektion=1
3. **OpenBSD Manual Pages: `csh(1)` — C Shell Interpreter**
   - URL: https://man.openbsd.org/csh.1
4. **IEEE Std 1003.1 POSIX Shell Specification (`Shell & Utilities`)**
   - URL: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html