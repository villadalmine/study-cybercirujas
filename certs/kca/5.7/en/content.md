# 5.7 Variables & API Calls in Policies

**Domain 5 — Applying Policies · Exam weight: 2.91**

---

## 1. The production problem: policy is code, but the decision is data

A Kyverno rule written entirely with literals is a *static* assertion. It can answer "does this Pod have `runAsNonRoot: true`?" It cannot answer any of the questions that actually generate incidents in a multi-tenant platform:

| Real question from a platform team | Why literals fail |
|---|---|
| "Is this image registry allowed **for this tenant**?" | The allowlist differs per namespace and changes weekly without a policy release. |
| "Does this namespace already have 20 LoadBalancer Services?" | The answer lives in the API server, not in the `AdmissionReview`. |
| "Is the namespace labelled `env=prod`?" | `AdmissionReview` carries the **object**, not the namespace object it belongs to. Namespace labels are *not* in the request. |
| "Is the requesting user actually allowed to delete in `kube-system`?" | Requires a `SubjectAccessReview` — a **write** call to the API during admission. |
| "Does the container image run as UID 0 **in its own config**?" | The answer is in the OCI image config blob in the registry, not in the manifest. |
| "Is this CVE exception still valid, or did it expire?" | Requires date arithmetic against `now`. |

Kyverno closes this gap with two coupled mechanisms:

1. **Variables** — a JMESPath-based substitution engine that injects runtime data into any policy field before the rule is evaluated.
2. **Context** — a per-rule data-loading stage (`context[]`) that pulls external state (ConfigMaps, Kubernetes API, registries, arbitrary HTTPS services, cached global entries) into the variable namespace.

The architectural consequence is the thing you must internalise for production: **`context` runs synchronously inside the admission webhook call path.** Every `apiCall` you add is latency added to *every* matching API write in the cluster, and — if `failurePolicy: Fail` — a new dependency whose failure blocks writes cluster-wide. Variables turn Kyverno from a linter into a distributed system component with a latency budget and a blast radius.

```
                        kube-apiserver
                              │ AdmissionReview (10s webhook timeout)
                              ▼
                 ┌──────────────────────────────┐
                 │ kyverno-admission-controller │
                 │                              │
   match/exclude │  1. rule selection           │  ← NO variables here
                 │  2. context[] load  ─────────┼──►  ConfigMap informer (cache, ~0ms)
                 │     (sequential, ordered)    ├──►  in-cluster API   (~1–20ms)
                 │                              ├──►  GlobalContextEntry (cache, ~0ms)
                 │                              ├──►  external service (RTT + TLS)
                 │                              └──►  OCI registry     (100–800ms)
                 │  3. variable substitution    │
                 │  4. preconditions            │
                 │  5. validate/mutate/generate │
                 └──────────────────────────────┘
                              │ AdmissionResponse
                              ▼
```

Steps 2 and 3 are the subject of this topic.

---

## 2. The substitution engine

### 2.1 Syntax

A variable is `{{ <JMESPath expression> }}`. Kyverno walks the entire rule body as an untyped tree, finds string values containing `{{ … }}`, evaluates the expression against a **context object**, and replaces the placeholder.

```yaml
message: "Pod {{ request.object.metadata.name }} in {{ request.namespace }} is invalid"
```

Two behaviours you must know cold:

* **Whole-string substitution preserves type.** If the string is *exactly* `"{{ expr }}"` and `expr` evaluates to a list or an object, the result is a real list/object, not a string. If the placeholder is embedded in surrounding text, the result is coerced to a string.

  ```yaml
  value: "{{ teams }}"        # → ["payments","search"]   (a list)
  value: "team is {{ team }}" # → "team is payments"      (a string)
  ```

* **Escaping.** A literal `{{` is written `\{{`. This matters constantly when a policy generates Helm templates, Prometheus rules, or Grafana dashboards via `generate`.

  ```yaml
  expr: 'sum(rate(http_requests_total[5m])) by (job)'
  legend: '\{{ job }}'      # rendered literally as {{ job }}
  ```

* **Nested resolution.** Kyverno resolves variables inside variables, up to a bounded depth: `{{ dictionary.data.{{ request.object.metadata.labels.tier }} }}` is legal but hostile to read — prefer a `variable` context entry.

### 2.2 Where variables are and are not allowed

This is the single most common policy-authoring error.

| Field | Variables? | Note |
|---|---|---|
| `spec.rules[].match` / `exclude` | **No** (with narrow, documented exceptions) | Rule selection happens before substitution. The policy validation webhook rejects it. |
| `spec.rules[].name` | No | Rule identity must be stable for reporting. |
| `context[].configMap.name` / `.namespace` | Yes | Resolved from `request.*` only. |
| `context[].apiCall.urlPath` | Yes | The classic `"/api/v1/namespaces/{{ request.namespace }}/pods"`. |
| `preconditions` | Yes | Both `key` and `value`. |
| `validate.message` | Yes | Interpolated into the denial text the user sees. |
| `validate.pattern` / `anyPattern` | Yes | |
| `validate.deny.conditions` | Yes | |
| `validate.foreach[].*` | Yes, plus `element`/`elementIndex` | |
| `mutate.patchStrategicMerge` / `patchesJson6902` | Yes | |
| `generate.data` / `clone` | Yes | |
| `spec.background` behaviour | — | See §2.4. |

If you place a variable in `match`, policy creation fails at admission:

```console
$ kubectl apply -f bad-policy.yaml
Error from server: error when creating "bad-policy.yaml": admission webhook
"validate-policy.kyverno.svc" denied the request: spec.rules[0].match: Invalid
value: "{{ request.object.metadata.labels.tier }}": variables are not allowed
in the match section
```

### 2.3 Built-in variables

| Variable | Available when | Content |
|---|---|---|
| `request.object` | CREATE, UPDATE, CONNECT | The incoming resource. **`null` on DELETE.** |
| `request.oldObject` | UPDATE, DELETE | The prior state. The *only* source on DELETE. |
| `request.operation` | Admission only | `CREATE` \| `UPDATE` \| `DELETE` \| `CONNECT` |
| `request.userInfo` | Admission only | `{username, uid, groups, extra}` |
| `request.roles`, `request.clusterRoles` | Admission only | Role names bound to the requester. |
| `request.namespace` | Admission only | Namespace of the request (not necessarily `object.metadata.namespace`). |
| `serviceAccountName` | Admission only | Derived from `system:serviceaccount:<ns>:<name>` → `<name>`. |
| `serviceAccountNamespace` | Admission only | → `<ns>` |
| `images` | Always | Normalised image data: `images.containers."<name>".{registry,path,name,tag,digest,reference}`; also `images.initContainers`, `images.ephemeralContainers`. |
| `element`, `elementIndex` | Inside `foreach` | Current list item and its 0-based index. |
| `@` | Inside `foreach`/pattern | Shorthand for the current element. |
| `target` | `mutate.targets`, `generate` | The *existing* resource being modified, as opposed to the trigger. |
| `globalContext.<name>` | Always | See §3.6. |

**Normalised images are worth a second look.** Kyverno canonicalises `nginx` into `docker.io/nginx:latest` so your policies never have to handle the implicit-registry / implicit-tag cases:

```console
$ kyverno jp query -i pod.yaml 'images.containers."web"'
{
  "digest": "",
  "image": "docker.io/nginx:1.27",
  "name": "web",
  "path": "nginx",
  "reference": "docker.io/nginx:1.27",
  "referenceWithTag": "docker.io/nginx:1.27",
  "registry": "docker.io",
  "tag": "1.27"
}
```

### 2.4 Admission mode vs. background mode — a hard constraint

Kyverno evaluates policies twice: once in the admission path, and again in **background scans** (the reports controller re-evaluating existing resources for `PolicyReport`s, and the background controller for `generate` / `mutateExisting`).

Background scans have **no `AdmissionReview`**. Therefore `request.userInfo`, `request.roles`, `request.clusterRoles`, `serviceAccountName`, `serviceAccountNamespace` and `request.operation` do not exist there. Kyverno refuses the policy at creation time rather than failing silently:

```console
$ kubectl apply -f audit-user.yaml
Error from server: error when creating "audit-user.yaml": admission webhook
"validate-policy.kyverno.svc" denied the request: spec.background: Invalid
value: true: variables {{request.userInfo.username}} are not supported in
background mode. Set spec.background=false
```

The fix — and the exam answer — is `spec.background: false`. The cost is that such policies produce **no `PolicyReport` results for pre-existing resources**; they only act at admission time. Be explicit about that trade-off in a design review.

A defensive idiom you will see throughout the Kyverno docs guards `request.operation` so a policy can be safely reused in both modes:

```yaml
preconditions:
  all:
  - key: "{{ request.operation || 'BACKGROUND' }}"
    operator: AnyIn
    value:
    - CREATE
    - UPDATE
```

`||` is the JMESPath **or-expression**: it returns the right-hand side when the left is `null` or "false-like". It is the primary tool for defaults, and it is what keeps rules from erroring out on absent fields.

---

## 3. `context[]` — the data-loading stage

`context` is an **ordered** list evaluated top to bottom, per rule, before preconditions. Later entries may reference earlier ones. Entry `name` becomes a top-level variable.

### 3.1 Comparison of context sources

| Source | Backing mechanism | Typical latency in the admission path | Freshness | RBAC required | Best used for |
|---|---|---|---|---|---|
| `configMap` | Kubernetes informer cache in the controller | ~0 (in-memory) | Watch-driven, near real-time | `get/list/watch configmaps` (in the default Kyverno roles) | Allowlists, tenant dictionaries, tunable thresholds |
| `apiCall` (in-cluster, GET) | Direct call to `kube-apiserver` | 1–20 ms p50, tail unbounded | Strongly consistent (read-through) | Explicit, per-resource, must be aggregated in | Counting resources, reading namespace labels, cross-object checks |
| `apiCall` (in-cluster, POST) | Direct call, writes a review object | 5–30 ms | Strongly consistent | `create subjectaccessreviews` etc. | Authorization-aware policy (`SubjectAccessReview`) |
| `apiCall` with `service` | HTTPS to an arbitrary endpoint | Network RTT + TLS; the dominant cost | Whatever the service says | None in-cluster; needs `caBundle` | CMDB lookups, external risk scoring, licence servers |
| `imageRegistry` | OCI registry pull of manifest + config blob | 100–800 ms cold, cached briefly | Registry-dependent | None in-cluster; needs registry creds | Reading image labels, `USER`, exposed ports, SBOM refs |
| `globalReference` (GlobalContextEntry) | Background-refreshed cache in Kyverno | ~0 (in-memory) | Stale by up to `refreshInterval` | Same as `apiCall`, granted once | High-frequency lookups that would otherwise hammer the API server |
| `variable` | Pure computation | 0 | — | — | Naming intermediate JMESPath expressions, defaults |

**The engineering rule:** if a rule matches a high-QPS resource (Pods, Events, Leases) and needs cluster state, use a `GlobalContextEntry`, not a raw `apiCall`. If it matches a low-QPS resource (Namespaces, Ingresses), a direct `apiCall` is fine and gives you strong consistency.

### 3.2 `configMap`

```yaml
context:
- name: registries
  configMap:
    name: allowed-registries
    namespace: kyverno
```

Accessing keys:

```yaml
# simple key
{{ registries.data.default }}

# key containing '-' or '.' MUST be quoted in JMESPath
{{ registries.data."prod-allowlist" }}
```

**The array trap.** ConfigMap values are always strings. To use one as a list, parse it explicitly:

```yaml
- key: "{{ images.containers.*.registry }}"
  operator: AllIn
  value: "{{ parse_json(registries.data.\"prod-allowlist\") }}"
```

Storing the value as YAML in the ConfigMap and using `parse_yaml()` works equally well and is friendlier to humans editing it via GitOps.

If the ConfigMap does not exist, the variable resolves to `null` — it is **not** a hard error at load time; the failure surfaces later as an unresolved variable. Always pair it with a `default`:

```yaml
context:
- name: registries
  configMap:
    name: allowed-registries
    namespace: kyverno
- name: allowlist
  variable:
    jmesPath: 'parse_json(registries.data."prod-allowlist")'
    default: ["registry.internal.example.com"]
```

### 3.3 `apiCall` — GET

```yaml
context:
- name: nsdata
  apiCall:
    urlPath: "/api/v1/namespaces/{{ request.namespace }}"
    jmesPath: "metadata.labels"
```

`urlPath` is a raw Kubernetes API path. Get it right by asking the API server itself:

```console
$ kubectl get --raw "/api/v1/namespaces/payments" | jq '.metadata.labels'
{
  "environment": "prod",
  "kubernetes.io/metadata.name": "payments",
  "team": "payments"
}
```

```console
$ kubectl get --raw "/apis/networking.k8s.io/v1/namespaces/payments/ingresses" | jq '.items | length'
7
```

Path construction, memorised:

| Resource shape | Path |
|---|---|
| Core, namespaced | `/api/v1/namespaces/{ns}/{resource}` |
| Core, cluster-scoped | `/api/v1/{resource}` |
| Grouped, namespaced | `/apis/{group}/{version}/namespaces/{ns}/{resource}` |
| Grouped, cluster-scoped | `/apis/{group}/{version}/{resource}` |
| Label-selected | append `?labelSelector=team%3Dpayments` |
| Field-selected | append `?fieldSelector=spec.nodeName%3Dnode-1` |

`jmesPath` is applied **server-response-side**, and doing the reduction there is a real optimisation: `jmesPath: "items | length(@)"` keeps a 4 MB Pod list from being materialised into the variable namespace and re-serialised for every subsequent expression.

### 3.4 `apiCall` — POST (authorization-aware policy)

Some Kubernetes APIs are write-only: you `create` a review object and read the answer out of its `status`. `SubjectAccessReview` is the canonical case, and it lets a Kyverno policy delegate the "may this user do X?" question to the cluster's own authorizer instead of re-implementing RBAC in JMESPath.

```yaml
context:
- name: sar
  apiCall:
    urlPath: "/apis/authorization.k8s.io/v1/subjectaccessreviews"
    method: POST
    data:
    - key: kind
      value: SubjectAccessReview
    - key: apiVersion
      value: authorization.k8s.io/v1
    - key: spec
      value:
        user: "{{ request.userInfo.username }}"
        groups: "{{ request.userInfo.groups }}"
        resourceAttributes:
          namespace: "{{ request.namespace }}"
          verb: update
          group: ""
          resource: secrets
    jmesPath: "status.allowed"
```

`data[]` is a list of `key`/`value` pairs that Kyverno assembles into the JSON request body. `value` may be a scalar, list, or object, and is fully variable-substituted.

### 3.5 `apiCall` with `service` — leaving the cluster

```yaml
context:
- name: riskScore
  apiCall:
    service:
      url: https://risk-api.platform.svc.cluster.local:8443/v1/score
      caBundle: |
        -----BEGIN CERTIFICATE-----
        MIIBkTCCATegAwIBAgIQKDVeSMPvDQOnrKzMSLmXnjAKBggqhkjOPQQDAjAeMRww
        GgYDVQQDExNwbGF0Zm9ybS1pbnRlcm5hbC1jYTAeFw0yNjAxMDIwMDAwMDBaFw0z
        NjAxMDIwMDAwMDBaMB4xHDAaBgNVBAMTE3BsYXRmb3JtLWludGVybmFsLWNhMFkw
        EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEs0m9k1u5Vh0K0R0cQ3F0m2wZ9x1c1sQ0
        Hn8p4Q8bF2mV8i2p9rQ1s8v0Y5k1H8u2b1p3n5C0q8N4tM6uKKNCMEAwDgYDVR0P
        AQH/BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFDq3S3fWpxvW1Q8h
        3d0Yq3Hq5t4mMAoGCCqGSM49BAMCA0gAMEUCIQCz2Vv8Yk8k9F1a5H2Q4wJ0x8Q6
        Hb3W1s2V0m9Q8vQ0AgIgQ8n1S5m2p0Q3x8bV1a7t9K0Y6c2Q4H8u1p3W5m0V8k=
        -----END CERTIFICATE-----
    method: POST
    data:
    - key: images
      value: "{{ images.containers.*.reference }}"
    jmesPath: "score"
```

Two hard requirements and one design warning:

* `caBundle` is **mandatory** for `service` calls — Kyverno will not skip TLS verification. Paste the PEM chain that signs the endpoint.
* The endpoint must survive being called on the critical path of every matching admission request. Give it a hard client-side budget.
* **Design warning:** `service` turns policy authorship into an outbound-request primitive. Anyone who can create a `ClusterPolicy` can make the Kyverno ServiceAccount issue arbitrary HTTPS requests carrying cluster data. Treat `create/update clusterpolicies` as a privileged verb, gate it behind GitOps review, and consider a NetworkPolicy that restricts Kyverno's egress to a known allowlist.

### 3.6 `globalReference` and `GlobalContextEntry`

A `GlobalContextEntry` (CRD introduced in Kyverno 1.11) moves the fetch **out** of the admission path. Kyverno maintains the data in memory and refreshes it on a timer or via a watch.

```yaml
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: cluster-ingress-hosts
spec:
  apiCall:
    urlPath: "/apis/networking.k8s.io/v1/ingresses"
    refreshInterval: 30s
```

Or the watch-based form, which avoids polling entirely:

```yaml
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: all-namespaces
spec:
  kubernetesResource:
    group: ""
    version: v1
    resource: namespaces
```

Consumed by:

```yaml
context:
- name: takenHosts
  globalReference:
    name: cluster-ingress-hosts
    jmesPath: "items[].spec.rules[].host"
```

The trade-off is explicit and must be stated in the design: **you exchange strong consistency for latency.** With `refreshInterval: 30s`, two Ingresses claiming the same host created 5 seconds apart will both be admitted. For uniqueness constraints that must be exact, use a direct `apiCall` and accept the latency; for advisory checks, use the global entry.

Confirm which API version your cluster serves before writing the manifest:

```console
$ kubectl api-resources --api-group=kyverno.io | grep -i global
globalcontextentries   gctxentry   kyverno.io/v2alpha1   false   GlobalContextEntry
```

### 3.7 `imageRegistry`

```yaml
context:
- name: imageData
  imageRegistry:
    reference: "{{ element }}"
    jmesPath: "configData.config"
```

The returned object contains `registry`, `repository`, `identifier`, `manifest` (the OCI manifest) and `configData` (the image config blob — the thing that holds `User`, `Entrypoint`, `Env`, `ExposedPorts`, `Labels`). For private registries:

```yaml
context:
- name: imageData
  imageRegistry:
    reference: "{{ element }}"
    imageRegistryCredentials:
      allowInsecureRegistry: false
      providers:
      - default
      secrets:
      - regcred-platform          # in the Kyverno namespace
```

This is by far the most expensive context type. Never attach it to a rule that matches broadly without preconditions narrowing it first.

### 3.8 `variable`

Pure computation, no I/O. Use it aggressively: it names intermediate results, provides defaults, and keeps `deny.conditions` readable.

```yaml
context:
- name: replicas
  variable:
    jmesPath: "request.object.spec.replicas"
    default: 1
- name: isProd
  variable:
    value: "{{ nsdata.environment || 'dev' }}"
```

---

## 4. Complete production manifests

### 4.1 RBAC — the prerequisite everyone forgets

Kyverno's controllers run with least privilege. `apiCall` to anything beyond the defaults **fails with a 403 until you grant it**. Since Kyverno 1.10 the controllers are separate Deployments with separate ServiceAccounts, and permissions are granted through **aggregated ClusterRoles**.

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:platform:context-reader
  labels:
    # These labels graft the rules onto Kyverno's own aggregated ClusterRoles.
    # Grant only to the controllers that actually need them.
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
rules:
- apiGroups: [""]
  resources: ["namespaces", "services", "resourcequotas", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:platform:sar-creator
  labels:
    # SubjectAccessReview is only meaningful at admission time — do not grant
    # it to the background or reports controllers.
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
rules:
- apiGroups: ["authorization.k8s.io"]
  resources: ["subjectaccessreviews"]
  verbs: ["create"]
```

Verify the grant landed, using the ServiceAccount identity itself:

```console
$ kubectl apply -f kyverno-context-rbac.yaml
clusterrole.rbac.authorization.k8s.io/kyverno:platform:context-reader created
clusterrole.rbac.authorization.k8s.io/kyverno:platform:sar-creator created

$ kubectl auth can-i list ingresses \
    --as=system:serviceaccount:kyverno:kyverno-admission-controller \
    --all-namespaces
yes

$ kubectl auth can-i create subjectaccessreviews \
    --as=system:serviceaccount:kyverno:kyverno-background-controller
no
```

The second `no` is correct and intentional — least privilege per controller.

### 4.2 Tenant-scoped registry allowlist (ConfigMap + variable + foreach)

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-allowlist
  namespace: kyverno
data:
  # Per-namespace allowlists. GitOps-managed; changing this needs no policy release.
  payments: |
    ["registry.internal.example.com", "ghcr.io"]
  search: |
    ["registry.internal.example.com"]
  # Fallback for namespaces with no explicit entry.
  _default: |
    ["registry.internal.example.com"]
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
  annotations:
    policies.kyverno.io/title: Restrict Image Registries per Tenant
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Every container image must originate from a registry explicitly allowed
      for the workload's namespace. The allowlist is read from a ConfigMap at
      admission time so it can be changed without redeploying policy.
spec:
  validationFailureAction: Enforce
  background: true
  webhookTimeoutSeconds: 10
  failurePolicy: Fail
  rules:
  - name: check-registry
    match:
      any:
      - resources:
          kinds:
          - Pod
    context:
    # 1. Pull the whole dictionary from the informer-backed cache (free).
    - name: allowlistCM
      configMap:
        name: registry-allowlist
        namespace: kyverno
    # 2. Select this namespace's entry, falling back to _default.
    - name: allowedRegistries
      variable:
        jmesPath: >-
          parse_json(
            allowlistCM.data."{{ request.namespace }}"
            || allowlistCM.data._default
          )
        default:
        - registry.internal.example.com
    preconditions:
      all:
      - key: "{{ request.operation || 'BACKGROUND' }}"
        operator: AnyIn
        value:
        - CREATE
        - UPDATE
    validate:
      message: >-
        Image registries {{ images.containers.*.registry | to_string(@) }} are not
        all permitted in namespace {{ request.namespace }}.
        Allowed: {{ allowedRegistries | to_string(@) }}.
      deny:
        conditions:
          all:
          - key: "{{ images.containers.*.registry }}"
            operator: AnyNotIn
            value: "{{ allowedRegistries }}"
```

Note the use of `AnyNotIn` in a **deny** block: deny when *any* registry is outside the list. Getting the polarity right on `deny` is a frequent exam trap — `deny.conditions` fire the failure when they evaluate **true**, the inverse of `pattern`.

Behaviour:

```console
$ kubectl -n payments run web --image=ghcr.io/example/web:1.4.0
pod/web created

$ kubectl -n search run web --image=ghcr.io/example/web:1.4.0
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/search/web was blocked due to the following policies

restrict-image-registries:
  check-registry: 'Image registries ["ghcr.io"] are not all permitted in namespace
    search. Allowed: ["registry.internal.example.com"].'
```

### 4.3 Cluster state via `apiCall`: enforce a LoadBalancer budget

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: limit-loadbalancer-services
  annotations:
    policies.kyverno.io/title: Limit LoadBalancer Services per Namespace
    policies.kyverno.io/category: Cost Control
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Each LoadBalancer Service provisions a billable cloud load balancer.
      This policy counts existing LoadBalancer Services in the namespace via a
      live API call and denies creation beyond the namespace's declared quota,
      which is carried on the namespace as an annotation.
spec:
  validationFailureAction: Enforce
  background: false          # counts are only meaningful at admission time
  failurePolicy: Fail
  webhookTimeoutSeconds: 15
  rules:
  - name: check-lb-count
    match:
      any:
      - resources:
          kinds:
          - Service
    preconditions:
      all:
      - key: "{{ request.operation || 'BACKGROUND' }}"
        operator: Equals
        value: CREATE
      - key: "{{ request.object.spec.type }}"
        operator: Equals
        value: LoadBalancer
    context:
    - name: existingLBs
      apiCall:
        urlPath: "/api/v1/namespaces/{{ request.namespace }}/services"
        jmesPath: "items[?spec.type == 'LoadBalancer'] | length(@)"
    - name: nsObject
      apiCall:
        urlPath: "/api/v1/namespaces/{{ request.namespace }}"
        jmesPath: "metadata.annotations"
    - name: quota
      variable:
        jmesPath: 'to_number(nsObject."platform.example.com/lb-quota" || `2`)'
        default: 2
    validate:
      message: >-
        Namespace {{ request.namespace }} already has {{ existingLBs }} LoadBalancer
        Service(s); its quota is {{ quota }}. Use the shared Ingress controller or
        request a quota increase from the platform team.
      deny:
        conditions:
          all:
          - key: "{{ existingLBs }}"
            operator: GreaterThanOrEquals
            value: "{{ quota }}"
```

Note that `context` is placed **after** `preconditions` in intent: Kyverno evaluates preconditions after loading context, so to actually *skip* the API call for non-LoadBalancer Services you should split the work — the cheap type check belongs in a `match` on `Service` plus a precondition, and the expensive count is only reached when the rule is not skipped. In hot paths, prefer splitting into two rules so the context-bearing rule matches as narrowly as possible.

```console
$ kubectl -n payments get svc --field-selector spec.type=LoadBalancer
NAME       TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
gateway    LoadBalancer   10.96.14.203    203.0.113.41     443:31820/TCP  61d
legacy-lb  LoadBalancer   10.96.201.17    203.0.113.88     80:30991/TCP   14d

$ kubectl -n payments apply -f third-lb.yaml
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Service/payments/analytics was blocked due to the following policies

limit-loadbalancer-services:
  check-lb-count: 'Namespace payments already has 2 LoadBalancer Service(s); its
    quota is 2. Use the shared Ingress controller or request a quota increase from
    the platform team.'
```

### 4.4 Namespace labels — the data that is not in the request

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: prod-requires-pdb-and-probes
  annotations:
    policies.kyverno.io/title: Production Workloads Require Probes
    policies.kyverno.io/category: Reliability
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: probes-in-prod
    match:
      any:
      - resources:
          kinds:
          - Deployment
          - StatefulSet
    context:
    - name: nsLabels
      apiCall:
        urlPath: "/api/v1/namespaces/{{ request.namespace }}"
        jmesPath: "metadata.labels"
    - name: environment
      variable:
        value: "{{ nsLabels.environment || 'dev' }}"
    preconditions:
      all:
      - key: "{{ environment }}"
        operator: Equals
        value: prod
    validate:
      message: >-
        Namespace {{ request.namespace }} is environment={{ environment }};
        every container must declare both readinessProbe and livenessProbe.
      foreach:
      - list: "request.object.spec.template.spec.containers"
        deny:
          conditions:
            any:
            - key: "{{ element.readinessProbe || '' }}"
              operator: Equals
              value: ""
            - key: "{{ element.livenessProbe || '' }}"
              operator: Equals
              value: ""
```

> Kyverno also supports `match.any[].resources.namespaceSelector` for label-based namespace matching, which is evaluated by the *API server* via the webhook's `namespaceSelector` and costs nothing. Prefer it when you only need to *select*; use the `apiCall` when you need the label **value** inside the rule body (in a message, a threshold, a generated object).

### 4.5 Authorization-aware policy with a POST `apiCall`

This rule blocks deletion of resources carrying a `platform.example.com/protected: "true"` label unless the requester genuinely holds cluster-admin-equivalent rights — as judged by the cluster's own authorizer, not by a hardcoded username list.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: protect-critical-resources
  annotations:
    policies.kyverno.io/title: Protect Labelled Resources From Deletion
    policies.kyverno.io/category: Change Management
    policies.kyverno.io/severity: critical
spec:
  validationFailureAction: Enforce
  background: false          # uses request.userInfo — mandatory
  failurePolicy: Fail
  rules:
  - name: block-protected-delete
    match:
      any:
      - resources:
          kinds:
          - ConfigMap
          - Secret
          - Service
          - Deployment
          - StatefulSet
          - PersistentVolumeClaim
    preconditions:
      all:
      - key: "{{ request.operation }}"
        operator: Equals
        value: DELETE
      # On DELETE, request.object is null — read from oldObject.
      - key: "{{ request.oldObject.metadata.labels.\"platform.example.com/protected\" || 'false' }}"
        operator: Equals
        value: "true"
    context:
    # Ask the API server whether this identity may delete namespaces —
    # a proxy for "is genuinely a cluster operator".
    - name: sar
      apiCall:
        urlPath: "/apis/authorization.k8s.io/v1/subjectaccessreviews"
        method: POST
        data:
        - key: kind
          value: SubjectAccessReview
        - key: apiVersion
          value: authorization.k8s.io/v1
        - key: spec
          value:
            user: "{{ request.userInfo.username }}"
            groups: "{{ request.userInfo.groups }}"
            resourceAttributes:
              verb: delete
              group: ""
              resource: namespaces
        jmesPath: "status.allowed"
    validate:
      message: >-
        {{ request.oldObject.kind }}/{{ request.oldObject.metadata.name }} is
        labelled protected. User {{ request.userInfo.username }} is not authorised
        to delete it. Remove the label through the change-management process first.
      deny:
        conditions:
          all:
          - key: "{{ sar }}"
            operator: Equals
            value: false
```

```console
$ kubectl --context=dev-user -n payments delete secret payment-signing-key
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Secret/payments/payment-signing-key was blocked due to the following policies

protect-critical-resources:
  block-protected-delete: 'Secret/payment-signing-key is labelled protected. User
    dana@example.com is not authorised to delete it. Remove the label through the
    change-management process first.'

$ kubectl --context=cluster-admin -n payments delete secret payment-signing-key
secret "payment-signing-key" deleted
```

### 4.6 GlobalContextEntry: Ingress host uniqueness without hammering the API

```yaml
---
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: ingress-hosts
spec:
  apiCall:
    urlPath: "/apis/networking.k8s.io/v1/ingresses"
    refreshInterval: 20s
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: unique-ingress-hosts
  annotations:
    policies.kyverno.io/title: Advisory Ingress Host Uniqueness
    policies.kyverno.io/category: Networking
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Advisory check. Backed by a GlobalContextEntry refreshed every 20s, so two
      conflicting Ingresses created within the refresh window can both be admitted.
      Enforcement of true uniqueness belongs to the ingress controller.
spec:
  validationFailureAction: Audit
  background: true
  rules:
  - name: host-not-taken
    match:
      any:
      - resources:
          kinds:
          - Ingress
    context:
    - name: takenHosts
      globalReference:
        name: ingress-hosts
        # Exclude the object being updated so an in-place edit does not self-conflict.
        jmesPath: >-
          items[?!(metadata.name == '{{ request.object.metadata.name }}'
            && metadata.namespace == '{{ request.namespace }}')]
            .spec.rules[].host
    validate:
      message: >-
        Host(s) {{ request.object.spec.rules[].host | to_string(@) }} are already
        claimed by another Ingress in this cluster.
      deny:
        conditions:
          all:
          - key: "{{ request.object.spec.rules[].host }}"
            operator: AnyIn
            value: "{{ takenHosts || `[]` }}"
```

```console
$ kubectl get gctxentry
NAME            REFRESH   AGE
ingress-hosts   20s       4m11s

$ kubectl describe gctxentry ingress-hosts | tail -6
Status:
  Ready:  True
  Conditions:
    Message:               Global context entry is ready
    Reason:                Succeeded
    Status:                True
    Type:                  Ready
```

### 4.7 `imageRegistry` + `foreach`: reject images whose config runs as root

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: images-must-declare-nonroot-user
  annotations:
    policies.kyverno.io/title: Image Config Must Declare a Non-Root USER
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Inspects the OCI image config blob in the registry. An image whose USER is
      empty or 0 defaults to root even when the Pod omits securityContext, so this
      catches the failure at its source rather than patching every workload.
spec:
  validationFailureAction: Enforce
  background: false          # registry pulls are too expensive for background scans
  webhookTimeoutSeconds: 20
  failurePolicy: Ignore      # a registry outage must not block the cluster
  rules:
  - name: check-image-user
    match:
      any:
      - resources:
          kinds:
          - Pod
    preconditions:
      all:
      - key: "{{ request.operation || 'BACKGROUND' }}"
        operator: AnyIn
        value:
        - CREATE
        - UPDATE
    validate:
      message: "Image config declares a root or unset USER."
      foreach:
      - list: "request.object.spec.containers"
        context:
        - name: imageData
          imageRegistry:
            reference: "{{ element.image }}"
            jmesPath: "configData.config.User || ''"
        deny:
          conditions:
            any:
            - key: "{{ imageData }}"
              operator: AnyIn
              value:
              - ""
              - "0"
              - "root"
```

Two production choices are encoded here and both are deliberate:

* `failurePolicy: Ignore` — an unreachable registry produces an unresolvable context. With `Fail`, that outage becomes a **cluster-wide write outage**. The security posture is weaker; the availability posture is what keeps you employed. Compensate with an `Audit`-mode twin policy plus a `PolicyReport` alert.
* `background: false` — a reports-controller scan of 8,000 Pods would issue 8,000 registry pulls per scan interval.

### 4.8 Mutation and generation driven by variables

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-cost-centre
  annotations:
    policies.kyverno.io/title: Propagate Cost Centre From Namespace
    policies.kyverno.io/category: FinOps
spec:
  background: true
  rules:
  - name: add-cost-centre-label
    match:
      any:
      - resources:
          kinds:
          - Deployment
          - StatefulSet
          - CronJob
    context:
    - name: nsAnnotations
      apiCall:
        urlPath: "/api/v1/namespaces/{{ request.namespace }}"
        jmesPath: "metadata.annotations"
    - name: costCentre
      variable:
        value: '{{ nsAnnotations."finops.example.com/cost-centre" || "unallocated" }}'
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            finops.example.com/cost-centre: "{{ costCentre }}"
        spec:
          template:
            metadata:
              labels:
                finops.example.com/cost-centre: "{{ costCentre }}"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-tenant-netpol
  annotations:
    policies.kyverno.io/title: Generate a Default-Deny NetworkPolicy per Namespace
    policies.kyverno.io/category: Networking
spec:
  background: true
  rules:
  - name: default-deny
    match:
      any:
      - resources:
          kinds:
          - Namespace
    context:
    - name: tenant
      variable:
        value: '{{ request.object.metadata.labels.tenant || "shared" }}'
    preconditions:
      all:
      - key: "{{ request.object.metadata.labels.environment || 'dev' }}"
        operator: AnyIn
        value:
        - prod
        - staging
    generate:
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: default-deny-ingress
      namespace: "{{ request.object.metadata.name }}"
      synchronize: true
      data:
        metadata:
          labels:
            tenant: "{{ tenant }}"
            app.kubernetes.io/managed-by: kyverno
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
```

`synchronize: true` means the background controller reconciles the generated object forever — and it evaluates the same variables in **background** mode, which is exactly why neither rule may reference `request.userInfo`.

---

## 5. JMESPath in Kyverno

Kyverno ships upstream JMESPath plus a large set of custom functions. The authoritative list is the one compiled into *your* binary:

```console
$ kyverno version
Version: v1.13.2
Time: 2026-01-19T09:41:07Z
Git commit ID: 4a1e0c93f2d9f2b6c1c3e2a91f8a0f2f1c7ab340

$ kyverno jp function | head -20
add(any, any) any
base64_decode(string) string
base64_encode(string) string
compare(string, string) number
concat(string, string) string
divide(any, any) any
equal_fold(string, string) bool
image_normalize(string) string
items(object|array, string, string) array[object]
label_match(object, object) bool
lookup(object|array, any) any
modulo(any, any) any
object_from_lists(array[string], array) object
parse_json(string) any
parse_yaml(string) any
path_canonicalize(string) string
pattern_match(string, string) bool
random(string) string
regex_match(string, any) bool
regex_replace_all(string, string|number, string|number) string

$ kyverno jp function | wc -l
57
```

Functions you will reach for repeatedly:

| Function | Use |
|---|---|
| `parse_json(str)` / `parse_yaml(str)` | Turn ConfigMap string values into structures |
| `to_number(str)`, `to_string(any)` | Type coercion in `deny.conditions` and messages |
| `length(@)` | Counting from an `apiCall` result |
| `items(obj, 'k', 'v')` | Convert a map into a list for `foreach` |
| `object_from_lists(keys, vals)` | Inverse of `items` |
| `regex_match(pat, str)` | Naming conventions, image reference shapes |
| `semver_compare(ver, constraint)` | Chart/app version gating |
| `time_since('', a, b)`, `time_after(a, b)` | Exception expiry, certificate freshness |
| `x509_decode(pem)` | Inspect certs inside Secrets |
| `split(str, sep)`, `trim_prefix(str, pre)` | Reference parsing |
| `sum(list)`, `add`, `subtract`, `divide` | Aggregate resource-request budgets |

`kyverno jp query` is the fastest way to iterate on an expression without a cluster round-trip:

```console
$ kubectl get --raw "/api/v1/namespaces/payments/services" > svc.json

$ kyverno jp query -i svc.json "items[?spec.type == 'LoadBalancer'] | length(@)"
2

$ kyverno jp query -i svc.json "items[].metadata.name | sort(@)"
[
  "gateway",
  "legacy-lb",
  "payments-api"
]

$ echo '{"data":{"prod-allowlist":"[\"a.io\",\"b.io\"]"}}' \
    | kyverno jp query 'parse_json(data."prod-allowlist") | length(@)'
2
```

---

## 6. Failure semantics: what happens when a variable does not resolve

This is where most production incidents originate. The chain of behaviour:

| Condition | Result |
|---|---|
| Expression evaluates to `null` and a `default` is set | `default` is used, rule continues |
| Expression evaluates to `null`, no `default`, `||` fallback present | Fallback used |
| Expression evaluates to `null`, nothing else | **Variable substitution error** → rule fails |
| `apiCall` returns 403 / 404 / timeout | Context load error → rule fails |
| Rule fails and `spec.failurePolicy: Fail` | **The API request is rejected** |
| Rule fails and `spec.failurePolicy: Ignore` | Webhook error is swallowed; the request is admitted; an event/log records it |
| Rule fails during background scan | `PolicyReport` result of type `error` |

The design rule that follows: **`failurePolicy: Fail` + external dependency = a new single point of failure for cluster writes.** The matrix you should be able to reason about under exam conditions and in a design review:

| Context source | `failurePolicy: Fail` acceptable? | Rationale |
|---|---|---|
| `configMap` | Yes | In-process cache; failure mode is "ConfigMap deleted", which is your own GitOps error. |
| `apiCall` in-cluster | Usually | If the API server is down, admission is not happening anyway. Watch out for RBAC drift after upgrades. |
| `globalReference` | Yes | In-process cache; add a `default` for the pre-warm window after a controller restart. |
| `imageRegistry` | **No** | Registry outages are common and external. Use `Ignore`. |
| `service` (external) | **No** | Your policy engine must not inherit a third party's SLO. Use `Ignore`. |

Always pair an `Ignore` policy with an `Audit`-mode reporting policy and an alert on `PolicyReport` results with `result: error`, otherwise the control silently stops existing.

---

## 7. Verification and diagnosis

### 7.1 Offline: `kyverno apply` with a values file

Variables that come from admission (`request.userInfo`, `request.operation`) do not exist offline. Mock them.

```yaml
# values.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
spec:
  globalValues:
    request.operation: CREATE
    request.userInfo.username: dana@example.com
  namespaceSelector:
  - name: search
    labels:
      environment: prod
  policies:
  - name: restrict-image-registries
    resources:
    - name: web
      values:
        allowlistCM.data.search: '["registry.internal.example.com"]'
        request.namespace: search
```

```console
$ kyverno apply restrict-image-registries.yaml \
    --resource pod-ghcr.yaml \
    --values-file values.yaml

Applying 1 policy rule(s) to 1 resource(s) with 1 variable file(s)...

policy restrict-image-registries -> resource search/Pod/web failed:
1. check-registry: Image registries ["ghcr.io"] are not all permitted in namespace
   search. Allowed: ["registry.internal.example.com"].

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

### 7.2 Offline against a live cluster: `--cluster`

`--cluster` lets `apiCall` and `configMap` entries resolve for real, using **your** kubeconfig credentials — which is precisely why a policy can pass here and fail in the cluster (you are cluster-admin; Kyverno's ServiceAccount is not).

```console
$ kyverno apply limit-loadbalancer-services.yaml \
    --resource third-lb.yaml \
    --cluster \
    --values-file values.yaml

Applying 1 policy rule(s) to 1 resource(s) with 1 variable file(s)...

policy limit-loadbalancer-services -> resource payments/Service/analytics failed:
1. check-lb-count: Namespace payments already has 2 LoadBalancer Service(s); its
   quota is 2. Use the shared Ingress controller or request a quota increase from
   the platform team.

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

### 7.3 Regression tests: `kyverno test`

```yaml
# .kyverno-test/kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: registry-allowlist-tests
policies:
- ../restrict-image-registries.yaml
resources:
- ../resources/pod-internal.yaml
- ../resources/pod-ghcr.yaml
variables: ../values.yaml
results:
- policy: restrict-image-registries
  rule: check-registry
  resources:
  - web-internal
  kind: Pod
  result: pass
- policy: restrict-image-registries
  rule: check-registry
  resources:
  - web-ghcr
  kind: Pod
  result: fail
```

```console
$ kyverno test .kyverno-test/

Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│───│───────────────────────────│────────────────│───────────────────│────────│
│ # │ POLICY                    │ RULE           │ RESOURCE          │ RESULT │
│───│───────────────────────────│────────────────│───────────────────│────────│
│ 1 │ restrict-image-registries │ check-registry │ Pod/web-internal  │ Pass   │
│ 2 │ restrict-image-registries │ check-registry │ Pod/web-ghcr      │ Pass   │
│───│───────────────────────────│────────────────│───────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

Wire this into CI. Variable-bearing policies are the ones that break silently when a ConfigMap key is renamed.

### 7.4 In-cluster verification

```console
$ kubectl get clusterpolicy restrict-image-registries
NAME                        ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
restrict-image-registries   true        true         Enforce           True    12m   Ready

$ kubectl -n search create deployment web --image=ghcr.io/example/web:1.4.0 --dry-run=server
error: failed to create deployment: admission webhook "validate.kyverno.svc-fail"
denied the request:

resource Pod/search/web-6d9f4c8b7d-* was blocked due to the following policies

restrict-image-registries:
  check-registry: 'Image registries ["ghcr.io"] are not all permitted in namespace
    search. Allowed: ["registry.internal.example.com"].'
```

`--dry-run=server` runs the full admission chain without persisting — the safest way to test an `Enforce` policy in production.

Policy reports carry background-mode results, including context errors:

```console
$ kubectl -n payments get policyreport
NAME                                   KIND         NAME       PASS   FAIL   WARN   ERROR   SKIP   AGE
0f0b8a5b-2a70-4a1f-9a58-1b1d4c0e7a11   Deployment   api        3      0      0      1       0      9m

$ kubectl -n payments get policyreport -o yaml | yq '.items[].results[] | select(.result=="error")'
message: 'failed to load context: failed to fetch data for APICall: ingresses.networking.k8s.io
  is forbidden: User "system:serviceaccount:kyverno:kyverno-reports-controller"
  cannot list resource "ingresses" in API group "networking.k8s.io" at the cluster scope'
policy: unique-ingress-hosts
result: error
rule: host-not-taken
```

That output is the archetypal RBAC failure — note it names the **reports controller**, not the admission controller, which is exactly why the aggregation labels in §4.1 must be applied per controller.

### 7.5 Controller logs

```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=40 | grep -i "context\|variable"
2026-08-13T11:04:22Z  ERROR  engine.context  failed to add resource with dynamic
  client  {"policy": "limit-loadbalancer-services", "rule": "check-lb-count",
  "error": "services is forbidden: User \"system:serviceaccount:kyverno:kyverno-admission-controller\"
  cannot list resource \"services\" in API group \"\" in the namespace \"payments\""}
2026-08-13T11:04:22Z  ERROR  engine  failed to load context  {"kind": "Service",
  "namespace": "payments", "name": "analytics", "policy": "limit-loadbalancer-services",
  "rule": "check-lb-count"}
```

Raise verbosity temporarily when an expression is misbehaving:

```console
$ kubectl -n kyverno set env deploy/kyverno-admission-controller -- -v=4
deployment.apps/kyverno-admission-controller env updated

$ kubectl -n kyverno logs deploy/kyverno-admission-controller -f | grep "substitut"
2026-08-13T11:09:41Z  INFO  engine.variables  substituting variable
  {"variable": "{{ allowedRegistries }}", "value": ["registry.internal.example.com"]}
2026-08-13T11:09:41Z  INFO  engine.variables  substituting variable
  {"variable": "{{ images.containers.*.registry }}", "value": ["ghcr.io"]}
```

Revert it afterwards — `-v=4` is expensive at cluster QPS.

### 7.6 Diagnosis table

| Symptom | Root cause | First command |
|---|---|---|
| `variable substitution failed ... Unknown key` | Field absent on this object; typo; unquoted key with `-` or `.` | `kyverno jp query -i obj.json '<expr>'` |
| `is forbidden: User "system:serviceaccount:kyverno:..."` | Missing aggregated ClusterRole | `kubectl auth can-i <verb> <res> --as=system:serviceaccount:kyverno:<sa>` |
| Policy rejected at creation: `variables ... not supported in background mode` | `request.userInfo` etc. with `background: true` | Set `spec.background: false` |
| Rule silently skipped, no report entry | Precondition evaluated false — often `request.operation` `null` in background | Add `|| 'BACKGROUND'`; check `kubectl describe polr` |
| ConfigMap list comparison never matches | Value is a JSON **string**, not a list | Wrap in `parse_json()` |
| `context deadline exceeded` in webhook | `apiCall`/registry slower than `webhookTimeoutSeconds` | Raise timeout, move to `GlobalContextEntry`, or set `failurePolicy: Ignore` |
| Works with `kyverno apply --cluster`, fails in cluster | You are cluster-admin; the ServiceAccount is not | Compare with `kubectl auth can-i --as=...` |
| Denial message shows literal `{{ … }}` | Placeholder was escaped, or lives in a field that does not substitute | Check `\{{` and §2.2 |
| `GlobalContextEntry` returns stale/empty data | Controller restarted; cache not warm; `refreshInterval` too long | `kubectl describe gctxentry <name>` → `Ready` condition |
| Cluster-wide write outage after a policy change | `failurePolicy: Fail` + external context failed | `kubectl patch clusterpolicy <n> --type=merge -p '{"spec":{"failurePolicy":"Ignore"}}'` |

Emergency break-glass, in order of decreasing blast radius:

```console
# 1. Downgrade a single policy to reporting only
$ kubectl patch clusterpolicy restrict-image-registries --type=merge \
    -p '{"spec":{"validationFailureAction":"Audit"}}'
clusterpolicy.kyverno.io/restrict-image-registries patched

# 2. Stop it failing closed
$ kubectl patch clusterpolicy restrict-image-registries --type=merge \
    -p '{"spec":{"failurePolicy":"Ignore"}}'
clusterpolicy.kyverno.io/restrict-image-registries patched

# 3. Remove the policy entirely — the webhook rule is reconfigured automatically
$ kubectl delete clusterpolicy restrict-image-registries
clusterpolicy.kyverno.io "restrict-image-registries" deleted
```

A narrower alternative to deleting a policy is a `PolicyException`, which carves out specific resources without changing the policy's posture for everyone else.

---

## 8. Performance model you should carry into a design review

| Decision | Effect on admission p99 | Effect on correctness |
|---|---|---|
| Narrow `match` (kinds, `namespaceSelector`, `operations`) | Largest win — the webhook is never invoked | None |
| Put cheap preconditions before expensive rules (split into separate rules) | Large | None |
| `jmesPath` reduction on the `apiCall` itself | Moderate; avoids materialising large lists | None |
| `GlobalContextEntry` instead of `apiCall` | Large; O(1) memory read | Introduces staleness up to `refreshInterval` |
| `background: false` on expensive rules | Removes scan-time load entirely | No `PolicyReport` coverage of existing resources |
| `failurePolicy: Ignore` | None directly; removes the outage coupling | Control becomes best-effort |
| Raising `webhookTimeoutSeconds` | Worsens tail latency for everything matching | Fewer spurious failures |

Two numbers to keep in mind: the Kubernetes webhook timeout ceiling is **30 seconds**, and Kyverno's default is **10**. A rule doing a cold registry pull for six containers can plausibly exceed that. Measure before you ship — do not assume.

---

## 9. Exam-focused summary

* `{{ }}` delimits a JMESPath expression; `\{{` escapes it.
* Variables do **not** work in `match`/`exclude`.
* `context[]` is ordered and loads **before** preconditions; later entries see earlier ones.
* Five context types: `configMap`, `apiCall`, `imageRegistry`, `variable`, `globalReference`.
* `apiCall` supports `urlPath` (in-cluster) or `service` (external, `caBundle` mandatory), and `method: GET|POST` with `data[]`.
* `request.object` is `null` on DELETE — use `request.oldObject`.
* `request.userInfo` / `serviceAccountName` / `request.operation` force `spec.background: false`.
* `||` supplies defaults; `context[].variable.default` does the same declaratively.
* ConfigMap values are strings — `parse_json` / `parse_yaml` before treating them as structures.
* `deny.conditions` fire on **true**; `pattern` passes on match. Opposite polarity.
* Every `apiCall` needs RBAC granted via a ClusterRole labelled `rbac.kyverno.io/aggregate-to-{admission,background,reports}-controller: "true"`.
* `GlobalContextEntry` trades consistency for latency.
* `kyverno jp query` to debug expressions; `--values-file` to mock admission variables; `kyverno test` for CI; `--cluster` resolves context for real but with *your* credentials.

---

## Referencias

- KCA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- Kyverno — Variables — https://kyverno.io/docs/writing-policies/variables/
- Kyverno — External Data Sources (`context`) — https://kyverno.io/docs/writing-policies/external-data-sources/
- Kyverno — Preconditions — https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — JMESPath custom functions — https://kyverno.io/docs/writing-policies/jmespath/
- Kyverno — Validate rules (`deny`, `foreach`, `pattern`) — https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Mutate rules — https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — Generate rules — https://kyverno.io/docs/writing-policies/generate/
- Kyverno — Policy definition, `failurePolicy`, `background`, webhook configuration — https://kyverno.io/docs/writing-policies/policy-settings/
- Kyverno — Exceptions — https://kyverno.io/docs/writing-policies/exceptions/
- Kyverno — CLI (`apply`, `test`, `jp`) — https://kyverno.io/docs/kyverno-cli/
- Kyverno — Customizing permissions / RBAC aggregation — https://kyverno.io/docs/installation/customization/
- Kyverno — Policy Reports — https://kyverno.io/docs/policy-reports/
- Kyverno — Security considerations — https://kyverno.io/docs/security/
- Kyverno — Troubleshooting — https://kyverno.io/docs/troubleshooting/
- Kyverno API reference (`ClusterPolicy`, `GlobalContextEntry`) — https://kyverno.io/docs/api-reference/
- Kyverno source — https://github.com/kyverno/kyverno
- JMESPath specification — https://jmespath.org/specification.html
- Kubernetes — Dynamic Admission Control (webhook timeouts, failure policy) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Authorization: checking API access (`SubjectAccessReview`) — https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — Using RBAC Authorization (aggregated ClusterRoles) — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes API concepts (resource paths) — https://kubernetes.io/docs/reference/using-api/api-concepts/
- OCI Image Specification — image config — https://github.com/opencontainers/image-spec/blob/main/config.md