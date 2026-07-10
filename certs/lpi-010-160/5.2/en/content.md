# 5.2 Creating Users and Groups

**Exam weight: 2** — Linux Essentials 010-160, version 1.6

## Why users and groups matter

Linux is a multi-user operating system: several people (and many system services) can use the same machine, each with their own identity, files, and permissions. Every action on the system is performed *as* some user, and every user belongs to at least one group. Understanding how accounts are defined, where they are stored, and how to create them is the foundation for the permissions model covered in the rest of Topic 5.

## Types of user accounts

Linux systems distinguish three kinds of accounts:

| Account type | Typical UID range | Purpose |
|---|---|---|
| **root** (superuser) | 0 | Unlimited administrative access to the whole system |
| **System accounts** | 1–999 | Used by services/daemons (e.g. `www-data`, `sshd`); usually cannot log in interactively |
| **Regular users** | 1000+ | Human users with a home directory and a login shell |

- Every user has a numeric **UID** (User ID). The name is just a label; the kernel works with numbers.
- Every group has a numeric **GID** (Group ID).
- Each user has one **primary group** (recorded with the account) and may belong to any number of **supplementary groups** (used to grant extra access, e.g. membership in `sudo` or `wheel` for administrative rights).

The UID boundary between system and regular users can vary by distribution (some older systems start regular users at 500), but 1000 is the common modern default, defined in `/etc/login.defs`.

## Identifying who you are

The `id` command shows the current user's UID, primary GID, and all group memberships:

```
$ id
uid=1000(carol) gid=1000(carol) groups=1000(carol),27(sudo),998(docker)
```

You can also query another account: `id emma`.

Related commands worth knowing for the exam:

- `who` — lists users currently logged in.
- `w` — like `who`, but also shows what each session is doing.
- `last` — shows the history of logins and reboots, read from `/var/log/wtmp`:

```
$ last -n 3
carol    pts/0        192.168.1.20     Mon Jul  6 09:12   still logged in
emma     tty2         :0               Sun Jul  5 18:40 - 19:55  (01:15)
reboot   system boot  5.15.0-91        Sun Jul  5 18:38   still running
```

## Where account information lives

### /etc/passwd

One line per user, seven colon-separated fields. Despite its name, it no longer stores passwords.

```
$ grep carol /etc/passwd
carol:x:1000:1000:Carol Jones:/home/carol:/bin/bash
```

The fields, left to right:

1. **Username** — `carol`
2. **Password placeholder** — `x` means the real password hash is in `/etc/shadow`
3. **UID** — `1000`
4. **GID** of the primary group — `1000`
5. **GECOS** — free-text comment, usually the full name
6. **Home directory** — `/home/carol`
7. **Login shell** — `/bin/bash` (system accounts often use `/usr/sbin/nologin` or `/bin/false` to prevent logins)

`/etc/passwd` is world-readable, which is exactly why password hashes were moved out of it.

### /etc/shadow

Holds the hashed passwords and password-aging policy. Readable only by root:

```
$ sudo grep carol /etc/shadow
carol:$6$W3q9...hashed...:20456:0:99999:7:::
```

Key fields: username, password hash, date of last password change (in days since 1970-01-01), minimum/maximum password age, and warning period. A `!` or `*` in the hash field means the account cannot log in with a password (locked, or a system account).

### /etc/group

One line per group, four fields: group name, password placeholder, GID, and a comma-separated list of members (supplementary membership — the primary group is recorded in `/etc/passwd`):

```
$ grep sudo /etc/group
sudo:x:27:carol,emma
```

You can inspect these databases with `getent`, which also works when accounts come from a network directory:

```
$ getent passwd carol
carol:x:1000:1000:Carol Jones:/home/carol:/bin/bash
```

## Creating users: useradd

Account management requires root privileges, so the commands below are run with `sudo`. The low-level, universally available tool is `useradd`:

```
$ sudo useradd -m -c "Dave Lee" -s /bin/bash dave
```

Common options:

- `-m` — create the home directory (copying the skeleton files from `/etc/skel`, e.g. default `.bashrc`)
- `-c` — comment (GECOS field, usually the full name)
- `-s` — login shell
- `-d` — specify a non-default home directory
- `-g` — primary group; `-G` — comma-separated supplementary groups
- `-u` — choose a specific UID

A brand-new account has no valid password yet, so set one with `passwd`:

```
$ sudo passwd dave
New password:
Retype new password:
passwd: password updated successfully
```

Regular users can run `passwd` with no arguments to change *their own* password; only root can change someone else's.

Verify the result:

```
$ id dave
uid=1001(dave) gid=1001(dave) groups=1001(dave)
$ ls /home
carol  dave
```

Many Debian-based systems also ship `adduser`, a friendlier interactive front end to `useradd` that prompts for the password and details in one step. For the exam, know that `useradd` is the standard tool.

## Creating groups: groupadd

```
$ sudo groupadd developers
$ grep developers /etc/group
developers:x:1002:
```

Use `-g` to pick a specific GID. To add an existing user to the group as a supplementary member, use `usermod -aG`:

```
$ sudo usermod -aG developers dave
$ id dave
uid=1001(dave) gid=1001(dave) groups=1001(dave),1002(developers)
```

**Careful:** the `-a` (append) flag matters. `usermod -G developers dave` *replaces* all of Dave's supplementary groups with just `developers`; `-aG` adds to them. A user must log out and back in for new group memberships to take effect.

## Modifying and deleting accounts

- `usermod` — change an existing account: `-s` new shell, `-d` new home (`-m` to move contents), `-L`/`-U` lock/unlock the account.
- `userdel dave` — remove the account; add `-r` to also delete the home directory and mail spool.
- `groupmod` — rename a group (`-n`) or change its GID (`-g`).
- `groupdel developers` — remove a group (only if it is no one's primary group).

```
$ sudo userdel -r dave
$ sudo groupdel developers
```

## Key takeaways

- root is UID 0; system accounts sit below the regular-user range, which usually starts at UID 1000.
- Users are defined in `/etc/passwd`, password hashes in `/etc/shadow` (root-only), groups in `/etc/group`.
- `useradd -m` creates a user with a home directory; `passwd` sets the password; `groupadd` creates groups; `usermod -aG` adds supplementary group membership.
- `id`, `who`, `w`, and `last` tell you who you are and who has been on the system.

## Referencias

- LPI Learning Materials, Linux Essentials 5.2 — Creating Users and Groups: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
- LPI Linux Essentials exam objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- `useradd(8)` man page: https://man7.org/linux/man-pages/man8/useradd.8.html
- `groupadd(8)` man page: https://man7.org/linux/man-pages/man8/groupadd.8.html
- `usermod(8)` man page: https://man7.org/linux/man-pages/man8/usermod.8.html
- `passwd(5)` man page (format of /etc/passwd): https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)` man page (format of /etc/shadow): https://man7.org/linux/man-pages/man5/shadow.5.html
- `group(5)` man page (format of /etc/group): https://man7.org/linux/man-pages/man5/group.5.html