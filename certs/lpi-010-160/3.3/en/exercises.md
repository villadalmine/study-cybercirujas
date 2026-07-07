# Guided Exercises — Topic 3.3: Turning Commands into a Script

**Certification:** LPI Linux Essentials (010-160, v1.6) · **Exam weight:** 4

Work through each block in a terminal. Type every command yourself — don't copy-paste — and observe the output before answering the questions.

---

## Exercise 1: Your first script

A shell script is nothing more than a text file containing commands you could have typed at the prompt. Let's prove it.

1. Create a working directory and move into it:
   ```bash
   mkdir ~/script-lab
   cd ~/script-lab
   ```
2. Run these three commands interactively and watch their output:
   ```bash
   echo "System report"
   date
   whoami
   ```
3. Now put the same commands into a file. Open a text editor — `nano` is the friendliest to start with:
   ```bash
   nano report.sh
   ```
   Type the following, then save and exit (`Ctrl+O`, Enter, `Ctrl+X` in nano):
   ```bash
   #!/bin/bash

   # report.sh - print a tiny system report
   echo "System report"
   date
   whoami
   ```
4. Run the script by handing the file to the interpreter:
   ```bash
   bash report.sh
   ```
5. Try to run it directly, like a real command:
   ```bash
   ./report.sh
   ```
   You should get `Permission denied`.
6. Look at the file's permissions, add execute permission, and try again:
   ```bash
   ls -l report.sh
   chmod +x report.sh
   ls -l report.sh
   ./report.sh
   ```

**Questions**

- **1a.** What is the very first line, `#!/bin/bash`, called, and what does the kernel use it for when you run `./report.sh`?
- **1b.** In step 4 the script ran fine *without* execute permission, but in step 5 it didn't. Why does `bash report.sh` work when `./report.sh` fails?
- **1c.** The line `# report.sh - print a tiny system report` starts with `#`. What does bash do with it? Why is `#!/bin/bash` on line 1 not ignored the same way?
- **1d.** Why do you have to type `./report.sh` instead of just `report.sh`, even though the file is right there in your current directory?

---

## Exercise 2: Variables

Variables let a script store a value once and reuse it, and command substitution lets it capture a command's output.

1. Create `vars.sh` with your editor (or with `cat`, as shown):
   ```bash
   cat > vars.sh << 'EOF'
   #!/bin/bash

   GREETING="Hello"
   PLANET=Earth
   TODAY=$(date +%Y-%m-%d)

   echo "$GREETING, $PLANET!"
   echo "Today is $TODAY"
   echo 'Today is $TODAY'
   EOF
   chmod +x vars.sh
   ./vars.sh
   ```
2. Compare the last two lines of output carefully.
3. Now break it on purpose. Edit `vars.sh` and change `GREETING="Hello"` to `GREETING = "Hello"` (spaces around the `=`), then run it again and read the error message. Fix it back afterwards.

**Questions**

- **2a.** In `TODAY=$(date +%Y-%m-%d)`, what does the `$( ... )` construct do?
- **2b.** Why did the double-quoted `echo "Today is $TODAY"` print the date, while the single-quoted version printed the literal text `$TODAY`?
- **2c.** What error did step 3 produce, and why does bash misread `GREETING = "Hello"`?
- **2d.** When you *assign* a variable you write `TODAY=...`, but when you *use* it you write `$TODAY`. What is the `$` for?

---

## Exercise 3: Arguments — making scripts flexible

Hard-coding values limits a script to one job. Positional parameters let the caller pass information in.

1. Create `greet.sh`:
   ```bash
   cat > greet.sh << 'EOF'
   #!/bin/bash

   echo "Script name : $0"
   echo "First arg   : $1"
   echo "Second arg  : $2"
   echo "Arg count   : $#"
   echo "All args    : $@"
   EOF
   chmod +x greet.sh
   ```
2. Run it several times with different inputs:
   ```bash
   ./greet.sh
   ./greet.sh Ana
   ./greet.sh Ana Bruno Carla
   ./greet.sh "Ana Bruno" Carla
   ```
