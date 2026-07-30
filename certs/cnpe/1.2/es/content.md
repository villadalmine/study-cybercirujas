# Tema 1.2: Using Cost Management Solutions for Right-Sizing and Scaling

## Introducción

La gestión de costos en entornos cloud native (**FinOps**) es una disciplina que combina prácticas financieras, operativas y de ingeniería para optimizar el gasto en infraestructura sin sacrificar performance ni disponibilidad. En Kubernetes, el desafío principal es que los recursos (CPU, memoria) se <PERSON> `requests` y `limits`, pero frecuentemente existe una brecha entre lo solicitado y <PERSON> consumido. <PERSON> traduce <PERSON> (**overprovisioning**) o en riesgo de *throttling*/OOMKill (**underprovisioning**).

Este tema <PERSON> herramientas y prácticas para **right-sizing** (ajustar recursos al uso real) y **scaling** (ajustar la cantidad de réplicas/nodos según demanda), integradas con soluciones de observabilidad de costos.

---

## 1. <PERSON>

### 1.1 Requests, Limits y su impacto en costos

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-demo
spec:
  containers:
    - name: app
      image: myapp:1.0
      resources:
        requests:
          cpu: "500m"
          memory: "256Mi"
        limits:
          cpu: "1"
          memory: "512Mi"
```

- **requests**: usado por el `kube-scheduler` para decidir en qué nodo colocar el Pod. Es la base del cálculo de **cost allocation** (cuánto "reserva" el Pod del nodo).
- **limits**: techo máximo antes de *throttling* (CPU) o **OOMKill** (memoria).
- El costo real de un cluster se calcula típicamente por **nodo** (instance type × tiempo), <PERSON> **reparte (allocate)** entre los Pods según sus requests, no según el uso real, salvo que la herramienta soporte *idle cost allocation*.

### 1.2 <PERSON> clave de eficiencia

| Métrica | Fórmula | Significado |
|---|---|---|
| **CPU/Memory Request Utilization** | uso real / request | <PERSON> request |
| **Cluster Utilization** | suma requests / capacidad del nodo | Nivel de bin-packing |
| **Idle Cost** | costo de capacidad no reservada | Capacidad pagada y no usada |
| **Waste** | request - uso real | Recursos sobredimensionados |

---

## 2. Herramientas de Cost Management

### 2.1 OpenCost

**OpenCost** es un proyecto CNCF (Sandbox) que define un estándar abierto para medir costos de Kubernetes en tiempo real, correlacionando el uso de recursos con el pricing del proveedor cloud (AWS, GCP, Azure) o con costos on-prem definidos manualmente.

Instalación básica <PERSON>:

```bash
helm repo add opencost https://opencost.github.io/opencost-helm-chart
helm install opencost opencost/opencost -n opencost --create-namespace
```

Consulta de la API (costo por namespace en la <PERSON>):

```bash
kubectl port-forward -n opencost svc/opencost 9003:9003

curl "http://localhost:9003/allocation/compute?window=1h&aggregate=namespace" | jq
```

Salida ejemplo (simplificada):

```json
{
  "code": 200,
  "data": [
    {
      "production": {
        "cpuCost": 0.42,
        "ramCost": 0.15,
        "totalCost": 0.57,
        "cpuCoreRequestAverage": 4.2,
        "cpuCoreUsageAverage": 1.1
      }
    }
  ]
}
```

Este resultado permite detectar rápidamente que `cpuCoreUsageAverage` (1.1) es mucho menor que `cpuCoreRequestAverage` (4.2) → <PERSON>right-sizing**.

### 2.2 Kubecost

**Kubecost** utiliza OpenCost como motor de medición y agrega una capa de UI, alertas, *savings recommendations* y soporte multi-cluster. Es útil para **showback/chargeback** hacia equipos o centros de costo.

```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm install kubecost kubecost/cost-analyzer -n kubecost --create-namespace \
  --set kubecostToken="<token>"
```

Kubecost expone recomendaciones de **request sizing** directamente en su dashboard, calculadas típicamente <PERSON> (p95/p99) de uso histórico (CPU y memoria) en una ventana configurable (ej. 7 días).

### 2.3 Goldilocks (Fairwinds)

**Goldilocks** utiliza el **Vertical Pod Autoscaler (VPA)** en modo `recommender` para sugerir requests/limits óptimos sin aplicarlos automáticamente, mostrando resultados en un dashboard visual estilo "Goldilocks zone" (<PERSON>, ni muy chico).

```bash
kubectl label ns production goldilocks.fairwinds.com/enabled=true

helm install goldilocks fairwinds-stable/<PERSON>namespace
```

---

## 3. Right-Sizing con Vertical Pod Autoscaler (VPA)

El **VPA** <PERSON> (o recomienda) los `requests` de CPU/memoria de los Pods en base a su historial de consumo.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: app-vpa
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind: Deployment
    name: app-demo
  updatePolicy:
    updateMode: "Off"   # "Off" = solo <PERSON>; "Auto" = aplica cambios
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        <PERSON>:
          cpu: "100m"
          memory: "128Mi"
        <PERSON>:
          cpu: "2"
          memory: "1Gi"
```

Consultar recomendaciones:

```bash
kubectl describe vpa app-vpa
```

```
Recommendation:
  Container Recommendations:
    Container Name: app
    Lower Bound:
      Cpu: 200m
      Memory: 200Mi
    Target:
      Cpu: 350m
      Memory: 280Mi
    Upper Bound:
      Cpu: 600m
      Memory: 450Mi
```

⚠️ **Nota importante**: `updateMode: "Auto"` en VPA **reinicia** los Pods para aplicar nuevos requests (no hay in-place resize hasta features recientes como `InPlacePodVerticalScaling`, alpha en versiones recientes de Kubernetes). Esto tiene implicaciones de disponibilidad que deben evaluarse junto a `PodDisruptionBudget`.

---

## 4. Scaling: HPA, Cluster Autoscaler y Karpenter

El right-sizing a nivel Pod se complementa con estrategias de escalado horizontal para optimizar el costo total del cluster.

### 4.1 Horizontal Pod Autoscaler (HPA)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: app-demo
  <PERSON>: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

```bash
kubectl get hpa app-hpa
```

```
NAME      REFERENCE            TARGETS   MINPODS   MAXPODS   REPLICAS
app-hpa   Deployment/app-demo  45%/60%   2         10        3
```

El HPA depende de requests correctamente dimensionados: si el `request.cpu` es exagerado, el `averageUtilization` (%) nunca <PERSON> sobreaprovisiona en nodos.

### 4.2 Cluster Autoscaler vs Karpenter

| Aspecto | Cluster Autoscaler | Karpenter |
|---|---|---|
| Enfoque | Escala node groups predefinidos | Provisiona nodos "just-in-time" según Pods pendientes |
| Bin-packing | Limitado a tipos de instancia fijos | Elige instance type <PERSON> (cost-aware) |
| Velocidad | Minutos | Segundos |
| Consolidación | Manual/limitada | <PERSON> (`consolidation`) para reducir waste |

Ejemplo de `NodePool` en Karpenter orientado a costo (prioriza instancias spot y right-sized):

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: cost-optimized
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

La política `consolidationPolicy: WhenEmptyOrUnderutilized` es clave para cost management: Karpenter reempaqueta Pods en menos nodos y termina instancias <PERSON>.

---

## 5. Flujo integrado de Right-Sizing + Cost Visibility

Un flujo típico auditado en la certificación:

1. **Medir**: OpenCost/Kubecost exponen consumo real vs. requests por namespace/workload.
2. **Recomendar**: Goldilocks/VPA (`updateMode: Off`) <PERSON> requests basados en percentiles históricos.
3. **Aplicar**: se actualizan manifests (GitOps) o se habilita VPA en modo `Auto`/`Recreate`.
4. **Escalar horizontalmente**: HPA ajusta réplicas según <PERSON>.
5. **Optimizar infraestructura**: Karpenter/Cluster Autoscaler consolidan nodos, usan spot instances y <PERSON> instance types adecuados.
6. **Reportar**: Kubecost genera reportes de *showback* por equipo/label/namespace para accountability.

---

## Referencias

- OpenCost — Documentación oficial: <PERSON>
- Kubecost — Documentación oficial: https://docs.kubecost.com/
- Kubernetes VPA (Vertical Pod Autoscaler): https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- Kubernetes HPA — Documentación oficial: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Cluster Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- Karpenter — Documentación oficial: https://karpenter.sh/docs/
- Goldilocks (Fairwinds): https://github.com/FairwindsOps/goldilocks
- FinOps Foundation: https://www.finops.org/
- CNCF Curriculum (fuente base del programa): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf