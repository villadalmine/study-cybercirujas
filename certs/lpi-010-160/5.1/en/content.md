# 5.1 Basic Security and Identifying User Types

**Exam:** LPI Linux Essentials 010-160 (version 1.6) — **Weight: 2**

---

## Overview

Linux is a **multi-user** operating system: several people — and many background services — can use the machine at the same time, each under its own account with its own permissions. The foundation of Linux security is knowing *who* is acting on the system and *what kind* of account they are using. This topic covers:

- The three kinds of accounts: the **root** superuser, **standard users**, and **system users**
- Where account information lives: `/etc/passwd`, `/etc/shadow`, `/etc/group`
- Finding out who you are and who is logged in: `id`, `who`, `w`, `last`
- Switching identities safely: `su` and `sudo`

---

## 1. User Types

### 1.1 The superuser: `root`

The `root` account is the system administrator. It is identified by **UID 0** (User ID zero), not by its name — any account with UID 0 has full power. Root can read, modify, or delete *any* file, install software, manage users, change system configuration, and kill any process. Permissions simply do not apply to it.

That power is exactly why root should **not** be used for everyday work: a single mistyped command run as root (a stray `rm`, an edit to the wrong config file) can break the whole system, and a compromised root session compromises everything. The security best practice is:

> Work as a standard user, and elevate privileges only for the specific commands that need them (`sudo`), or for a short administrative session (`su`).

A quick visual cue: the shell prompt usually ends in `$` for a normal user and `#` for root. Documentation uses the same convention to signal which commands require root.

### 1.2 Standard users (regular users)

Standard users are the accounts real people log in with. Typically they:

- Have a **home directory** of their own, e.g. `/home/carol`
- Have a real **login shell**, e.g. `/bin/bash`
- Get UIDs starting at **1000** on most modern distributions (older Red Hat–style systems started at 500)
- Can only modify their own files and whatever the file permissions allow

### 1.3 System users (service accounts)

System users exist so that **services and daemons** (web servers, databases, printing, logging…) can run *without* root privileges. If the web server is compromised, the attacker gets only the limited rights of the `www-data` user — not the whole machine. This is the **principle of least privilege** in action.

Typical traits of a system user:

- UID in the reserved low range (conventionally **1–999**)
- No usable password and **no interactive login**: the shell field is set to `/usr/sbin/nologin` or `/bin/false`
- Often no real home directory, or one that points at the service's data area (e.g. `/var/www`)

Examples you will see on almost any system: `daemon`, `mail`, `www-data` (Debian/Ubuntu) or `apache` (Red Hat), `sshd`, `nobody`.

### Summary table

| Account type | Typical UID | Login shell | Purpose |
|---|---|---|---|
| `root` | 0 | `/bin/bash` | System administration — unlimited power |
| System users | 1–999 | `/usr/sbin/nologin`, `/bin/false` | Run services with limited privileges |
| Standard users | 1000+ | `/bin/bash` (or other real shell) | Interactive accounts for people |

---

## 2. Where Accounts Are Defined

### 2.1 `/etc/passwd`

Every account — root, system, and standard — has one line in `/etc/passwd`, with **seven colon-separated fields**:

```
$ grep -E '^(root|www-data|carol)' /etc/passwd
root:x:0:0:root:/root:/bin/bash
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
carol:x:1000:1000:Carol Smith:/home/carol:/bin/bash
```

| Field | Example (`carol`) | Meaning |
|---|---|---|
| 1 | `carol` | Username |
| 2 | `x` | Password placeholder (real hash is in `/etc/shadow`) |
| 3 | `1000` | **UID** — numeric user ID |
| 4 | `1000` | **GID** — primary group ID |
| 5 | `Carol Smith` | GECOS: full name / comment |
| 6 | `/home/carol` | Home directory |
| 7 | `/bin/bash` | Login shell |

Despite the name, `/etc/passwd` contains no passwords today, so it is world-readable. Note how the three example lines illustrate the three user types: UID 0, a system UID with `nologin`, and a standard UID 1000 with bash.

### 2.2 `/etc/shadow`

The actual **password hashes** and password-aging information live in `/etc/shadow`, which is readable **only by root**:

```
$ ls -l /etc/shadow
-rw-r----- 1 root shadow 1183 Jul  7 09:14 /etc/shadow
```

Keeping hashes out of the world-readable file prevents ordinary users from copying them and attacking them offline.

### 2.3 `/etc/group`

Groups let permissions be granted to sets of users. Each line in `/etc/group` has four fields — group name, password placeholder, **GID**, and the comma-separated list of members:

```
$ grep sudo /etc/group
sudo:x:27:carol,tux
```

Every user has one **primary group** (field 4 of `/etc/passwd`) and may belong to additional **supplementary groups** listed here.

---

## 3. Identifying Users: `id`, `who`, `w`, `last`

### 3.1 `id` — who am I, exactly?

`id` prints the UID, primary GID, and all group memberships of the current user (or of a user given as an argument):

```
$ id
uid=1000(carol) gid=1000(carol) groups=1000(carol),27(sudo),999(docker)

$ id root
uid=0(root) gid=0(root) groups=0(root)
```

Related shortcuts: `whoami` prints just the effective username — handy for checking whether you are currently root.

### 3.2 `who` — who is logged in?

`who` lists the sessions currently open on the machine: username, terminal, login time, and origin (remote host or display):

```
$ who
carol    tty2         2026-07-07 08:55 (:0)
tux      pts/1        2026-07-07 09:12 (192.168.1.42)
```

Here `carol` is on the local console and `tux` is connected over the network via SSH.

### 3.3 `w` — who is logged in, and what are they doing?

`w` shows the same sessions plus system uptime, load averages, idle time, and the command each session is running:

```
$ w
 09:30:01 up  3:12,  2 users,  load average: 0.15, 0.10, 0.05
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
carol    tty2     :0               08:55    1:02m  0.30s  0.10s /usr/bin/bash
tux      pts/1    192.168.1.42     09:12    0.00s  0.05s  0.01s vim notes.txt
```

### 3.4 `last` — login history

`last` reads the login log (`/var/log/wtmp`) and shows past logins, logouts, and reboots — newest first:

```
$ last
tux      pts/1        192.168.1.42     Mon Jul  7 09:12   still logged in
carol    tty2         :0               Mon Jul  7 08:55   still logged in
reboot   system boot  6.8.0-40-generic Mon Jul  7 06:18   still running
carol    tty2         :0               Sun Jul  6 18:02 - 22:41  (04:39)
```

This is a basic auditing tool: unexpected logins from unknown hosts are a red flag. The companion `lastb` (root only) shows *failed* login attempts, read from `/var/log/btmp`.

---

## 4. Switching Identities: `su` and `sudo`

### 4.1 `su` — substitute user

`su` starts a shell as another user; with no argument, it targets root. You must type the **target user's password** (i.e. root's password for plain `su`):

```
$ su -
Password:
#
```

The `-` (equivalent to `-l` / `--login`) makes it a **login shell**: you get root's full environment and land in `/root`. Prefer `su -` over bare `su`, and type `exit` as soon as the administrative work is done.

### 4.2 `sudo` — run one command with elevated privileges

`sudo` runs a single command as root (or another user), asking for **your own password** and checking that you are authorized:

```
$ sudo apt update
[sudo] password for carol:
...
```

Authorization is defined in `/etc/sudoers`, which must be edited only with `visudo` (it validates syntax before saving, so you can't lock yourself out with a typo). On most distributions, membership in a group grants full sudo rights: group `sudo` on Debian/Ubuntu, group `wheel` on Red Hat/Fedora.

Why `sudo` is generally preferred over `su`:

- The root password never needs to be shared (on Ubuntu the root account is locked by default and `sudo` is the only path to root).
- Each elevated command is **logged** with the invoking user's name — an audit trail.
- Privileges last for one command (or a short cached period), not a whole session, reducing the window for mistakes.

If you really need an interactive root shell through sudo: `sudo -i`.

### 4.3 `su` vs `sudo` at a glance

| | `su -` | `sudo command` |
|---|---|---|
| Password requested | Target user's (root's) | Your own |
| Scope | Full interactive session | One command |
| Configuration | None (just the password) | `/etc/sudoers` via `visudo` |
| Audit trail | Session start only | Every command logged |

---

## 5. Key Points for the Exam

- **root = UID 0**; the UID, not the name, is what grants the power.
- **System users** (UID 1–999) run services, have `nologin`/`false` as shell, and exist to apply **least privilege**.
- **Standard users** normally start at UID 1000 and have a home directory and a real shell.
- `/etc/passwd` (7 fields, world-readable, no real passwords) vs `/etc/shadow` (hashes, root-only) vs `/etc/group` (group memberships).
- `id` → my UID/GID/groups; `who` → current logins; `w` → current logins + activity + load; `last` → login history.
- `su -` asks for **root's** password and opens a root session; `sudo` asks for **your** password, runs one command, is configured in `/etc/sudoers` (edit with `visudo`), and logs everything.
- Prompt convention: `$` = normal user, `#` = root.

---

## Referencias

- LPI Learning Materials, Topic 5.1 "Basic Security and Identifying User Types": https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
- LPI Linux Essentials Objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- `id`: https://man7.org/linux/man-pages/man1/id.1.html
- `who`: https://man7.org/linux/man-pages/man1/who.1.html
- `w`: https://man7.org/linux/man-pages/man1/w.1.html
- `last`, `lastb`: https://man7.org/linux/man-pages/man1/last.1.html
- `su`: https://man7.org/linux/man-pages/man1/su.1.html
- `sudo`: https://www.sudo.ws/docs/man/sudo.man/
- `sudoers` / `visudo`: https://www.sudo.ws/docs/man/sudoers.man/
- `passwd(5)`: https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)`: https://man7.org/linux/man-pages/man5/shadow.5.html
- `group(5)`: https://man7.org/linux/man-pages/man5/group.5.html