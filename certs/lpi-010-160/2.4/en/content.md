# 2.4 Creating, Moving and Deleting Files

## Overview

Topic 2.4 covers the core file management commands every Linux user needs: creating files and directories, copying and moving them, removing them safely, and creating links between them. These commands form the backbone of daily filesystem interaction on any Linux system.

## Creating Directories: `mkdir`

The `mkdir` command creates new directories.

```
$ mkdir projects
$ mkdir -p projects/2026/reports
```

- `-p` (`--parents`) creates any missing parent directories along the path and does not fail if the target already exists.
- `-v` (`--verbose`) prints a message for each directory created.

```
$ mkdir -pv archive/logs/old
mkdir: created directory 'archive'
mkdir: created directory 'archive/logs'
mkdir: created directory 'archive/logs/old'
```

Without `-p`, trying to create a nested path whose parents don't exist fails:

```
$ mkdir new/sub
mkdir: cannot create directory 'new/sub': No such file or directory
```

## Creating Empty Files: `touch`

`touch` creates an empty file if it doesn't exist, or updates the access/modification timestamps if it does.

```
$ touch notes.txt
$ ls -l notes.txt
-rw-r--r--. 1 user user 0 Jul 12 10:00 notes.txt
```

Running `touch` again on an existing file updates its timestamp without changing its content:

```
$ touch notes.txt
$ stat -c '%y' notes.txt
2026-07-12 10:05:12.000000000 -0300
```

Useful options:
- `-c` (`--no-create`) only updates timestamps; does nothing if the file doesn't exist.
- `-t [[CC]YY]MMDDhhmm[.ss]` sets a specific timestamp.

## Copying Files and Directories: `cp`

`cp` copies files or directories.

```
$ cp report.txt report_backup.txt
$ cp report.txt /tmp/
```

Key options:
- `-r` or `-R` (recursive) — required to copy directories and their contents.
- `-i` (interactive) — prompts before overwriting an existing destination file.
- `-v` (verbose) — prints each file as it's copied.
- `-p` (preserve) — keeps original permissions, ownership, and timestamps.
- `-u` (update) — only copies when the source is newer than the destination or the destination is missing.

```
$ cp -r projects/ projects_backup/
$ cp -riv notes.txt /tmp/
cp: overwrite '/tmp/notes.txt'? y
'notes.txt' -> '/tmp/notes.txt'
```

Attempting to copy a directory without `-r` fails:

```
$ cp projects/ projects_backup2/
cp: -r not specified; omitting directory 'projects/'
```

## Moving and Renaming: `mv`

`mv` moves files/directories to a new location, and is also used to rename them (a rename is simply a move within the same directory).

```
$ mv notes.txt final_notes.txt
$ mv final_notes.txt archive/
```

Options mirror `cp`:
- `-i` — prompt before overwrite.
- `-v` — verbose output.
- `-n` — never overwrite an existing file.

```
$ mv -v report.txt archive/logs/
'report.txt' -> 'archive/logs/report.txt'
```

Moving multiple files into a directory:

```
$ mv file1.txt file2.txt archive/
```

Unlike `cp`, `mv` does not need `-r` to move directories, since it typically just repoints the directory entry rather than copying data (when staying on the same filesystem).

## Removing Files and Directories: `rm` and `rmdir`

`rmdir` removes **empty** directories only:

```
$ rmdir archive/logs/old
$ rmdir archive/logs
rmdir: failed to remove 'archive/logs': Directory not empty
```

`rm` removes files, and with `-r` removes directories recursively (including their contents):

```
$ rm notes.txt
$ rm -r projects_backup/
```

Common options:
- `-f` (force) — ignores nonexistent files and never prompts.
- `-i` (interactive) — prompts before every removal.
- `-r` / `-R` (recursive) — required for directories.
- `-v` (verbose) — reports what was removed.

```
$ rm -rf projects_backup2/
```

`rm -rf` is powerful and destructive: there is no trash bin or undelete by default in most shells, so files removed this way are typically unrecoverable. Always double-check the path, especially when using wildcards:

```
$ rm -rf /var/tmp/cache/*
```

A misplaced space (e.g., `rm -rf / var/tmp/cache/*` instead of `rm -rf /var/tmp/cache/*`) can attempt to wipe the root filesystem, so care with spacing and quoting matters.

## Links: `ln`

Linux supports two kinds of links between files, created with `ln`.

### Hard links

A hard link is an additional directory entry pointing to the same inode (same data on disk). Both names are equally "real"; deleting one leaves the data accessible through the other.

```
$ echo "hello" > original.txt
$ ln original.txt hardlink.txt
$ ls -li original.txt hardlink.txt
123456 -rw-r--r--. 2 user user 6 Jul 12 10:10 hardlink.txt
123456 -rw-r--r--. 2 user user 6 Jul 12 10:10 original.txt
```

Note both files share the same inode number (`123456`) and the link count is `2`. Hard links cannot span filesystems and cannot point to directories (with rare exceptions handled internally by the system).

### Symbolic (soft) links

A symbolic link is a special file that stores a path to another file. Created with `ln -s`:

```
$ ln -s original.txt symlink.txt
$ ls -l symlink.txt
lrwxrwxrwx. 1 user user 12 Jul 12 10:12 symlink.txt -> original.txt
```

Symbolic links can point across filesystems and to directories, but become "dangling" (broken) if the target is removed:

```
$ rm original.txt
$ cat symlink.txt
cat: symlink.txt: No such file or directory
```

`ls -l` marks the link type with a leading `l` and shows the target after `->`.

## Summary Table

| Command | Purpose | Key flags |
|---|---|---|
| `mkdir` | create directories | `-p`, `-v` |
| `touch` | create empty files / update timestamps | `-c`, `-t` |
| `cp` | copy files/directories | `-r`, `-i`, `-v`, `-p` |
| `mv` | move/rename files/directories | `-i`, `-v`, `-n` |
| `rmdir` | remove empty directories | — |
| `rm` | remove files/directories | `-r`, `-f`, `-i`, `-v` |
| `ln` | create hard/symbolic links | `-s` |

## Referencias

- LPI Learning Materials, Topic 2.4: https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
- GNU Coreutils Manual — `mkdir`: https://www.gnu.org/software/coreutils/manual/html_node/mkdir-invocation.html
- GNU Coreutils Manual — `touch`: https://www.gnu.org/software/coreutils/manual/html_node/touch-invocation.html
- GNU Coreutils Manual — `cp`: https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html
- GNU Coreutils Manual — `mv`: https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html
- GNU Coreutils Manual — `rm`: https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html
- GNU Coreutils Manual — `rmdir`: https://www.gnu.org/software/coreutils/manual/html_node/rmdir-invocation.html
- GNU Coreutils Manual — `ln`: https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html