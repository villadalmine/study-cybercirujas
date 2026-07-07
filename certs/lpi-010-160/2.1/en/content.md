# 2.1 Command Line Basics

**Weight:** 3
**Key knowledge areas:** Basic shell · Command line syntax · Variables · Quoting

---

## 1. What Is the Shell?

The **shell** is a program that reads the commands you type, interprets them, and asks the operating system to run them. It is the primary text-based interface to a Linux system. When you open a terminal, the shell prints a **prompt** and waits for input:

```
user@host:~$
```

A typical prompt shows the username (`user`), the hostname (`host`), the current directory (`~` means your home directory), and a final character: `$` for a regular user or `#` for the superuser (`root`).

The most common shell on Linux — and the one covered by the exam — is **Bash** (*Bourne Again Shell*), an improved successor of the original Bourne Shell (`sh`). Other shells exist (`zsh`, `ksh`, `csh`, `dash`), but Bash is the default on most distributions.

You can check which shell you are currently running:

```
$ echo $SHELL
/bin/bash
```

The shell does much more than launch programs: it expands wildcards, manages variables, keeps a command history, and can be scripted. Because it is a **command interpreter**, everything you type is processed by the shell *before* any program sees it — understanding that processing is the core of this topic.

---

## 2. Command Line Syntax

A command line follows this general structure:

```
command [options] [arguments]
```

The three parts are separated by **spaces**:

- **Command** — the program or shell builtin to execute (e.g., `ls`, `echo`).
- **Options** — modify the command's behavior. Short options use one dash and a single letter (`-l`); long options use two dashes and a word (`--all`). Short options can usually be combined: `-la` equals `-l -a`.
- **Arguments** — the objects the command acts on, typically file names or text.

Example with all three parts:

```
$ ls -l /tmp
total 4
drwx------ 2 user user 4096 Jul  7 10:15 ssh-XXXXqYzABC
-rw-r--r-- 1 user user   42 Jul  7 09:58 notes.txt
```

Here `ls` is the command, `-l` (long listing) is an option, and `/tmp` is an argument.

Some other syntax rules worth knowing:

- **Case matters.** `ls` exists; `LS` does not. `-r` and `-R` are usually different options.
- **Multiple commands on one line** are separated by a semicolon:

  ```
  $ cd /tmp ; ls
  ```

- **Long lines** can be continued by ending the line with a backslash `\`; the shell shows a secondary prompt (`>`) and waits for the rest.

### Internal vs. external commands

Commands come in two flavors:

- **Internal (builtin)** commands are part of the shell itself, e.g., `cd`, `echo`, `pwd`, `export`, `type`.
- **External** commands are separate programs stored on disk, e.g., `ls` in `/usr/bin/ls`.

The `type` builtin tells you which is which:

```
$ type echo
echo is a shell builtin
$ type ls
ls is /usr/bin/ls
```

To find where an external command lives you can also use `which`:

```
$ which mkdir
/usr/bin/mkdir
```

### Command history

Bash records the commands you type. Press the **Up/Down arrows** to walk through previous commands, or run `history` to list them:

```
$ history
  101  ls -l /tmp
  102  echo $SHELL
  103  history
```

`!101` re-runs command number 101, and `!!` re-runs the last command. The history is saved in the file `~/.bash_history` when the session ends.

---

## 3. Variables

A **variable** is a named container for a value. The shell uses two kinds:

- **Shell (local) variables** — exist only in the current shell.
- **Environment variables** — are passed on (*exported*) to programs started from the shell.

### Creating and reading variables

Assign with `NAME=value` — **no spaces around the `=`** — and read with a `$` prefix:

```
$ greeting='Hello world'
$ echo $greeting
Hello world
```

Variable names may contain letters, digits, and underscores, but cannot start with a digit. By convention, environment variables are written in UPPERCASE.

### Environment variables and `export`

To make a variable visible to child processes, export it:

```
$ export greeting
```

or in one step:

```
$ export EDITOR=nano
```

Inspect the environment with `env` (or `printenv`), and remove a variable with `unset`:

```
$ env | grep EDITOR
EDITOR=nano
$ unset EDITOR
```

Important environment variables to recognize:

| Variable | Meaning |
|----------|---------|
| `PATH`   | Directories searched for external commands |
| `HOME`   | Current user's home directory |
| `USER`   | Current username |
| `SHELL`  | Path of the user's login shell |
| `PWD`    | Current working directory |
| `LANG`   | Locale / language settings |

### The `PATH` variable

When you type a command name, the shell searches, in order, each directory listed in `PATH` (colon-separated) until it finds a matching executable:

```
$ echo $PATH
/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin
```

If a program is not in any of these directories, you get `command not found` — even if the file exists. You can run it anyway by giving its path explicitly (`./myscript.sh`), or add its directory to the search path:

```
$ export PATH=$PATH:/home/user/scripts
```

This appends `/home/user/scripts` to the existing value. Changes made this way last only for the current session.

---

## 4. Quoting

Because the shell interprets certain characters specially (spaces split words; `$` expands variables; `*` matches filenames), you need **quoting** to control that interpretation. There are three mechanisms:

### Double quotes `"..."`

Suppress most special meanings **but still allow** variable expansion (`$`) and command substitution:

```
$ user_count=3
$ echo "There are $user_count users logged in"
There are 3 users logged in
```

Without quotes, an argument containing spaces would be split into several arguments — a classic problem with filenames:

```
$ touch "my notes.txt"     # creates ONE file
$ touch my notes.txt       # creates TWO files: 'my' and 'notes.txt'
```

### Single quotes `'...'`

Suppress **all** special meanings — everything is taken literally, including `$`:

```
$ echo 'There are $user_count users logged in'
There are $user_count users logged in
```

### Escape character `\`

A backslash removes the special meaning of just the **next** character:

```
$ echo "The price is \$5"
The price is $5
$ touch my\ notes.txt      # same as "my notes.txt"
```

### Quoting and globbing

Unquoted `*` and `?` are **wildcards** (globbing) expanded by the shell into matching filenames; quoting prevents that:

```
$ ls *.txt
my notes.txt  notes.txt
$ echo '*.txt'
*.txt
```

**Rule of thumb:** use double quotes when you want variables expanded, single quotes when you want the text exactly as written.

---

## 5. Getting Output: `echo` and Command Substitution

`echo` prints its arguments followed by a newline and is the standard way to inspect variables:

```
$ echo $HOME
/home/user
```

Useful options: `-n` suppresses the trailing newline; `-e` enables escape sequences such as `\n` (newline) and `\t` (tab):

```
$ echo -e "Line one\nLine two"
Line one
Line two
```

**Command substitution** inserts the output of one command into another, using `$(...)` (modern) or backticks `` `...` `` (legacy):

```
$ echo "Today is $(date +%A)"
Today is Tuesday
$ kernel=$(uname -r)
$ echo $kernel
6.9.3-200.fc40.x86_64
```

---

## 6. Quick Reference

| Task | Command |
|------|---------|
| Show current shell | `echo $SHELL` |
| Identify command type | `type cd`, `which ls` |
| List/reuse past commands | `history`, `!!`, `!n` |
| Set a local variable | `var=value` |
| Export to environment | `export var=value` |
| Show environment | `env`, `printenv` |
| Delete a variable | `unset var` |
| Show search path | `echo $PATH` |
| Literal text (no expansion) | `'single quotes'` |
| Text with variable expansion | `"double quotes"` |
| Escape one character | `\` |
| Insert command output | `$(command)` |

---

## Referencias

- LPI Learning Materials — 010-160, Topic 2.1 *Command Line Basics*: https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
- LPI Linux Essentials Objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- GNU Bash Manual — Quoting: https://www.gnu.org/software/bash/manual/html_node/Quoting.html
- GNU Coreutils Manual (`echo`, `env`, `printenv`): https://www.gnu.org/software/coreutils/manual/coreutils.html