# 5.5 Generation Rules

> **Domain 5 — Writing Policies** · Exam weight: **2.91 %**
> Applies to `kyverno.io/v1` / `kyverno.io/v2beta1` `ClusterPolicy` and `Policy`, `spec.rules[].generate`.

---

## 1. The architectural problem

Every multi-tenant Kubernetes platform hits the same wall on day one: **a `Namespace` is an empty box**. The API server will happily create it with zero NetworkPolicies, zero ResourceQuota, no LimitRange, no image-pull credentials, and no RBAC. From the moment `kubectl create ns team-payments` returns until a human or a pipeline provisions the guardrails, that namespace is an unbounded, fully-connected blast radius sitting inside your cluster.

The classic remedies all leak:

| Approach | Where it breaks in production |
|---|---|
| Namespace template in Helm/Kustomize, applied by CI | Only covers namespaces created *through* the pipeline. Anyone with `create namespace` RBAC bypasses it entirely. |
| GitOps app-of-apps (Argo CD / Flux) per tenant | Correct, but provisioning latency is a full reconcile loop; and it requires a Git commit for every namespace, which does not compose with self-service portals. |
| Custom controller / operator | Correct and fast, but you now own a controller: leader election, informer cache, retry/backoff, RBAC, upgrades, observability. Weeks of work for a `NetworkPolicy` copy. |
| Hierarchical Namespace Controller (HNC), Capsule | Strong for hierarchy and propagation, but is a second, opinionated control plane with its own CRDs and its own tenancy model. |
| `validate` rule that *rejects* namespaces lacking a NetworkPolicy | Impossible — the NetworkPolicy cannot exist before the namespace it lives in. Validation can only forbid, never provision. |

A Kyverno **generation rule** collapses this into a declarative policy object: *when a resource matching X appears, ensure a resource Y exists, and optionally keep Y converged forever.* It is a controller you write in YAML, running inside a controller you already operate for validation and mutation.

The second problem it solves is **drift**. `synchronize: true` turns the rule from a one-shot bootstrap into a continuous reconciliation loop over the generated object. A developer who deletes the `default-deny` NetworkPolicy to debug connectivity gets it back within a reconcile interval, without a pager and without a Git revert.

The third — and the one most teams discover late — is **fan-out configuration**. Change the `data` block in one policy and every downstream copy across 3 000 namespaces converges. That is enormous leverage, and it is exactly as dangerous as it sounds; §10 covers the blast-radius controls.

---

## 2. Where a generate rule actually executes

This is the single most important mental model for the exam and for on-call. **A generate rule does not run in the admission webhook.** It is not part of the trigger's admission transaction.

```
                      ┌──────────────────────────────────────────────────────────┐
  kubectl create ns   │                     kube-apiserver                       │
  team-payments  ───► │  auth ─► mutating admission ─► validating admission ─► etcd
                      └────────────┬──────────────────────────┬──────────────────┘
                                   │ AdmissionReview          │ watch
                                   ▼                          │
                      ┌────────────────────────┐              │
                      │ kyverno-admission-     │              │
                      │ controller (webhook)   │              │
                      │  • evaluates match/    │              │
                      │    exclude/precondition│              │
                      │  • creates an          │              │
                      │    UpdateRequest (UR)  │              │
                      └────────────┬───────────┘              │
                                   │ CREATE ur-xxxxx          │
                                   ▼   (ns: kyverno)          │
                      ┌────────────────────────┐              │
                      │ UpdateRequest CR       │◄─────────────┘
                      │ spec.type: generate    │
                      │ status.state: Pending  │
                      └────────────┬───────────┘
                                   │ informer
                                   ▼
                      ┌────────────────────────┐
                      │ kyverno-background-    │  resolves context/variables
                      │ controller             │  renders data|clone|cloneList
                      │  (SA: kyverno-         │  CREATE/UPDATE downstream
                      │   background-controller│  writes status.generatedResources
                      └────────────┬───────────┘
                                   │
                                   ▼
                      NetworkPolicy/team-payments/default-deny-ingress
                      labels: generate.kyverno.io/policy-name=...
                              generate.kyverno.io/trigger-name=...
```

Four consequences fall out of this design, and every one of them is an incident waiting to happen if you don't internalise it:

1. **Generation is eventually consistent.** The `create namespace` call returns `Created` before the NetworkPolicy exists. A pipeline that creates a namespace and immediately schedules Pods has a real, reproducible race window (typically tens to hundreds of milliseconds, but unbounded under background-controller backlog).
2. **Identity is the background controller's, not the user's.** The downstream is written by `system:serviceaccount:kyverno:kyverno-background-controller`. If that ServiceAccount lacks RBAC for the target kind, the trigger still succeeds and the generation silently fails into the UR status. Kyverno **cannot grant what it does not itself hold** — the API server's privilege-escalation prevention applies to it like any other subject.
3. **Failures are asynchronous and therefore invisible to the user.** `kubectl create ns` prints success. The failure lives in `UpdateRequest.status`, a Kubernetes Event on the trigger, and the background-controller log. Alert on all three.
4. **Registering a generate rule puts Kyverno in the admission path for the trigger kind.** A rule matching `Namespace` causes Kyverno to add `namespaces` to its resource webhook. With `failurePolicy: Fail`, a Kyverno outage now blocks namespace creation cluster-wide. That is a deliberate trade — pick it consciously.

### Why labels and not `ownerReferences`

Kyverno links downstream resources to their trigger with **labels**, not owner references, and re-implements the deletion semantics itself. That is not laziness; the Kubernetes garbage collector forbids the topology generate needs:

| Owner | Dependent | Legal? | GC behaviour |
|---|---|---|---|
| Cluster-scoped (e.g. `Namespace`) | Namespaced (e.g. `NetworkPolicy`) | Yes | Normal cascading delete |
| Namespaced, **same** namespace | Namespaced | Yes | Normal cascading delete |
| Namespaced, **different** namespace | Namespaced | **No** | Treated as invalid; the dependent is **deleted** and an `OwnerRefInvalidNamespace` event is emitted |
| Namespaced | Cluster-scoped | **No** | Owner ref is unresolvable; the dependent is never garbage collected |

A `clone` rule copying `platform-system/harbor-pull-secret` into `team-payments` is precisely the third row. Had Kyverno used owner references, the API server would have deleted every generated Secret shortly after creation. Hence the label contract:

```
app.kubernetes.io/managed-by:                  kyverno
generate.kyverno.io/policy-name:               sync-registry-credentials
generate.kyverno.io/policy-namespace:          ""            # empty for ClusterPolicy
generate.kyverno.io/rule-name:                 clone-pull-secret
generate.kyverno.io/trigger-group:             ""
generate.kyverno.io/trigger-version:           v1
generate.kyverno.io/trigger-kind:              Namespace
generate.kyverno.io/trigger-name:              team-payments
generate.kyverno.io/trigger-namespace:         ""
```

These labels are the **only** join key between policy, trigger and downstream. Strip them (a well-meaning Kustomize `commonLabels` overlay will) and Kyverno loses the ability to synchronize or clean up that object. Treat them as a protected namespace of label keys.

> **Version note.** Label key sets and `UpdateRequest` API versions have moved across releases (`GenerateRequest` → `UpdateRequest`; `kyverno.io/v1beta1` → `kyverno.io/v2`). Confirm against `kubectl explain updaterequest.spec` on the cluster you are operating.

---

## 3. API surface

```yaml
rules:
  - name: <string>                     # required, unique within the policy
    match: {...}                       # selects the TRIGGER, not the downstream
    exclude: {...}
    preconditions: {...}               # JMESPath gate, evaluated before generation
    context: [...]                     # configMap | apiCall | variable | imageRegistry | globalReference
    generate:
      apiVersion: <group/version>      # downstream API version
      kind: <Kind>                     # downstream kind
      name: <string>                   # downstream name (variables allowed)
      namespace: <string>              # downstream namespace (omit for cluster-scoped)
      synchronize: <bool>              # default false
      orphanDownstreamOnPolicyDelete: <bool>   # default false  (>= 1.10)
      generateExisting: <bool>         # rule-level backfill      (newer releases)

      # exactly ONE of the following payload sources:
      data: {...}                      # inline definition
      clone:                           # copy one existing resource
        namespace: <string>
        name: <string>
      cloneList:                       # copy N existing resources by selector
        namespace: <string>
        kinds: [<group/version/Kind>, ...]
        selector: {matchLabels: {...}}
      foreach:                         # loop over a list (>= 1.11)
        - list: <jmespath>
          apiVersion: ...
          kind: ...
          name: ...
          namespace: ...
          data|clone|cloneList: ...
```

Spec-level fields that change generate behaviour:

| Field | Effect |
|---|---|
| `spec.background` | Must be `true` for `generateExisting` and for background reconciliation. Kyverno rejects `background: true` on rules referencing `{{request.userInfo.*}}` / `{{request.roles}}` / `{{serviceAccountName}}`, because that data does not exist outside an AdmissionReview. |
| `spec.generateExisting` | Applies the rule to resources that already existed when the policy was created/updated. Older name: `spec.generateExistingOnPolicyUpdate`. |
| `spec.failurePolicy` | `Fail` (default) makes a Kyverno outage block the *trigger's* admission. `Ignore` trades enforcement for availability. |
| `spec.schemaValidation` | Kyverno validates the `data` block against the target CRD's OpenAPI schema where available. |

Two hard scoping rules worth memorising:

- **A namespaced `Policy` can only generate into its own namespace.** Cross-namespace generation requires a `ClusterPolicy`.
- **`match` describes the trigger.** A very common beginner error is writing `match: kinds: [NetworkPolicy]` when the intent is "generate a NetworkPolicy for every Namespace". The trigger is the `Namespace`.

---

## 4. Payload source: `data` vs `clone` vs `cloneList`

| Dimension | `data` | `clone` | `cloneList` |
|---|---|---|---|
| Source of truth | The policy manifest itself | A live resource in the cluster | N live resources selected by labels |
| Variable interpolation | Full (`{{request.*}}`, context) | None — verbatim copy | None — verbatim copy |
| Add labels/annotations to downstream | Yes, inline | **No** — `data` and `clone` are mutually exclusive | **No** |
| Secret material in Git | Present in the policy → **do not use for Secrets** | Stays in the cluster (or in your ESO/Vault sync target) | Same |
| Rotation story | Edit policy → fan-out | Update the source Secret → fan-out (with `synchronize: true`) | Same |
| Downstream name | Explicit, may be templated | Inherited from source | Inherited from each source |
| Number of downstreams per trigger | 1 (or N with `foreach`) | 1 | N (selector cardinality) |
| Typical use | NetworkPolicy, ResourceQuota, LimitRange, RoleBinding, ConfigMap | `imagePullSecret`, CA bundle, wildcard TLS Secret | "propagate everything labelled `propagate=true`" |

Decision heuristic used in practice:

- The content is **derived from the trigger** (namespace name, tenant tier label, annotation) → `data`.
- The content is **sensitive or rotated by another system** (External Secrets Operator, cert-manager, Vault) → `clone`, and let the other system own the source.
- The set of things to propagate is **open-ended and managed by the platform team via labels** → `cloneList`.

> **`clone` requires the background controller to `get`/`list`/`watch` the source.** If the source lives in a namespace excluded by the `kyverno` ConfigMap's `resourceFilters`, the clone will fail or never re-sync. This is the number-one cause of "the Secret was created once and never updated again".

---

## 5. Synchronization semantics — the complete state table

`synchronize` is the field that decides whether you have written a bootstrap script or a controller. Know this table cold.

| Event | `synchronize: false` | `synchronize: true` |
|---|---|---|
| Trigger created (matches) | Downstream created | Downstream created |
| Trigger updated, still matches | No-op | Downstream re-reconciled from current source/data |
| Trigger updated, **no longer** matches (label removed) | Downstream left in place | Downstream **deleted** |
| Trigger deleted | Downstream left in place | Downstream **deleted** |
| Downstream mutated by a user | Drift persists forever | Reverted to the policy's desired state |
| Downstream deleted by a user | Not recreated | Recreated |
| `clone` source resource updated | Downstream stays stale | Downstream updated to match source |
| `clone` source resource deleted | Downstream stays | Reconciliation errors; downstream is **not** removed automatically |
| Policy `data` block edited | Only *new* downstreams get the new content | **All** downstreams updated (fan-out) |
| Rule removed / policy deleted | Downstream left in place | Downstream deleted, unless `orphanDownstreamOnPolicyDelete: true` |
| Downstream's namespace deleted | Gone via native GC | Gone; recreated only if the trigger is recreated |

Three operational readings of this table:

1. **`synchronize: true` + `orphanDownstreamOnPolicyDelete: false` (the defaults you get by explicitly asking) means `kubectl delete cpol namespace-baseline` deletes every NetworkPolicy it ever created.** On a 2 000-namespace cluster that is an instantaneous, cluster-wide network-policy removal. Set `orphanDownstreamOnPolicyDelete: true` on anything security-critical, or protect the policy object with a `validate` rule / finalizer discipline.
2. **`synchronize: false` is not "weaker enforcement", it is "no enforcement after t₀".** Use it only where the generated object is genuinely a *seed* the tenant is meant to own and evolve (a starter `ConfigMap`, an example `Ingress`).
3. **The "no longer matches → deleted" row is a footgun with label selectors.** A tenant who removes `tenant.example.com/managed: "true"` from their own namespace — which they can do if they hold `patch namespace` — deletes their own quota and network policy. Gate the label with a separate `validate` rule that forbids removing it.

---

## 6. RBAC: the failure mode everyone hits first

Kyverno's background controller ships with permissions for a conservative core set. **Anything else you must grant explicitly**, via a `ClusterRole` carrying the aggregation label:

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:background-controller:tenant-baseline
  labels:
    # This label is the contract. Kyverno's background-controller ClusterRole is an
    # aggregated role; anything labelled here is merged into it by the API server's
    # ClusterRole aggregation controller, with no Kyverno restart required.
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups: [""]
    resources:
      - resourcequotas
      - limitranges
      - configmaps
      - secrets
      - serviceaccounts
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["rolebindings", "roles"]
    # 'bind' and 'escalate' are REQUIRED to create a RoleBinding that references a
    # ClusterRole whose permissions Kyverno does not itself hold. Without them the
    # API server rejects the write with a privilege-escalation error, even though
    # 'create rolebindings' is granted.
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "bind", "escalate"]

  - apiGroups: ["cert-manager.io"]
    resources: ["certificates"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

Verify the grant took effect *as the controller's identity*, never as yourself:

```console
$ kubectl auth can-i create networkpolicies \
    --as=system:serviceaccount:kyverno:kyverno-background-controller \
    -n team-payments
yes

$ kubectl auth can-i create rolebindings \
    --as=system:serviceaccount:kyverno:kyverno-background-controller \
    -n team-payments
yes

$ kubectl get clusterrole kyverno:background-controller -o jsonpath='{.aggregationRule}' | jq
{
  "clusterRoleSelectors": [
    {
      "matchLabels": {
        "rbac.kyverno.io/aggregate-to-background-controller": "true"
      }
    }
  ]
}
```

Sibling labels exist for the other controllers — `rbac.kyverno.io/aggregate-to-admission-controller`, `...-to-reports-controller`, `...-to-cleanup-controller`. Grant to the *narrowest* one that needs it; generation needs only the background controller.

---

## 7. Production manifests

### 7.1 Tenant baseline bootstrap — `data`, with a tiered quota resolved from a ConfigMap

The platform-team source of truth for sizing:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-system
  labels:
    tenant.example.com/managed: "false"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tenant-tiers
  namespace: platform-system
data:
  tiers: |
    [
      {"name": "bronze", "cpu": "4",  "memory": "8Gi",   "pods": "30",  "pvc": "5",  "nodeports": "0"},
      {"name": "silver", "cpu": "16", "memory": "32Gi",  "pods": "120", "pvc": "20", "nodeports": "2"},
      {"name": "gold",   "cpu": "64", "memory": "128Gi", "pods": "400", "pvc": "60", "nodeports": "8"}
    ]
```

The policy:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: tenant-namespace-baseline
  annotations:
    policies.kyverno.io/title: Tenant Namespace Baseline
    policies.kyverno.io/category: Multi-Tenancy
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Namespace, NetworkPolicy, ResourceQuota, LimitRange
    policies.kyverno.io/description: >-
      Provisions and continuously reconciles the mandatory guardrails for every
      namespace labelled tenant.example.com/managed=true: a default-deny ingress
      NetworkPolicy, a ResourceQuota sized from the tenant tier, and a LimitRange
      that forces every container to carry requests. Generated objects are
      orphaned on policy deletion so that removing the policy never silently
      removes the network guardrails of a running fleet.
spec:
  # Generate rules always execute in the background controller. background:true is
  # additionally required so that generateExisting can backfill pre-existing
  # namespaces, and so drift is reconciled outside admission events.
  background: true
  generateExisting: true
  # If Kyverno is unavailable we would rather let namespace creation succeed and
  # backfill on recovery than block the whole platform. Flip to Fail once the
  # Kyverno deployment is genuinely HA and you have an SLO to back it.
  failurePolicy: Ignore

  rules:
    # ---------------------------------------------------------------------------
    - name: default-deny-ingress
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      exclude:
        any:
          - resources:
              kinds:
                - Namespace
              names:
                - "kube-*"
                - "kyverno"
                - "platform-system"
                - "default"
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-ingress
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        # Deleting this policy must NOT strip network isolation from the fleet.
        orphanDownstreamOnPolicyDelete: true
        data:
          metadata:
            labels:
              app.kubernetes.io/part-of: tenant-baseline
              app.kubernetes.io/managed-by: kyverno
            annotations:
              # Argo CD would otherwise flag this object as out-of-sync/extraneous
              # in any Application whose destination is this namespace.
              argocd.argoproj.io/compare-options: IgnoreExtraneous
              argocd.argoproj.io/sync-options: Prune=false
              # Flux equivalent.
              kustomize.toolkit.fluxcd.io/prune: disabled
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
            ingress:
              # Same-namespace traffic is permitted; everything else is denied.
              - from:
                  - podSelector: {}
              # Allow the ingress controller in.
              - from:
                  - namespaceSelector:
                      matchLabels:
                        kubernetes.io/metadata.name: ingress-nginx

    # ---------------------------------------------------------------------------
    - name: tenant-resourcequota
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      context:
        # Resolve the tier label with a safe default, so an unlabelled namespace
        # gets the smallest quota rather than an unresolved-variable rule error.
        - name: tierName
          variable:
            jmesPath: request.object.metadata.labels."tenant.example.com/tier"
            default: bronze
        - name: tiersCM
          configMap:
            name: tenant-tiers
            namespace: platform-system
        # ConfigMap values are always strings; parse_json turns the embedded JSON
        # document into a real list we can filter with JMESPath.
        - name: tier
          variable:
            jmesPath: "parse_json(tiersCM.data.tiers)[?name=='{{ tierName }}'] | [0]"
      preconditions:
        all:
          - key: "{{ tier.name || '' }}"
            operator: NotEquals
            value: ""
      generate:
        apiVersion: v1
        kind: ResourceQuota
        name: tenant-quota
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        orphanDownstreamOnPolicyDelete: true
        data:
          metadata:
            labels:
              app.kubernetes.io/part-of: tenant-baseline
              tenant.example.com/tier: "{{ tier.name }}"
            annotations:
              argocd.argoproj.io/compare-options: IgnoreExtraneous
          spec:
            hard:
              requests.cpu: "{{ tier.cpu }}"
              requests.memory: "{{ tier.memory }}"
              limits.cpu: "{{ tier.cpu }}"
              limits.memory: "{{ tier.memory }}"
              pods: "{{ tier.pods }}"
              persistentvolumeclaims: "{{ tier.pvc }}"
              services.nodeports: "{{ tier.nodeports }}"
              count/jobs.batch: "50"

    # ---------------------------------------------------------------------------
    - name: tenant-limitrange
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      generate:
        apiVersion: v1
        kind: LimitRange
        name: tenant-defaults
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        orphanDownstreamOnPolicyDelete: true
        data:
          metadata:
            labels:
              app.kubernetes.io/part-of: tenant-baseline
          spec:
            limits:
              - type: Container
                default:
                  cpu: "500m"
                  memory: "512Mi"
                defaultRequest:
                  cpu: "100m"
                  memory: "128Mi"
                max:
                  cpu: "4"
                  memory: "8Gi"
                min:
                  cpu: "10m"
                  memory: "16Mi"
              - type: PersistentVolumeClaim
                max:
                  storage: "500Gi"
                min:
                  storage: "1Gi"
```

**Design notes embedded above, made explicit:**

- `operations: [CREATE, UPDATE]` — `UPDATE` matters. It is what makes a namespace *becoming* managed (label added later) trigger provisioning.
- `default: bronze` on the `tierName` context entry converts a missing label from a *rule error* (which surfaces as `PolicyError` and a failed UR) into a safe fallback. Unresolved variables in generate rules are a leading cause of stuck URs.
- The `preconditions` block guards against a tier label naming a tier that does not exist in the ConfigMap: `tier` would be `null`, and `{{ tier.cpu }}` would fail to resolve. Skipping is the correct behaviour — the namespace gets no quota and the missing-quota alert fires, rather than the whole rule erroring in a loop.
- `orphanDownstreamOnPolicyDelete: true` on all three rules. Removing the policy should be a control-plane change, not a data-plane outage.

### 7.2 Registry credential distribution — `clone`

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-registry-credentials
  annotations:
    policies.kyverno.io/title: Propagate Registry Pull Secret
    policies.kyverno.io/category: Supply Chain
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Clones the platform registry pull secret into every tenant namespace and
      keeps it converged. The source secret is owned by External Secrets Operator,
      so credential rotation in Vault propagates fleet-wide with no policy change.
spec:
  background: true
  generateExisting: true
  rules:
    - name: clone-harbor-pull-secret
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      exclude:
        any:
          - resources:
              kinds:
                - Namespace
              names:
                - "kube-*"
                - "kyverno"
                - "platform-system"
      generate:
        apiVersion: v1
        kind: Secret
        name: harbor-pull-secret
        namespace: "{{ request.object.metadata.name }}"
        # With synchronize:true Kyverno watches the SOURCE. When ESO rewrites
        # platform-system/harbor-pull-secret after a Vault rotation, every clone
        # is updated. This is the entire reason to prefer clone over data here:
        # the credential never enters a policy manifest, therefore never enters Git.
        synchronize: true
        orphanDownstreamOnPolicyDelete: false
        clone:
          namespace: platform-system
          name: harbor-pull-secret
```

The companion piece — generation puts the Secret in the namespace, but Pods still need to reference it. That is a **mutate-existing** rule, not a generate rule, and the pairing is a common exam and design point:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: attach-pull-secret-to-default-sa
spec:
  background: true
  mutateExistingOnPolicyUpdate: true
  rules:
    - name: add-imagepullsecret
      match:
        any:
          - resources:
              kinds:
                - Secret
              names:
                - harbor-pull-secret
              operations:
                - CREATE
                - UPDATE
      mutate:
        targets:
          - apiVersion: v1
            kind: ServiceAccount
            name: default
            namespace: "{{ request.object.metadata.namespace }}"
        patchStrategicMerge:
          imagePullSecrets:
            - name: harbor-pull-secret
```

### 7.3 Selector-driven propagation — `cloneList`

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-platform-bundles
  annotations:
    policies.kyverno.io/title: Propagate Platform Bundles
    policies.kyverno.io/description: >-
      Copies every ConfigMap and Secret in platform-system carrying the label
      tenant.example.com/propagate=true into every managed namespace. Adding a new
      bundle is a label on one object, not a policy change.
spec:
  background: true
  generateExisting: true
  rules:
    - name: clone-labelled-bundles
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/managed: "true"
      generate:
        # No apiVersion/kind/name here: cloneList derives all three from each
        # matched source object. Only the destination namespace is specified.
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        orphanDownstreamOnPolicyDelete: false
        cloneList:
          namespace: platform-system
          kinds:
            - v1/ConfigMap
            - v1/Secret
          selector:
            matchLabels:
              tenant.example.com/propagate: "true"
```

Sources, for completeness:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: corporate-ca-bundle
  namespace: platform-system
  labels:
    tenant.example.com/propagate: "true"
data:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    MIIDXTCCAkWgAwIBAgIJAKl3xk8kQ2mBMA0GCSqGSIb3DQEBCwUAMEUxCzAJBgNV
    ...
    -----END CERTIFICATE-----
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-endpoint
  namespace: platform-system
  labels:
    tenant.example.com/propagate: "true"
data:
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
```

**The scaling trade-off in one sentence:** `cloneList` cardinality multiplies. Three labelled bundles × 2 000 namespaces = 6 000 downstream objects, each with its own reconcile path and each consuming etcd. Label a fourth bundle and you have just issued 2 000 API writes with a single `kubectl label`.

### 7.4 `foreach` — one downstream per element (Kyverno ≥ 1.11)

Generating a cert-manager `Certificate` per host on every Ingress:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-certificates-per-ingress-host
  annotations:
    policies.kyverno.io/title: Certificate per Ingress Host
    policies.kyverno.io/description: >-
      Emits one cert-manager Certificate per host listed on an Ingress annotated
      for automatic TLS, without requiring tenants to understand cert-manager.
spec:
  background: true
  rules:
    - name: certificate-per-host
      match:
        any:
          - resources:
              kinds:
                - networking.k8s.io/v1/Ingress
              operations:
                - CREATE
                - UPDATE
              selector:
                matchLabels:
                  tenant.example.com/auto-tls: "true"
      preconditions:
        all:
          - key: "{{ request.object.spec.rules[?host] | length(@) }}"
            operator: GreaterThan
            value: 0
      generate:
        foreach:
          - list: "request.object.spec.rules[?host]"
            apiVersion: cert-manager.io/v1
            kind: Certificate
            # Hostnames contain dots, which are legal in a DNS-subdomain name but
            # make downstream naming ambiguous. Normalise to dashes.
            name: "{{ replace_all(element.host, '.', '-') }}-tls"
            namespace: "{{ request.object.metadata.namespace }}"
            synchronize: true
            orphanDownstreamOnPolicyDelete: false
            data:
              metadata:
                labels:
                  app.kubernetes.io/managed-by: kyverno
                  tenant.example.com/source-ingress: "{{ request.object.metadata.name }}"
              spec:
                secretName: "{{ replace_all(element.host, '.', '-') }}-tls"
                duration: 2160h    # 90d
                renewBefore: 720h  # 30d
                privateKey:
                  algorithm: ECDSA
                  size: 256
                  rotationPolicy: Always
                dnsNames:
                  - "{{ element.host }}"
                usages:
                  - server auth
                issuerRef:
                  name: letsencrypt-prod
                  kind: ClusterIssuer
                  group: cert-manager.io
```

Note the removal semantics: with `synchronize: true`, deleting a host from `spec.rules` causes the corresponding `Certificate` to be removed on the next reconcile, because that downstream is no longer in the rendered desired set.

### 7.5 Backfilling an existing cluster

`generateExisting` is what turns a new policy from "applies to namespaces created from now on" into "applies to the fleet". Two forms:

```yaml
# Spec-level: applies to every generate rule in the policy.
spec:
  background: true
  generateExisting: true
```

```yaml
# Rule-level (newer releases): scope the backfill to one rule, so you can roll out
# a cheap NetworkPolicy backfill immediately and defer an expensive one.
    - name: default-deny-ingress
      generate:
        generateExisting: true
        ...
```

The backfill is triggered by **policy create or update**, not by a schedule. Re-triggering a backfill without changing behaviour is done by touching an innocuous annotation:

```console
$ kubectl annotate cpol tenant-namespace-baseline \
    platform.example.com/backfill-epoch="7" --overwrite
clusterpolicy.kyverno.io/tenant-namespace-baseline annotated
```

**Do not do this on a large cluster during business hours.** A backfill enumerates every matching resource and enqueues one `UpdateRequest` per (trigger × rule). Three rules over 2 000 namespaces is 6 000 URs materialised in etcd and drained through the background controller's work queue.

---

## 8. CLI: verification loop with real output

### 8.1 Offline — validate before the cluster ever sees it

```console
$ kyverno version
Version: 1.13.2
Time: 2025-01-28T09:12:44Z
Git commit ID: 4f1c0b93c7e2f1a6d21b8b3f9d5e7a1c2b6f8d40

$ kyverno apply policy/tenant-namespace-baseline.yaml \
    --resource test/namespace-team-payments.yaml \
    --values-file test/values.yaml \
    --output out/

Applying 3 policy rule(s) to 1 resource(s)...

pass: 3, fail: 0, warn: 0, error: 0, skip: 0

$ ls out/
LimitRange-team-payments-tenant-defaults.yaml
NetworkPolicy-team-payments-default-deny-ingress.yaml
ResourceQuota-team-payments-tenant-quota.yaml

$ cat out/ResourceQuota-team-payments-tenant-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  labels:
    app.kubernetes.io/part-of: tenant-baseline
    tenant.example.com/tier: silver
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
  name: tenant-quota
  namespace: team-payments
spec:
  hard:
    count/jobs.batch: "50"
    limits.cpu: "16"
    limits.memory: 32Gi
    persistentvolumeclaims: "20"
    pods: "120"
    requests.cpu: "16"
    requests.memory: 32Gi
    services.nodeports: "2"
```

The `--values-file` supplies the ConfigMap context so the offline run resolves the same variables the cluster would:

```yaml
---
apiVersion: cli.kyverno.io/v1alpha1
kind: Values
metadata:
  name: baseline-values
policies:
  - name: tenant-namespace-baseline
    resources:
      - name: team-payments
        values: {}
namespaceSelector: []
globalValues: {}
```

Pinning the expected output as a regression test:

```yaml
---
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: tenant-namespace-baseline
policies:
  - ../policy/tenant-namespace-baseline.yaml
resources:
  - namespace-team-payments.yaml
variables: values.yaml
results:
  - policy: tenant-namespace-baseline
    rule: default-deny-ingress
    kind: Namespace
    resources:
      - team-payments
    generatedResource: expected/networkpolicy-default-deny-ingress.yaml
    result: pass
  - policy: tenant-namespace-baseline
    rule: tenant-resourcequota
    kind: Namespace
    resources:
      - team-payments
    generatedResource: expected/resourcequota-tenant-quota.yaml
    result: pass
  - policy: tenant-namespace-baseline
    rule: tenant-limitrange
    kind: Namespace
    resources:
      - team-payments
    generatedResource: expected/limitrange-tenant-defaults.yaml
    result: pass
```

```console
$ kyverno test . --detailed-results

Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 3 policy rules to 1 resource ...
  Checking results ...

│────│───────────────────────────│──────────────────────│──────────────────────────│────────│
│ ID │ POLICY                    │ RULE                 │ RESOURCE                 │ RESULT │
│────│───────────────────────────│──────────────────────│──────────────────────────│────────│
│ 1  │ tenant-namespace-baseline │ default-deny-ingress │ /Namespace/team-payments │ Pass   │
│ 2  │ tenant-namespace-baseline │ tenant-resourcequota │ /Namespace/team-payments │ Pass   │
│ 3  │ tenant-namespace-baseline │ tenant-limitrange    │ /Namespace/team-payments │ Pass   │
│────│───────────────────────────│──────────────────────│──────────────────────────│────────│

Test Summary: 3 tests passed and 0 tests failed
```

`generatedResource` performs a structural comparison of the rendered downstream against a golden file. This is the only mechanism that catches a `data` block regression before it fans out across the fleet — put it in CI.

### 8.2 In-cluster — the standard verification sequence

```console
$ kubectl apply -f policy/tenant-namespace-baseline.yaml
clusterpolicy.kyverno.io/tenant-namespace-baseline created

$ kubectl get cpol tenant-namespace-baseline
NAME                        ADMISSION   BACKGROUND   READY   AGE   MESSAGE
tenant-namespace-baseline   true        true         True    9s    Ready

$ kubectl create namespace team-payments
namespace/team-payments created

$ kubectl label namespace team-payments \
    tenant.example.com/managed=true tenant.example.com/tier=silver
namespace/team-payments labeled
```

The `UpdateRequest` is the ground truth for "did generation happen":

```console
$ kubectl -n kyverno get updaterequests
NAME       POLICY                      RULE                   RESOURCEKIND   RESOURCENAME    RESOURCENAMESPACE   STATUS      AGE
ur-2t9hq   tenant-namespace-baseline   default-deny-ingress   Namespace      team-payments                       Completed   4s
ur-b7wkn   tenant-namespace-baseline   tenant-resourcequota   Namespace      team-payments                       Completed   4s
ur-x4mzc   tenant-namespace-baseline   tenant-limitrange      Namespace      team-payments                       Completed   4s

$ kubectl -n kyverno get ur ur-b7wkn -o yaml
apiVersion: kyverno.io/v2
kind: UpdateRequest
metadata:
  generateName: ur-
  labels:
    generate.kyverno.io/policy-name: tenant-namespace-baseline
    generate.kyverno.io/rule-name: tenant-resourcequota
    generate.kyverno.io/trigger-kind: Namespace
    generate.kyverno.io/trigger-name: team-payments
    generate.kyverno.io/trigger-namespace: ""
  name: ur-b7wkn
  namespace: kyverno
spec:
  policy: tenant-namespace-baseline
  rule: tenant-resourcequota
  type: generate
  resource:
    apiVersion: v1
    kind: Namespace
    name: team-payments
status:
  state: Completed
  generatedResources:
    - apiVersion: v1
      kind: ResourceQuota
      name: tenant-quota
      namespace: team-payments
```

Confirm the downstream and its provenance labels:

```console
$ kubectl -n team-payments get networkpolicy,resourcequota,limitrange
NAME                                                  POD-SELECTOR   AGE
networkpolicy.networking.k8s.io/default-deny-ingress   <none>         31s

NAME                    AGE   REQUEST                                                              LIMIT
resourcequota/tenant-quota   31s   count/jobs.batch: 0/50, persistentvolumeclaims: 0/20, pods: 0/120, requests.cpu: 0/16, requests.memory: 0/32Gi, services.nodeports: 0/2   limits.cpu: 0/16, limits.memory: 0/32Gi

NAME                          CREATED AT
limitrange/tenant-defaults    2026-08-13T09:41:07Z

$ kubectl -n team-payments get netpol default-deny-ingress \
    -o jsonpath='{.metadata.labels}' | jq
{
  "app.kubernetes.io/managed-by": "kyverno",
  "app.kubernetes.io/part-of": "tenant-baseline",
  "generate.kyverno.io/policy-name": "tenant-namespace-baseline",
  "generate.kyverno.io/policy-namespace": "",
  "generate.kyverno.io/rule-name": "default-deny-ingress",
  "generate.kyverno.io/trigger-group": "",
  "generate.kyverno.io/trigger-kind": "Namespace",
  "generate.kyverno.io/trigger-name": "team-payments",
  "generate.kyverno.io/trigger-namespace": "",
  "generate.kyverno.io/trigger-version": "v1"
}
```

Prove that `synchronize` actually reconciles — the test every platform team should run before trusting the rule:

```console
$ kubectl -n team-payments delete netpol default-deny-ingress
networkpolicy.networking.k8s.io "default-deny-ingress" deleted

$ sleep 5 && kubectl -n team-payments get netpol
NAME                   POD-SELECTOR   AGE
default-deny-ingress   <none>         3s

$ kubectl -n team-payments patch netpol default-deny-ingress \
    --type=json -p='[{"op":"replace","path":"/spec/ingress","value":[{}]}]'
networkpolicy.networking.k8s.io/default-deny-ingress patched

$ sleep 5 && kubectl -n team-payments get netpol default-deny-ingress \
    -o jsonpath='{.spec.ingress}' | jq
[
  {
    "from": [
      { "podSelector": {} }
    ]
  },
  {
    "from": [
      { "namespaceSelector": { "matchLabels": { "kubernetes.io/metadata.name": "ingress-nginx" } } }
    ]
  }
]
```

The `[{}]` allow-all patch was reverted. That is the whole value proposition of `synchronize: true` in one terminal transcript.

Fleet-wide audit query — find every namespace that should have a baseline but does not:

```console
$ comm -23 \
    <(kubectl get ns -l tenant.example.com/managed=true -o name | sed 's|namespace/||' | sort) \
    <(kubectl get netpol -A -l generate.kyverno.io/policy-name=tenant-namespace-baseline \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)
team-legacy-billing
team-sandbox-03
```

---

## 9. Failure diagnosis

### 9.1 Triage order

```console
# 1. Is the policy admitted and Ready?
$ kubectl get cpol tenant-namespace-baseline -o wide

# 2. Was an UpdateRequest created at all?  (No UR => the ADMISSION side never matched.)
$ kubectl -n kyverno get ur \
    -l generate.kyverno.io/policy-name=tenant-namespace-baseline

# 3. If a UR exists, what does it say?  (UR exists but not Completed => BACKGROUND side.)
$ kubectl -n kyverno get ur <name> -o jsonpath='{.status}' | jq

# 4. Kubernetes Events on the trigger.
$ kubectl get events -A --field-selector involvedObject.name=team-payments \
    --sort-by=.lastTimestamp

# 5. The controller that actually did the work.
$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=200 \
    | grep -iE 'generat|updaterequest|forbidden'
```

That split at step 2 is the key diagnostic bisection: **no UR is an admission-side problem** (match/exclude, webhook registration, `resourceFilters`); **a UR that never completes is a background-side problem** (RBAC, variable resolution, schema, source missing).

### 9.2 Failure taxonomy

| Symptom | Root cause | Confirming command | Fix |
|---|---|---|---|
| No `UpdateRequest` created at all | Trigger kind not in Kyverno's webhook (autoUpdateWebhooks disabled, or Kyverno restarted before policy sync) | `kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o yaml \| grep -A5 namespaces` | Re-apply the policy; verify `--autoUpdateWebhooks=true` |
| No UR; trigger clearly matches | Trigger namespace/kind excluded by `resourceFilters` in the `kyverno` ConfigMap | `kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}'` | Remove the filter entry, or move the trigger out of the filtered namespace |
| No UR; `match` looks right | `match` was written against the *downstream* kind instead of the trigger | Re-read `spec.rules[].match.any[].resources.kinds` | Match the trigger |
| UR stuck `Pending`, background controller idle | Background controller not running / crash-looping / no leader | `kubectl -n kyverno get pods -l app.kubernetes.io/component=background-controller` | Restore the deployment; check resource limits and OOMKills |
| UR `Failed`, log shows `is forbidden` | Background-controller SA lacks RBAC on the downstream kind | `kubectl auth can-i create <res> --as=system:serviceaccount:kyverno:kyverno-background-controller -n <ns>` | Add an aggregated ClusterRole (§6) |
| UR `Failed` on RoleBinding only | Missing `bind`/`escalate` verbs — privilege-escalation prevention | Same, with `--subresource` unset; read the exact API-server message | Add `bind` and `escalate` |
| UR `Failed`: `variable substitution failed` / `failed to resolve` | JMESPath path does not exist on the trigger, or context entry returned `null` | `kyverno apply` offline with the exact trigger YAML | Add `default:` to the context variable, or a `preconditions` guard |
| Downstream created but immediately deleted | Something set a cross-namespace `ownerReference`; or the trigger stopped matching | `kubectl get events -n <ns> \| grep OwnerRefInvalidNamespace` | Remove the owner ref; do not hand-add owner refs to generated objects |
| Downstream never updates when the source changes | `synchronize: false`; or the source namespace is filtered; or clone-source watch labels were stripped | `kubectl get <source> -o jsonpath='{.metadata.labels}'` | Set `synchronize: true`; unfilter the source namespace |
| Downstream reverts a legitimate tenant edit | `synchronize: true` is doing exactly its job | — | Use `synchronize: false` for seeds, or narrow the `data` block to only the fields you own |
| Everything vanished after `kubectl delete cpol` | `orphanDownstreamOnPolicyDelete: false` (default) with `synchronize: true` | `kubectl get cpol` (gone) + audit logs | Set `orphanDownstreamOnPolicyDelete: true` before deleting; restore by re-applying the policy with `generateExisting: true` |
| Argo CD shows the namespace permanently `OutOfSync` | Generated object is extraneous to the Application's desired state | Argo UI diff | `argocd.argoproj.io/compare-options: IgnoreExtraneous` on the generated object, or an Argo `resource.exclusions` entry |
| Pods started before the NetworkPolicy existed | Asynchronous generation — by design | Compare `creationTimestamp` of Pod vs NetworkPolicy | Accept eventual consistency, and add a `validate` rule that denies Pods in managed namespaces lacking the guardrail |
| `generateExisting` did nothing | `spec.background: false`, or the policy was never updated after the flag was added | `kubectl get cpol <n> -o jsonpath='{.spec.background} {.spec.generateExisting}'` | Set `background: true`; touch an annotation to re-trigger |

### 9.3 Real failure transcripts

**RBAC denial:**

```console
$ kubectl -n kyverno get ur -l generate.kyverno.io/policy-name=generate-certificates-per-ingress-host
NAME       POLICY                                   RULE                   RESOURCEKIND   RESOURCENAME   RESOURCENAMESPACE   STATUS   AGE
ur-9qk4d   generate-certificates-per-ingress-host   certificate-per-host   Ingress        payments-api   team-payments       Failed   22s

$ kubectl -n kyverno get ur ur-9qk4d -o jsonpath='{.status}' | jq
{
  "state": "Failed",
  "message": "failed to create resource certificates.cert-manager.io/v1: certificates.cert-manager.io is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot create resource \"certificates\" in API group \"cert-manager.io\" in the namespace \"team-payments\"",
  "retryCount": 3
}

$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=5
E0813 09:52:14.774318       1 controller.go:318] "reconcile failed" err="failed to create resource certificates.cert-manager.io/v1: certificates.cert-manager.io is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot create resource \"certificates\" in API group \"cert-manager.io\" in the namespace \"team-payments\"" controller="updaterequest" UpdateRequest="kyverno/ur-9qk4d"

$ kubectl auth can-i create certificates.cert-manager.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n team-payments
no
```

Fix, then confirm the retry converges without touching the trigger:

```console
$ kubectl apply -f rbac/kyverno-background-certmanager.yaml
clusterrole.rbac.authorization.k8s.io/kyverno:background-controller:cert-manager created

$ kubectl auth can-i create certificates.cert-manager.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n team-payments
yes

$ kubectl -n team-payments annotate ingress payments-api kyverno.io/retry="1" --overwrite
ingress.networking.k8s.io/payments-api annotated

$ kubectl -n team-payments get certificates
NAME                          READY   SECRET                        AGE
api-payments-example-com-tls  True    api-payments-example-com-tls  18s
```

**Unresolved variable:**

```console
$ kubectl -n kyverno get ur ur-mm81f -o jsonpath='{.status.message}'
failed to substitute variables in generate rule: failed to resolve tier.cpu at path /spec/hard/requests.cpu: JMESPath query failed: Unknown key "cpu" in path

$ kubectl get ns team-legacy-billing -o jsonpath='{.metadata.labels}' | jq
{
  "kubernetes.io/metadata.name": "team-legacy-billing",
  "tenant.example.com/managed": "true",
  "tenant.example.com/tier": "platinum"
}
```

The namespace claims a `platinum` tier that does not exist in `tenant-tiers`; the JMESPath filter returned `null` and the `preconditions` guard was what should have skipped it. The reproduction offline:

```console
$ kyverno apply policy/tenant-namespace-baseline.yaml \
    --resource /tmp/ns-legacy.yaml

Applying 3 policy rule(s) to 1 resource(s)...

skipped: tenant-namespace-baseline/tenant-resourcequota on /Namespace/team-legacy-billing

pass: 2, fail: 0, warn: 0, error: 0, skip: 1
```

`skip` rather than `error` — which is what the precondition buys you, and why the offline run should always be part of the loop.

---

## 10. Scale, blast radius and operational limits

| Concern | Mechanism | Mitigation |
|---|---|---|
| UR volume | One UR per (trigger event × generate rule). A 3-rule policy backfilled over 2 000 namespaces = 6 000 URs in etcd. | Roll out rule-by-rule; use rule-level `generateExisting`; watch etcd object count and `apiserver_storage_objects`. |
| Fan-out on `data` edit | `synchronize: true` propagates a policy edit to every downstream. | Canary with a label selector (`tenant.example.com/baseline-channel: canary`), promote by relabelling. Two policies, two channels. |
| Background controller throughput | Single work queue with bounded concurrency. Backlog manifests as growing `Pending` UR count and rising generation latency. | Alert on `count(kube_customresource … state="Pending") > N` and on UR age; scale the background controller deployment and its CPU limits. |
| Admission path coupling | A generate rule on `Namespace` puts Kyverno in the path of every namespace CREATE. | `failurePolicy: Ignore` for provisioning-only policies; run the admission controller HA with a PDB; keep `Fail` only for policies whose bypass is a security event. |
| Deletion blast radius | `kubectl delete cpol` with `synchronize: true` and default orphan behaviour removes every downstream. | `orphanDownstreamOnPolicyDelete: true`; a `validate` ClusterPolicy that denies `DELETE` on baseline policies except by a break-glass ServiceAccount. |
| Secrets sprawl | `clone` of a pull secret to N namespaces means N copies of a credential, each readable by anyone with `get secrets` in that namespace. | Scope the credential to pull-only; rotate at the source; consider a registry-level, per-namespace token instead. |
| Terminating namespaces | Generation into a namespace in `Terminating` fails and retries. | Exclude terminating namespaces with a precondition on `request.object.status.phase`. |

**Closing the async gap.** Pair the generate rule with a validate rule so that the *window* is bounded by admission rather than by reconcile latency:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-baseline-before-workloads
  annotations:
    policies.kyverno.io/description: >-
      Closes the eventual-consistency window of tenant-namespace-baseline. A Pod
      cannot be admitted into a managed namespace until the generated NetworkPolicy
      actually exists, so no workload ever runs unisolated.
spec:
  background: false
  validationFailureAction: Enforce
  rules:
    - name: netpol-must-exist
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
              namespaceSelector:
                matchLabels:
                  tenant.example.com/managed: "true"
      context:
        - name: netpols
          apiCall:
            urlPath: "/apis/networking.k8s.io/v1/namespaces/{{ request.namespace }}/networkpolicies"
            jmesPath: "items[?metadata.name=='default-deny-ingress'] | length(@)"
      validate:
        message: >-
          The tenant baseline NetworkPolicy is not yet present in namespace
          {{ request.namespace }}. Kyverno provisions it asynchronously; retry in
          a few seconds. If this persists, the platform team has an open incident.
        deny:
          conditions:
            all:
              - key: "{{ netpols }}"
                operator: Equals
                value: 0
```

```console
$ kubectl -n team-payments run probe --image=nginx:1.27
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/team-payments/probe was blocked due to the following policies

require-baseline-before-workloads:
  netpol-must-exist: 'The tenant baseline NetworkPolicy is not yet present in namespace
    team-payments. Kyverno provisions it asynchronously; retry in a few seconds. If
    this persists, the platform team has an open incident.'
```

This is the pattern worth taking away from the whole topic: **`generate` provisions, `validate` guarantees.** Neither alone gives you a closed guardrail.

---

## 11. Interaction with GitOps

Generated resources exist in the cluster but not in Git. Every reconciling GitOps engine will therefore see them as drift.

| Engine | Symptom | Remedy |
|---|---|---|
| Argo CD | Application permanently `OutOfSync`; automated prune deletes the generated object; Kyverno recreates it; loop | Annotate the downstream `argocd.argoproj.io/compare-options: IgnoreExtraneous` and `argocd.argoproj.io/sync-options: Prune=false` (only possible with `data`, not `clone`), or add a cluster-wide `resource.exclusions` entry in `argocd-cm` keyed on `app.kubernetes.io/managed-by: kyverno` |
| Flux | Kustomization garbage-collects the object | `kustomize.toolkit.fluxcd.io/prune: disabled` on the downstream, or scope the Kustomization's inventory |

With `clone` you cannot inject annotations, because `clone` and `data` are mutually exclusive. The workable options are (a) put the annotations on the **source** so every copy inherits them, or (b) exclude at the engine level rather than per object. Option (a) is preferred: it keeps the exception declarative and colocated with the thing being propagated.

---

## 12. Exam checklist

- A generate rule's `match` selects the **trigger**, never the generated resource.
- Generation runs in the **background controller** via an **`UpdateRequest`**, asynchronously, outside the admission transaction.
- The downstream is written as `system:serviceaccount:kyverno:kyverno-background-controller`. Missing RBAC → the trigger still succeeds, the generation fails silently into UR status.
- Extend RBAC with a `ClusterRole` labelled `rbac.kyverno.io/aggregate-to-background-controller: "true"`.
- Exactly one of `data`, `clone`, `cloneList` (or a `foreach` containing one of them). `data` supports variables; `clone`/`cloneList` do not.
- `synchronize: true` ⇒ downstream is reconciled on drift, updated when the source/policy changes, **and deleted when the trigger is deleted or stops matching**.
- `orphanDownstreamOnPolicyDelete: true` keeps downstream resources when the policy or rule is removed. Default is `false`.
- `generateExisting: true` (requires `spec.background: true`) backfills resources that already exist; it fires on policy create/update, not on a timer.
- A namespaced `Policy` generates only into its own namespace; cross-namespace generation needs a `ClusterPolicy`.
- Linkage is by `generate.kyverno.io/*` labels, **not** owner references — because cross-namespace owner references are invalid in Kubernetes.
- `kubectl -n kyverno get ur` is the first command in every generate-rule investigation.
- Rules that reference `{{request.userInfo.*}}` cannot run with `background: true`, and therefore cannot use `generateExisting`.

> **Forward-looking note.** Recent Kyverno releases introduce CEL-based policy types under `policies.kyverno.io/v1alpha1` (`ValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy`, …) that align with the upstream Kubernetes ValidatingAdmissionPolicy model. The KCA exam and the overwhelming majority of production deployments target the `kyverno.io/v1` `ClusterPolicy`/`Policy` API described here. Check `kubectl api-resources --api-group=policies.kyverno.io` on your own cluster before assuming availability, and verify field names against `kubectl explain` for the exact version you run.

---

## Referencias

**Kyverno — official documentation**
- Generate rules: https://kyverno.io/docs/writing-policies/generate/
- Writing policies (index): https://kyverno.io/docs/writing-policies/
- Variables, context and JMESPath: https://kyverno.io/docs/writing-policies/variables/
- JMESPath custom filters (`parse_json`, `replace_all`, …): https://kyverno.io/docs/writing-policies/jmespath/
- Preconditions: https://kyverno.io/docs/writing-policies/preconditions/
- Mutate existing resources: https://kyverno.io/docs/writing-policies/mutate/
- Kyverno CLI (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Installation and customization (RBAC, ConfigMap, `resourceFilters`, webhooks): https://kyverno.io/docs/installation/customization/
- Troubleshooting: https://kyverno.io/docs/troubleshooting/
- Policy library (production-grade generate examples): https://kyverno.io/policies/
- Source and API types: https://github.com/kyverno/kyverno
- Policy library source: https://github.com/kyverno/policies

**Kubernetes — official documentation**
- Owners and dependents (cross-namespace owner-reference restrictions): https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/
- Garbage collection: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- RBAC — privilege escalation prevention, `bind` and `escalate`: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping
- Aggregated ClusterRoles: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles
- Dynamic admission control (webhook `failurePolicy`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Network policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Resource quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Limit ranges: https://kubernetes.io/docs/concepts/policy/limit-range/

**Certification**
- KCA curriculum (CNCF): https://github.com/cncf/curriculum
- Kyverno Certified Associate (Linux Foundation): https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/

**Ecosystem referenced in the examples**
- cert-manager `Certificate` API: https://cert-manager.io/docs/usage/certificate/
- Argo CD compare options and resource exclusions: https://argo-cd.readthedocs.io/en/stable/user-guide/compare-options/
- Flux Kustomization pruning: https://fluxcd.io/flux/components/kustomize/kustomizations/