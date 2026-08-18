# 2.1 Principios y prácticas de GitOps

## 1. Motivación en producción: el problema arquitectónico

Antes de GitOps, el modelo operativo dominante para flotas de Kubernetes era **CIOps** (despliegue push dirigido por CI): un pipeline ejecuta `kubectl apply` o `helm upgrade` contra el clúster al final de un build, y todo lo que ocurre después de ese instante es invisible para el sistema de entrega. A escala de producción este modelo falla sobre cuatro ejes independientes:

**Deriva de configuración (drift).** El estado vivo del clúster es mutado por actores de los que el pipeline no sabe nada: un SRE ejecutando `kubectl edit` durante un incidente, un admission webhook inyectando sidecars, un operator escalando una carga de trabajo, un colega aplicando un hotfix desde su laptop. En cuestión de semanas, ningún artefacto en ningún lado describe lo que realmente está corriendo. Los últimos manifiestos aplicados por el pipeline son una afirmación histórica, no un hecho. Este es el problema del *clúster copo de nieve* trasplantado desde la era de las VM a Kubernetes.

**Radio de exposición de credenciales.** Los modelos push exigen que el sistema de CI —típicamente un servicio multi-tenant, expuesto a internet y que ejecuta código de terceros— posea credenciales de cluster-admin (o casi) para cada clúster de destino. Un único plugin de pipeline comprometido se convierte en un compromiso de toda la flota. La ola de incidentes de cadena de suministro en CI de 2020–2021 convirtió esto en el argumento de seguridad principal para invertir la dirección del despliegue.

**Sin garantía de convergencia.** `kubectl apply` es una operación de un solo disparo, fire-and-forget. Si el API server está brevemente indisponible, si un CRD todavía no está registrado, si una condición de carrera en la admisión de un nodo descarta un recurso — el pipeline o bien falla la corrida entera o, peor, aplica a medias y reporta verde. Nada reintenta después de que el pipeline termina. El despliegue es un *evento*, no un *proceso*.

**Operaciones no auditables y recuperación ante desastres lenta.** Cuando el registro del cambio es un rollo de logs de CI más el historial de shell del operador, responder "quién cambió el `PodDisruptionBudget` y por qué" requiere trabajo forense. Reconstruir un clúster perdido requiere reproducir una secuencia desconocida de acciones imperativas en un orden desconocido.

GitOps resuelve las cuatro reestructurando la entrega como un **sistema de control de lazo cerrado**, el mismo patrón arquitectónico que Kubernetes usa internamente (controladores reconciliando `spec` hacia `status`):

```
             ┌────────────────────────────────────────────────┐
             │              Desired State Store               │
             │        (Git repository / OCI registry)         │
             └───────────────────────┬────────────────────────┘
                                     │  pulled (poll/webhook)
                                     ▼
             ┌────────────────────────────────────────────────┐
             │            Reconciler (software agent)         │
             │   observe live state ──► diff ──► converge     │
             │        Flux / Argo CD, running IN cluster      │
             └───────────────────────┬────────────────────────┘
                                     │  apply / prune / wait
                                     ▼
             ┌────────────────────────────────────────────────┐
             │                 Managed System                 │
             │            (Kubernetes API server)             │
             └────────────────────────────────────────────────┘
```

Las personas y los sistemas de CI pierden acceso de escritura al clúster; ganan acceso de escritura al state store, controlado por la misma maquinaria de revisión que el código de aplicación (pull requests, protección de ramas, commits firmados, CODEOWNERS). El agente dentro del clúster obtiene (pull) el estado deseado y lleva al sistema hacia él, de forma continua, para siempre. El despliegue deja de ser algo que uno *hace* y pasa a ser algo que el sistema *mantiene*.

---

## 2. Los cuatro principios de OpenGitOps (v1.0.0)

El proyecto **OpenGitOps** de la CNCF (un working group bajo el CNCF App Delivery TAG) codificó GitOps en cuatro principios normativos. El examen CGOA evalúa estas definiciones con precisión — incluyendo lo que deliberadamente *no* dicen (nota: nada de lo que sigue exige Git específicamente, y nada menciona Kubernetes).

> Un sistema gestionado con GitOps es aquel donde el **estado deseado** está (1) expresado declarativamente, (2) almacenado en un store versionado e inmutable, (3) obtenido automáticamente por agentes de software, y (4) reconciliado continuamente contra el estado vivo.

### Principio 1 — Declarativo

*"Un sistema gestionado por GitOps debe tener su estado deseado expresado declarativamente."*

Declarativo significa que el state store contiene **hechos sobre el destino, no instrucciones para el viaje**. `replicas: 6` es declarativo; `kubectl scale deployment web --replicas=6` es imperativo. La distinción es arquitectónica, no estilística:

- Las declaraciones son **idempotentes y tolerantes al orden**: aplicar el mismo estado dos veces converge al mismo resultado; el reconciliador puede reintentar, reordenar y re-aplicar con seguridad. Las secuencias imperativas no son ninguna de las dos cosas — reproducir `scale +2` dos veces da un sistema distinto.
- Las declaraciones son **diffeables**: el reconciliador puede calcular `deseado − observado` y actuar solo sobre el delta. No existe un diff con sentido entre dos scripts de shell.
- Las declaraciones **componen**: overlays (Kustomize), values (Helm) y motores de políticas pueden transformarlas mecánicamente.

El estado deseado es la *fuente de verdad*; el sistema vivo es un *artefacto derivado* — la misma relación que un binario compilado tiene con el código fuente.

### Principio 2 — Versionado e inmutable

*"El estado deseado se almacena de una manera que impone inmutabilidad, versionado y retiene un historial de versiones completo."*

El principio nombra propiedades, no productos. Git las satisface (commits direccionados por contenido, historial append-only bajo protección de ramas), y por eso es la elección canónica — pero un **OCI registry con tags inmutables** o un bucket S3 con versionado de objetos y object lock son state stores igualmente conformes. Flux, por ejemplo, puede reconciliar directamente desde artefactos OCI sin ningún repositorio Git en el camino de ejecución.

Lo que estas propiedades aportan en producción:

- **El rollback es un revert.** Todo estado previo del sistema es direccionable por revisión; la recuperación de un release malo es `git revert` + reconciliación — sin la presión de "solo roll-forward" propia de los sistemas copo de nieve.
- **La auditoría es intrínseca.** Autor, revisor, timestamp y contenido completo de cada cambio existen por construcción. Combinado con firma de commits y protección de ramas, el historial es a prueba de manipulaciones (tamper-evident).
- **Correlación.** La revisión (commit SHA / digest OCI) se convierte en un identificador de correlación para toda la flota: el reconciliador informa qué revisión está corriendo cada clúster, y las líneas de tiempo de incidentes se anclan a revisiones en vez de a conjeturas de reloj.

### Principio 3 — Obtenido automáticamente (pull)

*"Agentes de software obtienen automáticamente las declaraciones del estado deseado desde la fuente."*

El agente corre **dentro del límite de confianza del sistema gestionado** y sale *hacia afuera* a buscar el state store — lo inverso del despliegue push. Consecuencias:

- **Inversión de credenciales.** El clúster posee un token de solo lectura hacia el state store. El state store no posee nada. CI no posee nada que pueda tocar el clúster. El componente más expuesto de la cadena (CI) queda despojado de su secreto más peligroso.
- **Inversión de red.** No se requiere ningún camino entrante hacia el API de Kubernetes — clústeres detrás de NAT, en sitios air-gapped o sobre hardware de edge hacen pull cada vez que hay conectividad. Por eso GitOps es el patrón estándar para flotas de edge.
- **Automático** significa que los cambios se aplican cuando están *disponibles*, no cuando una persona ejecuta un comando. Los webhooks son una optimización que acorta el intervalo de poll; el bucle de poll sigue siendo el mecanismo de corrección (los webhooks pueden perderse; el polling garantiza la recogida eventual).

### Principio 4 — Reconciliado continuamente

*"Agentes de software observan continuamente el estado real del sistema e intentan aplicar el estado deseado."*

Este es el principio que separa GitOps de "CD que casualmente usa Git". El agente ejecuta un lazo de control interminable — *observar → diff → actuar* — con **dos disparadores, no uno**:

1. **Cambió el estado deseado** (nuevo commit) → converger el estado vivo hacia él.
2. **Cambió el estado vivo** (drift: edición manual, recurso borrado, nodo caído) → converger el estado vivo *de vuelta* a la declaración.

El disparador 2 es lo que un pipeline nunca puede proveer. El drift se detecta y se reporta o se revierte automáticamente dentro de un intervalo de reconciliación, lo que significa que un `kubectl edit` de emergencia queda *deshecho por diseño* — el procedimiento de emergencia correcto en un sistema GitOps es suspender la reconciliación explícitamente (`flux suspend kustomization <name>`, o el `spec.syncPolicy` / sync windows de Argo CD), arreglar, y luego commitear el arreglo al state store y reanudar. "Continuamente" promete *intentos perpetuos de convergencia*, no éxito instantáneo — el sistema es eventualmente consistente.

---

## 3. Análisis de compromisos

### 3.1 Operaciones imperativas vs. declarativas

| Dimensión | Imperativo (`kubectl create/edit/scale`) | Declarativo (manifiestos + apply/reconcile) |
|---|---|---|
| Idempotencia | No — repetir cambia el resultado | Sí — repetir converge al mismo estado |
| Auditabilidad | Historial de shell, si acaso | Historial versionado completo por construcción |
| Manejo del drift | Invisible; el drift *es* el flujo de trabajo | Detectable y reversible (existe el diff) |
| Recuperación (DR) | Reproducir una secuencia de comandos desconocida | Apuntar el agente al state store; listo |
| Sensibilidad al orden | Alta — las secuencias deben correr en orden | Baja — el reconciliador reintenta hasta converger |
| Velocidad durante un incidente | Rápida para un hotfix puntual | Requiere commit + reconciliación (o suspend explícito) |
| Compuertas de revisión/aprobación | Ninguna inherente | Revisión de PR, CODEOWNERS, chequeos de políticas |

### 3.2 Push (CIOps) vs. Pull (GitOps)

| Dimensión | Push: CI ejecuta `kubectl`/`helm` | Pull: un agente en el clúster reconcilia |
|---|---|---|
| Credenciales del clúster | En poder de CI, fuera del clúster | Nunca salen del clúster; el token del store es de solo lectura |
| Topología de red | Se requiere acceso entrante al API server | Solo saliente; amigable con NAT/edge/air-gap |
| Drift post-despliegue | No detectado hasta la próxima corrida del pipeline | Corregido/reportado en cada intervalo |
| Convergencia | Un solo disparo; falla si el timing es malo | Reintentado para siempre; consistencia eventual |
| Escala de flota (100+ clústeres) | N pipelines × N juegos de credenciales | El mismo repo, N agentes haciendo pull; superficie de configuración O(1) |
| Visibilidad del despliegue | Una línea de log de CI: "applied" | Salud viva + estado de sincronización por recurso |
| Modo de fallo | Aplicado a medias, pipeline en verde | Reporta `Not Ready` hasta estar realmente sano |
| Parada de emergencia | Cancelar el pipeline | Suspender la reconciliación explícitamente |

### 3.3 GitOps vs. CD tradicional — dónde sigue viviendo CI

GitOps **no** reemplaza a CI. La frontera es:

| Etapa | Responsable | Salida |
|---|---|---|
| Build, test, scan | CI (modelo push, sin cambios) | Imagen inmutable `registry/app@sha256:…` |
| Definición del release | Una persona o una automatización abriendo un PR | Commit que actualiza el digest de la imagen / los values en el state store |
| Despliegue | Reconciliador (modelo pull) | Clúster convergido reportando revisión + salud |

El acceso de escritura de CI termina en el repositorio Git. El único acoplamiento es un commit.

### 3.4 Opciones de state store

| Store | Inmutabilidad | Versionado | Latencia hasta el agente | Uso típico |
|---|---|---|---|---|
| Repositorio Git | Protección de ramas + direccionamiento por SHA | Nativo | Poll o webhook | Por defecto; flujo de revisión humana |
| OCI registry (`OCIRepository` de Flux) | Tags inmutables / pinning por digest | Tag + digest | Rápida, respaldada por CDN | Flotas a escala; Git queda para la autoría, OCI para la distribución |
| Almacenamiento de objetos S3 (`Bucket`) | Versionado de objetos + lock | Nativo | Poll | Espejos air-gapped, artefactos de ML/configuración |

---

## 4. Implementación de referencia: manifiestos completos

La distribución de repositorio de abajo es el patrón mono-repo estándar para entornos-como-directorios (ramas-por-entorno es un anti-patrón: fuerza la promoción por merge y genera historiales divergentes):

```
fleet-repo/
├── apps/
│   └── podinfo/
│       ├── base/
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── kustomization.yaml
│       └── overlays/
│           ├── staging/
│           │   └── kustomization.yaml
│           └── production/
│               ├── kustomization.yaml
│               └── replicas-patch.yaml
└── clusters/
    └── production/
        ├── flux-system/            # generated by flux bootstrap
        └── apps.yaml               # Flux Kustomization (below)
```

### 4.1 Base declarativa de la aplicación

`apps/podinfo/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  labels:
    app.kubernetes.io/name: podinfo
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: podinfo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodana/podinfo:6.7.0   # pinned tag, never :latest
          ports:
            - name: http
              containerPort: 9898
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 256Mi
```

`apps/podinfo/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: podinfo
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

`apps/podinfo/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

`apps/podinfo/overlays/production/replicas-patch.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
spec:
  replicas: 6
```

`apps/podinfo/overlays/production/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: podinfo-prod
resources:
  - ../../base
patches:
  - path: replicas-patch.yaml
```

### 4.2 Flux: fuente + reconciliación

`clusters/production/apps.yaml` — el `GitRepository` declara *dónde vive el estado deseado*; la `Kustomization` declara *qué reconciliar de ahí y cómo*:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: fleet-repo
  namespace: flux-system
spec:
  interval: 1m                      # poll cadence; webhook receiver can shorten it
  url: https://github.com/example-org/fleet-repo
  ref:
    branch: main
  secretRef:
    name: fleet-repo-auth           # read-only deploy token
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: podinfo-production
  namespace: flux-system
spec:
  interval: 10m                     # full re-reconcile even without new commits (drift correction)
  sourceRef:
    kind: GitRepository
    name: fleet-repo
  path: ./apps/podinfo/overlays/production
  prune: true                       # delete cluster objects removed from Git
  wait: true                        # reconcile is not Ready until workloads are healthy
  timeout: 3m
  targetNamespace: podinfo-prod
```

### 4.3 Equivalente en Argo CD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo-production
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade-delete managed resources with the app
spec:
  project: default
  source:
    repoURL: https://github.com/example-org/fleet-repo
    targetRevision: main
    path: apps/podinfo/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo-prod
  syncPolicy:
    automated:
      prune: true                   # remove resources deleted from Git
      selfHeal: true                # revert manual drift automatically
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

`prune` y `selfHeal` son los dos interruptores que convierten a Argo CD de "sincronizar bajo demanda" en un reconciliador plenamente conforme al Principio 4; sin `selfHeal`, el drift solo se *reporta* (`OutOfSync`), no se corrige.

---

## 5. Operar el lazo: sesiones reales de CLI

### 5.1 Bootstrap y primera reconciliación (Flux)

```
$ flux check --pre
► checking prerequisites
✔ Kubernetes 1.30.2 >=1.28.0-0
✔ prerequisites checks passed

$ flux bootstrap github \
    --owner=example-org --repository=fleet-repo \
    --branch=main --path=clusters/production
► connecting to github.com
✔ repository "https://github.com/example-org/fleet-repo" created
► installing components in "flux-system" namespace
✔ install completed
► configuring deploy key
✔ deploy key configured with read-only access
✔ sync configured
✔ all components are healthy
```

Notá que la salida misma del bootstrap demuestra el Principio 3: la credencial aprovisionada es una **deploy key de solo lectura**, en poder del clúster.

### 5.2 Observar estado deseado vs. estado vivo

```
$ flux get kustomizations
NAME                  REVISION            SUSPENDED  READY  MESSAGE
flux-system           main@sha1:8f4e21ab  False      True   Applied revision: main@sha1:8f4e21ab
podinfo-production    main@sha1:8f4e21ab  False      True   Applied revision: main@sha1:8f4e21ab

$ kubectl -n podinfo-prod get deploy podinfo
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   6/6     6            6           12m
```

La columna `REVISION` es el identificador de correlación del Principio 2: cada clúster de la flota informa exactamente qué commit encarna.

### 5.3 Un cambio recorriendo el lazo

```
$ git switch -c bump-podinfo-6.7.1
$ sed -i 's/6.7.0/6.7.1/' apps/podinfo/base/deployment.yaml
$ git commit -am "podinfo: bump image to 6.7.1"
$ git push origin bump-podinfo-6.7.1
# ... PR reviewed, approved, merged to main ...

$ flux reconcile kustomization podinfo-production --with-source
► annotating GitRepository fleet-repo in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:c91d3e07
◎ waiting for Kustomization reconciliation
✔ applied revision main@sha1:c91d3e07
```

`flux reconcile` solo *acorta la espera* — si se lo omite, la misma convergencia ocurre dentro de `spec.interval`. El comando es un disparador, nunca un mecanismo de despliegue.

### 5.4 Inyección de drift y reversión automática

```
$ kubectl -n podinfo-prod scale deploy podinfo --replicas=1
deployment.apps/podinfo scaled

$ sleep 600 && kubectl -n podinfo-prod get deploy podinfo
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   6/6     6            6           43m
```

El escalado manual sobrevivió menos de un intervalo de reconciliación. Argo CD muestra el mismo evento de forma explícita:

```
$ argocd app get podinfo-production
Name:               argocd/podinfo-production
Sync Status:        Synced to main (c91d3e0)
Health Status:      Healthy

GROUP  KIND        NAMESPACE     NAME     STATUS  HEALTH   MESSAGE
       Service     podinfo-prod  podinfo  Synced  Healthy  service/podinfo unchanged
apps   Deployment  podinfo-prod  podinfo  Synced  Healthy  deployment.apps/podinfo configured
```

### 5.5 Rollback como un revert

```
$ git revert --no-edit c91d3e07
[main 4b7a9f12] Revert "podinfo: bump image to 6.7.1"
$ git push origin main
$ flux reconcile kustomization podinfo-production --with-source
✔ applied revision main@sha1:4b7a9f12
```

No existe ni hace falta ninguna maquinaria especial de rollback: el rollback es un movimiento hacia adelante del state store hasta un estado previo idéntico en contenido.

---

## 6. Guía de verificación y diagnóstico de fallos

### 6.1 Orden de triage estructurado

Diagnosticá siguiendo la dirección del pipeline — **fuente → build → apply → salud** — porque el fallo de cada etapa envenena la siguiente:

```
$ flux get sources git          # 1. can the agent fetch the state store?
$ flux get kustomizations       # 2. did build+apply succeed, at which revision?
$ flux events --for Kustomization/podinfo-production   # 3. what exactly failed?
$ kubectl -n podinfo-prod get events --sort-by=.lastTimestamp   # 4. workload-level causes
```

### 6.2 Catálogo de fallos

| Síntoma (estado del agente) | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| `failed to checkout and determine revision` / `authentication required` | Deploy key rotada, token expirado, repo pasado a privado | `flux get sources git` muestra la fuente como no Ready | Recrear el secret de `secretRef`; nunca ampliar a permisos de escritura |
| `kustomization path not found` | Typo en `spec.path` o directorio renombrado en un commit | `flux events` nombra la ruta faltante | Corregir la ruta en la `Kustomization` de Flux; tratar la distribución del repo como una API |
| `dry-run failed: ... field is immutable` | Cambio en un campo inmutable (p. ej. `spec.selector` de un Deployment, `clusterIP` de un Service) | El error nombra el campo | Borrar/recrear el objeto de forma intencional, o usar `spec.force: true` en la Kustomization de Flux sabiendo que recrea recursos |
| `OutOfSync` inmediatamente después de cada sync (Argo CD) | Un mutating webhook o un controlador reescribe campos; el diff nunca se asienta | `argocd app diff` muestra campos que nunca definiste | Agregar `ignoreDifferences` para las rutas mutadas, o normalizar con server-side apply |
| Recursos borrados de Git siguen corriendo | `prune` deshabilitado (`prune: false` en Flux / Argo sin `prune: true`) | Comparar `kubectl get -n ns all` contra el repo | Habilitar el pruning; verificar primero con un dry-run |
| La reconciliación se cuelga y luego `timeout waiting for ... to be ready` | `wait: true` + carga de trabajo que nunca queda sana (imagen mala, probe fallando, no schedulable) | `kubectl describe pod` → `ImagePullBackOff` / fallos de probe | Arreglar la carga de trabajo en Git; el agente está correctamente negándose a reportar éxito |
| CRD + CR en el mismo apply falla una vez y luego funciona | Orden: el CR se aplicó antes de que el CRD estuviera establecido | `no matches for kind` transitorio en los eventos | Aceptable (el reintento converge), o separar los CRDs en una Kustomization anterior con `dependsOn` |
| El drift reaparece en cada intervalo | Dos reconciliadores (o un HPA) peleando por el mismo campo | `kubectl get deploy -o yaml \| grep -A2 managedFields` muestra dos managers | Quitar el campo de Git si el HPA es su dueño (`replicas`), o borrar la Application/Kustomization duplicada |
| Todo Ready pero con una revisión vieja | Reconciliación suspendida | `flux get kustomizations` → `SUSPENDED: True` | `flux resume kustomization <name>`; auditar por qué fue suspendida |

### 6.3 Verificar la convergencia de forma independiente

Nunca confíes en un único estado verde — verificá deseado-contra-vivo con el propio API server:

```
$ kubectl diff -k apps/podinfo/overlays/production
$ echo $?
0        # exit 0 = zero drift; exit 1 = diff printed; >1 = error
```

`kubectl diff` realiza un dry-run del lado del servidor contra los objetos vivos — es el chequeo de drift de verdad-fundamental, independiente de cualquier herramienta GitOps, y merece un lugar en CI como reporte nocturno de drift de la flota.

### 6.4 Procedimiento de emergencia (el runbook relevante para el examen)

1. `flux suspend kustomization podinfo-production` — hacé la pausa explícita y visible, en lugar de correr una carrera contra el reconciliador.
2. Aplicá la mitigación imperativa.
3. Commiteá el cambio declarativo equivalente al state store, con revisión acelerada.
4. `flux resume kustomization podinfo-production` — el lazo converge hacia la declaración ahora correcta; el cambio manual queda confirmado o limpiamente sobrescrito.

Saltear el paso 3 es el fallo clásico: el arreglo del incidente se evapora en silencio en la siguiente reconciliación tras el resume.

---

## Referencias

- OpenGitOps — GitOps Principles v1.0.0 (CNCF): https://opengitops.dev/
- OpenGitOps principles source (GitHub): https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
- OpenGitOps glossary (desired state, state store, reconciliation): https://github.com/open-gitops/documents/blob/main/GLOSSARY.md
- CNCF CGOA curriculum: https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
- CGOA exam page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-gitops-associate-cgoa/
- Kubernetes — Declarative management of objects: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — Server-Side Apply and field management: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Flux documentation — Core concepts: https://fluxcd.io/flux/concepts/
- Flux — Kustomization API (prune, wait, force, dependsOn): https://fluxcd.io/flux/components/kustomize/kustomizations/
- Argo CD documentation — Automated sync, self-heal and pruning: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- Argo CD — Diffing customization (`ignoreDifferences`): https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/