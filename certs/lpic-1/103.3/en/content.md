# 103.3 — Perform Basic File Management

**LPIC-1 v5.0 · Exam 101-500 · Weight: 6.25**

**Key files, terms and utilities:** `cp`, `find`, `mkdir`, `mv`, `ls`, `rm`, `rmdir`, `touch`, `tar`, `cpio`, `dd`, `file`, `gzip`, `gunzip`, `bzip2`, `bunzip2`, `xz`, `unxz`, file globbing.

---

## 1. The production problem

Every incident you will ever run has a file-management operation somewhere in its blast radius. Not because the commands are hard, but because their *semantics* are counterintuitive at scale:

- **A `df` that reports 100% full while `du` reports 40% used.** Nobody "forgot to delete" anything. A process is holding an open file descriptor to an already-unlinked 8 GiB log. `rm` never frees space; it decrements a link count.
- **A `mv` of a 400 GiB dataset that took 3 hours and left a half-written file when the SSH session died.** `mv` is atomic *within* a filesystem and a non-atomic copy-then-delete *across* filesystems. Nothing in the command tells you which one you got.
- **A nightly `find /var/log -mtime +7 -exec rm {} \;` cleanup job that saturated the node's CPU with 40,000 `fork()`+`execve()` pairs**, and that silently skipped files whose names contained spaces the day someone enabled a badly-configured log shipper.
- **A `for f in *.log` loop that died with `-bash: /bin/rm: Argument list too long`** on the one node that had 300,000 rotated files — the exact node you needed to recover.
- **A container image whose layers had a different SHA on every build**, because `tar` embedded `mtime`, UID/GID and directory order from the build host.
- **A `dd` reading from a pipe that silently produced a truncated disk image**, because `dd` honours short reads unless you tell it not to.

None of these are exotic. All of them are direct consequences of the POSIX file-model and the default flags of coreutils, GNU findutils, GNU tar and GNU cpio. This objective is where you stop treating `cp`/`mv`/`rm` as verbs and start treating them as *system calls with a CLI wrapper*.

The architectural framing for the rest of this document:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Shell (bash)                                                        │
│   ├── brace expansion  {a,b}      ← NOT a glob, no filesystem access │
│   ├── pathname expansion * ? [ ]  ← reads directories, sorts result  │
│   └── builds argv[]               ← bounded by ARG_MAX / MAX_ARG_STRLEN
├─────────────────────────────────────────────────────────────────────┤
│  Userspace tool (cp, mv, rm, find, tar, cpio, dd)                   │
│   └── policy: recursion, attribute preservation, error handling      │
├─────────────────────────────────────────────────────────────────────┤
│  System calls                                                        │
│   openat(2) statx(2) getdents64(2) linkat(2) unlinkat(2)             │
│   renameat2(2) copy_file_range(2) ioctl(FICLONE) utimensat(2)        │
├─────────────────────────────────────────────────────────────────────┤
│  VFS → filesystem (ext4 / XFS / Btrfs / overlayfs / tmpfs / NFS)     │
│   inodes · directory entries · extents · CoW · journal               │
└─────────────────────────────────────────────────────────────────────┘
```

Every trade-off in this objective lives at one of those four layers. Knowing *which* layer a behaviour comes from is the difference between a fix and a superstition.

---

## 2. The substrate: what a "file" actually is

A file is an **inode** — a metadata record holding mode, UID, GID, timestamps, size, link count and pointers to data blocks. A file is **not** its name. A name is a **directory entry**: a (name → inode number) tuple stored inside a directory, which is itself an inode.

```
$ stat -c 'name=%n inode=%i links=%h size=%s alloc=%b*%B mode=%A fs=%d' /etc/passwd
name=/etc/passwd inode=1310726 links=1 size=2938 alloc=8*512 mode=-rw-r--r-- fs=64768
```

Four consequences that generate real production behaviour:

| Fact | Consequence |
|---|---|
| Names point at inodes, inodes do not point at names | `rm` cannot "delete a file"; it removes one name and decrements `st_nlink`. Data is reclaimed when `st_nlink == 0` **and** no process holds an open fd. |
| Inode numbers are unique **per filesystem**, not globally | `mv` across a mount boundary cannot be a rename; it must copy. `find -xdev` exists for this reason. |
| Directory entries are unordered on disk | `ls` sorts for you; `readdir(2)`/`find` do not. Reproducible archives require `--sort=name` or `sort -z`. |
| Timestamps are three (four with `birth`) and only two are settable | `atime`, `mtime` are settable via `utimensat(2)`; `ctime` is set by the kernel on *any* inode change and cannot be forged with `touch`. |

```
$ stat /var/log/syslog
  File: /var/log/syslog
  Size: 1048576   	Blocks: 2048       IO Block: 4096   regular file
Device: 253,0	Inode: 262157      Links: 1
Access: (0640/-rw-r-----)  Uid: (  104/  syslog)   Gid: (   4/     adm)
Access: 2026-08-26 03:12:01.442918233 +0000
Modify: 2026-08-26 09:41:17.884213011 +0000
Change: 2026-08-26 09:41:17.884213011 +0000
 Birth: 2026-08-19 00:00:03.117884210 +0000
```

**Timestamp semantics — memorise this table, it drives `find` and `tar`:**

| Stamp | Set by | Changed by | Forgeable | Backup relevance |
|---|---|---|---|---|
| `atime` | read of file data | `read(2)`, `execve(2)` | yes (`touch -a`) | Unreliable: `relatime` is the default mount option and only refreshes if the old `atime` predates `mtime`/`ctime` or is >24 h old. `noatime`/`lazytime` suppress it further. |
| `mtime` | write of file **data** | `write(2)`, `truncate(2)` | yes (`touch -m`) | What `tar --newer-mtime` and `find -mtime` use. Forgeable ⇒ not a security control. |
| `ctime` | change of **inode** | `chmod`, `chown`, `rename`, link count change, and every data write | **no** | What `tar -N/--after-date` also consults, and the only stamp an attacker cannot roll back with `touch`. |
| `btime` | file creation | nothing | no | ext4/XFS/Btrfs only; exposed via `statx(2)`, shown by `stat` as `Birth:`. Not usable in `find`. |

```
$ touch -d '2001-01-01 00:00:00' /tmp/evidence
$ stat -c 'M=%y  C=%z' /tmp/evidence
M=2001-01-01 00:00:00.000000000 +0000  C=2026-08-26 09:44:52.113000000 +0000
```

The `mtime` says 2001. The `ctime` says the file was touched 12 seconds ago. This is why forensic sweeps use `find -newerct`, never `-newermt`.

---

## 3. Listing and inspecting: `ls`, `stat`, `file`

### 3.1 `ls` is not a cheap command

`ls` performs one `getdents64(2)` loop plus — for anything beyond bare names — one `statx(2)` **per entry**. On a directory with 500,000 entries on network storage, `ls -l` is half a million round trips.

| Invocation | Syscalls per entry | Sorts | Use when |
|---|---|---|---|
| `ls` | 0 extra (colour/classify may add `statx`) | yes (name) | interactive |
| `ls -l` | 1 `statx` + name lookups for uid/gid | yes | you need metadata |
| `ls -f` | 0 (implies `-aU`, disables sort *and* colour) | **no** | huge directories, emergency triage |
| `ls -U` | 0 extra | no | directory-order enumeration |
| `ls -1` | 0 extra | yes | piping (still unsafe for odd names) |

```
$ time ls -l /var/spool/postfix/deferred | wc -l
412337

real	0m19.884s
user	0m2.113s
sys	0m6.402s

$ time ls -f /var/spool/postfix/deferred | wc -l
412339

real	0m0.712s
user	0m0.188s
sys	0m0.404s
```

Flags that matter operationally:

```
$ ls -lai --time-style=full-iso --block-size=1 /srv/data
total 8589938688
 262145 drwxr-xr-x. 3 svc  svc         4096 2026-08-26 09:50:11.000000000 +0000 .
      2 drwxr-xr-x. 8 root root        4096 2026-08-01 10:00:00.000000000 +0000 ..
 262149 -rw-r-----. 2 svc  svc   4294967296 2026-08-26 09:12:44.000000000 +0000 shard-00.db
 262150 -rw-r-----. 1 svc  svc   4294967296 2026-08-26 09:12:44.000000000 +0000 shard-01.db
```

`shard-00.db` shows link count `2` — a second name points at that inode somewhere. Deleting this path frees **zero** bytes.

Other high-value flags: `-h` (human sizes), `-S` (sort by size), `-t` (sort by mtime), `-r` (reverse), `-R` (recurse), `-d` (the directory itself, not its contents — essential: `ls -ld /srv` vs `ls -l /srv`), `-i` (inode), `--color=never` (mandatory in scripts; colour codes are ANSI escapes in your data).

> **Never parse `ls` output in a script.** Filenames may contain spaces, newlines, quotes and ANSI escapes. `ls` mangles them (`-b`, `-q`, `--quoting-style`) inconsistently. Use `find -print0` or a shell glob.

### 3.2 `file` — content typing, not extension typing

`file(1)` classifies by reading magic bytes through `libmagic` against the compiled database `/usr/share/misc/magic.mgc`. Extensions are irrelevant to it.

```
$ file /bin/ls /etc/passwd /tmp/backup.tar.gz /dev/sda1 /proc/self/exe
/bin/ls:        ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=897d..., for GNU/Linux 3.2.0, stripped
/etc/passwd:    ASCII text
/tmp/backup.tar.gz: gzip compressed data, from Unix, original size modulo 2^32 1075200
/dev/sda1:      block special (8/1)
/proc/self/exe: symbolic link to /usr/bin/file
```

| Flag | Effect | Production use |
|---|---|---|
| `-b`, `--brief` | omit filename | scripting |
| `-i`, `--mime` | `text/plain; charset=us-ascii` | HTTP content negotiation, upload validation |
| `--mime-type` | `text/plain` only | dispatch tables |
| `-s` | read block/character devices instead of just calling them "special" | **identify a raw disk's partition table / filesystem** |
| `-z` | look *inside* compressed files | archive triage |
| `-L` | follow symlinks | |
| `-f LIST` | read filenames from a file | bulk classification |
| `-F SEP` | change the `: ` separator | parseable output |

```
$ sudo file -s /dev/sda1 /dev/sda2
/dev/sda1: Linux rev 1.0 ext4 filesystem data, UUID=6f2a-... (needs journal recovery) (extents) (64bit) (large files) (huge files)
/dev/sda2: LVM2 PV (Linux Logical Volume Manager), UUID: 3kQ1..., size: 213674622976

$ file -z /var/cache/artifacts/app-2.4.1.tar.zst
/var/cache/artifacts/app-2.4.1.tar.zst: POSIX tar archive (GNU) (Zstandard compressed data, ...)
```

`(needs journal recovery)` on a device you were about to `dd` is a full stop: image it read-only, do not mount it read-write.

---

## 4. `cp` — the copy path is not one path

`cp` looks like one operation. Underneath, modern GNU coreutils (9.x) choose among **four** data-movement strategies, and the one you get changes throughput by two orders of magnitude.

```
        ┌── same fs, supports FICLONE (Btrfs/XFS-reflink/OCFS2) ──► reflink clone: O(1), no data copied
cp ─────┼── copy_file_range(2) available ─────────────────────────► in-kernel copy, no user-space bounce
        ├── source has holes and --sparse=auto ────────────────────► holes preserved via lseek(SEEK_HOLE)
        └── fallback ─────────────────────────────────────────────► read(2)/write(2) loop through a buffer
```

```
$ strace -f -e trace=copy_file_range,ioctl,read,write cp big.img copy.img 2>&1 | head -5
ioctl(4, BTRFS_IOC_CLONE or FICLONE, 3) = 0
close(3)                                = 0
close(4)                                = 0

$ time cp --reflink=always /srv/vm/base.qcow2 /srv/vm/clone.qcow2
real	0m0.011s

$ time cp --reflink=never /srv/vm/base.qcow2 /srv/vm/clone.qcow2
real	0m41.907s
```

Since coreutils 9.0, `cp`, `mv` and `install` use `copy_file_range(2)` where available, which on reflink-capable filesystems yields the clone implicitly. `--reflink={always,auto,never}` gives explicit control; `always` fails loudly if cloning is impossible — that is exactly what you want in a snapshot pipeline, so you never silently fall back to a 40-second full copy.

### 4.1 Attribute preservation — the flag matrix

| Flag | Preserves | Notes |
|---|---|---|
| *(none)* | nothing but data; mode is `source mode & ~umask` for new files | default |
| `-p` | mode, ownership (if permitted), timestamps | shorthand for `--preserve=mode,ownership,timestamps` |
| `--preserve=all` | above **+ context (SELinux) + links + xattrs** | what a migration needs |
| `-a`, `--archive` | `-dR --preserve=all` | recursive, no dereference, everything |
| `-d` | copies symlinks as symlinks; preserves hard links | `= --no-dereference --preserve=links` |
| `-L` | dereference **all** symlinks (copy targets) | expands a symlink farm into real data |
| `-P` | never dereference | default for `-R` in GNU cp |
| `-r` / `-R` | recurse into directories | `-r` copies special files as regular files in some implementations; GNU treats `-r` = `-R` |
| `-u` | copy only if source newer or sizes differ | crude sync; not content-aware |
| `-n` | never overwrite (racy: stat-then-open) | prefer `--update=none` on coreutils ≥ 9.3 |
| `-i` | interactive | useless in automation; often shell-aliased — use `\cp` or `command cp` |
| `-l` | hard link instead of copying | zero-cost "copy" within one filesystem |
| `-s` | symlink instead of copying | requires absolute paths unless `-r` |
| `--sparse=WHEN` | `auto` (default) / `always` / `never` | `always` makes zero-runs into holes even if source was dense |
| `-x`, `--one-file-system` | do not cross mount points | **mandatory** when copying `/` — otherwise you recurse into `/proc`, `/sys`, `/dev` |
| `-t DIR` / `-T` | explicit target dir / treat target as non-directory | kills the "did it become `dst/src` or `dst`?" ambiguity |
| `-v` | verbose | |
| `-b`, `--backup=CONTROL` | back up destination before overwrite | `numbered`, `simple`, `existing` |

### 4.2 The `-T` ambiguity — a real outage class

```
$ ls /srv
config

$ cp -a build /srv/config          # /srv/config EXISTS as a directory
$ ls /srv/config
build                              # ← nested! you wanted the contents

$ rm -rf /srv/config/build
$ cp -aT build /srv/config         # -T: treat destination as a plain name
$ ls /srv/config
app.conf  tls/
```

Without `-T`, `cp`'s destination semantics depend on whether the target already exists — meaning your deployment script behaves differently on first run and on redeploy. Always use `-T` (or `-t`) in automation.

### 4.3 The `.*` glob trap

```
$ cp -a /old/app/. /new/app/        # correct: the "/." idiom copies contents INCLUDING dotfiles
$ cp -a /old/app/* /new/app/        # WRONG: silently omits .env, .git, .dockerignore
$ cp -a /old/app/.* /new/app/       # CATASTROPHIC: .* matches "." and ".." → tries to copy the PARENT
```

`cp -a src/. dst/` is the only form that is both complete and safe.

### 4.4 `cp` vs `rsync` vs `tar`-pipe vs `dd` — bulk-copy trade-offs

| Dimension | `cp -a` | `rsync -aHAX` | `tar -C src -cf - . \| tar -C dst -xf -` | `dd` |
|---|---|---|---|---|
| Resumable | no (restarts whole files) | **yes** (`--partial --append-verify`) | no | yes (`skip=`/`seek=`) |
| Delta transfer | no | yes (rolling checksum) | no | no |
| Over the network | no (needs a mount) | **native** (SSH/daemon) | yes (via `ssh`) | yes (via `ssh`/`nc`) |
| Hard links preserved | `-a` yes | `-H` yes | yes | n/a (block-level) |
| xattrs / ACLs / SELinux | `--preserve=all` | `-AX` + `--xattrs` | `--xattrs --acls --selinux` | n/a |
| Sparse handling | `--sparse=always` | `-S` | `--sparse` | `conv=sparse` |
| Reflink / CoW clone | **yes** | no | no | no |
| Progress | no | `--info=progress2` | `pv` in the pipe | `status=progress` |
| Millions of small files | good | slow (per-file protocol) | **best** (single stream) | n/a |
| Copies unmounted/raw devices | no | no | no | **yes** |
| Idempotent re-run | overwrites all | only deltas | overwrites all | overwrites all |

**Rule of thumb:** same host + same filesystem → `cp -a` (reflinks). Same host + huge file count → `tar`-pipe. Across the network or resumable → `rsync`. Raw block device / bootloader / forensic image → `dd`.

### 4.5 Durability: `cp` returning does **not** mean the data is on disk

```
$ cp firmware.bin /mnt/usb/ && umount /mnt/usb   # umount flushes — safe
$ cp firmware.bin /mnt/usb/ && echo done         # data may still be in page cache
$ cp firmware.bin /mnt/usb/ && sync -f /mnt/usb/firmware.bin   # explicit, per-filesystem flush
```

`dd` has `conv=fsync` / `oflag=direct` for this; `cp` has nothing equivalent — you must call `sync(1)`.

---

## 5. `mv` — `rename(2)` and the EXDEV cliff

`mv` first attempts `renameat2(2)`. Within one filesystem that is a **directory-entry edit**: atomic, instantaneous, size-independent, and it does not touch the data blocks at all.

```
$ time mv /srv/data/shard-00.db /srv/data/archive/shard-00.db     # same fs
real	0m0.002s

$ time mv /srv/data/shard-00.db /mnt/nfs/archive/shard-00.db      # different fs → EXDEV
real	1m52.331s
```

On `EXDEV` (`Invalid cross-device link`), GNU `mv` degrades to *copy then unlink*, and the guarantees collapse:

| Property | Same filesystem (`rename`) | Cross filesystem (copy + unlink) |
|---|---|---|
| Atomic | **yes** — observers see old name or new name, never both, never neither | **no** — partial destination is visible |
| Duration | O(1) | O(size) |
| Inode preserved | yes (same inode number, hard links intact) | **no** — new inode, hard-link groups broken |
| Interruption safety | nothing to clean up | leaves a truncated destination; source still present |
| Needs 2× space | no | **yes** |
| `ctime` change | yes (parent dir changed) | destination gets a fresh `ctime` |

```
$ stat -c %i /srv/data/f ; mv /srv/data/f /srv/other/f ; stat -c %i /srv/other/f
262401
262401                     ← same inode: it was a rename

$ df --output=source /srv/data /mnt/nfs | tail -n +2
/dev/mapper/vg0-data
nfs01:/exports/archive     ← different sources ⇒ mv will be a copy
```

**The atomic-publish idiom.** Because `rename(2)` is atomic *within* a filesystem, this is how you publish configuration or artefacts without ever exposing a partial file to a reader:

```
$ tmp=$(mktemp /etc/app/config.json.XXXXXX)   # same directory ⇒ same filesystem, guaranteed
$ render-config > "$tmp"
$ chmod 0644 "$tmp"
$ mv -f "$tmp" /etc/app/config.json           # atomic swap; readers see old or new, never half
```

Writing the temp file to `/tmp` and then `mv`-ing it into `/etc` **breaks this guarantee** on any system where `/tmp` is `tmpfs` or a separate mount — you get a non-atomic copy and a window where the config is truncated.

Flags:

| Flag | Meaning |
|---|---|
| `-f` | force overwrite, no prompt (default when not a tty) |
| `-i` | prompt before overwrite |
| `-n` | no-clobber. Racy on older coreutils (stat-then-rename); coreutils ≥ 9.5 uses `renameat2(RENAME_NOREPLACE)` where supported |
| `-u` | move only if source newer |
| `-t DIR` / `-T` | same disambiguation as `cp` |
| `-b`, `--backup=CONTROL` | back up the destination |
| `-v` | verbose |
| `--strip-trailing-slashes` | avoid symlink-directory surprises |

```
$ mv -bv --backup=numbered app.jar /opt/app/app.jar
renamed 'app.jar' -> '/opt/app/app.jar' (backup: '/opt/app/app.jar.~3~')
```

---

## 6. `rm`, `rmdir`, and why deletion frees nothing

`rm` calls `unlinkat(2)`. That removes a **directory entry** and decrements `st_nlink`. The inode and its data blocks are released only when *both* the link count reaches zero *and* the kernel's open-file reference count reaches zero.

This is the single most common "disk full" incident in production.

```
# df -h /var
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var        50G   50G     0 100% /var

# du -sh /var
19G	/var                       ← 31 GiB unaccounted for

# lsof +L1
COMMAND     PID   USER   FD   TYPE DEVICE   SIZE/OFF NLINK    NODE NAME
java       2841 tomcat   57w   REG  253,2 31138512896     0  786451 /var/log/tomcat/catalina.out (deleted)
```

`NLINK 0` + `(deleted)` = the file is unlinked but pinned open. `du` cannot see it (no name to walk). Recovery, in order of preference:

```
# ls -l /proc/2841/fd/57
l-wx------ 1 root root 64 Aug 26 10:02 /proc/2841/fd/57 -> '/var/log/tomcat/catalina.out (deleted)'

# truncate -s 0 /proc/2841/fd/57      # reclaim space WITHOUT restarting the process
# df -h --output=avail /var
Avail
  30G
```

`> /proc/PID/fd/N` also works but only if your shell can open the fd path for writing. Restarting the process works too and is the blunt instrument. Note that this is why log rotation must use `copytruncate` **or** signal the daemon to reopen (`logrotate` `postrotate` + `kill -USR1`); a bare `rm` of a live log leaks the space until restart.

### 6.1 `rm` flag semantics and guardrails

| Flag | Meaning | Danger |
|---|---|---|
| `-r`, `-R` | recurse | the one that ends careers |
| `-f` | ignore nonexistent files, never prompt, **exit 0 even if nothing matched** | masks failures in scripts |
| `-i` | prompt per file | `-I` prompts once for >3 files or recursion — the sane middle ground |
| `-d` | remove empty directories | like `rmdir` but composable |
| `-v` | verbose | use it in destructive automation, always |
| `--one-file-system` | refuse to recurse into a different mount | **essential** for `rm -rf` of a chroot or container rootfs |
| `--preserve-root` | refuse to operate on `/` (**default**) | |
| `--no-preserve-root` | disable that protection | there is no legitimate use in automation |

```
$ rm -rf /
rm: it is dangerous to operate recursively on '/'
rm: use --no-preserve-root to override this failsafe
```

`--preserve-root` protects `/` and nothing else. `rm -rf /*`, `rm -rf /var`, and `rm -rf "$UNSET_VAR/"` are all unprotected.

### 6.2 Defensive deletion patterns

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. ':?' aborts with an error if the variable is unset OR empty.
#    Without it, an unset TARGET makes this "rm -rf /*".
rm -rf -- "${TARGET:?TARGET must be set}"/*

# 2. Refuse to cross a mount boundary while wiping a container rootfs.
rm -rf --one-file-system -- "${ROOTFS:?}"

# 3. End-of-options guard: a file literally named "-rf" is not a flag.
rm -- "$file"        # or:  rm ./"$file"
```

```
$ touch -- -rf
$ rm -rf
rm: missing operand                    # the shell handed rm a flag, not a name
$ rm -- -rf
$ ls
```

### 6.3 `rmdir`

`rmdir` calls `rmdir(2)` and fails on a non-empty directory. That failure is a feature: it is the only safe "remove this if I'm the last user" primitive.

```
$ rmdir /srv/cache
rmdir: failed to remove '/srv/cache': Directory not empty

$ rmdir -p /srv/a/b/c            # remove c, then b, then a — stopping at the first non-empty
$ rmdir --ignore-fail-on-non-empty /srv/shared/lock.d   # idempotent teardown, exit 0
```

### 6.4 Deleting a file whose name you cannot type

```
$ ls -li
 262403 -rw-r--r-- 1 root root  0 Aug 26 10:11 'bad\nname'
$ find . -maxdepth 1 -inum 262403 -delete
```

`-inum` sidesteps quoting entirely. Same technique for names containing newlines, backspaces or ANSI escapes.

### 6.5 `shred` — and why it usually does nothing

`shred -u` overwrites then unlinks. It is only meaningful on a filesystem that overwrites blocks in place. It is **ineffective** on: journaled filesystems in `data=journal` mode, any copy-on-write filesystem (Btrfs, ZFS), any SSD/NVMe (wear levelling relocates writes), RAID with parity, network filesystems, and snapshotted volumes. For those, the answer is full-disk encryption + key destruction, not `shred`.

---

## 7. `mkdir` and `touch`

### 7.1 `mkdir`

```
$ umask
0022
$ mkdir plain && stat -c %a plain
755                            # 0777 & ~umask

$ mkdir -m 0700 secret && stat -c %a secret
700                            # -m bypasses umask for THIS directory

$ mkdir -pv /srv/a/b/c
mkdir: created directory '/srv/a'
mkdir: created directory '/srv/a/b'
mkdir: created directory '/srv/a/b/c'

$ mkdir -p /srv/a/b/c && echo "exit=$?"
exit=0                         # -p is idempotent: existing directories are not an error
```

**The `-p -m` gotcha:** `-m` applies to the *named* directory only. Intermediate parents are created with `u+wx` modified by umask — they will be `0755`, not `0700`.

```
$ umask 022; mkdir -p -m 0700 /srv/vault/keys
$ stat -c '%a %n' /srv/vault /srv/vault/keys
755 /srv/vault                  ← world-traversable parent
700 /srv/vault/keys
```

If the whole path must be private, create it and then `chmod` explicitly, or create each level with its own `mkdir -m`.

Brace expansion + `-p` is the idiomatic tree builder:

```
$ mkdir -p /srv/app/{bin,etc,var/{log,cache,run},share/doc}
$ find /srv/app -type d | sort
/srv/app
/srv/app/bin
/srv/app/etc
/srv/app/share
/srv/app/share/doc
/srv/app/var
/srv/app/var/cache
/srv/app/var/log
/srv/app/var/run
```

`mkdir -p` is **not atomic** across levels but *is* race-safe at each level (it tolerates `EEXIST`). `mkdir dir` without `-p` **is** an atomic test-and-set — which makes it a correct lock primitive, unlike `[ -e lock ] || touch lock`:

```bash
if mkdir /var/run/job.lock 2>/dev/null; then
    trap 'rmdir /var/run/job.lock' EXIT
    do_work
else
    echo "another instance holds the lock" >&2; exit 1
fi
```

### 7.2 `touch`

`touch` does two things: create empty files (`open(O_CREAT)`) and set timestamps (`utimensat(2)`).

| Flag | Effect |
|---|---|
| *(none)* | set `atime` and `mtime` to now; create if absent |
| `-a` | `atime` only |
| `-m` | `mtime` only |
| `-c`, `--no-create` | never create; only stamp existing files |
| `-d STRING` | date from a free-form string (`'2 hours ago'`, `'2026-08-26T09:00:00Z'`) |
| `-t [[CC]YY]MMDDhhmm[.ss]` | POSIX numeric form |
| `-r REF` | copy timestamps from a reference file |
| `-h` | stamp the symlink itself, not its target |

```
$ touch -t 202608260900.00 marker
$ find /var/log -newer marker -type f       # everything written since 09:00
/var/log/syslog
/var/log/nginx/access.log

$ touch -r /etc/passwd /tmp/clone && stat -c '%y' /etc/passwd /tmp/clone
2026-08-14 11:02:19.000000000 +0000
2026-08-14 11:02:19.000000000 +0000
```

The reference-file trick is the classic incremental-backup marker, and it is exactly what `find -newer` consumes.

---

## 8. File globbing — the shell does it, the command never sees it

**The single most important fact in this objective:** `rm *.log` does not pass `*.log` to `rm`. Bash expands the pattern by reading the directory, sorts the matches, and hands `rm` a fully-materialised `argv[]`. Every property below follows from that.

### 8.1 Simple wildcards (POSIX pathname expansion)

| Pattern | Matches | Does **not** match |
|---|---|---|
| `*` | any string, including empty | a leading `.`; a `/` |
| `?` | exactly one character | a leading `.`; a `/` |
| `[abc]` | one of `a`, `b`, `c` | |
| `[!abc]` / `[^abc]` | any one char **not** in the set | (`^` is a bash extension; `!` is POSIX) |
| `[a-z]` | a **collation** range — locale dependent! | |
| `[[:digit:]]` | POSIX character class — locale safe | |

```
$ ls
a.log  B.LOG  c.log  10.log  .hidden.log

$ echo *.log
10.log a.log c.log                # B.LOG excluded (case), .hidden.log excluded (leading dot)

$ echo [[:digit:]]*.log
10.log

$ LC_ALL=en_US.UTF-8 bash -c 'echo [a-c]*'    # en_US collation is case-insensitive-ish
a.log B.LOG c.log
$ LC_ALL=C bash -c 'echo [a-c]*'              # C collation is pure byte order
a.log c.log
```

> **Always set `LC_COLLATE=C` (or use `[[:alpha:]]` classes) in scripts that use ranges.** A `[a-z]` pattern that behaves one way in your shell and another way under `cron` (which has a minimal environment) is a genuine and common production bug.

Matching a literal dot requires typing it — `*` never matches a leading `.`:

```
$ echo .*                # includes "." and ".." — the source of countless disasters
. .. .hidden.log
$ echo .[!.]* ..?*       # the safe "all dotfiles, no . or .." idiom
.hidden.log
```

### 8.2 Advanced globbing (bash `shopt`)

| Option | Effect | Enable |
|---|---|---|
| `extglob` | `?(p)` 0–1, `*(p)` 0+, `+(p)` 1+, `@(p)` exactly one, `!(p)` anything except | `shopt -s extglob` |
| `globstar` | `**` crosses directory boundaries recursively; `**/` matches directories only | `shopt -s globstar` |
| `nullglob` | unmatched pattern expands to **nothing** instead of itself | `shopt -s nullglob` |
| `failglob` | unmatched pattern is a **hard error** | `shopt -s failglob` |
| `dotglob` | `*` includes dotfiles (but never `.`/`..`) | `shopt -s dotglob` |
| `nocaseglob` | case-insensitive matching | `shopt -s nocaseglob` |
| `GLOBIGNORE` | colon-separated patterns to exclude; setting it also implies `dotglob` semantics for `.`/`..` | variable |

```
$ shopt -s extglob
$ ls
app.log  app.log.1  app.log.2.gz  app.log.3.gz  config.yaml

$ echo !(*.gz)                     # everything that is not gzipped
app.log app.log.1 config.yaml

$ echo app.log.+([0-9]).gz         # numbered, gzipped rotations only
app.log.2.gz app.log.3.gz

$ shopt -s globstar
$ echo **/*.yaml
config.yaml  k8s/base/deploy.yaml  k8s/overlays/prod/kustomization.yaml
```

**The `nullglob` trap that bites every shell script:**

```bash
# Default behaviour: an unmatched pattern is passed through LITERALLY.
$ cd /empty-dir
$ for f in *.log; do echo "processing $f"; done
processing *.log                   # ← there is no file named "*.log"

# rm then does something entirely different than you intended:
$ rm -f *.log                      # harmless here (-f), but "gzip *.log" errors,
                                   # and "cat *.log > merged" creates a file named "*.log"
$ shopt -s nullglob
$ for f in *.log; do echo "processing $f"; done
                                   # loop body never runs — correct
```

Set `nullglob` for loops, `failglob` for scripts that must not proceed silently.

### 8.3 Brace expansion is **not** globbing

| | Brace `{a,b}` | Glob `*?[]` |
|---|---|---|
| Order in bash expansion | **first** (before tilde, parameter, pathname) | **last** but one (before quote removal) |
| Reads the filesystem | **no** | yes |
| Unmatched result | still expands | depends on `nullglob`/`failglob` |
| Use | *generate* names (create, ranges) | *select* existing names |

```
$ echo file{1..3}.txt              # generates, regardless of what exists
file1.txt file2.txt file3.txt
$ echo file{01..10..3}.txt         # zero-padded, stepped
file01.txt file04.txt file07.txt file10.txt
$ echo {a..e}
a b c d e
$ cp /etc/nginx/nginx.conf{,.bak}  # → cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
```

### 8.4 `ARG_MAX` — where globbing physically breaks

Because the shell materialises the full argument vector, a glob matching enough files exceeds the kernel's `execve(2)` limit.

```
$ getconf ARG_MAX
2097152

$ xargs --show-limits < /dev/null
Your environment variables take up 2027 bytes
POSIX upper limit on argument length (this system): 2093077
POSIX smallest allowable upper limit on argument length (all systems): 4096
Maximum length of command we could actually use: 2091050
Size of command buffer we are actually using: 131072
Maximum parallelism (--max-procs must be no greater than): 2147483647

$ ls /var/log/app | wc -l
412337
$ rm /var/log/app/*.log
-bash: /usr/bin/rm: Argument list too long
```

Two extra limits people miss: `MAX_ARG_STRLEN` caps a **single** argument at 128 KiB (32 pages) regardless of `ARG_MAX`, and the environment block counts against the same budget — a fat `env` from a CI runner shrinks your usable argv.

Five ways out, ranked:

| Approach | Handles odd filenames | Fork cost | Notes |
|---|---|---|---|
| `find DIR -maxdepth 1 -name '*.log' -delete` | **yes** | 1 process | Best. No `exec` at all. |
| `find DIR -name '*.log' -print0 \| xargs -0 -r rm` | **yes** (`-print0`) | batched | `-r` skips the run if input is empty |
| `find DIR -name '*.log' -exec rm {} +` | **yes** | batched | equivalent to `xargs`, no pipe |
| `printf '%s\0' DIR/*.log \| xargs -0 rm` | yes | batched | still builds the glob in shell memory (no `execve` limit, but RAM) |
| shell loop `for f in DIR/*.log; do rm "$f"; done` | yes | 0 (builtin-free `rm` is external → 1 fork each) | glob is in-shell so no `E2BIG`, but N forks |

```
$ find /var/log/app -maxdepth 1 -type f -name '*.log' -delete
$ echo $?
0
```

---

## 9. `find` — a query engine for the filesystem tree

`find` is not "a file search command". It is an expression evaluator: it walks a tree and evaluates a boolean expression per node, where some operands have side effects (`-print`, `-delete`, `-exec`).

```
find [-H|-L|-P] [-D opts] [-Olevel] PATH... [EXPRESSION]
      ▲                                       ▲
      │                                       └── tests · actions · operators
      └── symlink policy
```

### 9.1 Symlink policy and traversal control

| Option | Behaviour |
|---|---|
| `-P` | **default.** Never follow symlinks; `-type l` sees links |
| `-L` | Follow symlinks; `-type` reports the *target*'s type; broken links report as `l` |
| `-H` | Follow only symlinks named on the command line |
| `-xdev` / `-mount` | Do not descend into other filesystems |
| `-maxdepth N` / `-mindepth N` | Bound recursion (**must precede other tests** for efficiency; GNU warns otherwise) |
| `-depth` | Process a directory's contents before the directory itself (post-order) — implied by `-delete` |
| `-prune` | Do not descend into the current directory (true-valued; combine with `-o`) |

`-L` on a tree containing a symlink loop is how you hang a backup job:

```
$ find -L /srv -type f | head -3
find: File system loop detected; '/srv/self/self' is part of the same file system loop as '/srv'.
```

### 9.2 Tests

| Test | Meaning | Gotcha |
|---|---|---|
| `-name PAT` / `-iname` | glob against the **basename** | pattern must be quoted or the shell eats it |
| `-path PAT` / `-ipath` | glob against the **whole path**; `*` crosses `/` | |
| `-regex PAT` | regex against whole path; `-regextype posix-extended` | anchored at both ends |
| `-type c` | `f` file, `d` dir, `l` symlink, `b` block, `c` char, `p` fifo, `s` socket | GNU accepts a list: `-type f,l` |
| `-size N[cwbkMG]` | default unit is **512-byte blocks**; `c`=bytes | **size is rounded UP** — see below |
| `-empty` | zero-length file or empty directory | |
| `-user`/`-group`/`-uid`/`-gid` | ownership | `-nouser`/`-nogroup` finds orphaned files after a UID migration |
| `-perm MODE` | exact | `-perm -MODE` = all these bits set; `-perm /MODE` = any of these bits |
| `-links N` | hard-link count | `-links +1` finds files with multiple names |
| `-inum N` | inode number | the "unquotable filename" escape hatch |
| `-mtime N` / `-atime` / `-ctime` | age in **24-hour periods**, fraction discarded | see below |
| `-mmin N` / `-amin` / `-cmin` | age in minutes — use these | |
| `-newer F` / `-newerXY REF` | X,Y ∈ {a,B,c,m,t}: `-newermt '2026-08-01'`, `-newerct '2 hours ago'` | the precise tool |
| `-fstype T` | `ext4`, `xfs`, `nfs`, `tmpfs` | pairs with `-xdev` |

**The `-mtime` rounding trap.** `find` computes `(now - mtime) / 86400` and **truncates**. So:

- `-mtime 0` → modified in the last 24 h
- `-mtime 1` → between 24 and 48 h ago
- `-mtime +1` → **strictly more than 1** after truncation ⇒ at least **48 h** ago, not 24
- `-mtime -1` → less than 24 h ago (same as `-mtime 0`)

A retention job written as `-mtime +7` keeps 8 days, not 7. Use `-mmin +10080` or `-newermt` when the boundary matters.

**The `-size` rounding trap.** Sizes are rounded up to the next whole unit *before* comparison.

```
$ truncate -s 500K half
$ find . -size -1M
.                        # the directory
                         # 'half' is NOT listed: 500K rounds UP to 1M, and 1M is not < 1M
$ find . -size -1025k -size +1c -type f
./half                   # use a smaller unit, or use -size -1048576c
```

`-size -1M` matches only **empty** files. Always express size thresholds in `c` (bytes) in automation.

### 9.3 Operators and precedence — the `-print` bug

Precedence, highest first: `( )` → `!` / `-not` → `-a` / `-and` (**implicit**) → `-o` / `-or` → `,`.

```
$ find . -name '*.log' -o -name '*.txt' -print
./notes.txt
```

Only the `.txt` files printed. `-a` binds tighter than `-o`, so this parsed as
`-name '*.log' OR ( -name '*.txt' AND -print )`. Additionally, because no action was attached to the left branch, `find`'s "default `-print`" rule was suppressed by the presence of an explicit `-print`. Correct form:

```
$ find . \( -name '*.log' -o -name '*.txt' \) -print
./app.log
./notes.txt
```

**Pruning** — the idiom for excluding subtrees, and the reason `-prune` is always followed by `-o`:

```
$ find /srv \
    \( -path '/srv/*/node_modules' -o -path '/srv/*/.git' -o -fstype nfs \) -prune \
    -o -type f -name '*.jar' -print
/srv/app/lib/core-2.4.1.jar
/srv/app/lib/netty-4.1.99.jar
```

Read it as: "if the node matches the exclusion set, prune (and stop) — **otherwise** test and print."

### 9.4 Actions, and the `-exec` performance cliff

| Action | Processes spawned | NUL-safe | Exit-code aware | Notes |
|---|---|---|---|---|
| `-print` | 0 | no (newline-delimited) | — | default action |
| `-print0` | 0 | **yes** | — | pair with `xargs -0` |
| `-printf FMT` | 0 | depends on FMT | — | the structured-output workhorse |
| `-delete` | 0 | **yes** | yes | implies `-depth`; refuses non-empty dirs |
| `-exec cmd {} \;` | **one per file** | yes | stops nothing on failure | O(N) forks |
| `-exec cmd {} +` | batched (like `xargs`) | yes | | O(N/batch) forks |
| `-execdir cmd {} \;` / `+` | as above, **cwd = file's directory** | yes | | immune to a class of symlink races |
| `-ok` / `-okdir` | interactive confirm | yes | | never in automation |
| `-quit` | 0 | — | — | stop after the first match (cheap existence test) |
| `-ls` | 0 | no | — | `ls -dils`-style output |

```
$ time find /var/cache/app -type f -name '*.tmp' -exec rm {} \;
real	0m38.412s
user	0m2.918s
sys	0m21.774s                     # 41,000 fork+exec pairs

$ time find /var/cache/app -type f -name '*.tmp' -exec rm {} +
real	0m1.204s

$ time find /var/cache/app -type f -name '*.tmp' -delete
real	0m0.981s                    # zero exec: unlinkat(2) inline
```

`-exec ... +` only works when `{}` is the **last** argument. If you need `{}` in the middle, you need `\;` (one fork each) or `xargs -I{}`:

```
$ find . -name '*.conf' -exec cp {} /backup/ \;          # {} not last → forced \;
$ find . -name '*.conf' -exec cp -t /backup/ {} +        # -t moves the dir first → batching works
```

**The NUL-delimited contract.** Filenames may contain every byte except `/` and NUL. That makes NUL the only safe delimiter:

```
$ touch $'weird\nname.log'
$ find . -name '*.log' | xargs rm            # BROKEN: splits on the newline
rm: cannot remove './weird': No such file or directory
rm: cannot remove 'name.log': No such file or directory

$ find . -name '*.log' -print0 | xargs -0 -r rm     # correct
```

`xargs` flags worth knowing: `-0` (NUL input), `-r`/`--no-run-if-empty` (do not run the command on empty input — GNU only, and the reason `xargs rm` on an empty result set otherwise deletes nothing but *does* run `rm` with no args), `-n N` (args per invocation), `-P N` (parallel), `-I{}` (replace-string, implies `-L1`).

### 9.5 `-printf` — turning the filesystem into a dataset

| Spec | Meaning |
|---|---|
| `%p` full path · `%f` basename · `%h` dirname · `%P` path minus start point |
| `%s` size in bytes · `%k` size in KiB blocks · `%b` 512-byte blocks |
| `%y` type letter · `%i` inode · `%n` link count · `%d` depth |
| `%M` symbolic mode · `%m` octal mode · `%u`/`%U` user · `%g`/`%G` group |
| `%T@` mtime as epoch.nanoseconds · `%TY-%Tm-%Td` formatted · `%CT`/`%AT` for ctime/atime |
| `\0` NUL · `\n` newline · `\t` tab |

Production one-liners:

```
# The 10 largest files under /var, NUL-safe, sorted numerically
$ find /var -xdev -type f -printf '%s\t%p\n' | sort -rn | head -10
34359738368	/var/lib/postgresql/16/main/base/16384/1259
8589934592	/var/log/tomcat/catalina.out
...

# Disk usage by top-level directory, excluding other mounts
$ find /var -xdev -maxdepth 1 -mindepth 1 -type d -printf '%f\0' \
    | xargs -0 du -sh --one-file-system 2>/dev/null | sort -h
1.2M	run
44M	tmp
2.1G	cache
19G	lib

# Every SUID/SGID binary on the root filesystem (baseline for drift detection)
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
    -printf '%m %u %g %p\n' | sort
4755 root root /usr/bin/chsh
4755 root root /usr/bin/gpasswd
4755 root root /usr/bin/newgrp
4755 root root /usr/bin/passwd
4755 root root /usr/bin/su
2755 root tty  /usr/bin/wall
...

# World-writable files and directories missing the sticky bit
$ sudo find / -xdev -type d -perm -0002 ! -perm -1000 -printf '%M %p\n'
drwxrwxrwx /srv/uploads

# Files orphaned by a UID migration
$ sudo find /home -xdev \( -nouser -o -nogroup \) -printf '%U:%G %p\n' | head

# Anything modified since the last known-good deploy marker
$ find /opt/app -newer /var/lib/deploy/last-good.stamp -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n'
2026-08-26 09:41 /opt/app/conf/application.yaml

# Reproducible file list (directory order is NOT deterministic)
$ find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > MANIFEST
```

### 9.6 Retention job, done correctly

```bash
#!/usr/bin/env bash
# /usr/local/sbin/prune-logs — production log retention
set -euo pipefail

readonly ROOT=${1:?usage: prune-logs <dir> [days]}
readonly DAYS=${2:-14}

[[ -d $ROOT ]] || { echo "not a directory: $ROOT" >&2; exit 2; }

# -xdev            : never cross into another mount (e.g. an NFS share)
# -newermt         : exact boundary, no 24h truncation surprise
# ! -newermt       : negation gives "older than"
# -delete          : no fork storm; implies -depth so dirs empty before removal
find "$ROOT" -xdev -type f -name '*.log.*' \
     ! -newermt "-${DAYS} days" \
     -printf 'pruning %s bytes: %p\n' \
     -delete

# Second pass: reap directories that the first pass emptied.
find "$ROOT" -xdev -mindepth 1 -type d -empty -delete
```

---

## 10. Archiving: `tar`, `cpio`, `dd`

### 10.1 Choosing an archiver

| | `tar` | `cpio` | `dd` |
|---|---|---|---|
| Unit of work | files + metadata | files + metadata | **raw blocks** |
| Input | path arguments, recursive by itself | **filename list on stdin** | a byte stream / device |
| Filesystem-aware | yes | yes | **no** — copies free space, deleted data, everything |
| Preserves hard links | yes | yes | n/a |
| Sparse files | `--sparse` | no | `conv=sparse` |
| Random-access member extract | linear scan, but supported | linear scan | n/a |
| Streamable to a pipe | yes | yes | yes |
| Canonical use | backups, container layers, source tarballs | **initramfs**, RPM payloads, `find`-driven selection | disk imaging, bootloaders, MBR, offset-precise reads/writes |
| Handles a filesystem it cannot mount | no | no | **yes** |

### 10.2 `tar`

**Operation modes (exactly one required):**

| Mode | Long form | Meaning |
|---|---|---|
| `-c` | `--create` | create |
| `-x` | `--extract` | extract |
| `-t` | `--list` | list |
| `-r` | `--append` | append to an **uncompressed** archive |
| `-u` | `--update` | append only newer members |
| `-A` | `--concatenate` | concatenate archives |
| `-d` | `--diff` / `--compare` | compare archive to filesystem |
| `--delete` | | remove members (uncompressed, non-tape only) |

**Essential modifiers:**

| Flag | Meaning |
|---|---|
| `-f FILE` | archive file; `-` means stdin/stdout |
| `-v` | verbose (`-vv` for `ls -l`-style detail) |
| `-C DIR` | `chdir` before the next operand — **positional**, and the correct way to control paths |
| `-p`, `--preserve-permissions` | restore exact modes (default when extracting as root) |
| `--same-owner` / `--no-same-owner` | root defaults to same-owner; non-root to no-same-owner |
| `--numeric-owner` | store/restore raw UID/GID, never names — mandatory for cross-host restores |
| `-z` gzip · `-j` bzip2 · `-J` xz · `--zstd` · `--lzma` · `-Z` compress | compression |
| `-a`, `--auto-compress` | pick the compressor from the output filename suffix |
| `-I 'PROG'`, `--use-compress-program` | arbitrary compressor with flags: `-I 'zstd -19 -T0'` |
| `--exclude=PAT` / `--exclude-from=FILE` / `--exclude-vcs` | selection |
| `-T FILE`, `--files-from` | read the member list from a file; `--null` for NUL-delimited |
| `--strip-components=N` | drop N leading path components on extract |
| `--one-file-system` | stop at mount boundaries |
| `--sparse` | detect and store holes efficiently |
| `--xattrs --acls --selinux` | extended metadata |
| `--listed-incremental=SNAR` | GNU incremental backups |
| `--wildcards` / `--anchored` | glob semantics for member selection |
| `-P`, `--absolute-names` | keep leading `/` and `..` — **disables the safety stripping** |

**Format matters more than people think:**

| Format (`--format=`) | Max path | Max file size | Max UID/GID | Sub-second mtime | xattrs | Portability |
|---|---|---|---|---|---|---|
| `v7` | 99 | 8 GiB | 2097151 | no | no | ancient |
| `ustar` (POSIX.1-1988) | 100 + 155 prefix | **8 GiB** | 2097151 | no | no | universal |
| `gnu` (**GNU tar default**) | unlimited | unlimited | unlimited | no | no | GNU/bsdtar |
| `oldgnu` | unlimited | unlimited | unlimited | no | no | legacy |
| `pax` / `posix` (POSIX.1-2001) | unlimited | unlimited | unlimited | **yes** | **yes** | modern, the right default |

```
$ tar --version | head -1
tar (GNU tar) 1.35
```

An 8 GiB `ustar` limit is not theoretical — a 12 GiB database dump into a `ustar` archive fails, and some old toolchains produce `ustar` by default. Use `--format=pax` for anything modern.

**Path safety.** GNU tar strips a leading `/` and refuses `..` components on extraction unless `-P` is given:

```
$ tar -cf etc.tar /etc/nginx
tar: Removing leading `/' from member names
$ tar -tf etc.tar | head -2
etc/nginx/
etc/nginx/nginx.conf
```

This is a **security control** (the "Zip Slip" / tar-slip class). Never extract an untrusted archive with `-P`. Always inspect first:

```
$ tar -tvf untrusted.tar | awk '$NF ~ /^\/|\.\./ {print "UNSAFE:", $NF}'
```

**The `-C` positional rule** — the difference between a clean archive and one with `srv/app/` baked into every path:

```
$ tar -czf app.tgz /srv/app                # members: srv/app/...
$ tar -czf app.tgz -C /srv app             # members: app/...
$ tar -czf app.tgz -C /srv/app .           # members: ./...   ← usually what you want
```

**Verification and diffing:**

```
$ tar -tzvf backup.tgz | head -4
drwxr-xr-x svc/svc           0 2026-08-26 09:00 ./
-rw-r----- svc/svc     4194304 2026-08-26 09:00 ./data/shard-00.db
-rw-r--r-- root/root       412 2026-08-14 11:02 ./etc/app.conf
lrwxrwxrwx root/root         0 2026-08-01 10:00 ./bin/current -> ./bin/2.4.1

$ tar -df backup.tgz -C /srv/app          # compare archive against the live tree
./etc/app.conf: Mod time differs
./etc/app.conf: Size differs
$ echo $?
1
```

`tar -d` is the cheapest post-restore validation you have, and almost nobody uses it.

**Incremental backups (GNU):**

```
# Level 0 — full. The .snar file records directory state and IS PART OF THE BACKUP.
$ sudo tar --create --file=/backup/l0.tar.zst --zstd \
      --listed-incremental=/backup/app.snar \
      --numeric-owner --xattrs --acls --selinux --one-file-system \
      -C /srv/app .
$ cp /backup/app.snar /backup/app.snar.l0     # snapshot the snapshot file!

# Level 1 — only what changed since the snar was last written.
$ sudo tar --create --file=/backup/l1.tar.zst --zstd \
      --listed-incremental=/backup/app.snar \
      --numeric-owner --xattrs --acls --selinux --one-file-system \
      -C /srv/app .

# Restore MUST replay levels in order, with -G/--incremental on extract.
$ sudo tar --extract --incremental --file=/backup/l0.tar.zst --zstd -C /restore
$ sudo tar --extract --incremental --file=/backup/l1.tar.zst --zstd -C /restore
```

Losing the `.snar` means the next "incremental" silently becomes a full backup — or worse, the restore fails to delete files that were removed between levels. Version it alongside the archives.

**Reproducible tarballs** (identical bytes for identical content — the requirement for cacheable container layers and signed releases):

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE_DATE_EPOCH:?set to the commit timestamp}"

tar --create \
    --file=- \
    --format=pax \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 --group=0 --numeric-owner \
    --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
    --exclude-vcs \
    -C "${SRCDIR}" . \
  | gzip -9 -n > "${OUT}.tar.gz"      # -n: omit gzip's embedded name+mtime
```

Every flag there removes one source of nondeterminism: directory order, timestamps, ownership, pax extended-header names, and the gzip header. Drop any one and your SHA changes between builds.

### 10.3 `cpio`

`cpio` reads its file list from **stdin**. That is its whole design and its whole advantage: the selection logic is `find`, so it composes with everything in §9.

**Three modes:**

| Mode | Flag | Reads | Writes |
|---|---|---|---|
| copy-**out** | `-o` / `--create` | filenames on stdin | archive on stdout |
| copy-**in** | `-i` / `--extract` | archive on stdin | files in cwd |
| copy-**pass** | `-p` / `--pass-through` | filenames on stdin | files under a destination directory (no archive) |

**Formats (`-H`):**

| Format | Inode width | Max size | Notes |
|---|---|---|---|
| `bin` | 16-bit, byte-order dependent | 2 GiB | obsolete, non-portable |
| `odc` | old POSIX character | 8 GiB | portable, ancient |
| `newc` | 8-byte hex, 32-bit inode | **4 GiB per file** | **SVR4 — what the Linux kernel requires for initramfs** |
| `crc` | `newc` + checksum | 4 GiB | initramfs-capable, integrity-checked |
| `tar` / `ustar` | — | — | cpio writing tar |
| `hpbin` / `hpodc` | HP-UX variants | | |

**Key flags:** `-d`/`--make-directories`, `-m`/`--preserve-modification-time`, `-v`, `-u`/`--unconditional` (overwrite even if newer), `-t`/`--list`, `--no-absolute-filenames` (**security**), `-0`/`--null` (NUL-delimited input — pair with `find -print0`), `-F FILE` (archive file instead of stdio), `-p -d -m -l` for the pass-through hard-link copy.

```
# Create a NUL-safe archive of exactly the files find selected
$ find /srv/app -xdev -type f -newermt '-1 day' -print0 \
    | cpio --null --create --format=newc --verbose > /backup/delta.cpio
/srv/app/etc/app.conf
/srv/app/var/state.db
2048 blocks

# List
$ cpio -itv < /backup/delta.cpio
-rw-r--r--   1 svc      svc           412 Aug 26 09:41 srv/app/etc/app.conf
-rw-r-----   1 svc      svc       1048576 Aug 26 09:12 srv/app/var/state.db
2048 blocks

# Extract safely: make dirs, preserve mtimes, refuse absolute paths
$ mkdir -p /restore && cd /restore
$ cpio -idmv --no-absolute-filenames < /backup/delta.cpio
srv/app/etc/app.conf
srv/app/var/state.db
2048 blocks
```

**Building an initramfs** — the canonical `newc` use case, and the reason this format is on the exam:

```
$ cd /tmp/initramfs-root
$ find . -print0 | cpio --null --create --format=newc --owner=root:root \
    | zstd -19 -T0 > /boot/initramfs-6.9.0.img
128512 blocks

$ file /boot/initramfs-6.9.0.img
/boot/initramfs-6.9.0.img: Zstandard compressed data (v0.8+), Dictionary ID: None

# Inspect an existing one
$ zstdcat /boot/initramfs-6.9.0.img | cpio -itv | head -5
drwxr-xr-x   1 root     root            0 Aug 20 08:00 .
drwxr-xr-x   1 root     root            0 Aug 20 08:00 bin
lrwxrwxrwx   1 root     root            7 Aug 20 08:00 bin/sh -> busybox
-rwxr-xr-x   1 root     root       824328 Aug 20 08:00 bin/busybox
-rwxr-xr-x   1 root     root         3128 Aug 20 08:00 init
```

The kernel's initramfs unpacker only understands `newc`/`crc`. Hand it a `tar` and the machine does not boot.

**Copy-pass mode** — an archive-free tree copy that preserves hard links, useful when `cp -a` is not available in a rescue environment:

```
$ cd /source && find . -depth -print0 | cpio -0 -pdmv /destination
```

### 10.4 `dd`

`dd` is a **block-level** copier with explicit control over offsets, block sizes and I/O flags. It is not faster than `cp`, it has no filesystem awareness, and it will happily destroy a partition table. Its value is precision.

**Operands (note: `=`, not `--`):**

| Operand | Meaning |
|---|---|
| `if=FILE` / `of=FILE` | input/output (default stdin/stdout) |
| `bs=N` | both read and write block size |
| `ibs=N` / `obs=N` | separate input/output block sizes |
| `count=N` | copy N input blocks (`iflag=count_bytes` to make N a byte count) |
| `skip=N` | skip N **input** blocks before copying |
| `seek=N` | skip N **output** blocks before writing |
| `status=none\|noxfer\|progress` | `progress` prints a live rate |
| `conv=...` | data conversion / behaviour |
| `iflag=` / `oflag=` | per-side `open(2)` and read/write flags |

Suffixes: `c`=1, `w`=2, `b`=512, `K`/`KiB`=1024, `KB`=1000, `M`, `G`, `T`.

**`conv=` values that matter:**

| Value | Effect |
|---|---|
| `notrunc` | do **not** truncate the output file — mandatory when patching in place |
| `noerror` | continue after a read error (pair with `sync`, or offsets shift!) |
| `sync` | pad every input block to `ibs` with NULs — makes `noerror` offset-preserving |
| `sparse` | write holes instead of NUL blocks |
| `fsync` / `fdatasync` | flush before exiting — otherwise `dd` returns with data in page cache |
| `excl` / `nocreat` | fail if output exists / fail if it does not |
| `swab` | swap byte pairs (endianness) |

**`iflag`/`oflag` values that matter:**

| Value | Effect |
|---|---|
| `direct` | `O_DIRECT`, bypass the page cache — the only honest way to benchmark a disk |
| `dsync` / `sync` | synchronous data / data+metadata writes per block |
| `fullblock` | **accumulate full blocks on read** — mandatory for pipes, sockets, `/dev/urandom` |
| `nocache` | drop the page cache for the file afterwards |
| `count_bytes` / `skip_bytes` / `seek_bytes` | interpret the corresponding operand as bytes |
| `nonblock` / `noatime` | `O_NONBLOCK` / `O_NOATIME` |

**The short-read bug — the most dangerous `dd` behaviour:**

```
$ dd if=/dev/urandom bs=1M count=100 | dd of=out.bin bs=1M
0+3200 records in                  ← "0 full blocks in, 3200 PARTIAL"
0+3200 records out
104857600 bytes (105 MB, 100 MiB) copied, 0.9 s, 116 MB/s
```

Here it happened to total the right number of bytes, but with `count=` on the reading side a pipe's short reads silently truncate:

```
$ cat 100mb.bin | dd of=trunc.bin bs=1M count=100
7+93 records in
7+93 records out
21299200 bytes (21 MB, 20 MiB) copied, 0.03 s      ← 20 MiB, not 100 MiB. Silent data loss.

$ cat 100mb.bin | dd of=ok.bin bs=1M count=100 iflag=fullblock
100+0 records in
100+0 records out
104857600 bytes (105 MB, 100 MiB) copied, 0.21 s, 499 MB/s
```

**Rule: any `dd` whose input is not a regular file or block device must use `iflag=fullblock`.**

**Real uses:**

```
# 1. Back up the MBR (446 bytes of boot code + 64-byte partition table + 2-byte signature)
$ sudo dd if=/dev/sda of=/backup/sda-mbr.bin bs=512 count=1
1+0 records in
1+0 records out
512 bytes copied, 0.000452 s, 1.1 MB/s

# 2. Restore ONLY the boot code, leaving the partition table untouched
$ sudo dd if=/backup/sda-mbr.bin of=/dev/sda bs=446 count=1 conv=notrunc

# 3. Forensic image with error tolerance and preserved offsets
$ sudo dd if=/dev/sdb of=/evidence/sdb.img bs=64K conv=noerror,sync status=progress
  244140544 bytes (244 MB, 233 MiB) copied, 3 s, 81.4 MB/s
dd: error reading '/dev/sdb': Input/output error
3726+1 records in
3727+0 records out
   ⚠ For real forensics use ddrescue: it retries, logs bad sectors and resumes.

# 4. Read 4 KiB from a precise byte offset (superblock inspection)
$ sudo dd if=/dev/sda1 bs=1 skip=1024 count=4096 status=none | hexdump -C | head -3
00000000  00 00 20 00 00 00 80 00  33 33 06 00 6e c5 26 00  |.. .....33..n.&.|
00000010  b1 44 1a 00 00 00 00 00  02 00 00 00 02 00 00 00  |.D..............|
00000020  00 80 00 00 00 80 00 00  00 20 00 00 5d 2b ce 68  |......... ..]+.h|

# 5. Honest sequential write benchmark (O_DIRECT bypasses the page cache)
$ sudo dd if=/dev/zero of=/srv/testfile bs=1M count=4096 oflag=direct
4096+0 records in
4096+0 records out
4294967296 bytes (4.3 GB, 4.0 GiB) copied, 7.88214 s, 545 MB/s
$ sudo rm /srv/testfile
   ⚠ Without oflag=direct you are benchmarking RAM. Without conv=fsync you are
     benchmarking the page cache and the number will be absurdly high.

# 6. Create a sparse 100 GiB file instantly (fallocate is better, but dd works)
$ dd if=/dev/zero of=sparse.img bs=1 count=0 seek=100G
$ ls -lh sparse.img && du -h sparse.img
-rw-r--r-- 1 root root 100G Aug 26 10:30 sparse.img
0	sparse.img

# 7. Live progress on a long-running dd already in flight
$ sudo kill -USR1 $(pgrep -x dd)
  17179869184 bytes (17 GB, 16 GiB) copied, 62 s, 277 MB/s
```

**`dd` safety checklist before any `of=/dev/...`:**

```
$ lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL /dev/sdb
NAME   SIZE TYPE MOUNTPOINTS MODEL
sdb   14.9G disk             Ultra_Fit
└─sdb1 14.9G part /media/usb

$ findmnt -n /dev/sdb1 && echo "MOUNTED — unmount before writing"
$ sudo umount /dev/sdb1
$ sudo dd if=image.iso of=/dev/sdb bs=4M conv=fsync oflag=direct status=progress
```

Write to the **disk** (`/dev/sdb`) for a hybrid ISO, to the **partition** (`/dev/sdb1`) for a filesystem image. Getting that wrong destroys the partition table.

---

## 11. Compression

All of these are **stream** compressors. `tar` handles bundling; the compressor handles bytes. That separation is why `.tar.gz` has two suffixes and why you cannot randomly seek into a `.tar.gz` member without decompressing everything before it.

### 11.1 Algorithm comparison

Measured on a 1.0 GiB `tar` of a Debian rootfs, 8-core x86-64. Your numbers will differ; the *ratios* hold.

| Tool | Algorithm | Level | Output | Compress | Decompress | Decompress RAM | Parallel |
|---|---|---|---|---|---|---|---|
| `lz4` | LZ77 | `-1` | 447 MiB | 3 s | 1.1 s | ~1 MiB | `-T0` (mt) |
| `gzip` | DEFLATE (LZ77+Huffman, 32 KiB window) | `-6` | 331 MiB | 24 s | 3.1 s | ~1 MiB | `pigz` |
| `zstd` | LZ77+FSE/Huffman | `-3` | 318 MiB | 6 s | 2.4 s | ~8 MiB | **`-T0` native** |
| `bzip2` | BWT + MTF + Huffman | `-9` | 289 MiB | 96 s | 32 s | ~8 MiB | `pbzip2` |
| `zstd` | " | `-19` | 246 MiB | 178 s | 2.6 s | ~9 MiB | `-T0` |
| `xz` | LZMA2 | `-6` (default) | 231 MiB | 214 s | 12 s | **9 MiB** | `-T0` |
| `xz` | LZMA2 | `-9` | 224 MiB | 302 s | 14 s | **65 MiB** | `-T0` |

**The decision rule:**

- **Write once, read many, bandwidth-constrained distribution** (kernel tarballs, distro packages) → `xz -9`. Slow to make, small, cheap to read.
- **Backups you hope never to read but must read *fast* under pressure** → `zstd -19`. Nearly `xz` ratio, `gzip`-class decompression, 60× faster than `xz` to restore in aggregate.
- **Interactive / pipeline / log rotation** → `zstd -3` or `gzip -6`.
- **Real-time on the hot path** (network stream, tmp spill) → `lz4`.
- **`bzip2`** → only for compatibility with existing `.bz2` artefacts. It is dominated on every axis by `zstd` and `xz`.
- **`xz -9` decompression needs 65 MiB of RAM.** That is disqualifying inside a memory-constrained initramfs or a 128 MiB container. `xz --info-memory` tells you before you commit.

```
$ xz --info-memory
Total amount of physical memory (RAM): 32768 MiB
Number of processor threads: 16
Memory usage limit for compression:    Disabled
Memory usage limit for decompression:  Disabled

$ xz -l firmware.tar.xz
Strms  Blocks   Compressed Uncompressed  Ratio  Check   Filename
    1       1    224.1 MiB   1024.0 MiB  0.219  CRC64   firmware.tar.xz
```

### 11.2 Common interface

All four share the same core UX, which is what the exam tests:

| Behaviour | `gzip` | `bzip2` | `xz` | `zstd` |
|---|---|---|---|---|
| Compress, **replace** original | `gzip f` | `bzip2 f` | `xz f` | `zstd --rm f` |
| Keep the original | `gzip -k f` | `bzip2 -k f` | `xz -k f` | `zstd f` (default keeps) |
| Decompress | `gunzip f.gz` / `gzip -d` | `bunzip2` / `bzip2 -d` | `unxz` / `xz -d` | `unzstd` / `zstd -d` |
| Stream to stdout | `zcat` / `gzip -c` | `bzcat` / `bzip2 -c` | `xzcat` / `xz -c` | `zstdcat` |
| Test integrity | `gzip -t` | `bzip2 -t` | `xz -t` | `zstd -t` |
| Show ratio | `gzip -l` | *(none)* | `xz -l` | `zstd -l` |
| Levels | `-1`…`-9` | `-1`…`-9` (block size) | `-0`…`-9`, `-e` | `-1`…`-19`, `--ultra -22` |
| Grep inside | `zgrep` | `bzgrep` | `xzgrep` | `zstdgrep` |
| Threads | `pigz -p N` | `pbzip2 -p N` | `xz -T0` | `zstd -T0` |

> **The default is destructive.** `gzip file` leaves you with `file.gz` and no `file`. `-k`/`--keep` is muscle memory worth building.

```
$ ls -l app.log
-rw-r----- 1 svc svc 104857600 Aug 26 09:00 app.log
$ gzip -k -9 app.log
$ ls -l app.log*
-rw-r----- 1 svc svc 104857600 Aug 26 09:00 app.log
-rw-r----- 1 svc svc   4194304 Aug 26 09:00 app.log.gz     ← mtime is PRESERVED

$ gzip -l app.log.gz
         compressed        uncompressed  ratio uncompressed_name
            4194304           104857600  96.0% app.log

$ zcat app.log.gz | grep -c ERROR
1842
$ zgrep -c ERROR app.log.gz            # same thing, one process
1842
```

**`gzip -n` and reproducibility.** The gzip header embeds the original filename and mtime. Two byte-identical inputs compressed a second apart produce different `.gz` files. `-n`/`--no-name` strips both — required for any signed or cache-keyed artefact.

```
$ gzip -c  data > a.gz; sleep 2; gzip -c  data > b.gz; cmp a.gz b.gz
a.gz b.gz differ: byte 5, line 1
$ gzip -nc data > a.gz; sleep 2; gzip -nc data > b.gz; cmp a.gz b.gz && echo identical
identical
```

**Compressing an already-compressed file makes it bigger:**

```
$ ls -l image.jpg && gzip -9 -c image.jpg | wc -c
-rw-r--r-- 1 svc svc 2418176 Aug 26 09:00 image.jpg
2419331                                    ← +1155 bytes of overhead
```

**Concatenation semantics** (a real property you can rely on): `gzip`, `bzip2`, `xz` and `zstd` streams concatenate. `cat a.gz b.gz > c.gz` decompresses to `a` followed by `b`.

**Recovering a damaged archive:**

```
$ bzip2 -t corrupt.tar.bz2
bzip2: corrupt.tar.bz2: data integrity (CRC) error in data

$ bzip2recover corrupt.tar.bz2      # splits into per-block files; salvage what survives
bzip2recover: splitting into blocks
   block 1 runs from 80 to 8394239
   block 2 runs from 8394240 to 16789119
...
$ bzip2 -dc rec0000*.bz2 > salvaged.tar
```

`gzip` has no equivalent — a corrupt DEFLATE stream is unrecoverable past the damage. That alone is an argument for `zstd` (per-frame checksums) or `xz --check=sha256` on long-lived archives, and for splitting large backups into independently-verifiable chunks.

---

## 12. Production infrastructure

### 12.1 Kubernetes CronJob: PVC backup with `tar`, verified

Every flag below is deliberate: `--numeric-owner` because the restore host has different `/etc/passwd`; `--one-file-system` so a sidecar mount is not swept in; `-t` verification because an unverified backup is not a backup; `-mtime`-based retention with `-delete` so we do not fork 10,000 times inside a 100m-CPU container.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pvc-backup-script
  namespace: platform
data:
  backup.sh: |
    #!/usr/bin/env bash
    set -euo pipefail

    readonly SRC=/data
    readonly DST=/backup
    readonly STAMP="${BACKUP_STAMP:?injected by the CronJob}"
    readonly ARCHIVE="${DST}/app-${STAMP}.tar.zst"
    readonly RETENTION_DAYS="${RETENTION_DAYS:-14}"

    echo "==> source inventory"
    find "${SRC}" -xdev -type f -printf '%s\n' \
      | awk '{n++; b+=$1} END {printf "files=%d bytes=%d\n", n, b}'

    echo "==> creating ${ARCHIVE}"
    tar --create \
        --file="${ARCHIVE}.part" \
        --use-compress-program='zstd -12 -T0' \
        --format=pax \
        --sort=name \
        --one-file-system \
        --numeric-owner \
        --acls --xattrs --selinux \
        --sparse \
        --exclude='./lost+found' \
        --exclude='./*.tmp' \
        --warning=no-file-changed \
        --directory="${SRC}" .

    echo "==> verifying archive is readable end to end"
    tar --list --file="${ARCHIVE}.part" --use-compress-program='zstd -d -T0' >/dev/null

    echo "==> publishing atomically (same filesystem => rename(2))"
    mv --force -- "${ARCHIVE}.part" "${ARCHIVE}"
    sync -f "${ARCHIVE}"

    echo "==> checksum"
    ( cd "${DST}" && sha256sum "$(basename "${ARCHIVE}")" \
        > "$(basename "${ARCHIVE}").sha256" )

    echo "==> pruning archives older than ${RETENTION_DAYS} days"
    find "${DST}" -xdev -maxdepth 1 -type f \
         \( -name 'app-*.tar.zst' -o -name 'app-*.tar.zst.sha256' \) \
         ! -newermt "-${RETENTION_DAYS} days" \
         -printf 'pruning %10s bytes  %p\n' \
         -delete

    echo "==> orphaned .part files from crashed runs"
    find "${DST}" -xdev -maxdepth 1 -type f -name '*.part' -mmin +720 \
         -printf 'stale partial: %p\n' -delete

    echo "==> destination free space"
    df -h --output=source,size,used,avail,pcent "${DST}"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: app-pvc-backup
  namespace: platform
spec:
  schedule: "17 2 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 10800
      template:
        metadata:
          labels:
            app.kubernetes.io/name: app-pvc-backup
            app.kubernetes.io/component: backup
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: tar
              image: debian:12-slim
              imagePullPolicy: IfNotPresent
              command: ["/bin/bash", "/scripts/backup.sh"]
              env:
                - name: RETENTION_DAYS
                  value: "14"
                - name: BACKUP_STAMP
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: "500m"
                  memory: "256Mi"
                limits:
                  cpu: "2"
                  memory: "1Gi"
              volumeMounts:
                - name: data
                  mountPath: /data
                  readOnly: true
                - name: backup
                  mountPath: /backup
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: data
              persistentVolumeClaim:
                claimName: app-data
                readOnly: true
            - name: backup
              persistentVolumeClaim:
                claimName: backup-target
            - name: scripts
              configMap:
                name: pvc-backup-script
                defaultMode: 0555
            - name: tmp
              emptyDir:
                sizeLimit: 128Mi
```

`--warning=no-file-changed` deserves a note: `tar` exits **1** if a file changes size while being read, which on a live PVC is routine and would fail the Job every night. Suppressing the warning does not make the backup consistent — for that you need a volume snapshot. This is the honest trade-off: use `VolumeSnapshot` as the source PVC if your CSI driver supports it, and treat this manifest as the fallback.

### 12.2 Init container: verified artefact extraction

The pattern here is: fetch → **checksum before extract** → inspect for path traversal → extract with `--strip-components` → hand off through an `emptyDir`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: platform
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: app
  template:
    metadata:
      labels:
        app.kubernetes.io/name: app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: fetch-and-verify
          image: debian:12-slim
          command:
            - /bin/bash
            - -euo
            - pipefail
            - -c
            - |
              cd /work
              curl -fsSL --retry 5 --retry-delay 2 \
                   -o app.tar.gz "${ARTIFACT_URL}"

              echo "${ARTIFACT_SHA256}  app.tar.gz" | sha256sum -c -

              # Refuse absolute paths and any ".." component before extracting.
              if tar -tzf app.tar.gz | grep -Eq '^/|(^|/)\.\.(/|$)'; then
                echo "FATAL: archive contains unsafe member paths" >&2
                tar -tzf app.tar.gz | grep -E '^/|(^|/)\.\.(/|$)' >&2
                exit 1
              fi

              tar --extract --gzip \
                  --file=app.tar.gz \
                  --directory=/app \
                  --strip-components=1 \
                  --no-same-owner \
                  --no-overwrite-dir

              rm -f app.tar.gz
              find /app -maxdepth 2 -printf '%M %8s %P\n' | head -40
          env:
            - name: ARTIFACT_URL
              value: "https://artifacts.internal/app/2.4.1/app-2.4.1.tar.gz"
            - name: ARTIFACT_SHA256
              valueFrom:
                secretKeyRef:
                  name: app-artifact-digest
                  key: sha256
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }
          volumeMounts:
            - { name: app, mountPath: /app }
            - { name: work, mountPath: /work }
      containers:
        - name: app
          image: gcr.io/distroless/java21-debian12
          args: ["-jar", "/app/app.jar"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "500m", memory: "512Mi" }
            limits:   { cpu: "2",    memory: "2Gi" }
          volumeMounts:
            - { name: app, mountPath: /app, readOnly: true }
      volumes:
        - name: app
          emptyDir: { sizeLimit: 2Gi }
        - name: work
          emptyDir: { sizeLimit: 2Gi }
```

### 12.3 Node-level: `systemd` timer + `tmpfiles.d` for disk hygiene

Two mechanisms, two jobs. `tmpfiles.d` is declarative and handles the common age-based case; the timer handles anything with real logic.

```ini
# /etc/tmpfiles.d/app-cleanup.conf
#Type Path                        Mode UID   GID   Age  Argument
d     /var/cache/app              0750 svc   svc   7d   -
d     /var/lib/app/spool          0750 svc   svc   -    -
e     /var/lib/app/spool/incoming 0750 svc   svc   30d  -
D     /run/app                    0755 svc   svc   -    -
```

`d` = create if absent then clean entries older than Age. `e` = clean only if it already exists (never create). `D` = create and **purge on boot**. Apply and dry-run:

```
$ sudo systemd-tmpfiles --clean --dry-run /etc/tmpfiles.d/app-cleanup.conf
$ sudo systemd-tmpfiles --create --clean /etc/tmpfiles.d/app-cleanup.conf
```

```ini
# /etc/systemd/system/disk-hygiene.service
[Unit]
Description=Prune aged artefacts and report filesystem pressure
Documentation=man:find(1) man:tmpfiles.d(5)
ConditionPathIsMountPoint=/var

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
CPUQuota=25%
ExecStart=/usr/local/sbin/disk-hygiene
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
ReadWritePaths=/var/cache /var/log /var/tmp
```

```ini
# /etc/systemd/system/disk-hygiene.timer
[Unit]
Description=Nightly disk hygiene

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=1800
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/disk-hygiene  (0755, root:root)
set -euo pipefail
shopt -s nullglob

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# 1. Rotated logs older than 14 days, bounded to the /var filesystem.
log "pruning rotated logs"
find /var/log -xdev -type f \
     \( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*.old' \) \
     ! -newermt '-14 days' \
     -printf 'prune %10s %p\n' -delete

# 2. Empty directories left behind, deepest first.
find /var/log -xdev -mindepth 1 -type d -empty -delete

# 3. Compress yesterday's uncompressed logs. -mtime +0 == older than 24h.
log "compressing"
find /var/log -xdev -type f -name '*.log.1' -mtime +0 -print0 \
  | xargs -0 -r -P 4 -n 16 zstd -19 --rm --quiet

# 4. Space held open by deleted files — report only; never kill blindly.
log "checking for unlinked-but-open files"
if command -v lsof >/dev/null; then
    lsof -nP +L1 2>/dev/null \
      | awk 'NR==1 || $8 > 1073741824 {print}' || true
fi

# 5. Report inode and block pressure on every local filesystem.
log "filesystem pressure"
df  -hl --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs
df  -il --output=target,itotal,iused,iavail,ipcent -x tmpfs -x devtmpfs
```

```
$ sudo systemctl enable --now disk-hygiene.timer
Created symlink /etc/systemd/system/timers.target.wants/disk-hygiene.timer → /etc/systemd/system/disk-hygiene.timer.
$ systemctl list-timers disk-hygiene.timer
NEXT                        LEFT       LAST PASSED UNIT               ACTIVATES
Thu 2026-08-27 03:47:12 UTC 17h left   n/a  n/a    disk-hygiene.timer disk-hygiene.service
```

### 12.4 Reproducible container layer

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:12-slim AS build
ARG SOURCE_DATE_EPOCH
WORKDIR /src
COPY . .
RUN set -eux; \
    make build; \
    install -D -m 0755 -o root -g root out/app /rootfs/usr/local/bin/app; \
    install -D -m 0644 -o root -g root conf/app.yaml /rootfs/etc/app/app.yaml; \
    # Deterministic layer: fixed order, fixed times, fixed ownership.
    tar --create \
        --file=/rootfs.tar \
        --format=pax \
        --sort=name \
        --mtime="@${SOURCE_DATE_EPOCH}" \
        --owner=0 --group=0 --numeric-owner \
        --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
        -C /rootfs .

FROM gcr.io/distroless/base-debian12
COPY --from=build /rootfs.tar /tmp/rootfs.tar
# (In a real pipeline the tar is fed to buildkit as a layer, not extracted here.)
ENTRYPOINT ["/usr/local/bin/app"]
```

`install -D -m -o -g` in one call replaces `mkdir -p && cp && chmod && chown` — fewer states, no window where the file exists with the wrong mode.

---

## 13. Verification and failure diagnosis

### 13.1 The diagnostic ladder for "the disk is full"

```
                    df reports 100%
                          │
        ┌─────────────────┼──────────────────┐
        ▼                 ▼                  ▼
   df -i shows       du ≈ df?            du ≪ df?
   IUse% = 100%       │                     │
        │             ▼                     ▼
   INODE              genuinely       unlinked-but-open files
   EXHAUSTION         full              OR a mount shadowed
        │                                by another mount
        ▼                                    │
  find / -xdev -type f | wc -l          lsof +L1  /  mount --bind
  find / -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head
```

```
# Case A — inode exhaustion. Blocks are free, inodes are not.
$ df -h /var  && df -i /var
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var    50G   11G   37G  23% /var
Filesystem            Inodes  IUsed IFree IUse% Mounted on
/dev/mapper/vg0-var  3276800 3276800     0  100% /var

$ sudo find /var -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head -3
2981442 /var/spool/postfix/maildrop
  41118 /var/lib/app/sessions
   9033 /var/cache/nginx
# ext4 inode counts are fixed at mkfs time and CANNOT be grown. XFS allocates
# dynamically. This is an mkfs-time architectural decision, discovered at 3am.

# Case B — shadowed mount. Data was written to the mountpoint BEFORE mounting.
$ df -h /srv/data
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/vg0-data  500G   12G  488G   3% /srv/data
$ df -h /            # but / is full
$ sudo mkdir /mnt/root-view && sudo mount --bind / /mnt/root-view
$ sudo du -sh /mnt/root-view/srv/data
340G	/mnt/root-view/srv/data     ← 340 GiB hidden UNDER the mount
$ sudo umount /mnt/root-view
```

### 13.2 Error → cause → fix

| Message | Layer | Cause | Fix |
|---|---|---|---|
| `Argument list too long` (E2BIG) | kernel `execve` | glob exceeded `ARG_MAX` or env is huge | `find … -delete` / `-exec … +` / `xargs -0` |
| `Invalid cross-device link` (EXDEV) | `rename(2)` | source and target on different filesystems | expected — `mv` falls back to copy; use `cp -a && rm` explicitly if you need to control it |
| `Directory not empty` (ENOTEMPTY) | `rmdir(2)` | contents remain, possibly hidden dotfiles | `ls -A dir`; `rm -r` if intended |
| `Device or resource busy` (EBUSY) | `unlink`/`umount` | a process cwd's there or holds a mount | `lsof +D /path` / `fuser -vm /path` |
| `Text file busy` (ETXTBSY) | `open` for write | you are writing a running executable | replace via `mv` (rename), not `cp` |
| `Operation not permitted` on `chown` during extract | `tar -x` | non-root cannot change ownership | `--no-same-owner` (default for non-root) |
| `tar: Removing leading '/' from member names` | GNU tar | safety stripping, informational | use `-C` and relative paths |
| `tar: ...: file changed as we read it` (exit 1) | GNU tar | live file mutated mid-read | snapshot the volume, or `--warning=no-file-changed` and accept inconsistency |
| `tar: Unexpected EOF in archive` | GNU tar | truncated transfer, or a `.gz` piped without `-z` | verify checksum; `file` the archive |
| `cpio: premature end of archive` | cpio | truncated stream, or wrong `-H` format | `file` it; check the writer's exit status |
| `cpio: Malformed number` | cpio | format mismatch (`bin` read as `newc`) | `-H` must match the writer |
| `dd: failed to open '/dev/sdb': Permission denied` | kernel | not root, or device held exclusively | `sudo`; check `lsblk`/`findmnt` for holders |
| `dd` `N+M records in` with M ≫ 0 | `read(2)` | short reads from a pipe | `iflag=fullblock` |
| `gzip: stdin: not in gzip format` | gzip | file is not gzip (often `xz` or plain tar) | `file` it, use the right flag |
| `bzip2: data integrity (CRC) error` | bzip2 | corruption | `bzip2recover`; re-fetch |
| `xz: Cannot allocate memory` | xz | decompression dictionary exceeds cgroup limit | recompress at a lower preset; raise the memory limit |
| `No space left on device` with `df` showing free space | VFS | inode exhaustion, or an unlinked-but-open file, or a full `/tmp` in a different mount | `df -i`; `lsof +L1` |
| `find: warning: you have specified the -maxdepth option after a non-option argument` | findutils | ordering | put `-maxdepth` first |
| `rm: cannot remove 'x': Read-only file system` | VFS | filesystem remounted `ro` after an error | `dmesg -T \| grep -i 'remount\|I/O error'` — the disk is dying |

### 13.3 Post-operation verification checklist

```bash
# --- After any bulk copy: compare counts, bytes, and content ---
$ find /source -xdev -type f | wc -l ; find /dest -xdev -type f | wc -l
412337
412337

$ du -sb --one-file-system /source /dest
193491230720	/source
193491230720	/dest

# Content-level, order-independent, NUL-safe:
$ ( cd /source && find . -xdev -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 sha256sum ) > /tmp/src.sums
$ ( cd /dest   && find . -xdev -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 sha256sum ) > /tmp/dst.sums
$ diff /tmp/src.sums /tmp/dst.sums && echo "IDENTICAL"
IDENTICAL

# Metadata-level (modes, owners, times) — checksums do not cover these:
$ ( cd /source && find . -printf '%M %U %G %s %T@ %P\n' | LC_ALL=C sort ) > /tmp/src.meta
$ ( cd /dest   && find . -printf '%M %U %G %s %T@ %P\n' | LC_ALL=C sort ) > /tmp/dst.meta
$ diff /tmp/src.meta /tmp/dst.meta

# --- After any archive creation: prove it is readable and complete ---
$ tar -tzf backup.tgz >/dev/null && echo "archive traversable"
$ tar -tzf backup.tgz | wc -l
412340
$ tar -df backup.tgz -C /source && echo "archive matches live tree"

# --- After any dd to a device: verify the bytes actually landed ---
$ sudo dd if=image.iso of=/dev/sdb bs=4M conv=fsync status=progress
$ sync
$ sudo blockdev --flushbufs /dev/sdb        # drop the block-device cache
$ SIZE=$(stat -c %s image.iso)
$ sha256sum image.iso
9f2c...  image.iso
$ sudo dd if=/dev/sdb bs=4M count=$SIZE iflag=count_bytes status=none | sha256sum
9f2c...  -
# Reading back the whole device would include trailing garbage — hence count_bytes.

# --- Detect hard links you are about to break ---
$ find /source -xdev -type f -links +1 -printf '%i %n %p\n' | sort -n | head
262149 2 /source/data/shard-00.db
262149 2 /source/archive/shard-00.db

# --- Detect sparse files you are about to inflate ---
$ find /source -xdev -type f -printf '%s %b %p\n' \
    | awk '$1 > $2*512*1.5 {printf "SPARSE %s (apparent %d, allocated %d)\n", $3, $1, $2*512}'
SPARSE /source/vm/disk.img (apparent 107374182400, allocated 8589934592)
$ filefrag -v /source/vm/disk.img | head -5
Filesystem type is: ef53
File size of /source/vm/disk.img is 107374182400 (26214400 blocks of 4096 bytes)
 ext:     logical_offset:        physical_offset: length:   expected: flags:
   0:        0..   32767:   1179648..  1212415:  32768:
   1:   262144..  294911:   1212416..  1245183:  32768:    1212416:
```

### 13.4 The pipeline-exit-status trap

```
$ tar -czf backup.tgz /srv | tee build.log
$ echo $?
0                        # ← this is TEE's exit status, not tar's

$ set -o pipefail
$ tar -czf backup.tgz /srv | tee build.log
$ echo $?
2                        # ← now the failure is visible

$ tar -czf backup.tgz /srv | tee build.log ; echo "${PIPESTATUS[@]}"
2 0                      # bash-specific, per-element statuses
```

A backup script that pipes through `tee`, `gzip`, `logger` or `ssh` without `set -o pipefail` reports success for every failure mode there is. This is how organisations discover, during a restore, that they have three years of empty tarballs.

---

## 14. Command reference for the exam

```
ls    -l -a -A -d -i -h -R -S -t -r -1 -F -U -f --color=never --time-style=

cp    -a -r/-R -p --preserve=all -d -L -P -u -n -i -f -v -l -s -x -t -T
      --reflink={auto,always,never}  --sparse={auto,always,never}  -b --backup=

mv    -f -i -n -u -v -b --backup= -t -T --strip-trailing-slashes

rm    -r/-R -f -i -I -d -v --one-file-system --preserve-root(default) --

rmdir -p -v --ignore-fail-on-non-empty

mkdir -p -m MODE -v -Z

touch -a -m -c -d STRING -t [[CC]YY]MMDDhhmm[.ss] -r REF -h

find  PATH [-P|-L|-H] -maxdepth -mindepth -depth -xdev -prune
      -name -iname -path -regex -type f,d,l,b,c,p,s
      -size N[cwbkMG] -empty -perm [-|/]MODE -links -inum
      -user -group -nouser -nogroup
      -mtime -atime -ctime -mmin -amin -cmin -newer -newerXY
      -print -print0 -printf FMT -delete -quit -ls
      -exec CMD {} \;   -exec CMD {} +   -execdir   -ok
      \( \) ! -a -o

tar   -c -x -t -r -u -A -d --delete
      -f -v -C -p --same-owner --numeric-owner
      -z -j -J --zstd -a -I 'PROG'
      --exclude= --exclude-from= -T/--files-from --null
      --strip-components=N --one-file-system --sparse
      --xattrs --acls --selinux --format={gnu,ustar,pax}
      --listed-incremental=SNAR --wildcards -P/--absolute-names

cpio  -o/--create  -i/--extract  -p/--pass-through
      -H {bin,odc,newc,crc,tar,ustar}
      -d -m -v -t -u -F FILE -0/--null --no-absolute-filenames

dd    if= of= bs= ibs= obs= count= skip= seek= status={none,noxfer,progress}
      conv=notrunc,noerror,sync,sparse,fsync,fdatasync,excl,nocreat,swab
      iflag=/oflag=direct,dsync,sync,fullblock,nocache,count_bytes,skip_bytes,seek_bytes

gzip  -k -d -c -1..-9 -t -l -n -r -v      | gunzip | zcat | zgrep | zless
bzip2 -k -d -c -1..-9 -t -v               | bunzip2 | bzcat | bzgrep | bzip2recover
xz    -k -d -c -0..-9 -e -t -l -T0        | unxz | xzcat | xzgrep | --info-memory
zstd  --rm -d -c -1..-19 --ultra -22 -T0  | unzstd | zstdcat | zstdgrep

file  -b -i --mime-type -s -z -L -f LIST -F SEP

globbing  *  ?  [abc]  [!abc]  [a-z]  [[:class:]]
bash      shopt -s extglob globstar nullglob failglob dotglob nocaseglob
          ?(p) *(p) +(p) @(p) !(p)   **   {a,b}  {1..10..2}
```

**Ten facts that decide exam questions:**

1. `*` never matches a leading `.`; `.*` matches `.` and `..`.
2. Globbing is done by the **shell**, before the command runs.
3. `rm` calls `unlink(2)` — space is freed only when link count **and** open-fd count are both zero.
4. `mv` within a filesystem is atomic `rename(2)`; across filesystems it is copy + delete.
5. `find -mtime +1` means **more than 48 hours**, not 24.
6. `find -size -1M` matches only **empty** files (sizes round up).
7. `-exec {} \;` forks once per file; `-exec {} +` batches.
8. `tar -C` is **positional** — it applies to the operands that follow it.
9. `cpio` reads its file list from **stdin** and needs `-H newc` for initramfs.
10. `dd` on a pipe requires `iflag=fullblock` or it silently truncates.

---

## References

**Certification objectives**
- LPI Exam 101-500 Objectives (v5.0), Topic 103.3 — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Certification Overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Standards**
- IEEE Std 1003.1-2024 (POSIX.1), Shell & Utilities — https://pubs.opengroup.org/onlinepubs/9799919799/
- POSIX pathname expansion — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_14
- POSIX `pax` format (`ustar` / extended headers) — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pax.html
- Filesystem Hierarchy Standard 3.0 — https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html

**GNU tool manuals**
- GNU Coreutils Manual (`ls`, `cp`, `mv`, `rm`, `rmdir`, `mkdir`, `touch`, `dd`, `install`, `truncate`, `sync`) — https://www.gnu.org/software/coreutils/manual/coreutils.html
- `dd` invocation — https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html
- GNU Findutils Manual (`find`, `xargs`, `locate`) — https://www.gnu.org/software/findutils/manual/html_mono/find.html
- GNU Tar Manual — https://www.gnu.org/software/tar/manual/tar.html
- GNU Tar: incremental dumps — https://www.gnu.org/software/tar/manual/html_node/Incremental-Dumps.html
- GNU cpio Manual — https://www.gnu.org/software/cpio/manual/cpio.html
- GNU Gzip Manual — https://www.gnu.org/software/gzip/manual/gzip.html
- GNU Bash Reference Manual — Filename Expansion — https://www.gnu.org/software/bash/manual/html_node/Filename-Expansion.html
- GNU Bash Reference Manual — Brace Expansion — https://www.gnu.org/software/bash/manual/html_node/Brace-Expansion.html
- GNU Bash Reference Manual — `shopt` — https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html

**Kernel and system-call documentation**
- `man7.org` — `unlink(2)` — https://man7.org/linux/man-pages/man2/unlink.2.html
- `man7.org` — `rename(2)` / `renameat2(2)` — https://man7.org/linux/man-pages/man2/rename.2.html
- `man7.org` — `copy_file_range(2)` — https://man7.org/linux/man-pages/man2/copy_file_range.2.html
- `man7.org` — `statx(2)` — https://man7.org/linux/man-pages/man2/statx.2.html
- `man7.org` — `utimensat(2)` — https://man7.org/linux/man-pages/man2/utimensat.2.html
- `man7.org` — `execve(2)` (`ARG_MAX`, `MAX_ARG_STRLEN`, `E2BIG`) — https://man7.org/linux/man-pages/man2/execve.2.html
- `man7.org` — `inode(7)` — https://man7.org/linux/man-pages/man7/inode.7.html
- `man7.org` — `glob(7)` — https://man7.org/linux/man-pages/man7/glob.7.html
- Linux kernel: initramfs buffer format (`newc`) — https://www.kernel.org/doc/html/latest/driver-api/early-userspace/buffer-format.html
- Linux kernel: filesystem mount options (`relatime`, `noatime`, `lazytime`) — https://www.kernel.org/doc/html/latest/filesystems/proc.html

**Compression**
- XZ Utils — https://tukaani.org/xz/
- Zstandard manual — https://facebook.github.io/zstd/zstd_manual.html
- bzip2 documentation — https://sourceware.org/bzip2/manual/manual.html
- RFC 1952 — GZIP file format specification — https://www.rfc-editor.org/rfc/rfc1952
- RFC 1951 — DEFLATE compressed data format — https://www.rfc-editor.org/rfc/rfc1951

**Systemd and orchestration**
- `systemd-tmpfiles` / `tmpfiles.d(5)` — https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html
- `systemd.timer(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
- Kubernetes — CronJob — https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes — Init Containers — https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- Kubernetes — Volume Snapshots — https://kubernetes.io/docs/concepts/storage/volume-snapshots/

**Reproducibility and security**
- Reproducible Builds — `SOURCE_DATE_EPOCH` — https://reproducible-builds.org/docs/source-date-epoch/
- Reproducible Builds — Archive metadata — https://reproducible-builds.org/docs/archives/
- CWE-22: Improper Limitation of a Pathname to a Restricted Directory (path traversal in archives) — https://cwe.mitre.org/data/definitions/22.html