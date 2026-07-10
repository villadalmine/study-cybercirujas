# 5.4 Special Directories and Files

**Exam weight: 1** — Linux Essentials 010-160, version 1.6

## What this topic covers

Beyond your home directory, a Linux system keeps a handful of locations with special behavior that you must recognize: directories for temporary files that anyone may write to (protected by the **sticky bit**), virtual filesystems like `/dev`, `/proc`, and `/sys` that exist only in memory, and **links** — extra names for files created with `ln`. This topic is about knowing what lives where, why `/tmp` doesn't let users delete each other's files, and the difference between a hard link and a symbolic link.

## System directories with special roles

A quick map of the special locations the exam expects you to recognize:

| Directory | What it holds |
|---|---|
| `/etc` | System-wide configuration files (plain text) |
| `/var/log` | Log files written by the system and services |
| `/tmp` | Temporary files, world-writable, often cleared at boot |
| `/var/tmp` | Temporary files that should survive reboots |
| `/dev` | Device files representing hardware and pseudo-devices |
| `/proc` | Virtual filesystem exposing kernel and process information |
| `/sys` | Virtual filesystem exposing hardware and driver details |

### Temporary directories: /tmp and /var/tmp

Programs constantly need scratch space — a place to unpack an archive, hold a download in progress, or store a lock file. Linux provides two standard locations:

- **`/tmp`** — for short-lived data. Most distributions empty it at every boot (some mount it as a RAM-backed `tmpfs`, so its contents never touch the disk). Never store anything you want to keep in `/tmp`.
- **`/var/tmp`** — for temporary data that should **persist across reboots**, such as a resumable download or an editor's crash-recovery file.

Both are writable by every user on the system, which raises an obvious question: what stops user `alice` from deleting user `bob`'s temporary files? Recall from Topic 5.3 that deleting a file requires write permission *on the directory* — and everyone has that here. The answer is the sticky bit.

### The sticky bit

Look at the permissions of `/tmp`:

```
$ ls -ld /tmp /var/tmp
drwxrwxrwt 15 root root 4096 Jul  7 09:14 /tmp
drwxrwxrwt  5 root root 4096 Jul  5 22:03 /var/tmp
```

The final character is `t` instead of `x`. That is the **sticky bit** (also called the *restricted deletion flag*): in a directory with the sticky bit set, a file can be deleted or renamed **only by the file's owner, the directory's owner, or root** — even though the directory itself is world-writable. That single bit is what makes shared temporary directories safe.

In octal notation the sticky bit is a leading `1`, so `/tmp`'s mode is `1777`:

```
$ chmod 1777 shared-dir     # rwxrwxrwt — world-writable, sticky
$ chmod +t shared-dir       # symbolic form: just add the sticky bit
```

A capital `T` in a listing means the sticky bit is set but the directory lacks execute permission for others — worth recognizing, though rare in practice.

## Virtual (in-memory) filesystems

Three directories look like ordinary directory trees but contain no files on disk at all — the kernel generates their contents on the fly:

### /dev — device files

Every piece of hardware (and several pseudo-devices) appears here as a file, so programs can talk to devices using ordinary read and write operations. Examples: `/dev/sda` (first disk), `/dev/sda1` (its first partition), `/dev/tty1` (a console terminal).

Two pseudo-devices are exam favorites:

- **`/dev/null`** — discards everything written to it and returns nothing when read. Classic use: silencing unwanted command output.
- **`/dev/zero`** — produces an endless stream of zero bytes, useful for creating empty files of a given size.
- **`/dev/urandom`** — produces random bytes, e.g. for generating passwords or keys.

```
$ find /nonexistent 2> /dev/null          # throw away the error messages
$ dd if=/dev/zero of=empty.img bs=1M count=10   # a 10 MiB file of zeros
```

### /proc — processes and kernel state

Each running process gets a numbered subdirectory (`/proc/1234`) describing it, and top-level files expose kernel information. The files report a size of 0 because their contents are produced the moment you read them:

```
$ cat /proc/cpuinfo | head -3
processor	: 0
vendor_id	: GenuineIntel
model name	: Intel(R) Core(TM) i7-1165G7 @ 2.80GHz

$ cat /proc/meminfo | head -2
MemTotal:       16218452 kB
MemFree:         9846120 kB
```

Other useful entries: `/proc/version` (kernel version), `/proc/mounts` (mounted filesystems), `/proc/cmdline` (kernel boot parameters). Tools like `top` and `free` get their data from `/proc`.

### /sys — hardware and drivers

Where `/proc` focuses on processes and kernel state, `/sys` (the *sysfs* filesystem) presents a structured view of the hardware the kernel has detected — devices, buses, drivers — one value per file. For example, `/sys/class/net/` lists your network interfaces as directories.

Nothing under `/dev`, `/proc`, or `/sys` should be backed up: it is all recreated by the kernel at every boot.

## Links: extra names for files

The `ln` command lets one file be reachable under several names. There are two kinds of links, and telling them apart is the core skill of this topic.

### Hard links

A hard link is a **second directory entry pointing to the same data on disk** (the same *inode*). Created with `ln` and no options:

```
$ echo "original content" > file.txt
$ ln file.txt hardlink.txt
$ ls -li file.txt hardlink.txt
5252 -rw-r--r-- 2 carol carol 17 Jul  7 10:02 file.txt
5252 -rw-r--r-- 2 carol carol 17 Jul  7 10:02 hardlink.txt
```

Note with `ls -i` that both names share the same inode number (`5252`), and the link count after the permissions has risen to `2`. The two names are completely equal — neither is "the real one". Editing through either name changes the shared content; deleting one name leaves the data intact until the **last** name is removed.

Limitations of hard links:

- They cannot span filesystems (an inode number only makes sense within one filesystem).
- They cannot point to directories.

### Symbolic (soft) links

A symbolic link is a **separate small file that stores a path** to another file. Created with `ln -s` (source first, link name second):

```
$ ln -s file.txt symlink.txt
$ ls -l symlink.txt
lrwxrwxrwx 1 carol carol 8 Jul  7 10:05 symlink.txt -> file.txt
```

Symlinks are easy to spot: the type character is `l`, and `ls -l` shows the target after `->`. The permissions on the link itself (`rwxrwxrwx`) are meaningless — what matters are the target's permissions.

Symbolic links can do everything hard links cannot: they may cross filesystems and may point to directories. The price is fragility — if the target is moved or deleted, the link **dangles** (points to nothing) and any attempt to use it fails:

```
$ rm file.txt
$ cat symlink.txt
cat: symlink.txt: No such file or directory
```

Tip: when creating a symlink with a relative target path, the path is interpreted **relative to the link's location**, not to your current directory. The safest habit is to `cd` into the directory where the link will live before running `ln -s`.

### Hard vs. symbolic — summary

| | Hard link | Symbolic link |
|---|---|---|
| Command | `ln target name` | `ln -s target name` |
| What it is | Another name for the same inode | A file containing a path |
| Across filesystems | No | Yes |
| To a directory | No | Yes |
| If target is deleted | Data survives while any name remains | Link dangles (broken) |
| Visible in `ls -l` | Indistinguishable from the file; link count > 1 | Type `l` and `-> target` |

Symbolic links are used throughout the system itself — for example, on many distributions `/bin` is a symlink to `/usr/bin`, and `sh` is typically a symlink to the actual shell:

```
$ ls -l /bin/sh
lrwxrwxrwx 1 root root 4 Mar 12 08:31 /bin/sh -> dash
```

## Key takeaways

- `/tmp` and `/var/tmp` are world-writable temporary directories; `/tmp` is usually wiped at boot, `/var/tmp` persists.
- The **sticky bit** (`t` in `ls -l`, leading `1` in octal, `chmod +t`) restricts deletion in shared directories to each file's owner.
- `/dev`, `/proc`, and `/sys` are virtual filesystems generated by the kernel; `/dev/null` discards data, `/proc` exposes process and kernel info, `/sys` exposes hardware details.
- `ln` creates **hard links** (same inode, same filesystem, no directories); `ln -s` creates **symbolic links** (a path pointer, can cross filesystems and link directories, breaks if the target disappears).

## Referencias

- LPI Learning Materials, Lesson 5.4 — Special Directories and Files: https://learning.lpi.org/en/learning-materials/010-160/5/5.4/
- LPI Linux Essentials Objectives (version 1.6), Topic 5.4: https://www.lpi.org/our-certifications/exam-010-objectives/
- `ln(1)` manual page (GNU coreutils): https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html
- `chmod(1)` manual page (GNU coreutils): https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html
- The Linux Kernel documentation — The /proc Filesystem: https://docs.kernel.org/filesystems/proc.html
- Filesystem Hierarchy Standard (FHS) 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html