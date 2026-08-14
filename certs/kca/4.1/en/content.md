# 4.1 Applying Policy in Cluster

> **Scope note.** The KCA syllabus version is unspecified, so this material is anchored to the current stable policy surface of Kubernetes (v1.30 / v1.31) and calls out the GA milestone of every primitive. `PodSecurityPolicy` (PSP) was **removed in v1.25** — if you still carry PSP objects, they are inert and must be migrated to the mechanisms below.

---

## 1. Motivation: the architectural problem

### 1.1 The API server is the only write path — so it is the only place policy can be *guaranteed*

Every mutation to cluster state — whether it comes from `kubectl`, a GitOps controller (Argo CD, Flux), a custom operator's reconcile loop, or a compromised service account token — is a write to the `kube-apiserver`, which then persists to `etcd`. Nothing reaches `etcd` without traversing the API server's request pipeline. That pipeline is the **only chokepoint** where a rule can be enforced against *all* writers simultaneously.

This is why "shift-left" alone (linting YAML in CI, `conftest` in a pipeline) is necessary but **not sufficient**. CI validates what *you* push. It does not validate:

- A privileged pod created by an operator reconciling a third-party CRD.
- `kubectl apply` run by an on-call engineer at 03:00 bypassing the pipeline.
- GitOps drift-correction re-applying a manifest an attacker mutated in the repo.
- A workload created by a stolen ServiceAccount token from inside the cluster.

The taxonomy that matters in production is **gates vs. guardrails**:

- **Gate (validating):** reject the request. The bad object never exists. Fail-closed.
- **Guardrail (mutating):** silently repair the request (inject `runAsNonRoot`, add a sidecar, set a default). The object is admitted, corrected.

### 1.2 The admission pipeline (where policy lives)

```
                       kube-apiserver request lifecycle
  ┌──────────────┐   ┌───────────────┐   ┌──────────────────┐   ┌─────────────┐   ┌────────────────────┐   ┌───────┐
  │ Authentication│──▶│ Authorization │──▶│ Mutating admission│──▶│ Schema /    │──▶│ Validating admission│──▶│ etcd  │
  │ (who are you) │   │ (RBAC/ABAC/   │   │ (webhooks +       │   │ OpenAPI     │   │ (PSA, VAP, webhooks,│   │ (write)│
  │               │   │  Node/Webhook)│   │  MutatingAdmPolicy)│  │ validation  │   │  Gatekeeper/Kyverno)│   │       │
  └──────────────┘   └───────────────┘   └──────────────────┘   └─────────────┘   └────────────────────┘   └───────┘
        401                 403               mutate object          422 invalid          403 Forbidden        stored
```

Key ordering facts you will be tested on and will debug in production:

1. **Authorization (RBAC) runs first.** Admission policy assumes the caller was already allowed to perform the verb. RBAC answers *"can this identity do X?"*; admission answers *"is this specific object acceptable?"*. They are complementary policy layers.
2. **Mutation happens before validation.** A mutating webhook or `MutatingAdmissionPolicy` can inject a field that a *later* validating stage then checks. This is why "add a default `securityContext`, then enforce `restricted`" works — but only if ordering holds.
3. **Validating admission is the last line before `etcd`.** If it says `Forbidden`, the object never existed.

### 1.3 The failure modes policy exists to prevent

| Without in-cluster policy | Concrete production consequence |
|---|---|
| Pods run privileged / `hostPID` / `hostPath: /` | Container escape → node root → cluster takeover (lateral movement) |
| No `resources.limits` | One noisy neighbor OOM-kills a node; cascading eviction |
| `:latest` / untagged images | Non-reproducible rollouts, silent version drift, no rollback anchor |
| Flat pod network (no `NetworkPolicy`) | A compromised front-end can reach the database directly |
| No required labels (`owner`, `cost-center`) | Untraceable blast radius, no ownership during an incident |

---

## 2. The policy mechanisms — technical comparison

There are two enforcement *families* and one adjacent authorization layer:

- **In-tree, no network hop:** RBAC, ResourceQuota/LimitRange, **Pod Security Admission (PSA)**, **ValidatingAdmissionPolicy (VAP)**. Evaluated inside the API server process.
- **Out-of-tree admission webhooks:** **OPA Gatekeeper**, **Kyverno**. A network call from the API server to a pod.
- **Dataplane policy:** **NetworkPolicy** — not admission at all; enforced by the CNI at runtime.

### 2.1 Trade-off matrix

| Dimension | RBAC | Pod Security Admission | ValidatingAdmissionPolicy | OPA Gatekeeper | Kyverno | NetworkPolicy |
|---|---|---|---|---|---|---|
| Enforcement point | authz stage | admission (in-tree) | admission (in-tree) | validating **webhook** | validating+mutating **webhook** | CNI dataplane |
| Policy language | none (verbs/resources) | fixed profiles | **CEL** | **Rego** | YAML/JMESPath+CEL | label selectors |
| Can **mutate**? | ✗ | ✗ | ✗ (see MAP §7) | ✗ (assign mutations, beta) | ✓ (native) | n/a |
| Can **generate** resources? | ✗ | ✗ | ✗ | ✗ | ✓ | n/a |
| External dependency / pod to run? | no | no | no | **yes** (controller pods + certs) | **yes** (admission ctlr pods) | CNI plugin |
| Network hop per request (latency) | none | none | none | ~ms + risk | ~ms + risk | none (async) |
| Failure mode | deterministic | fail-closed (in-tree) | `failurePolicy: Fail/Ignore` | webhook `failurePolicy` | webhook `failurePolicy` | fail-closed once a policy selects the pod |
| Availability blast radius | none | none | none | **can wedge the API server** | **can wedge the API server** | none |
| Custom logic / cross-object lookups | no | no | limited (params only) | ✓ (Rego, `data`) | ✓ (API lookups, context) | no |
| GA status | GA | **GA v1.25** | **GA v1.30** | mature (v3.x) | mature (v1.x) | GA |
| Best fit | *who can act* | pod hardening baseline | native, dependency-free validation | complex org constraints, OPA shops | mutate+generate+validate, image verify | east-west segmentation |

### 2.2 How to choose (the decision most teams get wrong)

- **Start with PSA + NetworkPolicy + RBAC.** These are in-tree, free, and cannot be knocked offline. PSA gives you the `restricted` pod-hardening baseline with zero moving parts.
- **Reach for `ValidatingAdmissionPolicy` (CEL) before a webhook** when the rule is *pure validation* ("must set memory limit", "image from approved registry"). It is in-tree — no controller to run, no cert to rotate, no fail-open outage.
- **Reach for Kyverno or Gatekeeper** when you need what CEL/PSA cannot do: **mutation** (inject defaults), **generation** (auto-create a default-deny `NetworkPolicy` per namespace), **image signature verification**, or cross-resource lookups. Kyverno is YAML-native and does mutate+generate; Gatekeeper is Rego and integrates with the wider OPA ecosystem.

> **Architectural rule of thumb:** prefer the mechanism closest to the API server core. Every webhook you add is a new availability dependency for *every write in the cluster*.

---

## 3. Complete, production-grade manifests

### 3.1 Pod Security Admission — namespace opt-in + cluster-wide default

**Per-namespace enforcement** (the three modes are independent: `enforce` rejects, `audit` logs an annotation, `warn` returns a client warning):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    # Hard gate: reject non-compliant pods.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    # Audit trail in the API audit log (does not block).
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
    # Client-facing warning at apply time (does not block).
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
```

**Cluster-wide default** so a *newly created* namespace is not silently unguarded. This is wired into the API server, not applied with `kubectl`:

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"        # cluster-wide floor for namespaces without labels
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: ["kube-system"]   # infra pods that legitimately need privilege
```

The API server is then started with:

```
--admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
```

The three **Pod Security Standards** the labels reference:

| Standard | Meaning | Typical use |
|---|---|---|
| `privileged` | unrestricted | trusted infra / CNI / CSI namespaces |
| `baseline` | blocks known privilege escalations (`hostNetwork`, `privileged`, `hostPath`, most caps) | general workloads |
| `restricted` | hardened: `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `drop: ["ALL"]`, `allowPrivilegeEscalation: false` | regulated / multi-tenant |

### 3.2 ValidatingAdmissionPolicy — native CEL, no webhook (GA v1.30)

**Policy 1 — every container must declare a memory limit.** In-tree, zero external dependencies.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-resource-limits
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: containers
      expression: "object.spec.containers"
  validations:
    - expression: >-
        variables.containers.all(c,
          has(c.resources) && has(c.resources.limits) && has(c.resources.limits.memory))
      message: "every container must set spec.containers[].resources.limits.memory"
      reason: Invalid
```

Bind it — a policy does nothing until a **binding** activates it and declares the action (`Deny` / `Warn` / `Audit`):

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-resource-limits-binding
spec:
  policyName: require-resource-limits
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        policy.example.com/limits: "enforce"
```

**Policy 2 — parameterized allowed-registry check.** The allowed list lives in a `ConfigMap` (`paramKind`), so platform teams change policy data without editing the policy:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: allowed-image-registries
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          params.data['registries'].split(',').exists(r, c.image.startsWith(r)))
      messageExpression: >-
        "container image must come from an approved registry: " + params.data['registries']
      reason: Forbidden
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: approved-registries
  namespace: policy-system
data:
  registries: "registry.example.com/,gcr.io/prod-project/"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: allowed-image-registries-binding
spec:
  policyName: allowed-image-registries
  validationActions: ["Deny", "Audit"]
  paramRef:
    name: approved-registries
    namespace: policy-system
    parameterNotFoundAction: Deny     # fail closed if the ConfigMap is missing
  matchResources:
    namespaceSelector: {}             # all namespaces
```

### 3.3 OPA Gatekeeper — ConstraintTemplate (Rego) + Constraint

Gatekeeper splits the *rule* (a reusable `ConstraintTemplate` that generates a CRD) from the *instance* (a `Constraint` that parameterizes and scopes it):

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels

        violation[{"msg": msg}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("missing required labels: %v", [missing])
        }
```

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: ns-must-have-owner
spec:
  enforcementAction: deny          # deny | dryrun | warn
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Namespace"]
  parameters:
    labels: ["owner"]
```

### 3.4 Kyverno — validate, mutate, generate (the three superpowers)

**Validate** — block mutable image tags:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce   # Enforce = block; Audit = report only
  background: true                    # also scan pre-existing resources
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Using a mutable image tag (':latest' or untagged) is not allowed."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

> Kyverno 1.12+ deprecates spec-level `validationFailureAction` in favour of per-rule `validate.failureAction`. Pin your policy to the installed Kyverno version.

**Mutate** — inject a hardened default `securityContext` (a *guardrail*, not a gate):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-securitycontext
spec:
  rules:
    - name: set-runasnonroot
      match:
        any:
          - resources:
              kinds: ["Pod"]
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              runAsNonRoot: true
              seccompProfile:
                type: RuntimeDefault
```

**Generate** — auto-create a default-deny `NetworkPolicy` in every new namespace (`synchronize` keeps it repaired if someone deletes it):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-networkpolicy
spec:
  rules:
    - name: create-default-deny
      match:
        any:
          - resources:
              kinds: ["Namespace"]
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes: ["Ingress", "Egress"]
```

### 3.5 NetworkPolicy — default-deny + explicit allow

The most important segmentation pattern: deny everything, then re-open exactly what the workload needs. Note that a default-deny egress policy **also blocks DNS**, so you must explicitly re-allow port 53 or every name resolution in the namespace fails:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}                 # selects every pod in the namespace
  policyTypes: ["Ingress", "Egress"]
---
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
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-from-frontend
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8443
```

> `NetworkPolicy` is only enforced if your CNI supports it (Calico, Cilium, Antrea, Weave). With flannel-only, these objects are stored and **silently ignored** — a classic false sense of security. Verify with your CNI, not with `kubectl get netpol`.

### 3.6 The raw primitive — ValidatingWebhookConfiguration

Gatekeeper and Kyverno both register one of these. Understanding it is what lets you *debug an outage* when they misbehave. Two production-critical fields: `failurePolicy` and the `namespaceSelector` that must exclude the webhook's own namespace to avoid a bootstrap deadlock.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-policy.example.com
webhooks:
  - name: image-policy.example.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail            # Fail = block writes if webhook is down (fail-closed)
    timeoutSeconds: 5
    clientConfig:
      service:
        name: image-policy-webhook
        namespace: policy-system
        path: /validate
        port: 443
      caBundle: <base64-encoded-PEM>
    rules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
        scope: Namespaced
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "policy-system"]   # never gate your own controllers
```

---

## 4. CLI and terminal outputs

### 4.1 Pod Security Admission in action

```console
$ kubectl label namespace payments \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/warn=restricted
namespace/payments labeled

$ kubectl -n payments run nginx --image=nginx
Error from server (Forbidden): pods "nginx" is forbidden: violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type
  to "RuntimeDefault" or "Localhost")
```

**Dry-run a stricter policy against a live namespace *before* enforcing it** — this surfaces which existing pods would break, without blocking anything:

```console
$ kubectl label --dry-run=server --overwrite namespace legacy \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "legacy" violate the new PodSecurity enforce level "restricted:latest"
Warning: batch-runner-7f9c: allowPrivilegeEscalation != false, runAsNonRoot != true
namespace/legacy labeled (server dry run)
```

### 4.2 ValidatingAdmissionPolicy

```console
$ kubectl get validatingadmissionpolicy
NAME                        VALIDATIONS   PARAMKIND   AGE
allowed-image-registries    1             ConfigMap   6m
require-resource-limits     1             <unset>     6m

$ kubectl get validatingadmissionpolicybinding
NAME                               POLICYNAME                 PARAMREF              AGE
allowed-image-registries-binding   allowed-image-registries   approved-registries   6m
require-resource-limits-binding    require-resource-limits    <unset>               6m

$ kubectl apply -f pod-nolimits.yaml
Error from server (Forbidden): error when creating "pod-nolimits.yaml": pods "cache" is forbidden:
ValidatingAdmissionPolicy 'require-resource-limits' with binding 'require-resource-limits-binding'
denied request: every container must set spec.containers[].resources.limits.memory
```

### 4.3 Gatekeeper

```console
$ kubectl get constrainttemplate
NAME                AGE
k8srequiredlabels   12m

$ kubectl apply -f ns-noowner.yaml
Error from server (Forbidden): error when creating "ns-noowner.yaml":
admission webhook "validation.gatekeeper.sh" denied the request:
[ns-must-have-owner] missing required labels: {"owner"}

$ kubectl get k8srequiredlabels ns-must-have-owner \
    -o jsonpath='{.status.totalViolations}'
7
```

### 4.4 Kyverno

```console
$ kubectl get cpol
NAME                          ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
add-default-securitycontext   true        true         Audit             True    9m
disallow-latest-tag           true        true         Enforce           True    9m
default-deny-networkpolicy    true        true         Audit             True    9m

$ kubectl -n dev run web --image=nginx:latest
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/dev/web was blocked due to the following policies

disallow-latest-tag:
  require-image-tag: 'validation error: Using a mutable image tag (":latest" or untagged)
    is not allowed. rule require-image-tag failed at path /spec/containers/0/image/'

# Background scan results (does not block; reports on pre-existing resources)
$ kubectl get policyreport -A
NAMESPACE   NAME                                   PASS   FAIL   WARN   ERROR   SKIP   AGE
dev         cpol-disallow-latest-tag               12     3      0      0       0      9m
```

### 4.5 RBAC — the first policy layer

```console
$ kubectl auth can-i create pods --namespace payments \
    --as system:serviceaccount:ci:deployer
yes

$ kubectl auth can-i delete namespaces \
    --as system:serviceaccount:ci:deployer
no
```

---

## 5. Verification and failure diagnosis

### 5.1 Confirm each mechanism is actually wired in

```console
# Is the PodSecurity admission plugin even enabled? (managed clusters vary)
$ kubectl get --raw='/readyz?verbose' | grep -i admission
[+]poststarthook/start-kube-apiserver-admission-initializer ok

# Are policies loaded and bound?
$ kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding
$ kubectl get constrainttemplate,constraints -A
$ kubectl get cpol,polr,cpolr -A

# Is the webhook the API server will call actually registered?
$ kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration
```

### 5.2 The number-one production incident: a webhook wedges the API server

A validating/mutating webhook with `failurePolicy: Fail` whose backing pods are unhealthy will **reject every matching write cluster-wide**, including the writes needed to fix it. Symptoms and triage:

```console
# Symptom: everything times out with a webhook error
$ kubectl apply -f anything.yaml
Error from server (InternalError): Internal error occurred: failed calling webhook
"validate.kyverno.svc-fail": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/validate?timeout=10s": context deadline exceeded

# Triage 1 — is the admission controller alive?
$ kubectl -n kyverno get pods
NAME                                   READY   STATUS             RESTARTS   AGE
kyverno-admission-controller-6d…-x     0/1     CrashLoopBackOff   8          21m

# Triage 2 — break glass: temporarily set the webhook to fail-open, or delete it
$ kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
```

**Design defenses (build these in *before* the incident):**

- Exclude control-plane namespaces (`kube-system`, the policy controller's own namespace) via `namespaceSelector` — §3.6.
- Run controllers HA (≥2 replicas, `PodDisruptionBudget`, anti-affinity).
- Keep `timeoutSeconds` low (5s) so a slow webhook degrades instead of hanging.
- Consider `failurePolicy: Ignore` for *guardrail* mutations and reserve `Fail` for genuine security gates — an explicit availability-vs-security trade-off, not an accident.

### 5.3 Mutation-before-validation ordering bugs

If a Kyverno mutate policy should inject `runAsNonRoot: true` but a PSA `restricted` gate still rejects the pod, the mutation was **not applied first**. Diagnose with server-side dry-run, which runs the *entire* admission chain and returns the final object:

```console
$ kubectl apply --dry-run=server -o yaml -f pod.yaml | grep -A3 securityContext
  securityContext:
    runAsNonRoot: true          # <- present ⇒ mutation ran; absent ⇒ mutate policy didn't match
    seccompProfile:
      type: RuntimeDefault
```

If the field is absent, the mutate policy's `match` block didn't select the resource (wrong `kinds`, namespace excluded, or the controller was down).

### 5.4 Debugging denials methodically

1. **Read the error string** — every mechanism names *itself* and the failing rule (`ValidatingAdmissionPolicy 'X' with binding 'Y'`, `[constraint-name]`, `rule <name> failed at path <json-path>`). The path tells you the exact field.
2. **CEL / Rego logic bugs** — for VAP, test the expression in isolation; `failurePolicy: Fail` means a *compile error in the CEL itself* is reported as a denial, not skipped. Check `kubectl describe validatingadmissionpolicy <name>` for `TypeChecking` warnings.
3. **Audit vs. enforce confusion** — a policy in `audit`/`Audit`/`dryrun` mode does **not** block; it writes to reports/audit log. If "the policy isn't working", first confirm it is in enforcing mode (`validationActions: ["Deny"]`, `enforcementAction: deny`, `validationFailureAction: Enforce`).
4. **Selector scope** — bindings and constraints only act on what their `matchResources` / `match` select. `kubectl get ns --show-labels` to confirm the target namespace carries the label the binding requires.

### 5.5 Verify NetworkPolicy is truly enforced (not just stored)

```console
$ kubectl -n payments run probe --rm -it --image=nicolaka/netshoot -- \
    curl -m 3 http://database.payments.svc:5432
curl: (28) Connection timed out after 3001 milliseconds
command terminated with exit code 28    # <- good: default-deny is enforced by the CNI

# If it CONNECTS despite a default-deny policy, your CNI does not enforce NetworkPolicy.
```

---

## 6. What comes next (trajectory to watch)

- **MutatingAdmissionPolicy (MAP)** — the CEL-native counterpart to VAP for *mutation*, alpha in v1.32. It aims to move default-injection guardrails in-tree, removing the availability risk of mutating webhooks. When it matures, the "Kyverno for a simple default" case weakens the same way VAP already displaced simple validating webhooks.
- **The direction is unmistakable:** push policy *into* the API server (CEL) and out of network-dependent webhooks wherever the logic allows — fewer moving parts, no fail-open outage surface.

---

## Referencias

- Admission controllers reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- CEL in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Dynamic Admission Control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Enforce Pod Security Standards with namespace labels — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Enforce Pod Security Standards by configuring the built-in admission controller — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- RBAC authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Open Policy Agent / Rego — https://www.openpolicyagent.org/docs/latest/
- Kyverno documentation — https://kyverno.io/docs/
- Kyverno policy library — https://kyverno.io/policies/
- KCA / CNCF curriculum — https://github.com/cncf/curriculum