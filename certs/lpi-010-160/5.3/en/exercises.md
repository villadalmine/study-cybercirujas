# Guided Exercises — Topic 5.3: Managing File Permissions and Ownership

**Certification:** LPI Linux Essentials (010-160, version 1.6) · **Exam weight:** 2

These exercises are hands-on. Open a terminal on any Linux system (a virtual machine or container is fine). Everything happens inside a throwaway directory in your home, so nothing here can damage your system; a few steps use `sudo` to demonstrate ownership changes. After each block, answer the questions before checking the solutions at the end.

> Reference: LPI Learning Materials, Lesson 5.3 — https://learning.lpi.org/en/learning-materials/010-160/5/5.3/

---

## Exercise 1 — Reading the Permission String

Every file listing starts with a 10-character string that encodes the file type and three sets of permissions. Learn to read it before changing anything.

1. Create a playground and some objects to inspect:
   ```bash
   mkdir ~/perms-lab && cd ~/perms-lab
   touch report.txt
   mkdir archive
   echo "secret" > .hidden-note
   ```
2. List the directory in long format:
   ```bash
   ls -l
   ```
   Read each line as: `type + permissions`, link count, **owner**, **group**, size, timestamp, name.
3. The hidden file did not appear. List again including hidden entries:
   ```bash
   ls -la
   ```
4. Compare the first character of the `report.txt` line with the first character of the `archive` line. Then look at a device file and a symbolic link for contrast:
   ```bash
   ls -l /dev/null /etc/localtime
   ```

**Questions**

- **1a.** In the string `-rw-r--r--`, what does the very first character indicate, and what would `d` or `l` in that position mean?
- **1b.** The remaining nine characters form three groups of three. Which three *classes* of users do they describe, in order?
- **1c.** What makes a file "hidden" in Linux, and which `ls` option reveals hidden files?
- **1d.** In the `ls -l` output for `report.txt`, which two columns tell you who the owner and the owning group are?

---

## Exercise 2 — What r, w and x Mean for Files

The same three letters have precise meanings on regular files: read the contents, change the contents, execute as a program.

1. Still inside `~/perms-lab`, create a tiny script:
   ```bash
   echo -e '#!/bin/bash\necho "It works!"' > hello.sh
   ls -l hello.sh
   ```
2. Try to run it — this should fail:
   ```bash
   ./hello.sh
   ```
3. Grant execute permission to the owner using **symbolic mode**, then run it again:
   ```bash
   chmod u+x hello.sh
   ls -l hello.sh
   ./hello.sh
   ```
4. Now remove your own read permission and see what breaks:
   ```bash
   chmod u-r hello.sh
   cat hello.sh
   ./hello.sh
   ```
5. Restore read access:
   ```bash
   chmod u+r hello.sh
   ```

**Questions**

- **2a.** Why did `./hello.sh` fail in step 2 even though you had just created the file yourself?
- **2b.** In `chmod u+x`, what do the `u`, the `+`, and the `x` each stand for? What would `chmod go-w file` do?
- **2c.** After step 4 the script had execute but not read permission for you — and running it still failed. Why does a shell script need *both* `r` and `x` to run?

---

## Exercise 3 — What r, w and x Mean for Directories

On directories the same letters mean something different: `r` lists names, `w` creates/deletes entries, `x` enters the directory and reaches its contents.

1. Build a small tree:
   ```bash
   cd ~/perms-lab
   mkdir vault
   echo "inside" > vault/data.txt
   ```
2. Remove *execute* from the directory and try to work with it:
   ```bash
   chmod u-x vault
   ls vault
   cat vault/data.txt
   cd vault
   ```
   Note exactly which commands fail.
3. Restore execute, then remove *read* instead:
   ```bash
   chmod u+x vault
   chmod u-r vault
   ls vault
   cat vault/data.txt
   ```
4. Restore read, then remove *write* and try to create and delete files inside:
   ```bash
   chmod u+r vault
   chmod u-w vault
   touch vault/new.txt
   rm vault/data.txt
   ```
5. Clean up the permissions:
   ```bash
   chmod u+w vault
   ```

**Questions**

- **3a.** With `r` but not `x` on a directory (step 2 reversed in step 3), `ls vault` partially works but `cat vault/data.txt` fails. Explain what each of `r` and `x` allows on a directory.
- **3b.** In step 4 you could not delete `vault/data.txt` even though *you own that file and it is writable*. Which permission, on which object, controls deleting a file?
- **3c.** A directory that others may pass through but not list is a common setup for shared systems. Which permission combination on the directory achieves "can traverse, cannot list"?

---

## Exercise 4 — Octal (Numeric) Mode

Each permission triplet can be written as one digit: `r = 4`, `w = 2`, `x = 1`, added together. Three digits describe owner, group, and others at once.

1. Create a file and set some classic modes, checking the result each time:
   ```bash
   cd ~/perms-lab
   touch numbers.txt
   chmod 644 numbers.txt && ls -l numbers.txt
   chmod 600 numbers.txt && ls -l numbers.txt
   chmod 755 numbers.txt && ls -l numbers.txt
   chmod 777 numbers.txt && ls -l numbers.txt
   ```
2. Convert in the other direction — set a mode symbolically and predict the number before checking:
   ```bash
   chmod u=rwx,g=rx,o= numbers.txt
   ls -l numbers.txt
   stat -c "%a %n" numbers.txt
   ```
3. Apply a mode recursively to a whole tree:
   ```bash
   mkdir -p project/src
   touch project/src/main.c
   chmod -R 750 project
   ls -lR project
   ```

**Questions**

- **4a.** Decode `644`, `755`, and `600` into permission strings (`rwxrwxrwx` style). Which of the three is the typical default for a new text file, and which for a directory or program?
- **4b.** What octal number corresponds to `rw-rw-r--`? And to `r-xr-x---`?
- **4c.** Why is `chmod 777` almost always a bad idea, even when it "makes the error go away"?
- **4d.** What does the `-R` option of `chmod` do, and why should you be careful applying `755` recursively to a tree that mixes directories and plain data files?

---

## Exercise 5 — Symbolic Mode in Depth

Symbolic mode shines when you want to adjust one class without recalculating the whole number.

1. Reset a file to a known state:
   ```bash
   cd ~/perms-lab
   touch memo.txt
   chmod 644 memo.txt
   ```
2. Practice targeted changes, checking with `ls -l memo.txt` after each:
   ```bash
   chmod g+w memo.txt        # add write for the group
   chmod o-r memo.txt        # remove read from others
   chmod a+x memo.txt        # add execute for everyone
   chmod u=rw,go= memo.txt   # set exact permissions, wiping the rest
   ```
3. Combine several changes in one command:
   ```bash
   chmod u+x,g+r,o-rwx memo.txt
   ls -l memo.txt
   ```

**Questions**

- **5a.** What are the four *class* letters accepted by symbolic `chmod`, and which classes does each one target?
- **5b.** Explain the difference between the operators `+`, `-`, and `=`. Which one is "safe" in the sense that it only touches the bits you name?
- **5c.** After `chmod u=rw,go= memo.txt`, what is the octal mode of the file?

---

## Exercise 6 — Changing Ownership: chown and chgrp

Every file has exactly one owner and one owning group. Regular users can give away group ownership only to groups they belong to; changing the *owner* is reserved for `root`.

1. See your own identity and group memberships:
   ```bash
   id
   ```
2. Create a file and try to give it away as a regular user — this should fail:
   ```bash
   cd ~/perms-lab
   touch handover.txt
   chown root handover.txt
   ```
3. Do it with administrative rights, then inspect:
   ```bash
   sudo chown root handover.txt
   ls -l handover.txt
   ```
4. Change owner *and* group in one command, then only the group:
   ```bash
   sudo chown root:root handover.txt
   sudo chgrp $USER handover.txt
   ls -l handover.txt
   ```
5. Create a shared group, add a file to it, and hand a whole tree over recursively:
   ```bash
   sudo groupadd project-team
   mkdir shared
   touch shared/plan.txt
   sudo chown -R :project-team shared
   ls -l shared
   ```

**Questions**

- **6a.** Why is `chown` to another user restricted to `root`? Think about what a user could do with disk quotas or with blame for malicious files.
- **6b.** What is the difference between `chown alice file`, `chown alice:staff file`, and `chown :staff file`? Which of the three can `chgrp` replicate?
- **6c.** After step 3, can you still edit `handover.txt`? Check with `ls -l` and explain which permission triplet now applies to you.

---

## Exercise 7 — Special Permissions: setuid, setgid and the Sticky Bit

Three extra bits appear in the same string: `s` in the owner triplet (setuid), `s` in the group triplet (setgid), and `t` in the others triplet (sticky).

1. Find a classic setuid program and inspect it:
   ```bash
   ls -l /usr/bin/passwd
   ```
   Note the `s` where you would expect the owner's `x`.
2. Look at the world-writable temporary directory:
   ```bash
   ls -ld /tmp
   ```
   Note the `t` at the end of the permission string.
3. Create a setgid collaboration directory and watch group inheritance:
   ```bash
   cd ~/perms-lab
   mkdir teamdir
   sudo chgrp project-team teamdir
   chmod g+s teamdir
   ls -ld teamdir
   touch teamdir/newfile.txt
   ls -l teamdir/newfile.txt
   ```
4. In octal, special bits are a fourth digit in front: setuid = 4, setgid = 2, sticky = 1. Reproduce the `/tmp` mode on a test directory:
   ```bash
   mkdir droparea
   chmod 1777 droparea
   ls -ld droparea
   ```

**Questions**

- **7a.** `passwd` must edit `/etc/shadow`, which only `root` can write — yet any user can change their own password. How does the setuid bit make this possible?
- **7b.** What does the sticky bit on `/tmp` prevent, given that `/tmp` is writable by everyone?
- **7c.** In step 3, which group owns `teamdir/newfile.txt`, and why is that useful for a directory shared by a team?
- **7d.** Decode the mode `1777` from step 4 digit by digit.

---

## Cleanup

Remove everything the exercises created:

```bash
cd ~
sudo rm -rf ~/perms-lab
sudo groupdel project-team
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

- **1a.** The first character is the **file type**: `-` means a regular file, `d` a directory, and `l` a symbolic link. (Other values exist, such as `c` and `b` for character and block devices.)
- **1b.** In order: the **owner** (user) of the file, the **owning group**, and **others** (everyone else). Each class gets its own `rwx` triplet.
- **1c.** A file is hidden simply because its name starts with a dot (`.`). There is no separate "hidden" attribute. `ls -a` (or `-la` combined with long format) reveals dot files.
- **1d.** The third column is the owner and the fourth column is the owning group (right after the link count, before the size).

### Exercise 2

- **2a.** Creating a file does not make it executable. New files typically get read/write permissions only (e.g., `rw-r--r--`), so the shell refuses to execute it with "Permission denied" until the `x` bit is set.
- **2b.** `u` selects the **user/owner** class, `+` means **add** the permission, and `x` is **execute**. `chmod go-w file` removes (`-`) write permission (`w`) from both the group (`g`) and others (`o`).
- **2c.** To run a shell script, the kernel checks the `x` bit, but then the interpreter (`/bin/bash`) must *open and read* the script text — which requires `r`. Compiled binaries can run with `x` alone, but interpreted scripts need both `r` and `x`.

### Exercise 3

- **3a.** On a directory, `r` allows **listing the names** of entries, while `x` allows **traversing** it — reaching the inodes inside, which is needed to open files, `cd` into it, or even read file metadata. With `r` but no `x`, `ls` can show names (often with errors about the details) but no file inside can actually be opened.
- **3b.** Deleting a file means **removing an entry from the directory**, so it is governed by the **write permission on the directory** that contains the file — not by the permissions of the file itself. Without `w` on `vault`, neither `touch` (create) nor `rm` (delete) inside it works.
- **3c.** Execute without read: `--x` (e.g., `chmod o=x dir`, or modes like `711` on a home directory). Users can pass through it to reach a known path inside, but `ls` on the directory fails.

### Exercise 4

- **4a.** `644` = `rw-r--r--`, `755` = `rwxr-xr-x`, `600` = `rw-------`. `644` is the typical default for a new text file; `755` is typical for directories and executable programs; `600` suits private files (keys, mail spools).
- **4b.** `rw-rw-r--` = `664`. `r-xr-x---` = `550`.
- **4c.** `777` gives every user on the system full read, write, and execute access. Anyone can modify or replace the file (or, on a directory, delete anything inside). It "fixes" symptoms by removing all protection, which is a security hole; the right fix is granting the specific class the specific permission it lacks.
- **4d.** `-R` applies the mode to the directory **and everything below it, recursively**. Blindly applying `755` recursively makes every data file executable, which is wrong (data should not carry `x`); conversely, applying `644` recursively would strip `x` from directories, breaking traversal. Directories and files usually need different modes.

### Exercise 5

- **5a.** `u` = user/owner, `g` = group, `o` = others, `a` = all three at once (equivalent to `ugo`).
- **5b.** `+` **adds** the named permissions to whatever is already set; `-` **removes** them; `=` **sets exactly** the named permissions, clearing any others for that class. `+` and `-` are the "safe" incremental operators — they only touch the bits you name, while `=` overwrites the whole triplet.
- **5c.** `u=rw` gives the owner `rw-` (6); `go=` clears group and others to `---` (0 and 0). The octal mode is `600`.

### Exercise 6

- **6a.** If users could give files away, they could dodge **disk quotas** (charge their large files to someone else's account) or **shift blame** — planting a malicious or embarrassing file owned by another user. Ownership is part of the system's accountability model, so only `root` may reassign it.
- **6b.** `chown alice file` changes only the **owner**. `chown alice:staff file` changes **owner and group** in one step. `chown :staff file` changes only the **group** — which is exactly what `chgrp staff file` does; that is the only one of the three `chgrp` can replicate.
- **6c.** Yes for reading, no for writing (with the typical `644` mode). Once `root` owns the file, you are no longer the owner; if the group is also `root`, you match only the **others** triplet, `r--`. You can `cat` it but an editor cannot save changes. (You can still *delete* it, because the containing directory is yours and writable — see 3b.)

### Exercise 7

- **7a.** The setuid bit makes the program run **with the effective identity of the file's owner** instead of the identity of the user who launched it. `passwd` is owned by `root` and has setuid, so while it runs it has `root`'s power and can update `/etc/shadow` — but the program itself restricts *what* it will do (only change your own password, after verifying the current one).
- **7b.** In a world-writable directory, write permission would normally let *anyone* delete or rename *anyone else's* files (deletion is a directory-write operation, per 3b). The sticky bit (`t`) restricts deletion/renaming in that directory to the **file's owner**, the directory's owner, and `root` — so users sharing `/tmp` cannot remove each other's temporary files.
- **7c.** `project-team` owns `newfile.txt`. On a setgid directory, new files **inherit the directory's group** instead of the creator's primary group. In a shared directory this means every file automatically belongs to the team's group, so all members can access it according to the group permissions without anyone running `chgrp` by hand.
- **7d.** The leading `1` is the **sticky bit**; each `7` is `rwx` (4+2+1) for owner, group, and others respectively. Result: `rwxrwxrwt` — everyone may create files, but only owners may delete their own.

</details>