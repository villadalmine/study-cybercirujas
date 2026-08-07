# Topic 4.3 — Infrastructure Provisioning with Kubernetes (Crossplane / Kratix)

**Certification:** CNPA (Certified Cloud Native Platform Engineering Associate) — exam version 2025-04-01
**Exam weight:** 3.0

> These guided exercises build a small **internal developer platform (IDP)** control plane on a local `kind` cluster. You will provision real resources declaratively with **Crossplane** (control-plane / reconciliation model) and deliver capabilities as products with **Kratix** (Promise / workflow model), then diagnose both. Every step is runnable without cloud credentials: we use `provider-kubernetes` so the "external system" Crossplane manages is the cluster itself, and Kratix schedules to the same cluster acting as its own Destination.
>
> **Reference sources**
> - Crossplane docs — concepts & architecture: https://docs.crossplane.io/latest/concepts/
> - Crossplane Compositions & Composition Functions: https://docs.crossplane.io/latest/concepts/compositions/ · https://docs.crossplane.io/latest/concepts/composition-functions/
> - `provider-kubernetes`: https://github.com/crossplane-contrib/provider-kubernetes
> - Kratix docs — Promises & Workflows: https://docs.kratix.io/main/reference/promises/intro · https://docs.kratix.io/main/reference/workflows/intro
> - CNCF Platforms White Paper (TAG App Delivery): https://tag-app-delivery.cncf.io/whitepapers/platforms/
> - CNPA Curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf

## Prerequisites

```bash
# Verify tooling
kind version        # >= 0.22
kubectl version --client
helm version        # >= 3.12

# Create a dedicated cluster to act as our platform control plane
kind create cluster --name cnpa-platform
kubectl config use-context kind-cnpa-platform
```

Expected:

```
Creating cluster "cnpa-platform" ...
 ✓ Ensuring node image (kindest/node:v1.30.0) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-cnpa-platform"
```

---

## Exercise 1 — Install Crossplane and map the control-plane architecture

**Goal:** install the Crossplane core and identify the control loop, the extension CRDs, and the RBAC manager.

1. Install the Crossplane core via Helm into its own namespace.

   ```bash
   helm repo add crossplane-stable https://charts.crossplane.io/stable
   helm repo update
   helm install crossplane crossplane-stable/crossplane \
     --namespace crossplane-system --create-namespace --wait
   ```

2. Inspect the two core Deployments and confirm they are Ready.

   ```bash
   kubectl -n crossplane-system get deploy
   ```

   Expected:

   ```
   NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
   crossplane                 1/1     1            1           40s
   crossplane-rbac-manager    1/1     1            1           40s
   ```

3. List the CRDs the core installs. These are the *extension points* — Crossplane ships with almost no resource types of its own; it installs the machinery to install and compose them.

   ```bash
   kubectl get crds | grep crossplane.io
   ```

   Expected (abridged):

   ```
   compositeresourcedefinitions.apiextensions.crossplane.io
   compositions.apiextensions.crossplane.io
   compositionrevisions.apiextensions.crossplane.io
   configurations.pkg.crossplane.io
   functions.pkg.crossplane.io
   locks.pkg.crossplane.io
   providers.pkg.crossplane.io
   providerrevisions.pkg.crossplane.io
   ```

4. Look at what the RBAC manager does by watching it grant permissions later. For now, confirm it exists and note its purpose.

   ```bash
   kubectl -n crossplane-system logs deploy/crossplane-rbac-manager --tail=5
   ```

**Verify your understanding — Block 1**

- **Q1.1** Crossplane is described as "a control plane framework, not a resource type." What does the core install ship, and what does it deliberately *not* ship?
- **Q1.2** Name the three package kinds under `pkg.crossplane.io` (Provider, Configuration, Function) and state what each contributes to the platform.
- **Q1.3** What is the job of `crossplane-rbac-manager`, and why is it a separate Deployment from the main controller?
- **Q1.4** Contrast Crossplane's model against a run-to-completion IaC tool such as Terraform, in terms of *how drift is handled*.

---

## Exercise 2 — Install a Provider and a ProviderConfig

**Goal:** extend the control plane with a Provider, understand ProviderRevisions, and wire authentication with a ProviderConfig.

1. Install `provider-kubernetes`. A Provider is an OCI package that, once healthy, installs new Managed Resource CRDs and starts their controllers.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: pkg.crossplane.io/v1
   kind: Provider
   metadata:
     name: provider-kubernetes
   spec:
     package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.16.0
   EOF
   ```

2. Wait until the Provider reports `HEALTHY=True` (this triggers a rollout of the provider Deployment and installation of its CRDs).

   ```bash
   kubectl get providers
   kubectl wait provider/provider-kubernetes --for=condition=Healthy --timeout=180s
   ```

   Expected:

   ```
   NAME                  INSTALLED   HEALTHY   PACKAGE                                                             AGE
   provider-kubernetes   True        True      xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.16.0     60s
   provider.pkg.crossplane.io/provider-kubernetes condition met
   ```

3. Inspect the ProviderRevision and the new CRD the provider added.

   ```bash
   kubectl get providerrevisions
   kubectl get crds | grep kubernetes.crossplane.io
   ```

   Expected:

   ```
   NAME                            HEALTHY   REVISION   ...   STATE
   provider-kubernetes-6f2c1a9b    True      1                Active
   objects.kubernetes.crossplane.io
   providerconfigs.kubernetes.crossplane.io
   providerconfigusages.kubernetes.crossplane.io
   ```

4. `provider-kubernetes` targets *this* cluster using its own pod ServiceAccount (`InjectedIdentity`). That SA has no permissions yet, so grant it. Bind the provider's runtime SA to `cluster-admin` (scope this down in production).

   ```bash
   SA=$(kubectl -n crossplane-system get sa -o name \
        | grep provider-kubernetes \
        | sed -e 's|serviceaccount/|crossplane-system:|g')
   kubectl create clusterrolebinding provider-kubernetes-admin \
     --clusterrole=cluster-admin --serviceaccount="${SA}"
   ```

5. Create the ProviderConfig that tells Managed Resources *how to authenticate*.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kubernetes.crossplane.io/v1alpha1
   kind: ProviderConfig
   metadata:
     name: default
   spec:
     credentials:
       source: InjectedIdentity
   EOF
   ```

**Verify your understanding — Block 2**

- **Q2.1** What is the difference between a `Provider` and a `ProviderRevision`? What happens to the old revision when you bump the package tag?
- **Q2.2** A `Provider` (package) and a `ProviderConfig` are two different things with confusingly similar names. What does each one define, and which namespace/scope does each live in?
- **Q2.3** For a real cloud provider (e.g. `provider-aws-s3`), what are the common `credentials.source` values, and why is `InjectedIdentity` (IRSA / Workload Identity) preferred over a static `Secret`?
- **Q2.4** Why did the `Object` MR need a ClusterRoleBinding in step 4, even though the Crossplane core was already running?

---

## Exercise 3 — Provision a Managed Resource and observe reconciliation & self-healing

**Goal:** create a Managed Resource (MR), read its status conditions, understand the external-name annotation, and prove the reconciliation loop corrects drift.

1. Create an `Object` MR that provisions a Namespace as its external resource.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kubernetes.crossplane.io/v1alpha1
   kind: Object
   metadata:
     name: team-a-namespace
   spec:
     forProvider:
       manifest:
         apiVersion: v1
         kind: Namespace
         metadata:
           name: team-a
     providerConfigRef:
       name: default
   EOF
   ```

2. Watch the MR reach `SYNCED=True` and `READY=True`.

   ```bash
   kubectl get object team-a-namespace -o wide
   ```

   Expected:

   ```
   NAME               KIND        PROVIDERCONFIG   SYNCED   READY   AGE
   team-a-namespace   Namespace   default          True     True    15s
   ```

3. Inspect the two conditions and the external-name annotation that binds the MR to its real-world object.

   ```bash
   kubectl get object team-a-namespace \
     -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}{"\n"}'
   kubectl get object team-a-namespace -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
   kubectl get ns team-a
   ```

   Expected:

   ```
   team-a
   Synced=True (ReconcileSuccess)
   Ready=True (Available)
   NAME     STATUS   AGE
   team-a   Active   30s
   ```

4. **Prove self-healing.** Delete the *external* resource directly (bypassing Crossplane) and watch the controller recreate it.

   ```bash
   kubectl delete ns team-a
   sleep 10
   kubectl get ns team-a
   ```

   Expected — the namespace comes back because the desired state still exists:

   ```
   NAME     STATUS   AGE
   team-a   Active   3s
   ```

5. Explore how deletion is governed. Set an explicit management policy that observes but never deletes, then inspect.

   ```bash
   kubectl patch object team-a-namespace --type=merge \
     -p '{"spec":{"deletionPolicy":"Orphan"}}'
   kubectl get object team-a-namespace -o jsonpath='{.spec.deletionPolicy}{"\n"}'
   ```

**Verify your understanding — Block 3**

- **Q3.1** A Managed Resource has two independent conditions, `Synced` and `Ready`. What does each one mean, and give a concrete scenario where `Synced=True` but `Ready=False`.
- **Q3.2** What is the `crossplane.io/external-name` annotation for? What happens on the *next* reconcile if you change it by hand on an existing MR?
- **Q3.3** In step 4 the namespace was recreated. Explain the reconciliation loop that produced this (observe → diff → act) and why this is called a *continuous* control loop rather than a one-shot apply.
- **Q3.4** Contrast `deletionPolicy: Orphan` with the newer `managementPolicies` (e.g. `["Observe"]`). When would a platform team use `Observe` to *import* pre-existing infrastructure?

---

## Exercise 4 — Publish a platform API: XRD + Composition (pipeline functions) + Claim

**Goal:** move from "operator provisions raw MRs" to "app teams consume a self-service API." You define the API (XRD), the implementation (Composition using a composition function), and the app team files a Claim.

1. Install the patch-and-transform composition function. In modern Crossplane, Compositions run a **pipeline of functions**; patching is itself a function.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: pkg.crossplane.io/v1beta1
   kind: Function
   metadata:
     name: function-patch-and-transform
   spec:
     package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
   EOF
   kubectl wait function/function-patch-and-transform --for=condition=Healthy --timeout=180s
   ```

2. Define the **CompositeResourceDefinition (XRD)** — this generates the cluster-scoped `XAppNamespace` API *and* the namespaced `AppNamespace` claim API.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: apiextensions.crossplane.io/v1
   kind: CompositeResourceDefinition
   metadata:
     name: xappnamespaces.platform.cnpa.io
   spec:
     group: platform.cnpa.io
     names:
       kind: XAppNamespace
       plural: xappnamespaces
     claimNames:
       kind: AppNamespace
       plural: appnamespaces
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
                 team:
                   type: string
                 environment:
                   type: string
                   enum: ["dev", "staging", "prod"]
                   default: dev
               required:
               - team
   EOF
   ```

3. Define the **Composition** — the implementation that maps one `XAppNamespace` to one `Object` MR, patching the team name into the namespace.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: apiextensions.crossplane.io/v1
   kind: Composition
   metadata:
     name: appnamespace-kubernetes
   spec:
     compositeTypeRef:
       apiVersion: platform.cnpa.io/v1alpha1
       kind: XAppNamespace
     mode: Pipeline
     pipeline:
     - step: patch-and-transform
       functionRef:
         name: function-patch-and-transform
       input:
         apiVersion: pt.fn.crossplane.io/v1beta1
         kind: Resources
         resources:
         - name: ns
           base:
             apiVersion: kubernetes.crossplane.io/v1alpha1
             kind: Object
             spec:
               forProvider:
                 manifest:
                   apiVersion: v1
                   kind: Namespace
                   metadata:
                     name: placeholder
                     labels:
                       platform.cnpa.io/managed: "true"
               providerConfigRef:
                 name: default
           patches:
           - type: FromCompositeFieldPath
             fromFieldPath: spec.team
             toFieldPath: spec.forProvider.manifest.metadata.name
           - type: FromCompositeFieldPath
             fromFieldPath: spec.environment
             toFieldPath: spec.forProvider.manifest.metadata.labels[platform.cnpa.io/env]
   EOF
   ```

4. **Act as an app team.** File a namespaced Claim — the app team never touches Providers, MRs, or credentials.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: platform.cnpa.io/v1alpha1
   kind: AppNamespace
   metadata:
     name: payments
     namespace: default
   spec:
     team: payments-prod
     environment: prod
   EOF
   ```

5. Trace the full object graph from claim → composite → managed → external resource.

   ```bash
   kubectl get appnamespace,xappnamespace,object
   crossplane beta trace appnamespace.platform.cnpa.io/payments -n default
   kubectl get ns payments-prod --show-labels
   ```

   Expected (trace, abridged):

   ```
   NAME                                              SYNCED   READY   STATUS
   AppNamespace/payments (default)                   True     True    Available
   └─ XAppNamespace/payments-abc12                   True     True    Available
      └─ Object/payments-abc12-x7k2p                 True     True    Available
   ```

**Verify your understanding — Block 4**

- **Q4.1** Distinguish the four objects in play: **XRD**, **Composition**, **Composite Resource (XR)**, and **Claim (XRC)**. Who authors each, and what scope (cluster vs namespaced) does each have?
- **Q4.2** When the Claim was created, Crossplane created an XR with a generated suffix (`payments-abc12`). Why the indirection — why not have the Claim reconcile MRs directly?
- **Q4.3** With multiple Compositions for the same XRD (e.g. one backed by `provider-kubernetes`, one by `provider-aws`), how does an XR/Claim select which one runs? Name two mechanisms.
- **Q4.4** What does `mode: Pipeline` change versus the legacy inline `resources:` array, and why did the CNCF ecosystem standardize on **composition functions**? Name one thing a function can do that static patches cannot.

---

## Exercise 5 — Install Kratix and map its Promise/Workflow architecture

**Goal:** stand up Kratix on the same cluster and understand its fundamentally different model — Kratix delivers **Promises** (products) via **Workflows** that schedule outputs to **Destinations** through a **State Store**.

1. Install the Kratix control plane.

   ```bash
   kubectl apply --filename https://github.com/syntasso/kratix/releases/latest/download/kratix.yaml
   kubectl -n kratix-platform-system rollout status deploy/kratix-platform-controller-manager
   ```

2. Set up a State Store (MinIO in-cluster) and register the platform cluster as its own worker **Destination** (Kratix writes scheduled documents to the store; Flux on the Destination reconciles them). Use the documented single-cluster quick-start bundle:

   ```bash
   # MinIO bucket state store + GitOps toolkit (Flux) on the worker Destination
   kubectl apply --filename https://raw.githubusercontent.com/syntasso/kratix/main/hack/platform/minio-install.yaml
   kubectl apply --filename https://raw.githubusercontent.com/syntasso/kratix/main/config/samples/platform_v1alpha1_worker.yaml
   ```

   > If the exact URLs have moved, follow https://docs.kratix.io/main/getting-started — the objects (`BucketStateStore`, `Destination`) are stable.

3. Inspect the Kratix CRDs and the registered Destination.

   ```bash
   kubectl get crds | grep kratix.io
   kubectl get destinations,bucketstatestores
   ```

   Expected:

   ```
   destinations.platform.kratix.io
   promises.platform.kratix.io
   bucketstatestores.platform.kratix.io
   works.platform.kratix.io
   workplacements.platform.kratix.io
   NAME                                         AGE
   destination.platform.kratix.io/worker-1      30s
   NAME                                                       AGE
   bucketstatestore.platform.kratix.io/default                45s
   ```

**Verify your understanding — Block 5**

- **Q5.1** Kratix's tagline is "build your own platform." Name the four core Kratix abstractions (**Promise**, **Resource Request**, **Workflow/Pipeline**, **Destination**) and give a one-line definition of each.
- **Q5.2** What is the role of the **State Store** (`BucketStateStore` / `GitStateStore`) and why does Kratix rely on a GitOps agent (Flux/Argo) *on the Destination* rather than pushing manifests directly with `kubectl apply`?
- **Q5.3** What are `Work` and `WorkPlacement` resources, and where do they sit in the scheduling pipeline between a Resource Request and a Destination?
- **Q5.4** Kratix explicitly supports scheduling outputs to *many* Destinations (multiple clusters, or a namespace on one cluster). How does `destinationSelectors` (label matching) drive that placement?

---

## Exercise 6 — Author/consume a Kratix Promise and request an instance

**Goal:** install a Promise, file a Resource Request as an app team, and watch the pipeline containers turn the request into scheduled output.

1. Install a Promise. A Promise bundles three things: an **API** (a CRD it installs), **dependencies** (pre-requisite manifests scheduled to Destinations), and **workflows** (pipeline containers). We use the sample `postgresql` Promise.

   ```bash
   kubectl apply --filename https://raw.githubusercontent.com/syntasso/kratix-marketplace/main/postgresql/promise.yaml
   ```

2. Confirm the Promise installed its API onto the platform.

   ```bash
   kubectl get promises
   kubectl get crds | grep postgresql
   ```

   Expected:

   ```
   NAME         STATUS      KIND         API VERSION                              AGE
   postgresql   Available   postgresql   marketplace.kratix.io/v1alpha1           25s
   postgresqls.marketplace.kratix.io
   ```

3. **Act as an app team** — file a Resource Request against the Promise's API.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: marketplace.kratix.io/v1alpha1
   kind: postgresql
   metadata:
     name: acme-db
     namespace: default
   spec:
     env: production
   EOF
   ```

4. Watch Kratix run the **resource configure workflow** — a Job/Pod that reads the request from `/kratix/input`, generates manifests, and writes them to `/kratix/output`.

   ```bash
   kubectl get pods -l kratix.io/promise-name=postgresql
   kubectl logs -l kratix.io/work-type=resource --tail=20
   kubectl get works,workplacements
   ```

   Expected (abridged):

   ```
   NAME                                     STATUS      COMPLETIONS
   acme-db-configure-xxxxx                  Completed   1/1
   NAME                                          AGE
   work.platform.kratix.io/acme-db-default       40s
   NAME                                                    DESTINATION   AGE
   workplacement.platform.kratix.io/acme-db-default...     worker-1      38s
   ```

5. Verify the scheduled output landed on the Destination (Flux reconciled the documents from the state store).

   ```bash
   kubectl get statefulset,svc -l app=acme-db -A
   ```

**Verify your understanding — Block 6**

- **Q6.1** Open the Promise spec and name its three top-level sections. What does each contribute, and which one installs the CRD that the app team's Resource Request targets?
- **Q6.2** A Kratix Workflow container follows a strict filesystem contract. What is at `/kratix/input`, what must the container write to `/kratix/output`, and what is `/kratix/metadata` for?
- **Q6.3** Distinguish a **Promise Workflow** from a **Resource Workflow**. When does each fire?
- **Q6.4** **Crossplane vs Kratix — the core exam distinction.** Both provision infrastructure from Kubernetes, but their execution models differ. Contrast: (a) *continuous reconciliation of typed Managed Resources* vs *run-to-completion pipeline containers producing arbitrary manifests*; (b) how each delivers output to a *target cluster*; (c) when you would reach for one over the other.

---

## Exercise 7 — Diagnostics: debug a broken provisioning path in both systems

**Goal:** practise the failure-triage workflow for Crossplane and Kratix, the two most exam-relevant "it's stuck, why?" scenarios.

1. **Break Crossplane:** reference a Composition function that isn't installed, then observe the failure surfacing on the Claim.

   ```bash
   kubectl patch composition appnamespace-kubernetes --type=json \
     -p '[{"op":"replace","path":"/spec/pipeline/0/functionRef/name","value":"function-does-not-exist"}]'
   kubectl apply -f - <<'EOF'
   apiVersion: platform.cnpa.io/v1alpha1
   kind: AppNamespace
   metadata:
     name: broken
     namespace: default
   spec:
     team: broken-team
   EOF
   ```

2. Triage top-down: claim → composite → events.

   ```bash
   crossplane beta trace appnamespace.platform.cnpa.io/broken -n default
   kubectl describe xappnamespace | sed -n '/Events/,$p'
   ```

   Expected — the error names the missing function:

   ```
   Warning  ComposeResources  ...  cannot resolve function "function-does-not-exist": Function not found
   ```

3. Fix it and confirm recovery.

   ```bash
   kubectl patch composition appnamespace-kubernetes --type=json \
     -p '[{"op":"replace","path":"/spec/pipeline/0/functionRef/name","value":"function-patch-and-transform"}]'
   kubectl get appnamespace broken -w   # Ctrl-C once READY=True
   ```

4. **Second Crossplane failure mode — provider RBAC.** Simulate a permission failure by removing the provider's binding, then read where the error surfaces (on the MR's `Synced` condition, not the claim's schema).

   ```bash
   kubectl delete clusterrolebinding provider-kubernetes-admin
   kubectl get object -o wide          # SYNCED flips to False after next reconcile
   kubectl get object team-a-namespace -o jsonpath='{.status.conditions[?(@.type=="Synced")].message}{"\n"}'
   # restore
   SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed -e 's|serviceaccount/|crossplane-system:|g')
   kubectl create clusterrolebinding provider-kubernetes-admin --clusterrole=cluster-admin --serviceaccount="${SA}"
   ```

   Expected message (abridged):

   ```
   ... namespaces is forbidden: User "system:serviceaccount:crossplane-system:provider-kubernetes-..." cannot ...
   ```

5. **Break Kratix:** find a failed resource pipeline. When a workflow container exits non-zero, the Job fails and no `Work` is produced.

   ```bash
   kubectl get pods -l kratix.io/promise-name=postgresql
   # inspect the failing pipeline pod's logs and the pipeline Job status
   kubectl logs job/<failed-configure-job>
   kubectl get works,workplacements       # a missing Work == pipeline never completed
   kubectl -n kratix-platform-system logs deploy/kratix-platform-controller-manager --tail=30
   ```

6. **Delivery-side Kratix failure:** the pipeline completed (Work exists) but nothing appears on the Destination — check the state store and the Destination's GitOps agent.

   ```bash
   kubectl get bucketstatestores,destinations
   kubectl describe workplacement <name>     # look for scheduling/write errors
   kubectl -n flux-system get kustomizations  # Flux on the worker — is it reconciling the store?
   ```

**Verify your understanding — Block 7**

- **Q7.1** For a Crossplane Claim stuck at `READY=False`, what is the correct triage *order* (which object do you inspect first, and how do you walk down the graph)? Which single CLI command collapses this walk?
- **Q7.2** In step 4 the error appeared on the **Object MR's `Synced` condition**, not on the Claim's spec validation. Explain *why* schema errors and runtime provisioning errors surface at different layers of the XRD→XR→MR chain.
- **Q7.3** A Kratix Resource Request exists but no resources ever appear on the Destination. List the *two distinct failure classes* — pipeline-side vs delivery-side — and the specific object you would inspect to distinguish them.
- **Q7.4** Both platforms can leave "zombie" state. For Crossplane, what does `deletionPolicy: Orphan` / `managementPolicies` leave behind on delete? For Kratix, what happens to previously-scheduled documents in the state store when a Resource Request is deleted?

---

## Cleanup

```bash
kind delete cluster --name cnpa-platform
```

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — Crossplane architecture

**A1.1** The core ships the **control-plane machinery**: the main Crossplane controller (the package manager and composition engine) plus the RBAC manager, and the *extension-point CRDs* under `apiextensions.crossplane.io` (XRDs, Compositions, CompositionRevisions) and `pkg.crossplane.io` (Providers, Configurations, Functions, and their Revisions/Locks). It deliberately ships **no infrastructure resource types of its own** — you can't create an S3 bucket or a database with just the core. Those types arrive only when you install a Provider. Crossplane is a *framework for building control planes*, not a fixed catalogue.

**A1.2**
- **Provider** — an OCI package that installs a set of Managed Resource CRDs (e.g. `Bucket`, `RDSInstance`) and runs their controllers, which reconcile against an external API.
- **Configuration** — an OCI package that bundles your *platform APIs*: XRDs + Compositions (+ Function dependencies). It is how you distribute an opinionated platform.
- **Function** — an OCI package containing a **composition function** (a gRPC server) invoked in a Composition pipeline to compute desired resources.

**A1.3** `crossplane-rbac-manager` watches XRDs and Providers and **auto-generates the RBAC** (ClusterRoles / bindings) needed so the Crossplane controller and users can act on the newly-installed CRDs — e.g. when a Provider adds a `Bucket` CRD, the core controller needs permission to manage `Bucket` objects. It's a separate Deployment so RBAC generation (a security-sensitive, cluster-admin-level capability) is isolated and can be disabled or replaced independently of the main reconciler.

**A1.4** Terraform is **run-to-completion**: you run `apply`, it computes a plan against last-known state, mutates, and exits — drift between runs is invisible until the next `plan`. Crossplane runs a **continuous control loop**: each Managed Resource is reconciled forever, so if the external resource drifts (someone deletes it or changes it out-of-band) Crossplane detects the difference on the next reconcile and corrects it back to desired state. Desired state lives in etcd as a first-class API object, not in a state file.

### Block 2 — Providers & configuration

**A2.1** A `Provider` is the **desired package** (the tag you want). A `ProviderRevision` is a **specific installed version** of it — installing/upgrading a Provider creates a new revision. On a tag bump, the new revision becomes `Active` and the previous one moves to `Inactive` (its CRDs/controllers are stopped but, by default, retained per `revisionHistoryLimit`), enabling rollback. This mirrors how Deployments manage ReplicaSets.

**A2.2**
- A **Provider (package)** defines *which controllers and MR types exist* on the control plane. It's cluster-scoped (`pkg.crossplane.io/v1`).
- A **ProviderConfig** defines *how MRs authenticate* to the external system (credentials source, assume-role, endpoint). It's the provider's own API (e.g. `kubernetes.crossplane.io/v1alpha1`), cluster-scoped, and referenced by each MR via `providerConfigRef`.
One provider can have many ProviderConfigs (e.g. one per cloud account/region).

**A2.3** Common `credentials.source` values: `Secret` (static keys — simplest, worst hygiene), `InjectedIdentity` (use the provider pod's identity — IRSA on EKS, Workload Identity on GKE, or, here, the pod SA), `Environment`, `Filesystem`, and provider-specific `WebIdentity`/`OIDC`. `InjectedIdentity` is preferred because it uses **short-lived, automatically-rotated tokens** federated to the workload — no long-lived secret to store, leak, or rotate manually.

**A2.4** Because `provider-kubernetes` performs its writes **as its own runtime ServiceAccount** (`InjectedIdentity`), not as the Crossplane core controller. That SA starts with no permissions, so creating a Namespace would return `403 Forbidden` until you bind it. The core controller being privileged doesn't help — the *provider pod* is the one making the API calls.

### Block 3 — Managed Resources & reconciliation

**A3.1**
- **`Synced`** — Crossplane successfully *reconciled the desired spec with the external API* (the create/update call succeeded; no diff pending).
- **`Ready`** — the external resource is *actually available/usable* per the provider's readiness check.
Scenario: an RDS instance — the `CreateDBInstance` call succeeds (`Synced=True`) but the database is still `creating` for several minutes (`Ready=False`).

**A3.2** `crossplane.io/external-name` records the **identifier of the real external resource** the MR is bound to (here, the namespace name; for cloud MRs, the ARN/ID). It's how Crossplane finds the resource on the next reconcile instead of creating a duplicate. If you change it by hand on an existing MR, Crossplane will look for an external resource with the *new* name — effectively re-pointing (or, if none exists, creating a new one), which is how you **adopt/import** existing infra by setting the external-name before creation.

**A3.3** The controller runs `observe → diff → act` continuously: it *observes* the external world (queries whether `team-a` exists), *diffs* against desired state (spec says it should exist), and *acts* (recreates it). When you deleted the namespace, the next reconcile observed "missing," diffed to "should exist," and issued a create. It is *continuous* because the loop re-runs on a resync interval and on watch events forever — unlike a one-shot `apply` that only acts at invocation time.

**A3.4** `deletionPolicy: Orphan` controls only *what happens on MR deletion* (leave the external resource behind vs delete it). `managementPolicies` is finer-grained and controls the *whole lifecycle*: `["Observe"]` means Crossplane will **read but never create, update, or delete** — perfect for importing pre-existing infrastructure read-only (populate status/connection details without risk of Crossplane mutating it), later widening to `["*"]` to take full ownership.

### Block 4 — Platform APIs

**A4.1**
- **XRD (CompositeResourceDefinition)** — authored by the **platform team**; defines the *schema/API* (the `XAppNamespace` and its `AppNamespace` claim). Cluster-scoped.
- **Composition** — authored by the **platform team**; the *implementation* mapping an XR to concrete resources via a function pipeline. Cluster-scoped.
- **Composite Resource (XR)** — an *instance* of the API, cluster-scoped, usually created indirectly.
- **Claim (XRC)** — the **app team's** *namespaced* request; it points to (and creates) an XR.

**A4.2** The indirection separates **tenant-facing (namespaced Claim)** from **platform-facing (cluster-scoped XR + MRs)**. App teams live in namespaces and get RBAC only on Claims; the actual MRs (which hold credentials and cluster-scoped power) live behind the XR where tenants can't touch them. It also lets one XR be shared/referenced while claims map 1:1 to teams. (Note: Crossplane v2 makes XRs namespaced and de-emphasizes Claims, but the exam-era model uses the Claim→XR split.)

**A4.3** (1) **`compositionRef`** — the XR/Claim names an exact Composition. (2) **`compositionSelector.matchLabels`** — selects any Composition carrying matching labels. Additionally the XRD's **`defaultCompositionRef`** is used when neither is set, and `enforcedCompositionRef` can force one.

**A4.4** `mode: Pipeline` runs an **ordered list of composition functions** (each a gRPC server) that receive the observed state and return desired resources; patch-and-transform is just one such function. The ecosystem standardized on functions because static patches are limited to field copying/transforms — they can't do **loops, conditionals, external data lookups, or generate a variable number of resources**. A function can, for example, create N subnets from a count field, call out for data, or run arbitrary logic (`function-go-templating`, `function-kcl`, `function-cel`).

### Block 5 — Kratix architecture

**A5.1**
- **Promise** — a packaged platform *product*: an API (CRD) + dependencies + workflows. "What the platform offers."
- **Resource Request** — an *instance* of a Promise's API, filed by an app team ("give me one Postgres").
- **Workflow/Pipeline** — one or more *containers* Kratix runs to transform a request (or the Promise itself) into output manifests.
- **Destination** — a *target* (cluster or namespace) where scheduled outputs are delivered.

**A5.2** The State Store is the **source of truth for scheduled documents** — Kratix's pipelines write generated manifests into a bucket or Git repo, keyed per Destination. Kratix relies on a GitOps agent *on the Destination* (pull-based) rather than pushing with `kubectl apply` because it **decouples the platform cluster from workload clusters** (no direct credentials/network path to every target), gives **auditability and drift-correction for free** (Flux/Argo continuously reconciles), and scales to many Destinations without the platform holding kubeconfigs to all of them.

**A5.3** When a pipeline finishes, Kratix creates a **`Work`** (the bundle of output documents that need placing). The scheduler then matches it against Destinations and creates a **`WorkPlacement`** per chosen Destination, which is what actually **writes the documents into that Destination's path in the State Store**. So: Request → pipeline → `Work` → (scheduling) → `WorkPlacement` → State Store → (Flux) → Destination.

**A5.4** Both Promises (via `destinationSelectors`) and Destinations carry **labels**. During scheduling Kratix matches a Work's selectors against Destination labels; a Work is placed (a `WorkPlacement` created) on every Destination whose labels satisfy the selector. This lets you target, say, `environment: prod` clusters, or fan a dependency out to all Destinations, purely by label — no hardcoded cluster names.

### Block 6 — Promises & the Crossplane/Kratix distinction

**A6.1** A Promise has: **`api`** (the CRD it installs onto the platform — this is what the app team's Resource Request targets, plus optional defaults/validation), **`dependencies`** (static manifests, e.g. an operator/CRDs, scheduled to Destinations before requests are served), and **`workflows`** (the `promise.configure` and `resource.configure` pipelines). The `api` section installs the request CRD.

**A6.2** The Kratix container contract:
- **`/kratix/input`** — the incoming object (e.g. `object.yaml`, the Resource Request) is mounted read-only for the pipeline to read.
- **`/kratix/output`** — the pipeline **must write** the manifests it wants scheduled; Kratix collects everything here into a `Work`.
- **`/kratix/metadata`** — for pipeline-emitted metadata such as `destination-selectors.yaml` (per-request scheduling overrides) and `status.yaml` (status written back onto the Resource Request).

**A6.3** A **Promise Workflow** (`workflows.promise.configure`) fires **once when the Promise is installed/updated** — used to lay down shared dependencies (operators, CRDs, cluster-wide config). A **Resource Workflow** (`workflows.resource.configure`) fires **on every Resource Request** create/update — it turns a specific request into that instance's manifests.

**A6.4**
- **(a) Execution model:** Crossplane maintains **typed Managed Resources under continuous reconciliation** — a controller per resource type endlessly enforcing desired state against an external API. Kratix runs **run-to-completion pipeline containers** that emit *arbitrary* manifests (Helm output, operator CRs, plain YAML) once per request; it doesn't model each resource as a reconciled type.
- **(b) Delivery:** Crossplane's providers act **directly** on external APIs from the control-plane cluster. Kratix **writes to a State Store and lets a GitOps agent on each Destination pull** — delivery is decoupled and multi-cluster-native.
- **(c) When to choose:** Reach for **Crossplane** when you want strongly-typed, continuously-reconciled, drift-correcting infrastructure with a rich provider ecosystem, especially cloud resources. Reach for **Kratix** when you want to **package a whole product/experience** (including operators, Helm charts, multi-cluster placement, and arbitrary logic) as a Promise and deliver it across many clusters — and note the two **compose**: a Promise's pipeline commonly emits Crossplane Claims.

### Block 7 — Diagnostics

**A7.1** Triage **top-down through the ownership graph**: start at the **Claim** → its **Composite (XR)** → the **Managed Resources** → the external system, reading `Synced`/`Ready` conditions and `Events` at each level; the failure is usually at the lowest level that shows `False`. The command that collapses the whole walk is **`crossplane beta trace <claim/xr>`**, which renders the tree with each object's status in one view.

**A7.2** They surface at different layers because they are enforced at different layers. **Schema/validation** errors (bad enum, missing required field) are caught by the **XRD's OpenAPI schema on the XR/Claim** at admission time — before anything is provisioned. **Runtime provisioning** errors (a `403`, a quota limit, a bad credential) only occur when the **provider controller actually calls the external API**, so they appear on the **Managed Resource's `Synced` condition**. The Claim can be schema-valid yet its downstream MR can fail — you must descend to the MR to see it.

**A7.3**
- **Pipeline-side:** the workflow container failed (non-zero exit) so **no `Work` was ever produced**. Inspect the **pipeline Job/Pod logs** in the request's namespace and the Kratix controller logs. Symptom: `Work` missing.
- **Delivery-side:** the pipeline succeeded (`Work` and `WorkPlacement` exist) but documents aren't reconciled onto the target. Inspect the **`WorkPlacement`** (write errors to the store), the **`BucketStateStore`/`Destination`** health, and the **GitOps agent (Flux Kustomization) on the Destination**. Symptom: `Work`/`WorkPlacement` present, but nothing on the target cluster.

**A7.4** Crossplane with **`deletionPolicy: Orphan`** (or `managementPolicies` lacking `Delete`) **leaves the external resource alive** when the MR is deleted — Crossplane just stops managing it (intentional for adoption/hand-off, a leak if unintended). For Kratix, deleting a Resource Request causes Kratix to **remove that request's documents from the State Store** and issue the corresponding delete `WorkPlacement`, so the GitOps agent **prunes the previously-scheduled resources** from the Destination — provided pruning is enabled on the reconciler; otherwise those documents can linger.

</details>