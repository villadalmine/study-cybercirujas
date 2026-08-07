# 3.6 · GitOps Basics, Controllers, and Workflows

> **Peso en el examen: 2.25** · Dominio 3 (Cloud Native Application Delivery)
> Perfil: SRE / Platform Architect · Nivel: producción

---

## 1. Motivación: el problema arquitectónico que GitOps resuelve

Antes de GitOps, el estado de un clúster de Kubernetes era el resultado acumulado de una secuencia de comandos imperativos que nadie había registrado por completo:

```console
$ kubectl apply -f deployment.yaml          # el martes
$ kubectl scale deploy/api --replicas=8     # a las 3 AM durante un incidente
$ kubectl set image deploy/api api=1.4.2    # un hotfix aplicado a mano
$ kubectl edit configmap/api-config         # "solo cambio un valor rápido"
```

Cada uno de esos comandos muta el estado vivo del clúster sin dejar rastro en ningún repositorio. El resultado es un conjunto de problemas de producción bien conocidos:

- **Configuration drift (deriva de configuración).** El estado real del clúster diverge del estado que cualquiera *cree* que está desplegado. No existe una fuente de verdad; la fuente de verdad es `etcd`, que nadie audita a mano.
- **Snowflake clusters.** Dos clústeres que "deberían" ser idénticos (staging y prod) acumulan diferencias imposibles de reproducir. Un desastre en prod no se puede reconstruir porque no hay un artefacto declarativo que describa cómo llegó a ese estado.
- **Ausencia de audit trail.** ¿Quién escaló a 8 réplicas? ¿Por qué la imagen es `1.4.2` y no `1.4.3`? Sin Git de por medio, la respuesta vive en la memoria de un SRE y en el historial de un shell.
- **Credential sprawl en CI.** En el modelo clásico *push*, el sistema de CI (Jenkins, GitLab CI, GitHub Actions) necesita **credenciales de admin del clúster** para ejecutar `kubectl apply`. Cada runner de CI es ahora un vector de ataque con acceso de escritura al plano de control de producción.
- **Rollback frágil.** Volver atrás significa recordar el estado anterior y reaplicarlo imperativamente, en vez de un `git revert`.

**GitOps** invierte el modelo: el estado deseado del sistema se declara en Git (la **Single Source of Truth, SSOT**), y un **controller que corre dentro del clúster** observa continuamente ese repositorio y **reconcilia** el estado real hacia el estado declarado. El operador humano nunca vuelve a tocar el clúster directamente: cambia el clúster cambiando Git.

```
┌─────────────┐     git push      ┌──────────────┐
│ Developer / │──────────────────▶│  Git repo    │  ← Single Source of Truth
│  Platform   │   (PR + review)   │ (manifests)  │
└─────────────┘                   └──────┬───────┘
                                         │ pull (poll / webhook)
                                         ▼
                              ┌────────────────────┐
                              │  GitOps controller │  (Argo CD / Flux)
                              │  reconciliation loop│  corre DENTRO del clúster
                              └─────────┬──────────┘
                                        │ apply / prune
                                        ▼
                              ┌────────────────────┐
                              │  Kubernetes API    │
                              │  (estado real)     │
                              └────────────────────┘
```

### 1.1 Los cuatro principios de OpenGitOps

El proyecto **OpenGitOps** de la CNCF (working group bajo el App Delivery TAG) formaliza GitOps en **cuatro principios**. Memorizarlos es directamente evaluable:

| # | Principio | Significado en producción |
|---|-----------|---------------------------|
| 1 | **Declarative** | El sistema deseado se expresa de forma **declarativa**: manifiestos que describen *qué* estado se quiere, no *cómo* llegar a él. YAML de Kubernetes, Kustomize, Helm — nunca scripts imperativos. |
| 2 | **Versioned and Immutable** | El estado deseado se almacena de forma **versionada e inmutable**, con historial completo. Git es la implementación canónica: cada commit es un snapshot inmutable con autoría y timestamp. Habilita rollback a cualquier punto (`git revert`). |
| 3 | **Pulled Automatically** | Agentes de software **traen (pull)** automáticamente el estado deseado desde la fuente. El controller vive junto al sistema gestionado; la CI no empuja al clúster. |
| 4 | **Continuously Reconciled** | Agentes de software **observan continuamente** el estado real y **reconcilian** contra el deseado. Si alguien hace `kubectl edit` a mano, el controller lo detecta (drift) y — si `selfHeal` está activo — lo revierte. |

> Fuente canónica: **https://opengitops.dev/** · La especificación v1.0.0 vive en el repo `open-gitops/documents`.

---

## 2. Controllers y el reconciliation loop

GitOps no inventa el patrón de reconciliación: lo **extiende**. Es exactamente el mismo mecanismo que gobierna a *todo* Kubernetes.

### 2.1 El control loop de Kubernetes

Un **controller** de Kubernetes es un bucle no terminante que:

1. **Observa** el estado deseado (spec de un objeto en la API).
2. **Observa** el estado real (status, y el mundo real: Pods, nodos, etc.).
3. Calcula la **diferencia** (diff / drift).
4. Ejecuta **acciones** para acercar el estado real al deseado.
5. Actualiza el `status` y vuelve a empezar.

```
        ┌──────────────────────────────────────────┐
        │              reconcile()                  │
        │                                           │
   ┌────▼─────┐     diff      ┌──────────────┐      │
   │ desired  │──────────────▶│  compute     │      │
   │ (Git /   │               │  actions     │      │
   │  spec)   │               └──────┬───────┘      │
   └──────────┘                      │              │
   ┌──────────┐                      ▼              │
   │ observed │◀──────── apply / create / delete    │
   │ (etcd /  │                                     │
   │  cluster)│                                     │
   └────┬─────┘                                     │
        └─────────────── requeue ───────────────────┘
```

Este patrón es **level-triggered**, no **edge-triggered**, y esa distinción es de examen:

| Modelo | Reacciona a… | Riesgo | Kubernetes |
|--------|--------------|--------|------------|
| **Edge-triggered** | *eventos* (el instante del cambio) | Si se pierde un evento, el sistema queda desincronizado para siempre | ❌ |
| **Level-triggered** | *estado actual* (el nivel, revisado periódicamente) | Auto-corrige: si se pierde un evento, el siguiente sync lo arregla | ✅ |

Un controller GitOps es level-triggered: aunque se caiga durante una hora, al volver compara Git contra el clúster y reconcilia. No depende de haber "visto" cada commit.

### 2.2 El controller GitOps como extensión del patrón

El **desired state** ya no vive solo en `etcd`: vive en **Git**. El controller GitOps añade un paso previo — *renderizar* el estado deseado desde el repo (git clone → Kustomize build / Helm template) — y luego ejecuta el mismo `apply` reconciliador contra la API de Kubernetes.

Los objetos que el propio controller GitOps gestiona son **Custom Resources** (`Application` en Argo CD, `Kustomization`/`HelmRelease` en Flux), que a su vez son reconciliados por *sus* controllers. Es reconciliación en capas.

### 2.3 Push vs Pull: el eje de decisión de seguridad

| Dimensión | **Push-based** (CI → clúster) | **Pull-based** (agente en clúster) |
|-----------|-------------------------------|-------------------------------------|
| Quién aplica | El pipeline de CI ejecuta `kubectl apply` | Un controller *dentro* del clúster hace pull |
| Credenciales del clúster | En manos de CI (fuera del perímetro) | Nunca salen del clúster |
| Superficie de ataque | CI runners con acceso admin a prod | Solo lectura de Git desde el clúster |
| Drift detection | No hay; solo se aplica al hacer push | Continua; detecta y corrige drift |
| Escalado multi-clúster | CI necesita N credenciales | Cada clúster tira de su repo (o hub central) |
| Firewall / red privada | CI debe alcanzar la API del clúster | El clúster solo necesita *salida* a Git |
| Ejemplos | GitHub Actions + `kubectl`, Spinnaker | **Argo CD**, **Flux** |

**GitOps ⟹ pull-based** por el principio 3. El modelo pull es lo que permite mantener clústeres en redes privadas sin exponer su API server: el clúster solo necesita conectividad *saliente* hacia el repositorio Git y el registry.

---

## 3. Comparativa técnica: Argo CD vs Flux

Los dos controllers GitOps graduados de la CNCF. Ambos son **incubating/graduated**, pull-based y level-triggered; difieren en arquitectura y ergonomía.

| Característica | **Argo CD** | **Flux** (Flux CD v2) |
|---------------|-------------|------------------------|
| Proyecto CNCF | Graduated (Argo) | Graduated |
| Arquitectura | Monolítico lógico: `application-controller`, `repo-server`, `api-server`, `redis`, `dex` | Conjunto de controllers (GitOps Toolkit): `source-controller`, `kustomize-controller`, `helm-controller`, `notification-controller`, `image-*` |
| UI web | ✅ Rica, de primera clase | ❌ (usa Weave GitOps / Capacitor de terceros) |
| CRD principal | `Application`, `ApplicationSet` | `GitRepository`+`Kustomization`, `HelmRepository`+`HelmRelease` |
| Fan-out multi-clúster / multi-tenant | `ApplicationSet` con generators | `Kustomization` referenciando `GitRepository`, patrón hub/spoke |
| Motor de rendering | Helm, Kustomize, Jsonnet, plugins | Kustomize (nativo), Helm (SDK propio) |
| Detección de drift | Diff vs live state, visible en UI | Diff vía server-side apply |
| Self-heal | `syncPolicy.automated.selfHeal: true` | Reconciliación continua (drift correction por defecto) |
| Sync ordenado | **Sync waves** + **resource hooks** | `dependsOn` entre Kustomizations + health checks |
| Image automation | Vía Argo CD Image Updater (add-on) | `image-reflector-controller` + `image-automation-controller` (nativo) |
| Modelo mental | "Aplicación desplegada" centrado en UI | "Toolkit" componible, GitOps-nativo, CLI-first |
| Bootstrap | `argocd app create` / manifests | `flux bootstrap` (se auto-instala vía Git) |

**Regla de decisión práctica:** si el equipo quiere una **UI de operación** y un modelo de "aplicación" con visibilidad de árbol de recursos, Argo CD. Si el equipo es **CLI/GitOps-purista**, quiere image automation nativa y una arquitectura de controllers componibles, Flux. En plataformas grandes es común **Argo CD para dev-facing + Flux para infra** o directamente uno de los dos de forma estandarizada.

---

## 4. Manifiestos completos

### 4.1 Argo CD — `Application`

El objeto central de Argo CD. Declara *de dónde* (source) y *hacia dónde* (destination) desplegar, y con qué política de sync.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api
  namespace: argocd          # las Applications viven en el namespace de Argo CD
  finalizers:
    - resources-finalizer.argocd.argoproj.io  # cascada: al borrar la App, prunea sus recursos
  labels:
    team: payments
spec:
  project: production          # AppProject que restringe orígenes/destinos/RBAC
  source:
    repoURL: https://github.com/acme/deploy-manifests.git
    targetRevision: main       # branch, tag o SHA; SHA = inmutable (recomendado en prod)
    path: apps/payments-api/overlays/production
    # Ejemplo con Helm (mutuamente informativo):
    # helm:
    #   releaseName: payments-api
    #   valueFiles:
    #     - values-production.yaml
    #   parameters:
    #     - name: image.tag
    #       value: "1.7.3"
  destination:
    server: https://kubernetes.default.svc   # clúster in-cluster; o URL de clúster remoto
    namespace: payments
  syncPolicy:
    automated:
      prune: true              # borra recursos que ya no están en Git
      selfHeal: true           # revierte cambios manuales (drift correction)
      allowEmpty: false        # no sincronizar hacia un set vacío (guardarraíl)
    syncOptions:
      - CreateNamespace=true    # crea el namespace destino si no existe
      - PrunePropagationPolicy=foreground
      - PruneLast=true          # prunea DESPUÉS de aplicar el resto (evita cortes)
      - ServerSideApply=true    # SSA: gestión de field ownership, evita conflictos
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  # Ignorar campos mutados por otros controllers (p.ej. HPA toca replicas):
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
  revisionHistoryLimit: 10
```

### 4.2 Argo CD — `ApplicationSet` (fan-out declarativo)

`ApplicationSet` genera *N* `Application`s desde un **generator**. Es la herramienta para desplegar la misma app en muchos clústeres, o muchas apps desde un monorepo, sin escribir cada `Application` a mano.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: payments-api-all-clusters
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    # Genera una Application por cada clúster registrado con la label env=prod
    - clusters:
        selector:
          matchLabels:
            env: prod
  template:
    metadata:
      name: 'payments-{{.name}}'         # p.ej. payments-eu-west, payments-us-east
    spec:
      project: production
      source:
        repoURL: https://github.com/acme/deploy-manifests.git
        targetRevision: main
        path: 'apps/payments-api/overlays/{{.metadata.labels.region}}'
      destination:
        server: '{{.server}}'
        namespace: payments
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Otros generators frecuentes: `git` (descubre paths o archivos en el repo), `list` (estático), `matrix` (producto cartesiano de dos generators), `pullRequest` (preview environments por PR).

### 4.3 Argo CD — sync waves y resource hooks

El **orden de aplicación** se controla con dos anotaciones. Se evalúan en tres fases: `PreSync → Sync → PostSync`.

```yaml
# 1) Sync wave: los recursos con wave menor se aplican primero.
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-migrations-config
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # se aplica antes que la wave 0 (default)
---
# 2) Resource hook: un Job de migración que corre ANTES del sync principal.
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded  # borra el Job si tuvo éxito
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: registry.acme.io/payments/migrator:1.7.3
          command: ["/bin/migrate", "up"]
```

### 4.4 Flux — `GitRepository` + `Kustomization`

En Flux, el `source-controller` mantiene el artefacto Git y el `kustomize-controller` lo aplica.

```yaml
# Fuente: qué repo, qué rama, cada cuánto se reconcilia (pull interval).
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: deploy-manifests
  namespace: flux-system
spec:
  interval: 1m                 # frecuencia de pull del repo
  url: https://github.com/acme/deploy-manifests.git
  ref:
    branch: main
  secretRef:
    name: git-credentials      # deploy key o token (Secret en flux-system)
---
# Aplicación: qué path del artefacto aplicar, con prune y health checks.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments-api
  namespace: flux-system
spec:
  interval: 5m                 # frecuencia de reconciliación (drift correction)
  retryInterval: 1m
  timeout: 3m
  sourceRef:
    kind: GitRepository
    name: deploy-manifests
  path: ./apps/payments-api/overlays/production
  prune: true                  # equivalente al prune de Argo CD
  targetNamespace: payments
  wait: true                   # espera a que los recursos estén Ready
  dependsOn:
    - name: infra-controllers  # no aplicar hasta que esta Kustomization esté Ready
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: payments-api
      namespace: payments
  postBuild:
    substitute:
      cluster_env: "production"
```

### 4.5 Flux — `HelmRepository` + `HelmRelease`

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: redis
  namespace: payments
spec:
  interval: 10m
  chart:
    spec:
      chart: redis
      version: "20.x"          # semver range; el controller resuelve la versión
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true  # rollback automático si falla el upgrade
  values:
    architecture: replication
    auth:
      existingSecret: redis-auth
```

### 4.6 Workflows — Argo Workflows (pipeline como CRD)

**Argo Workflows** es el motor de workflows *container-native* de la familia Argo. Cada paso es un contenedor; los DAG y las secuencias se declaran como CRDs. Es el sustrato típico de pipelines de CI/CD, ETL y ML corriendo *dentro* del clúster.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: build-test-deploy-
  namespace: ci
spec:
  entrypoint: pipeline
  serviceAccountName: workflow-runner
  arguments:
    parameters:
      - name: git-sha
        value: "abc1234"
  templates:
    - name: pipeline
      dag:
        tasks:
          - name: build
            template: build-image
          - name: unit-test
            template: run-tests
            dependencies: [build]
          - name: integration-test
            template: run-integration
            dependencies: [build]
          - name: promote
            template: git-promote          # actualiza el repo GitOps (¡no kubectl apply!)
            dependencies: [unit-test, integration-test]
    - name: build-image
      container:
        image: gcr.io/kaniko-project/executor:latest
        args: ["--dockerfile=Dockerfile", "--destination=registry.acme.io/app:{{workflow.parameters.git-sha}}"]
    - name: run-tests
      container:
        image: registry.acme.io/app-ci:latest
        command: ["make", "test"]
    - name: run-integration
      container:
        image: registry.acme.io/app-ci:latest
        command: ["make", "integration"]
    - name: git-promote
      container:
        image: registry.acme.io/gitops-bot:latest
        # Escribe el nuevo tag en el repo GitOps y abre un PR:
        command: ["/bin/promote", "--sha", "{{workflow.parameters.git-sha}}"]
```

> **Patrón clave (de examen):** el workflow de CI **no despliega** con `kubectl apply`. Su paso final **actualiza el repositorio Git** (bump del tag de imagen); luego el controller GitOps (Argo CD/Flux) detecta el commit y reconcilia. Así se mantiene el principio *pull* y Git como SSOT. Esto separa **CI (build/test, push-based)** de **CD (deploy, pull-based)**.

### 4.7 Progressive delivery — Argo Rollouts (canary)

Los controllers GitOps despliegan el *estado deseado*, pero la **estrategia de rollout** (canary, blue-green) la aporta un controller adicional como **Argo Rollouts** o **Flagger**.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments-api
  namespace: payments
spec:
  replicas: 8
  strategy:
    canary:
      steps:
        - setWeight: 20        # 20% del tráfico a la nueva versión
        - pause: {duration: 5m}
        - setWeight: 50
        - pause: {duration: 5m}
        - analysis:            # gate automático contra métricas (Prometheus)
            templates:
              - templateName: success-rate
        - setWeight: 100
  selector:
    matchLabels: {app: payments-api}
  template:
    metadata:
      labels: {app: payments-api}
    spec:
      containers:
        - name: api
          image: registry.acme.io/payments/api:1.7.3
          ports:
            - containerPort: 8080
```

---

## 5. Comandos CLI y salidas de terminal

### 5.1 Argo CD

```console
$ argocd app list
NAME                 CLUSTER                         NAMESPACE  PROJECT     STATUS     HEALTH   SYNCPOLICY  CONDITIONS
argocd/payments-api  https://kubernetes.default.svc  payments   production  Synced     Healthy  Auto-Prune  <none>
argocd/checkout      https://kubernetes.default.svc  checkout   production  OutOfSync  Healthy  Auto-Prune  <none>

$ argocd app get payments-api
Name:               argocd/payments-api
Project:            production
Server:             https://kubernetes.default.svc
Namespace:          payments
URL:                https://argocd.acme.io/applications/payments-api
Repo:               https://github.com/acme/deploy-manifests.git
Target:             main
Path:               apps/payments-api/overlays/production
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME          STATUS  HEALTH   HOOK  MESSAGE
       Service     payments   payments-api  Synced  Healthy        service/payments-api created
apps   Deployment  payments   payments-api  Synced  Healthy        deployment.apps/payments-api created
       ConfigMap   payments   api-config    Synced

$ argocd app diff checkout          # muestra el drift antes de sincronizar
===== apps/Deployment payments/checkout ======
2c2
<     replicas: 3
---
>     replicas: 5                    # alguien escaló a mano; Git dice 3

$ argocd app sync checkout --prune
TIMESTAMP                  GROUP        KIND   NAMESPACE  NAME      STATUS    HEALTH   HOOK  MESSAGE
2026-08-07T14:02:11+00:00  apps  Deployment  checkout  checkout   OutOfSync  Healthy
2026-08-07T14:02:13+00:00  apps  Deployment  checkout  checkout   Synced     Healthy
Operation succeeded

# Ver Applications como CRDs nativos (útil para debugging sin la UI):
$ kubectl get applications.argoproj.io -n argocd
NAME           SYNC STATUS   HEALTH STATUS
payments-api   Synced        Healthy
checkout       Synced        Healthy
```

### 5.2 Flux

```console
$ flux get sources git
NAME               REVISION           SUSPENDED  READY  MESSAGE
deploy-manifests   main@sha1:a1b2c3d  False      True   stored artifact for revision 'main@sha1:a1b2c3d'

$ flux get kustomizations
NAME             REVISION           SUSPENDED  READY  MESSAGE
infra-controllers main@sha1:a1b2c3d  False      True   Applied revision: main@sha1:a1b2c3d
payments-api      main@sha1:a1b2c3d  False      True   Applied revision: main@sha1:a1b2c3d

$ flux reconcile kustomization payments-api --with-source
► annotating GitRepository deploy-manifests in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:e4f5g6h
► annotating Kustomization payments-api in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ applied revision main@sha1:e4f5g6h

$ flux get helmreleases -n payments
NAME   REVISION  SUSPENDED  READY  MESSAGE
redis  20.1.3    False      True   Helm install succeeded for release payments/redis.v1

# Suspender la reconciliación durante una intervención manual controlada:
$ flux suspend kustomization payments-api
► suspending kustomization payments-api in flux-system namespace
✔ kustomization suspended
# ...y reanudarla:
$ flux resume kustomization payments-api
```

### 5.3 Argo Workflows

```console
$ argo submit -n ci build-test-deploy.yaml --watch
Name:                build-test-deploy-7pk2n
Namespace:           ci
Status:              Running
Created:             Fri Aug 07 14:10:02 +0000 (10 seconds ago)

STEP                          TEMPLATE       PODNAME                       DURATION
 ● build-test-deploy-7pk2n    pipeline
 ├─✔ build                    build-image    build-test-deploy-7pk2n-...   32s
 ├─◷ unit-test                run-tests      build-test-deploy-7pk2n-...   4s
 └─◷ integration-test         run-integration build-test-deploy-7pk2n-..  4s

$ argo list -n ci
NAME                       STATUS      AGE   DURATION   PRIORITY
build-test-deploy-7pk2n    Succeeded   3m    2m14s      0

$ argo logs -n ci build-test-deploy-7pk2n --follow
build-test-deploy-7pk2n-build: INFO building image registry.acme.io/app:abc1234
build-test-deploy-7pk2n-unit-test: PASS  47 tests, 0 failures
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1 El significado exacto de `Sync Status` y `Health`

Son **dos ejes ortogonales** en Argo CD y confundirlos es el error #1 de operación:

| Eje | Valores | Qué mide |
|-----|---------|----------|
| **Sync Status** | `Synced` / `OutOfSync` | ¿El estado *live* coincide con Git? |
| **Health** | `Healthy` / `Progressing` / `Degraded` / `Missing` / `Suspended` | ¿El recurso funciona? (readiness, replicas disponibles) |

Una app puede estar `Synced` pero `Degraded` (el YAML correcto se aplicó, pero los Pods crashean) — o `OutOfSync` pero `Healthy` (funciona, pero difiere de Git). El diagnóstico empieza siempre por *cuál* de los dos ejes está mal.

### 6.2 Playbook de diagnóstico

**Síntoma: `OutOfSync` persistente que reaparece tras cada sync.**
Casi siempre es un **controller que muta el recurso** (HPA cambiando `replicas`, un mutating webhook, un default injectado por el API server). El diff "de ida y vuelta" nunca cierra.

```console
$ argocd app diff payments-api
===== apps/Deployment payments/payments-api ======
<     replicas: 3          # Git
>     replicas: 7          # HPA lo escaló
```
*Fix:* declarar `ignoreDifferences` sobre `/spec/replicas` (§4.1). No pelear contra el HPA con `selfHeal`.

**Síntoma: `selfHeal` revierte un hotfix manual legítimo.**
Es el comportamiento *correcto* de GitOps: el estado real debe venir de Git. Si necesitás una intervención de emergencia, **suspendé** la reconciliación primero:

```console
# Argo CD:
$ argocd app set payments-api --sync-policy none    # desactiva automated sync
# Flux:
$ flux suspend kustomization payments-api
```
…luego aplicá el fix *en Git*, y reanudá. Nunca dejes el clúster derivando indefinidamente.

**Síntoma: sync atascado en `Progressing` para siempre.**
Un **sync wave** o un **PreSync hook** no terminó. Ej.: el `Job` de migración (§4.3) falla y bloquea la fase.

```console
$ argocd app get payments-api --show-operation
...
GROUP  KIND  NAMESPACE  NAME       STATUS   HOOK     MESSAGE
batch  Job   payments   db-migrate  Failed   PreSync  Job has reached the specified backoff limit
$ kubectl logs -n payments job/db-migrate
ERROR: could not connect to database: connection refused
```
*Fix:* corregir la causa (DB no lista → añadir `dependsOn`/wave anterior), y borrar el hook Job fallido si `hook-delete-policy` no lo cubre.

**Síntoma: Flux `Kustomization` en `Ready: False`.**
Leé el `MESSAGE` y los eventos del CR — Flux es explícito:

```console
$ flux get kustomizations
NAME          REVISION  SUSPENDED  READY  MESSAGE
payments-api  main@..   False      False  kustomize build failed: accumulating resources: ...

$ kubectl -n flux-system describe kustomization payments-api
...
Events:
  Warning  BuildFailed  kustomize build failed: resource path apps/payments-api/overlays/production/ingress.yaml: no matches for kind "Ingress" in version "networking.k8s.io/v1beta1"
```
Diagnóstico directo: una API **deprecada/removida** (`networking.k8s.io/v1beta1` → `v1`). Fix en Git y `flux reconcile`.

**Síntoma: la app quedó `Missing`/`Unknown` tras un cambio de RBAC.**
El controller GitOps perdió permisos para leer o aplicar un recurso. Verificá el `AppProject` (Argo CD) o el `ServiceAccount`/`impersonation` de la `Kustomization` (Flux).

### 6.3 Verificación de que GitOps está *funcionando* (no solo instalado)

La prueba definitiva de un loop GitOps sano es el **test de drift**: mutá el clúster a mano y verificá que el controller lo revierte.

```console
# 1) Introducir drift deliberado:
$ kubectl -n payments scale deploy/payments-api --replicas=1

# 2) Observar la detección (Argo CD, en < intervalo de reconciliación):
$ argocd app get payments-api | grep 'Sync Status'
Sync Status:  OutOfSync from main (a1b2c3d)

# 3) Con selfHeal=true, el controller revierte solo. Confirmar:
$ kubectl -n payments get deploy payments-api -o jsonpath='{.spec.replicas}{"\n"}'
3            # volvió al valor de Git

# 4) Auditar: el evento queda registrado.
$ argocd app history payments-api
ID  DATE                           REVISION
0   2026-08-07 13:40:02 +0000 UTC  main (a1b2c3d)
1   2026-08-07 14:22:11 +0000 UTC  main (a1b2c3d)   # self-heal
```

Checklist de verificación de producción:

- [ ] El repo Git es la **única** vía de cambio; el acceso `kubectl` de escritura a prod está restringido/auditado.
- [ ] `prune: true` está activo (recursos borrados de Git desaparecen del clúster).
- [ ] `selfHeal: true` (o reconciliación continua de Flux) revierte drift, y existe un procedimiento de `suspend` para emergencias.
- [ ] El pipeline de CI **no** hace `kubectl apply`; promueve escribiendo en el repo GitOps.
- [ ] `targetRevision` en prod apunta a un **SHA/tag inmutable**, no a `main`, para releases auditables.
- [ ] Health checks y sync waves ordenan dependencias (DB migrations antes que la app).

---

## Referencias

- **OpenGitOps — Principles v1.0.0 (CNCF App Delivery TAG):** https://opengitops.dev/ · https://github.com/open-gitops/documents
- **CNPA Curriculum (CNCF):** https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- **Kubernetes — Controllers (concepto de control loop):** https://kubernetes.io/docs/concepts/architecture/controller/
- **Kubernetes — Operator pattern:** https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- **Argo CD — Documentación oficial:** https://argo-cd.readthedocs.io/en/stable/
- **Argo CD — Application & Sync (Automated Sync, Prune, SelfHeal):** https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- **Argo CD — Sync Waves & Resource Hooks:** https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
- **Argo CD — ApplicationSet:** https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- **Argo Workflows — Documentación oficial:** https://argo-workflows.readthedocs.io/en/latest/
- **Argo Rollouts — Progressive Delivery:** https://argo-rollouts.readthedocs.io/en/stable/
- **Flux — Documentación oficial (GitOps Toolkit):** https://fluxcd.io/flux/
- **Flux — Kustomization API:** https://fluxcd.io/flux/components/kustomize/kustomizations/
- **Flux — HelmRelease API:** https://fluxcd.io/flux/components/helm/helmreleases/
- **Flux — Core Concepts (reconciliation, sources):** https://fluxcd.io/flux/concepts/
- **CNCF — App Delivery TAG:** https://tag-app-delivery.cncf.io/