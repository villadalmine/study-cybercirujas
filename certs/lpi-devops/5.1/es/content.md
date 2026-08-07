# Material de estudio: LPI DevOps Tools Engineer (Examen 701-100)
## Tema 705.1: Operaciones de TI y Monitoreo (Ponderación: 6.67)

---

## 1. Motivación y problema arquitectónico en producción

### 1.1 El cambio de paradigma operacional
En los entornos monolíticos legados, el monitoreo del sistema era predominantemente estático, centrado en el host y orientado a caja negra. Los operadores dependían de barridos periódicos de ICMP ping y chequeos de NRPE/SNMP (por ejemplo, a través de Nagios o Zabbix) para determinar la alcanzabilidad del nodo y la existencia del proceso. Este modelo falla en las infraestructuras modernas de microservicios, entornos contenerizados y nativos de la nube debido a varias transformaciones en la realidad operacional:

1. **Efimeridad de corta vida y dinámica**: Los Pods y contenedores se escalan elásticamente y viven durante horas o minutos. Los archivos estáticos de configuración de IP son incapaces de rastrear cargas de trabajo dinámicas.
2. **Alta dimensionalidad**: Los sistemas distribuidos fallan en modos complejos y parciales. Saber si un host está vivo es insuficiente; los ingenieros necesitan visibilidad sobre los códigos de estado HTTP por endpoint, códigos de estado gRPC, tasas de profundidad de colas, agotamiento de pools de bases de datos y latencias de cola (tail latencies) a lo largo de cientos de microservicios.
3. **Limitaciones de caja negra**: El sondeo (polling) externo no puede inspeccionar los estados internos de la aplicación, las pausas de recolección de basura (garbage collection), las longitudes de cola del thread pool o las asignaciones del heap de memoria.

### 1.2 El problema arquitectónico en producción
Considere un clúster de Kubernetes empresarial que alberga 50 microservicios a través de 200 nodos que ejecutan 3,000 réplicas de Pods. La infraestructura experimenta autoescalado dinámico, despliegues frecuentes y aislamiento multi-tenant. 

```
                                 [ Push / Pull Topology Boundary ]
                                                 │
┌─────────────────────────┐                      │      ┌───────────────────────────────┐
│ Dynamic Kubernetes Pods │ ──(Scrape / Pull)───┼────► │   Prometheus Server (TSDB)    │
│  [ App A ] [ App B ]    │   HTTP /metrics      │      │ ┌───────────┐ ┌─────────────┐ │
└─────────────────────────┘                      │      │ │ Head Block│ │ Compaction  │ │
             │                                   │      │ └───────────┘ └─────────────┘ │
             ▼ (Ephemeral Jobs)                  │      └───────────────┬───────────────┘
┌─────────────────────────┐                      │                      │ Evaluates
│  Batch / Serverless     │ ──(Push Metrics)───► │ ┌──────────────────┐ │ Alert Rules
│  [ Short-Lived Jobs ]   │   HTTP POST          │ │  Pushgateway     │◄┘
└─────────────────────────┘                      │ └──────────────────┘ 
                                                 │                      │ Routes Alerts
                                                 │                      ▼
                                                 │      ┌───────────────────────────────┐
                                                 │      │         Alertmanager          │
                                                 │      └───────────────┬───────────────┘
                                                 │                      │
                                                 │                      ▼
                                                 │            [ PagerDuty / Slack ]
```

La implementación de observabilidad en esta arquitectura introduce desafíos de ingeniería fundamentales:

* **Explosión de alta cardinalidad**: Las métricas acompañadas con etiquetas de alta cardinalidad (por ejemplo, `user_id`, `email`, `order_id`, URLs sin redactar) provocan un crecimiento exponencial en las claves de índice de series temporales, colapsando las bases de datos de series temporales (TSDB) debido a condiciones de falta de memoria (Out-Of-Memory / OOM).
* **Sobrecarga en el descubrimiento de objetivos de scrape (Scrape Target Discovery Overhead)**: El mantenimiento manual de objetivos es imposible. El plano de control de monitoreo debe interactuar continuamente con el API server de Kubernetes (`Endpoints`, `Services`, `Pods`) para actualizar los objetivos de scrape dinámicamente sin perder métricas durante la rotación de Pods (pod churn).
* **Topología de red y límites de NAT**: Los motores de scrape se basan en una arquitectura **basada en Pull** sobre HTTP/HTTPS. Cuando los objetivos residen detrás de gateways NAT estrictos, routers de borde o dentro de enclaves de seguridad aislados, un modelo puramente pull falla sin componentes proxy intermedios como el Prometheus `Pushgateway` o proxies de borde.

### 1.3 Terminología del nivel de servicio y marcos de observabilidad

#### 1.3.1 Especificaciones de nivel de servicio (SLA, SLO, SLI)
* **SLI (Service Level Indicator / Indicador de Nivel de Servicio)**: Una medida cuantitativa cuidadosamente definida del rendimiento de un servicio observada en tiempo real.
  $$\text{SLI} = \frac{\text{Good Events}}{\text{Total Events}} \times 100$$
  *Ejemplo PromQL*:
  ```promql
  sum(rate(http_requests_total{job="payment-service", status=~"2..|3.."}[5m]))
  /
  sum(rate(http_requests_total{job="payment-service"}[5m]))
  ```
* **SLO (Service Level Objective / Objetivo de Nivel de Servicio)**: Un valor objetivo o rango de valores para un nivel de servicio medido por un SLI, acordado por los equipos de producto y SRE (por ejemplo, "La latencia SLI de la API de pagos debe ser < 200ms para el 99.9% de las peticiones en una ventana móvil de 30 días").
* **SLA (Service Level Agreement / Acuerdo de Nivel de Servicio)**: Un contrato explícito o implícito con los usuarios finales que incluye consecuencias financieras o legales por no cumplir con los SLOs.

#### 1.3.2 Monitoreo funcional vs. no funcional
* **Propiedades funcionales**: Verificación de que la lógica de negocio produce resultados correctos (por ejemplo, la finalización del procesamiento de pedidos, la validación de confirmación de transacciones en la base de datos).
* **Propiedades no funcionales**: Verificación de las métricas operacionales del sistema (por ejemplo, utilización de recursos, disponibilidad del sistema, rendimiento throughput, tasas de error, distribución de latencia).

#### 1.3.3 Marcos de observabilidad
* **Las 4 señales doradas (Google SRE)**:
  1. **Latencia**: El tiempo necesario para atender una petición (distinguiendo entre latencias de peticiones exitosas y fallidas).
  2. **Tráfico**: La demanda ejercida sobre el sistema (por ejemplo, peticiones HTTP por segundo, operaciones de I/O por segundo).
  3. **Errores**: La tasa de peticiones que fallan explícitamente (HTTP 5xx), implícitamente (HTTP 200 con un payload de falla), o por tiempo de espera de política (policy timeout).
  4. **Saturación**: La medida de plenitud del sistema (por ejemplo, utilización de CPU, presión de memoria, saturación del thread pool, espacio en disco).
* **Método RED (Servicios)**: **R**ate (peticiones/seg), **E**rrors (peticiones fallidas/seg), **D**uration (distribución de latencia).
* **Método USE (Hardware/Nodos)**: **U**tilization (porcentaje de tiempo ocupado), **S**aturation (longitud de la cola), **E**rrors (recuento de errores).

---

## 2. Comparaciones técnicas y balance de arquitectura (Trade-Offs)

### 2.1 Monitoreo Black-Box vs. White-Box
El monitoreo Black-box (caja negra) trata el sistema como una caja negra, probando el comportamiento externo sin acceso interno. El monitoreo White-box (caja blanca) inspecciona métricas internas expuestas por el código de la aplicación mediante librerías de instrumentación.

