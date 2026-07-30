# 6.1 Cost Optimization and FinOps for Cloud Native Infrastructure

## Motivación y FinOps en Kubernetes

La gestión de costos en entornos cloud native (**FinOps**) combina prácticas financieras, operativas y de ingeniería para optimizar el gasto en infraestructura sin sacrificar performance ni disponibilidad. En Kubernetes, el desafío principal es que los recursos (CPU, memoria) se asignan mediante `requests` y `limits`, pero frecuentemente existe una brecha entre lo solicitado y lo consumido realmente.

---

## 1. Right-Sizing con Vertical Pod Autoscaler (VPA)

El **VPA** analiza las métricas históricas de consumo de CPU y memoria de los Pods para recomendar o ajustar automáticamente los `requests` y `limits`:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: platform-api-vpa
  namespace: platform-prod
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: platform-api
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
    - containerName: api
      minAllowed:
        cpu: 50m
        memory: 64Mi
      maxAllowed:
        cpu: 2
        memory: 2Gi
```

---

## 2. Ratio de Eficiencia de Asignación

$$\text{Efficiency Ratio} = \frac{\text{Recursos Consumidos (usage)}}{\text{Recursos Solicitados (requests)}} \times 100$$

```bash
# PromQL: Porcentaje de uso real de CPU respecto al Request asignado
sum(rate(container_cpu_usage_seconds_total{container!=""}[5m]))
/
sum(kube_pod_container_resource_requests{resource="cpu"}) * 100
```

---

## 3. Herramientas de Observabilidad de Costos

- **Kubecost**: Dashboards de costos por namespace, deployment, label y equipo.
- **OpenCost (CNCF Sandbox)**: Modelo de costos abierto para Kubernetes.

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- OpenCost — https://www.opencost.io/
- Kubecost Docs — https://docs.kubecost.com/