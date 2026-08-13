# Argo CD — Entrega Continua GitOps Declarativa para Kubernetes
### Dominio CAPA 3.1 · Peso en el examen 20%

---

## 1. Motivación: el problema de producción que resuelve Argo CD

La forma predeterminada de modificar un clúster de Kubernetes es imperativa: una persona de ingeniería, un runner de CI o un script ejecuta `kubectl apply` contra un servidor de API en vivo. A la escala de un único servicio esto es invisible; a la escala de una plataforma produce cuatro fallas que se acumulan.

- **Deriva de configuración (drift).** El estado en vivo del clúster y la intención expresada en tu repositorio divergen silenciosamente. Alguien ejecuta `kubectl edit`, un Horizontal Pod Autoscaler muta un número de réplicas, un operator parchea un recurso, o se aplica un hotfix que nunca se commitea. No hay una respuesta autoritativa a "¿qué se *supone* que debería estar corriendo acá?"
- **Sin rastro de auditoría ni reproducibilidad.** El historial de cambios vive en el historial de shell de quien haya ejecutado el comando y en el efímero log de auditoría del servidor de API. Un clúster se convierte en un *snowflake* que no puede reconstruirse desde el código fuente.
- **Dispersión de credenciales (modelo push).** En un modelo push impulsado por CI, cada pipeline que despliega necesita credenciales de escritura al clúster. Esas credenciales se alojan en los almacenes de secretos de CI, tienen alcance amplio y son un objetivo primario de movimiento lateral. El radio de impacto de un runner de CI comprometido es todo el clúster.
- **Sin corrección continua.** Incluso si desplegás correctamente una vez, nada detecta ni corrige la deriva después. Recuperarse de un cambio fuera de banda depende de que una persona lo note.

**GitOps** replantea el despliegue como *reconciliación continua hacia un estado deseado declarado y almacenado en Git*. Los cuatro principios (tal como los formaliza el grupo de trabajo OpenGitOps) son:

1. **Declarativo** — el sistema completo se describe declarativamente.
2. **Versionado e inmutable** — el estado deseado se almacena de forma que quede versionado y su historial sea inmutable (Git).
3. **Extraído automáticamente (pulled)** — agentes de software *extraen* (pull) el estado deseado; al clúster nunca se le *empuja* (push) desde afuera.
4. **Reconciliado continuamente** — los agentes observan continuamente el estado en vivo y actúan para converger hacia el estado deseado.

**Argo CD es un controlador de Kubernetes que implementa los principios 3 y 4.** Corre *dentro* del clúster objetivo (o de un clúster de gestión), lee el estado deseado desde Git, lo compara con el estado en vivo, reporta la diferencia y — opcionalmente — converge el clúster automáticamente. Git se convierte en la única fuente de verdad y la única interfaz con autoridad de escritura; las personas interactúan con Git mediante pull requests, no con el clúster.

> **La inversión arquitectónica:** en push CD, el pipeline se mete *dentro* del clúster. En pull GitOps, el agente se extiende *hacia afuera* hasta Git. Las credenciales de escritura del clúster nunca lo abandonan.

---

## 2. Arquitectura y mecánica interna

Argo CD no es un monolito; es un conjunto de componentes que cooperan. Entender la división es la clave para diagnosticar fallas de producción, porque cada modo de falla se corresponde con un componente específico.

| Componente | Despliegue | Responsabilidad | ¿Con estado? |
|---|---|---|---|
| `argocd-server` (servidor de API) | Deployment | API gRPC/REST, sirve la Web UI y la CLI `argocd`, autenticación, aplicación de RBAC, gestión de credenciales de repo/clúster, integración SSO, expone eventos y logs | No (estado en K8s + Redis) |
| `argocd-repo-server` | Deployment | Clona/cachea repos de Git, **genera manifiestos** (Helm template, Kustomize build, Jsonnet, YAML plano, Config Management Plugins), devuelve los manifiestos renderizados al controlador | Caché git local (efímera) |
| `argocd-application-controller` | StatefulSet | El reconciliador: compara deseado vs. en vivo, computa el estado de sync/salud, ejecuta syncs, ejecuta resource hooks y sync waves, hace prune | No (estado en K8s + Redis) |
| `argocd-applicationset-controller` | Deployment | Genera recursos `Application` a partir de generadores (Git, Cluster, List, Matrix, PR, SCM…) | No |
| `argocd-notifications-controller` | Deployment | Evalúa triggers y despacha notificaciones (Slack, webhook, email…) | No |
| `argocd-redis` | Deployment (o StatefulSet HA) | Caché para manifiestos renderizados y estado computado de las apps; una **caché de rendimiento**, no una fuente de verdad | Caché efímera |
| `argocd-dex-server` | Deployment (opcional) | Federación OIDC para SSO con proveedores de identidad externos | No |

### 2.1 El bucle de reconciliación

El `application-controller` ejecuta un bucle de control por cada `Application`. Conceptualmente:

```
                 ┌────────────────────────────────────────────────┐
                 │              application-controller             │
   Git repo ───► │  1. ask repo-server to render desired manifests │
 (source of      │  2. list live resources from cluster API        │
   truth)        │  3. diff desired vs live  → Sync status         │
                 │  4. assess resource health → Health status      │
   Cluster  ◄─── │  5. if auto-sync & OutOfSync → apply + hooks    │
   API server    │  6. cache result in Redis, emit events          │
                 └────────────────────────────────────────────────┘
```

- **Refresh y Sync son distintos.** Un *refresh* re-renderiza los manifiestos y recomputa el diff (solo lectura). Un *sync* efectivamente aplica los cambios al clúster. `OutOfSync` significa "diff detectado"; **no** significa "Argo CD va a actuar" a menos que haya una política de sync automatizada configurada.
- **Intervalo de polling.** Por defecto el controlador reconcilia cada app aproximadamente cada **180 s** (`timeout.reconciliation` en `argocd-cm`). Esto es un *fallback*; el patrón de producción es configurar un **Git webhook** (`/api/webhook`) para que los pushes disparen refreshes casi instantáneos y puedas subir el intervalo de polling para reducir la carga sobre Git y la API.
- **El motor.** La maquinaria de diff/sync/salud es la biblioteca compartida `gitops-engine`, sobre la que se construyen Argo CD y otras herramientas.

### 2.2 Seguimiento de recursos — cómo Argo CD sabe qué le pertenece

Argo CD debe distinguir los recursos que *él* gestiona de todo lo demás en un namespace. Dos mecanismos, elegidos mediante `application.resourceTrackingMethod` en `argocd-cm`:

| Método | Marcador | Pros | Contras |
|---|---|---|---|
| `label` (legado por defecto) | `app.kubernetes.io/instance: <app-name>` | Legible por humanos, greppeable con `kubectl` | Valor truncado a 63 caracteres; colisiona con herramientas que usan la misma label bien conocida; un recurso solo puede pertenecer a una app |
| `annotation` | `argocd.argoproj.io/tracking-id` | Sin límite de longitud, sin colisión con las labels de la app, codifica group/kind/namespace/name | No es una label, así que no se puede seleccionar con `kubectl -l` |
| `annotation+label` | Ambos | La annotation es autoritativa, la label para compatibilidad con herramientas | Un poco más de metadata |

Recomendación de producción: preferir **`annotation`** en instalaciones greenfield para evitar la colisión de labels bien conocidas que silenciosamente hace que dos apps peleen por el mismo objeto.

### 2.3 El estado de sync y el estado de salud son ortogonales

Estos dos ejes son el concepto peor leído en el examen y en los incidentes.

- **El estado de sync** responde: *¿coincide lo en vivo con Git?* → `Synced` | `OutOfSync` | `Unknown`.
- **El estado de salud** responde: *¿está el recurso en vivo realmente funcionando?* → `Healthy` | `Progressing` | `Degraded` | `Suspended` | `Missing` | `Unknown`.

Una app puede estar **`Synced` y `Degraded`** (Git se aplicó fielmente, pero los pods del Deployment están en CrashLoop) o **`OutOfSync` y `Healthy`** (la app en ejecución está bien, pero alguien la editó a mano alejándola de Git). La salud la computan evaluadores integrados para los kinds base (Deployment, StatefulSet, Service, Ingress, PVC, Job, …) y **health checks en Lua personalizados** para CRDs (definidos en `argocd-cm` bajo `resource.customizations`).

---

## 3. Comparaciones técnicas (tablas de compromisos)

### 3.1 GitOps basado en pull vs. CI/CD basado en push

| Dimensión | Push CD (CI aplica) | Pull GitOps (Argo CD) |
|---|---|---|
| Credenciales del clúster | En manos de CI, alcance amplio, fuera del clúster | Quedan dentro del clúster; CI nunca toca el servidor de API |
| Detección de deriva | Ninguna | Continua, de primera clase |
| Autoreparación | Ninguna | Opcional (`selfHeal: true`) |
| Fuente de verdad | Ambigua (última ejecución del pipeline) | Commit SHA de Git |
| Fan-out multi-clúster | N pipelines, N conjuntos de credenciales | Un controlador → N clústeres registrados, o ApplicationSet |
| Rollback | Re-ejecutar el pipeline viejo (puede no ser reproducible) | `git revert` → auto-convergencia |
| Auditoría | Logs de CI + auditoría del clúster | Historial de Git (posibilidad de commits firmados) |

### 3.2 Argo CD vs. Flux CD

| Aspecto | Argo CD | Flux CD |
|---|---|---|
| UX principal | Web UI rica + CLI + CRDs | CRDs + CLI (UI vía Weave GitOps) |
| Abstracción central | CRD `Application` | CRDs `Kustomization` / `HelmRelease` |
| Templating multi-app | Generadores de `ApplicationSet` | Overlays de Kustomize, dependencias |
| Renderizado de manifiestos | Centralizado en `repo-server` (Helm/Kustomize/Jsonnet/plugins) | Controladores de source + build por tipo |
| RBAC / multi-tenancy | `AppProject` + RBAC integrado (`policy.csv`) | RBAC de Kubernetes + tenancy vía namespaces |
| Mejor encaje | Equipos que quieren un plano de control visual y fuertes barreras multi-tenant | Equipos que quieren piezas mínimas, nativas del controlador, componibles |

Ambos son CNCF Graduated. El alcance del examen es Argo CD; la comparación importa para la justificación arquitectónica.

### 3.3 Política de sync manual vs. automatizada

| | `syncPolicy` sin definir (manual) | `automated:` (sin opciones) | `automated: { prune, selfHeal }` |
|---|---|---|---|
| Aplica cambios de Git automáticamente | No | Sí | Sí |
| Borra recursos eliminados de Git | No | **No** (quedan huérfanos) | Sí (prune) |
| Revierte ediciones fuera de banda del clúster | No | No | Sí (selfHeal) |
| Perfil de riesgo | El más seguro, necesita una persona | Los objetos nuevos aparecen pero las eliminaciones persisten | Totalmente autónomo — máxima corrección de deriva, requiere confiar en Git como verdad |

`selfHeal` y `prune` son **independientes** y ambos tienen valor por defecto `false`. Un error de producción muy común es habilitar `automated` sin `prune` y después preguntarse por qué los manifiestos borrados siguen corriendo.

---

## 4. CRDs centrales y manifiestos completos

Todo lo que hace Argo CD es declarativo. Los tres CRDs (`argoproj.io/v1alpha1`): **`Application`**, **`AppProject`**, **`ApplicationSet`**.

### 4.1 Un `Application` completo, de grado producción

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api
  namespace: argocd                       # Applications live in the Argo CD namespace
  # The finalizer makes deletion cascade to the app's live resources.
  # Without it, deleting the Application orphans everything it created.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    team: payments
spec:
  project: payments                       # must reference an existing AppProject
  source:
    repoURL: https://github.com/acme/platform-manifests.git
    targetRevision: v2.7.3                 # branch, tag, or commit SHA (SHA = immutable)
    path: apps/payments-api/overlays/prod
    kustomize:                             # rendering engine hint (Helm/Jsonnet also supported)
      namePrefix: prod-
      images:
        - registry.acme.io/payments-api:1.14.2
  destination:
    server: https://kubernetes.default.svc # in-cluster; or a registered remote cluster URL
    namespace: payments
  syncPolicy:
    automated:
      prune: true                          # delete resources removed from Git
      selfHeal: true                       # revert out-of-band cluster edits
      allowEmpty: false                    # refuse to prune down to zero resources (safety)
    syncOptions:
      - CreateNamespace=true               # create the destination namespace if absent
      - PruneLast=true                     # prune only after other resources sync (avoids gaps)
      - ApplyOutOfSyncOnly=true            # skip already-synced objects — faster large syncs
      - ServerSideApply=true               # SSA: avoids client-side last-applied annotation bloat
      - RespectIgnoreDifferences=true      # don't sync fields listed in ignoreDifferences
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  # Fields Argo CD must NOT treat as drift (controllers/mutating webhooks own them).
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas                   # HPA owns replicas; ignore it or fight forever
    - group: ""
      kind: Secret
      jqPathExpressions:
        - '.data["ca.crt"]'                # cert-manager injects this
  # Bound the amount of stale revision history kept in the Application status.
  revisionHistoryLimit: 10
```

**Annotations de producción clave que se ponen en los recursos *hijos*** (no en la Application):

- `argocd.argoproj.io/sync-wave: "-1"` — ordena el sync en **waves** (el menor corre primero; por defecto `0`). Los Namespaces/CRDs/DBs van en waves más tempranas que las cargas de trabajo que dependen de ellos.
- `argocd.argoproj.io/hook: PreSync` — un **resource hook**; corre como una fase alrededor del sync. Fases: `PreSync`, `Sync`, `PostSync`, `SyncFail`, más `Skip`.
- `argocd.argoproj.io/hook-delete-policy: HookSucceeded` — limpia los recursos del hook (`HookSucceeded` | `HookFailed` | `BeforeHookCreation`).

Ejemplo de un Job de migración de base de datos como hook PreSync:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-wave: "-1"
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: registry.acme.io/payments-api:1.14.2
          command: ["/app/migrate", "up"]
```

Si este Job falla, el sync entero falla antes de que se despliegue cualquier Deployment nuevo — exactamente lo que querés para releases que cambian el esquema.

### 4.2 Barreras de multi-tenancy: `AppProject`

`AppProject` es el límite de seguridad. Restringe *desde dónde* y *hacia dónde* pueden desplegar las apps, *qué* pueden crear y *quién* puede operarlas.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
spec:
  description: Payments team — prod + staging only
  # Whitelist of Git repos apps in this project may pull from.
  sourceRepos:
    - https://github.com/acme/platform-manifests.git
  # Whitelist of (cluster, namespace) an app may deploy to.
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'payments*'
    - server: https://staging.k8s.acme.io
      namespace: 'payments*'
  # Cluster-scoped kinds this project may manage (default: none allowed).
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  # Namespaced kinds explicitly forbidden even if in Git.
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
  # Deploy freeze windows (cron). Deny prod syncs during business hours.
  syncWindows:
    - kind: deny
      schedule: '0 9 * * MON-FRI'
      duration: 8h
      applications:
        - 'payments-*'
      manualSync: true          # humans may still sync manually; automation is blocked
  # Project-scoped RBAC roles with token support for CI.
  roles:
    - name: ci-deployer
      description: Read + sync only, for the deploy pipeline
      policies:
        - p, proj:payments:ci-deployer, applications, sync, payments/*, allow
        - p, proj:payments:ci-deployer, applications, get, payments/*, allow
      groups:
        - acme:payments-ci
```

### 4.3 Escalar a muchas apps/clústeres: `ApplicationSet`

`ApplicationSet` genera `Application`s a partir de **generadores**, eliminando la proliferación de copy-paste. Generadores: **List, Cluster, Git (directorio/archivo), Matrix, Merge, SCM Provider, Pull Request, Cluster Decision Resource, Plugin.**

Este ejemplo usa un generador **Matrix** (directorios de Git × clústeres registrados) para desplegar cada directorio de app en cada clúster de producción:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-addons
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          # 1) one element per directory under addons/
          - git:
              repoURL: https://github.com/acme/platform-manifests.git
              revision: main
              directories:
                - path: addons/*
          # 2) one element per cluster labelled env=prod
          - clusters:
              selector:
                matchLabels:
                  env: prod
  template:
    metadata:
      name: '{{.path.basename}}-{{.name}}'    # e.g. ingress-nginx-prod-eu-west
    spec:
      project: platform
      source:
        repoURL: https://github.com/acme/platform-manifests.git
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: '{{.server}}'
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [ "CreateNamespace=true" ]
```

Agregar un nuevo clúster de prod (etiquetado `env=prod`) o un nuevo directorio de addon ahora *automáticamente* materializa el producto cruzado completo de `Application`s — sin escribir manifiestos a mano.

### 4.4 El patrón "App of Apps"

Una única `Application` raíz cuyo path de Git contiene **otros manifiestos `Application`**. Hacer bootstrap de un clúster entero se convierte en sincronizar una sola app.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-bootstrap
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/acme/platform-manifests.git
    targetRevision: main
    path: bootstrap/prod            # this directory contains Application YAMLs
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

`ApplicationSet` en general se prefiere sobre App-of-Apps para fan-out homogéneo; App-of-Apps sigue siendo útil para conjuntos de bootstrap heterogéneos y curados a mano.

### 4.5 RBAC declarativo (`argocd-rbac-cm`)

Argo CD tiene su propia capa de RBAC (independiente del RBAC de Kubernetes) aplicada por el servidor de API:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly           # everyone gets read-only by default
  scopes: '[groups]'                       # map OIDC "groups" claim to roles
  policy.csv: |
    # p, <subject>, <resource>, <action>, <object>, <effect>
    p, role:payments-admin, applications, *, payments/*, allow
    p, role:payments-admin, logs, get, payments/*, allow
    p, role:payments-admin, exec, create, payments/*, allow
    # bind an SSO group to the role
    g, acme:payments-leads, role:payments-admin
```

---

## 5. Comandos de la CLI y salida real de terminal

Instalá la CLI y después iniciá sesión contra el servidor de API (acá vía port-forward):

```console
$ argocd login argocd.acme.io --grpc-web
Username: admin
Password:
'admin:login' logged in successfully
Context 'argocd.acme.io' updated
```

Creá una app declarativamente-desde-flags (equivalente a aplicar el CRD `Application`):

```console
$ argocd app create payments-api \
    --repo https://github.com/acme/platform-manifests.git \
    --path apps/payments-api/overlays/prod \
    --revision v2.7.3 \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace payments \
    --project payments \
    --sync-policy automated --auto-prune --self-heal
application 'payments-api' created
```

Inspeccioná el estado — notá que **Sync** y **Health** se reportan de forma independiente:

```console
$ argocd app get payments-api
Name:               argocd/payments-api
Project:            payments
Server:             https://kubernetes.default.svc
Namespace:          payments
Repo:               https://github.com/acme/platform-manifests.git
Target:             v2.7.3
Path:               apps/payments-api/overlays/prod
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        Synced to v2.7.3 (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME              STATUS  HEALTH   HOOK  MESSAGE
       Service     payments   prod-payments-api Synced  Healthy        service/prod-payments-api created
apps   Deployment  payments   prod-payments-api Synced  Healthy        deployment.apps/prod-payments-api created
       ConfigMap   payments   prod-payments-api Synced                 configmap/prod-payments-api created
```

Previsualizá el diff antes de sincronizar (el código de salida `1` significa que existen diferencias — útil en gates de CI):

```console
$ argocd app diff payments-api
===== apps/Deployment payments/prod-payments-api ======
27c27
<       image: registry.acme.io/payments-api:1.14.1
---
>       image: registry.acme.io/payments-api:1.14.2
$ echo $?
1
```

Forzá un sync y bloqueá hasta que esté saludable:

```console
$ argocd app sync payments-api --prune
TIMESTAMP                  GROUP        KIND   NAMESPACE  NAME               STATUS    HEALTH        HOOK  MESSAGE
2026-08-12T14:03:11+00:00  apps  Deployment   payments   prod-payments-api  OutOfSync  Progressing
2026-08-12T14:03:19+00:00  apps  Deployment   payments   prod-payments-api  Synced     Progressing        deployment "prod-payments-api" updated

Operation:          Sync
Sync Revision:      a1b2c3d4e5f6...
Phase:              Succeeded
Message:            successfully synced (all tasks run)

$ argocd app wait payments-api --health --timeout 300
payments-api  Synced  Healthy
```

Historial y rollback:

```console
$ argocd app history payments-api
ID  DATE                           REVISION
7   2026-08-10 09:12:44 +0000 UTC  v2.7.1 (9f8e7d6)
8   2026-08-12 14:03:19 +0000 UTC  v2.7.3 (a1b2c3d)

$ argocd app rollback payments-api 7
Rollback 'payments-api' to 7 ...
Phase:   Succeeded
```

Registrá un clúster remoto (crea un `Secret` de tipo credenciales de clúster en el namespace `argocd`):

```console
$ argocd cluster add prod-eu-west --name prod-eu-west
INFO Creating ServiceAccount argocd-manager in kube-system
INFO ClusterRole and ClusterRoleBinding created
Cluster 'https://EAA1...eu-west.k8s.acme.io' added
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Primer triage — la lectura de dos ejes

Siempre separá los ejes antes de hacer cualquier otra cosa:

```console
$ argocd app list -o wide
NAME          CLUSTER                         NAMESPACE  PROJECT   STATUS     HEALTH     SYNCPOLICY  CONDITIONS
payments-api  https://kubernetes.default.svc  payments   payments  OutOfSync  Degraded   Auto-Prune  SyncError
```

- `OutOfSync` → un problema de *diff* (Git vs. en vivo). Investigá con `argocd app diff`.
- `Degraded` → un problema de *runtime* (la carga de trabajo no está saludable). Investigá el recurso en vivo con `kubectl`.
- Ambos → el sync se aplicó pero el nuevo estado está roto.

### 6.2 Catálogo de fallas

| Síntoma | Causa probable | Diagnóstico / arreglo |
|---|---|---|
| Estado de sync `ComparisonError` / `Unknown` | `repo-server` no puede renderizar (values de Helm malos, autenticación de repo privado, error de Kustomize) | `kubectl logs deploy/argocd-repo-server -n argocd`; verificá las credenciales del repo con `argocd repo list` |
| App perpetuamente `OutOfSync` en el mismo campo | Un controlador/webhook muta un campo que Argo intenta revertir (réplicas de HPA, sidecar inyectado, valores por defecto) | Agregá el campo a `ignoreDifferences`; habilitá `RespectIgnoreDifferences` |
| `selfHeal` peleando contra un operator cada pocos segundos | Dos controladores son dueños del mismo campo | Usá `ignoreDifferences` o `ServerSideApply` con los field managers correctos |
| Sync `Succeeded` pero app `Degraded` | Los manifiestos se aplicaron bien; los pods crashean/falla el liveness | `kubectl -n <ns> describe pod`, `kubectl logs`; esto es un bug de la app, no de Argo |
| Recursos borrados de Git siguen corriendo | `prune` está en `false` | Poné `automated.prune: true`, o manualmente `argocd app sync --prune` |
| Toda la app pruneada a cero inesperadamente | Path malo/render vacío + prune | Poné `allowEmpty: false`; verificá `spec.source.path` |
| El Job de un sync hook nunca se limpia | `hook-delete-policy` incorrecta/ausente | Poné `argocd.argoproj.io/hook-delete-policy: HookSucceeded` |
| CRD personalizado atascado en `Progressing` para siempre | No hay evaluador de salud para ese kind | Agregá un health check en Lua vía `resource.customizations` en `argocd-cm` |
| La `Application` no se borra | Finalizer ausente/bloqueado o un hijo atascado terminando | Verificá `resources-finalizer.argocd.argoproj.io`; inspeccioná los recursos hijos atascados |
| Sync bloqueado con "Sync is not allowed" | Una **sync window** `deny` activa en el `AppProject` | `argocd app get <app>` → verificá `SyncWindow`; sincronizá manualmente si `manualSync: true` |

### 6.3 Diagnósticos profundos

Inspeccioná lo que el controlador realmente computó para un recurso específico:

```console
$ argocd app get payments-api --show-operation
...
Operation:          Sync
Phase:              Failed
Message:            one or more objects failed to apply, reason:
                    admission webhook "validate.kyverno.svc" denied the request:
                    resource Deployment/prod-payments-api has no resource limits
```

Logs de los componentes, en el orden de la etapa del pipeline que falló:

```console
# rendering failures (Sync status Unknown/ComparisonError)
$ kubectl logs -n argocd deploy/argocd-repo-server --tail=100

# sync/health/hook failures
$ kubectl logs -n argocd sts/argocd-application-controller --tail=100

# auth / RBAC / UI / CLI errors
$ kubectl logs -n argocd deploy/argocd-server --tail=100
```

Forzá un refresh duro (bypasea la caché de manifiestos de Redis — el arreglo cuando Argo muestra estado obsoleto después de que *sabés* que Git cambió):

```console
$ argocd app get payments-api --hard-refresh
```

Confirmá la revisión exacta a la que Argo reconcilió y probá que no hay deriva:

```console
$ argocd app get payments-api -o json | jq '.status.sync.revision, .status.health.status'
"a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
"Healthy"
```

### 6.4 Señales de observabilidad

- **Las métricas de Prometheus** las expone cada componente (`argocd-metrics`, `argocd-server-metrics`, `argocd-repo-server` `:8084/metrics`). Señales SLO clave: `argocd_app_sync_total{phase}` (resultados de sync), `argocd_app_info{sync_status,health_status}` (salud de la flota), y la profundidad/latencia de la cola de reconciliación del controlador (histograma `argocd_app_reconcile`) para detectar un controlador saturado que ya no da abasto con la flota — el disparador para habilitar **sharding del controlador** entre clústeres.
- **El notifications controller** debería alertar sobre `on-sync-failed` y `on-health-degraded` para que una app de prod `Degraded` le avise a alguien en vez de quedarse silenciosamente en `Synced`.

---

## 7. Referencias (fuentes oficiales)

- Currículum CAPA (dominios y pesos del examen): https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
- Documentación de Argo CD (inicio): https://argo-cd.readthedocs.io/en/stable/
- Arquitectura y componentes: https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/
- CRD Application y opciones de sync: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- Política de sync automatizada (prune / selfHeal): https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- Sync waves, fases y resource hooks: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/ y https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/
- Diffing e `ignoreDifferences`: https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- Evaluación de salud y health checks Lua personalizados: https://argo-cd.readthedocs.io/en/stable/operator-manual/health/
- AppProject y multi-tenancy: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- ApplicationSet y generadores: https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/ y https://argocd-applicationset.readthedocs.io/en/stable/
- Configuración de RBAC: https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
- Métodos de seguimiento de recursos: https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
- Métricas de Prometheus: https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/
- Principios de OpenGitOps: https://opengitops.dev/
- gitops-engine (biblioteca compartida de reconciliación): https://github.com/argoproj/gitops-engine