| Métrica técnica / Característica | Monitoreo Black-Box (ej. Ping, Synthetic HTTP Check) | Monitoreo White-Box (ej. Prometheus Exporters, Client SDKs) |
| :--- | :--- | :--- |
| **Alcance de visibilidad** | Disponibilidad externa, alcanzabilidad de red, validez de certificados TLS. | Colas internas, estados del thread pool, uso del heap de memoria, recolección de basura, bloqueos de pool de DB. |
| **Atribución de causa raíz** | Baja. Indica *que* un servicio es inalcanzable o está fallando. | Alta. Explica *por qué* un servicio está fallando (ej. agotamiento de pool de DB, OOM del heap). |
| **Huella de red** | Sondas externas HTTP/ICMP originadas fuera del service mesh. | Endpoints de scrape en el proceso (`/metrics`) extraídos sobre redes locales. |
| **Velocidad de detección** | Intervalos de sondeo (ej. 30s–60s); alta latencia para la detección de fallas. | Scrape de métricas en tiempo real (ej. 5s–15s); actualizaciones de contadores internos en menos de un segundo. |
| **Costo de mantenimiento** | Configuración inicial baja; frágil ante cambios en la interfaz de usuario o esquemas de APIs públicas. | Requiere instrumentación de código de aplicación, dependencias de librerías y mantenimiento de métricas. |

### 2.2 Arquitectura de métricas Pull vs. Push

| Dimensión | Modelo Pull (ej. Prometheus Nativo) | Modelo Push (ej. StatsD, Graphite, Pushgateway) |
| :--- | :--- | :--- |
| **Centralización del plano de control** | El servidor central controla la frecuencia de scrape, jitter y descubrimiento de objetivos. | Las instancias de aplicación deciden de forma independiente cuándo y dónde enviar datos. |
| **Detección de estado del objetivo (Liveness)** | Inmediata. Si un scrape falla (`up == 0`), Prometheus registra la falla del objetivo. | Indirecta. La ausencia de datos puede significar que el objetivo está inactivo o se ha caído. |
| **Protección contra sobrecarga** | Alta. El servidor limita la ingesta de métricas controlando los bucles de scrape. | Baja. Los picos repentinos de tráfico hacen que el código cliente inunde los backends de monitoreo. |
| **Trabajos de corta vida / Batch** | Compleja. Requiere almacenamiento intermedio como `Pushgateway`. | Nativa. El trabajo en lote envía métricas al finalizar la ejecución y sale inmediatamente. |
| **Complejidad de Red / Firewall** | Requiere acceso directo a la red desde el servidor de Prometheus a la IP/puerto del Pod. | Fácil detrás de NAT; el tráfico saliente de la aplicación al backend está permitido por defecto. |

### 2.3 Comparación de arquitecturas de almacenamiento TSDB

| Arquitectura | Mecánica del motor de almacenamiento | Modelo de alta disponibilidad (HA) | Escalabilidad horizontal |
| :--- | :--- | :--- | :--- |
| **Prometheus Native TSDB** | WAL (Write-Ahead Log) de solo anexado en disco local, bloques inmutables de 2 horas, chunks mapeados en memoria. | Scrape dual sin recursos compartidos (instancias de Prometheus idénticas e independientes). | Escalado vertical únicamente; sin sharding nativo multinodo horizontal. |
| **Thanos** | Arquitectura Sidecar/Receiver que sube bloques TSDB compactados a Object Storage (S3/GCS). | Motor de consultas global (Global Query Engine) que desduplica métricas en pares de réplicas. | Escalado horizontal ilimitado de almacenamiento mediante object store + capa de consultas stateless. |
| **VictoriaMetrics** | Arquitectura tipo MergeTree, codificación personalizada, asignación de memoria optimizada. | Versión de clúster con nodos divididos de Almacenamiento, Índice y Router. | Alta escalabilidad horizontal nativa con bajo consumo de CPU y RAM. |

---

## 3. Manifiestos y configuración de nivel de producción

### 3.1 Manifiesto de configuración del servidor (`prometheus.yml`)
El siguiente manifiesto define una instancia de Prometheus lista para producción que incluye descubrimiento de endpoints de Kubernetes, reglas avanzadas de relabeling y enrutamiento de Alertmanager.

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s
  external_labels:
    cluster: 'prod-us-east-1'
    environment: 'production'

alerting:
  alertmanagers:
    - scheme: http
      path_prefix: /
      timeout: 10s
      kubernetes_sd_configs:
        - role: endpoints
          namespaces:
            names:
              - monitoring
      relabel_configs:
        - source_labels: [__meta_kubernetes_service_name]
          action: keep
          regex: alertmanager
        - source_labels: [__meta_kubernetes_endpoint_port_name]
          action: keep
          regex: web

rule_files:
  - "/etc/prometheus/rules/*.rules.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - monitoring
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: node-exporter
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)

  - job_name: 'kubernetes-cadvisor'
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    kubernetes_sd_configs:
      - role: node
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics/cadvisor

  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: 'true'
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: kubernetes_pod_name
```

### 3.2 Configuración de Alertmanager (`alertmanager.yml`)
Manifiesto de Alertmanager en producción con árboles de enrutamiento, agrupación de alertas, reglas de inhibición y receptores de integración con Slack/PagerDuty.

```yaml
global:
  resolve_timeout: 5m
  pagerduty_url: 'https://events.pagerduty.com/v2/enqueue'
  slack_api_url: 'https://hooks.slack.com/services/WORKSPACE/CHANNEL/TOKEN'

route:
  group_by: ['cluster', 'namespace', 'alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: 'slack-default'
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty-high-priority'
      continue: true
    - match:
        severity: warning
      receiver: 'slack-warnings'

inhibit_rules:
  - source_match:
      alertname: 'NodeDown'
    target_match:
      alertname: 'InstanceDown'
    equal: ['node']

receivers:
  - name: 'slack-default'
    slack_configs:
      - channel: '#ops-alerts'
        send_resolved: true
        title: '][ Cluster: '
        text: "<!subteam^S0000000> *Description:* \n*Details:*\n"

  - name: 'slack-warnings'
    slack_configs:
      - channel: '#ops-warnings'
        send_resolved: true
        title: '][ Cluster: '
        text: "*Alert:* \n*Summary:* "

  - name: 'pagerduty-high-priority'
    pagerduty_configs:
      - service_key: 'b8a7c6d5e4f3a2b1c0d9e8f7a6b5c4d3'
        severity: 'critical'
        send_resolved: true
```

### 3.3 Reglas de grabación y alerta (`slos-and-alerts.rules.yml`)
Definiciones completas de reglas que calculan las proporciones de error de peticiones de 5 minutos (SLIs) y generan alertas de producción accionables.

```yaml
groups:
  - name: api_sli_slo_rules
    rules:
      - record: job:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job, status)

      - record: job:http_requests_errors:ratio_rate5m
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
          /
          sum(rate(http_requests_total[5m])) by (job)

  - name: infrastructure_alert_rules
    rules:
      - alert: TargetServiceDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "Prometheus target unreachable: {{ $labels.instance }}"
          description: "Target {{ $labels.instance }} of job {{ $labels.job }} has been down for more than 3 minutes."

      - alert: APIHighErrorRate
        expr: job:http_requests_errors:ratio_rate5m{job="payment-api"} > 0.05
        for: 5m
        labels:
          severity: critical
          team: payments
        annotations:
          summary: "High HTTP 5xx Error Rate on {{ $labels.job }}"
          description: "Payment API error rate is {{ $value | humanizePercentage }} (threshold > 5%) over 5 minutes."

      - alert: NodeMemorySaturation
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes > 0.90
        for: 10m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "High Memory Utilization on Node {{ $labels.instance }}"
          description: "Node memory usage is at {{ $value | humanizePercentage }} for over 10 minutes."
