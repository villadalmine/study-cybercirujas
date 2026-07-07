# Guided Exercises — Topic 2.3: Using Directories and Listing Files

**Certification:** LPI Linux Essentials (010-160, v1.6) · **Exam weight:** 2

Work through each block in a terminal. Type every command yourself — don't copy-paste — and observe the output before answering the questions.

---

## Exercise 1: Finding out where you are

Every shell session runs *inside* some directory, called the **current working directory**. Almost everything you do with files is interpreted relative to it.

1. Print your current working directory:
   ```bash
   pwd
   ```
   If you just opened a terminal, the output is probably something like `/home/yourname` — your **home directory**.
2. Change into the system-wide configuration directory and confirm you moved:
   ```bash
   cd /etc
   pwd
   ```
3. Go back home using the shortcut form — `cd` with no arguments:
   ```bash
   cd
   pwd
   ```
4. Do the same thing using the tilde shortcut:
   ```bash
   cd /etc
   cd ~
   pwd
   ```

**Questions**

- **1a.** What does `pwd` stand for, and what does it print?
- **1b.** Name two ways to return to your home directory from anywhere, without typing its full path.
- **1c.** Where do regular users' home directories usually live on a Linux system?

---

## Exercise 2: Absolute vs. relative paths

A path starting with `/` is **absolute** — it is resolved from the root of the filesystem. Any other path is **relative** — it is resolved from your current working directory.

1. Move to the root directory and list it:
   ```bash
   cd /
   ls
   ```
   You should see top-level directories such as `etc`, `home`, `usr`, and `var`.
2. Descend one level at a time using **relative** paths:
   ```bash
   cd usr
   pwd
   cd share
   pwd
   ```
3. Now jump to the same place in a single step using an **absolute** path:
   ```bash
   cd /
   cd /usr/share
   pwd
   ```
4. Try a relative path from the *wrong* starting point to see it fail:
   ```bash
   cd /etc
   cd usr/share
   ```
   The shell reports `No such file or directory` — there is no `usr` inside `/etc`.

**Questions**

- **2a.** What single character tells you a path is absolute?
- **2b.** Why did `cd usr/share` work from `/` but fail from `/etc`?
- **2c.** From `/usr/share`, give both a relative and an absolute path that reach `/usr`.

---

## Exercise 3: The special directories `.` and `..`

Every directory contains two special entries: `.` (this directory itself) and `..` (its **parent** directory).

1. Go somewhere deep and climb up one level:
   ```bash
   cd /usr/share/doc
   cd ..
   pwd
   ```
2. Climb two levels in one command:
   ```bash
   cd /usr/share/doc
   cd ../..
   pwd
   ```
3. "Change" into the current directory and observe that nothing moves:
   ```bash
   cd .
   pwd
   ```
4. Use `..` inside a longer path to move *sideways* — from one directory into a sibling:
   ```bash
   cd /usr/share
   cd ../lib
   pwd
   ```
5. Bounce back to wherever you were before the last `cd`:
   ```bash
   cd ~
   cd -
   pwd
   ```
   Note that `cd -` also prints the directory it switched to.

**Questions**

- **3a.** What do `.` and `..` refer to?
- **3b.** Starting from `/home/emma/projects`, where does `cd ../../..` leave you?
- **3c.** What is the difference between `cd ~` and `cd -`?

---

## Exercise 4: Listing files with `ls` and reading the long format

`ls` on its own shows only names. The `-l` option switches to the **long listing**, which packs in ownership, permissions, size, and timestamps.

1. List your home directory, then list it again in long format:
   ```bash
   cd ~
   ls
   ls -l
   ```
2. Pick one line of the `ls -l` output and identify its seven fields, left to right:
   ```
   drwxr-xr-x  2 emma emma 4096 Jun 30 15:33 Documents
   ```
   - file type + permissions (`d` = directory, `-` = regular file)
   - number of hard links
   - owning **user**
   - owning **group**
   - size in bytes
   - last modification time
   - name
3. List a directory you are *not* currently in, by passing it as an argument:
   ```bash
   ls -l /var/log
   ```
4. List information about the directory *itself* rather than its contents, using `-d`:
   ```bash
   ls -l /var/log/     # contents of the directory
   ls -ld /var/log/    # the directory entry itself, one line
   ```

**Questions**

- **4a.** In `ls -l` output, how do you tell a directory apart from a regular file?
- **4b.** Which two fields of the long listing tell you *who* owns a file?
- **4c.** Do you need to `cd` into a directory before you can list it? Justify with a command.

---

## Exercise 5: Hidden files and directories

On Linux, any file or directory whose name **starts with a dot** is hidden: `ls` skips it by default. This is a naming convention, not a security feature — it mainly keeps configuration files out of the way.

1. List your home directory normally, then with hidden entries included:
   ```bash
   cd ~
   ls
   ls -a
   ```
   Notice the new entries: `.` and `..`, plus dotfiles such as `.bashrc` or `.profile`.
2. Combine hidden entries with the long format:
   ```bash
   ls -la
   ```
3. Create your own hidden file and confirm the default listing ignores it:
   ```bash
   touch ~/.my-hidden-note
   ls
   ls -a | grep my-hidden
   ```
4. Clean up:
   ```bash
   rm ~/.my-hidden-note
   ```

**Questions**

- **5a.** What makes a file "hidden" on Linux?
- **5b.** Which `ls` option reveals hidden files?
- **5c.** Why do so many hidden files live in your home directory? Give one example and its purpose.

