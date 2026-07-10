# Guided Exercises — Topic 5.1: Basic Security and Identifying User Types

**Certification:** LPI Linux Essentials (010-160, version 1.6) · **Exam weight:** 2

These exercises are hands-on. Open a terminal on any Linux system (a virtual machine or container is fine) and follow the numbered steps. After each block, answer the questions before checking the solutions at the end.

> Reference: LPI Learning Materials, Lesson 5.1 — https://learning.lpi.org/en/learning-materials/010-160/5/5.1/

---

## Exercise 1 — Discovering Your Own Identity

Every process you run in Linux acts on behalf of a user account, identified internally by a number: the **UID** (User ID).

1. Print your login name:
   ```bash
   whoami
   ```
2. Now get the full picture — UID, GID, and all group memberships:
   ```bash
   id
   ```
3. Compare with the identity of the superuser (you can query any account by name):
   ```bash
   id root
   ```
4. Ask only for specific fields:
   ```bash
   id -u        # numeric UID
   id -un       # UID as a name
   id -g        # primary group ID
   id -Gn       # all group names
   ```

**Questions**

- **1a.** What UID does `root` have, and why is that number special?
- **1b.** In the output of `id`, what is the difference between `gid=` and `groups=`?
- **1c.** If two accounts somehow shared the same UID, how would the kernel treat them?

---

## Exercise 2 — User Types in `/etc/passwd`

The file `/etc/passwd` lists every account on the system — not just humans. Linux distinguishes three broad user types: the **superuser** (`root`), **system users** (service accounts for daemons), and **regular users**.

1. Display the whole account database (it is world-readable):
   ```bash
   cat /etc/passwd
   ```
2. Look at a single record and count its fields:
   ```bash
   grep '^root:' /etc/passwd
   ```
   The seven colon-separated fields are: `username : password-placeholder : UID : GID : GECOS/comment : home-directory : shell`.
3. List only system accounts (on most distributions these have UIDs below 1000):
   ```bash
   awk -F: '$3 < 1000 {print $1, $3, $7}' /etc/passwd
   ```
4. Now list regular users:
   ```bash
   awk -F: '$3 >= 1000 {print $1, $3, $7}' /etc/passwd
   ```
5. Notice the login shells of system accounts:
   ```bash
   grep -E '(nologin|false)' /etc/passwd | head
   ```

**Questions**

- **2a.** Why does the second field of every line show `x` instead of a password?
- **2b.** What is the purpose of giving a service account like `daemon` or `www-data` a shell of `/usr/sbin/nologin` or `/bin/false`?
- **2c.** Why do daemons such as a web server run as system users instead of as `root`?
- **2d.** Which field tells you where a user lands in the filesystem right after logging in?

---

## Exercise 3 — Groups and `/etc/group`

Groups let administrators grant permissions to many users at once. Every user has one **primary group** (stored in `/etc/passwd`) and may belong to additional **supplementary groups**.

1. Show the groups you belong to:
   ```bash
   groups
   ```
2. Inspect the group database:
   ```bash
   cat /etc/group | head -20
   ```
   Fields: `group-name : password-placeholder : GID : member-list`.
3. Find which users are members of a specific group (try `sudo`, `wheel`, or `adm` depending on your distribution):
   ```bash
   grep -E '^(sudo|wheel|adm):' /etc/group
   ```
4. Cross-check: confirm your primary group by matching your GID from `id -g` against `/etc/group`:
   ```bash
   getent group "$(id -g)"
   ```

**Questions**

- **3a.** Where is a user's *primary* group defined, and where are *supplementary* group memberships defined?
- **3b.** On many distributions, membership in the `sudo` (Debian/Ubuntu) or `wheel` (Fedora/CentOS) group has a special effect. What is it?
- **3c.** Why might your username not appear in the member list of your own primary group in `/etc/group`?

---

## Exercise 4 — Who Is on the System, Now and Before

Auditing logins is a basic security task. Three classic commands answer "who is here?" and "who was here?".

1. See who is currently logged in:
   ```bash
   who
   ```
2. Get a richer view — including what each logged-in user is doing and the load average:
   ```bash
   w
   ```
3. Review the login history (read from `/var/log/wtmp`):
   ```bash
   last
   ```
4. Narrow the history to one account and to system reboots:
   ```bash
   last $USER
   last reboot
   ```
5. If available, check *failed* login attempts (usually requires root):
   ```bash
   sudo lastb | head
   ```

**Questions**

- **4a.** What information does `w` show that `who` does not?
- **4b.** Which log files back the `last` and `lastb` commands?
- **4c.** In the output of `last`, what does the phrase `still logged in` mean, and why is a long list of entries in `lastb` for the `root` account a warning sign?

---

## Exercise 5 — Becoming Someone Else: `su` and `sudo`

Doing daily work as `root` is dangerous: one typo can destroy the system, and there is no audit trail of *who* did what. The recommended practice is to work as a regular user and escalate privileges only when needed.

1. Run a single privileged command with `sudo` (you will be asked for **your own** password):
   ```bash
   sudo cat /etc/shadow | head -3
   ```
2. Check what you are allowed to do via sudo:
   ```bash
   sudo -l
   ```
3. Compare with `su`, which starts a shell as another user and asks for the **target user's** password (press `Ctrl+D` or type `exit` to leave):
   ```bash
   su -
   ```
   (If root has no password set — common on Ubuntu — this will fail; that is expected and instructive.)
4. Note the difference the `-` makes: `su -` gives a full *login shell* with root's environment, while plain `su` keeps your current environment.
5. Verify who you are before and after escalating:
   ```bash
   whoami; sudo whoami
   ```

