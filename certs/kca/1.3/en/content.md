# Admission Controllers

> **KCA · Domain 1 · Topic 1.3** — Exam weight: **4.5**
> Level: Production SRE / Platform Architect

---

## 1. The architectural problem: why the API server is not enough

Authentication answers *who* is calling. Authorization (RBAC, ABAC, Node, Webhook) answers *what verbs on what resources* the caller may use. Neither answers the question that dominates real production incidents:

> "This request is authenticated and authorized, but should the resulting object be **allowed to exist as written**, and if not, can we **fix it** before it is persisted?"

RBAC is coarse: it grants `create pods` in a namespace or it does not. It cannot express "you may create Pods, but only from registries under `registry.corp.internal`, never as root, always with resource limits, and every Pod must carry a `cost-center` label." That policy is a property of the *object payload*, and RBAC never inspects the payload.

Admission controllers are the enforcement point where the API server inspects and optionally rewrites the payload, after authZ and before the write to etcd. They are the last synchronous gate in the write path. Everything downstream — the scheduler, kubelet, controllers — trusts that whatever reached etcd already satisfies cluster policy. If a non-compliant object lands in etcd, no admission logic will ever re-examine it; you are now doing detection-and-remediation instead of prevention.

### The request path

```
                    kube-apiserver request lifecycle (write path)
  ┌──────────────┐   ┌───────────────┐   ┌───────────────────────────────────────┐
  │  HTTP handler│──▶│ Authentication│──▶│ Authorization (RBAC / Node / Webhook)  │
  └──────────────┘   └───────────────┘   └───────────────────────────────────────┘
          │
          ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │ MUTATING ADMISSION (in fixed internal order)                                   │
  │   built-in mutating plugins (ServiceAccount, DefaultStorageClass, LimitRanger, │
  │   Priority, RuntimeClass...) + MutatingAdmissionWebhook + MutatingAdmissionPolicy│
  └──────────────────────────────────────────────────────────────────────────────┘
          │  (object may now differ from what the client sent)
          ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │ OBJECT SCHEMA VALIDATION + defaulting (OpenAPI / structural schema)            │
  └──────────────────────────────────────────────────────────────────────────────┘
          │
          ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │ VALIDATING ADMISSION (in fixed internal order, run in parallel where possible) │
  │   built-in validating plugins (PodSecurity, ResourceQuota, NamespaceLifecycle) │
  │   + ValidatingAdmissionPolicy (CEL) + ValidatingAdmissionWebhook               │
  └──────────────────────────────────────────────────────────────────────────────┘
          │  any single reject => whole request fails (atomic)
          ▼
  ┌──────────────┐
  │    etcd      │  persisted
  └──────────────┘
```

Two invariants a Platform Architect must internalize:

1. **Mutation always precedes validation.** You cannot validate the final object until every mutator has run. That is why a mutating webhook that injects a sidecar runs *before* the validating webhook that verifies the sidecar is present.
2. **Validation is a logical AND.** A request is admitted only if **every** validating stage says yes. A single reject anywhere aborts the entire write — the object is never partially created.

---

## 2. Taxonomy: the three generations of admission control

There are three fundamentally different implementation mechanisms. Choosing among them is the core design decision of this topic.

| Mechanism | Where it runs | Language | Latency added | Availability risk | Typical use |
|---|---|---|---|---|---|
| **Compiled-in plugins** | Inside kube-apiserver | Go (shipped w/ k8s) | ~0 (in-process) | None (part of apiserver) | Cluster-wide defaults, quotas, PodSecurity, ServiceAccount injection |
| **Dynamic admission webhooks** | External HTTPS pod(s) | Any (Go, Rust, Rego, JS…) | 1 network round-trip per matching request (≤30s) | **High** — a down webhook with `failurePolicy: Fail` can freeze the API | Org-specific policy, cross-object logic, external data lookups |
| **CEL policies (`ValidatingAdmissionPolicy` / `MutatingAdmissionPolicy`)** | Inside kube-apiserver | CEL expressions in CRs | ~0 (in-process) | None (no external pod) | Declarative, self-contained validation & simple mutation without operating a webhook |

### 2.1 Compiled-in plugins

Enabled/disabled with kube-apiserver flags. The **order in the flag string is irrelevant** — the API server executes plugins in a fixed hard-coded order.

```bash
$ ps -ef | grep kube-apiserver | tr ' ' '\n' | grep admission
--enable-admission-plugins=NodeRestriction,PodSecurity,ResourceQuota
--disable-admission-plugins=DefaultTolerationSeconds
--admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
```

Inspect what is compiled in and on by default:

```bash
$ kube-apiserver -h | grep -A3 'enable-admission-plugins'
--enable-admission-plugins strings
    admission plugins that should be enabled in addition to default enabled ones
    (NamespaceLifecycle, LimitRanger, ServiceAccount, TaintNodesByCondition,
    PodSecurity, Priority, DefaultTolerationSeconds, DefaultStorageClass,
    StorageObjectInUseProtection, PersistentVolumeClaimResize, RuntimeClass,
    CertificateApproval, CertificateSigning, ClusterTrustBundleAttest,
    CertificateSubjectRestriction, DefaultIngressClass, MutatingAdmissionWebhook,
    ValidatingAdmissionPolicy, ValidatingAdmissionWebhook, ResourceQuota).
    Comma-delimited list...
```

Two entries in that default list are the **plumbing** for everything in §2.2 and §2.3: `MutatingAdmissionWebhook` and `ValidatingAdmissionWebhook`. If either is disabled, your webhooks are silently ignored — no error, they simply never fire. `ValidatingAdmissionPolicy` is likewise the plumbing for CEL policies.

### 2.2 Dynamic admission webhooks

Two configuration kinds, both `admissionregistration.k8s.io/v1`:

- `MutatingWebhookConfiguration` — may return a JSON Patch to rewrite the object.
- `ValidatingWebhookConfiguration` — may only allow or deny (plus warnings).

The API server serializes the incoming object into an `AdmissionReview` (`admission.k8s.io/v1`), POSTs it over TLS to your endpoint, and reads an `AdmissionReview` back.

### 2.3 CEL policies

`ValidatingAdmissionPolicy` (GA in v1.30) and `MutatingAdmissionPolicy` (alpha in v1.32, beta in v1.34) let you express policy as CEL expressions evaluated *inside* the API server. No webhook pod, no TLS, no network hop, no availability coupling. This is the modern default for policy that does not need external data.

---

## 3. Mutating vs Validating — the decision that trips people up

| Property | Mutating | Validating |
|---|---|---|
| May change the object? | **Yes** (returns JSON Patch) | No |
| May reject the object? | Yes (but discouraged — reject in validation) | Yes |
| Runs in which phase? | First phase | Second phase |
| Ordering within phase guaranteed? | **No** — treat as unordered | No |
| Re-invocation possible? | Yes, if `reinvocationPolicy: IfNeeded` | Never |
| Can observe other mutators' output? | Only after re-invocation | Always sees final object |
| Idempotency requirement | **Mandatory** | N/A (read-only) |

**The re-invocation trap.** Mutating webhooks within a phase run in an **unspecified order**, and a later mutator can change something an earlier one already inspected. With `reinvocationPolicy: IfNeeded`, the API server may call your mutating webhook **a second time** after other webhooks have mutated the object. Therefore every mutating webhook **must be idempotent**: applying it to its own output must produce no further change. A webhook that appends a sidecar container without first checking whether that sidecar already exists will inject it twice.

**Rule of thumb:** mutate to *default and inject*; validate to *enforce and reject*. Do not reject inside a mutating webhook if you can avoid it — a clean split makes failures far easier to reason about and lets you set different `failurePolicy` values per concern.

---

## 4. The AdmissionReview wire protocol

Every webhook speaks this contract. Understanding it is what separates operating webhooks from merely installing them.

**Request the API server sends (mutating example):**

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "request": {
    "uid": "b4e3a9f2-6a1c-4f7e-9d0a-2c8f1e5b7a90",
    "kind": {"group": "", "version": "v1", "kind": "Pod"},
    "resource": {"group": "", "version": "v1", "resource": "pods"},
    "namespace": "payments",
    "operation": "CREATE",
    "userInfo": {"username": "system:serviceaccount:ci:deployer",
                 "groups": ["system:serviceaccounts", "system:authenticated"]},
    "object": { "kind": "Pod", "metadata": {"name": "api-7c9"}, "spec": {"...": "..."} },
    "oldObject": null,
    "dryRun": false,
    "options": {"kind": "CreateOptions", "apiVersion": "meta.k8s.io/v1"}
  }
}
```

**Response your webhook must return** — note `uid` **must echo** the request `uid`, or the API server rejects the response:

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "b4e3a9f2-6a1c-4f7e-9d0a-2c8f1e5b7a90",
    "allowed": true,
    "patchType": "JSONPatch",
    "patch": "W3sib3AiOiJhZGQiLCJwYXRoIjoiL21ldGFkYXRhL2xhYmVscy9pbmplY3RlZCIsInZhbHVlIjoidHJ1ZSJ9XQ=="
  }
}
```

That `patch` is **base64-encoded JSON Patch (RFC 6902)**. Decoded:

```bash
$ echo 'W3sib3AiOiJhZGQiLCJwYXRoIjoiL21ldGFkYXRhL2xhYmVscy9pbmplY3RlZCIsInZhbHVlIjoidHJ1ZSJ9XQ==' | base64 -d | jq
[
  {
    "op": "add",
    "path": "/metadata/labels/injected",
    "value": "true"
  }
]
```

**A denial** carries a structured status the client sees verbatim:

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "b4e3a9f2-6a1c-4f7e-9d0a-2c8f1e5b7a90",
    "allowed": false,
    "status": {
      "code": 403,
      "message": "image registry docker.io is not in the allowlist [registry.corp.internal]"
    }
  }
}
```

---

## 5. Production build: a validating webhook that enforces image provenance

Goal: reject any Pod whose containers pull from outside `registry.corp.internal`. This is the canonical supply-chain guardrail.

### 5.1 The webhook server (Go, trimmed to the admission logic)

```go
package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const allowedPrefix = "registry.corp.internal/"

func handleValidate(w http.ResponseWriter, r *http.Request) {
	var review admissionv1.AdmissionReview
	if err := json.NewDecoder(r.Body).Decode(&review); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	req := review.Request

	var pod corev1.Pod
	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		writeResponse(w, req.UID, false, "cannot decode Pod: "+err.Error())
		return
	}

	all := append(pod.Spec.InitContainers, pod.Spec.Containers...)
	for _, c := range all {
		if !strings.HasPrefix(c.Image, allowedPrefix) {
			msg := fmt.Sprintf("container %q uses disallowed image %q; only %s* is permitted",
				c.Name, c.Image, allowedPrefix)
			writeResponse(w, req.UID, false, msg)
			return
		}
	}
	writeResponse(w, req.UID, true, "")
}

func writeResponse(w http.ResponseWriter, uid string, allowed bool, msg string) {
	resp := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{APIVersion: "admission.k8s.io/v1", Kind: "AdmissionReview"},
		Response: &admissionv1.AdmissionResponse{UID: uid, Allowed: allowed},
	}
	if !allowed {
		resp.Response.Result = &metav1.Status{Code: 403, Message: msg}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/validate", handleValidate)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	srv := &http.Server{
		Addr:      ":8443",
		Handler:   mux,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}
	// Certs mounted by cert-manager into the pod.
	srv.ListenAndServeTLS("/tls/tls.crt", "/tls/tls.key")
}
```

### 5.2 TLS: the caBundle problem

The API server will only talk to a webhook over HTTPS, and it must trust the server certificate. The CA that signed the webhook's serving cert has to be pinned in the `caBundle` field of the configuration. In production you delegate this to **cert-manager** with the `ca-injector`, which watches the configuration and writes the `caBundle` for you.

```yaml
# certificate issued by an internal CA ClusterIssuer, mounted into the webhook pod
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: image-guard-tls
  namespace: policy-system
spec:
  secretName: image-guard-tls
  dnsNames:
    - image-guard.policy-system.svc
    - image-guard.policy-system.svc.cluster.local
  issuerRef:
    name: internal-ca
    kind: ClusterIssuer
  duration: 2160h      # 90d
  renewBefore: 360h    # 15d
```

### 5.3 Deployment + Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: image-guard
  namespace: policy-system
spec:
  replicas: 3                      # HA is not optional for a Fail-closed webhook
  selector:
    matchLabels: {app: image-guard}
  template:
    metadata:
      labels: {app: image-guard}
    spec:
      topologySpreadConstraints:   # never lose all replicas to one node/zone
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: {app: image-guard}
      containers:
        - name: server
          image: registry.corp.internal/policy/image-guard:v1.4.2
          args: ["--tls-cert=/tls/tls.crt", "--tls-key=/tls/tls.key"]
          ports:
            - {containerPort: 8443, name: https}
          readinessProbe:
            httpGet: {path: /healthz, port: 8443, scheme: HTTPS}
            periodSeconds: 5
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits:   {cpu: 500m, memory: 256Mi}
          volumeMounts:
            - {name: tls, mountPath: /tls, readOnly: true}
      volumes:
        - name: tls
          secret: {secretName: image-guard-tls}
---
apiVersion: v1
kind: Service
metadata:
  name: image-guard
  namespace: policy-system
spec:
  selector: {app: image-guard}
  ports:
    - {port: 443, targetPort: 8443}
```

### 5.4 The ValidatingWebhookConfiguration — every field explained

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-provenance.corp.internal
  annotations:
    cert-manager.io/inject-ca-from: policy-system/image-guard-tls   # ca-injector fills caBundle
webhooks:
  - name: image-provenance.corp.internal          # must be a fully-qualified DNS name
    admissionReviewVersions: ["v1"]               # versions your server understands
    sideEffects: None                             # no out-of-band writes; safe under dryRun
    failurePolicy: Fail                            # deny if the webhook is unreachable (fail-closed)
    matchPolicy: Equivalent                       # also match equivalent API group/version aliases
    timeoutSeconds: 5                              # 1..30; keep tight, it is on the write path
    reinvocationPolicy: Never                      # (validating; field exists only on mutating)
    clientConfig:
      service:
        namespace: policy-system
        name: image-guard
        path: /validate
        port: 443
      caBundle: ""                                 # injected by cert-manager; leave empty
    rules:
      - operations: ["CREATE", "UPDATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
        scope: Namespaced
    namespaceSelector:                             # scope the blast radius
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "policy-system"] # never gate the control plane or yourself
    objectSelector:                                # optional escape hatch for break-glass
      matchExpressions:
        - key: policy.corp/exempt
          operator: DoesNotExist
```

**The four fields that cause most production incidents:**

| Field | Values | Why it matters | Safe default |
|---|---|---|---|
| `failurePolicy` | `Fail` \| `Ignore` | `Fail` = a broken webhook blocks all matching writes (including in `kube-system` if you forgot to exclude it). `Ignore` = policy silently stops enforcing. | `Fail` **only after** excluding control-plane namespaces and running HA |
| `sideEffects` | `None` \| `NoneOnDryRun` | If your webhook writes external state, declare it, or `kubectl --dry-run=server` corrupts data. v1 forbids `Some`/`Unknown`. | `None` |
| `timeoutSeconds` | `1`–`30` | Every matching write waits up to this long. A 30s timeout × a hung webhook = a stalled API server. | `5` or less |
| `namespaceSelector` | selector | The single most important guardrail: **exclude `kube-system` and the webhook's own namespace**, or a webhook outage becomes a cluster outage you cannot fix through the API. | exclude control-plane ns |

---

## 6. The modern alternative: `ValidatingAdmissionPolicy` (CEL, in-process)

The same image-provenance rule, with **no pod, no TLS, no network hop, no availability coupling**. This is what a Platform Architect reaches for first in 2024+ clusters.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "image-provenance"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: images
      expression: >-
        object.spec.containers.map(c, c.image) +
        object.spec.initContainers.map(c, c.image)
  validations:
    - expression: >-
        variables.images.all(img, img.startsWith('registry.corp.internal/'))
      message: "all images must come from registry.corp.internal"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "image-provenance-binding"
spec:
  policyName: "image-provenance"
  validationActions: [Deny]              # Deny | Warn | Audit — can combine
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system"]
```

The **policy** defines the logic; the **binding** decides *where* it applies and *what to do* (`Deny`, `Warn`, `Audit`). This separation is powerful: ship a policy in `Audit` mode cluster-wide, watch the audit annotations, then flip the binding to `Deny` once you know what you would have broken.

**CEL variables available in expressions:** `object`, `oldObject`, `request`, `params` (from `paramKind`), `namespaceObject`, `authorizer`, and any `variables` you define. A parameterized policy pulls its allowlist from a ConfigMap or CRD via `paramKind`/`paramRef`, so the same compiled policy serves many teams.

### Webhook vs CEL policy — the selection table

| Concern | Webhook | `ValidatingAdmissionPolicy` (CEL) |
|---|---|---|
| Needs external data (LDAP, image scanner, DB) | ✅ possible | ❌ CEL is self-contained |
| Complex/Turing-complete logic | ✅ any language | ⚠️ CEL is intentionally non-Turing-complete |
| Mutation | ✅ (mutating webhook) | ⚠️ `MutatingAdmissionPolicy` (beta v1.34) |
| Operational cost | Pod, HA, TLS, certs, upgrades | None — ships in the config object |
| Availability risk to API server | High (`Fail` + outage = frozen API) | None (in-process) |
| Latency | 1 network round-trip | Microseconds |
| Audit-then-enforce rollout | Manual | Built-in via binding `validationActions` |

**Guidance:** if the rule can be expressed as a pure function of the object(s), use a CEL policy. Reach for a webhook only when you need external data or mutation logic CEL cannot express.

---

## 7. PodSecurity admission — the built-in you must know cold

`PodSecurityPolicy` was removed in **v1.25**. Its replacement is the **PodSecurity** admission plugin, enforcing the three **Pod Security Standards**:

| Standard | Intent | Blocks |
|---|---|---|
| `privileged` | Unrestricted | nothing |
| `baseline` | Prevent known privilege escalations | hostNetwork, hostPID, privileged, most hostPath, added dangerous capabilities |
| `restricted` | Hardened best practice | must run non-root, `seccompProfile: RuntimeDefault`, drop ALL caps, no privilege escalation, restricted volume types |

Applied per-namespace by **labels**, in three independent **modes**:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted      # reject violating Pods
    pod-security.kubernetes.io/enforce-version: v1.31    # pin the standard to a version
    pod-security.kubernetes.io/audit: restricted        # record violations in the audit log
    pod-security.kubernetes.io/warn: restricted         # return a client warning
```

**Why three modes:** `warn` and `audit` let you observe what `enforce: restricted` *would* reject without breaking workloads — the safe migration path off a permissive namespace. Flip `enforce` last.

**Cluster-wide defaults and exemptions** go in the admission configuration file referenced by `--admission-control-config-file`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        warn: "restricted"
        audit: "restricted"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: ["kube-system"]   # the control plane needs privileged Pods
```

Observe it working:

```bash
$ kubectl label ns payments pod-security.kubernetes.io/enforce=restricted --overwrite
namespace/payments labeled

$ kubectl -n payments run bad --image=registry.corp.internal/nginx:1.27 \
    --privileged
Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity
"restricted:v1.31": privileged (container "bad" must not set securityContext.privileged=true),
allowPrivilegeEscalation != false (container "bad" must set
securityContext.allowPrivilegeEscalation=false), unrestricted capabilities
(container "bad" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true, seccompProfile (pod or container must set
securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

## 8. Policy engines: Gatekeeper vs Kyverno vs native CEL

For fleets, teams standardize on a policy engine rather than hand-rolling webhooks. Both Gatekeeper and Kyverno are, under the hood, dynamic admission webhooks packaged with a controller and a policy CRD language.

| Dimension | OPA Gatekeeper | Kyverno | Native CEL policies |
|---|---|---|---|
| Policy language | Rego | YAML (declarative) + CEL | CEL |
| Mutation | Yes (`Assign`, `ModifySet`) | Yes (first-class) | `MutatingAdmissionPolicy` (beta) |
| Generate resources | No | **Yes** (`generate` rules) | No |
| External data | `providers` / `data.inventory` | API calls, image verification | No |
| Runs as | Webhook + controller | Webhook + controller | In-apiserver |
| Audit / dry-run | `Audit` mode, constraint status | `Audit`/`Enforce`, PolicyReports | Binding `Audit`/`Warn` |
| Learning curve | Steep (Rego) | Gentle (K8s-native YAML) | Moderate (CEL) |
| Availability coupling | Webhook outage risk | Webhook outage risk | None |

**Gatekeeper** — a `ConstraintTemplate` compiles Rego into a new CRD; `Constraint` instances parameterize it:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names: {kind: K8sRequiredLabels}
      validation:
        openAPIV3Schema:
          type: object
          properties: {labels: {type: array, items: {type: string}}}
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels
        violation[{"msg": msg}] {
          required := input.parameters.labels
          provided := {k | input.review.object.metadata.labels[k]}
          missing := {x | x := required[_]} - provided
          count(missing) > 0
          msg := sprintf("missing required labels: %v", [missing])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata: {name: ns-must-have-cost-center}
spec:
  match: {kinds: [{apiGroups: [""], kinds: ["Namespace"]}]}
  parameters: {labels: ["cost-center"]}
```

**Kyverno** — the same intent, pure YAML, and it can *mutate* the missing label instead of rejecting:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: {name: require-cost-center}
spec:
  validationFailureAction: Enforce      # or Audit
  rules:
    - name: check-cost-center
      match:
        any: [{resources: {kinds: ["Namespace"]}}]
      validate:
        message: "namespace must carry a cost-center label"
        pattern:
          metadata:
            labels:
              cost-center: "?*"
```

**Guidance:** for greenfield validation, prefer **native CEL** (no operational surface). Choose **Kyverno** when you need resource *generation* (auto-create NetworkPolicy/ResourceQuota per namespace) or image verification with a K8s-native authoring model. Choose **Gatekeeper** when you already run OPA and want to share Rego and `data.inventory` across admission and other decision points.

---

## 9. Verification and failure diagnosis

### 9.1 Confirm the plumbing is enabled

```bash
$ kubectl -n kube-system get pod -l component=kube-apiserver \
    -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep admission
"--enable-admission-plugins=NodeRestriction,PodSecurity"

# Are webhook plugins actually on? (they are default-enabled unless disabled)
$ kubectl -n kube-system get pod -l component=kube-apiserver \
    -o yaml | grep -i disable-admission-plugins
# (empty output = nothing disabled = MutatingAdmissionWebhook/ValidatingAdmissionWebhook active)
```

### 9.2 List and inspect configurations

```bash
$ kubectl get validatingwebhookconfigurations
NAME                              WEBHOOKS   AGE
image-provenance.corp.internal    1          9d

$ kubectl get validatingwebhookconfiguration image-provenance.corp.internal \
    -o jsonpath='{.webhooks[0].failurePolicy}{"\t"}{.webhooks[0].timeoutSeconds}{"\n"}'
Fail	5

# Is the caBundle actually populated? A common cert-manager injection failure:
$ kubectl get validatingwebhookconfiguration image-provenance.corp.internal \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c
1428        # >0 means injected; 0 means the API server has no CA to trust => TLS handshake fails
```

### 9.3 Reproduce a rejection and read the reason

```bash
$ kubectl -n payments run rogue --image=docker.io/library/nginx:latest
Error from server (Forbidden): pods "rogue" is forbidden:
container "rogue" uses disallowed image "docker.io/library/nginx:latest";
only registry.corp.internal/* is permitted
```

### 9.4 The two failure signatures every SRE must recognize

**Signature A — webhook unreachable, `failurePolicy: Fail` (fail-closed outage):**

```bash
$ kubectl -n payments run ok --image=registry.corp.internal/nginx:1.27
Error from server (InternalError): Internal error occurred: failed calling webhook
"image-provenance.corp.internal": failed to call webhook: Post
"https://image-guard.policy-system.svc:443/validate?timeout=5s": no endpoints available
for service "image-guard"
```

Diagnosis ladder:

```bash
$ kubectl -n policy-system get endpoints image-guard
NAME          ENDPOINTS   AGE
image-guard   <none>      9d          # <-- zero ready pods: readiness probe failing or crashloop

$ kubectl -n policy-system get pods -l app=image-guard
NAME                           READY   STATUS             RESTARTS   AGE
image-guard-5f7c9d8b4d-2xk9p   0/1     CrashLoopBackOff   6          4m
```

Break-glass while you fix it — flip to `Ignore` (accept temporary non-enforcement over a frozen API), or use the `objectSelector` exemption you built in §5.4:

```bash
$ kubectl patch validatingwebhookconfiguration image-provenance.corp.internal \
    --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
validatingwebhookconfiguration.admissionregistration.k8s.io/image-provenance.corp.internal patched
```

**Signature B — TLS trust failure (bad or missing `caBundle`):**

```
Error from server (InternalError): Internal error occurred: failed calling webhook
"image-provenance.corp.internal": failed to call webhook: Post "...": tls: failed to
verify certificate: x509: certificate signed by unknown authority
```

Root cause is almost always: cert-manager `ca-injector` did not populate `caBundle`, the serving cert's SAN does not match `service.namespace.svc`, or the cert rotated and the pod did not reload it. Verify the SAN:

```bash
$ kubectl -n policy-system get secret image-guard-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
    X509v3 Subject Alternative Name:
        DNS:image-guard.policy-system.svc, DNS:image-guard.policy-system.svc.cluster.local
```

### 9.5 Prove a CEL policy is active

```bash
$ kubectl get validatingadmissionpolicy image-provenance
NAME               VALIDATIONS   PARAMKIND   AGE
image-provenance   1            <unset>     3d

$ kubectl get validatingadmissionpolicybinding image-provenance-binding \
    -o jsonpath='{.spec.validationActions}'
["Deny"]
```

### 9.6 Audit-log confirmation

With admission actions surfaced in the audit log, you can confirm which stage decided a request:

```bash
$ kubectl get --raw='/api/v1/namespaces/payments/pods' >/dev/null 2>&1
$ grep image-provenance /var/log/kubernetes/audit.log | jq '.annotations'
{
  "validation.policy.admission.k8s.io/validation_failure":
    "[{\"expression\":0,\"message\":\"all images must come from registry.corp.internal\",\"action\":\"Deny\"}]"
}
```

### 9.7 Diagnostic checklist

| Symptom | Likely cause | First command |
|---|---|---|
| Policy not enforcing at all | `ValidatingAdmissionWebhook` disabled, or `namespaceSelector` excludes the ns | `kubectl get pod -l component=kube-apiserver -o yaml \| grep disable-admission` |
| All writes to a ns suddenly fail with `InternalError` | webhook down + `failurePolicy: Fail` | `kubectl get endpoints <svc> -n <ns>` |
| `x509: certificate signed by unknown authority` | empty/stale `caBundle` or SAN mismatch | inspect `caBundle`, verify cert SAN |
| Webhook fires but object unchanged (mutation) | patch not base64, wrong `patchType`, or non-idempotent double-apply | decode `patch`, check `reinvocationPolicy` |
| `dry-run` corrupts external state | `sideEffects` mis-declared | set `sideEffects: None`/`NoneOnDryRun` |
| Random slow API writes | high `timeoutSeconds` + slow webhook | lower `timeoutSeconds`, add replicas |

---

## 10. Design principles (production checklist)

1. **Never gate the control plane.** Exclude `kube-system` and the webhook's own namespace from `namespaceSelector`. A `Fail`-closed webhook that can block writes to its own namespace is an unrecoverable outage.
2. **`failurePolicy: Fail` demands HA.** Multiple replicas, `topologySpreadConstraints`, a `PodDisruptionBudget`, tight `readinessProbe`. Fail-closed without HA is a self-inflicted outage waiting for a node reboot.
3. **Prefer in-process CEL over webhooks** whenever the rule is a pure function of the object. Zero availability coupling is worth more than syntactic convenience.
4. **Mutators must be idempotent.** Assume `reinvocationPolicy: IfNeeded` and re-entry. Check-before-inject, always.
5. **Roll out in `Audit`/`Warn` before `Deny`/`Enforce`.** CEL bindings and PodSecurity make this a first-class two-line change; use it.
6. **Keep `timeoutSeconds` small (≤5s).** It is directly on the synchronous write path of every matching request.
7. **Declare `sideEffects` honestly** so server-side dry-run stays safe.
8. **Automate `caBundle`** with cert-manager `ca-injector`; never paste a base64 CA by hand — it will rotate and break silently.

---

## Referencias

- Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Dynamic Admission Control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Mutating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- AdmissionReview API (`admission.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-admission.v1/
- Admissionregistration API (`admissionregistration.k8s.io/v1`) — https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.31/#validatingwebhookconfiguration-v1-admissionregistration-k8s-io
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- cert-manager CA Injector — https://cert-manager.io/docs/concepts/ca-injector/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Kyverno Policies — https://kyverno.io/docs/writing-policies/
- KCA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf