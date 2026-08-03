# Use Role Based Access Controls to Minimize Exposure

**Certification:** Certified Kubernetes Security Specialist (CKS) — curriculum v1.34
**Domain:** Cluster Setup and Hardening
**Weight:** 3.75%
**Profile:** Principal Platform Architect / Senior SRE

---

## 1. Motivation: the architectural problem RBAC actually solves

In a production Kubernetes cluster the API server is not "one of" the attack surfaces — it *is* the attack surface. Every other control plane component (scheduler, controller-manager, kubelet, CNI, CSI, operators) is a client of the same REST API, authenticated with the same identity primitives, and authorized by the same chain. Compromise of a single workload that holds an over-broad ServiceAccount token collapses the entire blast-radius model: network policy, seccomp profiles, and image signing become irrelevant if the attacker can simply `create` a privileged Pod through the API.

The failure mode we design against is **lateral privilege accumulation**:

1. An application Pod is compromised (RCE in a dependency, SSRF, exposed debug endpoint).
2. The attacker reads `/var/run/secrets/kubernetes.io/serviceaccount/token` — mounted by default unless explicitly disabled.
3. That token belongs to a ServiceAccount that a hurried platform team bound to `edit` "so the CI job works".
4. `edit` in a namespace permits creating a Pod that runs **as any ServiceAccount in that namespace**, and permits reading every Secret in that namespace.
5. If any ServiceAccount in the namespace is bound (directly or transitively) to `cluster-admin`, the attacker now owns the cluster.

Note that steps 3–5 involve no CVE, no kernel escape, and no misconfigured container runtime. They are pure authorization-model failures. This is why RBAC carries disproportionate weight relative to its 3.75% exam allocation: it is the control that determines whether every *other* control matters.

The second production problem is **operational drift**. RBAC objects are additive-only and have no deny semantics, so permissions in a long-lived cluster monotonically increase unless something actively prunes them. Every incident that ends with "just give the SA `cluster-admin` for now" is permanent unless you build detection. A mature platform therefore treats RBAC as *generated, reviewed, and continuously audited* artifacts — not as hand-edited YAML.

Third: **the authorization decision is not the whole story**. RBAC authorizes verbs on resource types. It cannot express "this Deployment may only mount Secrets whose name begins with `app-`", nor "this user may scale but not change the image". Those constraints belong to admission (ValidatingAdmissionPolicy / webhooks). Knowing where the RBAC boundary ends and where admission begins is the architectural competency being tested.

---

## 2. Where RBAC sits: the request pipeline

Every request to `kube-apiserver` traverses four stages. RBAC is stage 2.

```
                    ┌──────────────────────────────────────────────────┐
  HTTPS request ──▶ │ 1. AUTHENTICATION                                │
                    │    x509 client certs (CN → user, O → groups)     │
                    │    Bearer tokens (SA JWT via TokenReview / OIDC) │
                    │    Webhook token auth, static tokens (legacy)    │
                    │    Anonymous → system:anonymous                  │
                    └───────────────┬──────────────────────────────────┘
                                    │ user.Info{Name, UID, Groups, Extra}
                    ┌───────────────▼──────────────────────────────────┐
                    │ 2. AUTHORIZATION (ordered chain, first-allow-wins)│
                    │    Node → RBAC → [Webhook ...]                    │
                    │    Result: allow | deny | no-opinion              │
                    └───────────────┬──────────────────────────────────┘
                                    │
                    ┌───────────────▼──────────────────────────────────┐
                    │ 3. ADMISSION (mutating → schema validation →      │
                    │    validating: VAP, webhooks, PodSecurity,        │
                    │    NodeRestriction, ServiceAccount, ResourceQuota) │
                    └───────────────┬──────────────────────────────────┘
                                    │
                    ┌───────────────▼──────────────────────────────────┐
                    │ 4. PERSISTENCE (etcd, encryption-at-rest)         │
                    └──────────────────────────────────────────────────┘
```

Critical semantics of stage 2:

- The chain is **ordered** and evaluated until one authorizer returns `allow` or `deny`. `no-opinion` falls through to the next.
- **RBAC never returns `deny`.** It returns `allow` or `no-opinion`. If RBAC is the last authorizer, a `no-opinion` becomes an implicit `403 Forbidden`. This means *you cannot write a "deny" RBAC rule* — a common and expensive misconception. Restriction is achieved only by *not granting*.
- Because the chain is first-allow-wins, placing a permissive authorizer (`AlwaysAllow`, or a lenient webhook) before RBAC silently neutralizes RBAC.

### 2.1 Declaring the chain: `--authorization-config` (v1.34)

Modern clusters configure the chain through a structured file rather than the legacy `--authorization-mode` flag. The two are mutually exclusive.

`/etc/kubernetes/authorization/config.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthorizationConfiguration
authorizers:
  # Node authorizer: constrains kubelets to objects related to their own node.
  # Must be paired with the NodeRestriction admission plugin.
  - type: Node
    name: node

  # Optional: an external policy engine consulted BEFORE RBAC so it can DENY.
  # RBAC cannot deny, so any true deny-list must live in a webhook or admission.
  - type: Webhook
    name: org-guardrails
    webhook:
      connectionInfo:
        type: KubeConfigFile
        kubeConfigFile: /etc/kubernetes/authorization/guardrails.kubeconfig
      authorizedTTL: 30s
      unauthorizedTTL: 5s
      timeout: 3s
      subjectAccessReviewVersion: v1
      matchConditionSubjectAccessReviewVersion: v1
      failurePolicy: Deny
      matchConditions:
        # Only bother the webhook for high-risk resources; everything else
        # short-circuits to RBAC. Reduces latency and blast radius of an outage.
        - expression: >-
            request.resource.group == 'rbac.authorization.k8s.io' ||
            request.resource.resource == 'secrets'

  # RBAC last: the authoritative allow-list.
  - type: RBAC
    name: rbac
```

Wire it into the static Pod manifest `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.0
      command:
        - kube-apiserver
        - --advertise-address=10.0.0.11
        - --allow-privileged=true
        - --authorization-config=/etc/kubernetes/authorization/config.yaml
        - --enable-admission-plugins=NodeRestriction,ServiceAccount
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --anonymous-auth=false
        - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-maxage=30
        - --audit-log-maxbackup=10
        - --audit-log-maxsize=100
        - --profiling=false
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
        - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
      volumeMounts:
        - name: authz
          mountPath: /etc/kubernetes/authorization
          readOnly: true
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        - name: audit-log
          mountPath: /var/log/kubernetes/audit
  volumes:
    - name: authz
      hostPath:
        path: /etc/kubernetes/authorization
        type: Directory
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-log
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

> **Operational note.** The structured `AuthorizationConfiguration` reached GA at `apiserver.config.k8s.io/v1` in v1.32; clusters on v1.30/v1.31 use `v1beta1`. On any cluster where you are unsure, `kubectl -n kube-system get pod kube-apiserver-<node> -o yaml | grep authorization` tells you which form is in use in seconds. The legacy equivalent is `--authorization-mode=Node,RBAC`.

Because the apiserver runs as a static Pod, editing the manifest triggers an in-place restart by the kubelet. A syntax error means the API server does not come back — always keep a copy:

```
$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE    NAME             ATTEMPT  POD ID
9f1c0a2b3d4e5  4c2f1a9e0b3d7  18 seconds ago  Running  kube-apiserver   3        7a1b2c3d4e5f6
```

---

## 3. The RBAC object model and evaluation semantics

Four objects, all in `rbac.authorization.k8s.io/v1` (the `v1alpha1`/`v1beta1` variants were removed in v1.22).

| Object | Scope of the *rules* | Scope of the *grant* | Can reference |
|---|---|---|---|
| `Role` | one namespace | — | — |
| `ClusterRole` | cluster-wide (incl. cluster-scoped resources and `nonResourceURLs`) | — | — |
| `RoleBinding` | — | one namespace | a `Role` **in the same namespace**, or *any* `ClusterRole` |
| `ClusterRoleBinding` | — | all namespaces + cluster scope | a `ClusterRole` only |

The non-obvious combination is **`RoleBinding` → `ClusterRole`**. This is the single most useful pattern in multi-tenant platforms: author the permission set *once* as a `ClusterRole`, then project it into N namespaces with N cheap `RoleBinding`s. The projection is lossy in a safe direction — when a `ClusterRole` is bound via a `RoleBinding`, only its namespaced-resource rules take effect; rules covering cluster-scoped resources (`nodes`, `persistentvolumes`, `clusterroles`) and `nonResourceURLs` are **silently ignored**.

### 3.1 Anatomy of a rule

```yaml
rules:
  - apiGroups:     [""]                       # "" = core group. "*" = all groups.
    resources:     ["pods", "pods/log"]       # subresources use the slash form
    resourceNames: ["frontend-0"]             # optional; only for name-carrying requests
    verbs:         ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics", "/healthz"] # ClusterRole only; mutually exclusive
    verbs:           ["get"]                  # with apiGroups/resources
```

Evaluation is a pure union: a request is allowed if **any rule in any Role/ClusterRole bound to the subject (by user, by group, or by ServiceAccount)** matches all of `{apiGroup, resource, subresource, name, verb, namespace}`. There is no ordering, no precedence, no negation.

**Verbs** and the HTTP methods they map to:

| Verb | HTTP | Notes |
|---|---|---|
| `get` | GET (named) | includes reading subresources like `pods/log` |
| `list` | GET (collection) | returns full objects — `list` on `secrets` is `get` on all of them |
| `watch` | GET `?watch=1` | same data exposure as `list` |
| `create` | POST | object name unknown at authz time |
| `update` | PUT | full replace |
| `patch` | PATCH | strategic-merge/JSON-patch; equivalent power to `update` |
| `delete` | DELETE (named) | |
| `deletecollection` | DELETE (collection) | often forgotten in "read-write" roles |
| `bind` | — | virtual verb on `roles`/`clusterroles`; bypasses the escalation check |
| `escalate` | — | virtual verb on `roles`/`clusterroles`; bypasses the escalation check |
| `impersonate` | — | on `users`, `groups`, `serviceaccounts`, `uids` in `authentication.k8s.io` |
| `approve` / `sign` | — | on `certificatesigningrequests/approval` and `/status` (signers) |

### 3.2 `resourceNames` — precise limits and precise traps

`resourceNames` restricts a rule to named instances. It only functions for requests whose path **carries the object name**:

| Verb | `resourceNames` effective? | Why |
|---|---|---|
| `get`, `update`, `patch`, `delete` | ✅ yes | name is in the URL path |
| `create` | ❌ no | name is in the body (and may be `generateName`) |
| `list`, `watch`, `deletecollection` | ❌ no | collection request, no name in path |

The trap: a role granting `["get","list"]` on `secrets` with `resourceNames: ["db-credentials"]` gives `get` on that one Secret **and no `list` at all**. Users then report "I can't see any secrets" — that is correct behaviour, not a bug. Conversely, granting `list` *without* `resourceNames` alongside a name-restricted `get` re-exposes every Secret in the namespace, since `list` returns full object bodies.

RBAC also has **no field-selector or label-selector awareness**. `list pods --field-selector metadata.name=x` is still authorized as an unconstrained `list`.

### 3.3 Wildcards and CRDs

`apiGroups: ["*"]`, `resources: ["*"]`, `verbs: ["*"]` match everything **including resources that do not exist yet**. Installing an operator that registers a new CRD instantly widens every wildcard role in the cluster. This is the argument against `*` that survives contact with a real platform: it is not merely broad, it is *retroactively* broad.

For a CRD, the `apiGroups` value is the CRD's `spec.group`, and `resources` is `spec.names.plural`:

```
$ kubectl get crd certificates.cert-manager.io -o jsonpath='{.spec.group}/{.spec.names.plural}{"\n"}'
cert-manager.io/certificates
```

### 3.4 Aggregated ClusterRoles

A `ClusterRole` carrying an `aggregationRule` has its `rules` field **managed by the controller-manager** — anything you write there is overwritten. The controller unions the rules of every `ClusterRole` matching the selectors.

The built-in `admin`, `edit`, and `view` roles are aggregated, which is the supported extension point for CRDs:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-certificates-view
  labels:
    # Rules below are merged into the built-in "view" ClusterRole,
    # and transitively into "edit" and "admin" (they aggregate view).
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates", "certificaterequests", "issuers"]
    verbs:     ["get", "list", "watch"]
```

Security consequence to internalise: **anyone who can create a `ClusterRole` with an aggregation label can silently widen `view`/`edit`/`admin` cluster-wide.** The escalation check (§6.1) applies at creation time, but this is nonetheless a control point worth policing with admission.

### 3.5 Default roles and auto-reconciliation

| ClusterRole | Bound by default to | Grants | Security notes |
|---|---|---|---|
| `cluster-admin` | Group `system:masters` (binding `cluster-admin`) | `*` on `*` + all `nonResourceURLs` | Bypasses everything except admission |
| `admin` | nothing | Full namespace R/W **including** `roles`/`rolebindings` and `secrets` | Can self-escalate to any SA in the namespace |
| `edit` | nothing | Namespace R/W, **no** `roles`/`rolebindings` | **Can read Secrets** and run Pods as any namespace SA → equivalent to every SA in the namespace |
| `view` | nothing | Namespace read-only | **Explicitly excludes `secrets`**, precisely because reading them yields SA credentials |
| `system:basic-user` | Group `system:authenticated` | `create` on `selfsubject*reviews` | Harmless; enables `kubectl auth can-i` |
| `system:discovery` | Group `system:authenticated` | `get` on `/api*`, `/openapi*`, `/version` | API surface discovery |
| `system:public-info-viewer` | Groups `system:authenticated` **and `system:unauthenticated`** | `get` on `/healthz`, `/livez`, `/readyz`, `/version` | The only default grant to unauthenticated users |

On every start, `kube-apiserver` **reconciles** the bootstrap roles and bindings: deleted defaults are recreated, and removed rules are re-added. Deleting the `cluster-admin` ClusterRoleBinding is therefore not a durable hardening step. To opt a specific default object out of reconciliation:

```yaml
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "false"
```

Reconciliation is additive: it will re-add missing rules and subjects but will not remove extra ones you added. That asymmetry is why default roles drift.

---

## 4. Trade-off analysis

### 4.1 Authorization modules

| Module | Decision types | Data source | Dynamic? | Fit |
|---|---|---|---|---|
| `Node` | allow / no-opinion | Graph of node→pod→secret/configmap/pvc relations | yes | **Mandatory.** Restricts kubelets to their own node's objects. Pair with `NodeRestriction` admission. |
| `RBAC` | allow / no-opinion | API objects in etcd | yes | **Mandatory.** The allow-list of record. |
| `ABAC` | allow / no-opinion | Static JSON-lines file on the control-plane host | **no** — requires apiserver restart | Legacy. No API, no audit trail, no deny. Avoid. |
| `Webhook` | allow / **deny** / no-opinion | External HTTPS service | yes | The only way to express true deny in authz. Costs latency on every request; needs `failurePolicy` and TTL tuning. |
| `AlwaysAllow` | allow | — | — | Test clusters only. Placing it anywhere in the chain disables RBAC. |
| `AlwaysDeny` | deny | — | — | Diagnostics only. |

### 4.2 Multi-tenant RBAC topologies

| Strategy | Blast radius | Operational cost | Drift risk | When to choose |
|---|---|---|---|---|
| Per-namespace `Role` + `RoleBinding`, hand-written | Minimal | High (N× objects, N× reviews) | High — copies diverge | Small clusters, highly bespoke tenants |
| Shared `ClusterRole` projected by `RoleBinding` | Minimal (same as above) | **Low** — one definition, N thin bindings | Low — single source of truth | **Default recommendation** for platform teams |
| Aggregated `ClusterRole` extending `view`/`edit`/`admin` | Cluster-wide if mislabelled | Low | Medium — a stray label widens defaults | CRD/operator vendors publishing role fragments |
| `ClusterRoleBinding` to a broad role | **Whole cluster** | Lowest | — | Genuine cluster-scoped agents only (CNI, CSI, metrics) |
| Generated from IdP groups (OIDC) via GitOps | Minimal | Medium up-front, low steady-state | **Lowest** — reconciled continuously | Regulated / audited environments |

### 4.3 Identity carriers

| Carrier | Rotation | Revocation | Group support | Verdict |
|---|---|---|---|---|
| x509 client cert (CN=user, O=group) | Manual re-issue | **None short of rotating the CA** — no CRL check by the apiserver | via `O` (repeatable) | Break-glass only. Keep TTL short. |
| SA token, projected/bound (`TokenRequest`) | Automatic by kubelet | Bound to Pod/SA lifetime; invalid once the Pod is gone | implicit `system:serviceaccounts[:ns]` | **Default for workloads.** |
| SA token, legacy Secret-based | Never | Delete the Secret | same | Not auto-created since v1.24. Purge any survivors. |
| OIDC id_token | Provider TTL | Provider-side | via claim (`groups`) | **Default for humans.** |
| Static token file | Never | Restart apiserver | limited | Deprecated. Remove. |

---

## 5. Reference implementation: a least-privilege service

The scenario: a `reporter` workload in namespace `payments` must read its own ConfigMaps, read exactly one Secret, list Pods in `payments`, and read Pod logs. Nothing else. It must not be able to read any other Secret, create anything, or see any other namespace.

### 5.1 Namespace, ServiceAccount, Role, RoleBinding

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
---
# Dedicated identity. Never reuse the namespace "default" ServiceAccount:
# it is shared by every workload that forgets to set serviceAccountName.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: reporter
  namespace: payments
# Belt-and-braces: even if a Pod spec forgets to opt out, tokens are not
# mounted for Pods using this SA unless the Pod explicitly sets it to true.
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: reporter
  namespace: payments
rules:
  # 1) Pod inventory and logs. "pods/log" is a subresource: it needs its own
  #    entry, and the verb is "get" (there is no "list" on a subresource).
  - apiGroups: [""]
    resources: ["pods"]
    verbs:     ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs:     ["get"]

  # 2) Non-sensitive configuration, read-only.
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs:     ["get", "list", "watch"]

  # 3) Exactly one Secret, by name. NOTE the deliberate absence of "list":
  #    adding it here would expose every Secret in the namespace, because
  #    resourceNames cannot constrain a collection request.
  - apiGroups:     [""]
    resources:     ["secrets"]
    resourceNames: ["reporting-db-credentials"]
    verbs:         ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reporter
  namespace: payments
subjects:
  - kind: ServiceAccount
    name: reporter
    namespace: payments
roleRef:
  # roleRef is IMMUTABLE. Changing the target role requires delete + recreate.
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: reporter
```

### 5.2 The consuming Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reporter
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels:
      app: reporter
  template:
    metadata:
      labels:
        app: reporter
    spec:
      serviceAccountName: reporter
      # Explicit opt-in for THIS workload only. Everything else using the
      # "reporter" SA still gets no token, thanks to the SA-level default.
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: reporter
          image: registry.example.com/payments/reporter@sha256:3f1a9c2e7b5d4086f1c2a9b7d3e5f60718293a4b5c6d7e8f9012a3b4c5d6e7f8
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: KUBERNETES_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          volumeMounts:
            - name: kube-api-access
              mountPath: /var/run/secrets/kubernetes.io/serviceaccount
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests: { cpu: "50m",  memory: "64Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
      volumes:
        # Explicit projected volume: 1h token TTL (kubelet refreshes at 80%),
        # audience-bound so the token is rejected by anything but the apiserver.
        - name: kube-api-access
          projected:
            defaultMode: 0444
            sources:
              - serviceAccountToken:
                  path: token
                  expirationSeconds: 3600
                  audience: https://kubernetes.default.svc.cluster.local
              - configMap:
                  name: kube-root-ca.crt
                  items:
                    - key: ca.crt
                      path: ca.crt
              - downwardAPI:
                  items:
                    - path: namespace
                      fieldRef:
                        fieldPath: metadata.namespace
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 16Mi
```

### 5.3 The shared-ClusterRole projection pattern

