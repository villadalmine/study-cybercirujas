# Exercises — Topic 4.2: APIs for Self-Service Platforms (Custom Resource Definitions)

> **Prerequisites.** A throwaway cluster where you are `cluster-admin`. `kind create cluster --name cnpa-42` or `minikube start` both work. Every command below is copy-paste runnable. When an output block is shown, run the command and compare — divergence is the signal to stop and read the question, not to push on.
>
> The self-service premise: a **platform team** publishes a Kubernetes API that application developers consume with plain `kubectl`, `kubectl explain`, and their existing GitOps tooling — without the platform team writing a bespoke web portal, and without developers touching Deployments, Services or Ingress directly. In topic 4.2 the deliverable is the **API surface itself** (the CRD): its schema, validation, defaulting, versioning and discovery. The controller that acts on the resource is a separate concern; here we prove the API teaches, validates and self-documents on its own.

---

## Exercise 1 — Map the extension surface before you touch it

1. Confirm the built-in resource that lets you *add* resources is itself a resource:

   ```bash
   kubectl api-resources --api-group=apiextensions.k8s.io
   ```

   Expected:

   ```
   NAME                        SHORTNAMES   APIVERSION                        NAMESPACED   KIND
   customresourcedefinitions   crd,crds     apiextensions.k8s.io/v1           false        CustomResourceDefinition
   ```

2. Read the top of the CRD API's own documentation, served live by your API server:

   ```bash
   kubectl explain customresourcedefinition.spec --recursive | head -40
   ```

3. List CRDs already present (managed CNI, storage or metrics stacks often ship some; a bare `kind` cluster shows none):

   ```bash
   kubectl get crds
   ```

**Check your understanding**

- **Q1.1** `CustomResourceDefinition` reports `NAMESPACED   false`. What does that tell you about *where* a CRD lives, and is that the same as where the *custom resources* it defines will live?
- **Q1.2** A CRD is created through the `apiextensions.k8s.io` API group. Name the two distinct API surfaces that come into existence the moment you create one CRD, and which API group each belongs to.
- **Q1.3** Why is `kubectl explain` able to describe a resource the API server has never heard of until you install its CRD? What does the CRD contribute to make that work?

---

## Exercise 2 — Publish a minimal API and drive it

1. Write the CRD. This is the smallest thing the platform team ships to expose a `WebService` kind:

   ```yaml
   # webservice-crd-v1.yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: webservices.platform.example.com   # MUST be <plural>.<group>
   spec:
     group: platform.example.com
     scope: Namespaced
     names:
       plural: webservices
       singular: webservice
       kind: WebService
       shortNames:
         - ws
       categories:
         - platform
     versions:
       - name: v1alpha1
         served: true
         storage: true
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 properties:
                   image:
                     type: string
                   replicas:
                     type: integer
                 required:
                   - image
   ```

2. Apply it and watch it become established:

   ```bash
   kubectl apply -f webservice-crd-v1.yaml
   kubectl wait --for=condition=Established crd/webservices.platform.example.com --timeout=60s
   ```

   Expected:

   ```
   customresourcedefinition.apiextensions.k8s.io/webservices.platform.example.com created
   customresourcedefinition.apiextensions.k8s.io/webservices.platform.example.com condition met
   ```

3. Inspect the `status` block the API server filled in — you did not write any of it:

   ```bash
   kubectl get crd webservices.platform.example.com \
     -o jsonpath='{.status.acceptedNames.kind}{"\n"}{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
   ```

   Expected:

   ```
   WebService
   NamesAccepted=True
   Established=True
   ```

4. Consume the new API as a developer would — note the short name and the category both work immediately:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: platform.example.com/v1alpha1
   kind: WebService
   metadata:
     name: checkout
   spec:
     image: ghcr.io/acme/checkout:1.4.0
     replicas: 3
   EOF

   kubectl get ws
   kubectl get platform          # the category
   ```

   Expected (roughly):

   ```
   NAME       AGE
   checkout   5s
   ```

**Check your understanding**

- **Q2.1** The CRD `metadata.name` is `webservices.platform.example.com`. What rule ties that string to the `spec.group` and `spec.names.plural` fields, and what happens at apply time if it does not match?
- **Q2.2** `storage: true` appears on `v1alpha1`. In a CRD with several versions, how many may set `storage: true`, and what physically differs about the version that does?
- **Q2.3** In step 4 nothing validated that `image` was a real image or that `replicas` was sane — you could have set `replicas: -7`. Which field in the schema is doing the *only* validation present so far, and what did it enforce?
- **Q2.4** No controller exists. The `checkout` WebService created zero Pods. In self-service terms, what have you actually delivered to the developer at this point, and what is still missing before the resource *does* anything?

---

## Exercise 3 — Turn the schema into a real contract (structural schema + validation)

A permissive schema is a support ticket generator. Tighten it so the API rejects bad input at `kubectl apply` time, before any controller runs.

1. Replace the version's schema. This is a **structural schema**: every level declares a `type`, and constraints are attached to fields:

   ```yaml
   # apply as an update to the same CRD; only the versions[0].schema changes
   schema:
     openAPIV3Schema:
       type: object
       properties:
         spec:
           type: object
           properties:
             image:
               type: string
               pattern: '^[a-z0-9./-]+(:[a-zA-Z0-9._-]+)?$'
             replicas:
               type: integer
               minimum: 1
               maximum: 20
             port:
               type: integer
               minimum: 1
               maximum: 65535
             exposure:
               type: string
               enum: ["Internal", "Public"]
           required:
             - image
             - port
         status:
           type: object
           properties:
             availableReplicas:
               type: integer
           x-kubernetes-preserve-unknown-fields: false
       required:
         - spec
   ```

   Merge that into `webservice-crd-v1.yaml` under `versions[0].schema.openAPIV3Schema`, then:

   ```bash
   kubectl apply -f webservice-crd-v1.yaml
   ```

2. Prove the negative paths are actually rejected (a validating API is only proven by the errors it produces):

   ```bash
   # replicas out of range
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: WebService
   metadata: { name: bad-replicas }
   spec: { image: nginx:1.27, port: 80, replicas: 99 }
   EOF
   ```

   Expected:

   ```
   The WebService "bad-replicas" is invalid: spec.replicas: Invalid value: 99: spec.replicas in body should be less than or equal to 20
   ```

   ```bash
   # unknown field
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: WebService
   metadata: { name: typo }
   spec: { image: nginx:1.27, port: 80, replcias: 2 }
   EOF
   ```

   Expected:

   ```
   error: error validating data: ValidationError(WebService.spec): unknown field "replcias" in com.example.platform.v1alpha1.WebService.spec ...
   ```

   ```bash
   # missing required field
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: WebService
   metadata: { name: no-port }
   spec: { image: nginx:1.27 }
   EOF
   ```

   Expected:

   ```
   The WebService "no-port" is invalid: spec.port: Required value
   ```

3. Confirm the *good* path still applies:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: WebService
   metadata: { name: checkout }
   spec: { image: ghcr.io/acme/checkout:1.4.0, port: 8080, replicas: 3, exposure: Public }
   EOF
   ```

**Check your understanding**

- **Q3.1** Define a *structural schema* in your own words. Give two of the rules a schema must obey to qualify as structural.
- **Q3.2** The `unknown field "replcias"` rejection is *pruning* in action. Explain what pruning does to a field that is present in the object but absent from the schema, and why a self-service platform wants it on by default.
- **Q3.3** `x-kubernetes-preserve-unknown-fields: false` is set on `status`. When would you ever set it to `true` on a subtree, and what do you give up by doing so?
- **Q3.4** OpenAPI keywords like `enum`, `minimum` and `pattern` reject bad values. Name one *cross-field* invariant they fundamentally *cannot* express (e.g. "field A must be ≤ field B"), and hold that thought for the next exercise.

---

## Exercise 4 — Defaulting and CEL validation rules

OpenAPI constraints validate one field at a time. To default values and to express relationships *between* fields without an admission webhook, use schema `default` and `x-kubernetes-validations` (Common Expression Language, GA since Kubernetes 1.29).

1. Extend `spec` with defaults and CEL rules. Add `default:` to fields and a `x-kubernetes-validations` block at the `spec` level:

   ```yaml
   spec:
     type: object
     properties:
       image:
         type: string
         pattern: '^[a-z0-9./-]+(:[a-zA-Z0-9._-]+)?$'
       replicas:
         type: integer
         minimum: 1
         maximum: 20
         default: 1
       maxReplicas:
         type: integer
         minimum: 1
         maximum: 50
         default: 10
       port:
         type: integer
         minimum: 1
         maximum: 65535
       exposure:
         type: string
         enum: ["Internal", "Public"]
         default: "Internal"
     required:
       - image
       - port
     x-kubernetes-validations:
       - rule: "self.replicas <= self.maxReplicas"
         message: "replicas must not exceed maxReplicas"
       - rule: "self.exposure != 'Public' || has(self.port)"
         message: "Public services must declare a port"
   ```

   Apply the updated CRD.

2. Observe **defaulting** — omit the optional fields and read back what the API server stored:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: WebService
   metadata: { name: defaults-demo }
   spec: { image: nginx:1.27, port: 80 }
   EOF

   kubectl get ws defaults-demo -o jsonpath='{.spec}{"\n"}'
   ```

   Expected:

   ```json
   {"exposure":"Internal","image":"nginx:1.27","maxReplicas":10,"port":80,"replicas":1}
   ```

3. Observe **CEL validation** — violate the cross-field rule:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: WebService
   metadata: { name: over-scaled }
   spec: { image: nginx:1.27, port: 80, replicas: 15, maxReplicas: 5 }
   EOF
   ```

   Expected:

   ```
   The WebService "over-scaled" is invalid: spec: Invalid value: "object": replicas must not exceed maxReplicas
   ```

**Check your understanding**

- **Q4.1** In step 2 you sent 2 fields and read back 5. Where did the other 3 come from, and at what point in the request lifecycle were they injected — before or after the object was persisted to etcd?
- **Q4.2** The CEL rule `self.replicas <= self.maxReplicas` solves exactly the gap you identified in Q3.4. Why can this run inside the API server with no webhook, and what is one class of check CEL still *cannot* do (hint: it cannot read *other* objects)?
- **Q4.3** Defaulting requires a structural schema. Give the reason the two features are coupled.
- **Q4.4** A CEL *transition rule* can reference `oldSelf`. Sketch (in words) a rule that makes `spec.image`'s tag immutable-once-set, or makes `replicas` only ever increase. Why are transition rules evaluated only on update, never on create?

---

## Exercise 5 — Subresources and printer columns (make it operable)

Self-service is not just input validation; operators and developers need to *observe* the resource and scale it with standard tooling. That means a `/status` subresource, a `/scale` subresource, and useful `kubectl get` columns.

1. Add subresources and printer columns to the version. Under `versions[0]`, alongside `schema`:

   ```yaml
   - name: v1alpha1
     served: true
     storage: true
     subresources:
       status: {}
       scale:
         specReplicasPath: .spec.replicas
         statusReplicasPath: .status.availableReplicas
         labelSelectorPath: .status.selector
     additionalPrinterColumns:
       - name: Image
         type: string
         jsonPath: .spec.image
       - name: Desired
         type: integer
         jsonPath: .spec.replicas
       - name: Available
         type: integer
         jsonPath: .status.availableReplicas
       - name: Exposure
         type: string
         jsonPath: .spec.exposure
       - name: Age
         type: date
         jsonPath: .metadata.creationTimestamp
     schema:
       openAPIV3Schema:
         # ... same structural schema, but status now needs selector + availableReplicas ...
   ```

   Make sure `status` in the schema includes both `availableReplicas` (integer) and `selector` (string). Apply the CRD.

2. See the columns render:

   ```bash
   kubectl get ws
   ```

   Expected:

   ```
   NAME            IMAGE                        DESIRED   AVAILABLE   EXPOSURE   AGE
   checkout        ghcr.io/acme/checkout:1.4.0  3                     Public     10m
   defaults-demo   nginx:1.27                   1                     Internal   6m
   ```

3. Write to `status` through the **status subresource** (a spec-only write here is intentionally ignored):

   ```bash
   kubectl patch ws checkout --subresource=status --type=merge \
     -p '{"status":{"availableReplicas":3,"selector":"app=checkout"}}'

   kubectl get ws checkout
   ```

   Now `AVAILABLE` shows `3`.

4. Drive the resource with `kubectl scale` — the generic scale verb, working on your custom kind because you wired `/scale`:

   ```bash
   kubectl scale ws checkout --replicas=5
   kubectl get ws checkout -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   Expected: `5`

**Check your understanding**

- **Q5.1** With the `status` subresource enabled, what happens if a developer includes a `status:` block in a normal `kubectl apply` of the whole object? Which of the two — spec or status — does that request update?
- **Q5.2** `kubectl scale ws` worked on a resource that manages nothing. Explain the three JSONPaths in the `scale` subresource and why enabling `/scale` also means a `HorizontalPodAutoscaler` could target this custom resource.
- **Q5.3** `additionalPrinterColumns` are per-version. Why is the `AVAILABLE` column empty until step 3, and what does that reveal about the split between spec (user intent) and status (observed reality)?
- **Q5.4** Enabling the `status` subresource changes how the `metadata.generation` field behaves. What is the rule for when `generation` increments once a status subresource exists, and why is that useful to a controller?

---

## Exercise 6 — Versioning and a served upgrade path

Platform APIs evolve. You will promote `v1alpha1` to `v1beta1` while keeping the old version served so existing clients do not break. With schemas that differ only by additive, optional fields, you can use `conversion: strategy: None`.

1. Add a second version. Set the new version as `storage: true` and demote the old one; keep both `served: true`:

   ```yaml
   versions:
     - name: v1alpha1
       served: true
       storage: false            # was true
       # ... existing v1alpha1 schema/subresources/printer columns ...
     - name: v1beta1
       served: true
       storage: true             # new storage version
       subresources:
         status: {}
         scale:
           specReplicasPath: .spec.replicas
           statusReplicasPath: .status.availableReplicas
           labelSelectorPath: .status.selector
       additionalPrinterColumns:
         # ... same columns ...
       schema:
         openAPIV3Schema:
           # same structural schema as v1alpha1 PLUS one new optional field:
           #   spec.strategy: {type: string, enum: [RollingUpdate, Recreate], default: RollingUpdate}
   conversion:
     strategy: None
   ```

   Apply the CRD.

2. Read the *same object* through *both* versions — the API server converts on read:

   ```bash
   kubectl get webservice.v1alpha1.platform.example.com checkout -o jsonpath='{.apiVersion}{"\n"}'
   kubectl get webservice.v1beta1.platform.example.com  checkout -o jsonpath='{.apiVersion}{"\n"}'
   ```

   Expected:

   ```
   platform.example.com/v1alpha1
   platform.example.com/v1beta1
   ```

3. Inspect which versions are physically stored in etcd:

   ```bash
   kubectl get crd webservices.platform.example.com -o jsonpath='{.status.storedVersions}{"\n"}'
   ```

   Expected — both, because objects written under `v1alpha1` still sit in etcd at that version:

   ```
   ["v1alpha1","v1beta1"]
   ```

4. Migrate stored objects to the new storage version, then prune the old entry from `storedVersions`:

   ```bash
   # touching each object rewrites it at the current storage version (v1beta1)
   kubectl get ws -A -o name | xargs -r -I{} kubectl patch {} --type=merge -p '{}'
   # once no object remains at v1alpha1, remove it from status.storedVersions
   kubectl patch crd webservices.platform.example.com --subresource=status --type=merge \
     -p '{"status":{"storedVersions":["v1beta1"]}}'
   ```

**Check your understanding**

- **Q6.1** You changed `storage: true` from `v1alpha1` to `v1beta1`. Does that rewrite the objects already in etcd? What actually moves an existing object to the new storage version?
- **Q6.2** `conversion: strategy: None` was safe here. State precisely the condition under which `None` is correct, and the single-word name of the strategy you must switch to the moment that condition is violated.
- **Q6.3** Why is it dangerous to *remove* (`served: false` then delete) a version whose name still appears in `status.storedVersions`? What breaks, and what must you do first?
- **Q6.4** The `strategy: None` path forbids you from actually transforming data between versions, yet you added `spec.strategy` in `v1beta1`. Why does an *additive optional field with a default* not require real conversion logic, whereas *renaming* a field would?

---

## Exercise 7 — Ship it as a self-service API: discovery and RBAC

The API is only "self-service" if a developer can discover it without docs and use it without cluster-admin. Prove both.

1. Discovery — the API documents itself:

   ```bash
   kubectl api-resources --api-group=platform.example.com
   kubectl explain webservice.spec.exposure
   kubectl explain webservice.spec --recursive | head -20
   ```

   `kubectl explain` prints the `description` fields *if* you added them to the schema — a self-documenting API adds `description:` to every property. (If yours are blank, that is the finding.)

2. Grant a namespaced team access to *only* this custom API — no access to core resources:

   ```yaml
   # webservice-team-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: webservice-editor
     namespace: team-checkout
   rules:
     - apiGroups: ["platform.example.com"]
       resources: ["webservices"]
       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
     - apiGroups: ["platform.example.com"]
       resources: ["webservices/status"]
       verbs: ["get"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: webservice-editor-binding
     namespace: team-checkout
   subjects:
     - kind: ServiceAccount
       name: dev
       namespace: team-checkout
   roleRef:
     kind: Role
     name: webservice-editor
     apiGroup: rbac.authorization.k8s.io
   ```

   ```bash
   kubectl create namespace team-checkout
   kubectl create serviceaccount dev -n team-checkout
   kubectl apply -f webservice-team-rbac.yaml
   ```

3. Verify the boundary with `kubectl auth can-i`, impersonating the service account:

   ```bash
   SA="system:serviceaccount:team-checkout:dev"
   kubectl auth can-i create webservices.platform.example.com -n team-checkout --as="$SA"   # yes
   kubectl auth can-i create deployments.apps            -n team-checkout --as="$SA"        # no
   kubectl auth can-i create webservices.platform.example.com -n kube-system --as="$SA"      # no
   ```

   Expected:

   ```
   yes
   no
   no
   ```

**Check your understanding**

- **Q7.1** RBAC rules reference the custom API by `apiGroups: ["platform.example.com"]` and `resources: ["webservices"]`. Where do those two strings come from in the CRD, and why does RBAC treat a custom resource identically to a built-in one?
- **Q7.2** The Role grants `webservices` but only `webservices/status: [get]`. In practice, which actor in the system should hold *write* access to the `/status` subresource, and why is it deliberately withheld from the developer?
- **Q7.3** The developer can `create webservices` but not `create deployments`. Explain, in one sentence, how this single fact captures the entire value proposition of a CRD-based self-service platform.
- **Q7.4** `kubectl explain` returned useful text only because the schema carried `description:` fields. What does this imply about *where* the "documentation" of a self-service platform API should live, versus a separate wiki?

---

## Cleanup

```bash
kubectl delete crd webservices.platform.example.com   # cascades to every WebService object
kubectl delete namespace team-checkout
# kind delete cluster --name cnpa-42   # if you spun one up for this
```

> **Warning worth internalizing:** deleting the CRD garbage-collects *every custom resource of that kind, cluster-wide*, without a second prompt. On a real platform this is why production CRDs are protected and why finalizers exist — deleting the API definition must not silently delete the fleet built on it.

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**

- **A1.1** The `CustomResourceDefinition` object is **cluster-scoped** — a CRD is not owned by any namespace. That is independent of the scope of the resources it *defines*: `spec.scope` on the CRD chooses `Namespaced` or `Cluster` for the custom resources. So a cluster-scoped CRD can define namespaced custom resources (as our `WebService` does), and vice versa.
- **A1.2** (1) The **management API** — creating/reading the `CustomResourceDefinition` object itself — lives in `apiextensions.k8s.io/v1`. (2) The **new custom API** — the `WebService` kind and its REST endpoints — lives in the group you declared, `platform.example.com`. One `kubectl apply` of a CRD registers a brand-new REST path (`/apis/platform.example.com/v1alpha1/…`) served by the same kube-apiserver.
- **A1.3** The CRD's `spec.versions[].schema.openAPIV3Schema` is an OpenAPI v3 schema. The API server merges it into the cluster's published OpenAPI/discovery documents, and `kubectl explain` reads that schema (including `description` fields) to describe fields it otherwise knows nothing about. The CRD *is* the API's type definition and, if you write descriptions, its documentation.
  Source: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/

**Exercise 2**

- **A2.1** A CRD's `metadata.name` **must** equal `<spec.names.plural>.<spec.group>` — here `webservices.platform.example.com`. If it does not, the API server rejects the create with a validation error; the name is not free-form, it is derived.
- **A2.2** Exactly **one** version may set `storage: true`. That is the version in which objects are **serialized and persisted to etcd**. All other served versions are converted to/from the storage version on the fly for reads and writes.
- **A2.3** The only validation is `spec.required: [image]` from the OpenAPI schema — it enforces that `image` is present. Nothing constrained `replicas`, so `replicas: -7` would have been accepted. That is the gap Exercises 3–4 close.
- **A2.4** You delivered a **declarative API**: developers can `kubectl apply`/`get`/`delete` a `WebService`, and the object is stored and served. What is missing is a **controller/operator** that watches these objects and reconciles real Deployments/Services from them. Topic 4.2 is about the API contract; the acting controller is the complementary half of the platform.
  Source: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/

**Exercise 3**

- **A3.1** A **structural schema** is an OpenAPI v3 schema where every field's type is known: each level specifies a `type` (and object levels list their `properties`), constraints hang off individual fields, and the forbidden constructs (`additionalProperties` at the same level as `properties`, top-level `oneOf/anyOf/not` shaping the whole object, `type` left unset) are absent. `apiextensions.k8s.io/v1` **requires** structural schemas. Two concrete rules: (1) each node sets a non-empty `type`; (2) `additionalProperties` and `properties` are mutually exclusive at a given level. Source: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema
- **A3.2** **Pruning** strips any field not defined in the structural schema before the object is persisted — with `apiextensions.k8s.io/v1` it is on by default. A typo like `replcias` is caught (client-side validation surfaces it as an error; even if it slipped through, the server would drop it) rather than silently stored as dead data. A self-service platform wants this so that developers get told about mistakes instead of accumulating fields nothing will ever read.
- **A3.3** Set `x-kubernetes-preserve-unknown-fields: true` on a subtree only when you deliberately want to store arbitrary, schema-less content there (e.g. an embedded template, or opaque vendor config). You give up pruning and validation for that subtree — the platform can no longer guarantee the shape of what is stored, and `kubectl explain` cannot document it.
- **A3.4** OpenAPI keywords are per-field and cannot express **cross-field invariants** such as "`replicas` ≤ `maxReplicas`", "if `exposure == Public` then `port` is required", or any relationship between two fields. That is precisely what CEL `x-kubernetes-validations` adds in Exercise 4.

**Exercise 4**

- **A4.1** `exposure`, `maxReplicas` and `replicas` came from the schema's `default:` values. **Defaulting is applied on the server, during admission, before the object is persisted** — which is why reading it straight back from etcd shows the filled-in values. (Client-side `kubectl` does not invent them.)
- **A4.2** CEL rules run **inside the API server** during admission because they are compiled expressions evaluated against the object being admitted — no external webhook process is needed, so there is no extra latency or availability risk. CEL cannot read **other objects** in the cluster (e.g. "reject if another WebService already uses this port") — validation rules see only `self` (and `oldSelf` on updates); cross-object checks still require a validating admission webhook or a controller. Source: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- **A4.3** Defaulting writes values into fields, so the API server must know each field's exact type and position — that guarantee is exactly what a structural schema provides. Without it, the server could not safely place defaults, so `default:` is only permitted under structural schemas.
- **A4.4** A transition rule references `oldSelf`, e.g. `self.image == oldSelf.image` (image immutable once set) or `self.replicas >= oldSelf.replicas` (scale only up). These need the *previous* stored object to compare against, which does not exist on a **create** — there is no `oldSelf` — so transition rules are evaluated only on **update**.

**Exercise 5**

- **A5.1** With the `status` subresource enabled, a normal write to the main resource endpoint **updates only `spec` (and metadata); the `status` block in the payload is ignored.** To change `status` you must write to the `/status` subresource (`kubectl patch --subresource=status`). This enforces the split: users own spec, controllers own status.
- **A5.2** The three paths tell the scale subresource where to read/write: `specReplicasPath: .spec.replicas` is the desired count that `kubectl scale`/HPA *writes*; `statusReplicasPath: .status.availableReplicas` is the observed count they *read*; `labelSelectorPath: .status.selector` is the selector string an HPA uses to find the Pods whose metrics to average. Because the resource now speaks the standard `scale` interface, an HPA can target it via `scaleTargetRef` exactly as it targets a Deployment. Source: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#scale-subresource
- **A5.3** `AVAILABLE` maps to `.status.availableReplicas`, which is empty until a controller (here, you, via `kubectl patch --subresource=status`) writes it. `DESIRED` (`.spec.replicas`) is set the moment the user applies the object. The gap between them *is* the spec/status distinction: spec is declared intent, status is observed reality, and they converge only when something reconciles.
- **A5.4** Once a `status` subresource exists, `metadata.generation` **increments only when `spec` (the desired state) changes, not when `status` changes.** A controller compares `status.observedGeneration` to `metadata.generation` to know whether it has already reconciled the latest spec — a clean, race-free "is my work current?" signal.

**Exercise 6**

- **A6.1** No — flipping `storage: true` to a new version does **not** rewrite existing etcd objects. They stay serialized at the version they were last written in. An object moves to the new storage version only when it is **written again** (any create/update/patch, e.g. the no-op `patch` in step 4 or the built-in storage-version migrator). Source: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- **A6.2** `conversion: strategy: None` is correct only when **every served version has an identical schema apart from `apiVersion` and `kind`** — i.e. the API server can convert between them by just relabeling, with no field transformation. The moment any field differs in name/shape/semantics between versions, you must switch to `strategy: Webhook` (a conversion webhook).
- **A6.3** `status.storedVersions` lists every version at which objects still physically exist in etcd. If you delete (stop serving and remove) a version still listed there, the API server can no longer **decode** those stored objects and reads fail. You must first **migrate all objects off that version** (rewrite them under the current storage version), then remove the version's name from `status.storedVersions`, and only then drop the version from the CRD.
- **A6.4** An **additive, optional field with a default** (`spec.strategy`) needs no conversion: read as `v1alpha1` it is simply absent/pruned; read as `v1beta1` it is present with its default. No existing data has to be reshaped, so identity conversion (`None`) is lossless. **Renaming** a field changes where data lives, so a `v1alpha1` object read as `v1beta1` (or vice versa) would need the value physically moved — that transformation is exactly what a conversion webhook exists to perform, and why `None` is no longer valid.

**Exercise 7**

- **A7.1** `apiGroups` is the CRD's `spec.group` (`platform.example.com`) and `resources` is `spec.names.plural` (`webservices`); the `/status` and `/scale` subresources are addressed as `webservices/status`, `webservices/scale`. RBAC operates on the generic (group, resource, verb) triple resolved through discovery, so it makes **no distinction** between a built-in and a custom resource — installing a CRD immediately makes the custom API governable by ordinary Roles/ClusterRoles.
- **A7.2** The **controller/operator** that reconciles `WebService` objects should hold write access to `webservices/status`; it is the only actor entitled to report observed state. It is withheld from developers so they cannot forge status (e.g. claim `availableReplicas: 5` when nothing is running) — preserving the invariant that spec is user intent and status is machine-observed truth.
- **A7.3** The developer can create a high-level `WebService` but not the low-level `Deployment` it expands into — the platform exposes a curated, validated, guard-railed API and hides the primitives, which is the entire point of a self-service platform.
- **A7.4** The documentation should live **in the CRD schema itself** (`description:` on every property), so it ships with the API, versions with the API, and is served through `kubectl explain` and discovery — always in sync. A separate wiki drifts; a schema `description` cannot, because it is the same artifact the API is defined by.

</details>

---

**Sources**
- CNPA Curriculum (Domain 4 — Platform APIs & Provisioning): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Extend the Kubernetes API with CustomResourceDefinitions: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Custom Resources (concept): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/
- CRD Versioning & conversion: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- Validation rules (CEL): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/