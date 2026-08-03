# CKS 3.2 — Exercise Caution in Using Service Accounts

**Domain:** Cluster Hardening (15%) · **Topic weight:** 3.75 · **Kubernetes:** v1.34

---

## 1. The Production Architecture Problem

### 1.1 Every Pod Is an Authenticated Principal by Default

Kubernetes has no notion of an "anonymous workload". The moment a Pod is admitted, the `ServiceAccount` admission plugin resolves a ServiceAccount for it — the one you named, or `default` — and, unless explicitly told otherwise, injects a signed JWT into the container filesystem at `/var/run/secrets/kubernetes.io/serviceaccount/token`.

This means the *baseline* state of a cluster is: **every process in every container holds a bearer credential for the control plane API.** Not a capability scoped to what the workload needs — a full identity, presented to `kubernetes.default.svc:443`, which is reachable from every Pod network namespace unless a NetworkPolicy says otherwise.

From an SRE/attacker-modelling perspective, this collapses two things that should be separate:

| Concern | What it should be | What the default gives you |
|---|---|---|
| Network reachability of the API server | opt-in | universal (ClusterIP `kubernetes.default`) |
| Possession of a control-plane credential | opt-in | universal (automount `true`) |
| Blast radius of that credential | per-workload | per-*namespace* (shared `default` SA) |

The third row is the one that burns teams. `default` is a shared, namespace-scoped identity. The instant someone runs `kubectl create rolebinding debug --clusterrole=edit --serviceaccount=payments:default -n payments` to unblock a demo, **every** workload in `payments` that never set `serviceAccountName` silently gains `edit`. There is no audit event that says "17 unrelated Deployments were just promoted" — the grant is invisible at the workload level.

### 1.2 The Canonical Kill Chain

```
   ┌────────────────────────────────────────────────────────────────┐
   │ 1. Initial access                                              │
   │    RCE in app / vulnerable dependency / SSRF / log4shell-class │
   └───────────────────────────┬────────────────────────────────────┘
                               │  read a file, or make an HTTP call
                               ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ 2. Credential harvest                                          │
   │    cat /var/run/secrets/kubernetes.io/serviceaccount/token     │
   │    (SSRF variant: no code exec needed — just file:// or a      │
   │     templating engine that reads local paths)                  │
   └───────────────────────────┬────────────────────────────────────┘
                               ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ 3. Reconnaissance                                              │
   │    curl -H "Authorization: Bearer $TOK" https://kubernetes...  │
   │    SelfSubjectRulesReview → "what am I allowed to do?"         │
   └───────────────────────────┬────────────────────────────────────┘
                               ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ 4. Escalation primitive (pick one)                             │
   │    get secrets            → steal other SAs' / DB credentials  │
   │    create pods            → mount hostPath /, or run as another SA │
   │    create pods/exec       → enter a higher-privileged Pod      │
   │    create sa/token        → mint a token for a privileged SA   │
   │    impersonate            → become cluster-admin directly      │
   │    escalate / bind        → write your own ClusterRoleBinding  │
   └───────────────────────────┬────────────────────────────────────┘
                               ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ 5. Persistence / cluster takeover                              │
   └────────────────────────────────────────────────────────────────┘
```

Step 2 is free because of automounting. Step 3 is free because of network reachability. Step 4 is where RBAC minimization is the *only* control that matters.

### 1.3 Why the Legacy Token Model Was Structurally Broken

Before v1.24, creating a ServiceAccount caused the controller-manager to auto-generate a `Secret` of type `kubernetes.io/service-account-token` containing a **JWT with no `exp` claim, no `aud` claim, and no binding to any object**.

Consequences:

- **Exfiltration was permanent.** The only revocation was deleting the ServiceAccount (which changes its UID and invalidates the token). Rotating a token meant breaking every consumer simultaneously.
- **Replay anywhere.** No audience claim meant a token intended for the API server was equally valid at any other service that naively verified the signature — a classic confused-deputy amplifier (Vault, Istio, and every "authenticate my pod with its SA token" integration).
- **Secrets sprawl.** Every SA produced a Secret; anyone with `get secrets` in the namespace held every identity in that namespace.

KEP-1205 (Bound Service Account Tokens) and KEP-2799 (Reduction of Secret-Based Service Account Tokens) replaced this. Since v1.24 no token Secret is auto-created; since v1.22 the injected token is a **projected, time-bound, audience-scoped, object-bound** JWT issued through the TokenRequest API.

### 1.4 What Is Still Not Solved

Be precise about what modern token hygiene does and does not buy you — this is the difference between a passing CKS answer and a correct production design:

- Bound tokens shorten the *window* of a stolen credential; they do not reduce its *authority*. A 1-hour token with `cluster-admin` is a full cluster compromise.
- `automountServiceAccountToken: false` is **not a security boundary against anyone who can write Pod specs.** A Pod author can set it back to `true`, or skip the field entirely and mount a `serviceAccountToken` projected volume by hand.
- The API server's ClusterIP is reachable from every Pod by default. Removing the token does not remove the path.

Therefore the real control stack is layered:

| Layer | Control | Stops |
|---|---|---|
| Identity | Dedicated SA per workload, never `default` | Cross-workload privilege bleed |
| Authorization | Least-privilege Role/RoleBinding, `resourceNames` where possible | Escalation after theft |
| Credential exposure | `automountServiceAccountToken: false` | Trivial harvest via file read / SSRF |
| Credential lifetime | Bound projected tokens, short `expirationSeconds`, non-default `audience` | Replay and long-lived exfiltration |
| Admission | ValidatingAdmissionPolicy / Kyverno enforcing the above | Author error and deliberate bypass |
| Network | NetworkPolicy denying egress to the API server | Use of a harvested token from that Pod |
| Detection | Audit policy on SA token use + `authentication.k8s.io` metrics | Everything that got through |

---

## 2. Token Mechanics: What Is Actually in the Container

### 2.1 The Projected Volume the Admission Plugin Injects

When a Pod is admitted with automounting enabled, the `ServiceAccount` admission plugin appends this volume to the Pod spec (visible in the *stored* object, not in your manifest):

```yaml
volumes:
  - name: kube-api-access-4xr2n
    projected:
      defaultMode: 420
      sources:
        - serviceAccountToken:
            expirationSeconds: 3607
            path: token
        - configMap:
            name: kube-root-ca.crt
            items:
              - key: ca.crt
                path: ca.crt
        - downwardAPI:
            items:
              - fieldRef:
                  apiVersion: v1
                  fieldPath: metadata.namespace
                path: namespace
```

Notes an architect should internalise:

- `expirationSeconds: 3607` — one hour plus jitter. The kubelet re-requests the token when it exceeds 80% of its lifetime (or 24 h, whichever comes first) and **atomically replaces the file**. Long-running clients that read the token once at startup will begin failing with `401` roughly an hour in. This is the single most common "it worked in staging" production incident in this topic.
- `audience` is omitted, so it defaults to the API server's audience (`--api-audiences`, itself defaulting to `--service-account-issuer`).
- The `ca.crt` comes from the `kube-root-ca.crt` ConfigMap that the root CA publisher controller places in every namespace — not from a Secret.
- The volume name is randomly suffixed (`kube-api-access-XXXXX`), which is why you cannot reliably grep for a fixed name in policy.

### 2.2 Decoding a Live Token

```
$ kubectl -n payments exec deploy/api-gateway -- \
    cat /var/run/secrets/kubernetes.io/serviceaccount/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

```json
{
  "aud": [
    "https://kubernetes.default.svc.cluster.local"
  ],
  "exp": 1785413607,
  "iat": 1785410000,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "8f4c1a7e-2b90-4b3d-9d6a-1c0f5b7e4a11",
  "kubernetes.io": {
    "namespace": "payments",
    "node": {
      "name": "worker-2",
      "uid": "b0c1e6f2-9a44-4b1f-8f0a-7d2c3e5a9b10"
    },
    "pod": {
      "name": "api-gateway-7d9f6c4b58-mk2vq",
      "uid": "c7d2a1b3-55e6-4f77-9a01-3b8e2f6d4c99"
    },
    "serviceaccount": {
      "name": "api-gateway",
      "uid": "5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57"
    },
    "warnafter": 1785413200
  },
  "nbf": 1785410000,
  "sub": "system:serviceaccount:payments:api-gateway"
}
```

What each security-relevant claim buys you:

| Claim | Purpose | Security property |
|---|---|---|
| `sub` | The RBAC subject | `system:serviceaccount:<ns>:<name>` — this is what RoleBindings match |
| `aud` | Intended verifier | A token minted for `vault` is rejected by the API server, and vice-versa |
| `exp` / `nbf` | Validity window | Bounds exfiltration value |
| `jti` | Unique token ID | Surfaces in audit logs → you can trace *which* token performed an action |
| `kubernetes.io.pod` | Bound object | Token becomes invalid when that Pod object is deleted |
| `kubernetes.io.node` | Node binding | Enables node-scoped validation; the API server can reject a token presented after the node object is gone |
| `warnafter` | Kubelet hint | Timestamp after which the API server emits a "stale token" warning/metric |

The Pod binding is the important one: **deleting the Pod revokes the token immediately**, without touching the ServiceAccount. That is a real, usable incident-response lever.

### 2.3 Control-Plane Flags That Govern All of This

```
$ kubectl -n kube-system get pod kube-apiserver-cp-1 \
    -o jsonpath='{.spec.containers[0].command}' | tr ' ' '\n' | grep -E 'service-account|api-audiences'
```

```
--service-account-issuer=https://kubernetes.default.svc.cluster.local
--service-account-key-file=/etc/kubernetes/pki/sa.pub
--service-account-signing-key-file=/etc/kubernetes/pki/sa.key
--api-audiences=https://kubernetes.default.svc.cluster.local
--service-account-lookup=true
```

| Flag | Meaning | Hardening guidance |
|---|---|---|
| `--service-account-issuer` | `iss` claim; may be repeated for issuer rotation | Set to a stable, externally resolvable URL if you federate to a cloud IAM |
| `--service-account-signing-key-file` | Private key used by TokenRequest | Must be present or TokenRequest (and therefore all modern tokens) is disabled |
| `--service-account-key-file` | Public keys accepted for verification; repeatable | Keep both old and new keys during rotation, then drop the old |
| `--api-audiences` | Audiences the API server accepts | Explicitly set; enables minting tokens the API server will *not* accept |
| `--service-account-lookup` | Validate that the SA (and bound object) still exists | Leave `true`; this is what makes deletion actually revoke |
| `--service-account-max-token-expiration` | Caps requested TTL | Set to e.g. `24h` so no consumer can request a year-long token |
| `--service-account-extend-token-expiration` | Compatibility: silently extends in-tree-client tokens to ~1 year | Set `false` once metrics show zero stale-token use |

---

## 3. Comparative Analysis

### 3.1 Token Delivery Mechanisms

| Mechanism | TTL | `aud` | Object binding | Revocable by | Correct use in 2026 |
|---|---|---|---|---|---|
| Legacy `kubernetes.io/service-account-token` Secret | none (∞) | none | none | deleting the SA | Never. Migrate off. Only manually creatable since v1.24 |
| Auto-injected projected token | ~1 h, auto-rotated | API server | Pod (+ Node) | deleting Pod or SA | Default for in-cluster clients that genuinely call the API |
| Explicit projected volume with custom `audience`/`expirationSeconds` | you choose (min 600 s) | you choose | Pod | deleting Pod | Service-to-service auth (Vault, Istio, SPIFFE-style verifiers) |
| `kubectl create token` / TokenRequest API | you choose, capped by API server | you choose | optional (`--bound-object-*`) | deleting bound object / SA | CI systems, break-glass, short-lived automation |
| OIDC federation via issuer discovery | cloud-side, minutes | cloud audience | Pod | Pod deletion | Replacing static cloud IAM keys in Pods |

### 3.2 Where to Disable Automounting — and What Each Level Actually Guarantees

Resolution order for `automountServiceAccountToken` (**first match wins**):

```
pod.spec.automountServiceAccountToken   (explicitly true or false)
        ↓ unset
serviceAccount.automountServiceAccountToken   (explicitly true or false)
        ↓ unset
true   ← the dangerous default
```

| Set at | Effect | Bypassable by | Verdict |
|---|---|---|---|
| Pod / PodTemplate | Authoritative for that Pod | The Pod author (it is their own field) | Correct hygiene, not a boundary |
| ServiceAccount (incl. `default`) | Namespace-wide fallback | Any Pod that sets the field to `true` | Good baseline; catches omissions |
| ValidatingAdmissionPolicy / Kyverno | Rejects the Pod at admission | Only by someone who can edit policies | **The actual boundary** |
| NetworkPolicy egress deny to API server | Token becomes useless from that Pod | Someone who can edit NetworkPolicies | Strong defense-in-depth |

The exam-relevant sequence is: patch the `default` SA in every namespace **and** set the field explicitly on workload Pod specs **and** back it with admission policy. Doing only the first is the classic incomplete answer.

### 3.3 RBAC Verbs Ranked by Escalation Power

When you "minimize permissions on newly created service accounts", these are the grants that convert a scoped SA into a cluster compromise. Treat any of them as a cluster-admin-equivalent grant unless proven otherwise.

| Grant | Why it is cluster-admin equivalent | Safer alternative |
|---|---|---|
| `secrets: get/list` (namespace-wide) | Reads every credential in the namespace, including other SAs' manually created tokens | `resourceNames: [<one secret>]` |
| `pods: create` | Create a Pod with `serviceAccountName: <privileged-sa>`, or `hostPath: /`, or `hostPID` | Deny; use a controller with a fixed template |
| `pods/exec`, `pods/attach`, `pods/portforward` | Enter an already-privileged Pod | Deny; use ephemeral debug containers gated by a human |
| `serviceaccounts/token: create` | Mint a fresh token for **any** SA in scope | `resourceNames` restricted to exactly one SA |
| `rbac: escalate` / `bind` | Author a binding granting more than you hold | Deny outright |
| `users/groups/serviceaccounts: impersonate` | Become any subject | Deny outright |
| `deployments`, `daemonsets`, `statefulsets`, `jobs`, `cronjobs`: create/update | Indirect `pods: create` through a controller | Scope by `resourceNames` + admission policy on the resulting Pod |
| `nodes: patch`/`update` (or `nodes/status`) | Manipulate scheduling, remove taints, target the control plane | Deny to workloads |
| `certificatesigningrequests/approval`, `signers: approve` | Issue a client cert for `system:masters` | Deny |
| `validatingwebhookconfigurations`/`mutatingwebhookconfigurations`: create | Inject a webhook that mutates every object cluster-wide | Deny |
| `persistentvolumes: create` | `hostPath` PV → node filesystem | Deny |

Two structural rules that follow:

1. **Prefer `Role` + `RoleBinding` over `ClusterRole` + `ClusterRoleBinding`.** A `ClusterRole` referenced by a `RoleBinding` is namespace-scoped and is the right way to reuse a rule set without granting cluster scope.
2. **Never bind anything to `system:serviceaccounts` or `system:serviceaccounts:<ns>`.** These groups contain every SA, including ones created tomorrow.

---

## 4. Complete Manifests

### 4.1 Namespace Baseline: A Neutered `default` ServiceAccount

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    kubernetes.io/metadata.name: payments
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    security.example.com/sa-hygiene: enforced
---
# The 'default' SA cannot be deleted (the controller recreates it),
# so it is neutralised instead: no token, no image pull secrets.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: payments
  annotations:
    security.example.com/rationale: >-
      Hardened baseline. No workload may bind RBAC to this SA;
      see ValidatingAdmissionPolicy sa-hygiene.security.example.com.
automountServiceAccountToken: false
```

### 4.2 A Correctly Scoped Workload Identity

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-gateway
  namespace: payments
  labels:
    app.kubernetes.io/name: api-gateway
automountServiceAccountToken: false     # opt-in per Pod, never by default
---
# Least privilege: read exactly two ConfigMaps and watch Endpoints for
# service discovery. Nothing else. Note resourceNames on the get/list path.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-gateway
  namespace: payments
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["api-gateway-routes", "api-gateway-tls-policy"]
    verbs: ["get", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-gateway
  namespace: payments
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: api-gateway
subjects:
  - kind: ServiceAccount
    name: api-gateway
    namespace: payments
```

> **`resourceNames` caveat:** it cannot restrict `list` or `watch` on most resources when the client performs a collection request — the authorizer has no individual name to match. It works for `get`, `update`, `patch`, `delete`. Here `watch` on a named ConfigMap is allowed because the client watches a single object by name (`fieldSelector=metadata.name=...`); a bare collection `watch` would be denied. Verify with `kubectl auth can-i` before shipping.

### 4.3 Deployment: Explicit Identity, Explicit Token, Explicit Audience

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  namespace: payments
  labels:
    app.kubernetes.io/name: api-gateway
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: api-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-gateway
      annotations:
        security.example.com/apiserver-access: "required"
    spec:
      serviceAccountName: api-gateway
      # Suppress the implicit injection: we mount the token ourselves,
      # with a TTL and audience we control, at a non-default path.
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: gateway
          image: registry.example.com/payments/api-gateway:1.14.3
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: KUBE_TOKEN_PATH
              value: /var/run/secrets/api/token
            - name: KUBE_CA_PATH
              value: /var/run/secrets/api/ca.crt
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            privileged: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
          volumeMounts:
            - name: apiserver-token
              mountPath: /var/run/secrets/api
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: apiserver-token
          projected:
            defaultMode: 0400
            sources:
              - serviceAccountToken:
                  path: token
                  expirationSeconds: 900          # 15 min; kubelet rotates at 80%
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

`defaultMode: 0400` plus `runAsNonRoot` plus a non-standard path means a generic exploit that greps `/var/run/secrets/kubernetes.io/serviceaccount/token` finds nothing. That is obscurity, not security — but it defeats a large fraction of commodity tooling for free.

### 4.4 A Sidecar That Must *Not* Reach the API Server

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: log-shipper
  namespace: payments
spec:
  serviceAccountName: log-shipper
  automountServiceAccountToken: false
  containers:
    - name: shipper
      image: registry.example.com/obs/vector:0.41.1
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-shipper
  namespace: payments
automountServiceAccountToken: false
# Deliberately no Role and no RoleBinding: this identity is authenticated
# but authorized for nothing. Even a stolen token yields only 403s.
```

### 4.5 Admission Enforcement with ValidatingAdmissionPolicy (in-tree, no webhook)

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: sa-hygiene.security.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchConditions:
    # Never gate control-plane static/mirror pods.
    - name: exclude-mirror-pods
      expression: >-
        !has(object.metadata.annotations) ||
        !('kubernetes.io/config.mirror' in object.metadata.annotations)
  variables:
    - name: sa
      expression: >-
        has(object.spec.serviceAccountName) && object.spec.serviceAccountName != ''
          ? object.spec.serviceAccountName : 'default'
    - name: automount
      expression: >-
        has(object.spec.automountServiceAccountToken)
          ? object.spec.automountServiceAccountToken : true
    - name: manualTokenVolumes
      expression: >-
        has(object.spec.volumes)
          ? object.spec.volumes.filter(v,
              has(v.projected) && has(v.projected.sources) &&
              v.projected.sources.exists(s, has(s.serviceAccountToken)))
          : []
    - name: declared
      expression: >-
        has(object.metadata.annotations) &&
        'security.example.com/apiserver-access' in object.metadata.annotations &&
        object.metadata.annotations['security.example.com/apiserver-access'] == 'required'
  validations:
    - expression: "variables.sa != 'default'"
      reason: Forbidden
      messageExpression: >-
        'pod ' + object.metadata.name +
        ' must set spec.serviceAccountName to a dedicated ServiceAccount; the "default" SA is not usable'

    - expression: "variables.automount == false"
      reason: Forbidden
      message: >-
        spec.automountServiceAccountToken must be explicitly false; mount a
        projected serviceAccountToken volume with an explicit audience and
        expirationSeconds instead

    - expression: "size(variables.manualTokenVolumes) == 0 || variables.declared"
      reason: Forbidden
      message: >-
        pods that project a serviceAccountToken volume must carry the annotation
        security.example.com/apiserver-access=required

    - expression: >-
        variables.manualTokenVolumes.all(v,
          v.projected.sources.filter(s, has(s.serviceAccountToken)).all(s,
            has(s.serviceAccountToken.expirationSeconds) &&
            s.serviceAccountToken.expirationSeconds <= 3600))
      reason: Forbidden
      message: "projected serviceAccountToken volumes must set expirationSeconds <= 3600"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: sa-hygiene-binding
spec:
  policyName: sa-hygiene.security.example.com
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public"]
```

**Roll-out discipline:** ship first with `validationActions: ["Audit", "Warn"]`, read `apiserver_validating_admission_policy_check_total{enforcement_action="audit"}` and the audit annotations, fix the offenders, only then flip to `Deny`. Going straight to `Deny` on `pods` is how you wedge a cluster during a node drain.

**Diagnosis gotcha:** this policy matches `pods`, but users create `Deployments`. The rejection therefore surfaces on the ReplicaSet, not on `kubectl apply`. The `kubectl apply` succeeds and the Deployment simply never scales. See §6.3.

### 4.6 Equivalent Kyverno Policy (when you need mutation, not just validation)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: service-account-hygiene
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: disallow-default-sa
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "kube-node-lease", "kube-public"]
      validate:
        message: "Pods must not run as the 'default' ServiceAccount."
        pattern:
          spec:
            serviceAccountName: "!default"

    - name: default-automount-off
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system"]
      mutate:
        patchStrategicMerge:
          spec:
            +(automountServiceAccountToken): false   # add only if absent

    - name: forbid-rbac-to-default-sa
      match:
        any:
          - resources:
              kinds: ["RoleBinding", "ClusterRoleBinding"]
      validate:
        message: "RBAC must not be bound to a 'default' ServiceAccount or to the system:serviceaccounts groups."
        deny:
          conditions:
            any:
              - key: "{{ request.object.subjects[?name=='default'] | length(@) }}"
                operator: GreaterThan
                value: 0
              - key: "{{ request.object.subjects[?starts_with(name,'system:serviceaccounts')] | length(@) }}"
                operator: GreaterThan
                value: 0
```

The third rule is the one most teams forget: policing Pods is useless if someone can still bind `cluster-admin` to `payments:default`.

### 4.7 Network-Layer Containment

```yaml
---
# Default-deny egress in the namespace.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes: ["Egress"]
---
# Allow DNS for everyone.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: payments
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
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
---
# Only workloads explicitly labelled may reach the API server endpoints.
# 10.0.0.10/32 is the control-plane VIP in this cluster — derive it from
# `kubectl -n default get endpoints kubernetes`, not from a guess.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-apiserver-egress
  namespace: payments
spec:
  podSelector:
    matchLabels:
      security.example.com/apiserver-client: "true"
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.10/32
      ports:
        - protocol: TCP
          port: 6443
```

`ipBlock` is required because the API server endpoint is outside the Pod network, so `namespaceSelector`/`podSelector` cannot express it. Confirm the address:

```
$ kubectl -n default get endpoints kubernetes -o jsonpath='{.subsets[*].addresses[*].ip}{"\n"}'
10.0.0.10
```

### 4.8 Audit Policy for Token Use and SA Mutation

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Every token mint is a security event; capture the full request.
  - level: RequestResponse
    verbs: ["create"]
    resources:
      - group: ""
        resources: ["serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # Any RBAC change is a security event.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Anything done by a 'default' SA should not exist. Log it loudly.
  - level: Metadata
    users: []
    userGroups: []
    omitStages: ["RequestReceived"]
    namespaces: []
    # Matched by name pattern in the SIEM: sub == system:serviceaccount:*:default

  # Reads of Secrets by any service account.
  - level: Metadata
    userGroups: ["system:serviceaccounts"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["secrets"]

  - level: Metadata
```

Because the token now carries a `jti`, an audit entry lets you pivot from "this action" to "this exact token instance", and from there to the Pod UID that held it.

---

## 5. CLI Walkthrough with Real Output

### 5.1 Establishing the Baseline

```
$ kubectl get serviceaccount -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,AUTOMOUNT:.automountServiceAccountToken \
  | head -12
```

```
NS            NAME                      AUTOMOUNT
default       default                   <none>
kube-node-lease default                 <none>
kube-public   default                   <none>
kube-system   attachdetach-controller   <none>
kube-system   coredns                   <none>
kube-system   default                   <none>
payments      api-gateway               false
payments      default                   false
payments      log-shipper               false
```

`<none>` means "unset", which means **true**. Those are your gaps.

Patch every `default` SA outside the control plane:

```
$ for ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | grep -vE '^kube-(system|public|node-lease)$'); do
    kubectl patch serviceaccount default -n "$ns" \
      -p '{"automountServiceAccountToken": false}'
  done
```

```
serviceaccount/default patched
serviceaccount/default patched
serviceaccount/default patched
```

### 5.2 Finding Pods That Still Carry a Token

```
$ kubectl get pods -A -o json | jq -r '
    .items[]
    | select((.spec.automountServiceAccountToken // true) == true)
    | [.metadata.namespace, .metadata.name, (.spec.serviceAccountName // "default")]
    | @tsv' | column -t
```

```
observability  grafana-6c9d4b7f88-t2xzq        default
observability  loki-0                          loki
tenant-b       legacy-batch-9f4c2-r7t8w        default
tenant-b       reporting-cron-29344160-hh9lp   default
```

Two `default`-SA workloads in `tenant-b` with live tokens — that is the finding.

The stronger check is on the *stored* Pod object, because a Pod may carry a manually projected token even with automount disabled:

```
$ kubectl get pods -A -o json | jq -r '
    .items[]
    | select(.spec.volumes // [] | any(.projected.sources // [] | any(.serviceAccountToken)))
    | [.metadata.namespace, .metadata.name] | @tsv' | column -t
```

```
payments   api-gateway-7d9f6c4b58-mk2vq
payments   api-gateway-7d9f6c4b58-p4wnl
payments   api-gateway-7d9f6c4b58-x8k3r
tenant-b   legacy-batch-9f4c2-r7t8w
```

### 5.3 Hunting Legacy Secret-Based Tokens

```
$ kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
    -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,SA:.metadata.annotations.kubernetes\\.io/service-account\\.name,\
LASTUSED:.metadata.labels.kubernetes\\.io/legacy-token-last-used
```

```
NS         NAME                       SA              LASTUSED
tenant-b   legacy-batch-token-q7v2m   legacy-batch    2026-03-14
ci         jenkins-sa-token           jenkins         2026-07-29
```

`kubernetes.io/legacy-token-last-used` is maintained by the legacy-token-tracking controller. A date months in the past means the token is unused and safe to delete; a recent date means something still depends on it — find it before deleting.

Confirm from the control-plane metrics:

```
$ kubectl get --raw /metrics | grep -E '^serviceaccount_(legacy|stale)' | grep -v '^#'
```

```
serviceaccount_legacy_tokens_total 2
serviceaccount_legacy_token_uses_total 41822
serviceaccount_stale_tokens_total 0
```

`serviceaccount_stale_tokens_total 0` is your green light to set `--service-account-extend-token-expiration=false`. A non-zero `serviceaccount_legacy_token_uses_total` that keeps climbing is your migration backlog.

### 5.4 Minting and Inspecting Tokens On Demand

```
$ kubectl -n payments create token api-gateway --duration=10m
```

```
eyJhbGciOiJSUzI1NiIsImtpZCI6IlJoUWJVN0pOZDVfaG5FMEQxRzMtNU1GNGdpV0R0ZFdUMEdrRnpqUXlHRUUifQ.eyJhdWQiOlsiaHR0cHM6Ly9rdWJlcm5ldGVzLmRlZmF1bHQuc3ZjLmNsdXN0ZXIubG9jYWwiXSwiZXhwIjoxNzg1NDEwNjAwLCJpYXQiOjE3ODU0MTAwMDAsImlzcyI6Imh0dHBzOi8va3ViZXJuZXRlcy5kZWZhdWx0LnN2Yy5jbHVzdGVyLmxvY2FsIiwianRpIjoiYTFmM2M5ZDItNDRiNy00YzExLTk4ZjAtM2QyZTVhN2I5YzAxIiwia3ViZXJuZXRlcy5pbyI6eyJuYW1lc3BhY2UiOiJwYXltZW50cyIsInNlcnZpY2VhY2NvdW50Ijp7Im5hbWUiOiJhcGktZ2F0ZXdheSIsInVpZCI6IjVhMWY5YzJkLTdlMzMtNGE4OC1iMmM0LTZmOWQwZTFhM2I1NyJ9fSwibmJmIjoxNzg1NDEwMDAwLCJzdWIiOiJzeXN0ZW06c2VydmljZWFjY291bnQ6cGF5bWVudHM6YXBpLWdhdGV3YXkifQ.<signature>
```

Bind it to a Pod so it dies with the Pod:

```
$ POD=api-gateway-7d9f6c4b58-mk2vq
$ UID=$(kubectl -n payments get pod $POD -o jsonpath='{.metadata.uid}')
$ kubectl -n payments create token api-gateway \
    --duration=30m \
    --bound-object-kind Pod \
    --bound-object-name "$POD" \
    --bound-object-uid "$UID" > /tmp/tok
```

Mint a token the API server will **refuse** (audience-scoped for Vault):

```
$ kubectl -n payments create token api-gateway --audience=vault.example.com --duration=5m > /tmp/vault-tok
$ curl -sk -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $(cat /tmp/vault-tok)" \
    https://10.0.0.10:6443/api/v1/namespaces/payments/pods
```

```
401
```

That `401` is the point of the audience claim: even a fully exfiltrated Vault-bound token is worthless against the control plane.

### 5.5 Interrogating Effective Permissions

```
$ kubectl auth can-i --list --as=system:serviceaccount:payments:api-gateway -n payments
```

```
Resources                                       Non-Resource URLs   Resource Names                                  Verbs
selfsubjectreviews.authentication.k8s.io        []                  []                                              [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []                                              [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []                                              [create]
configmaps                                      []                  [api-gateway-routes api-gateway-tls-policy]     [get watch]
endpointslices.discovery.k8s.io                 []                  []                                              [get list watch]
                                                [/healthz]          []                                              [get]
                                                [/livez]            []                                              [get]
                                                [/readyz]           []                                              [get]
                                                [/version]          []                                              [get]
```

Spot-check the dangerous verbs explicitly:

```
$ for v in "get secrets" "create pods" "list secrets -A" "create serviceaccounts/token"; do
    printf '%-32s %s\n' "$v" \
      "$(kubectl auth can-i $v --as=system:serviceaccount:payments:api-gateway -n payments 2>/dev/null)"
  done
```

```
get secrets                      no
create pods                      no
list secrets -A                  no
create serviceaccounts/token     no
```

Identity check from *inside* a Pod (v1.26+):

```
$ kubectl -n payments exec -it deploy/api-gateway -- \
    kubectl auth whoami --token=$(cat /var/run/secrets/api/token)
```

```
ATTRIBUTE                                           VALUE
Username                                            system:serviceaccount:payments:api-gateway
UID                                                 5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57
Groups                                              [system:serviceaccounts system:serviceaccounts:payments system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [JTI=8f4c1a7e-2b90-4b3d-9d6a-1c0f5b7e4a11]
Extra: authentication.kubernetes.io/node-name       [worker-2]
Extra: authentication.kubernetes.io/node-uid        [b0c1e6f2-9a44-4b1f-8f0a-7d2c3e5a9b10]
Extra: authentication.kubernetes.io/pod-name        [api-gateway-7d9f6c4b58-mk2vq]
Extra: authentication.kubernetes.io/pod-uid         [c7d2a1b3-55e6-4f77-9a01-3b8e2f6d4c99]
```

Those `Extra:` attributes are the modern payoff: the API server now knows *which Pod on which Node* is calling, and you can write authorization webhooks or audit rules against it.

### 5.6 Reproducing the Attack, Then Proving It Fails

Before hardening:

```
$ kubectl -n tenant-b exec -it legacy-batch-9f4c2-r7t8w -- sh
/ # TOK=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
/ # CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
/ # curl -s --cacert $CA -H "Authorization: Bearer $TOK" \
      https://kubernetes.default.svc/api/v1/namespaces/tenant-b/secrets | head -20
```

```json
{
  "kind": "SecretList",
  "apiVersion": "v1",
  "metadata": { "resourceVersion": "1884213" },
  "items": [
    {
      "metadata": { "name": "postgres-superuser", "namespace": "tenant-b" },
      "data": { "password": "c3VwM3JzM2NyM3RfcGc=" },
      "type": "Opaque"
    },
```

After applying §4.1–§4.4:

```
/ # ls /var/run/secrets/kubernetes.io/serviceaccount/
ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
```

And with a token deliberately supplied (simulating a stolen one):

```
$ curl -sk -H "Authorization: Bearer $(kubectl -n payments create token log-shipper)" \
    https://10.0.0.10:6443/api/v1/namespaces/payments/secrets | jq -r '.message'
```

```
secrets is forbidden: User "system:serviceaccount:payments:log-shipper" cannot list resource "secrets" in API group "" in the namespace "payments"
```

Authenticated, authorized for nothing. That is the target state.

### 5.7 Emergency Revocation

Revoke one Pod's credential without touching anything else — the Pod binding does the work:

```
$ kubectl -n payments delete pod api-gateway-7d9f6c4b58-mk2vq
pod "api-gateway-7d9f6c4b58-mk2vq" deleted

$ curl -sk -H "Authorization: Bearer $(cat /tmp/tok)" \
    https://10.0.0.10:6443/api/v1/namespaces/payments/pods | jq -r '.message'
```

```
Unauthorized
```

Revoke *all* tokens for an identity — recreate the SA, which changes its UID:

```
$ kubectl -n payments get sa api-gateway -o jsonpath='{.metadata.uid}{"\n"}'
5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57

$ kubectl -n payments delete sa api-gateway && kubectl apply -f sa-api-gateway.yaml
serviceaccount "api-gateway" deleted
serviceaccount/api-gateway created

$ kubectl -n payments get sa api-gateway -o jsonpath='{.metadata.uid}{"\n"}'
e3b0c442-98fc-4c14-8fca-1a2b3c4d5e6f
```

Every previously issued token embedded the old UID and is now rejected. Running Pods must be restarted — the kubelet cannot refresh a token for a UID that no longer exists.

### 5.8 CKS Exam Speed-Run

```
$ kubectl create namespace build
namespace/build created

$ kubectl -n build create serviceaccount ci-runner
serviceaccount/ci-runner created

$ kubectl -n build patch serviceaccount default -p '{"automountServiceAccountToken":false}'
serviceaccount/default patched

$ kubectl -n build create role pod-reader --verb=get,list,watch --resource=pods
role.rbac.authorization.k8s.io/pod-reader created

$ kubectl -n build create rolebinding ci-runner-pod-reader \
    --role=pod-reader --serviceaccount=build:ci-runner
rolebinding.rbac.authorization.k8s.io/ci-runner-pod-reader created

$ kubectl auth can-i list pods -n build --as=system:serviceaccount:build:ci-runner
yes

$ kubectl auth can-i delete pods -n build --as=system:serviceaccount:build:ci-runner
no

$ kubectl -n build run probe --image=busybox:1.36 \
    --overrides='{"spec":{"serviceAccountName":"ci-runner","automountServiceAccountToken":false}}' \
    --restart=Never -- sleep 3600
pod/probe created

$ kubectl -n build exec probe -- ls /var/run/secrets/kubernetes.io/serviceaccount
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
command terminated with exit code 1
```

Memorise the `--overrides` form: `kubectl run`/`kubectl create deployment` have no flag for `automountServiceAccountToken`, and under exam time pressure editing YAML costs more than typing the override.

---

## 6. Verification and Failure Diagnosis

### 6.1 Symptom Table

| Symptom | Most likely cause | First command |
|---|---|---|
| `Unauthorized` (401), no message body | Token expired, SA deleted/recreated (UID mismatch), bound Pod deleted, or wrong `aud` | Decode the JWT: check `exp`, `aud`, `kubernetes.io.serviceaccount.uid` vs live SA UID |
| `... is forbidden: User "system:serviceaccount:..." cannot ...` (403) | Authenticated fine, RBAC insufficient. The message names resource, verb, group, and scope — read it literally | `kubectl auth can-i <verb> <res> --as=system:serviceaccount:<ns>:<sa> -n <ns>` |
| Works for ~1 h then 401s forever | Client read the token file once into memory; kubelet rotated it | `kubectl exec -- stat -c '%y' <token path>`; fix the client to re-read or use a maintained SDK |
| `unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined` | Not actually a token problem — Pod running outside a cluster context, or `hostNetwork` without the env vars | `kubectl exec -- env \| grep KUBERNETES_` |
| `open /var/run/secrets/kubernetes.io/serviceaccount/token: no such file or directory` | Automount disabled but the app expects the standard path | Decide: re-enable via an explicit projected volume, or point the app at your custom path |
| Pod stuck, `describe` shows `error looking up service account <ns>/<sa>: serviceaccount "<sa>" not found` | `serviceAccountName` references an SA that does not exist in that namespace | `kubectl -n <ns> get sa` |
| Deployment shows `0/3` replicas, no Pods, no error on `apply` | Admission policy rejected the *Pod*, so the failure lives on the ReplicaSet | `kubectl -n <ns> describe rs -l app=<name>` |
| SA has permissions you never granted | Bound via `system:serviceaccounts` group, or an aggregated ClusterRole picked up a new rule | §6.4 |
| Everything 403s including `/version` | `system:authenticated` group has no `system:public-info-viewer` binding, or the authorizer chain is misconfigured | `kubectl get clusterrolebinding system:public-info-viewer -o yaml` |

### 6.2 Reading a 401 Correctly

A 401 is authentication, not authorization. Walk it in this order:

```
$ TOK=$(kubectl -n payments exec deploy/api-gateway -- cat /var/run/secrets/api/token)

# 1. Is it expired?
$ echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '"exp=\(.exp)  now=\(now|floor)  remaining=\(.exp - (now|floor))s"'
exp=1785410600  now=1785412000  remaining=-1400s
```

Negative remaining → expired; the client is caching. If the number is positive:

```
# 2. Does the audience match what --api-audiences accepts?
$ echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.aud[]'
vault.example.com
```

Wrong audience. If the audience is right:

```
# 3. Does the embedded SA UID still match the live object?
$ echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '."kubernetes.io".serviceaccount.uid'
5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57
$ kubectl -n payments get sa api-gateway -o jsonpath='{.metadata.uid}{"\n"}'
e3b0c442-98fc-4c14-8fca-1a2b3c4d5e6f
```

Mismatch → the SA was deleted and recreated; every Pod using it must be restarted.

```
# 4. Does the bound object still exist?
$ echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '."kubernetes.io".pod.name'
api-gateway-7d9f6c4b58-mk2vq
$ kubectl -n payments get pod api-gateway-7d9f6c4b58-mk2vq
Error from server (NotFound): pods "api-gateway-7d9f6c4b58-mk2vq" not found
```

Authoritative validation, when you have the rights, is the TokenReview API — it tells you exactly what the API server thinks:

```
$ cat <<EOF > /tmp/tr.json
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "spec": {
    "token": "$TOK",
    "audiences": ["https://kubernetes.default.svc.cluster.local"]
  }
}
EOF
$ kubectl create --raw /apis/authentication.k8s.io/v1/tokenreviews -f /tmp/tr.json | jq .status
```

```json
{
  "authenticated": false,
  "error": "[invalid bearer token, service account token has expired]"
}
```

A healthy token returns:

```json
{
  "authenticated": true,
  "user": {
    "username": "system:serviceaccount:payments:api-gateway",
    "uid": "5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57",
    "groups": [
      "system:serviceaccounts",
      "system:serviceaccounts:payments",
      "system:authenticated"
    ],
    "extra": {
      "authentication.kubernetes.io/credential-id": ["JTI=8f4c1a7e-2b90-4b3d-9d6a-1c0f5b7e4a11"],
      "authentication.kubernetes.io/node-name": ["worker-2"],
      "authentication.kubernetes.io/pod-name": ["api-gateway-7d9f6c4b58-mk2vq"]
    }
  },
  "audiences": ["https://kubernetes.default.svc.cluster.local"]
}
```

> Sending a live token to `TokenReview` is safe against your own API server (it already trusts it), but never paste production tokens into third-party JWT decoders. Decode locally with `base64 -d`.

### 6.3 Debugging Admission Rejections That Hide Behind Controllers

```
$ kubectl -n tenant-b apply -f reporting.yaml
deployment.apps/reporting created

$ kubectl -n tenant-b get deploy reporting
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
reporting   0/2     0            0           45s

$ kubectl -n tenant-b describe rs -l app=reporting | tail -8
```

```
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  12s (x5 over 44s)  replicaset-controller  Error creating: pods "reporting-6d4b8f9c7-" is forbidden:
    ValidatingAdmissionPolicy 'sa-hygiene.security.example.com' with binding 'sa-hygiene-binding' denied request:
    pod reporting-6d4b8f9c7- must set spec.serviceAccountName to a dedicated ServiceAccount; the "default" SA is not usable
```

The fix belongs in `spec.template.spec`, not in the Deployment's own metadata — a distinction that trips people repeatedly.

Dry-run the policy before rollout:

```
$ kubectl -n payments run policy-probe --image=busybox:1.36 --dry-run=server --restart=Never -- true
Error from server (Forbidden): admission webhook / policy denied the request:
  ValidatingAdmissionPolicy 'sa-hygiene.security.example.com' with binding 'sa-hygiene-binding' denied request:
  pod policy-probe must set spec.serviceAccountName to a dedicated ServiceAccount; the "default" SA is not usable
```

`--dry-run=server` runs the full admission chain without persisting. It is the fastest way to validate a policy, and it is exam-legal.

### 6.4 Auditing for Over-Privileged Service Accounts

Every binding that reaches a `default` SA:

```
$ kubectl get rolebindings,clusterrolebindings -A -o json | jq -r '
    .items[]
    | . as $b
    | (.subjects // [])[]
    | select(.kind == "ServiceAccount" and .name == "default")
    | [$b.kind, ($b.metadata.namespace // "-"), $b.metadata.name, $b.roleRef.kind + "/" + $b.roleRef.name, .namespace]
    | @tsv' | column -t
```

```
ClusterRoleBinding  -         demo-quickfix    ClusterRole/cluster-admin  tenant-b
RoleBinding         tenant-b  batch-helper     ClusterRole/edit           tenant-b
```

Any binding to the `system:serviceaccounts*` groups:

```
$ kubectl get clusterrolebindings -o json | jq -r '
    .items[] | . as $b | (.subjects // [])[]
    | select(.kind == "Group" and (.name | startswith("system:serviceaccounts")))
    | [$b.metadata.name, $b.roleRef.name, .name] | @tsv' | column -t
```

```
system:service-account-issuer-discovery   system:service-account-issuer-discovery   system:serviceaccounts
```

That one is expected (it exposes only the OIDC discovery endpoints). Anything else on that list is an emergency.

Every SA holding a known escalation primitive:

```
$ for sa in $(kubectl get sa -A -o jsonpath='{range .items[*]}{.metadata.namespace}:{.metadata.name}{"\n"}{end}'); do
    ns=${sa%%:*}; name=${sa##*:}
    for perm in "create pods" "get secrets" "impersonate users" "create serviceaccounts/token" "escalate roles.rbac.authorization.k8s.io"; do
      if [ "$(kubectl auth can-i $perm --as=system:serviceaccount:$ns:$name -A 2>/dev/null)" = "yes" ]; then
        printf 'HIGH  %-40s %s\n' "$sa" "$perm"
      fi
    done
  done
```

```
HIGH  kube-system:daemon-set-controller        create pods
HIGH  kube-system:replicaset-controller        create pods
HIGH  kube-system:generic-garbage-collector    get secrets
HIGH  tenant-b:default                         create pods
HIGH  tenant-b:default                         get secrets
```

Control-plane controllers are expected; `tenant-b:default` is the incident.

### 6.5 Verifying the OIDC Discovery Surface

If you federate SA tokens to an external IdP, the discovery documents must be reachable and correct:

```
$ kubectl get --raw /.well-known/openid-configuration | jq .
```

```json
{
  "issuer": "https://kubernetes.default.svc.cluster.local",
  "jwks_uri": "https://kubernetes.default.svc.cluster.local/openid/v1/jwks",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
```

```
$ kubectl get --raw /openid/v1/jwks | jq -r '.keys[].kid'
RhQbU7JNd5_hnE0D1G3-5MF4giWDtdWT0GkFzjQyGEE
```

Two hardening notes: exposing these endpoints anonymously requires binding `system:service-account-issuer-discovery` to `system:unauthenticated`, which most clusters should **not** do; and the `--service-account-issuer` value must be the URL the external verifier can actually resolve, not the in-cluster name.

### 6.6 Pre-Merge Checklist

For every new workload, all seven must be true:

1. A dedicated ServiceAccount exists; `serviceAccountName` is set explicitly; it is not `default`.
2. The ServiceAccount has `automountServiceAccountToken: false`.
3. The Pod template sets `automountServiceAccountToken: false`, and projects a token explicitly **only if** the workload actually calls the API server.
4. Permissions come from a namespaced `Role` (or a `ClusterRole` referenced by a `RoleBinding`), with `resourceNames` wherever the verb supports it, and none of the escalation primitives in §3.3.
5. `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa> -n <ns>` output has been read line by line and matches the design doc.
6. `kubectl auth can-i <verb> <resource> -A --as=...` returns `no` for `create pods`, `get secrets`, `impersonate`, `escalate`, `bind`, and `create serviceaccounts/token`.
7. Egress to the API server is denied by NetworkPolicy unless the workload is labelled as an API client.

---

## References

- Kubernetes — *Service Accounts* (concepts, token mechanics, bound tokens): https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubernetes — *Configure Service Accounts for Pods* (automounting, projected tokens, `kubectl create token`): https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — *Managing Service Accounts* (control-plane flags, issuer discovery, legacy token cleanup): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — *Using RBAC Authorization* (escalation prevention, `escalate`/`bind`, default roles): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — *Authenticating* (service account tokens, TokenReview, audiences): https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes API Reference — `TokenRequest`: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-request-v1/
- Kubernetes API Reference — `ServiceAccount`: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/service-account-v1/
- Kubernetes API Reference — `TokenReview`: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/
- Kubernetes — *Projected Volumes* (`serviceAccountToken` source, `audience`, `expirationSeconds`): https://kubernetes.io/docs/concepts/storage/projected-volumes/
- Kubernetes — *Admission Controllers Reference* (`ServiceAccount`, `NodeRestriction`): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — *Validating Admission Policy*: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — *kube-apiserver* command-line reference (`--service-account-*`, `--api-audiences`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — *Labels, Annotations and Taints* (`kubernetes.io/legacy-token-last-used`, `kubernetes.io/legacy-token-invalid-since`): https://kubernetes.io/docs/reference/labels-annotations-taints/
- Kubernetes — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — `kubectl create token`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_token/
- Kubernetes — `kubectl auth can-i`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/
- KEP-1205 — *Bound Service Account Tokens*: https://github.com/kubernetes/enhancements/issues/1205
- KEP-2799 — *Reduction of Secret-Based Service Account Tokens*: https://github.com/kubernetes/enhancements/issues/2799
- KEP-4193 — *Bound Service Account Token Improvements* (JTI, node/pod claims, node binding): https://github.com/kubernetes/enhancements/issues/4193
- CNCF — *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository: https://github.com/cncf/curriculum