Define once:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:namespace-operator
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs:     ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "events", "endpoints"]
    verbs:     ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods/log", "pods/status"]
    verbs:     ["get"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs:     ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs:     ["get", "list", "watch"]
  # Deliberately absent: secrets, serviceaccounts, roles, rolebindings,
  # pods/exec, pods/attach, pods/portforward, pods/ephemeralcontainers.
```

Project into namespaces with thin bindings — note this grants *only within* `payments`, despite referencing a ClusterRole:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-operators
  namespace: payments
subjects:
  - kind: Group
    name: oidc:payments-sre          # from the OIDC "groups" claim + --oidc-group-prefix=oidc:
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: platform:namespace-operator
```

### 5.4 A human identity via CSR (break-glass / exam pattern)

```
$ openssl genrsa -out sre-alex.key 3072
$ openssl req -new -key sre-alex.key -out sre-alex.csr \
    -subj "/CN=sre-alex/O=oidc:payments-sre"
$ cat sre-alex.csr | base64 -w0 > sre-alex.csr.b64
```

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: sre-alex
spec:
  # base64 of the PEM CSR, single line
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0K...
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400          # 24h — short TTL compensates for no revocation
  usages:
    - client auth
```

```
$ kubectl apply -f sre-alex-csr.yaml
certificatesigningrequest.certificates.k8s.io/sre-alex created

$ kubectl get csr sre-alex
NAME       AGE   SIGNERNAME                            REQUESTOR           REQUESTEDDURATION   CONDITION
sre-alex   4s    kubernetes.io/kube-apiserver-client   kubernetes-admin    24h                 Pending

$ kubectl certificate approve sre-alex
certificatesigningrequest.certificates.k8s.io/sre-alex approved

$ kubectl get csr sre-alex -o jsonpath='{.status.certificate}' | base64 -d > sre-alex.crt
$ openssl x509 -in sre-alex.crt -noout -subject -dates
subject=CN = sre-alex, O = oidc:payments-sre
notBefore=Jul 30 09:12:00 2026 GMT
notAfter=Jul 31 09:12:00 2026 GMT
```

The `CN` becomes the username and each `O` becomes a group — so this certificate inherits the `payments-operators` RoleBinding above with no further RBAC changes. **There is no revocation**: the apiserver does not consult a CRL or OCSP. The only mitigations are short `expirationSeconds` and rotating the client CA.

### 5.5 Admission guardrail: block new `cluster-admin` bindings

RBAC cannot deny, so the deny-list lives in admission. `ValidatingAdmissionPolicy` (GA since v1.30) does this in-process, with no webhook to keep alive:

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: restrict-cluster-admin-bindings.security.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["rbac.authorization.k8s.io"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["clusterrolebindings", "rolebindings"]
  matchConditions:
    # Never block the apiserver's own bootstrap reconciliation, or kubeadm.
    - name: exclude-control-plane
      expression: >-
        !(request.userInfo.username in
          ['system:apiserver', 'system:kube-controller-manager'])
  variables:
    - name: roleName
      expression: "object.roleRef.name"
    - name: subjectNames
      expression: "object.subjects.orValue([]).map(s, s.name)"
  validations:
    - expression: >-
        variables.roleName != 'cluster-admin' ||
        object.metadata.name in ['cluster-admin', 'kubeadm:cluster-admins']
      messageExpression: >-
        'binding to ClusterRole/cluster-admin is not permitted (attempted by ' +
        request.userInfo.username + '); file an exception with the platform team'
      reason: Forbidden
    - expression: >-
        !variables.subjectNames.exists(n, n == 'system:unauthenticated' ||
                                          n == 'system:anonymous')
      message: "RBAC must never be granted to anonymous or unauthenticated subjects"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: restrict-cluster-admin-bindings.security.example.com
spec:
  policyName: restrict-cluster-admin-bindings.security.example.com
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector: {}          # all namespaces + cluster scope
```

Verify it bites:

```
$ kubectl create clusterrolebinding oops --clusterrole=cluster-admin --serviceaccount=payments:reporter
error: failed to create clusterrolebinding: admission webhook denied the request:
ValidatingAdmissionPolicy 'restrict-cluster-admin-bindings.security.example.com'
with binding 'restrict-cluster-admin-bindings.security.example.com' denied request:
binding to ClusterRole/cluster-admin is not permitted (attempted by kubernetes-admin);
file an exception with the platform team
```

---

## 6. The privilege-escalation surface

This table is the operational core of the topic. Each row is a permission that *looks* mundane in a review and is in fact a path to cluster-admin.

| Permission | Escalation path | Mitigation |
|---|---|---|
| `create` on `pods` | Schedule a Pod with `serviceAccountName: <any SA in ns>`, `hostPID`, `hostPath: /`, `privileged: true` → node root → read every kubelet-mounted Secret and the kubelet client cert | PodSecurity `restricted`, no `create pods` for humans (use controllers), NodeRestriction |
| `create` on `deployments`/`jobs`/`cronjobs`/`daemonsets` | Same as above, indirectly — the controller creates the Pod for you | Identical; treat workload-controller `create` as Pod `create` |
| `get`/`list` on `secrets` | Read SA tokens (legacy), TLS keys, cloud credentials | Never grant `list` on secrets; use `resourceNames` + `get`; encryption-at-rest does not help against an authorized read |
| `create` on `serviceaccounts/token` | `TokenRequest` for *any* SA in the namespace → become it | Grant only to token-issuing controllers, always with `resourceNames` |
| `impersonate` on `groups` | `--as-group=system:masters` → instant cluster-admin | Never grant; if unavoidable, restrict with `resourceNames` and audit every use |
| `escalate` on `roles`/`clusterroles` | Author a role granting more than you hold | Reserve for the bootstrap controller |
| `bind` on `roles`/`clusterroles` | Bind an existing high-privilege role to yourself | Restrict with `resourceNames` to a curated allow-list |
| `get`/`create` on `nodes/proxy` | Reach the kubelet API directly → `exec` into any Pod on that node, bypassing apiserver RBAC and audit | Kubelet `--authorization-mode=Webhook`, `--anonymous-auth=false`; never grant `nodes/proxy` |
| `create` on `pods/exec`, `pods/attach`, `pods/portforward` | Enter a Pod that holds a stronger SA token | Separate "debug" roles, time-boxed, audited at `RequestResponse` |
| `patch` on `pods/ephemeralcontainers` | Inject a container into a running Pod, bypassing its original securityContext review | Same as `exec`; PodSecurity still applies but the target Pod's SA is inherited |
| `approve` on `certificatesigningrequests/approval` + `sign` | Issue a client cert with `O=system:masters` | Only the signer controller; audit CSR approvals |
| `update`/`patch` on `validatingadmissionpolicies` / `...webhookconfigurations` | Disable the guardrails, then escalate freely | Cluster-admin only; alert on any change |
| `create`/`update` on `clusterroles` with `aggregate-to-*` labels | Silently widen `view`/`edit`/`admin` cluster-wide | Admission policy on the aggregation labels |

### 6.1 The built-in escalation prevention

Kubernetes will refuse to let you create or update a Role/ClusterRole containing permissions you do not already hold:

```
$ kubectl --context=payments-sre apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: sneaky
  namespace: payments
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs:     ["*"]
EOF
Error from server (Forbidden): error when creating "STDIN": roles.rbac.authorization.k8s.io "sneaky"
is forbidden: user "sre-alex" (groups=["oidc:payments-sre" "system:authenticated"]) is attempting to
grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["secrets"], Verbs:["*"]}
```

The same check applies to bindings: you may only bind a role whose permissions you already hold. The two escape hatches are the virtual verbs `escalate` (on roles/clusterroles) and `bind` (on roles/clusterroles). Granting either is functionally equivalent to granting the target permissions — treat them as such in review.

### 6.2 Impersonation, concretely

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:limited-impersonator
rules:
  # Only these two identities, never arbitrary users, and NEVER groups.
  - apiGroups:     [""]
    resources:     ["serviceaccounts"]
    resourceNames: ["ci-runner", "backup-agent"]
    verbs:         ["impersonate"]
  # Deliberately NOT granted:
  #   resources: ["groups"]  -> would allow --as-group=system:masters
  #   resources: ["users"]   -> would allow --as=<any human>
  #   resources: ["uids"]    -> allows spoofing the UID field in audit records
```

Impersonation is fully recorded in the audit log (`impersonatedUser`), which makes a *narrow* grant an acceptable auditability trade-off. A broad grant is not.

### 6.3 `system:masters` and the kubeadm split

`system:masters` is bound to `cluster-admin` by the bootstrap `ClusterRoleBinding` named `cluster-admin`, which is auto-reconciled. Since kubeadm v1.29 the admin kubeconfigs are split:

| File | Certificate subject | Effective identity |
|---|---|---|
| `/etc/kubernetes/admin.conf` | `CN=kubernetes-admin, O=kubeadm:cluster-admins` | cluster-admin via the ordinary, *deletable* `kubeadm:cluster-admins` binding |
| `/etc/kubernetes/super-admin.conf` | `CN=kubernetes-super-admin, O=system:masters` | cluster-admin via the hardwired bootstrap binding; **RBAC changes cannot restrict it** |

```
$ kubectl --kubeconfig /etc/kubernetes/admin.conf auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]

$ sudo kubectl --kubeconfig /etc/kubernetes/super-admin.conf auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-super-admin
Groups      [system:masters system:authenticated]
```

Hardening action: `super-admin.conf` belongs on the control-plane node with mode `0600`, out of the CI system and off engineer laptops. It is the break-glass credential for the case where someone deletes the `kubeadm:cluster-admins` binding.

### 6.4 Anonymous access

```
$ kubectl get --raw /api --kubeconfig /dev/null --server https://10.0.0.11:6443 --insecure-skip-tls-verify
{"kind":"APIVersions","versions":["v1"],"serverAddressByClientCIDRs":[{"clientCIDR":"0.0.0.0/0","serverAddress":"10.0.0.11:6443"}]}
```

If that succeeds, anonymous auth is on and `system:anonymous`/`system:unauthenticated` is reaching `system:discovery` or `system:public-info-viewer`. Set `--anonymous-auth=false` on the apiserver. If health probes need unauthenticated access, recent releases allow scoping anonymous auth to specific endpoints via `AuthenticationConfiguration` (`anonymous.conditions` with `path`) — check whether the `AnonymousAuthConfigurableEndpoints` feature gate is enabled on your cluster before relying on it:

```
$ kubectl get --raw /metrics | grep 'kubernetes_feature_enabled.*AnonymousAuthConfigurableEndpoints'
kubernetes_feature_enabled{name="AnonymousAuthConfigurableEndpoints",stage="BETA"} 1
```

Regardless of the gate, audit for the anti-pattern:

```
$ kubectl get clusterrolebindings,rolebindings -A -o json \
  | jq -r '.items[] | select(.subjects[]?.name |
      IN("system:anonymous","system:unauthenticated","system:authenticated"))
      | "\(.kind)/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'
ClusterRoleBinding/system:basic-user -> ClusterRole/system:basic-user
ClusterRoleBinding/system:discovery -> ClusterRole/system:discovery
ClusterRoleBinding/system:public-info-viewer -> ClusterRole/system:public-info-viewer
```

Those three are the expected defaults. **Anything else in that list is a finding.** A binding of `system:authenticated` to a real role means every ServiceAccount in the cluster holds it — `system:serviceaccounts` is a member of `system:authenticated`.

---

## 7. CLI walkthrough with real terminal output

### 7.1 Who am I, and what can I do?

```
$ kubectl auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]

