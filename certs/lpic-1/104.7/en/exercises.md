# LPIC-1 — 104.7 Find System Files and Place Files in the Correct Location

**Exam:** 101-500 · **Weight:** 3.12 · **Syllabus version:** 5.0

**Objective scope** — Understand the correct locations of files under the FHS; find files and commands on a Linux system; know the location and purpose of important files and directories as defined in the FHS.

**Terms and utilities on the exam:** `find`, `locate`, `updatedb`, `whereis`, `which`, `type`, `/etc/updatedb.conf`

**Reference sources**

- LPI Exam 101 Objectives — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Filesystem Hierarchy Standard 3.0 (Linux Foundation) — <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- GNU findutils manual — <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- `find(1)` — <https://man7.org/linux/man-pages/man1/find.1.html>
- `whereis(1)` — <https://man7.org/linux/man-pages/man1/whereis.1.html>
- `updatedb.conf(5)` — <https://man7.org/linux/man-pages/man5/updatedb.conf.5.html>
- Bash Reference Manual, Bourne Shell Builtins (`type`, `hash`) — <https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins>
- plocate — <https://plocate.sesse.net/>

---

## Lab environment

Any current Linux system with GNU findutils and `sudo`. Outputs below were captured on **Debian 12 (bookworm)** with `plocate`; on **RHEL 8/9** the locate implementation is `mlocate` and the database path differs — this is called out where it matters. Byte-for-byte output will differ on your machine; the *shape* of the output is what you must recognise.

Run every step yourself. Reading the commands is not the exercise.

### Step 0 — Build the scratch tree

```bash
export LAB="$HOME/lpic1-104.7"
rm -rf "$LAB"
mkdir -p "$LAB"/{app/{bin,etc,logs},data/{2024,2025,2026},junk,.cache}
cd "$LAB"

head -c 900     /dev/urandom > junk/small.bin
head -c 2097152 /dev/urandom > data/2026/report.bin
truncate -s 15M               data/2025/archive.bin      # sparse on purpose
: > junk/empty.log

printf '#!/bin/sh\necho hi\n' > app/bin/hello.sh && chmod 0755 app/bin/hello.sh
printf 'key=value\n'          > app/etc/hello.conf && chmod 0600 app/etc/hello.conf
printf 'secret\n'             > app/etc/token.conf && chmod 0666 app/etc/token.conf

: > 'app/logs/name with spaces.log'
: > $'app/logs/weird\tname.log'
: > .cache/hidden.tmp

ln -s ../bin/hello.sh app/etc/hello-link
ln -s /nonexistent    app/etc/broken-link

touch -d '2024-03-01 10:00' data/2024/old.txt
touch -d '2025-11-15 10:00' data/2025/mid.txt
touch                       data/2026/new.txt

find "$LAB" -printf '%y %10s %p\n' | sort -k3
```

Expected shape:

```
d       4096 /home/you/lpic1-104.7
d       4096 /home/you/lpic1-104.7/.cache
f          0 /home/you/lpic1-104.7/.cache/hidden.tmp
d       4096 /home/you/lpic1-104.7/app
d       4096 /home/you/lpic1-104.7/app/bin
f         18 /home/you/lpic1-104.7/app/bin/hello.sh
d       4096 /home/you/lpic1-104.7/app/etc
l         14 /home/you/lpic1-104.7/app/etc/broken-link
l         15 /home/you/lpic1-104.7/app/etc/hello-link
f         10 /home/you/lpic1-104.7/app/etc/hello.conf
f          7 /home/you/lpic1-104.7/app/etc/token.conf
...
f   15728640 /home/you/lpic1-104.7/data/2025/archive.bin
```

---

## Block 1 — Reading the FHS off a live system

The FHS is not trivia to memorise in the abstract; it is a set of *predicates* you can test on a running machine. This block makes you test them.

### Steps

1. Look at the top level and note which entries are symlinks:

   ```bash
   ls -ld /bin /sbin /lib /lib64 /usr/bin /usr/sbin /usr/lib 2>/dev/null
   ```

   On a modern merged-`/usr` distribution:

   ```
   lrwxrwxrwx  1 root root    7 Jul 10  2025 /bin -> usr/bin
   lrwxrwxrwx  1 root root    9 Jul 10  2025 /lib -> usr/lib
   lrwxrwxrwx  1 root root    9 Jul 10  2025 /lib64 -> usr/lib64
   lrwxrwxrwx  1 root root    8 Jul 10  2025 /sbin -> usr/sbin
   drwxr-xr-x  2 root root 61440 Aug 20 09:14 /usr/bin
   drwxr-xr-x  2 root root 20480 Aug 19 22:03 /usr/sbin
   ```

2. Resolve them and confirm the physical location:

   ```bash
   readlink -f /bin /sbin /lib
   ```

3. Check the same for the two FHS 3.0 runtime directories:

   ```bash
   ls -ld /run /var/run /var/lock
   findmnt -no TARGET,FSTYPE,OPTIONS /run
   ```

   ```
   drwxr-xr-x 34 root root      920 Aug 26 08:41 /run
   lrwxrwxrwx  1 root root        4 Jul 10  2025 /var/run -> /run
   lrwxrwxrwx  1 root root        9 Jul 10  2025 /var/lock -> /run/lock
   /run tmpfs rw,nosuid,nodev,noexec,relatime,size=1608268k,mode=755
   ```

4. Ask the kernel what filesystem backs `/tmp` and `/var/tmp`:

   ```bash
   stat -f -c '%n: %T' /tmp /var/tmp /run /proc /sys
   ```

   ```
   /tmp: tmpfs
   /var/tmp: ext2/ext3
   /run: tmpfs
   /proc: proc
   /sys: sysfs
   ```

5. Enumerate what actually lives in `/var` and in `/usr/share` on your system:

   ```bash
   ls -1 /var
   ls -1 /usr/share | head -20
   ```

6. Confirm the FHS rule that `/etc` contains no binaries — that is, no regular file with any execute bit that is also a real ELF program:

   ```bash
   find /etc -maxdepth 1 -type f -perm /111 -exec file {} + 2>/dev/null | head
   ```

   You will typically see shell scripts (`/etc/rc.local`) but no compiled executables. Scripts are tolerated in practice; the FHS prohibition is on *binaries*.

7. Look at a package that follows the `/opt` convention, if you have one, and note the three-part split:

   ```bash
   ls -d /opt/* /etc/opt/* /var/opt/* 2>/dev/null
   ```

8. Show the difference between a distribution-managed hierarchy and the local admin hierarchy:

   ```bash
   ls -d /usr/local/*
   ```

   ```
   /usr/local/bin  /usr/local/etc  /usr/local/games  /usr/local/include
   /usr/local/lib  /usr/local/man  /usr/local/sbin   /usr/local/share  /usr/local/src
   ```

### Comprehension questions — Block 1

- **Q1.1** — On a merged-`/usr` system, `/bin` is a symlink to `usr/bin` (relative), not `/usr/bin` (absolute). Why does the relative form matter?
- **Q1.2** — FHS 3.0 splits the hierarchy along two independent axes. Name them, and place `/usr`, `/var`, `/etc` and `/home` on both axes.
- **Q1.3** — A cron job writes a 4 GB intermediate file that must survive a reboot but is not user data. `/tmp` or `/var/tmp`? Justify from the FHS text, not from habit.
- **Q1.4** — Why is `/run` a tmpfs mounted with `nosuid,nodev`, and which FHS-2.3-era directory did it replace?
- **Q1.5** — You compile nginx from source with `./configure --prefix=???`. Give the correct prefix and say where its config and its logs must go. Then give the correct answer for the *other* case: a vendor ships you a self-contained tarball `acme-crm` with its own libraries.
- **Q1.6** — `/proc` and `/sys` are not in Chapters 3–5 of FHS 3.0. Where are they specified, and what does that tell you about their portability?
- **Q1.7** — Which of `/usr/local/man` and `/usr/local/share/man` does FHS 3.0 designate, and what is the status of the other?

---

## Block 2 — Locating *commands*: `type`, `which`, `whereis`

Three tools, three different questions. Confusing them is the single most common failure on this objective.

### Steps

1. Ask the shell what it would actually run:

   ```bash
   type ls
   type cd
   type if
   type -a echo
   ```

   ```
   ls is aliased to `ls --color=auto'
   cd is a shell builtin
   if is a shell keyword
   echo is a shell builtin
   echo is /usr/bin/echo
   ```

2. Get just the classification, then force a PATH-only lookup:

   ```bash
   type -t ls; type -t cd; type -t if; type -t echo
   type -P echo
   type -P ls
   ```

   ```
   alias
   builtin
   keyword
   builtin
   /usr/bin/echo
   /usr/bin/ls
   ```

3. Compare with `which` and with the POSIX builtin:

   ```bash
   which echo
   command -v echo
   command -v cd
   which cd; echo "exit=$?"
   ```

   ```
   /usr/bin/echo
   echo
   cd
   which: no cd in (/usr/local/bin:/usr/bin:/bin:...)
   exit=1
   ```

4. Observe the shell hash table — the reason `which` can disagree with reality:

   ```bash
   hash -r
   type ls >/dev/null; ls >/dev/null
   type ls
   hash
   ```

   ```
   ls is aliased to `ls --color=auto'
   hits	command
      1	/usr/bin/ls
   ```

5. Reproduce the classic stale-hash trap:

   ```bash
   mkdir -p ~/bin && printf '#!/bin/sh\necho FIRST\n' > ~/bin/probe && chmod +x ~/bin/probe
   export PATH="$HOME/bin:$PATH"
   hash -r
   probe                       # -> FIRST
   printf '#!/bin/sh\necho SECOND\n' > /tmp/probe && chmod +x /tmp/probe
   export PATH="/tmp:$PATH"
   which probe                 # -> /tmp/probe
   probe                       # -> ?
   type probe
   hash -r; probe              # -> ?
   ```

6. Now ask the *packaging* question instead of the *execution* question:

   ```bash
   whereis passwd
   whereis -b passwd
   whereis -m passwd
   whereis -s passwd
   ```

   ```
   passwd: /usr/bin/passwd /etc/passwd /etc/passwd.org /usr/share/man/man1/passwd.1.gz /usr/share/man/man5/passwd.5.gz
   passwd: /usr/bin/passwd /etc/passwd /etc/passwd.org
   passwd: /usr/share/man/man1/passwd.1.gz /usr/share/man/man5/passwd.5.gz
   passwd:
   ```

7. Show where `whereis` looks, and prove it is not just `$PATH`:

   ```bash
   whereis -l | head -20
   whereis -u -m -B /usr/bin -f probe          # -B needs -f to terminate the dir list
   ```

8. Run all three against a command that does not exist and compare exit statuses:

   ```bash
   type nosuchcmd;  echo "type=$?"
   which nosuchcmd; echo "which=$?"
   whereis nosuchcmd; echo "whereis=$?"
   ```

   ```
   bash: type: nosuchcmd: not found
   type=1
   which=1
   nosuchcmd:
   whereis=0
   ```

### Comprehension questions — Block 2

- **Q2.1** — Give the one-sentence question each of `type`, `which`, `whereis` answers. Which of the three is a shell builtin, and why does that make it authoritative?
- **Q2.2** — In step 5, what did the bare `probe` print immediately after you prepended `/tmp` to `PATH`, and why did `which probe` disagree with it?
- **Q2.3** — `which cd` fails while `command -v cd` succeeds. Explain, and state which one a portable script should use.
- **Q2.4** — `whereis nosuchcmd` exits 0. What is the operational consequence for a script that tests command availability with `whereis -b foo >/dev/null && ...`?
- **Q2.5** — Debian's `which` lives in the `debianutils` package and is being deprecated. What is the recommended replacement, and what is the one capability of `which -a` you must reproduce differently?
- **Q2.6** — Your `PATH` contains `/usr/local/bin` before `/usr/bin`. `type -a python3` lists both. Which one runs, and what single command shows you the resolved path without running it?
- **Q2.7** — Why does `whereis` return `/etc/passwd` when asked about the `passwd` *command*? Is that a bug?

---

## Block 3 — `find`: the expression engine

`find` is not a search command with flags. It is an expression evaluator: it walks a tree and evaluates a boolean expression against every node, with short-circuit semantics. Every "flag" is a *test*, an *action* (which also returns a boolean) or an *operator*. Once you internalise that, the surprising behaviours stop being surprising.

### Steps

1. Establish the anatomy. These three are equivalent:

   ```bash
   cd "$LAB"
   find . -name '*.conf'
   find . -name '*.conf' -print
   find . -a -name '*.conf' -a -print
   ```

   The implicit operator between predicates is `-a` (AND); the implicit action when none is given is `-print`.

2. Prove short-circuit evaluation with a side effect:

   ```bash
   find . -type f -printf 'TEST %p\n' -a -name '*.bin' -printf 'MATCH %p\n' | head
   ```

   Note that `-printf` returns true, so evaluation continues; `TEST` prints for every file, `MATCH` only for `.bin`.

3. Filter by type. Run each and count:

   ```bash
   find . -type f | wc -l
   find . -type d | wc -l
   find . -type l -printf '%p -> %l\n'
   ```

   ```
   app/etc/broken-link -> /nonexistent
   app/etc/hello-link -> ../bin/hello.sh
   ```

4. Name vs path vs regex:

   ```bash
   find . -name 'hello*'
   find . -iname 'HELLO*'
   find . -path '*/app/etc/*'
   find . -regex '.*/data/20[0-9][0-9]/.*\.txt'
   ```

   Note: `-name` matches the *basename only*, and its glob metacharacters do **not** stop at `/` — but since it only ever sees a basename, that is moot. `-path` matches the whole path as printed, and its `*` **does** cross `/`.

5. Depth control — and see the warning GNU emits when you get the order wrong:

   ```bash
   find . -maxdepth 2 -type d
   find . -type d -maxdepth 2
   ```

   ```
   find: warning: you have specified the global option -maxdepth after the argument -type,
   but global options are not positional, i.e., -maxdepth affects tests specified before it
   as well as those specified after it.  Please specify global options before other arguments.
   ```

6. Size — and the rounding trap:

   ```bash
   find . -type f -size +1M -printf '%10s %p\n'
   find . -type f -size -1M -printf '%10s %p\n'
   find . -type f -size -1M -size +0 -printf '%10s %p\n'
   find . -type f -size +900c -size -2000c -printf '%10s %p\n'
   ```

   ```
     2097152 ./data/2026/report.bin
    15728640 ./data/2025/archive.bin
           0 ./junk/empty.log
           0 ./.cache/hidden.tmp
           0 ./app/logs/name with spaces.log
           0 ./app/logs/weird	name.log
   (third command prints nothing)
   (fourth command prints nothing)
   ```

7. Confront the sparse-file question:

   ```bash
   ls -l  data/2025/archive.bin
   du -h  data/2025/archive.bin
   find data/2025 -name archive.bin -printf 'st_size=%s  blocks512=%b  du_k=%k\n'
   ```

   ```
   -rw-r--r-- 1 you you 15728640 Aug 26 08:52 data/2025/archive.bin
   0	data/2025/archive.bin
   st_size=15728640  blocks512=0  du_k=0
   ```

8. Time tests. `-mtime` units are 24-hour periods, truncated toward zero:

   ```bash
   find data -type f -mtime +365  -printf '%TY-%Tm-%Td %p\n'
   find data -type f -mmin  -10   -printf '%TY-%Tm-%Td %TH:%TM %p\n'
   find data -type f -newermt '2025-01-01' ! -newermt '2026-01-01' -printf '%TF %p\n'
   find data -type f -newer data/2025/mid.txt -printf '%TF %p\n'
   ```

9. Permissions — the three matching modes:

   ```bash
   find app -type f -perm 0644          # exactly 0644
   find app -type f -perm -0044         # r for group AND r for other, plus anything else
   find app -type f -perm /0022         # writable by group OR by other
   find app -type f -perm -0111         # executable by u AND g AND o
   ```

10. Combine with parentheses and negation — and note the shell quoting:

    ```bash
    find . \( -name '*.conf' -o -name '*.log' \) -a -type f -printf '%M %p\n'
    find . -type f ! -name '*.bin' -printf '%p\n'
    ```

11. `-prune` — skipping subtrees. Read this one carefully:

    ```bash
    find . -name .cache -prune -o -type f -print
    find . -name .cache -prune -o -type f            # WRONG: what changed?
    ```

12. `-xdev` — stay on one filesystem, the standard defence when scanning `/`:

    ```bash
    sudo find / -xdev -maxdepth 2 -name '*.conf' 2>/dev/null | wc -l
    sudo find /      -maxdepth 2 -name '*.conf' 2>/dev/null | wc -l
    ```

13. Actions: `-exec` in both forms, and `-execdir`:

    ```bash
    find . -name '*.conf' -exec sha256sum {} \;      # one process per file
    find . -name '*.conf' -exec sha256sum {} +       # batched, argv-limited
    find . -name '*.conf' -execdir sha256sum {} \;   # runs with cwd = the file's directory
    ```

    Time the difference at scale:

    ```bash
    time find /usr/share/doc -type f -exec true {} \;
    time find /usr/share/doc -type f -exec true {} +
    ```

14. Hostile filenames. This is why `-print0` exists:

    ```bash
    find app/logs -type f | wc -l
    find app/logs -type f | xargs ls -l 2>&1 | tail -3          # breaks
    find app/logs -type f -print0 | xargs -0 ls -l              # correct
    find app/logs -type f -exec ls -l {} +                      # also correct, no pipe
    ```

15. Symlink handling — `-P` (default), `-L`, `-H`:

    ```bash
    find app/etc -type l                  # implicit -P
    find -P app/etc -type l
    find -L app/etc -type l               # what appears here, and why?
    find -L app/etc -type f
    find -L app/etc -xtype l
    ```

16. Diagnostic one-liners you will actually use in production:

    ```bash
    # setuid/setgid binaries outside package-managed trust boundaries
    sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u:%g %p\n' 2>/dev/null

    # world-writable directories missing the sticky bit
    sudo find / -xdev -type d -perm -0002 ! -perm -1000 -print 2>/dev/null

    # files with no valid owner (left behind by a deleted user/UID)
    sudo find / -xdev \( -nouser -o -nogroup \) -printf '%U:%G %p\n' 2>/dev/null

    # top 10 space consumers
    sudo find /var -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -10

    # config changed in the last 24 h — the "what did I break" query
    sudo find /etc -xdev -type f -mtime -1 -printf '%TF %TT %p\n' 2>/dev/null | sort

    # empty files and empty directories
    find "$LAB" -empty -printf '%y %p\n'

    # hardlink forensics
    find /usr/bin -type f -links +1 -printf '%i %n %p\n' | sort -n | head
    ```

17. Exit status and early termination:

    ```bash
    find "$LAB" -name nonexistent-name; echo "exit=$?"
    find /root -name '*' >/dev/null;     echo "exit=$?"     # as a normal user
    find /usr -name 'bash' -print -quit; echo "exit=$?"
    ```

### Comprehension questions — Block 3

- **Q3.1** — In step 11, the second command dropped the `-print`. Describe exactly what changed in the output and explain it in terms of the implicit `-print` rule.
- **Q3.2** — `find . -type f -size -1M` printed only zero-byte files. Explain the rounding rule and rewrite the command so it means "smaller than one mebibyte but not empty".
- **Q3.3** — `du` says 0 and `ls -l` says 15 MiB for `archive.bin`, yet `find -size +10M` matches it. Which stat field does `find -size` use, and what is the practical risk when you use `find -size` to hunt for disk-space consumers?
- **Q3.4** — Distinguish `-perm 0644`, `-perm -0644` and `-perm /0644` precisely. What happened to `-perm +0644`?
- **Q3.5** — Why does `-mtime +7` **not** mean "older than 7 days" in the way most people read it? State what it does mean, and give the option that makes the boundary fall at midnight instead of "now minus N×24 h".
- **Q3.6** — Compare `-exec cmd {} \;` and `-exec cmd {} +` on: process count, argument-length limits, exit-status propagation, and whether `{}` may appear more than once.
- **Q3.7** — Why is `-execdir` preferred over `-exec` when the tree may be writable by an untrusted user?
- **Q3.8** — In step 15, `find -L app/etc -type l` printed `broken-link` and not `hello-link`. Explain both halves of that result, and say what `-xtype l` does differently.
- **Q3.9** — `find /etc -name '*.conf' | xargs grep -l root` is a widely copied idiom. Give two independent ways it can fail and the two safe rewrites.
- **Q3.10** — What is `find`'s exit status when it produced correct output but was denied access to some subdirectory? What does that imply for `set -e` scripts and for `find ... 2>/dev/null`?
- **Q3.11** — You must delete every `*.tmp` under `/srv` older than 30 days, safely. Write the command using `-delete`, then state the two behavioural side effects `-delete` has that `-exec rm {} +` does not.
- **Q3.12** — Why did the `-maxdepth` warning in step 5 call it a *global* option rather than a test?

---

## Block 4 — `locate`, `updatedb`, `/etc/updatedb.conf`

`find` walks the filesystem now. `locate` queries a database built earlier. Everything that distinguishes them follows from that one sentence.

### Steps

1. Identify which implementation you have:

   ```bash
   locate --version | head -1
   readlink -f "$(command -v locate)"
   ls -l /usr/bin/locate /usr/bin/plocate /usr/bin/mlocate 2>/dev/null
   ```

   ```
   plocate 1.1.15
   /usr/bin/plocate
   lrwxrwxrwx 1 root root      7 Apr  8  2023 /usr/bin/locate -> plocate
   -rwxr-sr-x 1 root plocate 71K Apr  8  2023 /usr/bin/plocate
   ```

   Note `-rwxr-s---`/`-rwxr-sr-x`: the binary is **setgid**, not setuid.

2. Find the database and inspect its ownership:

   ```bash
   ls -l /var/lib/plocate/plocate.db 2>/dev/null || ls -l /var/lib/mlocate/mlocate.db
   stat -c '%n %s bytes, %U:%G, %A' /var/lib/plocate/plocate.db 2>/dev/null
   ```

   ```
   /var/lib/plocate/plocate.db 12582912 bytes, root:plocate, -rw-r-----
   ```

3. Read the configuration file:

   ```bash
   cat /etc/updatedb.conf
   ```

   ```
   PRUNE_BIND_MOUNTS="yes"
   PRUNENAMES=".git .bzr .hg .svn"
   PRUNEPATHS="/tmp /var/spool /media /var/lib/os-prober /var/lib/ceph /home/.ecryptfs /var/lib/schroot"
   PRUNEFS="NFS afs autofs binfmt_misc ceph cgroup cgroup2 cifs coda configfs curlftpfs debugfs devfs
   devpts devtmpfs ecryptfs ftpfs fuse.ceph fuse.glusterfs fuse.sshfs fusectl gfs gfs2 hugetlbfs
   iso9660 lustre mfs ncpfs nfs nfs4 nfsd proc ramfs rpc_pipefs securityfs selinuxfs smbfs sysfs
   tmpfs tracefs udf usbfs vboxsf"
   ```

4. See when and how it is refreshed:

   ```bash
   systemctl list-timers '*updatedb*' --all
   systemctl cat plocate-updatedb.timer 2>/dev/null || systemctl cat updatedb.timer
   ls -l /etc/cron.daily/*locate* 2>/dev/null
   ```

5. Query with the database as it stands, then observe staleness:

   ```bash
   locate -c hello.conf
   touch "$LAB/marker-$$.conf"
   locate "marker-$$"            ; echo "exit=$?"
   sudo updatedb
   locate "marker-$$"            ; echo "exit=$?"
   rm "$LAB/marker-$$.conf"
   locate "marker-$$"            ; echo "exit=$?"
   locate -e "marker-$$"         ; echo "exit=$?"
   ```

6. Pattern semantics — the implicit wildcards:

   ```bash
   locate -c bash
   locate -c '*bash*'
   locate -c '/bin/bash'
   locate -b bash | head -5
   locate -b '\bash'                 # exact basename, the backslash disables implicit globbing
   ```

