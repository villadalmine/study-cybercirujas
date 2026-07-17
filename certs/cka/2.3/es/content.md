# Monitor Cluster and Application Resource Usage

## Introducción

Monitorear el uso de recursos es la base para tomar decisiones de capacity planning, detectar cuellos de botella y diagnosticar problemas de rendimiento en un cluster de Kubernetes. A diferencia de un sistema de monitoreo completo tipo Prometheus/Grafana (que queda fuera del alcance directo del examen CKA, aunque puede aparecer como contexto), el examen se enfoca en las herramientas **nativas** que expone Kubernetes: el **Metrics Server**, el **Metrics API** (`metrics.k8s.io`), el comando `kubectl top`, y la inspección de eventos y estado vía `kubectl describe`.

Es clave entender la diferencia entre dos pipelines de métricas:

- **Resource Metrics Pipeline**: métricas de CPU/memoria en tiempo real, agregadas y de corta retención (segundos/minutos). Lo provee el **Metrics Server**. Es lo que consumen `kubectl top` y el **Horizontal Pod Autoscaler (HPA)**.
- **Full Metrics Pipeline**: métricas históricas, de series temporales, con más dimensiones (custom/external metrics). Lo proveen soluciones de terceros como Prometheus. No es obligatorio para que el cluster funcione, pero sí necesario para dashboards y alertas de largo plazo.

El CKA se enfoca casi exclusivamente en el primer pipeline.

## Arquitectura del Resource Metrics Pipeline

```
kubelet (cAdvisor embebido)
   │  expone /stats/summary por nodo
   ▼
Metrics Server (scrapea cada kubelet cada ~15s)
   │  agrega y expone vía Metrics API
   ▼
metrics.k8s.io (API aggregation layer)
   │
   ├── kubectl top nodes / kubectl top pods
   └── Horizontal Pod Autoscaler (HPA)
```

Puntos importantes:

- El **kubelet** ya trae integrado **cAdvisor**, que recolecta estadísticas de uso de CPU, memoria, red y filesystem por contenedor.
- El **Metrics Server** no almacena histórico: mantiene solo la muestra más reciente en memoria. No sirve para ver tendencias pasadas.
- El Metrics Server se registra como una extensión de la API mediante un `APIService` que apunta a `metrics.k8s.io/v1beta1`.

## Instalar y verificar Metrics Server

En muchos clusters (kubeadm, minikube sin el addon, kind) el Metrics Server **no viene instalado por defecto**. Sin él, `kubectl top` falla.

Instalación estándar (manifiesto oficial):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Verificar que el pod esté corriendo:

```bash
kubectl get pods -n kube-system -l k8s-app=metrics-server
```

```
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-6764bf875c-9j4kv   1/1     Running   0          2m
```

Verificar que la API se registró correctamente:

```bash
kubectl get apiservices | grep metrics
```

```
v1beta1.metrics.k8s.io   kube-system/metrics-server   True   3m
```

Si la columna `AVAILABLE` muestra `False`, el problema típico en clusters de laboratorio (kubeadm/kind con certificados self-signed) es que el kubelet no valida su certificado TLS. La solución habitual (solo para labs/CKAD/CKA sandbox, **no recomendada en producción**) es agregar el flag al Deployment:

```bash
kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Diagnóstico rápido si sigue fallando:

```bash
kubectl logs -n kube-system deploy/metrics-server
kubectl describe apiservice v1beta1.metrics.k8s.io
```

## `kubectl top`: uso de recursos en tiempo real

### A nivel de nodo

```bash
kubectl top nodes
```

```
NAME           CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
node-worker1   312m         15%    1204Mi           31%
node-worker2   890m         44%    2867Mi           73%
control-plane  210m         10%    980Mi            25%
```

Esto es útil para detectar **node pressure** antes de que el kubelet empiece a evictar pods (ver Tema de troubleshooting / node conditions: `MemoryPressure`, `DiskPressure`, `PIDPressure`).

### A nivel de pod

```bash
kubectl top pods
```

```
NAME                       CPU(cores)   MEMORY(bytes)
frontend-7d4b6c9f7-k2xqp   5m           18Mi
backend-6f8c5d9b7-mzt2r    120m         256Mi
```

Con namespace específico o todos los namespaces:

```bash
kubectl top pods -n produccion
kubectl top pods --all-namespaces
```

Desglosado por contenedor dentro del pod (útil en pods multi-contenedor con sidecars):

```bash
kubectl top pods --containers
```

```
POD                        NAME       CPU(cores)   MEMORY(bytes)
backend-6f8c5d9b7-mzt2r    app        110m         240Mi
backend-6f8c5d9b7-mzt2r    envoy      10m          16Mi
```

Ordenar por consumo (muy usado para encontrar el pod/nodo "ruidoso"):

```bash
kubectl top pods --sort-by=cpu
kubectl top pods --sort-by=memory
kubectl top nodes --sort-by=memory
```

> Nota: si un pod recién fue creado o el kubelet todavía no reportó estadísticas, `kubectl top` puede devolver `error: metrics not available yet`. Es transitorio (~1 minuto).

## Requests, Limits y su relación con el monitoreo

El uso reportado por `kubectl top` cobra sentido cuando se compara contra lo declarado en el `PodSpec`:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "250m"
    memory: "256Mi"
```

- **requests**: usado por el `kube-scheduler` para decidir en qué nodo entra el pod (bin-packing). También define el mínimo garantizado.
- **limits**: aplicado por el kubelet/runtime vía cgroups. Al superar el límite de memoria, el contenedor es terminado con **OOMKilled**. Al superar el límite de CPU, el contenedor es *throttled* (no se mata, se lo estrangula).

Ver requests/limits configurados vs uso real:

```bash
kubectl describe pod backend-6f8c5d9b7-mzt2r
```

```
Limits:
  cpu:     250m
  memory:  256Mi
Requests:
  cpu:     100m
  memory:  128Mi
```

Comparar esto con la salida de `kubectl top pods --containers` permite detectar:

- **Over-provisioning**: requests muy altos vs uso real → desperdicio de capacidad del cluster.
- **Under-provisioning / riesgo de OOMKill**: uso cercano o que supera el limit de memoria.
- **CPU throttling silencioso**: el pod funciona pero está lento porque el limit de CPU es bajo (esto no se ve directo en `kubectl top`, hay que revisar `container_cpu_cfs_throttled_seconds_total` en un sistema con Prometheus, o inferirlo por latencia).

## QoS Classes y su impacto en monitoreo/evicción

Kubernetes asigna una **Quality of Service (QoS) class** a cada pod según cómo se definieron requests/limits, y esto determina el orden de evicción bajo `MemoryPressure`:

| QoS Class    | Condición                                                   | Prioridad de evicción |
|--------------|--------------------------------------------------------------|------------------------|
| `Guaranteed` | requests == limits para CPU y memoria en todos los containers | Última en ser evictada |
| `Burstable`  | al menos un container tiene requests, pero no cumple Guaranteed | Intermedia |
| `BestEffort` | sin requests ni limits definidos                              | Primera en ser evictada |

```bash
kubectl get pod backend-6f8c5d9b7-mzt2r -o jsonpath='{.status.qosClass}'
```

```
Burstable
```

Al monitorear un cluster con `MemoryPressure`, es esperable ver primero evictados los pods `BestEffort`.

## Detectar OOMKilled y CPU Throttling

Diagnóstico de un contenedor terminado por falta de memoria:

```bash
kubectl describe pod backend-6f8c5d9b7-mzt2r
```

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Ver el motivo también vía eventos o el estado directo del pod:

```bash
kubectl get pod backend-6f8c5d9b7-mzt2r -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
```

Revisar logs del contenedor anterior (el actual ya reinició):

```bash
kubectl logs backend-6f8c5d9b7-mzt2r --previous
```

Para CPU throttling no hay una señal tan directa sin un stack de métricas histórico; en el contexto del examen, la pista suele ser: el pod está `Running` (no se reinicia), pero su rendimiento es pobre pese a que `kubectl top` no muestra uso por encima del limit — ahí es donde vale la pena revisar si el `limits.cpu` es demasiado bajo y subirlo.

## Eventos del cluster

Los eventos son la fuente de verdad para entender *qué pasó* (scheduling, pulls de imagen, evicciones, fallos de probes) y complementan las métricas numéricas.

```bash
kubectl get events --sort-by='.lastTimestamp'
```

```
LAST SEEN   TYPE      REASON              OBJECT                          MESSAGE
2m          Warning   FailedScheduling    pod/backend-6f8c5d9b7-mzt2r     0/3 nodes are available: 3 Insufficient memory.
1m          Normal    Pulled              pod/backend-6f8c5d9b7-mzt2r     Container image already present on machine
30s         Warning   Evicted             pod/cache-7f9d8c6b5-abc12       The node was low on resource: memory.
```

Filtrar solo warnings, o eventos de un namespace/objeto puntual:

```bash
kubectl get events --field-selector type=Warning
kubectl get events -n produccion --field-selector involvedObject.name=backend-6f8c5d9b7-mzt2r
```

## Node conditions relevantes al uso de recursos

```bash
kubectl describe node node-worker2
```

```
Conditions:
  Type             Status  Reason
  MemoryPressure   False   KubeletHasSufficientMemory
  DiskPressure     False   KubeletHasNoDiskPressure
  PIDPressure      False   KubeletHasSufficientPID
  Ready            True    KubeletReady

Allocatable:
  cpu:                3800m
  memory:              7205864Ki
```

También se ve la sección `Allocated resources`, con el total de requests/limits comprometidos en el nodo — muy útil para saber si un nodo está "lleno" desde la perspectiva del scheduler aunque el uso real (`kubectl top`) sea bajo:

```
Allocated resources:
  Resource           Requests      Limits
  cpu                2100m (55%)   3400m (89%)
  memory             4096Mi (58%)  6144Mi (87%)
```

## Relación con el Horizontal Pod Autoscaler (HPA)

El HPA consulta el Resource Metrics Pipeline (vía `metrics.k8s.io`) para decidir cuándo escalar. Sin Metrics Server funcionando, el HPA no puede operar con métricas de `cpu`/`memory`.

```bash
kubectl autoscale deployment backend --cpu-percent=70 --min=2 --max=6
kubectl get hpa
```

```
NAME      REFERENCE            TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
backend   Deployment/backend   45%/70%   2         6         2          5m
```

Si `TARGETS` muestra `<unknown>/70%`, casi siempre significa que el Metrics Server no está disponible o el pod no tiene `requests.cpu` definido (el HPA calcula el porcentaje relativo al request, no al limit).

## Buenas prácticas para el examen

- Si `kubectl top` falla, primero verificar que el Metrics Server esté `Running` y que el `APIService` esté `Available=True`.
- `kubectl top` y HPA solo ven **CPU y memoria** (resource metrics pipeline). Métricas custom (requests/segundo, colas, etc.) requieren un *custom metrics adapter* — fuera del alcance práctico habitual del examen, pero vale saber que existe `custom.metrics.k8s.io`.
- Comparar siempre **uso real** (`kubectl top`) contra **requests/limits declarados** (`kubectl describe`) — es el patrón de diagnóstico más común en preguntas de performance.
- `kubectl describe` sigue siendo la herramienta más rica: combina eventos, QoS, conditions y último estado de terminación en un solo lugar.

## Referencias

- CNCF — CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Kubernetes Docs — Resource Metrics Pipeline: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- Kubernetes Docs — kubectl top: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#top
- Kubernetes Docs — Managing Resources for Containers (requests/limits): https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes Docs — Node-pressure Eviction: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes Docs — Pod Quality of Service Classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Kubernetes Docs — Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- kubernetes-sigs/metrics-server (GitHub): https://github.com/kubernetes-sigs/metrics-server
- Kubernetes Docs — Troubleshoot Clusters (events, node conditions): https://kubernetes.io/docs/tasks/debug/debug-cluster/