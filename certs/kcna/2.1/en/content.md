# Application Delivery

## Introduction

**Application Delivery** is the set of practices and tools that allow taking code from the repository to production in an automated, repeatable, and secure way in a cloud native environment. The KCNA groups three conceptual blocks here:

1. **CI/CD** (Continuous Integration / Continuous Delivery-Deployment)
2. **GitOps** as a declarative deployment model
3. **Progressive Delivery** (controlled rollout strategies: rolling, blue-green, canary)

These concepts are agnostic of a specific vendor, but the exam expects you to recognize the reference tools of the CNCF ecosystem: **Argo CD**, **Flux**, **Tekton**, **Argo Rollouts**, among others.

---

## CI/CD

- **Continuous Integration (CI)**: every code change is frequently integrated into a shared branch, triggering automatic build + tests. Example tools: Jenkins, GitLab CI, GitHub Actions, **Tekton** (Kubernetes-native, CNCF graduated).
- **Continuous Delivery**: the artifact (container image) always remains in a deployable state, but the move to production requires approval (manual gate).
- **Continuous Deployment**: extends the previous concept by removing the manual gate: every commit that passes the tests reaches production automatically.

A typical cloud native pipeline:

```
commit → build imagen → test → push a registry → actualizar manifiesto → deploy en cluster
```

Simplified example of a Tekton `Task` that builds and pushes an image with Kaniko:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: build-push
spec:
  steps:
    - name: build-and-push
      image: gcr.io/kaniko-project/executor:latest
      args:
        - --dockerfile=Dockerfile
        - --destination=registry.example.com/app:$(params.tag)
        - --context=/workspace/source
```

---

## GitOps

**GitOps** is an operating model where **Git is the single source of truth** for the desired state of infrastructure and applications. An *operator/controller* inside the cluster continuously reconciles the actual state against what is declared in the repository, without anyone manually running `kubectl apply` against production.

Key principles (defined by OpenGitOps, a CNCF project):

1. **Declarative**: the entire system is described declaratively.
2. **Versioned and Immutable**: the desired state is stored in a way that guarantees immutability, versioning, and complete history (Git).
3. **Pulled Automatically**: software agents automatically pull the desired state.
4. **Continuously Reconciled**: the software continuously reconciles the observed state against the desired state, correcting drift.

### Reference tools

| Herramienta | Modelo | Notas |
|---|---|---|
| **Argo CD** | Pull-based, con UI y CLI propias | CNCF graduated; sincroniza un `Application` CR contra un repo Git |
| **Flux** (Flux CD) | Pull-based, basado en controllers/CRDs (`GitRepository`, `Kustomization`) | CNCF graduated; se integra con Helm, Kustomize, notificaciones |

Example of an Argo CD `Application` resource:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mi-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/mi-app-manifests.git
    targetRevision: main
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: mi-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Equivalent command via CLI:

```
$ argocd app create mi-app \
    --repo https://github.com/org/mi-app-manifests.git \
    --path k8s/overlays/prod \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace mi-app \
    --sync-policy automated

$ argocd app get mi-app
Name:               mi-app
Sync Status:        Synced
Health Status:      Healthy
```

`selfHeal: true` is what guarantees the "continuously reconciled" principle: if someone manually modifies a resource in the cluster (drift), Argo CD automatically reverts it to the state declared in Git.

---

## Progressive Delivery

Strategies for deploying new versions while minimizing the risk of impact on users:

### Rolling Update
Default strategy of a Kubernetes `Deployment`: replaces old Pods with new ones incrementally, controlled by `maxSurge` and `maxUnavailable`.

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

### Blue-Green Deployment
Two identical environments are maintained ("blue" = current version, "green" = new version). Traffic is cut over all at once from the old environment to the new one (usually by changing a Service/selector or an Ingress). Instant rollback: simply point traffic back to the "blue" environment.

### Canary Deployment
The new version is released to a small percentage of traffic/users, metrics are observed (error rate, latency), and, if everything is fine, it is gradually increased up to 100%. If something fails, the percentage is reverted to 0.

**Argo Rollouts** (a CNCF project) replaces the standard `Deployment` with a `Rollout` CRD that natively supports blue-green and canary, integrating with Ingress controllers or service meshes (Istio, Linkerd, SMI) for traffic shifting:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: mi-app
spec:
  replicas: 5
  strategy:
    canary:
      steps:
        - setWeight: 20
        - pause: {duration: 10m}
        - setWeight: 50
        - pause: {duration: 10m}
        - setWeight: 100
```

Command to observe the rollout progress:

```
$ kubectl argo rollouts get rollout mi-app --watch

Name:            mi-app
Strategy:        Canary
  Step:          2/5
  SetWeight:     20
  ActualWeight:  20
Images:          registry.example.com/app:v2 (canary)
                 registry.example.com/app:v1 (stable)
```

---

## References

- CNCF Curriculum — KCNA Curriculum PDF: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes Docs — Deployments (RollingUpdate strategy): https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Argo CD Docs: https://argo-cd.readthedocs.io/en/stable/
- Argo Rollouts Docs: https://argo-rollouts.readthedocs.io/en/stable/
- Flux CD Docs: https://fluxcd.io/flux/
- OpenGitOps — Principles: https://opengitops.dev/
- Tekton Docs: https://tekton.dev/docs/
- CNCF CI/CD Landscape: https://landscape.cncf.io/category=continuous-integration-delivery