7. Case folding, regex, and limits:

   ```bash
   locate -i README | head -3
   locate --regex '/usr/share/man/man5/.*passwd.*' 
   locate -l 5 conf
   locate -0 conf | head -c 200 | xxd | head -3
   ```

8. Prove the privacy filter. `locate` must not leak paths the caller cannot see:

   ```bash
   sudo install -d -m 0700 /root/private-dir
   sudo touch /root/private-dir/topsecret-marker.txt
   sudo updatedb
   locate topsecret-marker          ; echo "user exit=$?"
   sudo locate topsecret-marker     ; echo "root exit=$?"
   ```

   ```
   user exit=1
   /root/private-dir/topsecret-marker.txt
   root exit=0
   ```

9. Build a **private, unprivileged** database — the technique that turns `locate` into a per-project index:

   ```bash
   updatedb -l 0 -U "$LAB" -o "$LAB/../lab.db"
   locate -d "$LAB/../lab.db" -c conf
   locate -d "$LAB/../lab.db" '*.bin'
   ```

   ```
   2
   /home/you/lpic1-104.7/data/2025/archive.bin
   /home/you/lpic1-104.7/data/2026/report.bin
   /home/you/lpic1-104.7/junk/small.bin
   ```

10. Exercise the prune knobs against your own tree:

    ```bash
    updatedb -l 0 -U "$LAB" -n '.cache' -o "$LAB/../lab-pruned.db"
    locate -d "$LAB/../lab-pruned.db" hidden.tmp   ; echo "exit=$?"

    updatedb -l 0 -U "$LAB" -e "$LAB/junk" -o "$LAB/../lab-nojunk.db"
    locate -d "$LAB/../lab-nojunk.db" small.bin    ; echo "exit=$?"
    ```

11. Compare cost directly:

    ```bash
    time locate -c '*.service'
    time sudo find / -xdev -name '*.service' 2>/dev/null | wc -l
    ```

### Comprehension questions — Block 4

- **Q4.1** — Name the four directives in `/etc/updatedb.conf` and say precisely what each excludes. Which one takes *directory names* rather than paths, and does it accept wildcards?
- **Q4.2** — `tmpfs` and `nfs` are both in `PRUNEFS`, for opposite reasons. Give the reason for each.
- **Q4.3** — In step 5, `locate "marker-$$"` still returned the path after you deleted the file. Explain, give the option that suppresses stale hits, and say what that option costs.
- **Q4.4** — `locate bash` and `locate '*bash*'` returned the same count, but `locate '/bin/bash'` did not. State the pattern rule that explains all three.
- **Q4.5** — The `locate` binary is setgid, not setuid. Explain the security model: what group, what does that group own, and what would break if the database were mode `0644`?
- **Q4.6** — What does `updatedb --require-visibility 0` change about the resulting database, and why is it the correct choice for the private database in step 9 but the wrong choice for `/var/lib/plocate/plocate.db`?
- **Q4.7** — A user reports that a file they created five minutes ago is "not on the system" because `locate` cannot find it. Give the two-line diagnosis and the correct tool.
- **Q4.8** — On a 4 TB NFS-backed fileserver, `updatedb` takes 40 minutes and saturates the mount. Give two configuration changes that fix it and state the trade-off of each.
- **Q4.9** — `find` versus `locate`: give four axes of comparison (freshness, cost, metadata predicates, privilege) and state, for each, which tool wins.

---

## Block 5 — Placement decisions: putting files in the *correct* location

The objective title has two halves. This block is the second half.

### Steps

1. Install a locally built script the FHS-correct way and verify it is reachable:

   ```bash
   sudo install -D -m 0755 "$LAB/app/bin/hello.sh" /usr/local/bin/hello
   type hello
   which hello
   whereis -b hello
   hello
   ```

2. Add a man page for it in the right place and confirm the man hierarchy picks it up:

   ```bash
   sudo install -d /usr/local/share/man/man1
   printf '.TH HELLO 1\n.SH NAME\nhello \\- print hi\n' \
     | sudo tee /usr/local/share/man/man1/hello.1 >/dev/null
   manpath
   man -w hello
   whereis -m hello
   ```

3. Now do the same thing **wrong**, and detect it:

   ```bash
   sudo install -D -m 0755 "$LAB/app/bin/hello.sh" /usr/bin/hello-bad
   dpkg -S /usr/bin/hello-bad 2>&1 || rpm -qf /usr/bin/hello-bad 2>&1
   ```

   ```
   dpkg-query: no path found matching pattern /usr/bin/hello-bad
   ```

   That "no path found" is the signature of a file the package manager does not own — a file that a distribution upgrade may silently overwrite or an integrity scan will flag.

4. Sweep the whole system for that class of mistake (Debian family):

   ```bash
   sudo find /usr/bin /usr/sbin -xdev -type f -print0 \
     | xargs -0 -n 200 dpkg -S 2>&1 >/dev/null \
     | sed 's/^dpkg-query: no path found matching pattern //' | head
   ```

   RPM family:

   ```bash
   sudo find /usr/bin /usr/sbin -xdev -type f -exec rpm -qf --qf '' {} \; 2>&1 \
     | grep 'not owned' | head
   ```

5. Lay out a vendor package the `/opt` way and prove the three-way split:

   ```bash
   sudo install -d /opt/acme-crm/{bin,lib} /etc/opt/acme-crm /var/opt/acme-crm/{log,spool}
   sudo install -m 0755 "$LAB/app/bin/hello.sh" /opt/acme-crm/bin/acme
   sudo install -m 0640 "$LAB/app/etc/hello.conf" /etc/opt/acme-crm/acme.conf
   find /opt/acme-crm /etc/opt/acme-crm /var/opt/acme-crm -printf '%y %M %p\n'
   ```

6. Place service data and check it against the alternatives:

   ```bash
   sudo install -d -m 0755 /srv/www/example.com
   echo ok | sudo tee /srv/www/example.com/index.html >/dev/null
   stat -c '%n %U:%G %A' /srv/www/example.com/index.html
   ```

7. Runtime state — the modern, systemd-friendly way:

   ```bash
   sudo install -d -m 0755 -o root -g root /run/acme
   findmnt -no FSTYPE /run
   printf 'd /run/acme 0755 root root -\n' | sudo tee /etc/tmpfiles.d/acme.conf >/dev/null
   sudo systemd-tmpfiles --create /etc/tmpfiles.d/acme.conf
   ls -ld /run/acme
   ```

8. Clean the lab up (do this — you are leaving root-owned files behind otherwise):

   ```bash
   sudo rm -f  /usr/local/bin/hello /usr/bin/hello-bad \
               /usr/local/share/man/man1/hello.1 \
               /etc/tmpfiles.d/acme.conf
   sudo rm -rf /opt/acme-crm /etc/opt/acme-crm /var/opt/acme-crm \
               /srv/www/example.com /run/acme /root/private-dir
   rm -f "$LAB/../lab.db" "$LAB/../lab-pruned.db" "$LAB/../lab-nojunk.db"
   sudo updatedb
   hash -r
   ```

### Comprehension questions — Block 5

- **Q5.1** — For each item, name the single FHS-correct directory and one sentence of justification: (a) a Python script you wrote for this host only; (b) a static site served by nginx; (c) a PostgreSQL data directory; (d) a PID file; (e) a systemd unit shipped by a distro package; (f) a systemd unit you wrote; (g) a locally compiled shared library; (h) the source tarball you compiled it from; (i) a CA certificate for an internal PKI; (j) a 200 MB nightly database dump kept for 7 days.
- **Q5.2** — In step 3, `dpkg -S` said "no path found". Why is that specifically a *problem* for `/usr/bin/hello-bad` but *expected and correct* for `/usr/local/bin/hello`?
- **Q5.3** — `/srv` versus `/var/www` versus `/opt/<vendor>/www`. Which one does FHS 3.0 designate for site-served data, and why do Debian and RHEL both ship `/var/www` anyway?
- **Q5.4** — Explain the `/opt` ⇄ `/etc/opt` ⇄ `/var/opt` triple. Why does the FHS forbid a package from writing its config under `/opt/<pkg>/etc`?
- **Q5.5** — You put a unit file in `/usr/local/lib/systemd/system/`. Is that FHS-correct? Is it *functional*? Reconcile the two answers.
- **Q5.6** — Why is `install -D -m 0755` preferable to `cp` + `chmod` in a provisioning script? Name two properties `install` gives you.
- **Q5.7** — After step 1, `type hello` worked immediately. After step 8's `rm`, `hello` may still "work" until you run `hash -r`. Which mechanism causes that, and which of `type`/`which`/`whereis` would have shown you the truth?
- **Q5.8** — Given `/usr/local/share/man/man1/hello.1`, explain how `man` found it without any configuration. Name the mechanism and the file that governs it.

---

## Block 6 — Integration: a diagnostic run

One scenario, all four tools.

### Steps

1. A deployment shipped a binary named `report-gen` and it "is not found". Work the ladder:

   ```bash
   type -a report-gen        2>&1
   command -v report-gen     2>&1
   whereis -b report-gen
   locate -b '\report-gen'
   sudo find / -xdev -type f -name 'report-gen' -printf '%M %u:%g %10s %TF %p\n' 2>/dev/null
   echo "$PATH" | tr ':' '\n'
   ```

2. Write the decision as a script and reason about each exit status:

   ```bash
   cat > /tmp/whereisit.sh <<'EOF'
   #!/bin/bash
   set -u
   cmd=$1
   if p=$(command -v -- "$cmd"); then
     printf 'in PATH: %s\n' "$p"; exit 0
   fi
   if locate -b "\\$cmd" 2>/dev/null | grep -q .; then
     printf 'on disk (locate db, may be stale):\n'; locate -e -b "\\$cmd"; exit 0
   fi
   printf 'not in PATH and not in locate db; doing a live scan...\n' >&2
   find / -xdev -type f -name "$cmd" -print -quit 2>/dev/null | grep . \
     || { printf 'genuinely absent\n' >&2; exit 1; }
   EOF
   chmod +x /tmp/whereisit.sh
   /tmp/whereisit.sh bash
   /tmp/whereisit.sh report-gen
   ```

3. Audit the placement of everything a local build dropped in the last day:

   ```bash
   sudo find /usr/local -xdev -mtime -1 -printf '%y %M %TF %TT %p\n' 2>/dev/null | sort -k4
   ```

4. Confirm nothing landed outside the sanctioned local hierarchies:

   ```bash
   sudo find / -xdev -mtime -1 -type f \
        \( -path '/usr/local/*' -o -path '/opt/*' -o -path '/etc/*' \) -prune -o \
        -type f -mtime -1 -newermt 'today 00:00' -print 2>/dev/null | head -20
   ```

### Comprehension questions — Block 6

- **Q6.1** — In step 1, order the five lookups from cheapest to most expensive and state what each one can prove that the previous cannot.
- **Q6.2** — The script uses `locate -b "\\$cmd"`. Explain both backslashes: one is consumed by the shell, one by `locate`. What would `locate -b "$cmd"` match instead?
- **Q6.3** — `find / -name X -print -quit` is used instead of a plain `find / -name X`. What does `-quit` buy you, and what does it cost in correctness?
- **Q6.4** — In step 4, the `-prune` branch lists paths *and then* the second `-type f -mtime -1` repeats itself. Explain why the repetition is necessary given `-o` semantics.
- **Q6.5** — `command -v` is used rather than `which` inside the script. Give the two reasons (one portability, one correctness) that make that the right call in a `#!/bin/bash` script.

---

## Answers

<details>
<summary><b>Click to reveal all answers</b></summary>

### Block 1 — Reading the FHS off a live system

**A1.1** — A *relative* symlink (`/bin -> usr/bin`) resolves correctly regardless of where the root filesystem is mounted. During installation, rescue, `chroot`, container image builds or `systemd-nspawn`, the tree lives at `/mnt/sysroot` or similar; an absolute `/bin -> /usr/bin` would escape the chroot and point at the *host's* `/usr/bin`, which is either wrong or a security hole. Relative links keep the hierarchy self-contained and relocatable.

**A1.2** — The two axes are **shareable vs. unshareable** and **static vs. variable** (FHS 3.0 §2).

| | static | variable |
|---|---|---|
| **shareable** | `/usr`, `/opt` | `/var/mail`, `/var/spool/news`, `/home` |
| **unshareable** | `/etc`, `/boot` | `/var/run`, `/var/lock` (now `/run`) |

`/usr` = shareable + static (mountable read-only, exportable to many hosts). `/var` = variable, mixed shareability. `/etc` = unshareable + static (host-specific configuration). `/home` = shareable + variable.

**A1.3** — `/var/tmp`. FHS 3.0 §5.15: "*Programs may not assume that any files or directories in `/tmp` are preserved between invocations of the program*", while §5.15 for `/var/tmp` states the data "*is more persistent than data in `/tmp`*" and "*must not be deleted when the system is booted*". `/tmp` is additionally a `tmpfs` on most modern distributions, so a 4 GB file there consumes RAM/swap, and `systemd-tmpfiles` age-cleans it aggressively (`/etc/tmpfiles.d`, typically 10 days for `/tmp`, 30 for `/var/tmp`).

**A1.4** — `/run` holds volatile runtime data that must be available **before `/var` is mounted** and must be discarded at boot. Making it a `tmpfs` guarantees both: it exists from very early in the initramfs handoff, and it starts empty every boot with no cleanup script needed. `nosuid,nodev` are hardening: nothing in `/run` should ever be a setuid binary or a device node, so the kernel is told to ignore those bits outright. It replaced **`/var/run`** (and `/var/lock` → `/run/lock`), which FHS 3.0 now requires to be symlinks to `/run` and `/run/lock`.

**A1.5** — Source build: `--prefix=/usr/local`. Binaries → `/usr/local/sbin/nginx`, config → `/usr/local/etc/nginx/`, variable data (logs, cache, PID) → `/var/log/nginx` and `/var/cache/nginx` — `/usr/local` must remain safe across upgrades of distribution software, and it should be mountable read-only, so nothing that changes at runtime belongs there. Vendor tarball: `/opt/acme-crm/` for the self-contained tree, `/etc/opt/acme-crm/` for its configuration, `/var/opt/acme-crm/` for its variable data.

**A1.6** — In **Chapter 6, the "Operating System Specific Annex"**, Linux section (§6.1.4 `/proc`, and the corresponding entry for `/sys`). Being in the annex rather than in the mandatory root-filesystem chapter means they are **Linux-specific**, not part of the portable core the FHS defines for all Unix-like systems — BSDs, for instance, do not provide `/sys` and mount `/proc` optionally or not at all.

**A1.7** — FHS 3.0 designates **`/usr/local/share/man`**, matching `/usr/share/man`. `/usr/local/man` is a **legacy compatibility path**: FHS 2.3 permitted it, and most distributions still ship it as a directory or a symlink so that older `--prefix=/usr/local` builds keep working. New installations should use `/usr/local/share/man`.

---

### Block 2 — Locating commands

**A2.1**
- `type` — *"What will this shell do when I type this word?"* Covers aliases, keywords, functions, builtins, hashed paths and PATH files, in the shell's own resolution order.
- `which` — *"Which file in `$PATH` matches this name?"* Nothing else.
- `whereis` — *"Where are this program's binary, source and man page, in the standard system locations?"*

`type` is a **shell builtin**, so it sees the shell's actual state — the alias table, the function table, the keyword list, the hash table. `which` is an external process; it cannot see any of that, only the exported `$PATH`.

**A2.2** — Bare `probe` still printed **`FIRST`**. Bash cached the full path `/home/you/bin/probe` in its hash table on the first invocation, and a later change to `PATH` does not invalidate the cache for names already hashed. `which` is a fresh external process with no hash table, so it did a clean left-to-right `PATH` scan and correctly reported `/tmp/probe`. `type probe` would have shown `probe is hashed (/home/you/bin/probe)` — the tell. `hash -r` clears the table and the next `probe` prints `SECOND`.

**A2.3** — `cd` is a shell builtin; there is no file named `cd` anywhere in `$PATH`, so `which` — which only searches `$PATH` for files — correctly finds nothing and exits 1. `command -v` is a POSIX shell builtin that reports how the shell would resolve the word, including builtins, so it prints `cd`. Portable scripts should use **`command -v`**: it is specified by POSIX, requires no external binary, and does not vary between the four incompatible `which` implementations in the wild (debianutils shell script, GNU which, BSD which, zsh builtin).

**A2.4** — `whereis` exits 0 whether or not it found anything — it is a reporting tool, not a test. The idiom `whereis -b foo >/dev/null && ...` therefore **always takes the true branch**, and the script proceeds as if `foo` existed. Correct: `command -v foo >/dev/null 2>&1 || { echo "foo required" >&2; exit 1; }`.

**A2.5** — The recommended replacement is **`command -v`** (POSIX) — Debian's `which` man page and the `debianutils` NEWS entry both say so. The one capability that does not carry over is `which -a`, which lists *every* match in `$PATH`. In bash, use **`type -a <name>`**; POSIX-portably, iterate `$PATH` yourself:

```sh
IFS=: ; for d in $PATH; do [ -x "$d/$1" ] && printf '%s\n' "$d/$1"; done
```

**A2.6** — The one listed **first** by `type -a` runs, because `type -a` prints matches in the shell's own resolution order — which for PATH files is left-to-right through `$PATH`, so `/usr/local/bin/python3`. The single command that shows the resolved path without executing it is **`type -P python3`** (or `command -v python3`).

**A2.7** — Not a bug. `whereis` searches a compiled-in list of standard directories that includes `/etc` — historically the place where a program's *binary* could live, and still the place where its data files often do. `whereis` matches on **basename only**, with a small set of recognised suffixes stripped; it has no notion of "is this file executable" or "is this the same program". `whereis -b passwd` therefore returns both the executable `/usr/bin/passwd` and the unrelated database `/etc/passwd`. This is exactly why `whereis` must never be used to test whether a command exists.

---

### Block 3 — The `find` expression engine

**A3.1** — With `-print` dropped, the command became `find . -name .cache -prune -o -type f`. Because **no action appears anywhere in the expression**, `find` appends an implicit `-print` to the *entire expression*, i.e. it behaves as `\( -name .cache -prune -o -type f \) -print`. The result: `./.cache` itself is now printed (it matched the left branch, `-prune` returned true), *and* all regular files are still printed. In the correct form, the explicit `-print` binds only to the right-hand branch of `-o`, so the pruned directory is silently skipped. The rule: **an explicit action anywhere in the expression suppresses the implicit `-print`**, and `-prune` returns *true*, which is precisely why it must be paired with `-o`.

**A3.2** — `-size` **rounds up** to the next whole unit. Any file from 1 byte to 1 048 576 bytes rounds up to `1M`, so `-size -1M` (strictly less than 1 M-unit) can only be satisfied by `0` — empty files. Correct form:

```bash
find . -type f -size -1M ! -empty
# or, exactly:
find . -type f -size -1048576c -size +0c
```

Only the `c` suffix is exact; `k`, `M`, `G`, `b` and `w` all round up.

**A3.3** — `find -size` uses **`st_size`** — the *apparent* size — for every unit, including the block units. `du` reports **`st_blocks`** — actually allocated storage. For a sparse file these diverge completely. Practical risk: `find -size +1G` will report sparse VM disk images, sparse log files and preallocated database files as space hogs when they occupy almost nothing, and conversely it will not account for filesystem compression (btrfs/ZFS) making an apparently large file physically small. When hunting real disk consumption, use `-printf '%k\t%p\n'` (which reports 1 KiB blocks from `st_blocks`) or `du`, not `-size`.

**A3.4**
- `-perm 0644` — the permission bits are **exactly** `rw-r--r--`; every one of the 12 mode bits (including setuid/setgid/sticky) must match.
- `-perm -0644` — **all** of the listed bits are set; others may also be set. Matches `0644`, `0755`, `0664`, `4644`.
- `-perm /0644` — **any** of the listed bits is set. Matches almost everything readable or owner-writable; `-perm /0000` matches nothing (special-cased).

`-perm +0644` was the old GNU spelling of `/`. It was deprecated in findutils 4.2.21 and **removed in 4.5.12**, because `+` collided with symbolic modes (`-perm +u+w`). Modern `find` errors out on it.

**A3.5** — `-mtime n` compares against **n × 24-hour periods counted back from the moment `find` starts**, and the arithmetic **truncates the fractional part toward zero**. So a file modified 7.5 days ago yields 7, which does not satisfy `+7` (strictly greater than 7). `-mtime +7` therefore means "modified **at least 8 full 24-hour periods** ago" — files between 7 and 8 days old fall through the crack. The option that anchors the boundary at midnight instead of "now" is **`-daystart`**, which must appear *before* the time tests it affects.

**A3.6**

| | `-exec cmd {} \;` | `-exec cmd {} +` |
|---|---|---|
| Processes | one per matched file | as few as `ARG_MAX` allows |
| Arg-length limits | never hit (one file each) | `find` splits invocations automatically to stay under the limit |
| Exit status | `-exec` returns the command's success per file, so it can be used as a **test** (`-exec grep -q X {} \; -print`) | always returns true; usable only as a terminal action |
| `{}` occurrences | may appear multiple times, anywhere in the argv | must appear **exactly once, immediately before the `+`** |

The performance gap is large: on a tree of ~50 000 files, `\;` forks 50 000 times, `+` forks a handful.

**A3.7** — `-exec` passes the full path and lets the invoked command resolve it from `find`'s original working directory. Between the moment `find` stats a directory and the moment the command opens the path, an attacker who controls part of the tree can swap a directory component for a symlink — a classic TOCTOU race that redirects the operation outside the intended tree. `-execdir` `chdir()`s into the containing directory and passes the path as `./basename`, so no attacker-controlled intermediate component is re-traversed. It also refuses to run if `$PATH` contains a relative entry.

**A3.8** — With `-L`, `find` **dereferences every symlink before applying the tests**. `hello-link` points at a regular file, so under `-L` it is reported as `-type f`, not `-type l`. `broken-link` cannot be dereferenced — the target does not exist — so `find` falls back to the link's own `lstat()` and it still tests as `-type l`. Hence under `-L`, `-type l` effectively means "broken symlink". `-xtype l` inverts the dereference policy for that one test: under the default `-P` it reports links whose *target* is a link, and under `-L` it reports the links themselves — so `-L ... -xtype l` gives you all symlinks regardless of whether they resolve.

**A3.9** — Two failure modes:
1. **Filenames containing whitespace, quotes or newlines.** `xargs` splits on whitespace and honours quoting by default, so `name with spaces.log` becomes three arguments and `"quoted"` is mangled.
2. **Empty input.** With no matches, GNU `xargs` still runs `grep -l root` once with no file operands, so `grep` reads **stdin** and the pipeline hangs (or, worse, consumes the script's input).

Safe rewrites:

```bash
find /etc -name '*.conf' -print0 | xargs -0 -r grep -l root
find /etc -name '*.conf' -exec grep -l root {} +
```

(`-r`/`--no-run-if-empty` fixes the second failure; `-print0`/`-0` the first. The `-exec ... +` form needs neither.)

**A3.10** — Exit status **1**. `find` returns 0 only if *everything* went right; any error — permission denied on a subdirectory, a broken `-exec`, an unreadable path — sets the status to non-zero even though the output produced was correct and complete for the readable portion. Consequences: under `set -e` (or `set -o pipefail`) a `find /` in a script aborts the run on the first unreadable directory, so you need `|| true` or a targeted start path. And `2>/dev/null` hides the *messages* but does **not** change the *exit status* — a very common source of "the script silently stopped" reports.

**A3.11**

```bash
sudo find /srv -xdev -type f -name '*.tmp' -mtime +30 -delete
```

Two side effects of `-delete` that `-exec rm {} +` does not have:
1. **`-delete` implies `-depth`.** The traversal switches to post-order so directories are processed after their contents. This silently breaks `-prune`, which has no effect under `-depth` — a `-prune -o ... -delete` expression will descend into and delete the tree you meant to protect.
2. **`-delete` is an action that returns a value and is evaluated in expression order.** Placed too early it deletes before later tests run; and unlike `rm`, it uses `unlinkat()` relative to the open directory FD, which makes it race-safe but also means it will happily remove empty directories when combined with `-type d` — with no `-i`, no confirmation and no `-r` guard.

Always dry-run with `-print` first, then swap in `-delete`.

**A3.12** — Because `-maxdepth` does not test the current node and return a boolean; it changes the behaviour of the **traversal itself**, for the whole run, regardless of where it appears in the expression. `find` parses the expression left to right and evaluates it per node, but global options (`-maxdepth`, `-mindepth`, `-depth`, `-daystart`, `-follow`, `-mount`/`-xdev`, `-regextype`, `-warn`) are hoisted out and applied to everything. Writing them after a test creates code that *reads* as if it were scoped when it is not — hence the warning rather than an error.

---

### Block 4 — `locate` / `updatedb`

**A4.1**
- **`PRUNEFS`** — filesystem *types* to skip entirely (matched case-insensitively against the mount's fstype).
- **`PRUNEPATHS`** — absolute *paths* to skip; the path itself and everything under it.
- **`PRUNENAMES`** — bare **directory names** to skip anywhere in the tree. It takes names only, **not paths and not wildcards**; `.git` skips every `.git` directory on the system.
- **`PRUNE_BIND_MOUNTS`** — `yes`/`no`; when `yes`, skip bind mounts so the same files are not indexed twice under two paths.

**A4.2** — `tmpfs` is pruned because its contents are **volatile** — they vanish on reboot, so indexing them produces a database full of paths that will not exist by the time anyone queries it. `nfs` is pruned because it is **remote**: walking it drags the whole export across the network, hammers the server, and would index files that belong to a different host's namespace (and that every NFS client would then redundantly re-index).

**A4.3** — `locate` reads a **snapshot database**, not the live filesystem; the entry survives until the next `updatedb`. **`locate -e` / `--existing`** suppresses hits whose paths no longer exist. The cost is that `-e` must `stat()` every candidate result, which reintroduces filesystem I/O and permission errors — cheap for a handful of hits, slow for a pattern matching tens of thousands.

**A4.4** — The rule: **if the pattern contains no globbing metacharacter (`*`, `?`, `[`), `locate` implicitly wraps it as `*pattern*`.** So `bash` ≡ `*bash*` — same count. `/bin/bash` *does* contain no metacharacters either, so it becomes `*/bin/bash*`, which matches far fewer paths (only those with that literal substring) than `*bash*`. Conversely, once you write any metacharacter, **no implicit wrapping happens** and the pattern must match the whole path: `locate '*.conf'` works, `locate '.conf'` matches `*.conf*` and also `myconfig`, and `locate 'bash*'` matches nothing at all because no absolute path *starts* with `bash`.

**A4.5** — The binary is **setgid `plocate`** (or `mlocate`). That group owns the database, which is mode `0640 root:plocate` — readable by the group, writable only by root. When you run `locate`, the process gains group `plocate`, opens the database, and then — critically — **filters every candidate result against the calling user's real UID/GID** by checking that the user can `stat()` the path and traverse every parent directory. If the database were mode `0644`, any user could read it directly with `cat`/`strings` and bypass the filter entirely, enumerating the complete filesystem layout including `/root`, other users' home directories, and paths that leak secrets in their names (`/home/alice/.ssh/id_ed25519_prod`). Setgid rather than setuid because read access to one group-owned file is all that is needed — no root privileges are required, so none are granted.

**A4.6** — `--require-visibility 0` writes a database that **does not store the ownership/permission metadata needed for the visibility filter**, and correspondingly marks the database as "no filtering required" — `locate` will return every stored path to any caller who can read the file. For step 9 that is correct: the database is built and owned by you, over a tree you already own, and it is stored at a path only you can read, so the filter would be pure overhead. For `/var/lib/plocate/plocate.db` it would be a serious information disclosure: that database indexes the whole system, including paths under other users' home directories and `/root`, and without the filter every unprivileged user could enumerate them. That is why the system database is always built with `--require-visibility 1` (the default) plus restrictive file permissions.

**A4.7** — Diagnosis: *"`locate` queries a database that is rebuilt on a timer — typically once a day — so a file created five minutes ago is not in it yet. Nothing is wrong with the file."* Confirm with `systemctl list-timers '*updatedb*'` to see the last run. Correct tool: **`find`**, which walks the live filesystem:

```bash
find /path/to/expected -name 'thefile' -mmin -10
```

Or force a refresh with `sudo updatedb` if the user genuinely needs the index current.

**A4.8** — Two fixes:
1. **Add `nfs nfs4` to `PRUNEFS`** (they are in the default list on most distributions — check whether the local file overrides it, or whether the mount reports a different fstype such as `fuse.sshfs`). Trade-off: `locate` can no longer find anything on the fileserver at all; users must use `find` there.
2. **Add the specific mountpoint to `PRUNEPATHS`**, e.g. `PRUNEPATHS="... /mnt/bulk"`. Trade-off: same loss of indexing, but scoped to one path — other NFS mounts stay indexed. A third option is to run `updatedb -U /mnt/bulk -o /mnt/bulk/.plocate.db` **on the fileserver itself** and have clients query it with `locate -d`; trade-off is the operational cost of distributing and permission-managing a second database.

**A4.9**

| Axis | `find` | `locate` |
|---|---|---|
| **Freshness** | live, always current | as of the last `updatedb`; typically up to 24 h stale |
| **Cost** | O(size of tree); minutes on `/` | O(size of result set); milliseconds |
| **Metadata predicates** | size, mtime, permissions, owner, type, inode, links — the full `stat` surface | **name/path only**; no size, time, mode or owner tests |
| **Privilege** | needs read+execute on every directory it descends; produces permission errors as a normal user | reads one group-readable database; results filtered to what the caller could see anyway |

Rule of thumb: **`locate` to find *where* something is by name; `find` to find *which* files satisfy a condition.**

---

### Block 5 — Placement decisions

**A5.1**

| | Correct location | Justification |
|---|---|---|
| (a) local Python script | `/usr/local/bin/` | Locally installed software; `/usr/local` is reserved for the administrator and is not touched by the package manager. |
| (b) static nginx site | `/srv/www/example.com/` | FHS §3.17: `/srv` is "site-specific data which is served by this system". `/var/www` is the distribution's convention, not the FHS's. |
| (c) PostgreSQL data dir | `/var/lib/postgresql/<ver>/` | `/var/lib` holds state information that persists across reboots and is modified as the program runs. |
| (d) PID file | `/run/<name>.pid` or `/run/<name>/<name>.pid` | Volatile runtime data, discarded at boot; `/var/run` is a compatibility symlink. |
| (e) distro systemd unit | `/usr/lib/systemd/system/` (Debian also `/lib/systemd/system` via the merged-`/usr` link) | Package-manager-owned static data under `/usr`. |
| (f) your systemd unit | `/etc/systemd/system/` | Host-specific configuration; also highest precedence, so it overrides the vendor unit. |
| (g) locally compiled `.so` | `/usr/local/lib/` (plus an `/etc/ld.so.conf.d/` entry + `ldconfig`) | Local software's libraries mirror the local hierarchy. |
| (h) the source tarball | `/usr/local/src/` | FHS §4.10: `/usr/src` is for system source code; `/usr/local/src` is its local counterpart. |
| (i) internal CA cert | `/usr/local/share/ca-certificates/*.crt` (Debian) or `/etc/pki/ca-trust/source/anchors/` (RHEL), then run `update-ca-certificates` / `update-ca-trust` | The trust anchor is local, host-affecting configuration; the tool regenerates the bundle under `/etc/ssl/certs`, which you must never edit directly. |
| (j) nightly DB dump | `/var/backups/` or `/var/lib/<app>/backups/` | Variable data, grows over time, must survive reboot; not `/tmp` (cleaned), not `/usr` (should be read-only mountable). |

**A5.2** — For `/usr/local/bin/hello` it is expected: FHS §4.9 says `/usr/local` is "for use by the system administrator when installing software locally", and it "needs to be safe from being overwritten when the system software is updated" — the package manager deliberately does not own anything there. For `/usr/bin/hello-bad` it is a problem for three reasons: (1) a distribution package could later ship a file at the same path and the upgrade would overwrite yours without warning, or fail with a file-conflict; (2) integrity tooling (`debsums`, `rpm -Va`, AIDE, Tripwire) flags unowned files in package-managed directories as intrusion indicators; (3) it will never be removed by any uninstall, so it survives as an orphan forever.

**A5.3** — FHS 3.0 designates **`/srv`** (§3.17). `/var/www` predates `/srv` — it was the de-facto convention before FHS 2.3 introduced `/srv`, and the entire ecosystem of Apache/nginx default vhosts, SELinux `httpd_sys_content_t` labelling, AppArmor profiles and thousands of tutorials is built on it. Distributions keep it because breaking it would break every existing deployment, and because `/srv`'s internal layout is deliberately left unspecified by the FHS ("no program should rely on a specific subdirectory structure"), so there is no portable `/srv` convention to migrate *to*. Both are defensible in production; be consistent, and if you use `/srv` on RHEL remember to set the SELinux context yourself.

**A5.4** — `/opt/<pkg>` holds the **static** files of an add-on package: binaries, libraries, read-only data. `/etc/opt/<pkg>` holds its **host-specific configuration**. `/var/opt/<pkg>` holds its **variable data**: logs, spool, caches, databases. The prohibition on `/opt/<pkg>/etc` exists because `/opt` is classified shareable+static: it must be mountable **read-only** and exportable to many hosts from one server. Configuration is unshareable by definition (each host differs) and variable data must be writable, so both have to live outside the read-only export. The same reasoning is what forces `/usr/local/etc` to be a grey area and why FHS-strict builds keep local config in `/etc` proper.

**A5.5** — **FHS-correct: yes**, in spirit — `/usr/local/lib/<pkg>` is the sanctioned place for local software's architecture-independent-but-not-`share` files, and it parallels the vendor path `/usr/lib/systemd/system`. **Functional: yes** — systemd's unit search path explicitly includes `/usr/local/lib/systemd/system`, at a precedence between the vendor path and `/etc/systemd/system`. The reconciliation: it is the right place for a unit that is part of a *locally installed package* (installed by `make install`, removable as a unit) but the wrong place for a *host-specific* unit you hand-wrote for this one machine — that belongs in `/etc/systemd/system`, which is both the FHS home for host configuration and systemd's highest-precedence directory. Check the live list with `systemd-analyze unit-paths` (or `systemctl show --property=UnitPath`).

**A5.6** — `install -D -m 0755 src dst`:
1. **Sets the mode atomically at creation time.** `cp` then `chmod` leaves a window in which the file exists with the wrong permissions — for a setuid binary or a key file, that window is exploitable. `install` also ignores the umask, so the result is deterministic regardless of the invoking shell's environment.
2. **`-D` creates all missing parent directories** of the destination, so a provisioning script does not need a separate `mkdir -p`, and there is one fewer failure mode when the target tree does not exist yet.

Bonus: `install` also accepts `-o`/`-g` in the same call, writes to a temporary file and renames (so the destination is never seen half-written), and refuses to overwrite a directory with a file.

**A5.7** — Bash's **command hash table**. Once `hello` has been executed successfully, bash caches the resolved path and reuses it without consulting `$PATH` — and it will keep doing so until the cached `execve()` actually fails with `ENOENT`, at which point bash retries a full `PATH` search (this recovery is bash-specific; other shells report "command not found"). **`type hello`** would have shown the truth — `hello is hashed (/usr/local/bin/hello)` — whereas `which hello` and `whereis -b hello` both perform fresh filesystem lookups and would correctly report that the file is gone. Clear it with `hash -r` (all entries) or `hash -d hello` (one entry).

**A5.8** — `man` builds its search path from **`manpath(1)`**, which derives it from `/etc/manpath.config` (Debian family) or `/etc/man_db.conf` / `/etc/man.conf` (RHEL family). Those files contain `MANPATH_MAP` entries that map each `$PATH` element to a corresponding manual hierarchy — `MANPATH_MAP /usr/local/bin /usr/local/share/man` — plus `MANDATORY_MANPATH` entries that are always searched. Because `/usr/local/bin` is in your `$PATH`, `/usr/local/share/man` is automatically added to the manual path; `man -w hello` prints the file it resolved to, and `manpath` prints the whole computed path. No `mandb` index is required for `man <name>` to work — the index only accelerates `man -k` / `apropos` and `whatis`.

---

### Block 6 — Integration

**A6.1** — Cheapest to most expensive:

1. **`type -a`** — free, in-process, no syscalls beyond the hash table and `$PATH` stats. Proves: what *this shell* would run, including aliases and functions that the other tools cannot see.
2. **`command -v`** — same cost, POSIX. Proves resolvability without the classification detail.
3. **`whereis -b`** — one process, stats a small hardcoded directory list. Proves: whether the binary sits in a *standard* location that is nonetheless outside your `$PATH` (the classic `/usr/sbin` not in a non-root user's PATH).
4. **`locate -b`** — one process, one indexed database read, milliseconds. Proves: whether the file exists **anywhere** on the system as of the last `updatedb` — the first check with whole-filesystem reach.
5. **`find / -xdev`** — full tree walk, seconds to minutes, needs root for completeness. Proves: ground truth right now, plus every metadata predicate (`%M %u:%g %s %TF`) that tells you *why* it is not running — wrong mode, wrong owner, zero bytes, wrong architecture.

Each rung answers something the one below cannot; run them in order and stop at the first that resolves the question.

**A6.2** — The shell processes the double-quoted string first and turns `\\` into a single literal `\`, so `locate` receives the argument `\report-gen`. `locate` then interprets the leading backslash as **"this pattern is literal — do not apply the implicit `*pattern*` wrapping"**, combined with `-b` giving an exact basename match. Without it, `locate -b "$cmd"` would receive `report-gen`, apply implicit globbing to `*report-gen*`, and match `report-gen.bak`, `old-report-gen`, `report-generator`, `report-gen.1.gz` — false positives that would make the script report success for a file that is not the command.

**A6.3** — `-quit` makes `find` **exit immediately after the first match**, turning a worst-case full-tree walk into an early return. On a large `/` that is the difference between seconds and minutes, and it matters here because the script only needs an existence answer, not an enumeration. The cost: you learn that *a* file with that name exists, but not **how many** or **which one wins** — if the binary is installed in three places with different versions or modes, `-quit` hides that, and the one it happens to hit first depends on directory traversal order, which is not sorted and not stable across filesystems. For a diagnostic that must distinguish duplicates, drop `-quit` and accept the cost.

**A6.4** — `-o` is a short-circuit OR over an expression evaluated per node, and `-prune` **returns true**. So the left branch `\( -path ... \) -prune` succeeds for the excluded directories, short-circuits, and the right branch never runs for them — that is the exclusion. But for every node that does *not* match the left branch, the OR falls through to the right branch, and that branch must **restate the tests it actually wants**, because nothing from the left branch carries over: `-o` composes two independent complete expressions, it does not "continue" the first. Additionally, since the expression now contains an explicit action (`-print`), the implicit `-print` is suppressed everywhere, so the right branch must supply its own. Hence `... -prune -o -type f -mtime -1 -print`.

**A6.5**
- **Portability**: `command -v` is specified by POSIX.1-2017 and is a shell builtin, so it exists on every conforming shell and needs no external binary. `which` is not in POSIX; there are at least four mutually incompatible implementations (debianutils' `/bin/sh` script, GNU `which`, BSD `which`, zsh's builtin) differing in exit status, output format and `-a` semantics, and it is absent entirely from minimal container images and busybox-less rescue environments.
- **Correctness**: `command -v` resolves the way the shell will actually resolve, so it reports builtins, functions and aliases, and it respects the shell's own `$PATH` handling. A script that tests with `which` and then invokes the name can get a different program than the one `which` reported — the stale-hash case from Block 2, or a shell function shadowing the PATH binary. Testing and invoking through the same resolution mechanism removes that class of bug.

</details>