**Questions**

- **5a.** Whose password does `sudo` ask for, and whose does `su` ask for? Why does the `sudo` model scale better in a team of administrators?
- **5b.** Name two security advantages of `sudo` over logging in directly as `root`.
- **5c.** What is the difference between `su` and `su -`?
- **5d.** Which file defines who may use `sudo` and for which commands, and which command should be used to edit it safely?

---

## Exercise 6 — Where Passwords Really Live: `/etc/shadow`

Passwords were moved out of `/etc/passwd` precisely because that file must stay world-readable. The hashes now live in `/etc/shadow`, readable only by root.

1. Try to read the shadow file as a regular user and observe the result:
   ```bash
   cat /etc/shadow
   ```
2. Compare the permissions of the two files:
   ```bash
   ls -l /etc/passwd /etc/shadow
   ```
3. Now read one shadow entry with elevated privileges:
   ```bash
   sudo grep "^$USER:" /etc/shadow
   ```
   Fields include: username, password hash, date of last password change, minimum/maximum password age, and warning period.
4. Look at the second field of a few system accounts:
   ```bash
   sudo awk -F: '$2 == "*" || $2 == "!" {print $1, $2}' /etc/shadow | head
   ```

**Questions**

- **6a.** Why is it a security problem to store password hashes in a world-readable file, even though a hash is not the password itself?
- **6b.** What do `*` or `!` in the password field of `/etc/shadow` mean?
- **6c.** What are the typical permissions of `/etc/passwd` versus `/etc/shadow`, and why do they differ?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

- **1a.** `root` has UID **0**. The kernel grants unrestricted privileges to UID 0 — it bypasses normal file-permission checks entirely. It is the number, not the name, that matters.
- **1b.** `gid=` shows the **primary group**, the one assigned to files the user creates by default. `groups=` lists **all** groups the user belongs to, including the primary one and every supplementary group.
- **1c.** The kernel identifies users only by UID, so two account names with the same UID are the same user as far as permissions are concerned: each could read, modify, and delete the other's files. A second UID-0 account is a classic backdoor indicator.

### Exercise 2

- **2a.** The `x` is a placeholder meaning the real password hash is stored in `/etc/shadow`. Since `/etc/passwd` must remain readable by everyone (many programs need to map UIDs to names), hashes were moved to a root-only file.
- **2b.** A shell of `/usr/sbin/nologin` or `/bin/false` prevents anyone from opening an interactive session as that account. Service accounts exist to own processes and files, not to log in — this shrinks the attack surface.
- **2c.** Running daemons under dedicated system users applies the **principle of least privilege**: if the service is compromised, the attacker only gains that account's limited rights, not full control of the system.
- **2d.** The sixth field — the **home directory**.

### Exercise 3

- **3a.** The primary group is the GID in the fourth field of the user's `/etc/passwd` entry. Supplementary memberships are recorded in the member list (fourth field) of `/etc/group`.
- **3b.** Members of `sudo` (Debian/Ubuntu) or `wheel` (Fedora/CentOS/openSUSE) are allowed to execute commands as root through `sudo`, per the default rules in `/etc/sudoers`.
- **3c.** The member list in `/etc/group` only needs to list *supplementary* members. Your primary membership is already established via `/etc/passwd`, so listing you again would be redundant.

### Exercise 4

- **4a.** `w` adds the system uptime and load averages, plus each session's idle time, CPU usage, and the command the user is currently running. `who` only shows the user, terminal, login time, and origin.
- **4b.** `last` reads `/var/log/wtmp` (successful logins, logouts, reboots); `lastb` reads `/var/log/btmp` (failed login attempts).
- **4c.** `still logged in` means that session has not ended yet. Many `lastb` entries for `root` suggest a brute-force attack: someone is repeatedly guessing the root password, so you should review remote-access policy (e.g., disable root SSH login).

### Exercise 5

- **5a.** `sudo` asks for the **invoking user's own** password; `su` asks for the **target account's** password (root's, by default). With `sudo`, the root password never needs to be shared: each admin authenticates as themselves, can be granted only specific commands, and can be revoked individually.
- **5b.** Any two of: every command is **logged** with the invoking user's identity (audit trail); privileges are granted **per command** rather than all-or-nothing; the root password need not be shared or even exist; privileges apply only to the one command instead of an entire root session, limiting damage from mistakes.
- **5c.** Plain `su` switches user but keeps the caller's environment and working directory. `su -` (equivalent to `su -l`) starts a full **login shell**: it loads the target user's environment, `PATH`, and home directory, as if they had logged in directly. For root work, `su -` is preferred because it gets root's correct `PATH` (including `/sbin` directories).
- **5d.** `/etc/sudoers` (plus drop-in files in `/etc/sudoers.d/`). It should be edited with `visudo`, which locks the file and checks the syntax before saving — a syntax error in `sudoers` could lock everyone out of privilege escalation.

### Exercise 6

- **6a.** With the hashes readable, any local user can copy them and run an offline **password-cracking** attack (dictionary or brute force) at unlimited speed, with no lockouts or logging. Weak passwords fall quickly. Restricting the file to root removes that avenue.
- **6b.** `*` or `!` means the account has **no usable password**: password login is disabled (locked). This is normal for system/service accounts, which are never meant to authenticate interactively with a password.
- **6c.** `/etc/passwd` is typically `-rw-r--r--` (644) — readable by all, because tools need to resolve UIDs and usernames. `/etc/shadow` is typically `-rw-r-----` root:shadow (640) or even `000`/`-r--------` on some systems — no access for regular users, because it holds the password hashes.

</details>