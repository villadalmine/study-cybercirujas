# Guided Exercises — Topic 5.2: Creating Users and Groups

**Certification:** LPI Linux Essentials (010-160, version 1.6) · **Exam weight:** 2

These exercises are hands-on. Open a terminal on any Linux system (a virtual machine or container is fine — you will create and delete test accounts, so avoid doing this on a production machine). Most steps need administrative rights, so prefix commands with `sudo` where shown. After each block, answer the questions before checking the solutions at the end.

> Reference: LPI Learning Materials, Lesson 5.2 — https://learning.lpi.org/en/learning-materials/010-160/5/5.2/

---

## Exercise 1 — The Three Account Databases

Before creating anything, get familiar with the files where Linux stores accounts, groups, and passwords.

1. Look at one record of the user database:
   ```bash
   grep "^$USER:" /etc/passwd
   ```
   The seven colon-separated fields are: `username : password-placeholder : UID : GID : GECOS/comment : home-directory : shell`.
2. Look at the group database:
   ```bash
   grep -E '^(sudo|wheel|adm):' /etc/group
   ```
   Its four fields are: `groupname : password-placeholder : GID : member-list`.
3. Try to read the password database as a regular user, then with `sudo`:
   ```bash
   cat /etc/shadow
   sudo grep "^$USER:" /etc/shadow
   ```
4. Query the same databases the portable way, with `getent`:
   ```bash
   getent passwd $USER
   getent group sudo
   ```

**Questions**

- **1a.** The second field of your `/etc/passwd` entry is an `x`. What does it mean, and where is the real password stored?
- **1b.** Why does reading `/etc/shadow` fail without `sudo`, while `/etc/passwd` is world-readable?
- **1c.** In `/etc/shadow`, the password field holds a *hash*, not the password itself. Why is that safer?

---

## Exercise 2 — Creating Your First User

The `useradd` command creates accounts. Its behavior is driven by defaults you can inspect.

1. Show the compiled-in defaults:
   ```bash
   useradd -D
   ```
2. Peek at the template directory that seeds every new home directory:
   ```bash
   ls -la /etc/skel
   ```
3. Create a test user with a home directory, a comment, and an explicit shell:
   ```bash
   sudo useradd -m -c "Emma Test Account" -s /bin/bash emma
   ```
4. Verify what was created:
   ```bash
   getent passwd emma
   getent group emma
   sudo ls -la /home/emma
   ```
5. Compare the contents of `/home/emma` with `/etc/skel`.

**Questions**

- **2a.** What does the `-m` option do, and what would have happened without it?
- **2b.** Where did the files inside `/home/emma` (such as `.bashrc`) come from?
- **2c.** On most modern distributions, creating the user `emma` also created a group `emma`. What is this scheme called, and which `/etc/passwd` field points to it?
- **2d.** What UID did `emma` receive? Why did the system pick a number of 1000 or above?

---

## Exercise 3 — Setting and Inspecting Passwords

A freshly created account is locked: it has no valid password yet.

1. Confirm the account has no usable password:
   ```bash
   sudo passwd -S emma
   ```
   (Look for `L` or `LK` — locked — in the output. On some distributions the flag is `P` only after a password is set.)
2. Set a password for `emma` (as administrator you can set anyone's password):
   ```bash
   sudo passwd emma
   ```
3. Check the status again and look at the shadow record:
   ```bash
   sudo passwd -S emma
   sudo grep '^emma:' /etc/shadow
   ```
4. Switch into the new account to prove it works, then return:
   ```bash
   su - emma
   whoami
   exit
   ```

**Questions**

- **3a.** Who can change `emma`'s password: only `root`, only `emma`, or both? What is the difference in what they must provide?
- **3b.** In the `/etc/shadow` entry, the third field is a number like `20641`. What does it represent?
- **3c.** Why is `su - emma` (with the dash) preferable to plain `su emma` for testing an account?

---

## Exercise 4 — Creating Groups and Adding Members

Groups let several users share access to files. A user has exactly one **primary group** and may belong to many **supplementary groups**.

1. Create a shared group for a project:
   ```bash
   sudo groupadd developers
   getent group developers
   ```
2. Add `emma` to it as a supplementary group:
   ```bash
   sudo usermod -aG developers emma
   ```
3. Create a second user directly with that supplementary group:
   ```bash
   sudo useradd -m -G developers -s /bin/bash lucas
   sudo passwd lucas
   ```
4. Verify both memberships:
   ```bash
   id emma
   id lucas
   getent group developers
   ```
5. See the group take effect on a shared file:
   ```bash
   su - emma
   touch ~/notes.txt
   ls -l ~/notes.txt
   exit
   ```

**Questions**

- **4a.** In `sudo usermod -aG developers emma`, what would go wrong if you forgot the `-a`?
- **4b.** In the output of `id emma`, which group appears after `gid=` and which after `groups=`? Which one is stamped on files `emma` creates?
- **4c.** Where is `emma`'s primary group recorded, and where are her supplementary groups recorded?

---

## Exercise 5 — Watching Who Is on the System

Administrators track logins with `who`, `w`, and `last`.

1. See who is logged in right now:
   ```bash
   who
   ```
2. Get the richer view — including what each session is running and the load average:
   ```bash
   w
   ```
3. Review the login history, including your `su` session as `emma` if your system records it:
   ```bash
   last
   last emma
   ```
4. Check the most recent boot entries:
   ```bash
   last reboot
   ```

**Questions**

- **5a.** What information does `w` show that `who` does not?
- **5b.** Which file does `last` read its history from, and why can't you `cat` it meaningfully?
- **5c.** In the output of `last`, what does the phrase `still logged in` indicate?

---

## Exercise 6 — Modifying an Existing Account

Requirements change: accounts get renamed comments, different shells, new homes.

1. Change `emma`'s comment (GECOS) field and shell:
   ```bash
   sudo usermod -c "Emma Dev Lead" -s /bin/sh emma
   getent passwd emma
   ```
2. Lock the account temporarily (for example, while she is on leave):
   ```bash
   sudo usermod -L emma
   sudo passwd -S emma
   sudo grep '^emma:' /etc/shadow
   ```
3. Unlock it again:
   ```bash
   sudo usermod -U emma
   sudo passwd -S emma
   ```

**Questions**

- **6a.** After locking, what changed at the start of the password hash in `/etc/shadow`?
- **6b.** Locking with `usermod -L` blocks password logins. Name one way a locked user could, in principle, still log in — and why full account expiry is stronger.
- **6c.** Which command and option would you use to change a user's *primary* group?

---

## Exercise 7 — Cleaning Up: Deleting Users and Groups

Test accounts should not linger. Removal order matters: a group that is someone's primary group cannot be deleted first.

1. Try to delete the `developers` group while it still has members — observe that supplementary membership does **not** block it, then recreate it to test the real blocker:
   ```bash
   sudo groupdel developers
   ```
2. Now try to delete `emma`'s *primary* group:
   ```bash
   sudo groupdel emma
   ```
   Read the error message carefully.
3. Delete both test users, removing their home directories too:
   ```bash
   sudo userdel -r emma
   sudo userdel -r lucas
   ```
4. Verify nothing is left behind:
   ```bash
   getent passwd emma lucas
   getent group emma lucas developers
   ls /home
   ```

**Questions**

- **7a.** What does the `-r` option of `userdel` remove, and what would remain on disk without it?
- **7b.** Why did step 2 fail while step 1 succeeded?
- **7c.** After `userdel -r emma`, files owned by `emma` might still exist elsewhere (e.g., in `/tmp`). How would `ls -l` display their owner, and why is that a security concern if UID 1001 is later reused?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

- **1a.** The `x` is a placeholder meaning "the password is stored elsewhere" — specifically, its hash lives in `/etc/shadow`. Historically the hash sat in `/etc/passwd` itself, but since that file must be world-readable, hashes were moved to the shadow file.
- **1b.** `/etc/passwd` must be readable by everyone because many programs need to map UIDs to usernames (e.g., `ls -l`). `/etc/shadow` contains password hashes and aging data, so it is readable only by `root` (and often the `shadow` group), preventing offline password-cracking attempts by ordinary users.
- **1c.** A hash is a one-way transformation: the system can verify a typed password by hashing it and comparing, but the original password cannot be directly read back from the hash. Even if the file leaks, attackers must guess passwords rather than read them.

### Exercise 2

- **2a.** `-m` tells `useradd` to create the home directory. Without it (on most distributions) the `/etc/passwd` entry would still point at `/home/emma`, but the directory would not exist, and the first login would fail or land in `/`.
- **2b.** They were copied from `/etc/skel`, the skeleton directory. Anything an administrator places there (shell configuration, a README, default folders) is copied into every new home created with `useradd -m`.
- **2c.** It is the **User Private Group (UPG)** scheme: each user gets a personal group with the same name (and usually the same number). The fourth field of `/etc/passwd` (the GID) points to it as the user's primary group.
- **2d.** Typically `1000`, `1001`, or the next free number ≥ 1000. UIDs below that boundary (below 100 or 500 on some systems) are reserved for `root` (UID 0) and system/service accounts; regular users start at the value set by `UID_MIN` in `/etc/login.defs`, commonly 1000.

### Exercise 3

- **3a.** Both can. `root` (via `sudo passwd emma`) can set it without knowing the old one; `emma` herself can run `passwd` but must first type her current password, and the new one must pass quality checks.
- **3b.** It is the date of the last password change, expressed as the number of days since the Unix epoch (January 1, 1970). The remaining fields use it to compute password aging (minimum/maximum age, warning period, expiry).
- **3c.** The dash makes it a **login shell**: it starts in `emma`'s home directory with `emma`'s own environment (PATH, variables, profile scripts), just like a real login. Without the dash you keep your previous environment, which can hide configuration problems in the new account.

### Exercise 4

- **4a.** Without `-a` (append), `-G` *replaces* the entire supplementary group list. `emma` would end up in `developers` only, silently losing every other supplementary membership she had.
- **4b.** `gid=` shows the primary group (here `emma`, from the UPG scheme); `groups=` lists all memberships, primary plus supplementary (including `developers`). New files are group-owned by the **primary** group — that is why `~/notes.txt` shows group `emma`, not `developers`.
- **4c.** The primary group is the GID field (field 4) of her `/etc/passwd` record. Supplementary memberships are recorded in the member list (field 4) of the relevant lines in `/etc/group`.

### Exercise 5

- **5a.** `w` adds the system uptime and load averages, plus per-session idle time, CPU usage, and the command each user is currently running. `who` only lists username, terminal, login time, and origin.
- **5b.** `last` reads `/var/log/wtmp`, a binary log of logins, logouts, and reboots. Because it is binary, `cat` prints gibberish; you need `last` (or `utmpdump`) to decode it.
- **5c.** That the session in that line has not ended yet — the user logged in and is still connected (or the session was never closed cleanly).

### Exercise 6

- **6a.** `usermod -L` prefixes the hash in `/etc/shadow` with `!` (e.g., `!$6$...`). Since no password can ever hash to a string starting with `!`, password authentication becomes impossible; `passwd -S` reports the account as locked (`L`/`LK`). Unlocking removes the `!`.
- **6b.** Authentication methods that bypass the password — most commonly an SSH key in `~/.ssh/authorized_keys` — still work with a `!`-locked hash. Setting an account expiry date (e.g., `usermod --expiredate 1` or `chage -E`) disables the account for every login method, which is why it is the stronger control.
- **6c.** `usermod -g <group> <user>` (lowercase `-g` sets the primary group; uppercase `-G` manages the supplementary list).

### Exercise 7

- **7a.** `-r` removes the user's home directory (with its contents) and the mail spool. Without it, `/home/emma` would remain on disk, owned by a now-nonexistent UID.
- **7b.** `groupdel developers` succeeded because supplementary membership does not protect a group. `groupdel emma` failed because that group is `emma`'s **primary** group (referenced from `/etc/passwd`); Linux refuses to delete a group that is any user's primary group until the user is deleted or reassigned.
- **7c.** With the account gone, `ls -l` can no longer translate the UID to a name, so it shows the raw number (e.g., `1001`). If a new account is later created and receives that same UID, it instantly becomes the owner of all those leftover files — which is why auditing for orphaned files (`find / -nouser`) after deleting accounts is good practice.

</details>