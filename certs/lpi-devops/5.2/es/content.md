# LPI DevOps Tools Engineer (Examen 701-100) — Tema 5.2: Gestión y Análisis de Logs

**Peso del examen:** 6.66 (Peso del tema: 4 / 60)  
**Audiencia objetivo:** Principal Platform Engineers, SREs y DevOps Architects  
**Prerrequisitos:** Comprensión profunda de streams POSIX, administración de sistemas Linux (`systemd`), redes y arquitecturas de runtime de contenedores.

---

## 1. Motivación Arquitectónica de Producción y Definición del Problema

En arquitecturas monolíticas, la gestión de logs dependía de daemons locales `syslogd` o `rsyslog` que escribían directamente en el almacenamiento en bloque persistente local (`/var/log`). La inspección se realizaba de forma interactiva utilizando herramientas como `tail`, `grep` y `less`. 

En entornos de microservicios y Kubernetes contenedorizados, este paradigma heredado se rompe debido a restricciones clave de producción:

1. **Ciclo de Vida de Cómputo Efímero**: Los contenedores son efímeros. Cuando un contenedor colapsa, es expulsado (evicted) por el kubelet, o se termina durante eventos de escalado, cualquier stream stdout/stderr no rastreado que resida en la capa volátil de escritura del contenedor se pierde permanentemente.
2. **Alta Cardinalidad y Volumen**: Un cluster que ejecuta miles de microservicios a través de cientos de nodos produce millones de líneas de log por segundo. Los colectores centralizados enfrentan backpressure, saturación de red, eliminaciones por falta de memoria (OOM kills) y cuellos de botella en la escritura de almacenamiento.
3. **Heterogeneidad de Streams No Estructurados**: Las aplicaciones heredadas emiten cadenas de texto multilínea no estructuradas (por ejemplo, stack traces de Java), mientras que los servicios modernos emiten streams estructurados en JSON o Logfmt. Los logs no estructurados impiden la extracción automatizada de métricas, el indexado de búsqueda y las alertas en tiempo real.
4. **Correlación de Logs**: La resolución de problemas de fallas de solicitudes transversales a través de mallas de servicios (service meshes) distribuidas requiere inyectar, preservar y consultar tokens de correlación únicos (por ejemplo, `trace_id`, `span_id`, `request_id`) a través de streams de logs dispares.

```
+-----------------------------------------------------------------------------------+
|                                 LOGGING PIPELINE MECHANICS                        |
+-----------------------------------------------------------------------------------+
|  [ App Container ] -> (stdout/stderr) -> [ Container Engine Log Pipe ]            |
|                                                     |                             |
|                                                     v                             |
|  [ Node Disk Storage ] <------------------ (/var/log/containers/*)                |
|           |                                                                       |
|           v                                                                       |
|  [ Log Collector / Agent ] (DaemonSet: Vector / Fluent Bit)                       |
|           |                                                                       |
|           +---> [ Parsing & Structuring ] (JSON, Regex, Grok, VRL)                |
|           +---> [ Enrichment ] (Node IP, Pod Name, Namespace, K8s Labels)         |
|           +---> [ Local Disk Buffering ] (WAL - Write-Ahead Logging for safety)   |
|           |                                                                       |
|           v                                                                       |
|  [ Central Aggregator / Ingestion Highway ] (Vector Aggregator / Logstash)        |
|           |                                                                       |
|           +---> Hot Path  ---> [ Search Storage Engine ] (Elasticsearch/OpenSearch)|
|           +---> Fast Path ---> [ Label Index Engine ]    (Grafana Loki)           |
|           +---> Cold Path ---> [ Object Storage ]        (AWS S3 / GCS / MinIO)   |
+-----------------------------------------------------------------------------------+
```

---

## 2. Comparativas Arquitectónicas Técnicas y Trade-Offs

### 2.1 Log Collectors y Forwarders

| Métrica / Dimensión | Fluent Bit | Vector | Logstash | Fluentd |
| :--- | :--- | :--- | :--- | :--- |
| **Lenguaje / Runtime** | C | Rust | Java / JRuby | Ruby (extensiones en C) |
| **Huella de Memoria (Memory Footprint)** | ~5 MB - 15 MB | ~15 MB - 50 MB | ~500 MB - 2 GB | ~50 MB - 200 MB |
| **Throughput y Velocidad** | Extremadamente Alto | Ultra Alto (Tokio asíncrono) | Moderado | Moderado |
| **Seguridad de Memoria (Memory Safety)** | Manual (Punteros C) | Garantizado (Compilador Rust) | Gestionado por JVM | Gestionado por Ruby VM |
| **Motor de Transformación** | Plugins de C / Lua | Vector Remap Language (VRL) | Logstash Filter Plugins | Plugins de Ruby |
| **Buffering en Disco (WAL)** | Soportado | Soportado (WAL Nativo) | Soportado (Colas Persistentes) | Soportado |
| **Caso de Uso Principal** | Colector a nivel de nodo (Node-level Collector) | Colector/Agregador Universal | Procesamiento Empresarial Pesado | Agente de Kubernetes Heredado |

### 2.2 Arquitecturas de Motores de Almacenamiento

| Métrica de Arquitectura | Índice Invertido (Elasticsearch / OpenSearch) | Indexación Basada en Etiquetas (Grafana Loki) | Archivo en Almacenamiento de Objetos (AWS S3 / MinIO) |
| :--- | :--- | :--- | :--- |
| **Estrategia de Indexación** | Indexa texto completo / todos los campos por defecto | Indexa solo etiquetas de metadatos; el texto del log no se indexa | Sin índice de búsqueda (chunks comprimidos sin procesar) |
| **Velocidad de Consulta** | Sub-segundo para búsquedas de texto completo complejas | Rápida para consultas delimitadas por etiquetas; escanea logs sin procesar para texto | Lenta (requiere motores de escaneo por lotes como Athena/Trino) |
| **Costo de Almacenamiento** | Alto (El tamaño del índice a menudo es del 100%–150% del tamaño de los datos sin procesar) | Bajo (Tamaño del índice ~1%–5% del volumen de logs) | Extremadamente Bajo |
| **Uso de CPU / RAM** | Alto (Gestión del JVM Heap, pausas de GC) | Bajo a Moderado | Mínimo |
| **Mejor Encaje (Best Fit)** | Auditoría de Seguridad, SIEM, Búsqueda de Cadenas Arbitrarias | Observabilidad y Métricas de Kubernetes Cloud-Native | Archivo de Cumplimiento a Largo Plazo |

---

## 3. Infraestructura de Producción y Manifestos de Configuración Completos

### 3.1 Configuración de `logrotate` de Producción (`/etc/logrotate.d/app-services`)

Esta configuración garantiza que los logs de daemons Linux heredados no contenedorizados se roten atómicamente sin descartar descriptores de archivos.

```etc
/var/log/app-services/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    dateext
    dateformat -%Y%m%m-%s
    sharedscripts
    maxsize 500M
    create 0640 www-data adm
    postrotate
        /usr/bin/systemctl reload app-service.service > /dev/null 2>&1 || true
    endscript
}
```

---

### 3.2 Configuración del Pipeline de Vector de Producción (`vector.yaml`)

Un pipeline de Vector completo de producción que ingiere logs de nodos de Kubernetes, parsea líneas de logs JSON/no estructurados con Vector Remap Language (VRL), aplica buffering write-ahead en disco local (WAL) y enruta a dual sinks (Elasticsearch y Grafana Loki).

```yaml
data_dir: /var/lib/vector

sources:
  kubernetes_logs:
    type: kubernetes_logs
    auto_discover: true
    exclude_paths:
      - "/var/log/pods/kube-system_**"

transforms:
  parse_and_enrich:
    type: remap
    inputs:
      - kubernetes_logs
    source: |
      # Parse JSON log payload if valid, else structure raw message
      if is_json(.message) {
        parsed, err = parse_json(.message)
        if err == null {
          .payload = parsed
          del(.message)
        }
      } else {
        .payload.raw_message = .message
        del(.message)
      }

      # Standardize metadata schema
      .environment = "production"
      .service = .kubernetes.pod_labels.app || .kubernetes.container_name || "unknown"
      .node_name = .kubernetes.pod_node_name
      .timestamp = parse_timestamp(.timestamp, "%Y-%m-%dT%H:%M:%S%.fZ") ?? now()

      # Remove verbose Kubernetes metadata to conserve index storage
      del(.kubernetes.pod_labels)
      del(.kubernetes.pod_annotations)

sinks:
  elasticsearch_hot:
    type: elasticsearch
    inputs:
      - parse_and_enrich
    endpoints:
      - "https://elasticsearch-cluster.internal:9200"
    mode: bulk
    bulk:
      index: "logs-production-%Y.%m.%d"
      action: "index"
    auth:
      strategy: basic
      user: "vector_ingest"
      password: "SuperSecretProductionPassword123!"
    tls:
      ca_file: "/etc/vector/certs/ca.crt"
      verify_certificate: true
    buffer:
      type: disk
      max_bytes: 10737418240 # 10 GB Local Disk Buffer
      when_full: block

  loki_secondary:
    type: loki
    inputs:
      - parse_and_enrich
    endpoint: "http://loki-gateway.internal:3100"
    encoding:
      codec: json
    labels:
      environment: "{{ environment }}"
      service: "{{ service }}"
      node: "{{ node_name }}"
    buffer:
      type: memory
      max_events: 10000
      when_full: drop_newest
```

---

### 3.3 Manifesto Completo de `DaemonSet` de Kubernetes para Fluent Bit (`fluent-bit.yaml`)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: logging
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
  labels:
    k8s-app: fluent-bit
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         1
        Log_Level     info
        Daemon        off
        Parsers_File  parsers.conf
        HTTP_Server   On
        HTTP_Listen   0.0.0.0
        HTTP_Port     2020

    [INPUT]
        Name              tail
        Tag               kube.*
        Path              /var/log/containers/*.log
        Parser            docker
        DB                /var/log/flb_kube.db
        Mem_Buf_Limit     50MB
        Skip_Long_Lines   On
        Refresh_Interval  10

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        Merge_Log_Key       log_processed
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [OUTPUT]
        Name            es
        Match           *
        Host            opensearch-cluster.internal
        Port            9200
        HTTP_User       admin
        HTTP_Passwd     admin
        Index           k8s-logs
        Type            _doc
        Logstash_Format On
        Logstash_Prefix logstash-k8s
        Time_Key        @timestamp
        Retry_Limit     5
        tls             On
        tls.verify      On

  parsers.conf: |
    [PARSER]
        Name        docker
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
        Time_Keep   On
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
  labels:
    k8s-app: fluent-bit
spec:
  selector:
    matchLabels:
      k8s-app: fluent-bit
  template:
    metadata:
      labels:
        k8s-app: fluent-bit
    spec:
      serviceAccountName: fluent-bit-sa
      containers:
      - name: fluent-bit
        image: fluent/fluent-bit:2.2.2
        imagePullPolicy: IfNotPresent
        ports:
          - containerPort: 2020
        resources:
          limits:
            cpu: 500m
            memory: 256Mi
          requests:
            cpu: 100m
            memory: 64Mi
        volumeMounts:
        - name: varlog
          mountPath: /var/log
        - name: varlibdockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
        - name: config
          mountPath: /fluent-bit/etc/fluent-bit.conf
          subPath: fluent-bit.conf
        - name: config
          mountPath: /fluent-bit/etc/parsers.conf
          subPath: parsers.conf
      terminationGracePeriodSeconds: 30
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
      - name: varlibdockercontainers
        hostPath:
          path: /var/lib/docker/containers
      - name: config
        configMap:
          name: fluent-bit-config
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit-sa
  namespace: logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit-read
rules:
- apiGroups: [""]
  resources:
  - namespaces
  - pods
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluent-bit-read-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit-read
subjects:
- kind: ServiceAccount
  name: fluent-bit-sa
  namespace: logging
```

---

### 3.4 Política de Index Lifecycle Management (ILM) de Elasticsearch (`ilm-policy.json`)

Para evitar el agotamiento del almacenamiento, los índices deben transicionar a través de las fases Hot, Warm, Cold y Delete de forma automática.

```json
{
  "policy": {
    "description": "Production log rollover and retention policy",
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_primary_shard_size": "50gb",
            "max_age": "1d",
            "max_docs": 100000000
          },
          "set_priority": {
            "priority": 100
          }
        }
      },
      "warm": {
        "min_age": "7d",
        "actions": {
          "forcemerge": {
            "max_num_segments": 1
          },
          "shrink": {
            "number_of_shards": 1
          },
          "set_priority": {
            "priority": 50
          }
        }
      },
      "delete": {
        "min_age": "30d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal Esperadas

### 4.1 Diagnósticos Avanzados de `journalctl` en Systemd

#### Comando: Inspeccionar logs de unidad desde un momento específico, en formato JSON, filtrados por prioridad

```bash
$ journalctl -u nginx.service --since "2026-08-07 00:00:00" -p err..emerg -o json-pretty -n 1
```

#### Output:
```json
{
	"_SYSTEMD_UNIT" : "nginx.service",
	"PRIORITY" : "3",
	"_PID" : "14821",
	"_COMM" : "nginx",
	"_HOSTNAME" : "lb-node-01.internal",
	"MESSAGE" : "2026/08/07 08:12:44 [error] 14821#14821: *40921 connect() failed (111: Connection refused) while connecting to upstream, client: 192.168.10.45, server: api.internal, request: \"GET /v1/checkout HTTP/1.1\", upstream: \"http://10.244.2.14:8080/v1/checkout\", host: \"api.internal\"",
	"_SOURCE_REALTIME_TIMESTAMP" : "1786090364000000",
	"__BOOT_ID" : "a1b2c3d4e5f64789890abcdef1234567"
}
```

#### Comando: Verificar la huella en disco de los logs de systemd y activar la limpieza por vacuum

```bash
$ journalctl --disk-usage
```

#### Output:
```text
Archived and active journals take up 3.8G in the file system.
```

```bash
$ sudo journalctl --vacuum-size=1G
```

#### Output:
```text
Vacuuming done, freed 2.8G of archived journals from /var/log/journal/a1b2c3d4e5f64789890abcdef1234567.
```

---

### 4.2 Análisis de Streams mediante POSIX y CLI Moderna (`jq`, `awk`, `ripgrep`)

#### Comando: Extraer códigos de estado HTTP, contar ocurrencias y calcular el porcentaje de errores desde streams JSON sin procesar

```bash
$ cat /var/log/vector/access.json | jq -r '.payload.status' | sort | uniq -c | sort -nr
```

#### Output:
```text
 849200 200
  12400 304
   3100 404
    850 500
    120 503
```

#### Comando: Monitoreo de errores en tiempo real y alto throughput con `ripgrep` filtrando los healthchecks

```bash
$ rg --line-buffered -i "error|exception|critical" /var/log/containers/*.log | rg -v "healthcheck" | head -n 3
```

#### Output:
```text
/var/log/containers/auth-service-7d9b-x82z_default_auth-a8b.log:{"time":"2026-08-07T08:15:01.12Z","stream":"stderr","log":"[ERROR] Database connection pool exhausted: timeout after 5000ms"}
/var/log/containers/payment-v2-54f6-99pl_default_pay-11c.log:{"time":"2026-08-07T08:15:02.44Z","stream":"stderr","log":"[CRITICAL] Stripe Gateway returned HTTP 502 Bad Gateway"}
/var/log/containers/order-proc-6c77-z44q_default_ord-99a.log:{"time":"2026-08-07T08:15:03.01Z","stream":"stderr","log":"[EXCEPTION] java.lang.NullPointerException at com.app.orders.Process.execute(OrderProcessor.java:142)"}
```

---

### 4.3 Operaciones de REST API de Elasticsearch vía `curl`

#### Comando: Verificar el estado de salud del cluster y el estado de asignación de shards

```bash
$ curl -s -k -u "admin:SuperSecretProductionPassword123!" https://elasticsearch-cluster.internal:9200/_cluster/health?pretty
```

#### Output:
```json
{
  "cluster_name" : "production-logging",
  "status" : "green",
  "timed_out" : false,
  "number_of_nodes" : 5,
  "number_of_data_nodes" : 3,
  "active_primary_shards" : 142,
  "active_shards" : 284,
  "relocating_shards" : 0,
  "initializing_shards" : 0,
  "unassigned_shards" : 0,
  "delayed_unassigned_shards" : 0,
  "number_of_pending_tasks" : 0,
  "number_of_in_flight_fetch" : 0,
  "task_max_waiting_in_queue_millis" : 0,
  "active_shards_percent_as_number" : 100.0
}
```

#### Comando: Consultar la asignación de índices y los tamaños de almacenamiento

```bash
$ curl -s -k -u "admin:SuperSecretProductionPassword123!" "https://elasticsearch-cluster.internal:9200/_cat/indices/logs-production-*?v&s=index:desc" | head -n 5
```

#### Output:
```text
health status index                       uuid                   pri rep docs.count docs.deleted store.size pri.store.size
green  open   logs-production-2026.08.07  xY9z0A1bB2c3D4e5F6g7H8   3   1   45120499            0     28.4gb         14.2gb
green  open   logs-production-2026.08.06  a1B2c3D4e5F6g7H8i9J0k1   3   1  120894102            0     74.8gb         37.4gb
green  open   logs-production-2026.08.05  k1J0i9H8g7F6e5D4c3B2a1   3   1  118492011            0     72.1gb         36.0gb
green  open   logs-production-2026.08.04  m2N3o4P5q6R7s8T9u0V1w2   3   1  115002944            0     70.5gb         35.2gb
```

---

### 4.4 Ingestión y Consultas con la CLI de Grafana Loki (`logcli`)

#### Comando: Ejecutar una consulta LogQL contra una instancia de Loki para obtener logs de error de `auth-service`

```bash
$ logcli --addr="http://loki-gateway.internal:3100" query '{environment="production", service="auth-service"} |= "ERROR"' --limit=2 --output=raw
```

#### Output:
```text
2026-08-07T08:20:11.492Z [ERROR] Authentication failure for user_id=8923: Invalid JWT signature
2026-08-07T08:20:14.102Z [ERROR] Redis cache connection timeout host=redis-cluster-01.internal:6379
```

---

## 5. Modos de Falla, Verificación y Guía de Troubleshooting

```
+-----------------------------------------------------------------------------------+
|                        PRODUCTION TROUBLESHOOTING FLOWCHART                       |
+-----------------------------------------------------------------------------------+
|  [ Incident Detected: Missing Logs / High Memory / Dropped Traces ]              |
|                                         |                                         |
|                                         v                                         |
|                 [ Step 1: Check Node File Descriptors & Memory ]                  |
|                 $ lsof -p <collector_pid> | wc -l                                 |
|                 $ free -h && dmesg | grep -i oom                                  |
|                                         |                                         |
|                    +--------------------+--------------------+                    |
|                    |                                         |                    |
|             (Resource Exhausted)                     (Resources OK)               |
|                    |                                         |                    |
|                    v                                         v                    |
|         [ Increase Limits / Fix Memory ]     [ Step 2: Inspect Local Buffer Status]|
|         (K8s Limits / WAL Disk Space)        $ ls -lh /var/lib/vector/buffer/     |
|                                                              |                    |
|                                              +---------------+---------------+    |
|                                              |                               |    |
|                                      (Buffer Full)                   (Buffer Low) |
|                                              |                               |    |
|                                              v                               v    |
|                                [ Downstream Blocking ]       [ Step 3: Validate API ]
|                                (Check ES/Loki Ingestion)     (Elasticsearch / Loki)
+-----------------------------------------------------------------------------------+
```

### 5.1 Eliminaciones por Falta de Memoria (OOM Kills) de Log Collectors

* **Causa Raíz**: El log forwarder (por ejemplo, Fluent Bit o Vector) lee logs del disco más rápido de lo que el backend puede aceptarlos, y el buffering basado en memoria se llena durante picos altos de ingestión.
* **Síntoma**: `dmesg -T` emite `Out of memory: Kill process <pid> (fluent-bit)`. El estado del Pod muestra `OOMKilled` con el código de salida `137`.
* **Remediación**:
  1. Cambiar los tipos de buffer de `memory` a WAL de `disk` (Write-Ahead Logging).
  2. En Fluent Bit, configurar un `Mem_Buf_Limit 50MB` explícito por bloque de entrada tail para forzar pausas en la lectura de logs cuando se superen los umbrales de uso de memoria.
  3. Incrementar la especificación de límites de Kubernetes del contenedor (`resources.limits.memory`).

---

### 5.2 Backpressure Aguas Abajo (Downstream) y Pérdida de Logs

* **Causa Raíz**: Elasticsearch ingresa en HTTP 429 (`TOO_MANY_REQUESTS`) debido al agotamiento de los tamaños de las colas bulk, o Loki devuelve 429 `entry for stream is too far behind`.
* **Síntoma**: Los logs del log collector muestran fallas de reintento, las particiones de buffer en disco se llenan al 100% de su capacidad y los logs en tiempo real se retrasan respecto al tiempo de reloj real en minutos u horas.
* **Procedimiento de Diagnóstico**:
  1. Inspeccionar la profundidad de la cola bulk de Elasticsearch:
     ```bash
     $ curl -s -k -u "admin:Pass" "https://elasticsearch-cluster.internal:9200/_cat/thread_pool/write?v&h=host,name,active,queue,rejected"
     ```
  2. Si el conteo de `rejected` está incrementando, escalar los shards primarios de Elasticsearch a través de más nodos o incrementar los tamaños de la cola de escritura del pool de hilos (thread pool).
  3. Validar los endpoints de salud del colector (por ejemplo, las métricas de Prometheus en Fluent Bit en el puerto `2020`):
     ```bash
     $ curl -s http://localhost:2020/api/v1/metrics | grep -i "output_dropped_records"
     ```

---

### 5.3 Truncamiento del Parser Multilínea (Stack Traces de Java / Python)

* **Causa Raíz**: Los parsers de logs predeterminados por regex/JSON dividen los stack traces multilínea en los límites de salto de línea (`\n`), tratando una sola cadena de excepción de Java como 50+ documentos de log separados en Elasticsearch.
* **Síntoma**: Entradas de logs incompletas en Kibana/Grafana con contexto roto (por ejemplo, líneas que comienzan con `at com.service.util...` indexadas como logs aislados sin la cadena de error de la causa raíz).
* **Remediación**: Usar reglas de parseo multilínea en la configuración del daemon colector.
  * **Ejemplo de Configuración Multilínea de Fluent Bit**:
    ```ini
    [FILTER]
        Name                  multiline
        Match                 kube.*
        multiline.key_content log
        multiline.parser      java, python
    ```

---

## 6. Referencias

* **Generalidades de Linux Professional Institute (LPI) DevOps Tools Engineer**:  
  https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
* **Objetivos Detallados de LPI 701-100**:  
  https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0
* **Documentación de la Arquitectura de Vector y Vector Remap Language (VRL)**:  
  https://vector.dev/docs/
* **Documentación de Fluent Bit y Patrones de Despliegue en Kubernetes**:  
  https://docs.fluentbit.io/manual/
* **Guías de Index Lifecycle Management (ILM) de Elasticsearch**:  
  https://www.elastic.co/guide/en/elasticsearch/reference/current/index-lifecycle-management.html
* **LogQL y Arquitectura de Ingestión de Grafana Loki**:  
  https://grafana.com/docs/loki/latest/
* **Páginas de Manual de Systemd Journalctl**:  
  https://www.freedesktop.org/software/systemd/man/journalctl.html