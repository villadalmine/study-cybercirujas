# Exercises: Security (Topic 2.6)

## Exercise 1: Finding and Inspecting SUID Binaries

SUID binaries run with the privileges of their owner. Finding unauthorized SUID binaries is a key part of host security auditing.

1. Search the entire filesystem for files with the SUID bit set (`-perm -4000`) and display their details:
   ```bash
   sudo find / -perm -4000 -type f -exec ls -la {} \; 2>/dev/null
   ```
2. Identify the `passwd` binary in the output and note its permissions.
3. Check the file capabilities of the `ping` command (modern systems often use capabilities instead of SUID for `ping`):
   ```bash
   getcap /usr/bin/ping
   ```

**Question 1.1:** Why does the `passwd` command need the SUID bit set in order to function correctly for a standard user?
**Question 1.2:** In the output of `ls -la`, how is the SUID bit represented in the permissions string?

---

## Exercise 2: Auditing Open Sockets with `lsof` and `ss`

To enforce a zero-trust model, you must know exactly which processes are listening on the network.

1. List all active, listening TCP ports on the system using `ss`:
   ```bash
   sudo ss -tlnp
   ```
2. Use `lsof` to find which specific process is listening on port 22 (SSH):
   ```bash
   sudo lsof -i :22
   ```

**Question 2.1:** If `ss -tlnp` shows a service listening on `0.0.0.0:80`, what does the `0.0.0.0` address mean?
**Question 2.2:** Why is `sudo` necessary to see the `Process` column in `ss` or to get the full output from `lsof`?

---

## Exercise 3: SSH Key Generation and Management

Password-based SSH authentication is inherently vulnerable to brute-force attacks.

1. Generate a new Ed25519 SSH key pair for your user:
   ```bash
   ssh-keygen -t ed25519 -C "lab-exercise"
   ```
   (Press Enter to accept default paths, and optionally enter a passphrase).
2. Start the `ssh-agent` in the background and add your new key to it:
   ```bash
   eval $(ssh-agent -s)
   ssh-add ~/.ssh/id_ed25519
   ```

**Question 3.1:** What is the primary advantage of using an `ssh-agent`?
**Question 3.2:** If you want to disable password authentication entirely for SSH, which directive in `/etc/ssh/sshd_config` must you change, and to what value?

---

<details>
<summary><strong>Answers</strong></summary>

**Answer 1.1:** The `passwd` command needs to write the new password hash into the `/etc/shadow` file. Because `/etc/shadow` is only readable and writable by the `root` user, a standard user executing `passwd` temporarily assumes `root` privileges (via the SUID bit) just for the duration of the command.

**Answer 1.2:** The SUID bit replaces the executable `x` bit in the user (owner) portion of the permissions string with an `s` (e.g., `-rwsr-xr-x`).

**Answer 2.1:** The address `0.0.0.0` indicates that the service is binding to *all* available IPv4 interfaces on the host (e.g., localhost, Ethernet, Wi-Fi, VPN tunnels).

**Answer 2.2:** A standard user is only permitted to see the file descriptors and network sockets belonging to their own processes. To inspect sockets opened by services running as `root` or other users, elevated privileges are required.

**Answer 3.1:** An `ssh-agent` securely stores decrypted private keys in memory. If your private key is protected by a passphrase, you only need to type the passphrase once when adding it to the agent. The agent then handles authentication for all subsequent SSH connections.

**Answer 3.2:** You must change `PasswordAuthentication` to `no` (and ensure `PermitEmptyPasswords` is also `no`).
</details>