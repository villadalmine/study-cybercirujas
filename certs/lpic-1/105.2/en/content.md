# LPIC-1 · Topic 105.2 — Customize or Write Simple Scripts

**Exam:** 102-500 (LPIC-1 v5.0) · **Objective 105.2** · Topic 105 *Shells and Shell Scripting*

**Key knowledge areas covered here:** standard `sh` syntax (loops, tests), command substitution, testing return values for success/failure or other information provided by a command, conditional mailing to the superuser, correct interpreter selection through the shebang (`#!`) line, and managing the location, ownership, execution and `suid` rights of scripts.

**Terms and utilities in scope:** `for`, `while`, `test`, `if`, `read`, `seq`, `exec`, `||`, `&&`, `;`, `exit`, `set`, `declare`, `.` (source), shell functions.

---

## 1. The production problem: shell is the substrate nobody audits

Every layer of a modern platform terminates in a shell script, whether or not anyone admits it:

| Layer | Where the script actually lives | What breaks when it is wrong |
|---|---|---|
| Container image | `ENTRYPOINT ["/entrypoint.sh"]` | PID 1 does not forward `SIGTERM`; pods take the full `terminationGracePeriodSeconds` to die, rolling updates crawl |
| Kubernetes probes | `exec: command: ["/bin/sh","-c","..."]` | A probe that always exits 0 masks a dead process; a probe that exits non-zero on a transient blip triggers a restart storm |
| Batch | `CronJob` → `command`, or `/etc/cron.daily/<name>` | Job "succeeds" while doing nothing; silent data loss |
| Node bootstrap | cloud-init, `%post`, Ignition, Ansible `shell:` | Node joins the cluster half-configured |
| CI/CD | `script:` blocks in GitLab CI, `run:` in GitHub Actions | Pipeline goes green on a failed build step |
| Systemd | `ExecStart=`, `ExecStartPre=`, `OnFailure=` | Unit reports `active (exited)` while the work never ran |

The architectural property that matters is this: **a shell script's public API is its exit status, and its observability surface is stdout/stderr.** Everything above — Kubernetes, systemd, cron, CI — is a supervisor that makes scheduling, restart, alerting and rollback decisions from a single integer between 0 and 255. A script that returns 0 after failing is not a bug in the script; it is a **corrupted control signal** propagated into the orchestrator, and it defeats every retry, alerting and rollback mechanism built on top.

Three failure classes cause the overwhelming majority of production incidents traceable to shell code:

1. **Silent failure** — the script continues after an error, and the last command (often `echo` or `rm`) returns 0. The supervisor records success.
2. **Wrong interpreter** — the script was written and tested under `bash` but the shebang says `#!/bin/sh`, which on Debian/Ubuntu is `dash`. Or the file was edited on Windows and carries CRLF line endings. The kernel refuses to exec, or the shell fails on constructs the author believed were universal.
3. **Unquoted expansion** — a variable containing a space, a glob character or a newline is word-split by the shell into multiple arguments. The classic terminal case is `rm -rf $DIR/` where `DIR` is empty.

This objective is about eliminating all three deterministically, with free static checks, before the code ever reaches a node.

---

## 2. The interpreter contract: what `#!` actually does

### 2.1 Kernel mechanics

`#!` is not a shell feature. It is handled by the kernel, in `fs/binfmt_script.c`. When `execve(2)` is called on a regular file with the execute bit set, the kernel reads the first bytes:

* If they are `\x7fELF`, `binfmt_elf` handles it.
* If they are `#!` (bytes `0x23 0x21`), `binfmt_script` reads the rest of the first line, splits it into an interpreter path plus **at most one** argument, and re-executes as `interpreter [optional-arg] script-path [original args...]`.
* Otherwise `execve` returns `ENOEXEC`.

Consequences that bite in production:

| Property | Behaviour | Practical rule |
|---|---|---|
| Line length limit | The first line is truncated to the kernel's `BINPRM_BUF_SIZE` (128 bytes historically, 256 on current kernels) | Never rely on long shebangs; keep them short |
| Argument count | Linux passes **everything after the interpreter as a single argument** | `#!/usr/bin/env python3 -u` passes `"python3 -u"` as one arg to `env` → fails |
| `env -S` | GNU coreutils ≥ 8.30 `env -S` splits the string itself | `#!/usr/bin/env -S python3 -u` works on GNU systems, not on BusyBox/BSD |
| No shebang | `execve` → `ENOEXEC`. An interactive `bash` catches this and re-runs the file with a copy of itself; a C program or `execve` from another language just fails | Always write a shebang |
| Relative interpreter | `#!bash` is resolved relative to the caller's CWD, not `PATH` | Always absolute, or `env` |

```
$ head -c 2 /usr/local/sbin/rotate-artifacts | xxd
00000000: 2321                                     #!

$ file /usr/local/sbin/rotate-artifacts
/usr/local/sbin/rotate-artifacts: Bourne-Again shell script, ASCII text executable
```

### 2.2 The three diagnostic signatures

```
$ ./deploy.sh
bash: ./deploy.sh: /bin/bash^M: bad interpreter: No such file or directory
```
CRLF line endings. The kernel took `/bin/bash\r` as the interpreter path. Confirm and fix:

```
$ file deploy.sh
deploy.sh: Bourne-Again shell script, ASCII text executable, with CRLF line terminators

$ sed -i 's/\r$//' deploy.sh
$ file deploy.sh
deploy.sh: Bourne-Again shell script, ASCII text executable
```

```
$ ./collect.sh; echo "rc=$?"
bash: ./collect.sh: /usr/bin/pythn3: bad interpreter: No such file or directory
rc=126
```
Typo or missing interpreter in a slim image. Exit status **126** = found but not executable.

```
$ ./collect.sh; echo "rc=$?"
bash: ./collect.sh: Permission denied
rc=126

$ ls -l collect.sh
-rw-r--r--. 1 sre sre 812 Aug 26 09:14 collect.sh
$ chmod 0755 collect.sh
$ ./collect.sh; echo "rc=$?"
rc=0
```

### 2.3 `#!/bin/sh` vs `#!/bin/bash` vs `#!/usr/bin/env bash`

| Shebang | Resolves to | Portable | Speed / size | When to use |
|---|---|---|---|---|
| `#!/bin/sh` | `dash` on Debian/Ubuntu, `bash` in POSIX mode on RHEL ≤ 8, `busybox ash` in Alpine | Maximum | Fastest start, smallest image | Init scripts, container entrypoints, anything that must run in a distroless/Alpine image |
| `#!/bin/bash` | Always GNU bash, fixed path | Fails where bash is at `/usr/local/bin/bash` (BSD) or absent (Alpine `bash` not installed) | ~3–5× slower startup than dash | System scripts on a distro you control |
| `#!/usr/bin/env bash` | First `bash` on `PATH` | Best for developer laptops and BSD | Same as above + one extra exec | Tooling, CI helpers |
| `#!/usr/bin/env -S bash -euo pipefail` | GNU coreutils ≥ 8.30 only | Poor | — | Avoid; put `set` on line 2 instead |

**The trap:** `#!/usr/bin/env bash` searches `PATH`. Under `sudo` with `secure_path` set, or in a systemd unit where `PATH` is `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, that may not be the `bash` you tested with. For anything invoked by a supervisor, prefer the absolute path and pin the environment in the unit file.

For LPIC-1 and for portable platform code, **`#!/bin/sh` plus strictly POSIX syntax is the defensible default**, and the rest of this document marks every bashism explicitly.

---

## 3. Choosing the dialect: POSIX `sh` vs `bash`

Debian and Ubuntu symlink `/bin/sh` to `dash` (Debian Almquist Shell) precisely because it is small and fast — it shaves measurable time off boot, where thousands of small scripts run. Alpine uses BusyBox `ash`. Neither is bash. The following table is the single most valuable artifact in this objective:

| Construct | POSIX `sh` (dash/ash) | bash | Portable replacement |
|---|---|---|---|
| `[[ x == y ]]` | ✗ `[[: not found` | ✓ | `[ "$x" = "$y" ]` |
| `==` inside `[ ]` | ✗ (dash accepts it, but it is non-standard) | ✓ | `=` |
| `(( n > 3 ))` | ✗ | ✓ | `[ "$n" -gt 3 ]` |
| `$(( n + 1 ))` | ✓ | ✓ | — |
| `arr=(a b c)` | ✗ | ✓ | Positional params `set -- a b c` |
| `${var,,}` / `${var^^}` | ✗ | ✓ (4.0+) | `tr '[:upper:]' '[:lower:]'` |
| `${var/foo/bar}` | ✗ | ✓ | `sed` / `${var#...}` `${var%...}` |
| `source file` | ✗ | ✓ | `. ./file` |
| `function f { }` | ✗ | ✓ | `f() { ... }` |
| `local` | ✓ *(dash/ash extension, not POSIX-2018; POSIX-2024 adds it)* | ✓ | Use it; universally available in practice |
| `echo -n` / `echo -e` | Undefined behaviour | ✓ | `printf '%s' "$x"` |
| `set -o pipefail` | ✗ in dash (added to POSIX Issue 8, 2024) | ✓ | Explicit status checks, or FIFOs |
| `${PIPESTATUS[@]}` | ✗ | ✓ | — |
| `trap ... ERR` | ✗ | ✓ | `set -e` + `trap ... EXIT` |
| `$RANDOM`, `$SECONDS`, `$EPOCHSECONDS` | ✗ | ✓ | `od -An -N2 -tu2 /dev/urandom`, `date +%s` |
| `<<<"here string"` | ✗ | ✓ | `printf '%s\n' "$x" \|` or heredoc |
| `&>file` | ✗ | ✓ | `>file 2>&1` |
| Process substitution `<(cmd)` | ✗ | ✓ | Temp file / FIFO |
| `read -a`, `read -d` | ✗ | ✓ | `IFS` + `set --` |
| `wait -n`, `mapfile` | ✗ | ✓ | — |

Demonstrating the cost of getting it wrong:

```
$ cat > /tmp/check.sh <<'EOF'
#!/bin/sh
if [[ "$1" == "prod" ]]; then
    echo "production"
fi
EOF
$ chmod +x /tmp/check.sh

$ bash /tmp/check.sh prod
production

$ dash /tmp/check.sh prod
/tmp/check.sh: 2: [[: not found

$ dash /tmp/check.sh prod; echo "rc=$?"
/tmp/check.sh: 2: [[: not found
rc=0
```

Note the last line carefully. **The script failed and still exited 0**, because the `if` simply took the false branch after the command was not found. A CI gate or a systemd unit would report success. This is failure class #1 and #2 combined, and it is caught for free:

```
$ checkbashisms /tmp/check.sh
possible bashism in /tmp/check.sh line 2 (alternative test command ([[ foo ]] should be [ foo ])):
if [[ "$1" == "prod" ]]; then

$ shellcheck -s sh /tmp/check.sh

In /tmp/check.sh line 2:
if [[ "$1" == "prod" ]]; then
   ^-- SC3010 (warning): In POSIX sh, [[ ]] is undefined.
                ^-- SC3014 (warning): In POSIX sh, == in place of = is undefined.

For more information:
  https://www.shellcheck.net/wiki/SC3010 -- In POSIX sh, [[ ]] is undefined.
  https://www.shellcheck.net/wiki/SC3014 -- In POSIX sh, == in place of = is...
```

---

## 4. Exit status: the script's real API

### 4.1 The status space

| Range | Meaning | Source |
|---|---|---|
| `0` | Success | Convention, enforced by every supervisor |
| `1` | Generic failure | Convention |
| `2` | Shell builtin misuse / usage error | bash convention |
| `1`–`125` | Application-defined | Yours to allocate |
| `126` | Command found but not executable (permissions, bad interpreter) | Shell |
| `127` | Command not found | Shell |
| `128+N` | Terminated by signal N (`130` = SIGINT, `137` = SIGKILL, `143` = SIGTERM) | Shell |
| `255` | `exit` argument out of range, or "everything failed" by convention | Shell |
| `64`–`78` | `sysexits.h` conventions (`EX_USAGE`=64 … `EX_CONFIG`=78) | BSD convention, used by MTAs |

```
$ nosuchcommand; echo $?
bash: nosuchcommand: command not found
127

$ sh -c 'kill -TERM $$'; echo $?
143

$ sh -c 'exit 300'; echo $?
44
```

`exit 300` wraps modulo 256 → 44. **Never compute an exit code from a count** (`exit "$errors"`); 256 errors becomes success.

### 4.2 Reading the status

`$?` holds the status of the **most recently completed foreground pipeline**. It is destroyed by the very next command, including `echo`.

```
$ grep -q root /etc/passwd
$ echo $?
0
$ echo $?
0        # <- this is the status of the previous echo, not of grep
```

Capture it immediately if you need it twice:

```sh
some_command
rc=$?
if [ "$rc" -ne 0 ]; then
    printf 'some_command failed with rc=%d\n' "$rc" >&2
fi
```

### 4.3 `&&`, `||`, `;` and short-circuit control flow

| Operator | Semantics | Exit status of the list |
|---|---|---|
| `A ; B` | Run A, then B unconditionally | Status of B |
| `A && B` | Run B only if A returned 0 | Status of last command run |
| `A \|\| B` | Run B only if A returned non-zero | Status of last command run |
| `A & B` | A in background, B immediately | Status of B (A's via `wait`) |
| `A \| B` | A's stdout into B's stdin | Status of **B only**, unless `pipefail` |

The classic idiom the exam expects:

```sh
mkdir -p /var/lib/artifacts || exit 1
cd /var/lib/artifacts || exit 1
command -v rsync >/dev/null 2>&1 && rsync -a src/ dst/
```

`cd "$dir" || exit` is not stylistic. Without it, a failed `cd` leaves you in the previous directory and the following `rm -rf ./*` deletes the wrong tree. ShellCheck flags this as **SC2164**.

### 4.4 The pipeline status trap

```
$ false | true; echo $?
0

$ set -o pipefail
$ false | true; echo $?
1
$ set +o pipefail

$ false | true | false | true
$ echo "${PIPESTATUS[@]}"
1 0 1 0
```

`pipefail` and `PIPESTATUS` are **bash/ksh/zsh only** (`pipefail` was standardised in POSIX Issue 8, 2024, but dash does not implement it). In a `#!/bin/sh` script you must restructure:

```sh
# Non-portable but correct in bash:
set -o pipefail
curl -fsS "$url" | tar -xzf - -C "$dest"

# Portable equivalent: stage it, check each stage.
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT INT TERM HUP
curl -fsS "$url" -o "$tmp" || exit 1
tar -xzf "$tmp" -C "$dest" || exit 1
```

Note `curl -f`: without it, curl writes an HTTP 500 error page to the file and exits 0. `-fsS` = fail on HTTP errors, silent progress, but still show errors. This is the same class of bug at the tool level.

### 4.5 `set` options — the strict-mode table

| Option | Long form | Effect | POSIX | Caveat |
|---|---|---|---|---|
| `-e` | `errexit` | Exit on any untested non-zero status | ✓ | Many exemptions — see below |
| `-u` | `nounset` | Error on expansion of an unset variable | ✓ | `"$@"` with no args is safe; `$1` is not |
| `-x` | `xtrace` | Print each command after expansion | ✓ | Leaks secrets into logs |
| `-v` | `verbose` | Print each line as read | ✓ | Pairs with `-n` for parsing |
| `-n` | `noexec` | Parse but do not execute | ✓ | Syntax check only |
| `-f` | `noglob` | Disable pathname expansion | ✓ | Useful around untrusted data |
| `-C` | `noclobber` | `>` refuses to overwrite | ✓ | `>|` overrides |
| `-o pipefail` | — | Pipeline fails if any stage fails | Issue 8 | Not in dash |
| `-m` | `monitor` | Job control | ✓ | Off in non-interactive shells |

`set -e` **does not** trigger in these positions, and this is the number-one reason people believe it is broken:

```sh
set -e

# 1. Anything in a condition context — the whole point is to test it.
if failing_command; then :; fi          # no exit
while failing_command; do :; done       # no exit
failing_command && echo ok              # no exit
! failing_command                       # no exit

# 2. Any command but the last in an && / || list.
false && true                           # no exit

# 3. Any pipeline stage but the last (without pipefail).
false | true                            # no exit

# 4. THE KILLER: local/declare/export swallow the substitution status.
main() {
    local out=$(false)                  # rc of `local` is 0 -> no exit
    echo "still here"
}
```

The fix for #4 — ShellCheck **SC2155** — is to separate declaration from assignment:

```sh
main() {
    local out
    out=$(false) || return 1
    printf '%s\n' "$out"
}
```

Recommended header for a bash script, and its portable sibling:

```sh
#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
```

```sh
#!/bin/sh
set -eu
```

`-E` (bash) makes `trap ... ERR` inherit into functions, subshells and command substitutions. `IFS=$'\n\t'` removes the space from the field separator so accidental word splitting on spaces stops silently mangling paths — it is a bashism (`$'...'` ANSI-C quoting) but a valuable one.

---

## 5. `test`, `[`, and conditionals

`test` and `[` are the same program — and both are shell builtins in every modern shell, with `/usr/bin/[` existing only as a fallback.

```
$ type [ test
[ is a shell builtin
test is a shell builtin
$ ls -l /usr/bin/[ /usr/bin/test
-rwxr-xr-x. 1 root root 63704 Mar  4 12:01 /usr/bin/[
-rwxr-xr-x. 1 root root 59608 Mar  4 12:01 /usr/bin/test
```

`[` requires a literal `]` as its final argument. That is why `[ "$a" = "$b" ]` needs the spaces: they are argument separators, not syntax sugar.

### 5.1 Operator reference

**File tests**

| Test | True when |
|---|---|
| `-e f` | `f` exists (any type) |
| `-f f` | Exists and is a regular file |
| `-d f` | Exists and is a directory |
| `-L f` / `-h f` | Is a symbolic link (not dereferenced) |
| `-b f` / `-c f` | Block / character device |
| `-p f` | Named pipe (FIFO) |
| `-S f` | Socket |
| `-r f` / `-w f` / `-x f` | Readable / writable / executable **by the effective UID** |
| `-s f` | Exists and size > 0 |
| `-u f` / `-g f` / `-k f` | setuid / setgid / sticky bit set |
| `-O f` / `-G f` | Owned by effective UID / GID |
| `-N f` | Modified since last read (bash) |
| `f1 -nt f2` / `f1 -ot f2` | Newer than / older than (mtime) |
| `f1 -ef f2` | Same device and inode (hard link or same file) |

**String tests**

| Test | True when |
|---|---|
| `-z "$s"` | Length is zero |
| `-n "$s"` | Length is non-zero |
| `"$a" = "$b"` | Equal (POSIX) |
| `"$a" != "$b"` | Not equal |
| `"$a" < "$b"` | Sorts before, in the current locale (bash `[[ ]]`; in `[ ]` needs escaping) |

**Integer tests** — `-eq -ne -lt -le -gt -ge`. These are for integers only; `[ "$a" -eq "$b" ]` with a non-numeric `$a` raises an error.

**Logic** — `!` negation, `-a` AND, `-o` OR, `\( \)` grouping. **Do not use `-a`/`-o`**: they are marked obsolescent in POSIX and are ambiguous when operands look like operators. Use shell-level operators instead:

```sh
# Fragile
[ -f "$f" -a -r "$f" ]

# Correct
[ -f "$f" ] && [ -r "$f" ]
```

### 5.2 The quoting rule that prevents 90% of test bugs

```
$ unset name
$ [ $name = "root" ] && echo match
bash: [: =: unary operator expected

$ [ "$name" = "root" ] && echo match
$ echo $?
1
```

Unquoted, an empty variable expands to *nothing*, and `[` receives `= root ]` — three arguments where it expected four. Always quote. The historical `x` prefix (`[ "x$name" = "xroot" ]`) is no longer necessary with any POSIX-conforming `test` and only obscures intent.

### 5.3 `[[ ]]` — what it buys and what it costs (bash only)

| Feature | `[ ]` | `[[ ]]` |
|---|---|---|
| Word splitting on unquoted vars | Yes (dangerous) | No |
| Glob on RHS | No | `[[ $f == *.log ]]` |
| Regex | No | `[[ $s =~ ^v[0-9]+\.[0-9]+$ ]]`, groups in `${BASH_REMATCH[@]}` |
| `&&` / `\|\|` inside | No | Yes |
| Portability | Universal | bash/ksh/zsh only |

```
$ ver="v1.24"
$ [[ $ver =~ ^v([0-9]+)\.([0-9]+)$ ]] && echo "major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}"
major=1 minor=24
```

Do not quote the regex — quoting turns it into a literal string match.

### 5.4 Full conditional forms

```sh
if [ -f "$config" ]; then
    . "$config"
elif [ -f "$HOME/.config/app/config" ]; then
    . "$HOME/.config/app/config"
else
    printf 'no configuration found\n' >&2
    exit 78          # EX_CONFIG
fi

case "$1" in
    start|restart)  do_start ;;
    stop)           do_stop ;;
    status)         do_status ;;
    -h|--help)      usage; exit 0 ;;
    '')             usage >&2; exit 64 ;;   # EX_USAGE
    *)              printf 'unknown action: %s\n' "$1" >&2; exit 64 ;;
esac
```

`case` is POSIX, faster than a chain of `if`, and does glob matching without invoking `test`. It is the right tool for argument dispatch and for init-script–style verb handling.

---

## 6. Loops and safe iteration

### 6.1 `for`

```sh
# POSIX: iterate over words
for env in dev staging prod; do
    printf 'deploying to %s\n' "$env"
done

# Over positional parameters — the quoted "$@" is mandatory
for arg in "$@"; do
    process "$arg"
done

# Bare `for arg; do` implicitly means "in \"$@\"" — POSIX and idiomatic
for arg; do
    process "$arg"
done
```

**Iterating over files — the four options and their trade-offs:**

| Technique | Handles spaces | Handles newlines in names | Recursive | POSIX |
|---|---|---|---|---|
| `for f in *.log` | ✓ (glob output is not word-split) | ✓ | ✗ | ✓ |
| `for f in $(ls)` | ✗ | ✗ | ✗ | ✓ — **never do this** (SC2045) |
| `find ... -exec cmd {} +` | ✓ | ✓ | ✓ | ✓ |
| `find -print0 \| while IFS= read -r -d ''` | ✓ | ✓ | ✓ | ✗ (`-d` is bash) |

```sh
# Portable and safe:
find /var/log/app -type f -name '*.log' -mtime +30 -exec gzip -9 {} +

# Bash, when you need shell logic per file:
while IFS= read -r -d '' f; do
    [ -s "$f" ] || continue
    process "$f"
done < <(find /var/log/app -type f -name '*.log' -print0)
```

Note the glob no-match case. In POSIX `sh`, `for f in *.log` with no matches iterates once with `f` set to the literal string `*.log`:

```
$ cd /tmp/empty
$ for f in *.log; do echo "got: $f"; done
got: *.log
```
Guard it: `[ -e "$f" ] || continue`. In bash, `shopt -s nullglob` makes the list empty instead — a bashism, but a correct one.

### 6.2 Numeric loops: `seq` vs brace expansion vs C-style

| Form | Shell | Notes |
|---|---|---|
| `for i in $(seq 1 10)` | POSIX + coreutils `seq` | Forks a process; not on BusyBox by default in some builds |
| `for i in $(seq 1 2 9)` | Same | Step form: start, increment, end |
| `for i in {1..10}` | bash / zsh | No fork; **does not expand variables** — `{1..$n}` fails |
| `for ((i=1; i<=n; i++))` | bash | No fork, variables work; the correct bash choice |
| `i=1; while [ "$i" -le 10 ]; do ...; i=$((i+1)); done` | POSIX | No fork, no external dependency |

```
$ seq -w 1 3
1
2
3
$ seq -s, 1 5
1,2,3,4,5
$ seq -f 'node-%02g' 1 3
node-01
node-02
node-03
```

`seq -f` is genuinely useful for generating hostnames and replica names. For large ranges, the POSIX `while` form beats `seq` because it avoids materialising the whole list in memory and avoids a fork.

### 6.3 `while`, `until`, and `read`

`while` loops on the exit status of a **command list**, not on a boolean. This is why the read-a-file idiom works:

```sh
while IFS= read -r line; do
    case "$line" in
        ''|'#'*) continue ;;     # skip blanks and comments
    esac
    printf 'line: %s\n' "$line"
done < /etc/app/hosts.conf
```

Three details, all mandatory:

* **`IFS=`** (empty) prevents stripping of leading/trailing whitespace.
* **`-r`** prevents `read` from interpreting backslashes as escapes.
* **`< file` after `done`** redirects the loop's stdin. Using `cat file | while ...` instead creates a subshell in POSIX `sh` and bash, so any variable set inside the loop is lost when it ends.

```
$ count=0
$ printf 'a\nb\nc\n' | while read -r l; do count=$((count+1)); done
$ echo "$count"
0                       # <- the subshell's increment was discarded

$ count=0
$ while read -r l; do count=$((count+1)); done < <(printf 'a\nb\nc\n')
$ echo "$count"
3
```

The portable fix without process substitution is redirection from a file, or a here-document:

```sh
count=0
while read -r l; do count=$((count+1)); done <<EOF
$(printf 'a\nb\nc\n')
EOF
echo "$count"   # 3
```

A file lacking a trailing newline loses its last line — `read` returns non-zero on EOF even though it assigned data. The robust form:

```sh
while IFS= read -r line || [ -n "$line" ]; do
    handle "$line"
done < "$file"
```

**Retry with backoff**, the platform-engineering canonical `until`:

```sh
attempt=0
max=5
delay=1
until curl -fsS -o /dev/null "http://localhost:8080/healthz"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max" ]; then
        printf 'health check failed after %d attempts\n' "$max" >&2
        exit 1
    fi
    sleep "$delay"
    delay=$((delay * 2))
done
printf 'healthy after %d retries\n' "$attempt"
```

`break` exits the innermost loop, `continue` skips to the next iteration; both accept a numeric level (`break 2`) to escape nested loops.

### 6.4 `read` options

| Option | Meaning | POSIX |
|---|---|---|
| `-r` | Raw — do not treat `\` as escape | ✓ |
| `-p 'prompt'` | Print prompt to stderr first | ✗ bash |
| `-s` | Silent (no echo) — passwords | ✗ bash |
| `-t N` | Timeout after N seconds | ✗ bash |
| `-n N` / `-N N` | Read N characters | ✗ bash |
| `-d C` | Use C as delimiter instead of newline | ✗ bash |
| `-a arr` | Read words into an array | ✗ bash |
| `var1 var2 rest` | Split on `IFS`; last var absorbs the remainder | ✓ |

```
$ echo "web01 10.0.1.5 amd64 extra fields here" | \
  while read -r host ip arch rest; do
      printf 'host=%s ip=%s arch=%s rest=[%s]\n' "$host" "$ip" "$arch" "$rest"
  done
host=web01 ip=10.0.1.5 arch=amd64 rest=[extra fields here]
```

Interactive prompting, portable form:

```sh
printf 'Proceed with destructive rollout? [y/N] ' >&2
read -r answer
case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) printf 'aborted\n' >&2; exit 1 ;;
esac
```

Always prompt on **stderr**, so the script remains pipeable.

---

## 7. Command substitution

Two syntaxes; only one is acceptable in new code.

| Form | Nesting | Backslash handling | Verdict |
|---|---|---|---|
| `$(cmd)` | Trivial: `$(a $(b))` | Predictable | **Use this** |
| `` `cmd` `` | Requires escaping: `` `a \`b\`` `` | `\` treated specially inside | Legacy only (SC2006) |

Both are POSIX. Both **strip all trailing newlines** from the output.

```
$ printf 'value\n\n\n' > /tmp/v
$ x=$(cat /tmp/v); printf '[%s]\n' "$x"
[value]
```

To preserve trailing newlines, append a sentinel and remove it:

```sh
x=$(cat /tmp/v; printf 'x')
x=${x%x}
```

### 7.1 Quoting substitutions

```
$ mkdir -p '/tmp/my reports'
$ d=$(printf '/tmp/my reports')

$ ls $d
ls: cannot access '/tmp/my': No such file or directory
ls: cannot access 'reports': No such file or directory

$ ls "$d"
$ echo $?
0
```

Unquoted, the result is subject to word splitting **and** globbing. ShellCheck **SC2046** (`$(...)` unquoted) and **SC2086** (`$var` unquoted) exist for exactly this.

The one intentional exception is when you *want* splitting into arguments — and even then, prefer explicit control:

```sh
# Deliberate splitting, with the field separator pinned:
oldifs=$IFS
IFS=:
set -- $PATH
IFS=$oldifs
for dir; do printf 'PATH entry: %s\n' "$dir"; done
```

### 7.2 Arithmetic vs command substitution

```
$ n=$(( 3 * 7 ))          # arithmetic expansion — POSIX, no fork
$ echo "$n"
21
$ files=$(ls -1 /etc | wc -l)   # command substitution — forks
$ echo "$files"
243
```

`$(( ))` is arithmetic; `$( )` runs a command. Inside `$(( ))`, variables need no `$` (`$((n+1))` works). Bash's `(( ))` statement form is *not* POSIX and has an exit-status inversion trap: `(( 0 ))` returns 1, so `set -e` will kill a script on `((count++))` when `count` was 0.

### 7.3 Practical substitution patterns

```
$ ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "$ts"
2026-08-26T11:42:07Z

$ nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
$ for n in $nodes; do printf 'node: %s\n' "$n"; done
node: cp-01
node: worker-01
node: worker-02

$ if ! bin=$(command -v jq); then printf 'jq missing\n' >&2; exit 127; fi
$ echo "$bin"
/usr/bin/jq

$ mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
$ [ "$mem_kb" -lt 524288 ] && printf 'WARNING: low memory (%s kB)\n' "$mem_kb"
```

Use `command -v`, not `which`. `which` is an external binary, is not in POSIX, is absent from many minimal images, and returns 0 in some implementations even when nothing was found.

---

## 8. Functions, scope, and sourcing

### 8.1 Definition and return

```sh
# POSIX form — the only portable one
log() {
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2
}

die() {
    log ERROR "$*"
    exit 1
}

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}
```

Inside a function, `$1 $2 … $@ $#` are the **function's** arguments, not the script's. `$0` remains the script name. `return N` sets the function's exit status; `return` with no argument returns the status of the last command. `exit` terminates the whole shell — a function that calls `exit` cannot be reused in a condition.

```
$ is_running() { systemctl is-active --quiet "$1"; }
$ is_running sshd && echo up || echo down
up
$ is_running nosuch.service; echo $?
4
```

The status passes straight through, which is exactly what makes functions composable with `&&`, `||` and `if`.

**Return a value, not a status:** shell functions can only return an integer status. To return data, print it and capture it:

```sh
current_release() {
    kubectl get deploy "$1" -o jsonpath='{.metadata.labels.release}' 2>/dev/null
}

rel=$(current_release checkout-api) || die "cannot read release"
[ -n "$rel" ] || die "deployment has no release label"
```

### 8.2 Scope

```
$ f() { x=inside; }
$ x=outside; f; echo "$x"
inside

$ g() { local x=inside; }
$ x=outside; g; echo "$x"
outside
```

All shell variables are global by default. `local` is not in POSIX-2018 but is implemented by bash, dash, ash, ksh93 and zsh — it is safe to use in practice and is required discipline in anything over 50 lines. Remember SC2155: `local x=$(cmd)` discards `cmd`'s exit status.

### 8.3 `.` (dot) and `source`

`.` is POSIX; `source` is a bash synonym. Both execute the file **in the current shell**, so variables, functions and `cd` persist.

| | `. ./lib.sh` | `./lib.sh` (exec) |
|---|---|---|
| Process | Current shell | Child process |
| Variables set | Persist | Discarded |
| `exit` inside | Exits your shell | Exits only the child |
| Requires execute bit | No (read is enough) | Yes |
| Requires shebang | No | Yes |

**PATH gotcha:** POSIX `.` searches `PATH` when the operand contains no slash. `. lib.sh` may source a completely different file from somewhere on `PATH`. Always write `. ./lib.sh` or `. /usr/local/lib/app/lib.sh`.

Standard library layout for a platform toolkit:

```sh
#!/bin/sh
# /usr/local/bin/artifact-gc
set -eu

LIB_DIR=${LIB_DIR:-/usr/local/lib/platform}
# shellcheck source=/dev/null
. "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/retry.sh"
```

The `# shellcheck source=` directive is required or ShellCheck emits SC1091 for files it cannot resolve statically.

`exec` replaces the shell process entirely — no fork, same PID:

```sh
exec >>/var/log/app/job.log 2>&1     # redirect the rest of the script
exec 3< /etc/app/hosts               # open fd 3 for reading
exec "$@"                            # hand off PID 1 to the real program
```

That last line is the single most important line in any container entrypoint; section 12.3 explains why.

---

## 9. Arguments, options and input validation

### 9.1 Special parameters

| Parameter | Meaning |
|---|---|
| `$0` | Script name as invoked |
| `$1`…`$9`, `${10}` | Positional parameters |
| `$#` | Number of positional parameters |
| `"$@"` | All parameters, **each as a separate word** |
| `"$*"` | All parameters joined by the first character of `IFS` into **one word** |
| `$?` | Exit status of the last foreground pipeline |
| `$$` | PID of the shell |
| `$!` | PID of the last background command |
| `$-` | Current option flags |

`"$@"` and `"$*"` are not interchangeable. With arguments `a b` and `c`:

```
$ set -- "a b" "c"
$ printf '[%s]\n' "$@"
[a b]
[c]
$ printf '[%s]\n' "$*"
[a b c]
$ printf '[%s]\n' $@
[a]
[b]
[c]
```

Rule: **`"$@"` always, everywhere**, unless you specifically want a single joined string for a log message.

### 9.2 Parameter expansion for defaults and validation

| Expansion | Behaviour |
|---|---|
| `${var:-default}` | Use `default` if unset **or empty** |
| `${var-default}` | Use `default` only if unset |
| `${var:=default}` | Assign `default` if unset/empty (fails on positional params) |
| `${var:?message}` | Error and exit non-interactive shell if unset/empty |
| `${var:+alt}` | Use `alt` only if var is set and non-empty |
| `${#var}` | Length |
| `${var#pat}` / `${var##pat}` | Strip shortest / longest prefix |
| `${var%pat}` / `${var%%pat}` | Strip shortest / longest suffix |

```
$ f=/var/log/app/checkout-api.access.log
$ echo "${f##*/}"
checkout-api.access.log
$ echo "${f%/*}"
/var/log/app
$ echo "${f%%.*}"
/var/log/app/checkout-api
$ echo "${f##*.}"
log
```

These are POSIX and replace `basename`/`dirname` without forking — meaningful inside a loop over 100 000 files.

```
$ sh -c ': "${DEPLOY_ENV:?must be set}"'
sh: 1: DEPLOY_ENV: must be set
$ echo $?
2
```

### 9.3 `getopts` — POSIX option parsing

```sh
#!/bin/sh
set -eu

usage() {
    cat >&2 <<'EOF'
Usage: artifact-gc [-n] [-d DAYS] [-p PATH] [-v]
  -n        dry run; report what would be removed
  -d DAYS   remove artifacts older than DAYS (default: 30)
  -p PATH   artifact root (default: /var/lib/artifacts)
  -v        verbose
EOF
}

dry_run=0
days=30
root=/var/lib/artifacts
verbose=0

while getopts ':nd:p:vh' opt; do
    case "$opt" in
        n) dry_run=1 ;;
        d) days=$OPTARG ;;
        p) root=$OPTARG ;;
        v) verbose=1 ;;
        h) usage; exit 0 ;;
        :) printf 'option -%s requires an argument\n' "$OPTARG" >&2; usage; exit 64 ;;
        \?) printf 'unknown option: -%s\n' "$OPTARG" >&2; usage; exit 64 ;;
    esac
done
shift $((OPTIND - 1))

# Validate before doing anything destructive.
case "$days" in
    ''|*[!0-9]*) printf 'invalid -d value: %s\n' "$days" >&2; exit 64 ;;
esac
[ -d "$root" ] || { printf 'not a directory: %s\n' "$root" >&2; exit 66; }   # EX_NOINPUT
```

The leading `:` in `':nd:p:vh'` switches `getopts` to *silent* error reporting, which is what lets you emit your own messages for `:` and `\?`. `shift $((OPTIND - 1))` leaves the non-option operands in `"$@"`.

`getopts` handles short options only. GNU long options require `getopt(1)` from util-linux, which is **not portable** and must be used with `eval set -- "$(getopt ...)"` — acceptable on a Linux-only fleet, disqualifying for a distroless image.

The `case "$days" in ''|*[!0-9]*)` idiom is the portable integer check. Do not use `[ "$days" -gt 0 ]` for validation — a non-numeric value produces a shell error, not a clean rejection.

---

## 10. Conditional mailing to the superuser

This is an explicit LPIC-1 objective, and it maps directly to the production question: *how does a batch job tell a human it failed?*

### 10.1 The cron channel (implicit, and the default)

cron mails **any output** — stdout or stderr — of a job to the owner, or to the address in `MAILTO`. This is why the universal cron idiom is "silence on success":

```cron
MAILTO=root
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/sh

# m h dom mon dow  command
17 3 * * *  /usr/local/sbin/artifact-gc -d 30 >/dev/null
```

`>/dev/null` discards stdout; stderr is left alone, so only errors generate mail. `MAILTO=""` disables mail entirely for that crontab.

**Verify the crontab environment, do not assume it.** cron gives a job a minimal environment — typically `PATH=/usr/bin:/bin`, no `LANG`, `HOME` set from `/etc/passwd`. A script that works interactively and fails under cron is nearly always a `PATH` problem:

```
$ sudo crontab -l -u root
MAILTO=root
17 3 * * * /usr/local/sbin/artifact-gc -d 30 >/dev/null

$ sudo journalctl -t CRON --since '-1d' | tail -3
Aug 26 03:17:01 node01 CRON[41220]: (root) CMD (/usr/local/sbin/artifact-gc -d 30 >/dev/null)
Aug 26 03:17:01 node01 CRON[41219]: (root) MAIL (mailed 84 bytes of output but got status 0x0001 from MTA)
```

That second line means the job produced output and the MTA rejected it — the alert path itself is broken.

### 10.2 The explicit channel

```sh
notify_root() {
    subject=$1
    shift
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$*" | mail -s "$subject" root
    elif command -v sendmail >/dev/null 2>&1; then
        {
            printf 'To: root\n'
            printf 'Subject: %s\n' "$subject"
            printf '\n%s\n' "$*"
        } | sendmail -t
    else
        logger -t artifact-gc -p cron.err -- "$subject: $*"
        return 1
    fi
}
```

Beware that `mail`/`mailx` is provided by at least three mutually incompatible packages:

| Implementation | Package | `-a` means | Notes |
|---|---|---|---|
| GNU Mailutils | `mailutils` | attach file | `-A` also attach |
| bsd-mailx | `bsd-mailx` | attach file (recent) / append header (older) | Debian default alternative |
| s-nail / Heirloom | `s-nail`, `heirloom-mailx` | attach (`s-nail`), header (Heirloom) | `-S` sets internal options |

Never build automation on `mail -a` without checking `man mail` on the target image. `sendmail -t` (with the recipient in the message headers) is the most portable interface, because every MTA — Postfix, exim, msmtp, ssmtp, nullmailer — provides a `sendmail`-compatible binary at `/usr/sbin/sendmail`.

### 10.3 The complete conditional-mail script

```sh
#!/bin/sh
#
# /usr/local/sbin/artifact-gc
# Remove build artifacts older than N days. Mails root ONLY on failure.
# Exit codes: 0 ok | 1 gc failure | 64 usage | 66 bad input path | 75 lock held
#
set -eu

PROG=${0##*/}
ROOT=${ARTIFACT_ROOT:-/var/lib/artifacts}
DAYS=${ARTIFACT_MAX_AGE_DAYS:-30}
LOCK=/run/lock/${PROG}.lock
MAILTO=${MAILTO:-root}
HOSTNAME=$(uname -n)

log()  { printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROG" "$*" >&2; }
die()  { log "FATAL: $*"; exit "${2:-1}"; }

notify_root() {
    _subject=$1
    _body=$2
    if command -v sendmail >/dev/null 2>&1; then
        {
            printf 'To: %s\n' "$MAILTO"
            printf 'Subject: [%s] %s\n' "$HOSTNAME" "$_subject"
            printf 'X-Automation: %s\n' "$PROG"
            printf '\n%s\n' "$_body"
        } | /usr/sbin/sendmail -t
    elif command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$_body" | mail -s "[$HOSTNAME] $_subject" "$MAILTO"
    else
        logger -t "$PROG" -p cron.err -- "$_subject"
        return 1
    fi
}

# Serialise: a second instance must not race the first.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK" || die "cannot open lock file $LOCK" 75
    flock -n 9 || die "another instance holds $LOCK" 75
fi

[ -d "$ROOT" ] || die "artifact root is not a directory: $ROOT" 66
case "$DAYS" in ''|*[!0-9]*) die "invalid retention: $DAYS" 64 ;; esac

workdir=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$workdir"' EXIT INT TERM HUP

errlog=$workdir/stderr
before=$(du -sk "$ROOT" 2>/dev/null | awk '{print $1}')

set +e
find "$ROOT" -mindepth 1 -type f -mtime "+$DAYS" -delete 2>"$errlog"
rc=$?
set -e

after=$(du -sk "$ROOT" 2>/dev/null | awk '{print $1}')
freed=$(( before - after ))

if [ "$rc" -ne 0 ]; then
    notify_root "artifact-gc FAILED (rc=$rc)" \
"Host:      $HOSTNAME
Root:      $ROOT
Retention: ${DAYS}d
Exit code: $rc
Freed:     ${freed} kB (partial)

--- stderr ---
$(cat "$errlog")
--------------
Investigate with:
  journalctl -t $PROG --since '-1h'
  ls -la $ROOT"
    die "gc failed with rc=$rc" "$rc"
fi

log "ok: freed ${freed} kB under $ROOT (retention ${DAYS}d)"
exit 0
```

Design points worth internalising:

* `set +e` / `set -e` around the one command whose failure must be **handled** rather than fatal.
* stderr is captured to a file so it can be both reported *and* mailed; discarding it would leave the alert content-free.
* `flock -n 9` on a file descriptor opened by `exec` — the lock is released automatically when the process dies, including on `SIGKILL`. A PID-file lock is not equivalent.
* `trap ... EXIT INT TERM HUP` guarantees temp cleanup on every exit path except `SIGKILL`. Note `EXIT` alone is enough in bash but listing the signals explicitly is the portable habit.
* Exit codes are documented at the top and are stable — that is the contract cron, systemd and Kubernetes consume.

### 10.4 Transport comparison

| Mechanism | Guarantees | Latency | Fails silently when | Use for |
|---|---|---|---|---|
| cron implicit mail | Any output → mail | Per run | No MTA installed; `MAILTO` unset and user has no mailbox | Traditional single-host jobs |
| `mail`/`sendmail` in-script | You control subject/body | Per run | MTA queue stuck; no MTA in container | Host-level batch |
| `logger` → syslog/journald | Structured, always available locally | Immediate | Nobody watches the log | Everything, as a floor |
| systemd `OnFailure=` | Fires on unit failure, including OOM-kill and timeout | Immediate | Unit `Type=` wrong so failure is never detected | systemd-managed jobs |
| Webhook (`curl` to alertmanager) | Routed, deduplicated, escalating | Immediate | Network egress blocked; no retry | Clusters |
| Kubernetes Job failure + `kube_job_failed` metric | Observed by Prometheus | Scrape interval | Job `backoffLimit` exhausted silently | Cluster batch |

In a container there is usually **no MTA at all**, so `mail` is a no-op. The correct in-cluster equivalents are: exit non-zero (so the Job is marked failed), write to stderr (so the log collector picks it up), and optionally `curl` an Alertmanager endpoint. Section 12 shows all three.

---

## 11. Where scripts live: FHS, ownership and permissions

### 11.1 The location table

| Path | Purpose | Owner:Group | Mode | Managed by |
|---|---|---|---|---|
| `/usr/local/bin` | Locally written commands for **all users** | `root:root` | `0755` | You |
| `/usr/local/sbin` | Locally written commands for **root only** | `root:root` | `0755` | You |
| `/usr/local/lib/<pkg>` | Sourced libraries, not directly executable | `root:root` | `0644` | You |
| `/usr/bin`, `/usr/sbin` | Distribution package files | `root:root` | `0755` | Package manager — **do not touch** |
| `/opt/<vendor>/bin` | Self-contained third-party add-on packages | vendor | `0755` | Vendor installer |
| `~/bin`, `~/.local/bin` | Per-user scripts | user | `0755` | User; on PATH via `~/.profile` on most distros |
| `/etc/profile.d/*.sh` | Login-shell environment fragments — **sourced, not executed** | `root:root` | `0644` | You |
| `/etc/cron.{hourly,daily,weekly,monthly}` | Periodic jobs run by `run-parts` | `root:root` | `0755` | You |
| `/etc/cron.d/<name>` | crontab-format fragments (with a user field) | `root:root` | `0644` | You |
| `/etc/init.d` | SysV init scripts (LSB header required) | `root:root` | `0755` | Legacy |
| `/etc/systemd/system` | Local unit files and overrides | `root:root` | `0644` | You |
| `/usr/lib/systemd/system` | Distribution unit files | `root:root` | `0644` | Package manager |
| `/etc/network/if-up.d`, `/etc/NetworkManager/dispatcher.d` | Network event hooks | `root:root` | `0755` | You |
| `/var/lib/<pkg>` | Variable state — **never** put scripts here | varies | varies | App |

The FHS rule underpinning all of this: **`/usr/local` is reserved for software installed by the local administrator and must never be written by the package manager**. Putting your script in `/usr/bin` means the next `dnf upgrade` or `apt upgrade` may silently overwrite or remove it.

### 11.2 The `run-parts` naming trap

Debian's `run-parts`, which drives `/etc/cron.daily`, **silently skips** any filename that does not match `^[a-zA-Z0-9_-]+$` unless invoked with `--lsbsysinit`. A file named `backup.sh` in `/etc/cron.daily` never runs, and nothing logs a warning.

```
$ sudo install -m 0755 -o root -g root backup.sh /etc/cron.daily/backup.sh
$ run-parts --test /etc/cron.daily
/etc/cron.daily/apt-compat
/etc/cron.daily/logrotate
/etc/cron.daily/man-db
                                   # backup.sh is absent

$ sudo mv /etc/cron.daily/backup.sh /etc/cron.daily/backup
$ run-parts --test /etc/cron.daily
/etc/cron.daily/apt-compat
/etc/cron.daily/backup
/etc/cron.daily/logrotate
/etc/cron.daily/man-db
```

**Always validate with `run-parts --test` after dropping a file into a `cron.*` directory.** Files must also be executable and owned by root; `run-parts` skips non-executables and files ending in `.dpkg-dist`, `.dpkg-old`, `~`, `,`.

### 11.3 Installation, ownership and permissions

Use `install(1)` rather than `cp` + `chmod` + `chown` — it is atomic in intent and sets all three in one call:

```
$ sudo install -D -o root -g root -m 0755 artifact-gc /usr/local/sbin/artifact-gc
$ ls -l /usr/local/sbin/artifact-gc
-rwxr-xr-x. 1 root root 2314 Aug 26 11:58 /usr/local/sbin/artifact-gc

$ sudo install -D -o root -g root -m 0644 lib/log.sh /usr/local/lib/platform/log.sh
```

Note the library is `0644`, not `0755`. A sourced file needs read, not execute; making it executable invites someone to run it directly.

Permission model for scripts:

| Mode | Meaning | When |
|---|---|---|
| `0755` | Anyone may read and run; only root may modify | Normal system script in `/usr/local/bin` |
| `0750` | Group-restricted execution | Script for a specific operations group; set group accordingly |
| `0700` | Owner only | Scripts holding embedded credentials (better: no embedded credentials) |
| `0644` | Read-only, sourced | Libraries, `/etc/profile.d` fragments |

### 11.4 setuid on scripts — the objective's sharp edge

LPIC-1 names "suid rights" in this objective, and the correct professional answer is:

> **The setuid bit has no effect on shell scripts on Linux.** The kernel deliberately ignores it for `#!`-interpreted files because of an unfixable exec race, so a setuid script is not a privilege escalation — it is a misleading no-op that will be flagged by every security scanner.

```
$ sudo install -m 4755 -o root -g root whoami-test.sh /usr/local/bin/whoami-test.sh
$ ls -l /usr/local/bin/whoami-test.sh
-rwsr-xr-x. 1 root root 40 Aug 26 12:03 /usr/local/bin/whoami-test.sh

$ cat /usr/local/bin/whoami-test.sh
#!/bin/sh
id -u

$ /usr/local/bin/whoami-test.sh
1000                       # <- still the calling user; setuid was ignored
```

Finding them across a fleet:

```
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u %g %p\n' 2>/dev/null
-rwsr-xr-x root root /usr/bin/sudo
-rwsr-xr-x root root /usr/bin/passwd
-rwsr-xr-x root root /usr/bin/su
-rwxr-sr-x root shadow /usr/bin/chage
-rwsr-xr-x root root /usr/local/bin/whoami-test.sh     # <- remove this
```

The correct mechanism for delegated privilege is `sudo` with a tightly scoped rule, validated with `visudo -c`:

```
# /etc/sudoers.d/artifact-gc  (mode 0440, root:root)
Cmnd_Alias ARTIFACT_GC = /usr/local/sbin/artifact-gc
%platform-ops ALL=(root) NOPASSWD: ARTIFACT_GC
```

```
$ sudo visudo -cf /etc/sudoers.d/artifact-gc
/etc/sudoers.d/artifact-gc: parsed OK
```

Two hardening requirements when a script is reachable through `sudo`:

1. Set `PATH` explicitly at the top of the script; do not trust the inherited one.
2. Accept no argument that is interpolated into a command without validation — `sudo artifact-gc -p '/; rm -rf /'` must be rejected by the `case` validator, not executed.

---

## 12. Production artifacts, complete and unabridged

### 12.1 systemd service + timer + failure mail

Replacing cron with systemd gives you dependency ordering, resource limits, sandboxing, a real failure signal and journald integration. This is the full set.

`/etc/systemd/system/artifact-gc.service`:

```ini
[Unit]
Description=Garbage-collect build artifacts older than the retention window
Documentation=man:artifact-gc(8)
After=network-online.target local-fs.target
Wants=network-online.target
OnFailure=unit-failure-mail@%n.service
StartLimitIntervalSec=3600
StartLimitBurst=3

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/artifact-gc -d 30 -p /var/lib/artifacts
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LC_ALL=C
Environment=MAILTO=root
User=root
Group=root

# Failure semantics
TimeoutStartSec=900
SuccessExitStatus=0
Restart=no

# Sandboxing: the script needs only its artifact root.
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ReadWritePaths=/var/lib/artifacts /run/lock
RestrictAddressFamilies=AF_UNIX
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryMax=512M
CPUQuota=50%

# Observability
StandardOutput=journal
StandardError=journal
SyslogIdentifier=artifact-gc

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/artifact-gc.timer`:

```ini
[Unit]
Description=Daily artifact garbage collection
Documentation=man:artifact-gc(8)

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=600
Persistent=true
AccuracySec=1min
Unit=artifact-gc.service

[Install]
WantedBy=timers.target
```

`RandomizedDelaySec` spreads the fleet so 400 nodes do not hit shared storage at the same second. `Persistent=true` runs a missed occurrence after the node boots — the property cron lacks.

`/etc/systemd/system/unit-failure-mail@.service`:

```ini
[Unit]
Description=Mail root about the failure of unit %i
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/unit-failure-mail %i
User=root
Group=root
```

`/usr/local/sbin/unit-failure-mail`:

```sh
#!/bin/sh
#
# Mail root a full post-mortem for a failed systemd unit.
# Invoked as: unit-failure-mail <unit-name>   (from OnFailure=unit-failure-mail@%n.service)
#
set -eu

unit=${1:?usage: unit-failure-mail <unit>}
host=$(uname -n)
to=${MAILTO:-root}

body=$(
    printf 'Unit %s failed on %s at %s\n\n' \
        "$unit" "$host" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '=== systemctl status ===\n'
    systemctl status --full --no-pager --lines=0 "$unit" 2>&1 || true

    printf '\n=== properties ===\n'
    systemctl show "$unit" \
        --property=Result,ExecMainStatus,ExecMainCode,NRestarts,ActiveEnterTimestamp \
        2>&1 || true

    printf '\n=== last 100 journal lines ===\n'
    journalctl --unit="$unit" --no-pager --lines=100 2>&1 || true
)

if command -v sendmail >/dev/null 2>&1; then
    {
        printf 'To: %s\n' "$to"
        printf 'Subject: [%s] systemd unit FAILED: %s\n' "$host" "$unit"
        printf 'Auto-Submitted: auto-generated\n'
        printf '\n%s\n' "$body"
    } | /usr/sbin/sendmail -t
elif command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "[$host] systemd unit FAILED: $unit" "$to"
else
    printf '%s\n' "$body" | logger -t unit-failure-mail -p daemon.err
    exit 1
fi
```

Deployment and verification:

```
$ sudo install -D -o root -g root -m 0755 unit-failure-mail /usr/local/sbin/unit-failure-mail
$ sudo install -D -o root -g root -m 0644 artifact-gc.service /etc/systemd/system/artifact-gc.service
$ sudo install -D -o root -g root -m 0644 artifact-gc.timer   /etc/systemd/system/artifact-gc.timer
$ sudo install -D -o root -g root -m 0644 unit-failure-mail@.service /etc/systemd/system/unit-failure-mail@.service

$ sudo systemd-analyze verify /etc/systemd/system/artifact-gc.service
$ echo $?
0

$ sudo systemctl daemon-reload
$ sudo systemctl enable --now artifact-gc.timer
Created symlink /etc/systemd/system/timers.target.wants/artifact-gc.timer → /etc/systemd/system/artifact-gc.timer.

$ systemctl list-timers artifact-gc.timer
NEXT                        LEFT     LAST PASSED UNIT              ACTIVATES
Thu 2026-08-27 03:23:41 UTC 15h left n/a  n/a    artifact-gc.timer artifact-gc.service

$ sudo systemctl start artifact-gc.service
$ systemctl show artifact-gc.service -p Result -p ExecMainStatus
Result=success
ExecMainStatus=0

$ journalctl -u artifact-gc.service -n 3 --no-pager
Aug 26 12:14:02 node01 systemd[1]: Starting Garbage-collect build artifacts...
Aug 26 12:14:03 node01 artifact-gc[41883]: 2026-08-26T12:14:03Z artifact-gc: ok: freed 184320 kB under /var/lib/artifacts (retention 30d)
Aug 26 12:14:03 node01 systemd[1]: Finished Garbage-collect build artifacts.
```

Prove the failure path actually fires — an untested alerting path is not an alerting path:

```
$ sudo ARTIFACT_ROOT=/nonexistent systemd-run --unit=gc-failtest \
    --property=OnFailure=unit-failure-mail@gc-failtest.service \
    /usr/local/sbin/artifact-gc -p /nonexistent
Running as unit: gc-failtest.service

$ systemctl show gc-failtest.service -p Result -p ExecMainStatus
Result=exit-code
ExecMainStatus=66

$ journalctl -u unit-failure-mail@gc-failtest.service -n 2 --no-pager
Aug 26 12:16:41 node01 systemd[1]: Starting Mail root about the failure of unit gc-failtest.service...
Aug 26 12:16:42 node01 systemd[1]: Finished Mail root about the failure of unit gc-failtest.service.

$ sudo mail -H
>N  1 root  Wed Aug 26 12:16  38/1402  [node01] systemd unit FAILED: gc-failtest.service
```

### 12.2 Kubernetes: ConfigMap-delivered script + CronJob

Full manifest, no elisions.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-jobs
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: artifact-gc
  namespace: platform-jobs
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: artifact-gc-script
  namespace: platform-jobs
  labels:
    app.kubernetes.io/name: artifact-gc
    app.kubernetes.io/component: batch
data:
  artifact-gc.sh: |
    #!/bin/sh
    #
    # Artifact garbage collector, container edition.
    # No MTA exists in this image: the failure channel is (a) a non-zero exit,
    # which marks the Job failed and is scraped by kube-state-metrics, and
    # (b) structured stderr, which the log pipeline ingests.
    #
    # Exit codes: 0 ok | 1 gc failure | 64 usage | 66 bad root | 69 unavailable
    #
    set -eu

    PROG=artifact-gc
    ROOT=${ARTIFACT_ROOT:?ARTIFACT_ROOT must be set}
    DAYS=${ARTIFACT_MAX_AGE_DAYS:-30}
    ALERT_URL=${ALERTMANAGER_URL:-}
    NODE=${NODE_NAME:-unknown}
    POD=${POD_NAME:-unknown}

    log() {
        # One JSON object per line: parseable by any log pipeline.
        printf '{"ts":"%s","level":"%s","prog":"%s","pod":"%s","node":"%s","msg":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$PROG" "$POD" "$NODE" "$2" >&2
    }

    die() {
        log error "$1"
        [ -n "$ALERT_URL" ] && alert "$1"
        exit "${2:-1}"
    }

    alert() {
        command -v curl >/dev/null 2>&1 || return 0
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
             -d "[{\"labels\":{\"alertname\":\"ArtifactGCFailed\",\"severity\":\"warning\",\"pod\":\"$POD\",\"node\":\"$NODE\"},\"annotations\":{\"description\":\"$1\"}}]" \
             "$ALERT_URL/api/v2/alerts" >/dev/null 2>&1 || true
    }

    case "$DAYS" in
        ''|*[!0-9]*) die "invalid ARTIFACT_MAX_AGE_DAYS: $DAYS" 64 ;;
    esac
    [ -d "$ROOT" ] || die "artifact root is not a directory: $ROOT" 66

    workdir=$(mktemp -d) || die "mktemp failed" 69
    trap 'rm -rf "$workdir"' EXIT INT TERM HUP

    errlog=$workdir/stderr
    before=$(du -sk "$ROOT" 2>/dev/null | awk '{print $1+0}')

    log info "starting gc: root=$ROOT retention=${DAYS}d size=${before}kB"

    set +e
    find "$ROOT" -mindepth 1 -type f -mtime "+$DAYS" -delete 2>"$errlog"
    rc=$?
    set -e

    after=$(du -sk "$ROOT" 2>/dev/null | awk '{print $1+0}')
    freed=$(( before - after ))

    if [ "$rc" -ne 0 ]; then
        while IFS= read -r line; do log error "find: $line"; done < "$errlog"
        die "gc failed rc=$rc freed=${freed}kB" "$rc"
    fi

    # Prune now-empty directories, best effort.
    find "$ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    log info "ok: freed ${freed}kB remaining=${after}kB"
    exit 0
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: artifacts
  namespace: platform-jobs
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 200Gi
  storageClassName: nfs-csi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: artifact-gc
  namespace: platform-jobs
  labels:
    app.kubernetes.io/name: artifact-gc
    app.kubernetes.io/component: batch
spec:
  schedule: "17 3 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  suspend: false
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 1800
      ttlSecondsAfterFinished: 86400
      template:
        metadata:
          labels:
            app.kubernetes.io/name: artifact-gc
          annotations:
            kubectl.kubernetes.io/default-container: gc
        spec:
          restartPolicy: Never
          serviceAccountName: artifact-gc
          automountServiceAccountToken: false
          terminationGracePeriodSeconds: 30
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: gc
              image: busybox:1.36.1
              imagePullPolicy: IfNotPresent
              command:
                - /bin/sh
                - /scripts/artifact-gc.sh
              env:
                - name: ARTIFACT_ROOT
                  value: /artifacts
                - name: ARTIFACT_MAX_AGE_DAYS
                  value: "30"
                - name: ALERTMANAGER_URL
                  value: http://alertmanager.monitoring.svc.cluster.local:9093
                - name: NODE_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: spec.nodeName
                - name: POD_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop:
                    - ALL
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
                limits:
                  cpu: 500m
                  memory: 256Mi
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: artifacts
                  mountPath: /artifacts
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: scripts
              configMap:
                name: artifact-gc-script
                defaultMode: 0555
            - name: artifacts
              persistentVolumeClaim:
                claimName: artifacts
            - name: tmp
              emptyDir:
                medium: Memory
                sizeLimit: 32Mi
```

Four decisions in that manifest exist specifically because of shell semantics:

* **`command: ["/bin/sh", "/scripts/artifact-gc.sh"]`, not `["/scripts/artifact-gc.sh"]`.** A ConfigMap volume mount is a symlink farm into `..data/`; `defaultMode: 0555` does grant execute, but with `readOnlyRootFilesystem` and some CSI/mount configurations the exec bit can be lost. Invoking the interpreter explicitly removes the dependency on the mode bit entirely — and makes the shebang irrelevant, which is why the script must be POSIX `sh`: the image is BusyBox and `/bin/sh` is `ash`.
* **`ARTIFACT_ROOT=${ARTIFACT_ROOT:?...}`** turns a missing env var into an immediate, loud failure instead of `find  -mindepth 1 -delete` running against the CWD.
* **`tmp` as an `emptyDir`** because `readOnlyRootFilesystem: true` makes `mktemp` fail otherwise — that is the `69 EX_UNAVAILABLE` path.
* **`concurrencyPolicy: Forbid`** is the container-native replacement for `flock`. Without it, a slow run overlapping the next schedule produces two processes deleting from the same PVC.

Applying and verifying:

```
$ kubectl apply -f artifact-gc.yaml
namespace/platform-jobs created
serviceaccount/artifact-gc created
configmap/artifact-gc-script created
persistentvolumeclaim/artifacts created
cronjob.batch/artifact-gc created

$ kubectl -n platform-jobs get cronjob artifact-gc
NAME          SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
artifact-gc   17 3 * * *    Etc/UTC    False     0        <none>          12s

$ kubectl -n platform-jobs create job --from=cronjob/artifact-gc artifact-gc-manual-001
job.batch/artifact-gc-manual-001 created

$ kubectl -n platform-jobs wait --for=condition=complete job/artifact-gc-manual-001 --timeout=300s
job.batch/artifact-gc-manual-001 condition met

$ kubectl -n platform-jobs logs job/artifact-gc-manual-001
{"ts":"2026-08-26T12:31:08Z","level":"info","prog":"artifact-gc","pod":"artifact-gc-manual-001-x4k2n","node":"worker-02","msg":"starting gc: root=/artifacts retention=30d size=194580kB"}
{"ts":"2026-08-26T12:31:11Z","level":"info","prog":"artifact-gc","pod":"artifact-gc-manual-001-x4k2n","node":"worker-02","msg":"ok: freed 41220kB remaining=153360kB"}

$ kubectl -n platform-jobs get job artifact-gc-manual-001 -o jsonpath='{.status.succeeded}{"\n"}'
1
```

And the failure path, which must be exercised deliberately:

```
$ kubectl -n platform-jobs create job gc-failtest \
    --from=cronjob/artifact-gc --dry-run=client -o yaml \
  | sed 's|value: /artifacts|value: /nonexistent|' \
  | kubectl apply -f -
job.batch/gc-failtest created

$ kubectl -n platform-jobs get pods -l job-name=gc-failtest
NAME                READY   STATUS   RESTARTS   AGE
gc-failtest-9dm7q   0/1     Error    0          14s

$ kubectl -n platform-jobs logs job/gc-failtest
{"ts":"2026-08-26T12:33:02Z","level":"error","prog":"artifact-gc","pod":"gc-failtest-9dm7q","node":"worker-01","msg":"artifact root is not a directory: /nonexistent"}

$ kubectl -n platform-jobs get pod gc-failtest-9dm7q \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
66
```

Exit code 66 arrives intact at the container status. That is the whole point of section 4 made concrete: the shell's integer is the platform's control signal.

### 12.3 Container entrypoint: `exec` and PID 1

```sh
#!/bin/sh
#
# /entrypoint.sh — render config from the environment, then hand off to the app.
#
set -eu

: "${APP_PORT:=8080}"
: "${APP_LOG_LEVEL:=info}"
: "${DATABASE_URL:?DATABASE_URL must be set}"

CONF=/etc/app/config.yaml

log() { printf '{"ts":"%s","level":"%s","msg":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }

# Refuse to start rather than start misconfigured.
case "$APP_PORT" in
    ''|*[!0-9]*) log error "APP_PORT is not numeric: $APP_PORT"; exit 78 ;;
esac
case "$APP_LOG_LEVEL" in
    debug|info|warn|error) ;;
    *) log error "invalid APP_LOG_LEVEL: $APP_LOG_LEVEL"; exit 78 ;;
esac

umask 0027
mkdir -p /var/run/app

cat > "$CONF" <<EOF
server:
  port: ${APP_PORT}
  shutdownGraceSeconds: 25
logging:
  level: ${APP_LOG_LEVEL}
  format: json
database:
  url: ${DATABASE_URL}
EOF

log info "config rendered at ${CONF}, starting: $*"

# CRITICAL: exec replaces this shell, so the application becomes PID 1 and
# receives SIGTERM directly from the container runtime. Without exec, the
# shell stays PID 1, ignores SIGTERM (non-interactive shells do not install
# a handler), and the pod is SIGKILLed after terminationGracePeriodSeconds.
exec "$@"
```

Proving it, which is the kind of check that turns a 30-second rolling update into a 3-second one:

```
$ docker run -d --name t1 --entrypoint /bin/sh myapp:1.4 -c '/usr/bin/app --serve'
9f2c1a...
$ docker exec t1 ps -o pid,comm
  PID COMMAND
    1 sh
    7 app
$ time docker stop t1
t1
real    0m10.284s          # <- SIGTERM ignored by the shell; SIGKILL after the timeout

$ docker run -d --name t2 --entrypoint /entrypoint.sh myapp:1.4 /usr/bin/app --serve
3a7e44...
$ docker exec t2 ps -o pid,comm
  PID COMMAND
    1 app
$ time docker stop t2
t2
real    0m0.412s
```

### 12.4 CI gate

`.github/workflows/shell-lint.yml`:

```yaml
name: shell-lint

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install linters
        run: |
          set -euo pipefail
          sudo apt-get update -qq
          sudo apt-get install -y --no-install-recommends shellcheck devscripts dash bats

      - name: Discover shell scripts
        id: discover
        run: |
          set -euo pipefail
          # Anything with a shell shebang, plus *.sh, excluding vendored trees.
          find . -path ./.git -prune -o -type f -print0 \
            | xargs -0 -r file --mime-type \
            | awk -F': ' '$2 ~ /x-shellscript/ {print $1}' \
            | sort -u > /tmp/scripts.txt
          printf 'found %d scripts\n' "$(wc -l < /tmp/scripts.txt)"
          cat /tmp/scripts.txt

      - name: Syntax check with the declared interpreter
        run: |
          set -euo pipefail
          rc=0
          while IFS= read -r f; do
            shebang=$(head -n 1 "$f")
            case "$shebang" in
              *bash*) bash -n "$f" || rc=1 ;;
              *)      dash -n "$f" || rc=1 ;;   # /bin/sh scripts must parse under dash
            esac
          done < /tmp/scripts.txt
          exit "$rc"

      - name: ShellCheck
        run: |
          set -euo pipefail
          xargs -r -a /tmp/scripts.txt shellcheck \
            --severity=warning \
            --enable=all \
            --exclude=SC2312 \
            --format=gcc

      - name: checkbashisms on /bin/sh scripts
        run: |
          set -euo pipefail
          rc=0
          while IFS= read -r f; do
            case "$(head -n 1 "$f")" in
              */bin/sh|*"env sh") checkbashisms -f "$f" || rc=1 ;;
            esac
          done < /tmp/scripts.txt
          exit "$rc"

      - name: Unit tests
        run: bats -r tests/
```

Two subtleties worth copying: `xargs -r` (do not run the linter with zero arguments, which would make ShellCheck read stdin and hang), and running `dash -n` against `#!/bin/sh` scripts so the CI parser is the same one production will use.

A matching `.git/hooks/pre-commit` catches it earlier and for free:

```sh
#!/bin/sh
set -eu

fail=0
git diff --cached --name-only --diff-filter=ACM -z \
| while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    case "$(file --mime-type -b -- "$f")" in
        text/x-shellscript) ;;
        *) continue ;;
    esac
    shellcheck --severity=warning -- "$f" || fail=1
    case "$(head -n 1 -- "$f")" in
        */bin/sh) dash -n -- "$f" || fail=1 ;;
        *bash)    bash -n -- "$f" || fail=1 ;;
    esac
done

exit "$fail"
```

---

## 13. Verification and failure diagnosis

### 13.1 The verification ladder

Run these in order. Each rung is cheaper than the one below it, and each catches a class the previous one cannot.

| Rung | Command | Catches | Cost |
|---|---|---|---|
| 0 | `head -c 2 f \| xxd` / `file f` | Missing shebang, CRLF, wrong file type | Instant |
| 1 | `sh -n f` / `bash -n f` | Syntax errors, unbalanced quotes, missing `fi`/`done` | Instant |
| 2 | `shellcheck f` | Unquoted expansions, `cd` without `\|\|`, SC2155, useless `cat`, ~400 patterns | Instant |
| 3 | `checkbashisms -f f` | bash-only constructs in a `#!/bin/sh` script | Instant |
| 4 | `dash f` (run under the real target shell) | Runtime dialect failures | Seconds |
| 5 | `sh -x f` with a rich `PS4` | Wrong expansion values, unexpected branch taken | Seconds |
| 6 | `bats` unit tests | Logic regressions, exit-code contract violations | Seconds |
| 7 | Deliberate failure injection in staging | Broken alerting path, wrong exit code surfaced to the supervisor | Minutes |

Rung 7 is the one that is always skipped and always the one that matters during an incident: an alert path that has never fired is an alert path that does not exist.

### 13.2 `bash -n` and `shellcheck` in practice

```
$ cat -n rotate.sh
     1  #!/bin/bash
     2  set -euo pipefail
     3  DIR=/var/log/app
     4  for f in $DIR/*.log; do
     5      if [ -s $f ]
     6          gzip -9 "$f"
     7      fi
     8  done

$ bash -n rotate.sh
rotate.sh: line 6: syntax error near unexpected token `gzip'
rotate.sh: line 6: `        gzip -9 "$f"'
```

Missing `; then`. Fix that, then:

```
$ shellcheck rotate.sh

In rotate.sh line 4:
for f in $DIR/*.log; do
         ^--^ SC2086 (info): Double quote to prevent globbing and word splitting.

Did you mean:
for f in "$DIR"/*.log; do

In rotate.sh line 5:
    if [ -s $f ]; then
            ^-- SC2086 (info): Double quote to prevent globbing and word splitting.

Did you mean:
    if [ -s "$f" ]; then

For more information:
  https://www.shellcheck.net/wiki/SC2086 -- Double quote to prevent globbing ...
```

The high-value ShellCheck codes to know by number:

| Code | Meaning |
|---|---|
| SC1090/SC1091 | Cannot follow a dynamic `source`; add `# shellcheck source=path` |
| SC2086 | Unquoted variable — word splitting and globbing |
| SC2046 | Unquoted `$(...)` — same |
| SC2006 | Backticks; use `$( )` |
| SC2115 | `rm -rf "$dir/"` when `$dir` may be empty; use `${dir:?}` |
| SC2155 | `local x=$(cmd)` masks the exit status |
| SC2164 | `cd` without `\|\| exit` |
| SC2181 | `if [ $? -eq 0 ]` — check the command directly |
| SC2148 | Missing shebang |
| SC30xx | POSIX-sh violations (only when `-s sh`) |

### 13.3 Tracing

```
$ export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
$ bash -x ./deploy.sh staging
+ deploy.sh:3:main: set -euo pipefail
+ deploy.sh:5:main: ENV=staging
+ deploy.sh:6:main: NS=app-staging
+ deploy.sh:8:main: resolve_image staging
+ deploy.sh:14:resolve_image: registry.internal/app
+ deploy.sh:14:resolve_image: tag=v1.4.2
+ deploy.sh:15:resolve_image: printf '%s:%s\n' registry.internal/app v1.4.2
+ deploy.sh:8:main: image=registry.internal/app:v1.4.2
+ deploy.sh:9:main: kubectl -n app-staging set image deploy/app app=registry.internal/app:v1.4.2
```

Because `set -x` prints commands **after** expansion, it prints secrets. Guard the sensitive region:

```sh
set +x
token=$(read_secret /run/secrets/api-token)
curl -fsS -H "Authorization: Bearer $token" "$url"
set -x
```

Better, in bash: `export BASH_XTRACEFD=9; exec 9>>/var/log/app/trace.log` sends the trace to a separate, restricted-permission file instead of the job's stdout.

Redirect a trace to a file portably:

```
$ sh -x ./job.sh 2>/tmp/job.trace
$ grep -n 'DIR=' /tmp/job.trace
12:+ DIR=
```
There is the bug: `DIR` expanded empty.

### 13.4 Diagnosis table

| Symptom | Probable cause | Confirming command | Fix |
|---|---|---|---|
| `bad interpreter: No such file or directory` and the path looks right | CRLF line endings | `file s.sh` shows "with CRLF line terminators" | `sed -i 's/\r$//' s.sh` |
| `bad interpreter` with `^M` visible | Same | `head -1 s.sh \| xxd` | Same |
| `Permission denied`, rc 126 | Execute bit missing, or `noexec` mount | `ls -l s.sh`; `findmnt -T s.sh -o TARGET,OPTIONS` | `chmod +x`, or move off the `noexec` filesystem |
| `command not found`, rc 127, works interactively | `PATH` differs under cron/systemd | `systemctl show u.service -p Environment`; add `env` to the cron line | Set `PATH=` in the unit/crontab, or use absolute paths |
| `[[: not found` | bashism under `dash` | `head -1 s.sh` | Rewrite as `[ ]` or change the shebang to `#!/bin/bash` |
| Script "succeeds" but does nothing | Pipeline masking status; `set -e` exemption | `echo "${PIPESTATUS[@]}"`; `bash -x` | `set -o pipefail`; check statuses explicitly |
| `rm -rf` removed the wrong tree | Unquoted/empty variable | ShellCheck SC2115 | `${dir:?}` and quote everything |
| Loop counter is 0 after the loop | `cmd \| while` created a subshell | `bash -x` shows the assignment happening | Redirect with `< file` or `< <(cmd)` |
| Last line of a file skipped | No trailing newline | `tail -c 1 f \| xxd` | `while read -r l \|\| [ -n "$l" ]` |
| Filenames with spaces processed as two items | `for f in $(ls)` | ShellCheck SC2045 | Glob or `find -exec ... +` |
| Job runs twice, corrupts data | No mutual exclusion | `pgrep -fa script` | `flock -n`; `concurrencyPolicy: Forbid` |
| Script in `/etc/cron.daily` never runs | Filename has a dot | `run-parts --test /etc/cron.daily` | Rename without extension |
| Pod takes the full grace period to stop | Shell is PID 1, no `exec` | `kubectl exec pod -- ps -o pid,comm` | `exec "$@"` in the entrypoint |
| `mktemp` fails in a container | `readOnlyRootFilesystem: true`, no writable `/tmp` | `kubectl logs` shows the error | Mount an `emptyDir` at `/tmp` |
| setuid script gives no privilege | Kernel ignores setuid on `#!` scripts | `./s.sh` prints the caller's uid | Use `sudo` with a scoped rule |
| Exit code 44 for 300 errors | `exit N` wraps mod 256 | `sh -c 'exit 300'; echo $?` | Return a fixed code, log the count |
| Cron mailed nothing on failure | No MTA; `MAILTO` unset | `journalctl -t CRON`; `mailq` | Install an MTA or switch to `OnFailure=` |

### 13.5 Unit-testing exit-code contracts with `bats`

`tests/artifact-gc.bats`:

```bash
#!/usr/bin/env bats

setup() {
    TESTROOT=$(mktemp -d)
    export ARTIFACT_ROOT="$TESTROOT"
    SCRIPT=${BATS_TEST_DIRNAME}/../sbin/artifact-gc
}

teardown() {
    rm -rf "$TESTROOT"
}

@test "exits 66 when the artifact root does not exist" {
    run "$SCRIPT" -p /definitely/not/here
    [ "$status" -eq 66 ]
}

@test "exits 64 on a non-numeric retention" {
    run "$SCRIPT" -d thirty -p "$TESTROOT"
    [ "$status" -eq 64 ]
}

@test "removes files older than the retention window" {
    touch -d '60 days ago' "$TESTROOT/old.tar.gz"
    touch "$TESTROOT/new.tar.gz"
    run "$SCRIPT" -d 30 -p "$TESTROOT"
    [ "$status" -eq 0 ]
    [ ! -e "$TESTROOT/old.tar.gz" ]
    [ -e "$TESTROOT/new.tar.gz" ]
}

@test "handles filenames containing spaces and newlines" {
    touch -d '60 days ago' "$TESTROOT/an old file.tar.gz"
    run "$SCRIPT" -d 30 -p "$TESTROOT"
    [ "$status" -eq 0 ]
    [ ! -e "$TESTROOT/an old file.tar.gz" ]
}

@test "is a valid POSIX sh script" {
    run dash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}
```

```
$ bats tests/artifact-gc.bats
artifact-gc.bats
 ✓ exits 66 when the artifact root does not exist
 ✓ exits 64 on a non-numeric retention
 ✓ removes files older than the retention window
 ✓ handles filenames containing spaces and newlines
 ✓ is a valid POSIX sh script

5 tests, 0 failures
```

---

## 14. Exam-focused summary

**Shebang.** First line, `#!` in bytes 0–1, absolute interpreter path, at most one argument on Linux. `#!/bin/sh` on Debian/Ubuntu means `dash`, not bash. No shebang → `ENOEXEC` from `execve`. Bad interpreter → exit 126.

**Exit status.** `$?` after each foreground pipeline; 0 = success. `126` not executable, `127` not found, `128+N` killed by signal N. `exit N` wraps modulo 256. A pipeline's status is its **last** command's unless `pipefail` (bash) is set.

**Testing return values.** `if cmd; then`, `cmd && ok`, `cmd || fail`, `rc=$?` captured immediately. Never `if [ $? -eq 0 ]` — test the command itself.

**`test` / `[`.** Same builtin; `[` needs a closing `]`. Quote every operand. Files: `-e -f -d -r -w -x -s -L`. Strings: `-z -n = !=`. Integers: `-eq -ne -lt -le -gt -ge`. Combine with `&&`/`||` between separate `[ ]`, not with `-a`/`-o`.

**Loops.** `for v in list; do … done`; `while cmd; do … done`; `until cmd; do … done`; `break`/`continue` with optional level. `for arg; do` iterates `"$@"`. `while IFS= read -r line; do … done < file` for line input.

**Command substitution.** `$(cmd)` — nestable, preferred. `` `cmd` `` — legacy. Both strip trailing newlines. Always quote the result.

**`seq`.** `seq LAST`, `seq FIRST LAST`, `seq FIRST STEP LAST`, `-w` zero-pad, `-s` separator, `-f` format.

**`set`.** `-e` exit on error, `-u` error on unset, `-x` trace, `-n` parse only, `-v` verbose, `-o pipefail` (bash). `set -- a b c` replaces the positional parameters.

**`declare`.** bash builtin: `declare -i` integer, `-r` readonly, `-a` array, `-A` associative array, `-x` export, `-f` function, `-p` print. Not POSIX — the portable equivalents are `readonly` and `export`.

**`exec`.** With a command: replaces the shell, keeping the PID. Without a command: applies redirections to the current shell permanently (`exec 3<file`, `exec >log 2>&1`).

**`.` (source).** Runs a file in the current shell; `source` is the bash synonym. Searches `PATH` if the argument has no slash — always write `. ./file`.

**Functions.** `name() { …; }` is the portable form. `return N` sets the status; `$1…$@` are the function's args; `local` scopes a variable.

**Conditional mail to root.** cron mails any job output to `MAILTO` (default: the crontab owner); the idiom is `cmd >/dev/null` so only stderr generates mail. Explicitly: `printf … | mail -s "subject" root`, or `sendmail -t` with `To:`/`Subject:` headers. In systemd: `OnFailure=`. In a container: exit non-zero and log to stderr.

**Locations.** `/usr/local/bin` (all users), `/usr/local/sbin` (root), `~/bin` or `~/.local/bin` (per user), `/etc/cron.{hourly,daily,weekly,monthly}` (run by `run-parts`, filenames without dots), `/etc/cron.d` (crontab format), `/etc/init.d` (SysV), `/etc/systemd/system` (local units). Never `/usr/bin` or `/usr/sbin` — those belong to the package manager.

**Permissions.** `0755` for executables, `0644` for sourced libraries, `root:root` for system scripts. **The setuid bit is ignored on `#!` scripts on Linux**; use `sudo` with a scoped `Cmnd_Alias` instead.

---

## 15. References

**LPI — certification objectives**
- LPIC-1 Exam 102 objectives, v5.0 (contains Topic 105.2): https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 Exam 101 objectives, v5.0: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Standards**
- POSIX.1-2024 (IEEE Std 1003.1-2024) — Shell Command Language: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html
- POSIX — `test` utility: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/test.html
- POSIX — `read` utility: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/read.html
- POSIX — `getopts` utility: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/getopts.html
- Filesystem Hierarchy Standard 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html

**GNU**
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- Bash — The Set Builtin: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- Bash — Shell Parameter Expansion: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
- Bash — Exit Status: https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html
- GNU Coreutils Manual (`seq`, `install`, `env`, `mktemp`): https://www.gnu.org/software/coreutils/manual/coreutils.html
- GNU Mailutils Manual: https://mailutils.org/manual/mailutils.html

**Shells and tooling**
- dash — Debian Almquist Shell: https://manpages.debian.org/stable/dash/dash.1.en.html
- ShellCheck: https://www.shellcheck.net/ · wiki index: https://www.shellcheck.net/wiki/
- `checkbashisms` (devscripts): https://manpages.debian.org/stable/devscripts/checkbashisms.1.en.html
- Bats — Bash Automated Testing System: https://bats-core.readthedocs.io/
- `run-parts(8)`: https://manpages.debian.org/stable/debianutils/run-parts.8.en.html
- `flock(1)`, util-linux: https://man7.org/linux/man-pages/man1/flock.1.html

**Kernel and system interfaces**
- `execve(2)` — interpreter scripts: https://man7.org/linux/man-pages/man2/execve.2.html
- `sudoers(5)`: https://www.sudo.ws/docs/man/sudoers.man/
- `crontab(5)`: https://man7.org/linux/man-pages/man5/crontab.5.html

**systemd**
- `systemd.service(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.unit(5)` — `OnFailure=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd.timer(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
- `systemd.exec(5)` — sandboxing directives: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html

**Kubernetes**
- CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Jobs — `backoffLimit`, `activeDeadlineSeconds`: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- ConfigMaps as volumes: https://kubernetes.io/docs/concepts/configuration/configmap/
- Security Context: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Container lifecycle and termination: https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/