```

### 3.4 Manifiesto completo de Deployment de Kubernetes (`prometheus-deployment.yaml`)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-k8s
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-k8s
rules:
- apiGroups: [""]
  resources:
  - nodes
  - nodes/metrics
  - services
  - endpoints
  - pods
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources:
  - configmaps
  verbs: ["get"]
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-k8s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-k8s
subjects:
- kind: ServiceAccount
  name: prometheus-k8s
  namespace: monitoring
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-server
  namespace: monitoring
  labels:
    app: prometheus
    component: server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
      component: server
  template:
    metadata:
      labels:
        app: prometheus
        component: server
    spec:
      serviceAccountName: prometheus-k8s
      containers:
      - name: prometheus
        image: prom/prometheus:v2.45.0
        args:
          - "--config.file=/etc/prometheus/prometheus.yml"
          - "--storage.tsdb.path=/prometheus"
          - "--storage.tsdb.retention.time=15d"
          - "--storage.tsdb.retention.size=50GB"
          - "--web.enable-lifecycle"
        ports:
          - name: web
            containerPort: 9090
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"
        securityContext:
          runAsUser: 65534
          runAsGroup: 65534
          runAsNonRoot: true
          readOnlyRootFilesystem: true
        readinessProbe:
          httpGet:
            path: /-/ready
            port: 9090
          initialDelaySeconds: 30
          timeoutSeconds: 3
        livenessProbe:
          httpGet:
            path: /-/healthy
            port: 9090
          initialDelaySeconds: 30
          timeoutSeconds: 3
        volumeMounts:
        - name: config-volume
          mountPath: /etc/prometheus
        - name: rules-volume
          mountPath: /etc/prometheus/rules
        - name: storage-volume
          mountPath: /prometheus
      volumes:
      - name: config-volume
        configMap:
          name: prometheus-core-config
      - name: rules-volume
        configMap:
          name: prometheus-rules-config
      - name: storage-volume
        emptyDir: {}
```

---

## 4. Comandos CLI y trazas de ejecución en terminal

### 4.1 Validación de sintaxis de configuración y reglas (`promtool`)

La utilidad `promtool` es la herramienta CLI estándar para validar la sintaxis de configuración y probar la lógica de alertas antes del despliegue.

```bash
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
  SUCCESS: 1 rule files found
  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file
```

```bash
$ promtool check rules /etc/prometheus/rules/slos-and-alerts.rules.yml
Checking /etc/prometheus/rules/slos-and-alerts.rules.yml
  SUCCESS: 3 rules found
```

### 4.2 Consulta de APIs Instant y Range de Prometheus a través de `curl`

#### Ejecución de Instant Query (`/api/v1/query`)
Ejecución de una Instant Query contra la API HTTP de Prometheus para calcular las tasas actuales de peticiones HTTP:

```bash
$ curl -s -X POST http://prometheus.monitoring.svc.cluster.local:9090/api/v1/query \
  --data-urlencode 'query=sum(rate(http_requests_total[5m])) by (job)' | jq .
```
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "job": "payment-api"
        },
        "value": [
          1691398800.123,
          "142.85"
        ]
      },
      {
        "metric": {
          "job": "user-service"
        },
        "value": [
          1691398800.123,
          "48.12"
        ]
      }
    ]
  }
}
```

#### Ejecución de Range Query (`/api/v1/query_range`)
Obtención de tendencias de latencia sobre una ventana de 15 minutos con una resolución de paso (step resolution) de 5 minutos:

```bash
$ curl -s -X POST http://prometheus.monitoring.svc.cluster.local:9090/api/v1/query_range \
  -d "query=histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))" \
  -d "start=1691395200" \
  -d "end=1691396100" \
  -d "step=300s" | jq .
```
```json
{
  "status": "success",
  "data": {
    "resultType": "matrix",
    "result": [
      {
        "metric": {},
        "values": [
          [ 1691395200, "0.145" ],
          [ 1691395500, "0.152" ],
          [ 1691395800, "0.489" ],
          [ 1691396100, "0.138" ]
        ]
      }
    ]
  }
}
```

### 4.3 Ingesta TSDB y análisis de bloques de almacenamiento

Análisis de cardinalidad del directorio de almacenamiento TSDB, recuento de series y huella de etiquetas directamente en disco usando `promtool`:

```bash
$ promtool tsdb analyze /prometheus
Block ID: 01H77F4P3Z3V8B9K019M7V0Z8K
Duration: 2h0m0s
Series: 145210
Label names: 42
Postings (label name -> label value pairs): 8920

Top 10 label names by series count:
  namespace: 145210
  pod: 138400
  container: 122100
  instance: 98400
  job: 98400
  __name__: 85400
  status: 42000
  le: 32000
  method: 18000
  endpoint: 12000

Top 10 highest cardinality labels:
  pod: 1420
  instance: 210
  endpoint: 84
  __name__: 642
  status: 12
```

### 4.4 Recarga dinámica de configuración a través de HTTP

Disparando la recarga en caliente de configuración sin reiniciar el contenedor del proceso Prometheus:

```bash
$ curl -X POST http://localhost:9090/-/reload
$ echo $?
0
```

---

## 5. Verificación, diagnóstico de fallas y solución de problemas SRE (Troubleshooting)

### 5.1 Diagnóstico de fallas en objetivos de scrape (`UP == 0`)

#### Síntoma
La alerta `TargetServiceDown` se dispara. La consulta PromQL `up{job="payment-api"} == 0` devuelve resultados de vectores activos.

#### Guía de diagnóstico (Playbook)
1. **Inspeccionar el estado del objetivo mediante la API de Prometheus**:
   Consultar el endpoint de estado de objetivos para obtener mensajes de error de scrape:
   ```bash
   $ curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="payment-api")'
   ```
   *Salida de fragmento de error esperado*:
   ```json
   {
     "discoveredLabels": {
       "__address__": "10.244.3.45:8080"
     },
     "labels": {
       "instance": "10.244.3.45:8080",
       "job": "payment-api"
     },
     "scrapeUrl": "http://10.244.3.45:8080/metrics",
     "lastError": "context deadline exceeded",
     "lastScrape": "2026-08-07T08:15:30.12345678Z",
     "health": "unhealthy"
   }
   ```

2. **Verificación de conectividad de red y firewall**:
   Ejecutar `curl` o `nc` desde el namespace del contenedor de Prometheus para probar la alcanzabilidad del endpoint:
   ```bash
   $ kubectl exec -n monitoring deploy/prometheus-server -c prometheus -- \
     curl -iv -m 5 http://10.244.3.45:8080/metrics
   ```
   *Indicación de falla*:
   `curl: (28) Connection timed out after 5001 milliseconds`

3. **Análisis de causa raíz y matriz de resolución**:
   * **`context deadline exceeded`**: La generación del payload de métricas del objetivo es demasiado lenta (> `scrape_timeout`). *Solución*: Optimizar la lógica de recolección de métricas de la aplicación o incrementar `scrape_timeout`.
   * **`connection refused`**: La aplicación no está escuchando en el puerto 8080 o el proceso se cayó. *Solución*: Inspeccionar `kubectl logs` y `kubectl describe pod`.
   * **`HTTP 404 Not Found`**: Discrepancia en la ruta de métricas (`/metrics` vs `/actuator/prometheus`). *Solución*: Corregir las anotaciones `prometheus.io/path` del objetivo.

### 5.2 Solución de problemas de falta de memoria por alta cardinalidad (OOMKilled)

#### Síntoma
El proceso Prometheus se cae repetidamente con el estado de kernel de Linux `OOMKilled` (código de salida 137). El uso de RAM aumenta exponencialmente tras la ingesta de objetivos.

#### Guía de diagnóstico y mitigación
1. **Localizar métricas de alta cardinalidad**:
   Consultar el endpoint de estado de runtime de la TSDB de Prometheus:
   ```bash
   $ curl -s http://localhost:9090/api/v1/status/tsdb | jq .data.headStats
   ```
   ```json
   {
     "numSeries": 2450190,
     "numLabelPairs": 120490,
     "chunkCount": 4901200,
     "minTime": 1691395200000,
     "maxTime": 1691402400000
   }
   ```

2. **Identificar métricas y etiquetas problemáticas**:
   Usar `promtool` o endpoints de consulta administrativa para exponer los nombres de etiquetas de alta cardinalidad:
   ```bash
   $ curl -s http://localhost:9090/api/v1/status/tsdb | jq .data.seriesCountByMetricName
   ```
   *Ejemplo de salida*:
   ```json
   [
     { "name": "http_requests_total", "value": 1850000 },
     { "name": "node_cpu_seconds_total", "value": 45000 }
   ]
   ```

3. **Remediación mediante reetiquetado de métricas (`metric_relabel_configs`)**:
   Descartar etiquetas no conformes (por ejemplo, `user_id`, `client_ip`, `order_uuid`) *antes* de la ingesta en el almacenamiento:
   ```yaml
   scrape_configs:
     - job_name: 'payment-api'
       metric_relabel_configs:
         - source_labels: [__name__]
           regex: 'http_requests_total'
           action: keep
         - regex: '(user_id|client_ip|order_uuid)'
           action: labeldrop
   ```

### 5.3 Métricas obsoletas en trabajos efímeros de Prometheus Pushgateway

#### Trampa técnica
A diferencia de los objetivos pull estándar, `Pushgateway` conserva las métricas de series temporales enviadas indefinidamente hasta que se eliminen explícitamente a través de llamadas a la API. Si un trabajo en lote falla o deja de ejecutarse, Pushgateway continúa sirviendo el último conjunto de métricas enviadas a Prometheus, presentando un estado saludable falso.

#### Arquitectura de mitigación en producción
1. **Patrón Pushgateway Textfile Exporter**: Para cargas de trabajo en lote en nodos, prefiera el colector `textfile` de Node Exporter sobre Pushgateway cuando sea posible.
2. **Eliminación automatizada de métricas**: Implemente pasos de limpieza explícitos en los wrappers de trabajos en lote utilizando llamadas HTTP `DELETE` al finalizar el trabajo:
   ```bash
   # Push metrics on job start
   echo "job_last_run_timestamp_seconds $(date +%s)" | \
     curl --data-binary @- http://pushgateway.monitoring.svc:9191/metrics/job/nightly_batch/instance/node-01

   # Execute batch operation
   /usr/local/bin/run_batch.sh

   # Explicitly wipe metrics from Pushgateway upon termination
   curl -X DELETE http://pushgateway.monitoring.svc:9191/metrics/job/nightly_batch/instance/node-01
   ```

---

## 6. Referencias

* **Linux Professional Institute (LPI) DevOps Tools Engineer (Exam 701-100 Overview)**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Prometheus Official Documentation (Configuration & Architecture)**  
  [https://prometheus.io/docs/prometheus/latest/configuration/configuration/](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
* **Prometheus Alerting Rules & Alertmanager Routing**  
  [https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
* **Google Site Reliability Engineering (SRE) Book: Monitoring Distributed Systems**  
  [https://sre.google/sre-book/monitoring-distributed-systems/](https://sre.google/sre-book/monitoring-distributed-systems/)
* **Google SRE Book: Service Level Objectives**  
  [https://sre.google/sre-book/service-level-objectives/](https://sre.google/sre-book/service-level-objectives/)
* **CNCF Prometheus TSDB Storage Format Specification**  
  [https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/README.md](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/README.md)