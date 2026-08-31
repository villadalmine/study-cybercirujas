# LPIC-1 · Topic 103.1 — Work on the Command Line

**Exams:** 101-500 (Topic 103, *GNU and Unix Commands*) · **Weight:** 6.25
**Key knowledge areas:** single commands and one-line command sequences · shell environment (define, reference, export) · command history · invoking commands inside and outside `$PATH`
**Terms and utilities:** `bash`, `echo`, `env`, `export`, `pwd`, `set`, `unset`, `type`, `which`, `man`, `uname`, `history`, `.bash_history`, quoting

---

## 1. Motivation: the architectural problem behind "just run a command"

Every incident review that ends with *"but it works on my machine"* is, mechanically, a **process environment** problem. There is no magic in it. The shell is a userland program whose entire job is to turn a line of text into a call to `execve(2)`:

```c
int execve(const char *pathname, char *const argv[], char *const envp[]);
```

Three inputs. That is the whole contract with the kernel. Everything you will read in this topic — `PATH` resolution, quoting, `export`, `env -i`, hashing, history expansion — exists to control what ends up in those three arguments, and **who inherits them next**.

The production failure modes that follow from getting this wrong are not academic:

| Failure in production | Root cause in 103.1 terms |
|---|---|
| A CI job passes locally, fails in the runner with `command not found` | `PATH` differs; the interactive shell sourced `~/.bashrc`, the non-interactive runner did not |
| A `systemd` service starts by hand but fails at boot | `ExecStart=` used a relative name; `systemd` never performs `PATH` lookup the way an interactive shell does, and its environment is minimal by design |
| A cron job silently produces empty output at 03:00 | cron gives you `PATH=/usr/bin:/bin` and no `LANG`; a locale-dependent `sort`/`date` changes behaviour |
| A deploy script deletes the wrong tree | Unquoted variable containing a space underwent word splitting and pathname expansion |
| An API token appears in `~/.bash_history` and is later scraped from a backup | `HISTCONTROL` not set; the operator typed the secret with no leading space |
| `rm` fails with `Argument list too long` on a log rotation host | Combined `argv[]` + `envp[]` exceeded the kernel's `MAX_ARG_STRLEN`/stack-derived limit |
| A binary exists, is executable, and still reports `No such file or directory` | Stale bash hash table, or a missing **ELF interpreter** — the ENOENT refers to the loader, not to your file |

An SRE who understands the `fork(2)` → `execve(2)` → `environ(7)` chain debugs all seven of these with the same mental model. That model is what this topic buys you, and it is why a "beginner" objective carries real weight on the exam and far more weight in practice.

---

## 2. The mechanics: what actually happens when you press Enter

### 2.1 The lifecycle of one command

```
  read line  ──► history expansion (interactive only)
             ──► alias expansion
             ──► lexical analysis / tokenization  (metacharacters, quoting)
             ──► parsing into commands, pipelines, lists
             ──► expansions (see §5.1)
             ──► redirection setup
             ──► command resolution (see §3)
             ──► builtin?  run in the current shell process
                 function? run in the current shell process
                 external? fork(2) ──► [child] execve(2) ──► exec'd program
                                  ──► [parent] wait4(2) ──► $? set from exit status
```

Two consequences that the exam loves and that production punishes:

1. **Builtins run in the current shell.** `cd`, `export`, `unset`, `read`, `pwd`, `history` *must* be builtins, because a child process cannot change its parent's working directory or environment. This is not an implementation choice; it is a consequence of the process model.
2. **Everything an external command receives, it received at `execve` time.** The environment is a *snapshot copied into the new process image*, not a shared, live namespace. Changing `export FOO=bar` after a program started has exactly zero effect on that running program.

Verify both claims directly:

```console
$ echo $$          # PID of the current shell
4471

$ pwd
/home/sre

$ ( cd /tmp; pwd )   # subshell: a fork, no exec
/tmp

$ pwd                # parent is untouched
/home/sre

$ echo $$ ; ( echo $$ ; echo $BASHPID )
4471
4471
9330
```

`$$` is deliberately inherited by subshells (it is the *shell's* PID as the script sees it); `$BASHPID` is the real, current PID. Confusing the two produces PID files that point at a process that no longer exists — a classic cause of "the service is up but the health check kills it".

### 2.2 Proving the environment is a snapshot

```console
$ sleep 600 &
[1] 9412

$ tr '\0' '\n' < /proc/9412/environ | grep -c .
34

$ export CANARY=hello
$ tr '\0' '\n' < /proc/9412/environ | grep CANARY || echo "not present"
not present
```

`/proc/<pid>/environ` is the NUL-separated block the kernel placed on the process stack at `execve` time. It does not update. (A process may modify its own copy via `putenv(3)`/`setenv(3)`, and glibc will move the block off the original stack region when it grows — which is exactly why `/proc/<pid>/environ` can silently diverge from a long-running daemon's real state. Trust it as *"what it was launched with"*, never as *"what it currently believes"*.)

---

## 3. Command resolution: `type`, `which`, `command -v`, and the hash table

### 3.1 The resolution order bash applies

For a simple command word, bash resolves in this fixed order:

| # | Category | Example | Bypass it with |
|---|---|---|---|
| 1 | **Alias** (interactive shells only, unless `shopt -s expand_aliases`) | `alias ll='ls -l'` | `\ll`, `'ll'`, `command ll` |
| 2 | **Keyword** (reserved word) | `if`, `for`, `while`, `[[`, `time`, `function` | quoting: `\time` |
| 3 | **Function** | `deploy() { ...; }` | `command deploy` |
| 4 | **Builtin** | `cd`, `echo`, `pwd`, `test`, `kill` | `env echo`, `/bin/echo`, `enable -n echo` |
| 5 | **Hashed path** | remembered from a previous lookup | `hash -r`, `set +h` |
| 6 | **`$PATH` search**, left to right, first match wins | `/usr/local/bin/kubectl` | absolute or `./relative` path |

Anything containing a `/` skips steps 1–6 entirely and goes straight to `execve` on that path. This is the entire reason `./script.sh` exists as an idiom: `.` is not (and must not be) in `PATH`.

### 3.2 Interrogating the resolution — tool comparison

```console
$ type -a echo
echo is a shell builtin
echo is /usr/bin/echo
echo is /bin/echo

$ type -t if
keyword

$ type -t ll
alias

$ type -P echo          # force a PATH-only lookup, ignore builtin/function/alias
/usr/bin/echo

$ command -v systemctl
/usr/bin/systemctl

$ command -V systemctl
systemctl is /usr/bin/systemctl

$ which -a python3
/usr/local/bin/python3
/usr/bin/python3
```

| Tool | Nature | Sees builtins/functions/aliases? | Uses the caller's real shell state? | Portability | Verdict for scripts |
|---|---|---|---|---|---|
| `type` | bash builtin | **Yes** (`-a` shows all, `-t` prints the category) | Yes | bash/ksh/zsh; not POSIX-portable output | Best for **humans debugging** |
| `command -v` | POSIX shell builtin | **Yes** | Yes | POSIX — portable everywhere | **Use this in scripts** |
| `which` | external binary (or a csh-era script) | **No** — only `$PATH` files | No: it re-reads `$PATH` from its own environment | Non-standard, behaviour differs per distro; Fedora has deprecated the `which` package in favour of `command -v` | Avoid in new code; **know it for the exam** |
| `whereis` | external | No; searches hard-coded standard dirs | No | util-linux | Locating binary + source + man page |
| `hash` | bash builtin | Shows only the remembered-path cache | Yes | bash | Diagnosing stale-path bugs |

**Why `which` misleads you in exactly the moment you need it:** it is a separate process. It cannot see that your shell has a function named `kubectl` shadowing the binary, and it re-reads `PATH` from *its own* copy of the environment. If you changed `PATH` without exporting it, `which` and your shell disagree:

```console
$ PATH=/opt/toolchain/bin:$PATH        # assignment only — NOT exported
$ type -P mytool
/opt/toolchain/bin/mytool
$ which mytool
/usr/bin/which: no mytool in (/usr/bin:/bin:/usr/sbin:/sbin)
```

That is not a bug. `PATH` was already exported by the login process, so re-assigning it *does* update the exported value in bash — but the example above works because `PATH` retains its export attribute. Where the divergence really bites is a shell function or a builtin. Prefer `type -a`.

### 3.3 The hash table — the "file exists but bash says it doesn't" bug

Bash caches successful `PATH` lookups. After a package upgrade relocates a binary, the cache is stale:

```console
$ hash
hits	command
   4	/usr/local/bin/kubectl
   1	/usr/bin/curl

$ sudo dnf -y upgrade kubectl        # binary moves to /usr/bin/kubectl
...
$ kubectl version --client
bash: /usr/local/bin/kubectl: No such file or directory

$ ls -l /usr/bin/kubectl
-rwxr-xr-x. 1 root root 54018048 Aug 12 09:31 /usr/bin/kubectl

$ hash -r                            # forget everything
$ kubectl version --client
Client Version: v1.31.4
```

| Command | Effect |
|---|---|
| `hash` | List the cache with hit counts |
| `hash -r` | Clear the whole cache |
| `hash -d kubectl` | Forget one entry |
| `hash -p /opt/bin/kubectl kubectl` | Pin a name to a path without a `PATH` search |
| `set +h` | Disable hashing entirely (useful in long-lived interactive shells during migrations; costs a `PATH` walk per command) |

**Production rule:** any automation that installs or relocates binaries and then invokes them in the *same* shell must call `hash -r` after the install step. This is a genuine, recurring cause of flaky CI jobs.

### 3.4 `PATH` as an attack surface

```console
$ echo "$PATH"
/home/sre/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

Three rules that belong in every hardening baseline:

1. **Never include `.`**, and never leave an empty field. An empty field means "current directory". All three of these are equivalent to putting `.` in `PATH`:
   `PATH=:/usr/bin` · `PATH=/usr/bin:` · `PATH=/usr/bin::/bin`
2. **Order is trust.** The first match wins, so writable early entries let any user who can write there shadow `ls` for everyone using that `PATH`.
3. **`sudo` deliberately does not trust your `PATH`.** With `Defaults secure_path` (the default on RHEL/Fedora/Debian), `sudo` *replaces* it:

```console
$ sudo grep -E 'secure_path|env_reset' /etc/sudoers
Defaults    env_reset
Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin

$ which terraform
/home/sre/.local/bin/terraform

$ sudo terraform version
sudo: terraform: command not found

$ sudo env "PATH=$PATH" terraform version     # explicit, auditable
Terraform v1.9.5

$ sudo -E printenv PATH                       # -E preserves env, subject to env_check/env_keep
/sbin:/bin:/usr/sbin:/usr/bin
```

Note the last one: `sudo -E` preserves most variables but `secure_path` still overrides `PATH`. Operators who "fix" this by deleting `secure_path` have converted a usability annoyance into a privilege-escalation vector. The correct fix is an absolute path or an explicit `sudo env "PATH=..."`.

---

## 4. Shell variables vs environment variables

### 4.1 The distinction

* A **shell variable** lives only in the shell process's own memory.
* An **environment variable** is a shell variable carrying the *export attribute*, which means bash copies it into `envp[]` at the next `execve`.

```console
$ LOCAL_ONLY=local
$ export EXPORTED=inherited

$ echo "$LOCAL_ONLY $EXPORTED"
local inherited

$ bash -c 'echo "child sees: [$LOCAL_ONLY] [$EXPORTED]"'
child sees: [] [inherited]
```

Set and export in one step, or add the attribute later — both are equivalent:

```console
$ export API_ENDPOINT=https://api.internal.example.com
$ API_TIMEOUT=30
$ export API_TIMEOUT
$ declare -x API_RETRIES=5           # declare -x is a synonym for export
$ export -p | grep API_
declare -x API_ENDPOINT="https://api.internal.example.com"
declare -x API_RETRIES="5"
declare -x API_TIMEOUT="30"
```

Removing:

```console
$ export -n API_TIMEOUT      # drop the export attribute, KEEP the shell variable
$ echo "$API_TIMEOUT"
30
$ bash -c 'echo "[$API_TIMEOUT]"'
[]

$ unset -v API_TIMEOUT       # remove the variable entirely
$ echo "[$API_TIMEOUT]"
[]

$ unset -f mydeployfunc      # -f removes a function, not a variable
```

Without `-v`/`-f`, `unset` tries the variable first and falls back to the function — ambiguous, so **always be explicit in scripts**.

### 4.2 Inspection tools — trade-offs

| Command | Shows | Includes non-exported shell vars? | Includes functions? | Can it *run* a command? | Notes |
|---|---|---|---|---|---|
| `env` | environment of a new process | No | No | **Yes** — `env [-i] [VAR=v]… cmd` | External binary (`/usr/bin/env`). The `cmd`-running form is its real power |
| `printenv` | environment | No | No | No | `printenv VAR` exits 1 if unset — scriptable existence test |
| `export -p` | exported vars, in re-usable `declare -x` form | No | No | No | Output can be `source`d |
| `set` (no args) | **all** shell vars + functions | **Yes** | Yes (bodies too, unless `set -o posix`) | No | Very noisy; pipe to `grep` |
| `declare -p` | all vars with their attributes | Yes | With `-f`/`-F` | No | Shows `-x` export, `-r` readonly, `-i` integer, `-a`/`-A` arrays |
| `compgen -v` | just the names | Yes | No | No | Ideal for diffing two shells |

```console
$ printenv HOME
/home/sre

$ printenv NOPE_NOT_SET; echo "exit=$?"
exit=1

$ declare -p PATH HOME LOCAL_ONLY
declare -x PATH="/home/sre/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
declare -x HOME="/home/sre"
declare -- LOCAL_ONLY="local"
```

The `--` on `LOCAL_ONLY` versus `-x` on `PATH` is the export attribute, visible. `declare -p` is the single most useful diagnostic in this whole topic.

### 4.3 `env` as a process launcher — the production-relevant use

`env` is not primarily a "print the environment" tool. It is a tool for **constructing** the environment of a child process:

```console
$ env DEPLOY_ENV=staging LOG_LEVEL=debug ./deploy.sh      # one-shot additions
```

```console
$ env -i /bin/bash --noprofile --norc -c 'echo "[$PATH]"; env | wc -l'
[]
0
```

`env -i` starts from a completely empty environment — and notice `PATH` is *empty*, not "default". Bash then falls back to a compiled-in default path only for its own lookups. This is the single best tool for reproducing "it fails in cron / in the container / under systemd":

```console
$ env -i HOME="$HOME" PATH=/usr/bin:/bin ./backup.sh
./backup.sh: line 12: aws: command not found
```

You have just reproduced the 03:00 cron failure at 11:00 in daylight, deterministically. Additional forms:

```console
$ env -u LD_PRELOAD -u LD_LIBRARY_PATH ./legacy-binary     # remove specific vars
$ env -C /srv/app ./run.sh                                 # chdir first (coreutils ≥ 8.28)
$ env -0 | tr '\0' '\n' | sort | head -3                   # NUL-safe listing
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
HOME=/home/sre
LANG=en_US.UTF-8
```

`env` is also why `#!/usr/bin/env python3` is the portable shebang: the kernel's shebang handler does **no `PATH` lookup**, so you delegate the lookup to `env`, which does one.

### 4.4 The environment boundary map

Knowing *where* the environment is re-established is the difference between guessing and diagnosing:

| Context | Environment source | Reads `~/.bashrc`? | Reads `/etc/profile`? |
|---|---|---|---|
| Login shell (console, `ssh host`) | PAM (`/etc/environment`, `pam_env`) → `/etc/profile` → `~/.bash_profile` | Only if `~/.bash_profile` sources it (the usual convention) | Yes |
| Interactive non-login (terminal in a desktop, `bash`) | inherited from the parent | **Yes** | No |
| Non-interactive (`ssh host 'cmd'`, script) | inherited; `$BASH_ENV` if set | No (bash skips it — the early `[ -z "$PS1" ] && return` guard in distro `bashrc`s exists for this) | No |
| `cron` job | crond's minimal env; `PATH=/usr/bin:/bin`, `SHELL=/bin/sh`, plus assignments in the crontab file itself | No | No |
| `systemd` service | `DefaultEnvironment=`, unit `Environment=`/`EnvironmentFile=`; **no shell at all** unless you invoke one | No | No |
| Container `ENTRYPOINT` | image `ENV` + runtime `-e`/`env:` | No (PID 1 is usually not a login shell) | No |
| Kubernetes container | image `ENV` + `env:`/`envFrom:` + injected service-discovery vars | No | No |

**`systemd` deserves an explicit warning:** `ExecStart=` requires an **absolute path** for the executable, performs no `PATH` search, and does not perform shell expansion. `ExecStart=/bin/sh -c 'foo | bar'` is how you opt back into a shell — and you should do so consciously, because you have just reintroduced quoting and `PATH` into your unit.

---

## 5. Quoting, expansion, and one-line command sequences

### 5.1 The expansion order — memorize this

Bash performs expansions in this order, and the order is *why* certain "obvious" things do not work:

| # | Expansion | Example | Notes |
|---|---|---|---|
| 1 | Brace | `file{1..3}.log` → `file1.log file2.log file3.log` | Purely textual; happens **before** variables, which is why `{1..$n}` does not work |
| 2 | Tilde | `~/logs`, `~root` | Only at the start of a word, unquoted |
| 3 | Parameter / variable | `$VAR`, `${VAR:-default}`, `${VAR#prefix}` | |
| 4 | Command substitution | `$(date -u +%F)`, backticks | Nestable with `$()`; backticks are not |
| 5 | Arithmetic | `$(( 3 * COUNT ))` | Integer only |
| 6 | Process substitution | `<(cmd)`, `>(cmd)` | bash extension; performed alongside 3–5 |
| 7 | **Word splitting** | on `$IFS` (default: space, tab, newline) | **Only on unquoted results of 3–6** |
| 8 | Pathname expansion (globbing) | `*.log`, `?`, `[a-z]` | Suppressed by `set -f` |
| 9 | Quote removal | | The literal quote characters are stripped last |

Steps 7 and 8 are the two that destroy production systems, and both are disabled by double-quoting.

### 5.2 Quoting rules

| Form | Protects from | Still expands | Canonical use |
|---|---|---|---|
| `\c` (backslash) | everything, one char | — | escaping a single metacharacter; line continuation with `\`+newline |
| `'single'` | **everything** | nothing at all — you cannot embed a `'` | literal strings, regexes, `awk`/`sed` programs, passwords |
| `"double"` | word splitting, globbing, most metacharacters | `$`, `` ` ``, `\`, and `!` (history, interactive shells) | **variable references — the default choice** |
| `$'ansi-c'` | — | interprets `\n`, `\t`, `\x41`, `\u00e9` | delimiters, control characters: `IFS=$'\n\t'` |
| `"$@"` | splitting of each element | expands to separate correctly-quoted words | forwarding script arguments — never `$*`, never bare `$@` |

Demonstration of why it matters:

```console
$ TARGET="/srv/app logs"
$ mkdir -p "$TARGET"

$ ls -d $TARGET
ls: cannot access '/srv/app': No such file or directory
ls: cannot access 'logs': No such file or directory

$ ls -d "$TARGET"
'/srv/app logs'
```

Now imagine the command was `rm -rf $TARGET` and `TARGET` came from a CI variable that was empty:

```console
$ TARGET=""
$ echo rm -rf $TARGET/          # dry-run with echo FIRST. Always.
rm -rf /
```

**Two habits that prevent this class of outage:** quote every expansion, and prefix destructive one-liners with `echo` until the output is exactly what you intend.

The `!` gotcha inside double quotes, interactive shells only:

```console
$ echo "Deploy failed!"
bash: !": event not found

$ echo 'Deploy failed!'
Deploy failed!

$ set +H                        # disable history expansion for this shell
$ echo "Deploy failed!"
Deploy failed!
```

### 5.3 One-line command sequences

| Operator | Semantics | Exit status of the list | Runs in a subshell? |
|---|---|---|---|
| `a ; b` | sequential, unconditional | status of `b` | no |
| `a && b` | run `b` only if `a` succeeded (`$? == 0`) | last executed | no |
| `a \|\| b` | run `b` only if `a` failed | last executed | no |
| `a \| b` | stdout of `a` → stdin of `b`; both start concurrently | status of `b` (unless `pipefail`) | **yes**, each stage |
| `a \|& b` | shorthand for `a 2>&1 \| b` | as above | yes |
| `a &` | background; shell does not wait | 0 immediately; real status via `wait %1` | yes |
| `( a; b )` | group in a **subshell** — env/cwd changes are discarded | last command | yes |
| `{ a; b; }` | group in the **current** shell (note the mandatory `;` and spaces) | last command | no |

```console
$ mkdir -p /srv/release && cd /srv/release && tar xzf /tmp/app.tgz && echo OK
OK

$ systemctl is-active nginx || systemctl start nginx
active

$ false | true ; echo "status=$?"
status=0

$ set -o pipefail
$ false | true ; echo "status=$?"
status=1

$ set +o pipefail
$ false | true ; echo "PIPESTATUS=(${PIPESTATUS[@]}) status=$?"
PIPESTATUS=(1 0) status=0
```

`PIPESTATUS` is the reason `curl … | jq …` silently "succeeds" when `curl` returns a 404 body. Any pipeline whose result you act upon needs `set -o pipefail` or an explicit `PIPESTATUS` check.

The exit-status convention itself is worth stating precisely: `0` = success; `1`–`125` = the program's own failure codes; `126` = found but not executable; `127` = **not found**; `128+N` = terminated by signal `N` (so `137` = `128+9`, SIGKILL — the OOM killer or a Kubernetes liveness probe).

```console
$ /etc/hostname ; echo $?
bash: /etc/hostname: Permission denied
126

$ nosuchcmd ; echo $?
bash: nosuchcmd: command not found
127

$ sleep 100 & kill -9 %1 ; wait ; echo $?
[1] 9871
[1]+  Killed                  sleep 100
137
```

### 5.4 The strict-mode preamble

Every non-trivial production script starts with this, and every line of it is a 103.1 concept:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
```

| Flag | Long form | Effect | Caveat you must know |
|---|---|---|---|
| `-e` | `errexit` | exit on any unhandled non-zero status | suppressed inside `if`, `&&`, `||`, `!` conditions — by design |
| `-u` | `nounset` | error on expanding an unset variable | `"${1:-}"` for optional args; combine with `${VAR:?message}` |
| `-o pipefail` | — | a pipeline fails if **any** stage fails | catches the `curl \| jq` trap |
| `-E` | `errtrace` | `ERR` traps are inherited by functions and subshells | needed for a working error handler |
| `-x` | `xtrace` | print each expanded command to stderr | the single best debugging switch; see §7.1 |
| `-f` | `noglob` | disable pathname expansion | for handling untrusted filenames |
| `IFS=$'\n\t'` | — | remove space as a word separator | makes accidental splitting far less destructive |

---

## 6. Command history

### 6.1 The variables that govern it

| Variable / setting | Purpose | Sane production value |
|---|---|---|
| `HISTFILE` | file the history is written to | `~/.bash_history` (default) |
| `HISTSIZE` | commands kept **in memory** | `10000` |
| `HISTFILESIZE` | lines kept **in the file** after truncation | `20000` |
| `HISTCONTROL` | `ignorespace` \| `ignoredups` \| `ignoreboth` \| `erasedups` | `ignoreboth:erasedups` |
| `HISTIGNORE` | colon-separated glob patterns never recorded | `'ls:ls *:cd:pwd:history:* --token=*:* --password=*'` |
| `HISTTIMEFORMAT` | strftime format shown by `history`; **also enables timestamps in the file** | `'%F %T '` |
| `shopt -s histappend` | append on exit instead of overwriting | **on** — mandatory with multiple terminals |
| `shopt -s cmdhist` | store a multi-line command as one history entry | on (default) |
| `set +o history` / `set +H` | disable recording / disable `!` expansion | for a secrets-handling session |

```console
$ cat >> ~/.bashrc <<'EOF'
# --- history hardening -------------------------------------------------
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
HISTIGNORE='ls:ls *:cd:cd *:pwd:history:clear:*--token=*:*--password=*:*AWS_SECRET*'
HISTTIMEFORMAT='%F %T '
shopt -s histappend cmdhist
PROMPT_COMMAND='history -a'
# -----------------------------------------------------------------------
EOF

$ exec bash -l
$ history 4
 1042  2026-08-26 11:04:12 systemctl status nginx
 1043  2026-08-26 11:04:31 journalctl -u nginx -n 50 --no-pager
 1044  2026-08-26 11:05:02 ss -ltnp
 1045  2026-08-26 11:05:19 history 4
```

With `HISTTIMEFORMAT` set, bash writes a comment line holding the epoch before each entry:

```console
$ tail -4 ~/.bash_history
#1756206302
ss -ltnp
#1756206319
history 4
```

### 6.2 The `history` builtin

| Invocation | Effect |
|---|---|
| `history` | print the in-memory list |
| `history 20` | last 20 entries |
| `history -a` | **append** new in-memory entries to `HISTFILE` (the key to multi-terminal sanity) |
| `history -r` | read `HISTFILE` and append to the in-memory list |
| `history -n` | read only the lines *not yet* read from `HISTFILE` |
| `history -w` | overwrite `HISTFILE` with the in-memory list |
| `history -c` | clear the in-memory list |
| `history -d 1043` | delete entry 1043 (`-d start-end` for a range in bash ≥ 5.0) |
| `history -p '!!'` | expand without executing — safe preview |
| `history -s 'cmd'` | inject an entry without running it |

**The multi-terminal problem.** By default, history is written only at shell exit, and the last shell to exit wins — commands from your other three terminals vanish. `shopt -s histappend` plus `PROMPT_COMMAND='history -a'` writes after every prompt. Add `history -n` to the `PROMPT_COMMAND` if you also want to *see* other sessions' commands; most operators do not, because it makes the up-arrow non-deterministic.

**The SIGKILL problem.** History is flushed by bash itself. A terminal window closed with `kill -9`, an OOM kill, or a hard reboot loses everything since the last write. `history -a` in `PROMPT_COMMAND` is the mitigation.

### 6.3 History expansion (`!`)

Performed by the **history library, before parsing** — which is why it happens even inside double quotes and why quoting cannot easily protect you.

| Designator | Meaning | Example |
|---|---|---|
| `!!` | previous command | `sudo !!` |
| `!n` / `!-n` | entry number *n* / *n* commands back | `!1043` |
| `!string` | most recent command starting with `string` | `!systemctl` |
| `!?string?` | most recent command *containing* `string` | `!?nginx?` |
| `!$` / `!^` / `!*` | last arg / first arg / all args of the previous command | `mkdir /srv/x && cd !$` |
| `!!:2` / `!!:2-3` | word 2 / words 2–3 of the previous command | |
| `^old^new^` | re-run the previous command with the first `old` replaced | |
| `!!:gs/old/new/` | global substitution | |
| `:p` modifier | **print, do not execute** | `!systemctl:p` |

```console
$ systemctl restart nginx
Failed to restart nginx.service: Access denied
$ sudo !!
sudo systemctl restart nginx
$ ^nginx^haproxy
sudo systemctl restart haproxy
```

**Safety rule for privileged shells:** always append `:p` first when reaching back into history with `!string`. `!rm:p` prints; `!rm` executes. The keystroke difference is two characters; the blast-radius difference is a filesystem. In the same spirit, `Ctrl-r` (reverse incremental search) is strictly safer than `!string`, because you *see* the command before Enter.

### 6.4 History is a security artifact

`~/.bash_history` is a plaintext file, mode `0600`, that is captured by every home-directory backup, every container image built from a live host, and every forensic image. Treat it accordingly:

```console
$ ls -l ~/.bash_history
-rw-------. 1 sre sre 48213 Aug 26 11:05 /home/sre/.bash_history

$ grep -nEi 'token|password|secret|apikey|BEGIN (RSA|OPENSSH) PRIVATE' ~/.bash_history
811:export VAULT_TOKEN=hvs.CAESIJ4xR2c...
```

Correct handling, in order of preference:

1. **Never type the secret.** Read it from a file or a secret manager: `export VAULT_TOKEN="$(vault login -field=token …)"`, `read -rs TOKEN`, `--password-stdin`.
2. **Prefix with a space** (requires `HISTCONTROL` to include `ignorespace`).
3. **Disable recording for the session:** `set +o history` … `set -o history`.
4. **Remediate after the fact:** `history -d <n>` then `history -w`, *and rotate the credential* — it is already in the file's on-disk history, in your terminal scrollback, and possibly in a backup. Deletion is cleanup, not remediation.

```console
$ read -rs -p "Vault token: " VAULT_TOKEN && export VAULT_TOKEN
Vault token: 
$ echo "${#VAULT_TOKEN}"      # verify length only, never the value
95
```

---

## 7. Infrastructure manifests: the same concepts, at platform scale

Everything above reappears verbatim in the manifests you write as a platform engineer. These are complete and syntactically valid.

### 7.1 Kubernetes — every way a container gets its environment

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shell-demo-config
  namespace: platform-training
data:
  LOG_LEVEL: "debug"
  API_ENDPOINT: "https://api.internal.example.com"
  # A whole file can be mounted and sourced by an entrypoint script.
  app.env: |
    DEPLOY_ENV=staging
    FEATURE_FLAGS=canary,tracing
---
apiVersion: v1
kind: Secret
metadata:
  name: shell-demo-secret
  namespace: platform-training
type: Opaque
stringData:
  API_TOKEN: "s3cr3t-rotate-me"
---
apiVersion: v1
kind: Pod
metadata:
  name: shell-env-demo
  namespace: platform-training
  labels:
    app.kubernetes.io/name: shell-env-demo
    app.kubernetes.io/component: training
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: shell
      image: debian:12-slim
      imagePullPolicy: IfNotPresent
      # command == ENTRYPOINT (execve argv[0]); args == CMD.
      # This is exec form: NO shell is involved, so $VAR is NOT expanded here
      # by a shell — Kubernetes performs its own $(VAR) substitution instead.
      command: ["/bin/bash"]
      args:
        - "-c"
        - |
          set -Eeuo pipefail
          echo "=== argv/exec identity ==="
          echo "pid=$$  bashpid=$BASHPID  shell=$0"
          echo "=== PATH resolution ==="
          echo "PATH=$PATH"
          command -v bash cat env || true
          echo "=== environment (sorted) ==="
          env | sort
          echo "=== sourcing a mounted env file ==="
          set -a                     # auto-export everything assigned from here
          . /etc/app/app.env
          set +a
          echo "DEPLOY_ENV=$DEPLOY_ENV FEATURE_FLAGS=$FEATURE_FLAGS"
          echo "=== secret length only, never the value ==="
          echo "API_TOKEN length: ${#API_TOKEN}"
          sleep 3600
      env:
        # 1. Literal value
        - name: TZ
          value: "UTC"
        # 2. Kubernetes-side $(VAR) interpolation — NOT shell expansion.
        #    Only previously-defined env entries are visible; use $$( ) to escape.
        - name: API_HEALTHCHECK
          value: "$(API_ENDPOINT)/healthz"
        # 3. From a ConfigMap key
        - name: LOG_LEVEL
          valueFrom:
            configMapKeyRef:
              name: shell-demo-config
              key: LOG_LEVEL
        # 4. From a Secret key
        - name: API_TOKEN
          valueFrom:
            secretKeyRef:
              name: shell-demo-secret
              key: API_TOKEN
        # 5. Downward API — pod metadata
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        # 6. Downward API — resources
        - name: CPU_LIMIT_MILLICORES
          valueFrom:
            resourceFieldRef:
              containerName: shell
              resource: limits.cpu
              divisor: "1m"
      envFrom:
        # Bulk import. Keys that are not valid shell identifiers are SKIPPED
        # and reported as an event — "app.env" above is one of those.
        - configMapRef:
            name: shell-demo-config
      volumeMounts:
        - name: app-env
          mountPath: /etc/app
          readOnly: true
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts_note: null   # (remove: illustrative only)
  volumes:
    - name: app-env
      configMap:
        name: shell-demo-config
        items:
          - key: app.env
            path: app.env
```

> Remove the `volumeMounts_note` line before applying; it is shown to mark where readers commonly duplicate the `volumeMounts` key. Duplicate keys in YAML are a silent last-wins overwrite in many parsers — `kubectl apply --validate=strict` catches it.

```console
$ kubectl apply -f shell-env-demo.yaml
configmap/shell-demo-config created
secret/shell-demo-secret created
pod/shell-env-demo created

$ kubectl -n platform-training logs shell-env-demo | head -20
=== argv/exec identity ===
pid=1  bashpid=1  shell=/bin/bash
=== PATH resolution ===
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
/bin/bash
/bin/cat
/usr/bin/env
=== environment (sorted) ===
API_ENDPOINT=https://api.internal.example.com
API_HEALTHCHECK=https://api.internal.example.com/healthz
API_TOKEN=s3cr3t-rotate-me
CPU_LIMIT_MILLICORES=500
HOME=/
HOSTNAME=shell-env-demo
KUBERNETES_PORT=tcp://10.96.0.1:443
...
```

Two observations that are pure 103.1:

* `HOME=/` — the container has no login shell, no `/etc/profile`, no `~/.bashrc`. Tools that write to `$HOME` will try to write to `/`, which `readOnlyRootFilesystem: true` refuses.
* `pid=1` — your shell **is** PID 1. It must reap zombies and forward signals, or `SIGTERM` on pod deletion goes nowhere and every rollout takes the full `terminationGracePeriodSeconds`. Use `exec` as the last line of an entrypoint script so the real program replaces the shell rather than being its child:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
: "${API_ENDPOINT:?API_ENDPOINT must be set}"     # fail fast, with a message
exec /usr/local/bin/app --endpoint "$API_ENDPOINT"   # replaces the shell: no extra PID
```

### 7.2 systemd — no shell, absolute paths, explicit environment

```ini
# /etc/systemd/system/shell-demo.service
[Unit]
Description=103.1 environment and PATH demonstration service
Documentation=https://www.freedesktop.org/software/systemd/man/systemd.exec.html
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=appsvc
Group=appsvc
WorkingDirectory=/srv/app

# systemd does NOT read /etc/profile, ~/.bashrc, or any shell startup file.
# The default PATH is compiled in; set it explicitly if you depend on it.
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="LOG_LEVEL=info" "TZ=UTC"

# EnvironmentFile syntax is NOT shell: no expansion, no command substitution,
# no `export`. A leading '-' makes a missing file non-fatal.
EnvironmentFile=-/etc/sysconfig/shell-demo
EnvironmentFile=-/run/secrets/shell-demo.env

# ExecStart requires an ABSOLUTE path. No PATH lookup, no globbing, no pipes.
ExecStart=/usr/local/bin/app --config /etc/app/config.yaml

# To use shell features you must invoke a shell explicitly and own the quoting:
# ExecStartPre=/bin/sh -c '/usr/bin/test -r /etc/app/config.yaml || exit 1'

Restart=on-failure
RestartSec=5s

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/app /var/log/app
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/sysconfig/shell-demo   (EnvironmentFile format — not a shell script)
LOG_LEVEL=debug
API_ENDPOINT=https://api.internal.example.com
# WRONG — these do NOT work here:
#   export FOO=bar          -> the variable would literally be named "export FOO"
#   PATH=$PATH:/opt/bin     -> "$PATH" is stored as a literal string
#   DATE=$(date +%F)        -> stored literally as "$(date +%F)"
```

Verify what the unit will actually receive, before it fails at 03:00:

```console
$ sudo systemd-analyze verify /etc/systemd/system/shell-demo.service
$ sudo systemctl daemon-reload
$ systemctl show shell-demo.service -p Environment -p ExecStart
Environment=PATH=/usr/local/bin:/usr/bin:/bin LOG_LEVEL=info TZ=UTC
ExecStart={ path=/usr/local/bin/app ; argv[]=/usr/local/bin/app --config /etc/app/config.yaml ; ... }

$ sudo systemd-run --pty --same-dir --wait --collect \
      --unit=envprobe --property=User=appsvc /usr/bin/env
Running as unit: envprobe.service
LANG=en_US.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
HOME=/var/lib/appsvc
LOGNAME=appsvc
USER=appsvc
SHELL=/bin/false
INVOCATION_ID=8f2c9a1e4d0b47f0b7c3f6a5d2e1c0b9
JOURNAL_STREAM=8:214437
```

`systemd-run` is the definitive answer to *"what environment will this service really have?"* — it is `env -i` for the systemd world.

### 7.3 Container image — shell form vs exec form

```dockerfile
# syntax=docker/dockerfile:1
FROM debian:12-slim

# ARG exists only at build time; ENV persists into the image metadata and
# therefore into every container's envp[] at execve.
ARG APP_VERSION=1.4.2
ENV APP_VERSION=${APP_VERSION} \
    LOG_LEVEL=info \
    PATH="/opt/app/bin:${PATH}" \
    LANG=C.UTF-8

RUN set -Eeuo pipefail \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/app
COPY --chmod=0755 entrypoint.sh /opt/app/bin/entrypoint.sh

# SHELL form: run through /bin/sh -c, so $VAR, pipes and globs work,
# and the shell becomes PID 1 with the program as its child.
#   ENTRYPOINT /opt/app/bin/entrypoint.sh          <-- avoid

# EXEC form: direct execve, no shell, no expansion, signals reach the process.
ENTRYPOINT ["/opt/app/bin/entrypoint.sh"]
CMD ["--serve"]

USER 65532:65532
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD ["/usr/bin/curl", "-fsS", "http://127.0.0.1:8080/healthz"]
```

```console
$ docker build --build-arg APP_VERSION=1.5.0 -t shelldemo:1.5.0 .
$ docker run --rm -e LOG_LEVEL=debug shelldemo:1.5.0 --version
$ docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' shelldemo:1.5.0
PATH=/opt/app/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
APP_VERSION=1.5.0
LOG_LEVEL=info
LANG=C.UTF-8
```

**Never put secrets in `ENV`.** `docker inspect` and every image-registry client can read them, and they persist in the image layer metadata forever.

### 7.4 A system-wide `PATH` drop-in, done correctly

```sh
# /etc/profile.d/99-platform-tools.sh
# Sourced by LOGIN shells only (via /etc/profile). Must be POSIX sh — this file
# is also read by dash-based /bin/sh login shells on Debian derivatives.

platform_tools_dir=/opt/platform/bin

if [ -d "$platform_tools_dir" ]; then
    case ":${PATH}:" in
        *":${platform_tools_dir}:"*) : ;;          # already present — idempotent
        *) PATH="${platform_tools_dir}:${PATH}" ;;
    esac
    export PATH
fi
unset platform_tools_dir
```

The `case` guard is the point: without it, every nested login shell prepends the directory again, and after a day of `su -`/`ssh` chains `PATH` is kilobytes long — which, per §8.5, eats directly into your `ARG_MAX` budget.

---

## 8. Verification and failure diagnosis

### 8.1 The `command not found` / `cannot execute` decision tree

```
Symptom
  │
  ├─ "bash: foo: command not found"                      (exit 127)
  │    ├─ type -a foo            → nothing?  it is not in PATH / not a builtin
  │    ├─ echo "$PATH"           → is the directory listed? exported?
  │    ├─ hash -r; try again     → stale hash cache?
  │    └─ ls -l /path/to/foo     → is it installed at all?  (rpm -qf / dpkg -S)
  │
  ├─ "bash: ./foo: Permission denied"                     (exit 126)
  │    ├─ ls -l ./foo            → missing the x bit?      → chmod +x
  │    ├─ findmnt -no OPTIONS -T ./foo → "noexec"?         → move it, or remount
  │    └─ ls -Z ./foo ; ausearch -m avc -ts recent → SELinux denial?
  │
  ├─ "bash: ./foo: cannot execute: required file not found"   (bash >= 5.1)
  │  "bash: ./foo: No such file or directory"                 (older bash)
  │    ├─ head -c2 ./foo == "#!" ?  → the INTERPRETER is missing
  │    │     └─ file ./foo ; sed -n 1p ./foo ; ls -l "$(sed -n '1s|^#!\([^ ]*\).*|\1|p' ./foo)"
  │    │     └─ CRLF?  file reports "with CRLF line terminators" → sed -i 's/\r$//' ./foo
  │    └─ ELF binary?              → the dynamic LOADER is missing
  │          └─ file ./foo ; ldd ./foo
  │
  └─ "bash: ./foo: cannot execute binary file: Exec format error"
       └─ wrong architecture (arm64 binary on x86_64) → file ./foo ; uname -m
```

Worked example — the interpreter, not the script, is what is missing:

```console
$ ls -l ./deploy.sh
-rwxr-xr-x. 1 sre sre 412 Aug 26 11:22 ./deploy.sh

$ ./deploy.sh
bash: ./deploy.sh: /bin/bash^M: bad interpreter: No such file or directory

$ file ./deploy.sh
./deploy.sh: Bourne-Again shell script, ASCII text executable, with CRLF line terminators

$ sed -i 's/\r$//' ./deploy.sh
$ file ./deploy.sh
./deploy.sh: Bourne-Again shell script, ASCII text executable
$ ./deploy.sh
deploying...
```

Worked example — the ELF loader:

```console
$ ./app
bash: ./app: cannot execute: required file not found

$ file ./app
./app: ELF 64-bit LSB pie executable, x86-64, dynamically linked,
interpreter /lib/ld-musl-x86_64.so.1, stripped

$ ls -l /lib/ld-musl-x86_64.so.1
ls: cannot access '/lib/ld-musl-x86_64.so.1': No such file or directory
```

The binary was built against musl (an Alpine image) and copied onto a glibc host. `execve` returned `ENOENT` for the *interpreter*, and bash reported it against your file name. `file` + `ldd` disambiguate in two seconds; guessing does not.

### 8.2 `strace`: watch `execve` and `PATH` search happen

```console
$ strace -f -e trace=execve,access -qq -o /tmp/tr.log bash -c 'kubectl version --client' 
$ grep -E 'execve' /tmp/tr.log
execve("/bin/bash", ["bash", "-c", "kubectl version --client"], 0x7ffd1c2a1e30 /* 34 vars */) = 0
execve("/home/sre/.local/bin/kubectl", ["kubectl", "version", "--client"], 0x55d3f2a1c8b0 /* 34 vars */) = -1 ENOENT (No such file or directory)
execve("/usr/local/bin/kubectl", ["kubectl", "version", "--client"], 0x55d3f2a1c8b0 /* 34 vars */) = -1 ENOENT (No such file or directory)
execve("/usr/bin/kubectl", ["kubectl", "version", "--client"], 0x55d3f2a1c8b0 /* 34 vars */) = 0
```

You are literally watching the `PATH` walk, left to right, with `ENOENT` per miss. The `/* 34 vars */` annotation is your `envp[]` size. This single command settles arguments about "is it a PATH problem or a permissions problem" definitively.

### 8.3 `set -x`: see expansion results, not your intentions

```console
$ cat check.sh
#!/usr/bin/env bash
set -Eeuo pipefail
TARGET=${1:-/var/log}
FILES=$(find "$TARGET" -name '*.log' -mtime +7)
echo "would remove: $FILES"

$ bash -x ./check.sh '/var/log/my app'
+ TARGET='/var/log/my app'
++ find '/var/log/my app' -name '*.log' -mtime +7
+ FILES='/var/log/my app/old.log
/var/log/my app/older.log'
+ echo 'would remove: /var/log/my app/old.log
/var/log/my app/older.log'
would remove: /var/log/my app/old.log
/var/log/my app/older.log
```

`+` is one level of expansion, `++` is a nested one (`PS4` controls the prefix). Make the trace far more useful:

```console
$ export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
$ bash -x ./check.sh /var/log
+ check.sh:3:main: TARGET=/var/log
+ check.sh:4:main: find /var/log -name '*.log' -mtime +7
```

Trace only a hot section rather than the whole script:

```bash
set -x
critical_step "$@"
set +x
```

### 8.4 Diffing two environments — the "works in my shell" resolution

```console
$ env -i bash --noprofile --norc -c 'env' | sort > /tmp/env.minimal
$ env | sort > /tmp/env.interactive
$ diff /tmp/env.minimal /tmp/env.interactive | head -12
1a2,10
> AWS_PROFILE=platform-admin
> KUBECONFIG=/home/sre/.kube/config-prod
> LANG=en_US.UTF-8
> PATH=/home/sre/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
> PYENV_ROOT=/home/sre/.pyenv
> SSH_AUTH_SOCK=/run/user/1000/keyring/ssh
```

Every line in that diff is a hidden dependency your script has on your workstation. `KUBECONFIG` and `SSH_AUTH_SOCK` in particular are why "the script deployed to prod from my laptop but does nothing from the runner".

Same technique against a live process, for daemons you did not start:

```console
$ pidof nginx
2841 2840 2839
$ sudo tr '\0' '\n' < /proc/2839/environ | sort
LANG=en_US.UTF-8
NGINX_BINARY=/usr/sbin/nginx
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
```

### 8.5 `Argument list too long` (`E2BIG`)

```console
$ ls /var/log/archive | wc -l
412093
$ rm -f /var/log/archive/*.gz
bash: /usr/bin/rm: Argument list too long

$ getconf ARG_MAX
2097152

$ ulimit -s
8192

$ xargs --show-limits < /dev/null
Your environment variables take up 4283 bytes
POSIX upper limit on argument length (this system): 2090821
POSIX smallest allowable upper limit on argument length (all systems): 4096
Maximum length of command we could actually use: 2086538
Size of command buffer we are actually using: 131072
Maximum parallelism (--max-procs must be no greater than): 2147483647
```

Note the first line: **your environment is charged against the same budget as your arguments.** A bloated `PATH` (§7.4) or a large exported variable measurably shrinks how many filenames you can pass. Correct solutions, in order of preference:

```console
$ find /var/log/archive -maxdepth 1 -name '*.gz' -delete
$ find /var/log/archive -maxdepth 1 -name '*.gz' -print0 | xargs -0 -r rm -f
$ find /var/log/archive -maxdepth 1 -name '*.gz' -exec rm -f {} +
```

`-print0`/`-0` is NUL-separation, immune to spaces and newlines in filenames. `-r` (`--no-run-if-empty`) stops `xargs` from running `rm` with no arguments. `-exec … +` batches, `-exec … \;` forks once per file — measurably different at 400k files:

```console
$ time find /var/log/archive -name '*.gz' -exec stat -c %s {} \; > /dev/null
real    3m41.207s
$ time find /var/log/archive -name '*.gz' -exec stat -c %s {} + > /dev/null
real    0m4.882s
```

Note also that `time` here is the bash **keyword** (it times the whole pipeline), not `/usr/bin/time`. `type -a time` shows both.

### 8.6 System identification: `uname`

```console
$ uname -a
Linux prod-worker-03 6.1.0-27-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.115-1 (2026-07-14) x86_64 GNU/Linux
```

| Flag | Field | Value above | Typical use |
|---|---|---|---|
| `-s` | kernel name | `Linux` | portability branching in scripts |
| `-n` | nodename | `prod-worker-03` | prefer `hostnamectl`/`hostname -f` for the FQDN |
| `-r` | kernel **release** | `6.1.0-27-amd64` | CVE applicability, module/driver matching, `/lib/modules/$(uname -r)` |
| `-v` | kernel **version** (build string) | `#1 SMP … Debian 6.1.115-1` | identifying the exact distro kernel build |
| `-m` | machine hardware | `x86_64` | architecture-specific downloads |
| `-o` | operating system (GNU ext.) | `GNU/Linux` | |
| `-p`, `-i` | processor, hardware platform | often `unknown` on Linux | rarely useful; do not depend on them |

```console
$ uname -r
6.1.0-27-amd64
$ ls /lib/modules/$(uname -r)/kernel/net/ | head -3
802
8021q
bridge
$ cat /etc/os-release | head -3
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
```

**`uname` describes the kernel, `/etc/os-release` describes the distribution.** A container running `debian:12-slim` on a Fedora host reports the *host's* kernel from `uname -r` and Debian from `/etc/os-release` — because containers share the host kernel. Confusing these two produces incorrect vulnerability reports:

```console
$ docker run --rm debian:12-slim sh -c 'uname -r; head -1 /etc/os-release'
7.1.8-200.fc44.x86_64
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
```

### 8.7 Getting documentation on the box, offline

```console
$ man 5 crontab            # section 5 = file formats, NOT the crontab command
$ man -f printf
printf (1)           - format and print data
printf (3)           - formatted output conversion
printf (1p)          - write formatted output

$ apropos -s 1 'shell'
bash (1)             - GNU Bourne-Again SHell
dash (1)             - command interpreter (shell)
sh (1)               - command interpreter (shell)

$ man -k 'environment' | head -3
env (1)              - run a program in a modified environment
environ (7)          - user environment
printenv (1)         - print environment variables

$ help export         # BUILTINS are documented by `help`, not by man
export: export [-fn] [name[=value] ...] or export -p
    Set export attribute for shell variables.
    ...
```

| Section | Contents | Example |
|---|---|---|
| 1 | User commands | `man 1 echo` |
| 2 | System calls | `man 2 execve` |
| 3 | Library functions | `man 3 getenv` |
| 4 | Devices, special files | `man 4 null` |
| 5 | File formats, configuration | `man 5 crontab`, `man 5 sudoers` |
| 6 | Games | |
| 7 | Miscellany, conventions, overviews | `man 7 environ`, `man 7 signal` |
| 8 | System administration | `man 8 mount` |

`man -a printf` walks every section in turn. If `man -k` returns `nothing appropriate`, the index is missing — run `sudo mandb` (Debian) or `sudo makewhatis`/`mandb` (RHEL). On minimal container images the man pages are stripped entirely; that is a deliberate size trade-off, and the answer is `--help` plus a documentation source outside the image.

**The trap:** for `echo`, `pwd`, `test`, `kill` and `time`, `man` documents the **external** coreutils binary while your shell runs the **builtin**, and they differ. `echo -e` works in bash's builtin and in GNU coreutils, but not in `dash`'s builtin or under `sh` in POSIX mode. `printf` is the portable choice:

```console
$ type -a echo
echo is a shell builtin
echo is /usr/bin/echo

$ printf '%s\t%s\n' col1 col2      # portable, predictable, no -e/-n guessing
col1	col2
```

### 8.8 A reusable environment-probe script

```bash
#!/usr/bin/env bash
# env-probe.sh — capture everything 103.1 governs, for a bug report.
set -Eeuo pipefail

printf '=== identity ===\n'
printf 'user=%s uid=%s pid=%s ppid=%s\n' "$(id -un)" "$(id -u)" "$$" "$PPID"
printf 'shell=%s version=%s\n' "${SHELL:-unset}" "${BASH_VERSION:-not-bash}"
printf 'login_shell=%s interactive=%s\n' \
       "$(shopt -q login_shell && echo yes || echo no)" \
       "$([[ $- == *i* ]] && echo yes || echo no)"
printf 'cwd=%s\n' "$PWD"

printf '\n=== system ===\n'
uname -srvmo
[[ -r /etc/os-release ]] && grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release

printf '\n=== PATH (one entry per line, marking problems) ===\n'
IFS=':' read -ra path_entries <<< "$PATH"
for entry in "${path_entries[@]}"; do
    if   [[ -z $entry   ]]; then printf '  !! EMPTY  (means ".", insecure)\n'
    elif [[ $entry == . ]]; then printf '  !! "."    (insecure)\n'
    elif [[ ! -d $entry ]]; then printf '  ?  %s (does not exist)\n' "$entry"
    elif [[ -w $entry && ! -O $entry ]]; then
                                 printf '  !! %s (writable, not owned by you)\n' "$entry"
    else                         printf '  ok %s\n' "$entry"
    fi
done

printf '\n=== command resolution ===\n'
for cmd in "$@"; do
    if type -a "$cmd" 2>/dev/null; then :; else printf '%s: NOT FOUND\n' "$cmd"; fi
done

printf '\n=== hash cache ===\n'
hash -l 2>/dev/null || printf '(empty)\n'

printf '\n=== environment (values of sensitive names redacted) ===\n'
env | sort | sed -E 's/^([^=]*(TOKEN|SECRET|PASSWORD|KEY)[^=]*)=.*/\1=<redacted>/'

printf '\n=== shell options ===\n'
printf 'set: %s\n' "$-"
shopt | grep -E '^(histappend|expand_aliases|checkwinsize|globstar|nullglob)\s'
```

```console
$ ./env-probe.sh kubectl helm terraform
=== identity ===
user=sre uid=1000 pid=12043 ppid=12042
shell=/bin/bash version=5.2.15(1)-release
login_shell=no interactive=no
cwd=/home/sre

=== system ===
Linux 6.1.0-27-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.115-1 (2026-07-14) x86_64 GNU/Linux
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
VERSION_ID="12"

=== PATH (one entry per line, marking problems) ===
  ok /home/sre/.local/bin
  ok /usr/local/bin
  ok /usr/bin
  ok /bin
  ?  /opt/legacy/bin (does not exist)
  !! EMPTY  (means ".", insecure)

=== command resolution ===
kubectl is /usr/bin/kubectl
helm is /usr/local/bin/helm
terraform: NOT FOUND
...
```

Attach that output to the ticket and the "works on my machine" conversation is over in one round trip.

---

## 9. Exam-focused drills

Answer before checking; each maps to a specific mechanism above.

1. `VAR=x bash -c 'echo $VAR'` prints `x`, but `VAR=x; bash -c 'echo $VAR'` prints an empty line. Why?
   *A prefix assignment on a command line places the variable in that command's environment for that invocation only. A plain assignment creates a non-exported shell variable.*
2. Why does `cd /tmp | cat` leave you in your original directory?
   *Each stage of a pipeline runs in a subshell; `cd` is a builtin acting on that short-lived child.*
3. `echo $PATH` and `sudo echo $PATH` print the same string. Why is that not evidence that `sudo` preserves `PATH`?
   *The parent shell expands `$PATH` **before** `execve`, so `sudo` receives the already-expanded literal. Use `sudo printenv PATH` or `sudo sh -c 'echo $PATH'`.*
4. A file is `-rwxr-xr-x`, on `PATH`, and `./file` still yields `command not found`.
   *`command not found` means `PATH` lookup failed; with `./` there is no lookup, so the message must be different. If it really is `command not found`, an alias or `hash -p` entry is intercepting the name — check `type -a`.*
5. What does `PATH=/usr/bin:` do that `PATH=/usr/bin` does not?
   *Adds the current directory as a searched location, via the trailing empty field.*
6. `history` shows a command that is absent from `~/.bash_history`. Give two explanations.
   *It has not been flushed yet (no `history -a`, shell still running), or `HISTCONTROL`/`HISTIGNORE` excluded it from the file while it remains in memory.*
7. What is the difference between `echo "$@"` and `echo "$*"` when the script is called with `a "b c"`?
   *`"$@"` yields two words `a` and `b c`; `"$*"` yields one word `a b c` joined by the first character of `IFS`.*
8. `find . -name *.log` fails with `paths must precede expression`. Why, and what is the fix?
   *The shell globbed `*.log` against the current directory before `find` ran. Quote it: `-name '*.log'`.*
9. How do you run the system `ls` when a function named `ls` exists?
   *`command ls`, `\ls` (bypasses aliases only), or `/usr/bin/ls`.*
10. Why must `ExecStart=` in a systemd unit be an absolute path?
    *systemd calls `execve` directly with no shell and performs no `PATH` search of its own for the leading token.*

---

## 10. References

**Certification objectives**
- LPI — Exam 101-500 Objectives (Topic 103.1): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/
- LPI — Exam 102-500 Objectives: https://www.lpi.org/our-certifications/exam-102-objectives/

**Shell and standards**
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- GNU Bash — Shell Expansions: https://www.gnu.org/software/bash/manual/html_node/Shell-Expansions.html
- GNU Bash — Bash History Facilities: https://www.gnu.org/software/bash/manual/html_node/Bash-History-Facilities.html
- GNU Bash — History Interaction (`!` expansion): https://www.gnu.org/software/bash/manual/html_node/History-Interaction.html
- GNU Bash — The Set Builtin: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- POSIX.1-2024 — Shell Command Language: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html
- POSIX.1-2024 — Environment Variables: https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap08.html
- GNU Coreutils Manual (`env`, `printenv`, `echo`, `printf`, `pwd`, `uname`): https://www.gnu.org/software/coreutils/manual/coreutils.html

**Kernel and system interfaces**
- `execve(2)` — including the `E2BIG` / `MAX_ARG_STRLEN` limits: https://man7.org/linux/man-pages/man2/execve.2.html
- `environ(7)`: https://man7.org/linux/man-pages/man7/environ.7.html
- `proc(5)` — `/proc/[pid]/environ`, `/proc/[pid]/cmdline`: https://man7.org/linux/man-pages/man5/proc.5.html
- `fork(2)`: https://man7.org/linux/man-pages/man2/fork.2.html
- `bash(1)`: https://man7.org/linux/man-pages/man1/bash.1.html
- `xargs(1)`: https://man7.org/linux/man-pages/man1/xargs.1.html
- `find(1)` — GNU findutils manual: https://www.gnu.org/software/findutils/manual/html_mono/find.html
- `uname(1)`: https://man7.org/linux/man-pages/man1/uname.1.html
- `man(1)` and manual sections: https://man7.org/linux/man-pages/man1/man.1.html

**Privilege and service environments**
- `sudoers(5)` — `env_reset`, `secure_path`, `env_keep`: https://www.sudo.ws/docs/man/sudoers.man/
- `sudo(8)` — command environment: https://www.sudo.ws/docs/man/sudo.man/
- `systemd.exec(5)` — `Environment=`, `EnvironmentFile=`, default `$PATH`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.service(5)` — `ExecStart=` command-line parsing: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd-run(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `crontab(5)` — the cron environment: https://man7.org/linux/man-pages/man5/crontab.5.html

**Container and orchestration environments**
- Kubernetes — Define Environment Variables for a Container: https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/
- Kubernetes — Define a Command and Arguments for a Container: https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/
- Kubernetes — Expose Pod Information to Containers (Downward API): https://kubernetes.io/docs/tasks/inject-data-application/environment-variable-expose-pod-information/
- Kubernetes — Distribute Credentials Securely Using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Docker — Dockerfile reference (`ENV`, `ARG`, `ENTRYPOINT` shell vs exec form): https://docs.docker.com/reference/dockerfile/
- Filesystem Hierarchy Standard 3.0 (`/bin`, `/usr/bin`, `/sbin`, `/usr/local/bin`): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html