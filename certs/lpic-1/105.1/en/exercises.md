# LPIC-1 · Topic 105.1 — Customize and Use the Shell Environment

## Guided Exercises

**Exam:** 102-500 (LPIC-1, version 5.0) · **Weight:** 4 (Topic 105 total: 9)
**Objective coverage:** setting environment variables at login and for new shells, writing Bash functions for frequently used command sequences, maintaining skeleton directories for new accounts, setting the command search path.
**Utilities under test:** `.` , `source`, `/etc/bash.bashrc`, `/etc/profile`, `env`, `export`, `set`, `unset`, `~/.bash_profile`, `~/.bash_login`, `~/.profile`, `~/.bashrc`, `~/.bash_logout`, `function`, `alias`, `lists`.

---

### Lab requirements and safety

You need a disposable Linux system (VM or container) with `bash` 4.4+ (5.x preferred), `sudo` or root access, and `shadow-utils` (`useradd`). **Do not run this on a machine you care about**: several steps deliberately break your shell startup files and create test users.

Verify your interpreter and take a backup before anything else:

```bash
bash --version | head -1
mkdir -p ~/lab-105.1/backup
cp -av ~/.bashrc ~/.bash_profile ~/.bash_login ~/.profile ~/.bash_logout \
      ~/lab-105.1/backup/ 2>/dev/null
ls -A ~/lab-105.1/backup/
```

```text
GNU bash, version 5.2.26(1)-release (x86_64-pc-linux-gnu)
'/home/student/.bashrc' -> '/home/student/lab-105.1/backup/.bashrc'
'/home/student/.profile' -> '/home/student/lab-105.1/backup/.profile'
.bashrc  .profile
```

Every exercise ends where it started; a full restore procedure is given in Exercise 10.

---

## Exercise 1 — Classify the shell you are sitting in

Bash reads *different* startup files depending on two independent, orthogonal properties: **interactive or not**, and **login or not**. Every configuration bug in this topic starts with getting this classification wrong.

**Step 1.** Inspect the current option flags. The `$-` variable holds the single-letter flags of the running shell:

```bash
echo "$-"
```

```text
himBHs
```

The letter that matters is `i` (interactive). Others: `h` = `hashall`, `m` = job control, `B` = brace expansion, `H` = history expansion.

**Step 2.** Ask Bash directly whether it is a login shell. `login_shell` is a read-only `shopt` option:

```bash
shopt login_shell
shopt -q login_shell; echo "exit status: $?"
```

```text
login_shell     off
exit status: 1
```

(In a graphical terminal emulator you will usually see `off`. Over SSH, on a text console, or after `su -`, you will see `on`.)

**Step 3.** Look at how the process was invoked. A login shell is conventionally started with a hyphen prepended to `argv[0]`:

```bash
ps -o pid,ppid,args -p "$$"
```

```text
    PID    PPID COMMAND
   4412    4408 bash
```

**Step 4.** Now produce all four combinations deliberately and compare:

```bash
bash -c        'echo "non-login non-interactive: [$-]"'
bash -i -c     'echo "non-login interactive    : [$-]"'
bash -l -c     'echo "login non-interactive    : [$-]"'
bash -l -i -c  'echo "login interactive        : [$-]"'
```

```text
non-login non-interactive: [hBc]
non-login interactive    : [himBHc]
login non-interactive    : [hBc]
login interactive        : [himBHc]
```

**Step 5.** Confirm that `-l` really did something, since `$-` does not report it:

```bash
bash -c   'shopt -q login_shell && echo LOGIN || echo NOT-LOGIN'
bash -l -c 'shopt -q login_shell && echo LOGIN || echo NOT-LOGIN'
```

```text
NOT-LOGIN
LOGIN
```

**Step 6.** Compare a remote command with a remote session (skip if `sshd` is not running locally):

```bash
ssh localhost 'echo "flags=[$-]"; shopt -q login_shell && echo LOGIN || echo NOT-LOGIN'
```

```text
flags=[hBc]
NOT-LOGIN
```

> **Q1.1** — Which single letter in `$-` proves the shell is interactive, and why is the login/non-login property *absent* from `$-`?
> **Q1.2** — `su student` and `su - student` both give you a shell as `student`. Which startup files differ between them, and why does `su -` fix "my PATH is wrong after switching users"?
> **Q1.3** — `ssh localhost 'echo hi'` produced a shell that is neither login nor interactive. Which startup file, if any, does Bash read in that case? (Two answers are defensible — name both.)
> **Q1.4** — Why is `ps -o args -p $$` an unreliable way to detect a login shell compared to `shopt -q login_shell`?

---

## Exercise 2 — Trace the startup file order empirically

Rather than memorising the order, instrument the files and let Bash tell you.

**Step 1.** Create a system-wide marker. `/etc/profile` sources every `*.sh` file in `/etc/profile.d/`, which is the supported drop-in location — never edit `/etc/profile` itself:

```bash
sudo tee /etc/profile.d/00-lab-trace.sh >/dev/null <<'EOF'
echo "TRACE: /etc/profile.d/00-lab-trace.sh (via /etc/profile)" >&2
EOF
```

**Step 2.** Instrument every per-user file. Note that we create all three login-file candidates:

```bash
cd ~
printf 'echo "TRACE: ~/.bash_profile" >&2\n' >> ~/.bash_profile
printf 'echo "TRACE: ~/.bash_login"   >&2\n' >> ~/.bash_login
printf 'echo "TRACE: ~/.profile"      >&2\n' >> ~/.profile
printf 'echo "TRACE: ~/.bashrc"       >&2\n' >> ~/.bashrc
printf 'echo "TRACE: ~/.bash_logout"  >&2\n' >> ~/.bash_logout
ls -A ~/.bash* ~/.profile
```

```text
/home/student/.bash_login  /home/student/.bash_profile  /home/student/.bashrc
/home/student/.bash_logout /home/student/.profile
```

**Step 3.** Start an interactive login shell and immediately leave it:

```bash
bash -l -i -c 'true'
```

```text
TRACE: /etc/profile.d/00-lab-trace.sh (via /etc/profile)
TRACE: ~/.bash_profile
```

**Step 4.** Remove the winner and repeat, twice:

```bash
mv ~/.bash_profile ~/lab-105.1/
bash -l -i -c 'true'
mv ~/.bash_login ~/lab-105.1/
bash -l -i -c 'true'
```

```text
TRACE: /etc/profile.d/00-lab-trace.sh (via /etc/profile)
TRACE: ~/.bash_login
TRACE: /etc/profile.d/00-lab-trace.sh (via /etc/profile)
TRACE: ~/.profile
```

**Step 5.** Now start an interactive **non-login** shell:

```bash
bash -i -c 'true'
```

```text
TRACE: ~/.bashrc
```

**Step 6.** And a plain non-interactive shell, then the same with `BASH_ENV` set:

```bash
bash -c 'true'
echo "---"
printf 'echo "TRACE: $BASH_ENV" >&2\n' > ~/lab-105.1/env.sh
BASH_ENV=~/lab-105.1/env.sh bash -c 'true'
```

```text
---
TRACE: /home/student/lab-105.1/env.sh
```

**Step 7.** Verify the system-wide interactive file. Its name is distribution-dependent:

```bash
ls -l /etc/bash.bashrc /etc/bashrc 2>&1
grep -n 'bash\.bashrc\|/etc/bashrc' ~/.bashrc /etc/skel/.bashrc 2>/dev/null | head
```

```text
ls: cannot access '/etc/bashrc': No such file or directory
-rw-r--r-- 1 root root 2319 Mar 31 09:12 /etc/bash.bashrc
```

**Step 8.** Prove that a login shell does **not** read `~/.bashrc` on its own, and see the conventional bridge that every distribution ships:

```bash
grep -n -A3 'bashrc' ~/.profile
```

```text
14:if [ -n "$BASH_VERSION" ]; then
15-    # include .bashrc if it exists
16-    if [ -f "$HOME/.bashrc" ]; then
17-        . "$HOME/.bashrc"
18-    fi
```

**Step 9.** Restore `~/.bash_profile` and `~/.bash_login` for the next exercise:

```bash
mv ~/lab-105.1/.bash_profile ~/lab-105.1/.bash_login ~/ 2>/dev/null; ls -A ~/.bash*
```

> **Q2.1** — Write the exact search order Bash uses for the per-user login file, and state what happens to the other two candidates when the first one exists.
> **Q2.2** — In Step 3 the login shell was also interactive, yet `~/.bashrc` was *not* traced. Explain why, and explain why you nevertheless saw `~/.bashrc` output in a real terminal session.
> **Q2.3** — You put `export PATH="$HOME/bin:$PATH"` in `~/.bashrc`. After opening a terminal and typing `bash` twice, what does `$PATH` look like, and which file should have held that line instead?
> **Q2.4** — Why is `/etc/profile.d/00-lab-trace.sh` a better place for a system-wide change than appending to `/etc/profile`?
> **Q2.5** — `BASH_ENV` was honoured in Step 6. Name one security consequence of that mechanism for a setuid-like context, and name the POSIX/`sh` equivalent variable.

---

## Exercise 3 — Shell variables versus environment variables

`set`, `env`, `export` and `unset` are four different tools operating on two different namespaces. Confusing them is the single most common failure in this objective.

**Step 1.** Create a plain shell variable — note there is no space around `=`:

```bash
LAB_LOCAL="shell-only"
echo "value: $LAB_LOCAL"
```

```text
value: shell-only
```

**Step 2.** Ask each tool whether it can see it:

```bash
set   | grep '^LAB_LOCAL='   ; echo "set   -> $?"
env   | grep '^LAB_LOCAL='   ; echo "env   -> $?"
export -p | grep 'LAB_LOCAL' ; echo "export -> $?"
```

```text
LAB_LOCAL='shell-only'
set   -> 0
env   -> 1
export -> 1
```

**Step 3.** Inspect the variable's attributes, then check whether a child process inherits it:

```bash
declare -p LAB_LOCAL
bash -c 'echo "child sees: [$LAB_LOCAL]"'
```

```text
declare -- LAB_LOCAL="shell-only"
child sees: []
```

**Step 4.** Promote it to the environment and repeat both checks:

```bash
export LAB_LOCAL
declare -p LAB_LOCAL
env | grep '^LAB_LOCAL='
bash -c 'echo "child sees: [$LAB_LOCAL]"'
```

```text
declare -x LAB_LOCAL="shell-only"
LAB_LOCAL=shell-only
child sees: [shell-only]
```

**Step 5.** Demote it again *without* destroying it, then destroy it:

```bash
export -n LAB_LOCAL
declare -p LAB_LOCAL
unset -v LAB_LOCAL
declare -p LAB_LOCAL
```

```text
declare -- LAB_LOCAL="shell-only"
bash: declare: LAB_LOCAL: not found
```

**Step 6.** Set a variable for exactly one command — a temporary assignment prefix does not touch the current shell:

```bash
LAB_ONCE=yes env | grep '^LAB_ONCE='
echo "after: [${LAB_ONCE:-unset}]"
```

```text
LAB_ONCE=yes
after: [unset]
```

**Step 7.** Use `env` to *remove* a variable from a child's environment and to build a pristine environment:

```bash
export LAB_KEEP=1 LAB_DROP=1
env -u LAB_DROP bash -c 'echo "keep=[$LAB_KEEP] drop=[$LAB_DROP]"'
env -i bash --noprofile --norc -c 'echo "count: $(env | wc -l)"; env'
```

```text
keep=[1] drop=[]
count: 3
PWD=/home/student
SHLVL=1
_=/usr/bin/env
```

**Step 8.** Contrast the two "list everything" commands. `set` with no arguments prints shell variables *and function definitions*; POSIX mode restricts it to variables:

```bash
set | wc -l
( set -o posix; set | wc -l )
env | wc -l
```

```text
312
118
41
```

**Step 9.** Demonstrate an attribute that resists `unset`:

```bash
declare -r LAB_RO="cannot change"
LAB_RO="try"
unset -v LAB_RO
echo "still: $LAB_RO"
```

```text
bash: LAB_RO: readonly variable
bash: unset: LAB_RO: cannot unset: readonly variable
still: cannot change
```

**Step 10.** Clean up (the readonly variable will disappear only when this shell exits):

```bash
unset -v LAB_KEEP LAB_DROP
```

> **Q3.1** — In one sentence each, state what `set`, `env`, `export -p` and `declare -p` show that the others do not.
> **Q3.2** — `export -n VAR` and `unset -v VAR` both make `env | grep VAR` empty. What is the observable difference in the current shell?
> **Q3.3** — Is `env` a shell builtin? Prove your answer with a command, and explain why `LAB_ONCE=yes env` works while `LAB_ONCE=yes echo $LAB_ONCE` prints nothing.
> **Q3.4** — Why does `set -o posix` shrink the output of `set` so dramatically?
> **Q3.5** — A colleague reports "I exported it but the script still doesn't see it." Give the two most likely causes given what you observed in Steps 3–5.

---

## Exercise 4 — The command search path and the hash table

**Step 1.** Print `PATH` one entry per line — colons are field separators, and the field order is the search order:

```bash
echo "$PATH" | tr ':' '\n' | nl
```

```text
     1  /home/student/.local/bin
     2  /usr/local/sbin
     3  /usr/local/bin
     4  /usr/sbin
     5  /usr/bin
     6  /sbin
     7  /bin
```

**Step 2.** Build a private command and observe that it is not yet findable:

```bash
mkdir -p ~/bin
cat > ~/bin/lab-tool <<'EOF'
#!/bin/bash
echo "lab-tool v1 from $0"
EOF
chmod 0755 ~/bin/lab-tool
lab-tool
```

```text
bash: lab-tool: command not found
```

**Step 3.** Prepend the directory and resolve the command three ways:

```bash
PATH="$HOME/bin:$PATH"
lab-tool
type lab-tool
type -a lab-tool
command -v lab-tool
type -t lab-tool
```

```text
lab-tool v1 from /home/student/bin/lab-tool
lab-tool is /home/student/bin/lab-tool
lab-tool is /home/student/bin/lab-tool
/home/student/bin/lab-tool
file
```

**Step 4.** Now expose the hash table. Bash caches full pathnames of executed commands so it does not re-scan `PATH` every time:

```bash
hash
```

```text
hits	command
   1	/home/student/bin/lab-tool
   3	/usr/bin/ls
```

**Step 5.** Create a *higher-priority* duplicate and watch the cache serve stale data:

```bash
sudo install -m 0755 /dev/stdin /usr/local/bin/lab-tool <<'EOF'
#!/bin/bash
echo "lab-tool v2 from $0"
EOF
PATH="/usr/local/bin:$HOME/bin:${PATH#$HOME/bin:}"
lab-tool
type -a lab-tool
```

```text
lab-tool v1 from /home/student/bin/lab-tool
lab-tool is /usr/local/bin/lab-tool
lab-tool is /home/student/bin/lab-tool
```

**Step 6.** Note the contradiction — `type -a` (which rescans) and the actual execution disagree. Flush the cache:

```bash
hash -d lab-tool     # forget one entry
lab-tool
hash -r              # forget everything
```

```text
lab-tool v2 from /usr/local/bin/lab-tool
```

**Step 7.** Examine the dangerous `PATH` syntax. An empty field — leading colon, trailing colon, or `::` — means *the current directory*:

```bash
mkdir -p ~/lab-105.1/trap && cd ~/lab-105.1/trap
cat > ls <<'EOF'
#!/bin/bash
echo "*** this is not coreutils ls ***"
EOF
chmod 0755 ls
PATH="$PATH:" ; hash -r
ls
```

```text
*** this is not coreutils ls ***
```

**Step 8.** Repair it and verify:

```bash
PATH="${PATH%:}" ; hash -r
ls
cd ~
```

```text
ls
```

**Step 9.** Make a `PATH` change durable and idempotent. Put this in `~/.profile` (login shell), not `~/.bashrc`:

```bash
cat >> ~/.profile <<'EOF'

# LAB 105.1 — idempotent PATH extension
case ":${PATH}:" in
    *:"$HOME/bin":*) ;;
    *) PATH="$HOME/bin:$PATH" ;;
esac
export PATH
EOF
bash -l -i -c 'echo "$PATH" | tr ":" "\n" | grep -c "^$HOME/bin$"'
```

```text
1
```

**Step 10.** Confirm nesting no longer duplicates the entry:

```bash
bash -l -i -c 'bash -i -c "bash -i -c \"echo SHLVL=\\\$SHLVL; echo \\\$PATH | tr : \\\\n | grep -c bin\\$\""'
```

> **Q4.1** — Given `PATH=/usr/local/bin:/usr/bin:/bin`, a file `/usr/bin/foo` (mode 0755) and `/usr/local/bin/foo` (mode 0644), which one runs when you type `foo`, and why?
> **Q4.2** — In Step 5, `type -a` reported `/usr/local/bin/lab-tool` first, but `/home/student/bin/lab-tool` executed. Explain the mechanism and give two commands that fix it.
> **Q4.3** — Name the three `PATH` spellings that silently include the current working directory, and explain the attack they enable in a shared `/tmp`.
> **Q4.4** — Why does `which lab-tool` sometimes disagree with `type lab-tool`? Which of the two is authoritative for what Bash will actually run?
> **Q4.5** — Why is `~/.profile` the correct home for a `PATH` assignment while `~/.bashrc` is the correct home for an `alias`?

---

## Exercise 5 — Aliases: expansion rules and their limits

**Step 1.** List what your distribution already defined, then create your own:

```bash
alias
alias ll='ls -alF --color=auto'
alias vi='vim'
alias
```

```text
alias ls='ls --color=auto'
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias vi='vim'
```

**Step 2.** Resolve an aliased name and observe precedence:

```bash
type -a ls
type -t ls
```

```text
ls is aliased to `ls --color=auto'
ls is /usr/bin/ls
alias
```

**Step 3.** Bypass the alias without removing it — three independent techniques:

```bash
\ls -d /etc | cat        # quoting any character suppresses alias lookup
'ls' -d /etc | cat
command ls -d /etc | cat
```

```text
/etc
/etc
/etc
```

**Step 4.** Prove aliases are an *interactive-only* feature by default:

```bash
cat > ~/lab-105.1/alias-test.sh <<'EOF'
#!/bin/bash
alias hello='echo "hello from alias"'
hello
EOF
chmod 0755 ~/lab-105.1/alias-test.sh
~/lab-105.1/alias-test.sh
```

```text
/home/student/lab-105.1/alias-test.sh: line 3: hello: command not found
```

**Step 5.** Enable them explicitly and re-run:

```bash
sed -i '2i shopt -s expand_aliases' ~/lab-105.1/alias-test.sh
~/lab-105.1/alias-test.sh
```

```text
hello from alias
```

**Step 6.** Discover the parse-time rule. Aliases are expanded when a line is *read*, not when it is *executed*:

```bash
bash -c 'shopt -s expand_aliases; alias hi="echo HI"; hi'
echo "---"
bash -c 'shopt -s expand_aliases
alias hi="echo HI"
hi'
```

```text
bash: line 1: hi: command not found
---
HI
```

**Step 7.** Use the trailing-blank rule, which is the only reason `sudo ll` can ever work:

```bash
alias please='sudo '        # note the trailing space
alias ll='ls -alF'
please ll /root | head -3
```

```text
total 32
drwx------.  5 root root 4096 Aug 20 11:02 ./
dr-xr-xr-x. 19 root root 4096 Aug  1 08:44 ../
```

**Step 8.** Discover the hard limit — an alias cannot process arguments positionally:

```bash
alias greet='echo "Hello, $1!"'
greet World
```

```text
Hello, ! World
```

**Step 9.** Remove them:

```bash
unalias please greet vi
unalias -a          # removes ALL aliases in this shell
alias | wc -l
```

```text
0
```

> **Q5.1** — Order these from highest to lowest precedence when Bash resolves a command word: external file in `PATH`, shell function, alias, builtin, reserved word.
> **Q5.2** — Why did `greet World` in Step 8 print `Hello, ! World` instead of `Hello, World!`? What is the correct construct for this job?
> **Q5.3** — In Step 6, the one-line version failed but the three-line version worked. State the rule that explains this, and say why it also means an alias defined *inside* a function body is unusable in that same function.
> **Q5.4** — Give two ways to run the real `/usr/bin/ls` while `alias ls='ls --color=auto'` is active, and explain why `alias ls='ls --color=auto'` does not cause infinite recursion.
> **Q5.5** — What does the trailing blank in `alias please='sudo '` change, mechanically?

---

## Exercise 6 — Bash functions for frequently used command sequences

**Step 1.** Write a function using both accepted syntaxes and compare them:

```bash
lab_posix() { echo "POSIX form, args: $#"; }
function lab_keyword { echo "keyword form, args: $#"; }
lab_posix a b
lab_keyword a b c
type -t lab_posix
```

```text
POSIX form, args: 2
keyword form, args: 3
function
```

**Step 2.** Build a production-grade function: local scope, argument validation, an explicit exit status, and no side effects on the caller's variables:

```bash
mkcd() {
    local dir="$1"
    if [[ -z "$dir" ]]; then
        printf 'mkcd: usage: mkcd DIRECTORY\n' >&2
        return 2
    fi
    mkdir -p -- "$dir" && cd -P -- "$dir" || return 1
}
mkcd; echo "status=$?"
mkcd ~/lab-105.1/deep/nested; echo "status=$? pwd=$PWD"
echo "leaked dir variable: [${dir:-unset}]"
cd ~
```

```text
mkcd: usage: mkcd DIRECTORY
status=2
status=0 pwd=/home/student/lab-105.1/deep/nested
leaked dir variable: [unset]
```

**Step 3.** Introspect functions:

```bash
declare -F | head -3
declare -F mkcd
declare -f mkcd
```

```text
declare -f mkcd
mkcd
mkcd () 
{ 
    local dir="$1";
    if [[ -z "$dir" ]]; then
        printf 'mkcd: usage: mkcd DIRECTORY\n' 1>&2;
        return 2;
    fi;
    mkdir -p -- "$dir" && cd -P -- "$dir" || return 1
}
```

**Step 4.** Show that functions, like plain variables, are **not** inherited by default — then export one:

```bash
bash -c 'type -t mkcd || echo "child: no such function"'
export -f mkcd
bash -c 'type -t mkcd'
```

```text
child: no such function
function
```

**Step 5.** Look at *how* the export is transported. It travels as an ordinary environment variable with a mangled name:

```bash
env | grep -A2 'BASH_FUNC'
```

```text
BASH_FUNC_mkcd%%=() {  local dir="$1";
 if [[ -z "$dir" ]]; then
     printf 'mkcd: usage: mkcd DIRECTORY\n' 1>&2;
```

**Step 6.** Demonstrate that a function overrides an external command, and how to reach the original:

```bash
ls() { echo "function ls intercepted: $*"; command ls "$@"; }
ls /etc/hostname
type -a ls
unset -f ls
```

```text
function ls intercepted: /etc/hostname
/etc/hostname
ls is a function
ls () 
{ 
    echo "function ls intercepted: $*";
    command ls "$@"
}
ls is /usr/bin/ls
```

**Step 7.** Make functions persistent the maintainable way — a separate library sourced from `~/.bashrc`:

```bash
mkdir -p ~/.bash_functions.d
cat > ~/.bash_functions.d/mkcd.sh <<'EOF'
# mkcd DIRECTORY — create a directory tree and enter it.
mkcd() {
    local dir="$1"
    [[ -z "$dir" ]] && { printf 'mkcd: usage: mkcd DIRECTORY\n' >&2; return 2; }
    mkdir -p -- "$dir" && cd -P -- "$dir" || return 1
}
EOF
cat >> ~/.bashrc <<'EOF'

# LAB 105.1 — load personal function library
if [ -d "$HOME/.bash_functions.d" ]; then
    for _f in "$HOME/.bash_functions.d"/*.sh; do
        [ -r "$_f" ] && . "$_f"
    done
    unset -v _f
fi
EOF
bash -i -c 'type -t mkcd' 2>/dev/null
```

```text
function
```

**Step 8.** Remove the exported copy so it stops polluting every child process:

```bash
export -fn mkcd
bash -c 'type -t mkcd || echo "child: clean"'
unset -f mkcd
```

```text
child: clean
```

> **Q6.1** — Give three capabilities a function has that an alias does not.
> **Q6.2** — What does `local` actually do, and what breaks in Step 2 if you remove it? (Consider a caller that already uses a variable named `dir`.)
> **Q6.3** — Inside a function, when should you use `return` and when `exit`? What happens if a *sourced* file calls `exit 1`?
> **Q6.4** — Explain the `BASH_FUNC_mkcd%%` name seen in Step 5, including why the encoding is not simply `mkcd`.
> **Q6.5** — `unset mkcd` (no flag) with both a variable `mkcd` and a function `mkcd` defined: which one is removed? Which flags make the intent explicit?

---

## Exercise 7 — Lists, grouping, subshells, and `source` versus execute

The LPI objective lists *lists* as a term: these are the operators that join commands into a single logical unit.

**Step 1.** Compare the four list separators. `;` is unconditional, `&&` and `||` are conditional, `&` is asynchronous:

```bash
true ; echo "A: always runs"
true && echo "B: runs only after success"
false && echo "C: never printed"
false || echo "D: runs only after failure"
( sleep 0.2; echo "E: background finished" ) & echo "F: foreground continues"
wait
```

```text
A: always runs
B: runs only after success
D: runs only after failure
F: foreground continues
E: background finished
```

**Step 2.** Read the exit status of the last command — the value that drives every conditional list:

```bash
grep -q root /etc/passwd ; echo "found  -> $?"
grep -q zzzz /etc/passwd ; echo "absent -> $?"
```

```text
found  -> 0
absent -> 1
```

**Step 3.** Expose the classic `&&`/`||` precedence trap. These operators have *equal* precedence and associate left to right, so this is not an if/else:

```bash
true && echo "then-branch" || echo "else-branch"
echo "--- now make the then-branch fail ---"
true && { echo "then-branch"; false; } || echo "else-branch"
```

```text
then-branch
--- now make the then-branch fail ---
then-branch
else-branch
```

**Step 4.** Contrast the two grouping constructs. `( )` forks a subshell; `{ }` runs in the current shell:

```bash
LAB_G="original"
( LAB_G="changed in subshell"; cd /tmp; echo "inside (): $LAB_G  pwd=$PWD" )
echo "after (): $LAB_G  pwd=$PWD"
{ LAB_G="changed in group"; cd /tmp; echo "inside {}: $LAB_G  pwd=$PWD"; }
echo "after {}: $LAB_G  pwd=$PWD"
cd ~
```

```text
inside (): changed in subshell  pwd=/tmp
after (): original  pwd=/home/student
inside {}: changed in group  pwd=/tmp
after {}: changed in group  pwd=/tmp
```

**Step 5.** Count the shell nesting levels to confirm what forked:

```bash
echo "SHLVL=$SHLVL BASH_SUBSHELL=$BASH_SUBSHELL BASHPID=$BASHPID PID=$$"
( echo "SHLVL=$SHLVL BASH_SUBSHELL=$BASH_SUBSHELL BASHPID=$BASHPID PID=$$" )
bash -c 'echo "SHLVL=$SHLVL"'
```

```text
SHLVL=1 BASH_SUBSHELL=0 BASHPID=4412 PID=4412
SHLVL=1 BASH_SUBSHELL=1 BASHPID=5033 PID=4412
SHLVL=2
```

**Step 6.** Now the difference the objective actually tests. Write a script that sets a variable:

```bash
cat > ~/lab-105.1/setvar.sh <<'EOF'
LAB_FROM_FILE="set by the file"
echo "inside the file: pid=$BASHPID LAB_FROM_FILE=$LAB_FROM_FILE"
EOF
chmod 0755 ~/lab-105.1/setvar.sh
```

**Step 7.** Execute it, then source it, and compare the effect on the *current* shell:

```bash
unset -v LAB_FROM_FILE
~/lab-105.1/setvar.sh
echo "after execute: [${LAB_FROM_FILE:-unset}]  my pid=$BASHPID"
echo "---"
source ~/lab-105.1/setvar.sh
echo "after source : [${LAB_FROM_FILE:-unset}]  my pid=$BASHPID"
```

```text
inside the file: pid=5104 LAB_FROM_FILE=set by the file
after execute: [unset]  my pid=4412
---
inside the file: pid=4412 LAB_FROM_FILE=set by the file
after source : [set by the file]  my pid=4412
```

**Step 8.** Confirm `.` and `source` are the same builtin, and that `.` searches `PATH` when the argument contains no slash:

```bash
type . source
unset -v LAB_FROM_FILE
PATH="$HOME/lab-105.1:$PATH" . setvar.sh
echo "sourced via PATH: [$LAB_FROM_FILE]"
```

```text
. is a shell builtin
source is a shell builtin
inside the file: pid=4412 LAB_FROM_FILE=set by the file
sourced via PATH: [set by the file]
```

**Step 9.** Pass positional parameters to a sourced file — a Bash extension worth knowing:

```bash
set -- outer1 outer2
cat > ~/lab-105.1/args.sh <<'EOF'
echo "sourced file sees \$1=$1 \$#=$#"
EOF
source ~/lab-105.1/args.sh inner1 inner2 inner3
echo "caller still sees \$1=$1 \$#=$#"
set --
```

```text
sourced file sees $1=inner1 $#=3
caller still sees $1=outer1 $#=2
```

> **Q7.1** — Write the output of `false && echo A || echo B ; echo C` and justify each line.
> **Q7.2** — Why is `cd /var/log && ./cleanup.sh` materially safer than `cd /var/log ; ./cleanup.sh`?
> **Q7.3** — A script ends with `( cd /opt/app && ./build.sh )`. The author claims the parentheses are "just for readability." What do they actually guarantee?
> **Q7.4** — Your `~/.bashrc` sets `EDITOR=vim`, but a shell script you run does not see it. Explain the mechanism and give two ways to fix it.
> **Q7.5** — `source ~/.bashrc` and `bash` are both offered as "reload my configuration." Compare them in terms of process count, `SHLVL`, and removed settings (e.g. an alias you just deleted from the file).

---

## Exercise 8 — Prompts: `PS1`, `PROMPT_COMMAND`, `PS2`, `PS4`

**Step 1.** Inspect the current primary prompt. Quote it so the escapes survive:

```bash
echo "$PS1"
```

```text
\[\e]0;\u@\h: \w\a\]${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ 
```

**Step 2.** Save it and build one from scratch, escape by escape:

```bash
LAB_PS1_ORIG="$PS1"
PS1='\u@\h:\w\$ '        ; : "user@host:cwd$"
PS1='[\t] \u@\H \W\$ '   ; : "timestamp, FQDN, basename of cwd"
PS1='\!:\# \$ '          ; : "history number : command number"
```

**Step 3.** Add colour — and observe why `\[` and `\]` are mandatory. First the **wrong** version:

```bash
PS1='\033[01;31m\u@\h\033[00m:\w\$ '
```

Now type a command longer than your terminal width, then press `Ctrl-a` / `Ctrl-e` and watch the cursor land in the wrong column or overwrite the prompt. Then the **correct** version:

```bash
PS1='\[\033[01;31m\]\u@\h\[\033[00m\]:\w\$ '
```

**Step 4.** Show the last exit status in the prompt via `PROMPT_COMMAND`, which runs immediately before `PS1` is printed:

```bash
lab_prompt() {
    local rc=$?                          # MUST be the first statement
    if (( rc == 0 )); then LAB_RC="\[\033[32m\]ok\[\033[0m\]"
    else                   LAB_RC="\[\033[31m\]$rc\[\033[0m\]"; fi
}
PROMPT_COMMAND=lab_prompt
PS1='${LAB_RC} \w\$ '
true
false
grep -q x /nonexistent-file-105 2>/dev/null
```

```text
ok ~$ true
ok ~$ false
1 ~$ grep -q x /nonexistent-file-105 2>/dev/null
2 ~$
```

**Step 5.** Change the continuation prompt and trigger it with an unterminated quote:

```bash
PS2='...continued> '
echo "line one
line two"
```

```text
...continued> line one
line two
```

**Step 6.** Turn `PS4` into a real debugging instrument. The default is `+ `, which tells you nothing about *where* you are:

```bash
cat > ~/lab-105.1/trace-demo.sh <<'EOF'
#!/bin/bash
step_one() { local n=1; echo "in step_one"; }
step_two() { step_one; echo "in step_two"; }
step_two
EOF
chmod 0755 ~/lab-105.1/trace-demo.sh
bash -x ~/lab-105.1/trace-demo.sh 2>&1 | head -6
echo "=== with a useful PS4 ==="
PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: ' bash -x ~/lab-105.1/trace-demo.sh 2>&1 | head -6
```

```text
+ step_two
+ step_one
+ local n=1
+ echo 'in step_one'
in step_one
+ echo 'in step_two'
=== with a useful PS4 ===
+ trace-demo.sh:4:main: step_two
+ trace-demo.sh:3:step_two: step_one
+ trace-demo.sh:2:step_one: local n=1
+ trace-demo.sh:2:step_one: echo 'in step_one'
in step_one
+ trace-demo.sh:3:step_two: echo 'in step_two'
```

**Step 7.** Toggle tracing around a suspect region of an interactive session:

```bash
set -x
LAB_X=$(date +%Y)
set +x
```

```text
++ date +%Y
+ LAB_X=2026
+ set +x
```

**Step 8.** Adjust related interactive behaviour with `shopt` and the history variables — these belong in `~/.bashrc`, never in `~/.profile`:

```bash
shopt -s checkwinsize histappend cmdhist
HISTCONTROL=ignoreboth
HISTSIZE=10000
HISTFILESIZE=20000
shopt | grep -E 'checkwinsize|histappend'
```

```text
checkwinsize   	on
histappend     	on
```

**Step 9.** Restore the original prompt:

```bash
PS1="$LAB_PS1_ORIG"; unset -v PROMPT_COMMAND LAB_RC; unset -f lab_prompt; PS2='> '
```

> **Q8.1** — What is the functional difference between `\w` and `\W`, and between `\h` and `\H`?
> **Q8.2** — Explain precisely what `\[` and `\]` do and what visible symptom appears when they are omitted around a colour escape.
> **Q8.3** — In `lab_prompt`, why must `local rc=$?` be the very first statement in the function?
> **Q8.4** — `PS1` must be a *shell* variable to work — does exporting it help a child Bash inherit your prompt? Explain what actually happens.
> **Q8.5** — Name the prompt variable used by each of: a wrapped multi-line command; `set -x` output; the `select` builtin.

---

## Exercise 9 — Skeleton directories for new accounts

**Step 1.** Inspect the skeleton. Hidden files are the whole point, so `-A` is mandatory:

```bash
ls -lA /etc/skel/
```

```text
total 20
-rw-r--r--. 1 root root  220 Mar 31 09:12 .bash_logout
-rw-r--r--. 1 root root 3771 Mar 31 09:12 .bashrc
-rw-r--r--. 1 root root  807 Mar 31 09:12 .profile
```

**Step 2.** Confirm which directory `useradd` will actually use — do not assume `/etc/skel`:

```bash
useradd -D
grep -vE '^\s*(#|$)' /etc/default/useradd
grep -iE '^(CREATE_HOME|UMASK|HOME_MODE)' /etc/login.defs
```

```text
GROUP=100
HOME=/home
INACTIVE=-1
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=yes
CREATE_HOME	yes
UMASK		022
HOME_MODE	0700
```

**Step 3.** Add a standard file to the skeleton, and set its mode deliberately — `useradd` copies the mode, it does not apply the caller's umask:

```bash
sudo tee /etc/skel/.bash_aliases >/dev/null <<'EOF'
# Site-wide defaults, provisioned from /etc/skel
alias ll='ls -alF'
alias rm='rm -I --preserve-root'
EOF
sudo chmod 0644 /etc/skel/.bash_aliases
sudo mkdir -p /etc/skel/.ssh && sudo chmod 0700 /etc/skel/.ssh
ls -ldA /etc/skel/.bash_aliases /etc/skel/.ssh
```

```text
-rw-r--r--. 1 root root 92 Aug 26 10:31 /etc/skel/.bash_aliases
drwx------. 2 root root  6 Aug 26 10:31 /etc/skel/.ssh
```

**Step 4.** Create an account and verify the copy:

```bash
sudo useradd -m -s /bin/bash -c "Lab user 105.1" labdev
sudo ls -lA /home/labdev/
```

```text
total 24
-rw-r--r--. 1 labdev labdev   92 Aug 26 10:32 .bash_aliases
-rw-r--r--. 1 labdev labdev  220 Aug 26 10:32 .bash_logout
-rw-r--r--. 1 labdev labdev 3771 Aug 26 10:32 .bashrc
-rw-r--r--. 1 labdev labdev  807 Aug 26 10:32 .profile
drwx------. 2 labdev labdev    6 Aug 26 10:32 .ssh
```

**Step 5.** Check ownership and the home directory's own mode:

```bash
sudo stat -c '%n %U:%G %a' /home/labdev /home/labdev/.bash_aliases /home/labdev/.ssh
```

```text
/home/labdev labdev:labdev 700
/home/labdev/.bash_aliases labdev:labdev 644
/home/labdev/.ssh labdev:labdev 700
```

**Step 6.** Prove the skeleton is a *one-shot* template. Change it, then check an existing account:

```bash
echo "alias lab-new='echo added AFTER labdev existed'" | sudo tee -a /etc/skel/.bash_aliases >/dev/null
sudo grep -c 'lab-new' /etc/skel/.bash_aliases /home/labdev/.bash_aliases
```

```text
/etc/skel/.bash_aliases:1
/home/labdev/.bash_aliases:0
```

**Step 7.** Use an alternate skeleton for a role-specific account:

```bash
sudo mkdir -p /etc/skel-ops
sudo tee /etc/skel-ops/.bashrc >/dev/null <<'EOF'
export PATH="/opt/ops/bin:$PATH"
export EDITOR=vim
PS1='[OPS] \u@\h:\w\$ '
EOF
sudo useradd -m -k /etc/skel-ops -s /bin/bash labops
sudo ls -A /home/labops/
sudo head -1 /home/labops/.bashrc
```

```text
.bashrc
export PATH="/opt/ops/bin:$PATH"
```

**Step 8.** Reach *existing* users too — the drop-in mechanism `/etc/skel` cannot provide:

```bash
sudo tee /etc/profile.d/zz-site-defaults.sh >/dev/null <<'EOF'
# Applies to every user, existing and future, at login.
export EDITOR="${EDITOR:-vim}"
export LESS="-R -F -X"
umask 027
EOF
sudo chmod 0644 /etc/profile.d/zz-site-defaults.sh
sudo -u labdev bash -l -c 'echo "EDITOR=$EDITOR umask=$(umask)"'
```

```text
EDITOR=vim umask=0027
```

**Step 9.** Remove the test accounts, including their home directories and mail spools:

```bash
sudo userdel -r labdev 2>/dev/null
sudo userdel -r labops 2>/dev/null
sudo rm -f /etc/skel/.bash_aliases
sudo rmdir /etc/skel/.ssh
sudo rm -rf /etc/skel-ops
sudo rm -f /etc/profile.d/zz-site-defaults.sh
getent passwd labdev labops ; echo "remaining: $?"
```

```text
remaining: 2
```

> **Q9.1** — Which `useradd` option triggers the skeleton copy, and what happens if you omit it on a system where `CREATE_HOME` is `no`?
> **Q9.2** — You edited `/etc/skel/.bashrc` to fix a `PATH` bug for 300 existing users. Did it work? What is the correct mechanism?
> **Q9.3** — Files land in `/home/labdev` owned by `labdev` even though `root` copied them. Which ownership and which permission bits are preserved from `/etc/skel`, and which are not?
> **Q9.4** — Give the option and the configuration key that let you use `/etc/skel-ops` instead of `/etc/skel`, one for a single invocation and one as a system default.
> **Q9.5** — Why should `/etc/skel/.ssh` be mode `0700`, and what happens with OpenSSH if a copied `authorized_keys` ends up group-writable?

---

## Exercise 10 — `~/.bash_logout`, non-interactive traps, and restore

**Step 1.** Confirm when the logout file runs. It is a *login-shell-only* hook:

```bash
cat > ~/.bash_logout <<'EOF'
echo "TRACE: ~/.bash_logout ran (pid $$)" >&2
EOF
echo "--- login shell ---"
bash -l -i -c 'true'
echo "--- non-login shell ---"
bash -i -c 'true'
```

```text
--- login shell ---
TRACE: ~/.bash_logout ran (pid 5411)
--- non-login shell ---
```

**Step 2.** See what distributions actually put there — clearing the console so the next user cannot scroll back:

```bash
cat /etc/skel/.bash_logout
```

```text
# ~/.bash_logout: executed by bash(1) when login shell exits.

# when leaving the console clear the screen to increase privacy
if [ "$SHELL" = "/bin/bash" ]; then
    [ -x /usr/bin/clear_console ] && /usr/bin/clear_console -q
fi
```

**Step 3.** Reproduce the most common production breakage in this objective. Bash sources `~/.bashrc` when it detects that stdin is a network connection — even for a non-interactive remote command:

```bash
cp ~/.bashrc ~/lab-105.1/bashrc.safe
sed -i '1i echo "Welcome to $(hostname)!"' ~/.bashrc
ssh localhost 'echo REMOTE-OK'
echo "--- now try a file transfer ---"
scp ~/lab-105.1/bashrc.safe localhost:/tmp/ 2>&1 | tail -3
```

```text
Welcome to lab01!
REMOTE-OK
--- now try a file transfer ---
Welcome to lab01!
bash: line 1: Received message too long 1114795883
```

**Step 4.** Apply the standard guard — the reason every shipped `~/.bashrc` starts with it:

```bash
sed -i '1i case $- in *i*) ;; *) return;; esac' ~/.bashrc
head -2 ~/.bashrc
scp ~/lab-105.1/bashrc.safe localhost:/tmp/ 2>&1 | tail -2
```

```text
case $- in *i*) ;; *) return;; esac
echo "Welcome to lab01!"
bashrc.safe    100% 3771     4.1MB/s   00:00
```

**Step 5.** Examine the PAM-level environment, which is neither a shell script nor Bash's responsibility:

```bash
cat /etc/environment
grep -n 'pam_env' /etc/pam.d/login /etc/pam.d/sshd 2>/dev/null | head -4
```

```text
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
/etc/pam.d/login:12:session       required     pam_env.so readenv=1
/etc/pam.d/sshd:9:session         required     pam_env.so
```

**Step 6.** Prove it is not shell syntax:

```bash
echo 'LAB_PAM=hello' | sudo tee -a /etc/environment >/dev/null
echo 'LAB_BAD=$HOME/x' | sudo tee -a /etc/environment >/dev/null
ssh localhost 'echo "LAB_PAM=[$LAB_PAM] LAB_BAD=[$LAB_BAD]"'
sudo sed -i '/^LAB_PAM=\|^LAB_BAD=/d' /etc/environment
```

```text
LAB_PAM=[hello] LAB_BAD=[$HOME/x]
```

**Step 7.** Full restore — return the system to its original state:

```bash
# per-user files
cp -f ~/lab-105.1/backup/.bashrc      ~/.bashrc      2>/dev/null
cp -f ~/lab-105.1/backup/.profile     ~/.profile     2>/dev/null
cp -f ~/lab-105.1/backup/.bash_logout ~/.bash_logout 2>/dev/null
[ -f ~/lab-105.1/backup/.bash_profile ] || rm -f ~/.bash_profile
[ -f ~/lab-105.1/backup/.bash_login ]   || rm -f ~/.bash_login
rm -rf ~/.bash_functions.d ~/bin/lab-tool

# system files
sudo rm -f /etc/profile.d/00-lab-trace.sh /usr/local/bin/lab-tool

# verify nothing is left
bash -l -i -c 'true' 2>&1 | grep -c TRACE
grep -c 'LAB 105.1' ~/.bashrc ~/.profile
```

```text
0
0
0
```

**Step 8.** Optionally keep the lab tree for review, or remove it:

```bash
rm -rf ~/lab-105.1
```

> **Q10.1** — Exactly when does `~/.bash_logout` execute, and when does it *not*? Name a task that belongs there and one that does not.
> **Q10.2** — Explain the mechanism behind the `scp` failure in Step 3. Why does producing output on stdout break the transfer specifically?
> **Q10.3** — Decode `case $- in *i*) ;; *) return;; esac`. Why `return` and not `exit`?
> **Q10.4** — `/etc/environment` is not read by Bash. Which component reads it, and name three shell features that are unavailable in it.
> **Q10.5** — A user reports that `PATH` set in `/etc/environment` is correct over SSH but missing in a `cron` job. Explain, and give the correct place for the setting.

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 1 — Classify the shell

**A1.1** — The letter `i`. `$-` reports *option flags* the shell was started with or that were changed by `set`; login status is not an option flag but a property recorded at startup (whether `argv[0]` began with `-` or `-l`/`--login` was passed). Bash exposes it through the read-only shell option `login_shell`, queried with `shopt -q login_shell`.

**A1.2** — `su student` starts an interactive **non-login** shell, so it reads only `~/.bashrc` (plus `/etc/bash.bashrc` where the distribution supports it) and keeps most of the invoking user's environment. `su - student` (equivalently `su -l`) starts a **login** shell: it reads `/etc/profile`, then `/etc/profile.d/*.sh`, then the first of `~/.bash_profile` → `~/.bash_login` → `~/.profile`, and resets the environment. `PATH` is normally set in `/etc/profile` and `~/.profile`, which is why only the `-` form gives the target user the correct `PATH` — the classic symptom being `sbin` utilities "not found" after `su root`.

**A1.3** — Formally: a non-interactive, non-login shell reads only the file named by `$BASH_ENV`, if that variable is set (the value is expanded and used directly as a filename; `PATH` is *not* searched). However, Bash also detects when its standard input is connected to a network socket — as when run by `sshd` for a remote command — and in that case reads `~/.bashrc`. Both answers are correct; the second is the one that causes real outages (see Exercise 10).

**A1.4** — `ps` shows `argv[0]`, which is only a *convention*: the login program prepends `-` to signal "login shell". Any process can set `argv[0]` to whatever it likes, `bash --login` does not produce a leading hyphen, and a shell can be a login shell without the hyphen. `shopt -q login_shell` asks the shell itself about its recorded state, which is authoritative.

---

### Exercise 2 — Startup file order

**A2.1** — For an **interactive login shell**, after `/etc/profile`, Bash reads the first file that exists and is readable from:
1. `~/.bash_profile`
2. `~/.bash_login`
3. `~/.profile`

The remaining candidates are **not read at all**. This is why adding a `~/.bash_profile` on a Debian system silently disables `~/.profile` — a very common self-inflicted outage.

**A2.2** — A login shell does not source `~/.bashrc`; the two chains are independent by design (`~/.profile` = "once per session, environment"; `~/.bashrc` = "every interactive shell, interactive behaviour"). You see `~/.bashrc` output in a real terminal for one of two reasons: either your terminal emulator opens a *non-login* interactive shell (so `~/.bashrc` is the only file read), or your `~/.profile` contains the conventional bridge `[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"` seen in Step 8.

**A2.3** — `~/.bashrc` runs for *every* interactive shell, so each nested `bash` prepends again:

```text
/home/student/bin:/home/student/bin:/home/student/bin:/usr/local/bin:/usr/bin:...
```

The correct home is `~/.profile` (or `~/.bash_profile`), which runs once per login session; `PATH` is exported and therefore inherited by every child shell. If it must live in `~/.bashrc`, guard it with the idempotent `case ":${PATH}:" in *:"$HOME/bin":*) ;; *) ... ;; esac` pattern from Exercise 4.

**A2.4** — `/etc/profile` is a package-owned file: a distribution upgrade may replace it, silently discarding your change, or leave a `.rpmnew`/`.dpkg-dist` conflict for an administrator to merge. `/etc/profile.d/*.sh` is the supported extension point — files there are sourced by `/etc/profile` (and by `/etc/bashrc` for non-login interactive shells on Red Hat family systems), survive upgrades, can be added and removed atomically by configuration management, and are individually attributable to a package or a site policy.

**A2.5** — Any process that can set `BASH_ENV` in the environment of a program that later runs a non-interactive `bash` script gets arbitrary code executed with that script's privileges. This is why `BASH_ENV` (and `ENV`, and `SHELLOPTS`) are ignored when Bash detects it is running setuid/setgid without `-p`, and why sanitising the environment matters for anything privileged. The POSIX/`sh` equivalent for **interactive** shells is `ENV`; Bash uses it instead of `BASH_ENV` when invoked as `sh` or in POSIX mode.

---

### Exercise 3 — Shell versus environment variables

**A3.1**
- `set` (no arguments): every **shell variable** — exported or not — *and* every function definition. It is the only one that shows non-exported variables together with functions.
- `env`: the **environment** actually passed to child processes (an external coreutils command, so it can only see what it inherited). Also modifies that environment for one command.
- `export -p`: the exported variables *as `export` statements*, i.e. re-usable shell input, from the shell's own point of view (includes read-only/exported attributes).
- `declare -p NAME`: one variable with its **attributes** and type — `--` plain, `-x` exported, `-r` readonly, `-i` integer, `-a` indexed array, `-A` associative array.

**A3.2** — `export -n VAR` removes only the export attribute: the variable still exists in the current shell with its value (`declare -p` prints `declare -- VAR="…"`, `echo $VAR` still works), it simply stops being inherited. `unset -v VAR` destroys it entirely: `declare -p` reports "not found" and `${VAR:-unset}` expands to the default.

**A3.3** — No: `type env` reports `env is /usr/bin/env`, an external coreutils binary. `LAB_ONCE=yes env` works because the assignment prefix modifies the environment of the command being executed, and `env` is a separate process that prints its inherited environment. `LAB_ONCE=yes echo $LAB_ONCE` prints nothing because `$LAB_ONCE` is expanded by the **current** shell *before* the assignment takes effect and before `echo` runs — and `echo` is a builtin, so there is no new process to inherit anything either.

**A3.4** — Without POSIX mode, `set` prints shell variables *and* the full source text of every defined function. A default interactive Bash session on most distributions carries dozens of functions (bash-completion alone defines hundreds of lines). `set -o posix` makes `set` conform to POSIX, printing only variable assignments — which is why `( set -o posix; set )` is the idiomatic way to dump variables cleanly.

**A3.5** — (1) The variable was exported in one shell but the script runs in a *different* session or was started before the export — exports propagate only downward, to children created after the export, never upward or sideways. (2) The export lives in `~/.bashrc`, and the script runs in a non-interactive shell that never reads `~/.bashrc` (Exercise 2). A third frequent cause: the assignment was written as `export VAR = value` with spaces, which Bash parses as running the command `export` with three arguments.

---

### Exercise 4 — `PATH` and the hash table

**A4.1** — `/usr/bin/foo` runs. Bash walks `PATH` left to right and selects the first entry that is a **regular file with execute permission** for the calling user. `/usr/local/bin/foo` is found first but is not executable (0644), so the search continues. Note the failure mode: had `/usr/local/bin/foo` been mode 0755 but syntactically broken, it would have run and `PATH` order alone would explain the mystery.

**A4.2** — Bash caches the full pathname of each command it executes in a hash table (the `hashall`/`-h` option, on by default) to avoid a `PATH` scan per invocation. Changing `PATH` does not invalidate entries already cached, so the stale path keeps executing while `type -a`, which performs a fresh search, reports the new one. Fixes: `hash -d lab-tool` (drop one entry) or `hash -r` (drop all). `hash -r` is also what you need after installing a package into a directory earlier in `PATH` than where an older copy lives.

**A4.3** — A leading colon (`:/usr/bin`), a trailing colon (`/usr/bin:`), and a doubled colon (`/usr/bin::/bin`) — each contains an empty field, which Bash treats as `.`, the current working directory. An explicit `.` in `PATH` is the fourth, equally dangerous, spelling. In a shared or world-writable directory, an attacker drops an executable named after a common command (`ls`, `ps`, `sudo`) and waits for an administrator to `cd` there and type it; the attacker's code then runs with the administrator's privileges. `PATH` must never contain the current directory, least of all for `root`.

**A4.4** — `which` is an external program (or, on Debian, a shell script) that only searches `PATH`. It cannot see aliases, shell functions, builtins, or the hash table, and it may read a different `PATH` than the one your shell just modified. `type` is a Bash builtin that resolves a name exactly the way the shell will: alias → function → builtin → hash table → `PATH`. **`type` — specifically `type -a`, plus `hash` — is authoritative.** `command -v` is the portable, script-friendly equivalent.

**A4.5** — `PATH` is an **environment** setting: it must be established once per session and is inherited by every child process, so it belongs in `~/.profile`/`~/.bash_profile`. Re-running it in `~/.bashrc` produces duplicated entries in nested shells. An `alias` is a purely **interactive, non-inherited shell feature**: it is not exported, not visible to children, and irrelevant to scripts, so it must be re-created in every interactive shell — which is exactly what `~/.bashrc` is for. The same rule places shell functions and `shopt`/history settings in `~/.bashrc`, and `umask`, `PATH` and other exports in `~/.profile`.

---

### Exercise 5 — Aliases

**A5.1** — Highest to lowest: **reserved word** (`if`, `for`, `while`, `function`, `[[`, `time`) → **alias** → **function** → **builtin** → **external file found in `PATH`**. Aliases sit near the top because they are expanded during parsing, before the word is ever resolved as a command; reserved words beat them because the parser recognises keywords first.

**A5.2** — An alias is pure **textual substitution**: `greet World` expanded to `echo "Hello, $1!" World`. In the interactive shell `$1` is unset, so it expanded to the empty string, and `World` was simply appended as a further argument to `echo`. There is no way to place an argument in the middle of an alias. The correct construct is a **function**, where `$1`, `$@` and `$#` are the function's own positional parameters:

```bash
greet() { echo "Hello, ${1:?name required}!"; }
```

**A5.3** — Aliases are expanded **when a line of input is read**, not when it is executed. In the one-line version, `alias hi=…` and `hi` are on the same input line, so the whole line was parsed — and `hi` resolved as a command word — before the `alias` builtin ever ran. The three-line version reads and executes line by line, so the alias exists by the time line 3 is read. The same rule applies to compound commands: a function body, an `if`, or a `{ … }` group is read as a single unit, so an alias defined inside it cannot be used inside it. This is the standard argument for preferring functions in any file that must be self-contained.

**A5.4** — Any of: `\ls`, `'ls'`, `"ls"`, `command ls`, `/usr/bin/ls`, or `unalias ls` first. Quoting *any* character of a word suppresses alias lookup for that word; `command` explicitly bypasses aliases and functions. There is no infinite recursion because Bash does not re-expand an alias while it is already being expanded — the replacement text is checked for aliases, but the alias currently under expansion is excluded. (The related rule: the *first* word of the replacement is re-checked, which combined with the trailing-blank rule enables alias chaining.)

**A5.5** — Normally only the **first** word of a command is checked for alias expansion. If the last character of an alias's *value* is a blank, Bash also checks the **next** word for alias expansion. So `please ll` expands `please` → `sudo `, then, because of the trailing blank, also expands `ll` → `ls -alF`, giving `sudo ls -alF`. Without the trailing blank, `ll` would be passed to `sudo` literally and `sudo` would report `ll: command not found` — since `sudo` executes a program, and `ll` is not one.

---

### Exercise 6 — Functions

**A6.1** — Any three of: (1) accepts positional arguments (`$1`, `$@`, `$#`) and can place them anywhere; (2) can contain multiple statements, loops, conditionals, and local state; (3) supports `local` variables that do not leak to the caller; (4) returns a meaningful exit status via `return N`; (5) can be exported to child shells with `export -f`; (6) works in non-interactive shells and scripts without `shopt -s expand_aliases`; (7) can recurse and can call the command it shadows via `command`.

**A6.2** — `local` creates a variable visible only in the function and in functions it calls (Bash uses dynamic scoping), and restores any previous value when the function returns. Without it, `dir="$1"` assigns to a **global** variable: a caller that maintains its own `dir` would silently have it overwritten, and the value would persist after `mkcd` returned. In long-lived interactive shells and in libraries sourced from `~/.bashrc` this is a real source of intermittent, hard-to-reproduce bugs. Rule: every variable inside a function is `local` unless you deliberately intend a side effect.

**A6.3** — `return N` exits the **function** and sets `$?` to `N` (0–255); `exit N` terminates the entire **shell process**. Inside a function used interactively or in a sourced library, `exit` closes the user's terminal session — which is why a *sourced* file must use `return` to abort. Note that `return` at the top level of a sourced file is legal and stops sourcing (this is precisely the mechanism behind the `~/.bashrc` non-interactive guard); at the top level of an *executed* script it is an error.

**A6.4** — Exported functions cannot be transported as functions — the environment is a flat list of `NAME=value` strings. Bash encodes them as an environment variable whose name is `BASH_FUNC_<name>%%` and whose value is the literal text `() { … }`; a receiving Bash sees the prefix and re-defines the function. The odd `BASH_FUNC_`/`%%` wrapper is deliberately **not** a valid shell identifier, so no ordinary assignment can forge one. Historically the encoding was just `name=() { … }`, and the parser evaluated everything after the closing brace — the flaw exploited by Shellshock (CVE-2014-6271, 2014). Practical consequence: exported functions travel to *every* child process, so `export -f` should be used sparingly and undone with `export -fn`.

**A6.5** — Plain `unset mkcd` removes the **variable** first; the function survives. Only if no variable of that name exists does it remove the function. Always be explicit: `unset -v mkcd` for the variable, `unset -f mkcd` for the function.

---

### Exercise 7 — Lists, grouping and sourcing

**A7.1**

```text
B
C
```

`false` returns non-zero, so `&& echo A` is skipped and A is never printed. The exit status of the skipped `&&` list is still `false`'s non-zero status, so `|| echo B` runs and prints `B`. `;` is unconditional, so `echo C` prints `C`.

**A7.2** — With `;`, the second command runs regardless of whether `cd` succeeded. If `/var/log` does not exist or is not accessible, the shell stays in the current directory and `./cleanup.sh` either fails or — far worse — runs a *different* `cleanup.sh` against the wrong tree. `&&` makes the second command conditional on the first's success. In non-interactive scripts the same guarantee is often expressed as `cd /var/log || exit 1`, or globally with `set -e`.

**A7.3** — Parentheses create a **subshell**: a forked child process. Everything inside — the working directory change, variable assignments, `set` options, exported variables, `trap` handlers, redirections — is discarded when the subshell exits. So the guarantee is that the rest of the script continues in the **original working directory** with the original environment, no matter what `build.sh` does. That is a correctness property, not a stylistic one. The trade-off is a `fork()` per group and the fact that assignments made inside cannot be observed outside (the classic `while read … | ...` variable-loss bug has the same root cause).

**A7.4** — `~/.bashrc` is read only by **interactive** shells. A script executed as `./script.sh` or `bash script.sh` is non-interactive and non-login, so it never sees anything defined there. Fixes: (1) move `export EDITOR=vim` to `~/.profile`/`~/.bash_profile` so it is set once at login and inherited by every descendant, including scripts; or (2) set it system-wide in `/etc/profile.d/*.sh` (or `/etc/environment` via PAM) for all users. A third option, `source ~/.bashrc` at the top of the script, is possible but poor practice — it couples a script to one user's interactive configuration.

**A7.5**

| | `source ~/.bashrc` | `bash` |
|---|---|---|
| Processes | none created — runs in the current shell | forks a new shell process |
| `SHLVL` | unchanged | incremented by 1 |
| Removed settings | **not** removed: an alias or function you deleted from the file is still defined, because sourcing only *adds* | still present in the new shell too — it inherits nothing non-exported, but the parent shell remains underneath, and `exit` returns you to it with the old settings |
| Cost | cheap, but accumulates duplicated `PATH` entries if the file is not idempotent | leaves shells nested; repeated use builds a stack |

Neither reliably removes a deleted definition. The only clean reload is `exec bash` (replaces the current process, `SHLVL` unchanged) or a new login session.

---

### Exercise 8 — Prompts

**A8.1** — `\w` is the **full** current working directory with `$HOME` abbreviated to `~` (`~/lab-105.1/deep`); `\W` is only its **basename** (`deep`). `\h` is the hostname up to the first dot (`lab01`); `\H` is the full hostname as configured (`lab01.example.com`). On systems with long FQDNs and deep directory trees, `\W` and `\h` keep the prompt short — but `\w` is safer when you routinely work in similarly named directories.

**A8.2** — `\[` and `\]` bracket a sequence of **non-printing** characters. Readline uses them to compute the prompt's visible width, which it needs in order to know where the cursor really is. Omitting them makes Readline count the ANSI escape bytes as visible columns, so it over-estimates the prompt width. The symptoms appear only once a command line approaches the terminal width: the line wraps early or overwrites the prompt, `Ctrl-a`/`Ctrl-e` and arrow keys land in the wrong column, and recalling long history entries visibly corrupts the display. The bug is invisible with short commands, which is why it survives in so many hand-written prompts.

**A8.3** — `$?` holds the exit status of the *last command executed*, and it is overwritten by every subsequent command — including the `local` builtin, an `if`, or an assignment inside the function. Capturing it in the very first statement is the only way to read the status of the command the user actually ran. (Even `local rc=$?` is subtly safe here because the assignment's expansion of `$?` happens before `local` sets its own status; splitting it into `local rc; rc=$?` would already be too late.)

**A8.4** — Exporting `PS1` does not give a child Bash your prompt in any useful way. A child **interactive** shell reads `~/.bashrc`, which normally assigns `PS1` unconditionally and therefore overwrites whatever it inherited. A child **non-interactive** shell unsets `PS1` entirely — Bash uses `PS1`'s emptiness as one signal of non-interactivity, and some scripts test `[ -z "$PS1" ]` for exactly that. The correct way to share a prompt is to put the assignment in `~/.bashrc` (per user) or in `/etc/profile.d/*.sh` guarded by an interactivity test (site-wide).

**A8.5** — Wrapped multi-line command → `PS2` (default `> `). `set -x` trace output → `PS4` (default `+ `; the first character is repeated once per level of indirection to show nesting depth). The `select` builtin's menu → `PS3` (default `#? `).

---

### Exercise 9 — Skeleton directories

**A9.1** — `-m` (`--create-home`) creates the home directory and copies the skeleton into it. Without `-m` on a system where `/etc/login.defs` sets `CREATE_HOME no`, the account is created with a home directory recorded in `/etc/passwd` that **does not exist**: the user can authenticate, but the login shell starts in `/` (or fails), no dotfiles are present, `PATH` and prompt come only from `/etc/profile`, and anything writing to `$HOME` fails. `-M` forces the opposite (never create), and `useradd -D`/`grep CREATE_HOME /etc/login.defs` tells you which default is in force.

**A9.2** — No. `/etc/skel` is a **template applied exactly once**, at account creation; it has no ongoing relationship with existing home directories, and the files it produced are owned by the users, who may have edited them. The correct mechanism for existing users is a drop-in in `/etc/profile.d/*.sh` (login shells) and/or the system-wide interactive file (`/etc/bash.bashrc` on Debian/SUSE, `/etc/bashrc` on Red Hat family) — both are read at every login by every user without touching their home directories. For anything more complex, use configuration management. Update `/etc/skel` too, so future accounts start consistent.

**A9.3** — **Ownership is not preserved**: `useradd` sets owner and group to the new user's UID and primary GID on every copied file. **Permission bits are preserved** from `/etc/skel` — the copying process's `umask` is not applied — which is why `/etc/skel/.ssh` must already be `0700` and why a stray world-readable file in the skeleton propagates to every future account. The **home directory itself** is a separate case: its mode comes from `HOME_MODE` in `/etc/login.defs` (shadow-utils 4.7 and later), falling back to `0777 & ~UMASK` on older versions. Symlinks and subdirectory trees are copied recursively.

**A9.4** — For a single invocation: `useradd -m -k /etc/skel-ops …` (`--skel`). As a system default: the `SKEL=` key in `/etc/default/useradd`, visible in `useradd -D` output. Note that `adduser` (the Debian Perl wrapper) does **not** read `/etc/default/useradd`; it uses `SKEL=` in `/etc/adduser.conf`.

**A9.5** — `.ssh` mode `0700` keeps private keys and `authorized_keys` unreadable by other users; a group- or world-readable `.ssh` exposes key material and lets others enumerate trusted keys. OpenSSH additionally enforces **StrictModes** (on by default): if `~`, `~/.ssh`, or `~/.ssh/authorized_keys` is writable by group or other, `sshd` **silently refuses** to use that `authorized_keys` file and falls back to password authentication — logging the reason only at debug level. It is a frequent "my key stopped working and nothing is in the log" incident, and a bad `/etc/skel` reproduces it on every new account.

---

### Exercise 10 — Logout, non-interactive traps, restore

**A10.1** — `~/.bash_logout` executes when an **interactive login shell** exits — via `exit`, `logout`, or `Ctrl-D`. It does **not** run for interactive non-login shells (a terminal emulator tab on most desktops), for non-interactive shells or scripts, or when the shell is killed with `SIGKILL` or the terminal is destroyed abruptly. Appropriate: clearing the console for privacy, flushing history (`history -a`), removing a per-session temporary directory, releasing a session lock. Inappropriate: anything the system must be able to rely on — audit logging, credential revocation, unmounting shared storage — because the file is trivially skipped by any of the cases above. Those belong in a PAM `session` module or a systemd user unit.

**A10.2** — `scp` (in its traditional mode) and `sftp` open a shell on the remote host and speak a **binary protocol over stdout/stdin**. Bash, detecting that its stdin is a network connection, sources `~/.bashrc` even though the shell is non-interactive; the `echo` at the top of that file injects `Welcome to lab01!` into the protocol stream. The client parses those bytes as a protocol frame, reads a nonsensical length field, and aborts with `Received message too long`. Anything that writes to **stdout** at shell start breaks it — banners, `fortune`, `neofetch`, `stty`, an interactive `read`. Writing to **stderr** is survivable but still pollutes every remote command. The general rule: `~/.bashrc` must produce no output.

**A10.3** — `$-` holds the current option flags; the `case` pattern `*i*` tests whether the interactive flag `i` is present. If it is, the empty branch `;;` does nothing and execution continues into the rest of the file. If it is not — a non-interactive shell, e.g. the one `sshd` started for `scp` — `return` immediately stops sourcing the file, so nothing further executes. `return` is required rather than `exit` because `~/.bashrc` is **sourced** into an existing shell: `exit` would terminate that shell, killing the SSH session or the `scp` transfer outright instead of merely skipping the configuration.

**A10.4** — `/etc/environment` is read by the PAM module **`pam_env(8)`**, configured as a `session` (or `auth`) line in `/etc/pam.d/*`, and applied before any shell starts — which is why it works for graphical logins, `sshd` and `login` alike, regardless of the user's shell. It is a plain list of `KEY=value` lines and supports none of: variable expansion (`$HOME` stays literal, as Step 6 showed), command substitution, globbing, conditionals or loops, the `export` keyword, comments other than whole-line `#`, or referring to a variable defined on a previous line. It is also not shell-specific: it applies equally to `zsh`, `fish` and non-shell sessions. For richer behaviour use `/etc/security/pam_env.conf`, which does support `DEFAULT`/`OVERRIDE` and `@{…}`/`${…}` expansion.

**A10.5** — `cron` jobs are not PAM login sessions in the same sense, and traditionally `crond` does not invoke `pam_env` for `/etc/environment` (behaviour varies by distribution and by whether `pam_env` is listed in `/etc/pam.d/crond`). Crucially, `cron` also runs commands with `/bin/sh -c`, a **non-interactive, non-login** shell that reads neither `/etc/profile` nor `~/.profile` nor `~/.bashrc`, and it supplies a deliberately minimal `PATH` — commonly `/usr/bin:/bin`. The correct fixes, in order of preference: set `PATH=` explicitly at the top of the crontab (cron supports `NAME=value` lines directly), or use absolute pathnames for every command in the job, or have the job source a dedicated environment file it owns. Never assume a `cron` job inherits an interactive user's environment.

</details>

---

## Sources

- LPI — *Exam 101 Objectives, LPIC-1 version 5.0*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — *Exam 102 Objectives, LPIC-1 version 5.0* (Topic 105.1 is examined in 102-500): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- GNU — *Bash Reference Manual, "Bash Startup Files"*: <https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html>
- GNU — *Bash Reference Manual, "Shell Variables"* (`BASH_ENV`, `PROMPT_COMMAND`, `PS1`–`PS4`, `SHLVL`): <https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html>
- GNU — *Bash Reference Manual, "Aliases"*: <https://www.gnu.org/software/bash/manual/html_node/Aliases.html>
- GNU — *Bash Reference Manual, "Shell Functions"*: <https://www.gnu.org/software/bash/manual/html_node/Shell-Functions.html>
- GNU — *Bash Reference Manual, "Lists of Commands"*: <https://www.gnu.org/software/bash/manual/html_node/Lists.html>
- GNU — *Bash Reference Manual, "Controlling the Prompt"*: <https://www.gnu.org/software/bash/manual/html_node/Controlling-the-Prompt.html>
- GNU Coreutils — *env invocation*: <https://www.gnu.org/software/coreutils/manual/html_node/env-invocation.html>
- shadow-utils — `useradd(8)`: <https://man7.org/linux/man-pages/man8/useradd.8.html>
- shadow-utils — `login.defs(5)` (`CREATE_HOME`, `HOME_MODE`, `UMASK`): <https://man7.org/linux/man-pages/man5/login.defs.5.html>
- Linux-PAM — `pam_env(8)` and `environment(5)`: <https://man7.org/linux/man-pages/man8/pam_env.8.html> · <https://man7.org/linux/man-pages/man5/environment.d.5.html>
- OpenSSH — `sshd(8)`, *StrictModes* and `~/.ssh/authorized_keys` permission requirements: <https://man.openbsd.org/sshd_config#StrictModes>