3. Study how `$#` and `$1` change between the last two runs.

**Questions**

- **3a.** What do `$0`, `$1`, `$#`, and `$@` each contain?
- **3b.** In the last run, why is the argument count 2 and not 3, even though three words appear on the command line?
- **3c.** In the first run, `$1` printed as an empty string rather than causing an error. What risk does that create in a script that does something destructive with `$1` (for example, `rm -r "$1"`)?

---

## Exercise 4: Exit status — how commands report success

Every command finishes with an exit status: `0` means success, anything from 1 to 255 means some kind of failure. Scripts and the shell use it to make decisions.

1. Run a command that succeeds, then inspect the special variable `$?`:
   ```bash
   ls /etc > /dev/null
   echo $?
   ```
2. Run a command that fails, and check again:
   ```bash
   ls /nonexistent
   echo $?
   echo $?
   ```
   Note what the *second* `echo $?` prints.
3. `grep` uses its exit status to say whether it found anything:
   ```bash
   grep root /etc/passwd > /dev/null; echo $?
   grep zzzz /etc/passwd > /dev/null; echo $?
   ```
4. The operators `&&` and `||` chain commands based on exit status:
   ```bash
   grep root /etc/passwd > /dev/null && echo "found"
   grep zzzz /etc/passwd > /dev/null || echo "not found"
   ```
5. A script can choose its own exit status with `exit`:
   ```bash
   cat > check.sh << 'EOF'
   #!/bin/bash
   grep -q "$1" /etc/passwd
   exit $?
   EOF
   chmod +x check.sh
   ./check.sh root; echo $?
   ./check.sh zzzz; echo $?
   ```

**Questions**

- **4a.** What exit status conventionally means success, and how do you read the exit status of the most recent command?
- **4b.** In step 2, what did the second `echo $?` print, and why?
- **4c.** In your own words: when does `cmd1 && cmd2` run `cmd2`, and when does `cmd1 || cmd2` run `cmd2`?
- **4d.** In `check.sh`, what would happen if you forgot the `exit $?` line — what exit status would the script report, and why does it still work here?

---

## Exercise 5: Making decisions with if

`if` runs a command and branches on its exit status. The `test` command (usually written as `[ ... ]`) exists precisely to be that command.

1. Experiment with `test` directly at the prompt:
   ```bash
   test 5 -gt 3; echo $?
   test 5 -gt 7; echo $?
   [ -f /etc/passwd ]; echo $?
   [ -d /etc/passwd ]; echo $?
   ```
2. Now use it inside a script. Create `checkfile.sh`:
   ```bash
   cat > checkfile.sh << 'EOF'
   #!/bin/bash

   if [ $# -eq 0 ]
   then
       echo "Usage: $0 <file>"
       exit 1
   fi

   if [ -f "$1" ]
   then
       echo "$1 exists and is a regular file"
   else
       echo "$1 is not a regular file"
   fi
   EOF
   chmod +x checkfile.sh
   ```
3. Test all three paths:
   ```bash
   ./checkfile.sh
   echo $?
   ./checkfile.sh /etc/passwd
   ./checkfile.sh /etc
   ```

**Questions**

- **5a.** How does `if` decide whether to run the `then` branch or the `else` branch?
- **5b.** What do the test operators `-f`, `-d`, `-eq`, and `-gt` each check?
- **5c.** Why does the script `exit 1` (and not `exit 0`) when called with no arguments?
- **5d.** The spaces inside `[ -f "$1" ]` are mandatory — `[-f "$1"]` fails. Why? (Hint: what kind of thing is `[`?)

---

## Exercise 6: Repeating work with for loops

A `for` loop runs the same block of commands once for each item in a list.

1. Try a loop at the prompt with a literal list:
   ```bash
   for name in Ana Bruno Carla
   do
       echo "Hello, $name"
   done
   ```
2. The list can come from a glob. Create some files and loop over them:
   ```bash
   touch data1.txt data2.txt data3.txt
   for f in *.txt
   do
       echo "Processing $f ..."
       wc -c "$f"
   done
   ```
