# Topic 2.4: Creating, Moving and Deleting Files — Guided Exercises

**LPI Linux Essentials (010-160), version 1.6 — Topic 2.4 (weight: 2)**

Reference: [LPI Learning Materials — 010-160 / 2 / 2.4](https://learning.lpi.org/en/learning-materials/010-160/2/2.4/)

These exercises assume a Bash shell on a Linux system, and a scratch directory to work in. Run the numbered steps in order, then answer the check questions before moving to the next exercise.

---

## Exercise 1 — Creating files with `touch`

1. Create a working directory and move into it:
   ```
   mkdir ~/lpi-2.4 && cd ~/lpi-2.4
   ```
2. Create an empty file:
   ```
   touch notes.txt
   ```
3. List the file with detailed timestamps:
   ```
   ls -l notes.txt
   ```
4. Run `touch notes.txt` again, then repeat step 3.
5. Create three files in a single command:
   ```
   touch report.txt report.bak report.old
   ```

**Check your understanding**
- If `notes.txt` already exists, what does `touch` change about it, and what does it *not* change?
- Does `touch` fail or succeed if the file it names does not yet exist? What does it do in that case?

---

## Exercise 2 — Creating directories with `mkdir`

1. From `~/lpi-2.4`, try creating a nested directory in one step:
   ```
   mkdir projects/2024/reports
   ```
   Observe the error message.
2. Now create the same nested path using the parent-creation flag:
   ```
   mkdir -p projects/2024/reports
   ```
3. Confirm the full tree was created:
   ```
   find projects -type d
   ```
4. Create several sibling directories at once:
   ```
   mkdir -p projects/2024/{drafts,final}
   ```
5. List the result:
   ```
   ls projects/2024
   ```

**Check your understanding**
- Why did step 1 fail, and which flag in step 2 fixed it?
- What does brace expansion (`{drafts,final}`) do here, and is it a feature of `mkdir` or of the shell?

---

## Exercise 3 — Copying files and directories with `cp`

1. Copy a single file, giving the copy a new name:
   ```
   cp notes.txt notes-backup.txt
   ```
2. Copy a file into a directory, keeping its original name:
   ```
   cp report.txt projects/2024/drafts/
   ```
3. Try copying the whole `projects` directory without any flag:
   ```
   cp projects projects-copy
   ```
   Observe the error.
4. Copy it recursively instead:
   ```
   cp -r projects projects-copy
   ```
5. Overwrite `notes-backup.txt` but ask for confirmation first:
   ```
   cp -i notes.txt notes-backup.txt
   ```

**Check your understanding**
- Why does plain `cp` refuse to copy a directory, and what does `-r` change?
- What is the purpose of the `-i` flag, and in what situation would you want it turned on by default?

---

## Exercise 4 — Moving and renaming with `mv`

1. Rename a file in place:
   ```
   mv notes.txt notes-2024.txt
   ```
2. Move a file into a directory:
   ```
   mv report.bak projects/2024/drafts/
   ```
3. Move and rename in a single command:
   ```
   mv report.old projects/2024/final/report-final.txt
   ```
4. Move an entire directory tree:
   ```
   mv projects-copy projects-archive
   ```
5. Try moving a file onto an existing filename to see it get replaced silently, then repeat with `-i`:
   ```
   mv notes-backup.txt notes-2024.txt
   mv -i report.txt notes-2024.txt
   ```

**Check your understanding**
- Does `mv` create a copy and then delete the source, or does it typically just rename the directory entry? Does this behavior change when moving across filesystems?
- What single tool handles both "rename" and "move," and how does the shell decide which behavior you get?

---

## Exercise 5 — Removing files and directories with `rm` and `rmdir`

1. Remove a single file:
   ```
   rm notes-2024.txt
   ```
2. Try removing an empty directory with `rmdir`:
   ```
   mkdir empty-dir
   rmdir empty-dir
   ```
3. Try `rmdir` on a directory that still has content:
   ```
   rmdir projects/2024/drafts
   ```
   Observe the error.
4. Remove that non-empty directory recursively instead:
   ```
   rm -r projects/2024/drafts
   ```
5. Remove multiple items, forcing silence on any "does not exist" errors:
   ```
   rm -f ghost-file.txt
   ```
6. Remove a directory tree while confirming each deletion:
   ```
   rm -ri projects-archive
   ```

**Check your understanding**
- Why does `rmdir` refuse to remove `projects/2024/drafts` in step 3, and what condition must be true for `rmdir` to succeed?
- What is the practical difference between `rm -r` and `rm -rf`, and why is the second one considered riskier?

---

## Exercise 6 — Using wildcards for bulk operations

1. Recreate some sample files:
   ```
   cd ~/lpi-2.4
   touch file1.txt file2.txt file3.log image1.png image2.png
   ```
2. List only the `.txt` files using a wildcard:
   ```
   ls *.txt
   ```
3. Copy all `.png` files into a new directory:
   ```
   mkdir images
   cp *.png images/
   ```
4. Move every file matching `file?.txt` (single-character wildcard) elsewhere:
   ```
   mkdir textfiles
   mv file?.txt textfiles/
   ```
5. Remove all `.log` files:
   ```
   rm *.log
   ```

**Check your understanding**
- What is the difference between the `*` and `?` wildcards when matching filenames?
- Which program actually expands `*.txt` before `cp` or `mv` ever sees it: the command itself, or the shell?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
- If `notes.txt` already exists, `touch` updates its access and modification timestamps to the current time; it does not change the file's content or size.
- `touch` succeeds and creates a new, empty file if the named file does not exist.

**Exercise 2**
- `mkdir projects/2024/reports` fails because `mkdir` by default requires every parent directory (`projects`, `projects/2024`) to already exist. The `-p` flag tells `mkdir` to create any missing parent directories along the way, and to not complain if the target already exists.
- `{drafts,final}` is shell brace expansion: the shell rewrites it into two separate arguments (`projects/2024/drafts` and `projects/2024/final`) before `mkdir` even runs. It is a shell feature, not something `mkdir` implements.

**Exercise 3**
- Plain `cp` copies files only; a directory is not a single stream of data but a container, so `cp` needs the `-r` (recursive) flag to walk into it and copy its full contents, including subdirectories.
- `-i` (interactive) makes `cp` prompt for confirmation before overwriting an existing destination file. It's useful when scripting or working in shared directories where accidentally clobbering a file could cause data loss.

**Exercise 4**
- Within the same filesystem, `mv` is typically just a metadata operation: it changes the directory entry (name/location) without physically copying the file's data blocks, which is why it's fast even for very large files. When moving across filesystems, this shortcut isn't possible, so `mv` transparently falls back to copying the data to the destination and then removing the original.
- `mv` handles both cases; whether it's a "rename" or a "move" is just a matter of whether the destination path is in the same directory as the source or a different one — from `mv`'s perspective it's the same operation.

**Exercise 5**
- `rmdir` only removes directories that are empty; `projects/2024/drafts` still contained files, so `rmdir` refuses to delete it to avoid silently discarding data.
- `rm -r` deletes a directory and its contents recursively but will still prompt or stop on issues like write-protected files (depending on system defaults); `rm -rf` adds `-f` (force), which suppresses prompts and ignores nonexistent-file errors, removing everything unconditionally. This makes `-rf` riskier because it removes the safety checks that might otherwise stop an unintended deletion.

**Exercise 6**
- `*` matches any sequence of characters (including none), while `?` matches exactly one character. So `*.txt` matches any filename ending in `.txt` regardless of length, while `file?.txt` only matches names with exactly one character between `file` and `.txt` (like `file1.txt`, not `file10.txt`).
- The shell expands the wildcard into a list of matching filenames before invoking the command; `cp`, `mv`, and `rm` simply receive the already-expanded list of arguments and have no wildcard logic of their own.

</details>