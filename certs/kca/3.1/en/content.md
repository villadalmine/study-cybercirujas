# 3.1 — `apply`: Declarative Object Management, Client-Side vs Server-Side Apply

> Exam weight: **3.0** · Domain 3 · Focus: the declarative object-management model that `kubectl apply` implements, the three-way merge that makes it safe, and Server-Side Apply (SSA) field ownership — the mechanism every GitOps controller and admission webhook now depends on.

---

## 1. Motivation — the production problem `apply` solves

A Kubernetes object's desired state does not have a single author. A `Deployment` is written by a human (or a Git repo), then *mutated in flight* by:

- **Controllers** — the HorizontalPodAutoscaler rewrites `.spec.replicas`; the Deployment controller stamps `.spec.template.metadata.annotations` for rollouts.
- **Admission webhooks** — a service mesh injector adds a sidecar container; Kyverno/Gatekeeper inject `securityContext` defaults.
- **Other humans / other tools** — `kubectl scale`, `kubectl set image`, a second team's Helm release, a break-glass `kubectl edit`.

If you manage objects **imperatively** (`kubectl create`, `kubectl replace -f`, `kubectl edit`), every write is a *full-object overwrite*. Reapplying your file blindly clobbers whatever the HPA or the injector did, and removing a field from your file does **not** remove it from the cluster (there is no record of what you previously "owned"). This produces two chronic incidents:

1. **The replica flap.** You `apply` `replicas: 3`. The HPA scales to 12. Your CI re-`apply`s → back to 3 → HPA scales to 12 again. The Deployment oscillates on every pipeline run.
2. **Config drift / orphaned fields.** Someone `kubectl edit`s an env var in prod. Your next `apply` leaves it in place because your file "doesn't know" the field exists — the live object silently diverges from Git.

`kubectl apply` exists to make the manifest the **declarative source of truth** while tracking *which fields you own*, so a reapply reconciles only your fields and *deletes fields you removed* without stomping fields owned by other actors. This is the foundation GitOps (Argo CD, Flux) is built on — both use Server-Side Apply so the controller, the platform team, and the app team can co-own one object without a merge war.

---

## 2. The three object-management models (and when each is legitimate)

Kubernetes documents three mutually-incompatible techniques. **Never mix them on the same object** — that is the #1 cause of apply surprises.

| Technique | Verbs | Config source | State tracking | Correct use | Failure mode when misused |
|---|---|---|---|---|---|
| **Imperative commands** | `kubectl create/run/expose/scale/set/delete` | none (flags) | none | one-off, dev, break-glass, generating YAML with `--dry-run=client -o yaml` | not reproducible; no audit trail |
| **Imperative object config** | `kubectl create -f`, `kubectl replace -f`, `kubectl delete -f` | one `.yaml` | none | when you want a *full overwrite* and reject concurrent edits | `replace` fails if object changed under you; drops fields set by controllers/webhooks |
| **Declarative object config** | `kubectl apply -f`, `kubectl apply -k`, `kubectl diff -f` | files / dirs / kustomize | **yes** — CSA annotation or SSA `managedFields` | production, GitOps, CI/CD, multi-writer objects | mixing with `replace`/`edit` corrupts the merge base |

**Rule of thumb:** an object touched by `apply` should be touched *only* by `apply` for the rest of its life. `kubectl edit`, `kubectl scale`, and `kubectl replace` write with *different field managers* and set up the exact conflict SSA is designed to detect (see §4.6).

---

## 3. How `apply` actually works — the merge mechanics

`kubectl apply` computes what to change from **three inputs**, hence *three-way merge*:

1. **The configuration file** you pass with `-f` (your new desired state).
2. **The live object** currently in etcd.
3. **The last-applied state** — what *you* declared last time.

Input #3 is what makes deletion possible: a field present in *last-applied* but absent from your *new file* → **delete it**. A field present live but never in your last-applied → **leave it alone** (someone else owns it). This is the whole trick.

There are two implementations of #3.

### 3.1 Client-Side Apply (CSA) — the legacy default

`kubectl` stores your last-applied state as a JSON blob inside an annotation on the object:

```yaml
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"apps/v1","kind":"Deployment","metadata":{...},"spec":{...}}
```

The client reads the live object, reads that annotation, diffs against your file, computes a **strategic merge patch**, and PATCHes it. Problems:

- The annotation **duplicates the whole object** — a 300 KB ConfigMap breaks the 256 KB annotation limit and the apply fails.
- The merge logic lives in the **client**, so `kubectl` and `client-go` and every other SDK must reimplement it identically (they don't, exactly).
- Ownership is coarse — the annotation records *what you sent*, not *which fields you exclusively own*.

### 3.2 Server-Side Apply (SSA) — beta 1.16, **GA 1.22**, the modern default for controllers

With `--server-side`, the client sends *only your intent* as a partial object with `Content-Type: application/apply-patch+yaml`, tagged with a **field manager** name. The **API server** does the merge and records, per field, who owns it, in `.metadata.managedFields`:

```yaml
metadata:
  managedFields:
  - manager: kubectl                      # who
    operation: Apply                      # Apply (declarative) vs Update (imperative)
    apiVersion: apps/v1
    time: "2026-08-13T10:15:32Z"
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
        f:replicas: {}                    # <- this manager owns .spec.replicas
        f:template:
          f:spec:
            f:containers:
              k:{"name":"web"}:           # keyed list entry (merge key = name)
                f:image: {}               # <- owns the image of container "web"
```

Now the server can answer *"who owns `.spec.replicas`?"* precisely. If two managers try to own the same field with **different values**, the server returns a **409 conflict** instead of silently overwriting.

### 3.3 Patch strategies and list-merge semantics

The merge is not a naive JSON overlay. Built-in types carry Go struct tags (`patchStrategy`, `patchMergeKey`); CRDs express the same via OpenAPI `x-kubernetes-list-type`.

| Strategy | Content-Type | List behavior | Where used |
|---|---|---|---|
| **Strategic Merge Patch** | `application/strategic-merge-patch+json` | merges lists by **merge key** (e.g. containers by `name`, ports by `containerPort`) | built-in types, CSA |
| **JSON Merge Patch (RFC 7386)** | `application/merge-patch+json` | lists are **atomic** — replaced whole | CRDs without schema hints, `kubectl patch --type merge` |
| **JSON Patch (RFC 6902)** | `application/json-patch+json` | explicit op/path array | `kubectl patch --type json` |
| **Apply Patch** | `application/apply-patch+yaml` | list behavior from `x-kubernetes-list-type` | Server-Side Apply |

For SSA, the CRD (or built-in schema) declares how each list merges:

| `x-kubernetes-list-type` | Semantics | Multiple owners? | Example field |
|---|---|---|---|
| `atomic` | whole list is one unit; one owner replaces all | no — single owner | `.spec.template.spec.tolerations` (in some types) |
| `set` | list of scalars, deduped, order-insensitive | yes — per element | `.spec.finalizers` |
| `map` | associative list keyed by `x-kubernetes-list-map-keys` | yes — per keyed entry | `containers` (key `name`), `ports` (key `containerPort`) |

This is why two managers can each own a *different container* in the same Pod spec, but if the schema marks a list `atomic`, only one manager may own the entire list. **Getting `x-kubernetes-list-type` wrong on a CRD is a top cause of "SSA keeps fighting my controller."**

---

## 4. Full manifests and real CLI sessions

### 4.1 The working object

`web.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: shop
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/part-of: storefront
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
    spec:
      containers:
      - name: web
        image: registry.example.com/web:1.8.2
        ports:
        - name: http
          containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: "500m"
            memory: 256Mi
        readinessProbe:
          httpGet:
            path: /healthz
            port: http
          initialDelaySeconds: 5
          periodSeconds: 10
```

### 4.2 Create → configure → unchanged (the idempotent loop)

```console
$ kubectl apply -f web.yaml
deployment.apps/web created

$ sed -i 's/web:1.8.2/web:1.9.0/' web.yaml

$ kubectl apply -f web.yaml
deployment.apps/web configured

$ kubectl apply -f web.yaml
deployment.apps/web unchanged
```

Three distinct verbs in the output — `created`, `configured`, `unchanged` — are your primary signal in CI: `unchanged` means the reconcile is a no-op (drift-free); `configured` after a clean pipeline run means someone edited the cluster out-of-band.

### 4.3 Preview before you touch prod — `kubectl diff`

```console
$ kubectl diff -f web.yaml
diff -u -N /tmp/LIVE-3517880123/apps.v1.Deployment.shop.web /tmp/MERGED-1029384756/apps.v1.Deployment.shop.web
--- /tmp/LIVE-3517880123/apps.v1.Deployment.shop.web    2026-08-13 10:20:11.000000000 +0000
+++ /tmp/MERGED-1029384756/apps.v1.Deployment.shop.web  2026-08-13 10:20:11.000000000 +0000
@@ -34,7 +34,7 @@
       containers:
       - name: web
-        image: registry.example.com/web:1.8.2
+        image: registry.example.com/web:1.9.0
         name: web
         ports:
         - containerPort: 8080
```

`kubectl diff` runs a **server-side dry-run** (`--server-side` merge in memory), so it shows exactly what the API server would compute, including webhook mutations. Exit code `1` means "there is a diff" — usable as a drift gate in CI:

```console
$ kubectl diff -f web.yaml >/dev/null 2>&1 && echo "in sync" || echo "DRIFT"
DRIFT
```

### 4.4 Dry-run: client vs server

```console
$ kubectl apply -f web.yaml --dry-run=client
deployment.apps/web configured (dry run)

$ kubectl apply -f web.yaml --dry-run=server
deployment.apps/web configured (server dry run)
```

`--dry-run=client` only validates YAML locally. `--dry-run=server` sends the object through **admission** (validating + mutating webhooks, quota, defaulting) without persisting — the only trustworthy preview, because it catches OPA/Kyverno denials and injector mutations. Always prefer `server` in pre-deploy checks.

### 4.5 Server-Side Apply and inspecting ownership

```console
$ kubectl apply --server-side -f web.yaml
deployment.apps/web serverside-applied

$ kubectl get deploy web -n shop --show-managed-fields -o yaml | yq '.metadata.managedFields[] | {"manager": .manager, "operation": .operation}'
{"manager": "kubectl", "operation": "Apply"}
```

Note the new output verb: **`serverside-applied`**. To see *who owns what*:

```console
$ kubectl get deploy web -n shop --show-managed-fields \
    -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\n"}{end}'
kubectl         Apply
```

Pin a stable field-manager name for automation (GitOps tools do this):

```console
$ kubectl apply --server-side --field-manager=argo-cd -f web.yaml
deployment.apps/web serverside-applied
```

### 4.6 The conflict — and how to resolve it (canonical CSA→SSA migration)

Suppose the object was first created with **client-side** apply (manager `kubectl-client-side-apply`, operation `Update`), then a platform pipeline switches to SSA. The image field is now contested:

```console
$ kubectl apply --server-side -f web.yaml
error: Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1:
  .spec.template.spec.containers[name="web"].image
Please review the fields above--they currently have other managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
* You may co-own fields by updating your manifest to match the existing
  value; in this case, you'll become the manager if the other manager(s)
  stop managing the field (remove it from their configuration).
See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts
```

The three documented resolutions map to three real production decisions:

| You want… | Do this | Effect on `managedFields` |
|---|---|---|
| **Take over** the field (you are the new owner of record) | `kubectl apply --server-side --force-conflicts -f web.yaml` | your manager becomes sole owner; other manager loses it |
| **Leave it to the other manager** (e.g. HPA owns replicas) | remove the field from your manifest | you never claim it; no conflict |
| **Co-own** it (both must agree on the value) | keep the field but set it to the *current live value* | shared ownership; you inherit if the other manager drops it |

Force-taking ownership:

```console
$ kubectl apply --server-side --force-conflicts -f web.yaml
deployment.apps/web serverside-applied
```

### 4.7 Deletion of removed fields (the deletion story)

Add an env var, apply, then remove it and apply again:

```console
$ kubectl apply --server-side -f web-with-env.yaml
deployment.apps/web serverside-applied

# web.yaml no longer contains the env block
$ kubectl apply --server-side -f web.yaml
deployment.apps/web serverside-applied

$ kubectl get deploy web -n shop -o jsonpath='{.spec.template.spec.containers[0].env}'
                                     # empty — the field you stopped declaring was removed
```

Because SSA tracks that *you* owned `.spec.template.spec.containers[name="web"].env`, dropping it from your manifest deletes it — but **only that field**, never fields owned by the sidecar injector or the HPA.

### 4.8 Object pruning — deleting whole objects no longer in your manifest set

`apply` only reconciles objects it is *given*. Deleting a manifest file does **not** delete the object. Two mechanisms close this gap:

**Legacy (deprecated, dangerous):**

```console
$ kubectl apply -f ./manifests/ --prune -l app.kubernetes.io/part-of=storefront
```

This label-based prune walks a hardcoded allowlist of types and can delete objects you never intended (cluster-scoped objects across the whole cluster). Treat it as a footgun.

**ApplySet-based pruning (KEP-3659, alpha/beta — gated by an env var):**

```console
$ export KUBECTL_APPLYSET=true
$ kubectl apply -n shop --server-side --applyset=storefront --prune -f ./manifests/
namespace/shop unchanged
deployment.apps/web serverside-applied
service/web serverside-applied
configmap/web-config pruned          # was in the set last run, absent now → deleted
```

The `--applyset` names a *parent* object (a ConfigMap/Secret, or a designated CRD) that records the membership set via `applyset.kubernetes.io/*` labels, so kubectl knows *exactly* which objects belong to this application and prunes only those. This is the safe, scoped successor to `--prune -l`.

### 4.9 Kustomize and stdin

```console
$ kubectl apply -k ./overlays/prod/
configmap/web-config-6t4h2b8f9c created
deployment.apps/web configured

$ kustomize build ./overlays/prod | kubectl apply --server-side -f -
deployment.apps/web serverside-applied
```

---

## 5. Verification and failure diagnosis

### 5.1 Diagnose the replica flap (fighting the HPA)

Symptom: replicas oscillate on every pipeline run. Confirm ownership:

```console
$ kubectl get deploy web -n shop --show-managed-fields -o yaml | \
    yq '.metadata.managedFields[] | select(.fieldsV1.f:spec | has("f:replicas")) | .manager'
kubectl
horizontal-pod-autoscaler
```

Two managers claim `.spec.replicas`. **Fix:** remove `replicas` from the manifest so the HPA is the sole owner:

```yaml
spec:
  # replicas: 3      <-- DELETE this line; the HPA owns it
  selector:
    ...
```

```console
$ kubectl apply --server-side -f web.yaml
deployment.apps/web serverside-applied
$ kubectl get deploy web -n shop --show-managed-fields -o yaml | \
    yq '[.metadata.managedFields[] | select(.fieldsV1.f:spec | has("f:replicas"))] | length'
1
```

Now exactly one owner remains and the flap stops. (This is the canonical reason production Deployment manifests under HPA **omit `replicas` entirely**.)

### 5.2 Diagnose "I mixed apply with edit/replace"

Symptom: `apply` reports `configured` on a clean pipeline, or fields you removed keep coming back. Look for a foreign field manager with `operation: Update`:

```console
$ kubectl get deploy web -n shop --show-managed-fields \
    -o jsonpath='{range .metadata.managedFields[*]}{.manager}{" / "}{.operation}{"\n"}{end}'
kubectl                 / Apply
kubectl-edit            / Update      # <- someone ran kubectl edit
```

**Fix:** reclaim the fields with `--server-side --force-conflicts`, then forbid out-of-band edits (RBAC, admission policy). To fully reset CSA cruft after migrating to SSA, drop the legacy annotation:

```console
$ kubectl apply --server-side --force-conflicts -f web.yaml
$ kubectl annotate deploy web -n shop kubectl.kubernetes.io/last-applied-configuration-
```

### 5.3 Annotation-size failure (CSA only)

```console
$ kubectl apply -f big-configmap.yaml
The ConfigMap "app-data" is invalid: metadata.annotations: Too long: must have at most 262144 bytes
```

**Root cause:** the `last-applied-configuration` annotation duplicates the (large) object. **Fix:** use `--server-side`, which stores no annotation:

```console
$ kubectl apply --server-side -f big-configmap.yaml
configmap/app-data serverside-applied
```

### 5.4 CRD list-merge misbehavior

Symptom: SSA on a custom resource replaces an entire list you expected to merge, or two controllers can't co-own a keyed list. Inspect the CRD schema:

```console
$ kubectl get crd widgets.example.com -o jsonpath \
    ='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.rules}' | jq
{
  "type": "array",
  "x-kubernetes-list-type": "atomic"          # <- why it replaces wholesale
}
```

**Fix:** the CRD author must declare `x-kubernetes-list-type: map` + `x-kubernetes-list-map-keys: ["name"]` for per-entry co-ownership. This is a *schema* fix, not a client fix.

### 5.5 Common-error reference table

| Symptom / message | Likely cause | Resolution |
|---|---|---|
| `Apply failed with N conflicts` | another field manager owns those fields | `--force-conflicts` (take over), drop the field (yield), or match the value (co-own) |
| output says `configured` on a clean CI run | out-of-band `kubectl edit`/`scale`/console change | find the `Update` manager via `--show-managed-fields`; reclaim + lock down RBAC |
| removed field persists in cluster | object last written imperatively (no last-applied / no `managedFields` for it) | one SSA apply reclaims ownership; thereafter deletes track |
| `metadata.annotations: Too long` | large object under CSA | switch to `--server-side` |
| deleted a YAML file but object still exists | `apply` never prunes by default | ApplySet prune (`--applyset --prune`), or `kubectl delete -f` |
| SSA replaces a whole list unexpectedly | CRD list is `atomic` | CRD must use `x-kubernetes-list-type: map` with map keys |
| `error validating data: ...unknown field` | typo / wrong apiVersion vs live schema | `kubectl apply --dry-run=server`; fix field or `--validate=strict` finds it early |

### 5.6 The golden verification sequence for any `apply` change

```console
$ kubectl apply --dry-run=server -f web.yaml        # passes admission?
$ kubectl diff -f web.yaml                           # exactly what changes?
$ kubectl apply --server-side -f web.yaml            # apply with ownership tracking
$ kubectl rollout status deploy/web -n shop          # did it converge?
deployment "web" successfully rolled out
$ kubectl diff -f web.yaml && echo "IN SYNC"         # drift gate: exit 0 == clean
IN SYNC
```

---

## 6. References

- Declarative object management with `kubectl apply` — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Managing Kubernetes Objects (three techniques overview) — https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/
- Imperative object configuration with config files — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/imperative-config/
- Server-Side Apply (field management, conflicts, managedFields) — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- `kubectl apply` command reference — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_apply/
- `kubectl diff` command reference — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/
- Update API objects in place using `kubectl patch` (merge strategies) — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- Kubernetes API concepts — patch/apply content types & dry-run — https://kubernetes.io/docs/reference/using-api/api-concepts/
- Structural schemas & list types (`x-kubernetes-list-type`) for CRDs — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema
- KEP-3659: ApplySet-based pruning for `kubectl apply --prune` — https://github.com/kubernetes/enhancements/tree/master/keps/sig-cli/3659-kubectl-apply-prune
- `kubectl` object-management field manager & conflicts (blog, SSA GA) — https://kubernetes.io/blog/2021/08/06/server-side-apply-ga/