# Argo Workflows — Dominio 2.1 de CAPA

**Certificación:** Certified Argo Project Associate (CAPA)
**Dominio 2.1 — Argo Workflows** · Peso en el examen: 20%
**Perfil objetivo:** SRE / Arquitecto de Plataforma — internals de producción, trade-offs, manifiestos completos, diagnósticos reales.

Línea base de versión para cada ejemplo de abajo: **Argo Workflows v3.5.x / v3.6.x** corriendo sobre Kubernetes ≥ 1.27. Donde el comportamiento cambió entre releases (defaults del executor, GC de artefactos, hooks) se lo señala explícitamente.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 Qué es realmente Argo Workflows

Argo Workflows es un **motor de workflows container-native implementado enteramente como un conjunto de Custom Resource Definitions (CRDs) de Kubernetes más un controlador que reconcilia**. No hay scheduler externo, ni una base de datos de metadatos separada en el hot path, ni un DSL para compilar. Un workflow es un objeto de Kubernetes; cada *step* de ese workflow es un **Pod**; la orquestación es un loop de reconciliación sobre el custom resource `Workflow`.

Este es el hecho arquitectónico clave del que deriva todo lo demás: **el estado deseado (el DAG), el estado en runtime (los statuses de los nodos) y las unidades de ejecución (los Pods) viven todos en la API de Kubernetes.** El control plane es `etcd` + el API server; Argo agrega un controlador.

```
                    ┌────────────────────────────────────────────┐
                    │              Kubernetes API / etcd           │
                    │  Workflow CR  ─┐   Pods   ConfigMaps  RBAC   │
                    └────────┬───────┼──────────────┬─────────────┘
                             │ watch │ create/patch  │ read
              ┌──────────────▼───────┴──┐   ┌────────▼─────────┐
              │   workflow-controller    │   │   argo-server    │
              │  (reconcile loop, DAG    │   │  (REST/gRPC API, │
              │   scheduler, GC, retries)│   │   UI, archive)   │
              └──────────────┬───────────┘   └──────────────────┘
                             │ spawns one Pod per node
                 ┌───────────▼───────────────────────────┐
                 │  Step Pod                               │
                 │  ┌─────────┐  ┌──────────────────────┐ │
                 │  │  init    │  │  main (your image)   │ │
                 │  │ (load    │  │                      │ │
                 │  │  inputs) │  └──────────────────────┘ │
                 │  └─────────┘  ┌──────────────────────┐ │
                 │               │  wait (executor)     │ │
                 │               │  captures outputs,   │ │
                 │               │  artifacts, exit code│ │
                 │               └──────────────────────┘ │
                 └─────────────────────────────────────────┘
```

### 1.2 El problema de producción que resuelve

Antes de Argo, los equipos que corrían **DAGs de batch, pipelines de ML, CI/CD, ETL de datos y automatización de infraestructura sobre Kubernetes** estaban atados a tres malas opciones:

1. **Objetos `Job`/`CronJob` crudos.** Sin grafo de dependencias. Un pipeline de diez etapas se vuelve diez Jobs pegados con polling frágil de shell (`kubectl wait --for=condition=complete`), sin paso de parámetros compartido, sin handoff de artefactos, sin fan-out, y sin un único objeto que represente "la corrida del pipeline".
2. **Un orquestador externo (Airflow, Luigi, Prefect).** El scheduler y su DB de metadatos viven *fuera* del cluster. Las tareas se envían frecuentemente *como* Pods de Kubernetes (KubernetesPodOperator), así que ahora corrés dos control planes, dos modelos de RBAC y dos dominios de falla. El DAG es código Python que debe empaquetarse y distribuirse por separado del estado del cluster.
3. **Runners de CI (Jenkins, GitLab CI) manejando `kubectl`.** El estado de orquestación vive en el sistema de CI, no en el cluster; los retries, el backoff y la observabilidad son de la herramienta de CI, no Kubernetes-native.

Argo colapsa todo esto: **un solo CRD es el pipeline, el scheduler es un controlador estándar de Kubernetes, y cada control de RBAC/quota/network-policy/PSA que ya corrés aplica sin cambios.** Para un SRE la ganancia operativa es que un workflow se debuggea con exactamente las mismas herramientas que usás para todo lo demás — `kubectl get`, `kubectl describe`, `kubectl logs`, eventos y Prometheus.

### 1.3 Los tres problemas difíciles que Argo tiene que resolver internamente

Un motor de workflows sobre Kubernetes debe responder tres preguntas que los Jobs crudos no pueden:

| Problema | Por qué es difícil en K8s | Mecanismo de Argo |
|---|---|---|
| **Capturar la salida de un step** (un valor de retorno, un parámetro computado, un archivo producido) | El contenedor de un Pod no tiene canal de retorno más allá de su exit code y sus logs | El **wait/executor container** lee `outputs.parameters` desde archivos/paths en el contenedor main y los escribe de vuelta en el node status del `Workflow`; los artefactos se transmiten a un object store |
| **Pasar datos entre steps** | Los Pods son efímeros y están aislados; no hay memoria de step compartida | Los output parameters se guardan en el status del Workflow; los **artefactos** se persisten en S3/GCS/Azure/MinIO y son re-hidratados por el contenedor *init* del step downstream |
| **Saber cuándo un step está realmente terminado** (incluso cuando el runtime mata el contenedor) | El kubelet puede reapear un contenedor antes de que su status sea observado | El **emissary executor** envuelve el proceso main (PID 1 es `argoexec`), así que el exit code exacto se captura incluso bajo eviction, y los outputs se flushean antes de que el Pod termine |

Entender que **los outputs y la finalización los captura un sidecar/wrapper, no Kubernetes en sí**, es el concepto interno más importante para el examen y para debuggear.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Argo Workflows vs. las alternativas

| Dimensión | Argo Workflows | Apache Airflow | Tekton Pipelines | Job/CronJob crudos de K8s |
|---|---|---|---|---|
| **Ubicación del control plane** | CRDs + controlador in-cluster | Scheduler externo + DB de metadatos | CRDs + controlador in-cluster | In-cluster |
| **Unidad de ejecución** | 1 Pod por step | 1 tarea (frecuentemente un Pod vía operator) | 1 Pod por step-container de `TaskRun` | 1 Pod por Job |
| **Definición del DAG** | YAML (`dag`/`steps`) | Código Python | YAML (`Pipeline`) | Ninguna (glue imperativo) |
| **Paso de parámetros/artefactos** | First-class (params + artefactos de object-store) | XCom (chico) + storage externo | `results` (≤4 KB) + `workspaces` (PVC) | Manual |
| **Fan-out (`withItems`/`withParam`)** | Nativo, dinámico | Dynamic task mapping | Matrix (limitado) | Ninguno |
| **Caso de uso primario** | Batch/ML/ETL/CI, pipelines de datos | Data engineering agendado | Pipelines de CI/CD | Jobs one-off/agendados |
| **Fit con GitOps** | Excelente (objetos K8s puros) | Pobre (código + DB) | Excelente | Bueno |
| **Techo de escala** | 10k+ nodos/workflow con tuning | Alto (pero limitado por la DB) | Moderado | N/A |
| **Statefulness** | Controlador stateless; estado en etcd + DB de archive opcional | Stateful (la DB es la source of truth) | Stateless | Stateless |

**Lectura del arquitecto:** elegí Argo cuando el pipeline *es* trabajo Kubernetes-native y querés un solo control plane y GitOps. Elegí Airflow cuando necesitás semántica de scheduling rica, backfills y un ecosistema de data-engineering, y estás dispuesto a correr un segundo sistema stateful. Tekton se solapa con Argo para CI/CD específicamente pero es más débil en fan-out dinámico y DAGs de data-science.

### 2.2 Tipos de template `steps` vs `dag`

| | `steps` | `dag` |
|---|---|---|
| **Modelo** | Lista ordenada de etapas; cada etapa es una lista que corre en paralelo | Grafo de dependencias explícito vía `dependencies`/`depends` |
| **Concurrencia** | Todo en un mismo grupo `[ ... ]` corre concurrentemente; los grupos son secuenciales | Cualquier tarea corre apenas sus dependencias se satisfacen |
| **Mejor para** | Pipelines más bien lineales con etapas paralelas ocasionales | Grafos complejos donde importa la máxima paralelización |
| **Semántica de falla** | Una etapa fallida bloquea la etapa siguiente | Solo las tareas downstream del nodo fallido se bloquean; las ramas independientes continúan |
| **Gating avanzado** | Expresiones `when` | Lógica booleana `depends` (`A.Succeeded && B.Failed`) |

Regla práctica: **`dag` extrae más paralelismo** porque no está limitado por etapas. Usá `steps` cuando la legibilidad de un flujo mayormente secuencial importa más que exprimir concurrencia.

### 2.3 Executors — el trade-off operativo más importante

El executor es el código en el **wait container** que captura los outputs y el exit code. Históricamente Argo shippeaba cuatro (`docker`, `kubelet`, `k8sapi`, `pns`); **desde v3.3 el executor default y recomendado es `emissary`**, y los legacy se removieron en v3.4.

| Executor | Mecanismo | ¿Necesita acceso privilegiado? | ¿Captura el exit code exacto? | Estado |
|---|---|---|---|---|
| **emissary** (default actual) | `argoexec` es PID 1, hace `exec` y reapea el comando del usuario vía un volumen `emissary` compartido | No | Sí | **Recomendado / el único en ≥ v3.4** |
| `docker` (legacy) | Habla con el socket de Docker | Sí (montea `docker.sock`) | Sí | Removido |
| `kubelet` (legacy) | API del Kubelet | Parcial | No (scrapeado de logs) | Removido |
| `k8sapi` (legacy) | `exec`/`logs` de la API de K8s | No | No (depende de los logs) | Removido |
| `pns` (legacy) | Process namespace compartido + polling de `/proc` | `SYS_PTRACE` | Sí | Removido |

**Por qué emissary importa en producción:** no necesita **ningún socket de Docker, ningún securityContext privilegiado, ni acoplamiento con el CRI**, así que funciona sobre containerd, CRI-O, GKE Autopilot y namespaces restrictivos de Pod Security Admission (`restricted`). Sí requiere que tus imágenes de contenedor tengan un command compatible sin shell resoluble en `PATH`, y reserva `/var/run/argo`. Si tu imagen tiene un entrypoint inusual, seteá `command:` explícitamente — la falla clásica de emissary es `Error: failed to find name in PATH`.

### 2.4 Semántica de `retryStrategy.retryPolicy`

| `retryPolicy` | ¿Reintenta ante falla (exit ≠ 0)? | ¿Reintenta ante error (infra: pod borrado, nodo perdido, image pull)? |
|---|---|---|
| `Always` | Sí | Sí |
| `OnFailure` | Sí | No |
| `OnError` | No | Sí |
| `OnTransientError` | No | Solo si el mensaje de error coincide con el allowlist de errores transitorios (`TRANSIENT_ERROR_PATTERN`) |

**El default es `OnFailure`.** Para infraestructura flaky (nodos spot/preemptible) normalmente querés `Always` con un `backoff` acotado. Para bugs de usuario determinísticos, reintentar no tiene sentido — poné un `limit` bajo.

### 2.5 Backends de repositorio de artefactos

| Backend | Tipo de key | Notas |
|---|---|---|
| S3 (AWS o MinIO) | `s3` | IRSA / IAM role o secret con accessKey/secretKey; el más común |
| Google Cloud Storage | `gcs` | Workload Identity o key JSON de service-account |
| Azure Blob | `azure` | Managed identity o secret de connection-string |
| Alibaba OSS | `oss` | |
| HDFS | `hdfs` | Soporta Kerberos |
| Git | `git` | Solo de entrada (clonar un repo como artefacto) |
| HTTP / raw | `http`/`raw` | Solo de entrada; `raw` inlinea contenido literal |

Configurá un repo default en el ConfigMap del controlador, o por-namespace con un ConfigMap `artifact-repositories` y la annotation `workflows.argoproj.io/default-artifact-repository`. **El GC de artefactos** (v3.4+) permite borrar artefactos `OnWorkflowCompletion` / `OnWorkflowDeletion` para que los object stores no crezcan sin límite.

---

## 3. Manifiestos completos, sin recortar, e infraestructura

### 3.1 Instalación (install namespace-scoped)

Argo ofrece dos perfiles de instalación: **cluster install** (`ClusterRole`, observa todos los namespaces) y **namespace install** (`Role`, observa un namespace — la opción multi-tenant-safe). Manifiestos de referencia, pineados por tag:

```bash
$ kubectl create namespace argo
$ kubectl apply -n argo \
  -f https://github.com/argoproj/argo-workflows/releases/download/v3.5.11/namespace-install.yaml
```

### 3.2 `workflow-controller-configmap` — la superficie de control operativo

Este ConfigMap es donde un SRE tunea el controlador: repositorio de artefactos default, paralelismo, recursos del executor, offloading de node status y métricas. Ejemplo completo, con forma de producción:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: workflow-controller-configmap
  namespace: argo
data:
  # --- Global concurrency guardrails ---
  parallelism: "50"                 # max concurrently-running workflows (whole controller)
  namespaceParallelism: "20"        # max concurrently-running workflows per namespace

  # --- Node status offloading: keep large workflows out of the 1.5 MB etcd object limit ---
  # When a Workflow's node status grows past the etcd object size, offload it to Postgres.
  persistence: |
    connectionPool:
      maxIdleConns: 100
      maxOpenConns: 0
    nodeStatusOffLoad: true
    archive: true
    archiveTTL: 7d
    postgresql:
      host: postgres.argo.svc.cluster.local
      port: 5432
      database: argo
      tableName: argo_workflows
      userNameSecret:
        name: argo-postgres-config
        key: username
      passwordSecret:
        name: argo-postgres-config
        key: password

  # --- Default artifact repository (S3 / MinIO) ---
  artifactRepository: |
    archiveLogs: true
    s3:
      endpoint: minio.argo.svc.cluster.local:9000
      bucket: argo-artifacts
      insecure: true                # true only for in-cluster MinIO over HTTP
      keyFormat: "wf/{{workflow.namespace}}/{{workflow.name}}/{{pod.name}}"
      accessKeySecret:
        name: argo-artifacts-s3
        key: accesskey
      secretKeySecret:
        name: argo-artifacts-s3
        key: secretkey

  # --- Executor (emissary) resource footprint applied to the wait/init containers ---
  executor: |
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 512Mi

  # --- Pod GC & workflow TTL defaults ---
  podGC: |
    strategy: OnWorkflowSuccess       # delete step Pods once the wf succeeds (keep on failure to debug)

  # --- Prometheus metrics ---
  metricsConfig: |
    enabled: true
    path: /metrics
    port: 9090

  # --- Default workflow spec merged into every submitted workflow ---
  workflowDefaults: |
    spec:
      ttlStrategy:
        secondsAfterCompletion: 86400   # GC the Workflow object 24h after it finishes
        secondsAfterSuccess: 3600
        secondsAfterFailure: 172800     # keep failures longer for post-mortem
      podGC:
        strategy: OnWorkflowSuccess
      activeDeadlineSeconds: 21600       # hard 6h wall-clock ceiling per workflow
```

Cada key acá es una palanca operativa real. Las dos más consecuentes para escala son **`nodeStatusOffLoad: true`** (los workflows con miles de nodos si no pegan contra el límite de objeto de 1.5 MB de etcd y el controlador loguea `offload node status is not supported`) y **`parallelism`/`namespaceParallelism`** (el guardrail de blast-radius contra un único tenant que satura el cluster).

### 3.3 Un workflow DAG completo de producción

DAG con parámetros, artefactos, retries por-tarea, límites de recursos, un gate `when`, fan-out sobre `withParam` y un exit handler:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: etl-pipeline-
  namespace: data-eng
spec:
  entrypoint: main
  serviceAccountName: argo-workflow          # SA with the RBAC from §3.6
  arguments:
    parameters:
      - name: source-date
        value: "2026-08-12"
  onExit: notify                             # runs whether the wf succeeds or fails

  # Controller-level retry defaults for every template unless overridden
  templateDefaults:
    retryStrategy:
      limit: "3"
      retryPolicy: OnFailure
      backoff:
        duration: "30s"
        factor: "2"
        maxDuration: "5m"

  templates:
    # ---- The DAG that wires the pipeline together ----
    - name: main
      dag:
        tasks:
          - name: extract
            template: extract
            arguments:
              parameters: [{name: date, value: "{{workflow.parameters.source-date}}"}]

          - name: validate
            template: validate
            dependencies: [extract]
            arguments:
              artifacts:
                - name: raw
                  from: "{{tasks.extract.outputs.artifacts.raw}}"

          # Fan-out: one transform task per shard emitted by validate
          - name: transform
            template: transform
            dependencies: [validate]
            withParam: "{{tasks.validate.outputs.parameters.shards}}"
            arguments:
              parameters: [{name: shard, value: "{{item}}"}]

          - name: load
            template: load
            # boolean depends: run only if all transforms succeeded AND validate passed
            depends: "transform.Succeeded && validate.Succeeded"

          - name: publish-report
            template: publish-report
            depends: "load.Succeeded"
            when: "{{workflow.parameters.source-date}} != ''"

    # ---- extract: container template producing an artifact ----
    - name: extract
      inputs:
        parameters: [{name: date}]
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/extract.py]
        args: ["--date", "{{inputs.parameters.date}}", "--out", "/out/raw.parquet"]
        resources:
          requests: {cpu: "500m", memory: 512Mi}
          limits:   {cpu: "1",    memory: 1Gi}
      outputs:
        artifacts:
          - name: raw
            path: /out/raw.parquet

    # ---- validate: script template emitting a JSON list output parameter ----
    - name: validate
      inputs:
        artifacts: [{name: raw, path: /in/raw.parquet}]
      script:
        image: ghcr.io/acme/etl:1.9.2
        command: [python]
        source: |
          import json, pyarrow.parquet as pq
          n = pq.read_table("/in/raw.parquet").num_rows
          assert n > 0, "empty extract"
          shards = [f"shard-{i}" for i in range(4)]
          with open("/tmp/shards.json", "w") as f:
              json.dump(shards, f)
      outputs:
        parameters:
          - name: shards
            valueFrom: {path: /tmp/shards.json}

    # ---- transform: one pod per shard ----
    - name: transform
      inputs:
        parameters: [{name: shard}]
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/transform.py]
        args: ["--shard", "{{inputs.parameters.shard}}"]
      retryStrategy:                          # override: spot-friendly, retry on infra loss too
        limit: "5"
        retryPolicy: Always
        backoff: {duration: "15s", factor: "2", maxDuration: "3m"}

    - name: load
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/load.py]

    - name: publish-report
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/report.py]

    # ---- exit handler: fires on success or failure ----
    - name: notify
      container:
        image: curlimages/curl:8.10.1
        command: [sh, -c]
        args:
          - >
            curl -s -XPOST "$SLACK_URL" -d
            '{"text":"wf {{workflow.name}} finished: {{workflow.status}} in {{workflow.duration}}"}'
        env:
          - name: SLACK_URL
            valueFrom: {secretKeyRef: {name: slack-webhook, key: url}}
```

### 3.4 `WorkflowTemplate` + `CronWorkflow` (reutilizable + agendado)

Los templates reutilizables son el patrón de producción: se escriben una vez, se invocan por referencia, se agendan con un `CronWorkflow`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: nightly-etl
  namespace: data-eng
spec:
  entrypoint: main
  arguments:
    parameters: [{name: source-date, value: "auto"}]
  templates:
    - name: main
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/run.py]
        args: ["--date", "{{workflow.parameters.source-date}}"]
---
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: nightly-etl-cron
  namespace: data-eng
spec:
  schedule: "0 2 * * *"                 # 02:00 daily
  timezone: "America/Argentina/Buenos_Aires"
  concurrencyPolicy: "Forbid"          # never overlap runs
  startingDeadlineSeconds: 300         # miss the window? skip, don't backfill forever
  successfulJobsHistoryLimit: 5
  failedJobsHistoryLimit: 10
  workflowSpec:
    serviceAccountName: argo-workflow
    workflowTemplateRef:
      name: nightly-etl                # invoke the template by reference
    arguments:
      parameters: [{name: source-date, value: "{{workflow.creationTimestamp.Y}}-{{workflow.creationTimestamp.m}}-{{workflow.creationTimestamp.d}}"}]
```

### 3.5 Sincronización — semáforos y mutexes (prevención de deadlocks)

Para limitar cuántos workflows/steps golpean un sistema externo compartido (una base de datos, una API con licencia, un entorno de staging), Argo lee los límites desde un ConfigMap.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argo-semaphores
  namespace: data-eng
data:
  db-writers: "2"        # at most 2 concurrent holders
---
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: gated-
spec:
  entrypoint: main
  synchronization:                    # workflow-level gate
    semaphore:
      configMapKeyRef: {name: argo-semaphores, key: db-writers}
  templates:
    - name: main
      steps:
        - - name: write
            template: writer
    - name: writer
      synchronization:                # step-level mutex: strictly one at a time
        mutex: {name: staging-env}
      container: {image: busybox, command: [sh, -c, "echo writing; sleep 10"]}
```

### 3.6 RBAC para el ServiceAccount del workflow

Cada step Pod corre bajo un ServiceAccount cuyo token usa el executor para patchear su propio Pod y el node status del Workflow, y (para templates `resource`) para crear/obtener objetos de Kubernetes. El mínimo para un workflow de container/DAG normal:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: argo-workflow, namespace: data-eng}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: argo-workflow, namespace: data-eng}
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, watch, patch]                 # executor patches its own pod
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get, watch]
  - apiGroups: [argoproj.io]
    resources: [workflowtaskresults]
    verbs: [create, patch]                      # emissary writes results here (v3.4+)
  - apiGroups: [argoproj.io]
    resources: [workflowtasksets, workflowtasksets/status]
    verbs: [list, watch, patch]                 # only for agent/HTTP templates
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: argo-workflow, namespace: data-eng}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: argo-workflow}
subjects: [{kind: ServiceAccount, name: argo-workflow, namespace: data-eng}]
```

> **Falla común de producción:** olvidarse de `workflowtaskresults: [create, patch]`. En v3.4+, emissary reporta los outputs vía un objeto `WorkflowTaskResult`; sin esta regla los steps corren pero el controlador loguea `Failed to patch WorkflowTaskResult ... is forbidden` y los outputs/exit codes nunca se propagan, dejando los nodos trabados en `Running`.

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Submit y watch

```bash
$ argo submit -n data-eng etl.yaml --watch
Name:                etl-pipeline-8k2vq
Namespace:           data-eng
ServiceAccount:      argo-workflow
Status:              Running
Created:             Wed Aug 12 02:00:01 -0300 (10 seconds ago)
Started:             Wed Aug 12 02:00:01 -0300 (10 seconds ago)
Duration:            10 seconds
Progress:            2/6
Parameters:
  source-date:       2026-08-12

STEP                        TEMPLATE         PODNAME                        DURATION  MESSAGE
 ● etl-pipeline-8k2vq       main
 ├───✔ extract              extract          etl-pipeline-8k2vq-1837471290  6s
 ├───● validate             validate         etl-pipeline-8k2vq-2948562301  3s
 ├───○ transform            transform
 ├───○ load                 load
 └───○ publish-report       publish-report
```

Glifos de nodo: `✔` succeeded, `●` running, `○` pending, `✖`/`✘` failed, `◷` retrying.

### 4.2 List, get, logs

```bash
$ argo list -n data-eng
NAME                 STATUS      AGE   DURATION   PRIORITY   MESSAGE
etl-pipeline-8k2vq   Succeeded   4m    1m         0
gated-abc12          Running     30s   30s        0

$ argo get -n data-eng etl-pipeline-8k2vq -o wide
Name:                etl-pipeline-8k2vq
Status:              Succeeded
Conditions:
 PodRunning          False
 Completed           True
Duration:            1 minute 12 seconds
ResourcesDuration:   4m3s*(1 cpu),9m12s*(100Mi memory)

$ argo logs -n data-eng etl-pipeline-8k2vq --follow
etl-pipeline-8k2vq-1837471290: 2026-08-12T05:00:07Z INFO  extracted 1.2M rows -> /out/raw.parquet
etl-pipeline-8k2vq-2948562301: 2026-08-12T05:00:11Z INFO  validation ok, 4 shards
etl-pipeline-8k2vq-3051673412: 2026-08-12T05:00:20Z INFO  transform shard-0 done
```

### 4.3 Retry, resubmit, stop, terminate — conocé la diferencia

```bash
# retry: re-run a FAILED workflow, reusing successful nodes (memoized), only from failure points
$ argo retry -n data-eng etl-pipeline-8k2vq
Name:   etl-pipeline-8k2vq   Status: Running (retried)

# resubmit: brand-new run from the same spec (new name, nothing reused)
$ argo resubmit -n data-eng etl-pipeline-8k2vq
Name:   etl-pipeline-9m4xp

# stop: graceful — runs the onExit handler, then stops
$ argo stop -n data-eng gated-abc12

# terminate: hard — kills everything immediately, NO exit handler
$ argo terminate -n data-eng gated-abc12
```

| Comando | ¿Corre el exit handler? | ¿Reutiliza nodos previos? | Resultado |
|---|---|---|---|
| `argo retry` | sí | sí (nodos exitosos) | el mismo objeto Workflow se reanuda |
| `argo resubmit` | n/a | no | nuevo objeto Workflow |
| `argo stop` | **sí** | — | shutdown graceful |
| `argo terminate` | **no** | — | kill inmediato |

### 4.4 Lint antes de shippear, y gates de suspend/resume

```bash
$ argo lint -n data-eng etl.yaml
✔ etl.yaml is valid

$ argo submit -n data-eng approval-wf.yaml            # contains a `suspend` template
$ argo resume -n data-eng approval-wf-xyz --node-field-selector displayName=wait-for-approval
```

### 4.5 La vista Kubernetes-native (sin necesidad del CLI de argo)

Todo es visible a través de `kubectl` porque todo son CRDs:

```bash
$ kubectl get wf -n data-eng
NAME                 STATUS      AGE
etl-pipeline-8k2vq   Succeeded   5m

$ kubectl get pods -n data-eng -l workflows.argoproj.io/workflow=etl-pipeline-8k2vq
NAME                            READY   STATUS      RESTARTS   AGE
etl-pipeline-8k2vq-1837471290   0/2     Completed   0          5m
etl-pipeline-8k2vq-2948562301   0/2     Completed   0          5m
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 La escalera de diagnóstico

Siempre debuggeá de arriba hacia abajo: **status del Workflow → mensaje del nodo → eventos del Pod → logs del contenedor → logs del controlador.**

```bash
# 1. Why did the workflow fail? Read the node-level message
$ argo get -n data-eng etl-pipeline-8k2vq
   └─✖ transform(0:shard-0)  transform  ...  Error (exit code 137)   # 137 = OOMKilled

# 2. Confirm at the Pod level
$ kubectl describe pod -n data-eng etl-pipeline-8k2vq-3051673412
  State:      Terminated
  Reason:     OOMKilled
  Exit Code:  137
  Events:
    Warning  Failed   kubelet  Memory cgroup out of memory: killed process

# 3. Read the failing container's logs
$ kubectl logs -n data-eng etl-pipeline-8k2vq-3051673412 -c main

# 4. If nodes are stuck (not failing), read the CONTROLLER
$ kubectl logs -n argo deploy/workflow-controller --tail=100 | grep -i error
```

### 5.2 Catálogo de fallas — síntoma → causa → solución

| Síntoma / mensaje | Causa raíz | Solución |
|---|---|---|
| Pod trabado en `Pending`, el nodo nunca arranca | No schedulable: sin CPU/mem, taints, o PVC unbound | `kubectl describe pod` → leé los Events; ajustá `resources`/tolerations/nodeSelector |
| `Error: failed to find name in PATH` | emissary no puede resolver el comando | Seteá `command:` explícitamente; asegurate de que el binario esté en `PATH` |
| Nodo trabado en `Running` para siempre; el controlador loguea `Failed to patch WorkflowTaskResult ... forbidden` | Falta el RBAC de `workflowtaskresults` | Agregá la regla de RBAC de §3.6 |
| `failed to save outputs: ... no such file or directory` | El `outputs.artifacts.path` / `outputs.parameters.valueFrom.path` no existe en el contenedor | Verificá que el step realmente escriba en ese path exacto |
| `failed to put file: ... 403 AccessDenied` | Credenciales/IAM del repo de artefactos mal | Chequeá el secret de S3 / el role de IRSA; probá con un `argo submit` de un wf con raw-artifact |
| exit code `137` | OOMKilled | Subí el `limits` de memoria, o shardeá el trabajo |
| exit code `143` | SIGTERM (terminated/deadline) | Chequeá `activeDeadlineSeconds` y los eventos de `terminate` |
| Workflow `Error`: `offload node status is not supported` | El node status excedió los 1.5 MB de etcd con offload deshabilitado | Habilitá `nodeStatusOffLoad: true` + Postgres/MySQL |
| Los workflows se encolan y nunca arrancan | Se alcanzó el cap de `parallelism`/`namespaceParallelism`, o hay un semáforo/mutex tomado | Inspeccioná `synchronization.status`; subí los límites o liberá el lock |
| `ImagePullBackOff` en el wait/init container | La imagen del executor no es pulleable (airgap/registry) | Espejá `quay.io/argoproj/argoexec`; seteá `executor.image`/`imagePullSecrets` |
| El CronWorkflow nunca dispara | `schedule`/`timezone` malos, o `concurrencyPolicy: Forbid` con una corrida previa trabada | `kubectl get cronwf -o yaml` → leé `.status`; chequeá `startingDeadlineSeconds` |

### 5.3 Verificar que el control plane esté sano

```bash
$ kubectl get deploy -n argo
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
argo-server           1/1     1            1           12d
workflow-controller   1/1     1            1           12d

# Controller leader-election & reconcile health via metrics
$ kubectl -n argo port-forward deploy/workflow-controller 9090:9090 &
$ curl -s localhost:9090/metrics | grep -E 'argo_workflows_(count|error_count|queue_depth)'
argo_workflows_count{status="Running"} 3
argo_workflows_count{status="Failed"} 1
argo_workflows_error_count 0
argo_workflows_workers_busy_count{worker_type="workflow_queue"} 2
```

Métricas de SLO clave para alertar: `argo_workflows_error_count` (errores internos del controlador), `argo_workflows_queue_depth_count` (backlog de reconciliación — si sube significa que el controlador se está quedando atrás) y `argo_workflows_k8s_request_total{status_code!="200"}` (throttling de la API). Un `workflow_ttl_queue` con depth creciente junto con conteos crecientes de objetos Workflow significa que el GC no está dando abasto — chequeá `ttlStrategy`.

### 5.4 Harness de reproducción rápida para problemas de artefactos/RBAC

Antes de culpar a un pipeline de 6 etapas, probá la plomería con un workflow de una línea:

```bash
$ argo submit -n data-eng --watch - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {generateName: smoke-}
spec:
  entrypoint: main
  serviceAccountName: argo-workflow
  templates:
    - name: main
      container: {image: busybox, command: [sh, -c, "echo hi > /tmp/o.txt"]}
      outputs:
        artifacts: [{name: o, path: /tmp/o.txt}]     # exercises the artifact repo end-to-end
EOF
```

Si este smoke test sube su artefacto y llega a `Succeeded`, el executor, el RBAC y el repositorio de artefactos están todos correctos — la falla está en tu pipeline, no en la plataforma.

---

## 6. Referencias

- Argo Workflows — Documentación oficial: https://argo-workflows.readthedocs.io/en/stable/
- Argo Workflows — Repositorio de GitHub y releases: https://github.com/argoproj/argo-workflows
- Referencia de campos de Workflow / template: https://argo-workflows.readthedocs.io/en/stable/fields/
- Conceptos centrales (Workflow, Template, node): https://argo-workflows.readthedocs.io/en/stable/core-concepts/
- Workflow templates: https://argo-workflows.readthedocs.io/en/stable/workflow-templates/
- Cron workflows: https://argo-workflows.readthedocs.io/en/stable/cron-workflows/
- Executors (emissary): https://argo-workflows.readthedocs.io/en/stable/workflow-executors/
- Configurar repositorios de artefactos: https://argo-workflows.readthedocs.io/en/stable/configure-artifact-repository/
- Retries: https://argo-workflows.readthedocs.io/en/stable/retries/
- Sincronización (semáforos y mutexes): https://argo-workflows.readthedocs.io/en/stable/synchronization/
- Workflow controller ConfigMap: https://argo-workflows.readthedocs.io/en/stable/workflow-controller-configmap/
- Node status offloading y archive: https://argo-workflows.readthedocs.io/en/stable/offloading-large-workflows/
- Referencia del CLI de Argo: https://argo-workflows.readthedocs.io/en/stable/cli/argo/
- Métricas de Prometheus: https://argo-workflows.readthedocs.io/en/stable/metrics/
- Currículum de CAPA (CNCF): https://github.com/cncf/curriculum/blob/master/capa/README.md
- Proyecto Argo (CNCF Graduated): https://www.cncf.io/projects/argo/