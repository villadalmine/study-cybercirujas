# 103.4 — Use streams, pipes and redirects
## Guided exercises (LPIC-1, exam 101-500, v5.0)

**Environment assumed:** Linux with Bash 5.x, GNU coreutils, GNU findutils, `procfs` mounted. Everything runs as an unprivileged user except where `sudo` is explicitly shown. Run every command in the lab directory built in Exercise 0.

**How to work through this:** execute each numbered step, compare your real output with the expected output shown, then answer the questions before moving on. Answers are in the collapsible section at the bottom.

---

## Exercise 0 — Build the lab

```bash
mkdir -p ~/lab-103.4 && cd ~/lab-103.4
```

1. Create deterministic data files:

```bash
seq 1 100 > numbers.txt
printf 'alpha\nbravo\ncharlie\ndelta\n' > words.txt
printf 'bravo\ncharlie\necho\nfoxtrot\n' > words2.txt
touch 'my report.txt' "it's here.txt"
```

2. Create a program that writes deterministically to **both** output streams and exits non-zero. Almost every later exercise uses it:

```bash
cat > noisy.sh <<'EOF'
#!/bin/bash
echo "stdout: processing $1"
echo "stderr: warning about $1" >&2
exit 3
EOF
chmod +x noisy.sh
```

3. Verify it:

```bash
./noisy.sh alpha
echo "exit=$?"
```

Expected:

```
stdout: processing alpha
stderr: warning about alpha
exit=3
```

4. Note the idiom used inside the script — `echo "..." >&2`. This is how a well-behaved tool separates diagnostics from data.

### Questions

- **Q0.1** In step 2 the here-document delimiter is written as `<<'EOF'` rather than `<<EOF`. What would have gone wrong with the unquoted form, given the script body contains `$1`?
- **Q0.2** Both lines of `./noisy.sh alpha` appear on your terminal. What experiment proves they travelled on two different file descriptors?

---

## Exercise 1 — The three standard streams as kernel objects

1. Ask the shell which file descriptors it currently holds:

```bash
ls -l /proc/self/fd
```

Expected (device name will vary):

```
total 0
lrwx------ 1 user user 64 Aug 26 10:00 0 -> /dev/pts/0
lrwx------ 1 user user 64 Aug 26 10:00 1 -> /dev/pts/0
lrwx------ 1 user user 64 Aug 26 10:00 2 -> /dev/pts/0
lr-x------ 1 user user 64 Aug 26 10:00 3 -> /proc/2841/fd
```

2. Now change what fd 1 points at, for that one command only:

```bash
ls -l /proc/self/fd > fds.txt
cat fds.txt
```

Expected: fd `1` now resolves to `/home/user/lab-103.4/fds.txt`, while `0` and `2` still point at the terminal.

3. Confirm the three streams are numbered, not named:

```bash
./noisy.sh a 1> stdout.txt 2> stderr.txt
cat stdout.txt
cat stderr.txt
```

Expected:

```
stdout: processing a
stderr: warning about a
```

4. Confirm the redirection is per-command and does not persist:

```bash
echo "back on the terminal"
```

### Questions

- **Q1.1** Why does `ls -l /proc/self/fd` show an extra descriptor 3 that you never opened, and why is it `lr-x` rather than `lrwx`?
- **Q1.2** `1>` and `>` behave identically. Which file descriptor number is the *only* one that can be omitted before `>`, and which is the only one that can be omitted before `<`?
- **Q1.3** In step 2, what would `/proc/self/fd/1` have shown if you had written `ls -l /proc/self/fd | cat` instead?

---

## Exercise 2 — Truncate, append, and the `noclobber` safety net

1. Observe truncation:

```bash
echo "first"  > log.txt
echo "second" > log.txt
cat log.txt
```

Expected: `second` only — `>` truncates to zero length **before** the command runs.

2. Observe append:

```bash
echo "third" >> log.txt
cat log.txt
```

Expected:

```
second
third
```

3. Prove that truncation happens before execution, even if the command fails:

```bash
echo "important data" > keep.txt
nosuchcommand > keep.txt
wc -c keep.txt
```

Expected:

```
bash: nosuchcommand: command not found
0 keep.txt
```

4. Enable the protection and retry:

```bash
set -o noclobber      # equivalent: set -C
echo "attempt" > log.txt
```

Expected:

```
bash: log.txt: cannot overwrite existing file
```

5. Override it deliberately for one command, then disable the option:

```bash
echo "attempt" >| log.txt
cat log.txt
set +o noclobber
```

6. Append stderr without touching stdout:

```bash
./noisy.sh b 2>> errors.log
./noisy.sh c 2>> errors.log
cat errors.log
```

### Questions

- **Q2.1** In step 3 the file was emptied even though the command never ran. Which process performs the truncation, and at what point in the pipeline of events?
- **Q2.2** `noclobber` blocked `>` in step 4. Does it also block `>>`? Does it block `>` when the target does not yet exist? Does it block `> /dev/null`?
- **Q2.3** A colleague's backup script contains `sort < data.txt > data.txt`. Predict the resulting size of `data.txt` and explain why.

---

## Exercise 3 — Merging stderr into stdout: order is everything

1. Send both streams to the same file:

```bash
./noisy.sh a > both.txt 2>&1
cat both.txt
```

Expected:

```
stdout: processing a
stderr: warning about a
```

2. Now swap the order of the two redirections:

```bash
./noisy.sh a 2>&1 > only-stdout.txt
```

Expected on the terminal:

```
stderr: warning about a
```

And:

```bash
cat only-stdout.txt
```

Expected:

```
stdout: processing a
```

3. Use the Bash shorthand (not POSIX):

```bash
./noisy.sh a &> shorthand.txt
./noisy.sh b &>> shorthand.txt
cat shorthand.txt
```

4. Observe stdio buffering changing the *interleaving* when a C program writes to a file:

```bash
ls /etc/hostname /etc/definitely-not-here > lsboth.txt 2>&1
cat lsboth.txt
```

Expected:

```
ls: cannot access '/etc/definitely-not-here': No such file or directory
/etc/hostname
```

5. Compare with the same command writing to the terminal:

```bash
ls /etc/hostname /etc/definitely-not-here
echo "exit=$?"
```

Expected: the two lines appear in the opposite (natural) order, and `exit=2`.

### Questions

- **Q3.1** Explain `2>&1 > file` in terms of descriptor duplication. Where does fd 2 point after the whole line is processed, and why is that *not* the file?
- **Q3.2** In step 4 the error line landed in the file *before* the data line, even though `ls` printed the data first internally. What is the mechanism?
- **Q3.3** You must write a portable `/bin/sh` script. Rewrite `cmd &>> out.log` using only POSIX redirection operators.
- **Q3.4** Why does `cmd > file 2>&1` work but `cmd > file 1>&2` silently destroy your data?

---

## Exercise 4 — Discarding output, and the difference between `/dev/null` and a closed descriptor

1. Discard stderr only:

```bash
./noisy.sh a 2>/dev/null
```

Expected: just `stdout: processing a`.

2. Discard stdout only, keep diagnostics:

```bash
./noisy.sh a >/dev/null
```

3. Discard everything but keep the exit status:

```bash
./noisy.sh a >/dev/null 2>&1
echo "exit=$?"
```

Expected: `exit=3`.

4. Now *close* fd 2 instead of discarding it:

```bash
./noisy.sh a 2>&-
echo "exit=$?"
```

5. Show why closing is riskier than discarding:

```bash
bash -c 'exec 2>&-; echo hello > /dev/full' ; echo "exit=$?"
```

Compare with:

```bash
bash -c 'exec 2>/dev/null; echo hello > /dev/full' ; echo "exit=$?"
```

### Questions

- **Q4.1** What is `/dev/null`, in terms of major/minor device numbers and kernel driver behaviour on `write()` and on `read()`?
- **Q4.2** A program does `write(2, buf, n)` after you ran it with `2>&-`. Which `errno` does it get, and name a realistic failure mode this causes in a long-running daemon.
- **Q4.3** `find / -name core 2>/dev/null` is a very common idiom. What exactly is being hidden, and what real problem can this mask during an audit?

---

## Exercise 5 — Input redirection, here-documents and here-strings

1. Contrast an argument with redirected input:

```bash
wc -l numbers.txt
wc -l < numbers.txt
```

Expected:

```
100 numbers.txt
100
```

2. Feed a command a literal block:

```bash
sort <<EOF
delta
alpha
charlie
EOF
```

Expected:

```
alpha
charlie
delta
```

3. Compare expansion behaviour of the delimiter:

```bash
cat <<EOF
user=$USER
year=$(date +%Y)
EOF

cat <<'EOF'
user=$USER
year=$(date +%Y)
EOF
```

4. Use the tab-stripping variant. **The indentation below must be real tab characters** (type `Ctrl+V` then `Tab` in the terminal, or write the script in an editor with tabs):

```bash
if true; then
	cat <<-EOF
	indented but flush in output
	EOF
fi
```

5. Use a here-string:

```bash
tr 'a-z' 'A-Z' <<< "alpha bravo"
wc -c <<< "abc"
```

Expected:

```
ALPHA BRAVO
4
```

6. Observe how command substitution and here-strings treat trailing newlines:

```bash
printf 'a\nb\nc\n' | wc -l
wc -l <<< "$(printf 'a\nb\nc\n')"
printf 'no-newline' | wc -l
```

Expected:

```
3
3
0
```

### Questions

- **Q5.1** Why does `wc -l < numbers.txt` omit the filename? What does that tell you about how `wc` decides what to print?
- **Q5.2** In step 4, `<<-` removed the indentation. Does it strip leading *spaces*? What is the practical consequence for a heredoc pasted from a document that uses 4-space indentation?
- **Q5.3** `wc -c <<< "abc"` returned 4, not 3. Where did the fourth byte come from?
- **Q5.4** In step 6, `$(printf 'a\nb\nc\n')` fed to `<<<` still produced 3. Two opposing transformations cancelled out — name both.

---

## Exercise 6 — Pipes, exit status and SIGPIPE

1. Build a three-stage pipeline:

```bash
grep -c . numbers.txt
sort -n numbers.txt | tail -3 | tr '\n' ' '; echo
```

Expected:

```
100
98 99 100 
```

2. Show that a pipeline's status is the status of the **last** command:

```bash
false | true
echo "status=$?"
```

Expected: `status=0`.

3. Recover every stage's status. Capture `PIPESTATUS` *immediately*:

```bash
false | true | ./noisy.sh x >/dev/null 2>&1
status=("${PIPESTATUS[@]}")
echo "stages: ${status[*]}"
```

Expected:

```
stages: 1 0 3
```

4. Prove that `PIPESTATUS` is volatile:

```bash
false | true
echo "last=$?"
echo "pipestatus now: ${PIPESTATUS[*]}"
```

5. Make failures propagate:

```bash
set -o pipefail
false | true
echo "status=$?"
set +o pipefail
```

Expected: `status=1`.

6. Observe SIGPIPE:

```bash
yes | head -3
echo "stages: ${PIPESTATUS[*]}"
```

Expected:

```
y
y
y
stages: 141 0
```

7. Observe block buffering in a pipeline. First, output to a terminal:

```bash
for i in 1 2 3; do echo "tick $i"; sleep 1; done | grep tick
```

Then the same with a further pipe stage:

```bash
for i in 1 2 3; do echo "tick $i"; sleep 1; done | grep tick | cat
```

Then fix it:

```bash
for i in 1 2 3; do echo "tick $i"; sleep 1; done | grep --line-buffered tick | cat
```

### Questions

- **Q6.1** How many processes does `a | b | c` create, and how many pipes? Which end of each pipe does each process keep open?
- **Q6.2** Why is `141` the exit status of `yes` in step 6? Decompose the number.
- **Q6.3** In step 4, why did `${PIPESTATUS[*]}` no longer show `1 0`?
- **Q6.4** In step 7, the middle version printed nothing for 3 seconds then flushed everything at once. What decision does glibc's stdio make at startup, based on what test, and what is the `stdbuf` equivalent of `--line-buffered` for a program that has no such flag?
- **Q6.5** `cmd 2>&1 | grep error` filters both streams. What does `cmd | grep error 2>&1` filter, and why is it almost always a bug?

---

## Exercise 7 — The subshell trap: variables lost in a pipeline

1. Try to count lines with a loop fed by a pipe:

```bash
count=0
printf 'a\nb\nc\n' | while read -r line; do count=$((count+1)); done
echo "count=$count"
```

Expected:

```
count=0
```

2. Confirm the loop really ran:

```bash
printf 'a\nb\nc\n' | while read -r line; do echo "saw $line"; done
```

3. Fix it with process substitution (Bash):

```bash
count=0
while read -r line; do count=$((count+1)); done < <(printf 'a\nb\nc\n')
echo "count=$count"
```

Expected: `count=3`.

4. Fix it with plain input redirection when the source is a file:

```bash
count=0
while read -r line; do count=$((count+1)); done < words.txt
echo "count=$count"
```

Expected: `count=4`.

5. Fix it with `lastpipe`. In an interactive shell you must also disable job control:

```bash
set +m
shopt -s lastpipe
count=0
printf 'a\nb\nc\n' | while read -r line; do count=$((count+1)); done
echo "count=$count"
shopt -u lastpipe
set -m
```

Expected: `count=3`.

### Questions

- **Q7.1** Where exactly did the increments in step 1 go?
- **Q7.2** Why does `shopt -s lastpipe` require job control to be off?
- **Q7.3** `cmd | read -r var` never sets `var` in Bash, but the equivalent works in `ksh93`. What does that tell you about which end of a pipeline the shell chooses to run in the current process, and why must a portable script never rely on it?

---

## Exercise 8 — `tee`: splitting a stream

1. Split a stream between a file and the next stage:

```bash
seq 1 5 | tee five.txt | wc -l
cat five.txt
```

Expected:

```
5
1
2
3
4
5
```

2. Append instead of truncating, and write to several files at once:

```bash
seq 6 8 | tee -a five.txt
seq 1 3 | tee copy-a.txt copy-b.txt > /dev/null
wc -l five.txt copy-a.txt copy-b.txt
```

Expected:

```
8 five.txt
3 copy-a.txt
3 copy-b.txt
12 total
```

3. Send a copy to stderr so a human sees the data while a pipeline consumes it:

```bash
seq 1 3 | tee /dev/stderr | md5sum
```

4. The production pattern for writing a privileged file — note that `sudo echo x > /root/file` fails, because the *shell* opens the file, not `echo`:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-lab.conf > /dev/null
cat /etc/sysctl.d/99-lab.conf
sudo rm /etc/sysctl.d/99-lab.conf
```

5. Fan a stream into two different *commands* using `tee` plus process substitution:

```bash
seq 1 10 | tee >(grep -c . > count.txt) >(paste -sd+ - > sum-expr.txt) > /dev/null
sleep 0.2
cat count.txt sum-expr.txt
```

Expected:

```
10
1+2+3+4+5+6+7+8+9+10
```

6. Protect a long capture from an accidental `Ctrl+C` on the reader:

```bash
seq 1 3 | tee -i protected.txt
```

### Questions

- **Q8.1** In step 1, why is `tee` necessary at all — why can't you write `seq 1 5 > five.txt | wc -l`?
- **Q8.2** In step 4, which process opens `/etc/sysctl.d/99-lab.conf`, and with whose credentials? Why does the redirection form fail even though the command is prefixed with `sudo`?
- **Q8.3** Why is `> /dev/null` appended in step 4 and step 5, given the file is already being written?
- **Q8.4** In step 5, why is the `sleep 0.2` there, and what class of bug does its absence produce in a script?
- **Q8.5** `cmd | tee out.log | grep ERROR` returns the exit status of which command? How do you get `cmd`'s status instead?

---

## Exercise 9 — `xargs`: turning output into arguments

1. Default behaviour — batch as many arguments as fit:

```bash
printf 'alpha\nbravo\ncharlie\n' | xargs echo
```

Expected:

```
alpha bravo charlie
```

2. One argument per invocation, and show the commands being built:

```bash
printf 'alpha\nbravo\n' | xargs -t -n1 echo "word:"
```

Expected:

```
echo word: alpha
word: alpha
echo word: bravo
word: bravo
```

3. Place the argument somewhere other than the end:

```bash
printf 'alpha\nbravo\n' | xargs -I{} echo "[{}] done"
```

Expected:

```
[alpha] done
[bravo] done
```

4. Hit the whitespace bug with the files you created in Exercise 0:

```bash
find . -maxdepth 1 -name '*.txt' | xargs ls -l 2>&1 | head -5
```

Expected: errors such as

```
ls: cannot access './my': No such file or directory
ls: cannot access 'report.txt': No such file or directory
```

5. Hit the quoting bug:

```bash
echo "it's here" | xargs echo
```

Expected:

```
xargs: unmatched single quote; by default quotes are special to xargs unless you use the -0 option
```

6. Fix both with NUL separation — the only correct way to pass filenames:

```bash
find . -maxdepth 1 -name '*.txt' -print0 | xargs -0 ls -l
```

7. Guard against an empty input set:

```bash
find . -name 'nothing-matches-this' | xargs -r ls -l ; echo "exit=$?"
find . -name 'nothing-matches-this' | xargs    ls -l ; echo "exit=$?"
```

8. Observe `xargs`' distinct exit statuses:

```bash
printf '/etc/hostname\n/definitely/not/here\n' | xargs -n1 cat > /dev/null 2>&1
echo "exit=$?"
```

Expected: `exit=123`.

9. Parallelise:

```bash
time (seq 1 4 | xargs -P4 -I{} sh -c 'sleep 1; echo done {}')
```

Expected: wall-clock ≈ 1 s, not 4 s.

10. Inspect the real limits on your system:

```bash
getconf ARG_MAX
xargs --show-limits < /dev/null
```

### Questions

- **Q9.1** In step 4, `find` emitted a single line `./my report.txt`. Which characters does `xargs` treat as argument separators by default, and how many arguments did `ls` actually receive?
- **Q9.2** Why is `-print0`/`-0` correct rather than just quoting? Which single byte is the only one that cannot appear in a Linux filename, and which is the only other one?
- **Q9.3** `-I{}` changes more than the placeholder position. Which other option does it implicitly set to `1`, and what is the performance consequence over 50 000 items?
- **Q9.4** Distinguish `find . -name '*.log' -exec rm {} \;` from `-exec rm {} +` and from `-print0 | xargs -0 rm`. Which two are equivalent in process count?
- **Q9.5** `rm $(find /var/tmp -name '*.tmp')` can fail with `Argument list too long`, but the `xargs` form never does. What does `xargs` do that command substitution cannot?
- **Q9.6** Interpret `xargs` exit statuses 123, 124, 125, 126 and 127.

---

## Exercise 10 — Command substitution vs. process substitution

1. Capture output into a variable:

```bash
lines=$(wc -l < numbers.txt)
echo "lines=[$lines]"
```

Expected: `lines=[100]`.

2. Show that trailing newlines are stripped:

```bash
v=$(printf 'x\n\n\n')
printf 'len=%s\n' "${#v}"
```

Expected: `len=1`.

3. Read a file without forking `cat`:

```bash
content=$(<words.txt)
echo "$content" | head -1
```

4. Show the quoting hazard:

```bash
mkdir -p sub && touch 'sub/two words.txt'
for f in $(find sub -type f); do echo "got: [$f]"; done
echo '--- correct ---'
while IFS= read -r -d '' f; do echo "got: [$f]"; done < <(find sub -type f -print0)
```

Expected: the first loop prints two broken entries, the second prints one correct entry.

5. Compare two commands without temporary files:

```bash
diff <(sort words.txt) <(sort words2.txt)
```

Expected:

```
1d0
< alpha
3a3,4
> echo
> foxtrot
```

6. See what a process substitution actually *is*:

```bash
echo <(true)
ls -l <(true)
```

Expected: a path such as `/dev/fd/63`.

7. Use the output-side form:

```bash
seq 1 6 > >(grep -c . > outcount.txt)
sleep 0.2
cat outcount.txt
```

Expected: `6`.

### Questions

- **Q10.1** State the one-line rule that decides between `$(cmd)` and `<(cmd)`.
- **Q10.2** Why must `$(...)` be preferred over backticks? Give a concrete nesting example that only works with `$(...)`.
- **Q10.3** In step 5, `diff` received two filenames. What kind of object is `/dev/fd/63`, and why does `diff <(sort a) <(sort b)` fail on a tool that seeks backwards through its input?
- **Q10.4** Why is `for f in $(find ...)` wrong even when you quote it as `"$(find ...)"`, and why is `read -d ''` the correct primitive?

---

## Exercise 11 — Persistent and custom file descriptors with `exec`

1. Open a private descriptor for writing:

```bash
exec 3> app.log
echo "starting run" >&3
echo "step 1 complete" >&3
exec 3>&-
cat app.log
```

Expected:

```
starting run
step 1 complete
```

2. Open a descriptor for reading and consume it incrementally:

```bash
exec 4< numbers.txt
read -r a <&4
read -r b <&4
echo "a=$a b=$b"
exec 4<&-
```

Expected: `a=1 b=2`.

3. Save, redirect, and restore the shell's own stdout — the classic script pattern:

```bash
bash -c '
  exec 3>&1                 # save the original stdout
  exec > /tmp/captured.txt  # everything now goes to the file
  echo "this line is captured"
  exec 1>&3 3>&-            # restore stdout, close the saved copy
  echo "this line is visible"
'
cat /tmp/captured.txt
```

Expected on the terminal:

```
this line is visible
this line is captured
```

4. Redirect an entire script at the top — the standard cron-safe header:

```bash
cat > logged.sh <<'EOF'
#!/bin/bash
exec >> /tmp/logged.out 2>&1
echo "run at fixed marker"
ls /definitely-not-here
EOF
chmod +x logged.sh
./logged.sh
echo "exit=$?"
tail -2 /tmp/logged.out
```

5. Redirect a whole block or loop without repeating yourself:

```bash
{
  echo "header"
  seq 1 3
  echo "footer"
} > block.txt
cat block.txt
```

6. Redirect a loop's *input*:

```bash
while read -r w; do echo "word=$w"; done < words.txt
```

### Questions

- **Q11.1** What is the difference between `exec 3> app.log` and `exec > app.log`?
- **Q11.2** In step 3, `exec 1>&3 3>&-` does two things in one line. Why is closing fd 3 important in a long-running script, and what leaks into child processes if you forget?
- **Q11.3** In step 4, why does `exec >> file 2>&1` at the top of a script solve the "cron sends me mail I don't want / cron output disappears" problem better than redirecting in the crontab line itself?
- **Q11.4** Which descriptor numbers should you avoid for custom use in scripts, and why is `{fd}>file` (Bash 4.1+) safer than hardcoding `3`?

---

## Exercise 12 — Diagnosing redirection on a live process

1. Start a background process with known redirections and inspect it:

```bash
sleep 300 > /tmp/sleep.out 2> /tmp/sleep.err &
pid=$!
ls -l /proc/$pid/fd
```

Expected:

```
lrwx------ ... 0 -> /dev/pts/0
l-wx------ ... 1 -> /tmp/sleep.out
l-wx------ ... 2 -> /tmp/sleep.err
```

2. Inspect a pipeline member instead:

```bash
kill $pid
sleep 300 | cat &
pid=$!
ls -l /proc/$pid/fd
```

Expected: fd `0 -> pipe:[123456]`.

3. Cross-check with `lsof`:

```bash
lsof -p "$pid" 2>/dev/null | awk 'NR==1 || $4 ~ /^[0-9]/'
kill %1 2>/dev/null
```

4. Scenario — reproduce and fix a real failure. A deployment script contains:

```bash
cat > deploy.sh <<'EOF'
#!/bin/bash
./noisy.sh service-a 2>&1 >> /tmp/deploy.log
./noisy.sh service-b | grep -q "stdout"
echo "grep status=$?"
EOF
chmod +x deploy.sh
./deploy.sh
```

Observe: warnings appear on the terminal instead of in `/tmp/deploy.log`, and the script cannot tell whether `noisy.sh` itself failed.

5. Repair both defects, then verify:

```bash
cat > deploy-fixed.sh <<'EOF'
#!/bin/bash
set -o pipefail
./noisy.sh service-a >> /tmp/deploy.log 2>&1
echo "service-a status=$?"
./noisy.sh service-b 2>>/tmp/deploy.log | grep -q "stdout"
echo "pipeline status=$? stages=${PIPESTATUS[*]}"
EOF
chmod +x deploy-fixed.sh
./deploy-fixed.sh
```

Expected:

```
service-a status=3
pipeline status=3 stages=3 0
```

### Questions

- **Q12.1** In step 1, why is fd 1 shown as `l-wx` while fd 0 is `lrwx`?
- **Q12.2** A process holds `1 -> pipe:[123456]`. How do you find the process on the other end of that pipe using only `/proc` or `lsof`?
- **Q12.3** In step 4, name both defects precisely, one per line of the script.
- **Q12.4** In step 5, `pipeline status=3` even though `grep` succeeded. Which option produced that, and what would the status have been without it?
- **Q12.5** A daemon's log file was deleted while it was running. `du` shows the disk is still full and `ls` shows no file. Using the concepts from this exercise, how do you locate the space and recover the data without restarting the daemon?

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

### Exercise 0

**A0.1** With an unquoted delimiter, the here-document is subject to parameter expansion, command substitution and arithmetic expansion. `$1` would have expanded to the *current* shell's first positional parameter — almost certainly empty — so the generated script would contain `echo "stdout: processing "`. Quoting any part of the delimiter (`<<'EOF'`, `<<"EOF"`, `<<\EOF`) disables all expansion and passes the body through literally. Rule for scripts that generate scripts: always quote the delimiter unless you specifically want interpolation.

**A0.2** Redirect one of them away and see which line survives: `./noisy.sh alpha 2>/dev/null` prints only the stdout line; `./noisy.sh alpha >/dev/null` prints only the stderr line. Both streams point at the same terminal by default, which is exactly why they look identical until you separate them.

### Exercise 1

**A1.1** fd 3 is the directory stream `ls` itself opened in order to read `/proc/self/fd`. It appears in its own listing because the listing is produced while that descriptor is open. It is `lr-x` (read-only) because a directory opened with `opendir()` is opened `O_RDONLY` — you cannot `write()` to a directory. Note also that `/proc/self` resolves inside the `ls` process, so it shows *`ls`'s* descriptors, not the shell's.

**A1.2** `>` defaults to fd **1** (stdout) and `<` defaults to fd **0** (stdin). fd 2 must always be written explicitly (`2>`, `2>>`, `2>&1`). This asymmetry is why `2>` is the single most-typed redirection in troubleshooting.

**A1.3** It would have shown a pipe, e.g. `1 -> pipe:[219845]`. A pipe is an anonymous kernel object with an inode number but no filesystem path.

### Exercise 2

**A2.1** The **shell** performs it, not the command. Bash parses the redirection, calls `open(path, O_WRONLY|O_CREAT|O_TRUNC, 0666)` — which truncates immediately — then `dup2()`s the result onto fd 1, and only then `execve()`s the command. If `execve()` fails (command not found), the file has already been emptied.

**A2.2** `noclobber` affects only `>` (and `>|` overrides it). It does **not** affect `>>`, and it does **not** block `>` when the target does not exist — that is the whole point, it prevents accidental overwrites, not creation. It also does not block `> /dev/null`: since Bash 4.x `noclobber` exempts character-special and other non-regular files, which is essential because `>/dev/null` is ubiquitous.

**A2.3** `data.txt` ends up **0 bytes**. Both redirections are set up before `sort` runs; `O_TRUNC` empties the file, then `sort` reads a now-empty file. Correct forms: `sort data.txt -o data.txt` (GNU `sort` handles in-place explicitly), `sponge` from moreutils, or a temp file plus `mv`.

### Exercise 3

**A3.1** Redirections are processed strictly left to right. `2>&1` means "make fd 2 a duplicate of *whatever fd 1 currently is*" — at that moment fd 1 is still the terminal, so fd 2 becomes a second handle on the terminal. Then `> file` re-points fd 1 at the file. fd 2 keeps pointing at the terminal, because `dup2()` copies the current target; it does not create an alias that follows later changes. Final state: fd 1 → file, fd 2 → terminal.

**A3.2** glibc's stdio chooses a buffering mode per stream at first use, based on `isatty()`. `stdout` to a file is **fully buffered** (typically 4 KiB), so `ls` accumulates `/etc/hostname` in memory and flushes it at `exit()`. `stderr` is **unbuffered** by C standard requirement, so the error is written immediately with a direct `write(2)`. The error therefore reaches the file first. Interleaving of merged streams is a buffering artefact, never a guarantee.

**A3.3** `cmd >> out.log 2>&1`. `&>` and `&>>` are Bash/Zsh extensions and are not in POSIX; `sh` on Debian (dash) parses `cmd &> file` as "run `cmd` in the background, then redirect an empty command to `file`" — a silent, dangerous misparse.

**A3.4** `> file 2>&1` points fd 1 at the file, then makes fd 2 a copy of fd 1 (the file). `> file 1>&2` points fd 1 at the file, then immediately re-points fd 1 at whatever fd 2 is (the terminal) — so nothing is ever written to `file`, but the file was still created and truncated. Your data is gone and your output went to the screen.

### Exercise 4

**A4.1** `/dev/null` is a character device, major 1, minor 3, backed by the kernel's `null` driver. `write()` accepts any number of bytes, discards them and returns the full count as success. `read()` returns 0 immediately — i.e. it is an infinite source of EOF, which is why `cmd < /dev/null` is the standard way to guarantee a batch job never blocks on input.

**A4.2** `EBADF` (bad file descriptor). Realistic failure: a daemon that checks the return value of its logging `write()` and treats failure as fatal will exit at the first log line; worse, a daemon that later calls `open()` will receive fd 2 as the lowest free descriptor, so its *data file* becomes fd 2 and every subsequent `perror()`/library diagnostic corrupts that file. This is precisely why `2>/dev/null` is correct and `2>&-` is not.

**A4.3** It hides `Permission denied` for directories the user cannot traverse, plus `No such file or directory` from symlink races and disappearing `/proc` entries. During an audit this masks the fact that your scan was **incomplete** — you conclude "no core files on the system" when large parts of the tree were never searched. Better: `find / -name core 2>errors.log`, then review `errors.log`.

### Exercise 5

**A5.1** With a filename argument, `wc` opens the file itself and knows its name, so it labels the count. With `<`, `wc` reads fd 0 and has no name to print. Practical consequence: `wc -l < f` is the correct form whenever you want to capture a bare number into a variable, avoiding `awk '{print $1}'` post-processing.

**A5.2** `<<-` strips **leading tab characters only** — never spaces. A heredoc indented with spaces will keep every space in the output, which breaks generated config files, YAML and here-doc-built SQL. Editors configured with "expand tabs to spaces" silently defeat `<<-`; this is one of the most common heredoc bugs in real scripts.

**A5.3** The here-string operator appends a newline to the word it feeds to stdin. So `abc` becomes `abc\n` — 4 bytes.

**A5.4** Command substitution `$( )` strips **all** trailing newlines from the captured output (`a\nb\nc\n` → `a\nb\nc`); the here-string then appends exactly **one** newline (`a\nb\nc\n`). The two cancel out for single-trailing-newline input, but not for multiple: `$(printf 'a\n\n\n')` fed to `<<<` yields one line, not three.

### Exercise 6

**A6.1** Three processes and two pipes. Each pipe is created with `pipe()` before forking; the writing process keeps the write end as fd 1 and closes the read end, the reading process keeps the read end as fd 0 and closes the write end. Closing the unused ends is essential — if the reader kept a copy of the write end open, it would never see EOF and the pipeline would hang. Bash runs all three in a subshell by default, which is the root cause of Exercise 7.

**A6.2** `141 = 128 + 13`. The shell reports a signal-terminated child as `128 + signal number`, and `SIGPIPE` is signal 13. `yes` wrote to a pipe whose read end had closed, the kernel delivered `SIGPIPE`, and the default disposition is terminate. This is a normal, healthy end for the upstream half of `… | head`; scripts using `set -o pipefail` must be prepared to see 141 and not treat it as an error.

**A6.3** Bash sets `PIPESTATUS` after **every** pipeline, and a simple command such as `echo "last=$?"` is a one-element pipeline. That `echo` succeeded, so `PIPESTATUS` was overwritten with `(0)`. Always copy it in the very next command: `st=("${PIPESTATUS[@]}")`.

**A6.4** glibc's stdio calls `isatty(1)` on first use: a terminal gets **line** buffering, anything else (pipe, file) gets **full** buffering with a ~4 KiB buffer. Adding `| cat` turned `grep`'s stdout into a pipe, so nothing flushed until exit. `stdbuf -oL cmd` forces line buffering on a program without its own flag (it works by preloading `libstdbuf.so`, so it has no effect on statically linked binaries or on programs that set their own buffering explicitly, such as `dd`).

**A6.5** `cmd | grep error 2>&1` redirects **grep's** stderr onto grep's stdout — `cmd`'s stderr goes straight to the terminal, unfiltered and unlogged. It is a bug because the redirection is attached to the wrong process: `2>&1` must appear on the command whose stderr you want, and it must come *before* the `|`.

### Exercise 7

**A7.1** Every command in a pipeline runs in a **subshell** (a forked child). The `while` loop incremented `count` in that child's address space; when the child exited, the variable died with it. The parent's `count` was never touched. Variables cannot propagate upward across a `fork()` — only exit status and written data can.

**A7.2** With job control enabled, Bash puts the whole pipeline into its own process group so it can be suspended and resumed as a unit; the shell itself cannot join that group without giving up control of the terminal. `lastpipe` requires the last command to run in the *current* shell process, which is incompatible with that. Hence it only takes effect in non-interactive shells, or after `set +m`.

**A7.3** `ksh93` (and `zsh`) run the **last** stage of a pipeline in the current shell; Bash forks it like every other stage unless `lastpipe` is set. A portable script must therefore never depend on side effects from the last stage — feed the loop with `< file` or `< <(cmd)` instead, which involves no pipeline at all.

### Exercise 8

**A8.1** Redirection and piping compete for the same descriptor. In `seq 1 5 > five.txt | wc -l`, fd 1 is first pointed at the pipe by the pipeline machinery and then overridden by `> five.txt`; `wc -l` inherits a pipe that nobody writes to, sees immediate EOF and prints `0`. `tee` is a real process that reads stdin once and `write()`s the same buffer to each output file *and* to its own stdout — a duplication that redirection alone cannot express.

**A8.2** The **shell** opens the file, before `sudo` is even executed, and it does so with your unprivileged UID — hence `Permission denied`. In the `tee` form, `sudo` is the process that execs `tee`, so `tee` runs as root and *it* opens the file. The general rule: `sudo` elevates the command, never the surrounding shell syntax.

**A8.3** `tee` always echoes its input to stdout as well. Without `> /dev/null` you get the content printed to the terminal (step 4) or forwarded to the next stage / terminal (step 5), which is noise at best and duplicated data at worst.

**A8.4** Process substitution creates an asynchronous child; the parent shell does **not** wait for it. `tee` can finish and the shell can return to the prompt while `grep -c` is still writing `count.txt`. Without the delay you read a file that does not exist yet or is half-written — a classic race that appears only under load or on slow storage. Robust fixes: capture the PID from `$!` where possible, use a temp file plus `mv` for atomicity, or restructure to avoid process substitution when ordering matters.

**A8.5** It returns `grep`'s status (the last command). To get `cmd`'s, use `set -o pipefail` (the pipeline then returns the rightmost non-zero status) or read `${PIPESTATUS[0]}` immediately after the pipeline.

### Exercise 9

**A9.1** By default `xargs` splits on **blanks (spaces and tabs) and newlines**, and additionally honours single quotes, double quotes and backslash escapes. `./my report.txt` became two arguments, so `ls` received `./my` and `report.txt`.

**A9.2** Quoting cannot help, because `find` emits raw filenames and `xargs` re-parses them — there is no quoting convention shared between the two. NUL (`\0`) is the correct separator because it is the C string terminator and therefore the **only** byte that cannot appear in a Linux filename; the other forbidden byte is `/`, which is the path separator. Newlines, quotes, spaces and backslashes are all perfectly legal in filenames, which is why any newline-based pipeline is only approximately correct.

**A9.3** `-I` implicitly sets `-L 1` (one input line per command invocation) and disables `-n`/`-L` batching. Over 50 000 items that means 50 000 `fork()`+`execve()` pairs instead of a handful of batched invocations — often two orders of magnitude slower. Use `-I` only when the placeholder position genuinely requires it; otherwise let `xargs` batch.

**A9.4** `-exec rm {} \;` runs **one `rm` per file**. `-exec rm {} +` batches filenames up to `ARG_MAX`, running very few `rm` processes — this is equivalent in process count to `-print0 | xargs -0 rm`, and it is also safer because no separator parsing happens at all. Prefer `-exec … +` when `find` alone suffices; use `xargs` when you need `-P`, `-I`, or a non-`find` producer.

**A9.5** Command substitution builds a **single** argument vector and hands it to `execve()`, which enforces the `MAX_ARG_STRLEN`/`ARG_MAX` limit (typically 2 MiB total for argv+envp on Linux). `xargs` reads the list incrementally and splits it into **multiple** invocations that each fit under the limit, transparently. `xargs --show-limits` prints the actual computed ceiling on your system.

**A9.6**
- **123** — one or more command invocations exited with status 1–125.
- **124** — the command exited with status 255 (treated as "stop immediately").
- **125** — the command was killed by a signal.
- **126** — the command was found but could not be executed (e.g. not executable).
- **127** — the command could not be found.
Anything else is `xargs`' own error (1). Note that `123` is *not* the failing command's status, so scripts must not compare against 1.

### Exercise 10

**A10.1** Use `$(cmd)` when you need the command's output **as text** (a value to assign, compare or interpolate). Use `<(cmd)` when a program demands a **filename** and you want to hand it a stream instead of creating a temp file.

**A10.2** Backticks do not nest without escaping, and they process backslashes differently. `$(du -sh "$(dirname "$(readlink -f "$0")")")` is straightforward; the backtick equivalent requires escalating backslash escapes at each level and becomes unreadable and error-prone. `$(...)` is also POSIX and is what every style guide mandates.

**A10.3** `/dev/fd/63` is a symlink (via `/proc/self/fd`) to the **read end of an anonymous pipe**. Pipes are not seekable: `lseek()` returns `ESPIPE`. Any tool that seeks — `tail -c` on some implementations, `sort` with certain temp strategies, `mediainfo`, `unzip` — will fail or silently misbehave. On systems without `/dev/fd`, Bash falls back to FIFOs, which are seekable-in-name-only and add a filesystem object.

**A10.4** Unquoted `$(find ...)` undergoes word splitting on `$IFS` **and** glob expansion, so `two words.txt` becomes two iterations and a file literally named `*` matches everything. Quoting it as `"$(find ...)"` prevents splitting entirely, so the loop runs **once** with all filenames concatenated into a single string — equally wrong. Only a NUL-delimited stream is unambiguous, and `read -r -d ''` sets the delimiter to NUL (`-r` additionally disables backslash interpretation, `IFS=` prevents leading/trailing whitespace being stripped).

### Exercise 11

**A11.1** `exec 3> app.log` opens the file on a **new, otherwise unused** descriptor and leaves fds 0/1/2 untouched — you opt in per command with `>&3`. `exec > app.log` replaces the **shell's own stdout** for the rest of the script; every subsequent command inherits it, with no way to get the terminal back unless you saved a copy first.

**A11.2** `exec 1>&3` restores stdout from the saved copy; `3>&-` closes the now-redundant descriptor. It matters because every `fork()`ed child inherits open descriptors: a leaked fd 3 pointing at a file keeps that file's inode alive even after deletion (space is not reclaimed), can be written to accidentally by a child that expects fd 3 to be free, and shows up in `lsof` as a mystery handle. Long-running daemons that leak descriptors eventually hit `RLIMIT_NOFILE` and fail with `EMFILE`.

**A11.3** `exec >> file 2>&1` inside the script captures output from **everything the script does**, including anything before/after individual commands and any child that inherits the descriptors, and it works regardless of how the script was invoked — manually, from `systemd`, from `cron`, from another script. Redirecting in the crontab line only covers that one invocation, is easy to omit when the entry is edited, and the crontab syntax makes `%` a line-break metacharacter that silently mangles redirections containing it.

**A11.4** Avoid 0, 1, 2 (the standard streams) and be careful with **255**, which Bash uses internally for its own bookkeeping in some contexts; descriptors above `ulimit -n` are unavailable. Hardcoding `3` is fragile because a caller, a sourced library, or a wrapping tool may already be using it, and you would silently clobber it. `exec {logfd}>file` lets Bash allocate a free descriptor and store the number in `$logfd`; close it with `exec {logfd}>&-`.

### Exercise 12

**A12.1** The permission bits on the `/proc/PID/fd/N` symlink reflect how the descriptor was opened. fd 1 was opened `O_WRONLY` by the shell for `> /tmp/sleep.out`, so it shows write-only (`l-wx`). fd 0 was inherited from the terminal, which is opened read-write (`lrwx`).

**A12.2** The number in `pipe:[123456]` is the pipe's **inode**. Find every process holding it: `lsof 2>/dev/null | grep 123456` (the `FD` column shows `0r` for the reader and `1w` for the writer), or scan `/proc/*/fd` with `ls -l /proc/*/fd 2>/dev/null | grep 'pipe:\[123456\]'`. This is the standard way to diagnose a hung pipeline — a stuck reader shows up as a writer blocked in `pipe_write` (check `/proc/PID/stack` or `/proc/PID/wchan`).

**A12.3**
- Line 1: `2>&1 >> /tmp/deploy.log` has the redirections in the wrong order. fd 2 is duplicated from the terminal *before* fd 1 is moved to the log, so warnings go to the screen and only stdout is logged. Correct: `>> /tmp/deploy.log 2>&1`.
- Line 2: `$?` after the pipeline reports `grep`'s status, not `noisy.sh`'s. A failing `noisy.sh` that still emits the matching text would be reported as success.

**A12.4** `set -o pipefail`, which makes the pipeline return the status of the **rightmost command that exited non-zero** — here `noisy.sh`'s 3. Without it the pipeline would have returned `grep`'s 0, hiding the failure entirely. `${PIPESTATUS[*]}` gives you the per-stage breakdown (`3 0`) either way.

**A12.5** The file is unlinked from the directory tree but the daemon still holds an open descriptor, so the inode — and its blocks — are not freed. Locate it with `lsof +L1` (files with link count 0) or `lsof -p PID | grep deleted`; the `SIZE` column shows the space consumed. Recover the content by copying through the still-open descriptor: `cp /proc/PID/fd/N /var/log/recovered.log`. To reclaim the space without a restart, truncate through the same path: `: > /proc/PID/fd/N` (`truncate -s0` on the `/proc` path works too). A restart also frees it, but only because it closes the descriptor — the same effect, with downtime.

</details>

---

## Sources

- LPI — *Exam 101-500 Objectives*, topic 103.4 "Use streams, pipes and redirects": <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Bash Reference Manual — *Redirections* (including `>|`, `&>`, `<<`, `<<<`, `{varname}>`): <https://www.gnu.org/software/bash/manual/bash.html#Redirections>
- GNU Bash Reference Manual — *Pipelines* and `PIPESTATUS`: <https://www.gnu.org/software/bash/manual/bash.html#Pipelines>
- GNU Bash Reference Manual — *Process Substitution* and *Command Substitution*: <https://www.gnu.org/software/bash/manual/bash.html#Process-Substitution>
- GNU Coreutils Manual — `tee` invocation: <https://www.gnu.org/software/coreutils/manual/html_node/tee-invocation.html>
- GNU Findutils Manual — `xargs` options and exit status: <https://www.gnu.org/software/findutils/manual/html_node/find_html/xargs-options.html>
- POSIX.1-2024 (IEEE 1003.1) — Shell Command Language, *Redirection*: <https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_07>
- Linux man-pages — `pipe(7)`: <https://man7.org/linux/man-pages/man7/pipe.7.html>
- Linux man-pages — `proc_pid_fd(5)`: <https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html>
- Linux man-pages — `null(4)`: <https://man7.org/linux/man-pages/man4/null.4.html>