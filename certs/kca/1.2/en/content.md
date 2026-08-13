# 1.2 YAML Manifests

## 1. The Architectural Problem: Why Declarative Manifests Exist

Before Kubernetes, provisioning a service meant a sequence of imperative steps — SSH into a host, install a package, edit a config, start a daemon, add it to a load balancer. Every step was an *action* whose outcome depended on the machine's current state. Reproducing an environment meant reproducing the *sequence*, and drift was inevitable: a hotfix applied by hand at 3 a.m. lived nowhere but in that one server's memory.

Kubernetes replaces the sequence of actions with a **declaration of desired state**. A YAML manifest does not say "create a Pod"; it says "a Pod with these properties should exist." The control plane's reconciliation loops continuously compare *desired state* (what you declared, stored in etcd) against *observed state* (what actually runs) and drive the difference to zero. This is the single most important mental model in the entire platform, and the YAML manifest is the interface to it.

This has three consequences that every production platform relies on:

1. **Idempotency.** Applying the same manifest twice is a no-op the second time. There is no "already exists" error path to code around, which is what makes GitOps and CI pipelines safe to re-run.
2. **The manifest is the source of truth, not the cluster.** If a manifest lives in Git and a controller applies it, the live object can be treated as a cache. Someone `kubectl edit`-ing production is drift to be corrected, not a change to be preserved.
3. **The API, not YAML, is the real interface.** This is the subtlety most students miss. YAML is *one serialization* of a Kubernetes API object. The API server speaks JSON internally; every YAML manifest is converted to JSON before it touches the API. Understanding this explains almost every confusing YAML behavior you will hit in production.

### YAML is a serialization format, not a Kubernetes feature

```
┌─────────────┐   sigs.k8s.io/yaml   ┌──────────────┐   OpenAPI schema   ┌────────────┐
│ deploy.yaml │ ───────────────────► │  JSON bytes  │ ─────────────────► │ API object │
│  (YAML)     │   (YAML→JSON pass)   │              │   (validation +    │  in etcd   │
└─────────────┘                      └──────────────┘    defaulting)      └────────────┘
```

The client (kubectl or a controller) parses your YAML, converts it to JSON, and PUTs/POSTs the JSON to the API server. The API server validates it against the OpenAPI schema of that `apiVersion`/`kind`, applies **defaulting** (fills in fields you omitted), applies **admission control**, and persists it. When you later `kubectl get -o yaml`, the server re-serializes the stored object *back* to YAML — which is why the object you read is always larger than the one you wrote.

---

## 2. Anatomy of a Manifest: The Four Top-Level Keys

Every Kubernetes object manifest has the same skeleton. There are exactly four required top-level keys for the request you send, plus one the server owns.

```yaml
apiVersion: apps/v1          # WHICH schema/version of WHICH API group
kind: Deployment             # WHICH type of object within that group
metadata:                    # identity: name, namespace, labels, annotations
  name: web
  namespace: production
spec:                        # YOUR desired state (you write this)
  replicas: 3
status:                      # OBSERVED state (the server writes this; never send it)
  readyReplicas: 3
```

| Key          | Who writes it | Purpose | Notes |
|--------------|---------------|---------|-------|
| `apiVersion` | You | Selects the API group + version (`v1`, `apps/v1`, `batch/v1`, `networking.k8s.io/v1`) | Wrong version → `no matches for kind` error |
| `kind`       | You | The object type (`Pod`, `Deployment`, `Service`, `ConfigMap`) | Case-sensitive, PascalCase |
| `metadata`   | You | Identity + `labels`, `annotations`, `namespace` | `name` + `namespace` must be unique per kind |
| `spec`       | You | Desired state — the type-specific payload | Schema differs entirely per `kind` |
| `status`     | Server | Observed state, written by controllers | Ignored on input; do **not** put it in Git |

### `apiVersion` decoded

`apiVersion` is `group/version` — except the *core* (legacy) group, whose group name is empty, so it is written bare as just `v1`.

| `apiVersion` | Group | Example kinds |
|---|---|---|
| `v1` | core (empty group) | `Pod`, `Service`, `ConfigMap`, `Secret`, `Namespace`, `Node`, `PersistentVolumeClaim` |
| `apps/v1` | apps | `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet` |
| `batch/v1` | batch | `Job`, `CronJob` |
| `networking.k8s.io/v1` | networking | `Ingress`, `NetworkPolicy` |
| `rbac.authorization.k8s.io/v1` | rbac | `Role`, `RoleBinding`, `ClusterRole` |

Discover the correct pairing for any kind directly from the API server, never from memory:

```console
$ kubectl api-resources | grep -E 'NAME|deploy|ingress'
NAME          SHORTNAMES   APIVERSION             NAMESPACED   KIND
deployments   deploy       apps/v1                true         Deployment
ingresses     ing          networking.k8s.io/v1   true         Ingress
```

The `APIVERSION` column is authoritative for the cluster you are talking to. This matters because API versions are promoted (`v1beta1` → `v1`) and removed across releases — a manifest that worked on 1.21 can fail on 1.25.

---

## 3. YAML the Language: The Parts That Bite in Production

YAML's readability hides genuinely dangerous ambiguity. The following are not academic — each has caused real production incidents.

### 3.1 Indentation is structure, and tabs are illegal

YAML uses **spaces only**. A tab character is a hard parse error. Two spaces per level is the community convention. Indentation is the *only* thing that expresses nesting — there are no braces.

```yaml
spec:
  containers:        # 2 spaces: child of spec
  - name: app        # list item, same indent as 'containers' key is allowed
    image: nginx     # 4 spaces: field of the list item (aligned under the '-')
```

The single most common beginner error is misaligning `-` list items so a field lands one level too shallow, silently attaching to the wrong parent.

### 3.2 Type coercion — the Norway Problem

YAML 1.1 (which the Kubernetes ecosystem's parsers effectively follow) auto-types unquoted scalars. This means unquoted values you *think* are strings become booleans, floats, or nulls.

| You write | YAML parses as | Type |
|---|---|---|
| `no` / `No` / `NO` | `false` | bool |
| `yes` / `Yes` / `on` / `off` | `true` / `false` | bool |
| `1.10` | `1.1` | float (trailing zero lost!) |
| `010` | `8` or `10` | int (octal ambiguity) |
| `null` / `~` / *(empty)* | `null` | null |
| `3.14` | `3.14` | float |

The name "Norway Problem" comes from country-code lists: `NO` (Norway) parses to boolean `false`. In Kubernetes this bites in `configMap` data, image tags, and version strings:

```yaml
data:
  version: 1.10          # ❌ becomes the float 1.1 — the ".0" vanishes
  enabled: no            # ❌ becomes boolean false, not the string "no"
  region: NO             # ❌ becomes boolean false (Norway!)
```

`ConfigMap.data` **must be string→string**, so the API server rejects the coerced non-strings outright:

```console
$ kubectl apply -f cm.yaml
Error from server (BadRequest): error when creating "cm.yaml":
ConfigMap in version "v1" cannot be handled as a ConfigMap:
json: cannot unmarshal number into Go struct field ConfigMap.data of type string
```

**The fix is always: quote strings whose meaning is textual.**

```yaml
data:
  version: "1.10"        # ✅ stays "1.10"
  enabled: "no"          # ✅ stays "no"
  region: "NO"           # ✅ stays "NO"
```

### 3.3 Scalars, block scalars, and flow style

```yaml
# Plain scalar (may be coerced)
name: nginx

# Quoted scalars (never coerced; single quotes = literal, double = escapes work)
message: "line1\nline2"      # double: \n is a newline
literal:  'C:\path'          # single: backslash is literal

# Block literal '|' — preserves newlines (ideal for embedded config files/scripts)
config: |
  server {
    listen 80;
  }

# Block folded '>' — folds newlines into spaces (ideal for long prose)
description: >
  This long sentence will be
  joined into one line.

# Flow style — JSON-like inline collections
labels: {app: web, tier: frontend}
ports:  [80, 443]
```

The `|` block literal is the correct way to embed multi-line shell scripts, nginx configs, or full config files inside a `ConfigMap` — it preserves every newline exactly. Use `|-` to also strip the trailing newline.

### 3.4 Anchors, aliases, and merge keys (DRY within one document)

YAML can reference itself. `&name` defines an anchor, `*name` references it, and `<<:` merges a mapping.

```yaml
# Define reusable resource block once
resources: &default-resources
  requests: {cpu: "100m", memory: "128Mi"}
  limits:   {cpu: "500m", memory: "512Mi"}

spec:
  containers:
  - name: app
    resources: *default-resources          # reuse verbatim
  - name: sidecar
    resources:
      <<: *default-resources               # merge, then override one field
      limits: {cpu: "200m", memory: "256Mi"}
```

**Trade-off:** anchors are resolved by the *YAML parser* before the document reaches Kubernetes, so they only work *within a single document*. They do not span files and are invisible to `kubectl` diffs. For cross-file reuse you need Kustomize or Helm (§6). Many teams ban anchors in manifests precisely because they hurt readability and grep-ability.

### 3.5 Multi-document files

A single `.yaml` file may hold many objects separated by `---` (document-start marker). This is the idiomatic way to keep a Deployment and its Service together.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
      - name: web
        image: nginx:1.27
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector: {app: web}
  ports:
  - port: 80
    targetPort: 80
```

`kubectl apply -f web.yaml` applies **both** in order. An empty trailing document (a `---` with nothing after it, common when concatenating with Helm) is skipped harmlessly, but a stray leading `---` before a Helm template comment can shift parsing — be deliberate.

---

## 4. Declarative vs. Imperative, and the Merge Semantics of `apply`

This is where the exam and real operations converge. There are three ways to mutate cluster state, and they differ in how they treat fields *you did not mention*.

| Approach | Command | Field ownership model | Re-runnable? | Use when |
|---|---|---|---|---|
| Imperative command | `kubectl create deploy web --image=nginx` | none | No — errors if exists | Quick throwaway, generating YAML |
| Imperative object | `kubectl create -f f.yaml` / `replace -f` | whole-object replace | `replace` yes, `create` no | Full replace, you own the entire object |
| Declarative | `kubectl apply -f f.yaml` | per-field, tracked | Yes (idempotent) | GitOps, everything in production |

### 4.1 Client-side apply and the three-way merge

Classic `kubectl apply` performs a **three-way merge** between:

1. **Last-applied** — the previous manifest, stored by kubectl in the annotation `kubectl.kubernetes.io/last-applied-configuration`.
2. **Live** — the current object in etcd (including controller-set fields).
3. **Config** — the manifest you're applying now.

The diff of (last-applied) vs (config) tells apply which fields *you* removed, so it can delete them from live while leaving controller-managed fields (like a HorizontalPodAutoscaler-set `replicas`) untouched. This is why `apply` doesn't clobber fields you never manage — and why `replace` *does* (it has no last-applied memory).

```console
$ kubectl apply -f web.yaml
deployment.apps/web configured

$ kubectl get deploy web -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | head -c 80
{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"annotations":{},"name":
```

**The classic footgun:** if you `kubectl create -f` (not `apply`), no last-applied annotation is written. The first later `apply` then can't compute a proper diff and warns:

```console
$ kubectl apply -f web.yaml
Warning: resource deployments/web is missing the kubectl.kubernetes.io/last-applied-configuration
annotation which is required by kubectl apply. kubectl apply should only be used on resources
created declaratively by either kubectl create --save-config or kubectl apply...
deployment.apps/web configured
```

Rule: **pick one discipline and stay in it.** `apply` from the start, forever.

### 4.2 Server-Side Apply (SSA) — the modern model

Server-Side Apply moves the merge logic into the API server and replaces the single annotation with structured **`managedFields`** — every field records which "manager" (kubectl, a controller, an HPA) owns it. This makes multi-writer ownership explicit and lets controllers and humans co-own an object without stomping each other.

```console
$ kubectl apply -f web.yaml --server-side
deployment.apps/web serverside-applied

$ kubectl get deploy web -o yaml --show-managed-fields \
    | yq '.metadata.managedFields[] | {manager: .manager, operation: .operation}'
manager: kube-controller-manager
operation: Update
manager: kubectl
operation: Apply
```

If two managers try to own the same field, you get a **conflict** — a feature, not a bug: it surfaces a fight that client-side apply would have hidden.

```console
$ kubectl apply -f web.yaml --server-side
error: Apply failed with 1 conflict: conflict with "kubectl-edit" using apps/v1:
  .spec.replicas
Please review the fields above--they currently have another manager. Re-run the
command with --force-conflicts to overwrite them, or ask the other manager to relinquish.
```

| | Client-side apply | Server-Side Apply |
|---|---|---|
| Merge location | kubectl (client) | API server |
| State tracking | `last-applied-configuration` annotation | `managedFields` (per-field) |
| Multi-writer safety | last-writer-wins, silent | explicit conflicts |
| Annotation bloat | grows with object size (can exceed limits) | none |
| Recommended for controllers | no | **yes** |

Large objects broke classic apply because the last-applied annotation is itself part of the object and could exceed the etcd value-size limit; SSA eliminates that failure class.

---

## 5. Complete Production Manifests (Uncut)

### 5.1 A production-grade Deployment (every field an SRE actually sets)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: production
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/version: "2.4.1"
    app.kubernetes.io/component: backend
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 4
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0            # zero-downtime: never drop below desired
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
        app.kubernetes.io/version: "2.4.1"
    spec:
      serviceAccountName: payments-api
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      terminationGracePeriodSeconds: 30
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: payments-api
      containers:
      - name: api
        image: registry.example.com/payments-api:2.4.1
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        env:
        - name: DB_HOST
          valueFrom:
            configMapKeyRef:
              name: payments-config
              key: db_host
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: payments-db
              key: password
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1"
            memory: "512Mi"
        livenessProbe:
          httpGet:
            path: /healthz
            port: http
          initialDelaySeconds: 10
          periodSeconds: 10
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /readyz
            port: http
          initialDelaySeconds: 5
          periodSeconds: 5
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: tmp
        emptyDir: {}
```

Notes an architect would call out: `maxUnavailable: 0` + `maxSurge: 1` guarantees no capacity dip during rollout; `readOnlyRootFilesystem: true` forces you to mount an explicit writable `/tmp`; the `app.kubernetes.io/*` labels are the **recommended common label set** and are what `selector.matchLabels` keys off — the selector is **immutable** after creation, so choosing it well matters.

### 5.2 ConfigMap with an embedded config file (block literal)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-config
  namespace: production
data:
  db_host: "postgres.production.svc.cluster.local"
  log_level: "info"
  app.conf: |
    [server]
    port = 8080
    timeout = 30s

    [features]
    retry_enabled = true
    max_retries = 3
```

The scalar values are quoted (defending against §3.2); `app.conf` uses `|` so the file's newlines survive intact and it can be mounted as a real file.

### 5.3 The manifest ↔ JSON equivalence

Because YAML is just a serialization, this Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo
spec:
  containers:
  - name: c
    image: nginx
    ports:
    - containerPort: 80
```

is *byte-for-byte semantically identical* to this JSON, which you can apply just as well:

```json
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": { "name": "demo" },
  "spec": {
    "containers": [
      { "name": "c", "image": "nginx", "ports": [ { "containerPort": 80 } ] }
    ]
  }
}
```

```console
$ kubectl apply -f demo.json
pod/demo created
```

Internalizing this equivalence is what makes the type-coercion rules (§3.2) and `-o jsonpath` queries stop feeling like magic.

---

## 6. Generating and Templating Manifests

Hand-writing the full Deployment above is error-prone, so nobody starts from a blank file. Three tiers of tooling exist, and their trade-offs are a common exam and design topic.

| Tool | Mechanism | Strength | Weakness |
|---|---|---|---|
| `kubectl create --dry-run=client -o yaml` | Generators emit a skeleton | Zero deps, instant scaffold | Only basic kinds; you finish by hand |
| **Kustomize** (`kubectl -k`) | Overlays patch a plain-YAML base | No templating language, valid YAML at every layer | Patching gets verbose for large variation |
| **Helm** | Go-template rendering + values | Full parameterization, packaging, releases | Templates aren't valid YAML until rendered; whitespace bugs |

### 6.1 Scaffold, don't type

```console
$ kubectl create deployment web --image=nginx:1.27 --replicas=3 \
    --dry-run=client -o yaml > web.yaml
$ head -8 web.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  creationTimestamp: null
  labels:
    app: web
  name: web
spec:
```

This is the correct workflow: generate the skeleton imperatively, then commit it and manage it declaratively with `apply`.

### 6.2 Kustomize — patch a base without a templating language

Kustomize keeps every layer as *real, valid YAML*. A `kustomization.yaml` names a base plus patches:

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: production
resources:
  - ../../base
patches:
  - target:
      kind: Deployment
      name: web
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 8
images:
  - name: nginx
    newTag: "1.27"
```

```console
$ kubectl kustomize overlays/production | head -6
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: production
spec:
$ kubectl apply -k overlays/production
deployment.apps/web configured
```

The design win: because a base and an overlay are both plain YAML, you can `kubectl diff -k` and read exactly what changed — no template mental-execution required.

---

## 7. Verification and Failure Diagnosis

Never apply an unvalidated manifest to production. There is a ladder of checks, each stricter and more expensive than the last.

### 7.1 The validation ladder

| Rung | Command | Catches | Needs cluster? |
|---|---|---|---|
| Lint syntax | `yamllint f.yaml` | tabs, bad indent, trailing spaces | no |
| Schema (offline) | `kubeconform -strict f.yaml` | wrong field names, wrong types vs OpenAPI | no |
| Client dry-run | `kubectl apply --dry-run=client -f f.yaml` | local decoding + basic structure | no |
| **Server dry-run** | `kubectl apply --dry-run=server -f f.yaml` | admission webhooks, quotas, defaulting, real schema | yes |
| Diff | `kubectl diff -f f.yaml` | exactly what would change on live | yes |

`--dry-run=server` is the highest-fidelity check short of actually applying: it runs the request through the *real* API server — validation, defaulting, and every admission webhook — and then discards it instead of persisting.

```console
$ kubectl apply --dry-run=server -f web.yaml
deployment.apps/web configured (server dry run)

$ kubectl diff -f web.yaml
diff -u -N /tmp/LIVE-123/apps.v1.Deployment.default.web /tmp/MERGED-456/...
--- LIVE      2026-08-13 10:04:11
+++ MERGED    2026-08-13 10:04:11
@@ -14,7 +14,7 @@
   spec:
-    replicas: 3
+    replicas: 5
```

Offline schema validation with kubeconform in CI (no cluster needed) is the standard GitOps gate:

```console
$ kubeconform -strict -summary web.yaml
Summary: 1 resource found parsing stdin - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0
```

### 7.2 The failure catalogue — symptom → cause → fix

**A. Wrong `apiVersion`/`kind` pairing**
```console
$ kubectl apply -f cronjob.yaml
error: unable to recognize "cronjob.yaml": no matches for kind "CronJob" in version "batch/v1beta1"
```
Cause: `batch/v1beta1` was removed. Fix: `kubectl api-resources | grep -i cronjob` → use `batch/v1`.

**B. Tab character in indentation**
```console
$ kubectl apply -f bad.yaml
error: error parsing bad.yaml: error converting YAML to JSON: yaml: line 6:
found character that cannot start any token
```
Cause: a literal tab. Fix: `grep -nP '\t' bad.yaml` and replace with spaces.

**C. Type coercion (Norway Problem)**
```console
$ kubectl apply -f cm.yaml
Error from server (BadRequest): ... json: cannot unmarshal bool into Go struct
field ConfigMap.data of type string
```
Cause: an unquoted `no`/`yes`/`1.10`. Fix: quote the value.

**D. Selector/template label mismatch (the silent one)**
```console
$ kubectl apply -f deploy.yaml
The Deployment "web" is invalid: spec.template.metadata.labels: Invalid value:
map[string]string{"app":"web"}: `selector` does not match template `labels`
```
Cause: `spec.selector.matchLabels` must be a subset of `spec.template.metadata.labels`. Fix: align them. Remember the selector is **immutable** — if you truly need to change it, delete and recreate.

**E. Field indented under the wrong parent (no error, wrong behavior)**
The nastiest failures produce *no error at all*. If `resources:` is indented one level too shallow, it attaches to the Pod spec instead of the container, is ignored as an unknown field, and your limits silently don't apply. Defense:
```console
$ kubectl apply --dry-run=server -f deploy.yaml
Warning: unknown field "spec.template.spec.resources"
deployment.apps/web configured (server dry run)
```
`--dry-run=server` surfaces `unknown field` warnings that `--dry-run=client` and a plain `apply` may swallow. Enable strict decoding to make them hard errors: `--validate=strict`.

### 7.3 Confirm the applied result matches intent

Applying successfully is not the same as applying *correctly*. Read the object back and compare against what you wrote — the server's defaulting means it will differ, so diff *semantically*:

```console
$ kubectl get deploy payments-api -o yaml \
    | kubectl neat 2>/dev/null || kubectl get deploy payments-api -o yaml | head -20

$ kubectl rollout status deploy/payments-api --timeout=120s
Waiting for deployment "payments-api" rollout to finish: 2 of 4 updated replicas are available...
deployment "payments-api" successfully rolled out

$ kubectl get deploy payments-api -o jsonpath='{.spec.replicas}/{.status.readyReplicas}{"\n"}'
4/4
```

The final identity to internalize: `spec.replicas` is *what you asked for*; `status.readyReplicas` is *what the cluster achieved*. When they match, reconciliation has converged. When they diverge and stay diverged, that gap is your entire debugging surface — and it always traces back to a field you did, or did not, put in the manifest.

---

## 8. References

- Kubernetes — Objects, Spec and Status: https://kubernetes.io/docs/concepts/overview/working-with-objects/kubernetes-objects/
- Kubernetes — Managing Objects with Configuration Files (declarative apply, three-way merge): https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — Server-Side Apply and managedFields: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — Imperative vs. declarative object management: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/imperative-config/
- Kubernetes — Recommended Labels: https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
- Kubernetes — API Overview and versioning: https://kubernetes.io/docs/reference/using-api/
- Kubernetes — Deprecated API Migration Guide: https://kubernetes.io/docs/reference/using-api/deprecation-guide/
- Kubernetes — Declarative Management with Kustomize: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kubernetes — Validate an object (`--dry-run`, `kubectl diff`): https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- YAML 1.2 Specification: https://yaml.org/spec/1.2.2/
- kubeconform (offline schema validation): https://github.com/yannh/kubeconform
- CNCF Curriculum (KCA): https://github.com/cncf/curriculum