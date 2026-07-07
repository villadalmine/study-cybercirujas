# 3.3 Turning Commands into a Script

**Exam weight: 4** — one of the heavier topics in the 010-160 exam. Expect several questions on shebangs, script permissions, variables, arguments, exit codes, conditionals, and loops.

---

## 1. Why Scripts?

Everything you type at the shell prompt can be stored in a file and replayed. A **shell script** is simply a plain-text file containing a sequence of commands that the shell executes from top to bottom. Scripts let you:

- **Automate** repetitive tasks (backups, cleanups, report generation).
- **Document** a procedure as executable code instead of a wiki page that goes stale.
- **Reduce errors** — the machine runs the same steps the same way every time.
- **Schedule** work to run unattended (e.g., via `cron`).

If you ever type the same three commands twice, that's a script waiting to be written.

## 2. Anatomy of a Script

### 2.1 The shebang (`#!`)

The first line of a script should be the **shebang** (also called *hashbang*): the characters `#!` followed by the absolute path of the interpreter that will execute the file.

```bash
#!/bin/bash
```

When you run the script as a program, the kernel reads this line and launches the named interpreter, passing it the script as input. Different interpreters can be used:

| Shebang | Interpreter |
|---|---|
| `#!/bin/bash` | Bash (Bourne Again Shell) — the usual choice on Linux |
| `#!/bin/sh` | The system's POSIX shell (may be a link to `bash`, `dash`, …) |
| `#!/usr/bin/env python3` | Python 3, located via the user's `PATH` |
| `#!/usr/bin/perl` | Perl |

The shebang **must be the very first line** — no blank lines or spaces before it. If it's anywhere else, `#!` is just a comment.

### 2.2 Comments

Everywhere else in the file, `#` starts a **comment**: the shell ignores everything from `#` to the end of the line. Use comments to explain *why* the script does something.

```bash
#!/bin/bash
# backup-home.sh — archive the user's home directory
# Author: you, Last updated: 2026-07-07

tar -czf /tmp/home-backup.tar.gz "$HOME"   # -z = gzip compression
```

### 2.3 A first script

Create the file with any text editor. For the exam you should be aware of the two classics:

- **`nano`** — beginner-friendly; commands are shown at the bottom (`Ctrl+O` save, `Ctrl+X` exit).
- **`vi` / `vim`** — modal editor found on virtually every Unix system (`i` to insert, `Esc` then `:wq` to save and quit).

```bash
$ nano hello.sh
```

Contents:

```bash
#!/bin/bash
# My first script
echo "Hello, world!"
```

## 3. Making a Script Executable

A freshly created file has no execute permission, so running it directly fails:

```bash
$ ./hello.sh
bash: ./hello.sh: Permission denied
```

Two ways to run it:

**Option 1 — pass it to the interpreter explicitly** (no execute bit needed, shebang ignored):

```bash
$ bash hello.sh
Hello, world!
```

**Option 2 — make it executable with `chmod`** (the standard way):

```bash
$ chmod +x hello.sh
$ ls -l hello.sh
-rwxr-xr-x 1 carol carol 52 Jul  7 10:15 hello.sh
$ ./hello.sh
Hello, world!
```

### Why `./`?

For security, the current directory (`.`) is normally **not** in the `PATH` variable, the list of directories the shell searches for commands. `./hello.sh` gives an explicit path so the shell doesn't need to search. To run a script by name alone, place it in a directory listed in `PATH` (e.g., `/usr/local/bin` or `~/bin`):

```bash
$ echo $PATH
/usr/local/bin:/usr/bin:/bin:/home/carol/bin
$ cp hello.sh ~/bin/hello
$ hello
Hello, world!
```

**Tip:** avoid naming a script after an existing command (e.g., `test` — that's a built-in and a binary). Use `which` or `type` to check first.

## 4. Producing Output: `echo` and `printf`

`echo` prints its arguments followed by a newline:

```bash
$ echo "The current directory is: $PWD"
The current directory is: /home/carol
```

Useful options:

- `echo -n` — suppress the trailing newline.
- `echo -e` — interpret escape sequences such as `\n` (newline) and `\t` (tab).

```bash
$ echo -e "Name:\tCarol\nShell:\t$SHELL"
Name:	Carol
Shell:	/bin/bash
```

`printf` offers finer format control (`printf "%s is %d years old\n" "Alice" 30`), but `echo` covers most scripting needs at this level.

## 5. Variables

### 5.1 Assigning and using variables

Assign with `NAME=value` — **no spaces around `=`**. Read the value with `$NAME`:

```bash
#!/bin/bash
username="carol"
greeting="Welcome back"
echo "$greeting, $username!"
```

```bash
$ ./welcome.sh
Welcome back, carol!
```

Rules to remember:

- Variable names may contain letters, digits, and underscores, but **cannot start with a digit**.
- `VAR = value` (with spaces) is an error — the shell thinks `VAR` is a command.
- Quote expansions (`"$var"`) so values containing spaces don't break your script.

### 5.2 Capturing command output

**Command substitution** stores a command's output in a variable, using `$(...)`:

```bash
#!/bin/bash
today=$(date +%F)
kernel=$(uname -r)
echo "Report generated on $today (kernel $kernel)"
```

```bash
$ ./report.sh
Report generated on 2026-07-07 (kernel 6.9.4-200.fc40.x86_64)
```

The older backtick syntax `` `date` `` does the same thing but is harder to read and nest; prefer `$(...)`.

### 5.3 Environment vs. shell variables

Variables you create exist only in the running script or shell. `export VAR` turns it into an **environment variable**, inherited by child processes. Common predefined ones: `$HOME`, `$USER`, `$PATH`, `$PWD`, `$SHELL`.

## 6. Arguments: Making Scripts Reusable

Scripts accept **positional parameters** — values typed after the script name:

| Variable | Meaning |
|---|---|
| `$0` | Name of the script itself |
| `$1`, `$2`, … `$9` | First, second, … ninth argument |
| `$#` | Number of arguments |
| `$@` | All arguments, as separate words |
| `$*` | All arguments, as a single word |

```bash
#!/bin/bash
# args.sh — demonstrate positional parameters
echo "Script name:     $0"
echo "First argument:  $1"
echo "Second argument: $2"
echo "Argument count:  $#"
echo "All arguments:   $@"
```

```bash
$ ./args.sh apple banana cherry
Script name:     ./args.sh
First argument:  apple
Second argument: banana
Argument count:  3
All arguments:   apple banana cherry
```

A practical example:

```bash
#!/bin/bash
# mkbackup.sh — copy a file adding a date suffix
cp "$1" "$1.$(date +%F).bak"
echo "Backup of $1 created."
```

```bash
$ ./mkbackup.sh notes.txt
Backup of notes.txt created.
$ ls notes*
notes.txt  notes.txt.2026-07-07.bak
```

## 7. Exit Codes: Did It Work?

Every command finishes with an **exit status** (also *return code*): an integer from 0 to 255.

- **`0` means success.**
- **Anything non-zero means failure** (the exact value is command-specific).

The special variable `$?` holds the exit status of the **most recently executed** command:

```bash
$ ls /etc/hostname
/etc/hostname
$ echo $?
0
$ ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory
$ echo $?
2
```

Note that `$?` is overwritten by every command — even the `echo` used to display it — so save it to a variable if you need it later.

Inside a script, `exit N` ends the script immediately with status `N`. `exit` with no argument (or reaching the end of the script) returns the status of the last command run:

```bash
#!/bin/bash
if [ ! -f "$1" ]; then
    echo "Error: file $1 not found" >&2
    exit 1        # signal failure to the caller
fi
echo "Processing $1..."
exit 0
```

Exit codes are what makes chaining with `&&` (run next only on success) and `||` (run next only on failure) work:

```bash
$ ./deploy.sh && echo "Deployed" || echo "Deploy FAILED"
```

## 8. Conditionals: `if` and `test`

### 8.1 Structure

```bash
if command; then
    # runs when the command exits with 0
elif other_command; then
    # runs when the first failed but this one succeeded
else
    # runs when everything above failed
fi
```

The condition is *any command*; its exit status decides the branch. Most often the condition is the `test` command, usually written in its bracket form `[ ... ]` (the spaces inside the brackets are mandatory).

### 8.2 Common tests

| Test | True when… |
|---|---|
| `[ -f FILE ]` | FILE exists and is a regular file |
| `[ -d DIR ]` | DIR exists and is a directory |
| `[ -r FILE ]` / `[ -w FILE ]` / `[ -x FILE ]` | FILE is readable / writable / executable |
| `[ -z "$s" ]` / `[ -n "$s" ]` | string is empty / non-empty |
| `[ "$a" = "$b" ]` / `[ "$a" != "$b" ]` | strings equal / not equal |
| `[ "$x" -eq "$y" ]` | integers equal (also `-ne`, `-lt`, `-le`, `-gt`, `-ge`) |
| `[ ! EXPR ]` | EXPR is false (negation) |

### 8.3 Example

```bash
#!/bin/bash
# checkfile.sh — report on a file passed as argument

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <filename>" >&2
    exit 1
fi

if [ -d "$1" ]; then
    echo "$1 is a directory."
elif [ -f "$1" ]; then
    echo "$1 is a regular file, $(wc -l < "$1") lines long."
else
    echo "$1 does not exist."
    exit 2
fi
```

```bash
$ ./checkfile.sh /etc
/etc is a directory.
$ ./checkfile.sh /etc/hostname
/etc/hostname is a regular file, 1 lines long.
$ ./checkfile.sh /nope; echo "exit status: $?"
/nope does not exist.
exit status: 2
```

## 9. Loops: `for`

The `for` loop runs a block of commands once for each item in a list:

```bash
for variable in list; do
    commands
done
```

**Iterating over words:**

```bash
#!/bin/bash
for fruit in apple banana cherry; do
    echo "I like $fruit"
done
```

```
I like apple
I like banana
I like cherry
```

**Iterating over files (glob):**

```bash
#!/bin/bash
for f in *.log; do
    echo "Compressing $f"
    gzip "$f"
done
```

**Iterating over script arguments:**

```bash
#!/bin/bash
for arg in "$@"; do
    echo "Argument: $arg"
done
```

**Iterating over a number range** with `seq` or brace expansion:

```bash
$ for i in $(seq 1 3); do echo "Run $i"; done
Run 1
Run 2
Run 3
```

Bash also offers `while` loops (`while [ condition ]; do ... done`), which repeat as long as a condition holds — useful for reading input line by line — but `for` is the loop emphasized at this level.

## 10. Putting It All Together

A complete script exercising every concept from this topic:

```bash
#!/bin/bash
# dirsummary.sh — summarize the contents of one or more directories
# Usage: ./dirsummary.sh DIR [DIR...]

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 DIR [DIR...]" >&2
    exit 1
fi

report="/tmp/dirsummary-$(date +%F).txt"
echo "Directory summary — $(date)" > "$report"

for dir in "$@"; do
    if [ -d "$dir" ]; then
        count=$(ls -A "$dir" | wc -l)
        echo "$dir: $count entries" >> "$report"
    else
        echo "$dir: not a directory (skipped)" >> "$report"
    fi
done

echo "Report written to $report"
cat "$report"
exit 0
```

```bash
$ chmod +x dirsummary.sh
$ ./dirsummary.sh /etc /home /nope
Report written to /tmp/dirsummary-2026-07-07.txt
Directory summary — Mon Jul  7 10:42:11 UTC 2026
/etc: 168 entries
/home: 1 entries
/nope: not a directory (skipped)
$ echo $?
0
```

## 11. Key Takeaways for the Exam

- The **shebang** (`#!/bin/bash`) must be the first line and names the interpreter.
- `#` starts a **comment** anywhere else.
- Make scripts runnable with **`chmod +x`**; run them as `./script.sh` because `.` is not in `PATH`.
- **Variables**: `name=value` (no spaces), read with `$name`; capture output with `$(command)`.
- **Positional parameters**: `$1`…`$9`, `$0` (script name), `$#` (count), `$@` (all args).
- **Exit status**: `0` = success, non-zero = failure; last status is in `$?`; set your own with `exit N`.
- **`if`/`test`**: `[ -f file ]`, `[ -d dir ]`, string (`=`, `!=`) and integer (`-eq`, `-lt`, …) comparisons; close with `fi`.
- **`for var in list; do ... done`** loops over words, globs, or `"$@"`.
- Know that **`nano`** and **`vi`** are the standard editors for writing scripts.

## Referencias

- LPI Learning Materials — Topic 3.3 *Turning Commands into a Script*: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
- LPI Linux Essentials Exam 010-160 Objectives (v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- Bash Reference Manual — Shell Scripts: https://www.gnu.org/software/bash/manual/html_node/Shell-Scripts.html
- Bash Reference Manual — Conditional Constructs: https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html
- Bash Reference Manual — Looping Constructs: https://www.gnu.org/software/bash/manual/html_node/Looping-Constructs.html
- GNU Coreutils Manual — `test`: https://www.gnu.org/software/coreutils/manual/html_node/test-invocation.html
- GNU Coreutils Manual — `echo`: https://www.gnu.org/software/coreutils/manual/html_node/echo-invocation.html
- GNU nano Documentation: https://www.nano-editor.org/docs.php
- Vim Documentation: https://www.vim.org/docs.php