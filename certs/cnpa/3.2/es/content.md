# Tema 3.2 — Continuous Delivery Concepts and GitOps Principles

> **Certificación:** CNPA (Cloud Native Platform Engineering Associate) — versión de examen 2025-04-01
> **Dominio 3 · Peso del tema: 2.3**
> **Perfil:** SRE / Platform Architect — comprensión de producción de la mecánica interna, no recetas.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El punto de partida: `kubectl apply` desde el laptop

El modelo ingenuo de entrega en Kubernetes es un pipeline de CI (Jenkins, GitLab CI, GitHub Actions) que, al final del build, ejecuta `kubectl apply -f` o `helm upgrade` contra el cluster. Es el modelo **push**: un actor externo, con credenciales del cluster, empuja el cambio hacia adentro. Funciona en una demo y colapsa en producción por cuatro razones que se acumulan a escala de plataforma:

1. **La verdad del cluster es imposible de conocer.** El estado vivo es la suma de todos los `apply` históricos, `kubectl edit` de madrugada, HPA que escaló réplicas, un operator que mutó un campo y un `kubectl scale` que nadie registró. No hay una fuente única contra la cual comparar. La pregunta "¿qué debería estar corriendo?" no tiene respuesta auditable.

2. **Drift silencioso (configuration drift).** Entre dos deploys, el estado real diverge del deseado. Un `kubectl set image` de emergencia arregla un incidente a las 3 AM; tres semanas después el siguiente deploy sobrescribe ese fix, el incidente reaparece y nadie entiende por qué. El drift no es un bug: es la entropía natural de un sistema mutable sin reconciliación.

3. **Superficie de credenciales invertida.** En el modelo push, el runner de CI —expuesto a internet, ejecutando código de cualquier PR— posee `cluster-admin` o algo cercano. Un token filtrado en un log de CI es un compromiso total del cluster. La credencial más sensible vive en el lugar menos confiable.

4. **Recuperación ante desastres no determinista.** Si el cluster se pierde, reconstruirlo significa recordar y re-ejecutar N pipelines en el orden correcto. No hay un artefacto declarativo del que partir. El MTTR depende de la memoria del equipo.

### 1.2 El giro conceptual: el cluster converge hacia Git

**Continuous Delivery (CD)** es la disciplina de mantener el software en un estado *siempre desplegable*, con cada cambio validado por un pipeline automatizado hasta la puerta de producción. **GitOps** es una implementación específica de CD para infraestructura declarativa que resuelve los cuatro problemas anteriores invirtiendo la dirección del flujo: en vez de empujar el estado hacia el cluster, un **agente dentro del cluster tira (pull) el estado deseado desde Git y reconcilia continuamente** el estado real contra él.

El cambio arquitectónico central es tratar al cluster como un **sistema de control con realimentación (closed-loop control system)**, exactamente como el reconciliation loop nativo de Kubernetes, pero extendido hasta Git:

```
   Git (estado deseado)  ──pull──►  Agente (Argo CD / Flux)
          ▲                              │
          │                             diff
     commit/PR                           │
          │                              ▼
   Desarrollador            aplica delta ──► API Server ──► estado real
          ▲                                                    │
          └───────────── detecta drift ◄──── observa ─────────┘
```

Git deja de ser un repositorio de código y pasa a ser el **plano de control declarativo**: la única fuente de verdad (single source of truth), el registro de auditoría inmutable y el botón de rollback (`git revert`).

### 1.3 Los cuatro principios de OpenGitOps

El proyecto **OpenGitOps** (CNCF Sandbox, GitOps Working Group) formaliza GitOps en cuatro principios. El examen CNPA los evalúa como definición canónica —hay que conocerlos textualmente y saber qué falla cuando falta cada uno:

| # | Principio | Enunciado | Qué garantiza | Qué se rompe si falta |
|---|-----------|-----------|---------------|----------------------|
| 1 | **Declarative** | El estado deseado se expresa de forma declarativa. | Reproducibilidad; el *qué*, no el *cómo*. | Scripts imperativos → resultado dependiente del orden y del estado previo. |
| 2 | **Versioned and Immutable** | El estado deseado se almacena de forma que impone inmutabilidad y versionado, reteniendo historial completo. | Auditoría, rollback atómico, trazabilidad. | Sin historial no hay `git revert` ni "quién cambió qué". |
| 3 | **Pulled Automatically** | Agentes de software tiran automáticamente el estado deseado desde la fuente. | Elimina credenciales de cluster fuera del cluster. | Modelo push → credenciales expuestas en CI. |
| 4 | **Continuously Reconciled** | Agentes observan continuamente el estado real e intentan aplicar el deseado. | Corrige drift solo; convergencia garantizada. | Drift persiste; deploy = evento puntual, no invariante. |

> Fuente canónica: <https://opengitops.dev/> — *"GitOps Principles v1.0.0"*.

**Distinción de examen — "Continuous Delivery" ≠ "Continuous Deployment":**

| Término | Alcance | ¿Producción automática? |
|---------|---------|-------------------------|
| **Continuous Integration (CI)** | Merge frecuente + build + test automáticos por commit. | No despliega. |
| **Continuous Delivery (CD)** | Todo cambio queda *listo* para producción; el paso final puede requerir aprobación manual (gate). | Opcional / con gate. |
| **Continuous Deployment** | Todo cambio que pasa el pipeline va a producción **sin intervención humana**. | Sí, siempre. |

GitOps es un *mecanismo* que sirve tanto a Continuous Delivery (sync manual, con gate) como a Continuous Deployment (sync automático).

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Push vs. Pull

| Dimensión | **Push** (CI empuja: `kubectl apply`) | **Pull / GitOps** (agente tira) |
|-----------|----------------------------------------|----------------------------------|
| Ubicación de credenciales | En el runner de CI (externo, expuesto). | Dentro del cluster; nunca salen. |
| Corrección de drift | Ninguna entre deploys. | Continua (self-heal). |
| Fuente de verdad | Implícita (último apply). | Explícita (Git). |
| Auditoría de cambios | Logs de CI, dispersos. | Historial de Git, inmutable. |
| Escala multi-cluster | El runner necesita N kubeconfigs. | Cada cluster tira lo suyo; O(1) por cluster. |
| Rollback | Re-ejecutar pipeline anterior. | `git revert` + reconcile. |
| Acoplamiento CI↔CD | Fuerte (CI conoce el cluster). | Desacoplado (CI produce imágenes; CD las consume vía Git). |
| Punto débil | Token de cluster filtrado = game over. | Latencia de reconciliación; el agente es un nuevo componente crítico. |

### 2.2 Argo CD vs. Flux — los dos motores GitOps graduados (CNCF Graduated)

| Aspecto | **Argo CD** | **Flux CD (v2 / GitOps Toolkit)** |
|---------|-------------|------------------------------------|
| Modelo mental | Aplicación de primera clase (CRD `Application`) con UI. | Conjunto de controllers componibles (GitOps Toolkit). |
| CRDs núcleo | `Application`, `ApplicationSet`, `AppProject`. | `GitRepository`, `Kustomization`, `HelmRelease`, `OCIRepository`, `HelmRepository`, `Bucket`. |
| Interfaz | UI web rica + CLI (`argocd`) + API. | CLI (`flux`) + API de Kubernetes; UI externa (Weave GitOps / Capacitor). |
| Multi-tenancy | `AppProject` (restricciones de repos, destinos, recursos). | Namespaces + RBAC + `Kustomization`/`HelmRelease` con `serviceAccountName`. |
| Fan-out a N clusters/apps | `ApplicationSet` + generators. | `Kustomization` por overlay + `flux bootstrap` por cluster. |
| Helm | Renderiza Helm como plantilla (`helm template`) por defecto. | `HelmRelease` gestionado por helm-controller (releases reales de Helm). |
| Image automation | No nativo (se usa Argo CD Image Updater, aparte). | Nativo (`image-reflector-controller` + `image-automation-controller`). |
| Footprint | Mayor (api-server, repo-server, controller, redis, dex). | Menor, modular (activás solo los controllers que usás). |
| Encaja mejor cuando | Equipos que quieren visibilidad/UI y gestión centralizada de apps. | Plataformas que quieren componibilidad, GitOps "kube-native" y automatización de imágenes. |

Ambos son **CNCF Graduated**. El examen no exige preferir uno; exige entender que resuelven el mismo problema (pull + reconcile) con filosofías distintas.

### 2.3 Estrategias de despliegue (deployment strategies)

La estrategia gobierna cómo se reemplaza la versión N por la N+1. Es ortogonal a GitOps: GitOps decide *desde dónde* viene el estado; la estrategia decide *cómo* transiciona.

| Estrategia | Mecánica | Downtime | Costo (recursos) | Blast radius | Rollback |
|------------|----------|----------|------------------|--------------|----------|
| **Recreate** | Mata todo lo viejo, luego crea lo nuevo. | Sí | 1× | Total | Lento (recreate inverso). |
| **RollingUpdate** (nativo Deployment) | Reemplaza pods gradualmente (`maxSurge`/`maxUnavailable`). | No | ~1.25× | Creciente durante el roll | Roll inverso. |
| **Blue-Green** | Dos entornos completos; se conmuta el tráfico (Service selector) de golpe. | No | 2× | Total al conmutar | Instantáneo (reconmutar). |
| **Canary** | Porción pequeña del tráfico va a la versión nueva; se incrementa por pasos con análisis. | No | ~1× + canary | Acotado (% de tráfico) | Rápido (abortar el paso). |
| **A/B testing** | Enrutamiento por atributo (header, cookie, geo) a variantes. | No | ~1× + variante | Segmento definido | Cambiar regla de routing. |
| **Shadow / mirror** | El tráfico real se *duplica* a la versión nueva sin devolver su respuesta. | No | 2× tráfico procesado | Cero (usuario no ve la nueva) | Quitar el mirror. |

**Progressive delivery** (término de James Governor, RedMonk) es canary/blue-green **gobernado por métricas**: un análisis automático (latencia p99, error rate, SLO) decide si el rollout avanza o se aborta. Es la unión de deployment strategy + observabilidad + control automático, y en Kubernetes se implementa típicamente con **Argo Rollouts** o **Flagger** (Flux).

---

## 3. Manifiestos completos (sin recortar)

### 3.1 Estructura de repositorios — separación app / config

El patrón de producción separa el **repo de aplicación** (código + Dockerfile + CI que produce imágenes) del **repo de configuración** (manifiestos declarativos que el agente GitOps tira). Esto respeta el desacoplamiento CI↔CD y evita que un rebuild dispare un redeploy accidental.

```
# Repo de configuración (fleet-infra), layout Kustomize base + overlays
fleet-infra/
├── apps/
│   └── payments/
│       ├── base/
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── kustomization.yaml
│       └── overlays/
│           ├── staging/
│           │   ├── kustomization.yaml
│           │   └── replicas-patch.yaml
│           └── production/
│               ├── kustomization.yaml
│               └── replicas-patch.yaml
└── clusters/
    ├── staging/
    │   └── payments.yaml        # Application / Kustomization que apunta al overlay
    └── production/
        └── payments.yaml
```

**`apps/payments/base/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  labels:
    app.kubernetes.io/name: payments
    app.kubernetes.io/part-of: platform
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: payments
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0        # nunca por debajo del deseado durante el roll
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments
    spec:
      containers:
        - name: payments
          image: registry.example.com/payments:1.4.2   # pin por tag inmutable/dígest
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
```

**`apps/payments/base/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

**`apps/payments/overlays/production/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: payments-prod
resources:
  - ../../base
patches:
  - path: replicas-patch.yaml
    target:
      kind: Deployment
      name: payments
images:
  - name: registry.example.com/payments
    newTag: 1.4.2        # este campo lo reescribe la automatización de imágenes
```

**`apps/payments/overlays/production/replicas-patch.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
spec:
  replicas: 6
```

### 3.2 Argo CD — `Application` con sync automático y self-heal

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade delete al borrar la App
spec:
  project: platform
  source:
    repoURL: https://github.com/example/fleet-infra.git
    targetRevision: main
    path: apps/payments/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: payments-prod
  syncPolicy:
    automated:
      prune: true        # borra recursos que ya no están en Git
      selfHeal: true     # revierte drift manual en el cluster
      allowEmpty: false  # no sincronizar un manifiesto vacío (protege de borrado accidental)
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 10
```

### 3.3 Argo CD — `AppProject` (multi-tenancy / guardrails)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Team Platform applications
  sourceRepos:
    - https://github.com/example/fleet-infra.git   # solo este repo
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'payments-*'                       # solo estos namespaces
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota      # los equipos no pueden auto-asignarse cuota
  roles:
    - name: ci-sync
      policies:
        - p, proj:platform:ci-sync, applications, sync, platform/*, allow
```

### 3.4 Argo CD — `ApplicationSet` (fan-out a N clusters)

Un solo objeto genera una `Application` por cada cluster registrado con el label `env=production`. Esto es el patrón de escala de flota.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: payments-fleet
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            env: production
  template:
    metadata:
      name: 'payments-{{.name}}'
    spec:
      project: platform
      source:
        repoURL: https://github.com/example/fleet-infra.git
        targetRevision: main
        path: apps/payments/overlays/production
      destination:
        server: '{{.server}}'
        namespace: payments-prod
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true]
```

### 3.5 Flux CD — `GitRepository` + `Kustomization`

El equivalente en Flux: una fuente (`GitRepository`) que el source-controller sondea, y una `Kustomization` que el kustomize-controller reconcilia.

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: fleet-infra
  namespace: flux-system
spec:
  interval: 1m                # frecuencia de pull del repo
  url: https://github.com/example/fleet-infra.git
  ref:
    branch: main
  secretRef:
    name: flux-git-auth       # credenciales de solo lectura al repo
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments-prod
  namespace: flux-system
spec:
  interval: 10m               # frecuencia de reconciliación del estado deseado
  retryInterval: 2m
  timeout: 3m
  sourceRef:
    kind: GitRepository
    name: fleet-infra
  path: ./apps/payments/overlays/production
  prune: true                 # equivalente al prune de Argo CD
  wait: true                  # espera health de los recursos aplicados
  targetNamespace: payments-prod
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: payments
      namespace: payments-prod
```

### 3.6 Flux CD — `HelmRelease` + automatización de imágenes

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 1h
  url: https://stefanprodan.github.io/podinfo
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
  namespace: podinfo
spec:
  interval: 10m
  chart:
    spec:
      chart: podinfo
      version: '6.x'
      sourceRef:
        kind: HelmRepository
        name: podinfo
        namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true   # rollback automático si el upgrade falla
  values:
    replicaCount: 3
```

Automatización de imágenes nativa de Flux — reescribe el tag en Git cuando aparece una imagen nueva que cumple la policy:

```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: payments
  namespace: flux-system
spec:
  image: registry.example.com/payments
  interval: 5m
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: payments
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: payments
  policy:
    semver:
      range: '>=1.4.0 <2.0.0'    # solo minor/patch, nunca un major automático
---
apiVersion: image.toolkit.fluxcd.io/v1beta1
kind: ImageUpdateAutomation
metadata:
  name: payments
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: fleet-infra
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: fluxcdbot
        email: fluxcdbot@example.com
      messageTemplate: 'chore(payments): bump image to {{range .Updated.Images}}{{println .}}{{end}}'
    push:
      branch: main
  update:
    path: ./apps/payments/overlays/production
    strategy: Setters          # marcadores # {"$imagepolicy": "..."} en el YAML
```

### 3.7 Progressive delivery — Argo Rollouts canary con análisis automático

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments
  namespace: payments-prod
spec:
  replicas: 6
  selector:
    matchLabels:
      app.kubernetes.io/name: payments
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments
    spec:
      containers:
        - name: payments
          image: registry.example.com/payments:1.5.0
          ports: [{ containerPort: 8080, name: http }]
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
  strategy:
    canary:
      canaryService: payments-canary
      stableService: payments-stable
      trafficRouting:
        nginx:
          stableIngress: payments
      steps:
        - setWeight: 10
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: success-rate
        - setWeight: 30
        - pause: { duration: 5m }
        - setWeight: 60
        - pause: { duration: 5m }
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: payments-prod
spec:
  metrics:
    - name: success-rate
      interval: 1m
      count: 5
      successCondition: result[0] >= 0.99      # aborta si error rate > 1%
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{app="payments",code!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{app="payments"}[2m]))
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Bootstrap y verificación de Flux

```console
$ flux bootstrap github \
    --owner=example \
    --repository=fleet-infra \
    --branch=main \
    --path=clusters/production \
    --personal
► connecting to github.com
► cloning branch "main" from Git repository "https://github.com/example/fleet-infra.git"
✔ cloned repository
► generating component manifests
✔ generated component manifests
✔ committed component manifests to "main" ("a1b2c3d")
► installing components in "flux-system" namespace
✔ installed components
✔ reconciled components
► confirming components are healthy
✔ helm-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ all components are healthy
```

```console
$ flux get kustomizations
NAME            REVISION            SUSPENDED  READY  MESSAGE
flux-system     main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d
payments-prod   main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d

$ flux get sources git
NAME          REVISION            SUSPENDED  READY  MESSAGE
fleet-infra   main@sha1:a1b2c3d   False      True   stored artifact for revision 'main@sha1:a1b2c3d'
```

### 4.2 Estado de una `Application` de Argo CD

```console
$ argocd app get payments-prod
Name:               argocd/payments-prod
Project:            platform
Server:             https://kubernetes.default.svc
Namespace:          payments-prod
URL:                https://argocd.example.com/applications/payments-prod
Source:
- Repo:             https://github.com/example/fleet-infra.git
  Target:           main
  Path:             apps/payments/overlays/production
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE      NAME      STATUS  HEALTH   HOOK  MESSAGE
       Namespace   payments-prod  payments  Synced                namespace/payments-prod created
       Service     payments-prod  payments  Synced  Healthy        service/payments created
apps   Deployment  payments-prod  payments  Synced  Healthy        deployment.apps/payments configured
```

### 4.3 Demostración de reconciliación: self-heal contra drift manual

```console
# Un operador "arregla" algo a mano — drift deliberado
$ kubectl -n payments-prod scale deployment/payments --replicas=1
deployment.apps/payments scaled

# Argo CD lo detecta y, con selfHeal=true, lo revierte solo
$ argocd app get payments-prod --refresh
Sync Status:  OutOfSync from main (a1b2c3d)

GROUP  KIND        NAMESPACE      NAME      STATUS     HEALTH   MESSAGE
apps   Deployment  payments-prod  payments  OutOfSync  Healthy  replicas 1 -> 6

# ...segundos después, tras la reconciliación automática:
$ kubectl -n payments-prod get deploy payments
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
payments   6/6     6            6           42h
```

El drift manual desaparece: el estado real converge de nuevo al estado en Git. **Esto es el principio 4 (Continuously Reconciled) en acción.**

### 4.4 Rollback vía Git (el "botón" de GitOps)

```console
# El deploy de 1.5.0 degradó la latencia. Rollback = revertir el commit.
$ git revert --no-edit a1b2c3d
[main e4f5g6h] Revert "chore(payments): bump image to 1.5.0"

$ git push origin main
To github.com:example/fleet-infra.git
   a1b2c3d..e4f5g6h  main -> main

# El agente tira el revert y reconcilia hacia 1.4.2 automáticamente.
$ argocd app wait payments-prod --sync --health
INFO[0004] Application 'payments-prod' has been synced to e4f5g6h
INFO[0012] Application 'payments-prod' is Healthy
```

### 4.5 Progressive delivery: seguimiento de un canary

```console
$ kubectl argo rollouts get rollout payments -n payments-prod --watch
Name:            payments
Namespace:       payments-prod
Status:          ॥ Paused
Message:         CanaryPauseStep (step 2/8)
Strategy:        Canary
  Step:          2/8
  SetWeight:     10
  ActualWeight:  10
Images:          registry.example.com/payments:1.4.2 (stable)
                 registry.example.com/payments:1.5.0 (canary)
Replicas:
  Desired:       6
  Current:       7
  Updated:       1
  Ready:         7
  Available:     7

NAME                                  KIND        STATUS     AGE  INFO
⟳ payments                            Rollout     ॥ Paused   2h
├──# revision:2
│  └──⧉ payments-6b9d7c (canary)      ReplicaSet  ✔ Healthy  3m   canary
│     └──□ payments-6b9d7c-abc12      Pod         ✔ Running  3m   ready:1/1
└──# revision:1
   └──⧉ payments-5f7c88 (stable)      ReplicaSet  ✔ Healthy  2h   stable
```

Cuando el `AnalysisRun` de la métrica `success-rate` falla, el rollout se **aborta y revierte al stable** sin intervención:

```console
$ kubectl argo rollouts get rollout payments -n payments-prod
Status:   ✖ Degraded
Message:  RolloutAborted: metric "success-rate" assessed Failed due to failed (1) > failureLimit (0)
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Estados clave y cómo leerlos

En cualquier motor GitOps, dos ejes ortogonales describen una app:

- **Sync status** — ¿el estado real coincide con Git? (`Synced` / `OutOfSync`). Es una comparación *estructural*.
- **Health status** — ¿los recursos funcionan? (`Healthy` / `Progressing` / `Degraded` / `Missing`). Es un juicio *funcional* (readiness, replicas disponibles, etc.).

La combinación diagnostica el problema:

| Sync | Health | Interpretación | Acción |
|------|--------|----------------|--------|
| Synced | Healthy | Estado nominal. | Ninguna. |
| OutOfSync | Healthy | Hay un cambio en Git aún no aplicado, o drift con selfHeal off. | `argocd app sync` / esperar reconcile. |
| Synced | Progressing | Se aplicó; los pods aún arrancan. | Esperar; vigilar readiness probes. |
| Synced | Degraded | Git aplicado pero la app no levanta (crashloop, probe falla). | Depurar el workload, no GitOps. |
| OutOfSync | Missing | Recurso definido en Git ausente en cluster. | Ver errores de sync/hooks. |

### 5.2 Diagnóstico en Argo CD

```console
# Ver el diff exacto entre Git y el cluster (la causa raíz de OutOfSync)
$ argocd app diff payments-prod
===== apps/Deployment payments-prod/payments ======
10c10
<   replicas: 6        # deseado (Git)
---
>   replicas: 1        # vivo (cluster)

# Historial de sync para rollback dirigido
$ argocd app history payments-prod
ID  DATE                           REVISION
3   2026-08-07 09:14:02 -0300      main (e4f5g6h)
2   2026-08-07 08:55:41 -0300      main (a1b2c3d)

# Rollback a una revisión concreta (rompe temporalmente el auto-sync)
$ argocd app rollback payments-prod 2

# Errores de sync detallados
$ argocd app get payments-prod -o json | jq '.status.operationState.message'
"one or more objects failed to apply, reason: admission webhook denied the request"
```

**Fallas frecuentes y su firma:**

| Síntoma | Causa raíz probable | Verificación |
|---------|---------------------|--------------|
| `OutOfSync` que no se resuelve solo | `selfHeal:false`, o campo mutado por otro controller (server-side apply conflict). | `argocd app diff`; buscar owner del campo. |
| `ComparisonError: rpc error ... repository not accessible` | Credenciales de repo mal / repo privado sin secret. | `argocd repo list`; revisar el secret. |
| App oscila `Synced`↔`OutOfSync` | Un webhook/operator muta el recurso tras cada apply → guerra de reconciliación. | Añadir `ignoreDifferences` al campo mutado. |
| `Degraded` tras sync exitoso | Imagen inexistente / probe mal configurada / CrashLoopBackOff. | `kubectl describe pod`; `kubectl logs`. |
| Prune borró algo vital | `prune:true` + recurso removido de Git por error. | Historial de Git; `git revert`. |

### 5.3 Diagnóstico en Flux

```console
# Forzar reconciliación inmediata (no esperar el interval)
$ flux reconcile kustomization payments-prod --with-source
► annotating GitRepository fleet-infra in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:a1b2c3d
► annotating Kustomization payments-prod in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ applied revision main@sha1:a1b2c3d

# Un Kustomization que NO está Ready — leer el MESSAGE es el 80% del diagnóstico
$ flux get kustomizations
NAME            REVISION   SUSPENDED  READY  MESSAGE
payments-prod   main@..    False      False  Deployment/payments-prod/payments dry-run failed:
                                             admission webhook "validate" denied the request

# Eventos y trazas del controller
$ flux logs --kind=Kustomization --name=payments-prod --since=10m
$ kubectl -n flux-system describe kustomization payments-prod

# Suspender/reanudar (p.ej. durante un incidente para congelar el estado)
$ flux suspend kustomization payments-prod
$ flux resume  kustomization payments-prod
```

**Fallas frecuentes en Flux:**

| Síntoma | Causa | Verificación |
|---------|-------|--------------|
| `Source` never Ready | URL/branch/secret de `GitRepository` erróneos. | `flux get sources git`; `kubectl describe gitrepository`. |
| `dry-run failed` | Manifiesto inválido o rechazado por webhook. | El `MESSAGE` lo dice; validar con `kustomize build`. |
| Cambios no llegan | `Kustomization` o `GitRepository` suspendido, o `interval` largo. | `flux get ... `; `flux reconcile --with-source`. |
| `HelmRelease` en `upgrade failed` | Valores inválidos o chart incompatible. | `flux logs --kind=HelmRelease`; ver `remediation`. |
| Image automation no commitea | Falta el marcador `# {"$imagepolicy": ...}` o la policy no matchea. | `flux get image policy`; revisar el setter en el YAML. |

### 5.4 Verificación de los principios (checklist auditable)

```console
# P2 (Versioned/Immutable): ¿todo cambio pasa por Git? — no debería haber deriva no comiteada
$ argocd app get payments-prod | grep 'Sync Status'
Sync Status:  Synced to main (a1b2c3d)

# P3 (Pulled): ¿existen kubeconfigs de este cluster fuera del cluster? No debería.
#   El agente usa su ServiceAccount interno; CI no tiene credenciales de cluster.
$ kubectl -n argocd get sa argocd-application-controller

# P4 (Reconciled): comprobar que el drift se corrige (prueba activa)
$ kubectl -n payments-prod patch deploy payments --type=json \
    -p='[{"op":"replace","path":"/spec/replicas","value":1}]'
$ sleep 20 && kubectl -n payments-prod get deploy payments -o jsonpath='{.spec.replicas}'
6      # revertido → reconciliación viva
```

### 5.5 Anti-patrones que el examen y producción penalizan

- **Tag mutable (`:latest`) en el manifiesto.** Viola inmutabilidad (P2): dos reconciliaciones idénticas producen estados distintos. Usá tags semánticos inmutables o dígests (`@sha256:...`).
- **Secrets en texto plano en Git.** Git es la fuente de verdad *y* es legible: nunca commitees secrets sin cifrar. Usá **Sealed Secrets**, **SOPS**, o un **External Secrets Operator** apuntando a un vault externo.
- **Mismo repo/branch para código y config con auto-sync.** Un rebuild dispara redeploys involuntarios. Separá repos o al menos paths, y desacoplá con automatización de imágenes.
- **`prune:false` "por las dudas".** Convierte a GitOps en add-only: los recursos borrados de Git sobreviven → drift permanente. Preferí `prune:true` con `AppProject`/RBAC como red de seguridad.
- **`kubectl edit` en producción.** En un cluster GitOps es, a lo sumo, un parche efímero: la próxima reconciliación lo borra. El fix va a Git, siempre.

---

## 6. Referencias

- **OpenGitOps — Principios GitOps v1.0.0 (CNCF):** <https://opengitops.dev/>
- **OpenGitOps — Repositorio y definiciones:** <https://github.com/open-gitops/documents>
- **CNPA — Curriculum oficial (CNCF):** <https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf>
- **Argo CD — Documentación oficial:** <https://argo-cd.readthedocs.io/>
- **Argo CD — Application Specification:** <https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/>
- **Argo CD — ApplicationSet:** <https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/>
- **Argo Rollouts — Progressive Delivery:** <https://argo-rollouts.readthedocs.io/>
- **Flux CD — Documentación oficial:** <https://fluxcd.io/flux/>
- **Flux CD — GitOps Toolkit (componentes):** <https://fluxcd.io/flux/components/>
- **Flux CD — Image Update Automation:** <https://fluxcd.io/flux/guides/image-update/>
- **CNCF — GitOps Working Group (TAG App Delivery):** <https://github.com/cncf/tag-app-delivery>
- **Kubernetes — Deployments y estrategias de rollout:** <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
- **Kubernetes — Kustomize (Declarative Management):** <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/>
- **Weaveworks — "GitOps: Operations by Pull Request" (origen del término):** <https://www.weave.works/blog/gitops-operations-by-pull-request>
- **Progressive Delivery (James Governor, RedMonk):** <https://redmonk.com/jgovernor/2018/08/06/towards-progressive-delivery/>