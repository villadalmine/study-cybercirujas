# 3.5 CI/CD Relationship Fundamentals and Integration

> **Tema 3.5 — CNPA (versión 2025-04-01) · Peso: 2.3**
> Dominio: relación entre la *Internal Developer Platform* (IDP) y los sistemas de CI/CD.

---

## 1. Motivación y problema arquitectónico de producción

Un error recurrente en organizaciones que adoptan Kubernetes es tratar CI/CD como **un solo sistema monolítico** — un `Jenkinsfile` gigante que compila, testea, construye la imagen, `kubectl apply` contra el cluster y ejecuta smoke tests, todo con un `kubeconfig` de `cluster-admin` inyectado en el runner. Ese diseño colapsa por tres razones estructurales que el CNPA evalúa directamente:

1. **Acoplamiento de credenciales (blast radius).** Un runner de CI que tiene acceso de escritura a producción convierte cada dependencia de la pipeline (una `action` de GitHub, un plugin de Jenkins, una imagen base) en un vector de compromiso del cluster. El incidente de *Codecov* (2021) y el patrón de ataques a la *software supply chain* demuestran que el runner es el eslabón más expuesto.
2. **Deriva de configuración (configuration drift).** Con push imperativo (`kubectl apply` desde la pipeline), el estado real del cluster no tiene una fuente de verdad. Un `hotfix` manual con `kubectl edit` sobrevive hasta el próximo deploy y nadie lo sabe. No hay reconciliación.
3. **Falta de una superficie de auto-servicio.** El equipo de plataforma no puede ofrecer *golden paths* si cada equipo escribe su propio pegamento de deploy. La plataforma debe exponer CI/CD como una **capability**, no como un tutorial de YAML.

El núcleo conceptual del tema es la **separación entre CI y CD**, y por qué en cloud-native esa frontera se traza en un artefacto inmutable y en un repositorio Git de estado deseado:

- **CI (Continuous Integration)** responde a *"¿el código es correcto y produce un artefacto confiable?"* — compilar, testear, escanear, construir una imagen OCI, firmarla, generar el SBOM y **publicar**. La CI **no toca el cluster**.
- **CD (Continuous Delivery/Deployment)** responde a *"¿el estado deseado declarado en Git está reconciliado en el cluster?"* — la CD observa un repositorio de configuración y converge el cluster hacia él.

El punto de contacto — **la "relación" que da nombre al tema** — es un único evento con dirección bien definida: *la CI actualiza una referencia de imagen en el repo de configuración; la CD detecta ese cambio y despliega.* Ningún sistema de CI necesita credenciales del cluster productivo. Esa es la tesis arquitectónica de GitOps.

```
┌──────────────┐   git push    ┌───────────────┐  build+sign   ┌──────────────┐
│  App Repo    │ ────────────► │   CI System   │ ────────────► │  OCI Registry │
│  (código)    │               │ (Tekton/GHA)  │               │  (imagen+sig) │
└──────────────┘               └──────┬────────┘               └──────────────┘
                                      │ bump image tag (write)
                                      ▼
                             ┌────────────────┐   reconcile    ┌──────────────┐
                             │  Config Repo   │ ◄────pull────── │  CD Operator │
                             │ (estado deseado)│                │ (Argo CD/Flux)│
                             └────────────────┘                └──────┬───────┘
                                                                      │ apply
                                                                      ▼
                                                              ┌──────────────┐
                                                              │  Cluster K8s │
                                                              └──────────────┘
```

La frontera CI↔CD es el *Config Repo*. La flecha `reconcile` va **desde el cluster hacia el repo** (pull), no al revés.

---

## 2. Comparativas técnicas con tablas de trade-offs

### 2.1 Push-based vs. Pull-based CD

| Dimensión | Push CD (`kubectl apply` desde CI) | Pull CD / GitOps (Argo CD, Flux) |
|---|---|---|
| Ubicación de credenciales | Runner de CI (externo, expuesto) | Operador dentro del cluster (`ServiceAccount` local) |
| Fuente de verdad del estado | Ninguna estable — el último `apply` gana | El repositorio Git |
| Detección de drift | No | Sí, reconciliación continua (`selfHeal`) |
| Rollback | Re-ejecutar pipeline anterior (frágil) | `git revert` — auditable, atómico |
| Blast radius de un CI comprometido | Todo el cluster | Solo el registry / config repo (write) |
| Multi-cluster | N *kubeconfigs* en CI | Un operador por cluster, mismo repo |
| Latencia de deploy | Baja (inmediata) | Intervalo de reconciliación (segundos, o webhook) |
| Observabilidad de "qué está desplegado" | Logs de pipeline | `Sync/Health status` declarativo |

### 2.2 Motores de CD GitOps

| Característica | **Argo CD** | **Flux (Flux CD v2)** |
|---|---|---|
| Modelo | Aplicación centralizada + UI/CLI potente | Toolkit de controladores componibles |
| CRD principal | `Application`, `ApplicationSet` | `GitRepository`+`Kustomization`/`HelmRelease` |
| UI incorporada | Sí (rica, con diff/tree view) | No (usa Weave GitOps / Capacitor por separado) |
| Escala multi-tenant | `AppProject` + RBAC | Namespaces + `ServiceAccount` por tenant |
| Image automation | Vía Argo CD Image Updater (add-on) | Integrada (`image-reflector`+`image-automation`) |
| Notificaciones | `argocd-notifications` | `notification-controller` (nativo) |
| Modelo mental | "Estado de la app" | "Reconciliadores de fuentes" |

### 2.3 Estrategias de deployment (el rol de CD en *progressive delivery*)

| Estrategia | Downtime | Costo de recursos | Rollback | Detección temprana de regresión | Herramienta |
|---|---|---|---|---|---|
| Recreate | Sí | 1× | Manual | No | K8s nativo |
| RollingUpdate | No | ~1.1× | Rollout undo | Débil (readiness) | Deployment nativo |
| Blue-Green | No | 2× (pico) | Instantáneo (switch) | Antes del switch | Argo Rollouts / Flagger |
| Canary | No | 1.2×–2× | Gradual/instantáneo | Sí (análisis de métricas) | Argo Rollouts / Flagger |

**Trade-off central:** blue-green da rollback instantáneo a costa de duplicar recursos; canary limita el blast radius a un porcentaje del tráfico y automatiza el *rollback* mediante análisis de métricas (`AnalysisTemplate`), pero exige que la plataforma exponga SLIs confiables (Prometheus) y una capa de tráfico ponderado (service mesh o `Ingress` con soporte de pesos).

---

## 3. Manifiestos completos (sin recortar)

### 3.1 CI Kubernetes-nativa con Tekton (build + firma + bump)

Un `Pipeline` de Tekton que representa el lado CI de la relación. **No despliega nada**: construye, firma y actualiza el config repo.

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: ci-build-sign-promote
  namespace: ci
spec:
  params:
    - name: app-repo-url
      type: string
    - name: config-repo-url
      type: string
    - name: image-ref
      type: string
      default: ghcr.io/acme/payments-api
  workspaces:
    - name: shared
    - name: dockerconfig        # credenciales de push al registry
    - name: git-ssh             # deploy key de escritura al config repo
  tasks:
    - name: clone
      taskRef:
        name: git-clone         # de Tekton Hub
      params:
        - name: url
          value: $(params.app-repo-url)
      workspaces:
        - name: output
          workspace: shared
    - name: unit-test
      runAfter: ["clone"]
      taskRef:
        name: golang-test
      workspaces:
        - name: source
          workspace: shared
    - name: build-image
      runAfter: ["unit-test"]
      taskRef:
        name: kaniko            # build sin daemon Docker (rootless)
      params:
        - name: IMAGE
          value: $(params.image-ref):$(tasks.clone.results.commit)
      workspaces:
        - name: source
          workspace: shared
        - name: dockerconfig
          workspace: dockerconfig
    - name: sign-image
      runAfter: ["build-image"]
      taskRef:
        name: cosign-sign       # firma keyless con OIDC del pipeline
      params:
        - name: image
          value: $(params.image-ref)@$(tasks.build-image.results.IMAGE_DIGEST)
    - name: promote
      runAfter: ["sign-image"]
      taskRef:
        name: git-cli
      params:
        - name: GIT_SCRIPT
          value: |
            git clone $(params.config-repo-url) config && cd config
            yq -i '.spec.template.spec.containers[0].image =
              "$(params.image-ref)@$(tasks.build-image.results.IMAGE_DIGEST)"' \
              envs/production/deployment.yaml
            git add -A
            git commit -m "ci: promote payments-api $(tasks.clone.results.commit)"
            git push origin main
      workspaces:
        - name: source
          workspace: git-ssh
```

Obsérvese que la **única** escritura hacia infraestructura es `git push` al **config repo** — nunca `kubectl` contra el cluster. La imagen se referencia por **digest** (`@sha256:...`), no por tag mutable: eso es lo que hace el deploy inmutable y auditable.

### 3.2 CD con Argo CD: `Application` y `AppProject`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
spec:
  description: Tenant payments — guardarraíles de plataforma
  sourceRepos:
    - https://github.com/acme/payments-config.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: payments
  clusterResourceWhitelist: []          # sin recursos cluster-scoped
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota                # el tenant no toca sus propias quotas
  roles:
    - name: deployer
      policies:
        - p, proj:payments:deployer, applications, sync, payments/*, allow
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascada limpia al borrar
spec:
  project: payments
  source:
    repoURL: https://github.com/acme/payments-config.git
    targetRevision: main
    path: envs/production
  destination:
    server: https://kubernetes.default.svc
    namespace: payments
  syncPolicy:
    automated:
      prune: true        # borra recursos que ya no están en Git
      selfHeal: true     # revierte cambios manuales (anti-drift)
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
```

### 3.3 Equivalente en Flux CD v2

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: payments-config
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/acme/payments-config.git
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments-api
  namespace: flux-system
spec:
  interval: 5m
  path: ./envs/production
  prune: true
  sourceRef:
    kind: GitRepository
    name: payments-config
  targetNamespace: payments
  wait: true
  timeout: 3m
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: payments-api
      namespace: payments
```

### 3.4 Progressive delivery: Argo Rollouts (canary con análisis)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments-api
  namespace: payments
spec:
  replicas: 6
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      containers:
        - name: api
          image: ghcr.io/acme/payments-api@sha256:abc123
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
  strategy:
    canary:
      canaryService: payments-api-canary
      stableService: payments-api-stable
      trafficRouting:
        istio:
          virtualService:
            name: payments-api-vsvc
            routes:
              - primary
      steps:
        - setWeight: 20
        - pause: {duration: 2m}
        - analysis:
            templates:
              - templateName: success-rate
        - setWeight: 50
        - pause: {duration: 5m}
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: payments
spec:
  metrics:
    - name: success-rate
      interval: 30s
      count: 4
      successCondition: result[0] >= 0.99
      failureLimit: 1              # 1 fallo => rollback automático
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{app="payments-api",code!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{app="payments-api"}[2m]))
```

### 3.5 Guardarraíl de supply chain: verificación de firma en admisión (Kyverno)

La plataforma cierra el lazo: la CD sólo puede desplegar imágenes que la CI firmó.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-payments-signature
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-keyless-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["payments"]
      verifyImages:
        - imageReferences:
            - "ghcr.io/acme/payments-api*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/acme/payments-api/.github/workflows/ci.yaml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

---

## 4. Comandos CLI y salidas reales

**Estado de sincronización en Argo CD:**

```console
$ argocd app get payments-api
Name:               argocd/payments-api
Project:            payments
Server:             https://kubernetes.default.svc
Namespace:          payments
URL:                https://argocd.acme.io/applications/payments-api
Source:
- Repo:             https://github.com/acme/payments-config.git
  Target:           main
  Path:             envs/production
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME          STATUS  HEALTH   HOOK  MESSAGE
       Service     payments   payments-api  Synced  Healthy
apps   Deployment  payments   payments-api  Synced  Healthy        deployment "payments-api" successfully rolled out
```

**Forzar reconciliación y ver el diff contra Git:**

```console
$ argocd app diff payments-api
===== apps/Deployment payments/payments-api ======
23c23
<     image: ghcr.io/acme/payments-api@sha256:abc123
---
>     image: ghcr.io/acme/payments-api@sha256:def456

$ argocd app sync payments-api
TIMESTAMP          GROUP  KIND        NAMESPACE  NAME          STATUS    HEALTH
2026-08-07T14:22   apps   Deployment  payments   payments-api  Syncing   Progressing
2026-08-07T14:22   apps   Deployment  payments   payments-api  Synced    Healthy
Operation succeeded
```

**Progreso de un canary con Argo Rollouts:**

```console
$ kubectl argo rollouts get rollout payments-api --watch
Name:            payments-api
Namespace:       payments
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/6
  SetWeight:     20
  ActualWeight:  20
Images:          ghcr.io/acme/payments-api@sha256:def456 (canary)
                 ghcr.io/acme/payments-api@sha256:abc123 (stable)
Replicas:
  Desired:       6
  Current:       7
  Updated:       2
  Ready:         7
  Available:     7

NAME                                     KIND        STATUS     AGE  INFO
⟳ payments-api                           Rollout     ॥ Paused   4d
├──# revision:2
│  └──⧉ payments-api-6c9f7d               ReplicaSet  ✔ Healthy  40s  canary
└──# revision:1
   └──⧉ payments-api-5b8e6c               ReplicaSet  ✔ Healthy  4d   stable
```

**Análisis fallido → rollback automático:**

```console
$ kubectl argo rollouts get rollout payments-api
Status:          ✖ Degraded
Message:         RolloutAborted: metric "success-rate" assessed Failed:
                 count(1) > failureLimit(1)
$ kubectl argo rollouts status payments-api
Error: The rollout is aborted
```

**Verificar firma manualmente con cosign (la misma verificación que hace Kyverno):**

```console
$ cosign verify \
    --certificate-identity-regexp "https://github.com/acme/payments-api/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/acme/payments-api@sha256:def456

Verification for ghcr.io/acme/payments-api@sha256:def456 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

**Reconciliación bajo demanda en Flux:**

```console
$ flux reconcile kustomization payments-api --with-source
► annotating GitRepository payments-config in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:a1b2c3d
► annotating Kustomization payments-api in flux-system namespace
✔ Kustomization reconciliation completed
✔ applied revision main@sha1:a1b2c3d
```

---

## 5. Verificación y diagnóstico de fallas

**Rollback declarativo (GitOps) — la operación es `git`, no `kubectl`:**

```console
$ git -C payments-config revert --no-edit HEAD
$ git -C payments-config push origin main
# Argo CD/Flux detecta el revert y reconcilia al estado anterior.
```

### Runbook de fallas frecuentes

| Síntoma | Causa probable | Diagnóstico | Remediación |
|---|---|---|---|
| `Sync Status: OutOfSync` persistente | Drift por edición manual (`kubectl edit`) | `argocd app diff <app>` | Activar `selfHeal`; educar sobre no editar en vivo |
| `Health: Degraded`, pods `ImagePullBackOff` | Digest inexistente o registry sin credenciales | `kubectl describe pod`; revisar `imagePullSecrets` | Corregir referencia en config repo; recrear secret |
| `ComparisonError: authentication required` | Deploy key del config repo caducada | Logs de `argocd-repo-server` | Rotar credencial del repositorio |
| Sync exitoso pero app inaccesible | CD reconcilió; el problema es de red/mesh | `kubectl get endpoints`, `istioctl analyze` | Revisar `Service`/`VirtualService`, no la CD |
| Pod bloqueado en admisión | Imagen sin firma o no coincide identidad | `kubectl get events`; `PolicyReport` de Kyverno | Firmar en CI; corregir `subject`/`issuer` |
| Canary nunca progresa (`Paused`) | `AnalysisTemplate` sin datos de Prometheus | `kubectl argo rollouts get rollout`; probar la query PromQL | Corregir la métrica/labels; verificar scraping |
| `prune` borró un recurso vivo | Objeto creado fuera de Git | `argocd app history`; auditar quién lo creó | Mover el recurso a Git o excluirlo del sync |

**Verificación end-to-end de la relación CI↔CD (checklist operativo):**

```console
# 1. La CI produjo un artefacto firmado y por digest
$ cosign verify ... ghcr.io/acme/payments-api@sha256:def456   # → OK

# 2. La CI escribió el digest en el config repo (no un tag mutable)
$ grep image payments-config/envs/production/deployment.yaml
    image: ghcr.io/acme/payments-api@sha256:def456

# 3. La CD reconcilió ese commit exacto
$ argocd app get payments-api -o json | jq '.status.sync.revision'
"a1b2c3d"

# 4. El estado real coincide con el deseado (sin drift)
$ argocd app get payments-api -o json | jq '.status.sync.status'
"Synced"

# 5. Ninguna credencial de cluster vive en la CI
$ tkn pipelinerun describe ci-build-sign-promote-xyz | grep -i kubeconfig
# (sin resultados — correcto)
```

**Antipatrón a detectar:** si la pipeline de CI ejecuta `kubectl apply` o monta un `kubeconfig` de producción, la separación CI/CD está rota — el config repo dejó de ser la fuente de verdad y el blast radius del runner incluye el cluster. La corrección es mover la escritura al config repo y delegar el `apply` al operador de CD.

---

## 6. Referencias

- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Argo CD — Documentación oficial: https://argo-cd.readthedocs.io/en/stable/
- Argo Rollouts — Progressive Delivery: https://argo-rollouts.readthedocs.io/en/stable/
- Flux CD v2 — Documentación oficial: https://fluxcd.io/flux/
- Tekton Pipelines: https://tekton.dev/docs/pipelines/
- Flagger — Progressive Delivery Operator: https://docs.flagger.app/
- OpenGitOps — Principios GitOps (CNCF): https://opengitops.dev/
- Sigstore / cosign: https://docs.sigstore.dev/
- Kyverno — verifyImages: https://kyverno.io/docs/writing-policies/verify-images/
- SLSA — Supply-chain Levels for Software Artifacts: https://slsa.dev/
- Kubernetes — Deployments (rollout/rollback): https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- CNCF Platforms White Paper (capabilities de plataforma): https://tag-app-delivery.cncf.io/whitepapers/platforms/