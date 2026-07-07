# 2.3 Using Directories and Listing Files

**Exam weight:** 2
**Key knowledge areas:** files and directories, hidden files and directories, home directories, absolute and relative paths.
**Relevant commands and concepts:** common options for `ls` (`-l`, `-a`, `-h`, `-R`), `cd`, `pwd`, `.` and `..`, `~`.

---

## 1. Files and Directories

In Linux, almost everything is represented as a file: documents, programs, and even hardware devices. Files are organized into **directories** (the equivalent of "folders" in other operating systems), which can contain files and other directories, forming a tree.

The tree starts at the **root directory**, written as a single forward slash `/`. Every file on the system can be reached by following a path that begins at `/`. Note that Linux uses the forward slash (`/`) as separator, not the backslash (`\`) used by Windows.

Some important directories in the tree:

| Directory | Purpose |
|-----------|---------|
| `/` | Root of the whole filesystem tree |
| `/home` | Contains the home directories of regular users |
| `/root` | Home directory of the administrator (`root` user) |
| `/etc` | System configuration files |
| `/usr` | Programs and read-only data installed by the system |
| `/tmp` | Temporary files |

Two rules worth remembering for the exam:

- **File names are case sensitive:** `Report.txt`, `report.txt` and `REPORT.TXT` are three different files.
- There is no concept of "drive letters" (`C:`, `D:`); additional disks are *mounted* somewhere inside the single tree.

## 2. The Current Directory: `pwd` and `cd`

The shell always has a **current working directory**. The `pwd` (*print working directory*) command shows where you are:

```
$ pwd
/home/carol
```

The `cd` (*change directory*) command moves you around the tree:

```
$ cd /etc
$ pwd
/etc
```

Running `cd` **with no arguments** takes you back to your home directory from anywhere:

```
$ cd
$ pwd
/home/carol
```

A useful extra: `cd -` returns to the *previous* directory you were in.

## 3. Special Directory Names: `.`, `..` and `~`

Every directory contains two special entries:

- `.` (a single dot) refers to **the directory itself**.
- `..` (two dots) refers to **the parent directory**, one level up.

```
$ pwd
/home/carol/Documents
$ cd ..
$ pwd
/home/carol
$ cd ../..
$ pwd
/
```

The tilde `~` is a shell shortcut for **your home directory**:

```
$ cd ~/Documents
$ pwd
/home/carol/Documents
```

You can also refer to another user's home directory with `~username`, e.g. `~dave` expands to `/home/dave`.

### Home directories

Each regular user has a personal directory under `/home`, named after the user (e.g. `/home/carol`). This is where personal files and per-user configuration live, and it is normally the only place where a regular user has full write permission. The administrator is the exception: `root`'s home is `/root`, not `/home/root`.

## 4. Absolute and Relative Paths

There are two ways to specify the location of a file or directory:

- An **absolute path** starts with `/` and describes the full route from the root of the tree. It works no matter what your current directory is.

  ```
  $ cd /home/carol/Documents/Work
  ```

- A **relative path** does *not* start with `/` and is interpreted **starting from the current directory**. It usually combines names with `.` and `..`.

  ```
  $ pwd
  /home/carol/Documents
  $ cd Work           # relative: /home/carol/Documents/Work
  $ cd ../Personal    # relative: up one level, then into Personal
  $ pwd
  /home/carol/Documents/Personal
  ```

Quick test: if the path begins with `/`, it is absolute; otherwise it is relative. Both notations can name the same target — `/home/carol/Documents` and (from `/home/carol`) `Documents` point to the same directory.

## 5. Listing Files with `ls`

The `ls` command lists the contents of a directory. With no arguments it lists the current directory; you can also pass it one or more paths:

```
$ ls
Desktop  Documents  Downloads  Music  Pictures  Videos
$ ls /etc/ssh
moduli  ssh_config  ssh_config.d  sshd_config  sshd_config.d
```

### Long listing: `ls -l`

The `-l` option shows one entry per line with detailed information:

```
$ ls -l
total 16
drwxr-xr-x 2 carol carol 4096 Jun 12 09:30 Documents
drwxr-xr-x 2 carol carol 4096 Jun 12 09:30 Downloads
-rw-r--r-- 1 carol carol 3540 Jun 15 14:02 notes.txt
```

Reading the columns from left to right: file type and permissions (a leading `d` means directory, `-` means regular file), number of links, owner, group, **size in bytes**, last modification date/time, and name.

### Human-readable sizes: `ls -h`

Raw byte counts are hard to read for large files. Combined with `-l`, the `-h` option prints sizes with units (K, M, G):

```
$ ls -lh notes.txt
-rw-r--r-- 1 carol carol 3.5K Jun 15 14:02 notes.txt
```

`-h` only has an effect together with `-l` (it modifies the size column).

### Hidden files: `ls -a`

Any file or directory whose name **begins with a dot** is *hidden*: `ls` skips it by default. Hidden files are commonly used for per-user configuration (e.g. `.bashrc`, `.ssh`). The `-a` (*all*) option shows them:

```
$ ls -a
.  ..  .bash_history  .bashrc  .ssh  Documents  Downloads  notes.txt
```

Note that `.` and `..` themselves appear, since they are also names starting with a dot. Making a file "hidden" is just a naming convention — renaming `notes.txt` to `.notes.txt` hides it; it is not a security mechanism.

### Recursive listing: `ls -R`

The `-R` option lists a directory **and all its subdirectories**, section by section:

```
$ ls -R Documents
Documents:
Personal  Work

Documents/Personal:
recipes.txt

Documents/Work:
report.odt
```

### Combining options

Short options can be combined after a single dash. A very common combination is:

```
$ ls -alh
```

which shows a long listing (`-l`), including hidden files (`-a`), with human-readable sizes (`-h`).

## 6. Worked Example

Putting it all together — starting from an unknown location, go home, inspect what is there, and navigate using relative paths:

```
$ cd                      # go to my home directory
$ pwd
/home/carol
$ ls -a                   # what is here, including hidden files?
.  ..  .bashrc  Documents  Downloads
$ cd Documents/Work       # relative path, two levels down
$ pwd
/home/carol/Documents/Work
$ ls -lh
total 12K
-rw-r--r-- 1 carol carol 8.2K Jun 20 10:15 report.odt
$ cd ../../Downloads      # up two levels, then into Downloads
$ pwd
/home/carol/Downloads
$ cd /etc                 # absolute path works from anywhere
```

## 7. Key Points to Remember

- The filesystem is a single tree rooted at `/`; there are no drive letters.
- File names are **case sensitive**.
- Absolute paths start with `/`; relative paths are resolved from the current directory.
- `pwd` shows where you are; `cd` moves you; plain `cd` goes home; `cd -` goes back.
- `.` = current directory, `..` = parent directory, `~` = your home directory.
- Names starting with a dot are hidden; show them with `ls -a`.
- `ls -l` gives details, `-h` makes sizes human-readable, `-R` recurses into subdirectories.

## Referencias

- LPI Learning Materials, Linux Essentials 010-160, Topic 2.3 — Using Directories and Listing Files: https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
- LPI Linux Essentials Exam Objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Coreutils Manual — `ls`: https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- GNU Coreutils Manual — `pwd`: https://www.gnu.org/software/coreutils/manual/html_node/pwd-invocation.html
- GNU Bash Manual — Tilde Expansion: https://www.gnu.org/software/bash/manual/html_node/Tilde-Expansion.html
- Filesystem Hierarchy Standard (FHS) 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html