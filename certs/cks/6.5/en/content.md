# 6.5 — Use Kubernetes Audit Logs to Monitor Access

**Certification:** CKS (Certified Kubernetes Security Specialist) — Exam version **1.34**
**Domain:** Monitoring, Logging and Runtime Security — **weight 4**

---

## 1. Motivation and the production architectural problem

### 1.1 What the audit log actually is

The Kubernetes API server is the **single mandatory chokepoint** for every declarative mutation and every read of cluster state. `kubectl`, controllers, operators, CI runners, kubelets, the scheduler, admission webhooks and every human — all of them ultimately issue HTTP requests to `kube-apiserver`. The **audit subsystem** is a chain of `AuditBackend` implementations wired into the apiserver's HTTP filter chain (`WithAudit`), which emits a structured `audit.k8s.io/v1` `Event` object for each request that a policy says is interesting.

That single fact is the whole architectural value proposition: **if you instrument one component, you get a security-relevant, tamper-evident, chronological record of who did what to which object, when, from where, and whether authorization allowed it.**

### 1.2 The production problem it solves

Consider the postmortem questions that every real incident produces:

| Incident question | Without audit logs | With audit logs |
|---|---|---|
| "Who deleted the `prod` StatefulSet at 03:12?" | `kubectl get events` — already garbage-collected after 1 h | Exact `user.username`, `sourceIPs`, `userAgent`, `auditID` |
| "Did the compromised CI token read our Secrets?" | Unknowable | `get`/`list` on `resources: secrets` filtered by `user.username` |
| "Was this ServiceAccount used from outside the cluster network?" | Unknowable | `sourceIPs` vs. Pod CIDR |
| "Did anyone `exec` into the PCI-scoped Pod?" | Unknowable | `objectRef.subresource == "exec"` |
| "Which identity escalated privileges via a ClusterRoleBinding?" | Unknowable | `RequestResponse`-level event with the full RBAC object |
| "Are we still calling a removed API before the 1.35 upgrade?" | Only from metrics, no attribution | `annotations["k8s.io/deprecated"] == "true"` + `userAgent` |

Kubernetes **Events** (`v1.Event`) are *not* an audit trail: they are best-effort, namespaced, aggregated, deduplicated and TTL'd (default 1 hour via `--event-ttl`). They exist for operational debugging, not for forensics or compliance. Audit logs are the only first-party mechanism that satisfies **PCI-DSS 10.x**, **SOC 2 CC7.2**, **ISO 27001 A.12.4** and **NIST 800-53 AU-2/AU-3** requirements for the control plane.

### 1.3 The three architectural tensions you must resolve

Enabling audit logging is trivial. Enabling it *correctly in production* forces three explicit trade-offs, and CKS-level competence means being able to argue each one:

**Tension 1 — Fidelity vs. volume vs. secret leakage.**
`RequestResponse` level captures the full object. On a `Secret` or a `TokenRequest`, that writes **plaintext credential material to a file on the control-plane node's disk**, which is then shipped to your log aggregator, indexed, replicated and retained for 400 days. A `RequestResponse` policy applied to `secrets` is a *credential exfiltration pipeline you built yourself*. Conversely, `Metadata` on a `clusterrolebindings` create tells you *that* an escalation happened but not *to whom the role was bound* — useless for response.

**Tension 2 — Durability vs. API server latency.**
The log backend defaults to `blocking` mode: the request handler does not complete until the event is written. If `/var/log` fills or the disk stalls, **every API request stalls with it** — the control plane becomes unavailable. `batch` mode decouples them at the cost of a bounded window of event loss on a hard crash. The webhook backend makes this worse: a slow SIEM in `blocking` mode injects its network latency into the p99 of every API call.

**Tension 3 — Locality vs. aggregation in HA control planes.**
Each `kube-apiserver` writes **its own local file**. A three-node stacked control plane behind a load balancer produces three partial, interleaved logs. Any query ("show me everything user X did") is wrong unless you aggregate all three. Worse, a node rebuild silently destroys evidence. Audit logs are only forensically useful once they are shipped off the node to write-once storage.

### 1.4 What the audit log does *not* see (the boundary of the control)

This is a favourite exam and interview probe. The audit log records requests **to `kube-apiserver`**. It is blind to:

- Direct `kubelet` API access (`https://node:10250/run/...`, `/exec`, `/logs`) that bypasses the apiserver. Those hit the kubelet's own (separate, rarely enabled) audit configuration.
- Direct `etcd` access (`etcdctl get /registry/secrets/... --prefix`) — a full read of every Secret in the cluster with **zero** audit events.
- Node-level activity: SSH, container escapes, process execution, file writes, outbound network. That is Falco / eBPF / auditd territory.
- Aggregated API servers (`metrics.k8s.io`, custom `APIService` backends) — the *proxying* request is audited by `kube-apiserver`, but the extension server's internal handling is audited only by its own configuration.
- Requests rejected by the load balancer, the firewall, or TLS handshake failures.

> **Design consequence:** audit logs are the *identity and intent* layer. Falco/eBPF is the *behaviour* layer. Neither substitutes for the other; a mature platform correlates both by Pod, node and timestamp.

---

## 2. Architecture of the audit subsystem

### 2.1 Request lifecycle and audit stages

```
                      kube-apiserver HTTP filter chain
   client
     │
     ├─► WithPanicRecovery
     ├─► WithRequestInfo
     ├─► WithAudit ◄──────── creates AuditContext, assigns auditID (UUID),
     │        │              sets response header "Audit-Id"
     │        │
     │        ├─ stage: RequestReceived      (emitted immediately, before authn)
     │        │
     ├─► WithAuthentication  ── populates event.user / event.impersonatedUser
     ├─► WithImpersonation
     ├─► WithAuthorization   ── writes annotations authorization.k8s.io/{decision,reason}
     ├─► WithPriorityAndFairness
     ├─► Admission (mutating → validating) ── writes admission annotations
     ├─► Storage / etcd
     │        │
     │        ├─ stage: ResponseStarted      (long-running only: watch, exec, portforward)
     │        └─ stage: ResponseComplete     (emitted when the response is fully written)
     │
     └─► on unrecovered panic ─ stage: Panic
                       │
                       ▼
              ┌────────────────────┐
              │   Audit Policy     │  first matching rule wins → level
              │  (audit.k8s.io/v1) │  no match → event dropped
              └────────┬───────────┘
                       │ Event (audit.k8s.io/v1)
            ┌──────────┴───────────┐
            ▼                      ▼
     log backend             webhook backend
  (file / stdout,          (POST batches of EventList
   lumberjack rotation)     to an HTTPS endpoint)
```

### 2.2 The four stages

| Stage | When emitted | Contains a response? | Typical use |
|---|---|---|---|
| `RequestReceived` | The handler receives the request, **before** authn/authz | No | Detecting requests that never completed (hung, killed apiserver). Doubles log volume. **Almost always omitted.** |
| `ResponseStarted` | Response headers written but body still streaming — only for long-running requests (`watch`, `exec`, `attach`, `portforward`) | Headers only | Catching the *start* of an interactive session even if it never terminates cleanly |
| `ResponseComplete` | Response body finished | Yes (`responseStatus`, and object if level allows) | **The event you actually analyse** |
| `Panic` | Handler panicked | No | Apiserver bug / DoS forensics |

A single `kubectl exec` therefore produces up to **three** events sharing one `auditID`: `RequestReceived`, `ResponseStarted`, `ResponseComplete`. Correlation is by `auditID` — never by timestamp.

### 2.3 The four levels

| Level | Metadata (who/what/when/verb/objectRef) | Request body | Response body | Notes |
|---|---|---|---|---|
| `None` | — | — | — | Event is discarded. Used to silence noise **before** a broader rule. |
| `Metadata` | ✅ | ❌ | ❌ | Safe default. Never leaks object content. |
| `Request` | ✅ | ✅ | ❌ | Shows *what was asked for*. For non-resource URLs it degrades to `Metadata`. |
| `RequestResponse` | ✅ | ✅ | ✅ | Full fidelity. **Never for `secrets`, `configmaps` with secrets, `tokenreviews`, `serviceaccounts/token`, `certificatesigningrequests`.** For `watch`, does *not* include the streamed objects. |

> **Sharp edge:** for `get`/`list`, `Request` adds essentially nothing (there is no request body) while `RequestResponse` dumps the entire returned object set — a `list` of 4 000 Pods becomes a single multi-megabyte audit line. This is the number-one cause of audit-induced disk exhaustion.

---

## 3. The `Policy` object — complete field reference and evaluation semantics

### 3.1 Evaluation semantics (memorize these)

1. Rules are evaluated **top to bottom**. The **first rule that matches wins**; evaluation stops.
2. If **no rule matches**, the event is **dropped** (implicit `None`). There is no implicit catch-all.
3. Within a rule, all specified selectors are **AND**-ed; the values inside one selector are **OR**-ed.
4. An **omitted** selector matches everything (`verbs` omitted = all verbs).
5. `namespaces: [""]` (empty string element) matches **cluster-scoped** resources. `namespaces: []` / omitted matches **all** namespaces.
6. `nonResourceURLs` supports a trailing `*` wildcard only (`/healthz*`), and cannot be combined with `resources` in the same rule.
7. Subresources are expressed as `pods/exec`, `pods/log`, `serviceaccounts/token` inside `resources`.
8. Order is a **security control**: a `None` rule for `system:kube-scheduler` placed above your `Metadata` catch-all is how you cut 80 % of volume — but placing a broad `None` too early is how you create an audit blind spot an attacker can hide in (e.g. `None` for the whole `system:serviceaccounts` group).

### 3.2 Full schema

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# Stages omitted for EVERY rule. Per-rule omitStages is additive to this.
omitStages:
  - "RequestReceived"

# Strip metadata.managedFields from request/response bodies (huge noise reducer).
# Available cluster-wide here, or per rule.
omitManagedFields: true

rules:
  - level: RequestResponse            # None | Metadata | Request | RequestResponse

    # ── Subject selectors (OR within each list, AND across lists) ──────────────
    users:                            # exact authenticated usernames
      - "system:serviceaccount:ci:deployer"
      - "alice@example.com"
    userGroups:                       # any group returned by the authenticator
      - "system:masters"
      - "oidc:platform-admins"

    # ── Verb selector ─────────────────────────────────────────────────────────
    verbs:                            # get list watch create update patch delete
      - create                        # deletecollection proxy impersonate
      - update
      - patch
      - delete

    # ── Resource selector (mutually exclusive with nonResourceURLs) ───────────
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
        resourceNames: []             # [] = all names; else exact names only
      - group: ""                     # core API group
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

    # ── Namespace selector ────────────────────────────────────────────────────
    namespaces:                       # [] = all; [""] = cluster-scoped only
      - "prod"
      - "payments"

    # ── Non-resource selector (mutually exclusive with resources) ─────────────
    # nonResourceURLs:
    #   - "/healthz*"
    #   - "/metrics"
    #   - "/version"

    # ── Per-rule overrides ────────────────────────────────────────────────────
    omitStages:
      - "RequestReceived"
    omitManagedFields: true
```

---

## 4. Trade-off tables

### 4.1 Backend comparison

| Dimension | **Log backend** (`--audit-log-path`) | **Webhook backend** (`--audit-webhook-config-file`) |
|---|---|---|
| Destination | Local file on the control-plane node, or `stdout` (`-`) | HTTPS `POST` of `audit.k8s.io/v1 EventList` batches |
| Default mode | `blocking` | `batch` |
| Failure blast radius | Disk full / IO stall → **API requests block** | Endpoint down → retries with backoff; in `blocking` mode → **API latency injection** |
| Rotation | Built-in (lumberjack): `maxsize`/`maxbackup`/`maxage`/`compress` | N/A |
| Delivery guarantee | At-least-once to disk (blocking) | Best-effort; events dropped when buffer overflows |
| Ordering | Strict per apiserver | Per batch, not global |
| Ops burden | Needs a shipper (Fluent Bit / Vector / Filebeat) | Needs a highly available receiver |
| Survives node loss | ❌ unless shipped | ✅ (already off-node) |
| CKS exam relevance | **High** — this is what is tested | Low — read-only knowledge |
| Recommended for prod | ✅ log backend + node shipper (decouples apiserver from SIEM availability) | Only with a local, in-cluster, HA receiver |

**Architect's verdict:** use the **log backend in `batch` mode** with a node-local shipper. Never make control-plane availability depend on your SIEM's uptime. The webhook backend is appropriate only when the receiver is a local sidecar/DaemonSet with a sub-millisecond path.

### 4.2 Mode comparison

| `--audit-log-mode` / `--audit-webhook-mode` | Semantics | Event loss on crash | API latency impact | Use when |
|---|---|---|---|---|
| `blocking` | Handler waits for the backend write; **backend errors are logged but the request still succeeds** | Minimal | Direct — backend latency adds to every audited request | Compliance requires no gaps and the backend is a local SSD |
| `blocking-strict` | As `blocking`, **but a failure at `RequestReceived` fails the request itself (HTTP 500)** | None (fail-closed) | Direct, plus availability risk | Regulated environments that mandate "no audit ⇒ no operation" |
| `batch` | Events buffered in memory, flushed asynchronously by size or timer | Up to `batch-buffer-size` events | Negligible | **Default recommendation for large clusters** |

`blocking-strict` is the fail-closed posture. It is correct for a payments cluster and catastrophic for a dev cluster whose `/var/log` is a 2 GiB tmpfs.

### 4.3 Volume and cost model per level

Estimate before you enable. The formula:

```
bytes/day = events_per_second × 86400 × avg_bytes_per_event × compression_factor
```

| Policy shape | Typical events/s (100-node, 3 000-pod cluster) | Avg bytes/event | Uncompressed/day | Notes |
|---|---|---|---|---|
| `Metadata` catch-all, no `None` rules | 1 500 – 4 000 | ~1.2 KB | **150 – 400 GB** | Dominated by controller-manager/scheduler `watch` + kubelet `get node` |
| Same, with `None` for system components + `/healthz*` + read-only noise | 150 – 400 | ~1.3 KB | **17 – 45 GB** | ~10× reduction; the single highest-leverage tuning step |
| Tiered policy (§5.2) | 100 – 300 | ~2.5 KB | **20 – 65 GB** | `RequestResponse` only on RBAC + admission objects |
| `RequestResponse` catch-all | 1 500 – 4 000 | 8 – 60 KB | **1 – 20 TB** | Will fill the disk and take down etcd. Never do this. |

`--audit-log-compress` typically yields **8–12×** on JSON audit data (highly repetitive keys).

### 4.4 Audit logs vs. adjacent controls

| Capability | Audit log | `v1.Event` | Falco / eBPF | Cloud provider control-plane log |
|---|---|---|---|---|
| Attributes an action to an identity | ✅ (authenticated user + groups + SA) | ❌ | Partial (uid/pod) | ✅ |
| Records the *intent* (declarative object) | ✅ | ❌ | ❌ | ✅ |
| Records syscalls / process exec inside a container | ❌ | ❌ | ✅ | ❌ |
| Detects `etcdctl` direct reads | ❌ | ❌ | ✅ (file/process) | ❌ |
| Detects kubelet-direct exec | ❌ | ❌ | ✅ | ❌ |
| Real-time alerting | Needs external pipeline | ❌ | ✅ built-in | Needs external pipeline |
| Retention under your control | ✅ | ❌ (1 h) | ✅ | Provider-dependent |
| Configurable on managed control planes (EKS/GKE/AKS) | Provider flag only — **policy usually not customizable** | ✅ | ✅ | ✅ |

> **Managed-cluster reality check:** on EKS you toggle `audit` in `logging.clusterLogging` and get AWS's fixed policy in CloudWatch; on GKE you get Cloud Audit Logs with `ADMIN_READ`/`DATA_READ`/`DATA_WRITE` categories. You cannot supply your own `Policy` file. The CKS exam always uses **kubeadm**, where you can.

---

## 5. Complete manifests and infrastructure

### 5.1 Minimal policy (exam-grade baseline)

`/etc/kubernetes/audit/policy.yaml`

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Full request+response for anything touching Secrets metadata is FORBIDDEN;
  #    Secrets are logged at Metadata only, so no secret material ever lands on disk.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]

  # 2. Interactive access to workloads — the highest-signal event class.
  - level: RequestResponse
    verbs: ["create"]
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 3. Everything else at Metadata.
  - level: Metadata
```

### 5.2 Production tiered policy (original, annotated)

`/etc/kubernetes/audit/policy.yaml`

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# RequestReceived doubles volume and carries no outcome. Drop it globally.
omitStages:
  - "RequestReceived"

# Strip metadata.managedFields (server-side apply bookkeeping). On a busy
# cluster this alone removes 30-60% of the bytes in Request/RequestResponse events.
omitManagedFields: true

rules:
  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 0 — NOISE SUPPRESSION.
  # These MUST come first. Every rule below is a deliberate blind spot: keep the
  # selectors as tight as possible (specific user AND specific verb AND specific
  # resource) so an attacker cannot hide inside them by impersonating a group.
  # ═══════════════════════════════════════════════════════════════════════════

  # Kubelet steady-state reads. Note: writes by kubelets are NOT suppressed.
  - level: None
    users: ["system:kubelet"]
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status", "pods", "services", "endpoints"]
      - group: "discovery.k8s.io"
        resources: ["endpointslices"]

  # Core controllers' read/watch loops (they generate the bulk of the traffic).
  - level: None
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:apiserver"
      - "system:serviceaccount:kube-system:endpoint-controller"
      - "system:serviceaccount:kube-system:endpointslice-controller"
      - "system:serviceaccount:kube-system:generic-garbage-collector"
      - "system:serviceaccount:kube-system:namespace-controller"
      - "system:serviceaccount:kube-system:resourcequota-controller"
    verbs: ["get", "list", "watch"]

  # Leader-election churn: one write every 2s per controller, forever.
  - level: None
    verbs: ["get", "update", "patch"]
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]
    namespaces: ["kube-system", "kube-node-lease"]

  # Health/discovery/metrics endpoints hit by every probe and scraper.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
      - "/metrics"
      - "/openapi*"
      - "/apis*"
      - "/api"
      - "/api/v1"

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 1 — SECRET-BEARING RESOURCES: Metadata ONLY, never the body.
  # This rule MUST appear before any broad RequestResponse rule, otherwise a
  # later wildcard would dump credential material to disk.
  # ═══════════════════════════════════════════════════════════════════════════
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews", "selfsubjectreviews"]
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests", "certificatesigningrequests/approval"]

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 2 — PRIVILEGE AND POLICY CHANGES: full fidelity, both directions.
  # These objects are small, rare, and are the payload of every escalation.
  # ═══════════════════════════════════════════════════════════════════════════
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
      - group: "admissionregistration.k8s.io"
        resources:
          - "validatingwebhookconfigurations"
          - "mutatingwebhookconfigurations"
          - "validatingadmissionpolicies"
          - "validatingadmissionpolicybindings"
      - group: "policy"
        resources: ["poddisruptionbudgets"]
      - group: "networking.k8s.io"
        resources: ["networkpolicies"]
      - group: "apiextensions.k8s.io"
        resources: ["customresourcedefinitions"]
      - group: "apiregistration.k8s.io"
        resources: ["apiservices"]
      - group: "node.k8s.io"
        resources: ["runtimeclasses"]

  # Namespace lifecycle and PSA label changes (a relabel to `privileged` is an
  # escalation vector and is invisible at Metadata level).
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["namespaces", "namespaces/status", "namespaces/finalize"]

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 3 — INTERACTIVE / DATA-PLANE ACCESS.
  # ═══════════════════════════════════════════════════════════════════════════
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
          - "nodes/log"
          - "pods/eviction"
          - "pods/ephemeralcontainers"   # debug containers = code exec in a live pod

  # Reading logs can exfiltrate application data; record it, but Metadata is enough.
  - level: Metadata
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["pods/log"]

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 4 — ALL OTHER WRITES: request body, no response (halves the bytes and
  # avoids echoing back server-populated fields we already know).
  # ═══════════════════════════════════════════════════════════════════════════
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""                      # core
      - group: "apps"
      - group: "batch"
      - group: "autoscaling"
      - group: "storage.k8s.io"
      - group: "scheduling.k8s.io"

  # Writes to any other (including custom) API group.
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 5 — CATCH-ALL. Without this, unmatched events are silently dropped.
  # ═══════════════════════════════════════════════════════════════════════════
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

### 5.3 Complete `kube-apiserver` static Pod manifest

`/etc/kubernetes/manifests/kube-apiserver.yaml` — the audit-relevant additions are marked `# AUDIT`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.0.10:6443
  creationTimestamp: null
  labels:
    component: kube-apiserver
    tier: control-plane
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=10.0.0.10
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --enable-bootstrap-token-auth=true
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
    - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    - --secure-port=6443
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-cluster-ip-range=10.96.0.0/12
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    # ─────────────────────────── AUDIT ───────────────────────────
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml      # AUDIT
    - --audit-log-path=/var/log/kubernetes/audit/audit.log       # AUDIT
    - --audit-log-format=json                                    # AUDIT (default)
    - --audit-log-maxage=30                                      # AUDIT: CIS — days
    - --audit-log-maxbackup=10                                   # AUDIT: CIS — files
    - --audit-log-maxsize=100                                    # AUDIT: CIS — MiB
    - --audit-log-compress=true                                  # AUDIT: gzip rotated
    - --audit-log-mode=batch                                     # AUDIT
    - --audit-log-batch-buffer-size=20000                        # AUDIT
    - --audit-log-batch-max-size=500                             # AUDIT
    - --audit-log-batch-max-wait=5s                              # AUDIT
    - --audit-log-batch-throttle-enable=true                     # AUDIT
    - --audit-log-batch-throttle-qps=50                          # AUDIT
    - --audit-log-batch-throttle-burst=100                       # AUDIT
    - --audit-log-truncate-enabled=true                          # AUDIT: cap giant events
    - --audit-log-truncate-max-event-size=204800                 # AUDIT: 200 KiB
    - --audit-log-truncate-max-batch-size=10485760               # AUDIT: 10 MiB
    # ─────────────────────────────────────────────────────────────
    image: registry.k8s.io/kube-apiserver:v1.34.0
    imagePullPolicy: IfNotPresent
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
    name: kube-apiserver
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 10.0.0.10
        path: /readyz
        port: 6443
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 250m
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 10.0.0.10
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/pki
      name: etc-pki
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    # ─────────────────────────── AUDIT ───────────────────────────
    - mountPath: /etc/kubernetes/audit                           # AUDIT
      name: audit-policy                                         # AUDIT
      readOnly: true                                             # AUDIT: policy is RO
    - mountPath: /var/log/kubernetes/audit                       # AUDIT
      name: audit-logs                                           # AUDIT
      readOnly: false                                            # AUDIT: MUST be writable
    # ─────────────────────────────────────────────────────────────
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /etc/ssl/certs
      type: DirectoryOrCreate
    name: ca-certs
  - hostPath:
      path: /etc/pki
      type: DirectoryOrCreate
    name: etc-pki
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
  # ─────────────────────────── AUDIT ───────────────────────────
  - hostPath:                                                    # AUDIT
      path: /etc/kubernetes/audit                                # AUDIT
      type: DirectoryOrCreate                                    # AUDIT
    name: audit-policy                                           # AUDIT
  - hostPath:                                                    # AUDIT
      path: /var/log/kubernetes/audit                            # AUDIT
      type: DirectoryOrCreate                                    # AUDIT: NOT FileOrCreate
    name: audit-logs                                             # AUDIT
  # ─────────────────────────────────────────────────────────────
status: {}
```

> **Two failure modes hidden in that manifest.**
> **(a)** Mount the **directory**, not the file. If you use `hostPath.type: FileOrCreate` on `audit.log` and mount the file directly, the container sees a bind mount to a specific inode; when lumberjack rotates by *renaming* the file, the apiserver keeps writing to the now-unlinked inode and your live `audit.log` on the host stops growing.
> **(b)** `readOnly: true` on `audit-logs` yields `permission denied` at startup and the apiserver never becomes ready. Only the *policy* mount is read-only.

### 5.4 Surviving `kubeadm upgrade` — declarative configuration

Editing the static Pod by hand is what the exam asks for, but `kubeadm upgrade apply` regenerates that file from the cluster's `ClusterConfiguration`. Persist the change in the `kubeadm-config` ConfigMap instead (API `v1beta4`, current for 1.31+ — note that `extraArgs` is a **list of `{name, value}`**, not a map):

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.0
apiServer:
  extraArgs:
    - name: audit-policy-file
      value: /etc/kubernetes/audit/policy.yaml
    - name: audit-log-path
      value: /var/log/kubernetes/audit/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: audit-log-compress
      value: "true"
    - name: audit-log-mode
      value: batch
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit
      mountPath: /etc/kubernetes/audit
      readOnly: true
      pathType: DirectoryOrCreate
    - name: audit-logs
      hostPath: /var/log/kubernetes/audit
      mountPath: /var/log/kubernetes/audit
      readOnly: false
      pathType: DirectoryOrCreate
```

```bash
$ sudo kubeadm init phase control-plane apiserver --config /root/kubeadm-audit.yaml
W0806 09:02:11.441233   18422 common.go:101] WARNING: Usage of the --config flag with kubeadm init phase is deprecated for some phases
[control-plane] Using manifest folder "/etc/kubernetes/manifests"
[control-plane] Creating static Pod manifest for "kube-apiserver"
```

### 5.5 Webhook backend (dynamic shipping to a SIEM)

`--audit-webhook-config-file` takes a **kubeconfig-shaped** file whose `cluster.server` is the receiver URL:

`/etc/kubernetes/audit/webhook-kubeconfig.yaml`

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: audit-sink
    cluster:
      server: https://audit-sink.observability.svc.cluster.local:8443/events
      certificate-authority: /etc/kubernetes/audit/sink-ca.crt
users:
  - name: kube-apiserver
    user:
      client-certificate: /etc/kubernetes/pki/apiserver.crt
      client-key: /etc/kubernetes/pki/apiserver.key
current-context: audit-sink
contexts:
  - name: audit-sink
    context:
      cluster: audit-sink
      user: kube-apiserver
```

Corresponding flags:

```
- --audit-webhook-config-file=/etc/kubernetes/audit/webhook-kubeconfig.yaml
- --audit-webhook-mode=batch
- --audit-webhook-batch-max-size=400
- --audit-webhook-batch-max-wait=30s
- --audit-webhook-initial-backoff=10s
- --audit-webhook-truncate-enabled=true
- --audit-webhook-truncate-max-event-size=102400
```

The receiver gets `POST` bodies of `{"apiVersion":"audit.k8s.io/v1","kind":"EventList","items":[...]}`.

> Log and webhook backends can be enabled **simultaneously** — the apiserver fans out to a union backend. A common pattern is: log backend to disk for forensic retention + webhook to a local Falco `k8saudit` plugin for real-time detection.

### 5.6 Shipping the log off the node — Fluent Bit DaemonSet

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: audit-shipper
  namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: audit-shipper-config
  namespace: observability
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush             5
        Daemon            Off
        Log_Level         info
        Parsers_File      parsers.conf
        HTTP_Server       On
        HTTP_Listen       0.0.0.0
        HTTP_Port         2020
        storage.path      /var/lib/fluent-bit/state
        storage.sync      normal
        storage.backlog.mem_limit 64M

    [INPUT]
        Name              tail
        Alias             k8s_audit
        Tag               k8s.audit
        Path              /var/log/kubernetes/audit/audit.log
        Parser            audit_json
        DB                /var/lib/fluent-bit/state/audit.db
        DB.locking        true
        Mem_Buf_Limit     128MB
        storage.type      filesystem
        Refresh_Interval  5
        Skip_Long_Lines   On
        Buffer_Max_Size   2MB

    [FILTER]
        Name              record_modifier
        Match             k8s.audit
        Record            cluster prod-eu-west-1
        Record            source_node ${NODE_NAME}

    # Defence in depth: even though the policy forbids RequestResponse on
    # Secrets, strip any body that could carry credential material.
    [FILTER]
        Name              nest
        Match             k8s.audit
        Operation         lift
        Nested_under      objectRef
        Add_prefix        objectRef_

    [FILTER]
        Name              grep
        Match             k8s.audit
        Exclude           level RequestResponse
        # only applied to the redaction branch below in a real pipeline;
        # shown here to make the control explicit

    [OUTPUT]
        Name              opensearch
        Match             k8s.audit
        Host              opensearch.observability.svc.cluster.local
        Port              9200
        HTTP_User         ${OS_USER}
        HTTP_Passwd       ${OS_PASSWORD}
        tls               On
        tls.verify        On
        tls.ca_file       /etc/ssl/certs/ca-certificates.crt
        Index             k8s-audit
        Logstash_Format   On
        Logstash_Prefix   k8s-audit
        Time_Key          stageTimestamp
        Retry_Limit       False
        Replace_Dots      On

  parsers.conf: |
    [PARSER]
        Name        audit_json
        Format      json
        Time_Key    stageTimestamp
        Time_Format %Y-%m-%dT%H:%M:%S.%LZ
        Time_Keep   On
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: audit-shipper
  namespace: observability
  labels:
    app.kubernetes.io/name: audit-shipper
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: audit-shipper
  template:
    metadata:
      labels:
        app.kubernetes.io/name: audit-shipper
    spec:
      serviceAccountName: audit-shipper
      priorityClassName: system-node-critical
      # Control-plane nodes only: that is where the audit log lives.
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      securityContext:
        runAsNonRoot: false          # must read root-owned 0600 audit.log
        runAsUser: 0
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          imagePullPolicy: IfNotPresent
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: OS_USER
              valueFrom:
                secretKeyRef:
                  name: opensearch-credentials
                  key: username
            - name: OS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: opensearch-credentials
                  key: password
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]   # read 0600 audit.log without full root FS access
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              memory: 512Mi
          ports:
            - name: http
              containerPort: 2020
          livenessProbe:
            httpGet:
              path: /api/v1/health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
          volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/fluent-bit.conf
              subPath: fluent-bit.conf
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc/parsers.conf
              subPath: parsers.conf
              readOnly: true
            - name: audit-logs
              mountPath: /var/log/kubernetes/audit
              readOnly: true
            - name: state
              mountPath: /var/lib/fluent-bit/state
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          configMap:
            name: audit-shipper-config
        - name: audit-logs
          hostPath:
            path: /var/log/kubernetes/audit
            type: Directory
        - name: state
          hostPath:
            path: /var/lib/fluent-bit/state
            type: DirectoryOrCreate
        - name: tmp
          emptyDir: {}
```

> **Security note on the shipper:** it mounts a host path containing every identity that touched the cluster and runs on the control plane. It is itself a high-value target. Mount `readOnly: true`, drop all capabilities except `DAC_READ_SEARCH`, set `readOnlyRootFilesystem: true`, and never give it a ServiceAccount with cluster read permissions.

---

## 6. Applying it and reading real output

### 6.1 Preparing the node

```bash
$ sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
$ sudo chmod 0700 /var/log/kubernetes/audit
$ sudo vi /etc/kubernetes/audit/policy.yaml
$ sudo chmod 0600 /etc/kubernetes/audit/policy.yaml

$ ls -la /etc/kubernetes/audit/
total 12
drwxr-xr-x  2 root root 4096 Aug  6 09:01 .
drwxr-xr-x  5 root root 4096 Aug  6 09:00 ..
-rw-------  1 root root 3187 Aug  6 09:01 policy.yaml
```

Validate the YAML **before** touching the static Pod — an invalid policy is an apiserver that will not start:

```bash
$ python3 -c 'import yaml,sys; d=yaml.safe_load(open("/etc/kubernetes/audit/policy.yaml")); print(d["apiVersion"], d["kind"], len(d["rules"]), "rules")'
audit.k8s.io/v1 Policy 14 rules
```

### 6.2 Editing the static Pod and watching the restart

```bash
$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

The kubelet detects the mtime change within its `--file-check-frequency` (default 20 s) and recreates the Pod. Expect the API to be unavailable for 15–60 s:

```bash
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT   POD ID         POD
2f9a11c7d3b80  8c9a5f2ed12b4  18 seconds ago  Running   kube-apiserver   3         a71c4e2b90f13  kube-apiserver-cp-01

$ kubectl get --raw='/readyz?verbose' | tail -5
[+]shutdown ok
[+]etcd ok
[+]poststarthook/start-kube-apiserver-admission-initializer ok
[+]autoregister-completion ok
readyz check passed
```

### 6.3 Confirming the flags took effect

```bash
$ kubectl -n kube-system get pod kube-apiserver-cp-01 \
    -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep -- --audit
"--audit-policy-file=/etc/kubernetes/audit/policy.yaml"
"--audit-log-path=/var/log/kubernetes/audit/audit.log"
"--audit-log-format=json"
"--audit-log-maxage=30"
"--audit-log-maxbackup=10"
"--audit-log-maxsize=100"
"--audit-log-compress=true"
"--audit-log-mode=batch"
```

```bash
$ sudo ls -la /var/log/kubernetes/audit/
total 8412
drwx------ 2 root root    4096 Aug  6 09:14 .
drwxr-xr-x 3 root root    4096 Aug  6 09:03 ..
-rw------- 1 root root 8598143 Aug  6 09:16 audit.log
```

### 6.4 Generating a signal and finding it

```bash
$ kubectl -n prod exec -it payments-7d9c8f5b6-x2k4t -c app -- sh -c 'id'
uid=1000(app) gid=1000(app) groups=1000(app)
```

```bash
$ sudo grep -F '"subresource":"exec"' /var/log/kubernetes/audit/audit.log | tail -1 | jq .
```

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "auditID": "b9f0c1a4-6e7a-4a1a-9b0f-2c3d4e5f6a7b",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/prod/pods/payments-7d9c8f5b6-x2k4t/exec?command=sh&command=-c&command=id&container=app&stdin=true&stdout=true&tty=true",
  "verb": "create",
  "user": {
    "username": "alice@example.com",
    "uid": "8f2c1d90-4b77-4d2e-9a01-77c3f5e1a2b4",
    "groups": [
      "oidc:sre",
      "system:authenticated"
    ]
  },
  "sourceIPs": [
    "10.0.3.44",
    "192.0.2.17"
  ],
  "userAgent": "kubectl/v1.34.0 (linux/amd64) kubernetes/f3a4c19",
  "objectRef": {
    "resource": "pods",
    "namespace": "prod",
    "name": "payments-7d9c8f5b6-x2k4t",
    "apiVersion": "v1",
    "subresource": "exec"
  },
  "responseStatus": {
    "metadata": {},
    "code": 101
  },
  "requestReceivedTimestamp": "2026-08-06T09:14:22.118374Z",
  "stageTimestamp": "2026-08-06T09:14:24.902611Z",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RBAC: allowed by RoleBinding \"sre-exec\" of Role \"pod-exec\" to Group \"oidc:sre\"",
    "pod-security.kubernetes.io/enforce-policy": "restricted:latest"
  }
}
```

**How to read this event, field by field:**

| Field | Forensic meaning |
|---|---|
| `auditID` | Correlates the `ResponseStarted` and `ResponseComplete` events of the same request. Also returned to the client in the `Audit-Id` HTTP response header. |
| `stage` | `ResponseComplete` here — the session ended. If you only ever see `ResponseStarted` for an exec, the session is still open or the apiserver died mid-stream. |
| `verb: create` on `pods/exec` | `exec` is modelled as a **create** on a subresource, not as `get`. RBAC rules for exec must therefore grant `create` on `pods/exec`. |
| `sourceIPs` | An **array**: the last element is the direct peer, preceding ones come from `X-Forwarded-For`. Two entries here means the request traversed a proxy/LB — `192.0.2.17` is the real client. |
| `userAgent` | Attacker tooling fingerprint. `kubectl/v1.20` on a 1.34 cluster, or a bare `Go-http-client/2.0`, is worth an alert. |
| `responseStatus.code: 101` | HTTP 101 Switching Protocols — SPDY/WebSocket upgrade. Normal for exec/attach/portforward. |
| `annotations["authorization.k8s.io/reason"]` | **The exact binding that granted access.** This is the fastest way to answer "why could they do that?" without replaying RBAC by hand. |
| `stageTimestamp − requestReceivedTimestamp` | Session duration: 2.78 s. |

### 6.5 Correlating a client request with its audit event

```bash
$ kubectl get secrets -n prod -v=8 2>&1 | grep -i 'audit-id'
I0806 09:21:07.884213   24118 round_trippers.go:553] Response Headers:
I0806 09:21:07.884261   24118 round_trippers.go:560]     Audit-Id: 4c1e77b2-9a03-41d5-bc8e-0f3ab5d21e77
```

```bash
$ sudo jq -c 'select(.auditID=="4c1e77b2-9a03-41d5-bc8e-0f3ab5d21e77")' \
    /var/log/kubernetes/audit/audit.log
{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata","auditID":"4c1e77b2-9a03-41d5-bc8e-0f3ab5d21e77","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/prod/secrets?limit=500","verb":"list","user":{"username":"alice@example.com","groups":["oidc:sre","system:authenticated"]},"sourceIPs":["10.0.3.44"],"userAgent":"kubectl/v1.34.0 (linux/amd64) kubernetes/f3a4c19","objectRef":{"resource":"secrets","namespace":"prod","apiVersion":"v1"},"responseStatus":{"metadata":{},"code":200},"requestReceivedTimestamp":"2026-08-06T09:21:07.871402Z","stageTimestamp":"2026-08-06T09:21:07.883901Z","annotations":{"authorization.k8s.io/decision":"allow","authorization.k8s.io/reason":"RBAC: allowed by ClusterRoleBinding \"sre-readers\" of ClusterRole \"secret-reader\" to Group \"oidc:sre\""}}
```

Note the `level: Metadata` — the Tier-1 rule prevented the Secret payloads from being written. That is the policy doing its job.

---

## 7. Analysis recipes (`jq`) — the detection playbook

All examples assume `AUDIT=/var/log/kubernetes/audit/audit.log`.

**Every `exec`/`attach`/`portforward`, with who and where:**

```bash
$ sudo jq -r 'select(.objectRef.subresource | IN("exec","attach","portforward"))
  | select(.stage=="ResponseComplete")
  | [.stageTimestamp, .user.username, .sourceIPs[0], .objectRef.namespace,
     .objectRef.name, .objectRef.subresource] | @tsv' $AUDIT | column -t
2026-08-06T09:14:24.902611Z  alice@example.com                       10.0.3.44  prod     payments-7d9c8f5b6-x2k4t  exec
2026-08-06T09:33:02.114887Z  system:serviceaccount:ci:deployer       10.0.5.12  staging  migrate-job-2xk9d         exec
2026-08-06T10:02:41.559130Z  bob@example.com                         10.0.3.51  prod     redis-0                   portforward
```

**Anyone who read Secrets, ranked:**

```bash
$ sudo jq -r 'select(.objectRef.resource=="secrets")
  | select(.verb | IN("get","list","watch"))
  | select(.stage=="ResponseComplete")
  | .user.username' $AUDIT | sort | uniq -c | sort -rn | head
   4412 system:kube-controller-manager
    881 system:serviceaccount:kube-system:token-cleaner
    140 system:serviceaccount:argocd:argocd-application-controller
     37 alice@example.com
      6 system:serviceaccount:default:default        <-- investigate
```

`system:serviceaccount:default:default` reading Secrets is a strong indicator of a compromised workload using the auto-mounted default token.

**Authorization denials (failed access attempts / reconnaissance):**

```bash
$ sudo jq -r 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
  | [.stageTimestamp, .user.username, .verb,
     (.objectRef.resource // .requestURI), (.objectRef.namespace // "-")] | @tsv' \
  $AUDIT | tail -8 | column -t
2026-08-06T10:41:03.220914Z  system:serviceaccount:default:default  list    secrets              kube-system
2026-08-06T10:41:03.418772Z  system:serviceaccount:default:default  create  clusterrolebindings  -
2026-08-06T10:41:03.611305Z  system:serviceaccount:default:default  create  pods/exec            kube-system
2026-08-06T10:41:03.809441Z  system:serviceaccount:default:default  get     nodes/proxy          -
```

Four escalation probes in 600 ms from a default ServiceAccount: that is an automated privilege-escalation scanner (`kubectl auth can-i --list` style enumeration or `peirates`/`kubeletmein`). **Denied requests are the highest-signal, lowest-volume class in the entire log — alert on them first.**

**Anonymous and unauthenticated access:**

```bash
$ sudo jq -r 'select(.user.username=="system:anonymous"
              or (.user.groups // [] | index("system:unauthenticated")))
  | [.stageTimestamp, .sourceIPs[0], .verb, .requestURI, .responseStatus.code] | @tsv' \
  $AUDIT | grep -v '/healthz\|/livez\|/readyz\|/version' | head
2026-08-06T11:07:55.331902Z  198.51.100.9  get  /api/v1/namespaces/kube-system/secrets  403
2026-08-06T11:07:55.702118Z  198.51.100.9  get  /apis                                    200
```

**Impersonation (a legitimate but frequently abused escalation path):**

```bash
$ sudo jq -r 'select(.impersonatedUser != null)
  | [.stageTimestamp, .user.username, "->", .impersonatedUser.username,
     ((.impersonatedUser.groups // []) | join(",")), .verb,
     (.objectRef.resource // "-")] | @tsv' $AUDIT | column -t
2026-08-06T11:22:14.008412Z  ops@example.com  ->  system:serviceaccount:kube-system:clusterrole-aggregation-controller  system:serviceaccounts  create  clusterroles
```

A human impersonating a privileged ServiceAccount to create ClusterRoles is exactly the pattern RBAC review misses and the audit log catches.

**RBAC escalations with full object (thanks to Tier 2 `RequestResponse`):**

```bash
$ sudo jq -r 'select(.objectRef.resource=="clusterrolebindings")
  | select(.verb=="create")
  | select(.stage=="ResponseComplete")
  | "\(.stageTimestamp)  \(.user.username)  bound  \(.requestObject.roleRef.name)  to  \(
      [.requestObject.subjects[]? | "\(.kind)/\(.namespace // "-")/\(.name)"] | join(", "))"' \
  $AUDIT
2026-08-06T11:41:07.882301Z  system:serviceaccount:default:default  bound  cluster-admin  to  ServiceAccount/default/default
```

That single line is the whole incident.

**Writes to workloads in a protected namespace, excluding the expected CI identity:**

```bash
$ sudo jq -r 'select(.objectRef.namespace=="prod")
  | select(.verb | IN("create","update","patch","delete","deletecollection"))
  | select(.user.username != "system:serviceaccount:ci:deployer")
  | select((.user.username | startswith("system:")) | not)
  | [.stageTimestamp, .user.username, .verb, .objectRef.resource, .objectRef.name] | @tsv' \
  $AUDIT | column -t
2026-08-06T12:03:19.771204Z  carol@example.com  patch   deployments  payments
2026-08-06T12:05:02.113990Z  carol@example.com  delete  pods         payments-7d9c8f5b6-x2k4t
```

**Deprecated / removed API usage before an upgrade:**

```bash
$ sudo jq -r 'select(.annotations["k8s.io/deprecated"]=="true")
  | [.userAgent, .objectRef.apiGroup, .objectRef.apiVersion, .objectRef.resource,
     (.annotations["k8s.io/removed-release"] // "-")] | @tsv' $AUDIT \
  | sort | uniq -c | sort -rn
     37  helm/v3.11.0  flowcontrol.apiserver.k8s.io  v1beta3  flowschemas  1.35
      4  legacy-operator/0.9  batch                   v1beta1  cronjobs     1.25
```

**API server latency attribution (SRE use of the same data):**

```bash
$ sudo jq -r 'select(.annotations["apiserver.latency.k8s.io/total"] != null)
  | [.verb, (.objectRef.resource // .requestURI),
     .annotations["apiserver.latency.k8s.io/total"],
     (.annotations["apiserver.latency.k8s.io/etcd"] // "-"),
     (.annotations["apiserver.latency.k8s.io/validating-admission-controller"] // "-")] | @tsv' \
  $AUDIT | sort -k3 -r | head -5 | column -t
list    pods                 4.812s  4.611s  1.2ms
create  pods                 1.944s  31ms    1.881s   <-- a slow validating webhook
```

**Top talkers, for policy tuning:**

```bash
$ sudo jq -r '"\(.user.username)|\(.verb)|\(.objectRef.resource // .requestURI)"' $AUDIT \
  | sort | uniq -c | sort -rn | head -10
  92411 system:kube-controller-manager|watch|leases
  41880 system:serviceaccount:monitoring:prometheus-k8s|list|pods
  17402 system:kubelet|patch|nodes/status
   9911 system:serviceaccount:argocd:argocd-repo-server|list|applications
```

Each of those lines is a candidate `level: None` rule — with the caveat from §5.2 that every suppression is a deliberate blind spot.

**Real-time tailing during an incident:**

```bash
$ sudo tail -F /var/log/kubernetes/audit/audit.log \
  | jq -r --unbuffered 'select(.stage=="ResponseComplete")
      | select(.user.username | startswith("system:") | not)
      | "\(.stageTimestamp[11:19])  \(.user.username)  \(.verb)  \(.objectRef.resource // .requestURI)/\(.objectRef.name // "")  [\(.responseStatus.code)]"'
09:41:12  alice@example.com  list    pods/                  [200]
09:41:19  alice@example.com  create  pods/exec/redis-0      [101]
09:41:44  mallory@example.com create clusterrolebindings/x  [403]
```

---

## 8. Verification and failure diagnosis

### 8.1 The five-step verification protocol

```bash
# 1. The policy file exists on the HOST and is valid YAML with the right apiVersion.
$ sudo head -3 /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:

# 2. The apiserver Pod is Running and its restart count is stable.
$ kubectl -n kube-system get pod -l component=kube-apiserver -o wide
NAME                   READY   STATUS    RESTARTS      AGE   IP          NODE
kube-apiserver-cp-01   1/1     Running   3 (4m2s ago)  4m2s  10.0.0.10   cp-01

# 3. The flags are present on the running container.
$ kubectl -n kube-system get pod kube-apiserver-cp-01 -o yaml | grep -c -- '--audit'
8

# 4. The policy file is visible INSIDE the container (volumeMount, not just volume).
$ sudo crictl exec -it $(sudo crictl ps -q --name kube-apiserver) \
    ls -l /etc/kubernetes/audit/policy.yaml
-rw------- 1 root root 3187 Aug  6 09:01 /etc/kubernetes/audit/policy.yaml

# 5. The log is growing and contains a signal you just generated.
$ kubectl get secrets -A >/dev/null
$ sudo jq -c 'select(.objectRef.resource=="secrets" and .verb=="list")' \
    /var/log/kubernetes/audit/audit.log | tail -1 | jq -r .user.username
kubernetes-admin
```

### 8.2 Failure catalogue

| Symptom | Representative log line / evidence | Root cause | Fix |
|---|---|---|---|
| apiserver Pod never appears; `kubectl` dead | `crictl ps -a` shows nothing named kube-apiserver | Static Pod YAML is syntactically invalid — kubelet won't even build the Pod | `journalctl -u kubelet -n 50` → `failed to parse manifest`; restore `/root/kube-apiserver.yaml.bak` |
| CrashLoopBackOff | `Error: loading audit policy file: failed to read file path "/etc/kubernetes/audit/policy.yaml": no such file or directory` | Volume declared but **`volumeMounts` entry missing**, or wrong `mountPath` | Add the `volumeMounts` entry; the two lists are independent |
| CrashLoopBackOff | `error converting YAML to JSON: yaml: line 12: did not find expected key` | Indentation error in policy | Validate with `python3 -c 'import yaml,...'` before restarting |
| CrashLoopBackOff | `no kind "Policy" is registered for version "audit.k8s.io/v1beta1"` | Wrong `apiVersion` (v1alpha1/v1beta1 removed) | Use `audit.k8s.io/v1` |
| CrashLoopBackOff | `unknown field "omitManagedField"` / `unknown field "resourceName"` | Field typo — the policy decoder is strict | Fix to `omitManagedFields` / `resourceNames` |
| CrashLoopBackOff | `failed to open audit log "/var/log/kubernetes/audit/audit.log": permission denied` | `readOnly: true` on the log `volumeMount`, or the directory doesn't exist and `type: Directory` was used | `readOnly: false`; use `type: DirectoryOrCreate` |
| Pod Running, `audit.log` never created | No error at all | `--audit-policy-file` set but `--audit-log-path` missing (or vice-versa) — **both are required** for the log backend | Add the missing flag |
| `audit.log` exists but is empty | File size stays 0 | Every rule is `level: None`, or no rule matches (no catch-all) | Add a terminal `- level: Metadata` |
| `audit.log` exists but is empty | File size stays 0 | `--audit-log-mode=batch` with a large `batch-max-wait` and low traffic | Wait for `batch-max-wait`, or `kubectl get pods` a few times |
| Log grows but your request is missing | — | An earlier `None` rule matched first | Re-read the rules top-down; first match wins |
| Log grows but your request is missing | — | HA control plane: the LB routed you to a different apiserver | Grep **all** control-plane nodes, or aggregate centrally |
| Log only has `RequestReceived` for an exec | No `ResponseComplete` | Session still open, or apiserver restarted mid-stream | Correlate by `auditID` across restarts |
| `/var` at 100 %, cluster degraded | `no space left on device` from etcd and apiserver | `RequestResponse` catch-all, or missing `maxsize`/`maxbackup` | Set the CIS rotation flags; tighten the policy; move `/var/log/kubernetes` to its own volume |
| p99 API latency jumped 10× after enabling audit | `apiserver_request_duration_seconds` up; `apiserver_audit_error_total` climbing | `blocking` mode + slow disk or slow webhook | Switch to `--audit-log-mode=batch`; move the webhook off the hot path |
| Requests failing with HTTP 500 | `rejected by audit backend` | `blocking-strict` + backend failure (fail-closed working as designed) | Fix the backend, or reconsider `blocking-strict` |
| Secrets visible in the SIEM | grep the index for `"data":` under `requestObject` | A `RequestResponse` rule matched `secrets` before the Tier-1 rule | Move the Metadata rule for secret-bearing resources **above** every `RequestResponse` rule; then **rotate every exposed Secret and purge the index** |

### 8.3 Reading apiserver startup errors when `kubectl` is down

The apiserver is the thing you broke, so `kubectl logs` is unavailable. Use the container runtime and the kubelet's on-disk log directory:

```bash
$ sudo crictl ps -a --name kube-apiserver --latest
CONTAINER      IMAGE          CREATED        STATE    NAME             ATTEMPT  POD ID
7d3c11ab9f042  8c9a5f2ed12b4  8 seconds ago  Exited   kube-apiserver   7        e2b1c9a70d443

$ sudo crictl logs 7d3c11ab9f042 2>&1 | tail -6
I0806 09:07:41.118203       1 options.go:221] external host was not specified, using 10.0.0.10
E0806 09:07:41.119884       1 run.go:74] "command failed" err="loading audit policy file: failed to read file path \"/etc/kubernetes/audit/policy.yaml\": open /etc/kubernetes/audit/policy.yaml: no such file or directory"

# Equivalent, without crictl:
$ sudo tail -20 /var/log/pods/kube-system_kube-apiserver-cp-01_*/kube-apiserver/*.log

# And the kubelet's view of why the Pod won't start:
$ sudo journalctl -u kubelet --since "-5 min" --no-pager | grep -i apiserver | tail -10
```

### 8.4 Prometheus signals to alert on

The apiserver exposes audit-subsystem metrics on `/metrics`:

```bash
$ kubectl get --raw /metrics | grep -E '^apiserver_audit' | grep -v '^#'
apiserver_audit_event_total 1847233
apiserver_audit_error_total{plugin="log"} 0
apiserver_audit_level_total{level="Metadata"} 1102847
apiserver_audit_level_total{level="Request"} 511209
apiserver_audit_level_total{level="RequestResponse"} 233177
apiserver_audit_requests_rejected_total{plugin="log"} 0
```

Recommended alerting rules:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kube-audit
  namespace: monitoring
  labels:
    role: alert-rules
spec:
  groups:
    - name: kubernetes-audit
      rules:
        # The audit trail stopped. This is a security incident, not a monitoring gap:
        # the first thing an attacker with control-plane access does is silence audit.
        - alert: KubeAuditEventsStopped
          expr: sum(rate(apiserver_audit_event_total[10m])) == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "No audit events emitted for 10 minutes — audit trail is blind"

        # Backend write failures: events are being lost right now.
        - alert: KubeAuditBackendErrors
          expr: sum(rate(apiserver_audit_error_total[5m])) by (plugin) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Audit backend {{ $labels.plugin }} is dropping events"

        # blocking-strict is rejecting API requests.
        - alert: KubeAuditRequestsRejected
          expr: sum(rate(apiserver_audit_requests_rejected_total[5m])) > 0
          for: 2m
          labels:
            severity: critical

        # Volume explosion — usually a policy change that widened a level.
        - alert: KubeAuditVolumeSpike
          expr: |
            sum(rate(apiserver_audit_event_total[15m]))
              > 3 * sum(rate(apiserver_audit_event_total[15m] offset 1d))
          for: 15m
          labels:
            severity: warning

        # Disk headroom on the control-plane audit volume.
        - alert: KubeAuditDiskPressure
          expr: |
            node_filesystem_avail_bytes{mountpoint="/var/log"}
              / node_filesystem_size_bytes{mountpoint="/var/log"} < 0.15
          for: 10m
          labels:
            severity: warning
```

> **The most important alert in that list is `KubeAuditEventsStopped`.** An adversary who can edit `/etc/kubernetes/manifests/kube-apiserver.yaml` will remove `--audit-log-path` before doing anything else. Detecting the *absence* of the trail is the control that survives that.

### 8.5 CIS Kubernetes Benchmark alignment

`kube-bench` checks the audit configuration under the `kube-apiserver` section (control numbers shift between benchmark releases; the requirements do not):

| Requirement | Flag | CIS-mandated value |
|---|---|---|
| Audit log enabled | `--audit-log-path` | set (non-empty) |
| Retention | `--audit-log-maxage` | `>= 30` |
| Backup count | `--audit-log-maxbackup` | `>= 10` |
| File size | `--audit-log-maxsize` | `>= 100` (MiB) |
| Policy present | `--audit-policy-file` | set |

```bash
$ kube-bench run --targets master --check 1.2.19,1.2.20,1.2.21,1.2.22 2>/dev/null | head -20
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[PASS] 1.2.19 Ensure that the --audit-log-path argument is set (Automated)
[PASS] 1.2.20 Ensure that the --audit-log-maxage argument is set to 30 or as appropriate (Automated)
[PASS] 1.2.21 Ensure that the --audit-log-maxbackup argument is set to 10 or as appropriate (Automated)
[PASS] 1.2.22 Ensure that the --audit-log-maxsize argument is set to 100 or as appropriate (Automated)

== Summary master ==
4 checks PASS
0 checks FAIL
```

---

## 9. Real-time detection: piping audit events into Falco

Falco's `k8saudit` plugin consumes the audit stream (webhook or file) and evaluates rules in real time, giving you alerting without an ELK stack.

`/etc/falco/falco.yaml` (extract):

```yaml
load_plugins: [k8saudit, json]

plugins:
  - name: k8saudit
    library_path: libk8saudit.so
    init_config:
      maxEventSize: 262144
      webhookMaxBatchSize: 12582912
    open_params: "http://:9765/k8s-audit"   # receives the apiserver webhook backend
  - name: json
    library_path: libjson.so

rules_file:
  - /etc/falco/k8s_audit_rules.yaml
  - /etc/falco/rules.d
```

Custom rule — alert on any `exec` into a namespace labelled as regulated:

```yaml
- macro: kevt
  condition: (jevt.value[/stage] in ("ResponseComplete","ResponseStarted"))

- macro: regulated_namespace
  condition: (ka.target.namespace in (prod, payments, pci))

- rule: Exec Into Regulated Namespace Pod
  desc: >
    An interactive session (exec/attach) was opened against a Pod in a
    regulated namespace. All such access must be preceded by an approved
    change ticket.
  condition: >
    kevt and ka.verb=create and
    ka.target.subresource in (exec, attach) and
    regulated_namespace
  output: >
    Interactive session opened in regulated namespace
    (user=%ka.user.name groups=%ka.user.groups ns=%ka.target.namespace
     pod=%ka.target.name sub=%ka.target.subresource
     cmd=%ka.uri.param[command] srcip=%ka.sourceips auditid=%ka.auditid)
  priority: WARNING
  source: k8s_audit
  tags: [k8s, access, pci]

- rule: ClusterRoleBinding To Cluster Admin
  desc: A binding to cluster-admin was created outside the platform pipeline.
  condition: >
    kevt and ka.verb=create and
    ka.target.resource=clusterrolebindings and
    ka.req.binding.role=cluster-admin and
    not ka.user.name in (system:serviceaccount:platform:rbac-operator)
  output: >
    cluster-admin granted (user=%ka.user.name subjects=%ka.req.binding.subjects
     name=%ka.target.name auditid=%ka.auditid)
  priority: CRITICAL
  source: k8s_audit
  tags: [k8s, rbac, escalation]
```

**Trade-off:** Falco gives you sub-second detection but no retention or ad-hoc query. The log backend gives you retention and query but no alerting. Production runs **both**: log backend → object storage (retention/compliance), webhook → Falco (detection).

---

## 10. CKS exam drills

The exam question is almost always a variant of: *"Enable audit logging on the control-plane node with a policy that logs X at level Y; keep 30 days / 10 backups / 100 MB; the log must be at `/var/log/kubernetes/audit/audit.log`."*

**Ordered muscle memory:**

```bash
# 0. ALWAYS back up first — a broken static Pod costs you the whole cluster.
$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak

# 1. Create the directories.
$ sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit

# 2. Write the policy (apiVersion: audit.k8s.io/v1 — kind: Policy — rules:).
$ sudo vi /etc/kubernetes/audit/policy.yaml

# 3. Edit the static Pod: add 3 things in 3 places.
#    (a) the --audit-* flags under .spec.containers[0].command
#    (b) volumeMounts under .spec.containers[0].volumeMounts
#    (c) volumes under .spec.volumes
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml

# 4. Wait for the restart and verify.
$ watch -n2 'sudo crictl ps --name kube-apiserver'
$ sudo ls -l /var/log/kubernetes/audit/audit.log
```

**The five mistakes that cost points:**

1. Adding the `volumes` but forgetting the `volumeMounts` (or vice versa). Three edits, always.
2. `readOnly: true` on the audit **log** mount.
3. Wrong `apiVersion` — it is `audit.k8s.io/v1`, not `v1beta1`, not `v1`.
4. Forgetting the final catch-all rule, so the log stays empty.
5. Not waiting long enough. The kubelet needs up to ~20 s to notice the file, plus ~20 s for the apiserver to become ready. `kubectl` will fail during that window — that is expected, not a mistake.

**Quick reference of the flag set the exam expects:**

```
--audit-policy-file=/etc/kubernetes/audit/policy.yaml
--audit-log-path=/var/log/kubernetes/audit/audit.log
--audit-log-maxage=30
--audit-log-maxbackup=10
--audit-log-maxsize=100
```

**Subresource cheat sheet for policy rules:**

| Action to audit | `verbs` | `resources[].resources` |
|---|---|---|
| Shell into a Pod | `create` | `pods/exec` |
| Attach to a running container | `create` | `pods/attach` |
| Port-forward | `create` | `pods/portforward` |
| Read Pod logs | `get` | `pods/log` |
| Add an ephemeral debug container | `update`, `patch` | `pods/ephemeralcontainers` |
| Proxy to a node's kubelet | `get`, `create` | `nodes/proxy` |
| Mint a ServiceAccount token | `create` | `serviceaccounts/token` |
| Delete a whole collection | `deletecollection` | any |

---

## 11. Operational checklist

- [ ] Policy file present, mode `0600`, root-owned, on **every** control-plane node.
- [ ] Policy is **identical** across all control-plane nodes (drift = inconsistent evidence).
- [ ] No rule emits `Request` or `RequestResponse` for `secrets`, `configmaps`, `tokenreviews`, `serviceaccounts/token`, or `certificatesigningrequests`.
- [ ] `omitStages: ["RequestReceived"]` set globally.
- [ ] `omitManagedFields: true` set globally.
- [ ] A terminal catch-all rule exists.
- [ ] `--audit-log-mode=batch` on clusters above ~50 nodes.
- [ ] Rotation flags meet CIS (`30` / `10` / `100`) and `--audit-log-compress=true`.
- [ ] `/var/log/kubernetes` is a **separate filesystem** from etcd's data directory.
- [ ] Logs are shipped off-node to write-once, immutable storage within minutes.
- [ ] Retention matches the compliance regime (PCI-DSS: 1 year, 3 months hot).
- [ ] `KubeAuditEventsStopped` alert is wired and tested by deliberately stopping the backend in staging.
- [ ] Denied-request alerting (`authorization.k8s.io/decision == "forbid"`) is in place.
- [ ] The policy file itself is under version control and change-reviewed; a PR that adds a `level: None` rule requires security sign-off.
- [ ] The shipper's host mount is `readOnly: true` with minimal capabilities.
- [ ] A quarterly exercise reconstructs a known action end-to-end from the archived logs (prove the evidence chain actually works before you need it).

---

## 12. References

- Kubernetes Documentation — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes API Reference — `audit.k8s.io/v1` `Policy` and `Event`: https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Kubernetes Documentation — `kube-apiserver` command-line reference (all `--audit-*` flags): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes Documentation — *Auditing with Audit Policy* (levels, stages, rule matching): https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/#audit-k8s-io-v1-Level
- Kubernetes Documentation — *Options for Highly Available Topology* (per-apiserver log locality): https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/
- Kubernetes Documentation — *Customizing components with the kubeadm API* (`extraArgs`, `extraVolumes`): https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/control-plane-flags/
- kubeadm API Reference — `kubeadm.k8s.io/v1beta4`: https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- Kubernetes Documentation — *Static Pods*: https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Kubernetes Documentation — *Kubernetes API Server Bypass Risks* (what audit does **not** cover): https://kubernetes.io/docs/concepts/security/api-server-bypass-risks/
- Kubernetes Documentation — *Deprecated API Migration Guide* (`k8s.io/deprecated` audit annotation): https://kubernetes.io/docs/reference/using-api/deprecation-guide/
- Kubernetes Documentation — *Pod Security Admission* (`pod-security.kubernetes.io/*` audit annotations): https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes Documentation — *Validating Admission Policy* (`validation.policy.admission.k8s.io/*` annotations): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes Documentation — *Using RBAC Authorization* (`authorization.k8s.io/decision` and `reason`): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes Documentation — *System Logs and Metrics*: https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Kubernetes source — audit policy checker and backends: https://github.com/kubernetes/apiserver/tree/master/pkg/audit
- CNCF — CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- `kube-bench` (automated CIS assessment): https://github.com/aquasecurity/kube-bench
- Falco — `k8saudit` plugin: https://github.com/falcosecurity/plugins/tree/master/plugins/k8saudit
- Falco — default Kubernetes audit rules: https://github.com/falcosecurity/rules/blob/main/rules/k8s_audit_rules.yaml
- Fluent Bit Documentation — `tail` input and `opensearch` output: https://docs.fluentbit.io/manual/pipeline/inputs/tail
- NIST SP 800-53 Rev. 5 — AU (Audit and Accountability) control family: https://csrc.nist.gov/projects/risk-management/sp800-53-controls/release-search#!/families