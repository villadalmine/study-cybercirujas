# 3.2 Searching and Extracting Data from Files

**Exam weight:** 3
**Key knowledge areas:** command-line pipes, I/O redirection, basic regular expressions (`.`, `[ ]`, `*`, `?`)
**Relevant commands and terms:** `grep`, `less`, `cat`, `head`, `tail`, `sort`, `cut`, `wc`, `>`, `>>`, `<`, `2>`, `|`

---

## 1. Why This Topic Matters

Linux follows a simple philosophy: programs should do one thing well, work with plain text, and be combinable. This topic covers the three mechanisms that make that philosophy practical:

1. **I/O redirection** — sending a command's input or output to and from files.
2. **Pipes** — connecting the output of one command directly to the input of another.
3. **Searching tools and regular expressions** — finding and extracting exactly the data you need, primarily with `grep`.

Mastering these lets you answer questions like "which users on this system use Bash?" or "how many errors appeared in this log?" with a single line.

---

## 2. Standard Input, Output, and Error

Every Linux program automatically gets three communication channels, called **file descriptors**:

| Descriptor | Name | Number | Default |
|---|---|---|---|
| stdin | Standard input | 0 | Keyboard |
| stdout | Standard output | 1 | Terminal screen |
| stderr | Standard error | 2 | Terminal screen |

`stdout` carries normal results; `stderr` carries error messages. They both appear on your screen by default, but because they are separate channels, they can be redirected independently. This separation is the foundation of everything else in this topic.

---

## 3. I/O Redirection

### 3.1 Redirecting stdout: `>` and `>>`

The `>` operator sends stdout to a file instead of the screen. **It overwrites the file if it exists.**

```console
$ echo "first line" > notes.txt
$ cat notes.txt
first line
$ echo "replaced!" > notes.txt
$ cat notes.txt
replaced!
```

The `>>` operator **appends** instead of overwriting:

```console
$ echo "one" >> log.txt
$ echo "two" >> log.txt
$ cat log.txt
one
two
```

Both operators create the file if it does not exist yet.

### 3.2 Redirecting stderr: `2>` and `2>>`

Error messages travel on descriptor 2, so `>` alone does not capture them:

```console
$ ls /nonexistent > out.txt
ls: cannot access '/nonexistent': No such file or directory
```

The error still printed to the screen, and `out.txt` is empty. To capture the error, redirect descriptor 2 explicitly:

```console
$ ls /nonexistent 2> errors.txt
$ cat errors.txt
ls: cannot access '/nonexistent': No such file or directory
```

You can redirect both streams to different files at once:

```console
$ find /etc -name passwd > found.txt 2> denied.txt
```

To combine both streams into a single file, redirect stderr to wherever stdout is pointing with `2>&1`:

```console
$ find /etc -name passwd > all.txt 2>&1
```

A common trick is discarding unwanted errors by sending them to `/dev/null`, a special device that silently throws away everything written to it:

```console
$ find / -name "*.conf" 2> /dev/null
```

### 3.3 Redirecting stdin: `<`

The `<` operator feeds a file into a command's stdin. Some commands behave differently when given a filename argument versus data on stdin — `wc` is a good example:

```console
$ wc -l /etc/passwd
34 /etc/passwd
$ wc -l < /etc/passwd
34
```

With `<`, `wc` never learns the filename, so it prints only the count. This matters when you want clean numeric output for further processing.

### 3.4 Here documents: `<<`

A **here document** lets you type multi-line input directly, ended by a delimiter word:

```console
$ wc -l << EOF
> line one
> line two
> line three
> EOF
3
```

### Summary of redirection operators

| Operator | Effect |
|---|---|
| `> file` | stdout to file (overwrite) |
| `>> file` | stdout to file (append) |
| `2> file` | stderr to file (overwrite) |
| `2>> file` | stderr to file (append) |
| `2>&1` | stderr merged into stdout |
| `< file` | file becomes stdin |
| `<< WORD` | here document (inline stdin) |

---

## 4. Command-Line Pipes

The pipe operator `|` connects the stdout of one command to the stdin of the next, without any intermediate file:

```console
$ cat /etc/passwd | wc -l
34
```

Pipes can be chained into pipelines of any length. Each stage transforms the data a little more:

```console
$ cat /etc/passwd | grep bash | cut -d: -f1 | sort
carol
dave
root
```

This pipeline reads the user database, keeps only lines mentioning `bash`, extracts the first colon-separated field (the username), and sorts the result alphabetically.

Note that only **stdout** flows through a pipe by default; stderr still goes to the screen. To pipe both streams, merge them first: `command 2>&1 | less`.

---

## 5. Commands for Viewing and Extracting Data

These small utilities are the standard building blocks inside pipelines.

### 5.1 `cat` — concatenate and print files

```console
$ cat /etc/hostname
mylaptop
```

`cat file1 file2` prints files one after another, which is where its name (concatenate) comes from.

### 5.2 `less` — page through long output

`less` displays a file (or piped input) one screen at a time. Navigate with the arrow keys, `Space` (next page), `/pattern` (search forward), `n` (next match), and `q` (quit).

```console
$ less /var/log/syslog
$ dmesg | less
```

### 5.3 `head` and `tail` — beginning and end of a file

Both show 10 lines by default; `-n` changes the count.

```console
$ head -n 3 /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin

$ tail -n 2 /etc/passwd
carol:x:1000:1000:Carol:/home/carol:/bin/bash
dave:x:1001:1001:Dave:/home/dave:/bin/bash
```

`tail -f` (follow) keeps printing new lines as they are appended — invaluable for watching log files live:

```console
$ tail -f /var/log/syslog
```

### 5.4 `sort` — order lines

```console
$ sort names.txt          # alphabetical
$ sort -r names.txt       # reverse order
$ sort -n sizes.txt       # numeric sort (10 after 9, not after 1)
$ sort -u names.txt       # sort and drop duplicate lines
```

Example of why `-n` matters:

```console
$ printf "10\n9\n2\n" | sort
10
2
9
$ printf "10\n9\n2\n" | sort -n
2
9
10
```

### 5.5 `cut` — extract columns or fields

`cut` slices each line by delimiter and field number (`-d` and `-f`) or by character position (`-c`).

```console
$ cut -d: -f1,7 /etc/passwd | head -n 3
root:/bin/bash
daemon:/usr/sbin/nologin
bin:/usr/sbin/nologin

$ echo "abcdef" | cut -c 2-4
bcd
```

### 5.6 `wc` — count lines, words, and bytes

By default `wc` prints lines, words, and bytes. Individual flags: `-l` (lines), `-w` (words), `-c` (bytes).

```console
$ wc /etc/passwd
 34  56 1832 /etc/passwd
$ grep bash /etc/passwd | wc -l
3
```

---

## 6. Searching with `grep`

`grep` reads lines from files or stdin and prints those matching a **pattern**:

```console
$ grep bash /etc/passwd
root:x:0:0:root:/root:/bin/bash
carol:x:1000:1000:Carol:/home/carol:/bin/bash
dave:x:1001:1001:Dave:/home/dave:/bin/bash
```

Frequently used options:

| Option | Meaning |
|---|---|
| `-i` | Case-insensitive match |
| `-v` | Invert: print lines that do **not** match |
| `-c` | Print only the count of matching lines |
| `-n` | Prefix each match with its line number |
| `-r` | Search recursively through a directory |
| `-w` | Match whole words only |

Examples:

```console
$ grep -i error /var/log/syslog       # ERROR, Error, error...
$ grep -v nologin /etc/passwd          # accounts with a real shell
$ grep -c bash /etc/passwd
3
$ grep -rn "PermitRootLogin" /etc/ssh/
/etc/ssh/sshd_config:33:#PermitRootLogin prohibit-password
```

---

## 7. Basic Regular Expressions

A **regular expression (regex)** is a pattern describing a set of strings. `grep` treats its pattern as a basic regular expression by default. The exam expects the following metacharacters:

| Metacharacter | Meaning |
|---|---|
| `.` | Any single character |
| `[abc]` | Any one of the listed characters |
| `[a-z]` | Any character in the range |
| `[^abc]` | Any character **not** listed |
| `*` | Zero or more repetitions of the preceding element |
| `?` | Zero or one repetition (extended regex, use `grep -E`) |
| `^` | Anchor: start of line |
| `$` | Anchor: end of line |

> **Important:** regex `*` differs from shell globbing. In globbing, `*` alone means "anything"; in regex, `*` is a quantifier applying to the element before it. "Any sequence of characters" in regex is `.*`.

### Examples

Sample file:

```console
$ cat animals.txt
cat
cart
carrot
bat
dog
```

**`.` — any single character:**

```console
$ grep 'ca.t' animals.txt
cart
```

**`[ ]` — character set:**

```console
$ grep '[cb]at' animals.txt
cat
bat
```

**`*` — zero or more of the previous element:**

```console
$ grep 'car*t' animals.txt
cat
cart
```

(`r*` matches zero r's in `cat` and one in `cart`; `carrot` fails because of the trailing `ot`.)

**`^` and `$` — anchors:**

```console
$ grep '^ca' animals.txt        # lines starting with "ca"
cat
cart
carrot
$ grep 't$' animals.txt         # lines ending in "t"
cat
cart
carrot
bat
```

A practical anchored example — find users whose shell is Bash, matching only at the end of the line:

```console
$ grep ':/bin/bash$' /etc/passwd
root:x:0:0:root:/root:/bin/bash
carol:x:1000:1000:Carol:/home/carol:/bin/bash
```

**`?` — zero or one (requires extended regex, `grep -E` or `egrep`):**

```console
$ echo -e "color\ncolour" | grep -E 'colou?r'
color
colour
```

**Quoting tip:** always wrap regex patterns in single quotes (`grep 'pat.*' file`) so the shell does not expand metacharacters like `*` before `grep` sees them.

---

## 8. Putting It All Together

Realistic one-liners combining redirection, pipes, and searching:

```console
# Count how many users cannot log in interactively
$ grep -c 'nologin$' /etc/passwd
27

# Top of an alphabetically sorted list of usernames, saved to a file
$ cut -d: -f1 /etc/passwd | sort | head -n 5 > first_users.txt

# Watch a log for errors in real time
$ tail -f /var/log/syslog | grep -i error

# Find every .conf file under /etc, ignoring permission errors,
# and count them
$ find /etc -name '*.conf' 2> /dev/null | wc -l
89
```

---

## 9. Key Takeaways for the Exam

- **stdin = 0, stdout = 1, stderr = 2.** `>` affects only stdout; `2>` affects stderr; `2>&1` merges them.
- `>` **overwrites**, `>>` **appends** — a classic exam distinction.
- A pipe `|` carries **stdout only** into the next command's stdin.
- `head`/`tail` default to **10 lines**; `tail -f` follows a growing file.
- `cut -d: -f1 /etc/passwd` is the canonical field-extraction example.
- In regex: `.` = one character, `[ ]` = character set, `*` = zero or more of the **preceding** element, `^`/`$` = line anchors, `?` = optional (with `grep -E`).
- `/dev/null` discards anything written to it — commonly used as `2> /dev/null`.

---

## Referencias

- LPI Learning Materials — Objective 3.2, Searching and Extracting Data from Files: https://learning.lpi.org/en/learning-materials/010-160/3/3.2/
- LPI Linux Essentials Exam 010-160 Objectives: https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Grep Manual: https://www.gnu.org/software/grep/manual/grep.html
- GNU Coreutils Manual (`cat`, `head`, `tail`, `sort`, `cut`, `wc`): https://www.gnu.org/software/coreutils/manual/coreutils.html
- Bash Reference Manual — Redirections: https://www.gnu.org/software/bash/manual/html_node/Redirections.html