$ kubectl auth can-i --list --as=system:serviceaccount:payments:reporter -n payments
Resources                                       Non-Resource URLs                     Resource Names                Verbs
configmaps                                      []                                    []                            [get list watch]
pods                                            []                                    []                            [get list watch]
pods/log                                        []                                    []                            [get]
secrets                                         []                                    [reporting-db-credentials]    [get]
selfsubjectreviews.authentication.k8s.io        []                                    []                            [create]
selfsubjectaccessreviews.authorization.k8s.io   []                                    []                            [create]
selfsubjectrulesreviews.authorization.k8s.io    []                                    []                            [create]
                                                [/api/*]                              []                            [get]
                                                [/api]                                []                            [get]
                                                [/apis/*]                             []                            [get]
                                                [/apis]                               []                            [get]
                                                [/healthz]                            []                            [get]
                                                [/livez]                              []                            [get]
                                                [/openapi/*]                          []                            [get]
                                                [/openapi]                            []                            [get]
                                                [/readyz]                             []                            [get]
                                                [/version/]                           []                            [get]
                                                [/version]                            []                            [get]
```

`--as` performs impersonation, so it requires impersonation rights — which cluster-admin has. This is the fastest correctness check available.

### 7.2 Point checks — including the negatives

```
$ kubectl auth can-i get secret/reporting-db-credentials --as=system:serviceaccount:payments:reporter -n payments
yes

$ kubectl auth can-i list secrets --as=system:serviceaccount:payments:reporter -n payments
no

$ kubectl auth can-i get secret/other-app-tls --as=system:serviceaccount:payments:reporter -n payments
no

$ kubectl auth can-i create pods --as=system:serviceaccount:payments:reporter -n payments
no

$ kubectl auth can-i list pods --as=system:serviceaccount:payments:reporter -n billing
no

$ kubectl auth can-i '*' '*' --as=system:serviceaccount:payments:reporter -A
no
```

`--quiet` suppresses output and encodes the answer in the exit status, which is what you want in CI:

```
$ kubectl auth can-i --quiet create pods --as=system:serviceaccount:payments:reporter -n payments; echo "exit=$?"
exit=1
```

### 7.3 Testing with a real token rather than impersonation

Impersonation tests RBAC, but not the token plumbing. To test end-to-end:

```
$ TOKEN=$(kubectl -n payments create token reporter --duration=10m)
$ kubectl --token="$TOKEN" --server=https://10.0.0.11:6443 \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    -n payments get pods
NAME                        READY   STATUS    RESTARTS   AGE
reporter-7d9c4b8f6c-2xk4p   1/1     Running   0          6m12s
reporter-7d9c4b8f6c-l9mzq   1/1     Running   0          6m12s

$ kubectl --token="$TOKEN" --server=https://10.0.0.11:6443 \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    -n payments get secrets
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:payments:reporter"
cannot list resource "secrets" in API group "" in the namespace "payments"
```

Decode the token to confirm binding and TTL:

```
$ echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
{
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1785405600,
  "iat": 1785405000,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "3c1f9a2b-7d4e-4a86-9f01-2b3c4d5e6f70",
  "kubernetes.io": {
    "namespace": "payments",
    "serviceaccount": { "name": "reporter", "uid": "8a2b1c9d-4e5f-4061-9a2b-3c4d5e6f7081" }
  },
  "nbf": 1785405000,
  "sub": "system:serviceaccount:payments:reporter"
}
```

### 7.4 From inside the Pod (the attacker's view)

```
$ kubectl -n payments exec -it deploy/reporter -- sh
/ $ ls /var/run/secrets/kubernetes.io/serviceaccount/
ca.crt  namespace  token
/ $ TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
/ $ CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
/ $ curl -sS --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
      https://kubernetes.default.svc/api/v1/namespaces/payments/pods | head -c 120
{"kind":"PodList","apiVersion":"v1","metadata":{"resourceVersion":"418293"},"items":[{"metadata":{"name":"repo
/ $ curl -sS --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
      https://kubernetes.default.svc/api/v1/namespaces/payments/secrets
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "secrets is forbidden: User \"system:serviceaccount:payments:reporter\" cannot list resource \"secrets\" in API group \"\" in the namespace \"payments\"",
  "reason": "Forbidden",
  "details": { "kind": "secrets" },
  "code": 403
}
```

If `ls` on that path returns "No such file or directory", `automountServiceAccountToken: false` is working — that is the strongest possible outcome for a workload that does not talk to the API at all.

### 7.5 Programmatic authorization queries

`SubjectAccessReview` is what `can-i` uses under the hood, and it is available to any controller that needs to delegate:

```yaml
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:payments:reporter
  groups:
    - system:serviceaccounts
    - system:serviceaccounts:payments
    - system:authenticated
  resourceAttributes:
    namespace: payments
    group: ""
    resource: secrets
    verb: list
```

```
$ kubectl create -f sar.yaml -o jsonpath='{.status}{"\n"}'
{"allowed":false,"denied":false,"reason":"no relation found between subject and requested resource"}
```

Note `allowed:false, denied:false` — that is the "no-opinion" outcome, which the apiserver turns into a 403 because no later authorizer allows it.

### 7.6 Non-destructive convergence with `kubectl auth reconcile`

`kubectl apply` on RBAC objects replaces rules and subjects wholesale, which can strip permissions another team added. `kubectl auth reconcile` merges instead, and understands `roleRef` immutability:

```
$ kubectl auth reconcile -f rbac/ --dry-run=client
clusterrole.rbac.authorization.k8s.io/platform:namespace-operator reconciled
    reconciliation required create
    missing rules added:
        {Verbs:["get" "list" "watch"], APIGroups:["networking.k8s.io"], Resources:["ingresses" "networkpolicies"]}
rolebinding.rbac.authorization.k8s.io/payments-operators reconciled (dry run)

$ kubectl auth reconcile -f rbac/ --remove-extra-permissions --remove-extra-subjects
clusterrole.rbac.authorization.k8s.io/platform:namespace-operator reconciled
rolebinding.rbac.authorization.k8s.io/payments-operators reconciled
```

Use the plain form for additive GitOps; the `--remove-extra-*` flags when the manifests are the sole source of truth and you are deliberately pruning drift.

---

## 8. Verification, auditing and failure diagnosis

### 8.1 Reading a 403 correctly

```
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:payments:reporter"
cannot list resource "pods" in API group "" in the namespace "billing"
```

Parse it as five independent variables and check each:

| Field in the message | What to verify |
|---|---|
| `User "..."` | The identity actually presented — not the one you intended. A stale kubeconfig or a Pod that forgot `serviceAccountName` lands here. |
| `cannot <verb>` | Is the verb in your rule? `list` ≠ `get`; `patch` ≠ `update`; `deletecollection` ≠ `delete`. |
| `resource "..."` | Plural, lowercase, and the *subresource* form (`pods/log`) needs its own rule. |
| `API group "..."` | `""` is core. `apps`, `batch`, `networking.k8s.io`, `rbac.authorization.k8s.io` are separate. A `ClusterRole` for `deployments` under `apiGroups: [""]` matches nothing. |
| `in the namespace "..."` | Is the binding in *that* namespace? A `RoleBinding` in `payments` grants nothing in `billing`. |

A subtly different message means something different:

```
Error from server (Forbidden): pods is forbidden: User "sre-alex" cannot list resource "pods"
in API group "" at the cluster scope
```

"at the cluster scope" means the request was for **all namespaces** (`-A` / no namespace). That requires a `ClusterRoleBinding`; a `RoleBinding` will never satisfy it, even to the same `ClusterRole`.

### 8.2 The eight-point RBAC triage checklist

Run these in order; each eliminates one class of cause.

```bash
# 1. Which identity is actually reaching the apiserver?
kubectl auth whoami

# 2. What does the authorizer think that identity can do here?
kubectl auth can-i --list --as=system:serviceaccount:payments:reporter -n payments

# 3. Does the binding exist, and does it point where you think?
kubectl -n payments get rolebinding -o wide

# 4. Does the subject in the binding match EXACTLY? (kind, name, namespace)
kubectl -n payments get rolebinding reporter -o jsonpath='{.subjects}' | jq .

# 5. Are the rules what you wrote? (apply may have replaced them)
kubectl -n payments describe role reporter

# 6. Is the API group / resource string correct for this resource?
kubectl api-resources | grep -E '^NAME|deployments|networkpolicies'

# 7. Is roleRef stale? (immutable — an "updated" binding may still point elsewhere)
kubectl -n payments get rolebinding reporter -o jsonpath='{.roleRef}' ; echo

# 8. Is RBAC even in the chain, and is something permissive ahead of it?
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -i authoriz
```

Step 4 catches the single most common mistake: `kind: ServiceAccount` subjects **require** an explicit `namespace` field, because a `ClusterRoleBinding` has no namespace of its own and a `RoleBinding` may legitimately grant to a ServiceAccount from another namespace.

```
$ kubectl -n payments get rolebinding reporter -o jsonpath='{.subjects}' | jq .
[
  {
    "kind": "ServiceAccount",
    "name": "reporter",
    "namespace": "payments"
  }
]
```

Step 7 catches the immutability trap:

```
$ kubectl -n payments patch rolebinding reporter --type=merge \
    -p '{"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"view"}}'
The RoleBinding "reporter" is invalid: roleRef: Invalid value:
rbac.RoleRef{APIGroup:"rbac.authorization.k8s.io", Kind:"ClusterRole", Name:"view"}:
cannot change roleRef

$ kubectl -n payments delete rolebinding reporter && kubectl apply -f rolebinding.yaml
rolebinding.rbac.authorization.k8s.io "reporter" deleted
rolebinding.rbac.authorization.k8s.io/reporter created
```

### 8.3 Server-side evidence: audit annotations

Every audited request carries the authorizer's verdict as annotations, which is the authoritative answer to "*why* was this allowed?".

Audit policy focused on the RBAC and credential surface:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Full bodies for every RBAC mutation — this is the change log that matters.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Any use of impersonation, and any exec/attach/portforward.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]
      - group: "authentication.k8s.io"
        resources: ["*"]

  # Secret access: metadata only — never log Secret bodies into a log pipeline.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]

  # Anonymous and unauthenticated traffic, whatever it touches.
  - level: Metadata
    userGroups: ["system:unauthenticated"]

  # Silence the high-volume, low-value control-plane read loop.
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
    verbs: ["get", "list", "watch"]

  - level: Metadata
```

A resulting record:

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "6b2a9f1c-3d4e-4a58-9b07-1c2d3e4f5061",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/payments/secrets?limit=500",
  "verb": "list",
  "user": {
    "username": "system:serviceaccount:payments:reporter",
    "uid": "8a2b1c9d-4e5f-4061-9a2b-3c4d5e6f7081",
    "groups": ["system:serviceaccounts", "system:serviceaccounts:payments", "system:authenticated"]
  },
  "sourceIPs": ["10.244.2.17"],
  "objectRef": { "resource": "secrets", "namespace": "payments", "apiVersion": "v1" },
  "responseStatus": { "metadata": {}, "status": "Failure", "reason": "Forbidden", "code": 403 },
  "requestReceivedTimestamp": "2026-07-30T11:42:17.881204Z",
  "stageTimestamp": "2026-07-30T11:42:17.884901Z",
  "annotations": {
    "authorization.k8s.io/decision": "forbid",
    "authorization.k8s.io/reason": ""
  }
}
```

And for an allowed request, `reason` names the exact binding — this is how you answer "which grant is responsible?" without guessing:

```
$ sudo jq -r 'select(.objectRef.resource=="secrets")
    | "\(.user.username)\t\(.verb)\t\(.annotations["authorization.k8s.io/decision"])\t\(.annotations["authorization.k8s.io/reason"])"' \
    /var/log/kubernetes/audit/audit.log | sort -u | head
system:serviceaccount:kube-system:generic-garbage-collector  list  allow  RBAC: allowed by ClusterRoleBinding "system:controller:generic-garbage-collector" of ClusterRole "system:controller:generic-garbage-collector" to ServiceAccount "generic-garbage-collector/kube-system"
system:serviceaccount:payments:reporter                      get   allow  RBAC: allowed by RoleBinding "reporter/payments" of Role "reporter" to ServiceAccount "reporter/payments"
system:serviceaccount:payments:reporter                      list  forbid
```

Hunt for the dangerous grants across all history:

```
$ sudo jq -r 'select(.annotations["authorization.k8s.io/reason"] // "" | test("cluster-admin"))
    | [.requestReceivedTimestamp, .user.username, .verb, .objectRef.resource] | @tsv' \
    /var/log/kubernetes/audit/audit.log | tail -5
2026-07-30T09:14:02.113Z  kubernetes-admin  create  clusterrolebindings
2026-07-30T09:14:55.907Z  kubernetes-admin  delete  pods
2026-07-30T10:02:31.442Z  sre-alex          patch   deployments
```

Impersonation shows up as a distinct `impersonatedUser` field — alert on any occurrence you did not authorize:

```
$ sudo jq -r 'select(.impersonatedUser != null)
    | [.requestReceivedTimestamp, .user.username, "->", .impersonatedUser.username,
       (.impersonatedUser.groups // [] | join(","))] | @tsv' \
    /var/log/kubernetes/audit/audit.log
2026-07-30T11:41:02.884Z  kubernetes-admin  ->  system:serviceaccount:payments:reporter  system:serviceaccounts,system:serviceaccounts:payments
```

### 8.4 Verbose authorizer logging (last resort)

When the audit reason is empty and you need the authorizer's internal view, raise verbosity on the RBAC package only:

```
$ sudo sed -i '/- kube-apiserver/a\    - --vmodule=rbac*=5' /etc/kubernetes/manifests/kube-apiserver.yaml
$ sudo crictl logs -f $(sudo crictl ps -q --name kube-apiserver) 2>&1 | grep -i rbac
I0730 11:42:17.884213       1 rbac.go:104] RBAC: no rules authorize user "system:serviceaccount:payments:reporter" with groups ["system:serviceaccounts" "system:serviceaccounts:payments" "system:authenticated"] to "list" resource "secrets" in API group "" in the namespace "payments"
```

The exact log format shifts between releases; the content does not. **Revert this immediately** — v5 on a busy apiserver produces gigabytes per hour and can itself become an availability incident.

### 8.5 Continuous audit queries

These are the checks worth running on a schedule. All are pure `kubectl` + `jq`, so they work on an exam VM and in production alike.

```bash
# A. Who holds cluster-admin, by any binding?
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name == "cluster-admin")
  | .metadata.name as $b | .subjects[]? | "\($b)\t\(.kind)/\(.namespace // "-")/\(.name)"'
```
```
cluster-admin           Group/-/system:masters
kubeadm:cluster-admins  Group/-/kubeadm:cluster-admins
```

```bash
# B. Every non-system role containing a wildcard.
kubectl get clusterroles,roles -A -o json | jq -r '
  .items[]
  | select(.metadata.name | startswith("system:") | not)
  | select(.rules[]? | (.verbs // [] | index("*")) or (.resources // [] | index("*")) or (.apiGroups // [] | index("*")))
  | "\(.kind)\t\(.metadata.namespace // "cluster")\t\(.metadata.name)"'
```
```
ClusterRole  cluster   legacy-ci-runner
Role         staging   debug-everything
```

```bash
# C. Any role granting the escalation verbs.
kubectl get clusterroles,roles -A -o json | jq -r '
  .items[] as $r | $r.rules[]?
  | select((.verbs // []) | any(. == "escalate" or . == "bind" or . == "impersonate"))
  | "\($r.kind)/\($r.metadata.namespace // "cluster")/\($r.metadata.name)\tverbs=\(.verbs)\tresources=\(.resources)"'
```

```bash
# D. Which ServiceAccounts are bound to anything at all?
kubectl get clusterrolebindings,rolebindings -A -o json | jq -r '
  .items[] | .roleRef.name as $role | .metadata.namespace as $ns | .kind as $k
  | .subjects[]? | select(.kind == "ServiceAccount")
  | "\($k)\t\($ns // "cluster")\t\(.namespace)/\(.name)\t-> \($role)"' | sort
```

```bash
# E. Pods still mounting a token they may not need.
kubectl get pods -A -o json | jq -r '
  .items[]
  | select([.spec.volumes[]? | select(.projected.sources[]?.serviceAccountToken)] | length > 0)
  | "\(.metadata.namespace)/\(.metadata.name)\tsa=\(.spec.serviceAccountName)"' | head
```

```bash
# F. Any workload still using the namespace "default" ServiceAccount.
kubectl get pods -A -o json | jq -r '
  .items[] | select((.spec.serviceAccountName // "default") == "default")
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

```bash
# G. Legacy, non-expiring ServiceAccount token Secrets (should be empty post-1.24).
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SA:.metadata.annotations.kubernetes\.io/service-account\.name'
```

In production, complement these with the ecosystem tooling — `krew install who-can rbac-tool access-matrix` gives you `kubectl who-can delete pods -n payments` and `kubectl rbac-tool viz` for a graph. Note that no such tooling is available in the exam environment: the `jq` recipes above are the portable form, and are what you should practise.

---

## 9. Hardening checklist

Apply in this order; each step is independently verifiable.

1. **Chain is `Node` then `RBAC`.** No `AlwaysAllow`, no `ABAC`, no permissive webhook ahead of RBAC. Verify with the apiserver command line.
2. **`--anonymous-auth=false`**, or anonymous scoped to health endpoints only. Verify with an unauthenticated `curl` to `/api`.
3. **No binding to `system:unauthenticated`, `system:anonymous`, or `system:authenticated`** beyond the three bootstrap defaults. Verify with query (A)/§6.4.
4. **`cluster-admin` bound to at most the bootstrap subjects.** Every human path to cluster-admin goes through an audited, time-boxed process. Verify with query (A).
5. **`super-admin.conf` off engineer laptops and CI**, mode `0600`, on the control-plane node only.
6. **One ServiceAccount per workload**, never `default`. Verify with query (F).
7. **`automountServiceAccountToken: false`** on every ServiceAccount and on the `default` SA of every namespace; opt in per-Pod. Verify with query (E).
8. **No wildcards** in `apiGroups`, `resources`, or `verbs` outside `system:` roles. Verify with query (B).
9. **No `escalate`, `bind`, `impersonate`** outside the control plane. Verify with query (C).
10. **No `list`/`watch` on `secrets`** for application workloads; use `get` + `resourceNames`, or better, an external secret store with short-lived credentials.
11. **No `nodes/proxy`, `pods/exec`, `pods/attach`, `pods/portforward`, `pods/ephemeralcontainers`** in steady-state roles. Separate break-glass roles, audited at `RequestResponse`.
12. **Namespace-scoped by default.** A `ClusterRoleBinding` requires written justification; a `RoleBinding`→`ClusterRole` projection is the default idiom.
13. **Audit policy covers RBAC mutations at `RequestResponse`** and Secret access at `Metadata`. Verify by making a change and grepping the log.
14. **Admission guardrails** (`ValidatingAdmissionPolicy`) deny new `cluster-admin` bindings and grants to anonymous subjects.
15. **RBAC lives in Git**, reconciled with `kubectl auth reconcile`, and the audit queries above run on a schedule with alerting on new findings.

Disable the `default` ServiceAccount's automount across every namespace in one pass:

```
$ for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    kubectl -n "$ns" patch serviceaccount default \
      -p '{"automountServiceAccountToken": false}' 2>/dev/null
  done
serviceaccount/default patched
serviceaccount/default patched
serviceaccount/default patched
...

$ kubectl get sa -A -o json | jq -r '
    .items[] | select(.metadata.name=="default")
    | "\(.metadata.namespace)\tautomount=\(.automountServiceAccountToken // true)"'
default       automount=false
kube-node-lease  automount=false
kube-public   automount=false
kube-system   automount=false
payments      automount=false
```

Control-plane components in `kube-system` set `automountServiceAccountToken` explicitly at the Pod level, so this patch does not break them — but confirm with `kubectl -n kube-system get pods` before and after on any cluster with third-party operators.

---

## 10. Exam-speed reminders

- `kubectl create role`/`clusterrole`/`rolebinding`/`clusterrolebinding` with `--dry-run=client -o yaml` is faster and less error-prone than hand-writing YAML:

```
$ kubectl create role reporter -n payments \
    --verb=get,list,watch --resource=pods,configmaps \
    --dry-run=client -o yaml
```
```
$ kubectl create clusterrole reader \
    --verb=get --resource=secrets --resource-name=db-creds \
    --dry-run=client -o yaml
```
```
$ kubectl create rolebinding reporter -n payments \
    --role=reporter --serviceaccount=payments:reporter \
    --dry-run=client -o yaml
```
- `--serviceaccount=<ns>:<name>` for SA subjects, `--user=` for users, `--group=` for groups. Mixing them up produces a binding that silently matches nobody.
- `--resource=pods/log` and `--resource=pods/exec` work in `kubectl create role` for subresources.
- Verify every answer with `kubectl auth can-i ... --as=...`, including at least one **negative** check. A rule that is too broad passes the positive check and fails the task.
- `roleRef` is immutable: `delete` then `create`, never `edit`.
- If a task says "in namespace X only", the answer is a `RoleBinding`, even when it references a `ClusterRole`.

---

## Referencias

- Kubernetes — *Using RBAC Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — *Authorization Overview*: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — *Authenticating*: https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes — *Node Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Kubernetes — *Webhook Mode*: https://kubernetes.io/docs/reference/access-authn-authz/webhook/
- Kubernetes — *Admission Controllers Reference (NodeRestriction, ServiceAccount)*: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — *Validating Admission Policy*: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — *Managing Service Accounts*: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — *Configure Service Accounts for Pods*: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — *Certificate Signing Requests*: https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Kubernetes — *Certificates and Certificate Management*: https://kubernetes.io/docs/tasks/administer-cluster/certificates/
- Kubernetes — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — *kube-apiserver Reference*: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — *kubectl auth (can-i, whoami, reconcile)*: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/
- Kubernetes — *Controlling Access to the Kubernetes API*: https://kubernetes.io/docs/concepts/security/controlling-access/
- Kubernetes — *Securing a Cluster*: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Kubernetes — *Kubernetes API Access Control (RBAC good practices)*: https://kubernetes.io/docs/concepts/security/rbac-good-practices/
- Kubernetes — *kubeadm: super-admin.conf and admin.conf*: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- Kubernetes — *Feature Gates*: https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/
- CNCF — *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF — *Curriculum repository*: https://github.com/cncf/curriculum
- CIS — *Kubernetes Benchmark* (sections 1.2 API server, 5.1 RBAC and Service Accounts): https://www.cisecurity.org/benchmark/kubernetes
- NSA/CISA — *Kubernetes Hardening Guide*: https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF