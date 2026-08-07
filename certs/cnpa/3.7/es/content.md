# GitOps para la Gestión de Aplicaciones Multi-Entorno

> **Tema 3.7 — CNPA (2025-04-01) · Peso: 2.25**
> Perfil: SRE / Platform Architect. Objetivo: dominar la mecánica de reconciliación, las estrategias de estructura de repositorio y los patrones de promoción entre `dev → staging → prod` con Argo CD y Flux.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El síntoma: *environment drift* y *snowflake clusters*

En una plataforma sin GitOps, cada entorno converge a un estado distinto por acumulación de operaciones imperativas:

```console
$ kubectl set image deployment/checkout checkout=registry.acme.io/checkout:1.9.3 -n prod
$ kubectl patch hpa checkout -n prod --type merge -p '{"spec":{"maxReplicas":40}}'
$ kubectl edit configmap checkout-flags -n prod   # editado a mano un viernes 19:40
```

Ninguna de estas mutaciones queda registrada en un origen versionado. El cluster de `prod` deja de ser reproducible: si se pierde, no existe un artefacto que lo reconstruya idénticamente. Esto es el **configuration drift**, y su forma más peligrosa es el drift *silencioso* — `staging` y `prod` divergen en `resources`, `replicas`, feature flags y versiones de imagen, de modo que "funciona en staging" deja de predecir "funciona en prod". El problema arquitectónico central de multi-entorno es garantizar **environment parity** (paridad dev/prod, principio III de *The Twelve-Factor App*) sin sacrificar las diferencias *legítimas* entre entornos (réplicas, dominios, tamaños de recursos, endpoints de dependencias).

### 1.2 Los cuatro principios de OpenGitOps

El CNCF Sandbox project **OpenGitOps** formaliza cuatro propiedades que todo sistema GitOps debe cumplir. Son el marco conceptual sobre el que se apoya el resto del tema:

| # | Principio | Significado operativo |
|---|-----------|----------------------|
| 1 | **Declarative** | El estado deseado del sistema se expresa declarativamente (manifiestos K8s, Kustomize, Helm), no como scripts imperativos. |
| 2 | **Versioned & Immutable** | El estado deseado se almacena de forma que impone inmutabilidad, versionado y retención de historia completa (Git, con commits firmados). |
| 3 | **Pulled Automatically** | Agentes de software *extraen* (pull) el estado deseado desde el origen automáticamente. No hay `kubectl apply` desde un pipeline con credenciales al cluster (push). |
| 4 | **Continuously Reconciled** | Agentes de software observan el estado real y **reconcilian** de forma continua contra el deseado, corrigiendo drift sin intervención humana. |

Fuente: <https://opengitops.dev/> · <https://github.com/open-gitops/documents>

El principio 4 es lo que convierte a GitOps en un **control loop** (bucle de control) al estilo del reconciliation model de Kubernetes, no en un "deployment automatizado". El operador GitOps es un controlador más: `observe → diff → act → repeat`.

### 1.3 Por qué el modelo *pull* importa en multi-entorno

```
  PUSH (CI/CD clásico)                          PULL (GitOps)
  ┌──────────┐   kubectl apply  ┌────────┐      ┌──────────┐  watch/pull  ┌────────┐
  │  Pipeline│ ───────────────► │ Cluster│      │ Git Repo │ ◄─────────── │ Agente │
  │  (CI)    │  (credenciales   │  prod  │      │ (desired)│              │ in-clus│
  └──────────┘   del cluster    └────────┘      └──────────┘              │  ter   │
                 en el CI)                                                 └───┬────┘
                                                                              │ apply
                                                                          ┌───▼────┐
                                                                          │ Cluster│
                                                                          └────────┘
```

Ventajas decisivas del *pull* para una plataforma con N entornos y N clusters:

- **Superficie de credenciales mínima.** El CI nunca posee kubeconfig de `prod`. El agente vive *dentro* del cluster y solo lee Git. Un CI comprometido no da acceso al cluster.
- **Escala a N clusters sin N pipelines.** Añadir un cluster de región nueva es registrar un `Cluster` secret / `GitRepository`, no reescribir pipelines.
- **Reconciliación continua = auto-remediación.** Si alguien hace `kubectl edit` en prod, el agente lo revierte al estado de Git en el siguiente ciclo (drift correction). El *root cause* se corrige en Git o no se corrige.

---

## 2. Estrategias de estructura y comparativas técnicas

La decisión más consecuente del tema es **cómo modelar las diferencias entre entornos**. Se descompone en dos ejes ortogonales: (a) cómo se *renderiza* la variación (Kustomize vs Helm), y (b) cómo se *dispone* en el repositorio (branch vs directory vs repo).

### 2.1 Renderizado de la variación: Kustomize vs Helm

| Dimensión | **Kustomize** (overlays) | **Helm** (values por entorno) |
|-----------|--------------------------|-------------------------------|
| Modelo | *Overlay* sobre una `base` con `patches` estratégicos/JSON6902 | *Templating* Go con `values-<env>.yaml` |
| Legibilidad del diff | El overlay ES el diff entre entornos (explícito y pequeño) | El diff está disperso en `values` + lógica de templates |
| DRY vs explícito | Muy DRY; riesgo de "patch a distancia" | Reutilización por charts; riesgo de templates ilegibles |
| Validación | `kubectl kustomize` produce YAML puro validable | `helm template` + posible lógica condicional oculta |
| Secretos | `secretGenerator` (+ SOPS/KSOPS) | subcharts / plugins / external-secrets |
| Native en agentes | Argo CD y Flux lo soportan nativo | Argo CD (helm), Flux `HelmRelease` |
| Cuándo elegirlo | Variación *estructural* pequeña entre entornos, misma app | Empaquetado redistribuible, muchos parámetros, ecosistema de charts |

**Regla práctica de plataforma:** Kustomize para *tu* aplicación entre entornos (la variación es un overlay pequeño y auditable); Helm para software de terceros (ingress-nginx, cert-manager, prometheus-stack) donde consumís un chart parametrizado.

### 2.2 Disposición en el repositorio

| Estrategia | Descripción | Ventajas | Desventajas / riesgos |
|-----------|-------------|----------|----------------------|
| **Branch-per-environment** | Rama `dev`, `staging`, `prod`; promover = merge entre ramas | Promoción visible como PR entre ramas | **Antipatrón para config.** Merges arrastran cambios de infra no deseados; divergencia de ramas; conflictos; difícil ver "qué difiere entre entornos". Argo CD y Flux **desaconsejan** este modelo. |
| **Directory/overlay-per-environment** | Una rama `main`; carpetas `overlays/dev`, `overlays/staging`, `overlays/prod` | Toda la verdad en `main`; diff entre entornos = diff entre carpetas; promoción = bump de tag en un archivo | Requiere disciplina de overlays; el "estado renderizado" no es visible sin `kustomize build` |
| **Repo-per-environment** | Un repositorio por entorno/cluster | Aislamiento de RBAC y blast-radius fuerte | Duplicación; sincronizar bases común es tedioso |
| **Rendered Manifests pattern** | CI renderiza (`kustomize build`) y comitea el YAML *plano* a un branch/dir por entorno; el agente aplica manifiestos ya renderizados | El diff de un PR muestra el YAML final exacto que verá el cluster; separa "source" de "deployed" | Requiere pipeline de render; dos repos (source + deploy) |

**Consenso de la industria (Argo CD/Flux docs, Codefresh, Akuity):** *directory-per-environment sobre una sola rama* es el patrón recomendado; *branch-per-environment* es un antipatrón para configuración porque los merges no respetan la frontera entre "diferencia de entorno" y "cambio de aplicación". El *rendered manifests pattern* es la evolución para organizaciones que quieren revisar el YAML final en cada PR.

### 2.3 Argo CD vs Flux

| Dimensión | **Argo CD** | **Flux** |
|-----------|-------------|----------|
| Modelo | *Application-centric*, CRD `Application`/`ApplicationSet` | *Toolkit* de controllers (source, kustomize, helm, notification, image) |
| UI | Web UI rica, diff visual, topología | Sin UI oficial (Weave GitOps / Capacitor de terceros) |
| Multi-entorno a escala | `ApplicationSet` con generators (git, cluster, matrix, list) | `Kustomization` por entorno + `dependsOn`; `GitRepository` compartido |
| Multi-tenant | `AppProject` (RBAC, allow/deny de recursos y repos) | Namespaces + RBAC + `Kustomization` con `serviceAccountName` |
| Sync/orden | *Sync waves* + *resource hooks* (PreSync/Sync/PostSync) | `dependsOn` entre `Kustomization`s + health checks |
| Drift | `selfHeal` opcional; detección continua | Reconciliación continua con `prune` e `interval` |
| Image automation | Argo CD Image Updater (add-on) | Image reflector + Image automation controllers (nativo) |
| Filosofía | "Panel de control" declarativo con visibilidad | "Unix-y", componible, GitOps de infra + apps homogéneo |

Ambos son proyectos **CNCF Graduated**. La elección típica: **Argo CD** cuando el valor está en la UI/diff visual y el modelo `AppProject` de multi-tenant; **Flux** cuando querés un toolkit componible, automation de imágenes nativa y homogeneidad entre infra y apps.

---

## 3. Manifiestos completos (sin recortar)

### 3.1 Base Kustomize + overlays por entorno

Estructura de directorios del *source repo* (single branch `main`, directory-per-environment):

```
apps/checkout/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── replicas-patch.yaml
    ├── staging/
    │   ├── kustomization.yaml
    │   └── replicas-patch.yaml
    └── prod/
        ├── kustomization.yaml
        ├── replicas-patch.yaml
        └── resources-patch.yaml
```

**`base/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml
commonLabels:
  app.kubernetes.io/name: checkout
  app.kubernetes.io/part-of: storefront
images:
  - name: checkout
    newName: registry.acme.io/checkout
    newTag: 1.9.0   # tag por defecto; los overlays lo sobreescriben por entorno
```

**`base/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
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
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: checkout
          image: checkout   # sustituido por images: del kustomization
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: LOG_LEVEL
              value: "info"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

**`base/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout
spec:
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
```

**`base/hpa.yaml`**

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
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

**`overlays/prod/kustomization.yaml`** — la variación *legítima* de prod, explícita y auditable:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - ../../base
nameSuffix: "-prod"
commonLabels:
  environment: prod
images:
  - name: registry.acme.io/checkout
    newTag: 1.9.0   # ← única línea que promueve una versión a prod
patches:
  - path: replicas-patch.yaml
    target:
      kind: Deployment
      name: checkout
  - path: resources-patch.yaml
    target:
      kind: Deployment
      name: checkout
configMapGenerator:
  - name: checkout-flags
    literals:
      - LOG_LEVEL=warn
      - FEATURE_NEW_PRICING=false
```

**`overlays/prod/replicas-patch.yaml`** (strategic merge patch):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 6
```

**`overlays/prod/resources-patch.yaml`**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
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

Validación local antes de comitear (el YAML plano que verá el cluster):

```console
$ kubectl kustomize apps/checkout/overlays/prod | head -n 20
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/part-of: storefront
    environment: prod
  name: checkout-flags-prod-8t2gm6c4hf
  namespace: prod
data:
  FEATURE_NEW_PRICING: "false"
  LOG_LEVEL: warn
---
apiVersion: v1
kind: Service
metadata:
  ...
```

### 3.2 Argo CD: `AppProject` + `ApplicationSet` con git generator + matrix

El `AppProject` define el *tenant* y las barreras de seguridad (qué repos, qué destinos, qué recursos):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: storefront
  namespace: argocd
spec:
  description: Storefront team apps across all environments
  sourceRepos:
    - https://github.com/acme/storefront-config.git
  destinations:
    - namespace: dev
      server: https://kubernetes.default.svc
    - namespace: staging
      server: https://kubernetes.default.svc
    - namespace: prod
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  roles:
    - name: prod-syncer
      description: Only senior SREs may sync prod
      policies:
        - p, proj:storefront:prod-syncer, applications, sync, storefront/checkout-prod, allow
      groups:
        - acme:sre-oncall
```

Un **único** `ApplicationSet` genera una `Application` por entorno recorriendo los directorios de `overlays/`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: checkout
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/acme/storefront-config.git
        revision: main
        directories:
          - path: apps/checkout/overlays/*
  template:
    metadata:
      name: 'checkout-{{.path.basename}}'   # checkout-dev, checkout-staging, checkout-prod
      labels:
        environment: '{{.path.basename}}'
    spec:
      project: storefront
      source:
        repoURL: https://github.com/acme/storefront-config.git
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ApplyOutOfSyncOnly=true
        retry:
          limit: 5
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 3m
  # prod requiere aprobación manual: se desactiva selfHeal/automated vía overlay o
  # con un segundo ApplicationSet; aquí, control por AppProject role + branch protection.
```

Variante **matrix generator** — combina *entornos* × *clusters* (multi-cluster, multi-región):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: checkout-multicluster
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - git:
              repoURL: https://github.com/acme/storefront-config.git
              revision: main
              directories:
                - path: apps/checkout/overlays/*
          - clusters:
              selector:
                matchLabels:
                  gitops.acme.io/enabled: "true"
  template:
    metadata:
      name: 'checkout-{{.path.basename}}-{{.name}}'
    spec:
      project: storefront
      source:
        repoURL: https://github.com/acme/storefront-config.git
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: '{{.server}}'
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: ["CreateNamespace=true"]
```

### 3.3 Flux: `GitRepository` + `Kustomization` por entorno con `dependsOn`

Un único `GitRepository` como fuente compartida:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: storefront-config
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/acme/storefront-config.git
  ref:
    branch: main
  secretRef:
    name: flux-git-auth
```

Tres `Kustomization` (uno por entorno). `staging` **depende** de `dev` y `prod` de `staging`: Flux no reconcilia el siguiente hasta que el anterior está `Ready` (promoción por dependencia + health gating):

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: checkout-dev
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 1m
  timeout: 3m
  sourceRef:
    kind: GitRepository
    name: storefront-config
  path: ./apps/checkout/overlays/dev
  prune: true
  wait: true         # espera health de los recursos aplicados
  targetNamespace: dev
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: checkout-dev
      namespace: dev
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: checkout-staging
  namespace: flux-system
spec:
  interval: 5m
  dependsOn:
    - name: checkout-dev      # ← gate: no avanza si dev no está Ready
  sourceRef:
    kind: GitRepository
    name: storefront-config
  path: ./apps/checkout/overlays/staging
  prune: true
  wait: true
  targetNamespace: staging
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: checkout-prod
  namespace: flux-system
spec:
  interval: 10m
  dependsOn:
    - name: checkout-staging  # ← promoción escalonada dev → staging → prod
  sourceRef:
    kind: GitRepository
    name: storefront-config
  path: ./apps/checkout/overlays/prod
  prune: true
  wait: true
  targetNamespace: prod
```

### 3.4 Flux `HelmRelease` para software de terceros parametrizado por entorno

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: ingress-nginx
  namespace: flux-system
spec:
  interval: 1h
  url: https://kubernetes.github.io/ingress-nginx
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ingress-nginx
  namespace: prod
spec:
  interval: 10m
  chart:
    spec:
      chart: ingress-nginx
      version: "4.11.x"
      sourceRef:
        kind: HelmRepository
        name: ingress-nginx
        namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
  values:
    controller:
      replicaCount: 3              # prod: 3; dev usaría 1 en su propio HelmRelease
      resources:
        requests: { cpu: 200m, memory: 256Mi }
      metrics:
        enabled: true
```

### 3.5 Image automation nativa de Flux (promoción de imagen guiada por GitOps)

Flux escribe el nuevo tag de vuelta a Git — el commit *es* la promoción:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: checkout
  namespace: flux-system
spec:
  interval: 5m
  image: registry.acme.io/checkout
  secretRef:
    name: acme-registry-auth
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: checkout-dev
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: checkout
  policy:
    semver:
      range: ">=1.9.0 <2.0.0"   # dev acepta cualquier patch/minor de la 1.x
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: checkout-dev
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: storefront-config
  git:
    checkout:
      ref: { branch: main }
    commit:
      author:
        name: fluxbot
        email: fluxbot@acme.io
      messageTemplate: |
        chore(dev): promote checkout {{range .Changed.Changes}}{{.NewValue}}{{end}}
    push:
      branch: main
  update:
    path: ./apps/checkout/overlays/dev
    strategy: Setters
```

En el overlay de `dev`, el marcador `# {"$imagepolicy": ...}` le dice a Flux dónde escribir:

```yaml
images:
  - name: registry.acme.io/checkout
    newTag: 1.9.0 # {"$imagepolicy": "flux-system:checkout-dev:tag"}
```

### 3.6 Secreto por entorno con SOPS (encriptado en Git)

Nunca se comitea un `Secret` en texto plano. Con SOPS + age, el ciphertext vive en Git y el controller lo desencripta en el cluster:

```yaml
# apps/checkout/overlays/prod/db-secret.enc.yaml (fragmento — ENC[...] es ciphertext)
apiVersion: v1
kind: Secret
metadata:
  name: checkout-db
  namespace: prod
type: Opaque
stringData:
  DSN: ENC[AES256_GCM,data:9f3a...,iv:...,tag:...,type:str]
sops:
  age:
    - recipient: age1qz...prodkey
  encrypted_regex: ^(data|stringData)$
```

Se referencia el desencriptado en la `Kustomization` de Flux:

```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age-prod   # contiene la clave age SOLO del cluster prod
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Argo CD

```console
$ argocd app list -p storefront
NAME                     CLUSTER                         NAMESPACE  PROJECT     STATUS     HEALTH   SYNCPOLICY  CONDITIONS
argocd/checkout-dev      https://kubernetes.default.svc  dev        storefront  Synced     Healthy  Auto-Prune  <none>
argocd/checkout-staging  https://kubernetes.default.svc  staging    storefront  Synced     Healthy  Auto-Prune  <none>
argocd/checkout-prod     https://kubernetes.default.svc  prod       storefront  OutOfSync  Healthy  <none>      <none>
```

`prod` está `OutOfSync` (promoción pendiente de aprobación manual). Inspeccionar el diff exacto:

```console
$ argocd app diff checkout-prod
===== apps/Deployment prod/checkout-prod ======
28c28
<       image: registry.acme.io/checkout:1.8.4
---
>       image: registry.acme.io/checkout:1.9.0
```

Promover explícitamente (la acción queda auditada por el `AppProject` role `prod-syncer`):

```console
$ argocd app sync checkout-prod --prune
TIMESTAMP                  GROUP        KIND   NAMESPACE  NAME           STATUS    HEALTH        HOOK  MESSAGE
2026-08-07T14:22:31+00:00  apps         Deployment  prod  checkout-prod  OutOfSync  Progressing        
2026-08-07T14:22:33+00:00  apps         Deployment  prod  checkout-prod  Synced     Progressing        deployment.apps/checkout-prod configured
2026-08-07T14:22:51+00:00  apps         Deployment  prod  checkout-prod  Synced     Healthy            

Operation:          Sync
Sync Revision:      3f9c1a7e...
Phase:              Succeeded
Message:            successfully synced (all tasks run)
```

Estado detallado incluyendo revisión de Git aplicada:

```console
$ argocd app get checkout-prod
Name:               argocd/checkout-prod
Project:            storefront
Server:             https://kubernetes.default.svc
Namespace:          prod
URL:                https://argocd.acme.io/applications/checkout-prod
Source:
- Repo:             https://github.com/acme/storefront-config.git
  Target:           main
  Path:             apps/checkout/overlays/prod
SyncWindow:         Sync Allowed
Sync Policy:        Manual
Sync Status:        Synced to main (3f9c1a7e)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME           STATUS  HEALTH   HOOK  MESSAGE
       Service     prod       checkout-prod  Synced  Healthy
apps   Deployment  prod       checkout-prod  Synced  Healthy        deployment.apps/checkout-prod configured
       ConfigMap   prod       checkout-flags-prod-8t2gm6c4hf  Synced
```

### 4.2 Flux

```console
$ flux get kustomizations
NAME               REVISION            SUSPENDED  READY   MESSAGE
checkout-dev       main@sha1:3f9c1a7e  False      True    Applied revision: main@sha1:3f9c1a7e
checkout-staging   main@sha1:3f9c1a7e  False      True    Applied revision: main@sha1:3f9c1a7e
checkout-prod      main@sha1:1b8d4f2a  False      False   dependency 'flux-system/checkout-staging' is not ready
```

`prod` no reconcilia porque `staging` aún no está `Ready` — el gate de `dependsOn` funciona. Forzar reconciliación tras un push (en lugar de esperar el `interval`):

```console
$ flux reconcile kustomization checkout-staging --with-source
► annotating GitRepository storefront-config in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:1b8d4f2a
◎ waiting for Kustomization reconciliation
✔ Kustomization reconciliation completed
✔ applied revision main@sha1:1b8d4f2a
```

Estado de las fuentes y del image automation:

```console
$ flux get sources git
NAME                REVISION            SUSPENDED  READY  MESSAGE
storefront-config   main@sha1:1b8d4f2a  False      True   stored artifact for revision 'main@sha1:1b8d4f2a'

$ flux get image policy checkout-dev
NAME          LATEST IMAGE                       READY  MESSAGE
checkout-dev  registry.acme.io/checkout:1.9.2    True   Latest image tag for 'registry.acme.io/checkout' resolved to 1.9.2
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 El significado preciso de los dos estados ortogonales

Todo diagnóstico GitOps empieza distinguiendo **Sync status** de **Health status** — son dimensiones independientes:

| | **Synced** | **OutOfSync** |
|---|---|---|
| **Healthy** | Estado deseado = real, y funciona. Objetivo. | Hay cambios en Git aún no aplicados (o drift no auto-curado). Normal antes de un sync manual. |
| **Degraded / Progressing** | Se aplicó lo de Git pero los pods fallan (imagen mala, probe roja, OOMKill). El problema está en la *app*, no en GitOps. | Cambio pendiente **y** lo desplegado está roto. Peor cuadrante. |

**Corolario operativo:** `OutOfSync` no es un fallo — es "hay una diferencia con Git". `Degraded` sí es un fallo de runtime. Confundirlos es el error de diagnóstico más común.

### 5.2 Diagnóstico de drift y su corrección

```console
$ argocd app get checkout-prod --refresh
...
Sync Status:  OutOfSync from main (3f9c1a7e)
GROUP  KIND        NAMESPACE  NAME           STATUS     HEALTH   MESSAGE
apps   Deployment  prod       checkout-prod  OutOfSync  Healthy
```

¿Alguien editó el cluster a mano? El diff lo revela:

```console
$ argocd app diff checkout-prod
===== apps/Deployment prod/checkout-prod ======
19c19
<   replicas: 12          # ← estado real: alguien escaló a mano
---
>   replicas: 6           # ← estado deseado en Git
```

Con `selfHeal: true`, Argo CD revierte automáticamente. Sin él, `argocd app sync` restaura Git. **La lección arquitectónica:** el fix correcto es cambiar Git (subir el `replicas` en el overlay via PR), no reeditar el cluster — de lo contrario el drift reaparecerá en cada reconciliación.

### 5.3 Diagnóstico de reconciliación atascada (Flux)

Síntoma: un `Kustomization` queda `READY=False`. El árbol de causas:

```console
$ flux get kustomizations checkout-prod
NAME           REVISION  SUSPENDED  READY  MESSAGE
checkout-prod  <none>    False      False  Kustomization/flux-system/checkout-prod dry-run failed: ...

$ flux logs --kind Kustomization --name checkout-prod --level error
2026-08-07T14:31:02.114Z error Kustomization/checkout-prod - reconciliation failed:
  Deployment/prod/checkout-prod dry-run failed: admission webhook "validate.kyverno.svc"
  denied the request: resource limits are required
```

Checklist de causas frecuentes de `READY=False`:

1. **Fuente no lista** → `flux get sources git`; si `READY=False`, es auth de Git o el branch/tag no existe.
2. **`dependsOn` no satisfecho** → el mensaje lo dice explícitamente; revisar el health del padre.
3. **Falla de build de Kustomize** → `kubectl kustomize ./overlays/prod` localmente reproduce el error de sintaxis/patch.
4. **Rechazo de admission (webhook/policy)** → el dry-run falla; corregir el manifiesto (p. ej. añadir `resources.limits`).
5. **Timeout de health check** (`wait: true`) → el Deployment nunca alcanza `Available`; investigar los pods:

```console
$ kubectl -n prod get deploy checkout-prod
NAME            READY   UP-TO-DATE   AVAILABLE   AGE
checkout-prod   0/6     6            0           4m

$ kubectl -n prod get pods -l app.kubernetes.io/name=checkout
NAME                             READY   STATUS             RESTARTS   AGE
checkout-prod-7c9d8f6b5-2xk4p    0/1     ImagePullBackOff   0          4m

$ kubectl -n prod describe pod checkout-prod-7c9d8f6b5-2xk4p | tail -4
  Warning  Failed  4m (x5)  kubelet  Failed to pull image "registry.acme.io/checkout:1.9.0":
           rpc error: code = NotFound desc = manifest for ...:1.9.0 not found
```

Diagnóstico: se promovió a Git un tag que no existe en el registry — GitOps aplicó fielmente un estado deseado inválido. **GitOps garantiza convergencia al estado de Git, no que ese estado sea correcto.** El fix es en Git (tag válido), reforzado por un check de CI que verifique existencia del tag antes del merge.

### 5.4 Verificación de `ApplicationSet` (que generó lo esperado)

```console
$ kubectl -n argocd get applicationset checkout -o jsonpath='{.status.conditions[?(@.type=="ResourcesUpToDate")].message}'
Successfully generated parameters for all Applications

$ kubectl -n argocd get applications -l argocd.argoproj.io/application-set-name=checkout
NAME                SYNC STATUS   HEALTH STATUS
checkout-dev        Synced        Healthy
checkout-staging    Synced        Healthy
checkout-prod       OutOfSync     Healthy
```

Si faltara un entorno, el generator git no encontró el directorio: verificar el glob `overlays/*` y que el overlay tenga un `kustomization.yaml` válido en `main`.

### 5.5 Diagnóstico de orden con Argo CD sync waves

Cuando recursos deben aplicarse en orden (CRD antes que su CR; migración de DB antes que el deploy), se usan waves y hooks. Verificar el orden real de ejecución:

```console
$ argocd app get checkout-prod --show-operation
GROUP  KIND        NAMESPACE  NAME                 STATUS     HOOK      WAVE
       Job         prod       db-migrate-1b8d4f2a  Succeeded  PreSync   
apps   Deployment  prod       checkout-prod        Synced     Sync      1
```

Anotaciones relevantes en el manifiesto:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"           # orden dentro de una fase
    argocd.argoproj.io/hook: PreSync            # PreSync | Sync | PostSync | SyncFail
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

Si un `PreSync` hook (migración) falla, el sync se detiene *antes* de tocar el Deployment — la app vieja sigue sirviendo con el esquema viejo. Ese es el comportamiento correcto: fallar la promoción sin dejar la app en estado inconsistente.

---

## 6. Referencias

- **OpenGitOps — Principles v1.0.0 (CNCF):** <https://opengitops.dev/> · <https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md>
- **Argo CD — Application & ApplicationSet:** <https://argo-cd.readthedocs.io/en/stable/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/>
- **Argo CD — ApplicationSet Generators (Git, Cluster, Matrix, List):** <https://argocd-applicationset.readthedocs.io/en/stable/Generators/>
- **Argo CD — Sync Waves and Resource Hooks:** <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/>
- **Argo CD — Projects (AppProject) & RBAC:** <https://argo-cd.readthedocs.io/en/stable/user-guide/projects/> · <https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/>
- **Flux — Documentation & GitOps Toolkit:** <https://fluxcd.io/flux/> · <https://fluxcd.io/flux/components/>
- **Flux — Kustomization API (`dependsOn`, health checks, SOPS):** <https://fluxcd.io/flux/components/kustomize/kustomizations/>
- **Flux — HelmRelease API:** <https://fluxcd.io/flux/components/helm/helmreleases/>
- **Flux — Image Automation (reflector + automation controllers):** <https://fluxcd.io/flux/guides/image-update/> · <https://fluxcd.io/flux/components/image/>
- **Flux — Mozilla SOPS integration:** <https://fluxcd.io/flux/guides/mozilla-sops/>
- **Kustomize — Reference y patrón base/overlays:** <https://kubectl.docs.kubernetes.io/references/kustomize/> · <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/>
- **Helm — Documentation:** <https://helm.sh/docs/>
- **The Twelve-Factor App — X. Dev/prod parity:** <https://12factor.net/dev-prod-parity>
- **Argo CD Best Practices (single-branch, directory-per-environment; antipatrón branch-per-env):** <https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/>
- **CNCF — Argo & Flux (Graduated projects):** <https://www.cncf.io/projects/argo/> · <https://www.cncf.io/projects/flux/>
- **CNPA Curriculum (CNCF):** <https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf>