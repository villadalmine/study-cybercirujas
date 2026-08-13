# 2.2 Kyverno Custom Resource Definitions (CRDs)

## 1. Motivation: policy as a first-class Kubernetes API object

The architectural bet Kyverno makes is that **policy is not a separate language living outside the cluster — it is a Kubernetes resource like any other**. Every Kyverno capability is exposed through a `CustomResourceDefinition`. This is not a cosmetic decision; it is the load-bearing design choice that determines how you operate policy at scale.

The production problem this solves: in a multi-tenant platform with dozens of namespaces and hundreds of workloads, you need governance (require `runAsNonRoot`, block `:latest` tags, force resource limits, auto-generate `NetworkPolicy` for every new namespace). The two historical answers were both painful:

- **Admission webhooks written by hand** (custom Go, a `ValidatingWebhookConfiguration`, a Deployment, a Service, cert rotation). Every rule is code you build, ship, and page on.
- **OPA Gatekeeper**, which is CRD-based but splits the model in two: a `ConstraintTemplate` (Rego logic) plus a `Constraint` (parameters), and you must learn Rego.

Kyverno's answer is that because policies are CRDs, they inherit the *entire* Kubernetes control plane for free:

| Capability | How CRDs give it to you |
|---|---|
| Authoring | Plain YAML — no Rego, no Go. Same shape as a Deployment. |
| Access control | Standard RBAC `Role`/`ClusterRole` on `clusterpolicies.kyverno.io`. |
| Storage & audit | etcd + the API server audit log record every policy change. |
| Tooling | `kubectl get/describe/explain/apply`, `kustomize`, `helm`, ArgoCD, Flux. |
| Validation | The CRD's OpenAPI v3 schema rejects malformed policies at `kubectl apply` time, before the controller ever runs. |
| GitOps | A policy is a manifest in a repo; drift detection and rollback are the same as any workload. |
| Reporting | Results are *also* CRDs (`PolicyReport`), so `kubectl get polr` and Prometheus/Policy Reporter can consume them. |

The consequence for an SRE: **there is no Kyverno-specific query language or state store to learn or back up.** If you know Kubernetes, you already know how to read, secure, diff, and roll back Kyverno policy. The trade-off — spelled out in §2 — is that expressiveness is bounded by what the CRD schema and the JMESPath/CEL engine allow, versus Gatekeeper's Turing-adjacent Rego.

---

## 2. The complete Kyverno CRD landscape

Kyverno ships **three API groups**. Knowing which group owns which kind — and, critically, **who writes each object (you vs. a Kyverno controller)** — is the single most useful mental model for the exam and for debugging.

```
$ kubectl api-resources --api-group=kyverno.io
NAME                     SHORTNAMES   APIVERSION           NAMESPACED   KIND
cleanuppolicies          cleanpol     kyverno.io/v2        true         CleanupPolicy
clustercleanuppolicies   ccleanpol    kyverno.io/v2        false        ClusterCleanupPolicy
clusterpolicies          cpol         kyverno.io/v1        false        ClusterPolicy
globalcontextentries     gctxentry    kyverno.io/v2alpha1  false        GlobalContextEntry
policies                 pol          kyverno.io/v1        true         Policy
policyexceptions         polex        kyverno.io/v2        true         PolicyException
updaterequests           ur           kyverno.io/v2        true         UpdateRequest

$ kubectl api-resources --api-group=reports.kyverno.io
NAME                            APIVERSION              NAMESPACED   KIND
admissionreports                reports.kyverno.io/v1   true         AdmissionReport
backgroundscanreports           reports.kyverno.io/v1   true         BackgroundScanReport
clusteradmissionreports         reports.kyverno.io/v1   false        ClusterAdmissionReport
clusterbackgroundscanreports    reports.kyverno.io/v1   false        ClusterBackgroundScanReport
ephemeralreports                reports.kyverno.io/v1   true         EphemeralReport
clusterephemeralreports         reports.kyverno.io/v1   false        ClusterEphemeralReport

$ kubectl api-resources --api-group=wgpolicyk8s.io
NAME                    SHORTNAMES   APIVERSION                NAMESPACED   KIND
clusterpolicyreports    cpolr        wgpolicyk8s.io/v1alpha2   false        ClusterPolicyReport
policyreports           polr         wgpolicyk8s.io/v1alpha2   true         PolicyReport
```

### 2.1 CRD reference table

| Kind | Group / Version | Scope | You write it? | Purpose |
|---|---|---|---|---|
| **ClusterPolicy** | `kyverno.io/v1` | Cluster | ✅ | The primary policy object; rules apply cluster-wide. |
| **Policy** | `kyverno.io/v1` | Namespaced | ✅ | Same rule schema, scoped to one namespace (tenant self-service). |
| **PolicyException** | `kyverno.io/v2` | Namespaced | ✅ | Carve-outs: exempt specific resources from named rules. |
| **CleanupPolicy** | `kyverno.io/v2` | Namespaced | ✅ | TTL-style scheduled deletion of matching resources. |
| **ClusterCleanupPolicy** | `kyverno.io/v2` | Cluster | ✅ | Same, cluster-wide. |
| **GlobalContextEntry** | `kyverno.io/v2alpha1` | Cluster | ✅ | Cached external/API data shared across policies (avoids per-request API calls). |
| **PolicyReport** | `wgpolicyk8s.io/v1alpha2` | Namespaced | ❌ (controller) | Aggregated pass/fail results per namespace (open CNCF standard). |
| **ClusterPolicyReport** | `wgpolicyk8s.io/v1alpha2` | Cluster | ❌ (controller) | Aggregated results for cluster-scoped resources. |
| **UpdateRequest** | `kyverno.io/v2` | Namespaced | ❌ (controller) | Internal queue driving `generate` and `mutateExisting`. |
| **AdmissionReport** / **BackgroundScanReport** (+ `Cluster*`, `Ephemeral*`) | `reports.kyverno.io/v1` | Both | ❌ (controller) | Intermediate per-resource results that the reports-controller aggregates into `PolicyReport`. |

**The one distinction that matters most:** the top block (`ClusterPolicy` … `GlobalContextEntry`) is **input** you author. The bottom block (`*Report`, `UpdateRequest`, `reports.kyverno.io/*`) is **output/state** written by Kyverno controllers — you read it, you never hand-edit it. Trying to `kubectl edit polr` is a red flag in an interview and a no-op in practice (the controller reconciles it back).

### 2.2 Kyverno CRDs vs. the alternatives

| Dimension | Kyverno CRDs | Gatekeeper CRDs | Hand-rolled webhook |
|---|---|---|---|
| # of CRDs to model one rule | 1 (`ClusterPolicy`) | 2 (`ConstraintTemplate` + `Constraint`) | 0 (but you own the server) |
| Authoring language | YAML + JMESPath/CEL | Rego (in a CRD field) | Go/any |
| Schema validation of the policy itself | Yes (CRD OpenAPI schema) | Partial (Rego is opaque to the schema) | None |
| Mutation | Yes (`mutate`) | Yes (Assign/ModifySet CRDs) | Yes |
| Resource generation | Yes (`generate` + `UpdateRequest`) | No native equivalent | Yes |
| Native reporting CRD | Yes (`PolicyReport`) | Yes (status on Constraint) + `PolicyReport` via export | You build it |
| Learning curve | Low (Kubernetes YAML) | High (Rego) | Very high |

The cost of Kyverno's single-CRD ergonomics is a **larger, deeper CRD schema** — the `ClusterPolicy` OpenAPI schema is one of the biggest in the ecosystem, which creates a real operational gotcha covered in §7 (`kubectl apply` failing on annotation size).

---

## 3. Anatomy of the policy CRDs: `ClusterPolicy` and `Policy`

`ClusterPolicy` and `Policy` share an identical `spec`; they differ only in scope. The `spec` is a list of `rules`, each of which does exactly **one** of: `validate`, `mutate`, `generate`, or `verifyImages`.

A complete, syntactically valid multi-rule policy that exercises the core schema:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: platform-baseline
  annotations:
    policies.kyverno.io/title: Platform Baseline
    policies.kyverno.io/category: Pod Security, Supply Chain
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Baseline guardrails: enforce non-root, mutate default resource
      requests, and auto-generate a default-deny NetworkPolicy per namespace.
spec:
  # Apply/skip background scanning of already-existing resources.
  background: true
  # Cluster-default action; can be overridden per-namespace or per-rule.
  validationFailureAction: Enforce
  validationFailureActionOverrides:
    - action: Audit          # softer in the sandbox namespaces
      namespaces:
        - sandbox-*
  # Webhook behavior if Kyverno itself is unreachable.
  failurePolicy: Fail
  webhookTimeoutSeconds: 10
  # If multiple rules match, evaluate all of them.
  applyRules: All
  rules:
    # ---- RULE 1: validate ----
    - name: require-run-as-non-root
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      validate:
        message: "Containers must set securityContext.runAsNonRoot=true."
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(runAsNonRoot): "true"

    # ---- RULE 2: mutate (defaulting) ----
    - name: default-resource-requests
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                resources:
                  requests:
                    +(memory): "128Mi"
                    +(cpu): "100m"

    # ---- RULE 3: generate (resource provisioning) ----
    - name: default-deny-networkpolicy
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{request.object.metadata.name}}"
        synchronize: true          # keep the generated object reconciled
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

Key schema fields an SRE must recognize:

- **`match` / `exclude`** — selection. Both accept `any` (logical OR of the listed selectors) and `all` (logical AND). Selectors filter by `kinds`, `namespaces`, `names`, `selector` (labels), `annotations`, `operations`, and `subjects`/`roles`/`clusterRoles`.
- **`background`** — when `true`, the rule is also evaluated by the background scan against resources that *already exist*, producing `PolicyReport` entries. `mutate`/`generate` on request-time-only context cannot run in background.
- **`validationFailureAction`** — `Enforce` (block on admission) vs `Audit` (allow, but record a `fail` in the report). In `kyverno.io/v1` it sits at `spec` level; in `v2beta1`/`v2` it moves **into the rule** as `validate.failureAction`. Know both — this is a classic version-skew trap.
- **`failurePolicy`** — `Fail` vs `Ignore`, wired straight into the generated `ValidatingWebhookConfiguration`. `Fail` means "if Kyverno is down, reject the request" (fail-closed).
- **Anchors in patterns** — `=(x)` conditional anchor ("if x exists, it must match"), `+(x)` add-if-absent (mutate), `(x)` matching anchor, `X(...)` global. These are Kyverno's overlay grammar and appear throughout validate/mutate.

The same object as a namespaced `Policy` differs only in `kind` and the presence of a `metadata.namespace`:

```yaml
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: team-a-baseline
  namespace: team-a
spec:
  validationFailureAction: Audit
  rules:
    - name: require-team-label
      match:
        any:
          - resources:
              kinds: [Pod, Deployment, Service]
      validate:
        message: "All resources must carry the 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"      # ?* = non-empty string
```

---

## 4. The auxiliary CRDs, with full manifests

### 4.1 `PolicyException` — governed carve-outs

Exceptions are themselves a CRD, so exempting a workload is an auditable, RBAC-gated, GitOps-tracked act — not an edit to the policy.

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: allow-privileged-monitoring
  namespace: monitoring
spec:
  exceptions:
    - policyName: platform-baseline
      ruleNames:
        - require-run-as-non-root
        - autogen-require-run-as-non-root   # exempt the auto-generated variant too
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - monitoring
          names:
            - node-exporter-*
```

Note the `autogen-*` rule name: Kyverno auto-generates Pod-controller variants of Pod rules (for Deployment/DaemonSet/StatefulSet/Job/CronJob). An exception frequently must name **both** the base rule and its autogen sibling.

### 4.2 `CleanupPolicy` / `ClusterCleanupPolicy` — scheduled deletion

A dedicated CRD (and controller) for time-based deletion — no `validate/mutate/generate` involved.

```yaml
apiVersion: kyverno.io/v2
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-completed-jobs
spec:
  match:
    any:
      - resources:
          kinds:
            - Job
  conditions:
    all:
      - key: "{{ target.status.succeeded || `0` }}"
        operator: Equals
        value: 1
  schedule: "*/10 * * * *"     # standard cron; controller deletes matches each run
```

### 4.3 `GlobalContextEntry` — shared cached data

Introduced to stop every admission request from hammering the API server or an external endpoint. The controller populates and refreshes it; policies read it via `context`.

```yaml
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: deployments-count
spec:
  apiCall:
    urlPath: "/apis/apps/v1/deployments"
    refreshInterval: 10m
```

### 4.4 `PolicyReport` / `ClusterPolicyReport` — the output side

You never author these. A representative object the reports-controller produces:

```yaml
apiVersion: wgpolicyk8s.io/v1alpha2
kind: PolicyReport
metadata:
  name: cpol-platform-baseline
  namespace: team-a
scope:
  apiVersion: v1
  kind: Pod
  name: web-7d9f-xk2p9
summary:
  pass: 2
  fail: 1
  warn: 0
  error: 0
  skip: 0
results:
  - policy: platform-baseline
    rule: require-run-as-non-root
    result: fail
    severity: high
    category: Pod Security
    source: kyverno
    message: "validation error: Containers must set securityContext.runAsNonRoot=true."
    resources:
      - apiVersion: v1
        kind: Pod
        name: web-7d9f-xk2p9
        namespace: team-a
```

Because it conforms to the **CNCF Policy Working Group** open standard (`wgpolicyk8s.io`), the *same* `PolicyReport` object is consumable by Policy Reporter, Trivy-operator, and any WG-compliant tool — not just Kyverno.

### 4.5 The newer CEL-based policy CRDs (Kyverno 1.14+)

Recent Kyverno introduced a parallel family under the **`policies.kyverno.io/v1alpha1`** group that mirrors upstream Kubernetes `ValidatingAdmissionPolicy` and is authored in **CEL** rather than JMESPath overlays: `ValidatingPolicy`, `ImageValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy`, `DeletingPolicy`. Depending on the exam snapshot these may or may not be in scope; recognize that they are *additional* CRDs, not replacements for `ClusterPolicy`.

```yaml
apiVersion: policies.kyverno.io/v1alpha1
kind: ValidatingPolicy
metadata:
  name: require-labels-cel
spec:
  validationActions: [Deny]
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  validations:
    - expression: "has(object.metadata.labels) && 'team' in object.metadata.labels"
      message: "Pods must have a 'team' label."
```

---

## 5. CRD installation, versioning and conversion — the operational layer

CRDs are installed as part of the Kyverno release. The Helm chart splits them out precisely because CRD lifecycle is separate from controller lifecycle:

```
$ helm repo add kyverno https://kyverno.github.io/kyverno/
$ helm install kyverno-crds kyverno/kyverno-crds -n kyverno --create-namespace
$ helm install kyverno kyverno/kyverno -n kyverno
```

Two production realities:

1. **Multiple served versions + a conversion webhook.** `ClusterPolicy` is served at `v1`, `v2beta1`, `v2` simultaneously. A conversion webhook (part of Kyverno) translates between stored and requested versions. If Kyverno's admission Service is unhealthy, **`kubectl get cpol` itself can fail** because the API server cannot convert stored objects — a failure mode that surprises people who assume "reads always work."

2. **CRD schema size.** The `ClusterPolicy` schema is enormous. Applying the CRDs with client-side `kubectl apply` writes the whole prior object into the `last-applied-configuration` annotation and can exceed the 262 144-byte metadata limit:

```
$ kubectl apply -f kyverno-crds.yaml
The CustomResourceDefinition "clusterpolicies.kyverno.io" is invalid:
metadata.annotations: Too long: must have at most 262144 bytes
```

The fix — and the reason the docs mandate it — is **server-side apply**:

```
$ kubectl apply --server-side --force-conflicts -f kyverno-crds.yaml
customresourcedefinition.apiextensions.k8s.io/clusterpolicies.kyverno.io serverside-applied
```

---

## 6. CLI commands and real terminal output

Inspect what exists:

```
$ kubectl get crds | grep -E 'kyverno|wgpolicy'
admissionreports.reports.kyverno.io                  2026-08-10T09:12:44Z
backgroundscanreports.reports.kyverno.io             2026-08-10T09:12:44Z
cleanuppolicies.kyverno.io                           2026-08-10T09:12:44Z
clusteradmissionreports.reports.kyverno.io           2026-08-10T09:12:44Z
clusterbackgroundscanreports.reports.kyverno.io      2026-08-10T09:12:44Z
clustercleanuppolicies.kyverno.io                    2026-08-10T09:12:44Z
clusterpolicies.kyverno.io                           2026-08-10T09:12:44Z
clusterpolicyreports.wgpolicyk8s.io                  2026-08-10T09:12:44Z
globalcontextentries.kyverno.io                      2026-08-10T09:12:44Z
policies.kyverno.io                                  2026-08-10T09:12:44Z
policyexceptions.kyverno.io                          2026-08-10T09:12:44Z
policyreports.wgpolicyk8s.io                         2026-08-10T09:12:44Z
updaterequests.kyverno.io                            2026-08-10T09:12:44Z
```

Confirm a CRD is actually **Established** and **NamesAccepted** (a CRD can exist but not be served):

```
$ kubectl get crd clusterpolicies.kyverno.io \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
NamesAccepted=True
Established=True
```

Discover the schema without leaving the terminal — this is how you learn field names on the exam:

```
$ kubectl explain clusterpolicy.spec.rules.validate
KIND:       ClusterPolicy
VERSION:    kyverno.io/v1

FIELD: validate <Object>

DESCRIPTION:
    Validation is used to validate matching resources.
FIELDS:
  allowExistingViolations   <boolean>
  anyPattern                <Object>
  cel                       <Object>
  deny                      <Object>
  failureAction             <string>
  foreach                   <[]Object>
  message                   <string>
  pattern                   <Object>
  podSecurity               <Object>
```

List policies and their aggregated state:

```
$ kubectl get cpol
NAME                ADMISSION   BACKGROUND   READY   AGE   MESSAGE
platform-baseline   true        true         True    3h    Ready

$ kubectl get polr -A
NAMESPACE   NAME                       KIND   NAME                PASS   FAIL   WARN   ERROR   SKIP   AGE
team-a      cpol-platform-baseline     Pod    web-7d9f-xk2p9      2      1      0      0        0      2h

$ kubectl get cpolr
NAME                   PASS   FAIL   WARN   ERROR   SKIP   AGE
cpol-platform-baseline 14     0      0      0        0      3h
```

Watch the `generate` machinery via its internal CRD:

```
$ kubectl get ur -n kyverno
NAME             POLICY              RULETYPE   RESOURCEKIND   RESOURCENAME   STATE       AGE
ur-8f2kd         platform-baseline   generate   Namespace      team-b         Completed   12s
```

---

## 7. Verification and failure diagnosis

### 7.1 `kubectl apply` fails on CRD annotation size
**Symptom:** `metadata.annotations: Too long: must have at most 262144 bytes` when installing/upgrading CRDs.
**Cause:** Client-side apply stores the entire (huge) schema in `kubectl.kubernetes.io/last-applied-configuration`.
**Fix:** `kubectl apply --server-side --force-conflicts -f <crds>` (or install via the `kyverno-crds` Helm chart). Confirm: the apply prints `serverside-applied`.

### 7.2 `kubectl get cpol` hangs or errors after Kyverno is unhealthy
**Symptom:** `Error from server: conversion webhook for kyverno.io/v1, Kind=ClusterPolicy failed: ... service "kyverno-svc" not found` — even for a plain **read**.
**Cause:** Multiple served versions require the conversion webhook; if the Kyverno admission Service/Pods are down, conversion fails.
**Diagnose:**
```
$ kubectl -n kyverno get pods
$ kubectl get validatingwebhookconfiguration | grep kyverno
$ kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.spec.conversion.strategy}{"\n"}'
Webhook
```
**Fix:** restore the Kyverno admission-controller Deployment/Service; reads recover once the webhook endpoint is reachable.

### 7.3 A policy applies but never blocks or reports
**Checklist:**
```
# 1. Is it Ready and set to Enforce/Audit as intended?
$ kubectl get cpol platform-baseline -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
True
# 2. Did the webhook actually register the rule's resource kinds?
$ kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[*].rules[*].resources}{"\n"}'
# 3. Is background scanning on, if you expect a report for existing resources?
$ kubectl get cpol platform-baseline -o jsonpath='{.spec.background}{"\n"}'
true
# 4. Is there a PolicyException silently exempting the target?
$ kubectl get polex -A
```

### 7.4 CRD version skew after upgrade
**Symptom:** `strict decoding error: unknown field "spec.validationFailureAction"` (field moved into the rule in `v2beta1`/`v2`).
**Cause:** Manifests written for one served version applied against a newer default authoring version.
**Fix:** pin the version you author (`apiVersion: kyverno.io/v1`) or migrate `validationFailureAction` → `validate.failureAction`. Inspect served/stored versions:
```
$ kubectl get crd clusterpolicies.kyverno.io \
    -o jsonpath='{.spec.versions[*].name}  stored={.status.storedVersions}{"\n"}'
v1 v2beta1 v2  stored=[v1]
```

### 7.5 CRD present but not `Established`
**Symptom:** `kubectl get cpol` → `the server doesn't have a resource type "clusterpolicies"` right after install.
**Diagnose:** check the `Established` condition (§6). If `NamesAccepted=False`, a name collision exists; if `Established=False`, the CRD is still registering — wait or reapply.

---

## 8. References

- Kyverno — Custom Resources / API reference: https://kyverno.io/docs/policy-types/
- Kyverno — Policy CRD (`ClusterPolicy`/`Policy`) schema: https://htmlpreview.github.io/?https://github.com/kyverno/kyverno/blob/main/docs/user/crd/index.html
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Kyverno — Policy Exceptions: https://kyverno.io/docs/exceptions/
- Kyverno — Cleanup Policies: https://kyverno.io/docs/policy-types/cleanup-policy/
- Kyverno — Installation (server-side apply requirement for CRDs): https://kyverno.io/docs/installation/
- Kyverno — GlobalContextEntry / external data: https://kyverno.io/docs/policy-types/cluster-policy/external-data-sources/
- CNCF Policy WG — PolicyReport open standard (`wgpolicyk8s.io`): https://github.com/kubernetes-sigs/wg-policy-prototypes
- Kubernetes — CustomResourceDefinitions concept & versioning/conversion: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Kubernetes — Server-Side Apply: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- CNCF Curriculum (KCA): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf