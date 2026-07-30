# 1.2 Using Cost Management Solutions for Right-Sizing and Scaling

## Motivación y Principios de FinOps en Kubernetes

La gestión de costos en entornos cloud native (**FinOps**) combina finanzas, operaciones e ingeniería para optimizar el gasto en infraestructura sin sacrificar el rendimiento, la disponibilidad ni la seguridad. En Kubernetes, el desafío fundamental radica en la discrepancia entre **recursos solicitados (Requests)**, **límites máximos (Limits)** y **consumo real (Usage)**.

```
+-------------------------------------------------------------------+
|               LIMIT (Capacidad Máxima Permitida)                 |
|  +-------------------------------------------------------------+  |
|  |            REQUEST (Garantía de Reservación de CPU/RAM)     |  |
|  |  +-------------------------------------------------------+  |  |
|  |  |         REAL USAGE (Consumo Real del Contenedor)       |  |  |
|  |  +-------------------------------------------------------+  |  |
|  +-------------------------------------------------------------+  |
+-------------------------------------------------------------------+
```

- **Overprovisioning (Desperdicio de Recursos)**: Cuando `Request >> Real Usage`. Los nodos se llenan por reservación teórica aunque los recursos estén ociosos (*Idle Cost*).
- **Underprovisioning (Riesgo de Disponibilidad)**: Cuando `Request < Real Usage`. Los contenedores sufren estrangulamiento de CPU (*CPU Throttling*) o terminación por falta de memoria (*OOMKilled*).

---

## 1. Visibilidad y Atribución de Costos (OpenCost & Kubecost)

Para optimizar costos, el primer paso es visibilizar el consumo y atribuirlo a unidades de negocio, namespaces, servicios o etiquetas de usuario (*Cost Allocation*).

### 1.1 OpenCost (CNCF Sandbox)
OpenCost es el estándar abierto de la CNCF para calcular costos de infraestructura en tiempo real mapeando métricas de Kubernetes contra precios de proveedores cloud (AWS, GCP, Azure) o modelos personalizados on-premise.

Despliegue de OpenCost en Kubernetes mediante Helm:

```bash
helm upgrade --install opencost opencost/opencost \
  --namespace opencost --create-namespace \
  --set opencost.exporter.extraEnv[0].name=CLUSTER_ID \
  --set opencost.exporter.extraEnv[0].value=prod-cluster-01
```

Consulta de la API de asignación de costos por namespace en formato JSON:

```bash
$ curl -s "http://opencost.opencost.svc:9003/allocation/compute?window=7d&aggregate=namespace" | jq .
{
  "code": 200,
  "data": [
    {
      "platform-prod": {
        "cpuCost": 142.50,
        "gpuCost": 0.00,
        "memoryCost": 68.20,
        "pvCost": 12.00,
        "networkCost": 5.40,
        "totalCost": 228.10,
        "efficiency": 0.68
      },
      "payments-dev": {
        "cpuCost": 85.00,
        "gpuCost": 0.00,
        "memoryCost": 40.10,
        "pvCost": 0.00,
        "networkCost": 1.20,
        "totalCost": 126.30,
        "efficiency": 0.32
      }
    }
  ]
}
```

---

## 2. Right-Sizing: Ajuste Fino de Requests y Limits

### 2.1 Vertical Pod Autoscaler (VPA)

El **Vertical Pod Autoscaler (VPA)** analiza el consumo histórico de CPU y memoria de las cargas de trabajo y recomienda o aplica automáticamente los valores óptimos de `requests` y `limits`.

Modos de operación del VPA:
1. `Off`: Únicamente calcula recomendaciones y las muestra en la spec del VPA.
2. `Initial`: Asigna las recomendaciones de recursos solo al momento de crear el Pod.
3. `Recreate`: Aplica las recomendaciones evictando y recreando los Pods existentes cuando el consumo varía significativamente.
4. `Auto`: Actualmente idéntico a `Recreate`.

Manifiesto de VPA en modo recomendación (`Off`) para una aplicación crítica:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: platform-api-vpa
  namespace: platform-prod
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind: Deployment
    name: platform-api
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: 4000m
          memory: 8Gi
        controlledResources: ["cpu", "memory"]
```

Inspección de las recomendaciones generadas por VPA:

```bash
$ kubectl get vpa platform-api-vpa -n platform-prod -o yaml
status:
  recommendation:
    containerRecommendations:
    - containerName: api-container
      lowerBound:
        cpu: 250m
        memory: 256Mi
      target:
        cpu: 500m
        memory: 512Mi
      uncappedTarget:
        cpu: 480m
        memory: 490Mi
      upperBound:
        cpu: 1500m
        memory: 3Gi
```

---

## 3. Horizontal Autoscaling: HPA y KEDA

### 3.1 Horizontal Pod Autoscaler (HPA) v2

El **HPA** ajusta el número de réplicas de un objeto ejecutable basándose en métricas obtenidas desde Metrics Server o Prometheus via Custom Metrics API.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: platform-api-hpa
  namespace: platform-prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: platform-api
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 75
  - type: Resource
    resource:
      name: memory
      target:
        type: AverageValue
        averageValue: 400Mi
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
```

### 3.2 KEDA (Kubernetes Event-driven Autoscaling)

KEDA es un proyecto CNCF Graduated que extiende HPA para escalar cargas de trabajo basándose en fuentes de eventos externas (RabbitMQ, Apache Kafka, AWS SQS, NATS) e incluso permite **escalar a cero réplicas** (`scale to 0`) para ahorrar costos cuando no hay eventos pendientes.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: order-processor-scaler
  namespace: e-commerce
spec:
  scaleTargetRef:
    name: order-processor
  minReplicaCount: 0
  maxReplicaCount: 50
  cooldownPeriod: 300
  triggers:
  - type: rabbitmq
    metadata:
      protocol: amqp
      queueName: orders-queue
      mode: QueueLength
      value: "20"
    authenticationRef:
      name: rabbitmq-auth
```

---

## 4. Autoscaling de Infraestructura: Karpenter vs Cluster Autoscaler

| Característica | Cluster Autoscaler | Karpenter (AWS / Open Source) |
|---|---|---|
| **Velocidad de Aprovisionamiento** | 2 - 5 minutos (espera a los NodeGroups) | 30 - 60 segundos (directo via EC2 API) |
| **Modelado de Nodos** | Basado en grupos homogéneos pre-definidos | Selección dinámica del tipo de instancia exacta |
| **Consolidación de Costos** | Limitada | Empaquetado agresivo y reemplazo por Spot Instances |

---

## Verificación y Diagnóstico del Autoscaling

### Comandos de Diagnóstico en Vivo

```bash
# Consultar el estado del HPA
$ kubectl get hpa platform-api-hpa -n platform-prod
NAME               REFERENCE                 TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
platform-api-hpa   Deployment/platform-api   42%/75%, 210Mi/400Mi   3         20        3          5d

# Verificar eventos de escalado del cluster
$ kubectl get events -n platform-prod --field-selector reason=SuccessfulRescale
LAST SEEN   TYPE     REASON              OBJECT                             MESSAGE
12m         Normal   SuccessfulRescale   horizontalpodautoscaler/platform-api-hpa   New size: 8; reason: cpu resource utilization above target
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenCost Specification & Docs — https://www.opencost.io/docs/
- Kubernetes HPA v2 Specification — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- KEDA Event-driven Autoscaler — https://keda.sh/docs/latest/
- Karpenter High-Performance Autoscaling — https://karpenter.sh/docs/