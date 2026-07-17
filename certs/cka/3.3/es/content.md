# 3.3 Configure workload autoscaling

## Introducción

El *autoscaling* de workloads en Kubernetes permite ajustar automáticamente la cantidad de réplicas de un Pod (escalado horizontal) o los `resources.requests`/`limits` de un contenedor (escalado vertical) en función de la demanda real, sin intervención manual. El examen CKA evalúa principalmente el **Horizontal Pod Autoscaler (HPA)**, que es nativo de Kubernetes, y el conocimiento conceptual del **Vertical Pod Autoscaler (VPA)**, que es un proyecto complementario (`kubernetes/autoscaler`) no incluido por defecto en el control plane.

Ambos mecanismos dependen de una fuente de métricas: normalmente el **metrics-server**, que expone la API `metrics.k8s.io` a partir de datos recolectados de cAdvisor/kubelet.

## Horizontal Pod Autoscaler (HPA)

### Funcionamiento

El HPA es un controlador que corre dentro de `kube-controller-manager`. En un ciclo periódico (`--horizontal-pod-autoscaler-sync-period`, por defecto 15s) consulta las métricas del target (Deployment, ReplicaSet o StatefulSet) y ajusta `spec.replicas` según la fórmula:

```
desiredReplicas = ceil[ currentReplicas * ( currentMetricValue / desiredMetricValue ) ]
```

Requisitos indispensables:
- El **metrics-server** (u otro adaptador compatible con `custom.metrics.k8s.io`/`external.metrics.k8s.io`) debe estar desplegado.
- Los Pods objetivo deben declarar `resources.requests.cpu` (y/o `memory`), ya que el porcentaje de utilización se calcula respecto al request, no al límite.

### Crear un HPA de forma imperativa

```bash
kubectl autoscale deployment web --cpu-percent=50 --min=2 --max=10
```

```
horizontalpodautoscaler.autoscaling/web autoscaled
```

### Definición declarativa (autoscaling/v2)

La API `autoscaling/v1` sólo soporta CPU. Para memoria, métricas custom o external, y para el bloque `behavior`, se usa `autoscaling/v2`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
```

### Control fino con `behavior`

Permite evitar oscilaciones (*flapping*) controlando cuán rápido escala hacia arriba o abajo:

```yaml
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Pods
        value: 4
        periodSeconds: 60
      selectPolicy: Max
```

- `stabilizationWindowSeconds`: ventana de tiempo sobre la que se toma el valor más conservador antes de aplicar el escalado (útil sobre todo en `scaleDown` para evitar bajar réplicas por picos momentáneos).
- `policies`: límite de cuánto puede cambiar el número de réplicas por período (`Pods` = cantidad absoluta, `Percent` = porcentaje).
- `selectPolicy`: `Max` (por defecto en scaleUp), `Min` o `Disabled`.

### Verificación

```bash
kubectl get hpa web-hpa
```

```
NAME      REFERENCE      TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
web-hpa   Deployment/web cpu: 23%/50%       2         10        3          5m
```

```bash
kubectl describe hpa web-hpa
```

Muestra el historial de eventos (`SuccessfulRescale`) y, si algo falla, la causa más común:

```
Warning  FailedGetResourceMetric  horizontal-pod-autoscaler  missing request for cpu
```

o bien, si el metrics-server no está disponible, `TARGETS` aparece como `<unknown>/50%`.

### Métricas custom y external

Además de `Resource` (CPU/memoria vía metrics-server), `autoscaling/v2` soporta:
- `Pods`: métrica promedio por Pod expuesta vía la API `custom.metrics.k8s.io` (típicamente servida por un adaptador como `prometheus-adapter`), p. ej. requests por segundo.
- `Object`: métrica de un objeto de Kubernetes distinto (p. ej. `Ingress`).
- `External`: métrica de un sistema fuera del clúster (cola de mensajes, etc.), vía `external.metrics.k8s.io`.

```yaml
  metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "100"
```

## Vertical Pod Autoscaler (VPA)

El VPA **no forma parte del core de Kubernetes**; es un componente adicional del repositorio [kubernetes/autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) que se instala aparte. Ajusta `requests`/`limits` de los contenedores en base al uso histórico, en lugar de cambiar el número de réplicas.

Componentes:
- **Recommender**: analiza el uso de CPU/memoria y calcula valores recomendados.
- **Updater**: si `updateMode` lo permite, expulsa (evict) Pods que no cumplen la recomendación para que sean recreados con los nuevos valores.
- **Admission Controller**: intercepta la creación de Pods e inyecta los `resources` recomendados vía *mutating webhook*.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: web-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  updatePolicy:
    updateMode: "Auto"
```

`updateMode` acepta:
- `Off`: sólo genera recomendaciones (visibles con `kubectl describe vpa`), no las aplica.
- `Initial`: aplica la recomendación únicamente al crear el Pod.
- `Recreate` / `Auto`: recrea Pods existentes para aplicar los nuevos valores (`Auto` puede usar *in-place resize* si el clúster lo soporta).

```bash
kubectl describe vpa web-vpa
```

```
Recommendation:
  Container Recommendations:
    Container Name: web
    Target:
      Cpu:     250m
      Memory:  256Mi
```

**Importante para el examen**: no se debe combinar HPA y VPA sobre la **misma métrica** (CPU o memoria) del mismo workload, ya que ambos controladores competirían ajustando el mismo recurso. Sí es válido usar HPA basado en una métrica custom/external junto con VPA ajustando CPU/memoria.

## metrics-server

Es el requisito base tanto para `kubectl top` como para el HPA basado en `Resource` metrics.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
kubectl top pods -n default
```

```
NAME     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
node-1   145m         7%     1204Mi          31%
```

En entornos con certificados self-signed en el kubelet (común en clústeres de práctica) suele requerirse el flag `--kubelet-insecure-tls` en el Deployment de metrics-server para que empiece a reportar datos.

## Cluster Autoscaler (contexto)

A diferencia de HPA/VPA, el **Cluster Autoscaler** no ajusta Pods sino el número de **nodos** del clúster, agregando/quitando nodos según Pods `Pending` por falta de recursos programables. No se configura vía manifiestos estándar de la API de Kubernetes sino según el proveedor de infraestructura (cloud provider o *node group*), por lo que el examen lo trata como concepto de referencia más que como tarea práctica hands-on.

## Troubleshooting típico

| Síntoma | Causa habitual |
|---|---|
| `kubectl get hpa` muestra `<unknown>/50%` | metrics-server no instalado o sin conectividad al kubelet |
| HPA no escala aunque CPU esté alta | Falta `resources.requests.cpu` en el contenedor |
| VPA no aplica cambios | `updateMode: Off` (sólo recomienda) o admission controller no desplegado |
| Escalado oscila constantemente | Falta o es muy corta la `stabilizationWindowSeconds` en `scaleDown` |

## Referencias

- [Horizontal Pod Autoscaling — Kubernetes docs](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HorizontalPodAutoscaler Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
- [HPA API Reference (autoscaling/v2)](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.31/#horizontalpodautoscaler-v2-autoscaling)
- [kubectl autoscale reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#autoscale)
- [Vertical Pod Autoscaler — GitHub kubernetes/autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler)
- [metrics-server — GitHub kubernetes-sigs/metrics-server](https://github.com/kubernetes-sigs/metrics-server)
- [Cluster Autoscaler — GitHub kubernetes/autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
- [CKA Curriculum v1.35 — CNCF](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)