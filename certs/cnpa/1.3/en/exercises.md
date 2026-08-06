# CNPA — Topic 1.3: Application Environments and Infrastructure Architecture
## Guided Exercises

> **Prerequisites:** a disposable Kubernetes cluster (`kind create cluster --name cnpa-lab` is enough), `kubectl` ≥ 1.29, `kustomize` ≥ 5.x (or the version embedded in `kubectl`), `terraform` ≥ 1.7 or `tofu` (OpenTofu, drop-in equivalent syntax), and optionally the `argocd` CLI. Every exercise is destructive-safe: everything lives in namespaces you create and delete here.

---

## Exercise 1 — Environment boundaries inside one cluster: Namespaces, ResourceQuota, LimitRange, Pod Security

The cheapest environment boundary Kubernetes offers is the namespace. This exercise builds three environments for a `payments` service inside one cluster and demonstrates exactly which guarantees that boundary gives you — and which it does not.

**1.** Confirm which cluster you are about to modify. This habit prevents the classic "applied staging config to prod" incident:

```bash
kubectl config current-context
```

Expected output:

```
kind-cnpa-lab
```

**2.** Create the three environments as labeled namespaces. Note that the Pod Security Standard level is *stricter as you approach production* — dev tolerates `baseline`, prod enforces `restricted`:

```yaml
# environments.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments-dev
  labels:
    environment: dev
    team: payments
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments-staging
  labels:
    environment: staging
    team: payments
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments-prod
  labels:
    environment: prod
    team: payments
    pod-security.kubernetes.io/enforce: restricted
```

```bash
kubectl apply -f environments.yaml
kubectl get namespaces -l team=payments --show-labels
```

Expected output:

```
NAME               STATUS   AGE   LABELS
payments-dev       Active   5s    environment=dev,pod-security.kubernetes.io/enforce=baseline,team=payments,...
payments-prod      Active   5s    environment=prod,pod-security.kubernetes.io/enforce=restricted,team=payments,...
payments-staging   Active   5s    environment=staging,pod-security.kubernetes.io/enforce=restricted,team=payments,...
```

**3.** Cap what dev can consume so a runaway load test cannot starve the shared nodes:

```yaml
# quota-dev.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: env-quota
  namespace: payments-dev
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi
    pods: "20"
```

```bash
kubectl apply -f quota-dev.yaml
kubectl describe resourcequota env-quota -n payments-dev
```

Expected output:

```
Name:            env-quota
Namespace:       payments-dev
Resource         Used  Hard
--------         ----  ----
limits.cpu       0     4
limits.memory    0     8Gi
pods             0     20
requests.cpu     0     2
requests.memory  0     4Gi
```

**4.** Now trigger the first non-obvious interaction. Try to run a pod **without** resource requests in a namespace that has a compute quota:

```bash
kubectl run curl-test --image=curlimages/curl:8.8.0 -n payments-dev \
  --command -- sleep 3600
```

Expected output:

```
Error from server (Forbidden): pods "curl-test" is forbidden: failed quota: env-quota:
must specify limits.cpu for: curl-test; limits.memory for: curl-test;
requests.cpu for: curl-test; requests.memory for: curl-test
```

**5.** Fix it the platform way — not by editing every pod, but by injecting defaults with a `LimitRange`:

```yaml
# limitrange-dev.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: env-defaults
  namespace: payments-dev
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      default:
        cpu: 500m
        memory: 512Mi
```

```bash
kubectl apply -f limitrange-dev.yaml
kubectl run curl-test --image=curlimages/curl:8.8.0 -n payments-dev \
  --command -- sleep 3600
kubectl get pod curl-test -n payments-dev \
  -o jsonpath='{.spec.containers[0].resources}{"\n"}'
```

Expected output:

```
pod/curl-test created
{"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
```

**6.** Verify that the prod namespace really enforces a stricter security posture than dev. The same insecure pod that dev accepts, prod rejects:

```bash
kubectl run nginx-test --image=nginx:1.27 -n payments-prod
```

Expected output (abridged):

```
Error from server (Forbidden): pods "nginx-test" is forbidden: violates PodSecurity
"restricted:latest": allowPrivilegeEscalation != false (container "nginx-test" must set
securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (...),
runAsNonRoot != true (...), seccompProfile (...)
```

**7.** Clean up the test pod:

```bash
kubectl delete pod curl-test -n payments-dev
```

**Checkpoint questions**

- **Q1.1** — The quota rejection in step 4 happened *instantly*, before any scheduling decision. Which control-plane component enforced it, and at which phase of the request lifecycle?
- **Q1.2** — Why is the combination `ResourceQuota` + `LimitRange` a platform-engineering pattern rather than two unrelated features? What breaks if you deploy the quota without the LimitRange?
- **Q1.3** — Namespaces isolate names, quota, and (with the right labels) pod security. Name at least three things a namespace boundary does **not** isolate between dev and prod in this setup.

---

## Exercise 2 — Measuring the blast radius of a shared control plane

The decision "namespace-per-environment vs cluster-per-environment" is not aesthetic — it is a blast-radius calculation. This exercise makes the shared failure domain tangible using a CRD, the canonical example of cluster-scoped state.

**1.** List which API resources are *cluster-scoped* — i.e., shared by every environment living in this cluster, with no namespace boundary in between:

```bash
kubectl api-resources --namespaced=false | grep -Ei 'NAME|customresource|node|namespace|clusterrole|priorityclass|storageclass|webhook'
```

Expected output (abridged):

```
NAME                              SHORTNAMES   APIVERSION                        NAMESPACED   KIND
namespaces                        ns           v1                                false        Namespace
nodes                             no           v1                                false        Node
mutatingwebhookconfigurations                  admissionregistration.k8s.io/v1   false        MutatingWebhookConfiguration
validatingwebhookconfigurations                admissionregistration.k8s.io/v1   false        ValidatingWebhookConfiguration
customresourcedefinitions         crd,crds     apiextensions.k8s.io/v1           false        CustomResourceDefinition
clusterroles                                   rbac.authorization.k8s.io/v1      false        ClusterRole
priorityclasses                   pc           scheduling.k8s.io/v1              false        PriorityClass
storageclasses                    sc           storage.k8s.io/v1                 false        StorageClass
```

**2.** Install a CRD, as any operator (cert-manager, Prometheus Operator, Crossplane…) would:

```yaml
# widget-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.com
spec:
  group: example.com
  names:
    kind: Widget
    plural: widgets
    singular: widget
  scope: Namespaced
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
                size:
                  type: string
```

```bash
kubectl apply -f widget-crd.yaml
```

**3.** Create instances in *both* dev and prod — two "environments" using the same API:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: example.com/v1alpha1
kind: Widget
metadata:
  name: widget-a
  namespace: payments-dev
spec:
  size: small
---
apiVersion: example.com/v1alpha1
kind: Widget
metadata:
  name: widget-b
  namespace: payments-prod
spec:
  size: large
EOF
kubectl get widgets -A
```

Expected output:

```
NAMESPACE       NAME       AGE
payments-dev    widget-a   3s
payments-prod   widget-b   3s
```

**4.** Try to give dev "a newer version of the operator's schema" while prod stays on the old one. Check the CRD's identity first:

```bash
kubectl get crd widgets.example.com -o jsonpath='{.spec.versions[*].name}{"\n"}'
```

Expected output:

```
v1alpha1
```

There is exactly **one** object named `widgets.example.com` in the whole cluster. Any change to its schema, served versions or conversion webhook takes effect for every namespace *at the same instant*. There is no per-namespace CRD version.

**5.** Now measure the worst case. Simulate a botched operator uninstall in "dev" — someone deletes the CRD:

```bash
kubectl delete crd widgets.example.com
kubectl get widgets -A
```

Expected output:

```
customresourcedefinition.apiextensions.k8s.io "widgets.example.com" deleted
error: the server doesn't have a resource type "widgets"
```

Both `widget-a` (dev) **and** `widget-b` (prod) were garbage-collected the moment the CRD disappeared. A "dev-only" action deleted production data, because the boundary between them was namespaced but the resource type was not.

**Checkpoint questions**

- **Q2.1** — Besides CRDs, list four other shared failure domains that a namespace-per-environment design cannot isolate (think: things one bad "staging" change can break for prod in the same cluster).
- **Q2.2** — Which environment architecture eliminates the failure you just reproduced, and what are its two main costs?
- **Q2.3** — A common compromise is "shared cluster for dev/staging, dedicated cluster for prod". Which properties of prod justify paying for the dedicated cluster there and not in staging?

---

## Exercise 3 — One base, many environments: Kustomize overlays and promotion by diff

Environments must differ in *parameters* (replicas, resources, image tag) but never in *structure*, or they stop predicting each other. Kustomize encodes that rule in the filesystem: one `base/`, one small overlay per environment.

**1.** Build this tree:

```bash
mkdir -p app/base app/overlays/dev app/overlays/prod
```

```
app/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        ├── kustomization.yaml
        ├── patch-resources.yaml
        └── pdb.yaml
```

**2.** The base — environment-agnostic on purpose (no namespace, no env-specific replicas):

```yaml
# app/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  labels:
    app.kubernetes.io/name: checkout
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
    spec:
      containers:
        - name: checkout
          image: ghcr.io/example/checkout:1.4.0
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
```

```yaml
# app/base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout
spec:
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - port: 80
      targetPort: 8080
```

```yaml
# app/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

**3.** The dev overlay — a release candidate runs here first:

```yaml
# app/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: payments-dev
resources:
  - ../../base
labels:
  - pairs:
      environment: dev
images:
  - name: ghcr.io/example/checkout
    newTag: 1.5.0-rc.1
```

**4.** The prod overlay — same structure, hardened parameters, plus a resource that only makes sense in prod (a `PodDisruptionBudget` is meaningless with 1 replica):

```yaml
# app/overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: payments-prod
resources:
  - ../../base
  - pdb.yaml
labels:
  - pairs:
      environment: prod
images:
  - name: ghcr.io/example/checkout
    newTag: 1.4.0
patches:
  - path: patch-resources.yaml
    target:
      kind: Deployment
      name: checkout
```

```yaml
# app/overlays/prod/patch-resources.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: checkout
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
```

```yaml
# app/overlays/prod/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
```

**5.** Render both environments *without applying* and compare what actually differs:

```bash
kubectl kustomize app/overlays/dev  | grep -E 'image:|replicas:'
kubectl kustomize app/overlays/prod | grep -E 'image:|replicas:'
```

Expected output:

```
        image: ghcr.io/example/checkout:1.5.0-rc.1
  replicas: 1
        image: ghcr.io/example/checkout:1.4.0
  replicas: 3
```

**6.** Deploy dev (the image is fictional, so pods will show `ImagePullBackOff` — that is fine; the object model is what we are studying):

```bash
kubectl apply -k app/overlays/dev
kubectl get deploy,svc -n payments-dev -l environment=dev
```

Expected output:

```
deployment.apps/checkout created
service/checkout created
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/checkout   0/1     1            0           5s

NAME               TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/checkout   ClusterIP   10.96.144.21   <none>        80/TCP    5s
```

**7.** Promote `1.5.0-rc.1` to prod *as data, not as a copy-paste*. `kustomize edit` rewrites only the overlay file, which makes promotion a one-line git diff:

```bash
cd app/overlays/prod
kustomize edit set image ghcr.io/example/checkout=ghcr.io/example/checkout:1.5.0-rc.1
git diff -- kustomization.yaml
```

Expected output:

```diff
 images:
   - name: ghcr.io/example/checkout
-    newTag: 1.4.0
+    newTag: 1.5.0-rc.1
```

**8.** Before applying to prod, always inspect the server-side diff:

```bash
cd ../../..
kubectl diff -k app/overlays/prod | head -20
```

`kubectl diff` exits with code `1` when there are pending changes — in CI you use that exit code as a gate, in a terminal you read the diff.

**Checkpoint questions**

- **Q3.1** — Why must the base contain *no* namespace and *no* environment-specific values? Describe the failure mode of the alternative (three full copies of the YAML, one per environment).
- **Q3.2** — In this model, what *exactly* is a "promotion" in terms of artifacts? What is never rebuilt during a promotion, and why is that the whole point?
- **Q3.3** — Helm solves the same problem with `values-<env>.yaml` files and templates. Name one advantage of the Kustomize approach and one of the Helm approach for environment management.

---

## Exercise 4 — GitOps-driven environments with Argo CD: sync policies as promotion gates

With overlays in Git, the missing piece is an agent that makes the cluster converge to Git — and whose *sync policy per environment* becomes your promotion gate: dev auto-deploys, prod waits for a human.

> If you don't have a Git repo handy, push the `app/` tree from Exercise 3 to any repository you control and substitute its URL below. The manifests are exactly what you would use in production.

**1.** Install Argo CD:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=180s
```

**2.** Declare the dev environment with **automated sync and self-heal** — Git is the only writer:

```yaml
# app-dev.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: checkout-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOURUSER/checkout-deploy.git
    targetRevision: main
    path: app/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: payments-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**3.** Declare prod identically **except** the sync policy — no `automated` block. Every change to prod requires an explicit, audited sync:

```yaml
# app-prod.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: checkout-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOURUSER/checkout-deploy.git
    targetRevision: main
    path: app/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: payments-prod
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f app-dev.yaml -f app-prod.yaml
kubectl get applications -n argocd
```

Expected output (after the promotion commit from Exercise 3 step 7 lands in `main`):

```
NAME            SYNC STATUS   HEALTH STATUS
checkout-dev    Synced        Healthy
checkout-prod   OutOfSync     Healthy
```

Read that table carefully: dev already converged on its own; prod *knows* it is behind Git (`OutOfSync`) and is deliberately waiting.

**4.** Execute the prod promotion — the human gate:

```bash
argocd app sync checkout-prod
```

**5.** Prove that `selfHeal` makes manual changes to dev impossible to sustain. Scale the deployment by hand and watch Argo CD revert it:

```bash
kubectl scale deployment checkout -n payments-dev --replicas=5
kubectl get deployment checkout -n payments-dev -w
```

Expected output (within a few seconds):

```
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
checkout   0/5     1            0           12m
checkout   0/1     1            0           12m
```

The replica count snapped back to the value in Git. `kubectl edit` is no longer a deployment mechanism in this environment — it is drift, and drift gets erased.

**Checkpoint questions**

- **Q4.1** — Both environments deploy from the same `main` branch and the same repo, yet they can run different versions. Where does the version difference live, and why is that better than one branch per environment?
- **Q4.2** — What operational capabilities do you get "for free" from the fact that every prod change is a Git commit? Name at least three.
- **Q4.3** — GitOps agents *pull* desired state and reconcile continuously; a CI job running `kubectl apply` *pushes* once. Give two concrete failure scenarios where the pull model behaves better.

---

## Exercise 5 — Ephemeral preview environments with the ApplicationSet Pull Request generator

Static environments (dev/staging/prod) are complemented by *ephemeral* ones: an isolated environment per pull request, created when the PR opens and destroyed when it merges. Argo CD's `ApplicationSet` turns that lifecycle into a declarative rule.

**1.** Study, then validate, the manifest. The `pullRequest` generator polls GitHub and emits one parameter set per open PR labeled `preview`; the template stamps out one `Application` (and thus one namespace) per PR:

```yaml
# appset-previews.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: checkout-previews
  namespace: argocd
spec:
  generators:
    - pullRequest:
        github:
          owner: YOURUSER
          repo: checkout
          labels:
            - preview
        requeueAfterSeconds: 120
  template:
    metadata:
      name: 'checkout-pr-{{number}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/YOURUSER/checkout-deploy.git
        targetRevision: main
        path: app/overlays/dev
        kustomize:
          namespace: 'preview-pr-{{number}}'
          images:
            - 'ghcr.io/example/checkout:pr-{{number}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'preview-pr-{{number}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**2.** Server-side dry-run validates it against the real CRD schema without needing GitHub credentials:

```bash
kubectl apply -f appset-previews.yaml --dry-run=server
```

Expected output:

```
applicationset.argoproj.io/checkout-previews created (server dry run)
```

**3.** Trace the lifecycle on paper (this is what the exam tests):

1. Developer opens PR `#42` and CI pushes image `ghcr.io/example/checkout:pr-42`.
2. Within `requeueAfterSeconds`, the generator emits `{number: 42}` → an `Application` named `checkout-pr-42` appears → namespace `preview-pr-42` is created and synced.
3. The PR merges. The generator's next poll returns no PR `#42` → the `Application` is deleted → with `prune: true` and cascade deletion, its workloads are removed.

**4.** Identify the cleanup gotcha before it bites you: namespaces created via `CreateNamespace=true` are **not** deleted when the `Application` is cascade-deleted — Argo CD never managed the `Namespace` object itself. Verify what a leaked preview namespace costs by simulating one and cleaning it by label:

```bash
kubectl create namespace preview-pr-42
kubectl label namespace preview-pr-42 preview=true
kubectl delete namespaces -l preview=true
```

Expected output:

```
namespace "preview-pr-42" deleted
```

In production you close this gap with `managedNamespaceMetadata` plus a namespace-level cleanup controller, or by having the template include the `Namespace` object as a managed resource.

**Checkpoint questions**

- **Q5.1** — Why do preview environments reuse `app/overlays/dev` as their configuration base instead of having their own overlay directory per PR?
- **Q5.2** — Preview environments multiply resource consumption by the number of open PRs. Which two mechanisms from Exercise 1 keep that multiplication from taking down the shared cluster?
- **Q5.3** — What does `requeueAfterSeconds: 120` trade off? What is the event-driven alternative?

---

## Exercise 6 — Infrastructure as Code: state, drift and reconciliation with Terraform/OpenTofu

Everything so far configured workloads *inside* a cluster. The environments themselves — clusters, networks, registries, the namespaces-with-quota pattern — are infrastructure, and IaC is how you stamp identical environments from one definition. Here you use Terraform's Kubernetes provider so the loop is observable without a cloud account; the mechanics (plan → apply → state → drift) are identical for VPCs or managed clusters. Every command below works verbatim with `tofu` instead of `terraform`.

**1.** Create a working directory with this definition. Note how environment differences are *data* (a variable and a conditional), never copied code:

```hcl
# main.tf
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

variable "environment" {
  type = string
}

resource "kubernetes_namespace" "env" {
  metadata {
    name = "iac-${var.environment}"
    labels = {
      environment = var.environment
      managed-by  = "terraform"
    }
  }
}

resource "kubernetes_resource_quota" "env" {
  metadata {
    name      = "env-quota"
    namespace = kubernetes_namespace.env.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = var.environment == "prod" ? "8" : "2"
      "requests.memory" = var.environment == "prod" ? "16Gi" : "4Gi"
    }
  }
}
```

**2.** Initialize and preview. `plan` computes the diff between desired state (code), recorded state (state file) and real state (the API):

```bash
terraform init
terraform plan -var environment=dev
```

Expected output (final line):

```
Plan: 2 to add, 0 to change, 0 to destroy.
```

**3.** Apply, and inspect what Terraform now *remembers*:

```bash
terraform apply -var environment=dev -auto-approve
terraform state list
```

Expected output:

```
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
kubernetes_namespace.env
kubernetes_resource_quota.env
```

**4.** Prove idempotency — the property your platform's CI depends on. A second apply must be a no-op:

```bash
terraform apply -var environment=dev -auto-approve
```

Expected output:

```
No changes. Your infrastructure matches the configuration.
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
```

**5.** Cause drift the way it happens in real life — someone "fixes" something by hand:

```bash
kubectl delete resourcequota env-quota -n iac-dev
terraform plan -var environment=dev
```

Expected output (abridged):

```
Note: Objects have changed outside of Terraform
...
  # kubernetes_resource_quota.env will be created
...
Plan: 1 to add, 0 to change, 0 to destroy.
```

Terraform *detected* the drift at plan time — but only because you ran a plan. Nothing repaired it autonomously. Run `terraform apply -var environment=dev -auto-approve` to reconcile.

**6.** Stamp a second environment from the *same* code using workspaces — separate state files, one definition:

```bash
terraform workspace new staging
terraform apply -var environment=staging -auto-approve
kubectl get resourcequota env-quota -n iac-dev -n iac-staging -o jsonpath='{.spec.hard.requests\.cpu}{"\n"}'
kubectl get namespaces -l managed-by=terraform
```

Expected output:

```
NAME          STATUS   AGE
iac-dev       Active   6m
iac-staging   Active   10s
```

**7.** Clean up both workspaces:

```bash
terraform destroy -var environment=staging -auto-approve
terraform workspace select default
terraform destroy -var environment=dev -auto-approve
```

**Checkpoint questions**

- **Q6.1** — What three inputs does `terraform plan` reconcile, and what specific role does the state file play that the live API cannot fulfill by itself?
- **Q6.2** — Contrast the drift behavior in step 5 with Argo CD's `selfHeal` in Exercise 4. Classify each as push- or pull-based reconciliation and state one consequence of the difference for production operations.
- **Q6.3** — Why is "one module, N variable sets" strictly better than "N copies of the code" for environment parity? Connect your answer to the incident class known as *snowflake environments*.

---

## Exercise 7 — Capstone: choosing an environment architecture (analysis)

No commands here — this is the judgment the exam (and the job) tests. For each scenario, choose an environment architecture and justify it against these criteria: **blast radius, upgrade independence, compliance isolation, cost, operational overhead, developer self-service**.

The candidate architectures:

- **A. Namespace-per-environment** in one shared cluster (Exercise 1 pattern).
- **B. Cluster-per-environment** (dedicated clusters for dev, staging, prod).
- **C. Hybrid**: shared non-prod cluster with namespace/ephemeral environments + dedicated prod cluster.
- **D. Fleet**: many clusters stamped from IaC + GitOps (Cluster API / Terraform modules), environments spread across them.

**Scenario 1** — A 15-person startup runs one SaaS product. Cloud budget is tight; there is no dedicated platform team; releases go out daily.

**Scenario 2** — A regulated fintech must demonstrate to auditors that cardholder-data workloads (PCI DSS scope) are isolated from everything else, that prod changes are individually approved and attributable, and that a staging experiment can never touch prod data paths.

**Scenario 3** — A platform team serves 30 product squads. Squads want a preview environment per pull request, self-service namespaces with guardrails, and the platform team must upgrade Kubernetes versions without a company-wide freeze.

**Checkpoint questions**

- **Q7.1** — Pick an architecture for each scenario and give the two criteria that most drove each choice.
- **Q7.2** — For Scenario 3: which exercises in this document correspond to the concrete building blocks of your chosen architecture? Map at least four.
- **Q7.3** — Whatever architecture you chose, one rule from this topic applies universally: environment differences must be expressed as ____, never as ____. Fill in the blanks and justify with one incident scenario.

---

## Answers

<details>
<summary><strong>Click to reveal all answers</strong></summary>

### Exercise 1

**A1.1** — The `kube-apiserver`, during **admission**, via the built-in `ResourceQuota` admission plugin (a validating admission step). The pod object was rejected before being persisted to etcd, so the scheduler never saw it. This is why quota violations fail fast and atomically, while *node* capacity exhaustion manifests later and differently — as pods stuck in `Pending` at scheduling time.

**A1.2** — The quota creates an obligation ("every pod must declare requests/limits or I cannot account for it"), and the LimitRange discharges that obligation automatically by mutating pods that don't declare them. Without the LimitRange, every workload whose author forgot resource declarations is rejected — in practice this breaks third-party charts and one-off debug pods (`kubectl run`), generating a stream of support tickets. Together they form a policy: "everything is accounted for, and there is a sane default." That composition — enforce + auto-remediate — is the general shape of platform guardrails.

**A1.3** — Any three of:
1. **Nodes / kernel**: dev and prod pods can share the same node, kernel, and container runtime; a kernel panic or noisy neighbor at the node level crosses environments (quota bounds totals, not placement — that needs taints/affinity).
2. **Control plane**: one `kube-apiserver`, one etcd, one scheduler. A dev-induced API storm (crashlooping controller hammering the API) degrades prod's API too.
3. **Cluster-scoped resources**: CRDs, webhooks, ClusterRoles, StorageClasses, PriorityClasses (Exercise 2 demonstrates this).
4. **Cluster version**: you cannot upgrade "only staging's" Kubernetes.
5. **Network by default**: without `NetworkPolicy`, any dev pod can reach any prod pod's ClusterIP.

### Exercise 2

**A2.1** — Any four of: (1) **admission webhooks** — a broken `ValidatingWebhookConfiguration` installed for a staging tool with `failurePolicy: Fail` can block *all* pod creation cluster-wide, including prod; (2) **the cluster version/upgrade** — control plane and node upgrades hit every environment simultaneously; (3) **the control plane itself** — API server/etcd overload or corruption from any tenant affects all; (4) **cluster-wide RBAC** — a mangled `ClusterRole`/`ClusterRoleBinding` changes authorization everywhere; (5) **CNI / cluster networking config** — one bad rollout of the network plugin takes down all pod networking; (6) **StorageClasses/PriorityClasses** — deleting or repointing one changes behavior for every namespace that references it.

**A2.2** — **Cluster-per-environment** (architecture B): each environment gets its own API server, etcd, CRD set, webhook set, and upgrade schedule, so the CRD deletion in step 5 could not have touched prod. Its two main costs: **money** (duplicated control planes, duplicated system add-ons, worse bin-packing because idle capacity can't be shared across environments) and **operational overhead** (N clusters to upgrade, monitor, certificate-rotate, and keep *configured identically* — which itself demands the IaC + GitOps machinery of Exercises 4 and 6, or the clusters drift apart and staging stops predicting prod).

**A2.3** — Prod uniquely combines: real user traffic and revenue impact (blast radius is measured in SLA money, not developer inconvenience), real data (compliance and breach exposure), and the need for **upgrade independence** (you want to rehearse a Kubernetes upgrade in staging *before* prod — impossible if they share a control plane). Staging outages, in contrast, cost developer time only, and staging actually *benefits* from sharing a cluster with dev: higher utilization and one less cluster to maintain. This asymmetry is why architecture C (shared non-prod + dedicated prod) is the most common production pattern.

### Exercise 3

**A3.1** — Because the base is instantiated N times, once per environment, and anything environment-specific in it would either be wrong for N−1 of them or need overriding everywhere (defeating the point). The copy-paste alternative fails by **structural drift**: an engineer adds a `readinessProbe` fix to the prod copy and forgets the staging copy; three months later staging passes and prod fails (or vice versa) for reasons no diff of "the app" reveals, because the environments no longer test the same object. Overlays make drift impossible to hide: the overlay file *is* the complete, reviewable list of ways prod differs from base.

**A3.2** — A promotion is a **one-line change to a text field** (`newTag`) in the target environment's overlay, delivered as a Git commit. What is never rebuilt is the **container image**: the digest that passed tests in dev is byte-for-byte the artifact that reaches prod. That is the point — "build once, promote the same artifact through environments." If each environment rebuilt from source, a different base-image pull or dependency resolution could make prod run code that was never tested.

**A3.3** — **Kustomize advantage**: everything is plain, rendered-inspectable YAML — no template language, `kubectl kustomize` output is exactly what will be applied, and reviewing an overlay requires no knowledge of chart internals. **Helm advantage**: parameterization and distribution — a chart packages logic (conditionals, loops, defaults with schema validation) and versions it for consumption by others, which fits software you *ship to* many operators, whereas overlays fit environments *you* operate. Many platforms combine them: third-party components via Helm, environment config via Kustomize on top.

### Exercise 4

**A4.1** — The version difference lives in the **overlay directories** (`overlays/dev/kustomization.yaml` vs `overlays/prod/kustomization.yaml`) — i.e., in *paths*, not branches. Branch-per-environment forces promotions to be merges, and merges do exactly the wrong thing: they carry *every* difference between branches, not just the intended one, so an unrelated hotfix that landed in the staging branch rides along into the prod merge invisibly. With path-per-environment, a promotion is a surgical diff to one file, `main` stays the single source of truth, and the complete state of all environments is visible in one checkout.

**A4.2** — Any three of: (1) **audit trail** — `git log` on the prod overlay is a complete, tamper-evident record of what changed, when, by whom, and who approved (the PR); (2) **rollback** — `git revert` + sync restores the exact previous state, no tribal knowledge required; (3) **peer review as a deployment gate** — branch protection makes "two approvals to touch prod" a mechanical guarantee; (4) **disaster recovery** — the repo *is* the environment definition; pointing Argo CD at a fresh cluster reproduces it; (5) **least-privilege CI** — CI never holds prod cluster credentials, because it only pushes commits; the in-cluster agent pulls.

**A4.3** — Two strong ones: (1) **drift repair** — if someone `kubectl edit`s prod at 3 a.m., the pull agent detects and (with `selfHeal`) reverts it continuously; a push pipeline is blind between runs, so the hand-edit survives until the next deploy, when it either persists unnoticed or causes a surprise diff. (2) **transient failure recovery** — if the cluster or a webhook is briefly unavailable during a push, the CI job fails and the deployment is simply *lost* until a human re-runs it; a reconciling agent retries until convergence. (Also acceptable: cluster recreation converging automatically; no long-lived cluster credentials stored in the CI system.)

### Exercise 5

**A5.1** — Because a preview environment's job is to test *the code change* against a known configuration, so everything except the image (and the namespace) must be held constant — and `dev` is the closest-to-real config that is safe to multiply. The ApplicationSet template overrides exactly those two parameters (`kustomize.images`, `namespace`) per PR. A per-PR overlay directory would mean generating and committing config per PR: churn in Git, config drift between previews, and cleanup that depends on remembering to delete files rather than on the generator's lifecycle.

**A5.2** — **ResourceQuota** (cap each preview namespace's total consumption, so 30 open PRs cost a bounded, predictable amount) and **LimitRange** (inject defaults so every preview pod is accounted against that quota without requiring authors to set resources). Combined with a `pods:` count cap, they convert "unbounded number of environments" into "bounded resource envelope per environment × number of PRs", which capacity planning can handle.

**A5.3** — It trades **latency for simplicity and API-rate friendliness**: previews appear/disappear up to 120 s after the PR event, but the setup needs no inbound connectivity and polls GitHub gently (a low value burns API rate limits; a high value makes previews sluggish). The event-driven alternative is a **webhook**: configuring the SCM to notify the ApplicationSet controller on PR events, which gives near-instant reaction but requires an exposed, authenticated endpoint reachable from the SCM.

### Exercise 6

**A6.1** — (1) The **configuration** (desired state, `.tf` files), (2) the **state file** (what Terraform believes it manages and created), (3) the **real infrastructure** (refreshed from the provider API). The state file's irreplaceable role is **ownership mapping**: it binds resource *addresses* in code (`kubernetes_namespace.env`) to specific real-world object identities. The live API can tell you what exists, but not *which* of those objects this configuration is responsible for — without state, Terraform couldn't distinguish "namespace I created and should update/delete" from "namespace someone else owns", couldn't detect deletions (nothing to compare against), and couldn't safely destroy.

**A6.2** — Terraform is **push-based, point-in-time** reconciliation: drift is detected only when someone runs `plan`, and corrected only when someone runs `apply`; between runs, drift persists silently. Argo CD with `selfHeal` is **pull-based, continuous**: an in-cluster controller compares desired vs live in a loop and repairs divergence within seconds, unattended. Operational consequence: with Terraform-managed infrastructure you must *schedule* drift detection (periodic plans in CI, alerting on non-empty diffs) or accept an unbounded drift window; with GitOps-managed resources, manual hotfixes are impossible to sustain, which is a feature (prod always matches Git) but demands that emergency changes also go through Git. Mature platforms use both: Terraform/OpenTofu for the substrate (clusters, networks), GitOps for everything running on it.

**A6.3** — With one module, every environment is *provably* the same code, and differences are enumerable by reading the variable sets — dev vs prod differ in exactly `requests.cpu`/`requests.memory`, nothing else, and a reviewer can verify that in seconds. With N copies, every fix must be applied N times, each copy accumulates its own history of forgotten patches and hand-edits, and environments become **snowflakes**: unique, unreproducible configurations where "works in staging" carries no information about prod. The incident class: a fix validated in staging fails in prod because prod's copy had a divergence nobody knew about — the outage post-mortem action item is invariably "converge environment definitions", i.e., what the single module gave you from day one.

### Exercise 7

**A7.1** —
- **Scenario 1 → A** (namespace-per-environment, possibly graduating to C later). Driving criteria: **cost** (one control plane, shared node capacity) and **operational overhead** (no platform team to run a fleet). The blast-radius risk of a shared cluster is real but acceptable when the whole company is 15 people iterating daily; mitigations from Exercise 1 (quota, Pod Security, NetworkPolicy) are cheap.
- **Scenario 2 → B** (cluster-per-environment; often further, separate cloud accounts/VPCs per environment). Driving criteria: **compliance isolation** (auditors accept "separate cluster, separate account, separate credentials" far more readily than "separate namespace") and **blast radius** (Exercise 2 showed a staging action deleting prod data across namespaces — that class of finding fails a PCI audit). Manual sync gates as in Exercise 4 provide the individually-approved, attributable prod changes.
- **Scenario 3 → C or D** (shared, quota-guarded non-prod cluster(s) with ephemeral namespaces per PR + dedicated prod; at 30 squads, likely D — a fleet stamped by IaC so clusters can be upgraded canary-style). Driving criteria: **developer self-service** (namespace-as-a-service + ApplicationSet previews) and **upgrade independence** (with a fleet, the platform team drains and upgrades clusters one at a time — no company-wide freeze).

**A7.2** — For Scenario 3: **Exercise 1** → the guardrails of namespace-as-a-service (quota, LimitRange, Pod Security labels applied to every self-service namespace); **Exercise 3** → the one-base-many-overlays structure each squad uses so their environments can't structurally drift; **Exercise 4** → Argo CD sync policies as the promotion gates (auto in non-prod, manual+reviewed to prod); **Exercise 5** → the ApplicationSet Pull Request generator implementing preview-environment-per-PR with automatic teardown; **Exercise 6** → the IaC module that stamps identical clusters for the fleet, making "upgrade one cluster at a time" possible because every cluster is reproducible from code.

**A7.3** — Environment differences must be expressed as **data** (parameters: overlay fields, variable values, values files — small, reviewable, diffable), never as **duplicated structure/code** (copied manifests, per-environment branches, hand-edited live objects). Incident scenario: a team keeps a full copy of the prod manifests "temporarily" to add one annotation; six months of fixes land only on the staging copy; a certificate-handling change tested green in staging takes prod down because prod's copy still mounted the old secret path — and no diff in the release under review could have shown it, because the divergence lived in the copy, not the change.

</details>

---

## Sources

- CNCF Platforms Whitepaper — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- Kubernetes Namespaces — https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Resource Quotas — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Limit Ranges — https://kubernetes.io/docs/concepts/policy/limit-range/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Multi-tenancy — https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Custom Resources / CRDs — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kustomize reference — https://kubectl.docs.kubernetes.io/references/kustomize/
- Helm values best practices — https://helm.sh/docs/chart_best_practices/values/
- Argo CD documentation — https://argo-cd.readthedocs.io/en/stable/
- ApplicationSet Pull Request generator — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/
- Terraform state — https://developer.hashicorp.com/terraform/language/state
- OpenTofu documentation — https://opentofu.org/docs/
- CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf