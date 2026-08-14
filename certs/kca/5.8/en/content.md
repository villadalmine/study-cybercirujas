# 5.8 JSON Patches

> **Domain:** Writing Kyverno Policies · **Exam weight:** 2.91 %
> **Prerequisites:** 5.5 Mutate rules, 5.3 Preconditions, 5.11 JMESPath

---

## 1. Motivation: the architectural problem JSON Patch solves

Every mutating admission controller has to answer one question: *given an object the API server is about to persist, how do I express a change to it?* The naive answer — "send the whole new object" — is unusable in a policy engine, because the policy author has never seen the object. A policy that injects a sidecar into every workload in a 3 000-namespace platform cannot enumerate the 3 000 Deployment specs it will act on. It must express a **delta**.

Kubernetes offers three delta dialects, and Kyverno exposes two of them. The one most platform teams reach for first is **Strategic Merge Patch (SMP)**, exposed by Kyverno as `mutate.patchStrategicMerge`. SMP is declarative, forgiving, and creates missing parent objects for you. It is the right default. It also has four hard failure modes that show up in production, usually at the worst moment:

1. **It cannot delete.** SMP composes; it does not subtract. Removing a `hostPath` volume, an over-permissive `securityContext` field, a deprecated `--insecure-skip-tls-verify` flag from `containers[].args`, or a stale finalizer is not expressible as a merge. The Kubernetes SMP directives (`$patch: delete`, `$patch: replace`) cover the object case narrowly and are hostile to read; they cover the *scalar list element* case (like `args`) not at all.

2. **It cannot address positions.** `spec.containers[].args` is a list of plain strings with no merge key. Under SMP, any patch to `args` replaces the whole list. If you want to change element `2` and leave the rest alone, SMP has no vocabulary for "element 2".

3. **It degrades silently on CRDs.** SMP semantics come from Go struct tags (`patchStrategy:"merge" patchMergeKey:"name"`) compiled into the API server for built-in types. A `cert-manager.io/v1 Certificate` or an `argoproj.io/v1alpha1 Application` has no such metadata, so list handling falls back to *replace*. A policy that "appends a DNS name" to a `Certificate` will, on a CRD, quietly discard every DNS name that was already there. This class of bug does not fail the admission request — it produces a valid object with the wrong contents.

4. **It has no ordering and no conditionals at the patch level.** Merges are unordered. "Only set this if that other field currently equals X" has to move up into preconditions, and "do A, then B, and abort both if the precondition breaks between them" is not expressible at all.

**JSON Patch, RFC 6902**, is the escape hatch for all four. It is an *ordered list of imperative operations* against an object addressed by **JSON Pointer, RFC 6901**. It can remove. It can address `containers/0/args/2`. It knows nothing about Go struct tags, so it behaves identically on a `Pod` and on a `Certificate`. And it carries a `test` operation that makes a patch conditional and atomic — if the `test` fails, the entire patch is discarded.

The price is precision. JSON Patch will not create missing parents, will not tolerate a path that does not exist, and its array indices shift out from under you the moment you remove an element. In Kyverno this is exposed as `mutate.patchesJson6902`.

The production rule of thumb, and the one the exam tests:

> **Additions and field-level defaults → `patchStrategicMerge`. Removals, positional edits, ordered/atomic sequences, and CRDs without patch metadata → `patchesJson6902`.**

---

## 2. RFC 6901: the addressing model

A JSON Pointer is a string of zero or more *reference tokens*, each prefixed by `/`. The empty string `""` addresses the whole document.

```
/spec/template/spec/containers/0/image
│    │        │    │          │ └── the "image" member of that object
│    │        │    │          └──── array index 0 (zero-based, decimal, no leading zeros)
│    │        │    └───────────────  the "containers" member
└────┴────────┴────────────────────  nested object members
```

### 2.1 Escaping — the single most common `patchesJson6902` bug

Because `/` is the separator and `~` starts an escape, both must be encoded inside a token:

| Literal character in the key | Encoded as | Decoding order |
|---|---|---|
| `~` | `~0` | decode `~1` **first**, then `~0` |
| `/` | `~1` | (the reverse order corrupts `~01`) |

Kubernetes annotation and label keys are namespaced with `/`, so **almost every annotation patch needs `~1`**:

| Key you want to touch | JSON Pointer you must write |
|---|---|
| `nginx.ingress.kubernetes.io/proxy-body-size` | `/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size` |
| `app.kubernetes.io/name` (label) | `/metadata/labels/app.kubernetes.io~1name` |
| `kubectl.kubernetes.io/last-applied-configuration` | `/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration` |
| `checksum/config` | `/spec/template/metadata/annotations/checksum~1config` |
| `owner` (no slash) | `/metadata/labels/owner` |

Writing `/metadata/annotations/nginx.ingress.kubernetes.io/proxy-body-size` does not error out with "you forgot to escape". It parses as a **five-token pointer** — `annotations` → `nginx.ingress.kubernetes.io` → `proxy-body-size` — and fails with a *missing path* error that points at the wrong thing. Budget an hour of your life to this one if you do not internalise it now.

### 2.2 The `-` token

Inside an array, the token `-` means *the position after the last element*. It is valid **only as the target of `add`** (RFC 6902 §4.1); `remove`, `replace`, `copy` and `move` against `-` are errors.

```yaml
- op: add
  path: "/spec/containers/-"     # append
  value: { name: sidecar, image: ... }
```

### 2.3 Index bounds

| Pointer | Array of length 3 | Result |
|---|---|---|
| `/list/0` | valid | first element |
| `/list/2` | valid | last element |
| `/list/3` | `add` only | equivalent to append |
| `/list/3` | `remove`, `replace` | **error** — out of range |
| `/list/-` | `add` only | append |
| `/list/01` | any op | **error** — leading zeros are illegal |

---

## 3. RFC 6902: exact operation semantics

Every operation is an object with an `op` member. `path` is a JSON Pointer. `value` carries arbitrary JSON. `from` is a JSON Pointer for `move` and `copy`.

