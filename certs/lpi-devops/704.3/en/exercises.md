# LPI DevOps Tools Engineer (701-100, v1.0) - Topic 5.2: Log Management and Analysis

**Exam Weight:** 6.66  
**Target Audience:** SREs, Platform Engineers, Systems Engineers preparing for the LPI DevOps Certification.  
**Official Reference:** [LPI DevOps Tools Engineer Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)

---

## Technical Overview & Architectural Foundations

In high-concurrency production systems, log management spans five critical lifecycle stages: **Generation**, **Local Collection & Rate-Limiting**, **Transport & Buffering**, **Processing & Normalization**, and **Indexing & Storage**.

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

1. **Local System Logging Mechanics (`systemd-journald`, `rsyslog`):** Linux kernels and system daemons write structured entries to socket buffers (e.g., `/dev/log`, `/run/systemd/journal/socket`). `systemd-journald` captures binary, indexed log metadata (pID, UID, cgroups, systemd unit), while `rsyslog` processes text-based syslog protocols (RFC 5424 / RFC 3164) and routes log events over network sockets via TCP/UDP/TLS.
2. **Log Normalization & Parsing (Logstash):** Unstructured text logs must be translated into structured schema (JSON keys) via regular expression matching (Grok), mutation, and field casting to enable performant aggregation queries.
3. **Storage Engineering & Index Lifecycle (Elasticsearch/Lucene):** Text fields are split into tokens via inverted indices for full-text search, while structured scalar fields use `doc_values` (columnar storage) for aggregations. Log indices require automated Index Lifecycle Management (ILM) to manage shard capacity, rollover, and retention deletion without overwhelming cluster IOPS.
4. **Resiliency & Backpressure Handling:** High-throughput logging pipelines utilize decoupled message queues (e.g., Apache Kafka or disk-assisted edge memory buffers) to insulate indexers from traffic spikes and downstream cluster outages.

---

## Exercise 1: Systemd Journald & Rsyslog Local Engine Tuning and Forwarding

### Architectural Mechanics & Trade-Offs
`systemd-journald` maintains log integrity by storing entries in a binary append-only format with internal hash tables. High log frequency can trigger kernel ring-buffer drops or IOPS exhaustion. `SystemMaxUse` limits total disk consumption, while `RateLimitIntervalSec` and `RateLimitBurst` establish leaky-bucket throttles. `rsyslog` relies on dynamic modules (`imuxsock`, `imklog`, `omfwd`) to read from the journal socket and stream log streams downstream via TCP.

### Step 1.1: Configure Production `journald` Persistence & Rate-Limiting
Create or modify the persistent storage directory and write a hardened `/etc/systemd/journald.conf.d/production.conf` configuration file to prevent disk exhaustion and log storming.

```bash
sudo mkdir -p /var/log/journal
sudo chown root:systemd-journal /var/log/journal
sudo chmod 2755 /var/log/journal
```

Write the configuration file `/etc/systemd/journald.conf.d/production.conf`:

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

Restart `systemd-journald` to apply rules cleanly:

```bash
sudo systemctl restart systemd-journald
```

### Step 1.2: Validate Journal Filter Operations & Structured Querying
Execute structured queries using `journalctl` to filter by priority severity, unit, and output formatted JSON payloads for downstream processing.

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
Edit `/etc/rsyslog.d/50-remote-forwarding.conf` to process local logs and reliably forward logs with priority `Warning` (4) or higher to a central receiver (`10.0.10.50:514`) over TCP with an asynchronous queue fallback.

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

Validate rsyslog configuration syntax and restart the daemon:

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

1. **What technical consequences occur if `ForwardToSyslog=yes` remains enabled in `journald.conf` while `rsyslog` reads direct binary journal streams via the `imjournal` module?**
2. **If an application generates 50,000 log lines in a 10-second burst under the configured `journald.conf` rate limits above, how many logs will be stored in the journal, and how does `journalctl` report the discarded entries?**

---

## Exercise 2: Logstash Data Processing Pipeline, Grok Normalization, and Field Mutation

### Architectural Mechanics & Trade-Offs
Logstash operates an event-driven execution thread model: **Input Plugin** $\rightarrow$ **In-Memory Queue / Persistent Queue** $\rightarrow$ **Worker Thread Pipeline (Filter)** $\rightarrow$ **Output Batch Execution**. Grok plugins parse unstructured strings by running regular expression engine patterns. Overuse of complex regex with backreferences can cause catastrophic backtracking and CPU exhaustion. Date filters align event timestamps to `@timestamp` ISO8601 UTC to prevent index skew.

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
Create `/etc/logstash/conf.d/01-nginx-processing.conf` to accept Filebeat inputs over port `5044`, parse Nginx combined access logs, convert HTTP response status codes into integer data types, compute GeoIP data, and route clean events to Elasticsearch while placing malformed logs into a Dead Letter Queue (DLQ) tag structure.

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
Validate the Logstash pipeline syntax against the core configuration test engine:

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

1. **Why is using the `date` filter to replace `@timestamp` critical when indexing high-volume batch logs into Elasticsearch, and what operational problem occurs if this step is omitted?**
2. **If a Grok filter experiences high CPU utilization spikes causing pipeline latency, what configuration parameter or regular expression pattern structure should be audited to fix the issue?**

---

## Exercise 3: Elasticsearch Storage, Shard Topology, and Index Lifecycle Management (ILM)

### Architectural Mechanics & Trade-Offs
Elasticsearch indexes documents inside dynamic Lucene instances called **Shards**. 
* **`text` fields** are parsed by analyzers into tokenized Inverted Indexes for full-text search (high memory footprint, non-aggregatable).
* **`keyword` fields** are stored as exact strings in `doc_values` (columnar format on disk optimized for sorting and aggregations).

**Index Lifecycle Management (ILM)** automates tiering across physical node architectures:
1. **Hot Phase:** High-write IOPS, primary sharding, rollover execution.
2. **Warm Phase:** Read-only operations, shrink shards, force-merge Lucene segments into single segments to free memory.
3. **Cold Phase:** Read-only frozen indices backed by object storage.
4. **Delete Phase:** Hard deletion based on retention SLA.

```
┌─────────────────┐      Rollover      ┌─────────────────┐    ForceMerge     ┌─────────────────┐
│    HOT PHASE    │ ─────────────────► │   WARM PHASE    │ ────────────────► │  DELETE PHASE   │
│  (Write / Read) │  Max Size: 50GB    │   (Read-Only)   │    Retain 30d     │  Purge Indices  │
│ Primary Shards  │  Max Age:  7d      │ Single Segment  │                   │  Free Cluster   │
└─────────────────┘                    └─────────────────┘                   └─────────────────┘
```

### Step 3.1: Define ILM Policy via Elasticsearch API
Configure an automated 4-stage lifecycle policy using `curl` against the REST API (`10.0.20.10:9200`).

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
Create a composite Index Template `/etc/elasticsearch/templates/nginx_template.json` to enforce strict schema types (`keyword` vs `text`) and attach the ILM policy to matching indices.

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
Query the cluster state to verify active shard allocation and policy binding:

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

1. **Why is aggregating dashboard metrics over a field mapped purely as `text` inefficient or prone to Out-Of-Memory (OOM) errors compared to a field mapped as `keyword`?**
2. **What occurs if primary shard sizes in an index grow to 200 GB without ILM rollover configuration enabled? How does this impact search latency and node rebalancing?**

---

## Exercise 4: High-Availability Edge Collection (Filebeat) & Buffer Architecture (Kafka)

### Architectural Mechanics & Trade-Offs
During peak traffic events or indexer node maintenance, direct log shipping (`Filebeat` $\rightarrow$ `Logstash`) risks data loss or edge memory exhaustion if backpressure blocks client connections. Deploying **Apache Kafka** as a distributed, persistent commit log decouples collectors from log indexers. Filebeat buffers logs to local disk ring queues before publishing messages to Kafka partitions. Logstash worker threads consume messages from Kafka consumer groups at a controlled ingestion rate.

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
Create `/etc/filebeat/filebeat.yml` to ingest syslog files, use an internal memory-ring fallback buffer, and publish payloads into a partitioned Kafka cluster topic (`app-logs`).

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

Validate Filebeat configuration and output connectivity:

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
Create `/etc/logstash/conf.d/00-kafka-input.conf` to process events from the distributed queue:

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

1. **How does setting `required_acks: 1` in Filebeat's Kafka output configuration strike a balance between data durability and shipping latency compared to `required_acks: 0` and `required_acks: -1` (all)?**
2. **If Logstash indexers go offline for 2 hours during a cluster upgrade, what happens to logs collected by Filebeat at the edge, and how does Kafka manage the backlog without dropping data?**

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
   * **Mechanism:** Enabling `ForwardToSyslog=yes` instructs `systemd-journald` to forward every logged line to the classical `/dev/log` socket. If `rsyslog` simultaneously uses `imjournal` to read directly from the binary journal files on disk while also listening on `/dev/log` (`imuxsock`), it will receive and log every message **twice**.
   * **Production Impact:** Double IOPS load, duplicate indexing, doubled storage costs, and corrupted metric counts.
   * **Best Practice:** When using modern `rsyslog` configurations, keep `imjournal` enabled and disable `ForwardToSyslog` in `journald.conf`, or use `imuxsock` exclusively with `ForwardToSyslog=yes` while disabling `imjournal`.

2. **Leaky-Bucket Throttle Execution:**
   * **Calculation:** The configuration specifies `RateLimitIntervalSec=30s` and `RateLimitBurst=10000`. 
   * **Result:** Out of 50,000 entries generated in 10 seconds, exactly **10,000 entries** will be committed to disk. The remaining **40,000 entries** are dropped at the journal boundary.
   * **Reporting in `journalctl`:** `journald` emits a metadata warning directly into the journal stream:
     `Suppressed 40000 messages from /system.slice/nginx.service`

---

### Exercise 2 Solutions

1. **Timestamp Normalization & Index Skew Prevention:**
   * **Mechanism:** In the absence of the `date` filter, Logstash assigns `@timestamp` using the current system wall-clock time at the moment Logstash *processes* the log.
   * **Failure Scenario:** If network partitions or queue backlogs delay log delivery by 6 hours, logs generated at 02:00 UTC will be stored with an `@timestamp` of 08:00 UTC.
   * **Production Impact:** Time-series visualizations in Kibana/Grafana display inaccurate time spikes, root cause analysis (RCA) correlation across disparate microservices breaks, and daily ILM index names (`logstash-nginx-access-2026.08.07`) receive historical events belonging to older indices.

2. **Regex Backtracking and Grok Optimization:**
   * **Mechanism:** Grok latency and high CPU spikes stem from **Nondeterministic Finite Automaton (NFA) catastrophic backtracking**, caused by greedy matching operators (`.*` or `%{DATA}`) positioned adjacent to optional or overlapping patterns.
   * **Remediation:** Replace ambiguous patterns with anchored, exact regex character classes (e.g., replace `%{DATA}` with `[^"]+` or strict numeric types `%{NUMBER}`). Audit performance using the Logstash pipeline monitoring API or test expressions via Grok debuggers.

---

### Exercise 3 Solutions

1. **`text` vs `keyword` Storage Engine Mechanics:**
   * **`text` Fields:** Analyzed into inverted index terms. Aggregations (like `terms` or `date_histogram`) on `text` fields force Elasticsearch to load tokenized strings into Heap Memory via **Fielddata**. Loading massive string arrays into JVM heap leads to long Garbage Collection (GC) pauses and `java.lang.OutOfMemoryError` cluster crashes.
   * **`keyword` Fields:** Bypasses term analyzers and stores raw byte strings directly in `doc_values`—an on-disk, columnar data structure managed efficiently by the OS page cache. Aggregations run against `doc_values` without consuming JVM heap memory.

2. **Unmanaged Shard Growth Hazards:**
   * **Performance Degradation:** A 200 GB shard drastically exceeds the recommended Lucene shard size limit of **30 GB – 50 GB**. 
   * **Search Latency:** Large Lucene segments increase disk seek times and slow down parallel query execution.
   * **Recovery Failure:** If a cluster node fails, rebalancing or relocating a 200 GB shard across network interfaces saturates cluster network bandwidth, risking cascading node timeouts and cluster-wide `RED` status.

---

### Exercise 4 Solutions

1. **Kafka Producer Acknowledgement (`required_acks`) Trade-offs:**
   * **`required_acks: 0` (No Acknowledgement):** The Filebeat producer sends packets without waiting for broker confirmation. Lowest latency, highest throughput, but risks total log loss if the Kafka broker drops packets.
   * **`required_acks: 1` (Leader Acknowledgement - Configured):** The producer waits for the partition Leader broker to write the event to its local log. Provides strong protection against network dropouts with low shipping latency.
   * **`required_acks: -1` or `all` (Full Partition Replica Sync):** The producer waits until the Leader and all In-Sync Replicas (ISR) write the event. Maximum data durability guarantee, but increases network round-trip latency.

2. **Backpressure Decoupling & Queue Persistence:**
   * **Edge Resilience:** Filebeat detects TCP connection refusal or missing ACKs from Kafka. It pauses log position offsets and buffers incoming logs locally inside its configured memory ring buffer (`queue.mem`).
   * **Broker Decoupling:** Once Filebeat flushes events to Kafka, Kafka writes the payloads to its durable append-only disk partition logs (`app-logs`).
   * **Consumer Resume:** When Logstash comes back online after 2 hours, it reconnects to Kafka using its persistent `group_id` (`logstash-indexer-group`). Logstash fetches stored unread offsets from Kafka and catches up at maximum indexing throughput without dropping a single log entry or blocking application threads.

</details>