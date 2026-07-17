# 4.4 — Define resource requirements

**Peso en el examen: 3** · Dominio: Application Environment, Configuration and Security

## ¿Por qué importan los recursos?

Kubernetes no sabe cuánta CPU o memoria necesita tu aplicación a menos que se lo digas. Los **resource requirements** se declaran por contenedor dentro del Pod y cumplen dos funciones distintas:

- **`requests`**: la cantidad *garantizada* que el contenedor necesita. El **scheduler** usa este valor para decidir en qué nodo colocar el Pod. Si ningún nodo tiene capacidad libre suficiente para los `requests`, el Pod queda en estado `Pending`.
- **`limits`**: el tope máximo que el contenedor puede consumir. Lo hace cumplir el **kubelet** junto con el container runtime.

El comportamiento al superar el límite es diferente según el recurso:

| Recurso | Si supera el `limit` |
|---|---|
| `cpu` | Se aplica **throttling** (se lo frena, no se lo mata) |
| `memory` | El contenedor es terminado con **OOMKilled** (exit code 137) |
| `ephemeral-storage` | El Pod es **evicted** del nodo |

## Unidades

**CPU** se mide en cores o *millicores*:

- `1` = 1 core (1 vCPU) · `500m` = 0.5 cores · `0.1` = `100m`
- No existen fracciones menores a `1m`.

**Memoria** se mide en bytes, con sufijos binarios (`Ki`, `Mi`, `Gi`) o decimales (`K`, `M`, `G`):

- `128Mi` = 128 × 2²⁰ bytes · `1Gi` = 1024 Mi

> ⚠️ Error clásico de examen: escribir `400m` en memoria pensando en "400 megas". `400m` de memoria son **0.4 bytes**. Para memoria usá siempre `Mi`, `Gi`, `M` o `G`.

## Declarar requests y limits en un Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: nginx:1.27
    resources:
      requests:
        cpu: 250m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
```

Puntos clave:

- Los recursos se definen **por contenedor**, no por Pod. Los `requests` efectivos del Pod son la suma de todos sus contenedores (incluidos init containers, que se calculan aparte: cuenta el máximo entre init y la suma de los normales).
- Si declarás `limits` sin `requests`, Kubernetes asigna `requests = limits` automáticamente.
- Si no declarás nada, el contenedor puede consumir todo lo disponible en el nodo, pero es el primer candidato a eviction bajo presión de memoria.

### Generarlo rápido en el examen

```bash
kubectl run app --image=nginx:1.27 \
  --dry-run=client -o yaml > pod.yaml
# editar y agregar el bloque resources

# O directamente sobre un Deployment existente:
kubectl set resources deployment/web \
  --requests=cpu=250m,memory=128Mi \
  --limits=cpu=500m,memory=256Mi
```

`kubectl set resources` es de los comandos que más tiempo ahorran en este tema: modifica el Deployment en caliente y dispara un rollout.

## Clases de QoS (Quality of Service)

Según cómo declares recursos, Kubernetes asigna al Pod una **QoS class** que determina el orden de eviction cuando el nodo se queda sin memoria:

| Clase | Condición | Prioridad de eviction |
|---|---|---|
| `Guaranteed` | Todos los contenedores tienen `requests` = `limits` en CPU **y** memoria | Última en ser expulsada |
| `Burstable` | Al menos un contenedor tiene `requests` o `limits` (sin cumplir Guaranteed) | Intermedia |
| `BestEffort` | Ningún contenedor declara nada | Primera en ser expulsada |

Verificación:

```bash
kubectl get pod app -o jsonpath='{.status.qosClass}'
```
```
Burstable
```

## Diagnóstico: ¿qué pasa cuando algo falla?

**Pod que no schedulea** (requests mayores que la capacidad libre de cualquier nodo):

```bash
kubectl describe pod app
```
```
Events:
  Warning  FailedScheduling  ...  0/3 nodes are available:
  3 Insufficient memory. preemption: 0/3 nodes are available...
```

**Contenedor que excede su límite de memoria:**

```bash
kubectl describe pod app
```
```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
```

**Ver consumo real y capacidad de los nodos:**

```bash
kubectl top pod app            # requiere metrics-server
kubectl top node
kubectl describe node node01   # sección "Allocated resources"
```
```
Allocated resources:
  Resource   Requests      Limits
  cpu        1150m (57%)   2 (100%)
  memory     980Mi (25%)   2Gi (54%)
```

## LimitRange: defaults por namespace

Un **LimitRange** define valores por defecto, mínimos y máximos para los contenedores de un namespace. Si un Pod no declara recursos, el admission controller le inyecta los defaults:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: dev
spec:
  limits:
  - type: Container
    default:            # limit por defecto
      cpu: 500m
      memory: 256Mi
    defaultRequest:     # request por defecto
      cpu: 100m
      memory: 128Mi
    max:
      cpu: "1"
      memory: 1Gi
```

Si un Pod viola el `max`/`min`, la creación es **rechazada** en el momento (error de admission, no un Pending).

## ResourceQuota: tope agregado por namespace

Mientras LimitRange actúa por contenedor, **ResourceQuota** limita el total consumido por todo el namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: dev
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
```

```bash
kubectl describe quota team-quota -n dev
```
```
Resource         Used   Hard
--------         ----   ----
limits.cpu       2      8
limits.memory    4Gi    16Gi
pods             5      20
requests.cpu     1      4
requests.memory  2Gi    8Gi
```

> Importante: cuando existe una ResourceQuota sobre `requests`/`limits`, **todo Pod nuevo debe declarar esos recursos** (o heredarlos de un LimitRange), de lo contrario es rechazado.

## Checklist para el examen

- `requests` → scheduling; `limits` → enforcement en runtime.
- CPU excedida = throttling; memoria excedida = `OOMKilled` (137).
- Memoria siempre con `Mi`/`Gi`; nunca sufijo `m`.
- `kubectl set resources` para editar rápido un Deployment.
- QoS: `requests = limits` en todo → `Guaranteed`.
- `FailedScheduling: Insufficient cpu/memory` → bajar requests, o el nodo no da.
- LimitRange = por contenedor (defaults/min/max); ResourceQuota = agregado del namespace.

## Referencias

- Resource Management for Pods and Containers — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Assign Memory Resources to Containers and Pods — https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/
- Assign CPU Resources to Containers and Pods — https://kubernetes.io/docs/tasks/configure-pod-container/assign-cpu-resource/
- Pod Quality of Service Classes — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Limit Ranges — https://kubernetes.io/docs/concepts/policy/limit-range/
- Resource Quotas — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf