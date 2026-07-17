# 4.3 Understand requests, limits, quotas

## Introducción

En Kubernetes, la gestión de recursos de cómputo (CPU y memoria) es fundamental para que un clúster funcione de forma estable y predecible. Este tema cubre tres mecanismos relacionados pero distintos:

- **Requests y Limits**: definidos a nivel de container, determinan cuánto recurso se reserva y cuánto puede consumir como máximo.
- **LimitRange**: un objeto de namespace que impone valores por defecto y rangos válidos de requests/limits para los Pods/Containers creados en ese namespace.
- **ResourceQuota**: un objeto de namespace que limita el consumo total agregado de recursos (CPU, memoria, cantidad de objetos, etc.) dentro de ese namespace.

Entender la interacción entre estos tres conceptos es clave para el examen, ya que suelen combinarse en preguntas de troubleshooting (Pods que no se crean por exceder una quota, o que quedan en `Pending` por falta de recursos en los nodos).

---

## Requests y Limits

### Concepto

Cada container dentro de un Pod puede declarar, en `spec.containers[].resources`:

- **requests**: la cantidad de CPU/memoria que el scheduler garantiza que estará disponible en el nodo donde se agenda el Pod. El `kube-scheduler` usa este valor para decidir en qué nodo colocar el Pod (suma de requests de todos los Pods del nodo no puede superar la capacidad asignable del nodo).
- **limits**: el techo máximo de consumo que el container puede alcanzar. El `kubelet` (a través del container runtime) hace cumplir este límite.

### Unidades

- **CPU** se mide en "cores". `1` equivale a 1 vCPU/core físico o virtual. Se puede expresar en milicores: `500m` = 0.5 core.
- **Memoria** se mide en bytes, con sufijos como `Mi` (mebibytes), `Gi` (gibibytes), `M`, `G`, etc. Se recomienda usar los sufijos binarios (`Mi`, `Gi`) por ser los que Kubernetes usa internamente.

### Comportamiento al exceder los limits

- **CPU**: es un recurso *compressible*. Si un container intenta usar más CPU que su limit, el kernel lo *throttlea* (lo hace más lento), pero no lo mata.
- **Memoria**: es un recurso *incompressible*. Si un container excede su limit de memoria, el kernel lo termina con **OOMKilled** (`OOMKilled`, exit code 137).

### Ejemplo de manifiesto

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-resources
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

Aplicando y verificando:

```bash
kubectl apply -f demo-resources.yaml
kubectl describe pod demo-resources
```

Salida relevante (recortada):

```
Containers:
  app:
    Image:      nginx:1.27
    Limits:
      cpu:     500m
      memory:  256Mi
    Requests:
      cpu:        250m
      memory:     128Mi
```

### Simular un OOMKill

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: oom-demo
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      limits:
        memory: "50Mi"
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
```

```bash
kubectl get pod oom-demo -w
```

```
NAME       READY   STATUS      RESTARTS   AGE
oom-demo   0/1     OOMKilled   0          8s
oom-demo   0/1     CrashLoopBackOff   1     20s
```

```bash
kubectl describe pod oom-demo | grep -A5 "Last State"
```

```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

### Quality of Service (QoS) classes

Kubernetes asigna una clase de QoS a cada Pod en función de cómo se configuran requests y limits. Esto determina la prioridad de eviction cuando un nodo sufre presión de recursos.

| Clase | Condición | Prioridad de eviction |
|---|---|---|
| `Guaranteed` | Todos los containers tienen `requests == limits` para CPU **y** memoria | Última en ser evictada |
| `Burstable` | Al menos un container tiene requests, pero no cumple la condición de `Guaranteed` | Prioridad intermedia |
| `BestEffort` | Ningún container define requests ni limits | Primera en ser evictada |

```bash
kubectl get pod demo-resources -o jsonpath='{.status.qosClass}'
```

```
Burstable
```

---

## LimitRange

### Concepto

Un `LimitRange` es un objeto namespaced que permite:

- Definir valores **default** de request/limit para containers que no los especifican explícitamente.
- Imponer un **mínimo y máximo** permitido por container (o por Pod, PVC).
- Definir un **ratio máximo** entre limit y request (`maxLimitRequestRatio`).

Si un Pod viola las restricciones de un `LimitRange` (por ejemplo, pide menos que el mínimo o más que el máximo), el API server lo rechaza en el momento de creación con un error de admisión.

### Ejemplo

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: cpu-mem-limit-range
  namespace: dev
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"
      memory: "256Mi"
    defaultRequest:
      cpu: "250m"
      memory: "128Mi"
    min:
      cpu: "100m"
      memory: "64Mi"
    max:
      cpu: "1"
      memory: "512Mi"
    maxLimitRequestRatio:
      cpu: "4"
```

```bash
kubectl apply -f limitrange.yaml -n dev
kubectl describe limitrange cpu-mem-limit-range -n dev
```

```
Type        Resource  Min    Max    Default Request  Default Limit  Max Limit/Request Ratio
----        --------  ---    ---    ---------------  -------------  -----------------------
Container   cpu       100m   1      250m             500m           4
Container   memory    64Mi   512Mi  128Mi            256Mi          -
```

Un Pod que no especifica `resources` recibirá automáticamente `requests`/`limits` por defecto:

```bash
kubectl run test-pod --image=nginx -n dev
kubectl get pod test-pod -n dev -o jsonpath='{.spec.containers[0].resources}'
```

```
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"250m","memory":"128Mi"}}
```

Un Pod que excede el máximo es rechazado:

```bash
kubectl run big-pod --image=nginx -n dev --requests=cpu=2 --limits=cpu=2
```

```
Error from server (Forbidden): pods "big-pod" is forbidden: maximum cpu usage per Container is 1, but limit is 2
```

---

## ResourceQuota

### Concepto

Un `ResourceQuota` limita el **consumo agregado** de recursos dentro de un namespace: suma total de CPU/memoria (requests y limits), cantidad máxima de objetos (Pods, Services, PVCs, ConfigMaps, Secrets, etc.), y también soporta scopes (por ejemplo, solo Pods con determinada `priorityClass`).

Importante: si un namespace tiene una `ResourceQuota` que cubre `requests.cpu`, `requests.memory`, `limits.cpu` o `limits.memory`, **todo Pod creado en ese namespace debe declarar explícitamente esos valores** (o el namespace debe tener un `LimitRange` con defaults), de lo contrario el Pod es rechazado.

### Ejemplo: quota de cómputo

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: dev
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "10"
```

```bash
kubectl apply -f resourcequota.yaml
kubectl describe resourcequota compute-quota -n dev
```

```
Name:            compute-quota
Namespace:       dev
Resource         Used   Hard
--------         ----   ----
limits.cpu       500m   4
limits.memory    256Mi  4Gi
pods             1      10
requests.cpu     250m   2
requests.memory  128Mi  2Gi
```

### Ejemplo: quota de objetos

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: object-quota
  namespace: dev
spec:
  hard:
    configmaps: "10"
    secrets: "10"
    services: "5"
    persistentvolumeclaims: "4"
```

### Rechazo por exceder quota

```bash
kubectl run overquota --image=nginx -n dev --requests=cpu=3
```

```
Error from server (Forbidden): pods "overquota" is forbidden: exceeded quota: compute-quota, requested: requests.cpu=3, used: requests.cpu=250m, limited: requests.cpu=2
```

### Rechazo por falta de requests/limits cuando hay quota activa

Si `compute-quota` existe y un Pod se crea sin `resources` (y no hay `LimitRange` con defaults):

```
Error from server (Forbidden): pods "no-resources" is forbidden: failed quota: compute-quota: must specify limits.cpu,limits.memory,requests.cpu,requests.memory
```

Esto explica por qué en la práctica se combinan `LimitRange` (para poner defaults automáticos) con `ResourceQuota` (para limitar el total) en el mismo namespace.

---

## Interacción entre requests, LimitRange, ResourceQuota y el scheduler

1. Un Pod se crea sin especificar `resources`.
2. Si existe un `LimitRange`, el admission controller `LimitRanger` inyecta los defaults.
3. Si existe un `ResourceQuota`, el admission controller `ResourceQuota` verifica que el consumo total (incluyendo el nuevo Pod) no exceda el `hard` definido; si no hay requests/limits y la quota los exige, rechaza el Pod.
4. Si el Pod pasa la admisión, el `kube-scheduler` busca un nodo cuya capacidad **allocatable** menos la suma de requests de los Pods ya agendados sea suficiente para cubrir los requests del nuevo Pod. Si ningún nodo cumple, el Pod queda en `Pending`.

```bash
kubectl get pod pending-pod
```

```
NAME          READY   STATUS    RESTARTS   AGE
pending-pod   0/1     Pending   0          30s
```

```bash
kubectl describe pod pending-pod | grep -A3 Events
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  30s   default-scheduler  0/3 nodes are available: 3 Insufficient cpu.
```

---

## Comandos útiles para el examen

```bash
# Ver requests/limits configurados de un Pod
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources}'

# Ver consumo real vs. capacidad de un nodo
kubectl describe node <node> | grep -A5 "Allocated resources"

# Ver uso actual (requiere metrics-server)
kubectl top pod
kubectl top node

# Editar requests/limits de un Deployment
kubectl set resources deployment <name> --requests=cpu=200m,memory=256Mi --limits=cpu=500m,memory=512Mi

# Ver todas las ResourceQuota y LimitRange de un namespace
kubectl get resourcequota,limitrange -n dev
```

---

## Referencias

- Resource Management for Pods and Containers: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Assign Memory Resources to Containers and Pods: https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/
- Assign CPU Resources to Containers and Pods: https://kubernetes.io/docs/tasks/configure-pod-container/assign-cpu-resource/
- Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Configure Default Memory/CPU Requests and Limits for a Namespace: https://kubernetes.io/docs/tasks/administer-cluster/manage-resources/memory-default-namespace/
- Pod Quality of Service Classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf