# 3.4 Primitivas para self-healing y despliegues robustos

## Por qué existen estos primitivos

Kubernetes no despliega Pods "sueltos" en producción: los Pods son efímeros y mortales por diseño (un nodo puede fallar, un proceso puede crashear, un Pod puede ser desalojado por presión de recursos). La robustez y el self-healing no vienen de que el Pod "no falle", sino de que existan **controllers** que observan el estado deseado (declarado en un manifest) contra el estado actual (observado vía el API server) y actúan continuamente para converger uno hacia el otro. Esto es el **reconciliation loop**, el patrón central detrás de todos los primitivos de este tema.

Los primitivos que hay que dominar para el examen son:

- **Controllers de alto nivel**: Deployment, ReplicaSet, DaemonSet, StatefulSet, Job, CronJob.
- **Pod-level self-healing**: `restartPolicy`, liveness/readiness/startup probes.
- **Disponibilidad ante disrupciones voluntarias**: PodDisruptionBudget (PDB).

---

## ReplicaSet: el garante del "cuántas réplicas"

Un `ReplicaSet` (RS) asegura que un número específico de réplicas de un Pod estén corriendo en todo momento. Si un Pod administrado por un RS muere (crash, nodo caído, eliminación manual), el controller lo detecta vía el watch al API server y crea un Pod de reemplazo.

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web-rs
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
```

En la práctica casi nunca se crea un RS directamente: se usa a través de un `Deployment`, que gestiona los RS por vos.

```console
$ kubectl delete pod web-rs-abc12
pod "web-rs-abc12" deleted

$ kubectl get pods -l app=web
NAME            READY   STATUS    RESTARTS   AGE
web-rs-def34    1/1     Running   0          40s   # nuevo Pod creado por el RS
web-rs-ghi56    1/1     Running   0          5m
web-rs-jkl78    1/1     Running   0          5m
```

El `selector.matchLabels` es la única forma en que el RS "sabe" qué Pods le pertenecen; el `template` sólo se usa al crear Pods nuevos, no re-etiqueta Pods existentes.

---

## Deployment: gestión declarativa de ReplicaSets

El `Deployment` agrega sobre el ReplicaSet la capacidad de hacer **rolling updates**, **rollbacks** y mantener un historial de revisiones. Internamente, cada cambio en el `template` del Deployment crea un nuevo ReplicaSet y escala gradualmente el viejo hacia 0 mientras escala el nuevo hacia `replicas`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
```

- `maxUnavailable`: cuántos Pods pueden estar down durante el update (garantiza disponibilidad mínima).
- `maxSurge`: cuántos Pods extra por encima de `replicas` se pueden crear temporalmente (acelera el rollout).
- `strategy.type: Recreate` mata todos los Pods viejos antes de crear los nuevos (útil cuando no se puede tener dos versiones corriendo a la vez, ej. por un volumen `ReadWriteOnce`).

Este subtema se solapa con 3.1 (rolling updates/rollbacks), pero acá lo relevante es que el Deployment **es** el mecanismo de self-healing a nivel aplicación: si borrás Pods, el ReplicaSet subyacente los repone; si el ReplicaSet entero desaparece, el Deployment controller lo vuelve a crear desde el `template`.

```console
$ kubectl rollout status deployment/web
deployment "web" successfully rolled out

$ kubectl get rs -l app=web
NAME               DESIRED   CURRENT   READY   AGE
web-7c9f8d6b4      3         3         3       2m
web-5b6d7c8f9      0         0         0       10m   # RS anterior, escalado a 0
```

---

## DaemonSet: un Pod por nodo, self-healing por topología

Garantiza que **cada nodo** (o un subconjunto seleccionado con `nodeSelector`/afinidad) corra exactamente una copia de un Pod. Es el primitivo correcto para agentes de infraestructura (log shippers, CNI, monitoring agents) donde la robustez significa "sobrevive independientemente de cuántos nodos haya" en vez de "sobrevive con N réplicas fijas".

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      tolerations:
      - operator: Exists   # correr también en nodos con taints (ej. control-plane)
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.8.0
```

Si se agrega un nodo nuevo al cluster, el DaemonSet controller crea automáticamente un Pod ahí; si un nodo se elimina, el Pod correspondiente desaparece con él (no hay "reprogramación" a otro nodo, porque es 1:1 con el nodo).

---

## Job y CronJob: self-healing para cargas de ejecución finita

A diferencia de Deployment/ReplicaSet (que asumen que el proceso corre indefinidamente), `Job` garantiza que un Pod **complete exitosamente** un número de veces, reintentando ante fallas.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migration
spec:
  backoffLimit: 4          # reintentos antes de marcar el Job como fallido
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: migrate
        image: myapp/migrate:1.0
```

- `backoffLimit`: cantidad de reintentos con backoff exponencial ante Pods que fallan.
- `restartPolicy` dentro de un Job **debe** ser `OnFailure` o `Never` (nunca `Always`).
- `activeDeadlineSeconds`: corta el Job entero si excede ese tiempo total.

```console
$ kubectl get jobs
NAME           COMPLETIONS   DURATION   AGE
db-migration   1/1           14s        1m
```

`CronJob` agrega programación tipo cron sobre un Job:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-backup
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid       # no solapar ejecuciones
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: backup
            image: myapp/backup:1.0
```

`concurrencyPolicy: Forbid` es en sí un mecanismo de robustez: evita que una ejecución lenta se solape con la siguiente.

---

## `restartPolicy`: self-healing a nivel de kubelet

Cada Pod tiene un `restartPolicy` (default `Always`) que el **kubelet local** aplica sin intervención del control plane:

| Valor | Comportamiento |
|---|---|
| `Always` | Reinicia el container siempre que termine (exitoso o no). Default para Deployments/ReplicaSets. |
| `OnFailure` | Reinicia sólo si el container termina con código de salida distinto de 0. Uso típico: Jobs. |
| `Never` | Nunca reinicia. Uso típico: Jobs de "un solo intento" o debugging. |

```console
$ kubectl get pod crashy -o jsonpath='{.status.containerStatuses[0].restartCount}'
7
```

Un `RESTARTS` alto visible en `kubectl get pods` es señal de un container crasheando repetidamente (`CrashLoopBackOff`); el backoff entre reintentos crece exponencialmente (10s, 20s, 40s... hasta un tope de 5 min).

---

## Probes: cómo Kubernetes sabe que algo anda mal

El self-healing sólo funciona si Kubernetes puede **detectar** que un Pod no está sano. Para eso existen tres tipos de probe, configurables con `exec`, `httpGet`, `tcpSocket` o `grpc`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-probes
spec:
  containers:
  - name: app
    image: myapp:1.0
    startupProbe:
      httpGet:
        path: /startupz
        port: 8080
      failureThreshold: 30
      periodSeconds: 10
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 10
      failureThreshold: 3
    readinessProbe:
      tcpSocket:
        port: 8080
      periodSeconds: 5
```

- **`livenessProbe`**: si falla, el **kubelet mata y reinicia el container** (aplicando `restartPolicy`). Detecta deadlocks o procesos colgados que siguen "vivos" pero no funcionan.
- **`readinessProbe`**: si falla, el Pod se **saca de los Endpoints del Service** (no recibe tráfico), pero **no se reinicia**. Es el mecanismo para no mandar requests a un Pod que está temporalmente ocupado o cargando datos.
- **`startupProbe`**: mientras no pase, se **desactivan** liveness y readiness. Protege apps con arranque lento de que la liveness probe las mate antes de terminar de bootear (evita tener que poner un `initialDelaySeconds` liveness enorme, que retrasaría la detección de cuelgues reales una vez arrancada la app).

```console
$ kubectl describe pod web-probes | grep -A3 Events
Events:
  Warning  Unhealthy  2m (x3 over 3m)  kubelet  Liveness probe failed: HTTP probe failed with statuscode: 500
  Normal   Killing    2m               kubelet  Container app failed liveness probe, will be restarted
```

---

## PodDisruptionBudget: robustez ante disrupciones voluntarias

Los primitivos anteriores cubren fallas **involuntarias** (crashes, nodos caídos). Pero un `drain` de nodo para mantenimiento, o un `kubectl delete` masivo, son disrupciones **voluntarias**. Un `PodDisruptionBudget` (PDB) le pone un piso a cuántos Pods de una app pueden estar down simultáneamente por ese tipo de operación.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 2        # o maxUnavailable: 1 (son mutuamente excluyentes)
  selector:
    matchLabels:
      app: web
```

Con esto, `kubectl drain` respeta el PDB y evita desalojar un Pod si hacerlo dejaría menos de 2 réplicas de `app: web` disponibles:

```console
$ kubectl drain node-1 --ignore-daemonsets
node/node-1 cordoned
evicting pod default/web-7c9f8d6b4-x9k2p
error when evicting pods/"web-7c9f8d6b4-x9k2p": global timeout reached: 
  Cannot evict pod as it would violate the pod's disruption budget.
```

Nota: el PDB **no** protege contra disrupciones involuntarias (un nodo que se cae de golpe no consulta al PDB); sólo aplica a operaciones que pasan por la Eviction API.

---

## Cómo se combinan estos primitivos en la práctica

1. **Deployment** define el estado deseado (`replicas`, imagen, estrategia de rollout) → gestiona **ReplicaSet**.
2. **ReplicaSet** garantiza el conteo de Pods → repone Pods eliminados o crasheados.
3. **kubelet** aplica `restartPolicy` localmente cuando un container termina.
4. **livenessProbe** le dice al kubelet cuándo un container "vivo" en realidad está roto y hay que reiniciarlo.
5. **readinessProbe** evita mandar tráfico a Pods que aún no están listos, sin gatillar reinicios innecesarios.
6. **PodDisruptionBudget** protege la disponibilidad cuando un humano (o un `drain` automatizado) intenta remover Pods a propósito.
7. **DaemonSet** y **Job/CronJob** son variantes del mismo patrón de reconciliación para topologías (1 por nodo) y cargas finitas (batch) respectivamente.

---

## Referencias

- Workload Resources — Kubernetes Docs: https://kubernetes.io/docs/concepts/workloads/controllers/
- Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Pod Lifecycle (restartPolicy, container states): https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Disruptions / PodDisruptionBudget: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Specifying a Disruption Budget for your Application: https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
