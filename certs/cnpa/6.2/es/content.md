# 6.2 Autoscaling Strategies: HPA, VPA, KEDA, and Cluster Autoscaler

## Motivación y Escalamiento Automático en Kubernetes

El escalamiento automático (**Autoscaling**) en Kubernetes opera en tres niveles para responder dinámicamente a la demanda de carga sin intervención manual:

1. **Horizontal Pod Autoscaler (HPA)**: Escala el número de réplicas de Pods basándose en métricas de uso (CPU, memoria, custom metrics).
2. **Vertical Pod Autoscaler (VPA)**: Ajusta los `requests` y `limits` de CPU/memoria de los contenedores.
3. **Cluster Autoscaler / Karpenter**: Escala el número de nodos del clúster añadiendo o eliminando VMs según la capacidad necesaria.
4. **KEDA (Kubernetes Event-Driven Autoscaling)**: Escala workloads basándose en eventos externos (colas de mensajes, métricas de Prometheus, métricas cloud).

---

## 1. HPA con Custom Metrics

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
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "1000"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
```

---

## 2. KEDA ScaledObject

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: queue-worker-scaler
  namespace: platform-prod
spec:
  scaleTargetRef:
    name: queue-worker
  minReplicaCount: 0
  maxReplicaCount: 50
  triggers:
  - type: rabbitmq
    metadata:
      host: amqp://rabbitmq.platform-prod:5672
      queueName: tasks
      queueLength: "5"
```

---

## Verificación del Estado de Autoscaling

```bash
# Estado actual del HPA
$ kubectl get hpa -n platform-prod
NAME                REFERENCE                  TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
platform-api-hpa    Deployment/platform-api    65%/70%, 800/1k   2         20        5          30m

# Eventos de escalamiento del Cluster Autoscaler
$ kubectl get events -n kube-system --field-selector reason=ScaledUpGroup
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes HPA — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- KEDA — https://keda.sh/docs/
- Karpenter — https://karpenter.sh/