3. The list can also come from a command. Loop over the first three account names in `/etc/passwd`:
   ```bash
   for user in $(cut -d ':' -f 1 /etc/passwd | head -n 3)
   do
       echo "Account: $user"
   done
   ```
4. Inside a script, looping over `$@` processes every argument:
   ```bash
   cat > sizes.sh << 'EOF'
   #!/bin/bash
   for f in "$@"
   do
       if [ -f "$f" ]
       then
           echo "$f: $(wc -c < "$f") bytes"
       else
           echo "$f: skipped (not a regular file)"
       fi
   done
   EOF
   chmod +x sizes.sh
   ./sizes.sh *.txt /etc greet.sh
   ```

**Questions**

- **6a.** In step 1, how many times does the body between `do` and `done` execute, and what determines that number?
- **6b.** In step 2, who expands `*.txt` into the list of filenames — the `for` loop or the shell? When does that expansion happen?
- **6c.** In `sizes.sh`, the loop variable is used as `"$f"` with double quotes. What could go wrong with an unquoted `$f` if a filename contained a space?

---

## Exercise 7: Putting it all together

Combine the shebang, arguments, exit status, `if`, and `for` into one small, genuinely useful tool: a batch backup script.

1. Create `backup.sh`:
   ```bash
   cat > backup.sh << 'EOF'
   #!/bin/bash

   # backup.sh - copy each given file to <name>.bak
   if [ $# -eq 0 ]
   then
       echo "Usage: $0 <file> [more files...]"
       exit 1
   fi

   COUNT=0
   for f in "$@"
   do
       if [ -f "$f" ]
       then
           cp "$f" "$f.bak"
           echo "Backed up: $f -> $f.bak"
           COUNT=$((COUNT + 1))
       else
           echo "Skipping: $f (not a regular file)"
       fi
   done

   echo "$COUNT file(s) backed up on $(date +%Y-%m-%d)"
   EOF
   chmod +x backup.sh
   ```
2. Exercise every path through the script:
   ```bash
   ./backup.sh
   echo $?
   ./backup.sh data1.txt data2.txt /etc nosuchfile
   ls *.bak
   ```
3. Optional: open the script once more in a different editor to get a feel for it — `vi backup.sh` (press `i` to edit, `Esc` then `:q!` to leave without saving).

**Questions**

- **7a.** Trace the run `./backup.sh data1.txt /etc nosuchfile`: for each of the three arguments, which branch of the inner `if` executes, and what is the final value of `COUNT`?
- **7b.** The script validates `$#` *before* doing any work. What exit status does the caller see when the usage message is printed, and how could another script use that fact with `||`?
- **7c.** Name the two text editors the Linux Essentials objectives expect you to be aware of, and one practical difference between them for a beginner.
- **7d.** Nothing in this script was new — every construct came from Exercises 1–6. List the five building blocks it combines.

---

<details>
<summary><strong>Answers</strong></summary>

- **1a.** It's the *shebang* (also written `#!`). When you execute the file directly, the kernel reads that first line and launches the named interpreter — here `/bin/bash` — passing it the script to run. It guarantees the script runs under the interpreter it was written for.
- **1b.** With `bash report.sh` you are executing `bash` (which is already executable) and the script is merely a file it reads, so only *read* permission on the file is needed. With `./report.sh` you are asking the kernel to execute the file itself, which requires the *execute* permission bit.
- **1c.** Lines starting with `#` are comments — bash ignores them completely. `#!` on line 1 is also a comment as far as bash is concerned, but the *kernel* inspects those first two characters when the file is executed directly, which is why the shebang still has an effect.
- **1d.** For safety, the current directory is not in the `PATH` variable, the list of directories the shell searches for commands. `./report.sh` gives an explicit path, so no `PATH` search is needed.

- **2a.** Command substitution: the shell runs the command inside `$( ... )`, captures its standard output, and substitutes it in place — so `TODAY` receives the formatted date string.
- **2b.** Double quotes allow variable expansion (the shell replaces `$TODAY` with its value); single quotes suppress *all* expansion, so the characters `$TODAY` are printed literally.
- **2c.** Something like `GREETING: command not found`. With spaces, bash parses `GREETING` as a command name and `=` and `"Hello"` as its arguments. Variable assignment in shell must be written with no spaces around `=`.
- **2d.** `$` triggers expansion — it tells the shell "replace this with the variable's value". At assignment time there is nothing to expand: you are naming the variable, not reading it.

- **3a.** `$0` is the name the script was invoked with; `$1` is the first argument (and `$2` the second, and so on); `$#` is the number of arguments; `$@` expands to all arguments.
- **3b.** The quotes around `"Ana Bruno"` make the shell deliver it as a single argument containing a space. The script receives 2 arguments: `Ana Bruno` and `Carla`.
- **3c.** Unset positional parameters silently expand to nothing. `rm -r "$1"` with no argument becomes `rm -r ""` (or worse patterns in sloppier scripts), so a careful script checks `$#` first and prints a usage message instead of acting on an empty value.

- **4a.** `0` means success; any non-zero value (1–255) signals failure. The special variable `$?` holds the exit status of the most recently executed command.
- **4b.** It printed `0`. `$?` always refers to the *immediately previous* command — which by then was the first `echo`, and that `echo` succeeded. Exit status is consumed fresh each time.
- **4c.** `cmd1 && cmd2` runs `cmd2` only if `cmd1` *succeeded* (exit status 0). `cmd1 || cmd2` runs `cmd2` only if `cmd1` *failed* (non-zero).
- **4d.** The same thing: without an explicit `exit`, a script exits with the status of its last command — here the `grep`. Writing `exit $?` just makes that intent explicit.

- **5a.** `if` runs the command after it and checks its exit status: 0 selects the `then` branch, non-zero selects the `else` branch (or skips the block if there is no `else`).
- **5b.** `-f` — the operand exists and is a regular file; `-d` — it exists and is a directory; `-eq` — two integers are equal; `-gt` — the first integer is greater than the second.
- **5c.** Being called without arguments is an error condition, and by convention errors are reported with a non-zero exit status so callers (scripts, `&&`/`||` chains) can detect the failure. `exit 0` would falsely claim success.
- **5d.** `[` is not syntax — it is a command (another name for `test`) whose last argument must be `]`. Like any command it must be separated from its arguments by spaces; `[-f` would be looked up as a single, nonexistent command name.

- **6a.** Three times — once per item in the list after `in` (`Ana`, `Bruno`, `Carla`). The list length determines the iteration count.
- **6b.** The shell expands the glob *before* the loop ever runs, replacing `*.txt` with the matching filenames; `for` just receives the resulting word list.
- **6c.** Unquoted, the value of `$f` undergoes word splitting: a name like `my file.txt` would be passed to `wc` as two separate arguments (`my` and `file.txt`), making the command fail or act on the wrong files. Quoting keeps each filename intact.

- **7a.** `data1.txt` is a regular file → the `then` branch runs and it's copied to `data1.txt.bak`; `/etc` is a directory → `else` branch, skipped; `nosuchfile` doesn't exist → `else` branch, skipped. `COUNT` ends at 1.
- **7b.** The caller sees exit status 1. Another script could react with something like `./backup.sh "$f" || echo "backup failed" >> errors.log` — the `||` branch fires precisely because the status is non-zero.
- **7c.** `nano` and `vi`. `nano` shows its key bindings on screen and edits directly, so it's easier for beginners; `vi` is modal (separate insert and command modes, entered with `i` and `Esc`) but is installed virtually everywhere, so knowing how to exit it (`:q!`) is essential.
- **7d.** The shebang line (`#!/bin/bash`) with comments and `chmod +x` (Exercise 1); variables and command substitution (`COUNT`, `$(date ...)`) (Exercise 2); positional parameters (`$#`, `$@`, `$0`) (Exercise 3); exit statuses and `exit 1` (Exercise 4); the `if`/`test` conditional (Exercise 5) inside a `for` loop (Exercise 6).

</details>

---

**Reference:** LPI Learning Materials, Linux Essentials Topic 3.3 — *Turning Commands into a Script*: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/