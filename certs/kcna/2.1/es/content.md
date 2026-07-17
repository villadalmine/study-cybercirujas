# Application Delivery

## Introducción

**Application Delivery** es el conjunto de prácticas y herramientas que permiten llevar código desde el repositorio hasta producción de forma automatizada, repetible y segura en un entorno cloud native. El KCNA agrupa acá tres bloques conceptuales:

1. **CI/CD** (Continuous Integration / Continuous Delivery-Deployment)
2. **GitOps** como modelo declarativo de despliegue
3. **Progressive Delivery** (estrategias de rollout controlado: rolling, blue-green, canary)

Estos conceptos son agnósticos de un vendor específico, pero el examen espera que reconozcas las herramientas de referencia del ecosistema CNCF: **Argo CD**, **Flux**, **Tekton**, **Argo Rollouts**, entre otras.

---

## CI/CD

- **Continuous Integration (CI)**: cada cambio de código se integra frecuentemente a una rama compartida, disparando build + tests automáticos. Ejemplos de herramientas: Jenkins, GitLab CI, GitHub Actions, **Tekton** (nativo de Kubernetes, CNCF graduated).
- **Continuous Delivery**: el artefacto (imagen de contenedor) queda siempre en estado desplegable, pero el paso a producción requiere una aprobación (manual gate).
- **Continuous Deployment**: extiende el concepto anterior eliminando el gate manual: todo commit que pasa los tests llega a producción automáticamente.

Un pipeline típico cloud native:

```
commit → build imagen → test → push a registry → actualizar manifiesto → deploy en cluster
```

Ejemplo simplificado de un `Task` de Tekton que construye y sube una imagen con Kaniko:

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

**GitOps** es un modelo operativo donde **Git es la única fuente de verdad** (single source of truth) del estado deseado de la infraestructura y las aplicaciones. Un *operator/controller* dentro del cluster reconcilia continuamente el estado real contra lo declarado en el repositorio, sin que nadie ejecute `kubectl apply` manualmente contra producción.

Principios clave (definidos por OpenGitOps, proyecto CNCF):

1. **Declarative**: el sistema completo se describe declarativamente.
2. **Versioned and Immutable**: el estado deseado se almacena de forma que garantiza inmutabilidad, versionado y historial completo (Git).
3. **Pulled Automatically**: agentes de software extraen (pull) automáticamente el estado deseado.
4. **Continuously Reconciled**: el software reconcilia continuamente el estado observado contra el deseado, corrigiendo drift.

### Herramientas de referencia

| Herramienta | Modelo | Notas |
|---|---|---|
| **Argo CD** | Pull-based, con UI y CLI propias | CNCF graduated; sincroniza un `Application` CR contra un repo Git |
| **Flux** (Flux CD) | Pull-based, basado en controllers/CRDs (`GitRepository`, `Kustomization`) | CNCF graduated; se integra con Helm, Kustomize, notificaciones |

Ejemplo de un recurso `Application` de Argo CD:

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

Comando equivalente vía CLI:

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

`selfHeal: true` es lo que garantiza el principio de "continuously reconciled": si alguien modifica un recurso manualmente en el cluster (drift), Argo CD lo revierte automáticamente al estado declarado en Git.

---

## Progressive Delivery

Estrategias para desplegar nuevas versiones minimizando el riesgo de impacto en usuarios:

### Rolling Update
Estrategia por defecto de un `Deployment` en Kubernetes: reemplaza Pods viejos por nuevos de forma incremental, controlado por `maxSurge` y `maxUnavailable`.

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

### Blue-Green Deployment
Se mantienen dos entornos idénticos ("blue" = versión actual, "green" = versión nueva). El tráfico se corta de una vez del entorno viejo al nuevo (normalmente cambiando un Service/selector o un Ingress). Rollback instantáneo: basta con volver a apuntar el tráfico al entorno "blue".

### Canary Deployment
Se libera la nueva versión a un porcentaje pequeño de tráfico/usuarios, se observan métricas (error rate, latencia) y, si todo está bien, se incrementa gradualmente hasta el 100%. Si algo falla, se revierte el porcentaje a 0.

**Argo Rollouts** (proyecto CNCF) reemplaza el `Deployment` estándar por un CRD `Rollout` que soporta blue-green y canary de forma nativa, integrándose con Ingress controllers o service meshes (Istio, Linkerd, SMI) para el shifting de tráfico:

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

Comando para observar el progreso del rollout:

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

## Referencias

- CNCF Curriculum — KCNA Curriculum PDF: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes Docs — Deployments (RollingUpdate strategy): https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Argo CD Docs: https://argo-cd.readthedocs.io/en/stable/
- Argo Rollouts Docs: https://argo-rollouts.readthedocs.io/en/stable/
- Flux CD Docs: https://fluxcd.io/flux/
- OpenGitOps — Principles: https://opengitops.dev/
- Tekton Docs: https://tekton.dev/docs/
- CNCF CI/CD Landscape: https://landscape.cncf.io/category=continuous-integration-delivery