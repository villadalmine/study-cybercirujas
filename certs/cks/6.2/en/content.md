# CKS 6.2 — Detect Threats Within Physical Infrastructure, Apps, Networks, Data, Users and Workloads

> **Domain:** Monitoring, Logging and Runtime Security
> **Curriculum:** CKS v1.34 · **Relative weight:** 4
> **Prerequisites:** 6.1 (behavioural analytics / syscall visibility), 2.x (RBAC, audit), 4.x (seccomp/AppArmor)

---

## 1. Motivation: the architectural problem detection actually solves

Every control you built in domains 1–5 is a **precondition**, not a guarantee. Admission controllers reject bad manifests at `t=0`; image scanners assert facts about a layer at build time; NetworkPolicies constrain a topology. None of them observes what the process *actually did* at `t=+3h` when a legitimate, signed, non-privileged, PSA-`restricted` container parsed a hostile PDF and spawned `/bin/sh`.

The production failure mode is specific and repeatable:

```
Build-time posture:  image scanned clean          → CVE-2026-XXXX published 4 days later
Admission posture:   runAsNonRoot, no privileges  → CAP_NET_BIND_SERVICE not needed for reverse shell
Network posture:     NetworkPolicy egress to      → attacker exfiltrates over the *allowed* DNS path
                     10.0.0.0/8 + 443/tcp             and the *allowed* 443 to a CDN-fronted C2
RBAC posture:        SA can only get configmaps   → the SA token is stolen and replayed from a
                                                     laptop in another AS; RBAC says "authorised"
```

Every one of those is a **policy-compliant compromise**. Prevention is a filter over *declared intent*; detection is a filter over *observed behaviour*. You need both, and the CKS exam tests the second one because it is the layer most teams skip.

The architectural constraint that makes this hard in Kubernetes specifically:

| Constraint | Consequence for detection design |
|---|---|
| Containers share one kernel | A single node-level sensor sees *all* tenants — good for coverage, catastrophic for blast radius if the sensor itself is compromised (it runs privileged). |
| Pods are ephemeral (p50 lifetime minutes) | Post-hoc forensics on the pod is usually impossible. Telemetry must be **streamed off-node** before the pod dies. |
| Identity is layered (node → SA → user → workload) | An event without namespace/pod/image enrichment is nearly useless. Raw syscall streams must be joined against CRI + API server metadata *at capture time*. |
| The control plane is an API, not a shell | 80 % of "user" threat activity is an authenticated HTTPS request. Only the **API server audit log** sees it; no node sensor does. |
| Nodes are cattle, images are pinned | Node firmware/boot integrity is invisible to Kubernetes entirely. It requires TPM/IMA/Secure Boot telemetry from below the OS. |

### The detection contract

Design every detection control against four measurable properties, and write them into the SLO:

| Property | Definition | Realistic production target |
|---|---|---|
| **Coverage** | Fraction of the relevant ATT&CK techniques that produce at least one signal | ≥ 70 % of ATT&CK for Containers |
| **Fidelity** | True positives ÷ total alerts for the tuned rule set | ≥ 0.6 for `Critical`+ |
| **Latency (MTTD)** | Event → analyst-visible alert | < 60 s node-local, < 5 min SIEM |
| **Integrity** | Can the adversary erase or forge the signal? | Append-only, off-node within 10 s |

A rule that fires with 5 % precision is *worse than nothing*: it trains the on-call to `Ack` reflexively. Tune ruthlessly.

---

## 2. Threat model: the six detection planes

The curriculum item names six surfaces. They are not arbitrary — each maps to a distinct **signal source**, and no source can substitute for another.

```
                        ┌─────────────────────────────────────────────┐
   USERS ───────────────►  kube-apiserver audit log  (HTTP/API plane) │
   (kubectl, CI, SA)    │  → who did what, to which object, from where│
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   WORKLOADS / APPS ────►  syscall telemetry  (Falco / Tetragon /     │
   (exec, file, proc)   │  Tracee — kmod or eBPF)                     │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   NETWORK ─────────────►  flow + DNS telemetry (Hubble / eBPF socket │
   (L3/L4/L7, DNS)      │  events / NetworkPolicy denies)             │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   DATA ────────────────►  file-open telemetry + audit on Secrets     │
   (secrets, PV, etcd)  │  (Falco fd.name / Tetragon security_file_*) │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   OS / KERNEL ─────────►  auditd, seccomp SCMP_ACT_LOG, AppArmor     │
   (node processes)     │  complain-mode, kernel taint                │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   PHYSICAL INFRA ──────►  Secure Boot, TPM PCRs, IMA measurement log,│
   (firmware, disk, BMC)│  FIM (AIDE), BMC/IPMI logs                  │
                        └─────────────────────────────────────────────┘
```

### 2.1 Mapping to MITRE ATT&CK for Containers

This is the coverage matrix you should be able to reproduce from memory; it drives which rules you write.

| ATT&CK ID | Technique | Best plane | Concrete signal |
|---|---|---|---|
| T1610 | Deploy Container | Users (audit) | `create` on `pods`, `privileged:true`, `hostPID` |
| T1611 | Escape to Host | Workloads | `nsenter`, `/proc/*/root` open, `unshare`, `mount` syscall in container |
| T1613 | Container & Resource Discovery | Users + Workloads | burst of `list` on `pods` across namespaces; `crictl`/`docker` in container |
| T1552.001 | Credentials in Files | Data | open of `/var/run/secrets/kubernetes.io/serviceaccount/token` by non-app proc |
| T1552.007 | Container API | Network | connect to `10.96.0.1:443` or `unix:///run/containerd/...` |
| T1078 | Valid Accounts | Users | SA token used from a `sourceIP` outside the cluster CIDR |
| T1525 | Implant Internal Image | Supply chain + Users | `create` on `pods` with an unsigned digest |
| T1496 | Resource Hijacking | Workloads + Network | `xmrig`-class process, stratum DNS lookups, sustained CPU |
| T1070.004 | Indicator Removal (file deletion) | Workloads | `unlink` of `/var/log/*` inside container |
| T1543 | Create/Modify System Process | OS | write to `/etc/systemd/system`, `/etc/cron.d` |
| T1078.001 | Default Accounts | Users | `system:anonymous` / `system:unauthenticated` in audit |

---

## 3. Plane: physical infrastructure and node integrity

Kubernetes has **zero** visibility here. If the firmware lies, every layer above it lies. On bare-metal clusters (and on the CKS "worker node" mental model) you assert integrity with three independent mechanisms.

### 3.1 Verify the boot chain

```bash
$ mokutil --sb-state
SecureBoot enabled

$ sudo dmesg | grep -iE 'secure boot|lockdown'
[    0.000000] secureboot: Secure boot enabled
[    0.000000] Kernel is locked down from EFI Secure Boot mode; see man kernel_lockdown.7

$ sudo tpm2_pcrread sha256:0,1,4,7,10
  sha256:
    0 : 0x3D458CFE55CC03EA1F443F1562BEEC8DF51C75E14A9FCF9A7234A13F198E7969
    1 : 0xE6E1B3A5C0F1A0B0C4A2B7F0C1D2E3F40506A7B8C9DAEBFC0D1E2F3041526374
    4 : 0x9B2D6C3A1F4E5D8C7B0A9E8D7C6B5A4938271605F4E3D2C1B0A99887766554433
    7 : 0x65CAF2C4B1E9A0D3F5768899AABBCCDDEEFF00112233445566778899AABBCCDD
   10 : 0x0A1B2C3D4E5F60718293A4B5C6D7E8F9A0B1C2D3E4F50617

# PCR 0/7 pin firmware + Secure Boot policy. A change here between reboots is a
# firmware/bootloader event, not a Kubernetes event. Alert on it.
```

### 3.2 Kernel-level file measurement (IMA)

IMA (Integrity Measurement Architecture) extends PCR 10 with a hash of every executed binary. It is the only mechanism that detects a **replaced kubelet binary** before it runs.

Boot parameters (`/etc/default/grub` → `GRUB_CMDLINE_LINUX`):

```
ima=on ima_policy=tcb ima_appraise=log ima_template=ima-ng ima_hash=sha256 lsm=integrity,apparmor
```

```bash
$ sudo head -4 /sys/kernel/security/ima/ascii_runtime_measurements
10 8b1f2c9d0a7e5f3b41c60d92aa8f4e77b3c5d901 ima-ng sha256:3f2a55c1ce7f6d0a9b8e4c2d1f0a9b8e7c6d5f4a3b2c1d0e9f8a7b6c5d4e3f2a1 boot_aggregate
10 c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7 ima-ng sha256:9a8b7c6d5e4f30211f2e3d4c5b6a798877665544332211ffeeddccbbaa998877 /usr/lib/systemd/systemd
10 1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d ima-ng sha256:0011223344556677889900aabbccddeeff112233445566778899aabbccddeeff /usr/bin/containerd
10 f0e1d2c3b4a5968778695a4b3c2d1e0f9a8b7c6d ima-ng sha256:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899 /usr/bin/kubelet

# Ship this list off-node. Diff it against a golden manifest per node image version.
$ sudo awk '{print $5, $6}' /sys/kernel/security/ima/ascii_runtime_measurements \
    | sort -u > /var/lib/node-attest/measurements.$(uname -r).txt
```

### 3.3 File Integrity Monitoring on the control-plane surface

The five directories that matter on any Kubernetes node:

```
/etc/kubernetes/manifests/   ← static pod injection = instant cluster-admin
/etc/kubernetes/pki/         ← CA keys = forge any identity
/var/lib/kubelet/            ← kubelet config, seccomp profiles, SA token cache
/etc/containerd/ or /etc/crio/ ← runtime config, insecure registries, runtime class
/usr/bin/{kubelet,kubectl,containerd,runc}  ← binary replacement
```

**`/etc/aide/aide.conf.d/99-kubernetes.conf`** (complete):

```
# AIDE rules for Kubernetes node integrity.
# Rule atoms: p=perms u=uid g=gid s=size m=mtime c=ctime i=inode
#             sha256=content hash  ftype=file type  selinux/xattrs

K8S_STRICT   = p+u+g+s+m+c+i+ftype+sha256+xattrs
K8S_CONTENT  = p+u+g+ftype+sha256
K8S_GROWING  = p+u+g+ftype+S           # S = allow size to grow only (logs)

# --- Control plane, the highest-value target -------------------------------
/etc/kubernetes/manifests        K8S_STRICT
/etc/kubernetes/pki              K8S_STRICT
/etc/kubernetes/admin.conf       K8S_STRICT
/etc/kubernetes/kubelet.conf     K8S_STRICT

# --- Node runtime ----------------------------------------------------------
/var/lib/kubelet/config.yaml     K8S_STRICT
/var/lib/kubelet/seccomp         K8S_CONTENT
/etc/containerd/config.toml      K8S_STRICT
/etc/crictl.yaml                 K8S_STRICT

# --- Binaries --------------------------------------------------------------
/usr/bin/kubelet                 K8S_STRICT
/usr/bin/kubectl                 K8S_STRICT
/usr/bin/containerd              K8S_STRICT
/usr/bin/containerd-shim-runc-v2 K8S_STRICT
/usr/bin/runc                    K8S_STRICT

# --- Host persistence vectors ---------------------------------------------
/etc/cron.d                      K8S_STRICT
/etc/cron.daily                  K8S_STRICT
/etc/systemd/system              K8S_STRICT
/etc/ld.so.preload               K8S_STRICT
/root/.ssh                       K8S_STRICT
/etc/sudoers.d                   K8S_STRICT

# --- Explicit exclusions: high-churn paths that would drown the report -----
!/var/lib/kubelet/pods
!/var/lib/kubelet/plugins
!/var/lib/kubelet/device-plugins
!/var/lib/containerd
```

Systemd unit + timer (complete, drop in `/etc/systemd/system/`):

```ini
# aide-check.service
[Unit]
Description=AIDE integrity check for Kubernetes node surface
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
# Exit 0=clean, 1=new files, 2=removed, 4=changed (bitmask, can combine)
ExecStart=/usr/bin/aide --config=/etc/aide/aide.conf --check
SuccessExitStatus=0
StandardOutput=journal
StandardError=journal
```

```ini
# aide-check.timer
[Unit]
Description=Run AIDE integrity check every 30 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=30min
RandomizedDelaySec=180
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
$ sudo aide --config=/etc/aide/aide.conf --init
Start timestamp: 2026-08-05 09:14:02 +0000 (AIDE 0.18.6)
AIDE initialized database at /var/lib/aide/aide.db.new.gz
Number of entries:      1847

$ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
$ sudo systemctl enable --now aide-check.timer
Created symlink /etc/systemd/system/timers.target.wants/aide-check.timer → /etc/systemd/system/aide-check.timer

# Simulate the attack CKS cares about: static pod injection
$ sudo cp /tmp/evil-daemon.yaml /etc/kubernetes/manifests/kube-proxy-metrics.yaml

$ sudo aide --config=/etc/aide/aide.conf --check
Start timestamp: 2026-08-05 09:47:31 +0000 (AIDE 0.18.6)
AIDE found differences between database and filesystem!!

Summary:
  Total number of entries:      1848
  Added entries:                1
  Removed entries:              0
  Changed entries:              1

---------------------------------------------------
Added entries:
---------------------------------------------------
f+++++++++++++++++: /etc/kubernetes/manifests/kube-proxy-metrics.yaml

---------------------------------------------------
Changed entries:
---------------------------------------------------
d =....  mc.. . : /etc/kubernetes/manifests

---------------------------------------------------
Detailed information about changes:
---------------------------------------------------
Directory: /etc/kubernetes/manifests
  Mtime    : 2026-08-04 11:02:19 +0000        | 2026-08-05 09:47:12 +0000
  Ctime    : 2026-08-04 11:02:19 +0000        | 2026-08-05 09:47:12 +0000
```

> **Trade-off note.** AIDE is a *periodic* control: MTTD equals half the timer interval on average. For `/etc/kubernetes/manifests` that is too slow — a static pod runs within ~20 s of the file landing. Pair AIDE (integrity baseline, node-wide) with Falco/`fanotify` (event-driven, sub-second) on the same paths. Section 5 gives the Falco rule.

### 3.4 auditd: the kernel's own tamper-evident log

auditd survives when the container runtime does not, and it records the **loginuid** — the original interactive user behind a `sudo` chain, which no container sensor can recover.

**`/etc/audit/rules.d/50-kubernetes.rules`** (complete):

```
## Delete all existing rules and set a large backlog before loading ours.
-D
-b 32768
-f 1
--backlog_wait_time 60000

## ---- Immutable, high-value control-plane material -----------------------
-w /etc/kubernetes/pki/           -p wa   -k k8s_pki
-w /etc/kubernetes/manifests/     -p wa   -k k8s_static_pods
-w /etc/kubernetes/admin.conf     -p rwa  -k k8s_admin_kubeconfig
-w /var/lib/kubelet/config.yaml   -p wa   -k kubelet_config
-w /var/lib/kubelet/pki/          -p wa   -k kubelet_pki
-w /etc/containerd/config.toml    -p wa   -k runtime_config

## ---- Runtime binaries: record every invocation --------------------------
-w /usr/bin/kubectl               -p x    -k k8s_exec
-w /usr/bin/crictl                -p x    -k runtime_exec
-w /usr/bin/runc                  -p x    -k runtime_exec
-w /usr/bin/nsenter               -p x    -k container_escape
-w /usr/bin/unshare               -p x    -k container_escape

## ---- Host persistence & privilege escalation ---------------------------
-w /etc/ld.so.preload             -p wa   -k rootkit_preload
-w /etc/sudoers                   -p wa   -k privesc
-w /etc/sudoers.d/                -p wa   -k privesc
-w /etc/cron.d/                   -p wa   -k persistence
-w /etc/systemd/system/           -p wa   -k persistence
-w /root/.ssh/                    -p wa   -k persistence

## ---- Kernel module loading (rootkit / driver injection) ----------------
-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k module_load
-a always,exit -F arch=b32 -S init_module -S finit_module -S delete_module -k module_load

## ---- Container escape primitives ---------------------------------------
-a always,exit -F arch=b64 -S mount -S umount2 -F auid>=1000 -F auid!=unset -k mount_ops
-a always,exit -F arch=b64 -S setns -k namespace_switch
-a always,exit -F arch=b64 -S ptrace -F a0=0x4 -k ptrace_attach   # PTRACE_ATTACH

## ---- Make the ruleset immutable. Requires a reboot to change. ----------
## Put this LAST. -e 2 is what makes the audit trail trustworthy.
-e 2
```

```bash
$ sudo augenrules --load
$ sudo auditctl -s
enabled 2
failure 1
pid 1121
rate_limit 0
backlog_limit 32768
lost 0
backlog 0
backlog_wait_time 60000
backlog_wait_time_actual 0

# 'enabled 2' == immutable. Confirm the rules loaded:
$ sudo auditctl -l | head -5
-w /etc/kubernetes/pki -p wa -k k8s_pki
-w /etc/kubernetes/manifests -p wa -k k8s_static_pods
-w /etc/kubernetes/admin.conf -p rwa -k k8s_admin_kubeconfig
-w /var/lib/kubelet/config.yaml -p wa -k kubelet_config
-w /var/lib/kubelet/pki -p wa -k kubelet_pki

# Investigate: who read the CA key?
$ sudo ausearch -k k8s_pki -i --start recent
----
type=PROCTITLE msg=audit(08/05/2026 09:52:14.113:2231) : proctitle=cat /etc/kubernetes/pki/ca.key
type=PATH msg=audit(08/05/2026 09:52:14.113:2231) : item=0 name=/etc/kubernetes/pki/ca.key
  inode=262149 dev=fd:00 mode=file,600 ouid=root ogid=root rdev=00:00
  obj=system_u:object_r:cert_t:s0 nametype=NORMAL cap_fp=none cap_fi=none cap_fe=0 cap_fver=0
type=CWD msg=audit(08/05/2026 09:52:14.113:2231) : cwd=/home/deploy
type=SYSCALL msg=audit(08/05/2026 09:52:14.113:2231) : arch=x86_64 syscall=openat
  success=yes exit=3 a0=0xffffff9c a1=0x7ffd3c1a2b40 a2=O_RDONLY a3=0x0 items=1
  ppid=48210 pid=48344 auid=deploy uid=root gid=root euid=root suid=root fsuid=root
  egid=root sgid=root fsgid=root tty=pts0 ses=42 comm=cat exe=/usr/bin/cat
  subj=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023 key=k8s_pki
```

The `auid=deploy ses=42` pair is the forensic gold: `uid=root` because of `sudo`, but the **login UID is immutable** and identifies the human.

```bash
$ sudo aureport -k --summary -i --start today

Key Summary Report
===========================
total  key
===========================
  312  k8s_exec
   47  k8s_pki
   19  runtime_exec
    6  container_escape
    2  module_load
```

---

## 4. Plane: users — the Kubernetes audit log

**Nothing on the node sees `kubectl create clusterrolebinding`.** It is an HTTPS request terminated by the API server. The audit log is the *only* source of truth for the user plane, and it is disabled by default.

### 4.1 Levels and stages: the volume/value trade-off

| Level | Records | Typical size/day (100-node cluster) | Forensic value |
|---|---|---|---|
| `None` | nothing | 0 | — (use to silence noise) |
| `Metadata` | who, when, verb, resource, namespace, response code | ~1.5 GB | Answers *who touched what*. Sufficient for 80 % of investigations. |
| `Request` | + request body | ~12 GB | Shows the manifest that was applied. Required for `create`/`update` on RBAC & Pods. |
| `RequestResponse` | + response body | ~40 GB | Shows secret *values* on `get secrets`. **Almost never appropriate** — it turns the audit log into a secret store. |

| Stage | Emitted when | Use it? |
|---|---|---|
| `RequestReceived` | request hits the handler | **Omit globally.** Doubles volume, adds nothing except detection of requests that never completed. |
| `ResponseStarted` | headers sent — long-running only (`watch`) | Keep for `watch` on Secrets. |
| `ResponseComplete` | response finished | **The one you want.** |
| `Panic` | handler panicked | Always keep; free and rare. |

### 4.2 Production audit policy (complete)

**`/etc/kubernetes/audit/policy.yaml`**

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# Drop the RequestReceived stage globally: it doubles log volume and the
# ResponseComplete record is a strict superset for investigation purposes.
omitStages:
  - "RequestReceived"

# Strip managedFields from every logged body. On a busy cluster this is
# 30-60% of the bytes in a Request-level record and is never useful.
omitManagedFields: true

rules:
  # =========================================================================
  # 1. NOISE SUPPRESSION — must come first; the first matching rule wins.
  # =========================================================================

  # Kubelet and node-problem-detector heartbeats.
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  # Leader-election churn: one write per second, per controller, forever.
  - level: None
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:serviceaccount:kube-system:endpoint-controller"
    verbs: ["get", "update"]
    namespaces: ["kube-system"]
    resources:
      - group: ""
        resources: ["endpoints"]
      - group: "coordination.k8s.io"
        resources: ["leases"]

  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]
    verbs: ["get", "update", "patch"]

  # Unauthenticated health/discovery endpoints — high volume, zero signal.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
      - "/metrics"
      - "/openapi/*"
      - "/apis"
      - "/apis/*"
      - "/api"
      - "/api/*"

  # =========================================================================
  # 2. CREDENTIAL ACCESS — T1552. Metadata ONLY: never log secret bodies.
  # =========================================================================
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
    omitStages:
      - "RequestReceived"

  # =========================================================================
  # 3. INTERACTIVE ACCESS TO WORKLOADS — exec/attach/portforward is the
  #    single highest-fidelity "human in the data plane" signal there is.
  # =========================================================================
  - level: RequestResponse
    resources:
      - group: ""
        resources:
          - "pods/exec"
          - "pods/attach"
          - "pods/portforward"
          - "pods/proxy"
          - "services/proxy"
          - "nodes/proxy"

  # =========================================================================
  # 4. AUTHORISATION CHANGES — privilege escalation ground truth.
  # =========================================================================
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests", "certificatesigningrequests/approval"]
      - group: "admissionregistration.k8s.io"
        resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]
      - group: "policy"
        resources: ["poddisruptionbudgets"]

  # =========================================================================
  # 5. WORKLOAD MUTATION — log the manifest so you can diff what was applied.
  # =========================================================================
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["pods", "persistentvolumes", "persistentvolumeclaims"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets", "replicasets"]
      - group: "batch"
        resources: ["jobs", "cronjobs"]
      - group: "networking.k8s.io"
        resources: ["networkpolicies", "ingresses"]

  # =========================================================================
  # 6. ANYTHING BY AN ANONYMOUS OR UNAUTHENTICATED PRINCIPAL.
  # =========================================================================
  - level: RequestResponse
    userGroups: ["system:unauthenticated"]

  # =========================================================================
  # 7. CATCH-ALL — Metadata for every remaining request.
  # =========================================================================
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

### 4.3 Wiring it into the API server

Edit the static pod manifest. **Every path referenced by a flag must also be a `volumeMount`** — this is the #1 cause of a CrashLooping API server in the exam.

**`/etc/kubernetes/manifests/kube-apiserver.yaml`** (relevant fragments, complete):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    component: kube-apiserver
    tier: control-plane
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.0
      command:
        - kube-apiserver
        - --advertise-address=10.0.1.10
        - --allow-privileged=true
        - --authorization-mode=Node,RBAC
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --enable-admission-plugins=NodeRestriction
        - --etcd-servers=https://127.0.0.1:2379
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        - --service-cluster-ip-range=10.96.0.0/12
        # ---------- AUDIT ----------------------------------------------
        - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-format=json
        - --audit-log-maxage=30          # days of retention
        - --audit-log-maxbackup=10       # rotated files kept
        - --audit-log-maxsize=500        # MB before rotation
        - --audit-log-compress=true
        # Webhook backend: ship off-node so a node compromise cannot erase it.
        - --audit-webhook-config-file=/etc/kubernetes/audit/webhook.yaml
        - --audit-webhook-mode=batch
        - --audit-webhook-batch-max-size=400
        - --audit-webhook-batch-max-wait=5s
        - --audit-webhook-initial-backoff=10s
        - --audit-webhook-truncate-enabled=true
        - --audit-webhook-truncate-max-event-size=102400
        # ---------------------------------------------------------------
      volumeMounts:
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        - name: audit-logs
          mountPath: /var/log/kubernetes/audit
          readOnly: false          # MUST be writable
      livenessProbe:
        httpGet:
          host: 10.0.1.10
          path: /livez
          port: 6443
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 8
  volumes:
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-logs
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

**`/etc/kubernetes/audit/webhook.yaml`** — a standard kubeconfig; `clusters[0].cluster.server` is the collector:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: audit-sink
    cluster:
      server: https://audit-collector.security.svc.cluster.local:8443/v1/audit
      certificate-authority: /etc/kubernetes/pki/ca.crt
contexts:
  - name: audit-sink-context
    context:
      cluster: audit-sink
      user: kube-apiserver-audit
current-context: audit-sink-context
users:
  - name: kube-apiserver-audit
    user:
      client-certificate: /etc/kubernetes/pki/apiserver-audit-client.crt
      client-key: /etc/kubernetes/pki/apiserver-audit-client.key
```

> **Failure mode.** `--audit-webhook-mode=blocking` makes *every API request* wait on the collector. If the collector is in-cluster and the cluster is degraded, you deadlock the control plane. Use `batch` in production; use `blocking-strict` only when a regulator requires that no request proceed unaudited, and then host the collector **outside** the cluster.

### 4.4 Hunting in the audit log

```bash
$ AUDIT=/var/log/kubernetes/audit/audit.log

# --- 1. Every interactive shell into a pod, ever ---------------------------
$ jq -r 'select(.objectRef.subresource=="exec")
         | [.requestReceivedTimestamp, .user.username, .sourceIPs[0],
            .objectRef.namespace + "/" + .objectRef.name,
            (.requestURI | split("?")[1] // "-")]
         | @tsv' "$AUDIT" | column -t -s$'\t'

2026-08-05T09:12:44.881Z  kubernetes-admin  10.0.1.10     kube-system/etcd-cp1        command=sh&container=etcd&stdin=true&tty=true
2026-08-05T10:41:07.220Z  ci-deployer       203.0.113.77  payments/api-6d4f8b9c-2xk4z command=%2Fbin%2Fbash&stdin=true&tty=true

# ci-deployer, a CI service account, opened an interactive TTY from a public
# IP. That is the alert. CI does not need a TTY.

# --- 2. Secret reads by non-system principals ------------------------------
$ jq -r 'select(.objectRef.resource=="secrets")
         | select(.verb=="get" or .verb=="list")
         | select(.user.username | startswith("system:") | not)
         | [.requestReceivedTimestamp, .user.username,
            .objectRef.namespace, (.objectRef.name // "LIST-ALL"),
            .sourceIPs[0], (.annotations["authorization.k8s.io/decision"] // "-")]
         | @tsv' "$AUDIT" | column -t -s$'\t'

2026-08-05T10:44:19.003Z  ci-deployer  payments  LIST-ALL   203.0.113.77  allow
2026-08-05T10:44:19.512Z  ci-deployer  default   LIST-ALL   203.0.113.77  allow
2026-08-05T10:44:20.118Z  ci-deployer  kube-system LIST-ALL 203.0.113.77  allow

# Namespace-walking a LIST on secrets in 1.1 s == T1613 + T1552.007.

# --- 3. RBAC escalation attempts, allowed AND denied ------------------------
$ jq -r 'select(.objectRef.apiGroup=="rbac.authorization.k8s.io")
         | select(.verb=="create" or .verb=="update" or .verb=="patch")
         | [.requestReceivedTimestamp, .user.username, .verb,
            .objectRef.resource, (.objectRef.name // "-"),
            .responseStatus.code,
            (.requestObject.roleRef.name // "-")]
         | @tsv' "$AUDIT" | column -t -s$'\t'

2026-08-05T10:45:02.771Z  ci-deployer  create  clusterrolebindings  ci-escalate  201  cluster-admin

# --- 4. Denied requests grouped by principal: reconnaissance fingerprint ----
$ jq -r 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
         | .user.username' "$AUDIT" | sort | uniq -c | sort -rn | head

    412 system:serviceaccount:payments:api
     97 system:anonymous
     31 system:serviceaccount:default:default

# 412 forbids from one SA in one window = an implant enumerating its own
# permissions (equivalent to `kubectl auth can-i --list`).

# --- 5. Anything anonymous ---------------------------------------------------
$ jq -r 'select(.user.username=="system:anonymous")
         | [.requestReceivedTimestamp,.sourceIPs[0],.verb,.requestURI,
            .responseStatus.code] | @tsv' "$AUDIT" | head -3

2026-08-05T03:11:02.441Z  198.51.100.4  get   /api/v1/namespaces/default/pods   403
2026-08-05T03:11:02.998Z  198.51.100.4  get   /apis/rbac.authorization.k8s.io/v1/clusterroles  403
2026-08-05T03:11:03.512Z  198.51.100.4  post  /apis/authorization.k8s.io/v1/selfsubjectaccessreviews  201

# --- 6. Service-account tokens replayed from outside the cluster CIDR -------
$ jq -r 'select(.user.username | startswith("system:serviceaccount:"))
         | select(.sourceIPs[0] | test("^(10\\.|172\\.1[6-9]\\.|192\\.168\\.)") | not)
         | [.requestReceivedTimestamp,.user.username,.sourceIPs[0],.verb,.requestURI]
         | @tsv' "$AUDIT" | head

2026-08-05T10:41:00.004Z  system:serviceaccount:payments:api  203.0.113.77  get  /api/v1/namespaces/payments/secrets
```

Query 6 is the highest-value single detection in the entire user plane. A projected, bound service-account token is only valid inside the pod; seeing it presented from an external IP means the token was exfiltrated. Bind it to an alert.

---

## 5. Plane: workloads and apps — Falco in depth

### 5.1 Architecture

```
 ┌───────────────────────── userspace ──────────────────────────┐
 │ falco (rule engine)                                          │
 │   ├─ libsinsp   : state machine, fd table, thread table,     │
 │   │               container enrichment via CRI + k8s meta    │
 │   ├─ rule engine: condition eval → priority → output format  │
 │   └─ outputs    : stdout / file / syslog / gRPC / http / program
 └──────────────▲───────────────────────────────────────────────┘
                │ shared ring buffers (per-CPU, mmap'd)
 ┌──────────────┴───────────────── kernel ──────────────────────┐
 │ DRIVER  (exactly one of):                                    │
 │   modern_ebpf : CO-RE BPF, needs CONFIG_DEBUG_INFO_BTF, 5.8+ │
 │   ebpf        : legacy probe (falco-probe.o), 4.14+          │
 │   kmod        : falco.ko kernel module                       │
 │ Hooks: sys_enter / sys_exit tracepoints, sched_process_exit, │
 │        page_fault, signal_deliver                            │
 └──────────────────────────────────────────────────────────────┘
```

### 5.2 Driver comparison — this decision has real operational consequences

| | `modern_ebpf` (CO-RE) | `ebpf` (legacy probe) | `kmod` |
|---|---|---|---|
| Kernel requirement | ≥ 5.8 **and** `CONFIG_DEBUG_INFO_BTF=y` | ≥ 4.14 | any supported |
| Build/download at install | none — compiled into the binary | fetch/compile `falco-probe.o` per kernel | fetch/compile `falco.ko` per kernel |
| Behaviour on kernel upgrade | keeps working | breaks until a new probe is built | breaks until a new module is built |
| Node taint | none | none | `kmod` taints the kernel (`P`/`O`) |
| Crash blast radius | verifier-checked; process-level | verifier-checked; process-level | **kernel panic** |
| Overhead (syscall-heavy pod) | ~2–4 % CPU | ~3–6 % | ~2–5 % |
| Works in GKE COS / Bottlerocket / Talos | yes | partial | usually no |
| Recommended | **default choice** | legacy kernels only | last resort |

```bash
# Decide the driver empirically, not by folklore:
$ ls -l /sys/kernel/btf/vmlinux
-r--r--r--. 1 root root 6291456 Aug  5 08:02 /sys/kernel/btf/vmlinux
# → BTF present ⇒ modern_ebpf is available.

$ uname -r
6.8.0-45-generic

$ grep -E 'CONFIG_(BPF_JIT|DEBUG_INFO_BTF|BPF_LSM)=' /boot/config-$(uname -r)
CONFIG_BPF_JIT=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_BPF_LSM=y
```

### 5.3 `falco.yaml` — the settings that matter

**`/etc/falco/falco.yaml`** (annotated, production values):

```yaml
# ---------------------------------------------------------------------------
# Rule sources, loaded in order. LATER FILES OVERRIDE EARLIER ONES.
# Never edit falco_rules.yaml: it is replaced on upgrade.
# ---------------------------------------------------------------------------
rules_files:
  - /etc/falco/falco_rules.yaml          # shipped, do not edit
  - /etc/falco/falco_rules.local.yaml    # your overrides of shipped rules
  - /etc/falco/rules.d                   # your own rules (directory)

# ---------------------------------------------------------------------------
# Engine / driver
# ---------------------------------------------------------------------------
engine:
  kind: modern_ebpf
  modern_ebpf:
    cpus_for_each_buffer: 2
    buf_size_preset: 4          # 1..10 → 1MB..512MB per buffer set
    drop_failed_exit: true      # discard failed syscalls: big volume cut

# ---------------------------------------------------------------------------
# Output plumbing
# ---------------------------------------------------------------------------
# Minimum priority a rule must have to be evaluated at all.
# Set to 'notice' in production; 'debug' floods the pipeline.
priority: notice

# Buffered output hides events when Falco is killed mid-flush. Turn it OFF.
buffered_outputs: false

# Rate-limit alerts so one runaway loop cannot DoS the collector.
outputs:
  rate: 1000                 # tokens refilled per second
  max_burst: 10000

json_output: true
json_include_output_property: true
json_include_tags_property: true

stdout_output:
  enabled: true

file_output:
  enabled: false
  keep_alive: false
  filename: /var/log/falco/events.log

syslog_output:
  enabled: false

http_output:
  enabled: true
  url: http://falcosidekick.falco.svc.cluster.local:2801/
  user_agent: "falcosecurity/falco"
  insecure: false
  echo: false

grpc:
  enabled: true
  bind_address: "unix:///run/falco/falco.sock"
  threadiness: 0

grpc_output:
  enabled: true

# ---------------------------------------------------------------------------
# Self-monitoring: Falco telling you it is blind. ALERT ON THESE.
# ---------------------------------------------------------------------------
syscall_event_drops:
  threshold: 0.1
  actions:
    - log
    - alert
  rate: 0.03333          # at most 1 drop alert every 30s
  max_burst: 1

metrics:
  enabled: true
  interval: 1h
  output_rule: true
  rules_counters_enabled: true
  resource_utilization_enabled: true
  kernel_event_counters_enabled: true
  libbpf_stats_enabled: true

# ---------------------------------------------------------------------------
# Plugins: container metadata + k8s pod/namespace enrichment.
# Without these, container.* and k8smeta.* fields are empty.
# ---------------------------------------------------------------------------
load_plugins:
  - container
  - k8smeta

plugins:
  - name: container
    library_path: libcontainer.so
    init_config:
      engines:
        cri:
          enabled: true
          sockets:
            - /run/containerd/containerd.sock
            - /run/crio/crio.sock
        docker:
          enabled: false
        podman:
          enabled: false

  - name: k8smeta
    library_path: libk8smeta.so
    init_config:
      collectorPort: 45000
      collectorHostname: k8s-metacollector.falco.svc.cluster.local
      nodeName: "${FALCO_K8S_NODE_NAME}"
```

### 5.4 Rule grammar — the parts CKS tests

```yaml
- rule: <unique name>            # duplicate name ⇒ later definition wins
  desc: <human description>
  condition: <sysdig filter expression>
  output: <printf-style with %field tokens>
  priority: <EMERGENCY|ALERT|CRITICAL|ERROR|WARNING|NOTICE|INFORMATIONAL|DEBUG>
  source: syscall                # or k8s_audit, or a plugin's event source
  tags: [container, mitre_execution, T1059]
  enabled: true
```

Supporting constructs:

```yaml
- list: my_binaries
  items: [curl, wget, nc, ncat, socat]

- macro: my_container
  condition: (container.id != host)
```

Operators: `=` `!=` `<` `<=` `>` `>=` `in` `intersects` `pmatch` `glob` `contains` `icontains` `bcontains` `startswith` `endswith` `exists`, combined with `and` `or` `not` and parentheses.

**High-value fields (memorise these):**

| Field | Meaning |
|---|---|
| `evt.type` | syscall name (`execve`, `open`, `openat`, `connect`, `setns`) |
| `evt.dir` | `>` = enter, `<` = exit. Almost all rules use `evt.dir=<`. |
| `evt.time`, `evt.num` | timestamp / monotonic event number |
| `proc.name`, `proc.pname` | process / parent process name |
| `proc.cmdline`, `proc.exeline` | full command line |
| `proc.pid`, `proc.ppid`, `proc.tty` | identifiers; `proc.tty != 0` ⇒ interactive |
| `proc.aname[N]` | ancestor name at depth N — defeats `sh -c "sh -c ..."` |
| `fd.name` | file path or `ip:port` tuple |
| `fd.sip`, `fd.sport`, `fd.cip` | server IP/port, client IP |
| `fd.directory`, `fd.filename` | split path |
| `user.name`, `user.uid`, `user.loginuid` | identity; `loginuid=-1` ⇒ non-interactive |
| `container.id`, `container.name` | runtime identity |
| `container.image.repository`, `.tag`, `.digest` | image identity |
| `container.privileged` | boolean |
| `k8smeta.ns.name`, `k8smeta.pod.name`, `k8smeta.pod.label[x]` | Kubernetes identity (needs `k8smeta` plugin) |

Useful shipped macros you should *reuse* rather than reinvent: `container`, `spawned_process`, `open_write`, `open_read`, `outbound`, `inbound`, `never_true`, `proc_name_exists`; and shipped lists `shell_binaries`, `known_binaries`, `sensitive_file_names`, `bin_dir`, `package_mgmt_binaries`.

### 5.5 A complete custom ruleset

**`/etc/falco/rules.d/cks-threat-detection.yaml`**

```yaml
# =============================================================================
# CKS 6.2 — cross-plane threat detection ruleset
# Load AFTER falco_rules.yaml so overrides take effect.
# =============================================================================
- required_engine_version: 0.31.0

# -----------------------------------------------------------------------------
# Lists
# -----------------------------------------------------------------------------
- list: cks_shell_binaries
  items: [ash, bash, csh, ksh, sh, tcsh, zsh, dash, busybox]

- list: cks_pkg_mgmt_binaries
  items: [apt, apt-get, aptitude, dpkg, yum, dnf, rpm, apk, microdnf,
          pacman, zypper, pip, pip3, npm, gem, easy_install]

- list: cks_recon_binaries
  items: [nmap, masscan, zmap, nc, ncat, netcat, socat, tcpdump, tshark,
          hping3, arp-scan, dig, nslookup, host, whois, ss, netstat,
          ifconfig, ip, route, arp]

- list: cks_escape_binaries
  items: [nsenter, unshare, setns, chroot, pivot_root, docker, crictl,
          ctr, runc, kubectl, podman, nerdctl]

- list: cks_crypto_miner_binaries
  items: [xmrig, minerd, cpuminer, cgminer, bfgminer, ethminer, nbminer,
          t-rex, phoenixminer, xmr-stak, kdevtmpfsi, kinsing]

- list: cks_sensitive_host_paths
  items: ["/etc/shadow", "/etc/sudoers", "/etc/ssh/ssh_host_rsa_key",
          "/root/.ssh/authorized_keys", "/etc/kubernetes/pki",
          "/etc/kubernetes/admin.conf", "/var/lib/kubelet/pki",
          "/etc/ld.so.preload"]

- list: cks_trusted_image_registries
  items: ["registry.internal.corp", "registry.k8s.io", "ghcr.io/mycorp"]

- list: cks_system_namespaces
  items: [kube-system, kube-public, kube-node-lease, falco,
          monitoring, cilium-secrets]

# -----------------------------------------------------------------------------
# Macros
# -----------------------------------------------------------------------------
- macro: in_container
  condition: (container.id != host)

- macro: proc_started
  condition: (evt.type in (execve, execveat) and evt.dir=<)

- macro: file_opened_write
  condition: >
    (evt.type in (open, openat, openat2, creat) and evt.is_open_write=true
     and fd.typechar='f' and fd.num>=0)

- macro: file_opened_read
  condition: >
    (evt.type in (open, openat, openat2) and evt.is_open_read=true
     and fd.typechar='f' and fd.num>=0)

- macro: outbound_conn
  condition: >
    ((evt.type=connect and evt.dir=< and fd.l4proto in (tcp, udp))
     and (fd.typechar=4 or fd.typechar=6)
     and not fd.snet in ("127.0.0.0/8"))

- macro: cluster_internal_dest
  condition: >
    (fd.sip.name contains "cluster.local"
     or fd.snet in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                    "100.64.0.0/10", "169.254.0.0/16"))

- macro: sa_token_path
  condition: (fd.name startswith "/var/run/secrets/kubernetes.io/serviceaccount")

# =============================================================================
# WORKLOAD PLANE
# =============================================================================

- rule: CKS Terminal Shell Spawned In Container
  desc: >
    An interactive shell was started inside a container. In an immutable,
    CI-deployed workload this never happens legitimately; it is either an
    operator bypassing change control or an attacker after RCE (T1059).
  condition: >
    proc_started
    and in_container
    and proc.name in (cks_shell_binaries)
    and (proc.tty != 0 or container.image.repository != "")
    and not proc.pname in (cks_shell_binaries)
    and not k8smeta.ns.name in (cks_system_namespaces)
  output: >
    Interactive shell spawned in container
    (evt_time=%evt.time user=%user.name uid=%user.uid loginuid=%user.loginuid
     shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline tty=%proc.tty
     container_id=%container.id container_name=%container.name
     image=%container.image.repository:%container.image.tag
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]
  source: syscall

- rule: CKS Package Management Executed In Container
  desc: >
    Installing software at runtime breaks image immutability and is the
    canonical persistence/tooling step after initial access (T1105).
  condition: >
    proc_started
    and in_container
    and proc.name in (cks_pkg_mgmt_binaries)
  output: >
    Package manager launched in container
    (evt_time=%evt.time container_id=%container.id user=%user.name
     command=%proc.cmdline image=%container.image.repository
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: ERROR
  tags: [container, mitre_command_and_control, T1105]
  source: syscall

- rule: CKS Container Escape Tooling Executed
  desc: >
    Namespace-manipulation or runtime-control binaries executed inside a
    container. This is T1611 (Escape to Host) in its most direct form.
  condition: >
    proc_started
    and in_container
    and proc.name in (cks_escape_binaries)
  output: >
    Container escape tooling executed
    (evt_time=%evt.time proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname user=%user.name uid=%user.uid
     container_id=%container.id image=%container.image.repository
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: CRITICAL
  tags: [container, mitre_privilege_escalation, T1611]
  source: syscall

- rule: CKS Host Namespace Entered From Container
  desc: >
    setns() from inside a container onto a host namespace fd, or a read of
    another process's root via /proc/<pid>/root — a namespace break-out.
  condition: >
    in_container
    and ((evt.type=setns and evt.dir=<)
         or (file_opened_read and fd.name glob "/proc/*/root/*"))
  output: >
    Namespace escape attempt from container
    (evt_time=%evt.time evt=%evt.type target=%fd.name proc=%proc.name
     cmdline=%proc.cmdline container_id=%container.id
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: CRITICAL
  tags: [container, mitre_privilege_escalation, T1611]
  source: syscall

- rule: CKS Cryptominer Process Started
  desc: Known cryptomining binary executed anywhere on the node (T1496).
  condition: >
    proc_started
    and (proc.name in (cks_crypto_miner_binaries)
         or proc.cmdline contains "stratum+tcp"
         or proc.cmdline contains "--donate-level"
         or proc.cmdline contains "nicehash")
  output: >
    Cryptomining activity detected
    (evt_time=%evt.time proc=%proc.name cmdline=%proc.cmdline
     container_id=%container.id image=%container.image.repository
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name user=%user.name)
  priority: CRITICAL
  tags: [container, mitre_impact, T1496]
  source: syscall

- rule: CKS Untrusted Image Started
  desc: A container whose image does not come from an approved registry.
  condition: >
    proc_started
    and in_container
    and proc.vpid=1
    and not container.image.repository pmatch (cks_trusted_image_registries)
  output: >
    Container started from untrusted registry
    (evt_time=%evt.time image=%container.image.repository:%container.image.tag
     digest=%container.image.digest container_id=%container.id
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: WARNING
  tags: [container, supply_chain, T1525]
  source: syscall

# =============================================================================
# DATA PLANE
# =============================================================================

- rule: CKS Service Account Token Read By Non App Process
  desc: >
    The projected SA token was read by a process other than the workload's
    own entrypoint. Precursor to token theft and off-cluster replay (T1552.001).
  condition: >
    file_opened_read
    and in_container
    and sa_token_path
    and not proc.name in (java, python3, python, node, ruby, dotnet, app,
                          kubectl, kube-proxy, coredns, cilium-agent)
  output: >
    Service account token read by unexpected process
    (evt_time=%evt.time file=%fd.name proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname user=%user.name container_id=%container.id
     image=%container.image.repository ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: CRITICAL
  tags: [container, secrets, mitre_credential_access, T1552.001]
  source: syscall

- rule: CKS Sensitive Host File Accessed From Container
  desc: >
    A container touched host credential material. Only reachable through a
    hostPath mount or an escape; either way it is an incident.
  condition: >
    (file_opened_read or file_opened_write)
    and in_container
    and fd.name pmatch (cks_sensitive_host_paths)
  output: >
    Sensitive host file accessed from container
    (evt_time=%evt.time file=%fd.name mode=%evt.arg.flags proc=%proc.name
     cmdline=%proc.cmdline container_id=%container.id
     image=%container.image.repository ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: CRITICAL
  tags: [container, filesystem, mitre_credential_access, T1552.001]
  source: syscall

- rule: CKS Static Pod Manifest Directory Modified
  desc: >
    A write to /etc/kubernetes/manifests. The kubelet starts whatever lands
    there with no admission control, no RBAC, no PSA. Instant node takeover.
  condition: >
    file_opened_write
    and fd.directory startswith "/etc/kubernetes/manifests"
    and not proc.name in (kubeadm, kubelet)
  output: >
    Static pod manifest written outside kubeadm
    (evt_time=%evt.time file=%fd.name proc=%proc.name cmdline=%proc.cmdline
     user=%user.name loginuid=%user.loginuid container_id=%container.id)
  priority: CRITICAL
  tags: [host, k8s, mitre_persistence, T1543]
  source: syscall

- rule: CKS Kubernetes PKI Read
  desc: Any read of cluster CA private keys or the admin kubeconfig.
  condition: >
    file_opened_read
    and (fd.name startswith "/etc/kubernetes/pki"
         or fd.name = "/etc/kubernetes/admin.conf")
    and fd.name endswith ".key" or fd.name = "/etc/kubernetes/admin.conf"
    and not proc.name in (kube-apiserver, kube-controller-manager, etcd,
                          kubelet, kubeadm)
  output: >
    Kubernetes PKI material read by unexpected process
    (evt_time=%evt.time file=%fd.name proc=%proc.name cmdline=%proc.cmdline
     user=%user.name loginuid=%user.loginuid pid=%proc.pid ppid=%proc.ppid)
  priority: CRITICAL
  tags: [host, k8s, mitre_credential_access, T1552.001]
  source: syscall

# =============================================================================
# NETWORK PLANE
# =============================================================================

- rule: CKS Outbound Connection To Non Cluster Destination
  desc: >
    A workload initiated an egress connection outside RFC1918/cluster space.
    With a default-deny NetworkPolicy this should be impossible; if it fires,
    either the policy is missing or the workload found an allowed path (T1071).
  condition: >
    outbound_conn
    and in_container
    and not cluster_internal_dest
    and not fd.sport in (53)
    and not k8smeta.ns.name in (cks_system_namespaces)
  output: >
    Unexpected outbound connection from container
    (evt_time=%evt.time dest=%fd.sip:%fd.sport proto=%fd.l4proto
     proc=%proc.name cmdline=%proc.cmdline container_id=%container.id
     image=%container.image.repository ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: WARNING
  tags: [network, mitre_command_and_control, T1071]
  source: syscall

- rule: CKS Contact To Kubernetes API From Unexpected Workload
  desc: >
    A pod that is not a controller talked to the API server ClusterIP.
    Legitimate for operators; suspicious for a web front end (T1552.007).
  condition: >
    outbound_conn
    and in_container
    and fd.sip = "10.96.0.1"
    and fd.sport = 443
    and not k8smeta.ns.name in (cks_system_namespaces)
    and not k8smeta.pod.label[security.corp/api-client] = "true"
  output: >
    Container contacted Kubernetes API server
    (evt_time=%evt.time dest=%fd.sip:%fd.sport proc=%proc.name
     cmdline=%proc.cmdline container_id=%container.id
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name sa=%k8smeta.pod.label[app])
  priority: NOTICE
  tags: [network, k8s, mitre_discovery, T1552.007]
  source: syscall

- rule: CKS Network Reconnaissance Tooling In Container
  desc: Scanner or packet-capture tooling executed inside a container (T1046).
  condition: >
    proc_started
    and in_container
    and proc.name in (cks_recon_binaries)
    and not k8smeta.ns.name in (cks_system_namespaces)
  output: >
    Network recon tool executed in container
    (evt_time=%evt.time proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname container_id=%container.id
     image=%container.image.repository ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: WARNING
  tags: [network, container, mitre_discovery, T1046]
  source: syscall

# =============================================================================
# NODE / OS PLANE
# =============================================================================

- rule: CKS Kernel Module Loaded
  desc: init_module/finit_module on a running node — rootkit or driver injection.
  condition: >
    (evt.type in (init_module, finit_module) and evt.dir=<)
  output: >
    Kernel module load attempt
    (evt_time=%evt.time proc=%proc.name cmdline=%proc.cmdline
     user=%user.name loginuid=%user.loginuid container_id=%container.id)
  priority: CRITICAL
  tags: [host, mitre_persistence, T1547.006]
  source: syscall

- rule: CKS Log File Deleted Or Truncated
  desc: Indicator removal — the attacker cleaning up after themselves (T1070.004).
  condition: >
    (evt.type in (unlink, unlinkat, rename, renameat, renameat2) and evt.dir=<
     and (fd.name startswith "/var/log" or evt.arg.path startswith "/var/log"))
    and not proc.name in (logrotate, journald, systemd-journald, rsyslogd)
  output: >
    Log file removed or renamed
    (evt_time=%evt.time target=%evt.arg.path proc=%proc.name
     cmdline=%proc.cmdline user=%user.name loginuid=%user.loginuid
     container_id=%container.id)
  priority: ERROR
  tags: [host, mitre_defense_evasion, T1070.004]
  source: syscall
```

### 5.6 Overriding a shipped rule (do not fork `falco_rules.yaml`)

Modern Falco replaces `append: true` with explicit `override` semantics. Put these in `/etc/falco/falco_rules.local.yaml`:

```yaml
# Append an exception to a shipped rule without copying its condition.
- rule: Terminal shell in container
  condition: and not k8smeta.ns.name in (debug-sandbox)
  override:
    condition: append

# Raise the priority of a shipped rule.
- rule: Read sensitive file untrusted
  priority: CRITICAL
  override:
    priority: replace

# Extend a shipped list.
- list: known_binaries
  items: [my-corp-agent, otel-collector]
  override:
    items: append

# Disable a rule that is pure noise in your environment.
- rule: Write below etc
  enabled: false
```

Preferred over both: the **`exceptions`** block, which is checked at compile time and cannot break the condition:

```yaml
- rule: CKS Package Management Executed In Container
  exceptions:
    - name: allowed_builder_images
      fields: [container.image.repository, proc.name]
      comps: [=, in]
      values:
        - [registry.internal.corp/ci/builder, [apt, apt-get, dpkg]]
```

### 5.7 Running and validating

```bash
$ falco --version
Falco version: 0.41.0
Libs version:  0.20.0
Plugin API:    3.10.0
Engine:        modern_ebpf
Driver:
  API version:    8.0.0
  Schema version: 2.0.0
  Default driver: 7.4.0+driver

# --- Syntax-check before you ever restart the daemon -----------------------
$ falco --validate /etc/falco/rules.d/cks-threat-detection.yaml
Fri Aug  5 11:02:14 2026: Validating rules file(s):
Fri Aug  5 11:02:14 2026:    /etc/falco/rules.d/cks-threat-detection.yaml
/etc/falco/rules.d/cks-threat-detection.yaml: Ok
Ok

# A broken rule fails loudly, with a line number:
$ falco --validate /tmp/broken.yaml
/tmp/broken.yaml: Invalid
1 error:
------
Item #0: Compilation error when compiling "proc_started and container.id != host and proc.nmae in (sh)":
  38:52 - filter_check called with nonexistent field proc.nmae

# --- List everything the engine loaded -------------------------------------
$ falco -L | grep -A2 '^CKS Terminal'
CKS Terminal Shell Spawned In Container
  An interactive shell was started inside a container. In an immutable,
  CI-deployed workload this never happens legitimately; it is either an

$ falco --list=syscall | grep -c .
412

# --- Time-boxed capture, JSON to a file (the classic CKS task) -------------
$ falco -r /etc/falco/falco_rules.yaml \
        -r /etc/falco/rules.d/cks-threat-detection.yaml \
        -M 45 \
        -o json_output=true \
        -o priority=warning \
        -o file_output.enabled=true \
        -o file_output.filename=/opt/course/incident.log \
        -o stdout_output.enabled=false
Fri Aug  5 11:07:31 2026: Falco version: 0.41.0 (x86_64)
Fri Aug  5 11:07:31 2026: Falco initialized with configuration files:
Fri Aug  5 11:07:31 2026:    /etc/falco/falco.yaml | schema validation: ok
Fri Aug  5 11:07:31 2026: Loading plugin 'container' from file /usr/share/falco/plugins/libcontainer.so
Fri Aug  5 11:07:31 2026: Loading plugin 'k8smeta' from file /usr/share/falco/plugins/libk8smeta.so
Fri Aug  5 11:07:31 2026: Loading rules from:
Fri Aug  5 11:07:31 2026:    /etc/falco/falco_rules.yaml | schema validation: ok
Fri Aug  5 11:07:31 2026:    /etc/falco/rules.d/cks-threat-detection.yaml | schema validation: ok
Fri Aug  5 11:07:31 2026: Hostname value has been overridden via environment variable to: worker-02
Fri Aug  5 11:07:31 2026: Starting health webserver with threadiness 8, listening on 0.0.0.0:8765
Fri Aug  5 11:07:31 2026: Loaded event sources: syscall
Fri Aug  5 11:07:31 2026: Enabled event sources: syscall
Fri Aug  5 11:07:31 2026: Opening 'syscall' source with modern BPF probe.
Fri Aug  5 11:07:31 2026: One ring buffer every '2' CPUs.
Fri Aug  5 11:08:16 2026: Running for 45 seconds, terminating...
Fri Aug  5 11:08:16 2026: Events detected: 6
Fri Aug  5 11:08:16 2026: Rule counts by severity:
   CRITICAL: 2
   ERROR: 1
   WARNING: 3
Fri Aug  5 11:08:16 2026: Triggered rules by rule name:
   CKS Terminal Shell Spawned In Container: 2
   CKS Package Management Executed In Container: 1
   CKS Service Account Token Read By Non App Process: 1
   CKS Outbound Connection To Non Cluster Destination: 1
   CKS Container Escape Tooling Executed: 1
Fri Aug  5 11:08:16 2026: Syscall event drop monitoring:
   - event drop detected: 0 occurrences
   - num times actions taken: 0
```

Sample JSON record:

```json
{
  "hostname": "worker-02",
  "output": "Service account token read by unexpected process (evt_time=11:07:52.331884113 file=/var/run/secrets/kubernetes.io/serviceaccount/token proc=curl cmdline=curl -s -H Authorization: Bearer ... parent=sh user=root container_id=8f3a2b1c9d4e image=registry.internal.corp/payments/api ns=payments pod=api-6d4f8b9c-2xk4z)",
  "output_fields": {
    "container.id": "8f3a2b1c9d4e",
    "container.image.repository": "registry.internal.corp/payments/api",
    "evt.time": 1786014472331884113,
    "fd.name": "/var/run/secrets/kubernetes.io/serviceaccount/token",
    "k8smeta.ns.name": "payments",
    "k8smeta.pod.name": "api-6d4f8b9c-2xk4z",
    "proc.cmdline": "curl -s -H Authorization: Bearer ...",
    "proc.name": "curl",
    "proc.pname": "sh",
    "user.name": "root"
  },
  "priority": "Critical",
  "rule": "CKS Service Account Token Read By Non App Process",
  "source": "syscall",
  "tags": ["T1552.001", "container", "mitre_credential_access", "secrets"],
  "time": "2026-08-05T11:07:52.331884113Z"
}
```

### 5.8 Custom output format — the exam's favourite variation

The task is usually phrased: *"write only `timestamp,container-id,user-name` for rule X into `/opt/course/detect.log`"*. You do it in the rule's `output:` field, not with `awk`:

```yaml
- rule: CKS Package Management Executed In Container
  output: "%evt.time,%container.id,%user.name"
```

```bash
$ falco -r /etc/falco/rules.d/cks-threat-detection.yaml -M 30 \
        -o json_output=false \
        -o time_format_iso_8601=true \
        -o stdout_output.enabled=false \
        -o file_output.enabled=true \
        -o file_output.filename=/opt/course/detect.log

$ cat /opt/course/detect.log
11:22:04.115332271: Error 2026-08-05T11:22:04+0000,3b9d7f21ea08,root
11:22:31.884190277: Error 2026-08-05T11:22:31+0000,3b9d7f21ea08,root
```

> **Gotcha.** Falco always prefixes the line with `<time>: <Priority> `. If the task demands *exactly* three comma-separated fields, either post-process, or note that the prefix is part of Falco's contract and the graded portion is the payload. Read the task wording carefully; when it says "log format", it means the `output:` field.

### 5.9 Falco on Kubernetes — Helm values (complete)

```yaml
# values-falco.yaml
driver:
  enabled: true
  kind: modern_ebpf

collectors:
  enabled: true
  containerd:
    enabled: true
    socket: /run/containerd/containerd.sock
  crio:
    enabled: false
  docker:
    enabled: false
  kubernetes:
    enabled: true          # deploys k8s-metacollector + k8smeta plugin

controller:
  kind: daemonset
  daemonset:
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxUnavailable: 1

falco:
  rules_files:
    - /etc/falco/falco_rules.yaml
    - /etc/falco/rules.d
  priority: notice
  buffered_outputs: false
  json_output: true
  json_include_output_property: true
  json_include_tags_property: true
  syscall_event_drops:
    threshold: 0.1
    actions: [log, alert]
    rate: 0.03333
    max_burst: 1
  metrics:
    enabled: true
    interval: 1h
    output_rule: true
  http_output:
    enabled: true
    url: "http://falco-falcosidekick:2801/"

customRules:
  cks-threat-detection.yaml: |-
    # (paste the full ruleset from 5.5 here; Helm renders it into
    #  /etc/falco/rules.d/cks-threat-detection.yaml)
    - list: cks_shell_binaries
      items: [ash, bash, csh, ksh, sh, tcsh, zsh, dash, busybox]
    # ... rest of the ruleset ...

resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1024Mi

tolerations:
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists

priorityClassName: system-node-critical

falcoctl:
  artifact:
    install:
      enabled: true
    follow:
      enabled: true          # auto-update rules from the OCI registry
  config:
    artifact:
      allowedTypes: [rulesfile, plugin]
      install:
        refs: [falco-rules:4]
      follow:
        refs: [falco-rules:4]

falcosidekick:
  enabled: true
  fullfqdn: false
  webui:
    enabled: true
    redis:
      storageEnabled: true
  config:
    debug: false
    customfields: "cluster:prod-eu-1,env:production"
    slack:
      webhookurl: ""                     # set via existingSecret
      minimumpriority: "critical"
      messageformat: "Falco on {{ .Hostname }}"
    loki:
      hostport: "http://loki.monitoring.svc.cluster.local:3100"
      minimumpriority: "notice"
    prometheus:
      extralabels: "cluster,env"
    elasticsearch:
      hostport: ""
      index: "falco"
      minimumpriority: "notice"
```

```bash
$ helm repo add falcosecurity https://falcosecurity.github.io/charts && helm repo update
"falcosecurity" has been added to your repositories
Update Complete. ⎈Happy Helming!⎈

$ helm upgrade --install falco falcosecurity/falco \
    --namespace falco --create-namespace \
    -f values-falco.yaml --wait --timeout 5m
Release "falco" does not exist. Installing it now.
NAME: falco
LAST DEPLOYED: Wed Aug  5 11:35:02 2026
NAMESPACE: falco
STATUS: deployed
REVISION: 1

$ kubectl -n falco get pods -o wide
NAME                                     READY   STATUS    RESTARTS   AGE   NODE
falco-8x2kq                              2/2     Running   0          92s   worker-01
falco-mn4vt                              2/2     Running   0          92s   worker-02
falco-falcosidekick-6d9c74b5f7-jr2wl     1/1     Running   0          92s   worker-01
falco-falcosidekick-ui-7f8b6d94c-x9pl2   1/1     Running   0          92s   worker-02
falco-k8s-metacollector-5c4b7d8f9-tq6mn  1/1     Running   0          92s   worker-01

# Prove the pipeline end to end.
$ kubectl -n payments exec -it deploy/api -- sh -c 'cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null'

$ kubectl -n falco logs ds/falco -c falco --since=60s | jq -r 'select(.priority=="Critical") | .rule'
CKS Service Account Token Read By Non App Process
```

---

## 6. Kernel-policy telemetry: detecting before you enforce

Both seccomp and AppArmor have a **log-only mode**. This is how you build an enforcement profile without breaking production — and it is a genuine detection surface in its own right.

| Mechanism | Detect mode | Enforce mode | Where the signal lands |
|---|---|---|---|
| seccomp | `SCMP_ACT_LOG` | `SCMP_ACT_ERRNO` / `SCMP_ACT_KILL_PROCESS` | auditd `type=SECCOMP`, or `dmesg` |
| AppArmor | `complain` (`aa-complain`) | `enforce` (`aa-enforce`) | auditd `apparmor="ALLOWED"` vs `"DENIED"` |
| SELinux | `permissive` | `enforcing` | auditd `type=AVC` |
| Falco | always detect-only | via Talon/response engine | Falco outputs |

**`/var/lib/kubelet/seccomp/profiles/audit.json`**

```json
{
  "defaultAction": "SCMP_ACT_LOG"
}
```

**`/var/lib/kubelet/seccomp/profiles/violation.json`** — allow-list everything the app needs, log the rest:

```json
{
  "defaultAction": "SCMP_ACT_LOG",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_X32"
  ],
  "syscalls": [
    {
      "names": [
        "accept4", "arch_prctl", "bind", "brk", "clone", "close", "connect",
        "epoll_create1", "epoll_ctl", "epoll_pwait", "execve", "exit_group",
        "fcntl", "fstat", "futex", "getdents64", "getpid", "getrandom",
        "getsockname", "getsockopt", "listen", "mmap", "mprotect", "munmap",
        "nanosleep", "newfstatat", "openat", "prctl", "pread64", "read",
        "readlinkv", "rt_sigaction", "rt_sigprocmask", "sched_getaffinity",
        "sendto", "set_robust_list", "set_tid_address", "setsockopt",
        "sigaltstack", "socket", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["ptrace", "process_vm_readv", "process_vm_writev",
                "init_module", "finit_module", "delete_module",
                "mount", "umount2", "pivot_root", "setns", "unshare",
                "kexec_load", "bpf", "perf_event_open"],
      "action": "SCMP_ACT_KILL_PROCESS"
    }
  ]
}
```

**Pod using it (Kubernetes ≥ 1.30 field syntax for AppArmor):**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: payments-api-audited
  namespace: payments
  labels:
    app: payments-api
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/violation.json   # relative to /var/lib/kubelet/seccomp
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-payments-api          # GA field since v1.30
  containers:
    - name: api
      image: registry.internal.corp/payments/api@sha256:9f2c1a...e77b
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        privileged: false
        capabilities:
          drop: ["ALL"]
      ports:
        - name: http
          containerPort: 8080
      volumeMounts:
        - name: tmp
          mountPath: /tmp
      resources:
        requests: {cpu: 100m, memory: 128Mi}
        limits:   {cpu: 500m, memory: 256Mi}
  volumes:
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
```

**AppArmor complain-mode profile** — `/etc/apparmor.d/k8s-payments-api`:

```
#include <tunables/global>

profile k8s-payments-api flags=(attach_disconnected,mediate_deleted,complain) {
  #include <abstractions/base>

  network inet tcp,
  network inet udp,

  file,                                   # observe everything, deny nothing (complain)

  # These would be DENIED in enforce mode; in complain mode they are logged.
  deny /etc/shadow rwklx,
  deny /proc/sys/kernel/** wklx,
  deny /sys/kernel/security/** rwklx,
  deny mount,
  deny ptrace (trace, tracedby, read, readby),

  capability net_bind_service,
}
```

```bash
$ sudo apparmor_parser -r -W /etc/apparmor.d/k8s-payments-api
$ sudo aa-status | grep -A2 'complain mode'
2 profiles are in complain mode.
   k8s-payments-api
   docker-default

# Observe what the workload actually does — this is your detection feed.
$ sudo ausearch -m AVC,SECCOMP -ts recent -i | grep -E 'apparmor=|SECCOMP' | head -6
type=AVC msg=audit(08/05/2026 11:52:03.771:3312) : apparmor="ALLOWED" operation="open"
  profile="k8s-payments-api" name="/etc/shadow" pid=52117 comm="sh"
  requested_mask="r" denied_mask="r" fsuid=10001 ouid=0
type=SECCOMP msg=audit(08/05/2026 11:52:07.114:3319) : auid=unset uid=10001 gid=10001
  ses=unset pid=52140 comm=sh exe=/bin/busybox sig=SIGSYS arch=x86_64 syscall=ptrace
  compat=0 ip=0x7f1a2b3c4d5e code=kill_process

# Aggregate: which syscalls did the workload attempt that the profile does not allow?
$ sudo ausearch -m SECCOMP -ts today --raw | aureport --syscall --summary -i

Syscall Summary Report
=========================
total  syscall
=========================
   47  ptrace
   12  mount
    9  setns
    3  init_module
```

> **The workflow.** Run in `complain`/`SCMP_ACT_LOG` for one full business cycle (include batch jobs and the monthly close), harvest the audit records, generate the allow-list, then flip to `enforce`. The **Security Profiles Operator** automates exactly this with `ProfileRecording` CRDs (`recorder: bpf` or `recorder: logs`).

---

## 7. Plane: network — flow-level detection

Syscall sensors see `connect()`; they do not see a packet that a NetworkPolicy dropped, nor L7 semantics. For that you need the datapath.

### 7.1 Default-deny is a *detection* control, not only a prevention control

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-explicit
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
  egress:
    # DNS to CoreDNS only.
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
    # Postgres inside the namespace.
    - to:
        - podSelector:
            matchLabels:
              app: payments-db
      ports:
        - protocol: TCP
          port: 5432
```

Once this exists, **every drop is a signal**. Without default-deny you have no baseline and no drop events.

### 7.2 Cilium: policy-level audit mode and Hubble observation

`CiliumNetworkPolicy` supports an **audit** mode via the endpoint's policy enforcement state, which lets you deploy a policy and watch what *would* be denied before enforcing it.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-api-l7-dns
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: payments-api
  egress:
    # L7 DNS visibility: every name the workload resolves is logged.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    # L7 HTTP visibility on the allowed egress path.
    - toFQDNs:
        - matchName: "api.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app: payments-db
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

```bash
$ cilium status --brief
OK

# Put a single endpoint into audit (non-enforcing, log-only) mode:
$ kubectl -n payments get pods -l app=payments-api -o jsonpath='{.items[0].status.podIP}'
10.244.2.87
$ kubectl -n kube-system exec ds/cilium -- cilium endpoint list | grep 10.244.2.87
1842   Disabled  Disabled  24681  k8s:app=payments-api  10.244.2.87  ready
$ kubectl -n kube-system exec ds/cilium -- cilium endpoint config 1842 PolicyAuditMode=Enabled
Endpoint 1842 configuration updated successfully

# Watch what the policy WOULD drop:
$ hubble observe --namespace payments --verdict AUDIT --follow
Aug  5 12:03:11.442: payments/api-6d4f8b9c-2xk4z:41022 (ID:24681) -> 198.51.100.9:443 (world) policy-verdict:none EGRESS AUDITED (TCP Flags: SYN)
Aug  5 12:03:11.610: payments/api-6d4f8b9c-2xk4z:52104 (ID:24681) -> kube-system/coredns-xxx:53 (ID:16) policy-verdict:L3-L4 EGRESS ALLOWED (UDP)

# Real drops, once enforcing:
$ hubble observe --verdict DROPPED --last 20
Aug  5 12:11:04.113: payments/api-6d4f8b9c-2xk4z:44118 (ID:24681) <> 203.0.113.77:9001 (world) Policy denied DROPPED (TCP Flags: SYN)
Aug  5 12:11:05.220: payments/api-6d4f8b9c-2xk4z:44120 (ID:24681) <> 203.0.113.77:9001 (world) Policy denied DROPPED (TCP Flags: SYN)

# DNS exfiltration hunting — long labels, high-entropy subdomains:
$ hubble observe --protocol dns --namespace payments -o json --last 5000 \
  | jq -r 'select(.l7.dns.query != null) | .l7.dns.query' \
  | awk 'length($0) > 60' | sort | uniq -c | sort -rn | head -3
     41 aGVsbG8td29ybGQtZXhmaWx0cmF0aW9uLXBheWxvYWQ.c2.attacker.example.
     37 dGhpcy1pcy1zdGFnZS10d28tb2YtdGhlLWJlYWNvbg.c2.attacker.example.
     33 YmFzZTY0LWVuY29kZWQtc2VjcmV0LW1hdGVyaWFs.c2.attacker.example.

# Anything talking to the API server that should not be:
$ hubble observe --to-identity 1 --last 50 -o compact
Aug  5 12:14:22.001 payments/api-6d4f8b9c-2xk4z:48812 -> kube-apiserver:6443 to-network FORWARDED (TCP Flags: SYN)
```

### 7.3 Tetragon: kernel-level enforcement + telemetry with `TracingPolicy`

Tetragon adds what Falco cannot: **synchronous, in-kernel action** (`Sigkill`, `Override`) at the hook point, and LSM-level hooks rather than syscall boundaries (immune to TOCTOU on path arguments).

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: detect-credential-access
  namespace: payments
spec:
  kprobes:
    # ---- Detect reads of credential material via the LSM file hook --------
    - call: "security_file_permission"
      syscall: false
      return: true
      args:
        - index: 0
          type: "file"
        - index: 1
          type: "int"
      returnArg:
        index: 0
        type: "int"
      returnArgAction: "Post"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Prefix"
              values:
                - "/var/run/secrets/kubernetes.io/serviceaccount"
                - "/etc/shadow"
                - "/etc/kubernetes/pki"
                - "/root/.ssh"
            - index: 1
              operator: "Equal"
              values:
                - "4"          # MAY_READ
          matchActions:
            - action: Post

    # ---- Detect AND KILL any attempt to write to /etc/passwd or /etc/shadow
    - call: "security_file_permission"
      syscall: false
      return: true
      args:
        - index: 0
          type: "file"
        - index: 1
          type: "int"
      returnArg:
        index: 0
        type: "int"
      returnArgAction: "Post"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Equal"
              values:
                - "/etc/passwd"
                - "/etc/shadow"
            - index: 1
              operator: "Equal"
              values:
                - "2"          # MAY_WRITE
          matchActions:
            - action: Sigkill

  # ---- Detect every process execution in the namespace -------------------
  tracepoints:
    - subsystem: "raw_syscalls"
      event: "sys_enter"
      args:
        - index: 4
          type: "int64"
      selectors:
        - matchArgs:
            - index: 0
              operator: "InMap"
              values:
                - "101"   # unshare
                - "308"   # setns
                - "165"   # mount
                - "155"   # pivot_root
          matchActions:
            - action: Post
```

```bash
$ kubectl apply -f tracingpolicy-credential-access.yaml
tracingpolicynamespaced.cilium.io/detect-credential-access created

$ kubectl -n kube-system get tracingpolicies,tracingpoliciesnamespaced -A
NAMESPACE   NAME                                                       AGE
payments    tracingpolicynamespaced.cilium.io/detect-credential-access 14s

$ kubectl -n kube-system exec -ti ds/tetragon -c tetragon -- \
    tetra getevents -o compact --namespace payments
🚀 process payments/api-6d4f8b9c-2xk4z /bin/sh
🚀 process payments/api-6d4f8b9c-2xk4z /usr/bin/cat /var/run/secrets/kubernetes.io/serviceaccount/token
📖 read    payments/api-6d4f8b9c-2xk4z /var/run/secrets/kubernetes.io/serviceaccount/token
🚀 process payments/api-6d4f8b9c-2xk4z /usr/bin/vi /etc/shadow
📝 write   payments/api-6d4f8b9c-2xk4z /etc/shadow
💥 exit    payments/api-6d4f8b9c-2xk4z /usr/bin/vi /etc/shadow SIGKILL
```

---

## 8. Comparative analysis: choosing the sensor

| | **Falco** | **Tetragon** | **Tracee** | **auditd** | **Kubernetes audit** |
|---|---|---|---|---|---|
| Layer | syscall (tracepoint) | kprobe/LSM/tracepoint | syscall + LSM | syscall (audit subsystem) | HTTP API |
| Detects `kubectl create clusterrolebinding` | ❌ (unless `k8saudit` plugin) | ❌ | ❌ | ❌ | ✅ **only source** |
| Detects `cat /etc/shadow` in a pod | ✅ | ✅ | ✅ | ✅ (no pod identity) | ❌ |
| Detects a dropped packet | ❌ | ✅ (with Cilium) | partial | ❌ | ❌ |
| Detects firmware/boot tamper | ❌ | ❌ | ❌ | partial | ❌ |
| Kubernetes identity enrichment | ✅ via `k8smeta` plugin | ✅ native | ✅ | ❌ | ✅ native |
| Can block synchronously | ❌ (async via Talon) | ✅ `Sigkill`/`Override` | ✅ (signatures + policies) | ❌ | ✅ (admission is separate) |
| TOCTOU-safe path matching | ⚠️ syscall args | ✅ LSM hooks | ✅ | ⚠️ | n/a |
| Rule language | sysdig filter DSL | CRD selectors | Go/Rego signatures | audit rules | audit Policy YAML |
| Rule ecosystem maturity | ★★★★★ | ★★★☆☆ | ★★★☆☆ | ★★★★☆ | ★★☆☆☆ |
| Node overhead (typical) | 2–5 % CPU | 1–3 % CPU | 3–7 % CPU | 1–4 % CPU + disk | 3–8 % apiserver CPU |
| CNCF status | Graduated | Incubating (Cilium) | Incubating (Aqua) | Linux upstream | Upstream Kubernetes |
| **On the CKS exam** | **primary** | rare | rare | secondary | **primary** |

**Recommendation for a production platform:** run **all three of** Kubernetes audit (user plane), Falco (workload plane), and Hubble or Tetragon (network plane). They are complements, not alternatives — the tables above show each has a blind spot the others cover. Add auditd + AIDE + IMA on the node for the physical/OS plane. For the exam, invest your study time in Falco and the audit policy.

### 8.1 Detect-only vs enforce: the operational trade-off

| Posture | MTTD | MTTR | Availability risk | When to choose |
|---|---|---|---|---|
| Detect only (Falco → SIEM → human) | seconds | minutes–hours | none | New rule, unknown FP rate, business-critical workload |
| Detect + automated label/quarantine (Talon: `kubernetes:label`, NetworkPolicy isolation) | seconds | seconds | low — pod keeps running, loses network | Default for `Critical` rules after 2 weeks of clean detect-only data |
| Detect + terminate (Talon: `kubernetes:terminate`) | seconds | seconds | medium — Deployment reschedules; a `DaemonSet` or singleton `StatefulSet` may not | High-confidence rules only; always `ignore_daemonsets`/`ignore_statefulsets` |
| In-kernel kill (Tetragon `Sigkill`, seccomp `SCMP_ACT_KILL_PROCESS`) | 0 | 0 | high — no appeal, no context | Only for behaviour that is *never* legitimate (write to `/etc/shadow`, `init_module`) |

---

## 9. From detection to response

**Falcosidekick** fans a Falco event out to N destinations. **Falco Talon** is the response engine that acts on it.

```yaml
# falcosidekick config fragment (chart values .falcosidekick.config)
customfields: "cluster:prod-eu-1,env:production,team:platform-sec"
templatedfields: ""
outputFieldFormat: ""

# Route by priority, not by rule — keeps routing stable as rules evolve.
slack:
  webhookurl: "https://hooks.slack.com/services/XXX"
  minimumpriority: "critical"
  outputformat: "all"
  messageformat: "Falco {{ .Priority }} on {{ .Hostname }}"

loki:
  hostport: "http://loki.monitoring.svc.cluster.local:3100"
  minimumpriority: "debug"      # everything, for retro-hunting
  tenant: "security"
  extralabels: "rule,priority,k8s_ns_name,k8s_pod_name"

prometheus:
  extralabels: "cluster,env,team"

webhook:
  address: "http://falco-talon.falco.svc.cluster.local:2803"
  minimumpriority: "warning"

policyreport:
  enabled: true
  kubeconfig: ""
  minimumpriority: "notice"
  maxevents: 1000
  prunebypriority: true
```

Talon response rules (schema is version-sensitive — validate against the chart you deploy):

```yaml
# talon-rules.yaml
- action: Label suspicious pod
  actionner: kubernetes:label
  parameters:
    labels:
      security.corp/quarantine: "true"
      security.corp/incident: "auto"

- action: Isolate pod network
  actionner: kubernetes:networkpolicy
  parameters:
    allow_cidr:
      - "10.0.100.0/24"     # forensic collector only

- action: Terminate pod
  actionner: kubernetes:terminate
  parameters:
    grace_period_seconds: 5
    ignore_daemonsets: true
    ignore_statefulsets: true

---
- rule: Quarantine on credential access
  match:
    rules:
      - "CKS Service Account Token Read By Non App Process"
      - "CKS Sensitive Host File Accessed From Container"
    priority: ">=critical"
    output_fields:
      - "k8smeta.ns.name!=kube-system"
  actions:
    - action: Label suspicious pod
    - action: Isolate pod network

- rule: Terminate on container escape
  match:
    rules:
      - "CKS Container Escape Tooling Executed"
      - "CKS Host Namespace Entered From Container"
    priority: ">=critical"
  actions:
    - action: Label suspicious pod
    - action: Terminate pod
```

> **Design rule.** *Label + isolate* before *terminate*. Terminating destroys the evidence you need for the post-incident review, and an attacker who notices instant pod death learns your detection boundary. Isolation preserves memory, `/proc`, and the process tree for live forensics while stopping exfiltration.

---

## 10. Verification and failure diagnosis

### 10.1 Falco produces no events at all

```bash
# 1. Is the driver actually attached?
$ kubectl -n falco logs ds/falco -c falco | grep -iE 'Opening|probe|driver|error'
Fri Aug  5 11:07:31 2026: Opening 'syscall' source with modern BPF probe.

# If instead you see:
#   Runtime error: can't open BPF probe. Exiting.
$ ls /sys/kernel/btf/vmlinux || echo "NO BTF → modern_ebpf unavailable"
$ kubectl -n falco set env ds/falco FALCO_BPF_PROBE=""   # fall back to legacy eBPF

# 2. Is the container privileged enough?
$ kubectl -n falco get ds falco -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | jq
{
  "capabilities": {"add": ["SYS_ADMIN","SYS_RESOURCE","SYS_PTRACE","BPF","PERFMON"]},
  "privileged": false
}
# Missing BPF/PERFMON on kernels >=5.8 → probe load fails silently in some builds.

# 3. hostPID / host mounts present?
$ kubectl -n falco get ds falco -o jsonpath='{.spec.template.spec.hostPID}'
true
$ kubectl -n falco get ds falco -o jsonpath='{.spec.template.spec.volumes[*].name}'
etc-falco proc-fs boot-fs lib-modules usr-fs sys-fs containerd-socket

# 4. Health endpoint
$ kubectl -n falco exec ds/falco -c falco -- curl -s localhost:8765/healthz
{"healthy": true}
```

### 10.2 A rule exists but never fires

| Symptom | Cause | Fix |
|---|---|---|
| Rule listed by `falco -L` but silent | `priority:` in `falco.yaml` is above the rule's priority | Lower `priority:` or raise the rule's |
| Rule silent, no error | A later file redefines the same `rule:` name | `grep -R "rule: <name>" /etc/falco` — last definition wins |
| Rule silent only in containers | `container.id != host` but the `container` plugin can't reach the CRI socket | Check `container.id` is not literally `host` in other events; fix the socket path |
| `k8smeta.ns.name` always empty | `k8s-metacollector` not deployed / plugin not loaded | `kubectl -n falco get deploy k8s-metacollector`; check `load_plugins` |
| Fires in `-M` foreground run but not as a service | Different rules dir, different config file | `systemctl cat falco-modern-bpf.service` and compare `-c`/`-r` args |
| Fires but events vanish downstream | `buffered_outputs: true` and Falco restarts | Set `buffered_outputs: false` |

```bash
# The definitive test: does the engine even see the syscall?
$ falco -r /etc/falco/rules.d/cks-threat-detection.yaml -M 20 \
        -o log_level=debug -o stdout_output.enabled=true 2>&1 | grep -i 'rule.*loaded\|skipp'

# Per-rule hit counters (requires metrics.rules_counters_enabled: true)
$ kubectl -n falco logs ds/falco -c falco | jq -r \
    'select(.rule=="Falco internal: metrics snapshot") | .output_fields
     | to_entries[] | select(.key|startswith("falco.rules_counters"))
     | "\(.key)=\(.value)"' | head
falco.rules_counters.CKS Terminal Shell Spawned In Container=14
falco.rules_counters.CKS Package Management Executed In Container=3
falco.rules_counters.CKS Container Escape Tooling Executed=0
```

### 10.3 Falco is dropping events (you are blind and don't know it)

```bash
$ kubectl -n falco logs ds/falco -c falco | grep -i 'drop'
Fri Aug  5 12:31:02 2026: Falco internal: syscall event drop. 41252 system calls dropped in last second.
{"priority":"Critical","rule":"Falco internal: syscall event drop",
 "output":"Falco internal: syscall event drop. 41252 system calls dropped in last second.",
 "output_fields":{"n_drops":41252,"n_drops_buffer_total":41252,"n_evts":1204118}}
```

Remediation, in order of preference:

1. Raise `buf_size_preset` (4 → 6 doubles per-CPU ring memory; costs RAM).
2. Set `drop_failed_exit: true` — discards failed syscalls, typically 20–40 % of volume.
3. Trim the base ruleset: disable rules you never action.
4. Reduce `cpus_for_each_buffer` (1 = one buffer per CPU, most memory, fewest drops).
5. Move the noisiest workload to a node with a dedicated Falco resource limit.

Always alert on the drop rule itself. A silent Falco is indistinguishable from a clean cluster.

### 10.4 API server won't start after enabling audit

```bash
# Static pods don't appear in `kubectl get events` when the apiserver is down.
$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE    NAME             ATTEMPT
a1b2c3d4e5f6   4b2b0f0a9c1d   9 seconds ago   Exited   kube-apiserver   7

$ sudo crictl logs a1b2c3d4e5f6 2>&1 | tail -5
I0805 12:41:02.118  1 flags.go:64] FLAG: --audit-policy-file="/etc/kubernetes/audit/policy.yaml"
E0805 12:41:02.221  1 run.go:74] "command failed" err="failed to initialize audit backend: \
  error opening audit policy file: open /etc/kubernetes/audit/policy.yaml: no such file or directory"

$ sudo journalctl -u kubelet -n 30 --no-pager | grep -i apiserver
```

Checklist when the API server CrashLoops after an audit change:

| Error text | Root cause |
|---|---|
| `open ...: no such file or directory` | `hostPath` volume missing, or `mountPath` doesn't match the flag |
| `error opening audit log file: permission denied` | Log dir mounted `readOnly: true`, or wrong ownership |
| `unknown field "omitManagedFields"` | Policy `apiVersion` wrong (must be `audit.k8s.io/v1`) |
| `invalid policy: level "Meta" is not valid` | Typo in `level:` — valid values are `None`, `Metadata`, `Request`, `RequestResponse` |
| Starts, but log stays empty | Every request matched a `level: None` rule; rule order is first-match-wins |
| Starts, then OOMs the node | `--audit-log-maxsize` unset, disk full, or `RequestResponse` catch-all |

```bash
# Verify the flags actually took effect:
$ kubectl -n kube-system get pod kube-apiserver-cp1 -o yaml \
  | grep -E 'audit-(policy|log|webhook)'
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=500

# Verify events are landing and are well-formed JSON:
$ sudo tail -1 /var/log/kubernetes/audit/audit.log | jq -e '.kind == "Event"' && echo VALID
true
VALID

$ sudo ls -lh /var/log/kubernetes/audit/
total 412M
-rw------- 1 root root  87M Aug  5 12:44 audit.log
-rw------- 1 root root  41M Aug  5 09:12 audit-2026-08-05T09-12-04.331.log.gz

# Volume sanity check — events per minute:
$ sudo tail -100000 /var/log/kubernetes/audit/audit.log \
  | jq -r '.requestReceivedTimestamp[0:16]' | uniq -c | tail -5
   1204 2026-08-05T12:40
   1188 2026-08-05T12:41
   1231 2026-08-05T12:42
   1197 2026-08-05T12:43
   1210 2026-08-05T12:44
# ~1200/min = ~1.7M/day. At ~1KB Metadata records that is ~1.7GB/day. Acceptable.
# If you see 20k/min, your noise-suppression rules are not matching. Check rule order.
```

### 10.5 End-to-end detection drill (run this after every change)

```bash
#!/usr/bin/env bash
# detection-smoke-test.sh — verify each plane produces its expected signal.
set -euo pipefail
NS=detection-drill
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" run drill --image=alpine:3.20 --restart=Never \
  --command -- sleep 3600
kubectl -n "$NS" wait --for=condition=Ready pod/drill --timeout=60s

echo "== [workload] interactive shell =="
kubectl -n "$NS" exec drill -- sh -c 'echo shell-spawned'

echo "== [workload] package manager =="
kubectl -n "$NS" exec drill -- sh -c 'apk info >/dev/null 2>&1 || true'

echo "== [data] service account token read =="
kubectl -n "$NS" exec drill -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null

echo "== [network] egress to the internet =="
kubectl -n "$NS" exec drill -- \
  sh -c 'wget -q -T 3 -O /dev/null https://example.com || true'

echo "== [users] secret enumeration (should be forbidden + audited) =="
kubectl -n "$NS" get secrets >/dev/null 2>&1 || true

echo "== [users] exec is audited at RequestResponse =="
sleep 5
sudo jq -r 'select(.objectRef.subresource=="exec")
            | select(.objectRef.namespace=="'"$NS"'")
            | .requestReceivedTimestamp + " " + .user.username' \
  /var/log/kubernetes/audit/audit.log | tail -3

echo "== Falco verdict =="
kubectl -n falco logs ds/falco -c falco --since=90s \
  | jq -r 'select(.output_fields["k8smeta.ns.name"]=="'"$NS"'")
           | .priority + "  " + .rule' | sort | uniq -c

kubectl delete namespace "$NS" --wait=false
```

Expected output:

```
== Falco verdict ==
      1 Critical  CKS Service Account Token Read By Non App Process
      1 Error     CKS Package Management Executed In Container
      2 Warning   CKS Terminal Shell Spawned In Container
      1 Warning   CKS Outbound Connection To Non Cluster Destination
```

A missing line is a coverage gap, not a passing test. Wire this script into CI against a staging cluster and fail the build when a plane goes dark.

---

## 11. Exam-focused drill

Under time pressure, these are the muscle-memory sequences.

**Task pattern A — "Add a Falco rule that detects X and writes to a file."**

```bash
# 1. Find the config and the rules directory.
$ ls /etc/falco/
falco.yaml  falco_rules.local.yaml  falco_rules.yaml  rules.d/

# 2. Write the rule into rules.d/ (never into falco_rules.yaml).
$ sudo tee /etc/falco/rules.d/exam.yaml >/dev/null <<'EOF'
- rule: Detect Package Management In Container
  desc: Package manager launched inside a container
  condition: >
    evt.type in (execve, execveat) and evt.dir=< and container.id != host
    and proc.name in (apk, apt, apt-get, dpkg, yum, dnf, rpm, pip, npm)
  output: "%evt.time,%container.id,%user.name"
  priority: ERROR
  source: syscall
EOF

# 3. Validate BEFORE restarting anything.
$ sudo falco --validate /etc/falco/rules.d/exam.yaml
/etc/falco/rules.d/exam.yaml: Ok

# 4. Capture for a bounded time into the requested file.
$ sudo falco -M 45 \
    -o stdout_output.enabled=false \
    -o file_output.enabled=true \
    -o file_output.filename=/opt/course/incidents.log

# 5. Or, if the task wants the daemon running persistently:
$ sudo systemctl restart falco-modern-bpf.service
$ sudo systemctl status falco-modern-bpf.service --no-pager
$ sudo journalctl -u falco-modern-bpf.service -f
```

**Task pattern B — "Enable auditing with policy P and verify."**

```bash
$ sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
$ sudo vi /etc/kubernetes/audit/policy.yaml            # write the policy
$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/apiserver.bak
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml # flags + volume + volumeMount
$ watch -n2 'sudo crictl ps | grep apiserver'          # wait for a fresh container
$ kubectl get --raw /livez?verbose | tail -3
$ sudo tail -f /var/log/kubernetes/audit/audit.log | jq -c '{u:.user.username,v:.verb,r:.objectRef.resource}'
```

**Fast identification of the guilty pod from a `container.id`:**

```bash
$ CID=8f3a2b1c9d4e
$ sudo crictl ps --id "$CID" -o json | jq -r '.containers[0].labels
    | "\(.["io.kubernetes.pod.namespace"])/\(.["io.kubernetes.pod.name"])"'
payments/api-6d4f8b9c-2xk4z

# Or cluster-wide, without node access:
$ kubectl get pods -A -o json \
  | jq -r --arg cid "$CID" '.items[]
      | select(.status.containerStatuses[]?.containerID | test($cid))
      | "\(.metadata.namespace)/\(.metadata.name) node=\(.spec.nodeName)"'
payments/api-6d4f8b9c-2xk4z node=worker-02
```

---

## 12. Summary — the decision table

| You must detect… | Use | Why nothing else works |
|---|---|---|
| A user granting themselves `cluster-admin` | kube-apiserver audit log | It is an HTTPS request; no node sensor sees it |
| A shell inside a container | Falco / Tetragon | Audit log only sees `pods/exec`, not `sh` spawned by the app itself |
| An SA token stolen and replayed externally | Audit log (`sourceIPs` vs cluster CIDR) | Only the API server sees the presenter's IP |
| A container escaping to the host | Falco (`setns`, `/proc/*/root`) + auditd | Kubernetes has no concept of a namespace break |
| Data exfiltration over an allowed port | Hubble L7 / DNS telemetry | Syscall `connect()` cannot tell C2 from a CDN |
| A replaced `kubelet` binary | IMA + AIDE | The compromised kubelet reports itself healthy |
| A firmware implant | TPM PCR attestation | Everything above the firmware trusts it |
| A syscall your seccomp profile would block | seccomp `SCMP_ACT_LOG` + auditd | Enforcing first breaks production |

Detection is a system, not a tool. Instrument every plane, prove each one fires with the smoke test, alert on sensor silence as loudly as you alert on findings, and stream everything off-node before the pod dies.

---

## 13. References

**Curriculum and exam**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum

**Kubernetes upstream**
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Audit Policy API reference (`audit.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- kube-apiserver command-line reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Seccomp: restrict a container's syscalls — https://kubernetes.io/docs/tutorials/security/seccomp/
- AppArmor: restrict a container's access — https://kubernetes.io/docs/tutorials/security/apparmor/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/
- Kubernetes Security Cheat Sheet — https://kubernetes.io/docs/concepts/security/security-checklist/
- Static Pods — https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/

**Falco (CNCF Graduated)**
- Documentation home — https://falco.org/docs/
- Rules reference — https://falco.org/docs/concepts/rules/
- Supported fields (filter reference) — https://falco.org/docs/reference/rules/supported-fields/
- Configuration options (`falco.yaml`) — https://falco.org/docs/reference/daemon/config-options/
- Command-line options — https://falco.org/docs/reference/daemon/daemon-cli/
- Drivers (modern eBPF, eBPF, kmod) — https://falco.org/docs/concepts/event-sources/kernel/
- Plugins (`container`, `k8smeta`, `k8saudit`) — https://falco.org/docs/concepts/plugins/
- Event drops / metrics — https://falco.org/docs/concepts/metrics/
- falcoctl — https://github.com/falcosecurity/falcoctl
- Falcosidekick — https://github.com/falcosecurity/falcosidekick
- Falco Talon (response engine) — https://github.com/falcosecurity/falco-talon
- Helm charts — https://github.com/falcosecurity/charts

**eBPF-based alternatives**
- Cilium Tetragon documentation — https://tetragon.io/docs/
- Tetragon TracingPolicy reference — https://tetragon.io/docs/concepts/tracing-policy/
- Cilium Hubble — https://docs.cilium.io/en/stable/observability/hubble/
- Cilium Network Policy (L7/DNS) — https://docs.cilium.io/en/stable/security/policy/
- Aqua Tracee — https://aquasecurity.github.io/tracee/latest/

**Node and physical integrity**
- Linux audit framework (`auditd`) — https://github.com/linux-audit/audit-documentation/wiki
- `auditctl(8)` — https://man7.org/linux/man-pages/man8/auditctl.8.html
- `ausearch(8)` — https://man7.org/linux/man-pages/man8/ausearch.8.html
- AIDE — https://aide.github.io/
- Kernel IMA/EVM — https://www.kernel.org/doc/html/latest/security/IMA-templates.html
- Kernel lockdown / Secure Boot — https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html
- `seccomp(2)` and `SECCOMP_RET_LOG` — https://man7.org/linux/man-pages/man2/seccomp.2.html
- AppArmor documentation — https://gitlab.com/apparmor/apparmor/-/wikis/Documentation
- Keylime (remote attestation, CNCF sandbox) — https://keylime.dev/

**Threat models and benchmarks**
- MITRE ATT&CK Matrix for Containers — https://attack.mitre.org/matrices/enterprise/containers/
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- NSA/CISA Kubernetes Hardening Guidance — https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- Security Profiles Operator — https://github.com/kubernetes-sigs/security-profiles-operator