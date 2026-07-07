# 2.4 Creating, Moving and Deleting Files

**Exam weight:** 2
**Key knowledge areas:** files and directories, case sensitivity, simple globbing (wildcards).
**Relevant commands and concepts:** `touch`, `mkdir`, `rmdir`, `cp`, `mv`, `rm`, globbing characters (`*`, `?`, `[]`), quoting.

---

## 1. Creating Files with `touch`

The quickest way to create an empty file is `touch`:

```
$ touch notes.txt
$ ls -l notes.txt
-rw-r--r-- 1 carol carol 0 Jul  7 10:15 notes.txt
```

The file size is `0` bytes — `touch` creates the file but puts nothing in it. If the file *already exists*, `touch` does not modify its contents; it only updates the file's timestamps (its access and modification times). That is actually the command's original purpose — creating files is a convenient side effect.

You can create several files at once by listing them:

```
$ touch a.txt b.txt c.txt
```

Remember that Linux file names are **case sensitive**: `touch Notes.txt` creates a *second* file, different from `notes.txt`.

## 2. Creating and Removing Directories: `mkdir` and `rmdir`

`mkdir` (*make directory*) creates directories:

```
$ mkdir projects
$ ls -l
drwxr-xr-x 2 carol carol 4096 Jul  7 10:20 projects
```

Trying to create nested directories in one step fails by default, because the intermediate directory does not exist:

```
$ mkdir projects/linux/essentials
mkdir: cannot create directory 'projects/linux/essentials': No such file or directory
```

The `-p` (*parents*) option solves this by creating every missing directory along the path:

```
$ mkdir -p projects/linux/essentials
```

`rmdir` (*remove directory*) deletes a directory — but **only if it is empty**:

```
$ rmdir projects
rmdir: failed to remove 'projects': Directory not empty
```

`rmdir` also accepts `-p` to remove a whole chain of nested empty directories:

```
$ rmdir -p projects/linux/essentials
```

This removes `essentials`, then `linux`, then `projects` — provided each one contains nothing else. To remove a directory *with* its contents, you need `rm -r` (see section 5).

## 3. Copying Files and Directories: `cp`

The basic form is `cp SOURCE DESTINATION`:

```
$ cp notes.txt backup.txt
```

If the destination is a **directory**, the copy keeps the original name and is placed inside it:

```
$ mkdir backups
$ cp notes.txt backups/
$ ls backups
notes.txt
```

You can copy several files at once, but then the last argument *must* be a directory:

```
$ cp a.txt b.txt c.txt backups/
```

Copying a directory requires the `-r` (*recursive*) option, which copies the directory and everything inside it:

```
$ cp backups backups2
cp: -r not specified; omitting directory 'backups'
$ cp -r backups backups2
```

Two safety-related options worth knowing:

| Option | Effect |
|--------|--------|
| `-i` (*interactive*) | Ask for confirmation before overwriting an existing file |
| `-r` or `-R` | Copy directories recursively |

Without `-i`, `cp` **silently overwrites** the destination if it already exists — a classic way to lose data.

```
$ cp -i notes.txt backup.txt
cp: overwrite 'backup.txt'? n
```

## 4. Moving and Renaming: `mv`

Linux uses a single command for both moving and renaming: `mv`. Which one happens depends only on the arguments.

**Renaming** (destination is a new file name):

```
$ mv notes.txt meeting-notes.txt
```

**Moving** (destination is an existing directory):

```
$ mv meeting-notes.txt backups/
$ ls backups
meeting-notes.txt  notes.txt
```

You can move and rename in one step:

```
$ mv backups/meeting-notes.txt ./old-notes.txt
```

Unlike `cp`, `mv` moves directories without needing any special option. Like `cp`, it silently overwrites an existing destination unless you use `-i`:

```
$ mv -i old-notes.txt backup.txt
mv: overwrite 'backup.txt'? y
```

## 5. Deleting Files and Directories: `rm`

`rm` (*remove*) deletes files:

```
$ rm backup.txt
```

By default it refuses to delete directories:

```
$ rm backups
rm: cannot remove 'backups': Is a directory
```

With `-r` (*recursive*) it deletes a directory **and everything inside it**, at any depth:

```
$ rm -r backups
```

The most important options:

| Option | Effect |
|--------|--------|
| `-r` or `-R` | Delete directories and their contents recursively |
| `-i` | Ask for confirmation before each deletion |
| `-f` (*force*) | Never ask, ignore missing files, override some protections |

Two things to burn into memory:

- **There is no trash can.** Files deleted with `rm` are gone; there is no built-in undo or recycle bin on the command line.
- `rm -rf` combined with a wrong path or a careless wildcard can wipe out enormous amounts of data without a single prompt. Double-check the arguments before pressing Enter — especially as `root`.

A safer habit while learning is to use the interactive mode:

```
$ rm -ri projects
rm: descend into directory 'projects'? y
rm: remove regular file 'projects/todo.txt'? y
rm: remove directory 'projects'? y
```

## 6. Globbing: Working with Many Files at Once

**Globbing** (also called *wildcard expansion*) lets you refer to multiple files with a single pattern. The important detail: it is the **shell** that expands the pattern into a list of matching names *before* running the command — the command itself (e.g. `rm`) never sees the wildcard, only the resulting file names.

| Pattern | Matches |
|---------|---------|
| `*` | Any string of characters, including none |
| `?` | Exactly one character (any character) |
| `[abc]` | Exactly one character from the set: `a`, `b` or `c` |
| `[a-z]` | Exactly one character in the range `a` to `z` |
| `[!abc]` or `[^abc]` | Exactly one character *not* in the set |

Examples, assuming the directory contains `log1.txt`, `log2.txt`, `log10.txt` and `report.txt`:

```
$ ls *.txt
log1.txt  log2.txt  log10.txt  report.txt

$ ls log?.txt
log1.txt  log2.txt

$ ls log[12].txt
log1.txt  log2.txt

$ ls log*
log1.txt  log2.txt  log10.txt
```

Note the difference between `?` and `*`: `log?.txt` does not match `log10.txt`, because `?` stands for exactly one character.

Globbing works with any command that takes file names:

```
$ cp *.txt backups/       # copy all .txt files
$ mv log* archive/        # move everything starting with "log"
$ rm log[0-9].txt         # delete log0.txt through log9.txt
```

Because the shell expands the pattern first, `rm *` really means "run `rm` with every visible file in this directory as an argument" — which is why wildcards and `rm -rf` are a dangerous combination.

## 7. Quoting: File Names with Spaces and Special Characters

The shell uses spaces to separate arguments, so a file name containing spaces gets split into pieces:

```
$ touch my notes.txt
$ ls
my  notes.txt
```

That created **two** files (`my` and `notes.txt`), not one. To treat the whole name as a single argument, quote it:

```
$ touch "my notes.txt"
$ rm 'my notes.txt'
```

Quoting also *disables globbing*, which matters when a name contains wildcard characters:

- **Double quotes** (`"..."`): protect spaces and wildcards, but the shell still expands variables like `$HOME` inside them.
- **Single quotes** (`'...'`): protect everything literally — no globbing, no variable expansion.

```
$ echo "You are $USER"
You are carol
$ echo 'You are $USER'
You are $USER
```

A backslash (`\`) escapes a single character instead of a whole string: `rm my\ notes.txt` is equivalent to `rm "my notes.txt"`.

## 8. Command Summary

| Task | Command |
|------|---------|
| Create an empty file / update timestamps | `touch file` |
| Create a directory | `mkdir dir` |
| Create nested directories | `mkdir -p a/b/c` |
| Remove an empty directory | `rmdir dir` |
| Copy a file | `cp src dst` |
| Copy a directory | `cp -r srcdir dstdir` |
| Move or rename | `mv src dst` |
| Delete a file | `rm file` |
| Delete a directory and its contents | `rm -r dir` |
| Ask before overwriting/deleting | `-i` with `cp`, `mv`, `rm` |

---

## Referencias

- LPI Learning Materials — Topic 2.4, Creating, Moving and Deleting Files: https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
- LPI Linux Essentials exam objectives (010-160, v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Coreutils manual (`touch`, `mkdir`, `rmdir`, `cp`, `mv`, `rm`): https://www.gnu.org/software/coreutils/manual/coreutils.html
- Bash Reference Manual — Filename Expansion (globbing): https://www.gnu.org/software/bash/manual/html_node/Filename-Expansion.html
- Bash Reference Manual — Quoting: https://www.gnu.org/software/bash/manual/html_node/Quoting.html