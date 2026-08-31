# LPIC-1 · Exam 101-500 · Objective 103.5 — Create, monitor and kill processes

**Guided exercises.** Every step is meant to be typed on a live Linux system. Blocks marked `# expected output` are illustrative — your PIDs, times and memory figures will differ, the *shape* of the output should not.

> **Lab requirements:** any systemd-based distribution (Debian 12+, Ubuntu 22.04+, Rocky/Alma 9, openSUSE Leap 15.5+), a normal unprivileged user account, `bash` as the interactive shell, and the `procps`/`procps-ng` package (`ps`, `top`, `free`, `uptime`, `pgrep`, `pkill`, `kill`, `killall`, `watch`). Two exercises additionally need `screen` and `tmux`, and one needs a second terminal or SSH session.
>
> **Safety:** everything below acts on processes you own. Do not run `kill -9 -1`, `pkill -f .` or `killall -9 bash` on a machine you care about — one exercise explains exactly why.

---

## Exercise 0 — Build the lab

### Steps

1. Create an isolated working directory:

   ```bash
   mkdir -p ~/lab-103.5 && cd ~/lab-103.5
   ```

2. Create a long-running worker that prints its own identity, so you can correlate what you see in `ps`, `top` and `jobs`:

   ```bash
   cat > worker.sh <<'EOF'
   #!/bin/bash
   # Heartbeat worker used across objective 103.5 exercises.
   name="${1:-worker}"
   beat=0
   while true; do
       beat=$((beat + 1))
       printf '%s [%s] pid=%d ppid=%d pgid=%d beat=%d\n' \
              "$(date +%T)" "$name" "$$" "$PPID" "$(ps -o pgid= -p $$ | tr -d ' ')" "$beat"
       sleep 2
   done
   EOF
   chmod +x worker.sh
   ```

3. Create a CPU burner used later for sorting and `top`:

   ```bash
   cat > burner.sh <<'EOF'
   #!/bin/bash
   # Busy loop, no syscalls in the hot path: stays in state R.
   while :; do :; done
   EOF
   chmod +x burner.sh
   ```

4. Confirm your shell has **job control** (monitor mode) enabled and see which keystrokes the terminal driver maps to signals:

   ```bash
   echo "$-"
   stty -a | tr ';' '\n' | grep -E 'intr|susp|quit|tostop'
   ```

   ```text
   # expected output
   himBHs
   intr = ^C
   quit = ^\
   susp = ^Z
   -tostop
   ```

   The `m` in `$-` is `set -m`, monitor mode. It is on by default in interactive shells and **off** in non-interactive shells and scripts.

### Check your understanding

- **Q0.1** — `Ctrl-C`, `Ctrl-Z` and `Ctrl-\` are shown by `stty`, not by `bash`. Which component actually turns those keystrokes into signals, and which set of processes receives them?
- **Q0.2** — What practical difference does `set -m` being *off* inside a shell script make for a command you start with `&`?
- **Q0.3** — `worker.sh` reports `$$` and `$PPID`. In a script started as `./worker.sh alpha`, what do those two variables refer to?

---

## Exercise 1 — Foreground, background, and the shell's job table

### Steps

1. Start a worker in the foreground and let it print two or three heartbeats:

   ```bash
   ./worker.sh alpha
   ```

   ```text
   # expected output
   14:02:11 [alpha] pid=4821 ppid=3970 pgid=4821 beat=1
   14:02:13 [alpha] pid=4821 ppid=3970 pgid=4821 beat=2
   ```

2. Press **`Ctrl-Z`**. The shell regains the prompt:

   ```text
   # expected output
   ^Z
   [1]+  Stopped                 ./worker.sh alpha
   ```

3. Resume it **in the background** and start a second worker directly in the background, redirecting its noise to a file:

   ```bash
   bg %1
   ./worker.sh beta > beta.log 2>&1 &
   echo "last background PID: $!"
   ```

   ```text
   # expected output
   [1]+ ./worker.sh alpha &
   [2] 4835
   last background PID: 4835
   ```

4. Inspect the job table three ways:

   ```bash
   jobs
   jobs -l
   jobs -p
   ```

   ```text
   # expected output
   [1]-  Running                 ./worker.sh alpha &
   [2]+  Running                 ./worker.sh beta > beta.log 2>&1 &

   [1]-  4821 Running                 ./worker.sh alpha &
   [2]+  4835 Running                 ./worker.sh beta > beta.log 2>&1 &

   4821
   4835
   ```

   Note the `+` and `-` markers: `+` is the **current job** (`%+` or `%%`), `-` is the **previous job** (`%-`).

5. Bring job 2 to the foreground, then stop it again and leave it stopped:

   ```bash
   fg %2
   # ...press Ctrl-Z...
   jobs -l
   ```

   ```text
   # expected output
   ./worker.sh beta > beta.log 2>&1
   ^Z
   [2]+  Stopped                 ./worker.sh beta > beta.log 2>&1
   [1]-  4821 Running                 ./worker.sh alpha &
   [2]+  4835 Stopped                 ./worker.sh beta > beta.log 2>&1
   ```

6. Prove that a *stopped* job consumes no CPU and executes nothing, while a *background* job keeps running:

   ```bash
   wc -l beta.log
   sleep 6
   wc -l beta.log          # unchanged: job 2 is stopped
   ```

7. Prove the job table is **per-shell** and not inherited:

   ```bash
   bash -c 'jobs; echo "exit=$?"'
   ```

   ```text
   # expected output
   exit=0
   ```

8. Address jobs by name instead of number, and clean up:

   ```bash
   fg %?beta        # select the job whose command line contains "beta"
   # ...Ctrl-Z again...
   kill %1 %2
   sleep 1
   jobs
   ```

   ```text
   # expected output
   [1]-  Terminated              ./worker.sh alpha
   [2]+  Terminated              ./worker.sh beta > beta.log 2>&1
   ```

   `kill %2` on a **stopped** job is a classic production trap — see the questions.

### Check your understanding

- **Q1.1** — `bg %1` and `fg %1` both resume a stopped job. Which signal do they both send, and what does `fg` do in *addition* that `bg` does not?
- **Q1.2** — In step 3, `$!` returned `4835`. Which PID is that exactly — the `bash` interpreting `worker.sh`, or the `sleep 2` it forks?
- **Q1.3** — `jobs` inside `bash -c` printed nothing and exited 0. Explain why that is correct behaviour and not an error.
- **Q1.4** — You send `kill %2` (i.e. `SIGTERM`) to a job in state `Stopped`. Does the process die immediately? What must you do to make it die?
- **Q1.5** — Your shell exits while job 2 is `Stopped`. What does `bash` do, and why is that different from the `Running` case?
- **Q1.6** — `%1`, `%+`, `%-`, `%?beta` and `%beta` are all job specifications. What is the difference between `%beta` and `%?beta`?

---

## Exercise 2 — Reading the process table with `ps`

### Steps

1. Compare the two historical syntaxes. They are *not* aliases:

   ```bash
   ps                # your processes on this terminal
   ps -f             # UNIX/POSIX style, full format
   ps aux | head -3  # BSD style, user-oriented, all processes
   ps -ef | head -3  # UNIX style, all processes, full format
   ```

   ```text
   # expected output (ps -ef)
   UID          PID    PPID  C STIME TTY          TIME CMD
   root           1       0  0 09:14 ?        00:00:03 /sbin/init splash
   root           2       0  0 09:14 ?        00:00:00 [kthreadd]
   ```

2. Observe what happens when you mix them:

   ```bash
   ps -aux | head -2
   ```

   ```text
   # expected output
   Warning: bad syntax, perhaps a bogus '-'? See /usr/share/doc/procps-ng/FAQ
   USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
   ```

3. Build your own output format — this is what you should actually use in production:

   ```bash
   ./worker.sh alpha > /dev/null 2>&1 &
   ./burner.sh &
   sleep 3
   ps -eo pid,ppid,pgid,sid,tty,stat,ni,%cpu,%mem,rss,vsz,wchan:16,comm --sort=-%cpu | head -8
   ```

   ```text
   # expected output
       PID    PPID    PGID     SID TT       STAT  NI %CPU %MEM   RSS    VSZ WCHAN            COMMAND
      5104    3970    5104    3970 pts/1    R     0 99.4  0.0  3456   8120 -                burner.sh
      1183    1102    1183    1183 ?        Ssl   0  2.1  4.3 348912 2914772 ep_poll        gnome-shell
      5088    3970    5088    3970 pts/1    S     0  0.3  0.0  3612   8248 do_wait          worker.sh
      5121    5088    5088    3970 pts/1    S     0  0.0  0.0  2176   8100 hrtimer_nanosle  sleep
   ```

4. Decode the `STAT` column against a live tree and against `proc(5)`:

   ```bash
   ps -eo stat= | sort | uniq -c | sort -rn
   grep -E '^(Name|State|Threads|VmRSS|Voluntary)' /proc/$(pgrep -n -x worker.sh)/status
   ```

   ```text
   # expected output
       231 S
        14 I
         6 Ss
         3 Ssl
         1 R+
   Name:	worker.sh
   State:	S (sleeping)
   Threads:	1
   VmRSS:	    3612 kB
   ```

5. Look at the process hierarchy as a tree, three different ways:

   ```bash
   ps axjf | head -12
   ps -e --forest -o pid,ppid,comm | grep -A3 -w systemd | head
   pstree -p "$USER" | head
   ```

6. Distinguish `comm` from `args` — this distinction decides whether your `pgrep` pattern works:

   ```bash
   ps -eo pid,comm,args -p "$(pgrep -n -x worker.sh)"
   cat /proc/$(pgrep -n -x worker.sh)/comm
   tr '\0' ' ' < /proc/$(pgrep -n -x worker.sh)/cmdline; echo
   ```

   ```text
   # expected output
       PID COMMAND         COMMAND
      5088 worker.sh       /bin/bash ./worker.sh alpha
   worker.sh
   /bin/bash ./worker.sh alpha
   ```

7. Compare `ps`'s `%CPU` with `top`'s. Leave `burner.sh` running, then:

   ```bash
   ps -o pid,etimes,times,%cpu -p "$(pgrep -n -x burner.sh)"
   sleep 20
   ps -o pid,etimes,times,%cpu -p "$(pgrep -n -x burner.sh)"
   ```

8. Clean up:

   ```bash
   pkill -x burner.sh
   pkill -x worker.sh
   ```

### Check your understanding

- **Q2.1** — Why does `ps -aux` emit a warning while `ps aux` does not? What does POSIX say `-aux` should mean?
- **Q2.2** — In step 3, `worker.sh` was in state `S` with `WCHAN` `do_wait`, and a child `sleep` was in `S` with `hrtimer_nanosleep`. Explain what each process is blocked on.
- **Q2.3** — A process shows `STAT` as `D`. What is it doing, and what happens if you send it `SIGKILL`?
- **Q2.4** — Decode `Ssl` and `R+` completely, letter by letter.
- **Q2.5** — `RSS` for `gnome-shell` is 348 MB and `VSZ` is 2.9 GB. Which number is closer to "RAM this process is costing me", and why is even that one misleading when you sum it across processes?
- **Q2.6** — `ps` reported `%CPU` 99.4 for the burner. Is that an instantaneous measurement? Derive the formula from the `etimes` and `times` columns of step 7.
- **Q2.7** — The `COMMAND` column appeared twice in step 6 with different values. Which one comes from `/proc/PID/comm`, what is its hard length limit, and which one can a process change at runtime?

---

## Exercise 3 — Parents, children, orphans and zombies

### Steps

1. Watch a parent/child pair and the process group they share:

   ```bash
   ./worker.sh tree > /dev/null 2>&1 &
   sleep 1
   ps -eo pid,ppid,pgid,sid,stat,comm --forest | grep -E 'bash|worker|sleep' | head
   ```

2. Create an **orphan**: kill the parent, keep the child.

   ```bash
   bash -c './worker.sh orphan > ~/lab-103.5/orphan.log 2>&1 &  sleep 60' &
   MIDDLE=$!
   sleep 2
   ps -o pid,ppid,comm -p "$(pgrep -n -x worker.sh)"
   kill "$MIDDLE"
   sleep 2
   ps -o pid,ppid,comm -p "$(pgrep -n -x worker.sh)"
   ```

   ```text
   # expected output
       PID    PPID COMMAND
      5310    5301 worker.sh
       PID    PPID COMMAND
      5310    2140 worker.sh
   ```

3. Find out *what* adopted it — the answer is frequently not PID 1:

   ```bash
   ps -o pid,comm -p 2140
   ps -o pid,comm -p 1
   ```

   ```text
   # expected output
       PID COMMAND
      2140 systemd          <- systemd --user, a child subreaper
       PID COMMAND
         1 systemd
   ```

4. Verify the reparenting rule directly from the kernel-exported view:

   ```bash
   grep -E '^(Name|PPid|NSpid)' /proc/$(pgrep -n -x worker.sh)/status
   pkill -x worker.sh
   ```

5. Create a **zombie** on purpose. The child exits, the parent `exec`s into a program that never calls `wait()`:

   ```bash
   bash -c '/bin/true & exec sleep 120' &
   sleep 2
   ps -eo pid,ppid,stat,comm,args | awk 'NR==1 || $3 ~ /^Z/'
   ```

   ```text
   # expected output
       PID    PPID STAT COMMAND         COMMAND
      5402    5401 Z    true            [true] <defunct>
   ```

6. Try to kill the zombie, then kill it the only way that works:

   ```bash
   kill -9 5402                          # substitute the zombie PID
   sleep 1
   ps -o pid,stat,comm -p 5402           # still there
   kill 5401                             # substitute the PARENT PID (the sleep)
   sleep 1
   ps -o pid,stat,comm -p 5402           # gone
   ```

7. Count zombies system-wide the way a monitoring check would:

   ```bash
   ps -eo stat= | grep -c '^Z'
   awk '/^procs_blocked|^procs_running/' /proc/stat
   ```

### Check your understanding

- **Q3.1** — After the intermediate shell died, the worker's `PPid` changed. Which system call performs that change, and at what moment?
- **Q3.2** — Why was the new parent `systemd --user` (PID 2140) rather than PID 1? Name the mechanism.
- **Q3.3** — What resource does a zombie actually hold? Why is `kill -9` powerless against it?
- **Q3.4** — Your monitoring reports 4 000 zombies with the same PPID. What is the defect, and which process do you restart?
- **Q3.5** — Explain why `bash -c '/bin/true & exec sleep 120'` produces a zombie but `bash -c '/bin/true & sleep 120'` usually does not.

---

## Exercise 4 — Signals: sending, catching, and what cannot be caught

### Steps

1. List the signals your kernel and shell know about:

   ```bash
   kill -l
   kill -l TERM KILL HUP INT CONT STOP TSTP
   ```

   ```text
   # expected output
   ...
   15
   9
   1
   2
   18
   19
   20
   ```

2. Write a program that installs handlers, so you can *see* delivery:

   ```bash
   cat > trapper.sh <<'EOF'
   #!/bin/bash
   cleanup() { echo "$(date +%T) SIGTERM: releasing lock"; rm -f "$LOCK"; exit 143; }
   reload()  { echo "$(date +%T) SIGHUP: re-reading configuration"; }
   nope()    { echo "$(date +%T) SIGINT: ignored, send SIGTERM to stop me"; }

   LOCK="/tmp/trapper.$$.lock"
   trap cleanup TERM
   trap reload  HUP
   trap nope    INT
   : > "$LOCK"
   echo "pid=$$ lock=$LOCK ready"
   while :; do sleep 1; done
   EOF
   chmod +x trapper.sh
   ./trapper.sh &
   TRAP=$!
   ```

3. Send the three catchable signals, by name, by number and by job spec:

   ```bash
   kill -HUP  "$TRAP"
   kill -1    "$TRAP"
   kill -s INT "$TRAP"
   kill -INT %+
   ```

   ```text
   # expected output
   14:31:02 SIGHUP: re-reading configuration
   14:31:02 SIGHUP: re-reading configuration
   14:31:03 SIGINT: ignored, send SIGTERM to stop me
   14:31:03 SIGINT: ignored, send SIGTERM to stop me
   ```

   Notice the handler output can lag up to one second behind the `kill`.

4. Terminate it politely and read the exit status:

   ```bash
   kill -TERM "$TRAP"
   wait "$TRAP"; echo "exit status: $?"
   ls -l /tmp/trapper.$TRAP.lock 2>&1
   ```

   ```text
   # expected output
   14:31:20 SIGTERM: releasing lock
   exit status: 143
   ls: cannot access '/tmp/trapper.5511.lock': No such file or directory
   ```

5. Now prove that `SIGKILL` and `SIGSTOP` cannot be intercepted:

   ```bash
   ./trapper.sh &
   TRAP=$!
   kill -STOP "$TRAP"; sleep 1; ps -o pid,stat,comm -p "$TRAP"
   kill -CONT "$TRAP"; sleep 1; ps -o pid,stat,comm -p "$TRAP"
   kill -KILL "$TRAP"
   wait "$TRAP"; echo "exit status: $?"
   ls -l /tmp/trapper.$TRAP.lock
   ```

   ```text
   # expected output
       PID STAT COMMAND
      5540 T    trapper.sh
       PID STAT COMMAND
      5540 S    trapper.sh
   exit status: 137
   -rw-r--r-- 1 you you 0 Aug 26 14:33 /tmp/trapper.5540.lock
   ```

   The lock file survived. That is the whole argument against reaching for `-9` first.

6. Inspect a process's signal disposition masks — the production way to answer "will this daemon honour `SIGHUP`?":

   ```bash
   ./trapper.sh & TRAP=$!
   grep -E '^Sig(Blk|Ign|Cgt)' /proc/$TRAP/status
   ```

   ```text
   # expected output
   SigBlk:	0000000000000000
   SigIgn:	0000000000000000
   SigCgt:	0000000000004003
   ```

   `0x4003` = bits 0, 1, 14 → signals 1 (`HUP`), 2 (`INT`), 15 (`TERM`).

7. Signal a whole **process group** with a negative PID, then verify:

   ```bash
   setsid ./worker.sh grp > /dev/null 2>&1 &
   sleep 1
   PG=$(ps -o pgid= -p "$(pgrep -n -x worker.sh)" | tr -d ' ')
   ps -eo pid,pgid,comm | awk -v g="$PG" '$2==g'
   kill -TERM -"$PG"
   sleep 1
   ps -eo pid,pgid,comm | awk -v g="$PG" '$2==g'
   ```

8. Read — do **not** run — the two dangerous forms, then use `/bin/kill` explicitly to see it is a distinct program:

   ```bash
   type -a kill
   /bin/kill --list | head -5
   /bin/kill %1 2>&1 || echo "external kill does not understand job specs"
   ```

   ```text
   # expected output
   kill is a shell builtin
   kill is /usr/bin/kill
   ...
   /bin/kill: failed to parse argument: '%1'
   external kill does not understand job specs
   ```

9. Clean up:

   ```bash
   pkill -x trapper.sh; pkill -x worker.sh; rm -f /tmp/trapper.*.lock
   ```

### Check your understanding

- **Q4.1** — In step 3 the handler output arrived up to a second late even though the signal was delivered immediately. Explain the delay in terms of how `bash` runs traps.
- **Q4.2** — Exit statuses `143` and `137` appeared. Derive both from a single rule, and state where that rule is defined.
- **Q4.3** — Which two signals can never be caught, blocked or ignored, and what architectural guarantee does that provide to the operator?
- **Q4.4** — `SigCgt` was `0000000000004003`. Show the arithmetic that maps that hex mask to signals 1, 2 and 15.
- **Q4.5** — `kill -TERM -1234` and `kill -TERM 1234` differ by one character. What does each do? And what does `kill -TERM 0` do?
- **Q4.6** — `kill -9 -1` is listed in every "never type this" article. Exactly which processes would it signal, and would `root` running it fare better or worse than a normal user?
- **Q4.7** — `kill` exists as both a shell builtin and `/bin/kill`. Give one capability each has that the other lacks.
- **Q4.8** — Signal numbers 1, 2, 9 and 15 are identical on every Linux architecture, but `SIGSTOP` is 19 on x86-64 and 23 on MIPS. What operational rule follows from this?

---

## Exercise 5 — Surviving logout: `nohup`, `disown`, `setsid`

### Steps

1. Start a job with `nohup` and read the message it prints:

   ```bash
   cd ~/lab-103.5
   nohup ./worker.sh nh &
   sleep 1
   ls -l nohup.out
   ```

   ```text
   # expected output
   nohup: ignoring input and appending output to 'nohup.out'
   -rw-r--r-- 1 you you 132 Aug 26 14:40 nohup.out
   ```

2. Verify what `nohup` actually changed — not "detached", just one ignored signal:

   ```bash
   NH=$(pgrep -n -x worker.sh)
   grep SigIgn /proc/$NH/status
   ps -o pid,ppid,pgid,sid,tty,comm -p "$NH"
   ```

   ```text
   # expected output
   SigIgn:	0000000000000001
       PID    PPID    PGID     SID TT       COMMAND
      5711    3970    5711    3970 pts/1    worker.sh
   ```

   `SigIgn` bit 0 → `SIGHUP` ignored. But `TT` is still `pts/1`, and `SID` is still the shell's session.

3. Compare with `disown`, which changes the *shell's* bookkeeping rather than the process:

   ```bash
   ./worker.sh dis > dis.log 2>&1 &
   DIS=$!
   jobs -l
   disown -h %+          # keep in job table, but do not send SIGHUP on shell exit
   jobs -l
   disown %+             # remove from job table entirely
   jobs -l
   grep SigIgn /proc/$DIS/status
   ```

   ```text
   # expected output
   [2]+  5730 Running                 ./worker.sh dis > dis.log 2>&1 &
   [2]+  5730 Running                 ./worker.sh dis > dis.log 2>&1 &
   SigIgn:	0000000000000000
   ```

   After the second `disown`, `jobs -l` prints nothing — and note the signal mask never changed.

4. Compare with `setsid`, the only one of the three that truly detaches:

   ```bash
   setsid ./worker.sh sid > sid.log 2>&1 < /dev/null
   sleep 1
   SID=$(pgrep -n -x worker.sh)
   ps -o pid,ppid,pgid,sid,tty,comm -p "$SID"
   grep SigIgn /proc/$SID/status
   ```

   ```text
   # expected output
       PID    PPID    PGID     SID TT       COMMAND
      5748       1    5748    5748 ?        worker.sh
   SigIgn:	0000000000000000
   ```

   New session, new process group, **no controlling terminal** (`TT` is `?`), parent is PID 1.

5. Now simulate a hangup instead of guessing. Open a **second terminal**, then in the first one:

   ```bash
   bash            # nested interactive shell; note its PID
   echo "nested shell pid: $$"
   cd ~/lab-103.5
   ./worker.sh plain    > plain.log    2>&1 &
   nohup ./worker.sh nohupped > nohupped.log 2>&1 &
   ./worker.sh disowned > disowned.log 2>&1 & disown -h %+
   setsid ./worker.sh setsid_ > setsid_.log 2>&1 < /dev/null
   pgrep -a -x worker.sh
   ```

6. From the **second terminal**, hang up the nested shell exactly the way a dropped SSH connection would:

   ```bash
   kill -HUP <nested-shell-pid>
   sleep 3
   pgrep -a -x worker.sh
   ```

   ```text
   # expected output
   5811 /bin/bash ./worker.sh nohupped
   5814 /bin/bash ./worker.sh disowned
   5818 /bin/bash ./worker.sh setsid_
   ```

   `plain` is gone; the other three survived, for three different reasons.

7. Examine the shell option that governs the *clean logout* case, which is not the same as the hangup case:

   ```bash
   shopt huponexit
   ```

   ```text
   # expected output
   huponexit      	off
   ```

8. Clean up:

   ```bash
   pkill -x worker.sh
   rm -f nohup.out *.log
   ```

### Check your understanding

- **Q5.1** — State precisely what `nohup` does. Does it put the command in the background?
- **Q5.2** — Where does `nohup` send stdout, and under what condition? What does it do with stderr?
- **Q5.3** — `disown -h %1` and `disown %1` had identical effects on `/proc/PID/status`. So what *is* the difference between them, and what do they both change?
- **Q5.4** — `disown` cannot protect a job from one specific source of `SIGHUP` that `nohup` can. Which one, and why?
- **Q5.5** — After `setsid`, `TT` was `?`. Which two things did `setsid` sever, and why does that make the process immune to terminal-generated signals in general, not just `SIGHUP`?
- **Q5.6** — `huponexit` is `off` by default. So when *does* `bash` send `SIGHUP` to its jobs, and how does that reconcile with `plain` dying in step 6?
- **Q5.7** — You must launch an 8-hour data migration over SSH and be able to *watch its progress tomorrow*. Rank `nohup`, `disown`, `setsid` and `tmux` for this task and justify the winner.

---

## Exercise 6 — Selecting processes: `pgrep`, `pkill`, `killall`

### Steps

1. Create a deliberately long-named script — longer than 15 characters:

   ```bash
   cd ~/lab-103.5
   cp worker.sh collect-metrics-daemon.sh
   cp worker.sh collect-metrics-shipper.sh
   ./collect-metrics-daemon.sh  d1 > /dev/null 2>&1 &
   ./collect-metrics-shipper.sh s1 > /dev/null 2>&1 &
   sleep 1
   ```

2. Observe the kernel's 15-character truncation of `comm`:

   ```bash
   ps -eo pid,comm,args | grep -E 'collect-metrics' | grep -v grep
   ```

   ```text
   # expected output
      5901 collect-metrics /bin/bash ./collect-metrics-daemon.sh d1
      5903 collect-metrics /bin/bash ./collect-metrics-shipper.sh s1
   ```

   Two distinct programs, one indistinguishable `comm`.

3. Watch `pgrep` fail and then succeed:

   ```bash
   pgrep collect-metrics-daemon.sh    ; echo "rc=$?"
   pgrep collect-metrics              ; echo "rc=$?"
   pgrep -f collect-metrics-daemon.sh ; echo "rc=$?"
   pgrep -a -f collect-metrics
   ```

   ```text
   # expected output
   rc=1
   5901
   5903
   rc=0
   5901
   rc=0
   5901 /bin/bash ./collect-metrics-daemon.sh d1
   5903 /bin/bash ./collect-metrics-shipper.sh s1
   ```

4. Exercise the selection options that make `pgrep`/`pkill` safe:

   ```bash
   pgrep -c -u "$USER" -f collect-metrics     # count only
   pgrep -n -f collect-metrics                # newest
   pgrep -o -f collect-metrics                # oldest
   pgrep -x bash                              # exact comm match
   pgrep -P "$$" -a                           # children of this shell
   pgrep -u root -x sshd
   ```

5. Do the dry run before the kill — **always**:

   ```bash
   pgrep -a -f 'collect-metrics-daemon\.sh'      # 1. look
   pkill -f 'collect-metrics-daemon\.sh'         # 2. then act
   sleep 1
   pgrep -a -f collect-metrics
   ```

   ```text
   # expected output
   5901 /bin/bash ./collect-metrics-daemon.sh d1
   5903 /bin/bash ./collect-metrics-shipper.sh s1
   ```

6. Now reproduce the `killall` truncation hazard on the survivor:

   ```bash
   ./collect-metrics-daemon.sh d2 > /dev/null 2>&1 &
   sleep 1
   pgrep -a -f collect-metrics
   killall collect-metrics-daemon.sh
   sleep 1
   pgrep -a -f collect-metrics    ; echo "rc=$?"
   ```

   ```text
   # expected output
   5903 /bin/bash ./collect-metrics-shipper.sh s1
   5940 /bin/bash ./collect-metrics-daemon.sh d2
   rc=1
   ```

   Both died. You asked for `...daemon.sh` and `killall` also took `...shipper.sh`.

7. Repeat with the flag that prevents it:

   ```bash
   ./collect-metrics-daemon.sh  d3 > /dev/null 2>&1 &
   ./collect-metrics-shipper.sh s3 > /dev/null 2>&1 &
   sleep 1
   killall -e collect-metrics-daemon.sh ; echo "rc=$?"
   killall -r 'collect-metrics-daemon' ; echo "rc=$?"
   sleep 1
   pgrep -a -f collect-metrics
   ```

8. Send a specific signal, not just `SIGTERM`, and observe the `pkill` self-match rule:

   ```bash
   pkill -HUP -x sshd -u root 2>/dev/null; echo "rc=$? (1 = no match, normal as non-root)"
   pgrep -f pgrep                    ; echo "rc=$? (pgrep never matches itself)"
   ```

9. Clean up:

   ```bash
   pkill -f collect-metrics
   rm -f collect-metrics-*.sh
   ```

### Check your understanding

- **Q6.1** — Why is `comm` limited to 15 characters? Name the kernel constant and its value.
- **Q6.2** — `pgrep collect-metrics-daemon.sh` returned nothing with `rc=1`, yet the process existed. Which field does `pgrep` match by default, and which option changes that?
- **Q6.3** — In step 3, the bare `pgrep collect-metrics` matched **both** scripts. Was that a substring match or an exact match? Which option would have forced an exact match, and would it have helped here?
- **Q6.4** — Explain, in `procps-ng` terms, why `killall collect-metrics-daemon.sh` killed the shipper too, and what `-e` changes.
- **Q6.5** — On a Solaris host, `killall` run as root does something categorically different from Linux. What, and what discipline does that impose on portable scripts?
- **Q6.6** — `pgrep` and `pkill` never match themselves. Give a realistic scenario where `pkill -f backup` nonetheless kills the very script that ran it.
- **Q6.7** — Write the single safest command that sends `SIGHUP` to exactly the `nginx` master process owned by `root`, and explain each option.

---

## Exercise 7 — Live monitoring: `top`, `uptime`, `free`

### Steps

1. Establish a baseline, then create load:

   ```bash
   uptime
   nproc
   for i in 1 2 3; do ~/lab-103.5/burner.sh & done
   ```

   ```text
   # expected output
    14:58:03 up  5:43,  2 users,  load average: 0.31, 0.24, 0.19
   8
   ```

2. Start `top` and work through its interactive keys. Press each and observe:

   ```bash
   top
   ```

   | Key | Effect |
   |---|---|
   | `h` | help screen |
   | `1` | expand the CPU line into one row per logical CPU |
   | `P` | sort by `%CPU` (default) |
   | `M` | sort by `%MEM` |
   | `T` | sort by cumulative `TIME+` |
   | `R` | reverse the current sort order |
   | `u` | filter by user (enter your username) |
   | `c` | toggle `COMMAND` between `comm` and the full command line |
   | `V` | forest/tree view |
   | `H` | show individual threads instead of processes |
   | `I` | toggle Irix mode (per-CPU vs. per-machine `%CPU` scaling) |
   | `d` | change refresh delay (try `5`) |
   | `f` | field-management screen: add `PPID`, `nTH`, `S` |
   | `k` | kill: prompts for PID, then for the signal |
   | `W` | write the current layout to `~/.config/procps/toprc` |
   | `q` | quit |

3. Read the summary area carefully while the burners run:

   ```text
   # expected output
   top - 14:59:41 up  5:45,  2 users,  load average: 2.71, 1.06, 0.48
   Tasks: 312 total,   4 running, 308 sleeping,   0 stopped,   0 zombie
   %Cpu(s): 37.6 us,  0.4 sy,  0.0 ni, 61.9 id,  0.0 wa,  0.1 hi,  0.0 si,  0.0 st
   MiB Mem :  15884.0 total,   6301.4 free,   3211.8 used,   6370.8 buff/cache
   MiB Swap:   8192.0 total,   8192.0 free,      0.0 used.  11702.3 avail Mem

       PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
      6011 you       20   0    8120   3456   3072 R  99.7   0.0   1:24.11 burner.sh
      6012 you       20   0    8120   3452   3072 R  99.7   0.0   1:24.09 burner.sh
      6013 you       20   0    8120   3456   3072 R  99.3   0.0   1:24.02 burner.sh
   ```

4. Quit `top` and use the batch mode you would actually put in a script or a ticket:

   ```bash
   top -b -n 1 -o %CPU | head -12
   top -b -n 2 -d 1 -p "$(pgrep -d, -x burner.sh)" | tail -8
   ```

5. Correlate the load average with its kernel source:

   ```bash
   cat /proc/loadavg
   ```

   ```text
   # expected output
   2.71 1.06 0.48 4/1247 6103
   ```

6. Read memory the right way:

   ```bash
   free -h
   free -h -w
   free -m -s 2 -c 3
   grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree)' /proc/meminfo
   ```

   ```text
   # expected output
                  total        used        free      shared  buff/cache   available
   Mem:            15Gi       3.1Gi       6.1Gi       412Mi       6.2Gi        11Gi
   Swap:          8.0Gi          0B       8.0Gi
   ```

7. Stop the load and confirm the load average decays rather than dropping:

   ```bash
   pkill -x burner.sh
   uptime; sleep 60; uptime
   ```

### Check your understanding

- **Q7.1** — Load average reached 2.71 on an 8-CPU machine. Is the machine overloaded? State the rule that relates load average to `nproc`.
- **Q7.2** — Linux load average counts something that classical UNIX load average does not. What, and why does that make a high load on an I/O-bound host mean something different?
- **Q7.3** — In `/proc/loadavg`, the field `4/1247` and the trailing `6103` — what are they?
- **Q7.4** — In step 7 the burners were killed but `uptime` still showed ~2.0 immediately after. Why is that not a bug?
- **Q7.5** — `%Cpu(s)` showed `61.9 id` and `0.0 wa`. Define `us`, `sy`, `ni`, `id`, `wa`, `hi`, `si`, `st` — and say which one would be non-zero on a busy VM whose hypervisor is oversubscribed.
- **Q7.6** — `free -h` shows `free` 6.1 Gi but `available` 11 Gi. Explain the difference, and say which figure a capacity alert must use.
- **Q7.7** — A multithreaded process shows `%CPU` of `340.0` in `top`. Is that a bug? Which `top` key changes that number's scale, and what does the other scale display instead?
- **Q7.8** — Both `top` and `ps` print a `%CPU` column and they routinely disagree for the same PID. Explain the measurement difference (this repeats Q2.6 deliberately — it is the most misread column on the exam and in practice).
- **Q7.9** — Name two things `top`'s `k` key can do that `kill <pid>` alone cannot, and one risk of using it.

---

## Exercise 8 — Repeated observation with `watch`

### Steps

1. Watch a changing value with change highlighting:

   ```bash
   ~/lab-103.5/worker.sh w1 > ~/lab-103.5/w1.log 2>&1 &
   watch -n 1 -d 'tail -3 ~/lab-103.5/w1.log; echo; free -m | head -2'
   ```

   Press `Ctrl-C` to exit.

2. Compare quoting behaviours — this is where most `watch` one-liners break:

   ```bash
   watch -n 2 ps -eo pid,stat,comm --sort=-%cpu          # WRONG: shell eats --sort? no; watch eats -n? no — see Q8.2
   watch -n 2 'ps -eo pid,stat,comm --sort=-%cpu | head'
   watch -n 2 -x ps -eo pid,stat,comm --sort=-%cpu
   ```

3. Use the exit-on-change mode as a cheap wait condition:

   ```bash
   watch -g -n 1 'pgrep -c -x worker.sh'; echo "count changed, rc=$?"
   # in another terminal: pkill -x worker.sh
   ```

4. Strip the header and set precise timing:

   ```bash
   watch -t -n 0.5 'date +%T.%N; cat /proc/loadavg'
   watch -n 5 -b 'systemctl --user is-active dbus'; echo "rc=$?"
   ```

5. Understand what `watch` is *not*:

   ```bash
   watch -n 1 'echo $$'      # what does this print, and does it change?
   ```

### Check your understanding

- **Q8.1** — What is `watch`'s default interval, and what does `-d` add?
- **Q8.2** — In step 2, why does the *unquoted* form still work for `ps` but break the moment you add `| head`? Which option runs the command without a shell, and what do you lose by using it?
- **Q8.3** — `watch -g` and `watch -e` both exit early. On what condition does each exit?
- **Q8.4** — `watch -n 1 'top'` is a bad idea. Give two independent reasons.
- **Q8.5** — Is `watch` a monitoring tool in the sense that `top` is? State the fundamental difference in what each measures.

---

## Exercise 9 — Persistent sessions: `screen` and `tmux`

### Steps

1. With `screen`, create a named session, run work, detach and reattach:

   ```bash
   screen -S migration
   # inside: run the long job
   ~/lab-103.5/worker.sh scr
   # detach:  Ctrl-a  then  d
   ```

   ```bash
   screen -ls
   ```

   ```text
   # expected output
   There is a screen on:
           6211.migration  (26/08/26 15:20:04)     (Detached)
   1 Socket in /run/screen/S-you.
   ```

2. Inspect what `screen` did to the process tree:

   ```bash
   ps -eo pid,ppid,pgid,sid,tty,comm | grep -E 'screen|worker' | grep -v grep
   ```

   ```text
   # expected output
      6211       1    6211    6211 ?        screen
      6212    6211    6212    6212 pts/3    bash
      6240    6212    6240    6212 pts/3    worker.sh
   ```

3. Reattach, and learn the flag you need when the session is wrongly marked attached:

   ```bash
   screen -r migration
   # Ctrl-a d again
   screen -d -r migration     # detach it elsewhere, then attach here
   screen -x migration        # multi-attach: both terminals see the same screen
   ```

4. Repeat with `tmux`:

   ```bash
   tmux new -s migration
   # inside: ~/lab-103.5/worker.sh tmx
   # detach:  Ctrl-b  then  d
   tmux ls
   tmux attach -t migration
   tmux kill-session -t migration
   ```

   ```text
   # expected output
   migration: 1 windows (created Tue Aug 26 15:24:11 2026) [190x48]
   ```

5. Prove the survival property against the same hangup you used in Exercise 5. From a second terminal:

   ```bash
   pgrep -a -x worker.sh
   kill -HUP $(pgrep -n -x bash)   # hang up an interactive shell (NOT the screen/tmux server)
   sleep 2
   pgrep -a -x worker.sh           # the screen/tmux job is still there
   ```

6. Clean up:

   ```bash
   screen -S migration -X quit
   tmux kill-server 2>/dev/null
   pkill -x worker.sh
   rm -rf ~/lab-103.5
   ```

### Check your understanding

- **Q9.1** — In step 2, the `screen` process has `PPID 1`, `TTY ?`, and its own `SID`. Which command from Exercise 5 does that resemble, and what does `screen` add on top of it?
- **Q9.2** — Your job inside `screen` has `TTY pts/3`. If your SSH connection drops, `pts/3` does not disappear. Why not?
- **Q9.3** — `screen -r` vs `screen -d -r` vs `screen -x`: give the one-sentence use case for each.
- **Q9.4** — Name one concrete advantage `tmux` has over `screen`, and one situation in which `screen` is still the pragmatic choice.
- **Q9.5** — You are on a remote host that has neither `screen` nor `tmux` and no package access. Give the closest substitute for a 6-hour job you must be able to check on later, and state precisely what you give up.

---

## Exercise 10 — Diagnostic scenario: the runaway process

> A monitoring alert fires: `load average: 47.2` on an 8-CPU application server. Users report the web UI hangs. You have SSH and `sudo`. Work through this as a runbook.

### Steps

1. Confirm the alert and classify the load in one shot:

   ```bash
   uptime; nproc; cat /proc/loadavg
   ps -eo stat= | sort | uniq -c | sort -rn | head -5
   ```

2. Decide whether it is CPU pressure or I/O pressure before touching anything:

   ```bash
   top -b -n 2 -d 1 | awk '/^%Cpu/{print}' 
   ps -eo pid,stat,wchan:24,comm | awk '$2 ~ /D/'
   ```

3. If CPU: identify the top consumers by *instantaneous* usage, not lifetime average:

   ```bash
   top -b -n 2 -d 1 -o %CPU | tail -20
   ```

4. Establish provenance before killing anything — who started it, from where, since when:

   ```bash
   PID=<offender>
   ps -o pid,ppid,user,lstart,etimes,pgid,sid,tty,stat,%cpu,rss,args -p "$PID"
   ps -o pid,user,args -p "$(ps -o ppid= -p "$PID" | tr -d ' ')"
   ls -l /proc/$PID/exe /proc/$PID/cwd
   pgrep -c -P "$PID"
   ```

5. Try to make it stop *gracefully*, and give it time:

   ```bash
   sudo kill -TERM "$PID"
   sleep 10
   ps -o pid,stat,comm -p "$PID" || echo "gone"
   ```

6. If it ignores `SIGTERM`, check whether it is even *able* to respond:

   ```bash
   grep -E '^(State|SigBlk|SigIgn|SigCgt)' /proc/$PID/status
   ```

7. Escalate only after that, and to the process **group** if it spawned children:

   ```bash
   PG=$(ps -o pgid= -p "$PID" | tr -d ' ')
   ps -eo pid,pgid,comm | awk -v g="$PG" '$2==g'
   sudo kill -TERM -"$PG"
   sleep 10
   sudo kill -KILL -"$PG"
   ```

8. Verify recovery and leave evidence in the ticket:

   ```bash
   sleep 60; uptime
   ps -eo stat= | grep -c '^Z'
   ```

### Check your understanding

- **Q10.1** — Load 47 on 8 CPUs, but `%Cpu(s)` shows `2.1 us, 1.0 sy, 94.0 wa`. What is the actual problem, and why would killing the top `%CPU` process be the wrong move?
- **Q10.2** — In step 4, why does `lstart`/`etimes` matter more than `TIME+` for the incident write-up?
- **Q10.3** — Step 6 finds `State: D (disk sleep)` and `SigCgt: 0000000000000000`. Predict the result of `kill -9` and explain it.
- **Q10.4** — Step 7 signals the negative PGID rather than the PID. What failure mode does that prevent?
- **Q10.5** — The offender turns out to be a `systemd` service. Why is `systemctl stop` preferable to `kill` here, even though both send `SIGTERM`?
- **Q10.6** — Write the shortest correct escalation ladder for an unresponsive process, from least to most destructive, with the wait you should allow at each rung.

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every block</summary>

### Exercise 0

**A0.1** — The **terminal line discipline** in the kernel (the `N_TTY` driver), not `bash`. When the driver reads a character matching the configured `intr`, `susp` or `quit` setting, it generates the corresponding signal (`SIGINT`, `SIGTSTP`, `SIGQUIT`) and delivers it to **every process in the foreground process group of the controlling terminal**. That is why `Ctrl-C` on a shell pipeline kills the whole pipeline: all its members share one process group. `bash` merely arranges, via `tcsetpgrp()`, *which* group is in the foreground.

**A0.2** — With monitor mode off, `bash` does not create a separate process group per job. A command started with `&` inside a script stays in the script's process group and keeps the same controlling terminal, so a `Ctrl-C` at the terminal hits it too. There is also no `jobs`/`fg`/`bg` notification machinery, and `%1`-style job specs are unavailable. This is why background jobs launched from cron/systemd scripts behave differently from the same line typed interactively.

**A0.3** — `$$` is the PID of the `bash` process *interpreting the script* (the process the kernel created for `./worker.sh`), and `$PPID` is the interactive shell that forked it. `$$` is deliberately **not** updated in subshells, which is why `(echo $$)` prints the parent's PID — use `$BASHPID` when you need the real current PID.

### Exercise 1

**A1.1** — Both send **`SIGCONT`**. `fg` additionally calls `tcsetpgrp()` to make the job's process group the *foreground* process group of the controlling terminal, so the job can read from the terminal and receives terminal-generated signals; the shell then `wait`s for it. `bg` leaves the shell in the foreground and returns the prompt immediately.

**A1.2** — `$!` is the PID of the **`bash` process running `worker.sh`** — the direct child of your interactive shell, i.e. the job's process-group leader. The `sleep 2` is a grandchild with its own PID; `$!` never refers to it.

**A1.3** — The job table is a data structure private to each shell instance, maintained in that shell's memory and **not inherited across `fork`/`exec`**. `bash -c` is a brand-new shell with no jobs of its own, so it correctly reports an empty list, which is not an error condition — hence exit 0. Corollary for scripts: you cannot `fg` a job started by a different shell; use PIDs.

**A1.4** — No. A stopped process is not scheduled, so it never reaches a point where a pending signal can be delivered and acted on. `SIGTERM` sits pending. You must resume it first: `kill -CONT %2` (or `bg %2` / `fg %2`), after which the pending `SIGTERM` is delivered and the process dies. The idiomatic one-liner is `kill -TERM %2; kill -CONT %2`. `SIGKILL` is the exception — the kernel destroys a stopped task without needing to schedule it.

**A1.5** — `bash` warns `There are stopped jobs.` and **refuses to exit** on the first attempt; a second `exit` proceeds. The protection exists because a stopped job would otherwise be left suspended forever with no terminal to resume it from — unlike a `Running` background job, which at least keeps making progress.

**A1.6** — `%beta` (equivalently `%beta*`) matches a job whose command line **begins with** `beta`. `%?beta` matches a job whose command line **contains** `beta` anywhere. In the exercise the command line is `./worker.sh beta`, which starts with `.`, so only `%?beta` matches.

### Exercise 2

**A2.1** — `ps` accepts three mutually incompatible option styles: BSD (no dash), UNIX/POSIX (single dash), and GNU (double dash). POSIX/UNIX semantics require `ps -aux` to mean "`-a` (all processes with a terminal, except session leaders) **plus** all processes belonging to a user literally named `x`". `procps-ng` checks whether a user `x` exists; when it does not, it charitably reinterprets the request as BSD `aux` and prints the warning. On a system that happens to have a user named `x`, you get silently different output — which is the real reason to never write `-aux`.

**A2.2** — `WCHAN` is the kernel function in which the task is blocked. `worker.sh` sits in `do_wait`: it called `wait4()` and is blocked until its child `sleep` exits. The `sleep` sits in `hrtimer_nanosleep`: it is blocked on a high-resolution timer. Both are in interruptible sleep (`S`), so both will react to a signal immediately.

**A2.3** — `D` is **uninterruptible sleep**: the task is blocked inside a kernel call that cannot be interrupted by signals, almost always waiting on block I/O or an unresponsive network filesystem (NFS, iSCSI, a stalled device). `SIGKILL` is recorded as pending but **cannot take effect** until the syscall completes; the process is unkillable in the meantime. Persistent `D` states point at storage, not at the process. (Some paths use `D` with the `TASK_KILLABLE` variant, which *does* honour `SIGKILL` — but you cannot tell which from `ps`.)

**A2.4** —
- `Ssl` = `S` interruptible sleep · `s` session leader · `l` multi-threaded (has cloned threads).
- `R+` = `R` running or runnable (on a run queue) · `+` in the **foreground process group** of its controlling terminal.
Other modifiers: `<` high priority (negative nice), `N` low priority (positive nice), `L` has pages locked into memory, `T` stopped by a job-control signal, `t` stopped by a debugger during tracing, `Z` zombie, `I` idle kernel thread, `X` dead.

**A2.5** — `RSS` (resident set size) is closer: it counts only physical pages currently resident, whereas `VSZ` counts the whole virtual address space including reservations, mapped-but-untouched regions and shared libraries that may never be paged in. But `RSS` **counts shared pages in full for every process that maps them** — sum `RSS` across all processes and you massively over-count `libc`, the page cache-backed binaries, and the shared memory of forked workers. For a per-process figure that sums honestly, use `PSS` (proportional set size) from `/proc/PID/smaps_rollup`.

**A2.6** — Not instantaneous. `ps` computes `%CPU = cputime / elapsed_time × 100`, where `cputime` is the total user+system time consumed since the process started (`times`) and `elapsed` is its wall-clock age (`etimes`). It is therefore a **lifetime average**: a process that pegged a CPU for its first minute and has been idle for the last hour still shows a small, slowly shrinking number. `top` recomputes from deltas between refreshes and reports the last interval.

**A2.7** — The first `COMMAND` is the `comm` format specifier, sourced from `/proc/PID/comm`, and it is capped at **15 characters** (see A6.1). The second is `args` (aliased `cmd`), sourced from `/proc/PID/cmdline`, which shows the full argument vector. `cmdline` lives in the process's own address space, so a process can **rewrite it** (`setproctitle`-style, as `sshd`, `postgres` and `nginx` do). `comm` can also be changed, but only via `prctl(PR_SET_NAME)` and only within 15 characters. Neither field is trustworthy for security decisions.

### Exercise 3

**A3.1** — No system call is invoked by the child. When a parent terminates, **the kernel performs reparenting inside `do_exit()`**: as part of tearing down the exiting task, it walks its children list and reassigns each child's parent pointer. The child observes only that its `PPid` changed the next time it looks.

**A3.2** — Because `systemd --user` marks itself a **child subreaper** via `prctl(PR_SET_CHILD_SUBREAPER, 1)`. The kernel reparents an orphan to the nearest ancestor that has that flag set, and only falls back to PID 1 (or the PID-namespace init) if there is none. Container runtimes, `tini`, and `systemd` service units use the same mechanism, which is why "orphans always go to PID 1" is folklore that no longer holds on a modern desktop or inside a container.

**A3.3** — Only an **entry in the process table**: its PID and its exit status, held so the parent can retrieve them with `wait()`. All other resources — memory, file descriptors, the address space — were already released at exit. `kill -9` fails because there is no execution context left to kill; the task is already dead. The zombie disappears the instant someone reaps it. Killing the parent works because reparenting hands the child to a subreaper or init, which calls `wait()` in a loop and reaps it immediately.

**A3.4** — The defect is in the **parent**: it forks children but never calls `wait()`/`waitpid()`, or it installed `SIG_IGN`/a broken handler for `SIGCHLD`. Restart the *parent*, not the zombies. The operational stake is PID exhaustion — check `cat /proc/sys/kernel/pid_max`; each zombie holds a PID hostage.

**A3.5** — With `exec`, the `bash` process is **replaced in place** by `sleep`. The PID and the parent/child relationships survive the `exec`, so `sleep` inherits the just-exited `/bin/true` as a child — and `sleep` never calls `wait()`, so the zombie persists for its full 120 seconds. Without `exec`, `bash` remains the parent; `bash` reaps background children as part of its normal `SIGCHLD` handling and job bookkeeping, so the zombie is cleaned up almost instantly.

### Exercise 4

**A4.1** — `bash` cannot interrupt a foreground child. When the signal arrives, `bash` marks the trap as pending, and executes the handler only **after the currently running foreground command completes** — here, after the in-flight `sleep 1` returns. Hence up to one second of latency. The standard fix for a script that must react promptly is `sleep 300 & wait $!`, because `bash` *does* interrupt the `wait` builtin to run a trap.

**A4.2** — The rule is **`128 + signal_number`**: `128 + 15 = 143` for `SIGTERM`, `128 + 9 = 137` for `SIGKILL`. It is a shell convention defined in the POSIX Shell & Utilities specification for `$?` (and implemented by `bash`, `dash`, `ksh`, `zsh`), which needs to distinguish a normal exit code from termination by signal in a single 8-bit value. Note the ambiguity it creates: a program that genuinely `exit(143)`s is indistinguishable from one that was `SIGTERM`ed. `wait -n` plus `WIFSIGNALED` at the C level is the unambiguous route.

**A4.3** — **`SIGKILL` (9)** and **`SIGSTOP` (19 on x86-64)**. They guarantee the operator always retains two capabilities no program can revoke: the ability to terminate any process it owns, and the ability to freeze it for inspection. Without that, a buggy or hostile process could install handlers for everything and become genuinely unstoppable. The cost is that neither gives the process any chance to clean up — hence `SIGTERM` first.

**A4.4** — The mask is a 64-bit bitmap where **bit *n*−1 corresponds to signal *n*** (bit 0 = signal 1). `0x4003` = binary `100 0000 0000 0011`. Bit 0 set → signal 1 = `SIGHUP`. Bit 1 set → signal 2 = `SIGINT`. Bit 14 set → signal 15 = `SIGTERM`. Reading `SigIgn` and `SigCgt` from `/proc/PID/status` is the definitive answer to "does this daemon support reload-on-`SIGHUP`?" — far more reliable than the documentation.

**A4.5** —
- `kill -TERM 1234` → signals **the single process** with PID 1234.
- `kill -TERM -1234` → signals **every process in process group 1234**. A negative PID means "process group".
- `kill -TERM 0` → signals **every process in the caller's own process group**, which includes the calling shell. Typing it interactively kills your session.

**A4.6** — PID `-1` is a special value meaning "**every process the caller has permission to signal**", excluding the calling process itself and PID 1. As a normal user it kills all of *your* processes — your shells, your desktop session, your SSH connections; you are logged out. As `root` it kills essentially **every process on the system except init**, taking down `sshd`, the database, and the logging daemon simultaneously, with no shutdown sequencing. Root fares strictly worse.

**A4.7** — The **builtin** understands shell job specifications (`kill %1`, `kill %+`) because only the shell knows its job table; the external binary cannot. The **external `/bin/kill`** (util-linux) offers features the builtin lacks, notably `--timeout` for the escalate-after-N-milliseconds pattern, `--queue`/`--value` for `sigqueue()` real-time signals with a payload, and `--verbose`. It is also what you get from `find -exec`, `xargs` and any non-shell context.

**A4.8** — **Always signal by name, never by number, in anything portable.** `signal(7)` documents the divergence: `SIGUSR1` is 10 on x86/ARM, 30 on Alpha/SPARC, 16 on MIPS; `SIGSTOP` is 19, 17 and 23 respectively. Only signals 1–2 (`HUP`, `INT`), 3 (`QUIT`), 9 (`KILL`), 11 (`SEGV`), 13 (`PIPE`) and 15 (`TERM`) are stable across all Linux architectures. `kill -USR1` is correct everywhere; `kill -10` is correct on your laptop.

### Exercise 5

**A5.1** — `nohup` does exactly two things: it sets the disposition of **`SIGHUP` to `SIG_IGN`**, and it redirects output if stdout is a terminal (see A5.2). Then it `exec`s the requested command, which inherits the ignored disposition across `execve()`. It does **not** background anything — you must still append `&` yourself. It does not fork, does not create a new session, and does not detach from the controlling terminal.

**A5.2** — If stdout is a terminal, `nohup` **appends** it to `nohup.out` in the current directory; if that is not writable, it falls back to `$HOME/nohup.out`. If stdout is already redirected, `nohup` leaves it alone. Stderr, if it is a terminal, is redirected onto **stdout** — so both streams end up interleaved in the same file. It also reports `ignoring input`, because stdin is left as-is and a backgrounded process reading the terminal gets `SIGTTIN`.

**A5.3** — Both remove the shell's obligation to send `SIGHUP` to that job, but they differ in bookkeeping. `disown -h %1` **keeps the job in the job table** (so `jobs`, `fg`, `bg` and `wait` still work on it) and merely marks it "do not send `SIGHUP`". Plain `disown %1` **removes the entry entirely** — you can no longer `fg` it, and `$!`-style tracking is gone; you are down to the PID. Neither touches the process: they change *the shell's* behaviour, which is why `SigIgn` stayed `0`.

**A5.4** — `disown` cannot protect against a `SIGHUP` sent by the **kernel** when the controlling terminal is hung up. On terminal disconnection the kernel sends `SIGHUP` to the foreground process group of that session directly, entirely bypassing the shell. `nohup` survives it because the *process itself* ignores the signal; `disown` only stops the *shell* from sending its own. In practice a disowned background job usually survives anyway — it is not in the foreground process group — but it is a weaker guarantee.

**A5.5** — `setsid` calls `setsid(2)`, which makes the caller the leader of a **new session** and of a **new process group**, and detaches it from the **controlling terminal**. Both severances matter: terminal-generated signals (`SIGINT`, `SIGQUIT`, `SIGTSTP`, `SIGHUP`-on-hangup) are delivered to process groups within the session of a controlling terminal. With no controlling terminal and a session of its own, none of those can reach the process. This is the classic daemonisation step, and the reason `TT` shows `?`.

**A5.6** — `bash` sends `SIGHUP` to its jobs in two cases: (a) when **`bash` itself receives `SIGHUP`** — an interactive login shell then forwards it to all jobs; and (b) on **normal exit**, only if `shopt -s huponexit` is enabled. Step 6 was case (a): you sent `SIGHUP` explicitly to the nested shell, which forwarded it, and `plain` — with no ignored disposition and still in the job table — died. `huponexit` being off is why `exit`-ing a shell normally usually leaves background jobs alive.

**A5.7** — **`tmux` (or `screen`) wins**, clearly. `nohup`, `disown` and `setsid` all make the job *survive*, but they leave you with only a log file — there is no interactive terminal to reattach to, so "watch its progress tomorrow" means `tail -f` at best, and any prompt the job emits is unanswerable. `tmux` keeps a live pty owned by a server process outside your login session: you reattach and are back inside the running program, scrollback and all. Ranking: `tmux` > `setsid` (true detachment, but no reattach) > `nohup` (survives the common case, output to a file) > `disown` (retrofit only — it is what you use when you *forgot* to plan ahead).

### Exercise 6

**A6.1** — Because `comm` is stored in a fixed-size field inside the kernel's `task_struct`, sized by **`TASK_COMM_LEN`, which is 16 bytes** — 15 characters plus the terminating NUL. Keeping it fixed-size and in-kernel means `comm` is always readable, cannot be swapped out, and needs no locking against the process's own address space (unlike `cmdline`, which lives in user memory and can be unreadable or falsified).

**A6.2** — `pgrep` matches against **`comm`** by default — the truncated 15-character name. `pgrep -f` matches against the **full command line** (`/proc/PID/cmdline`) instead. Since the truncated `comm` was `collect-metrics`, the 27-character pattern could never match.

**A6.3** — A **substring (ERE) match**: the pattern `collect-metrics` is an extended regular expression matched anywhere within `comm`, so it matched the truncated name of both scripts. **`-x`** forces the pattern to match the entire field exactly. It would **not** have helped here — `pgrep -x collect-metrics` would still match both, because after truncation their `comm` values are *identical*. Only `-f` (full command line) can distinguish them.

**A6.4** — `procps-ng`'s `killall` documents that when the requested name is longer than 15 characters, the full name may be unavailable in `comm`, so it falls back to **comparing only the first 15 characters** and kills everything that matches that prefix. `collect-metrics-daemon.sh` and `collect-metrics-shipper.sh` share the prefix `collect-metrics`, so both matched. **`-e` (`--exact`)** disables the fallback: entries whose name cannot be matched in full are skipped rather than killed. `-r` switches to explicit regex matching against the name.

**A6.5** — On Solaris (and historically on some other System V derivatives), `killall` run by root sends `SIGTERM` to **all processes on the system** — it is a shutdown-sequence helper, not a pattern matcher. Running the Linux idiom `killall httpd` there takes the machine down. The discipline: in portable scripts use `pkill` (which has consistent semantics across Linux and the BSDs) or plain `kill` with PIDs from a pidfile, and never `killall`.

**A6.6** — `pgrep`/`pkill` exclude only **their own PID**, not their parent or siblings. If you run a script named `backup.sh` and it internally calls `pkill -f backup`, the pattern matches the script's own `bash` process — `/bin/bash ./backup.sh` contains `backup` — and the script kills itself mid-run, leaving whatever it was doing half-finished. Defences: anchor the pattern to exclude yourself (`pkill -f 'backup-worker\.py'`), add `-x` with a precise `comm`, or filter explicitly with `pgrep -f pattern | grep -v "^$$\$"`.

**A6.7** —

```bash
sudo pkill -HUP -x -u root -o nginx
```

`-HUP` selects the signal by name (portable — see A4.8). `-x` requires an exact `comm` match, so `nginx-debug` or a script with `nginx` in its name is not caught. `-u root` restricts to processes owned by root, excluding the `www-data` worker processes. `-o` selects the **oldest** matching process, which for a pre-forking daemon is the master — the workers are its children and were started later. In production, prefer the pidfile — `kill -HUP "$(cat /run/nginx.pid)"` — or `systemctl reload nginx`, both of which are unambiguous by construction.

### Exercise 7

**A7.1** — No. Load average is roughly comparable to **`nproc`**: a load equal to the CPU count means the machine is fully utilised with no queueing; below it there is headroom; sustained load *above* it means tasks are waiting. 2.71 on 8 CPUs is about 34 % utilisation — healthy. The number is meaningless without the core count, which is why alerts should be expressed as `load / nproc`.

**A7.2** — Linux counts tasks in state **`R` (running/runnable) *and* `D` (uninterruptible sleep)**; classical UNIX counts only runnable tasks. So on Linux a host with idle CPUs but a stalled NFS mount or a saturated disk can show a load of 50 while `%Cpu(s)` reads 95 % idle. Load average on Linux therefore measures *demand pressure across CPU and I/O together*, not CPU utilisation — always read it alongside `%wa` and the count of `D`-state tasks.

**A7.3** — `4/1247` is **currently runnable tasks / total tasks** (threads) that currently exist. `6103` is the **PID most recently allocated** by the kernel. A rapidly climbing last field is a useful signal of fork-storm behaviour.

**A7.4** — The load averages are **exponentially damped moving averages** over nominal 1-, 5- and 15-minute windows, sampled by the kernel every 5 seconds. They decay toward the new value rather than snapping to it: after removing the load, the 1-minute figure needs roughly a minute to fall to ~37 % of its old value, and the 15-minute figure lags far longer. A "load average" that dropped instantly would not be an average.

**A7.5** —
- `us` — user time, processes at normal priority
- `sy` — kernel/system time
- `ni` — user time of processes with a **positive nice value** (deprioritised); counted separately from `us`
- `id` — idle
- `wa` — I/O wait: idle CPU time during which at least one task was blocked on I/O
- `hi` — hardware interrupt servicing
- `si` — software interrupt (softirq) servicing, e.g. network receive processing
- `st` — **steal**: time the virtual CPU was ready to run but the hypervisor gave the physical CPU to another guest

`st` is the one that goes non-zero on an **oversubscribed hypervisor** — a critical figure on cloud instances, since it is capacity you are paying for but not receiving. `si` is the one to watch on a network-saturated host.

**A7.6** — `free` is memory that is **completely unused**, holding nothing at all. `available` is the kernel's estimate of memory **obtainable by a new application without swapping**, i.e. `free` plus the reclaimable portion of the page cache and slab. Linux deliberately uses idle RAM for cache, so on a healthy long-running server `free` trends toward near zero and that is *correct behaviour*, not a leak. A capacity alert must therefore use **`available`** (`MemAvailable` in `/proc/meminfo`); alerting on `free` produces a permanent false positive on every busy machine.

**A7.7** — Not a bug. In the default **Irix mode**, `top` scales `%CPU` per *logical CPU*, so a process using 3.4 cores fully shows 340 %. Pressing **`I`** toggles to **Solaris mode**, which divides by the CPU count and shows the same process as 42.5 % of the whole machine. Irix mode makes it obvious how many cores a thread pool is consuming; Solaris mode makes the column sum to 100 % across the machine.

**A7.8** — `ps` reports a **lifetime average**: total CPU time consumed divided by total elapsed time since the process started. `top` reports usage over the **most recent refresh interval**, computed from the delta in CPU ticks between two samples. Consequences: for a long-lived process that is busy right now, `top` reads much higher than `ps`; for one that burned CPU at startup and is now idle, `ps` reads higher. Also, `top -b -n 1` has no previous sample to diff against, so its first iteration falls back to lifetime figures — which is why `top -b -n 2 -d 1 | tail` is the correct scripted form.

**A7.9** — With `k`, `top` (a) lets you **choose the signal**, prompting for it after the PID — it is not hardcoded to `SIGTERM`; and (b) lets you act on a process you just identified **without leaving the sorted, live view** or retyping a PID, so you see the effect immediately in the next refresh. The risk is precisely that immediacy: the row under your cursor moves between refreshes as the sort order changes, so it is easy to confirm a PID that is no longer the one you looked at. Read the PID, then confirm it in the prompt.

### Exercise 8

**A8.1** — Default interval is **2 seconds** (`-n` changes it; `procps-ng` accepts fractional values such as `-n 0.5`). **`-d` (`--differences`)** highlights the characters that changed since the previous run; `-d=cumulative`/`--differences=permanent` keeps every position that has *ever* changed highlighted, which is useful for spotting a field that flickers rarely.

**A8.2** — `watch` passes its command to **`sh -c`** — but only after assembling it from the remaining argv. Unquoted, `ps -eo pid,stat,comm --sort=-%cpu` survives because `watch` rejoins the arguments and the shell it spawns re-parses them harmlessly. The moment you add `| head`, **your interactive shell** interprets the pipe first: it pipes `watch`'s own output into `head` instead of passing the pipeline to `watch`. Quoting the whole expression is the fix. **`-x` (`--exec`)** passes the argument vector directly to `execvp` with no shell at all — you lose pipes, redirections, globbing and variable expansion, and you gain exact control over word splitting (essential when arguments contain spaces or quotes).

**A8.3** — **`-g` (`--chgexit`)** exits as soon as the command's *output* changes from the previous iteration — a cheap "wait until this value moves" primitive. **`-e` (`--errexit`)** exits when the command returns a **non-zero exit status**, freezing the display so you can read the error (add `-b`/`--beep` to be alerted audibly).

**A8.4** — First, `top` is already a self-refreshing full-screen program with its own timing, sorting and state; wrapping it means `watch` clears the screen and restarts `top` from scratch every second, discarding all of it. Second, `top` in non-batch mode expects a terminal it controls; under `watch` it either garbles the display or refuses to run. The correct scripted form is `top -b -n N -d S`, which is designed for non-interactive output.

**A8.5** — No. `top` is a **sampling monitor**: it reads counters at intervals and computes rates from the deltas, so it can report meaningful per-interval CPU percentages. `watch` is a **repeater**: it re-executes an arbitrary command and shows you its output, computing nothing. Each `watch` iteration is an independent process with no memory of the previous one — which is exactly why `watch -n 1 'echo $$'` prints a *different* PID each time (a fresh `sh -c` per iteration; the `$$` is expanded by that subshell, not by your shell, because it is single-quoted).

### Exercise 9

**A9.1** — It resembles **`setsid`**: `screen` daemonises its server process into a new session with no controlling terminal, reparented to init. What `screen` adds is a **pseudo-terminal (pty) pair that it allocates and owns**. Your job's controlling terminal is that pty (`pts/3`), whose master end is held by the long-lived `screen` server rather than by your SSH session — so the job keeps a fully functional interactive terminal that outlives your connection, which bare `setsid` cannot provide.

**A9.2** — Because the master side of `pts/3` is held open by the **`screen` server process**, which is not part of your login session and does not exit when SSH disconnects. A pty is destroyed only when its master is closed. Your SSH connection owns a *different* pty (the one your login shell used); that one is torn down and its foreground group gets `SIGHUP`, but `pts/3` and everything on it are untouched.

**A9.3** —
- `screen -r <name>` — reattach to a session currently marked **Detached**. Fails if it is marked Attached.
- `screen -d -r <name>` — **force**: detach it from wherever it is attached, then attach here. This is the one you need after a network drop left the session wrongly marked Attached.
- `screen -x <name>` — **multi-attach**: join a session that is already attached elsewhere, both terminals sharing the same view. The pair-programming / over-the-shoulder-support mode.

**A9.4** — Advantages of `tmux`: a genuine client–server architecture with a scriptable command interface (`tmux send-keys`, `tmux new-window`, `tmux list-panes`), so entire layouts can be built from a script; real vertical **and** horizontal splits as a first-class concept; and far more active upstream development. `screen` remains the pragmatic choice when it is **the only one installed** — it ships in the base or minimal package set of many enterprise distributions and appliances where `tmux` is not available and you have no package access. Muscle memory for `Ctrl-a d` is worth having for exactly that day.

**A9.5** — Use `setsid` (or `nohup … &`) with explicit output redirection:

```bash
setsid ./migrate.sh > ~/migrate.log 2>&1 < /dev/null &
```

then follow it later with `tail -f ~/migrate.log`. What you give up is **interactivity**: you cannot reattach to a terminal, so the job must never prompt (redirect stdin from `/dev/null` so that a stray read fails fast instead of blocking on `SIGTTIN`), you have no scrollback beyond the log, and you cannot send it keystrokes — only signals. Design the job to be non-interactive and log-verbose before you rely on this.

### Exercise 10

**A10.1** — This is **I/O saturation**, not CPU pressure. On Linux the load average counts `D`-state (uninterruptible sleep) tasks, so dozens of processes blocked on a stalled disk, a degraded RAID rebuild or a hung NFS mount produce a huge load while the CPUs sit idle — exactly the `94.0 wa` signature. Killing the top `%CPU` process would remove a process that is barely running and would not touch the queue of blocked tasks; worse, `D`-state tasks cannot be killed at all until their I/O completes. Investigate storage: `iostat -x`, `dmesg -T | tail`, the state of the mounts, and `ps -eo stat,wchan,comm | awk '$1 ~ /D/'` to see *what* they are blocked on.

**A10.2** — `TIME+` is **cumulative CPU consumed**, which tells you the process has been busy but not *when it started being a problem*. `lstart` gives the absolute wall-clock start time and `etimes` the age in seconds, which is what correlates the process with the deployment, the cron entry, or the user login that caused it. An incident write-up needs a timeline; `TIME+` cannot supply one. A process with `TIME+ 04:12:33` and `etimes 15100` has been busy for 4 of the last 4.2 hours — that combination is the actual finding.

**A10.3** — `kill -9` will **not take effect while the task remains in `D`**. `SIGKILL` is set pending and the kernel will act on it the moment the uninterruptible kernel path returns — which may be seconds, or never if the underlying device or NFS server does not respond. The process will keep appearing in `ps` after the `kill`, and `ps -o stat` will still show `D`. `SigCgt: 0` merely confirms the process catches nothing; it is irrelevant here, because `SIGKILL` is never caught anyway. The fix is at the storage layer, not the process layer.

**A10.4** — It prevents **orphaned children continuing the damage**. If the offender forked workers, killing only the parent leaves the workers running — they are reparented to init/a subreaper and keep consuming the CPU or writing to the same files, while your monitoring shows the offender "gone". Signalling the whole process group reaches the parent and every descendant that stayed in the group in one atomic operation. Verify group membership first (`ps -eo pid,pgid,comm | awk '$2==g'`) so you do not signal your own shell — and be aware that a child that called `setsid` or `setpgid` has left the group and needs separate handling.

**A10.5** — `systemctl stop` uses the unit's **cgroup** as the authoritative process set, so it reaches every descendant regardless of process group, session, or double-forking — something `kill` on a PID cannot do. It also honours the unit's configured `KillSignal`, `TimeoutStopSec` and `ExecStop=`, escalating to `SIGKILL` on the unit's own schedule, and it **updates systemd's state**: `Restart=` will not fight you by immediately respawning the process, and `systemctl status` will show `inactive (dead)` rather than a service systemd believes is running but is not. `kill`-ing a managed service leaves the supervisor and reality out of sync.

**A10.6** —

1. **`SIGTERM`** — the documented "shut down cleanly" request. Wait **10–30 s**, sized to the service's own shutdown timeout (for a database, longer: it may be flushing).
2. **`SIGHUP`** if the daemon is merely wedged on stale configuration and documents reload-on-HUP — check `SigCgt` first. (Optional rung; skip if not applicable.)
3. **`SIGTERM` to the process group** (`kill -TERM -$PGID`) — catches children that ignored the parent's shutdown. Wait **10 s**.
4. **`SIGKILL`** to the PID, then to the group — unconditional, no cleanup, locks and temp files left behind. Wait **5 s** and verify.
5. If it is still present, it is in **`D` state** and no signal will help: the problem is below the process layer (storage, network filesystem, driver). Investigate there; a reboot may be the only remaining lever.

For a systemd-managed service, replace rungs 1–4 with `systemctl stop` — it performs exactly this escalation, over the correct process set, on a configured timeout.

</details>

---

## Sources

- LPI — Exam 101-500 Objectives (v5.0), Topic 103.5: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Bash Reference Manual — Job Control: <https://www.gnu.org/software/bash/manual/html_node/Job-Control.html>
- GNU Bash Reference Manual — Signals: <https://www.gnu.org/software/bash/manual/html_node/Signals.html>
- `signal(7)` — Linux manual page (signal numbers, dispositions, architecture differences): <https://man7.org/linux/man-pages/man7/signal.7.html>
- `ps(1)` — Linux manual page (syntax styles, output specifiers, process state codes): <https://man7.org/linux/man-pages/man1/ps.1.html>
- `kill(1)`: <https://man7.org/linux/man-pages/man1/kill.1.html> · `kill(2)`: <https://man7.org/linux/man-pages/man2/kill.2.html>
- `pgrep(1)` / `pkill(1)`: <https://man7.org/linux/man-pages/man1/pgrep.1.html>
- `killall(1)`: <https://man7.org/linux/man-pages/man1/killall.1.html>
- `nohup(1)`: <https://man7.org/linux/man-pages/man1/nohup.1.html> · `setsid(1)`: <https://man7.org/linux/man-pages/man1/setsid.1.html> · `setsid(2)`: <https://man7.org/linux/man-pages/man2/setsid.2.html>
- `top(1)`: <https://man7.org/linux/man-pages/man1/top.1.html> · `free(1)`: <https://man7.org/linux/man-pages/man1/free.1.html> · `uptime(1)`: <https://man7.org/linux/man-pages/man1/uptime.1.html> · `watch(1)`: <https://man7.org/linux/man-pages/man1/watch.1.html>
- `proc(5)` — `/proc/PID/status`, `/proc/PID/comm`, `/proc/loadavg`, `/proc/meminfo`: <https://man7.org/linux/man-pages/man5/proc.5.html>
- `credentials(7)` — process groups and sessions: <https://man7.org/linux/man-pages/man7/credentials.7.html>
- `prctl(2)` — `PR_SET_NAME`, `PR_SET_CHILD_SUBREAPER`: <https://man7.org/linux/man-pages/man2/prctl.2.html>
- Linux kernel documentation — the `/proc` filesystem: <https://docs.kernel.org/filesystems/proc.html>
- procps-ng (upstream of `ps`, `top`, `free`, `uptime`, `watch`, `pgrep`, `kill`, `killall`): <https://gitlab.com/procps-ng/procps>
- GNU Screen manual: <https://www.gnu.org/software/screen/manual/screen.html>
- tmux — official wiki and manual: <https://github.com/tmux/tmux/wiki>
- `systemd.kill(5)` — `KillMode`, `KillSignal`, `TimeoutStopSec`: <https://www.freedesktop.org/software/systemd/man/systemd.kill.html>