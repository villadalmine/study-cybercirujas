# 3.3 — Restrict access to the Kubernetes API

**Certification:** CKS (Certified Kubernetes Security Specialist), exam version 1.34
**Domain:** 3 — Cluster Hardening · **Topic weight:** 3.75 %

---

## 1. The production problem

`kube-apiserver` is the only component in a Kubernetes cluster that writes to etcd. Every other control-plane process — scheduler, controller-manager, kubelet, CNI, CSI, operators — is a *client*. That architectural choice is what makes Kubernetes coherent, and it is also what makes the API server the single most valuable target in the cluster: **one authenticated, over-privileged request to port 6443 is equivalent to root on every node.**

The escalation chain that reviewers see over and over in real incidents:

```
reachable :6443  →  identity accepted  →  create pods (any namespace)
                                       →  pod with hostPath: / + privileged
                                       →  chroot /host
                                       →  read /etc/kubernetes/pki/ca.key
                                       →  mint a client cert with O=system:masters
                                       →  permanent, unrevokable cluster-admin
```

Note the last step. A stolen ServiceAccount token can be revoked; a client certificate signed by the cluster CA **cannot** — Kubernetes implements no CRL and no OCSP. The only remediation is rotating the cluster CA, which is a multi-hour, all-nodes, all-kubeconfigs operation. This asymmetry is the reason "restrict access to the API" is a *defence-in-depth* topic rather than a single flag.

There are four independent gates, and a production cluster must close all four. Failing any single one is sufficient for full compromise:

| Gate | Question it answers | Primary control | Blast radius if wrong |
|---|---|---|---|
| **1. Reachability** | Can the packet arrive at 6443? | Firewall / `--bind-address` / authorized networks | Global — internet-wide scanning of your control plane |
| **2. Authentication** | Who is this? | x509, OIDC, SA tokens, `anonymous` | Identity forgery, unauthenticated reads |
| **3. Authorization** | May *this* identity do *this*? | Node + RBAC + Webhook chain | Privilege escalation, lateral movement |
| **4. Admission & throttling** | Is the *object* acceptable? At what rate? | Admission plugins, ValidatingAdmissionPolicy, APF | Container breakout, control-plane DoS |

The rest of this material walks the four gates in request order, exactly as `kube-apiserver` evaluates them.

---

## 2. Anatomy of a request (the mechanics you must be able to recite)

```
        TCP :6443
            │
            ▼
   ┌──────────────────┐
   │ TLS handshake    │  --tls-cert-file / --client-ca-file
   │ (mTLS optional)  │  --tls-min-version / --tls-cipher-suites
   └────────┬─────────┘
            ▼
   ┌──────────────────┐   Authenticator chain — FIRST success wins,
   │ Authentication   │   remaining authenticators are skipped.
   │                  │   Output: username + UID + groups[] + extra{}
   └────────┬─────────┘   Failure of ALL → anonymous (if enabled) else 401
            ▼
   ┌──────────────────┐   Audit stage: RequestReceived / ResponseStarted
   │ Audit            │
   └────────┬─────────┘
            ▼
   ┌──────────────────┐   Authorizer chain — each returns
   │ Authorization    │   Allow | Deny | NoOpinion.
   │                  │   FIRST Allow or Deny terminates the chain.
   └────────┬─────────┘   All NoOpinion → 403
            ▼
   ┌──────────────────┐
   │ APF (flow ctl)   │   FlowSchema → PriorityLevel → queue or 429
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │ Mutating admission → schema validation → Validating admission │
   └────────┬─────────┘
            ▼
          etcd
```

Two properties of this pipeline are exam-relevant and constantly misunderstood:

1. **Authentication is `OR`, authorization is short-circuit.** Adding an authenticator can only *widen* who gets in. Adding an authorizer *after* RBAC can never take away what RBAC already allowed — a deny-oriented webhook must be placed **before** RBAC in the chain.
2. **401 vs 403 is a diagnostic signal, not a detail.** `401 Unauthorized` = gate 2 rejected you (no identity). `403 Forbidden` = gate 2 accepted you and gate 3 refused. If you disable anonymous auth and a probe starts returning 403 instead of 401, your change did not take effect.

---

## 3. Gate 1 — Network reachability

Kubernetes `NetworkPolicy` objects **do not protect the API server.** The control plane runs on the host network, outside the CNI's dataplane; there is no `NetworkPolicy` that can filter ingress to `kube-apiserver`. This surprises people every single audit.

### 3.1 Trade-off table

| Control | Where enforced | Survives node rebuild? | Granularity | Failure mode | Verdict |
|---|---|---|---|---|---|
| `--bind-address=<private IP>` | apiserver socket | Yes (static pod manifest) | Interface | Cluster unreachable if IP changes | Baseline for on-prem |
| Host firewall (`nftables`/`firewalld`) | Control-plane node kernel | No (re-image wipes it) | CIDR + port | Silent lockout, needs console access | Good, but must be config-managed |
| Cloud SG / NACL | Provider network fabric | Yes | CIDR + port | Lockout, recoverable from console | **Preferred on cloud** |
| Managed "authorized networks" (EKS `publicAccessCidrs`, GKE `master-authorized-networks`, AKS `--api-server-authorized-ip-ranges`) | Provider control plane | Yes | CIDR list | API returns connection timeout | **Preferred on managed** |
| Private endpoint only (no public IP) | Provider VPC | Yes | VPC/peering | Requires bastion/VPN for operators | Strongest; highest ops cost |
| `konnectivity` / SSH tunnel egress | Control plane → node direction | Yes | n/a | Exec/logs/port-forward break | Complements, not replaces |

### 3.2 Binding the API server to a private interface

`/etc/kubernetes/manifests/kube-apiserver.yaml` on a kubeadm control-plane node. This is a **static pod** — the kubelet watches the directory and restarts the container on any file change.

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
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.10.11:6443
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: kube-apiserver
    image: registry.k8s.io/kube-apiserver:v1.34.0
    command:
    - kube-apiserver
    # ---- Gate 1: reachability ---------------------------------------------
    - --bind-address=10.0.10.11              # NOT 0.0.0.0
    - --advertise-address=10.0.10.11
    - --secure-port=6443
    # ---- TLS hardening (CIS 1.2.x) ----------------------------------------
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    - --tls-min-version=VersionTLS12
    - --tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
    - --profiling=false                      # closes /debug/pprof
    # ---- Gate 2: authentication -------------------------------------------
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --authentication-config=/etc/kubernetes/authn/authentication.yaml
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-lookup=true          # revoke legacy tokens by deleting the Secret
    - --api-audiences=https://kubernetes.default.svc.cluster.local
    # ---- Gate 3: authorization --------------------------------------------
    - --authorization-config=/etc/kubernetes/authz/authorization.yaml
    # ---- Gate 4: admission + audit ----------------------------------------
    - --enable-admission-plugins=NodeRestriction
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    - --request-timeout=60s
    # ---- etcd / kubelet client identities ---------------------------------
    - --etcd-servers=https://10.0.10.11:2379
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt
    - --allow-privileged=true
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 10.0.10.11
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 10.0.10.11
        path: /readyz
        port: 6443
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 10.0.10.11
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - name: k8s-certs
      mountPath: /etc/kubernetes/pki
      readOnly: true
    - name: authn
      mountPath: /etc/kubernetes/authn
      readOnly: true
    - name: authz
      mountPath: /etc/kubernetes/authz
      readOnly: true
    - name: audit-policy
      mountPath: /etc/kubernetes/audit
      readOnly: true
    - name: audit-log
      mountPath: /var/log/kubernetes/audit
      readOnly: false
    - name: ca-certs
      mountPath: /etc/ssl/certs
      readOnly: true
  volumes:
  - name: k8s-certs
    hostPath: {path: /etc/kubernetes/pki, type: DirectoryOrCreate}
  - name: authn
    hostPath: {path: /etc/kubernetes/authn, type: DirectoryOrCreate}
  - name: authz
    hostPath: {path: /etc/kubernetes/authz, type: DirectoryOrCreate}
  - name: audit-policy
    hostPath: {path: /etc/kubernetes/audit, type: DirectoryOrCreate}
  - name: audit-log
    hostPath: {path: /var/log/kubernetes/audit, type: DirectoryOrCreate}
  - name: ca-certs
    hostPath: {path: /etc/ssl/certs, type: DirectoryOrCreate}
```

> **Operational rule:** any file you reference with a flag must also exist as a `hostPath` volume **and** a `volumeMount`. A missing mount is the #1 cause of "I added the flag and the API server never came back" — the container starts, cannot open the file, and exits before it can log anything useful to a place you can read with `kubectl`.

### 3.3 Host firewall (nftables), config-managed

```bash
$ cat /etc/nftables.d/k8s-controlplane.nft
table inet k8s_cp {
  set admin_nets {
    type ipv4_addr
    flags interval
    elements = { 10.0.10.0/24, 10.0.20.0/24, 203.0.113.7/32 }
  }
  chain input {
    type filter hook input priority filter; policy accept;

    # kube-apiserver: only nodes + the bastion range
    tcp dport 6443 ip saddr @admin_nets accept
    tcp dport 6443 counter log prefix "k8s-apiserver-drop " drop

    # etcd: control-plane peers only
    tcp dport { 2379, 2380 } ip saddr { 10.0.10.0/24 } accept
    tcp dport { 2379, 2380 } counter drop

    # kubelet read-write API
    tcp dport 10250 ip saddr { 10.0.10.0/24 } accept
    tcp dport 10250 counter drop
  }
}

$ sudo nft -f /etc/nftables.d/k8s-controlplane.nft
$ sudo nft list ruleset | grep -A3 'dport 6443'
		tcp dport 6443 ip saddr @admin_nets accept
		tcp dport 6443 counter packets 0 bytes 0 log prefix "k8s-apiserver-drop " drop
```

Verify from an unauthorized network:

```bash
$ nc -vz -w3 10.0.10.11 6443
nc: connect to 10.0.10.11 port 6443 (tcp) timed out: Operation now in progress
```

A **timeout** (not `connection refused`, not a TLS error) is the signature of a correctly working L3/L4 filter.

---

## 4. Gate 2 — Authentication

### 4.1 The authenticator chain

| Method | Enabled by | Revocable? | Expiry | Groups source | CKS verdict |
|---|---|---|---|---|---|
| **x509 client cert** | `--client-ca-file` | ❌ **No CRL support** | Cert `notAfter` | `O=` fields | Break-glass only; ≤ 24 h lifetimes |
| **Static token file** | `--token-auth-file` | Only via restart | Never | CSV column | ❌ Forbidden — plaintext on disk |
| **Static password file** | *(removed in 1.19)* | — | — | — | ❌ Does not exist |
| **Bootstrap token** | `--enable-bootstrap-token-auth` | Delete the Secret | `expiration` field | `system:bootstrappers:*` | Node join only, short TTL |
| **SA token — legacy Secret** | auto (pre-1.24 behaviour) | Delete Secret *(needs `--service-account-lookup=true`)* | **Never** | `system:serviceaccounts[:ns]` | Migrate away |
| **SA token — TokenRequest / projected** | default since 1.21 | Delete Pod or SA | 1 h, auto-rotated at ~80 % | same + pod/node binding | ✅ Default for workloads |
| **OIDC / structured JWT** | `--authentication-config` | IdP-side, immediate | Minutes | `groups` claim, CEL-mapped | ✅ Humans in production |
| **Webhook token** | `--authentication-token-webhook-config-file` | External | External | External | Cloud IAM integration |
| **Anonymous** | `--anonymous-auth` / config | n/a | n/a | `system:unauthenticated` | Restrict to health endpoints |
| **Proxy headers** | `--requestheader-*` | n/a | n/a | header | Aggregation layer only |

### 4.2 Anonymous access — and the trap that breaks your control plane

By default the API server accepts unauthenticated requests and assigns them:

```
username: system:anonymous
groups:   [system:unauthenticated]
```

The default RBAC posture keeps this harmless: the only binding that targets `system:unauthenticated` is `system:public-info-viewer`.

```bash
$ kubectl auth can-i --list --as=system:anonymous
Resources   Non-Resource URLs   Resource Names   Verbs
            [/healthz]          []               [get]
            [/livez]            []               [get]
            [/readyz]           []               [get]
            [/version/]         []               [get]
            [/version]          []               [get]
```

```bash
$ curl -sk https://10.0.10.11:6443/api/v1/namespaces/kube-system/secrets | jq -c '{code,message}'
{"code":403,"message":"secrets is forbidden: User \"system:anonymous\" cannot list resource \"secrets\" in API group \"\" in the namespace \"kube-system\""}
```

The catastrophic misconfiguration — seen in real breach reports — is someone binding an unauthenticated subject to a broad role:

```yaml
# ☠️  NEVER. This is remote, unauthenticated cluster-admin.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: debug-please-remove-later
subjects:
- kind: Group
  name: system:unauthenticated       # or system:anonymous, or system:authenticated
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

**The trap.** The obvious hardening step is `--anonymous-auth=false`. On a kubeadm cluster this kills the control plane, because the kubelet's liveness/readiness probes against `/livez` and `/readyz` are unauthenticated HTTP GETs:

```
$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT
a41c9e2f7b0d   c3ff0a2e2b1f   40 seconds ago  Exited    kube-apiserver   6

$ sudo journalctl -u kubelet --since -5min | grep -i probe
Aug 03 11:04:12 cp-1 kubelet[1180]: I0803 11:04:12.774 1180 prober.go:107] "Probe failed" probeType="Startup" pod="kube-system/kube-apiserver-cp-1" podUID="8c1..." containerName="kube-apiserver" result="Failure" output="HTTP probe failed with statuscode: 401"
Aug 03 11:04:22 cp-1 kubelet[1180]: I0803 11:04:22.781 1180 kuberuntime_manager.go:1027] "Container failed startup probe, will be restarted" pod="kube-system/kube-apiserver-cp-1"
```

`statuscode: 401` on a health endpoint is the fingerprint of this exact mistake.

**The correct fix (1.32+): configurable anonymous endpoints.** Keep anonymous auth alive *only* for the probe paths, using the structured authentication configuration:

```yaml
# /etc/kubernetes/authn/authentication.yaml
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration

# Anonymous requests are accepted ONLY on these exact paths.
# Everything else from an unauthenticated client gets 401.
anonymous:
  enabled: true
  conditions:
  - path: /livez
  - path: /readyz
  - path: /healthz
```

> **Mutual exclusion:** if the config file contains an `anonymous` section, you must **not** also pass `--anonymous-auth` on the command line. The API server refuses to start with both. Remove the flag from the static pod manifest.

Verification after the change:

```bash
$ curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.10.11:6443/livez
200
$ curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.10.11:6443/version
401
$ curl -sk https://10.0.10.11:6443/api/v1/nodes | jq -c '{code,message}'
{"code":401,"message":"Unauthorized"}
```

`200` on `/livez` and `401` everywhere else is exactly the target state.

**Alternative, when `--anonymous-auth=false` is mandated by policy** (e.g. an older cluster, or a CIS profile that checks the flag literally): rewrite the probes to authenticate with a client certificate via an `exec` wrapper, or point them at the kubelet-local `--secure-port` with a token file. This is materially more fragile than the configurable-endpoints approach; prefer the config file when the version allows it.

### 4.3 Full JWT / OIDC configuration with CEL guardrails

The same file carries the identity-provider configuration. This is the modern replacement for the `--oidc-*` flags, and its CEL rules let you enforce invariants the flags never could:

```yaml
# /etc/kubernetes/authn/authentication.yaml (complete)
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration

anonymous:
  enabled: true
  conditions:
  - path: /livez
  - path: /readyz
  - path: /healthz

jwt:
- issuer:
    url: https://sso.example.com/realms/platform
    audiences:
    - kubernetes-prod
    audienceMatchPolicy: MatchAny
    certificateAuthority: |
      -----BEGIN CERTIFICATE-----
      MIIDdzCCAl+gAwIBAgIEbY6prTANBgkqhkiG9w0BAQsFADBaMQswCQYDVQQGEwJV
      UzETMBEGA1UECBMKQ2FsaWZvcm5pYTEWMBQGA1UEBxMNU2FuIEZyYW5jaXNjbzEP
      MA0GA1UEChMGRXhhbXBsZTENMAsGA1UEAxMEcm9vdDAeFw0yNTAxMDEwMDAwMDBa
      -----END CERTIFICATE-----

  claimMappings:
    username:
      # Prefix is MANDATORY unless expression yields a value that cannot
      # collide with built-in identities. Never map raw `sub` without a prefix.
      expression: "'sso:' + claims.sub"
    groups:
      expression: "claims.groups.map(g, 'sso:' + g)"
    uid:
      expression: "claims.sub"
    extra:
    - key: "example.com/tenant"
      valueExpression: "claims.tenant_id"

  claimValidationRules:
  - expression: "claims.hd == 'example.com'"
    message: "the token must be issued to an example.com hosted-domain account"
  - expression: "'kubernetes-prod' in claims.aud"
    message: "audience must include kubernetes-prod"
  - expression: "has(claims.amr) && 'mfa' in claims.amr"
    message: "multi-factor authentication is required for cluster access"

  userValidationRules:
  - expression: "!user.groups.exists(g, g.startsWith('system:'))"
    message: "external identities must not claim any system: group"
  - expression: "user.username.startsWith('sso:')"
    message: "username must carry the sso: prefix"
```

The two `userValidationRules` above close a genuine escalation path: without them, an IdP that can be induced to emit `groups: ["system:masters"]` grants the holder cluster-admin, because the RBAC authorizer resolves group names, not their provenance.

Reload semantics: `--authentication-config` is watched and hot-reloaded — no API server restart needed for JWT changes (the `anonymous` section is applied at startup). Confirm a reload succeeded:

```bash
$ kubectl get --raw /metrics | grep apiserver_authentication_config_controller_automatic_reload_last_timestamp_seconds
apiserver_authentication_config_controller_automatic_reload_last_timestamp_seconds{apiserver_id_hash="sha256:9c1f...",status="success"} 1.754218e+09
```

> **Version check before you rely on any of this in the exam or in production:**
> ```bash
> $ kube-apiserver --help | grep -E 'authentication-config|anonymous-auth'
> $ kubectl get --raw /metrics | grep 'kubernetes_feature_enabled.*Anonymous'
> ```
> `apiserver.config.k8s.io/v1beta1` is served in 1.34; newer releases may also serve `v1`. Read the version your cluster reports rather than assuming.

### 4.4 Client certificates: the unrevokable identity

```bash
$ openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt -noout -subject -dates
subject=O=system:masters, CN=kube-apiserver-kubelet-client
notBefore=Jul 20 09:14:31 2026 GMT
notAfter=Jul 20 09:19:31 2027 GMT
```

`CN` becomes the **username**; each `O` becomes a **group**. Nothing else in the certificate matters to Kubernetes.

Issue short-lived, correctly-scoped credentials through the CSR API rather than hand-signing with `ca.key`:

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: oncall-alice-2026-08-03
spec:
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNU...   # base64 of the PEM CSR
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 3600          # 1 hour — honoured by kube-controller-manager
  usages:
  - client auth
```

```bash
$ openssl genrsa -out alice.key 3072
$ openssl req -new -key alice.key -out alice.csr \
    -subj "/CN=alice/O=platform-oncall"

$ kubectl create -f alice-csr.yaml
certificatesigningrequest.certificates.k8s.io/oncall-alice-2026-08-03 created

$ kubectl get csr oncall-alice-2026-08-03
NAME                      AGE   SIGNERNAME                            REQUESTOR           REQUESTEDDURATION   CONDITION
oncall-alice-2026-08-03   4s    kubernetes.io/kube-apiserver-client   kubernetes-admin    3600s               Pending

$ kubectl certificate approve oncall-alice-2026-08-03
certificatesigningrequest.certificates.k8s.io/oncall-alice-2026-08-03 approved

$ kubectl get csr oncall-alice-2026-08-03 -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
$ openssl x509 -in alice.crt -noout -subject -dates
subject=O=platform-oncall, CN=alice
notBefore=Aug  3 11:22:00 2026 GMT
notAfter=Aug  3 12:22:00 2026 GMT
```

Because the certificate cannot be revoked, the *only* meaningful controls are (a) short `expirationSeconds`, and (b) never issuing `O=system:masters`. Watch the fleet's certificate expiry as a first-class SLI:

```bash
$ kubectl get --raw /metrics | grep apiserver_client_certificate_expiration_seconds_bucket | tail -4
apiserver_client_certificate_expiration_seconds_bucket{le="21600"} 3
apiserver_client_certificate_expiration_seconds_bucket{le="43200"} 3
apiserver_client_certificate_expiration_seconds_bucket{le="86400"} 41
apiserver_client_certificate_expiration_seconds_bucket{le="+Inf"} 44

$ sudo kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
admin.conf                 Jul 20, 2027 09:19 UTC   351d            no
apiserver                  Jul 20, 2027 09:19 UTC   351d            no
apiserver-kubelet-client   Jul 20, 2027 09:19 UTC   351d            no
super-admin.conf           Jul 20, 2027 09:19 UTC   351d            no
```

---

## 5. Gate 3 — Authorization

### 5.1 Authorizer modes and chain semantics

| Mode | Returns Deny? | Scope | Use |
|---|---|---|---|
| `Node` | Yes (for kubelet identities out of scope) | Restricts `system:nodes` to objects bound to that node | **Mandatory** |
| `RBAC` | No — Allow or NoOpinion only | Namespaced + cluster roles | **Mandatory** |
| `ABAC` | Yes | Static policy file, no live updates | ❌ Legacy, restart to change |
| `Webhook` | Yes (`Deny`) or NoOpinion | External policy engine | Deny-by-policy, tenant isolation |
| `AlwaysAllow` | n/a | Everything | ❌ Catastrophic |
| `AlwaysDeny` | Yes | Nothing | Testing only |

Because RBAC **cannot deny**, the ordering rule is decisive:

- `Node,RBAC,Webhook` → the webhook only ever sees requests that RBAC left as NoOpinion. It can grant, but it can **never** revoke an RBAC grant.
- `Webhook,Node,RBAC` → the webhook can issue an authoritative `Deny` that terminates the chain. This is the correct ordering for compliance gates ("no one touches namespace `prod-payments` outside a change window").

The cost is availability: every request now waits on the webhook. Use `matchConditions` to scope it and `authorizedTTL`/`unauthorizedTTL` to cache.

### 5.2 Structured authorization configuration

```yaml
# /etc/kubernetes/authz/authorization.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthorizationConfiguration
authorizers:

# 1. Authoritative deny gate — evaluated FIRST so it can override RBAC.
#    matchConditions keep the blast radius (and the latency) small.
- type: Webhook
  name: change-window-guard
  webhook:
    connectionInfo:
      type: KubeConfigFile
      kubeConfigFile: /etc/kubernetes/authz/change-window-guard.kubeconfig
    subjectAccessReviewVersion: v1
    matchConditionSubjectAccessReviewVersion: v1
    authorizedTTL: 10s
    unauthorizedTTL: 10s
    timeout: 3s
    # Fail CLOSED. If the guard is down, mutations to the protected
    # namespaces are refused rather than silently permitted.
    failurePolicy: Deny
    matchConditions:
    # Only consult the webhook for writes into protected namespaces.
    - expression: >-
        has(request.resourceAttributes) &&
        request.resourceAttributes.namespace in ['prod-payments','prod-identity'] &&
        request.resourceAttributes.verb in ['create','update','patch','delete','deletecollection']
    # Never gate the control plane itself — this would deadlock the cluster.
    - expression: >-
        !request.user.username.startsWith('system:') &&
        !('system:nodes' in request.user.groups)

# 2. Node authorizer — kubelets may only read objects scheduled to them.
- type: Node
  name: node

# 3. RBAC — the normal grant path.
- type: RBAC
  name: rbac
```

Wire it up (mutually exclusive with `--authorization-mode`):

```bash
$ sudo sed -i 's|--authorization-mode=Node,RBAC|--authorization-config=/etc/kubernetes/authz/authorization.yaml|' \
    /etc/kubernetes/manifests/kube-apiserver.yaml
```

`--authorization-config` is hot-reloaded. Confirm:

```bash
$ kubectl get --raw /metrics | grep apiserver_authorization_config_controller_automatic_reloads_total
apiserver_authorization_config_controller_automatic_reloads_total{apiserver_id_hash="sha256:9c1f...",status="success"} 3

$ kubectl get --raw /metrics | grep apiserver_authorization_decisions_total
apiserver_authorization_decisions_total{decision="allowed",type="RBAC"} 918447
apiserver_authorization_decisions_total{decision="denied",type="Webhook"} 12
apiserver_authorization_decisions_total{decision="no-opinion",type="Node"} 918459
```

> **Fail-closed is a real availability decision.** `failurePolicy: Deny` on an authorization webhook means an outage of your policy service becomes an outage of writes to the protected namespaces. That is usually the right trade for `prod-payments` and the wrong trade for a cluster-wide match condition. Scope the `matchConditions` narrowly *because* you chose `Deny`.

### 5.3 `system:masters` — the identity you cannot govern

`system:masters` is bound to `cluster-admin` by a bootstrap `ClusterRoleBinding` that the API server **re-creates on every start**:

```bash
$ kubectl get clusterrolebinding cluster-admin -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-admin
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"    # ← self-healing
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:masters
```

Consequences you must internalise:

- Deleting this binding does not stick unless you first set `rbac.authorization.kubernetes.io/autoupdate: "false"`. Doing so is a documented way to lock yourself out permanently.
- `system:masters` also matches the `exempt` APF flow schema, so it bypasses priority-and-fairness throttling.
- A certificate carrying `O=system:masters` is cluster-admin **forever**, with no revocation path short of CA rotation.

**kubeadm ≥ 1.29 split this deliberately.** Learn the difference cold:

```bash
$ sudo grep -A2 'client-certificate-data' /etc/kubernetes/admin.conf >/dev/null; \
  sudo kubectl --kubeconfig /etc/kubernetes/admin.conf auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]

$ sudo kubectl --kubeconfig /etc/kubernetes/super-admin.conf auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-super-admin
Groups      [system:masters system:authenticated]
```

| File | Identity | Path to power | Handling |
|---|---|---|---|
| `admin.conf` | `CN=kubernetes-admin`, `O=kubeadm:cluster-admins` | Ordinary `ClusterRoleBinding kubeadm:cluster-admins` → `cluster-admin` — **revocable, auditable, RBAC-visible** | Day-to-day admin |
| `super-admin.conf` | `CN=kubernetes-super-admin`, `O=system:masters` | Hard-coded bootstrap binding — bypasses APF, unrevokable | **Remove from the node**, store in a vault, break-glass only |

```bash
# Break-glass hygiene on every control-plane node
$ sudo install -m 0600 /etc/kubernetes/super-admin.conf /root/breakglass/super-admin.conf
$ sudo shred -u /etc/kubernetes/super-admin.conf
$ ls -l /etc/kubernetes/*.conf
-rw------- 1 root root 5654 Aug  3 11:31 /etc/kubernetes/admin.conf
-rw------- 1 root root 5666 Aug  3 11:31 /etc/kubernetes/controller-manager.conf
-rw------- 1 root root 5610 Aug  3 11:31 /etc/kubernetes/kubelet.conf
-rw------- 1 root root 5614 Aug  3 11:31 /etc/kubernetes/scheduler.conf
```

### 5.4 Verbs that are equivalent to cluster-admin

RBAC review is a separate topic (3.2), but for *restricting API access* you must recognise the grants that silently return full control:

| Grant | Why it is cluster-admin | Mitigation |
|---|---|---|
| `create pods` in any namespace | Mount `hostPath: /`, `privileged: true`, read `ca.key` | Pod Security Admission `restricted`; separate namespaces |
| `create pods/exec`, `pods/attach` | Enter any container, steal its SA token | Grant per-namespace, audit at `RequestResponse` |
| `get/list secrets` | Reads every SA token in scope | Never cluster-scoped; use `resourceNames` |
| `escalate` on roles | Create a role with permissions you lack | Never grant |
| `bind` on clusterrolebindings | Bind yourself to `cluster-admin` | Never grant |
| `impersonate` users/groups | Assume `system:masters` | Restrict with `resourceNames` |
| `get nodes/proxy` | Direct kubelet API → exec on any pod | Never grant to workloads |
| `create` on `certificatesigningrequests/approval` + a signer | Mint arbitrary client certs | Separate approver identity |
| `update` on `validatingwebhookconfigurations` | Disable the admission gate | Restrict to platform team |
| `*` on `*` | Self-evident | — |

Enforce the worst of these with a `ValidatingAdmissionPolicy`, which runs at gate 4 and therefore catches even an RBAC misconfiguration:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: forbid-privileged-subject-bindings
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   ["rbac.authorization.k8s.io"]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["clusterrolebindings", "rolebindings"]
  variables:
  - name: subjects
    expression: "has(object.subjects) ? object.subjects : []"
  validations:
  - expression: >-
      !variables.subjects.exists(s,
        s.name in ['system:anonymous','system:unauthenticated',
                   'system:authenticated','system:serviceaccounts'])
    message: "binding roles to anonymous, unauthenticated, all-authenticated or all-serviceaccounts subjects is forbidden"
    reason: Forbidden
  - expression: >-
      object.roleRef.name != 'cluster-admin' ||
      !variables.subjects.exists(s, s.kind == 'ServiceAccount')
    message: "ServiceAccounts must not be bound to cluster-admin"
    reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: forbid-privileged-subject-bindings
spec:
  policyName: forbid-privileged-subject-bindings
  validationActions: [Deny, Audit]
  matchResources:
    namespaceSelector: {}
```

```bash
$ kubectl apply -f forbid-privileged-subject-bindings.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/forbid-privileged-subject-bindings created
validatingadmissionpolicybinding.admissionregistration.k8s.io/forbid-privileged-subject-bindings created

$ kubectl create clusterrolebinding oops --clusterrole=cluster-admin --group=system:unauthenticated
error: failed to create clusterrolebinding: clusterrolebindings.rbac.authorization.k8s.io "oops" is forbidden:
ValidatingAdmissionPolicy 'forbid-privileged-subject-bindings' with binding 'forbid-privileged-subject-bindings'
denied request: binding roles to anonymous, unauthenticated, all-authenticated or all-serviceaccounts subjects is forbidden
```

---

## 6. Restricting the API surface a workload can reach

Every pod that mounts a ServiceAccount token is an API client. The largest single reduction in API attack surface is turning that off for the ~90 % of workloads that never call the API.

### 6.1 Disable automounting — both levels

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: prod
automountServiceAccountToken: false        # covers every pod using this SA
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: prod
spec:
  replicas: 3
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      serviceAccountName: frontend
      automountServiceAccountToken: false  # pod-level; overrides the SA setting
      containers:
      - name: web
        image: registry.example.com/frontend@sha256:7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 10001
          capabilities: {drop: ["ALL"]}
          seccompProfile: {type: RuntimeDefault}
```

Precedence: **pod-level `automountServiceAccountToken` always wins** over the ServiceAccount-level setting.

```bash
$ kubectl exec -n prod deploy/frontend -- ls /var/run/secrets/kubernetes.io/serviceaccount
ls: cannot access '/var/run/secrets/kubernetes.io/serviceaccount': No such file or directory
command terminated with exit code 2
```

Cluster-wide audit of what is still mounting a token:

```bash
$ kubectl get pods -A -o json | jq -r '
    .items[]
    | select((.spec.automountServiceAccountToken // true) == true)
    | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.serviceAccountName)"' \
  | sort | uniq -c | sort -rn | head
     18	prod	api-7d9f8c6b5-*	api
      6	kube-system	kube-proxy-*	kube-proxy
      3	monitoring	prometheus-0	prometheus
```

### 6.2 Bound, audience-scoped, auto-rotating tokens

For pods that *do* need the API, the projected token carries binding claims that make theft far less useful:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-client
  namespace: prod
spec:
  serviceAccountName: api
  automountServiceAccountToken: false      # suppress the default mount…
  containers:
  - name: app
    image: registry.example.com/api:1.9.2
    volumeMounts:
    - name: kube-api-token
      mountPath: /var/run/secrets/tokens
      readOnly: true
    - name: vault-token
      mountPath: /var/run/secrets/vault
      readOnly: true
  volumes:
  # …and project exactly the tokens this workload needs, with tight audiences.
  - name: kube-api-token
    projected:
      defaultMode: 0400
      sources:
      - serviceAccountToken:
          path: token
          audience: https://kubernetes.default.svc.cluster.local
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt
          items: [{key: ca.crt, path: ca.crt}]
      - downwardAPI:
          items: [{path: namespace, fieldRef: {fieldPath: metadata.namespace}}]
  - name: vault-token
    projected:
      defaultMode: 0400
      sources:
      - serviceAccountToken:
          path: token
          audience: https://vault.example.com      # useless against kube-apiserver
          expirationSeconds: 600
```

Inspect the claims — this is what "bound" means concretely:

```bash
$ kubectl exec -n prod api-client -- cat /var/run/secrets/tokens/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq
{
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1785311820,
  "iat": 1785308220,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "0f4a9c72-2d3e-4a6b-9f10-5c8e1a7b3d42",
  "kubernetes.io": {
    "namespace": "prod",
    "node": {"name": "worker-2", "uid": "b1e7f0c4-9a2d-4f31-8c55-0d6e2a91f7bb"},
    "pod":  {"name": "api-client", "uid": "3c9d1a55-77e4-4a08-9b2f-1e6c4d0a8f19"},
    "serviceaccount": {"name": "api", "uid": "8a5b2c1e-4f7d-49a3-b0c6-2e91d3f4a7c8"}
  },
  "nbf": 1785308220,
  "sub": "system:serviceaccount:prod:api"
}
```

Delete the pod and the token stops working immediately — the `pod` claim is validated against live state. Compare that with a legacy Secret-based token, which is a bearer credential with no expiry at all.

Ad-hoc, time-boxed tokens for CI (replaces creating a long-lived Secret):

```bash
$ kubectl create token ci-deployer -n ci --audience=https://kubernetes.default.svc.cluster.local --duration=15m
eyJhbGciOiJSUzI1NiIsImtpZCI6Ilo0RzRSNW1SVndoVWxmNXNBUlNoM0JJeEtGWk1uZ0IifQ.eyJhdWQiOl...

$ kubectl create token ci-deployer -n ci --duration=15m \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.exp | tostring'
1785309150
```

Hunt legacy tokens still in use:

```bash
$ kubectl get --raw /metrics | grep -E 'serviceaccount_(legacy_token_uses|stale_tokens|legacy_tokens_used)_total'
serviceaccount_legacy_tokens_used_total 0
serviceaccount_stale_tokens_total 0

$ kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,LASTUSED:.metadata.labels.kubernetes\.io/legacy-token-last-used'
NS            NAME                    LASTUSED
legacy-apps   jenkins-token-4x9qk     2026-07-28
```

A non-zero `serviceaccount_legacy_tokens_used_total` means something in the cluster still presents a pre-1.24-style token. Find it, migrate it, delete the Secret. With `--service-account-lookup=true` (the default), deleting the Secret revokes the token immediately.

---

## 7. Gate 4 — Throttling the API server itself

Restricting *access* also means restricting *volume*. A single misbehaving controller doing `LIST pods` cluster-wide in a hot loop will brown-out the control plane as effectively as an attacker. API Priority and Fairness gives you an isolation boundary per client class.

```yaml
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: restrict-unauthenticated
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 1     # a sliver of total concurrency
    lendablePercent: 100            # lend it all away when idle
    limitResponse:
      type: Reject                  # 429 immediately; never queue
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: restrict-unauthenticated
spec:
  matchingPrecedence: 100           # lower number = evaluated earlier
  priorityLevelConfiguration:
    name: restrict-unauthenticated
  distinguisherMethod:
    type: ByUser
  rules:
  - subjects:
    - kind: Group
      group:
        name: system:unauthenticated
    resourceRules:
    - verbs: ["*"]
      apiGroups: ["*"]
      resources: ["*"]
      clusterScope: true
      namespaces: ["*"]
    nonResourceRules:
    - verbs: ["*"]
      nonResourceURLs: ["*"]
```

```bash
$ kubectl apply -f apf-unauthenticated.yaml
prioritylevelconfiguration.flowcontrol.apiserver.k8s.io/restrict-unauthenticated created
flowschema.flowcontrol.apiserver.k8s.io/restrict-unauthenticated created

$ kubectl get flowschemas.flowcontrol.apiserver.k8s.io --sort-by=.spec.matchingPrecedence | head
NAME                            PRIORITYLEVEL              MATCHINGPRECEDENCE   DISTINGUISHERMETHOD   AGE
exempt                          exempt                     1                    <none>                40d
probes                          exempt                     2                    <none>                40d
system-leader-election          leader-election            100                  ByUser                40d
restrict-unauthenticated        restrict-unauthenticated   100                  ByUser                12s
workload-leader-election        leader-election            200                  ByUser                40d

$ kubectl get --raw /metrics | grep apiserver_flowcontrol_rejected_requests_total
apiserver_flowcontrol_rejected_requests_total{flow_schema="restrict-unauthenticated",priority_level="restrict-unauthenticated",reason="concurrency-limit"} 1183
```

Remember: `system:masters` matches the built-in `exempt` schema, which is a further reason to keep that group empty in normal operation.

---

## 8. Audit — proving the restriction holds

A restriction you cannot observe is a restriction you cannot defend. This policy is tuned to keep volume manageable while capturing everything relevant to API access:

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
- RequestReceived

rules:
# 1. Drop the highest-volume, lowest-value traffic first.
- level: None
  nonResourceURLs:
  - /healthz*
  - /livez*
  - /readyz*
  - /version*
  - /metrics
  - /openapi/*
- level: None
  users: ["system:kube-scheduler", "system:kube-controller-manager"]
  verbs: ["get", "list", "watch"]
- level: None
  userGroups: ["system:nodes"]
  verbs: ["get", "watch"]

# 2. Anything unauthenticated is a security event — capture the full exchange.
- level: RequestResponse
  users: ["system:anonymous"]
- level: RequestResponse
  userGroups: ["system:unauthenticated"]

# 3. Break-glass usage — full bodies, always.
- level: RequestResponse
  userGroups: ["system:masters"]

# 4. Impersonation and RBAC mutation — the escalation primitives.
- level: RequestResponse
  resources:
  - group: "rbac.authorization.k8s.io"
    resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  - group: "certificates.k8s.io"
    resources: ["certificatesigningrequests", "certificatesigningrequests/approval"]
  - group: "admissionregistration.k8s.io"
    resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations",
                "validatingadmissionpolicies", "validatingadmissionpolicybindings"]

# 5. Credential access — metadata only, never the payload.
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets", "configmaps", "serviceaccounts/token"]

# 6. Interactive access to running containers.
- level: RequestResponse
  resources:
  - group: ""
    resources: ["pods/exec", "pods/attach", "pods/portforward", "nodes/proxy"]

# 7. Everything else: who did what to which object.
- level: Metadata
```

> `level: Metadata` on Secrets is deliberate. `RequestResponse` on a Secret writes the plaintext value into the audit log, converting your SIEM into a credential store.

Query it:

```bash
$ sudo jq -c 'select(.user.username=="system:anonymous")
              | {t:.requestReceivedTimestamp, ip:.sourceIPs[0], uri:.requestURI, code:.responseStatus.code}' \
     /var/log/kubernetes/audit/audit.log | tail -3
{"t":"2026-08-03T11:47:02.114Z","ip":"198.51.100.44","uri":"/apis/rbac.authorization.k8s.io/v1/clusterrolebindings","code":403}
{"t":"2026-08-03T11:47:02.331Z","ip":"198.51.100.44","uri":"/api/v1/secrets","code":403}
{"t":"2026-08-03T11:47:02.502Z","ip":"198.51.100.44","uri":"/api/v1/namespaces/kube-system/pods","code":403}
```

Three enumeration attempts from one external IP in 400 ms — that is a scanner, and it tells you gate 1 is open when it should not be.

---

## 9. Verification playbook

Run these in order. Each has a defined expected output; anything else is a finding.

**1 — Who am I, really?**

```bash
$ kubectl auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]
```
*Expected:* no `system:masters` in day-to-day operation.

**2 — What can an unauthenticated caller do?**

```bash
$ kubectl auth can-i --list --as=system:anonymous
$ kubectl auth can-i --list --as-group=system:unauthenticated --as=system:anonymous
```
*Expected:* health/version non-resource URLs only. **No resource rows at all.**

**3 — Are there any bindings to unauthenticated or all-authenticated subjects?**

```bash
$ kubectl get clusterrolebindings,rolebindings -A -o json | jq -r '
    .items[]
    | select(.subjects != null)
    | select(any(.subjects[];
        .name == "system:anonymous" or
        .name == "system:unauthenticated" or
        .name == "system:authenticated" or
        .name == "system:serviceaccounts"))
    | "\(.kind)/\(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'
ClusterRoleBinding/-/system:public-info-viewer -> ClusterRole/system:public-info-viewer
ClusterRoleBinding/-/system:basic-user -> ClusterRole/system:basic-user
ClusterRoleBinding/-/system:discovery -> ClusterRole/system:discovery
ClusterRoleBinding/-/system:service-account-issuer-discovery -> ClusterRole/system:service-account-issuer-discovery
```
*Expected:* only these bootstrap entries. Anything else is a finding — investigate it before doing anything else on this list.

**4 — Who holds `cluster-admin`?**

```bash
$ kubectl get clusterrolebindings -o json | jq -r '
    .items[] | select(.roleRef.name=="cluster-admin")
    | .metadata.name as $n | (.subjects // [])[]
    | "\($n)\t\(.kind)\t\(.name)"'
cluster-admin	Group	system:masters
kubeadm:cluster-admins	Group	kubeadm:cluster-admins
```
*Expected:* a short, fully explained list. Every `ServiceAccount` here is a finding.

**5 — Anonymous behaviour end to end**

```bash
$ API=https://10.0.10.11:6443
$ for p in /livez /readyz /version /api/v1/nodes /apis; do
    printf '%-16s %s\n' "$p" "$(curl -sk -o /dev/null -w '%{http_code}' $API$p)"
  done
/livez           200
/readyz          200
/version         401
/api/v1/nodes    401
/apis            401
```

**6 — Effective API server flags**

```bash
$ kubectl -n kube-system get pod -l component=kube-apiserver \
    -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -E 'anonymous|authorization|authentication|profiling|insecure|service-account-lookup'
"--authentication-config=/etc/kubernetes/authn/authentication.yaml"
"--authorization-config=/etc/kubernetes/authz/authorization.yaml"
"--profiling=false"
"--service-account-lookup=true"
```
*Expected:* no `--insecure-port`, no `--anonymous-auth` alongside a config file, no `AlwaysAllow`, no `--token-auth-file`.

**7 — Impersonation reachability**

```bash
$ kubectl auth can-i impersonate users --all-namespaces
no
$ kubectl auth can-i --list | grep -E 'escalate|bind|impersonate'
```
*Expected:* `no` for any identity that is not a platform-team break-glass account.

**8 — Automated CIS check**

```bash
$ kube-bench run --targets master --check 1.2.1,1.2.2,1.2.5,1.2.6,1.2.7 2>/dev/null | grep -E '^\[(PASS|FAIL|WARN)\]'
[PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false
[PASS] 1.2.2 Ensure that the --token-auth-file parameter is not set
[PASS] 1.2.5 Ensure that the --kubelet-certificate-authority argument is set as appropriate
[PASS] 1.2.6 Ensure that the --authorization-mode argument is not set to AlwaysAllow
[PASS] 1.2.7 Ensure that the --authorization-mode argument includes Node
```

---

## 10. Failure diagnosis

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| API server `CrashLoopBackOff`, kubelet logs `Probe failed … statuscode: 401` | `--anonymous-auth=false` with default probes | `journalctl -u kubelet \| grep "Probe failed"` | Use `AuthenticationConfiguration.anonymous.conditions` for `/livez`, `/readyz`, `/healthz` |
| API server container exits instantly, no logs | Flag references a file with no `hostPath` volume/mount | `crictl logs <id>` → `open /etc/…: no such file or directory` | Add matching `volumes` + `volumeMounts` entries |
| `kube-apiserver` refuses to start: *"--anonymous-auth and anonymous field in AuthenticationConfiguration are mutually exclusive"* | Both set | apiserver stderr via `crictl logs` | Remove the CLI flag |
| `Unable to connect to the server: EOF` after a manifest edit | Static pod never became ready | `crictl ps -a --name kube-apiserver` | `mv` the manifest out of `/etc/kubernetes/manifests`, fix, `mv` back |
| Everything returns `401` including valid kubeconfigs | Wrong `--client-ca-file`, or expired client cert | `openssl x509 -in ~/.kube/client.crt -noout -dates`; `kubeadm certs check-expiration` | Renew cert / restore correct CA |
| Valid identity gets `403` on everything | Authorizer chain lost `RBAC`, or config file replaced the mode | `kubectl auth can-i --list`; inspect `--authorization-config` | Ensure `RBAC` is present in `authorizers:` |
| Sporadic `403` under load, clean at low traffic | Authorization webhook `failurePolicy: Deny` timing out | `apiserver_authorization_webhook_duration_seconds`, webhook logs | Widen `timeout`, raise `authorizedTTL`, narrow `matchConditions` |
| `429 Too Many Requests` for a specific controller | APF priority level saturated | `apiserver_flowcontrol_rejected_requests_total{flow_schema=…}` | Dedicated `FlowSchema`, or fix the client's watch/list pattern |
| Pod gets `401` calling the API after ~1 h | Cached the projected token at startup; it rotated | Compare `exp` claim to now | Re-read the token file on every request (all official client libraries do this) |
| Pod gets `401` immediately | Token minted for a different `audience` | Decode the JWT, compare `aud` to `--api-audiences` | Fix the `audience` in the projected volume |
| SA token works from outside the cluster | Legacy Secret-based token (no binding claims) | `kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token` | Delete the Secret; migrate to TokenRequest |
| Deleted a `ClusterRoleBinding`; it reappears | `rbac.authorization.kubernetes.io/autoupdate: "true"` | `kubectl get clusterrolebinding X -o yaml` | Set the annotation to `"false"` first — and understand you may be removing your own access |
| `kubectl` works from anywhere on the internet | Gate 1 open | `nc -vz <public-ip> 6443` from an untrusted host | Authorized networks / private endpoint / firewall |

### Emergency recovery when the API server will not start

`kubectl` is unavailable, so work at the container runtime layer on the control-plane node:

```bash
$ sudo crictl ps -a --name kube-apiserver --latest
CONTAINER      IMAGE          CREATED          STATE    NAME             ATTEMPT   POD ID
7b3e1a9c4d02   c3ff0a2e2b1f   12 seconds ago   Exited   kube-apiserver   9         e21f...

$ sudo crictl logs 7b3e1a9c4d02 2>&1 | tail -5
E0803 12:03:41.229118       1 run.go:74] "command failed" err="error while parsing file: \
open /etc/kubernetes/authz/authorization.yaml: no such file or directory"

# Stop the crash loop, restore, restart
$ sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.broken
$ sudo cp /root/backups/kube-apiserver.yaml.2026-08-03 /etc/kubernetes/manifests/kube-apiserver.yaml
$ sudo systemctl restart kubelet
$ until sudo crictl ps --name kube-apiserver -q | grep -q .; do sleep 2; done
$ kubectl get --raw /readyz?verbose | tail -3
[+]shutdown ok
healthz check passed
```

> **Discipline that pays for itself:** `cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/backups/kube-apiserver.yaml.$(date +%F)` before *every* edit. Editing in place with no backup is how a five-minute hardening change becomes a two-hour outage.

---

## 11. Exam-day quick reference

```bash
# Identity
kubectl auth whoami
kubectl auth can-i --list --as=system:anonymous
kubectl auth can-i create pods -n prod --as=system:serviceaccount:prod:api

# Anonymous probe
curl -sk -o /dev/null -w '%{http_code}\n' https://<cp>:6443/api/v1/nodes    # want 401

# API server flags (control-plane node)
sudo grep -nE 'anonymous|authorization|authentication|profiling|token-auth' \
  /etc/kubernetes/manifests/kube-apiserver.yaml

# Dangerous bindings
kubectl get clusterrolebindings -o json | jq -r \
  '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'

# Token hygiene
kubectl get sa -A -o json | jq -r \
  '.items[] | select((.automountServiceAccountToken // true)==true)
   | "\(.metadata.namespace)/\(.metadata.name)"'
kubectl create token <sa> -n <ns> --duration=10m

# Certificates
sudo kubeadm certs check-expiration
openssl x509 -in <cert> -noout -subject -dates

# When kubectl is dead
sudo crictl ps -a --name kube-apiserver
sudo crictl logs <container-id> 2>&1 | tail -20
```

**The five statements to have memorised:**

1. `NetworkPolicy` cannot protect the API server — it is hostNetwork, outside the CNI dataplane.
2. Authentication is first-match-wins across authenticators; authorization is first-`Allow`-or-`Deny`-wins across authorizers, and **RBAC can never deny**.
3. `--anonymous-auth=false` breaks kubeadm health probes; `AuthenticationConfiguration.anonymous.conditions` is the surgical fix, and the flag and the config field are mutually exclusive.
4. x509 client certificates are unrevokable — short lifetimes are the only control, and `O=system:masters` is a permanent, APF-exempt backdoor.
5. Pod-level `automountServiceAccountToken` overrides the ServiceAccount setting; projected tokens are bound to namespace + SA + pod + node and expire in one hour.

---

## Referencias

- Controlling Access to the Kubernetes API — https://kubernetes.io/docs/concepts/security/controlling-access/
- Authenticating — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Authorization — https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Using Node Authorization — https://kubernetes.io/docs/reference/access-authn-authz/node/
- Webhook Mode — https://kubernetes.io/docs/reference/access-authn-authz/webhook/
- Certificate Signing Requests — https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Service Accounts (concepts) — https://kubernetes.io/docs/concepts/security/service-accounts/
- Admission Control in Kubernetes — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- API Priority and Fairness — https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- kube-apiserver command-line reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- kube-apiserver configuration API (`apiserver.config.k8s.io`) — https://kubernetes.io/docs/reference/config-api/apiserver-config.v1/
- Audit configuration API (`audit.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- kubeadm configuration API v1beta4 — https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- Certificate Management with kubeadm — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- PKI certificates and requirements — https://kubernetes.io/docs/setup/best-practices/certificates/
- Securing a Cluster — https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Ports and Protocols — https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- CKS Curriculum v1.34 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- kube-bench — https://github.com/aquasecurity/kube-bench