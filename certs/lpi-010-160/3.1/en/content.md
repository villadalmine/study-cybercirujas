# 3.1 Archiving Files on the Command Line

**Exam weight:** 2
**Key knowledge areas:** Files and directories; archives and compression.
**Relevant commands:** `tar`, `gzip`, `gunzip`, `bzip2`, `bunzip2`, `xz`, `unxz`, `zip`, `unzip`, common `tar` options.

---

## 1. Archiving vs. Compression

These are two different operations that are often combined:

- **Archiving** bundles many files and directories into a single file, preserving names, directory structure, permissions, and timestamps. The classic tool is `tar` (originally *tape archive*).
- **Compression** reduces the size of a single file using algorithms such as DEFLATE (`gzip`), Burrows–Wheeler (`bzip2`), or LZMA2 (`xz`).

On Linux the traditional workflow is: `tar` creates the archive, then a compressor shrinks it. That is why you see double extensions like `.tar.gz` (also written `.tgz`), `.tar.bz2`, or `.tar.xz`. The `zip` format, common on Windows, does both jobs in one step.

| Tool | Extension | Compression | Speed |
|---|---|---|---|
| `gzip` | `.gz` | Good | Fast |
| `bzip2` | `.bz2` | Better | Slower |
| `xz` | `.xz` | Best | Slowest |
| `zip` | `.zip` | Good | Fast |

## 2. The `tar` Command

General syntax:

```
tar [options] [archive-file] [files or directories...]
```

The three **main modes** (exactly one is required):

- `-c` — **create** a new archive
- `-t` — **list** (test) the contents of an archive
- `-x` — **extract** files from an archive

Frequently combined options:

- `-f FILE` — the archive file to operate on (almost always needed; must be the last option before the filename)
- `-v` — verbose, show each file as it is processed
- `-z` — filter through **gzip**
- `-j` — filter through **bzip2**
- `-J` — filter through **xz**
- `-C DIR` — change to directory `DIR` before extracting

> Mnemonic for the compression letters: `-z` = g**z**ip, `-j` = **b**zip2 (the odd one out), `-J` = **x**z (capital, strongest).

### 2.1 Creating an archive

```bash
$ tar -cvf backup.tar Documents/
Documents/
Documents/notes.txt
Documents/report.odt
Documents/projects/
Documents/projects/plan.md
```

Create and compress in one step:

```bash
$ tar -czvf backup.tar.gz Documents/    # gzip
$ tar -cjvf backup.tar.bz2 Documents/   # bzip2
$ tar -cJvf backup.tar.xz Documents/    # xz
```

Comparing the results:

```bash
$ ls -lh backup.tar*
-rw-r--r-- 1 carol carol 10M jul  7 10:15 backup.tar
-rw-r--r-- 1 carol carol 3.2M jul  7 10:16 backup.tar.gz
-rw-r--r-- 1 carol carol 2.9M jul  7 10:16 backup.tar.bz2
-rw-r--r-- 1 carol carol 2.6M jul  7 10:17 backup.tar.xz
```

### 2.2 Listing the contents

Always inspect an archive before extracting it:

```bash
$ tar -tf backup.tar.gz
Documents/
Documents/notes.txt
Documents/report.odt
Documents/projects/
Documents/projects/plan.md
```

Add `-v` to see permissions, owner, size, and date (similar to `ls -l`):

```bash
$ tar -tvf backup.tar.gz
drwxr-xr-x carol/carol       0 2026-07-07 10:12 Documents/
-rw-r--r-- carol/carol    1420 2026-07-07 10:12 Documents/notes.txt
```

### 2.3 Extracting

```bash
$ tar -xvf backup.tar.gz
Documents/
Documents/notes.txt
...
```

Modern GNU `tar` auto-detects the compression when extracting, so `-z`/`-j`/`-J` are optional here. Useful variations:

```bash
# Extract into a different directory
$ tar -xf backup.tar.gz -C /tmp/restore

# Extract a single file from the archive
$ tar -xf backup.tar.gz Documents/notes.txt
```

Note that `tar` accepts options with or without the leading dash (`tar xvf backup.tar` also works), a historical quirk you may see in documentation.

## 3. Standalone Compression Tools

These tools compress **one file at a time** and, by default, **replace** the original with the compressed version:

```bash
$ ls -lh logfile.txt
-rw-r--r-- 1 carol carol 5.0M jul  7 10:20 logfile.txt
$ gzip logfile.txt
$ ls -lh logfile.txt.gz
-rw-r--r-- 1 carol carol 980K jul  7 10:20 logfile.txt.gz
```

Decompressing (any of these forms):

```bash
$ gunzip logfile.txt.gz      # or: gzip -d logfile.txt.gz
$ bunzip2 logfile.txt.bz2    # or: bzip2 -d
$ unxz logfile.txt.xz        # or: xz -d
```

Handy options shared by the three tools:

- `-k` — **keep** the original file instead of deleting it
- `-d` — decompress
- `-1` … `-9` — compression level (fast/large … slow/small)

You can read a compressed text file without decompressing it on disk using `zcat`, `bzcat`, or `xzcat`:

```bash
$ zcat logfile.txt.gz | head -n 2
Jul 07 09:00:01 host CRON[1234]: session opened
Jul 07 09:05:01 host CRON[1250]: session opened
```

## 4. `zip` and `unzip`

`zip` archives **and** compresses in a single step, and the format is fully interoperable with Windows and macOS — useful when exchanging files with non-Linux users.

Create an archive (use `-r` to recurse into directories):

```bash
$ zip -r backup.zip Documents/
  adding: Documents/ (stored 0%)
  adding: Documents/notes.txt (deflated 62%)
  adding: Documents/report.odt (deflated 8%)
```

List the contents without extracting:

```bash
$ unzip -l backup.zip
Archive:  backup.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
        0  2026-07-07 10:12   Documents/
     1420  2026-07-07 10:12   Documents/notes.txt
```

Extract (optionally into another directory with `-d`):

```bash
$ unzip backup.zip
$ unzip backup.zip -d /tmp/restore
```

Unlike `gzip` and friends, `zip` keeps the original files, and unlike `tar.gz` each file inside a `.zip` is compressed individually.

## 5. Quick Reference

| Task | Command |
|---|---|
| Create tar archive | `tar -cvf arch.tar dir/` |
| Create gzipped tar | `tar -czvf arch.tar.gz dir/` |
| Create bzip2 tar | `tar -cjvf arch.tar.bz2 dir/` |
| Create xz tar | `tar -cJvf arch.tar.xz dir/` |
| List tar contents | `tar -tvf arch.tar.gz` |
| Extract tar | `tar -xvf arch.tar.gz` |
| Extract to a directory | `tar -xf arch.tar.gz -C /path` |
| Compress / decompress a file | `gzip file` / `gunzip file.gz` |
| Create zip | `zip -r arch.zip dir/` |
| List / extract zip | `unzip -l arch.zip` / `unzip arch.zip` |

**Exam tips:**

- Know which `tar` letter maps to which compressor: `-z` → gzip, `-j` → bzip2, `-J` → xz.
- Remember that `gzip`, `bzip2`, and `xz` replace the original file unless you pass `-k`.
- Compression ranking (typical): `xz` smallest, then `bzip2`, then `gzip`/`zip`; speed is the reverse.
- `zip` needs `-r` to include the contents of directories.

## Referencias

- LPI Learning Materials — Topic 3.1, Archiving Files on the Command Line: https://learning.lpi.org/en/learning-materials/010-160/3/3.1/
- LPI Linux Essentials Objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU tar manual: https://www.gnu.org/software/tar/manual/
- GNU gzip manual: https://www.gnu.org/software/gzip/manual/gzip.html
- bzip2 documentation: https://sourceware.org/bzip2/docs.html
- XZ Utils: https://tukaani.org/xz/
- Info-ZIP (`zip`/`unzip`): https://infozip.sourceforge.net/