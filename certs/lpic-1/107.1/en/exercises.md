# LPIC-1 · Topic 107.1 — Manage user and group accounts and related system files
## Guided Exercises (101-500 / 102-500, version 5.0)

> **Run this on a throwaway system.** Every step below edits the real account databases. Use a VM snapshot you can roll back, or a disposable container:
> ```
> docker run --rm -it --name lpic107 debian:12 bash
> ```
> All commands assume you are `root`. Where a distribution difference matters it is called out inline (Debian/Ubuntu vs. RHEL/Fedora/SUSE).

---

## Exercise 0 — Safety net and baseline

**Steps**

1. Confirm your privilege level and the distribution you are on:
   ```bash
   id -u
   cat /etc/os-release | head -2
   ```
   ```
   0
   PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
   NAME="Debian GNU/Linux"
   ```

2. Back up the four account databases *preserving mode, owner and timestamps*:
   ```bash
   mkdir -p /root/acct-backup
   cp -a /etc/passwd /etc/shadow /etc/group /etc/gshadow /root/acct-backup/
   ```

3. Inspect the permissions of the originals:
   ```bash
   ls -l /etc/passwd /etc/shadow /etc/group /etc/gshadow
   ```
   ```
   -rw-r--r-- 1 root root   1042 Aug 27 09:12 /etc/passwd
   -rw-r----- 1 root shadow  621 Aug 27 09:12 /etc/shadow
   -rw-r--r-- 1 root root    527 Aug 27 09:12 /etc/group
   -rw-r----- 1 root shadow  447 Aug 27 09:12 /etc/gshadow
   ```

4. Record today's "days since the Epoch" — the unit `/etc/shadow` uses for every date field:
   ```bash
   echo $(( $(date +%s) / 86400 ))
   date -u -d "1970-01-01 UTC +$(( $(date +%s) / 86400 )) days" +%F
   ```
   ```
   20692
   2026-08-27
   ```

**Questions**

- **Q1.** Why `cp -a` instead of a plain `cp` when backing up these four files?
- **Q2.** Two of the four files are world-readable and two are not. What is the security reason for that split, and what is the historical name of the mechanism that produced it?
- **Q3.** `/etc/shadow` is mode `0640` owned by `root:shadow`. Which program needs to read it as a non-root user, and how does it manage to?

---

## Exercise 1 — Anatomy of the four databases

**Steps**

1. Split the `root` line of `/etc/passwd` into its seven fields:
   ```bash
   getent passwd root | awk -F: '{printf "1 login=%s\n2 passwd=%s\n3 uid=%s\n4 gid=%s\n5 gecos=%s\n6 home=%s\n7 shell=%s\n",$1,$2,$3,$4,$5,$6,$7}'
   ```
   ```
   1 login=root
   2 passwd=x
   3 uid=0
   4 gid=0
   5 gecos=root
   6 home=/root
   7 shell=/bin/bash
   ```

2. Now the nine fields of the matching `/etc/shadow` line:
   ```bash
   getent shadow root | awk -F: '{printf "1 login=%s\n2 hash=%.16s...\n3 lastchg=%s\n4 min=%s\n5 max=%s\n6 warn=%s\n7 inactive=%s\n8 expire=%s\n9 reserved=%s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9}'
   ```
   ```
   1 login=root
   2 hash=$y$j9T$e8Kq3Vt2...
   3 lastchg=20441
   4 min=0
   5 max=99999
   6 warn=7
   7 inactive=
   8 expire=
   9 reserved=
   ```

3. Identify the hashing scheme from the `$id$` prefix:
   ```bash
   getent shadow root | cut -d: -f2 | cut -d'$' -f2
   grep -E '^ENCRYPT_METHOD' /etc/login.defs
   ```
   ```
   y
   ENCRYPT_METHOD YESCRYPT
   ```
   Reference table: `$1$` MD5 · `$2b$` bcrypt · `$5$` SHA-256 · `$6$` SHA-512 · `$y$` yescrypt · `$7$` scrypt.

4. Look at accounts that can never authenticate with a password, and at the group databases:
   ```bash
   awk -F: '$2=="*" {print $1}' /etc/shadow | head -5
   getent group sudo
   getent gshadow sudo
   ```
   ```
   daemon
   bin
   sys
   sync
   games
   sudo:x:27:
   sudo:*::
   ```

5. Prove the difference between a *primary* group and a *supplementary* group membership:
   ```bash
   getent passwd root | cut -d: -f4      # primary GID of root
   getent group root                     # is root listed as a member of group root?
   id root
   ```
   ```
   0
   root:x:0:
   uid=0(root) gid=0(root) groups=0(root)
   ```

**Questions**

- **Q4.** Field 2 of `/etc/passwd` contains `x`. What does that mean, and what happens if you replace it with an empty string?
- **Q5.** In field 2 of `/etc/shadow`, distinguish `*`, `!`, `!!`, `!$y$j9T$...`, and an **empty** field. Which of these still allows a password login?
- **Q6.** `getent group root` shows an empty member list, yet `id root` reports `groups=0(root)`. Explain the apparent contradiction.
- **Q7.** What does field 3 of `/etc/gshadow` hold, and which command writes it?
- **Q8.** `root`'s `lastchg` is `20441`. Convert it to a calendar date with a single command, and say what a value of `0` in that field would mean.

---

## Exercise 2 — Defaults consulted *before* an account exists

**Steps**

1. Read the site-wide policy file:
   ```bash
   grep -E '^(UID_MIN|UID_MAX|GID_MIN|GID_MAX|SYS_UID_MIN|SYS_UID_MAX|PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|CREATE_HOME|USERGROUPS_ENAB|UMASK|ENCRYPT_METHOD)' /etc/login.defs
   ```
   ```
   PASS_MAX_DAYS	99999
   PASS_MIN_DAYS	0
   PASS_WARN_AGE	7
   UID_MIN			 1000
   UID_MAX			60000
   SYS_UID_MIN		  100
   SYS_UID_MAX		  999
   GID_MIN			 1000
   GID_MAX			60000
   UMASK			022
   ENCRYPT_METHOD YESCRYPT
   USERGROUPS_ENAB yes
   ```

2. Read the `useradd`-specific defaults — note this is a **different file**, and it has a CLI front end:
   ```bash
   useradd -D
   cat /etc/default/useradd
   ```
   ```
   GROUP=100
   HOME=/home
   INACTIVE=-1
   EXPIRE=
   SHELL=/bin/sh
   SKEL=/etc/skel
   CREATE_MAIL_SPOOL=no
   ```

3. Change one default through the tool rather than the editor, then verify it landed in the file:
   ```bash
   useradd -D -s /bin/bash
   grep ^SHELL /etc/default/useradd
   ```
   ```
   SHELL=/bin/bash
   ```

4. Inspect the home-directory template and add a marker to it:
   ```bash
   ls -A /etc/skel
   echo '# managed by platform team' >> /etc/skel/.bashrc
   install -d -m 0700 /etc/skel/.ssh
   ```
   ```
   .bash_logout  .bashrc  .profile
   ```

**Questions**

- **Q9.** `UID_MIN` lives in `/etc/login.defs`, `HOME` lives in `/etc/default/useradd`. What is the conceptual division of labour between the two files?
- **Q10.** On Debian, `useradd bob` (no options) does **not** create `/home/bob`; on RHEL it does. Which setting explains it, and which single option makes the behaviour deterministic on both?
- **Q11.** `USERGROUPS_ENAB yes` is set. Describe its two distinct effects — one at creation time, one at deletion time.
- **Q12.** You add `/etc/skel/.ssh` *after* creating a user. Does that user get the directory? Which `useradd` option overrides the skeleton source for one invocation?

---

## Exercise 3 — Creating human and service accounts

**Steps**

1. Create a regular, interactive account explicitly — never rely on defaults in production:
   ```bash
   useradd -m -c "Ana Nova,SRE,,," -s /bin/bash ana
   id ana
   ls -ld /home/ana
   ```
   ```
   uid=1000(ana) gid=1000(ana) groups=1000(ana)
   drwx------ 2 ana ana 4096 Aug 27 09:20 /home/ana
   ```
   *(UID/GID may differ if your system already has regular users.)*

2. Inspect what the three databases now hold for `ana`:
   ```bash
   getent passwd ana; getent shadow ana; getent group ana
   ```
   ```
   ana:x:1000:1000:Ana Nova,SRE,,,:/home/ana:/bin/bash
   ana:!:20692:0:99999:7:::
   ana:x:1000:
   ```

3. Set a password non-interactively and re-read the shadow entry:
   ```bash
   echo 'ana:Str0ng-Transit!' | chpasswd
   getent shadow ana | cut -c1-40
   passwd -S ana
   ```
   ```
   ana:$y$j9T$Rk1pZ8QmA2Vn7Hs0kX...
   ana P 08/27/2026 0 99999 7 -1
   ```

4. Create a **system** account for a daemon — no login shell, no home, no aging:
   ```bash
   useradd -r -s /usr/sbin/nologin -d /var/lib/metrics -M svc_metrics
   install -d -o svc_metrics -g svc_metrics -m 0750 /var/lib/metrics
   getent passwd svc_metrics
   passwd -S svc_metrics
   ```
   ```
   svc_metrics:x:999:999::/var/lib/metrics:/usr/sbin/nologin
   svc_metrics L 08/27/2026 0 99999 7 -1
   ```

5. Attempt an interactive switch to the service account:
   ```bash
   su -s /usr/sbin/nologin - svc_metrics
   ```
   ```
   This account is currently not available.
   ```

**Questions**

- **Q13.** `useradd -r` chose UID `999` while `ana` got `1000`. Which two `login.defs` variables produced each number, and in which direction does `useradd` search each range?
- **Q14.** A colleague runs `useradd -p 'Str0ng-Transit!' bob` and the account cannot log in. What is wrong, and what is the correct way to use `-p`?
- **Q15.** `ana`'s shadow field 2 was `!` immediately after `useradd` (`!!` on RHEL). Was the account *locked*, or something else? What is the practical difference?
- **Q16.** Name two operational drawbacks of `echo 'user:pass' | chpasswd` on a shared administrative host.
- **Q17.** Setting the shell to `/usr/sbin/nologin` blocks `su` and `ssh` shell sessions. Name one access path it does **not** block by itself.

---

## Exercise 4 — Groups, primary vs. supplementary

**Steps**

1. Create two groups — one ordinary, one system:
   ```bash
   groupadd ops
   groupadd -r -g 940 deployers
   getent group ops deployers
   ```
   ```
   ops:x:1001:
   deployers:x:940:
   ```

2. Add `ana` to both, **appending**:
   ```bash
   usermod -aG ops,deployers ana
   id ana
   getent group ops
   ```
   ```
   uid=1000(ana) gid=1000(ana) groups=1000(ana),940(deployers),1001(ops)
   ops:x:1001:ana
   ```

3. Observe that a running session does not pick this up:
   ```bash
   su - ana -c 'id -nG'
   ```
   ```
   ana deployers ops
   ```
   ```bash
   # inside an already-open session of ana, `id -nG` would still print only: ana
   ```

4. Use the group-administration tool (`gpasswd`) — the canonical way to delegate membership:
   ```bash
   useradd -m -s /bin/bash carla
   gpasswd -a carla ops
   gpasswd -A ana ops          # make ana the group administrator
   getent group ops
   getent gshadow ops
   ```
   ```
   Adding user carla to group ops
   ops:x:1001:ana,carla
   ops:!:ana:ana,carla
   ```

5. Switch primary group for a single command and for a whole shell:
   ```bash
   su - carla -c 'id -gn'
   su - carla -c 'sg ops -c "id -gn"'
   su - carla -c 'umask; touch /tmp/f1; ls -l /tmp/f1'
   ```
   ```
   carla
   ops
   0022
   -rw-r--r-- 1 carla carla 0 Aug 27 09:31 /tmp/f1
   ```

6. Rename a group and watch what does — and does not — follow:
   ```bash
   groupmod -n platform ops
   getent group platform
   id ana
   ```
   ```
   platform:x:1001:ana,carla
   uid=1000(ana) gid=1000(ana) groups=1000(ana),940(deployers),1001(platform)
   ```

**Questions**

- **Q18.** What exactly does `usermod -G ops ana` do that `usermod -aG ops ana` does not? Describe the failure it causes in production.
- **Q19.** `groupmod -n platform ops` updated `id ana` instantly, with no `usermod` run. Why? What does this tell you about how memberships are stored?
- **Q20.** Compare `newgrp platform` and `sg platform -c "cmd"`. When does either prompt for a password, and where is that password stored?
- **Q21.** Give the two commands that remove `carla` from `platform`, and explain why one of them is dangerous.
- **Q22.** `getent gshadow platform` shows `ops:!:ana:ana,carla` fields. Which field makes `ana` able to run `gpasswd -a` on that group without being root?

---

## Exercise 5 — Password aging, locking and expiry

**Steps**

1. Read the full aging record:
   ```bash
   chage -l ana
   ```
   ```
   Last password change					: Aug 27, 2026
   Password expires					: never
   Password inactive					: never
   Account expires						: never
   Minimum number of days between password change		: 0
   Maximum number of days between password change		: 99999
   Number of days of warning before password expires	: 7
   ```

2. Apply a real policy — 90-day rotation, 1-day minimum, 14-day warning, 7-day grace after expiry:
   ```bash
   chage -m 1 -M 90 -W 14 -I 7 ana
   getent shadow ana | awk -F: '{print "lastchg="$3" min="$4" max="$5" warn="$6" inactive="$7" expire="$8}'
   ```
   ```
   lastchg=20692 min=1 max=90 warn=14 inactive=7 expire=
   ```

3. Force a change at next login, and confirm the wire-level representation:
   ```bash
   chage -d 0 ana
   getent shadow ana | cut -d: -f3
   chage -l ana | head -2
   ```
   ```
   0
   Last password change					: password must be changed
   Password expires					: password must be changed
   ```

4. Set a hard account expiry date (contractor off-boarding), then read it back:
   ```bash
   chage -E 2026-09-30 ana
   getent shadow ana | cut -d: -f8
   chage -l ana | grep 'Account expires'
   ```
   ```
   20726
   Account expires						: Sep 30, 2026
   ```

5. Lock and unlock the *password*, watching the hash field:
   ```bash
   getent shadow carla | cut -c1-14
   passwd -l carla ;   getent shadow carla | cut -c1-15 ; passwd -S carla
   passwd -u carla ;   getent shadow carla | cut -c1-14 ; passwd -S carla
   ```
   ```
   carla:$y$j9T$
   passwd: password expired changed.
   carla:!$y$j9T$
   carla L 08/27/2026 0 99999 7 -1
   passwd: password expired changed.
   carla:$y$j9T$
   carla P 08/27/2026 0 99999 7 -1
   ```

6. Compare with the account-level lock:
   ```bash
   usermod -L carla && passwd -S carla
   usermod -e 1 carla && chage -l carla | grep 'Account expires'
   usermod -U carla; usermod -e '' carla
   ```
   ```
   carla L 08/27/2026 0 99999 7 -1
   Account expires						: Jan 02, 1970
   ```

7. Restore `ana` to a sane state:
   ```bash
   chage -d $(( $(date +%s) / 86400 )) -E -1 ana
   chage -l ana | grep -E 'Last password|Account expires'
   ```
   ```
   Last password change					: Aug 27, 2026
   Account expires						: never
   ```

**Questions**

- **Q23.** Distinguish `max` (field 5) from `inactive` (field 7) from `expire` (field 8). Sketch the timeline for `-M 90 -I 7`.
- **Q24.** `passwd -l`, `usermod -L`, `chage -E 1`, and `usermod -s /usr/sbin/nologin` all "disable" an account. The user has an SSH **public key** in `~/.ssh/authorized_keys`. Which of the four actually stops that login? Which one is the correct off-boarding action?
- **Q25.** `passwd -S` printed `P`, then `L`. What does `NP` mean and why is it an incident?
- **Q26.** `chage -d 0 ana` sets field 3 to `0`. Explain precisely how that differs from an expired password under `-M 90`, and why `0` is *not* the same as "the Epoch".
- **Q27.** Why does `chage -E 1` (not `-E 0`) appear in off-boarding runbooks?
- **Q28.** Which of the aging operations in this exercise can `ana` perform on herself, and which strictly require root?

---

## Exercise 6 — Modifying existing accounts safely

**Steps**

1. Rename the login and relocate the home directory in one operation:
   ```bash
   pkill -u carla ; sleep 1
   usermod -l carlota -d /home/carlota -m carlota
   getent passwd carlota
   ls -ld /home/carlota; ls -ld /home/carla 2>&1
   ```
   ```
   carlota:x:1001:1002::/home/carlota:/bin/bash
   drwx------ 2 carlota carlota 4096 Aug 27 09:31 /home/carlota
   ls: cannot access '/home/carla': No such file or directory
   ```

2. Note what the rename did **not** touch:
   ```bash
   getent group carla
   getent group | grep -E ':(.*,)?carla(,|$)'
   ```
   ```
   carla:x:1002:
   ```
   Fix it explicitly:
   ```bash
   groupmod -n carlota carla
   id carlota
   ```
   ```
   uid=1001(carlota) gid=1002(carlota) groups=1002(carlota),1001(platform)
   ```

3. Renumber a UID and audit the fallout:
   ```bash
   touch /srv/shared-report.txt && chown carlota /srv/shared-report.txt
   usermod -u 1500 carlota
   ls -ln /home/carlota/.bashrc /srv/shared-report.txt
   ```
   ```
   -rw-r--r-- 1 1500 1002 220 Aug 27 09:31 /home/carlota/.bashrc
   -rw-r--r-- 1 1001 1002   0 Aug 27 09:40 /srv/shared-report.txt
   ```

4. Locate and repair every file left behind:
   ```bash
   find / -xdev -uid 1001 -print 2>/dev/null
   find / -xdev -uid 1001 -exec chown 1500 {} +
   ls -ln /srv/shared-report.txt
   ```
   ```
   /srv/shared-report.txt
   -rw-r--r-- 1 1500 1002 0 Aug 27 09:40 /srv/shared-report.txt
   ```

5. Change the shell two ways and see the policy gate:
   ```bash
   usermod -s /bin/dash carlota && getent passwd carlota | cut -d: -f7
   cat /etc/shells
   su - carlota -c 'chsh -s /usr/bin/zsh'
   ```
   ```
   /bin/dash
   /bin/sh
   /bin/bash
   /usr/bin/dash
   chsh: "/usr/bin/zsh" is not listed in /etc/shells.
   ```

**Questions**

- **Q29.** `usermod -l` changed only field 1 of `/etc/passwd` (plus `/etc/shadow`). List every other place a login name may still appear that you must fix by hand.
- **Q30.** After `usermod -u 1500`, `/home/carlota/.bashrc` was re-owned but `/srv/shared-report.txt` was not. State the rule `usermod` follows, and write the command that finds all orphaned files system-wide.
- **Q31.** Why did step 1 begin with `pkill -u carlota`? What does `usermod` do if the user is logged in?
- **Q32.** `usermod -d /home/new` without `-m` succeeds instantly. Describe the resulting broken state at the user's next login.
- **Q33.** Root can set any shell with `usermod -s`, but `chsh` refused. Which file enforces that, and what else consults it?

---

## Exercise 7 — Deleting accounts and hunting orphans

**Steps**

1. Delete `carlota` **without** removing her data, and observe the residue:
   ```bash
   userdel carlota
   getent passwd carlota; echo "exit=$?"
   ls -ln /home/ | grep 1500
   getent group carlota
   ```
   ```
   exit=2
   drwx------ 2 1500 1002 4096 Aug 27 09:31 carlota
   ```
   *(The user private group `carlota` is gone: `USERGROUPS_ENAB yes` removed it because no other user had it as primary group.)*

2. Find every file with no owning user or group:
   ```bash
   find / -xdev \( -nouser -o -nogroup \) -printf '%u %g %p\n' 2>/dev/null
   ```
   ```
   1500 1002 /home/carlota
   1500 1002 /home/carlota/.bashrc
   1500 1002 /home/carlota/.profile
   1500 1002 /home/carlota/.bash_logout
   ```

3. Archive and reclaim:
   ```bash
   tar --numeric-owner -czf /root/carlota-home.tar.gz -C /home carlota
   rm -rf /home/carlota
   find / -xdev \( -nouser -o -nogroup \) 2>/dev/null | wc -l
   ```
   ```
   0
   ```

4. Delete `ana` the complete way and confirm all four databases are clean:
   ```bash
   userdel -r ana
   ```
   ```
   userdel: ana mail spool (/var/mail/ana) not found
   ```
   ```bash
   for f in passwd shadow group gshadow; do echo "== $f"; grep -c '^ana:' /etc/$f; done
   getent group platform
   ```
   ```
   == passwd
   0
   == shadow
   0
   == group
   0
   == gshadow
   0
   platform:x:1001:
   ```

5. Remove the now-empty groups:
   ```bash
   groupdel platform
   groupdel deployers
   groupdel: cannot remove the primary group of user 'svc_metrics'  # if you try groupdel svc_metrics
   ```

**Questions**

- **Q34.** `userdel carlota` removed the group `carlota` but `userdel -r ana` left `platform` in place. State the rule that governs this.
- **Q35.** `userdel -r` reported a missing mail spool but still exited successfully. Which two directory trees does `-r` remove?
- **Q36.** You must delete a user who has a running process. `userdel` refuses. What does `-f` do, and why is `-f` on a *system* account with a low UID especially dangerous?
- **Q37.** Why archive with `tar --numeric-owner`? What breaks if you omit it and restore on another host?
- **Q38.** `groupdel` refused to remove `svc_metrics`. Give the two-step sequence that would make the removal legitimate.

---

## Exercise 8 — Consistency, locking and the NSS layer

**Steps**

1. Run the integrity checkers in read-only mode:
   ```bash
   pwck -r
   grpck -r
   echo "grpck exit=$?"
   ```
   ```
   user 'lp': directory '/var/spool/lpd' does not exist
   user 'news': directory '/var/spool/news' does not exist
   pwck: no changes
   grpck exit=0
   ```

2. Inject a defect and let `pwck` find it:
   ```bash
   printf 'ghost:x:1600:1600::/home/ghost:/bin/bash\n' >> /etc/passwd
   pwck -r
   ```
   ```
   user 'ghost': no group 1600
   user 'ghost': directory '/home/ghost' does not exist
   no matching password file entry in /etc/shadow
   add user 'ghost' in /etc/shadow? No
   pwck: no changes
   ```

3. Repair it with the *locking* editor rather than a bare `vi`:
   ```bash
   EDITOR=/bin/ed vipw <<'EOF'
   /^ghost:/d
   w
   q
   EOF
   pwck -r && echo CLEAN
   ```
   ```
   You have modified /etc/passwd.
   You may need to modify /etc/shadow for consistency.
   Please use the command 'vipw -s' to do so.
   CLEAN
   ```
   Companion commands: `vipw -s` (shadow), `vigr` (group), `vigr -s` (gshadow).

4. See the shadow suite convert back and forth (**read the question before running this on anything you care about**):
   ```bash
   cp -a /etc/shadow /root/shadow.safe
   pwunconv
   getent passwd root | cut -c1-24
   ls /etc/shadow 2>&1
   pwconv
   getent passwd root | cut -c1-14
   ```
   ```
   root:$y$j9T$e8Kq3Vt2...
   ls: cannot access '/etc/shadow': No such file or directory
   root:x:0:0:root
   ```
   The group equivalents are `grpconv` / `grpunconv`.

5. Prove that `getent` is not `cat`:
   ```bash
   grep -c '' /etc/passwd
   getent passwd | wc -l
   grep ^passwd /etc/nsswitch.conf
   getent passwd 0
   ```
   ```
   21
   21
   passwd:         files systemd
   root:x:0:0:root:/root:/bin/bash
   ```

**Questions**

- **Q39.** `pwck` reported `directory '/var/spool/lpd' does not exist` and still said `no changes`. What are the two classes of problem `pwck` reports, and which ones can it actually fix?
- **Q40.** Exactly what does `vipw` do that `vi /etc/passwd` does not? Name the file it creates.
- **Q41.** What did `pwunconv` do to the security posture of the system, and what is the one legitimate reason to run it?
- **Q42.** On a host joined to LDAP or SSSD, `grep ^alice /etc/passwd` returns nothing but `id alice` works. Explain, and give the correct command for scripting user lookups.
- **Q43.** `getent passwd 0` accepted a numeric key. Give the equivalent for groups, and state the exit code `getent` returns when the key is not found.

---

## Exercise 9 — Capstone: diagnose a broken login

**Steps**

1. Build the scenario:
   ```bash
   useradd -m -s /bin/bash -G platform dario 2>/dev/null || { groupadd platform; useradd -m -s /bin/bash -G platform dario; }
   echo 'dario:Temp-Passw0rd!' | chpasswd
   su - dario -c 'echo LOGIN OK'
   ```
   ```
   LOGIN OK
   ```

2. Inject four independent faults:
   ```bash
   usermod -L dario                                   # fault A
   chage -E 1 dario                                   # fault B
   sed -i 's#^dario:\(.*\):/bin/bash$#dario:\1:/bin/zsh#' /etc/passwd   # fault C
   chown -R 4242 /home/dario                          # fault D
   ```

3. Diagnose **without** looking at the commands above. Work top-down through the account record:
   ```bash
   getent passwd dario
   passwd -S dario
   chage -l dario
   ls -ld /home/dario
   test -x "$(getent passwd dario | cut -d: -f7)" || echo "shell missing or not executable"
   ```
   ```
   dario:x:1002:1003::/home/dario:/bin/zsh
   dario L 08/27/2026 0 99999 7 -1
   Last password change					: Aug 27, 2026
   Password expires					: never
   Password inactive					: never
   Account expires						: Jan 02, 1970
   Minimum number of days between password change		: 0
   Maximum number of days between password change		: 90
   Number of days of warning before password expires	: 7
   drwx------ 2 4242 dario 4096 Aug 27 09:52 /home/dario
   shell missing or not executable
   ```

4. Repair, one fault at a time, verifying after each:
   ```bash
   usermod -U dario           && passwd -S dario | awk '{print $2}'
   usermod -e '' dario        && chage -l dario | grep 'Account expires'
   usermod -s /bin/bash dario && getent passwd dario | cut -d: -f7
   chown -R dario:dario /home/dario && ls -ld /home/dario
   su - dario -c 'echo LOGIN OK'
   ```
   ```
   P
   Account expires						: never
   /bin/bash
   drwx------ 2 dario dario 4096 Aug 27 09:52 /home/dario
   LOGIN OK
   ```

5. Clean up the whole lab:
   ```bash
   userdel -r dario; userdel -r ana 2>/dev/null; userdel -r carlota 2>/dev/null
   userdel svc_metrics; rm -rf /var/lib/metrics
   groupdel platform 2>/dev/null; groupdel deployers 2>/dev/null
   cp -a /root/acct-backup/{passwd,shadow,group,gshadow} /etc/
   pwck -r && grpck -r && echo RESTORED
   ```

**Questions**

- **Q44.** Rank the four faults by *observable symptom*: which produces "Permission denied", which "This account is currently not available", which "Your account has expired", which a silent fallback to `/bin/sh` or an immediate disconnect?
- **Q45.** Fault D left the home directory owned by UID `4242`. The user can still authenticate — what exactly fails, and at which stage of the login sequence?
- **Q46.** Which single command would have shown faults A and B together, and which would have shown C?
- **Q47.** Faults A and B are both "locks". If an auditor asks "was this account disabled or just password-locked?", which file field answers the question, and what is stored there?

---

## Command reference for this objective

| Task | Command | Files touched |
|---|---|---|
| Create user | `useradd -m -s SHELL -c GECOS -G g1,g2 name` | passwd, shadow, group, gshadow, subuid, subgid |
| Show/change useradd defaults | `useradd -D [-s SHELL]` | `/etc/default/useradd` |
| Modify user | `usermod -aG` / `-l` / `-d -m` / `-u` / `-s` / `-L` / `-U` / `-e` | passwd, shadow, group |
| Delete user | `userdel [-r] [-f] name` | all four (+ home, mail spool) |
| Create/modify/delete group | `groupadd [-r] [-g]` · `groupmod -n -g` · `groupdel` | group, gshadow |
| Group membership + admins | `gpasswd -a / -d / -A / -M / -r` | group, gshadow |
| Password | `passwd [-l -u -e -d -S -n -x -w -i]` · `chpasswd` | shadow |
| Aging | `chage [-l -d -m -M -W -I -E]` | shadow |
| Query (NSS-aware) | `getent passwd|group|shadow [key]` · `id` · `groups` | — |
| Integrity | `pwck` · `grpck` | passwd/shadow, group/gshadow |
| Safe editing | `vipw` · `vipw -s` · `vigr` · `vigr -s` | with lock files |
| Shadow conversion | `pwconv` / `pwunconv` · `grpconv` / `grpunconv` | passwd↔shadow, group↔gshadow |

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

### Exercise 0

**A1.** Plain `cp` creates the copies with the *invoking* umask and the current time, so `/etc/shadow` would land as `0644 root:root` — world-readable password hashes sitting in `/root` (and, worse, if you ever restore that copy over `/etc/shadow`, you propagate the bad mode). `cp -a` (`--archive` = `-dR --preserve=all`) keeps mode, ownership, timestamps and ACLs, so the backup is a faithful, restorable image.

**A2.** `/etc/passwd` and `/etc/group` are world-readable (`0644`) because ordinary programs must resolve UID→name and GID→name constantly — `ls -l`, `ps`, `find` all do it, as unprivileged users. `/etc/shadow` and `/etc/gshadow` are `0640 root:shadow` because they hold the password hashes; leaving hashes world-readable invites offline brute-force. The split is the **shadow password suite** (shadow-utils): the hash was moved out of field 2 of `/etc/passwd`, which now holds the placeholder `x`.

**A3.** `/usr/bin/passwd` (and `su`, `chage`, `gpasswd`, `newgrp`, `chsh`) — they are **setuid root** (`-rwsr-xr-x root root`), so they run with root's effective UID and can read/write `/etc/shadow`. Some distributions instead use setgid `shadow` binaries plus PAM helpers (`/usr/sbin/unix_chkpwd`), which is why the group ownership is `shadow`.

### Exercise 1

**A4.** `x` means "the real hash is in `/etc/shadow`" — it is a placeholder, not a password. If you empty the field (`root::0:0:...`) on a system where `/etc/shadow` also has no entry, the account has **no password at all**: `login` and `su` grant access with no prompt. When a shadow entry does exist, `x` vs. anything else is largely ignored by modern PAM, but the correct, portable value is `x`.

**A5.**
- `*` — an invalid hash string. No password can ever match. Conventional marker for a system account that must never authenticate by password. **Not** a "lock" in the shadow-utils sense.
- `!` — locked *and* no hash underneath (typical state right after `useradd` on Debian).
- `!!` — Red Hat/Fedora's "password never set" marker; functionally equivalent to `!`.
- `!$y$j9T$...` — a **valid hash prefixed with `!`**: this is `passwd -l` / `usermod -L`. Removing the `!` (`passwd -u`) restores the original password.
- **empty** — no password required. Anyone who reaches the login prompt gets in. This is a finding, always.

Only the empty field allows a "password login" (a passwordless one). None of the others do.

**A6.** `/etc/group`'s member list (field 4) records only **supplementary** memberships. `root`'s membership in group `0` is *primary*, stored in field 4 of `/etc/passwd`, not in `/etc/group`. `id` merges both sources, which is why it shows `groups=0(root)`. The same is true for every user-private group.

**A7.** Field 3 of `/etc/gshadow` is the comma-separated list of **group administrators** — users allowed to run `gpasswd -a`/`-d` on that group without being root. It is written by `gpasswd -A user1,user2 groupname`. (Fields are: `name : encrypted-group-password : administrators : members`.)

**A8.** `date -u -d "1970-01-01 UTC +20441 days" +%F` → `2025-12-19`. A value of `0` in field 3 does **not** mean 1 Jan 1970; it is the special sentinel meaning **"the password must be changed at the next login"** (set by `chage -d 0` or `passwd -e`). An *empty* field 3 means aging information is absent.

### Exercise 2

**A9.** `/etc/login.defs` is **system-wide policy** consulted by many tools of the shadow suite (`useradd`, `usermod`, `userdel`, `passwd`, `su`, `login`, PAM's `pam_unix`): ID ranges, hashing method, default aging, umask. `/etc/default/useradd` holds **`useradd`-only creation defaults**: the base HOME directory, the default shell and primary group, the skeleton path, mail-spool behaviour, and `INACTIVE`/`EXPIRE`. Policy vs. per-tool defaults.

**A10.** `CREATE_HOME` in `/etc/login.defs` — `yes` on RHEL, unset/`no` on Debian. The deterministic option is `-m` (`--create-home`); its counterpart is `-M` (`--no-create-home`). Always pass one explicitly in automation.

**A11.** With `USERGROUPS_ENAB yes`: (1) **at creation**, `useradd` creates a *user private group* with the same name as the user and uses it as the primary group, instead of falling back to `GROUP=100` (`users`) from `/etc/default/useradd`; (2) **at deletion**, `userdel` removes that group — but only if it has the user's name and no other user still has it as primary group. It also makes a `umask 002` safe for shared directories, since each user's default group contains only that user.

**A12.** No. `/etc/skel` is copied **once**, at `useradd -m` time; later additions reach only accounts created afterwards. The per-invocation override is `-k /path/to/skel` (`--skel`), which is only honoured together with `-m`.

### Exercise 3

**A13.** `ana` came from `UID_MIN`/`UID_MAX` (1000–60000) and `useradd` searches that range **upwards** from the lowest free value ≥ `UID_MIN`. `svc_metrics` came from `SYS_UID_MIN`/`SYS_UID_MAX` (100–999) because of `-r`, and there `useradd` searches **downwards** from `SYS_UID_MAX`, which is why it picked 999. Deliberate: system UIDs grow down, human UIDs grow up, so the two never collide.

**A14.** `useradd -p` expects an **already-encrypted hash**, exactly as it will be written into field 2 of `/etc/shadow` — not a plaintext password. `bob`'s literal string `Str0ng-Transit!` was stored as if it were a hash, matches nothing, and the account is effectively locked. Correct usage:
```bash
useradd -m -p "$(openssl passwd -6 -stdin <<< 'Str0ng-Transit!')" bob
# or: mkpasswd -m sha512crypt   (Debian: package whois)
```
In practice, prefer `chpasswd` or `passwd`, because `-p` puts the hash in the process table and shell history.

**A15.** It was **not locked in the sense of `passwd -l`** — there was no password to lock. `!` here means *no valid password has ever been set*. The practical difference matters at unlock time: `passwd -u` on an account whose field is only `!` produces `passwd: unlocking the password would result in a passwordless account` and refuses (unless forced with `-f`), whereas on `!$y$...` it simply restores the old password. `passwd -S` reports `L` for both.

**A16.** (1) The plaintext lands in the shell history file (`~/.bash_history`) and, for the lifetime of the pipeline, in `/proc/<pid>/cmdline`, visible to `ps` for any local user. (2) It is captured by shell auditing/`auditd`/`script` session recording and by the terminal scrollback, so the credential is durably logged somewhere you do not control. Safer: `chpasswd < file` with a `0600` file removed afterwards, or `passwd` interactively, or feed a pre-computed hash with `chpasswd -e`.

**A17.** Anything that does not need the login shell to be a real shell — most importantly **`sudo -u svc_metrics <cmd>`**, `su -s /bin/bash - svc_metrics`, and daemon startup via systemd's `User=` (systemd executes the unit's `ExecStart`, not the account's shell). SSH *forced commands* and internal-sftp configured in `sshd_config` can also bypass it. `nologin` is a convenience, not a security boundary; the boundary is `usermod -L` plus `usermod -e 1`, or removing the account.

### Exercise 4

**A18.** `usermod -G ops ana` **replaces** the entire supplementary-group list with exactly `ops`. Any other membership — `sudo`, `docker`, `wheel`, `platform` — is silently dropped. The classic production incident is an administrator adding themself to a new group and losing `sudo`/`wheel` in the same command, then discovering it after logging out. `-a` (`--append`) is only valid together with `-G` and adds without removing.

**A19.** Because group membership is stored **by name**, not by ID: `/etc/group`'s field 4 contains the literal string `ana`. Renaming the *group* rewrites only the group's own name field; the member list is untouched, and `id` resolves the GID freshly on every call. The corollary is the reverse case — renaming a **user** with `usermod -l` *does* rewrite the member lists, because those store the login name.

**A20.** `newgrp platform` starts a **new shell** whose real and effective GID is `platform` (exit it with `exit`/`Ctrl-D` to return). `sg platform -c "cmd"` runs a single command with that primary GID. Neither prompts if the invoking user is already a member of the group. If the user is **not** a member, both prompt for the **group password**, stored as a hash in field 2 of `/etc/gshadow` and set with `gpasswd groupname`. A `!` or `*` there means "no group password" and the prompt can never succeed — which is the recommended state; `gpasswd -r groupname` removes a group password.

**A21.**
```bash
gpasswd -d carla platform          # correct: surgical removal from one group
usermod -G platform,otros carla    # dangerous: rewrites the whole list
```
The `usermod -G` form requires you to re-enumerate *every* group the user should keep; omitting one silently revokes it. Use `gpasswd -d`, or build the list from `id -nG` before rewriting.

**A22.** Field 3, the administrator list (`ana`). Because `gpasswd` is setuid root, it checks that list and lets `ana` add/remove members of `platform` without full root. Note `getent gshadow` requires root to read.

### Exercise 5

**A23.**
- **`max` (field 5, `chage -M`)** — the password's lifetime in days. After `lastchg + max`, the password is expired: the user may still log in but is forced to change it immediately.
- **`inactive` (field 7, `chage -I`)** — a grace period *after* the password expires. Once `lastchg + max + inactive` passes, the **account** is disabled; no login at all, even with the right password.
- **`expire` (field 8, `chage -E`)** — an absolute end date for the account, independent of any password activity.

Timeline for `-M 90 -I 7`, counting from the last password change: days 0–75 normal · days 76–89 warning (`-W 14`) · day 90 password expired, forced change at login · days 90–97 grace · day 98 account inactive, login refused.

**A24.** Only **`chage -E 1`** (equivalently `usermod -e`) stops the key-based login: account expiry is enforced by PAM's *account* management stack (`pam_unix account`), which runs after any authentication method, including publickey. `passwd -l` and `usermod -L` touch only the password hash and are bypassed entirely by publickey auth — the single most common off-boarding mistake. `usermod -s /usr/sbin/nologin` blocks a shell session but not `ssh user@host 'command'` in every configuration, and not port-forwarding-only sessions. Correct off-boarding: `usermod -L -e 1 -s /usr/sbin/nologin user`, plus removing/renaming `~/.ssh/authorized_keys`, plus killing live sessions (`pkill -u user`).

**A25.** `passwd -S` field 2 is the password status: `P` = usable password, `L` = locked, `NP` = **no password** — field 2 of `/etc/shadow` is empty. Anyone reaching a login prompt (console, `su`, or SSH with `PermitEmptyPasswords yes`) authenticates with no credential. Audit for it with:
```bash
awk -F: '($2 == "") { print $1 }' /etc/shadow
```

**A26.** Under `-M 90`, expiry is *computed*: `lastchg + 90 < today`. `chage -d 0` sets `lastchg` to the sentinel `0`, which shadow-utils interprets unconditionally as "must change now", regardless of `max` — `chage -l` prints `password must be changed` rather than a date. It is **not** 1 Jan 1970: the Epoch itself is not representable in field 3, and an *empty* field means "no aging data". `passwd -e user` is the equivalent front end.

**A27.** `-E 0` is ambiguous with the "empty/never expires" encoding and older shadow-utils treated `0` as "no expiry"; `-E 1` is an unambiguous, definitely-in-the-past value (2 Jan 1970) that every version reads as expired. `chage -E -1` (or `usermod -e ''`) is the documented way to clear the field.

**A28.** As herself, `ana` can only run `chage -l ana` (reading her own aging record) and `passwd` to change her own password, subject to the `min` days constraint — with `-m 1` set, a second change on the same day is refused (`You must wait longer to change your password`). Every write to another user's record, and every use of `-d -m -M -W -I -E`, requires root.

### Exercise 6

**A29.** `usermod -l` rewrites the login name in `/etc/passwd`, `/etc/shadow`, and the member lists of `/etc/group` and `/etc/gshadow`. It does **not** touch: the home directory path or its name (needs `-d -m`), the **user private group's name** (needs `groupmod -n`), the mail spool `/var/mail/<name>`, `/etc/sudoers` and `/etc/sudoers.d/*`, cron (`/var/spool/cron/crontabs/<name>`), at jobs, `~/.ssh/authorized_keys` comments, `/etc/subuid` and `/etc/subgid`, systemd user units, ACL entries (`getfacl -R` stores names), quota records, and anything in application databases.

**A30.** The rule (from `usermod(8)`): when the UID changes, `usermod` re-owns only files **inside the user's home directory** and the mail spool. Files elsewhere keep the old numeric UID and become orphans — or, worse, silently belong to whoever is assigned that UID next. The system-wide sweep:
```bash
find / -xdev -uid 1001 -exec chown -h 1500 {} +      # before the old UID is reused
find / -xdev \( -nouser -o -nogroup \) -ls           # after the fact
```
Run it per filesystem (`-xdev` plus one invocation per mount) and remember network filesystems and backups.

**A31.** Because `usermod` refuses to modify an account with running processes for the fields that would break them (`usermod: user carlota is currently used by process 812`), and because moving a home directory out from under a live session leaves that session's `$HOME` pointing at a path that no longer exists. `pkill -u` (then verifying with `pgrep -u`, and `loginctl terminate-user` on systemd hosts) makes the change atomic from the user's perspective.

**A32.** `/etc/passwd` field 6 points at a directory that does not exist. At next login, PAM/`login` cannot `chdir` there; most systems log `Could not chdir to home directory /home/new: No such file or directory` and drop the user into `/` with `$HOME` set to the nonexistent path. Everything that reads `$HOME` then fails or silently reverts to defaults: no `.bashrc`, no `~/.ssh/authorized_keys` (so key-based SSH stops working), no dotfiles, and writes to `~` fail. `-m` (`--move-home`) moves the contents and fixes ownership.

**A33.** `/etc/shells` — the list of valid *login* shells. `chsh` refuses any path not listed when invoked by a non-root user. It is also consulted by `vsftpd` and other FTP daemons (a user whose shell is not in `/etc/shells` is denied), by `su`'s `--shell` handling, and by `getusershell(3)` in general. Root can bypass it with `usermod -s`, which performs no such validation — that is precisely how an unusable shell gets into `/etc/passwd`.

### Exercise 7

**A34.** `userdel` removes the user's primary group only if (a) `USERGROUPS_ENAB yes` is set, (b) the group has the **same name as the user**, and (c) **no other user** still has it as their primary group. `carlota` satisfied all three. `platform` was a *supplementary*, differently-named group shared with others, so `userdel` only stripped `ana` from its member list.

**A35.** `-r` (`--remove`) removes the **home directory and all its contents**, plus the **mail spool** (`/var/mail/<user>` or `/var/spool/mail/<user>`). A missing mail spool is a warning, not an error. Note what `-r` does *not* remove: files the user owns anywhere else on the system — cron jobs, `/tmp`, `/srv`, shared project trees.

**A36.** `-f` (`--force`) deletes the account even if the user is logged in, removes the home directory even when it is not owned by the user, and removes the user's group even if it is another user's primary group. On a low-UID system account this can delete a shared directory (`/var/lib/<service>` set as that account's home) or destroy a group that other daemons depend on — an outage delivered by a cleanup command. Always `pgrep -u`, `lsof -u`, and read `getent passwd <user>` before reaching for `-f`.

**A37.** Once the account is gone there is no name↔UID mapping left, so `tar` would store the numeric owner under a *stale* name resolution — or, at restore time, map the archived **name** onto whatever UID currently holds it on the target host, handing the old user's private data to an unrelated account. `--numeric-owner` stores and restores raw numeric IDs, keeping the data unambiguously orphaned until you deliberately re-assign it.

**A38.**
```bash
userdel svc_metrics      # remove the user whose primary group it is
groupdel svc_metrics     # now the group has no dependents
```
Verify no dependents remain first:
```bash
awk -F: -v gid=999 '$4==gid {print $1}' /etc/passwd
```

### Exercise 8

**A39.** `pwck` reports (1) **structural/consistency problems** — wrong field count, non-numeric UID/GID, duplicate login name or UID, an entry in `/etc/passwd` with no matching `/etc/shadow` line and vice versa, bad `/etc/shadow` field values; and (2) **advisory problems** — a home directory that does not exist, an invalid login shell, a GID with no group. It can *fix* only the first class, and only interactively: it offers to delete corrupt lines or add the missing shadow entry (`-r` makes it read-only, answering "no" to everything; `-q` reports only errors). The advisory findings, like `/var/spool/lpd`, are normal on a system without that service installed and are never "fixed" by `pwck`. `grpck` does the same for `/etc/group` and `/etc/gshadow`, including checking that every member listed actually exists in `/etc/passwd`.

**A40.** `vipw` (and `vigr`) take a **lock** — it creates `/etc/passwd.lock` (respectively `/etc/group.lock`, `/etc/shadow.lock`, `/etc/gshadow.lock`), the same lock `useradd`/`usermod`/`passwd` honour. Without it, a concurrent `useradd` and a hand edit can each write a full copy of the file and one silently loses the other's change — a real way to lose accounts. `vipw` also edits a temporary copy, validates that it parses before installing it, preserves the original mode/owner, and reminds you to run `vipw -s` for the matching shadow file. Never edit these files with a bare editor.

**A41.** `pwunconv` merges the hashes from `/etc/shadow` back into field 2 of the **world-readable** `/etc/passwd` and deletes `/etc/shadow` — every user's password hash becomes readable by every local user and every process, ready for offline cracking, and all aging fields (min/max/warn/inactive/expire) are **discarded**, not just hidden. There is essentially no reason to run it on a modern system; the legitimate case is migrating to or debugging a legacy tool or ancient Unix that predates the shadow suite, and the correct follow-up is an immediate `pwconv` (which recreates `/etc/shadow` from `/etc/passwd` + `/etc/login.defs` defaults — the previously discarded aging data does not come back).

**A42.** The local files are only one **NSS** source. `/etc/nsswitch.conf` lists the lookup chain for the `passwd`/`group`/`shadow` databases (`files sss`, `files ldap`, `files systemd`, …), and `alice` is served by the directory, never appearing in `/etc/passwd`. `grep` sees only the `files` backend. Use the NSS-aware tools: `getent passwd alice`, `getent group ops`, `id alice`. In scripts, `getent` is the only correct choice — and it exits `2` when the key is not found, which makes it directly testable.

**A43.** `getent group 0` (or `getent group root`). `getent` exits `0` on success, `1` if the database is unknown, **`2` if the key was not found**, and `3` if the database has no enumeration support.

### Exercise 9

**A44.**
- **Fault C** (shell `/bin/zsh` not installed) — `su - dario` prints `su: failed to execute /bin/zsh: No such file or directory`; over SSH the session authenticates and then closes immediately. Some services fall back to `/bin/sh`; `login` and `su` do not.
- **Fault A** (`usermod -L`) — the password prompt appears and the correct password is rejected: `su: Authentication failure` / `Permission denied, please try again`. Key-based SSH is unaffected.
- **Fault B** (`chage -E 1`) — authentication *succeeds*, then PAM account management refuses: `Your account has expired; please contact your system administrator`.
- **Fault D** (home owned by 4242) — login succeeds, then `Could not chdir to home directory /home/dario: Permission denied`, and the session lands in `/` with a broken `$HOME`.

**A45.** Authentication (PAM auth) and account validation (PAM account) both pass. The failure is in **session setup**: `login`/`sshd` cannot `chdir` into a `0700` directory owned by another UID, so no dotfiles are sourced, `~/.ssh/authorized_keys` is unreadable (which breaks the *next* key-based login and is often the first symptom reported), and every write to `~` fails with `Permission denied`. Note that `sshd`'s `StrictModes yes` will additionally refuse publickey auth outright when `~` or `~/.ssh` is not owned by the user.

**A46.** `chage -l dario` shows both the password state and the account expiry in one screen (fault B explicitly; fault A shows up as `L` under `passwd -S dario`, and the combination `passwd -S` + `chage -l` is the standard two-command triage). Fault C is visible in `getent passwd dario` field 7 — verify the shell is real with `test -x` and against `/etc/shells`.

**A47.** `/etc/shadow` answers both, in different fields. **Field 2** starting with `!` (or `!!`) means the *password* was locked — reversible with `passwd -u`, and bypassable by SSH keys. **Field 8** holding a past day-count (e.g. `1`) means the *account* was expired — a real disable, enforced for every authentication method. An auditor asking "disabled or password-locked?" is asking which of those two fields is set; a proper off-boarding sets both.

</details>

---

## Sources

- LPI — Exam 101-500 Objectives (LPIC-1 v5.0): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — Exam 102-500 Objectives, where Topic 107.1 is examined: <https://www.lpi.org/our-certifications/exam-102-objectives/>
- shadow-utils (upstream of `useradd`, `usermod`, `userdel`, `chage`, `gpasswd`, `pwck`, `vipw`): <https://github.com/shadow-maint/shadow>
- `passwd(5)` — format of the password file: <https://man7.org/linux/man-pages/man5/passwd.5.html>
- `shadow(5)` — format of the shadowed password file: <https://man7.org/linux/man-pages/man5/shadow.5.html>
- `group(5)` / `gshadow(5)`: <https://man7.org/linux/man-pages/man5/group.5.html> · <https://man7.org/linux/man-pages/man5/gshadow.5.html>
- `login.defs(5)` — shadow suite configuration: <https://man7.org/linux/man-pages/man5/login.defs.5.html>
- `useradd(8)` · `usermod(8)` · `userdel(8)`: <https://man7.org/linux/man-pages/man8/useradd.8.html> · <https://man7.org/linux/man-pages/man8/usermod.8.html> · <https://man7.org/linux/man-pages/man8/userdel.8.html>
- `chage(1)` · `passwd(1)` · `gpasswd(1)` · `newgrp(1)` · `sg(1)`: <https://man7.org/linux/man-pages/man1/chage.1.html> · <https://man7.org/linux/man-pages/man1/passwd.1.html> · <https://man7.org/linux/man-pages/man1/gpasswd.1.html>
- `pwck(8)` · `grpck(8)` · `vipw(8)` · `pwconv(8)`: <https://man7.org/linux/man-pages/man8/pwck.8.html> · <https://man7.org/linux/man-pages/man8/vipw.8.html> · <https://man7.org/linux/man-pages/man8/pwconv.8.html>
- `getent(1)` and `nsswitch.conf(5)` (GNU C Library): <https://man7.org/linux/man-pages/man1/getent.1.html> · <https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html>
- `crypt(5)` — password hash prefixes (`$1$`, `$5$`, `$6$`, `$y$`): <https://man7.org/linux/man-pages/man5/crypt.5.html>
- Debian Policy / `base-passwd` UID & GID assignment: <https://www.debian.org/doc/debian-policy/ch-opersys.html#uid-and-gid-classes>