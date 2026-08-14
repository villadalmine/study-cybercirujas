# 5.4 Mutation Rules

> **Domain 5 — Writing Policies · Exam weight 2.91**
> Kyverno Certified Associate (KCA). All content original; every external claim is attributed in **Referencias**.

---

## 1. The architectural problem mutation solves

Kubernetes has two native mechanisms for filling in what the user did not write:

1. **API defaulting** — declared in the OpenAPI schema of a built-in type, compiled into the API server (`imagePullPolicy: Always` when the tag is `:latest`, `terminationGracePeriodSeconds: 30`). You cannot extend it for built-in types.
2. **CRD defaulting** — `default:` in a `CustomResourceDefinition` structural schema. Only for your own CRDs, and only static values.

Neither can express *organizational* policy: "every Pod in a tenant namespace inherits the tenant's cost-center label", "every image pull is rewritten to the internal Harbor mirror", "every workload gets `seccompProfile: RuntimeDefault` unless it already declares one". That gap is what **mutating admission** exists for, and it is the single highest-leverage control a platform team owns — because a mutation is the only policy type that *fixes* the request instead of rejecting it.

### 1.1 Four production drivers

| Driver | Without mutation | With mutation |
|---|---|---|
| **Compliance baselining** (PSS `restricted`, seccomp, `runAsNonRoot`) | Every team edits every manifest; validate rules reject deploys; friction and shadow-IT | Platform sets the safe default; validate rules become a backstop that almost never fires |
| **Supply-chain control** (air-gapped registry, digest pinning) | Manifests hardcode `docker.io/...`; a registry migration is a org-wide PR campaign | Registry rewritten at admission; the source manifests stay portable |
| **Metadata propagation** (cost center, owner, data classification) | Labels drift; chargeback and network policy selectors silently miss workloads | Labels are derived from the Namespace at admission and back-filled on existing objects |
| **Scheduling / topology defaults** (tolerations, `topologySpreadConstraints`, `priorityClassName`, `nodeSelector`) | Every chart re-implements node placement; a taint change breaks fleets | One rule, one rollout |

The distinguishing property: **mutation moves the burden of correctness from N application teams to 1 platform team**, and it does so without forking Helm charts. That is the exam-relevant framing and the production one.

### 1.2 Where mutation runs in the admission chain

```
kubectl / controller
        │
        ▼
  API server: authn → authz
        │
        ▼
  ┌────────────────────────────────────────────┐
  │ MUTATING admission                         │
  │  1. built-in mutating plugins              │
  │  2. MutatingWebhookConfiguration webhooks  │  ← Kyverno admission controller
  │     (serial, ordered by config name)       │
  │  3. reinvocation pass (reinvocationPolicy: │
  │     IfNeeded) if any webhook mutated       │
  └────────────────────────────────────────────┘
        │
        ▼
  OpenAPI schema validation  ← a malformed patch is rejected HERE, not by Kyverno
        │
        ▼
  ┌────────────────────────────────────────────┐
  │ VALIDATING admission (parallel)            │  ← Kyverno validate rules, PSA
  └────────────────────────────────────────────┘
        │
        ▼
  etcd
```

Three consequences that are constantly misunderstood in incident reviews:

- **Mutating webhooks are serial and ordered by webhook-configuration name.** Two injectors that both add a container (Kyverno + Istio) interact order-dependently.
- **Kyverno registers its resource mutating webhook with `reinvocationPolicy: IfNeeded`.** If another webhook mutates *after* Kyverno, Kyverno is invoked a second time. **Therefore every mutate rule you write must be idempotent** — applying it twice must produce the same object as applying it once. An `add`-to-array JSON patch without a guard is the classic non-idempotent rule and produces duplicated tolerations or duplicated sidecars.
- **The patch is validated by the API server's schema, not by Kyverno.** A rule that writes `spec.contaienrs` produces a webhook success followed by an API-server `strict decoding error`. Kyverno's `spec.schemaValidation` catches many of these at policy-admission time, not all.

### 1.3 What Kyverno actually returns

Kyverno does not "edit the object". It computes an **RFC 6902 JSON Patch** against the incoming object and returns it base64-encoded in the `AdmissionResponse`:

```json
{
  "allowed": true,
  "patchType": "JSONPatch",
  "patch": "W3sib3AiOiJhZGQiLCJwYXRoIjoiL3NwZWMvY29udGFpbmVycy8wL2ltYWdlUHVsbFBvbGljeSIsInZhbHVlIjoiSWZOb3RQcmVzZW50In1d"
}
```

which decodes to:

```json
[{"op":"add","path":"/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]
```

Whatever authoring syntax you use — strategic merge, `patchesJson6902`, `foreach` — the wire format is always this. Understanding that collapses most confusion about ordering and idempotency.

---

## 2. Anatomy of a mutate rule

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy            # or `Policy` for namespace scope
metadata:
  name: platform-defaults
  annotations:
    policies.kyverno.io/title: Platform Workload Defaults
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
spec:
  admission: true              # evaluate at admission time (default true)
  background: false            # background scanning; irrelevant for admission-time mutate
  failurePolicy: Fail          # per-policy webhook failurePolicy
  webhookTimeoutSeconds: 10    # per-policy webhook timeout (max 30)
  applyRules: All              # All | One — stop after the first matching rule
  rules:
    - name: default-image-pull-policy
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
                - UPDATE
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (image): "*:latest"
                imagePullPolicy: IfNotPresent
```

Mandatory: `name`, `match`, and exactly one `mutate` block. Inside `mutate`, exactly **one** of `patchStrategicMerge`, `patchesJson6902`, or `foreach` may be used per rule. `targets` and `mutateExistingOnPolicyUpdate` turn the rule into a *mutate-existing* rule (§8).

Rules run **in declaration order within a policy**. Across policies the order is not something you should depend on — if rule B must observe rule A's output, put both rules in the same policy, in order.

---

## 3. Patch strategies: technical comparison

| | `patchStrategicMerge` | `patchesJson6902` | `foreach` |
|---|---|---|---|
| **Underlying format** | Kubernetes strategic merge patch + Kyverno anchors | RFC 6902 JSON Patch | Either of the two, applied per list element |
| **List semantics** | Uses `patchMergeKey` from the Go struct tags (`name` for containers, `containerPort` for ports, `mountPath` for volumeMounts) | Positional index or `-` append | Explicit iteration, `{{ element }}` / `{{ elementIndex }}` |
| **Creates missing parent maps** | Yes | **No** — `add` to `/spec/tolerations/-` fails when `tolerations` is absent | Inherits the chosen sub-strategy |
| **Idempotent by construction** | Yes for maps; yes for lists with a merge key | **No** for array append (`/-`) | Depends |
| **Conditional logic** | Anchors `()`, `+()`, `<()` | `preconditions` only, or `test` ops | `preconditions` per element |
| **Works on CRDs without a Go schema** | Degrades to a naive JSON merge — lists are **replaced**, not merged | Yes, fully predictable | Yes |
| **Readability at scale** | High | Low | Medium |
| **Typical use** | Defaults, labels/annotations, container fields | Ordered edits, deletions by index, escaped keys, CRDs | Per-container rewrites (images, resources, securityContext) |

### 3.1 The CRD trap

Strategic merge patch is only "Kubernetes-aware" for types whose Go structs carry `patchStrategy`/`patchMergeKey` tags — i.e. built-ins. For a CRD, Kyverno cannot know the merge key, so a `patchStrategicMerge` against a list inside a custom resource **replaces the whole list**. For CRDs, prefer `patchesJson6902` or `foreach` + `patchesJson6902`. This is one of the most common production surprises when teams start mutating `ArgoCD Application`, `Cluster` (CAPI), or `VirtualService` objects.

---

## 4. Strategic merge patch and Kyverno anchors

Anchors are Kyverno's extension that make a declarative patch conditional.

| Anchor | Syntax | Valid in `mutate` | Semantics |
|---|---|---|---|
| **Conditional** | `(key)` | ✅ | The sibling fields in the same map are applied **only if** `key` exists and its value matches (wildcards `*`, `?` allowed). Inside a list, it also selects which elements are patched. |
| **Add-if-not-present** | `+(key)` | ✅ | Adds `key` with the given value **only when the key is absent**. Never overwrites. The whole subtree is atomic — see §4.2. |
| **Global** | `<(key)` | ✅ | The condition is evaluated against the resource as a whole; if it fails, the **entire patch** is skipped. |
| **Remove** | `key: null` | ✅ | Standard strategic-merge deletion. |
| Equality | `=(key)` | ❌ validate only | |
| Existence | `^(key)` | ❌ validate only | |
| Negation | `X(key)` | ❌ validate only | |

### 4.1 Conditional anchor — patch only what matches

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: image-pull-policy-for-mutable-tags
spec:
  rules:
    - name: latest-to-ifnotpresent
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (image): "*:latest"
                imagePullPolicy: IfNotPresent
            initContainers:
              - (image): "*:latest"
                imagePullPolicy: IfNotPresent
```

`(image)` is doing two jobs: it is the *filter* (only containers whose image ends in `:latest`) and, because the map has no `name` key, the *selector* Kyverno uses to find the target element. Containers with a pinned tag or a digest are untouched.

### 4.2 Add-if-not-present — the defaulting anchor, and its atomicity trap

Wrong (silently does nothing for half your fleet):

```yaml
        patchStrategicMerge:
          spec:
            +(securityContext):
              runAsNonRoot: true
              seccompProfile:
                type: RuntimeDefault
```

If a Pod already has *any* `spec.securityContext` — say `fsGroup: 2000` — the anchor sees the key present and skips **the entire subtree**. The Pod gets neither `runAsNonRoot` nor `seccompProfile`. `+()` is atomic on the whole value.

Correct — anchor each leaf, and let strategic merge create the missing parent:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pod-security-defaults
  annotations:
    policies.kyverno.io/title: Pod Security Standards Defaults
    policies.kyverno.io/description: >-
      Back-fills the pod- and container-level securityContext fields required by
      the restricted Pod Security Standard, without overriding values the
      workload author already set.
spec:
  admission: true
  background: false
  failurePolicy: Fail
  rules:
    - name: pod-level-defaults
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
                - UPDATE
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              +(runAsNonRoot): true
              +(seccompProfile):
                type: RuntimeDefault

    - name: container-level-defaults
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
                - UPDATE
      mutate:
        foreach:
          - list: request.object.spec.containers
            patchStrategicMerge:
              spec:
                containers:
                  - (name): "{{ element.name }}"
                    securityContext:
                      +(allowPrivilegeEscalation): false
                      +(privileged): false
                      +(capabilities):
                        drop:
                          - ALL
          - list: request.object.spec.initContainers || `[]`
            patchStrategicMerge:
              spec:
                initContainers:
                  - (name): "{{ element.name }}"
                    securityContext:
                      +(allowPrivilegeEscalation): false
                      +(capabilities):
                        drop:
                          - ALL
