# 1.3 — Application Environments and Infrastructure Architecture

## 1. Motivation: the production problem this topic solves

Every non-trivial platform must answer one question before it ships a single feature: **where does code run before it is allowed to touch real users, and what guarantees does each of those places provide?**

An *application environment* is a bounded, named context — `dev`, `staging`, `prod`, `pr-1423` — with its own configuration, data, credentials, capacity, and blast radius. The *infrastructure architecture* is the physical and logical substrate those environments are carved from: clusters, namespaces, virtual clusters, cloud accounts, regions, and failure domains.

The production failure modes that appear when this is done badly are well known to every SRE:

- **Environment drift**: staging runs Kubernetes 1.29 with 2 vCPU nodes while prod runs 1.31 with dedicated node pools, so a `PodDisruptionBudget` or a CSI behavior change is first observed during a production incident. This violates the *dev/prod parity* principle formalized in the Twelve-Factor App (factor X).
- **Snowflake environments**: environments created imperatively (`kubectl create ns`, console clicks) cannot be reproduced. When the platform team needs a fourth environment for a compliance audit, nobody can enumerate what "an environment" actually contains.
- **Shared blast radius**: a load test in `dev` exhausts cluster-wide IP addresses or `etcd` storage and takes down `prod` workloads co-located on the same cluster, because isolation was assumed at the namespace level but never enforced with quotas, `NetworkPolicy`, and priority classes.
- **Configuration leakage**: a prod database DSN committed into a shared values file gets mounted in a preview environment reachable by every engineer.
- **Cost inversion**: hard isolation everywhere (one cluster per environment per team) is safe but multiplies control-plane cost, upgrade toil, and fleet sprawl until the platform team spends all of its time patching clusters instead of building the platform.

Platform engineering's answer — reflected in the CNCF Platforms Whitepaper and the CNPA curriculum — is to treat environments as **products of the platform**: declaratively defined, self-service, reproducible from Git, and mapped deliberately onto an isolation model whose trade-offs were chosen, not inherited.

The architecture decisions in this topic sit on three axes:

1. **Isolation model** — what boundary separates environments (namespace, virtual cluster, cluster, cloud account)?
2. **Configuration model** — how does the *same* application definition vary per environment without forking (Kustomize overlays, Helm values, GitOps repo layout)?
3. **Lifecycle model** — which environments are long-lived (prod, staging) and which are ephemeral (preview per pull request), and who or what creates and destroys them?

---

## 2. Isolation models: mapping environments onto infrastructure

### 2.1 The four canonical models

**Namespace-per-environment (soft multi-tenancy).** All environments share one cluster and one control plane; a Kubernetes `Namespace` plus `ResourceQuota`, `LimitRange`, `NetworkPolicy`, and RBAC form the boundary. Cheapest and fastest to provision, but the kernel, kubelet, CNI, cluster-scoped CRDs, and the API server itself are shared. A noisy or hostile tenant can affect everyone; a CRD version upgrade affects every environment at once.

**Virtual cluster per environment (vCluster and similar).** Each environment gets its own virtualized control plane (API server + datastore) running as pods inside a host namespace, while workloads are synced to the host cluster's nodes. Tenants can install their own CRDs and even run different Kubernetes API versions, without paying for real control planes. Node kernel and CNI remain shared.

**Cluster-per-environment (hard isolation).** Each environment is a full Kubernetes cluster, typically managed declaratively with Cluster API or a managed offering (EKS/GKE/AKS). Failure domains, upgrade cadence, and cluster-scoped resources are fully independent. Cost and fleet-management toil scale linearly with the number of environments.

**Cloud account / subscription-per-environment.** The boundary moves above Kubernetes: separate AWS accounts, GCP projects, or Azure subscriptions per environment, each containing its own clusters, IAM, billing, and quota. This is the strongest boundary — it isolates cloud API rate limits, IAM privilege escalation paths, and spend — and it is the standard pattern for regulated production estates (often combined with an organization-level landing zone).

### 2.2 Trade-off matrix

| Dimension | Namespace | Virtual cluster | Cluster per env | Account per env |
|---|---|---|---|---|
| Control-plane isolation | None (shared API server, etcd) | Full (own API server) | Full | Full |
| Node/kernel isolation | None | None (shared nodes)¹ | Full | Full |
| Cluster-scoped resources (CRDs, webhooks, `ClusterRole`) | Shared — main conflict source | Per-vcluster | Per-cluster | Per-cluster |
| Kubernetes version skew between envs | Impossible | Possible (per vcluster) | Possible | Possible |
| Blast radius of a control-plane outage | All environments | One environment | One environment | One environment |
| Provisioning time | Seconds | ~1 minute | 5–20 minutes | Minutes–hours (org policy) |
| Marginal cost per environment | ≈ 0 (quota only) | Low (one pod + PVC) | High (control plane + system nodes) | High + org overhead |
| Upgrade toil | One cluster to upgrade | Host + N vclusters | N clusters (fleet tooling required) | N clusters + N accounts |
| Fits ephemeral/preview envs | Good | Excellent | Poor (too slow/expensive) | Unusable |
| Fits regulated prod | Weak | Weak–moderate | Strong | Strongest |
| Security boundary class | Policy-based (bypassable by cluster-admin, kernel exploits) | Control-plane only | Hardware/VM boundary | Cloud IAM + billing boundary |

¹ vCluster can be combined with dedicated node pools and taints for partial node isolation.

**Production guidance (the pattern you should defend in an exam scenario):** hard boundary between *prod* and *everything else* (separate cluster, ideally separate account); soft or virtual boundaries between pre-production environments; ephemeral namespaces or vclusters for preview environments. Isolation strength should follow data sensitivity and blast-radius cost, not organizational habit.

### 2.3 Failure domains inside an environment

Isolation between environments is only half the architecture; production environments must also be architected *across* failure domains:

- **Zonal spread**: worker nodes across ≥3 availability zones, with `topologySpreadConstraints` so a zone loss degrades capacity by ~1/3 instead of 100%.
- **Control plane**: managed control planes are multi-AZ by default; self-managed (kubeadm/Cluster API) need 3 or 5 control-plane machines across zones for etcd quorum.
- **Regional strategy**: a second region is an *environment-set* decision (active/active vs active/passive), not a per-application one — it multiplies every environment you promote through.

```yaml
# Zonal spread for a production workload — include in the prod overlay only.
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app.kubernetes.io/name: checkout
```

---

## 3. The configuration model: one definition, many environments

The cardinal rule: **environments differ by data, not by code**. The application's manifests are written once; per-environment variance (replicas, resources, hostnames, feature flags, secret references) is layered on top. Two dominant mechanisms exist.

### 3.1 Kustomize: base + overlays (complete, runnable example)

Repository layout:

```
apps/checkout/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── patch-resources.yaml
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patch-resources.yaml
    └── prod/
        ├── kustomization.yaml
        ├── patch-resources.yaml
        ├── pdb.yaml
        └── hpa.yaml
```

`base/deployment.yaml`:

```yaml
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
        image: registry.example.com/shop/checkout:1.8.3
        ports:
        - name: http
          containerPort: 8080
        env:
        - name: LOG_LEVEL
          value: info
        readinessProbe:
          httpGet:
            path: /healthz/ready
            port: http
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /healthz/live
            port: http
          initialDelaySeconds: 15
          periodSeconds: 20
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            memory: 256Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 10001
          capabilities:
            drop: ["ALL"]
```

`base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout
  labels:
    app.kubernetes.io/name: checkout
spec:
  selector:
    app.kubernetes.io/name: checkout
  ports:
  - name: http
    port: 80
    targetPort: http
```

`base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
labels:
- includeSelectors: true
  pairs:
    app.kubernetes.io/part-of: shop
```

`overlays/dev/kustomization.yaml` — small footprint, verbose logging:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shop-dev
resources:
- ../../base
patches:
- path: patch-resources.yaml
images:
- name: registry.example.com/shop/checkout
  newTag: 1.9.0-rc.2
```

`overlays/dev/patch-resources.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: checkout
        env:
        - name: LOG_LEVEL
          value: debug
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 128Mi
```

`overlays/prod/kustomization.yaml` — pinned tag, HA resources:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shop-prod
resources:
- ../../base
- pdb.yaml
- hpa.yaml
patches:
- path: patch-resources.yaml
images:
- name: registry.example.com/shop/checkout
  newTag: 1.8.3
```

`overlays/prod/patch-resources.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 3
  template:
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: checkout
      containers:
      - name: checkout
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            memory: 1Gi
```

`overlays/prod/pdb.yaml`:

```yaml
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

`overlays/prod/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  minReplicas: 3
  maxReplicas: 12
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

Render and inspect an overlay without applying it:

```
$ kubectl kustomize apps/checkout/overlays/prod | grep -E 'kind:|replicas:|image:|namespace:'
kind: Service
  namespace: shop-prod
kind: Deployment
  namespace: shop-prod
  replicas: 3
        image: registry.example.com/shop/checkout:1.8.3
kind: HorizontalPodAutoscaler
  namespace: shop-prod
kind: PodDisruptionBudget
  namespace: shop-prod
```

### 3.2 Helm: values-per-environment

The same variance expressed as one chart plus `values-<env>.yaml` files:

```yaml
# values-prod.yaml
replicaCount: 3
image:
  tag: "1.8.3"
resources:
  requests: {cpu: 500m, memory: 512Mi}
  limits: {memory: 1Gi}
pdb:
  enabled: true
  minAvailable: 2
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 12
```

```
$ helm upgrade --install checkout ./chart -n shop-prod -f values-prod.yaml --dry-run=server | head -n 6
Release "checkout" has been upgraded. Happy Helming!
NAME: checkout
LAST DEPLOYED: Wed Aug  6 10:42:17 2026
NAMESPACE: shop-prod
STATUS: pending-upgrade
REVISION: 12
```

### 3.3 Kustomize vs Helm for environment variance

| Criterion | Kustomize overlays | Helm values |
|---|---|---|
| Model | Patch/merge over plain YAML | Template rendering with parameters |
| Per-env diff visibility | Excellent — overlay *is* the diff | Weak — must render both and diff |
| Logic (conditionals, loops) | None by design | Full (Go templates) — power and foot-gun |
| Third-party software consumption | Awkward | Native (charts + versioned releases) |
| Rollback/versioning unit | Git commit | Chart version + release revision |
| Typical platform usage | In-house apps, env promotion | Off-the-shelf components (ingress, observability) |
| GitOps integration | Native in Argo CD / Flux | Native in Argo CD / Flux |

In practice platforms use **both**: Helm for vendored components, Kustomize (sometimes wrapping Helm via `helmCharts:` or Flux `HelmRelease` + per-env `valuesFrom`) for their own applications.

### 3.4 GitOps repo layout: folch-per-environment vs branch-per-environment

| | Folder-per-env (recommended) | Branch-per-env |
|---|---|---|
| Promotion | PR that copies/edits a pinned tag in the next env's folder — a reviewable diff | Merge/cherry-pick between long-lived branches |
| Drift between envs | Visible in one tree, one commit history | Hidden across branches; merge conflicts accumulate |
| Accidental divergence | Hard (same branch protection) | Easy (hotfix on prod branch never backported) |
| Tooling assumptions | Matches Argo CD/Flux docs and community guidance | Fights them |

The near-universal community position (Argo CD project, OpenGitOps): **environments are directories, not branches**. Promotion is a pull request that changes exactly one thing — typically the image tag or chart version — in the next directory, giving an auditable, revertible promotion trail: `dev → staging → prod` as three commits.

---

## 4. Environment bootstrap: what a namespace-based environment actually contains

An "environment" on a shared cluster is never just a namespace. The platform must stamp out the full guardrail set atomically. Complete bootstrap manifest for one environment:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop-staging
  labels:
    environment: staging
    team: shop
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: env-quota
  namespace: shop-staging
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.memory: 32Gi
    pods: "60"
    persistentvolumeclaims: "10"
    services.loadbalancers: "0"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: env-defaults
  namespace: shop-staging
spec:
  limits:
  - type: Container
    default:            # applied when a container declares no limits
      memory: 256Mi
    defaultRequest:     # applied when a container declares no requests
      cpu: 100m
      memory: 128Mi
    max:
      cpu: "2"
      memory: 4Gi
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: shop-staging
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace-and-dns
  namespace: shop-staging
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
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
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: shop-team-edit
  namespace: shop-staging
subjects:
- kind: Group
  name: team-shop
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
```

Why each piece is non-negotiable in production:

- **`ResourceQuota`** converts the namespace from a naming convention into a capacity boundary; without it, one environment can starve the cluster.
- **`LimitRange`** makes the quota *usable*: with `requests.cpu` in a quota, any pod without explicit requests is rejected — the `defaultRequest` prevents that failure class.
- **Default-deny `NetworkPolicy`** turns the environment into a network boundary; the second policy re-opens intra-environment traffic plus DNS. Cross-environment traffic (e.g., staging reaching a prod database) becomes impossible by default instead of possible by default.
- **Pod Security Admission labels** enforce the `restricted` profile per environment — dev can run `baseline` while prod runs `restricted`.
- **RBAC** scopes humans: developers get `edit` in dev/staging, read-only in prod, with prod writes reserved for the GitOps controller's service account.

Fan the environment set out with an Argo CD `ApplicationSet` (complete):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: checkout-environments
  namespace: argocd
spec:
  goTemplate: true
  generators:
  - list:
      elements:
      - env: dev
        cluster: https://kubernetes.default.svc
      - env: staging
        cluster: https://kubernetes.default.svc
      - env: prod
        cluster: https://prod-cluster.internal.example.com:6443
  template:
    metadata:
      name: 'checkout-{{ .env }}'
    spec:
      project: shop
      source:
        repoURL: https://git.example.com/shop/deploy.git
        targetRevision: main
        path: 'apps/checkout/overlays/{{ .env }}'
      destination:
        server: '{{ .cluster }}'
        namespace: 'shop-{{ .env }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=false   # namespaces come from the bootstrap app, with guardrails
```

Note the architectural detail: **prod points at a different cluster URL** — the isolation model (section 2) is expressed directly in the delivery topology. Argo CD here runs hub-and-spoke: one control instance, many destination clusters.

---

## 5. Ephemeral environments: preview-per-pull-request

Long-lived environments answer "is it safe to promote?"; ephemeral environments answer "what does *this branch* look like, live, before merge?" The canonical implementation is an `ApplicationSet` with a `pullRequest` generator — one environment per open PR, garbage-collected on merge/close:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: checkout-previews
  namespace: argocd
spec:
  goTemplate: true
  generators:
  - pullRequest:
      github:
        owner: shop
        repo: checkout
        labels: ["preview"]          # opt-in via PR label
      requeueAfterSeconds: 120
  template:
    metadata:
      name: 'checkout-pr-{{ .number }}'
      labels:
        env-type: preview
    spec:
      project: shop-previews
      source:
        repoURL: https://git.example.com/shop/deploy.git
        targetRevision: main
        path: apps/checkout/overlays/dev
        kustomize:
          namespace: 'checkout-pr-{{ .number }}'
          images:
          - 'registry.example.com/shop/checkout:pr-{{ .number }}-{{ .head_sha }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'checkout-pr-{{ .number }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
```

Production concerns that distinguish a toy preview system from a platform-grade one:

| Concern | Mitigation |
|---|---|
| Cost runaway (100 open PRs × full stack) | Quota per preview namespace; label-gated opt-in; TTL cleanup job; scale-to-zero off-hours |
| Data | Never prod data — seeded fixtures or masked snapshots; per-preview ephemeral database (operator-provisioned) |
| Secrets | Separate secret scope; preview envs must not mount prod `ExternalSecret` paths |
| DNS/exposure | Wildcard ingress `*.preview.example.com`, SSO in front, `pr-<n>.preview.example.com` |
| Isolation | Previews belong on the *non-prod* cluster; strongest fit for vclusters when PRs need CRDs |

When previews need cluster-scoped resources (their own operators/CRDs), a namespace is not enough — this is exactly the vCluster sweet spot:

```
$ vcluster create pr-1423 --namespace preview-pr-1423 --upgrade
info   Creating namespace preview-pr-1423
info   Create vcluster pr-1423...
info   execute command: helm upgrade pr-1423 /tmp/vcluster-0.20.0.tgz ...
done   Successfully created virtual cluster pr-1423 in namespace preview-pr-1423
info   Waiting for vcluster to come up...
done   vCluster is up and running

$ vcluster list
     NAME    | NAMESPACE        | STATUS  | VERSION | CONNECTED | AGE
  -----------+------------------+---------+---------+-----------+------
    pr-1423  | preview-pr-1423  | Running | 0.20.0  |           | 45s
```

---

## 6. Infrastructure architecture: where clusters themselves come from

Environments above namespace granularity require declarative *cluster* provisioning — the infrastructure layer of the platform. Three families coexist:

| Tool family | Model | Reconciliation | Typical platform role |
|---|---|---|---|
| Terraform / OpenTofu | Imperative plan/apply over declarative HCL; state file | On demand (`apply`), drift detected only at next plan | Landing zone: accounts, VPCs, managed control planes (EKS/GKE/AKS) |
| Crossplane | Kubernetes CRDs for cloud resources; Compositions define platform APIs | Continuous (controller loop) | Self-service infra *through* the platform API (databases, buckets, clusters as claims) |
| Cluster API (CAPI) | Kubernetes CRDs for clusters/machines; management cluster reconciles workload clusters | Continuous | Fleet lifecycle: create/upgrade/scale clusters declaratively |

The architectural distinction that matters for the exam: **Terraform reconciles when a human/pipeline runs it; Crossplane and Cluster API reconcile continuously**, giving clusters the same self-healing GitOps loop that applications have. Mature platforms commonly use Terraform for the org/network substrate and a controller-based tool for anything provisioned on demand per team or per environment.

A representative Cluster API definition of an environment's cluster (management-cluster side, complete for the Docker provider used in CAPI quickstarts):

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: shop-staging
  namespace: fleet
  labels:
    environment: staging
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["192.168.0.0/16"]
    serviceDomain: cluster.local
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: shop-staging-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: DockerCluster
    name: shop-staging
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: DockerCluster
metadata:
  name: shop-staging
  namespace: fleet
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: shop-staging-control-plane
  namespace: fleet
spec:
  replicas: 3
  version: v1.31.4
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: DockerMachineTemplate
      name: shop-staging-control-plane
  kubeadmConfigSpec:
    clusterConfiguration: {}
    initConfiguration:
      nodeRegistration: {}
    joinConfiguration:
      nodeRegistration: {}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: DockerMachineTemplate
metadata:
  name: shop-staging-control-plane
  namespace: fleet
spec:
  template:
    spec: {}
```

```
$ clusterctl describe cluster shop-staging -n fleet
NAME                                             READY  SEVERITY  REASON  SINCE  MESSAGE
Cluster/shop-staging                             True                     4m
├─ClusterInfrastructure - DockerCluster/shop-…   True                     5m
└─ControlPlane - KubeadmControlPlane/shop-sta…   True                     4m
  └─3 Machines...                                True                     4m
```

The management-cluster pattern (CAPI) and the hub-and-spoke delivery pattern (Argo CD, section 4) compose into the standard fleet architecture: **one management plane provisions N clusters; one delivery plane deploys M environments onto them; both are driven from Git.**

---

## 7. CLI walkthrough: creating, promoting and inspecting environments

Apply the environment bootstrap and the overlay:

```
$ kubectl apply -f envs/shop-staging/bootstrap.yaml
namespace/shop-staging created
resourcequota/env-quota created
limitrange/env-defaults created
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/allow-same-namespace-and-dns created
rolebinding.rbac.authorization.k8s.io/shop-team-edit created

$ kubectl apply -k apps/checkout/overlays/staging
service/checkout created
deployment.apps/checkout created

$ kubectl -n shop-staging get deploy,po -o wide
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES
deployment.apps/checkout   2/2     2            2           41s   checkout     registry.example.com/shop/checkout:1.9.0-rc.2

NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE
pod/checkout-7f7c9d6b4-k2xqp    1/1     Running   0          41s   10.42.1.17    worker-a-2
pod/checkout-7f7c9d6b4-zr8ww    1/1     Running   0          41s   10.42.2.9     worker-b-1
```

Inspect environment capacity:

```
$ kubectl -n shop-staging describe resourcequota env-quota
Name:            env-quota
Namespace:       shop-staging
Resource         Used    Hard
--------         ----    ----
limits.memory    512Mi   32Gi
pods             2       60
requests.cpu     200m    8
requests.memory  256Mi   16Gi
```

Promote staging → prod in a folder-per-env GitOps repo — the whole promotion is one pinned-tag change:

```
$ sed -i 's/newTag: 1.8.3/newTag: 1.9.0/' apps/checkout/overlays/prod/kustomization.yaml
$ git diff --stat
 apps/checkout/overlays/prod/kustomization.yaml | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
$ git switch -c promote-checkout-1.9.0-prod && git commit -am "promote checkout 1.9.0 to prod" && git push -u origin HEAD
```

After merge, the GitOps controller converges prod; verify from the delivery plane:

```
$ argocd app list -l app.kubernetes.io/instance=checkout
NAME              CLUSTER                                    NAMESPACE     STATUS  HEALTH   SYNCPOLICY
checkout-dev      https://kubernetes.default.svc             shop-dev      Synced  Healthy  Auto-Prune
checkout-staging  https://kubernetes.default.svc             shop-staging  Synced  Healthy  Auto-Prune
checkout-prod     https://prod-cluster.internal.example.com  shop-prod     Synced  Healthy  Auto-Prune
```

Compare what actually runs across environments (the ground-truth parity check):

```
$ for ctx in nonprod prod; do for ns in shop-staging shop-prod; do \
    kubectl --context $ctx -n $ns get deploy checkout \
      -o jsonpath='{.metadata.namespace}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null; \
  done; done
shop-staging	registry.example.com/shop/checkout:1.9.0
shop-prod	registry.example.com/shop/checkout:1.9.0
```

---

## 8. Verification and failure diagnosis guide

### 8.1 Symptom → cause → diagnostic

| Symptom | Likely cause | First diagnostic |
|---|---|---|
| Deployment stuck `0/N`, no pods at all | `ResourceQuota` rejects pod creation (often: no requests set, quota requires them) | `kubectl -n <ns> describe rs <rs>` → look for `FailedCreate` events |
| Pods `Pending` | Quota fine but cluster capacity / `topologySpreadConstraints` unsatisfiable in this env | `kubectl describe pod` → scheduler events |
| App reaches dependencies in dev but not staging | Default-deny `NetworkPolicy` present in staging only; missing egress rule | `kubectl -n <ns> get netpol`; test with a curl pod |
| Argo CD app `OutOfSync` loops forever | Mutating webhook or HPA fighting Git (e.g., `replicas` both in Git and HPA-managed) | `argocd app diff <app>`; remove `replicas` from the overlay |
| Prod behaves differently from staging despite same tag | Parity drift: different cluster version, LimitRange defaults, or env var patch only in one overlay | Render both overlays and diff (below) |
| Preview envs pile up after PRs close | `prune: false`, generator auth failing, or missing PR label filter | `kubectl -n argocd get applicationset -o yaml` → status conditions |
| New environment's pods rejected with PSA error | Namespace enforces `restricted` but base manifest lacks securityContext | `kubectl -n <ns> get events`; check namespace PSA labels |

### 8.2 Quota rejection — the classic environment failure, end to end

```
$ kubectl -n shop-staging get deploy checkout
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
checkout   0/2     0            0           2m

$ kubectl -n shop-staging get rs -l app.kubernetes.io/name=checkout
NAME                  DESIRED   CURRENT   READY   AGE
checkout-7f7c9d6b4    2         0         0       2m

$ kubectl -n shop-staging describe rs checkout-7f7c9d6b4 | tail -n 4
Events:
  Type     Reason        Age                Message
  ----     ------        ----               -------
  Warning  FailedCreate  12s (x6 over 2m)   Error creating: pods "checkout-7f7c9d6b4-" is forbidden:
    exceeded quota: env-quota, requested: requests.cpu=500m, used: requests.cpu=7800m, limited: requests.cpu=8
```

Read the three numbers: `requested + used > limited`. The fix is an environment-capacity decision (raise the quota via the environment's Git definition, or reduce requests) — **never** an ad-hoc `kubectl edit quota` on the live cluster, which reintroduces drift. Key detail: the *Deployment* shows no error; quota rejections surface on the **ReplicaSet**, which is why `describe rs` is the reflex.

### 8.3 Structural parity check between environments

Drift between rendered environments is caught mechanically, pre-merge:

```
$ diff <(kubectl kustomize apps/checkout/overlays/staging) \
       <(kubectl kustomize apps/checkout/overlays/prod)
14c14
<   namespace: shop-staging
---
>   namespace: shop-prod
47c47
<   replicas: 2
---
>   replicas: 3
61c61
<         image: registry.example.com/shop/checkout:1.9.0
---
>         image: registry.example.com/shop/checkout:1.8.3
```

Every line of this diff must be an *intentional* difference (namespace, replicas, pinned version mid-promotion). An unexpected line — an env var, a probe, a securityContext present in only one overlay — is drift; fix it in the base. Run this diff in CI on every PR touching overlays.

Live-cluster drift against Git (GitOps ground truth):

```
$ argocd app diff checkout-prod
===== apps/Deployment shop-prod/checkout ======
47c47
<         replicas: 3
---
>         replicas: 5
```

Here someone scaled prod by hand; with `selfHeal: true` Argo CD reverts it, and the correct channel for the change is a PR to `overlays/prod`.

### 8.4 Network isolation verification

Prove the environment boundary actually holds — from a staging pod, prod must be unreachable:

```
$ kubectl -n shop-staging run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
    wget -qO- --timeout=3 http://checkout.shop-prod.svc.cluster.local
wget: download timed out
pod "nettest" deleted
pod default/nettest terminated (Error)
```

A timeout is the *desired* outcome. If content comes back, the default-deny policy is missing or the CNI does not enforce `NetworkPolicy` (verify the CNI supports it — a policy on a non-enforcing CNI is silently inert; run the same probe as the test).

### 8.5 Pre-promotion verification checklist

1. **Render diff** between source and target overlays shows only intended deltas (§8.3).
2. **Provenance**: the image tag being promoted is immutable (digest or unique tag), signed, and identical to the one validated in the previous environment.
3. **Capacity**: target environment's `ResourceQuota` headroom covers the new requests (`kubectl describe quota`).
4. **Policy**: rendered manifests pass the target namespace's PSA level and any admission policies (`kubectl apply --dry-run=server -k overlays/prod`).
5. **Post-sync**: app `Synced/Healthy` in the delivery plane, rollout complete (`kubectl rollout status deploy/checkout -n shop-prod`), golden signals stable.

---

## Referencias

- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF Platforms Whitepaper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/maturity-model/
- The Twelve-Factor App — Dev/prod parity: https://12factor.net/dev-prod-parity
- Kubernetes — Namespaces: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes — Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes — Multi-tenancy guide: https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Kustomize documentation: https://kubectl.docs.kubernetes.io/references/kustomize/
- Helm documentation — Values files: https://helm.sh/docs/chart_template_guide/values_files/
- Argo CD — ApplicationSet (Pull Request generator): https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/
- Argo CD — Best practices (repo/environment layout): https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/
- OpenGitOps — GitOps Principles: https://opengitops.dev/
- Cluster API Book: https://cluster-api.sigs.k8s.io/
- Crossplane documentation: https://docs.crossplane.io/
- vCluster documentation: https://www.vcluster.com/docs
- OpenTofu documentation: https://opentofu.org/docs/