# LPIC-1 — 105.2 Customize or Write Simple Scripts
## Guided Lab Exercises

**Target skills:** `sh` syntax (loops, tests), command substitution, exit status handling, conditional mailing to the superuser, correct selection of the interpreter via the shebang line, and the location / ownership / execution / SUID rights of scripts.

> **Portability convention used throughout.** LPI asks for *standard sh syntax*. Where a construct is Bash-only (`[[ ]]`, `((` `))`, arrays, `$(<file)`) it is marked **[bash-only]**. Everything unmarked runs under `dash`, `busybox sh`, `ksh` and `bash`. On Debian/Ubuntu `/bin/sh` is `dash`, so this distinction is not academic.

---

## Exercise 0 — Lab setup

1. Create a clean working directory and enter it:

```bash
mkdir -p ~/lab-105.2 && cd ~/lab-105.2
```

2. Identify what `/bin/sh` actually is on your system:

```bash
ls -l /bin/sh
readlink -f /bin/sh
```

Expected output on Debian/Ubuntu:

```
lrwxrwxrwx 1 root root 4 Mar 20 08:41 /bin/sh -> dash
/usr/bin/dash
```

Expected output on RHEL/Fedora/openSUSE:

```
lrwxrwxrwx 1 root root 4 Mar 20 08:41 /bin/sh -> bash
/usr/bin/bash
```

3. Record your shell and its version:

```bash
echo "$0"
bash --version | head -1
```

**Questions**

- **Q0.1** — If `/bin/sh` is a symlink to `bash`, does a script starting with `#!/bin/sh` behave identically to one starting with `#!/bin/bash`?
- **Q0.2** — Why is `echo $0` an unreliable way to discover which shell a *script* is running under?

---

## Exercise 1 — The shebang: how the kernel picks the interpreter

The `#!` mechanism is not implemented by the shell. It is implemented by the kernel, in the `binfmt_script` handler of `execve(2)`. This exercise proves it.

1. Build an "interpreter" that does nothing but report the arguments the kernel hands it:

```bash
cat > showargs <<'EOF'
#!/bin/sh
printf 'interpreter %s got %d argument(s):\n' "$0" "$#"
printf '  [%s]\n' "$@"
EOF
chmod 755 showargs
```

2. Build a "script" whose shebang points at that interpreter and passes several options:

```bash
cat > demo.sh <<'EOF'
#!/home/REPLACE_ME/lab-105.2/showargs -a -b -c
this line is never executed
EOF
sed -i "s|/home/REPLACE_ME/lab-105.2|$PWD|" demo.sh
chmod 755 demo.sh
head -1 demo.sh
```

3. Run it, first with no arguments, then with two:

```bash
./demo.sh
./demo.sh foo bar
```

Expected output (paths will show your own `$PWD`):

```
interpreter /home/student/lab-105.2/showargs got 2 argument(s):
  [-a -b -c]
  [./demo.sh]
interpreter /home/student/lab-105.2/showargs got 4 argument(s):
  [-a -b -c]
  [./demo.sh]
  [foo]
  [bar]
```

4. Now break the interpreter path deliberately and observe the error:

```bash
printf '#!/bin/bahs\necho never reached\n' > typo.sh
chmod 755 typo.sh
./typo.sh
echo "exit status: $?"
```

Expected:

```
bash: ./typo.sh: /bin/bahs: bad interpreter: No such file or directory
exit status: 127
```

5. Reproduce the single most common real-world shebang failure — a file saved with DOS line endings:

```bash
printf '#!/bin/bash\r\necho "hello"\r\n' > crlf.sh
chmod 755 crlf.sh
head -1 crlf.sh | cat -A
./crlf.sh
echo "exit status: $?"
```

Expected:

```
#!/bin/bash^M$
bash: ./crlf.sh: cannot execute: required file not found
exit status: 127
```

(On bash < 5.1 the message is `/bin/bash^M: bad interpreter: No such file or directory`. Both mean the same thing.)

6. Repair it and confirm:

```bash
sed -i 's/\r$//' crlf.sh     # or: dos2unix crlf.sh
head -1 crlf.sh | cat -A
./crlf.sh
```

Expected:

```
#!/bin/bash$
hello
```

7. Compare an absolute shebang against the `env` form:

```bash
printf '#!/usr/bin/env bash\necho "interpreter: $BASH_VERSION"\n' > envshebang.sh
chmod 755 envshebang.sh
./envshebang.sh
```

**Questions**

- **Q1.1** — In step 3, why did the interpreter receive `-a -b -c` as **one** argument instead of three? What would happen to that same file on FreeBSD?
- **Q1.2** — In step 3 the second argument is `./demo.sh`, not `demo.sh` or an absolute path. What does that tell you about what the kernel passes to the interpreter?
- **Q1.3** — In step 4 the exit status was 127, and the error names `/bin/bahs`, not `./typo.sh`. Which component printed that message, and why is 127 the status?
- **Q1.4** — Give one concrete advantage and one concrete security disadvantage of `#!/usr/bin/env bash` over `#!/bin/bash`.
- **Q1.5** — A file has no shebang at all, is executable, and you run `./noshebang.sh` from an interactive bash session. What executes it? What happens if the same file is `exec()`ed from a C program?

---

## Exercise 2 — Location, ownership, permissions, and the SUID trap

1. Write a small script and try to run it before making it executable:

```bash
cat > sysinfo.sh <<'EOF'
#!/bin/sh
printf 'host      : %s\n' "$(uname -n)"
printf 'kernel    : %s\n' "$(uname -r)"
printf 'uptime    : %s\n' "$(uptime -p 2>/dev/null || cut -d. -f1 /proc/uptime)"
printf 'real uid  : %s (%s)\n' "$(id -u)"  "$(id -un)"
printf 'eff. uid  : %s (%s)\n' "$(id -u -r 2>/dev/null; id -u)" "$(id -un)"
EOF
ls -l sysinfo.sh
./sysinfo.sh
echo "exit status: $?"
```

Expected:

```
-rw-r--r-- 1 student student  312 Aug 26 10:12 sysinfo.sh
bash: ./sysinfo.sh: Permission denied
exit status: 126
```

2. Make it executable and run it three different ways:

```bash
chmod 755 sysinfo.sh
./sysinfo.sh          # execve() -> kernel reads the shebang
sh sysinfo.sh         # sh reads the file; shebang is just a comment
. ./sysinfo.sh        # sourced into the CURRENT shell
```

3. Prove that `PATH` — not the file — decides whether a bare name works:

```bash
sysinfo.sh
echo "exit status: $?"
echo "$PATH"
```

Expected:

```
bash: sysinfo.sh: command not found
exit status: 127
```

4. Install it where a user-level script belongs, and refresh the shell's command hash:

```bash
mkdir -p ~/.local/bin
install -m 0755 sysinfo.sh ~/.local/bin/sysinfo
case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
hash -r
command -v sysinfo
sysinfo
```

5. Install a *system-wide* copy with correct ownership, and inspect the conventional directories:

```bash
sudo install -o root -g root -m 0755 sysinfo.sh /usr/local/bin/sysinfo
ls -l /usr/local/bin/sysinfo
```

Expected:

```
-rwxr-xr-x 1 root root 312 Aug 26 10:19 /usr/local/bin/sysinfo
```

6. **The SUID experiment.** Attempt to give the script root privileges through the setuid bit:

```bash
sudo chown root:root /usr/local/bin/sysinfo
sudo chmod 4755 /usr/local/bin/sysinfo
ls -l /usr/local/bin/sysinfo
/usr/local/bin/sysinfo
```

Expected:

```
-rwsr-xr-x 1 root root 312 Aug 26 10:19 /usr/local/bin/sysinfo
host      : workstation
kernel    : 6.8.0-40-generic
uptime    : up 3 hours, 12 minutes
real uid  : 1000 (student)
eff. uid  : 1000 (student)
```

The `s` bit is set on disk, and it did **nothing**.

7. Confirm the same file works as root through the supported mechanism:

```bash
sudo /usr/local/bin/sysinfo | grep uid
```

Expected:

```
real uid  : 0 (root)
eff. uid  : 0 (root)
```

8. Clean up the dangerous bit:

```bash
sudo chmod 0755 /usr/local/bin/sysinfo
ls -l /usr/local/bin/sysinfo
```

9. Find every setuid file already on the system — the audit you should know how to run:

```bash
sudo find /usr /bin /sbin -perm /4000 -type f -printf '%M %u %p\n' 2>/dev/null | head -20
```

10. Check whether a common temporary directory would even allow execution:

```bash
findmnt -no TARGET,OPTIONS /tmp
```

If the options contain `noexec`, a `chmod 755` script under `/tmp` still cannot be executed via `./script`.

**Questions**

- **Q2.1** — Step 1 gave exit status 126 and step 3 gave 127. Define both precisely.
- **Q2.2** — In step 2 you ran the script three ways. Which one can change the value of `PWD` or `PATH` in your *interactive* shell, and why?
- **Q2.3** — In step 2, if the file had `#!/bin/bash` but you ran `sh sysinfo.sh` on Debian, which interpreter runs the code?
- **Q2.4** — Why did the setuid bit have no effect in step 6? Cite the mechanism, not just the outcome.
- **Q2.5** — You must let a helpdesk group restart one service as root. Rank these three designs from worst to best and justify: (a) setuid shell script, (b) setuid C wrapper that calls the shell script, (c) a `sudoers` rule.
- **Q2.6** — What is the difference in intent between `/usr/local/bin` and `/usr/local/sbin`, and what permission mode would you choose for a root-only maintenance script?
- **Q2.7** — Why was `hash -r` necessary in step 4?

---

## Exercise 3 — Exit status: `$?`, `&&`, `||`, and pipelines

1. Observe the status of successful and failing commands:

```bash
true;  echo "true  -> $?"
false; echo "false -> $?"
ls /etc/hostname >/dev/null; echo "ls ok      -> $?"
ls /no/such/file 2>/dev/null; echo "ls missing -> $?"
grep -q root /etc/passwd; echo "grep found     -> $?"
grep -q zzzzz /etc/passwd; echo "grep not found -> $?"
grep -q root /no/such/file 2>/dev/null; echo "grep error     -> $?"
```

Expected:

```
true  -> 0
false -> 1
ls ok      -> 0
ls missing -> 2
grep found     -> 0
grep not found -> 1
grep error     -> 2
```

2. Observe a status produced by a signal:

```bash
sh -c 'kill -TERM $$'; echo "SIGTERM -> $?"
sh -c 'kill -KILL $$'; echo "SIGKILL -> $?"
kill -l 15
```

Expected:

```
SIGTERM -> 143
SIGKILL -> 137
TERM
```

3. Build conditional chains and note the trap:

```bash
test -f /etc/passwd && echo "passwd exists"
test -f /etc/nope   || echo "nope is missing"
test -d /etc && echo "A" || echo "B"
test -d /etc && false || echo "C RAN ANYWAY"
```

Expected:

```
passwd exists
nope is missing
A
C RAN ANYWAY
```

4. Capture and reuse a status *before* it is destroyed:

```bash
grep -q '^nosuchuser:' /etc/passwd
rc=$?
echo "still have it: $rc"
echo "but now \$? is: $?"
```

Expected:

```
still have it: 1
but now $? is: 0
```

5. Discover what a pipeline reports:

```bash
false | true; echo "pipeline status: $?"
echo "PIPESTATUS: ${PIPESTATUS[@]}"          # [bash-only]
set -o pipefail
false | true; echo "with pipefail : $?"
set +o pipefail
```

Expected:

```
pipeline status: 0
PIPESTATUS: 1 0
with pipefail : 1
```

6. Write a script that returns a meaningful status of its own:

```bash
cat > checkuser.sh <<'EOF'
#!/bin/sh
# Usage: checkuser.sh <username>
# Exit: 0 = user exists, 1 = user absent, 2 = usage error
if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") <username>" >&2
    exit 2
fi
if getent passwd "$1" >/dev/null 2>&1; then
    echo "$1: present"
    exit 0
else
    echo "$1: absent" >&2
    exit 1
fi
EOF
chmod 755 checkuser.sh
./checkuser.sh root;        echo "-> $?"
./checkuser.sh zzzz;        echo "-> $?"
./checkuser.sh;             echo "-> $?"
./checkuser.sh a b c;       echo "-> $?"
```

Expected:

```
root: present
-> 0
zzzz: absent
-> 1
usage: checkuser.sh <username>
-> 2
usage: checkuser.sh <username>
-> 2
```

7. Watch `set -e` do — and not do — what people expect:

```bash
cat > seteset.sh <<'EOF'
#!/bin/sh
set -e
echo "one"
if false; then echo "never"; fi     # set -e does NOT fire here
false || echo "two (guarded)"        # nor here
false                                # HERE it fires
echo "three: never printed"
EOF
chmod 755 seteset.sh
./seteset.sh; echo "-> $?"
```

Expected:

```
one
two (guarded)
-> 1
```

**Questions**

- **Q3.1** — `grep` returned 0, 1 and 2 in step 1. What does each mean, and why is `grep -q x f || echo missing` a latent bug?
- **Q3.2** — What is the valid numeric range of an exit status? What does `exit 256` actually set, and what does `exit -1` set?
- **Q3.3** — Explain the `C RAN ANYWAY` line in step 3. Rewrite that line so it behaves like a real `if/then/else`.
- **Q3.4** — Why must `rc=$?` in step 4 be the very next line? Name two commands that would silently destroy `$?` if inserted before it.
- **Q3.5** — By default, which command's status does a pipeline report? Which POSIX-portable technique gives you the failure of an earlier stage without `PIPESTATUS`?
- **Q3.6** — In step 7, list the three contexts in which `set -e` is suppressed.

---

## Exercise 4 — `test`, `[ ]`, and conditional structures

1. Prove that `[` is a command, not syntax:

```bash
type -a [
ls -l /usr/bin/[
/usr/bin/[ -d /etc ] ; echo "external [ -> $?"
```

Expected (size varies by distribution):

```
[ is a shell builtin
[ is /usr/bin/[
-rwxr-xr-x 1 root root 59768 Mar 20 08:41 /usr/bin/[
external [ -> 0
```

2. Exercise the file-test operators:

```bash
touch empty.txt
echo "data" > full.txt
for op in e f d r w x s; do
    for target in /etc /etc/passwd empty.txt full.txt /no/such; do
        if [ -"$op" "$target" ]; then r=TRUE; else r=false; fi
        printf '%-12s -%s  %s\n' "$target" "$op" "$r"
    done
done
```

3. Exercise string and integer comparison, and the classic quoting bug:

```bash
name="root"
[ "$name" = "root" ]  && echo "string equal"
[ "$name" != "daemon" ] && echo "string not equal"
[ -z "" ]      && echo "-z: empty string is true"
[ -n "$name" ] && echo "-n: non-empty string is true"

n=42
[ "$n" -gt 10 ] && echo "42 > 10"
[ "$n" -eq 42 ] && echo "42 == 42"
```

4. Now break it on purpose:

```bash
unset undefined_var
[ $undefined_var = "root" ]; echo "unquoted -> $?"
[ "$undefined_var" = "root" ]; echo "quoted   -> $?"

spaced="two words"
[ -n $spaced ]; echo "unquoted -n -> $?"
[ -n "$spaced" ]; echo "quoted -n   -> $?"
```

Expected:

```
bash: [: =: unary operator expected
unquoted -> 2
quoted   -> 1
bash: [: two: binary operator expected
unquoted -n -> 2
quoted -n   -> 0
```

5. Compare `=` against `-eq`:

```bash
a=07; b=7
[ "$a" = "$b" ]   && echo "= says equal"   || echo "= says different"
[ "$a" -eq "$b" ] && echo "-eq says equal" || echo "-eq says different"
```

Expected:

```
= says different
-eq says equal
```

6. Build a full `if / elif / else` with a `case`:

```bash
cat > diskcheck.sh <<'EOF'
#!/bin/sh
# Usage: diskcheck.sh <mountpoint>
mp=${1:-/}
if [ ! -d "$mp" ]; then
    echo "not a directory: $mp" >&2
    exit 2
fi

used=$(df -P "$mp" | awk 'NR==2 {sub(/%$/,"",$5); print $5}')

if   [ "$used" -ge 95 ]; then level=CRITICAL
elif [ "$used" -ge 85 ]; then level=WARNING
elif [ "$used" -ge 70 ]; then level=NOTICE
else                          level=OK
fi

printf '%-20s %3s%%  %s\n' "$mp" "$used" "$level"

case "$level" in
    CRITICAL|WARNING) exit 1 ;;
    *)                exit 0 ;;
esac
EOF
chmod 755 diskcheck.sh
./diskcheck.sh /
./diskcheck.sh /nonexistent; echo "-> $?"
```

Expected (values will differ):

```
/                     41%  OK
not a directory: /nonexistent
-> 2
```

7. Compare portable `test` with the Bash keyword:

```bash
f="my file.txt"; touch "$f"
[ -f $f ];   echo "POSIX unquoted   -> $?"    # breaks
[ -f "$f" ]; echo "POSIX quoted     -> $?"
[[ -f $f ]]; echo "bash [[ ]] unquoted -> $?" # works: no word splitting
[[ "$f" == my* ]] && echo "bash pattern match works"
```

**Questions**

- **Q4.1** — `[ "$a" = "$b" ]` said `07` and `7` differ, `[ "$a" -eq "$b" ]` said they are equal. Explain, and state which one you would use to compare a UID read from `/etc/passwd`.
- **Q4.2** — In step 4, why is the exit status of the unquoted test `2` and not `1`? Why does that distinction matter in a `while` loop?
- **Q4.3** — Name three things `[[ ]]` does that `[ ]` cannot, and state exactly why an LPIC-1 answer about "standard sh syntax" should still use `[ ]`.
- **Q4.4** — Rewrite `[ -f "$a" -a -r "$a" ]` in the form recommended by POSIX, and explain why `-a` / `-o` are deprecated.
- **Q4.5** — What is the difference between `[ -e f ]`, `[ -f f ]` and `[ -s f ]`? Which one is true for `/dev/null`, `/etc` and an empty regular file?
- **Q4.6** — In step 6, why is `used=$(... awk ... sub(/%$/,"",$5) ...)` necessary before an `-ge` comparison?

---

## Exercise 5 — Command substitution and quoting

1. Compare the two syntaxes:

```bash
today=$(date +%F)
today_old=`date +%F`
echo "$today / $today_old"
```

2. Demonstrate why `$( )` is preferred — nesting:

```bash
echo "kernel dir: $(dirname "$(readlink -f /boot/vmlinuz 2>/dev/null || echo /boot/none)")"
echo "backtick attempt: `echo \`echo nested\``"
```

3. Prove that command substitution strips **all** trailing newlines:

```bash
printf 'line\n\n\n\n' > trail.txt
x=$(cat trail.txt)
printf 'captured: [%s]\n' "$x"
wc -c < trail.txt
printf '%s' "$x" | wc -c
```

Expected:

```
captured: [line]
11
4
```

4. Show why unquoted substitution is dangerous:

```bash
mkdir -p subdir && touch "subdir/a b.txt" "subdir/c.txt"
echo "--- unquoted (word splitting) ---"
for f in $(ls subdir); do echo "  [$f]"; done
echo "--- glob (correct) ---"
for f in subdir/*;   do echo "  [$f]"; done
```

Expected:

```
--- unquoted (word splitting) ---
  [a]
  [b.txt]
  [c.txt]
--- glob (correct) ---
  [subdir/a b.txt]
  [subdir/c.txt]
```

5. Substitution inside strings, and arithmetic expansion:

```bash
users=$(getent passwd | wc -l)
shells=$(getent passwd | cut -d: -f7 | sort -u | wc -l)
echo "There are $users accounts using $shells distinct shells."
echo "Average accounts per shell: $(( users / shells ))"
echo "Same with expr: $(expr "$users" / "$shells")"
```

6. Compare the three ways to read a whole file into a variable:

```bash
a=$(cat /etc/hostname)          # portable, forks
b=$(< /etc/hostname)            # [bash-only], no fork
read -r c < /etc/hostname       # portable, first line only
echo "$a | $b | $c"
```

7. Measure the fork cost:

```bash
time ( i=0; while [ "$i" -lt 500 ]; do x=$(echo hi); i=$((i+1)); done )
time ( i=0; while [ "$i" -lt 500 ]; do x="hi";       i=$((i+1)); done )
```

**Questions**

- **Q5.1** — Give two concrete reasons `$(cmd)` is preferred over `` `cmd` ``.
- **Q5.2** — A script does `count=$(wc -l < /var/log/syslog)` and then `[ "$count" -gt 1000 ]`. It fails with `integer expression expected` on one system but works on another. What is different, and how do you make it robust?
- **Q5.3** — Why is `for f in $(ls)` considered a bug even when filenames have no spaces? Name two failure modes besides spaces.
- **Q5.4** — `x=$(printf 'a\nb\n')`. What is `echo "$x"` versus `echo $x`?
- **Q5.5** — What is the difference between `$(( ))`, `$( )` and `${ }`?
- **Q5.6** — You need the *stderr* of a command in a variable. Write the redirection.

---

## Exercise 6 — Loops: `for`, `while`, `until`, and `read`

1. `for` over a literal word list, a glob, and a generated sequence:

```bash
for svc in sshd cron rsyslog; do
    printf '%-10s ' "$svc"
    systemctl is-active "$svc" 2>/dev/null || echo "unknown"
done

for f in /etc/*.conf; do
    printf '%8d  %s\n' "$(wc -l < "$f")" "$f"
done | sort -rn | head -5

for i in 1 2 3 4 5;      do printf '%s ' "$i"; done; echo
for i in $(seq 1 5);     do printf '%s ' "$i"; done; echo
i=1; while [ "$i" -le 5 ]; do printf '%s ' "$i"; i=$((i+1)); done; echo   # portable
for ((i=1; i<=5; i++));  do printf '%s ' "$i"; done; echo                 # [bash-only]
```

2. `for` with no list — the implicit `"$@"`:

```bash
cat > eachargs.sh <<'EOF'
#!/bin/sh
echo "argument count: $#"
for a; do              # identical to: for a in "$@"; do
    echo "  [$a]"
done
EOF
chmod 755 eachargs.sh
./eachargs.sh one "two words" three
```

Expected:

```
argument count: 3
  [one]
  [two words]
  [three]
```

3. `while read` — the correct file-line idiom:

```bash
while IFS=: read -r user pw uid gid gecos home shell; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; then
        printf '%-16s uid=%-6s shell=%s\n' "$user" "$uid" "$shell"
    fi
done < /etc/passwd
```

4. **The subshell trap.** Run both versions and compare:

```bash
count=0
cat /etc/passwd | while read -r line; do count=$((count+1)); done
echo "piped   : count=$count"

count=0
while read -r line; do count=$((count+1)); done < /etc/passwd
echo "redirect: count=$count"

wc -l < /etc/passwd
```

Expected:

```
piped   : count=0
redirect: count=45
45
```

5. Prove why `-r` and `IFS=` matter:

```bash
printf 'C:\\Users\\admin\n   leading and trailing   \n' > raw.txt

while read line;        do printf 'no -r     : [%s]\n' "$line"; done < raw.txt
while read -r line;     do printf 'with -r   : [%s]\n' "$line"; done < raw.txt
while IFS= read -r line; do printf 'IFS= -r   : [%s]\n' "$line"; done < raw.txt
```

Expected:

```
no -r     : [C:Usersadmin]
no -r     : [leading and trailing]
with -r   : [C:\Users\admin]
with -r   : [leading and trailing]
IFS= -r   : [C:\Users\admin]
IFS= -r   : [   leading and trailing   ]
```

6. `until`, `break`, `continue`, and an infinite loop with a guard:

```bash
cat > waitport.sh <<'EOF'
#!/bin/sh
# Usage: waitport.sh <host> <port> [timeout_seconds]
host=${1:?host required}; port=${2:?port required}; timeout=${3:-10}
elapsed=0
until nc -z -w1 "$host" "$port" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout" ]; then
        echo "timeout after ${timeout}s waiting for $host:$port" >&2
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed+1))
done
echo "$host:$port is open after ${elapsed}s"
EOF
chmod 755 waitport.sh
./waitport.sh 127.0.0.1 22 3; echo "-> $?"
./waitport.sh 127.0.0.1 9999 3; echo "-> $?"
```

7. `break` / `continue` with a level argument:

```bash
for i in 1 2 3; do
    for j in a b c; do
        [ "$j" = b ] && continue
        [ "$i" = 3 ] && break 2
        echo "$i$j"
    done
done
```

Expected:

```
1a
1c
2a
2c
```

8. Loop over a `find` result safely — the NUL-delimited idiom:

```bash
find /etc -maxdepth 1 -name '*.conf' -print0 |
while IFS= read -r -d '' f; do            # [bash-only: read -d]
    printf 'found: %s\n' "$f"
done | head -5

# POSIX alternative, no subshell issue, handles any filename:
find /etc -maxdepth 1 -name '*.conf' -exec sh -c '
    for f do printf "found: %s\n" "$f"; done
' sh {} + | head -5
```

**Questions**

- **Q6.1** — In step 4, why was `count` still 0 after the pipeline? Name two ways to fix it while keeping a pipeline.
- **Q6.2** — What exactly does `IFS=` before `read` do, and why does it apply only to that one command?
- **Q6.3** — Without `-r`, `read` mangled the backslashes. Give a real-world example where losing `-r` corrupts data silently.
- **Q6.4** — `for f in *.log` when no `.log` file exists: what is `$f` on the first iteration in POSIX sh, and how do you prevent the bug? What Bash option changes this behavior?
- **Q6.5** — Why is `for i in $(seq 1 100000)` a worse choice than a `while` counter in a memory-constrained environment?
- **Q6.6** — In step 6, what does `${1:?host required}` do, and how does it differ from `${1:-default}` and `${1:=default}`?

---

## Exercise 7 — Positional parameters and script arguments

1. Build a script that reports everything about its invocation:

```bash
cat > params.sh <<'EOF'
#!/bin/sh
echo "\$0    = $0"
echo "basename = $(basename "$0")"
echo "\$#    = $#"
echo "\$1    = $1"
echo "\$2    = $2"
echo "\$\$    = $$"
echo '--- "$@" (each arg separate) ---'
for a in "$@"; do echo "  [$a]"; done
echo '--- "$*" (all joined by IFS) ---'
for a in "$*"; do echo "  [$a]"; done
echo '--- $@ unquoted (split again) ---'
for a in $@; do echo "  [$a]"; done
EOF
chmod 755 params.sh
./params.sh alpha "beta gamma" delta
```

Expected:

```
$0    = ./params.sh
basename = params.sh
$#    = 3
$1    = alpha
$2    = beta gamma
$$    = 28417
--- "$@" (each arg separate) ---
  [alpha]
  [beta gamma]
  [delta]
--- "$*" (all joined by IFS) ---
  [alpha beta gamma delta]
--- $@ unquoted (split again) ---
  [alpha]
  [beta]
  [gamma]
  [delta]
```

2. Consume arguments with `shift`:

```bash
cat > shiftdemo.sh <<'EOF'
#!/bin/sh
action=$1
[ "$#" -ge 1 ] || { echo "usage: $(basename "$0") ACTION [FILE...]" >&2; exit 2; }
shift
echo "action  = $action"
echo "remaining ($#): $*"
while [ "$#" -gt 0 ]; do
    echo "  processing: $1"
    shift
done
EOF
chmod 755 shiftdemo.sh
./shiftdemo.sh backup /etc/passwd /etc/group
```

3. Parse real options with `getopts`:

```bash
cat > optdemo.sh <<'EOF'
#!/bin/sh
verbose=0
outfile=""
usage() { echo "usage: $(basename "$0") [-v] [-o FILE] target..." >&2; exit 2; }

while getopts ':vo:h' opt; do
    case "$opt" in
        v) verbose=1 ;;
        o) outfile=$OPTARG ;;
        h) usage ;;
        :) echo "option -$OPTARG requires an argument" >&2; usage ;;
        \?) echo "unknown option: -$OPTARG" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

[ "$#" -ge 1 ] || usage
echo "verbose=$verbose outfile='${outfile:-<stdout>}' targets=$*"
EOF
chmod 755 optdemo.sh
./optdemo.sh -v -o /tmp/out.txt hostA hostB
./optdemo.sh -o
./optdemo.sh -z host; echo "-> $?"
```

Expected:

```
verbose=1 outfile='/tmp/out.txt' targets=hostA hostB
option -o requires an argument
usage: optdemo.sh [-v] [-o FILE] target...
unknown option: -z
usage: optdemo.sh [-v] [-o FILE] target...
-> 2
```

**Questions**

- **Q7.1** — State the difference between `"$@"` and `"$*"` in one sentence, and say which one you pass to an inner command.
- **Q7.2** — Why is `shift $((OPTIND - 1))` required after a `getopts` loop?
- **Q7.3** — What does the leading `:` in `getopts ':vo:h'` change?
- **Q7.4** — `$0` was `./params.sh`. What is `$0` when the same file is sourced with `. ./params.sh`? What is it when run as `sh params.sh`?
- **Q7.5** — In POSIX sh, how do you access the tenth positional parameter, and why does `$10` not work?

---

## Exercise 8 — Conditional mailing to the superuser

The exam objective is explicit: *perform conditional mailing to the superuser*. That means the script decides — based on a test — whether to send mail at all.

1. Check what mail delivery you actually have:

```bash
command -v mail mailx sendmail /usr/sbin/sendmail 2>/dev/null
ls -l /var/mail/ 2>/dev/null
```

2. If no MTA is installed, build a **fake** `mail` so the lab is still runnable:

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/mail <<'EOF'
#!/bin/sh
echo "===== FAKE MTA ====="
echo "argv : $*"
echo "----- body -----"
cat
echo "===== END ====="
EOF
chmod 755 ~/.local/bin/mail
PATH="$HOME/.local/bin:$PATH"; hash -r
command -v mail
```

3. Send a trivial conditional mail from the command line:

```bash
if [ "$(id -u)" -ne 0 ]; then
    echo "Script was run by $(id -un) at $(date -Is), not root." \
        | mail -s "privilege notice from $(uname -n)" root
fi
```

Expected (with the fake MTA):

```
===== FAKE MTA =====
argv : -s privilege notice from workstation root
----- body -----
Script was run by student at 2026-08-26T10:41:07+02:00, not root.
===== END =====
```

4. Build the production pattern — collect a report, mail it **only if non-empty**:

```bash
cat > diskwatch.sh <<'EOF'
#!/bin/sh
#
# diskwatch.sh - mail root when any local filesystem exceeds a threshold.
# Usage: diskwatch.sh [threshold_percent]   (default 85)
# Exit:  0 = nothing to report, 1 = alert sent, 2 = usage/internal error
#
set -u

THRESHOLD=${1:-85}
RECIPIENT=${DISKWATCH_TO:-root}
HOSTNAME=$(uname -n)

case "$THRESHOLD" in
    ''|*[!0-9]*) echo "threshold must be an integer: $THRESHOLD" >&2; exit 2 ;;
esac

report=$(mktemp "${TMPDIR:-/tmp}/diskwatch.XXXXXX") || exit 2
trap 'rm -f "$report"' EXIT HUP INT TERM

# -P forces POSIX single-line output; -l skips network filesystems.
df -P -l 2>/dev/null | awk -v t="$THRESHOLD" '
    NR > 1 && $5 + 0 >= t {
        printf "%-28s %6s used of %-10s mounted on %s\n", $1, $5, $2 "k", $6
    }
' > "$report"

if [ -s "$report" ]; then
    {
        echo "Filesystems at or above ${THRESHOLD}% on ${HOSTNAME}:"
        echo
        cat "$report"
        echo
        echo "Generated by $0 (pid $$) at $(date -Is)"
    } | mail -s "[DISK] ${HOSTNAME}: filesystem threshold ${THRESHOLD}% exceeded" "$RECIPIENT"
    logger -t diskwatch -p user.warning "threshold ${THRESHOLD}% exceeded; mailed ${RECIPIENT}"
    exit 1
fi

logger -t diskwatch -p user.info "all filesystems below ${THRESHOLD}%"
exit 0
EOF
chmod 755 diskwatch.sh
```

5. Exercise all three branches:

```bash
./diskwatch.sh 99;   echo "-> $?"     # almost certainly quiet
./diskwatch.sh 1;    echo "-> $?"     # forces the alert
./diskwatch.sh abc;  echo "-> $?"     # usage error
```

Expected:

```
-> 0
===== FAKE MTA =====
argv : -s [DISK] workstation: filesystem threshold 1% exceeded root
----- body -----
Filesystems at or above 1% on workstation:

/dev/nvme0n1p2                  41% used of 494006272k mounted on /
/dev/nvme0n1p1                   2% used of 523248k    mounted on /boot/efi

Generated by ./diskwatch.sh (pid 28603) at 2026-08-26T10:44:19+02:00
===== END =====
-> 1
threshold must be an integer: abc
-> 2
```

6. Confirm the temporary file was removed by the `trap`:

```bash
ls /tmp/diskwatch.* 2>&1
```

Expected:

```
ls: cannot access '/tmp/diskwatch.*': No such file or directory
```

7. Verify the syslog entries:

```bash
journalctl -t diskwatch -n 5 --no-pager 2>/dev/null || tail -5 /var/log/messages
```

8. Install it as a root-only job and schedule it:

```bash
sudo install -o root -g root -m 0750 diskwatch.sh /usr/local/sbin/diskwatch
ls -l /usr/local/sbin/diskwatch
printf '%s\n' '17 * * * * /usr/local/sbin/diskwatch 85' | sudo tee /etc/cron.d/diskwatch-tmp >/dev/null
```

> A `/etc/cron.d/` file needs a user field. The correct line is:
> `17 * * * * root /usr/local/sbin/diskwatch 85`
> Fix it before relying on it, then remove the lab file: `sudo rm -f /etc/cron.d/diskwatch-tmp`

**Questions**

- **Q8.1** — Why is the report written to a temp file and tested with `[ -s ]` instead of piping `awk` straight into `mail`?
- **Q8.2** — The `trap` lists `EXIT HUP INT TERM`. Why is `EXIT` alone insufficient in older shells, and why is `KILL` absent from the list?
- **Q8.3** — `df -P` is used instead of plain `df`. What specific parsing bug does `-P` prevent?
- **Q8.4** — In the `awk` expression, why `$5 + 0 >= t` rather than `$5 >= t`?
- **Q8.5** — A cron job that mails root is redundant if the script also writes to stdout. Explain the interaction between cron's `MAILTO` and a script's own `mail` call, and how to avoid two messages per run.
- **Q8.6** — The script was installed `0750 root:root` in `/usr/local/sbin`. Justify each of those four decisions.
- **Q8.7** — Rewrite the mail invocation so it still works if `mail` is absent but `/usr/sbin/sendmail` is present.

---

## Exercise 9 — Debugging and validating a script

1. Syntax-check without executing:

```bash
printf '#!/bin/sh\nif [ 1 -eq 1 ]\necho broken\nfi\n' > broken.sh
sh -n broken.sh; echo "-> $?"
```

Expected:

```
broken.sh: 4: Syntax error: "fi" unexpected (expecting "then")
-> 2
```

2. Trace execution three ways:

```bash
sh -x ./diskcheck.sh /
```

```bash
# Inline, scoped to a region:
cat > traced.sh <<'EOF'
#!/bin/sh
echo "quiet part"
set -x
n=$(( 2 + 3 ))
[ "$n" -gt 4 ] && result=big || result=small
set +x
echo "result=$result"
EOF
chmod 755 traced.sh
./traced.sh
```

Expected:

```
quiet part
+ n=5
+ [ 5 -gt 4 ]
+ result=big
+ set +x
result=big
```

3. Make the trace identify itself (Bash's `PS4`):

```bash
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: ' bash -x ./diskcheck.sh / 2>&1 | head
```

4. Turn on the recommended safety options and see each one fire:

```bash
cat > strict.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo "unset variable next:"
echo "${NOT_SET}"
echo "never reached"
EOF
chmod 755 strict.sh
./strict.sh; echo "-> $?"
```

Expected:

```
unset variable next:
./strict.sh: line 4: NOT_SET: unbound variable
-> 1
```

5. Static analysis, if available:

```bash
command -v shellcheck >/dev/null && shellcheck diskwatch.sh || echo "shellcheck not installed"
```

**Questions**

- **Q9.1** — What is the difference between `sh -n`, `sh -v` and `sh -x`?
- **Q9.2** — Where does `set -x` output go, and why does `./script.sh -x > log 2>&1` behave differently from `./script.sh -x > log`?
- **Q9.3** — `set -u` is Bash-friendly but hostile to `"$@"` handling in old Bash. What does `${1:-}` accomplish under `set -u`?
- **Q9.4** — Why is `set -euo pipefail` inappropriate in a script whose shebang is `#!/bin/sh` on Debian?

---

## Exercise 10 — Capstone

Write and install a single script, `svcaudit`, satisfying **all** of the following. Then check yourself against the reference implementation in the answers.

1. Shebang `#!/bin/sh`; no Bash-only construct anywhere (verify with `dash -n svcaudit`).
2. Usage: `svcaudit [-m] [-q] SERVICE...` — `-m` mails root on failure, `-q` suppresses stdout.
3. Uses `getopts`, then `shift $((OPTIND-1))`; exits 2 on usage error.
4. For each service, uses command substitution to capture `systemctl is-active`, and a `case` to classify.
5. Uses a `while` loop over the remaining positional parameters with `shift`.
6. Exits 0 if all services are active, 1 if any is not.
7. Mails root **only if** `-m` was given **and** at least one service is down.
8. Cleans up any temp file with a `trap`.
9. Installed as `/usr/local/sbin/svcaudit`, owner `root:root`, mode `0750`.

```bash
./svcaudit -m sshd cron nosuchservice; echo "-> $?"
```

---

## Cleanup

```bash
cd ~
sudo rm -f /usr/local/bin/sysinfo /usr/local/sbin/diskwatch /usr/local/sbin/svcaudit
sudo rm -f /etc/cron.d/diskwatch-tmp
rm -f ~/.local/bin/mail ~/.local/bin/sysinfo
rm -rf ~/lab-105.2
hash -r
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1 — No.** When `bash` is invoked as `sh` (via `argv[0]`), it enters POSIX-ish compatibility mode: it does not read `~/.bashrc`, disables `bash`-specific startup behavior, and turns off some extensions. More importantly, the *portability contract* differs: a `#!/bin/sh` script is a promise that it needs nothing beyond POSIX, and it must survive being run on a system where `/bin/sh` is `dash`. Testing only on a `bash`-as-`sh` system hides `[[ ]]`, `local`, `+=`, arrays, `$'...'`, `source` and `echo -e` as latent bugs.

**A0.2 —** In an interactive shell `$0` is the shell name (`bash`, `-bash`). Inside a script `$0` is the *script path*, not the interpreter. To find the interpreter of a running script, use `readlink /proc/$$/exe` on Linux, or check `$BASH_VERSION` (set only under bash).

---

### Exercise 1

**A1.1 —** Linux's `binfmt_script` handler splits the shebang line into at most **two** tokens: the interpreter path, and everything after the first whitespace run as a **single** argument, verbatim. It does no word splitting. So `-a -b -c` arrives as one `argv` element. FreeBSD's `execve` *does* split into multiple arguments (up to a limit), so the same file behaves differently — which is exactly why the portable rule is **at most one option on the shebang line** (e.g. `#!/bin/sh -e` is fine; `#!/bin/sh -e -u` is not). GNU coreutils offers `#!/usr/bin/env -S bash -eu` (env ≥ 8.30) as a portable escape hatch.

**A1.2 —** The kernel passes the path **exactly as it was resolved for the `exec` call** — here `./demo.sh`. It is not canonicalized. Consequence: `$0` inside a script is whatever the caller typed, so `$0` is not a reliable way to locate the script's own directory, and `basename "$0"` is the correct way to get a display name.

**A1.3 —** The **shell** printed it, not the kernel. `execve("./typo.sh", …)` returned `ENOENT` (the *interpreter* `/bin/bahs` does not exist). Bash, seeing `ENOENT` after a successful stat of the script itself, reads the first line and reports the interpreter as the missing item. Status **127** is the POSIX convention for "command not found". This is why 127 with a puzzling path almost always means "bad shebang", and CRLF is the usual cause.

**A1.4 —** *Advantage:* `env` searches `PATH`, so the script finds `bash` at `/bin/bash`, `/usr/local/bin/bash` (BSD), or a `pyenv`/`nix`/Homebrew build — essential for `python3`, `perl`, `node`. *Disadvantage:* it makes the interpreter **caller-controlled**. Anyone who can influence `PATH` chooses the interpreter, which is unacceptable for anything privileged or invoked by `sudo`/`cron`, and it defeats reproducibility. Rule of thumb: `#!/bin/sh` and `#!/bin/bash` absolute for system scripts; `#!/usr/bin/env python3` for portable tooling.

**A1.5 —** `execve` fails with `ENOEXEC` (no recognized magic). POSIX requires an interactive shell to then **re-execute the file with itself**, so bash runs it as a bash script. A C program calling `execve()` directly just gets `ENOEXEC` and fails; `execvp()` from glibc reproduces the shell fallback by running `/bin/sh`. Never rely on this — always write a shebang.

---

### Exercise 2

**A2.1 —** **126** = the command was *found* but could not be executed: no execute permission, it is a directory, or the filesystem is mounted `noexec`. **127** = the command name was not found at all in `PATH`, **or** the shebang interpreter does not exist. Together with `128+N` (killed by signal N) these are the three statuses a script must never return by accident.

**A2.2 —** Only `. ./sysinfo.sh` (`source`). Sourcing runs the commands in the **current** shell process, so `cd`, `export`, `set`, variable assignments and function definitions persist. `./sysinfo.sh` and `sh sysinfo.sh` both `fork()` a child; nothing the child changes can propagate back. This is why `/etc/profile.d/*.sh` files are sourced, not executed.

**A2.3 —** `dash`. Running `sh file` makes the shebang line an ordinary comment — the interpreter is the one you named on the command line. A `#!/bin/bash` script invoked as `sh script` will hit syntax errors on the first Bash-only construct. Always launch via `./script` or the correct interpreter.

**A2.4 —** The Linux kernel **deliberately ignores the set-user-ID and set-group-ID bits on interpreter (`#!`) scripts** — `execve(2)`, "Interpreter scripts". The bit remains in the inode (so `ls` shows `s` and audit tools flag it), but the credentials are never changed. The reason is a class of unfixable races: between `execve` opening the script and the interpreter re-opening it by path, the file can be swapped (a symlink attack), and the interpreter can be steered by `PATH`, `IFS`, `ENV`, `BASH_ENV`, or an injected shebang option. Correct mechanisms: `sudo`, a `setcap`'d/setuid **compiled** binary that sanitizes the environment, or a privileged daemon/systemd unit.

**A2.5 —** Worst → best:
(a) **Setuid shell script** — does not even work on Linux, and on systems where it does, it is a trivially exploitable root hole.
(b) **Setuid C wrapper calling a shell script** — works, but you have merely moved the problem: the wrapper must clear the entire environment (`PATH`, `IFS`, `ENV`, `BASH_ENV`, `LD_*`), use an absolute path, and the script must remain root-owned and non-writable at every path component. One mistake is root.
(c) **`sudoers` rule** — the right answer. `%helpdesk ALL=(root) NOPASSWD: /bin/systemctl restart nginx.service` gives one command, logs every invocation, sanitizes the environment by default (`env_reset`, `secure_path`), and is centrally auditable.

**A2.6 —** `/usr/local/bin` is for commands intended for **all users**; `/usr/local/sbin` for commands intended for **system administration** (FHS §4.9). `/usr/local/*` specifically is the location reserved for locally installed software, which is exactly where hand-written admin scripts belong — never `/usr/bin` or `/usr/sbin`, which belong to the package manager. A root-only maintenance script should be `root:root` mode **`0750`** (or `0700`); `0755` would let any user *read* logic and paths that may reveal internal structure, and `0775`/group-writable would let a non-root user *modify* a script root runs — a privilege escalation.

**A2.7 —** Bash caches full paths of previously executed commands in a hash table. Prepending a directory to `PATH` does not invalidate that cache, and a "not found" result can also be remembered. `hash -r` clears it. Equivalent: `hash -d name` for one entry, or start a new shell.

---

### Exercise 3

**A3.1 —** `grep`: **0** = at least one line matched, **1** = no line matched (not an error), **2** = an actual error (file unreadable, invalid regex, missing file). The bug: `grep -q x f || echo missing` prints "missing" both when the pattern is genuinely absent (1) and when the file could not be read at all (2) — a permissions failure or typo'd path is silently reported as "the string isn't there". Robust form:

```sh
grep -q x f
case $? in
  0) echo present ;;
  1) echo absent ;;
  *) echo "error reading f" >&2; exit 2 ;;
esac
```

**A3.2 —** 0–255 (8 bits, as delivered through `wait(2)`). `exit 256` sets **0** (256 mod 256) — a spectacular way to report success while failing. `exit -1` sets **255**. Never compute an exit status from a count without clamping: `[ "$errors" -gt 255 ] && errors=255`.

**A3.3 —** `cmd && A || B` is **not** if/then/else. If `A` runs but *fails*, `||` still fires and `B` runs too. In the example `test -d /etc` succeeded, then `false` failed, so `echo "C RAN ANYWAY"` executed. Correct:

```sh
if test -d /etc; then false; else echo C; fi
```
The `&&`/`||` idiom is only safe when the left branch cannot fail (e.g. a plain `echo`).

**A3.4 —** `$?` is overwritten by **every** command, including successful ones. Two silent destroyers: `echo "checking..."` (sets `$?` to 0) and `[ "$x" = "y" ]` — and, less obviously, `local rc=$?` in bash (the `local` builtin's own status wins; write `local rc; rc=$?`). Capture first, print second.

**A3.5 —** By default a pipeline reports the status of the **last** command. Portable technique without `PIPESTATUS`: avoid the pipeline by using a temp file or process substitution, or restructure so the fallible command is last — e.g. `if ! out=$(cmd1); then …; fi; printf '%s\n' "$out" | cmd2`. In bash, `set -o pipefail` makes the pipeline return the rightmost non-zero status.

**A3.6 —** `set -e` (`errexit`) does **not** trigger when the failing command is:
1. the condition of `if`, `while`, or `until`;
2. any part of an `&&` / `||` list except the final command;
3. negated with `!`.
Additionally it does not fire for a command inside a subshell whose status is then tested, and its behavior on functions and command substitution is famously inconsistent between shells. `set -e` is a helpful backstop, never a substitute for explicit status checks.

---

### Exercise 4

**A4.1 —** `=` is **string** comparison: the strings `07` and `7` are different. `-eq` is **integer** comparison: both parse to 42… to 7, so they are equal. For a UID read from `/etc/passwd` use **`-eq` / `-ge` / `-lt`**, because you are comparing numbers and you want `007` and `7` to match; but you must first guarantee the value is numeric, or `test` aborts with status 2.

**A4.2 —** `test` uses **0 = true, 1 = false, >1 = error**. The unquoted `[ $undefined_var = "root" ]` expanded to `[ = "root" ]`, which is a malformed expression — a *syntax* error, not a false result, so status **2**. This matters in `while [ … ]; do` because the shell only distinguishes zero from non-zero: an error looks identical to "false", so the loop silently never runs and you conclude the data was empty rather than that your test was broken.

**A4.3 —** `[[ ]]` adds: (1) no word splitting or globbing on unquoted variable expansions, so `[[ -f $f ]]` is safe; (2) pattern matching with `==`/`!=` and regex with `=~`; (3) `&&`, `||`, and parentheses as real operators with proper precedence; (4) numeric comparison with `<`/`>` without escaping. **But** it is a *reserved word*, not a command, and exists only in bash/ksh/zsh — not in `dash`, `busybox sh`, or POSIX. LPIC-1 105.2 says "standard sh syntax," and any script whose shebang is `#!/bin/sh` will break on Debian. Use `[ ]` with disciplined quoting.

**A4.4 —** `[ -f "$a" ] && [ -r "$a" ]`. POSIX marks `-a` and `-o` obsolescent because `test` cannot reliably parse expressions of more than four arguments: the operands are indistinguishable from operators, so a filename literally called `-a` or `!` or `(` changes how the whole expression is parsed. Chaining separate `[ ]` invocations with shell `&&`/`||` is unambiguous and shortcuts correctly.

**A4.5 —**
- `-e f` → the path **exists** (any type: file, dir, symlink target, device, socket).
- `-f f` → exists **and is a regular file**.
- `-s f` → exists **and has size > 0**.

| path | `-e` | `-f` | `-s` |
|---|---|---|---|
| `/dev/null` | true | **false** (character device) | **false** (size 0) |
| `/etc` | true | **false** (directory) | true (directories have non-zero size) |
| empty regular file | true | true | **false** |

Note `-e`/`-f` follow symlinks; use `-L` (or `-h`) to test the link itself.

**A4.6 —** `df` prints capacity as `41%`. `test` with `-ge` requires a pure integer and would abort with `integer expression expected` (status 2) on the `%`. `sub(/%$/,"",$5)` strips the trailing percent sign inside `awk` so the shell receives `41`. The alternative is `${used%\%}` (parameter expansion, removes the suffix) — also portable.

---

### Exercise 5

**A5.1 —** (1) `$( )` **nests** without escaping; backticks require `\`` escaping at each level and become unreadable after two. (2) Backticks apply an extra layer of backslash processing, so `\$`, `\\` and `` \` `` behave differently inside them than in `$( )` — a source of subtle, silent bugs. (Bonus: `$( )` is visually unambiguous next to `'` in most fonts.)

**A5.2 —** The difference is `wc -l < file` (which prints a bare number) versus `wc -l file` (which prints `1234 file`). The failing system's script most likely used `$(wc -l file)`, or the file is missing so `count` is empty, or the locale inserted a thousands separator. Robust:

```sh
count=$(wc -l < /var/log/syslog 2>/dev/null) || count=0
count=${count##*[! 0-9]}     # or: count=$(printf '%s' "$count" | tr -cd '0-9')
[ -n "$count" ] || count=0
[ "$count" -gt 1000 ] && …
```
Always redirect *into* `wc` when you want just the number.

**A5.3 —** `$(ls)` produces one newline-separated blob that the shell then subjects to **word splitting on `$IFS`** and **globbing**. Beyond spaces: (1) a filename containing `*` or `?` is expanded again against the directory — a file named `*` matches everything; (2) a filename containing a newline is split into two "files"; (3) `ls` mangles non-printing characters when its output is not a terminal (it substitutes `?` or quotes), so the name you get back may not be the name on disk. The glob `for f in ./*` never passes through word splitting at all.

**A5.4 —** `echo "$x"` prints two lines, `a` then `b`, because quoting preserves the embedded newline. `echo $x` prints `a b` on one line: unquoted, the value is word-split on `$IFS` (which contains newline) into two words, and `echo` joins its arguments with a single space. The trailing newline was stripped by the substitution in both cases.

**A5.5 —**
- `$(( expr ))` — **arithmetic expansion**: evaluates integer arithmetic, returns the number. `$(( 2 + 3 ))` → `5`.
- `$( cmd )` — **command substitution**: forks, runs `cmd`, returns its stdout with trailing newlines stripped.
- `${ var }` — **parameter expansion**: the value of a variable, plus modifiers (`${v:-d}`, `${v#pat}`, `${v%pat}`, `${#v}`). No subprocess.

**A5.6 —** `err=$(cmd 2>&1 >/dev/null)`. Order matters: `2>&1` first points stderr at the current stdout (the substitution pipe), then `>/dev/null` redirects stdout away. Writing `>/dev/null 2>&1` would send both to `/dev/null` and capture nothing.

---

### Exercise 6

**A6.1 —** Each stage of a pipeline runs in its own **subshell** (a forked process). The `while` loop incremented `count` in the child; when the child exited, its memory — including the variable — was discarded. The parent's `count` was never touched. Fixes that keep a pipeline:
1. Put the consumer last and capture its output: `count=$(cat /etc/passwd | wc -l)`, or more generally `count=$(cmd | while read …; do …; done; echo "$count")`.
2. **[bash-only]** `shopt -s lastpipe` (requires job control off, i.e. non-interactive) runs the last pipeline stage in the current shell.
3. Use a here-string or process substitution: `while read …; do …; done < <(cmd)` **[bash-only]**.
The portable answer is simply to redirect from a file or use option 1.

**A6.2 —** `IFS= read -r line` is a **temporary environment assignment** that applies only to the `read` command's execution and is restored afterwards — this is POSIX behavior for a variable assignment preceding a *simple command*. Setting `IFS` to empty disables field splitting inside `read`, so leading and trailing whitespace is preserved verbatim in `line`. Without it, `read` strips leading/trailing `IFS` characters (space, tab, newline). Note the exception: because `read` is a *builtin*, some shells historically made this assignment persist; POSIX requires the temporary behavior for special builtins only — `read` is a regular builtin, so the temporary behavior is guaranteed.

**A6.3 —** Without `-r`, `read` treats backslash as an escape: it removes it, and a trailing backslash silently joins the line with the next one. Real cases: reading Windows paths from a CSV (`C:\Users\admin` → `C:Usersadmin`), reading `/etc/fstab` where mount points with spaces are encoded as `\040` (`/mnt/my\040disk` → `/mnt/my040disk`, and the mount fails), and reading LDAP DNs where commas are escaped. **Always use `-r`** unless you specifically want escape processing.

**A6.4 —** In POSIX sh, an unmatched glob is left **literally**: `$f` is the four-character string `*.log`, and the loop body runs once on a file that does not exist. Prevention:

```sh
for f in *.log; do
    [ -e "$f" ] || continue
    …
done
```
In Bash, `shopt -s nullglob` makes an unmatched pattern expand to *nothing* (loop runs zero times), and `shopt -s failglob` makes it an error.

**A6.5 —** `$(seq 1 100000)` materializes the entire sequence as a single ~589 KB string in the shell's memory, forks a process to produce it, and then word-splits it into 100 000 fields — all before the first iteration begins. A `while` counter uses O(1) memory and no fork. On busybox/embedded systems `seq` may not exist at all. The bash-only `for ((i=1;i<=100000;i++))` is also O(1) but not portable.

**A6.6 —**
- `${1:?host required}` — if `$1` is unset **or empty**, print `sh: 1: host required` to stderr and **exit the script** (non-interactive) with a non-zero status. Use for mandatory arguments.
- `${1:-default}` — substitute `default` **for this expansion only**; `$1` itself is unchanged.
- `${1:=default}` — substitute *and* **assign**. It fails on positional parameters (`$1`, `$2`, …) — POSIX forbids assigning to them this way — so it is only usable with named variables.
Dropping the colon (`${1?…}`, `${1-…}`) changes the trigger from "unset or empty" to "unset only".

---

### Exercise 7

**A7.1 —** `"$@"` expands to **N separate quoted words**, one per positional parameter, preserving embedded spaces; `"$*"` expands to **one word** with the parameters joined by the first character of `$IFS` (a space by default). Pass **`"$@"`** to an inner command — always, with the quotes. `"$*"` is only for building a display string.

**A7.2 —** `getopts` leaves `OPTIND` pointing at the index of the **first non-option argument**. `shift $((OPTIND - 1))` discards the consumed options and their arguments so that `$1`, `$@` and `$#` then refer only to the operands. Without it, `$1` is still `-v` and every subsequent loop over `"$@"` re-processes the flags. (In a script, `OPTIND` is reset to 1 automatically at startup; if you call `getopts` twice in one shell, reset it manually with `OPTIND=1`.)

**A7.3 —** The leading `:` selects **silent error reporting**. Without it, `getopts` prints its own message to stderr for unknown options and missing arguments. With it: an unknown option sets `opt` to `?` and puts the offending letter in `OPTARG`; a missing required argument sets `opt` to `:` and puts the letter in `OPTARG`. That is the only way to distinguish "unknown flag" from "flag missing its value" and to emit your own consistent usage message.

**A7.4 —** When sourced with `. ./params.sh`, `$0` is the **calling shell's** `$0` (e.g. `bash` or `-bash`) — sourcing does not change it, which is why sourced files cannot reliably find their own path in POSIX sh. When run as `sh params.sh`, `$0` is `params.sh` (as typed, without `./`).

**A7.5 —** `${10}`. Bare `$10` is parsed as `${1}` followed by the literal character `0`, because unbraced positional parameters are a **single digit** only. The portable alternative is to `shift` past the first nine, or to iterate with `for a in "$@"`.

---

### Exercise 8

**A8.1 —** Because you must decide *whether to send at all* before sending, and `mail` has already committed to a message by the time it reads its stdin — piping `awk` directly would send an empty alert on every run. `[ -s "$report" ]` ("exists and size greater than zero") is exactly the "conditional" in "conditional mailing". This also gives you the report twice: once in the mail body, once for logging. The alternative that avoids the temp file is `report=$(df … | awk …); [ -n "$report" ] && printf '%s\n' "$report" | mail …` — fine here, but the file form scales to reports too large to hold comfortably in a variable.

**A8.2 —** Older Bourne-derived shells (and some `ksh` versions) do **not** run the `EXIT` trap when the shell is terminated by a signal — the process dies before the exit handler runs. Listing `HUP INT TERM` explicitly guarantees cleanup when the terminal closes, the user hits Ctrl-C, or `systemd`/`kill` sends `SIGTERM`. `KILL` (9) is absent because **`SIGKILL` cannot be caught, blocked or ignored** — the kernel destroys the process directly. That is precisely why `mktemp` files belong under `TMPDIR`/`/tmp`, where `systemd-tmpfiles` or a boot-time clean will eventually collect the orphan.

**A8.3 —** Plain `df` wraps long device names onto a second line when they exceed the column width (e.g. `/dev/mapper/vg_data-lv_backups`), so `awk '{print $5}'` reads the wrong field or the wrong line. `df -P` forces the POSIX output format: **exactly one line per filesystem**, fields in a fixed order (`Filesystem 1024-blocks Used Available Capacity Mounted-on`), and 1024-byte blocks regardless of `BLOCKSIZE`/`POSIXLY_CORRECT`. Any script that parses `df` must use `-P`.

**A8.4 —** `$5` is the string `"41%"`. In `awk`, a string-to-number comparison follows complex rules: comparing a field against a *numeric* variable `t` triggers numeric coercion only if the field "looks numeric", and `"41%"` does not — so `$5 >= t` may perform a **string** comparison, in which `"9%"` sorts after `"41%"` and the alert fires on the wrong filesystem. `$5 + 0` forces arithmetic evaluation, and awk's numeric parse stops at the first non-numeric character, yielding `41`. Explicit is correct.

**A8.5 —** `cron` mails **anything the job writes to stdout or stderr** to the address in `MAILTO` (or to the crontab's owner if unset). If the script also calls `mail` itself, root receives two messages for the same event. Resolutions, pick one:
- Keep the script's own `mail` (better: you control subject, recipient and formatting) and make the script **silent on stdout** — send all human output to the log via `logger`, or redirect in the crontab: `17 * * * * root /usr/local/sbin/diskwatch 85 >/dev/null 2>&1`. Beware: that redirection also hides genuine crashes, so pair it with `logger`.
- Or drop the `mail` call, let the script print the report to stdout only when there is something to report, and let cron do the mailing via `MAILTO=root`. Simplest, but you lose control of the subject line.
Setting `MAILTO=""` in the crontab disables cron's mailing entirely.

**A8.6 —** *`/usr/local/sbin`*: it is a system-administration command (it reads all filesystems and mails root), not a user command, and it is locally written, so it belongs under `/usr/local` rather than `/usr/sbin`, which the package manager owns. *owner `root`*: cron runs it as root; a script root executes must not be writable by anyone else. *group `root`*: same reason — a group-writable file is a root shell for every member of that group. *mode `0750`*: `rwx` for root, `r-x` for group (here, only root), **nothing for others** — no reason for ordinary users to read internal thresholds, recipients or paths, and no reason for them to run it.

**A8.7 —**

```sh
send_mail() {   # send_mail <subject> <recipient>; body on stdin
    if command -v mail >/dev/null 2>&1; then
        mail -s "$1" "$2"
    elif [ -x /usr/sbin/sendmail ]; then
        {
            printf 'To: %s\n' "$2"
            printf 'Subject: %s\n' "$1"
            printf 'Auto-Submitted: auto-generated\n\n'
            cat
        } | /usr/sbin/sendmail -t
    else
        logger -t diskwatch -p user.err "no MTA available; alert dropped"
        return 1
    fi
}
```
`sendmail -t` reads the recipients from the header block, so you must emit `To:` and a blank line before the body. `Auto-Submitted: auto-generated` (RFC 3834) stops vacation responders from replying to your monitoring.

---

### Exercise 9

**A9.1 —** `-n` (`noexec`): parse the whole script and report syntax errors **without running anything** — the mandatory pre-flight check for any script you are about to install. `-v` (`verbose`): echo each line of input **as read**, before expansion. `-x` (`xtrace`): echo each command **after** expansion, prefixed by `$PS4`, as it executes. Use `-n` to validate, `-x` to debug, `-v` rarely (it shows you what you wrote, which you already have).

**A9.2 —** `set -x` writes to **stderr** (file descriptor 2), not stdout — deliberately, so the trace never contaminates a script's data output. Also note that `./script.sh -x` does **not** enable tracing at all: `-x` is passed to the script as `$1`. To trace, run `sh -x ./script.sh` or put `set -x` in the script. As for redirection: `> log` captures only stdout, leaving the trace on the terminal; `> log 2>&1` merges the trace into the same file, interleaved with output — which is what you usually want when debugging a cron job.

**A9.3 —** Under `set -u` (`nounset`), referencing an unset variable is a fatal error. `$1` is unset whenever the script is called with no arguments, so `if [ -z "$1" ]` aborts instead of reporting a usage error. `${1:-}` expands to the empty string when `$1` is unset, suppressing the `nounset` failure while still letting you test for emptiness. Same idiom for `"${@:-}"` on Bash < 4.4, where `"$@"` with zero parameters also tripped `-u`.

**A9.4 —** `pipefail` is **not POSIX** — `dash` does not implement it, and `set -o pipefail` fails with `Illegal option -o pipefail`, aborting the script on its first line. `set -e` and `set -u` are POSIX and work in `dash`, but `-u`'s exact behavior around `"$@"` varies. For `#!/bin/sh` the portable safety net is `set -eu` plus explicit status checks around every pipeline. If you want `pipefail`, change the shebang to `#!/bin/bash` and mean it.

---

### Exercise 10 — Reference implementation

```sh
#!/bin/sh
#
# svcaudit - report systemd services that are not active.
# Usage: svcaudit [-m] [-q] SERVICE...
#   -m  mail root if any service is down
#   -q  suppress normal stdout
# Exit: 0 all active, 1 at least one not active, 2 usage/internal error
#
set -u

do_mail=0
quiet=0
report=""

usage() {
    echo "usage: $(basename "$0") [-m] [-q] SERVICE..." >&2
    exit 2
}

cleanup() { [ -n "$report" ] && rm -f "$report"; }
trap cleanup EXIT HUP INT TERM

while getopts ':mqh' opt; do
    case "$opt" in
        m)  do_mail=1 ;;
        q)  quiet=1 ;;
        h)  usage ;;
        :)  echo "option -$OPTARG requires an argument" >&2; usage ;;
        \?) echo "unknown option: -$OPTARG" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

[ "$#" -ge 1 ] || usage

report=$(mktemp "${TMPDIR:-/tmp}/svcaudit.XXXXXX") || exit 2
failures=0

while [ "$#" -gt 0 ]; do
    svc=$1
    shift
    state=$(systemctl is-active "$svc" 2>/dev/null) || true
    case "$state" in
        active)
            [ "$quiet" -eq 1 ] || printf '%-24s %s\n' "$svc" "OK ($state)"
            ;;
        activating|reloading)
            [ "$quiet" -eq 1 ] || printf '%-24s %s\n' "$svc" "TRANSIENT ($state)"
            ;;
        *)
            [ "$quiet" -eq 1 ] || printf '%-24s %s\n' "$svc" "DOWN (${state:-unknown})"
            printf '%-24s %s\n' "$svc" "${state:-unknown}" >> "$report"
            failures=$((failures + 1))
            ;;
    esac
done

if [ "$failures" -gt 0 ]; then
    if [ "$do_mail" -eq 1 ] && [ -s "$report" ]; then
        {
            printf 'Service audit on %s at %s\n\n' "$(uname -n)" "$(date -Is)"
            printf '%d service(s) not active:\n\n' "$failures"
            cat "$report"
        } | mail -s "[SVC] $(uname -n): $failures service(s) not active" root
    fi
    logger -t svcaudit -p user.warning "$failures service(s) not active"
    exit 1
fi

logger -t svcaudit -p user.info "all requested services active"
exit 0
```

Validate and install:

```bash
dash -n svcaudit && echo "POSIX syntax OK"
sudo install -o root -g root -m 0750 svcaudit /usr/local/sbin/svcaudit
```

Expected run:

```
sshd                     OK (active)
cron                     OK (active)
nosuchservice            DOWN (inactive)
===== FAKE MTA =====
argv : -s [SVC] workstation: 1 service(s) not active root
----- body -----
Service audit on workstation at 2026-08-26T11:07:52+02:00

1 service(s) not active:

nosuchservice            inactive

===== END =====
-> 1
```

Points worth noting in the implementation:
- `state=$(systemctl is-active "$svc") || true` — `is-active` **exits non-zero** when the unit is not active, which under `set -e` would kill the script; `|| true` neutralizes it while the value is still captured.
- `${state:-unknown}` covers the case where `systemctl` produces no output at all (unit not found on some versions).
- `cleanup()` guards on `[ -n "$report" ]` because the trap is installed *before* `mktemp` runs — an early `usage` exit must not `rm -f ""`.
- `while [ "$#" -gt 0 ]; …; shift` is used instead of `for svc in "$@"` purely to satisfy requirement 5; `for svc do` is the idiomatic form.

</details>

---

## Sources

- LPI — Exam 101-500 Objectives: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — Exam 102-500 Objectives (Topic 105.2 lives here): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- The Open Group — POSIX.1-2017, Shell Command Language: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html>
- GNU Bash Reference Manual: <https://www.gnu.org/software/bash/manual/bash.html>
- `execve(2)` — interpreter scripts, and the ignoring of set-user-ID on scripts: <https://man7.org/linux/man-pages/man2/execve.2.html>
- `test(1)` / POSIX `test`: <https://man7.org/linux/man-pages/man1/test.1.html> · <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html>
- `getopts` (POSIX): <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/getopts.html>
- `df(1)` and the `-P` POSIX output format: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/df.html>
- `mailx(1p)` — the POSIX mail interface: <https://man7.org/linux/man-pages/man1/mailx.1p.html>
- `crontab(5)` — `MAILTO` and job output handling: <https://man7.org/linux/man-pages/man5/crontab.5.html>
- Filesystem Hierarchy Standard 3.0, §4.9 `/usr/local`: <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch04s09.html>
- Sudo — `sudoers(5)`: <https://www.sudo.ws/docs/man/sudoers.man/>
- ShellCheck: <https://www.shellcheck.net/>