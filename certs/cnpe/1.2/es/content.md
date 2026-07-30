# 1.2 Using Cost Management Solutions for Right-Sizing and Scaling

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El control de costos e infraestructura eficiente (*FinOps*) en plataformas cloud native es una responsabilidad crítica del **Platform Engineer**. Este tema cubre las herramientas, estrategias y mejores prácticas para el dimensionamiento correcto (*Right-Sizing*), autosescalado de workloads y visibilidad de costos en clústeres de producción.

---

## 1. Conceptos de FinOps y Resource Allocation en Kubernetes

Kubernetes maneja la asignación de recursos a través de dos mecanismos clave a nivel de contenedor:
- **Requests**: El mínimo de CPU/memoria garantizado por el Kubelet. Determina las decisiones de scheduling.
- **Limits**: El techo máximo absoluto. CPU se estrangula (*throttling* vía cgroups CFS quota) y Memoria dispara un evento *Out Of Memory* (OOMKill) si sobrepasa el límite.

### Problemas Comunes de Dimensionamiento
1. **Over-provisioning**: Se definen `requests` demasiado altos por miedo a caídas, dejando CPU/Memoria ociosa y elevando la factura cloud.
2. **Under-provisioning**: `requests` demasiado bajos que causan colisiones de recursos (*noisy neighbors*) o `OOMKilled` frecuentes.

---

## 2. Herramientas de Visibilidad y Cost Allocation (OpenCost / Kubecost)

Para atribuir costos exactos por namespace, deployment o tenant, se utilizan motores de monitoreo de costos integrados con métricas de Prometheus.

### OpenCost
OpenCost es un proyecto Sandbox de la CNCF para medir costos de infraestructura de Kubernetes en tiempo real mediante un estándar abierto.

```bash
# Instalación rápida de OpenCost vía Helm
helm repo add opencost https://opencost.github.io/opencost-helm/
helm install opencost opencost/opencost --namespace opencost --create-namespace
```

Métricas exportadas por OpenCost:
- `node_cpu_hourly_cost`: Costo por CPU/hora según el proveedor de nube.
- `container_cpu_allocation_bytes`: Asignación real consumida por contenedor.

---

## 3. Estrategias de Autoscaling: HPA, VPA y Karpenter

Para ajustar los recursos automáticamente según la demanda:

### Horizontal Pod Autoscaler (HPA)
Escala la cantidad de réplicas de un Pod basándose en métricas de CPU, memoria o métricas custom (Prometheus).

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
  namespace: platform-prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 75
```

### Vertical Pod Autoscaler (VPA)
Ajusta automáticamente las `requests` y `limits` de CPU y Memoria basándose en el consumo histórico.
- **Modo Recommendation Only (`Off`)**: El VPA analiza y sugiere los valores óptimos sin reiniciar los Pods (ideal para análisis de right-sizing).
- **Modo `Auto`**: Modifica activamente las requests recreando los Pods.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: api-vpa-recommender
  namespace: platform-prod
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind: Deployment
    name: api-deployment
  updatePolicy:
    updateMode: "Off"
```

### Autoscaling de Infraestructura (Karpenter / Cluster Autoscaler)
Karpenter (CNCF Sandbox) reemplaza el Cluster Autoscaler tradicional aprovisionando nodos "just-in-time" optimizados para el tamaño exacto de los Pods pendientes (*unschedulable*), reduciendo desperdicio de instancias EC2/VMs.

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenCost Specification — https://www.opencost.io/docs/
- Kubernetes Vertical Pod Autoscaler — https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- Karpenter Autoscaling — https://karpenter.sh/
