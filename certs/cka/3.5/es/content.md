# 3.5 Configure Pod Admission and Scheduling (limits, node affinity, etc.)

## Contexto general

El *scheduling* en Kubernetes es el proceso por el cual el `kube-scheduler` decide en qué `node` debe correr un `Pod` que todavía no tiene `nodeName` asignado. La "admisión" de un Pod, en cambio, ocurre en el `kube-apiserver` antes de que el objeto se persista en `etcd`: ahí actúan los *admission controllers* que pueden validar, mutar o directamente rechazar el Pod (por ejemplo, por violar una `ResourceQuota` o un `LimitRange`).

Este tema combina ambos mundos porque en la práctica se controlan con las mismas herramientas: **requests/limits de recursos**, **afinidad de nodos y de Pods**, **taints/tolerations**, **topology spread constraints** y **PriorityClass**.

## 1. Resource requests y limits

Cada contenedor puede declarar cuánto CPU/memoria necesita (`requests`, usado por el scheduler para decidir el nodo) y cuánto puede llegar a usar como máximo (`limits`, aplicado por el `kubelet`/`cgroups`).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-limitado
spec:
  containers:
  - name: app
    image: nginx:1.27
    resources:
      requests:
        cpu: "250m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "256Mi"
```

- El scheduler solo filtra nodos por `requests` (nunca por `limits`).
- Si un contenedor supera su `limit` de memoria, el `kubelet` lo mata con `OOMKilled`. Si supera el `limit` de CPU, se lo *throttlea* (no se mata).
- Un Pod sin `limits` de memoria puede quedar como candidato a eviction antes que uno con `limits` definidos, según la QoS class.

### QoS Classes

Kubernetes asigna automáticamente una clase de QoS según cómo se definan requests/limits:

| QoS Class | Condición |
|---|---|
| `Guaranteed` | Todos los contenedores tienen `requests == limits` para CPU y memoria |
| `Burstable` | Al menos un contenedor tiene requests o limits, pero no cumple `Guaranteed` |
| `BestEffort` | Ningún contenedor define requests ni limits |

```bash
kubectl get pod app-limitado -o jsonpath='{.status.qosClass}'
# Burstable
```

Ante presión de recursos en el nodo, el `kubelet` evict primero los `BestEffort`, luego `Burstable`, y por último `Guaranteed`.

## 2. LimitRange

Un `LimitRange` define valores por defecto y límites mínimos/máximos de recursos **por namespace**, para Pods/contenedores que no los especifiquen o que se salgan de rango. Es un *admission controller* (`LimitRanger`) que actúa al crear el objeto.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: limites-default
  namespace: equipo-a
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"
      memory: "256Mi"
    defaultRequest:
      cpu: "250m"
      memory: "128Mi"
    max:
      cpu: "1"
      memory: "512Mi"
    min:
      cpu: "100m"
      memory: "64Mi"
```

```bash
kubectl apply -f limitrange.yaml
kubectl describe limitrange limites-default -n equipo-a
```

```
Type        Resource  Min   Max    Default Request  Default Limit
----        --------  ---   ---    ---------------  -------------
Container   cpu       100m  1      250m             500m
Container   memory    64Mi  512Mi  128Mi            256Mi
```

Si se intenta crear un Pod que pida más de `max` o menos de `min`, el `apiserver` rechaza la creación:

```
Error from server (Forbidden): error when creating "pod.yaml":
pods "app" is forbidden: maximum cpu usage per Container is 1, but limit is 2
```

## 3. ResourceQuota

Mientras `LimitRange` opera por Pod/contenedor, `ResourceQuota` limita el **consumo agregado** de un namespace (CPU/memoria totales, cantidad de objetos como Pods, Services, PVCs, etc.).

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-equipo-a
  namespace: equipo-a
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
    pods: "20"
    count/deployments.apps: "10"
```

```bash
kubectl apply -f resourcequota.yaml
kubectl describe resourcequota quota-equipo-a -n equipo-a
```

```
Name:            quota-equipo-a
Namespace:       equipo-a
Resource         Used  Hard
--------         ----  ----
limits.cpu       500m  8
limits.memory    256Mi 8Gi
pods             1     20
requests.cpu     250m  4
requests.memory  128Mi 4Gi
```

Punto clave para el examen: **si un namespace tiene una `ResourceQuota` con `requests.cpu`/`requests.memory`, todo Pod creado en ese namespace debe declarar explícitamente `requests` y `limits`** (o el `apiserver` lo rechaza), salvo que un `LimitRange` le provea valores por defecto.

## 4. nodeSelector

La forma más simple de restringir el scheduling: el Pod solo corre en nodos que tengan **todas** las labels indicadas.

```bash
kubectl label node worker-2 disk=ssd
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-ssd
spec:
  nodeSelector:
    disk: ssd
  containers:
  - name: app
    image: nginx:1.27
```

## 5. Node affinity

Node affinity es una versión más expresiva de `nodeSelector`, con dos tipos según cuándo se evalúa y dos modos según si es obligatoria o preferida:

- `requiredDuringSchedulingIgnoredDuringExecution`: regla obligatoria al programar (equivalente "duro" a nodeSelector, pero con operadores).
- `preferredDuringSchedulingIgnoredDuringExecution`: regla de preferencia con `weight` (1-100); el scheduler intenta cumplirla pero no es bloqueante.

"IgnoredDuringExecution" significa que si las labels del nodo cambian después de que el Pod ya está corriendo, no se lo desaloja.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-afinidad
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disk
            operator: In
            values: ["ssd"]
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
          - key: zone
            operator: In
            values: ["us-east-1a"]
  containers:
  - name: app
    image: nginx:1.27
```

Operadores válidos en `matchExpressions`: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`.

```bash
kubectl get pod app-afinidad -o wide
kubectl describe pod app-afinidad | grep -A5 Events
```

Si ninguna regla `required` se cumple, el Pod queda en `Pending` con un evento tipo:

```
Warning  FailedScheduling  0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector.
```

## 6. Pod affinity y anti-affinity

Permiten decidir el nodo de un Pod en función de **qué otros Pods ya corren ahí** (o en el mismo dominio de topología, definido por `topologyKey`, típicamente `kubernetes.io/hostname` o `topology.kubernetes.io/zone`).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  labels:
    app: web
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values: ["cache"]
        topologyKey: kubernetes.io/hostname
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
            - key: app
              operator: In
              values: ["web"]
          topologyKey: kubernetes.io/hostname
  containers:
  - name: web
    image: nginx:1.27
```

Casos de uso típicos:
- **Pod affinity**: colocar un Pod de aplicación en el mismo nodo/zona que su caché (`co-location`), reduciendo latencia.
- **Pod anti-affinity**: evitar que réplicas del mismo `Deployment` caigan en el mismo nodo/zona, mejorando disponibilidad ante falla de un nodo.

## 7. Taints y tolerations

Los taints se aplican a **nodos** y repelen Pods, salvo que el Pod tenga una **toleration** que los tolere. Es el mecanismo inverso a la afinidad (que "atrae" en vez de "repeler").

```bash
kubectl taint nodes worker-3 gpu=true:NoSchedule
kubectl describe node worker-3 | grep Taints
# Taints: gpu=true:NoSchedule
```

Efectos posibles:
- `NoSchedule`: no se programan Pods nuevos sin toleration, pero los existentes no se mueven.
- `PreferNoSchedule`: el scheduler evita el nodo si puede, pero no es obligatorio.
- `NoExecute`: además de bloquear el scheduling, **expulsa** Pods que ya corren en el nodo y no toleran el taint (útil para `node.kubernetes.io/not-ready` y `node.kubernetes.io/unreachable`, que Kubernetes agrega automáticamente).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-gpu
spec:
  tolerations:
  - key: "gpu"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
  containers:
  - name: app
    image: cuda-app:1.0
```

Toleration con `tolerationSeconds` para limitar cuánto tiempo un Pod tolera un `NoExecute` antes de ser desalojado:

```yaml
tolerations:
- key: "node.kubernetes.io/not-ready"
  operator: "Exists"
  effect: "NoExecute"
  tolerationSeconds: 300
```

Quitar un taint:

```bash
kubectl taint nodes worker-3 gpu=true:NoSchedule-
```

Nota para el examen: **taints/tolerations no garantizan** que el Pod termine en ese nodo, solo que puede ser programado ahí (evitan que otros Pods sin toleration entren). Para forzar afinidad hacia un nodo específico se combina con `nodeAffinity` o `nodeSelector`.

## 8. Topology Spread Constraints

Distribuyen Pods de manera equilibrada entre dominios de topología (zonas, nodos, regiones), independientemente de la afinidad.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-spread
  labels:
    app: web
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
  containers:
  - name: web
    image: nginx:1.27
```

- `maxSkew`: diferencia máxima tolerada en cantidad de Pods entre el dominio con más y el que tiene menos.
- `whenUnsatisfiable`: `DoNotSchedule` (obligatorio, como `required`) o `ScheduleAnyway` (best-effort, como `preferred`).

## 9. PriorityClass y preemption

Define prioridad relativa entre Pods. Ante falta de recursos, el scheduler puede **desalojar (preempt)** Pods de menor prioridad para hacer lugar a uno de mayor prioridad que de otro modo quedaría `Pending`.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: alta-prioridad
value: 1000000
globalDefault: false
description: "Para cargas críticas de producción"
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-critica
spec:
  priorityClassName: alta-prioridad
  containers:
  - name: app
    image: nginx:1.27
```

```bash
kubectl get pod app-critica -o jsonpath='{.spec.priority}'
# 1000000
```

`preemptionPolicy: Never` en una `PriorityClass` evita que Pods de esa clase desalojen a otros (solo esperan turno).

## 10. Admission controllers relevantes

El `kube-apiserver` corre una cadena de *admission controllers* habilitados con `--enable-admission-plugins`. Los más relevantes para este tema:

```bash
# Ver los admission plugins habilitados (requiere acceso al manifiesto estático)
grep enable-admission-plugins /etc/kubernetes/manifests/kube-apiserver.yaml
```

- `LimitRanger`: aplica los `LimitRange` de cada namespace.
- `ResourceQuota`: valida contra las `ResourceQuota` (siempre corre al final de la cadena de validación).
- `DefaultTolerationSeconds`: agrega tolerations por defecto de 300s para `not-ready`/`unreachable`.
- `PodNodeSelector` (opcional, no habilitado por defecto): fuerza un `nodeSelector` por namespace vía anotación.
- `AlwaysPullImages`, `NamespaceLifecycle`, etc. no son objeto directo de este tema, pero conviene saber que existen en la misma cadena.

## Resumen de comandos útiles para el examen

```bash
# Ver por qué un Pod no se programó
kubectl describe pod <pod> | grep -A10 Events

# Ver taints de todos los nodos
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Ver labels de nodos
kubectl get nodes --show-labels

# Ver quotas y limitranges de un namespace
kubectl get resourcequota,limitrange -n <ns>

# Ver la QoS class y los recursos asignados
kubectl get pod <pod> -o jsonpath='{.status.qosClass}{"\n"}{.spec.containers[*].resources}'
```

## Referencias

- Node affinity y afinidad entre Pods: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Taints y tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Requests y limits de recursos: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- LimitRange: https://kubernetes.io/docs/concepts/policy/limit-range/
- ResourceQuota: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Pod Priority and Preemption: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Pod Quality of Service: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Using Admission Controllers: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf