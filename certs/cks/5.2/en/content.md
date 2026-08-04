# 5.2 Using least-privilege identity and access management

> **Domain**: System Hardening · **Exam weight**: 2.5 · **Kubernetes**: v1.34
> **Scope**: identity of *humans*, *machines*, *workloads* and *nodes* — on the host OS, inside the cluster, and across the cloud trust boundary.

---

## 1. The architectural problem

Least-privilege IAM is not one control. In a real Kubernetes platform there are **four independent identity planes**, each with its own authenticator, its own credential material, and its own lifetime. A breach almost never happens because one of them is wrong; it happens because a credential in plane *N* can be exchanged for a credential in plane *N+1*.

```
┌────────────────────────────────────────────────────────────────────────────┐
│ PLANE 4 · Cloud IAM        AWS/GCP/Azure principals, instance profiles     │
│    ▲ exchange: OIDC federation (IRSA / Workload Identity) or IMDS theft    │
├────────────────────────────────────────────────────────────────────────────┤
│ PLANE 3 · Cluster API      Users, Groups, ServiceAccounts → RBAC/Node auth │
│    ▲ exchange: SA token on disk, TokenRequest, kubeconfig on the node      │
├────────────────────────────────────────────────────────────────────────────┤
│ PLANE 2 · Node / kubelet   system:node:<name> in group system:nodes        │
│    ▲ exchange: /var/lib/kubelet/pki/kubelet-client-current.pem             │
├────────────────────────────────────────────────────────────────────────────┤
│ PLANE 1 · Host OS          uid/gid, sudo, PAM, SSH, capabilities, systemd  │
└────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 The canonical escalation chain

This is the chain the CKS exam models, and the one that shows up verbatim in incident reports:

| Step | Attacker action | Enabling misconfiguration |
|---|---|---|
| 1 | RCE in an application container | app vulnerability (out of scope) |
| 2 | Read `/var/run/secrets/kubernetes.io/serviceaccount/token` | `automountServiceAccountToken` left at default `true` |
| 3 | `kubectl auth can-i --list` with that token → `create pods` in the namespace | over-broad Role bound to the default SA |
| 4 | Create a pod with `hostPath: /` or `hostPID: true` on a control-plane node | no Pod Security Admission `restricted`, no node taints |
| 5 | Read `/etc/kubernetes/admin.conf` from the hostPath | control-plane node schedulable |
| 6 | `curl http://169.254.169.254/latest/meta-data/iam/security-credentials/` | IMDSv1 enabled, hop limit > 1 |
| 7 | Assume the **node instance role** → EC2/S3/KMS/ECR in the whole account | node role carries `AmazonEKSClusterPolicy` or a wildcard `*` |

Every one of steps 2, 3, 4, 6 and 7 is a *least-privilege identity* failure. Fixing any single one breaks the chain; fixing all of them is what "defence in depth" means here.

### 1.2 The design rule

> **A credential must be scoped in four dimensions simultaneously: *who* (subject), *what* (verbs+resources), *where* (audience/namespace/node), and *how long* (TTL).**
> A credential that is unbounded in any one dimension is a standing privilege, regardless of how tight the other three are.

Legacy Kubernetes ServiceAccount Secrets fail on *where* and *how long* (no audience, no expiry). Static kubeconfigs with client certificates fail on *how long* (no revocation until the CA rotates). A `cluster-admin` binding fails on *what*. IMDSv1 fails on *who* (any process on the host, including a container with default networking).

---

## 2. Plane 1 — Host OS identity

### 2.1 Human accounts

The node OS is not a shared workstation. On a hardened worker node there should be **zero interactive accounts** other than a break-glass one, and administration should happen through configuration management or a rebuild.

```bash
$ awk -F: '$3 >= 1000 && $3 != 65534 {print $1, $3, $7}' /etc/passwd
deploy 1000 /bin/bash
alice 1001 /bin/bash
jenkins 1002 /bin/bash

$ awk -F: '$2 !~ /^[!*]/ {print $1}' /etc/shadow     # accounts with a usable password
root
deploy
alice
```

`root` still has a password hash — on a node reachable by SSH or console that is a standing credential nobody rotates.

```bash
# Lock the password, keep the account usable via sudo/console recovery
$ sudo passwd -l root
passwd: password expiry information changed.

# Service identities must not be able to log in at all
$ sudo useradd --system --no-create-home --shell /usr/sbin/nologin --uid 987 nodeexp
$ getent passwd nodeexp
nodeexp:x:987:987::/home/nodeexp:/usr/sbin/nologin

# Expire an offboarded human immediately (does not delete audit-relevant uid)
$ sudo usermod --lock --expiredate 1 alice
$ sudo chage -l alice | head -3
Last password change                                    : password must be changed
Password expires                                        : password must be changed
Account expires                                         : Jan 02, 1970
```

### 2.2 `sudo` — the most misconfigured privilege boundary on a node

`sudo` is where "least privilege" is usually *claimed* and rarely *achieved*. Two facts drive the design:

1. A `sudo` rule that permits any binary with a shell escape (`vi`, `less`, `find`, `awk`, `git`, `tar`, `systemctl`, `nsenter`) is equal to `ALL=(ALL) NOPASSWD: ALL`.
2. **Blacklists (`!command`) are not a security boundary.** The user can copy the binary elsewhere and the path no longer matches.

```
# /etc/sudoers.d/40-k8s-operators   (mode 0440, root:root)
#
# Least-privilege operations access for the k8s-operators group.
# ALLOWLIST ONLY. Every entry must be a binary with no shell escape and no
# argument that can be turned into arbitrary code execution.

Defaults        secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults        env_reset
Defaults        requiretty
Defaults        passwd_tries=3
Defaults        timestamp_timeout=5
Defaults        logfile="/var/log/sudo.log"
Defaults        log_input, log_output
Defaults        iolog_dir="/var/log/sudo-io/%{user}"
Defaults        lecture=never

# --- Allowed operations -----------------------------------------------------
Cmnd_Alias KUBELET_READ  = /usr/bin/systemctl status kubelet, \
                           /usr/bin/systemctl is-active kubelet, \
                           /usr/bin/journalctl -u kubelet --no-pager -n 200

Cmnd_Alias KUBELET_WRITE = /usr/bin/systemctl restart kubelet

Cmnd_Alias RUNTIME_READ  = /usr/bin/crictl ps, \
                           /usr/bin/crictl pods, \
                           /usr/bin/crictl stats

# --- Bindings ---------------------------------------------------------------
# Read-only diagnostics: no password (safe, high frequency, idempotent)
%k8s-operators  ALL=(root) NOPASSWD: KUBELET_READ, RUNTIME_READ

# Disruptive: password required, always logged with I/O capture
%k8s-operators  ALL=(root) PASSWD: KUBELET_WRITE

# Break-glass: full root, but only from the console, and heavily alerted on
%breakglass     ALL=(root) ALL
```

```bash
$ sudo visudo -cf /etc/sudoers.d/40-k8s-operators
/etc/sudoers.d/40-k8s-operators: parsed OK

$ sudo -l -U deploy
Matching Defaults entries for deploy on worker-2:
    secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin,
    env_reset, requiretty, passwd_tries=3, timestamp_timeout=5,
    logfile=/var/log/sudo.log, log_input, log_output

User deploy may run the following commands on worker-2:
    (root) NOPASSWD: /usr/bin/systemctl status kubelet, /usr/bin/systemctl is-active kubelet,
        /usr/bin/journalctl -u kubelet --no-pager -n 200, /usr/bin/crictl ps, /usr/bin/crictl pods,
        /usr/bin/crictl stats
    (root) PASSWD: /usr/bin/systemctl restart kubelet
```

**Audit every node for the anti-patterns:**

```bash
$ sudo grep -rnE 'NOPASSWD:\s*ALL|\(ALL\s*:\s*ALL\)\s*ALL|^\s*%?\S+\s+ALL=\(ALL\)\s*ALL' \
      /etc/sudoers /etc/sudoers.d/
/etc/sudoers:110:%wheel  ALL=(ALL)       ALL
/etc/sudoers.d/99-cloud-init-users:2:ec2-user ALL=(ALL) NOPASSWD:ALL

$ sudo find /etc/sudoers.d -type f ! -perm 0440 -printf '%M %p\n'
-rw-r--r-- /etc/sudoers.d/99-cloud-init-users     # world-readable, fix to 0440
```

### 2.3 SSH — restrict the entry point

```
# /etc/ssh/sshd_config.d/50-hardening.conf
Port 22
Protocol 2

PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey

# Identity allowlist — deny-by-default for everyone else
AllowGroups k8s-operators breakglass
DenyUsers root nodeexp

MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no

LogLevel VERBOSE
```

```bash
$ sudo sshd -t && echo "config OK"
config OK
$ sudo systemctl reload sshd

$ sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|allowgroups|maxauthtries)'
permitrootlogin no
passwordauthentication no
maxauthtries 3
allowgroups k8s-operators breakglass
```

### 2.4 Process-level identity: SUID, SGID and file capabilities

A SUID binary is a permanent, unauthenticated privilege escalation primitive available to every local uid — including a container that shares the host filesystem through a `hostPath` mount.

```bash
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u:%g %p\n' 2>/dev/null | sort
-rwsr-xr-x root:root /usr/bin/chsh
-rwsr-xr-x root:root /usr/bin/gpasswd
-rwsr-xr-x root:root /usr/bin/mount
-rwsr-xr-x root:root /usr/bin/newgrp
-rwsr-xr-x root:root /usr/bin/passwd
-rwsr-xr-x root:root /usr/bin/su
-rwsr-xr-x root:root /usr/bin/sudo
-rwsr-xr-x root:root /usr/bin/umount
-rwsr-xr-x root:root /usr/local/bin/backup-helper      # <-- not part of the base OS

$ sudo getcap -r / 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newuidmap cap_setuid=ep
/usr/bin/newgidmap cap_setgid=ep
/opt/agent/collector cap_sys_admin,cap_dac_read_search=eip   # <-- effectively root
```

`cap_sys_admin` and `cap_dac_read_search` on a third-party agent are a full compromise of the node. Remove or replace:

```bash
$ sudo setcap -r /opt/agent/collector
$ sudo getcap /opt/agent/collector
$ sudo chmod u-s /usr/local/bin/backup-helper
$ ls -l /usr/local/bin/backup-helper
-rwxr-xr-x. 1 root root 18240 Jul 11 09:22 /usr/local/bin/backup-helper
```

### 2.5 Least privilege for host daemons via systemd

Every agent that runs on the node (log shipper, metrics exporter, EDR) is a privileged identity. Constrain it in the unit, not in documentation.

```ini
# /etc/systemd/system/node-exporter.service.d/10-hardening.conf
[Service]
User=nodeexp
Group=nodeexp
DynamicUser=no

# --- Privilege ---------------------------------------------------------------
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
SecureBits=noroot noroot-locked
RestrictSUIDSGID=yes

# --- Filesystem --------------------------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ReadWritePaths=/var/lib/node-exporter
UMask=0077

# --- Kernel ------------------------------------------------------------------
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
LockPersonality=yes
MemoryDenyWriteExecute=yes

# --- Namespaces & syscalls ---------------------------------------------------
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @debug @obsolete
```

```bash
$ sudo systemctl daemon-reload && sudo systemctl restart node-exporter
$ systemd-analyze security node-exporter.service | tail -5
→ Overall exposure level for node-exporter.service: 1.6 SAFE 😀

$ systemctl show node-exporter -p User -p CapabilityBoundingSet -p NoNewPrivileges
User=nodeexp
CapabilityBoundingSet=
NoNewPrivileges=yes
```

### 2.6 PAM: lockout and password quality

```
# /etc/security/faillock.conf
deny = 5
unlock_time = 900
fail_interval = 900
even_deny_root
audit
silent
```

```
# /etc/security/pwquality.conf
minlen = 14
minclass = 4
maxrepeat = 3
dictcheck = 1
enforce_for_root
```

```bash
$ faillock --user alice
alice:
When                Type  Source                                           Valid
2026-08-04 11:02:31 TTY   /dev/pts/0                                           V
2026-08-04 11:02:38 TTY   /dev/pts/0                                           V

$ sudo faillock --user alice --reset
```

### 2.7 auditd: detect identity mutation

```
# /etc/audit/rules.d/50-identity.rules
-w /etc/passwd            -p wa -k identity
-w /etc/shadow            -p wa -k identity
-w /etc/group             -p wa -k identity
-w /etc/gshadow           -p wa -k identity
-w /etc/sudoers           -p wa -k identity
-w /etc/sudoers.d/        -p wa -k identity
-w /etc/ssh/sshd_config   -p wa -k identity
-w /etc/ssh/sshd_config.d/ -p wa -k identity

# Any successful transition of real/effective uid by a non-system account
-a always,exit -F arch=b64 -S setuid,setreuid,setresuid -F auid>=1000 -F auid!=unset -k privesc
-a always,exit -F arch=b64 -S setgid,setregid,setresgid -F auid>=1000 -F auid!=unset -k privesc

# Node identity material — theft of these is a cluster compromise
-w /etc/kubernetes/admin.conf        -p rwa -k k8s-identity
-w /etc/kubernetes/kubelet.conf      -p rwa -k k8s-identity
-w /var/lib/kubelet/pki/             -p rwa -k k8s-identity
-w /etc/kubernetes/pki/              -p rwa -k k8s-identity
```

```bash
$ sudo augenrules --load
$ sudo auditctl -l | grep -c identity
10

$ sudo ausearch -k k8s-identity -ts recent -i | head -12
type=PROCTITLE msg=audit(04/08/26 11:41:07.882:9134) : proctitle=cat /etc/kubernetes/admin.conf
type=PATH msg=audit(04/08/26 11:41:07.882:9134) : item=0 name=/etc/kubernetes/admin.conf
    inode=524301 dev=fd:00 mode=file,600 ouid=root ogid=root
type=SYSCALL msg=audit(04/08/26 11:41:07.882:9134) : arch=x86_64 syscall=openat success=yes
    exit=3 ppid=44120 pid=44210 auid=deploy uid=root gid=root euid=root suid=root
    comm=cat exe=/usr/bin/cat subj=unconfined key=k8s-identity
```

`auid=deploy` survives every `setuid` in the chain — that is the field an investigation actually uses.

---

## 3. Plane 2/3 — Kubernetes workload identity

### 3.1 Anatomy of a modern ServiceAccount token

Since v1.21 (`BoundServiceAccountTokenVolume` GA) the kubelet injects a **projected, bound, expiring** token — not a Secret. In v1.33+ the token additionally carries node binding claims (`ServiceAccountTokenPodNodeInfo`, `ServiceAccountTokenNodeBinding` GA).

```bash
$ kubectl -n payments exec deploy/api -- \
    cat /var/run/secrets/kubernetes.io/serviceaccount/token | cut -d. -f2 | base64 -d 2>/dev/null | jq
{
  "aud": [
    "https://kubernetes.default.svc.cluster.local"
  ],
  "exp": 1786218061,
  "iat": 1786214461,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "2f0a9c1e-7b44-4e2f-9c8d-1a5b6e3f0d21",
  "kubernetes.io": {
    "namespace": "payments",
    "node": {
      "name": "worker-2",
      "uid": "5a2f8e10-6c31-4f0b-9d77-b0c1d2e3f4a5"
    },
    "pod": {
      "name": "api-7c9f8d6b64-2xk9p",
      "uid": "1c1a4b77-9d0e-4a3c-8f21-77c4e9b0aa31"
    },
    "serviceaccount": {
      "name": "api",
      "uid": "0d3e5a91-2b6c-4d8e-b1f0-3c9a7e5d2b48"
    },
    "warnafter": 1786218061
  },
  "nbf": 1786214461,
  "sub": "system:serviceaccount:payments:api"
}
```

What each claim buys you:

| Claim | Dimension | Security property |
|---|---|---|
| `sub` | *who* | Maps to the RBAC subject `system:serviceaccount:<ns>:<name>` |
| `aud` | *where* | Token is rejected by any verifier that does not expect this audience — stops replay against Vault, cloud STS, or a sidecar |
| `exp` / `iat` | *how long* | Default 1 h in-cluster; kubelet re-projects at 80 % of TTL |
| `kubernetes.io.pod` | *where* | API server invalidates the token the moment the Pod object is deleted |
| `kubernetes.io.node` | *where* | Token is invalid if the node object is gone; enables node-scoped policy in external verifiers |

### 3.2 Token mechanisms compared

| | Legacy SA Secret | Projected token (auto) | `TokenRequest` (`kubectl create token`) | X.509 client cert | OIDC / external IdP |
|---|---|---|---|---|---|
| Created by | manual Secret since v1.24 | kubelet, automatic | API call to `sa/token` subresource | CSR + signer | external IdP |
| Expiry | **never** | 1 h, auto-rotated | caller-chosen (`--duration`) | cert `notAfter` (often 1 y) | IdP-controlled |
| Audience-bound | ❌ | ✅ | ✅ (`--audience`) | ❌ | ✅ |
| Object-bound | ❌ | ✅ Pod (+Node) | ✅ (`--bound-object-*`) | ❌ | ❌ |
| Revocable | delete Secret | delete Pod | delete bound object | ❌ (no CRL support) | IdP session revoke |
| Stored at rest in etcd | ✅ (bad) | ❌ | ❌ | ❌ (only the CSR) | ❌ |
| Good for humans | ❌ | ❌ | ❌ | break-glass only | ✅ **preferred** |
| Good for in-cluster workloads | ❌ | ✅ **preferred** | ✅ for external verifiers | ❌ | ❌ |
| Good for CI/CD outside cluster | ❌ | ❌ | ✅ short-lived, per-run | ⚠️ | ✅ |

**Rule for the exam and for production:** never create a `kubernetes.io/service-account-token` Secret. If a legacy token is unavoidable (an old controller that reads a Secret), pin its lifetime with a rotation job and record why.

```yaml
# ANTI-PATTERN — shown so you can recognise and remove it.
# A non-expiring bearer token, stored in plaintext in etcd, readable by anyone
# with `get secrets` in the namespace.
apiVersion: v1
kind: Secret
metadata:
  name: deploy-bot-legacy-token
  namespace: payments
  annotations:
    kubernetes.io/service-account.name: deploy-bot
type: kubernetes.io/service-account-token
```

Find them all:

```bash
$ kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SA:.metadata.annotations.kubernetes\.io/service-account\.name,AGE:.metadata.creationTimestamp'
NS         NAME                       SA           AGE
kube-system  dashboard-token           dashboard    2024-11-02T08:14:55Z
payments     deploy-bot-legacy-token   deploy-bot   2025-03-19T17:41:02Z
```

Kubernetes ≥1.29 tracks and cleans unused legacy tokens (`LegacyServiceAccountTokenCleanUp`); the `kubernetes.io/legacy-token-last-used` label tells you whether anything still needs it:

```bash
$ kubectl -n payments get secret deploy-bot-legacy-token \
    -o jsonpath='{.metadata.labels.kubernetes\.io/legacy-token-last-used}{"\n"}'
2026-07-30
```

### 3.3 Minting a scoped token on demand

```bash
# Audience-bound, 10 minutes, tied to a specific Pod's lifetime
$ kubectl -n payments create token deploy-bot \
    --duration=10m \
    --audience=vault.internal \
    --bound-object-kind=Pod \
    --bound-object-name=api-7c9f8d6b64-2xk9p
eyJhbGciOiJSUzI1NiIsImtpZCI6IkxxNVRfazd2N0JaN3RQMFZ3Vk5nMDNiWFpEUWVzY0k0In0.eyJhdWQiOlsidmF1bHQu...

# Verify what the API server actually issued (durations are clamped by
# --service-account-max-token-expiration on the API server)
$ kubectl -n payments create token deploy-bot --duration=48h --audience=vault.internal \
    | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, iat, exp, ttl_hours: ((.exp-.iat)/3600)}'
{
  "aud": [ "vault.internal" ],
  "iat": 1786214461,
  "exp": 1786301, 
  "ttl_hours": 24
}
```

> The request asked for 48 h; the API server capped it at its configured maximum. **Always verify `exp`, never assume `--duration` was honoured.**

### 3.4 Turning off ambient identity

Two switches, and the Pod-level one wins.

```yaml
---
# The ServiceAccount every namespace gets for free. Neutralise it so that a
# workload that forgets to declare an identity gets *no* identity.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: payments
automountServiceAccountToken: false
---
# The workload's own identity: still no ambient mount. The token is requested
# explicitly, with an explicit audience and TTL, only where it is needed.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api
  namespace: payments
automountServiceAccountToken: false
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: payments
  labels:
    app.kubernetes.io/name: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api
    spec:
      serviceAccountName: api
      automountServiceAccountToken: false     # no /var/run/secrets/kubernetes.io
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          image: registry.internal/payments/api@sha256:3f9d0a1b7c4e5f6081a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop: ["ALL"]
          env:
            - name: VAULT_ADDR
              value: https://vault.internal:8200
            - name: VAULT_JWT_PATH
              value: /var/run/secrets/vault.internal/token
          volumeMounts:
            - name: vault-identity
              mountPath: /var/run/secrets/vault.internal
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
      volumes:
        # Explicit, audience-scoped, 10-minute identity for exactly one verifier.
        - name: vault-identity
          projected:
            defaultMode: 0400
            sources:
              - serviceAccountToken:
                  path: token
                  audience: vault.internal
                  expirationSeconds: 600
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
```

Verification:

```bash
$ kubectl -n payments exec deploy/api -- ls -l /var/run/secrets/kubernetes.io/serviceaccount 2>&1
ls: cannot access '/var/run/secrets/kubernetes.io/serviceaccount': No such file or directory
command terminated with exit code 2

$ kubectl -n payments exec deploy/api -- ls -l /var/run/secrets/vault.internal/
total 0
lrwxrwxrwx 1 root root 12 Aug  4 11:58 token -> ..data/token

$ kubectl -n payments exec deploy/api -- \
    sh -c 'cut -d. -f2 /var/run/secrets/vault.internal/token' | base64 -d 2>/dev/null | jq '{aud, ttl:((.exp-.iat))}'
{
  "aud": [ "vault.internal" ],
  "ttl": 600
}
```

Cluster-wide sweep for workloads that still mount ambient identity:

```bash
$ kubectl get pods -A -o json | jq -r '
  .items[]
  | select((.spec.automountServiceAccountToken // true) == true)
  | select(.spec.serviceAccountName == "default")
  | "\(.metadata.namespace)/\(.metadata.name)  sa=\(.spec.serviceAccountName)"'
default/legacy-cron-28901234-x7k2p  sa=default
monitoring/grafana-6b7d9c5f4-qq8lm  sa=default
payments/debug-shell                sa=default
```

### 3.5 RBAC: verbs that are `cluster-admin` in disguise

Reviewing RBAC by reading `Role` names is useless. Review by **capability**. These grants are privilege escalations regardless of how narrow they look:

| Grant | Why it is effectively cluster-admin |
|---|---|
| `create` on `serviceaccounts/token` | Mint a token for **any** SA in the namespace, including one bound to `cluster-admin` |
| `escalate` on `roles`/`clusterroles` | Bypasses the built-in privilege-escalation-prevention check; write yourself any permission |
| `bind` on `roles`/`clusterroles` | Bind an existing `cluster-admin` ClusterRole to yourself |
| `impersonate` on `users`/`groups`/`serviceaccounts` | Act as `system:masters` |
| `create` on `pods` (any namespace with privileged workloads) | Schedule a pod with `hostPath: /`, mount node credentials |
| `create` on `pods/exec`, `pods/attach`, `pods/ephemeralcontainers` | Enter a pod that already holds a stronger identity |
| `get`/`list` on `secrets` | Read every credential the namespace holds |
| `update`/`patch` on `nodes` or `nodes/status` | Change taints/labels to attract privileged workloads |
| `approve` on `certificatesigningrequests/approval` + `signers` | Issue a client cert for `system:masters` |
| `update` on `validatingwebhookconfigurations` / `mutatingwebhookconfigurations` | Disable admission control, or inject sidecars everywhere |
| `patch` on `daemonsets`/`deployments` in `kube-system` | Own every node |
| `*` on `*.*` scoped by `namespace` | Everything above, inside that namespace |

**Find them:**

```bash
# Anything bound to cluster-admin
$ kubectl get clusterrolebindings -o json | jq -r '
  .items[]
  | select(.roleRef.name == "cluster-admin")
  | .metadata.name as $n
  | (.subjects // [])[]
  | "\($n)\t\(.kind)\t\(.namespace // "-")/\(.name)"' | column -t
cluster-admin                    Group            -/system:masters
platform-team-admin              Group            -/oidc:platform-sre
ci-runner-admin                  ServiceAccount   ci/runner        # <-- investigate

# Anything holding a wildcard verb
$ kubectl get clusterroles -o json | jq -r '
  .items[]
  | select(.metadata.name | startswith("system:") | not)
  | select([.rules[]? | select((.verbs // []) | index("*"))] | length > 0)
  | .metadata.name'
ci-runner
legacy-operator

# The dangerous verbs, everywhere
$ kubectl get roles,clusterroles -A -o json | jq -r '
  .items[]
  | .metadata.namespace as $ns | .metadata.name as $name | .kind as $kind
  | (.rules // [])[]
  | select(((.verbs // []) | any(. == "escalate" or . == "bind" or . == "impersonate"))
        or ((.resources // []) | any(. == "serviceaccounts/token")))
  | "\($kind)\t\($ns // "-")/\($name)\tverbs=\(.verbs)\tres=\(.resources)"' | column -t
ClusterRole  -/legacy-operator   verbs=["bind","escalate"]  res=["clusterroles"]
Role         ci/deployer         verbs=["create"]           res=["serviceaccounts/token"]
```

### 3.6 A least-privilege RBAC set, written out

```yaml
---
# Namespaced identity for the deployment controller. It may roll out workloads
# and read its own configuration. It may NOT read secrets, exec into pods, or
# mint tokens.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deploy-bot
  namespace: payments
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deploy-bot
  namespace: payments
rules:
  # Workload rollout — note: no "delete" on deployments, no "*" verbs.
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]

  # Rollout observability only.
  - apiGroups: ["apps"]
    resources: ["deployments/status", "statefulsets/status", "replicasets"]
    verbs: ["get", "list", "watch"]

  - apiGroups: [""]
    resources: ["pods", "pods/log", "events"]
    verbs: ["get", "list", "watch"]

  # Configuration this bot owns, addressed by name. resourceNames is the single
  # most under-used field in RBAC and the cheapest way to shrink blast radius.
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["api-config", "api-feature-flags"]
    verbs: ["get", "update", "patch"]

  # Services it must keep in sync, again by name.
  - apiGroups: [""]
    resources: ["services"]
    resourceNames: ["api", "api-headless"]
    verbs: ["get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deploy-bot
  namespace: payments
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deploy-bot
subjects:
  - kind: ServiceAccount
    name: deploy-bot
    namespace: payments
---
# Cluster-scoped read the bot genuinely needs: it resolves StorageClasses and
# IngressClasses by name. Cluster scope is unavoidable here; keep it read-only
# and enumerate the resources.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: deploy-bot-cluster-read
rules:
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingressclasses"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: deploy-bot-cluster-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: deploy-bot-cluster-read
subjects:
  - kind: ServiceAccount
    name: deploy-bot
    namespace: payments
---
# Human access via OIDC groups — never bind an individual user.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-oncall-read
  namespace: payments
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view                       # built-in; excludes secrets by design
subjects:
  - kind: Group
    name: oidc:payments-oncall
    apiGroup: rbac.authorization.k8s.io
```

Apply with drift-aware reconciliation rather than `apply` (this preserves aggregated rules and prunes removed ones correctly):

```bash
$ kubectl auth reconcile -f rbac/deploy-bot.yaml
serviceaccount/deploy-bot unchanged
role.rbac.authorization.k8s.io/deploy-bot reconciled
  reconciliation required update
  missing rules added:
        {Verbs:["get" "list" "watch"], APIGroups:[""], Resources:["events"]}
rolebinding.rbac.authorization.k8s.io/deploy-bot reconciled
clusterrole.rbac.authorization.k8s.io/deploy-bot-cluster-read unchanged
clusterrolebinding.rbac.authorization.k8s.io/deploy-bot-cluster-read unchanged

$ kubectl auth reconcile -f rbac/deploy-bot.yaml --remove-extra-permissions --remove-extra-subjects --dry-run=client
role.rbac.authorization.k8s.io/deploy-bot reconciled (dry run)
  extra rules removed:
        {Verbs:["delete"], APIGroups:["apps"], Resources:["deployments"]}
```

### 3.7 Node identity: the Node authorizer and NodeRestriction

The kubelet authenticates as `system:node:<nodeName>` in group `system:nodes`. Two controls make that identity *node-scoped* instead of *cluster-scoped*:

- **Node authorizer** — a graph-based authorizer that lets a kubelet read only the Secrets/ConfigMaps/PVCs referenced by Pods **scheduled on that node**.
- **NodeRestriction admission plugin** — stops a kubelet from modifying other nodes' objects, from setting `node-restriction.kubernetes.io/*` labels on itself, and (with `ServiceAccountTokenNodeBinding`) from requesting tokens for pods it does not run.

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml  (relevant flags only)
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        - --authorization-config=/etc/kubernetes/authorization-config.yaml
        - --enable-admission-plugins=NodeRestriction,PodSecurity,ServiceAccount
        - --anonymous-auth=false
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        - --api-audiences=https://kubernetes.default.svc.cluster.local
        - --service-account-max-token-expiration=24h
        - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit.log
        - --audit-log-maxage=30
        - --audit-log-maxbackup=10
        - --audit-log-maxsize=100
```

```yaml
# /etc/kubernetes/authorization-config.yaml
# Structured authorization config (apiserver.config.k8s.io/v1, GA in v1.32).
# Order matters: the first authorizer to return Allow or Deny wins.
apiVersion: apiserver.config.k8s.io/v1
kind: AuthorizationConfiguration
authorizers:
  - type: Node
    name: node

  # Break-glass and emergency deny list, evaluated before RBAC can allow.
  - type: Webhook
    name: deny-quarantined-identities
    webhook:
      connectionInfo:
        type: KubeConfigFile
        kubeConfigFile: /etc/kubernetes/authz-webhook.kubeconfig
      authorizedTTL: 0s
      unauthorizedTTL: 30s
      timeout: 3s
      subjectAccessReviewVersion: v1
      matchConditionSubjectAccessReviewVersion: v1
      failurePolicy: Deny
      matchConditions:
        # Only consult the webhook for write verbs by non-system identities;
        # everything else skips it, so an outage cannot brown out the cluster.
        - expression: "!('system:nodes' in request.groups)"
        - expression: >-
            request.resourceAttributes != null &&
            request.resourceAttributes.verb in
              ['create','update','patch','delete','deletecollection','escalate','bind','impersonate']

  - type: RBAC
    name: rbac
```

```bash
$ kubectl get --raw '/livez?verbose' | grep -i authoriz
[+]poststarthook/start-apiserver-admission-initializer ok

# Prove the node scope holds: a kubelet must not read an unrelated Secret
$ sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf \
     -n payments get secret db-credentials
Error from server (Forbidden): secrets "db-credentials" is forbidden:
User "system:node:worker-2" cannot get resource "secrets" in API group "" in the namespace "payments":
no relationship found between node 'worker-2' and this object

# Prove NodeRestriction holds: a kubelet must not label another node
$ sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf \
     label node worker-3 tier=privileged
Error from server (Forbidden): nodes "worker-3" is forbidden:
node "worker-2" is not allowed to modify node "worker-3"
```

Kubelet side — the node's own API surface must not be an anonymous identity:

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
readOnlyPort: 0
rotateCertificates: true
serverTLSBootstrap: true
protectKernelDefaults: true
seccompDefault: true
```

```bash
$ curl -sk https://worker-2:10250/pods | head -3
Unauthorized

$ curl -s http://worker-2:10255/pods
curl: (7) Failed to connect to worker-2 port 10255: Connection refused

$ ls -l /var/lib/kubelet/pki/
total 12
-rw------- 1 root root 1114 Aug  4 09:12 kubelet-client-2026-08-04-09-12-33.pem
lrwxrwxrwx 1 root root   59 Aug  4 09:12 kubelet-client-current.pem -> /var/lib/kubelet/pki/kubelet-client-2026-08-04-09-12-33.pem
-rw------- 1 root root 1273 Aug  4 09:12 kubelet-server-current.pem

$ sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -enddate
subject=O=system:nodes, CN=system:node:worker-2
notAfter=Nov  2 09:12:33 2026 GMT
```

---

## 4. Plane 4 — the cloud IAM boundary

### 4.1 The instance metadata service is an unauthenticated identity oracle

By default, **any process with network access on the node — including a pod on the pod network — can read the node's cloud credentials** at `169.254.169.254`. That is a single flat identity shared by every workload on the node.

```bash
# From inside a pod, on an unhardened cluster:
$ kubectl -n payments run probe --rm -it --restart=Never --image=curlimages/curl:8.9.1 -- \
    curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/
eks-node-group-role
pod "probe" deleted
```

That output is a finding. Three layers fix it:

**Layer 1 — cloud-side (authoritative).** IMDSv2 with a PUT-response hop limit of 1 makes the endpoint unreachable from a pod network namespace, because the packet crosses one extra hop.

```bash
$ aws ec2 modify-instance-metadata-options \
    --instance-id i-0abcd1234ef567890 \
    --http-endpoint enabled \
    --http-tokens required \
    --http-put-response-hop-limit 1 \
    --http-protocol-ipv6 disabled
{
    "InstanceId": "i-0abcd1234ef567890",
    "InstanceMetadataOptions": {
        "State": "pending",
        "HttpTokens": "required",
        "HttpPutResponseHopLimit": 1,
        "HttpEndpoint": "enabled",
        "HttpProtocolIpv6": "disabled",
        "InstanceMetadataTags": "disabled"
    }
}

$ aws ec2 describe-instances --instance-ids i-0abcd1234ef567890 \
    --query 'Reservations[].Instances[].MetadataOptions' --output table
------------------------------------------------
|               DescribeInstances              |
+------------------------+---------------------+
|  HttpEndpoint          |  enabled            |
|  HttpProtocolIpv6      |  disabled           |
|  HttpPutResponseHopLimit|  1                 |
|  HttpTokens            |  required           |
|  State                 |  applied            |
+------------------------+---------------------+
```

**Layer 2 — NetworkPolicy.** Defence in depth, and the only layer you control from inside the cluster.

```yaml
---
# Default-deny egress for the namespace. Everything else is additive.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
# Re-allow exactly what the workloads need, with link-local and the node
# network carved out of the internet range.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-except-metadata
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # Cluster DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53

    # Kubernetes API (adjust to your service CIDR)
    - to:
        - ipBlock:
            cidr: 10.96.0.1/32
      ports:
        - protocol: TCP
          port: 443

    # Everything else on the internet, minus every private and link-local range.
    # 169.254.0.0/16 covers IMDS (169.254.169.254) and the EKS Pod Identity
    # agent (169.254.170.23); GKE's metadata server is also link-local.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.0.0/16
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 127.0.0.0/8
      ports:
        - protocol: TCP
          port: 443
```

> **Two gotchas that invalidate this policy.**
> 1. A pod with `hostNetwork: true` is on the node's network namespace and **is not subject to pod NetworkPolicy**. Block `hostNetwork` with Pod Security Admission `restricted` or an admission policy.
> 2. Some CNIs implement `ipBlock` only for traffic that leaves the node. Verify empirically with the probe in §5.3 rather than trusting the manifest.

**Layer 3 — shrink the node role itself.** Even with IMDS blocked, the node role is what the kubelet and the CNI use. It should carry only `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly` (or a scoped ECR policy) and the CNI policy — never `AdministratorAccess`, never `iam:PassRole` with `Resource: "*"`, never S3/KMS for application data.

### 4.2 Federating workload identity instead of sharing the node identity

The correct model: each Kubernetes ServiceAccount maps to exactly one cloud principal, and the exchange is an OIDC token trade — no long-lived cloud key anywhere.

```bash
$ kubectl get --raw /.well-known/openid-configuration | jq
{
  "issuer": "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE",
  "jwks_uri": "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE/keys",
  "authorization_endpoint": "urn:kubernetes:programmatic_authorization",
  "response_types_supported": [ "id_token" ],
  "subject_types_supported": [ "public" ],
  "claims_supported": [ "sub", "iss" ],
  "id_token_signing_alg_values_supported": [ "RS256" ]
}

$ kubectl get --raw /openid/v1/jwks | jq '.keys[0] | {kty, alg, use, kid}'
{
  "kty": "RSA",
  "alg": "RS256",
  "use": "sig",
  "kid": "Lq5T_k7v7BZ7tP0VwVNg03bXZDQescI4"
}
```

Anonymous discovery must be granted deliberately, not by accident:

```yaml
# Only bind this if an external verifier genuinely needs unauthenticated
# discovery. Otherwise leave it bound to system:authenticated only.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: service-account-issuer-discovery
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:service-account-issuer-discovery
subjects:
  - kind: Group
    name: system:authenticated      # NOT system:unauthenticated
    apiGroup: rbac.authorization.k8s.io
```

**AWS — IRSA.** The trust policy is where least privilege lives or dies:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowOnlyThisServiceAccount",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::111122223333:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:aud": "sts.amazonaws.com",
          "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub": "system:serviceaccount:payments:s3-reader"
        }
      }
    }
  ]
}
```

> **Never** write `"StringLike": {"...:sub": "system:serviceaccount:*"}`. That single wildcard lets *any* ServiceAccount in *any* namespace of the cluster assume the role — a namespace-creation permission then becomes a cloud-account compromise.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader
  namespace: payments
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/payments-s3-reader
    eks.amazonaws.com/sts-regional-endpoints: "true"
    eks.amazonaws.com/token-expiration: "3600"
automountServiceAccountToken: false
```

The mutating webhook injects the projected token and the SDK env vars:

```bash
$ kubectl -n payments get pod s3-sync-6d8f7b9c4-lk2wn -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
AWS_STS_REGIONAL_ENDPOINTS=regional
AWS_DEFAULT_REGION=eu-west-1
AWS_REGION=eu-west-1
AWS_ROLE_ARN=arn:aws:iam::111122223333:role/payments-s3-reader
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token

$ kubectl -n payments exec s3-sync-6d8f7b9c4-lk2wn -- aws sts get-caller-identity
{
    "UserId": "AROAEXAMPLEID:botocore-session-1786214999",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/payments-s3-reader/botocore-session-1786214999"
}
```

**Provider comparison:**

| | AWS IRSA | AWS EKS Pod Identity | GKE Workload Identity Federation | Azure Workload Identity |
|---|---|---|---|---|
| Binding surface | SA annotation + IAM trust policy | `PodIdentityAssociation` API (no annotation) | SA annotation / direct principal | SA label + annotation |
| Credential path | projected token → `AssumeRoleWithWebIdentity` | agent at `169.254.170.23` | GKE metadata server (`169.254.169.254` shadowed) | projected token → Entra ID |
| Requires cluster OIDC exposed publicly | ✅ | ❌ | ❌ | ✅ |
| Cross-account | via role chaining | native | n/a | via multi-tenant app |
| Token audience | `sts.amazonaws.com` | internal | `<project>.svc.id.goog` | `api://AzureADTokenExchange` |
| Blocks node-role inheritance | ✅ (if IMDS blocked) | ✅ | ✅ (metadata server filters) | ✅ |
| Rotation | 1 h, automatic | automatic | automatic | 1 h, automatic |
| Main failure mode | `sub`/`aud` mismatch in trust policy | missing association | node pool created without `--workload-metadata-from-node=GKE_METADATA` | wrong `client-id`, missing `use: "true"` label |

```yaml
---
# GKE Workload Identity Federation
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gcs-reader
  namespace: payments
  annotations:
    iam.gke.io/gcp-service-account: payments-gcs-reader@my-project.iam.gserviceaccount.com
automountServiceAccountToken: false
---
# Azure Workload Identity
apiVersion: v1
kind: ServiceAccount
metadata:
  name: blob-reader
  namespace: payments
  labels:
    azure.workload.identity/use: "true"
  annotations:
    azure.workload.identity/client-id: 8f2b9c1d-4e5a-4f60-9b7c-2d3e4f5a6b7c
    azure.workload.identity/tenant-id: 1a2b3c4d-5e6f-4708-9a1b-2c3d4e5f6071
automountServiceAccountToken: false
```

---

## 5. Verification and failure diagnosis

### 5.1 Establish who you are before debugging what you can do

```bash
$ kubectl auth whoami
ATTRIBUTE                                           VALUE
Username                                            oidc:alice@example.com
UID                                                 8c8f7f5a-0b31-4e33-9a2c-1f0e7d6c5b4a
Groups                                              [oidc:payments-oncall system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [JTI=9f3ac2b1-...]
```

Half of all "RBAC is broken" tickets are resolved here: the user is authenticating as someone other than who they think.

```bash
$ kubectl auth whoami -o yaml
apiVersion: authentication.k8s.io/v1
kind: SelfSubjectReview
status:
  userInfo:
    groups:
      - oidc:payments-oncall
      - system:authenticated
    uid: 8c8f7f5a-0b31-4e33-9a2c-1f0e7d6c5b4a
    username: oidc:alice@example.com
```

### 5.2 Enumerate effective permissions

```bash
# What can this ServiceAccount actually do?
$ kubectl auth can-i --list -n payments --as=system:serviceaccount:payments:deploy-bot
Resources                                       Non-Resource URLs                     Resource Names                   Verbs
deployments.apps                                []                                    []                               [get list watch create update patch]
statefulsets.apps                               []                                    []                               [get list watch create update patch]
pods                                            []                                    []                               [get list watch]
pods/log                                        []                                    []                               [get list watch]
events                                          []                                    []                               [get list watch]
configmaps                                      []                                    [api-config api-feature-flags]   [get update patch]
services                                        []                                    [api api-headless]               [get update patch]
selfsubjectreviews.authentication.k8s.io        []                                    []                               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                                    []                               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                                    []                               [create]
                                                [/api/*]                              []                               [get]
                                                [/healthz]                            []                               [get]
                                                [/version]                            []                               [get]

# The specific negative checks that matter
$ kubectl auth can-i get secrets -n payments --as=system:serviceaccount:payments:deploy-bot
no

$ kubectl auth can-i create pods/exec -n payments --as=system:serviceaccount:payments:deploy-bot
no

$ kubectl auth can-i create serviceaccounts/token -n payments --as=system:serviceaccount:payments:deploy-bot
no

$ kubectl auth can-i '*' '*' --all-namespaces --as=system:serviceaccount:payments:deploy-bot
no

# Group-based check (humans)
$ kubectl auth can-i delete deployments -n payments \
    --as=alice@example.com --as-group=oidc:payments-oncall
no
```

Test with the *real* token, not with impersonation, when the identity crosses a webhook or an external authorizer:

```bash
$ TOKEN=$(kubectl -n payments create token deploy-bot --duration=5m)
$ kubectl --token="$TOKEN" --server=https://api.cluster.internal:6443 \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    -n payments get secrets
Error from server (Forbidden): secrets is forbidden:
User "system:serviceaccount:payments:deploy-bot" cannot list resource "secrets" in API group "" in the namespace "payments"
```

### 5.3 Prove the metadata boundary holds

```bash
$ cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: imds-probe
  namespace: payments
  labels:
    app.kubernetes.io/name: imds-probe
spec:
  serviceAccountName: default
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: curlimages/curl:8.9.1
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      command:
        - sh
        - -c
        - |
          set -x
          echo "--- IMDSv1 ---"
          curl -s -o /dev/null -w '%{http_code}\n' --max-time 4 \
            http://169.254.169.254/latest/meta-data/ || echo "blocked(v1)"
          echo "--- IMDSv2 ---"
          curl -s -X PUT --max-time 4 \
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
            http://169.254.169.254/latest/api/token || echo "blocked(v2)"
          echo "--- EKS Pod Identity agent ---"
          curl -s -o /dev/null -w '%{http_code}\n' --max-time 4 \
            http://169.254.170.23/v1/credentials || echo "blocked(agent)"
EOF
pod/imds-probe created

$ kubectl -n payments logs imds-probe
+ echo --- IMDSv1 ---
--- IMDSv1 ---
+ curl -s -o /dev/null -w %{http_code}\n --max-time 4 http://169.254.169.254/latest/meta-data/
+ echo blocked(v1)
blocked(v1)
+ echo --- IMDSv2 ---
--- IMDSv2 ---
+ curl -s -X PUT --max-time 4 -H X-aws-ec2-metadata-token-ttl-seconds: 60 http://169.254.169.254/latest/api/token
+ echo blocked(v2)
blocked(v2)
+ echo --- EKS Pod Identity agent ---
--- EKS Pod Identity agent ---
+ echo blocked(agent)
blocked(agent)

$ kubectl -n payments delete pod imds-probe
pod "imds-probe" deleted
```

Anything other than `blocked` on all three lines is an open finding.

### 5.4 Read the 403 correctly

A Kubernetes authorization error tells you the *subject*, the *verb*, the *resource*, the *API group* and the *namespace*. Parse all five before touching RBAC:

```
Error from server (Forbidden): deployments.apps "api" is forbidden:
        User "system:serviceaccount:payments:deploy-bot"        ← subject (wrong SA? wrong kubeconfig context?)
        cannot delete resource "deployments"                    ← verb (not in the Role)
        in API group "apps"                                     ← apiGroups: ["apps"], not [""]
        in the namespace "payments"                             ← RoleBinding namespace must match
```

Three distinct root causes, distinguishable only by this string:

| Message fragment | Root cause | Fix |
|---|---|---|
| `cannot <verb> resource "<r>" in API group "<g>"` | Rule missing or wrong `apiGroups` | Add the verb/group to the Role |
| `no relationship found between node '<n>' and this object` | Node authorizer, not RBAC | The kubelet legitimately has no pod referencing that object |
| `... is forbidden: User "system:anonymous" ...` | Authentication failed silently — token expired or was never sent | Check `exp`, check the kubeconfig |
| `attempt to grant extra privileges` | Privilege-escalation prevention on RBAC write | You need `escalate`, or you must already hold the permissions you are granting |

```bash
$ kubectl create clusterrolebinding oops --clusterrole=cluster-admin --user=bob \
    --as=system:serviceaccount:payments:deploy-bot
Error from server (Forbidden): clusterrolebindings.rbac.authorization.k8s.io is forbidden:
User "system:serviceaccount:payments:deploy-bot" cannot create resource "clusterrolebindings"
in API group "rbac.authorization.k8s.io" at the cluster scope
```

### 5.5 Trace the request

```bash
$ kubectl -n payments get secrets --v=8 2>&1 | grep -E 'GET|Response Status|Authorization'
I0804 12:03:11.442  round_trippers.go:463] GET https://api.cluster.internal:6443/api/v1/namespaces/payments/secrets?limit=500
I0804 12:03:11.442  round_trippers.go:469] Request Headers:
I0804 12:03:11.442  round_trippers.go:473]     Authorization: Bearer <masked>
I0804 12:03:11.489  round_trippers.go:574] Response Status: 403 Forbidden in 46 milliseconds
```

Then correlate against the audit log:

```yaml
# /etc/kubernetes/audit-policy.yaml — identity-focused policy
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Never log token contents, but always record that a token was requested.
  - level: Metadata
    resources:
      - group: ""
        resources: ["serviceaccounts/token"]

  # Every authentication failure and anonymous access.
  - level: Metadata
    users: ["system:anonymous"]

  # Every RBAC mutation, with the full object — this is your change history.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Impersonation and CSR approval.
  - level: RequestResponse
    resources:
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests", "certificatesigningrequests/approval"]

  # Secret access: metadata only, never the payload.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Node identities are chatty; keep them out of the high-value log.
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]

  - level: None
    nonResourceURLs: ["/healthz*", "/livez*", "/readyz*", "/version", "/metrics"]

  # Default: metadata for everything else.
  - level: Metadata
```

```bash
$ sudo jq -c 'select(.responseStatus.code == 403)
              | {t: .requestReceivedTimestamp,
                 user: .user.username,
                 groups: .user.groups,
                 verb: .verb,
                 uri: .requestURI,
                 reason: .annotations["authorization.k8s.io/reason"]}' \
     /var/log/kubernetes/audit.log | tail -3
{"t":"2026-08-04T12:03:11.470Z","user":"system:serviceaccount:payments:deploy-bot","groups":["system:serviceaccounts","system:serviceaccounts:payments","system:authenticated"],"verb":"list","uri":"/api/v1/namespaces/payments/secrets?limit=500","reason":"RBAC: no rules matched"}

# Which decision path allowed a sensitive call?
$ sudo jq -r 'select(.objectRef.resource=="serviceaccounts" and .objectRef.subresource=="token")
              | [.requestReceivedTimestamp, .user.username, .objectRef.namespace + "/" + .objectRef.name] | @tsv' \
     /var/log/kubernetes/audit.log | tail -5
2026-08-04T11:58:02.113Z  system:serviceaccount:kube-system:token-issuer  payments/api
2026-08-04T12:01:44.902Z  oidc:alice@example.com                          payments/deploy-bot
```

### 5.6 Failure catalogue

| Symptom | Likely cause | Diagnostic command |
|---|---|---|
| `Unauthorized` (401), not 403 | Token expired, or `--anonymous-auth=false` and no credential sent | `cut -d. -f2 <token> \| base64 -d \| jq .exp` |
| Pod works for ~1 h then 401s | App reads the token once at startup; must re-read the file | `kubectl exec -- stat -c %y /var/run/secrets/.../token` |
| `Forbidden` only for a specific SA | `RoleBinding` in the wrong namespace, or `subjects[].namespace` missing | `kubectl -n <ns> get rolebinding <rb> -o yaml` |
| Everything works — even after removing RBAC | An extra ClusterRoleBinding to `system:authenticated`, or `--authorization-mode=AlwaysAllow` | `kubectl get clusterrolebindings -o json \| jq '.items[] \| select(.subjects[]?.name=="system:authenticated")'` |
| `aws sts get-caller-identity` returns the **node** role | Webhook did not inject; SA annotation typo or pod predates the annotation | `kubectl get pod -o jsonpath='{.spec.volumes}'` — look for `aws-iam-token` |
| `AccessDenied ... not authorized to perform: sts:AssumeRoleWithWebIdentity` | Trust policy `sub` or `aud` mismatch | Decode the projected token; compare `sub`/`aud` byte-for-byte |
| Pod can still reach IMDS | `hostNetwork: true`, or CNI ignores `ipBlock` | Run the §5.3 probe; check `.spec.hostNetwork` |
| `kubectl auth can-i` says `yes` but the call 403s | An authorization webhook denies after RBAC allows | Check `authorization.k8s.io/decision` annotation in audit log |
| kubelet 403s on Secrets it needs | Node authorizer graph not updated (pod not yet bound) | `kubectl get pod -o wide` — confirm `nodeName` |
| `attempt to grant extra privileges` on `kubectl apply -f rbac.yaml` | Escalation prevention: you cannot grant what you lack | Grant yourself the perms first, or use a bootstrap identity |
| New namespace's workloads silently get a token | `default` SA there still has `automountServiceAccountToken: true` | Enforce via a policy engine on namespace creation |

---

## 6. Trade-offs to state out loud

| Decision | Choose A when | Choose B when | Cost of getting it wrong |
|---|---|---|---|
| **Automount off by default vs. per-workload** | Off cluster-wide (`default` SA patched in every namespace) — new workloads fail closed | Per-workload — fewer breakages during migration | Off-by-default breaks in-cluster clients that were silently relying on the ambient token; on-by-default leaves step 2 of the escalation chain open |
| **Namespaced `Role` vs. `ClusterRole` + `RoleBinding`** | `Role` — the permission is genuinely namespace-specific | `ClusterRole` reused via `RoleBinding` — same permission set in many namespaces, one object to audit | Many near-identical Roles drift; one ClusterRole accidentally bound with a `ClusterRoleBinding` becomes cluster-wide |
| **`resourceNames` vs. broad resource grants** | Small, stable, named set (ConfigMaps, Services) | Set is dynamic or created by the same identity | `resourceNames` does not work with `list`/`watch`/`deletecollection` — a Role that only names resources cannot list them, which surprises controllers |
| **Impersonation (`--as`) for support vs. dedicated support identity** | Impersonation — every action is attributed to the real human in the audit log | Dedicated identity — the impersonate verb itself is too dangerous to grant | `impersonate` on `groups` is a path to `system:masters`; restrict with `resourceNames` on the `groups` resource |
| **IRSA/Workload Identity vs. secrets with static cloud keys** | Federation — no material at rest, automatic rotation | Static keys — only when the platform has no OIDC path | Static keys in Secrets are readable by anyone with `get secrets` and never expire |
| **Blocking IMDS at the CNI vs. at the cloud** | Cloud (hop limit) — authoritative, cannot be bypassed by `hostNetwork` | CNI — works on-prem and for non-AWS metadata services | CNI-only leaves `hostNetwork` pods and privileged DaemonSets with full node credentials |
| **`sudo` allowlist vs. no interactive access at all** | Allowlist — nodes are pets, humans must debug | No access — immutable/ephemeral nodes, debug by replacement | An allowlist with one shell-escape binary is equivalent to full root; auditing it is ongoing work |

---

## 7. Fast checklist

```bash
# --- Host -------------------------------------------------------------------
awk -F: '$3>=1000 && $3!=65534 {print $1,$7}' /etc/passwd     # interactive humans
sudo grep -rE 'NOPASSWD:\s*ALL' /etc/sudoers /etc/sudoers.d/  # blanket sudo
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication'
sudo find / -xdev -perm -4000 -type f 2>/dev/null             # SUID
sudo getcap -r / 2>/dev/null                                  # file capabilities
systemd-analyze security --no-pager | head -20                # worst units

# --- Cluster identity -------------------------------------------------------
kubectl auth whoami
kubectl auth can-i --list -n <ns> --as=system:serviceaccount:<ns>:<sa>
kubectl get sa -A -o json | jq -r '.items[] | select((.automountServiceAccountToken // true)==true) | "\(.metadata.namespace)/\(.metadata.name)"'
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token
kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'

# --- Node identity ----------------------------------------------------------
grep -E 'anonymous|authorization|readOnlyPort' /var/lib/kubelet/config.yaml
grep -- '--enable-admission-plugins' /etc/kubernetes/manifests/kube-apiserver.yaml
curl -sk https://127.0.0.1:10250/pods | head -1     # expect: Unauthorized

# --- Cloud boundary ---------------------------------------------------------
kubectl run imds --rm -it --restart=Never --image=curlimages/curl:8.9.1 -- \
  curl -s --max-time 3 http://169.254.169.254/latest/meta-data/    # expect: timeout
```

---

## 8. Referencias

**Kubernetes — official documentation**
- Authenticating — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Authorization overview and modes — https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Node Authorization — https://kubernetes.io/docs/reference/access-authn-authz/node/
- Admission Controllers Reference (NodeRestriction, ServiceAccount, PodSecurity) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Configure Service Accounts for Pods — https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- ServiceAccount token volume projection — https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection
- TokenRequest API reference — https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-request-v1/
- SelfSubjectReview / `kubectl auth whoami` — https://kubernetes.io/docs/reference/access-authn-authz/authentication/#self-subject-review
- Structured Authorization Configuration — https://kubernetes.io/docs/reference/access-authn-authz/authorization/#configuring-the-api-server-using-an-authorization-config-file
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubelet authentication/authorization — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubelet configuration (v1beta1) reference — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Certificate Signing Requests — https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/
- Controlling Access to the Kubernetes API — https://kubernetes.io/docs/concepts/security/controlling-access/

**Exam and curriculum**
- CKS Curriculum v1.34 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- CKS certification page — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/

**Benchmarks and hardening guides**
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- NSA/CISA Kubernetes Hardening Guide — https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- kube-bench — https://github.com/aquasecurity/kube-bench

**Host OS**
- `sudoers(5)` — https://www.sudo.ws/docs/man/sudoers.man/
- `sshd_config(5)` — https://man.openbsd.org/sshd_config
- `capabilities(7)` — https://man7.org/linux/man-pages/man7/capabilities.7.html
- `systemd.exec(5)` sandboxing directives — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `auditctl(8)` / audit rules — https://man7.org/linux/man-pages/man8/auditctl.8.html
- `pam_faillock(8)` — https://man7.org/linux/man-pages/man8/pam_faillock.8.html

**Cloud provider workload identity**
- AWS — IAM roles for service accounts (IRSA) — https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- AWS — EKS Pod Identity — https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- AWS — Instance Metadata Service v2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- AWS — Restrict access to the instance profile assigned to the worker node — https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
- Google Cloud — Workload Identity Federation for GKE — https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
- Google Cloud — Protecting cluster metadata — https://cloud.google.com/kubernetes-engine/docs/how-to/protecting-cluster-metadata
- Microsoft Azure — Workload Identity for AKS — https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview