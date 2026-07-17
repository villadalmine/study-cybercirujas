# 2.3 Observability

## Introducción

**Observability** (observabilidad) es la capacidad de entender el estado interno de un sistema a partir de sus salidas externas. En sistemas cloud native, donde las aplicaciones están compuestas por decenas o cientos de microservicios distribuidos en contenedores efímeros, la observability deja de ser un "nice to have" y se vuelve una necesidad operativa: sin ella es imposible depurar fallas, entender latencias o planificar capacidad.

Se suele diferenciar de **monitoring** (monitoreo): el monitoring te dice *que algo está mal* (basado en dashboards y alertas predefinidas), mientras que la observability te da las herramientas para *investigar por qué* algo está mal, incluso ante fallas que nunca anticipaste.

La observability se apoya tradicionalmente en tres pilares:

| Pilar | Qué captura | Pregunta que responde |
|---|---|---|
| **Metrics** | Series numéricas en el tiempo (CPU, requests/sec, latencia) | "¿Qué tan seguido pasa esto?" |
| **Logs** | Eventos discretos con contexto (timestamp, mensaje) | "¿Qué pasó exactamente?" |
| **Traces** | El recorrido de un request a través de múltiples servicios | "¿Dónde se generó la latencia/error?" |

## Metrics y Prometheus

**Prometheus** es el proyecto de referencia del CNCF (segundo graduado, después de Kubernetes) para métricas en entornos cloud native.

Características clave:

- Modelo de datos **multi-dimensional**: cada métrica es una serie temporal identificada por un nombre y un conjunto de pares clave-valor llamados **labels**.
- **Pull-based**: Prometheus scrapea (hace polling) endpoints HTTP en formato `/metrics` en lugar de que las apps le empujen datos.
- **Service discovery** nativo para Kubernetes: descubre Pods, Services y Endpoints automáticamente vía la API de Kubernetes.
- Lenguaje de queries propio: **PromQL**.
- **AlertManager** como componente separado para deduplicar, agrupar y enrutar alertas.

Ejemplo de una métrica expuesta por una app (formato Prometheus):

```
# HELP http_requests_total Total de requests HTTP recibidos
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200"} 1547
http_requests_total{method="POST",status="500"} 12
```

Ejemplo de query en PromQL para calcular la tasa de requests por segundo en los últimos 5 minutos:

```promql
rate(http_requests_total[5m])
```

Tipos de métricas en Prometheus:

- **Counter**: valor que solo crece (ej: total de requests).
- **Gauge**: valor que sube y baja (ej: uso de memoria actual).
- **Histogram**: distribución de valores en buckets (ej: latencia de requests).
- **Summary**: similar al histogram, pero calcula cuantiles en el cliente.

Para exponer métricas de componentes que no las generan nativamente (nodos, bases de datos, hardware) se usan **exporters**, como `node_exporter` (métricas de sistema operativo) o `kube-state-metrics` (estado de objetos de Kubernetes: Deployments, Pods, etc.).

## Visualización: Grafana

**Grafana** es la herramienta estándar para construir dashboards a partir de fuentes de datos como Prometheus, Loki o Elasticsearch. No almacena datos: consulta fuentes externas y las renderiza. Permite definir alertas visuales y es agnóstico de la fuente de datos, lo cual lo hace el complemento natural de Prometheus dentro del stack CNCF.

## Health checks en Kubernetes (probes)

Kubernetes usa **probes** para determinar el estado de salud de un contenedor y actuar en consecuencia. Son parte fundamental de la observability porque permiten al sistema auto-remediar sin intervención humana:

- **Liveness probe**: si falla, Kubernetes **reinicia** el contenedor. Detecta procesos "colgados" (deadlocks).
- **Readiness probe**: si falla, el Pod se **saca del Service** (deja de recibir tráfico) pero no se reinicia. Indica si el contenedor está listo para atender requests.
- **Startup probe**: usada en apps con arranque lento; deshabilita liveness/readiness hasta que la app termine de iniciar, evitando reinicios prematuros.

Ejemplo de manifiesto con las tres probes:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-app
spec:
  containers:
  - name: app
    image: myapp:1.0
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 10
      periodSeconds: 15
    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
      periodSeconds: 5
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30
      periodSeconds: 10
```

Comandos útiles para inspeccionar el estado de salud:

```bash
kubectl get pods
# NAME      READY   STATUS    RESTARTS   AGE
# web-app   0/1     Running   3          5m   <- readiness falla, restarts por liveness

kubectl describe pod web-app
# ... Events:
#   Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 500
```

## Logging

Los logs en Kubernetes son efímeros por naturaleza: cuando un Pod muere, sus logs locales se pierden. El patrón estándar es centralizarlos con un stack de tipo **EFK/ELK** (Elasticsearch/Fluentd/Fluent Bit + Kibana) o el stack nativo de Prometheus, **Grafana Loki** (indexa solo metadata/labels, no el texto completo, lo que lo hace más liviano).

- **Fluentd** / **Fluent Bit**: agentes que corren como **DaemonSet** en cada nodo, recolectan los logs de `/var/log` (o vía el container runtime) y los reenvían a un backend centralizado.
- **Loki**: diseñado para integrarse con Grafana y usar el mismo modelo de labels que Prometheus.

Comando básico para ver logs de un Pod (nivel de debugging, no reemplaza la centralización):

```bash
kubectl logs web-app -c app --previous   # logs del contenedor anterior tras un crash
```

## Distributed Tracing

En una arquitectura de microservicios, un solo request de usuario puede atravesar decenas de servicios. El **distributed tracing** permite reconstruir ese recorrido end-to-end mediante un **trace**, compuesto de múltiples **spans** (cada span representa una unidad de trabajo, ej: una llamada a un servicio o a una base de datos).

Herramientas de referencia en el ecosistema CNCF:

- **Jaeger**: proyecto graduado del CNCF, originado en Uber, para tracing distribuido.
- **OpenTelemetry (OTel)**: proyecto CNCF que unifica la **instrumentación** (generación de métricas, logs y traces) bajo un estándar único y vendor-neutral, con SDKs por lenguaje y un componente central, el **OTel Collector**, que recibe, procesa y exporta telemetría hacia distintos backends (Prometheus, Jaeger, Loki, etc.). OpenTelemetry es el resultado de la fusión de OpenTracing y OpenCensus, y es hoy el estándar recomendado por sobre instrumentar cada pilar por separado.

## Otras consideraciones

- **Cost monitoring**: la observability también cubre la visibilidad de costos en entornos cloud native (ej. **Kubecost**), permitiendo atribuir gasto de infraestructura a namespaces, Deployments o equipos.
- El examen KCNA espera reconocer qué herramienta corresponde a qué pilar (Prometheus → metrics, Fluentd/Loki → logs, Jaeger/OTel → traces) y el rol de las probes como mecanismo de auto-healing de Kubernetes.

## Referencias

- KCNA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes – Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes – Logging Architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Prometheus – Documentation: https://prometheus.io/docs/introduction/overview/
- Prometheus – Metric Types: https://prometheus.io/docs/concepts/metric_types/
- Grafana – Documentation: https://grafana.com/docs/grafana/latest/
- Grafana Loki – Documentation: https://grafana.com/docs/loki/latest/
- OpenTelemetry – Documentation: https://opentelemetry.io/docs/
- Jaeger – Documentation: https://www.jaegertracing.io/docs/latest/
- CNCF – Cloud Native Interactive Landscape (Observability & Analysis): https://landscape.cncf.io/