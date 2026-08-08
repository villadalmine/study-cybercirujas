# Ejercicios Guiados — Tema 2.1: Implementing Monitoring, Alerting, Logging, and Tracing Solutions

> **Certificación:** CNPE (Cloud Native Platform Engineer)
> **Peso en el examen:** 6.66 %
> **Prerrequisitos de laboratorio:** un cluster Kubernetes ≥ 1.28 (kind, k3d o minikube sirven), `kubectl`, `helm` v3 y ~4 GB de RAM libres. Todos los `namespace` se crean en el propio ejercicio.
> **Duración estimada:** 3–4 h en total; cada ejercicio es autocontenido y puede correrse por separado.

Estos ejercicios recorren los **cuatro pilares de observabilidad** que el syllabus del CNPE agrupa en el dominio *Observability*: **metrics, alerting, logs y traces**. El objetivo de plataforma no es solo "instalar Prometheus", sino entregar estas capacidades como *self-service* para los equipos de aplicación (ServiceMonitor, PrometheusRule, pipelines de logs y traces declarativos). Trabajaremos con el ecosistema de referencia CNCF: **Prometheus + Alertmanager**, **Grafana Loki**, y **OpenTelemetry + Jaeger/Tempo**.

Fuente del temario: [CNCF Curriculum — CNPE](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

---

## Ejercicio 1 — Desplegar el stack de métricas con Prometheus Operator

**Meta:** entender la diferencia entre *scraping* configurado a mano y *scraping* declarativo vía CRDs, y ver cómo el Operator materializa un `ServiceMonitor` en configuración real de Prometheus.

### Bloque A — Instalación

1. Creá el namespace de observabilidad y agregá el repo de Helm:

```bash
kubectl create namespace observability
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

2. Instalá `kube-prometheus-stack` (Prometheus Operator + Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics) en una sola release:

```bash
helm install kps prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --set prometheus.prometheusSpec.retention=6h \
  --set prometheus.prometheusSpec.scrapeInterval=30s \
  --set grafana.adminPassword=admin
```

3. Esperá a que todo quede `Running` y observá qué se creó:

```bash
kubectl -n observability rollout status statefulset/prometheus-kps-kube-prometheus-stack-prometheus
kubectl -n observability get pods
```

Salida esperada (abreviada):

```
NAME                                                     READY   STATUS    RESTARTS   AGE
alertmanager-kps-kube-prometheus-stack-alertmanager-0    2/2     Running   0          2m
kps-grafana-6c9d5b8f9c-xh2kd                             3/3     Running   0          2m
kps-kube-state-metrics-77b8f7f6b9-9l6qd                  1/1     Running   0          2m
kps-prometheus-node-exporter-abcde                       1/1     Running   0          2m
prometheus-kps-kube-prometheus-stack-prometheus-0        2/2     Running   0          2m
```

4. Fijate en los **CRDs** que instaló el Operator — son la interfaz declarativa de la plataforma:

```bash
kubectl get crds | grep monitoring.coreos.com
```

```
alertmanagerconfigs.monitoring.coreos.com
alertmanagers.monitoring.coreos.com
podmonitors.monitoring.coreos.com
probes.monitoring.coreos.com
prometheuses.monitoring.coreos.com
prometheusrules.monitoring.coreos.com
scrapeconfigs.monitoring.coreos.com
servicemonitors.monitoring.coreos.com
```

> **Preguntas — Bloque A**
> A1. El Prometheus corre como un `StatefulSet`, no como un `Deployment`. ¿Por qué es la elección correcta para la TSDB de Prometheus?
> A2. ¿Cuál es la función del componente `prometheus-operator` frente al pod `prometheus-...-0`? ¿Quién hace el scraping y quién genera la configuración?
> A3. ¿Qué aporta `kube-state-metrics` que **no** puede darte `node-exporter`? Dá un ejemplo de métrica de cada uno.

### Bloque B — Cómo el ServiceMonitor se convierte en scrape config

5. Mirá el `Secret` donde el Operator guarda la config generada (está gzip-comprimida):

```bash
kubectl -n observability get secret \
  prometheus-kps-kube-prometheus-stack-prometheus \
  -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | head -40
```

6. Abrí la UI de Prometheus y revisá los targets activos:

```bash
kubectl -n observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
# En otra terminal / navegador: http://localhost:9090/targets
```

7. En **Status → Configuration** de esa UI, buscá un `job_name` que empiece con `serviceMonitor/`. Notá el patrón `serviceMonitor/<namespace>/<nombre>/<endpoint-index>`.

> **Preguntas — Bloque B**
> B1. ¿Por qué el Operator guarda la configuración de scraping en un `Secret` y la recarga en caliente, en vez de que vos edites `prometheus.yml` a mano?
> B2. Un `ServiceMonitor` selecciona `Service`s por labels, pero Prometheus **no** scrapea el `ClusterIP` del Service. ¿Qué scrapea realmente y qué objeto de Kubernetes usa para descubrir esas direcciones?
> B3. ¿En qué se diferencia un `PodMonitor` de un `ServiceMonitor`, y cuándo elegirías el primero?

---

## Ejercicio 2 — Instrumentar una app y exponer métricas custom

**Meta:** publicar métricas propias de una aplicación, descubrirlas declarativamente con un `ServiceMonitor` y consultarlas con PromQL. Este es el flujo *self-service* que un platform engineer ofrece a los equipos.

### Bloque A — Desplegar una app instrumentada

1. Desplegá una aplicación de ejemplo que ya expone `/metrics` en formato Prometheus. Usamos `prom/prometheus`'s demo, pero acá desplegamos un app propio mínimo con `nginx-prometheus-exporter` para que sea reproducible. Guardá esto como `app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
  labels:
    app: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
        - name: exporter
          image: nginx/nginx-prometheus-exporter:1.4.0
          args:
            - "--nginx.scrape-uri=http://127.0.0.1:80/stub_status"
          ports:
            - name: metrics
              containerPort: 9113
      volumes:
        - name: conf
          configMap:
            name: web-conf
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-conf
  namespace: demo
data:
  default.conf: |
    server {
      listen 80;
      location / { return 200 "ok\n"; }
      location /stub_status {
        stub_status on;
        access_log off;
      }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
  labels:
    app: web
spec:
  selector:
    app: web
  ports:
    - name: metrics
      port: 9113
      targetPort: metrics
    - name: http
      port: 80
      targetPort: http
```

2. Aplicá:

```bash
kubectl create namespace demo
kubectl apply -f app.yaml
kubectl -n demo rollout status deployment/web
```

3. Verificá que el endpoint de métricas responde:

```bash
kubectl -n demo port-forward deploy/web 9113:9113 &
curl -s localhost:9113/metrics | grep '^nginx_'
```

Salida esperada (abreviada):

```
nginx_connections_accepted 12
nginx_connections_active 1
nginx_connections_handled 12
nginx_http_requests_total 34
nginx_up 1
```

> **Preguntas — Bloque A**
> A1. En este Deployment corren dos contenedores en el mismo Pod. ¿Por qué el patrón *sidecar exporter* comparte `network namespace` y por eso el exporter puede llegar a `127.0.0.1:80`?
> A2. El `Service` expone dos puertos (`metrics` y `http`). ¿Por qué conviene separar el puerto de métricas del puerto de tráfico de usuarios en producción?

### Bloque B — Descubrimiento declarativo con ServiceMonitor

4. Creá el `ServiceMonitor`. **Atención al label** `release: kps`: el Prometheus de `kube-prometheus-stack` por defecto solo selecciona ServiceMonitors con ese label (via `serviceMonitorSelector`). Guardá como `sm.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: web
  namespace: demo
  labels:
    release: kps          # requerido por el serviceMonitorSelector del stack
spec:
  selector:
    matchLabels:
      app: web            # selecciona el Service, no el Pod
  namespaceSelector:
    matchNames:
      - demo
  endpoints:
    - port: metrics       # nombre del puerto en el Service
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
```

5. Aplicá y confirmá que Prometheus lo tomó (esperá ~30 s):

```bash
kubectl apply -f sm.yaml
# En la UI (port-forward del Ej.1): http://localhost:9090/targets
# Debe aparecer el job "serviceMonitor/demo/web/0" con 2 targets UP
```

6. Comprobá desde la API de Prometheus que la métrica ya está indexada:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=nginx_up' | jq '.data.result'
```

7. Ejecutá algunas queries PromQL en la UI (**Graph**):

```promql
# Tasa de requests por segundo, agregada por pod, ventana de 5m
sum by (pod) (rate(nginx_http_requests_total[5m]))

# Conexiones activas promedio en el deployment
avg(nginx_connections_active)

# ¿Algún target caído?
nginx_up == 0
```

> **Preguntas — Bloque B**
> B1. Aplicaste el `ServiceMonitor` pero el target **no** apareció en Prometheus. Enumerá las tres causas más frecuentes y cómo verificar cada una.
> B2. ¿Por qué se usa `rate(nginx_http_requests_total[5m])` y no `nginx_http_requests_total` directamente? ¿Qué tipo de métrica es `_total` y qué garantiza el sufijo?
> B3. Un `ServiceMonitor` vive en el namespace `demo`, pero el Prometheus vive en `observability`. ¿Qué permite que Prometheus scrapee *cross-namespace* — es el `namespaceSelector` del ServiceMonitor, un `serviceMonitorNamespaceSelector` en el `Prometheus` CR, o ambos? Explicá la cadena de permisos.

---

## Ejercicio 3 — Alerting con PrometheusRule, routing e inhibición en Alertmanager

**Meta:** definir reglas de alerta declarativas, entender el ciclo `pending → firing`, y configurar routing, agrupación e inhibición en Alertmanager.

### Bloque A — Reglas de alerta

1. Creá una `PrometheusRule`. Definimos una alerta con `for: 2m` (histéresis) y una regla de *recording* para precalcular una tasa cara. Guardá como `rules.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: web-rules
  namespace: demo
  labels:
    release: kps           # requerido por el ruleSelector del stack
spec:
  groups:
    - name: web.recording
      interval: 30s
      rules:
        - record: job:nginx_http_requests:rate5m
          expr: sum by (job) (rate(nginx_http_requests_total[5m]))
    - name: web.alerts
      rules:
        - alert: WebTargetDown
          expr: nginx_up == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "El exporter de {{ $labels.pod }} está caído"
            description: "nginx_up == 0 durante más de 2 minutos en {{ $labels.pod }}."
        - alert: WebHighConnections
          expr: avg(nginx_connections_active) > 100
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Conexiones activas altas"
            description: "Promedio de conexiones activas por encima de 100 (valor actual {{ $value | printf \"%.0f\" }})."
```

2. Aplicá y verificá que la regla se cargó:

```bash
kubectl apply -f rules.yaml
# UI Prometheus → Alerts : deben aparecer WebTargetDown y WebHighConnections en estado "Inactive"
curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[].name'
```

3. Provocá la alerta `WebTargetDown` bajando la app y observá la transición de estado:

```bash
kubectl -n demo scale deployment/web --replicas=0
# UI → Alerts: WebTargetDown pasa a "Pending" (amarillo) y, tras 2m, a "Firing" (rojo)
```

> **Preguntas — Bloque A**
> A1. Entre el segundo 0 y el segundo 120 la alerta está en `Pending`, no `Firing`. ¿Qué problema operativo previene el campo `for:` y qué le pasaría a tu on-call sin él?
> A2. ¿Cuál es la diferencia entre una **recording rule** y una **alerting rule**? Dá un motivo concreto de performance para usar `job:nginx_http_requests:rate5m`.
> A3. Al escalar a 0 réplicas, `nginx_up == 0` se dispara. Pero hay una sutileza: cuando el Pod desaparece, su serie temporal deja de existir. ¿La alerta `nginx_up == 0` seguiría disparando si el target **desaparece por completo** del service discovery? ¿Qué alerta complementaria usarías para "no data" (pista: `absent()` / `up`)?

### Bloque B — Routing e inhibición en Alertmanager

4. Configurá Alertmanager para agrupar por `alertname` y namespace, y para que una `critical` **inhiba** las `warning` del mismo servicio. Con el Operator esto se hace por `AlertmanagerConfig` o vía el Helm values; acá usamos la config directa del stack. Guardá como `am-values.yaml`:

```yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: "default"
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        - matchers:
            - severity = "critical"
          receiver: "oncall"
          group_wait: 10s
    inhibit_rules:
      - source_matchers: ["severity = critical"]
        target_matchers: ["severity = warning"]
        equal: ["namespace", "alertname"]
    receivers:
      - name: "default"
      - name: "oncall"
        # En un lab real: webhook_configs / slack_configs / pagerduty_configs
        webhook_configs:
          - url: "http://webhook-logger.observability.svc:8080/"
```

5. Aplicá el cambio (upgrade de la release) y validá la config cargada:

```bash
helm upgrade kps prometheus-community/kube-prometheus-stack \
  --namespace observability --reuse-values -f am-values.yaml

kubectl -n observability port-forward svc/kps-kube-prometheus-stack-alertmanager 9093:9093 &
# UI: http://localhost:9093  → Status muestra la config activa
amtool --alertmanager.url=http://localhost:9093 config show   # si tenés amtool
```

6. Creá un **silence** temporal (por ejemplo durante un mantenimiento) desde la UI o CLI:

```bash
amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname="WebHighConnections" --duration=1h --comment="ventana de mantenimiento"
amtool --alertmanager.url=http://localhost:9093 silence query
```

> **Preguntas — Bloque B**
> B1. Explicá con tus palabras la diferencia entre `group_wait`, `group_interval` y `repeat_interval`. ¿Cuál controla cuánto esperás para agrupar alertas nuevas del mismo grupo antes del primer envío?
> B2. La `inhibit_rule` usa `equal: ["namespace", "alertname"]`. ¿Qué efecto tiene y por qué querés silenciar los `warning` cuando ya hay un `critical` del mismo servicio disparado?
> B3. ¿En qué se diferencia un **silence** de una **inhibition**? ¿Cuál es declarativo/permanente y cuál es una acción operativa puntual con expiración?
> B4. Prometheus evalúa las reglas y envía a Alertmanager, pero **Alertmanager** hace la deduplicación, agrupación y notificación. ¿Por qué separar estas dos responsabilidades en dos componentes distintos ayuda con la alta disponibilidad (varios Prometheus → un cluster de Alertmanager)?

---

## Ejercicio 4 — Logging agregado con Grafana Loki y LogQL

**Meta:** desplegar un backend de logs (Loki) con un agente de recolección, entender por qué Loki indexa *labels* y no el contenido del log, y consultar con LogQL correlacionando por labels con las métricas.

### Bloque A — Desplegar Loki + agente

1. Instalá Loki en modo *single binary* (para lab) y Promtail como DaemonSet:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki-stack \
  --namespace observability \
  --set loki.isDefault=false \
  --set promtail.enabled=true \
  --set grafana.enabled=false
```

2. Verificá que Promtail corre en cada nodo (DaemonSet) y que Loki está `Ready`:

```bash
kubectl -n observability get ds -l app.kubernetes.io/name=promtail
kubectl -n observability get pods -l app=loki
```

Salida esperada:

```
NAME             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
loki-promtail    1         1         1       1            1

NAME     READY   STATUS    RESTARTS   AGE
loki-0   1/1     Running   0          1m
```

> **Preguntas — Bloque A**
> A1. Promtail se despliega como `DaemonSet`. ¿Por qué esa es la topología correcta para un recolector de logs de nodo, frente a un `Deployment`?
> A2. Promtail lee los archivos de `/var/log/pods/...` montados desde el host. ¿Qué componente de Kubernetes escribe esos archivos y por qué Promtail necesita `hostPath` y permisos de lectura sobre ellos?
> A3. Nombrá un agente alternativo a Promtail dentro del ecosistema CNCF y una razón para elegirlo (pista: **Fluent Bit** / **Fluentd**, graduados CNCF).

### Bloque B — Consultar con LogQL

3. Conectá Loki como datasource en Grafana (el del Ej.1) o consultá vía API. Primero, generá algo de tráfico/logs escalando la app de vuelta:

```bash
kubectl -n demo scale deployment/web --replicas=2
kubectl -n demo run curl --image=curlimages/curl --restart=Never -- \
  sh -c 'for i in $(seq 1 20); do wget -qO- http://web.demo/ ; done'
```

4. En Grafana (`http://localhost:3000`, admin/admin), agregá el datasource Loki con URL `http://loki.observability.svc:3100`, y en **Explore** ejecutá LogQL:

```logql
# Todos los logs del namespace demo
{namespace="demo"}

# Solo el contenedor web, filtrando líneas que contengan "GET"
{namespace="demo", container="web"} |= "GET"

# Tasa de líneas de log por pod en 5m (metric query sobre logs)
sum by (pod) (rate({namespace="demo"}[5m]))

# Parsear logs con formato logfmt/JSON y filtrar por un campo
{namespace="demo"} | json | status_code >= 500
```

5. Comprobá desde la API cruda que la query funciona:

```bash
kubectl -n observability port-forward svc/loki 3100:3100 &
curl -sG 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={namespace="demo"}' \
  --data-urlencode 'limit=5' | jq '.data.result[0].stream'
```

> **Preguntas — Bloque B**
> B1. La consigna clave de Loki: **indexa labels, no el contenido**. ¿Qué implicancia de costo/almacenamiento tiene esto frente a Elasticsearch, y qué peligro operativo aparece si ponés un label de **alta cardinalidad** (p. ej. `request_id`) en un stream de Loki?
> B2. En LogQL, `{namespace="demo"} |= "GET"` tiene dos partes. ¿Cuál es el *stream selector* (usa el índice) y cuál es el *line filter* (se aplica en tiempo de query)? ¿Por qué el orden importa para la performance?
> B3. `sum by (pod) (rate({...}[5m]))` devuelve un número, no líneas de texto. ¿Qué son las *metric queries* de LogQL y por qué permiten graficar y **alertar** sobre logs sin exportarlos a Prometheus?

---

## Ejercicio 5 — Distributed tracing con OpenTelemetry Collector y Jaeger

**Meta:** desplegar el OpenTelemetry Collector como pipeline (receivers → processors → exporters), enviar traces desde una app instrumentada y visualizarlos en Jaeger, entendiendo *context propagation* y *sampling*.

### Bloque A — El Collector como pipeline

1. Desplegá Jaeger (all-in-one, para lab) como backend de traces:

```bash
kubectl -n observability apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/main/examples/all-in-one/all-in-one-example.yaml || \
kubectl -n observability create deployment jaeger --image=jaegertracing/all-in-one:1.62.0
kubectl -n observability expose deployment jaeger --port=16686 --name=jaeger-query
kubectl -n observability expose deployment jaeger --port=4317 --name=jaeger-otlp
```

2. Desplegá el **OpenTelemetry Collector** con un pipeline OTLP → batch → Jaeger. Guardá como `otel-collector.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: observability
data:
  collector.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        timeout: 5s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
    exporters:
      otlp/jaeger:
        endpoint: jaeger-otlp.observability.svc:4317
        tls:
          insecure: true
      debug:
        verbosity: basic
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/jaeger, debug]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
  labels:
    app: otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.115.1
          args: ["--config=/conf/collector.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
          volumeMounts:
            - name: conf
              mountPath: /conf
      volumes:
        - name: conf
          configMap:
            name: otel-collector-conf
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector:
    app: otel-collector
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: otlp-grpc }
    - { name: otlp-http, port: 4318, targetPort: otlp-http }
```

3. Aplicá y verificá el pipeline:

```bash
kubectl apply -f otel-collector.yaml
kubectl -n observability rollout status deployment/otel-collector
kubectl -n observability logs deploy/otel-collector | grep -i "Everything is ready"
```

> **Preguntas — Bloque A**
> A1. Un pipeline del Collector tiene tres etapas: **receivers**, **processors**, **exporters**. Asigná cada componente de arriba (`otlp`, `batch`, `memory_limiter`, `otlp/jaeger`, `debug`) a su etapa.
> A2. El `memory_limiter` está **antes** del `batch` en la lista de processors. ¿Por qué el orden de los processors importa y qué protege el `memory_limiter`?
> A3. ¿Qué ventaja de arquitectura da meter un Collector **entre** las apps y Jaeger, en vez de que cada app exporte directo al backend? (pistá: buffering, re-ruteo, sampling centralizado, cambio de backend sin tocar apps).

### Bloque B — Enviar traces y leerlos

4. Generá traces con una app de demo ya instrumentada con OTel. Usamos el `opentelemetry-demo` mínimo o un generador. Corré un generador de trazas apuntando al Collector:

```bash
kubectl -n observability run tracegen --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  -- traces --otlp-insecure \
  --otlp-endpoint otel-collector.observability.svc:4317 \
  --traces 50 --service demo-service
```

5. Confirmá en el Collector que recibió y exportó spans:

```bash
kubectl -n observability logs deploy/otel-collector | grep -i "TracesExporter\|spans"
```

6. Abrí Jaeger y buscá las trazas:

```bash
kubectl -n observability port-forward svc/jaeger-query 16686:16686 &
# Navegador: http://localhost:16686  → Service: demo-service → Find Traces
```

Deberías ver 50 traces, cada uno con un *root span* y spans hijos, con su *duration* en el diagrama de Gantt.

> **Preguntas — Bloque B**
> B1. Un trace se compone de **spans** unidos por `trace_id` y `parent_span_id`. Para que un request que atraviesa el *servicio A → servicio B* aparezca como **un solo trace**, ¿qué debe viajar en los headers HTTP entre A y B? (pista: W3C `traceparent`).
> B2. En producción no guardás el 100 % de los traces. Contrastá **head-based sampling** vs **tail-based sampling**: ¿cuál decide *antes* de ver el trace completo y cuál puede quedarse específicamente con los traces que tienen errores o latencia alta? ¿En qué componente configurarías tail sampling?
> B3. El exporter `debug` no manda datos a ningún lado. ¿Para qué sirve tenerlo en el pipeline durante el bring-up de la plataforma?

---

## Ejercicio 6 — Correlación de señales: de una alerta al trace culpable

**Meta:** integrar los tres pilares. Un platform engineer no entrega cuatro silos, entrega una experiencia donde desde una métrica anómala se salta al log y de ahí al trace. Practicamos la correlación por **labels compartidos** y **exemplars**.

### Bloque A — El modelo mental de correlación

1. Repasá qué label/campo une cada par de señales. Completá mentalmente esta tabla mientras respondés:

| Desde | Hacia | Clave de correlación |
|---|---|---|
| Métrica (Prometheus) | Log (Loki) | labels compartidos: `namespace`, `pod`, `container` |
| Métrica (Prometheus) | Trace (Jaeger/Tempo) | **exemplar** con `trace_id` embebido |
| Log (Loki) | Trace (Jaeger/Tempo) | `trace_id` extraído del cuerpo del log (`| json | trace_id=...`) |

2. En Grafana, con Loki y Prometheus ya como datasources, configurá una **derived field** en el datasource de Loki que detecte `trace_id=(\w+)` en los logs y lo enlace a Jaeger/Tempo. (Datasource Loki → *Derived fields* → regex `trace_id=(\w+)`, internal link → Jaeger).

> **Preguntas — Bloque A**
> A1. Un dashboard muestra `rate(http_requests_total{code="500"}[5m])` con un pico a las 14:32. Describí, señal por señal, el camino de diagnóstico: de la **métrica** al **log** al **trace**. ¿Qué label usás en cada salto?
> A2. ¿Qué es un **exemplar** en Prometheus y por qué es el puente natural de un histograma de latencia hacia un trace concreto? ¿Qué debe emitir la app para que el exemplar tenga un `trace_id` válido?
> A3. Los tres pilares comparten los labels `namespace/pod/container` porque provienen del mismo Pod. ¿Qué disciplina de plataforma (naming, resource attributes de OTel, relabeling) hay que imponer para que esos labels sean **idénticos** en las tres señales y la correlación no se rompa?

### Bloque B — Diseño de plataforma

3. Reflexioná sobre las decisiones de plataforma sin ejecutar comandos:

> **Preguntas — Bloque B**
> B1. **Cardinalidad** es el enemigo común de los tres pilares. Explicá cómo un label de alta cardinalidad (`user_id`, `request_id`) rompe: (a) la TSDB de Prometheus, (b) el índice de Loki. ¿Por qué en **traces** en cambio el `trace_id` de alta cardinalidad *sí* es correcto?
> B2. Un equipo pide "retención de 400 días de todas las métricas a 15 s de resolución". Como platform engineer, ¿qué le respondés y qué alternativa (downsampling / long-term storage tipo Thanos o Mimir, recording rules) proponés?
> B3. ¿Por qué la secuencia correcta de instrumentación es **metrics → logs → traces** en madurez, y no al revés? ¿Qué pilar te dice *que* algo está mal, cuál *qué* pasó y cuál *dónde exactamente* en la cadena de servicios?

---

## Fuentes oficiales

- **CNCF Curriculum (CNPE):** https://github.com/cncf/curriculum
- **Prometheus:** https://prometheus.io/docs/introduction/overview/ · **PromQL:** https://prometheus.io/docs/prometheus/latest/querying/basics/
- **Prometheus Operator / kube-prometheus-stack:** https://prometheus-operator.dev/docs/ · https://github.com/prometheus-operator/kube-prometheus
- **Alertmanager:** https://prometheus.io/docs/alerting/latest/alertmanager/ · **amtool:** https://github.com/prometheus/alertmanager#amtool
- **Grafana Loki / LogQL:** https://grafana.com/docs/loki/latest/ · https://grafana.com/docs/loki/latest/query/
- **Fluent Bit (CNCF):** https://docs.fluentbit.io/manual
- **OpenTelemetry (docs y Collector):** https://opentelemetry.io/docs/ · https://opentelemetry.io/docs/collector/configuration/
- **W3C Trace Context:** https://www.w3.org/TR/trace-context/
- **Jaeger:** https://www.jaegertracing.io/docs/latest/ · **Grafana Tempo:** https://grafana.com/docs/tempo/latest/
- **Exemplars en Prometheus:** https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage

---

## Respuestas

<details>
<summary><strong>Ejercicio 1 — soluciones</strong></summary>

**A1.** La TSDB de Prometheus es *stateful*: escribe bloques a un volumen persistente (WAL + bloques de 2 h). Un `StatefulSet` da identidad de red estable (`prometheus-...-0`), un `PersistentVolumeClaim` propio por réplica y orden de arranque/terminación determinístico. Un `Deployment` con réplicas compartiría/rotaría Pods sin identidad ni volumen dedicado, corrompiendo la TSDB. En HA se corren 2 réplicas, cada una con su propio PVC scrapeando lo mismo.

**A2.** El **operator** es un controlador que *observa* los CRDs (`Prometheus`, `ServiceMonitor`, `PrometheusRule`, `Alertmanager`) y genera la configuración (`prometheus.yaml.gz` en un Secret) + el StatefulSet. No hace scraping. El pod **`prometheus-...-0`** es el que efectivamente scrapea targets, evalúa reglas y almacena series. Separación control-plane / data-plane.

**A3.** `node-exporter` expone métricas del **host/kernel**: CPU, memoria, disco, red del nodo (`node_cpu_seconds_total`, `node_filesystem_avail_bytes`). `kube-state-metrics` expone el **estado de los objetos de la API de Kubernetes**: réplicas deseadas vs disponibles, estado de Pods, etc. (`kube_deployment_status_replicas`, `kube_pod_status_phase`). Uno mide máquinas; el otro, el estado declarativo del cluster.

**B1.** Porque la config puede contener credenciales de scraping (bearer tokens, TLS) → `Secret`. Y porque el Operator recarga Prometheus en caliente (`SIGHUP` / endpoint `/-/reload`) al cambiar el Secret, evitando reinicios y downtime. Editarla a mano rompería la reconciliación del operator (la sobrescribiría).

**B2.** Prometheus descubre y scrapea las **direcciones IP de los Pods** detrás del Service, no el `ClusterIP` (que balancearía y daría métricas de un pod al azar). El objeto que usa es el **`Endpoints`/`EndpointSlice`** que Kubernetes mantiene por cada Service: el `ServiceMonitor` selecciona el Service, y de sus EndpointSlices salen los targets individuales.

**B3.** Un `PodMonitor` selecciona **Pods directamente por labels**, sin necesidad de un `Service`. Se usa cuando los Pods no tienen (ni deben tener) Service — p. ej. Jobs, DaemonSets de infraestructura o cuando querés scrapear un puerto que no está expuesto por ningún Service.

</details>

<details>
<summary><strong>Ejercicio 2 — soluciones</strong></summary>

**A1.** Todos los contenedores de un Pod comparten el mismo *network namespace* (misma IP, mismo `localhost`). Por eso el sidecar `exporter` alcanza el nginx en `127.0.0.1:80`. Es el patrón *sidecar*: adjuntar capacidad (traducir `stub_status` a formato Prometheus) sin modificar la imagen principal.

**A2.** Separar el puerto de métricas del de tráfico permite: (1) aplicar NetworkPolicies distintas (solo Prometheus llega a `:9113`, no usuarios), (2) no exponer `/metrics` públicamente (fuga de información interna), (3) escalar/limitar cada plano por separado.

**B1.** Causas típicas de que un target no aparezca: (1) **falta el label** que el `serviceMonitorSelector` del `Prometheus` exige (acá `release: kps`) — verificar con `kubectl get prometheus -o yaml | grep -A5 serviceMonitorSelector`; (2) el **`port` del endpoint no coincide** con el *nombre* del puerto del Service (debe ser el nombre, no el número) — verificar el `Service`; (3) **selector de labels erróneo** (el `matchLabels` del SM no matchea el Service) o el `serviceMonitorNamespaceSelector` no incluye el namespace `demo`. Diagnóstico: UI Prometheus → *Status → Service Discovery* muestra por qué se descartó un target.

**B2.** `nginx_http_requests_total` es un **counter** (monótonamente creciente, se reinicia a 0 si el proceso reinicia). Su valor absoluto no dice nada útil; `rate(...[5m])` calcula la tasa de crecimiento por segundo y maneja los *resets* correctamente. El sufijo `_total` es la convención de nombres para counters.

**B3.** Requiere **ambos** niveles. En el `Prometheus` CR, `serviceMonitorNamespaceSelector` decide *de qué namespaces* se leen ServiceMonitors (por defecto en kube-prometheus-stack: todos o los que matcheen). Luego el `namespaceSelector` **dentro del ServiceMonitor** decide *de qué namespaces* se seleccionan los Services a scrapear. Además el ServiceAccount de Prometheus necesita RBAC (`get/list/watch` sobre endpoints/services/pods) — que el chart configura vía ClusterRole.

</details>

<details>
<summary><strong>Ejercicio 3 — soluciones</strong></summary>

**A1.** `for: 2m` exige que la condición se cumpla **de forma sostenida** 2 minutos antes de disparar. Previene *alert flapping* por picos transitorios (un scrape fallido, un GC pause). Sin `for:`, el on-call recibiría avisos por ruido momentáneo → fatiga de alertas y pérdida de confianza en el sistema.

**A2.** Una **recording rule** precalcula y **almacena** una expresión como nueva serie temporal a intervalos fijos; una **alerting rule** evalúa una condición y genera una alerta. `job:nginx_http_requests:rate5m` evita recalcular un `sum(rate(...))` costoso en cada dashboard/alerta: se computa una vez cada 30 s y las queries leen la serie ya agregada (más rápido y con carga predecible).

**A3.** Si el target **desaparece del service discovery** (Pod borrado), la serie `nginx_up` deja de existir y `nginx_up == 0` ya **no** matchea nada → la alerta se resuelve sola, ocultando el problema. Para "no data" se usa `absent(nginx_up{job="..."})` o se alerta sobre `up == 0` (la métrica sintética `up` que Prometheus genera por cada target scrapeado, incluso fallido) mientras el target siga en el SD; y para desaparición total, `absent()`.

**B1.** `group_wait`: cuánto espera Alertmanager tras la **primera** alerta de un grupo nuevo antes de notificar (para juntar alertas que llegan casi simultáneas). `group_interval`: cuánto espera antes de enviar una notificación **actualizada** de un grupo que ya notificó (nuevas alertas al mismo grupo). `repeat_interval`: cada cuánto **re-notifica** una alerta que sigue firing sin cambios. El que junta alertas nuevas antes del primer envío es `group_wait`.

**B2.** La `inhibit_rule` suprime las notificaciones de las alertas `warning` cuando hay una `critical` con el mismo `namespace` y `alertname` disparada. Evita spam: si el servicio está *caído* (critical), no querés además avisos de "conexiones altas" (warning) del mismo servicio — ya sabés que está mal, la warning es ruido derivado.

**B3.** Un **silence** es una acción **operativa puntual** con `matchers` y **expiración** (ej. ventana de mantenimiento de 1 h): lo crea un humano y caduca. Una **inhibition** es una **regla declarativa permanente** en la config: una alerta suprime automáticamente a otras según relación causal. Silence = manual/temporal; inhibition = automática/estructural.

**B4.** Prometheus (evaluación) es *stateful* y puede correr en varias réplicas idénticas que envían las **mismas** alertas a un **cluster** de Alertmanager. Alertmanager **deduplica** esas alertas repetidas (gossip entre instancias) y notifica **una** sola vez. Separar evaluación de notificación permite HA de ambos planos sin duplicar páginas al on-call.

</details>

<details>
<summary><strong>Ejercicio 4 — soluciones</strong></summary>

**A1.** Un `DaemonSet` garantiza **una** instancia de Promtail **por nodo**, con acceso a los logs locales de *todos* los Pods de ese nodo vía `hostPath`. Un `Deployment` no garantiza cobertura por nodo (podrían quedar nodos sin agente) — topología incorrecta para recolección local.

**A2.** El **kubelet** (a través del *container runtime* / CRI) escribe los logs de stdout/stderr de cada contenedor en `/var/log/pods/...` y `/var/log/containers/...` del nodo. Promtail monta esos paths por `hostPath` en modo lectura y necesita permisos para leerlos; también usa la API de Kubernetes para enriquecer cada línea con labels (`namespace`, `pod`, `container`) vía service discovery.

**A3.** **Fluent Bit** (o **Fluentd**), ambos proyectos CNCF graduados. Fluent Bit es liviano (C, bajo footprint de memoria), ideal como agente de nodo con muchos parsers y outputs; se elige por eficiencia, ecosistema de plugins y por no atar la plataforma a Loki (puede rutear a Elasticsearch, S3, Kafka, etc.).

**B1.** Loki indexa solo un conjunto pequeño de **labels** y guarda los *chunks* de log comprimidos en object storage → índice chiquito y almacenamiento barato, frente a Elasticsearch que indexa (invierte) todo el texto → mucho más caro en cómputo/almacenamiento. El peligro: un label de **alta cardinalidad** (`request_id`) crea un **stream distinto por valor** → explosión de streams, degradación de escritura y consulta ("cardinality explosion"). Los datos de alta cardinalidad van en el **cuerpo** del log (filtrable con line filters/parsers), nunca como label.

**B2.** `{namespace="demo"}` es el **stream selector**: usa el índice para elegir qué streams leer (rápido, obligatorio). `|= "GET"` es el **line filter**: se aplica *después*, escaneando el contenido de esos streams en tiempo de query. El orden importa porque cuanto más restrictivo sea el selector de labels, menos datos hay que escanear con el filtro de línea → consultas mucho más baratas.

**B3.** Las **metric queries** de LogQL convierten logs en series temporales numéricas (`rate`, `count_over_time`, `sum by`). Permiten graficar tendencias y **crear reglas de alerta** (via Loki ruler) directamente sobre volumen/patrones de logs, sin necesidad de exportar contadores a Prometheus — útil cuando la señal solo existe en el texto del log.

</details>

<details>
<summary><strong>Ejercicio 5 — soluciones</strong></summary>

**A1.** Receivers: `otlp` (recibe spans por gRPC/HTTP). Processors: `memory_limiter` y `batch`. Exporters: `otlp/jaeger` (manda a Jaeger) y `debug` (imprime a stdout).

**A2.** Los processors se ejecutan **en orden**. El `memory_limiter` va primero para poder **rechazar/aplicar backpressure** a los datos entrantes *antes* de que se acumulen en el `batch` y demás processors, protegiendo al Collector de un OOM cuando el volumen de spans supera la capacidad. Si estuviera al final, la memoria ya se habría consumido.

**A3.** Un Collector intermedio ofrece: **buffering/retry** ante caídas del backend; **sampling y procesamiento centralizado** (tail sampling, redacción de PII, agregación) sin tocar las apps; **desacople del backend** (cambiar Jaeger→Tempo editando un exporter, no N aplicaciones); y un único punto de configuración de telemetría (traces, metrics, logs). Es el patrón *gateway/agent* de OTel.

**B1.** Debe viajar el **contexto de traza** en los headers HTTP, estándar **W3C Trace Context**: el header `traceparent` (contiene `trace_id`, `parent_id`, flags) y opcionalmente `tracestate`. Así el servicio B crea sus spans como hijos del `trace_id` de A → un único trace distribuido.

**B2.** **Head-based sampling** decide *al inicio* del trace (en la primera app), antes de conocer su resultado — simple pero puede descartar justo los traces con errores. **Tail-based sampling** decide *después* de haber recibido el trace completo, pudiendo quedarse específicamente con los que tienen `error=true` o latencia alta. Se configura en el **OpenTelemetry Collector** con el `tail_sampling` processor (requiere que todos los spans de un trace lleguen al mismo Collector).

**B3.** El exporter `debug` (antes `logging`) escribe resúmenes de la telemetría a stdout del Collector. En el bring-up sirve para **confirmar que el pipeline recibe y procesa spans** sin depender de que el backend esté sano — se lee con `kubectl logs`.

</details>

<details>
<summary><strong>Ejercicio 6 — soluciones</strong></summary>

**A1.** (1) **Métrica**: el pico de `http_requests_total{code="500"}` te dice *que* hay errores y en qué `namespace/pod`. (2) **Log**: saltás a Loki con `{namespace="X", pod="Y"} |= "error"` filtrando por la ventana temporal — usás los labels compartidos `namespace/pod` para acotar. (3) **Trace**: del log extraés el `trace_id` (`| json | trace_id != ""`) y abrís ese trace en Jaeger/Tempo para ver *dónde exactamente* en la cadena de servicios se produjo la latencia/el error.

**A2.** Un **exemplar** es una referencia adjunta a una muestra de métrica (típicamente a un bucket de histograma) que apunta a una traza concreta (`trace_id`) que produjo *ese* valor. Es el puente de "el p99 de latencia subió" a "acá está un request de ejemplo que fue lento". La app debe emitir el histograma con exemplars (client library de OTel/Prometheus con exemplars habilitados) incluyendo el `trace_id` del span activo.

**A3.** Hay que estandarizar los **resource attributes** de OTel (`service.name`, `k8s.namespace.name`, `k8s.pod.name`) y el **relabeling** de Prometheus/Promtail para que produzcan *exactamente* los mismos nombres de label (`namespace`, `pod`, `container`) en las tres señales. Sin esa disciplina de naming/atributos, `pod` en métricas no matchea `pod` en logs y la correlación por labels se rompe. Es trabajo de plataforma: convenciones + relabel configs + OTel Resource semantic conventions.

**B1.** (a) En **Prometheus**, cada combinación única de labels es una serie temporal en memoria/TSDB; `user_id` → millones de series → explosión de memoria y OOM. (b) En **Loki**, cada valor de label es un *stream* con su índice y chunks; `request_id` → millones de streams → índice inmanejable. En **traces**, en cambio, el `trace_id` NO es un label indexado que multiplica series: es el identificador natural de cada traza, almacenado en un backend diseñado para búsqueda por ID/atributos (Tempo/Jaeger). Alta cardinalidad es la *naturaleza* de los traces, no un antipatrón.

**B2.** Le explicás que 400 días × 15 s de resolución de *todas* las series es inviable en la TSDB local de Prometheus (retención y costo). Propuesta: retención corta local (días) + **long-term storage** con **Thanos** o **Grafana Mimir** (bloques a object storage, consulta global) y **downsampling** (resoluciones de 5 m/1 h para históricos largos); precalcular con **recording rules** las agregaciones que realmente se consultan a largo plazo, en vez de guardar todo a 15 s.

**B3.** **Metrics** son baratas y continuas: te dicen *que* algo está mal y disparan la alerta (síntoma, SLO). **Logs** te dan el *qué* pasó (el mensaje de error, el stack). **Traces** te dan el *dónde* exactamente en la cadena de servicios y con qué latencia por span. Se instrumenta en ese orden de madurez porque metrics dan cobertura barata primero; logs y traces son más caros/voluminosos y se agregan para profundizar el diagnóstico. Invertir el orden gastaría el presupuesto de observabilidad antes de tener la señal de alerta básica.

</details>