| `op` | Required members | Target must exist? | Semantics | Idempotent? |
|---|---|---|---|---|
| `add` | `path`, `value` | **parent** must exist | Object member: create **or replace**. Array index: **insert**, shifting later elements right. `-`: append. | Object member: yes. Array: **no** |
| `remove` | `path` | **yes** | Delete member / delete element and shift left | **No** — second run errors |
| `replace` | `path`, `value` | **yes** | Equivalent to `remove` then `add`; fails if absent | Yes |
| `move` | `from`, `path` | **both** | `remove` from `from`, `add` at `path`. `from` must not be a proper prefix of `path` | No |
| `copy` | `from`, `path` | `from` yes | `add` at `path` a copy of `from`'s value | Object: yes. Array: no |
| `test` | `path`, `value` | **yes** | Deep JSON equality. **Failure aborts the entire patch.** | Yes (pure) |

### 3.1 Atomicity

RFC 6902 §5: *"if a normative requirement is violated by a JSON Patch document, or if an operation is not successful, evaluation of the JSON Patch document SHOULD terminate and application of the entire patch document SHALL NOT be deemed successful."*

This is the property that makes `test` useful. A patch is a transaction: either every operation lands or none does. There is no partial mutation.

### 3.2 `add` is not "add"

The single most misread line in the RFC. On an **object member**, `add` is upsert — if the member exists, its value is *overwritten*:

```jsonc
// document
{ "metadata": { "annotations": { "team": "payments", "cost-center": "4412" } } }

// patch
[ { "op": "add", "path": "/metadata/annotations", "value": { "team": "sre" } } ]

// result — cost-center is GONE
{ "metadata": { "annotations": { "team": "sre" } } }
```

On an **array index**, `add` is insert, not overwrite:

```jsonc
// document
{ "args": ["--v=2", "--leader-elect"] }

// patch
[ { "op": "add", "path": "/args/0", "value": "--config=/etc/app.yaml" } ]

// result — nothing was replaced, everything shifted
{ "args": ["--config=/etc/app.yaml", "--v=2", "--leader-elect"] }
```

### 3.3 `test` deep-equality rules

`test` compares JSON values structurally, not textually:

| Comparison | Result |
|---|---|
| `3` vs `3.0` | equal (same numeric value) |
| `"3"` vs `3` | **not** equal (type differs) |
| `{"a":1,"b":2}` vs `{"b":2,"a":1}` | equal (object members are unordered) |
| `[1,2]` vs `[2,1]` | **not** equal (arrays are ordered) |
| `null` vs member absent | **not** equal — `test` on an absent path is an *error*, not a false |

That last row matters: `test` cannot express "this field is absent". For absence checks in Kyverno, use a **precondition**, not a `test` op — see §7.

---

## 4. The three Kubernetes patch dialects side by side

| | JSON Patch (RFC 6902) | JSON Merge Patch (RFC 7386) | Strategic Merge Patch |
|---|---|---|---|
| `kubectl patch --type=` | `json` | `merge` | `strategic` (default) |
| Content-Type | `application/json-patch+json` | `application/merge-patch+json` | `application/strategic-merge-patch+json` |
| Standard | IETF RFC 6902 | IETF RFC 7386 | Kubernetes-specific |
| Shape | ordered array of ops | a partial document | a partial document + directives |
| Delete a field | `op: remove` | set to `null` | `$patch: delete` / value `null` |
| List handling | positional index | **replaces the whole list** | merge by `patchMergeKey` when the type declares one, else replace |
| Works on CRDs | **yes, identically** | yes | **degrades to merge-patch list semantics** |
| Creates missing parents | **no** | yes | yes |
| Conditional | `test` op | no | Kyverno anchors only |
| Ordered | **yes** | n/a | n/a |
| Works on `list` (non-resource) endpoints | yes | yes | no |
| Kyverno field | `mutate.patchesJson6902` | — | `mutate.patchStrategicMerge` |

A concrete demonstration of row "List handling", against `spec.template.spec.containers` (which *does* declare `patchMergeKey: name`) versus a CRD list (which does not):

```console
$ kubectl patch deployment web --type=strategic \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","image":"web:2.1"}]}}}}'
deployment.apps/web patched
# → only the "app" container changed; the "sidecar" container is untouched.

$ kubectl patch certificate api-tls --type=merge \
    -p '{"spec":{"dnsNames":["api.example.com"]}}'
certificate.cert-manager.io/api-tls patched

$ kubectl get certificate api-tls -o jsonpath='{.spec.dnsNames}'
["api.example.com"]
# → the four other SANs that were in the list are gone. No error was raised.
```

The RFC 6902 form of the same intent is safe because it is explicit about position:

```console
$ kubectl patch certificate api-tls --type=json \
    -p '[{"op":"add","path":"/spec/dnsNames/-","value":"api.example.com"}]'
certificate.cert-manager.io/api-tls patched

$ kubectl get certificate api-tls -o jsonpath='{.spec.dnsNames}'
["api.internal","api-canary.example.com","api.example.com"]
```

### 4.1 Kyverno's two mutate dialects, decision table

| Requirement | `patchStrategicMerge` | `patchesJson6902` | Recommendation |
|---|---|---|---|
| Add an annotation / label | ✅ creates `metadata.annotations` if absent | ⚠️ fails if the map is absent | **SMP** |
| Set a container `resources` default | ✅ merges by container `name` | ⚠️ needs the index | **SMP** |
| Add a container to `containers` | ✅ merges by `name`, idempotent | ⚠️ `add /…/-` duplicates on reinvocation | **SMP** |
| Remove one element of `args` / `command` | ❌ not expressible | ✅ `op: remove` | **JSON Patch** |
| Remove a volume / toleration by predicate | ⚠️ anchor gymnastics | ✅ | **JSON Patch** |
| Reorder `initContainers` | ❌ | ✅ `op: move` | **JSON Patch** |
| Change one element of a keyless list | ❌ replaces the list | ✅ index-addressed | **JSON Patch** |
| Mutate a CRD's list field | ❌ replaces the list | ✅ | **JSON Patch** |
| Compare-and-swap (optimistic concurrency) | ❌ | ✅ `op: test` | **JSON Patch** |
| Two changes that must land together or not at all | ❌ | ✅ atomicity | **JSON Patch** |
| Conditional on a *value* elsewhere in the object | ✅ `()` conditional anchor | ✅ preconditions | either |
| Add only when absent | ✅ `+()` anchor | ⚠️ precondition required | **SMP** |
| Readability / reviewability | ✅ high | ❌ low | **SMP** |
| Auto-gen for Pod controllers | ✅ mature | ⚠️ verify generated paths | **SMP** |

Kyverno's SMP anchors, for the comparison to be complete:

| Anchor | Name | Valid in |
|---|---|---|
| `()` | Conditional | validate, mutate |
| `^()` | Existence (at least one array element) | validate |
| `=()` | Equality / key must exist | validate |
| `X()` | Negation | validate |
| `+()` | **Add-if-not-present** | mutate |
| `<()` | Global | validate |

---

## 5. `patchesJson6902` in Kyverno: syntax and mechanics

### 5.1 It is a *string*, not a list

This is the second most common authoring error. In the Kyverno CRD schema, `mutate.patchesJson6902` is typed `string`, holding a YAML (or JSON) array. It must be a YAML block scalar:

```yaml
mutate:
  patchesJson6902: |-        # ← block scalar. The content is a STRING.
    - op: add
      path: "/spec/containers/-"
      value:
        name: otel-agent
        image: otel/opentelemetry-collector-contrib:0.104.0
```

Writing it as a native YAML sequence:

```yaml
mutate:
  patchesJson6902:           # ← WRONG: this is a list, not a string
    - op: add
      path: "/spec/containers/-"
```

is rejected by the API server at policy-admission time:

```console
$ kubectl apply -f inject-sidecar.yaml
The ClusterPolicy "inject-otel-agent" is invalid: spec.rules[0].mutate.patchesJson6902:
Invalid value: "array": spec.rules[0].mutate.patchesJson6902 in body must be of type string: "array"
```

### 5.2 The document JSON Patch is applied to

Kyverno applies the patch to the **entire admitted object**, not to a fragment. Paths are therefore absolute from the object root:

- Matching `Pod` → `/spec/containers/0/image`
- Matching `Deployment` → `/spec/template/spec/containers/0/image`
- Matching `CronJob` → `/spec/jobTemplate/spec/template/spec/containers/0/image`

For `mutate` rules (admission), the document is `request.object` after any earlier rule in the same policy has already mutated it — rules within a policy apply **in declaration order**, each seeing the output of the previous one.

### 5.3 Variables

Kyverno substitutes `{{ … }}` JMESPath expressions in both `path` and `value` **before** the patch is parsed as JSON. Two consequences:

- A variable that expands to a JSON array or object is inserted as structured JSON when it is the *entire* value (no surrounding quotes). Quote it and you get a string.
- A variable that fails to resolve leaves the patch document syntactically broken, which surfaces as a JSON parse error rather than a "variable not found" error, unless the rule is written with `failurePolicy`/preconditions to skip cleanly.

```yaml
patchesJson6902: |-
  - op: replace
    path: "/spec/volumes"
    value: {{ request.object.spec.volumes[?!contains(keys(@), 'hostPath')] }}   # structured
  - op: add
    path: "/metadata/annotations/platform.example.com~1mutated-by"
    value: "{{ request.uid }}"                                                   # string
```

### 5.4 Full rule anatomy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: example
spec:
  rules:
    - name: example-rule
      match: { … }              # selection            (5.2)
      exclude: { … }            # de-selection         (5.2)
      preconditions: { … }      # cheap, clean SKIP    (5.3)
      context: [ … ]            # external data        (5.9)
      mutate:
        patchesJson6902: |-     # ordered, atomic ops  (this topic)
          - op: …
```

Preconditions gate the rule; the patch executes only if they pass. **A false precondition produces `skip`; a failed `test` op produces `error`.** Use the former for control flow and the latter only for genuine compare-and-swap invariants.

---

## 6. Production recipe A — remove a forbidden container flag

**Problem.** A platform-wide audit found workloads running `kube-rbac-proxy` and various operators with `--insecure-skip-tls-verify` or `--tls-min-version=VersionTLS10` in `args`. `args` is `[]string` with no merge key: SMP cannot touch a single element. You need a surgical removal that leaves every other flag intact.

The index-based approach is a trap — removing element 1 renumbers everything after it, so a patch that removes indices `[1, 3]` in ascending order actually removes the original elements 1 and 4. The robust technique is **rebuild the list with a JMESPath filter and `replace` it atomically**. One operation, index-safe, idempotent, and it does the right thing when zero or many elements match.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: strip-insecure-tls-flags
  annotations:
    policies.kyverno.io/title: Strip Insecure TLS Flags
    policies.kyverno.io/category: Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Removes arguments that disable or downgrade TLS verification from every
      container and initContainer. Uses RFC 6902 because args is a keyless
      list of strings and Strategic Merge Patch can only replace it wholesale.
spec:
  background: false
  rules:
    - name: strip-args-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          # Only act when at least one container actually carries a banned flag.
          # Without this the rule would rewrite /spec/containers on every Pod
          # in the cluster, churning the object for no reason.
          - key: |-
              {{ request.object.spec.containers[?args] 
                 | length(@[?length(args[?starts_with(@, '--insecure-skip-tls-verify')
                                       || starts_with(@, '--tls-min-version=VersionTLS10')
                                       || starts_with(@, '--tls-min-version=VersionTLS11')]) > `0`]) }}
            operator: GreaterThan
            value: 0
      mutate:
        foreach:
          - list: "request.object.spec.containers"
            # Skip containers that have nothing to strip: a no-op replace would
            # still count as a mutation and would still churn the object.
            preconditions:
              all:
                - key: |-
                    {{ length(element.args[?starts_with(@, '--insecure-skip-tls-verify')
                                          || starts_with(@, '--tls-min-version=VersionTLS10')
                                          || starts_with(@, '--tls-min-version=VersionTLS11')]) }}
                  operator: GreaterThan
                  value: 0
            patchesJson6902: |-
              - op: replace
                path: "/spec/containers/{{ elementIndex }}/args"
                value: {{ element.args[?!(starts_with(@, '--insecure-skip-tls-verify')
                                       || starts_with(@, '--tls-min-version=VersionTLS10')
                                       || starts_with(@, '--tls-min-version=VersionTLS11'))] }}
```

`foreach` binds two variables per iteration: `{{ element }}` (the list item) and `{{ elementIndex }}` (its zero-based position in the **original** list). Because every iteration issues a `replace` at a fixed index — never a `remove` — indices stay stable across the whole loop. This is the pattern to reach for whenever you are tempted to remove list elements by index.

**Verification with the CLI, before the policy ever reaches a cluster:**

`resource.yaml`
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: metrics-proxy
  namespace: observability
spec:
  containers:
    - name: kube-rbac-proxy
      image: quay.io/brancz/kube-rbac-proxy:v0.18.0
      args:
        - "--secure-listen-address=0.0.0.0:8443"
        - "--insecure-skip-tls-verify=true"
        - "--upstream=http://127.0.0.1:8080/"
        - "--tls-min-version=VersionTLS10"
        - "--logtostderr=true"
    - name: exporter
      image: prom/node-exporter:v1.8.2
      args:
        - "--path.rootfs=/host"
```

```console
$ kyverno apply strip-insecure-tls-flags.yaml --resource resource.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy strip-insecure-tls-flags applied to observability/Pod/metrics-proxy:
apiVersion: v1
kind: Pod
metadata:
  annotations:
    policies.kyverno.io/last-applied-patches: |
      strip-args-containers.strip-insecure-tls-flags.kyverno.io: replaced /spec/containers/0/args
  name: metrics-proxy
  namespace: observability
spec:
  containers:
  - args:
    - --secure-listen-address=0.0.0.0:8443
    - --upstream=http://127.0.0.1:8080/
    - --logtostderr=true
    image: quay.io/brancz/kube-rbac-proxy:v0.18.0
    name: kube-rbac-proxy
  - args:
    - --path.rootfs=/host
    image: prom/node-exporter:v1.8.2
    name: exporter
---

pass: 1, fail: 0, warn: 0, error: 0, skip: 0
```

Two things to read off that output. The `exporter` container was **not** rewritten — its inner precondition was false, so `foreach` skipped that iteration. And Kyverno stamped `policies.kyverno.io/last-applied-patches`, which is your primary in-cluster forensic signal (§11).

---

## 7. Production recipe B — idempotent sidecar injection

**Problem.** Inject an OpenTelemetry agent into opted-in workloads. The obvious patch is `add /spec/containers/-`. It is also the classic outage:

> Kubernetes mutating webhooks may be **re-invoked**. When the API server has more than one mutating webhook and one of them changes the object, webhooks whose configuration declares `reinvocationPolicy: IfNeeded` are called again in a second pass. Kyverno's resource mutating webhook uses `IfNeeded`, so **a `patchesJson6902` rule can execute more than once against the same admission request**, and `add /list/-` is not idempotent. The result is two identical sidecars, a port collision, and a CrashLoopBackOff that only reproduces on clusters that happen to have a second mutating webhook installed.

Confirm the reinvocation setting on your cluster:

```console
$ kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.reinvocationPolicy}{"\n"}{end}'
mutate.kyverno.svc-fail	IfNeeded
mutate.kyverno.svc-ignore	IfNeeded
```

The fix is an **absence precondition**. A `test` op cannot express this — `test` on a path that does not exist is an error, and there is no pointer that means "no element whose `name` is `otel-agent`".

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-otel-agent
  annotations:
    policies.kyverno.io/title: Inject OpenTelemetry Agent
    policies.kyverno.io/category: Observability
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
spec:
  background: false
  rules:
    - name: inject-agent-container
      match:
        any:
          - resources:
              kinds:
                - Pod
              selector:
                matchLabels:
                  observability.example.com/otel: "enabled"
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      preconditions:
        all:
          # Idempotency guard. Survives webhook reinvocation and re-admission
          # of an already-mutated Pod template.
          - key: "{{ request.object.spec.containers[?name=='otel-agent'] | length(@) }}"
            operator: Equals
            value: 0
          # A JSON Patch cannot create a missing parent. /spec/containers is
          # required by the Pod schema, so it is always present — but assert it
          # rather than assume it, because this same rule shape gets copied
          # onto CRDs where the parent really can be absent.
          - key: "{{ request.object.spec.containers | length(@) }}"
            operator: GreaterThan
            value: 0
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/containers/-"
            value:
              name: otel-agent
              image: otel/opentelemetry-collector-contrib:0.104.0
              imagePullPolicy: IfNotPresent
              args:
                - "--config=/conf/otel-agent-config.yaml"
              env:
                - name: OTEL_RESOURCE_ATTRIBUTES
                  value: "k8s.namespace.name={{ request.namespace }},k8s.pod.name={{ request.object.metadata.name || 'generated' }}"
                - name: GOMEMLIMIT
                  value: "160MiB"
              ports:
                - name: otlp-grpc
                  containerPort: 4317
                  protocol: TCP
                - name: otlp-http
                  containerPort: 4318
                  protocol: TCP
              resources:
                requests:
                  cpu: 50m
                  memory: 96Mi
                limits:
                  memory: 200Mi
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                runAsNonRoot: true
                runAsUser: 65534
                capabilities:
                  drop: ["ALL"]
                seccompProfile:
                  type: RuntimeDefault
              volumeMounts:
                - name: otel-agent-config
                  mountPath: /conf
                  readOnly: true
              livenessProbe:
                httpGet:
                  path: /
                  port: 13133
                initialDelaySeconds: 5
              readinessProbe:
                httpGet:
                  path: /
                  port: 13133
                initialDelaySeconds: 5
          - op: add
            path: "/spec/volumes/-"
            value:
              name: otel-agent-config
              configMap:
                name: otel-agent-config
                defaultMode: 420
```

⚠️ **The second operation is a latent failure.** `/spec/volumes` is optional on a Pod. If the Pod has no volumes at all, the member is absent and `add /spec/volumes/-` fails with *doc is missing path* — and because RFC 6902 is atomic, **the sidecar injection is rolled back too**. Two correct fixes:

**Fix 1 — make the parent unconditional with a preceding `patchStrategicMerge` rule** (SMP creates missing parents; JSON Patch does not):

```yaml
    - name: ensure-volumes-exists
      match:
        any:
          - resources:
              kinds: [Pod]
              selector:
                matchLabels:
                  observability.example.com/otel: "enabled"
      mutate:
        patchStrategicMerge:
          spec:
            +(volumes): []          # add-if-not-present anchor
```

Declare this rule **before** `inject-agent-container`; rules run top-to-bottom and the second sees the first's output.

**Fix 2 — branch the patch on a precondition**, keeping everything in one rule pair:

```yaml
      preconditions:
        all:
          - key: "{{ request.object.spec.volumes || `[]` | length(@) }}"
            operator: Equals
            value: 0
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/volumes"
            value:
              - name: otel-agent-config
                configMap: { name: otel-agent-config, defaultMode: 420 }
```

Fix 1 is preferred: fewer rules to keep in sync, and the intent is legible in review.

---

## 8. Production recipe C — annotations, and the `add`-wipes-the-map trap

Because `add` on an object member *replaces* it (§3.2), the "obvious" way to make an annotation patch safe is catastrophic:

```yaml
# NEVER DO THIS
patchesJson6902: |-
  - op: add
    path: "/metadata/annotations"      # ← destroys every existing annotation
    value: {}
  - op: add
    path: "/metadata/annotations/example.com~1owner"
    value: "platform-team"
```

On a Pod created by a Deployment this deletes `kubectl.kubernetes.io/restartedAt`, checksum annotations that drive rollouts, `cni.projectcalico.org/*` state, and anything a prior webhook wrote. It is a data-loss patch with a clean exit code.

| Approach | Safe when annotations absent? | Preserves existing? | Verdict |
|---|---|---|---|
| `patchStrategicMerge` on `metadata.annotations` | ✅ creates the map | ✅ | **Use this** |
| JSON Patch `add /metadata/annotations` then the key | ✅ | ❌ **wipes** | Never |
| JSON Patch single `add /metadata/annotations/key~1x` | ❌ errors if map absent | ✅ | Only behind a precondition |
| Two rules: SMP `+(annotations): {}` then JSON Patch | ✅ | ✅ | Acceptable, verbose |

The legitimate case for JSON Patch on annotations is **removal**, which SMP cannot do:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sanitize-ingress-annotations
  annotations:
    policies.kyverno.io/title: Remove Snippet Annotations from Ingress
    policies.kyverno.io/category: Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/description: >-
      ingress-nginx configuration-snippet and server-snippet annotations allow
      arbitrary nginx configuration and have been the vector for several
      published CVEs. Strip them at admission rather than rejecting the Ingress,
      so that GitOps reconciliation does not loop on a permanently failing sync.
spec:
  background: false
  rules:
    - name: strip-configuration-snippet
      match:
        any:
          - resources:
              kinds:
                - networking.k8s.io/v1/Ingress
      preconditions:
        any:
          - key: "nginx.ingress.kubernetes.io/configuration-snippet"
            operator: AnyIn
            value: "{{ request.object.metadata.annotations || `{}` | keys(@) }}"
      mutate:
        patchesJson6902: |-
          - op: remove
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1configuration-snippet"

    - name: strip-server-snippet
      match:
        any:
          - resources:
              kinds:
                - networking.k8s.io/v1/Ingress
      preconditions:
        any:
          - key: "nginx.ingress.kubernetes.io/server-snippet"
            operator: AnyIn
            value: "{{ request.object.metadata.annotations || `{}` | keys(@) }}"
      mutate:
        patchesJson6902: |-
          - op: remove
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1server-snippet"
```

Two separate rules, not one patch with two `remove` ops — because atomicity works against you here. A single patch removing both would fail entirely on an Ingress that carries only one of the two, and RFC 6902 would roll back the removal that *did* apply.

```console
$ kubectl apply -f evil-ingress.yaml
ingress.networking.k8s.io/shop created

$ kubectl get ingress shop -o jsonpath='{.metadata.annotations}' | jq
{
  "nginx.ingress.kubernetes.io/rewrite-target": "/",
  "policies.kyverno.io/last-applied-patches": "strip-configuration-snippet.sanitize-ingress-annotations.kyverno.io: removed /metadata/annotations/nginx.ingress.kubernetes.io~1configuration-snippet\n"
}
```

---

## 9. Production recipe D — `mutate` on existing resources

`patchesJson6902` is not limited to admission. With `mutate.targets`, Kyverno's **background controller** patches resources that already exist, triggered by a change to some other object. This is where JSON Patch earns its keep: background mutation runs repeatedly, so idempotency and `test`-guarded compare-and-swap become load-bearing.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-ingress-body-size
  annotations:
    policies.kyverno.io/title: Propagate proxy-body-size to Existing Ingresses
    policies.kyverno.io/category: Platform
    policies.kyverno.io/subject: Ingress, ConfigMap
spec:
  mutateExistingOnPolicyUpdate: true
  rules:
    - name: patch-existing-ingresses
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
              names:
                - ingress-tuning
              namespaces:
                - platform
      mutate:
        targets:
          - apiVersion: networking.k8s.io/v1
            kind: Ingress
            namespace: "*"
            selector:
              matchLabels:
                platform.example.com/managed: "true"
        patchesJson6902: |-
          - op: add
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size"
            value: "{{ request.object.data.bodySize }}"
```

Background mutation runs under the **background controller's** service account, which by default cannot touch Ingresses. Grant it with an aggregating ClusterRole — Kyverno's roles aggregate on a label, so you never edit Kyverno's own RBAC:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:mutate-ingresses
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch
      - update
      - patch
```

Diagnosing the missing-RBAC case, which is the single most common `mutateExisting` failure:

```console
$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=40 | grep -i forbidden
E0814 09:21:04.118  mutate  failed to update target resource
  {"policy":"propagate-ingress-body-size","rule":"patch-existing-ingresses",
   "target":"networking.k8s.io/v1/Ingress/shop/shop",
   "error":"ingresses.networking.k8s.io \"shop\" is forbidden: User
   \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot patch
   resource \"ingresses\" in API group \"networking.k8s.io\" in the namespace \"shop\""}

$ kubectl auth can-i patch ingresses.networking.k8s.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n shop
no

# after applying the aggregating ClusterRole (aggregation is not instantaneous —
# the controller-manager recomputes the aggregate role within a few seconds)
$ kubectl auth can-i patch ingresses.networking.k8s.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n shop
yes
```

---

## 10. Auto-gen and Pod controllers

Kyverno's **auto-gen** feature clones a `Pod` rule into equivalent rules for Deployment, StatefulSet, DaemonSet, Job, CronJob and ReplicaSet, so that a violation is caught at the controller rather than only on the Pod the controller creates. For `patchStrategicMerge` this is a mechanical re-nesting of the patch under `spec.template`. For `patchesJson6902` it means **rewriting JSON Pointer prefixes**, and that is a place to verify rather than assume.

Control it explicitly:

```yaml
metadata:
  annotations:
    pod-policies.kyverno.io/autogen-controllers: "Deployment,StatefulSet,DaemonSet"
    # or, to opt out entirely:
    # pod-policies.kyverno.io/autogen-controllers: "none"
```

Inspect what Kyverno actually generated — the generated rules are written back into the policy's `status`/`spec` and are visible on the live object:

```console
$ kubectl get clusterpolicy inject-otel-agent -o yaml | grep -A4 'name: autogen'
      name: autogen-inject-agent-container
      match:
        any:
        - resources:
            kinds:
            - Deployment
--
      name: autogen-cronjob-inject-agent-container
      match:
        any:
        - resources:
            kinds:
            - CronJob

$ kubectl get clusterpolicy inject-otel-agent -o jsonpath='{.spec.rules[?(@.name=="autogen-inject-agent-container")].mutate.patchesJson6902}'
- op: add
  path: "/spec/template/spec/containers/-"
  value:
    name: otel-agent
    ...
```

| Symptom | Cause | Fix |
|---|---|---|
| Autogen rule errors with *missing path* on Deployments | Path prefix not rewritten as expected for your Kyverno version | Write the controller rules explicitly, set `autogen-controllers: "none"` |
| Autogen precondition still reads `request.object.spec.containers` | Preconditions are rewritten too — verify the generated JMESPath | Inspect the generated rule; write explicit rules if it does not match |
| Sidecar appears twice on Deployment-owned Pods | Both the autogen Deployment rule and the Pod rule fired | The idempotency precondition (§7) makes the Pod-level rule a no-op |

**Rule of thumb:** if a `patchesJson6902` rule matters for correctness, disable autogen and author each controller kind explicitly. The extra 30 lines buy you a policy whose behaviour you can read directly instead of inferring.

---

## 11. Verification

### 11.1 Ladder of confidence

| Question | Tool | Cluster required? |
|---|---|---|
| Is the patch document syntactically valid JSON/YAML? | `kubectl apply` of the policy (CRD schema validation) | policy only |
| Does the patch apply to *this* resource? | `kyverno apply -p policy.yaml --resource r.yaml` | no |
| Is the mutated output exactly what I expect, byte for byte? | `kyverno test` with `patchedResources` | no |
| Does it apply in the real admission chain, with other webhooks? | `kubectl apply --dry-run=server -o yaml` | yes |
| Did it apply in production? | `policies.kyverno.io/last-applied-patches` annotation | yes |
| Did it *fail* in production? | admission-controller logs, Events, PolicyReports | yes |

### 11.2 `kyverno test` — the regression harness

Pin the exact expected output so a policy edit cannot silently change the mutation. Directory layout:

```
policies/inject-otel-agent/
├── policy.yaml
├── resource.yaml
├── patched.yaml
└── kyverno-test.yaml
```

`kyverno-test.yaml`
```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: inject-otel-agent
policies:
  - policy.yaml
resources:
  - resource.yaml
results:
  - policy: inject-otel-agent
    rule: inject-agent-container
    kind: Pod
    resources:
      - api-server
    patchedResources: patched.yaml
    result: pass
  - policy: inject-otel-agent
    rule: inject-agent-container
    kind: Pod
    resources:
      - already-injected
    result: skip
```

```console
$ kyverno test policies/inject-otel-agent/

Loading test  ( policies/inject-otel-agent/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│───│─────────────────────│──────────────────────────│───────────────────────│────────│
│ # │ POLICY              │ RULE                     │ RESOURCE              │ RESULT │
│───│─────────────────────│──────────────────────────│───────────────────────│────────│
│ 1 │ inject-otel-agent   │ inject-agent-container   │ Pod/api-server        │ Pass   │
│ 2 │ inject-otel-agent   │ inject-agent-container   │ Pod/already-injected  │ Pass   │
│───│─────────────────────│──────────────────────────│───────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

When the produced object drifts from `patched.yaml`, the CLI prints the diff and exits non-zero — which is exactly what you want wired into CI:

```console
$ kyverno test policies/inject-otel-agent/
...
│ 1 │ inject-otel-agent │ inject-agent-container │ Pod/api-server │ Fail │
...
Test Summary: 1 tests passed and 1 tests failed

Aggregated Failed Test Cases : 
│ 1 │ inject-otel-agent │ inject-agent-container │ Pod/api-server │ Fail │
patched resource diff:
   spec.containers[1].resources.limits.memory:
-    200Mi
+    256Mi

$ echo $?
1
```

### 11.3 Server-side dry run — the whole admission chain

`kyverno apply` evaluates one policy in isolation. Production behaviour is the *composition* of every mutating webhook, in the API server's order, with reinvocation. Only the API server can show you that:

```console
$ kubectl apply -f pod.yaml --dry-run=server -o yaml \
  | yq '.spec.containers[].name'
api
otel-agent
istio-proxy

$ diff <(yq -P 'sort_keys(..)' pod.yaml) \
       <(kubectl apply -f pod.yaml --dry-run=server -o yaml | yq -P 'sort_keys(..)') \
  | head -30
```

Server-side dry run runs admission plugins and webhooks and discards the object; Kyverno honours `dryRun` and does not create policy reports for it.

### 11.4 In-cluster evidence

```console
$ kubectl get pod api-server-7d9f5c8b4-x2klm \
    -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'
inject-agent-container.inject-otel-agent.kyverno.io: added /spec/containers/1
strip-args-containers.strip-insecure-tls-flags.kyverno.io: replaced /spec/containers/0/args

$ kubectl get events -n observability --field-selector reason=PolicyApplied \
    --sort-by=.lastTimestamp -o wide | tail -3
LAST SEEN   TYPE     REASON          OBJECT                  MESSAGE
12s         Normal   PolicyApplied   pod/api-server-x2klm    ClusterPolicy inject-otel-agent: rule inject-agent-container applied

$ kubectl get events -A --field-selector reason=PolicyError --sort-by=.lastTimestamp | tail -5
```

---

## 12. Failure diagnosis

### 12.1 Error-string decoder

The patch engine underneath Kyverno and the API server is a straight RFC 6902 implementation, so both surface nearly the same strings. Representative messages and their real cause:

| Message | Root cause | Fix |
|---|---|---|
| `add operation does not apply: doc is missing path: "/spec/volumes"` | Parent object/array absent. JSON Patch never creates parents. | Precede with an SMP `+(volumes): []` rule, or branch on a precondition |
| `remove operation does not apply: doc is missing key: hostNetwork` | Removing an optional field that this object does not have | Guard the rule with a precondition on the key's presence; do **not** use `test` |
| `replace operation does not apply: doc is missing key: /spec/replicas` | `replace` requires the target to exist | Use `add` (upsert on object members) or gate on a precondition |
| `jsonpatch test operation does not apply` / `testing value /spec/replicas failed` | `test` compared unequal, or the path was absent | Intentional CAS → retry. Unintentional → you wanted a precondition |
| `add operation does not apply: doc is missing path: "/metadata/annotations/foo.io/bar"` | Unescaped `/` in an annotation key | `~1` (§2.1) |
| `error in JSON patch: invalid character '{' looking for beginning of object key string` | A `{{ }}` variable did not resolve and was left in the document | Fix the JMESPath; add a precondition so the rule skips when the source is absent |
| `spec.rules[0].mutate.patchesJson6902 in body must be of type string: "array"` | Wrote a YAML list instead of a block scalar | `patchesJson6902: \|-` (§5.1) |
| `Index out of bounds` / `Unable to access invalid index: 3` | Index-based op after an earlier `remove` shifted the array | Rebuild the list with a filtered `replace` (§6) |
| `admission webhook "mutate.kyverno.svc-fail" denied the request` | The rule errored and the webhook's `failurePolicy` is `Fail` | Read the controller log for the wrapped RFC 6902 error |
| Object admitted **unmutated**, no error anywhere | Rule errored and `failurePolicy: Ignore` | The dangerous case — see §12.3 |

### 12.2 Reproducing a production failure locally

```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=200 \
    | grep -iE 'json.?patch|6902|mutate.*error'
E0814 09:44:19.882  mutate  failed to apply JSON Patch
  {"policy":"inject-otel-agent","rule":"inject-agent-container",
   "resource":"payments/Pod/checkout-6b7f9d",
   "error":"add operation does not apply: doc is missing path: \"/spec/volumes\""}

# Capture the offending object and replay it offline
$ kubectl get pod -n payments checkout-6b7f9d -o yaml \
    | yq 'del(.status, .metadata.uid, .metadata.resourceVersion,
              .metadata.creationTimestamp, .metadata.managedFields)' > repro.yaml

$ kyverno apply inject-otel-agent.yaml --resource repro.yaml -v 4
...
Applying 1 policy rule(s) to 1 resource(s)...

Error: failed to apply policy inject-otel-agent rule inject-agent-container on
resource payments/Pod/checkout-6b7f9d: add operation does not apply:
doc is missing path: "/spec/volumes"

pass: 0, fail: 0, warn: 0, error: 1, skip: 0
$ echo $?
1
```

### 12.3 `failurePolicy` and the silent-drift class of bug

This is the highest-severity operational property of `patchesJson6902` and it is worth stating on its own:

| `spec.failurePolicy` | Patch operation errors | Visible to the user? | Consequence |
|---|---|---|---|
| `Fail` (default) | Admission request **rejected** | ✅ loudly — `kubectl` prints the webhook error | Deploys break. Loud, correctable. |
| `Ignore` | Object admitted **without the mutation** | ❌ nothing in the apply output | A "hardening" policy silently stops hardening. Sidecars vanish. Nobody notices until an incident. |

If you run `failurePolicy: Ignore` — which many teams do, to keep a Kyverno outage from becoming a cluster outage — you **must** compensate with detection:

1. A paired `validate` policy in `Audit` mode asserting the post-condition (the sidecar exists, the flag is absent). Mutation failures then show up as PolicyReport failures.
2. An alert on the `kyverno_policy_results_total{rule_result="error"}` metric.

```console
$ kubectl get polr -A -o json \
  | jq -r '.items[].results[] | select(.result=="fail" or .result=="error")
           | "\(.policy)/\(.rule)\t\(.result)\t\(.message)"' | sort | uniq -c | sort -rn | head
     31 require-otel-agent/agent-present	fail	validation error: workloads labeled otel=enabled must carry the otel-agent container

$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
$ curl -s localhost:8000/metrics | grep 'kyverno_policy_results_total.*error'
kyverno_policy_results_total{policy_name="inject-otel-agent",rule_name="inject-agent-container",rule_result="error",rule_type="mutation",...} 31
```

31 failed mutations, zero errors on any `kubectl apply`. That gap is exactly what `failurePolicy: Ignore` buys you, and the validate-in-audit pairing is how you close it.

---

## 13. `kubectl patch` — the same dialect at the operator's fingertips

Everything above applies verbatim to `kubectl patch --type=json`; it is the fastest way to build intuition for RFC 6902 before committing it to a policy.

```console
# remove a probe that is flapping during an incident
$ kubectl patch deployment web --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/containers/0/livenessProbe"}]'
deployment.apps/web patched

# compare-and-swap: only scale if we are still at 3 replicas
$ kubectl patch deployment web --type=json -p '[
    {"op":"test","path":"/spec/replicas","value":3},
    {"op":"replace","path":"/spec/replicas","value":8}
  ]'
deployment.apps/web patched

# the same command once someone else has already scaled it
$ kubectl patch deployment web --type=json -p '[
    {"op":"test","path":"/spec/replicas","value":3},
    {"op":"replace","path":"/spec/replicas","value":8}
  ]'
Error from server: jsonpatch test operation does not apply
# → the replace did NOT happen. Atomicity did its job.

# escaping, on the command line
$ kubectl patch ingress shop --type=json \
    -p '[{"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size","value":"50m"}]'
ingress.networking.k8s.io/shop patched

# reorder initContainers
$ kubectl patch deployment web --type=json \
    -p '[{"op":"move","from":"/spec/template/spec/initContainers/2","path":"/spec/template/spec/initContainers/0"}]'
deployment.apps/web patched

# subresources take patches too
$ kubectl patch pod api --subresource=status --type=json \
    -p '[{"op":"replace","path":"/status/conditions/0/status","value":"False"}]'

# always rehearse against the server first
$ kubectl patch deployment web --type=json --dry-run=server -o yaml \
    -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]' \
  | yq '.spec.template.spec.containers[0].resources'
requests:
  cpu: 100m
  memory: 128Mi
limits:
  memory: 512Mi
```

**Interaction with server-side apply.** A JSON Patch is a client-side-apply write; it takes field ownership under the field manager `kubectl-patch`. If the object is otherwise reconciled by Argo CD or Flux with `--server-side`, your patch creates a conflicting owner and the next sync either reverts it or errors with a conflict. Patch imperatively during incidents; encode the durable intent as a Kyverno policy or in Git.

---

## 14. Ordering, performance and cost

| Concern | Behaviour | Practical guidance |
|---|---|---|
| Rule order within a policy | Sequential; rule *n* sees rule *n−1*'s output | Put parent-creating SMP rules before JSON Patch rules |
| Policy order across policies | Not guaranteed | Never make one policy depend on another's mutation |
| Webhook reinvocation | `IfNeeded` → rules may run twice per request | Every `add /list/-` needs an absence precondition |
| Variable substitution | Runs before JSON parsing, per request | Keep JMESPath shallow; a `foreach` over 30 containers is 30 substitutions |
| Latency budget | Mutating webhooks are on the critical path of every write | Narrow `match` (kinds, namespaces, label selectors) is the biggest lever, not patch complexity |
| `background: true` | Enables periodic re-evaluation | Set `background: false` on rules that reference `request.userInfo`, `request.uid` or `request.operation` — those are unavailable outside admission |
| Skip vs error | Precondition false → `skip`; failed op → `error` | Use preconditions for control flow, `test` only for genuine CAS |

---

## 15. Exam checklist

- `patchesJson6902` is a **string** (`|-` block scalar), not a YAML list.
- JSON Pointer escaping: `~` → `~0`, `/` → `~1`. Annotations and labels almost always need `~1`.
- `-` means append and is legal **only** for `add`.
- `add` on an object member **replaces**; on an array index it **inserts** and shifts.
- `remove` and `replace` **require** the target to exist; `add` requires the **parent** to exist.
- JSON Patch **never creates missing parents** — that is Strategic Merge Patch's job.
- A patch is **atomic**: one failed op discards the whole patch.
- `test` failure is an **error**, not a skip; absence checks belong in **preconditions**.
- Removing multiple array elements by index is a bug — rebuild the list with a JMESPath-filtered `replace`.
- `add /spec/containers/-` is **not idempotent**; webhook reinvocation duplicates it.
- Paths are absolute from the object root: `/spec/...` for Pod, `/spec/template/spec/...` for Deployment, `/spec/jobTemplate/spec/template/spec/...` for CronJob.
- `foreach` gives you `{{ element }}` and `{{ elementIndex }}`.
- SMP anchors: `()` conditional, `+()` add-if-not-present (mutate), `=()` equality, `^()` existence, `X()` negation, `<()` global.
- `failurePolicy: Ignore` turns a broken patch into silent drift — pair it with a validate policy in `Audit`.
- `mutate.targets` + `mutateExistingOnPolicyUpdate` need extra RBAC aggregated with `rbac.kyverno.io/aggregate-to-background-controller: "true"`.
- Verify with `kyverno apply` (fast), `kyverno test` + `patchedResources` (regression), `kubectl apply --dry-run=server` (full chain).

---

## Referencias

**Standards**
- RFC 6902 — JavaScript Object Notation (JSON) Patch: https://datatracker.ietf.org/doc/html/rfc6902
- RFC 6901 — JavaScript Object Notation (JSON) Pointer: https://datatracker.ietf.org/doc/html/rfc6901
- RFC 7386 — JSON Merge Patch: https://datatracker.ietf.org/doc/html/rfc7386
- Interactive JSON Patch playground: https://jsonpatch.me/

**Kyverno**
- Mutate rules (`patchesJson6902`, `patchStrategicMerge`, anchors, `foreach`): https://kyverno.io/docs/policy-types/cluster-policy/mutate/
- Mutate existing resources (`targets`, RBAC): https://kyverno.io/docs/policy-types/cluster-policy/mutate/#mutate-existing-resources
- Preconditions: https://kyverno.io/docs/policy-types/cluster-policy/preconditions/
- JMESPath in Kyverno: https://kyverno.io/docs/policy-types/cluster-policy/jmespath/
- Auto-gen rules for Pod controllers: https://kyverno.io/docs/policy-types/cluster-policy/autogen/
- Kyverno CLI — `apply` and `test`: https://kyverno.io/docs/kyverno-cli/usage/apply/ · https://kyverno.io/docs/kyverno-cli/usage/test/
- Policy Reports: https://kyverno.io/docs/policy-reports/
- Customizing permissions / RBAC aggregation: https://kyverno.io/docs/installation/customization/#customizing-permissions
- Policy settings (`failurePolicy`, `background`, `webhookConfiguration`): https://kyverno.io/docs/policy-types/cluster-policy/policy-settings/
- Kyverno policy library — mutation examples: https://kyverno.io/policies/?policytypes=mutate

**Kubernetes**
- Update API objects in place using `kubectl patch`: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- Dynamic Admission Control — webhooks, `reinvocationPolicy`, `failurePolicy`: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Server-Side Apply and field management: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- API concepts — patch content types: https://kubernetes.io/docs/reference/using-api/api-concepts/#patch-and-apply
- Mutating Admission Policy (CEL-based mutation with `patchType: JSONPatch`; check the current feature-gate status for your version): https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- `kubectl patch` reference: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_patch/

**Implementation**
- `evanphx/json-patch` — the RFC 6902 implementation used by Kubernetes and Kyverno: https://github.com/evanphx/json-patch
- `k8s.io/apimachinery` strategic merge patch: https://github.com/kubernetes/apimachinery/tree/master/pkg/util/strategicpatch

**Curriculum**
- KCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf