# 704.3 Gestión y Análisis de Logs

**Examen:** LPI DevOps Tools Engineer — 701-100, v2.0.0
**Peso del objetivo:** 3.33
**Perfil:** SRE / Arquitecto de Plataforma

---

## 1. El problema arquitectónico

Una línea de log es la única señal de telemetría que lleva *contexto ilimitado*. Una métrica te dice que el 0,4 % de las requests devolvió 503; una traza te dice qué span falló; solo la línea de log te dice `upstream prematurely closed connection while reading response header from upstream, upstream: "http://10.244.3.17:8080/checkout"`. Esa riqueza es exactamente lo que hace de los logs la señal más cara de operar: son de alto volumen, de alta cardinalidad, sin esquema por defecto, y los produce software que no controlás.

Tres propiedades de la infraestructura moderna rompen el flujo de trabajo clásico `ssh host && tail -f /var/log/app.log`:

1. **El host es efímero.** Un pod de Kubernetes al que el OOM killer mata a las 03:14 y que es reprogramado no deja ningún sistema de archivos detrás. El log tiene que haber salido del nodo *antes* del incidente, no después.
2. **La unidad de fallo es una request, no un proceso.** Una sola request HTTP toca un ingress controller, tres servicios, un sidecar proxy y una base de datos. Correlacionar eso requiere un identificador compartido (`trace.id`) y un único almacén consultable.
3. **El costo de una línea de log se paga en la ingesta, no en la lectura.** La indexación es el costo dominante en los sistemas de la clase de Elasticsearch. Cada decisión —qué parsear, qué indexar, qué conservar— es una decisión de costo tomada antes de que ocurra el incidente, por alguien que no sabe qué campo va a importar.

La pregunta arquitectónica para 704.3 no es, entonces, "cómo meto logs en Elasticsearch", sino: **en qué punto del pipeline se agrega la estructura, dónde absorbe el buffering la contrapresión, y cuál es el modo de fallo cuando el almacén no está disponible.**

### 1.1 Los tres modos de fallo de un pipeline de logging

| Modo de fallo | Síntoma | Causa raíz | Defensa arquitectónica |
|---|---|---|---|
| **Pérdida de datos** | Hueco en Discover durante la ventana del incidente | El shipper hizo buffer en memoria y el nodo se reinició; o el almacén rechazó escrituras y el shipper descartó | Cola respaldada en disco en el shipper *y* en el agregador; entrega at-least-once |
| **Colapso por contrapresión** | Los contenedores de la aplicación se bloquean en `write(2)` a stdout; picos de latencia | El pipe de log está lleno porque el colector dejó de leer (Docker `json-file` con un plugin bloqueado) | Nunca dejes que el runtime se bloquee sobre el colector; desacoplá con archivo + rotación |
| **Explosión de costo** | Disco del clúster al 92 %, ILM borrando los datos de ayer | El mapeo dinámico creó 14 000 campos a partir de un payload JSON; mapeo `text` sobre un campo UUID | Mapeos estrictos, `ignore_above`, límites de campos como barandas, descarte en tiempo de ingesta |

El tercero es el más común en la práctica y el menos dramático: no suena ninguna alerta, el pipeline sigue funcionando, y seis semanas después la retención bajó silenciosamente de 30 días a 4.

---

## 2. Formatos de log y logging estructurado

### 2.1 Los formatos de cable que te vas a encontrar de verdad

| Formato | Especificación | Timestamp | Estructura | Dónde te lo encontrás |
|---|---|---|---|---|
| BSD syslog | RFC 3164 | `MMM dd HH:mm:ss`, **sin año, sin zona horaria, sin subsegundo** | Texto libre después de `TAG:` | Equipamiento de red, daemons viejos, valores por defecto de `logger(1)` |
| IETF syslog | RFC 5424 | RFC 3339 con offset y segundos fraccionarios | SD-elements de `STRUCTURED-DATA` | rsyslog/syslog-ng con `RSYSLOG_SyslogProtocol23Format` |
| journald nativo | systemd | `__REALTIME_TIMESTAMP` µs desde epoch | Campos `KEY=value` arbitrarios, indexados | Todo host con systemd; `journalctl -o json` |
| JSON Lines | de facto | Lo que escriba la app | Anidamiento completo | Apps 12-factor, stdout de contenedores |
| logfmt | de facto | definido por la app | `k=v` plano | Ecosistema Go (linaje Heroku) |
| CRI log | Kubernetes CRI | RFC 3339 nano, UTC | `<ts> <stream> <tag> <msg>` | `/var/log/pods/**/*.log` en cada nodo |

Vale la pena memorizar el formato de línea de CRI, porque todo colector de Kubernetes debe quitarlo antes de que el payload sea usable:

```
2026-09-18T08:14:22.481937214Z stdout F {"level":"error","msg":"checkout failed","order_id":"a91f"}
2026-09-18T08:14:22.482011882Z stdout P this is a partial line that was split because it exceeded
2026-09-18T08:14:22.482013104Z stdout F  the 16 KiB runtime buffer and must be reassembled
```

`F` = línea completa, `P` = parcial. Un colector que no reensambla las líneas `P` va a corromper todo mensaje de log de más de 16 KiB — una fuente clásica de "nuestros stack traces de Java salen truncados".

### 2.2 RFC 3164 es una trampa

```
Sep 18 08:14:22 web01 nginx: upstream timed out
```

Sin año y sin zona horaria. El consumidor tiene que adivinar ambos. Cada enero, una flota sobre RFC 3164 produce una ráfaga de documentos fechados once meses en el futuro o en el pasado, según cómo resuelva el año el parser. Arreglalo en el origen:

```
# /etc/rsyslog.conf
module(load="imuxsock")
module(load="imjournal" StateFile="imjournal.state")

# RFC 5424 with year, timezone and sub-second precision
$ActionFileDefaultTemplate RSYSLOG_SyslogProtocol23Format

# Reliable forwarding: RELP with an on-disk spool, not plain UDP
module(load="omrelp")
action(type="omrelp"
       target="logs-agg.internal"
       port="2514"
       tls="on"
       tls.caCert="/etc/ssl/certs/internal-ca.pem"
       queue.type="LinkedList"
       queue.filename="relp_fwd"
       queue.maxdiskspace="2g"
       queue.saveonshutdown="on"
       action.resumeRetryCount="-1")
```

`UDP syslog silently drops under load`. Si el objetivo es "sin huecos durante el incidente", el `omfwd` simple sobre UDP se descalifica de inmediato: el incidente *es* la carga.

### 2.3 Logging estructurado y un esquema común

La estructura en el origen le gana al parseo aguas abajo en todos los ejes: ninguna regex que mantener, ningún `_grokparsefailure`, nada de CPU quemada en Oniguruma. La aplicación emite:

```
{"@timestamp":"2026-09-18T08:14:22.481Z","log.level":"error","message":"checkout failed","service.name":"checkout-api","service.version":"2.11.3","trace.id":"4bf92f3577b34da6a3ce929d0e0e4736","span.id":"00f067aa0ba902b7","http.request.method":"POST","url.path":"/api/v1/orders","http.response.status_code":503,"error.type":"UpstreamTimeout","event.duration":4102831000}
```

Compiten dos esquemas, y conviene elegir uno deliberadamente:

| | **ECS** (Elastic Common Schema) | **Modelo de datos de Logs de OpenTelemetry** |
|---|---|---|
| Nomenclatura de campos | Con puntos, con capacidad de anidamiento: `http.response.status_code` | Atributos con convenciones semánticas: `http.response.status_code` |
| Timestamp | `@timestamp`, RFC 3339 ms | `Time`, `ObservedTime`, nanos uint64 |
| Severidad | `log.level` (string) | `SeverityNumber` (1–24) + `SeverityText` |
| Correlación | `trace.id`, `span.id`, `transaction.id` | `TraceId`, `SpanId`, `TraceFlags` (de primera clase, binario) |
| Identidad del recurso | aplanada dentro del documento (`host.name`, `container.id`) | Bloque `Resource` separado, deduplicado por lote |
| Acoplamiento a proveedor | Elastic, pero publicado bajo Apache-2.0 | CNCF, neutral respecto del proveedor |
| Madurez para logs | Estable, conjunto de campos muy amplio | Especificación estable; soporte universal en el collector |

ECS y las convenciones semánticas de OTel vienen convergiendo desde que Elastic donó ECS a OpenTelemetry en 2023, así que los nombres de campo coinciden en gran medida. **Elegí ECS si tu almacén es Elasticsearch** (las plantillas de índice incluidas, los dashboards de Kibana y las reglas de detección lo asumen); elegí el modelo de datos de OTel si el collector ya es tu puerta de entrada de telemetría para métricas y trazas.

La regla innegociable: **un solo esquema, impuesto en el agregador**, no "lo que emita cada equipo". Un campo que es `http.response.status_code: 503` en un servicio y `status: "503"` en otro no se puede agregar, y el segundo además va a envenenar el mapeo.

---

## 3. Arquitectura: shipper, agregador, almacén, UI

```
                 ┌──────────────┐
  app stdout ───►│  node agent  │  Filebeat / Fluent Bit / Vector / Alloy
   /var/log ────►│  (DaemonSet) │  - tail + reassemble + light enrichment
                 └──────┬───────┘  - disk registry (offset durability)
                        │ Lumberjack / OTLP / HTTP  (TLS, backpressure-aware)
                        ▼
                 ┌──────────────┐
                 │  aggregator  │  Logstash / Fluentd / OTel Collector
                 │  (StatefulSet│  - heavy parse, enrich, redact, route
                 │   + PVC)     │  - persistent queue = shock absorber
                 └──────┬───────┘
                        │ bulk
             ┌──────────┴──────────┐
             ▼                     ▼
      ┌─────────────┐      ┌──────────────┐
      │Elasticsearch│      │ object store │  cold/archive, compliance
      │ hot/warm/cold      │  (S3/MinIO)  │
      └──────┬──────┘      └──────────────┘
             ▼
        ┌────────┐
        │ Kibana │
        └────────┘
```

### 3.1 Por qué una capa de agregación

*Podés* enviar Filebeat → Elasticsearch directamente y parsear con un ingest pipeline. Eso es más barato y tiene una pieza móvil menos. El agregador se gana el sueldo cuando:

- El parseo es caro (grok sobre varios MB/s de texto no estructurado) y no querés esa CPU compitiendo con la búsqueda en los nodos de datos.
- Tenés que **repartir**: el mismo evento a Elasticsearch, a S3 para cumplimiento, a un SIEM, a Kafka para un procesador de streams.
- Necesitás un **buffer durable grande**. El buffer de Filebeat es el archivo de log mismo más un spool chico; si Elasticsearch está caído dos horas y el nodo rota sus logs, los datos se perdieron. Una cola persistente de Logstash de 50 GB lo sobrevive.
- Necesitás **redacción antes del almacenamiento** (PII, secretos, números de tarjeta) y no podés confiar en el borde.

### 3.2 Comparación de shippers

| | **Filebeat** | **Fluent Bit** | **Fluentd** | **Vector** | **Alloy / Promtail** | **OTel Collector** |
|---|---|---|---|---|---|---|
| Lenguaje | Go | C | Ruby + C | Rust | Go | Go |
| RSS a 10k EPS | ~120 MB | ~35 MB | ~250 MB | ~90 MB | ~80 MB | ~110 MB |
| Lenguaje de transformación | processors (YAML) | Lua / filtros incorporados | plugins Ruby | VRL (tipado, compilado) | River / pipeline stages | OTTL |
| Buffer en disco | registry + spool | `storage.type filesystem` | `buffer file` | `buffer.type disk` | WAL | extensión `file_storage` |
| Contrapresión | se propaga al harvester | `Mem_Buf_Limit`, pausa la entrada | se propaga | se propaga | se propaga | se propaga |
| Metadatos de K8s | `add_kubernetes_metadata` | filtro `kubernetes` | `kubernetes_metadata` | fuente `kubernetes_logs` | nativo | `k8sattributes` |
| Sink natural | Elasticsearch/Logstash | cualquiera | cualquiera | cualquiera | Loki | cualquiera (OTLP) |
| Relevancia para el examen | **alta** (nombrado en los objetivos) | conocimiento general | conocimiento general | — | conocimiento general | conocimiento general |

Para 701-100, **Filebeat es el shipper nombrado**. En producción, Fluent Bit y Vector son las opciones habituales cuando el almacén no es Elastic.

### 3.3 Comparación de almacenes — la decisión que determina tu curva de costo

| | **Elasticsearch / OpenSearch** | **Loki** | **ClickHouse** | **Graylog** |
|---|---|---|---|---|
| Modelo de índice | Índice invertido sobre **todos** los campos indexados | Índice solo sobre **labels**; el cuerpo del log se guarda como chunks comprimidos | Columnar, índice primario disperso + skip indexes/bloom | Elasticsearch/OpenSearch por debajo |
| Costo de ingesta | Alto (análisis + construcción del índice) | Muy bajo | Bajo–medio | Alto |
| Costo de consulta para `status:503` | O(postings list) — milisegundos | Escaneo por fuerza bruta de los streams coincidentes | Escaneo vectorizado + poda por bloom | como Elasticsearch |
| Multiplicador de almacenamiento vs crudo | 0,5–1,3× (logsdb/best_compression → ~0,3–0,5×) | 0,1–0,2× | 0,05–0,15× | como Elasticsearch |
| Peligro de cardinalidad | Explosión de campos en los mapeos | Explosión de **labels** → explosión de streams | Bajo | Explosión de campos |
| Agregaciones | Ricas, nativas | Limitadas (consultas métricas de LogQL) | SQL completo | Ricas |
| Relevancia full-text | Sí (BM25) | Solo substring/regex | Bloom de tokens / `hasToken` | Sí |
| Peso operativo | Alto (shards, heap, ILM) | Medio (necesita object store) | Medio (necesita diseño de esquema) | Medio |

El resumen arquitectónico honesto: **Elasticsearch te compra búsqueda arbitraria rápida a un alto costo de ingesta; Loki te compra retención barata al precio de conocer tu conjunto de labels de antemano; ClickHouse te compra ambas al precio de diseñar un esquema.** Elegí en función de si tus investigaciones arrancan desde un label conocido (servicio, namespace) —en cuyo caso Loki es drásticamente más barato— o desde un string desconocido encontrado en el reporte de un cliente.

---

## 4. Elasticsearch para cargas de trabajo de logs

### 4.1 Internals que cambian tu configuración

- **Segmentos y refresh.** Un documento solo es buscable después de que un *refresh* crea un nuevo segmento de Lucene. El `index.refresh_interval` por defecto es `1s`. Para logs, rara vez vale la pena la frescura de un segundo frente a la rotación de segmentos: poner `30s` típicamente compra un 15–25 % de throughput de indexación y muchos menos merges.
- **Translog.** La durabilidad viene del log de transacciones, fsynceado en cada request por defecto (`index.translog.durability: request`). `async` con `sync_interval: 30s` es una ganancia real de throughput y una decisión explícita de arriesgar 30 s de datos ante una caída dura de nodo. Para logs eso suele ser aceptable; para logs de auditoría no lo es.
- **doc_values vs índice invertido.** Las agregaciones y el ordenamiento leen `doc_values` columnares; la búsqueda lee el índice invertido. Un campo por el que solo filtrás de forma exacta (`kubernetes.pod.name`) debería ser `keyword`; un campo que solo agregás debería tener `index: false, doc_values: true`; un campo que nunca usás no debería indexarse en absoluto.
- **`match_only_text`.** Para el cuerpo del log, `match_only_text` no almacena normas ni posiciones en disco (las posiciones se recomputan desde `_source` para las consultas de frase). Es aproximadamente un 10 % más chico que `text` y el valor por defecto correcto para `message`.
- **Dimensionamiento de shards.** Apuntá a **30–50 GB por shard primario** para logs, y mantené el total de shards por debajo de aproximadamente **20 por GB de heap de la JVM** por nodo. La cantidad de shards no es una perilla que ajustás una vez — es la salida de los umbrales de `rollover`.

### 4.2 `elasticsearch.yml` — un nodo hot en un clúster por capas

```yaml
cluster.name: logs-prod
node.name: ${HOSTNAME}
node.roles: [data_hot, data_content, ingest]

path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

network.host: 0.0.0.0
http.port: 9200
transport.port: 9300

discovery.seed_hosts: ["es-master-0.es.internal", "es-master-1.es.internal", "es-master-2.es.internal"]
cluster.initial_master_nodes: ["es-master-0", "es-master-1", "es-master-2"]

bootstrap.memory_lock: true

xpack.security.enabled: true
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.keystore.path: certs/transport.p12
xpack.security.transport.ssl.truststore.path: certs/transport.p12
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.keystore.path: certs/http.p12

indices.memory.index_buffer_size: 20%
indices.breaker.total.use_real_memory: true

cluster.routing.allocation.disk.threshold_enabled: true
cluster.routing.allocation.disk.watermark.low: 80%
cluster.routing.allocation.disk.watermark.high: 88%
cluster.routing.allocation.disk.watermark.flood_stage: 95%

action.destructive_requires_name: true
```

El heap **no** se configura acá — va en `jvm.options.d/`:

```
-Xms31g
-Xmx31g
```

Nunca por encima de ~31 GB: pasado ese punto la JVM pierde los punteros comprimidos a objetos ordinarios y obtenés *menos* heap utilizable a partir de más memoria. El resto de la RAM va al page cache, que es lo que en realidad hace rápido a Lucene.

### 4.3 Data streams, no índices

Para datos de series temporales de solo anexado, usá un **data stream**. La convención de nombres es `<type>-<dataset>-<namespace>`:

```
logs-nginx.access-prod
logs-kubernetes.container_logs-default
```

Los índices de respaldo se llaman `.ds-logs-nginx.access-prod-2026.09.18-000042`. Las escrituras siempre van al nombre del stream; ILM rota el índice de respaldo por debajo tuyo; un `_search` contra el nombre del stream cubre todas las generaciones.

**Component template — el contrato de mapeo:**

```json
{
  "template": {
    "settings": {
      "index.number_of_shards": 3,
      "index.number_of_replicas": 1,
      "index.refresh_interval": "30s",
      "index.codec": "best_compression",
      "index.translog.durability": "async",
      "index.translog.sync_interval": "30s",
      "index.mapping.total_fields.limit": 2000,
      "index.mapping.ignore_malformed": true,
      "index.lifecycle.name": "logs-30d"
    },
    "mappings": {
      "dynamic": "true",
      "dynamic_templates": [
        {
          "strings_as_keyword": {
            "match_mapping_type": "string",
            "mapping": {
              "type": "keyword",
              "ignore_above": 1024
            }
          }
        },
        {
          "labels_are_flattened": {
            "path_match": "labels.*",
            "mapping": {
              "type": "flattened"
            }
          }
        }
      ],
      "properties": {
        "@timestamp": {
          "type": "date",
          "format": "strict_date_optional_time||epoch_millis"
        },
        "message": {
          "type": "match_only_text"
        },
        "log": {
          "properties": {
            "level": { "type": "keyword" },
            "logger": { "type": "keyword" },
            "offset": { "type": "long", "index": false }
          }
        },
        "service": {
          "properties": {
            "name": { "type": "keyword" },
            "version": { "type": "keyword" },
            "environment": { "type": "keyword" }
          }
        },
        "http": {
          "properties": {
            "request": {
              "properties": {
                "method": { "type": "keyword" }
              }
            },
            "response": {
              "properties": {
                "status_code": { "type": "short" },
                "body": {
                  "properties": {
                    "bytes": { "type": "long" }
                  }
                }
              }
            }
          }
        },
        "url": {
          "properties": {
            "original": { "type": "wildcard" },
            "path": { "type": "keyword" },
            "domain": { "type": "keyword" }
          }
        },
        "event": {
          "properties": {
            "duration": { "type": "long" },
            "dataset": { "type": "keyword" },
            "ingested": { "type": "date" }
          }
        },
        "trace": {
          "properties": {
            "id": { "type": "keyword" }
          }
        },
        "error": {
          "properties": {
            "type": { "type": "keyword" },
            "message": { "type": "match_only_text" },
            "stack_trace": { "type": "text", "index": false }
          }
        }
      }
    }
  },
  "_meta": {
    "description": "Base ECS-aligned mapping for application logs",
    "managed_by": "platform-team"
  }
}
```

Tres decisiones deliberadas ahí dentro, cada una previniendo una caída real:

- `dynamic_templates → keyword, ignore_above: 1024` impide que un campo descarriado de 2 MB sea analizado en decenas de miles de términos.
- `index.mapping.ignore_malformed: true` significa que un único documento con `status_code: "N/A"` se indexa salteando ese campo, en lugar de que se rechace el ítem completo del bulk. Los ítems de bulk rechazados en un pipeline de logging se convierten en tormentas de reintentos.
- `labels.*` como `flattened` mapea todo un subobjeto arbitrario a **un** solo campo. Este es el antídoto directo contra la explosión de mapeo por claves controladas por el usuario.

**Index template que lo enlaza al stream:**

```json
{
  "index_patterns": ["logs-nginx.access-*"],
  "data_stream": {},
  "priority": 500,
  "composed_of": ["logs-base-mappings", "logs-base-settings"],
  "template": {
    "settings": {
      "index.number_of_shards": 6
    }
  },
  "_meta": {
    "owner": "platform-team"
  }
}
```

Aplicándolos:

```
$ curl -sS -u elastic:$ES_PASS -X PUT "https://es01:9200/_component_template/logs-base-mappings" \
    -H 'Content-Type: application/json' --data-binary @component-mappings.json
{"acknowledged":true}

$ curl -sS -u elastic:$ES_PASS -X PUT "https://es01:9200/_index_template/logs-nginx.access" \
    -H 'Content-Type: application/json' --data-binary @index-template.json
{"acknowledged":true}

$ curl -sS -u elastic:$ES_PASS -X POST "https://es01:9200/_index_template/_simulate_index/logs-nginx.access-prod?pretty" | head -30
{
  "template" : {
    "settings" : {
      "index" : {
        "lifecycle" : { "name" : "logs-30d" },
        "codec" : "best_compression",
        "refresh_interval" : "30s",
        "number_of_shards" : "6",
        "number_of_replicas" : "1"
      }
    },
```

`_simulate_index` es el endpoint más subutilizado en la operación de Elasticsearch: te dice exactamente qué plantillas se compusieron, y en qué orden, *antes* de que el primer documento cree un mapeo equivocado que después no podés cambiar sin un reindex.

### 4.4 Index Lifecycle Management

```json
{
  "policy": {
    "_meta": {
      "description": "30 days searchable, 90 days retained, application logs"
    },
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_primary_shard_size": "50gb",
            "max_age": "1d"
          },
          "set_priority": {
            "priority": 100
          }
        }
      },
      "warm": {
        "min_age": "2d",
        "actions": {
          "shrink": {
            "number_of_shards": 1
          },
          "forcemerge": {
            "max_num_segments": 1
          },
          "set_priority": {
            "priority": 50
          }
        }
      },
      "cold": {
        "min_age": "14d",
        "actions": {
          "allocate": {
            "number_of_replicas": 0
          },
          "set_priority": {
            "priority": 0
          }
        }
      },
      "delete": {
        "min_age": "90d",
        "actions": {
          "wait_for_snapshot": {
            "policy": "daily-logs-snapshot"
          },
          "delete": {}
        }
      }
    }
  }
}
```

Mecánicas que vale la pena entender para el examen y para la versión de esto a las 3 de la mañana:

- `min_age` se mide desde el **rollover**, no desde la creación del índice, para cada fase posterior a `hot`.
- ILM revisa las políticas cada `indices.lifecycle.poll_interval` (por defecto **10 minutos**). Un índice no se mueve en el instante en que transcurre `min_age`.
- `forcemerge` a 1 segmento es una operación de E/S pesada y no interrumpible. Hacerla en `warm` (después de que las escrituras se detuvieron) es correcto; hacerla sobre un índice hot es una caída autoinfligida.
- `shrink` requiere que todos los primarios estén en un mismo nodo y que el índice sea primero de solo lectura; ILM se encarga de eso, pero necesita disco libre igual al tamaño del índice.
- `wait_for_snapshot` antes de `delete` es la diferencia entre retención y pérdida de datos.

Verificar un ciclo de vida atascado:

```
$ curl -sS -u elastic:$ES_PASS "https://es01:9200/.ds-logs-nginx.access-prod-*/_ilm/explain?human&pretty" \
  | jq '.indices | to_entries[] | select(.value.step == "ERROR") | {index: .key, action: .value.action, step: .value.step, err: .value.step_info.reason}'
{
  "index": ".ds-logs-nginx.access-prod-2026.09.04-000031",
  "action": "shrink",
  "step": "ERROR",
  "err": "no such index [shrink-fqkz-.ds-logs-nginx.access-prod-2026.09.04-000031]"
}

$ curl -sS -u elastic:$ES_PASS -X POST "https://es01:9200/.ds-logs-nginx.access-prod-2026.09.04-000031/_ilm/retry"
{"acknowledged":true}
```

### 4.5 Una nota sobre `logsdb`

Las versiones recientes de Elasticsearch incluyen un modo de índice especializado para logs:

```json
{
  "template": {
    "settings": {
      "index.mode": "logsdb"
    }
  }
}
```

Habilita `_source` sintético (el documento se reconstruye a partir de los `doc_values` en lugar de almacenarse textualmente) más el ordenamiento por `host.name` y `@timestamp`, lo que mejora drásticamente la compresión — típicamente **2–2,5× más chico en disco**. Las contrapartidas son reales y hay que verificarlas contra la documentación de tu versión antes de adoptarlo: el `_source` reconstruido no es idéntico byte a byte (cambian el orden de los campos y parte del formato), y unos pocos tipos de campo no están soportados. Validá sobre una copia de datos reales antes de cambiar un stream de producción.

---

## 5. Logstash

### 5.1 Mecánica del pipeline

Un pipeline de Logstash es `input → queue → N worker threads (filter + output) → sink`.

- Los plugins de input corren en sus propios threads y empujan eventos hacia la cola.
- `pipeline.workers` (por defecto = núcleos de CPU) threads worker, cada uno tomando un **lote** de hasta `pipeline.batch.size` eventos (por defecto 125), o lo que se haya acumulado después de `pipeline.batch.delay` ms (por defecto 50).
- **Los filtros y los outputs se ejecutan en el mismo thread worker.** No hay una etapa de salida separada. Por eso un output que se bloquea (Elasticsearch no disponible) detiene el filtrado, lo que detiene el drenado de la cola, lo que propaga contrapresión al input, que la propaga a Filebeat. Esa cadena es el diseño, y es correcta: la contrapresión le gana a la pérdida de datos.
- El **ordenamiento** de eventos **no se preserva** con más de un worker. `pipeline.ordered: true` fuerza un único worker.

### 5.2 `logstash.yml`

```yaml
node.name: logstash-agg-0
path.data: /var/lib/logstash
path.logs: /var/log/logstash

config.reload.automatic: true
config.reload.interval: 15s

pipeline.workers: 8
pipeline.batch.size: 500
pipeline.batch.delay: 50
pipeline.ordered: auto

queue.type: persisted
path.queue: /var/lib/logstash/queue
queue.max_bytes: 48gb
queue.checkpoint.writes: 1024

dead_letter_queue.enable: true
dead_letter_queue.max_bytes: 4gb
dead_letter_queue.storage_policy: drop_older
path.dead_letter_queue: /var/lib/logstash/dlq

log.level: info
log.format: json

api.http.host: 0.0.0.0
api.http.port: 9600

xpack.monitoring.enabled: false
```

Dos ajustes que deciden si perdés datos:

- **`queue.type: persisted`** escribe cada evento a disco antes de confirmarle al input. El costo es real (fsync por checkpoint) pero `queue.checkpoint.writes: 1024` lo amortiza. Con la cola `memory` por defecto, un reinicio de Logstash descarta todo lo que está en vuelo — hasta `pipeline.workers × pipeline.batch.size` eventos más la cola en memoria.
- **`dead_letter_queue.enable: true`** captura los documentos que Elasticsearch rechazó con HTTP 400 o 404 — abrumadoramente **conflictos de mapeo**. Sin una DLQ, esos eventos se esfuman con una línea de log y nadie se entera. Con ella, podés volver a leerlos y ver exactamente qué campo se rompió.

### 5.3 `pipelines.yml` — múltiples pipelines

```yaml
- pipeline.id: beats-ingress
  path.config: "/etc/logstash/conf.d/00-beats-input.conf"
  pipeline.workers: 4
  queue.type: persisted
  queue.max_bytes: 16gb

- pipeline.id: nginx
  path.config: "/etc/logstash/conf.d/10-nginx.conf"
  pipeline.workers: 8
  queue.type: persisted
  queue.max_bytes: 24gb

- pipeline.id: kubernetes-json
  path.config: "/etc/logstash/conf.d/20-k8s-json.conf"
  pipeline.workers: 8
  queue.type: persisted
  queue.max_bytes: 24gb

- pipeline.id: dlq-recovery
  path.config: "/etc/logstash/conf.d/90-dlq.conf"
  pipeline.workers: 1
  queue.type: memory
```

Pipelines separados te dan **aislamiento por inquilino**: un patrón grok que empieza a hacer backtracking en el pipeline de nginx no deja sin workers al pipeline de Kubernetes, y las dos colas se llenan de forma independiente.

### 5.4 El patrón pipeline-a-pipeline

`00-beats-input.conf` — un listener TLS, ruteado por un distribuidor:

```
input {
  beats {
    port => 5044
    ssl_enabled => true
    ssl_certificate => "/etc/logstash/certs/logstash.crt"
    ssl_key => "/etc/logstash/certs/logstash.pkcs8.key"
    ssl_certificate_authorities => ["/etc/logstash/certs/ca.crt"]
    ssl_client_authentication => "required"
    client_inactivity_timeout => 120
  }
}

output {
  if [event][dataset] == "nginx.access" {
    pipeline { send_to => ["nginx"] }
  } else if [kubernetes][namespace] {
    pipeline { send_to => ["kubernetes-json"] }
  } else {
    pipeline { send_to => ["fallback"] }
  }
}
```

`10-nginx.conf` — el parseo completo:

```
input {
  pipeline { address => "nginx" }
}

filter {
  # 1. Fixed-delimiter fast path. dissect is ~5-10x cheaper than grok
  #    because it does no regex backtracking at all.
  dissect {
    mapping => {
      "message" => '%{[source][address]} - %{[user][name]} [%{[nginx][ts]}] "%{[http][request][method]} %{[url][original]} HTTP/%{[http][version]}" %{[http][response][status_code]} %{[http][response][body][bytes]} "%{[http][request][referrer]}" "%{[user_agent][original]}" %{[nginx][request_time]}'
    }
    tag_on_failure => ["_dissectfailure"]
  }

  # 2. Only fall back to grok for lines dissect could not split.
  if "_dissectfailure" in [tags] {
    grok {
      match => {
        "message" => [
          "^%{IPORHOST:[source][address]} - %{DATA:[user][name]} \[%{HTTPDATE:[nginx][ts]}\] \"%{WORD:[http][request][method]} %{DATA:[url][original]} HTTP/%{NUMBER:[http][version]}\" %{NUMBER:[http][response][status_code]:int} %{NUMBER:[http][response][body][bytes]:int}",
          "^%{IPORHOST:[source][address]} %{GREEDYDATA:[error][message]}$"
        ]
      }
      timeout_millis => 5000
      timeout_scope  => "event"
      tag_on_failure => ["_grokparsefailure"]
      tag_on_timeout => ["_groktimeout"]
      overwrite      => ["message"]
    }
  }

  # 3. Canonical timestamp. Without this @timestamp is INGEST time,
  #    and every dashboard silently lies during a backlog drain.
  date {
    match  => ["[nginx][ts]", "dd/MMM/yyyy:HH:mm:ss Z", "ISO8601"]
    target => "@timestamp"
    timezone => "UTC"
    tag_on_failure => ["_dateparsefailure"]
  }

  mutate {
    convert => {
      "[http][response][status_code]" => "integer"
      "[http][response][body][bytes]" => "integer"
      "[nginx][request_time]"         => "float"
    }
    # ECS event.duration is nanoseconds
    remove_field => ["[nginx][ts]"]
    gsub => ["[user][name]", "^-$", ""]
  }

  ruby {
    code => 'rt = event.get("[nginx][request_time]"); event.set("[event][duration]", (rt * 1_000_000_000).to_i) unless rt.nil?'
  }

  # 4. Split the URL so url.path is a low-cardinality keyword
  #    and the query string does not blow up the mapping.
  grok {
    match => { "[url][original]" => "^%{URIPATH:[url][path]}(?:\?%{NOTSPACE:[url][query]})?$" }
    tag_on_failure => []
  }

  useragent {
    source => "[user_agent][original]"
    target => "[user_agent]"
  }

  geoip {
    source => "[source][address]"
    target => "[source][geo]"
    fields => ["city_name", "country_iso_code", "location"]
    tag_on_failure => []
  }

  # 5. Redact before storage. Non-negotiable for anything user-supplied.
  mutate {
    gsub => [
      "[url][query]", "(?i)(token|api_key|password|authorization)=[^&]*", "\\1=[REDACTED]",
      "message",      "\\b(?:\\d[ -]*?){13,16}\\b",                       "[REDACTED-PAN]"
    ]
  }

  # 6. Deterministic _id => at-least-once delivery becomes
  #    effectively-once. A replayed batch overwrites instead of duplicating.
  fingerprint {
    source => ["[host][name]", "[log][file][path]", "[log][offset]"]
    target => "[@metadata][fp]"
    method => "SHA256"
    concatenate_sources => true
  }

  mutate {
    add_field => { "[event][dataset]" => "nginx.access" }
    add_field => { "[event][module]"  => "nginx" }
  }
}

output {
  if "_grokparsefailure" in [tags] or "_groktimeout" in [tags] {
    file {
      path => "/var/log/logstash/unparsed-nginx-%{+YYYY.MM.dd}.log"
      codec => line { format => "%{message}" }
    }
  }

  elasticsearch {
    hosts       => ["https://es01:9200", "https://es02:9200", "https://es03:9200"]
    data_stream => true
    data_stream_type      => "logs"
    data_stream_dataset   => "nginx.access"
    data_stream_namespace => "prod"
    document_id => "%{[@metadata][fp]}"
    api_key     => "${ES_API_KEY}"
    ssl_enabled => true
    ssl_certificate_authorities => ["/etc/logstash/certs/ca.crt"]
    retry_on_conflict => 0
    action  => "create"
    compression_level => 3
  }
}
```

**El output a archivo de `_grokparsefailure` es la parte que la gente se saltea y después lamenta.** Un patrón que falla en silencio sobre el 4 % de las líneas produce un dashboard que está calladamente un 4 % equivocado. Escribir las líneas no parseadas a un archivo hace que la tasa de fallo sea *contable*.

### 5.5 Comparación de parsers

| Filtro | Costo por evento | Cuándo usarlo | Modo de fallo |
|---|---|---|---|
| `json` | Muy bajo | La app emite JSON Lines | `_jsonparsefailure`; explosión de profundidad de anidamiento |
| `dissect` | Muy bajo (sin regex) | Delimitadores fijos, cantidad de campos conocida | Silenciosamente equivocado si el formato varía |
| `kv` | Bajo | logfmt, pares `k=v` | Conjunto de claves ilimitado → explosión de mapeo; siempre poné `include_keys` |
| `csv` | Bajo | Logs de acceso con una lista de columnas estable | Comas embebidas |
| `grok` | **Alto** | Texto genuinamente irregular | Backtracking catastrófico; timeouts; `_grokparsefailure` |
| `ruby` | Medio | Lógica que ningún filtro expresa | Ilimitado — un bug acá bloquea un thread worker |

Reglas de grok que evitan el caso patológico:

1. **Anclá.** `^...$`. Un patrón sin anclar hace que el motor reintente en cada offset de una línea de 4 KB.
2. **Nunca encadenes `%{GREEDYDATA}`.** Dos patrones greedy en una misma expresión es backtracking exponencial. Usá `%{DATA}` (lazy) en el medio, y `%{GREEDYDATA}` solo al final.
3. **Ordená las alternativas de la más específica a la menos**, porque `break_on_match => true` se detiene en la primera coincidencia.
4. **Siempre configurá `timeout_millis`.** Sin eso, una sola línea de log adversaria ocupa un thread worker indefinidamente.
5. **Preferí `dissect` y recurrí a grok solo sobre el residuo**, como en la configuración de arriba.

Los patrones personalizados viven en un directorio al que apuntás con `patterns_dir`:

```
# /etc/logstash/patterns/app.grok
APP_LEVEL     (?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)
APP_THREAD    [\w\-\.#]+
APP_LOGGER    [\w\.$]+
APP_LINE      ^%{TIMESTAMP_ISO8601:[event][created]}\s+%{APP_LEVEL:[log][level]}\s+\[%{APP_THREAD:[process][thread][name]}\]\s+%{APP_LOGGER:[log][logger]}\s+-\s+%{GREEDYDATA:message}$
```

### 5.6 La dead letter queue, releída

```
input {
  dead_letter_queue {
    path => "/var/lib/logstash/dlq"
    pipeline_id => "nginx"
    commit_offsets => true
  }
}

filter {
  mutate {
    add_field => {
      "[dlq][reason]" => "%{[@metadata][dead_letter_queue][reason]}"
      "[dlq][origin]" => "%{[@metadata][dead_letter_queue][plugin_id]}"
      "[dlq][at]"     => "%{[@metadata][dead_letter_queue][entry_time]}"
    }
  }
  # Most common cause: a field that should be keyword arrived as an object.
  mutate {
    remove_field => ["[labels]"]
  }
}

output {
  elasticsearch {
    hosts => ["https://es01:9200"]
    index => "logs-dlq-recovered"
    api_key => "${ES_API_KEY}"
    ssl_enabled => true
  }
}
```

---

## 6. Filebeat

### 6.1 `filebeat.yml` autónomo

```yaml
filebeat.inputs:
  - type: filestream
    id: nginx-access
    enabled: true
    paths:
      - /var/log/nginx/access.log
    fields:
      event.dataset: nginx.access
      service.name: edge-nginx
    fields_under_root: true
    prospector:
      scanner:
        check_interval: 10s
        fingerprint:
          enabled: true
          offset: 0
          length: 1024
    file_identity:
      fingerprint: ~
    close:
      on_state_change:
        inactive: 5m
        renamed: true
        removed: true
    clean_removed: true
    ignore_older: 72h

  - type: filestream
    id: app-json
    paths:
      - /var/log/app/*.json
    parsers:
      - ndjson:
          target: ""
          overwrite_keys: true
          add_error_key: true
          expand_keys: true

  - type: journald
    id: systemd-units
    include_matches:
      - "_SYSTEMD_UNIT=sshd.service"
      - "_SYSTEMD_UNIT=kubelet.service"
      - "_SYSTEMD_UNIT=containerd.service"

processors:
  - add_host_metadata:
      netinfo.enabled: true
  - add_cloud_metadata: ~
  - add_fields:
      target: ""
      fields:
        service.environment: production
        organization.name: platform
  - drop_event:
      when:
        regexp:
          message: '^127\.0\.0\.1 .* "GET /healthz '
  - rename:
      fields:
        - from: "agent.hostname"
          to: "host.name"
      ignore_missing: true

queue.disk:
  max_size: 4GB
  path: /var/lib/filebeat/diskqueue
  segment_size: 128MB

output.logstash:
  hosts: ["logstash-agg-0.logging:5044", "logstash-agg-1.logging:5044"]
  loadbalance: true
  worker: 2
  bulk_max_size: 2048
  slow_start: true
  ttl: 60s
  compression_level: 3
  ssl.enabled: true
  ssl.certificate_authorities: ["/etc/filebeat/certs/ca.crt"]
  ssl.certificate: "/etc/filebeat/certs/filebeat.crt"
  ssl.key: "/etc/filebeat/certs/filebeat.key"
  ssl.verification_mode: full

http.enabled: true
http.host: 0.0.0.0
http.port: 5066

logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
  permissions: "0640"
```

Cuatro detalles que separan un despliegue funcionando de un incidente de pérdida de datos:

- **`file_identity: fingerprint`.** El valor por defecto heredado identificaba los archivos por inodo + dispositivo. En sistemas que reutilizan inodos de manera agresiva —o cuando un log se rota con `copytruncate`— la identidad por inodo causa tanto la relectura de un archivo completo (duplicados) como el salteo de un archivo nuevo (pérdida). Tomar la huella de los primeros 1024 bytes es lo correcto. Cambiar `file_identity` en un despliegue existente **invalida el registry**, así que planificá una relectura única o un reseteo del registry.
- **`queue.disk`** le da a Filebeat un buffer real, independiente de la retención propia del archivo de log.
- **`ttl: 60s`** en el output de Logstash fuerza reconexiones periódicas, que es la forma de conseguir rebalanceo cuando una réplica de Logstash vuelve. Sin eso, las conexiones quedan clavadas para siempre en las sobrevivientes.
- **`ignore_older` debe ser mayor que tu ventana de rotación**, o un archivo que queda en silencio durante un fin de semana nunca se va a retomar.

### 6.2 Interacción con `logrotate`

```
# /etc/logrotate.d/nginx
/var/log/nginx/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 $(cat /run/nginx.pid)
    endscript
}
```

`create` + señal (el reopen con `USR1` de nginx) es el patrón seguro: el inodo viejo queda abierto hasta que el harvester lo termina. **`copytruncate` es el peligroso** — trunca el archivo en el lugar mientras el harvester mantiene un offset más allá del nuevo EOF, lo que pierde todo lo escrito entre la copia y el truncado. `delaycompress` también importa: comprimir en la misma rotación puede gzipear un archivo que el harvester no terminó de leer.

---

## 7. Arquitectura de logging en Kubernetes

En cada nodo, el kubelet escribe el stdout/stderr de los contenedores a `/var/log/pods/<ns>_<pod>_<uid>/<container>/<n>.log`, con symlinks en `/var/log/containers/<pod>_<ns>_<container>-<id>.log`. **El kubelet realiza la rotación**, controlada por:

```yaml
containerLogMaxSize: 50Mi
containerLogMaxFiles: 5
```

Los valores por defecto son `10Mi` / `5` — eso es **50 MiB de buffer por contenedor**. Un pod que loguea 20 MB/s tiene ~2,5 segundos de margen antes de que se borre el archivo más viejo. Si tu colector está caído más tiempo que eso, los datos se perdieron sin importar ningún buffer aguas abajo. Este es el número más importante en la planificación de capacidad de logging en Kubernetes, y se configura en el kubelet, no en el colector.

### 7.1 Patrones de recolección

| Patrón | Pods por nodo | Aislamiento | Maneja logs que no van a stdout | Costo |
|---|---|---|---|---|
| **Agente de nodo (DaemonSet)** | 1 | Compartido; un namespace ruidoso puede dejar sin recursos a los demás | No (salvo que monte un emptyDir) | El más bajo |
| **Sidecar por pod** | N | Por workload | Sí | Alto (1 contenedor por pod) |
| **La aplicación empuja directamente** | 0 | Por workload | Sí | Sin buffer a nivel de nodo; la app se bloquea si el endpoint está caído |

El DaemonSet es el valor por defecto y la respuesta correcta para ~95 % de las plataformas. Usá un sidecar solo cuando una aplicación escribe a un archivo que se niega a enviar también a stdout, y nunca dejes que una aplicación empuje directamente al almacén — perdés el buffer del nodo y acoplás la disponibilidad de la aplicación al backend de logging.

### 7.2 DaemonSet de Filebeat completo

**Namespace**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: logging
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

**ServiceAccount**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: filebeat
  namespace: logging
```

**ClusterRole**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: filebeat
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "nodes"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "watch", "list"]
```

**ClusterRoleBinding**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: filebeat
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: filebeat
subjects:
  - kind: ServiceAccount
    name: filebeat
    namespace: logging
```

**ConfigMap**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: filebeat-config
  namespace: logging
data:
  filebeat.yml: |
    filebeat.inputs:
      - type: filestream
        id: kubernetes-container-logs
        paths:
          - /var/log/containers/*.log
        parsers:
          - container:
              stream: all
              format: cri
          - multiline:
              type: pattern
              pattern: '^[[:space:]]+(at|\.{3})[[:space:]]+\b|^Caused by:|^[[:space:]]*Suppressed:'
              negate: false
              match: after
              max_lines: 500
              timeout: 5s
        prospector:
          scanner:
            symlinks: true
            check_interval: 10s
            fingerprint:
              enabled: true
              offset: 0
              length: 1024
        file_identity:
          fingerprint: ~
        close:
          on_state_change:
            inactive: 5m
            removed: true
        clean_removed: true

    processors:
      - add_kubernetes_metadata:
          host: ${NODE_NAME}
          default_indexers.enabled: true
          default_matchers.enabled: false
          matchers:
            - logs_path:
                logs_path: /var/log/containers/
          labels.dedot: true
          annotations.dedot: true
      - drop_event:
          when:
            or:
              - equals:
                  kubernetes.namespace: kube-system
              - contains:
                  message: /healthz
      - decode_json_fields:
          fields: ["message"]
          target: ""
          overwrite_keys: true
          add_error_key: true
          max_depth: 2
          process_array: false
      - add_fields:
          target: ""
          fields:
            orchestrator.cluster.name: leloir-prod

    queue.disk:
      max_size: 2GB
      path: /var/lib/filebeat/diskqueue

    output.logstash:
      hosts: ["logstash.logging.svc.cluster.local:5044"]
      loadbalance: true
      worker: 2
      bulk_max_size: 2048
      ttl: 60s
      compression_level: 3
      ssl.enabled: true
      ssl.certificate_authorities: ["/etc/filebeat/certs/ca.crt"]

    http.enabled: true
    http.host: 0.0.0.0
    http.port: 5066

    logging.level: info
    logging.to_stderr: true
```

**DaemonSet**

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: filebeat
  namespace: logging
  labels:
    app.kubernetes.io/name: filebeat
    app.kubernetes.io/component: log-shipper
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: filebeat
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: filebeat
      annotations:
        checksum/config: "replace-with-configmap-hash"
    spec:
      serviceAccountName: filebeat
      terminationGracePeriodSeconds: 30
      hostNetwork: false
      dnsPolicy: ClusterFirst
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: filebeat
          image: docker.elastic.co/beats/filebeat:8.15.2
          args:
            - "-e"
            - "-c"
            - "/etc/filebeat.yml"
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          securityContext:
            runAsUser: 0
            privileged: false
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]
          resources:
            requests:
              cpu: 100m
              memory: 200Mi
            limits:
              cpu: "1"
              memory: 600Mi
          livenessProbe:
            httpGet:
              path: /stats
              port: 5066
            initialDelaySeconds: 30
            periodSeconds: 20
            timeoutSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/filebeat.yml
              subPath: filebeat.yml
              readOnly: true
            - name: certs
              mountPath: /etc/filebeat/certs
              readOnly: true
            - name: data
              mountPath: /usr/share/filebeat/data
            - name: diskqueue
              mountPath: /var/lib/filebeat/diskqueue
            - name: varlogcontainers
              mountPath: /var/log/containers
              readOnly: true
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          configMap:
            name: filebeat-config
            defaultMode: 0640
        - name: certs
          secret:
            secretName: logging-ca
        - name: data
          hostPath:
            path: /var/lib/filebeat-data
            type: DirectoryOrCreate
        - name: diskqueue
          hostPath:
            path: /var/lib/filebeat-queue
            type: DirectoryOrCreate
        - name: varlogcontainers
          hostPath:
            path: /var/log/containers
        - name: varlogpods
          hostPath:
            path: /var/log/pods
        - name: tmp
          emptyDir: {}
```

El volumen `data` es un `hostPath`, no un `emptyDir`, a propósito: el registry que guarda los offsets de lectura tiene que sobrevivir al reinicio del pod. Con `emptyDir`, cada reinicio de Filebeat relee todos los archivos desde el principio y obtenés una tormenta de duplicados.

`/var/log/pods` debe montarse junto con `/var/log/containers` porque este último es solo un directorio de symlinks que apuntan al primero.

### 7.3 Logstash como StatefulSet

Una cola persistente requiere almacenamiento estable y durable por réplica — eso significa un StatefulSet con `volumeClaimTemplates`, nunca un Deployment.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: logstash
  namespace: logging
spec:
  serviceName: logstash
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app.kubernetes.io/name: logstash
  template:
    metadata:
      labels:
        app.kubernetes.io/name: logstash
    spec:
      terminationGracePeriodSeconds: 180
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsNonRoot: true
      containers:
        - name: logstash
          image: docker.elastic.co/logstash/logstash:8.15.2
          env:
            - name: LS_JAVA_OPTS
              value: "-Xms2g -Xmx2g"
            - name: ES_API_KEY
              valueFrom:
                secretKeyRef:
                  name: logstash-es-credentials
                  key: api_key
          ports:
            - name: beats
              containerPort: 5044
            - name: api
              containerPort: 9600
          resources:
            requests:
              cpu: "2"
              memory: 3Gi
            limits:
              cpu: "4"
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /_node/pipelines
              port: 9600
            initialDelaySeconds: 60
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 9600
            initialDelaySeconds: 120
            periodSeconds: 30
            failureThreshold: 5
          volumeMounts:
            - name: pipeline
              mountPath: /usr/share/logstash/pipeline
            - name: config
              mountPath: /usr/share/logstash/config/logstash.yml
              subPath: logstash.yml
            - name: config
              mountPath: /usr/share/logstash/config/pipelines.yml
              subPath: pipelines.yml
            - name: certs
              mountPath: /etc/logstash/certs
              readOnly: true
            - name: queue
              mountPath: /usr/share/logstash/data
      volumes:
        - name: pipeline
          configMap:
            name: logstash-pipeline
        - name: config
          configMap:
            name: logstash-config
        - name: certs
          secret:
            secretName: logstash-certs
  volumeClaimTemplates:
    - metadata:
        name: queue
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 64Gi
```

`terminationGracePeriodSeconds: 180` le da a Logstash tiempo para drenar sus lotes en vuelo al recibir SIGTERM. Los 30 s por defecto truncan el drenado y los eventos restantes se recuperan de la cola persistente al reiniciar — lo que solo funciona porque la cola está en un PVC.

---

## 8. Kibana y lenguajes de consulta

### 8.1 `kibana.yml`

```yaml
server.name: kibana-prod
server.host: 0.0.0.0
server.port: 5601
server.publicBaseUrl: "https://kibana.internal.example.com"

elasticsearch.hosts: ["https://es01:9200", "https://es02:9200", "https://es03:9200"]
elasticsearch.serviceAccountToken: "${KIBANA_SERVICE_TOKEN}"
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/certs/ca.crt"]
elasticsearch.ssl.verificationMode: full
elasticsearch.requestTimeout: 60000

server.ssl.enabled: true
server.ssl.certificate: /etc/kibana/certs/kibana.crt
server.ssl.key: /etc/kibana/certs/kibana.key

xpack.encryptedSavedObjects.encryptionKey: "${KIBANA_ENCRYPTION_KEY}"
xpack.reporting.encryptionKey: "${KIBANA_REPORTING_KEY}"
xpack.security.encryptionKey: "${KIBANA_SECURITY_KEY}"

xpack.security.session.idleTimeout: "1h"
xpack.security.session.lifespan: "24h"

logging.appenders.file.type: file
logging.appenders.file.fileName: /var/log/kibana/kibana.log
logging.appenders.file.layout.type: json
logging.root.level: info

monitoring.ui.ccs.enabled: false
```

Los tres valores de `encryptionKey` deben ser **idénticos en todas las instancias de Kibana** y estables entre reinicios, o los saved objects, las reglas de alerta y los trabajos de reporting se vuelven indescifrables. Generarlos en tiempo de despliegue con una función aleatoria es una caída autoinfligida recurrente.

### 8.2 Lenguajes de consulta

| | **KQL** | **Lucene** | **ES|QL** | **Query DSL** |
|---|---|---|---|---|
| Dónde | Barra de búsqueda de Kibana (por defecto) | Barra de búsqueda de Kibana (conmutable) | Discover / API | API, reglas de alerta |
| Comodines en los valores | Sí (`service.name: check*`) | Sí | `LIKE` / `RLIKE` | consulta `wildcard` |
| Regex | No | Sí (`/err(or)?/`) | Sí (`RLIKE`) | consulta `regexp` |
| Rangos | `bytes > 1000` | `bytes:[1000 TO *]` | `WHERE bytes > 1000` | `range` |
| Agregación | No | No | **Sí** (`STATS`) | Sí |
| Transformación | No | No | **Sí** (`EVAL`, `DISSECT`, `GROK`) | Runtime fields |

Ejemplos prácticos contra un stream con forma ECS:

```
# KQL - the everyday language
service.name : "checkout-api" and http.response.status_code >= 500 and not url.path : "/healthz"

# KQL - existence and nesting
error.stack_trace : * and kubernetes.namespace : ("prod" or "prod-canary")

# Lucene - regex, which KQL cannot do
log.level:(ERROR OR FATAL) AND message:/timeout|refused|reset by peer/

# ES|QL - aggregate without leaving Discover
FROM logs-nginx.access-prod
| WHERE @timestamp > NOW() - 1 hour
| EVAL is_error = http.response.status_code >= 500
| STATS errors = COUNT(*) BY url.path, http.response.status_code
| WHERE errors > 10
| SORT errors DESC
| LIMIT 20

# ES|QL - parse an unparsed field at query time, no reindex
FROM logs-fallback-prod
| GROK message "%{IP:client} - - \\[%{HTTPDATE:ts}\\] \"%{WORD:method} %{URIPATH:path}"
| STATS hits = COUNT(*) BY path
| SORT hits DESC
```

Esa última es la salida de emergencia del arquitecto: **podés recuperar estructura de un campo que no lograste parsear en tiempo de ingesta, sin reindexar**, vía `GROK`/`DISSECT` en ES|QL o vía un runtime field en la data view. Es más lento que un campo indexado (se computa por documento coincidente) pero convierte un reindex de seis horas en una consulta.

El LogQL equivalente, si el almacén es Loki:

```
{namespace="prod", app="checkout-api"} |= "error" | json | status_code >= 500 | line_format "{{.trace_id}} {{.message}}"

sum by (status_code) (
  rate({namespace="prod", app="checkout-api"} | json | __error__="" [5m])
)
```

La diferencia estructural se ve en el primer selector: Loki *requiere* un matcher de label, y los labels son lo único indexado. `{namespace="prod"}` es barato; no hay forma de preguntar "encontrá este string en cualquier parte del clúster" sin escanear.

---

## 9. Verificación y diagnóstico de fallos

### 9.1 Validá antes de desplegar

```
$ logstash --path.settings /etc/logstash -f /etc/logstash/conf.d/10-nginx.conf --config.test_and_exit
Using bundled JDK: /usr/share/logstash/jdk
[2026-09-18T09:41:12,338][INFO ][logstash.runner] Log4j configuration path used is: /etc/logstash/log4j2.properties
[2026-09-18T09:41:12,349][INFO ][logstash.runner] Starting Logstash {"logstash.version"=>"8.15.2", "jruby.version"=>"jruby 9.4.8.0"}
Configuration OK
[2026-09-18T09:41:18,002][INFO ][logstash.runner] Using config.test_and_exit mode. Config Validation Result: OK. Exiting Logstash
```

```
$ filebeat test config -c /etc/filebeat/filebeat.yml
Config OK

$ filebeat test output -c /etc/filebeat/filebeat.yml
logstash: logstash-agg-0.logging:5044...
  connection...
    parse host... OK
    dns lookup... OK
    addresses: 10.96.41.18
    dial up... OK
  TLS...
    security: server's certificate chain verification is enabled
    handshake... OK
    TLS version: TLSv1.3
    dial up... OK
  talk to server... OK
```

Ejercitá un patrón de punta a punta sin tocar el clúster:

```
$ echo '10.0.4.19 - - [18/Sep/2026:09:44:02 +0000] "POST /api/v1/orders HTTP/1.1" 503 197 "-" "curl/8.5.0" 4.102' \
  | logstash -f /etc/logstash/conf.d/10-nginx.conf \
      --config.string 'input { stdin {} } output { stdout { codec => rubydebug } }' 2>/dev/null
{
        "@timestamp" => 2026-09-18T09:44:02.000Z,
            "source" => { "address" => "10.0.4.19" },
              "http" => {
            "request" => { "method" => "POST" },
           "response" => { "status_code" => 503, "body" => { "bytes" => 197 } },
            "version" => "1.1"
    },
               "url" => { "original" => "/api/v1/orders", "path" => "/api/v1/orders" },
             "event" => { "duration" => 4102000000, "dataset" => "nginx.access" },
        "user_agent" => { "original" => "curl/8.5.0", "name" => "curl", "version" => "8.5.0" }
}
```

### 9.2 ¿Está fluyendo el pipeline?

```
$ curl -sS localhost:9600/_node/stats/pipelines?pretty | jq '.pipelines | to_entries[] | {id: .key, in: .value.events.in, out: .value.events.out, filtered: .value.events.filtered, queue_events: .value.queue.events, queue_bytes: .value.queue.queue_size_in_bytes}'
{
  "id": "nginx",
  "in": 48213991,
  "out": 48213412,
  "filtered": 48213412,
  "queue_events": 579,
  "queue_bytes": 1284119
}
{
  "id": "kubernetes-json",
  "in": 191044822,
  "out": 174009331,
  "filtered": 174009331,
  "queue_events": 17035491,
  "queue_bytes": 19314772480
}
```

`kubernetes-json` tiene **17 millones de eventos sentados en la cola y 19 GB en disco**: `in` corre bastante por delante de `out`. Esa es la firma de un atasco aguas abajo — la cola persistente está haciendo su trabajo, y tenés `queue.max_bytes / tasa de crecimiento actual` antes de que la contrapresión llegue a Filebeat.

Encontrá *cuál* plugin es el cuello de botella:

```
$ curl -sS localhost:9600/_node/stats/pipelines/kubernetes-json?pretty \
  | jq '.pipelines["kubernetes-json"].plugins.filters[] | {id, events_out: .events.out, ms: .events.duration_in_millis}' \
  | jq -s 'sort_by(-.ms) | .[0:3]'
[
  { "id": "grok_fallback",   "events_out": 8112004,   "ms": 4410882 },
  { "id": "json_container",  "events_out": 174009331, "ms": 318844 },
  { "id": "date_normalize",  "events_out": 174009331, "ms": 91277 }
]
```

`grok_fallback` procesó el 4,7 % de los eventos y quemó el 91 % del tiempo de filtrado — 0,54 ms por evento contra 0,0018 ms del parser JSON. Ese es el hallazgo real, y el arreglo es un camino rápido con `dissect` o descartar el stream imparseable, no más CPU.

### 9.3 Salud del clúster y de los índices

```
$ curl -sS -u elastic:$ES_PASS "https://es01:9200/_cluster/health?pretty"
{
  "cluster_name" : "logs-prod",
  "status" : "yellow",
  "timed_out" : false,
  "number_of_nodes" : 9,
  "number_of_data_nodes" : 6,
  "active_primary_shards" : 812,
  "active_shards" : 1571,
  "relocating_shards" : 0,
  "initializing_shards" : 2,
  "unassigned_shards" : 51,
  "delayed_unassigned_shards" : 0,
  "number_of_pending_tasks" : 0,
  "active_shards_percent_as_number" : 96.73
}

$ curl -sS -u elastic:$ES_PASS "https://es01:9200/_cat/indices/.ds-logs-*?v&s=store.size:desc&h=health,status,index,pri,rep,docs.count,store.size,pri.store.size" | head -6
health status index                                              pri rep docs.count store.size pri.store.size
yellow open   .ds-logs-kubernetes.container_logs-prod-2026.09.18-000714   6   1  418201773    1.1tb        612.4gb
green  open   .ds-logs-nginx.access-prod-2026.09.18-000042               6   1  184203112  412.7gb        206.3gb
green  open   .ds-logs-nginx.access-prod-2026.09.17-000041               6   1  179884120  401.9gb        201.0gb
green  open   .ds-logs-app.json-prod-2026.09.18-000188                   3   1   62114882  118.2gb         59.1gb

$ curl -sS -u elastic:$ES_PASS "https://es01:9200/_cat/allocation?v&h=shards,disk.indices,disk.used,disk.avail,disk.percent,node"
shards disk.indices disk.used disk.avail disk.percent node
   271        2.7tb     2.9tb      612gb           83 es-hot-0
   268        2.7tb     2.9tb      598gb           83 es-hot-1
   274        2.8tb     3.0tb      501gb           86 es-hot-2
   253        1.9tb     2.0tb      4.1tb           33 es-warm-0

$ curl -sS -u elastic:$ES_PASS "https://es01:9200/_cluster/allocation/explain?pretty" \
  | jq '{index, shard, primary, reason: .can_allocate, note: .allocate_explanation}'
{
  "index": ".ds-logs-kubernetes.container_logs-prod-2026.09.18-000714",
  "shard": 4,
  "primary": false,
  "reason": "no",
  "note": "Elasticsearch isn't allowed to allocate this shard to any of the nodes in the cluster. Choose a node to which you expect this shard to be allocated, find this node in the node-by-node explanation, and address the reasons which prevent Elasticsearch from allocating this shard there."
}
```

`_cluster/allocation/explain` es la respuesta canónica a "por qué está amarillo mi clúster". Nombra el shard y el motivo por nodo; nunca hace falta adivinar.

### 9.4 Confirmá que los datos son realmente correctos

Que la salud esté en verde y los eventos fluyan no significa que los datos estén bien. Dos chequeos atrapan la mayor parte de la corrupción silenciosa:

**Retraso de ingesta** — la brecha entre cuándo ocurrió el evento y cuándo fue indexado:

```
$ curl -sS -u elastic:$ES_PASS -X POST "https://es01:9200/logs-nginx.access-prod/_search?pretty" \
  -H 'Content-Type: application/json' -d @- <<'EOF'
{
  "size": 0,
  "runtime_mappings": {
    "ingest_lag_ms": {
      "type": "long",
      "script": {
        "source": "emit(doc['event.ingested'].value.toInstant().toEpochMilli() - doc['@timestamp'].value.toInstant().toEpochMilli())"
      }
    }
  },
  "aggs": {
    "lag": {
      "percentiles": {
        "field": "ingest_lag_ms",
        "percents": [50, 95, 99]
      }
    }
  }
}
EOF
{
  "took" : 1842,
  "aggregations" : {
    "lag" : {
      "values" : {
        "50.0" : 3104.0,
        "95.0" : 19883.0,
        "99.0" : 412094.0
      }
    }
  }
}
```

Un p50 de 3 s es sano; un p99 de 412 s dice que ~1 % de los eventos llega con casi siete minutos de retraso — un shipper parcialmente atascado en alguna parte. Los valores negativos significarían **desfase de reloj**, que es peor: pone los eventos en el futuro y desaparecen de cualquier dashboard de "los últimos 15 minutos".

**Tasa de fallos de parseo** — el número que te dice si tus dashboards están mintiendo:

```
$ curl -sS -u elastic:$ES_PASS -X POST "https://es01:9200/logs-*/_search?pretty" \
  -H 'Content-Type: application/json' -d '{
    "size": 0,
    "query": { "range": { "@timestamp": { "gte": "now-1h" } } },
    "aggs": { "by_tag": { "terms": { "field": "tags", "size": 10 } } }
  }'
{
  "hits" : { "total" : { "value" : 10000, "relation" : "gte" } },
  "aggregations" : {
    "by_tag" : {
      "buckets" : [
        { "key" : "beats_input_codec_plain_applied", "doc_count" : 41882301 },
        { "key" : "_grokparsefailure",               "doc_count" : 1904772 },
        { "key" : "_dateparsefailure",               "doc_count" : 88104 },
        { "key" : "_groktimeout",                    "doc_count" : 311 }
      ]
    }
  }
}
```

4,5 % de `_grokparsefailure`. Alertá sobre esta proporción. Es la única métrica que atrapa "el proveedor cambió su formato de log en una release menor".

### 9.5 Manual de fallos

| Síntoma | Causa probable | Diagnóstico | Arreglo |
|---|---|---|---|
| `cluster_block_exception ... read-only-allow-delete` | El disco cruzó el watermark de flood-stage del 95 % | `GET _cat/allocation?v` | Liberar disco / agregar nodos; el bloqueo se libera solo por debajo del watermark alto. Liberación manual: `PUT */_settings {"index.blocks.read_only_allow_delete": null}` |
| Rechazos de bulk, `es_rejected_execution_exception` | Cola del thread-pool de `write` llena — indexando más rápido de lo que el clúster absorbe | `GET _cat/thread_pool/write?v&h=node_name,active,queue,rejected` | Bajá `bulk_max_size`, subí `refresh_interval`, agregá nodos hot. Nunca aumentes el tamaño de la cola — eso cambia rechazos por presión de heap |
| `mapper_parsing_exception: failed to parse field [x] of type [long]` | El campo llegó con un tipo distinto al del mapeo | Leé la DLQ; `GET <index>/_mapping/field/x` | `ignore_malformed: true` en el índice; normalizá el tipo en el filtro; el índice existente no se puede cambiar — el nuevo mapeo aplica en el próximo rollover |
| `Limit of total fields [1000] has been exceeded` | Explosión de mapeo dinámico, normalmente por un objeto `labels` o `params` | `GET <index>/_mapping | jq '[paths] | length'` | Mapeá el subobjeto culpable como `flattened`; subí el límite solo como parche temporal |
| Filebeat relee archivos enteros tras reiniciar | Registry no persistido (`emptyDir`), o `file_identity` cambiado | `ls -l /usr/share/filebeat/data/registry/filebeat/` | Persistí el directorio de datos en un `hostPath`/PVC |
| Documentos duplicados | Reintento at-least-once tras un fallo parcial de bulk | Contá por `_id` | Filtro `fingerprint` + `document_id` en el output de ES; `action => "create"` |
| Hueco en los logs, sin errores en ninguna parte | El kubelet rotó y borró el archivo antes de que fuera leído | `kubectl get --raw /api/v1/nodes/<n>/proxy/configz | jq .kubeletconfig.containerLogMaxSize` | Subí `containerLogMaxSize` / `containerLogMaxFiles`; reducí el volumen de logs en el origen |
| Stack traces partidos en muchos documentos | Sin parser multiline, o el patrón no coincide con este lenguaje | Comparar el conteo de `log.level:*` contra el de `message:"at "` | Agregá/repará el parser `multiline`; preferí logging JSON con `error.stack_trace` como un solo campo |
| Logs truncados en ~16 KiB | Líneas parciales (`P`) de CRI sin reensamblar | Buscá líneas que terminan a mitad de palabra | Usá el parser `container` con `format: cri` |
| Todo con timestamp de tiempo de ingesta | Sin filtro `date`, o el filtro falló | Contá `_dateparsefailure` | Agregá/repará el filtro `date`; notá que RFC 3164 no tiene año ni zona horaria |
| CPU de Logstash clavada, throughput colapsado | Backtracking catastrófico de grok | `duration_in_millis` por plugin desde la API de node-stats | Anclá el patrón, reemplazá `GREEDYDATA` por `DATA`, agregá `timeout_millis`, pasá a `dissect` |
| Kibana: "no results" pero los datos existen | Filtro de tiempo vs relojes desfasados; data view equivocada; privilegio de lectura faltante sobre el patrón de índice | Consultá Elasticsearch directamente con el mismo rango | Arreglá NTP; revisá el campo de tiempo de la data view; revisá los privilegios de índice del rol |
| La fase warm nunca corre | Error de paso de ILM (normalmente `shrink` necesitando disco libre o una asignación colocada) | `GET <idx>/_ilm/explain?human` | Arreglá la causa subyacente, después `POST <idx>/_ilm/retry` |

### 9.6 Alertar sobre el propio pipeline

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: logging-pipeline
  namespace: logging
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: logging.rules
      rules:
        - alert: LogstashQueueBacklogGrowing
          expr: |
            logstash_node_queue_events_count
            > 500000
          for: 10m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Logstash persistent queue backlog above 500k events"
            description: "Ingest is outrunning Elasticsearch. Check bulk rejections and disk watermarks."
            runbook_url: "https://runbooks.internal.example.com/logging/queue-backlog"

        - alert: LogstashQueueNearCapacity
          expr: |
            logstash_node_queue_queue_size_in_bytes
            /
            logstash_node_queue_max_queue_size_in_bytes
            > 0.80
          for: 5m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Logstash queue above 80 percent — backpressure will reach the shippers"
            runbook_url: "https://runbooks.internal.example.com/logging/queue-full"

        - alert: FilebeatPublishFailureRate
          expr: |
            sum(rate(filebeat_libbeat_output_events_failed_total[5m]))
            /
            clamp_min(sum(rate(filebeat_libbeat_output_events_total[5m])), 1)
            > 0.01
          for: 15m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "More than 1 percent of Filebeat publish attempts are failing"

        - alert: LogParseFailureRatio
          expr: |
            sum(rate(logstash_node_plugin_events_out_total{plugin_id="grok_fallback"}[10m]))
            /
            clamp_min(sum(rate(logstash_node_events_in_total[10m])), 1)
            > 0.05
          for: 30m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Over 5 percent of events fall through to the grok fallback path"
            description: "A log format has probably changed upstream. Dashboards built on parsed fields are now incomplete."

        - alert: ElasticsearchFloodStage
          expr: |
            min(elasticsearch_filesystem_data_available_bytes
            /
            elasticsearch_filesystem_data_size_bytes) < 0.07
          for: 5m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "An Elasticsearch data node is approaching the flood-stage watermark"
            description: "At 95 percent used, indices become read-only and ingest stops cluster-wide."
```

La alerta que a la mayoría de los equipos le falta es la anteúltima: **la proporción de fallos de parseo**. Todas las demás avisan cuando los logs se detienen. Esa avisa cuando los logs siguen fluyendo pero dejan de significar lo que tus dashboards asumen.

---

## 10. Seguridad y cumplimiento

- **Transporte.** mTLS en cada salto: Filebeat→Logstash (`ssl_client_authentication => "required"`), Logstash→Elasticsearch, Kibana→Elasticsearch. Un pipeline de logging transporta, por construcción, los strings más sensibles que producen tus sistemas.
- **Autenticación.** Usá **API keys** con los privilegios mínimos, no el superusuario `elastic`. Un shipper necesita `auto_configure`, `create_doc` sobre su propio patrón de data stream y nada más:

```json
{
  "name": "filebeat-nginx-prod",
  "expiration": "90d",
  "role_descriptors": {
    "writer": {
      "cluster": ["monitor"],
      "indices": [
        {
          "names": ["logs-nginx.access-prod"],
          "privileges": ["auto_configure", "create_doc"],
          "allow_restricted_indices": false
        }
      ]
    }
  }
}
```

- **Redacción en el agregador.** Los números de tarjeta, los bearer tokens, los secretos en query strings y cualquier campo que un usuario pueda controlar deben limpiarse antes de que lleguen al almacenamiento persistente. Una vez que un secreto está en un segmento de Lucene, está en cada réplica, cada snapshot y cada backup, y `_update_by_query` no lo saca de los segmentos existentes hasta que ocurre un merge.
- **La retención como restricción legal.** El `delete` de ILM es cómo implementás "no conservamos esto más allá de N días". `wait_for_snapshot` es cómo implementás "y todavía lo podemos producir a pedido". Son requisitos opuestos y los dos suelen estar en el mismo documento de política.
- **El log de auditoría no es un log de aplicación.** El rastro de auditoría propio de Elasticsearch (`xpack.security.audit.enabled`) pertenece a un clúster separado o, como mínimo, a un data stream separado con privilegios separados — de lo contrario, las cuentas que estás auditando también pueden escribir en el registro de auditoría.

---

## 11. Modelo mental para el examen

- **ELK es un pipeline, no un producto.** Los Beats recolectan, Logstash transforma, Elasticsearch indexa, Kibana consulta. Conocé qué componente es dueño de cada verbo.
- **La configuración de Logstash son tres bloques: `input`, `filter`, `output`.** Plugins nombrados en los objetivos: inputs `beats`, `file`, `stdin`; filtros `grok`, `mutate`, `date`, `json`, `dissect`; outputs `elasticsearch`, `stdout`. `/etc/logstash/logstash.yml` son los ajustes; `/etc/logstash/conf.d/*.conf` es el pipeline.
- **`%{SYNTAX:SEMANTIC}`** es la gramática de grok. `%{IP:client}` coincide con una IP y la guarda en el campo `client`. Una coincidencia fallida agrega el tag `_grokparsefailure`.
- **El filtro `date` establece `@timestamp`.** Sin él, `@timestamp` es el tiempo de ingesta.
- **Un index template gobierna los índices creados después de que existe**, nunca los existentes. Los mapeos son inmutables para un campo existente; cambiar uno requiere rollover o reindex.
- **Fases de ILM en orden: hot → warm → cold → frozen → delete**, con `min_age` contado desde el rollover.
- **Un data stream es un alias sobre índices de respaldo rotativos**, de solo anexado, que requiere `@timestamp`.
- **El registry de Filebeat guarda los offsets de lectura.** Perdelo y releés; corrompelo y salteás.
- **Alternativas a nivel de conocimiento general:** Fluentd y Fluent Bit (colectores CNCF, basados en plugins), Loki (labels indexados, cuerpo no), Graylog (Elasticsearch/OpenSearch con su propia UI y reglas de procesamiento), Vector y el OpenTelemetry Collector.

---

## Referencias

**Objetivos del examen**
- LPI — Exam 701 Objectives (DevOps Tools Engineer, v2.0.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI — DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Elasticsearch**
- Elasticsearch Reference: https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html
- Data streams: https://www.elastic.co/guide/en/elasticsearch/reference/current/data-streams.html
- Index templates: https://www.elastic.co/guide/en/elasticsearch/reference/current/index-templates.html
- Mapping: https://www.elastic.co/guide/en/elasticsearch/reference/current/mapping.html
- Index lifecycle management: https://www.elastic.co/guide/en/elasticsearch/reference/current/index-lifecycle-management.html
- Size your shards: https://www.elastic.co/guide/en/elasticsearch/reference/current/size-your-shards.html
- Tune for indexing speed: https://www.elastic.co/guide/en/elasticsearch/reference/current/tune-for-indexing-speed.html
- API `_cat/indices`: https://www.elastic.co/guide/en/elasticsearch/reference/current/cat-indices.html
- Cluster health API: https://www.elastic.co/guide/en/elasticsearch/reference/current/cluster-health.html
- Cluster allocation explain API: https://www.elastic.co/guide/en/elasticsearch/reference/current/cluster-allocation-explain.html
- Create API key API: https://www.elastic.co/guide/en/elasticsearch/reference/current/security-api-create-api-key.html

**Logstash**
- Logstash Reference: https://www.elastic.co/guide/en/logstash/current/index.html
- Cómo funciona Logstash (ejecución del pipeline): https://www.elastic.co/guide/en/logstash/current/pipeline.html
- Archivo de configuración (`logstash.yml`): https://www.elastic.co/guide/en/logstash/current/logstash-settings-file.html
- Múltiples pipelines (`pipelines.yml`): https://www.elastic.co/guide/en/logstash/current/multiple-pipelines.html
- Colas persistentes: https://www.elastic.co/guide/en/logstash/current/persistent-queues.html
- Dead letter queues: https://www.elastic.co/guide/en/logstash/current/dead-letter-queues.html
- Plugin de filtro `grok`: https://www.elastic.co/guide/en/logstash/current/plugins-filters-grok.html
- Plugin de filtro `dissect`: https://www.elastic.co/guide/en/logstash/current/plugins-filters-dissect.html
- Plugin de filtro `date`: https://www.elastic.co/guide/en/logstash/current/plugins-filters-date.html
- Plugin de filtro `mutate`: https://www.elastic.co/guide/en/logstash/current/plugins-filters-mutate.html
- Plugin de salida `elasticsearch`: https://www.elastic.co/guide/en/logstash/current/plugins-outputs-elasticsearch.html
- Node stats API: https://www.elastic.co/guide/en/logstash/current/node-stats-api.html
- Biblioteca de patrones grok del núcleo (fuente): https://github.com/logstash-plugins/logstash-patterns-core

**Beats**
- Filebeat Reference: https://www.elastic.co/guide/en/beats/filebeat/current/index.html
- Input `filestream`: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-filestream.html
- Input `journald`: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-journald.html
- Ejecutar Filebeat en Kubernetes: https://www.elastic.co/guide/en/beats/filebeat/current/running-on-kubernetes.html
- Processor `add_kubernetes_metadata`: https://www.elastic.co/guide/en/beats/filebeat/current/add-kubernetes-metadata.html

**Kibana**
- Kibana Guide: https://www.elastic.co/guide/en/kibana/current/index.html
- Kibana Query Language (KQL): https://www.elastic.co/guide/en/kibana/current/kuery-query.html
- Data views: https://www.elastic.co/guide/en/kibana/current/data-views.html
- Ajustes de `kibana.yml`: https://www.elastic.co/guide/en/kibana/current/settings.html

**Esquemas**
- Referencia de Elastic Common Schema (ECS): https://www.elastic.co/guide/en/ecs/current/ecs-reference.html
- Modelo de datos de logs de OpenTelemetry: https://opentelemetry.io/docs/specs/otel/logs/data-model/
- Convenciones semánticas de OpenTelemetry para logs: https://opentelemetry.io/docs/specs/semconv/general/logs/

**Kubernetes**
- Arquitectura de logging: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Configuración del kubelet (`containerLogMaxSize`, `containerLogMaxFiles`): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Logs del sistema: https://kubernetes.io/docs/concepts/cluster-administration/system-logs/

**Syslog, journald y rotación**
- RFC 5424 — The Syslog Protocol: https://datatracker.ietf.org/doc/html/rfc5424
- RFC 3164 — The BSD syslog Protocol: https://datatracker.ietf.org/doc/html/rfc3164
- RFC 5425 — TLS Transport Mapping for Syslog: https://datatracker.ietf.org/doc/html/rfc5425
- `systemd-journald.service`: https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html
- `journald.conf`: https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- `journalctl`: https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
- Documentación de rsyslog: https://www.rsyslog.com/doc/
- logrotate: https://linux.die.net/man/8/logrotate

**Stacks alternativos (nivel de conocimiento general)**
- Documentación de Grafana Loki: https://grafana.com/docs/loki/latest/
- LogQL: https://grafana.com/docs/loki/latest/query/
- Documentación de Fluentd: https://docs.fluentd.org/
- Documentación de Fluent Bit: https://docs.fluentbit.io/manual
- Documentación de Vector: https://vector.dev/docs/
- OpenTelemetry Collector — receptor filelog: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver
- Documentación de Graylog: https://go2docs.graylog.org/
- Documentación de OpenSearch: https://opensearch.org/docs/latest/