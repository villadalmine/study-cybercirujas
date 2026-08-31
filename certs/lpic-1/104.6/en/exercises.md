# LPIC-1 · 104.6 — Create and change hard and symbolic links

**Exam:** 101-500 · **Objective weight:** 3.12
**Guided exercises.** Every step is meant to be executed. Answers are at the bottom, in a collapsible section — write your own answer down before opening it.

---

## Before you start

You need a normal user account, a writable home directory, GNU coreutils (any modern distribution), and `sudo` for Exercises 6 and 10 only. Nothing here touches system files destructively; the last section cleans up.

```bash
$ mkdir -p ~/lab-104.6 && cd ~/lab-104.6
$ pwd
/home/student/lab-104.6
```

Two facts frame everything that follows:

- A **file** on a POSIX filesystem is an **inode**: metadata (mode, owner, timestamps, size, link count) plus pointers to data blocks. The inode has **no name**.
- A **name** is a directory entry: a `(name → inode number)` pair stored *in a directory*. "Deleting a file" is `unlink(2)` — removing a name. The inode dies when its link count reaches zero **and** no process holds it open.

Everything about hard and symbolic links falls out of those two sentences.

---

## Exercise 1 — Inodes, names, and link counts

1. Create a payload file and look at it with the inode number visible:

```bash
$ printf 'release: 1.0\nchecksum: 8f14e45f\n' > payload.txt
$ ls -li
total 4
1442653 -rw-r--r-- 1 student student 32 Aug 26 09:14 payload.txt
```

2. Read the full inode metadata:

```bash
$ stat payload.txt
  File: payload.txt
  Size: 32              Blocks: 8          IO Block: 4096   regular file
Device: fd00h/64768d    Inode: 1442653     Links: 1
Access: (0644/-rw-r--r--)  Uid: ( 1000/ student)   Gid: ( 1000/ student)
Access: 2026-08-26 09:14:02.118374915 -0300
Modify: 2026-08-26 09:14:02.118374915 -0300
Change: 2026-08-26 09:14:02.118374915 -0300
 Birth: 2026-08-26 09:14:02.118374915 -0300
```

3. Print only the fields you will keep checking during this lab:

```bash
$ stat -c '%i %h %s %n' payload.txt
1442653 1 32 payload.txt
```

`%i` = inode, `%h` = hard link count, `%s` = size, `%n` = name.

4. Confirm the second column of `ls -l` is that link count, not something else:

```bash
$ ls -l payload.txt | awk '{print $2}'
1
```

**Check your understanding**

- **Q1.1** — Where is the name `payload.txt` physically stored: in the inode, or somewhere else?
- **Q1.2** — `stat` shows `Modify` and `Change` separately. Which one changes if you run `chmod 600 payload.txt`, and why does that distinction matter for hard links?
- **Q1.3** — In `ls -l`, what exactly is the number in the second column for a regular file?

---

## Exercise 2 — Hard links: one inode, several names

1. Create a second name for the same inode with `ln` (no options = hard link):

```bash
$ ln payload.txt payload-hard.txt
$ ls -li
total 8
1442653 -rw-r--r-- 2 student student 32 Aug 26 09:14 payload-hard.txt
1442653 -rw-r--r-- 2 student student 32 Aug 26 09:14 payload.txt
```

Same inode number. The link count went `1 → 2`. `total 8` counts the blocks twice, but the data exists once — you will measure that in Exercise 7.

2. Write through one name, read through the other:

```bash
$ echo 'note: patched in place' >> payload.txt
$ cat payload-hard.txt
release: 1.0
checksum: 8f14e45f
note: patched in place
```

3. Change metadata through one name:

```bash
$ chmod 640 payload-hard.txt
$ chown --from=student student payload.txt   # no-op, just proving the syntax works
$ ls -li
1442653 -rw-r----- 2 student student 55 Aug 26 09:16 payload-hard.txt
1442653 -rw-r----- 2 student student 55 Aug 26 09:16 payload.txt
```

Permissions and ownership live in the inode, so both names show `-rw-r-----`. There is no such thing as "the permissions of a hard link".

4. Rename the *original* name and check that nothing breaks:

```bash
$ mv payload.txt payload-renamed.txt
$ ls -li
1442653 -rw-r----- 2 student student 55 Aug 26 09:16 payload-hard.txt
1442653 -rw-r----- 2 student student 55 Aug 26 09:16 payload-renamed.txt
$ cat payload-hard.txt | tail -1
note: patched in place
```

5. Find every name pointing at that inode:

```bash
$ find ~ -samefile payload-hard.txt 2>/dev/null
/home/student/lab-104.6/payload-hard.txt
/home/student/lab-104.6/payload-renamed.txt

$ find ~ -inum 1442653 2>/dev/null
/home/student/lab-104.6/payload-hard.txt
/home/student/lab-104.6/payload-renamed.txt
```

**Check your understanding**

- **Q2.1** — After step 4, which of the two names is "the original file"?
- **Q2.2** — Why did `chmod` through `payload-hard.txt` also change `payload-renamed.txt`?
- **Q2.3** — `find -inum 1442653` and `find -samefile X` returned the same thing here. On a machine with several mounted filesystems, why is `-samefile` the safer of the two?
- **Q2.4** — You need to give a colleague read access to a 40 GB dataset in your home directory without copying it. Is a hard link a valid technique here? What must be true of the destination path?

---

## Exercise 3 — Deletion semantics: unlink, link count, and open descriptors

1. Remove one name and watch the count drop:

```bash
$ rm payload-renamed.txt
$ stat -c '%i %h %n' payload-hard.txt
1442653 1 payload-hard.txt
```

The data is untouched; only a directory entry disappeared.

2. Now the case that confuses every junior SRE. Create a large file, hold it open with a file descriptor, delete it, and watch the space *not* come back:

```bash
$ dd if=/dev/zero of=bigfile bs=1M count=64 status=none
$ df -h . | tail -1
/dev/vda2        40G   12G   26G  32% /home

$ exec 9< bigfile          # shell opens fd 9 on the inode
$ rm bigfile               # unlink: the NAME is gone
$ ls bigfile
ls: cannot access 'bigfile': No such file or directory

$ ls -l /proc/$$/fd/9
lr-x------ 1 student student 64 Aug 26 09:22 /proc/4187/fd/9 -> '/home/student/lab-104.6/bigfile (deleted)'
```

3. The inode still exists — you can still read it through the descriptor:

```bash
$ head -c 8 /proc/$$/fd/9 | xxd
00000000: 0000 0000 0000 0000                      ........
```

4. Release it and the blocks are freed:

```bash
$ exec 9<&-
$ ls -l /proc/$$/fd/9
ls: cannot access '/proc/4187/fd/9': No such file or directory
```

5. In production you find these with `lsof`:

```bash
$ sudo lsof +L1 2>/dev/null | head -3
COMMAND    PID USER   FD   TYPE DEVICE SIZE/OFF NLINK    NODE NAME
rsyslogd   912 root    7w   REG  253,2 21474836     0 1442701 /var/log/messages (deleted)
```

`NLINK 0` = deleted but held open.

6. Directories have their own link-count arithmetic:

```bash
$ mkdir -p parent
$ stat -c '%h %n' parent
2 parent

$ mkdir parent/child-a parent/child-b
$ stat -c '%h %n' parent
4 parent
```

**Check your understanding**

- **Q3.1** — `df` reports a full `/var` but `du -sh /var` accounts for far less. Give the most common cause and the exact command that proves it.
- **Q3.2** — A directory you just created has a link count of 2. Name both links.
- **Q3.3** — After creating two subdirectories the count is 4. Where did links 3 and 4 come from?
- **Q3.4** — Why does log rotation by `rm` + restart-less truncation differ? Specifically: why does `> /var/log/messages` free space immediately while `rm /var/log/messages` does not?

---

## Exercise 4 — Symbolic links: a file whose contents are a path

1. Create one with `ln -s`:

```bash
$ ln -s payload-hard.txt payload-sym.txt
$ ls -li
total 8
1442653 -rw-r----- 1 student student 55 Aug 26 09:16 payload-hard.txt
1442667 lrwxrwxrwx 1 student student 16 Aug 26 09:26 payload-sym.txt -> payload-hard.txt
```

Three things to notice: a **different inode**, file type `l`, and **size 16** — exactly `strlen("payload-hard.txt")`. The symlink's "contents" *are* the target path string.

2. Prove the size claim:

```bash
$ ln -s /a/very/much/longer/path/that/does/not/exist demo-long
$ stat -c '%s %N' demo-long payload-sym.txt
41 'demo-long' -> '/a/very/much/longer/path/that/does/not/exist'
16 'payload-sym.txt' -> 'payload-hard.txt'
```

3. `stat` follows nothing by default; `stat -L` dereferences:

```bash
$ stat -c '%i %F %s' payload-sym.txt
1442667 symbolic link 16

$ stat -L -c '%i %F %s' payload-sym.txt
1442653 regular file 55
```

4. Read the link, and resolve it fully:

```bash
$ readlink payload-sym.txt
payload-hard.txt

$ readlink -f payload-sym.txt
/home/student/lab-104.6/payload-hard.txt

$ realpath payload-sym.txt
/home/student/lab-104.6/payload-hard.txt
```

`readlink -f` canonicalises every component and tolerates a missing *final* component; `readlink -e` requires the whole path to exist; `readlink -m` requires nothing:

```bash
$ readlink -f demo-long
/a/very/much/longer/path/that/does/not/exist
$ readlink -e demo-long; echo "exit=$?"
exit=1
```

5. The `lrwxrwxrwx` mode is cosmetic on Linux — access is decided by the target's permissions and by the directories you traverse:

```bash
$ chmod 000 payload-sym.txt
chmod: changing permissions of 'payload-sym.txt': Operation not supported
```

6. Ownership and timestamps of the link itself need `-h`:

```bash
$ touch -h payload-sym.txt          # touches the link, not the target
$ sudo chown -h root: payload-sym.txt   # would change the LINK's owner
$ sudo chown root: payload-sym.txt      # would change the TARGET's owner
```

(Do not run the two `chown` lines unless you intend to; they are shown for the contrast.)

**Check your understanding**

- **Q4.1** — Why does `ls -l` show size 16 for a symlink whose target is a 55-byte file?
- **Q4.2** — You need to know whether `/etc/localtime` is itself a symlink, without following it. Which command and which flag?
- **Q4.3** — `chmod 000` on the symlink failed. What are the two things that actually gate access through a symlink?
- **Q4.4** — Explain the difference between `readlink -f`, `readlink -e`, and `readlink -m` in one sentence each.
- **Q4.5** — A backup script runs `chown -R appuser: /srv/app`. `/srv/app/tmp` is a symlink to `/var/tmp`. What is the blast radius, and which flag would have contained it?

---

## Exercise 5 — Relative vs absolute symlinks, and what survives a move

1. Build both flavours side by side:

```bash
$ mkdir -p tree/data tree/links
$ echo "payload v1" > tree/data/file.txt
$ ln -s ../data/file.txt          tree/links/rel.txt
$ ln -s "$PWD/tree/data/file.txt" tree/links/abs.txt
$ ls -l tree/links/
lrwxrwxrwx 1 student student 40 Aug 26 09:31 abs.txt -> /home/student/lab-104.6/tree/data/file.txt
lrwxrwxrwx 1 student student 17 Aug 26 09:31 rel.txt -> ../data/file.txt
```

2. Both resolve today:

```bash
$ cat tree/links/rel.txt tree/links/abs.txt
payload v1
payload v1
```

3. Move the whole tree — the classic "we changed the mount point" scenario:

```bash
$ mv tree tree-moved
$ cat tree-moved/links/rel.txt
payload v1
$ cat tree-moved/links/abs.txt
cat: tree-moved/links/abs.txt: No such file or directory
```

4. Now move only the *link*, which is the opposite failure:

```bash
$ mv tree-moved/links/rel.txt .
$ cat rel.txt
cat: rel.txt: No such file or directory
$ readlink rel.txt
../data/file.txt
$ mv rel.txt tree-moved/links/     # put it back
```

5. Let `ln` compute the relative path for you (`-r`, coreutils ≥ 8.16):

```bash
$ ln -sr tree-moved/data/file.txt tree-moved/links/auto.txt
$ readlink tree-moved/links/auto.txt
../data/file.txt
```

6. The `ln -sf` directory trap. Set up a release layout:

```bash
$ mkdir -p releases/v1 releases/v2
$ echo v1 > releases/v1/VERSION
$ echo v2 > releases/v2/VERSION
$ cd releases
$ ln -s v1 current
$ readlink current
v1
```

Now try to repoint it the obvious way:

```bash
$ ln -sf v2 current
$ readlink current
v1
$ ls -l v1/
total 4
-rw-r--r-- 1 student student 3 Aug 26 09:33 VERSION
lrwxrwxrwx 1 student student 2 Aug 26 09:34 v2 -> v2
```

`ln` **followed** `current` into `v1/` and created a link *inside* it. Undo and do it correctly:

```bash
$ rm v1/v2
$ ln -sfn v2 current
$ readlink current
v2
$ cd ..
```

**Check your understanding**

- **Q5.1** — State the rule for which reference point a relative symlink is resolved against.
- **Q5.2** — For a symlink inside a package that will be installed under an arbitrary `DESTDIR`, do you use relative or absolute? Why?
- **Q5.3** — Explain precisely why `ln -sf v2 current` created `v1/v2` instead of repointing `current`.
- **Q5.4** — What does `-n` (`--no-dereference`) tell `ln` to do?
- **Q5.5** — `ln -sfn` is still not atomic. Describe the window of inconsistency, and write a command pair that closes it.

---

## Exercise 6 — The boundaries: what a hard link cannot do

1. **Cross-filesystem.** `/dev/shm` is a separate `tmpfs` mount on virtually every distribution:

```bash
$ findmnt -no TARGET,FSTYPE /dev/shm .
/dev/shm  tmpfs
/home     ext4

$ ln payload-hard.txt /dev/shm/attempt
ln: failed to create hard link '/dev/shm/attempt' => 'payload-hard.txt': Invalid cross-device link
```

`EXDEV`. An inode number is only meaningful within one filesystem, so a directory entry can never point outside its own.

2. A symlink crosses freely, because it stores a *path*, not an inode number:

```bash
$ ln -s "$PWD/payload-hard.txt" /dev/shm/attempt
$ cat /dev/shm/attempt | head -1
release: 1.0
$ rm /dev/shm/attempt
```

3. **Directories.** Hard-linking a directory is refused:

```bash
$ ln parent parent-link
ln: parent: hard link not allowed for directory

$ sudo ln -d parent parent-link
ln: failed to create hard link 'parent-link' => 'parent': Operation not permitted
```

Even as root, the Linux kernel returns `EPERM` from `link(2)` on a directory. Symlinks to directories are fine and are how the whole filesystem hierarchy is stitched together.

4. **Loops.** Symlinks can point at each other; the kernel gives up after 40 resolutions:

```bash
$ ln -s loop-b loop-a
$ ln -s loop-a loop-b
$ cat loop-a
cat: loop-a: Too many levels of symbolic links
$ ls -l loop-a
lrwxrwxrwx 1 student student 6 Aug 26 09:38 loop-a -> loop-b
```

Note that `ls -l` still works — it never dereferences.

5. **Dangling links.** Nothing stops you from creating a link to a path that does not exist:

```bash
$ ln -s /srv/not-deployed-yet broken
$ ls -l broken
lrwxrwxrwx 1 student student 20 Aug 26 09:39 broken -> /srv/not-deployed-yet

$ cat broken
cat: broken: No such file or directory

$ [ -e broken ]; echo "exists=$?"
exists=1
$ [ -L broken ]; echo "is-a-symlink=$?"
is-a-symlink=0
```

6. Find broken links across a tree:

```bash
$ find . -xtype l
./broken
./loop-a
./loop-b
./demo-long
```

**Check your understanding**

- **Q6.1** — Why is `EXDEV` a structural limitation rather than a policy decision someone could relax?
- **Q6.2** — Give two concrete problems that would arise if hard links to directories were permitted.
- **Q6.3** — In a shell script, which test distinguishes "this is a symlink" from "this resolves to something that exists"? Write the check for a *broken* symlink.
- **Q6.4** — What is the difference between `find -type l` and `find -xtype l`?
- **Q6.5** — Your deployment creates `/opt/app/current -> /opt/app/releases/2026-08-26` *before* the release directory is unpacked. `ls -l` looks correct and the service fails to start. What is the diagnostic command?

---

## Exercise 7 — Auditing: disk usage, inodes, and finding links at scale

1. Hard links are counted once per `du` traversal:

```bash
$ mkdir -p usage && cd usage
$ dd if=/dev/zero of=blob.bin bs=1M count=10 status=none
$ ln blob.bin blob-alias.bin
$ ls -l
total 20480
-rw-r--r-- 2 student student 10485760 Aug 26 09:42 blob-alias.bin
-rw-r--r-- 2 student student 10485760 Aug 26 09:42 blob.bin

$ du -sh .
10M     .
$ du -sh --count-links .
20M     .
```

`ls` sums per-name and lies; `du` deduplicates by `(device, inode)` and tells the truth about disk consumption.

2. A symlink costs an inode and, on ext4, usually zero data blocks:

```bash
$ ln -s blob.bin blob-sym.bin
$ du -sh --apparent-size blob-sym.bin
8       blob-sym.bin
$ du -sh blob.bin blob-sym.bin
10M     blob.bin
0       blob-sym.bin
```

ext4 stores a target shorter than 60 bytes inline in the inode's block-pointer area ("fast symlink"), so no block is allocated.

3. Inodes are a finite, separately exhaustible resource:

```bash
$ df -i /home
Filesystem       Inodes   IUsed    IFree IUse% Mounted on
/dev/vda2       2621440  318204  2303236   13% /home
```

4. The audit queries you should have memorised:

```bash
# Regular files with more than one name (candidates for surprise shared edits)
$ find . -type f -links +1 -printf '%n %i %p\n'
2 1442712 ./blob-alias.bin
2 1442712 ./blob.bin

# Every symlink and where it points
$ find . -type l -printf '%p -> %l\n'
./blob-sym.bin -> blob.bin

# Only broken ones
$ find . -xtype l

# Every name of one specific inode, limited to one filesystem
$ find / -xdev -samefile ./blob.bin 2>/dev/null
```

5. Confirm the shared-inode risk is real:

```bash
$ cd ~/lab-104.6
```

**Check your understanding**

- **Q7.1** — `ls -l` says 20 MB, `du -sh` says 10 MB. Which is the right number to report to capacity planning, and why do both exist?
- **Q7.2** — `du` deduplicates hard links *within one invocation*. What happens if you run `du -sh dir-a` and `du -sh dir-b` separately, and the same inode is linked into both?
- **Q7.3** — `df -h` shows 60% free but writes fail with `No space left on device`. What do you check next, and with which command?
- **Q7.4** — Write a single `find` command that lists every symlink under `/etc` together with its target.
- **Q7.5** — Why does `find / -samefile X` deserve `-xdev` in an audit script?

---

## Exercise 8 — Links vs copies: `cp`, `tar`, `rsync`, and in-place editors

1. Set up a small tree containing both link types:

```bash
$ mkdir -p src && cd src
$ echo "config v1" > app.conf
$ ln app.conf app.conf.hard
$ ln -s app.conf app.conf.sym
$ ls -li
1442731 -rw-r--r-- 2 student student 10 Aug 26 09:48 app.conf
1442731 -rw-r--r-- 2 student student 10 Aug 26 09:48 app.conf.hard
1442745 lrwxrwxrwx 1 student student  8 Aug 26 09:48 app.conf.sym -> app.conf
$ cd ..
```

2. Plain `cp -r` **dereferences** symlinks and **breaks** hard links:

```bash
$ cp -r src dst-plain
$ ls -li dst-plain
1442760 -rw-r--r-- 1 student student 10 Aug 26 09:49 app.conf
1442761 -rw-r--r-- 1 student student 10 Aug 26 09:49 app.conf.hard
1442762 -rw-r--r-- 1 student student 10 Aug 26 09:49 app.conf.sym
```

Three independent regular files. The symlink became a copy of its target.

3. `cp -a` (archive) preserves both:

```bash
$ cp -a src dst-archive
$ ls -li dst-archive
1442770 -rw-r--r-- 2 student student 10 Aug 26 09:48 app.conf
1442770 -rw-r--r-- 2 student student 10 Aug 26 09:48 app.conf.hard
1442771 lrwxrwxrwx 1 student student  8 Aug 26 09:48 app.conf.sym -> app.conf
```

`-a` = `-dR --preserve=all`, and `-d` = `--no-dereference --preserve=links`.

4. `cp -l` makes hard links instead of copying data — the basis of snapshot backups (`rsnapshot`, `cp -al` rotations):

```bash
$ cp -al src snapshot-1
$ stat -c '%i %h %n' src/app.conf snapshot-1/app.conf
1442731 3 src/app.conf
1442731 3 snapshot-1/app.conf
```

A "full backup" that consumed zero extra data blocks. The catch is Q8.4.

5. `tar` preserves both by default; `-h` collapses symlinks:

```bash
$ tar -cf archive.tar src
$ tar -tvf archive.tar
drwxr-xr-x student/student   0 2026-08-26 09:48 src/
-rw-r--r-- student/student  10 2026-08-26 09:48 src/app.conf
hrw-r--r-- student/student   0 2026-08-26 09:48 src/app.conf.hard link to src/app.conf
lrwxrwxrwx student/student   0 2026-08-26 09:48 src/app.conf.sym -> app.conf

$ tar -chf archive-deref.tar src
$ tar -tvf archive-deref.tar | grep sym
-rw-r--r-- student/student  10 2026-08-26 09:48 src/app.conf.sym
```

6. `rsync -a` implies `-l` (copy symlinks as symlinks) but **not** `-H` (preserve hard links):

```bash
$ rsync -a src/ dst-rsync/
$ stat -c '%i %h %n' dst-rsync/app.conf dst-rsync/app.conf.hard
1442790 1 dst-rsync/app.conf
1442791 1 dst-rsync/app.conf.hard

$ rsync -aH --delete src/ dst-rsync/
$ stat -c '%i %h %n' dst-rsync/app.conf dst-rsync/app.conf.hard
1442795 2 dst-rsync/app.conf
1442795 2 dst-rsync/app.conf.hard
```

7. In-place editors: `sed -i` **breaks** hard links, because it writes a temp file and `rename(2)`s over the name:

```bash
$ cd src
$ stat -c '%i %h %n' app.conf app.conf.hard
1442731 3 app.conf
1442731 3 app.conf.hard

$ sed -i 's/v1/v2/' app.conf
$ stat -c '%i %h %n' app.conf app.conf.hard
1442801 1 app.conf
1442731 2 app.conf.hard
$ cat app.conf app.conf.hard
config v2
config v1
```

The names diverged. Note the snapshot at `snapshot-1/app.conf` still holds `config v1` — which is precisely why `cp -al` snapshots work.

8. `cp` onto an existing name, in contrast, **writes through** (open + `O_TRUNC`) and keeps the inode:

```bash
$ echo "config v3" > /tmp/new.conf
$ cp /tmp/new.conf app.conf.hard
$ stat -c '%i %h %n' app.conf.hard
1442731 2 app.conf.hard
$ cat app.conf.hard snapshot-out 2>/dev/null | head -1
config v3
$ cat ../snapshot-1/app.conf
config v3
```

The snapshot was silently modified. `cp --remove-destination` restores copy-then-replace semantics.

9. And on a symlink, `sed -i` replaces the link with a regular file unless told otherwise:

```bash
$ sed -i 's/v3/v4/' app.conf.sym
$ ls -l app.conf.sym
-rw-r--r-- 1 student student 10 Aug 26 09:55 app.conf.sym

$ cd .. && rm -rf src && mkdir src && cd src   # rebuild for the next line
$ echo "config v1" > app.conf && ln -s app.conf app.conf.sym
$ sed -i --follow-symlinks 's/v1/v2/' app.conf.sym
$ ls -l app.conf.sym && cat app.conf
lrwxrwxrwx 1 student student 8 Aug 26 09:56 app.conf.sym -> app.conf
config v2
$ cd ..
```

**Check your understanding**

- **Q8.1** — Two backup jobs: `cp -r /srv /backup` and `cp -a /srv /backup`. Name three differences in the result.
- **Q8.2** — Which `rsync` flag preserves hard links, and why is it deliberately excluded from `-a`?
- **Q8.3** — `tar -czf web.tar.gz /var/www` produced an archive far larger than `du -sh /var/www`. What single flag was probably in the command line, and what did it do?
- **Q8.4** — A `cp -al` snapshot rotation is in place. An administrator runs `cp new.conf /srv/app/app.conf`. Explain what happens to yesterday's snapshot, and what the administrator should have run instead.
- **Q8.5** — Why does `sed -i` break a hard link while `>>` does not?
- **Q8.6** — Your `vim` sessions keep breaking hard links on `/etc/` files. Which `vim` setting controls this, and to what value?

---

## Exercise 9 — Production patterns you will meet on a real system

1. **Atomic release switching.** This is the single most common symlink pattern in deployment tooling:

```bash
$ cd ~/lab-104.6/releases
$ ls
current  v1  v2
$ mkdir v3 && echo v3 > v3/VERSION
```

The non-atomic way (`ln -sfn` = `unlink()` then `symlink()`) leaves a window where `current` does not exist:

```bash
$ ln -sfn v3 current
$ readlink current
v3
```

The atomic way — create a temporary link, then `rename(2)` it over the old one in a single kernel operation:

```bash
$ ln -s v2 current.tmp
$ mv -T current.tmp current
$ readlink current
v2
```

`-T` (`--no-target-directory`) is mandatory: without it, `mv` would follow `current` into `v2/` and deposit the link there.

2. **Removing a symlink to a directory.** The trailing slash matters more than anywhere else in the shell:

```bash
$ ls current/
VERSION
$ rm current
$ ls
current.tmp  v1  v2  v3
$ ls v2/
VERSION
```

`rm` on the symlink removed the *link only*; `v2/` is intact. And GNU `rm` refuses the trailing-slash form outright:

```bash
$ ln -s v2 current
$ rm -r current/
rm: cannot remove 'current/': Not a directory
$ ls v2/
VERSION
```

3. **Shared library versioning.** Every `.so` you have ever linked against is a two-hop symlink chain:

```bash
$ ls -l /usr/lib64/libz.so*        # paths vary by distribution
lrwxrwxrwx 1 root root     13 Jun  2 11:04 /usr/lib64/libz.so -> libz.so.1.3.1
lrwxrwxrwx 1 root root     13 Jun  2 11:04 /usr/lib64/libz.so.1 -> libz.so.1.3.1
-rwxr-xr-x 1 root root 121208 Jun  2 11:04 /usr/lib64/libz.so.1.3.1
```

- `libz.so.1.3.1` — the real file, the *realname*.
- `libz.so.1` — the **SONAME**, what the dynamic linker records in every binary and resolves at run time. Created by `ldconfig`.
- `libz.so` — the *linker name*, used only by `ld` at build time, shipped in the `-devel` package.

Reproduce the pattern locally:

```bash
$ cd ~/lab-104.6 && mkdir -p libdemo && cd libdemo
$ : > libdemo.so.1.2.3
$ ln -s libdemo.so.1.2.3 libdemo.so.1
$ ln -s libdemo.so.1     libdemo.so
$ ls -l
lrwxrwxrwx 1 student student  11 Aug 26 10:02 libdemo.so -> libdemo.so.1
lrwxrwxrwx 1 student student  15 Aug 26 10:02 libdemo.so.1 -> libdemo.so.1.2.3
-rw-r--r-- 1 student student   0 Aug 26 10:02 libdemo.so.1.2.3
$ cd ..
```

4. **`/etc/localtime`** — a symlink into the tzdata database:

```bash
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 52 Jun  2 11:03 /etc/localtime -> ../usr/share/zoneinfo/America/Argentina/Buenos_Aires
$ readlink -f /etc/localtime
/usr/share/zoneinfo/America/Argentina/Buenos_Aires
```

Note it is **relative** (`../usr/...`), which is deliberate: it keeps working inside a chroot or container image built with a different root.

5. **`systemctl enable` is symlink management.** There is no database:

```bash
$ ls -l /etc/systemd/system/multi-user.target.wants/ | head -4
total 0
lrwxrwxrwx 1 root root 36 Jun  2 11:10 sshd.service -> /usr/lib/systemd/system/sshd.service
lrwxrwxrwx 1 root root 41 Jun  2 11:10 chronyd.service -> /usr/lib/systemd/system/chronyd.service

$ systemctl is-enabled sshd
enabled
```

`disable` deletes the symlink. `mask` replaces the unit path with a symlink to `/dev/null`:

```bash
$ systemctl is-enabled systemd-networkd 2>/dev/null; ls -l /etc/systemd/system/tmp.mount 2>/dev/null
lrwxrwxrwx 1 root root 9 Jun  2 11:11 /etc/systemd/system/tmp.mount -> /dev/null
```

6. **`/etc/alternatives`** — a two-level symlink chain so several packages can provide `editor`, `java`, `python`:

```bash
$ ls -l /usr/bin/editor /etc/alternatives/editor 2>/dev/null
lrwxrwxrwx 1 root root 24 Jun  2 11:06 /etc/alternatives/editor -> /usr/bin/vim.basic
lrwxrwxrwx 1 root root 22 Jun  2 11:06 /usr/bin/editor -> /etc/alternatives/editor
```

7. **`/proc/<pid>/exe` and `/proc/<pid>/cwd`** are kernel-synthesised symlinks — useful for forensics:

```bash
$ ls -l /proc/self/exe
lrwxrwxrwx 1 student student 0 Aug 26 10:05 /proc/4187/exe -> /usr/bin/ls
$ readlink /proc/self/cwd
/home/student/lab-104.6
```

**Check your understanding**

- **Q9.1** — Why is `mv -T newlink current` atomic while `ln -sfn` is not, and what does a request that arrives during the `ln -sfn` window see?
- **Q9.2** — Why is `-T` required in that `mv`?
- **Q9.3** — In `libz.so`, `libz.so.1`, `libz.so.1.3.1` — which one does a *running* binary resolve, which one does the *compiler* use, and which program creates the middle link?
- **Q9.4** — `/etc/localtime` is a relative symlink. Give the operational reason.
- **Q9.5** — A colleague reports "`systemctl disable` didn't work, the service still starts at boot." Which two directories do you inspect, and what are you looking for?
- **Q9.6** — What does masking a unit do at the filesystem level, and why is it stronger than disabling?

---

## Exercise 10 — Kernel hardening: protected symlinks and hardlinks

`/tmp` is world-writable and sticky, which historically enabled symlink- and hardlink-based privilege escalation: an attacker pre-creates `/tmp/somefile` as a symlink to `/etc/shadow`, and a root daemon that writes to that predictable path clobbers it.

1. Check the two sysctls (default `1` on essentially every modern distribution):

```bash
$ sysctl fs.protected_symlinks fs.protected_hardlinks
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
```

2. `fs.protected_hardlinks=1` forbids hard-linking a file you neither own nor have read+write access to. Prove it:

```bash
$ sudo sh -c 'echo secret > /tmp/rootfile && chmod 600 /tmp/rootfile'
$ ls -l /tmp/rootfile
-rw------- 1 root root 7 Aug 26 10:10 /tmp/rootfile

$ ln /tmp/rootfile /tmp/mine
ln: failed to create hard link '/tmp/mine' => '/tmp/rootfile': Operation not permitted
```

Without the protection this would succeed: the link count would rise, and deleting `/tmp/rootfile` would *not* free the inode, leaving the attacker a permanent handle on the content.

3. A symlink, by contrast, is always creatable — creating one grants no access:

```bash
$ ln -s /tmp/rootfile /tmp/mysym
$ cat /tmp/mysym
cat: /tmp/mysym: Permission denied
```

4. `fs.protected_symlinks=1` restricts *following* a symlink in a sticky world-writable directory when the symlink's owner differs from both the directory owner and the following process. Check the sticky bit:

```bash
$ ls -ld /tmp
drwxrwxrwt 1 root root 4096 Aug 26 10:10 /tmp
```

The `t` is what activates the rule.

5. Clean up:

```bash
$ sudo rm -f /tmp/rootfile /tmp/mysym
```

6. Applications defend themselves with `O_NOFOLLOW` / `openat2(RESOLVE_NO_SYMLINKS)`. From the shell, the equivalent hygiene is to canonicalise before acting:

```bash
$ target=$(readlink -e /path/from/config) || { echo "refusing: does not resolve" >&2; exit 1; }
$ case "$target" in /srv/app/*) : ;; *) echo "refusing: escapes /srv/app" >&2; exit 1 ;; esac
```

**Check your understanding**

- **Q10.1** — Why is `fs.protected_hardlinks` necessary at all, given that a hard link does not change the file's permissions?
- **Q10.2** — Which directory property must be present for `fs.protected_symlinks` to apply?
- **Q10.3** — Why can *anyone* create a symlink to `/etc/shadow` without that being a vulnerability by itself?
- **Q10.4** — A backup script runs as root and does `cat "$userpath" > /backup/out`. Sketch the attack a user can mount with a symlink, and one mitigation.

---

## Cleanup

```bash
$ cd ~ && rm -rf ~/lab-104.6
$ rm -f /dev/shm/attempt
```

---

## Command reference for this objective

| Task | Command |
|---|---|
| Hard link | `ln TARGET LINKNAME` |
| Symbolic link | `ln -s TARGET LINKNAME` |
| Relative symlink, computed | `ln -sr TARGET LINKNAME` |
| Repoint an existing dir symlink | `ln -sfn NEWTARGET LINKNAME` |
| Repoint atomically | `ln -s NEW L.tmp && mv -T L.tmp L` |
| Hard link to the symlink itself | `ln -P SYMLINK NEWNAME` |
| Show inode + link count | `ls -li` / `stat -c '%i %h %n' F` |
| Follow the link in `stat` | `stat -L F` |
| Read a symlink's target | `readlink F` |
| Canonicalise | `readlink -f` / `-e` / `-m`, `realpath F` |
| All names of one inode | `find DIR -xdev -samefile F` |
| All symlinks + targets | `find DIR -type l -printf '%p -> %l\n'` |
| Broken symlinks | `find DIR -xtype l` |
| Multiply-linked regular files | `find DIR -type f -links +1` |
| True disk usage | `du -sh DIR` (vs `--count-links`) |
| Inode exhaustion | `df -i` |
| Remove one name | `rm F` or `unlink F` |
| Copy preserving links | `cp -a`, `cp -d`, `rsync -aH` |
| Copy as hard links (snapshot) | `cp -al SRC DST` |
| Change owner of the link itself | `chown -h`, `touch -h` |

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — In the **parent directory**, not in the inode. A directory is a table of `(name, inode number)` entries. The inode holds mode, owner, timestamps, size, link count and block pointers, but never a name. This is exactly why one inode can carry many names and why a file can be renamed without touching its data.

**A1.2** — `chmod` updates **`Change` (ctime)** only, because it modifies inode metadata, not file contents. `Modify` (mtime) tracks data changes. For hard links this matters because *both timestamps live in the inode*: touching the file through any name updates the mtime seen through every name. There is no per-name timestamp.

**A1.3** — The **hard link count**: the number of directory entries across the filesystem that reference this inode. `1` means exactly one name. Deleting names decrements it; the inode is released at `0` (and only once no process holds it open).

### Exercise 2

**A2.1** — Neither. The concept does not exist. After `ln`, the two directory entries are peers — identical in every way, indistinguishable at the filesystem level. There is no "original" and no "the link"; there is one inode with two names. This is the single most important difference from a symlink, where the asymmetry is real and permanent.

**A2.2** — Because permissions are stored in the inode, and both names reference the same inode. `chmod` operates on the inode reached through whichever path you named. There is no per-name mode.

**A2.3** — Inode numbers are unique **only within a filesystem**. `find / -inum 1442653` will match unrelated inodes on every other mounted filesystem that happens to reuse that number. `-samefile` compares the `(st_dev, st_ino)` pair, which is the actually-unique identity of a file. Use `-samefile`, and add `-xdev` when you know the target's filesystem.

**A2.4** — Only if the destination is on the **same filesystem** (`findmnt` to confirm), and only if directory permissions along the colleague's path let them traverse to the new name. Note two consequences: (a) your colleague's copy has the same inode, so its permissions and ownership are yours and cannot diverge; (b) if you later `rm` your name, theirs keeps the 40 GB alive — the space is not reclaimed. For cross-user sharing a symlink plus a group-readable directory is usually the better tool; a hard link is right for deduplication *within* one administrative domain (snapshots, package stores).

### Exercise 3

**A3.1** — Deleted-but-open files: a process (typically a logger or an application whose log was rotated by `rm` or `mv` without a `SIGHUP`/reopen) still holds a descriptor on an unlinked inode. `du` walks names and cannot see it; `df` reports allocated blocks and does. Prove it with:

```bash
sudo lsof +L1
```

`NLINK` of `0` in that output is the smoking gun. Fix it by making the process reopen (`systemctl reload`, `kill -HUP`, or restart) — not by deleting more files.

**A3.2** — `parent` in its own parent directory, and `parent/.` — the entry every directory contains that points to itself.

**A3.3** — From `parent/child-a/..` and `parent/child-b/..`. Every subdirectory's `..` entry is an additional hard link to its parent. Hence the formula: **a directory's link count = 2 + number of immediate subdirectories**, which is a quick way to count subdirectories without listing them (`stat -c %h dir`) — and one reason `find` can skip `stat`ing entries in some optimisations.

**A3.4** — `> file` **truncates** the existing inode: it keeps the same inode and the same open descriptors valid, and releases the data blocks immediately. `rm file` only unlinks the name; the writer still holds the inode open and keeps appending into an unreachable file. This is exactly why `logrotate` uses `copytruncate` when it cannot signal the daemon, and why the correct rotation sequence is `mv` + signal-to-reopen (the daemon reopens by *name*, releasing the old inode).

### Exercise 4

**A4.1** — Because the symlink's "file contents" *are* the target path string. `ls -l` reports the size of the symlink itself, which is `strlen(target)` with no terminating NUL. `stat -L` would report the target's 55 bytes.

**A4.2** — `ls -l /etc/localtime`, or precisely `stat /etc/localtime` (which does **not** dereference by default), or scriptably `test -L /etc/localtime`. `stat -L` and `readlink -f` would follow it, which is the opposite of what you asked for.

**A4.3** — (1) The **permissions of the target file**, and (2) the **execute/search permission on every directory** traversed in resolving the target path. The `lrwxrwxrwx` mode bits on the symlink inode are ignored by Linux entirely; that is why `chmod` returns `EOPNOTSUPP` on a symlink. (Some other Unixes do honour symlink permissions — do not build portable logic on it.)

**A4.4** —
- `readlink -f` — canonicalise every component, following all symlinks; the **last** component may not exist.
- `readlink -e` — same, but **every** component must exist; exits non-zero otherwise. Use this in scripts when you require the file to be there.
- `readlink -m` — same, but **no** component needs to exist; never fails on absence. Use it when computing a path you are about to create.

**A4.5** — Without `-h`, `chown -R` follows the symlink and recursively rechowns **`/var/tmp` and everything in it** to `appuser` — a system-wide breakage affecting every service that uses `/var/tmp`. `chown -R -h` (or better, `chown -R --no-dereference`) changes the symlink's own ownership and never traverses into it. GNU `chown -R` additionally offers `-P` (default: do not traverse symlinks), `-H`, and `-L`; the safe default is `-P`/`-h`.

### Exercise 5

**A5.1** — A relative symlink is resolved **against the directory containing the symlink**, not against the process's current working directory and not against the target's location. So `tree/links/rel.txt -> ../data/file.txt` means "`tree/links/../data/file.txt`", i.e. `tree/data/file.txt`, no matter where you `cd` to before reading it.

**A5.2** — **Relative.** An absolute symlink bakes in the build-time prefix and points outside the staging root, so it breaks in a `DESTDIR` staging tree, in a container image, in a chroot, and in any relocated install. A relative link inside the package stays internally consistent wherever the tree is mounted. This is why `/etc/localtime` and most distribution-shipped links are relative. Absolute links are correct when the target genuinely is a fixed, system-wide location that must be followed regardless of where the link lives.

**A5.3** — `ln` dereferences the link name by default. `current` was an existing symlink to a directory, so `ln` resolved it to `v1/` and applied the standard "`ln TARGET DIRECTORY`" rule: create a link inside that directory named after the target's basename. Result: `v1/v2 -> v2`. `-f` only forced overwriting a pre-existing `v1/v2`; it never touched `current`.

**A5.4** — `-n` / `--no-dereference` tells `ln` to treat the link name as an ordinary file even if it is a symlink to a directory — so `-f` will replace *the symlink itself* instead of following it. In practice, always write `ln -sfn` for directory symlinks; the habit costs nothing on non-directory targets.

**A5.5** — `ln -sfn` is implemented as `unlink("current")` followed by `symlink("v2", "current")`. Between those two syscalls the name **does not exist**: any process resolving `/opt/app/current/...` in that window gets `ENOENT`. Under load that is a burst of 500s. Close it with a single atomic `rename(2)`:

```bash
ln -s v3 current.tmp && mv -T current.tmp current
```

`rename(2)` replaces the destination entry atomically — readers see either the old link or the new one, never nothing.

### Exercise 6

**A6.1** — A directory entry stores an **inode number**, and inode numbers are namespaced per filesystem — inode 1442653 on `/home` and inode 1442653 on `/var` are unrelated files. A directory entry therefore has no way to *express* "the file on that other filesystem"; there is no field for a device identifier. It is not a policy, it is the absence of a representable value. A symlink sidesteps this by storing a path string, which the kernel re-resolves from the root of the namespace on every access — crossing mounts freely.

**A6.2** — Any two of:
- **Unbreakable cycles.** `ln /a /a/b` would make a directory graph with a loop that has no entry point of link count 1, so a garbage-collecting `unlink` can never reclaim it and `fsck` cannot decide what is orphaned. The tree becomes a general cyclic graph.
- **`..` becomes ambiguous.** A directory has exactly one `..` entry; with two parents, path resolution upward is undefined.
- **Traversal never terminates.** `find`, `du`, `tar`, and every recursive tool would loop forever or need cycle detection, since they rely on the tree being acyclic.

**A6.3** — `[ -L path ]` is true for a symlink regardless of whether it resolves. `[ -e path ]` follows the link and is true only if the target exists. A broken symlink is therefore:

```bash
if [ -L "$p" ] && [ ! -e "$p" ]; then echo "broken symlink: $p"; fi
```

**A6.4** — `-type l` matches **every** symlink. `-xtype l` checks the type of the file the link *points to*; if the link is broken there is nothing to check, so `find` falls back to reporting the link itself as type `l`. Net effect on symlinks: `-xtype l` matches exactly the **broken** ones (and symlink chains that terminate in another symlink). That is the idiom for finding dangling links.

**A6.5** — `readlink -e /opt/app/current` — it exits non-zero and prints nothing when any component of the resolved path is missing, unlike `readlink -f` which happily prints a path to a nonexistent directory. `ls -l` is useless here because it never dereferences. `ls -L /opt/app/current` or `stat -L` would also expose it (`No such file or directory`). Broader sweep: `find /opt -xtype l`.

### Exercise 7

**A7.1** — Report **`du`'s 10 MB**: that is the number of blocks actually allocated on the device, which is what fills the filesystem. `ls -l` reports each inode's `st_size` per name; since both names share one inode it double-counts. Both exist because they answer different questions — "how big is this file" (`ls`) versus "how much storage does this tree consume" (`du`).

**A7.2** — Each invocation starts with an empty seen-set, so the inode is counted **once in each run** — 10 MB + 10 MB = 20 MB reported for 10 MB of real storage. To get the true figure, pass both directories to one invocation: `du -sh --total dir-a dir-b`, or `du -shc dir-a dir-b`. This is a routine source of confusion in hard-linked backup rotations, where per-snapshot `du` sums to enormously more than the pool's real size.

**A7.3** — **Inode exhaustion.** `df -h` measures data blocks; `df -i` measures inodes, which are allocated at `mkfs` time on ext2/3/4 and are a separate, fixed pool:

```bash
df -i /path
```

`IUse% 100%` with free blocks is the signature. Typical cause: millions of tiny files (mail spools, session files, cache directories). ext4 cannot grow the inode table after the fact — you either delete files or reformat with `mkfs.ext4 -i` / `-N`. XFS and Btrfs allocate inodes dynamically and do not have this failure mode.

**A7.4** —

```bash
find /etc -type l -printf '%p -> %l\n'
```

`%l` is `find`'s "object of a symbolic link" format specifier. Add `-xtype l` to narrow it to the broken ones — a genuinely useful `/etc` health check after a package removal.

**A7.5** — Without `-xdev`, `find /` descends into every mounted filesystem: network mounts (NFS/CIFS, which can hang or be enormous), `/proc` and `/sys` (synthetic, with meaningless inode semantics), bind mounts (which report the *same* device and inode, producing duplicate hits for one file), and container overlay mounts. `-xdev` confines the search to the filesystem you started on — which is also the only one that could hold a hard link to your target anyway.

### Exercise 8

**A8.1** — Any three of:
- `cp -r` **dereferences symlinks**, replacing each with a full copy of its target — inflating size and possibly copying data from outside the source tree. `cp -a` preserves them as symlinks (via `-d`).
- `cp -r` **breaks hard links**: two names sharing an inode become two independent files, doubling storage. `cp -a` preserves the sharing (`--preserve=links`).
- `cp -r` **does not preserve** ownership, permissions, timestamps, ACLs, xattrs or SELinux context. `cp -a` implies `--preserve=all`.
- With a symlink loop or a symlink pointing back up the tree, `cp -r` can recurse pathologically or fail; `cp -a` just copies the link.

For backups, `cp -a` (or `rsync -aHAX`) is the only defensible choice.

**A8.2** — `-H` / `--hard-links`. It is excluded from `-a` because preserving hard links requires rsync to build an in-memory map of every multiply-linked inode in the transfer, which costs significant memory and CPU on large trees, and because the common case (most files have one link) gains nothing. `-a` is `-rlptgoD`: recursive, links (symlinks), perms, times, group, owner, devices/specials — but not `-H`, not `-A` (ACLs), not `-X` (xattrs). The full-fidelity backup invocation is `rsync -aHAX --numeric-ids`.

**A8.3** — `-h` (`--dereference`). It replaced every symlink with a copy of the file it pointed to. In a web root full of symlinks into a shared assets directory — or, worse, a symlink to `/` or to a large mount — this multiplies the archive size or makes it unbounded. Remove `-h`; `tar` preserves symlinks and hard links (as `hrw-...` "link to" entries) by default.

**A8.4** — `cp` opens the destination with `O_TRUNC` and writes into the **existing inode**, which is the same inode the snapshot links to. Yesterday's snapshot therefore now contains today's content — the backup is silently corrupted, and the whole point of the rotation is defeated. The administrator should have used:

```bash
cp --remove-destination new.conf /srv/app/app.conf
```

which unlinks the destination name first, dropping the link count and leaving the snapshot's inode untouched, then creates a fresh file. `install -m`, `mv`, and any rename-based editor (`sed -i`, `vim` with default `backupcopy`) are also safe for the same reason. This asymmetry — `cp` writes through, `mv`/`sed -i` replace — is the number-one operational hazard of hard-linked snapshot backups.

**A8.5** — `sed -i` does not edit in place despite the name: it writes the result to a temporary file in the same directory and then `rename(2)`s it over the target name. `rename` replaces the *directory entry*, so that name now points to a brand-new inode while every other name still points to the old one — the link is broken and the contents diverge. `>>` (and `>`) call `open(2)` on the existing path and write into the **same inode**, so every name observes the change and the link count is unaffected.

**A8.6** — `backupcopy`. Set `:set backupcopy=yes` (or add `set backupcopy=yes` to your `vimrc`), which makes `vim` copy the original to the backup file and then **write into the original inode**, preserving hard links, ownership, ACLs and SELinux context. The default `auto` prefers the faster rename strategy, which breaks links. `vim` already forces `yes` behaviour in some cases (e.g. when the file has multiple links and `backupcopy=auto` detects it), but do not rely on the heuristic on files under `/etc`.

### Exercise 9

**A9.1** — `mv -T` on the same filesystem is a single `rename(2)` syscall, which the kernel performs atomically with respect to other path lookups: any process resolving `current` observes either the complete old entry or the complete new one. `ln -sfn` is two syscalls — `unlink("current")` then `symlink("v2","current")` — and a request arriving between them resolves `current` to nothing and gets **`ENOENT`** (a 404/500 from the web server, or a failed `open` in the application). Under a few thousand requests per second that window is not theoretical.

**A9.2** — `-T` / `--no-target-directory` forces `mv` to treat `current` as the literal destination name. Without it, `mv` sees that `current` is a symlink to a directory, follows it, and moves `current.tmp` *into* `v2/`, producing `v2/current.tmp` and leaving `current` still pointing at the old release — a silent no-op that looks like a successful deploy.

**A9.3** —
- A **running binary** resolves `libz.so.1` — the **SONAME**, which `ld` recorded in the executable's `DT_NEEDED` entry at build time and `ld.so` looks up at exec time. The major-version link is the ABI-compatibility contract.
- The **compiler/linker** at build time uses `libz.so`, the unversioned *linker name*, resolved from `-lz`. It exists only in `-devel`/`-dev` packages.
- **`ldconfig`** creates and maintains the `libz.so.1 -> libz.so.1.3.1` link (and the `/etc/ld.so.cache` index) by reading each library's embedded SONAME. This is why `ldconfig` must run after installing a library into a directory in `/etc/ld.so.conf.d/`.

**A9.4** — So it resolves correctly relative to whatever root it finds itself under. `../usr/share/zoneinfo/...` from `/etc/` means "`/usr/share/zoneinfo/...` *of this root*". Inside a chroot, a container image, a mounted rescue filesystem at `/mnt/sysroot`, or an OSTree/image-based deployment, an absolute `/usr/share/zoneinfo/...` would silently resolve to the **host's** tzdata (or to nothing). The relative form keeps the link internally consistent with the tree it ships in.

**A9.5** — Check:
1. `/etc/systemd/system/*.target.wants/` — `systemctl disable` removes symlinks here, but only those created by `enable` from the unit's `[Install]` section. A hand-created symlink, or one under a different target than the one `[Install]` names, is left behind.
2. `/etc/systemd/system/` itself and `/run/systemd/system/` — a **drop-in override** or a full unit copy can add `WantedBy`/`Requires`, and another unit's `Wants=`/`Requires=` can pull the service in regardless of its own enablement.

Authoritative check: `systemctl list-unit-files <name>`, `systemctl show -p WantedBy -p RequiredBy <name>`, and `systemctl list-dependencies --reverse <name>`. If it must never start, `systemctl mask` it.

**A9.6** — Masking creates a symlink from the unit name in `/etc/systemd/system/` (higher precedence than `/usr/lib/systemd/system/`) to **`/dev/null`**. systemd treats a unit whose path resolves to `/dev/null` as non-existent and unloadable. It is stronger than `disable` because `disable` only removes the `.wants/` symlinks that cause *automatic* activation at boot — the unit can still be started manually or pulled in as a dependency of another unit. A masked unit cannot be started at all: `systemctl start` on it fails with `Unit is masked`.

### Exercise 10

**A10.1** — Because a hard link is a **permanent, unrevokable reference to the inode** that survives the owner's `rm`. Two concrete attacks it enables:
1. **Content retention.** An attacker hard-links a file that is about to be rotated, deleted or have its permissions tightened (a temporary file that briefly contains a token, a key being regenerated). Deleting the original does not free the inode; the attacker keeps the snapshot forever, and later permission changes on the *inode* do not remove their existing link.
2. **Confused-deputy writes.** A setuid or root process that writes to an attacker-chosen path in a shared directory, or that "safely" `chown`s/`chmod`s a file it believes it created, can be pointed at a link to a sensitive inode — quota-bypass and TOCTOU variants included. `fs.protected_hardlinks=1` requires that the linker either own the source inode or have read **and** write access to it, which removes the whole class.

**A10.2** — The directory must be **world-writable and sticky** (`drwxrwxrwt`, mode `1777`) — the classic `/tmp`, `/var/tmp`, `/dev/shm` shape. The restriction then blocks *following* a symlink in that directory when the symlink's owner is neither the following process's UID nor the directory's owner. Outside sticky world-writable directories the protection does not apply, because there the directory permissions already establish who could have planted the link.

**A10.3** — Creating a symlink stores a **path string** and grants no rights whatsoever; the kernel enforces `/etc/shadow`'s `0640 root:shadow` at every `open()` through it, exactly as it would for the direct path. `cat /tmp/mysym` returns `Permission denied` for an unprivileged user. The vulnerability only materialises when a **privileged** process follows the attacker's link and does something with the target it would not have done to `/etc/shadow` directly — write, truncate, `chown`, `chmod`. The link is bait; the privilege belongs to the victim process.

**A10.4** — **Attack:** the user makes `$userpath` a symlink to `/etc/shadow` (or `/root/.ssh/id_ed25519`). The root script follows it and copies the contents into `/backup/out`, which the user can then read — or, in the write direction (`cat something > "$userpath"`), the root process truncates and overwrites an arbitrary system file. `fs.protected_symlinks` does **not** save you here: it only covers sticky world-writable directories, and the user's own home directory is not one.

**Mitigations**, best first:
- Do not run the traversal as root. Drop to the file's owner (`setpriv --reuid`, `runuser -u`) so the kernel's own permission checks apply.
- Refuse to follow: `open(..., O_NOFOLLOW)` in code; in shell, verify with `[ -L "$p" ] && exit 1`, or canonicalise with `readlink -e` and assert the result stays inside the permitted prefix (as in step 6 of the exercise).
- For whole-tree work, use tools that do not dereference by default: `tar` without `-h`, `cp -P`/`-a`, `rsync -l`, `find -P` (the default), `chown -h`.
- Under a modern kernel, `openat2(2)` with `RESOLVE_NO_SYMLINKS`/`RESOLVE_BENEATH` enforces the containment in the kernel rather than in a check-then-use race.

</details>

---

## Sources

- LPI — Exam 101 Objectives (LPIC-1 v5.0), objective 104.6: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Coreutils Manual — `ln` invocation: <https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html>
- GNU Coreutils Manual — `cp` invocation: <https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html>
- GNU Coreutils Manual — `readlink` invocation: <https://www.gnu.org/software/coreutils/manual/html_node/readlink-invocation.html>
- GNU Findutils Manual — tests and actions (`-samefile`, `-xtype`, `-links`, `-printf`): <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- `symlink(7)` — symbolic link handling: <https://man7.org/linux/man-pages/man7/symlink.7.html>
- `link(2)` — `EXDEV`, `EPERM` on directories: <https://man7.org/linux/man-pages/man2/link.2.html>
- `rename(2)` — atomicity guarantees: <https://man7.org/linux/man-pages/man2/rename.2.html>
- `open(2)` — `O_NOFOLLOW`, `O_TRUNC`: <https://man7.org/linux/man-pages/man2/open.2.html>
- `openat2(2)` — `RESOLVE_NO_SYMLINKS`, `RESOLVE_BENEATH`: <https://man7.org/linux/man-pages/man2/openat2.2.html>
- Linux kernel documentation — `fs.protected_symlinks` and `fs.protected_hardlinks`: <https://docs.kernel.org/admin-guide/sysctl/fs.html>
- Linux kernel documentation — ext4 on-disk format (fast symlinks, `EXT4_LINK_MAX`): <https://docs.kernel.org/filesystems/ext4/index.html>
- `systemd.unit(5)` — unit file load path, masking, `[Install]` symlinks: <https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html>
- `ldconfig(8)` and `ld.so(8)` — SONAME resolution and library link chains: <https://man7.org/linux/man-pages/man8/ldconfig.8.html>
- `rsync(1)` — `-a`, `-H`, `-l` semantics: <https://download.samba.org/pub/rsync/rsync.1>
- GNU Tar Manual — `--dereference` and hard-link handling: <https://www.gnu.org/software/tar/manual/html_node/dereference.html>