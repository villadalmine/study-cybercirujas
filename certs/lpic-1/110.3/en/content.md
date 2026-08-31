# 110.3 — Securing Data with Encryption

**LPIC-1 (101-500 / 102-500), version 5.0 — Topic 110: Security**

Objective coverage: OpenSSH 2 client configuration and usage; the role of host keys; GnuPG configuration, usage and revocation; SSH port tunnels including X11 tunnels.
Files and commands in scope: `ssh`, `ssh-keygen`, `ssh-agent`, `ssh-add`, `~/.ssh/id_rsa{,.pub}`, `~/.ssh/id_dsa{,.pub}`, `~/.ssh/id_ecdsa{,.pub}`, `~/.ssh/id_ed25519{,.pub}`, `/etc/ssh/ssh_host_{rsa,dsa,ecdsa,ed25519}_key{,.pub}`, `~/.ssh/authorized_keys`, `ssh_known_hosts`, `gpg`, `gpg-agent`, `~/.gnupg/`.

---

## 1. Motivation and the production architectural problem

### 1.1 What "securing data with encryption" actually buys you

Encryption is not a feature you switch on. It is a set of guarantees you choose to purchase, each with a different runtime cost and a different failure mode. On a Linux platform there are exactly three planes where those guarantees are bought:

| Plane | Guarantee | Adversary model | Tooling in this objective |
|---|---|---|---|
| **Data in transit** | Confidentiality + integrity + **peer authentication** on the wire | On-path attacker (rogue switch, hostile NAT, BGP hijack, compromised jump host) | OpenSSH transport |
| **Data at rest** | Confidentiality of a blob independent of the filesystem it lives on | Anyone who can read the file later: backup tape, git history, S3 bucket, `etcd` dump, a stolen laptop | GnuPG (OpenPGP) |
| **Data provenance** | Non-repudiable proof of *who produced this artifact* | Supply-chain attacker who can write to your registry, mirror or git remote | GnuPG signatures, `ssh-keygen -Y` signatures |

The plane most engineers get wrong is the second half of the first row: **peer authentication**. An SSH session to the wrong host is perfectly encrypted and completely compromised. Every real SSH incident in production is an authentication failure, never a cipher failure.

### 1.2 The architectural problem: identity at fleet scale

Consider the realistic shape of a platform: 400 nodes across 3 regions, replaced continuously by an autoscaler, plus 40 engineers, plus 12 CI runners that need to push artifacts and pull private modules.

Naïve SSH gives you a **quadratic trust problem**:

- Every one of the 440 clients must learn the host key of every one of the 400 servers → up to 176,000 trust decisions.
- Every new node minted by the autoscaler generates *fresh* host keys at first boot, so `known_hosts` is permanently wrong.
- The human response to "permanently wrong" is `StrictHostKeyChecking no`, which deletes the entire authentication guarantee of the transport. This is the single most common self-inflicted SSH vulnerability in the industry.

And a symmetric problem on the user side:

- 40 engineers × 400 nodes of `authorized_keys` entries, distributed by configuration management, means an offboarded engineer is only revoked when the next config-management run lands on every node — including the nodes that are cordoned, unreachable, or in a stuck rollout.

The three production answers, in order of maturity:

1. **Public key pinned out-of-band** — bake `/etc/ssh/ssh_known_hosts` from a trusted inventory at image build time, or publish `SSHFP` records in DNSSEC-signed DNS. Removes TOFU, keeps the quadratic bookkeeping.
2. **SSH certificates** — a host CA signs host keys, a user CA signs user keys. Trust becomes **2 keys instead of 176,000 pairings**, and user certificates carry a `validity` window, so revocation becomes *expiry* rather than a config-management race. This is what every large-scale SSH deployment converges on.
3. **Hardware-bound keys** — `ed25519-sk`/`ecdsa-sk` (FIDO2) or an OpenPGP smartcard, so the private key is *not exfiltratable* even from a fully compromised workstation. This is the only control that survives a stolen laptop with a live agent.

For data at rest, the equivalent architectural problem is the **secret-in-git problem**: a Kubernetes `Secret` is base64, not encryption; a Terraform state file contains plaintext credentials; a Helm `values.yaml` in a private repo is one fork away from public. GnuPG (or age, via the same envelope pattern) solves this by making the repository the transport and the key material the boundary — the file is encrypted *to a set of recipients*, and the CI runner is one of them.

### 1.3 The non-goals — state these to your students explicitly

- SSH does **not** protect data at rest on either endpoint. `scp` a database dump and it lands in plaintext.
- GnuPG does **not** give forward secrecy. A message encrypted to your key today is readable tomorrow if that key leaks. SSH *does* (ephemeral ECDH per session).
- Neither protects against a compromised endpoint. Agent forwarding into a hostile host is equivalent to handing over the key for the duration of the session.

---

## 2. Technical comparatives and trade-offs

### 2.1 SSH key algorithms

```
$ ssh -Q key
ssh-ed25519
ssh-ed25519-cert-v01@openssh.com
sk-ssh-ed25519@openssh.com
sk-ssh-ed25519-cert-v01@openssh.com
ecdsa-sha2-nistp256
ecdsa-sha2-nistp384
ecdsa-sha2-nistp521
sk-ecdsa-sha2-nistp256@openssh.com
ssh-rsa
rsa-sha2-256
rsa-sha2-512
```

| Algorithm | Key size on disk | Security level | Signing speed | Notes for production |
|---|---|---|---|---|
| `ssh-ed25519` | 68 B pubkey, 399 B private | ~128-bit | Fastest | **Default choice.** Constant-time, no parameter choices to get wrong, no RNG-quality dependency at signature time. Supported since OpenSSH 6.5 (2014). |
| `sk-ssh-ed25519@openssh.com` | Handle only; secret in token | ~128-bit + hardware | Fast + touch latency | Ed25519 with a FIDO2 authenticator. Private key **cannot** be copied off the device. Requires OpenSSH ≥ 8.2 on client **and** server. |
| `rsa-sha2-512` (RSA-4096) | ~3.2 KB private | ~128–140-bit | Slow keygen, slow verify | Only for interoperating with legacy servers or hardware that predates EdDSA. RSA-2048 is the practical floor; RSA-1024 is dead. |
| `ecdsa-sha2-nistp256` | 178 B pubkey | ~128-bit | Fast | Works, but ECDSA fails catastrophically on nonce reuse and depends on the RNG at signature time. Prefer Ed25519. |
| `ssh-dss` (DSA) | 1024-bit fixed | ~80-bit — broken | — | **Do not use.** Disabled by default since OpenSSH 7.0, compile-time disabled by default in 9.8, removed in OpenSSH 10.0. The LPIC-1 objective still lists `~/.ssh/id_dsa` — know the filename, never create one. |

> **Exam trap and production trap in one:** OpenSSH 8.8 (2021) disabled the `ssh-rsa` signature algorithm (RSA with SHA-1) by default. An RSA *key* is still fine; the SHA-1 *signature scheme* is not. Symptom is `no mutual signature algorithm` against old servers, fixed on the client with `PubkeyAcceptedAlgorithms +ssh-rsa` — a targeted `Host` block, never a global one.

### 2.2 Host-key trust models

| Model | Bootstrap cost | Revocation | Autoscaling friendly | Failure mode |
|---|---|---|---|---|
| **TOFU** (`StrictHostKeyChecking ask`, the default) | Zero | Manual `ssh-keygen -R` | ✗ — every new node prompts | User habituation: engineers type `yes` reflexively |
| **`StrictHostKeyChecking no`** | Zero | N/A | ✓ | **No authentication at all.** Never in production. |
| **`accept-new`** (OpenSSH ≥ 7.6) | Zero | `ssh-keygen -R` | Partial | Accepts unknown hosts silently, but *refuses changed* keys. A pragmatic middle ground for ephemeral CI. |
| **Pre-seeded `/etc/ssh/ssh_known_hosts`** | Build a trusted inventory | Rebuild + redistribute the file | ✗ | Stale file → hard failures on legitimate rebuilds |
| **SSHFP in DNSSEC** (`VerifyHostKeyDNS yes`) | DNSSEC zone + automation | Zone update, honours TTL | ✓ | Silently degrades to TOFU if DNSSEC validation is unavailable |
| **Host certificates (`@cert-authority`)** | One CA keypair | CA rotation or `RevokedHostKeys` | ✓✓ | CA private key compromise is total; keep it offline/HSM |

### 2.3 Key-exchange and cipher selection

```
$ ssh -Q kex | head -12
diffie-hellman-group1-sha1
diffie-hellman-group14-sha1
diffie-hellman-group14-sha256
diffie-hellman-group16-sha512
diffie-hellman-group18-sha512
diffie-hellman-group-exchange-sha1
diffie-hellman-group-exchange-sha256
ecdh-sha2-nistp256
ecdh-sha2-nistp384
ecdh-sha2-nistp521
curve25519-sha256
curve25519-sha256@libssh.org

$ ssh -Q cipher
3des-cbc
aes128-cbc
aes192-cbc
aes256-cbc
aes128-ctr
aes192-ctr
aes256-ctr
aes128-gcm@openssh.com
aes256-gcm@openssh.com
chacha20-poly1305@openssh.com
```

| Choice | When it wins | Cost |
|---|---|---|
| `chacha20-poly1305@openssh.com` | CPUs without AES-NI (ARM SBCs, older embedded, some cloud burstables) | ~10–20 % slower than AES-GCM where AES-NI exists |
| `aes256-gcm@openssh.com` | Anything with AES-NI — bulk transfer, backups over SSH | Needs hardware acceleration to beat ChaCha20 |
| `curve25519-sha256` | Default KEX; fast, no NIST-curve concerns | — |
| Hybrid post-quantum KEX (`sntrup761x25519-sha512@openssh.com`, `mlkem768x25519-sha256`) | **Harvest-now-decrypt-later** threat: long-lived session content recorded today | Larger handshake, negligible CPU; both peers must be recent OpenSSH. Modern OpenSSH negotiates a hybrid PQ KEX by default. |
| CBC modes, `3des-cbc`, `*-sha1` MACs | Never | Legacy only; disable explicitly |

Verify what a peer actually negotiated rather than what you configured:

```
$ ssh -v node-a.prod.example.net true 2>&1 | grep -E 'kex:|cipher|compat'
debug1: kex: algorithm: mlkem768x25519-sha256
debug1: kex: host key algorithm: ssh-ed25519
debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
```

### 2.4 Tunnel types

| Flag | Direction | Listener runs on | Canonical use | Main hazard |
|---|---|---|---|---|
| `-L [bind:]lport:dhost:dport` | Local → remote | **Client** | Reach a DB bound to `127.0.0.1` on a remote node | Exposing the listener on `0.0.0.0` |
| `-R [bind:]rport:dhost:dport` | Remote → local | **Server** | Expose a service from a NAT'd network to a bastion | Requires `GatewayPorts` on the server to bind non-loopback; silently binds loopback otherwise |
| `-D [bind:]port` | Client → anywhere | **Client** | SOCKS5 proxy, browsing through a network boundary | Everything on the box can use it; bind loopback only |
| `-W host:port` | stdio → remote | none | Building block of `ProxyCommand` | Superseded by `ProxyJump` |
| `-J user@jump` | n/a | none | Multi-hop **without** agent forwarding | None — this is the correct answer |
| `-X` / `-Y` | X11 channel | Server sets `DISPLAY` | Run a GUI tool remotely | `-Y` (trusted) disables the X security extension: the remote app can keylog your entire X session |
| `-A` (agent forwarding) | Agent socket | Server | Chained logins | **A root user on the remote host can use your agent for as long as you are connected.** Prefer `-J`. |

| Alternative to SSH tunnels | Strength | Weakness |
|---|---|---|
| `ssh -L/-R` | Zero extra infrastructure, per-user auth, audit trail on the bastion | Per-session, TCP-only, dies with the session, TCP-over-TCP meltdown under loss |
| WireGuard | Kernel-space, UDP, roaming, survives link changes | Needs a peer registry and IP planning; no per-user identity by itself |
| `kubectl port-forward` | No node access needed, RBAC-scoped | Single connection, no HA, dies on pod restart |
| Service mesh mTLS | Transparent to apps, identity per workload | Heavy control plane; irrelevant for operator access |

### 2.5 GnuPG algorithm and topology choices

| Choice | Recommendation | Rationale |
|---|---|---|
| Primary key algorithm | `ed25519` (`future-default`) | Small, fast, no parameter selection. RSA-4096 only when a counterpart's tooling is ancient. |
| Encryption subkey | `cv25519` | X25519 ECDH; paired automatically with `future-default`. |
| Capabilities split | Primary `[C]` only; subkeys `[S]`, `[E]`, `[A]` | Compromise of a laptop loses a *subkey*, which you revoke and replace. Compromise of the primary loses your identity. |
| Primary key storage | Offline (encrypted USB / air-gapped) or smartcard | `gpg --export-secret-subkeys` puts only subkeys on the daily driver. |
| Expiry | Subkeys 1 year, primary 2–3 years or never-with-offline-storage | Expiry is a dead-man's switch for keys you lose access to. |
| Revocation certificate | Generate **at creation**, store separately from the key | GnuPG ≥ 2.1 writes one automatically to `~/.gnupg/openpgp-revocs.d/<FPR>.rev`. If you lose both key and revocation certificate, your published key is immortal and unusable. |

| Symmetric vs asymmetric at rest | `gpg --symmetric` | `gpg --encrypt -r` |
|---|---|---|
| Key distribution | Out-of-band shared passphrase | Recipient public keys, distributable in the clear |
| Adding a consumer | Reshare the passphrase to everyone | Re-encrypt to one more recipient |
| Revoking a consumer | Rotate the passphrase everywhere | Re-encrypt without them (past copies stay readable — rotate the plaintext secret) |
| CI-friendly | Passphrase in a env var — awkward but simple | Private key in the runner, `--pinentry-mode loopback` |
| Right use | One-off archive, backup blob | Repository secrets, multi-consumer artifacts |

---

## 3. Complete infrastructure manifests

### 3.1 `~/.ssh/config` — a production client configuration

```sshconfig
# ~/.ssh/config — mode 0600
# Order matters: OpenSSH applies the FIRST value obtained for each keyword.
# Put specific Host blocks above general ones.

Host bastion-eu
    HostName          bastion.eu-west-1.example.net
    User              sre
    Port              22
    IdentityFile      ~/.ssh/id_ed25519_sk_prod
    IdentitiesOnly    yes
    # Certificate issued by the user CA; short-lived, refreshed by `step ssh login`
    CertificateFile   ~/.ssh/id_ed25519_sk_prod-cert.pub
    ForwardAgent      no
    ControlMaster     auto
    ControlPath       ~/.ssh/cm/%C
    ControlPersist    10m

# Every production node is reached through the bastion. No direct exposure.
Host *.prod.example.net 10.42.*
    User              sre
    ProxyJump         bastion-eu
    IdentityFile      ~/.ssh/id_ed25519_sk_prod
    IdentitiesOnly    yes
    ForwardAgent      no
    ForwardX11        no
    StrictHostKeyChecking yes
    UserKnownHostsFile /etc/ssh/ssh_known_hosts ~/.ssh/known_hosts

# Ephemeral CI workers: keys change on every rebuild, so accept-new is the
# strongest setting that still works. It refuses CHANGED keys, unlike `no`.
Host ci-runner-*
    User              runner
    IdentityFile      ~/.ssh/id_ed25519_ci
    IdentitiesOnly    yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts.ci

Host github.com
    User              git
    IdentityFile      ~/.ssh/id_ed25519_git
    IdentitiesOnly    yes
    # GitHub publishes host keys over HTTPS; pin them, do not TOFU them.
    UserKnownHostsFile ~/.ssh/known_hosts.github

Host *
    # Defaults applied to everything not matched above.
    AddKeysToAgent        yes
    HashKnownHosts        yes
    UpdateHostKeys        yes
    VerifyHostKeyDNS      ask
    ServerAliveInterval   30
    ServerAliveCountMax   3
    TCPKeepAlive          no
    Compression           no
    ExitOnForwardFailure  yes
    PubkeyAcceptedAlgorithms sk-ssh-ed25519@openssh.com,ssh-ed25519,rsa-sha2-512,rsa-sha2-256
    HostKeyAlgorithms     ssh-ed25519-cert-v01@openssh.com,ssh-ed25519,rsa-sha2-512
    Ciphers               chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
    MACs                  hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
    KexAlgorithms         mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256
```

> `ExitOnForwardFailure yes` is the difference between "my tunnel is up" and "my tunnel silently failed and I am talking to a local service by accident". Set it globally.

### 3.2 `/etc/ssh/sshd_config` — host-key roles made explicit

```sshconfig
# /etc/ssh/sshd_config — the server half of the trust relationship.
# The HOST key proves the SERVER's identity to the client. It is never used
# to authenticate users.

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
# ECDSA and DSA host keys deliberately absent.

# Host certificate signed by the host CA: clients that trust the CA need no
# per-host known_hosts entry at all.
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub

# Users authenticate with certificates issued by the user CA...
TrustedUserCAKeys /etc/ssh/user_ca.pub
RevokedKeys       /etc/ssh/revoked_user_keys
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
# ...and, as a break-glass fallback, with raw keys from a root-owned path.
AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u .ssh/authorized_keys

PermitRootLogin           no
PasswordAuthentication    no
KbdInteractiveAuthentication no
PubkeyAuthentication      yes
AuthenticationMethods     publickey
UsePAM                    yes

# Forwarding policy: deny by default, allow per-group.
AllowAgentForwarding      no
AllowTcpForwarding        no
GatewayPorts              no
X11Forwarding             no
PermitTunnel              no

Match Group bastion-users
    AllowTcpForwarding    yes
    PermitOpen            10.42.0.0/16:5432 10.42.0.0/16:6443
    ForceCommand          /usr/local/sbin/bastion-shell

Match Group desktop-admins
    X11Forwarding         yes
    X11UseLocalhost       yes
    AllowAgentForwarding  no

LogLevel VERBOSE
Subsystem sftp /usr/lib/openssh/sftp-server -f AUTHPRIV -l INFO

KexAlgorithms  mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256
Ciphers        chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs           hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

### 3.3 `~/.ssh/authorized_keys` — constrained entries

```
# One line per key. Options come BEFORE the key type. Line order is irrelevant.

# Full interactive access, restricted to the bastion's source addresses.
from="10.42.0.10,10.42.0.11" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0f7c9pQ2m4hV1sT7nQ8xJd3bK9wRfZ1Yv6uLg0aXcP sre@laptop

# Backup robot: may run exactly one command, no PTY, no forwarding of any kind.
# `restrict` (OpenSSH >= 7.2) denies everything, then we re-enable nothing.
restrict,command="/usr/local/sbin/rrsync -ro /srv/backup",from="10.42.9.5" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKp5rV2sQ9cM8xL0wYnT4jB7hF3dZ1uR6gE2vX9kOaTs backup@controller

# Tunnel-only account: no shell at all, only a forward to the Postgres primary.
restrict,port-forwarding,permitopen="db-primary.prod:5432",command="/bin/false" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4tN9wQ2xR7vK1mZ0cJ8fL5hY3dP6sU9gT2bX7nWaEq analytics@grafana

# Hardware-backed key: server enforces user presence (touch) on every auth.
verify-required,restrict,pty ecdsa-sk-... AAAAInNr...  oncall@yubikey
```

### 3.4 `cloud-init` — a node that boots with a signed host certificate

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Boots a node whose host key is signed by the host CA, so no client ever
# performs a TOFU decision against it.

users:
  - name: sre
    groups: [sudo, bastion-users]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys: []          # deliberately empty: certificates only

write_files:
  - path: /etc/ssh/user_ca.pub
    permissions: "0644"
    owner: root:root
    content: |
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDq7hW2mX9pR4vT1cL8sJ0nY6bK3fZ5uQ7gE2dV9wXaM user-ca@example.net

  - path: /etc/ssh/auth_principals/sre
    permissions: "0644"
    owner: root:root
    content: |
      sre
      oncall

  - path: /etc/ssh/sshd_config.d/10-hardening.conf
    permissions: "0600"
    owner: root:root
    content: |
      HostKey /etc/ssh/ssh_host_ed25519_key
      HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
      TrustedUserCAKeys /etc/ssh/user_ca.pub
      AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
      RevokedKeys /etc/ssh/revoked_user_keys
      PermitRootLogin no
      PasswordAuthentication no
      AuthenticationMethods publickey
      AllowTcpForwarding no
      X11Forwarding no
      LogLevel VERBOSE

  - path: /etc/ssh/revoked_user_keys
    permissions: "0644"
    owner: root:root
    content: ""

  - path: /usr/local/sbin/request-host-cert.sh
    permissions: "0750"
    owner: root:root
    content: |
      #!/bin/bash
      # Submit the freshly generated host public key to the CA service and
      # install the returned certificate. Idempotent: exits early if valid.
      set -euo pipefail
      PUB=/etc/ssh/ssh_host_ed25519_key.pub
      CERT=/etc/ssh/ssh_host_ed25519_key-cert.pub
      CA_URL="https://ca.internal.example.net/v1/ssh/sign-host"

      if [[ -s "$CERT" ]] && ssh-keygen -L -f "$CERT" | grep -q 'Valid: from'; then
          exit 0
      fi

      FQDN="$(hostname -f)"
      IP="$(ip -4 -o route get 1.1.1.1 | awk '{print $7; exit}')"

      curl --fail --silent --show-error \
           --cacert /etc/ssl/certs/internal-root.pem \
           --header "Content-Type: application/json" \
           --data "$(jq -nc --arg k "$(cat "$PUB")" --arg p "$FQDN,$IP" \
                     '{public_key:$k, principals:$p, ttl:"720h"}')" \
           "$CA_URL" -o "$CERT.tmp"

      install -m 0644 -o root -g root "$CERT.tmp" "$CERT"
      rm -f "$CERT.tmp"
      ssh-keygen -L -f "$CERT"

bootcmd:
  # Destroy any host keys baked into the golden image. A shared host key across
  # an autoscaling group means one stolen node impersonates the whole fleet.
  - [ sh, -c, "rm -f /etc/ssh/ssh_host_*" ]

runcmd:
  - [ ssh-keygen, -A ]
  - [ rm, -f, /etc/ssh/ssh_host_dsa_key,   /etc/ssh/ssh_host_dsa_key.pub ]
  - [ rm, -f, /etc/ssh/ssh_host_ecdsa_key, /etc/ssh/ssh_host_ecdsa_key.pub ]
  - [ /usr/local/sbin/request-host-cert.sh ]
  - [ systemctl, restart, ssh ]

ssh_deletekeys: true
ssh_genkeytypes: [ed25519, rsa]
ssh_pwauth: false
disable_root: true
```

### 3.5 Ansible — distributing trust, not keys

```yaml
---
# playbooks/ssh-trust.yml
# Distributes CA trust anchors and the revocation list. Individual user keys
# are NOT distributed: authorisation comes from short-lived certificates.
- name: Establish SSH trust anchors across the fleet
  hosts: all
  become: true
  vars:
    ssh_user_ca_pub: >-
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDq7hW2mX9pR4vT1cL8sJ0nY6bK3fZ5uQ7gE2dV9wXaM
      user-ca@example.net
    ssh_revoked_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF9kW3xR8mT2vQ6cY1pL5nJ0bH7dZ4uS3gE8wX2aVoRt former-employee@laptop"
    ssh_principals:
      sre:     [sre, oncall]
      deployer: [deployer]

  handlers:
    - name: validate and reload sshd
      ansible.builtin.shell: |
        set -euo pipefail
        /usr/sbin/sshd -t
        systemctl reload ssh
      args:
        executable: /bin/bash

  tasks:
    - name: Install the user CA trust anchor
      ansible.builtin.copy:
        content: "{{ ssh_user_ca_pub }}\n"
        dest: /etc/ssh/user_ca.pub
        owner: root
        group: root
        mode: "0644"
      notify: validate and reload sshd

    - name: Publish the revocation list
      ansible.builtin.copy:
        content: "{{ ssh_revoked_keys | join('\n') }}\n"
        dest: /etc/ssh/revoked_user_keys
        owner: root
        group: root
        mode: "0644"
      notify: validate and reload sshd

    - name: Create the principals directory
      ansible.builtin.file:
        path: /etc/ssh/auth_principals
        state: directory
        owner: root
        group: root
        mode: "0755"

    - name: Map local accounts to allowed certificate principals
      ansible.builtin.copy:
        content: "{{ item.value | join('\n') }}\n"
        dest: "/etc/ssh/auth_principals/{{ item.key }}"
        owner: root
        group: root
        mode: "0644"
      loop: "{{ ssh_principals | dict2items }}"
      loop_control:
        label: "{{ item.key }}"
      notify: validate and reload sshd

    - name: Remove weak host keys if a golden image reintroduced them
      ansible.builtin.file:
        path: "{{ item }}"
        state: absent
      loop:
        - /etc/ssh/ssh_host_dsa_key
        - /etc/ssh/ssh_host_dsa_key.pub
        - /etc/ssh/ssh_host_ecdsa_key
        - /etc/ssh/ssh_host_ecdsa_key.pub
      notify: validate and reload sshd

    - name: Collect host key fingerprints for the inventory of record
      ansible.builtin.command:
        cmd: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
      changed_when: false
      register: hostkey_fpr

    - name: Report fingerprints
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} => {{ hostkey_fpr.stdout }}"
```

### 3.6 `sops` + GnuPG — encrypted secrets that live in git

```yaml
---
# .sops.yaml — creation rules. Matched top-down against the file path.
creation_rules:
  # Production secrets: encrypted to the platform team AND to the CI key,
  # so the pipeline can decrypt without a human in the loop.
  - path_regex: ^deploy/prod/.*\.enc\.ya?ml$
    encrypted_regex: '^(data|stringData|password|token|.*_KEY)$'
    pgp: >-
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6,
      A7C3E91B22D4F6580A19B3CC5E7D2F41B8069AE2,
      D18F45A6C0B37E92FA5C1D8834B60E7791A2C5F3

  - path_regex: ^deploy/staging/.*\.enc\.ya?ml$
    encrypted_regex: '^(data|stringData)$'
    pgp: >-
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6,
      A7C3E91B22D4F6580A19B3CC5E7D2F41B8069AE2

  # Everything else in the repository must be encrypted to the platform key
  # at minimum, so an accidental `sops -e` never produces an orphan file.
  - path_regex: \.enc\.ya?ml$
    pgp: 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
```

```yaml
---
# deploy/prod/postgres-credentials.enc.yaml — the on-disk, committable form.
# Structure and keys are readable; values are per-value AES-256-GCM ciphertext
# whose data key is wrapped to each PGP recipient.
apiVersion: v1
kind: Secret
metadata:
    name: postgres-credentials
    namespace: platform
type: Opaque
stringData:
    POSTGRES_USER: ENC[AES256_GCM,data:8fJq2w==,iv:kR3v9pQ1sT7nX4mL0bY6cZ8dW2hF5uJ9gE1aV7oS3xI=,tag:pN4mQ8sT2vX6cL0bY9dZ1w==,type:str]
    POSTGRES_PASSWORD: ENC[AES256_GCM,data:Kd8xQ2mV7pR1sT9nY4bL0cZ6h,iv:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI=,tag:R2sT8vX4cL6bY1dZ0w9pQ==,type:str]
    PGSSLMODE: ENC[AES256_GCM,data:9pQ2sT==,iv:Y4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0=,tag:L0cZ6hK1pR8gJ5uH2aE7fV==,type:str]
sops:
    kms: []
    gcp_kms: []
    azure_kv: []
    hc_vault: []
    age: []
    lastmodified: "2026-08-31T09:14:22Z"
    mac: ENC[AES256_GCM,data:xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK==,iv:mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3=,tag:H2aE7fV1oS9xIT7vX2cL9==,type:str]
    pgp:
        - created_at: "2026-08-31T09:14:21Z"
          enc: |
            -----BEGIN PGP MESSAGE-----

            hF4DA9kQ7pR2sT8SAQdAxQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9xI
            T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3
            0kABmK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7f
            V1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ
            =Kq7T
            -----END PGP MESSAGE-----
          fp: 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
        - created_at: "2026-08-31T09:14:21Z"
          enc: |
            -----BEGIN PGP MESSAGE-----

            hF4DL0cZ6hK1pR8SAQdAsT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9b
            Y0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5u
            0kABH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX
            2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR
            =9dZ4
            -----END PGP MESSAGE-----
          fp: A7C3E91B22D4F6580A19B3CC5E7D2F41B8069AE2
    version: 3.9.0
```

### 3.7 `~/.gnupg/gpg.conf` and `~/.gnupg/gpg-agent.conf`

```conf
# ~/.gnupg/gpg.conf — mode 0600, directory ~/.gnupg mode 0700
# Display long key IDs and full fingerprints; short IDs are forgeable by
# collision and must never be used to identify a key.
keyid-format 0xlong
with-fingerprint
with-subkey-fingerprint

# Never trust the preferences embedded in someone else's key over ours.
personal-cipher-preferences AES256 AES192 AES
personal-digest-preferences SHA512 SHA384 SHA256
personal-compress-preferences ZLIB BZIP2 ZIP Uncompressed
default-preference-list SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed
cert-digest-algo SHA512
s2k-digest-algo SHA512
s2k-cipher-algo AES256
s2k-mode 3
s2k-count 65011712

# Operational hygiene
no-emit-version
no-comments
require-cross-certification
armor
charset utf-8
throw-keyids                    # do not leak the recipient list in the packet

# Key discovery: WKD first, keyserver as a fallback.
auto-key-locate wkd,keyserver
keyserver hkps://keys.openpgp.org
```

```conf
# ~/.gnupg/gpg-agent.conf — mode 0600
default-cache-ttl 600            # 10 min idle timeout for a cached passphrase
max-cache-ttl 7200               # 2 h absolute ceiling regardless of use
default-cache-ttl-ssh 600
max-cache-ttl-ssh 7200

pinentry-program /usr/bin/pinentry-gnome3
# Headless / TTY-only hosts:
# pinentry-program /usr/bin/pinentry-curses

# Let gpg-agent act as the ssh-agent as well. Keygrips listed in
# ~/.gnupg/sshcontrol become available to ssh(1).
enable-ssh-support

# Refuse to keep secrets after an explicit lock.
no-allow-external-cache
```

### 3.8 Systemd — a supervised reverse tunnel

```ini
# /etc/systemd/system/tunnel-metrics.service
# Exposes the node's local Prometheus exporter (127.0.0.1:9100) on the
# bastion's loopback:19100 so the scraper can reach a NAT'd network.
[Unit]
Description=Reverse SSH tunnel: node-exporter -> bastion:19100
Documentation=man:ssh(1)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=exec
User=tunnel
Group=tunnel
ExecStart=/usr/bin/ssh -NT \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts \
    -o IdentitiesOnly=yes \
    -i /etc/tunnel/id_ed25519 \
    -R 127.0.0.1:19100:127.0.0.1:9100 \
    tunnel@bastion.eu-west-1.example.net
Restart=always
RestartSec=5

# The tunnel process needs nothing but a socket.
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/etc/tunnel
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/user/ssh-agent.service
# A per-user agent with a stable socket path, so every login shell finds it.
[Unit]
Description=OpenSSH key agent
Documentation=man:ssh-agent(1)

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK
# Keys expire from the agent after 8 hours regardless of activity.
ExecStartPost=/bin/sh -c 'sleep 1; /usr/bin/ssh-add -t 8h /home/%u/.ssh/id_ed25519 </dev/null || true'
Restart=on-failure

[Install]
WantedBy=default.target
```

```sh
# /etc/profile.d/ssh-agent.sh
# Point every shell at the systemd-managed socket. XDG_RUNTIME_DIR is per-user
# and mode 0700, which is exactly the protection an agent socket needs.
if [ -z "${SSH_AUTH_SOCK:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket" ]; then
    export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
fi
```

### 3.9 CI: a GitLab pipeline that decrypts with GnuPG

```yaml
---
# .gitlab-ci.yml
stages: [verify, deploy]

variables:
  GNUPGHOME: "$CI_PROJECT_DIR/.gnupg-ci"

.gpg_bootstrap: &gpg_bootstrap
  before_script:
    # A private key in a masked CI variable, base64-armoured.
    - install -d -m 0700 "$GNUPGHOME"
    - echo "$CI_GPG_PRIVATE_KEY_B64" | base64 -d | gpg --batch --quiet --import
    - |
      cat > "$GNUPGHOME/gpg-agent.conf" <<'EOF'
      allow-loopback-pinentry
      default-cache-ttl 0
      max-cache-ttl 0
      EOF
    - gpgconf --kill gpg-agent
    - gpg --batch --list-secret-keys --keyid-format 0xlong
  after_script:
    # Kill the agent and shred the ephemeral homedir; runners are reused.
    - gpgconf --kill all || true
    - rm -rf "$GNUPGHOME"

verify:signatures:
  stage: verify
  <<: *gpg_bootstrap
  script:
    - gpg --batch --import keys/release-signing.pub.asc
    - gpg --batch --verify dist/artifact.tar.gz.asc dist/artifact.tar.gz

deploy:prod:
  stage: deploy
  environment: production
  <<: *gpg_bootstrap
  script:
    - export SOPS_GPG_EXEC=gpg
    - |
      sops --decrypt deploy/prod/postgres-credentials.enc.yaml \
        | kubectl apply --namespace platform -f -
    - kubectl rollout status deployment/api --namespace platform --timeout=180s
  rules:
    - if: $CI_COMMIT_TAG
```

---

## 4. CLI: commands and real terminal output

### 4.1 Generating keys

```
$ ssh-keygen -t ed25519 -a 100 -C "sre@laptop-2026-08" -f ~/.ssh/id_ed25519_prod
Generating public/private ed25519 key pair.
Enter passphrase for "/home/sre/.ssh/id_ed25519_prod" (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved in /home/sre/.ssh/id_ed25519_prod
Your public key has been saved in /home/sre/.ssh/id_ed25519_prod.pub
The key fingerprint is:
SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI sre@laptop-2026-08
The key's randomart image is:
+--[ED25519 256]--+
|      .o+=B*o    |
|       o.=+*.    |
|      . = *.o    |
|     . + O =     |
|      o S B .    |
|     . o + o     |
|    . o . E      |
|   . o .         |
|    o .          |
+----[SHA256]-----+
```

`-a 100` sets the number of KDF rounds protecting the private key on disk; the default is 16. Raising it makes an offline attack on a stolen key file ~6× more expensive at the cost of a few hundred milliseconds per unlock.

Hardware-backed key (FIDO2 token):

```
$ ssh-keygen -t ed25519-sk -O resident -O verify-required -O application=ssh:prod \
             -C "oncall@yubikey" -f ~/.ssh/id_ed25519_sk_prod
Generating public/private ed25519-sk key pair.
You may need to touch your authenticator to authorize key generation.
Enter PIN for authenticator:
You may need to touch your authenticator again to authorize key generation.
Enter file in which to save the key (/home/sre/.ssh/id_ed25519_sk_prod):
Enter passphrase for "/home/sre/.ssh/id_ed25519_sk_prod" (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved in /home/sre/.ssh/id_ed25519_sk_prod
Your public key has been saved in /home/sre/.ssh/id_ed25519_sk_prod.pub
The key fingerprint is:
SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI oncall@yubikey
```

Inspecting, and changing the passphrase without changing the key:

```
$ ssh-keygen -lf ~/.ssh/id_ed25519_prod.pub
256 SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI sre@laptop-2026-08 (ED25519)

$ ssh-keygen -y -f ~/.ssh/id_ed25519_prod          # derive the public key from the private one
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0f7c9pQ2m4hV1sT7nQ8xJd3bK9wRfZ1Yv6uLg0aXcP

$ ssh-keygen -p -a 200 -f ~/.ssh/id_ed25519_prod   # rotate the passphrase / raise KDF rounds
Enter old passphrase:
Key has comment 'sre@laptop-2026-08'
Enter new passphrase (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved with the new passphrase.

$ ssh-keygen -c -C "sre@laptop-rotated-2026-08-31" -f ~/.ssh/id_ed25519_prod
Enter passphrase for "/home/sre/.ssh/id_ed25519_prod":
Comment 'sre@laptop-2026-08' -> 'sre@laptop-rotated-2026-08-31'
```

Server host keys — note that `-A` only creates what is missing, which makes it idempotent:

```
$ sudo ssh-keygen -A
ssh-keygen: generating new host keys: RSA ECDSA ED25519

$ ls -l /etc/ssh/ssh_host_*
-rw------- 1 root root  505 Aug 31 09:02 /etc/ssh/ssh_host_ecdsa_key
-rw-r--r-- 1 root root  176 Aug 31 09:02 /etc/ssh/ssh_host_ecdsa_key.pub
-rw------- 1 root root  411 Aug 31 09:02 /etc/ssh/ssh_host_ed25519_key
-rw-r--r-- 1 root root   96 Aug 31 09:02 /etc/ssh/ssh_host_ed25519_key.pub
-rw------- 1 root root 2602 Aug 31 09:02 /etc/ssh/ssh_host_rsa_key
-rw-r--r-- 1 root root  568 Aug 31 09:02 /etc/ssh/ssh_host_rsa_key.pub
```

> **The role of the host key, stated precisely:** during key exchange the server signs the exchange hash with its host private key. The client verifies that signature against the host *public* key it already holds (from `known_hosts`, `ssh_known_hosts`, DNS `SSHFP`, or a CA signature). This binds the freshly negotiated session key to a specific server identity, and is the *only* thing standing between you and a man in the middle. `/etc/ssh/ssh_host_*_key` must be mode `0600` and owned by `root`.

### 4.2 `known_hosts` management

```
$ ssh-keyscan -t ed25519 node-a.prod.example.net
# node-a.prod.example.net:22 SSH-2.0-OpenSSH_9.9p1 Debian-3
node-a.prod.example.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL8xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS

$ ssh-keyscan -t ed25519 node-a.prod.example.net 2>/dev/null | ssh-keygen -lf -
256 SHA256:9pQ2sT7vX4cL6bY1dZ0wJ8mK3nR5hF2uG7eV9aS1oXI node-a.prod.example.net (ED25519)
```

`ssh-keyscan` is **not** a verification step. It transports whatever the network gives you. Compare its fingerprint against a channel the attacker does not control — the cloud console's serial output, the Ansible fact gathered over an already-trusted path, or the CA-signed certificate.

```
$ ssh-keygen -F node-a.prod.example.net                 # is it already known?
# Host node-a.prod.example.net found: line 42
|1|8sJ2qL0cZ6hK1pR8gJ5uH2aE7fV=|9dZ4wQ8sN3mK1pR6gJ5uH2aE7fV= ssh-ed25519 AAAAC3Nza...

$ ssh-keygen -R node-a.prod.example.net                 # remove it (works on hashed files)
# Host node-a.prod.example.net found: line 42
/home/sre/.ssh/known_hosts updated.
Original contents retained as /home/sre/.ssh/known_hosts.old

$ ssh-keygen -H -f ~/.ssh/known_hosts                   # hash an existing plaintext file
/home/sre/.ssh/known_hosts updated.
Original contents retained as /home/sre/.ssh/known_hosts.old
WARNING: /home/sre/.ssh/known_hosts.old contains unhashed entries
Delete this file to ensure privacy of hostnames
```

Hashing matters: an unhashed `known_hosts` on a compromised laptop is a ready-made lateral-movement map.

### 4.3 The agent

```
$ eval "$(ssh-agent -s)"
Agent pid 48213

$ echo "$SSH_AUTH_SOCK"
/tmp/ssh-XXXXXm9K2pQ/agent.48212

$ ssh-add -t 4h ~/.ssh/id_ed25519_prod
Enter passphrase for /home/sre/.ssh/id_ed25519_prod:
Identity added: /home/sre/.ssh/id_ed25519_prod (sre@laptop-2026-08)
Lifetime set to 14400 seconds

$ ssh-add -l
256 SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI sre@laptop-2026-08 (ED25519)
256 SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI oncall@yubikey (ED25519-SK)

$ ssh-add -L | head -1
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0f7c9pQ2m4hV1sT7nQ8xJd3bK9wRfZ1Yv6uLg0aXcP /home/sre/.ssh/id_ed25519_prod

$ ssh-add -x                                # lock the agent without dropping keys
Enter lock password:
Again:
Agent locked.

$ ssh-add -l
The agent has no identities.               # keys are still there, just unusable

$ ssh-add -X
Enter lock password:
Agent unlocked.

$ ssh-add -d ~/.ssh/id_ed25519_prod         # drop one key
Identity removed: /home/sre/.ssh/id_ed25519_prod ED25519 (sre@laptop-2026-08)

$ ssh-add -D                                # drop all
All identities removed.
```

Confirm-on-use — the mitigation that makes agent forwarding survivable when you truly cannot avoid it:

```
$ ssh-add -c -t 1h ~/.ssh/id_ed25519_prod
Enter passphrase for /home/sre/.ssh/id_ed25519_prod:
Identity added: /home/sre/.ssh/id_ed25519_prod (sre@laptop-2026-08)
Lifetime set to 3600 seconds
The user must confirm each use of the key
```

### 4.4 Authenticating and reading the handshake

```
$ ssh-copy-id -i ~/.ssh/id_ed25519_prod.pub sre@node-a.prod.example.net
/usr/bin/ssh-copy-id: INFO: Source of key(s) to be installed: "/home/sre/.ssh/id_ed25519_prod.pub"
/usr/bin/ssh-copy-id: INFO: attempting to log in with the new key(s), to filter out any that are already installed
/usr/bin/ssh-copy-id: INFO: 1 key(s) remain to be installed -- if you are prompted now it is to install the new keys
sre@node-a.prod.example.net's password:

Number of key(s) added: 1

Now try logging into the machine, with:   "ssh 'sre@node-a.prod.example.net'"
and check to make sure that only the key(s) you wanted were added.
```

```
$ ssh -v sre@node-a.prod.example.net true
OpenSSH_9.9p1 Debian-3, OpenSSL 3.4.0 22 Oct 2024
debug1: Reading configuration data /home/sre/.ssh/config
debug1: /home/sre/.ssh/config line 22: Applying options for *.prod.example.net
debug1: Reading configuration data /etc/ssh/ssh_config
debug1: Setting implicit ProxyCommand from ProxyJump: ssh -v -W '[%h]:%p' bastion-eu
debug1: Executing proxy command: exec ssh -v -W '[node-a.prod.example.net]:22' bastion-eu
debug1: Connecting to node-a.prod.example.net port 22.
debug1: Connection established.
debug1: identity file /home/sre/.ssh/id_ed25519_sk_prod type 3
debug1: Local version string SSH-2.0-OpenSSH_9.9p1 Debian-3
debug1: Remote protocol version 2.0, remote software version OpenSSH_9.9p1 Debian-3
debug1: SSH2_MSG_KEXINIT sent
debug1: SSH2_MSG_KEXINIT received
debug1: kex: algorithm: mlkem768x25519-sha256
debug1: kex: host key algorithm: ssh-ed25519-cert-v01@openssh.com
debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: Server host certificate: ssh-ed25519-cert-v01@openssh.com SHA256:9pQ2sT7vX4cL6bY1dZ0wJ8mK3nR5hF2uG7eV9aS1oXI, serial 4471 ID "node-a.prod" CA ssh-ed25519 SHA256:L0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4w valid from 2026-08-01T00:00:00 to 2026-09-30T00:00:00
debug1: Host 'node-a.prod.example.net' is known and matches the ED25519-CERT host certificate.
debug1: Found CA key in /etc/ssh/ssh_known_hosts:1
debug1: Will attempt key: /home/sre/.ssh/id_ed25519_sk_prod ED25519-SK SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI agent
debug1: Authentications that can continue: publickey
debug1: Offering public key: /home/sre/.ssh/id_ed25519_sk_prod ED25519-SK SHA256:T7vX... agent
debug1: Server accepts key: /home/sre/.ssh/id_ed25519_sk_prod ED25519-SK SHA256:T7vX... agent
Confirm user presence for key ED25519-SK SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI
User presence confirmed
Authenticated to node-a.prod.example.net (via proxy) using "publickey".
debug1: Entering interactive session.
debug1: Exit status 0
```

Dump the effective client configuration — this settles every "but I set it in `/etc/ssh/ssh_config`" argument:

```
$ ssh -G node-a.prod.example.net | grep -E '^(user|port|identityfile|proxyjump|forwardagent|stricthostkeychecking|ciphers)'
user sre
port 22
identityfile ~/.ssh/id_ed25519_sk_prod
proxyjump bastion-eu
forwardagent no
stricthostkeychecking yes
ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
```

### 4.5 Tunnels

**Local forward** — reach a Postgres primary that only listens on its own loopback:

```
$ ssh -f -N -L 127.0.0.1:15432:127.0.0.1:5432 -o ExitOnForwardFailure=yes sre@db-primary.prod.example.net

$ ss -tlnp 'sport = :15432'
State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN  0       128         127.0.0.1:15432        0.0.0.0:*      users:(("ssh",pid=51204,fd=5))

$ psql "host=127.0.0.1 port=15432 dbname=orders user=readonly sslmode=disable" -c 'select now(), inet_server_addr();'
              now              | inet_server_addr
-------------------------------+------------------
 2026-08-31 09:31:47.114882+00 | 10.42.3.17
(1 row)
```

`sslmode=disable` is correct *here*: the SSH channel already provides confidentiality and integrity, and the TCP endpoint is the server's own loopback. Do not generalise it.

**Remote forward** — publish a local service on the bastion:

```
$ ssh -N -R 127.0.0.1:19100:127.0.0.1:9100 tunnel@bastion.eu-west-1.example.net &
[1] 51890

# On the bastion:
$ ss -tlnp 'sport = :19100'
State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN  0       128         127.0.0.1:19100        0.0.0.0:*      users:(("sshd",pid=2211,fd=9))

$ curl -s http://127.0.0.1:19100/metrics | head -3
# HELP go_gc_duration_seconds A summary of the wall-time pause (GC) duration.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 4.1206e-05
```

Ask the server to pick the port (`-R 0:...`) when many nodes share one bastion:

```
$ ssh -N -R 0:127.0.0.1:9100 tunnel@bastion.eu-west-1.example.net -v 2>&1 | grep 'Allocated port'
debug1: Remote connections from LOCALHOST:39241 forwarded to local address 127.0.0.1:9100
Allocated port 39241 for remote forward to 127.0.0.1:9100
```

**Dynamic forward** (SOCKS5):

```
$ ssh -f -N -D 127.0.0.1:1080 sre@bastion.eu-west-1.example.net

$ curl -s --socks5-hostname 127.0.0.1:1080 http://argocd.internal.example.net/api/version | jq -r .Version
v2.13.1+af54ef8
```

`--socks5-hostname` (rather than `--socks5`) resolves DNS **at the bastion**. Without it, your local resolver leaks the internal hostname and, more practically, fails to resolve it at all.

**Managing forwards on a live connection** via the control socket — no reconnect, no dropped session:

```
$ ssh -O check bastion-eu
Master running (pid=51204)

$ ssh -O forward -L 127.0.0.1:16443:10.42.0.5:6443 bastion-eu
$ ss -tlnp 'sport = :16443'
State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN  0       128         127.0.0.1:16443        0.0.0.0:*      users:(("ssh",pid=51204,fd=7))

$ ssh -O cancel -L 127.0.0.1:16443:10.42.0.5:6443 bastion-eu
$ ssh -O exit bastion-eu
Exit request sent.
```

The same is reachable interactively with the escape sequence `~C` (newline first, then `~C`):

```
ssh> -L 127.0.0.1:18080:10.42.0.9:80
Forwarding port.
ssh> ?
Commands:
      -L[bind_address:]port:host:hostport    Request local forward
      -R[bind_address:]port:host:hostport    Request remote forward
      -D[bind_address:]port                  Request dynamic forward
      -KL[bind_address:]port                 Cancel local forward
```

**X11 forwarding:**

```
$ ssh -X sre@workstation.lab.example.net
sre@workstation:~$ echo $DISPLAY
localhost:10.0

sre@workstation:~$ xauth list
workstation.lab.example.net/unix:10  MIT-MAGIC-COOKIE-1  9f2c7b41d80e5a63c17f4b2e6a05d391

sre@workstation:~$ ss -tlnp | grep 601
LISTEN 0  128  127.0.0.1:6010  0.0.0.0:*  users:(("sshd",pid=8842,fd=10))

sre@workstation:~$ xdpyinfo | head -3
name of display:    localhost:10.0
version number:     11.0
vendor string:      The X.Org Foundation

sre@workstation:~$ xclock &
```

Display `localhost:10.0` maps to TCP port `6000 + 10 = 6010`, bound to loopback because `X11UseLocalhost yes` is the default. The `MIT-MAGIC-COOKIE-1` in `~/.Xauthority` is the shared secret that authorises the remote client to the local X server; SSH generates a *proxy* cookie for untrusted (`-X`) forwarding and substitutes it transparently.

`-X` applies the X11 SECURITY extension and a 20-minute timeout on the untrusted cookie; `-Y` skips both. Under `-Y`, the remote application can read your clipboard, take screenshots and inject keystrokes into every window on your local X server. On Wayland, X11 forwarding reaches only `Xwayland` clients.

### 4.6 GnuPG end to end

**Create a key with an offline-capable topology:**

```
$ gpg --quick-generate-key "SRE Platform <sre@example.com>" future-default cert 2y
About to create a key for:
    "SRE Platform <sre@example.com>"

Continue? (Y/n) y
We need to generate a lot of random bytes. ...
gpg: /home/sre/.gnupg/trustdb.gpg: trustdb created
gpg: directory '/home/sre/.gnupg/openpgp-revocs.d' created
gpg: revocation certificate stored as '/home/sre/.gnupg/openpgp-revocs.d/4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6.rev'
public and secret key created and signed.

pub   ed25519 2026-08-31 [C] [expires: 2028-08-30]
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
uid                      SRE Platform <sre@example.com>
```

```
$ gpg --quick-add-key 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 ed25519 sign 1y
$ gpg --quick-add-key 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 cv25519 encr 1y
$ gpg --quick-add-key 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 ed25519 auth 1y

$ gpg --list-secret-keys --keyid-format 0xlong --with-keygrip
/home/sre/.gnupg/pubring.kbx
----------------------------
sec   ed25519/0x9E4A2C7F0B15D3A6 2026-08-31 [C] [expires: 2028-08-30]
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
      Keygrip = 7B4C29E01FA6D3958C2B7E14D06A5F8931CE2740
uid                   [ultimate] SRE Platform <sre@example.com>
ssb   ed25519/0x3C7D91AB55E20F48 2026-08-31 [S] [expires: 2027-08-31]
      Keygrip = A15F7C930D6B24E8871F0A3C95D26E4470BA8135
ssb   cv25519/0xB2E80D14C93A6F57 2026-08-31 [E] [expires: 2027-08-31]
      Keygrip = C40E29B7158A6D3F92C1704E8BD53A6621F09C84
ssb   ed25519/0x6A1F03D8E27B54C9 2026-08-31 [A] [expires: 2027-08-31]
      Keygrip = E93D175CB0248FA61D7E9350C82B4F017AD6E259
```

`[C]` certify, `[S]` sign, `[E]` encrypt, `[A]` authenticate. The keygrip is the filename under `~/.gnupg/private-keys-v1.d/` and the token `gpg-agent` uses in `sshcontrol`.

**Move the primary key offline** — the operation that makes the whole topology worthwhile:

```
$ gpg --export-secret-subkeys --armor 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 > /mnt/airgap/subkeys.asc
$ gpg --export-secret-keys --armor 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 > /mnt/airgap/primary-FULL.asc
$ gpg --delete-secret-keys 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
$ gpg --import /mnt/airgap/subkeys.asc

$ gpg --list-secret-keys --keyid-format 0xlong
sec#  ed25519/0x9E4A2C7F0B15D3A6 2026-08-31 [C] [expires: 2028-08-30]
```

The `#` after `sec` is the whole point: the primary secret is **not on this machine**. The laptop can sign, encrypt and authenticate; it cannot certify other keys, add UIDs, or extend expiry — and a thief cannot take over your identity.

**Everyday operations:**

```
$ gpg --armor --export sre@example.com > sre-public.asc
$ gpg --import colleague-public.asc
gpg: key 0xA7C3E91B22D4F658: public key "Platform CI <ci@example.com>" imported
gpg: Total number processed: 1
gpg:               imported: 1

$ gpg --edit-key ci@example.com
gpg> fpr
pub   ed25519/0xA7C3E91B22D4F658 2026-06-14 SRE Platform CI
 Primary key fingerprint: A7C3 E91B 22D4 F658 0A19  B3CC 5E7D 2F41 B806 9AE2
gpg> trust
  1 = I don't know or won't say
  2 = I do NOT trust
  3 = I trust marginally
  4 = I trust fully
  5 = I trust ultimately
Your decision? 4
gpg> sign
gpg> save
```

Verify that fingerprint by voice, in person, or against a signed inventory — never by reading it out of the same email that carried the key.

```
$ echo "s3cr3t-db-password" | gpg --encrypt --armor \
    --recipient sre@example.com --recipient ci@example.com --output db.pw.asc

$ gpg --list-packets db.pw.asc | grep -E 'pubkey enc|keyid'
:pubkey enc packet: version 3, algo 18, keyid B2E80D14C93A6F57
:pubkey enc packet: version 3, algo 18, keyid 0000000000000000     # throw-keyids in effect

$ gpg --decrypt db.pw.asc
gpg: encrypted with cv25519 key, ID 0xB2E80D14C93A6F57, created 2026-08-31
      "SRE Platform <sre@example.com>"
s3cr3t-db-password

$ gpg --symmetric --cipher-algo AES256 --armor --output backup.tar.gz.asc backup.tar.gz

$ gpg --detach-sign --armor --output dist/artifact.tar.gz.asc dist/artifact.tar.gz
$ gpg --verify dist/artifact.tar.gz.asc dist/artifact.tar.gz
gpg: Signature made Mon 31 Aug 2026 09:47:12 AM UTC
gpg:                using EDDSA key 3C7D91AB55E20F48A0F2C815D74B93E60A5C21DF
gpg:                issuer "sre@example.com"
gpg: Good signature from "SRE Platform <sre@example.com>" [ultimate]
```

`gpg --verify` exits `0` on a good signature and `1` otherwise — but **a good signature from an untrusted key still exits 0** with a `WARNING: This key is not certified with a trusted signature!`. In automation, verify against a dedicated keyring holding only keys you accept:

```
$ gpg --no-default-keyring --keyring /etc/apt/trusted-release.gpg \
      --status-fd 1 --verify dist/artifact.tar.gz.asc dist/artifact.tar.gz \
  | grep -E '^\[GNUPG:\] (GOODSIG|VALIDSIG|TRUST_)'
[GNUPG:] GOODSIG 3C7D91AB55E20F48 SRE Platform <sre@example.com>
[GNUPG:] VALIDSIG 3C7D91AB55E20F48A0F2C815D74B93E60A5C21DF 2026-08-31 1788507232 0 4 0 22 10 00 3C7D91AB55E20F48A0F2C815D74B93E60A5C21DF
[GNUPG:] TRUST_ULTIMATE 0 pgp
```

Machine-readable `--status-fd` output is the only correct parsing surface; human output is not a stable API.

**Revocation:**

```
$ gpg --output revoke-sre.asc --gen-revoke sre@example.com
sec  ed25519/0x9E4A2C7F0B15D3A6 2026-08-31 SRE Platform <sre@example.com>

Create a revocation certificate for this key? (y/N) y
Please select the reason for the revocation:
  0 = No reason specified
  1 = Key has been compromised
  2 = Key is no longer used
  3 = User ID is no longer valid
  Q = Cancel
Your decision? 1
Enter an optional description; end it with an empty line:
> Laptop stolen 2026-08-31, key material assumed exfiltrated
>
Reason for revocation: Key has been compromised
Laptop stolen 2026-08-31, key material assumed exfiltrated
Is this okay? (y/N) y
ASCII armored output forced.
Revocation certificate created.

$ gpg --import revoke-sre.asc
gpg: key 0x9E4A2C7F0B15D3A6: "SRE Platform <sre@example.com>" revocation certificate imported

$ gpg --keyserver hkps://keys.openpgp.org --send-keys 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
gpg: sending key 0x9E4A2C7F0B15D3A6 to hkps://keys.openpgp.org

$ gpg --list-keys sre@example.com
pub   ed25519/0x9E4A2C7F0B15D3A6 2026-08-31 [C] [revoked: 2026-08-31]
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
uid           [ revoked] SRE Platform <sre@example.com>
```

Revoking a single compromised subkey instead of the whole identity:

```
$ gpg --edit-key sre@example.com
gpg> key 2
gpg> revkey
Do you really want to revoke this subkey? (y/N) y
Please select the reason for the revocation:
  1 = Key has been compromised
Your decision? 1
gpg> save
```

Revocation is **publication**, not deletion. Anyone who never refreshes from a keyserver, and every ciphertext already produced, is unaffected. Treat revocation as a signal to peers and **rotate the underlying secrets** — that is the part that actually contains the incident.

**`gpg-agent` as `ssh-agent`:**

```
$ gpgconf --list-dirs agent-ssh-socket
/run/user/1000/gnupg/S.gpg-agent.ssh

$ echo E93D175CB0248FA61D7E9350C82B4F017AD6E259 >> ~/.gnupg/sshcontrol
$ gpgconf --kill gpg-agent
$ export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

$ ssh-add -l
256 SHA256:mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3 (ED25519)
```

The `[A]` (authenticate) subkey now serves as an SSH identity, which is the mechanism behind OpenPGP smartcard SSH login.

**Signing git commits — with both back ends:**

```
$ git config --global user.signingkey 0x3C7D91AB55E20F48
$ git config --global commit.gpgsign true
$ git config --global tag.gpgsign true
$ git commit -S -m "feat: rotate database credentials"
[main 7a3f912] feat: rotate database credentials

$ git log --show-signature -1
commit 7a3f912c8e04b5d1739f2a6c58e1d047b3925fa8
gpg: Signature made Mon 31 Aug 2026 09:52:01 AM UTC
gpg:                using EDDSA key 3C7D91AB55E20F48A0F2C815D74B93E60A5C21DF
gpg: Good signature from "SRE Platform <sre@example.com>" [ultimate]
```

```
$ git config --global gpg.format ssh
$ git config --global user.signingkey ~/.ssh/id_ed25519_prod.pub
$ git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
$ printf 'sre@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0f7c9pQ2m4hV1sT7nQ8xJd3bK9wRfZ1Yv6uLg0aXcP\n' \
    > ~/.config/git/allowed_signers

$ git log --show-signature -1
Good "git" signature for sre@example.com with ED25519 key SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI
```

Standalone `ssh-keygen` signatures over arbitrary files, useful when you already run an SSH CA and do not want a second PKI:

```
$ ssh-keygen -Y sign -f ~/.ssh/id_ed25519_prod -n file dist/artifact.tar.gz
Signing file dist/artifact.tar.gz
Write signature to dist/artifact.tar.gz.sig

$ ssh-keygen -Y verify -f ~/.config/git/allowed_signers -I sre@example.com \
             -n file -s dist/artifact.tar.gz.sig < dist/artifact.tar.gz
Good "file" signature for sre@example.com with ED25519 key SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI
```

---

## 5. Verification and failure diagnosis

### 5.1 The verification ladder

| Rung | What it proves | Command | Cost |
|---|---|---|---|
| 1. Syntax | The config parses | `sshd -t`; `ssh -G host` | free |
| 2. Effective config | What is actually applied, after `Match`/`Host` merge | `sshd -T -C user=sre,host=10.42.0.5,addr=10.42.0.5`; `ssh -G host` | free |
| 3. Key inventory | Which keys exist, their type and fingerprint | `ssh-keygen -lf`; `gpg -K --with-keygrip` | free |
| 4. Trust anchors | The client trusts the right host identity | `ssh-keygen -F host`; `ssh-keygen -L -f *-cert.pub` | free |
| 5. Negotiated crypto | What the peers actually agreed on, not what you configured | `ssh -v … \| grep 'kex:'` | one connection |
| 6. Authorisation | This key really can reach this account | `ssh -o BatchMode=yes -o PreferredAuthentications=publickey user@host true` | one connection |
| 7. Data path | The tunnel carries real traffic to the intended endpoint | `ss -tlnp`; an application-level probe (`psql`, `curl`) | one request |
| 8. Content correctness | The decrypted plaintext is the secret you meant | Application health, not a crypto tool | — |

Rung 8 is where the honest gap sits: every check above passes for a perfectly encrypted, perfectly delivered, **wrong** credential.

### 5.2 Non-interactive health check

```bash
#!/usr/bin/env bash
# /usr/local/sbin/check-ssh-trust.sh — exits non-zero on the first violation.
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'OK:   %s\n' "$1"; }

# 1. sshd config is syntactically valid
/usr/sbin/sshd -t || fail "sshd_config does not parse"
ok "sshd_config parses"

# 2. Password authentication and root login are off in the effective config
eff=$(/usr/sbin/sshd -T 2>/dev/null)
grep -qx 'passwordauthentication no' <<<"$eff" || fail "PasswordAuthentication is enabled"
grep -qx 'permitrootlogin no'       <<<"$eff" || fail "PermitRootLogin is not 'no'"
ok "password auth and root login disabled"

# 3. No weak host keys present
for weak in dsa ecdsa; do
    [[ -e "/etc/ssh/ssh_host_${weak}_key" ]] && fail "weak host key present: ${weak}"
done
ok "no DSA/ECDSA host keys"

# 4. Host key permissions
while IFS= read -r -d '' k; do
    perm=$(stat -c '%a %U' "$k")
    [[ "$perm" == "600 root" ]] || fail "$k has wrong perms/owner: $perm"
done < <(find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key' -print0)
ok "host key permissions are 0600 root:root"

# 5. Host certificate, if configured, is still valid
cert=/etc/ssh/ssh_host_ed25519_key-cert.pub
if [[ -s "$cert" ]]; then
    until=$(ssh-keygen -L -f "$cert" | awk '/Valid:/ {print $NF}')
    left=$(( $(date -d "$until" +%s) - $(date +%s) ))
    (( left > 604800 )) || fail "host certificate expires in $((left/86400))d (< 7d)"
    ok "host certificate valid for $((left/86400)) more days"
fi

# 6. Every authorized_keys file is user-owned and not group/world writable
while IFS=: read -r user _ uid _ _ home _; do
    (( uid >= 1000 )) || continue
    ak="$home/.ssh/authorized_keys"
    [[ -f "$ak" ]] || continue
    perm=$(stat -c '%a %U' "$ak")
    [[ "${perm%% *}" =~ ^6[04]0$ ]] || fail "$ak has permissive mode: $perm"
    [[ "${perm##* }" == "$user" ]]  || fail "$ak not owned by $user"
done < /etc/passwd
ok "authorized_keys ownership and modes are sane"
```

### 5.3 Failure catalogue

| Symptom | Root cause | Fix |
|---|---|---|
| `Permissions 0644 for '/home/sre/.ssh/id_ed25519' are too open.` | Private key readable by others; `ssh` refuses to use it | `chmod 600 ~/.ssh/id_ed25519; chmod 700 ~/.ssh` |
| `Load key "...": error in libcrypto` | File is not a key, or is a PuTTY `.ppk`, or truncated | `ssh-keygen -y -f <key>`; convert with `puttygen key.ppk -O private-openssh -o id_rsa` |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` | Legitimate rebuild, OR an active MITM | **Verify out-of-band first.** Then `ssh-keygen -R host`. Never blind-delete `known_hosts`. |
| `Host key verification failed.` | Unknown host with `StrictHostKeyChecking yes`, or unreadable `UserKnownHostsFile` | Seed the entry from a trusted inventory; check the file path with `ssh -G host \| grep knownhosts` |
| `no matching host key type found. Their offer: ssh-rsa` | Server only offers SHA-1 RSA, disabled since OpenSSH 8.8 | Per-host: `HostkeyAlgorithms +ssh-rsa`, `PubkeyAcceptedAlgorithms +ssh-rsa`. Fix the server. |
| `Unable to negotiate with 10.0.0.5 port 22: no matching key exchange method found.` | Ancient peer (network appliance) | Per-host `KexAlgorithms +diffie-hellman-group14-sha1` — scoped, temporary, tracked |
| `Permission denied (publickey).` with the right key loaded | `authorized_keys` mode/ownership, home directory group-writable, SELinux label | `sudo journalctl -u ssh -n50`; look for `Authentication refused: bad ownership or modes`; `restorecon -Rv ~/.ssh` |
| `sign_and_send_pubkey: signing failed for ED25519 ...: agent refused operation` | Agent locked, key expired via `-t`, or `-c` confirmation dialog had no display | `ssh-add -l`; `ssh-add -X`; set `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` |
| `Could not open a connection to your authentication agent.` | `SSH_AUTH_SOCK` unset or pointing at a dead socket (classic after `sudo`, `screen`, `tmux` reattach) | `echo $SSH_AUTH_SOCK; ss -xl \| grep agent`; use a stable socket path (§3.8) |
| `Too many authentication failures` | Agent offered every loaded key; server hit `MaxAuthTries` | `IdentitiesOnly yes` + explicit `IdentityFile` |
| `channel 2: open failed: administratively prohibited: open failed` | Server has `AllowTcpForwarding no` or the target is outside `PermitOpen` | Check `sshd -T \| grep -E 'allowtcpforwarding\|permitopen'` |
| `bind [127.0.0.1]:8080: Address already in use` + `Could not request local forwarding.` | A previous forward (often a `ControlMaster` still alive) holds the port | `ssh -O check host`; `ssh -O exit host`; `ss -tlnp 'sport = :8080'` |
| Remote forward silently binds loopback only | `GatewayPorts no` (default) | Set `GatewayPorts clientspecified` on the **server**; prefer keeping loopback and adding a proxy |
| Tunnel "works" but you reach the wrong service | `ExitOnForwardFailure` unset: the forward failed, a local service answered instead | Always `ExitOnForwardFailure yes`; verify the peer with an app-level probe |
| Tunnel dies after minutes of idleness | NAT/firewall idle timeout drops the flow | `ServerAliveInterval 30`, `ServerAliveCountMax 3`; supervise with systemd (§3.8) |
| Bulk transfer through a tunnel collapses under packet loss | TCP-over-TCP: two independent retransmit timers fight | Use WireGuard/UDP, or `ssh -o Compression=no` + a single stream; do not tune your way out |
| `X11 forwarding request failed on channel 0` | `X11Forwarding no`, or `xauth` not installed on the server | `sshd -T \| grep x11`; `apt install xauth` |
| `Warning: untrusted X11 forwarding setup failed: xauth key data not generated` | Missing/broken `xauth`, or `~/.Xauthority` unwritable (full disk, read-only home) | `which xauth`; `ls -l ~/.Xauthority`; free space |
| `Error: Can't open display: localhost:10.0` | `$DISPLAY` inherited into a `sudo`/`su` shell that lost `~/.Xauthority` | `xauth list` as the original user, `xauth add` as the target user, or `sudo -E` |
| `gpg: decryption failed: No secret key` | Ciphertext encrypted to a key you do not hold, or wrong `GNUPGHOME` | `gpg --list-packets file.asc \| grep keyid`; `gpg -K` |
| `gpg: signing failed: Inappropriate ioctl for device` | Pinentry has no TTY (cron, CI, container) | `export GPG_TTY=$(tty)`; or `--pinentry-mode loopback --passphrase-fd 0` with `allow-loopback-pinentry` |
| `gpg: WARNING: unsafe permissions on homedir '/home/sre/.gnupg'` | Directory not `0700` | `chmod 700 ~/.gnupg; chmod 600 ~/.gnupg/*` |
| `gpg: keyserver receive failed: No dirmngr` / `Server indicated a failure` | `dirmngr` not running or blocked by egress policy | `gpgconf --launch dirmngr`; `dirmngr --debug-level guru --server`; check hkps egress on 443 |
| `gpg: There is no assurance this key belongs to the named user` | Key imported but never certified | `gpg --edit-key <id>` → verify fingerprint out-of-band → `trust` / `sign` |
| GnuPG hangs forever in CI | Agent waiting on a pinentry nobody will answer | `--batch --no-tty --pinentry-mode loopback`; `gpgconf --kill gpg-agent` between jobs |
| `gpg: Note: signature key ... expired` | Subkey expiry passed | On the offline machine: `gpg --quick-set-expire <fpr> 1y <subkey-fpr>`, re-export, redistribute |

### 5.4 Diagnostic escalation ladder

```
$ ssh -v  host        # config resolution, KEX, which keys were offered
$ ssh -vv host        # per-channel state, packet-level decisions
$ ssh -vvv host       # raw protocol; only when you suspect an implementation bug
```

Server side, without disturbing the running daemon — run a second `sshd` on an alternate port in the foreground, one connection at a time:

```
$ sudo /usr/sbin/sshd -d -p 2222
debug1: sshd version OpenSSH_9.9, OpenSSL 3.4.0 22 Oct 2024
debug1: private host key #0: ssh-ed25519 SHA256:9pQ2sT7vX4cL6bY1dZ0wJ8mK3nR5hF2uG7eV9aS1oXI
debug1: rexec_argv[2]='-p'
Server listening on 0.0.0.0 port 2222.
...
debug1: userauth-request for user sre service ssh-connection method publickey
debug1: trying public key file /home/sre/.ssh/authorized_keys
Authentication refused: bad ownership or modes for directory /home/sre
debug1: restore_uid: 0/0
Failed publickey for sre from 10.42.0.9 port 51422 ssh2: ED25519 SHA256:qN4mV7pR...
```

That one line — `bad ownership or modes for directory /home/sre` — is the answer to a majority of "my key stopped working" tickets, and it never appears on the client. Cause: the home directory is group- or world-writable (commonly `775` after a careless `chmod -R`), so someone other than the owner could replace `~/.ssh`. `chmod 750 /home/sre` fixes it.

Correlate at the audit layer:

```
$ sudo journalctl -u ssh --since "1 hour ago" -o cat | grep -E 'Accepted|Failed|Disconnect'
Accepted publickey for sre from 10.42.0.9 port 51402 ssh2: ED25519-SK SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI, serial 4471 CA ED25519 SHA256:L0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4w
Failed publickey for deployer from 10.42.7.2 port 40118 ssh2: RSA SHA256:xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9x
Disconnected from authenticating user deployer 10.42.7.2 port 40118 [preauth]
```

With `LogLevel VERBOSE`, every accepted login records the **key fingerprint** (and, with certificates, the serial and issuing CA). That fingerprint is what turns "someone logged in as `sre`" into "*this* credential on *that* laptop logged in", which is the difference between an audit trail and a log file.

Verify a certificate before blaming the network:

```
$ ssh-keygen -L -f /etc/ssh/ssh_host_ed25519_key-cert.pub
/etc/ssh/ssh_host_ed25519_key-cert.pub:
        Type: ssh-ed25519-cert-v01@openssh.com host certificate
        Public key: ED25519-CERT SHA256:9pQ2sT7vX4cL6bY1dZ0wJ8mK3nR5hF2uG7eV9aS1oXI
        Signing CA: ED25519 SHA256:L0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4w (using ssh-ed25519)
        Key ID: "node-a.prod"
        Serial: 4471
        Valid: from 2026-08-01T00:00:00 to 2026-09-30T00:00:00
        Principals:
                node-a.prod.example.net
                10.42.3.17
        Critical Options: (none)
        Extensions: (none)
```

An expired certificate produces a client-side `Host key verification failed.` that looks exactly like a MITM. Alert on `Valid: to` minus now, not on connection failures — the alert should fire days before the outage.

Watch a tunnel's actual data path rather than trusting that it exists:

```
$ ss -tnp state established '( sport = :22 or dport = :22 )'
Recv-Q Send-Q     Local Address:Port      Peer Address:Port  Process
     0      0        10.42.0.9:51402     10.42.3.17:22       users:(("ssh",pid=51204,fd=3))

$ sudo lsof -nP -iTCP:15432 -sTCP:LISTEN
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
ssh     51204  sre    5u  IPv4 918233      0t0  TCP 127.0.0.1:15432 (LISTEN)

$ sudo ss -K dst 10.42.3.17 dport = 22     # forcibly kill a wedged session's socket
```

GnuPG state inspection:

```
$ gpgconf --list-components
gpg:OpenPGP:/usr/bin/gpg
gpgsm:S/MIME:/usr/bin/gpgsm
keyboxd:Public Keys:/usr/libexec/keyboxd
gpg-agent:Private Keys:/usr/bin/gpg-agent
scdaemon:Smartcards:/usr/libexec/scdaemon
dirmngr:Network:/usr/bin/dirmngr

$ gpg-connect-agent 'keyinfo --list' /bye
S KEYINFO A15F7C930D6B24E8871F0A3C95D26E4470BA8135 D - - - P - - -
S KEYINFO C40E29B7158A6D3F92C1704E8BD53A6621F09C84 D - - - P - - -
OK

$ gpg-connect-agent 'RELOADAGENT' /bye     # pick up gpg-agent.conf without a restart
OK

$ gpgconf --kill gpg-agent                 # hard reset: drops all cached passphrases
$ gpg --check-trustdb
gpg: marginals needed: 3  completes needed: 1  trust model: pgp
gpg: depth: 0  valid:   1  signed:   2  trust: 0-, 0q, 0n, 0m, 0f, 1u
gpg: depth: 1  valid:   2  signed:   0  trust: 2-, 0q, 0n, 0m, 0f, 0u
gpg: next trustdb check due at 2027-08-31
```

### 5.5 Incident runbook — "an engineer's laptop was stolen"

```
# 1. Revoke SSH authority. With a user CA this is one file, fleet-wide.
$ ssh-keygen -lf ~/inventory/keys/former.pub
256 SHA256:xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9x former@laptop (ED25519)
$ ansible-playbook playbooks/ssh-trust.yml -e '@revoke-former.yml'

# 2. Confirm enforcement on a sample node, from the node itself.
$ ssh node-a.prod.example.net 'sudo sshd -T | grep -E "revokedkeys|trusteduserca"'
revokedkeys /etc/ssh/revoked_user_keys
trusteduserca /etc/ssh/user_ca.pub

# 3. Terminate live sessions belonging to that principal. Revocation does NOT
#    close an already-authenticated connection.
$ ansible all -b -m shell -a "pkill -u former -t 'pts/*' || true"

# 4. Revoke the OpenPGP subkeys from the offline primary, publish, redistribute.
$ gpg --edit-key former@example.com          # key N -> revkey -> save
$ gpg --keyserver hkps://keys.openpgp.org --send-keys <FPR>

# 5. Re-encrypt every secret that key could read, then ROTATE the plaintext.
#    Re-encryption alone is theatre: the attacker may already hold the old blob.
$ sops updatekeys deploy/prod/postgres-credentials.enc.yaml
$ ./scripts/rotate-db-credentials.sh --namespace platform

# 6. Audit what that fingerprint touched.
$ ansible all -b -m shell \
    -a "journalctl -u ssh --since '30 days ago' -o cat | grep 'SHA256:xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9x' || true"
```

Steps 3 and 5 are the ones that get skipped, and they are the ones that matter. Revocation changes future authorisation decisions; it does nothing about a session already open or a ciphertext already copied.

---

## 6. References

**LPI certification objectives**
- Exam 101-500 objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- Exam 102-500 objectives (Topic 110.3 lives here) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**OpenSSH — project documentation and manual pages**
- OpenSSH project — https://www.openssh.com/
- Release notes and deprecation timeline (`ssh-rsa`/SHA-1, DSA removal) — https://www.openssh.com/releasenotes.html
- OpenSSH security policy and legacy algorithm guidance — https://www.openssh.com/security.html
- `ssh(1)` — https://man.openbsd.org/ssh.1
- `ssh_config(5)` — https://man.openbsd.org/ssh_config.5
- `sshd(8)`, including the `AUTHORIZED_KEYS FILE FORMAT` and `SSH_KNOWN_HOSTS FILE FORMAT` sections — https://man.openbsd.org/sshd.8
- `sshd_config(5)` — https://man.openbsd.org/sshd_config.5
- `ssh-keygen(1)`, including `CERTIFICATES` and `ALLOWED SIGNERS` — https://man.openbsd.org/ssh-keygen.1
- `ssh-agent(1)` — https://man.openbsd.org/ssh-agent.1
- `ssh-add(1)` — https://man.openbsd.org/ssh-add.1
- `ssh-keyscan(1)` — https://man.openbsd.org/ssh-keyscan.1
- `ssh-copy-id(1)` — https://man.openbsd.org/ssh-copy-id.1
- OpenSSH FIDO/U2F support (`*-sk` keys) — https://www.openssh.com/agent-restrict.html

**GnuPG — project documentation**
- GnuPG project — https://gnupg.org/
- The GNU Privacy Handbook — https://gnupg.org/gph/en/manual.html
- `gpg` manual, Using the GNU Privacy Guard — https://gnupg.org/documentation/manuals/gnupg/
- `gpg-agent` options and configuration — https://gnupg.org/documentation/manuals/gnupg/Invoking-GPG_002dAGENT.html
- `gpgconf` — https://gnupg.org/documentation/manuals/gnupg/Invoking-gpgconf.html
- `dirmngr` (keyserver and WKD access) — https://gnupg.org/documentation/manuals/gnupg/Invoking-DIRMNGR.html
- Smartcard / OpenPGP card HOWTO — https://gnupg.org/howtos/card-howto/en/smartcard-howto.html
- GnuPG FAQ — https://gnupg.org/faq/gnupg-faq.html

**Protocol standards**
- RFC 4251 — The Secure Shell (SSH) Protocol Architecture — https://www.rfc-editor.org/rfc/rfc4251
- RFC 4252 — SSH Authentication Protocol — https://www.rfc-editor.org/rfc/rfc4252
- RFC 4253 — SSH Transport Layer Protocol — https://www.rfc-editor.org/rfc/rfc4253
- RFC 4254 — SSH Connection Protocol (channels, port forwarding, X11) — https://www.rfc-editor.org/rfc/rfc4254
- RFC 4255 — Using DNS to Securely Publish SSH Key Fingerprints (SSHFP) — https://www.rfc-editor.org/rfc/rfc4255
- RFC 4716 — The Secure Shell Public Key File Format — https://www.rfc-editor.org/rfc/rfc4716
- RFC 8332 — Use of RSA Keys with SHA-256 and SHA-512 in SSH — https://www.rfc-editor.org/rfc/rfc8332
- RFC 8709 — Ed25519 and Ed448 Public Key Algorithms for SSH — https://www.rfc-editor.org/rfc/rfc8709
- RFC 4880 — OpenPGP Message Format — https://www.rfc-editor.org/rfc/rfc4880
- RFC 9580 — OpenPGP (current revision) — https://www.rfc-editor.org/rfc/rfc9580

**X Window System**
- `xauth(1)` — https://www.x.org/releases/current/doc/man/man1/xauth.1.xhtml
- `Xsecurity(7)` — access control mechanisms — https://www.x.org/releases/current/doc/man/man7/Xsecurity.7.xhtml

**Supporting tooling referenced in the manifests**
- SOPS — https://github.com/getsops/sops
- cloud-init documentation — https://cloudinit.readthedocs.io/en/latest/
- `systemd.exec(5)` sandboxing directives — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- Git — signing commits and tags — https://git-scm.com/book/en/v2/Git-Tools-Signing-Your-Work