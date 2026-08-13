# CAPA 1.1 — Fundamentos del proyecto Argo

> **Peso del dominio:** 20% · **Nivel:** Avanzado (SRE / Arquitecto de Plataforma) · **Idioma de autoría:** inglés
>
> Este capítulo establece el sustrato conceptual y arquitectónico que comparten todas las herramientas del ecosistema Argo. Todo lo que aprendas en los dominios de Workflows, CD, Rollouts y Events se apoya en las cuatro ideas que se desarrollan aquí: **CRDs nativos de Kubernetes**, el **bucle de controlador/reconciliación**, el **estado deseado declarativo** y **GitOps**. Tratá este como el capítulo portante: el examen premia entender *por qué* Argo está construido como está, no solo *qué* hacen las CLIs.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El problema que Argo existe para resolver

Un equipo de plataforma moderno que opera Kubernetes a escala enfrenta cuatro problemas recurrentes y distintos. Argo no es una única herramienta: es una **familia de cuatro controladores graduados por la CNCF**, cada uno atacando uno de estos problemas con el *mismo* patrón arquitectónico:

| Problema de producción | Síntoma en el terreno | Proyecto de Argo |
|---|---|---|
| **Deriva de configuración** — el clúster en vivo ya no coincide con lo que está en Git | "Funciona en staging, nadie sabe por qué prod es diferente"; el `kubectl edit` manual nunca quedó registrado | **Argo CD** (entrega continua / GitOps) |
| **Orquestación batch compleja con forma de DAG** — pipelines de CI/CD, ETL y ML que superan a un shell script | pipelines de Jenkins que envuelven `kubectl run`; sin reintentos, sin linaje de artefactos, sin control de paralelismo | **Argo Workflows** (motor de workflows) |
| **Despliegues riesgosos** — un mal rollout se lleva el 100% del tráfico al instante | `Deployment` `RollingUpdate` no tiene aborto automático guiado por métricas; el rollback es manual y lento | **Argo Rollouts** (entrega progresiva) |
| **Pegamento orientado a eventos** — "cuando X sucede en el sistema A, hacé Y en Kubernetes" | polling por cron, receptores de webhook a medida, sin lógica de dependencias entre eventos | **Argo Events** (automatización orientada a eventos) |

La idea arquitectónica que los unifica: **no construyas un demonio a medida para cada problema. Extendé la API de Kubernetes con un nuevo tipo de recurso (un CRD) y escribí un controlador que impulse continuamente la realidad hacia el spec declarado del recurso.** Este es el *patrón operador*, y Argo es una de las demostraciones más completas de él en el mundo real.

### 1.2 Por qué "nativo de Kubernetes" es una decisión arquitectónica, no un eslogan

Considerá los diseños alternativos que un equipo de plataforma podría haber elegido para la entrega continua:

- **CI basado en push (Jenkins/GitLab ejecutando `kubectl apply`)** — el runner de CI necesita credenciales de cluster-admin, que ahora viven *fuera* del límite de confianza del clúster. Cada runner es una superficie de ataque con una llave maestra. No hay convergencia continua: una vez que `apply` termina, la deriva es invisible hasta que el siguiente pipeline se ejecuta.
- **Un demonio de sincronización propio hecho en casa** — ahora sos dueño de la semántica de reconciliación, el caché, el RBAC, el motor de diff y la UI. Es una inversión de varios años que cada equipo reinventa.
- **La elección de Argo: un controlador dentro del clúster que hace pull desde Git.** El estado vive en el propio API server del clúster (como CRs). El bucle de reconciliación es continuo. Las credenciales nunca salen del clúster. La observabilidad es `kubectl get` más una UI hecha a propósito.

El resto de este capítulo disecciona esa maquinaria compartida para que los capítulos específicos de cada herramienta puedan avanzar rápido.

---

## 2. El proyecto Argo: alcance, gobernanza y madurez

### 2.1 Los cuatro proyectos centrales (más el ecosistema)

```
                         ┌─────────────────────────────────────────┐
                         │              Argo Project                │
                         │        (CNCF Graduated — Dec 2022)       │
                         └─────────────────────────────────────────┘
                                          │
     ┌───────────────┬────────────────────┼────────────────────┬───────────────┐
     ▼               ▼                    ▼                    ▼               ▼
┌──────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────────┐   (ecosystem
│ Argo CD  │   │ Argo         │   │ Argo Rollouts │   │ Argo Events  │    add-ons:
│ GitOps   │   │ Workflows    │   │ Progressive   │   │ Event-driven │    ApplicationSet,
│ CD       │   │ DAG/step     │   │ delivery      │   │ automation   │    Notifications,
│          │   │ orchestration│   │ (canary/BG)   │   │ (bus+sources)│    argo-cd-image-updater)
└──────────┘   └──────────────┘   └───────────────┘   └──────────────┘
```

Los cuatro se graduaron juntos en la CNCF como un único proyecto el **2022-12-06** — la graduación es el nivel de madurez más alto de la CNCF y señala adopción en producción, auditorías de seguridad y gobernanza diversa.

### 2.2 Cómo se componen los proyectos (esto es relevante para el examen)

Los proyectos son binarios independientes pero están diseñados para **encadenarse**:

```
   Git push / webhook
          │
          ▼
   ┌──────────────┐  event   ┌──────────────┐  submit  ┌──────────────┐
   │ Argo Events  │ ───────▶ │ Argo         │ ───────▶ │  (build/test │
   │ EventSource  │          │ Workflows    │          │   artifacts) │
   │ + Sensor     │          │              │          └──────────────┘
   └──────────────┘          └──────────────┘
                                                              │ commit new image tag to Git
                                                              ▼
                              ┌──────────────┐   syncs   ┌──────────────┐
                              │  Argo CD     │ ────────▶ │ Argo Rollouts│
                              │  (GitOps)    │  Rollout  │  (canary +   │
                              │              │  manifest │   analysis)  │
                              └──────────────┘           └──────────────┘
```

Un pipeline de producción canónico: **Events** detecta un push a Git → dispara un **Workflow** que compila y testea → el Workflow hace commit de un tag de imagen actualizado → **Argo CD** detecta el cambio en Git y sincroniza → el recurso sincronizado es un **Rollout** que desplaza el tráfico progresivamente mientras consulta métricas.

### 2.3 El único patrón detrás de los cuatro

Cada proyecto de Argo es una instancia de la misma tríada:

| Capa | Qué es | Ejemplo (Argo CD) | Ejemplo (Workflows) |
|---|---|---|---|
| **Custom Resource (CRD)** | El *estado deseado* declarativo, almacenado en etcd como cualquier objeto nativo | `Application`, `ApplicationSet` | `Workflow`, `WorkflowTemplate`, `CronWorkflow` |
| **Controller** | Un bucle de control que observa esos CRs | `argocd-application-controller` | `workflow-controller` |
| **Reconciliation** | Impulsa continuamente el *estado en vivo* → *estado deseado* | Sincroniza los manifiestos de git dentro del clúster | Crea pods para cada nodo del workflow |

Si internalizás *CRD + controller + reconciliation*, cada herramienta de Argo se vuelve una variación sobre un tema.

---

## 3. Concepto central 1 — Custom Resource Definitions (CRDs)

### 3.1 Por qué extender la API en lugar de construir un servicio sidecar

Un CRD registra un nuevo `kind` en el API server de Kubernetes. Una vez registrados, `Application`, `Workflow` y `Rollout` son **objetos de API de primera clase**: obtienen `kubectl get/describe/apply`, RBAC, control de admisión, registro de auditoría, concurrencia optimista con `resourceVersion`, streams de watch y persistencia en etcd — **gratis**. Argo escribe cero código de almacenamiento.

Inspeccioná los CRDs que Argo instala:

```bash
$ kubectl get crd | grep argoproj.io
applications.argoproj.io                    2026-08-01T09:14:22Z
applicationsets.argoproj.io                 2026-08-01T09:14:22Z
appprojects.argoproj.io                     2026-08-01T09:14:22Z
clusterworkflowtemplates.argoproj.io        2026-08-01T09:15:03Z
cronworkflows.argoproj.io                   2026-08-01T09:15:03Z
workflows.argoproj.io                       2026-08-01T09:15:03Z
workflowtemplates.argoproj.io               2026-08-01T09:15:03Z
rollouts.argoproj.io                        2026-08-01T09:15:41Z
analysistemplates.argoproj.io               2026-08-01T09:15:41Z
analysisruns.argoproj.io                    2026-08-01T09:15:41Z
experiments.argoproj.io                     2026-08-01T09:15:41Z
eventsources.argoproj.io                    2026-08-01T09:16:12Z
sensors.argoproj.io                         2026-08-01T09:16:12Z
eventbus.argoproj.io                        2026-08-01T09:16:12Z
```

### 3.2 La anatomía que comparte todo CR de Argo

Cada CR de Argo sigue el contrato estándar de objetos de Kubernetes: `spec` es lo que declara el usuario; `status` es lo que reporta de vuelta el controlador. **Vos escribís el `spec`. El controlador es dueño del `status`. Nunca edites `status` a mano.**

```yaml
apiVersion: argoproj.io/v1alpha1   # group / version — most Argo CRDs are still v1alpha1
kind: Application                  # the CRD kind
metadata:
  name: my-app
  namespace: argocd                # Argo CD Applications live in the control-plane namespace
spec:                              # DESIRED STATE — authored by you / Git
  # ...
status:                            # OBSERVED STATE — written by the controller, read-only to you
  # ...
```

> **Trampa:** la mayoría de los CRDs de Argo siguen siendo `v1alpha1`. El `alpha` en la versión de la API **no** significa "no listo para producción" — los proyectos están graduados por la CNCF. Es una etiqueta de estabilidad de API que los mantenedores de Argo eligieron no incrementar porque hacerlo implica la carga de migración de un conversion-webhook. No confundas la versión de la API con la madurez del proyecto.

---

## 4. Concepto central 2 — el controlador y su bucle de reconciliación

### 4.1 El bucle de control

Un controlador es un programa que ejecuta un bucle infinito:

```
   for-ever:
     desired = read spec of every watched CR         (from the API server cache / informer)
     live    = observe actual cluster state
     diff    = desired − live
     if diff != ∅:
         act to close the diff (create/update/delete child resources)
     write observed result into status
     wait for next event OR resync interval
```

Esto es reconciliación **level-triggered** (también llamada *level-based*), y es la propiedad de diseño más importante para entender de cara al examen.

### 4.2 Level-triggered vs edge-triggered — el trade-off que hace a GitOps autorreparable

| Propiedad | **Edge-triggered** (reacciona al evento) | **Level-triggered** (reacciona al estado) — *el modelo de Argo* |
|---|---|---|
| Disparo | La transición ("ocurrió un push") | La condición actual ("en vivo ≠ deseado") |
| Evento perdido | **Perdido permanentemente** — el estado diverge para siempre | **Irrelevante** — la siguiente resincronización vuelve a observar y corrige |
| Reinicio del controlador | Puede perderse lo que ocurrió mientras estaba caído | Se recupera por completo volviendo a observar al arrancar |
| Deriva manual (`kubectl edit` en prod) | Sin detectar | **Detectada y (opcionalmente) revertida** en el siguiente bucle |
| Idempotencia | Difícil — hay que deduplicar eventos | Natural — reconciliar un estado ya correcto es un no-op |
| Costo | Barato por evento | Comparación completa periódica (mitigada por cachés de informer + hashing) |

Como los controladores de Argo reconcilian contra el *estado*, no contra los *eventos*, son **autorreparables**. Si un operador ejecuta `kubectl scale deployment/foo --replicas=1` sobre un recurso que administra Argo CD, la siguiente reconciliación observa `live.replicas=1 ≠ desired.replicas=3`, reporta **OutOfSync** y (con `selfHeal: true`) lo restaura. Un modelo de push de CI edge-triggered nunca lo notaría.

### 4.3 Dónde vive el estado

```
   ┌───────────────────────────────────────────────────────────────┐
   │                     Kubernetes API server                      │
   │   (etcd: the single source of truth for LIVE cluster state)    │
   └───────────────────────────────────────────────────────────────┘
        ▲  watch/list (informer)            │ create/update/patch
        │                                    ▼
   ┌────┴───────────────┐            ┌───────────────────────┐
   │   Argo controller   │  compares  │  child resources it   │
   │ (reconcile loop)    │◀──────────▶│  owns (Deployments,   │
   │                     │            │  Pods, Services, ...)  │
   └─────────────────────┘            └───────────────────────┘
        ▲
        │ DESIRED state
   ┌────┴───────────────┐
   │  Git repo (Argo CD) │   ← for GitOps tools, Git is the desired-state source;
   │  or the CR itself   │     for Workflows/Rollouts, the CR `spec` is authoritative.
   └─────────────────────┘
```

---

## 5. Concepto central 3 — estado deseado declarativo

### 5.1 Declarativo vs imperativo

| Eje | **Imperativo** (`kubectl create`, `kubectl scale`, shell scripts) | **Declarativo** (`kubectl apply -f`, CRs de Argo) |
|---|---|---|
| Especificás | Los *pasos* para alcanzar un estado | El *estado final* en sí |
| Reproducibilidad | Depende del punto de partida + el orden | Mismo manifiesto → mismo resultado, cualquier punto de partida |
| Detección de deriva | Imposible (no hay intención registrada) | Trivial (comparar manifiesto vs en vivo) |
| Auditabilidad | Dispersa en el historial del shell / logs de CI | Un único diff de Git revisable |
| Rollback | Rederivar y reejecutar los pasos inversos | `git revert` |
| Postura de Argo | Solo una vía de escape | **El valor por defecto y todo el punto** |

Las herramientas de Argo son declarativas hasta la médula: nunca le decís a Argo CD "sincronizá ahora, después esperá, después parchá". Declarás una `Application` cuyo `spec.source` apunta a una ruta de Git, y el controlador deduce los pasos.

### 5.2 Idempotencia (un requisito nativo de la CNCF y exigido por el repo)

Declarativo + level-triggered da **idempotencia**: aplicar el mismo manifiesto N veces converge al mismo estado y es un no-op después de la primera reconciliación exitosa. Por eso es seguro reintentar las operaciones de Argo — una sincronización interrumpida, un workflow reenviado, una `Application` reaplicada, todos retoman de forma limpia en lugar de duplicar trabajo.

---

## 6. Concepto central 4 — GitOps

### 6.1 Los cuatro principios de OpenGitOps

GitOps está formalizado por el grupo de trabajo **OpenGitOps** de la CNCF. Un sistema es GitOps si satisface **los cuatro** principios. Argo CD es una implementación de referencia.

| # | Principio | Significado | Cómo lo implementa Argo CD |
|---|---|---|---|
| 1 | **Declarativo** | Todo el estado deseado se expresa de forma declarativa | Manifiestos de Kubernetes / Helm / Kustomize en Git |
| 2 | **Versionado e inmutable** | El estado deseado se almacena de modo que quede versionado e imponga la inmutabilidad, con un historial completo | Git — commits, tags, commits firmados, revert |
| 3 | **Extraído automáticamente** | Agentes de software extraen (pull) automáticamente el estado deseado desde la fuente | `argocd-repo-server` clona el repo; el controlador hace pull |
| 4 | **Reconciliado continuamente** | Los agentes observan continuamente el estado real e intentan aplicar el estado deseado | El bucle level-triggered del application-controller |

### 6.2 Entrega basada en pull vs basada en push — el argumento de seguridad

| Dimensión | **CD por push** (CI ejecuta `kubectl apply`) | **CD por pull** (Argo CD reconcilia desde adentro) |
|---|---|---|
| Ubicación de credenciales | El kubeconfig de cluster-admin vive en el sistema de CI (fuera del clúster) | Las credenciales nunca salen del clúster; el agente tiene RBAC dentro del clúster |
| Superficie de ataque | Cada runner de CI es una llave maestra a prod | Ningún sistema externo tiene las credenciales del clúster |
| Escala multi-clúster | CI debe alcanzar la API de cada clúster (fan-out de red + credenciales) | Cada clúster hace pull por sí mismo; el hub puede estar detrás de un firewall |
| Corrección de deriva | Solo en el momento de ejecución del pipeline | Continua, autorreparable |
| Fuente de verdad | Ambigua (estado de CI + estado del clúster) | Git, sin ambigüedad |
| Trade-off | Modelo mental más simple, familiar para los equipos de CI | Requiere un agente dentro del clúster + semántica de reconciliación |

Este es el argumento de producción más fuerte a favor de Argo CD, y un tema frecuente del examen: **el GitOps basado en pull mantiene las credenciales de despliegue dentro del límite de confianza y convierte la deriva en una condición corregida continuamente en lugar de un evento puntual en el tiempo.**

---

## 7. Arquitectura de cada plano de control de Argo (a profundidad de fundamentos)

No se espera que memorices cada pod, pero debés reconocer la descomposición en componentes y la *razón* de ella.

### 7.1 Componentes de Argo CD

```
                                   ┌────────────────────────────┐
   git repo ◀───── clone/render ───│  argocd-repo-server        │  renders Helm/Kustomize/
                                   │  (manifest generation)     │  Jsonnet/plain YAML → manifests
                                   └────────────┬───────────────┘
                                                │ gRPC
   ┌──────────────┐   watch/apply   ┌───────────┴───────────────┐
   │ K8s API      │◀───────────────▶│ argocd-application-        │  the reconcile loop:
   │ (managed     │                 │ controller                 │  desired(git) vs live(cluster)
   │  clusters)   │                 └───────────┬───────────────┘
   └──────────────┘                             │
                                    ┌───────────┴───────────────┐
   UI / CLI / SSO ◀───────────────▶│ argocd-server (API server) │  REST/gRPC, RBAC, UI
                                    └───────────┬───────────────┘
                                                │
                          ┌─────────────────────┼─────────────────────┐
                          ▼                     ▼                     ▼
                   ┌─────────────┐      ┌─────────────┐       ┌──────────────┐
                   │ redis       │      │ dex (opt.)  │       │ applicationset│
                   │ (cache)     │      │ SSO broker  │       │ + notifications│
                   └─────────────┘      └─────────────┘       └──────────────┘
```

| Componente | Responsabilidad | Por qué está separado |
|---|---|---|
| `argocd-application-controller` | El motor de reconciliación: diff + sync | El núcleo con estado que muta el clúster; se escala por sharding entre los clústeres administrados |
| `argocd-repo-server` | Clona Git, renderiza las herramientas de templating en manifiestos crudos | Intensivo en CPU/memoria y expuesto a entradas no confiables; aislado para que un Helm chart malo no pueda tumbar al controlador |
| `argocd-server` | API/gRPC + UI web + aplicación de RBAC | Mayormente de lectura, escalable horizontalmente, expuesto a la red |
| `redis` | Caché efímero de manifiestos renderizados + estado en vivo | Evita rerenderizar/relistar en cada request; **pérdida = cache miss, no pérdida de datos** |
| `dex` (opcional) | Federa SSO externo (OIDC/SAML/LDAP) | Opcional; se puede usar OIDC nativo en su lugar |
| `applicationset-controller` | Genera muchas `Application`s a partir de generadores | Fan-out de templating (multi-clúster, monorepo) |
| `notifications-controller` | Envía eventos a Slack/email/webhooks | Transversal; desacoplado del núcleo de sincronización |

### 7.2 Componentes de Argo Workflows

- **`workflow-controller`** — observa los CRs `Workflow`, recorre el DAG/los pasos y crea un **Pod por nodo**. Cada pod ejecuta el contenedor del usuario más el **emissary executor** (el ejecutor por defecto y único desde v3.4), que captura logs, salidas y artefactos sin necesitar el socket de Docker.
- **`argo-server`** — la API/UI, el servido de artefactos y la autenticación. Opcional para un uso puramente basado en `kubectl`.

### 7.3 Componentes de Argo Rollouts

- **Controlador `argo-rollouts`** — un único controlador que administra el CRD `Rollout` (un reemplazo directo de `Deployment`), más `AnalysisTemplate`/`AnalysisRun`/`Experiment`. Manipula `ReplicaSet`s y (mediante plugins de enrutamiento de tráfico: Istio, SMI, NGINX, ALB, Gateway API y otros) desplaza el tráfico en pasos ponderados, opcionalmente condicionando según el análisis de métricas.

### 7.4 Componentes de Argo Events

- **`EventBus`** — la columna vertebral de transporte (JetStream/NATS por defecto).
- **`EventSource`** — adapta una fuente externa (webhook, S3, Kafka, calendario, SQS…) a eventos en el bus.
- **`Sensor`** — se suscribe a eventos, aplica lógica de dependencia/disparo y dispara **triggers** (crear un Workflow, un objeto de K8s, una llamada HTTP…).

---

## 8. Manifiestos completos y sin abreviar (uno por proyecto)

Estos son manifiestos mínimos pero válidos, con forma de producción, que ilustran la anatomía compartida de los CRD. Son sintácticamente completos y se aplicarán contra un clúster que tenga instalado el controlador de Argo respectivo.

### 8.1 Argo CD — una `Application` (unidad de despliegue de GitOps)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
  # Ensures the app itself and all its children are removed on `kubectl delete application`.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  # The AppProject scoping the RBAC and allowed sources/destinations for this app.
  project: default

  # DESIRED STATE lives in Git — principle #1 (declarative) and #2 (versioned).
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD          # a branch, tag, or commit SHA (SHA = immutable, recommended for prod)
    path: guestbook               # directory within the repo to render

  # Where the rendered manifests are applied.
  destination:
    server: https://kubernetes.default.svc   # in-cluster; or a registered remote cluster URL
    namespace: guestbook

  # Reconciliation behavior — principle #3 (pull) and #4 (continuous reconcile).
  syncPolicy:
    automated:
      prune: true        # delete cluster objects removed from Git
      selfHeal: true     # revert manual drift back to Git's declared state
      allowEmpty: false  # refuse to prune everything if Git renders to zero manifests (safety rail)
    syncOptions:
      - CreateNamespace=true       # create the destination namespace if missing
      - PruneLast=true             # prune only after other resources are healthy
      - ApplyOutOfSyncOnly=true    # apply only drifted resources, not the whole set
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### 8.2 Argo Workflows — un `Workflow` DAG de dos pasos

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: hello-dag-        # server assigns a unique suffix — idempotent-safe naming
  namespace: argo
spec:
  entrypoint: main                # which template to run first
  serviceAccountName: argo-workflow   # SA the executor pods run as
  templates:
    - name: main
      dag:
        tasks:
          - name: build
            template: echo
            arguments:
              parameters: [{ name: msg, value: "building" }]
          - name: test
            template: echo
            dependencies: [build]     # test runs only after build succeeds — DAG edge
            arguments:
              parameters: [{ name: msg, value: "testing" }]

    - name: echo
      inputs:
        parameters:
          - name: msg
      container:
        image: alpine:3.20
        command: [sh, -c]
        args: ["echo '{{inputs.parameters.msg}}'; sleep 2"]
        resources:
          requests: { cpu: 50m, memory: 64Mi }
          limits:   { cpu: 200m, memory: 128Mi }
```

### 8.3 Argo Rollouts — un `Rollout` canary (reemplazo directo de `Deployment`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: web
  namespace: demo
spec:
  replicas: 5
  revisionHistoryLimit: 3
  selector:
    matchLabels: { app: web }
  template:                        # identical schema to a Deployment's pod template
    metadata:
      labels: { app: web }
    spec:
      containers:
        - name: web
          image: argoproj/rollouts-demo:blue
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 50m, memory: 64Mi }
  strategy:
    canary:
      steps:
        - setWeight: 20            # send 20% of traffic to the new version
        - pause: { duration: 60s } # bake, watch metrics
        - setWeight: 50
        - pause: {}                # pause indefinitely — requires manual `promote`
        - setWeight: 100
```

### 8.4 Argo Events — `EventBus` + `EventSource` + `Sensor`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  jetstream:                       # JetStream is the recommended bus backend
    version: latest
    replicas: 3
---
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: webhook
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000
  webhook:
    push:                          # named event dependency key referenced by the Sensor
      port: "12000"
      endpoint: /push
      method: POST
---
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: webhook
  namespace: argo-events
spec:
  dependencies:
    - name: push-dep
      eventSourceName: webhook
      eventName: push
  triggers:
    - template:
        name: log-trigger
        k8s:
          operation: create
          source:
            resource:
              apiVersion: v1
              kind: Pod
              metadata:
                generateName: reacted-
              spec:
                containers:
                  - name: hello
                    image: alpine:3.20
                    command: [echo, "event received"]
                restartPolicy: Never
```

---

## 9. Instalación y primer contacto por CLI (salida real de terminal)

### 9.1 Instalar Argo CD

```bash
$ kubectl create namespace argocd
namespace/argocd created

$ kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io created
serviceaccount/argocd-application-controller created
...
deployment.apps/argocd-repo-server created
deployment.apps/argocd-server created
statefulset.apps/argocd-application-controller created

$ kubectl -n argocd get pods
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          73s
argocd-applicationset-controller-6b8c9f7d5b-x2n4k   1/1     Running   0          73s
argocd-dex-server-7c4f9d9f8c-mn2pq                  1/1     Running   0          73s
argocd-notifications-controller-5d9b7c8f9-qk4rt     1/1     Running   0          73s
argocd-redis-6f9c7d5b4c-8sw2l                       1/1     Running   0          73s
argocd-repo-server-84b7f9c6d8-lk9vn                 1/1     Running   0          73s
argocd-server-6d8c9f7b5d-w7xq2                      1/1     Running   0          73s
```

### 9.2 Iniciar sesión y desplegar la primera Application por CLI

```bash
$ argocd admin initial-password -n argocd
kR7pT2xQ9mZ4bWnL
 This password must be only used for first time login. We strongly recommend
 you update the password using `argocd account update-password`.

$ argocd login localhost:8080 --username admin --password kR7pT2xQ9mZ4bWnL --insecure
'admin:login' logged in successfully
Context 'localhost:8080' updated

$ argocd app create guestbook \
    --repo https://github.com/argoproj/argocd-example-apps.git \
    --path guestbook \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace guestbook
application 'guestbook' created

$ argocd app get guestbook
Name:               argocd/guestbook
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          guestbook
Repo:               https://github.com/argoproj/argocd-example-apps.git
Target:             HEAD
Path:               guestbook
Sync Policy:        Manual
Sync Status:        OutOfSync from HEAD (53e28ff)
Health Status:      Missing

GROUP  KIND        NAMESPACE  NAME          STATUS     HEALTH   HOOK  MESSAGE
       Service     guestbook  guestbook-ui  OutOfSync  Missing
apps   Deployment  guestbook  guestbook-ui  OutOfSync  Missing

$ argocd app sync guestbook
TIMESTAMP                  GROUP        KIND    NAMESPACE   NAME          STATUS    HEALTH        HOOK  MESSAGE
2026-08-12T14:07:03+00:00  apps  Deployment  guestbook  guestbook-ui  OutOfSync  Missing
2026-08-12T14:07:05+00:00  apps  Deployment  guestbook  guestbook-ui    Synced  Progressing
Operation:          Sync
Phase:              Succeeded
Message:            successfully synced (all tasks run)
```

Notá la transición **OutOfSync/Missing → Synced/Progressing → Synced/Healthy**: dos ejes ortogonales que reporta el controlador — *sync status* (¿coincide lo en vivo con Git?) y *health status* (¿el recurso en vivo realmente funciona?).

### 9.3 Enviar un Workflow

```bash
$ argo submit -n argo hello-dag.yaml --watch
Name:                hello-dag-4kf9x
Namespace:           argo
Status:              Running
Created:             Wed Aug 12 14:12:01 +0000 (now)

STEP                    TEMPLATE  PODNAME                    DURATION  MESSAGE
 ● hello-dag-4kf9x      main
 ├─✔ build              echo      hello-dag-4kf9x-build-...  4s
 └─● test               echo      hello-dag-4kf9x-test-...   2s

$ argo list -n argo
NAME              STATUS      AGE   DURATION   PRIORITY   MESSAGE
hello-dag-4kf9x   Succeeded   30s   9s         0
```

---

## 10. Guía de verificación y diagnóstico de fallos

Esta es la sección que separa a un operador de un usuario. Cada problema de Argo se reduce a una pregunta: **¿está reconciliando el controlador, y qué reporta en `status`?**

### 10.1 Los tres primeros comandos universales

```bash
# 1. Is the controller alive and reconciling?
$ kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-application-controller
NAME                              READY   STATUS    RESTARTS   AGE
argocd-application-controller-0   1/1     Running   0          2h

# 2. What does the CR's status say? (status is the controller's report of reality)
$ kubectl -n argocd get application guestbook -o jsonpath='{.status.sync.status} / {.status.health.status}{"\n"}'
OutOfSync / Degraded

# 3. What is the controller actually logging as it reconciles?
$ kubectl -n argocd logs argocd-application-controller-0 --tail=50 | grep guestbook
```

### 10.2 Taxonomía de fallos de Argo CD

| Síntoma (`status`) | Causa raíz probable | Diagnóstico | Solución |
|---|---|---|---|
| `OutOfSync` y no converge | `syncPolicy.automated` sin configurar, o un recurso ignorado/podado | `argocd app diff guestbook` | Agregar `automated: {selfHeal, prune}` o `argocd app sync` |
| `ComparisonError` | `repo-server` no puede clonar/renderizar (credenciales malas, path malo, error de Helm) | `kubectl -n argocd logs deploy/argocd-repo-server` | Corregir credenciales del repo / `path` / valores del chart |
| `Health: Degraded` | Recurso hijo genuinamente roto (CrashLoop, probe fallida) | `kubectl describe` sobre el hijo; `argocd app resources` | Arreglar la app, no a Argo |
| `Health: Progressing` para siempre | El Deployment nunca alcanza las réplicas listas | `kubectl get deploy -n <ns>` | ¿Pull de imagen? ¿Límites de recursos? ¿Readiness probe? |
| La sincronización tiene éxito pero la deriva regresa al instante | Otro controlador (HPA, webhook mutante) pelea con Argo | `argocd app diff`; revisar `ignoreDifferences` | Agregar `spec.ignoreDifferences` para los campos administrados por el HPA |
| `repo-server` OOMKilled | Un monorepo grande / Helm chart supera la memoria | `kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server` muestra reinicios | Subir la memoria del repo-server; habilitar el caché de manifiestos |

Ejemplo concreto de deriva — HPA vs Argo peleando por `replicas`:

```yaml
# Add to the Application spec so Argo stops reverting the field the HPA owns:
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

### 10.3 Diagnóstico de Argo Workflows

```bash
$ argo get -n argo hello-dag-4kf9x            # per-node status + messages
$ argo logs -n argo hello-dag-4kf9x           # aggregated logs across all pods
$ kubectl -n argo logs deploy/workflow-controller --tail=100   # controller-level errors

# Common failure: workflow stuck Pending → the executor SA lacks RBAC to create pods,
# or no artifact repository is configured. Check:
$ kubectl -n argo describe wf hello-dag-4kf9x | grep -A3 Events
```

| Síntoma | Causa | Solución |
|---|---|---|
| Workflow `Pending`, sin pods | RBAC: la SA no puede crear pods | Otorgar el rol de workflow a la SA |
| Nodo `Error: could not save outputs` | No hay un repositorio de artefactos configurado | Configurar `artifactRepository` (S3/GCS/MinIO) |
| Pods atascados en `Init:0/1` | Problema de init del emissary executor / pull de imagen | `kubectl describe pod` sobre el pod del nodo |

### 10.4 Diagnóstico de Argo Rollouts

```bash
$ kubectl argo rollouts get rollout web -n demo --watch
Name:            web
Namespace:       demo
Status:          ॥ Paused
Strategy:        Canary
  Step:          1/5
  SetWeight:     20
  ActualWeight:  20
...
$ kubectl argo rollouts promote web -n demo     # advance past a manual pause
$ kubectl argo rollouts abort web -n demo       # roll back to the stable ReplicaSet immediately
```

### 10.5 Diagnóstico de Argo Events

```bash
# The bus must be Running before sources/sensors work:
$ kubectl -n argo-events get eventbus,eventsource,sensor
NAME                             AGE
eventbus.argoproj.io/default     10m

NAME                              AGE
eventsource.argoproj.io/webhook   9m

NAME                          AGE
sensor.argoproj.io/webhook    9m

$ kubectl -n argo-events logs deploy/webhook-eventsource   # did the source receive the event?
$ kubectl -n argo-events logs deploy/webhook-sensor        # did the sensor's dependency fire?
```

| Síntoma | Causa | Solución |
|---|---|---|
| El Sensor nunca dispara | EventBus no está Ready, o discrepancia en el `eventName` de la dependencia | Verificar los pods del bus; hacer coincidir `eventSourceName`/`eventName` exactamente |
| El trigger dispara pero no se crea el objeto | La SA del Sensor no tiene RBAC para el `kind` objetivo | Otorgar a la SA del Sensor `create` sobre ese recurso |

### 10.6 Verificación de procedencia / reproducibilidad (higiene de plataforma)

Como cada objeto de Argo es un CR declarativo en Git o etcd, siempre podés responder "¿quién/qué creó esto y puedo reconstruirlo?":

```bash
$ kubectl get application guestbook -n argocd -o yaml \
    | grep -E 'targetRevision|repoURL|path'
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
```

El estado deseado es totalmente rastreable hasta un commit de Git — el equivalente operativo del propio requisito de procedencia del repo: *nada existe de forma no rastreable*.

---

## 11. Resumen consolidado de trade-offs (tabla de repaso para el examen)

| Concepto | Opción izquierda | Opción derecha (la elección de Argo) | Por qué importa |
|---|---|---|---|
| Modelo de extensión | Demonio a medida | **CRD + controller** | Almacenamiento, RBAC, watch, auditoría gratis |
| Reconciliación | Edge-triggered | **Level-triggered** | Autorreparable, seguro ante reinicios, idempotente |
| Estilo de configuración | Imperativo | **Declarativo** | Reproducible, auditable, revertible |
| Dirección de entrega | Push (CI → clúster) | **Pull (agente en el clúster)** | Las credenciales quedan dentro del límite de confianza |
| Fuente de verdad | Estado del clúster / CI | **Git** | Versionado, inmutable, revisable |
| Estrategia de despliegue | `Deployment` RollingUpdate | **Rollout** canary/blue-green + análisis | Condicionado por métricas, abortable, seguro |
| Orquestación | Scripts de shell/Jenkins | CRs **Workflow** DAG | Reintentos, paralelismo, linaje de artefactos |
| Disparador de automatización | Polling por cron | Bus + sensores de **Events** | Lógica de dependencias, muchas fuentes |

---

## 12. Referencias

- Currículum CAPA de la CNCF (alcance autoritativo del examen): https://github.com/cncf/curriculum — específicamente `capa/README.md`: https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
- Certified Argo Project Associate (CAPA) — página de certificación de la Linux Foundation: https://training.linuxfoundation.org/certification/certified-argo-project-associate-capa/
- Sitio paraguas del proyecto Argo: https://argoproj.github.io/
- Perfil del proyecto en la CNCF (madurez graduada): https://www.cncf.io/projects/argo/
- Documentación de Argo CD: https://argo-cd.readthedocs.io/
- Conceptos centrales y arquitectura de Argo CD: https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/
- Documentación de Argo Workflows: https://argo-workflows.readthedocs.io/
- Documentación de Argo Rollouts: https://argo-rollouts.readthedocs.io/
- Documentación de Argo Events: https://argo-events.readthedocs.io/
- Principios de OpenGitOps (GitOps WG de la CNCF): https://opengitops.dev/
- Controladores de Kubernetes y el modelo de reconciliación: https://kubernetes.io/docs/concepts/architecture/controller/
- Custom Resource Definitions de Kubernetes: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Repositorio de código de Argo CD: https://github.com/argoproj/argo-cd
- Repositorio de código de Argo Workflows: https://github.com/argoproj/argo-workflows
- Repositorio de código de Argo Rollouts: https://github.com/argoproj/argo-rollouts
- Repositorio de código de Argo Events: https://github.com/argoproj/argo-events