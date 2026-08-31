# 110.3 Securing data with encryption — Guided Exercises

**Certification:** LPIC-1 (Exams 101-500 / 102-500), version 5.0
**Objective 110.3:** OpenSSH client configuration and use, GnuPG configuration, use and revocation.
**Key files and commands under test:** `ssh`, `ssh-keygen`, `ssh-agent`, `ssh-add`, `~/.ssh/id_rsa[.pub]`, `~/.ssh/id_dsa[.pub]`, `~/.ssh/id_ecdsa[.pub]`, `~/.ssh/id_ed25519[.pub]`, `/etc/ssh/ssh_host_*`, `~/.ssh/authorized_keys`, `~/.ssh/known_hosts`, `ssh_known_hosts`, `gpg`, `gpg-agent`, `~/.gnupg/`.

---

## Lab setup

You need one Linux system with `openssh-client`, `openssh-server` and `gnupg` installed, and a running `sshd`. Every "remote host" in this lab is `localhost` connected over the real SSH protocol — the client and server code paths are identical to a remote connection, so nothing is simulated.

```bash
# Debian/Ubuntu
sudo apt-get install -y openssh-client openssh-server gnupg
# RHEL/Fedora/openSUSE
sudo dnf install -y openssh-clients openssh-server gnupg2

sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd
systemctl is-active ssh sshd 2>/dev/null | grep -q active && echo "sshd running"
```

Record your baseline so you can compare later:

```bash
ssh -V
gpg --version | head -2
```

Expected output (versions will differ; write yours down):

```
OpenSSH_9.6p1 Ubuntu-3ubuntu13.5, OpenSSL 3.0.13 30 Jan 2024
gpg (GnuPG) 2.4.4
libgcrypt 1.10.3
```

> Throughout this document, `student` is your login name. Substitute yours.

---

## Exercise 1 — Generating and inspecting SSH key pairs

**Goal:** produce keys of three algorithms, understand the on-disk format, and read a fingerprint the way `sshd` reads it.

1. Create the client key directory with correct ownership and mode:

   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   ls -ld ~/.ssh
   ```

   ```
   drwx------ 2 student student 4096 Aug 31 10:02 /home/student/.ssh
   ```

2. Generate an Ed25519 key pair with a comment and a passphrase. When prompted for the file, accept the default; when prompted for a passphrase, type `LabPass123` twice.

   ```bash
   ssh-keygen -t ed25519 -C "lpic1-lab-$(hostname -s)"
   ```

   ```
   Generating public/private ed25519 key pair.
   Enter file in which to save the key (/home/student/.ssh/id_ed25519):
   Enter passphrase (empty for no passphrase):
   Enter same passphrase again:
   Your identification has been saved in /home/student/.ssh/id_ed25519
   Your public key has been saved in /home/student/.ssh/id_ed25519.pub
   The key fingerprint is:
   SHA256:0kR9nJmYb6Qb2t/9m3n0lVQ1uJ0uS3xW4qz9m8dK1cE lpic1-lab-workstation
   The key's randomart image is:
   +--[ED25519 256]--+
   |        .o+.     |
   |       . o.o     |
   ...
   +----[SHA256]-----+
   ```

3. Generate a 4096-bit RSA key in a non-default file, with no passphrase, non-interactively:

   ```bash
   ssh-keygen -t rsa -b 4096 -N '' -C "rsa-lab" -f ~/.ssh/id_rsa_lab
   ssh-keygen -t ecdsa -b 521 -N '' -C "ecdsa-lab" -f ~/.ssh/id_ecdsa_lab
   ls -l ~/.ssh/
   ```

   ```
   -rw------- 1 student student 3389 Aug 31 10:05 id_ecdsa_lab
   -rw-r--r-- 1 student student  283 Aug 31 10:05 id_ecdsa_lab.pub
   -rw------- 1 student student  399 Aug 31 10:04 id_ed25519
   -rw-r--r-- 1 student student   99 Aug 31 10:04 id_ed25519.pub
   -rw------- 1 student student 3381 Aug 31 10:05 id_rsa_lab
   -rw-r--r-- 1 student student  743 Aug 31 10:05 id_rsa_lab.pub
   ```

4. Look at the two halves of one pair:

   ```bash
   head -1 ~/.ssh/id_ed25519
   cat  ~/.ssh/id_ed25519.pub
   ```

   ```
   -----BEGIN OPENSSH PRIVATE KEY-----
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1n0m9zXxk0k9r4t2c1... lpic1-lab-workstation
   ```

5. Print fingerprints — first the default SHA256/base64 form, then the legacy MD5 hex form still shown by old servers:

   ```bash
   ssh-keygen -l -f ~/.ssh/id_ed25519.pub
   ssh-keygen -l -E md5 -f ~/.ssh/id_ed25519.pub
   ssh-keygen -lv -f ~/.ssh/id_rsa_lab.pub | head -3
   ```

   ```
   256 SHA256:0kR9nJmYb6Qb2t/9m3n0lVQ1uJ0uS3xW4qz9m8dK1cE lpic1-lab-workstation (ED25519)
   256 MD5:af:5c:1b:90:2d:7e:44:03:9a:11:c8:6f:e2:0d:73:b4 lpic1-lab-workstation (ED25519)
   4096 SHA256:tR3v2QpL8m0aX9c1... rsa-lab (RSA)
   ```

6. Prove the public key is derived from the private key, not stored independently. Delete the `.pub` file, regenerate it, and compare:

   ```bash
   cp ~/.ssh/id_rsa_lab.pub /tmp/original.pub
   rm ~/.ssh/id_rsa_lab.pub
   ssh-keygen -y -f ~/.ssh/id_rsa_lab > ~/.ssh/id_rsa_lab.pub
   diff <(cut -d' ' -f1,2 /tmp/original.pub) <(cut -d' ' -f1,2 ~/.ssh/id_rsa_lab.pub) && echo "IDENTICAL key material"
   ```

   ```
   IDENTICAL key material
   ```

7. Change the passphrase on the Ed25519 key without regenerating it (old: `LabPass123`, new: `NewLabPass456`):

   ```bash
   ssh-keygen -p -f ~/.ssh/id_ed25519
   ```

   ```
   Enter old passphrase:
   Key has comment 'lpic1-lab-workstation'
   Enter new passphrase (empty for no passphrase):
   Enter same passphrase again:
   Your identification has been saved with the new passphrase.
   ```

### Check your understanding — block 1

1. `ssh-keygen -t ed25519 -b 4096` — what happens, and why?
2. Step 6 regenerated `id_rsa_lab.pub` from the private key, but the `diff` compared only fields 1 and 2. Which field was deliberately excluded and what does that tell you about where the comment lives?
3. Which of the two files in a pair may be world-readable, and which will make `ssh` refuse to run if it is?
4. A server administrator emails you `af:5c:1b:90:...` as the host fingerprint, but your client prints `SHA256:0kR9...`. Give the exact command that lets you compare them.
5. After `ssh-keygen -p`, does the public key file need to be redistributed to every server that trusts it?

---

## Exercise 2 — Public key authentication and `authorized_keys`

**Goal:** install a key, break it deliberately, and read the server's side of the failure.

1. Confirm password authentication works before you change anything, then install the Ed25519 public key into your own `authorized_keys`:

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub student@localhost
   ```

   ```
   /usr/bin/ssh-copy-id: INFO: Source of key(s) to be installed: "/home/student/.ssh/id_ed25519.pub"
   /usr/bin/ssh-copy-id: INFO: attempting to log in with the new key(s), to filter out any that are already installed
   /usr/bin/ssh-copy-id: INFO: 1 key(s) remain to be installed -- if you are prompted now it is to install the new keys
   student@localhost's password:

   Number of key(s) added: 1
   ```

2. Inspect what was written and with which permissions:

   ```bash
   ls -l ~/.ssh/authorized_keys
   cat ~/.ssh/authorized_keys
   ```

   ```
   -rw------- 1 student student 99 Aug 31 10:12 /home/student/.ssh/authorized_keys
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1n0m9zXxk0k9r4t2c1... lpic1-lab-workstation
   ```

3. Authenticate with the key. You will be asked for the *key passphrase*, not the account password — note the difference in the prompt text:

   ```bash
   ssh -i ~/.ssh/id_ed25519 student@localhost 'echo AUTHENTICATED as $(id -un) from $SSH_CONNECTION'
   ```

   ```
   Enter passphrase for key '/home/student/.ssh/id_ed25519':
   AUTHENTICATED as student from 127.0.0.1 43210 127.0.0.1 22
   ```

4. Break the permissions on purpose and observe the client-side refusal:

   ```bash
   chmod 644 ~/.ssh/id_ed25519
   ssh -i ~/.ssh/id_ed25519 student@localhost true
   ```

   ```
   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
   @         WARNING: UNPROTECTED PRIVATE KEY FILE!          @
   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
   Permissions 0644 for '/home/student/.ssh/id_ed25519' are too open.
   It is required that your private key files are NOT accessible by others.
   This private key will be ignored.
   ```

   ```bash
   chmod 600 ~/.ssh/id_ed25519
   ```

5. Now break the *server* side and read the log. Make the home directory group-writable, which trips `StrictModes yes`:

   ```bash
   chmod g+w ~
   ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
       -i ~/.ssh/id_ed25519 student@localhost true
   ```

   ```
   student@localhost: Permission denied (publickey).
   ```

   ```bash
   sudo journalctl -u ssh -u sshd -n 5 --no-pager | tail -3
   ```

   ```
   sshd[4471]: Authentication refused: bad ownership or modes for directory /home/student
   ```

   ```bash
   chmod g-w ~
   ```

6. Restrict the key. Prepend options so this key can only run one command and cannot forward anything:

   ```bash
   cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
   sed -i '1s|^|restrict,command="/bin/date -u" |' ~/.ssh/authorized_keys
   head -c 80 ~/.ssh/authorized_keys; echo
   ssh -i ~/.ssh/id_ed25519 student@localhost 'rm -rf /tmp/whatever'
   ```

   ```
   restrict,command="/bin/date -u" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1n0m9z
   Mon Aug 31 10:19:44 UTC 2026
   ```

7. Restore the unrestricted entry:

   ```bash
   mv ~/.ssh/authorized_keys.bak ~/.ssh/authorized_keys
   ```

### Check your understanding — block 2

6. In step 3 the prompt was `Enter passphrase for key ...`. What would the prompt have been if the key had not been accepted by the server, and what does each prompt prove about *where* the secret is verified?
7. `ssh-copy-id` created `~/.ssh/authorized_keys` with mode 600. Would mode 644 break authentication under the default `sshd_config`? What about 664?
8. Why did the failure in step 5 appear only in the server's journal and not in `ssh -v` client output?
9. What is the difference between the `restrict` keyword and writing `no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty` explicitly?
10. With `command="/bin/date -u"` in place, the user typed `rm -rf /tmp/whatever`. Where did that string go? Name the environment variable that still carries it on the server.

---

## Exercise 3 — Host keys, `known_hosts` and host verification

**Goal:** understand the server's identity, the TOFU model, and how to repair a mismatch safely.

1. List the server's host keys and their fingerprints:

   ```bash
   sudo ls -l /etc/ssh/ssh_host_*
   for k in /etc/ssh/ssh_host_*_key.pub; do sudo ssh-keygen -l -f "$k"; done
   ```

   ```
   -rw------- 1 root root  505 Jul  2 09:11 /etc/ssh/ssh_host_ecdsa_key
   -rw-r--r-- 1 root root  174 Jul  2 09:11 /etc/ssh/ssh_host_ecdsa_key.pub
   -rw------- 1 root root  399 Jul  2 09:11 /etc/ssh/ssh_host_ed25519_key
   -rw-r--r-- 1 root root   94 Jul  2 09:11 /etc/ssh/ssh_host_ed25519_key.pub
   -rw------- 1 root root 2590 Jul  2 09:11 /etc/ssh/ssh_host_rsa_key
   -rw-r--r-- 1 root root  563 Jul  2 09:11 /etc/ssh/ssh_host_rsa_key.pub
   256 SHA256:hQ2m8Lp0aVc3... root@workstation (ECDSA)
   256 SHA256:Wc9Xy1Zt6Nn4... root@workstation (ED25519)
   3072 SHA256:Kk7Ff3Rr2Dd8... root@workstation (RSA)
   ```

2. Fetch the same keys over the network the way a client does, without connecting a session:

   ```bash
   ssh-keyscan -t ed25519 localhost 2>/dev/null
   ssh-keyscan -t ed25519 localhost 2>/dev/null | ssh-keygen -l -f -
   ```

   ```
   localhost ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9k2v0mQ...
   256 SHA256:Wc9Xy1Zt6Nn4... localhost (ED25519)
   ```

   Compare this fingerprint to the one printed in step 1 — they must match.

3. Inspect your `known_hosts`. On Debian-family systems `HashKnownHosts yes` is the default, so hostnames are stored as HMACs:

   ```bash
   head -2 ~/.ssh/known_hosts
   ```

   ```
   |1|Ry8Zl3pQ0nK2m9d4Tt7wXcVbA1s=|Uu6Yh2Nn0Kk8Ff4Dd1Ss9Aa3Qq5= ssh-ed25519 AAAAC3Nza...
   ```

4. Because it is hashed, `grep` is useless. Use the built-in search:

   ```bash
   ssh-keygen -F localhost
   ```

   ```
   # Host localhost found: line 1
   |1|Ry8Zl3pQ0nK2m9d4Tt7wXcVbA1s=|Uu6Yh2Nn0Kk8Ff4Dd1Ss9Aa3Qq5= ssh-ed25519 AAAAC3Nza...
   ```

5. Simulate a host-key change (server rebuild, or an attack). Corrupt the stored entry and reconnect:

   ```bash
   cp ~/.ssh/known_hosts /tmp/known_hosts.good
   ssh-keygen -R localhost >/dev/null 2>&1
   ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | sed 's/AAAA/AAAB/' >> ~/.ssh/known_hosts
   ssh -o StrictHostKeyChecking=ask student@127.0.0.1 true
   ```

   ```
   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
   @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
   IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
   Someone could be eavesdropping on you right now (man-in-the-middle attack)!
   It is also possible that a host key has just been changed.
   The fingerprint for the ED25519 key sent by the remote host is
   SHA256:Wc9Xy1Zt6Nn4...
   Please contact your system administrator.
   Add correct host key in /home/student/.ssh/known_hosts to get rid of this message.
   Offending ECDSA key in /home/student/.ssh/known_hosts:2
   Host key verification failed.
   ```

6. Repair it the correct way — remove only the offending entry, then re-verify out of band before accepting:

   ```bash
   ssh-keygen -R 127.0.0.1
   ssh student@127.0.0.1 'echo reconnected'
   ```

   ```
   # Host 127.0.0.1 found: line 2
   /home/student/.ssh/known_hosts updated.
   Original contents retained as /home/student/.ssh/known_hosts.old
   The authenticity of host '127.0.0.1 (127.0.0.1)' can't be established.
   ED25519 key fingerprint is SHA256:Wc9Xy1Zt6Nn4....
   This key is not known by any other names.
   Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
   Warning: Permanently added '127.0.0.1' (ED25519) to the list of known hosts.
   reconnected
   ```

7. Look at the system-wide equivalent, which an administrator pre-populates so users never see a TOFU prompt:

   ```bash
   ls -l /etc/ssh/ssh_known_hosts 2>/dev/null || echo "not present (this is normal on a default install)"
   grep -i -E 'GlobalKnownHostsFile|UserKnownHostsFile|StrictHostKeyChecking|HashKnownHosts' /etc/ssh/ssh_config
   ```

### Check your understanding — block 3

11. `ssh_host_ed25519_key` is mode 600 and owned by root, but you connect as an unprivileged user. Which process reads it, and at what point in the connection?
12. In step 6 the prompt offered `yes/no/[fingerprint]`. What does typing the fingerprint achieve that typing `yes` does not?
13. What is the operational cost of `HashKnownHosts yes`, and what attack does it mitigate?
14. Your automation pipeline hangs on the TOFU prompt. A colleague suggests `StrictHostKeyChecking=no`. State the correct fix and why theirs is wrong.
15. `ssh-keygen -R host` says "Original contents retained as ...known_hosts.old". Why is that file a problem if you were rotating keys after a suspected compromise?

---

## Exercise 4 — `ssh-agent` and `ssh-add`

**Goal:** hold a decrypted private key in memory, control its lifetime, and understand the socket that grants access to it.

1. Check whether an agent is already running in your session:

   ```bash
   echo "SOCK=$SSH_AUTH_SOCK  PID=$SSH_AGENT_PID"
   ssh-add -l; echo "exit=$?"
   ```

   ```
   SOCK=  PID=
   Could not open a connection to your authentication agent.
   exit=2
   ```

2. Start an agent and import its variables into the current shell. Read the raw output first — the `eval` is what makes the variables take effect:

   ```bash
   ssh-agent -s
   ```

   ```
   SSH_AUTH_SOCK=/tmp/ssh-XXXX8fQ1kM/agent.5012; export SSH_AUTH_SOCK;
   SSH_AGENT_PID=5013; export SSH_AGENT_PID;
   echo Agent pid 5013;
   ```

   ```bash
   eval "$(ssh-agent -s)"
   ssh-add -l; echo "exit=$?"
   ```

   ```
   Agent pid 5031
   The agent has no identities.
   exit=1
   ```

3. Add the Ed25519 key with a 120-second lifetime (passphrase `NewLabPass456`) and list it two ways:

   ```bash
   ssh-add -t 120 ~/.ssh/id_ed25519
   ssh-add -l
   ssh-add -L | cut -c1-60
   ```

   ```
   Enter passphrase for /home/student/.ssh/id_ed25519:
   Identity added: /home/student/.ssh/id_ed25519 (lpic1-lab-workstation)
   Lifetime set to 120 seconds
   256 SHA256:0kR9nJmYb6Qb2t/9m3n0lVQ1uJ0uS3xW4qz9m8dK1cE lpic1-lab-workstation (ED25519)
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1n0m9zXxk0k9r4t2c
   ```

4. Connect twice with no passphrase prompt, then watch the key expire:

   ```bash
   ssh student@localhost 'echo first'; ssh student@localhost 'echo second'
   sleep 125
   ssh-add -l
   ```

   ```
   first
   second
   The agent has no identities.
   ```

5. Add all default keys at once, then remove selectively and then completely:

   ```bash
   ssh-add ~/.ssh/id_rsa_lab ~/.ssh/id_ecdsa_lab
   ssh-add -l | wc -l
   ssh-add -d ~/.ssh/id_ecdsa_lab
   ssh-add -l | wc -l
   ssh-add -D
   ```

   ```
   Identity added: /home/student/.ssh/id_rsa_lab (rsa-lab)
   Identity added: /home/student/.ssh/id_ecdsa_lab (ecdsa-lab)
   2
   Identity removed: /home/student/.ssh/id_ecdsa_lab (ecdsa-lab)
   1
   All identities removed.
   ```

6. Examine the agent socket — this is the whole security boundary:

   ```bash
   ls -l "$SSH_AUTH_SOCK"
   ls -ld "$(dirname "$SSH_AUTH_SOCK")"
   ```

   ```
   srw------- 1 student student 0 Aug 31 10:41 /tmp/ssh-XXXX8fQ1kM/agent.5030
   drwx------ 2 student student 60 Aug 31 10:41 /tmp/ssh-XXXX8fQ1kM
   ```

7. Add a key that requires confirmation for every use, then kill the agent:

   ```bash
   ssh-add -c ~/.ssh/id_rsa_lab      # each signature now pops an askpass confirmation
   ssh-add -x                        # lock the agent with a temporary password
   ssh-add -l
   ssh-agent -k
   echo "SOCK=$SSH_AUTH_SOCK"
   ```

   ```
   Identity added: /home/student/.ssh/id_rsa_lab (rsa-lab)
   The user must confirm each use of the key
   Enter lock password:
   Again:
   Agent locked.
   The agent has no identities.
   unset SSH_AUTH_SOCK;
   unset SSH_AGENT_PID;
   echo Agent pid 5030 killed;
   ```

### Check your understanding — block 4

16. `ssh-add -l` returned exit code 2 in step 1 and 1 in step 3. What does each code mean, and why is the distinction useful in a script?
17. Why must `ssh-agent -s` be wrapped in `eval` instead of just executed? What would happen if you ran it inside a subshell such as `$(ssh-agent -s)` without `eval`?
18. Your agent holds a key. You `ssh -A` into a shared server where `root` is not you. Precisely what can that root user do, and what can they *not* take with them?
19. The agent socket is mode `srw-------` inside a `drwx------` directory. Which of those two permissions actually stops another unprivileged user from signing with your key?
20. In step 7 the last command printed `unset SSH_AUTH_SOCK;` but did not unset it in your shell. Fix the command line so that it does.

---

## Exercise 5 — Client configuration and port forwarding

**Goal:** replace long command lines with `~/.ssh/config`, and build local, remote and dynamic tunnels.

1. Write a client configuration. Note that the *first* obtained value for each keyword wins, so specific hosts go above the wildcard:

   ```bash
   cat > ~/.ssh/config <<'EOF'
   Host lab
       HostName localhost
       User student
       Port 22
       IdentityFile ~/.ssh/id_ed25519
       IdentitiesOnly yes
       ServerAliveInterval 30

   Host *
       HashKnownHosts yes
       ForwardAgent no
       ForwardX11 no
   EOF
   chmod 600 ~/.ssh/config
   ssh lab 'echo connected via alias'
   ```

   ```
   connected via alias
   ```

2. Ask the client what it has actually resolved for that alias — this is the diagnostic command, not `cat`:

   ```bash
   ssh -G lab | grep -E '^(hostname|user|port|identityfile|identitiesonly|forwardagent) '
   ```

   ```
   user student
   hostname localhost
   port 22
   forwardagent no
   identityfile ~/.ssh/id_ed25519
   identitiesonly yes
   ```

3. Build a **local** forward. Anything reaching port 8022 on your loopback interface is tunnelled to `localhost:22` *as seen from the server*:

   ```bash
   ssh -f -N -L 8022:localhost:22 lab
   ss -tlnp | grep 8022
   ssh -p 8022 -o StrictHostKeyChecking=accept-new student@127.0.0.1 'echo through the tunnel'
   ```

   ```
   LISTEN 0  128  127.0.0.1:8022  0.0.0.0:*  users:(("ssh",pid=5210,fd=5))
   through the tunnel
   ```

4. Build a **remote** forward: port 9022 on the server is tunnelled back to a service on your client:

   ```bash
   ssh -f -N -R 9022:localhost:22 lab
   ssh lab "ss -tln | grep 9022"
   ```

   ```
   LISTEN 0  128  127.0.0.1:9022  0.0.0.0:*
   ```

5. Build a **dynamic** forward — a SOCKS5 proxy that resolves and connects on the server side:

   ```bash
   ssh -f -N -D 1080 lab
   curl --socks5-hostname 127.0.0.1:1080 -s -o /dev/null -w '%{http_code}\n' http://example.com/
   ```

   ```
   200
   ```

6. Try to make the local forward reachable from other machines and observe why it fails silently:

   ```bash
   ssh -f -N -L 0.0.0.0:8023:localhost:22 lab
   ss -tlnp | grep 8023
   ```

   ```
   LISTEN 0  128  0.0.0.0:8023  0.0.0.0:*  users:(("ssh",pid=5288,fd=5))
   ```

   The client binds because you asked it to. Now check the equivalent for `-R`, which is governed by the **server's** `GatewayPorts` setting:

   ```bash
   grep -i gatewayports /etc/ssh/sshd_config
   ```

   ```
   #GatewayPorts no
   ```

7. Practise the escape sequences inside an interactive session. Connect, then press `Enter` followed by `~?`, `~#` and finally `~.`:

   ```bash
   ssh lab
   ```

   ```
   student@workstation:~$          <-- press Enter, then ~?
   Supported escape sequences:
    ~.   - terminate connection (and any multiplexed sessions)
    ~B   - send a BREAK to the remote system
    ~C   - open a command line
    ~R   - request rekey
    ~#   - list forwarded connections
    ~&   - background ssh (when waiting for connections to terminate)
    ~?   - this message
    ~~   - send the escape character by typing it twice
   ```

8. Tear down every background tunnel:

   ```bash
   pkill -f 'ssh -f -N' ; ss -tlnp | grep -E '8022|8023|9022|1080' || echo "all tunnels closed"
   ```

### Check your understanding — block 5

21. In `-L 8022:localhost:22`, on which machine is the name `localhost` resolved? And in `-R 9022:localhost:22`?
22. What does `IdentitiesOnly yes` change, given that `IdentityFile` was already specified?
23. Why is `-N` combined with `-f` in steps 3–5, and what would happen if you dropped `-N`?
24. Step 6 showed `-L 0.0.0.0:8023` binding successfully while `-R` needs `GatewayPorts`. Explain the asymmetry in terms of who owns the listening socket.
25. A user reports the `~.` escape does nothing. Name two configurations that would explain it.
26. With `-D 1080`, where is the DNS lookup for `example.com` performed when using `--socks5-hostname`? Why does that matter for a bastion host?

---

## Exercise 6 — GnuPG: key generation and keyring anatomy

**Goal:** create an OpenPGP key pair, read `~/.gnupg/`, and distinguish the certification key from its subkeys.

1. Inspect the home directory before doing anything, and set `GPG_TTY` so `pinentry` can reach your terminal:

   ```bash
   export GPG_TTY=$(tty)
   gpgconf --list-dirs homedir
   ls -la ~/.gnupg 2>/dev/null || echo "not created yet"
   ```

   ```
   /home/student/.gnupg
   ```

2. Generate a key pair non-interactively (passphrase `GpgLab789` when prompted), then repeat the concept interactively so you have seen both menus:

   ```bash
   gpg --quick-generate-key "Ada Lovelace <ada@lab.example>" ed25519 default 1y
   ```

   ```
   gpg: directory '/home/student/.gnupg' created
   gpg: keybox '/home/student/.gnupg/pubring.kbx' created
   gpg: /home/student/.gnupg/trustdb.gpg: trustdb created
   gpg: key 9F3C1D77A2B40E51 marked as ultimately trusted
   gpg: directory '/home/student/.gnupg/openpgp-revocs.d' created
   gpg: revocation certificate stored as '/home/student/.gnupg/openpgp-revocs.d/4B1E...A2B40E51.rev'
   public and secret key created and signed.

   pub   ed25519 2026-08-31 [SC] [expires: 2027-08-31]
         4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   uid                      Ada Lovelace <ada@lab.example>
   sub   cv25519 2026-08-31 [E]
   ```

   ```bash
   gpg --full-generate-key      # walk the menu: (1) RSA and RSA, 3072 bits, 2y, "Bob Tester <bob@lab.example>"
   ```

3. List public and secret keyrings, with fingerprints and key IDs:

   ```bash
   gpg --list-keys --keyid-format LONG
   gpg --list-secret-keys
   gpg --fingerprint ada@lab.example
   ```

   ```
   /home/student/.gnupg/pubring.kbx
   --------------------------------
   pub   ed25519/9F3C1D77A2B40E51 2026-08-31 [SC] [expires: 2027-08-31]
         4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   uid                 [ultimate] Ada Lovelace <ada@lab.example>
   sub   cv25519/1C0A55E93BD27F64 2026-08-31 [E]

   sec   ed25519 2026-08-31 [SC] [expires: 2027-08-31]
         4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   uid           [ultimate] Ada Lovelace <ada@lab.example>
   ssb   cv25519 2026-08-31 [E]
   ```

4. Map the on-disk layout. Modern GnuPG (2.1+) does **not** use `secring.gpg`:

   ```bash
   ls -la ~/.gnupg
   ls -l ~/.gnupg/private-keys-v1.d/
   ls -l ~/.gnupg/openpgp-revocs.d/
   ```

   ```
   drwx------ 4 student student 4096 Aug 31 10:58 .
   -rw------- 1 student student 2510 Aug 31 10:58 pubring.kbx
   drwx------ 2 student student 4096 Aug 31 10:58 private-keys-v1.d
   drwx------ 2 student student 4096 Aug 31 10:58 openpgp-revocs.d
   -rw------- 1 student student 1360 Aug 31 10:58 trustdb.gpg
   -rw------- 1 student student   32 Aug 31 10:58 gpg.conf
   ```

5. Export the public key in ASCII armor, and the secret key too. Compare their sizes and headers:

   ```bash
   gpg --armor --export ada@lab.example > /tmp/ada.pub.asc
   gpg --armor --export-secret-keys ada@lab.example > /tmp/ada.sec.asc
   head -1 /tmp/ada.pub.asc; head -1 /tmp/ada.sec.asc
   ```

   ```
   -----BEGIN PGP PUBLIC KEY BLOCK-----
   -----BEGIN PGP PRIVATE KEY BLOCK-----
   ```

6. Simulate receiving Bob's key on Ada's side: import into a *separate* GnuPG home so the two identities are truly distinct:

   ```bash
   mkdir -p /tmp/bobhome && chmod 700 /tmp/bobhome
   gpg --armor --export bob@lab.example > /tmp/bob.pub.asc
   gpg --homedir /tmp/bobhome --import /tmp/bob.pub.asc
   gpg --homedir /tmp/bobhome --list-keys
   ```

   ```
   gpg: key 77D0E4A9B3115C82: public key "Bob Tester <bob@lab.example>" imported
   gpg: Total number processed: 1
   gpg:               imported: 1
   ```

### Check your understanding — block 6

27. The primary key shows `[SC]` and the subkey `[E]`. Expand each letter and explain why encryption lives on a separate subkey.
28. Which file holds Ada's private key material, and which holds the public keyring? Name the file that used to hold secret keys before GnuPG 2.1.
29. `gpg --quick-generate-key` said "marked as ultimately trusted" without asking. Why is that safe for your own key and never correct for an imported one?
30. Give the full 40-hex-character fingerprint's relationship to `9F3C1D77A2B40E51` and to a short ID like `A2B40E51`. Which of the three must you use when verifying a key in person?
31. What did `--homedir /tmp/bobhome` accomplish that `--keyring` alone would not?

---

## Exercise 7 — Encrypting, decrypting, signing and verifying

**Goal:** exercise both asymmetric and symmetric modes, produce detached signatures, and read the packet structure of the result.

1. Create a test document:

   ```bash
   echo "Analytical Engine boot sequence: step 1, wind the crank." > /tmp/notes.txt
   sha256sum /tmp/notes.txt
   ```

2. Encrypt **to Bob** (asymmetric) and confirm you cannot read it as Ada:

   ```bash
   gpg --armor --encrypt --recipient bob@lab.example --output /tmp/notes.asc /tmp/notes.txt
   head -2 /tmp/notes.asc
   gpg --decrypt /tmp/notes.asc > /dev/null
   ```

   ```
   -----BEGIN PGP MESSAGE-----

   gpg: encrypted with rsa3072 key, ID 77D0E4A9B3115C82, created 2026-08-31
         "Bob Tester <bob@lab.example>"
   ```

   (Since both keys are in the same keyring here, decryption succeeds; do it from `/tmp/bobhome`, which has only Bob's *public* key, to see the real failure:)

   ```bash
   gpg --homedir /tmp/bobhome --decrypt /tmp/notes.asc
   ```

   ```
   gpg: encrypted with RSA key, ID 77D0E4A9B3115C82
   gpg: decryption failed: No secret key
   ```

3. Inspect the ciphertext structure without decrypting it:

   ```bash
   gpg --list-packets /tmp/notes.asc | head -4
   ```

   ```
   # off=0 ctb=85 tag=1 hlen=3 plen=268
   :pubkey enc packet: version 3, algo 1, keyid 77D0E4A9B3115C82
           data: [3071 bits]
   :encrypted data packet:
   ```

4. Encrypt **symmetrically** with a passphrase (`SharedSecret42`), then prove which cipher was used:

   ```bash
   gpg --symmetric --cipher-algo AES256 --output /tmp/notes.sym.gpg /tmp/notes.txt
   gpg --list-packets /tmp/notes.sym.gpg | head -3
   gpg --decrypt /tmp/notes.sym.gpg
   ```

   ```
   # off=0 ctb=8c tag=3 hlen=2 plen=13
   :symkey enc packet: version 4, cipher 9, aead 0, s2k 3, hash 8
           salt A1B2C3D4E5F60718, count 65011712 (255)
   gpg: AES256.CFB encrypted data
   gpg: encrypted with 1 passphrase
   Analytical Engine boot sequence: step 1, wind the crank.
   ```

5. Sign in the three distinct modes and compare the artefacts:

   ```bash
   gpg --local-user ada@lab.example --sign        --output /tmp/notes.sig.gpg /tmp/notes.txt   # binary, embeds document
   gpg --local-user ada@lab.example --clearsign   --output /tmp/notes.clear.asc /tmp/notes.txt # readable + signature
   gpg --local-user ada@lab.example --detach-sign --armor --output /tmp/notes.txt.asc /tmp/notes.txt
   ls -l /tmp/notes.txt /tmp/notes.sig.gpg /tmp/notes.clear.asc /tmp/notes.txt.asc
   head -3 /tmp/notes.clear.asc
   ```

   ```
   -rw-r--r-- 1 student student   57 Aug 31 11:12 /tmp/notes.txt
   -rw-r--r-- 1 student student  178 Aug 31 11:14 /tmp/notes.sig.gpg
   -rw-r--r-- 1 student student  349 Aug 31 11:14 /tmp/notes.clear.asc
   -rw-r--r-- 1 student student  228 Aug 31 11:14 /tmp/notes.txt.asc
   -----BEGIN PGP SIGNED MESSAGE-----
   Hash: SHA512

   ```

6. Verify each one, including a deliberately tampered case:

   ```bash
   gpg --verify /tmp/notes.txt.asc /tmp/notes.txt
   echo "step 2, ignore the crank." >> /tmp/notes.txt
   gpg --verify /tmp/notes.txt.asc /tmp/notes.txt; echo "exit=$?"
   ```

   ```
   gpg: Signature made Mon 31 Aug 2026 11:14:02 AM UTC
   gpg:                using EDDSA key 4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   gpg: Good signature from "Ada Lovelace <ada@lab.example>" [ultimate]
   gpg: BAD signature from "Ada Lovelace <ada@lab.example>" [ultimate]
   exit=1
   ```

7. Verify from Bob's keyring, where Ada's key is unknown and then merely untrusted:

   ```bash
   gpg --homedir /tmp/bobhome --verify /tmp/notes.clear.asc
   gpg --homedir /tmp/bobhome --import /tmp/ada.pub.asc
   gpg --homedir /tmp/bobhome --verify /tmp/notes.clear.asc
   ```

   ```
   gpg: Can't check signature: No public key
   gpg: key 9F3C1D77A2B40E51: public key "Ada Lovelace <ada@lab.example>" imported
   gpg: Good signature from "Ada Lovelace <ada@lab.example>" [unknown]
   gpg: WARNING: This key is not certified with a trusted signature!
   gpg:          There is no indication that the signature belongs to the owner.
   Primary key fingerprint: 4B1E 9A70 C6D5 F033 8821  B0DE 9F3C 1D77 A2B4 0E51
   ```

8. Combine both operations — sign and encrypt in one pass, the normal production case:

   ```bash
   printf 'confidential and attributable\n' > /tmp/both.txt
   gpg --armor --sign --encrypt --local-user ada@lab.example --recipient bob@lab.example \
       --output /tmp/both.asc /tmp/both.txt
   gpg --decrypt /tmp/both.asc
   ```

### Check your understanding — block 7

32. `--list-packets` showed `cipher 9` for the symmetric file. What algorithm is that, and how did the *decrypting* side learn which cipher to use without being told?
33. In step 7 the signature was `Good` but carried a `WARNING`. Distinguish the cryptographic question GnuPG answered from the one it refused to answer.
34. Which of the three signature modes lets `grep` still read the document text, and which one would you use to sign a 4 GB ISO image? Justify both.
35. The `--detach-sign` verification needs two file arguments. What is the argument order, and what happens if you supply only the `.asc`?
36. Ada encrypted to Bob and could still decrypt it in step 2 from her own keyring. What option would you add so a copy is *intentionally* readable by the sender, and why is that not the default?

---

## Exercise 8 — `gpg-agent`, expiration and revocation

**Goal:** control passphrase caching, extend a key's life, and revoke it correctly.

1. Observe the agent that GnuPG started implicitly, and the keys it holds:

   ```bash
   gpgconf --list-components | grep gpg-agent
   pgrep -a gpg-agent
   gpg-connect-agent 'keyinfo --list' /bye
   ```

   ```
   gpg-agent:GPG-Agent:/usr/bin/gpg-agent
   5401 gpg-agent --homedir /home/student/.gnupg --use-standard-socket --daemon
   S KEYINFO 8A1B...F09 D - - - P - - -
   S KEYINFO 3C2D...E71 D - - - P - - -
   OK
   ```

2. Configure caching and pinentry, then reload the agent (no kill required for most settings):

   ```bash
   cat > ~/.gnupg/gpg-agent.conf <<'EOF'
   default-cache-ttl 60
   max-cache-ttl 300
   pinentry-program /usr/bin/pinentry-curses
   EOF
   gpgconf --reload gpg-agent
   ```

3. Prove the cache works, then prove it expires:

   ```bash
   echo test > /tmp/c.txt
   gpg --local-user ada@lab.example --detach-sign -o /tmp/c.sig /tmp/c.txt   # asks for passphrase
   gpg --local-user ada@lab.example --detach-sign -o /tmp/c2.sig /tmp/c.txt  # silent — cached
   sleep 65
   gpg --local-user ada@lab.example --detach-sign -o /tmp/c3.sig /tmp/c.txt  # asks again
   ```

4. Flush the cache on demand and restart the agent completely:

   ```bash
   gpg-connect-agent reloadagent /bye
   gpgconf --kill gpg-agent && pgrep -a gpg-agent || echo "agent stopped; it will respawn on next gpg use"
   ```

5. Extend the key's expiration date through the edit menu:

   ```bash
   gpg --edit-key ada@lab.example
   ```

   ```
   gpg> expire
   Changing expiration time for the primary key.
   Please specify how long the key should be valid.
            0 = key does not expire
         <n>  = key expires in n days
   Key is valid for? (0) 2y
   Key expires at Tue 31 Aug 2028 11:31:00 AM UTC
   Is this correct? (y/N) y

   gpg> key 1
   gpg> expire        <-- repeat for the encryption subkey
   gpg> save
   ```

   ```bash
   gpg --list-keys ada@lab.example | grep expires
   ```

6. Locate the revocation certificate GnuPG generated for you, and generate a second one explicitly:

   ```bash
   ls ~/.gnupg/openpgp-revocs.d/
   gpg --output /tmp/ada-revoke.asc --gen-revoke ada@lab.example
   ```

   ```
   Create a revocation certificate for this key? (y/N) y
   Please select the reason for the revocation:
     0 = No reason specified
     1 = Key has been compromised
     2 = Key is no longer used
     3 = User ID is no longer valid
   Your decision? 1
   Enter an optional description: laptop stolen 2026-08-31
   Is this okay? (y/N) y
   ASCII armored output forced.
   Revocation certificate created.
   ```

7. Revoke the key by importing the certificate, then observe the effect on encryption:

   ```bash
   gpg --import /tmp/ada-revoke.asc
   gpg --list-keys ada@lab.example
   gpg --encrypt --recipient ada@lab.example --output /tmp/x.gpg /tmp/c.txt
   ```

   ```
   gpg: key 9F3C1D77A2B40E51: "Ada Lovelace <ada@lab.example>" revocation certificate imported
   gpg: Total number processed: 1
   gpg:      new key revocations: 1

   pub   ed25519 2026-08-31 [SC] [revoked: 2026-08-31]
         4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   uid           [ revoked] Ada Lovelace <ada@lab.example>

   gpg: 4B1E9A70...: skipped: Unusable public key
   gpg: /tmp/c.txt: encryption failed: Unusable public key
   ```

8. Distribute the revocation — the step people forget:

   ```bash
   gpg --armor --export ada@lab.example > /tmp/ada-revoked.pub.asc
   gpg --homedir /tmp/bobhome --import /tmp/ada-revoked.pub.asc
   gpg --homedir /tmp/bobhome --list-keys ada@lab.example | head -2
   ```

   ```
   gpg: key 9F3C1D77A2B40E51: "Ada Lovelace <ada@lab.example>" revocation certificate imported
   pub   ed25519 2026-08-31 [SC] [revoked: 2026-08-31]
   ```

### Check your understanding — block 8

37. `default-cache-ttl 60` and `max-cache-ttl 300` are both set. Describe a sequence of signings where the passphrase is requested at t=0 and again at exactly t=300 despite continuous use.
38. Revoking the key made *encryption to Ada* fail, but what happens to signatures Ada made last year, and to documents already encrypted to her?
39. Where does GnuPG 2.1+ store an automatic revocation certificate, and what is the operational risk of leaving it on the same disk as `private-keys-v1.d/`?
40. You revoked the key locally. Bob, on another continent, still encrypts to it. Name the two mechanisms that would have propagated the revocation and the one manual fallback used in step 8.
41. `gpgconf --reload gpg-agent` versus `gpgconf --kill gpg-agent` — which one preserves cached passphrases, and which setting change forces the harsher option?
42. Ada's key expired rather than being revoked. Can she still extend it after the expiration date has passed? What does that tell you about what an expiration date really is?

---

## Cleanup

```bash
pkill -f 'ssh -f -N'; ssh-agent -k 2>/dev/null
rm -f ~/.ssh/id_rsa_lab* ~/.ssh/id_ecdsa_lab* ~/.ssh/config ~/.ssh/known_hosts.old
cp /tmp/known_hosts.good ~/.ssh/known_hosts 2>/dev/null
gpgconf --kill gpg-agent
rm -rf /tmp/bobhome /tmp/notes* /tmp/both* /tmp/ada* /tmp/bob* /tmp/c*.txt /tmp/c*.sig /tmp/x.gpg
# To discard the lab OpenPGP keys entirely:
# gpg --delete-secret-and-public-key ada@lab.example
```

---

## Answers

<details>
<summary><strong>Click to reveal the answers to all 42 questions</strong></summary>

### Block 1 — Key generation and inspection

**1.** The `-b 4096` is silently ignored. Ed25519 is a fixed-size algorithm: the curve determines a 256-bit key, so there is no size to choose. `ssh-keygen` accepts the flag and produces the same 256-bit key; `ssh-keygen -l` will still report `256`. Only RSA (`-b 2048/3072/4096`) and ECDSA (`-b 256/384/521`, which selects the NIST curve, not an arbitrary length) honour it.

**2.** Field 3, the comment. The public key file is `<type> <base64-key-blob> <comment>`, and `ssh-keygen -y` reconstructs only the first two fields because the comment is stored inside the *encrypted private key*, not derived from the key material. Regenerating a `.pub` therefore loses the comment unless you re-add it with `-C`. This also proves the point: the public key contains zero information that is not computable from the private key.

**3.** The `.pub` file may be — and normally is — world-readable (644); it is public by definition. The private key must not be group- or world-accessible. `ssh` enforces this itself and refuses to use a key whose mode is looser than 600 (owner read/write), printing the `UNPROTECTED PRIVATE KEY FILE` banner. Note this is a *client-side* check on files it reads, independent of `sshd`'s `StrictModes`.

**4.** `ssh-keygen -l -E md5 -f <keyfile>`. Since OpenSSH 6.8 the default fingerprint hash is SHA256 rendered in base64 (and printed with the `SHA256:` prefix); `-E md5` selects the legacy MD5 colon-hex representation. The key is the same — only the digest and encoding differ. You can also compare in the other direction by asking the peer for a SHA256 fingerprint.

**5.** No. The passphrase encrypts the private key file at rest; it never leaves your machine and is not part of the key pair. `ssh-keygen -p` re-encrypts the same private key material under a new passphrase. The public key is byte-identical, so nothing on any server changes.

### Block 2 — Public key authentication

**6.** It would have been `student@localhost's password:` — the account password prompt. The distinction locates the secret: a *passphrase* prompt is local, produced by the client to decrypt `~/.ssh/id_ed25519`, and means the server already accepted this key's public half as an offer worth pursuing. A *password* prompt means public-key authentication failed or was never attempted, and the client fell back to the `password`/`keyboard-interactive` method, sending a secret over the (encrypted) channel to the server.

**7.** Mode 644 works fine. `sshd`'s `StrictModes yes` rejects `authorized_keys` only when it is writable by group or other — readability is irrelevant, since the file contains public keys. Mode 664 **breaks** authentication: group-writable means another account in that group could append its own key and impersonate you. The same rule applies to `~/.ssh` and to the home directory itself, which is what step 5 demonstrated.

**8.** Because `sshd` deliberately does not tell the client *why* authentication failed — reporting "your home directory is group-writable" would leak filesystem state to an unauthenticated peer. The client only ever sees `Permission denied (publickey)`. This is the single most important habit for diagnosing key auth: `ssh -vvv` shows you which key was *offered*, but only `journalctl -u sshd` (or `LogLevel DEBUG` in `sshd_config`) shows why it was *refused*.

**9.** `restrict` (OpenSSH 7.2+) is a deny-all default: it disables port forwarding, agent forwarding, X11 forwarding, PTY allocation, `~/.ssh/rc` execution and any *future* capability OpenSSH adds. The explicit list disables only what existed when you wrote it — a new feature added in a later release would be permitted. `restrict` is therefore the safe form, and individual capabilities can be re-enabled after it (e.g. `restrict,pty`).

**10.** The client still sends the requested command, and `sshd` sets it in the `SSH_ORIGINAL_COMMAND` environment variable before executing the forced `command=` instead. Nothing is executed from the user's string — but the forced command can read it, which is exactly how gate scripts (like `git-shell` or rsync wrappers) implement selective dispatch. If your forced command passes `SSH_ORIGINAL_COMMAND` to a shell, you have reintroduced arbitrary execution.

### Block 3 — Host keys and `known_hosts`

**11.** `sshd` reads it, running as root, during the key exchange — before any authentication. The server signs the exchange hash with its host private key; the client verifies that signature against the public key stored in `known_hosts`. This is what binds the encrypted channel to a specific server identity and is why a stolen host private key enables a man-in-the-middle attack even without any user credential.

**12.** Typing `yes` means "I accept whatever key you just showed me" — pure trust-on-first-use with no verification. Typing (pasting) the fingerprint makes the *client* compare it against the key the server actually presented and abort on mismatch, so you cannot accidentally accept an attacker's key by typing `yes` reflexively. It only helps if you obtained the fingerprint through an independent channel (console output, configuration management, a signed document).

**13.** Cost: you can no longer `grep` or read `known_hosts`; you must use `ssh-keygen -F host` to search and `-R host` to remove, and you cannot audit at a glance which hosts a user has connected to. Mitigation: if the file is stolen — by malware or from a backup — the attacker cannot enumerate your infrastructure from it, which historically was a favourite lateral-movement map for worms.

**14.** The correct fix is to pre-populate the host key: distribute `/etc/ssh/ssh_known_hosts` (or a per-user `known_hosts`) from configuration management using fingerprints collected from a trusted source, or use `ssh-keyscan` output verified against the server's own `ssh-keygen -l /etc/ssh/ssh_host_*_key.pub`. `StrictHostKeyChecking=no` accepts *any* key silently and also disables the mismatch warning, so it converts a hang into a permanent, invisible man-in-the-middle exposure. `accept-new` is a middle ground: it auto-accepts unknown hosts but still refuses on a *changed* key.

**15.** `known_hosts.old` still contains the old, possibly attacker-supplied entry. If you later restore or merge that file — or if a backup script picks it up — you silently reinstate trust in the compromised key. After a suspected compromise, delete `known_hosts.old` explicitly and re-verify the new fingerprint out of band.

### Block 4 — `ssh-agent` / `ssh-add`

**16.** Exit 2 = cannot contact the agent at all (`SSH_AUTH_SOCK` unset or the socket is dead). Exit 1 = the agent answered, but holds no identities. Exit 0 = at least one identity is loaded. A script can therefore distinguish "start an agent" (2) from "prompt the user to `ssh-add`" (1) instead of guessing from output text.

**17.** `ssh-agent -s` forks the daemon and prints *shell code* on stdout; it cannot modify its parent shell's environment. `eval` executes that code in the current shell so `SSH_AUTH_SOCK` and `SSH_AGENT_PID` are exported where `ssh` will see them. Running `$(ssh-agent -s)` without `eval` makes the shell attempt to execute the first word of the output — `SSH_AUTH_SOCK=/tmp/...` — as a command, which sets nothing useful and typically errors; meanwhile the agent process is left running, orphaned and unreachable.

**18.** While your session is alive, root on that host can read `SSH_AUTH_SOCK`, connect to the forwarded socket, and ask your agent to sign challenges — effectively authenticating as you to any host that trusts your key, for as long as you stay connected. What they **cannot** do is extract the private key: the agent only ever returns signatures, never key material. Mitigations: `ssh-add -c` (confirm each use), short `-t` lifetimes, `ForwardAgent no` by default and per-host opt-in, or `ProxyJump` instead of agent forwarding.

**19.** The directory mode. The socket's own permissions are advisory on some kernels' handling of Unix sockets, so OpenSSH does not rely on them: it creates the socket inside a `0700` directory owned by you, and directory traversal permission is what actually denies other users the ability to `connect()`. Note that root bypasses both.

**20.** Wrap it in `eval` the same way as when starting: `eval "$(ssh-agent -k)"`. Like `-s`, the `-k` option kills the daemon and prints the shell commands (`unset ...`) needed to clean up the environment, but it cannot alter your shell by itself.

### Block 5 — Client configuration and forwarding

**21.** For `-L 8022:localhost:22`, the client listens locally and the *server* resolves and connects to `localhost:22` — so `localhost` is the SSH server itself. For `-R 9022:localhost:22`, the server listens and the *client* resolves and connects to `localhost:22` — so `localhost` is your workstation. The rule: the destination host:port in a forwarding spec is always resolved by the endpoint that opens the outbound connection, which is the opposite end from the one that listens.

**22.** Without `IdentitiesOnly yes`, `ssh` offers `IdentityFile` entries *plus* every key loaded in the agent, in agent order. With many keys loaded, the server can hit `MaxAuthTries` (default 6) and reject you before your correct key is offered — the classic "too many authentication failures" error. `IdentitiesOnly yes` restricts the offer to the keys named in the configuration (still using the agent to *hold* them).

**23.** `-N` means "do not execute a remote command", so the connection carries only the tunnel; `-f` backgrounds `ssh` after authentication, so your shell returns. Without `-N`, `-f` would background a full login shell with no terminal attached, which typically exits immediately (or hangs on input), tearing the tunnel down with it. Combining both gives a pure, persistent tunnel process.

**24.** For `-L`, the listening socket belongs to the *client* process running under your account on your machine — you are entitled to bind any unprivileged address there, so no server permission is involved. For `-R`, the listening socket is opened by `sshd` on the server; exposing it beyond loopback would let arbitrary third parties enter your tunnel, so the server administrator controls it with `GatewayPorts` (`no` = loopback only, `yes` = any address, `clientspecified` = honour the client's bind address).

**25.** (a) The escape character was disabled or changed — `EscapeChar none` in `ssh_config`, or `-e none` on the command line (common in scripted sessions). (b) The `~` was not the first character after a newline; escapes are only recognised immediately following a line break, so pressing `Enter` first is mandatory. A third case: you are in a *nested* SSH session, where the outer client consumes the escape — use `~~.` to reach the inner one.

**26.** With `--socks5-hostname` (SOCKS5h), the hostname is sent to the proxy as a name and resolved by the **SSH server**, at the far end of the tunnel. That matters on a bastion because internal DNS names that do not resolve on your workstation still work, and because your local resolver never sees which internal hosts you are visiting. Plain `--socks5` resolves locally and forwards only the IP address, which breaks split-horizon DNS and leaks the query.

### Block 6 — GnuPG keys and keyring

**27.** `S` = Sign, `C` = Certify (sign other keys and your own UIDs), `E` = Encrypt; you may also see `A` = Authenticate. Encryption is a subkey because the two roles have different lifecycles and different loss semantics: an encryption subkey can be rotated or revoked and replaced without destroying your identity or the web of trust built on the primary key, while losing the encryption subkey costs you access to past ciphertext. The certification-capable primary key is the long-term identity and is often kept offline.

**28.** Private key material lives in `~/.gnupg/private-keys-v1.d/<KEYGRIP>.key`, one file per key, managed exclusively by `gpg-agent`. The public keyring is `~/.gnupg/pubring.kbx` (keybox format). Before GnuPG 2.1 secret keys lived in `~/.gnupg/secring.gpg`; that file no longer exists and is migrated on first use of a modern GnuPG — an exam-favourite distinction.

**29.** Ultimate trust means "signatures made by this key are, for trust-computation purposes, as good as my own" — correct for a key whose private half you just generated and control. Assigning it to an imported key tells GnuPG to accept everything that key has certified, transitively, so a single bad import silently validates an arbitrary set of identities. Imported keys should be validated by verifying the fingerprint out of band and then signing/certifying them, letting the web-of-trust computation assign validity.

**30.** They are the same key, truncated from the right: the 40-hex-character (160-bit) fingerprint is the full identifier; the long key ID `9F3C1D77A2B40E51` is its last 64 bits; the short ID `A2B40E51` is the last 32 bits. Only the **full fingerprint** is acceptable for in-person verification — short IDs have been publicly collided (deliberately, at low cost), and long IDs are within reach for a determined attacker. Prefer `--keyid-format LONG` at minimum, and compare full fingerprints when it matters.

**31.** `--homedir` gives Bob a completely separate GnuPG state: his own keyring, his own `trustdb.gpg`, his own `private-keys-v1.d/` and his own agent. `--keyring` would only add another public keyring file to the *current* home, still sharing Ada's trust database and, critically, her secret keys — so a "Bob cannot decrypt this" test would silently succeed using Ada's private key. Isolating the home directory is the only way to honestly simulate a second party on one machine.

### Block 7 — Encrypt, decrypt, sign, verify

**32.** Cipher 9 is AES-256 (7 = AES-128, 8 = AES-192, 2 = 3DES). The decrypting side does not need to be told out of band: the symmetric-key-encrypted-session-key packet carries the algorithm ID, the S2K specifier (mode 3 = iterated+salted), the hash and the salt, so `gpg` derives the same key from your passphrase and knows which cipher to instantiate. The same holds for public-key encryption, where the session key is delivered inside the `pubkey enc packet`.

**33.** GnuPG answered the *cryptographic* question: this signature was produced by the private key matching fingerprint `4B1E…0E51`, and the document has not been altered since. It refused the *identity* question: nothing in Bob's keyring establishes that this key actually belongs to a human called Ada Lovelace. Validity is a trust computation over certifications, not a property of the mathematics — which is why the warning appears even though the signature is `Good`.

**34.** `--clearsign` keeps the text readable: it wraps the original in `BEGIN PGP SIGNED MESSAGE` with the signature appended in armor, which is why it is used for mailing-list posts and announcements. For a 4 GB ISO use `--detach-sign`: the signature is a separate small file, so the image is distributed unmodified, can be verified without rewriting or copying 4 GB, and consumers who do not care about signatures can use it as-is. `--sign` (binary, embedded and compressed) would produce a second 4 GB artefact that must be unwrapped before use.

**35.** The order is `gpg --verify <signature-file> <data-file>` — signature first. If you supply only the `.asc`, GnuPG applies its guessing rule: it strips a `.asc`/`.sig`/`.gpg` suffix and looks for a file of that name in the same directory. That works when the names match (`notes.txt.asc` → `notes.txt`) and fails confusingly when they do not, so being explicit is the habit worth building.

**36.** Add `--recipient <your-own-key>` a second time, or set `default-recipient-self` / `encrypt-to <your-key-id>` in `~/.gnupg/gpg.conf`. It is not the default because encrypting to an extra key is a disclosure decision, not a convenience: it silently widens the recipient set, is visible to anyone running `--list-packets` on the ciphertext (revealing that you also encrypted to yourself), and in some threat models the whole point is that the sender cannot later be compelled to produce the plaintext.

### Block 8 — Agent, expiration, revocation

**37.** `default-cache-ttl` is an *idle* timer refreshed on each use; `max-cache-ttl` is an absolute ceiling measured from the moment the passphrase was entered, and is never refreshed. Sign at t=0 (prompt), then again at t=50, t=100, t=150, t=250 — each within 60 s of the previous, so the idle timer never fires. At t=300 the absolute maximum expires and the cache entry is dropped regardless of activity, so the next signature prompts again.

**38.** Signatures Ada made *before* the revocation remain verifiable and, depending on the stated reason, may remain trustworthy: revoking for "key is no longer used" (reason 2) leaves past signatures valid, whereas "key has been compromised" (reason 1) invalidates them retroactively, since an attacker could have produced them. Documents already encrypted to her are still decryptable — she still holds the private key; revocation is a public statement not to *use* the key going forward, not a destruction of key material.

**39.** In `~/.gnupg/openpgp-revocs.d/<FINGERPRINT>.rev`, mode 600, generated automatically at key creation since GnuPG 2.1. The risk is symmetric to its purpose: anyone who can read that file can publish it and permanently revoke your key (a denial-of-service on your identity), and anyone who destroys your disk destroys both the key *and* the ability to announce its revocation. Best practice is to move it to separate offline media — printed or on a different encrypted device — not leave it beside `private-keys-v1.d/`.

**40.** (a) A keyserver, if the key was published there and Bob refreshes with `gpg --refresh-keys` (or has `auto-key-retrieve` / a keyserver configured). (b) Web Key Directory (WKD), where the domain owner publishes the current key over HTTPS at a well-known URL and `gpg --locate-keys` fetches it. The manual fallback used in step 8 is exporting the now-revoked public key and delivering it out of band for `gpg --import` — importing the *key* carries the revocation signature with it, which is why re-importing an existing key still updates its status.

**41.** `--reload` sends a reload signal: the agent re-reads `gpg-agent.conf` and keeps running, so cached passphrases survive. `--kill` terminates the daemon, discarding the entire cache; the next `gpg` invocation starts a fresh agent. Changing `pinentry-program` is the case that usually needs the kill, because the agent binds its pinentry helper at startup — as do socket-related options such as `extra-socket` and `enable-ssh-support`.

**42.** Yes. An expiration date is not a lock; it is a self-signature on the key stating a validity period, and the holder of the primary key can always issue a new self-signature with a later date — even years after it lapsed — and republish the key. That is precisely why expiration is a *dead-man's switch* rather than a security control: it makes an abandoned key visibly stale to everyone who refreshes it, while remaining fully recoverable by its legitimate owner. Revocation, by contrast, is irreversible.

</details>

---

### Official sources

- LPI — Exam 101-500 Objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Exam 102-500 Objectives (topic 110.3): https://www.lpi.org/our-certifications/exam-102-objectives/
- OpenSSH — `ssh(1)`: https://man.openbsd.org/ssh.1
- OpenSSH — `ssh_config(5)`: https://man.openbsd.org/ssh_config.5
- OpenSSH — `ssh-keygen(1)`: https://man.openbsd.org/ssh-keygen.1
- OpenSSH — `ssh-agent(1)` / `ssh-add(1)`: https://man.openbsd.org/ssh-agent.1 · https://man.openbsd.org/ssh-add.1
- OpenSSH — `sshd(8)`, `AUTHORIZED_KEYS FILE FORMAT`: https://man.openbsd.org/sshd.8
- GnuPG — Using the GNU Privacy Guard (manual): https://www.gnupg.org/documentation/manuals/gnupg/
- GnuPG — `gpg-agent` options: https://www.gnupg.org/documentation/manuals/gnupg/Agent-Options.html
- GnuPG — GnuPG 2.1 changes (`secring.gpg` removal, revocation directory): https://www.gnupg.org/faq/whats-new-in-2.1.html
- RFC 4880 — OpenPGP Message Format (packet types, cipher IDs): https://www.rfc-editor.org/rfc/rfc4880