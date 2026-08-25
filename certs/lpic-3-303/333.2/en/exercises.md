# LPIC-3 303 — Topic 333.2: Mandatory Access Control

## Guided Exercises

> **Exam context.** Objective 333.2 covers TE/RBAC/MAC/DAC concepts, configuring and maintaining SELinux, and awareness of AppArmor and Smack. Utilities in scope: `getenforce`, `setenforce`, `selinuxenabled`, `getsebool`, `setsebool`, `togglesebool`, `fixfiles`, `restorecon`, `setfiles`, `newrole`, `runcon`, `semanage`, `sestatus`, `seinfo`, `apol`, `seaudit`, `audit2why`, `audit2allow`, `/etc/selinux/*`, and the AppArmor toolchain.
> Source: [LPI Exam 303 Objectives (303-300, v3.0)](https://www.lpi.org/our-certifications/exam-303-objectives/)

---

## Lab environment

Two machines (VMs, containers with a full init, or cloud instances). Do **not** run these on a production host: several steps deliberately create denials, relabel filesystems and reload kernel policy.

| Host | Distribution | Role |
|---|---|---|
| `mac-rhel` | Rocky Linux 9 / RHEL 9 / Fedora 40+ | SELinux (Exercises 1–9, 11) |
| `mac-deb` | Ubuntu 24.04 LTS (or Debian 12) | AppArmor (Exercise 10) |

Package prerequisites:

```bash
# mac-rhel
sudo dnf install -y httpd curl policycoreutils policycoreutils-python-utils \
     setools-console selinux-policy-devel setroubleshoot-server audit attr

# mac-deb
sudo apt install -y apparmor apparmor-utils apparmor-profiles auditd attr
```

Outputs below are representative. PIDs, inodes, device names, policy version numbers and rule counts differ per system — the *shape* of the output is what you must be able to read.

---

## Exercise 1 — Proving that MAC is not DAC

The point of this exercise is not "SELinux blocked Apache". It is that a **fully permissive DAC configuration is not sufficient**, because DAC and MAC are two independent gates and the kernel evaluates both.

### Steps

1. Create content outside every path Apache is normally allowed to read:

   ```bash
   sudo mkdir -p /srv/lab333/html
   echo '<h1>333.2 MAC lab</h1>' | sudo tee /srv/lab333/html/index.html
   ```

2. Make DAC as permissive as it can possibly get, and confirm it:

   ```bash
   sudo chown -R apache:apache /srv/lab333
   sudo chmod -R 0777 /srv/lab333
   ls -ld /srv/lab333 /srv/lab333/html /srv/lab333/html/index.html
   ```

   ```
   drwxrwxrwx. 3 apache apache 19 Aug 24 10:02 /srv/lab333
   drwxrwxrwx. 2 apache apache 24 Aug 24 10:02 /srv/lab333/html
   -rwxrwxrwx. 1 apache apache 24 Aug 24 10:02 /srv/lab333/html/index.html
   ```

3. Point Apache at it:

   ```bash
   sudo tee /etc/httpd/conf.d/lab333.conf >/dev/null <<'EOF'
   DocumentRoot "/srv/lab333/html"
   <Directory "/srv/lab333/html">
       Require all granted
   </Directory>
   EOF
   sudo systemctl enable --now httpd
   ```

4. Request the page:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   ```

   ```
   403
   ```

5. Prove the failure is not DAC — read the same file as the same UID Apache runs under:

   ```bash
   sudo -u apache cat /srv/lab333/html/index.html
   ```

   ```
   <h1>333.2 MAC lab</h1>
   ```

6. Now look at the second gate:

   ```bash
   ls -Z /srv/lab333/html/index.html
   ps -eZ | grep -m1 httpd
   ```

   ```
   unconfined_u:object_r:var_t:s0 /srv/lab333/html/index.html
   system_u:system_r:httpd_t:s0    1487 ?  00:00:00 httpd
   ```

7. Read the denial the kernel recorded:

   ```bash
   sudo ausearch -m AVC -ts recent | tail -n 20
   ```

   ```
   type=AVC msg=audit(1756029773.114:412): avc:  denied  { getattr } for  pid=1489
     comm="httpd" path="/srv/lab333/html/index.html" dev="dm-0" ino=17825920
     scontext=system_u:system_r:httpd_t:s0
     tcontext=unconfined_u:object_r:var_t:s0
     tclass=file permissive=0
   ```

### Checkpoint 1

- **Q1.1** — Step 5 succeeded as `apache` but step 4 returned 403. Explain precisely why, in terms of the order in which the kernel evaluates DAC and LSM hooks.
- **Q1.2** — In the AVC record, identify what `scontext`, `tcontext`, `tclass` and `permissive=0` each denote. Which one tells you the *action* that was refused?
- **Q1.3** — The file was created by `root`, yet its SELinux user is `unconfined_u`, not `system_u` or `root`. Where did that first field come from?
- **Q1.4** — State the defining difference between DAC and MAC in one sentence, using this scenario as the example. Why can `chmod 777` never be a MAC bypass?

---

## Exercise 2 — Mode, state, and what "disabled" actually means

### Steps

1. Query the three state tools and note that they answer three different questions:

   ```bash
   getenforce
   selinuxenabled; echo "exit status: $?"
   sestatus
   ```

   ```
   Enforcing
   exit status: 0
   SELinux status:                 enabled
   SELinuxfs mount:                /sys/fs/selinux
   SELinux root directory:         /etc/selinux
   Loaded policy name:             targeted
   Current mode:                   enforcing
   Mode from config file:          enforcing
   Policy MLS status:              enabled
   Policy deny_unknown status:     allowed
   Memory protection checking:     actual (secure)
   Max kernel policy version:      33
   ```

2. Inspect the pseudo-filesystem the kernel exports the interface through:

   ```bash
   mount | grep selinuxfs
   cat /sys/fs/selinux/enforce
   ls /sys/fs/selinux/
   ```

   ```
   selinuxfs on /sys/fs/selinux type selinuxfs (rw,nosuid,noexec,relatime)
   1
   access  avc  booleans  checkreqprot  class  commit_pending_bools  context
   create  deny_unknown  enforce  initial_contexts  member  mls  policy  policyvers
   relabel  status  user  validatetrans
   ```

3. Watch the access vector cache while you generate traffic:

   ```bash
   cat /sys/fs/selinux/avc/cache_stats
   for i in $(seq 200); do curl -s -o /dev/null http://localhost/; done
   cat /sys/fs/selinux/avc/cache_stats
   ```

   ```
   lookups hits misses allocations reclaims frees
   1049873 1046412 3461 3461 2496 2560
   ```

4. Switch to permissive at runtime, retest, and switch back:

   ```bash
   sudo setenforce 0 && getenforce
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   sudo setenforce 1 && getenforce
   ```

   ```
   Permissive
   200
   Enforcing
   ```

5. Confirm that the runtime change did **not** touch the config file:

   ```bash
   sudo grep -Ev '^\s*(#|$)' /etc/selinux/config
   sestatus | grep -E 'Current mode|Mode from config'
   ```

   ```
   SELINUX=enforcing
   SELINUXTYPE=targeted
   Current mode:                   enforcing
   Mode from config file:          enforcing
   ```

6. Inspect what actually lives under `/etc/selinux`:

   ```bash
   ls /etc/selinux/
   ls /etc/selinux/targeted/
   ls /etc/selinux/targeted/contexts/files/
   ```

   ```
   config  semanage.conf  targeted
   active  contexts  policy  setrans.conf  logins
   file_contexts  file_contexts.bin  file_contexts.homedirs
   file_contexts.homedirs.bin  file_contexts.local  file_contexts.subs_dist
   media
   ```

7. Read (do not apply) the two boot-time overrides:

   ```
   enforcing=0     # policy loaded, all denials logged only
   selinux=0       # SELinux not initialised at all, nothing labelled
   ```

### Checkpoint 2

- **Q2.1** — `getenforce`, `selinuxenabled` and `sestatus` overlap. What does each one uniquely tell you, and which is the only one usable directly in a shell conditional?
- **Q2.2** — You run `setenforce 0`, reboot, and the system comes back Enforcing. Why? Which file would you have had to edit, and what is the trade-off versus the runtime command?
- **Q2.3** — A system is running with `SELINUX=disabled` in `/etc/selinux/config` and you now want Enforcing. Why is `setenforce 1` guaranteed to fail, and what must you do — including one step that is easy to forget and will render the system unbootable-into-a-usable-state if skipped?
- **Q2.4** — Contrast `enforcing=0` and `selinux=0` as kernel command line parameters. Which one is safe to use when diagnosing a boot failure you suspect is SELinux-related, and why is the other one a much worse choice for that purpose?
- **Q2.5** — What does `Policy deny_unknown status: allowed` mean, and what is the security consequence of the opposite setting?

---

## Exercise 3 — Contexts, labelling and the `chcon` trap

### Steps

1. Show the context of a process, a user, a file and a socket, and note the identical four-field grammar:

   ```bash
   id -Z
   ps -eZ | grep -m1 'httpd$'
   ls -Z /var/www/html
   sudo ss -ltnpZ | grep -m1 httpd
   ```

   ```
   unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
   system_u:system_r:httpd_t:s0     1487 ? 00:00:00 httpd
   system_u:object_r:httpd_sys_content_t:s0 index.html
   LISTEN 0 511 *:80 *:* users:(("httpd",pid=1487,fd=4,proc_ctx=system_u:system_r:httpd_t:s0))
   ```

2. Prove the label is an extended attribute on disk, not a database:

   ```bash
   getfattr -m . -d /srv/lab333/html/index.html
   ```

   ```
   getfattr: Removing leading '/' from absolute path names
   # file: srv/lab333/html/index.html
   security.selinux="unconfined_u:object_r:var_t:s0"
   ```

3. Ask the policy what the label *should* be, without changing anything:

   ```bash
   sudo selabel_lookup -b file -k /srv/lab333/html/index.html
   sudo matchpathcon /var/www/html/index.html     # legacy equivalent
   ```

   ```
   Default context: system_u:object_r:var_t:s0
   /var/www/html/index.html	system_u:object_r:httpd_sys_content_t:s0
   ```

4. Apply a **runtime-only** label and confirm the site now works:

   ```bash
   sudo chcon -R -t httpd_sys_content_t /srv/lab333/html
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   ls -Z /srv/lab333/html/index.html
   ```

   ```
   200
   unconfined_u:object_r:httpd_sys_content_t:s0 /srv/lab333/html/index.html
   ```

5. Now spring the trap — simulate any event that triggers a relabel:

   ```bash
   sudo restorecon -Rv /srv/lab333
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   ```

   ```
   Relabeled /srv/lab333/html from unconfined_u:object_r:httpd_sys_content_t:s0 to unconfined_u:object_r:var_t:s0
   Relabeled /srv/lab333/html/index.html from unconfined_u:object_r:httpd_sys_content_t:s0 to unconfined_u:object_r:var_t:s0
   403
   ```

6. Do it correctly — record the rule in the policy store first, then relabel:

   ```bash
   sudo semanage fcontext -a -t httpd_sys_content_t '/srv/lab333/html(/.*)?'
   sudo restorecon -Rv /srv/lab333/html
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   ```

   ```
   Relabeled /srv/lab333/html from unconfined_u:object_r:var_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
   Relabeled /srv/lab333/html/index.html from ... to unconfined_u:object_r:httpd_sys_content_t:s0
   200
   ```

7. Show that the rule is now persistent and inspect where it was written:

   ```bash
   sudo semanage fcontext -l -C
   sudo cat /etc/selinux/targeted/contexts/files/file_contexts.local
   ```

   ```
   SELinux fcontext              type       Context

   /srv/lab333/html(/.*)?        all files  system_u:object_r:httpd_sys_content_t:s0

   # This file is auto-generated by libsemanage
   # Do not edit directly.
   /srv/lab333/html(/.*)?    system_u:object_r:httpd_sys_content_t:s0
   ```

8. Observe the difference between `cp` and `mv` for labels:

   ```bash
   cd /tmp && echo hi > t1 && ls -Z t1
   sudo cp t1 /srv/lab333/html/copied.html   && ls -Z /srv/lab333/html/copied.html
   sudo cp -a t1 /srv/lab333/html/copied2.html && ls -Z /srv/lab333/html/copied2.html
   sudo mv t1 /srv/lab333/html/moved.html    && ls -Z /srv/lab333/html/moved.html
   ```

   ```
   unconfined_u:object_r:user_tmp_t:s0 t1
   unconfined_u:object_r:httpd_sys_content_t:s0 /srv/lab333/html/copied.html
   unconfined_u:object_r:user_tmp_t:s0          /srv/lab333/html/copied2.html
   unconfined_u:object_r:user_tmp_t:s0          /srv/lab333/html/moved.html
   ```

9. Compare the whole-filesystem tools:

   ```bash
   sudo fixfiles -v check /srv/lab333        # report only
   sudo fixfiles -R httpd restore            # relabel every path owned by a package
   sudo setfiles -v /etc/selinux/targeted/contexts/files/file_contexts /srv/lab333
   ```

10. Learn the emergency relabel that survives an unlabelled root filesystem:

    ```bash
    sudo touch /.autorelabel     # then reboot; init relabels everything and reboots again
    sudo fixfiles -F onboot      # equivalent, -F also resets user and role fields
    ```

### Checkpoint 3

- **Q3.1** — Name the four fields of an SELinux context in order. In the `targeted` policy, which field carries essentially all of the enforcement decisions, and what are the other three mostly used for?
- **Q3.2** — Step 4 fixed the site and step 5 broke it again with a command that changed no policy. Explain the mechanism, and state the rule of thumb for when `chcon` is legitimate.
- **Q3.3** — In step 8, `cp` produced a different label from `cp -a` and from `mv`. Explain each of the three outcomes in terms of whether an inode is created or merely renamed.
- **Q3.4** — `restorecon`, `setfiles` and `fixfiles` all relabel. Distinguish them by *what supplies the specification* and *what scope they operate on*. Which is the right tool for "one directory tree I just added a rule for", and which for "the whole system after SELinux was disabled for a month"?
- **Q3.5** — You add an fcontext rule but forget `restorecon`. Does the running system change behaviour? Does it change after a reboot? Explain.
- **Q3.6** — `semanage fcontext -a -e /srv/lab333/html /var/www/html` does something different from `-t`. What, and when would you prefer it?

---

## Exercise 4 — Type Enforcement, domains and transitions

### Steps

1. Get the size and shape of the loaded policy:

   ```bash
   seinfo
   ```

   ```
   Statistics for policy file: /sys/fs/selinux/policy
   Policy Version:             33 (MLS enabled)
   Target Policy:              selinux
   Handle unknown classes:     allow

     Classes:           135    Permissions:       326
     Sensitivities:       1    Categories:       1024
     Types:            5089    Attributes:        253
     Users:               8    Roles:             14
     Booleans:          326    Cond. Expr.:      371
     Allow:          113480    Neverallow:         0
     Type_trans:      27204    Type_change:       232
   ```

2. Inspect a domain type and the attributes it inherits privileges through:

   ```bash
   seinfo -t httpd_t -x | head -n 20
   seinfo -r system_r -x | head -n 5
   ```

3. Ask *why* Apache can read your content — the actual allow rule:

   ```bash
   sesearch -A -s httpd_t -t httpd_sys_content_t -c file -p read
   ```

   ```
   allow httpd_t httpd_sys_content_t:file { getattr ioctl lock map open read };
   ```

4. Confirm the reverse: no rule exists for `var_t`, which is why Exercise 1 failed:

   ```bash
   sesearch -A -s httpd_t -t var_t -c file -p read
   echo "matches: $?"
   ```

5. Find the automatic domain transition that turns `systemd` into a confined web server:

   ```bash
   sesearch -T -s init_t -t httpd_exec_t -c process
   ls -Z /usr/sbin/httpd
   ```

   ```
   type_transition init_t httpd_exec_t:process httpd_t;
   system_u:object_r:httpd_exec_t:s0 /usr/sbin/httpd
   ```

6. Verify the three rules a transition requires all exist:

   ```bash
   sesearch -A -s init_t -t httpd_exec_t -c file -p execute      # source may execute the entrypoint
   sesearch -A -s init_t -t httpd_t     -c process -p transition # source may transition to target domain
   sesearch -A -s httpd_t -t httpd_exec_t -c file -p entrypoint  # target domain may be entered via it
   ```

7. Force a context manually and observe what the policy permits:

   ```bash
   id -Z
   runcon -t httpd_t id -Z
   runcon -u system_u -r system_r -t httpd_t /usr/bin/cat /srv/lab333/html/index.html
   ```

   ```
   unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
   unconfined_u:unconfined_r:httpd_t:s0-s0:c0.c1023
   <h1>333.2 MAC lab</h1>
   ```

8. Try the role-change tool (targeted policy, unconfined user):

   ```bash
   newrole -r sysadm_r -t sysadm_t
   ```

   ```
   newrole: failure forking: Operation not permitted
   ```

   (On a policy where your SELinux user is authorised for `sysadm_r`, `newrole` re-authenticates you and spawns a new shell in the requested role.)

### Checkpoint 4

- **Q4.1** — Define *domain*, *type*, and *entrypoint*, and state the relationship between a domain and a type in the SELinux data model.
- **Q4.2** — A domain transition requires three separate allow rules. Name all three and explain what attack each one independently prevents if it is missing.
- **Q4.3** — Why does `runcon -t httpd_t` succeed for an unconfined shell in step 7 while `newrole` fails in step 8? What is the essential difference between what the two commands change?
- **Q4.4** — Explain how RBAC and TE compose in SELinux: which one denies an access, and what role does the role field actually play?
- **Q4.5** — `sesearch` reported an allow rule with source `httpd_t`, but `seinfo -t httpd_t -x` showed the type belongs to many attributes. Why can `sesearch -A` return rules that were never literally written with `httpd_t` on the left, and which option restricts output to rules that were?
- **Q4.6** — A binary is copied from `/usr/sbin/httpd` to `/usr/local/bin/httpd` and launched by systemd. What context does the process get, and why is this a privilege *escalation* from the policy's point of view even though nothing in policy changed?

---

## Exercise 5 — Booleans: policy you can change without writing policy

### Steps

1. Trigger a network denial. Add a proxy directive and a listener:

   ```bash
   sudo tee -a /etc/httpd/conf.d/lab333.conf >/dev/null <<'EOF'
   ProxyPass        /up/ http://127.0.0.1:9999/
   ProxyPassReverse /up/ http://127.0.0.1:9999/
   EOF
   sudo systemctl restart httpd
   (printf 'HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nup\n'; sleep 30) | nc -l 9999 &
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/up/
   ```

   ```
   503
   ```

2. Read the denial:

   ```bash
   sudo ausearch -m AVC -ts recent | tail -n 6
   ```

   ```
   type=AVC msg=audit(1756030411.883:498): avc:  denied  { name_connect } for  pid=1902
     comm="httpd" dest=9999 scontext=system_u:system_r:httpd_t:s0
     tcontext=system_u:object_r:unreserved_port_t:s0 tclass=tcp_socket permissive=0
   ```

   > Confirm the destination port's type on *your* policy rather than trusting the transcript: `sudo semanage port -l | grep -w 9999`.

3. Find the boolean that governs it, and read its description:

   ```bash
   sudo semanage boolean -l | grep httpd_can_network
   getsebool -a | grep httpd_can_network_connect
   ```

   ```
   httpd_can_network_connect      (off  ,  off)  Allow httpd to can network connect
   httpd_can_network_connect_db   (off  ,  off)  Allow httpd to can network connect db
   httpd_can_network_connect off
   ```

4. Confirm that the boolean really is what gates the rule:

   ```bash
   sesearch -A -b httpd_can_network_connect -s httpd_t -c tcp_socket -p name_connect
   ```

   ```
   allow httpd_t port_type:tcp_socket { name_connect recv_msg send_msg }; [ httpd_can_network_connect ]
   ```

5. Flip it non-persistently, test, then flip it persistently:

   ```bash
   sudo setsebool httpd_can_network_connect on
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/up/
   sudo semanage boolean -l -C
   ```

   ```
   200
   SELinux boolean          State  Default  Description
   httpd_can_network_connect (on ,  off)  Allow httpd to can network connect
   ```

   ```bash
   sudo setsebool -P httpd_can_network_connect on
   sudo semanage boolean -l -C
   ```

   ```
   httpd_can_network_connect (on ,   on)  Allow httpd to can network connect
   ```

6. Compare with the flip-only tool and the raw kernel interface:

   ```bash
   sudo togglesebool httpd_can_network_connect
   getsebool httpd_can_network_connect
   cat /sys/fs/selinux/booleans/httpd_can_network_connect
   sudo setsebool -P httpd_can_network_connect on
   ```

   ```
   httpd_can_network_connect => off
   httpd_can_network_connect off
   0 1
   ```

7. Export and re-import your local customisations — the way you move them between hosts:

   ```bash
   sudo semanage export -f /tmp/lab333-local.mod
   cat /tmp/lab333-local.mod
   # on another host:  sudo semanage import -f /tmp/lab333-local.mod
   ```

   ```
   boolean -m -1 httpd_can_network_connect
   fcontext -a -f a -t httpd_sys_content_t -r 's0' '/srv/lab333/html(/.*)?'
   ```

### Checkpoint 5

- **Q5.1** — `semanage boolean -l` shows two states per boolean. What are they, and what does the pair `(on , off)` tell you about how this machine will behave after a reboot?
- **Q5.2** — Distinguish `setsebool`, `setsebool -P` and `togglesebool` by persistence and by whether they require you to know the current value.
- **Q5.3** — Step 6 showed `0 1` in `/sys/fs/selinux/booleans/…`. Interpret both numbers.
- **Q5.4** — A boolean and a custom `allow` module can both make a denial go away. Give two concrete reasons to prefer the boolean when one exists.
- **Q5.5** — `httpd_can_network_connect` allows connections to `port_type`, an attribute covering essentially every labelled port. What is the security cost of enabling it compared with labelling one specific port for `http_port_t` (Exercise 6)?

---

## Exercise 6 — `semanage`: ports, logins, users, and the local store

### Steps

1. Move Apache to a non-standard port and watch it fail to start:

   ```bash
   sudo sed -i 's/^Listen 80$/Listen 8088/' /etc/httpd/conf/httpd.conf
   sudo systemctl restart httpd; echo "exit: $?"
   sudo systemctl status httpd --no-pager -l | tail -n 8
   ```

   ```
   exit: 1
   httpd[2044]: (13)Permission denied: AH00072: make_sock: could not bind to address [::]:8088
   httpd[2044]: no listening sockets available, shutting down
   ```

2. Confirm it is MAC, not a port conflict and not a capability problem:

   ```bash
   sudo ss -ltnp | grep 8088 ; echo "in use: $?"
   sudo ausearch -m AVC -ts recent | tail -n 5
   ```

   ```
   in use: 1
   type=AVC msg=audit(1756030880.702:531): avc:  denied  { name_bind } for  pid=2044
     comm="httpd" src=8088 scontext=system_u:system_r:httpd_t:s0
     tcontext=system_u:object_r:unreserved_port_t:s0 tclass=tcp_socket permissive=0
   ```

3. Inspect the port label database and the policy rule behind it:

   ```bash
   sudo semanage port -l | grep -w http_port_t
   seinfo --portcon=8088
   ```

   ```
   http_port_t   tcp   80, 81, 443, 488, 8008, 8009, 8443, 9000
   portcon tcp 8088 system_u:object_r:unreserved_port_t:s0
   ```

4. Label the port and restart:

   ```bash
   sudo semanage port -a -t http_port_t -p tcp 8088
   sudo semanage port -l -C
   sudo systemctl restart httpd; echo "exit: $?"
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8088/index.html
   ```

   ```
   SELinux Port Type   Proto   Port Number
   http_port_t         tcp     8088
   exit: 0
   200
   ```

5. Note the difference between adding and modifying:

   ```bash
   sudo semanage port -a -t http_port_t -p tcp 80
   ```

   ```
   ValueError: Port tcp/80 already defined
   ```

   ```bash
   sudo semanage port -m -t http_port_t -p tcp 9000   # -m modifies an existing definition
   ```

6. Explore the confined-user side of `semanage`:

   ```bash
   sudo semanage user -l
   sudo semanage login -l
   ```

   ```
   SELinux User  Labeling Prefix  MLS/MCS Level  MLS/MCS Range        SELinux Roles
   guest_u       user             s0             s0                   guest_r
   staff_u       user             s0             s0-s0:c0.c1023       staff_r sysadm_r system_r unconfined_r
   sysadm_u      user             s0             s0-s0:c0.c1023       sysadm_r
   unconfined_u  user             s0             s0-s0:c0.c1023       system_r unconfined_r
   user_u        user             s0             s0                   user_r
   xguest_u      user             s0             s0                   xguest_r

   Login Name   SELinux User   MLS/MCS Range     Service
   __default__  unconfined_u   s0-s0:c0.c1023    *
   root         unconfined_u   s0-s0:c0.c1023    *
   ```

7. Confine a real Linux account and observe the effect:

   ```bash
   sudo useradd -m kiosk && echo 'kiosk:Lab333pass!' | sudo chpasswd
   sudo semanage login -a -s user_u kiosk
   sudo semanage login -l | grep kiosk
   ```

   ```
   kiosk        user_u         s0                *
   ```

   Log in as `kiosk` on a text console (not via `su`, which does not re-run PAM's context assignment the same way) and check:

   ```bash
   id -Z
   sudo -i
   ```

   ```
   user_u:user_r:user_t:s0
   sudo: PERM_ROOT: setresuid(0, -1, 0): Operation not permitted
   ```

8. Clean up:

   ```bash
   sudo semanage login -d kiosk
   sudo userdel -r kiosk
   ```

### Checkpoint 6

- **Q6.1** — Apache runs as root at bind time and therefore holds `CAP_NET_BIND_SERVICE`. Explain why it still could not bind 8088, and what that says about the relationship between capabilities and MAC.
- **Q6.2** — Give the exact `semanage` invocation to allow a service labelled `mysqld_t` to listen on TCP 3307, and explain how you would first check whether the port is already defined.
- **Q6.3** — What is the practical difference between `semanage port -a` and `semanage port -m`, and what error tells you that you needed the other one?
- **Q6.4** — Explain the three-layer mapping: Linux user → SELinux user → role → domain. Which `semanage` subcommand configures each hop?
- **Q6.5** — In step 7, `sudo -i` failed for `kiosk` even though `kiosk` might be in `wheel`. Which mechanism blocked it, and how does this differ from removing `kiosk` from `wheel`?
- **Q6.6** — `semanage export` produced a short file. What class of configuration does it capture, and what does it deliberately *not* capture? Why does that matter when rebuilding a host?

---

## Exercise 7 — Reading denials: `audit2why`, `audit2allow`, `dontaudit`, permissive domains

### Steps

1. Manufacture a fresh denial that a boolean cannot fix:

   ```bash
   sudo mkdir -p /srv/lab333/writable
   sudo semanage fcontext -a -t httpd_sys_content_t '/srv/lab333/writable(/.*)?'
   sudo restorecon -Rv /srv/lab333/writable
   sudo -u apache runcon -u system_u -r system_r -t httpd_t \
        /usr/bin/touch /srv/lab333/writable/upload.tmp
   ```

   ```
   /usr/bin/touch: cannot touch '/srv/lab333/writable/upload.tmp': Permission denied
   ```

2. Search the audit log several ways — know all three:

   ```bash
   sudo ausearch -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR -ts recent -i
   sudo journalctl -t setroubleshoot --since '-10 min'
   sudo grep -c 'avc:  denied' /var/log/audit/audit.log
   ```

3. Get a human explanation with `setroubleshoot`:

   ```bash
   sudo journalctl -t setroubleshoot --since '-10 min' | tail -n 3
   sudo sealert -l '*' | head -n 30
   ```

   ```
   SELinux is preventing touch from write access on the directory writable.
   *****  Plugin catchall_labels (83.8 confidence) suggests  *******************
   If you want to allow touch to have write access on the writable directory
   Then you need to change the label on writable
   Do
   # semanage fcontext -a -t FILE_TYPE 'writable'
   ```

4. Ask *why* it was denied, in policy terms:

   ```bash
   sudo ausearch -m AVC -ts recent | audit2why
   ```

   ```
   type=AVC msg=audit(1756031204.551:602): avc:  denied  { write } for  pid=2210
     comm="touch" name="writable" dev="dm-0" ino=17825923
     scontext=system_u:system_r:httpd_t:s0
     tcontext=system_u:object_r:httpd_sys_content_t:s0
     tclass=dir permissive=0

   	Was caused by:
   	Missing type enforcement (TE) allow rule.

   	You can use audit2allow to generate a loadable module to allow this access.
   ```

5. See what a **generated** rule would look like — do not install it yet:

   ```bash
   sudo ausearch -m AVC -ts recent | audit2allow
   ```

   ```
   #============= httpd_t ==============
   allow httpd_t httpd_sys_content_t:dir { add_name write };
   allow httpd_t httpd_sys_content_t:file { create write };
   ```

6. Recognise the correct answer instead: the policy already ships a *type* for writable web content:

   ```bash
   sudo semanage fcontext -m -t httpd_sys_rw_content_t '/srv/lab333/writable(/.*)?'
   sudo restorecon -Rv /srv/lab333/writable
   sudo -u apache runcon -u system_u -r system_r -t httpd_t \
        /usr/bin/touch /srv/lab333/writable/upload.tmp && echo OK
   ```

   ```
   Relabeled /srv/lab333/writable from ...httpd_sys_content_t:s0 to ...httpd_sys_rw_content_t:s0
   OK
   ```

7. Now practise the module workflow on a denial that genuinely has no policy answer:

   ```bash
   sudo -u apache runcon -u system_u -r system_r -t httpd_t \
        /usr/bin/cat /var/log/dnf5.log 2>/dev/null
   sudo ausearch -m AVC -ts recent -c cat | audit2allow -M lab333-readlog
   cat lab333-readlog.te
   ```

   ```
   ******************** IMPORTANT ***********************
   To make this policy package active, execute:

   semodule -i lab333-readlog.pp

   module lab333-readlog 1.0;

   require {
   	type httpd_t;
   	type var_log_t;
   	class file { getattr open read };
   }

   #============= httpd_t ==============
   allow httpd_t var_log_t:file { getattr open read };
   ```

8. Install, verify, then remove:

   ```bash
   sudo semodule -i lab333-readlog.pp
   sudo semodule --list=full | grep lab333
   sudo -u apache runcon -u system_u -r system_r -t httpd_t \
        /usr/bin/head -1 /var/log/dnf5.log && echo ALLOWED
   sudo semodule -r lab333-readlog
   ```

   ```
   400 lab333-readlog  pp
   2026-08-24T09:11:04+0000 INFO --- logging initialized ---
   ALLOWED
   ```

9. Use a **permissive domain** — the correct way to gather a complete rule set without disabling enforcement globally:

   ```bash
   sudo semanage permissive -a httpd_t
   sudo semanage permissive -l
   getenforce
   # exercise the application fully here; every would-be denial is logged with permissive=1
   sudo ausearch -m AVC -ts recent | grep -c 'permissive=1'
   sudo semanage permissive -d httpd_t
   ```

   ```
   Builtin Permissive Types

   Customized Permissive Types

   httpd_t
   Enforcing
   ```

10. Reveal the denials the policy is deliberately hiding:

    ```bash
    sesearch --dontaudit -s httpd_t | head -n 5
    sudo semodule -DB          # rebuild policy with all dontaudit rules disabled
    # reproduce the problem, collect AVCs
    sudo semodule -B           # restore dontaudit rules
    ```

### Checkpoint 7

- **Q7.1** — Explain the division of labour between `ausearch`, `audit2why` and `audit2allow`. Which one requires a loaded policy to answer its question, and why?
- **Q7.2** — In step 4, `audit2why` said "Missing type enforcement (TE) allow rule." List at least three *other* causes `audit2why` can report, and explain why each one means `audit2allow` output would be useless or harmful.
- **Q7.3** — Step 5 generated a syntactically correct allow rule that you deliberately did not install, and step 6 solved the problem with a relabel. Articulate the general rule for choosing between "change the label" and "add a rule".
- **Q7.4** — `semodule --list=full` showed `400 lab333-readlog pp`. What is 400, what priority do distribution modules use, and how would you install a module that overrides a shipped one?
- **Q7.5** — Compare `setenforce 0` and `semanage permissive -a httpd_t` as troubleshooting techniques. Give two distinct advantages of the second.
- **Q7.6** — What is a `dontaudit` rule, why does the policy ship thousands of them, and describe the exact scenario in which `semodule -DB` is the only way to make progress. What must you remember afterwards?
- **Q7.7** — A junior engineer's runbook says: "if the app breaks, run `ausearch -m AVC -ts today | audit2allow -M fixit && semodule -i fixit.pp`." Give three specific reasons this is dangerous, at least one of which is about the *time window*.

---

## Exercise 8 — Writing policy by hand: TE source and CIL

### Steps

1. Confirm the development environment is present:

   ```bash
   rpm -q selinux-policy-devel
   ls /usr/share/selinux/devel/Makefile /usr/share/selinux/devel/include/ | head -n 4
   ```

2. Write a module in TE source. This one creates a private type for a spool directory, labels it via an `fc` file, and grants Apache exactly the access it needs:

   ```bash
   mkdir -p ~/lab333-policy && cd ~/lab333-policy
   cat > lab333spool.te <<'EOF'
   policy_module(lab333spool, 1.0.0)

   require {
       type httpd_t;
       type unconfined_t;
       role unconfined_r;
   }

   type lab333_spool_t;
   files_type(lab333_spool_t)

   # Apache may read, write and create inside the spool
   allow httpd_t lab333_spool_t:dir  { getattr search open read write add_name remove_name };
   allow httpd_t lab333_spool_t:file { getattr open read write create unlink append };

   # Administrators may manage it interactively
   allow unconfined_t lab333_spool_t:dir  { relabelfrom relabelto };
   allow unconfined_t lab333_spool_t:file { relabelfrom relabelto };
   EOF

   cat > lab333spool.fc <<'EOF'
   /srv/lab333/spool(/.*)?    gen_context(system_u:object_r:lab333_spool_t,s0)
   EOF
   ```

3. Build with the reference-policy makefile:

   ```bash
   make -f /usr/share/selinux/devel/Makefile lab333spool.pp
   ls -l lab333spool.pp
   ```

   ```
   Compiling targeted lab333spool module
   Creating targeted lab333spool.pp policy package
   rm tmp/lab333spool.mod tmp/lab333spool.mod.fc
   -rw-r--r--. 1 root root 1284 Aug 24 11:20 lab333spool.pp
   ```

4. Build the same thing the low-level way, to know what the makefile is doing:

   ```bash
   checkmodule -M -m -o lab333spool.mod lab333spool.te
   semodule_package -o lab333spool-manual.pp -m lab333spool.mod -f lab333spool.fc
   ```

   ```
   checkmodule:  loading policy configuration from lab333spool.te
   checkmodule:  policy configuration loaded
   checkmodule:  writing binary representation (version 19) to lab333spool.mod
   ```

5. Install and verify the new type actually exists in the running policy:

   ```bash
   sudo semodule -i lab333spool.pp
   seinfo -t lab333_spool_t -x
   sudo mkdir -p /srv/lab333/spool && sudo restorecon -Rv /srv/lab333/spool
   ls -Zd /srv/lab333/spool
   ```

   ```
   Types: 1
      type lab333_spool_t;
         file_type
         non_security_file_type
   Relabeled /srv/lab333/spool from unconfined_u:object_r:var_t:s0 to system_u:object_r:lab333_spool_t:s0
   system_u:object_r:lab333_spool_t:s0 /srv/lab333/spool
   ```

6. Do the same with CIL, the language `semodule` compiles everything down to:

   ```bash
   cat > lab333cil.cil <<'EOF'
   (allow httpd_t lab333_spool_t (dir (rmdir)))
   EOF
   sudo semodule -X 300 -i lab333cil.cil
   sudo semodule --list=full | grep lab333
   ```

   ```
   300 lab333cil       cil
   400 lab333spool     pp
   ```

7. Dump a shipped module as CIL to read real policy source:

   ```bash
   sudo semodule -c -E apache 2>/dev/null || \
     sudo /usr/libexec/selinux/hll/pp /var/lib/selinux/targeted/active/modules/100/apache/hll \
       > /tmp/apache.cil
   head -n 20 /tmp/apache.cil
   ```

8. Clean up:

   ```bash
   sudo semodule -X 300 -r lab333cil
   sudo semodule -r lab333spool
   ```

### Checkpoint 8

- **Q8.1** — Trace the toolchain: `.te` + `.fc` → `.mod` → `.pp` → loaded policy. Name the tool responsible for each arrow and what artefact each produces.
- **Q8.2** — What is the `require { }` block for, and what happens if you reference `httpd_t` without it?
- **Q8.3** — Why did the module need an `.fc` file *and* a `restorecon` run? What would have happened if you installed the module and created the directory but never relabelled?
- **Q8.4** — Step 6 installed a `.cil` file directly while step 5 installed a compiled `.pp`. What is CIL's role in the modern SELinux userspace, and what does that imply about the `.pp` format going forward?
- **Q8.5** — The module defines a brand-new type rather than reusing `httpd_sys_rw_content_t`. State one strong argument for each choice in a production deployment.
- **Q8.6** — Why must `files_type()` (or an equivalent attribute assignment) be applied to a new file type? What breaks if you declare a bare `type lab333_spool_t;` and nothing else?

---

## Exercise 9 — MLS/MCS: the second dimension

### Steps

1. Confirm the targeted policy has the MCS machinery enabled:

   ```bash
   sestatus | grep MLS
   seinfo | grep -E 'Sensitivities|Categories'
   id -Z
   ```

   ```
   Policy MLS status:              enabled
     Sensitivities:       1    Categories:       1024
   unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
   ```

2. Create two files and put one in a category:

   ```bash
   sudo mkdir -p /srv/lab333/mcs
   echo 'public data'  | sudo tee /srv/lab333/mcs/open.txt   >/dev/null
   echo 'tenant-A data'| sudo tee /srv/lab333/mcs/tenantA.txt >/dev/null
   sudo chcat +c100 /srv/lab333/mcs/tenantA.txt
   ls -Z /srv/lab333/mcs/
   ```

   ```
   unconfined_u:object_r:var_t:s0       open.txt
   unconfined_u:object_r:var_t:s0:c100  tenantA.txt
   ```

3. Read both as your unconfined self, whose range is `s0-s0:c0.c1023`:

   ```bash
   sudo cat /srv/lab333/mcs/tenantA.txt
   ```

   ```
   tenant-A data
   ```

4. Now read them from a process pinned to a *lower* level:

   ```bash
   sudo runcon -l s0 /usr/bin/cat /srv/lab333/mcs/open.txt
   sudo runcon -l s0 /usr/bin/cat /srv/lab333/mcs/tenantA.txt
   ```

   ```
   public data
   /usr/bin/cat: /srv/lab333/mcs/tenantA.txt: Permission denied
   ```

5. Grant exactly the one category needed:

   ```bash
   sudo runcon -l s0:c100 /usr/bin/cat /srv/lab333/mcs/tenantA.txt
   ```

   ```
   tenant-A data
   ```

6. Look at what the denial from step 4 looks like, and what `audit2why` says about it:

   ```bash
   sudo ausearch -m AVC -ts recent -c cat | tail -n 5
   sudo ausearch -m AVC -ts recent -c cat | audit2why | tail -n 6
   ```

   ```
   type=AVC msg=audit(1756032980.221:701): avc:  denied  { read } for pid=2551 comm="cat"
     name="tenantA.txt" scontext=unconfined_u:unconfined_r:unconfined_t:s0
     tcontext=unconfined_u:object_r:var_t:s0:c100 tclass=file permissive=0

   	Was caused by:
   	Constraint violation.

   	Check policy/constraints.
   	Typically, you just need to add a type attribute to the domain
   	or the type to satisfy the constraint.
   ```

7. See the same mechanism doing real work — container isolation:

   ```bash
   sudo dnf install -y podman
   sudo podman run -d --name c1 registry.access.redhat.com/ubi9/ubi sleep 300
   sudo podman run -d --name c2 registry.access.redhat.com/ubi9/ubi sleep 300
   ps -eZ | grep -E 'sleep 300'
   ```

   ```
   system_u:system_r:container_t:s0:c214,c806   3011 ? 00:00:00 sleep
   system_u:system_r:container_t:s0:c455,c1002  3062 ? 00:00:00 sleep
   ```

8. Inspect a bind-mounted volume's label:

   ```bash
   sudo mkdir -p /srv/lab333/vol && echo hi | sudo tee /srv/lab333/vol/f >/dev/null
   sudo podman run --rm -v /srv/lab333/vol:/data:Z ubi9/ubi cat /data/f
   ls -Zd /srv/lab333/vol
   ```

   ```
   hi
   system_u:object_r:container_file_t:s0:c214,c806 /srv/lab333/vol
   ```

9. Clean up:

   ```bash
   sudo podman rm -f c1 c2
   sudo chcat -d +c100 /srv/lab333/mcs/tenantA.txt 2>/dev/null || \
     sudo chcon -l s0 /srv/lab333/mcs/tenantA.txt
   ```

### Checkpoint 9

- **Q9.1** — Distinguish MLS from MCS. How many sensitivities does the `targeted` policy define, and what does that tell you about which of the two it is really implementing?
- **Q9.2** — In step 4, the same file was readable by one process and not another, with identical type on both sides. Which part of the policy denied it, and why is that architecturally different from a missing `allow` rule?
- **Q9.3** — `audit2why` reported "Constraint violation" and suggested adding a type attribute. Explain why running `audit2allow -M` here would produce a module that installs cleanly and changes nothing.
- **Q9.4** — A process has range `s0-s0:c0.c1023`. Explain "dominance" and state which of these it may read: `s0`, `s0:c5`, `s0:c1024`, `s1:c5`.
- **Q9.5** — Two containers received different category pairs. Explain how this achieves tenant isolation using a policy in which both processes have the *same* type, and what happens if you launch a container with `--security-opt label=disable`.
- **Q9.6** — What does the `:Z` suffix on a podman bind mount do, and what is the difference from `:z`? Name one situation where `:Z` on the wrong directory is destructive.

---

## Exercise 10 — AppArmor: path-based MAC on Debian/Ubuntu

Run this block on `mac-deb`.

### Steps

1. Establish the baseline:

   ```bash
   sudo aa-status
   cat /sys/kernel/security/lsm
   cat /sys/module/apparmor/parameters/enabled
   ```

   ```
   apparmor module is loaded.
   58 profiles are loaded.
   38 profiles are in enforce mode.
      /usr/bin/man
      /usr/lib/NetworkManager/nm-dhcp-client.action
      ...
   20 profiles are in complain mode.
   0 profiles are in kill mode.
   0 profiles are in unconfined mode.
   4 processes have profiles defined.
   4 processes are in enforce mode.
   0 processes are in complain mode.
   0 processes are unconfined but have a profile defined.

   lockdown,capability,landlock,yama,apparmor,bpf,ipe
   Y
   ```

2. Identify processes that *should* be confined and are not:

   ```bash
   sudo aa-unconfined | head
   ```

3. Create the program you will confine:

   ```bash
   sudo mkdir -p /srv/lab333/public /srv/lab333/private
   echo 'public'  | sudo tee /srv/lab333/public/ok.txt   >/dev/null
   echo 'secrets' | sudo tee /srv/lab333/private/key.txt >/dev/null

   sudo tee /usr/local/bin/lab333-reader >/dev/null <<'EOF'
   #!/bin/bash
   for f in "$@"; do
       printf '%s: ' "$f"
       cat -- "$f" 2>&1
   done
   EOF
   sudo chmod 0755 /usr/local/bin/lab333-reader
   /usr/local/bin/lab333-reader /srv/lab333/public/ok.txt /srv/lab333/private/key.txt
   ```

   ```
   /srv/lab333/public/ok.txt: public
   /srv/lab333/private/key.txt: secrets
   ```

4. Generate a skeleton profile and read it:

   ```bash
   sudo aa-autodep /usr/local/bin/lab333-reader
   sudo cat /etc/apparmor.d/usr.local.bin.lab333-reader
   ```

   ```
   # Last Modified: Mon Aug 24 12:04:11 2026
   abi <abi/4.0>,

   include <tunables/global>

   /usr/local/bin/lab333-reader {
     include <abstractions/base>
     include <abstractions/bash>

     /usr/local/bin/lab333-reader r,
   }
   ```

5. Write the real profile by hand:

   ```bash
   sudo tee /etc/apparmor.d/usr.local.bin.lab333-reader >/dev/null <<'EOF'
   abi <abi/4.0>,
   include <tunables/global>

   profile lab333-reader /usr/local/bin/lab333-reader {
     include <abstractions/base>
     include <abstractions/bash>

     /usr/local/bin/lab333-reader   r,
     /usr/bin/bash                  ix,
     /usr/bin/cat                   ix,

     /srv/lab333/public/**          r,
     deny /srv/lab333/private/**    rwklx,

     owner @{HOME}/lab333/**        rw,

     capability,
     deny capability sys_admin,

     network inet stream,
     deny network inet dgram,
   }
   EOF
   ```

   > On Ubuntu 22.04 / Debian 12 use `abi <abi/3.0>,` — check `ls /etc/apparmor.d/abi/`.

6. Syntax-check before loading, then load in complain mode:

   ```bash
   sudo apparmor_parser -Q /etc/apparmor.d/usr.local.bin.lab333-reader && echo "syntax OK"
   sudo apparmor_parser -r /etc/apparmor.d/usr.local.bin.lab333-reader
   sudo aa-complain /etc/apparmor.d/usr.local.bin.lab333-reader
   sudo aa-status | grep -A2 'complain mode' | grep lab333
   ```

   ```
   syntax OK
   Setting /etc/apparmor.d/usr.local.bin.lab333-reader to complain mode.
      lab333-reader
   ```

7. Exercise it and read the audit records:

   ```bash
   /usr/local/bin/lab333-reader /srv/lab333/public/ok.txt /srv/lab333/private/key.txt
   sudo ausearch -m AVC -ts recent | grep apparmor | tail -n 3
   ```

   ```
   /srv/lab333/public/ok.txt: public
   /srv/lab333/private/key.txt: secrets

   type=AVC msg=audit(1756034041.117:822): apparmor="ALLOWED" operation="open"
     class="file" profile="lab333-reader" name="/srv/lab333/private/key.txt"
     pid=4417 comm="cat" requested_mask="r" denied_mask="r" fsuid=0 ouid=0
   ```

8. Switch to enforce and repeat:

   ```bash
   sudo aa-enforce /etc/apparmor.d/usr.local.bin.lab333-reader
   /usr/local/bin/lab333-reader /srv/lab333/public/ok.txt /srv/lab333/private/key.txt
   sudo ausearch -m AVC -ts recent | grep apparmor | tail -n 2
   ```

   ```
   Setting /etc/apparmor.d/usr.local.bin.lab333-reader to enforce mode.
   /srv/lab333/public/ok.txt: public
   /srv/lab333/private/key.txt: cat: /srv/lab333/private/key.txt: Permission denied

   type=AVC msg=audit(1756034102.556:830): apparmor="DENIED" operation="open"
     class="file" profile="lab333-reader" name="/srv/lab333/private/key.txt"
     pid=4462 comm="cat" requested_mask="r" denied_mask="r" fsuid=0 ouid=0
   ```

9. Confirm the confinement label on a live process, and run an arbitrary command under a profile:

   ```bash
   sudo aa-exec -p lab333-reader -- /bin/bash -c 'cat /proc/self/attr/current; cat /srv/lab333/private/key.txt'
   ```

   ```
   lab333-reader (enforce)
   cat: /srv/lab333/private/key.txt: Permission denied
   ```

10. Use the log-driven refinement loop:

    ```bash
    sudo aa-logprof
    ```

    ```
    Reading log entries from /var/log/audit/audit.log.
    Updating AppArmor profiles in /etc/apparmor.d.

    Profile:  lab333-reader
    Path:     /etc/lab333.conf
    New Mode: owner r
    Severity: unknown

     [1 - #include <abstractions/lab333>]
      2 - owner /etc/lab333.conf r,
    (A)llow / [(D)eny] / (I)gnore / (G)lob / Glob with (E)xt / (N)ew / Audi(t) / (O)wner permissions off / Abo(r)t / (F)inish
    ```

11. Compare the ways to stop enforcing a profile:

    ```bash
    sudo aa-disable /etc/apparmor.d/usr.local.bin.lab333-reader
    ls -l /etc/apparmor.d/disable/
    sudo apparmor_parser -R /etc/apparmor.d/usr.local.bin.lab333-reader   # unload only, not persistent
    sudo aa-enforce /etc/apparmor.d/usr.local.bin.lab333-reader           # re-enable
    ```

    ```
    Disabling /etc/apparmor.d/usr.local.bin.lab333-reader.
    lrwxrwxrwx 1 root root 44 Aug 24 12:31 usr.local.bin.lab333-reader -> /etc/apparmor.d/usr.local.bin.lab333-reader
    ```

12. Look at the modern userns restriction Ubuntu ships as an AppArmor profile:

    ```bash
    sysctl kernel.apparmor_restrict_unprivileged_userns
    unshare -Ur id 2>&1 | head -n 1
    ```

    ```
    kernel.apparmor_restrict_unprivileged_userns = 1
    unshare: unshare failed: Permission denied
    ```

### Checkpoint 10

- **Q10.1** — State the single most important architectural difference between AppArmor and SELinux, and derive from it two practical operational consequences (one advantage each).
- **Q10.2** — In step 5, `/usr/bin/cat ix,` gave `cat` inherit-execute. Explain the difference between `ix`, `Px`, `Cx` and `ux`, and say which one you would use for a helper that has its own profile.
- **Q10.3** — The profile denies `/srv/lab333/private/**`. Describe how a hard link could, in principle, defeat a path-based rule, and what AppArmor does about it.
- **Q10.4** — Explain the three ways to put a profile in complain mode, and which one survives an `apparmor_parser -r`.
- **Q10.5** — Distinguish `aa-disable`, `apparmor_parser -R`, and simply deleting the profile file, in terms of persistence and what the process runs as afterwards.
- **Q10.6** — `aa-genprof` and `aa-logprof` overlap. What does each add, and what workflow do they belong to? Why is complain mode a prerequisite for both being useful?
- **Q10.7** — In step 7, the AVC says `apparmor="ALLOWED"` and yet `denied_mask="r"` is populated. Reconcile those two fields.
- **Q10.8** — Compare `abstractions/`, `tunables/`, and `local/` under `/etc/apparmor.d/`. Which one should hold your site-specific additions to a distribution-shipped profile, and why?

---

## Exercise 11 — Smack, and choosing between the three

Smack is normally not the active LSM on RHEL or Ubuntu. Steps 1–2 run anywhere; steps 3–6 require a kernel booted with Smack as the major LSM and are marked as such.

### Steps

1. Determine which LSMs are active and in what order:

   ```bash
   cat /sys/kernel/security/lsm
   ls /sys/kernel/security/
   sudo cat /proc/cmdline
   ```

   ```
   lockdown,capability,landlock,yama,selinux,bpf,ipe
   apparmor  evm  integrity  ipe  lockdown  lsm  selinux  tpm0
   BOOT_IMAGE=/vmlinuz-5.14.0-503.el9.x86_64 root=/dev/mapper/rl-root ro rhgb quiet
   ```

2. Read the boot parameter that would select Smack instead:

   ```
   lsm=lockdown,capability,yama,smack
   ```

   Then rebuild the initramfs / update the bootloader and reboot. **Only one of SELinux, AppArmor and Smack can be the active major LSM on a stock kernel.**

3. *(Smack kernel only.)* Confirm smackfs and the current label:

   ```bash
   mount | grep smackfs
   ls /sys/fs/smackfs/
   cat /proc/self/attr/current
   ```

   ```
   smackfs on /sys/fs/smackfs type smackfs (rw,relatime)
   access  access2  ambient  change-rule  cipso  cipso2  direct  doi  ipv6host
   load  load2  logging  netlabel  onlycap  ptrace  relabel-self  revoke-subject
   syslog  unconfined
   _
   ```

4. *(Smack kernel only.)* Label an object and inspect the extended attribute:

   ```bash
   sudo mkdir -p /srv/lab333/smack
   echo 'tenant data' | sudo tee /srv/lab333/smack/f >/dev/null
   sudo chsmack -a TenantA /srv/lab333/smack/f
   sudo chsmack /srv/lab333/smack/f
   getfattr -m . -d /srv/lab333/smack/f
   ```

   ```
   /srv/lab333/smack/f access="TenantA"
   # file: srv/lab333/smack/f
   security.SMACK64="TenantA"
   ```

5. *(Smack kernel only.)* Load an access rule and test it:

   ```bash
   echo -n 'WebApp TenantA r--' | sudo tee /sys/fs/smackfs/load2
   cat /sys/fs/smackfs/load2 | grep TenantA
   sudo smackload --help 2>/dev/null | head -n 3
   ```

   ```
   WebApp TenantA r--
   ```

6. *(Smack kernel only.)* Note the other attributes and the special labels:

   ```
   security.SMACK64          label of the object
   security.SMACK64EXEC      label a process takes when it executes this file
   security.SMACK64MMAP      label required to mmap this file
   security.SMACK64TRANSMUTE directory: new objects inherit the directory's label
   security.SMACK64IPIN      label for data received on this socket
   security.SMACK64IPOUT     label for data sent from this socket

   _  floor    ^  hat    *  star    ?  unlabelled/wildcard    @  web
   ```

7. Build the comparison you will be tested on:

   | | SELinux | AppArmor | Smack |
   |---|---|---|---|
   | Model | TE + RBAC + MLS/MCS, label-based | Path-based profiles | Label-based, simplified |
   | Object identity | Extended attribute on the inode | Filesystem path at open time | Extended attribute on the inode |
   | Default distros | RHEL/Fedora/CentOS, Android | Ubuntu/Debian/openSUSE | Tizen, AGL, embedded/IoT |
   | Policy size | ~113k allow rules shipped | Per-application profile files | Handful of rules per label pair |
   | Filesystem relabel needed | Yes | No | Yes |
   | Modes | Enforcing / Permissive / Disabled (+ per-domain permissive) | Enforce / Complain / Kill / Unconfined (per profile) | Enforcing only |
   | Key config | `/etc/selinux/` | `/etc/apparmor.d/` | `/sys/fs/smackfs/`, xattrs |
   | Learning tools | `audit2allow`, `sealert` | `aa-genprof`, `aa-logprof` | none comparable |

### Checkpoint 11

- **Q11.1** — Why can only one of SELinux, AppArmor and Smack be active as the major LSM, and how do you determine which is active on a machine you have just been handed?
- **Q11.2** — State Smack's seven access rules in your own words (the ordered decision procedure the kernel applies). Which label makes a *subject* powerless, and which makes an *object* universally accessible?
- **Q11.3** — What does `security.SMACK64TRANSMUTE` on a directory accomplish, and which SELinux mechanism is its closest functional analogue?
- **Q11.4** — A customer runs an IoT appliance with ~15 processes and a read-only rootfs. Argue for Smack over SELinux for that platform, and give the one thing they lose.
- **Q11.5** — You must confine a single third-party binary on an Ubuntu server, with a two-day deadline and no policy-writing experience on the team. Which MAC system, and justify it with two properties from the comparison table.
- **Q11.6** — Both SELinux and Smack expose the process label via `/proc/self/attr/current`, and AppArmor uses the same file. What does that tell you about how these systems are integrated into the kernel?

---

## Answer key

<details>
<summary><b>Click to reveal all answers (Checkpoints 1–11)</b></summary>

### Checkpoint 1

**A1.1** — The kernel evaluates the two gates in sequence: the traditional DAC check (UID/GID, mode bits, ACLs) runs **first**, and only if it grants the access does the kernel invoke the LSM hook, where SELinux consults the loaded policy. In step 5, `cat` ran in the `unconfined_t` domain, which the targeted policy permits to read `var_t`, so both gates passed. In step 4 the reader was `httpd`, running in `httpd_t`, and no rule allows `httpd_t` to read `var_t` files — DAC passed, MAC denied, `open()` returned `EACCES`, and Apache translated that into HTTP 403. Both gates must grant; either can deny.

**A1.2** —
- `scontext` — the **source** context, i.e. the label of the process attempting the access (`system_u:system_r:httpd_t:s0`).
- `tcontext` — the **target** context, the label of the object being accessed (`unconfined_u:object_r:var_t:s0`).
- `tclass` — the **object class** (`file`, `dir`, `tcp_socket`, `process`, …), which determines the permission vocabulary that applies.
- `permissive=0` — the decision was **enforced**; the syscall actually failed. `permissive=1` means the access was logged but allowed (global permissive mode or a permissive domain).
The refused action is in the braces after `denied`: `{ getattr }`.

**A1.3** — The SELinux **user** field of a newly created object is inherited from the creating process, not from the Linux UID. `root`'s login was mapped to the SELinux user `unconfined_u` (see `semanage login -l`, `__default__` → `unconfined_u`), so files it creates get `unconfined_u`. `system_u` is reserved for objects created by system processes and for the default in `file_contexts`; a subsequent `restorecon -F` would reset it to `system_u`.

**A1.4** — Under DAC, the **owner of a resource decides** who may access it, and that decision is discretionary and unrestricted (`chmod 777` grants the world). Under MAC, an **administrator-defined, system-wide policy decides**, and no resource owner — not even root — can grant access the policy does not permit at runtime. `chmod 777` only widens the DAC gate; it writes nothing into the policy, so the MAC gate is untouched. Changing MAC requires changing labels or policy, which is itself an access-controlled operation.

### Checkpoint 2

**A2.1** —
- `getenforce` prints exactly one word — the **current runtime mode** (`Enforcing`/`Permissive`/`Disabled`).
- `selinuxenabled` prints nothing and communicates purely through exit status: `0` if SELinux is enabled, `1` if not. It is the only one designed for scripting (`if selinuxenabled; then …; fi`), because parsing `getenforce` output is fragile and both `Permissive` and `Enforcing` count as enabled.
- `sestatus` is the full report: runtime mode *and* config-file mode side by side (the only tool that shows the drift between them), the policy name, the SELinuxfs mount point, MLS status, `deny_unknown` handling, and the policy version.

**A2.2** — `setenforce` writes only to `/sys/fs/selinux/enforce`, a kernel runtime knob with no persistence. At boot, the init system reads `SELINUX=` from `/etc/selinux/config` and sets the mode from it. To persist, set `SELINUX=permissive` in that file. The trade-off is the point of the design: the runtime command is deliberately volatile so that an accidental or malicious `setenforce 0` is undone by a reboot, and so that troubleshooting cannot silently become a permanent posture change.

**A2.3** — With SELinux disabled, the kernel is not maintaining labels: every file written or modified while disabled has a stale or absent `security.selinux` xattr, and there is no policy loaded to switch modes in. `setenforce` therefore fails (`setenforce: SELinux is disabled`) because the transition Disabled→Enforcing is not a runtime operation. The procedure is:
1. Set `SELINUX=permissive` in `/etc/selinux/config` (**not** `enforcing` — go through permissive first).
2. **Create `/.autorelabel`** — this is the easy-to-forget step. Without it the system boots with a policy loaded but thousands of unlabelled or mislabelled files, and essential services fail in ways that can leave you unable to log in.
3. Reboot; init relabels the whole filesystem and reboots again.
4. Review the AVCs collected in permissive mode, fix them, then set `SELINUX=enforcing` and reboot.

**A2.4** —
- `enforcing=0` — SELinux initialises normally and the policy is loaded; only the enforcement decision is suppressed. **Labels continue to be maintained correctly** and every would-be denial is logged with `permissive=1`. This is the safe diagnostic parameter: you boot, collect the complete denial set, fix it, and reboot without it.
- `selinux=0` — SELinux is never initialised. No policy, no labelling. Any file created or modified during that boot ends up with a stale or missing label, so re-enabling later requires a full filesystem relabel. It also produces zero diagnostic information: you learn that the machine boots without SELinux, not *which* denial was the problem.
Use `enforcing=0` for diagnosis; reserve `selinux=0` for the case where the SELinux subsystem itself is what prevents boot.

**A2.5** — `deny_unknown` controls what the kernel does with object classes and permissions that the *kernel* knows about but the *loaded policy* does not define — typically after a kernel upgrade brings new hooks that the policy package has not caught up with. `allowed` means such unknown permissions are permitted (fail-open, prioritising availability); `denied` means they are refused (fail-closed, more secure but can break newly-introduced kernel functionality with no corresponding rule). It is set in `/etc/selinux/semanage.conf` (`handle-unknown=`) and requires a policy rebuild.

### Checkpoint 3

**A3.1** — `user:role:type:level` — SELinux user, role, type (called the *domain* when it labels a process), and the MLS/MCS level or range. In the `targeted` policy virtually every decision is a Type Enforcement decision, so the **type** field carries the enforcement. The **role** restricts which types a subject may transition into (RBAC), the **user** restricts which roles are reachable, and the **level** is used almost exclusively for MCS category separation (containers, sVirt, `chcat`) rather than true multi-level security.

**A3.2** — `chcon` writes the label directly to the inode's `security.selinux` extended attribute; it does not touch the policy's file-context database. `restorecon` reads the *policy's* specification (`file_contexts` plus `file_contexts.local`) and resets the label to whatever the policy says the path should be — which, having never been told about `/srv/lab333`, was still `var_t`. Any relabel event undoes `chcon`: an explicit `restorecon`, `fixfiles`, `/.autorelabel`, or a package operation that relabels its files. **Rule of thumb:** `chcon` is for temporary experiments and for confirming a hypothesis before writing the real rule; `semanage fcontext -a` + `restorecon` is the only durable form.

**A3.3** —
- `cp` creates a **new inode**. New objects get the label the policy's type-transition rules specify for that parent directory and creating domain — here, `httpd_sys_content_t` from the fcontext rule inherited via the directory. This is the "correct" behaviour and the reason `cp` is usually what you want.
- `cp -a` implies `--preserve=all`, which includes the SELinux context, so it explicitly copies the source label (`user_tmp_t`) onto the new inode, defeating the transition.
- `mv` within the same filesystem is a **rename**: no new inode is created, so the existing xattr moves with it unchanged (`user_tmp_t`). This is the classic cause of "I moved my site into DocumentRoot and got 403" and the reason `restorecon -R` should follow every `mv` into a labelled tree. (`mv` *across* filesystems degrades to copy+unlink and behaves like `cp`.)

**A3.4** —
- `restorecon` — specification comes from the **active default** (`file_contexts` + `file_contexts.local` for the current policy); scope is the paths you name (`-R` for recursive, `-v` verbose, `-n` dry run, `-F` forces the user and role fields too, not just the type).
- `setfiles` — you pass the **specification file explicitly** as the first argument. It is the primitive used at install and relabel time when there is no active policy to consult, e.g. from an installer or rescue environment.
- `fixfiles` — a shell wrapper around `setfiles`/`restorecon` that adds **system-level scopes**: `fixfiles check` (report only), `fixfiles relabel` (everything, with a `/tmp` warning), `fixfiles -R <pkg> restore` (every path owned by an RPM), `fixfiles -F onboot` (schedules a full relabel at next boot by creating `/.autorelabel`).
"One directory tree I just added a rule for" → `restorecon -Rv`. "Whole system after SELinux was disabled" → `fixfiles -F onboot` (or `touch /.autorelabel`) then reboot.

**A3.5** — No, and no. `semanage fcontext -a` only appends a rule to `file_contexts.local` in the policy store; it does not touch a single inode. Labels on disk are unchanged, so the running system behaves identically. A reboot changes nothing either — the kernel reads xattrs, not the fcontext database, at access time. The rule takes effect only when something relabels the files: `restorecon`, `fixfiles`, or a full relabel. This asymmetry is the single most common cause of "I ran the semanage command from the docs and it still doesn't work."

**A3.6** — `-e` creates an **equivalency** (substitution) rule: it tells the labelling machinery to treat `/srv/lab333/html` as if it were `/var/www/html`, so the *entire* set of rules that applies to the target path — including subdirectory-specific rules like `cgi-bin` → `httpd_sys_script_exec_t` — applies to the new path. `-t` sets a single flat type for everything matching one regex. Prefer `-e` when you are relocating a whole service's directory tree that the shipped policy already labels in a fine-grained way (a moved `/var/www`, `/home`, or `/var/lib/mysql`); prefer `-t` for a new tree of your own with uniform content. Equivalencies are listed with `semanage fcontext -l -e`.

### Checkpoint 4

**A4.1** —
- **Type** — the third context field; an abstract security label attached to any object (files, sockets, ports, keys, processes). Types have no inherent meaning; the policy's rules give them meaning.
- **Domain** — the same thing, but the word used when the type labels a *process*. `httpd_t` is a domain when it labels a running Apache and a type when discussed abstractly. The distinction is conventional, not structural — SELinux deliberately unified subjects and objects under a single type namespace.
- **Entrypoint** — a permission on the `file` class. A domain may only be entered by executing a file whose type the domain holds `entrypoint` on. `httpd_t` has `entrypoint` on `httpd_exec_t`, so the only way into the `httpd_t` domain is by executing something labelled `httpd_exec_t`.

**A4.2** —
1. `allow <source_domain> <exec_type>:file execute;` — without it the source process simply cannot run the binary at all. Prevents a domain from launching programs outside its remit.
2. `allow <source_domain> <target_domain>:process transition;` — without it the exec succeeds but the process stays in the *old* domain, which usually means an unexpected privilege level. Prevents an arbitrary domain from spawning a privileged domain.
3. `allow <target_domain> <exec_type>:file entrypoint;` — without it nothing can ever enter the target domain through that binary. This is the crucial one: it means an attacker who plants a malicious binary cannot get it to run as `httpd_t`, because their binary will not carry `httpd_exec_t`. It binds a domain to a specific, labelled, on-disk program.
(A fourth element, `type_transition`, makes the transition *automatic*; without it the transition must be requested explicitly, e.g. by `setexeccon()` or `runcon`.)

**A4.3** — `runcon` sets the context for a **new process at exec time**; the targeted policy allows `unconfined_t` to transition into most domains, so the request succeeds. `newrole` changes the **role of your current login session**, re-authenticating you first — it is the SELinux analogue of `su` for roles, and it requires that your *SELinux user* be authorised for the requested role. On a targeted system your login maps to `unconfined_u`, which is authorised for `unconfined_r` and `system_r` but not `sysadm_r`, so the request is refused. Essentially: `runcon` operates in the TE dimension on a child process, `newrole` operates in the RBAC dimension on your session.

**A4.4** — TE is what actually denies: every access decision is ultimately "is there an `allow <stype> <ttype>:<class> <perm>` rule?" RBAC is a **constraint layer on top**: the policy declares which roles a given SELinux user may assume (`semanage user -l`) and which types each role may be associated with (`role httpd_r types httpd_t;`). A process cannot enter a domain unless its current role is authorised for that type, so RBAC limits the *reachable set* of domains rather than deciding individual file accesses. In `targeted`, RBAC is largely vestigial for system services (everything lands in `system_r`); it does real work in confined-user setups (`user_r`, `staff_r`, `sysadm_r`).

**A4.5** — SELinux policy makes heavy use of **attributes**: a rule may be written against an attribute such as `httpdcontent` or `port_type`, and every type bearing that attribute inherits the rule. `sesearch -A` expands attributes by default so you see the *effective* permission set, which is what you usually want when answering "can this domain do this?". Use `-d` / `--direct` to restrict output to rules literally written with that type, which is what you want when you are trying to find the source line to patch.

**A4.6** — It gets whatever domain the transition rules produce for `/usr/local/bin/httpd`'s label — which will be `bin_t` (the default for `/usr/local/bin`), not `httpd_exec_t`. There is no `type_transition init_t bin_t:process httpd_t`, so the process runs in `init_t` — systemd's own, highly privileged domain — rather than in the tightly confined `httpd_t`. Nothing in policy changed, but the practical result is that the web server, the most exposed process on the box, is now running effectively unconfined. This is exactly why the entrypoint mechanism ties a domain to a *labelled* binary, and why `restorecon` after moving service binaries is a security operation, not housekeeping.

### Checkpoint 5

**A5.1** — The pair is `(current , default)` — the value in effect right now, and the value stored persistently in the policy store. `(on , off)` means the boolean is currently on, but nothing has been written to the store, so a reboot returns it to `off`. This pair is how you detect drift between what someone did with `setsebool` during an incident and what the machine will actually do tomorrow. `semanage boolean -l -C` lists only booleans whose stored value differs from the policy default — the effective "what has been customised here" report.

**A5.2** —
- `setsebool <bool> on|off` — sets an explicit value, **runtime only**, lost at reboot. Effect is immediate.
- `setsebool -P <bool> on|off` — sets an explicit value and commits it to the policy store, so it survives reboot. It rebuilds and reloads the policy, so it is noticeably slower (seconds).
- `togglesebool <bool>` — **flips** whatever the current value is, runtime only, and has no persistent form. Because it does not take a target value, running it twice is a no-op and running it from a script whose prior state you do not know is non-deterministic. Prefer `setsebool` in automation.

**A5.3** — Two values separated by a space: **current** value and **pending** value. `0 1` means the boolean is currently off but a change to on has been staged and not yet committed. Writes to `/sys/fs/selinux/booleans/<name>` stage a change; writing `1` to `/sys/fs/selinux/commit_pending_bools` applies all pending changes atomically. `setsebool` performs both steps for you.

**A5.4** — (1) The boolean was written by the policy authors, who scoped the conditional rules to exactly the permissions that feature needs, and it is reviewed and maintained across policy updates; a hand-written module reflects only the denials you happened to trigger during testing, and nobody revisits it. (2) A boolean is self-documenting and discoverable — `semanage boolean -l` shows its description, and `sesearch -b` shows exactly which rules it gates — so the next engineer can see why the system is configured this way; a custom `.pp` in `/root` is invisible to anyone who does not run `semodule --list=full`. A third reason: booleans are portable via `semanage export`, survive policy package upgrades cleanly, and cannot introduce syntax that conflicts with a future policy version.

**A5.5** — `httpd_can_network_connect` grants outbound connections to **every port type in the policy** — SSH, database ports, LDAP, everything. If Apache is compromised, it becomes a general-purpose pivot into the internal network. Labelling one port instead (`semanage port -a -t http_port_t -p tcp 9999`) grants outbound access only to that specific port number, so a compromised Apache can reach the one backend it was supposed to reach and nothing else. The boolean is the convenient answer; the port label is the correct one. Where a purpose-specific boolean exists — `httpd_can_network_connect_db`, `httpd_can_network_relay`, `httpd_can_connect_ldap` — prefer it over the general one.

### Checkpoint 6

**A6.1** — `CAP_NET_BIND_SERVICE` satisfies the *DAC-equivalent* check for binding a privileged port; it is a capability check, evaluated before the LSM hook. SELinux then applies an independent check on the `name_bind` permission for the `tcp_socket` class, matching the domain against the **port's** type. Port 8088 was `unreserved_port_t`, and `httpd_t` holds `name_bind` only on `http_port_t` (and a few others). Capabilities are a refinement of DAC — they subdivide root's power — and are subject to MAC just like everything else. Having every capability in the world does not create an allow rule.

**A6.2** —
```bash
sudo semanage port -l | grep -w 3307        # is it already defined, and under what type?
sudo semanage port -a -t mysqld_port_t -p tcp 3307
```
If the grep shows the port already assigned to another type, `-a` will fail with `ValueError: Port tcp/3307 already defined` and you must use `-m` to reassign it — which you should think about first, because you are taking the port away from whatever service the policy assigned it to.

**A6.3** — `-a` **adds** a new local definition and refuses if the port number/protocol is already defined anywhere in the policy (shipped or local). `-m` **modifies** an existing definition, reassigning the port to a different type. The error `ValueError: Port tcp/80 already defined` tells you to use `-m`; the error `ValueError: Port tcp/8088 is not defined` tells you to use `-a`. `-d` deletes a local definition and restores the shipped one.

**A6.4** —
1. **Linux user → SELinux user**: `semanage login`. Consulted by PAM (`pam_selinux`) at login time. `__default__` catches everything unmapped.
2. **SELinux user → roles (and MLS range)**: `semanage user`. Declares which roles an SELinux user may assume and the clearance range they get.
3. **Role → types/domains**: fixed by the policy's `role … types …` declarations; changed only by writing and installing a policy module, not by `semanage`.
The runtime hop **domain → domain** is the type transition from Exercise 4, also policy-defined.

**A6.5** — `user_u`'s only role is `user_r`, whose associated domain `user_t` is not permitted the `setuid`/`setgid` capabilities or the transition to `sysadm_t` that `sudo -i` needs. The block came from MAC, not from `sudoers`. The difference is significant: removing `kiosk` from `wheel` is a DAC/`sudoers` change that `kiosk` might undo if it ever obtained root by another route (a setuid bug, a misconfigured service), whereas the SELinux confinement means that even a process that *becomes* UID 0 remains in `user_t` and still cannot do what `user_t` may not do. That is the whole argument for confined users: it constrains what root-equivalence is worth.

**A6.6** — `semanage export` captures the **local customisations recorded in the policy store**: modified booleans, fcontext rules, port assignments, login mappings, interface and node contexts, permissive domains. It deliberately does **not** capture installed policy modules (`.pp`/`.cil` files — you must copy and `semodule -i` those separately), nor the on-disk labels themselves (a `semanage import` on the new host still needs a `restorecon`/`fixfiles` run). When rebuilding a host, `semanage export`/`import` gets you the configuration but you must additionally: reinstall custom modules, and relabel. Forgetting the relabel reproduces the Exercise 3 trap at whole-system scale.

### Checkpoint 7

**A7.1** —
- `ausearch` — a **log query tool**. It parses `/var/log/audit/audit.log`, filters by message type, time, command, key, PID, and with `-i` resolves numeric fields to names. It knows nothing about policy.
- `audit2why` — takes AVC records on stdin and explains **why** the access was denied: missing TE rule, boolean off, constraint violation, dontaudit, unknown permission, permissive domain. It must **load the current policy** (`/sys/fs/selinux/policy`) to answer, because "there is no rule for this" and "there is a rule but a boolean turns it off" are indistinguishable from the log alone. It is the same binary as `audit2allow -w`.
- `audit2allow` — takes AVC records and **emits the allow rules** that would have permitted them, optionally packaging them as a loadable module with `-M`. It is a transcription tool: it does not reason about whether the access *should* be allowed.

**A7.2** — Other `audit2why` verdicts and why generated rules would be wrong:
- **"One of the following booleans was set incorrectly"** — the rule exists but is gated off. The fix is `setsebool -P`; installing a duplicate unconditional allow rule bypasses the boolean and permanently removes an administrator's ability to turn the feature off.
- **"Constraint violation"** — the denial came from an MLS/MCS or RBAC constraint, which allow rules cannot override. The generated module installs cleanly and changes nothing, wasting an outage window (see A9.3).
- **"Access was denied by a dontaudit rule"** (seen after `semodule -DB`) — the policy authors deliberately marked this access as expected-and-harmless noise. Allowing it grants real privilege to silence a message that was never a symptom.
- **"Missing or disabled TE allow rule" / permissive-domain records (`permissive=1`)** — the access already succeeded; the record documents what *would* have been denied. Feeding these into `audit2allow` without review is how you end up granting the full set of accesses an application attempted during a fuzz test.

**A7.3** — Ask: *is the domain doing something legitimate to an object that is wearing the wrong label, or is it doing something the policy authors decided it should not do?* If the object is mislabelled — content in a non-standard directory, a file created by `mv`, a database moved to a new volume — the correct fix is a label change (`semanage fcontext` + `restorecon`), because the shipped policy already contains the right rules for the right type and you gain them all for free, forever, across upgrades. Only when the required access has **no** corresponding shipped type or boolean — a genuinely novel integration between two confined services — is a custom module correct. In practice, well over 90% of production denials are labelling problems.

**A7.4** — 400 is the module's **priority**. `semodule -i` installs at priority 400 by default; modules shipped by the distribution's policy package live at priority **100**. When two modules share a name, the one with the highest priority wins. To override a shipped module, install your modified version at any priority above 100 — `sudo semodule -X 400 -i apache.pp` — and remove it with the matching priority (`semodule -X 400 -r apache`) to fall back to the distribution's version. This is why `semodule --list=full` is more useful than plain `semodule -l`: only the full listing shows priorities and the language (`pp` vs `cil`).

**A7.5** — (1) **Blast radius.** `setenforce 0` disables enforcement for every domain on the machine, so during the diagnostic window nothing at all is confined; a permissive domain leaves the other several thousand domains enforcing, so a compromise of an unrelated service is still contained. (2) **Signal-to-noise.** With global permissive you collect AVCs from every process on the box and must filter; with a permissive domain the log contains essentially only the records you care about, each marked `permissive=1`. A third: `semanage permissive` is recorded in the policy store, so `semanage permissive -l` shows an auditor exactly which domains are unconfined and `semanage export` carries it — an interactive `setenforce 0` leaves no trace at all.

**A7.6** — A `dontaudit` rule **suppresses the audit record** for a denial without allowing it. The policy ships thousands because many applications routinely probe for things they do not need — walking `/proc`, stat-ing files to see if they exist, trying `ioctl`s on the wrong kind of fd — and logging every one would bury real denials. The scenario where `semodule -DB` is the only way forward: **an application fails, but `ausearch` shows no AVC at all.** The denial exists; it is simply being hidden. `semodule -DB` rebuilds and reloads the policy with all dontaudit rules disabled, you reproduce the failure, and the record appears. Afterwards you **must** run `semodule -B` to restore them — leaving dontaudit disabled floods the audit log, can fill the disk, and on a busy host degrades performance measurably.

**A7.7** — (1) **Time window**: `-ts today` sweeps up every denial from every domain since midnight, including unrelated services and any probing an attacker did. The module will contain allow rules the engineer never looked at, granting access far beyond the incident. Use `-ts recent` (last 10 minutes) or a precise timestamp, and always scope with `-c <comm>` or the source context. (2) **No review step**: `&& semodule -i` installs without anyone reading the `.te`. `audit2allow` will happily emit `allow httpd_t shadow_t:file read;` if that denial is in the log — which is precisely the access an attacker would generate. Always run `audit2allow` without `-M` first, read the rules, and only then package. (3) **Wrong tool for the cause**: the runbook does not consult `audit2why`, so it applies allow rules to problems that are labelling errors, boolean settings, or constraint violations — permanently degrading the policy to work around something that had a correct one-line fix, and in the constraint case not fixing anything at all. A fourth: repeated over months, this produces a stack of overlapping unnamed modules nobody can safely remove.

### Checkpoint 8

**A8.1** —
- `.te` (+ `.if`, `.fc`) → `.mod`: **`checkmodule -M -m -o out.mod in.te`** compiles the type-enforcement source into a binary policy module. `-m` selects module (not base) mode; `-M` enables MLS/MCS support, which is mandatory on a targeted policy.
- `.mod` + `.fc` → `.pp`: **`semodule_package -o out.pp -m out.mod -f out.fc`** bundles the binary module with the file-context specification into a **p**olicy **p**ackage.
- `.pp` → loaded policy: **`semodule -i out.pp`** inserts the package into the policy store under `/var/lib/selinux/<policytype>/active/modules/<priority>/`, then rebuilds the complete binary policy and loads it into the kernel.
`make -f /usr/share/selinux/devel/Makefile foo.pp` performs the first two steps and additionally runs the M4 macro expansion that gives you access to reference-policy interfaces such as `files_type()` and `apache_content_template()`.

**A8.2** — `require { }` declares the identifiers the module **uses but does not define** — types, classes, permissions, roles, attributes and booleans that live in the base policy or in other modules. It is the module system's import declaration: it tells the compiler these symbols will be resolved at link time. Referencing `httpd_t` without requiring it fails at compile time with `unknown type httpd_t` (or, worse in older toolchains, is interpreted as an attempt to *declare* a new type of that name, silently producing a module that grants access to a type nothing else uses). Note that `audit2allow` generates the `require` block for you — one of its genuine strengths.

**A8.3** — The `.fc` file adds a rule to the policy's file-context database saying "paths matching `/srv/lab333/spool(/.*)?` should be labelled `lab333_spool_t`". Installing the module writes that rule into the store; it does not touch any inode (same asymmetry as A3.5). `restorecon` is what reads the rule and applies the label. Without the relabel, the directory would have kept `var_t`, the new type `lab333_spool_t` would exist in the policy but label nothing, and every rule in the module would be dead code — the denial would be identical to before, which is a maddening thing to debug because `semodule --list` confirms the module is installed.

**A8.4** — **CIL** (Common Intermediate Language) is the native input language of the modern SELinux policy compiler. Since userspace 2.4, `semodule` compiles `.pp` files into CIL via a high-level-language plugin (`/usr/libexec/selinux/hll/pp`) and then compiles CIL into the binary kernel policy. So `.pp` is now a legacy front-end format, retained for compatibility, and CIL is the real interface: it can be installed directly (`semodule -i foo.cil`), it is what tools like `udica` and `container-selinux` generate, and it exposes features the `.te`/`m4` toolchain cannot express (namespaces, inheritance, `deny` rules). Practically: keep using `.te` for hand-written policy because the reference-policy interface library is enormous and only available there, but expect generated policy and future tooling to be CIL, and know that `semodule -c -E <module>` lets you read any installed module as CIL.

**A8.5** —
- **New private type** — the domain gets exactly the access to exactly this data, and nothing else on the system shares the label. If Apache is compromised, the attacker reaches this spool and no other web content. It also makes the intent auditable: `sesearch -A -t lab333_spool_t` shows the complete list of who may touch it. Cost: you own the module forever, including across policy upgrades.
- **Reuse `httpd_sys_rw_content_t`** — zero maintenance, it is already correct, every shipped rule and boolean that governs writable web content applies automatically, and the next engineer recognises the label instantly. Cost: everything else on the box labelled `httpd_sys_rw_content_t` — every other vhost's upload directory — is now in the same equivalence class as your data.
Rule of thumb: reuse the shipped type unless you have a specific isolation requirement between two things that would otherwise share a label. For multi-tenant separation, MCS categories (Exercise 9) are usually a better answer than a new type.

**A8.6** — `files_type()` is a reference-policy interface that assigns the standard file attributes (`file_type`, `non_security_file_type`, and related) to your new type. Enormous numbers of shipped rules are written against those attributes rather than against individual types — the rules that let administrators relabel the file, that let backup and filesystem-maintenance domains read it, that let `restorecon` operate on it, that exempt it from the security-file constraints. A bare `type lab333_spool_t;` produces a type that is in *no* attribute, so it inherits *no* rule: the directory becomes unreadable by every domain including `unconfined_t`, `restorecon` may be unable to relabel it, and backups silently fail. It is the classic first mistake in hand-written policy, and the symptom — "even root can't touch it and I can't relabel it back" — is alarming out of proportion to the one-line cause.

### Checkpoint 9

**A9.1** — **MLS** (Multi-Level Security) implements a Bell–LaPadula-style hierarchy of *sensitivities* (`s0` < `s1` < `s2` …) with dominance rules — no read up, no write down — and is what the `mls` policy type provides for environments with formal classification levels. **MCS** (Multi-Category Security) uses only the *category* portion of the same field, with no hierarchy: categories are flat, unordered compartments, and a subject may access an object only if the subject's category set is a superset of the object's. `sestatus`/`seinfo` on `targeted` shows **1 sensitivity** and 1024 categories — a single-sensitivity policy is by definition not doing multi-*level* security. `targeted` uses the MLS machinery purely as MCS.

**A9.2** — An MLS/MCS **constraint** (`mlsconstrain`), not a type rule. Constraints are a separate policy construct: they are boolean expressions over context fields (`l1 dom l2`, `u1 == u2`, `r1 == r2`) that must hold *in addition to* an allow rule. The architecture is: an access is permitted only if an allow rule exists **and** every applicable constraint is satisfied. Type rules are additive and can be extended by any module; constraints are declarative restrictions on the whole policy and can only be changed in the base policy. That is why a constraint denial is a fundamentally different kind of failure from a missing allow rule.

**A9.3** — `audit2allow` reads the AVC and mechanically emits `allow unconfined_t var_t:file read;` — a rule which, on the targeted policy, **already exists**. The generated module compiles, `semodule -i` succeeds, `semodule --list=full` shows it loaded, and the access is still denied, because the denial never came from the type dimension. This produces the worst kind of troubleshooting failure: every action reports success and nothing changes. The tell is `audit2why` reporting "Constraint violation" and the AVC showing scontext and tcontext with *different level fields but identical types*. The real fixes are to change the object's categories (`chcat`), change the subject's range (`semanage login -r` / `semanage user -r`), or run the subject at an appropriate level (`runcon -l`).

**A9.4** — **Dominance**: a range `low-high` dominates a level if the level's sensitivity is within `[low, high]` **and** the range's category set is a superset of the level's category set. A subject may read an object only if the subject's clearance dominates the object's level.
- `s0` — yes (same sensitivity, empty category set is a subset of anything).
- `s0:c5` — yes (`c5` ∈ `c0.c1023`).
- `s0:c1024` — no (categories run `c0`–`c1023`; `c1024` is outside the range and is in fact an invalid category on a 1024-category policy).
- `s1:c5` — no (`s1` exceeds the range's high sensitivity `s0`; also `s1` does not exist in a single-sensitivity targeted policy).

**A9.5** — Both containers run in the same type, `container_t`, so Type Enforcement alone would allow either to touch the other's files. The container runtime assigns each container a **unique random pair of categories** (`c214,c806` vs `c455,c1002`) and labels that container's writable layer and `:Z` volumes with the same pair. The MCS constraint then requires the accessing process's category set to be a superset of the object's — and neither container's pair is a superset of the other's, so the accesses are denied by constraint even though the types match perfectly. This is MCS doing exactly what it was designed for: N mutually-isolated instances of one confined type without writing N policies.
`--security-opt label=disable` runs the container as `spc_t` (super-privileged container) with no category pair. The container is then unconfined by SELinux: a container escape has whatever access `spc_t` has, and the MCS isolation from every other container is gone. It is the container equivalent of `setenforce 0` for that one workload.

**A9.6** —
- **`:z`** (lowercase) — relabel the volume content with a **shared** label (`container_file_t:s0`, no categories), so *multiple* containers can use it.
- **`:Z`** (uppercase) — relabel with the **private** label of this specific container, including its unique category pair, so only that container may use it.
Both perform a **recursive relabel of the host directory**. Pointing `:Z` at a directory the host also uses — `/var/lib/mysql` belonging to a host MariaDB, `/home`, or worst of all `/` or `/usr` — recursively rewrites the labels of every file underneath, breaking the host service (which now cannot read its own data) and potentially requiring a full `restorecon` or `/.autorelabel` to recover. Use `:Z` only on directories created specifically for the container.

### Checkpoint 10

**A10.1** — **SELinux mediates on labels attached to inodes; AppArmor mediates on filesystem paths.**
- Advantage of AppArmor: no filesystem relabelling is ever required. Profiles are readable text naming real paths, so you can deploy a confinement policy to an existing system without touching a single file's metadata, and a profile can be reviewed by someone who has never studied the policy language. Nothing is ever "mislabelled".
- Advantage of SELinux: the label travels with the inode, so confinement cannot be circumvented by reaching the same data through a different name — a bind mount, a symlink, an alternate mount point, or a hard link. It also means SELinux can label objects that have no path at all (sockets, ports, IPC, keys, processes), which is why it can express things AppArmor cannot, such as "this domain may bind only this TCP port".

**A10.2** —
- `ix` — **inherit execute**: the new program runs under the *current* profile. Correct for trivial helpers (`cat`, `sed`) that you want constrained exactly as the parent is.
- `Px` — **discrete profile execute**: transition to the helper's *own* profile; if no profile exists, execution is **denied**. This is the right answer for a helper that has its own profile — it is fail-closed.
- `Cx` — **child profile execute**: transition to a child profile defined inline inside the current profile (`profile /usr/bin/helper { … }`). Use when the helper needs a different confinement but does not warrant a top-level profile.
- `ux` — **unconfined execute**: the new program runs with **no** confinement at all. Almost always wrong; it is an escape hatch and an audit finding.
(Lowercase `px`/`cx`/`ux` are the same transitions but *without* scrubbing the environment; the uppercase forms sanitise `LD_PRELOAD` and friends and should be preferred. `pix`/`Pix` mean "use the profile if one exists, otherwise inherit" — convenient but fail-open.)

**A10.3** — AppArmor's rules match the path used in the `open()` call. If a file under `/srv/lab333/private/` also had a hard link at `/srv/lab333/public/key.txt`, the confined process could open it via the permitted path and read the same inode — the deny rule names a path, and the process did not use it. AppArmor mitigates this with the **link subset test**: creating a link (`l` permission) is only allowed if the target name's permissions are a **subset** of the source name's, so a confined process cannot manufacture a more-permissive alias for a file it can already reach. That protects against the confined process creating the link, but not against a link that already exists or that an unconfined process creates. The defence is to audit the filesystem layout, keep sensitive data on separate filesystems (hard links cannot cross them), and prefer `owner` qualifiers and tight globs. SELinux is immune to this class by construction, since the label is on the inode.

**A10.4** —
1. `aa-complain /etc/apparmor.d/<profile>` — inserts `flags=(complain)` into the profile file and reloads it. **Persistent**, survives `apparmor_parser -r` and reboot, because the flag is in the source.
2. Editing the profile by hand to add `flags=(complain)` after the profile name, then `apparmor_parser -r`. Identical result; `aa-complain` is a wrapper for it.
3. `aa-complain` on a *running* profile name rather than a file path (`aa-complain lab333-reader`) or writing to `/sys/kernel/security/apparmor/.access` — changes the loaded profile only. **Not persistent**; a reload from the on-disk file restores enforce mode.
So (1) and (2) — the same thing — survive `apparmor_parser -r`; only the in-memory form does not. The reverse operations are `aa-enforce` and `aa-audit` (enforce plus log every allowed access, useful for auditing a profile you believe is correct).

**A10.5** —
- **`aa-disable`** — unloads the profile *and* creates a symlink in `/etc/apparmor.d/disable/`, which the init script honours, so the profile stays unloaded across reboots. Persistent, reversible with `aa-enforce` (which removes the symlink). Processes run **unconfined**. This is the supported way to turn a profile off.
- **`apparmor_parser -R <file>`** — removes the profile from the kernel *now*. Not persistent: the boot-time load reinstates it. Running processes that were confined by it become unconfined immediately.
- **Deleting the profile file** — persistent, but destroys your work and any local customisations; the profile is gone at next boot, and if the file came from a package, the next package update silently restores it, re-confining the application at an unpredictable moment. Never the right answer.
In all three cases already-running processes lose confinement (AppArmor does not kill them), which matters if you are disabling a profile in response to an incident.

**A10.6** —
- **`aa-genprof <program>`** — the *bootstrap* tool. It creates a skeleton profile (like `aa-autodep`), puts it in complain mode, and then prompts you to run the program while it watches the log, entering the interactive rule-approval loop when you press `S`. Use it when there is no profile at all.
- **`aa-logprof`** — the *refinement* tool. It scans the audit log for entries relating to **any** loaded profile and walks you through the same interactive loop for each unmatched access. Use it after a profile exists and the application has been exercised — e.g. after a week in complain mode in staging, or after an application upgrade added new file accesses.
Both depend on complain mode because in enforce mode the accesses are **denied**, so the application takes an error path and never reveals what it would have done next. You learn the first denial and nothing after it. In complain mode the access is allowed and logged, so a single full exercise of the application produces the complete access set in one pass. The standard workflow is: `aa-genprof` → complain → exercise thoroughly in staging → `aa-logprof` → `aa-enforce` → monitor for `DENIED` in production.

**A10.7** — `apparmor="ALLOWED"` is the **outcome**: the profile is in complain mode, so the syscall succeeded. `denied_mask="r"` is the **decision the profile's rules produced**: read access is not granted by any rule, so in enforce mode this would have been refused. Complain mode reports both — what the policy says and what actually happened — which is exactly the information `aa-logprof` needs. The equivalent in SELinux is an AVC with `permissive=1`: the `denied { … }` list is still populated, and the access still succeeded. In both systems, "learning mode" records the counterfactual.

**A10.8** —
- **`abstractions/`** — reusable rule fragments for common patterns (`base`, `bash`, `nameservice`, `ssl_certs`, `python`, `user-tmp`). Included with `include <abstractions/base>`. They exist so that every profile does not re-derive the twenty rules needed to load libc and read `/etc/nsswitch.conf`.
- **`tunables/`** — variable definitions (`@{HOME}`, `@{PROC}`, `@{run}`, `@{multiarch}`) that profiles expand. Included via `include <tunables/global>` at the top of essentially every profile. Editing a tunable changes behaviour across all profiles at once — for example adding a non-standard home directory location to `@{HOMEDIRS}`.
- **`local/`** — one file per profile, named after it, and `include <local/usr.sbin.nginx>` appears at the **end** of the shipped profile. This is where site-specific additions belong, because package upgrades replace the main profile file and will silently discard edits made directly in it, while `/etc/apparmor.d/local/*` is preserved. Putting your rules there is the difference between a customisation that survives `apt upgrade` and one that vanishes during a routine patch window.

### Checkpoint 11

**A11.1** — SELinux, AppArmor and Smack are all "major" LSMs: each maintains its own security label on the same kernel objects and hooks the same decision points, and the label storage (`security.*` xattrs, `/proc/*/attr/current`) and the semantics of a denial were historically exclusive — a stock kernel initialises exactly one of them. (Minor LSMs — `capability`, `yama`, `lockdown`, `landlock`, `bpf`, `integrity` — have stacked since Linux 5.1, and full major-LSM stacking has been in development for years but is not the default anywhere.) To determine what is active: `cat /sys/kernel/security/lsm` lists the initialised LSMs in order; `ls /sys/kernel/security/` shows a directory for whichever is active; and the specific probes are `sestatus`/`getenforce`, `aa-status`, and `mount | grep smackfs`. The boot-time selector is the `lsm=` kernel parameter (older kernels: `security=`).

**A11.2** — The kernel applies these in order (from `Documentation/admin-guide/LSM/Smack.rst`):
1. Any access requested by a subject labelled `*` is **denied**. (`*` is the powerless subject label.)
2. A read or execute requested by a subject labelled `^` is **permitted**. (`^`, the "hat", is the universal reader.)
3. A read or execute requested on an object labelled `_` is **permitted**. (`_`, the "floor", is the default label everything starts with, and is universally readable.)
4. Any access requested on an object labelled `*` is **permitted**. (`*` as an *object* label is universally accessible.)
5. Any access where subject and object labels are **identical** is permitted.
6. Any access explicitly present in the loaded rule set is permitted.
7. Everything else is **denied**.
So `*` makes a *subject* powerless (rule 1) and an *object* universally accessible (rule 4) — the same label, opposite meanings depending on which side of the access it sits.

**A11.3** — `SMACK64TRANSMUTE` set on a directory means that objects **created inside it inherit the directory's label** rather than the creating process's label — provided a rule grants the subject `t` (transmute) access. Without it, Smack's default is that a new file takes the label of the process that created it, which is wrong for shared spool and data directories where the *location* should determine the label. Its closest SELinux analogue is the **type transition on file creation** (`type_transition domain_t dir_t:file new_t;`), which likewise makes the parent directory rather than the creating domain determine a new object's type — the mechanism behind `httpd_t` creating files as `httpd_sys_rw_content_t` in a writable web directory.

**A11.4** — Smack's argument for that platform: the policy is small enough to read in full. With ~15 processes you need perhaps a dozen labels and a few dozen rules, all expressible in a text file loaded into `/sys/fs/smackfs/load2` at boot — versus SELinux's shipped policy of ~5,000 types and ~113,000 allow rules, essentially none of which describes an appliance. Smack has a far smaller kernel and userspace footprint (relevant on constrained flash and RAM), the labels are human-meaningful strings you choose rather than an inherited vocabulary, and a read-only rootfs makes the labelling problem trivial because labels are baked into the image at build time. This is why Tizen and Automotive Grade Linux chose it.
What they lose: **the tooling and the ecosystem**. There is no `audit2allow`, no `sealert`, no `setroubleshoot`, no reference policy, no upstream-maintained per-application policy, no permissive mode for progressive rollout, and no MLS/MCS. Every rule is hand-written and every regression is diagnosed by reading raw kernel messages. That trade is fine for 15 known processes and untenable for a general-purpose server.

**A11.5** — **AppArmor.** (1) *Path-based, no relabelling*: the profile is a text file naming the paths the binary may touch, so a team with no MAC background can read, review and reason about it in an afternoon — and deploying it changes no metadata on any existing file, so the blast radius of a mistake is one profile, not a filesystem. (2) *Complain mode plus `aa-genprof`/`aa-logprof`*: the tooling generates a working profile from observed behaviour interactively, so the two days go into exercising the application rather than learning a policy language. Add that it is the default on Ubuntu, so profiles load at boot with no configuration and `aa-status` gives an immediate answer to "is it confined?".
(The honest caveat to state alongside the recommendation: the resulting profile confines the paths you observed. Anything the application does only under conditions you did not exercise will be denied in production, so ship it in complain mode first and run `aa-logprof` before switching to enforce.)

**A11.6** — It tells you that all three are implemented against the **same kernel abstraction — the Linux Security Modules framework** — rather than as independent, ad-hoc patches. LSM defines a fixed set of hooks at security-relevant decision points (inode permission checks, task creation, socket bind, capability checks, and so on) and a per-object/per-task opaque security blob; each module supplies its own decision function and its own interpretation of the blob. `/proc/<pid>/attr/current` is part of that common interface: a generic way to read and, where the module permits, set the calling task's security attribute, whatever "security attribute" means to the active module. The practical consequences for you as an administrator are that the *shape* of the systems is comparable — every one has a subject label, an object label, a rule set, and a hook where a decision is made — and that a tool written against the generic interface (audit, `ps -Z`, container runtimes) can report on whichever LSM is active. What differs is entirely the policy model layered on top.

</details>

---

## References

- LPI — [Exam 303 Objectives (303-300, version 3.0)](https://www.lpi.org/our-certifications/exam-303-objectives/)
- The SELinux Project — [Main page](https://selinuxproject.org/page/Main_Page), [Policy Languages](https://selinuxproject.org/page/PolicyLanguages), [CIL Reference Guide](https://github.com/SELinuxProject/selinux/tree/main/secilc/docs)
- Red Hat — [Using SELinux (RHEL 9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/index)
- man pages — [`selinux(8)`](https://man7.org/linux/man-pages/man8/selinux.8.html), [`semanage(8)`](https://man7.org/linux/man-pages/man8/semanage.8.html), [`semodule(8)`](https://man7.org/linux/man-pages/man8/semodule.8.html), [`restorecon(8)`](https://man7.org/linux/man-pages/man8/restorecon.8.html), [`setfiles(8)`](https://man7.org/linux/man-pages/man8/setfiles.8.html), [`fixfiles(8)`](https://man7.org/linux/man-pages/man8/fixfiles.8.html), [`runcon(1)`](https://man7.org/linux/man-pages/man1/runcon.1.html), [`newrole(1)`](https://man7.org/linux/man-pages/man1/newrole.1.html), [`audit2allow(1)`](https://man7.org/linux/man-pages/man1/audit2allow.1.html)
- SETools — [project repository](https://github.com/SELinuxProject/setools) (`seinfo`, `sesearch`, `apol`; note that `seaudit` was removed in SETools 4.x, where `ausearch` + `audit2why` cover that workflow)
- AppArmor — [upstream wiki](https://gitlab.com/apparmor/apparmor/-/wikis/home), [profile language reference](https://gitlab.com/apparmor/apparmor/-/wikis/AppArmor_Core_Policy_Reference), [Ubuntu Server documentation](https://documentation.ubuntu.com/server/how-to/security/apparmor/)
- Linux kernel — [LSM framework](https://www.kernel.org/doc/html/latest/admin-guide/LSM/index.html), [SELinux](https://www.kernel.org/doc/html/latest/admin-guide/LSM/SELinux.html), [AppArmor](https://www.kernel.org/doc/html/latest/admin-guide/LSM/apparmor.html), [Smack](https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html)
- Linux Audit — [`audit` documentation](https://github.com/linux-audit/audit-documentation/wiki)