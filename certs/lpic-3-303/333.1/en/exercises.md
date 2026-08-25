# 333.1 — Discretionary Access Control: Guided Exercises

**Exam:** LPIC-3 303-300 (Security), v3.0.0 · **Topic weight:** 5
**Utilities in scope:** `chmod`, `umask`, `chown`, `chgrp`, `getfacl`, `setfacl`, `getfattr`, `setfattr`
**Source of the objective:** <https://www.lpi.org/our-certifications/exam-303-objectives/>

> **Run this on a disposable VM or container.** The exercises create local users and groups, set SUID binaries, and mount filesystems. Nothing here should be executed on a machine you care about. Everything is confined to a loop-mounted ext4 image so that the cleanup step is a single `umount` plus one `rm`.
>
> **Why a loop image and not `/tmp`?** `/tmp` is `tmpfs` on most modern distributions, and `tmpfs` only gained `user.*` extended-attribute support in Linux 6.6. It is also frequently mounted `nosuid,nodev`. Both facts silently break half of this topic. A disk-backed ext4 filesystem with known mount options is the only reproducible substrate for DAC exercises.

---

## Exercise 0 — Build the lab filesystem

### Steps

1. Create two ext4 images: one with the ACL/xattr defaults, one deliberately crippled.

```console
# dd if=/dev/zero of=/var/tmp/dac-lab.img  bs=1M count=256 status=none
# dd if=/dev/zero of=/var/tmp/dac-plain.img bs=1M count=64  status=none
# mkfs.ext4 -q -F /var/tmp/dac-lab.img
# mkfs.ext4 -q -F /var/tmp/dac-plain.img
```

2. Inspect the *filesystem-level* default mount options recorded in the superblock.

```console
# tune2fs -l /var/tmp/dac-lab.img | grep -E 'Default mount options|Filesystem features'
Default mount options:    user_xattr acl
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
```

3. Mount both.

```console
# mkdir -p /srv/dac-lab /srv/dac-plain
# mount -o loop                      /var/tmp/dac-lab.img   /srv/dac-lab
# mount -o loop,noacl,nouser_xattr   /var/tmp/dac-plain.img /srv/dac-plain
```

4. Ask the kernel what it actually applied.

```console
# findmnt -no SOURCE,FSTYPE,OPTIONS /srv/dac-lab
/dev/loop0 ext4 rw,relatime,seclabel

# findmnt -no SOURCE,FSTYPE,OPTIONS /srv/dac-plain
/dev/loop1 ext4 rw,relatime,seclabel,noacl,nouser_xattr
```

5. Create the identities used throughout.

```console
# groupadd devops
# groupadd payroll
# useradd -m -G devops  alice
# useradd -m -G devops  bob
# useradd -m            carol
# id alice; id bob; id carol
uid=1001(alice) gid=1001(alice) groups=1001(alice),1004(devops)
uid=1002(bob) gid=1002(bob) groups=1002(bob),1004(devops)
uid=1003(carol) gid=1003(carol) groups=1003(carol)
```

> UIDs on your system will differ. Wherever a numeric ID appears below, substitute the output of `id -u <user>`.

### Comprehension check

- **Q0.1** `findmnt` shows `noacl,nouser_xattr` for `/srv/dac-plain` but shows neither `acl` nor `user_xattr` for `/srv/dac-lab`. Does that mean ACLs are disabled on `/srv/dac-lab`? Explain the general rule about reading `/proc/self/mounts`.
- **Q0.2** What is the difference between the `ext_attr` entry in `Filesystem features` and the `user_xattr` entry in `Default mount options`?
- **Q0.3** A colleague reports that `setfacl` fails with `Operation not supported` on a production volume. Name the three distinct layers you would check, in order, before concluding the tool is broken.

---

## Exercise 1 — Ownership, the mode word, and what `ls -l` is really printing

### Steps

1. Create a working tree and look at the raw mode.

```console
# mkdir -p /srv/dac-lab/project
# cd /srv/dac-lab/project
# echo 'quarterly figures' > report.txt
# ls -l report.txt
-rw-r--r--. 1 root root 18 Aug 24 10:11 report.txt
# stat -c 'mode=%A  octal=%a  raw=%f  uid=%u(%U)  gid=%g(%G)  %n' report.txt
mode=-rw-r--r--  octal=644  raw=81a4  uid=0(root)  gid=0(root)  report.txt
```

2. Change ownership and group, then confirm that only the identity changed.

```console
# chown alice report.txt
# chgrp devops report.txt
# chown alice:devops report.txt          # equivalent single call
# ls -l report.txt
-rw-r--r--. 1 alice devops 18 Aug 24 10:11 report.txt
```

3. Compare symbolic and numeric `chmod`. Note that symbolic mode is a *delta*, numeric mode is an *absolute assignment*.

```console
# chmod 640 report.txt      ; stat -c %a report.txt
640
# chmod g+w  report.txt     ; stat -c %a report.txt
660
# chmod o=r  report.txt     ; stat -c %a report.txt
664
# chmod u=rw,g=r,o= report.txt ; stat -c %a report.txt
640
```

4. Demonstrate that *deleting* a file is a directory operation, not a file operation.

```console
# mkdir /srv/dac-lab/project/locked
# echo secret > /srv/dac-lab/project/locked/data.txt
# chmod 000 /srv/dac-lab/project/locked/data.txt
# chmod 777 /srv/dac-lab/project/locked
# sudo -u carol cat /srv/dac-lab/project/locked/data.txt
cat: /srv/dac-lab/project/locked/data.txt: Permission denied
# sudo -u carol rm -f /srv/dac-lab/project/locked/data.txt
# ls /srv/dac-lab/project/locked
```

5. Show that `chmod` on a symlink is a no-op on Linux, and that `chown` needs `-h`.

```console
# ln -s report.txt report.lnk
# ls -l report.lnk
lrwxrwxrwx. 1 root root 10 Aug 24 10:14 report.lnk -> report.txt
# chmod 600 report.lnk
# ls -l report.lnk report.txt
lrwxrwxrwx. 1 root  root   10 Aug 24 10:14 report.lnk -> report.txt
-rw-------. 1 alice devops 18 Aug 24 10:11 report.txt
# chown -h carol report.lnk
# ls -l report.lnk
lrwxrwxrwx. 1 carol root 10 Aug 24 10:14 report.lnk -> report.txt
```

### Comprehension check

- **Q1.1** `stat` reported `raw=81a4`. Decompose that 16-bit value. Which part is the file type and which part is the permission word?
- **Q1.2** In step 3, why did `chmod g+w` produce `660` while `chmod o=r` produced `664`? State the rule that distinguishes `+`/`-` from `=`.
- **Q1.3** In step 4, `carol` could not read a file but could delete it. Which permission bit, on which inode, authorised the deletion?
- **Q1.4** `chmod 600 report.lnk` silently changed nothing. What did it actually modify, and which system call would have been required to change the symlink's own mode?
- **Q1.5** A file is `-rw-rw-rw-` and owned by `alice:devops`. `alice` is a member of `devops`. Which triad does the kernel evaluate for `alice`, and what happens if the owner triad is `---` while the group triad is `rw-`?

---

## Exercise 2 — Path resolution: `x` on directories is not "execute"

### Steps

1. Build a three-level path and remove the *read* bit from the middle directory while keeping *execute*.

```console
# mkdir -p /srv/dac-lab/a/b/c
# echo payload > /srv/dac-lab/a/b/c/file.txt
# chmod 711 /srv/dac-lab/a/b        # --x for group/other: traversable, not listable
# chmod 755 /srv/dac-lab/a /srv/dac-lab/a/b/c
# chmod 644 /srv/dac-lab/a/b/c/file.txt
```

2. Have an unprivileged user try to list versus traverse.

```console
# sudo -u carol ls /srv/dac-lab/a/b
ls: cannot open directory '/srv/dac-lab/a/b': Permission denied
# sudo -u carol cat /srv/dac-lab/a/b/c/file.txt
payload
```

3. Now invert it: read bit present, execute bit absent.

```console
# chmod 744 /srv/dac-lab/a/b
# sudo -u carol ls /srv/dac-lab/a/b
c
# sudo -u carol ls -l /srv/dac-lab/a/b
ls: cannot access '/srv/dac-lab/a/b/c': Permission denied
total 0
d????????? ? ? ? ?            ? c
# sudo -u carol cat /srv/dac-lab/a/b/c/file.txt
cat: /srv/dac-lab/a/b/c/file.txt: Permission denied
```

4. Restore.

```console
# chmod 755 /srv/dac-lab/a/b
```

### Comprehension check

- **Q2.1** State precisely what `r` and what `x` grant on a directory inode.
- **Q2.2** Why does step 3 print `d?????????` instead of a normal long listing?
- **Q2.3** The `711` mode on a home directory (`/home/alice`) is a common hardening pattern. What does it allow and what does it prevent? Why is `750` sometimes preferred?
- **Q2.4** A web server returns 403 for `/srv/app/public/index.html` even though the file is `-rw-r--r-- root root` and the server runs as `nginx`. `namei -om /srv/app/public/index.html` is the diagnostic tool. What is it checking that `ls -l index.html` cannot?

---

## Exercise 3 — `umask`: the bits a process is forbidden to create

### Steps

1. Read the current mask in both notations.

```console
# umask
0022
# umask -S
u=rwx,g=rx,o=rx
```

2. Observe the two different *creation modes* that programs request, and how the mask subtracts from them.

```console
# cd /srv/dac-lab/project
# umask 022
# touch f022 ; mkdir d022
# umask 077
# touch f077 ; mkdir d077
# umask 002
# touch f002 ; mkdir d002
# ls -ld f022 d022 f077 d077 f002 d002
drwxr-xr-x. 2 root root 4096 Aug 24 10:22 d022
drwxrwx---. 2 root root 4096 Aug 24 10:22 d002
drwx------. 2 root root 4096 Aug 24 10:22 d077
-rw-r--r--. 1 root root    0 Aug 24 10:22 f022
-rw-rw----. 1 root root    0 Aug 24 10:22 f002
-rw-------. 1 root root    0 Aug 24 10:22 f077
```

3. Prove that the mask is a *per-process* attribute inherited across `fork`/`exec`, not a filesystem or user attribute.

```console
# umask 027
# bash -c 'umask; touch /srv/dac-lab/project/inherited; stat -c %a /srv/dac-lab/project/inherited'
0027
640
```

4. Show a mask that removes bits the creation mode never had.

```console
# umask 777
# touch f777 ; mkdir d777
# ls -ld f777 d777
d---------. 2 root root 4096 Aug 24 10:24 d777
----------. 1 root root    0 Aug 24 10:24 f777
# umask 022
```

5. Look at where the login mask comes from on a real system.

```console
# grep -E '^\s*(UMASK|HOME_MODE|USERGROUPS_ENAB)' /etc/login.defs
UMASK 022
HOME_MODE 0700
USERGROUPS_ENAB yes
# grep -rn pam_umask /etc/pam.d/ | head -3
/etc/pam.d/postlogin:session  optional  pam_umask.so silent
```

### Comprehension check

- **Q3.1** With `umask 077`, a regular file was created `600` and a directory `700`. Why is the directory not `600`?
- **Q3.2** Is `umask` a subtraction or a bitwise operation? Write the exact expression the kernel applies inside `open(2)`/`mkdir(2)`.
- **Q3.3** With `umask 022`, `gcc` produces an executable that is `755`, but `touch` produces `644`. Neither umask nor the filesystem differs. Explain.
- **Q3.4** A cron job writes files as `0644` although the operator's interactive shell has `umask 007`. Give two independent reasons and the fix for each.
- **Q3.5** `USERGROUPS_ENAB yes` combined with `pam_umask` typically yields an effective umask of `002` for ordinary users instead of `022`. What is the security assumption that makes `002` acceptable there, and when does that assumption fail?

---

## Exercise 4 — SUID, SGID, and the sticky bit

### Steps

1. Create a SUID binary without needing a compiler, by copying `id` and setting the bit.

```console
# cp /usr/bin/id /srv/dac-lab/project/idcopy
# chmod 4755 /srv/dac-lab/project/idcopy
# ls -l /srv/dac-lab/project/idcopy
-rwsr-xr-x. 1 root root 39784 Aug 24 10:30 /srv/dac-lab/project/idcopy
# sudo -u carol /srv/dac-lab/project/idcopy
uid=1003(carol) gid=1003(carol) euid=0(root) groups=1003(carol)
```

2. Observe the capital-`S` form: the special bit set *without* the underlying execute bit.

```console
# chmod 4644 /srv/dac-lab/project/idcopy
# ls -l /srv/dac-lab/project/idcopy
-rwSr--r--. 1 root root 39784 Aug 24 10:30 /srv/dac-lab/project/idcopy
# chmod 4755 /srv/dac-lab/project/idcopy
```

3. Show that `chown` destroys the SUID bit.

```console
# chown alice /srv/dac-lab/project/idcopy
# ls -l /srv/dac-lab/project/idcopy
-rwxr-xr-x. 1 alice root 39784 Aug 24 10:30 /srv/dac-lab/project/idcopy
```

4. Prove SUID is ignored on interpreted scripts.

```console
# printf '#!/bin/bash\nid\n' > /srv/dac-lab/project/whoami.sh
# chmod 4755 /srv/dac-lab/project/whoami.sh
# sudo -u carol /srv/dac-lab/project/whoami.sh
uid=1003(carol) gid=1003(carol) groups=1003(carol)
```

5. Build the canonical SGID collaborative directory.

```console
# mkdir /srv/dac-lab/shared
# chgrp devops /srv/dac-lab/shared
# chmod 2770  /srv/dac-lab/shared
# ls -ld /srv/dac-lab/shared
drwxrws---. 2 root devops 4096 Aug 24 10:34 /srv/dac-lab/shared
# sudo -u alice touch /srv/dac-lab/shared/from-alice
# sudo -u bob   mkdir /srv/dac-lab/shared/subdir
# ls -ld /srv/dac-lab/shared/from-alice /srv/dac-lab/shared/subdir
-rw-r--r--. 1 alice devops    0 Aug 24 10:35 /srv/dac-lab/shared/from-alice
drwxr-sr-x. 2 bob   devops 4096 Aug 24 10:35 /srv/dac-lab/shared/subdir
```

6. Build a sticky drop-box and try to delete someone else's file.

```console
# mkdir /srv/dac-lab/dropbox
# chmod 1777 /srv/dac-lab/dropbox
# ls -ld /srv/dac-lab/dropbox
drwxrwxrwt. 2 root root 4096 Aug 24 10:38 /srv/dac-lab/dropbox
# sudo -u alice touch /srv/dac-lab/dropbox/alice.tmp
# sudo -u bob rm /srv/dac-lab/dropbox/alice.tmp
rm: cannot remove '/srv/dac-lab/dropbox/alice.tmp': Operation not permitted
# sudo -u bob mv /srv/dac-lab/dropbox/alice.tmp /srv/dac-lab/dropbox/hijacked
mv: cannot move '/srv/dac-lab/dropbox/alice.tmp' to '/srv/dac-lab/dropbox/hijacked': Operation not permitted
# sudo -u bob truncate -s 0 /srv/dac-lab/dropbox/alice.tmp
# ls -l /srv/dac-lab/dropbox/alice.tmp
-rw-r--r--. 1 alice alice 0 Aug 24 10:39 /srv/dac-lab/dropbox/alice.tmp
```

7. Audit the running system the way you would in an engagement.

```console
# find /usr /bin /sbin -xdev -type f -perm -4000 -printf '%M %u %g %p\n' 2>/dev/null | head
-rwsr-xr-x root root /usr/bin/su
-rwsr-xr-x root root /usr/bin/mount
-rwsr-xr-x root root /usr/bin/passwd
...
# find / -xdev -type f -perm /6000 2>/dev/null | wc -l
22
# find / -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null
```

### Comprehension check

- **Q4.1** Distinguish `-rwsr-xr-x` from `-rwSr-xr-x` and `drwxrwxrwt` from `drwxrwxrwT`. What does the lowercase/uppercase distinction encode in every case?
- **Q4.2** In step 3 the SUID bit disappeared after `chown`, executed *as root*. Why does the kernel do this, and why must you never rely on the privileged case behaving one way or the other?
- **Q4.3** Step 4 produced no privilege escalation. What is the kernel-level reason, and which alternative mechanisms exist for granting a script elevated rights?
- **Q4.4** In step 5, `from-alice` is group `devops` rather than group `alice`. Which bit produced that, and what did `subdir` additionally inherit that `from-alice` could not?
- **Q4.5** In step 6, `bob` could not unlink or rename `alice.tmp` but *could* truncate it to zero bytes. Explain exactly what the sticky bit protects and what it does not.
- **Q4.6** `find / -perm -4000` and `find / -perm /6000` return different sets. State the semantics of `-`, `/`, and a bare octal argument to `find -perm`.
- **Q4.7** A SUID-root helper stops working after the operations team adds `nosuid` to the volume's mount options. Where else, besides `mount`, can SUID be neutralised system-wide?

---

## Exercise 5 — POSIX ACLs and the mask

### Steps

1. Read the ACL of a file that has no extended ACL. Note the three *base* entries mapping onto the classic mode word.

```console
# cd /srv/dac-lab/project
# chown root:devops report.txt ; chmod 640 report.txt
# getfacl report.txt
getfacl: Removing leading '/' from absolute path names
# file: report.txt
# owner: root
# group: devops
user::rw-
group::r--
other::---
```

2. Grant a named user access. Watch a `mask` entry appear and the `+` marker attach to the listing.

```console
# setfacl -m u:carol:rw- report.txt
# ls -l report.txt
-rw-rw----+ 1 root devops 18 Aug 24 10:11 report.txt
# getfacl report.txt
# file: report.txt
# owner: root
# group: devops
user::rw-
user:carol:rw-
group::r--
mask::rw-
other::---
# sudo -u carol sh -c 'echo appended >> report.txt' && echo OK
OK
```

3. **The trap.** `ls -l` now shows `rw-` in the group field. Verify that this is *not* the owning group's permission.

```console
# stat -c %a report.txt
660
# getfacl -c report.txt | grep '^group::'
group::r--
# sudo -u bob sh -c 'echo bob-was-here >> report.txt'
sh: line 1: report.txt: Permission denied
```

4. Now shrink the mask with `chmod` and watch every named entry lose rights at once.

```console
# chmod g=r report.txt
# getfacl report.txt
# file: report.txt
# owner: root
# group: devops
user::rw-
user:carol:rw-			#effective:r--
group::r--
mask::r--
other::---
# sudo -u carol sh -c 'echo again >> report.txt'
sh: line 1: report.txt: Permission denied
```

5. Restore the mask explicitly, without touching any grant.

```console
# setfacl -m m::rw- report.txt
# getfacl -c report.txt
user::rw-
user:carol:rw-
group::r--
mask::rw-
other::---
```

6. Show automatic mask recalculation and how to suppress it.

```console
# setfacl -m g:payroll:rwx report.txt
# getfacl -c report.txt | grep mask
mask::rwx
# setfacl -n -m g:payroll:rwx report.txt      # -n: leave the mask alone
```

7. Remove entries selectively and wholesale.

```console
# setfacl -x g:payroll report.txt
# getfacl -c report.txt | grep payroll || echo 'entry gone'
entry gone
# setfacl -b report.txt
# ls -l report.txt
-rw-r-----. 1 root devops 30 Aug 24 10:48 report.txt
```

8. Save and restore ACLs as a text stream — the mechanism behind ACL backup.

```console
# setfacl -m u:carol:rw,g:payroll:r report.txt
# getfacl -R --absolute-names /srv/dac-lab/project > /var/tmp/project.acl
# setfacl -b report.txt
# setfacl --restore=/var/tmp/project.acl
# getfacl -c report.txt | grep -E 'carol|payroll'
user:carol:rw-
group:payroll:r--
```

9. Find every file on the volume that carries an extended ACL.

```console
# getfacl -R -s -p /srv/dac-lab 2>/dev/null | grep '^# file:' 
# file: /srv/dac-lab/project
# file: /srv/dac-lab/project/report.txt
```

### Comprehension check

- **Q5.1** List the six ACL entry types and state which ones an ACL is *required* to contain to be valid.
- **Q5.2** Exactly which entry classes does the `mask` limit, and which two are immune to it?
- **Q5.3** In step 3, `ls -l` showed `-rw-rw----+` yet `bob` — a member of the owning group `devops` — was denied write. Reconcile these two facts in one sentence.
- **Q5.4** In step 4 a plain `chmod g=r` silently revoked `carol`'s write access even though `carol` is not in `devops`. State the rule `chmod` follows on a file with an extended ACL, and name the operational hazard this creates for configuration management tools.
- **Q5.5** What does `#effective:` in `getfacl` output mean, and why does it never appear next to `user::`?
- **Q5.6** Contrast `setfacl -x`, `setfacl -b`, and `setfacl -k`.
- **Q5.7** `setfacl -m u:carol:rwx dir` succeeds but `carol` still cannot create files in `dir`. Give the two most likely causes.
- **Q5.8** Why does `getfacl -R -s` make a better volume audit than `find ... -perm`?

---

## Exercise 6 — Default ACLs, inheritance, and the umask override

### Steps

1. Attach a default ACL to a directory. Only directories can carry one.

```console
# mkdir /srv/dac-lab/inbox
# chown root:devops /srv/dac-lab/inbox
# chmod 750 /srv/dac-lab/inbox
# setfacl -d -m u:carol:rwx,g:payroll:r-x /srv/dac-lab/inbox
# getfacl /srv/dac-lab/inbox
# file: srv/dac-lab/inbox
# owner: root
# group: devops
user::rwx
group::r-x
other::---
default:user::rwx
default:user:carol:rwx
default:group::r-x
default:group:payroll:r-x
default:mask::rwx
default:other::---
# setfacl -d -m u:carol:rwx /srv/dac-lab/project/report.txt
setfacl: report.txt: Only directories can have default ACLs
```

2. Set a hostile umask, then create a file inside the directory.

```console
# ( umask 077 && touch /srv/dac-lab/inbox/inherited.txt )
# ls -l /srv/dac-lab/inbox/inherited.txt
-rw-rw----+ 1 root root 0 Aug 24 11:02 /srv/dac-lab/inbox/inherited.txt
# getfacl -c /srv/dac-lab/inbox/inherited.txt
user::rw-
user:carol:rwx			#effective:rw-
group::r-x			#effective:r--
group:payroll:r-x		#effective:r--
mask::rw-
other::---
```

3. Create a subdirectory and observe the two-way inheritance.

```console
# ( umask 077 && mkdir /srv/dac-lab/inbox/sub )
# getfacl -c /srv/dac-lab/inbox/sub
user::rwx
user:carol:rwx
group::r-x
group:payroll:r-x
mask::rwx
other::---
default:user::rwx
default:user:carol:rwx
default:group::r-x
default:group:payroll:r-x
default:mask::rwx
default:other::---
```

4. Confirm that inheritance is applied at creation time only — it is not a live link.

```console
# setfacl -d -x u:carol /srv/dac-lab/inbox
# getfacl -c /srv/dac-lab/inbox/inherited.txt | grep carol
user:carol:rwx			#effective:rw-
```

5. Apply an ACL to an existing tree, distinguishing access from default entries in one pass.

```console
# setfacl -R -m u:carol:rX /srv/dac-lab/inbox
# setfacl -R -d -m u:carol:rX /srv/dac-lab/inbox
# getfacl -c /srv/dac-lab/inbox/inherited.txt | grep carol
user:carol:r--
# getfacl -c /srv/dac-lab/inbox/sub | grep carol
user:carol:r-x
default:user:carol:r-x
```

6. Drop the default ACL without touching the access ACL.

```console
# setfacl -k /srv/dac-lab/inbox
# getfacl -c /srv/dac-lab/inbox | grep -c default
0
```

### Comprehension check

- **Q6.1** In step 2, the umask was `077` and yet the file came out `-rw-rw----`. State the rule from `acl(5)` that governs this, and explain why it is a frequent source of "our hardening baseline is not being applied" incidents.
- **Q6.2** The default ACL granted `carol` `rwx`, but the created file shows `#effective:rw-`. Where did the `x` go? Which parameter, supplied by which system call, capped it?
- **Q6.3** `inherited.txt` is a file and got only an access ACL; `sub` is a directory and got both an access ACL and a default ACL. Why the asymmetry?
- **Q6.4** In step 4, revoking the default entry on the parent had no effect on the existing child. What does this tell you about the correct order of operations when rolling out a permission change to a live data directory?
- **Q6.5** In step 5, `rX` (capital X) was used instead of `rx`. What is the difference, and why does it matter for a recursive application over a tree containing both files and directories?
- **Q6.6** You must guarantee that *everything* written into `/srv/data` by any process is group-readable by `devops`. Compare the SGID-directory approach with the default-ACL approach: what does each one actually guarantee, and what does each one fail to guarantee?

---

## Exercise 7 — Extended attributes and attribute namespaces

### Steps

1. Set and read a `user.*` attribute.

```console
# cd /srv/dac-lab/project
# setfattr -n user.owner_team -v 'payments-sre' report.txt
# setfattr -n user.retention  -v '2555d'        report.txt
# getfattr -d report.txt
getfattr: Removing leading '/' from absolute path names
# file: report.txt
user.owner_team="payments-sre"
user.retention="2555d"
# getfattr -n user.owner_team --only-values report.txt; echo
payments-sre
```

2. Note that `getfattr` defaults to the `user.` namespace only. Widen the pattern.

```console
# getfattr -d -m '.*' report.txt
# file: report.txt
security.selinux="unconfined_u:object_r:unlabeled_t:s0"
user.owner_team="payments-sre"
user.retention="2555d"
```

3. Explore the four namespaces and their access rules.

```console
# setfattr -n trusted.audit_tag -v 'pci-dss' report.txt
# sudo -u carol setfattr -n trusted.audit_tag -v 'tampered' report.txt
setfattr: report.txt: Operation not permitted
# sudo -u carol getfattr -d -m '.*' report.txt
# file: report.txt
security.selinux="unconfined_u:object_r:unlabeled_t:s0"
user.owner_team="payments-sre"
user.retention="2555d"
# getfattr -d -m '.*' report.txt | grep trusted
trusted.audit_tag="pci-dss"
```

4. Read the ACL through its `system.*` backing store, and decode it by hand.

```console
# setfacl -b report.txt
# chmod 640 report.txt
# setfacl -m u:carol:rw- report.txt
# id -u carol
1003
# getfattr -n system.posix_acl_access -e hex report.txt
# file: report.txt
system.posix_acl_access=0x0200000001000600ffffffff02000600eb03000004000400ffffffff10000600ffffffff20000000ffffffff
```

Decode, little-endian, 4-byte header (`0x00000002` = `POSIX_ACL_XATTR_VERSION`) followed by 8-byte records of `{u16 tag, u16 perm, u32 id}`:

| Bytes | Tag | Constant | Perm | id | Meaning |
|---|---|---|---|---|---|
| `0100 0600 ffffffff` | `0x0001` | `ACL_USER_OBJ` | `6` = `rw-` | undefined | `user::rw-` |
| `0200 0600 eb030000` | `0x0002` | `ACL_USER` | `6` = `rw-` | `0x3eb` = 1003 | `user:carol:rw-` |
| `0400 0400 ffffffff` | `0x0004` | `ACL_GROUP_OBJ` | `4` = `r--` | undefined | `group::r--` |
| `1000 0600 ffffffff` | `0x0010` | `ACL_MASK` | `6` = `rw-` | undefined | `mask::rw-` |
| `2000 0000 ffffffff` | `0x0020` | `ACL_OTHER` | `0` = `---` | undefined | `other::---` |

> Your `id` bytes will differ. On some kernel/filesystem combinations `system.posix_acl_access` is not returned by a wildcard `getfattr -m` listing but is still readable by explicit name, as above.

5. Attempt to write a `user.*` attribute where the namespace is disabled.

```console
# cp report.txt /srv/dac-plain/report.txt
# setfattr -n user.owner_team -v 'payments-sre' /srv/dac-plain/report.txt
setfattr: /srv/dac-plain/report.txt: Operation not supported
# setfacl -m u:carol:rw- /srv/dac-plain/report.txt
setfacl: /srv/dac-plain/report.txt: Operation not supported
```

6. Hit the ext4 attribute-size ceiling. The error is the interesting part.

```console
# setfattr -n user.blob -v "$(head -c 3000 /dev/zero | tr '\0' A)" report.txt && echo 'accepted'
accepted
# setfattr -n user.blob2 -v "$(head -c 8000 /dev/zero | tr '\0' B)" report.txt
setfattr: report.txt: No space left on device
# df -h /srv/dac-lab | tail -1
/dev/loop0  241M  2.1M  222M   1% /srv/dac-lab
# setfattr -x user.blob report.txt
```

7. Remove attributes and dump/restore a whole tree.

```console
# getfattr -R -d -m '.*' --absolute-names /srv/dac-lab/project > /var/tmp/project.xattr
# setfattr -x user.owner_team report.txt
# setfattr -x user.retention  report.txt
# getfattr -d report.txt
# setfattr --restore=/var/tmp/project.xattr
# getfattr -d report.txt
# file: report.txt
user.owner_team="payments-sre"
user.retention="2555d"
```

### Comprehension check

- **Q7.1** Name the four extended-attribute namespaces and state, for each, who may read and who may write.
- **Q7.2** Why does a bare `getfattr file` show nothing on a file that demonstrably has an SELinux label?
- **Q7.3** In step 3, `carol` could not even *see* `trusted.audit_tag`. Contrast this with `security.selinux`, which she could see. What design property of the `trusted` namespace does this illustrate, and name one real subsystem that relies on it.
- **Q7.4** POSIX ACLs are stored in `system.posix_acl_access`. Why is that namespace not writable with `setfattr` even as root on most kernels, and what would go wrong if it were freely writable?
- **Q7.5** In step 6, `df` reported 222 MiB free and the kernel still returned `ENOSPC`. Explain the real constraint on ext4 and name the filesystem feature that lifts it.
- **Q7.6** `user.*` attributes cannot be set on symbolic links or on directories owned by another user when the sticky bit is set. What is the reasoning behind each restriction?
- **Q7.7** Which of these is *not* stored as an extended attribute: file capabilities, SELinux context, POSIX ACL, the SUID bit, IMA measurement?

---

## Exercise 8 — Preserving DAC metadata across copy, archive, and migration

### Steps

1. Build a reference file carrying everything: mode, ACL, and xattrs.

```console
# cd /srv/dac-lab/project
# chown root:devops report.txt ; chmod 640 report.txt
# setfacl -m u:carol:rw-,g:payroll:r-- report.txt
# setfattr -n user.owner_team -v 'payments-sre' report.txt
# ls -l report.txt
-rw-rw----+ 1 root devops 3030 Aug 24 11:31 report.txt
```

2. Copy with three different flag sets and compare what survives.

```console
# mkdir -p /srv/dac-lab/copies
# cp                  report.txt /srv/dac-lab/copies/plain.txt
# cp -p               report.txt /srv/dac-lab/copies/preserve-p.txt
# cp --preserve=all   report.txt /srv/dac-lab/copies/preserve-all.txt

# for f in /srv/dac-lab/copies/*; do
>   printf '=== %s\n' "$f"
>   getfacl -c "$f" 2>/dev/null | grep -E 'carol|payroll' || echo '  (no extended ACL)'
>   getfattr --only-values -n user.owner_team "$f" 2>/dev/null && echo || echo '  (no user xattr)'
> done
=== /srv/dac-lab/copies/plain.txt
  (no extended ACL)
  (no user xattr)
=== /srv/dac-lab/copies/preserve-all.txt
user:carol:rw-
group:payroll:r--
payments-sre
=== /srv/dac-lab/copies/preserve-p.txt
user:carol:rw-
group:payroll:r--
  (no user xattr)
```

3. Copy to the crippled filesystem and read the diagnostics.

```console
# cp --preserve=all report.txt /srv/dac-plain/report2.txt
cp: preserving permissions for '/srv/dac-plain/report2.txt': Operation not supported
cp: setting attribute 'user.owner_team' for '/srv/dac-plain/report2.txt': Operation not supported
# cp -a report.txt /srv/dac-plain/report3.txt
# ls -l /srv/dac-plain/report3.txt
-rw-r-----. 1 root devops 3030 Aug 24 11:31 /srv/dac-plain/report3.txt
```

4. Archive with `tar` and confirm the flags are not optional.

```console
# tar -cf /var/tmp/naive.tar   -C /srv/dac-lab project
# tar --acls --xattrs --xattrs-include='*' -cf /var/tmp/full.tar -C /srv/dac-lab project
# mkdir -p /srv/dac-lab/restore-naive /srv/dac-lab/restore-full
# tar -xf /var/tmp/naive.tar -C /srv/dac-lab/restore-naive
# tar --acls --xattrs --xattrs-include='*' -xf /var/tmp/full.tar -C /srv/dac-lab/restore-full
# getfacl -c /srv/dac-lab/restore-naive/project/report.txt | grep -c carol
0
# getfacl -c /srv/dac-lab/restore-full/project/report.txt | grep -c carol
1
# getfattr --only-values -n user.owner_team /srv/dac-lab/restore-full/project/report.txt; echo
payments-sre
```

5. Same test with `rsync`.

```console
# rsync -a   /srv/dac-lab/project/ /srv/dac-lab/rsync-a/
# rsync -aAX /srv/dac-lab/project/ /srv/dac-lab/rsync-aAX/
# getfacl -c /srv/dac-lab/rsync-a/report.txt   | grep -c carol
0
# getfacl -c /srv/dac-lab/rsync-aAX/report.txt | grep -c carol
1
```

6. Confirm that `mv` within one filesystem preserves everything, because it is a `rename(2)`.

```console
# mv report.txt report-renamed.txt
# getfacl -c report-renamed.txt | grep -c -E 'carol|payroll'
2
# getfattr --only-values -n user.owner_team report-renamed.txt; echo
payments-sre
# mv report-renamed.txt report.txt
```

### Comprehension check

- **Q8.1** `cp -p` kept the ACL but dropped the `user.*` attribute. Which attribute classes does `--preserve=mode` cover, and which flag is needed for the rest?
- **Q8.2** In step 3, `cp --preserve=all` printed two errors while `cp -a` printed none, and both produced the same degraded file. Why does the more convenient flag hide the failure, and what is the operational consequence during a data migration?
- **Q8.3** A migration script uses `tar -cf` on a source volume where authorisation depends on ACLs. The restore looks complete — same file count, same byte counts, `md5sum` matches. What has been silently lost, and which single verification step would have caught it?
- **Q8.4** `rsync -a` does *not* imply `-A -X`. Give the reason this is the correct default from rsync's point of view, and state the flag set you would standardise on for a Linux-to-Linux server migration.
- **Q8.5** `mv` preserved every attribute in step 6 without any flags. Would that still be true if the destination were `/srv/dac-plain`? Explain what `mv` does when `rename(2)` returns `EXDEV`.
- **Q8.6** Which of `install -m 0640`, `cp -a`, `git checkout`, and `rpm -i` will reproduce a file's ACL on the target host? Justify each answer.

---

## Exercise 9 — Diagnosis: four failures that look identical

Each scenario below reproduces a real "Permission denied" with a different root cause. Reproduce it, diagnose it with tools, then fix it.

### Steps

1. **Stale group membership.** Add `carol` to `devops` and show that an existing session is unaffected.

```console
# usermod -aG devops carol
# id carol
uid=1003(carol) gid=1003(carol) groups=1003(carol),1004(devops)
# sudo -u carol id -nG            # fresh process: sees the new group
carol devops
```

Simulate a long-lived session that predates the change:

```console
# setsid --fork sleep 600 &
# grep Groups /proc/$(pgrep -n sleep)/status
Groups: 0
```

2. **Mask, not group.** Restore the mask trap and diagnose it correctly.

```console
# cd /srv/dac-lab/project
# setfacl -b report.txt ; chmod 640 report.txt
# setfacl -m u:carol:rw- report.txt ; chmod g=r report.txt
# ls -l report.txt
-rw-r-----+ 1 root devops 3030 Aug 24 11:52 report.txt
# sudo -u carol sh -c 'echo x >> report.txt'
sh: line 1: report.txt: Permission denied
# getfacl -c report.txt
user::rw-
user:carol:rw-			#effective:r--
group::r--
mask::r--
other::---
# setfacl -m m::rw- report.txt
# sudo -u carol sh -c 'echo x >> report.txt' && echo FIXED
FIXED
```

3. **A parent directory in the path.** Break traversal three levels up.

```console
# chmod 750 /srv/dac-lab
# sudo -u carol cat /srv/dac-lab/project/report.txt
cat: /srv/dac-lab/project/report.txt: Permission denied
# namei -om /srv/dac-lab/project/report.txt
f: /srv/dac-lab/project/report.txt
 drwxr-xr-x root root /
 drwxr-xr-x root root srv
 drwxr-x--- root root dac-lab
 drwxr-xr-x root root project
 -rw-rw----+ root devops report.txt
# chmod 755 /srv/dac-lab
# sudo -u carol cat /srv/dac-lab/project/report.txt >/dev/null && echo FIXED
FIXED
```

4. **A mount option, not a permission.** Show that the mode is irrelevant when the filesystem refuses.

```console
# mount -o remount,nosuid /srv/dac-lab
# ls -l /srv/dac-lab/project/idcopy
-rwxr-xr-x. 1 alice root 39784 Aug 24 10:30 /srv/dac-lab/project/idcopy
# chown root:root /srv/dac-lab/project/idcopy ; chmod 4755 /srv/dac-lab/project/idcopy
# sudo -u carol /srv/dac-lab/project/idcopy
uid=1003(carol) gid=1003(carol) groups=1003(carol),1004(devops)
# mount -o remount,suid /srv/dac-lab
# sudo -u carol /srv/dac-lab/project/idcopy
uid=1003(carol) gid=1003(carol) euid=0(root) groups=1003(carol),1004(devops)
```

5. **The generic escalation ladder.** Run this checklist against any DAC denial.

```console
# ls -l   <file>                  # mode, owner, group, and the '+' / '.' marker
# getfacl <file>                  # extended entries and #effective:
# namei -om <path>                # every component of the path
# findmnt -no OPTIONS -T <path>   # ro, nosuid, noexec, noacl, nouser_xattr
# id <user>                       # groups as currently defined
# grep Groups /proc/<pid>/status  # groups as the running process sees them
# ausearch -m AVC -ts recent      # if the answer is "SELinux", not DAC
```

### Comprehension check

- **Q9.1** In step 1, `id carol` and `/proc/<pid>/status` disagree. Which one describes what the kernel will enforce for that process, and why? Name two ways to obtain the new group without a full logout.
- **Q9.2** In step 2, which single line of `getfacl` output is the diagnosis? Why is `ls -l` actively misleading here?
- **Q9.3** `namei -om` in step 3 showed that the failure was two directories above the target. Write the one-sentence rule about how the kernel walks a path.
- **Q9.4** In step 4 the SUID bit was present and the binary was root-owned, yet no escalation occurred. Which layer overrode DAC, and where would you look first if a production `sudo` suddenly stopped elevating?
- **Q9.5** A denial persists even though `ls -l`, `getfacl`, `namei` and `findmnt` are all clean, and the process runs as `root`. Name three mechanisms outside DAC that can still deny the operation, and the command that identifies each.

---

## Cleanup

```console
# umount /srv/dac-lab /srv/dac-plain
# rmdir  /srv/dac-lab /srv/dac-plain
# rm -f  /var/tmp/dac-lab.img /var/tmp/dac-plain.img
# rm -f  /var/tmp/project.acl /var/tmp/project.xattr /var/tmp/naive.tar /var/tmp/full.tar
# userdel -r alice ; userdel -r bob ; userdel -r carol
# groupdel devops  ; groupdel payroll
```

---

## References

- LPI, *Exam 303 Objectives (303-300)* — <https://www.lpi.org/our-certifications/exam-303-objectives/>
- `acl(5)` — POSIX ACL semantics, mask, default-ACL inheritance, umask interaction — <https://man7.org/linux/man-pages/man5/acl.5.html>
- `setfacl(1)` — <https://man7.org/linux/man-pages/man1/setfacl.1.html> · `getfacl(1)` — <https://man7.org/linux/man-pages/man1/getfacl.1.html>
- `xattr(7)` — namespaces and their access rules — <https://man7.org/linux/man-pages/man7/xattr.7.html>
- `setfattr(1)` — <https://man7.org/linux/man-pages/man1/setfattr.1.html> · `getfattr(1)` — <https://man7.org/linux/man-pages/man1/getfattr.1.html>
- `inode(7)` — mode word layout, SUID/SGID/sticky semantics — <https://man7.org/linux/man-pages/man7/inode.7.html>
- `path_resolution(7)` — directory traversal rules — <https://man7.org/linux/man-pages/man7/path_resolution.7.html>
- `umask(2)` — <https://man7.org/linux/man-pages/man2/umask.2.html> · `open(2)` — <https://man7.org/linux/man-pages/man2/open.2.html>
- `chown(2)` — SUID/SGID and capability clearing on ownership change — <https://man7.org/linux/man-pages/man2/chown.2.html>
- `chmod(1)` — <https://man7.org/linux/man-pages/man1/chmod.1.html>
- `ext4(5)` — `acl`/`noacl`, `user_xattr`/`nouser_xattr` mount options — <https://man7.org/linux/man-pages/man5/ext4.5.html>
- Linux kernel documentation, *ext4 Data Structures and Algorithms* (extended attributes, `ea_inode`) — <https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html>
- GNU coreutils manual, `cp` invocation (`--preserve`, `-a` reduced diagnostics) — <https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html>
- `capabilities(7)` — file capabilities as an alternative to SUID — <https://man7.org/linux/man-pages/man7/capabilities.7.html>
- `mount(8)` — `nosuid`, `noexec`, `ro` — <https://man7.org/linux/man-pages/man8/mount.8.html>

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 0 — Lab environment

**Q0.1** No. ACLs are enabled. `/proc/self/mounts` and `findmnt` print only options that *differ from the kernel default* for that filesystem, plus options the VFS tracks generically. For ext4 on current kernels, `acl` and `user_xattr` are the compiled-in defaults, so they are invisible; `noacl` and `nouser_xattr` are deviations and therefore printed. **General rule: absence of an option in the mount list means "default", not "off".** To learn the actual state you must know the filesystem's defaults, or test empirically (`setfacl` on a scratch file).

**Q0.2** They live at different layers. `ext_attr` in `Filesystem features` is an **on-disk format flag** in the superblock: the filesystem's metadata layout is capable of storing extended attributes at all. `Default mount options` is a superblock field written by `mkfs`/`tune2fs -o` that supplies default *mount-time* options, which the kernel merges with whatever `mount -o` specifies. A filesystem can have `ext_attr` on disk and still be mounted `nouser_xattr` — the capability exists, the policy denies it.

**Q0.3** In order:
1. **Filesystem type and format** — does it support ACLs at all? (`tune2fs -l`, or the fs type itself: FAT/exFAT/NTFS-3G without special options, and older `tmpfs`, do not.)
2. **Mount options** — `findmnt -no OPTIONS -T <path>`, looking for `noacl` and for `ro`.
3. **Kernel build** — `CONFIG_EXT4_FS_POSIX_ACL` / `CONFIG_FS_POSIX_ACL`, via `zgrep POSIX_ACL /proc/config.gz` or `grep POSIX_ACL /boot/config-$(uname -r)`.
Only after all three does "the tool is broken" become plausible. A fourth, non-DAC candidate: the operation is being blocked by SELinux/AppArmor, which reports different errno values but is often misread.

### Exercise 1 — Ownership and the mode word

**Q1.1** `0x81a4` = `0o100644`. The upper bits `0o100000` (`S_IFREG`) are the **file type**, taken from the `S_IFMT` mask `0o170000`. The lower 12 bits `0o0644` are the **permission word**: 3 special bits (SUID `04000`, SGID `02000`, sticky `01000`) plus the three rwx triads. `%A` renders the type as the leading character of `-rw-r--r--`; `%a` prints only the low 12 bits.

**Q1.2** `+` and `-` are **relative** operators: they add or remove the named bits and leave everything else in that triad untouched — `g+w` on `640` set only the group write bit, giving `660`. `=` is an **absolute assignment** for the triads it names: `o=r` set the *entire* other triad to `r--`, which both added `r` and would have cleared any `w`/`x` there. Consequence in practice: `chmod g+w` is safe in a script that must not disturb existing state; `chmod g=w` is a silent revocation of group read and execute.

**Q1.3** The **write bit on the directory** `locked`, combined with its execute bit (`chmod 777`). `unlink(2)` modifies the directory's list of names; it never touches the target inode's permissions. This is why the sticky bit exists (Exercise 4) and why "the file is `chmod 000`" is not a deletion defence.

**Q1.4** It changed the mode of the **target** (`report.txt`), because `chmod(2)` follows symlinks and `chmod(1)` has no `-h`. On Linux, symlink mode bits are stored but **never consulted** — they are always shown as `lrwxrwxrwx` and are meaningless; permission on a symlink is decided by the containing directory and by the target. There is no `lchmod(2)` in glibc on Linux for this reason (some other Unixes have one and honour symlink modes). `chown` *does* have `-h` because symlink ownership is meaningful: it is checked by the sticky-bit rule when unlinking.

**Q1.5** The kernel evaluates **exactly one triad** and stops. The order is: if the effective UID matches the owner → use the owner triad, final. Else if the effective GID or any supplementary group matches the file group → use the group triad, final. Else → other. Since `alice` is the owner, she gets the owner triad. If the owner triad is `---` and the group triad is `rw-`, `alice` is **denied**, despite being in `devops` — the group triad is never consulted for her. Non-owners in `devops` get `rw-`. This "first match wins, no accumulation" rule is the single most common misconception about Unix permissions.

### Exercise 2 — Path resolution

**Q2.1** On a directory: `r` grants the right to **enumerate the names** it contains (`readdir`, i.e. `ls`). `x` — the *search* bit — grants the right to **resolve a name through it** (`stat`, `open`, `cd`, and using it as a component of any longer path). They are independent. `r` without `x` gives you names you cannot use; `x` without `r` gives you a directory where you must already know the name to reach the file.

**Q2.2** With `r` but no `x`, `ls` can call `getdents` to obtain the names but cannot `stat` each entry — every `stat` needs search permission on the containing directory. `ls -l` therefore prints the name it knows and `?` for every field that would have come from the inode, using `d` only because `getdents` returns a coarse file type from the directory entry itself (`d_type`).

**Q2.3** `711` on a home directory allows any user to **traverse** into it — so `/home/alice/public_html/index.html` still works for the web server or for a `~alice/.ssh/authorized_keys` lookup — while preventing anyone from **listing** its contents. It is not confidentiality: an attacker who guesses or brute-forces a filename gets it. `750` (group-readable, world-nothing) is preferred when no service needs blind traversal, because it removes even the guessing channel; the standard modern default (`HOME_MODE 0700` in `/etc/login.defs`) removes group access as well.

**Q2.4** `ls -l index.html` shows the permissions of one inode. `namei -om` walks and prints the mode, owner and group of **every component of the path** — `/`, `srv`, `app`, `public`, `index.html` — plus symlink resolution and mount points. The 403 almost always comes from a missing `x` on an intermediate directory (frequently `/srv/app` created `750 root:root`), which no amount of inspecting the leaf file will reveal.

### Exercise 3 — umask

**Q3.1** Because the mask does not choose the permissions — it only *removes* bits from what the creating program asks for. `open(2)` with `O_CREAT` conventionally requests mode `0666` (no execute, ever) and `mkdir(2)` requests `0777` (execute needed for traversal). `0666 & ~0077 = 0600`; `0777 & ~0077 = 0700`.

**Q3.2** Bitwise, not arithmetic: `mode & ~umask`. The distinction matters because subtraction gives wrong answers whenever the mask removes a bit the mode never had. Example: mode `0666`, umask `0033`. Bitwise: `0666 & ~0033 = 0644`. Arithmetic subtraction would give `0633`.

**Q3.3** Because the umask constrains the requested mode, and different programs request different modes. `touch` calls `open(..., 0666)` → `0644`. A linker/compiler calls `open(..., 0777)` for an output it intends to be executable → `0755`. The umask is identical in both cases; the *request* differs. Same reason `install -m 0755` and `mkdir` produce executable results while `>` redirection never does.

**Q3.4** (a) **cron does not run your login shell profile.** `crond` starts jobs from a minimal environment; `~/.bashrc`/`~/.profile` — where an interactive `umask 007` usually lives — is not sourced, so the job inherits `crond`'s umask, typically `022`. Fix: set the umask explicitly inside the job or the script (`umask 007` as the first line), or use a systemd timer with `UMask=0007` in the service unit. (b) **The umask is set in an interactive-only path.** Many distributions guard `~/.bashrc` with an early `case $- in *i*) ;; *) return;; esac`, so non-interactive shells skip everything after it. Fix: put the `umask` call before that guard, or better, set it declaratively in the unit/crontab rather than in a shell rc file. A third, less common cause: a default ACL on the destination directory overriding the umask entirely (Exercise 6).

**Q3.5** The assumption is the **user private group** scheme: every user has a primary group containing only themselves (`alice:alice`), so the group bits grant access to nobody but the user. Under that assumption `002` costs nothing and makes SGID collaborative directories work naturally. It fails the moment a user's primary group is a **shared** group — a legacy `users` group, an LDAP/AD-sourced primary group such as `Domain Users`, or a service account deliberately placed in a shared group. Then `umask 002` makes every file that user creates writable by the entire group, everywhere on the system. Verify with `awk -F: '$4 < 1000 || $3 != $4' /etc/passwd` and by checking the directory service's primary-group mapping before enabling `USERGROUPS_ENAB`.

### Exercise 4 — SUID, SGID, sticky

**Q4.1** The special bit is displayed **in the position of the corresponding execute bit**, and its case reports whether that execute bit is also set:

| Display | Special bit | Execute bit | Meaning |
|---|---|---|---|
| `-rws------` | SUID | set | works: runs with the owner's UID |
| `-rwS------` | SUID | clear | set but inert — nothing to execute |
| `----rws---` | SGID | set | runs with the file's group |
| `----rwS---` | SGID (on a file) | clear | on a *file*: inert. On a *directory*: normal and meaningful — group inheritance, no group search |
| `drwxrwxrwt` | sticky | `o+x` set | restricted deletion, world-traversable |
| `drwxrwxrwT` | sticky | `o+x` clear | restricted deletion, others cannot traverse |

Lowercase = special bit **and** execute bit. Uppercase = special bit **without** execute bit. The important non-obvious case is `drwxr-S---` on a directory, which is perfectly normal: SGID on directories has nothing to do with execution.

**Q4.2** For an unprivileged caller, `chown(2)` must clear SUID/SGID or the call would be a trivial escalation: create a file, make it SUID, then give it to root. Linux's `notify_change()` applies `ATTR_KILL_SUID`/`ATTR_KILL_SGID` on ownership change of a regular file (SGID only when the group-execute bit is set, so that the mandatory-locking encoding `-rw-r-Sr--` survives). POSIX explicitly leaves the **privileged** case implementation-defined, and Linux's behaviour has varied across versions. Therefore: **never treat `chown` as attribute-preserving.** Always re-apply the mode afterwards. This is why RPM `%attr(4755,root,root)` and `install -m 4755 -o root` set ownership and mode as one specified operation rather than relying on ordering. The same event also clears `security.capability` — for *any* caller, including root — so file capabilities are lost on `chown` and on any write to the file.

**Q4.3** The kernel's `execve` path handles `#!` in `fs/binfmt_script.c`: it re-targets execution at the **interpreter** and passes the script as an argument. The SUID bit belongs to the script's inode, not the interpreter's, and honouring it would mean handing an attacker-controlled argument list, environment and `/dev/fd` race window to a privileged interpreter. Linux therefore ignores SUID/SGID on scripts unconditionally. Alternatives, best first: (1) `sudo` with a precise `Cmnd_Alias` and `NOPASSWD` entry, which is auditable and gives per-command policy; (2) a **file capability** on a small compiled helper (`setcap cap_net_bind_service+ep`), granting one privilege instead of all of root; (3) a `systemd` unit with the privilege and a socket/D-Bus trigger; (4) a minimal SUID **C wrapper** that sanitises `PATH`/`IFS`/environment and `execve`s an absolute path — the traditional answer, and the easiest to get wrong.

**Q4.4** The **SGID bit on the directory** (`2` in `chmod 2770`). It makes new entries inherit the directory's group instead of the creator's primary group — this is what makes shared project directories work without every user having to `newgrp`. `subdir` additionally inherited the **SGID bit itself** (`drwxr-s`), so the behaviour propagates recursively down new subtrees. Regular files do not inherit the bit, only the group. Note what SGID does *not* do: it does not touch the permission bits, so `from-alice` came out `644` (from umask `022`) — group `devops` gets read but not write. Guaranteeing group *write* requires either a `002` umask or a default ACL.

**Q4.5** The sticky bit on a directory restricts **`unlink(2)`, `rmdir(2)` and `rename(2)`** of entries within it to: the file's owner, the directory's owner, or a process with `CAP_FOWNER`. That is all. It says nothing about the file's own contents: `bob` had `w` on `alice.tmp` via the `other` triad (`644`), so `open(O_TRUNC)` and writing were allowed by ordinary DAC. The sticky bit protects the **namespace**, not the **data**. Practical consequence: a world-writable sticky directory still permits content destruction; if that matters, fix the file modes or the umask, not the directory bit.

**Q4.6** For `find -perm`:
- `-perm 4755` — **exact** match of the whole 12-bit permission word. `-rwsr-sr-x` would not match.
- `-perm -4000` — **all** of the listed bits are set (AND). `-perm -6000` means SUID **and** SGID together.
- `-perm /6000` — **any** of the listed bits is set (OR). This is the correct form for "find everything SUID or SGID". (The obsolete `+` syntax meant the same and was removed in GNU findutils 4.5.12.)
Also use `-xdev` to stay on one filesystem, and remember that `-perm -4000` alone will match directories and symlinks — add `-type f` for a meaningful SUID audit.

**Q4.7** Beyond `mount -o nosuid` (per filesystem — check `findmnt -no OPTIONS -T <path>` and `/etc/fstab`):
- **Namespaces/containers** — files in a user namespace mapped without the relevant privilege, and every mount inside an unprivileged user namespace, are implicitly `nosuid`.
- **`no_root_squash`/`root_squash` on NFS**, plus the server-side `nosuid` export option.
- **MAC policy** — SELinux can deny the `execute_no_trans`/domain transition even where DAC allows it; the symptom is identical.
- **The bit being stripped** by a preceding `chown` or by a package/config-management run (Q4.2).
- **`fs.suid_dumpable` / `fs.protected_*`** sysctls do not disable SUID but change adjacent behaviour and are worth checking during triage.

### Exercise 5 — POSIX ACLs and the mask

**Q5.1** Six types:

| Entry | Text form | Notes |
|---|---|---|
| `ACL_USER_OBJ` | `user::rwx` | the owner. **Required.** |
| `ACL_USER` | `user:name:rwx` | a named user. Zero or more. |
| `ACL_GROUP_OBJ` | `group::rwx` | the owning group. **Required.** |
| `ACL_GROUP` | `group:name:rwx` | a named group. Zero or more. |
| `ACL_MASK` | `mask::rwx` | **Required** if any named entry exists. |
| `ACL_OTHER` | `other::rwx` | everyone else. **Required.** |

A *minimal* ACL is exactly `user::`, `group::`, `other::` — precisely the classic mode word, which is why every file has an ACL even when `ls -l` shows no `+`. An ACL containing at least one named entry (or a mask) is an *extended* ACL and gets the `+` marker.

**Q5.2** The mask is an upper bound on **all named users (`ACL_USER`), all named groups (`ACL_GROUP`), and the owning group (`ACL_GROUP_OBJ`)** — collectively the "group class". Effective permission = entry ∧ mask. Immune: **`user::` (the owner)** and **`other::`**. This is why you cannot lock the owner out with a mask, and why tightening the mask never affects world access.

**Q5.3** `ls -l`'s group field displays the **mask**, not `group::`, whenever an extended ACL is present — so `rw-` was the ceiling for the group class, while `group::` itself was still `r--`, and `bob` is only ever evaluated against `group::`. In one sentence: *on a file with a `+`, the middle triad of `ls -l` is the mask, so it shows the maximum any group-class entry could have, not what the owning group actually has.*

**Q5.4** On a file with an extended ACL, `chmod` sets `user::` from the owner digit, **`mask::` from the group digit**, and `other::` from the other digit; `group::` is left untouched. Since the mask caps every named entry, one `chmod` can revoke access for users who are not mentioned anywhere in the `chmod` command. The operational hazard: **any tool that enforces a mode idempotently — Ansible `file: mode=0640`, Puppet `file { mode => }`, a `chmod -R` in a deploy script, `rpm --setperms`, `restorecon`-adjacent hardening playbooks — will silently strip ACL grants on every run**, producing an intermittent outage that reappears each converge. Detection: `getfacl -R -s` before and after, or watch for `#effective:` lines appearing.

**Q5.5** `#effective:` is printed when an entry's **granted** permissions exceed what the mask permits; it shows the intersection that is actually enforced. It never appears on `user::` because `ACL_USER_OBJ` is not in the group class and is not subject to the mask (same for `other::`). Reading rule: if you see `#effective:` anywhere, the mask is your problem, not the individual grant.

**Q5.6**
- `setfacl -x u:carol file` — remove **one specific entry**; the rest of the ACL, including other named entries and the mask, survives (the mask is recalculated).
- `setfacl -b file` (`--remove-all`) — remove **all extended access entries**, leaving only the three base entries. The file loses its `+`. Default ACLs are *retained*.
- `setfacl -k dir` (`--remove-default`) — remove **only the default ACL**. The access ACL is untouched. Meaningless on non-directories.
Combine with `-R` for recursion; `setfacl -R -b -k` is the full reset of a tree.

**Q5.7** (a) The **mask** is more restrictive than the grant — check `getfacl` for `#effective:`. (b) Creating a file needs **`w` *and* `x` on the directory** (`x` to resolve names within it); an ACL of `rw-` grants write but not search, so `open(O_CREAT)` fails. Grant `rwx`. Two further candidates worth checking: a missing `x` on an ancestor directory (`namei -om`), and a read-only or `noacl` mount.

**Q5.8** `find -perm` can only test the **mode word**, and on an ACL-bearing file the mode word's group field is the *mask* — so `find -perm -g+w` both misses grants that exist only as named entries and produces false positives from a permissive mask. `getfacl -R -s` (`--skip-base`) walks the tree and emits output **only for objects with a non-trivial ACL**, which is exactly the set that a mode-based audit cannot see. Note that GNU `find` has no `-acl` predicate (that is FreeBSD's `find`); `getfacl -R -s -p` is the portable Linux idiom.

### Exercise 6 — Default ACLs and inheritance

**Q6.1** From `acl(5)`: *if a default ACL is associated with a directory, the mode parameter passed by the creating call and the directory's default ACL determine the new object's ACL — the process's file creation mask is **not** used.* If no default ACL exists, the umask applies as usual. So a default ACL **completely overrides the umask** for that directory. This is the mechanism behind incidents where a `umask 077` hardening baseline is deployed fleet-wide and audits still find group-readable files: some data directory carries a default ACL, and no amount of umask policy will affect it. Detect with `getfacl -R -s | grep default`.

**Q6.2** `touch` calls `open(..., O_CREAT, 0666)`. Step 2 of the inheritance algorithm intersects **the entries corresponding to the mode word's triads** — `user::`, `mask::` (standing in for the group triad because a mask exists), and `other::` — with that mode. The group triad of `0666` is `rw-`, so `mask::` became `rw-`, and `carol`'s `rwx` grant is capped to `#effective:rw-`. The named entry itself still records `rwx`; only its effective value is reduced. Note the grant is *not* rewritten — raising the mask later (`setfacl -m m::rwx`) restores the `x` without re-granting.

**Q6.3** A default ACL is inheritance *template* metadata, and only directories can have children. Files carry only an access ACL. When a directory is created inside a directory with a default ACL, it receives **two** ACLs: an access ACL (derived from the parent's default, intersected with `mkdir`'s `0777`) and a copy of the parent's default ACL, so the rule keeps propagating. A file receives only the derived access ACL, and propagation stops there. `setfacl -d` on a regular file is an error, as step 1 shows.

**Q6.4** Default ACLs are evaluated **once, at creation time**. They are a template, not a live inheritance link — nothing like an inherited Windows ACE that re-evaluates. Correct rollout order for a live data directory: **(1)** update the default ACL so future objects are correct, then **(2)** apply the equivalent access ACL recursively (`setfacl -R -m`) to fix everything that already exists. Doing only (1) leaves an ever-shrinking but never-vanishing set of legacy files; doing only (2) means the next file created reintroduces the problem. Both are required, and the same is true of revocation.

**Q6.5** `X` (capital) grants execute/search **only if the object is a directory, or already has at least one execute bit set for some user class**. `x` (lowercase) grants it unconditionally. Over a mixed tree, `setfacl -R -m u:carol:rx` would make every data file executable — noise at best, and a real problem for anything scanning for executables or for a `noexec`-adjacent policy. `rX` gives directories the search bit they need while leaving plain data files non-executable, and correctly preserves the execute bit on files that legitimately have one. `chmod` has the same `X` semantics, for the same reason.

**Q6.6**

| | SGID directory | Default ACL |
|---|---|---|
| Guarantees | new objects get **group = `devops`** | new objects get the **specified permission entries**, for any number of users and groups |
| Does not guarantee | any particular permission *bits* — those still come from the umask, so a `077` process yields `-rw------- alice devops`, unreadable by the group | the group **ownership**; that still comes from the creator's primary group unless SGID is also set |
| Scope | one group only (the directory's) | arbitrarily many named users and groups |
| Overrides umask | no | yes |

Neither alone is sufficient. The production pattern is **both**: `chgrp devops dir && chmod 2770 dir && setfacl -m g:devops:rwx -d -m g:devops:rwx dir`. SGID fixes ownership and propagates itself; the default ACL fixes the bits regardless of any process's umask.

### Exercise 7 — Extended attributes

**Q7.1**

| Namespace | Read | Write | Purpose |
|---|---|---|---|
| `user.*` | anyone with `r` on the file | anyone with `w` on the file | free-form application metadata. Not permitted on symlinks or special files; on a sticky directory, only the owner may set them. |
| `trusted.*` | requires `CAP_SYS_ADMIN` | requires `CAP_SYS_ADMIN` | privileged metadata that must be **invisible** to unprivileged processes |
| `system.*` | mediated by the kernel subsystem that owns the attribute | same — not generally writable via `setfattr` | kernel-managed: `system.posix_acl_access`, `system.posix_acl_default` |
| `security.*` | typically world-readable | requires the owning LSM's permission | `security.selinux`, `security.capability`, `security.ima`/`evm` |

The read asymmetry between `trusted` and `security` is deliberate and is the whole point of having both.

**Q7.2** `getfattr`'s `-m` pattern defaults to `^user\.`, so a bare invocation lists only the `user` namespace. Widen it with `-m '.*'` (an explicit match-everything regex) or the conventional shorthand `-m -`; add `-d` to dump values. Corollary for scripting: **never conclude "this file has no xattrs" from a bare `getfattr`.**

**Q7.3** `trusted.*` is designed so that unprivileged processes cannot even learn of its existence — `listxattr` filters the namespace out entirely for callers without `CAP_SYS_ADMIN`, and `getxattr` returns `EPERM`/`ENODATA`. `security.selinux` is world-readable by design, because contexts are not secrets and userspace tools (`ls -Z`, `ps -Z`) must display them. The real subsystem relying on `trusted`: **overlayfs**, which stores whiteouts, opaque-directory markers and redirects in `trusted.overlay.*` — if an unprivileged process in the upper layer could see or forge those, it could manipulate the merged view. (Historically also used by Samba/`winbind` and by some HSM/backup products.)

**Q7.4** Because the ACL is not merely stored there — it is **cached in the in-memory inode** and consulted on every permission check, and it must satisfy structural invariants (a mask whenever named entries exist, exactly one of each required entry, entries sorted, a valid version header). The kernel exposes `system.posix_acl_access` through a dedicated xattr *handler* that parses, validates and installs the ACL, and simultaneously updates the mode word so `ls -l` stays consistent. `setfattr` cannot bypass that handler. If raw writes were allowed, a malformed blob would either desynchronise the mode word from the ACL — producing a file whose displayed permissions bear no relation to what is enforced — or be rejected as unparseable at check time with undefined fallback behaviour. Use `setfacl`, which speaks the same interface correctly.

**Q7.5** On ext4 without the `ea_inode` feature, **all** extended attributes for one inode must fit either in the inode's spare space (`extra_isize`) or in a **single filesystem block** — 4 KiB by default. The limit is per-inode and per-block, not per-volume, so free space on the device is irrelevant and the kernel reports `ENOSPC` regardless. Enable `ea_inode` (`tune2fs -O ea_inode`, or `mkfs.ext4 -O ea_inode`) to let large values spill into dedicated inodes, raising the per-value ceiling to 64 KiB. XFS has a different layout and supports 64 KiB values natively. Practical rule: **extended attributes are for labels and small metadata, not for payload.** A backup product storing multi-kilobyte manifests in xattrs will fail intermittently on ext4 depending on how many other attributes (SELinux label, ACL, capabilities) are already present.

**Q7.6** *Symlinks and special files:* the kernel refuses `user.*` there because those inodes have no meaningful permission bits of their own — a symlink is always `lrwxrwxrwx` — so the "you may write `user.*` if you may write the file" access rule would degenerate into "anyone may write". *Sticky directories:* a world-writable `/tmp`-style directory would otherwise let any user attach unbounded attribute data to *other users'* directories, both a disk-quota and a metadata-integrity problem. Restricting it to the directory's owner mirrors exactly the reasoning behind the sticky bit itself.

**Q7.7** The **SUID bit**. It is part of the inode's mode word (`i_mode`), a first-class inode field, not an extended attribute. The other four are all xattrs: file capabilities → `security.capability`; SELinux context → `security.selinux`; POSIX ACL → `system.posix_acl_access` / `system.posix_acl_default`; IMA measurement → `security.ima` (with `security.evm` for the HMAC). This distinction is exactly why `cp` needs `--preserve=xattr` for capabilities and ACLs but gets the SUID bit from `--preserve=mode`.

### Exercise 8 — Preserving DAC metadata

**Q8.1** `--preserve=mode` covers the **permission bits (including SUID/SGID/sticky) and access control lists** — coreutils treats the ACL as part of "mode", which is coherent because the ACL and the mode word are two views of one thing. It does **not** cover general extended attributes. `cp -p` is `--preserve=mode,ownership,timestamps`, hence ACL yes, `user.*` no. For everything you need `--preserve=xattr`, or `--preserve=all` / `-a`, which additionally covers links and SELinux context.

**Q8.2** `cp -a` is documented as *"equivalent to `-dR --preserve=all` with reduced diagnostics"* — it deliberately suppresses xattr/ACL preservation failures, on the theory that `-a` is used for casual mirroring where a destination that cannot hold the metadata is not an error worth aborting for. `--preserve=all` (and `--preserve=xattr` specifically) reports the failure. **Operational consequence:** a migration performed with `cp -a` onto a destination that lacks ACL or xattr support completes with **exit status 0 and no output**, and the loss is discovered later as an authorisation incident. For migrations, use `cp -dR --preserve=all` (or `rsync -aAX --info=progress2`) so failures are loud, and verify afterwards rather than trusting the exit code.

**Q8.3** Every **ACL** and every **extended attribute** — named-user and named-group grants, default ACLs on directories, SELinux contexts, file capabilities. Byte-identical content with an amputated authorisation model: after cutover, users who were granted access through named ACL entries are denied, and — worse in the other direction — files whose ACL was *restricting* an otherwise permissive mode become **more** accessible than before. `md5sum` and file counts cannot see any of it, because none of it is file content. The single catch-all verification: run `getfacl -R --absolute-names` and `getfattr -R -d -m '.*' --absolute-names` over source and destination and `diff` the two dumps. That one comparison covers ACLs, defaults, and all xattr namespaces the caller can read. (Run the `trusted.*` portion as root, or it will silently compare nothing.)

**Q8.4** rsync's defaults are conservative because ACLs and xattrs are **not portable across platforms or filesystems**: the same `-a` invocation is routinely used macOS↔Linux, Linux↔BSD, and onto FAT/SMB/S3-backed targets, where attempting to transfer them would fail or produce garbage. Making them opt-in keeps the common case working. For a Linux-to-Linux server migration, standardise on **`rsync -aAX --numeric-ids --hard-links --sparse`**: `-A` ACLs, `-X` xattrs (this is what carries SELinux contexts and file capabilities), and `--numeric-ids` so UIDs are not remapped through a `/etc/passwd` that may differ on the two hosts — an ID remap silently rewrites every ownership *and* every named ACL entry. Add `-H` when the source has hard links, or you will inflate the dataset and break inode-sharing assumptions.

**Q8.5** No. Within one filesystem, `mv` is a single `rename(2)` — the inode never moves, so mode, ownership, ACL, xattrs, timestamps and link count are preserved by construction, with no flags and no opportunity for loss. Across filesystems, `rename(2)` fails with **`EXDEV`**, and `mv` falls back to **copy-then-unlink**, using the equivalent of `--preserve=all`. At that point it is subject to exactly the same destination limitations as `cp`: onto `/srv/dac-plain` the ACL and `user.*` attributes cannot be written. `mv` does emit a diagnostic for the failed preservation, but the source file is still removed afterwards — **the degraded copy is all that remains.** Verify metadata before, not after, a cross-filesystem `mv`.

**Q8.6**
- **`install -m 0640`** — no. `install` creates a fresh file and sets exactly the specified mode; ACLs and xattrs are not carried (there is `-Z`/`--preserve-context` for SELinux, but nothing for POSIX ACLs). This is a feature: `install` exists to produce deterministic permissions.
- **`cp -a`** — yes, when the destination filesystem supports ACLs; and silently no when it does not (Q8.2).
- **`git checkout`** — no. Git stores exactly **one** permission bit per file: whether it is executable (mode `100644` vs `100755`), plus symlinks and gitlinks. No owner, no group, no ACL, no xattr. Permissions on checked-out files come from the umask. Anything security-relevant must be reasserted by the deployment step (`install`, a `chmod` in the unit, Ansible, `%attr` in a spec file), never assumed from the repository.
- **`rpm -i`** — yes for mode and ownership, from the `%attr`/`%defattr` directives recorded in the package header, and RPM also restores SELinux contexts and file capabilities. It does **not** carry POSIX ACLs: they are not part of the RPM file-info format, so a package cannot ship a named-user ACL entry. That must be applied post-install (`%post` scriptlet or configuration management).

### Exercise 9 — Diagnosis

**Q9.1** `/proc/<pid>/status` describes what will be enforced. Supplementary groups are part of a process's **credentials**, established at `setgroups(2)` time — normally by `login`/`sshd`/`sudo` via `initgroups(3)` — and then inherited across `fork` and `exec`. `usermod -aG` edits `/etc/group`, a *database*; it cannot reach into already-running processes. `id carol` shows the database view because `id` is a new process that reads the database directly. Obtaining the new group without a full logout: **(a)** `newgrp devops` or `sg devops -c '<cmd>'`, which start a new shell/command with re-initialised credentials (`newgrp` is SUID root precisely for this); **(b)** any freshly authenticated session — `sudo -u carol -i`, a new `ssh` login, a new desktop session, or `systemctl restart` for a service. For services, restarting the unit is the only reliable fix — reloading is usually not enough, since credentials are set at fork time.

**Q9.2** The line `user:carol:rw-` **`#effective:r--`**, corroborated by `mask::r--`. That single annotation says: the grant exists, and the mask is destroying it. `ls -l` is actively misleading because it renders `-rw-r-----+` — a listing whose group field (`r--`) is the *mask*, and which shows nothing at all about `carol`. Reading `ls -l` alone, the natural conclusion is "carol has no entry, add one" — and `setfacl -m u:carol:rw-` will appear to succeed while changing nothing, because it re-grants a permission that is already granted and then recalculates the mask... which in this case *would* actually fix it, obscuring the real lesson. The `+` character is the signal to stop reading `ls` and start reading `getfacl`.

**Q9.3** The kernel resolves a path **one component at a time, from left to right, requiring search (`x`) permission on every directory it passes through**; the leaf's own permissions are checked only if every preceding component was traversable. A denial can therefore originate anywhere along the path, and the error is indistinguishable from a denial on the target itself — which is exactly what `namei -om` exists to disambiguate.

**Q9.4** The **mount options** — `nosuid` on the filesystem — overrode DAC entirely. The kernel discards the SUID/SGID bits at `execve` time for any binary on a `nosuid` mount, and there is no error message: the program simply runs unprivileged, so the symptom is "the tool says permission denied" rather than "the tool refused to start". For a `sudo` that stopped elevating, check in this order: **(1)** `findmnt -no OPTIONS -T /usr/bin/sudo` for `nosuid`; **(2)** `ls -l /usr/bin/sudo` — the SUID bit is `-rwsr-xr-x root root`, and it is routinely destroyed by a `chown`, a botched `chmod -R`, or a restore from an archive taken without `--preserve=all`; **(3)** `getcap /usr/bin/sudo` if the distribution uses capabilities instead; **(4)** SELinux denials via `ausearch -m AVC -ts recent`. Note that modern sudo can also be built to use `CAP_SETUID` rather than SUID, in which case a `chown` or a write to the binary silently clears `security.capability` with the same result.

**Q9.5** Three mechanisms outside DAC, with the command that identifies each:

| Mechanism | Symptom | Diagnostic |
|---|---|---|
| **MAC — SELinux / AppArmor** | `EACCES` with everything else clean; root is not exempt | `ausearch -m AVC -ts recent`, `dmesg \| grep -i denied`, `getenforce`, `aa-status`. Confirm by testing with `setenforce 0` (never leave it there). |
| **Immutable / append-only file attributes** | `EPERM` on write or unlink even as root | `lsattr <file>` → `----i--------` (immutable) or `-----a-------` (append-only). Clear with `chattr -i`; requires `CAP_LINUX_IMMUTABLE`. Distinct from ACLs and xattrs — these are `ioctl`-managed inode flags. |
| **Read-only mount, or a read-only device/snapshot** | `EROFS` — "Read-only file system" | `findmnt -no OPTIONS -T <path>` for `ro`; `dmesg` for the filesystem having been remounted read-only after an I/O or journal error. |

Further candidates worth knowing: **filesystem quota exhaustion** (`EDQUOT`, `quota -s -u <user>`, `repquota`); **seccomp or a systemd sandbox directive** — `ProtectSystem=strict`, `ReadOnlyPaths=`, `ProtectHome=`, `PrivateTmp=` — which are invisible from outside the unit (`systemctl show <unit> -p ProtectSystem,ReadOnlyPaths,ProtectHome`); **namespace mount propagation**, where the process sees a different filesystem tree than your shell does (`cat /proc/<pid>/mountinfo`); and **NFS `root_squash`**, where root is remapped to `nobody` on the server (`exportfs -v` on the server). The unifying lesson: DAC is the *first* gate, not the only one, and `EACCES`/`EPERM` are shared by all of them.

</details>