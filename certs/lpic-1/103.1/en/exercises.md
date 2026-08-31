# 103.1 — Work on the Command Line
## Guided Exercises (LPIC-1, exam 101-500 v5.0)

**Scope covered:** single commands and one-line command sequences · shell vs. environment variables (`set`, `unset`, `export`, `env`) · command resolution and `PATH` · quoting · command history and `.bash_history` · `man` and self-documentation · `uname`, `pwd`, `echo`, `type`, `which`.

**Reference sources**
- LPI Exam 101-500 objectives — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Bash Reference Manual — <https://www.gnu.org/software/bash/manual/bash.html>
- GNU Coreutils Manual — <https://www.gnu.org/software/coreutils/manual/coreutils.html>
- Linux `man-pages` project — <https://www.kernel.org/doc/man-pages/>

---

## Before you start

These exercises assume an interactive **Bash 5.x** shell on any mainstream distribution, running as an **unprivileged user**. No `sudo` is required. Exact byte-for-byte output varies by distribution and Bash build — where that matters, it is called out.

Every artefact is created under `/tmp/lab103` and `~/bin`, and Exercise 9 removes them.

```bash
mkdir -p /tmp/lab103
cd /tmp/lab103
pwd
```

Expected:

```
/tmp/lab103
```

> **Working habit:** open a *second* terminal and keep `man bash` in it. Almost every question below is answerable from that page, and the exam rewards knowing *where* the answer lives.

---

## Exercise 1 — Identify the shell you are actually running

The command line is a *process*. Before changing its behaviour, prove which process it is.

1. Print the shell's process ID and its parent:

   ```bash
   echo "$$"
   ps -p "$$" -o pid,ppid,comm
   ```

   Expected (numbers will differ):

   ```
   4711
       PID    PPID COMMAND
      4711    4702 bash
   ```

2. Ask Bash for its own version, two different ways:

   ```bash
   echo "$BASH_VERSION"
   bash --version | head -n 1
   ```

   Expected:

   ```
   5.2.21(1)-release
   GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
   ```

3. Look at `$0`, then compare with a login shell:

   ```bash
   echo "$0"
   bash -l -c 'echo "$0"'
   ```

   Expected:

   ```
   bash
   -bash
   ```

4. Identify the kernel and machine hardware, which is what `uname` reports — **not** the distribution:

   ```bash
   uname
   uname -s -r -m
   uname -a
   ```

   Expected (shortened):

   ```
   Linux
   Linux 6.8.0-45-generic x86_64
   Linux studybox 6.8.0-45-generic #45-Ubuntu SMP ... x86_64 GNU/Linux
   ```

5. Compare that with the distribution's own identity file:

   ```bash
   cat /etc/os-release | head -n 3
   ```

**Check your understanding**

- **Q1.1** — Why does `bash -l -c 'echo "$0"'` print `-bash` instead of `bash`? What consumes that leading hyphen, and what does it decide?
- **Q1.2** — `uname -r` reports `6.8.0-45-generic`, but `/etc/os-release` says `Ubuntu 24.04`. Explain precisely what each value describes and why one cannot be derived from the other.
- **Q1.3** — `$$` is a shell variable. Predict the output of `echo "$$"` versus `bash -c 'echo "$$"'` run from the same shell, and justify the difference.

---

## Exercise 2 — How Bash decides *what* to run

When you type a word, Bash resolves it in a fixed order: **alias → function → builtin → hashed path → `PATH` search**. This exercise makes that order visible.

1. Inspect the type of several commands:

   ```bash
   type -t if
   type -t cd
   type -t ls
   type -t bash
   ```

   Expected (on a typical distribution where `ls` is aliased):

   ```
   keyword
   builtin
   alias
   file
   ```

2. Show *every* candidate for a name, in resolution order:

   ```bash
   type -a echo
   ```

   Expected:

   ```
   echo is a shell builtin
   echo is /usr/bin/echo
   echo is /bin/echo
   ```

3. Contrast the three lookup tools:

   ```bash
   type echo
   command -v echo
   which echo
   ```

   Expected:

   ```
   echo is a shell builtin
   echo
   /usr/bin/echo
   ```

4. Create a deliberate collision — a *function* that shadows an external command:

   ```bash
   pwd() { echo "I am a function, not the real pwd"; }
   pwd
   type -a pwd
   command pwd
   /bin/pwd
   unset -f pwd
   pwd
   ```

   Expected:

   ```
   I am a function, not the real pwd
   pwd is a function
   pwd ()
   {
       echo "I am a function, not the real pwd"
   }
   pwd is a shell builtin
   pwd is /usr/bin/pwd
   /tmp/lab103
   /tmp/lab103
   /tmp/lab103
   ```

5. Observe the **hash table** — Bash's cache of resolved `PATH` lookups:

   ```bash
   hash -r
   hash
   date > /dev/null; date > /dev/null; ls > /dev/null
   hash
   ```

   Expected:

   ```
   hash: hash table empty
   hits	command
      2	/usr/bin/date
      1	/usr/bin/ls
   ```

**Check your understanding**

- **Q2.1** — Reproduce the resolution order in full. At which step does a shell *keyword* like `if` get handled, and why can it never be overridden by a file in `PATH`?
- **Q2.2** — `which echo` says `/usr/bin/echo`, but typing `echo` runs the builtin. Explain why `which` gives a misleading answer here, and name the POSIX-correct replacement.
- **Q2.3** — After `pwd() { ...; }`, `command pwd` and `/bin/pwd` both bypass the function but are *not* equivalent. What is the difference?
- **Q2.4** — You move `/usr/bin/date` to `/usr/local/bin/date` and `date` afterwards fails with `No such file or directory` even though the new location is in `PATH`. What caused it, and which single command fixes it?

---

## Exercise 3 — Invoking commands inside and outside `PATH`

1. Look at your search path, one entry per line:

   ```bash
   echo "$PATH"
   echo "$PATH" | tr ':' '\n'
   ```

2. Create a personal command. Note the **quoted** here-document delimiter:

   ```bash
   mkdir -p ~/bin
   cat > ~/bin/greet <<'EOF'
   #!/bin/bash
   echo "greet: script=$0 pid=$$ user=$USER"
   EOF
   chmod +x ~/bin/greet
   ls -l ~/bin/greet
   ```

   Expected:

   ```
   -rwxr-xr-x 1 student student 62 Aug 26 10:14 /home/student/bin/greet
   ```

3. Try to run it by bare name, then by path:

   ```bash
   greet
   ~/bin/greet
   /home/"$USER"/bin/greet
   ```

   Expected (assuming `~/bin` is not yet in `PATH`):

   ```
   bash: greet: command not found
   greet: script=/home/student/bin/greet pid=4802 user=student
   greet: script=/home/student/bin/greet pid=4803 user=student
   ```

4. Add the directory to `PATH` and retry:

   ```bash
   export PATH="$HOME/bin:$PATH"
   greet
   type greet
   ```

   Expected:

   ```
   greet: script=/home/student/bin/greet pid=4810 user=student
   greet is /home/student/bin/greet
   ```

5. Now create a *second* `greet` in the current directory and observe that it is **not** picked:

   ```bash
   cd /tmp/lab103
   printf '#!/bin/bash\necho "greet: LOCAL copy"\n' > greet
   chmod +x greet
   greet
   ./greet
   ```

   Expected:

   ```
   greet: script=/home/student/bin/greet pid=4820 user=student
   greet: LOCAL copy
   ```

6. Remove the execute bit and observe the distinct error:

   ```bash
   chmod -x greet
   ./greet
   bash greet
   ```

   Expected:

   ```
   bash: ./greet: Permission denied
   greet: LOCAL copy
   ```

**Check your understanding**

- **Q3.1** — Why is `./greet` required, while `greet` alone is not enough? What would break if `.` were added to `PATH`?
- **Q3.2** — In step 6, `./greet` fails with *Permission denied* but `bash greet` succeeds. Which permission bit does each invocation actually require, and why do they differ?
- **Q3.3** — `export PATH="$HOME/bin:$PATH"` was run in one terminal. Open a new terminal and run `type greet`. What happens, and where must the line go to make it permanent for interactive shells?
- **Q3.4** — What is the practical difference between `PATH="$HOME/bin:$PATH"` and `PATH="$PATH:$HOME/bin"`? Give a scenario where the choice changes which binary runs.

---

## Exercise 4 — Shell variables vs. environment variables

This is the single most-tested distinction in 103.1.

1. Create a plain **shell** variable — note: no spaces around `=`:

   ```bash
   MYVAR=hello
   echo "$MYVAR"
   ```

   Then observe what the wrong syntax does:

   ```bash
   MYVAR = hello
   ```

   Expected:

   ```
   hello
   bash: MYVAR: command not found
   ```

2. Ask two different tools whether the variable exists:

   ```bash
   set | grep '^MYVAR='
   env | grep '^MYVAR='
   echo "env exit status: $?"
   ```

   Expected:

   ```
   MYVAR=hello
   env exit status: 1
   ```

3. Prove that a child process does not see it, then export and retry:

   ```bash
   bash -c 'echo "child sees: [$MYVAR]"'
   export MYVAR
   bash -c 'echo "child sees: [$MYVAR]"'
   env | grep '^MYVAR='
   ```

   Expected:

   ```
   child sees: []
   child sees: [hello]
   MYVAR=hello
   ```

4. Inspect the variable's attributes directly:

   ```bash
   declare -p MYVAR
   export -n MYVAR
   declare -p MYVAR
   export MYVAR
   ```

   Expected:

   ```
   declare -x MYVAR="hello"
   declare -- MYVAR="hello"
   ```

5. Set a variable **for one command only**, and confirm the parent is untouched:

   ```bash
   MYVAR=temporary bash -c 'echo "child: $MYVAR"'
   echo "parent: $MYVAR"
   env MYVAR=viaenv bash -c 'echo "child: $MYVAR"'
   echo "parent: $MYVAR"
   ```

   Expected:

   ```
   child: temporary
   parent: hello
   child: viaenv
   parent: hello
   ```

6. Demonstrate that the child gets a **copy**, not a reference:

   ```bash
   bash -c 'MYVAR=changed_by_child; echo "child now: $MYVAR"'
   echo "parent still: $MYVAR"
   ```

   Expected:

   ```
   child now: changed_by_child
   parent still: hello
   ```

7. Start a process with a **scrubbed** environment:

   ```bash
   env -i printenv | wc -l
   env -i bash -c 'echo "PATH=[$PATH]"'
   ```

   Expected:

   ```
   0
   PATH=[/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games]
   ```

   (The exact `PATH` differs — it is Bash's compiled-in default, not an inherited value.)

8. Remove the variable, and note that `unset` has two namespaces:

   ```bash
   unset -v MYVAR
   echo "[${MYVAR}]"
   readonly RO=locked
   unset -v RO
   ```

   Expected:

   ```
   []
   bash: unset: RO: cannot unset: readonly variable
   ```

**Check your understanding**

- **Q4.1** — State the exact difference between a shell variable and an environment variable, in terms of what `fork()`/`exec()` transfers to the child.
- **Q4.2** — `set | grep MYVAR` finds it, `env | grep MYVAR` does not. Which one lists which namespace, and what *else* does bare `set` print that `env` never will?
- **Q4.3** — In step 7, `env -i` cleared the environment, yet the child Bash still reported a non-empty `PATH`. Where did that value come from? Why does this matter when debugging a cron job?
- **Q4.4** — A colleague sets `EDITOR=vim` in their shell and complains that `sudo visudo` still opens `nano`. Give two independent reasons this can happen, and the command that proves which one applies.
- **Q4.5** — Why does `MYVAR=temporary bash -c '...'` not leave `MYVAR` altered in the parent, whereas `export MYVAR=temporary; bash -c '...'` would?

---

## Exercise 5 — Quoting: the mechanism, not the folklore

1. Create a file whose name contains a space, then break it:

   ```bash
   cd /tmp/lab103
   file="my report.txt"
   touch "$file"
   ls -l $file
   ls -l "$file"
   ```

   Expected:

   ```
   ls: cannot access 'my': No such file or directory
   ls: cannot access 'report.txt': No such file or directory
   -rw-r--r-- 1 student student 0 Aug 26 10:20 'my report.txt'
   ```

2. Watch the shell's expansion with the execution trace:

   ```bash
   set -x
   ls -l $file
   ls -l "$file"
   set +x
   ```

   Expected (trace lines begin with `+`):

   ```
   + ls -l my report.txt
   ...
   + ls -l 'my report.txt'
   ```

3. Compare the three quoting mechanisms against the same string:

   ```bash
   echo 'Home is $HOME and the date is $(date +%F)'
   echo "Home is $HOME and the date is $(date +%F)"
   echo Home is \$HOME
   ```

   Expected:

   ```
   Home is $HOME and the date is $(date +%F)
   Home is /home/student and the date is 2026-08-26
   Home is $HOME
   ```

4. Test what *double* quotes still allow through:

   ```bash
   touch a.txt b.txt
   echo *.txt
   echo "*.txt"
   echo "user=$USER host=$(hostname) sum=$((6*7))"
   ```

   Expected:

   ```
   a.txt b.txt my report.txt
   *.txt
   user=student host=studybox sum=42
   ```

5. Handle the single-quote-inside-single-quotes problem:

   ```bash
   echo "it's fine"
   echo 'it'\''s fine'
   echo $'tab\there\nnewline done'
   ```

   Expected:

   ```
   it's fine
   it's fine
   tab	here
   newline done
   ```

6. Use a backslash as a **line continuation** in a one-line sequence:

   ```bash
   echo "first part" \
        "second part"
   ```

   Expected:

   ```
   first part second part
   ```

7. Observe the consequence of an unquoted variable holding an empty value:

   ```bash
   empty=""
   ls -l $empty
   ls -l "$empty"
   ```

   Expected: the first lists the current directory; the second reports

   ```
   ls: cannot access '': No such file or directory
   ```

**Check your understanding**

- **Q5.1** — List, in order, the expansions Bash performs on a command line. At which step does word splitting occur, and why does that make `ls -l $file` fail while `ls -l "$file"` works?
- **Q5.2** — Which characters retain their special meaning **inside** double quotes? Which inside single quotes?
- **Q5.3** — Why can a single-quoted string never contain a single quote, not even escaped?
- **Q5.4** — In step 7, unquoted `$empty` produced *zero* arguments while `"$empty"` produced *one empty* argument. Explain the mechanism, and describe a scenario where this turns a harmless script into a destructive one.
- **Q5.5** — `echo "*.txt"` printed the literal glob. Which entity performs pathname expansion — the shell or `echo`? What does `echo` receive in each case?

---

## Exercise 6 — One-line command sequences and exit status

1. Read exit status directly:

   ```bash
   true;  echo "status=$?"
   false; echo "status=$?"
   ls /nonexistent 2>/dev/null; echo "status=$?"
   ```

   Expected:

   ```
   status=0
   status=1
   status=2
   ```

2. Compare the three separators:

   ```bash
   false ; echo "semicolon: always runs"
   false && echo "AND: not printed"
   false || echo "OR: printed"
   true  && echo "AND: printed"
   ```

3. Chain a realistic sequence:

   ```bash
   mkdir -p /tmp/lab103/out && cd /tmp/lab103/out && pwd && cd - >/dev/null
   grep -q '^root:' /etc/passwd && echo "root present" || echo "root missing"
   ```

   Expected:

   ```
   /tmp/lab103/out
   root present
   ```

4. Expose the classic `&& ... || ...` trap:

   ```bash
   true && ls /nonexistent 2>/dev/null || echo "fallback ran"
   ```

   Expected:

   ```
   fallback ran
   ```

5. Contrast a **subshell** with a **group command**:

   ```bash
   cd /tmp/lab103
   pwd ; ( cd /tmp && pwd ) ; pwd
   pwd ; { cd /tmp && pwd ; } ; pwd
   cd /tmp/lab103
   ```

   Expected:

   ```
   /tmp/lab103
   /tmp
   /tmp/lab103
   /tmp/lab103
   /tmp
   /tmp
   ```

6. Show that variables set in a subshell do not survive:

   ```bash
   V=outer
   ( V=inner; echo "inside: $V" )
   echo "outside: $V"
   ```

   Expected:

   ```
   inside: inner
   outside: outer
   ```

7. Read the exit status of a **pipeline**:

   ```bash
   false | true ; echo "pipeline status=$?"
   echo "each stage: ${PIPESTATUS[@]}"
   set -o pipefail
   false | true ; echo "with pipefail=$?"
   set +o pipefail
   ```

   Expected:

   ```
   pipeline status=0
   each stage: 1 0
   with pipefail=1
   ```

8. Build one genuinely useful one-liner:

   ```bash
   cut -d: -f7 /etc/passwd | sort | uniq -c | sort -rn | head -n 5
   ```

   Expected (values vary):

   ```
        28 /usr/sbin/nologin
         3 /bin/false
         2 /bin/sync
         1 /bin/bash
   ```

**Check your understanding**

- **Q6.1** — Give the exit-status convention: which value means success, and what range is available for failure? What does status `127` specifically indicate, and `126`?
- **Q6.2** — Explain step 4. Why is `A && B || C` **not** a safe if/then/else, and what is the correct construct?
- **Q6.3** — Why did `( cd /tmp )` leave the caller's directory unchanged while `{ cd /tmp; }` did not? Which one forks?
- **Q6.4** — By default `$?` after a pipeline reports only one stage's status. Which stage, and what are the two mechanisms shown for seeing the rest?
- **Q6.5** — In step 8, how many processes does the shell create, and do they run sequentially or concurrently?

---

## Exercise 7 — Command history

1. Inspect the history and its configuration:

   ```bash
   history | tail -n 5
   echo "HISTFILE=$HISTFILE"
   echo "HISTSIZE=$HISTSIZE  HISTFILESIZE=$HISTFILESIZE"
   echo "HISTCONTROL=$HISTCONTROL"
   ```

   Expected:

   ```
      512  set +o pipefail
      513  cut -d: -f7 /etc/passwd | sort | uniq -c | sort -rn | head -n 5
      514  history | tail -n 5
   HISTFILE=/home/student/.bash_history
   HISTSIZE=1000  HISTFILESIZE=2000
   HISTCONTROL=ignoredups
   ```

2. Use event designators. `:p` **prints without executing** — always test with it first:

   ```bash
   echo alpha bravo charlie
   !!:p
   !!
   !echo:p
   ```

   Expected:

   ```
   alpha bravo charlie
   echo alpha bravo charlie
   echo alpha bravo charlie
   alpha bravo charlie
   echo alpha bravo charlie
   ```

3. Use word designators:

   ```bash
   ls -l /etc/hostname
   echo "last arg was: !$"
   echo "first arg was: !^"
   echo "all args were: !*"
   ```

   Expected:

   ```
   -rw-r--r-- 1 root root 9 Aug 26 09:02 /etc/hostname
   echo "last arg was: /etc/hostname"
   last arg was: /etc/hostname
   ...
   ```

   (Bash echoes the expanded line before running it — that is history expansion, not the command.)

4. Recall by number and repair a typo:

   ```bash
   history | tail -n 3
   !513
   grpe root /etc/passwd
   ^grpe^grep^
   ```

   Expected:

   ```
   bash: grpe: command not found
   grep root /etc/passwd
   root:x:0:0:root:/root:/bin/bash
   ```

5. Practise incremental search interactively: press **`Ctrl-R`**, type `passwd`, press `Ctrl-R` again to cycle backwards, then **`Ctrl-G`** to abort without running anything. Repeat and press **Enter** to execute, or **`→`**/**`Ctrl-E`** to edit the recalled line first.

6. Keep a command out of the history:

   ```bash
   HISTCONTROL=ignoreboth
   echo "this line is recorded"
    echo "this line is NOT recorded"
   history | tail -n 3
   ```

   (Note the single **leading space** on the second `echo`.)

7. Add timestamps and see they are display-time metadata:

   ```bash
   HISTTIMEFORMAT='%F %T  '
   history | tail -n 3
   ```

   Expected:

   ```
      520  2026-08-26 10:31:44  echo "this line is recorded"
      521  2026-08-26 10:31:58  history | tail -n 3
   ```

8. Manipulate the history list and the file:

   ```bash
   history | tail -n 1
   history -d 521
   wc -l < ~/.bash_history
   history -a
   wc -l < ~/.bash_history
   ```

9. Understand multi-terminal loss, then fix it:

   ```bash
   shopt histappend
   shopt -s histappend
   PROMPT_COMMAND='history -a'
   ```

10. Clear the in-memory list and, separately, the file:

    ```bash
    history -c
    history | wc -l
    ```

    Expected:

    ```
    1
    ```

**Check your understanding**

- **Q7.1** — Distinguish `HISTSIZE` from `HISTFILESIZE`. Which one is enforced when the shell exits?
- **Q7.2** — `history -c` returns an empty list, yet a new terminal shows the old commands again. Why? Which additional step actually removes them from disk?
- **Q7.3** — Explain the four `history` write/read options `-a`, `-w`, `-r`, `-n`, and why `shopt -s histappend` plus `history -a` is the standard fix for two terminals overwriting each other.
- **Q7.4** — What do `ignorespace`, `ignoredups`, `ignoreboth` and `erasedups` do in `HISTCONTROL`? Why is *"prefix the command with a space"* a poor way to hide a password?
- **Q7.5** — `!!` works when typed at the prompt but does nothing inside a shell script. Explain why, and name the shell option involved.
- **Q7.6** — What does `!$` expand to, and what is the single-keystroke Readline equivalent that inserts it without a history-expansion round-trip?

---

## Exercise 8 — Getting help: `man` and friends

1. Understand manual **sections**:

   ```bash
   man man | grep -A 12 'The table below'
   man 1 passwd
   man 5 passwd
   man -f passwd
   ```

   Expected from `man -f`:

   ```
   passwd (1)           - change user password
   passwd (5)           - the password file
   passwd (1ssl)        - compute password hashes
   ```

2. Search by keyword — this needs the index database:

   ```bash
   man -k 'change user password'
   apropos hostname | head -n 5
   whatis uname
   ```

   Expected:

   ```
   passwd (1)           - change user password
   ...
   uname (1)            - print system information
   uname (2)            - get name and information about current kernel
   ```

   If `man -k` reports `nothing appropriate`, the index is missing; on most systems it is rebuilt with `mandb` (root) and refreshed by a periodic timer.

3. Locate the source file and the page's origin:

   ```bash
   man -w ls
   man -w 5 passwd
   ```

   Expected:

   ```
   /usr/share/man/man1/ls.1.gz
   /usr/share/man/man5/passwd.5.gz
   ```

4. Ask for help on a **builtin** — where `man` usually fails:

   ```bash
   type -t cd
   help cd | head -n 5
   help -d export
   man cd
   ```

   Expected:

   ```
   builtin
   cd: cd [-L|[-P [-e]] [-@]] [dir]
       Change the shell working directory.
   export - Set export attribute for shell variables.
   No manual entry for cd
   ```

5. Use the third help channel — the program's own flag:

   ```bash
   ls --help | head -n 5
   uname --help | tail -n 5
   ```

6. Navigate a page efficiently (interactive, inside `man ls`): `/` search forward, `n` next match, `N` previous, `G` end, `g` start, `q` quit. Try:

   ```bash
   man ls
   ```

   then type `/--human-readable` and press Enter.

7. Read a Bash concept straight from the source page:

   ```bash
   man bash | grep -n 'QUOTING' | head -n 3
   ```

**Check your understanding**

- **Q8.1** — Name the purpose of manual sections 1, 5 and 8, and explain why `passwd` legitimately appears in two of them.
- **Q8.2** — `man -k ssh` returns `nothing appropriate` on a freshly installed server, yet `man ssh` works perfectly. What is broken, and what fixes it?
- **Q8.3** — Give the three distinct help channels demonstrated here and state which one is authoritative for `cd`, `export` and `unset`. Why is `man` the wrong tool for those?
- **Q8.4** — `whatis` and `man -f` produced the same output; so did `apropos` and `man -k`. What is the actual relationship between these commands?

---

## Exercise 9 — Capstone: diagnose a broken invocation

A script fails for reasons that combine everything above. Build it, break it, then repair it using only the diagnostic commands from this topic.

1. Set up the scenario:

   ```bash
   mkdir -p "/tmp/lab103/data files"
   touch "/tmp/lab103/data files/alpha.log" "/tmp/lab103/data files/beta.log"

   cat > /tmp/lab103/collect <<'EOF'
   #!/bin/bash
   echo "DATADIR=[$DATADIR]"
   ls -1 $DATADIR
   greet
   EOF
   chmod +x /tmp/lab103/collect
   ```

2. Run it the way the author "tested" it:

   ```bash
   DATADIR="/tmp/lab103/data files"
   /tmp/lab103/collect
   ```

   Expected — note it *silently lists the wrong directory*:

   ```
   DATADIR=[]
   collect
   data files
   greet
   my report.txt
   ...
   greet: script=/home/student/bin/greet pid=5011 user=student
   ```

3. Reproduce the second failure by sanitising the environment:

   ```bash
   env PATH=/usr/bin:/bin DATADIR="/tmp/lab103/data files" /tmp/lab103/collect
   ```

   Expected:

   ```
   DATADIR=[/tmp/lab103/data files]
   ls: cannot access '/tmp/lab103/data': No such file or directory
   ls: cannot access 'files': No such file or directory
   /tmp/lab103/collect: line 4: greet: command not found
   ```

4. Gather evidence before changing anything:

   ```bash
   declare -p DATADIR
   env | grep -c '^DATADIR='
   type greet
   bash -x /tmp/lab103/collect 2>&1 | head -n 8
   ```

5. Apply the three fixes:

   ```bash
   cat > /tmp/lab103/collect <<'EOF'
   #!/bin/bash
   : "${DATADIR:?DATADIR must be set and exported}"
   echo "DATADIR=[$DATADIR]"
   ls -1 "$DATADIR"
   PATH="$HOME/bin:$PATH"
   greet
   EOF
   chmod +x /tmp/lab103/collect

   export DATADIR="/tmp/lab103/data files"
   /tmp/lab103/collect
   ```

   Expected:

   ```
   DATADIR=[/tmp/lab103/data files]
   alpha.log
   beta.log
   greet: script=/home/student/bin/greet pid=5044 user=student
   ```

6. Confirm the guard works:

   ```bash
   env -u DATADIR /tmp/lab103/collect ; echo "status=$?"
   ```

   Expected:

   ```
   /tmp/lab103/collect: line 2: DATADIR: DATADIR must be set and exported
   status=1
   ```

7. Clean up:

   ```bash
   cd ~
   rm -rf /tmp/lab103
   rm -f ~/bin/greet
   unset -v DATADIR MYVAR file empty V
   hash -r
   ```

**Check your understanding**

- **Q9.1** — In step 2 the script printed `DATADIR=[]` and then listed a *different* directory instead of erroring. Trace both consequences back to their two independent root causes.
- **Q9.2** — In step 3, one variable (`DATADIR`) reached the script and another setting (`PATH`) broke it. Explain exactly how `env PATH=... DATADIR=... cmd` composes the child's environment.
- **Q9.3** — `bash -x` was used instead of `set -x`. When would you prefer each, and what does the trace prove that `echo` debugging cannot?
- **Q9.4** — The fix sets `PATH` inside the script without `export`. Does `greet` still resolve? Justify your answer in terms of who performs the `PATH` search.
- **Q9.5** — `: "${DATADIR:?message}"` is an idiom. What does the leading `:` do, what does `:?` do, and how does the behaviour differ from `${DATADIR:-default}` and `${DATADIR:=default}`?

---

<details>
<summary><strong>Answers</strong> — open only after attempting the exercises</summary>

### Exercise 1

**A1.1** — A login shell is started with `argv[0]` set to the shell name prefixed by a hyphen; that is the historical convention `login`, `sshd`, `su -` and `bash -l` follow. Bash inspects `argv[0]` at startup: a leading `-` marks the shell as a **login shell**, which changes the startup files it reads (`/etc/profile`, then the first existing of `~/.bash_profile`, `~/.bash_login`, `~/.profile`, and `~/.bash_logout` on exit) instead of the non-login interactive path (`~/.bashrc`). Nothing "consumes" the hyphen — it is simply data in `argv[0]` that Bash tests. This is why `PATH` additions placed in `~/.bash_profile` appear in an SSH login but not in a new terminal tab.

**A1.2** — `uname -r` reports the **kernel release** of the currently running kernel image, obtained from the `uname(2)` syscall. `/etc/os-release` describes the **userland distribution** — the package set, its version and its vendor — and is a plain text file with no kernel involvement. They are independent: the same Ubuntu 24.04 userland can run a distro kernel, a mainline kernel, or a vendor kernel; conversely the same 6.8 kernel runs under Debian, Ubuntu or Fedora userlands. Neither can be derived from the other. Practical consequence: `uname -a` never tells you which package manager to use.

**A1.3** — `echo "$$"` prints the **current shell's** PID. `bash -c 'echo "$$"'` forks and executes a new Bash, whose `$$` is its **own** PID — a different, larger number. `$$` is expanded by the shell that is executing the command, and in the second case the single quotes prevented the parent from expanding it, so the child did. (Subtle exception worth knowing: inside a `( ... )` subshell `$$` still reports the *parent's* PID, because Bash deliberately preserves it; `$BASHPID` gives the real one.)

---

### Exercise 2

**A2.1** — Bash resolves a command word in this order:
1. **Reserved word / keyword** (`if`, `for`, `while`, `case`, `function`, `[[`, `time`, `{`) — recognised by the *parser*, before any expansion or lookup happens at all.
2. **Alias** — textual substitution, interactive shells only by default.
3. **Function**.
4. **Builtin**.
5. **Hashed path** — the cached full path from a previous successful `PATH` search.
6. **`PATH` search**, left to right, first executable match wins.

A keyword can never be overridden by a file because it is consumed during parsing to determine the command's *grammar*; by the time any lookup could occur, `if` is no longer a candidate command name. A file called `/usr/bin/if` is only reachable by full path or via `command`/`env`.

**A2.2** — `which` is an **external program** (or on some distributions a shell script/alias). It knows only `PATH`; it has no visibility into the calling shell's aliases, functions, builtins or hash table, and its behaviour and exit codes vary between distributions. It answers "is there a file named `echo` in `PATH`" — a different question from "what will Bash run". The POSIX-correct replacements are `command -v NAME` (machine-readable: prints a path, an alias definition, or the bare name for builtins/keywords) and `type NAME` / `type -a NAME` (human-readable, shows all candidates in order).

**A2.3** — `command pwd` skips **aliases and functions** but still uses the normal builtin/`PATH` resolution, so it runs the **`pwd` builtin**. `/bin/pwd` bypasses resolution entirely and executes the **coreutils binary** in a new process. The distinction is observable: the builtin reports Bash's own logical `$PWD` (symlinks preserved) by default, while `/bin/pwd` also defaults to logical mode but is a separate process with its own `getcwd()` behaviour under `-P`. Practically, `command` is cheaper (no `fork`/`exec`) and is the right tool for defeating a function; the absolute path is the right tool when you must guarantee the external implementation.

**A2.4** — Bash's **hash table** cached the old location `/usr/bin/date` from the earlier successful lookup, and it retries that stale path rather than re-searching `PATH`. Fix: `hash -r` (or `hash -d date` for one entry) clears the cache and forces a fresh search. `hash -r` is also the reflex after installing a package into a directory you already searched unsuccessfully.

---

### Exercise 3

**A3.1** — Bash only searches `PATH` for command words that contain **no slash**. A word containing a slash is treated as a pathname and used directly. Since `.` is not in `PATH` on a correctly configured system, the bare word `greet` triggers a `PATH` search that misses the local file; `./greet` contains a slash, so it is used verbatim. Adding `.` to `PATH` is a well-known privilege-escalation vector: an attacker who can write to a shared or world-writable directory (`/tmp`, an upload dir) plants a file named `ls` or `sl`, and any user who `cd`s there and runs `ls` executes it. The risk is worst when `.` is *first* in `PATH` and when the victim is root.

**A3.2** — `./greet` asks the **kernel** to `execve()` the file, which requires the **execute** bit for the calling user; the kernel then reads the `#!` line and runs the interpreter. Without `x`, `execve()` returns `EACCES` and Bash prints *Permission denied*. `bash greet` executes `/usr/bin/bash` (which has `x`) and passes `greet` as an argument; Bash then only needs to **read** the file, so the `r` bit alone suffices. Corollary: the `#!` line is irrelevant in the second form — `bash greet` would run a script whose shebang says `#!/usr/bin/python3`.

**A3.3** — The new terminal prints `bash: type: greet: not found`. `export` modifies only the current shell and the children it later spawns; it cannot reach sibling or future terminals. To make it permanent for interactive non-login shells, add `export PATH="$HOME/bin:$PATH"` to `~/.bashrc`; for login shells (SSH, console, `su -`) add it to `~/.bash_profile` — the common pattern is to put it in `~/.bashrc` and have `~/.bash_profile` source `~/.bashrc`. Note that many distributions already add `~/bin` to `PATH` from `~/.profile` **if the directory exists at login time**, which is why creating `~/bin` sometimes appears to work only after re-logging in.

**A3.4** — `PATH` is searched left to right, first match wins. Prepending (`"$HOME/bin:$PATH"`) means your copies **shadow** system commands; appending means system commands win and yours are only a fallback. Scenario: you place a wrapper named `kubectl` in `~/bin` that injects a `--context` flag. Prepended, every invocation uses your wrapper. Appended, `/usr/bin/kubectl` is found first and the wrapper is dead code. Prepending is convenient but is also how a compromised `~/bin` silently hijacks every command you type — the security trade-off is the same one as `.` in `PATH`, only slower to exploit.

---

### Exercise 4

**A4.1** — A **shell variable** lives in the shell process's own memory. An **environment variable** is a shell variable additionally marked with the *export* attribute, which causes Bash to place it in the `envp` array passed to `execve()` when it launches a child. The child's C runtime exposes that array as `environ`, and its own shell (if it is a shell) turns each entry back into an exported variable. So `export` does not "share" anything: it enrols the variable in the **one-way copy** made at `exec()` time. A child can never write back to the parent's environment — the only channels are exit status, output streams, files, and IPC.

**A4.2** — `set` with no arguments lists the shell's **entire** variable namespace — exported *and* non-exported variables — plus **all defined shell functions** with their bodies. `env` (and `printenv`) lists only the **exported** environment that a child would inherit. Functions and non-exported variables never appear in `env`. This is exactly why `set | grep MYVAR` matched and `env | grep MYVAR` returned nothing with exit status 1 (grep found no match). In practice `declare -p NAME` is the precise tool: `declare -x` means exported, `declare --` means shell-only.

**A4.3** — When Bash starts and finds no `PATH` in its inherited environment, it initialises `PATH` from a **compiled-in default** (`DEFAULT_PATH_VALUE`, chosen at build time by the distribution). That value is typically much shorter than a login `PATH` and frequently omits `/usr/local/bin`, `/sbin`, `/usr/sbin` and `~/bin`. This is the canonical explanation for *"the script works in my terminal but fails in cron"*: `cron` starts jobs with a minimal environment (usually `PATH=/usr/bin:/bin`, `HOME`, `SHELL`, `LOGNAME` and nothing else), does **not** read `~/.bashrc` or `~/.bash_profile`, and so any command outside that skeleton `PATH` fails with *command not found*. `env -i` is the correct way to reproduce that failure interactively. Fix: use absolute paths in cron jobs, or set `PATH` explicitly at the top of the script/crontab.

**A4.4** — Two independent causes:
1. **`EDITOR` was never exported.** It exists as a shell variable, so `echo $EDITOR` prints `vim` in the shell, but `sudo` — a child process — never receives it. Proof: `declare -p EDITOR` shows `declare -- EDITOR="vim"` rather than `declare -x`.
2. **`sudo` scrubbed it.** By default `sudo` resets the environment according to `env_reset` and only passes variables listed in `env_keep` in `/etc/sudoers`. Even a properly exported `EDITOR` is dropped unless `env_keep += "EDITOR"` is set — and `visudo` specifically consults `SUDO_EDITOR`, then `VISUAL`, then `EDITOR`. Proof: `sudo printenv EDITOR` prints nothing while `printenv EDITOR` prints `vim`, and `sudo -V | grep -i env_keep` shows the policy.

The single diagnostic that separates them is `declare -p EDITOR`: if it lacks `-x`, cause 1; if it has `-x` and `sudo printenv EDITOR` is still empty, cause 2.

**A4.5** — `MYVAR=temporary bash -c '...'` is a **variable assignment prefixing a command**. POSIX defines this form to place the assignment in the *environment of that command only*; the current shell's variable is untouched (for regular builtins and external commands). `export MYVAR=temporary` instead performs an ordinary assignment in the current shell *and* sets the export attribute, so the change persists in the parent for every subsequent command. The prefix form is the correct idiom for one-shot overrides — `LC_ALL=C sort file`, `DEBUG=1 ./run.sh` — precisely because it cannot leak.

---

### Exercise 5

**A5.1** — Bash performs expansions in this fixed order:
1. Brace expansion (`{a,b}`)
2. Tilde expansion (`~`)
3. Parameter and variable expansion (`$VAR`, `${VAR}`)
4. Command substitution (`$(...)`, backticks)
5. Arithmetic expansion (`$((...))`)
6. **Word splitting** — on the characters in `IFS` (default: space, tab, newline)
7. Pathname expansion / globbing (`*`, `?`, `[...]`)
8. Quote removal

Word splitting happens at step 6, **after** the variable has already been replaced by its text. So `ls -l $file` becomes `ls -l my report.txt`, which is then split into two words and passed to `ls` as two separate arguments. Double quotes suppress steps 6 and 7 for the enclosed text, so `"$file"` survives as a single argument containing a space. The rule that follows: **quote every variable expansion unless you specifically want splitting and globbing.**

**A5.2** — Inside **double quotes**, these retain special meaning: `$` (parameter, command and arithmetic expansion), `` ` `` (legacy command substitution), `\` (only before `$`, `` ` ``, `"`, `\` or newline — elsewhere it is literal), and `!` (history expansion, in interactive shells only). Word splitting and globbing are disabled. Inside **single quotes**, *nothing* is special — every character including `$`, `` ` ``, `\`, `!`, `*` and newline is literal.

**A5.3** — Single-quote processing is defined as "consume characters literally until the next `'`". There is no escape mechanism inside, because `\` itself is literal there — so the very first `'` encountered *always* terminates the string. To include one you must leave the quoted region: `'it'\''s'` is the concatenation of `'it'` + `\'` (an escaped quote, outside quotes) + `'s'`, which the shell joins into a single word `it's`. Alternatives: `"it's"` or `$'it\'s'`.

**A5.4** — After parameter expansion `$empty` becomes the empty string; word splitting on an empty string yields **zero words**, so the argument disappears entirely and `ls -l` runs with no operand, defaulting to `.`. `"$empty"` is protected from splitting, so it survives as one argument that happens to be empty, and `ls` faithfully reports it cannot access `''`. The destructive scenario is the same mechanism with a different command: in a script, `rm -rf $PREFIX/$DIR` where both variables are unset expands to `rm -rf /` — the argument did not become empty, it became the root directory. Quoting turns that into a harmless error (`cannot remove '/'`); `set -u` or `${PREFIX:?}` prevents it outright.

**A5.5** — The **shell** performs pathname expansion, at step 7 above, before `echo` is ever executed. With `echo *.txt`, `echo` receives three separate arguments (`a.txt`, `b.txt`, `my report.txt`) and simply prints them space-separated. With `echo "*.txt"`, quoting suppressed globbing, so `echo` receives the single literal argument `*.txt`. Commands never see the glob — a critical point when a command implements its *own* pattern matching (`find -name '*.txt'`, `grep '*'`): there you must quote precisely to keep the shell from expanding the pattern first.

---

### Exercise 6

**A6.1** — Exit status `0` means **success**; any non-zero value in `1`–`255` means failure, and the meaning of the specific value is defined by the program (`ls` uses 1 for minor problems and 2 for serious ones; `grep` uses 1 for "no lines matched" and 2 for a real error). Reserved conventions: **`127` = command not found** (the `PATH` search failed), **`126` = found but not executable** (permission denied, or it is a directory), `128+N` = terminated by signal N (e.g. `130` = SIGINT/`Ctrl-C`, `137` = SIGKILL). The status of the last foreground command is in `$?`, and it is overwritten by the *next* command — capture it immediately if you need it.

**A6.2** — `A && B || C` runs `C` when **either** `A` fails **or** `B` fails. In step 4, `true` succeeded, so `ls /nonexistent` ran and failed, so the `||` branch fired — the fallback executed even though the "condition" was true. It only behaves like if/then/else when `B` is guaranteed to succeed. The correct construct is a real conditional:

```bash
if true; then
    ls /nonexistent
else
    echo "fallback ran"
fi
```

**A6.3** — `( ... )` runs its contents in a **subshell**: Bash forks a child process that inherits a copy of the environment, variables, functions and current directory. Any `cd`, variable assignment, `umask` or redirection inside affects only that copy, which then exits. `{ ...; }` is a **group command**: it is executed by the *current* shell with no fork at all, so its side effects persist. Only the parenthesised form forks. Syntax detail worth memorising: `{` and `}` are reserved words, so they need surrounding whitespace and the final command needs a `;` or newline before `}`; `(` and `)` are operators and need neither.

**A6.4** — By default `$?` reports the exit status of the **last (rightmost) command** in the pipeline — which is why `false | true` yields 0 and why a failing `grep` piped into `wc -l` looks successful. Two mechanisms expose the rest: the array **`${PIPESTATUS[@]}`**, which holds one status per stage of the most recent pipeline (index 0 is the leftmost), and **`set -o pipefail`**, which makes the pipeline return the status of the rightmost command that exited non-zero, or 0 if all succeeded. `pipefail` is a Bash extension, not POSIX; `PIPESTATUS` must be read *immediately*, since the next command replaces it.

**A6.5** — Five: `cut`, `sort`, `uniq`, `sort`, `head` — the shell forks and execs one process per stage. They run **concurrently**, not sequentially: the shell creates all the pipes and all the processes up front, connecting each stage's stdout to the next stage's stdin, and the kernel's pipe buffers plus blocking reads/writes provide the flow control. This is why a pipeline's memory footprint stays bounded on huge inputs, and why `head` closing early can make an upstream stage exit with SIGPIPE.

---

### Exercise 7

**A7.1** — `HISTSIZE` is the number of commands kept in the **in-memory** history list of the running shell. `HISTFILESIZE` is the maximum number of lines kept in the **history file** (`$HISTFILE`, by default `~/.bash_history`). `HISTFILESIZE` is applied when the history file is written — which normally happens when the shell **exits** — truncating the file to the most recent N lines. Setting either to an empty string or to a negative value means unlimited. Note that `HISTFILESIZE` is applied *after* the new entries are appended, so a small value silently discards old history on every exit.

**A7.2** — `history -c` clears only the **in-memory list** of the current shell; it never touches the file on disk. The new terminal reads `$HISTFILE` at startup, so it sees everything that was saved previously. To actually erase the stored history you must clear the memory list *and* overwrite the file: `history -c && history -w`, or remove the file (`rm -f ~/.bash_history`) — but beware that the current shell will rewrite it on exit with whatever it still holds, so clear memory first. A more careful sequence: `history -c; history -w; unset HISTFILE` (the last stops the exiting shell from writing anything).

**A7.3** —
- `history -a` — **append** the new entries of this session (those not yet written) to `$HISTFILE`.
- `history -w` — **write** the entire in-memory list to `$HISTFILE`, *overwriting* it.
- `history -r` — **read** the whole `$HISTFILE` and append it to the in-memory list.
- `history -n` — read only the **new** lines added to `$HISTFILE` since this shell last read it.

The default behaviour on exit is closer to `-w`, so with two terminals open the one that exits **last** overwrites the file and the other's commands vanish. `shopt -s histappend` changes the exit behaviour to append rather than truncate, and `PROMPT_COMMAND='history -a'` flushes each command to the file as soon as it is entered rather than waiting for exit — together they make concurrent sessions accumulate instead of clobber. Adding `history -n` to `PROMPT_COMMAND` additionally pulls in the other terminal's commands live.

**A7.4** —
- `ignorespace` — lines beginning with a space are not saved.
- `ignoredups` — a line identical to the *immediately preceding* one is not saved.
- `ignoreboth` — shorthand for both of the above.
- `erasedups` — remove all previous matching lines from the list before saving this one.

Prefixing with a space is a poor secret-hiding mechanism because it protects **only the history file**: the password is still visible in the process list (`ps aux`, `/proc/<pid>/cmdline`) for the lifetime of the process, may be logged by auditd/`sudo` logs or shell audit hooks, is exposed to every user on the machine, and the protection silently disappears if `HISTCONTROL` does not contain `ignorespace` (it is not the default everywhere). It also does nothing about the terminal scrollback. Correct approaches: read the secret with `read -s`, take it from a file with restrictive permissions, or use a credential helper — never as a command-line argument.

**A7.5** — History expansion (`!!`, `!$`, `!n`, `^old^new`) is a **Readline/interactive** feature controlled by the `histexpand` shell option, i.e. `set -H`. It is **on by default only for interactive shells** and is off in non-interactive shells such as scripts and `bash -c`. This is deliberate: a script containing `!` in a string would otherwise be rewritten unpredictably by whatever happened to be in the history. It is also why `echo "hello!"` can misbehave interactively but never in a script, and why `set +H` is a reasonable line in an interactive rc file if you type `!` in strings often.

**A7.6** — `!$` expands to the **last argument of the previous command** (equivalent to `!!:$`). The Readline equivalent is **`Alt-.`** (or `Esc` then `.`), *insert-last-argument*, which inserts the text directly into the editing buffer — pressing it repeatedly walks back through earlier commands' last arguments. It is superior to `!$` because you see the literal text before executing, and it works even when history expansion is disabled.

---

### Exercise 8

**A8.1** — Section **1** is user commands (executable programs and shell commands); section **5** is file formats and conventions; section **8** is system administration commands, normally requiring root. `passwd` appears in both 1 and 5 because they document different objects that share a name: `passwd(1)` is the `/usr/bin/passwd` program that changes a password, and `passwd(5)` is the `/etc/passwd` **file format** — field order, meanings, and its relationship to `/etc/shadow`. `man passwd` shows section 1 because `man` returns the first match in section order; you must say `man 5 passwd` to reach the other. (For completeness: 2 = syscalls, 3 = library functions, 4 = special files/devices, 6 = games, 7 = miscellaneous/conventions.)

**A8.2** — `man -k` / `apropos` do not read the manual pages; they query a **pre-built index database** of page names and their one-line descriptions (`whatis` entries), stored under `/var/cache/man`. On a fresh install, or after installing packages, that database may be absent or stale, so keyword search finds nothing while direct page lookup — which walks `MANPATH` and opens the file — still works. Fix: build the index with `sudo mandb` (Debian/Ubuntu/Fedora) or `sudo makewhatis` on older/BSD-derived systems. Most distributions also refresh it from a systemd timer or cron job, which is why the problem tends to fix itself overnight.

**A8.3** — The three channels are:
1. **`man PAGE`** — the manual page, for external programs and file formats.
2. **`help BUILTIN`** — Bash's built-in documentation, for shell builtins.
3. **`CMD --help`** — the program's own usage text, embedded in the binary.

For `cd`, `export` and `unset`, **`help`** is authoritative, because these are **shell builtins** — they have no executable file of their own, so there is generally nothing for `man` to document (many systems ship no page, and where a `builtins(1)` page exists it merely redirects to `bash(1)`). They must be builtins by necessity: `cd` has to change the *current shell's* working directory, and a child process could never do that; `export` and `unset` likewise manipulate the shell's own variable table. `--help` is the fallback when a package ships no man page at all, and it is the only channel guaranteed to match the installed binary's version.

**A8.4** — They are the same programs. `man -f` is functionally identical to `whatis`: exact-name lookup returning the one-line description from each matching section. `man -k` is identical to `apropos`: substring/regex search across page names *and* descriptions. On modern `man-db` systems, `whatis` and `apropos` are literally the same executable dispatching on `argv[0]`, or thin wrappers around `man`. The exam expects you to recognise both spellings and to know that `-k` searches descriptions while `-f` matches only names.

---

### Exercise 9

**A9.1** — Two independent root causes:
1. **`DATADIR` was never exported.** It was assigned in the interactive shell as a plain shell variable, so it was not in the `envp` passed to the script's Bash, and inside the script `$DATADIR` expanded to the empty string — hence `DATADIR=[]`.
2. **`$DATADIR` was unquoted.** Because the expansion was empty and unquoted, word splitting produced **zero** arguments, so `ls -1` ran with no operand and silently listed the **current working directory** instead of failing. Two separate defects conspired: the missing export supplied the empty value, and the missing quotes converted that empty value into "no argument at all" rather than an error. Had `DATADIR` been exported but unquoted, the same line would instead have split the path on its space and produced two `cannot access` errors — which is exactly what step 3 demonstrated.

**A9.2** — `env PATH=/usr/bin:/bin DATADIR="..." /tmp/lab103/collect` runs the external `env` program. `env` takes the environment it inherited from the shell, applies each `NAME=VALUE` operand as an addition or **override**, and then `execve()`s the named command with that modified environment. So the child received the shell's full environment *except* that `PATH` was replaced by the two-directory value and `DATADIR` was added. `~/bin` was therefore no longer in the search path, `greet` was not found (status 127), while `DATADIR` did reach the script. Note the shell expanded `"..."` before `env` ever ran — `env` sees only the final strings. `env -i` starts from an *empty* environment instead of the inherited one, and `env -u NAME` removes a single variable.

**A9.3** — `bash -x script` enables tracing for a **separate invocation** of the script without editing it, leaving the file untouched — right for diagnosing someone else's script, a one-off failure, or a script you cannot modify. `set -x` inside the script (or in your interactive shell) turns tracing on for a **region**, paired with `set +x` to turn it off — right when only one section is interesting and full output would be unreadable. What the trace proves that `echo` cannot: it shows the command **after all expansions and quote removal**, exactly as it will be executed. `echo "$DATADIR"` shows you a value; `+ ls -1 /tmp/lab103/data files` shows you that the value was split into two arguments. Argument boundaries, empty arguments and glob results are visible only in the trace, and Bash helpfully quotes traced words that contain special characters.

**A9.4** — Yes, `greet` still resolves. The `PATH` search is performed by the **shell that executes the command** — here, the script's own Bash — using its own `PATH` **shell variable**. `export` only matters for passing the value down to *further* child processes. So `PATH="$HOME/bin:$PATH"` inside the script is sufficient for that script's own command lookups; it would be insufficient only if the script launched another program that itself needed `~/bin` in its environment. In practice `PATH` is almost always already exported (inherited that way from login), so a bare assignment updates the existing exported variable and the distinction never surfaces — but understanding it is the difference between guessing and knowing.

**A9.5** — Breaking it down:
- **`:`** is the null builtin. It expands its arguments, sets `$?` to 0, and does nothing else. It is used here purely as a carrier so the parameter expansion is evaluated for its **side effect** without running or printing anything.
- **`${VAR:?message}`** expands to `$VAR` if it is set and non-empty; otherwise Bash writes `VAR: message` to stderr and **exits** a non-interactive shell with a non-zero status (it does not exit an interactive shell, it just aborts the command). This is the fail-fast guard.
- **`${VAR:-default}`** substitutes `default` for this expansion only; `VAR` remains unset.
- **`${VAR:=default}`** substitutes `default` **and assigns** it to `VAR`, so it persists for the rest of the script (this form fails on positional parameters).

The `:` prefix in each form means "treat empty as unset"; omitting it (`${VAR-default}`, `${VAR?msg}`) triggers only when the variable is genuinely unset, letting a deliberately empty value through. Choose `:?` for mandatory inputs, `:-` for optional values with a fallback, `:=` when the fallback should be remembered.

</details>