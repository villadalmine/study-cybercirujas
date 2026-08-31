# 103.7 — Search text files using regular expressions

**Certification:** LPIC-1 (LPI 101-500 + 102-500), version 5.0
**Exam:** 101-500 · **Topic:** 103 (GNU and Unix Commands) · **Objective:** 103.7
**Weight (platform-normalized):** 4.69
**Key knowledge areas:** create regular expressions containing several notational elements; understand the difference between basic and extended regular expressions; use regular expression tools to search a filesystem or file content.
**Terms and utilities:** `grep`, `egrep`, `fgrep`, `sed`, `regex(7)`

---

## 1. Motivation: regular expressions are a production control plane, not a text-editing convenience

The exam frames 103.7 as "find text in files". That framing is 30 years old and it is why engineers under-invest in this objective and then get paged by it. In a modern platform, a regular expression is **executable configuration on the hot path of every observability and routing decision you make**. Consider where a regex is evaluated in a typical Kubernetes platform:

| Layer | Component | What the regex decides | Evaluation rate | Blast radius when wrong |
|---|---|---|---|---|
| Log collection | Fluent Bit / Vector / Promtail parser | Whether a log line becomes structured fields or is dropped as unparsable | Once per log line — 10⁴–10⁶ lines/s per node | Silent log loss; CPU saturation of the DaemonSet; node-level backpressure |
| Log query | Loki `|~`, LogQL `line_format` | Which lines answer an incident query | Per query, over TB of chunks | Wrong incident conclusion; query timeouts |
| Metrics discovery | Prometheus `relabel_configs.regex` | Which targets are scraped and how labels are built | Once per SD refresh, per target | Whole tiers of targets silently unscraped — dashboards go blank, alerts never fire |
| Metrics ingestion | `metric_relabel_configs` | Which series are kept | Per scrape, per series | Cardinality explosion → TSDB OOM |
| Alert routing | Alertmanager `matchers` (`=~`) | Which team gets paged | Per alert | Pages routed to the wrong on-call, or to nobody |
| Ingress | NGINX `location ~`, Envoy `safe_regex` | Which backend serves a request | Per request | Traffic misrouting; RE2 program-size rejections at config load |
| CI/CD | `grep`-based policy gates | Whether a commit merges | Per pipeline | Secrets merged to `main` |
| Auth/audit | `auditd`, `rsyslog` filters, `sudoers` command matching | What is recorded, what is permitted | Per syscall / per message | Audit blind spots |

Every one of these is a *different regex engine with different syntax and different failure semantics*, and the operator writing them is usually validating with `grep` on a laptop. That mismatch is the architectural problem this objective actually protects you from.

### 1.1 Failure mode #1 — the log pipeline that ate a node (catastrophic backtracking)

A team adds a parser for a new service. The regex is a plausible-looking:

```
^(?<ts>\S+)\s+(?<level>\w+)\s+(\[(?<thread>[^\]]*)\]\s*)*(?<msg>.*)$
```

The nested `( ... )*` around a group that can itself match the empty string turns a *non-matching* line into exponential work in any backtracking engine. Fluent Bit uses **Onigmo** (a backtracking engine). Log lines that *do* match cost microseconds; the 0.1 % of lines that do not — a truncated line, a stack-trace continuation — cost seconds each. The DaemonSet pod pins a core, the input buffer fills, `Mem_Buf_Limit` is reached, and Fluent Bit **drops** records with `[warn] [input] emitter.4 paused`. You lose exactly the logs from the incident that produced the malformed lines.

`grep -E` would have found the same regex instantly non-matching, because GNU `grep`'s primary matcher is a **DFA** — it cannot backtrack. Testing with the wrong engine proved nothing.

### 1.2 Failure mode #2 — the anchoring mismatch

```yaml
- source_labels: [__meta_kubernetes_pod_label_app]
  regex: api          # intent: "keep anything whose app label contains api"
  action: keep
```

In `grep`, `api` matches `payments-api`. In Prometheus, **`regex` is implicitly anchored at both ends** (`^(?:api)$`), so `payments-api` is dropped and the tier stops being scraped. There is no error, no warning, no metric. `up` simply stops existing for those targets, and alerts based on `absent()` are usually the only thing that catches it — if someone wrote them.

The inverse trap exists in Alertmanager (`=~` is anchored) and *not* in Loki (`|~` is unanchored). Same YAML file, three anchoring rules.

### 1.3 Failure mode #3 — the locale

```bash
$ grep -c '[a-z]' names.txt      # LANG=en_US.UTF-8
```
POSIX declares the behaviour of ranges outside the C locale **unspecified**; glibc orders them by *collation*, so `[a-z]` can match characters you never intended, and multibyte decoding makes the same search 3–10× slower. The portable, fast and correct form is `[[:lower:]]` and, for byte-oriented log scanning, `LC_ALL=C`.

### 1.4 The engineering rule this objective teaches

> Write the smallest regex that cannot backtrack, in the syntax of the engine that will actually run it, and validate it against a golden corpus of both matching and **non-matching** inputs — in that engine.

Everything below is the mechanics needed to do that.

---

## 2. The regular expression model

### 2.1 Two POSIX dialects, and why they are incompatible in both directions

POSIX defines **BRE** (Basic Regular Expressions, `grep`/`sed` default) and **ERE** (Extended, `grep -E`/`sed -E`/`awk`). They are not "ERE is BRE plus features": several characters are *special in one and literal in the other*, which means a pattern can be silently valid in both and mean different things.

| Construct | BRE | ERE | Notes |
|---|---|---|---|
| Any character | `.` | `.` | Never matches NUL in `grep` unless `-z`; matches newline only where the tool presents newlines (`sed -z`, `grep -z`) |
| Bracket expression | `[abc]`, `[^abc]`, `[a-z]` | same | `]` first is literal (`[]abc]`), `-` last is literal (`[abc-]`), `^` first negates |
| Character class | `[[:digit:]]` | `[[:digit:]]` | Only valid **inside** brackets |
| Anchors | `^` `$` | `^` `$` | **BRE:** special only at start/end of the RE or subexpression; literal elsewhere. **ERE:** always special |
| Zero or more | `*` | `*` | BRE: literal when it is the first character of an RE or subexpression |
| One or more | `\+` *(GNU ext.)* | `+` | Plain `+` in BRE is a literal plus |
| Zero or one | `\?` *(GNU ext.)* | `?` | Plain `?` in BRE is a literal question mark |
| Interval | `\{n,m\}` | `{n,m}` | Portable ceiling `RE_DUP_MAX` = 255 |
| Grouping | `\(` `\)` | `(` `)` | Plain parens in BRE are literal parens |
| Alternation | `\|` *(GNU ext.)* | `|` | **POSIX BRE has no alternation at all** |
| Back-reference | `\1` … `\9` | `\1` … `\9` *(GNU ext.)* | Undefined in POSIX ERE; forces the backtracking engine — see §2.4 |
| Escape of ordinary char | `\.` `\$` | `\.` `\$` | Escaping a *non-special* ordinary character is undefined in ERE |

**The inversion trap in one line:** `(` `)` `{` `}` `|` `+` `?` are literals in BRE and metacharacters in ERE. `\(` `\)` `\{` `\}` `\|` `\+` `\?` are metacharacters in BRE and undefined/literal in ERE.

```bash
$ echo 'a+b' | grep -c 'a+b'      # BRE: '+' is literal → match
1
$ echo 'a+b' | grep -c -E 'a+b'   # ERE: 'a+' is "one or more a" → no match
0
```

### 2.2 POSIX character classes (locale-aware, portable, always correct)

| Class | Equivalent (C locale) | Use it instead of |
|---|---|---|
| `[[:alpha:]]` | `[A-Za-z]` | `[a-zA-Z]` |
| `[[:digit:]]` | `[0-9]` | `\d` (not POSIX) |
| `[[:alnum:]]` | `[0-9A-Za-z]` | `\w` (GNU adds `_`) |
| `[[:upper:]]` / `[[:lower:]]` | `[A-Z]` / `[a-z]` | ranges that break under collation |
| `[[:space:]]` | space, tab, NL, VT, FF, CR | `\s` (not POSIX) |
| `[[:blank:]]` | space, tab only | `[ \t]` |
| `[[:punct:]]` | printable, non-alnum, non-space | hand-rolled sets |
| `[[:xdigit:]]` | `[0-9A-Fa-f]` | — |
| `[[:cntrl:]]` / `[[:print:]]` / `[[:graph:]]` | control / printable / printable-non-space | — |

Nesting is required: `[[:digit:]]` is a class inside a bracket expression. `[[:digit:].-]` = digits, dot, hyphen.

### 2.3 GNU extensions you will use daily (and that will not port)

| Extension | Meaning | Available in |
|---|---|---|
| `\b` / `\B` | word boundary / non-boundary | GNU grep, GNU sed, gawk (`\y`), PCRE |
| `\<` / `\>` | start / end of word | GNU grep, GNU sed |
| `\w` / `\W` | `[_[:alnum:]]` / complement | GNU grep, GNU sed |
| `\s` / `\S` | `[[:space:]]` / complement | GNU grep, GNU sed |
| `\|` `\+` `\?` in BRE | alternation, +, ? | GNU |
| `\`` / `\'` | buffer start / end (distinct from `^`/`$`) | GNU sed |
| `-P` | switch to PCRE2 entirely | GNU grep, built with PCRE |

None of `\b \w \s \d` are POSIX. In a `Makefile`, a container `sh`, a BSD box, or busybox, they may be literal `b`, `w`, `s`, `d`.

### 2.4 The engine landscape — the single most operationally important table in this objective

| Engine | Used by | Syntax | Back-refs | Look-around | Worst case | Anchoring |
|---|---|---|---|---|---|---|
| GNU DFA (+ glibc fallback) | `grep`, `grep -E`, `egrep` | BRE / ERE + GNU ext. | yes (falls back to backtracking) | no | **O(n·m)** without back-refs | unanchored |
| glibc `regexec` | `sed`, `awk` (mawk/BWK), many C programs | BRE / ERE | yes | no | can degrade superlinearly | unanchored |
| gawk DFA | `gawk` | ERE + `\y` `\s` | no | no | linear | unanchored |
| Aho–Corasick / Boyer–Moore | `grep -F`, `fgrep` | **literal only** | n/a | n/a | linear, ~GB/s | unanchored |
| PCRE2 | `grep -P`, `journalctl -g`, nginx (PCRE), PHP | Perl | yes | yes | **exponential** (guarded by a match limit) | unanchored |
| Onigmo | Fluent Bit, Ruby | Perl-ish, `(?<name>…)` | yes | yes | **exponential, unguarded** | unanchored |
| RE2 | Prometheus, Alertmanager, Loki, Envoy, Go `regexp` | RE2 syntax, `(?P<name>…)` | **no** | **no** | linear, memory-bounded | **anchored** in Prometheus/Alertmanager; **unanchored** in Loki `|~` |
| Rust `regex` | ripgrep, Vector | RE2-like | no | no | linear | unanchored |

Two consequences you must internalize:

1. **`grep -E` cannot prove a Fluent Bit / nginx / Python regex is safe.** Different engine class. It *can* prove syntax intent for POSIX-ish patterns.
2. **RE2-family engines reject constructs, they do not slow down.** A back-reference or look-ahead in a Prometheus `regex` is a config-load error, not a performance problem. This is a feature: it makes ReDoS structurally impossible in the metrics control plane.

Reference: Russ Cox, *Regular Expression Matching Can Be Simple And Fast* — https://swtch.com/~rsc/regexp/regexp1.html

### 2.5 Greediness, and why `.*` is an anti-pattern in parsers

POSIX requires the **leftmost-longest** match. `.*` therefore consumes to end-of-line and gives back only as much as needed.

```bash
$ echo '"GET /api/v2/orders HTTP/1.1" 200' | grep -oE '".*"'
"GET /api/v2/orders HTTP/1.1"
$ echo 'a"b"c"d"e' | grep -oE '".*"'
"b"c"d"
$ echo 'a"b"c"d"e' | grep -oE '"[^"]*"'
"b"
"d"
```

In log parsers, the correct field pattern is almost always a **negated bracket expression** (`[^"]*`, `[^ ]*`, `[^\]]*`), never `.*?`. It is faster (no backtracking), portable (lazy quantifiers are not POSIX), and unambiguous.

---

## 3. The tools

### 3.1 `grep` — the option surface that matters in production

| Option | Effect | Production use |
|---|---|---|
| `-E` / `-F` / `-G` / `-P` | ERE / fixed strings / BRE (default) / PCRE2 | `-F` for IOC and blocklist matching; `-P` only when you truly need look-around |
| `-e PAT` | pattern as an argument | mandatory when the pattern starts with `-` |
| `-f FILE` | read patterns, one per line | `-F -f iocs.txt` with 50 k patterns is still ~linear |
| `-i` `-w` `-x` `-v` | ignore case / whole word / whole line / invert | `-w` prevents `10.0.0.1` matching `110.0.0.10` |
| `-c` `-l` `-L` `-o` `-m N` | count / files-with / files-without / only-matching / stop after N | `-m1 -l` on huge files short-circuits |
| `-n` `-H` `-h` `-b` `-Z` | line no. / with-filename / no-filename / byte offset / NUL after filename | `-Z` + `xargs -0` for paths with spaces |
| `-A N` `-B N` `-C N` | after / before / context | stack traces |
| `-r` / `-R` | recursive (**`-r` does not follow symlinks** except CLI args) / recursive following all symlinks | `-r` by default; `-R` risks loops |
| `--include=GLOB` `--exclude=GLOB` `--exclude-dir=GLOB` | path filtering | `--exclude-dir=.git --exclude-dir=vendor` |
| `-I` / `-a` / `--binary-files=text` | skip binaries / treat as text | logs containing NUL from a torn write |
| `-z` / `--null-data` | input records are NUL-separated | with `find -print0`; also makes `.` span newlines |
| `--line-buffered` | flush per line | **required** in `tail -f | grep … | while read` |
| `-q` | quiet, exit at first match | conditionals; see the SIGPIPE note in §6 |
| `-s` | suppress file-error messages | do not use while debugging — it hides permission problems |

**`egrep` and `fgrep` are obsolescent.** GNU grep 3.8 (2022) made them emit `egrep: warning: egrep is obsolescent; using grep -E`. LPIC-1 v5.0 still names them, so know them; in code, always write `grep -E` / `grep -F`.

### 3.2 `sed` — a line editor whose addresses are regular expressions

Structure: `sed [-n] [-E] [-i[SUFFIX]] [-z] 'ADDRESS COMMAND' file…`

| Address form | Meaning |
|---|---|
| `/re/` | lines matching `re` |
| `\%re%` | same, alternate delimiter (for paths) |
| `N` , `$` | line N, last line |
| `addr1,addr2` | inclusive range, re-armable |
| `0,/re/` | **GNU:** range ending at the *first* match, even on line 1 — the correct "first occurrence only" idiom |
| `addr,+N` / `addr,~N` | N more lines / until line divisible by N (GNU) |
| `first~step` | every `step`-th line from `first` (GNU) |
| `addr!` | negation |

Substitution: `s/re/replacement/FLAGS`

| Flag | Meaning |
|---|---|
| `g` | all occurrences on the line |
| `N` | the N-th occurrence; `Ng` = N-th onward |
| `p` | print (pair with `-n`) |
| `w file` | write matching lines to file |
| `I` / `i` | case-insensitive match (GNU) |
| `M` / `m` | multiline: `^`/`$` match at embedded newlines (GNU) |
| `e` | execute the result as a shell command (GNU) — **never** on untrusted input |

In the replacement: `&` = whole match, `\1`…`\9` = groups, `\n` = newline, and GNU adds `\U \L \u \l \E` for case conversion. An empty regex `s//x/` reuses the last regex — which is why `0,/ERROR/s//FIRST/` works.

**`sed` is line-oriented.** The pattern space holds one line; `^` and `$` are the line's edges. To match across lines you must build a multi-line pattern space with `N`, `H`/`G`, or use `-z` (NUL-separated records → the whole file is one record).

Portability: GNU `sed -i` takes an optional suffix attached (`-i.bak`); BSD `sed -i` **requires** an argument (`-i ''`). `-E` is the portable extended flag (standardized in POSIX Issue 8; GNU accepts `-r` as a synonym).

### 3.3 Tool selection

| Task | Right tool | Why |
|---|---|---|
| Does this literal string exist? | `grep -F` | no regex parsing; Boyer–Moore |
| Match one of 50 000 literals | `grep -F -f list.txt` | Aho–Corasick, one pass |
| Structured field extraction, one line at a time | `grep -oE` or `sed -E 's/…/\1/'` | no state needed |
| Field extraction with arithmetic/aggregation | `awk` | ERE + numeric context in one pass |
| Edit in place across a repo | `sed -E -i` driven by `grep -rlZ` | change only files that match |
| Cross-line correlation | `awk` (hold state) or `sed -z` | line orientation is the constraint |
| Search a large source tree | `rg` (ripgrep) if available, else `grep -r --exclude-dir` | gitignore-aware, parallel, linear-time engine |
| Search the journal | `journalctl -g PATTERN` | PCRE2, indexed, no `journalctl | grep` cost |
| Search rotated/compressed logs | `zgrep` / `xzgrep` / `zstdgrep` | avoids a decompression temp file |

---

## 4. Infrastructure manifests — where these regexes actually run

The following are complete, deployable manifests. They are the "production" half of this objective: the same syntax you practice with `grep` is what you commit here.

### 4.1 Fluent Bit — regex parsers (Onigmo), the backtracking-sensitive layer

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: observability
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
  name: fluent-bit-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit-read
subjects:
  - kind: ServiceAccount
    name: fluent-bit
    namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: observability
  labels:
    app.kubernetes.io/name: fluent-bit
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush                     1
        Daemon                    Off
        Log_Level                 info
        Parsers_File              parsers.conf
        HTTP_Server               On
        HTTP_Listen               0.0.0.0
        HTTP_Port                 2020
        Health_Check              On
        storage.path              /var/log/flb-storage/
        storage.sync              normal
        storage.checksum          off
        storage.backlog.mem_limit 64M

    [INPUT]
        Name                tail
        Tag                 kube.*
        Path                /var/log/containers/*.log
        Exclude_Path        /var/log/containers/*fluent-bit*.log
        multiline.parser    cri
        DB                  /var/log/flb_kube.db
        DB.locking          true
        Mem_Buf_Limit       32MB
        Skip_Long_Lines     On
        Skip_Empty_Lines    On
        Refresh_Interval    10
        storage.type        filesystem

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        Merge_Log_Key       log_processed
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On
        Labels              On
        Annotations         Off
        Buffer_Size         256k

    # Structured extraction for the ingress tier. If the parser fails the record
    # is passed through untouched (Reserve_Data On) instead of being dropped.
    [FILTER]
        Name                parser
        Match               kube.var.log.containers.ingress-nginx*
        Key_Name            log
        Parser              nginx_combined
        Reserve_Data        On
        Preserve_Key        Off

    [FILTER]
        Name                parser
        Match               kube.var.log.containers.orders-api*
        Key_Name            log
        Parser              app_json_fallback_plain
        Reserve_Data        On
        Preserve_Key        On

    # Drop kube-probe noise before it costs storage. The regex here is Onigmo,
    # unanchored, applied to the value of the named key.
    [FILTER]
        Name                grep
        Match               kube.*
        Exclude             agent   ^kube-probe/

    [FILTER]
        Name                grep
        Match               kube.*
        Exclude             path    ^/(healthz|readyz|livez)$

    # Redact anything that looks like a bearer token or an AWS access key id
    # before the record leaves the node.
    [FILTER]
        Name                modify
        Match               kube.*
        Condition           Key_Value_Matches log (?i)(authorization|bearer|AKIA[0-9A-Z]{16})
        Set                 redacted true

    [OUTPUT]
        Name                loki
        Match               kube.*
        Host                loki-gateway.observability.svc.cluster.local
        Port                80
        Labels              job=fluent-bit
        Label_Keys          $kubernetes['namespace_name'],$kubernetes['container_name'],$level
        Remove_Keys         kubernetes,stream
        Line_Format         json
        Auto_Kubernetes_Labels Off
        Retry_Limit         5

  parsers.conf: |
    # ---------------------------------------------------------------------
    # Every field is a NEGATED bracket expression, never `.*`.
    # There is no nested quantifier anywhere in this file. That is the rule
    # that keeps Onigmo linear on non-matching input.
    # ---------------------------------------------------------------------
    [PARSER]
        Name        nginx_combined
        Format      regex
        Regex       ^(?<remote>[^ ]*) (?<host>[^ ]*) (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>[A-Z]+) (?<path>[^ ]*) (?<proto>[^"]*)" (?<code>[0-9]{3}) (?<size>[0-9-]+) "(?<referer>[^"]*)" "(?<agent>[^"]*)"$
        Time_Key    time
        Time_Format %d/%b/%Y:%H:%M:%S %z
        Time_Keep   On
        Types       code:integer size:integer

    [PARSER]
        Name        app_json_fallback_plain
        Format      regex
        Regex       ^(?<time>[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+) +(?<level>[A-Z]+) +\[(?<service>[^\]]*)\] +(?<logger>[^ ]+) - (?<message>.*)$
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%LZ
        Time_Keep   On

    [PARSER]
        Name        cri
        Format      regex
        Regex       ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[FP]) (?<message>.*)$
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L%z

    [MULTILINE_PARSER]
        Name          java_stacktrace
        Type          regex
        Flush_Timeout 1000
        # state  name      regex                                  next_state
        Rule      "start_state"  "/^[0-9]{4}-[0-9]{2}-[0-9]{2}T/"  "cont"
        Rule      "cont"         "/^[\t ]+(at |\.{3}|Caused by:)/" "cont"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: observability
  labels:
    app.kubernetes.io/name: fluent-bit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fluent-bit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fluent-bit
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "2020"
        prometheus.io/path: "/api/v1/metrics/prometheus"
    spec:
      serviceAccountName: fluent-bit
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 30
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 2020
              protocol: TCP
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              # A hard CPU limit is the containment boundary for a backtracking
              # parser: it converts "node CPU starvation" into "throttled
              # collector", which is observable via container_cpu_cfs_throttled.
              cpu: "1"
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /api/v1/health
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/fluent-bit.conf
              subPath: fluent-bit.conf
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc/parsers.conf
              subPath: parsers.conf
              readOnly: true
            - name: varlog
              mountPath: /var/log
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: flb-storage
              mountPath: /var/log/flb-storage
      volumes:
        - name: config
          configMap:
            name: fluent-bit-config
        - name: varlog
          hostPath:
            path: /var/log
            type: Directory
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
            type: DirectoryOrCreate
        - name: flb-storage
          hostPath:
            path: /var/log/flb-storage
            type: DirectoryOrCreate
```

### 4.2 Prometheus — RE2, fully anchored, and the cardinality guard

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: observability
data:
  prometheus.yml: |
    global:
      scrape_interval:     30s
      scrape_timeout:      10s
      evaluation_interval: 30s
      external_labels:
        cluster: prod-eu-west-1

    rule_files:
      - /etc/prometheus/rules/*.yaml

    scrape_configs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          # `regex` is anchored: this is ^(?:true)$ — it will NOT match "True".
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true

          # (.+) means "the annotation exists and is non-empty".
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)

          # Two capture groups joined in `replacement`. The optional (?::\d+)?
          # strips an existing port from __address__.
          - source_labels:
              - __address__
              - __meta_kubernetes_pod_annotation_prometheus_io_port
            action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__

          # Promote every pod label to a metric label, sanitising invalid
          # characters. labelmap matches against LABEL NAMES, not values.
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)

          - source_labels: [__meta_kubernetes_namespace]
            action: replace
            target_label: namespace

          - source_labels: [__meta_kubernetes_pod_name]
            action: replace
            target_label: pod

          # Never scrape the sandbox/init containers.
          - source_labels: [__meta_kubernetes_pod_container_name]
            action: drop
            regex: (istio-init|linkerd-init|POD)

          # Anchoring in practice: to express "contains api" you must write it.
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            action: keep
            regex: .*api.*

        metric_relabel_configs:
          # Cardinality guard: drop known-explosive series at ingestion.
          - source_labels: [__name__]
            action: drop
            regex: (container_tasks_state|container_memory_failures_total|apiserver_request_duration_seconds_bucket)

          # Drop any label whose VALUE looks like a UUID or a k8s pod suffix,
          # by rewriting it to a bounded form.
          - source_labels: [pod]
            target_label: workload
            regex: (.+?)-[0-9a-f]{8,10}-[a-z0-9]{5}
            replacement: $1
            action: replace

      - job_name: fluent-bit
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [observability]
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            action: keep
            regex: fluent-bit
          - source_labels: [__address__]
            action: replace
            regex: ([^:]+)(?::\d+)?
            replacement: $1:2020
            target_label: __address__
          - target_label: __metrics_path__
            replacement: /api/v1/metrics/prometheus
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-rules
  namespace: observability
data:
  regex-health.yaml: |
    groups:
      - name: regex-control-plane
        interval: 30s
        rules:
          # The alert that catches Failure Mode #2 from section 1.2.
          - alert: ScrapeTierDisappeared
            expr: absent(up{job="kubernetes-pods", namespace="prod"} == 1)
            for: 10m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "No healthy targets in job kubernetes-pods/prod"
              description: >-
                Every target vanished from service discovery. The usual cause is
                a relabel_configs `regex:` that is implicitly anchored and no
                longer matches the label values it used to match.
              runbook_url: https://runbooks.example.com/prometheus/relabel-anchoring

          # The alert that catches Failure Mode #1 from section 1.1.
          - alert: LogParserCPUSaturation
            expr: |
              rate(container_cpu_usage_seconds_total{container="fluent-bit"}[5m]) > 0.9
              and
              rate(fluentbit_input_records_total[5m]) < 100
            for: 5m
            labels:
              severity: warning
              team: observability
            annotations:
              summary: "Fluent Bit burning CPU while ingesting almost nothing"
              description: >-
                High CPU with low record throughput is the signature of
                catastrophic backtracking in a parser regex. Check the most
                recently changed [PARSER] block.

          - alert: LogRecordsDropped
            expr: rate(fluentbit_output_dropped_records_total[5m]) > 0
            for: 2m
            labels:
              severity: critical
              team: observability
            annotations:
              summary: "Fluent Bit is dropping records — log loss in progress"
```

### 4.3 Alertmanager — `matchers` with `=~` (anchored RE2)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: observability
type: Opaque
stringData:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m

    route:
      receiver: platform-slack
      group_by: [alertname, cluster, namespace]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        # `=~` is ANCHORED. "prod-.*" matches prod-eu and prod-us, but plain
        # "prod" would match ONLY the exact string "prod".
        - matchers:
            - severity =~ "critical|page"
            - namespace =~ "prod-.*"
          receiver: pagerduty-sre
          continue: false

        # Negated regex matcher.
        - matchers:
            - namespace !~ "(dev|staging|sandbox)-.*"
            - severity = "warning"
          receiver: platform-slack

        - matchers:
            - team = "observability"
          receiver: observability-slack

    inhibit_rules:
      - source_matchers:
          - severity = "critical"
        target_matchers:
          - severity =~ "warning|info"
        equal: [alertname, cluster, namespace]

    receivers:
      - name: platform-slack
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/slack-url
            channel: '#platform-alerts'
            send_resolved: true
            title: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

      - name: observability-slack
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/slack-url
            channel: '#observability'
            send_resolved: true

      - name: pagerduty-sre
        pagerduty_configs:
          - routing_key_file: /etc/alertmanager/secrets/pd-key
            severity: critical
            description: '{{ .CommonLabels.alertname }} in {{ .CommonLabels.namespace }}'
```

### 4.4 Promtail / Loki — RE2 named captures, unanchored

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: observability
data:
  promtail.yaml: |
    server:
      http_listen_port: 3101
      grpc_listen_port: 0

    positions:
      filename: /run/promtail/positions.yaml

    clients:
      - url: http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push
        tenant_id: prod

    scrape_configs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        pipeline_stages:
          - cri: {}

          # RE2 named groups use (?P<name>...). Unanchored: this matches
          # anywhere in the line unless you write ^ yourself.
          - regex:
              expression: '^(?P<ip>[^ ]+) [^ ]+ [^ ]+ \[(?P<ts>[^\]]+)\] "(?P<method>[A-Z]+) (?P<path>[^ ]+) [^"]*" (?P<status>\d{3}) (?P<bytes>[0-9-]+)'

          - labels:
              method:
              status:

          # Bound cardinality: collapse numeric path segments BEFORE labelling.
          - replace:
              expression: '(/[0-9a-f]{8,}|/\d+)'
              replace: '/:id'
              source: path

          - timestamp:
              source: ts
              format: 02/Jan/2006:15:04:05 -0700

          - metrics:
              http_5xx_total:
                type: Counter
                description: "5xx responses parsed from the ingress log"
                source: status
                config:
                  action: inc
                  match_all: false
                  value: ""
                  # This is an RE2 match against the captured status value.
          - match:
              selector: '{namespace=~"dev-.*"}'
              action: drop

        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_promtail_io_scrape]
            action: drop
            regex: false
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
          - action: replace
            replacement: /var/log/pods/*$1/*.log
            separator: /
            source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
            target_label: __path__
```

Corresponding LogQL — note `|~` is **unanchored** RE2, the opposite of Prometheus:

```logql
{namespace="prod-orders", container="orders-api"}
  |~ `(?i)\b(timeout|connection refused|circuit breaker)\b`
  != `kube-probe`
  | regexp `orderId=(?P<order_id>\d+)`
  | order_id != ""
```

### 4.5 The CI gate — `grep` as merge policy

```yaml
name: content-and-secret-gate

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  regex-policy:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Show tool versions (engine identity matters)
        run: |
          grep --version | head -n1
          sed --version | head -n1
          echo "PCRE support: $(grep -P '' /dev/null 2>&1 && echo yes || echo no)"

      - name: Block hardcoded credentials
        run: bash ci/checks/no-secrets.sh

      - name: Block :latest image tags in manifests
        run: |
          if grep -rInE --include='*.yaml' --include='*.yml' \
               '^[[:space:]]*image:[[:space:]]*[^[:space:]]+:latest[[:space:]]*$' manifests/; then
            echo "::error::mutable :latest tag found in a manifest"
            exit 1
          fi

      - name: Block unanchored Prometheus keep/drop regexes that were meant to be substrings
        run: bash ci/checks/relabel-anchoring.sh

      - name: Validate observability configs
        run: |
          promtool check config manifests/prometheus/prometheus.yml
          promtool check rules  manifests/prometheus/rules/*.yaml
          amtool check-config   manifests/alertmanager/alertmanager.yml
          docker run --rm -v "$PWD/manifests/fluent-bit:/cfg:ro" \
            cr.fluentbit.io/fluent/fluent-bit:3.1.9 \
            /fluent-bit/bin/fluent-bit -c /cfg/fluent-bit.conf --dry-run

      - name: Golden-corpus parser tests
        run: bash ci/checks/parser-corpus.sh
```

```bash
#!/usr/bin/env bash
# ci/checks/no-secrets.sh
# grep -E only: no PCRE, so this gate itself cannot ReDoS the runner.
set -euo pipefail

PATTERNS=$(mktemp); trap 'rm -f "$PATTERNS"' EXIT
cat >"$PATTERNS" <<'EOF'
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
-----BEGIN [A-Z ]*PRIVATE KEY-----
gh[pousr]_[A-Za-z0-9]{36,}
xox[baprs]-[0-9A-Za-z-]{10,}
eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
(password|passwd|secret|token|api_?key)[[:space:]]*[:=][[:space:]]*["'][^"']{8,}["']
EOF

# -I skips binaries, -n gives reviewable output, --exclude-dir keeps it fast.
# Exit 1 from grep means "clean" here, so the status is inverted deliberately.
if grep -rInE -f "$PATTERNS" \
     --exclude-dir=.git \
     --exclude-dir=node_modules \
     --exclude-dir=vendor \
     --exclude-dir=.terraform \
     --exclude='*.lock' \
     --exclude='no-secrets.sh' \
     . ; then
  echo "::error::credential-shaped string found — rotate it before removing it"
  exit 1
fi

echo "no-secrets: clean"
```

```bash
#!/usr/bin/env bash
# ci/checks/relabel-anchoring.sh
# Catches the Failure Mode of section 1.2: a keep/drop regex with no
# anchor-relaxing wildcard, which is silently exact-match in Prometheus.
set -euo pipefail

status=0
while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  value=$(sed -n "${line}p" "$file" | sed -E 's/^[[:space:]]*regex:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//')

  # A regex containing no . * + ? ( ) [ ] | is a bare literal — almost always
  # an unintended exact match.
  if printf '%s' "$value" | grep -qvE '[.*+?()\[\]|]'; then
    printf '%s:%s: bare literal regex %q — Prometheus anchors this to ^(?:%s)$\n' \
      "$file" "$line" "$value" "$value"
    status=1
  fi
done < <(grep -rnE --include='*.yml' --include='*.yaml' \
           '^[[:space:]]*regex:[[:space:]]*' manifests/prometheus/ || true)

exit "$status"
```

```bash
#!/usr/bin/env bash
# ci/checks/parser-corpus.sh
# Golden corpus: every parser must match every POSITIVE sample and must match
# NO negative sample, and must do so in bounded time.
set -euo pipefail

RE_NGINX='^([^ ]*) ([^ ]*) ([^ ]*) \[([^]]*)\] "([A-Z]+) ([^ ]*) ([^"]*)" ([0-9]{3}) ([0-9-]+) "([^"]*)" "([^"]*)"$'

fail=0

while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! printf '%s\n' "$line" | timeout 5 grep -qE "$RE_NGINX"; then
    printf 'POSITIVE sample did not match: %s\n' "$line"
    fail=1
  fi
done < ci/corpus/nginx.positive

while IFS= read -r line; do
  [ -z "$line" ] && continue
  if printf '%s\n' "$line" | timeout 5 grep -qE "$RE_NGINX"; then
    printf 'NEGATIVE sample matched (regex too loose): %s\n' "$line"
    fail=1
  fi
done < ci/corpus/nginx.negative

# Pathological input must complete well inside the timeout.
if ! head -c 100000 /dev/zero | tr '\0' 'a' | timeout 5 grep -qE "$RE_NGINX"; then
  : # no match is the expected result; what matters is that it returned
fi
if [ $? -eq 124 ]; then
  echo "regex did not terminate on pathological input"
  fail=1
fi

exit "$fail"
```

---

## 5. Terminal sessions

### 5.1 Building the lab corpus

```bash
$ mkdir -p ~/lab/103.7 && cd ~/lab/103.7
$ cat > access.log <<'EOF'
10.0.4.17 - - [26/Aug/2026:09:14:02 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
10.0.4.17 - - [26/Aug/2026:09:14:12 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
203.0.113.42 - - [26/Aug/2026:09:14:19 +0000] "POST /api/v2/orders HTTP/1.1" 201 512 "-" "curl/8.5.0"
198.51.100.7 - - [26/Aug/2026:09:14:23 +0000] "GET /api/v2/orders/8821 HTTP/1.1" 404 74 "-" "Go-http-client/2.0"
203.0.113.42 - - [26/Aug/2026:09:15:01 +0000] "POST /api/v2/orders HTTP/1.1" 500 141 "-" "curl/8.5.0"
192.0.2.88 - - [26/Aug/2026:09:15:07 +0000] "GET /static/app.js HTTP/1.1" 200 90211 "https://shop.example.com/" "Mozilla/5.0"
203.0.113.42 - - [26/Aug/2026:09:15:33 +0000] "POST /api/v2/orders HTTP/1.1" 502 0 "-" "curl/8.5.0"
198.51.100.7 - - [26/Aug/2026:09:15:44 +0000] "DELETE /api/v2/orders/8821 HTTP/1.1" 403 63 "-" "Go-http-client/2.0"
10.0.4.17 - - [26/Aug/2026:09:15:52 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
192.0.2.88 - - [26/Aug/2026:09:16:02 +0000] "GET /api/v2/cart HTTP/1.1" 200 1044 "https://shop.example.com/" "Mozilla/5.0"
203.0.113.42 - - [26/Aug/2026:09:16:19 +0000] "POST /api/v2/orders HTTP/1.1" 503 0 "-" "curl/8.5.0"
172.16.9.3 - - [26/Aug/2026:09:16:41 +0000] "GET /admin/metrics HTTP/1.1" 401 0 "-" "Prometheus/2.51.2"
EOF

$ cat > app.log <<'EOF'
2026-08-26T09:14:02.114Z INFO  [orders-api] c.e.o.web.HealthController - liveness ok
2026-08-26T09:15:01.882Z ERROR [orders-api] c.e.o.svc.OrderService - failed to reserve stock for orderId=8821 sku=SKU-4471
2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms.
2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)
2026-08-26T09:15:01.885Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)
2026-08-26T09:15:33.201Z WARN  [orders-api] c.e.o.svc.PaymentClient - upstream upstream returned 502, retrying in 200ms
2026-08-26T09:16:19.774Z ERROR [orders-api] c.e.o.svc.PaymentClient - circuit breaker OPEN after 5 consecutive failures
2026-08-26T09:16:41.010Z INFO  [orders-api] c.e.o.web.MetricsController - unauthorized scrape from 172.16.9.3
2026-08-26T09:17:02.554Z DEBUG [orders-api] c.e.o.repo.OrderRepo - select * from orders where id = ?
2026-08-26T09:17:10.099Z INFO  [orders-api] c.e.o.web.HealthController - readiness ok
EOF

$ wc -l access.log app.log
 12 access.log
 10 app.log
 22 total

$ grep --version | head -n1
grep (GNU grep) 3.11
```

### 5.2 BRE vs ERE, demonstrated rather than memorized

```bash
$ grep -c 'orders|cart' access.log       # BRE: '|' is a literal pipe
0
$ echo $?
1

$ grep -c 'orders\|cart' access.log      # BRE + GNU alternation extension
6

$ grep -c -E 'orders|cart' access.log    # ERE: portable and readable
6
```

Grouping and intervals in both dialects:

```bash
$ grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}' access.log | head -n3
10.0.4.17
10.0.4.17
203.0.113.42

$ grep -o '^\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}' access.log | head -n3
10.0.4.17
10.0.4.17
203.0.113.42
```

Anchors are positional in BRE, absolute in ERE:

```bash
$ echo 'a^b' | grep -c 'a^b'      # BRE: '^' not at the start → literal
1
$ echo 'a^b' | grep -c -E 'a^b'   # ERE: '^' always an anchor → impossible
0
$ echo 'a$b' | grep -c 'a$b'
1
$ echo 'a$b' | grep -c -E 'a$b'
0
```

Back-references — available in GNU BRE and (as an extension) GNU ERE:

```bash
$ grep -n '\b\([a-z]\+\) \1\b' app.log
6:2026-08-26T09:15:33.201Z WARN  [orders-api] c.e.o.svc.PaymentClient - upstream upstream returned 502, retrying in 200ms
```

That single pattern is also the thing you must **never** ship to a backtracking engine on untrusted input, and the thing RE2 will reject outright.

### 5.3 Incident-shaped searches

Every 5xx served by the ingress:

```bash
$ grep -E '" 5[0-9]{2} ' access.log
203.0.113.42 - - [26/Aug/2026:09:15:01 +0000] "POST /api/v2/orders HTTP/1.1" 500 141 "-" "curl/8.5.0"
203.0.113.42 - - [26/Aug/2026:09:15:33 +0000] "POST /api/v2/orders HTTP/1.1" 502 0 "-" "curl/8.5.0"
203.0.113.42 - - [26/Aug/2026:09:16:19 +0000] "POST /api/v2/orders HTTP/1.1" 503 0 "-" "curl/8.5.0"
```

Talker ranking — `-o` turns `grep` into a field extractor:

```bash
$ grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}' access.log | sort | uniq -c | sort -rn
      4 203.0.113.42
      3 10.0.4.17
      2 198.51.100.7
      2 192.0.2.88
      1 172.16.9.3
```

Status-code histogram, excluding probe traffic:

```bash
$ grep -v 'kube-probe' access.log | grep -oE '" [0-9]{3} ' | tr -d '" ' | sort | uniq -c | sort -rn
      3 200
      1 503
      1 502
      1 500
      1 404
      1 403
      1 401
      1 201
```

Non-RFC1918 clients — a negated lookahead is unnecessary; alternation and `-v` suffice:

```bash
$ grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' access.log | grep -oE '^[^ ]+' | sort -u
192.0.2.88
198.51.100.7
203.0.113.42
```

Context around the first error, the way you actually read a stack trace:

```bash
$ grep -n -A3 'SQLTransientConnectionException' app.log
3:2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms.
4-2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)
5-2026-08-26T09:15:01.885Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)
```

Whole-word matching prevents the classic IP false positive:

```bash
$ printf '10.0.4.17\n110.0.4.170\n' | grep '10.0.4.17'
10.0.4.17
110.0.4.170
$ printf '10.0.4.17\n110.0.4.170\n' | grep -w '10\.0\.4\.17'
10.0.4.17
```

Note the second form escapes the dots too. Unescaped `.` is "any character", which is how `10.0.4.17` also matches `10a0b4c17`.

### 5.4 `sed` — extraction, redaction, surgical edits

Extract a single value and stop reading the file (`q` short-circuits):

```bash
$ sed -n 's/.*orderId=\([0-9]\+\).*/\1/p; /orderId=/q' app.log
8821
```

Redact every IPv4 address before shipping a log excerpt to a vendor:

```bash
$ sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/x.x.x.x/g' access.log | head -n3
x.x.x.x - - [26/Aug/2026:09:14:02 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
x.x.x.x - - [26/Aug/2026:09:14:12 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
x.x.x.x - - [26/Aug/2026:09:14:19 +0000] "POST /api/v2/orders HTTP/1.1" 201 512 "-" "curl/8.5.0"
```

Rewrite an access log into a CSV, with capture groups doing the field work:

```bash
$ sed -nE 's/^([^ ]+) [^ ]+ [^ ]+ \[([^]]+)\] "([A-Z]+) ([^ ]+) [^"]*" ([0-9]{3}) ([0-9-]+).*/\2,\1,\3,\4,\5,\6/p' access.log | head -n4
26/Aug/2026:09:14:02 +0000,10.0.4.17,GET,/healthz,200,2
26/Aug/2026:09:14:12 +0000,10.0.4.17,GET,/healthz,200,2
26/Aug/2026:09:14:19 +0000,203.0.113.42,POST,/api/v2/orders,201,512
26/Aug/2026:09:14:23 +0000,198.51.100.7,GET,/api/v2/orders/8821,404,74
```

Range addressing — everything from the first ERROR to the next WARN:

```bash
$ sed -n '/ERROR/,/WARN/p' app.log
2026-08-26T09:15:01.882Z ERROR [orders-api] c.e.o.svc.OrderService - failed to reserve stock for orderId=8821 sku=SKU-4471
2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms.
2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)
2026-08-26T09:15:01.885Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)
2026-08-26T09:15:33.201Z WARN  [orders-api] c.e.o.svc.PaymentClient - upstream upstream returned 502, retrying in 200ms
```

`0,/re/` — replace only the **first** match, the idiom that `s///` alone cannot express:

```bash
$ sed '0,/ERROR/s//FIRST-ERROR/' app.log | grep -n 'ERROR' | head -n3
2:2026-08-26T09:15:01.882Z FIRST-ERROR [orders-api] c.e.o.svc.OrderService - failed to reserve stock for orderId=8821 sku=SKU-4471
3:2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms.
4:2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)
```

The line-orientation limit, and the two ways past it:

```bash
$ sed -n '/Connection is not available/,+1{N;s/\n[[:space:]]*/ | /;p}' app.log | head -n1
2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms. | 2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)

$ sed -z -E 's/(SQLTransientConnectionException)[^\n]*\n[^\n]*at ([A-Za-z.]+)\(/\1 raised at \2(/' app.log | sed -n '3p'
2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException raised at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)
```

Safe in-place editing across a repository — find first, then edit only what matched:

```bash
$ grep -rlZ --include='*.yaml' -E 'image: +nginx:1\.25\.[0-9]+' manifests/ \
  | xargs -0 --no-run-if-empty sed -E -i.bak 's|(image: +nginx:)1\.25\.[0-9]+|\g<1>1.27.2|'
$ grep -rn 'image: nginx' manifests/ | head -n3
manifests/ingress/deployment.yaml:34:          image: nginx:1.27.2
manifests/demo/deployment.yaml:21:          image: nginx:1.27.2
$ find manifests -name '*.bak' -delete
```

(`\g<1>` is GNU sed's unambiguous group reference — required when the replacement continues with a digit, since `\11` would mean group 11.)

### 5.5 Filesystem-wide search

```bash
$ grep -rIn --exclude-dir=.git --include='*.yaml' -E '^[[:space:]]*image:.*:latest[[:space:]]*$' manifests/
manifests/dev/job-migrate.yaml:23:          image: registry.example.com/migrate:latest
manifests/dev/deployment.yaml:41:          image: registry.example.com/orders-api:latest

$ grep -rlZ -E 'AKIA[0-9A-Z]{16}' --exclude-dir=.git . | xargs -0 -r ls -l
-rw-r--r--. 1 sre sre 1180 Aug 26 09:22 ./terraform/backup.tfvars.example

$ find /etc -maxdepth 2 -type f -name '*.conf' -print0 2>/dev/null \
  | xargs -0 grep -lE '^[[:space:]]*PermitRootLogin[[:space:]]+yes'
/etc/ssh/sshd_config
```

`grep -r` versus `find -exec` — the trade-off:

| Approach | Startup cost | Handles odd filenames | Filtering power |
|---|---|---|---|
| `grep -r --include=… --exclude-dir=…` | one process | yes | glob only |
| `find … -print0 \| xargs -0 grep` | one `grep` per batch | yes, with `-print0`/`-0` | full `find` predicates (`-mtime`, `-size`, `-perm`, `-user`) |
| `find … -exec grep {} \;` | one process **per file** | yes | full | ← avoid; use `-exec … {} +` |

Compressed and journal sources:

```bash
$ zgrep -c ' 50[0-9] ' /var/log/nginx/access.log.2.gz
417

$ journalctl -u kubelet --since '2026-08-26 09:00' -g 'Failed to (start|create) (pod )?sandbox' -o short-iso --no-pager | head -n2
2026-08-26T09:15:04+0000 node-3 kubelet[1811]: E0826 09:15:04.882119    1811 kuberuntime_sandbox.go:72] "Failed to create sandbox for pod" err="rpc error: code = Unknown desc = failed to setup network"
2026-08-26T09:15:09+0000 node-3 kubelet[1811]: E0826 09:15:09.114553    1811 kuberuntime_manager.go:1166] "Failed to start sandbox" pod="prod-orders/orders-api-6f9c8d7b4-2xkqz"
```

### 5.6 Engine behaviour under adversarial input — measure it yourself

```bash
$ python3 -c 'print("a"*40)' > redos.txt

$ time grep -E '^(a+)+b$' redos.txt
real    0m0.003s
user    0m0.002s
sys     0m0.001s
$ echo $?
1
```

GNU grep's DFA answers "no match" in constant-ish time regardless of nesting. Now the same pattern through PCRE2:

```bash
$ time grep -P '^(a+)+b$' redos.txt
grep: exceeded PCRE's backtracking limit
real    0m1.284s
user    0m1.279s
sys     0m0.003s
$ echo $?
2
```

The backtracking limit is a *guard rail*, not a fix — and libraries embedded in your log pipeline usually have no such guard:

```bash
$ time python3 -c "import re; re.match(r'^(a+)+b\$', 'a'*26)"
real    0m11.407s
user    0m11.399s
sys     0m0.004s
```

Each additional `a` doubles that. At 30 characters it is ~3 minutes of one core, per log line. This is the whole of section 1.1 in one measurement.

The fix is structural, not a tuning knob:

```bash
$ time grep -P '^a+b$' redos.txt        # no nested quantifier → no ambiguity
real    0m0.003s
$ echo $?
1
```

### 5.7 Throughput: pick the cheapest engine that can answer the question

```bash
$ yes '203.0.113.42 - - [26/Aug/2026:09:15:01 +0000] "POST /api/v2/orders HTTP/1.1" 500 141 "-" "curl/8.5.0"' \
  | head -n 3000000 > big.log
$ ls -lh big.log
-rw-r--r--. 1 sre sre 315M Aug 26 09:41 big.log

$ time grep -c -F 'POST /api/v2/orders' big.log
3000000
real    0m0.212s

$ time grep -c 'POST /api/v2/orders' big.log
3000000
real    0m0.219s

$ time grep -c -E '"(GET|POST|PUT) /api/v2/[a-z]+ HTTP/1\.1" [0-9]{3}' big.log
3000000
real    0m1.947s

$ time grep -c -P '"(GET|POST|PUT) /api/v2/[a-z]+ HTTP/1\.1" \d{3}' big.log
3000000
real    0m3.512s

$ time LC_ALL=C grep -c -iE '"(get|post|put) /api/v2/[a-z]+ ' big.log
3000000
real    0m1.104s

$ time grep -c -iE '"(get|post|put) /api/v2/[a-z]+ ' big.log
3000000
real    0m3.986s
```

The `LC_ALL=C` gap is largest exactly where you use it most: `-i` and bracket expressions over multibyte-capable locales. For byte-oriented log scanning it is free performance. Do **not** use it when the pattern or data contains non-ASCII characters you care about, because matching becomes byte-wise and a multibyte character can be split.

---

## 6. Verification and failure diagnosis

### 6.1 Exit status is the contract

| Tool | 0 | 1 | 2 | Other |
|---|---|---|---|---|
| `grep` | at least one line matched | no line matched | error (bad regex, unreadable file) — unless `-q` suppressed it | 141 = SIGPIPE (see below) |
| `sed` | success | — | error / `q` with an explicit code | `q5` exits 5 |
| `awk` | success | — | error | `exit N` |

Three scripting hazards that follow directly:

```bash
# 1. `set -e` + grep: "no match" is exit 1 and will kill the script.
set -euo pipefail
count=$(grep -c 'ERROR' app.log)          # aborts the script when count is 0
count=$(grep -c 'ERROR' app.log || true)  # correct
count=$(grep -c 'ERROR' app.log) || count=0   # also correct, keeps real errors visible

# 2. `grep -q` closes stdin at the first match; the writer gets SIGPIPE.
$ set -o pipefail
$ zcat huge.log.gz | grep -q 'ERROR'; echo "status=$?"
status=141
# Fix: drop pipefail for this pipeline, or use `grep -m1 -q` semantics
# downstream of a producer that tolerates EPIPE.

# 3. `-s` hides the difference between "no match" and "cannot read".
$ grep -rs 'secret' /var/lib/kubelet/ ; echo $?
1        # is this "clean" or "permission denied everywhere"? unknowable
$ sudo grep -r 'secret' /var/lib/kubelet/ >/dev/null; echo $?
0
```

### 6.2 Diagnostic runbook

| Symptom | Likely cause | Diagnostic command | Fix |
|---|---|---|---|
| Pattern works in a Perl/Python REPL, matches nothing in `grep` | `\d`, `\w+?`, `(?:…)`, `(?=…)` are not POSIX | `grep -oE 'PAT' <<<'sample'` vs `grep -oP 'PAT' <<<'sample'` | rewrite in ERE (`[[:digit:]]`, negated classes) or accept `-P` and its cost |
| `grep: Unmatched ( or \(` | ERE metacharacter used under BRE | `grep -E` the same pattern | add `-E`, or escape as `\(` |
| Pattern with `+`/`?`/`|` matches literally | BRE default | `grep -E …` | `-E`, always |
| Prometheus target silently disappears | `regex:` is anchored | `promtool check config`, then `curl -s localhost:9090/api/v1/targets \| jq '.data.droppedTargets[0]'` | write `.*foo.*` when you mean "contains" |
| Alert routed to the wrong receiver | `=~` anchored, or `continue:` semantics | `amtool config routes test --config.file=alertmanager.yml severity=critical namespace=prod-eu` | anchor-aware matcher; verify with `amtool` before merging |
| Loki query returns too much | `|~` is unanchored | add `^`/`$`, or use `|=` for a literal | prefer `|=` line filters before `|~` — Loki applies them cheaply first |
| Fluent Bit pod at 100 % CPU, few records out | nested quantifier in a `[PARSER]` Regex | `curl -s localhost:2020/api/v1/metrics \| jq`, then diff the last parser change | remove nesting; use negated classes; add a CPU limit as containment |
| Fluent Bit drops records | `Mem_Buf_Limit` reached (often a downstream of the above) | `fluentbit_output_dropped_records_total` | fix the parser; enable `storage.type filesystem` |
| `Binary file X matches` instead of output | NUL byte in a truncated log | `grep -c $'\0' -a X`; `file X` | `grep -a` or `--binary-files=text`; `-I` to skip |
| `grep` on a `tail -f` pipeline prints in bursts | 4 KiB block buffering when stdout is a pipe | `tail -f x \| grep --line-buffered PAT \| cat` | `--line-buffered`, or `stdbuf -oL` |
| Character class matches unexpected characters | non-C locale collation for ranges | `LC_ALL=C grep …` vs `grep …` | `[[:lower:]]` instead of `[a-z]`; pin `LC_ALL=C` for byte scanning |
| `sed -i` fails on a Mac/BSD runner | `-i` requires an argument there | `sed --version` (GNU prints a version; BSD errors) | `sed -i.bak` and delete the backups, or `sed … > tmp && mv tmp file` |
| `sed` will not match a two-line pattern | pattern space is one line | `sed -n 'N;p'` to confirm | `N`/`H`+`G`, or `sed -z`, or `awk` |
| `grep: regular expression too big` | interval count beyond the engine limit | reduce `{n,m}` | stay within `RE_DUP_MAX` = 255 |
| Pattern beginning with `-` is read as an option | argument parsing | `grep -e '-v-flag' file` | `-e` or `--` |

### 6.3 A reusable validation harness

Test the regex in **the engine that will run it**, against both positive and negative corpora, with a time bound. This script is the generic form of `ci/checks/parser-corpus.sh`:

```bash
#!/usr/bin/env bash
# regex-verify.sh — prove a pattern before it becomes config.
# usage: regex-verify.sh <engine> <pattern> <positive-file> <negative-file>
#        engine: bre | ere | pcre | re2
set -uo pipefail

engine=$1 pattern=$2 pos=$3 neg=$4
timeout_s=5
fail=0

match_one() {   # match_one <line> -> 0 match, 1 no match, 124 timeout, 2 error
  case "$engine" in
    bre)  printf '%s\n' "$1" | timeout "$timeout_s" grep -q    -- "$pattern" ;;
    ere)  printf '%s\n' "$1" | timeout "$timeout_s" grep -qE   -- "$pattern" ;;
    pcre) printf '%s\n' "$1" | timeout "$timeout_s" grep -qP   -- "$pattern" ;;
    re2)  timeout "$timeout_s" go run ./cmd/re2match "$pattern" "$1" ;;
    *)    echo "unknown engine: $engine" >&2; exit 64 ;;
  esac
}

check() {       # check <file> <expected 0|1>
  local file=$1 want=$2 rc
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    match_one "$line"; rc=$?
    case $rc in
      124) printf 'TIMEOUT  %s\n' "$line"; fail=1 ;;
      2)   printf 'REGEXERR %s\n' "$pattern"; exit 2 ;;
      *)   if [ "$rc" -ne "$want" ]; then
             printf 'WRONG(rc=%s want=%s) %s\n' "$rc" "$want" "$line"; fail=1
           fi ;;
    esac
  done < "$file"
}

check "$pos" 0
check "$neg" 1

# Adversarial probe: long runs of the most common character in the corpus.
for n in 100 1000 10000 100000; do
  probe=$(head -c "$n" /dev/zero | tr '\0' 'a')
  match_one "$probe" >/dev/null 2>&1
  [ $? -eq 124 ] && { printf 'SUPERLINEAR at n=%s — do not ship this pattern\n' "$n"; fail=1; break; }
done

[ "$fail" -eq 0 ] && echo "OK  engine=$engine  pattern=$pattern"
exit "$fail"
```

```bash
$ ./regex-verify.sh ere '^([^ ]*) ([^ ]*) ([^ ]*) \[([^]]*)\] "([A-Z]+) ([^ ]*) ([^"]*)" ([0-9]{3}) ([0-9-]+) "([^"]*)" "([^"]*)"$' \
    ci/corpus/nginx.positive ci/corpus/nginx.negative
OK  engine=ere  pattern=^([^ ]*) ([^ ]*) ([^ ]*) \[([^]]*)\] "([A-Z]+) ([^ ]*) ([^"]*)" ([0-9]{3}) ([0-9-]+) "([^"]*)" "([^"]*)"$

$ ./regex-verify.sh pcre '^(\S+\s+)+$' ci/corpus/nginx.positive ci/corpus/nginx.negative
SUPERLINEAR at n=10000 — do not ship this pattern
```

### 6.4 Pre-merge checklist for any regex that becomes configuration

1. **Engine named.** Which of §2.4 will evaluate this? Write it in a comment next to the pattern.
2. **Anchoring stated.** Anchored by the tool (Prometheus, Alertmanager), or by you (`^…$`), or deliberately unanchored (Loki, `grep`).
3. **No nested quantifier.** No `(x+)+`, `(x*)*`, `(x|xy)+`, or `(…)*` around a group that can match empty.
4. **Negated classes, not `.*`.** Each field is `[^delimiter]*`.
5. **POSIX classes, not ASCII ranges.** `[[:digit:]]` over `[0-9]` when locale is not pinned.
6. **Negative corpus exists.** A pattern validated only against matching input is not validated.
7. **Time-bounded test passed** against a 100 kB adversarial string.
8. **Config validated by the vendor tool**: `promtool check config`, `amtool check-config`, `fluent-bit --dry-run`, `nginx -t`, `logcli` query smoke test.
9. **An alert exists for the silent failure** (`absent()` for scrape tiers, `dropped_records_total` for collectors).
10. **`grep -E`, not `egrep`; `grep -F`, not `fgrep`** — in every script you commit.

---

## 7. Exam mapping

| The exam asks | What to have ready |
|---|---|
| Difference between BRE and ERE | the inversion table in §2.1 — `( ) { } | + ?` are literal in BRE, special in ERE |
| Build a regex with several notational elements | anchors, `.`, bracket expressions with ranges/negation/POSIX classes, `*` `+` `?`, `{n,m}`, grouping, alternation, back-references |
| `grep` / `egrep` / `fgrep` | `grep -E` ≡ `egrep`; `grep -F` ≡ `fgrep`; both old names are obsolescent in GNU grep ≥ 3.8 |
| `sed` | `s/re/repl/flags`, address forms `/re/`, `N`, `$`, `addr1,addr2`, `!`, `-n` with `p`, `-i`, `-E` |
| `regex(7)` | `man 7 regex` is the POSIX syntax reference shipped on the system |
| Search a filesystem | `grep -r` with `--include` / `--exclude-dir`, and `find -print0 \| xargs -0 grep` |

---

## 8. References

**Certification objectives**
- LPI, *Exam 101-500 Objectives* (LPIC-1 v5.0), objective 103.7 — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI, *LPIC-1 Certification* overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Standards**
- The Open Group, *POSIX.1-2024 (Issue 8), Base Definitions Chapter 9: Regular Expressions* — https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V3_chap09.html
- The Open Group, *POSIX.1-2024, `grep`* — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/grep.html
- The Open Group, *POSIX.1-2024, `sed`* — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sed.html
- The Open Group, *POSIX.1-2024, `awk`* — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/awk.html

**GNU tools**
- GNU Project, *GNU Grep Manual* — https://www.gnu.org/software/grep/manual/grep.html
- GNU Project, *GNU Grep NEWS* (`egrep`/`fgrep` obsolescence in 3.8) — https://git.savannah.gnu.org/cgit/grep.git/tree/NEWS
- GNU Project, *GNU sed Manual* — https://www.gnu.org/software/sed/manual/sed.html
- GNU Project, *GNU Awk User's Guide — Regular Expressions* — https://www.gnu.org/software/gawk/manual/gawk.html#Regexp

**Manual pages**
- `regex(7)` — https://man7.org/linux/man-pages/man7/regex.7.html
- `grep(1)` — https://man7.org/linux/man-pages/man1/grep.1.html
- `sed(1)` — https://man7.org/linux/man-pages/man1/sed.1.html
- `journalctl(1)` (`-g`/`--grep`, PCRE2) — https://man7.org/linux/man-pages/man1/journalctl.1.html
- `locale(7)` — https://man7.org/linux/man-pages/man7/locale.7.html

**Regex engines**
- PCRE2, *Pattern Syntax Summary* — https://www.pcre.org/current/doc/html/pcre2syntax.html
- Google, *RE2 Syntax* — https://github.com/google/re2/wiki/Syntax
- Russ Cox, *Regular Expression Matching Can Be Simple And Fast* — https://swtch.com/~rsc/regexp/regexp1.html
- OWASP, *Regular expression Denial of Service (ReDoS)* — https://owasp.org/www-community/attacks/Regular_expression_Denial_of_Service_-_ReDoS

**Platform components used in the manifests**
- Prometheus, *Configuration — `relabel_config`* — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
- Prometheus, *Alertmanager Configuration — route and matchers* — https://prometheus.io/docs/alerting/latest/configuration/
- Fluent Bit, *Parsers — Regular Expression* — https://docs.fluentbit.io/manual/pipeline/parsers/regular-expression
- Fluent Bit, *Filters — Grep* — https://docs.fluentbit.io/manual/pipeline/filters/grep
- Grafana Loki, *Promtail stages — `regex`* — https://grafana.com/docs/loki/latest/send-data/promtail/stages/regex/
- Grafana Loki, *LogQL — Log queries* — https://grafana.com/docs/loki/latest/query/log_queries/
- Kubernetes, *DaemonSet* — https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/