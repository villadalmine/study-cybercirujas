# 5.3 Managing File Permissions and Ownership

**Exam weight: 2** — Linux Essentials 010-160, version 1.6

## Why permissions matter

Because Linux is a multi-user system, it needs a way to decide who may read, change, or run each file. Every file and directory carries two pieces of security metadata: an **ownership** record (which user and which group it belongs to) and a set of **permissions** (what the owner, the group, and everyone else may do with it). Together they form the classic Unix access-control model, and Topic 5.3 is about reading that information, understanding what it means, and changing it with `chmod`, `chown`, and `chgrp`.

## Reading permissions with `ls -l`

The long listing shows the whole picture:

```
$ ls -l
-rw-r--r-- 1 carol staff  4096 Jul  6 10:12 report.txt
drwxr-x--- 2 carol staff  4096 Jul  6 09:40 projects
-rwxr-xr-x 1 root  root  12408 Jun 30 15:02 backup.sh
```

The first column is a 10-character string. Break it down for `-rw-r--r--`:

| Position | Example | Meaning |
|---|---|---|
| 1 | `-` | File type: `-` regular file, `d` directory, `l` symbolic link |
| 2–4 | `rw-` | Permissions for the **user** (owner) |
| 5–7 | `r--` | Permissions for the **group** |
| 8–10 | `r--` | Permissions for **others** (everyone else) |

After the permission string come the link count, the **owning user** (`carol`), the **owning group** (`staff`), the size, the modification time, and the name.

### What r, w and x mean

The same three letters mean slightly different things on files and on directories — a favorite exam question:

| Permission | On a regular file | On a directory |
|---|---|---|
| `r` (read) | View the file's contents | List the names inside the directory (`ls`) |
| `w` (write) | Modify the file's contents | Create, delete, or rename files inside it |
| `x` (execute) | Run the file as a program or script | Enter the directory (`cd`) and access its files |

Two consequences worth remembering:

- To delete a file you need **write permission on the directory**, not on the file itself — deleting is a change to the directory's list of names.
- A directory with `r` but not `x` lets you see the names inside but not open them; with `x` but not `r` you can access files if you already know their names, but not list them. In practice directories almost always get `r` and `x` together.

### Which set applies to you?

Linux checks the classes in order and uses the **first one that matches**: if you are the owner, only the user bits apply; otherwise, if you are in the owning group, the group bits apply; otherwise the others bits apply. The superuser (`root`) bypasses permission checks entirely.

## Octal (numeric) notation

Each permission triplet can be written as one digit by adding the values of the bits that are set:

| Permission | Value |
|---|---|
| `r` | 4 |
| `w` | 2 |
| `x` | 1 |

So `rwx` = 4+2+1 = **7**, `rw-` = 4+2 = **6**, `r-x` = 4+1 = **5**, `r--` = **4**, and `---` = **0**. Three digits describe a whole mode, user–group–others:

| Mode | Symbolic | Typical use |
|---|---|---|
| `755` | `rwxr-xr-x` | Directories, executables, scripts |
| `644` | `rw-r--r--` | Regular files (documents, config) |
| `700` | `rwx------` | Private directories (e.g. `~/.ssh`) |
| `600` | `rw-------` | Private files (keys, credentials) |
| `777` | `rwxrwxrwx` | Everyone can do everything — almost always a mistake |

Practice converting in both directions; the exam tests it. For example, `-rwxr-x---` is `750`, and `664` renders as `rw-rw-r--`.

## Changing permissions: `chmod`

`chmod` (change mode) accepts either octal or symbolic arguments. Only the file's owner (or root) may change a file's permissions.

### Octal mode

Sets all nine bits at once:

```
$ chmod 640 report.txt
$ ls -l report.txt
-rw-r----- 1 carol staff 4096 Jul  6 10:12 report.txt
```

### Symbolic mode

Adjusts specific bits without touching the rest. The syntax is *who* + *operator* + *what*:

- **Who:** `u` (user/owner), `g` (group), `o` (others), `a` (all three)
- **Operator:** `+` add, `-` remove, `=` set exactly
- **What:** `r`, `w`, `x`

```
$ chmod u+x backup.sh          # make it executable for the owner
$ chmod go-w shared.txt        # remove write from group and others
$ chmod a=r notes.txt          # everyone gets read only: r--r--r--
$ chmod u=rwx,g=rx,o= private/ # equivalent to chmod 750 private/
```

### Recursive changes

`-R` applies the change to a directory and everything inside it:

```
$ chmod -R go-rwx ~/private
```

Be careful with recursive octal modes: `chmod -R 644` would strip the `x` bit from directories, making them unusable. Symbolic mode with `X` (capital X — execute only for directories and files that already have some execute bit) avoids this: `chmod -R u=rwX,go=rX docs/`.

## Changing ownership: `chown` and `chgrp`

Every file belongs to one user and one group. New files belong to the user who created them and (normally) to that user's primary group.

`chown` (change owner) sets the owning user, the owning group, or both. Changing the *user* owner requires root:

```
$ sudo chown emma report.txt          # change the user owner
$ sudo chown emma:developers report.txt  # change user and group at once
$ sudo chown :developers report.txt   # change only the group
$ sudo chown -R emma:emma /home/emma  # recursively, e.g. after restoring a backup
$ ls -l report.txt
-rw-r----- 1 emma developers 4096 Jul  6 10:12 report.txt
```

(A dot also works as the separator: `emma.developers`.)

`chgrp` (change group) changes only the owning group. A regular user may do this without root, but only to a group they belong to:

```
$ groups
carol staff developers
$ chgrp developers report.txt
```

`chgrp` also accepts `-R` for recursive changes. `chown :group` and `chgrp group` are equivalent.

## Special permissions: setuid, setgid, sticky bit

Beyond the nine basic bits there are three special bits, shown in the execute positions of `ls -l` and written as a fourth, leading octal digit (setuid = 4, setgid = 2, sticky = 1).

| Bit | Shown as | On files | On directories |
|---|---|---|---|
| **setuid** (`4---`) | `s` in the user execute slot | Program runs with the *owner's* privileges instead of the caller's | No effect |
| **setgid** (`2---`) | `s` in the group execute slot | Program runs with the owning *group's* privileges | New files inside inherit the directory's group — ideal for shared team directories |
| **sticky** (`1---`) | `t` in the others execute slot | No effect on modern Linux | Only a file's owner (or root) may delete or rename files inside, even if the directory is world-writable |

Classic examples you can inspect on any system:

```
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 59976 Feb  6 2026 /usr/bin/passwd

$ ls -ld /tmp
drwxrwxrwt 22 root root 4096 Jul  7 08:15 /tmp
```

`passwd` is setuid root so that ordinary users can update `/etc/shadow`, which they cannot write directly. `/tmp` is world-writable but sticky, so users cannot delete each other's temporary files.

Setting them:

```
$ chmod u+s program        # setuid           (or chmod 4755 program)
$ chmod g+s shared_dir/    # setgid directory (or chmod 2775 shared_dir/)
$ chmod +t public_drop/    # sticky bit       (or chmod 1777 public_drop/)
```

A lowercase `s`/`t` means the corresponding execute bit is also set; an uppercase `S`/`T` warns that the special bit is set but execute is not.

## Default permissions: `umask`

New files never appear with arbitrary permissions: the shell's **umask** defines which bits are *removed* from the defaults (`666` for files, `777` for directories). With the common umask of `022`:

```
$ umask
0022
$ touch newfile && mkdir newdir
$ ls -ld newfile newdir
-rw-r--r-- 1 carol staff    0 Jul  7 09:00 newfile
drwxr-xr-x 2 carol staff 4096 Jul  7 09:00 newdir
```

Files get `666 − 022 = 644` and directories get `777 − 022 = 755`. A more restrictive `umask 077` yields `600`/`700`, keeping everything private to the owner. Running `umask` with a value changes it for the current shell session.

## Quick reference

| Task | Command |
|---|---|
| Inspect permissions and ownership | `ls -l file` / `ls -ld dir` |
| Set exact permissions (octal) | `chmod 640 file` |
| Adjust specific bits (symbolic) | `chmod g+w,o-r file` |
| Change owner (root only) | `sudo chown user file` |
| Change owner and group | `sudo chown user:group file` |
| Change group only | `chgrp group file` |
| Apply recursively | add `-R` to `chmod`, `chown`, or `chgrp` |
| Show/set default permission mask | `umask` / `umask 077` |

## Key takeaways for the exam

- Decode `ls -l` strings instantly: type + three triplets (user, group, others).
- Convert between symbolic and octal notation in both directions (`rwxr-x--x` ↔ `751`).
- Know the different meaning of `r`, `w`, `x` on files versus directories.
- `chmod` changes permissions; `chown` changes user (and optionally group, root required for user changes); `chgrp` changes group only.
- Recognize setuid (`s`, 4), setgid (`s`, 2), and the sticky bit (`t`, 1), and the canonical examples `/usr/bin/passwd` and `/tmp`.
- `umask` subtracts bits from `666`/`777` to produce default permissions for new files and directories.

## Referencias

- LPI Learning Materials, Lesson 5.3 — Managing File Permissions and Ownership: https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
- LPI Linux Essentials exam objectives (version 1.6): https://www.lpi.org/our-certifications/exam-objectives/linux-essentials-exam-010-objectives/
- GNU Coreutils manual — `chmod`: https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html
- GNU Coreutils manual — `chown`: https://www.gnu.org/software/coreutils/manual/html_node/chown-invocation.html
- GNU Coreutils manual — `chgrp`: https://www.gnu.org/software/coreutils/manual/html_node/chgrp-invocation.html
- Linux man-pages — `chmod(1)`: https://man7.org/linux/man-pages/man1/chmod.1.html
- Linux man-pages — `chown(1)`: https://man7.org/linux/man-pages/man1/chown.1.html
- Bash Reference Manual — `umask` builtin: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html