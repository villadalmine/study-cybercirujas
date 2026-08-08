# 4.3 Denial of Service

## 1. Motivación: por qué el DoS es un problema *arquitectónico*, no solo de tráfico

En el imaginario clásico, un Denial of Service es un flood de paquetes desde afuera. En un cluster de Kubernetes ese es el caso *menos* interesante y el más fácil de mitigar (lo absorbe el load balancer o el WAF antes de tocar el data plane). El DoS que realmente tumba producción en cloud native nace **adentro**, y su causa raíz es una decisión de diseño de la plataforma: Kubernetes es, por definición, un sistema **multi-tenant que comparte kernel y comparte control plane**.

Dos hechos arquitectónicos generan toda la superficie de DoS:

1. **Los nodos comparten un solo kernel de Linux.** Los contenedores no son VMs: son procesos aislados por namespaces y acotados por cgroups. Si un Pod agota un recurso *del kernel que no está acotado por cgroup* (PIDs, inodos, conntrack entries, file descriptors, memoria del kernel para page cache), degrada a **todos** los Pods del nodo, incluidos los `system` daemons (kubelet, container runtime, CNI). Esto es el *noisy neighbor* elevado a incidente.

2. **Todos los tenants comparten un solo API server y un solo etcd.** El control plane no tiene sharding por namespace. Un `LIST pods` sin paginar sobre 200k objetos, un controller con un hot-loop de `PATCH`, o un ValidatingWebhook que agrega latencia a cada `CREATE`, degradan el plano de control para el cluster entero. Cuando el API server se satura, no podés ni siquiera *responder* al incidente: `kubectl` deja de contestar.

El threat model de KCSA trata DoS como una categoría propia precisamente porque la mitigación no es un firewall: es **capacity management defensivo**. La pregunta de diseño es siempre la misma: *¿qué recurso finito puede agotar un tenant, y qué mecanismo del sistema le pone un techo antes de que el agotamiento propague?*

### El blast radius, formalizado

| Recurso agotado | Acotado por | Radio de impacto si no hay límite | Mecanismo defensivo primario |
|---|---|---|---|
| CPU | cgroup (cpu.cfs) | El propio Pod (throttling, no crash) | `limits.cpu` + `LimitRange` |
| Memory (RSS) | cgroup (memory.max) | El nodo (OOMKill del proceso más caro por `oom_score_adj`) | `limits.memory` + QoS `Guaranteed` |
| PIDs | cgroup pids.max **o** `SupportPodPidsLimit` | El nodo entero (no se pueden hacer `fork`) | `podPidsLimit` en kubelet + `LimitRange` |
| Ephemeral storage | Sin cgroup — solo eviction | El nodo (disk pressure → eviction masiva) | `limits.ephemeral-storage` + `ResourceQuota` |
| Inodos / conntrack | **No acotado por Pod** | El nodo entero | Node-level `sysctl` + monitoreo |
| API server (QPS, memoria) | API Priority & Fairness | El cluster entero | APF (`FlowSchema` + `PriorityLevelConfiguration`) |
| etcd (tamaño DB) | `--quota-backend-bytes` | El cluster entero (etcd read-only al superar quota) | Quota de objetos vía `ResourceQuota`, compaction |

Fijate en las dos filas sin cgroup: inodos y conntrack son los vectores que la gente olvida porque no aparecen en `kubectl top`.

---

## 2. Taxonomía de vectores: data plane vs. control plane

```
                        DENIAL OF SERVICE EN KUBERNETES
                                     │
            ┌────────────────────────┴────────────────────────┐
            │                                                  │
      DATA PLANE (nodos)                              CONTROL PLANE
            │                                                  │
   ┌────────┼────────┬──────────┐              ┌───────────────┼──────────────┐
   │        │        │          │              │               │              │
  CPU/     PID     Ephemeral  Kernel        API server       etcd        Admission
  Mem   exhaustion  storage   objects       flooding      exhaustion     webhooks
 (cgroup) (fork    (disk      (conntrack,   (APF, QPS)    (DB size,     (latency
          bomb)    pressure)   inodes)                    watch load)    injection)
```

La distinción es operativamente crítica porque **la telemetría y la mitigación viven en capas distintas**:

| Dimensión | Data plane DoS | Control plane DoS |
|---|---|---|
| Quién lo sufre | Pods co-residentes en el nodo | Todo el cluster |
| Señal de detección | `kubectl top nodes`, eviction events, OOMKilled | Latencia de `apiserver_request_duration`, APF rejections |
| Mecanismo de control | `LimitRange`, `ResourceQuota`, QoS | API Priority & Fairness, request size limits |
| Tiempo de detección típico | Segundos–minutos (crash visible) | Puede ser silencioso (degradación de latencia) |
| Recuperación | Reschedule del Pod ofensor | Requiere acceso al control plane… que está caído |
| Prevención estructural | Admission (quotas obligatorias) | Configuración del kube-apiserver |

---

## 3. Data plane: resource exhaustion en el nodo

### 3.1 El modelo de requests, limits y QoS

Kubernetes deriva la **Quality of Service class** de un Pod exclusivamente de la relación entre `requests` y `limits`. Esta clase decide *el orden en que los Pods mueren bajo presión* — es literalmente el sistema de defensa contra DoS por eviction.

| QoS Class | Condición | Comportamiento bajo memory pressure | Uso en producción |
|---|---|---|---|
| `Guaranteed` | `requests == limits` para **todos** los recursos y containers | Se mata **último**; `oom_score_adj = -997` | Cargas críticas, control plane, DBs |
| `Burstable` | Tiene requests, pero `requests < limits` (o falta en algún container) | Se mata **según uso vs. request** | Mayoría de las apps stateless |
| `BestEffort` | Sin requests ni limits | Se mata **primero**; `oom_score_adj = 1000` | Nunca en producción — es el primer vector de DoS |

Un Pod `BestEffort` es un DoS esperando a pasar: consume lo que quiera hasta que el kernel lo mate, y mientras tanto puede empujar a nodos enteros a memory pressure disparando eviction de vecinos `Burstable`.

Verificación de la QoS efectiva:

```console
$ kubectl get pod web-api-7d9f -o jsonpath='{.status.qosClass}{"\n"}'
Burstable

$ kubectl get pod web-api-7d9f -o jsonpath='{range .spec.containers[*]}{.name}: req={.resources.requests} lim={.resources.limits}{"\n"}{end}'
app: req={"cpu":"250m","memory":"256Mi"} lim={"cpu":"1","memory":"512Mi"}
```

#### La asimetría CPU vs. memoria (el trade-off que hay que entender)

No son simétricos y confundirlos causa incidentes:

| | CPU limit | Memory limit |
|---|---|---|
| Recurso | Compresible | **In**compresible |
| Al alcanzar el límite | **Throttling** (CFS quota) — el proceso se ralentiza | **OOMKill** — el proceso muere |
| Efecto en latencia | p99 se dispara, timeouts en cascada | Crash + restart loop |
| Métrica de detección | `container_cpu_cfs_throttled_periods_total` | `container_oom_events_total`, exit code 137 |

Consecuencia de diseño ampliamente debatida: **poner `limits.cpu` puede *causar* un self-DoS** por throttling agresivo del CFS, incluso con CPU libre en el nodo. Muchos SRE dejan `requests.cpu` (para scheduling) y omiten `limits.cpu`, confiando en el `requests` de los vecinos para el aislamiento. En cambio `limits.memory` es casi siempre obligatorio: sin él, un memory leak es un DoS de nodo.

```console
# Síntoma de CPU throttling — el Pod está "lento" sin razón aparente
$ kubectl exec web-api-7d9f -- cat /sys/fs/cgroup/cpu.stat
usage_usec 4821334000
nr_periods 892011
nr_throttled 511043          # 57% de los períodos fueron throttled
throttled_usec 88421990000   # 88 segundos acumulados de throttling

# Un OOMKill deja huella en el estado del container
$ kubectl get pod cache-0 -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
{"exitCode":137,"reason":"OOMKilled","startedAt":"2026-08-07T09:12:03Z","finishedAt":"2026-08-07T09:41:55Z"}
```

### 3.2 LimitRange: el techo por-objeto y los defaults obligatorios

`ResourceQuota` limita el **agregado por namespace**; `LimitRange` actúa **por Pod/Container** y — crucialmente — **inyecta defaults**. Sin defaults, cualquier Pod creado sin `limits` es `BestEffort` y burla la quota agregada. Los dos son complementarios y ambos son necesarios.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: sane-defaults
  namespace: team-payments
spec:
  limits:
    # Aplica a cada Container individual
    - type: Container
      # Default de limits si el manifiesto no los especifica
      default:
        cpu: "500m"
        memory: "512Mi"
        ephemeral-storage: "1Gi"
      # Default de requests si no se especifican
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
        ephemeral-storage: "256Mi"
      # Techo absoluto: ningún Container puede pedir/limitar más que esto
      max:
        cpu: "2"
        memory: "2Gi"
        ephemeral-storage: "4Gi"
      # Piso absoluto: evita requests ridículamente bajos que rompen scheduling
      min:
        cpu: "50m"
        memory: "64Mi"
      # Ratio máximo limit/request — fuerza QoS cercana a Guaranteed
      # limit no puede ser más de 4x el request (frena el over-commit abusivo)
      maxLimitRequestRatio:
        cpu: "4"
        memory: "2"
    # Aplica al Pod completo (suma de sus containers)
    - type: Pod
      max:
        cpu: "4"
        memory: "4Gi"
    # Techo de tamaño para PVCs solicitados en este namespace
    - type: PersistentVolumeClaim
      max:
        storage: "50Gi"
      min:
        storage: "1Gi"
```

El campo que más DoS previene es `maxLimitRequestRatio`: acota el over-commit. Un ratio de memoria de 2 significa que `limits.memory` nunca puede superar 2× el `requests.memory`, lo que impide que un tenant reserve poco (para pasar el scheduler) y luego reviente el nodo.

### 3.3 ResourceQuota: el techo agregado por namespace

Este es el mecanismo primario para acotar el consumo total de un tenant. Nótese que puede acotar **conteo de objetos** además de compute — el conteo de objetos es el vector de DoS contra etcd (ver §4.2).

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-payments-quota
  namespace: team-payments
spec:
  hard:
    # --- Compute agregado ---
    requests.cpu: "20"
    requests.memory: "40Gi"
    limits.cpu: "40"
    limits.memory: "80Gi"
    requests.ephemeral-storage: "50Gi"
    limits.ephemeral-storage: "100Gi"
    # --- Conteo de objetos: defensa contra etcd exhaustion ---
    pods: "150"
    services: "30"
    services.loadbalancers: "3"      # cada LB cuesta $$ y una IP pública
    services.nodeports: "0"          # prohíbe NodePort (superficie de ataque)
    configmaps: "100"
    secrets: "100"
    persistentvolumeclaims: "40"
    replicationcontrollers: "0"
    count/deployments.apps: "50"
    count/jobs.batch: "100"
    count/cronjobs.batch: "20"
    # --- Storage por StorageClass ---
    gold.storageclass.storage.k8s.io/requests.storage: "100Gi"
```

Cuando un `ResourceQuota` con recursos de compute está activo, el admission controller **exige** que *todo* Pod declare requests/limits para esos recursos — de lo contrario el `CREATE` es rechazado. Esto es lo que hace obligatorio al `LimitRange`: sin él, todos los Pods sin límites explícitos fallarían al crearse.

```console
$ kubectl apply -f pod-sin-limits.yaml
Error from server (Forbidden): error when creating "pod-sin-limits.yaml": pods "stress"
is forbidden: failed quota: team-payments-quota: must specify limits.cpu for: app;
limits.memory for: app; requests.cpu for: app; requests.memory for: app

$ kubectl describe resourcequota team-payments-quota -n team-payments
Name:                   team-payments-quota
Namespace:              team-payments
Resource                Used   Hard
--------                ----   ----
count/deployments.apps  12     50
limits.cpu              18     40
limits.memory           31Gi   80Gi
persistentvolumeclaims  8      40
pods                    47     150
requests.cpu            9500m  20
requests.memory         19Gi   40Gi
secrets                 23     100
services.loadbalancers  1      3
```

### 3.4 El fork bomb y el PID exhaustion

Los PIDs son un recurso **global del kernel del nodo**. Un fork bomb (`:(){ :|:& };:`) dentro de un contenedor, sin límite de PIDs, agota la tabla de procesos del *nodo entero* — el kubelet no puede hacer `fork` para lanzar `exec` probes, el runtime no arranca contenedores, y el nodo entra en `NotReady`.

Hay dos capas de defensa, ambas configurables:

1. **Node-level (`--pod-max-pids` / `podPidsLimit` en KubeletConfiguration):** techo por Pod, aplicado por el kubelet vía cgroup `pids.max`. Es la defensa fuerte porque no depende de que el tenant coopere.
2. **Node allocatable reservation (`SystemReserved` / `KubeReserved`):** reserva PIDs para los daemons del sistema.

```yaml
# /var/lib/kubelet/config.yaml  (KubeletConfiguration)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Techo de PIDs por Pod — la defensa principal contra fork bombs
podPidsLimit: 4096
# Eviction cuando los PIDs del nodo se agotan
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
  pid.available: "2048"        # evict si quedan < 2048 PIDs libres en el nodo
evictionSoft:
  memory.available: "1Gi"
  pid.available: "4096"
evictionSoftGracePeriod:
  memory.available: "1m30s"
  pid.available: "1m"
# Reserva de recursos para daemons del sistema (fuera de allocatable)
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  pid: "1000"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  pid: "1000"
```

Verificación del límite efectivo dentro del cgroup del Pod:

```console
$ kubectl exec stress-pod -- cat /sys/fs/cgroup/pids.max
4096

$ kubectl exec stress-pod -- cat /sys/fs/cgroup/pids.current
38

# Un fork bomb con límite de PIDs falla contenido, sin tumbar el nodo:
$ kubectl exec stress-pod -- sh -c ':(){ :|:& };:'
sh: fork: retry: Resource temporarily unavailable
sh: fork: retry: Resource temporarily unavailable
sh: fork: Resource temporarily unavailable
command terminated with exit code 1

$ kubectl get node worker-3
NAME       STATUS   ROLES    AGE   VERSION
worker-3   Ready    <none>   82d   v1.31.2      # sigue Ready — el límite contuvo el ataque
```

Y el mismo Pod (`type: Pod`) puede recibir un límite duro de PIDs desde `LimitRange` no directamente — el campo pid no está en LimitRange, por eso `podPidsLimit` a nivel kubelet es el mecanismo canónico. Es una configuración de nodo, no de namespace: no confíes en que el tenant la ponga.

### 3.5 Ephemeral storage y disk pressure

El ephemeral storage (`emptyDir`, logs de contenedor, capa writable de la imagen) **no está acotado por un cgroup de bloques** en la mayoría de las configuraciones. El único control es `limits.ephemeral-storage` evaluado por el kubelet mediante *polling* periódico (cada 10s por defecto), no en tiempo real. Esto crea una ventana: un `dd if=/dev/zero of=/tmp/fill` puede llenar el disco *entre* dos ciclos de polling y disparar **node disk pressure**, que evicta Pods `BestEffort` y `Burstable` en cascada.

```console
$ kubectl describe node worker-1 | grep -A6 Conditions
Conditions:
  Type             Status    Reason                       Message
  ----             ------    ------                       -------
  MemoryPressure   False     KubeletHasSufficientMemory   kubelet has sufficient memory available
  DiskPressure     True      KubeletHasDiskPressure       kubelet has disk pressure
  PIDPressure      False     KubeletHasSufficientPID      kubelet has sufficient PID available
  Ready            True      KubeletReady                 kubelet is posting ready status

$ kubectl get events --field-selector reason=Evicted -n team-payments
LAST SEEN   TYPE      REASON    OBJECT              MESSAGE
2m14s       Warning   Evicted   pod/worker-batch-0  The node was low on resource: ephemeral-storage.
                                                     Container app was using 8.2Gi, request is 1Gi.
```

La defensa combina `limits.ephemeral-storage` por Pod (evict al Pod ofensor y no a los vecinos), `sizeLimit` en `emptyDir`, y `evictionHard` sobre `nodefs.inodesFree` (los inodos se agotan antes que los bytes con millones de archivitos):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bounded-scratch
  namespace: team-payments
spec:
  containers:
    - name: app
      image: registry.internal/batch:1.4.2
      resources:
        requests:
          ephemeral-storage: "1Gi"
        limits:
          ephemeral-storage: "2Gi"     # kubelet evicta este Pod al superar 2Gi
      volumeMounts:
        - name: scratch
          mountPath: /tmp
  volumes:
    - name: scratch
      emptyDir:
        sizeLimit: "1Gi"               # acota el tmpfs/dir a 1Gi independientemente
```

---

## 4. Control plane: el DoS que te deja sin herramientas para responder

### 4.1 API Priority and Fairness (APF)

Antes de APF, el kube-apiserver tenía dos flags globales de rate limiting (`--max-requests-inflight`, `--max-mutating-requests-inflight`). El problema arquitectónico: un solo cliente abusivo (un controller en hot-loop, un `kubectl get pods --all-namespaces --watch` masivo) consumía *todos* los slots inflight y ahogaba a los componentes críticos — incluido el propio `kube-scheduler` y el `leader election`. Un DoS accidental por un controller mal escrito tumbaba el cluster.

**API Priority and Fairness** (GA desde v1.29, grupo `flowcontrol.apiserver.k8s.io/v1`) reemplaza esos flags por un sistema de *fair queuing* con aislamiento. Dos objetos:

- **`PriorityLevelConfiguration`**: define un "carril" con una cuota de concurrencia (concurrency shares). Los carriles se aíslan entre sí — saturar uno no roba capacidad a otro.
- **`FlowSchema`**: reglas que clasifican cada request (por usuario, ServiceAccount, verbo, recurso) y lo asignan a un PriorityLevel, subdividiéndolo en *flows* con un `distinguisher` (p.ej. por usuario) para fair queuing *dentro* del carril.

```
Request entrante
      │
      ▼
┌─────────────┐   match por (subject, verb, resource, namespace)
│ FlowSchema  │──────────────────────────────────────────────┐
└─────────────┘                                               │
      │ asigna a priorityLevel + flowDistinguisher            │
      ▼                                                       ▼
┌──────────────────────┐          ┌──────────────────────────────┐
│ PriorityLevel:       │          │ PriorityLevel:               │
│ "workload-high"      │          │ "workload-low" (batch/CI)    │
│ shares=100           │          │ shares=30                    │
│ ┌────┬────┬────┐     │          │ ┌────┬────┬────┐             │
│ │flow│flow│flow│ ... │          │ │flow│flow│flow│  (queued)   │
│ └────┴────┴────┘     │          │ └────┴────┴────┘             │
│ fair queuing         │          │ satura AISLADO — no afecta   │
└──────────────────────┘          │ a workload-high              │
                                   └──────────────────────────────┘
```

Los niveles built-in `system`, `leader-election`, `node-high`, `workload-high`, `workload-low`, `global-default` y `catch-all` ya existen. El nivel especial `exempt` **no** hace throttling — reservalo con extremo cuidado (`system:masters` cae ahí, lo que significa que un admin con hot-loop *sí* puede DoS-ear).

Un `FlowSchema` custom para acotar un tenant CI/CD ruidoso a un carril de baja prioridad y aislado:

```yaml
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: ci-restricted
spec:
  type: Limited
  limited:
    # Porción de la concurrencia total del apiserver asignada a este carril
    nominalConcurrencyShares: 20
    # Qué pasa cuando el carril se llena
    limitResponse:
      type: Queue          # encolar en vez de rechazar (Reject es el otro modo)
      queuing:
        queues: 64         # nº de colas para fair queuing (shuffle sharding)
        queueLengthLimit: 50
        handSize: 6        # requests por flow antes de rebalancear
    # Cuánta concurrencia puede "prestar" a otros carriles y tomar prestada
    borrowingLimitPercent: 0     # 0 = no puede robar capacidad a otros
    lendablePercent: 50
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: ci-pipeline-flow
spec:
  # Menor número = mayor precedencia de matching (se evalúan en orden)
  matchingPrecedence: 900
  priorityLevelConfiguration:
    name: ci-restricted
  # Sub-particiona el carril por usuario, para fair queuing entre bots CI
  distinguisherMethod:
    type: ByUser
  rules:
    - subjects:
        - kind: ServiceAccount
          serviceAccount:
            name: jenkins-runner
            namespace: ci-cd
      resourceRules:
        - verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
          apiGroups: ["*"]
          resources: ["*"]
          namespaces: ["*"]
```

Diagnóstico de APF en un incidente — las métricas que importan:

```console
# ¿Se están rechazando o encolando requests? (señal de saturación de un carril)
$ kubectl get --raw '/metrics' | grep apiserver_flowcontrol_rejected_requests_total
apiserver_flowcontrol_rejected_requests_total{flow_schema="ci-pipeline-flow",priority_level="ci-restricted",reason="queue-full"} 1843

# Profundidad de cola por priority level en tiempo real
$ kubectl get --raw '/metrics' | grep apiserver_flowcontrol_current_inqueue_requests
apiserver_flowcontrol_current_inqueue_requests{flow_schema="ci-pipeline-flow",priority_level="ci-restricted"} 47
apiserver_flowcontrol_current_inqueue_requests{flow_schema="workload-high",priority_level="workload-high"} 0

# Concurrencia en uso vs. límite por carril
$ kubectl get --raw '/metrics' | grep apiserver_flowcontrol_request_concurrency_limit
apiserver_flowcontrol_request_concurrency_limit{priority_level="ci-restricted"} 60
apiserver_flowcontrol_request_concurrency_limit{priority_level="workload-high"} 240

# Vista declarativa de los carriles
$ kubectl get prioritylevelconfigurations
NAME               TYPE      NOMINALCONCURRENCYSHARES   QUEUES   HANDSIZE   QUEUELENGTHLIMIT
catch-all          Limited   5                          <none>   <none>     <none>
ci-restricted      Limited   20                         64       6          50
exempt             Exempt    <none>                     <none>   <none>     <none>
global-default     Limited   20                         128      6          50
leader-election    Limited   10                         16       4          50
node-high          Limited   40                         64       6          50
system             Limited   30                         64       6          50
workload-high      Limited   40                         128      6          50
workload-low       Limited   100                        128      6          50
```

Cuando un cliente es throttled por APF, recibe **HTTP 429** con headers que identifican el carril — esto es lo que ves en el `kubectl` de la víctima:

```console
$ kubectl get pods -A
Error from server (TooManyRequests): the server has received too many requests and has
asked us to try again later (retry after 1s)

# En verbose se ven los headers de APF que nombran el FlowSchema culpable:
$ kubectl get pods -A -v=8 2>&1 | grep -i 'X-Kubernetes-PF'
X-Kubernetes-PF-FlowSchema-UID: 3a1e...  X-Kubernetes-PF-PriorityLevel-UID: 9c2f...
```

### 4.2 etcd exhaustion: el DoS por acumulación de objetos

etcd es la única fuente de verdad y tiene un **límite duro de tamaño de base de datos** (`--quota-backend-bytes`, default 2GiB, típicamente subido a 8GiB — máximo recomendado). **Cuando etcd supera su quota entra en modo `NOSPACE` (alarm), y el cluster pasa a read-only: no se pueden crear ni actualizar objetos.** Ese es un DoS total del control plane, y se puede provocar simplemente **creando muchos objetos** — Secrets, ConfigMaps, Events, CRs. De ahí que el `count/*` en `ResourceQuota` (§3.3) sea una defensa de DoS, no solo de higiene.

Vectores concretos: un CronJob mal configurado que deja miles de Jobs completados, un controller que genera Events en loop, o un tenant creando ConfigMaps grandes.

```console
# Tamaño y fragmentación de la DB de etcd
$ ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
+------------------------+------------------+---------+---------+-----------+------------+
|        ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM  |
+------------------------+------------------+---------+---------+-----------+------------+
| https://127.0.0.1:2379 | 8e9e05c52164694d |  3.5.16 |  7.9 GB |      true |         12 |
+------------------------+------------------+---------+---------+-----------+------------+
# 7.9 GB con quota de 8 GiB — a segundos de disparar la alarm NOSPACE

# ¿Qué prefijo de claves está inflando la DB? (los Events y Secrets son sospechosos típicos)
$ ETCDCTL_API=3 etcdctl get / --prefix --keys-only | \
    sed 's#/registry/##; s#/.*##' | sort | uniq -c | sort -rn | head
  184320 events
   41200 pods
   18944 configmaps
   12010 secrets
    9800 leases

# Al superar la quota, TODO write falla — esto ve el cluster entero:
$ kubectl create configmap test --from-literal=k=v
Error from server: etcdserver: mvcc: database space exceeded

# Recuperación: compactar historial de revisiones + defrag + limpiar la alarm
$ ETCDCTL_API=3 etcdctl compact $(etcdctl endpoint status --write-out=json | \
    grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)
$ ETCDCTL_API=3 etcdctl defrag --cluster
$ ETCDCTL_API=3 etcdctl alarm disarm
```

Defensa preventiva declarativa contra la acumulación de Jobs (fuente #1 de bloat de etcd por Events y objetos):

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: report-generator
  namespace: team-payments
spec:
  schedule: "*/5 * * * *"
  # Cuántos Jobs históricos retener — sin esto se acumulan indefinidamente
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Forbid          # no lanzar si el anterior sigue corriendo
  jobTemplate:
    spec:
      # TTL controller borra el Job 600s después de terminar → libera etcd
      ttlSecondsAfterFinished: 600
      backoffLimit: 2                # no reintentar infinito (evita Job storms)
      activeDeadlineSeconds: 240     # mata el Job si excede su ventana
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: report
              image: registry.internal/report:2.1.0
              resources:
                requests: {cpu: "200m", memory: "256Mi"}
                limits:   {cpu: "500m", memory: "512Mi"}
```

### 4.3 Admission webhooks como vector de DoS

Un `ValidatingWebhookConfiguration` o `MutatingWebhookConfiguration` con `failurePolicy: Fail` inyecta su latencia en el path crítico de *cada* operación que matchea. Si el backend del webhook se cae o se pone lento, **bloquea todos los `CREATE`/`UPDATE`** del cluster — incluidos los del propio sistema. Es un DoS de control plane por dependencia.

Contramedidas de diseño: `timeoutSeconds` corto, `namespaceSelector`/`objectSelector` para acotar el alcance, y evaluar `failurePolicy: Ignore` para webhooks no críticos.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: policy-enforcer
webhooks:
  - name: validate.policy.internal
    admissionReviewVersions: ["v1"]
    sideEffects: None
    # Techo de latencia: si el webhook no responde en 5s, se aplica failurePolicy
    timeoutSeconds: 5
    # Fail = seguro pero es un SPOF de DoS; Ignore = disponible pero bypasseable
    failurePolicy: Fail
    # Acota el alcance: NO evaluar namespaces del sistema (evita deadlock de arranque)
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public"]
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: Namespaced
    clientConfig:
      service:
        namespace: security
        name: policy-webhook
        path: /validate
        port: 443
      caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
```

---

## 5. Manifiestos de referencia: baseline defensivo completo de un tenant

El conjunto mínimo que hace a un namespace *resistente a DoS por diseño*. Es una plantilla de onboarding de tenant: quota agregada + defaults obligatorios + techo de PIDs a nivel nodo (ya cubierto en §3.4). Aquí el par ResourceQuota + LimitRange listo para `kubectl apply`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: team-orders
  labels:
    pod-security.kubernetes.io/enforce: restricted    # baseline PSA — reduce superficie
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-and-objects
  namespace: team-orders
spec:
  hard:
    requests.cpu: "16"
    requests.memory: "32Gi"
    limits.cpu: "32"
    limits.memory: "64Gi"
    requests.ephemeral-storage: "40Gi"
    limits.ephemeral-storage: "80Gi"
    pods: "120"
    count/deployments.apps: "40"
    count/jobs.batch: "60"
    services: "25"
    services.loadbalancers: "2"
    services.nodeports: "0"
    secrets: "80"
    configmaps: "80"
    persistentvolumeclaims: "30"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: container-defaults
  namespace: team-orders
spec:
  limits:
    - type: Container
      default:        {cpu: "500m", memory: "512Mi", ephemeral-storage: "1Gi"}
      defaultRequest: {cpu: "100m", memory: "128Mi", ephemeral-storage: "256Mi"}
      max:            {cpu: "4",    memory: "8Gi"}
      min:            {cpu: "50m",  memory: "64Mi"}
      maxLimitRequestRatio: {cpu: "4", memory: "2"}
    - type: Pod
      max: {cpu: "8", memory: "16Gi"}
    - type: PersistentVolumeClaim
      max: {storage: "40Gi"}
      min: {storage: "1Gi"}
```

Y una `NetworkPolicy` default-deny — mitiga el DoS de red *este-oeste* (un Pod comprometido floodeando a vecinos) reduciendo la superficie a lo explícitamente permitido:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-orders
spec:
  podSelector: {}                 # aplica a todos los Pods del namespace
  policyTypes:
    - Ingress
    - Egress
  # Sin reglas ingress/egress = deny total; se abren flujos con policies aditivas
```

> Nota de alcance para el examen: `NetworkPolicy` **no** hace rate limiting ni acota ancho de banda — solo permite/deniega flujos L3/L4. El rate limiting de red real requiere un service mesh (Istio, con `EnvoyFilter`/rate-limit service) o anotaciones del Ingress controller (`nginx.ingress.kubernetes.io/limit-rps`). No confundas *segmentación* con *throttling*.

---

## 6. Verificación y diagnóstico de fallas

Runbook operativo por capa. La regla: **primero determiná si el DoS es de data plane (un nodo) o de control plane (todo el cluster)** — la señal es si `kubectl` responde.

### 6.1 ¿El control plane responde?

```console
# Latencia del apiserver por verbo/recurso — el termómetro del control plane
$ kubectl get --raw '/metrics' | grep 'apiserver_request_duration_seconds_bucket{.*verb="LIST".*le="1"'
apiserver_request_duration_seconds_bucket{...resource="pods",verb="LIST",le="1"} 89234
# comparar con le="+Inf" para ver el % de LIST que tarda > 1s

# ¿Hay rechazos de APF? (control plane saturado por un cliente)
$ kubectl get --raw '/metrics' | grep -E 'flowcontrol_(rejected|current_inqueue)' | grep -v ' 0$'
apiserver_flowcontrol_rejected_requests_total{flow_schema="ci-pipeline-flow",...} 1843

# ¿Quién genera la carga? Top talkers por audit log (si está habilitado)
$ jq -r 'select(.verb=="list" or .verb=="watch") | .user.username' /var/log/kubernetes/audit.log | \
    sort | uniq -c | sort -rn | head -5
  48211 system:serviceaccount:ci-cd:jenkins-runner
   9032 system:serviceaccount:monitoring:prometheus
```

### 6.2 Presión de recursos en nodos

```console
# Vista rápida de saturación por nodo
$ kubectl top nodes
NAME       CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
worker-1   7823m        97%    29Gi            94%      # <- nodo saturado
worker-2   2104m        26%    12Gi            38%
worker-3   1890m        23%    11Gi            35%

# Condiciones de presión — el kubelet las expone en el Node status
$ kubectl get nodes -o custom-columns=\
'NODE:.metadata.name,MEM:.status.conditions[?(@.type=="MemoryPressure")].status,\
DISK:.status.conditions[?(@.type=="DiskPressure")].status,\
PID:.status.conditions[?(@.type=="PIDPressure")].status'
NODE       MEM     DISK    PID
worker-1   True    False   False
worker-2   False   False   False
worker-3   False   False   False

# ¿Qué Pod es el ofensor en el nodo saturado?
$ kubectl top pods -A --field-selector spec.nodeName=worker-1 --sort-by=memory | head -5
NAMESPACE      NAME              CPU(cores)   MEMORY(bytes)
team-orders    leaky-cache-0     6200m        27Gi          # <- el noisy neighbor
kube-system    cilium-x9k2f      120m         180Mi
...

# Eventos de eviction / OOMKill recientes
$ kubectl get events -A --field-selector reason=Evicted,type=Warning --sort-by=.lastTimestamp | tail
default        3m   Warning   Evicted   pod/batch-7f    The node was low on resource: memory.
```

### 6.3 Diagnóstico de PIDs y ephemeral storage

```console
# PIDs en uso vs. límite dentro del cgroup del Pod sospechoso
$ kubectl exec -n team-orders leaky-cache-0 -- sh -c 'echo cur=$(cat /sys/fs/cgroup/pids.current) max=$(cat /sys/fs/cgroup/pids.max)'
cur=4096 max=4096          # <- pegado al techo: fork bomb contenido

# Uso de disco e inodos del nodo (SSH al nodo o node-shell)
$ df -h /var/lib/kubelet ; df -i /var/lib/kubelet
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p1  200G  198G  2.0G  99% /var/lib/kubelet    # bytes casi llenos
Filesystem       Inodes  IUsed IFree IUse% Mounted on
/dev/nvme0n1p1    13M     12.8M  200K  99% /var/lib/kubelet  # inodos también

# ¿Qué emptyDir está inflado?
$ sudo du -sh /var/lib/kubelet/pods/*/volumes/kubernetes.io~empty-dir/* 2>/dev/null | sort -rh | head
41G  /var/lib/kubelet/pods/9a1f.../volumes/kubernetes.io~empty-dir/scratch
```

### 6.4 Checklist de postura anti-DoS (auditable)

```console
# 1. ¿Hay algún namespace de tenant SIN ResourceQuota? (agujero de DoS)
$ for ns in $(kubectl get ns -o name | grep team-); do
    n=$(kubectl get resourcequota -n ${ns#namespace/} --no-headers 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && echo "SIN QUOTA: $ns"
  done
SIN QUOTA: namespace/team-legacy       # <- hallazgo: onboardear con la plantilla §5

# 2. ¿Pods BestEffort en producción? (primeros en morir, DoS silencioso)
$ kubectl get pods -A -o jsonpath='{range .items[?(@.status.qosClass=="BestEffort")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | grep team- | head
team-legacy/adhoc-debug-0

# 3. ¿Webhooks con failurePolicy:Fail y timeout alto? (SPOF de control plane)
$ kubectl get validatingwebhookconfigurations -o json | \
    jq -r '.items[].webhooks[] | select(.failurePolicy=="Fail" and .timeoutSeconds>10) | .name'

# 4. ¿podPidsLimit configurado en los nodos?
$ kubectl get --raw "/api/v1/nodes/worker-1/proxy/configz" | jq '.kubeletconfig.podPidsLimit'
4096
```

### 6.5 Matriz de síntoma → causa → mitigación

| Síntoma observado | Capa | Causa raíz probable | Mitigación inmediata | Prevención estructural |
|---|---|---|---|---|
| `kubectl` responde `429 TooManyRequests` | Control plane | Cliente en hot-loop saturando un carril APF | Identificar por métricas APF; escalar shares del carril crítico | `FlowSchema` que aísle al cliente ofensor |
| `kubectl` timeout / sin respuesta | Control plane | etcd `NOSPACE`, o apiserver OOM | `etcdctl compact`+`defrag`+`alarm disarm` | `count/*` en quota, TTL en Jobs |
| Pods `OOMKilled` (exit 137) en cascada | Data plane | Nodo en MemoryPressure por Pod sin `limits.memory` | Evict/reschedule ofensor; cordon del nodo | `LimitRange` con defaults + quota |
| Latencia p99 alta sin CPU saturada | Data plane | CPU throttling por `limits.cpu` agresivo | Subir/quitar `limits.cpu` | Revisar `maxLimitRequestRatio` |
| Nodo `NotReady`, no arrancan Pods | Data plane | PID exhaustion (fork bomb) | Reiniciar kubelet; matar ofensor | `podPidsLimit` en KubeletConfiguration |
| Eviction masiva, `DiskPressure=True` | Data plane | emptyDir/logs llenando el disco | Borrar volumen ofensor; cordon | `limits.ephemeral-storage` + `sizeLimit` |
| Todos los `CREATE` cuelgan 30s+ | Control plane | Webhook lento con `failurePolicy:Fail` | Borrar el webhook o poner `Ignore` | `timeoutSeconds` bajo + `namespaceSelector` |

---

## 7. Referencias

- CNCF KCSA Curriculum — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Kubernetes — Resource Management for Pods and Containers — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes — Configure Quality of Service for Pods — https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/
- Kubernetes — Resource Quotas — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — Limit Ranges — https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes — Process ID Limits And Reservations — https://kubernetes.io/docs/concepts/policy/pid-limiting/
- Kubernetes — Node-pressure Eviction — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes — Reserve Compute Resources for System Daemons — https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/
- Kubernetes — API Priority and Fairness — https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Kubernetes — Local ephemeral storage — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage
- Kubernetes — Dynamic Admission Control — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Operating etcd clusters for Kubernetes — https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- etcd — Maintenance (compaction, defragmentation, space quota) — https://etcd.io/docs/latest/op-guide/maintenance/
- Kubernetes — Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- MITRE ATT&CK for Containers — Resource Hijacking (T1496) / Endpoint DoS (T1499) — https://attack.mitre.org/techniques/T1499/
- Kubernetes — Automatic Clean-up for Finished Jobs (TTL controller) — https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/