```

Note `+(capabilities)` is still atomic — deliberately. If a workload declares `capabilities: {add: [NET_BIND_SERVICE]}`, we do **not** silently inject `drop: [ALL]` and change its runtime behaviour; a separate validate rule flags it instead. Choosing where atomicity is a feature versus a bug is the actual skill here.

### 4.3 Global anchor — gate the whole patch on unrelated state

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: quarantine-socket-mounters
spec:
  rules:
    - name: force-readonly-when-mounting-container-runtime-socket
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            <(volumes):
              - (hostPath):
                  path: "/var/run/containerd/containerd.sock"
            containers:
              - (name): "*"
                securityContext:
                  privileged: false
                  readOnlyRootFilesystem: true
```

The `<(volumes)` block asserts a condition about `spec.volumes`; it is **not** itself patched. If no volume mounts the containerd socket, the entire rule is a no-op. Without the global anchor you would need a `precondition` with a JMESPath `contains(...)` expression — the anchor keeps the condition and the patch structurally adjacent.

### 4.4 Removal

```yaml
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              kubectl.kubernetes.io/last-applied-configuration: null
              scheduler.alpha.kubernetes.io/critical-pod: null
          spec:
            (hostNetwork): true
            hostNetwork: false
```

The second block reads: *if* `hostNetwork` is `true`, set it to `false`. Writing `hostNetwork: false` unconditionally would work too, but the conditional form keeps the emitted patch empty for the 99% of Pods that never set it — which keeps the audit trail and the Events clean.

---

## 5. RFC 6902 JSON patches

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ingress-hardening
spec:
  rules:
    - name: add-proxy-limits
      match:
        any:
          - resources:
              kinds:
                - networking.k8s.io/v1/Ingress
              operations:
                - CREATE
                - UPDATE
      preconditions:
        all:
          - key: "{{ request.object.metadata.annotations || '{}' | keys(@) }}"
            operator: AllNotIn
            value:
              - nginx.ingress.kubernetes.io/proxy-body-size
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size"
            value: "8m"
          - op: add
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-read-timeout"
            value: "60"
```

### 5.1 JSON Pointer escaping — the number-one `patchesJson6902` defect

RFC 6901 reserves two characters inside a pointer segment:

| Literal character in the key | Must be written as |
|---|---|
| `/` | `~1` |
| `~` | `~0` |

So the annotation key `nginx.ingress.kubernetes.io/proxy-body-size` becomes the path segment `nginx.ingress.kubernetes.io~1proxy-body-size`. Get this wrong and the patch either targets a nonexistent nested path or the API server rejects the resulting object. **Order matters when escaping by hand: replace `~` first, then `/`.**

### 5.2 `add` does not create parents

```yaml
        patchesJson6902: |-
          - op: add
            path: "/spec/tolerations/-"
            value:
              key: workload-class
              operator: Equal
              value: batch
              effect: NoSchedule
```

If the Pod has no `spec.tolerations`, this fails. Two safe shapes:

**(a) Guard with a precondition and emit the whole array when absent:**

```yaml
      preconditions:
        all:
          - key: "{{ request.object.spec.tolerations[?key=='workload-class'] | length(@) }}"
            operator: Equals
            value: 0
      mutate:
        patchStrategicMerge:
          spec:
            tolerations:
              - key: workload-class
                operator: Equal
                value: batch
                effect: NoSchedule
```

Strategic merge creates `tolerations` if absent, and the precondition makes the rule idempotent across reinvocation. **This is the pattern to use.**

**(b) Two ops, initialising first** — only valid if you accept clobbering:

```yaml
        patchesJson6902: |-
          - op: add
            path: "/spec/tolerations"
            value: []            # DESTRUCTIVE if tolerations already exist
          - op: add
            path: "/spec/tolerations/-"
            value: { ... }
```

Do not ship (b).

### 5.3 When `patchesJson6902` is genuinely the right tool

- Deleting an element by index: `- op: remove` / `path: "/spec/containers/2"`.
- Editing keys that contain `/` or `~`.
- Editing CRDs where strategic merge would replace lists.
- `op: test` guards: `- op: test` / `path: "/spec/replicas"` / `value: 1` — the whole patch aborts if the test fails, giving you atomic compare-and-set semantics inside a single patch.

---

## 6. `foreach`: mutating lists element by element

`foreach` iterates a JMESPath-selected list and applies a sub-patch per element. Inside the loop, `{{ element }}` is the current item and `{{ elementIndex }}` its zero-based position.

### 6.1 Registry rewrite for an air-gapped or pull-through-cache cluster

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: rewrite-public-registries
  annotations:
    policies.kyverno.io/title: Redirect Public Registries to Internal Mirror
    policies.kyverno.io/description: >-
      Normalises every image reference and rewrites docker.io / quay.io / ghcr.io
      pulls to the internal Harbor proxy projects. Images already hosted on the
      internal registry are left untouched so the rule is idempotent under
      webhook reinvocation.
spec:
  admission: true
  background: false
  failurePolicy: Fail
  rules:
    - name: rewrite-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
                - UPDATE
      mutate:
        foreach:
          - list: request.object.spec.containers
            preconditions:
              all:
                - key: "{{ image_normalize(element.image) }}"
                  operator: NotEquals
                  value: "harbor.internal.example.net/*"
            patchStrategicMerge:
              spec:
                containers:
                  - (name): "{{ element.name }}"
                    image: >-
                      {{ regex_replace_all('^(docker\.io|quay\.io|ghcr\.io|registry\.k8s\.io)/(.*)$',
                         image_normalize(element.image),
                         'harbor.internal.example.net/$1/$2') }}

          - list: request.object.spec.initContainers || `[]`
            preconditions:
              all:
                - key: "{{ image_normalize(element.image) }}"
                  operator: NotEquals
                  value: "harbor.internal.example.net/*"
            patchStrategicMerge:
              spec:
                initContainers:
                  - (name): "{{ element.name }}"
                    image: >-
                      {{ regex_replace_all('^(docker\.io|quay\.io|ghcr\.io|registry\.k8s\.io)/(.*)$',
                         image_normalize(element.image),
                         'harbor.internal.example.net/$1/$2') }}
```

Why `image_normalize` first: a bare `nginx` is not `docker.io/nginx` textually. `image_normalize` expands the short form to its fully-qualified `registry/repository:tag` shape so the regex has a registry component to anchor on. Skipping it is the reason naive registry-rewrite policies mangle `nginx:1.27` into `harbor.internal.example.net` with the tag lost.

Effect:

| Input image | Normalized | Output |
|---|---|---|
| `nginx` | `docker.io/nginx:latest` | `harbor.internal.example.net/docker.io/nginx:latest` |
| `quay.io/prometheus/node-exporter:v1.8.2` | unchanged | `harbor.internal.example.net/quay.io/prometheus/node-exporter:v1.8.2` |
| `harbor.internal.example.net/apps/api:2.1.0` | unchanged | untouched (precondition) |

### 6.2 `order` and destructive iteration

When a `foreach` removes elements, iterate **descending** so earlier removals do not shift the indices of later ones:

```yaml
      mutate:
        foreach:
          - list: request.object.spec.template.spec.volumes
            order: Descending
            preconditions:
              all:
                - key: "{{ element.hostPath.path || '' }}"
                  operator: Equals
                  value: "/var/lib/kubelet"
            patchesJson6902: |-
              - op: remove
                path: "/spec/template/spec/volumes/{{ elementIndex }}"
```

`order` accepts `Ascending` (default) or `Descending`.

### 6.3 `foreach` vs a single strategic merge

Use plain `patchStrategicMerge` with `(name): "*"` when the patched value is **identical** for every element. Use `foreach` when the value is **derived from the element** — a rewritten image, a per-container resource default computed from the container name, a `VOLUME`-derived mount. The `foreach` version costs one JMESPath evaluation per element; on a 40-container Pod that is measurable in the webhook latency histogram, but never the bottleneck.

---

## 7. Variables, context and JMESPath inside mutations

Available roots in an admission-time mutate rule:

| Variable | Contents |
|---|---|
| `request.object` | The incoming object (post any earlier mutation in the same admission pass) |
| `request.oldObject` | Previous state on `UPDATE`/`DELETE`; `null` on `CREATE` |
| `request.operation` | `CREATE` \| `UPDATE` \| `DELETE` \| `CONNECT` |
| `request.userInfo` | `username`, `groups`, `uid` of the requester |
| `request.namespace` | Namespace of the request |
| `serviceAccountName`, `serviceAccountNamespace` | Convenience splits of `request.userInfo.username` |
| `element`, `elementIndex` | Inside `foreach` |
| `target` | Inside a **mutate-existing** rule: the object being patched (§8) |
| `images` | Kyverno-parsed image references: `images.containers.<name>.{registry,path,name,tag,digest}` |

### 7.1 Pulling external context

```yaml
    - name: inject-tenant-defaults
      match:
        any:
          - resources:
              kinds:
                - Pod
      context:
        # 1. Read a ConfigMap in the Kyverno namespace
        - name: tenantcfg
          configMap:
            name: tenant-defaults
            namespace: platform-system
        # 2. Read the Pod's own Namespace object via the API
        - name: ns
          apiCall:
            urlPath: "/api/v1/namespaces/{{ request.namespace }}"
            jmesPath: "metadata.labels"
        # 3. Derive a value with pure JMESPath
        - name: costCenter
          variable:
            jmesPath: 'ns."company.io/cost-center"'
            default: "unassigned"
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              +(company.io/cost-center): "{{ costCenter }}"
              +(company.io/tier): "{{ tenantcfg.data.tier }}"
          spec:
            +(priorityClassName): "{{ tenantcfg.data.priorityClass }}"
```

Three operational notes:

- `configMap` context is served from an **informer cache**; a ConfigMap edit propagates within seconds, not instantly. Do not use it for anything with a hard consistency requirement.
- `apiCall` runs on the **admission hot path**. It is bounded by `webhookTimeoutSeconds` (max 30, default 10). An `apiCall` to a slow aggregated API server with `failurePolicy: Fail` will take your cluster's writes down. Prefer `configMap` context, or a `variable` derived from data already in the request.
- `default:` on a `variable` context is what prevents a missing label from failing the whole rule. Without it, an unresolvable variable makes Kyverno fail the rule (and, with `failurePolicy: Fail`, the request).

### 7.2 JMESPath functions worth memorising for mutations

| Function | Use in mutation |
|---|---|
| `regex_replace_all(regex, src, repl)` | Registry rewrites; `$1`/`${1}` capture-group expansion |
| `regex_replace_all_literal(regex, src, repl)` | Same, replacement treated literally |
| `image_normalize(image)` | Expand short image refs before matching |
| `to_upper` / `to_lower` | Label/annotation normalisation |
| `split(str, sep)` / `join(sep, arr)` | Deriving values from names |
| `truncate(str, n)` | Fitting a derived value into the 63-char label limit |
| `sha256(str)` | Stable short identifiers |
| `semver_compare(a, constraint)` | Version-gated mutations |
| `add`, `subtract`, `multiply`, `divide` | Computing resource values (quantity-aware) |
| `parse_json` / `to_string` | ConfigMap values, which are always strings |
| `time_add`, `time_now_utc` | TTL / expiry annotations |

Watch the label-length ceiling: `truncate(to_lower(...), 63)` is not optional when the source is a free-form field.

---

## 8. Mutating **existing** resources

Everything so far runs at admission and therefore only affects *future* writes. Kyverno's `mutate.targets` extends the same rule grammar to objects already in etcd, executed by the **background controller**.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-cost-center
  annotations:
    policies.kyverno.io/title: Propagate Cost Center From Namespace
spec:
  rules:
    - name: sync-to-deployments
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.\"company.io/cost-center\" || '' }}"
            operator: NotEquals
            value: ""
      mutate:
        mutateExistingOnPolicyUpdate: true
        targets:
          - apiVersion: apps/v1
            kind: Deployment
            namespace: "{{ request.object.metadata.name }}"
          - apiVersion: apps/v1
            kind: StatefulSet
            namespace: "{{ request.object.metadata.name }}"
        patchStrategicMerge:
          metadata:
            labels:
              company.io/cost-center: >-
                {{ request.object.metadata.labels."company.io/cost-center" }}
```

### 8.1 Semantics you must internalise

| Aspect | Admission-time mutate | Mutate-existing (`targets`) |
|---|---|---|
| Executed by | admission controller (in-band) | background controller (out-of-band) |
| Trigger | the matched request itself | the matched request, **plus** policy create/update if `mutateExistingOnPolicyUpdate: true` |
| Object patched | the request object | every object matching `targets` |
| Failure mode | request denied (`failurePolicy: Fail`) or allowed unmutated (`Ignore`) | Warning Event; the triggering request is **not** affected |
| Variable for the patched object | `request.object` | **`target`** |
| RBAC needed | none beyond the webhook | explicit `update`/`patch` grants (§8.2) |
| Atomicity | yes, one API transaction | no — best-effort, eventually consistent |

Inside a mutate-existing rule, `request.object` is the **trigger** and `target` is the **object being patched**. Mixing them up is the single most common authoring error:

```yaml
        patchStrategicMerge:
          metadata:
            annotations:
              # value taken from the TRIGGER (the Namespace)
              company.io/synced-from: "{{ request.object.metadata.name }}"
              # value taken from the TARGET (each Deployment)
              company.io/previous-replicas: "{{ target.spec.replicas }}"
```

### 8.2 RBAC — the reason mutate-existing "silently does nothing"

Kyverno's background controller ships with deliberately narrow permissions. To let it write to a resource kind you must aggregate a ClusterRole:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:background-controller:workload-mutation
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups:
      - apps
    resources:
      - deployments
      - statefulsets
    verbs:
      - get
      - list
      - watch
      - update
      - patch
```

Without it:

```
$ kubectl -n platform-system logs deploy/kyverno-background-controller | grep -i forbidden
E0813 11:04:22.118  mutate-existing  failed to update target  {"policy": "propagate-cost-center",
  "rule": "sync-to-deployments", "target": "apps/v1/Deployment/team-a/api",
  "error": "deployments.apps \"api\" is forbidden: User
  \"system:serviceaccount:platform-system:kyverno-background-controller\" cannot patch
  resource \"deployments\" in API group \"apps\" in the namespace \"team-a\""}
```

### 8.3 Do not target Pods

Almost every Pod field is immutable after creation — `spec.containers[*].image` is mutable, `securityContext`, `volumes`, `nodeSelector` are not. A mutate-existing rule targeting Pods produces a stream of `Warning PolicyError` events and never converges. **Target the controller** (`Deployment`, `StatefulSet`, `DaemonSet`, `CronJob`) and let the rollout replace the Pods. Note that this means the mutation is *not* applied to running Pods until the next rollout — say so explicitly in your policy's `description`, because operators will ask.

### 8.4 Loop protection

If the trigger match and the `targets` selector overlap, each patch generates an `UPDATE` that re-triggers the rule. Kyverno detects that a patch is a no-op and stops, so a correctly-written idempotent rule converges after one pass. A rule that writes a changing value (a timestamp, a counter, `time_now_utc()`) never converges and will hot-loop the background controller against the API server. **Never write a non-deterministic value in a mutate-existing rule whose target can also be its trigger.**

---

## 9. Auto-gen: Pod rules and Pod controllers

A rule that matches only `Pod` would miss every Deployment — the Deployment is admitted first, and its Pods are created later by the controller-manager's ServiceAccount (which you may have excluded). Kyverno solves this by **auto-generating** copies of your rule for Pod controllers, re-rooting all paths at `spec.template`.

```
$ kubectl get clusterpolicy pod-security-defaults -o yaml | yq '.spec.rules[].name'
pod-level-defaults
container-level-defaults
autogen-pod-level-defaults
autogen-container-level-defaults
autogen-cronjob-pod-level-defaults
autogen-cronjob-container-level-defaults
```

Control it with an annotation on the policy:

```yaml
metadata:
  annotations:
    # Restrict to specific controllers
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet
    # Or disable entirely
    # pod-policies.kyverno.io/autogen-controllers: none
```

Rules that break auto-gen — memorise these, they are exam-typical and incident-typical:

1. **The `match` block includes kinds other than `Pod`.** Auto-gen is skipped for the whole rule. If you need both Pods and a CRD, write two rules.
2. **The rule references `request.object.spec.containers` in a `context` or `precondition`** while the generated variant needs `request.object.spec.template.spec.containers`. Kyverno rewrites paths inside `patchStrategicMerge` and `patchesJson6902`, and inside `foreach.list`, but you should verify rather than assume — read the generated rule.
3. **`patchesJson6902` with hand-written absolute paths** — the generated rule gets `/spec/template` prepended; confirm the result is what you intended.
4. **Auto-gen produces `Pod` rules for direct Pod creation too.** A Pod created by a Job created by a CronJob is covered by the `autogen-cronjob-*` rules.

---

## 10. Ordering, idempotency and conflicts

### 10.1 Within a policy

Rules execute top to bottom. Rule 2 sees rule 1's output. `spec.applyRules: One` stops after the first rule that matches — useful for a prioritized fallback chain (rewrite for tenant A, else tenant B, else the default).

### 10.2 Across policies

Not ordered in a way you should depend on. If you have `set-registry` and `pin-digest` policies and the second must run after the first, merge them into one policy with two rules.

### 10.3 Against other webhooks

The API server calls mutating webhooks serially, sorted by `MutatingWebhookConfiguration` name. Kyverno's is `kyverno-resource-mutating-webhook-cfg`; Istio's is typically `istio-sidecar-injector`. `i` < `k`, so Istio runs first and Kyverno sees the injected `istio-proxy` container. Reverse that on a different service mesh and your `foreach` over `spec.containers` will not see the sidecar at all on the first pass — only on the `reinvocationPolicy: IfNeeded` second pass.

**The correctness requirement this imposes:** every mutate rule must be safe to apply twice. Test it:

```
$ kyverno apply policies/ --resource out.yaml   # feed the mutated output back in
```

If the second run's output differs from its input, the rule is not idempotent. Fix it with a precondition or an `+()`/`()` anchor.

### 10.4 Interaction with `verifyImages`

`verifyImages` rules with `mutateDigest: true` (the default) rewrite `image: repo/app:1.2.3` to `image: repo/app:1.2.3@sha256:...` after signature verification. If your registry-rewrite mutation runs after that, its regex must tolerate a digest suffix. Anchoring the regex on the registry prefix (`^(docker\.io|quay\.io)/(.*)$`) rather than the tag is what makes §6.1 safe here.

---

## 11. Verification

### 11.1 Server-side dry-run — the highest-value single command

```
$ kubectl -n team-a apply --dry-run=server -f pod.yaml -o yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    company.io/cost-center: cc-4471
  name: web
  namespace: team-a
spec:
  containers:
  - image: harbor.internal.example.net/docker.io/nginx:latest
    imagePullPolicy: IfNotPresent
    name: web
    resources: {}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      privileged: false
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  ...
```

`--dry-run=server` runs the **entire real admission chain** — every webhook, in the real order, with the real cluster's policies and context — and returns the object the API server *would* have persisted, without persisting it. Nothing else reproduces webhook interleaving faithfully. Make it a required step in your policy-promotion pipeline.

### 11.2 Kyverno CLI — offline evaluation

```
$ kyverno apply policies/pod-security-defaults.yaml --resource tests/pod-plain.yaml

Applying 2 policy rule(s) to 1 resource(s)...

mutate policy pod-security-defaults applied to team-a/Pod/web:

apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: team-a
spec:
  containers:
  - image: nginx:1.27.1
    name: web
    resources: {}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      privileged: false
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
---

pass: 2, fail: 0, warn: 0, error: 0, skip: 0
```

Useful flags:

| Flag | Purpose |
|---|---|
| `--resource <file\|dir>` | Resources to evaluate (repeatable) |
| `--cluster` | Fetch resources from the live cluster instead of files |
| `--set <key>=<value>` / `--values-file` | Supply variables (`request.operation`, `request.userInfo`, ConfigMap context) |
| `--policy-report` | Emit a `PolicyReport` instead of human output |
| `--detailed-results` | Per-rule breakdown |
| `-v 4` | Verbose engine tracing |

For a rule that reads context, `--values-file` is mandatory offline:

```yaml
# values.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
policies:
  - name: propagate-cost-center
    rules:
      - name: sync-to-deployments
        values:
          costCenter: cc-4471
namespaceSelector:
  - name: team-a
    labels:
      company.io/cost-center: cc-4471
```

### 11.3 Declarative regression tests

`kyverno test` is what belongs in CI. For mutate rules, assert the **exact patched object**.

```yaml
# tests/kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: pod-security-defaults
policies:
  - ../policies/pod-security-defaults.yaml
resources:
  - resources/pod-plain.yaml
  - resources/pod-already-hardened.yaml
results:
  - policy: pod-security-defaults
    rule: pod-level-defaults
    kind: Pod
    resources:
      - web
    patchedResource: patched/pod-plain-patched.yaml
    result: pass
  - policy: pod-security-defaults
    rule: pod-level-defaults
    kind: Pod
    resources:
      - hardened
    result: skip
```

```
$ kyverno test tests/

Loading test  ( tests/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 2 policy rule(s) to 2 resource(s) ...
  Checking results ...

│───│──────────────────────│─────────────────────│──────────────────│────────│
│ # │ POLICY               │ RULE                │ RESOURCE         │ RESULT │
│───│──────────────────────│─────────────────────│──────────────────│────────│
│ 1 │ pod-security-defaults│ pod-level-defaults  │ team-a/Pod/web   │ Pass   │
│ 2 │ pod-security-defaults│ pod-level-defaults  │ team-a/Pod/harde │ Pass   │
│───│──────────────────────│─────────────────────│──────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

`patchedResource` is the assertion that catches anchor-atomicity bugs (§4.2). A `result: pass` alone would not — the rule "applied", it just applied nothing useful. **Always pin `patchedResource` for mutate tests.**

### 11.4 Confirming the webhook is even registered

```
$ kubectl get mutatingwebhookconfigurations
NAME                                     WEBHOOKS   AGE
kyverno-policy-mutating-webhook-cfg      1          31d
kyverno-resource-mutating-webhook-cfg    2          31d
kyverno-verify-mutating-webhook-cfg      1          31d

$ kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.failurePolicy}{"\t"}{.timeoutSeconds}{"\t"}{.reinvocationPolicy}{"\n"}{end}'
mutate.kyverno.svc-fail	    Fail	 10	IfNeeded
mutate.kyverno.svc-ignore	Ignore	 10	IfNeeded
```

Kyverno maintains this configuration **dynamically**: the `rules` list contains only the resource kinds actually matched by installed policies. If you install your first Ingress-mutating policy, the webhook grows an `ingresses` rule a few seconds later. If `rules` does not list your kind, no mutation will ever occur — regardless of how correct the policy is.

```
$ kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
    -o jsonpath='{.webhooks[0].rules}' | jq '.[].resources'
[ "pods", "pods/ephemeralcontainers" ]
[ "deployments", "statefulsets", "daemonsets", "jobs", "cronjobs" ]
```

### 11.5 Events

```
$ kubectl -n team-a get events --field-selector reason=PolicyApplied --sort-by=.lastTimestamp
LAST SEEN   TYPE     REASON          OBJECT          MESSAGE
12s         Normal   PolicyApplied   pod/web         policy pod-security-defaults/pod-level-defaults applied
12s         Normal   PolicyApplied   pod/web         policy rewrite-public-registries/rewrite-containers applied
```

Note the reporting asymmetry: **mutate rules surface as Events, not as `PolicyReport` entries** the way `validate` and `verifyImages` results do. The authoritative evidence that a mutation happened is the mutated object itself plus these Events. Build your dashboards accordingly.

---

## 12. Failure diagnosis playbook

| Symptom | Likely cause | Command that proves it |
|---|---|---|
| Policy exists, nothing is mutated, no Events | Resource filtered by the `resourceFilters` in the Kyverno ConfigMap (defaults exclude `kube-system`, the Kyverno namespace, and several kinds) | `kubectl -n <kyverno-ns> get cm kyverno -o jsonpath='{.data.resourceFilters}'` |
| Same, and the namespace is not filtered | Kind not present in the webhook's `rules` — policy failed to compile | `kubectl get clusterpolicy <p> -o jsonpath='{.status.conditions}'` and check `READY` |
| `kubectl get clusterpolicy` shows `READY: False` | Schema validation of the patch failed at policy admission | `kubectl describe clusterpolicy <p>` |
| Works for Pods, not for Deployments | Auto-gen skipped (match includes non-Pod kinds) or disabled by annotation | `kubectl get clusterpolicy <p> -o yaml \| grep autogen-` |
| Mutation applied twice (duplicated toleration / sidecar) | Non-idempotent rule + `reinvocationPolicy: IfNeeded` re-entry | Re-feed the output: `kyverno apply policies/ --resource mutated.yaml` |
| `+()` anchor appears to do nothing | Parent key already exists ⇒ whole subtree skipped (§4.2) | Compare the object's existing parent map against the anchored key |
| `patchesJson6902` "path does not exist" | Missing parent, or unescaped `/` in a key (RFC 6901) | Decode the rule's path; check `~1`/`~0` |
| Object is silently unmutated during a Kyverno outage | `failurePolicy: Ignore` — fails open by design | `kubectl get mutatingwebhookconfiguration ... -o yaml \| grep failurePolicy` |
| API writes hang or 500 during a Kyverno outage | `failurePolicy: Fail` — fails closed | Same; plus check controller readiness |
| Intermittent `context deadline exceeded` on admission | `apiCall` context on the hot path exceeding `webhookTimeoutSeconds` | Kyverno logs; metric `kyverno_admission_review_duration_seconds` |
| Mutate-existing does nothing | Missing background-controller RBAC (§8.2) | `kubectl -n <kyverno-ns> logs deploy/kyverno-background-controller \| grep -i forbidden` |
| Mutate-existing loops forever | Non-deterministic value in a self-triggering rule (§8.4) | Event flood on the target; rising `kyverno_policy_results_total` |
| One namespace exempt for no apparent reason | A `PolicyException` matches it | `kubectl get polex -A` |
| Variable resolution error kills the request | Missing `default:` on a `variable` context | Kyverno logs: `variable substitution failed` |

Raise engine verbosity when the above is inconclusive:

```
$ kubectl -n platform-system set env deploy/kyverno-admission-controller -- -v=4
deployment.apps/kyverno-admission-controller env updated

$ kubectl -n platform-system logs -f deploy/kyverno-admission-controller | grep -i mutate
I0813 11:41:07.552  engine.mutate  mutate rule applied successfully  {"policy":"pod-security-defaults",
  "rule":"pod-level-defaults","kind":"Pod","namespace":"team-a","name":"web",
  "patches":["{\"op\":\"add\",\"path\":\"/spec/securityContext\",\"value\":{\"runAsNonRoot\":true,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}}}"]}
```

Revert verbosity afterwards — `-v=4` on a busy cluster is a meaningful log-volume and CPU cost.

Metrics to alert on:

| Metric | Alert on |
|---|---|
| `kyverno_admission_review_duration_seconds` | p99 approaching `webhookTimeoutSeconds` |
| `kyverno_admission_requests_total` | sudden drop ⇒ webhook deregistered |
| `kyverno_policy_results_total{rule_type="mutate"}` | unexplained growth ⇒ mutate-existing loop |
| `kyverno_policy_execution_duration_seconds` | per-rule regression after a policy change |

---

## 13. The comparative landscape

| | **Kyverno `mutate`** | **Gatekeeper Mutation** (`Assign`, `AssignMetadata`, `ModifySet`, `AssignImage`) | **`MutatingAdmissionPolicy`** (in-tree CEL) | **Bespoke webhook** |
|---|---|---|---|---|
| Language | YAML + anchors + JMESPath | YAML, one CRD per operation shape | CEL expressions + Apply-Configuration or JSON Patch | Go/Rust/… |
| Turing-complete logic | No (deliberately) | No | No | Yes |
| External data at admission | ConfigMap, API call, image registry, Secret | Limited (`external data` provider, beta) | No — request/authorizer only | Anything |
| Mutate **existing** objects | Yes (`targets`) | No | No | Only if you build a controller |
| Extra components | Kyverno controllers | Gatekeeper controllers | **None** — runs in the API server | Yours to build, scale, certify, and page for |
| Latency added | one network hop | one network hop | in-process | one network hop |
| Availability blast radius | webhook down ⇒ fail-open or fail-closed | same | none | same |
| Maturity for mutation | GA, broad policy library | GA | beta as of Kubernetes 1.34 | n/a |
| Auto-gen for Pod controllers | Yes | No | No | No |
| Best for | The general case; anything needing external context or back-fill | Shops already standardised on OPA/Rego for validation | Simple, hot-path, high-volume defaults with no external data | Genuinely bespoke logic that no policy engine can express |

**Architectural guidance.** Where a mutation is simple, static and on a high-QPS path, `MutatingAdmissionPolicy` is strictly better — it costs no network hop and cannot take your cluster down. Where a mutation needs external context (`ConfigMap`, `apiCall`), needs to touch objects already in etcd (`targets`), or needs auto-gen across Pod controllers, Kyverno is the answer and there is currently no in-tree equivalent. Expect a hybrid steady state, not a migration. A bespoke webhook should be the last resort: you are signing up to operate a component on the critical path of every write in the cluster.

---

## 14. Exam-focused summary

- One `mutate` block per rule; exactly one of `patchStrategicMerge` | `patchesJson6902` | `foreach`.
- Mutate anchors: `()` conditional, `+()` add-if-absent, `<()` global. `=()`, `^()`, `X()` are **validate-only**.
- `+()` is **atomic over its whole value** — anchor leaves, not parents, when you want partial defaulting.
- `patchesJson6902` does **not** create missing parents; escape `/` as `~1` and `~` as `~0` (RFC 6901).
- `foreach` gives `{{ element }}` and `{{ elementIndex }}`; use `order: Descending` when removing.
- `targets` + `mutateExistingOnPolicyUpdate: true` = mutate existing; needs a ClusterRole labelled `rbac.kyverno.io/aggregate-to-background-controller: "true"`; the patched object is `target`, the trigger is `request.object`.
- Auto-gen creates `autogen-*` rules for Pod controllers, but only when the rule matches Pods **alone**.
- Kyverno's resource mutating webhook uses `reinvocationPolicy: IfNeeded` ⇒ **rules must be idempotent**.
- Verify with `kubectl apply --dry-run=server -o yaml` (in-cluster) and `kyverno test` with `patchedResource` (CI).
- Mutation results appear as Events, not as `PolicyReport` entries.

---

## Referencias

**CNCF / certification**
- KCA curriculum (CNCF): https://github.com/cncf/curriculum
- KCA curriculum PDF: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- Kyverno project (CNCF Incubating): https://kyverno.io/

**Kyverno documentation**
- Mutate rules: https://kyverno.io/docs/writing-policies/mutate/
- Anchors (conditional, add-if-not-present, global): https://kyverno.io/docs/writing-policies/validate/#anchors
- Preconditions: https://kyverno.io/docs/writing-policies/preconditions/
- Variables and external context: https://kyverno.io/docs/writing-policies/external-data-sources/
- JMESPath custom filters: https://kyverno.io/docs/writing-policies/jmespath/
- Auto-generation for Pod controllers: https://kyverno.io/docs/writing-policies/autogen/
- Policy exceptions: https://kyverno.io/docs/writing-policies/exceptions/
- Image verification (`mutateDigest`): https://kyverno.io/docs/writing-policies/verify-images/
- Kyverno CLI (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Installation, webhook and ConfigMap configuration: https://kyverno.io/docs/installation/customization/
- Troubleshooting guide: https://kyverno.io/docs/troubleshooting/
- Ready-made policy library: https://kyverno.io/policies/

**Kubernetes documentation**
- Dynamic Admission Control (mutating webhooks, ordering, `reinvocationPolicy`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Admission control in Kubernetes: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Update API objects in place using `kubectl patch` (strategic merge, merge keys): https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- Server-side dry run: https://kubernetes.io/docs/reference/using-api/api-concepts/#dry-run
- Mutating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Labels and selectors (63-character value limit): https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/

**Standards**
- RFC 6902 — JavaScript Object Notation (JSON) Patch: https://datatracker.ietf.org/doc/html/rfc6902
- RFC 6901 — JavaScript Object Notation (JSON) Pointer (`~0` / `~1` escaping): https://datatracker.ietf.org/doc/html/rfc6901
- JMESPath specification: https://jmespath.org/specification.html

**Comparative**
- OPA Gatekeeper mutation: https://open-policy-agent.github.io/gatekeeper/website/docs/mutation/