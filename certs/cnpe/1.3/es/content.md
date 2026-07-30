# 1.3 Optimizing Multi-Tenancy Resource Usage

## Introducción

En clusters multi-tenant, varios equipos, aplicaciones o clientes comparten el mismo control plane y los mismos nodos. El objetivo de este tema es garantizar **fairness**, **isolation** y **eficiencia en el uso de recursos** entre los distintos tenants, evitando que un namespace o workload <PERSON> (noisy neighbor problem) y logrando un buen **bin-packing** de los nodos.

Los mecanismos principales de Kubernetes para esto son:

- **Namespaces** como unidad de aislamiento lógico.
- **ResourceQuota** <PERSON> agregado por namespace.
- **LimitRange** para definir defaults y rangos por Pod/Container.
- **Requests/Limits** en los Pods (CPU, memoria, `ephemeral-storage`, <PERSON>).
- **PriorityClass** y **preemption** para diferenciar tenants críticos de no críticos.
- **Quality of Service (QoS) classes** derivadas de requests/limits.
- Herramientas de **fair scheduling** (por ejemplo, PodTopologySpread, taints/tolerations) <PERSON> equitativa.

---

## 1. Namespaces como frontera de multi-tenancy

Los `Namespace` no aíslan recursos de cómputo por sí mismos, solo proveen scoping de nombres y RBAC. La optimización de recursos <PERSON> con **ResourceQuota** y **LimitRange**, <PERSON> aplican por namespace.

```bash
kubectl create namespace team-a
kubectl create namespace team-b
```

---

## 2. ResourceQuota

`ResourceQuota` limita el consumo **total** de recursos (compute, storage, objetos) dentro de un namespace. Es la herramienta central para evitar que un tenant agote los recursos del cluster.

### Tipos de recursos que se pueden limitar

- **Compute**: `requests.cpu`, `requests.memory`, `limits.cpu`, `limits.memory`
- **Storage**: `requests.storage`, `persistentvolumeclaims`, `<storage-class>.storageclass.storage.k8s.io/requests.storage`
- **Object counts**: `pods`, `services`, `configmaps`, `secrets`, `count/<resource>.<group>`
- **Extended resources**: `requests.<resource-name>` (ej. GPUs)

### Ejemplo de manifiesto

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
    persistentvolumeclaims: "10"
    requests.storage: 100Gi
```

```bash
kubectl apply -f team-a-quota.yaml
kubectl describe resourcequota team-a-quota -n team-a
```

Salida típica:

```
Name:            team-a-quota
Namespace:       team-a
Resource         Used   Hard
--------         ----   ----
limits.cpu       4      20
limits.memory    8Gi    40Gi
pods             5      50
requests.cpu     2      10
requests.memory  4Gi    20Gi
```

> **Nota:** Si existe un `ResourceQuota` con requests/limits de CPU o memoria en un namespace, **todos** los Pods creados en él deben especificar explícitamente esos valores, o el `apiserver` los rechazará (a menos que un `LimitRange` inyecte defaults).

### Scope y ScopeSelector

Se pueden aplicar quotas condicionadas por `scopeSelector`, por ejemplo diferenciando por `priorityClass`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: high-priority-quota
  namespace: team-a
spec:
  hard:
    pods: "10"
  scopeSelector:
    matchExpressions:
      - operator: In
        scopeName: PriorityClass
        values: ["high-priority"]
```

---

## 3. LimitRange

`LimitRange` define **valores mínimos, máximos y por defecto** de recursos a nivel Pod/Container/PVC dentro de un namespace. <PERSON> a `ResourceQuota`: mientras esta limita el total, `LimitRange` evita que un solo Pod acapare todo el quota o que se cree sin requests/limits.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: team-a-limits
  namespace: team-a
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 250m
        memory: 256Mi
      min:
        cpu: 100m
        memory: 128Mi
      <PERSON>:
        cpu: 2
        memory: 2Gi
```

```bash
kubectl apply -f team-a-limits.yaml
kubectl describe limitrange team-a-limits -n team-a
```

- Si un Pod no especifica `resources`, <PERSON> inyectan `default`/`defaultRequest`.
- Si excede `min`/`max`, el `apiserver` <PERSON>.

---

## 4. Requests, Limits y QoS Classes

Cada Pod recibe una **Quality of Service class** según sus requests/limits, <PERSON>eviction** bajo presión de nodo:

| QoS Class     | Condición                                                                 |
|---------------|----------------------------------------------------------------------------|
| `Guaranteed`  | Todos los containers tienen `requests == limits` para CPU y memoria       |
| `Burstable`   | Al menos un container tiene requests, sin cumplir condición de Guaranteed |
| `BestEffort`  | Ningún container define requests ni limits                                |

```bash
kubectl get pod mypod -o jsonpath='{.status.qosClass}'
```

Para multi-tenancy, <PERSON>:

- Tenants críticos → `Guaranteed`.
- Workloads batch/no críticos → `Burstable` o `BestEffort` (primeros en ser evicted).

---

## 5. PriorityClass y Preemption

`PriorityClass` permite diferenciar tenants por importancia; en escasez de recursos, el scheduler puede **preempt** (desalojar) Pods de menor prioridad para dar lugar a Pods de mayor prioridad.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
description: "Prioridad para workloads críticos de tenant"
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: critical-app
spec:
  priorityClassName: high-priority
  containers:
    - name: app
      image: nginx
      resources:
        requests: {cpu: "500m", memory: "512Mi"}
        limits: {cpu: "1", memory: "1Gi"}
```

<PERSON> con `ResourceQuota` con `scopeSelector` por `PriorityClass`, <PERSON> recursos "premium" consume cada tenant.

---

## 6. Fair Scheduling y distribución de carga

Para evitar concentración de tenants en pocos nodos (afectando bin-packing y aislamiento de fallas):

- **PodTopologySpreadConstraints**: distribuye Pods entre zonas/nodos.
- **Taints/Tolerations** + **NodeAffinity**: dedicar node pools a tenants específicos.
- **Cluster Autoscaler / Karpenter**: <PERSON> según demanda agregada, optimizando costo vs. uso.

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        tenant: team-a
```

---

## 7. Verificación y monitoreo del uso

```bash
kubectl top pods -n team-a
kubectl top nodes
kubectl describe quota -n team-a
kubectl get limitrange -n team-a -o yaml
```

Integrar con **Vertical Pod Autoscaler (VPA)** o métricas de `metrics-server` ayuda a ajustar requests/limits reales de cada tenant, optimizando la relación entre uso solicitado y uso real (evitando over-provisioning que desperdicia quota).

---

## Buenas prácticas resumidas

1. Combinar `ResourceQuota` + `LimitRange` en cada namespace de tenant.
2. <PERSON> `PriorityClass` para diferenciar SLAs entre tenants.
3. Establecer requests/limits realistas basados en métricas históricas (VPA/HPA).
4. Usar `scopeSelector` en quotas para segmentar por prioridad o tipo de recurso.
5. Aplicar `topologySpreadConstraints` para distribución equitativa entre nodos/zonas.
6. Auditar consumo regularmente con `kubectl describe resourcequota` y dashboards (Prometheus/Grafana).

---

## Referencias

- Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- Configure Default Memory/CPU Requests and Limits: https://kubernetes.io/docs/tasks/administer-cluster/manage-resources/memory-default-namespace/
- Pod Quality of Service Classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Pod Priority and Preemption: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Vertical Pod Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- CNCF CNPE Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf