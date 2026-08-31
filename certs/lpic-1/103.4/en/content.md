# 103.4 — Use Streams, Pipes and Redirects

**Certification:** LPIC-1 (Exams 101-500 / 102-500, version 5.0)
**Topic:** 103.4 — Use streams, pipes and redirects
**Exam weight:** 6.25
**Level:** Advanced — SRE / Platform Architect profile

**Key knowledge areas covered by the objective:** redirecting standard input, standard output and standard error; piping the output of one command to the input of another; using the output of one command as arguments to another command; sending output simultaneously to stdout and a file.

**Terms and utilities:** `tee`, `xargs`, and the shell operators `<`, `>`, `>>`, `|`, `2>`, `2>&1`, `&>`, `<<`, `<<<`, `<()`, `>()`.

---

## 1. Motivation and the Production Architectural Problem

### 1.1 Why a 1970s abstraction is still the load-bearing wall of your platform

The Unix stream model states that a process has no idea *what* it is talking to. It writes bytes to a small integer. Whether that integer resolves to a terminal, a regular file on XFS, a pipe to `gzip`, a UNIX socket consumed by `journald`, or a `null` device is decided **by the caller, after the program was compiled**. This late binding is the reason a container image built in 2019 can be observed by a log pipeline designed in 2026 without recompilation.

Every modern platform contract you operate depends on it:

| Platform contract | What it actually requires of the process | Failure mode when violated |
|---|---|---|
| **Twelve-Factor App XI (Logs)** | Write an unbuffered event stream to `stdout`; never manage files or rotation | App writes to `/var/log/app.log` inside an ephemeral container → logs die with the pod |
| **Docker `json-file` / `local` log drivers** | Runtime attaches a pipe to fd 1 and fd 2 of PID 1 in the container | App daemonizes and closes fds → `docker logs` is empty forever |
| **Kubernetes `kubectl logs`** | kubelet reads CRI-formatted files fed from the container's stdout/stderr pipes | App forks a child that inherits nothing → partial or missing logs |
| **systemd `StandardOutput=journal`** | Unit's fd 1 and fd 2 are `AF_UNIX` sockets to `systemd-journald` | Unit uses `ExecStart=/bin/sh -c 'app > /var/log/app.log'` → journal has nothing, `journalctl -u` is useless during an incident |
| **CI/CD job logs** | Runner attaches a pty or a pipe and streams it | Full buffering on a pipe → the job appears hung for 4 minutes, then dumps 4 MiB at once |

### 1.2 Three real incidents that this objective prevents

**Incident A — The backup that never failed.**

```bash
pg_dump production | gzip > /backup/prod-$(date +%F).sql.gz
```

`pg_dump` died with `FATAL: terminating connection due to administrator command`. `gzip` happily compressed the 0 bytes it received and exited 0. The pipeline's exit status is the exit status of the **last** command, so the wrapper script logged `backup OK`, the monitoring check went green, and the 214-byte gzip files were only discovered eleven weeks later during a restore drill. The fix is one line — `set -o pipefail` — and it is examinable material.

**Incident B — The service that "hung" at boot.**

A Python service ran fine interactively but produced no output for minutes under systemd. Nothing was wrong with the service: glibc's stdio switches fd 1 from **line-buffered** to **fully buffered (4 KiB)** when it is not a TTY. Under systemd, fd 1 is a socket. The logs existed; they were sitting in userspace memory. During the incident the on-call engineer restarted the process, discarding the buffer and the evidence.

**Incident C — The disk that was full but empty.**

`df` reported 100% on `/var`; `du -sh /var` reported 3 GB out of 200 GB. A log-rotation script had `rm`'d a 180 GB file while the application still held fd 3 open on it. The inode's link count reached zero, but the **open file description** kept it alive. Space was reclaimed only when the process was restarted — or, as the team eventually learned, by truncating through `/proc/<pid>/fd/3`.

All three are the same subject: **file descriptors, their lifetime, and their buffering semantics**.

---

## 2. The Kernel Model: Descriptors, Descriptions and Inodes

You cannot reason about redirection correctly without three distinct objects. Conflating them produces exactly the bugs in section 9.

```
   Process (PID 4711)                Kernel                     Filesystem
 ┌─────────────────────┐    ┌───────────────────────────┐    ┌──────────────┐
 │ fd table (per proc) │    │ open file description     │    │ inode        │
 │  0 ──────────────┐  │    │  table (system-wide)      │    │  (per file)  │
 │  1 ────────────┐ │  │    │                           │    │              │
 │  2 ──────────┐ │ │  │    │ ┌───────────────────────┐ │    │ ┌──────────┐ │
 │  3 ────────┐ │ │ └──┼───▶│ │ offset, O_APPEND,     │─┼───▶│ │ 8:2 ino  │ │
 │            │ │ └────┼───▶│ │ O_NONBLOCK, access    │ │    │ │ 1441795  │ │
 │            │ └──────┼───▶│ │ mode, refcount        │ │    │ │ nlink=1  │ │
 │            └────────┼───▶│ └───────────────────────┘ │    │ └──────────┘ │
 └─────────────────────┘    └───────────────────────────┘    └──────────────┘
```

* **File descriptor (fd)** — a per-process integer index. `dup2(3, 1)` makes index 1 point at whatever index 3 points at. This is *literally* what the shell does for every redirection.
* **Open file description** — the kernel object holding the **file offset** and the status flags. Two fds created by two separate `open()` calls on the same path have **independent offsets**. Two fds created by `dup()`/`dup2()` **share** one offset. This single distinction explains why `cmd > f 2> f` corrupts data and `cmd > f 2>&1` does not.
* **Inode** — the on-disk file. It is freed when `nlink == 0` **and** no open file description references it. Hence incident C.

### 2.1 The three standard streams

| fd | POSIX name | C stdio handle | Default buffering when TTY | Default when pipe/file | Conventional use |
|---:|---|---|---|---|---|
| 0 | standard input | `stdin` | line-buffered | fully buffered | data to consume |
| 1 | standard output | `stdout` | line-buffered | **fully buffered (4 KiB+)** | the *result* — machine-parseable |
| 2 | standard error | `stderr` | unbuffered | **unbuffered** | diagnostics, progress, prompts |

> **Architectural rule:** fd 1 carries the payload of the program; fd 2 carries commentary *about* the program. A tool that prints progress bars to fd 1 is unpipeable and therefore unusable in automation. This is why `curl` writes its transfer meter to fd 2, and why `kubectl get -o json` warnings go to fd 2.

Descriptors 3 and above are yours. Nothing in the kernel privileges 0/1/2; the convention is enforced entirely by libc and by the shell.

### 2.2 Observing the model directly

```bash
$ sleep 300 > /tmp/out.log 2>&1 < /dev/null &
[1] 4711
$ ls -l /proc/4711/fd
total 0
lr-x------. 1 dalmine dalmine 64 Aug 26 14:02 0 -> /dev/null
l-wx------. 1 dalmine dalmine 64 Aug 26 14:02 1 -> /tmp/out.log
l-wx------. 1 dalmine dalmine 64 Aug 26 14:02 2 -> /tmp/out.log
```

```bash
$ cat /proc/4711/fdinfo/1
pos:	0
flags:	02101001
mnt_id:	28
ino:	1441795
$ cat /proc/4711/fdinfo/2
pos:	0
flags:	02101001
mnt_id:	28
ino:	1441795
```

Identical `ino`, and because `2>&1` was a `dup2`, they are the **same** open file description: advancing one advances the other. Contrast with `> /tmp/out.log 2> /tmp/out.log`, which produces two descriptions both starting at `pos: 0`.

The `/dev/std*` paths are just a userspace view of the same table:

```bash
$ ls -l /dev/stdin /dev/stdout /dev/stderr /dev/fd
lrwxrwxrwx. 1 root root 15 Aug 26 09:11 /dev/fd -> /proc/self/fd
lrwxrwxrwx. 1 root root 15 Aug 26 09:11 /dev/stderr -> /proc/self/fd/2
lrwxrwxrwx. 1 root root 15 Aug 26 09:11 /dev/stdin -> /proc/self/fd/0
lrwxrwxrwx. 1 root root 15 Aug 26 09:11 /dev/stdout -> /proc/self/fd/1
```

---

## 3. Redirection: Complete Operator Reference and Trade-offs

### 3.1 The operator matrix

`n` is an optional fd number immediately preceding the operator (**no space**), defaulting to 0 for input and 1 for output.

| Operator | POSIX `sh` | bash | Underlying syscall effect | Semantics |
|---|:---:|:---:|---|---|
| `n> file` | ✅ | ✅ | `open(O_WRONLY\|O_CREAT\|O_TRUNC)` + `dup2` | Truncate/create, write |
| `n>> file` | ✅ | ✅ | `open(O_WRONLY\|O_CREAT\|O_APPEND)` | Append; each `write()` is atomic w.r.t. offset |
| `n< file` | ✅ | ✅ | `open(O_RDONLY)` | Read |
| `n<> file` | ✅ | ✅ | `open(O_RDWR\|O_CREAT)` | Read-write, **no truncation** |
| `n>| file` | ✅ | ✅ | `open(...O_TRUNC)` | Force truncate even under `set -o noclobber` |
| `n>&m` | ✅ | ✅ | `dup2(m, n)` | Point fd *n* at fd *m*'s description |
| `n<&m` | ✅ | ✅ | `dup2(m, n)` | Same, input side |
| `n>&-` / `n<&-` | ✅ | ✅ | `close(n)` | Close the descriptor |
| `&> file` | ❌ | ✅ | `dup2` after `open` | Shorthand for `> file 2>&1` |
| `&>> file` | ❌ | ✅ | — | Shorthand for `>> file 2>&1` |
| `<< DELIM` | ✅ | ✅ | temp file or pipe on fd 0 | Here-document |
| `<<- DELIM` | ✅ | ✅ | — | Here-document, strips **leading tabs only** |
| `<<< word` | ❌ | ✅ (also ksh/zsh) | — | Here-string |
| `<(cmd)` / `>(cmd)` | ❌ | ✅ (also ksh/zsh) | `pipe2()` + `/dev/fd/N` | Process substitution — expands to a *pathname* |
| `\|&` | ❌ | ✅ (bash 4+) | — | Shorthand for `2>&1 \|` |
| `{var}> file` | ❌ | ✅ (bash 4.1+) | — | Allocate a free fd ≥ 10 into `$var` |

### 3.2 Ordering: the single most-tested subtlety

Redirections are processed **left to right**, and `n>&m` copies the *current* target of `m`.

```bash
$ ls /etc/hostname /etc/nope > /tmp/a.txt 2>&1 ; cat /tmp/a.txt
ls: cannot access '/etc/nope': No such file or directory
/etc/hostname
```

```bash
$ ls /etc/hostname /etc/nope 2>&1 > /tmp/b.txt
ls: cannot access '/etc/nope': No such file or directory
$ cat /tmp/b.txt
/etc/hostname
```

In the second case, at the moment `2>&1` was evaluated, fd 1 still referred to the terminal, so fd 2 was pointed at the terminal. Only afterwards was fd 1 moved to the file. The mnemonic: **`2>&1` means "wherever 1 points *right now*", not "wherever 1 will eventually point".**

The idiomatic swap of stdout and stderr uses the same rule plus a scratch descriptor:

```bash
$ { ls /etc/hostname /etc/nope 3>&2 2>&1 1>&3 3>&- ; } | sed 's/^/[stdout-channel] /'
[stdout-channel] ls: cannot access '/etc/nope': No such file or directory
/etc/hostname
```

### 3.3 Truncation happens *before* the command runs

The shell performs all redirections after fork and before `execve`. Therefore:

```bash
$ printf 'c\na\nb\n' > /tmp/data.txt
$ sort /tmp/data.txt > /tmp/data.txt
$ wc -c /tmp/data.txt
0 /tmp/data.txt
```

The file was truncated to zero before `sort` ever opened it. **Never redirect into a file that is also an input.** Production-safe alternatives:

| Approach | Command | Atomic? | Notes |
|---|---|:---:|---|
| Temp file + rename | `sort f > f.tmp && mv f.tmp f` | ✅ on same filesystem | `rename(2)` is atomic; preserves readers of the old inode |
| `sponge` (moreutils) | `sort f \| sponge f` | ⚠️ | Buffers all input in memory, then writes; not atomic, but avoids truncation |
| In-place flag | `sed -i`, `perl -i`, `sort -o f f` | Varies | `sort -o` explicitly supports this; `sed -i` creates a new inode (breaks hardlinks and open fds) |
| `<>` read-write | `exec 3<> f` | ❌ | Advanced; no truncation, you manage offsets |

`sort` is the exception worth memorising:

```bash
$ printf 'c\na\nb\n' > /tmp/data.txt
$ sort -o /tmp/data.txt /tmp/data.txt
$ cat /tmp/data.txt
a
b
c
```

### 3.4 `noclobber` — a cheap guardrail for interactive root shells

```bash
$ set -o noclobber
$ echo hello > /tmp/data.txt
-bash: /tmp/data.txt: cannot overwrite existing file
$ echo hello >| /tmp/data.txt
$ echo more >> /tmp/data.txt
```

`noclobber` protects only against `>`. It does **not** protect against `>>`, `dd of=`, `cp`, or `tee`. Treat it as ergonomics, not a control.

### 3.5 Persistent redirection with `exec`

`exec` **without a command** applies redirections to the current shell, permanently. This is how you build a script that logs everything it does without wrapping every line.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOGFILE=/var/log/deploy.log

# Duplicate the original terminal onto fd 3 so we can still talk to the operator.
exec 3>&1 4>&2
# Everything from here on goes to the log AND to the original stdout.
exec > >(tee -a "$LOGFILE") 2>&1

echo "starting deploy"          # -> terminal + logfile
echo "operator-only note" >&3   # -> terminal only
```

Closing descriptors is equally explicit and matters when you spawn children that must not inherit a lock or a socket:

```bash
$ exec 9> /var/lock/deploy.lock
$ flock -n 9 || { echo "another deploy is running" >&2; exit 1; }
$ ls -l /proc/$$/fd/9
l-wx------. 1 dalmine dalmine 64 Aug 26 14:31 /proc/29144/fd/9 -> /var/lock/deploy.lock
$ exec 9>&-
$ ls -l /proc/$$/fd/9
ls: cannot access '/proc/29144/fd/9': No such file or directory
```

Automatic descriptor allocation avoids hard-coding numbers that may collide in sourced libraries:

```bash
$ exec {audit_fd}>>/var/log/audit-trail.log
$ echo "fd allocated: $audit_fd"
fd allocated: 10
$ printf '%s deploy started\n' "$(date -Is)" >&"$audit_fd"
$ exec {audit_fd}>&-
```

### 3.6 Here-documents, here-strings and process substitution

```bash
$ cat <<'EOF' > /etc/sysctl.d/99-platform.conf
# $HOME and `hostname` are NOT expanded because the delimiter is quoted
net.core.somaxconn = 4096
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2097152
EOF
```

| Form | Expansion of `$var`, `` `cmd` ``, `\` | Typical use |
|---|:---:|---|
| `<< EOF` | ✅ | Templating a config with runtime values |
| `<< 'EOF'` or `<< "EOF"` | ❌ | Emitting literal scripts, JSON with `$`, regexes |
| `<<- EOF` | ✅ | Indented heredoc inside a function — **tabs only**, spaces are preserved |
| `<<< "$var"` | ✅ (it is a normal word) | Feeding one string to a filter without `echo \|` |

Here-string vs. `echo` pipeline — the difference is a subshell, and it matters:

```bash
$ echo "10 20 30" | read a b c ; echo "a=$a"
a=
$ read a b c <<< "10 20 30" ; echo "a=$a"
a=10
```

The pipeline runs `read` in a subshell whose variables vanish. The here-string does not fork.

**Process substitution** turns a command into a filename. This is the tool for programs that refuse to read stdin, or when you need *two* streams:

```bash
$ diff <(ssh web-01 'rpm -qa --qf "%{NAME}-%{VERSION}\n"' | sort) \
       <(ssh web-02 'rpm -qa --qf "%{NAME}-%{VERSION}\n"' | sort)
312a313
> nginx-1.26.2
$ echo <(true)
/dev/fd/63
```

The output side, `>(...)`, is how you fan a stream into several sinks:

```bash
$ tar -cf - /srv/data \
    | tee >(sha256sum > /backup/data.sha256) \
          >(wc -c > /backup/data.size) \
    | zstd -19 -T0 -o /backup/data.tar.zst
```

> **Trap:** the shell does **not** wait for `>(...)` children. `/backup/data.sha256` may still be empty the instant the pipeline returns. Either `wait` on `$!` where available, or restructure so the consumer is the last stage.

---

## 4. Pipes: Mechanics, Back-pressure and Exit Status

### 4.1 What `|` actually is

`cmd1 | cmd2` performs `pipe2()` to obtain a read end and a write end, forks twice, `dup2`s the write end onto fd 1 of the left process and the read end onto fd 0 of the right process, closes the spares in both, and `execve`s.

```bash
$ strace -f -e trace=pipe2,dup2,clone,execve -o /tmp/p.trace bash -c 'echo hi | cat' >/dev/null
$ grep -E 'pipe2|dup2' /tmp/p.trace
29310 pipe2([3, 4], 0)                  = 0
29311 dup2(4, 1)                        = 1
29312 dup2(3, 0)                        = 0
```

Key properties an SRE must internalise:

| Property | Value on Linux | Operational consequence |
|---|---|---|
| Default capacity | 65536 bytes (16 pages) | A producer blocks once the consumer falls 64 KiB behind — this *is* your back-pressure mechanism |
| Max capacity (unprivileged) | `/proc/sys/fs/pipe-max-size`, default 1048576 | `fcntl(F_SETPIPE_SZ)`; raising it hides back-pressure, it does not remove it |
| `PIPE_BUF` | 4096 bytes | Writes **≤ 4096 bytes** to a pipe are atomic; concurrent writers interleave cleanly below this size, and corrupt each other above it |
| Reader closes early | Writer receives `SIGPIPE`, or `EPIPE` if the signal is blocked | Exit status **141** (`128 + 13`) |
| Writer closes | Reader's `read()` returns 0 (EOF) | Normal termination of the consumer |
| Buffering | Kernel ring buffer, never touches disk | No `fsync` semantics; a crash loses in-flight data |

The `PIPE_BUF` guarantee is why multiple containers appending short lines to a shared FIFO produce clean logs, and why a 200 KiB JSON blob written by two processes to the same FIFO comes out shredded.

Back-pressure is directly observable:

```bash
$ yes | head -c 65536 > /dev/null ; echo "fits in the buffer"
fits in the buffer
$ ( yes 'x' & ) | (sleep 5; wc -l)   # producer blocks after ~64 KiB
```

```bash
$ cat /proc/$(pgrep -f 'yes x' | head -1)/wchan ; echo
pipe_write
```

A process in `pipe_write` is not hung — it is throttled by a slow consumer. That distinction saves an unnecessary restart during an incident.

### 4.2 SIGPIPE — expected, and frequently misread as an error

```bash
$ yes | head -n 3
y
y
y
$ echo "${PIPESTATUS[@]}"
141 0
```

`yes` did not fail; it was told the world stopped listening. But with `set -o pipefail`, that 141 becomes the pipeline's status and a `set -e` script exits:

```bash
$ bash -c 'set -euo pipefail; yes | head -n 3; echo "reached"'
y
y
y
$ echo $?
141
```

**Handling pattern:** treat 141 as success for producers you deliberately truncate.

```bash
head_safe() {
  local rc
  set +o pipefail
  "$@"
  rc=${PIPESTATUS[0]}
  set -o pipefail
  (( rc == 0 || rc == 141 ))
}
```

### 4.3 Exit status of a pipeline — the highest-value operational content in this objective

| Shell setting | `$?` after `a \| b \| c` | Best for |
|---|---|---|
| Default (POSIX) | Exit status of `c` only | Interactive use |
| `set -o pipefail` (bash/ksh/zsh, **not POSIX sh**) | Rightmost **non-zero** status, else 0 | Every non-interactive script |
| `${PIPESTATUS[@]}` (bash) / `${pipestatus[@]}` (zsh) | Array of all statuses | Precise error attribution and metrics |

```bash
$ false | true | true ; echo "default: $?"
default: 0
$ set -o pipefail
$ false | true | true ; echo "pipefail: $?"
pipefail: 1
$ grep -q nonexistent /etc/hostname | cat ; echo "statuses: ${PIPESTATUS[*]}"
statuses: 1 0
```

Production template — this is the fix for Incident A:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

declare -a rc
pg_dump --no-owner production | zstd -19 -T0 > "/backup/prod-$(date +%F).sql.zst"
rc=("${PIPESTATUS[@]}")

if (( rc[0] != 0 )); then
  echo "FATAL: pg_dump exited ${rc[0]}" >&2
  exit "${rc[0]}"
elif (( rc[1] != 0 )); then
  echo "FATAL: zstd exited ${rc[1]}" >&2
  exit "${rc[1]}"
fi
```

### 4.4 Subshells, `lastpipe`, and lost variables

Every component of a pipeline runs in a subshell. Counters incremented inside the last stage evaporate:

```bash
$ count=0; printf 'a\nb\nc\n' | while read -r l; do ((count++)); done; echo "count=$count"
count=0
```

Three correct fixes:

```bash
# 1. Redirect instead of pipe — no subshell for the loop
$ count=0; while read -r l; do ((count++)); done < <(printf 'a\nb\nc\n'); echo "count=$count"
count=3

# 2. Here-string
$ count=0; while read -r l; do ((count++)); done <<< $'a\nb\nc'; echo "count=$count"
count=3

# 3. lastpipe — requires job control OFF (i.e. non-interactive scripts)
$ bash -c 'shopt -s lastpipe; count=0; printf "a\nb\nc\n" | while read -r l; do ((count++)); done; echo "count=$count"'
count=3
```

### 4.5 Named pipes (FIFOs) — decoupling processes that cannot be piped

An anonymous pipe requires a common ancestor. A FIFO is a filesystem entry, so unrelated processes — different containers sharing a volume, a legacy daemon and a modern log shipper — can rendezvous.

```bash
$ mkfifo -m 0600 /var/run/app/applog.pipe
$ ls -l /var/run/app/applog.pipe
prw-------. 1 app app 0 Aug 26 15:02 /var/run/app/applog.pipe
```

```bash
$ ( logger -t legacy-app -f /var/run/app/applog.pipe & )
$ echo "checkout failed order=8812" > /var/run/app/applog.pipe
$ journalctl -t legacy-app -n 1 --no-pager
Aug 26 15:03:11 node-01 legacy-app[31220]: checkout failed order=8812
```

| Property | Anonymous pipe `\|` | Named pipe (FIFO) |
|---|---|---|
| Namespace | Kernel only, inherited via fork | Filesystem path |
| Unrelated processes | ❌ | ✅ |
| `open()` for write blocks | n/a | ✅ until a reader opens (unless `O_NONBLOCK`) |
| Survives restarts | ❌ | The *node* survives; buffered data does not |
| Multiple writers | Rare | Common — atomic below `PIPE_BUF` |
| Disk usage | 0 | 0 (data never hits the backing store) |
| Main production risk | — | A writer blocks forever if the reader dies |

> **Operational warning:** if the single reader of a FIFO exits, the next writer gets `SIGPIPE`; if *no* reader ever opens it, a blocking writer hangs at `open()` indefinitely. Sidecar log shippers built on FIFOs need a reader supervised independently of the writer.

---

## 5. `tee` — Splitting a Stream Without Losing It

`tee` reads stdin, writes it to stdout **and** to every file argument. It is the canonical answer to "send output to both the screen and a file", which is an explicit sub-objective of 103.4.

```bash
$ journalctl -u kubelet -n 5 --no-pager | tee /tmp/kubelet.snippet | wc -l
5
$ head -2 /tmp/kubelet.snippet
Aug 26 15:10:02 node-01 kubelet[1188]: I0826 15:10:02.114 kubelet.go:2437] "SyncLoop (PLEG)"
Aug 26 15:10:04 node-01 kubelet[1188]: I0826 15:10:04.902 kubelet.go:2451] "SyncLoop (probe)"
```

| Flag | Effect | Production relevance |
|---|---|---|
| `-a`, `--append` | `O_APPEND` instead of truncating | Mandatory for long-running log capture |
| `-i`, `--ignore-interrupts` | Ignores `SIGINT` | Keeps the transcript when the operator hits Ctrl-C |
| `-p` | Diagnose write errors, don't exit on `SIGPIPE` | Multi-sink pipelines where one sink may vanish |
| `--output-error=warn\|exit\|warn-nopipe` | Policy on write failure | `exit` for backups where a silent sink loss is unacceptable |

### 5.1 The three canonical `tee` idioms

```bash
# 1. Capture everything (stdout AND stderr) while still watching it live
$ ./deploy.sh 2>&1 | tee -a /var/log/deploy-$(date +%F).log

# 2. Write to a root-owned path from an unprivileged shell.
#    `sudo cmd > /etc/x` fails: the *shell* opens the file, and the shell is not root.
$ echo 'vm.swappiness = 1' | sudo tee /etc/sysctl.d/99-swappiness.conf
vm.swappiness = 1
$ echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-swappiness.conf > /dev/null

# 3. Fan out to N heterogeneous sinks
$ kubectl get events -A -w \
    | tee >(grep -E 'Failed|OOMKilled' >> /var/log/k8s-bad-events.log) \
          >(logger -t k8s-events) \
    > /dev/null
```

### 5.2 The exit-status trap that `tee` introduces

```bash
$ false | tee /tmp/x.log ; echo "status: $?"
status: 0
$ set -o pipefail
$ false | tee /tmp/x.log ; echo "status: $?"
status: 1
```

Any `| tee` inserted "just to see the output" converts a failing command into a passing one unless `pipefail` is set or `PIPESTATUS` is inspected. This is the reason CI wrappers that append `| tee build.log` start reporting green builds that produce no artifacts.

### 5.3 `tee` versus the alternatives

| Requirement | Tool | Trade-off |
|---|---|---|
| Screen + one file | `tee file` | Simplest; loses exit status without `pipefail` |
| Screen + file, keep exit status | `cmd \|& tee f; exit ${PIPESTATUS[0]}` | Correct, more verbose |
| Whole *session* transcript incl. TTY control codes | `script -q -c 'cmd' /tmp/t.log` | Allocates a **pty** — also defeats block buffering (§7) |
| File only, no screen | `cmd > file 2>&1` | One fd, no extra process |
| Overwrite an input file | `sponge` (moreutils) | Buffers in RAM; not atomic |
| Duplicate into a *process* | `tee >(proc)` | Bash-only; shell does not wait for the child |
| Duplicate for the whole script | `exec > >(tee -a f) 2>&1` | Elegant; child outlives the redirection unless handled |

---

## 6. `xargs` — Turning Output Into Arguments

Piping connects **stdout to stdin**. Many essential tools (`rm`, `chown`, `kubectl delete`, `systemctl`) take **arguments**, not stdin. `xargs` is the bridge, and using the output of one command as arguments to another is a named sub-objective of 103.4.

### 6.1 The limit that makes `xargs` necessary

```bash
$ getconf ARG_MAX
2097152
$ rm /var/log/spool/*.tmp
-bash: /usr/bin/rm: Argument list too long
```

`E2BIG` comes from `execve(2)`. Two separate ceilings apply: total argv+envp size (`ARG_MAX`, typically 2 MiB or 1/4 of the stack limit) and `MAX_ARG_STRLEN` = 131072 bytes for any **single** argument. `xargs` reads the limit and batches accordingly:

```bash
$ xargs --show-limits < /dev/null
Your environment variables take up 3186 bytes
POSIX upper limit on argument length (this system): 2091118
POSIX smallest allowable upper limit on argument length (all systems): 4096
Maximum length of command we could actually use: 2087932
Size of command buffer we are actually using: 131072
Maximum parallelism (--max-procs must be no greater than): 2147483647
```

### 6.2 Flags that matter in production

| Flag | Meaning | When it is mandatory |
|---|---|---|
| `-0`, `--null` | Input items are NUL-separated | **Always**, with `find -print0` — the only separator impossible in a filename |
| `-d DELIM` | Custom delimiter | Newline-only input: `-d '\n'` |
| `-r`, `--no-run-if-empty` | Don't run once on empty input | GNU-only, but critical: `xargs rm -rf` on empty input runs `rm -rf` with no args |
| `-n N` | At most N arguments per invocation | Rate-limiting an API-backed CLI |
| `-L N` | At most N **lines** per invocation | Line-oriented input |
| `-I {}` | Replace `{}` anywhere in the command | Implies `-L 1` — **one process per item**, much slower |
| `-P N` | Run N invocations in parallel | `-P 0` = as many as possible; combine with `-n` |
| `-t` | Echo each command to stderr before running | Auditing |
| `-p` | Prompt for confirmation | Interactive destructive operations |
| `-a FILE` | Read items from FILE instead of stdin | Frees stdin for the child command |
| `-s N` | Max command length in bytes | Working around remote `ARG_MAX` over `ssh` |

### 6.3 Correct and incorrect forms, side by side

```bash
$ mkdir -p /tmp/lab && cd /tmp/lab && touch 'report final.log' 'ok.log'
$ find . -name '*.log' | xargs rm -v
removed './ok.log'
rm: cannot remove './report': No such file or directory
rm: cannot remove 'final.log': No such file or directory
```

```bash
$ touch 'report final.log' 'ok.log'
$ find . -name '*.log' -print0 | xargs -0 -r rm -v
removed './report final.log'
removed './ok.log'
```

Empty input, with and without `-r`:

```bash
$ find /tmp/lab -name '*.nomatch' | xargs -t ls
ls
ls: cannot access ...   # ran once with no arguments — lists the CWD
$ find /tmp/lab -name '*.nomatch' | xargs -r -t ls
$ echo $?
0
```

Placement with `-I`, and the batching difference:

```bash
$ printf 'alpha\nbravo\ncharlie\n' | xargs -t echo PREFIX
echo PREFIX alpha bravo charlie
PREFIX alpha bravo charlie

$ printf 'alpha\nbravo\ncharlie\n' | xargs -t -I{} echo PREFIX {} SUFFIX
echo PREFIX alpha SUFFIX
PREFIX alpha SUFFIX
echo PREFIX bravo SUFFIX
PREFIX bravo SUFFIX
echo PREFIX charlie SUFFIX
PREFIX charlie SUFFIX
```

Parallelism with bounded concurrency — the pattern for draining nodes or warming caches without melting the control plane:

```bash
$ kubectl get pods -n prod -o name \
    | xargs -r -n1 -P4 -I{} sh -c 'kubectl logs -n prod {} --tail=1 >/dev/null 2>&1 || echo "no logs: {}"'
no logs: pod/batch-runner-7f9c4d8b6-x2llq
```

> With `-P > 1`, children share fd 1. Output lines longer than `PIPE_BUF` (4096) may interleave. Either keep lines short, or have each child write to its own file and concatenate.

### 6.4 `xargs` versus `find -exec` versus a shell loop versus `parallel`

| Approach | Processes spawned | Handles weird filenames | Parallel | Portable | Notes |
|---|---|---|:---:|:---:|---|
| `find … -exec cmd {} \;` | one per file | ✅ (no shell involved) | ❌ | POSIX | Slowest; correct by construction |
| `find … -exec cmd {} +` | batched (like `xargs`) | ✅ | ❌ | POSIX | **Best default** when `find` is already the source |
| `find … -print0 \| xargs -0 -r cmd` | batched | ✅ | ✅ via `-P` | GNU/BSD | Needed when you want parallelism or a non-`find` source |
| `while IFS= read -r -d '' f; do …; done < <(find … -print0)` | 0 extra (builtins) | ✅ | ❌ | bash | Full shell logic per item; no `execve` cost for builtins |
| `parallel` (GNU) | batched/parallel | ✅ | ✅ | extra package | Job control, retries, remote execution; not on the exam |

```bash
$ find /var/log -name '*.log' -type f -exec stat -c '%s %n' {} + | sort -rn | head -3
2147483 /var/log/journal/9f0.../system.journal
 894112 /var/log/audit/audit.log
 331290 /var/log/messages
```

---

## 7. Buffering: Why Correct Redirection Still Produces No Output

The shell wires the descriptors correctly, and yet the log is empty. The cause is in libc, not in the kernel.

| fd 1 is a… | glibc stdio mode | Flush trigger |
|---|---|---|
| TTY | line-buffered | every `\n` |
| pipe, file, socket | **fully buffered**, `BUFSIZ`/st_blksize (4096+) | buffer full, `fflush()`, or clean `exit()` |
| fd 2 (any target) | unbuffered | every write |

Consequences: a process killed with `SIGKILL` loses its buffered stdout entirely; a process that is merely slow appears silent for minutes.

### 7.1 Reproducing and fixing it

```bash
$ python3 -c 'import time,sys
for i in range(3):
    print(f"tick {i}"); time.sleep(1)' | cat
# ...3 seconds of nothing, then:
tick 0
tick 1
tick 2
```

| Fix | Command | Applies to |
|---|---|---|
| Application flag | `python3 -u`, `PYTHONUNBUFFERED=1`, `node` (already line-buffered to pipes since v6), `stdbuf`-unaware Go (already unbuffered) | Best when available |
| Tool's own flag | `grep --line-buffered`, `sed -u`, `awk` + `fflush()`, `jq --unbuffered`, `tcpdump -l`, `stdbuf` | Filters *inside* the pipeline |
| `stdbuf` (coreutils) | `stdbuf -oL -eL cmd` | Dynamically linked programs using glibc stdio; **no effect** on static binaries, setuid binaries, or programs calling `setvbuf()` themselves |
| Fake a TTY | `script -qec 'cmd' /dev/null` or `unbuffer cmd` (expect) | Anything, including static binaries |

```bash
$ stdbuf -oL python3 -c 'import time
for i in range(3):
    print(f"tick {i}"); time.sleep(1)' | cat
tick 0
tick 1
tick 2
```

> **Note:** `stdbuf -oL python3` works only because CPython consults its own logic; for a program that hard-codes `setvbuf(stdout, buf, _IOFBF, N)`, only a pty helps. Check with `ltrace -e setvbuf` or read the source.

The classic multi-stage victim:

```bash
# Broken: grep fully buffers because its stdout is a pipe
$ tail -F /var/log/app.log | grep ERROR | ts

# Fixed
$ tail -F /var/log/app.log | grep --line-buffered ERROR | ts
```

---

## 8. Complete Production Infrastructure

Everything below is complete and syntactically valid — no elisions.

### 8.1 Container image: forcing an unpipeable application onto stdout

The pattern used by the official `nginx` image: replace the log files with symlinks to the container's own stdout/stderr.

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:12-slim

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends nginx ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    # The application insists on writing to files. Point those files at the
    # container's stdout/stderr so the runtime's log driver collects them.
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log

# PID 1 must NOT daemonize: the runtime attaches the pipes to PID 1's fds.
STOPSIGNAL SIGQUIT
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
```

Verification inside a running container:

```bash
$ docker run -d --name web -p 8080:80 platform/nginx:1.26
b91f2c0a7de4
$ docker exec web ls -l /proc/1/fd/1 /proc/1/fd/2
l-wx------ 1 root root 64 Aug 26 16:02 /proc/1/fd/1 -> pipe:[184229]
l-wx------ 1 root root 64 Aug 26 16:02 /proc/1/fd/2 -> pipe:[184230]
$ docker exec web readlink /var/log/nginx/access.log
/dev/stdout
$ curl -s localhost:8080 >/dev/null && docker logs --tail 1 web
172.17.0.1 - - [26/Aug/2026:16:02:41 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.6.0" "-"
```

### 8.2 Kubernetes: the two streams, and how the kubelet sees them

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: streams-lab
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: stream-emitter
  namespace: streams-lab
data:
  emit.sh: |
    #!/bin/sh
    set -eu
    # Two independent streams, distinguishable by the CRI log format.
    i=0
    while [ "$i" -lt 20 ]; do
      printf '%s stdout-line seq=%d\n' "$(date -Iseconds)" "$i"
      printf '%s stderr-line seq=%d\n' "$(date -Iseconds)" "$i" >&2
      i=$((i + 1))
      sleep 2
    done
    # Kubernetes reads this file to populate the container's termination message.
    printf 'emitter finished cleanly after %d iterations\n' "$i" > /dev/termination-log
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stream-demo
  namespace: streams-lab
  labels:
    app.kubernetes.io/name: stream-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: stream-demo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stream-demo
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: emitter
          image: busybox:1.36
          command: ["/bin/sh", "/scripts/emit.sh"]
          terminationMessagePath: /dev/termination-log
          terminationMessagePolicy: FallbackToLogsOnError
          env:
            # Belt and braces for interpreted runtimes; harmless for sh.
            - name: PYTHONUNBUFFERED
              value: "1"
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: scripts
          configMap:
            name: stream-emitter
            defaultMode: 0555
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 8Mi
```

```bash
$ kubectl apply -f stream-demo.yaml
namespace/streams-lab created
configmap/stream-emitter created
deployment.apps/stream-demo created

$ kubectl -n streams-lab logs deploy/stream-demo --tail=4
2026-08-26T16:20:10+00:00 stdout-line seq=3
2026-08-26T16:20:10+00:00 stderr-line seq=3
2026-08-26T16:20:12+00:00 stdout-line seq=4
2026-08-26T16:20:12+00:00 stderr-line seq=4
```

`kubectl logs` merges both streams. To separate them you must read the CRI log on the node — this is the layer the abstraction hides:

```bash
$ POD_UID=$(kubectl -n streams-lab get pod -l app.kubernetes.io/name=stream-demo \
    -o jsonpath='{.items[0].metadata.uid}')
$ sudo tail -4 /var/log/pods/streams-lab_stream-demo-*_${POD_UID}/emitter/0.log
2026-08-26T16:20:12.114882301Z stdout F 2026-08-26T16:20:12+00:00 stdout-line seq=4
2026-08-26T16:20:12.115901744Z stderr F 2026-08-26T16:20:12+00:00 stderr-line seq=4
2026-08-26T16:20:14.117003912Z stdout F 2026-08-26T16:20:14+00:00 stdout-line seq=5
2026-08-26T16:20:14.117994120Z stderr F 2026-08-26T16:20:14+00:00 stderr-line seq=5
```

Fields: RFC3339Nano timestamp, **stream name** (`stdout`/`stderr`), tag (`F` = full line, `P` = partial), message. containerd splits any line longer than **16 KiB** into `P` fragments; a JSON log line above that limit arrives at your aggregator as several unparseable pieces unless the shipper reassembles `P`/`F`.

```bash
$ sudo awk '$2=="stderr"' /var/log/pods/streams-lab_*/emitter/0.log | wc -l
20
```

### 8.3 Kubernetes: sidecar consuming a FIFO from a legacy application

For an application that cannot be made to write to stdout, a named pipe on a shared `emptyDir` converts file output into a stream, with **zero disk usage** and no rotation.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fifo-bridge
  namespace: streams-lab
data:
  setup-fifo.sh: |
    #!/bin/sh
    set -eu
    # Must exist before either the app or the shipper opens it.
    [ -p /shared/app.pipe ] || mkfifo -m 0660 /shared/app.pipe
    echo "fifo ready: $(ls -l /shared/app.pipe)"
  legacy-app.sh: |
    #!/bin/sh
    set -eu
    # The "legacy" application: it only knows how to append to a log file.
    LOGFILE=/shared/app.pipe
    i=0
    while :; do
      printf '{"ts":"%s","level":"info","seq":%d,"msg":"transaction processed"}\n' \
        "$(date -Iseconds)" "$i" >> "$LOGFILE"
      i=$((i + 1))
      sleep 3
    done
  shipper.sh: |
    #!/bin/sh
    set -eu
    # Reader side. Reopen on EOF: every time the last writer closes the FIFO,
    # read() returns 0 and `cat` exits. A supervised loop keeps the reader alive.
    while :; do
      cat /shared/app.pipe || true
      sleep 0.2
    done
---
apiVersion: v1
kind: Pod
metadata:
  name: fifo-sidecar
  namespace: streams-lab
spec:
  restartPolicy: Never
  initContainers:
    - name: create-fifo
      image: busybox:1.36
      command: ["/bin/sh", "/scripts/setup-fifo.sh"]
      volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: shared
          mountPath: /shared
    # Native sidecar (Kubernetes 1.29+): an initContainer with restartPolicy:
    # Always starts before the app containers and keeps running. This guarantees
    # a reader is attached to the FIFO before the writer opens it.
    - name: log-shipper
      image: busybox:1.36
      restartPolicy: Always
      command: ["/bin/sh", "/scripts/shipper.sh"]
      resources:
        requests: { cpu: 5m, memory: 8Mi }
        limits:   { cpu: 50m, memory: 32Mi }
      volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: shared
          mountPath: /shared
  containers:
    - name: legacy-app
      image: busybox:1.36
      command: ["/bin/sh", "/scripts/legacy-app.sh"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits:   { cpu: 100m, memory: 64Mi }
      volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: shared
          mountPath: /shared
  volumes:
    - name: scripts
      configMap:
        name: fifo-bridge
        defaultMode: 0555
    - name: shared
      emptyDir:
        medium: Memory
        sizeLimit: 1Mi
```

```bash
$ kubectl apply -f fifo-sidecar.yaml
configmap/fifo-bridge created
pod/fifo-sidecar created

$ kubectl -n streams-lab logs fifo-sidecar -c log-shipper --tail=2
{"ts":"2026-08-26T16:41:07+00:00","level":"info","seq":11,"msg":"transaction processed"}
{"ts":"2026-08-26T16:41:10+00:00","level":"info","seq":12,"msg":"transaction processed"}

$ kubectl -n streams-lab exec fifo-sidecar -c legacy-app -- sh -c 'ls -l /shared; du -sh /shared'
prw-rw----    1 root     root             0 Aug 26 16:40 app.pipe
0	/shared
```

The `emptyDir` never grows: the FIFO holds at most 64 KiB in kernel memory, and the data is consumed as fast as it is produced.

### 8.4 systemd: redirection at the service-manager layer

```ini
# /etc/systemd/system/order-processor.service
[Unit]
Description=Order Processor (stream-correct logging)
Documentation=https://internal.example.com/runbooks/order-processor
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=order
Group=order
WorkingDirectory=/opt/order-processor

# The unit's fd 1 and fd 2 become AF_UNIX sockets to systemd-journald.
# Do NOT add a shell redirection in ExecStart; it would bypass this entirely.
StandardInput=null
StandardOutput=journal
StandardError=journal
SyslogIdentifier=order-processor

# Defeat glibc full buffering: fd 1 is a socket, not a TTY.
Environment=PYTHONUNBUFFERED=1
Environment=LC_ALL=C.UTF-8

ExecStart=/opt/order-processor/venv/bin/python -u -m order_processor.main

Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
KillSignal=SIGTERM
# Give the process a chance to flush before SIGKILL.
FinalKillSignal=SIGKILL

# Hardening — unrelated to streams, but these units ship together in production.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/order-processor
CapabilityBoundingSet=
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
$ sudo systemctl daemon-reload && sudo systemctl restart order-processor
$ systemctl show order-processor -p StandardOutput -p StandardError -p MainPID
StandardOutput=journal
StandardError=journal
MainPID=41902
$ sudo ls -l /proc/41902/fd/{0,1,2}
lr-x------. 1 order order 64 Aug 26 17:01 /proc/41902/fd/0 -> /dev/null
l-wx------. 1 order order 64 Aug 26 17:01 /proc/41902/fd/1 -> socket:[512338]
l-wx------. 1 order order 64 Aug 26 17:01 /proc/41902/fd/2 -> socket:[512338]
$ journalctl -u order-processor -n 2 --no-pager -o short-iso
2026-08-26T17:01:12+0000 node-01 order-processor[41902]: ready, listening on :9090
2026-08-26T17:01:14+0000 node-01 order-processor[41902]: processed order=44120 in 18ms
```

To separate the two streams at the journal level, `StandardError=` accepts different sinks:

```ini
StandardOutput=journal
StandardError=append:/var/log/order-processor/errors.log
```

| `StandardOutput=` value | Where fd 1 points | Rotation responsibility |
|---|---|---|
| `journal` (default) | `AF_UNIX` socket to journald | journald (`SystemMaxUse=`) |
| `inherit` | Whatever systemd itself has | — |
| `null` | `/dev/null` | none |
| `tty` | The configured `TTYPath=` | none |
| `file:/path` | `open(O_CREAT\|O_TRUNC)` at each start | **you** (`logrotate`) |
| `append:/path` | `open(O_CREAT\|O_APPEND)` | **you** |
| `truncate:/path` | Truncate on every start | **you** |
| `socket` | Inherited socket-activation fd | — |
| `kmsg` | Kernel ring buffer | ring |

### 8.5 `logrotate`: the two strategies, and why one loses data

If you *must* keep file-based logs, understand the fd consequence. Renaming a file does not change the writer's open file description — the process keeps writing into the renamed inode, and the new file stays at 0 bytes forever.

```conf
# /etc/logrotate.d/order-processor
/var/log/order-processor/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    dateext
    dateformat -%Y-%m-%d
    create 0640 order order
    sharedscripts
    postrotate
        # CORRECT: tell the process to close and reopen its log files.
        # Zero data loss; the old inode is released the instant it reopens.
        /bin/systemctl kill -s SIGUSR1 order-processor.service 2>/dev/null || true
    endscript
}

# Only for a process that cannot be signalled to reopen.
/var/log/legacy-vendor/*.log {
    size 100M
    rotate 5
    compress
    missingok
    # copytruncate: copy the file, then truncate the ORIGINAL inode in place.
    # The writer's fd and offset are untouched, so it keeps working — but any
    # bytes written between the copy and the truncate are LOST, and the
    # truncated file becomes sparse until the offset catches up.
    copytruncate
}
```

| Strategy | Data loss window | Requires app cooperation | Leaves sparse files | Verdict |
|---|---|:---:|:---:|---|
| `create` + reopen signal | none | ✅ (SIGHUP/SIGUSR1 handler) | ❌ | **Preferred** |
| `copytruncate` | copy→truncate race | ❌ | ✅ | Last resort for vendor binaries |
| No rotation, log to stdout | none | ✅ | ❌ | **Correct for containers** |

---

## 9. Verification and Failure Diagnosis

### 9.1 Symptom → cause → command

| Symptom | Most likely cause | First command to run |
|---|---|---|
| `docker logs` / `kubectl logs` empty, process healthy | App writes to a file, or daemonized away from PID 1's fds | `readlink /proc/1/fd/1` inside the container |
| Output appears in bursts of ~4 KiB or only at exit | glibc full buffering on a non-TTY fd 1 | `stdbuf -oL cmd` / `script -qec` to confirm |
| Pipeline reports success but produced nothing | Exit status of last stage masks the failure | `echo "${PIPESTATUS[@]}"`; add `set -o pipefail` |
| `df` full, `du` small | Deleted file still held open | `lsof +L1 /var` |
| Exit code 141 | `SIGPIPE` — the reader closed first | Expected with `head`; check for premature consumer death otherwise |
| `Argument list too long` | `execve` `E2BIG` | `getconf ARG_MAX`; switch to `find -exec … +` or `xargs` |
| Command consumed the wrong files | Word-splitting on whitespace in filenames | Re-run with `-print0` / `xargs -0` |
| A destructive `xargs` ran on empty input | Missing `-r` | Add `--no-run-if-empty` |
| Writer stuck, consumer slow | Pipe buffer full (back-pressure, not a hang) | `cat /proc/PID/wchan` → `pipe_write` |
| `sudo cmd > /root/file` → Permission denied | The *shell* opens the file, unprivileged | `cmd \| sudo tee /root/file` |
| Log file rotated but stays 0 bytes | Writer holds the old inode | `lsof -p PID \| grep '(deleted)'`, signal reopen |
| Variable set in a loop is empty afterwards | Loop ran in a pipeline subshell | Use `< <(...)`, `<<<`, or `shopt -s lastpipe` |

### 9.2 Diagnosing "the disk is full but nothing is there"

```bash
$ df -h /var
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var   200G  200G     0 100% /var
$ du -sh /var
3.1G	/var

$ sudo lsof +L1 /var
COMMAND     PID  USER   FD   TYPE DEVICE     SIZE/OFF NLINK     NODE NAME
java      21877   app    3w   REG  253,4 189223448576     0 20971621 /var/log/app/app.log (deleted)

$ sudo ls -l /proc/21877/fd/3
l-wx------. 1 app app 64 Aug 26 17:22 /proc/21877/fd/3 -> '/var/log/app/app.log (deleted)'
```

Recover the content before reclaiming, if the data matters:

```bash
$ sudo cp /proc/21877/fd/3 /mnt/rescue/app.log.recovered
$ ls -lh /mnt/rescue/app.log.recovered
-rw-r--r--. 1 root root 176G Aug 26 17:25 /mnt/rescue/app.log.recovered
```

Reclaim without restarting the service — truncate **through** the descriptor:

```bash
$ sudo truncate -s 0 /proc/21877/fd/3
$ df -h /var
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var   200G  3.2G  188G   2% /var
```

> The writer's offset is *not* reset by `truncate`, so the file becomes sparse and `ls -l` will still show a large apparent size. `du` shows the real allocation. This is a controlled trade: an incident-time reclaim, not a substitute for fixing rotation.

### 9.3 Proving where a stream actually goes

```bash
$ sudo strace -f -y -e trace=write,openat,dup2,pipe2 -p 21877 2>&1 | head -6
strace: Process 21877 attached
write(3</var/log/app/app.log (deleted)>, "2026-08-26 17:31:02 INFO order 4"..., 61) = 61
write(1<pipe:[512901]>, "heartbeat ok\n", 13) = 13
```

The `-y` flag prints the resolved path for each descriptor — this single flag answers "which fd goes where" faster than any amount of reading configuration.

### 9.4 Verifying the buffering hypothesis in 20 seconds

```bash
$ ./ingest --verbose | head -1     # nothing for 30s -> suspicious
^C
$ ./ingest --verbose > /dev/tty | head -1   # bypass the pipe: output is immediate?
processing batch 1
```

If output is immediate to a TTY and delayed to a pipe, it is buffering, not a hang. Confirm and fix:

```bash
$ stdbuf -oL -eL ./ingest --verbose | head -1
processing batch 1
```

### 9.5 A verification checklist for any log path you own

```bash
# 1. Does the process actually hold the descriptors you think it does?
$ sudo ls -l /proc/$(pgrep -f order_processor)/fd/{0,1,2}

# 2. Are both streams reaching the collector?
$ journalctl -u order-processor -n 20 -o json | jq -r '.PRIORITY + " " + .MESSAGE' | sort -u | head

# 3. Is anything buffered rather than delivered?
$ sudo cat /proc/$(pgrep -f order_processor)/wchan; echo

# 4. Does the pipeline propagate failure?
$ bash -c 'set -o pipefail; false | tee /dev/null; echo $?'
1

# 5. Is any log file being written while unlinked?
$ sudo lsof +L1 / 2>/dev/null | awk 'NR==1 || $NF ~ /deleted/'

# 6. Will a rotation actually work?
$ sudo logrotate -d /etc/logrotate.d/order-processor
```

### 9.6 Guided lab — verify every claim in this topic

```bash
# --- Descriptors -----------------------------------------------------------
$ mkdir -p ~/streams-lab && cd ~/streams-lab
$ ls /etc/hostname /etc/nope > out.txt 2> err.txt
$ cat out.txt; echo '---'; cat err.txt
/etc/hostname
---
ls: cannot access '/etc/nope': No such file or directory

# --- Ordering --------------------------------------------------------------
$ ls /etc/hostname /etc/nope > both.txt 2>&1 ; wc -l both.txt
2 both.txt
$ ls /etc/hostname /etc/nope 2>&1 > only-out.txt ; wc -l only-out.txt
ls: cannot access '/etc/nope': No such file or directory
1 only-out.txt

# --- Same file, two descriptions (data corruption) --------------------------
$ ls /etc/hostname /etc/nope > bad.txt 2> bad.txt ; cat -A bad.txt | head -2
/etc/hostname$
ls: cannot access '/etc/nope': No such file or directory$

# --- Pipe capacity and back-pressure ---------------------------------------
$ (dd if=/dev/zero bs=1024 count=100 2>/dev/null | (sleep 2; wc -c)) &
$ sleep 0.5; cat /proc/$(pgrep -n dd)/wchan; echo
pipe_write

# --- PIPESTATUS ------------------------------------------------------------
$ grep -q root /etc/passwd | grep -q nosuchuser | true; echo "${PIPESTATUS[*]}"
0 1 0

# --- tee to a privileged path ----------------------------------------------
$ echo 'kernel.pid_max = 4194304' | sudo tee /etc/sysctl.d/98-pidmax.conf
kernel.pid_max = 4194304

# --- xargs safety ----------------------------------------------------------
$ touch 'a b.tmp' 'c.tmp'
$ find . -name '*.tmp' -print0 | xargs -0 -r -t rm -v
rm -v ./a b.tmp ./c.tmp
removed './a b.tmp'
removed './c.tmp'

# --- Process substitution ---------------------------------------------------
$ diff <(printf 'a\nb\nc\n') <(printf 'a\nx\nc\n')
2c2
< b
---
> x

# --- Named pipe -------------------------------------------------------------
$ mkfifo demo.pipe
$ (wc -l < demo.pipe &) ; printf 'l1\nl2\nl3\n' > demo.pipe
3
$ rm -f demo.pipe
```

---

## 10. Exam-Focused Consolidation

| You must be able to… | Canonical answer |
|---|---|
| Send stdout to a file, discard stderr | `cmd > out.txt 2> /dev/null` |
| Send stderr to a file, keep stdout on screen | `cmd 2> err.txt` |
| Merge both into one file | `cmd > all.txt 2>&1` **or** `cmd &> all.txt` (bash) |
| Append both | `cmd >> all.txt 2>&1` **or** `cmd &>> all.txt` |
| Discard everything | `cmd > /dev/null 2>&1` |
| Send stdout to a file *and* the screen | `cmd \| tee out.txt` |
| Append while showing | `cmd \| tee -a out.txt` |
| Both streams to screen and file | `cmd 2>&1 \| tee -a out.txt` |
| Print to stderr from a script | `echo "message" >&2` |
| Feed a file to a command's stdin | `cmd < in.txt` |
| Feed a literal block to stdin | `cmd <<'EOF' … EOF` |
| Feed a single string to stdin | `cmd <<< "$var"` |
| Chain commands | `cmd1 \| cmd2 \| cmd3` |
| Use output as *arguments* | `cmd1 \| xargs cmd2` |
| Handle filenames with spaces | `find … -print0 \| xargs -0 …` |
| Avoid running on empty input | `xargs -r` |
| One invocation per item | `xargs -I{} cmd {} extra` |
| Catch a failing stage in a pipeline | `set -o pipefail` / `${PIPESTATUS[@]}` |

**Highest-yield distinctions:** `>` truncates while `>>` appends; `2>&1` must come *after* the stdout redirection; `|` connects stdout→stdin while `xargs` converts stdout→argv; `tee` is the only standard way to satisfy "screen **and** file" in one pass; `&>` and `<<<` and `<(…)` are bash extensions, not POSIX.

---

## 11. References

**Certification objectives**
- LPI — Exam 101 Objectives (LPIC-1 version 5.0), Topic 103.4: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Shell and standards**
- GNU Bash Reference Manual — Redirections: https://www.gnu.org/software/bash/manual/html_node/Redirections.html
- GNU Bash Reference Manual — Pipelines: https://www.gnu.org/software/bash/manual/html_node/Pipelines.html
- GNU Bash Reference Manual — Process Substitution: https://www.gnu.org/software/bash/manual/html_node/Process-Substitution.html
- GNU Bash Reference Manual — The Set Builtin (`pipefail`, `noclobber`): https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- POSIX.1-2024 (IEEE Std 1003.1-2024) — Shell Command Language, Redirection: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_07

**Kernel and libc**
- `pipe(7)` — pipes and FIFOs, capacity and `PIPE_BUF`: https://man7.org/linux/man-pages/man7/pipe.7.html
- `fifo(7)` — named pipes: https://man7.org/linux/man-pages/man7/fifo.7.html
- `dup(2)` / `dup2(2)`: https://man7.org/linux/man-pages/man2/dup.2.html
- `open(2)` — `O_APPEND`, `O_TRUNC`, `O_CREAT`: https://man7.org/linux/man-pages/man2/open.2.html
- `execve(2)` — `E2BIG` and `ARG_MAX`: https://man7.org/linux/man-pages/man2/execve.2.html
- `stdio(3)` — buffering modes: https://man7.org/linux/man-pages/man3/stdio.3.html
- `setvbuf(3)`: https://man7.org/linux/man-pages/man3/setvbuf.3.html
- `proc(5)` — `/proc/pid/fd`, `/proc/pid/fdinfo`, `/proc/pid/wchan`: https://man7.org/linux/man-pages/man5/proc.5.html

**Core utilities**
- GNU Coreutils Manual — `tee`: https://www.gnu.org/software/coreutils/manual/html_node/tee-invocation.html
- GNU Coreutils Manual — `stdbuf`: https://www.gnu.org/software/coreutils/manual/html_node/stdbuf-invocation.html
- GNU Findutils Manual — `xargs`: https://www.gnu.org/software/findutils/manual/html_node/find_html/Invoking-xargs.html
- GNU Findutils Manual — `find … -exec … +`: https://www.gnu.org/software/findutils/manual/html_node/find_html/Multiple-Files.html
- POSIX.1-2024 — `xargs`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/xargs.html
- POSIX.1-2024 — `tee`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tee.html
- moreutils (`sponge`): https://joeyh.name/code/moreutils/

**Service management and logging**
- systemd — `systemd.exec(5)`, `StandardInput=`/`StandardOutput=`/`StandardError=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — `journald.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- logrotate — `logrotate(8)`: https://linux.die.net/man/8/logrotate

**Containers and orchestration**
- Kubernetes — Logging Architecture (node-level logging, CRI log format, sidecars): https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Kubernetes — Determine the Reason for Pod Failure (`terminationMessagePath`): https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/
- Kubernetes — Sidecar Containers: https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Docker — Configure logging drivers: https://docs.docker.com/engine/logging/configure/
- The Twelve-Factor App — XI. Logs: https://12factor.net/logs