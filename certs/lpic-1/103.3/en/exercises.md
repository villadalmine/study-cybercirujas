# 103.3 — Perform Basic File Management
## Guided Exercises (LPIC-1, exam 101-500, v5.0 — weight 6.25)

**Environment assumed:** a Linux system with GNU coreutils ≥ 8.30, GNU findutils, GNU tar ≥ 1.30, GNU cpio, and `bash` 5.x. Where BSD/busybox behaviour differs materially, it is flagged. All work happens inside a disposable lab tree — nothing outside `~/lpic1-lab` is touched, with two exceptions that are explicitly marked read-only (`/etc/hostname`) or scratch (`/tmp`, `/dev/shm`).

> **Safety rule for this whole module:** every `rm -rf` and every `dd of=` in these exercises points at a path under your lab directory. Read each command before pressing Enter. `dd` writing to a `/dev/sd*` or `/dev/nvme*` node destroys a disk; there is no undo and no confirmation prompt.

---

## Exercise 0 — Lab bootstrap

```bash
mkdir -p ~/lpic1-lab/103.3
cd ~/lpic1-lab/103.3
export LAB="$PWD"
echo "$LAB"
```

Verify you are in the right place before continuing; every later exercise starts with `cd "$LAB"`.

---

## Exercise 1 — Creating a tree, and reading what the filesystem actually stores

`ls`, `mkdir`, `touch`, `stat`, hard links vs symbolic links.

### Steps

1. Build the directory skeleton in a single command:

   ```bash
   cd "$LAB"
   mkdir -p project/{src,doc,build/obj,logs}
   ```

2. Inspect what was created:

   ```console
   $ find project -type d | sort
   project
   project/build
   project/build/obj
   project/doc
   project/logs
   project/src
   ```

3. Create empty regular files, again with brace expansion:

   ```bash
   touch project/src/{main,util,parser}.c
   touch project/doc/{README.md,design.txt}
   ```

4. Create three binary files of known, different sizes:

   ```bash
   for i in 1 2 3; do
     head -c $((i * 1024)) /dev/urandom > "project/build/obj/mod$i.o"
   done
   ls -l project/build/obj
   ```

   ```console
   -rw-r--r--. 1 user user 1024 Aug 26 10:14 mod1.o
   -rw-r--r--. 1 user user 2048 Aug 26 10:14 mod2.o
   -rw-r--r--. 1 user user 3072 Aug 26 10:14 mod3.o
   ```

5. Read the full metadata of one file:

   ```console
   $ stat project/src/main.c
     File: project/src/main.c
     Size: 0            Blocks: 0          IO Block: 4096   regular empty file
   Device: 0,42   Inode: 1179651     Links: 1
   Access: (0644/-rw-r--r--)  Uid: ( 1000/    user)   Gid: ( 1000/    user)
   Access: 2026-08-26 10:14:02.113254190 -0300
   Modify: 2026-08-26 10:14:02.113254190 -0300
   Change: 2026-08-26 10:14:02.113254190 -0300
    Birth: 2026-08-26 10:14:02.113254190 -0300
   ```

6. Create a **hard link** and a **symbolic link** to the same file, then compare:

   ```bash
   ln    project/src/main.c project/src/main.c.hard
   ln -s ../src/main.c      project/doc/main.c.sym
   ```

   ```console
   $ ls -li project/src/
   total 0
   1179651 -rw-r--r--. 2 user user 0 Aug 26 10:14 main.c
   1179651 -rw-r--r--. 2 user user 0 Aug 26 10:14 main.c.hard
   1179654 -rw-r--r--. 1 user user 0 Aug 26 10:14 parser.c
   1179653 -rw-r--r--. 1 user user 0 Aug 26 10:14 util.c

   $ ls -l project/doc/
   total 4
   -rw-r--r--. 1 user user  0 Aug 26 10:14 README.md
   -rw-r--r--. 1 user user  0 Aug 26 10:14 design.txt
   lrwxrwxrwx. 1 user user 13 Aug 26 10:16 main.c.sym -> ../src/main.c
   ```

7. Manipulate timestamps deliberately — this matters for `find` later:

   ```bash
   touch -d '2020-01-01 09:00:00' project/src/main.c
   touch -d '10 days ago'  project/logs/old.log      # -d creates the file too
   touch -d '2 days ago'   project/logs/recent.log
   touch -d '30 min ago'   project/logs/fresh.log
   touch -c project/logs/does-not-exist.log          # -c: do NOT create
   ls -l project/logs
   ```

8. Compare the three timestamps of `main.c` after the change:

   ```console
   $ stat -c 'atime=%x%nmtime=%y%nctime=%z' project/src/main.c
   atime=2020-01-01 09:00:00.000000000 -0300
   mtime=2020-01-01 09:00:00.000000000 -0300
   ctime=2026-08-26 10:18:41.552091223 -0300
   ```

9. List by size and by modification time:

   ```bash
   ls -lhS project/build/obj      # -S: largest first
   ls -lt  project/logs           # -t: newest first
   ls -ltu project/logs           # -u with -l: show/sort by ACCESS time
   ls -d   project/*/             # -d: the directories themselves, not contents
   ```

### Questions — block 1

- **Q1.1** In step 6, which of `main.c.hard` and `main.c.sym` shares an inode with `main.c`? What number in `ls -li` proves it, and what is the *third* column of `ls -l` counting?
- **Q1.2** `ls -l` reports size `13` for `main.c.sym` while `main.c` has size `0`. Where does 13 come from?
- **Q1.3** `stat` reports `Size: 0` **and** `Blocks: 0` for `main.c`, but `IO Block: 4096`. Explain all three.
- **Q1.4** In step 8, `touch -d` set atime and mtime to 2020, but ctime shows *now* and cannot be set to 2020 with any `touch` flag. Why?
- **Q1.5** Is `project/{src,doc,build/obj,logs}` in step 1 a glob (wildcard) expansion? What would happen if `project/src` already existed and you ran the same `mkdir -p` again?
- **Q1.6** What does `ls -d project/*/` return that `ls project` does not, and why the trailing slash?

---

## Exercise 2 — `cp`: recursion, target semantics, and metadata

### Steps

1. Copy a single file, verbosely:

   ```console
   $ cd "$LAB"
   $ cp -v project/doc/README.md /tmp/
   'project/doc/README.md' -> '/tmp/README.md'
   ```

2. Try to copy a directory **without** recursion:

   ```console
   $ cp project/src /tmp/src-copy
   cp: -r not specified; omitting directory 'project/src'
   $ echo $?
   1
   ```

3. Now copy it recursively into a target that **does not exist**:

   ```console
   $ cp -r project/src /tmp/src-copy
   $ ls /tmp/src-copy
   main.c  main.c.hard  parser.c  util.c
   ```

4. Run the **exact same command a second time** and look carefully:

   ```console
   $ cp -r project/src /tmp/src-copy
   $ find /tmp/src-copy -maxdepth 2 | sort
   /tmp/src-copy
   /tmp/src-copy/main.c
   /tmp/src-copy/main.c.hard
   /tmp/src-copy/parser.c
   /tmp/src-copy/src
   /tmp/src-copy/src/main.c
   /tmp/src-copy/src/main.c.hard
   /tmp/src-copy/src/parser.c
   /tmp/src-copy/src/util.c
   /tmp/src-copy/util.c
   ```

5. Copy **contents only** into an existing directory — the `/.` idiom:

   ```bash
   rm -rf /tmp/src-copy
   mkdir  /tmp/src-copy
   cp -r project/src/. /tmp/src-copy/
   find /tmp/src-copy -maxdepth 1 | sort
   ```

6. Compare plain `cp` with `cp -p` on the 2020-dated file:

   ```console
   $ cp    project/src/main.c /tmp/plain.c
   $ cp -p project/src/main.c /tmp/preserved.c
   $ stat -c '%n  mtime=%y  mode=%a' /tmp/plain.c /tmp/preserved.c
   /tmp/plain.c  mtime=2026-08-26 10:31:07.884...  mode=644
   /tmp/preserved.c  mtime=2020-01-01 09:00:00.000...  mode=644
   ```

7. Copy the whole tree in archive mode and check how links survived:

   ```console
   $ cp -a project /tmp/project-a
   $ ls -l /tmp/project-a/doc/main.c.sym
   lrwxrwxrwx. 1 user user 13 Aug 26 10:16 /tmp/project-a/doc/main.c.sym -> ../src/main.c

   $ ls -li /tmp/project-a/src/main.c /tmp/project-a/src/main.c.hard
   2231455 -rw-r--r--. 2 user user 0 Jan  1  2020 /tmp/project-a/src/main.c
   2231455 -rw-r--r--. 2 user user 0 Jan  1  2020 /tmp/project-a/src/main.c.hard
   ```

8. Now dereference instead:

   ```console
   $ cp -rL project /tmp/project-L
   $ ls -l /tmp/project-L/doc/main.c.sym
   -rw-r--r--. 1 user user 0 Jan  1  2020 /tmp/project-L/doc/main.c.sym

   $ ls -li /tmp/project-L/src/main.c /tmp/project-L/src/main.c.hard
   2231701 -rw-r--r--. 1 user user 0 ... /tmp/project-L/src/main.c
   2231702 -rw-r--r--. 1 user user 0 ... /tmp/project-L/src/main.c.hard
   ```

9. Test `-u` (update) and `-n` (no-clobber):

   ```console
   $ echo "v2" > project/doc/README.md
   $ cp -u -v project/doc/README.md /tmp/
   'project/doc/README.md' -> '/tmp/README.md'
   $ cp -u -v project/doc/README.md /tmp/          # nothing to do now
   $ cp -n -v project/doc/README.md /tmp/
   $ cat /tmp/README.md
   v2
   ```

10. Interactive and backup behaviour:

    ```console
    $ echo "v3" > project/doc/README.md
    $ cp -i project/doc/README.md /tmp/
    cp: overwrite '/tmp/README.md'? n
    $ cp --backup=numbered project/doc/README.md /tmp/
    $ ls /tmp/README.md*
    /tmp/README.md  /tmp/README.md.~1~
    ```

> **Production note.** On Btrfs and XFS, `cp --reflink=auto` makes a copy-on-write clone: the copy is instantaneous and consumes no extra space until one of the two is modified. It is not on the exam, but on a Fedora/RHEL box with Btrfs it is the correct default for copying large images.

### Questions — block 2

- **Q2.1** Steps 3 and 4 ran the *identical* command and produced different results. State the rule `cp` applies to its final argument.
- **Q2.2** `cp` is supposed to be safe to repeat. Was step 4 idempotent? How do you write a recursive copy that *is* idempotent?
- **Q2.3** What exactly does `-a` expand to, and which of its components is responsible for the symlink surviving as a symlink in step 7?
- **Q2.4** In step 7 the hard link was preserved as a hard link (same inode, link count 2). In step 8 it became two independent files. Which option caused that, and what is the disk-space consequence for a large tree?
- **Q2.5** `cp -p` preserved mode, ownership and timestamps. If you run `cp -p` as a normal user on a file owned by `root`, which part of `-p` fails, and what does `cp` do about it?
- **Q2.6** Distinguish `cp -u`, `cp -n` and `cp -i`. Which one is *content*-aware and which two are purely existence/timestamp-based?

---

## Exercise 3 — `mv`, `rm`, `rmdir`, and filenames that fight back

### Steps

1. Rename within the same filesystem and watch the inode:

   ```console
   $ cd "$LAB"
   $ ls -i project/doc/design.txt
   1179656 project/doc/design.txt
   $ mv project/doc/design.txt project/doc/architecture.txt
   $ ls -i project/doc/architecture.txt
   1179656 project/doc/architecture.txt
   ```

2. Prove that `/dev/shm` is a different filesystem, then move across it:

   ```console
   $ stat -c '%n is on device %d' . /dev/shm
   . is on device 42
   /dev/shm is on device 24

   $ cp project/build/obj/mod3.o .
   $ ls -i mod3.o
   1179660 mod3.o
   $ mv mod3.o /dev/shm/
   $ ls -i /dev/shm/mod3.o
   17 /dev/shm/mod3.o
   $ rm /dev/shm/mod3.o
   ```

3. Move a directory onto an existing directory name:

   ```console
   $ mkdir -p /tmp/dest
   $ cp -a project/logs /tmp/logs-a
   $ mv /tmp/logs-a /tmp/dest
   $ ls /tmp/dest
   logs-a
   ```

4. Safe overwrite controls:

   ```bash
   cp project/doc/README.md /tmp/target.md
   echo "newer" > /tmp/source.md
   mv -n -v /tmp/source.md /tmp/target.md     # refuses, source stays
   mv -b -v /tmp/source.md /tmp/target.md     # keeps /tmp/target.md~
   ls /tmp/target.md*
   ```

5. `rmdir` only removes **empty** directories:

   ```console
   $ rmdir project
   rmdir: failed to remove 'project': Directory not empty

   $ mkdir -p /tmp/a/b/c
   $ rmdir -p /tmp/a/b/c
   $ ls -d /tmp/a
   ls: cannot access '/tmp/a': No such file or directory
   ```

6. Now the hostile filenames. Create them in an isolated directory:

   ```bash
   mkdir -p /tmp/nasty && cd /tmp/nasty
   touch -- -i
   touch -- --help
   touch 'two words'
   touch $'line\nbreak'
   touch '*'
   ls -b
   ```

   ```console
   $ ls -b
   --help  -i  line\nbreak  two\ words  *
   ```

7. Watch what happens when the shell hands `-i` to `rm` as an option:

   ```console
   $ rm *
   rm: remove regular empty file '*'? 
   ```

   Answer `n` and press Enter. The file literally named `-i` was expanded by the glob, sorted first, and `rm` parsed it as the *interactive* flag.

8. Remove them correctly, two ways:

   ```bash
   rm -- -i --help
   rm ./'*'
   rm 'two words'
   find . -maxdepth 1 -type f -print0 | xargs -0 rm -v --
   cd "$LAB"; rmdir /tmp/nasty
   ```

9. Recursive removal, and the guard rail you must internalise:

   ```bash
   cp -a project /tmp/project-doomed
   rm -rf /tmp/project-doomed
   ls -d /tmp/project-doomed 2>&1
   ```

   Now read — **do not run** — the classic destroyer:

   ```bash
   # NEVER: if $DIR is unset or empty this becomes  rm -rf /
   rm -rf $DIR/
   # Correct form in any script:
   set -u
   rm -rf -- "${DIR:?DIR must be set}"/
   ```

### Questions — block 3

- **Q3.1** In step 1 the inode was unchanged; in step 2 it changed. Which system call did each `mv` use, and what does that imply about the *duration* and *atomicity* of the operation?
- **Q3.2** After a cross-filesystem `mv`, which of atime/mtime/ctime is guaranteed to change, and which does `mv` deliberately carry over?
- **Q3.3** A 40 GB file is moved with `mv` from `/home` to `/var` on separate partitions and the process is killed halfway. What is the state of the source and the destination?
- **Q3.4** In step 7, `rm` prompted even though you never typed `-i`. Explain the exact chain of events, and give the two independent fixes.
- **Q3.5** Why does `rmdir` exist at all when `rm -r` can delete directories? Name one situation where `rmdir` is the *safer* tool.
- **Q3.6** Why does the pipeline in step 8 use `-print0` and `xargs -0` instead of `find . -type f | xargs rm`?
- **Q3.7** In the guard-rail snippet, what do `set -u` and `${DIR:?...}` each protect against, and why is `--` still needed?

---

## Exercise 4 — File globbing: simple and advanced

Globbing is performed by the **shell**, not by the command. Everything in this exercise is bash behaviour.

### Steps

1. Build a controlled filename set:

   ```bash
   mkdir -p "$LAB/glob" && cd "$LAB/glob"
   touch file{1..12}.txt data.csv notes.TXT .hidden .config
   touch report-2023.log report-2024.log report-2025.log
   touch archive.tar.gz archive.tar.bz2 archive.tar.xz
   mkdir -p sub/deep && touch sub/a.c sub/deep/b.c
   ls -a
   ```

2. `*` — any string, including empty, but **not** a leading dot:

   ```console
   $ echo *.txt
   file1.txt file10.txt file11.txt file12.txt file2.txt file3.txt file4.txt file5.txt file6.txt file7.txt file8.txt file9.txt
   $ echo *
   archive.tar.bz2 archive.tar.gz archive.tar.xz data.csv file1.txt ... notes.TXT report-2023.log report-2024.log report-2025.log sub
   ```

3. `?` — exactly one character:

   ```console
   $ echo file?.txt
   file1.txt file2.txt file3.txt file4.txt file5.txt file6.txt file7.txt file8.txt file9.txt
   $ echo file??.txt
   file10.txt file11.txt file12.txt
   ```

4. Bracket expressions — set, range, and negation:

   ```console
   $ echo file[1-3].txt
   file1.txt file2.txt file3.txt
   $ echo file[!1-3].txt
   file4.txt file5.txt file6.txt file7.txt file8.txt file9.txt
   $ echo report-20[23][45].log
   report-2024.log report-2025.log
   ```

5. POSIX character classes — locale-safe, unlike raw ranges:

   ```console
   $ echo *[[:upper:]]*
   notes.TXT
   $ echo [[:digit:]]*        # no filename starts with a digit
   [[:digit:]]*
   ```

6. Dotfiles: `*` never matches them. Three ways to reach them:

   ```console
   $ echo .*
   . .. .config .hidden
   $ echo .[!.]*
   .config .hidden
   $ shopt -s dotglob; echo *; shopt -u dotglob
   .config .hidden archive.tar.bz2 archive.tar.gz ...
   ```

7. Unmatched globs: default vs `nullglob` vs `failglob`:

   ```console
   $ echo *.nomatch
   *.nomatch
   $ shopt -s nullglob; echo "[$(echo *.nomatch)]"; shopt -u nullglob
   []
   $ shopt -s failglob; echo *.nomatch; shopt -u failglob
   bash: no match: *.nomatch
   ```

8. Brace expansion is **not** globbing — it happens first and needs no files:

   ```console
   $ echo {a,b,c}.iso
   a.iso b.iso c.iso
   $ echo file{1..3}.txt
   file1.txt file2.txt file3.txt
   $ echo archive.tar.{gz,bz2,xz}
   archive.tar.gz archive.tar.bz2 archive.tar.xz
   ```

   Note the *order* in that last line: braces preserve the order you wrote, globs are sorted.

9. Extended globs (`extglob`) — the "advanced wildcard specifications" of the objective:

   ```console
   $ shopt -s extglob
   $ echo !(file*|sub)
   archive.tar.bz2 archive.tar.gz archive.tar.xz data.csv notes.TXT report-2023.log report-2024.log report-2025.log
   $ echo report-@(2024|2025).log
   report-2024.log report-2025.log
   $ echo archive.tar.?(gz|xz)
   archive.tar.gz archive.tar.xz
   $ echo file+([0-9]).txt
   file1.txt file10.txt file11.txt file12.txt file2.txt ... file9.txt
   $ shopt -u extglob
   ```

10. `globstar` for recursive matching:

    ```console
    $ shopt -s globstar
    $ echo **/*.c
    sub/a.c sub/deep/b.c
    $ shopt -u globstar
    $ echo **/*.c
    sub/a.c
    ```

11. Quoting — the difference between shell globbing and program-side pattern matching:

    ```console
    $ find . -name *.txt
    find: paths must precede expression: 'file10.txt'
    find: possible expression starting point: '-name'

    $ find . -name '*.txt' | wc -l
    12
    ```

### Questions — block 4

- **Q4.1** Which process expands `*.txt` — `ls`, or the shell? What does `ls` actually receive in its `argv`?
- **Q4.2** Why does `echo file?.txt` return nine names while `echo file*.txt` returns twelve?
- **Q4.3** Give the glob for "every file whose name ends in `.log` and whose fourth-from-last character is a digit other than 3", using `[!...]`.
- **Q4.4** Why is `[a-z]` a hazard in a script that may run under a non-C locale, and what replaces it?
- **Q4.5** `echo .*` printed `.` and `..`. Why is `rm -rf .*` a catastrophic command, and what is the safe idiom?
- **Q4.6** Why did `echo *.nomatch` print the pattern itself instead of nothing? Name the two `shopt` options that change this and describe the difference between them.
- **Q4.7** `touch file{1..12}.txt` worked in an empty directory, but `touch file*.txt` in an empty directory creates a file literally named `file*.txt`. Explain both behaviours in terms of expansion order.
- **Q4.8** In step 11, the unquoted `find . -name *.txt` failed. Explain the failure precisely, and explain why it would have *silently succeeded with the wrong result* if exactly one `.txt` file had existed.

---

## Exercise 5 — `find`: locating and acting on files

### Steps

1. Return to the project tree and add material with known sizes and ages:

   ```bash
   cd "$LAB"
   head -c 500      /dev/urandom > project/logs/tiny.bin
   head -c 5000     /dev/urandom > project/logs/small.bin
   head -c 2000000  /dev/urandom > project/logs/big.bin
   touch -d '10 days ago' project/logs/old.log
   touch -d '2 days ago'  project/logs/recent.log
   touch -d '30 min ago'  project/logs/fresh.log
   touch project/build/obj/tmp1.tmp project/build/obj/tmp2.tmp
   chmod 600 project/doc/architecture.txt
   chmod 755 project/src/main.c
   ```

2. Type and name tests:

   ```console
   $ find project -type f -name '*.c'
   project/src/parser.c
   project/src/util.c
   project/src/main.c
   project/src/main.c.hard

   $ find project -type d
   project
   project/src
   project/doc
   project/build
   project/build/obj
   project/logs

   $ find project -type l
   project/doc/main.c.sym

   $ find project -iname '*.TXT'
   project/doc/architecture.txt
   ```

3. Depth control — `-maxdepth` / `-mindepth` must come **before** the tests:

   ```console
   $ find project -maxdepth 1 -type f
   $ find project -mindepth 2 -maxdepth 2 -type f | sort
   project/build/obj ...
   $ find project -type f -maxdepth 1
   find: warning: you have specified the global option -maxdepth after the argument -type, but global options are not positional...
   ```

4. Size tests — and the rounding trap:

   ```console
   $ find project/logs -type f -size +4k
   project/logs/small.bin
   project/logs/big.bin

   $ find project/logs -type f -size +1M
   project/logs/big.bin

   $ find project/logs -type f -size -1M
   project/logs/old.log
   project/logs/recent.log
   project/logs/fresh.log

   $ find project/logs -type f -size -1000000c
   project/logs/tiny.bin
   project/logs/small.bin
   project/logs/old.log
   project/logs/recent.log
   project/logs/fresh.log

   $ find project -type f -empty | head -3
   ```

5. Time tests:

   ```console
   $ find project/logs -type f -name '*.log' -mtime +7
   project/logs/old.log

   $ find project/logs -type f -name '*.log' -mtime -3
   project/logs/recent.log
   project/logs/fresh.log

   $ find project/logs -type f -mmin -60
   project/logs/fresh.log
   project/logs/tiny.bin
   project/logs/small.bin
   project/logs/big.bin

   $ find project -type f -newer project/logs/recent.log -name '*.log'
   project/logs/fresh.log
   ```

6. Permission tests — the three modes of `-perm`:

   ```console
   $ find project -type f -perm 600
   project/doc/architecture.txt

   $ find project -type f -perm -u+x
   project/src/main.c
   project/src/main.c.hard

   $ find project -type f -perm /o+w
   $ find project -type f ! -perm -o+r | head
   project/doc/architecture.txt
   ```

7. Ownership, and boolean composition:

   ```console
   $ find project -type f -user "$USER" -group "$(id -gn)" | wc -l
   $ find project -type f \( -name '*.tmp' -o -name '*.o' \) -printf '%s\t%p\n'
   1024	project/build/obj/mod1.o
   2048	project/build/obj/mod2.o
   3072	project/build/obj/mod3.o
   0	project/build/obj/tmp1.tmp
   0	project/build/obj/tmp2.tmp
   ```

8. `-exec` in both forms — count the invocations:

   ```console
   $ find project -name '*.c' -exec sh -c 'echo "call with $# arg(s)"' _ {} \;
   call with 1 arg(s)
   call with 1 arg(s)
   call with 1 arg(s)
   call with 1 arg(s)

   $ find project -name '*.c' -exec sh -c 'echo "call with $# arg(s)"' _ {} +
   call with 4 arg(s)
   ```

9. `-exec` vs `xargs`, safely:

   ```bash
   find project -type f -name '*.o' -exec cp -v {} /tmp/ \;
   find project -type f -name '*.o' -print0 | xargs -0 -r cp -v -t /tmp/
   find project -type f -name '*.o' -print0 | xargs -0 -r -n1 -P4 sha256sum
   ```

10. Pruning a subtree — note that `-prune` is an *action* that returns true:

    ```console
    $ find project -path project/build -prune -o -type f -print | sort
    project/doc/README.md
    project/doc/architecture.txt
    project/logs/big.bin
    ...
    project/src/util.c
    ```

    Compare with the naive, wrong version:

    ```console
    $ find project -path project/build -prune -o -type f | sort
    project/build
    project/doc/README.md
    ...
    ```

11. Deletion — and its ordering hazard:

    ```console
    $ find project -type f -name '*.tmp' -print
    project/build/obj/tmp1.tmp
    project/build/obj/tmp2.tmp
    $ find project -type f -name '*.tmp' -delete
    $ find project -type f -name '*.tmp' | wc -l
    0
    ```

    Read, **do not run**:

    ```bash
    # -delete comes FIRST: find evaluates left to right, so this deletes
    # everything it can before -name is ever consulted.
    find project -delete -name '*.tmp'
    ```

12. Broken symlinks and regex matching:

    ```console
    $ ln -s /nonexistent/path project/doc/dangling.sym
    $ find project -xtype l
    project/doc/dangling.sym
    $ find project -regextype posix-extended -regex '.*/(mod[0-9]+\.o|.*\.c)$' | sort
    ```

### Questions — block 5

- **Q5.1** `-size -1M` matched only the empty `.log` files and skipped a 500-byte and a 5000-byte file, while `-size -1000000c` matched them. Explain the rounding rule that produces this.
- **Q5.2** Translate `-mtime +7` and `-mtime -3` into precise statements about elapsed time. Where does the fractional part of a day go?
- **Q5.3** Distinguish `-perm 600`, `-perm -600` and `-perm /600` with one example file each.
- **Q5.4** In step 8, `\;` produced four process spawns and `+` produced one. When is `\;` *required* even though `+` is faster?
- **Q5.5** Why must `{}` and `;` be escaped or quoted in `-exec ... \;`?
- **Q5.6** Rewrite `find project -name '*.o' | xargs rm` so it is correct for filenames containing spaces *and* does not run `rm` at all when nothing matches.
- **Q5.7** In step 10, why is `-o -type f -print` needed instead of just `-o -type f`? What implicit action does `find` add, and why does `-prune` suppress it?
- **Q5.8** `-delete` implies `-depth`. Why is that implication necessary, and why does it make `-prune` and `-delete` unsafe to combine?
- **Q5.9** Why did `-maxdepth` produce a warning in step 3 but still work? What is the risk of relying on that?

---

## Exercise 6 — `tar`: archiving with and without compression

### Steps

1. Create an uncompressed archive and inspect it:

   ```console
   $ cd "$LAB"
   $ tar -cvf project.tar project
   project/
   project/src/
   project/src/main.c
   ...
   $ ls -l project.tar
   -rw-r--r--. 1 user user 2078720 Aug 26 11:02 project.tar

   $ tar -tvf project.tar | head -5
   drwxr-xr-x user/user         0 2026-08-26 11:01 project/
   drwxr-xr-x user/user         0 2026-08-26 10:16 project/src/
   -rwxr-xr-x user/user         0 2020-01-01 09:00 project/src/main.c
   -rw-r--r-- user/user         0 2026-08-26 10:14 project/src/parser.c
   lrwxrwxrwx user/user         0 2026-08-26 10:16 project/doc/main.c.sym -> ../src/main.c
   ```

2. Absolute paths are stripped — observe the warning:

   ```console
   $ tar -cvf /tmp/host.tar /etc/hostname
   tar: Removing leading `/' from member names
   /etc/hostname
   $ tar -tf /tmp/host.tar
   etc/hostname
   ```

3. Compare the three compressors on the same input:

   ```console
   $ tar -czf project.tar.gz  project
   $ tar -cjf project.tar.bz2 project
   $ tar -cJf project.tar.xz  project
   $ ls -l project.tar*
   -rw-r--r--. 1 user user 2078720 Aug 26 11:02 project.tar
   -rw-r--r--. 1 user user 2016... Aug 26 11:03 project.tar.bz2
   -rw-r--r--. 1 user user 2013... Aug 26 11:03 project.tar.gz
   -rw-r--r--. 1 user user 2010... Aug 26 11:04 project.tar.xz
   ```

   (The payload here is `/dev/urandom` output, which is incompressible — that is the point of the question below. Re-run with a text-heavy tree to see real ratios.)

4. Autodetect on read; `-a` to pick the compressor from the suffix on write:

   ```bash
   tar -tf project.tar.xz | head -3          # no -J needed
   tar -caf project2.tar.gz project          # -a: infer gzip from the name
   file project2.tar.gz
   ```

5. Extract into a chosen directory, and strip a leading path component:

   ```console
   $ mkdir -p /tmp/restore1 /tmp/restore2
   $ tar -xf project.tar.gz -C /tmp/restore1
   $ ls /tmp/restore1
   project

   $ tar -xf project.tar.gz -C /tmp/restore2 --strip-components=1
   $ ls /tmp/restore2
   build  doc  logs  src
   ```

6. Extract a **single member**:

   ```console
   $ tar -xvf project.tar.gz -C /tmp project/doc/README.md
   project/doc/README.md
   $ cat /tmp/project/doc/README.md
   v3
   ```

7. Pattern matching on member names — always be explicit:

   ```console
   $ tar -tvf project.tar --wildcards 'project/src/*.c'
   -rwxr-xr-x user/user  0 2020-01-01 09:00 project/src/main.c
   -rw-r--r-- user/user  0 2026-08-26 10:14 project/src/parser.c
   -rw-r--r-- user/user  0 2026-08-26 10:14 project/src/util.c
   ```

8. Exclusions — place them **before** the paths they affect:

   ```console
   $ tar -czf project-clean.tar.gz --exclude='*.o' --exclude='logs' project
   $ tar -tf project-clean.tar.gz | grep -cE '\.o$|logs'
   0
   ```

9. Build an archive from a `find` result, NUL-safely:

   ```bash
   find project -type f -name '*.c' -print0 \
     | tar --null --no-recursion -T - -czf sources.tar.gz
   tar -tf sources.tar.gz
   ```

10. Verify an archive against the live tree:

    ```console
    $ tar -df project.tar
    $ echo "changed" >> project/doc/README.md
    $ tar -df project.tar
    project/doc/README.md: Mod time differs
    project/doc/README.md: Size differs
    $ echo $?
    1
    ```

11. Append and update — only on **uncompressed** archives:

    ```console
    $ echo "note" > extra.txt
    $ tar -rvf project.tar extra.txt
    extra.txt
    $ tar -rvf project.tar.gz extra.txt
    tar: Cannot update compressed archives
    tar: Error is not recoverable: exiting now
    ```

12. Permissions on extract, as a non-root user:

    ```console
    $ umask
    0022
    $ chmod 777 project/logs/fresh.log
    $ tar -cf perm.tar project/logs/fresh.log
    $ mkdir -p /tmp/pt && tar -xf perm.tar -C /tmp/pt
    $ stat -c %a /tmp/pt/project/logs/fresh.log
    755
    $ rm -rf /tmp/pt && mkdir -p /tmp/pt
    $ tar -xpf perm.tar -C /tmp/pt
    $ stat -c %a /tmp/pt/project/logs/fresh.log
    777
    ```

### Questions — block 6

- **Q6.1** `tar -czf` and `tar -zcf` both work, but `tar -cfz project.tar.gz project` does not. Why? What is special about `-f`?
- **Q6.2** Why does `tar` strip the leading `/`, and what is the security scenario that motivated it? Which option turns the stripping off, and why should you never use it on an untrusted archive?
- **Q6.3** The three compressed archives in step 3 were all about the same size. What property of the input explains that, and what would you expect for a tree of source code and logs? Rank gzip/bzip2/xz on ratio, compression speed and decompression speed.
- **Q6.4** You have `app-1.4.2/` inside `app.tar.gz` but you want its contents directly in `/opt/app`. Write the single `tar` command.
- **Q6.5** Why does `-r` fail on `project.tar.gz` but succeed on `project.tar`? What is the structural difference between the two files?
- **Q6.6** In step 12, extracting without `-p` gave mode `755` instead of `777`. What applied the mask, and how does the default differ when `root` extracts?
- **Q6.7** In step 9, why are `--null` **and** `--no-recursion` both needed?
- **Q6.8** Given only `project.tar.gz`, list every member larger than 1 MB without extracting anything.

---

## Exercise 7 — `cpio`

`cpio` reads its file list from **stdin** and writes the archive to **stdout**. That is the whole design, and everything else follows from it.

### Steps

1. Copy-out mode (`-o`) — create an archive:

   ```console
   $ cd "$LAB"
   $ find project -depth -print | cpio -o -H newc > project.cpio
   4063 blocks
   $ ls -l project.cpio
   -rw-r--r--. 1 user user 2080256 Aug 26 11:20 project.cpio
   $ file project.cpio
   project.cpio: ASCII cpio archive (SVR4 with no CRC)
   ```

2. List the contents (`-t`), verbosely:

   ```console
   $ cpio -itv < project.cpio | head -5
   -rwxr-xr-x   2 user     user            0 Jan  1  2020 project/src/main.c
   -rw-r--r--   1 user     user            0 Aug 26 10:14 project/src/parser.c
   -rw-r--r--   1 user     user            0 Aug 26 10:14 project/src/util.c
   drwxr-xr-x   2 user     user            0 Aug 26 10:16 project/src
   lrwxrwxrwx   1 user     user           13 Aug 26 10:16 project/doc/main.c.sym -> ../src/main.c
   ```

3. Copy-in mode (`-i`) — extract, **without** `-d` first, to see the failure:

   ```console
   $ mkdir -p /tmp/cpio-nod && cd /tmp/cpio-nod
   $ cpio -i < "$LAB/project.cpio"
   cpio: project/src/main.c: Cannot open: No such file or directory
   cpio: project/src/parser.c: Cannot open: No such file or directory
   ...
   4063 blocks
   ```

4. Extract correctly:

   ```console
   $ mkdir -p /tmp/cpio-x && cd /tmp/cpio-x
   $ cpio -idmv < "$LAB/project.cpio" 2>&1 | tail -3
   project/logs
   project
   4063 blocks
   $ find . -type f | wc -l
   ```

5. Extract selectively, with a pattern:

   ```console
   $ mkdir -p /tmp/cpio-sel && cd /tmp/cpio-sel
   $ cpio -idmv 'project/src/*' < "$LAB/project.cpio"
   project/src/main.c
   project/src/parser.c
   project/src/util.c
   project/src/main.c.hard
   4063 blocks
   ```

6. Overwrite behaviour — `cpio -i` refuses to replace a **newer** file unless told to:

   ```console
   $ cd /tmp/cpio-x
   $ touch project/src/util.c
   $ cpio -idm < "$LAB/project.cpio" 2>&1 | grep util
   cpio: project/src/util.c not created: newer or same age version exists
   $ cpio -idmu < "$LAB/project.cpio" >/dev/null 2>&1
   $ stat -c %y project/src/util.c
   ```

7. Pass-through mode (`-p`) — copy a tree without ever creating an archive:

   ```console
   $ cd "$LAB"
   $ mkdir -p /tmp/passthru
   $ find project -depth -print0 | cpio --null -pdmv /tmp/passthru 2>&1 | tail -2
   /tmp/passthru/project
   4063 blocks
   $ diff -r project /tmp/passthru/project && echo IDENTICAL
   IDENTICAL
   ```

8. Formats — `newc` is the one that matters in modern Linux:

   ```bash
   find project -depth -print | cpio -o -H crc  > project-crc.cpio
   find project -depth -print | cpio -o -H odc  > project-odc.cpio
   file project-crc.cpio project-odc.cpio
   ```

9. Real-world context — an `initramfs` **is** a compressed `newc` cpio archive:

   ```console
   $ mkdir -p /tmp/initrd-x && cd /tmp/initrd-x
   $ ls -l /boot/initramfs-$(uname -r).img
   $ file /boot/initramfs-$(uname -r).img
   /boot/initramfs-6.15.4-200.fc44.x86_64.img: ASCII cpio archive (SVR4 with no CRC)
   ```

   The leading segment is an uncompressed early-cpio (CPU microcode); the compressed root image follows it. On Fedora/RHEL, `lsinitrd` reads both for you:

   ```bash
   lsinitrd /boot/initramfs-$(uname -r).img | head -20
   ```

10. Cleanup:

    ```bash
    cd "$LAB"; rm -rf /tmp/cpio-nod /tmp/cpio-x /tmp/cpio-sel /tmp/passthru /tmp/initrd-x
    ```

### Questions — block 7

- **Q7.1** Name the three operating modes of `cpio` and the flag that selects each. Which two involve an archive stream, and which does not?
- **Q7.2** Step 3 failed with "Cannot open: No such file or directory" for *regular files*. What was actually missing, and which flag fixes it?
- **Q7.3** Why does the `find` in step 1 use `-depth`? What breaks on restore if you omit it?
- **Q7.4** `cpio` printed `4063 blocks`. What is the block size, on which stream was that message written, and why does that matter for `cpio -o > archive`?
- **Q7.5** In step 6, `cpio` silently skipped a file. Compare this default with `tar`'s extraction default, and name the `cpio` flag that restores tar-like behaviour.
- **Q7.6** Write the `tar` equivalent of `find project -depth -print0 | cpio --null -pdmv /tmp/passthru`, using a `tar | tar` pipeline.
- **Q7.7** Why is `--no-absolute-filenames` important when extracting a cpio archive you did not create?
- **Q7.8** Give one concrete reason `cpio` is still used on Linux in 2026 despite `tar` being more ergonomic.

---

## Exercise 8 — `dd`: block-level copying

> **Danger.** `dd` has no confirmation and no undo. Every `of=` in this exercise is a regular file under your lab directory. Never type a device node here.

### Steps

1. Create an 8 MiB image of zeros:

   ```console
   $ cd "$LAB"
   $ dd if=/dev/zero of=disk.img bs=1M count=8 status=progress
   8+0 records in
   8+0 records out
   8388608 bytes (8.4 MB, 8.0 MiB) copied, 0.00612 s, 1.4 GB/s
   ```

2. Read the "records" line carefully, then create a **sparse** file and compare apparent vs allocated size:

   ```console
   $ dd if=/dev/zero of=sparse.img bs=1 count=0 seek=100M
   0+0 records in
   0+0 records out
   0 bytes copied, 0.000108 s, 0.0 kB/s

   $ ls -l sparse.img
   -rw-r--r--. 1 user user 104857600 Aug 26 11:40 sparse.img
   $ du -h sparse.img
   0	sparse.img
   $ du -h --apparent-size sparse.img
   100M	sparse.img
   ```

3. Patch bytes **in place** — `seek` + `conv=notrunc`:

   ```console
   $ printf 'LPIC' | dd of=disk.img bs=1 seek=512 conv=notrunc
   4+0 records in
   4+0 records out
   4 bytes copied, 8.4e-05 s, 47.6 kB/s

   $ ls -l disk.img
   -rw-r--r--. 1 user user 8388608 Aug 26 11:42 disk.img
   ```

4. Now repeat **without** `conv=notrunc` on a copy, and watch the file get destroyed:

   ```console
   $ cp disk.img disk2.img
   $ printf 'LPIC' | dd of=disk2.img bs=1 seek=512
   4+0 records in
   4+0 records out
   4 bytes copied, 9.1e-05 s, 44.0 kB/s
   $ ls -l disk2.img
   -rw-r--r--. 1 user user 516 Aug 26 11:43 disk2.img
   ```

5. Read the patched region back — `skip` is the *input* counterpart of `seek`:

   ```console
   $ dd if=disk.img bs=1 skip=512 count=4 status=none
   LPIC
   $ xxd -s 512 -l 16 disk.img
   00000200: 4c50 4943 0000 0000 0000 0000 0000 0000  LPIC............
   ```

6. Take a 512-byte "boot sector" style backup and restore it:

   ```bash
   dd if=disk.img of=sector0.bin bs=512 count=1
   ls -l sector0.bin
   dd if=sector0.bin of=disk.img bs=512 count=1 conv=notrunc
   ```

7. `count` counts **read() calls**, not bytes — the pipe trap:

   ```console
   $ head -c 10000 /dev/urandom | dd of=part.bin bs=4096 count=2
   0+2 records in
   0+2 records out
   10000 bytes (10 kB, 9.8 KiB) copied, 0.00021 s, 47.6 MB/s
   ```

   Your exact `records in` line will vary run to run. Now the deterministic form:

   ```console
   $ head -c 10000 /dev/urandom | dd of=part.bin bs=4096 count=2 iflag=fullblock
   2+0 records in
   2+0 records out
   8192 bytes (8.2 kB, 8.0 KiB) copied, 0.00019 s, 43.1 MB/s
   ```

8. Error tolerance for failing media (simulated here — just read the semantics):

   ```bash
   # On a dying disk: keep going past read errors, and pad each failed
   # block with NULs so every subsequent byte keeps its correct offset.
   # dd if=/dev/sdX of=rescue.img bs=4096 conv=noerror,sync status=progress
   ```

9. Wipe and verify (on the lab image only):

   ```console
   $ dd if=/dev/zero of=disk.img bs=1M count=8 conv=notrunc status=none
   $ sha256sum disk.img
   0dea6e9dc6bbfa7d... disk.img
   $ dd if=/dev/zero bs=1M count=8 status=none | sha256sum
   0dea6e9dc6bbfa7d... -
   ```

10. Throughput comparison — `bs` is the single biggest performance lever:

    ```console
    $ dd if=/dev/zero of=perf.img bs=512  count=20000 status=none; sync
    $ dd if=/dev/zero of=perf.img bs=1M   count=10    status=none; sync
    ```

    Re-run each with `status=progress` (drop `status=none`) and compare the reported rates.

11. Cleanup:

    ```bash
    rm -f disk.img disk2.img sparse.img part.bin sector0.bin perf.img
    ```

### Questions — block 8

- **Q8.1** Decode `8+0 records in`. What would `0+2` mean, and what would `12+1` mean?
- **Q8.2** In step 4, an 8 MiB file became 516 bytes. Explain exactly what `dd` did and why `conv=notrunc` prevents it.
- **Q8.3** Distinguish `skip=` from `seek=`. Which side does each apply to, and in what unit are they counted?
- **Q8.4** `ls -l` said 100 MB and `du` said 0 for `sparse.img`. What is stored on disk, and what happens if you `tar -cf` that file and extract it elsewhere?
- **Q8.5** Why is `conv=sync` paired with `conv=noerror` when rescuing a failing disk? What would happen to a filesystem image if you used `noerror` alone?
- **Q8.6** Why did `bs=4096 count=2` copy 10000 bytes from a pipe? Give the flag that makes it deterministic and explain the mechanism.
- **Q8.7** Write the command to back up the first sector of `/dev/sda` to `~/mbr.bin`, and state precisely which structures live in those 512 bytes on an MBR-partitioned disk.
- **Q8.8** `dd if=/dev/zero of=/dev/sda bs=1M count=1` and `dd if=/dev/zero of=/dev/sda1 bs=1M count=1` — describe the different damage each causes.

---

## Exercise 9 — Compression tools and file identification

### Steps

1. Make a compressible file (repetitive text, unlike `/dev/urandom`):

   ```bash
   cd "$LAB"
   for i in $(seq 1 20000); do
     echo "2026-08-26 10:00:00 INFO  request id=$i status=200 path=/api/v1/health"
   done > access.log
   ls -l access.log
   ```

2. `gzip` replaces the original by default — `-k` keeps it:

   ```console
   $ cp access.log t.log && gzip t.log && ls t.log*
   t.log.gz
   $ gzip -k access.log && ls -l access.log access.log.gz
   -rw-r--r--. 1 user user 1477790 Aug 26 12:01 access.log
   -rw-r--r--. 1 user user   85403 Aug 26 12:02 access.log.gz
   ```

3. Compare the three compressors at default and maximum levels:

   ```bash
   for tool in gzip bzip2 xz; do
     cp access.log "c-$tool"
     /usr/bin/time -f "$tool  %e s" $tool -9 "c-$tool"
   done
   ls -l c-*
   ```

   ```console
   -rw-r--r--. 1 user user  70841 Aug 26 12:05 c-bzip2.bz2
   -rw-r--r--. 1 user user  84925 Aug 26 12:05 c-gzip.gz
   -rw-r--r--. 1 user user  13996 Aug 26 12:05 c-xz.xz
   ```

4. Inspect a gzip member without decompressing it:

   ```console
   $ gzip -l access.log.gz
            compressed        uncompressed  ratio uncompressed_name
                 85403             1477790  94.2% access.log
   ```

5. Read compressed content in place:

   ```bash
   zcat  access.log.gz | head -2
   zgrep 'id=17777' access.log.gz
   xzcat c-xz.xz | wc -l
   bzcat c-bzip2.bz2 | tail -1
   zless access.log.gz     # q to quit
   ```

6. Decompress, three equivalent spellings each:

   ```bash
   gunzip  -k access.log.gz   ;  gzip  -dk access.log.gz
   bunzip2 -k c-bzip2.bz2     ;  bzip2 -dk c-bzip2.bz2
   unxz    -k c-xz.xz         ;  xz    -dk c-xz.xz
   ```

7. Identify files by **content**, not by name — this is what `file` is for:

   ```console
   $ file access.log access.log.gz c-bzip2.bz2 c-xz.xz project.tar project.tar.gz project.cpio project/src
   access.log:      ASCII text
   access.log.gz:   gzip compressed data, was "access.log", last modified: ..., from Unix, original size modulo 2^32 1477790
   c-bzip2.bz2:     bzip2 compressed data, block size = 900k
   c-xz.xz:         XZ compressed data, checksum CRC64
   project.tar:     POSIX tar archive (GNU)
   project.tar.gz:  gzip compressed data, from Unix, original size modulo 2^32 2078720
   project.cpio:    ASCII cpio archive (SVR4 with no CRC)
   project/src:     directory
   ```

8. Prove that the extension is irrelevant:

   ```console
   $ cp access.log.gz misleading.txt
   $ file misleading.txt
   misleading.txt: gzip compressed data, was "access.log", ...
   $ file -b --mime-type misleading.txt
   application/gzip
   ```

9. `file` and symlinks:

   ```console
   $ file project/doc/main.c.sym
   project/doc/main.c.sym: symbolic link to ../src/main.c
   $ file -L project/doc/main.c.sym
   project/doc/main.c.sym: empty
   $ file project/doc/dangling.sym
   project/doc/dangling.sym: broken symbolic link to /nonexistent/path
   ```

10. Integrity, which is the point of all of this:

    ```console
    $ sha256sum access.log project.tar.gz > SHA256SUMS
    $ sha256sum -c SHA256SUMS
    access.log: OK
    project.tar.gz: OK
    $ printf '\0' >> project.tar.gz
    $ sha256sum -c SHA256SUMS
    access.log: OK
    project.tar.gz: FAILED
    sha256sum: WARNING: 1 computed checksum did NOT match
    $ echo $?
    1
    ```

### Questions — block 9

- **Q9.1** Why does `gzip access.log` leave no `access.log` behind, while `gzip -c access.log > access.log.gz` does? Which is safer in a script and why?
- **Q9.2** `gzip`, `bzip2` and `xz` all compress a *single stream*. What does that imply about `.tar.gz` versus a `.zip` file, in terms of extracting one member?
- **Q9.3** Rank gzip/bzip2/xz on compression ratio, compression CPU cost and decompression CPU cost, and state the operational rule that follows (which one for a nightly log rotation, which for a distributed release tarball).
- **Q9.4** `gzip -l` reported "uncompressed 1477790". What is the documented limitation of that number for very large files, and what does the `file` output hint about it?
- **Q9.5** Name the `zcat` equivalents for bzip2 and xz, and explain why `zgrep` exists rather than just using `gunzip -c | grep`.
- **Q9.6** In step 9, `file` said `symbolic link to ...` and `file -L` said `empty`. Explain both answers.
- **Q9.7** `file` correctly identified a gzip stream named `misleading.txt`. What mechanism does it use, and where does its database live?
- **Q9.8** After appending a single NUL byte, `sha256sum -c` failed but `tar -tzf project.tar.gz` may still list the members. Explain, and say which check you would put in a backup verification script.

---

## Exercise 10 — Capstone: a failed nightly backup

A cron job produced a nightly archive. Restore, verify, and clean up — using only the tools of this objective.

### Steps

1. Build the scenario:

   ```bash
   cd "$LAB"
   mkdir -p nightly && cd nightly
   mkdir -p app/{bin,conf,data,cache,logs}
   printf '#!/bin/sh\necho running\n' > app/bin/run.sh && chmod 750 app/bin/run.sh
   printf 'listen=0.0.0.0:8080\nworkers=4\n' > app/conf/app.conf && chmod 640 app/conf/app.conf
   head -c 300000 /dev/urandom > app/data/store.db
   head -c 900000 /dev/urandom > app/cache/blob1.cache
   head -c 900000 /dev/urandom > app/cache/blob2.cache
   for i in 1 2 3 4 5; do echo "line $i" > "app/logs/app-$i.log"; done
   touch -d '40 days ago' app/logs/app-1.log app/logs/app-2.log
   ln -s ../conf/app.conf app/bin/app.conf
   cd "$LAB/nightly"
   ```

2. **Task A** — produce `backup.tar.gz` of `app/` that excludes the `cache/` directory and every `*.cache` file, preserves the symlink as a symlink, and contains no leading `/`. Then prove the exclusions worked.

   ```bash
   tar -czf backup.tar.gz --exclude='cache' --exclude='*.cache' app
   tar -tvf backup.tar.gz
   tar -tf backup.tar.gz | grep -c cache        # expect 0
   ```

3. **Task B** — record a checksum manifest of the archive and of every file it should contain:

   ```bash
   sha256sum backup.tar.gz > backup.sha256
   find app -type f ! -path '*/cache/*' ! -name '*.cache' -print0 \
     | sort -z | xargs -0 sha256sum > files.sha256
   wc -l files.sha256
   ```

4. **Task C** — restore into a clean location and diff against the original:

   ```bash
   mkdir -p /tmp/verify
   sha256sum -c backup.sha256
   tar -xpzf backup.tar.gz -C /tmp/verify
   diff -r --no-dereference app /tmp/verify/app
   ```

   The `diff` will report the `cache` directory as present only on the left. That is expected — everything else must be identical.

5. **Task D** — verify that modes survived the round trip:

   ```console
   $ stat -c '%a %n' app/bin/run.sh app/conf/app.conf
   750 app/bin/run.sh
   640 app/conf/app.conf
   $ stat -c '%a %n' /tmp/verify/app/bin/run.sh /tmp/verify/app/conf/app.conf
   750 /tmp/verify/app/bin/run.sh
   640 /tmp/verify/app/conf/app.conf
   ```

6. **Task E** — rotate: compress every log older than 30 days, delete the cache, and leave the rest untouched. One pass each, NUL-safe:

   ```bash
   find app/logs -type f -name '*.log' -mtime +30 -print0 | xargs -0 -r gzip -v
   find app -type f -name '*.cache' -delete
   find app -type d -empty -print
   ls -l app/logs
   ```

7. **Task F** — the archive is corrupted in transit. Detect it before wasting time on extraction:

   ```console
   $ cp backup.tar.gz shipped.tar.gz
   $ dd if=/dev/urandom of=shipped.tar.gz bs=1 seek=500 count=32 conv=notrunc status=none
   $ gzip -t shipped.tar.gz
   gzip: shipped.tar.gz: invalid compressed data--crc error
   $ echo $?
   1
   $ sha256sum -c backup.sha256 2>/dev/null; echo "manifest exit=$?"
   ```

8. Cleanup the whole lab:

   ```bash
   cd ~
   rm -rf "$LAB" /tmp/verify /tmp/restore1 /tmp/restore2 /tmp/dest \
          /tmp/project-a /tmp/project-L /tmp/src-copy /tmp/project \
          /tmp/README.md* /tmp/plain.c /tmp/preserved.c /tmp/target.md* \
          /tmp/host.tar /tmp/mod*.o
   ```

### Questions — block 10

- **Q10.1** In Task A, why are **both** `--exclude='cache'` and `--exclude='*.cache'` given? Would either alone have been enough here?
- **Q10.2** Task C used `diff -r --no-dereference`. What would plain `diff -r` have done with `app/bin/app.conf`, and why would that hide a real regression?
- **Q10.3** Task E's first command uses `xargs -0 -r`. Explain what `-r` prevents on a night when no log is older than 30 days.
- **Q10.4** `gzip -t` detected the corruption in Task F. What exactly is it checking, and why is a `sha256sum` manifest still worth keeping alongside it?
- **Q10.5** The rotation in Task E ran `gzip` on `app-1.log`, producing `app-1.log.gz`. If the same cron job runs again the next night, what happens, and how do you make the rotation idempotent?
- **Q10.6** Rewrite Task A using `cpio` instead of `tar`, keeping the same exclusions. Which of the two is easier to express, and why?

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 1 — metadata, links, timestamps

**A1.1** `main.c.hard` shares the inode. `ls -li` prints the inode number in the first column: `main.c` and `main.c.hard` both show `1179651`, while `main.c.sym` has its own inode. The third column of `ls -l` is the **link count** (`st_nlink`) — the number of directory entries pointing at that inode. It reads `2` for both hard-linked names. A hard link is not a copy and not a pointer: both names are equal, first-class references to one inode, and the data is freed only when the link count reaches 0 *and* no process holds the file open. Symlinks do not increment the target's link count, which is why deleting `main.c` would leave `main.c.sym` dangling but `main.c.hard` perfectly intact. (Directories always show at least 2: their own name plus their `.` entry, plus one per subdirectory's `..`.)

**A1.2** A symbolic link's "size" is the byte length of the **target path string** it stores. `../src/main.c` is 13 characters, so the size is 13. It says nothing about the target file. On most Linux filesystems, targets short enough are stored inline in the inode itself ("fast symlinks"), which is why `stat` often reports `Blocks: 0` for them too.

**A1.3**
- `Size: 0` — the logical file length in bytes (`st_size`). `touch` creates a file with no content.
- `Blocks: 0` — the number of **512-byte** units actually allocated (`st_blocks`). An empty file needs an inode but no data blocks, so zero. This field is what `du` reports, and it is why `du` and `ls -l` disagree on sparse files and on files with tail-packing or compression.
- `IO Block: 4096` — the filesystem's preferred I/O transfer size (`st_blksize`), a hint for applications choosing a buffer size. It is not the allocation unit and not a property of this file.

**A1.4** ctime is the **inode change time**, and it is maintained by the kernel, not by userspace. Any modification to inode metadata — mode, owner, link count, and *including the act of setting atime/mtime itself* — updates ctime to the current time. There is deliberately no API to backdate it, precisely so it can serve as tamper evidence: an intruder can forge mtime with `touch -d`, but not ctime. (The only way to alter it is to change the system clock or write to the raw device.) Note `Birth:` (creation time, `statx`) is a fourth timestamp, available on ext4/XFS/Btrfs and also not settable.

**A1.5** No — it is **brace expansion**, which is a distinct and earlier shell mechanism. Brace expansion is purely textual: it does not look at the filesystem and does not require the names to exist, which is exactly why it works for `mkdir`. Globbing (`*`, `?`, `[...]`) matches *existing* names. Running the same `mkdir -p` again is a no-op success: `-p` suppresses the "File exists" error for existing components and creates only what is missing, plus it creates intermediate parents. That combination is what makes `mkdir -p` the idempotent form used in scripts.

**A1.6** `ls project` lists the *contents* of `project`. `ls -d project/*/` lists the **directory entries themselves** without descending into them; `-d` is what stops `ls` from expanding a directory argument into its contents. The trailing `/` in the glob restricts the match to directories (and to symlinks that resolve to directories), because a pattern ending in `/` only matches names that can be followed by a slash.

---

### Block 2 — `cp`

**A2.1** The rule: **if the final argument is an existing directory, `cp` copies the sources *into* it, keeping their basenames. Otherwise the final argument is the new name of the copy.** In step 3 `/tmp/src-copy` did not exist, so it became a copy of `src`. In step 4 it existed, so `src` was copied *inside* it as `/tmp/src-copy/src`. This is the single most common `cp -r` mistake, and it also explains why `cp file1 file2 file3 dest` requires `dest` to be a directory.

**A2.2** No, step 4 was not idempotent — the second run changed the result. Two idempotent formulations:
- `cp -aT project/src /tmp/src-copy` — `-T`/`--no-target-directory` forces the target to be treated as a name, never as a container, so the command means the same thing whether or not the target exists.
- `mkdir -p /tmp/src-copy && cp -a project/src/. /tmp/src-copy/` — copy the *contents*.

`rsync -a project/src/ /tmp/src-copy/` is the production answer for the same reason (note that for `rsync`, unlike `cp`, the trailing slash on the *source* is what selects contents-only).

**A2.3** `cp -a` is exactly `cp -dR --preserve=all`, where `-d` is itself `--no-dereference --preserve=links`. Breaking it down:
- `-R` — recurse into directories.
- `--no-dereference` — copy a symlink **as a symlink** instead of copying what it points to. This is what preserved `main.c.sym`.
- `--preserve=links` — reproduce hard links between copied files as hard links.
- `--preserve=all` — mode, ownership, timestamps, plus context, links and xattrs where supported.

**A2.4** `-L` (`--dereference`) caused it: it follows every symlink and copies the *target's content* to the link's name, and it also implies that hard-linked names are copied independently rather than re-linked. For a large tree the space cost is real — a source tree with a 2 GB file hard-linked under four names occupies 2 GB at the source and 8 GB after `cp -rL`, and every symlink into a big directory is materialised as a full copy. Use `-a` for backups and `-L` only when you deliberately want a self-contained, link-free snapshot.

**A2.5** `--preserve=ownership` fails: only a process with `CAP_CHOWN` (in practice, root) may give a file away to another user. `cp -p` prints a diagnostic such as `cp: failed to preserve ownership for '/tmp/x': Operation not permitted` and exits non-zero, **but it does not delete the copy** — the data and, where permitted, the mode and timestamps are still there. This is why restoring a root-owned `/etc` tree as an unprivileged user produces a tree that is complete but wrongly owned, and why `tar` extraction as non-root defaults to `--no-same-owner`.

**A2.6**
- `cp -i` — **interactive**: prompts before each overwrite. Existence-based, requires a human.
- `cp -n` — **no-clobber**: silently skips if the destination exists. Existence-based, scriptable. (Note that `-n` and `-i` are mutually exclusive; the last one on the command line wins.)
- `cp -u` — **update**: copies only if the source is newer than the destination, or the destination is missing. **Timestamp**-based.

None of the three is content-aware: `cp -u` will skip a file whose content differs but whose mtime is older or equal, and will copy a byte-identical file whose mtime is merely newer. Content-aware copying is `rsync -c` (checksum) or a `sha256sum`-driven pipeline. Modern coreutils also offer `cp --update=<policy>` for finer control.

---

### Block 3 — `mv`, `rm`, hostile filenames

**A3.1** Step 1 used `rename(2)`: a single metadata operation inside one filesystem that just rewrites directory entries. The inode is untouched, so it is **instantaneous regardless of file size and atomic** — at no instant does a concurrent observer see the file missing or half-present. Step 2 could not use `rename(2)` (it fails with `EXDEV`, "Invalid cross-device link"), so `mv` fell back to copy-then-unlink: read every byte to a new inode on the target filesystem, then delete the source. That takes time proportional to the size and is **not atomic**.

**A3.2** **ctime** must change — a new inode was created, so its change time is the moment of creation. `mv` deliberately carries over **mtime** (and atime, mode, and ownership when permitted), because the whole intent of `mv` is that the file is "the same file in a new place". This is a genuine difference from `cp` without `-p`. It is also why an intact mtime after a cross-filesystem move is not evidence that no copy occurred; only the inode number and ctime tell you that.

**A3.3** The source `/home` file is still fully present and intact — `mv` unlinks the source only after the copy completes successfully. The destination in `/var` is a **partial, truncated file** of whatever was written before the kill. Nothing was lost, but the destination is silently corrupt and the same size check that a naive script does (`test -f`) will pass. The safe pattern for large cross-filesystem moves is copy → verify (checksum or `cmp`) → delete source, or `rsync --remove-source-files` which does exactly that.

**A3.4** The chain: the shell expanded `*`, the expansion is sorted, and in the C/POSIX-ish collation a leading `-` sorts before letters, so the file named `-i` was placed **first** in `rm`'s argument list. `rm` parses leading-dash arguments as options, so it saw `-i` as the interactive flag rather than as a filename. The two independent fixes:
- **`--`** — the POSIX end-of-options marker: `rm -- *`. Everything after `--` is a filename, even if it starts with a dash.
- **A path prefix** — `rm ./*` or `rm ./-i`. `./-i` no longer begins with `-`, so option parsing never triggers.

Both are worth having as reflexes; `--` is the one that also protects against a file named `--help` or `-rf`.

**A3.5** `rmdir` fails loudly (`Directory not empty`) instead of destroying data, so it encodes the *assertion* "this directory should be empty by now". That makes it the safer tool whenever emptiness is part of the contract — e.g. a cleanup script that removes a spool directory only after confirming every job was drained, or removing a mountpoint you believe is unmounted. `rm -rf mountpoint` on a directory you *thought* was unmounted deletes the mounted filesystem's contents; `rmdir mountpoint` cannot. It also uses the dedicated `rmdir(2)` syscall rather than a recursive walk.

**A3.6** Because the default `find`/`xargs` interface is delimited by whitespace and newlines, which are legal characters in filenames. `find . -type f | xargs rm` would turn `two words` into two arguments (`two` and `words`) and split `line\nbreak` across two lines, deleting or failing on the wrong names — and a filename containing a quote character can make `xargs` mangle things further. `-print0` emits NUL-terminated records and `xargs -0` reads them; NUL (`\0`) and `/` are the only two bytes that cannot appear in a filename, so NUL is the only unambiguous delimiter. The equivalent single-tool form is `find . -type f -delete` or `find . -type f -exec rm {} +`, which never serialise the names at all.

**A3.7**
- `set -u` makes the shell abort with an error when an **unset** variable is referenced, so `rm -rf $DIR/` becomes a fatal error rather than `rm -rf /`.
- `${DIR:?DIR must be set}` additionally catches the case `set -u` misses: a variable that is set but **empty** (`DIR=""`). The `:?` form errors on unset *or* null, and lets you supply the message.
- `--` is still needed because `$DIR` could legitimately expand to a value beginning with `-` (a directory literally named `-tmp`, or a value injected from an argument), which `rm` would parse as options.

The quoting `"${DIR:?...}"` is the fourth guard: unquoted, a value with spaces becomes multiple paths.

---

### Block 4 — globbing

**A4.1** The **shell** expands it, before `ls` is executed. `ls` receives an already-expanded argument vector: `argv = ["ls", "data.csv", "file1.txt", ...]`. `ls` never sees the character `*`. This is the single most important fact about globbing on Unix, and it explains three things at once: why globbing works identically for every command, why `find . -name *.txt` breaks, and why a command that needs to do its *own* pattern matching (`find`, `tar`, `grep`) requires you to quote the pattern so the shell hands the literal characters through.

**A4.2** `?` matches **exactly one** character, so `file?.txt` matches `file1.txt` … `file9.txt` — nine names. `file10.txt` has two characters between `file` and `.txt`, so it needs `file??.txt`. `*` matches a string of **zero or more** characters, so `file*.txt` matches all twelve (and would also match a hypothetical `file.txt`).

**A4.3** `*[!3][0-9][0-9][0-9].log` is wrong on positions; counting from the end, `.log` is 4 characters, so "fourth-from-last" means the last character before `.log`. The pattern is:

```
*[!3].log
```

For the exercise's `report-YYYY.log` set that yields `report-2024.log` and `report-2025.log`. The general point: `[!...]` (POSIX; bash also accepts `[^...]`) negates the set, and it still matches **exactly one** character — a negated bracket is not a "not this string" operator.

**A4.4** Bracket **ranges** are interpreted using the collation order of the current locale (`LC_COLLATE`), not ASCII. In many locales the collation interleaves cases, so `[a-z]` can match `B` through `Z` as well, and `[A-Z]` can match lowercase letters. A script that filters filenames with `[a-z]` therefore behaves differently on a `en_US.UTF-8` desktop and a `LANG=C` cron environment. The portable replacement is the POSIX character class, which is locale-*aware* in the correct sense: `[[:lower:]]`, `[[:upper:]]`, `[[:digit:]]`, `[[:alpha:]]`, `[[:alnum:]]`, `[[:space:]]`, `[[:punct:]]`. The other fix is to pin `LC_ALL=C` for the script.

**A4.5** `.*` matches `.` (the current directory) and `..` (**the parent**). `rm -rf .*` therefore attempts to recurse into `..` and delete the *entire parent directory tree* — a classic way to lose a home directory while "cleaning dotfiles". (GNU `rm` special-cases the literal arguments `.` and `..` and refuses them, but this is not portable and does not save you in every construction.) The safe idiom for "hidden entries except `.` and `..`" is:

```bash
rm -rf .[!.]* ..?*
```
or, better, `shopt -s dotglob` plus a plain `*`, or `find . -maxdepth 1 -name '.*' ! -name '.' ! -name '..' -exec rm -rf {} +`.

**A4.6** Because bash's default is to leave a pattern that matches nothing **unexpanded**, passing the literal characters to the command. That is why `ls *.nomatch` reports `cannot access '*.nomatch'` — `ls` really did receive that string. The two options:
- `shopt -s nullglob` — an unmatched pattern expands to **nothing** (zero words). Convenient for `for f in *.log`, dangerous for commands that change meaning with fewer arguments (`cp *.bak dest/` becomes `cp dest/`).
- `shopt -s failglob` — an unmatched pattern is an **error**: the command does not run at all. This is the strictest and usually the best choice for interactive safety.

**A4.7** Order of expansion. Bash performs **brace expansion first**, purely textually and without consulting the filesystem, so `file{1..12}.txt` becomes twelve words regardless of what exists — which is exactly what `touch` needs. **Pathname expansion (globbing) happens much later** and only matches existing names; in an empty directory `file*.txt` matches nothing, and under the default (`nullglob` off) it is passed through literally, so `touch` dutifully creates a file whose name contains an asterisk. Full order: brace → tilde → parameter/variable → command substitution → arithmetic → word splitting → **pathname expansion** → quote removal.

**A4.8** Unquoted, the shell expanded `*.txt` **before** `find` ran, so `find` received `find . -name file1.txt file10.txt file11.txt ... file9.txt`. `find`'s grammar is `find [paths...] [expression]`; after the `-name file1.txt` test it hit another bare word, `file10.txt`, in expression position and rejected it — hence `paths must precede expression`. Had exactly one `.txt` file existed, the expansion would have produced a single, syntactically valid command: `find . -name file1.txt`, which runs happily and finds only that one file, in the current directory tree — **the wrong result, with exit status 0 and no warning**. The failure mode is worse than the error: it is silent, and it depends on the state of the directory you happen to be standing in. Always quote patterns intended for the *program*: `find . -name '*.txt'`.

---

### Block 5 — `find`

**A5.1** With a unit suffix, GNU `find` divides the file size by the unit and **rounds up** to the next whole unit. A 500-byte file is `ceil(500 / 1048576) = 1` in units of `M`. `-size -1M` means "strictly fewer than 1 unit", i.e. 0 units, which only empty (0-byte) files satisfy. Hence only the empty `.log` files matched. `-size -1000000c` counts in raw bytes (`c`), where no rounding occurs, so the 500- and 5000-byte files match. The rules to memorise:
- suffixes: `c` = bytes, `w` = 2 bytes, `b` = **512-byte blocks (the default when no suffix is given)**, `k` = KiB, `M` = MiB, `G` = GiB;
- `+n` = more than n units, `-n` = fewer than n units, `n` = exactly n units — all *after* rounding up;
- if you care about exact byte thresholds, always use `c`.

**A5.2** `find` computes the file's age in whole 24-hour periods and **truncates** the fractional part.
- `-mtime +7` → `age_in_days > 7` after truncation, so the file was modified **at least 8×24 h ago**. A file modified 7 days and 20 hours ago has truncated age 7 and does **not** match — this is why "delete backups older than a week" written as `-mtime +7` actually keeps them for eight days.
- `-mtime -3` → truncated age `< 3`, i.e. modified within the last **3×24 h**.
- `-mtime 0` → truncated age exactly 0, i.e. within the last 24 hours.

The fractional part is discarded, which biases `+n` toward keeping files and `-n` toward selecting them. Use `-mmin` for minute granularity, or `-newermt '7 days ago'` for an exact timestamp comparison with no truncation at all.

**A5.3** All three take the same mode argument but combine it differently:
- **`-perm 600`** — *exact* match. Only `rw-------`. A file with mode 644 or 601 does not match.
- **`-perm -600`** — *all of these bits are set*, others irrelevant. Matches 600, 640, 644, 660, 777 — anything with owner read **and** owner write. This is the form for "is it writable by its owner".
- **`-perm /600`** — *any of these bits is set*. Matches 400, 200, 644, 040? (no — 040 has neither owner-read nor owner-write, so it does not match), i.e. anything with owner-read **or** owner-write. This is the form for the classic security sweep `find / -type f -perm /o+w`, "world-writable in any way".

(`-perm +600` was the old GNU spelling of `/`; it was removed in findutils 4.5.12 and errors out today.) Symbolic forms work everywhere a numeric one does: `-perm -u+x`, `-perm /o+w`.

**A5.4** `\;` terminates the command after **one** filename, so `find` forks and execs the command once per match. `+` batches as many filenames as fit within `ARG_MAX` into a single invocation, exactly like `xargs`. `+` is dramatically faster on large trees (one `exec` instead of 100 000).

`\;` is **required** when:
- the command takes exactly one file argument, or the `{}` is not the last argument — e.g. `-exec mv {} /backup/ \;` (with `+`, `{}` must be the final argument, so this form is invalid; use `-exec mv -t /backup/ {} +` instead);
- `{}` must appear more than once or be embedded in a larger string — `-exec sh -c 'cp "$1" "$1.bak"' _ {} \;`;
- you need per-file exit-status semantics — with `+`, `find`'s exit status reflects the batch, and one failing file is harder to attribute;
- the command is not idempotent over multiple arguments, e.g. `diff {} ref \;`.

**A5.5** Both are shell metacharacters that must reach `find` literally. `;` is the shell's **command separator** — unescaped, the shell would terminate the `find` command there and try to run whatever follows as a new command, and `find` would complain `-exec: no terminating ";" or "+"`. `{}` is only special in some contexts (brace expansion needs a comma or `..`, so bare `{}` usually survives), but quoting it as `'{}'` is a harmless habit that is portable across shells that do treat it specially. Acceptable spellings: `\;`, `';'`, `";"`.

**A5.6**
```bash
find project -name '*.o' -print0 | xargs -0 -r rm --
```
- `-print0` / `-0` — NUL delimiters, so spaces, newlines and quotes in names are safe.
- `-r` (`--no-run-if-empty`, a GNU extension) — do not run `rm` at all when the input is empty. Without it, `xargs` runs `rm --` once with no operands; GNU `rm` treats that as an error (`missing operand`), which turns a quiet no-op night into a failing cron job.
- `--` — protects against a matched filename beginning with `-`.

The tool-native equivalents, which avoid the pipe entirely, are `find project -name '*.o' -delete` or `find project -name '*.o' -exec rm -- {} +`.

**A5.7** `find` appends an implicit `-print` **only when the expression contains no action of its own**. `-prune` *is* an action (as are `-print`, `-delete`, `-exec`, `-quit`), so its presence suppresses the implicit `-print` for the whole expression — which is why the naive version printed nothing useful and, worse, printed `project/build` itself: without an explicit `-print` on the right-hand branch, the only output came from `-prune`'s own default behaviour in the expression as evaluated. Writing `-o -type f -print` restores an explicit action on the branch you actually want.

The mechanics of `-prune`: it always returns **true** and tells `find` "do not descend into this directory". The idiom is therefore `find PATH <match-to-skip> -prune -o <real-expression> -print`, read as "either it is the thing to skip (prune it, and short-circuit the `-o`) **or** evaluate the real expression". Note `-prune` has no effect under `-depth` (and therefore none with `-delete`), because `-depth` visits contents before the directory.

**A5.8** `-delete` implies `-depth` because a directory cannot be removed until it is empty: the traversal must visit and delete a directory's **contents first**, then the directory. That is exactly what `-depth` (post-order traversal) provides.

The consequence for `-prune`: `-prune` works by telling the top-down traversal not to descend — but under `-depth` the descent has already happened by the time the directory is evaluated, so `-prune` is silently a no-op. GNU `find` refuses the combination outright (`find: -delete action is incompatible with -prune`) in recent versions; older versions accepted it and **deleted the subtree you meant to protect**. To exclude a subtree from a deleting `find`, use a negative test instead: `find project ! -path 'project/build/*' -name '*.tmp' -delete`.

**A5.9** `-maxdepth`, `-mindepth`, `-depth`, `-follow` and `-xdev` are **global options**: they affect the entire traversal regardless of where they appear, but `find` parses the command line left to right and evaluates *tests* in order. Writing a global option after a test creates a mismatch between how it reads and how it behaves, so GNU `find` emits a warning while still applying it globally.

The risk is that it reads like a conditional and is not. `find . -name '*.log' -maxdepth 1` looks like "of the `.log` files, only those at depth 1", but the traversal was already limited to depth 1 before any test ran — same result here, different result in expressions with `-o` or `-prune`, where a reader will mis-predict the outcome. Worse, the warning is on stderr and disappears in a cron job. Always put global options immediately after the paths: `find . -maxdepth 1 -name '*.log'`.

---

### Block 6 — `tar`

**A6.1** Historical `tar` accepts a **bundled option cluster as its first argument, with or without a leading dash** (`tar czf`, `tar -czf`, `tar -z -c -f`). Within a cluster, order is free — *except* that `-f` consumes the **next argument** as the archive filename. In `-cfz`, the letter after `f` is `z`, so `f` takes `z`… no: `f` takes the next *command-line word*, which is `project.tar.gz` — but the cluster `-cfz` has already consumed `z` as a bundled flag position, so `tar` reads the archive name as the word following the cluster and then mis-assigns the rest. In practice you get `tar: z: Cannot stat: No such file or directory` or an archive named after the wrong operand. The rule: **`-f` must be the last letter of the cluster**, because its argument follows it.

**A6.2** `tar` strips the leading `/` so that an archive is **relocatable**: extracting it writes into the current directory (or `-C` target) rather than clobbering the absolute paths it was created from. The motivating security scenario is an archive containing `/etc/shadow` or `/root/.ssh/authorized_keys`: without stripping, a naive `tar -xf untrusted.tar` run as root would overwrite live system files anywhere on the disk. (The same class of attack uses `../../..` components; modern GNU tar also refuses those by default and warns.)

`-P` / `--absolute-names` disables the stripping. Never use it on an archive you did not create, for exactly the reason above. Use it only when you deliberately need absolute restoration, and even then prefer `tar -xf archive.tar -C /` on a relative archive.

**A6.3** The payload was `/dev/urandom` output — cryptographically random data has maximum entropy and is **incompressible by construction**. No general-purpose compressor can shrink it; all three produced roughly the input size plus container overhead. (If a compressor ever appeared to shrink random data meaningfully, that would indicate the source was not random.)

For a realistic tree of source code, config and logs, the expected behaviour:

| | ratio | compress speed | decompress speed | typical use |
|---|---|---|---|---|
| `gzip` (`-z`, `.gz`) | lowest | fastest | fastest | log rotation, on-the-fly HTTP, anything CPU-bound or streamed |
| `bzip2` (`-j`, `.bz2`) | middle | slow | slow | largely superseded; still seen in older distro archives |
| `xz` (`-J`, `.xz`) | highest | **slowest**, memory-hungry | fast | release tarballs, kernel/distro sources — compress once, download many times |

The operational rule follows from the asymmetry: **compress once / decompress many → xz; compress many / read rarely → gzip.** (`zstd`, `tar --zstd`, now occupies the practical middle: near-gzip speed at near-xz ratios, and is the default in several distributions — not on the LPIC-1 objective, but the right answer in production.)

**A6.4**
```bash
tar -xzf app.tar.gz -C /opt/app --strip-components=1
```
`--strip-components=1` removes the first path element (`app-1.4.2/`) from every member name on extraction, and `-C` sets the working directory before extraction begins. `/opt/app` must already exist. This is the standard incantation for unpacking upstream release tarballs, which almost always wrap their content in a single versioned directory.

**A6.5** `.tar` is a **concatenation of 512-byte-header + data records**, ending in two blocks of NULs. Appending means seeking to the end-of-archive marker and writing new records there — a local, cheap operation. `.tar.gz` is that same tar stream fed through a **single compressed stream**; there is no addressable "end of members" inside it and the compressor's state depends on everything before, so GNU tar cannot append without decompressing and recompressing the whole file. It refuses rather than doing that silently: `tar: Cannot update compressed archives`.

The workaround is explicit: `gunzip project.tar.gz && tar -rf project.tar extra.txt && gzip project.tar`. Formats with a per-member index and central directory — `zip`, `7z`, `dar` — do not have this restriction, which is the practical difference between "archive then compress" (tar) and "compress each member" (zip).

**A6.6** The **umask** applied it. When a non-root user extracts, GNU tar computes the final mode as the archived mode masked by the current umask, so `777 & ~022 = 755`. `-p` / `--preserve-permissions` (a.k.a. `--same-permissions`) tells tar to ignore the umask and set the archived mode exactly.

The defaults are role-dependent:
- **root**: `-p` is the **default** on extraction, as is `--same-owner`. Restoring a system tree as root reproduces modes and ownership exactly, which is what you want for `/etc`.
- **non-root**: umask is applied unless `-p`, and `--no-same-owner` is the default (files become owned by the extracting user), because a normal user cannot `chown` files to anyone else anyway.

For any restore that must be faithful, use `sudo tar -xpf ... --same-owner` and verify with `stat -c '%a %U:%G'`.

**A6.7**
- `--null` tells tar that the `-T -` name list is **NUL-separated**, matching `find -print0`. Without it, tar splits on newlines and mangles any filename containing one — and, unhelpfully, tar's newline-separated `-T` format also treats leading/trailing whitespace and quoting specially, so ordinary spaces can break it too. `--null` additionally disables that quote processing.
- `--no-recursion` is needed because `find` has **already** enumerated every file. Left to itself, tar would take each directory in the list and recurse into it again, re-adding files that `find` deliberately excluded — silently defeating the filter. The pair `--null --no-recursion -T -` is the canonical "let find decide the file set" idiom.

(Order matters slightly: `--no-recursion` is positional in GNU tar and affects names read after it, so keep it before `-T`.)

**A6.8**
```bash
tar -tvzf project.tar.gz | awk '$3 > 1048576 {print $3, $6}'
```
`tar -tv` prints a `ls -l`-style listing in which field 3 is the size in bytes and the last field is the member name (field 6 for the default date format; use `--quoting-style=literal` and check your locale, or safer, `tar --list --verbose --full-time`). The key point for the exam is that **`-t` reads the archive without writing anything to the filesystem** — you can inspect names, sizes, modes, owners and link targets of an untrusted archive before deciding to extract, which is the first thing you should do with any archive from outside.

---

### Block 7 — `cpio`

**A7.1**
- **`-o` / `--create`** — *copy-out*: reads a list of filenames on **stdin**, writes an archive to **stdout**.
- **`-i` / `--extract`** — *copy-in*: reads an archive from **stdin**, extracts (or with `-t`, lists) it.
- **`-p` / `--pass-through`** — *pass-through*: reads a list of filenames on stdin and copies them directly into the destination directory given as the sole argument. **No archive is ever created** — it is `cp -a` driven by `find`, which is precisely why it is useful for tree copies with complex selection criteria.

**A7.2** The **directories** were missing. `cpio -i` by default does not create leading directories; it tries to open `project/src/main.c` for writing, `project/src` does not exist, and `open(2)` returns `ENOENT` — reported as "Cannot open: No such file or directory" against the *file* name, which is why the message is misleading. **`-d` / `--make-directories`** fixes it. The full extraction idiom is `cpio -idmv`: `-i` extract, `-d` make directories, `-m` preserve mtime, `-v` verbose. Memorise it as a unit; it is the answer to almost every cpio extraction question.

**A7.3** `-depth` makes `find` emit each directory **after** its contents (post-order). On restore, cpio then creates the files first and sets the directory's own permissions and timestamps last. Without it, cpio writes a directory with, say, mode `0555` or `0500`, and then cannot create files inside it — and even when it can, writing the files afterwards updates the directory's mtime, so the restored directory timestamps are wrong. With read-only directories in the source tree, omitting `-depth` produces an outright failed restore. Same reasoning applies to `cpio -p`.

**A7.4** The block size is **512 bytes**, and the message is written to **stderr**. That separation is essential: the archive itself goes to **stdout**, so `find ... | cpio -o > project.cpio` puts only archive bytes in the file while the "N blocks" progress line still reaches your terminal. If cpio wrote it to stdout, every archive would be corrupt. The corollary for scripting: `2>/dev/null` silences the counter without touching the archive, and you must never merge stderr into stdout (`2>&1`) in a cpio copy-out pipeline.

**A7.5** `cpio -i` **refuses to overwrite a file that is newer than or the same age as the archived version**, printing `not created: newer or same age version exists`, and it does so **without a non-zero exit for that file** — a silent skip. `tar -x`, by contrast, **overwrites unconditionally** by default (its opt-in equivalents are `--keep-newer-files` and `--keep-old-files`).

`-u` / `--unconditional` restores tar-like behaviour: overwrite regardless of age. The operational lesson is that a cpio-based restore onto a partly-live tree can silently leave newer, wrong files in place — always restore into an empty directory, or pass `-u` deliberately.

**A7.6**
```bash
mkdir -p /tmp/passthru
tar -cf - project | tar -xpf - -C /tmp/passthru
```
The first `tar` writes the archive to stdout (`-f -`), the second reads it from stdin and extracts under `-C`. Add `--numeric-owner` and run as root for a faithful system-tree copy, and `-S` to keep sparse files sparse. This `tar | tar` pipeline is the classic way to copy a tree across a boundary that `cp` handles poorly — including over the network: `tar -cf - dir | ssh host 'tar -xpf - -C /dest'`.

**A7.7** Because in copy-in mode GNU cpio will honour an **absolute member name** in the archive and write to that absolute path, outside your current directory. An archive crafted with members named `/etc/cron.d/backdoor` or `/root/.ssh/authorized_keys`, extracted as root, writes exactly there. `--no-absolute-filenames` forces every member to be created relative to the current directory, which is `tar`'s default behaviour and should be yours. Combine it with `cpio -t` to inspect the member list *before* extracting anything, and prefer extracting into a throwaway directory.

**A7.8** The `initramfs`. The Linux kernel's early userspace image is a **`newc`-format cpio archive** (optionally compressed, and often prefixed by an uncompressed early-cpio segment carrying CPU microcode), because the kernel contains a minimal cpio unpacker in-tree and cpio's format is simple enough to decode with no dependencies. So every Linux system boots through a cpio archive, and anyone debugging a boot failure — a missing storage driver, a broken `dracut` module, a wrong `/etc/crypttab` — unpacks and repacks one. `lsinitrd` (Fedora/RHEL) and `lsinitramfs` (Debian/Ubuntu) are wrappers over exactly this. RPM payloads are also cpio archives.

---

### Block 8 — `dd`

**A8.1** The format is `FULL+PARTIAL records in` / `FULL+PARTIAL records out`, where "record" means one `read()`/`write()` of `bs` bytes.
- `8+0` — eight **complete** blocks, zero partial. Clean.
- `0+2` — zero complete blocks and **two partial** ones: two `read()` calls each returned fewer than `bs` bytes. Normal when reading from a pipe, a tty, or a socket, where a single `read()` is not obliged to fill the buffer.
- `12+1` — twelve full blocks plus a final short one, the usual signature of a file whose size is not a multiple of `bs`.

The `records out` line matters just as much: if `in` and `out` disagree, or if `out` shows partial writes to a device, data has been dropped or short-written.

**A8.2** Without `conv=notrunc`, `dd` opens the output file with `O_TRUNC`, so the file is **truncated to zero length at open time**. Then `seek=512` skips forward 512 bytes — writing into a hole — and writes 4 bytes, leaving a file of exactly 516 bytes whose first 512 bytes are a sparse run of NULs. The original 8 MiB of content is gone.

`conv=notrunc` omits `O_TRUNC`, so the existing file is opened in place and only the 4 bytes at offset 512 are modified; the length stays 8388608. **Any in-place patch of an existing file or image requires `conv=notrunc`.** (Writing to a block device is unaffected — devices cannot be truncated — which is why the flag is easy to forget until it destroys a disk image.)

**A8.3**
- **`skip=N`** applies to the **input** (`if=`): skip N blocks before starting to read.
- **`seek=N`** applies to the **output** (`of=`): skip N blocks before starting to write.

Both are counted in **`bs`-sized blocks**, not bytes — a constant source of off-by-a-factor errors. If `ibs` and `obs` are set separately, `skip` uses `ibs` and `seek` uses `obs`. GNU `dd` also accepts `iseek=`/`oseek=` as clearer aliases, and `skip=512B` (uppercase `B` suffix) to force a byte count regardless of `bs`. Mnemonic: you **seek** to where you will **write**.

**A8.4** Only the **non-zero regions and the file's metadata** are stored; the 100 MB of zeros is a **hole** — a range of the file for which the filesystem has allocated no blocks at all and which reads back as NULs. `ls -l` shows `st_size` (the logical length, 100 MB); `du` shows `st_blocks × 512` (the allocated bytes, 0).

`tar -cf` without `-S` **reads the file normally**, gets 100 MB of NULs, and stores 100 MB of NULs — the archive balloons and the extracted file is fully allocated, no longer sparse. `tar -S` / `--sparse` detects holes and records them, restoring sparseness on extract. The same applies to `cp` (`--sparse=always|auto|never`, `auto` by default, which detects long NUL runs) and to `rsync -S`. This is why naively copying VM disk images and swap-backed files multiplies your storage bill.

**A8.5** They solve two halves of one problem:
- `conv=noerror` — do not abort on a read error; log it and continue to the next block. Without it, `dd` stops dead at the first bad sector and you rescue nothing past it.
- `conv=sync` — **pad every short or failed input block out to `bs` with NULs** before writing.

With `noerror` alone, a failed 4096-byte read contributes **nothing** to the output, so every byte after the bad sector is shifted 4096 bytes earlier than its true offset. For a filesystem image that is catastrophic: superblocks, inode tables and extent pointers all live at fixed offsets, and a single unpadded bad block misaligns the entire remainder, turning a recoverable image with one hole into an unmountable one. `sync` preserves offsets, so you lose only the unreadable sectors — the rest of the filesystem still parses.

In production, `ddrescue` (GNU) is the correct tool: it maps the bad regions, retries them with decreasing block sizes, and keeps a resumable log. `dd conv=noerror,sync` is the answer when `ddrescue` is not installed, and it is the answer on the exam.

**A8.6** `count=2` limits `dd` to **two `read()` calls**, not to two `bs`-sized chunks of data. Reading from a **pipe**, a single `read()` returns whatever is currently in the pipe buffer — often less than 4096 bytes, and the kernel is under no obligation to fill the buffer. Two short reads returned 10000 bytes in total, hence `0+2 records in` and 10000 bytes copied. On a different run the timing differs and so does the byte count.

`iflag=fullblock` makes `dd` keep calling `read()` until the full `bs` bytes are accumulated (or EOF), so `count` once again means "this many complete blocks". **Any `dd` reading from a pipe, socket, tty or `/dev/urandom` with a `count=` that must be exact needs `iflag=fullblock`.** Its absence is the single most common cause of silently truncated `dd` output in scripts.

**A8.7**
```bash
sudo dd if=/dev/sda of=~/mbr.bin bs=512 count=1
```
Those 512 bytes on an MBR-partitioned disk contain, in order:
- bytes **0–445** — the bootstrap code (stage 1 boot loader, e.g. GRUB's `boot.img`);
- bytes **440–443** — the 32-bit disk signature (NT drive serial number), used by some systems to identify the disk;
- bytes **446–509** — the **partition table**: four 16-byte primary partition entries;
- bytes **510–511** — the boot signature `0x55AA`.

Restoring only the partition table without the boot code is `bs=1 skip=446 count=64 seek=446 conv=notrunc`. On a **GPT** disk this sector is instead a *protective MBR*, and the real partition table is the GPT header at LBA 1 plus the entry array at LBA 2–33 (with a backup copy at the end of the disk) — so `bs=512 count=34` is the GPT-equivalent capture, and `sgdisk --backup` is the correct tool.

**A8.8**
- `of=/dev/sda bs=1M count=1` — zeroes the **first megabyte of the whole disk**: the MBR/protective MBR, the partition table, the GPT primary header and entry array, and the start of the first partition. The system loses all knowledge of how the disk is divided; every partition becomes unreachable at once, and the boot loader is gone. Recoverable in principle (GPT keeps a backup at the end of the disk; `testdisk` can rebuild an MBR from filesystem signatures), but the machine will not boot and nothing will mount.
- `of=/dev/sda1 bs=1M count=1` — zeroes the **first megabyte of one partition**: that filesystem's superblock, and for ext4 the primary group descriptors and part of the inode table. The partition table itself is untouched, so the other partitions are fine and the disk still enumerates. `ext4` keeps backup superblocks (`mke2fs -n` lists their offsets; `fsck -b 32768` uses one), so this is often repairable; XFS keeps secondary superblocks too. LUKS is the exception — zeroing a LUKS header without a `luksHeaderBackup` destroys the key slots and the data is cryptographically unrecoverable.

Both are catastrophic. The habit that prevents them: run `lsblk -f` and read the output *out loud* before any `dd of=/dev/...`, and prefer `of=` last on the line so you see it at the moment you commit.

---

### Block 9 — compression and `file`

**A9.1** `gzip FILE` is defined to **replace** its input: it writes `FILE.gz` and unlinks `FILE` on success. `gzip -c` writes to **stdout** and leaves the input alone (as does `gzip -k`, `--keep`).

`-c` (or `-k`) is safer in a script for two reasons. First, if the destination filesystem fills up mid-write, `gzip -c > out.gz` leaves a truncated `out.gz` **and an intact original**, whereas plain `gzip` can leave you with neither a usable archive nor the source under some failure paths. Second, `gzip -c` composes: it can feed a pipe, an `ssh` session or a checksum without touching the disk. The rotation-safe pattern is `gzip -c f > f.gz.tmp && mv f.gz.tmp f.gz && rm f`, which is atomic at the rename.

**A9.2** `gzip`/`bzip2`/`xz` compress **one continuous byte stream** and have no concept of members, names or an index. `.tar.gz` is therefore "solid": to extract one member, the decompressor must inflate the stream from the beginning up to that member's offset. There is no random access, and there is no central directory listing what is inside — `tar -tzf` on a 50 GB archive genuinely reads and decompresses 50 GB.

`.zip` compresses **each member independently** and stores a central directory at the end of the file with per-member offsets, so extracting one file out of 100 000 is O(1) seeks. The trade-off is ratio: solid compression finds redundancy *across* files (a hundred similar `.c` files compress far better together), which is why `.tar.xz` beats `.zip` on a source tree and why `.zip` beats it on random access. Formats like `7z` and `dar` offer both by compressing in blocks with an index.

**A9.3** See the table in **A6.3**. The operational rule: **nightly log rotation → gzip** (logs are written and compressed constantly and read rarely; CPU on the production host is the scarce resource, and `logrotate`'s `compress` directive uses gzip by default). **A distributed release tarball → xz** (compressed once on a build machine where CPU is free, downloaded and decompressed thousands of times; every percent of ratio is bandwidth saved). bzip2 has no niche left — it is slower than xz to decompress *and* compresses worse.

**A9.4** The gzip format stores the uncompressed size in a trailing 4-byte field, so it is only valid **modulo 2³²** — for any input of 4 GiB or more, `gzip -l` reports `size mod 4294967296`, which is simply wrong with no warning. `file`'s own output states this explicitly: *"original size modulo 2^32"*. The reliable answer for a large member is to decompress and count without writing: `gzip -dc big.gz | wc -c`. (`xz --robot --list` reports true sizes because the xz container records them properly.)

**A9.5** `bzcat` for bzip2 and `xzcat` for xz (also `bzip2 -dc` and `xz -dc`; `zstdcat` for zstd). Note `zcat` on GNU systems also handles `.Z` (compress) and, in many builds, other formats — but do not rely on it for `.bz2`/`.xz`.

`zgrep` exists for ergonomics and correctness, not capability. It accepts and forwards **grep's full option set and multiple filename arguments**, and — crucially — it prefixes matches with the correct **filename** when given several files, which `gunzip -c *.gz | grep pat` cannot do because the pipeline has already merged the streams and lost the boundaries. It also transparently handles a mix of compressed and uncompressed inputs, so `zgrep 'ERROR' /var/log/messages*` works across a rotation set where some files are `.gz` and the current one is not. The same family provides `zdiff`, `zless`, `zmore`, `zcmp`.

**A9.6** `file` by default does **not follow** symlinks: it calls `lstat(2)`, sees a link, and reports the link itself along with its target path — which is the useful answer when you are auditing a tree for what is a link and where it points. `file -L` (`--dereference`) follows the link and identifies **what it points at**; the target `main.c` is a zero-byte file, and `file` classifies an empty regular file as `empty`. `file` also detects and reports **broken** links specially, since following them is impossible — that makes `file` a quick complement to `find -xtype l`.

**A9.7** `file` reads the beginning (and sometimes other offsets) of the file and matches the bytes against a database of **magic numbers** — signatures such as `1f 8b` for gzip, `42 5a 68` (`BZh`) for bzip2, `fd 37 7a 58 5a 00` for xz, `7f 45 4c 46` (`\x7fELF`) for ELF binaries, and `ustar` at offset 257 for POSIX tar. Only if no magic matches does it fall back to heuristics (character-set analysis for "ASCII text", language guessing) and to a final "data" verdict.

The database lives in `/usr/share/misc/magic.mgc` (a compiled binary, path varies: `/usr/share/file/magic.mgc` on some distributions), compiled from source rules in `/usr/share/misc/magic/` or `/etc/magic`; users can extend it with `~/.magic` or `file -m`. The consequence worth internalising: on Unix the **extension is a convention for humans**, carries no authority, and is checked by nothing in the kernel. `file` is the tool that answers the actual question, and `file -b --mime-type` is its script-friendly form.

**A9.8** `sha256sum -c` compares a cryptographic digest of the **entire byte stream**, so a single flipped or appended byte anywhere changes the digest and it fails. `tar -tzf` may still succeed because the appended NUL landed **after** the gzip stream's logical end: gzip's own CRC32 covers the compressed member, and tar stops at the end-of-archive marker, so both can reach a valid stopping point and ignore trailing garbage. Corruption *inside* the stream would have been caught — `gzip -t` did catch the mid-stream damage in Exercise 10 — but corruption in a region neither tool reads is invisible to them.

In a backup verification script, use **both, in cheap-to-expensive order**:
1. `sha256sum -c manifest` — authoritative on the archive file as shipped, catches every bit of drift including truncation and trailing junk;
2. `gzip -t` / `xz -t` — validates the compressed stream's own CRC without extracting;
3. `tar -tf` — proves the archive structure parses and lets you count members;
4. periodically, a **real test restore** into a scratch directory followed by `diff -r` or a per-file checksum comparison.

Only step 4 proves the backup is restorable. A backup that has never been restored is a hypothesis, not a backup.

---

### Block 10 — capstone

**A10.1** They cover two different things. `--exclude='cache'` matches the **directory** `app/cache` by its basename and prunes the whole subtree — nothing under it is even considered. `--exclude='*.cache'` matches **files by suffix** wherever they live, including a stray `app/data/session.cache` outside the cache directory.

For this specific tree, `--exclude='cache'` alone would have been sufficient, since every `*.cache` file happens to live inside it. Keeping both makes the rule express the *intent* ("no cache data, wherever it is") rather than the current layout, so it stays correct when someone later drops a cache file elsewhere. Note that GNU tar's `--exclude` patterns match against the member name and use wildcards by default, that `*` **does** cross `/` in exclusion patterns unless you use `--no-wildcards-match-slash`, and that exclusions must appear **before** the file operands they apply to.

**A10.2** Plain `diff -r` **follows symbolic links** and compares the contents of their targets. `app/bin/app.conf` → `../conf/app.conf` would be compared as a copy of the config file, and it would compare equal — even if the restore had materialised it as a **regular file** instead of a link. That hides a real regression: a restored tree where symlinks became file copies breaks the moment someone edits `conf/app.conf` and expects `bin/app.conf` to follow, and it silently doubles the size of link-heavy trees.

`--no-dereference` makes `diff` compare the links themselves — reporting `Symbolic links ... and ... differ` when one side is a link and the other is not. For archive verification the stronger check is `tar -df backup.tar.gz` (compares the archive against the live tree, including type, mode, owner and mtime) or a `find -printf '%y %m %s %p\n'` inventory diffed between the two trees.

**A10.3** `-r` (`--no-run-if-empty`) prevents `xargs` from running the command **once with no file arguments** when its input is empty. On a night when no log is older than 30 days, `find` outputs nothing; without `-r`, `xargs` still executes `gzip -v` with zero operands, and `gzip` with no operands **reads stdin and writes compressed data to stdout** — which, in a cron job, means gzip blocks on an empty stdin or emits binary garbage into the job's output mail, and the job's exit status becomes non-zero. With `-r`, `xargs` exits 0 having done nothing, which is the correct behaviour for a rotation that has nothing to rotate.

(`-r` is a GNU extension; POSIX `xargs` has no equivalent, which is one more reason to prefer `find -exec ... +`, which never runs the command with an empty file list.)

**A10.4** `gzip -t` (`--test`) decompresses the stream **without writing any output** and verifies the format's own integrity fields: the header magic, the DEFLATE stream structure, and the trailing **CRC-32** and length of the uncompressed data. Any corruption inside the compressed stream produces `invalid compressed data--crc error` and exit status 1. It is cheap — no disk written — and it is the fastest way to reject a bad archive before spending time on extraction.

The sha256 manifest is still worth keeping because `gzip -t` validates only **what the gzip stream claims about itself**. It cannot detect: trailing bytes appended after the stream ends; a wholesale substitution of the archive by a different, internally-valid archive; or deliberate tampering, since an attacker who modifies the content simply recomputes the CRC-32 (a 32-bit non-cryptographic checksum, trivially forgeable). A SHA-256 recorded at creation time and stored separately answers a different question — "is this the exact archive I made?" — which is the question that matters for both integrity and provenance.

**A10.5** The second run finds `app-1.log.gz`, not `app-1.log`, so the `-name '*.log'` test no longer matches it and it is left alone — that part is fine. The failure appears if a **new** `app-1.log` is created by the application and later ages past 30 days: `gzip` then finds `app-1.log.gz` already present and refuses, prompting `gzip: app-1.log.gz already exists; do you wish to overwrite (y or n)?`. In a cron job with no tty, `gzip` sees EOF on stdin, declines, and exits non-zero — the log is never compressed and the job reports failure every night thereafter.

Idempotent forms:
- add a unique suffix: `find app/logs -name '*.log' -mtime +30 -exec sh -c 'gzip -c "$1" > "$1.$(date +%F).gz" && rm "$1"' _ {} \;`
- or let `gzip` overwrite deliberately: `gzip -f`, accepting that the older archive is lost;
- or, in production, **do not hand-roll rotation at all** — `logrotate` with `compress`, `delaycompress`, `dateext` and `rotate N` handles naming, retention, and the reopen signal to the writing process, which a `find | gzip` pipeline does not (compressing a log that a daemon still holds open frees no space until the daemon reopens it).

**A10.6**
```bash
cd "$LAB/nightly"
find app -depth -path 'app/cache' -prune -o ! -name '*.cache' -print0 \
  | cpio --null -o -H newc | gzip -c > backup.cpio.gz
```
**`tar` is clearly easier.** The differences that matter:
- `tar` takes exclusions as its own options (`--exclude`), applied during its own recursion; `cpio` has no exclusion mechanism at all and must be fed a pre-filtered list, so the entire selection logic moves into a `find` expression with `-prune`/`-o`/`-print0`.
- `tar` compresses inline with a single flag (`-z`); `cpio` has no compression and needs an explicit pipe, which also means you must remember `gunzip -c backup.cpio.gz | cpio -idmv` on the way back.
- `tar` handles `-depth` ordering internally; with `cpio` you must remember it.

The compensating advantage — and the reason `cpio` still exists — is exactly that decoupling: because the file list is external, **any** selection `find` can express (or any other program that emits filenames, including a database query) drives the archive, with no need for the archiver to grow a new option. That, plus the format's simplicity, is why the kernel's initramfs is cpio and not tar.

</details>

---

## Common exam traps for 103.3

| Trap | Correct model |
|---|---|
| `cp -r src dst` behaves differently depending on whether `dst` exists | Final argument that is an existing directory ⇒ copy *into* it. Use `-T` or `src/.` for deterministic behaviour |
| `-size -1M` "means less than 1 MB" | Sizes are rounded **up** to the unit; `-1M` matches only empty files. Use `c` for exact bytes |
| `-mtime +7` "means older than a week" | Age is truncated to whole days; `+7` means **≥ 8 days** |
| `-maxdepth` placed after tests | Global options are not positional — put them right after the paths |
| `-delete` combined with `-prune` | `-delete` implies `-depth`, which makes `-prune` a no-op; use `! -path ...` |
| `tar -cfz archive.tar.gz dir` | `-f` consumes the next word — it must be the **last** letter of the cluster |
| `tar -r` on a `.tar.gz` | Append works only on uncompressed tar; a compressed archive is one solid stream |
| Extraction as a normal user gives mode 755 instead of 777 | umask is applied unless `-p`; root gets `-p` and `--same-owner` by default |
| `cpio -i` "doesn't extract anything" | Missing `-d`. The idiom is `cpio -idmv` |
| `cpio -i` silently skips a file | Default is to keep the newer existing file; `-u` overwrites unconditionally |
| `dd seek=` on an existing file empties it | Without `conv=notrunc`, the output is opened with `O_TRUNC` |
| `dd count=` copies fewer bytes than expected from a pipe | `count` counts `read()` calls; add `iflag=fullblock` |
| `find . -name *.txt` | Quote patterns meant for the program: `'*.txt'`. The shell expands unquoted globs first |
| `rm *` prompts unexpectedly | A file named `-i` was expanded into the argument list. Use `rm -- *` or `rm ./*` |
| `rm -rf .*` "removes hidden files" | `.*` matches `..`; use `.[!.]*` or `shopt -s dotglob` |
| `*` "matches everything" | It never matches a leading dot, and it is not a regular expression — `.` is literal |

---

## Sources

- LPI — *Exam 101 Objectives (LPIC-1, version 5.0)*, objective 103.3: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Coreutils Manual — `cp`, `mv`, `rm`, `rmdir`, `mkdir`, `touch`, `ls`, `dd`, `sha256sum`: <https://www.gnu.org/software/coreutils/manual/coreutils.html>
- GNU Findutils Manual — `find`, `xargs`: <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- GNU Tar Manual: <https://www.gnu.org/software/tar/manual/tar.html>
- GNU Cpio Manual: <https://www.gnu.org/software/cpio/manual/cpio.html>
- GNU Gzip Manual: <https://www.gnu.org/software/gzip/manual/gzip.html>
- GNU Bash Reference Manual — *Filename Expansion* and *Pattern Matching*: <https://www.gnu.org/software/bash/manual/bash.html#Filename-Expansion>
- XZ Utils (official project page and documentation): <https://tukaani.org/xz/>
- bzip2 (official project page): <https://sourceware.org/bzip2/>
- The `file` command and libmagic (official project): <https://www.darwinsys.com/file/>
- Linux man-pages project — `stat(2)`, `rename(2)`, `symlink(7)`, `open(2)`: <https://www.kernel.org/doc/man-pages/>
- The Open Group Base Specifications Issue 8 — `cp`, `mv`, `rm`, `find`, `pax`, and *Pattern Matching Notation*: <https://pubs.opengroup.org/onlinepubs/9799919799/>