---

## Exercise 6: Human-readable sizes and combining options

Raw byte counts are hard to read. The `-h` option makes `ls -l` print sizes with units (K, M, G). Short options can be combined behind a single dash.

1. Long-list a directory with large files, first in bytes, then human-readable:
   ```bash
   ls -l /boot
   ls -l -h /boot
   ```
2. Combine the options into one argument — these are equivalent:
   ```bash
   ls -lh /boot
   ls -hl /boot
   ```
3. Stack three options: long format, human-readable, and hidden files:
   ```bash
   ls -lha ~
   ```
4. Confirm that `-h` alone changes nothing visible:
   ```bash
   ls -h ~
   ```
   Without `-l` there are no sizes displayed, so there is nothing for `-h` to convert.

**Questions**

- **6a.** What does `ls -lh` do that `ls -l` does not?
- **6b.** Is `ls -l -h -a` different from `ls -lha`? Does the order of combined options matter?
- **6c.** Why does `ls -h` on its own appear to do nothing?

---

## Exercise 7: Recursive listings

Sometimes you want to see not just a directory, but everything *underneath* it. The `-R` option makes `ls` descend into every subdirectory.

1. Build a small directory tree to explore:
   ```bash
   mkdir -p ~/lab23/reports/2026
   touch ~/lab23/notes.txt ~/lab23/reports/summary.txt ~/lab23/reports/2026/january.txt
   ```
2. List the top level only, then recursively:
   ```bash
   ls ~/lab23
   ls -R ~/lab23
   ```
   Observe how the recursive output is grouped: each subdirectory gets its own block, introduced by its path and a colon.
3. Combine recursion with the long format:
   ```bash
   ls -lR ~/lab23
   ```
4. Clean up the practice tree:
   ```bash
   rm -r ~/lab23
   ```

**Questions**

- **7a.** What does `ls -R` do, and how is its output organized?
- **7b.** `ls -R /` would be legal but is usually a bad idea on a real system. Why?
- **7c.** Case matters: what does the lowercase `-r` option do instead? (Check `ls --help` if unsure.)

---

<details>
<summary><strong>Answers</strong></summary>

**1a.** `pwd` stands for **print working directory**. It prints the absolute path of the directory your shell is currently in.

**1b.** `cd` with no arguments, and `cd ~`. (Also acceptable: `cd $HOME`.) All three take you to your home directory from anywhere.

**1c.** Under `/home`, in a subdirectory named after the user — e.g. `/home/emma`. (The root user is the exception: root's home is `/root`.)

**2a.** A leading slash `/`. If the path starts with `/`, it is absolute and resolved from the filesystem root; otherwise it is relative to the current working directory.

**2b.** Because relative paths are resolved from the current working directory. From `/`, the path `usr/share` means `/usr/share`, which exists. From `/etc`, the same path means `/etc/usr/share`, which does not exist.

**2c.** Relative: `cd ..` — absolute: `cd /usr`.

**3a.** `.` is the current directory itself; `..` is the parent directory (the directory one level up).

**3b.** In `/` (the root directory): each `..` climbs one level — `projects` → `emma` → `home` → `/`.

**3c.** `cd ~` always goes to your **home directory**. `cd -` goes to the **previous working directory** — wherever you were before the last `cd` — and prints that path. Running `cd -` repeatedly toggles between two locations.

**4a.** By the first character of the line: `d` means directory, `-` means regular file. (Other values exist, e.g. `l` for a symbolic link.)

**4b.** The owning **user** (third field) and the owning **group** (fourth field).

**4c.** No. `ls` accepts a path as an argument, so `ls -l /var/log` lists that directory from wherever you are — no `cd` required.

**5a.** Its name begins with a dot (`.`), e.g. `.bashrc`. That is the entire mechanism — a naming convention that default listings respect, not a permission or security setting.

**5b.** `-a` (all). It shows every entry, including dotfiles and the special entries `.` and `..`. (The variant `-A` shows dotfiles but omits `.` and `..`.)

**5c.** Programs store per-user configuration there and hide it to avoid cluttering everyday listings. Example: `.bashrc` holds personal settings for the Bash shell, such as aliases; another example is `.profile`, read at login.

**6a.** It prints file sizes in **human-readable units** (e.g. `4.0K`, `13M`, `1.2G`) instead of raw byte counts.

**6b.** No difference — `-lha`, `-lah`, and `-l -h -a` are all equivalent. Single-letter options can be written separately or bundled after one dash, and their order does not matter for `ls`.

**6c.** `-h` only changes *how sizes are displayed*, and the default short listing shows no sizes at all. It becomes useful only in combination with `-l` (or `-s`).

**7a.** It lists the directory and then **recursively** lists every subdirectory beneath it. The output is one block per directory, each introduced by the directory's path followed by a colon, then its contents.

**7b.** Recursion from `/` walks the **entire filesystem** — potentially millions of entries — producing enormous, slow output (and many "permission denied" errors for a regular user). Recursive commands should be aimed at the smallest tree that answers your question.

**7c.** Lowercase `-r` (`--reverse`) reverses the sort order of the listing — it has nothing to do with recursion. Recursion is uppercase `-R`.

</details>

---

**Reference:** LPI Learning Materials, Lesson 2.3 — *Using Directories and Listing Files*: <https://learning.lpi.org/en/learning-materials/010-160/2/2.3/>