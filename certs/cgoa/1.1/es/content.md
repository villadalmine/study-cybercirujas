# Tema 1.1 — Fundamentos de GitOps

**Examen:** CGOA · **Peso:** 25.0 · **Perfil:** SRE / Arquitecto de plataforma

---

## 1. Motivación: el problema de producción que GitOps resuelve

### 1.1 El modo de fallo de las operaciones imperativas

Antes de GitOps, el patrón de entrega dominante para Kubernetes era **CIOps**: un pipeline de CI construye un artefacto y luego *empuja* los cambios al clúster con comandos imperativos (`kubectl apply`, `helm upgrade`) como etapa final. Este modelo se rompe en producción a lo largo de cuatro ejes independientes:

1. **Deriva de configuración (drift).** El *estado real* del clúster diverge de lo que todo el mundo cree que está desplegado. Un hotfix aplicado con `kubectl edit` a las 03:00 durante un incidente sobrevive en silencio hasta que la siguiente ejecución del pipeline lo sobrescribe — o peor, no lo hace, porque el pipeline solo aplica los archivos que conoce. No hay ningún proceso cuya tarea sea advertir la divergencia.
2. **Proliferación de credenciales.** El CD basado en push exige que el sistema de CI conserve credenciales de cluster-admin (o casi) para cada clúster objetivo. Tu plataforma de CI — a menudo un producto SaaS fuera de tu frontera de seguridad — se convierte en el objetivo de ataque de mayor valor del parque. Comprometer el pipeline es comprometer producción.
3. **Cambio no auditable.** `kubectl` no da ninguna respuesta duradera a "¿quién cambió esto, cuándo y por qué?". Los audit logs de Kubernetes registran la llamada a la API, pero no la intención, ni la revisión, ni la ruta de rollback. Los regímenes de cumplimiento (SOC 2, control de cambios de PCI-DSS) terminan reconstruyendo el historial de cambios a partir de mensajes de Slack.
4. **Recuperación ante desastres lenta y con pérdidas.** Si el clúster es el único lugar donde existe el estado deseado completo, reconstruir un clúster es arqueología: exportar objetos vivos (contaminados con `status`, `managedFields`, valores por defecto) y confiar en que nada se aplicó a mano.

### 1.2 La respuesta arquitectónica: control en lazo cerrado

GitOps replantea la entrega como un **sistema de control en lazo cerrado**, el mismo modelo que el de los controladores de Kubernetes sobre los que corre:

```
             ┌──────────────────────────────────────────────┐
             │                                              │
  Human ──► PR ──► review ──► merge ──► State Store (Git)   │
             │                              │               │
             │                              ▼               │
             │                    ┌──────────────────┐      │
             │                    │ Reconciler agent │◄─────┼── observes actual state
             │                    │ (in-cluster)     │      │
             │                    └────────┬─────────┘      │
             │                             │ pull + apply   │
             │                             ▼                │
             │                    Kubernetes API server ────┘
             └──────────────────────────────────────────────┘
```

- El **estado deseado** vive en un **state store** versionado e inmutable (en la práctica, Git).
- **Agentes** de software (reconciliadores) *tiran* (pull) del estado deseado y lo comparan *continuamente* con el **estado real** del sistema.
- Cualquier divergencia — causada por un commit nuevo o por una mutación fuera de banda del clúster — es **drift**, y la tarea del reconciliador es converger el estado real de vuelta al estado deseado.

El cambio mental crítico para el examen: **un despliegue no es un evento disparado por un pipeline; es el efecto colateral de cambiar el estado deseado.** El verbo es *merge*, no *push*.

### 1.3 Qué te compra esto en producción

| Propiedad | Mecanismo que la provee |
|---|---|
| Auditabilidad | Cada cambio es un commit: autor, marca de tiempo, diff, rastro de revisión |
| Rollback | `git revert` — el reconciliador converge al estado anterior |
| Recuperación ante desastres | Apuntá el reconciliador de un clúster nuevo al repositorio; el estado se reconstruye solo |
| Postura de seguridad | Las credenciales del clúster nunca salen del clúster; CI tiene cero acceso al clúster |
| Eliminación de drift | La reconciliación continua revierte automáticamente los cambios fuera de banda |
| Consistencia multi-clúster | N clústeres reconcilian desde una única fuente de verdad |

---

## 2. Los cuatro principios de OpenGitOps (v1.0.0)

El proyecto **OpenGitOps** de la CNCF (un grupo de trabajo bajo el CNCF App Delivery TAG) define GitOps en cuatro principios. Esta es la definición normativa que evalúa el examen CGOA — memorizalos *y* sus consecuencias operativas.

> **Principio 1 — Declarativo.** *Un sistema gestionado con GitOps debe tener su estado deseado expresado de forma declarativa.*

Describís **qué** es el estado final (`replicas: 3`), nunca **cómo** llegar ahí (`kubectl scale --replicas=3`). El estado declarativo es idempotente y convergente: aplicarlo dos veces es seguro, y el estado actual es irrelevante para la corrección del estado deseado. Los scripts imperativos, en cambio, codifican supuestos sobre el punto de partida y fallan de manera impredecible cuando esos supuestos se rompen.

> **Principio 2 — Versionado e inmutable.** *El estado deseado se almacena de una forma que impone inmutabilidad, versionado y conserva un historial de versiones completo.*

Prestá atención: el principio dice **almacenamiento versionado e inmutable**, no "Git". Git es la implementación abrumadoramente común (de ahí el nombre), pero un registro OCI con tags inmutables, o un bucket S3 versionado, satisface el principio. Inmutabilidad significa que una revisión dada (un SHA de commit, un digest de imagen) siempre resuelve al mismo contenido — que es lo que hace trivial el rollback y confiable la auditoría.

> **Principio 3 — Traído automáticamente (pull).** *Agentes de software traen automáticamente las declaraciones de estado deseado desde la fuente.*

El agente corre *dentro* (o adyacente) al sistema gestionado y busca el estado según su propia planificación. Nada fuera de la frontera de confianza necesita acceso de escritura al sistema. Esto invierte el modelo de credenciales de CI/CD: en lugar de que CI guarde credenciales del clúster, el clúster guarda una deploy key de *solo lectura* al repositorio.

> **Principio 4 — Reconciliado continuamente.** *Agentes de software observan continuamente el estado real del sistema e intentan aplicar el estado deseado.*

"Continuamente" significa que el lazo nunca termina — no es "aplicar al hacer commit". El reconciliador compara deseado contra real en cada intervalo (y ante notificación), de modo que el drift introducido en *cualquier* momento desde *cualquier* fuente se corrige. Este es el principio que distingue a GitOps de "un pipeline de CD que casualmente lee YAML desde Git".

### 2.1 Terminología central (vocabulario de examen)

| Término | Definición |
|---|---|
| **Estado deseado (desired state)** | El agregado de todos los datos de configuración suficientes para recrear el sistema |
| **State store** | El sistema versionado e inmutable que aloja el estado deseado (Git, registro OCI) |
| **Estado real (actual state)** | El estado vivo y observado del sistema gestionado |
| **State drift** | Cualquier divergencia entre el estado real y el deseado |
| **Reconciliación** | El proceso continuo de converger el estado real hacia el estado deseado |
| **Reconciliador / agente de estado** | El componente de software que realiza la reconciliación (controladores de Flux, application-controller de Argo CD) |
| **Detección de drift** | Identificar que real ≠ deseado (prerrequisito de la remediación, pero distinto de ella) |
| **Continuous deployment vs. GitOps** | CD automatiza el *release*; GitOps además convierte el destino del release en un estado declarado que se aplica de forma continua |

---

## 3. Análisis de compromisos

### 3.1 Push (CIOps) vs. Pull (GitOps)

| Dimensión | Push (CI aplica al clúster) | Pull (reconciliador in-cluster) |
|---|---|---|
| Credenciales del clúster | Exportadas al sistema de CI (superficie de ataque) | Nunca salen del clúster; la deploy key del repo es de solo lectura |
| Manejo de drift | Ninguno — el drift persiste hasta la próxima ejecución del pipeline | Detectado y remediado continuamente |
| Topología de red | CI debe alcanzar el API server (agujeros de VPN/firewall hacia prod) | El clúster hace HTTPS *saliente* hacia Git — funciona detrás de NAT, amigable con air-gap si el store está espejado |
| Disparador del despliegue | Evento del pipeline (momento imperativo en el tiempo) | Cambio de estado + intervalo (convergente, reintentado por siempre) |
| Recuperación ante fallos | Re-ejecutar el pipeline manualmente | El reconciliador reintenta con backoff automáticamente |
| Escalado de flota | La complejidad del pipeline crece O(clústeres) | Cada clúster tira independientemente; pipeline O(1) |
| Latencia de feedback | Inmediata (log del pipeline) | Limitada por el intervalo salvo que se configure webhook/notificación |
| Emergencia "mandalo y ya" | Trivialmente fácil (que es justo el problema) | Requiere un commit — la fricción es la característica |

### 3.2 Gestión imperativa vs. declarativa

| Dimensión | Imperativa (`kubectl create/edit/scale`) | Declarativa (`apply` desde manifiestos) |
|---|---|---|
| Idempotencia | No — depende del estado actual | Sí — converge desde cualquier estado |
| Revisabilidad | Solo el historial de comandos | Diff completo en un PR |
| Reproducibilidad | Requiere reproducir el historial en orden | Requiere solo la última revisión |
| Convivencia con otros actores | Pisa cambios | El server-side apply resuelve la propiedad campo por campo |
| Compatibilidad con GitOps | Incompatible (viola el Principio 1) | Requerida |

### 3.3 Ubicación del reconciliador: agente in-cluster vs. operador externo

| Dimensión | Agente por clúster (modelo Flux, Argo CD por clúster) | Hub central gestionando spokes (Argo CD hub-and-spoke) |
|---|---|---|
| Radio de impacto si se compromete el reconciliador | Un clúster | Toda la flota |
| Modelo de credenciales | Ninguna cruza la frontera | El hub guarda kubeconfigs/tokens de cada spoke |
| Panel único de control | Requiere una capa de agregación | Nativo |
| Escala a N clústeres | Lineal, independiente | El hub se vuelve un cuello de botella de throughput/HA |
| Requisito de red | Clúster → Git (solo saliente) | Hub → API server de cada spoke (entrante hacia prod) |

Regla práctica del arquitecto: el pull por clúster maximiza las propiedades de seguridad que GitOps promete; hub-and-spoke devuelve algunas de ellas a cambio de operabilidad. Sabé que la lectura *más pura* del Principio 3 favorece al agente in-cluster.

### 3.4 State store: Git vs. artefactos OCI

| Dimensión | Repositorio Git | Registro OCI (p. ej. OCIRepository de Flux) |
|---|---|---|
| Flujo de revisión humana | Nativo (PRs) | Necesita un upstream en Git de todos modos; el registro aloja el estado *publicado* |
| Inmutabilidad | Impuesta por convención (ramas protegidas, sin force-push) | Impuesta por direccionamiento por digest |
| Firma/verificación | Firma de commits (GPG/SSH), controlada por política | Firmas Cosign/Notation, verificadas por el reconciliador |
| Escala de consumidores | Los servidores Git limitan flotas con polling intenso | Los registros están construidos para fan-out masivo de pulls |
| Entrega en air-gap | Espejado del repositorio | Promoción de artefactos entre registros — muy natural |

---

## 4. Manifiestos completos: una aplicación mínima gestionada con GitOps

El estado deseado vive en un repositorio con esta estructura:

```
fleet-repo/
├── apps/
│   └── podinfo/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── kustomization.yaml
└── clusters/
    └── prod/
        ├── podinfo-source.yaml
        └── podinfo-kustomization.yaml
```

### 4.1 El estado deseado de la aplicación

`apps/podinfo/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  namespace: podinfo
  labels:
    app.kubernetes.io/name: podinfo
    app.kubernetes.io/managed-by: flux
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: podinfo
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.7.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 9898
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
```

`apps/podinfo/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  namespace: podinfo
  labels:
    app.kubernetes.io/name: podinfo
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: podinfo
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

`apps/podinfo/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: podinfo
resources:
  - deployment.yaml
  - service.yaml
```

### 4.2 La configuración del reconciliador — sabor Flux

`clusters/prod/podinfo-source.yaml` — *de dónde* traer el estado deseado (Principios 2 y 3):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: fleet-repo
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/example-org/fleet-repo
  ref:
    branch: main
  secretRef:
    name: fleet-repo-auth
```

`clusters/prod/podinfo-kustomization.yaml` — *qué* reconciliar y *cómo* (Principio 4):

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: fleet-repo
  path: ./apps/podinfo
  prune: true
  wait: true
  targetNamespace: podinfo
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: podinfo
      namespace: podinfo
```

Dos campos cargan con la semántica relevante para el examen:

- **`prune: true`** — los recursos eliminados de Git son *borrados* del clúster (recolección de basura). Sin él, las eliminaciones en el state store nunca se propagan, y el estado real acumula huérfanos.
- **`interval`** — el período del lazo de reconciliación. Es la cota superior de la vida útil del drift, independientemente de cualquier actividad de commits.

### 4.3 La misma intención — sabor Argo CD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/example-org/fleet-repo
    targetRevision: main
    path: apps/podinfo
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

Mapeo de vocabulario que conviene saber de memoria: el **`selfHeal: true`** de Argo CD es lo que hace que la reconciliación sea *continua* frente al drift del lado del clúster (sin él, Argo CD solo sincroniza ante cambios en Git — el drift se detecta y se reporta como `OutOfSync`, pero no se remedia). **`prune: true`** tiene la misma semántica de recolección de basura que el campo homónimo de Flux.

---

## 5. Flujos de trabajo reales en CLI y salida esperada

### 5.1 El flujo de cambio es un flujo de Git

```
$ git switch -c bump-podinfo-6.7.1
$ sed -i 's|podinfo:6.7.0|podinfo:6.7.1|' apps/podinfo/deployment.yaml
$ git add -p && git commit -m "apps/podinfo: bump to 6.7.1"
$ git push -u origin bump-podinfo-6.7.1
```

Tras la revisión y el merge, no ocurre ninguna otra acción humana. El reconciliador toma la nueva revisión en su próximo intervalo.

### 5.2 Observar la reconciliación (Flux)

```
$ flux get sources git
NAME        REVISION            SUSPENDED  READY  MESSAGE
fleet-repo  main@sha1:8f4e2c1a  False      True   stored artifact for revision 'main@sha1:8f4e2c1a'

$ flux get kustomizations
NAME     REVISION            SUSPENDED  READY  MESSAGE
podinfo  main@sha1:8f4e2c1a  False      True   Applied revision: main@sha1:8f4e2c1a
```

El detalle que sostiene todo: `REVISION` informa el SHA exacto del commit aplicado. "¿Qué está corriendo en prod?" tiene una respuesta de un solo comando, precisa al commit.

Forzar una reconciliación inmediata en lugar de esperar al intervalo:

```
$ flux reconcile kustomization podinfo --with-source
► annotating GitRepository fleet-repo in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:8f4e2c1a
► annotating Kustomization podinfo in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ applied revision main@sha1:8f4e2c1a
```

### 5.3 Observar el estado de sincronización (Argo CD)

```
$ argocd app get podinfo
Name:               argocd/podinfo
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          podinfo
URL:                https://argocd.example.com/applications/podinfo
Source:
- Repo:             https://github.com/example-org/fleet-repo
  Target:           main
  Path:             apps/podinfo
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (8f4e2c1)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME     STATUS  HEALTH   HOOK  MESSAGE
       Service     podinfo    podinfo  Synced  Healthy        service/podinfo unchanged
apps   Deployment  podinfo    podinfo  Synced  Healthy        deployment.apps/podinfo configured
```

Fijate en los dos estados ortogonales — esta distinción se evalúa:

- **Sync Status** (`Synced` / `OutOfSync`): ¿el estado real coincide con el estado deseado?
- **Health Status** (`Healthy` / `Progressing` / `Degraded` / `Missing`): ¿la carga de trabajo realmente funciona?

Una aplicación puede estar `Synced` y `Degraded` a la vez: los manifiestos se aplicaron limpiamente, pero los pods están en crash-loop. GitOps garantiza la convergencia de la *configuración*, no la corrección del *software*.

### 5.4 Presenciar la remediación del drift

Simulá un cambio fuera de banda:

```
$ kubectl -n podinfo scale deployment/podinfo --replicas=10
deployment.apps/podinfo scaled

$ kubectl -n podinfo get deploy podinfo
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   10/10   10           10          14d
```

Dentro de un intervalo de reconciliación (o de inmediato con `selfHeal`):

```
$ kubectl -n podinfo get deploy podinfo
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   3/3     3            3           14d

$ kubectl -n flux-system get events --field-selector reason=ReconciliationSucceeded | tail -1
2m    Normal   ReconciliationSucceeded   kustomization/podinfo   Reconciliation finished in 341ms, next run in 10m
```

El cambio imperativo fue revertido por el lazo de control. Esta demostración — drift inyectado, drift borrado, sin intervención humana — *es* el Principio 4.

### 5.5 El rollback es `git revert`

```
$ git revert --no-edit 8f4e2c1
[main 3b9d0aa] Revert "apps/podinfo: bump to 6.7.1"
$ git push origin main
```

Sin `rollout undo`, sin pipeline de redespliegue. El estado deseado se movió hacia atrás; el reconciliador converge a él exactamente igual que lo haría con cualquier otra revisión. Como el revert es a su vez un commit, el rastro de auditoría registra el rollback como un cambio de primera clase.

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Orden sistemático de diagnóstico

La reconciliación es una cadena: **fetch de la fuente → build/render → apply → salud**. Diagnosticá en ese orden; un fallo temprano en la cadena se manifiesta más tarde como contenido desactualizado.

```
$ flux check
► checking prerequisites
✔ Kubernetes 1.31.2 >=1.28.0-0
► checking controllers
✔ source-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ helm-controller: deployment ready
✔ notification-controller: deployment ready
✔ all checks passed

$ flux get all -A --status-selector ready=false
NAME  REVISION  SUSPENDED  READY  MESSAGE
```

Un segundo listado vacío es la luz verde a nivel de flota: nada está fallando al reconciliar.

### 6.2 Tabla de modos de fallo

| Síntoma | Causa probable | Confirmar con | Solución |
|---|---|---|---|
| Fuente `READY=False`, `authentication required` | Deploy key o token expirado/rotado | `kubectl -n flux-system describe gitrepository fleet-repo` | Rotar el secret de `secretRef`; las claves son de solo lectura, así que la rotación es de bajo riesgo |
| La revisión avanza pero el clúster no cambia | Kustomization/Application suspendida, o `path` incorrecto | `flux get kustomizations` (`SUSPENDED=True`), `argocd app get` | `flux resume kustomization <name>`; corregir `spec.path` |
| `OutOfSync` inmediatamente después de cada sync | Un mutating webhook u otro controlador reescribe campos que el reconciliador posee | `kubectl diff`, vista "diff" de Argo CD mostrando un delta perpetuo | Configurar ignore-differences / exclusión de drift para los campos en disputa; encontrar al propietario en conflicto vía `managedFields` |
| El apply falla: `dry-run failed: ... CRD not found` | Orden — el CR se aplicó antes que su CRD | Eventos de la Kustomization | Separar los CRDs en su propia Kustomization previa; usar `dependsOn` (Flux) o sync waves (Argo CD) |
| `Synced` pero `Degraded` | La configuración convergió; la carga de trabajo está rota (imagen mala, probes fallando) | `kubectl -n podinfo describe pod`, logs del contenedor | Arreglar hacia adelante o `git revert` — nunca `kubectl edit`, que el lazo va a borrar |
| Borrado de Git, sigue en el clúster | `prune` deshabilitado | `spec.prune` en la Kustomization/Application | Habilitar prune; entender primero el radio de impacto |
| Reconciliador `Progressing` para siempre | `wait: true` con un health check que nunca puede pasar | `kubectl -n flux-system logs deploy/kustomize-controller` | Arreglar la carga de trabajo o el health check; subir `timeout` solo si de verdad es lento |
| Los cambios llegan minutos tarde | Solo polling por intervalo, sin notificación push | Comparar la hora del commit contra `lastHandledReconcileAt` | Agregar un receptor de webhook (notification-controller de Flux / webhook de Argo CD) — el intervalo pasa a ser el respaldo, no el camino |

### 6.3 Detección de drift sin reconciliador (desde primeros principios)

`kubectl diff` es la primitiva que subyace a la detección de drift de toda herramienta GitOps — un código de salida `1` significa que hay drift:

```
$ kustomize build apps/podinfo | kubectl diff -f -
diff -u /tmp/LIVE-1932/apps.v1.Deployment.podinfo.podinfo /tmp/MERGED-2811/apps.v1.Deployment.podinfo.podinfo
--- /tmp/LIVE-1932/apps.v1.Deployment.podinfo.podinfo
+++ /tmp/MERGED-2811/apps.v1.Deployment.podinfo.podinfo
@@ -14,7 +14,7 @@
-  replicas: 10
+  replicas: 3
$ echo $?
1
```

### 6.4 La escalera de verificación de una afirmación GitOps

Para afirmar "prod corre la revisión X" con evidencia en lugar de fe:

1. `git log -1 --format=%H` en `main` — lo que dice el state store.
2. `flux get kustomizations` / `argocd app get` — lo último que aplicó el reconciliador.
3. `kubectl get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}'` — lo que tiene el API server.
4. `kubectl get pods -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'` — el digest que realmente corre en los nodos.

O las cuatro coinciden, o encontraste drift (2≠3), un reconciliador estancado (1≠2), o un rollout en curso (3≠4). Cada desigualdad localiza la falla en un eslabón de la cadena — esa descomposición es la habilidad práctica que este dominio evalúa.

---

## Referencias

- OpenGitOps — principles v1.0.0 and glossary: https://opengitops.dev/
- OpenGitOps normative documents (CNCF GitOps Working Group): https://github.com/open-gitops/documents
- CNCF CGOA curriculum: https://github.com/cncf/curriculum
- CGOA exam page (CNCF/Linux Foundation): https://www.cncf.io/training/certification/cgoa/
- Kubernetes — Declarative management of objects: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — Controllers and the reconciliation model: https://kubernetes.io/docs/concepts/architecture/controller/
- Flux — Core concepts: https://fluxcd.io/flux/concepts/
- Flux — Kustomization API: https://fluxcd.io/flux/components/kustomize/kustomizations/
- Argo CD — Declarative setup: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- Argo CD — Automated sync and self-heal: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/