# 704.3 Log Management and Analysis

**Exam:** LPI DevOps Tools Engineer — 701-100, v2.0.0
**Objective weight:** 3.33
**Profile:** SRE / Platform Architect

---

## 1. The architectural problem

A log line is the only telemetry signal that carries *unbounded context*. A metric tells you that 0.4 % of requests returned 503; a trace tells you which span failed; only the log line tells you `upstream prematurely closed connection while reading response header from upstream, upstream: "http://10.244.3.17:8080/checkout"`. That richness is exactly what makes logs the most expensive signal to operate: they are high-volume, high-cardinality, schema-less by default, and produced by software you do not control.

Three properties of modern infrastructure break the classic `ssh host && tail -f /var/log/app.log` workflow:

1. **The host is ephemeral.** A Kubernetes pod that OOM-kills at 03:14 and is rescheduled leaves no filesystem behind. The log must have left the node *before* the incident, not after.
2. **The unit of failure is a request, not a process.** One HTTP request touches an ingress controller, three services, a sidecar proxy and a database. Correlating that requires a shared identifier (`trace.id`) and a single queryable store.
3. **The cost of a log line is paid at ingest, not at read.** Indexing is the dominant cost in Elasticsearch-class systems. Every decision — what to parse, what to index, what to keep — is a cost decision made before the incident happens, by someone who does not know which field will matter.

The architectural question for 704.3 is therefore not "how do I get logs into Elasticsearch", it is: **where in the pipeline does structure get added, where does buffering absorb backpressure, and what is the failure mode when the store is unavailable?**

### 1.1 The three failure modes of a logging pipeline

| Failure mode | Symptom | Root cause | Architectural defence |
|---|---|---|---|
| **Data loss** | Gap in Discover across the incident window | Shipper buffered in memory, node restarted; or store rejected writes and shipper dropped | Disk-backed queue at the shipper *and* at the aggregator; at-least-once delivery |
| **Backpressure collapse** | Application containers block on `write(2)` to stdout; latency spikes | Log pipe full because collector stopped reading (Docker `json-file` with a blocked plugin) | Never let the runtime block on the collector; decouple with file + rotation |
| **Cost explosion** | Cluster disk at 92 %, ILM deleting yesterday's data | Dynamic mapping created 14 000 fields from a JSON payload; `text` mapping on a UUID field | Strict mappings, `ignore_above`, field-limit guardrails, ingest-time dropping |

The third one is the most common in practice and the least dramatic: nothing pages, the pipeline keeps working, and six weeks later retention has silently fallen from 30 days to 4.

---

## 2. Log formats and structured logging

### 2.1 The wire formats you will actually meet

| Format | Spec | Timestamp | Structure | Where you meet it |
|---|---|---|---|---|
| BSD syslog | RFC 3164 | `MMM dd HH:mm:ss`, **no year, no timezone, no sub-second** | Free text after `TAG:` | Network gear, old daemons, `logger(1)` defaults |
| IETF syslog | RFC 5424 | RFC 3339 with offset and fractional seconds | `STRUCTURED-DATA` SD-elements | rsyslog/syslog-ng with `RSYSLOG_SyslogProtocol23Format` |
| journald native | systemd | `__REALTIME_TIMESTAMP` µs since epoch | Arbitrary `KEY=value` fields, indexed | Every systemd host; `journalctl -o json` |
| JSON Lines | de facto | Whatever the app writes | Full nesting | 12-factor apps, container stdout |
| logfmt | de facto | app-defined | Flat `k=v` | Go ecosystem (Heroku lineage) |
| CRI log | Kubernetes CRI | RFC 3339 nano, UTC | `<ts> <stream> <tag> <msg>` | `/var/log/pods/**/*.log` on every node |

The CRI line format is worth memorising, because every Kubernetes collector must strip it before the payload is usable:

```
2026-09-18T08:14:22.481937214Z stdout F {"level":"error","msg":"checkout failed","order_id":"a91f"}
2026-09-18T08:14:22.482011882Z stdout P this is a partial line that was split because it exceeded
2026-09-18T08:14:22.482013104Z stdout F  the 16 KiB runtime buffer and must be reassembled
```

`F` = full line, `P` = partial. A collector that does not reassemble `P` lines will corrupt every log message longer than 16 KiB — a classic source of "our Java stack traces are truncated".

### 2.2 RFC 3164 is a trap

```
Sep 18 08:14:22 web01 nginx: upstream timed out
```

No year and no timezone. The consumer must guess both. Every January a fleet on RFC 3164 produces a burst of documents dated eleven months in the future or the past, depending on how the parser resolves the year. Fix it at the source:

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

`UDP syslog silently drops under load`. If the objective is "no gap during the incident", plain `omfwd` over UDP disqualifies itself immediately: the incident *is* the load.

### 2.3 Structured logging and a common schema

Structure at the source beats parsing downstream on every axis: no regex to maintain, no `_grokparsefailure`, no CPU burnt in Oniguruma. The application emits:

```
{"@timestamp":"2026-09-18T08:14:22.481Z","log.level":"error","message":"checkout failed","service.name":"checkout-api","service.version":"2.11.3","trace.id":"4bf92f3577b34da6a3ce929d0e0e4736","span.id":"00f067aa0ba902b7","http.request.method":"POST","url.path":"/api/v1/orders","http.response.status_code":503,"error.type":"UpstreamTimeout","event.duration":4102831000}
```

Two schemas compete, and you should pick one deliberately:

| | **ECS** (Elastic Common Schema) | **OpenTelemetry Logs Data Model** |
|---|---|---|
| Field naming | Dotted, nested-capable: `http.response.status_code` | Attributes with semantic conventions: `http.response.status_code` |
| Timestamp | `@timestamp`, RFC 3339 ms | `Time`, `ObservedTime`, uint64 nanos |
| Severity | `log.level` (string) | `SeverityNumber` (1–24) + `SeverityText` |
| Correlation | `trace.id`, `span.id`, `transaction.id` | `TraceId`, `SpanId`, `TraceFlags` (first-class, binary) |
| Resource identity | flattened into the doc (`host.name`, `container.id`) | Separate `Resource` block, deduplicated per batch |
| Vendor coupling | Elastic, but published under Apache-2.0 | CNCF, vendor-neutral |
| Maturity for logs | Stable, very broad field set | Stable spec; collector support universal |

ECS and OTel semantic conventions have been converging since Elastic donated ECS to OpenTelemetry in 2023, so the field names largely agree. **Choose ECS if your store is Elasticsearch** (the shipped index templates, Kibana dashboards and detection rules all assume it); choose the OTel data model if the collector is already your telemetry front door for metrics and traces.

The non-negotiable rule: **one schema, enforced at the aggregator**, not "whatever each team emits". A field that is `http.response.status_code: 503` in one service and `status: "503"` in another cannot be aggregated, and the second one will also poison the mapping.

---

## 3. Architecture: shipper, aggregator, store, UI

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

### 3.1 Why an aggregator tier at all

You *can* ship Filebeat → Elasticsearch directly and parse with an ingest pipeline. That is cheaper and has one moving part fewer. The aggregator earns its keep when:

- Parsing is expensive (grok over multi-MB/s of unstructured text) and you do not want that CPU competing with search on data nodes.
- You must **fan out**: the same event to Elasticsearch, to S3 for compliance, to a SIEM, to Kafka for a stream processor.
- You need a **large durable buffer**. Filebeat's buffer is the log file itself plus a small spool; if Elasticsearch is down for two hours and the node rotates its logs, data is gone. A Logstash persistent queue of 50 GB survives it.
- You need **redaction before storage** (PII, secrets, card numbers) and cannot trust the edge.

### 3.2 Shipper comparison

| | **Filebeat** | **Fluent Bit** | **Fluentd** | **Vector** | **Alloy / Promtail** | **OTel Collector** |
|---|---|---|---|---|---|---|
| Language | Go | C | Ruby + C | Rust | Go | Go |
| RSS at 10k EPS | ~120 MB | ~35 MB | ~250 MB | ~90 MB | ~80 MB | ~110 MB |
| Transform language | processors (YAML) | Lua / built-in filters | Ruby plugins | VRL (typed, compiled) | River / pipeline stages | OTTL |
| Disk buffer | registry + spool | `storage.type filesystem` | `buffer file` | `buffer.type disk` | WAL | `file_storage` extension |
| Back-pressure | propagates to harvester | `Mem_Buf_Limit`, pauses input | propagates | propagates | propagates | propagates |
| K8s metadata | `add_kubernetes_metadata` | `kubernetes` filter | `kubernetes_metadata` | `kubernetes_logs` source | native | `k8sattributes` |
| Natural sink | Elasticsearch/Logstash | anything | anything | anything | Loki | any (OTLP) |
| Exam relevance | **high** (named in objectives) | awareness | awareness | — | awareness | awareness |

For 701-100, **Filebeat is the named shipper**. In production, Fluent Bit and Vector are the common choices when the store is not Elastic.

### 3.3 Store comparison — the decision that determines your cost curve

| | **Elasticsearch / OpenSearch** | **Loki** | **ClickHouse** | **Graylog** |
|---|---|---|---|---|
| Index model | Inverted index on **every** indexed field | Index on **labels only**; log body stored as compressed chunks | Columnar, sparse primary index + skip indexes/bloom | Elasticsearch/OpenSearch underneath |
| Ingest cost | High (analysis + index build) | Very low | Low–medium | High |
| Query cost for `status:503` | O(postings list) — milliseconds | Brute-force scan of matching streams | Vectorised scan + bloom prune | as Elasticsearch |
| Storage multiplier vs raw | 0.5–1.3× (logsdb/best_compression → ~0.3–0.5×) | 0.1–0.2× | 0.05–0.15× | as Elasticsearch |
| Cardinality hazard | Field explosion in mappings | **Label** explosion → stream explosion | Low | Field explosion |
| Aggregations | Rich, native | Limited (LogQL metric queries) | Full SQL | Rich |
| Full-text relevance | Yes (BM25) | Substring/regex only | Token bloom / `hasToken` | Yes |
| Operational weight | High (shards, heap, ILM) | Medium (needs object store) | Medium (needs schema design) | Medium |

The honest architectural summary: **Elasticsearch buys you fast arbitrary search at high ingest cost; Loki buys you cheap retention at the price of knowing your label set in advance; ClickHouse buys you both at the price of designing a schema.** Pick based on whether your investigations start from a known label (service, namespace) — in which case Loki is dramatically cheaper — or from an unknown string found in a customer report.

---

## 4. Elasticsearch for log workloads

### 4.1 Internals that change your configuration

- **Segments and refresh.** A document is searchable only after a *refresh* creates a new Lucene segment. Default `index.refresh_interval` is `1s`. For logs, 1-second freshness is rarely worth the segment churn: setting `30s` typically buys 15–25 % indexing throughput and far fewer merges.
- **Translog.** Durability comes from the transaction log, fsynced on every request by default (`index.translog.durability: request`). `async` with `sync_interval: 30s` is a real throughput win and an explicit decision to risk 30 s of data on a hard node failure. For logs that is often acceptable; for audit logs it is not.
- **doc_values vs inverted index.** Aggregations and sorting read columnar `doc_values`; searching reads the inverted index. A field you only ever filter on exactly (`kubernetes.pod.name`) should be `keyword`; a field you only ever aggregate should have `index: false, doc_values: true`; a field you never use should not be indexed at all.
- **`match_only_text`.** For the log body, `match_only_text` stores no norms and no positions on disk (positions are recomputed from `_source` for phrase queries). It is roughly 10 % smaller than `text` and the right default for `message`.
- **Shard sizing.** Target **30–50 GB per primary shard** for logs, and keep total shards under roughly **20 per GB of JVM heap** per node. Shard count is not a tuning knob you set once — it is the output of `rollover` thresholds.

### 4.2 `elasticsearch.yml` — a hot node in a tiered cluster

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

Heap is **not** set here — it goes in `jvm.options.d/`:

```
-Xms31g
-Xmx31g
```

Never above ~31 GB: past that the JVM loses compressed ordinary object pointers and you get *less* usable heap from more memory. Rest of the RAM goes to the page cache, which is what actually makes Lucene fast.

### 4.3 Data streams, not indices

For append-only time-series data, use a **data stream**. The naming convention is `<type>-<dataset>-<namespace>`:

```
logs-nginx.access-prod
logs-kubernetes.container_logs-default
```

Backing indices are named `.ds-logs-nginx.access-prod-2026.09.18-000042`. Writes always go to the stream name; ILM rolls the backing index over underneath you; `_search` against the stream name covers all generations.

**Component template — the mapping contract:**

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

Three deliberate choices in there, each preventing a real outage:

- `dynamic_templates → keyword, ignore_above: 1024` stops a rogue 2 MB field from being analysed into tens of thousands of terms.
- `index.mapping.ignore_malformed: true` means a single document with `status_code: "N/A"` is indexed with that one field skipped, instead of the whole bulk item being rejected. Rejected bulk items in a logging pipeline turn into retry storms.
- `labels.*` as `flattened` maps an entire arbitrary sub-object to **one** field. This is the direct antidote to mapping explosion from user-controlled keys.

**Index template binding it to the stream:**

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

Applying them:

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

`_simulate_index` is the single most underused endpoint in Elasticsearch operations: it tells you exactly which templates composed, in which order, *before* the first document creates a wrong mapping that you then cannot change without a reindex.

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

Mechanics worth understanding for the exam and for the 3 a.m. version of this:

- `min_age` is measured from **rollover**, not from index creation, for every phase after `hot`.
- ILM checks policies every `indices.lifecycle.poll_interval` (default **10 minutes**). An index does not move the instant `min_age` elapses.
- `forcemerge` to 1 segment is a heavy, non-interruptible I/O operation. Doing it in `warm` (after writes stopped) is correct; doing it on a hot index is a self-inflicted outage.
- `shrink` requires all primaries on one node and the index to be read-only first; ILM handles that, but it needs free disk equal to the index size.
- `wait_for_snapshot` before `delete` is the difference between retention and data loss.

Verifying a stuck lifecycle:

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

### 4.5 A note on `logsdb`

Recent Elasticsearch versions ship an index mode specialised for logs:

```json
{
  "template": {
    "settings": {
      "index.mode": "logsdb"
    }
  }
}
```

It enables synthetic `_source` (the document is reconstructed from `doc_values` instead of being stored verbatim) plus sorting by `host.name` and `@timestamp`, which dramatically improves compression — typically **2–2.5× smaller on disk**. The trade-offs are real and must be checked against your version's documentation before adopting: reconstructed `_source` is not byte-identical (field order and some formatting change), and a few field types are unsupported. Validate on a copy of real data before switching a production stream.

---

## 5. Logstash

### 5.1 Pipeline mechanics

A Logstash pipeline is `input → queue → N worker threads (filter + output) → sink`.

- Input plugins run on their own threads and push events into the queue.
- `pipeline.workers` (default = CPU cores) worker threads each pull a **batch** of up to `pipeline.batch.size` events (default 125), or whatever has accumulated after `pipeline.batch.delay` ms (default 50).
- **Filters and outputs execute in the same worker thread.** There is no separate output stage. This is why an output that blocks (Elasticsearch unavailable) stops filtering, which stops draining the queue, which propagates backpressure to the input, which propagates it to Filebeat. That chain is the design, and it is correct: backpressure beats data loss.
- Event **ordering is not preserved** with more than one worker. `pipeline.ordered: true` forces a single worker.

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

Two settings that decide whether you lose data:

- **`queue.type: persisted`** writes every event to disk before acknowledging the input. The cost is real (fsync per checkpoint) but `queue.checkpoint.writes: 1024` amortises it. With the default `memory` queue, a Logstash restart drops everything in flight — up to `pipeline.workers × pipeline.batch.size` events plus the in-memory queue.
- **`dead_letter_queue.enable: true`** captures documents that Elasticsearch rejected with HTTP 400 or 404 — overwhelmingly **mapping conflicts**. Without a DLQ those events vanish with a log line and no one notices. With it, you can read them back and see exactly which field broke.

### 5.3 `pipelines.yml` — multiple pipelines

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

Separate pipelines give you **per-tenant isolation**: a grok pattern that starts backtracking on the nginx pipeline does not starve the Kubernetes pipeline's workers, and the two queues fill independently.

### 5.4 The pipeline-to-pipeline pattern

`00-beats-input.conf` — one TLS listener, routed by a distributor:

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

`10-nginx.conf` — the full parse:

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

**The `_grokparsefailure` file output is the part people skip and then regret.** A pattern that silently fails on 4 % of lines produces a dashboard that is quietly 4 % wrong. Writing the unparsed lines to a file makes the failure rate *countable*.

### 5.5 Parser comparison

| Filter | Cost per event | When to use | Failure mode |
|---|---|---|---|
| `json` | Very low | App emits JSON Lines | `_jsonparsefailure`; nested depth explosion |
| `dissect` | Very low (no regex) | Fixed delimiters, known field count | Silently wrong if the format varies |
| `kv` | Low | logfmt, `k=v` pairs | Unbounded key set → mapping explosion; always set `include_keys` |
| `csv` | Low | Access logs with a stable column list | Embedded commas |
| `grok` | **High** | Genuinely irregular text | Catastrophic backtracking; timeouts; `_grokparsefailure` |
| `ruby` | Medium | Logic no filter expresses | Unbounded — a bug here stalls a worker thread |

Grok rules that prevent the pathological case:

1. **Anchor.** `^...$`. An unanchored pattern makes the engine retry at every offset of a 4 KB line.
2. **Never chain `%{GREEDYDATA}`.** Two greedy patterns in one expression is exponential backtracking. Use `%{DATA}` (lazy) in the middle, `%{GREEDYDATA}` only at the end.
3. **Order alternatives most-specific first**, because `break_on_match => true` stops at the first hit.
4. **Always set `timeout_millis`.** Without it, one adversarial log line occupies a worker thread indefinitely.
5. **Prefer `dissect` and reach for grok only on the residue**, as in the config above.

Custom patterns live in a directory you point at with `patterns_dir`:

```
# /etc/logstash/patterns/app.grok
APP_LEVEL     (?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)
APP_THREAD    [\w\-\.#]+
APP_LOGGER    [\w\.$]+
APP_LINE      ^%{TIMESTAMP_ISO8601:[event][created]}\s+%{APP_LEVEL:[log][level]}\s+\[%{APP_THREAD:[process][thread][name]}\]\s+%{APP_LOGGER:[log][logger]}\s+-\s+%{GREEDYDATA:message}$
```

### 5.6 The dead letter queue, read back

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

### 6.1 Standalone `filebeat.yml`

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

Four details that separate a working deployment from a data-loss incident:

- **`file_identity: fingerprint`.** The legacy default identified files by inode + device. On systems that reuse inodes aggressively — or when a log is rotated with `copytruncate` — inode identity causes both re-reading a whole file (duplicates) and skipping a new file (loss). Fingerprinting the first 1024 bytes is correct. Changing `file_identity` on an existing deployment **invalidates the registry**, so plan for a one-time re-read or a registry reset.
- **`queue.disk`** gives Filebeat a real buffer independent of the log file's own retention.
- **`ttl: 60s`** on the Logstash output forces periodic reconnection, which is how you get rebalancing after a Logstash replica returns. Without it, connections pin to the survivors forever.
- **`ignore_older` must be larger than your rotation window**, or a file that goes quiet over a weekend will never be resumed.

### 6.2 `logrotate` interaction

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

`create` + signal (the nginx `USR1` reopen) is the safe pattern: the old inode stays open until the harvester finishes it. **`copytruncate` is the dangerous one** — it truncates the file in place while the harvester holds an offset past the new EOF, which loses everything written between the copy and the truncate. `delaycompress` matters too: compressing on the same rotation can gzip a file the harvester has not finished reading.

---

## 7. Kubernetes logging architecture

On every node the kubelet writes container stdout/stderr to `/var/log/pods/<ns>_<pod>_<uid>/<container>/<n>.log`, with symlinks at `/var/log/containers/<pod>_<ns>_<container>-<id>.log`. **The kubelet performs the rotation**, controlled by:

```yaml
containerLogMaxSize: 50Mi
containerLogMaxFiles: 5
```

Defaults are `10Mi` / `5` — that is **50 MiB of buffer per container**. A pod logging 20 MB/s has ~2.5 seconds of headroom before the oldest file is deleted. If your collector is down for longer than that, the data is gone regardless of any downstream buffer. This is the single most important number in Kubernetes logging capacity planning, and it is set on the kubelet, not on the collector.

### 7.1 Collection patterns

| Pattern | Pods per node | Isolation | Handles non-stdout logs | Cost |
|---|---|---|---|---|
| **Node agent (DaemonSet)** | 1 | Shared; a noisy namespace can starve others | No (unless it mounts an emptyDir) | Lowest |
| **Sidecar per pod** | N | Per-workload | Yes | High (1 container per pod) |
| **Application pushes directly** | 0 | Per-workload | Yes | No node-level buffer; app blocks if the endpoint is down |

The DaemonSet is the default and the right answer for ~95 % of platforms. Use a sidecar only when an application writes to a file it refuses to also send to stdout, and never let an application push directly to the store — you lose the node buffer and couple application availability to the logging backend.

### 7.2 Full Filebeat DaemonSet

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

The `data` volume is a `hostPath`, not an `emptyDir`, on purpose: the registry holding read offsets must survive a pod restart. With `emptyDir`, every Filebeat restart re-reads every file from the beginning and you get a duplicate storm.

`/var/log/pods` must be mounted alongside `/var/log/containers` because the latter is only a directory of symlinks pointing into the former.

### 7.3 Logstash as a StatefulSet

A persistent queue requires stable, durable storage per replica — that means a StatefulSet with `volumeClaimTemplates`, never a Deployment.

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

`terminationGracePeriodSeconds: 180` gives Logstash time to drain its in-flight batches on SIGTERM. The default 30 s truncates the drain and the remaining events are recovered from the persistent queue on restart — which only works because the queue is on a PVC.

---

## 8. Kibana and query languages

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

The three `encryptionKey` values must be **identical across all Kibana instances** and stable across restarts, or saved objects, alert rules and reporting jobs become undecryptable. Generating them at deploy time with a random function is a recurring self-inflicted outage.

### 8.2 Query languages

| | **KQL** | **Lucene** | **ES|QL** | **Query DSL** |
|---|---|---|---|---|
| Where | Kibana search bar (default) | Kibana search bar (toggle) | Discover / API | API, alert rules |
| Wildcards in values | Yes (`service.name: check*`) | Yes | `LIKE` / `RLIKE` | `wildcard` query |
| Regex | No | Yes (`/err(or)?/`) | Yes (`RLIKE`) | `regexp` query |
| Ranges | `bytes > 1000` | `bytes:[1000 TO *]` | `WHERE bytes > 1000` | `range` |
| Aggregation | No | No | **Yes** (`STATS`) | Yes |
| Transformation | No | No | **Yes** (`EVAL`, `DISSECT`, `GROK`) | Runtime fields |

Practical examples against an ECS-shaped stream:

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

That last one is the architect's escape hatch: **you can recover structure from a field you failed to parse at ingest time, without reindexing**, via `GROK`/`DISSECT` in ES|QL or via a runtime field on the data view. It is slower than an indexed field (computed per matching document) but it turns a six-hour reindex into a query.

Equivalent LogQL, if the store is Loki:

```
{namespace="prod", app="checkout-api"} |= "error" | json | status_code >= 500 | line_format "{{.trace_id}} {{.message}}"

sum by (status_code) (
  rate({namespace="prod", app="checkout-api"} | json | __error__="" [5m])
)
```

The structural difference is visible in the first selector: Loki *requires* a label matcher, and labels are the only indexed thing. `{namespace="prod"}` is cheap; there is no way to ask "find this string anywhere in the cluster" without scanning.

---

## 9. Verification and failure diagnosis

### 9.1 Validate before you deploy

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

Exercise a pattern end-to-end without touching the cluster:

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

### 9.2 Is the pipeline flowing?

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

`kubernetes-json` has **17 million events sitting in the queue and 19 GB on disk**: `in` is running well ahead of `out`. That is the signature of a downstream stall — the persistent queue is doing its job, and you have `queue.max_bytes / current growth rate` before backpressure reaches Filebeat.

Find *which* plugin is the bottleneck:

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

`grok_fallback` processed 4.7 % of the events and burned 91 % of the filter time — 0.54 ms per event against 0.0018 ms for the JSON parser. That is the real finding, and the fix is a `dissect` fast path or dropping the unparseable stream, not more CPU.

### 9.3 Cluster and index health

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

`_cluster/allocation/explain` is the canonical answer to "why is my cluster yellow". It names the shard and the per-node reason; guessing is never necessary.

### 9.4 Confirm the data is actually correct

Health green and events flowing does not mean the data is right. Two checks catch most silent corruption:

**Ingest lag** — the gap between when the event happened and when it was indexed:

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

p50 of 3 s is healthy; a p99 of 412 s says ~1 % of events are arriving nearly seven minutes late — a partially stalled shipper somewhere. Negative values would mean **clock skew**, which is worse: it puts events in the future and they disappear from any "last 15 minutes" dashboard.

**Parse-failure rate** — the number that tells you whether your dashboards are lying:

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

4.5 % `_grokparsefailure`. Alert on this ratio. It is the only metric that catches "the vendor changed their log format in a minor release".

### 9.5 Failure playbook

| Symptom | Likely cause | Diagnostic | Fix |
|---|---|---|---|
| `cluster_block_exception ... read-only-allow-delete` | Disk crossed the 95 % flood-stage watermark | `GET _cat/allocation?v` | Free disk / add nodes; the block auto-releases below the high watermark. Manual release: `PUT */_settings {"index.blocks.read_only_allow_delete": null}` |
| Bulk rejections, `es_rejected_execution_exception` | `write` thread-pool queue full — indexing faster than the cluster absorbs | `GET _cat/thread_pool/write?v&h=node_name,active,queue,rejected` | Raise `bulk_max_size` **down**, raise `refresh_interval`, add hot nodes. Never raise the queue size — that trades rejection for heap pressure |
| `mapper_parsing_exception: failed to parse field [x] of type [long]` | Field arrived as a different type than the mapping | Read the DLQ; `GET <index>/_mapping/field/x` | `ignore_malformed: true` on the index; normalise the type in the filter; the existing index cannot be changed — new mapping applies at next rollover |
| `Limit of total fields [1000] has been exceeded` | Dynamic mapping explosion, usually from a `labels` or `params` object | `GET <index>/_mapping | jq '[paths] | length'` | Map the offending sub-object as `flattened`; raise the limit only as a stopgap |
| Filebeat re-reads whole files after restart | Registry not persisted (`emptyDir`), or `file_identity` changed | `ls -l /usr/share/filebeat/data/registry/filebeat/` | Persist the data dir on a `hostPath`/PVC |
| Duplicate documents | At-least-once retry after a partial bulk failure | Count by `_id` | `fingerprint` filter + `document_id` in the ES output; `action => "create"` |
| Gap in logs, no errors anywhere | kubelet rotated and deleted the file before it was read | `kubectl get --raw /api/v1/nodes/<n>/proxy/configz | jq .kubeletconfig.containerLogMaxSize` | Raise `containerLogMaxSize` / `containerLogMaxFiles`; reduce log volume at the source |
| Stack traces split across many documents | No multiline parser, or the pattern does not match this language | Search `log.level:*` count vs `message:"at "` count | Add/repair the `multiline` parser; prefer JSON logging with `error.stack_trace` as one field |
| Logs truncated at ~16 KiB | CRI partial (`P`) lines not reassembled | Look for lines ending mid-word | Use the `container` parser with `format: cri` |
| Everything timestamped at ingest time | No `date` filter, or the filter failed | Count `_dateparsefailure` | Add/repair the `date` filter; note RFC 3164 has no year or timezone |
| Logstash CPU pinned, throughput collapsed | Grok catastrophic backtracking | Per-plugin `duration_in_millis` from the node-stats API | Anchor the pattern, replace `GREEDYDATA` with `DATA`, add `timeout_millis`, move to `dissect` |
| Kibana: "no results" but data exists | Time filter vs skewed clocks; wrong data view; missing read privilege on the index pattern | Query Elasticsearch directly with the same range | Fix NTP; check the data view's time field; check role index privileges |
| Warm phase never runs | ILM step error (usually `shrink` needing free disk or a colocated allocation) | `GET <idx>/_ilm/explain?human` | Fix the underlying cause, then `POST <idx>/_ilm/retry` |

### 9.6 Alerting on the pipeline itself

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

The alert most teams are missing is the last-but-one: **parse failure ratio**. Everything else pages when logs stop. That one pages when logs keep flowing but stop meaning what your dashboards assume.

---

## 10. Security and compliance

- **Transport.** mTLS on every hop: Filebeat→Logstash (`ssl_client_authentication => "required"`), Logstash→Elasticsearch, Kibana→Elasticsearch. A logging pipeline carries, by construction, the most sensitive strings your systems produce.
- **Authentication.** Use **API keys** with the minimum privileges, not the `elastic` superuser. A shipper needs `auto_configure`, `create_doc` on its own data stream pattern and nothing more:

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

- **Redaction at the aggregator.** Card numbers, bearer tokens, query-string secrets and any field a user can control must be scrubbed before they hit persistent storage. Once a secret is in a Lucene segment it is in every replica, every snapshot and every backup, and `_update_by_query` does not remove it from existing segments until a merge.
- **Retention as a legal constraint.** ILM `delete` is how you implement "we do not keep this beyond N days". `wait_for_snapshot` is how you implement "and we can still produce it on request". These are opposite requirements and both are usually in the same policy document.
- **The audit log is not an application log.** Elasticsearch's own audit trail (`xpack.security.audit.enabled`) belongs in a separate cluster or at minimum a separate data stream with separate privileges — otherwise the accounts you are auditing can also write to the audit record.

---

## 11. Mental model for the exam

- **ELK is a pipeline, not a product.** Beats collect, Logstash transforms, Elasticsearch indexes, Kibana queries. Know which component owns each verb.
- **Logstash config is three blocks: `input`, `filter`, `output`.** Plugins named in the objectives: inputs `beats`, `file`, `stdin`; filters `grok`, `mutate`, `date`, `json`, `dissect`; outputs `elasticsearch`, `stdout`. `/etc/logstash/logstash.yml` is settings; `/etc/logstash/conf.d/*.conf` is the pipeline.
- **`%{SYNTAX:SEMANTIC}`** is the grok grammar. `%{IP:client}` matches an IP and stores it in the field `client`. A failed match adds the tag `_grokparsefailure`.
- **The `date` filter sets `@timestamp`.** Without it, `@timestamp` is ingest time.
- **An index template governs indices created after it exists**, never existing ones. Mappings are immutable for an existing field; changing one requires rollover or reindex.
- **ILM phases in order: hot → warm → cold → frozen → delete**, `min_age` counted from rollover.
- **A data stream is an alias over rolling backing indices**, append-only, requiring `@timestamp`.
- **Filebeat's registry stores read offsets.** Lose it and you re-read; corrupt it and you skip.
- **Awareness-level alternatives:** Fluentd and Fluent Bit (CNCF collectors, plugin-based), Loki (labels indexed, body not), Graylog (Elasticsearch/OpenSearch with its own UI and processing rules), Vector and the OpenTelemetry Collector.

---

## References

**Exam objectives**
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
- `_cat/indices` API: https://www.elastic.co/guide/en/elasticsearch/reference/current/cat-indices.html
- Cluster health API: https://www.elastic.co/guide/en/elasticsearch/reference/current/cluster-health.html
- Cluster allocation explain API: https://www.elastic.co/guide/en/elasticsearch/reference/current/cluster-allocation-explain.html
- Create API key API: https://www.elastic.co/guide/en/elasticsearch/reference/current/security-api-create-api-key.html

**Logstash**
- Logstash Reference: https://www.elastic.co/guide/en/logstash/current/index.html
- How Logstash works (pipeline execution): https://www.elastic.co/guide/en/logstash/current/pipeline.html
- Settings file (`logstash.yml`): https://www.elastic.co/guide/en/logstash/current/logstash-settings-file.html
- Multiple pipelines (`pipelines.yml`): https://www.elastic.co/guide/en/logstash/current/multiple-pipelines.html
- Persistent queues: https://www.elastic.co/guide/en/logstash/current/persistent-queues.html
- Dead letter queues: https://www.elastic.co/guide/en/logstash/current/dead-letter-queues.html
- `grok` filter plugin: https://www.elastic.co/guide/en/logstash/current/plugins-filters-grok.html
- `dissect` filter plugin: https://www.elastic.co/guide/en/logstash/current/plugins-filters-dissect.html
- `date` filter plugin: https://www.elastic.co/guide/en/logstash/current/plugins-filters-date.html
- `mutate` filter plugin: https://www.elastic.co/guide/en/logstash/current/plugins-filters-mutate.html
- `elasticsearch` output plugin: https://www.elastic.co/guide/en/logstash/current/plugins-outputs-elasticsearch.html
- Node stats API: https://www.elastic.co/guide/en/logstash/current/node-stats-api.html
- Core grok pattern library (source): https://github.com/logstash-plugins/logstash-patterns-core

**Beats**
- Filebeat Reference: https://www.elastic.co/guide/en/beats/filebeat/current/index.html
- `filestream` input: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-filestream.html
- `journald` input: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-journald.html
- Running Filebeat on Kubernetes: https://www.elastic.co/guide/en/beats/filebeat/current/running-on-kubernetes.html
- `add_kubernetes_metadata` processor: https://www.elastic.co/guide/en/beats/filebeat/current/add-kubernetes-metadata.html

**Kibana**
- Kibana Guide: https://www.elastic.co/guide/en/kibana/current/index.html
- Kibana Query Language (KQL): https://www.elastic.co/guide/en/kibana/current/kuery-query.html
- Data views: https://www.elastic.co/guide/en/kibana/current/data-views.html
- `kibana.yml` settings: https://www.elastic.co/guide/en/kibana/current/settings.html

**Schemas**
- Elastic Common Schema (ECS) reference: https://www.elastic.co/guide/en/ecs/current/ecs-reference.html
- OpenTelemetry logs data model: https://opentelemetry.io/docs/specs/otel/logs/data-model/
- OpenTelemetry semantic conventions for logs: https://opentelemetry.io/docs/specs/semconv/general/logs/

**Kubernetes**
- Logging architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Kubelet configuration (`containerLogMaxSize`, `containerLogMaxFiles`): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- System logs: https://kubernetes.io/docs/concepts/cluster-administration/system-logs/

**Syslog, journald and rotation**
- RFC 5424 — The Syslog Protocol: https://datatracker.ietf.org/doc/html/rfc5424
- RFC 3164 — The BSD syslog Protocol: https://datatracker.ietf.org/doc/html/rfc3164
- RFC 5425 — TLS Transport Mapping for Syslog: https://datatracker.ietf.org/doc/html/rfc5425
- `systemd-journald.service`: https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html
- `journald.conf`: https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- `journalctl`: https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
- rsyslog documentation: https://www.rsyslog.com/doc/
- logrotate: https://linux.die.net/man/8/logrotate

**Alternative stacks (awareness level)**
- Grafana Loki documentation: https://grafana.com/docs/loki/latest/
- LogQL: https://grafana.com/docs/loki/latest/query/
- Fluentd documentation: https://docs.fluentd.org/
- Fluent Bit documentation: https://docs.fluentbit.io/manual
- Vector documentation: https://vector.dev/docs/
- OpenTelemetry Collector — filelog receiver: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver
- Graylog documentation: https://go2docs.graylog.org/
- OpenSearch documentation: https://opensearch.org/docs/latest/