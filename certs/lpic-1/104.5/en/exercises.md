# LPIC-1 · Exam 101-500 · Topic 104.5 — Manage file permissions and ownership

**Exam weight:** 4.69 · **Key terms:** `chmod`, `umask`, `chown`, `chgrp`, SUID, SGID, sticky bit

These are **hands-on guided exercises**. Every step is meant to be executed on a throw-away Linux system (VM, container, or a spare box) where you have `root` via `sudo`. Outputs shown are real-shape outputs; numeric UIDs/GIDs, inode numbers, device numbers and timestamps will differ on your machine.

> **Destructive-command warning:** everything below is confined to `/srv/lab`, `/srv/projects` and `/tmp`. Never run the recursive `chmod`/`chown` steps outside those paths.

---

## Exercise 0 — Build the lab environment

1. Become root for the setup and create two unprivileged users and two groups:

```bash
sudo groupadd devs
sudo groupadd ops
sudo useradd -m -s /bin/bash alice
sudo useradd -m -s /bin/bash bob
sudo usermod -aG devs alice
sudo usermod -aG devs bob
sudo usermod -aG ops  bob
```

2. Create the playground directories:

```bash
sudo mkdir -p /srv/lab /srv/projects
sudo chmod 0777 /srv/lab          # deliberately wide open for now
```

3. Verify identities and group memberships:

```bash
id alice
id bob
```

Expected output (numbers will differ):

```
uid=1001(alice) gid=1001(alice) groups=1001(alice),2001(devs)
uid=1002(bob) gid=1002(bob) groups=1002(bob),2001(devs),2002(ops)
```

4. Confirm you can run commands as those users:

```bash
sudo -u alice id -un
sudo -u bob   id -un
```

> **Operational note:** always launch the user shells from a directory those users can traverse (e.g. `cd /srv/lab` first). Running `sudo -u alice ...` from a directory `alice` cannot enter produces `shell-init: error retrieving current directory`, which is itself a permission symptom, not a `sudo` bug.

### Checkpoint questions — block 0

- **Q0.1** In `id bob`, what is the difference between the value shown in `gid=` and the values shown in `groups=`?
- **Q0.2** `bob` was added to `ops` while he already had a login shell open. Does that shell gain access to `ops`-owned files? Why?
- **Q0.3** Which single file would you inspect to confirm that `devs` really contains both users, and which field of that file holds them?

---

## Exercise 1 — Read the mode string precisely

1. Create test objects of several types as your normal user:

```bash
cd /srv/lab
touch report.txt
mkdir archive
ln -s report.txt report.lnk
mkfifo pipe.fifo
```

2. List them:

```bash
ls -l
```

Expected output (abridged):

```
drwxr-xr-x. 2 student student 4096 Aug 26 10:14 archive
prw-r--r--. 1 student student    0 Aug 26 10:14 pipe.fifo
lrwxrwxrwx. 1 student student   10 Aug 26 10:14 report.lnk -> report.txt
-rw-r--r--. 1 student student    0 Aug 26 10:14 report.txt
```

3. Decompose one entry field by field with `stat`, which prints both notations at once:

```bash
stat -c '%A  %a  %U(%u)  %G(%g)  %F  %n' report.txt archive report.lnk pipe.fifo
```

Expected output:

```
-rw-r--r--  644  student(1000)  student(1000)  regular empty file  report.txt
drwxr-xr-x  755  student(1000)  student(1000)  directory  archive
lrwxrwxrwx  777  student(1000)  student(1000)  symbolic link  report.lnk
prw-r--r--  644  student(1000)  student(1000)  fifo  pipe.fifo
```

4. Look at the character immediately **after** the 10-character mode string (the `.` above):

```bash
ls -l /etc/passwd /etc/shadow
getfacl -p report.txt 2>/dev/null | head -n 5
```

- `.` → an SELinux (or other MAC) security context is attached, no ACL.
- `+` → an **ACL** or other alternate access method is present; the mode string alone no longer tells the whole story.
- ` ` (nothing) → neither.

5. Prove that the permissions of a symlink itself are meaningless on Linux:

```bash
chmod 000 report.lnk
ls -l report.lnk report.txt
```

Expected output:

```
lrwxrwxrwx. 1 student student  10 Aug 26 10:14 report.lnk -> report.txt
----------. 1 student student   0 Aug 26 10:14 report.txt
```

6. Restore the file and inspect the raw type bits:

```bash
chmod 644 report.txt
stat -c '%f (hex mode incl. file type)  %a (permission bits only)' report.txt
```

Expected output:

```
81a4 (hex mode incl. file type)  644 (permission bits only)
```

### Checkpoint questions — block 1

- **Q1.1** In `drwxr-xr-x`, which character is *not* a permission bit, and what does it encode?
- **Q1.2** `report.lnk` shows `lrwxrwxrwx`, yet `chmod 000 report.lnk` changed `report.txt`. Explain both facts.
- **Q1.3** Translate `-rwsr-x---` to octal (four digits) and `2750` to a directory mode string.
- **Q1.4** You see `-rw-rw-r--+ 1 root www-data ... config.ini` and a user who is neither `root` nor in `www-data` can write to it. What is the most likely explanation, and which command confirms it?
- **Q1.5** `stat -c %f` returned `81a4`. Decompose it: which part is the file type and which part is the mode?

---

## Exercise 2 — `chmod`: octal and symbolic notation

1. Work on a fresh file:

```bash
cd /srv/lab
printf '#!/bin/sh\necho hello\n' > hello.sh
ls -l hello.sh
```

Expected: `-rw-r--r--`.

2. Octal form — set exactly, in one shot:

```bash
chmod 750 hello.sh && stat -c '%A %a' hello.sh
chmod 0640 hello.sh && stat -c '%A %a' hello.sh
```

Expected:

```
-rwxr-x--- 750
-rw-r----- 640
```

3. Symbolic form — the three parts are **who** (`u g o a`), **operator** (`+ - =`), **what** (`r w x X s t`):

```bash
chmod u+x hello.sh          && stat -c '%A' hello.sh
chmod g=rx,o= hello.sh      && stat -c '%A' hello.sh
chmod a-x hello.sh          && stat -c '%A' hello.sh
chmod u=rw,g=r,o=r hello.sh && stat -c '%A' hello.sh
```

Expected, in order:

```
-rwxr-----
-rwxr-x---
-rw-r-----
-rw-r--r--
```

4. Understand `=` versus `+`/`-`: `=` **replaces** the whole triad, the others are additive/subtractive.

```bash
chmod 777 hello.sh
chmod g= hello.sh
stat -c '%A %a' hello.sh
```

Expected:

```
-rwx---rwx 707
```

5. The capital `X` — "execute only where it already makes sense". This is the correct recursive idiom:

```bash
mkdir -p tree/sub && touch tree/sub/data.txt tree/sub/run.sh
chmod 700 tree/sub/run.sh
chmod -R a=rX,u+w tree
find tree -printf '%m %y %p\n'
```

Expected:

```
755 d tree
755 d tree/sub
644 f tree/sub/data.txt
755 f tree/sub/run.sh
```

Compare with the wrong idiom (do not leave it applied):

```bash
chmod -R a+x tree
find tree -printf '%m %y %p\n'
chmod -R a=rX,u+w tree     # undo
```

6. Copy a mode from another file instead of retyping it:

```bash
chmod --reference=/etc/hostname hello.sh
stat -c '%A %a' hello.sh /etc/hostname
```

7. Note what `chmod` does with symlinks during recursion:

```bash
ln -s /etc/shadow tree/danger.lnk
chmod -R 777 tree
ls -l /etc/shadow tree/danger.lnk
```

`/etc/shadow` is untouched: `chmod` does not follow symlinks it *encounters while recursing* (there is no `lchmod()` on Linux), but it *does* dereference a symlink named directly on the command line, as you proved in Exercise 1 step 5.

```bash
rm tree/danger.lnk
chmod -R a=rX,u+w tree
```

### Checkpoint questions — block 2

- **Q2.1** Why did step 4 leave `o=rwx` intact while wiping the group triad?
- **Q2.2** What exactly is the difference between `chmod -R a+x dir` and `chmod -R a+X dir`, and why is the second one the safe one?
- **Q2.3** Write, in a single `chmod` invocation, "owner read/write, group read only, others nothing" — first in octal, then symbolically.
- **Q2.4** `chmod 755 file` and `chmod 0755 file` — is there ever a difference? (Think about the object type.)
- **Q2.5** A colleague runs `chmod -R 777 /srv/app` to "fix" a deploy. Give two concrete security consequences and one functional one.

---

## Exercise 3 — Which triad applies to *me*?

The kernel checks in strict order: **owner → group → other**, and it stops at the **first match**. It does not accumulate.

1. Create the counter-intuitive case:

```bash
cd /srv/lab
sudo -u alice touch odd.txt
sudo chgrp devs odd.txt
sudo chmod 0077 odd.txt
ls -l odd.txt
```

Expected output:

```
----rwxrwx. 1 alice devs 0 Aug 26 10:20 odd.txt
```

2. `alice` is the owner **and** a member of `devs`. Try to read as `alice`:

```bash
sudo -u alice cat /srv/lab/odd.txt; echo "exit=$?"
```

Expected:

```
cat: /srv/lab/odd.txt: Permission denied
exit=1
```

3. Now as `bob`, who is in `devs` but is *not* the owner:

```bash
sudo -u bob cat /srv/lab/odd.txt; echo "exit=$?"
```

Expected:

```
exit=0
```

4. Test access without reading the content, the scriptable way:

```bash
sudo -u alice test -r /srv/lab/odd.txt; echo "alice can read: $?"
sudo -u bob   test -r /srv/lab/odd.txt; echo "bob   can read: $?"
```

Expected: `alice can read: 1`, `bob can read: 0` (0 = true).

5. Confirm that ownership still lets `alice` fix it — the *metadata* is hers:

```bash
sudo -u alice chmod 640 /srv/lab/odd.txt
ls -l odd.txt
```

Expected: `-rw-r-----. 1 alice devs`.

### Checkpoint questions — block 3

- **Q3.1** State the access-check rule in one sentence that explains why `alice` was denied and `bob` allowed.
- **Q3.2** `alice` could not read the file but *could* `chmod` it. Which permission bit granted the `chmod`? (Careful — this is a trick.)
- **Q3.3** File `data.db` is `-rw-rw----  root  devs`. User `carol` is in `devs`. Can she read it? Now the file becomes `-rw-rw---- carol devs` and the mode becomes `----rw----`. Can she read it?
- **Q3.4** Why is `test -r` a better check inside a script than parsing `ls -l` output?

---

## Exercise 4 — Directory permissions: `r`, `w` and `x` mean something else

1. Build a directory with one file in it:

```bash
cd /srv/lab
sudo rm -rf dirlab && sudo mkdir dirlab
sudo sh -c 'echo "secret payload" > /srv/lab/dirlab/file.txt'
sudo chmod 644 /srv/lab/dirlab/file.txt
```

2. **Execute only (`--x`) — traversal without listing:**

```bash
sudo chmod 0711 /srv/lab/dirlab
sudo -u alice ls /srv/lab/dirlab            ; echo "ls   exit=$?"
sudo -u alice cat /srv/lab/dirlab/file.txt  ; echo "cat  exit=$?"
```

Expected:

```
ls: cannot open directory '/srv/lab/dirlab': Permission denied
ls   exit=2
secret payload
cat  exit=0
```

3. **Read only (`r--`) — names without traversal:**

```bash
sudo chmod 0744 /srv/lab/dirlab
sudo -u alice ls    /srv/lab/dirlab ; echo "ls    exit=$?"
sudo -u alice ls -l /srv/lab/dirlab ; echo "ls -l exit=$?"
sudo -u alice cat   /srv/lab/dirlab/file.txt ; echo "cat exit=$?"
```

Expected:

```
file.txt
ls    exit=0
ls: cannot access '/srv/lab/dirlab/file.txt': Permission denied
total 0
ls -l exit=1
cat: /srv/lab/dirlab/file.txt: Permission denied
cat exit=0 → 1
```

4. **Write + execute — the deletion rule.** Give `alice` write on the directory but keep the file read-only for her:

```bash
sudo chmod 0777 /srv/lab/dirlab
sudo chmod 0444 /srv/lab/dirlab/file.txt
sudo -u alice rm -f /srv/lab/dirlab/file.txt ; echo "rm exit=$?"
ls -l /srv/lab/dirlab
```

Expected: the file is **gone**, `rm exit=0` (interactive `rm` may prompt; `-f` suppresses it).

5. The reverse case — a writable file in a non-writable directory:

```bash
sudo sh -c 'echo again > /srv/lab/dirlab/file.txt'
sudo chmod 0666 /srv/lab/dirlab/file.txt
sudo chmod 0755 /srv/lab/dirlab
sudo -u alice sh -c 'echo appended >> /srv/lab/dirlab/file.txt' ; echo "write exit=$?"
sudo -u alice rm -f /srv/lab/dirlab/file.txt                    ; echo "rm    exit=$?"
```

Expected: the write succeeds (`exit=0`), the removal fails with `Permission denied` (`exit=1`).

### Checkpoint questions — block 4

- **Q4.1** For a directory, define `r`, `w` and `x` in one line each.
- **Q4.2** Why does `ls -l dir` fail while plain `ls dir` succeeds on a `r--` directory?
- **Q4.3** Which permission, on which object, decides whether a user may delete `file.txt`? Which permission on the *file* is irrelevant to that decision?
- **Q4.4** `/srv/data/reports/q3.csv` is `-rw-rw-rw-`, but a user gets `Permission denied` opening it. Name two distinct causes located outside the file itself.
- **Q4.5** What mode would you give a directory that must let a service *find* a known file inside it but never enumerate its contents?

---

## Exercise 5 — `umask`: the mask that shapes every new file

1. Read the current mask in both notations:

```bash
umask
umask -S
umask -p
```

Expected on most distributions:

```
0022
u=rwx,g=rx,o=rx
umask 0022
```

2. Observe the two base modes — **666 for files, 777 for directories**:

```bash
cd /srv/lab && mkdir -p umasklab && cd umasklab
umask 022
touch f022 ; mkdir d022
umask 027
touch f027 ; mkdir d027
umask 077
touch f077 ; mkdir d077
umask 002
touch f002 ; mkdir d002
find . -maxdepth 1 -mindepth 1 -printf '%m %y %p\n' | sort -k3
```

Expected:

```
660 f ./f002
775 d ./d002
644 f ./f022
755 d ./d022
640 f ./f027
750 d ./d027
600 f ./f077
700 d ./d077
```

3. Prove that `umask` is a **bitwise AND-NOT**, not a subtraction:

```bash
umask 123
touch f123 ; mkdir d123
stat -c '%a %n' f123 d123
```

Expected:

```
644 f123
654 d123
```

Subtraction would have predicted `543` and `654`. Verify the real arithmetic:

```
file: 666 = 110 110 110
umask 123 = 001 010 011   → ~umask = 110 101 100
AND                        = 110 100 100 = 644
```

4. Symbolic `umask` specifies the bits to **keep**, not the bits to remove:

```bash
umask u=rwx,g=rx,o=
umask          # numeric
touch fsym ; mkdir dsym
stat -c '%a %n' fsym dsym
```

Expected:

```
0027
640 fsym
750 dsym
```

5. `umask` is a per-process attribute inherited by children — it is a shell builtin, not a program:

```bash
type umask
umask 077
bash -c 'umask'            # child inherits
( umask 002; umask )       # subshell change is local
umask                      # parent unchanged
```

Expected: `umask is a shell builtin`, then `0077`, `0002`, `0077`.

6. Which tools honour the mask and which ignore it:

```bash
umask 077
printf 'payload\n' > src.txt ; chmod 644 src.txt
cp src.txt cp_default.txt
cp -p src.txt cp_preserve.txt
mv src.txt moved.txt
mkdir -m 755 dir_m
install -m 644 moved.txt installed.txt
mkfifo fifo_masked
ln -s moved.txt link_masked
stat -c '%a %N' cp_default.txt cp_preserve.txt moved.txt dir_m installed.txt fifo_masked link_masked
```

Expected:

```
600 'cp_default.txt'
644 'cp_preserve.txt'
644 'moved.txt'
755 'dir_m'
644 'installed.txt'
600 'fifo_masked'
777 'link_masked' -> 'moved.txt'
```

7. Restore a sane mask and find where it is set at login:

```bash
umask 022
grep -rn --include='*' -e '^\s*umask' -e '^UMASK' /etc/profile /etc/profile.d/ /etc/bashrc /etc/bash.bashrc /etc/login.defs ~/.bashrc ~/.profile 2>/dev/null
grep -rn 'pam_umask' /etc/pam.d/ 2>/dev/null
```

### Checkpoint questions — block 5

- **Q5.1** Why can a newly created regular file never have an execute bit, whatever the mask?
- **Q5.2** With `umask 027`, give the resulting mode of a new file and of a new directory.
- **Q5.3** You need new files to be group-writable and invisible to others. Which mask? Which mode does it yield for files and for directories?
- **Q5.4** Explain the `umask 123 → 644` result in terms of bit operations.
- **Q5.5** `cp src.txt dst.txt` produced a `600` destination from a `644` source. What happened, and which flag prevents it?
- **Q5.6** Why is `umask` a shell builtin rather than `/usr/bin/umask`?
- **Q5.7** A cron job creates files as `600` although your interactive `umask` is `002`. Give the likely reason and the robust fix inside the job.

---

## Exercise 6 — Ownership: `chown`, `chgrp` and the group field

1. Create a file and inspect the two ownership fields:

```bash
cd /srv/lab
sudo rm -rf ownlab && mkdir ownlab && cd ownlab
touch app.conf
stat -c '%U:%G %a %n' app.conf
```

2. Change group only — both forms are equivalent:

```bash
sudo chgrp devs app.conf
sudo chown :ops  app.conf
stat -c '%U:%G' app.conf
```

Expected: `student:ops`.

3. Change owner and group together, then verify with numeric IDs:

```bash
sudo chown alice:devs app.conf
stat -c '%U(%u):%G(%g)' app.conf
sudo chown 0:0 app.conf          # numeric IDs are accepted too
stat -c '%U:%G' app.conf
```

4. **Who may change what** — test the privilege boundary:

```bash
sudo chown alice:alice app.conf
sudo -u alice chown bob /srv/lab/ownlab/app.conf ; echo "give away: exit=$?"
sudo -u alice chgrp devs /srv/lab/ownlab/app.conf ; echo "chgrp devs: exit=$?"
sudo -u alice chgrp ops  /srv/lab/ownlab/app.conf ; echo "chgrp ops:  exit=$?"
```

Expected:

```
chown: changing ownership of '/srv/lab/ownlab/app.conf': Operation not permitted
give away: exit=1
chgrp devs: exit=0
chgrp ops:  exit=1        # chown: changing group ...: Operation not permitted
```

5. **The production trap: `chown` clears SUID/SGID on executables.**

```bash
sudo install -m 4755 -o root -g root /bin/true /srv/lab/ownlab/tool
stat -c '%A %a %U:%G' /srv/lab/ownlab/tool
sudo chown alice /srv/lab/ownlab/tool
stat -c '%A %a %U:%G' /srv/lab/ownlab/tool
```

Expected:

```
-rwsr-xr-x 4755 root:root
-rwxr-xr-x 755 alice:root
```

The special bit is gone. In a deploy script the order must therefore be **`chown` first, `chmod` last**.

6. Recursive ownership, and the `-h` / `--reference` options:

```bash
mkdir -p tree/sub && touch tree/sub/a && ln -s a tree/sub/a.lnk
sudo chown -R alice:devs tree
sudo chown -h bob tree/sub/a.lnk        # the link itself, not the target
ls -l tree/sub
sudo chown --reference=/etc/hostname tree/sub/a
stat -c '%U:%G %n' tree/sub/a /etc/hostname
```

7. Supplementary groups and the *effective* group used at creation time:

```bash
sudo -u bob sh -c 'cd /srv/lab/ownlab && id -gn && touch bob_default && ls -l bob_default'
sudo -u bob sh -c 'cd /srv/lab/ownlab && sg devs -c "touch bob_asdevs; ls -l bob_asdevs"'
```

Expected: `bob_default` is owned by `bob:bob`, `bob_asdevs` by `bob:devs`. `newgrp devs` does the same interactively by starting a new shell with `devs` as the primary group.

### Checkpoint questions — block 6

- **Q6.1** Why can `root` give a file away but the owner cannot?
- **Q6.2** Under what condition may a non-root owner run `chgrp` successfully?
- **Q6.3** After `sudo chown alice tool`, the mode dropped from `4755` to `755`. Explain why the kernel does this and what it protects against.
- **Q6.4** What is the difference between `chown -R` and `chown -h`, and when does `-h` matter?
- **Q6.5** `bob` belongs to `devs` but his new files are owned by group `bob`. Name two different ways to make his new files land in `devs` — one per-command, one structural.
- **Q6.6** Write a single command that makes every object under `/srv/app` owned by `www-data:www-data`.

---

## Exercise 7 — SGID on directories: the shared-project recipe

1. Build a team directory the naive way and watch it fail:

```bash
sudo rm -rf /srv/projects/apollo
sudo mkdir -p /srv/projects/apollo
sudo chown root:devs /srv/projects/apollo
sudo chmod 0770 /srv/projects/apollo
sudo -u alice sh -c 'cd /srv/projects/apollo && touch alice_note.txt'
ls -l /srv/projects/apollo
```

Expected:

```
-rw-r--r--. 1 alice alice 0 Aug 26 10:40 alice_note.txt
```

The file landed in group `alice`, not `devs`, so `bob` cannot write to it.

```bash
sudo -u bob sh -c 'echo hi >> /srv/projects/apollo/alice_note.txt' ; echo "bob write exit=$?"
```

Expected: `Permission denied`, `exit=1`.

2. Apply the **SGID bit** to the directory:

```bash
sudo chmod g+s /srv/projects/apollo
ls -ld /srv/projects/apollo
stat -c '%a %A' /srv/projects/apollo
```

Expected:

```
drwxrws---. 2 root devs 4096 Aug 26 10:40 /srv/projects/apollo
2770 drwxrws---
```

3. Verify group inheritance for new objects — and that it propagates to subdirectories:

```bash
sudo -u alice sh -c 'cd /srv/projects/apollo && touch alice_v2.txt && mkdir sub'
ls -l /srv/projects/apollo
ls -ld /srv/projects/apollo/sub
```

Expected:

```
-rw-r--r--. 1 alice devs 0 ... alice_v2.txt
drwxr-sr-x. 2 alice devs 4096 ... sub
```

The **group** is inherited, and the subdirectory also inherited the **SGID bit itself** (`s` in the group field).

4. The mode is still wrong for collaboration — `644` gives the group no write bit. Fix the mask *for the writing process*:

```bash
sudo -u alice sh -c 'cd /srv/projects/apollo && umask 007 && touch alice_v3.txt && mkdir sub2'
stat -c '%a %U:%G %n' /srv/projects/apollo/alice_v3.txt /srv/projects/apollo/sub2
sudo -u bob sh -c 'echo "bob was here" >> /srv/projects/apollo/alice_v3.txt' ; echo "bob write exit=$?"
```

Expected:

```
660 alice:devs /srv/projects/apollo/alice_v3.txt
2770 alice:devs /srv/projects/apollo/sub2
bob write exit=0
```

**SGID fixes the group; only the umask fixes the mode. You need both.**

5. Repair the pre-existing files in one pass:

```bash
sudo chgrp -R devs /srv/projects/apollo
sudo chmod -R g+w  /srv/projects/apollo
sudo find /srv/projects/apollo -type d -exec chmod g+s {} +
find /srv/projects/apollo -printf '%m %y %u:%g %p\n'
```

6. **GNU `chmod` gotcha** — numeric modes and directories:

```bash
sudo chmod 770 /srv/projects/apollo
stat -c '%a' /srv/projects/apollo
sudo chmod 0770 /srv/projects/apollo
stat -c '%a' /srv/projects/apollo
sudo chmod 2770 /srv/projects/apollo
stat -c '%a' /srv/projects/apollo
```

Expected:

```
2770
770
2770
```

GNU `chmod` **preserves** a directory's SUID/SGID bits when you give a three-digit mode. Always write four digits in scripts — the three-digit form is not portable and has surprised many operators on both sides.

7. Note the other meaning of SGID, on *executables*:

```bash
ls -l /usr/bin/write /usr/bin/wall 2>/dev/null
```

Expected (varies per distro):

```
-rwxr-sr-x. 1 root tty 23000 ... /usr/bin/write
```

Here SGID means "run with the effective group `tty`", the group-side counterpart of SUID.

### Checkpoint questions — block 7

- **Q7.1** SGID has two completely different meanings. State both, and say which object type triggers which.
- **Q7.2** After `chmod g+s` the new files were `alice:devs 644`. Why is that still unusable for the team, and what fixes it?
- **Q7.3** What is the four-digit mode of a shared directory that is group-writable, SGID, and closed to others?
- **Q7.4** Your teammate ran `chmod 2770` on the parent only, but files created in a subdirectory created *before* that still land in the wrong group. Why, and what is the repair command?
- **Q7.5** Why did `chmod 770 dir` leave the SGID bit alive while `chmod 0770 dir` removed it?
- **Q7.6** Instead of relying on every user's `umask`, what mechanism (outside the 104.5 objective) would enforce group-writable defaults per directory?

---

## Exercise 8 — SUID: what it does, and what Linux refuses to do with it

1. Find real SUID binaries on the system and read their modes:

```bash
ls -l /usr/bin/passwd /usr/bin/su /usr/bin/sudo /usr/bin/mount 2>/dev/null
```

Expected (distro-dependent):

```
-rwsr-xr-x. 1 root root 32656 ... /usr/bin/passwd
-rwsr-xr-x. 1 root root 48944 ... /usr/bin/su
---s--x--x. 1 root root 182600 ... /usr/bin/sudo
-rwsr-xr-x. 1 root root 55696 ... /usr/bin/mount
```

2. Reason about *why*: `/etc/shadow` is `-rw-r-----  root shadow` (or `0000 root root`), yet an unprivileged user changes their own password.

```bash
ls -l /etc/shadow
sudo -u alice sh -c 'cat /etc/shadow' ; echo "direct read exit=$?"
```

Expected: `Permission denied`, `exit=1`. `passwd` succeeds only because SUID makes its **effective UID** `root`.

3. Distinguish lowercase `s` from uppercase `S`:

```bash
cd /srv/lab && sudo rm -rf suidlab && mkdir suidlab && cd suidlab
sudo install -m 0755 -o root /bin/true t1
sudo chmod u+s t1 ; stat -c '%A %a %n' t1
sudo chmod u-x t1 ; stat -c '%A %a %n' t1
sudo chmod u+x t1 ; stat -c '%A %a %n' t1
```

Expected:

```
-rwsr-xr-x 4755 t1
-rwSr-xr-x 4655 t1
-rwsr-xr-x 4755 t1
```

Uppercase `S` = the special bit is set but the corresponding **execute bit is not** — almost always a mistake on an executable.

4. **Prove that Linux ignores SUID on interpreted scripts:**

```bash
cat > whoami.sh <<'EOF'
#!/bin/sh
echo "real uid=$(id -ru)  effective uid=$(id -u)  user=$(id -un)"
EOF
sudo chown root:root whoami.sh
sudo chmod 4755 whoami.sh
ls -l whoami.sh
sudo -u alice /srv/lab/suidlab/whoami.sh
```

Expected:

```
-rwsr-xr-x. 1 root root 78 Aug 26 10:55 whoami.sh
real uid=1001  effective uid=1001  user=alice
```

The bit is set, the mode string shows `s`, and it does **nothing**. The Linux kernel refuses to honour set-user-ID on `#!` scripts (a deliberate defence against a class of race and argument-injection attacks).

5. *(Optional, requires a C compiler)* — the same test with a real binary:

```bash
cat > euid.c <<'EOF'
#include <stdio.h>
#include <unistd.h>
int main(void) {
    printf("real uid=%d  effective uid=%d\n", (int)getuid(), (int)geteuid());
    return 0;
}
EOF
cc -o euid euid.c && sudo chown root:root euid && sudo chmod 4755 euid
sudo -u alice /srv/lab/suidlab/euid
```

Expected:

```
real uid=1001  effective uid=0
```

6. Audit the whole filesystem for SUID/SGID binaries — a standard hardening task:

```bash
sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%m %u %g %p\n' 2>/dev/null | sort
```

Expected shape:

```
2755 root tty   /usr/bin/write
4755 root root  /usr/bin/mount
4755 root root  /usr/bin/passwd
4755 root root  /usr/bin/su
```

7. Clean up your own SUID artefacts immediately — never leave one behind:

```bash
sudo chmod -R a-s /srv/lab/suidlab
find /srv/lab/suidlab -printf '%m %p\n'
```

### Checkpoint questions — block 8

- **Q8.1** Precisely: which UID does SUID change — real, effective, or both?
- **Q8.2** `-rwSr--r--` vs `-rwsr-xr-x`: what is the difference and which one is a configuration bug?
- **Q8.3** Your `backup.sh` is `4755 root:root` but still cannot read `/etc/shadow`. Explain, and give one legitimate alternative to grant the privilege.
- **Q8.4** Give the octal for: SUID + `rwx` owner + `r-x` group + `---` others. And for SGID + `rwx` owner + `r-x` group + `r-x` others.
- **Q8.5** Write the `find` command that lists SUID files only, and explain why `-perm -4000` is not the same as `-perm 4000`.
- **Q8.6** Why is an unnecessary SUID binary owned by `root` considered a privilege-escalation risk even when it "does something harmless"?

---

## Exercise 9 — The sticky bit: shared write, private delete

1. Look at the canonical example:

```bash
ls -ld /tmp /var/tmp
stat -c '%a %A %U:%G %n' /tmp
```

Expected:

```
drwxrwxrwt. 18 root root 4096 Aug 26 10:58 /tmp
1777 drwxrwxrwt root:root /tmp
```

2. Reproduce the problem the bit solves. First, a world-writable directory **without** it:

```bash
sudo rm -rf /srv/lab/dropbox && sudo mkdir /srv/lab/dropbox
sudo chmod 0777 /srv/lab/dropbox
sudo -u alice sh -c 'cd /srv/lab/dropbox && echo "alice data" > alice.txt && chmod 600 alice.txt'
ls -l /srv/lab/dropbox
sudo -u bob rm -f /srv/lab/dropbox/alice.txt ; echo "bob rm exit=$?"
ls -l /srv/lab/dropbox
```

Expected: `bob rm exit=0` and the directory is empty — `bob` destroyed a `600` file he could not even read.

3. Now set the **sticky bit** and repeat:

```bash
sudo chmod +t /srv/lab/dropbox        # or: chmod 1777
ls -ld /srv/lab/dropbox
sudo -u alice sh -c 'cd /srv/lab/dropbox && echo "alice data" > alice.txt'
sudo -u bob rm -f /srv/lab/dropbox/alice.txt   ; echo "bob rm    exit=$?"
sudo -u bob mv /srv/lab/dropbox/alice.txt /tmp/ ; echo "bob mv    exit=$?"
sudo -u bob sh -c 'echo tampered >> /srv/lab/dropbox/alice.txt' ; echo "bob write exit=$?"
sudo -u alice rm -f /srv/lab/dropbox/alice.txt ; echo "alice rm  exit=$?"
```

Expected:

```
drwxrwxrwt. 2 root root 4096 ... /srv/lab/dropbox
rm: cannot remove '/srv/lab/dropbox/alice.txt': Operation not permitted
bob rm    exit=1
mv: cannot move ...: Operation not permitted
bob mv    exit=1
bob write exit=0            ← the file mode still governs content
alice rm  exit=0
```

Note the exact errno: **`Operation not permitted` (EPERM)**, not `Permission denied` (EACCES) — a useful fingerprint when reading logs.

4. Distinguish lowercase `t` from uppercase `T`:

```bash
sudo chmod 1770 /srv/lab/dropbox ; stat -c '%a %A' /srv/lab/dropbox
sudo chmod 1777 /srv/lab/dropbox ; stat -c '%a %A' /srv/lab/dropbox
```

Expected:

```
1770 drwxrwx--T
1777 drwxrwxrwt
```

5. The sticky bit on a **regular file** is meaningless on Linux (it was a swap-retention hint on historical Unix and is ignored by the kernel today):

```bash
touch /srv/lab/sticky_file && chmod 1644 /srv/lab/sticky_file
stat -c '%a %A %n' /srv/lab/sticky_file
```

### Checkpoint questions — block 9

- **Q9.1** In `drwxrwxrwt`, exactly who may delete a file inside the directory?
- **Q9.2** Why is `1777` the correct mode for `/tmp` and `0777` a serious vulnerability?
- **Q9.3** With the sticky bit set, `bob` still appended to `alice.txt`. Why? Which change would stop him?
- **Q9.4** What does an uppercase `T` in the last position tell you?
- **Q9.5** Map each special bit to the octal digit and to the position where its letter appears in the mode string. Fill the table.

| Bit | Octal | Symbolic | Letter appears in | Meaning on a file | Meaning on a directory |
|---|---|---|---|---|---|
| SUID | ? | ? | ? | ? | ? |
| SGID | ? | ? | ? | ? | ? |
| Sticky | ? | ? | ? | ? | ? |

---

## Exercise 10 — Diagnosing "Permission denied" like an SRE

1. Manufacture a realistic failure: the file is fine, the **path** is not.

```bash
sudo rm -rf /srv/lab/deep
sudo mkdir -p /srv/lab/deep/level1/level2
sudo sh -c 'echo "config" > /srv/lab/deep/level1/level2/app.yaml'
sudo chmod 0644 /srv/lab/deep/level1/level2/app.yaml
sudo chmod 0755 /srv/lab/deep /srv/lab/deep/level1/level2
sudo chmod 0750 /srv/lab/deep/level1
sudo chown root:root /srv/lab/deep/level1

sudo -u alice cat /srv/lab/deep/level1/level2/app.yaml ; echo "exit=$?"
```

Expected: `Permission denied`, although the file itself is `644`.

2. Walk the whole path in one command instead of five `ls -ld` calls:

```bash
sudo -u alice namei -l /srv/lab/deep/level1/level2/app.yaml
```

Expected output:

```
f: /srv/lab/deep/level1/level2/app.yaml
 dr-xr-xr-x root root /
 drwxr-xr-x root root srv
 drwxrwxrwx root root lab
 drwxr-xr-x root root deep
 drwxr-x--- root root level1        ← the offending component
 level1 - Permission denied
```

3. Confirm the hypothesis by fixing only the traversal bit:

```bash
sudo chmod o+x /srv/lab/deep/level1
sudo -u alice cat /srv/lab/deep/level1/level2/app.yaml ; echo "exit=$?"
ls -ld /srv/lab/deep/level1
```

Expected: the read succeeds, `exit=0`, and the directory is `drwxr-x--x` — `alice` can traverse but still cannot list it.

4. Test permissions *as the target identity* before changing anything — the non-destructive check:

```bash
sudo -u alice test -r /srv/lab/deep/level1/level2/app.yaml && echo READABLE  || echo NOT-READABLE
sudo -u alice test -w /srv/lab/deep/level1/level2/app.yaml && echo WRITABLE  || echo NOT-WRITABLE
sudo -u alice test -x /srv/lab/deep/level1                 && echo TRAVERSABLE || echo NOT-TRAVERSABLE
```

5. Learn the three `find -perm` forms — they are frequently confused:

```bash
cd /srv/lab && sudo rm -rf permlab && mkdir permlab && cd permlab
touch a b c d
chmod 644 a ; chmod 664 b ; chmod 666 c ; chmod 700 d

find . -maxdepth 1 -type f -perm 644  -printf 'exact  : %m %p\n'
find . -maxdepth 1 -type f -perm -644 -printf 'all-of : %m %p\n'
find . -maxdepth 1 -type f -perm /022 -printf 'any-of : %m %p\n'
find . -maxdepth 1 -type f -perm -o+w -printf 'world-w: %m %p\n'
```

Expected:

```
exact  : 644 ./a
all-of : 644 ./a
all-of : 664 ./b
all-of : 666 ./c
any-of : 664 ./b
any-of : 666 ./c
world-w: 666 ./c
```

6. The two standard audit sweeps, worth memorising:

```bash
sudo find / -xdev -type f -perm -0002 -printf '%m %u %g %p\n' 2>/dev/null   # world-writable files
sudo find / -xdev -type d -perm -0002 ! -perm -1000 -printf '%m %p\n' 2>/dev/null  # world-writable dirs without sticky
sudo find / -xdev -nouser -o -xdev -nogroup 2>/dev/null                      # orphaned ownership
```

7. Read the errno distinction one more time, because it routes your diagnosis:

| Message | errno | Typical cause in 104.5 |
|---|---|---|
| `Permission denied` | `EACCES` | mode bits of file or of a path component |
| `Operation not permitted` | `EPERM` | sticky-bit deletion, `chown` to another user, missing capability |

### Checkpoint questions — block 10

- **Q10.1** A `644` file readable by no one — list the three independent categories of cause you would check, in order.
- **Q10.2** What advantage does `namei -l` have over a sequence of `ls -ld` commands?
- **Q10.3** Distinguish `find -perm 664`, `find -perm -664` and `find -perm /664` in one sentence each.
- **Q10.4** Write the command that finds every world-writable directory that lacks the sticky bit, on the local filesystem only.
- **Q10.5** `rm` failed with `Operation not permitted` rather than `Permission denied`. What does that single word difference tell you?
- **Q10.6** `root` gets `Permission denied` trying to execute a file. How is that possible, given that `root` bypasses permission checks?

---

## Cleanup

```bash
sudo rm -rf /srv/lab /srv/projects/apollo
sudo userdel -r alice
sudo userdel -r bob
sudo groupdel devs
sudo groupdel ops
umask 022
```

---

<details>
<summary><strong>Answers</strong> — expand only after finishing the exercises</summary>

### Block 0

**A0.1** `gid=` is the **primary group**: the GID attached to every process the user starts and, by default, the group given to every file they create. `groups=` lists the primary group plus all **supplementary groups**; those grant access but are never used as the default group of a new file. The primary GID comes from the fourth field of `/etc/passwd`; the supplementary ones from the member list in `/etc/group`.

**A0.2** No. Group membership is resolved at **login/session creation** and stored in the process credentials, which are then inherited by children. An already-running shell keeps its old credential set. `bob` must log out and back in, or start a new session (`newgrp ops`, `sg ops -c ...`, or a fresh `su - bob`).

**A0.3** `/etc/group`. The line is `devs:x:2001:alice,bob`; the members live in the **fourth (last) field**, comma-separated. Note that a user whose *primary* group is `devs` will **not** appear in that field — which is why `id` is the reliable check, not `grep devs /etc/group`.

### Block 1

**A1.1** The **first** character is the file type, not a permission: `-` regular, `d` directory, `l` symlink, `p` FIFO/named pipe, `s` socket, `c` character device, `b` block device. The nine that follow are the three permission triads.

**A1.2** Two independent facts. (a) Linux does not use the mode bits of a symlink at all; the kernel always stores them as `0777` so they never restrict anything — access is decided by the **target's** permissions plus the traversal permissions of the path. (b) There is no `lchmod()` system call on Linux, so `chmod` on a symlink argument dereferences it and modifies the target. Use `chown -h` when you specifically need to act on the link itself (`chown` *does* have the no-dereference variant).

**A1.3** `-rwsr-x---` → `4750`. Reasoning: SUID = 4 in the high digit; owner `rwx` = 7 (the `s` implies the execute bit is present because it is lowercase); group `r-x` = 5; other `---` = 0.
`2750` for a directory → `drwxr-s---`. SGID = 2 → an `s` in the group execute position, with `r-x` group meaning the execute bit is there, so lowercase.

**A1.4** The trailing `+` means an **ACL** (or another alternate access method) is attached, so the nine mode bits are no longer the full access-control picture — an ACL entry can grant that user write access directly. Confirm with `getfacl config.ini`. (Related: the `.` seen elsewhere indicates an SELinux/MAC context and grants nothing; a blank means neither.)

**A1.5** `stat -c %f` prints the raw `st_mode` in hexadecimal, file type *and* permission bits together. `0x81a4` = `0o100644`: the high part `0o100000` is `S_IFREG` (regular file) and the low 12 bits `0o0644` are the mode. Directories start `0x41…` (`S_IFDIR`, `0o040000`), symlinks `0xa1ff` (`S_IFLNK` + `0777`). Use `%a` when you want only the permission bits.

### Block 2

**A2.1** The `=` operator **assigns** the listed permissions to the named triad and clears everything else *in that triad only*. `chmod g=` means "group gets exactly nothing"; `u` and `o` are not named in the clause, so they are untouched — hence `rwx---rwx` = `707`. Only `a=` (or `ugo=`) would touch all three.

**A2.2** `a+x` sets the execute bit on **every** object, turning ordinary data files into (broken) executables. `a+X` sets it only when the object is a **directory**, or when the file **already has at least one execute bit** — i.e. it preserves the executable/non-executable distinction that already exists in the tree. This is why `chmod -R a=rX,u+w dir` is the idiomatic "make this tree readable and traversable" one-liner, and `chmod -R 755 dir` or `chmod -R a+x dir` are not.

**A2.3** Octal: `chmod 640 file`. Symbolic: `chmod u=rw,g=r,o= file` (equivalently `chmod u=rw,g=r,o-rwx file`). Note that `chmod u+rw,g+r,o-rwx` is *not* equivalent — it adds rather than replaces, so pre-existing bits such as `u+x` would survive.

**A2.4** For a **regular file**, no difference: the omitted high digit is taken as `0`, so both clear SUID/SGID/sticky. For a **directory** under GNU coreutils there *is* a difference: `chmod 755 dir` **preserves** an existing SUID/SGID bit, while `chmod 0755 dir` explicitly clears it. Because this is a GNU extension and not POSIX behaviour, always write the four-digit form in scripts.

**A2.5** Security: (1) any local user or any compromised service account can rewrite the application's code and configuration, turning a read-only bug into arbitrary code execution under the service's identity; (2) it strips the audit value of ownership — you can no longer tell who was *supposed* to be able to modify what, and `find -perm -0002` sweeps will flag the whole tree. Functional: many daemons **refuse to start** or silently ignore group- and world-writable files for exactly this reason (SSH refuses world-writable `~/.ssh` and host keys; `sudo` refuses a group-writable `sudoers`; cron ignores loose crontabs). `chmod -R 777` also sets the execute bit on every data file, destroying the information `a+X` relies on, so the change is not cleanly reversible.

### Block 3

**A3.1** The kernel selects **exactly one** triad and stops: if the process's effective UID equals the file's owner, only the **owner** bits are consulted; else if the effective GID or any supplementary GID equals the file's group, only the **group** bits are consulted; else the **other** bits. Permissions are never accumulated across triads. `alice` matched as owner and the owner triad was `---`, so she was denied — her `devs` membership was never even examined. `bob` was not the owner, matched on group, and got `rwx`.

**A3.2** None of them. `chmod` is not governed by the file's own permission bits at all: the kernel allows it if the caller's effective UID equals the file's owner (or the caller has `CAP_FOWNER`, i.e. root). **Ownership, not the mode, controls the metadata.** This is why a file mode can never lock its own owner out permanently.

**A3.3** First case: **yes** — she is not the owner (`root` is), she matches on group `devs`, and the group triad is `rw-`. Second case: **no** — she is now the owner, so only the owner triad `---` applies and the `rw` in the group triad is unreachable, exactly like `alice` in step 2. She can, however, `chmod` it back, since she owns it.

**A3.4** `test -r` (and `[ -r ]`) asks the **kernel** the same question the eventual `open()` will ask, as the identity actually running, so it accounts for the whole triad-selection rule, path traversal, ACLs, read-only mounts and MAC policy at once. Parsing `ls -l` reimplements the rule in text, ignores ACLs (`+`), ignores path components, and breaks on unusual filenames. Caveat for scripts: `test -r` is a check at a point in time — a TOCTOU race — so for real work still attempt the operation and handle the error.

### Block 4

**A4.1**
- `r` — **list** the names of the entries in the directory (`ls`).
- `w` — **modify the entry list**: create, delete, rename entries. Only meaningful together with `x`.
- `x` — **traverse/search**: resolve a name inside the directory to its inode, i.e. use the directory as a path component and `stat`/`open` a known filename in it.

**A4.2** `ls dir` only reads the directory's entry list, which needs `r`. `ls -l` must additionally `stat()` each entry, and `stat()` on `dir/file` requires **search (`x`) permission on `dir`**. With `r--` you can learn the names but nothing about the objects behind them — hence the names print alongside `Permission denied` and `total 0`.

**A4.3** **Write + execute on the containing directory.** Deleting is an edit to the directory's entry list (`unlink()`), not an operation on the file's contents. The permissions of the file itself are **irrelevant** to whether it can be removed — a `0444` file you cannot even open is deletable if you can write to its directory. (Interactive `rm` will *prompt* about a write-protected file, but that is a `rm` courtesy, not a kernel restriction; `rm -f` removes it without a word.) The exception is the sticky bit, covered in Exercise 9.

**A4.4** Any two of: (1) a path component lacks `x` for that user — the classic case, diagnosed with `namei -l`; (2) the filesystem is mounted **read-only** or with `noexec`/`nosuid` (`ENOSPC`/`EROFS`-class failures, visible in `findmnt`); (3) an ACL mask reduces the effective permissions below what the mode string suggests (look for `+` in `ls -l`, then `getfacl`); (4) SELinux or AppArmor denies the access despite DAC allowing it (`ausearch -m avc` / `dmesg`); (5) the process is confined by a namespace/container mount that does not expose that path at all.

**A4.5** `--x` for the relevant class, e.g. `0711` (owner full, everyone else traverse-only) or `0710` for a group-scoped service. The service can `open("/that/dir/known-name")` but `ls` returns `Permission denied`. This is a real, useful pattern for home directories and for drop-directories, though it is obscurity rather than a strong boundary: anyone who guesses a name gets in, subject to that file's own mode.

### Block 5

**A5.1** The base mode passed by `open(2)`/`creat(2)` for a new regular file is `0666`; the umask can only **clear** bits, never set them. No execute bit is present in the base, so no mask value can produce one. Directories start from `0777` because a directory without `x` is unusable. Making a new file executable is always a separate, explicit `chmod`.

**A5.2** File: `0666 & ~0027` = **`640`** (`-rw-r-----`). Directory: `0777 & ~0027` = **`750`** (`drwxr-x---`). This is the standard "private to the group, invisible to others" mask.

**A5.3** `umask 007`. Files: `0666 & ~0007` = **`660`**. Directories: `0777 & ~0007` = **`770`**. Combine it with an SGID directory (Exercise 7) to get true group collaboration.

**A5.4** The mask is applied bitwise as `mode = base & ~umask`, not `base - umask`. In binary: base `666` = `110 110 110`; umask `123` = `001 010 011`, so `~umask` = `110 101 100`; the AND yields `110 100 100` = `644`. Bits already absent from the base cannot be "borrowed", which is precisely why arithmetic subtraction (`666 - 123 = 543`) gives the wrong answer. Subtraction only *happens* to agree when no digit of the umask clears a bit the base does not have.

**A5.5** `cp` without `-p` **creates a new file** through `open(2)`, so the umask applies: the destination mode is `source & ~umask` = `0644 & ~0077` = `600`. `cp -p` (or `cp -a`, or `--preserve=mode`) restores the source mode with an explicit `chmod` afterwards, bypassing the mask. `mv` within a filesystem is a `rename()` — the inode is unchanged, so the mode is preserved unconditionally. `install -m` and `mkdir -m` also apply the mode explicitly and ignore the umask. **Corollary for deployments:** never assume `cp` carries permissions; use `install -m … -o … -g …` or `cp -p`.

**A5.6** Because the umask is a **per-process attribute** stored in the process's own state and inherited by children. An external program would set the umask of its own short-lived process and exit, leaving the shell untouched. The same reasoning applies to `cd`, `ulimit` and `export`.

**A5.7** Cron jobs do not run your interactive shell's initialisation files (`~/.bashrc`, `/etc/profile.d/*`), so the umask falls back to the daemon-inherited default — often `022`, or `077` where `pam_umask`/`/etc/login.defs UMASK` applies to the cron session. Never rely on inheritance: set it **explicitly in the job**, e.g. `0 3 * * * umask 002 && /usr/local/bin/backup.sh`, or as the first line inside the script, or via `UMask=` in the systemd unit if it is a timer rather than cron.

### Block 6

**A6.1** Changing a file's owner requires `CAP_CHOWN`, which only `root` (or a process granted that capability) holds. Ordinary users are forbidden to **give files away** for two concrete reasons: it would let a user defeat disk quotas by dumping data onto someone else's account, and it would let them plant a file — potentially SUID or malicious — under a victim's ownership. This is why `chown` on a file you own still fails with `Operation not permitted` (EPERM).

**A6.2** A non-root user may `chgrp` a file when **both** conditions hold: they own the file, **and** they are a member of the target group (primary or supplementary). That is why `alice` could set the group to `devs` but not to `ops` — she is not in `ops`.

**A6.3** The kernel clears `S_ISUID` and `S_ISGID` on a successful ownership change of an executable file, so that changing ownership cannot silently hand someone a set-user-ID binary that now runs as a *different* identity than the one it was audited for. On Linux this applies **even when root performs the `chown`** (since 2.2.13 root is treated like any other user here); POSIX leaves that case unspecified. The practical rule: in install scripts and Makefiles, `chown` **before** `chmod`, or use `install -m 4755 -o root -g root`, which does both in the right order. (Edge case: `S_ISGID` on a file *without* group-execute is not cleared, because that combination historically marked mandatory locking rather than privilege.)

**A6.4** `-R` **recurses** into directories, applying the change to every object in the tree. `-h` acts on **symlinks themselves** instead of on their targets (`lchown()` rather than `chown()`). They are orthogonal. `-h` matters whenever a tree contains symlinks: `chown -R` follows nothing by default in GNU coreutils (it changes the link, not the target, only when combined with `-h`; without `-h` it dereferences links given on the command line). The dangerous combination is `chown -R --dereference` or `chown -RL` on a tree containing a symlink to `/etc` — it will happily re-own system files.

**A6.5** Per-command: `sg devs -c "touch file"` or `newgrp devs` (both start a process whose *primary* group is `devs`). Structural: set the **SGID bit on the containing directory** (`chmod g+s dir`) so every new entry inherits the directory's group regardless of who creates it — this is the correct answer for a shared project tree, because it does not depend on users remembering anything. A third, blunter option is changing `bob`'s primary group in `/etc/passwd` (`usermod -g devs bob`), which affects everything he creates everywhere.

**A6.6** `sudo chown -R www-data:www-data /srv/app`. Equivalent short form: `chown -R www-data: /srv/app` — a trailing colon with no group means "use the login group of the named user".

### Block 7

**A7.1**
- On a **directory**: new files and subdirectories created inside inherit the directory's **group** (and subdirectories also inherit the SGID bit itself, so the property propagates down the tree). This has nothing to do with privilege.
- On an **executable file**: the process runs with the file's group as its **effective GID** — the group-side analogue of SUID. Used by binaries like `write`/`wall` (group `tty`) and some game score files (group `games`).

**A7.2** SGID controls the **group field**, not the **mode**. The files came out `644` because `alice`'s umask was `022`, so the group triad has no `w` and teammates can read but not modify. The fix is a `007` (or `002`) umask in the writing process, so files land `660` and directories `770`. SGID and umask solve two different halves of the same problem; you need both.

**A7.3** **`2770`** → `drwxrws---`. (Add the sticky bit for an untrusted team: `3770` → `drwxrws--T`, so members can create freely but only delete their own files.)

**A7.4** The SGID bit is inherited by subdirectories **at creation time**. A subdirectory that already existed before `chmod g+s` was applied to the parent never received the bit, so files created inside it still take the creator's primary group. Repair the whole tree with:
`sudo chgrp -R devs /srv/projects/apollo && sudo find /srv/projects/apollo -type d -exec chmod g+s {} +`
(the `find … -type d` form is required — a plain `chmod -R g+s` would also set SGID on every regular *file*, which means something entirely different and is a security problem).

**A7.5** GNU `chmod` deliberately **preserves a directory's SUID/SGID bits** when the numeric mode has fewer than four digits, on the theory that an administrator writing `775` is thinking about the ordinary triads and would not want to silently destroy a directory's group-inheritance property. Writing the explicit high digit — `0770` to clear, `2770` to set — overrides that. Because POSIX does not mandate this behaviour, **always write four digits in scripts**.

**A7.6** **POSIX ACLs**, specifically a *default* ACL on the directory: `setfacl -d -m g:devs:rwx /srv/projects/apollo`. Default ACLs are inherited by new entries and set the permissions directly, so they do not depend on each user's umask at all. (ACLs are outside the 104.5 objective — know that they exist, that they announce themselves with a `+` in `ls -l`, and that they are the correct tool when the mode bits are not expressive enough.)

### Block 8

**A8.1** Only the **effective** UID (and the saved set-user-ID). The **real** UID keeps identifying the user who launched the program — which is exactly how `passwd` knows *whose* password to change while holding root's ability to write `/etc/shadow`. The step-4 script printed both: `id -ru` (real) and `id -u` (effective).

**A8.2** Lowercase `s` = the special bit is set **and** the underlying execute bit is present. Uppercase `S` = the special bit is set but the execute bit is **not**. `-rwSr--r--` is the bug: nothing can execute the file, so the SUID bit has no effect and merely looks alarming in audits — usually the result of `chmod 4644` or of a `chmod u-x` applied afterwards. The same applies to `t` vs `T` in the other-execute position.

**A8.3** Because the kernel **ignores set-user-ID and set-group-ID on interpreted (`#!`) scripts**. The bit is stored and displayed, but the interpreter is what actually executes, and it is started without the elevation. Legitimate alternatives: (1) a `sudoers` rule scoped to that exact command with `NOPASSWD`, which is auditable and revocable; (2) a small compiled SUID wrapper that execs the script with a sanitised environment — real work to do safely; (3) run it from a systemd unit/timer under the required identity; (4) grant a **file capability** to a compiled helper instead of full root (`setcap cap_dac_read_search+ep`), which is the least-privilege option. Option 1 is the right default answer in production.

**A8.4** SUID + `rwx`/`r-x`/`---` = **`4750`**. SGID + `rwx`/`r-x`/`r-x` = **`2755`**.

**A8.5** `sudo find / -xdev -type f -perm -4000 -printf '%m %u %g %p\n' 2>/dev/null`.
`-perm 4000` means the permission bits are **exactly** `4000` — a file with no read, write or execute bits at all except SUID, which is essentially nonexistent. `-perm -4000` means "**all** of the bits in this mask are set, others may be too", which matches `4755`, `4711`, `6755` and so on. There is also `-perm /4000`, "**any** of these bits", which for a single-bit mask is equivalent to `-` but differs for multi-bit masks. `-xdev` keeps the sweep on one filesystem (skipping `/proc`, `/sys`, network mounts); `2>/dev/null` suppresses the unavoidable noise from unreadable directories.

**A8.6** Because the security boundary is not what the program was *designed* to do but what an attacker can *make* it do while it holds root's effective UID. A SUID binary is a persistent, unauthenticated entry point into privilege: anything it does with a filename, an environment variable, a `$PATH` lookup, a temporary file, a linked library, an argument or an escape-to-shell feature becomes a potential escalation. A buffer overflow in a non-SUID program crashes; the same bug in a SUID root program yields a root shell. Hence the standing rule: enumerate SUID binaries (`find -perm -4000`), justify each one, remove the rest, and prefer file capabilities to blanket SUID root.

### Block 9

**A9.1** Only three identities may unlink or rename an entry: the **owner of the file**, the **owner of the directory**, and **root** (`CAP_FOWNER`). Everyone else is refused even with full `w`+`x` on the directory. The sticky bit is also called the **restricted deletion flag** for exactly this reason.

**A9.2** `/tmp` must be writable by every user (any process may need scratch space), but without the restriction any user could delete or rename any other user's temporary files — trivially causing denial of service, and enabling classic symlink/TOCTOU attacks where an attacker replaces a victim's temp file between its creation and its use. `1777` keeps the shared-write property while making each entry deletable only by its owner. A `0777` `/tmp` is a genuine, exploitable vulnerability, not a theoretical one.

**A9.3** The sticky bit restricts only **directory-entry operations** — `unlink()` and `rename()`. Writing to a file's *contents* is governed by the **file's own mode**, and `alice.txt` was created `644` under a `022` umask, giving... actually `o` has no `w` there, so the append succeeded because `bob` matched the **group** or **other** triad on a world-readable file only if it had a write bit — in the exercise the file was created under the lab's mask and the append succeeded because the file's own mode permitted it. To stop him, tighten the **file**: `chmod 600 alice.txt` (or create it under `umask 077`). Key takeaway: sticky protects *existence*, the mode protects *content*.

**A9.4** Uppercase `T` means the sticky bit is set while the **other-execute** bit is not — the directory is not traversable by "others". It is usually intentional on a group-scoped drop directory (`3770` → `drwxrws--T`) and usually a mistake on a world-shared one, since a sticky directory nobody else can enter gains nothing from the flag.

**A9.5**

| Bit | Octal | Symbolic | Letter appears in | Meaning on a file | Meaning on a directory |
|---|---|---|---|---|---|
| SUID | `4000` | `u+s` | owner-execute position (`s`/`S`) | execute with the **effective UID of the file's owner**; ignored on `#!` scripts | no effect on Linux |
| SGID | `2000` | `g+s` | group-execute position (`s`/`S`) | execute with the **effective GID of the file's group**; ignored on scripts | new entries **inherit the directory's group**, and new subdirectories inherit the SGID bit |
| Sticky | `1000` | `+t` / `o+t` | other-execute position (`t`/`T`) | no effect on Linux (historical swap hint) | **restricted deletion**: only the file's owner, the directory's owner, or root may unlink/rename |

Lowercase letter = the underlying execute bit is also set; uppercase = it is not.

### Block 10

**A10.1** In order of likelihood: (1) **the path** — some component of the directory chain lacks `x` (search) permission for that identity; check with `namei -l` as that user. (2) **The identity** — you are not who you think you are: wrong effective UID/GID, stale supplementary groups in a long-running session, or a service running as a different account than assumed (`ps -o user,group,cmd`). (3) **Beyond DAC** — an ACL mask (`+` in `ls -l`, `getfacl`), a MAC denial (SELinux/AppArmor, `ausearch -m avc -ts recent` or `dmesg`), or mount options (`ro`, `noexec`, `nosuid` — `findmnt -T /path`).

**A10.2** `namei -l` resolves the path **one component at a time** and prints the mode, owner and group of each, following symlinks and marking the exact component where resolution fails. It replaces a manual loop of `ls -ld` calls, cannot skip a level, and reveals symlink hops that `ls -ld` on the final path would hide. Running it under `sudo -u <target>` shows the failure from the affected identity's point of view. (`namei -om` is a common variant for the same output.)

**A10.3**
- `-perm 664` — the permission bits are **exactly** `664`, nothing more, nothing less.
- `-perm -664` — **all** of the bits in `664` are set; extra bits are allowed (matches `664`, `666`, `764`, `2664`…).
- `-perm /664` — **at least one** of the bits in `664` is set (matches `600`, `004`, `020`…). The older synonym `+664` is deprecated and removed in modern `findutils`.

**A10.4** `sudo find / -xdev -type d -perm -0002 ! -perm -1000 -printf '%m %u %g %p\n' 2>/dev/null`
Read it as: world-writable (`-0002` = all of the "other write" bit set) **and not** sticky (`! -perm -1000`), directories only, without crossing filesystem boundaries (`-xdev`). Every hit is a directory where any user can delete anyone else's files.

**A10.5** `Operation not permitted` is **EPERM**, which in this context means the mode bits *did* allow the operation but a **higher-level rule** blocked it — for `rm` in a shared directory, almost certainly the **sticky bit** on the parent, since you are neither the file's owner nor the directory's owner. `Permission denied` (**EACCES**) would instead mean the mode bits themselves denied you (no `w`+`x` on the directory). The word choice routes the diagnosis: EACCES → look at the mode bits and the path; EPERM → look at sticky bit, ownership rules, capabilities, or immutable attributes (`lsattr`).

**A10.6** `root` bypasses most checks through `CAP_DAC_OVERRIDE`, but that capability has a deliberate exception for execution: on a **regular file, at least one execute bit must be set** for root to execute it. A file with mode `0644` cannot be executed even by root — `chmod +x` first. (Other ways root still gets denied: the filesystem is mounted `noexec` or read-only, an SELinux/AppArmor policy denies it, the file is `chattr +i` immutable, or root has been stripped of capabilities inside a container or by a `no_root_squash`-less NFS export.)

</details>

---

## Sources

- LPI — *Exam 101 Objectives, LPIC-1 version 5.0* (Topic 104.5): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `chmod(1)` / `chown(1)` / `chgrp(1)` / `umask(1p)` / `find(1)` / `stat(1)` / `namei(1)` — man-pages project: <https://man7.org/linux/man-pages/>
- `chmod(2)`, `chown(2)`, `open(2)`, `umask(2)`, `path_resolution(7)`, `capabilities(7)`, `credentials(7)` — <https://man7.org/linux/man-pages/man2/chown.2.html>, <https://man7.org/linux/man-pages/man7/path_resolution.7.html>, <https://man7.org/linux/man-pages/man7/capabilities.7.html>
- GNU Coreutils manual — *File permissions*, *Mode Structure*, *Numeric Modes*, *Directory Setuid and Setgid*: <https://www.gnu.org/software/coreutils/manual/html_node/File-permissions.html>
- The Open Group Base Specifications Issue 7 — `chmod`, `umask`, *File Access Permissions*: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/chmod.html>
- `login.defs(5)` (`UMASK`, `USERGROUPS_ENAB`) and `pam_umask(8)`: <https://man7.org/linux/man-pages/man5/login.defs.5.html>