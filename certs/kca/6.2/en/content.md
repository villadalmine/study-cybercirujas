# 6.2 PolicyExceptions

**Exam weight: 3.33** · API surface: `kyverno.io/v2`, `kind: PolicyException` (short name `polex`)

---

## 1. The architectural problem

A policy engine is only adopted if it can be operated. The failure mode that kills Kyverno rollouts is not a missing feature — it is the **exception request queue**.

The steady state looks like this. The platform team owns a set of `ClusterPolicy` objects: `disallow-privileged-containers`, `disallow-host-path`, `restrict-image-registries`, `require-run-as-nonroot`. These are cluster-scoped, they apply to every namespace, and they are reconciled from a Git repository the platform team controls. Then reality arrives:

- The GPU operator needs `privileged: true` to load kernel modules.
- The node log shipper needs `hostPath: /var/log/pods`.
- A legacy vendor image only publishes to `quay.io/vendor` and your registry allowlist is `registry.internal.example.com/*`.
- A batch job in `data-eng` runs a container that genuinely needs `CAP_SYS_NICE`.

Each of these is a legitimate, reviewed, business-approved exemption. The question is *where the exemption is written down*.

### The three antipatterns

**Antipattern 1 — editing the policy.** The obvious move is to add an `exclude` block to the `ClusterPolicy`:

```yaml
  rules:
  - name: host-path
    match:
      any:
      - resources:
          kinds: [Pod]
    exclude:
      any:
      - resources:
          namespaces: [observability, gpu-operator, data-eng, legacy-erp]
```

This works, and it is wrong at scale for four reasons:

1. **Blast radius.** The exclusion object *is* the enforcement object. A typo in the `exclude` block — a stray `*`, a wrong indent that promotes `exclude` a level — silently disables the rule cluster-wide. There is no smaller unit of failure than "the whole policy."
2. **Ownership inversion.** The team that needs the exemption cannot make the change; the platform team must. Every exemption becomes a pull request against a repository the requesting team has no write access to, reviewed by people who do not know why `/var/log/pods` is needed. The queue grows, and the pressure to merge without review grows with it.
3. **No lifecycle.** `namespaces: [legacy-erp]` has no expiry, no owner, and no ticket. Three years later nobody knows whether `legacy-erp` still exists, and deleting the entry is a risk nobody wants to take. Exclusion lists are monotonically increasing.
4. **Coarse granularity.** Excluding the namespace exempts *every* workload in it, forever, including the ones deployed next quarter. You wanted to exempt one DaemonSet; you exempted a namespace.

**Antipattern 2 — the policy fork.** Copy the `ClusterPolicy` into a namespaced `Policy` with the offending rule removed, and exclude the namespace from the cluster policy. Now you have two divergent copies of the same intent, and the next upstream policy update patches one of them.

**Antipattern 3 — turning the rule to Audit.** Set the failure action to `Audit` for that namespace. The rule stops blocking *everything* in the namespace, not just the justified workload, and the report fills with `fail` results nobody triages.

### What `PolicyException` changes

`PolicyException` is a **separate, namespaced Kubernetes object that names the policy and rule it exempts, and the resources the exemption covers**. It inverts the ownership: the policy stays untouched and platform-owned; the exception is a first-class object that can live in the application team's namespace, in the application team's Git repository, under the application team's RBAC — while the *permission to create one* remains a platform-controlled grant.

That gives you the four properties the antipatterns lack:

| Property | Mechanism |
|---|---|
| Bounded blast radius | A malformed exception fails to exempt; it cannot disable a rule it does not name |
| Delegable | RBAC on a namespaced CRD, not write access to the policy repo |
| Auditable | `kubectl get polex -A` is the complete, queryable list of every exemption in the cluster |
| Expirable | It is a Kubernetes object — it takes labels, annotations, owner references, and Kyverno's `cleanup.kyverno.io/ttl` |

And critically: **an exempted resource is reported as `skip`, not `pass`.** The exemption is visible in the policy report forever. You never lose the signal that a control was not applied.

---

## 2. Choosing an exclusion mechanism

Kyverno offers several ways to not-enforce something. They are not interchangeable. This table is the decision surface.

| Mechanism | Object edited | Owned by | Granularity | Visible in reports | Expirable | Survives policy upgrade | Use when |
|---|---|---|---|---|---|---|---|
| `rule.exclude` block | The policy itself | Platform | Namespace / kind / selector | No — resource is not evaluated at all | No | Merge conflict on every upstream bump | The exclusion is **structural and permanent** (e.g. never evaluate `kube-system`) |
| Namespace label + `namespaceSelector` in `match` | Policy + namespace | Platform + ns owner | Whole namespace | No | No | Yes | Tiering namespaces (`security-tier: baseline` vs `restricted`) |
| `validate.failureActionOverrides` | The policy itself | Platform | Namespace | Yes, as `fail`/`warn` | No | Merge conflict | **Rollout ramps** — audit a new policy in prod while enforcing in staging |
| Namespaced `Policy` fork | New policy object | Whoever forked it | Whole policy | Yes | No | No — diverges silently | Almost never |
| `resourceFilters` in the `kyverno` ConfigMap | Kyverno config | Platform | Webhook level, cluster-wide | **No — Kyverno never sees the resource** | No | Yes | Excluding Kyverno's own namespace and system components; performance triage |
| **`PolicyException`** | **New, separate object** | **App team, under platform RBAC** | **Rule + kind + name/selector + PSS control + CEL-ish conditions** | **Yes, as `skip`** | **Yes (`cleanup.kyverno.io/ttl`)** | **Yes — decoupled from the policy** | **A specific, justified, reviewable workload-level exemption** |

### Contrast with upstream Pod Security Admission exemptions

The KCA syllabus places Kyverno next to the built-in Pod Security Admission controller. Their exemption models are worth comparing directly, because they explain *why* a policy engine exists at all:

| | PSA `exemptions` | Kyverno `PolicyException` |
|---|---|---|
| Where configured | `AdmissionConfiguration` file on the **API server** | A CRD inside the cluster |
| Who can change it | Whoever can edit control-plane static config (cloud provider: often nobody) | Anyone with RBAC on `policyexceptions` in a namespace |
| Change propagation | API server restart / re-read of admission config | Immediate, via watch |
| Exemption dimensions | `usernames`, `runtimeClasses`, `namespaces` — that's all | policy, rule, kind, name glob, label selector, subject/role, JMESPath conditions, individual PSS control, image pattern |
| Granularity floor | Whole namespace | One control, on one image pattern, in one workload |
| Auditability | Read a file on the control plane | `kubectl get polex -A`, plus a `skip` line in every affected PolicyReport |
| GitOps-able | Rarely | Natively |

PSA cannot express "this DaemonSet may mount `/var/log/pods`, and nothing else in the namespace may mount anything." `PolicyException` can.

---

## 3. Anatomy of the CRD

Before writing YAML against any version, read the schema the cluster actually serves. This is not optional ceremony — the `PolicyException` schema has moved through `v2alpha1` → `v2beta1` → `v2` and fields were added in each step.

```console
$ kubectl api-resources --api-group=kyverno.io
NAME                     SHORTNAMES   APIVERSION             NAMESPACED   KIND
cleanuppolicies          cleanpol     kyverno.io/v2          true         CleanupPolicy
clustercleanuppolicies   ccleanpol    kyverno.io/v2          false        ClusterCleanupPolicy
clusterpolicies          cpol         kyverno.io/v1          false        ClusterPolicy
globalcontextentries     gctxentry    kyverno.io/v2alpha1    false        GlobalContextEntry
policies                 pol          kyverno.io/v1          true         Policy
policyexceptions         polex        kyverno.io/v2          true         PolicyException
updaterequests           ur           kyverno.io/v2          true         UpdateRequest
```

```console
$ kubectl explain polex.spec
GROUP:      kyverno.io
KIND:       PolicyException
VERSION:    v2

FIELD: spec <Object>

DESCRIPTION:
    Spec declares policy exception behaviors.

FIELDS:
  background    <boolean>
  conditions    <Object>
  exceptions    <[]Object>
  match         <Object>
  podSecurity   <[]Object>
```

If `conditions` or `podSecurity` are absent from that output, your Kyverno predates them — the manifests in §7 and §8 will be rejected by the API server, not silently ignored.

### The five fields

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: <exception-name>
  namespace: <where-the-object-lives>
spec:
  # 1. Does this exception also apply during background scans (reports),
  #    or only at admission time? Default: true.
  background: true

  # 2. WHICH RESOURCES are exempted. Same schema as a policy match block.
  match:
    any:
    - resources:
        kinds:      [Pod, DaemonSet]
        namespaces: [observability]
        names:      ["node-log-shipper*"]
        selector:
          matchLabels:
            app.kubernetes.io/name: node-log-shipper
        operations:  [CREATE, UPDATE]

  # 3. WHICH POLICY RULES are skipped for those resources.
  exceptions:
  - policyName: disallow-host-path
    ruleNames:
    - host-path
    - autogen-host-path

  # 4. OPTIONAL extra guard: the exception only fires when these hold.
  conditions:
    all:
    - key:      "{{ ... }}"
      operator: AnyIn
      value:    [ ... ]

  # 5. OPTIONAL surgical mode for Pod Security Standards rules:
  #    remove ONE control from evaluation instead of skipping the whole rule.
  podSecurity:
  - controlName: HostPath Volumes
    images:      ["ghcr.io/example/log-shipper:*"]
```

Three semantics that decide whether your exception works:

- **`match` is authoritative, `metadata.namespace` is not.** The namespace the object lives in determines *who can create it* (RBAC) — not, by itself, which resources it covers. `spec.match` decides that. Unless you constrain this (§9), a `PolicyException` created in `team-a` can name `namespaces: [kube-system]`. This is the single most important governance fact about the CRD.
- **`exceptions[].ruleNames` must match the rule name Kyverno actually evaluated**, which for workload controllers is an autogenerated name, not the one in the policy source (§6).
- **An exception is a skip, not a pass.** The rule does not run. If the rule also did something useful — a mutation, an image verification — that is skipped too.

---

## 4. End-to-end: the blocked DaemonSet

The full production scenario. Platform enforces the Pod Security *baseline* control on `hostPath` volumes; observability needs to read node logs.

### 4.1 The policy (platform-owned, untouched from here on)

`policies/disallow-host-path.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-host-path
  annotations:
    policies.kyverno.io/title: Disallow hostPath
    policies.kyverno.io/category: Pod Security Standards (Baseline)
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod,Volume
    policies.kyverno.io/description: >-
      HostPath volumes let Pods access the host filesystem, which is a
      container-escape and data-exfiltration primitive. Mounting a host path
      also couples the workload to node layout. This policy forbids all
      hostPath volumes; justified uses are granted via PolicyException.
spec:
  background: true
  rules:
  - name: host-path
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      failureAction: Enforce
      allowExistingViolations: true
      message: >-
        HostPath volumes are forbidden. The field spec.volumes[*].hostPath
        must be unset. Request an exemption with a PolicyException.
      pattern:
        spec:
          =(volumes):
          - X(hostPath): "null"
```

> On Kyverno older than 1.13, `validate.failureAction` does not exist: use `spec.validationFailureAction: Enforce` at the policy level instead. Verify which form your cluster accepts with `kubectl explain cpol.spec.rules.validate.failureAction`.

```console
$ kubectl apply -f policies/disallow-host-path.yaml
clusterpolicy.kyverno.io/disallow-host-path created

$ kubectl get cpol disallow-host-path
NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
disallow-host-path   true        true         True    9s    Ready
```

`READY=True` means the webhook configuration has converged. A policy stuck at `False` is not enforcing anything yet — check it before concluding an exception "worked."

### 4.2 The workload that must be exempted

`workloads/node-log-shipper.yaml`:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-log-shipper
  namespace: observability
  labels:
    app.kubernetes.io/name: node-log-shipper
    app.kubernetes.io/component: logging
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-log-shipper
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-log-shipper
        app.kubernetes.io/component: logging
    spec:
      serviceAccountName: node-log-shipper
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
      securityContext:
        runAsNonRoot: false
        runAsUser: 0
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: shipper
        image: ghcr.io/example/log-shipper:2.9.1
        args:
        - --input=/var/log/pods
        - --output=otlp://otel-collector.observability.svc:4317
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
            add: ["DAC_READ_SEARCH"]
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 256Mi
        volumeMounts:
        - name: podlogs
          mountPath: /var/log/pods
          readOnly: true
        - name: state
          mountPath: /var/lib/log-shipper
      volumes:
      - name: podlogs
        hostPath:
          path: /var/log/pods
          type: Directory
      - name: state
        emptyDir: {}
```

```console
$ kubectl apply -f workloads/node-log-shipper.yaml
Error from server: error when creating "workloads/node-log-shipper.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource DaemonSet/observability/node-log-shipper was blocked due to the following policies

disallow-host-path:
  autogen-host-path: 'validation error: HostPath volumes are forbidden. The field
    spec.volumes[*].hostPath must be unset. Request an exemption with a PolicyException.
    rule autogen-host-path failed at path /spec/template/spec/volumes/0/hostPath/'
```

**Read that denial message like a diagnostic, because it is one.** It hands you the two strings you need for the exception:

- `disallow-host-path` → `spec.exceptions[].policyName`
- `autogen-host-path` → `spec.exceptions[].ruleNames[]` — *not* `host-path`, which is what the policy source says

### 4.3 The exception

`exceptions/allow-hostpath-log-shipper.yaml`:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: allow-hostpath-log-shipper
  namespace: observability
  labels:
    cleanup.kyverno.io/ttl: 90d
    exceptions.platform.example.com/risk: medium
  annotations:
    exceptions.platform.example.com/owner: observability-sre@example.com
    exceptions.platform.example.com/ticket: PLAT-4471
    exceptions.platform.example.com/approved-by: security-review-board
    exceptions.platform.example.com/justification: >-
      The log shipper reads container stdout/stderr from /var/log/pods on the
      node. The mount is readOnly, the container drops ALL capabilities except
      DAC_READ_SEARCH, and the root filesystem is read-only. Removal is tracked
      in PLAT-4620 (migration to the Kubernetes node log API, Q4).
spec:
  background: true
  match:
    any:
    - resources:
        kinds:
        - DaemonSet
        - Pod
        namespaces:
        - observability
        selector:
          matchLabels:
            app.kubernetes.io/name: node-log-shipper
  exceptions:
  - policyName: disallow-host-path
    ruleNames:
    - host-path
    - autogen-host-path
```

Two design choices worth defending in a review:

- **Both `kinds` and both `ruleNames`.** The DaemonSet is validated by `autogen-host-path`. The Pods that the DaemonSet controller subsequently creates are validated *separately*, as `Pod`, by `host-path`. Exempting only the DaemonSet produces the worst possible outcome: the DaemonSet is admitted, then every Pod it spawns is rejected, and the workload never runs while the object exists and looks healthy.
- **`selector.matchLabels`, not `names: ["node-log-shipper*"]`.** A name glob is matched against the *requested* name, which anyone with create rights in the namespace controls; `node-log-shipper-evil` matches the glob. Label selectors are also team-controlled, but they force an explicit, greppable declaration on the workload. Where the risk is high, add a `conditions` block (§7) so the exemption is bound to the actual hostPath value rather than to who wrote the manifest.

```console
$ kubectl apply -f exceptions/allow-hostpath-log-shipper.yaml
policyexception.kyverno.io/allow-hostpath-log-shipper created

$ kubectl -n observability get polex
NAME                         AGE
allow-hostpath-log-shipper   6s

$ kubectl apply -f workloads/node-log-shipper.yaml
daemonset.apps/node-log-shipper created

$ kubectl -n observability rollout status ds/node-log-shipper
daemon set "node-log-shipper" successfully rolled out
```

### 4.4 Proving the exemption is recorded, not hidden

This is the step that separates a `PolicyException` from an `exclude` block. The control was not applied, and the cluster says so:

```console
$ kubectl -n observability get policyreport
NAME                                   KIND        NAME                     PASS   FAIL   WARN   ERROR   SKIP   AGE
1a4f0a6f-4c7b-4a5f-9a0e-2f7c9f1a3b21   DaemonSet   node-log-shipper            3      0      0       0      1     47s
7c2d9e10-8ab3-41d2-b6f4-0d1e5c8a9b33   Pod         node-log-shipper-4nrqx      3      0      0       0      1     44s
6b1c8f27-1de4-4a0b-9c22-5f3a7d2e4c19   Pod         node-log-shipper-hs8lp      3      0      0       0      1     44s
```

```console
$ kubectl -n observability get polr -o json | jq -r '
    .items[].results[]
    | select(.result=="skip")
    | [.policy, .rule, .result, .message] | @tsv'
disallow-host-path	autogen-host-path	skip	rule is skipped due to policy exception observability/allow-hostpath-log-shipper
disallow-host-path	host-path	skip	rule is skipped due to policy exception observability/allow-hostpath-log-shipper
disallow-host-path	host-path	skip	rule is skipped due to policy exception observability/allow-hostpath-log-shipper
```

> Match on `result == "skip"` in tooling, never on the message string — the wording of the skip message is not API and changes across minor releases. The `result` field is stable, it is defined by the Kubernetes Policy WG report schema, and it is what your dashboards should key on.

The audit query that answers "what is not enforced in this cluster, and who owns it":

```console
$ kubectl get polex -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TTL:.metadata.labels.cleanup\.kyverno\.io/ttl,OWNER:.metadata.annotations.exceptions\.platform\.example\.com/owner,TICKET:.metadata.annotations.exceptions\.platform\.example\.com/ticket,POLICIES:.spec.exceptions[*].policyName'
NS              NAME                          TTL   OWNER                              TICKET      POLICIES
gpu-operator    gpu-driver-privileged         30d   platform-gpu@example.com           PLAT-4390   disallow-privileged-containers
observability   allow-hostpath-log-shipper    90d   observability-sre@example.com      PLAT-4471   disallow-host-path
data-eng        spark-sys-nice                60d   data-platform@example.com          DATA-1182   restrict-capabilities
```

That table is the deliverable an auditor asks for. It does not exist with `exclude` blocks.

---

## 5. Enabling and confining the feature

`PolicyException` is gated by a controller flag. On a cluster where it is off, applying an exception fails at the API server (the CRD may still be installed by the chart) or the exception is accepted and silently ignored — both have been observed across releases, which is why you verify rather than assume.

```console
$ kubectl -n kyverno get deploy kyverno-admission-controller \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="kyverno")].args}' \
  | tr ',' '\n' | tr -d '[]"' | grep -i -E 'exception|enablePolicy'
--enablePolicyException=true
--exceptionNamespace=
```

Interpretation:

| Output | Meaning |
|---|---|
| `--enablePolicyException=true` | Exceptions are honoured |
| `--enablePolicyException=false`, or the flag absent on a release where it defaults off | Exceptions are ignored — the CRD may exist and accept writes, and nothing will happen |
| `--exceptionNamespace=` (empty) | An exception is honoured **in any namespace** |
| `--exceptionNamespace=platform-exceptions` | Only exceptions living in `platform-exceptions` are honoured; every other one is inert |

Helm values that produce those flags:

```yaml
# values.yaml
features:
  policyExceptions:
    enabled: true
    # Empty string = accept exceptions from any namespace (self-service model).
    # Set to a single namespace to centralise them (gatekeeping model).
    namespace: ""
```

```console
$ helm upgrade --install kyverno kyverno/kyverno \
    --namespace kyverno --create-namespace \
    --version 3.x.x \
    --set features.policyExceptions.enabled=true \
    --set features.policyExceptions.namespace="" \
    --wait
```

### The two operating models

| | Self-service (`namespace: ""`) | Centralised (`namespace: platform-exceptions`) |
|---|---|---|
| Where exceptions live | Team namespaces, in team Git repos | One namespace, in the platform repo |
| Who approves | RBAC grant + meta-policy (§9) | Human review on a PR |
| Latency to exempt | Minutes | Days |
| Risk | An over-broad grant becomes a self-serve bypass | Exception queue backlog; teams route around the policy engine |
| Cross-namespace reach | Must be constrained by a meta-policy | Structurally centralised, but still needs `match` review |
| Recommended for | Mature platforms with the §9 controls in place | New rollouts, regulated environments, any cluster without a meta-policy |

**Start centralised. Move to self-service only once the §9 controls are enforced and tested.** A self-service model without a meta-policy is a cluster-wide policy bypass granted to every namespace admin.

Kyverno's own controllers also need read access to the CRD. If you install with a hand-written RBAC set rather than the chart, and the admission, background and reports controllers cannot `list`/`watch` `policyexceptions`, exceptions apply at admission but not in reports, or not at all:

```console
$ kubectl auth can-i list policyexceptions.kyverno.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -A
yes
```

---

## 6. The autogen trap

This is the most common reason a correct-looking exception does nothing, and it is exam material.

Kyverno policies are normally written against `Pod`, because that is where the security-relevant fields live. But nobody deploys bare Pods. So Kyverno **auto-generates** additional rules that apply the same check to the pod template of workload controllers. The generated rules get derived names:

| Source rule matches | Generated rule name | Applies to |
|---|---|---|
| `Pod` | `<rule-name>` (the original) | `Pod` |
| `Pod` | `autogen-<rule-name>` | `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `ReplicationController`, `Job` |
| `Pod` | `autogen-cronjob-<rule-name>` | `CronJob` |

Autogen behaviour is steered by an annotation on the policy:

```yaml
metadata:
  annotations:
    # Restrict which controllers get generated rules; "none" disables autogen.
    pod-policies.kyverno.io/autogen-controllers: DaemonSet,Deployment,StatefulSet
```

An exception that lists only `ruleNames: [host-path]` will not exempt a Deployment, because the rule that fired was `autogen-host-path`. An exception that lists only `[autogen-host-path]` exempts the Deployment and then every Pod it creates is rejected.

**The reliable procedure, in order of preference:**

