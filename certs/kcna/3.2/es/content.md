# 3.2 Scheduling

## ¿Qué es el scheduling?

El **scheduling** es el proceso mediante el cual Kubernetes decide en qué **node** del cluster debe ejecutarse un **Pod** recién creado. El componente responsable de esto es el **kube-scheduler**, uno de los componentes del control plane.

Es importante entender que el scheduler **no ejecuta** los Pods, solo decide *dónde* deberían ejecutarse. Una vez que toma la decisión, escribe el nombre del node elegido en el campo `spec.nodeName` del Pod (a través del API server). Después de eso, el **kubelet** del node asignado es quien efectivamente crea los contenedores.

El ciclo de vida básico es:
1. Un Pod se crea sin `spec.nodeName` (queda en estado `Pending`).
2. El kube-scheduler detecta el Pod sin asignar (watch sobre el API server).
3. Selecciona el node más adecuado según un proceso de dos fases: **filtering** y **scoring**.
4. Realiza el *binding*: asigna el Pod al node elegido.
5. El kubelet de ese node toma el Pod y lo ejecuta.

```bash
kubectl get pods -o wide
# NAME       READY   STATUS    NODE
# my-pod     1/1     Running   worker-node-2
```

Si un Pod queda en `Pending` por mucho tiempo, generalmente significa que el scheduler no pudo encontrar un node que cumpla los requisitos:

```bash
kubectl describe pod my-pod
# Events:
#   Warning  FailedScheduling  0/3 nodes are available: 3 Insufficient cpu.
```

## Las dos fases del scheduling

### 1. Filtering (antes llamado "predicates")

El scheduler descarta todos los nodes que **no pueden** correr el Pod. Ejemplos de filtros:
- ¿El node tiene suficientes recursos (CPU, memoria) libres?
- ¿El Pod tiene un `nodeSelector` o `nodeAffinity` que el node no cumple?
- ¿Existen **taints** en el node que el Pod no tolera?
- ¿El node tiene puertos ya ocupados que el Pod necesita (`hostPort`)?
- ¿El volumen requerido está disponible en la zona del node?

Si ningún node pasa el filtro, el Pod queda en `Pending`.

### 2. Scoring (antes llamado "priorities")

De los nodes que pasaron el filtro, el scheduler les asigna un puntaje a cada uno según criterios como:
- Balanceo de recursos (evitar concentrar carga en pocos nodes).
- Afinidad/anti-afinidad de Pods.
- Spreading entre zonas de disponibilidad.

El node con el puntaje más alto es elegido para el binding.

## Mecanismos para influir en el scheduling

### nodeSelector

La forma más simple de restringir en qué nodes puede correr un Pod, usando labels.

```bash
kubectl label nodes worker-node-1 disktype=ssd
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx
  nodeSelector:
    disktype: ssd
```

### Node Affinity

Versión más expresiva del `nodeSelector`, con operadores (`In`, `NotIn`, `Exists`, etc.) y dos modos:
- `requiredDuringSchedulingIgnoredDuringExecution`: regla obligatoria (equivalente "duro").
- `preferredDuringSchedulingIgnoredDuringExecution`: regla preferida ("soft", el scheduler intenta cumplirla pero no es bloqueante).

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: In
            values: ["ssd"]
```

### Pod Affinity / Anti-Affinity

Permite decidir la ubicación de un Pod en relación a **otros Pods** (no nodes). Útil para:
- Co-ubicar Pods que se comunican mucho entre sí (affinity), reduciendo latencia.
- Separar réplicas de una misma app entre distintos nodes o zonas (anti-affinity), mejorando la resiliencia.

```yaml
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values: ["web"]
        topologyKey: "kubernetes.io/hostname"
```

Este ejemplo evita que dos Pods con label `app=web` corran en el mismo node.

### Taints y Tolerations

Mientras que `nodeAffinity` es una propiedad del Pod que "atrae" hacia ciertos nodes, los **taints** son una propiedad del **node** que "repele" Pods, salvo que estos declaren una **toleration** explícita.

```bash
kubectl taint nodes worker-node-3 key=value:NoSchedule
```

Efectos posibles de un taint:
- `NoSchedule`: no se programan Pods nuevos sin toleration (los existentes no se afectan).
- `PreferNoSchedule`: variante "soft", el scheduler evita el node si puede.
- `NoExecute`: además de no programar nuevos Pods, **expulsa** los Pods existentes que no toleren el taint.

```yaml
spec:
  tolerations:
  - key: "key"
    operator: "Equal"
    value: "value"
    effect: "NoSchedule"
```

Un caso de uso muy común: los control-plane nodes suelen tener un taint (`node-role.kubernetes.io/control-plane:NoSchedule`) para que los Pods de las apps no se programen ahí por defecto.

### Resource Requests y Limits

El scheduler usa el campo `resources.requests` de cada contenedor para decidir si un node tiene capacidad suficiente. Los `limits`, en cambio, los hace cumplir el kubelet/runtime en tiempo de ejecución, no el scheduler.

```yaml
resources:
  requests:
    cpu: "250m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

Si la suma de `requests` de los Pods ya asignados a un node más los del nuevo Pod supera la capacidad asignable del node, ese node es descartado en la fase de filtering.

### nodeName (scheduling manual)

Es posible saltarse el scheduler completamente especificando el node de forma directa:

```yaml
spec:
  nodeName: worker-node-1
```

Esto es poco común en producción; se usa sobre todo para debugging o casos muy específicos.

### Pod Topology Spread Constraints

Permite distribuir Pods de forma pareja entre "dominios de topología" (zonas, regiones, nodes), generalizando lo que antes se lograba solo con anti-affinity.

```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
```

### Multiple Schedulers

Kubernetes permite correr más de un scheduler en simultáneo (el default `kube-scheduler` más schedulers custom), y cada Pod puede elegir cuál lo va a programar con `spec.schedulerName`.

```yaml
spec:
  schedulerName: my-custom-scheduler
```

## Descheduler

Un proyecto relacionado (no parte del core, sino un subproyecto de `kubernetes-sigs`) es el **Descheduler**, que evalúa Pods ya corriendo y los expulsa (para que el scheduler los reubique) si las condiciones cambiaron — por ejemplo, si un node quedó desbalanceado o violando una anti-affinity que se agregó después.

## Resumen de conceptos clave

| Mecanismo | Actúa sobre | Tipo de regla |
|---|---|---|
| `nodeSelector` | Pod → Node | Duro (simple) |
| `nodeAffinity` | Pod → Node | Duro o soft, expresivo |
| `podAffinity`/`podAntiAffinity` | Pod → Pod | Duro o soft |
| Taints/Tolerations | Node repele Pods | `NoSchedule`, `PreferNoSchedule`, `NoExecute` |
| `resources.requests` | Capacidad del node | Filtro obligatorio |
| Topology Spread Constraints | Distribución entre zonas/nodes | Configurable (`DoNotSchedule` o `ScheduleAnyway`) |

## Referencias

- CNCF KCNA Curriculum: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes Docs — Kubernetes Scheduler: https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
- Kubernetes Docs — Assigning Pods to Nodes: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Kubernetes Docs — Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes Docs — Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes Docs — Scheduling Framework: https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/
- Kubernetes SIGs — Descheduler: https://github.com/kubernetes-sigs/descheduler