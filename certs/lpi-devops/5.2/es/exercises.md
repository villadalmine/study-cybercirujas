# LPI DevOps Tools Engineer (701-100, v1.0) - Topic 5.2: Log Management and Analysis

**Exam Weight:** 6.66  
**Target Audience:** SREs, Platform Engineers, Systems Engineers preparándose para la LPI DevOps Certification.  
**Official Reference:** [LPI DevOps Tools Engineer Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)

---

## Technical Overview & Architectural Foundations

En sistemas de producción de alta concurrencia, el log management abarca cinco etapas críticas del ciclo de vida: **Generation**, **Local Collection & Rate-Limiting**, **Transport & Buffering**, **Processing & Normalization**, e **Indexing & Storage**.

```
[ Application / OS ] 
       │ (stdout/stderr / syslog / journald socket)
       ▼
[ Local Collector ] ──(Rate-limiting / Disk Buffer)──► [ Distributed Message Queue ]
 (Filebeat / Vector)                                       (Apache Kafka / Redis)
                                                                     │
                                                                     ▼
[ Storage & Indexing Engine ] ◄──(Parsed JSON / Mutation)── [ Log Processor ]
(Elasticsearch / OpenSearch / Loki)                             (Logstash)
```

1. **Local System Logging Mechanics (`systemd-journald`, `rsyslog`):** Los kernels de Linux y demonios del sistema escriben entradas estructuradas en socket buffers (ej., `/dev/log`, `/run/systemd/journal/socket`). `systemd-journald` captura metadatos de log binarios e indexados (pID, UID, cgroups, systemd unit), mientras que `rsyslog` procesa protocolos syslog basados en texto (RFC 5424 / RFC 3164) y enruta eventos de log a través de network sockets vía TCP/UDP/TLS.
2. **Log Normalization & Parsing (Logstash):** Los logs de texto no estructurados deben traducirse a un schema estructurado (JSON keys) a través de coincidencias de expresiones regulares (Grok), mutaciones y field casting para permitir agregaciones con alto rendimiento.
3. **Storage Engineering & Index Lifecycle (Elasticsearch/Lucene):** Los campos `text` se dividen en tokens mediante inverted indices para búsqueda full-text, mientras que los campos escalares estructurados utilizan `doc_values` (almacenamiento columnar) para agregaciones. Los índices de logs requieren Index Lifecycle Management (ILM) automatizado para gestionar la capacidad de los shards, rollover y eliminación por retención sin sobrecargar los IOPS del cluster.
4. **Resiliency & Backpressure Handling:** Las pipelines de logging de alto rendimiento utilizan message queues desacopladas (ej., Apache Kafka o buffers de memoria edge asistidos por disco) para aislar los indexers de picos de tráfico y caídas de clusters aguas abajo (downstream).

---

## Exercise 1: Systemd Journald & Rsyslog Local Engine Tuning and Forwarding

### Architectural Mechanics & Trade-Offs
`systemd-journald` mantiene la integridad de los logs almacenando entradas en un formato binario append-only con tablas hash internas. Una alta frecuencia de logs puede provocar caídas en el ring-buffer del kernel o agotamiento de IOPS. `SystemMaxUse` limita el consumo total de disco, mientras que `RateLimitIntervalSec` y `RateLimitBurst` establecen throttles de tipo leaky-bucket. `rsyslog` se apoya en módulos dinámicos (`imuxsock`, `imklog`, `omfwd`) para leer desde el journal socket y enviar flujos de logs downstream vía TCP.

### Step 1.1: Configure Production `journald` Persistence & Rate-Limiting
Cree o modifique el directorio de almacenamiento persistente y escriba un archivo de configuración `/etc/systemd/journald.conf.d/production.conf` endurecido (hardened) para prevenir el agotamiento de disco y log storming.

```bash
sudo mkdir -p /var/log/journal
sudo chown root:systemd-journal /var/log/journal
sudo chmod 2755 /var/log/journal
```

Escriba el archivo de configuración `/etc/systemd/journald.conf.d/production.conf`:

```ini
[Journal]
# Force persistent disk storage over volatile RAM ring buffers
Storage=persistent
Compress=yes
Seal=yes

# Rate limiting: Max 10,000 log entries within a 30-second window per unit
RateLimitIntervalSec=30s
RateLimitBurst=10000

# Retention and Storage Constraints
SystemMaxUse=5G
SystemKeepFree=2G
SystemMaxFileSize=500M
MaxRetentionSec=1month

# Sync behavior: Flush to disk every 30 seconds to optimize write IOPS
SyncIntervalSec=30s
ForwardToSyslog=yes
```

Reinicie `systemd-journald` para aplicar las reglas limpiamente:

```bash
sudo systemctl restart systemd-journald
```

### Step 1.2: Validate Journal Filter Operations & Structured Querying
Ejecute consultas estructuradas utilizando `journalctl` para filtrar por severidad de prioridad, unit, y emitir payloads en formato JSON para procesamiento downstream.

```bash
journalctl _SYSTEMD_UNIT=nginx.service PRIORITY=3 --since "1 hour ago" --output=json-pretty -n 1
```

**Expected Command Output:**

```json
{
	"__CURSOR" : "s=a1b2c3d4e5f6...",
	"__REALTIME_TIMESTAMP" : "1723034400000000",
	"__MONOTONIC_TIMESTAMP" : "123456789",
	"_BOOT_ID" : "9f8e7d6c5b4a3210...",
	"_TRANSPORT" : "stdout",
	"PRIORITY" : "3",
	"_PID" : "4102",
	"_UID" : "33",
	"_GID" : "33",
	"_SYSTEMD_UNIT" : "nginx.service",
	"_HOSTNAME" : "prod-edge-node-01",
	"MESSAGE" : "2026/08/07 08:00:00 [error] 4102#4102: *1092 open() \"/usr/share/nginx/html/missing.html\" failed (2: No such file or directory), client: 192.168.1.50, server: localhost, request: \"GET /missing.html HTTP/1.1\", host: \"10.0.0.15\"",
	"_COMM" : "nginx"
}
```

### Step 1.3: Configure Rsyslog Remote TCP Forwarding with Disk-Assisted Queue
Edite `/etc/rsyslog.d/50-remote-forwarding.conf` para procesar logs locales y reenviar confiablemente logs con prioridad `Warning` (4) o superior a un receptor central (`10.0.10.50:514`) sobre TCP con un fallback de cola asíncrona.

```syslog
# Load input module for system socket
module(load="imuxsock")

# Define template for RFC 5424 structured syslog format
template(name="ProductionJsonFormat" type="string" string="{\"timestamp\":\"%timestamp:::date-rfc3339%\",\"hostname\":\"%HOSTNAME%\",\"app-name\":\"%app-name%\",\"procid\":\"%procid%\",\"facility\":\"%syslogfacility-text%\",\"severity\":\"%syslogseverity-text%\",\"message\":\"%msg:::json%\"}\n")

# Configure queue rules for remote output module omfwd
action(
    type="omfwd"
    target="10.0.10.50"
    port="514"
    protocol="tcp"
    template="ProductionJsonFormat"
    queue.filename="remote_queue"
    queue.size="100000"
    queue.maxdiskspace="2g"
    queue.saveonshutdown="on"
    queue.type="LinkedList"
    action.resumeRetryCount="-1"
    filterCondition="*.warn"
)
```

Valide la sintaxis de configuración de rsyslog y reinicie el demonio:

```bash
rsyslogd -N1
sudo systemctl restart rsyslog
```

**Expected Command Output:**

```text
rsyslogd: version 8.2302.0, config validation run...
rsyslogd: End of configuration run check. [State 0] No error detected.
```

---

### Verification Questions - Exercise 1

1. **¿Qué consecuencias técnicas ocurren si `ForwardToSyslog=yes` permanece habilitado en `journald.conf` mientras `rsyslog` lee directamente los streams binarios del journal a través del módulo `imjournal`?**
2. **Si una aplicación genera 50,000 líneas de log en una ráfaga de 10 segundos bajo los límites de rate limiting configurados arriba en `journald.conf`, ¿cuántos logs se almacenarán en el journal y cómo reporta `journalctl` las entradas descartadas?**

---

## Exercise 2: Logstash Data Processing Pipeline, Grok Normalization, and Field Mutation

### Architectural Mechanics & Trade-Offs
Logstash opera con un modelo de hilos de ejecución orientados a eventos: **Input Plugin** $\rightarrow$ **In-Memory Queue / Persistent Queue** $\rightarrow$ **Worker Thread Pipeline (Filter)** $\rightarrow$ **Output Batch Execution**. Los plugins de Grok parsean cadenas no estructuradas ejecutando patrones del motor de expresiones regulares. El uso excesivo de regex complejas con backreferences puede causar catastrófico backtracking y agotamiento de CPU. Los filtros `date` alinean los timestamps de los eventos a `@timestamp` ISO8601 UTC para prevenir el sesgo (skew) del índice.

```
                  ┌──────────────────────────────────────────────┐
                  │ Logstash Pipeline Worker Thread Pool        │
                  │                                              │
┌──────────────┐  │  ┌──────────────┐    ┌────────────────────┐  │  ┌──────────────────┐
│ Beats / TCP  │──┼─►│ Grok Filter  │───►│ Mutate / Convert   │──┼─►│ Elasticsearch    │
│ Input Socket │  │  │ (Regex Parse)│    │ (IP / GeoIP / Date)│  │  │ Output Plugin    │
└──────────────┘  │  └──────────────┘    └────────────────────┘  │  └──────────────────┘
                  └──────────────────────────────────────────────┘
```

### Step 2.1: Write a Complete Logstash Processing Pipeline
Cree `/etc/logstash/conf.d/01-nginx-processing.conf` para aceptar inputs de Filebeat en el puerto `5044`, parsear los access logs combinados de Nginx, convertir códigos de estado de respuesta HTTP en tipos de datos entero, calcular datos de GeoIP y enrutar eventos limpios a Elasticsearch mientras se colocan los logs malformados en una estructura de tags de Dead Letter Queue (DLQ).

```ruby
input {
  beats {
    port => 5044
    ssl  => false
  }
}

filter {
  if [fields][service] == "nginx-access" {
    # Parse standard Nginx combined log string into structured JSON keys
    grok {
      match => { 
        "message" => "%{IPORHOST:client_ip} - %{DATA:remote_user} \[%{HTTPDATE:log_timestamp}\] \"%{WORD:http_method} %{URIPATHPARAM:request_path} HTTP/%{NUMBER:http_version}\" %{NUMBER:response_code:int} %{NUMBER:bytes_sent:int} \"%{DATA:referrer}\" \"%{DATA:user_agent}\"" 
      }
      remove_field => [ "message" ]
      tag_on_failure => [ "_grokparsefailure_nginx" ]
    }

    if "_grokparsefailure_nginx" not in [tags] {
      # Align event time with the log's original timestamp
      date {
        match => [ "log_timestamp", "dd/MMM/yyyy:HH:mm:ss Z" ]
        target => "@timestamp"
        remove_field => [ "log_timestamp" ]
      }

      # Extract network IP geolocation data
      geoip {
        source => "client_ip"
        target => "geo"
      }

      # Mutate data fields and drop noise
      mutate {
        convert => {
          "bytes_sent" => "integer"
          "response_code" => "integer"
        }
        lowercase => [ "http_method" ]
        add_field => { "environment" => "production" }
      }

      # Filter out noisy internal health checks
      if [request_path] == "/healthz" or [request_path] == "/metrics" {
        drop {}
      }
    }
  }
}

output {
  if "_grokparsefailure_nginx" in [tags] {
    elasticsearch {
      hosts => ["http://10.0.20.10:9200"]
      index => "dlq-nginx-failures-%{+YYYY.MM.dd}"
    }
  } else {
    elasticsearch {
      hosts => ["http://10.0.20.10:9200"]
      index => "logstash-nginx-access-%{+YYYY.MM.dd}"
      action => "create"
    }
  }
}
```

### Step 2.2: Test Pipeline Syntax and Simulate Log Parsing Execution
Valide la sintaxis de la pipeline de Logstash con el motor de pruebas de configuración principal:

```bash
/usr/share/logstash/bin/logstash --config.test_and_exit -f /etc/logstash/conf.d/01-nginx-processing.conf
```

**Expected Command Output:**

```text
Sending Logstash logs to /var/log/logstash which is now configured via log4j2.properties
[2026-08-07T08:15:22,410][INFO ][logstash.runner          ] Starting Logstash {"logstash.version"=>"8.12.0"}
[2026-08-07T08:15:24,890][INFO ][logstash.config.sources.local.configcondition] No configuration change detected or old configuration was invalid
Configuration OK
[2026-08-07T08:15:25,102][INFO ][logstash.runner          ] Logstash shut down.
```

---

### Verification Questions - Exercise 2

1. **¿Por qué es crítico usar el filtro `date` para reemplazar `@timestamp` al indexar logs por lotes (batch) de gran volumen en Elasticsearch, y qué problema operacional ocurre si se omite este paso?**
2. **Si un filtro Grok experimenta altos picos de utilización de CPU que causan latencia en la pipeline, ¿qué parámetro de configuración o estructura de patrón de expresión regular debería auditarse para solucionar el problema?**

---

## Exercise 3: Elasticsearch Storage, Shard Topology, and Index Lifecycle Management (ILM)

### Architectural Mechanics & Trade-Offs
Elasticsearch indexa documentos dentro de instancias dinámicas de Lucene llamadas **Shards**. 
* **Campos `text`:** son analizados por analyzers en Inverted Indexes tokenizados para búsqueda full-text (alto footprint de memoria, no agregables).
* **Campos `keyword`:** se almacenan como cadenas exactas en `doc_values` (formato columnar en disco optimizado para ordenamiento y agregaciones).

**Index Lifecycle Management (ILM)** automatiza la estratificación (tiering) a través de arquitecturas de nodos físicos:
1. **Hot Phase:** Altos IOPS de escritura, sharding primario, ejecución de rollover.
2. **Warm Phase:** Operaciones de solo lectura, reducción (shrink) de shards, force-merge de segmentos de Lucene en segmentos únicos para liberar memoria.
3. **Cold Phase:** Índices congelados de solo lectura respaldados por almacenamiento de objetos.
4. **Delete Phase:** Eliminación definitiva basada en el SLA de retención.

```
┌─────────────────┐      Rollover      ┌─────────────────┐    ForceMerge     ┌─────────────────┐
│    HOT PHASE    │ ─────────────────► │   WARM PHASE    │ ────────────────► │  DELETE PHASE   │
│  (Write / Read) │  Max Size: 50GB    │   (Read-Only)   │    Retain 30d     │  Purge Indices  │
│ Primary Shards  │  Max Age:  7d      │ Single Segment  │                   │  Free Cluster   │
└─────────────────┘                    └─────────────────┘                   └─────────────────┘
```

### Step 3.1: Define ILM Policy via Elasticsearch API
Configure una política de ciclo de vida automatizada de 4 etapas utilizando `curl` contra la REST API (`10.0.20.10:9200`).

```bash
curl -X PUT "http://10.0.20.10:9200/_ilm/policy/logs_production_ilm_policy" \
     -H 'Content-Type: application/json' \
     -d '{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_primary_shard_size": "50gb",
            "max_age": "7d",
            "max_docs": 100000000
          },
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "0ms",
        "actions": {
          "forcemerge": { "max_num_segments": 1 },
          "allocate": { "number_of_replicas": 1 },
          "set_priority": { "priority": 50 }
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
}'
```

**Expected Command Output:**

```json
{"acknowledged":true}
```

### Step 3.2: Create Index Template with Explicit Field Mappings
Cree un Index Template compuesto `/etc/elasticsearch/templates/nginx_template.json` para imponer tipos de schema estrictos (`keyword` vs `text`) y vincular la política de ILM a los índices coincidentes.

```bash
curl -X PUT "http://10.0.20.10:9200/_index_template/logstash_nginx_template" \
     -H 'Content-Type: application/json' \
     -d '{
  "index_patterns": ["logstash-nginx-access-*"],
  "template": {
    "settings": {
      "number_of_shards": 2,
      "number_of_replicas": 1,
      "index.lifecycle.name": "logs_production_ilm_policy",
      "index.lifecycle.rollover_alias": "logstash-nginx-access"
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "client_ip": { "type": "ip" },
        "http_method": { "type": "keyword" },
        "request_path": { 
          "type": "text",
          "fields": {
            "keyword": { "type": "keyword", "ignore_above": 256 }
          }
        },
        "response_code": { "type": "integer" },
        "bytes_sent": { "type": "long" },
        "user_agent": { "type": "text" },
        "environment": { "type": "keyword" }
      }
    }
  }
}'
```

**Expected Command Output:**

```json
{"acknowledged":true}
```

### Step 3.3: Inspect Cluster Index Health and ILM Execution Status
Consulte el estado del cluster para verificar la asignación activa de shards y la vinculación de políticas:

```bash
curl -X GET "http://10.0.20.10:9200/_cat/indices/logstash-nginx-access-*?v&s=index"
```

**Expected Command Output:**

```text
health status index                                 uuid                   pri rep docs.count docs.deleted store.size pri.store.size
green  open   logstash-nginx-access-2026.08.07-000001 aB8kL9pQRy2vM5_xXzW1yA   2   1   1425890          0      1.2gb        614.2mb
```

---

### Verification Questions - Exercise 3

1. **¿Por qué agregar métricas de dashboard sobre un campo mapeado puramente como `text` es ineficiente o propenso a errores de Out-Of-Memory (OOM) en comparación con un campo mapeado como `keyword`?**
2. **¿Qué ocurre si los tamaños de los shards primarios en un índice crecen a 200 GB sin tener habilitada la configuración de rollover de ILM? ¿Cómo impacta esto en la latencia de búsqueda y el rebalanceo de nodos?**

---

## Exercise 4: High-Availability Edge Collection (Filebeat) & Buffer Architecture (Kafka)

### Architectural Mechanics & Trade-Offs
Durante eventos de tráfico pico o mantenimiento de nodos indexers, el envío directo de logs (`Filebeat` $\rightarrow$ `Logstash`) corre el riesgo de pérdida de datos o agotamiento de memoria edge si el backpressure bloquea las conexiones de los clientes. Desplegar **Apache Kafka** como un commit log distribuido y persistente desacopla los colectores de los indexers de logs. Filebeat almacena logs en colas circulares de disco local antes de publicar mensajes a las particiones de Kafka. Los hilos worker de Logstash consumen mensajes de los grupos de consumidores de Kafka a una tasa de ingesta controlada.

```
┌────────────────────────┐                    ┌────────────────────────┐                    ┌────────────────────────┐
│ Filebeat Edge Node     │                    │ Apache Kafka Cluster   │                    │ Logstash Cluster       │
│                        │                    │                        │                    │                        │
│ ┌────────────────────┐ │   TCP Stream       │ ┌────────────────────┐ │   Consumer Group   │ ┌────────────────────┐ │
│ │ File Tailer Engine │─┼───────────────────►│ │ Topic: app-logs    │─┼───────────────────►│ │ Kafka Input Plugin │ │
│ └────────────────────┘ │ (TLS + ACKs=1)     │ │ Partition 0, 1, 2  │ │ (Auto-Offset-Commit)│ └────────────────────┘ │
│ ┌────────────────────┐ │                    │ └────────────────────┘ │                    │                        │
│ │ Disk Spool Buffer  │ │                    └────────────────────────┘                    └────────────────────────┘
│ └────────────────────┘ │
└────────────────────────┘
```

### Step 4.1: Configure Filebeat Edge Collector with Kafka Output
Cree `/etc/filebeat/filebeat.yml` para ingerir archivos syslog, utilice un buffer circular de memoria interno como fallback, y publique payloads en un topic de cluster de Kafka particionado (`app-logs`).

```yaml
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/nginx/access.log
  fields:
    service: nginx-access
    datacenter: us-east-1
  fields_under_root: true
  scan_frequency: 10s
  close_inactive: 5m

# Internal disk-assisted buffer when Kafka brokers are unreachable
queue.mem:
  events: 4096
  flush.min_events: 512
  flush.timeout: 1s

output.kafka:
  hosts: ["10.0.30.11:9092", "10.0.30.12:9092", "10.0.30.13:9092"]
  topic: 'app-logs'
  partition.round_robin:
    reachable_only: true
  required_acks: 1
  compression: gzip
  max_message_bytes: 1000000
```

Valide la configuración de Filebeat y la conectividad de salida:

```bash
filebeat test config -c /etc/filebeat/filebeat.yml
filebeat test output -c /etc/filebeat/filebeat.yml
```

**Expected Command Output:**

```text
Config OK
kafka: 10.0.30.11:9092... connected
  TLS... disabled
  status... active
  version... 3.4.0
```

### Step 4.2: Configure Logstash Kafka Consumer Pipeline
Cree `/etc/logstash/conf.d/00-kafka-input.conf` para procesar eventos desde la cola distribuida:

```ruby
input {
  kafka {
    bootstrap_servers => "10.0.30.11:9092,10.0.30.12:9092,10.0.30.13:9092"
    topics => ["app-logs"]
    group_id => "logstash-indexer-group"
    consumer_threads => 4
    auto_offset_reset => "latest"
    codec => "json"
    metadata_max_age_ms => 60000
  }
}

output {
  elasticsearch {
    hosts => ["http://10.0.20.10:9200"]
    index => "kafka-app-logs-%{+YYYY.MM.dd}"
  }
}
```

---

### Verification Questions - Exercise 4

1. **¿Cómo establece la configuración `required_acks: 1` en la salida de Kafka de Filebeat un equilibrio entre la durabilidad de los datos y la latencia de envío en comparación con `required_acks: 0` y `required_acks: -1` (all)?**
2. **Si los indexers de Logstash quedan fuera de línea durante 2 horas durante la actualización de un cluster, ¿qué sucede con los logs recolectados por Filebeat en el edge y cómo gestiona Kafka el backlog sin perder datos?**

---

## Official Documentation References & Sources

* **LPI DevOps Tools Engineer Exam Objectives:** [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Systemd Journald Configuration Manual:** [https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html)
* **Rsyslog Core Documentation:** [https://www.rsyslog.com/doc/v8-stable/configuration/index.html](https://www.rsyslog.com/doc/v8-stable/configuration/index.html)
* **Elastic Logstash Reference Guide:** [https://www.elastic.co/guide/en/logstash/current/index.html](https://www.elastic.co/guide/en/logstash/current/index.html)
* **Elasticsearch Index Lifecycle Management (ILM):** [https://www.elastic.co/guide/en/elasticsearch/reference/current/index-lifecycle-management.html](https://www.elastic.co/guide/en/elasticsearch/reference/current/index-lifecycle-management.html)
* **Elastic Beats - Kafka Output Integration:** [https://www.elastic.co/guide/en/beats/filebeat/current/kafka-output.html](https://www.elastic.co/guide/en/beats/filebeat/current/kafka-output.html)

---

<details>
<summary><strong>Solutions and Explanations (Click to Expand)</strong></summary>

### Exercise 1 Solutions

1. **Duplicate Log Processing and Loop Vulnerabilities:**
   * **Mecanismo:** Habilitar `ForwardToSyslog=yes` le indica a `systemd-journald` que reenvíe cada línea registrada al socket clásico `/dev/log`. Si `rsyslog` utiliza simultáneamente `imjournal` para leer directamente desde los archivos binarios del journal en disco mientras también escucha en `/dev/log` (`imuxsock`), recibirá y registrará cada mensaje **dos veces**.
   * **Impacto en Producción:** Doble carga de IOPS, indexación duplicada, costos de almacenamiento duplicados y recuentos de métricas corruptos.
   * **Mejor Práctica:** Al usar configuraciones modernas de `rsyslog`, mantenga `imjournal` habilitado y deshabilite `ForwardToSyslog` en `journald.conf`, o use `imuxsock` exclusivamente con `ForwardToSyslog=yes` mientras deshabilita `imjournal`.

2. **Leaky-Bucket Throttle Execution:**
   * **Cálculo:** La configuración especifica `RateLimitIntervalSec=30s` y `RateLimitBurst=10000`. 
   * **Resultado:** De las 50,000 entradas generadas en 10 segundos, exactamente **10,000 entradas** se escribirán en disco. Las **40,000 entradas** restantes se descartan en el límite del journal.
   * **Reporte en `journalctl`:** `journald` emite una advertencia de metadatos directamente en el stream del journal:
     `Suppressed 40000 messages from /system.slice/nginx.service`

---

### Exercise 2 Solutions

1. **Timestamp Normalization & Index Skew Prevention:**
   * **Mecanismo:** En ausencia del filtro `date`, Logstash asigna `@timestamp` usando la hora del reloj del sistema en el momento exacto en que Logstash *procesa* el log.
   * **Escenario de Falla:** Si particiones de red o acumulaciones en la cola retrasan la entrega de logs por 6 horas, los logs generados a las 02:00 UTC se almacenarán con un `@timestamp` de las 08:00 UTC.
   * **Impacto en Producción:** Las visualizaciones de series temporales en Kibana/Grafana muestran picos de tiempo inexactos, la correlación para el análisis de causa raíz (RCA) entre microservicios dispares se rompe, y los nombres de índices diarios de ILM (`logstash-nginx-access-2026.08.07`) reciben eventos históricos que pertenecen a índices más antiguos.

2. **Regex Backtracking and Grok Optimization:**
   * **Mecanismo:** La latencia de Grok y los altos picos de CPU se derivan del **Nondeterministic Finite Automaton (NFA) catastrophic backtracking**, causado por operadores de coincidencia codiciosos (`.*` o `%{DATA}`) posicionados adyacentes a patrones opcionales o superpuestos.
   * **Remediación:** Reemplace los patrones ambiguos con clases de caracteres de regex exactas y ancladas (por ejemplo, reemplace `%{DATA}` con `[^"]+` o tipos numéricos estrictos `%{NUMBER}`). Audite el rendimiento utilizando la API de monitoreo de pipelines de Logstash o pruebe expresiones a través de depuradores de Grok.

---

### Exercise 3 Solutions

1. **`text` vs `keyword` Storage Engine Mechanics:**
   * **Campos `text`:** Se analizan en términos de índice invertido. Las agregaciones (como `terms` o `date_histogram`) en campos `text` fuerzan a Elasticsearch a cargar cadenas tokenizadas en la Heap Memory a través de **Fielddata**. Cargar arreglos masivos de cadenas en la JVM heap provoca largas pausas de Garbage Collection (GC) y caídas del cluster por `java.lang.OutOfMemoryError`.
   * **Campos `keyword`:** Omiten los term analyzers y almacenan cadenas de bytes puras directamente en `doc_values`, una estructura de datos columnar en disco gestionada eficientemente por el page cache del SO. Las agregaciones se ejecutan contra `doc_values` sin consumir memoria de la JVM heap.

2. **Unmanaged Shard Growth Hazards:**
   * **Degradación del Rendimiento:** Un shard de 200 GB excede drásticamente el límite de tamaño de shard de Lucene recomendado de **30 GB – 50 GB**. 
   * **Latencia de Búsqueda:** Segmentos grandes de Lucene aumentan los tiempos de búsqueda en disco (seek times) y ralentizan la ejecución de consultas en paralelo.
   * **Falla de Recuperación:** Si un nodo del cluster falla, rebalancear o relocalizar un shard de 200 GB a través de interfaces de red satura el ancho de banda del cluster, arriesgando timeouts en cascada de los nodos y un estado `RED` en todo el cluster.

---

### Exercise 4 Solutions

1. **Kafka Producer Acknowledgement (`required_acks`) Trade-offs:**
   * **`required_acks: 0` (Sin Confirmación):** El productor de Filebeat envía paquetes sin esperar confirmación del broker. Menor latencia, mayor rendimiento, pero arriesga la pérdida total de logs si el broker de Kafka descarta paquetes.
   * **`required_acks: 1` (Confirmación del Líder - Configurado):** El productor espera a que el broker Líder de la partición escriba el evento en su log local. Proporciona una sólida protección contra caídas de red con una baja latencia de envío.
   * **`required_acks: -1` o `all` (Sincronización Completa de Replicas):** El productor espera hasta que el Líder y todas las In-Sync Replicas (ISR) escriban el evento. Máxima garantía de durabilidad de datos, pero aumenta la latencia de ida y vuelta de la red (round-trip latency).

2. **Backpressure Decoupling & Queue Persistence:**
   * **Resiliencia Edge:** Filebeat detecta rechazos de conexión TCP o ACKs faltantes desde Kafka. Pausa los offsets de posición de logs y almacena localmente los logs entrantes dentro de su buffer circular de memoria configurado (`queue.mem`).
   * **Desacoplamiento de Brokers:** Una vez que Filebeat envía los eventos a Kafka, Kafka escribe los payloads en sus logs de partición en disco duraderos y append-only (`app-logs`).
   * **Reanudación del Consumidor:** Cuando Logstash vuelve a estar en línea después de 2 horas, se reconecta a Kafka utilizando su `group_id` persistente (`logstash-indexer-group`). Logstash obtiene los offsets no leídos almacenados desde Kafka y se pone al día al máximo rendimiento de indexación sin perder una sola entrada de log ni bloquear los hilos de la aplicación.

</details>