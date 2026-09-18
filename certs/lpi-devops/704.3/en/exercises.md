# 704.3 — Log Management and Analysis
## Guided exercises (LPI DevOps Tools Engineer, exam 701-100)

**Before you start.** Every command below runs on a throwaway systemd-based VM (Debian 12 / Ubuntu 24.04 / RHEL 9 family) where you have root, plus a container runtime for the aggregation half. Never run exercises 2, 4 and 5 on a machine whose logs someone depends on: you will deliberately rotate, vacuum and rate-limit real journals.

```bash
sudo mkdir -p /var/log/drill
sudo apt-get install -y rsyslog logrotate jq   # or: sudo dnf install -y rsyslog logrotate jq
docker --version   # or podman --version
```

Throughout, the mental model to hold is the pipeline every log architecture is an instance of:

```
emit  ->  local collector  ->  buffer/queue  ->  ship  ->  index/store  ->  query/alert
```

Most production log incidents are not "the app did not log". They are "one hop in that chain silently dropped, and nothing alerted on the drop". The exercises are ordered along that chain.

---

## Exercise 1 — journald is a structured store, not a text file

`systemd-journald` does not keep lines. It keeps records: a set of key/value fields per entry, in an indexed binary format. Fields beginning with `_` are **trusted fields** — the kernel and journald derive them from the sending process credentials, and an application cannot forge them. That distinction is the whole security argument for journald.

### Steps

1. Confirm journald is the socket owner and emit one entry with an explicit facility and severity:

```bash
systemctl status systemd-journald --no-pager
logger -p local3.warning -t drill "disk latency p99 exceeded"
```

2. Read the entry back with every field:

```bash
journalctl -t drill -n 1 -o verbose
```

Expected output (abridged fields will differ per host):

```
Thu 2026-09-17 11:42:07.913455 UTC [s=6c1f2a...;i=1a4f;b=9d3c...;m=2b8e...;t=63c1...]
    _TRANSPORT=syslog
    PRIORITY=4
    SYSLOG_FACILITY=19
    SYSLOG_IDENTIFIER=drill
    SYSLOG_TIMESTAMP=Sep 17 11:42:07
    _UID=0
    _GID=0
    _COMM=logger
    _EXE=/usr/bin/logger
    _CMDLINE=logger -p local3.warning -t drill disk latency p99 exceeded
    _CAP_EFFECTIVE=1ffffffffff
    _SELINUX_CONTEXT=unconfined_u:unconfined_r:unconfined_t:s0
    _SYSTEMD_CGROUP=/user.slice/user-1000.slice/session-3.scope
    _SYSTEMD_UNIT=session-3.scope
    _BOOT_ID=9d3c...
    _MACHINE_ID=1f08...
    _HOSTNAME=node-a
    _PID=48213
    MESSAGE=disk latency p99 exceeded
    _SOURCE_REALTIME_TIMESTAMP=1789643327913455
```

3. Inspect the same record as JSON, and then extract two fields with `jq`:

```bash
journalctl -t drill -n 1 -o json | jq -r '[.PRIORITY, .SYSLOG_FACILITY, .MESSAGE] | @tsv'
```

```
4	19	disk latency p99 exceeded
```

> **Question 1.** `SYSLOG_FACILITY=19` and `PRIORITY=4`. What single byte would a classic RFC 3164 syslog receiver see as the PRI value for this message, and how is it computed?
>
> **Question 2.** You want to prove that the entry really came from PID 48213 running `/usr/bin/logger`, in a forensic investigation. Which of the fields above can you rely on, and which could a hostile process have set to anything it liked?

### Steps (continued)

4. Explore the index instead of grepping text. `-N` lists the field *names* present; `-F` lists the distinct *values* of one field:

```bash
journalctl -N | head -20
journalctl -F _TRANSPORT
```

```
audit
driver
journal
kernel
stdout
syslog
```

5. Now run four queries that a `grep` over `/var/log/syslog` cannot express as cheaply:

```bash
journalctl -u ssh.service -p 3..4 --since "-2h" --no-pager
journalctl _SYSTEMD_UNIT=cron.service _UID=0 -o short-iso
journalctl --facility=local3 --output-fields=MESSAGE,_PID -o json | tail -5
journalctl -k -b -1 -g 'oom|Out of memory'
```

> **Question 3.** `-p 3..4` selected which severities, by name? Why does `journalctl -p 4` on its own return *more* entries than `-p 3..4`?
>
> **Question 4.** `journalctl -g` and `journalctl -t` both narrow the result set. One of them is an indexed lookup and the other is a full scan of the matched entries. Which is which, and what does that imply for a query over 40 GB of journal?
>
> **Question 5.** `_TRANSPORT=stdout` appears in the list. Which kind of log producer lands in the journal through that transport, and what does that tell you about a service that writes to `stdout` and is started by systemd?

---

## Exercise 2 — Retention, disk budget and rate limiting

A journal with default settings is volatile on many distributions (`Storage=auto` keeps it in `/run` unless `/var/log/journal` exists), and it *will* drop messages under a burst. Both behaviours surprise people during their first postmortem.

### Steps

1. Check the current state:

```bash
journalctl --disk-usage
ls -ld /var/log/journal 2>/dev/null || echo "volatile: journal lives in /run/log/journal"
systemd-analyze cat-config systemd/journald.conf | grep -vE '^\s*#|^$'
```

2. Make the journal persistent and bound it explicitly, using a drop-in rather than editing the shipped file:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-drill.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=2G
SystemKeepFree=1G
SystemMaxFileSize=128M
MaxRetentionSec=2week
MaxFileSec=1day
RateLimitIntervalSec=30s
RateLimitBurst=1000
ForwardToSyslog=yes
EOF
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

3. Trigger the rate limiter on purpose and watch journald admit it:

```bash
for i in $(seq 1 5000); do logger -t drill-flood "burst line $i"; done
journalctl -t drill-flood | wc -l
journalctl _COMM=systemd-journald --since "-2min" | grep -i suppress
```

```
Sep 18 09:03:12 node-a systemd-journald[412]: Suppressed 4019 messages from /user.slice/user-1000.slice/session-3.scope
```

4. Rotate and reclaim without restarting the daemon:

```bash
sudo journalctl --rotate
sudo journalctl --vacuum-size=200M
sudo journalctl --vacuum-time=7d
sudo journalctl --verify | tail -3
```

> **Question 6.** Your drop-in sets both `SystemMaxUse=2G` and `SystemKeepFree=1G`, on a `/var` filesystem with 1.4 GB free. How much journal will systemd actually keep, and why?
>
> **Question 7.** The rate limiter suppressed 4019 of 5000 messages. Which scope does `RateLimitBurst` apply to — the host, the unit, or something else — and what is the operational consequence of raising it to `RateLimitBurst=0`?
>
> **Question 8.** You set `ForwardToSyslog=yes` and rsyslog is also running with `imuxsock` enabled. Describe the duplication failure mode this can cause, and the two module settings that resolve it.
>
> **Question 9.** `journalctl --verify` reported `PASS` but you have not run `journalctl --setup-keys`. What exactly was verified, and what additional guarantee would FSS (Forward Secure Sealing) have given you?

---

## Exercise 3 — rsyslog: facilities, severities, selectors, and validating before reload

rsyslog is still the machine-local router in most Linux fleets: it decides what is written where, what is discarded, and what leaves the host. Its classic selector syntax is terse and its defaults are "and everything more severe", which is the single most common misconfiguration in the objective.

### Steps

1. Write a rules file that demonstrates the three filter styles. Note the file is evaluated in lexical order of `/etc/rsyslog.d/*.conf`, so the numeric prefix matters:

```bash
sudo tee /etc/rsyslog.d/30-drill.conf >/dev/null <<'EOF'
# 1. classic selector: this severity AND everything more severe
local3.warning                  /var/log/drill/local3-warn-and-above.log

# 2. exact severity only
local3.=notice                  /var/log/drill/local3-notice-only.log

# 3. everything except one severity
local3.!=debug                  /var/log/drill/local3-no-debug.log

# 4. property-based filter on the message body
:msg, contains, "p99 exceeded"  /var/log/drill/latency.log

# 5. RainerScript: structured condition + explicit stop
if ($syslogfacility-text == "local3") and ($msg contains "SECRET") then {
    action(type="omfile" file="/var/log/drill/redacted.log" template="RSYSLOG_TraditionalFileFormat")
    stop
}
EOF
```

2. **Validate before reloading.** A syntax error in a drop-in can leave rsyslog running with a partial ruleset, or not running at all:

```bash
sudo rsyslogd -N1
```

```
rsyslogd: version 8.2312.0, config validation run (level 1), master config /etc/rsyslog.conf
rsyslogd: End of config validation run. Bye.
```

An error looks like this — note rsyslog gives you a documentation URL per error number:

```
rsyslogd: error during parsing file /etc/rsyslog.d/30-drill.conf, on or before line 14: syntax error on token 'then' [v8.2312.0 try https://www.rsyslog.com/e/2207 ]
```

3. Reload and generate one message at each severity:

```bash
sudo systemctl reload rsyslog
for sev in debug info notice warning err crit; do
  logger -p local3.$sev -t drill "severity test: $sev"
done
wc -l /var/log/drill/local3-*.log
```

```
  3 /var/log/drill/local3-warn-and-above.log
  1 /var/log/drill/local3-notice-only.log
  5 /var/log/drill/local3-no-debug.log
  9 total
```

> **Question 10.** Explain the three counts above line by line. Which messages landed in each file?
>
> **Question 11.** A colleague writes `local3.warning` intending "only warnings" and then files a ticket that the file is "full of noise". Give the one-character fix, and give the selector that would capture *everything* from `local3` regardless of severity.
>
> **Question 12.** The RainerScript block ends in `stop`. What would change, concretely, if you removed it, given rules 1–4 above it and the distribution's own `/etc/rsyslog.d/50-default.conf` below it?
>
> **Question 13.** Filter 4 uses `:msg, contains, "p99 exceeded"`. Why is `$msg contains` evaluated against a *different* string than `$rawmsg`, and when does that difference bite you?

---

## Exercise 4 — Forwarding with a queue that survives the network

Forwarding logs is easy. Forwarding logs *without losing them when the collector is down for 40 minutes* is the actual engineering problem, and it is entirely a queue-configuration problem.

### Steps

1. On the **receiver** (can be the same VM on a spare port), accept TCP syslog and file per host and per program:

```bash
sudo tee /etc/rsyslog.d/10-receiver.conf >/dev/null <<'EOF'
module(load="imtcp" MaxSessions="500")
input(type="imtcp" port="10514" ruleset="remote")

template(name="RemoteFile" type="string"
         string="/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log")

ruleset(name="remote") {
    action(type="omfile"
           dynaFile="RemoteFile"
           dynaFileCacheSize="200"
           createDirs="on"
           fileCreateMode="0640"
           dirCreateMode="0750")
    stop
}
EOF
sudo rsyslogd -N1 && sudo systemctl restart rsyslog
ss -lntp | grep 10514
```

```
LISTEN 0  25  0.0.0.0:10514  0.0.0.0:*  users:(("rsyslogd",pid=51204,fd=7))
```

2. On the **sender**, forward with a disk-assisted memory queue and infinite retry:

```bash
sudo tee /etc/rsyslog.d/90-forward.conf >/dev/null <<'EOF'
action(type="omfwd"
       target="127.0.0.1" port="10514" protocol="tcp"
       template="RSYSLOG_SyslogProtocol23Format"
       action.resumeRetryCount="-1"
       action.resumeInterval="10"
       queue.type="LinkedList"
       queue.filename="fwd_drill"
       queue.spoolDirectory="/var/spool/rsyslog"
       queue.maxDiskSpace="1g"
       queue.highWatermark="8000"
       queue.lowWatermark="2000"
       queue.size="10000"
       queue.saveOnShutdown="on"
       queue.dequeueBatchSize="1000")
EOF
sudo rsyslogd -N1 && sudo systemctl restart rsyslog
logger -p local3.err -t drill "forwarded probe"
cat /var/log/remote/$(hostname)/drill.log
```

```
<155>1 2026-09-18T09:21:44.512883+00:00 node-a drill 52310 - - forwarded probe
```

3. Now break the receiver and prove the queue spools to disk instead of dropping:

```bash
sudo ss -K dport = :10514 2>/dev/null
sudo systemctl stop rsyslog        # on the receiver side
for i in $(seq 1 20000); do logger -p local3.info -t drill "queued $i"; done
ls -lh /var/spool/rsyslog/
```

```
-rw------- 1 root root 1.8M Sep 18 09:24 fwd_drill.00000001
-rw------- 1 root root   84 Sep 18 09:24 fwd_drill.qi
```

4. Bring the receiver back and watch the backlog drain:

```bash
sudo systemctl start rsyslog       # receiver
sleep 20; ls -lh /var/spool/rsyslog/; wc -l /var/log/remote/*/drill.log
```

> **Question 14.** `RSYSLOG_SyslogProtocol23Format` produced `<155>1 ...`. Decode `155` into facility and severity, and name the RFC that defines the `1` immediately after it.
>
> **Question 15.** You removed `queue.filename`. What type of queue remains, and exactly how many messages survive a receiver outage of 40 minutes at 200 msg/s?
>
> **Question 16.** Compare `protocol="udp"`, `protocol="tcp"` and `omrelp` for this forwarder in terms of what is guaranteed on the wire. TCP is connection-oriented — why is it still not an end-to-end delivery guarantee for syslog?
>
> **Question 17.** `queue.saveOnShutdown="on"` costs shutdown time. Describe the data-loss scenario it prevents, and one scenario where it makes a node reboot take unacceptably long.

---

## Exercise 5 — logrotate: `create` versus `copytruncate`, and the dry run that saves you

### Steps

1. Write a rotation policy for the drill logs:

```bash
sudo tee /etc/logrotate.d/drill >/dev/null <<'EOF'
/var/log/drill/*.log {
    daily
    rotate 14
    dateext
    dateformat -%Y%m%d
    missingok
    notifempty
    compress
    delaycompress
    create 0640 root adm
    sharedscripts
    postrotate
        /usr/bin/systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
    endscript
}
EOF
```

2. Dry-run it. `-d` implies debug **and** makes no changes and does not update the state file:

```bash
sudo logrotate -d /etc/logrotate.d/drill
```

```
reading config file /etc/logrotate.d/drill
Allocating hash table for state file, size 64 entries
Handling 1 logs
rotating pattern: /var/log/drill/*.log  after 1 days (14 rotations)
empty log files are not rotated, old logs are removed
considering log /var/log/drill/latency.log
  Now: 2026-09-18 09:31
  Last rotated at 2026-09-18 00:00
  log does not need rotating (log has already been rotated)
```

3. Force a rotation and read the real actions:

```bash
sudo logrotate -v -f /etc/logrotate.d/drill
ls -l /var/log/drill/
sudo grep drill /var/lib/logrotate/logrotate.status   # RHEL: /var/lib/logrotate/logrotate.status
```

```
renaming /var/log/drill/latency.log to /var/log/drill/latency.log-20260918
creating new /var/log/drill/latency.log mode = 0640 uid = 0 gid = 4
running postrotate script
```

4. Reproduce the classic failure. Start a writer that holds the file descriptor and never reopens, then rotate under it:

```bash
( while true; do echo "$(date -Is) tick" >> /var/log/drill/stubborn.log; sleep 1; done ) &
WRITER=$!
sudo logrotate -f /etc/logrotate.d/drill
ls -l /proc/$WRITER/fd | grep drill
tail -1 /var/log/drill/stubborn.log
```

```
lrwx------ 1 root root 64 Sep 18 09:34 3 -> /var/log/drill/stubborn.log-20260918 (deleted)
tail: cannot open '/var/log/drill/stubborn.log' for reading: ... (or: file stays empty)
```

5. Switch that one file to `copytruncate` and repeat:

```bash
sudo tee /etc/logrotate.d/drill-stubborn >/dev/null <<'EOF'
/var/log/drill/stubborn.log {
    daily
    rotate 7
    copytruncate
    compress
    missingok
    notifempty
}
EOF
sudo logrotate -f /etc/logrotate.d/drill-stubborn
kill $WRITER
```

6. Confirm what actually triggers logrotate on a modern distro:

```bash
systemctl list-timers logrotate.timer --no-pager
systemctl cat logrotate.timer | grep -A3 '\[Timer\]'
```

> **Question 18.** In step 4 the writer's fd 3 points at a file marked `(deleted)`. Explain the sequence of syscalls that produced that state, and why disk space is *not* reclaimed until the writer exits.
>
> **Question 19.** `copytruncate` fixed it. Name the race condition `copytruncate` introduces, and explain why `delaycompress` exists at all when `compress` is already set.
>
> **Question 20.** The `postrotate` script sends `SIGHUP` to rsyslog and the stanza carries `sharedscripts`. What would happen without `sharedscripts` given the glob `/var/log/drill/*.log` matches six files?
>
> **Question 21.** Why does journald need no logrotate entry, and which mechanism plays the equivalent role for it?

---

## Exercise 6 — Structured logging, Loki and the cardinality trap

Aggregation systems split into two families: **index-everything** (Elasticsearch — any field is queryable, at the cost of a heavy index) and **index-labels-only** (Loki — a small label index plus compressed chunks that are brute-force scanned). Choosing wrong, or labelling wrong, is what makes a logging bill explode.

### Steps

1. Emit structured logs. One JSON object per line — the file as a whole is JSON Lines, not a JSON document:

```bash
sudo tee /usr/local/bin/drill-app >/dev/null <<'EOF'
#!/usr/bin/env bash
routes=(/api/v1/cart /api/v1/checkout /healthz)
levels=(info info info warn error)
while true; do
  r=${routes[$RANDOM % 3]}; l=${levels[$RANDOM % 5]}
  printf '{"ts":"%s","level":"%s","service":"checkout","route":"%s","status":%d,"latency_ms":%d,"trace_id":"%032x","msg":"request completed"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$l" "$r" $(( RANDOM % 2 ? 200 : 502 )) $(( RANDOM % 2000 )) $RANDOM \
    >> /var/log/drill/app.log
  sleep 0.2
done
EOF
sudo chmod +x /usr/local/bin/drill-app
sudo /usr/local/bin/drill-app &
tail -1 /var/log/drill/app.log | jq .
```

A single record, formatted:

```json
{"ts":"2026-09-18T09:41:02.481Z","level":"error","service":"checkout","route":"/api/v1/checkout","status":502,"latency_ms":1843,"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","msg":"request completed"}
```

2. Run Loki and point a collector at the file:

```bash
docker run -d --name loki -p 3100:3100 grafana/loki:3.1.1
curl -s http://localhost:3100/ready
```

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push
    backoff_config:
      min_period: 500ms
      max_period: 5m
      max_retries: 10

scrape_configs:
  - job_name: drill-app
    static_configs:
      - targets:
          - localhost
        labels:
          job: drill
          env: staging
          __path__: /var/log/drill/app.log
    pipeline_stages:
      - json:
          expressions:
            level: level
            ts: ts
            route: route
      - labels:
          level:
      - timestamp:
          source: ts
          format: RFC3339
      - output:
          source: msg
```

> Upstream note: Grafana has put Promtail into maintenance and points new deployments at **Grafana Alloy**, whose `loki.source.file` / `loki.process` components map one-to-one onto the stages above. The exam objective still names Promtail; check the current status on the Loki docs before designing a new fleet.

3. Query with `logcli` (or Grafana's Explore view). Start with a stream selector, then filter, then parse:

```bash
export LOKI_ADDR=http://localhost:3100
logcli query --limit=20 --since=15m '{job="drill"}'
logcli query --limit=20 --since=15m '{job="drill"} |= "502"'
logcli query --limit=20 --since=15m '{job="drill", level="error"} | json | status >= 500'
logcli query --since=15m 'sum by (route) (rate({job="drill", level="error"} [5m]))'
logcli query --since=15m 'quantile_over_time(0.99, {job="drill"} | json | unwrap latency_ms [5m]) by (route)'
```

4. Turn the ratio into an alert rule. Note that inside the block scalar every line — including the bare `/` operator — carries the same indentation, or the YAML document ends early:

```yaml
groups:
  - name: drill-log-alerts
    rules:
      - alert: CheckoutErrorRatioHigh
        expr: |
          sum(rate({job="drill", level="error"} |= "checkout" [5m]))
          /
          sum(rate({job="drill"} [5m]))
          > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "Over 5% of checkout log lines are errors"
          runbook_url: "https://runbooks.example.com/drill/checkout-errors"
```

> **Question 22.** The `labels:` stage promotes `level` but deliberately not `trace_id` or `route`. Estimate the number of streams created if `trace_id` were promoted over a day at 5 req/s, and explain what that does to Loki's index and to ingester memory.
>
> **Question 23.** Rank these three queries by cost over 100 GB of chunks, cheapest first, and say why: `{job="drill"} | json | status>=500`, `{job="drill"} |= "502"`, `{job="drill", level="error"}`.
>
> **Question 24.** A line fails to parse as JSON. What does `| json` put in the result, and what does appending `| __error__=""` do to your `rate()` computation?
>
> **Question 25.** The `timestamp` stage parses `ts` from the payload. Name one concrete incident that this stage prevents, and one new failure mode it introduces when an application's clock is wrong.

---

## Exercise 7 — Elastic Stack: Filebeat ships, Logstash parses, Elasticsearch indexes

### Steps

1. Bring up Elasticsearch and Kibana single-node for the drill:

```bash
docker network create elastic
docker run -d --name es01 --net elastic -p 9200:9200 \
  -e discovery.type=single-node -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms1g -Xmx1g" docker.elastic.co/elasticsearch/elasticsearch:8.15.0
curl -s localhost:9200/_cat/health?v
```

```
epoch      timestamp cluster       status node.total node.data shards pri relo init unassign
1789645... 09:52:31  docker-cluster yellow          1         1      3   3    0    0        1
```

2. A Logstash pipeline for a *non*-JSON legacy log — this is where `grok` earns its keep. The pipeline DSL is not YAML, so it is not tagged as such:

```
input {
  beats { port => 5044 }
}

filter {
  if [log][file][path] =~ "legacy" {
    grok {
      match => { "message" => "%{TIMESTAMP_ISO8601:ts} \[%{LOGLEVEL:level}\] %{DATA:component} - %{NUMBER:latency_ms:int}ms - %{GREEDYDATA:detail}" }
      tag_on_failure => ["_grokparsefailure_legacy"]
    }
    date {
      match => ["ts", "ISO8601"]
      target => "@timestamp"
      timezone => "UTC"
    }
    mutate {
      lowercase => ["level"]
      remove_field => ["ts", "message"]
    }
  }
}

output {
  if "_grokparsefailure_legacy" in [tags] {
    file { path => "/var/log/logstash/unparsed-%{+YYYY.MM.dd}.log" }
  } else {
    elasticsearch {
      hosts => ["http://es01:9200"]
      data_stream => "true"
    }
  }
  stdout { codec => rubydebug }
}
```

3. **Validate the pipeline before restarting the service** — the equivalent of `rsyslogd -N1`:

```bash
/usr/share/logstash/bin/logstash -f /etc/logstash/conf.d/drill.conf --config.test_and_exit
```

```
[INFO ][logstash.runner] Using config.test_and_exit mode. Config Validation Result: OK. Exiting Logstash
Configuration OK
```

4. Ship the JSON file from exercise 6 with Filebeat, parsing NDJSON at the edge so Logstash does no work:

```yaml
filebeat.inputs:
  - type: filestream
    id: drill-app
    enabled: true
    paths:
      - /var/log/drill/app.log
    parsers:
      - ndjson:
          target: ""
          overwrite_keys: true
          add_error_key: true
    fields:
      env: staging
    fields_under_root: true

filebeat.registry.path: /var/lib/filebeat/registry

output.logstash:
  hosts:
    - "localhost:5044"
  ttl: 30s
  pipelining: 2

logging.level: info
```

5. Verify the round trip and watch for the tell-tale parse-failure tag:

```bash
filebeat test config -c /etc/filebeat/filebeat.yml
filebeat test output -c /etc/filebeat/filebeat.yml
curl -s 'localhost:9200/_cat/indices?v&s=index'
curl -s 'localhost:9200/logs-*/_count?q=tags:_grokparsefailure_legacy' | jq .count
```

> **Question 26.** Documents are arriving but `@timestamp` is the ingest time, not the application's `ts`. Which filter is missing or misconfigured, and why does a dashboard over "the last 15 minutes" look correct anyway right up until the first ingest backlog?
>
> **Question 27.** `_grokparsefailure` appears on 30% of documents. Give the ordered diagnostic steps, and name the Logstash filter you would move to if the log format is fixed-delimiter and CPU is the bottleneck.
>
> **Question 28.** Filebeat keeps a registry at `/var/lib/filebeat/registry`. Predict the exact behaviour if you delete it while Filebeat is stopped, and separately if the `filestream` input's `id` is changed.
>
> **Question 29.** Contrast Loki's storage model with Elasticsearch's for this same JSON stream: which one lets you ask "show me every line with `trace_id=4bf92f...` in the last 30 days" without a full scan, and what do you pay for that?

---

## Exercise 8 — Container and Kubernetes logs

In a container, "the log file" is a convention maintained by the runtime, not the application. The application writes to `stdout`/`stderr`; everything after that is the runtime's logging driver.

### Steps

1. Run a noisy container on the default driver and find the file the runtime is really writing:

```bash
docker run -d --name noisy --log-driver json-file \
  --log-opt max-size=10m --log-opt max-file=3 --log-opt compress=true \
  busybox sh -c 'i=0; while true; do i=$((i+1)); echo "{\"seq\":$i,\"msg\":\"hello\"}"; sleep 0.05; done'

docker inspect --format '{{.LogPath}}' noisy
sudo ls -lh "$(docker inspect --format '{{.LogPath}}' noisy)"*
docker logs --since 1m --timestamps noisy | tail -3
```

```
/var/lib/docker/containers/9f1a.../9f1a...-json.log
-rw-r----- 1 root root 6.2M Sep 18 10:02 /var/lib/docker/containers/9f1a.../9f1a...-json.log
```

2. Switch a second container to the journald driver and query it through the journal's index:

```bash
docker run -d --name noisy-jd --log-driver journald --log-opt tag="{{.Name}}" \
  busybox sh -c 'while true; do echo "journald path"; sleep 1; done'
journalctl CONTAINER_NAME=noisy-jd -n 3 -o json | jq -r '.MESSAGE'
docker logs noisy-jd | tail -2
```

3. In Kubernetes, locate the same chain and check the kubelet's own rotation settings:

```bash
kubectl run drill --image=busybox --restart=Never -- sh -c 'echo started; sleep 3600'
kubectl logs drill --timestamps
kubectl logs drill --previous 2>&1 | head -2
sudo ls -l /var/log/pods/default_drill_*/drill/
kubectl get --raw "/api/v1/nodes/$(kubectl get no -o jsonpath='{.items[0].metadata.name}')/proxy/configz" \
  | jq '.kubeletconfig | {containerLogMaxSize, containerLogMaxFiles}'
```

```
{
  "containerLogMaxSize": "10Mi",
  "containerLogMaxFiles": 5
}
```

> **Question 30.** With `--log-driver journald`, `docker logs` still worked. With `--log-driver syslog` it typically does not. What property of a logging driver determines whether `docker logs` can serve from it?
>
> **Question 31.** A pod is `CrashLoopBackOff`, you run `kubectl logs pod`, and you see the logs of the *current*, still-starting container. Which flag shows the crashed one, and what makes those logs disappear permanently?
>
> **Question 32.** `containerLogMaxSize: 10Mi` with 5 files caps a container at ~50 MiB on the node. At 2 MiB/min of output, how long is your `kubectl logs` history — and what is the architectural conclusion for incident response?
>
> **Question 33.** Compare a node-level DaemonSet collector against a per-pod sidecar collector. Give one case where the sidecar is the only option that works.

---

## Exercise 9 — Capstone: "the logs stopped"

At 03:10 an on-call engineer reports that a service's logs vanished from the dashboard, while the service itself is serving traffic normally. Work the chain **from the emitter outward** — the order matters, because each rung eliminates everything below it.

### Steps

1. Is the process still writing at all?

```bash
PID=$(pgrep -f drill-app | head -1)
sudo ls -l /proc/$PID/fd | grep -E 'drill|deleted'
sudo lsof -p $PID | grep -E 'REG.*log'
stat -c '%n size=%s mtime=%y' /var/log/drill/app.log
```

2. Is the local collector accepting, or dropping?

```bash
journalctl _COMM=systemd-journald --since "-30min" | grep -iE 'suppress|missed|rotat'
sudo grep -iE 'imjournal|ratelimit|impstats|action.*suspended|discard' /var/log/syslog | tail -20
ls -lh /var/spool/rsyslog/
```

3. Is the host out of the resource the pipeline needs?

```bash
df -h /var /var/log
df -i /var/log
sudo ausearch -m avc -ts recent 2>/dev/null | tail -5   # or: journalctl -t setroubleshoot -n 5
```

4. Is the shipper stuck on a stale position?

```bash
sudo cat /var/lib/promtail/positions.yaml
curl -s localhost:9080/metrics | grep -E 'promtail_(read_bytes|sent_entries|dropped)_total'
curl -s localhost:3100/loki/api/v1/labels | jq .
```

5. Is the store rejecting the writes?

```bash
docker logs loki 2>&1 | grep -iE 'out of order|too far behind|per-stream rate limit|429'
curl -s 'localhost:9200/_cat/indices?v&health=red'
curl -s 'localhost:9200/_cluster/allocation/explain' | jq -r '.allocate_explanation? // "no unassigned shards"'
```

> **Question 34.** Step 1 shows fd 3 pointing at `/var/log/drill/app.log-20260918 (deleted)` and `app.log` has `size=0` with an mtime of 00:00. Name the root cause and the two independent fixes — one in logrotate, one in the application.
>
> **Question 35.** Step 5 shows Loki returning `429` with `per-stream rate limit exceeded`. Which change in the collector's `labels:` stage most plausibly caused it, and why does adding more Loki ingesters not fix this specific error?
>
> **Question 36.** `df -h` shows 40% used but `df -i` shows 100% inodes used. Explain how a logging pipeline reaches that state and which single directive in exercise 5 prevents it.
>
> **Question 37.** Everything above is green and the logs are still absent from the dashboard. Name the two remaining suspects that none of these commands would have caught.

---

<details>
<summary><b>Answers</b></summary>

**A1.** PRI = `facility * 8 + severity` = `19 * 8 + 4` = **156**, transmitted as `<156>`. Facility 19 is `local3`, severity 4 is `warning`. (In Exercise 4 the value was `155` because that message was `local3.err`: `19 * 8 + 3 = 155`.)

**A2.** Trust the underscore-prefixed fields: `_PID`, `_UID`, `_GID`, `_COMM`, `_EXE`, `_CMDLINE`, `_CAP_EFFECTIVE`, `_SELINUX_CONTEXT`, `_SYSTEMD_UNIT`, `_BOOT_ID`, `_MACHINE_ID`, `_HOSTNAME`. journald derives these from the sending socket's credentials (`SO_PEERCRED` / `SCM_CREDENTIALS`) and the process's cgroup, so the sender cannot forge them. Everything without an underscore — `MESSAGE`, `PRIORITY`, `SYSLOG_IDENTIFIER`, `SYSLOG_FACILITY`, `SYSLOG_PID` — is supplied by the sender and is arbitrary. A process can claim to be `sshd` at priority `emerg`; it cannot claim someone else's `_PID` or `_SYSTEMD_UNIT`.

**A3.** `-p 3..4` is `err` and `warning` only. `-p 4` alone means "warning *and everything more severe*" — i.e. severities 0–4 — so it is a superset: it adds `emerg`, `alert`, `crit` and `err`. A single `-p` value is always a ceiling, never an exact match; only the range form excludes the more severe end.

**A4.** `-t` (`SYSLOG_IDENTIFIER=`) is an indexed field match: journald's per-file hash tables and the entry-array index let it seek to matching entries. `-g` / `--grep` is a PCRE2 regex applied to the `MESSAGE` field of entries that survive the other filters — it must decompress and scan them. Over 40 GB, always narrow with indexed matches (`-u`, `-t`, `_SYSTEMD_UNIT=`, `--since`) *first* and use `-g` as the last stage, or you pay a full decompress of the whole journal.

**A5.** `_TRANSPORT=stdout` means the entry arrived through the pipe systemd attaches to a service's stdout/stderr (`StandardOutput=journal`, the default). Any service that just prints to stdout gets journal integration for free, with trusted `_SYSTEMD_UNIT` attached — which is why "log to stdout" is the correct behaviour for a systemd-managed or containerised service, and why writing your own file inside the unit throws that metadata away.

**A6.** journald honours **both** limits and takes the more restrictive result at all times. `SystemKeepFree=1G` means it must leave 1 GB free on `/var`; with only 1.4 GB free it can use at most ~0.4 GB, far below `SystemMaxUse=2G`. Additionally journald computes an implicit default of 10% of the filesystem capped at 4 GB when unset, and `SystemMaxUse` never overrides `SystemKeepFree` upward.

**A7.** The limit is applied **per service** — journald tracks it per the `_SYSTEMD_UNIT`/cgroup of the sender, so one noisy unit cannot silence the rest of the host. `RateLimitBurst=0` disables rate limiting for all units, which removes the last defence against a log-storm filling `/var`, starving disk I/O and pushing out the entries you actually need through retention limits. In production, prefer raising the burst for the specific unit via a drop-in (`LogRateLimitBurst=` in the *service* unit) over disabling it globally.

**A8.** `ForwardToSyslog=yes` makes journald copy every entry to the syslog socket; `imuxsock` makes rsyslog read `/dev/log` directly. A message sent to `/dev/log` can then be recorded twice — once from the socket, once from journald's forward — doubling file size and skewing any count-based alerting. Resolve it by picking exactly one path: either `module(load="imuxsock" SysSock.Use="off")` plus `module(load="imjournal" StateFile="imjournal.state")` (journal is the single source), or keep `imuxsock` and set `ForwardToSyslog=no` in `journald.conf`.

**A9.** Without FSS, `--verify` checks internal consistency only: the hash/checksum of each object, the entry arrays and the file structure — it detects corruption (bad blocks, truncation, a crashed write). It does **not** detect deliberate tampering, because an attacker with root can recompute those hashes. `journalctl --setup-keys` establishes Forward Secure Sealing: a sealing key that evolves over time, kept on the host, and a verification key kept off-host. After that, `--verify --verify-key=...` proves that entries written *before* a compromise have not been altered, because the attacker no longer possesses the past keys.

**A10.**
- `local3-warn-and-above.log` → 3 lines: `warning`, `err`, `crit` (severity ≤ 4).
- `local3-notice-only.log` → 1 line: `notice` (`=` pins the exact severity).
- `local3-no-debug.log` → 5 lines: everything emitted except `debug`.

**A11.** Add `=`: `local3.=warning`. To capture every severity of the facility, use `local3.*` (the wildcard), which is equivalent to `local3.debug` given "and more severe" semantics but states the intent explicitly.

**A12.** `stop` discards the message so no later rule sees it. Without it, the message continues down the ruleset and will also be matched by the distribution's `50-default.conf` — typically landing in `/var/log/syslog` or `/var/log/messages`. For a rule whose purpose is to route content containing `SECRET` into a restricted file, omitting `stop` means the secret is *also* written to the world-readable general log: the redaction rule silently accomplishes nothing.

**A13.** `$rawmsg` is the message exactly as received, including the `<PRI>` header, timestamp, hostname and tag. `$msg` is only the MSG part after the header has been parsed — and note it usually retains the leading space that syslog puts after the tag. So `:msg, contains, "p99"` will not match a hostname, but a filter written against `$rawmsg` might match a *different host's name* appearing in the header, and `:msg, isequal, "text"` fails surprisingly often because of that leading space. Prefer `contains`/`regex` on `$msg`, or `startswith` only when you have accounted for the space.

**A14.** `155` = `19 * 8 + 3` → facility `local3`, severity `err`. The `1` after the PRI is the syslog protocol VERSION field, defined by **RFC 5424** (the structured syslog protocol that replaced the informational RFC 3164 "BSD syslog" format). `RSYSLOG_SyslogProtocol23Format` emits RFC 5424 with ISO 8601 timestamps including timezone, a much better wire format than RFC 3164's ambiguous `Sep 18 09:21:44` with no year and no zone.

**A15.** Without `queue.filename` the queue is purely in-memory (`queue.type="LinkedList"` still, but no disk assistance), bounded by `queue.size="10000"`. At 200 msg/s the queue fills in 50 seconds; everything after that is dropped when the high watermark is reached and the discard policy kicks in. Over 40 minutes you would keep 10 000 messages and lose roughly **470 000**. `queue.filename` + `queue.spoolDirectory` is what makes it *disk-assisted*: memory absorbs bursts, disk absorbs outages up to `queue.maxDiskSpace`.

**A16.**
- **UDP** — fire and forget. Loss is invisible: no retransmission, no acknowledgement, silent truncation above the MTU. Fine only for low-value, high-volume telemetry.
- **TCP** — the kernel guarantees ordered, retransmitted delivery *to the peer's socket buffer*. It does not guarantee the peer's rsyslog dequeued and wrote the message: on a receiver crash, messages sitting in socket and application buffers vanish, and the sender never learns.
- **RELP** (`omrelp`/`imrelp`) — adds an application-level acknowledgement per batch. The sender only removes a message from its queue once the receiver confirms it took responsibility for it, closing exactly the gap TCP leaves.

**A17.** On shutdown, `saveOnShutdown="on"` persists the in-memory portion of the queue to the spool directory, so a planned reboot does not lose the messages that had not yet been forwarded. The cost: with a large backlog (say 1 GB of disk queue plus a full memory queue) the write can take minutes, and systemd will eventually hit `TimeoutStopSec` and `SIGKILL` rsyslog — losing the data anyway *and* delaying the reboot. On nodes with large queues, raise the unit's stop timeout deliberately or accept the loss consciously.

**A18.** logrotate called `rename("app.log", "app.log-20260918")` — which changes the directory entry, not the inode — then `creat()`ed a fresh `app.log` (the `create` directive). The writer's fd 3 still references the *original inode*, now reachable only under the new name; after `rotate 14` eventually unlinks that name, the inode has zero links but a non-zero open count, so the kernel keeps it alive and its blocks allocated until the last descriptor closes. That is why `df` shows a full disk while `du` shows nothing: the space belongs to a file with no name. `lsof +L1` lists exactly these.

**A19.** `copytruncate` copies the file's contents to the rotated name, then calls `truncate(fd, 0)` on the original inode. Anything the writer appends **between the copy and the truncate is lost**, and a writer using `O_APPEND` with a cached offset can leave a sparse hole of NUL bytes at the head of the new file. It is a fallback for processes that cannot be made to reopen — not a default. `delaycompress` exists because compression happens *after* rotation: if the writer has not yet reopened (it is about to get its `SIGHUP`, or it uses `copytruncate`), compressing the just-rotated file immediately would compress a file still being written. `delaycompress` defers compression by one cycle so the file is definitely quiescent.

**A20.** Without `sharedscripts`, the `postrotate` block runs **once per matched file** — six `systemctl kill -s HUP rsyslog.service` calls in a tight loop. Beyond wasted work, repeated HUPs make rsyslog re-read its configuration and reopen all outputs repeatedly, and any rotation that is still in flight can interleave badly. `sharedscripts` collapses it to a single execution after all six files are rotated.

**A21.** journald implements rotation and retention internally — `SystemMaxFileSize`, `MaxFileSec`, `SystemMaxUse`, `MaxRetentionSec` — sealing the active file and starting a new one, then vacuuming old ones. External rotation would corrupt the format. The operator-facing equivalents are `journalctl --rotate`, `--vacuum-size=`, `--vacuum-time=`, `--vacuum-files=`, plus `SIGUSR2` to the daemon for an immediate rotation (and `SIGUSR1` to flush `/run` into `/var/log/journal`).

**A22.** Each distinct label-value combination is one **stream**. At 5 req/s a day is 432 000 requests, each with a unique `trace_id` → up to 432 000 streams, versus a handful for `{job, env, level}`. Loki's index grows with stream count, each stream holds an open chunk in the ingester's memory (chunks are flushed only when full or idle), and queries must merge hundreds of thousands of tiny, badly-compressed chunks. This is the canonical Loki outage: ingester OOM, `per-stream rate limit` and `max streams per user` errors. High-cardinality values belong in the **line**, found with a filter expression, never in a label.

**A23.** Cheapest first:
1. `{job="drill", level="error"}` — pure index lookup; only the matching streams' chunks are fetched.
2. `{job="drill"} |= "502"` — a line filter, but Loki applies it as a fast substring match on compressed chunk contents before any parsing; it fetches all `job=drill` chunks yet does minimal work per line.
3. `{job="drill"} | json | status>=500` — fetches the same chunks *and* JSON-parses every line into labels before comparing. Parsers are the expensive stage.
The rule of thumb: narrow with the stream selector, then line filters (`|=`, `!=`, `|~`), and only then parsers and label filters.

**A24.** The entry is kept but tagged with the internal label `__error__="JSONParserErr"` (plus `__error_details__`), and none of the expected extracted labels exist. In a `rate()` or `sum by (...)` those entries either land in a separate series or vanish from a `by` grouping, silently skewing the metric. `| __error__=""` keeps only lines that parsed cleanly, which makes the metric honest — but you must then alert separately on the *rate of parse errors*, or a format change becomes an invisible data loss.

**A25.** It prevents the "ingest timestamp" incident: when a collector is backed up or restarted, thousands of lines emitted over the past hour are all stamped with the moment they were shipped, collapsing into a single spike on the dashboard and destroying the ordering you need to reconstruct an outage. The new failure mode: with a wrong application clock, entries arrive stamped far in the past or future — Loki rejects out-of-order or too-old entries per stream (`entry too far behind`), and a future-stamped entry becomes invisible on any "last 15 minutes" dashboard until real time catches up.

**A26.** The `date` filter is missing or its `match` pattern does not fit the incoming `ts`, so Elasticsearch falls back to Logstash's own `@timestamp` (event creation time). Dashboards look fine during steady state because ingest lag is a second or two and both timestamps are nearly identical; the illusion breaks the first time a backlog develops, at which point the graph shows the *recovery* rather than the *incident*, and every event in the backlog appears simultaneously. A `_dateparsefailure` tag on the documents is the giveaway.

**A27.** Diagnostics in order: (1) pull one failing raw line — that is why `output { file }` for the failure branch exists, and why `remove_field => ["message"]` must run *after* the failure branch is decided; (2) test the pattern against that exact line in Kibana's Grok Debugger or `logstash -e` with a `stdin` input; (3) check for the usual culprits — an optional field, a multi-word component name eaten by `%{DATA}` greediness, a changed timestamp format, or CRLF line endings; (4) anchor the pattern (`^...$`) and prefer specific patterns (`%{NUMBER}`, `%{WORD}`) over `%{DATA}`/`%{GREEDYDATA}`, which cause catastrophic backtracking. If the format is delimiter-stable, switch to the **`dissect`** filter: it splits on literal delimiters with no regex engine and is typically several times faster.

**A28.** The registry stores, per input, the file identity (device/inode or fingerprint) and the byte offset consumed. Delete it while Filebeat is stopped and, on restart, every matched file is treated as new and re-read from the beginning per `ignore_older`/`prospector` settings — a mass duplicate ingest. Changing the `filestream` input's `id` has the same effect for that input's files, because the registry entries are keyed by input id: this is precisely why the `id` is mandatory for `filestream` and must be treated as immutable once deployed.

**A29.** **Elasticsearch** can answer it without a scan: `trace_id` is an indexed term, so an inverted-index lookup jumps straight to the matching documents regardless of the time range. You pay for that with index size (often larger than the raw logs), heap pressure, mapping management and the operational weight of a distributed search cluster. **Loki** stores only labels in the index; `trace_id` lives in the line, so the same question becomes a brute-force decompress-and-filter over every chunk in the window — cheap at 30 minutes, prohibitive at 30 days. Loki's payoff is dramatically lower storage and operational cost, so the choice is: index-heavy random access (Elasticsearch) versus cheap storage with time-bounded scans (Loki).

**A30.** Whether the driver supports **log reading** as well as writing. `docker logs` is served by the driver's read API, which only `json-file`, `local` and `journald` implement (plus `awslogs`/`gcplogs` in some versions); `syslog`, `fluentd`, `gelf` and friends are write-only, so `docker logs` returns `Error response from daemon: configured logging driver does not support reading`. The practical rule: if you ship off-host with a write-only driver, also keep `local`/`json-file` — or use `journald`, which gives you both the local index and forwarding.

**A31.** `kubectl logs --previous` (`-p`) reads the *previous terminated container instance*. The kubelet keeps exactly one previous instance's log per container; it is deleted when the pod object is deleted, when the node reclaims disk under eviction pressure, when the container restarts again (the previous-previous is gone), or if the pod is rescheduled to another node. That one-generation window is the argument for shipping logs off-node before the crash loop outruns you.

**A32.** ~50 MiB ÷ 2 MiB/min = **about 25 minutes** of history. The conclusion: `kubectl logs` is a debugging convenience, not an incident-response tool. Any investigation that starts more than a few minutes after the event must be served by an aggregation system with independent retention; if you are still relying on `kubectl logs` for postmortems, the pipeline in exercises 6–7 is the missing piece, not a larger `containerLogMaxSize`.

**A33.** A **node-level DaemonSet** (Alloy/Promtail/Fluent Bit reading `/var/log/pods/`) is the default: one collector per node regardless of pod count, no application changes, automatic Kubernetes metadata enrichment, and constant resource overhead. A **sidecar** costs a container per pod and duplicates effort — but it is the only option when the application cannot be made to write to stdout, for example a legacy process that writes several distinct log files inside its own filesystem (an access log and an error log with different formats), or when one tenant needs a wholly different parsing/shipping configuration that a shared node agent cannot express. The common hybrid is a sidecar that merely `tail`s those files to stdout, leaving the shipping to the DaemonSet.

**A34.** Root cause: logrotate renamed the file (`create` mode) and the application never reopened, so it is still appending to the deleted inode — exactly the Exercise 4 reproduction, this time in production. Two independent fixes: **(a)** in logrotate, add a `postrotate` that signals the application to reopen (`kill -HUP`, or the app's own reopen mechanism), or fall back to `copytruncate` for that file; **(b)** in the application, handle `SIGHUP` by closing and reopening its log file — or, better, stop writing files at all and write to stdout, letting systemd/the container runtime own the lifecycle.

**A35.** Most plausibly a high-cardinality label was promoted in the `labels:` stage — `trace_id`, `route` with path parameters, a pod name, a user id — so what used to be a handful of streams became thousands, and per-stream limits (`per_stream_rate_limit`, default in the low MB/s) now apply to streams that each carry a slice of the traffic. Adding ingesters does not help because the limit is **per stream**, not per ingester: the same stream is still owned by one ingester at a time, and the correct fix is to remove the label (keep the field in the line) or, only if the cardinality is genuinely necessary, raise the per-stream limit knowingly.

**A36.** Every rotation with `dateext` creates a new file, and every compressed generation another — multiply that by a wildcard matching hundreds of per-container or per-host log files and you allocate hundreds of thousands of small files, exhausting inodes long before bytes. `rotate 14` (a bounded rotation count) is the directive that prevents it: it is the only thing that ever *deletes* old generations. A policy with `dateext` and no `rotate`/`maxage` grows without bound. `df -i` belongs in every logging-host alert set alongside `df -h`.

**A37.** (1) **The query side** — the dashboard's time range, timezone, or stream selector no longer matches reality: a label was renamed, the panel filters on `job="drill"` while the collector now emits `job="drill-app"`, or the browser is in a different timezone from the data. Nothing on the ingest path would show this. (2) **The emitter's own log level** — the application was deployed with `LOG_LEVEL=error` (or a feature flag turned a code path off), so there genuinely are no lines to collect. Both are found by comparing against a known-good line you emit by hand (`logger -t drill "canary $(date -Is)"`) and following it end to end, which is why a synthetic log canary with an alert on its absence is the one monitor that covers the whole chain at once.

</details>

---

## Official sources

- LPI, *DevOps Tools Engineer exam 701 objectives* — https://www.lpi.org/our-certifications/exam-701-objectives/
- freedesktop.org, `journalctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
- freedesktop.org, `journald.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- freedesktop.org, `systemd-journald.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html
- rsyslog, *Configuration* and *Queues* — https://www.rsyslog.com/doc/configuration/index.html · https://www.rsyslog.com/doc/concepts/queues.html
- IETF, RFC 5424, *The Syslog Protocol* — https://www.rfc-editor.org/rfc/rfc5424
- logrotate upstream — https://github.com/logrotate/logrotate
- Grafana, *Loki documentation* and *LogQL* — https://grafana.com/docs/loki/latest/ · https://grafana.com/docs/loki/latest/query/
- Grafana, *Promtail* (status and Alloy migration) — https://grafana.com/docs/loki/latest/send-data/promtail/
- Elastic, *Logstash* and *Filebeat* references — https://www.elastic.co/guide/en/logstash/current/index.html · https://www.elastic.co/guide/en/beats/filebeat/current/index.html
- Docker, *Configure logging drivers* — https://docs.docker.com/engine/logging/configure/
- Kubernetes, *Logging Architecture* — https://kubernetes.io/docs/concepts/cluster-administration/logging/