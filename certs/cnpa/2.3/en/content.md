# 2.3 Policy Engines for Platform Governance

> **Exam domain weight: 4.0** — This is a high-weight domain because policy enforcement is the mechanism by which a platform team encodes *organizational intent* into a self-service Kubernetes substrate. On the CNPA exam you are expected to reason about *where* enforcement happens in the request lifecycle, *which* engine fits a governance requirement, and *how* to diagnose a policy layer that is failing open, failing closed, or silently not matching.

---

## 1. The architectural problem: governance at self-service scale

A platform exists to let application teams ship without filing a ticket for every Namespace, Deployment or Ingress. The moment you grant that autonomy, you inherit a governance problem: **thousands of manifests per day, authored by people who do not know your security baseline, landing on a shared control plane.**

RBAC answers *who can perform which verb on which resource*. It does **not** answer:

- "Every Pod must set `runAsNonRoot: true` and drop `ALL` capabilities."
- "No image may be pulled from a registry outside `registry.corp.internal`."
- "Every Namespace must carry an `owner` and `cost-center` label."
- "No Ingress may reuse a host already claimed by another team."
- "Every workload must declare CPU/memory requests so the scheduler and the FinOps team can do their jobs."

These are **admission-time invariants** about the *content* of an object, not about the identity of the requester. RBAC has no vocabulary for them. This is the gap policy engines fill.

### 1.1 The four control points of policy-as-code

Governance is defense-in-depth. The same rule ("no `:latest` tags") should be enforced at several points, because each point catches a different failure mode:

| Control point | When | Engine / tool | What it catches | What it misses |
|---|---|---|---|---|
| **CI / pre-commit** | Before merge | `conftest`, `kyverno test`, `gator verify` | Author feedback in seconds; shifts left | Anything applied out-of-band (e.g. `kubectl` by an operator) |
| **GitOps / PR gate** | On pull request | Same, run in the pipeline | Drift from the declared source of truth | Direct API writes |
| **Admission (cluster)** | On every API write | Gatekeeper, Kyverno, VAP | The last line before `etcd`; catches *everything*, including controllers | Objects that already exist |
| **Runtime / background audit** | Continuously | Gatekeeper audit, Kyverno background scan, PolicyReports | Pre-existing violations, policy drift after a rule change | Nothing at write time (report-only) |

**Key exam insight:** admission control is the only point that is *non-bypassable* for a live cluster — a compromised or careless client cannot skip it, whereas CI checks can be circumvented with a direct `kubectl apply`. But admission control alone cannot tell you how many *existing* objects violate a newly introduced rule; that is what the audit/background layer is for. A mature platform runs the same policy at all four points.

### 1.2 Why this belongs to the platform team, not the app team

Policy-as-code is the contract surface of the platform. The platform team owns the rules; application teams consume a cluster where the rules are already true. This inverts the traditional model (security reviews the manifest after the fact) into a **paved road**: the guardrails are structural, versioned in Git, tested in CI, and enforced automatically.

---

## 2. Mechanics: the Kubernetes admission pipeline

Every policy engine is ultimately a plug into the API server's admission chain. You cannot reason about policy engines without knowing this pipeline cold.

```
                          kube-apiserver request lifecycle
  ┌──────────────┐   ┌───────────────┐   ┌──────────────────────────┐
  │ 1. AuthN     │──▶│ 2. AuthZ      │──▶│ 3. Mutating admission    │
  │ (who?)       │   │ (RBAC/ABAC)   │   │  - MutatingWebhookConfig │
  └──────────────┘   └───────────────┘   │  - MutatingAdmissionPol. │
                                         └────────────┬─────────────┘
                                                      ▼
                                    ┌──────────────────────────────┐
                                    │ 4. Object schema validation  │
                                    │    (OpenAPI, quotas, etc.)   │
                                    └────────────┬─────────────────┘
                                                 ▼
                              ┌────────────────────────────────────────┐
                              │ 5. Validating admission                │
                              │  - ValidatingWebhookConfiguration      │
                              │  - ValidatingAdmissionPolicy (CEL)     │
                              └────────────────┬───────────────────────┘
                                               ▼
                                        ┌─────────────┐
                                        │ 6. etcd     │
                                        └─────────────┘
```

Critical properties that drive every design decision below:

- **Mutating webhooks run before validating webhooks.** A mutating engine can inject a sidecar, add default labels, or set `securityContext`; the validating pass then sees the mutated object. Order within a phase is *not* guaranteed for webhooks (it is roughly `reinvocationPolicy`-dependent), which is why mutation and validation are often split across engines.
- **Webhooks are out-of-process HTTP callbacks.** The API server serializes the `AdmissionReview` and POSTs it to a Service. This introduces a network hop, a TLS handshake, a timeout, and a `failurePolicy` decision — the single largest source of production outages in this domain (§7.2).
- **In-process CEL (`ValidatingAdmissionPolicy`) runs inside the API server.** No network hop, no webhook Pod, no TLS certificate to rotate. It cannot be down independently of the API server. This is the strategic direction Kubernetes is moving.
- **The object is immutable to the client after step 6.** Admission is your last chance to reject or shape it.

---

## 3. Comparative analysis of the engine landscape

There is no single "best" engine — the choice is a set of trade-offs across language model, capabilities, and operational blast radius.

### 3.1 Capability matrix

| Capability | OPA/Gatekeeper | Kyverno | ValidatingAdmissionPolicy (native CEL) | Kubewarden |
|---|---|---|---|---|
| **Policy language** | Rego (declarative logic DSL) | YAML (K8s-native overlays) | CEL expressions | Wasm modules (Rust, Go, …) |
| **Runs as** | Webhook (Pod) | Webhook (Pod) | In-process (API server) | Webhook (Pod) |
| **Validate** | ✅ | ✅ | ✅ | ✅ |
| **Mutate** | ✅ (assign/modify) | ✅ (strong) | ❌ (MutatingAdmissionPolicy is alpha/beta) | ✅ |
| **Generate resources** | ❌ | ✅ (e.g. default NetworkPolicy per NS) | ❌ | ❌ |
| **Verify image signatures** | ⚠️ (via external data) | ✅ (native `verifyImages`, cosign) | ❌ | ✅ |
| **External data at eval time** | ✅ (`sync` cache + external data providers) | ✅ (API calls, context) | ⚠️ (limited; CEL variables, no arbitrary I/O) | ✅ |
| **Background/audit of existing objects** | ✅ (audit controller) | ✅ (background scan → PolicyReport) | ✅ (`Audit` action) | ✅ |
| **Learning curve** | High (Rego) | Low–Medium (YAML) | Medium (CEL) | High (build/ship Wasm) |
| **External dependency to run** | Deployment + certs | Deployment + certs | **None** | Deployment + certs |

### 3.2 When to choose what

| Requirement | Recommended engine | Rationale |
|---|---|---|
| Simple structural validation, no ops footprint | **ValidatingAdmissionPolicy** | In-process, zero webhook to operate, no failure-open/closed dilemma |
| Rich mutation + resource generation (default NetworkPolicies, quotas) | **Kyverno** | Only mainstream engine with first-class `generate` and strong `mutate` |
| Complex cross-object logic, reuse across non-K8s systems (Terraform, APIs, CI) | **OPA/Gatekeeper** | Rego + OPA is a general policy runtime; the same library evaluates non-K8s inputs |
| Supply-chain: enforce signed images, SBOM attestations | **Kyverno** or **Kubewarden** | Native cosign/`verifyImages` |
| Policies shipped as versioned binary artifacts, multi-language authors | **Kubewarden** | Wasm modules distributed via OCI registries |
| A single rule you want everywhere, cheaply | **VAP first, webhook engine for the rest** | Push everything expressible in CEL into the API server; reserve webhooks for what CEL can't do |

**The modern platform pattern (2024+):** use `ValidatingAdmissionPolicy` for everything expressible in CEL (it removes an entire class of outages), and keep one webhook engine (Kyverno or Gatekeeper) for mutation, generation, image verification and cross-object logic. Gatekeeper and Kyverno both can *generate* VAPs from their own policies so you get the in-process performance with your existing authoring model.

---

## 4. OPA / Gatekeeper deep dive

Gatekeeper is a CNCF-graduated project that packages Open Policy Agent as a Kubernetes admission controller, adding the **Constraint Framework**: a two-level model that separates *policy logic* (reusable, written once by the platform team) from *policy configuration* (declarative instances, safe for many teams to author).

### 4.1 Architecture

```
                    ┌──────────────────────────────────────────────┐
   API write ─────▶ │ kube-apiserver                               │
                    │   ValidatingWebhookConfiguration             │
                    │     gatekeeper-validating-webhook-configuration
                    └───────────────┬──────────────────────────────┘
                                    │ AdmissionReview (HTTPS)
                                    ▼
             ┌───────────────────────────────────────────┐
             │ gatekeeper-controller-manager (Pods)       │
             │  ┌─────────────┐   ┌────────────────────┐  │
             │  │ OPA engine  │◀──│ ConstraintTemplate │  │  (Rego → CRD)
             │  │ (Rego eval) │   │ Constraint (CR)    │  │  (parameters)
             │  └─────────────┘   └────────────────────┘  │
             │  ┌────────────────────────────────────────┐│
             │  │ sync cache (Config): replicate objects ││  (cross-object data)
             │  └────────────────────────────────────────┘│
             └───────────────────────────────────────────┘
             ┌───────────────────────────────────────────┐
             │ gatekeeper-audit (Pod): periodically scans │  → constraint .status.violations
             │ existing objects against all constraints   │
             └───────────────────────────────────────────┘
```

- **ConstraintTemplate** — carries a Rego rule *and* an OpenAPI schema for its parameters. Applying it dynamically creates a new CRD (`kind` you name). Written once, by the platform team.
- **Constraint** — a custom resource of that generated kind. It selects target objects (`match`) and passes `parameters`. This is what most teams touch.
- **Config (`sync`)** — tells Gatekeeper to replicate specific object kinds into OPA's in-memory cache so Rego can reason across objects (e.g. "no two Ingresses share a host").
- **Audit controller** — periodically re-evaluates all constraints against live objects and writes violations to each Constraint's `.status`.

### 4.2 Complete manifests — "every Namespace must carry an `owner` label"

**Step 1 — the ConstraintTemplate (policy logic):**

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
  annotations:
    description: >-
      Requires that a set of labels, defined via parameters, are present
      on the matched object.
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
            message:
              type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels

        get_message(parameters, _default) := msg {
          not parameters.message
          msg := _default
        }
        get_message(parameters, _default) := parameters.message {
          parameters.message
        }

        violation[{"msg": msg, "details": {"missing_labels": missing}}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          def_msg := sprintf("you must provide labels: %v", [missing])
          msg := get_message(input.parameters, def_msg)
        }
```

**Step 2 — the Constraint (policy configuration):**

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
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    labels: ["owner"]
    message: "All namespaces must carry an 'owner' label for accountability."
```

### 4.3 Cross-object policy with `sync` — "no duplicate Ingress hosts"

Rego can only see other objects if Gatekeeper replicates them into its cache. First, the `Config`:

```yaml
apiVersion: config.gatekeeper.sh/v1alpha1
kind: Config
metadata:
  name: config
  namespace: gatekeeper-system
spec:
  sync:
    syncOnly:
      - group: "networking.k8s.io"
        version: "v1"
        kind: "Ingress"
```

Then a template whose Rego iterates `data.inventory` (the cache):

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8suniqueingresshost
spec:
  crd:
    spec:
      names:
        kind: K8sUniqueIngressHost
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8suniqueingresshost

        identical(obj, review) {
          obj.metadata.namespace == review.object.metadata.namespace
          obj.metadata.name == review.object.metadata.name
        }

        violation[{"msg": msg}] {
          input.review.object.spec.rules[_].host == host
          other := data.inventory.namespace[_][_]["networking.k8s.io/v1"]["Ingress"][_]
          other.spec.rules[_].host == host
          not identical(other, input.review)
          msg := sprintf("ingress host conflict: %q is already in use", [host])
        }
```

### 4.4 CLI: applying, denials, audit, dry-run rollout

Apply and observe a denial:

```console
$ kubectl apply -f constrainttemplate.yaml
constrainttemplate.templates.gatekeeper.sh/k8srequiredlabels created

$ kubectl apply -f constraint.yaml
k8srequiredlabels.constraints.gatekeeper.sh/ns-must-have-owner created

$ kubectl create namespace team-payments
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
[ns-must-have-owner] All namespaces must carry an 'owner' label for accountability.

$ kubectl create namespace team-payments \
    --dry-run=client -o yaml | \
    kubectl label --local -f - owner=payments -o yaml | kubectl apply -f -
namespace/team-payments created
```

Read the audit results (violations on *pre-existing* objects) from the Constraint status:

```console
$ kubectl get k8srequiredlabels ns-must-have-owner \
    -o jsonpath='{.status.totalViolations}{"\n"}'
7

$ kubectl get k8srequiredlabels ns-must-have-owner -o yaml | yq '.status.violations[0]'
enforcementAction: deny
group: ""
kind: Namespace
message: All namespaces must carry an 'owner' label for accountability.
name: legacy-sandbox
version: v1
```

**Safe rollout pattern** — never introduce a `deny` constraint against a populated cluster. Start with `dryrun`, read the audit, remediate, then flip to `deny`:

```console
$ kubectl patch k8srequiredlabels ns-must-have-owner --type=merge \
    -p '{"spec":{"enforcementAction":"dryrun"}}'
k8srequiredlabels.constraints.gatekeeper.sh/ns-must-have-owner patched

# ... remediate the 7 offenders reported in audit ...

$ kubectl patch k8srequiredlabels ns-must-have-owner --type=merge \
    -p '{"spec":{"enforcementAction":"deny"}}'
```

### 4.5 Shift-left: `gator` in CI

`gator` evaluates Constraints and Templates against manifests *without a cluster* — this is the CI gate:

```console
$ gator test --filename=policy/ --filename=manifests/bad-namespace.yaml
Message: "All namespaces must carry an 'owner' label for accountability."
Constraint: ns-must-have-owner (K8sRequiredLabels)

$ echo $?
1
```

For a full regression suite, `gator verify` runs `Suite` fixtures (assertions of expected allow/deny):

```console
$ gator verify ./policy/...
ok      ./policy/required-labels        0.184s
PASS
```

---

## 5. Kyverno deep dive

Kyverno ("govern" in Greek) takes the opposite design bet from Gatekeeper: **policies are Kubernetes resources authored in YAML**, using overlays and pattern-matching that look like the manifests they govern. No new DSL. In exchange for that accessibility, it is less of a general-purpose logic engine than Rego. Its distinguishing strengths are **mutation, resource generation, and native image verification**.

### 5.1 Rule types

A Kyverno `ClusterPolicy` contains rules; each rule is exactly one of:

- **`validate`** — accept/reject based on a `pattern`, `deny` block, or `cel` expression.
- **`mutate`** — apply a strategic-merge/JSON patch to shape the object.
- **`generate`** — create *other* resources (e.g. a default deny-all `NetworkPolicy` in every new Namespace).
- **`verifyImages`** — verify cosign signatures / attestations on container images.

### 5.2 Validate — "every Pod must set a `team` label and non-root securityContext"

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pod-baseline
spec:
  background: true                 # also evaluate existing Pods → PolicyReport
  rules:
    - name: require-team-label
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        failureAction: Enforce      # Enforce | Audit  (>=1.10; was spec.validationFailureAction)
        message: "The label 'team' is required on every Pod."
        pattern:
          metadata:
            labels:
              team: "?*"            # any non-empty string
    - name: require-run-as-non-root
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        failureAction: Enforce
        message: "Containers must run as non-root."
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(runAsNonRoot): "true"
```

> **Version note:** in Kyverno ≥1.10 the enforcement action moved from the deprecated top-level `spec.validationFailureAction: enforce|audit` to per-rule `validate.failureAction: Enforce|Audit` (note the capitalization change). On the exam, know both spellings; prefer the per-rule form.

### 5.3 Mutate — inject default resource requests

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-requests
spec:
  rules:
    - name: default-container-requests
      match:
        any:
          - resources:
              kinds: ["Pod"]
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"                # for every container...
                resources:
                  requests:
                    +(memory): "128Mi"     # +(...) => add only if absent
                    +(cpu): "100m"
```

### 5.4 Generate — a default-deny NetworkPolicy for every new Namespace

This is the capability neither Gatekeeper nor native VAP has:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-netpol
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
        name: default-deny-ingress
        namespace: "{{request.object.metadata.name}}"
        synchronize: true            # keep in sync; recreate if deleted
        data:
          spec:
            podSelector: {}
            policyTypes: ["Ingress"]
```

### 5.5 Verify images — enforce cosign signatures

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-signed-images
spec:
  rules:
    - name: require-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "registry.corp.internal/*"
          failureAction: Enforce
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...truncated-for-brevity...
                      -----END PUBLIC KEY-----
```

### 5.6 CLI: denials, reports, and the offline test harness

Enforcement denial (note the webhook name suffix `-fail`, indicating `failurePolicy: Fail`):

```console
$ kubectl run nginx --image=nginx:1.27
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/nginx was blocked due to the following policies

pod-baseline:
  require-team-label: 'validation error: The label ''team'' is required on every Pod.
    rule require-team-label failed at path /metadata/labels/team/'
```

Background scan results are surfaced as `PolicyReport` objects — the auditable, machine-readable governance state of the cluster:

```console
$ kubectl get policyreport -A
NAMESPACE     NAME                              PASS   FAIL   WARN   ERROR   SKIP   AGE
default       46e...cpol                        12     3      0      0       0      5m
team-web      46e...cpol                        30     0      0      0       0      5m

$ kubectl get policyreport -n default -o jsonpath=\
'{range .items[0].results[?(@.result=="fail")]}{.policy}{" -> "}{.rule}{" @ "}{.resources[0].name}{"\n"}{end}'
pod-baseline -> require-team-label @ legacy-app-1
pod-baseline -> require-run-as-non-root @ legacy-app-1
pod-baseline -> require-team-label @ debug-pod
```

Offline CI harness with `kyverno-cli`:

```console
$ kyverno apply pod-baseline.yaml --resource=manifests/deploy.yaml --policy-report

Applying 2 policy rule(s) to 1 resource(s)...

policy pod-baseline -> resource default/Deployment/web failed:
  1. require-team-label: validation error: The label 'team' is required on every Pod.

pass: 1, fail: 1, warn: 0, error: 0, skip: 0

$ kyverno test ./tests/
Executing pod-baseline-test...
│ ID │ POLICY       │ RULE               │ RESOURCE            │ RESULT │
│ 1  │ pod-baseline │ require-team-label │ Pod/good-pod        │ Pass   │
│ 2  │ pod-baseline │ require-team-label │ Pod/bad-pod         │ Pass   │
Test Summary: 2 tests passed and 0 tests failed
```

---

## 6. Native in-process policy: ValidatingAdmissionPolicy (CEL)

Since Kubernetes **1.30 (GA)**, `ValidatingAdmissionPolicy` (VAP) lets you enforce rules **inside the API server** using the Common Expression Language (CEL). There is no webhook Pod, no Service, no TLS certificate, and — critically — **nothing that can be down independently of the API server itself.** This eliminates the failure-open/failure-closed dilemma (§7.2) for any rule you can express in CEL.

The model splits into three resources:

- **`ValidatingAdmissionPolicy`** — the logic (`validations` = CEL expressions) and what it matches (`matchConstraints`).
- **`ValidatingAdmissionPolicyBinding`** — activates the policy, scopes it (`matchResources`), and chooses the action (`Deny` / `Warn` / `Audit`).
- **(optional) a `paramKind` object** — externalized parameters, so one policy is reused with different thresholds per environment.

### 6.1 Complete manifests — parameterized replica ceiling

**Parameter CRD + instances:**

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: replicalimits.rules.example.com
spec:
  group: rules.example.com
  scope: Cluster
  names:
    plural: replicalimits
    singular: replicalimit
    kind: ReplicaLimit
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            maxReplicas:
              type: integer
---
apiVersion: rules.example.com/v1
kind: ReplicaLimit
metadata:
  name: replica-limit-prod
spec:
  maxReplicas: 20
```

**The policy:**

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "deployment-replica-limit"
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: rules.example.com/v1
    kind: ReplicaLimit
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  variables:
    - name: replicas
      expression: "object.spec.replicas"
  validations:
    - expression: "variables.replicas <= params.maxReplicas"
      messageExpression: >-
        "Deployment replicas (" + string(variables.replicas) +
        ") exceeds the limit of " + string(params.maxReplicas) + "."
      reason: Invalid
```

**The binding (activation + scope + action):**

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "deployment-replica-limit-binding"
spec:
  policyName: "deployment-replica-limit"
  validationActions: ["Deny"]        # Deny | Warn | Audit (combinable)
  paramRef:
    name: "replica-limit-prod"
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: production
```

### 6.2 CLI behaviour

```console
$ kubectl create deployment web --image=nginx --replicas=30 -n prod-ns
error: failed to create deployment: deployments.apps "web" is forbidden:
ValidatingAdmissionPolicy 'deployment-replica-limit' with binding
'deployment-replica-limit-binding' denied request: Deployment replicas (30)
exceeds the limit of 20.
```

Switch a binding to non-blocking `Audit`/`Warn` for a safe rollout — violations surface as an API-server audit annotation and a client-side warning without blocking:

```console
$ kubectl patch validatingadmissionpolicybinding deployment-replica-limit-binding \
    --type=merge -p '{"spec":{"validationActions":["Warn","Audit"]}}'

$ kubectl create deployment web --image=nginx --replicas=30 -n prod-ns
Warning: Deployment replicas (30) exceeds the limit of 20.
deployment.apps/web created
```

### 6.3 Trade-offs vs webhook engines

| Dimension | ValidatingAdmissionPolicy (CEL) | Webhook engine (Gatekeeper/Kyverno) |
|---|---|---|
| **Operational footprint** | None — part of the API server | Deployment, Service, cert rotation, HPA |
| **Failure mode** | Cannot fail independently of API server | `failurePolicy` dilemma (open vs closed) |
| **Latency** | In-process (µs–ms) | Network round-trip per request |
| **Expressiveness** | CEL: no arbitrary I/O, limited cross-object | Full logic, external data, mutation, generation |
| **Mutation / generation** | ❌ (Mutating*Policy* still maturing) | ✅ |
| **Best for** | Structural invariants, thresholds, field constraints | Everything CEL can't do |

> **Emerging:** `MutatingAdmissionPolicy` (CEL-based in-process mutation using apply-configuration/JSON-patch) entered alpha in 1.32 and is progressing through beta. Watch it — it is the piece that will let platforms retire mutating webhooks too.

---

## 7. Verification and failure diagnosis

This is where platform engineers earn their keep. A policy layer has three failure modes: it **fails open** (lets bad things through), it **fails closed** (blocks everything, including the cluster's own controllers), or it **silently doesn't match** (looks installed, enforces nothing).

### 7.1 Confirm the webhook is actually wired

A policy that isn't in a webhook configuration does nothing. Verify the plumbing before debugging the logic:

```console
$ kubectl get validatingwebhookconfigurations
NAME                                          WEBHOOKS   AGE
gatekeeper-validating-webhook-configuration   1          40d
kyverno-resource-validating-webhook-cfg       1          22d

$ kubectl get validatingwebhookconfiguration \
    kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].failurePolicy}{"\n"}{.webhooks[0].timeoutSeconds}{"\n"}'
Fail
10

# The self-exemption that prevents lockout — is Kyverno/Gatekeeper's own namespace excluded?
$ kubectl get validatingwebhookconfiguration \
    kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].namespaceSelector}{"\n"}'
{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["kyverno","kube-system"]}]}
```

### 7.2 The `failurePolicy` outage — the classic production incident

This is the single most important operational lesson in this domain, and a likely exam scenario.

A validating webhook has `failurePolicy: Fail | Ignore`:

- **`Fail` (fail-closed):** if the webhook Pod is unreachable/times out, the API server **rejects the request**. Secure, but if the webhook is down, *nothing can be admitted* — including the webhook's own Pods, node bootstrap objects, and cluster autoscaling. A crash-looping policy Pod can brick the entire cluster.
- **`Ignore` (fail-open):** if the webhook is unreachable, the request is **admitted without policy evaluation**. Available, but during an outage your guardrails silently vanish.

The symptom of a fail-closed lockout:

```console
$ kubectl create namespace anything
Error from server (InternalError): Internal error occurred: failed calling
webhook "validate.kyverno.svc-fail": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/validate/fail?timeout=10s":
dial tcp 10.96.0.42:443: connect: connection refused
```

**Diagnosis and mitigations:**

1. **Confirm the engine Pods are healthy** — a lockout is almost always the webhook backend being down:
   ```console
   $ kubectl get pods -n kyverno
   NAME                                READY   STATUS             RESTARTS   AGE
   kyverno-admission-controller-...    0/1     CrashLoopBackOff   8          14m
   ```
2. **Always exclude control-plane and the engine's own namespace** via `namespaceSelector`/`objectSelector` (shown in §7.1). Gatekeeper and Kyverno ship this exclusion by default — never remove it.
3. **Bound the blast radius of `Fail`** with a tight `timeoutSeconds` (5–10s) and run the engine HA (≥3 replicas, `PodDisruptionBudget`, anti-affinity across nodes).
4. **Emergency break-glass** — if you are locked out, delete the webhook configuration to restore the API, then fix the backend:
   ```console
   $ kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg
   validatingwebhookconfiguration.admissionregistration.k8s.io "kyverno-resource-validating-webhook-cfg" deleted
   # API writes flow again; the engine re-creates the config once its Pods recover.
   ```
5. **Prefer VAP for eligible rules** — an in-process CEL policy has no independent failure mode, sidestepping this entire class of incident.

### 7.3 "The policy isn't firing" — silent non-match

If applies are *not* being blocked when they should be, the match scope is wrong. Walk the funnel:

```console
# 1. Is the policy Ready/without errors?
$ kubectl get clusterpolicy pod-baseline
NAME           ADMISSION   BACKGROUND   READY   AGE
pod-baseline   true        true         True    3d

# 2. Gatekeeper: did the ConstraintTemplate compile? (bad Rego => no CRD, silent no-op)
$ kubectl get constrainttemplate k8srequiredlabels \
    -o jsonpath='{.status.created}{"\n"}{.status.byPod[0].errors}{"\n"}'
true

# 3. Is the target namespace excluded by a selector you forgot about?
$ kubectl get namespace team-web --show-labels
NAME       STATUS   AGE   LABELS
team-web   Active   9d    environment=production,kubernetes.io/metadata.name=team-web

# 4. VAP: is a Binding actually pointing at the policy? A policy with no binding is inert.
$ kubectl get validatingadmissionpolicybinding \
    -o jsonpath='{range .items[*]}{.spec.policyName}{"\n"}{end}'
deployment-replica-limit
```

Common root causes: (a) a `ValidatingAdmissionPolicy` with **no binding** (inert by design); (b) `namespaceSelector`/`excludedNamespaces` excluding the target; (c) `operations` missing `UPDATE` so edits slip through; (d) Gatekeeper template Rego that failed to compile (the CRD is never created and the constraint silently does nothing).

### 7.4 Unit-testing policies before they reach a cluster

| Engine | Command | What it proves |
|---|---|---|
| OPA (Rego) | `opa test policy/ -v` | Rego logic against synthetic `input` |
| Gatekeeper | `gator verify ./suite/...` | Constraints+Templates against allow/deny fixtures |
| Kyverno | `kyverno test ./tests/` | Policies against resource+expectation manifests |
| Any (CI) | `conftest test manifests/ -p policy/` | Rego over arbitrary structured files (K8s, Terraform, Dockerfile) |

```console
$ opa test policy/ -v
policy/required_labels_test.rego:
data.k8srequiredlabels.test_missing_owner_denied: PASS (1.2ms)
data.k8srequiredlabels.test_owner_present_allowed: PASS (0.9ms)
--------------------------------------------------------------------------------
PASS: 2/2
```

### 7.5 Observability — the governance you can graph

Both webhook engines expose Prometheus metrics; the platform team should alert on rejection rate and audit backlog:

- **Gatekeeper:** `gatekeeper_violations`, `gatekeeper_constraints`, `gatekeeper_request_duration_seconds`, `gatekeeper_audit_last_run_time`.
- **Kyverno:** `kyverno_admission_requests_total`, `kyverno_policy_results_total{policy_validation_mode, rule_result}`, `kyverno_admission_review_duration_seconds`.
- **VAP:** API-server metrics `apiserver_validating_admission_policy_check_total` and `..._check_duration_seconds`.

```console
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
$ curl -s localhost:8000/metrics | grep kyverno_policy_results_total | head -3
kyverno_policy_results_total{policy_name="pod-baseline",rule_result="fail",...} 42
kyverno_policy_results_total{policy_name="pod-baseline",rule_result="pass",...} 1830
```

A sudden spike in `rule_result="fail"` after a policy change is your early warning that a new rule is too aggressive — read it *before* teams start filing tickets.

---

## 8. Production patterns checklist

- **Defense in depth:** the same rule in CI (`conftest`/`kyverno test`/`gator`), in the PR gate, at admission, and in the background audit.
- **Never introduce `deny` cold:** roll out as `dryrun`/`Audit`/`Warn`, read the report, remediate existing violations, then enforce.
- **Push everything CEL-expressible into `ValidatingAdmissionPolicy`;** reserve webhook engines for mutation, generation, image verification and cross-object logic.
- **Protect the platform from itself:** exclude `kube-system` and the engine's own namespace; run the engine HA with a `PodDisruptionBudget`; keep `timeoutSeconds` tight; know the break-glass (delete the webhook config).
- **Everything in Git, everything tested:** policies are code — versioned, reviewed, unit-tested, and delivered by the same GitOps pipeline as workloads.
- **Exemptions are explicit and auditable:** use structured exclusion (labels, `excludedNamespaces`, `paramRef` scoping), never ad-hoc edits to the enforcing resource.

---

## Referencias

- CNPA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes — Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — Dynamic Admission Control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — Mutating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- Kubernetes — Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Open Policy Agent — Documentation — https://www.openpolicyagent.org/docs/latest/
- OPA Gatekeeper — Documentation — https://open-policy-agent.github.io/gatekeeper/website/docs/
- OPA Gatekeeper — `gator` CLI — https://open-policy-agent.github.io/gatekeeper/website/docs/gator/
- Kyverno — Documentation — https://kyverno.io/docs/
- Kyverno — Writing Policies — https://kyverno.io/docs/writing-policies/
- Kyverno — Policy Reports — https://kyverno.io/docs/policy-reports/
- Kyverno CLI — https://kyverno.io/docs/kyverno-cli/
- Kubewarden — Documentation — https://docs.kubewarden.io/
- Conftest — https://www.conftest.dev/
- Kubernetes Policy Working Group — PolicyReport CRD — https://github.com/kubernetes-sigs/wg-policy-prototypes