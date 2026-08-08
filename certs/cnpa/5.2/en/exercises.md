# 5.2 — API-Driven Service Catalogs and Infrastructure Abstractions — Guided Exercises

> **What you are building.** A platform where infrastructure is consumed the same way you consume the Kubernetes API: you declare *what* you want in a resource, and a controller reconciles the *how*. You will (1) stand up the API substrate, (2) publish a high-level platform API that hides infrastructure detail, (3) consume it self-service and observe reconciliation and drift correction, and (4) surface it in a service catalog as a golden path and diagnose it end-to-end.
>
> **Tooling used:** [Crossplane](https://docs.crossplane.io/) as the Kubernetes-native control plane for abstractions, [provider-kubernetes](https://github.com/crossplane-contrib/provider-kubernetes) so the lab needs **no cloud account**, and [Backstage](https://backstage.io/docs/features/software-catalog/) for the human-facing catalog.
>
> **Prerequisites:** `kind` ≥ 0.23, `kubectl` ≥ 1.29, `helm` ≥ 3.14, the `crossplane` CLI plugin, `jq`. Exercise 4's Backstage steps run against a local Backstage instance (`npx @backstage/create-app`) but can also be read as a modeling exercise if you don't have one running.
>
> **Version note (read this).** Crossplane is mid-transition. This lab uses the widely-documented **Claim + inline-schema XRD** model and the **Composition Functions pipeline** (`mode: Pipeline`), which is the path the current docs recommend and which forward-ports cleanly. Package tags drift fast — treat every `:vX.Y.Z` below as "check the current release on the [Upbound Marketplace](https://marketplace.upbound.io/) / GitHub releases and substitute."

---

## Exercise 1 — Stand up the platform API substrate

**Goal:** see that "installing infrastructure capabilities" literally means "adding new endpoints to the Kubernetes API," and that the Kubernetes API *is itself* a service catalog you can query.

1. Create a disposable cluster:

   ```bash
   kind create cluster --name platform
   kubectl cluster-info --context kind-platform
   ```

2. Snapshot the API surface **before** installing anything. This count is your baseline:

   ```bash
   kubectl api-resources --no-headers | wc -l
   ```

   Expected: a number around `50–60` (core + built-in extension groups).

3. Install Crossplane:

   ```bash
   helm repo add crossplane-stable https://charts.crossplane.io/stable
   helm repo update
   helm install crossplane crossplane-stable/crossplane \
     --namespace crossplane-system --create-namespace --wait
   kubectl get pods -n crossplane-system
   ```

   Expected:

   ```
   NAME                                       READY   STATUS    RESTARTS   AGE
   crossplane-6b9d8f5c4b-abcde                1/1     Running   0          40s
   crossplane-rbac-manager-7c5d9f6d8-fghij    1/1     Running   0          40s
   ```

4. Install the Kubernetes provider and the patch-and-transform function:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: pkg.crossplane.io/v1
   kind: Provider
   metadata:
     name: provider-kubernetes
   spec:
     package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.13.0
   ---
   apiVersion: pkg.crossplane.io/v1
   kind: Function
   metadata:
     name: function-patch-and-transform
   spec:
     package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
   EOF

   kubectl get providers,functions
   ```

   Wait until both report `INSTALLED=True` and `HEALTHY=True`:

   ```
   NAME                                            INSTALLED   HEALTHY   PACKAGE                                                          AGE
   provider.pkg.crossplane.io/provider-kubernetes  True        True      xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.13.0   90s

   NAME                                                        INSTALLED   HEALTHY   PACKAGE                                                                 AGE
   function.pkg.crossplane.io/function-patch-and-transform     True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0  90s
   ```

5. Re-count the API surface and diff against the baseline:

   ```bash
   kubectl api-resources --no-headers | wc -l
   kubectl api-resources --api-group=kubernetes.crossplane.io
   kubectl api-resources --api-group=apiextensions.crossplane.io
   ```

   The total jumped by tens of new kinds. The `kubernetes.crossplane.io` group now offers an `Object` kind; `apiextensions.crossplane.io` offers `CompositeResourceDefinition` and `Composition`.

6. Grant the provider's ServiceAccount permission to act on the cluster (it runs as its own SA, which starts with almost no RBAC — this is the single most common first-run failure):

   ```bash
   SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | head -1 | cut -d/ -f2)
   kubectl create clusterrolebinding provider-kubernetes-admin \
     --clusterrole=cluster-admin \
     --serviceaccount="crossplane-system:${SA}"
   ```

7. Wire the provider to talk to its *own* cluster using its injected identity, then confirm it is usable:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: kubernetes.crossplane.io/v1alpha1
   kind: ProviderConfig
   metadata:
     name: default
   spec:
     credentials:
       source: InjectedIdentity
   EOF
   ```

**Check your understanding — Block 1**

1. When you installed provider-kubernetes, what mechanism actually added the new API endpoints? Was it the Kubernetes *API aggregation layer* or something else — and why does that distinction matter operationally?
2. `kubectl api-resources` shows a `NAMESPACED` column. Why is it accurate to call the output of that command a "service catalog," and what is missing from it that a Backstage catalog would add?
3. In step 6 you bound `cluster-admin` to the provider SA. In a real platform, why is that grant a security smell, and what would you scope it down to?

---

## Exercise 2 — Publish a platform API (the abstraction)

**Goal:** as the *platform team*, define a new high-level API — `AppSpace` — whose consumers never see namespaces, quotas, or network policy. The **`openAPIV3Schema` is the contract**: it is the entire public surface the app teams program against.

1. Create the `CompositeResourceDefinition` (XRD). This declares *two* new kinds at once — a cluster-scoped Composite Resource (`XAppSpace`) and its namespaced Claim (`AppSpace`):

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: apiextensions.crossplane.io/v1
   kind: CompositeResourceDefinition
   metadata:
     name: xappspaces.platform.example.org
   spec:
     group: platform.example.org
     names:
       kind: XAppSpace
       plural: xappspaces
     claimNames:
       kind: AppSpace
       plural: appspaces
     defaultCompositionRef:
       name: appspace-kubernetes
     versions:
       - name: v1alpha1
         served: true
         referenceable: true
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 properties:
                   parameters:
                     type: object
                     properties:
                       team:
                         type: string
                         description: Owning team; becomes the namespace suffix.
                       cpuLimit:
                         type: string
                         default: "2"
                       memoryLimit:
                         type: string
                         default: "4Gi"
                     required:
                       - team
                 required:
                   - parameters
               status:
                 type: object
                 properties:
                   namespaceName:
                     type: string
   EOF
   ```

2. Confirm the XRD was accepted and its generated CRDs became `Established`:

   ```bash
   kubectl get xrd
   kubectl get crd | grep platform.example.org
   ```

   Expected:

   ```
   NAME                              ESTABLISHED   OFFERED   AGE
   xappspaces.platform.example.org   True          True      10s

   appspaces.platform.example.org     2026-08-07T...
   xappspaces.platform.example.org    2026-08-07T...
   ```

   `OFFERED=True` means the *claim* API (`AppSpace`) was generated in addition to the composite (`XAppSpace`).

3. Observe that your new API now appears in the same catalog you queried in Exercise 1 — and note the `NAMESPACED` values:

   ```bash
   kubectl api-resources --api-group=platform.example.org
   ```

   Expected:

   ```
   NAME         SHORTNAMES   APIVERSION                        NAMESPACED   KIND
   appspaces                 platform.example.org/v1alpha1     true         AppSpace
   xappspaces                platform.example.org/v1alpha1     false        XAppSpace
   ```

4. Read the contract exactly as an app developer would — with no access to your source YAML:

   ```bash
   kubectl explain appspace.spec.parameters
   ```

   Expected (abridged):

   ```
   FIELD: parameters <Object>
   DESCRIPTION: <empty>
   FIELDS:
     cpuLimit    <string>
     memoryLimit <string>
     team        <string> -required-
   ```

**Check your understanding — Block 2**

1. `kubectl api-resources` reported `appspaces` as `NAMESPACED=true` but `xappspaces` as `false`. Explain the intended division of responsibility this encodes, and who "owns" each of the two objects.
2. The XRD version is marked `referenceable: true` and `served: true`. What does each flag control, and what breaks if you later add a `v1beta1` version but forget to move `referenceable` to it?
3. You gave `cpuLimit` a `default: "2"` in the schema. Where and when is that default applied — at `kubectl apply` time, at admission, or during composition — and why does the answer matter for auditing what a team actually requested?
4. Nothing in this exercise created a namespace or quota. What, concretely, exists in the cluster after Exercise 2, and what would happen if an app team submitted a Claim *right now*?

---

## Exercise 3 — Implement and consume the abstraction

**Goal:** bind the API to a concrete implementation with a `Composition`, then consume it self-service as an app team and watch the claim → composite → managed-resource chain reconcile. Finally, break it on purpose to see drift correction.

1. As the platform team, author the `Composition` that maps one `AppSpace` to a `Namespace`, a `ResourceQuota`, and a default-deny `NetworkPolicy` — all created as provider-kubernetes `Object`s:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: apiextensions.crossplane.io/v1
   kind: Composition
   metadata:
     name: appspace-kubernetes
   spec:
     compositeTypeRef:
       apiVersion: platform.example.org/v1alpha1
       kind: XAppSpace
     mode: Pipeline
     pipeline:
       - step: patch-and-transform
         functionRef:
           name: function-patch-and-transform
         input:
           apiVersion: pt.fn.crossplane.io/v1beta1
           kind: Resources
           resources:
             - name: namespace
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha1
                 kind: Object
                 spec:
                   providerConfigRef:
                     name: default
                   forProvider:
                     manifest:
                       apiVersion: v1
                       kind: Namespace
                       metadata:
                         name: placeholder
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.team
                   toFieldPath: spec.forProvider.manifest.metadata.name
                   transforms:
                     - type: string
                       string:
                         fmt: "team-%s"
                 - type: ToCompositeFieldPath
                   fromFieldPath: spec.forProvider.manifest.metadata.name
                   toFieldPath: status.namespaceName
             - name: quota
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha1
                 kind: Object
                 spec:
                   providerConfigRef:
                     name: default
                   forProvider:
                     manifest:
                       apiVersion: v1
                       kind: ResourceQuota
                       metadata:
                         name: compute
                         namespace: placeholder
                       spec:
                         hard:
                           limits.cpu: "2"
                           limits.memory: 4Gi
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.team
                   toFieldPath: spec.forProvider.manifest.metadata.namespace
                   transforms:
                     - type: string
                       string:
                         fmt: "team-%s"
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.cpuLimit
                   toFieldPath: spec.forProvider.manifest.spec.hard['limits.cpu']
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.memoryLimit
                   toFieldPath: spec.forProvider.manifest.spec.hard['limits.memory']
             - name: netpol
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha1
                 kind: Object
                 spec:
                   providerConfigRef:
                     name: default
                   forProvider:
                     manifest:
                       apiVersion: networking.k8s.io/v1
                       kind: NetworkPolicy
                       metadata:
                         name: default-deny
                         namespace: placeholder
                       spec:
                         podSelector: {}
                         policyTypes: ["Ingress"]
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.team
                   toFieldPath: spec.forProvider.manifest.metadata.namespace
                   transforms:
                     - type: string
                       string:
                         fmt: "team-%s"
   EOF
   ```

2. **Switch hats.** As an app developer, submit a Claim — a small, readable request with no mention of namespaces or policies:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.org/v1alpha1
   kind: AppSpace
   metadata:
     name: payments
     namespace: default
   spec:
     parameters:
       team: payments
       cpuLimit: "4"
       memoryLimit: 8Gi
   EOF
   ```

3. Watch the whole chain reconcile in one view (this is the command you will reach for constantly):

   ```bash
   crossplane beta trace appspace payments -n default
   ```

   Expected once settled:

   ```
   NAME                            SYNCED   READY   STATUS
   AppSpace/payments (default)     True     True    Available
   └─ XAppSpace/payments-7t2x9     True     True    Available
      ├─ Object/payments-7t2x9-... True     True    Available
      ├─ Object/payments-7t2x9-... True     True    Available
      └─ Object/payments-7t2x9-... True     True    Available
   ```

4. Verify the abstraction actually materialized real, standard Kubernetes objects:

   ```bash
   kubectl get ns team-payments
   kubectl get resourcequota compute -n team-payments -o jsonpath='{.spec.hard}'; echo
   kubectl get networkpolicy default-deny -n team-payments
   ```

   Expected quota reflects the *4 / 8Gi* the developer asked for, not the schema defaults:

   ```
   {"limits.cpu":"4","limits.memory":"8Gi"}
   ```

5. Confirm the status flowed *back up* from the composed resource to the claim (`ToCompositeFieldPath`):

   ```bash
   kubectl get appspace payments -n default -o jsonpath='{.status.namespaceName}'; echo
   ```

   Expected: `team-payments`.

6. **Break it to see self-healing.** Delete the managed `ResourceQuota` out from under Crossplane and watch it come back:

   ```bash
   kubectl delete resourcequota compute -n team-payments
   sleep 15
   kubectl get resourcequota -n team-payments
   ```

   The quota reappears — the composed `Object` controller reconciled the external state back to desired.

**Check your understanding — Block 3**

1. Trace the four-tier chain that `crossplane beta trace` printed: Claim → Composite → `Object` (managed resource) → the actual `Namespace`/`ResourceQuota`. Which of these is *namespaced*, which is *cluster-scoped*, and which lives *outside* Crossplane's own API?
2. In step 4 the quota shows `4 / 8Gi`, overriding the XRD's `"2" / 4Gi` defaults. Follow the exact path a value takes from the developer's Claim to the `ResourceQuota.spec.hard` field. Name every hop.
3. In step 6, deletion was corrected automatically, but deleting the `AppSpace` Claim would cascade-delete everything. What Kubernetes mechanism links the composed `Object`s to the composite so this cleanup happens, and what is the `deletionPolicy` knob that could change it?
4. The `ResourceQuota` and `NetworkPolicy` reference a namespace that the `Namespace` object may not have created yet, since Crossplane submits composed resources concurrently. Why does the provision still converge instead of failing permanently?

---

## Exercise 4 — Catalog it as a golden path, then diagnose

**Goal:** the platform API from Exercises 2–3 is powerful but invisible to a developer browsing a portal. Here you register it in Backstage as a **catalog entity** and a **self-service template** (a golden path), understand that the catalog is *also* an API, and practice tracing a failed provision end-to-end.

### Part A — Model the abstraction in the service catalog

1. Describe the abstraction as a first-class catalog entity. Create `catalog-info.yaml`:

   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Resource
   metadata:
     name: appspace
     description: Self-service namespaced application environment with quota + default-deny.
     tags: [crossplane, golden-path, self-service]
   spec:
     type: environment
     owner: platform-team
     system: developer-platform
   ---
   apiVersion: backstage.io/v1alpha1
   kind: System
   metadata:
     name: developer-platform
   spec:
     owner: platform-team
   ```

2. Author the golden path — a Scaffolder `Template` that turns a form into a Crossplane Claim via a GitOps pull request (the catalog never touches the cluster directly). Create `template.yaml`:

   ```yaml
   apiVersion: scaffolder.backstage.io/v1beta3
   kind: Template
   metadata:
     name: request-appspace
     title: Request an Application Space
     description: Provision a namespaced environment with quotas via Crossplane.
     tags: [crossplane, golden-path]
   spec:
     owner: platform-team
     type: resource
     parameters:
       - title: Application Space
         required: [team]
         properties:
           team:
             title: Team name
             type: string
           cpuLimit:
             title: CPU limit
             type: string
             default: "4"
           memoryLimit:
             title: Memory limit
             type: string
             default: "8Gi"
     steps:
       - id: render
         name: Render Claim
         action: fetch:template
         input:
           url: ./skeleton
           values:
             team: ${{ parameters.team }}
             cpuLimit: ${{ parameters.cpuLimit }}
             memoryLimit: ${{ parameters.memoryLimit }}
       - id: pr
         name: Open PR to platform-claims
         action: publish:github:pull-request
         input:
           repoUrl: github.com?owner=acme&repo=platform-claims
           branchName: appspace-${{ parameters.team }}
           title: "Provision AppSpace for ${{ parameters.team }}"
           description: Generated by the Request an Application Space golden path.
   ```

   The `./skeleton/appspace.yaml` the template renders is exactly the Claim you hand-wrote in Exercise 3, step 2 — parameterized.

3. Register both files in Backstage (App → **Create...** → **Register Existing Component**, or add a `catalog.locations` entry pointing at the repo path). Then confirm the catalog ingested them by hitting the **catalog API directly** — the portal is a thin UI over this:

   ```bash
   curl -s "http://localhost:7007/api/catalog/entities/by-name/resource/default/appspace" | jq '{kind, name: .metadata.name, owner: .spec.owner, relations}'
   ```

   Expected (abridged):

   ```json
   {
     "kind": "Resource",
     "name": "appspace",
     "owner": "platform-team",
     "relations": [
       { "type": "ownedBy",  "targetRef": "group:default/platform-team" },
       { "type": "partOf",   "targetRef": "system:default/developer-platform" }
     ]
   }
   ```

### Part B — Diagnose a broken provision

4. Simulate the most common real-world failure: submit a Claim while the provider lacks RBAC (undo the grant from Exercise 1 first to reproduce), or simply submit a claim for a team whose Composition step has a typo. Provision, then walk the diagnosis ladder — **top-down**:

   ```bash
   # 1. Is the claim itself progressing?
   kubectl get appspace -A
   # 2. Full tree with statuses — where does READY go False?
   crossplane beta trace appspace <name> -n <ns>
   # 3. Read events on the object that is stuck
   kubectl describe object <stuck-object-name>
   # 4. Provider logs for the real API error
   kubectl -n crossplane-system logs -l pkg.crossplane.io/provider=provider-kubernetes --tail=40
   ```

   A missing-RBAC failure surfaces as an `Object` stuck `SYNCED=False` with an event like:

   ```
   cannot create object: namespaces is forbidden: User "system:serviceaccount:crossplane-system:provider-kubernetes-..." cannot create resource "namespaces"
   ```

**Check your understanding — Block 4**

1. The Scaffolder template does **not** run `kubectl apply`; it opens a pull request. What does the platform gain by routing self-service through GitOps instead of writing to the cluster from the portal, and what does it cost?
2. The catalog API returned `relations` you never wrote in the YAML (`ownedBy`, `partOf`). Where did those come from, and what component of Backstage produces them during ingestion?
3. You have *two* catalogs now — `kubectl api-resources` (the machine API surface) and the Backstage catalog (the human-facing one). For each of these questions, say which catalog answers it: (a) "What fields must I set to request an AppSpace?" (b) "Who owns the AppSpace capability and what system is it part of?" (c) "Is my specific `payments` AppSpace healthy right now?"
4. In the diagnosis ladder, why is the correct order top-down (Claim → Composite → managed `Object` → provider logs) rather than starting from the provider logs? What does each rung *rule out*?
5. The failure in step 4 showed `SYNCED=False` on the `Object`, not `READY=False`. In Crossplane's status conventions, what is the difference between `Synced` and `Ready`, and which one tells you the provider couldn't even *talk* to the target API?

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1

1. **CRDs, not the aggregation layer.** Crossplane providers install `CustomResourceDefinition`s; the same `kube-apiserver` serves them, backed by the same `etcd`, and they participate in normal RBAC, admission, and `kubectl` discovery. The *aggregation layer* (an `APIService` proxying to a separate extension API server) is the other extension path and is what things like `metrics-server` use. The distinction is operational: CRD-based APIs get durable etcd storage, versioning/conversion webhooks, and structural schemas "for free," and they fail independently per-resource; an aggregated API server is a separate process you must run, scale, and keep available, and if it's down that whole API group returns errors. Crossplane deliberately chose CRDs so your platform APIs behave exactly like native ones.
2. `kubectl api-resources` is a **machine-readable catalog of every kind the API server can serve** — name, group/version, whether it's namespaced, and its short names — and `kubectl explain` / the OpenAPI schema (`kubectl get --raw /openapi/v3`) give you each kind's field contract. That's a genuine service catalog for anything that speaks Kubernetes. What it lacks is the **human/organizational layer**: ownership, lifecycle stage, documentation, dependencies/relations, links to dashboards and runbooks, and a "request this" button. That layer is exactly what Backstage adds in Exercise 4.
3. `cluster-admin` lets the provider do *anything* to *any* resource, so a compromised provider pod, or a buggy Composition, can delete or mutate the entire cluster. It's a lab shortcut. In production you scope the provider's ServiceAccount to a purpose-built `ClusterRole` (or namespaced `Role`s) that grants only the verbs and resource types your Compositions actually touch — here that would be `create/get/update/delete` on `namespaces`, `resourcequotas`, and `networkpolicies`, nothing else. Least privilege turns "provider bug" from cluster-fatal into blast-radius-bounded.

### Block 2

1. `XAppSpace` (cluster-scoped, `NAMESPACED=false`) is the **Composite Resource (XR)** — the platform team's object and the reconciliation unit that owns the composed infrastructure. `AppSpace` (namespaced, `NAMESPACED=true`) is the **Claim** — the app team's object, living in *their* namespace so it's subject to their RBAC and quotas. The Claim is a thin, namespaced handle; Crossplane creates a matching cluster-scoped XR behind it and keeps them in sync. Division of ownership: app teams create Claims in their namespaces; the platform team owns the XRD, the Composition, and (indirectly) the XRs.
2. `served: true` means the API server will accept and return objects at that version (clients can read/write it). `referenceable: true` marks the version that Compositions bind to via `compositeTypeRef` — the "current canonical" version for composition. If you add `v1beta1` and leave `referenceable` on `v1alpha1`, your `v1beta1` objects are servable but **no Composition can target them** (`compositeTypeRef` must point at a referenceable version), so claims/XRs at the new version won't compose anything. Exactly one version may be `referenceable`.
3. The default is applied by the **API server at admission (CRD structural-schema defaulting)**, the same way defaults work for any CRD — so it's baked into the stored object *before* Crossplane ever composes it. That matters for auditing: `kubectl get appspace payments -o yaml` will show `cpuLimit: "2"` as if the developer typed it, even though they omitted it. If you need to distinguish "requested 2" from "defaulted to 2," you cannot rely on the persisted object — you'd track it at the source (the Git PR / template inputs) instead.
4. After Exercise 2 the cluster holds only *API definitions*: the XRD and its two generated CRDs (`appspaces`, `xappspaces`). There is **no Composition yet**. If an app team submitted a Claim now, it would be accepted and stored, a matching XR would be created, but reconciliation would stall — the XR would report it cannot find a Composition to satisfy `compositeTypeRef`, and `SYNCED` would stay `False`. Nothing infrastructural gets built until Exercise 3 supplies the Composition.

### Block 3

1. Four tiers:
   - **Claim `AppSpace/payments`** — *namespaced* (in `default`), the app team's object.
   - **Composite `XAppSpace/payments-7t2x9`** — *cluster-scoped*, the platform's reconciliation unit.
   - **`Object/...` managed resources** — *cluster-scoped* Crossplane MRs; each is a Crossplane-managed *representation* of an external object.
   - **The actual `Namespace` / `ResourceQuota` / `NetworkPolicy`** — the *external* objects, which happen to live in this same cluster but are "outside" Crossplane's API in the sense that provider-kubernetes reconciles them like any external system's resources.
2. Path of the CPU value: developer's Claim `spec.parameters.cpuLimit: "4"` → Crossplane copies Claim spec to the Composite `XAppSpace.spec.parameters.cpuLimit` → the Composition's `FromCompositeFieldPath` patch on the `quota` resource reads `spec.parameters.cpuLimit` → writes it to that `Object`'s `spec.forProvider.manifest.spec.hard['limits.cpu']` → provider-kubernetes applies that embedded manifest, creating/updating the real `ResourceQuota.spec.hard['limits.cpu']: "4"`. Five hops: Claim → XR → composition patch → `Object` manifest → external `ResourceQuota`.
3. **Owner references.** Each composed `Object` carries an `ownerReference` back to the `XAppSpace`, and the Claim owns the XR. Deleting the Claim triggers Kubernetes garbage collection down the chain, and Crossplane then asks the provider to delete the external objects. The knob is `spec.deletionPolicy` (or, on newer providers, `spec.managementPolicies`) on the managed resource: `Delete` (default) removes the external object; `Orphan` detaches it, leaving the real `ResourceQuota`/`Namespace` in place after the MR is gone — useful when you don't want teardown of an abstraction to wipe real data.
4. **Reconciliation is retried, not one-shot.** provider-kubernetes tries to apply the `ResourceQuota` `Object`, gets a "namespace not found" error, marks that `Object` `SYNCED=False`, and requeues. On a subsequent loop the `Namespace` `Object` has been created, the retry succeeds, and the system converges. This eventual-consistency-through-requeue behavior is why Crossplane doesn't need explicit ordering/`dependsOn` for most compositions — transient ordering errors self-heal.

### Block 4

1. **Gain:** every provisioning request becomes a reviewable, auditable Git commit; the desired state is version-controlled and reconciled by the GitOps controller, so the cluster state is reproducible and the portal needs no cluster credentials (smaller blast radius, no standing write access from a public-facing app). **Cost:** added latency and moving parts — a request isn't live until the PR is merged and the GitOps controller syncs; you must run and secure that pipeline; and simple requests feel heavier than a direct apply. It's the classic trade of immediacy for auditability and safety.
2. Backstage's **catalog processors** derive relations during ingestion. `spec.owner` and `spec.system` are *references*; the processors resolve them into concrete `ownedBy` / `partOf` relation edges (and reciprocal `hasPart` edges on the target) in the entity graph. You declare intent (owner: platform-team); the processor materializes the typed relations you queried.
3. (a) `kubectl explain` / the OpenAPI schema behind `kubectl api-resources` — the **machine catalog** holds the field contract. (b) The **Backstage catalog** — ownership and system membership are organizational metadata that only live there. (c) The **machine catalog / live cluster** (`kubectl get appspace payments` / `crossplane beta trace`) — runtime health of a specific instance is cluster state, not portal metadata (unless Backstage's Kubernetes plugin is surfacing it, but the source of truth is the cluster).
4. Top-down mirrors the abstraction stack and each rung *rules out* a layer. Claim healthy but XR unhealthy ⇒ the Composition/binding is wrong, not the developer's request. XR healthy but an `Object` unhealthy ⇒ a specific composed resource is failing, not the whole composition. `Object` `SYNCED=False` ⇒ go to provider logs for the raw API error. Starting at the provider logs floods you with every reconcile for every tenant and gives no map of *which* claim or *which* resource is affected — you'd see the symptom (a forbidden error) without knowing whose provision it broke.
5. **`Synced`** reports whether Crossplane successfully reconciled the resource *with the external API* — i.e., whether it could talk to the target and apply desired state. **`Ready`** reports whether the resulting external resource is up and usable. `Synced=False` means the provider couldn't even complete the API call (auth failure, RBAC-forbidden, bad manifest, unreachable endpoint) — that's the RBAC case here. `Synced=True, Ready=False` means the call succeeded but the thing isn't operational yet (still provisioning, failing health checks). Diagnosing `Synced=False` sends you to provider/credentials/RBAC; `Ready=False` sends you to the external resource itself.

</details>

---

### Sources

- CNCF CNPA curriculum — https://github.com/cncf/curriculum
- Kubernetes, *Custom Resources* & API extension — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Crossplane, *Composite Resource Definitions* — https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
- Crossplane, *Compositions* & *Composition Functions* — https://docs.crossplane.io/latest/concepts/compositions/
- Crossplane, *Composite Resources & Claims* — https://docs.crossplane.io/latest/concepts/composite-resources/
- provider-kubernetes — https://github.com/crossplane-contrib/provider-kubernetes
- Backstage, *Software Catalog* (entity model & relations) — https://backstage.io/docs/features/software-catalog/
- Backstage, *Software Templates* (Scaffolder) — https://backstage.io/docs/features/software-templates/
- Open Service Broker API (historical service-catalog standard) — https://www.openservicebrokerapi.org/
- CNOE reference platform (IDP patterns) — https://cnoe.io/