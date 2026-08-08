# Tema 4.1 — Implementing GitOps Workflows for Application and Infrastructure Deployment

> **Peso en el examen: 8.33** · Perfil: SRE / Platform Architect · Nivel: producción

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El problema real: la deriva entre lo que creés que corre y lo que corre

En una plataforma con decenas de clusters y cientos de servicios, el modo de despliegue *imperativo* (`kubectl apply` desde una pipeline, `helm upgrade` desde un runner, un `terraform apply` que alguien corrió desde su laptop) genera un problema estructural que no se resuelve con más disciplina: **no existe una fuente de verdad reconciliable**.

Los síntomas en producción son concretos y medibles:

- **Configuration drift**: alguien hizo `kubectl edit deployment` a las 3 AM durante un incidente, nadie lo revirtió, y ahora el estado vivo del cluster diverge de lo que el equipo *cree* que está desplegado. La siguiente pipeline lo pisa o lo respeta de forma no determinista.
- **Snowflake clusters**: tres clusters que "deberían" ser idénticos acumulan diferencias no rastreables. La reproducción de un bug de prod en staging falla porque staging *no es* prod.
- **Pérdida de auditoría**: la pregunta "¿quién cambió esto, cuándo y por qué?" no tiene respuesta si el cambio entró por `kubectl` o por un pipeline sin trazabilidad de commit.
- **Recovery no determinista**: ante la pérdida total de un cluster, no hay un botón que reconstruya el estado. Hay una arqueología de scripts, tickets y memoria institucional.
- **Acoplamiento CI↔CD peligroso**: el runner de CI tiene credenciales de admin al cluster de producción. Un compromiso de la supply chain de CI es un compromiso del cluster.

### 1.2 El giro conceptual de GitOps

GitOps invierte el modelo de control. En lugar de que un actor externo *empuje* (`push`) cambios al cluster, un **agente que corre dentro del cluster** *tira* (`pull`) del estado deseado desde un repositorio Git y ejecuta un **reconciliation loop** continuo que converge el estado vivo al estado declarado.

Los cuatro principios de OpenGitOps (CNCF App Delivery TAG) que el examen espera que sepas *por nombre*:

1. **Declarative** — el sistema completo se expresa de forma declarativa (el *qué*, no el *cómo*).
2. **Versioned and Immutable** — el estado deseado se almacena versionado e inmutable; Git es el canonical source of truth.
3. **Pulled Automatically** — agentes de software tiran automáticamente el estado deseado desde la fuente.
4. **Continuously Reconciled** — agentes observan continuamente el estado real y aplican acciones para converger al deseado.

> Fuente: https://opengitops.dev/ · https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md

### 1.3 Por qué esto es un cambio arquitectónico y no una herramienta

El reconciliation loop es un **control loop** en el sentido de teoría de control, idéntico en espíritu al `kube-controller-manager`: `observe → diff → act`, sin terminar nunca. Las propiedades emergentes que esto habilita:

- **Self-healing**: si un operador borra un `Deployment` a mano, el agente lo detecta como drift y lo recrea. El cluster *resiste* la mutación no declarada.
- **Disaster recovery como propiedad, no como runbook**: reconstruir un cluster es apuntar un agente nuevo al mismo repo. El estado converge.
- **Least privilege sobre CI**: CI ya no necesita credenciales al cluster. CI construye artefactos y hace commit a Git; el agente *dentro* del cluster es el único con permisos de despliegue. La superficie de ataque se reduce drásticamente.
- **Auditoría gratis**: `git log` es el audit trail. Cada cambio es un commit firmado, revisado por PR, con autor y timestamp.

Este tema abarca **aplicaciones e infraestructura**. El punto no trivial de nivel Platform Architect: extender el mismo control loop declarativo a la infraestructura (clusters, VPCs, buckets, bases de datos) vía **Crossplane** o **Terraform Controller / Flux Terraform provider**, cerrando el gap entre "GitOps para apps" y "ClickOps / Terraform imperativo para infra".

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Push-based vs Pull-based delivery

| Dimensión | Push (CI hace `kubectl apply`) | Pull (agente reconcilia) |
|---|---|---|
| Ubicación de credenciales | Runner de CI (fuera del cluster) | Agente dentro del cluster |
| Superficie de ataque | Alta: CI = admin de prod | Baja: CI no toca el cluster |
| Drift detection | Ninguna nativa | Continua |
| Self-healing | No | Sí |
| Multi-cluster a escala | Complejo (N sets de creds en CI) | Natural (hub-and-spoke o agent-per-cluster) |
| Firewall/red | CI necesita ingress al API server | Agente hace egress al Git/registry |
| Auditoría del despliegue | En logs de CI (efímeros) | En `git log` (permanente) |
| Feedback de fallo | Inmediato en la pipeline | Asíncrono (hay que observar el estado) |

El trade-off honesto: **push da feedback síncrono e inmediato**; pull da **seguridad, drift-correction y auditoría** a costa de un feedback asíncrono que exige observabilidad del reconciler.

### 2.2 Argo CD vs Flux CD

Ambos son proyectos **CNCF Graduated**. El examen no te pide "cuál es mejor", te pide entender los modelos.

| Dimensión | Argo CD | Flux CD |
|---|---|---|
| Modelo | Application controller centralizado + UI/API | Conjunto de controllers (GitOps Toolkit) componibles |
| CRD principal | `Application`, `ApplicationSet` | `GitRepository`+`Kustomization`+`HelmRelease`+`OCIRepository` |
| UI | Web UI de primera clase | No nativa (Weave GitOps / Capacitor de terceros) |
| Multi-tenancy | `AppProject` + RBAC propio | Namespaces + RBAC de Kubernetes + `--default-service-account` |
| Multi-cluster | Hub central registra clusters remotos | Hub central o Flux por cluster |
| Helm | Renderiza con `helm template` (no usa Tiller ni releases de Helm reales por defecto) | `HelmController` gestiona releases reales de Helm |
| Image automation | Argo CD Image Updater (proyecto aparte) | `image-reflector` + `image-automation` controllers nativos |
| Filosofía | Plataforma opinada, UI-céntrica | Toolkit Unix-like, API-céntrico, GitOps sobre sí mismo |
| Bootstrapping | `argocd app create` / app-of-apps | `flux bootstrap` (Flux se gestiona a sí mismo por GitOps) |

**Regla de decisión de arquitecto:** Argo CD si tu organización valora una UI de operaciones y un modelo de aplicación explícito con RBAC propio para muchos equipos. Flux si querés un toolkit componible, integración nativa con Helm releases y image automation, y GitOps aplicado al propio sistema de delivery.

### 2.3 Estructura del repositorio: monorepo vs polyrepo, y el patrón de tres repos

| Estrategia | Ventaja | Costo |
|---|---|---|
| **App code + manifests juntos** | Simple, un PR cambia código y deploy | Acopla ciclo de CI con el de release; ruido de commits de imagen |
| **Repo de config separado (recomendado)** | Separa "qué se construye" de "qué se despliega"; CI hace commit de la nueva tag al repo de config | Dos repos que coordinar |
| **Monorepo de config, un dir por env** | Diff visual entre envs, promoción por PR entre dirs | El blast radius de un cambio mal hecho es amplio |
| **Polyrepo (repo por equipo/tenant)** | Aislamiento fuerte de RBAC | Sprawl, difícil de auditar transversalmente |

El **patrón canónico de producción** separa:
- **Source repo**: código de la aplicación + Dockerfile (dispara CI, construye imagen, publica al registry).
- **Config/GitOps repo**: manifests declarativos (lo que el agente reconcilia).
- **Base/platform repo**: bases de Kustomize / charts compartidos.

### 2.4 Gestión del `image tag`: la promoción de entornos

| Enfoque | Cómo promueve | Trade-off |
|---|---|---|
| **Image Updater / Automation** commitea la nueva tag | CI construye, el image controller detecta la nueva tag y commitea al repo de config | Automático pero requiere policy de tags estricta (semver/regex) |
| **Overlays por entorno** (`dev/`, `staging/`, `prod/`) | PR que copia la tag de un overlay al siguiente | Promoción explícita, auditable, humana |
| **Branch por entorno** | Merge de `staging`→`prod` | Simple mental model, pero drift entre branches y merges conflictivos |
| **Render pipeline** (rendered manifests) | CI pre-renderiza y commitea YAML final por env | Máxima transparencia del diff, cero sorpresas de template |

### 2.5 Secrets en GitOps: nunca en claro en Git

| Solución | Mecanismo | Trade-off |
|---|---|---|
| **Sealed Secrets** (Bitnami) | Cifra con clave pública del controller; solo el controller del cluster descifra | Simple; secret cifrado vive en Git; atado a la clave del cluster |
| **SOPS** (+ age/KMS) | Cifra valores YAML/JSON; Flux/Argo lo descifran con la clave | Multi-backend (KMS, age, PGP); granular por valor |
| **External Secrets Operator (ESO)** | El secret vive en Vault/AWS SM/GCP SM; ESO lo sincroniza a un `Secret` de K8s | El secret nunca toca Git; requiere un backend externo |
| **Vault Agent Injector** | Inyecta secrets en el pod vía sidecar | Fuera del modelo declarativo puro |

Regla: **Git nunca contiene un secret en claro.** O está cifrado (Sealed/SOPS) o es una *referencia* a un backend externo (ESO).

### 2.6 GitOps para infraestructura: Crossplane vs Terraform-in-a-loop

| Dimensión | Crossplane | Flux + tf-controller / Terraform |
|---|---|---|
| Modelo | CRDs de Kubernetes representan recursos cloud; reconciliación continua nativa | HCL ejecutado en un loop reconciliado |
| Drift correction | Continua (es un controller) | Periódica (plan/apply en cron o por evento) |
| State | En etcd (el propio recurso es el estado) | Terraform state (backend remoto) |
| Superficie de aprendizaje | CRDs + Compositions (XRD) | HCL existente, ecosistema maduro de módulos |
| Encaje GitOps | Perfecto: son manifests que Argo/Flux reconcilian | Requiere un controller que envuelva el binario de Terraform |

---

## 3. Manifiestos completos (sin recortar)

### 3.1 Bootstrap de Flux (Flux se instala a sí mismo por GitOps)

```bash
$ flux bootstrap github \
  --owner=acme-platform \
  --repository=fleet-infra \
  --branch=main \
  --path=./clusters/prod \
  --personal=false \
  --components-extra=image-reflector-controller,image-automation-controller
```

Esto crea, en `./clusters/prod/flux-system/`, los manifests del propio Flux más un `GitRepository` y un `Kustomization` que reconcilian ese directorio: Flux **gestiona su propia actualización** por GitOps.

**`clusters/prod/flux-system/gotk-sync.yaml`** (generado por bootstrap):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  secretRef:
    name: flux-system
  url: ssh://git@github.com/acme-platform/fleet-infra
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./clusters/prod
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

### 3.2 Flux: desplegar una aplicación con `GitRepository` + `Kustomization`

**`apps/podinfo/source.yaml`**:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 5m0s
  url: https://github.com/acme-platform/podinfo-config
  ref:
    branch: main
  ignore: |
    # exclude all
    /*
    # include kustomize dir
    !/kustomize/
```

**`apps/podinfo/release.yaml`**:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 10m0s
  retryInterval: 2m0s
  timeout: 3m0s
  targetNamespace: podinfo
  sourceRef:
    kind: GitRepository
    name: podinfo
  path: "./kustomize"
  prune: true
  wait: true
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: podinfo
      namespace: podinfo
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
```

### 3.3 Flux: `HelmRepository` + `HelmRelease` (releases de Helm reales)

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 30m
  url: https://stefanprodan.github.io/podinfo
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
  namespace: podinfo
spec:
  interval: 10m
  timeout: 5m
  releaseName: podinfo
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
    cleanupOnFail: true
  rollback:
    cleanupOnFail: true
  chart:
    spec:
      chart: podinfo
      version: '6.x'
      sourceRef:
        kind: HelmRepository
        name: podinfo
        namespace: flux-system
      interval: 12h
  values:
    replicaCount: 3
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        memory: 256Mi
```

### 3.4 Argo CD: `Application` con sync policy automatizada

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/acme-platform/podinfo-config
    targetRevision: main
    path: kustomize
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated:
      prune: true          # borra recursos que ya no están en Git
      selfHeal: true       # revierte drift del cluster
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 10
```

### 3.5 Argo CD: `AppProject` — el límite de multi-tenancy

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform team applications
  sourceRepos:
    - 'https://github.com/acme-platform/*'
  destinations:
    - namespace: 'podinfo'
      server: https://kubernetes.default.svc
    - namespace: 'ingress-*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
  roles:
    - name: read-only
      description: Read-only access to platform apps
      policies:
        - p, proj:platform:read-only, applications, get, platform/*, allow
      groups:
        - acme-platform:viewers
```

### 3.6 Argo CD: `ApplicationSet` — fan-out a N clusters (patrón fleet)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: podinfo-fleet
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            environment: production
  template:
    metadata:
      name: 'podinfo-{{.name}}'
    spec:
      project: platform
      source:
        repoURL: https://github.com/acme-platform/podinfo-config
        targetRevision: main
        path: 'overlays/{{.metadata.labels.region}}'
      destination:
        server: '{{.server}}'
        namespace: podinfo
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### 3.7 App-of-Apps: un `Application` raíz que declara todos los demás

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/acme-platform/fleet-infra
    targetRevision: main
    path: apps          # cada archivo aquí es otro Application
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 3.8 Sync waves: ordenar el despliegue (CRDs antes que los CRs)

```yaml
# 1º: instala el CRD
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.acme.io
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
# ...spec omitido por brevedad estructural, pero en producción va completo...
---
# 2º: crea el recurso que usa ese CRD
apiVersion: acme.io/v1
kind: Database
metadata:
  name: orders-db
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  size: large
```

En Flux, el orden equivalente se logra con `dependsOn` entre `Kustomization`s:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-controllers
  interval: 10m
  path: ./apps/prod
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

### 3.9 Secrets: SOPS con Flux

**`.sops.yaml`** en la raíz del repo:

```yaml
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8j
```

El `Kustomization` que descifra:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age        # contiene la clave age privada
```

### 3.10 External Secrets Operator: el secret vive fuera de Git

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: podinfo
spec:
  provider:
    vault:
      server: "https://vault.acme.internal:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "podinfo"
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: podinfo-db
  namespace: podinfo
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: podinfo-db-credentials     # el Secret de K8s que se crea
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: database/podinfo
        property: password
```

### 3.11 Infraestructura por GitOps: Crossplane

```yaml
# El controller de Crossplane reconcilia esto contra AWS de forma continua
apiVersion: rds.aws.upbound.io/v1beta1
kind: Instance
metadata:
  name: orders-db-prod
spec:
  forProvider:
    region: us-east-1
    instanceClass: db.r6g.large
    engine: postgres
    engineVersion: "15.5"
    allocatedStorage: 100
    storageEncrypted: true
    multiAZ: true
    username: admin
    passwordSecretRef:
      namespace: crossplane-system
      name: rds-creds
      key: password
    skipFinalSnapshot: false
    finalSnapshotIdentifier: orders-db-prod-final
  writeConnectionSecretToRef:
    namespace: podinfo
    name: orders-db-connection
```

Este manifiesto se commitea al repo de GitOps y lo reconcilia Argo/Flux **igual que una app**. Ese es el punto arquitectónico: app e infraestructura, un solo control loop, una sola fuente de verdad.

### 3.12 Progressive delivery: canary con Flagger

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: podinfo
  namespace: podinfo
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  progressDeadlineSeconds: 60
  service:
    port: 9898
    targetPort: 9898
  analysis:
    interval: 30s
    threshold: 5          # nº de fallos antes de rollback
    maxWeight: 50
    stepWeight: 10
    metrics:
      - name: request-success-rate
        thresholdRange:
          min: 99
        interval: 1m
      - name: request-duration
        thresholdRange:
          max: 500
        interval: 1m
    webhooks:
      - name: load-test
        url: http://flagger-loadtester.test/
        timeout: 5s
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 http://podinfo-canary.podinfo:9898/"
```

Flagger promueve la nueva versión gradualmente (10% → 20% → … → 50%) solo si las métricas se mantienen dentro del threshold; ante fallo, revierte automáticamente. GitOps declara el *objetivo*; Flagger gestiona la *transición segura*.

---

## 4. Comandos CLI y salidas reales

### 4.1 Estado de un `Application` en Argo CD

```bash
$ argocd app get podinfo
Name:               argocd/podinfo
Project:            platform
Server:             https://kubernetes.default.svc
Namespace:          podinfo
URL:                https://argocd.acme.io/applications/podinfo
Source:
- Repo:             https://github.com/acme-platform/podinfo-config
  Target:           main
  Path:             kustomize
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME     STATUS  HEALTH   HOOK  MESSAGE
       Service     podinfo    podinfo  Synced  Healthy        service/podinfo created
apps   Deployment  podinfo    podinfo  Synced  Healthy        deployment.apps/podinfo created
```

### 4.2 Provocar un drift y observar el self-heal

```bash
$ kubectl -n podinfo scale deployment/podinfo --replicas=1
deployment.apps/podinfo scaled

$ argocd app get podinfo | grep 'Sync Status'
Sync Status:        OutOfSync from main (a1b2c3d)

# selfHeal: true revierte solo en segundos
$ sleep 20 && kubectl -n podinfo get deploy podinfo -o jsonpath='{.spec.replicas}'
3
```

El controller detectó que el estado vivo (1 réplica) divergía del declarado (3) y reconcilió. **Eso es self-healing en acción.**

### 4.3 Diff antes de sincronizar

```bash
$ argocd app diff podinfo
===== apps/Deployment podinfo/podinfo ======
34c34
<     replicas: 3
---
>     replicas: 1
```

### 4.4 Flux: verificar la salud del sistema completo

```bash
$ flux check
► checking prerequisites
✔ Kubernetes 1.29.4 >=1.28.0-0
► checking version in cluster
✔ distribution: flux-v2.3.0
✔ bootstrapped: true
► checking controllers
✔ helm-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ all checks passed

$ flux get kustomizations
NAME          REVISION           SUSPENDED  READY  MESSAGE
apps          main@sha1:a1b2c3d  False      True   Applied revision: main@sha1:a1b2c3d
flux-system   main@sha1:a1b2c3d  False      True   Applied revision: main@sha1:a1b2c3d
infra         main@sha1:a1b2c3d  False      True   Applied revision: main@sha1:a1b2c3d
```

### 4.5 Flux: forzar reconciliación inmediata (no esperar el `interval`)

```bash
$ flux reconcile kustomization apps --with-source
► annotating GitRepository flux-system in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:e4f5g6h
► annotating Kustomization apps in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ applied revision main@sha1:e4f5g6h
```

### 4.6 Flux: inspeccionar un `HelmRelease` que falló

```bash
$ flux get helmreleases -n podinfo
NAME     REVISION  SUSPENDED  READY  MESSAGE
podinfo  6.5.4     False      False  Helm upgrade failed: timed out waiting for the condition

$ flux logs --kind=HelmRelease --name=podinfo -n podinfo --tail=5
2026-08-07T10:14:22Z error HelmRelease/podinfo.podinfo - reconciliation failed: 
  Helm upgrade failed: timed out waiting for the condition; last deployed revision is 6.5.3
```

### 4.7 Rollback manual en Argo CD (a un commit anterior)

```bash
$ argocd app history podinfo
ID  DATE                           REVISION
0   2026-08-07 09:02:11 -0300 ART  main (9f8e7d6)
1   2026-08-07 10:14:03 -0300 ART  main (a1b2c3d)

$ argocd app rollback podinfo 0
Rollback application 'podinfo' to history ID 0
...
$ argocd app get podinfo | grep Health
Health Status:      Healthy
```

> Nota de arquitecto: el rollback *real* en GitOps puro es un `git revert` en el repo de config; el `argocd app rollback` es un mecanismo de emergencia que **crea drift respecto de Git** hasta que revertís el commit. Si `selfHeal: true`, el controller volverá a aplicar Git. Usalo consciente de eso.

### 4.8 Verificar sync waves ejecutándose en orden

```bash
$ argocd app sync root --dry-run
GROUP                    KIND              NAMESPACE  NAME          STATUS   WAVE
apiextensions.k8s.io     CustomResourceD.  ''         databases...  OutOfSync  -1
acme.io                  Database          podinfo    orders-db     OutOfSync   0
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 El árbol de diagnóstico: `Sync Status` vs `Health Status`

Son **dos dimensiones ortogonales** y confundirlas es el error de diagnóstico más común:

- **Sync Status** (`Synced` / `OutOfSync`): ¿coincide el cluster con Git? Es un diff estructural.
- **Health Status** (`Healthy` / `Progressing` / `Degraded` / `Missing`): ¿funcionan los recursos desplegados? Es una evaluación semántica (readiness probes, rollout status, etc.).

| Sync | Health | Diagnóstico |
|---|---|---|
| Synced | Healthy | Todo OK |
| Synced | Degraded | Git se aplicó pero la app no arranca → problema de la app (imagen, config, probes), no de GitOps |
| OutOfSync | Healthy | Hay drift o un commit nuevo sin aplicar → revisar sync policy / `argocd app diff` |
| OutOfSync | Progressing | Sync en curso |
| Synced | Missing | Recursos borrados fuera de banda; con `selfHeal` volverán |

### 5.2 Falla: la `Application` queda `OutOfSync` y no sincroniza sola

```bash
$ argocd app get podinfo | grep 'Sync Policy'
Sync Policy:        <none>
```

**Causa**: `syncPolicy.automated` no está configurado → despliegue manual. **Fix**: agregar el bloque `automated` o `argocd app set podinfo --sync-policy automated`.

Otras causas: existe un **sync window** que bloquea (`argocd app get` muestra `SyncWindow: Sync Denied`), o el recurso está en `Ignore Differences` por una anotación.

### 5.3 Falla: prune borró algo que no debía

Síntoma: aplicaste un cambio y desaparecieron recursos que esperabas conservar.

**Causa raíz**: `prune: true` borra *todo* lo que ya no está en el path de Git. Si movés un archivo de directorio o cambiás el `path`, esos recursos se consideran huérfanos y se eliminan.

**Diagnóstico y mitigación**:
```bash
$ argocd app get podinfo -o json | jq '.status.operationState.syncResult.resources[] | select(.status=="Pruned")'
```
Protecciones: anotación `argocd.argoproj.io/sync-options: Prune=false` en recursos críticos (PVCs, namespaces con datos); en Flux, `prune: false` a nivel `Kustomization` o `kustomize.toolkit.fluxcd.io/prune: disabled` por recurso.

### 5.4 Falla: `ComparisonError` — el repo no se puede leer o renderizar

```bash
$ argocd app get podinfo
Health Status:      Unknown
CONDITIONS:
  ComparisonError: rpc error: code = Unknown desc = Manifest generation error 
  (cached): `kustomize build .` failed exit status 1: 
  Error: accumulating resources: ... evalsymlink failure ... no such file or directory
```

**Causas típicas**: `kustomization.yaml` referencia un archivo inexistente; credenciales de repo inválidas; `targetRevision` apunta a un branch/tag que no existe.
**Diagnóstico**: reproducir localmente con `kustomize build ./kustomize` o `helm template`. Si funciona local pero no en Argo, es un problema de credenciales o de versión del renderer en el repo-server.

### 5.5 Falla: drift infinito por defaults mutados por webhooks/admission

Síntoma: la app oscila eternamente entre `Synced` y `OutOfSync`; el controller reaplica cada minuto.

**Causa**: un admission webhook (Istio sidecar injector, un defaulting controller) muta el recurso *después* de aplicarlo. Argo lo ve como drift, lo revierte, el webhook lo vuelve a mutar. Loop infinito.

**Fix**: `ignoreDifferences` sobre los campos mutados por terceros:
```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/spec/containers/0/resources
    - group: ""
      kind: Service
      jqPathExpressions:
        - '.spec.ports[] | select(.name == "istio").nodePort'
```

### 5.6 Falla: `HelmRelease` se queda en `upgrade retries exhausted`

```bash
$ flux get hr -n podinfo
NAME     REVISION  READY  MESSAGE
podinfo  6.5.4     False  upgrade retries exhausted
```

**Diagnóstico**: el `HelmController` reintentó `spec.upgrade.remediation.retries` veces y desistió. Ver el estado real con `helm history`:
```bash
$ helm history podinfo -n podinfo
REVISION  STATUS      DESCRIPTION
5         deployed    Upgrade complete
6         failed      Upgrade "podinfo" failed: timed out
```
Si `remediateLastFailure: true`, Flux hace rollback automático a la revisión 5. Para reintentar tras arreglar la causa: `flux reconcile hr podinfo -n podinfo`. Si quedó *suspendido*, `flux resume hr podinfo -n podinfo`.

### 5.7 Falla: SOPS no descifra

```bash
$ flux logs --kind=Kustomization --name=apps -n flux-system | tail -3
error: Kustomization/apps - decryption failed: 
  failed to decrypt secret.yaml: no key could decrypt the data
```

**Causa**: la clave age en el `Secret sops-age` no corresponde a la clave pública usada para cifrar, o el `.sops.yaml` no matchea el archivo.
**Verificación**: `sops --decrypt secret.yaml` local con la clave privada; comparar el `recipient` age del archivo cifrado con la clave del cluster.

### 5.8 Checklist de verificación de un despliegue GitOps sano

```bash
# 1. El agente está sano
$ flux check          # o: argocd app list

# 2. La fuente está siendo leída (último revision reciente)
$ flux get sources git

# 3. Todo reconcilia y está Ready/Synced+Healthy
$ flux get kustomizations -A
$ argocd app list -o wide

# 4. No hay drift (self-heal funcionando)
$ argocd app diff podinfo      # sin salida = sin drift

# 5. Los eventos no muestran errores recurrentes
$ kubectl -n flux-system get events --sort-by=.lastTimestamp | tail

# 6. Las notificaciones de fallo están cableadas (alerting)
$ flux get alerts -A
```

### 5.9 Métricas y observabilidad del reconciler (SLO del delivery)

Ambos controllers exportan métricas Prometheus que deberías alertar:

- **Argo CD**: `argocd_app_info{sync_status,health_status}`, `argocd_app_reconcile_bucket` (latencia de reconcile), `argocd_app_sync_total{phase}`.
- **Flux**: `gotk_reconcile_condition{kind,name,type,status}`, `gotk_reconcile_duration_seconds`, `gotk_suspend_status`.

Alertas mínimas de producción:
```promql
# Una app lleva > 15 min OutOfSync (posible drift no reconciliable)
argocd_app_info{sync_status="OutOfSync"} == 1

# Un Kustomization de Flux no está Ready
gotk_reconcile_condition{type="Ready",status="False"} == 1

# El reconcile de una app supera su SLO de latencia
histogram_quantile(0.99, rate(argocd_app_reconcile_bucket[5m])) > 30
```

---

## 6. Referencias

- OpenGitOps — Principios (CNCF App Delivery TAG): https://opengitops.dev/ · https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
- CNPE Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Argo CD — Documentación oficial: https://argo-cd.readthedocs.io/en/stable/
- Argo CD — ApplicationSet: https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/
- Argo CD — Sync Options & Waves: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
- Argo CD — App of Apps pattern: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- Flux CD — Documentación oficial: https://fluxcd.io/flux/
- Flux CD — GitOps Toolkit components: https://fluxcd.io/flux/components/
- Flux CD — Bootstrap: https://fluxcd.io/flux/installation/bootstrap/
- Flux CD — Manage secrets with SOPS: https://fluxcd.io/flux/guides/mozilla-sops/
- Flagger — Progressive delivery: https://docs.flagger.app/
- Sealed Secrets (Bitnami Labs): https://github.com/bitnami-labs/sealed-secrets
- SOPS (getsops): https://github.com/getsops/sops
- External Secrets Operator: https://external-secrets.io/latest/
- Crossplane — Documentación oficial: https://docs.crossplane.io/
- Kustomize: https://kustomize.io/
- CNCF App Delivery TAG: https://tag-app-delivery.cncf.io/