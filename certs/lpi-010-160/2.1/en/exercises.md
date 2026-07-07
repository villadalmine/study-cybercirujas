# Guided Exercises — Topic 2.1: Command Line Basics

**Certification:** LPI Linux Essentials (010-160, version 1.6) · **Weight:** 3
**Reference:** [LPI Learning Materials, Lesson 2.1](https://learning.lpi.org/en/learning-materials/010-160/2/2.1/)

Work through each block in a terminal. Type every command yourself — don't copy and paste. After each block, answer the questions before moving on. All answers are collapsed at the end.

---

## Exercise 1 — Anatomy of a Command

Every command line follows the same general structure: **command**, then **options** (which modify behavior), then **arguments** (what the command acts on).

1. Open a terminal and run the command with no options or arguments:
   ```bash
   uname
   ```
2. Now add an option:
   ```bash
   uname -a
   ```
3. Run a command with an argument:
   ```bash
   ls /etc
   ```
4. Combine an option and an argument:
   ```bash
   ls -l /etc
   ```
5. Try a long-form option (long options start with `--`):
   ```bash
   ls --help
   ```

**Questions:**

- **Q1.1** — In the command `ls -l /etc`, identify the command, the option, and the argument.
- **Q1.2** — What changed in the output of `uname` when you added `-a`?
- **Q1.3** — What is the difference in form between a short option and a long option? Give one example of each from this exercise.

---

## Exercise 2 — Finding Out What You're Running

The shell is itself a program. Most Linux distributions use **Bash** (Bourne Again Shell) as the default.

1. Display which shell you are currently using:
   ```bash
   echo $SHELL
   ```
2. Print your username using another variable:
   ```bash
   echo $USER
   ```
3. Check what kind of command `echo` is:
   ```bash
   type echo
   ```
4. Compare with a command that lives on disk:
   ```bash
   type ls
   ```

**Questions:**

- **Q2.1** — What is the difference between an *internal (builtin)* command and an *external* command?
- **Q2.2** — Based on the output of step 3 and step 4, which of `echo` and `ls` is a shell builtin?
- **Q2.3** — `$SHELL` and `$USER` are examples of what kind of variable?

---

## Exercise 3 — Variables

Variables store values. **Shell variables** exist only in the current shell; **environment variables** are also passed to programs the shell starts.

1. Create a shell variable (no spaces around `=`):
   ```bash
   greeting='hello world'
   ```
2. Display its value:
   ```bash
   echo $greeting
   ```
3. Start a child shell and try to read the variable there:
   ```bash
   bash
   echo $greeting
   ```
   Then leave the child shell:
   ```bash
   exit
   ```
4. Now export the variable to the environment and test again:
   ```bash
   export greeting
   bash
   echo $greeting
   exit
   ```
5. Remove the variable:
   ```bash
   unset greeting
   echo $greeting
   ```

**Questions:**

- **Q3.1** — Why did `echo $greeting` print nothing the first time you ran it inside the child shell (step 3)?
- **Q3.2** — What does `export` do?
- **Q3.3** — What happens if you write `greeting = 'hello'` with spaces around the equals sign? Try it and explain the error.

---

## Exercise 4 — The PATH Variable

When you type a command name, the shell searches the directories listed in the `PATH` environment variable, in order, to find the executable.

1. Display your search path:
   ```bash
   echo $PATH
   ```
2. Find where the `ls` executable lives:
   ```bash
   which ls
   ```
3. Try running a program that exists but is *not* in your `PATH`. First create one:
   ```bash
   mkdir -p ~/mybin
   echo 'echo it works' > ~/mybin/hello.sh
   chmod +x ~/mybin/hello.sh
   hello.sh
   ```
   (The last command should fail.)
4. Add the directory to your `PATH` and try again:
   ```bash
   PATH="$PATH:$HOME/mybin"
   hello.sh
   ```

**Questions:**

- **Q4.1** — What character separates the directories inside `PATH`?
- **Q4.2** — Why did `hello.sh` fail in step 3 but succeed in step 4?
- **Q4.3** — In step 4, why is it important to write `PATH="$PATH:..."` instead of just `PATH="$HOME/mybin"`?

---

## Exercise 5 — Quoting

Quoting controls how the shell interprets special characters like `$`, `*`, and spaces before running the command.

1. Set up a test variable:
   ```bash
   export planet=Mars
   ```
2. Run the same `echo` with three quoting styles and compare:
   ```bash
   echo Hello $planet
   echo "Hello $planet"
   echo 'Hello $planet'
   ```
3. Use the escape character to protect a single character:
   ```bash
   echo "The variable is called \$planet"
   ```
4. See why quoting matters for spaces:
   ```bash
   mkdir "test dir"
   ls -l test dir
   ls -l "test dir"
   ```
5. Clean up:
   ```bash
   rmdir "test dir"
   unset planet
   ```

**Questions:**

- **Q5.1** — What is the difference between double quotes (`"`) and single quotes (`'`) with respect to variables?
- **Q5.2** — In step 3, what does the backslash (`\`) do?
- **Q5.3** — In step 4, why did `ls -l test dir` produce errors while `ls -l "test dir"` worked?

---

## Exercise 6 — Command History

The shell remembers the commands you've typed so you can reuse them.

1. Show your recent commands:
   ```bash
   history
   ```
2. Press the **Up arrow** key a few times to walk back through previous commands, then **Down arrow** to come forward. Press `Enter` on one to re-run it.
3. Re-run a specific command by its number from the `history` list (replace `42` with a real number from your output):
   ```bash
   !42
   ```
4. Re-run the most recent command:
   ```bash
   !!
   ```
5. Find out where your history is stored across sessions:
   ```bash
   echo $HISTFILE
   ```

**Questions:**

- **Q6.1** — What does `!!` do?
- **Q6.2** — In which file does Bash typically save your command history between sessions?
- **Q6.3** — What does `!42` mean?

---

## Exercise 7 — Putting It Together

1. In one command line, run two commands one after the other using `;` as a separator:
   ```bash
   uname -a; echo $USER
   ```
2. Write a command that prints exactly this line, dollar sign included:
   ```
   PATH is $PATH
   ```
3. Without typing it again, re-run the command from step 2 using history.

**Questions:**

- **Q7.1** — What does the `;` do on a command line?
- **Q7.2** — Write two different commands (using two different quoting techniques) that both print the literal text `PATH is $PATH`.

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

### Exercise 1

- **A1.1** — Command: `ls`. Option: `-l` (long listing format). Argument: `/etc` (the directory to list).
- **A1.2** — Plain `uname` prints only the kernel name (`Linux`). With `-a` (all), it prints extended system information: kernel name, hostname, kernel release and version, machine architecture, and operating system.
- **A1.3** — Short options are a single dash followed by one letter (`-l`, `-a`) and can often be combined (`-la`). Long options are two dashes followed by a word (`--help`). Examples from this exercise: `-a` (short) and `--help` (long).

### Exercise 2

- **A2.1** — An internal (builtin) command is part of the shell itself and executes without launching a separate program. An external command is a separate executable file stored on disk (for example in `/usr/bin`) that the shell must locate via `PATH` and run as a new process.
- **A2.2** — `echo` is a shell builtin (`type echo` reports "echo is a shell builtin"). `ls` is external (`type ls` shows a filesystem path such as `/usr/bin/ls`, or an alias that ultimately points to it).
- **A2.3** — They are **environment variables**: variables set by the system/shell and available to programs started from the shell. By convention their names are uppercase.

### Exercise 3

- **A3.1** — `greeting` was created as a plain shell variable, so it existed only in the shell where it was defined. Child processes (like the second `bash`) receive only *environment* variables, and `greeting` had not been exported yet.
- **A3.2** — `export` marks a shell variable as an environment variable, so it is copied into the environment of every child process the shell starts from that point on.
- **A3.3** — The shell reports an error such as `greeting: command not found`. With spaces, Bash interprets `greeting` as a command name and `=` and `'hello'` as its arguments. Variable assignment in the shell must be written with no spaces: `name=value`.

### Exercise 4

- **A4.1** — The colon (`:`).
- **A4.2** — In step 3, `~/mybin` was not listed in `PATH`, so the shell could not find `hello.sh` (you could still have run it with an explicit path like `~/mybin/hello.sh`). In step 4, the directory was appended to `PATH`, so the shell's search found the executable by name.
- **A4.3** — `PATH="$PATH:..."` *appends* the new directory while keeping all the existing ones. Writing `PATH="$HOME/mybin"` would *replace* the whole path, and the shell would no longer find standard commands like `ls` or `cat`.

### Exercise 5

- **A5.1** — Double quotes prevent most special-character interpretation but **still expand variables** (`$planet` becomes `Mars`). Single quotes prevent **all** interpretation, so `$planet` is printed literally.
  - `echo Hello $planet` → `Hello Mars`
  - `echo "Hello $planet"` → `Hello Mars`
  - `echo 'Hello $planet'` → `Hello $planet`
- **A5.2** — The backslash is the escape character: it removes the special meaning of the single character that follows it. Here `\$` prevents variable expansion, so the output is `The variable is called $planet` even inside double quotes.
- **A5.3** — Without quotes, the shell splits the line on spaces and passes **two** arguments to `ls`: `test` and `dir` — neither of which exists as a separate file, so `ls` prints "No such file or directory" for each. With quotes, `test dir` is passed as a **single** argument matching the actual directory name.

### Exercise 6

- **A6.1** — `!!` re-executes the most recent command from the history.
- **A6.2** — In `~/.bash_history` (the file named by the `HISTFILE` variable), written when the shell session ends.
- **A6.3** — It re-executes the command stored at position 42 in the history list.

### Exercise 7

- **A7.1** — The semicolon separates multiple commands on a single line; they run sequentially, one after the other, regardless of whether the previous one succeeded.
- **A7.2** — Two possibilities:
  ```bash
  echo 'PATH is $PATH'        # single quotes: no expansion at all
  echo "PATH is \$PATH"       # double quotes + escaped dollar sign
  ```
  (To re-run it via history: press the Up arrow, or use `!!` immediately after, or `!<n>` with its history number.)

</details>

---

*Reference used for topic scope: LPI Learning Materials, Linux Essentials 010-160, Lesson 2.1 — https://learning.lpi.org/en/learning-materials/010-160/2/2.1/*