1. Read the rule name out of the admission denial (§4.2) or the PolicyReport `rule` field. This is empirical and cannot be wrong.
2. Enumerate what actually ran, for a resource you can create:

```console
$ kubectl -n observability get polr -o json | jq -r '
    .items[]
    | select(.scope.name=="node-log-shipper")
    | .results[] | [.policy, .rule, .result] | @tsv'
disallow-host-path	autogen-host-path	skip
require-run-as-nonroot	autogen-run-as-nonroot	pass
require-requests-limits	autogen-requests-limits	pass
restrict-image-registries	autogen-validate-registries	pass
```

3. Cover all three forms explicitly:

```yaml
  exceptions:
  - policyName: disallow-host-path
    ruleNames:
    - host-path
    - autogen-host-path
    - autogen-cronjob-host-path
```

### The wildcard, and why to ban it

`ruleNames` accepts globs, so this covers every variant in one line:

```yaml
  exceptions:
  - policyName: disallow-host-path
    ruleNames: ["*"]
```

It also covers **every rule the policy will ever contain**. When the platform team adds a second rule to `disallow-host-path` next quarter — say, one that blocks `hostPath` in `ephemeral-containers` — the wildcard exempts that too, retroactively and silently. `ruleNames: ["*"]` converts an exception into a standing exemption from a policy's future.

A narrower glob is defensible when it is anchored:

```yaml
    ruleNames: ["*host-path"]     # covers host-path, autogen-host-path, autogen-cronjob-host-path
```

`ruleNames: ["*"]` is denied by the meta-policy in §9.

---

## 7. Binding the exemption to a fact, not to an identity

`spec.match` answers "which object." `spec.conditions` answers "under what circumstances." The difference matters because `match` selects on metadata the requesting team controls; `conditions` can select on the *substance* of the request.

The log shipper was exempted to read `/var/log/pods`. Nothing in the §4.3 exception stops the team from mounting `/etc/kubernetes/pki` under the same labels. This does:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: allow-hostpath-log-shipper
  namespace: observability
  labels:
    cleanup.kyverno.io/ttl: 90d
  annotations:
    exceptions.platform.example.com/owner: observability-sre@example.com
    exceptions.platform.example.com/ticket: PLAT-4471
spec:
  background: true
  match:
    any:
    - resources:
        kinds:
        - DaemonSet
        - Pod
        namespaces:
        - observability
        selector:
          matchLabels:
            app.kubernetes.io/name: node-log-shipper
  conditions:
    all:
    # Every hostPath in the request must be one of the approved paths.
    - key: "{{ request.object.spec.template.spec.volumes[?hostPath != null].hostPath.path || request.object.spec.volumes[?hostPath != null].hostPath.path || `[]` }}"
      operator: AllIn
      value:
      - /var/log/pods
      - /var/log/containers
    # ...and every one of them must be mounted read-only.
    - key: "{{ request.object.spec.template.spec.containers[].volumeMounts[?name == 'podlogs'].readOnly || request.object.spec.containers[].volumeMounts[?name == 'podlogs'].readOnly || `[]` }}"
      operator: AllIn
      value:
      - true
  exceptions:
  - policyName: disallow-host-path
    ruleNames:
    - host-path
    - autogen-host-path
```

If the condition does not hold, the exception does not apply, the rule runs, and the request is denied by the original policy. The exemption is now attached to the justified behaviour rather than to a label anyone in the namespace can set.

Test the JMESPath before shipping it — a silently-empty expression makes `AllIn` vacuously true and hands you a broader exemption than you wrote:

```console
$ kubectl -n observability get ds node-log-shipper -o json \
  | jq -r '.spec.template.spec.volumes[] | select(.hostPath != null) | .hostPath.path'
/var/log/pods
```

### `background` and admission-only context

`spec.background` controls whether the exception is honoured during background scans, which is what produces PolicyReports for resources that already exist.

| `background` | Admission | Background scan / reports | Consequence |
|---|---|---|---|
| `true` (default) | Exception applies | Exception applies | Resource shows `skip`. This is what you almost always want. |
| `false` | Exception applies | Exception is ignored — the rule runs | Resource is admitted, then reported `fail` forever. Your dashboard alerts on a workload you deliberately approved. |

You **must** set `background: false` when `spec.conditions` references admission-only context, because those variables do not exist during a background scan:

- `request.userInfo.*`, `request.roles`, `request.clusterRoles`
- `request.operation`
- `serviceAccountName`, `serviceAccountNamespace`

Likewise, `spec.match.any[].subjects` / `roles` / `clusterRoles` are admission-time concepts. An exception matching on *who submitted the request* cannot be evaluated when nobody is submitting anything.

Accept the trade: those exceptions produce permanent `fail` entries in reports. Prefer conditions on the object's own fields wherever possible, precisely so you can keep `background: true` and keep the report honest.

---

## 8. Surgical exemptions for Pod Security Standards

Kyverno can enforce the whole Pod Security Standards profile with a single subrule:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: psa-baseline
spec:
  background: true
  rules:
  - name: baseline
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      failureAction: Enforce
      podSecurity:
        level: baseline
        version: latest
```

A plain `PolicyException` against rule `baseline` would skip **the entire baseline profile** for the matched workload — privileged containers, host namespaces, host ports, everything. To exempt one driver Pod's need for `privileged: true` you would drop eleven other controls.

`spec.podSecurity` in the exception solves exactly this. It removes named controls from the evaluation and lets the rule run on the rest:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: gpu-driver-privileged
  namespace: gpu-operator
  labels:
    cleanup.kyverno.io/ttl: 180d
  annotations:
    exceptions.platform.example.com/owner: platform-gpu@example.com
    exceptions.platform.example.com/ticket: PLAT-4390
    exceptions.platform.example.com/justification: >-
      The NVIDIA driver container compiles and inserts kernel modules on the
      node; this requires a privileged container. Scoped to the vendor image
      only. All other baseline controls remain enforced on this workload.
spec:
  background: true
  match:
    any:
    - resources:
        kinds:
        - Pod
        - DaemonSet
        namespaces:
        - gpu-operator
        selector:
          matchLabels:
            app: nvidia-driver-daemonset
  exceptions:
  - policyName: psa-baseline
    ruleNames:
    - baseline
    - autogen-baseline
  podSecurity:
  - controlName: Privileged Containers
    images:
    - "nvcr.io/nvidia/driver:*"
  - controlName: Capabilities
    images:
    - "nvcr.io/nvidia/driver:*"
    restrictedField: spec.containers[*].securityContext.capabilities.add
    values:
    - SYS_ADMIN
    - SYS_MODULE
```

| | Rule-level exception | `podSecurity` exception |
|---|---|---|
| What is skipped | The whole rule — all controls in the profile | Only the named controls |
| Scoped to an image | No | Yes, via `images` glob |
| Scoped to a field value | No | Yes, via `restrictedField` + `values` |
| Report result for the rule | `skip` | The rule still evaluates the remaining controls, so a compliant workload reports `pass` |
| Blast radius | Whole PSS profile | One control, one image, one value |

That last row has an operational consequence: with a `podSecurity` exception, a *new* violation of a *different* control in the same workload is still caught and still blocks. With a rule-level exception, it is not. Confirm the reported result on your own cluster after applying one — `kubectl -n gpu-operator get polr -o json | jq '.items[].results[] | select(.policy=="psa-baseline")'` — and key any dashboards on what you observe.

Control names come from the upstream Pod Security Standards table (`Privileged Containers`, `Host Namespaces`, `HostPath Volumes`, `Host Ports`, `Capabilities`, `HostProcess`, `Seccomp`, `SELinux`, `Sysctls`, `/proc Mount Type`, `AppArmor` for baseline; restricted adds `Volume Types`, `Privilege Escalation`, `Running as Non-root`, `Running as Non-root user`). A misspelled control name is a schema-valid string that matches nothing — verify against the upstream table, and verify empirically that the workload is admitted for the right reason.

---

## 9. Governing exceptions: RBAC, confinement, meta-policy, expiry

An exception mechanism without governance is a bypass mechanism. Four controls, applied together.

### 9.1 RBAC — grant creation narrowly

Everyone gets read. Almost nobody gets write, and never cluster-wide.

```yaml
---
# Cluster-wide READ. Exceptions are a security-relevant inventory; make it visible.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:exceptions-viewer
rules:
- apiGroups: ["kyverno.io"]
  resources: ["policyexceptions"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kyverno:exceptions-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kyverno:exceptions-viewer
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:authenticated
---
# WRITE, namespace-scoped, granted per team by an explicit RoleBinding.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:exceptions-author
rules:
- apiGroups: ["kyverno.io"]
  resources: ["policyexceptions"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: exceptions-author
  namespace: observability
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kyverno:exceptions-author
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: observability-sre
```

Verify the grant is as narrow as intended — including the negative case:

```console
$ kubectl auth can-i create policyexceptions.kyverno.io \
    -n observability --as-group=observability-sre --as=alice@example.com
yes

$ kubectl auth can-i create policyexceptions.kyverno.io \
    -n kube-system --as-group=observability-sre --as=alice@example.com
no

$ kubectl auth can-i create policyexceptions.kyverno.io \
    -A --as-group=observability-sre --as=alice@example.com
no
```

**Do not bundle `policyexceptions` into a namespace-admin `edit`-style role.** In many clusters `edit` is bound broadly; adding the CRD to it grants every namespace admin the ability to write exceptions.

### 9.2 Confinement — the exception must not reach outside its namespace

RBAC controls *where the object is created*, not *what its `match` block names*. Alice can create a `PolicyException` in `observability` whose `spec.match` names `namespaces: [kube-system]`. Close that with a Kyverno policy that validates `PolicyException` objects themselves — policies apply to any Kubernetes resource, including Kyverno's own CRDs.

### 9.3 The meta-policy

`policies/govern-policy-exceptions.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: govern-policy-exceptions
  annotations:
    policies.kyverno.io/title: Govern PolicyExceptions
    policies.kyverno.io/category: Platform Governance
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: PolicyException
    policies.kyverno.io/description: >-
      PolicyExceptions are a delegated bypass of cluster security policy. This
      policy constrains them: no wildcard rule names, no cross-namespace reach,
      mandatory owner/ticket/expiry metadata, and a protected set of policies
      that may only be excepted from the platform namespace.
spec:
  background: false
  rules:

  # ---------------------------------------------------------------------------
  - name: no-wildcard-rule-names
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    validate:
      failureAction: Enforce
      message: >-
        A PolicyException must name the rules it exempts. ruleNames: ["*"] also
        exempts every rule added to the policy in the future. Read the rule name
        from the admission denial or the PolicyReport and list it explicitly.
      foreach:
      - list: "request.object.spec.exceptions"
        deny:
          conditions:
            any:
            - key: "*"
              operator: AnyIn
              value: "{{ element.ruleNames }}"

  # ---------------------------------------------------------------------------
  - name: exception-confined-to-own-namespace
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    preconditions:
      all:
      - key: "{{ request.object.metadata.namespace }}"
        operator: NotEquals
        value: platform-exceptions
    validate:
      failureAction: Enforce
      message: >-
        spec.match.any[].resources.namespaces must be exactly
        ["{{ request.object.metadata.namespace }}"]. A PolicyException may not
        exempt resources outside the namespace it lives in.
      foreach:
      - list: "request.object.spec.match.any"
        deny:
          conditions:
            any:
            - key: "{{ element.resources.namespaces || `[]` }}"
              operator: NotEquals
              value:
              - "{{ request.object.metadata.namespace }}"

  # ---------------------------------------------------------------------------
  - name: require-ownership-and-expiry
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    validate:
      failureAction: Enforce
      message: >-
        Every PolicyException must carry: label cleanup.kyverno.io/ttl, and
        annotations owner, ticket and justification under
        exceptions.platform.example.com/. Exceptions without an expiry become
        permanent policy holes.
      pattern:
        metadata:
          labels:
            cleanup.kyverno.io/ttl: "?*"
          annotations:
            exceptions.platform.example.com/owner: "?*@example.com"
            exceptions.platform.example.com/ticket: "?*-?*"
            exceptions.platform.example.com/justification: "?*"

  # ---------------------------------------------------------------------------
  - name: ttl-must-not-exceed-180-days
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    validate:
      failureAction: Enforce
      message: >-
        cleanup.kyverno.io/ttl must be expressed in days and must not exceed
        180d. Longer-lived exemptions require an architecture review, not a TTL.
      deny:
        conditions:
          any:
          - key: "{{ regex_match('^[0-9]{1,3}d$', '{{ request.object.metadata.labels.\"cleanup.kyverno.io/ttl\" }}') }}"
            operator: Equals
            value: false
          - key: "{{ to_number(trim('{{ request.object.metadata.labels.\"cleanup.kyverno.io/ttl\" }}', 'd')) }}"
            operator: GreaterThan
            value: 180

  # ---------------------------------------------------------------------------
  - name: protected-policies-need-platform-review
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    preconditions:
      all:
      - key: "{{ request.object.metadata.namespace }}"
        operator: NotEquals
        value: platform-exceptions
    validate:
      failureAction: Enforce
      message: >-
        Policy "{{ element.policyName }}" is on the protected list. An exception
        to it may only be created in the platform-exceptions namespace, by the
        platform team, after security review.
      foreach:
      - list: "request.object.spec.exceptions"
        deny:
          conditions:
            any:
            - key: "{{ element.policyName }}"
              operator: AnyIn
              value:
              - disallow-privileged-containers
              - disallow-host-namespaces
              - disallow-capabilities-strict
              - restrict-image-registries
              - verify-image-signatures
              - require-network-policy
```

The meta-policy in action:

```console
$ cat /tmp/bad-exception.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: quick-fix
  namespace: team-a
spec:
  match:
    any:
    - resources:
        kinds: ["*"]
        namespaces: ["*"]
  exceptions:
  - policyName: disallow-privileged-containers
    ruleNames: ["*"]

$ kubectl apply -f /tmp/bad-exception.yaml
Error from server: error when creating "/tmp/bad-exception.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource PolicyException/team-a/quick-fix was blocked due to the following policies

govern-policy-exceptions:
  no-wildcard-rule-names: 'A PolicyException must name the rules it exempts. ruleNames:
    ["*"] also exempts every rule added to the policy in the future. Read the rule
    name from the admission denial or the PolicyReport and list it explicitly.'
  exception-confined-to-own-namespace: 'spec.match.any[].resources.namespaces must
    be exactly ["team-a"]. A PolicyException may not exempt resources outside the
    namespace it lives in.'
  require-ownership-and-expiry: 'validation error: Every PolicyException must carry:
    label cleanup.kyverno.io/ttl, and annotations owner, ticket and justification
    under exceptions.platform.example.com/. Exceptions without an expiry become
    permanent policy holes. rule require-ownership-and-expiry failed at path /metadata/labels/'
  protected-policies-need-platform-review: 'Policy "disallow-privileged-containers"
    is on the protected list. An exception to it may only be created in the
    platform-exceptions namespace, by the platform team, after security review.'
```

**One thing to get right:** the meta-policy is itself a `ClusterPolicy`, so it can be excepted. Put `govern-policy-exceptions` on its own protected list, and — belt and braces — deny exceptions that name it at all:

```yaml
  - name: meta-policy-is-not-exceptable
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    validate:
      failureAction: Enforce
      message: "govern-policy-exceptions cannot be excepted."
      foreach:
      - list: "request.object.spec.exceptions"
        deny:
          conditions:
            any:
            - key: "{{ element.policyName }}"
              operator: Equals
              value: govern-policy-exceptions
```

### 9.4 Expiry — make exceptions self-deleting

Kyverno's cleanup controller honours a TTL label on **any** resource, including its own CRDs. This turns "exceptions accumulate forever" into "exceptions are renewed on purpose."

```yaml
metadata:
  labels:
    cleanup.kyverno.io/ttl: 90d          # relative: 90 days after creation
    # or an absolute instant:
    # cleanup.kyverno.io/ttl: "2026-12-31T23:59:59Z"
```

```console
$ kubectl -n observability get polex allow-hostpath-log-shipper \
    -o jsonpath='{.metadata.creationTimestamp}{"  ttl="}{.metadata.labels.cleanup\.kyverno\.io/ttl}{"\n"}'
2026-08-14T09:41:12Z  ttl=90d

$ kubectl -n kyverno logs deploy/kyverno-cleanup-controller --tail=5 | grep -i policyexception
I0814 09:41:14.882031  1 controller.go:214] cleanup-controller "msg"="resource scheduled for deletion" "gvr"="kyverno.io/v2, Resource=policyexceptions" "namespace"="observability" "name"="allow-hostpath-log-shipper" "deletionTime"="2026-11-12T09:41:12Z"
```

When the exception is deleted, the policy resumes enforcing. Set `allowExistingViolations: true` on the policy (as in §4.1) so that expiry does not immediately break running workloads — the already-admitted DaemonSet keeps running and starts reporting `fail`, which is the signal for the owner to renew or remediate. Without that field, the next update to the workload is rejected, which is a surprising way to discover an exception expired.

Complementary alert (§11) fires when an exception is within seven days of expiry, so renewal is a decision rather than an outage.

---

## 10. Testing exceptions in CI, before they reach a cluster

Exceptions are security-relevant config. They belong in the same test harness as the policies.

Repository layout:

```
policy-tests/
└── disallow-host-path/
    ├── policy.yaml
    ├── resource.yaml            # the log shipper DaemonSet
    ├── resource-violating.yaml  # a DaemonSet mounting /etc, must still be blocked
    ├── exception.yaml
    └── kyverno-test.yaml
```

`kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: disallow-host-path-with-exception
policies:
- policy.yaml
resources:
- resource.yaml
- resource-violating.yaml
exceptions:
- exception.yaml
results:
# The exempted workload is skipped, not passed. Assert the skip explicitly.
- policy: disallow-host-path
  rule: autogen-host-path
  kind: DaemonSet
  resources:
  - node-log-shipper
  result: skip
# The exception must NOT widen to other workloads in the same namespace.
- policy: disallow-host-path
  rule: autogen-host-path
  kind: DaemonSet
  resources:
  - rogue-agent
  result: fail
```

The second assertion is the one that earns its keep: it is a regression test against an over-broad `match` block.

```console
$ kyverno version
Version: 1.13.4
Time: 2026-06-18T11:02:57Z
Git commit ID: 8f0e1c7a6b4d2e9f31c05a7b8e6d4f2a19c3b0d7

$ kyverno test policy-tests/

Loading test  ( policy-tests/disallow-host-path/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Loading exceptions ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│────│──────────────────────│─────────────────────│──────────────────────────────────────│────────│
│ ID │ POLICY               │ RULE                │ RESOURCE                             │ RESULT │
│────│──────────────────────│─────────────────────│──────────────────────────────────────│────────│
│ 1  │ disallow-host-path   │ autogen-host-path   │ apps/v1/DaemonSet/node-log-shipper    │ Pass   │
│ 2  │ disallow-host-path   │ autogen-host-path   │ apps/v1/DaemonSet/rogue-agent         │ Pass   │
│────│──────────────────────│─────────────────────│──────────────────────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

> `RESULT: Pass` in `kyverno test` means *the assertion matched*, not *the policy passed*. Test 1 asserted `skip` and got `skip`; test 2 asserted `fail` and got `fail`. Confusing these is a classic misread.

Ad-hoc evaluation without a test file, useful when iterating on a `conditions` block:

```console
$ kyverno apply policy-tests/disallow-host-path/policy.yaml \
    --resource policy-tests/disallow-host-path/resource.yaml \
    --exception policy-tests/disallow-host-path/exception.yaml \
    --policy-report

Applying 1 policy rule(s) to 1 resource(s)...

pass: 0, fail: 0, warn: 0, error: 0, skip: 1
```

```console
$ kyverno apply policy-tests/disallow-host-path/policy.yaml \
    --resource policy-tests/disallow-host-path/resource.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy disallow-host-path -> resource observability/DaemonSet/node-log-shipper failed:
1. autogen-host-path: validation error: HostPath volumes are forbidden. The field spec.volumes[*].hostPath must be unset. Request an exemption with a PolicyException.

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

Running both — with and without `--exception` — proves the exception is what changed the outcome, and not some unrelated drift in the manifest.

CI gate:

```yaml
# .github/workflows/policy.yaml
name: policy
on: [pull_request]
jobs:
  kyverno-test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: Install Kyverno CLI
      uses: kyverno/action-install-cli@v0.2.0
    - name: Validate manifests parse
      run: kubectl --dry-run=client apply -f policy-tests/ --recursive -o name
    - name: Run policy tests
      run: kyverno test policy-tests/ --detailed-results
    - name: Exceptions must satisfy the meta-policy
      run: |
        kyverno apply policies/govern-policy-exceptions.yaml \
          --resource exceptions/ \
          --policy-report
```

That last step is the important one: it runs the §9 meta-policy against the exception manifests **in the pull request**, so an over-broad exception is rejected in review rather than at `kubectl apply` time.

---

## 11. Verification and failure diagnosis

### 11.1 Ordered triage

Work top to bottom. Each step is cheap and eliminates a whole class of cause.

```console
# 1. Is the feature even on?
$ kubectl -n kyverno get deploy kyverno-admission-controller \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="kyverno")].args}' \
  | tr ',' '\n' | tr -d '[]"' | grep -i exception
--enablePolicyException=true
--exceptionNamespace=

# 2. Does the object exist, in the namespace Kyverno will look at?
$ kubectl get polex -A
NAMESPACE       NAME                         AGE
observability   allow-hostpath-log-shipper   3m21s

# 3. Is the policy actually ready and enforcing?
$ kubectl get cpol disallow-host-path
NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
disallow-host-path   true        true         True    18m   Ready

# 4. What rule name did Kyverno evaluate? (empirical, not guessed)
$ kubectl -n observability get polr -o json \
  | jq -r '.items[].results[] | [.policy, .rule, .result] | @tsv' | sort -u
disallow-host-path	autogen-host-path	skip
disallow-host-path	host-path	skip

# 5. Does the exception name that exact rule?
$ kubectl -n observability get polex allow-hostpath-log-shipper \
    -o jsonpath='{.spec.exceptions}' | jq
[
  {
    "policyName": "disallow-host-path",
    "ruleNames": [
      "host-path",
      "autogen-host-path"
    ]
  }
]

# 6. Anything the controller wants to tell you?
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=200 \
  | grep -i -E 'exception|polex'
```

### 11.2 Symptom table

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| `error: the server doesn't have a resource type "policyexceptions"` | CRD not installed | `kubectl get crd \| grep policyexception` | Install/upgrade the Kyverno chart with `features.policyExceptions.enabled=true` |
| Exception applies cleanly, resource still denied | Feature flag off | §11.1 step 1 | Enable the flag and roll the admission controller |
| Exception exists, is ignored, no errors anywhere | `--exceptionNamespace` confines exceptions to another namespace | §11.1 step 1 — the flag has a non-empty value | Move the exception there, or clear the flag |
| Works for `Pod`, fails for `Deployment`/`DaemonSet` | Missing `autogen-<rule>` in `ruleNames`, or missing the controller kind in `match.kinds` | Compare the denial's rule name to `spec.exceptions[].ruleNames` | Add `autogen-<rule>` (and `autogen-cronjob-<rule>`) and the controller kind |
| Controller object is admitted, its Pods are all rejected | Exempted the controller kind but not `Pod` | `kubectl -n <ns> describe rs\|ds <name>` → `FailedCreate` events quoting the webhook | Add `Pod` to `match.kinds` and the base rule name to `ruleNames` |
| Admission succeeds, PolicyReport still says `fail` | `spec.background: false`, or the background/reports controller cannot read exceptions | `kubectl get polex -o jsonpath='{.spec.background}'`; `kubectl auth can-i list policyexceptions --as=system:serviceaccount:kyverno:kyverno-background-controller -A` | Set `background: true` (removing admission-only variables from `conditions`), or fix controller RBAC |
| Report says nothing at all for the resource | Namespace filtered out at the webhook layer by `resourceFilters` | `kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}'` | Adjust `resourceFilters`; note this is a blunter tool than an exception |
| Exception matches far more than intended | `names: ["*"]`, `kinds: ["*"]`, or a `namespaces` list wider than the object's own namespace | `kubectl get polr -A -o json \| jq -r '.items[].results[] \| select(.result=="skip") \| [.policy,.rule] \| @tsv' \| sort \| uniq -c` | Tighten `match`; enforce the §9 meta-policy |
| Exception worked, stopped working after an upgrade | Stored API version migrated (`v2beta1` → `v2`), or a field was removed | `kubectl get crd policyexceptions.kyverno.io -o jsonpath='{.status.storedVersions}'`; `kubectl explain polex.spec` | Re-apply manifests at the current version; run `kyverno test` against the new CLI in CI |
| Exception was accepted but a `conditions` guard never fires | JMESPath returns empty, making the comparison vacuous | Evaluate the same expression with `jq` against the live object (§7) | Correct the path; add a `!= null` filter and a `\|\| \`[]\`` default, then re-test with `kyverno apply` |
| A denied request names a rule you did not except | The policy has more than one rule, or a second policy matched | Read the full denial body — every failing policy and rule is listed | Add the missing `ruleNames`, or a second entry under `spec.exceptions` |
| `podSecurity` exception has no effect | `controlName` misspelled, or the `images` glob does not match the image reference actually in the Pod | `kubectl -n <ns> get pod <p> -o jsonpath='{.spec.containers[*].image}'` and compare against the glob | Use the exact upstream control name; widen the glob to include registry and tag form |

### 11.3 What "it works" must mean

An exception is verified only when all four hold. Anything less and you have confirmed a coincidence:

1. **The exempted workload is admitted.** `kubectl apply` succeeds, `rollout status` completes.
2. **The exemption is recorded.** A `skip` result naming the exception appears in the PolicyReport — for the controller *and* for its Pods.
3. **The exception did not widen.** A deliberately non-conforming workload in the same namespace, outside the exception's selector, is still denied:

```console
$ kubectl -n observability apply -f /tmp/rogue-agent.yaml
Error from server: error when creating "/tmp/rogue-agent.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource DaemonSet/observability/rogue-agent was blocked due to the following policies

disallow-host-path:
  autogen-host-path: 'validation error: HostPath volumes are forbidden. The field
    spec.volumes[*].hostPath must be unset. Request an exemption with a PolicyException.
    rule autogen-host-path failed at path /spec/template/spec/volumes/0/hostPath/'
```

4. **The exemption reverses.** Delete the exception and confirm the policy resumes:

```console
$ kubectl -n observability delete polex allow-hostpath-log-shipper
policyexception.kyverno.io "allow-hostpath-log-shipper" deleted

$ kubectl -n observability rollout restart ds/node-log-shipper
daemonset.apps/node-log-shipper restarted

$ kubectl -n observability get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail -2
2m          Warning   FailedCreate   daemonset/node-log-shipper   Error creating: admission webhook "validate.kyverno.svc-fail" denied the request: resource Pod/observability/node-log-shipper-x9k2p was blocked due to the following policies

disallow-host-path:
  host-path: 'validation error: HostPath volumes are forbidden...'
```

Step 4 is the one people skip, and it is the one that proves the *policy* was ever doing anything.

### 11.4 Metrics and alerting

```console
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
[1] 21884

$ curl -s localhost:8000/metrics | grep '^kyverno_policy_results_total' | grep 'rule_result="skip"'
kyverno_policy_results_total{policy_background_mode="true",policy_name="disallow-host-path",policy_namespace="",policy_type="ClusterPolicy",policy_validation_mode="enforce",resource_kind="DaemonSet",resource_namespace="observability",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="autogen-host-path",rule_result="skip",rule_type="validate"} 1
kyverno_policy_results_total{policy_background_mode="true",policy_name="disallow-host-path",policy_namespace="",policy_type="ClusterPolicy",policy_validation_mode="enforce",resource_kind="Pod",resource_namespace="observability",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="host-path",rule_result="skip",rule_type="validate"} 6
```

> Metric label sets change across minor releases. Read the real label set once with `curl -s localhost:8000/metrics | grep '^kyverno_policy_results_total' | head -1` before writing recording rules against it, rather than copying label names from documentation.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-exceptions
  namespace: kyverno
spec:
  groups:
  - name: kyverno-exceptions
    rules:

    # A protected control was skipped. This should never happen outside the
    # platform-exceptions namespace; if it does, an exception got past review.
    - alert: KyvernoProtectedPolicySkipped
      expr: |
        sum by (policy_name, rule_name, resource_namespace) (
          increase(kyverno_policy_results_total{
            rule_result="skip",
            policy_name=~"disallow-privileged-containers|restrict-image-registries|verify-image-signatures"
          }[1h])
        ) > 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Protected policy {{ $labels.policy_name }} skipped in {{ $labels.resource_namespace }}"
        description: >-
          Rule {{ $labels.rule_name }} was skipped by a PolicyException.
          Inventory: kubectl get polex -A -o wide

    # Skip volume growing fast usually means an exception widened, not that a
    # new workload appeared.
    - alert: KyvernoExceptionScopeGrowing
      expr: |
        sum by (policy_name, resource_namespace) (
          increase(kyverno_policy_results_total{rule_result="skip"}[24h])
        )
        >
        3 * sum by (policy_name, resource_namespace) (
          increase(kyverno_policy_results_total{rule_result="skip"}[24h] offset 7d)
        )
      for: 30m
      labels:
        severity: warning
      annotations:
        summary: "Exception scope for {{ $labels.policy_name }} tripled in {{ $labels.resource_namespace }}"
```

Pair the metric alerts with a scheduled inventory report, because an exception that is never exercised still exists:

```console
$ kubectl get polex -A -o json | jq -r '
    .items[]
    | [ .metadata.namespace,
        .metadata.name,
        (.metadata.labels["cleanup.kyverno.io/ttl"] // "NO-TTL"),
        (.metadata.annotations["exceptions.platform.example.com/owner"] // "NO-OWNER"),
        ([.spec.exceptions[].policyName] | join(","))
      ] | @tsv' | column -t
gpu-operator    gpu-driver-privileged       30d     platform-gpu@example.com        psa-baseline
observability   allow-hostpath-log-shipper  90d     observability-sre@example.com   disallow-host-path
data-eng        spark-sys-nice              NO-TTL  NO-OWNER                        restrict-capabilities
```

`NO-TTL` / `NO-OWNER` on that last row is an exception created before the meta-policy was enforced — Kyverno validates on admission, so pre-existing objects are not retroactively checked. Backfill by running the meta-policy as a background scan (`spec.background: true` with `failureAction: Audit` on a copy) and triaging the resulting report before switching the enforcing version on.

---

## 12. Version-sensitive surface — check, do not assume

The `PolicyException` API has grown across releases. Rather than memorise a version matrix, verify against the cluster in front of you. Each row below is a one-command check.

| Capability | Verify with |
|---|---|
| Served API versions (`v2alpha1` / `v2beta1` / `v2`) | `kubectl get crd policyexceptions.kyverno.io -o jsonpath='{.spec.versions[*].name}{"\n"}{.status.storedVersions}'` |
| Feature enabled, and confined or not | `kubectl -n kyverno get deploy kyverno-admission-controller -o yaml \| grep -i -E 'enablePolicyException\|exceptionNamespace'` |
| `spec.conditions` available | `kubectl explain polex.spec.conditions` |
| `spec.podSecurity` available | `kubectl explain polex.spec.podSecurity` |
| Which rule types honour exceptions (`validate`, `mutate`, `generate`, `verifyImages`) | Write a two-rule policy, one of each type; except one; read the PolicyReport for `skip` |
| `validate.failureAction` vs `spec.validationFailureAction` | `kubectl explain cpol.spec.rules.validate.failureAction` |
| Exceptions against CEL-based policy types (`spec.policyRefs`) | `kubectl explain polex.spec.policyRefs` — if the field is absent, your release ties exceptions to `policyName` only |
| Interaction with generated `ValidatingAdmissionPolicy` objects | `kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding` and inspect `matchConditions` — a native VAP has no knowledge of the `PolicyException` CRD, so confirm empirically that a workload exempted through Kyverno is also admitted by any generated VAP |

That last row deserves a moment. If your cluster relies on Kyverno generating native `ValidatingAdmissionPolicy` objects for performance, the enforcement path for some policies is the API server's own CEL evaluator, not the Kyverno webhook. Whether an exception is reflected there depends on how Kyverno expresses the exclusion in the generated binding. **Test it. Do not infer it.** The failure mode — a workload the reports say is exempted, denied by a policy object you did not write — is genuinely hard to diagnose from the message alone.

---

## 13. Exam checklist

- `PolicyException` is **namespaced**, short name `polex`, group `kyverno.io`, current version `v2`.
- Required fields: `spec.match` (which resources) and `spec.exceptions[].policyName` + `ruleNames` (which policy rules).
- An exempted resource is reported as **`skip`** — never `pass`, never absent.
- `metadata.namespace` governs **RBAC**; `spec.match` governs **reach**. They are not the same thing, and unconstrained they diverge.
- Workload controllers are validated by **`autogen-<rule>`**; CronJobs by **`autogen-cronjob-<rule>`**. Exempt the controller *and* the Pod, or the Pods will be rejected after the controller is admitted.
- `ruleNames: ["*"]` also exempts rules added to the policy later. Prefer explicit names or an anchored glob.
- `spec.background: false` when `conditions`/`match` reference admission-only context (`request.userInfo`, `request.operation`, subjects/roles). Expect permanent `fail` entries in reports as the price.
- `spec.podSecurity` exempts **one PSS control** (optionally for one image glob and one field value) instead of the whole rule — the highest-precision tool in the CRD.
- Two feature flags decide whether anything happens at all: `--enablePolicyException` and `--exceptionNamespace`.
- Kyverno CLI: `kyverno apply --exception <file>` for ad-hoc evaluation; `exceptions:` in `kyverno-test.yaml` with `result: skip` for CI.
- Exceptions are validated by Kyverno policies like any other resource — the meta-policy is the control that makes self-service safe.
- `cleanup.kyverno.io/ttl` on the exception makes it self-deleting; pair with `allowExistingViolations: true` on the policy so expiry surfaces as a report, not an outage.

---

## Referencias

**Kyverno — official documentation**

- Kyverno documentation home — https://kyverno.io/docs/
- Policy exceptions — https://kyverno.io/docs/writing-policies/exceptions/
- Validate rules and failure actions — https://kyverno.io/docs/writing-policies/validate/
- Auto-generation rules for pod controllers — https://kyverno.io/docs/writing-policies/autogen/
- Match / exclude resource selection — https://kyverno.io/docs/writing-policies/match-exclude/
- Preconditions and JMESPath operators — https://kyverno.io/docs/writing-policies/preconditions/
- JMESPath in Kyverno — https://kyverno.io/docs/writing-policies/jmespath/
- Variables and admission context — https://kyverno.io/docs/writing-policies/variables/
- Policy reports — https://kyverno.io/docs/policy-reports/
- Cleanup policies and the `cleanup.kyverno.io/ttl` label — https://kyverno.io/docs/writing-policies/cleanup/
- Installation and container flags — https://kyverno.io/docs/installation/customization/
- High availability and controller architecture — https://kyverno.io/docs/high-availability/
- Kyverno CLI — `apply` — https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno CLI — `test` — https://kyverno.io/docs/kyverno-cli/usage/test/
- Monitoring and metrics — https://kyverno.io/docs/monitoring/
- Pod Security Standards enforcement with Kyverno — https://kyverno.io/docs/writing-policies/validate/pod-security/
- Kyverno policy library — https://kyverno.io/policies/

**Kyverno — source of truth for the API surface**

- Kyverno repository — https://github.com/kyverno/kyverno
- `PolicyException` Go types (`kyverno.io/v2`) — https://github.com/kyverno/kyverno/blob/main/api/kyverno/v2/policy_exception_types.go
- Kyverno release notes — https://github.com/kyverno/kyverno/releases
- Kyverno Helm chart — https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Kyverno chart on Artifact Hub — https://artifacthub.io/packages/helm/kyverno/kyverno
- Kyverno CLI install action — https://github.com/kyverno/action-install-cli

**Kubernetes upstream**

- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Admission exemptions and configuration — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- Dynamic admission control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- RBAC authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Volumes — `hostPath` — https://kubernetes.io/docs/concepts/storage/volumes/#hostpath

**Standards and curriculum**

- Kubernetes Policy WG — Policy Report CRD (`wgpolicyk8s.io`) — https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report
- CNCF curriculum repository — https://github.com/cncf/curriculum
- KCA curriculum (PDF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf