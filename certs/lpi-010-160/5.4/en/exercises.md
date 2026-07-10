# Guided Exercises — Topic 5.4: Special Directories and Files

**Certification:** LPI Linux Essentials (010-160, version 1.6) · **Exam weight:** 1

These exercises are hands-on. Open a terminal on any Linux system (a virtual machine or container is fine). Everything runs as a regular user — no `sudo` needed — and all files live in `/tmp` or in a throwaway directory in your home, so nothing here can damage your system. After each block, answer the questions before checking the solutions at the end.

> Reference: LPI Learning Materials, Lesson 5.4 — https://learning.lpi.org/en/learning-materials/010-160/5/5.4/

---

## Exercise 1 — The System's Temporary Directories

Linux provides shared scratch space that every user and program can write to. The three standard locations differ in who cleans them and when.

1. Inspect the permissions of the standard temporary directories:
   ```bash
   ls -ld /tmp /var/tmp /run
   ```
   For `/tmp` you should see something like:
   ```
   drwxrwxrwt 15 root root 4096 Jul  7 10:32 /tmp
   ```
2. Note two things in that line: the owner is `root`, yet the permission string grants `rwx` to *others* — and the final character is a `t`, not an `x`.
3. Create your own temporary file and check who owns it:
   ```bash
   touch /tmp/scratch-$USER.txt
   ls -l /tmp/scratch-$USER.txt
   ```
4. Many programs decide where to put temporary files by reading the `TMPDIR` environment variable. Check whether it is set in your session:
   ```bash
   echo $TMPDIR
   ```
   An empty line means it is unset, and programs fall back to `/tmp`.

**Questions**

- **1a.** `/tmp` is owned by `root`, yet you created a file inside it without `sudo`. Which part of the permission string makes that possible?
- **1b.** What is the practical difference between `/tmp` and `/var/tmp` regarding how long files survive? Which one may be wiped on every reboot?
- **1c.** What kind of data lives in `/run`, and why is it typically not the place for *your* temporary files?
- **1d.** What is the purpose of the `TMPDIR` environment variable?

---

## Exercise 2 — The Sticky Bit

A world-writable directory has a problem: write permission on a directory allows deleting *any* entry in it, including other people's files. The sticky bit fixes exactly that.

1. Create two test directories in your home, one with the sticky bit and one without:
   ```bash
   mkdir ~/dropbox ~/plain
   chmod 1777 ~/dropbox
   chmod 777 ~/plain
   ls -ld ~/dropbox ~/plain
   ```
2. Compare the last character of each permission string: `t` versus `x`.
3. The sticky bit can also be managed in symbolic mode. Remove it, look, and add it back:
   ```bash
   chmod -t ~/dropbox
   ls -ld ~/dropbox
   chmod +t ~/dropbox
   ls -ld ~/dropbox
   ```
4. Verify that the real `/tmp` uses exactly this mode, expressed in octal:
   ```bash
   stat -c "%a %n" /tmp ~/dropbox
   ```
   Both should report `1777`.
5. Clean up:
   ```bash
   rmdir ~/dropbox ~/plain
   ```

**Questions**

- **2a.** In the octal mode `1777`, what does each digit stand for?
- **2b.** In a directory *with* the sticky bit set, who is allowed to delete or rename a file? (Three answers.)
- **2c.** Without the sticky bit, why could any user delete your files in a `777` directory, even if your files themselves are mode `600`?
- **2d.** In `ls -ld` output, what is the difference in meaning between a lowercase `t` and an uppercase `T` as the final character?

---

## Exercise 3 — Creating and Reading Symbolic Links

A symbolic link (or *symlink*, *soft link*) is a small special file that contains a path pointing to another file or directory.

1. Build a playground:
   ```bash
   mkdir ~/links-lab && cd ~/links-lab
   echo "version 1 of the data" > original.txt
   ```
2. Create a symbolic link to the file and inspect both:
   ```bash
   ln -s original.txt shortcut.txt
   ls -l
   ```
   Note the `l` as the first character of the link's line and the `->` arrow showing the target.
3. Use the link as if it were the file:
   ```bash
   cat shortcut.txt
   echo "extra line" >> shortcut.txt
   cat original.txt
   ```
4. Symlinks can also point to directories:
   ```bash
   mkdir -p deeply/nested/project
   ln -s deeply/nested/project proj
   ls -l proj
   touch proj/notes.txt
   ls deeply/nested/project
   ```
5. Now break the link on purpose:
   ```bash
   rm original.txt
   ls -l shortcut.txt
   cat shortcut.txt
   ```
   The link still exists, but following it fails — this is a *dangling* (broken) symlink.
6. Real systems use symlinks everywhere. Look at some:
   ```bash
   ls -l /usr/bin | grep -- '->' | head -5
   ```

**Questions**

- **3a.** In `ln -s original.txt shortcut.txt`, which argument is the target and which is the link name? What does the `-s` option select?
- **3b.** In step 3 you appended text through `shortcut.txt` and the change appeared in `original.txt`. Why?
- **3c.** After deleting `original.txt` in step 5, `ls -l` still shows `shortcut.txt` but `cat` fails. What exactly does a symlink store, and why does that explain the behavior?
- **3d.** Give two practical reasons why systems and administrators use symbolic links (step 6 hints at one).

---

## Exercise 4 — Hard Links and How They Differ

A hard link is not a special file at all: it is a second directory entry — a second *name* — for the same underlying inode (the data structure that actually holds the file).

1. Still in `~/links-lab`, create a file and a hard link to it (`ln` without `-s`):
   ```bash
   echo "shared content" > report.txt
   ln report.txt copy-name.txt
   ls -li report.txt copy-name.txt
   ```
   The `-i` option prints the **inode number** in the first column. Compare the two lines: same inode, and the link count (the number after the permissions) is `2`.
2. Modify the file through either name and check the other:
   ```bash
   echo "another line" >> copy-name.txt
   cat report.txt
   ```
3. Delete the *original* name and see what happens to the data:
   ```bash
   rm report.txt
   cat copy-name.txt
   ls -li copy-name.txt
   ```
   The content survives; the link count dropped back to `1`.
4. Try the two classic limitations of hard links:
   ```bash
   ln copy-name.txt /tmp/hardlink-test.txt
   mkdir somedir
   ln somedir dir-link
   ```
   The first command fails if `/tmp` is on a different filesystem (on many systems it is); the second always fails.
5. Compare with a symlink one more time:
   ```bash
   ln -s copy-name.txt sym.txt
   ls -li copy-name.txt sym.txt
   ```
   Different inodes: the symlink is its own small file.

**Questions**

- **4a.** After step 1, is there any way to tell which of `report.txt` and `copy-name.txt` is "the original"? Explain.
- **4b.** Why did the data survive in step 3 when its original name was deleted? When is the file's data actually freed?
- **4c.** State the two restrictions of hard links demonstrated in step 4, and note that symbolic links have neither.
- **4d.** A symlink to a file that gets deleted breaks; a hard link does not. Why?

---

## Exercise 5 — Links, Permissions and Everyday Use

Symlinks show their own fake permission string; the permissions that matter are the target's.

1. Look at a symlink's permissions:
   ```bash
   cd ~/links-lab
   echo "locked" > private.txt
   chmod 600 private.txt
   ln -s private.txt open-door.txt
   ls -l private.txt open-door.txt
   ```
   The link shows `lrwxrwxrwx` — apparently wide open.
2. Copy the two files' view of reality:
   ```bash
   cat open-door.txt
   ```
   It works for you — you own the target. The `rwxrwxrwx` on the link itself is never what is checked; access is decided by `private.txt`'s `600`.
3. Symlinks can use absolute or relative targets. Create one of each and test moving them:
   ```bash
   ln -s ~/links-lab/private.txt abs-link.txt
   ln -s private.txt rel-link.txt
   mkdir subdir
   mv abs-link.txt rel-link.txt subdir/
   cat subdir/abs-link.txt
   cat subdir/rel-link.txt
   ```
   The absolute link still works; the relative one broke because `subdir/private.txt` does not exist.
4. Clean up the whole lab:
   ```bash
   cd ~
   rm -rf ~/links-lab
   rm -f /tmp/scratch-$USER.txt /tmp/hardlink-test.txt
   ```

**Questions**

- **5a.** Why is the `rwxrwxrwx` shown on a symbolic link meaningless in practice? Whose permissions decide whether you can read through the link?
- **5b.** From step 3: when is a *relative* target the better choice for a symlink, and when is an *absolute* target safer?
- **5c.** In step 4, `rm` deletes the symlinks themselves. Does removing a symlink affect its target file in any way?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

- **1a.** The last permission triplet, `rwx` for **others**, applies to every user who is neither the owner (`root`) nor in the owning group. Write permission on the directory is what allows creating files in it, so any user can create entries in `/tmp`.
- **1b.** `/tmp` is short-term scratch space: many distributions clear it at every **reboot** (some keep it in RAM as a `tmpfs`), and cleanup jobs may delete old files even while the system runs. `/var/tmp` is for temporary files that should **persist across reboots**; it lives on disk and is preserved much longer.
- **1c.** `/run` holds **runtime data created by the system and services since boot** — PID files, sockets, lock files. It is recreated fresh at every boot and its subdirectories are mostly writable only by `root` or specific services, so it is not intended for users' scratch files.
- **1d.** `TMPDIR` tells programs **where to place their temporary files**, overriding the default of `/tmp`. Setting it lets a user or script redirect temporary data to a location with more space or different persistence.

### Exercise 2

- **2a.** The leading `1` is the **sticky bit**; the three `7`s are `rwx` (4+2+1) for the **owner**, the **group**, and **others** respectively. So `1777` = `rwxrwxrwt`.
- **2b.** Only the **owner of the file**, the **owner of the directory**, and **root** may delete or rename an entry in a sticky directory.
- **2c.** Deleting a file is an operation on the **directory**, not on the file: it removes a name from the directory's list of entries, and that requires only write permission **on the directory**. The file's own mode (`600`) is irrelevant to deletion, which is precisely the gap the sticky bit closes.
- **2d.** Lowercase `t` means sticky bit **plus** execute permission for others (`t` replaces the `x` that is present). Uppercase `T` means the sticky bit is set but others **lack execute** on the directory — an unusual and usually unintended combination.

### Exercise 3

- **3a.** The syntax is `ln -s TARGET LINK_NAME`: `original.txt` is the target (what the link points to) and `shortcut.txt` is the new link. `-s` selects a **symbolic** link; without it, `ln` creates a hard link.
- **3b.** Opening a symlink transparently opens its **target**. The shell followed `shortcut.txt` to `original.txt` and appended there — the link itself holds no data, so there is only one copy of the content.
- **3c.** A symlink stores only a **path** (a string of text). The link file itself still exists after the target is gone, so `ls` lists it, but any attempt to *follow* it fails because the stored path no longer resolves to anything — a dangling link.
- **3d.** Common reasons: (1) providing a **stable name for something that changes** — e.g., `/usr/bin/python` pointing at a specific versioned binary, or a `current` link pointing at the latest release directory; (2) making the same file or directory reachable from **several convenient locations** without duplicating data; (3) redirecting a legacy path to a new location without breaking programs that use the old one.

### Exercise 4

- **4a.** No. Both names are **equal directory entries pointing to the same inode**; the filesystem records no notion of which came first. "Original" and "link" are indistinguishable once created.
- **4b.** The inode keeps a **link count** of how many names refer to it. `rm report.txt` removed one name, dropping the count from 2 to 1 — still above zero, so the data stays. The data is freed only when the link count reaches **0** (and no process still has the file open).
- **4c.** Hard links (1) cannot cross **filesystem boundaries**, because an inode number only has meaning within its own filesystem, and (2) cannot point to **directories**, to keep the directory tree a loop-free hierarchy. Symbolic links can do both, since they store just a path.
- **4d.** A symlink refers to its target **by path**, so deleting the target leaves the path pointing at nothing. A hard link refers to the **inode itself** — it *is* the file under another name — so as long as any hard link remains, the file remains.

### Exercise 5

- **5a.** Permissions on the link file are never consulted when you access data through it; the kernel resolves the link and applies the **target's** permissions (plus those of the directories along the path). That is why symlinks conventionally display as `lrwxrwxrwx`. Reading `open-door.txt` succeeded only because `private.txt`'s mode `600` allows *you*, its owner, to read it.
- **5b.** A **relative** target is better when link and target live in the same tree that may be moved or renamed as a whole (the link keeps working after the move). An **absolute** target is safer when the link itself may be moved around but the target has a fixed, well-known location (like `/home/you/links-lab/private.txt` in the exercise).
- **5c.** No. `rm` on a symlink removes **only the link file**. The target is untouched — its data, permissions, and any other names for it remain exactly as they were.

</details>