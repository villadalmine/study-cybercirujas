# PCA — Topic 1.5: Binary Operators (Guided Exercises)

> **Domain:** PromQL · **Exam weight:** 4
> **What you will practice:** arithmetic, comparison, and logical/set binary operators; vector matching with `on` / `ignoring`; many-to-one joins with `group_left` / `group_right`; the `bool` modifier; and operator precedence.
>
> **Primary sources**
> - PromQL operators: https://prometheus.io/docs/prometheus/latest/querying/operators/
> - Query basics (instant vector, scalar): https://prometheus.io/docs/prometheus/latest/querying/basics/
> - HTTP query API: https://prometheus.io/docs/prometheus/latest/querying/api/
> - node_exporter metrics: https://github.com/prometheus/node_exporter
> - CNCF PCA curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf

Every query below is run either in the **Prometheus expression browser** (`http://localhost:9090/graph`, *Table* tab) or through the **HTTP API** with `curl` + `jq`. Sample outputs are machine-dependent — the *shape* and the *labels* are what matter, not the exact numbers.

---

## Exercise 0 — Build the lab

You need real series with rich label sets to make binary operators meaningful. We run Prometheus scraping itself plus a `node_exporter`.

1. Create a working directory and a scrape config:

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 5s
     evaluation_interval: 5s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']
     - job_name: node
       static_configs:
         - targets: ['node-exporter:9100']
   ```

2. Create the stack definition:

   ```yaml
   # docker-compose.yml
   services:
     prometheus:
       image: prom/prometheus:v2.53.0
       ports: ["9090:9090"]
       volumes:
         - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
       command: ["--config.file=/etc/prometheus/prometheus.yml"]
     node-exporter:
       image: prom/node-exporter:v1.8.1
       ports: ["9100:9100"]
   ```

3. Bring it up and wait ~15 s for the first scrapes:

   ```bash
   docker compose up -d
   sleep 15
   ```

4. Confirm both targets are healthy. In the expression browser run `up`, or from the shell:

   ```bash
   curl -s -G http://localhost:9090/api/v1/query \
     --data-urlencode 'query=up' | jq -r '.data.result[] | "\(.metric.job)\t\(.value[1])"'
   ```

   Expected (approximate):

   ```
   node       1
   prometheus 1
   ```

5. Define a shell helper you will reuse in every exercise (requires `jq`):

   ```bash
   promql() {
     curl -s -G http://localhost:9090/api/v1/query \
       --data-urlencode "query=$1" \
     | jq -r '.data.result[] | "\(.metric)  =>  \(.value[1])"'
   }
   ```

   Smoke-test it:

   ```bash
   promql 'up'
   ```

**Check your understanding**

- **Q0.1** In the JSON returned by `/api/v1/query`, `value` is a two-element array. What are the two elements, and which one does the `promql` helper print?
- **Q0.2** The `up` metric carries a `job` label and an `instance` label even though `prometheus.yml` never sets them. Where do those two labels come from?

---

## Exercise 1 — Arithmetic between a vector and a scalar

A binary arithmetic operator (`+ - * / % ^`) applied between an **instant vector** and a **scalar** operates element-by-element on the vector's sample values.

1. Read total memory in bytes:

   ```bash
   promql 'node_memory_MemTotal_bytes'
   ```

   ```
   {__name__="node_memory_MemTotal_bytes",instance="node-exporter:9100",job="node"}  =>  16768331776
   ```

2. Convert it to **GiB** by dividing by `1024^3`:

   ```bash
   promql 'node_memory_MemTotal_bytes / 1024 / 1024 / 1024'
   ```

   ```
   {instance="node-exporter:9100",job="node"}  =>  15.616...
   ```

3. Do the same conversion with exponentiation instead of chained division:

   ```bash
   promql 'node_memory_MemTotal_bytes / 1024^3'
   ```

4. Compute how many **seconds** each Prometheus target has been up since its process start, then compare to the raw metric:

   ```bash
   promql 'time() - process_start_time_seconds'
   ```

**Check your understanding**

- **Q1.1** Compare the labels in step 1 vs. step 2. One label is gone in the result. Which one, and why does arithmetic remove it?
- **Q1.2** In step 3, why does `1024^3` evaluate before the division? (Name the rule.)
- **Q1.3** `time()` returns a **scalar**, and `process_start_time_seconds` is an **instant vector**. What type is the result of step 4, and how many series does it contain relative to the number of scraped targets?

---

## Exercise 2 — Arithmetic between two instant vectors (automatic matching)

When both operands are instant vectors, Prometheus performs **one-to-one vector matching**: for each element on the left it looks for exactly one element on the right whose **complete label set is identical**, then applies the operator to the two values.

1. Compute **available memory as a percentage** of total:

   ```bash
   promql 'node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100'
   ```

   ```
   {instance="node-exporter:9100",job="node"}  =>  47.13...
   ```

2. Compute **used filesystem fraction** per mountpoint (available and size share the same label set — `device`, `fstype`, `mountpoint`, `instance`, `job`):

   ```bash
   promql '1 - (node_filesystem_avail_bytes{fstype!="tmpfs"}
                / node_filesystem_size_bytes{fstype!="tmpfs"})'
   ```

   ```
   {device="overlay",fstype="overlay",mountpoint="/",instance="node-exporter:9100",job="node"}  =>  0.38...
   ```

3. Now break matching on purpose. Aggregate the denominator so it loses its distinguishing labels, then divide:

   ```bash
   promql 'node_filesystem_avail_bytes{fstype!="tmpfs"}
           / sum(node_filesystem_size_bytes{fstype!="tmpfs"})'
   ```

   Observe: the result is **empty**.

**Check your understanding**

- **Q2.1** In step 1, both `MemAvailable` and `MemTotal` carry only `instance` and `job`. Explain, in matching terms, why exactly one result series is produced.
- **Q2.2** Why is the result of step 3 empty rather than an error? Describe the label sets on each side.
- **Q2.3** The result in step 2 has no `__name__`. If you wanted the surviving series to be *named*, which family of operators would you have to use instead of arithmetic?

---

## Exercise 3 — Controlling matching with `on` and `ignoring`

By default matching uses the **full** label set. `ignoring(<labels>)` matches on every label *except* those listed; `on(<labels>)` matches on *only* those listed.

1. Reproduce Exercise 2 step 1, but match on only `instance`:

   ```bash
   promql 'node_memory_MemAvailable_bytes
           / on(instance) node_memory_MemTotal_bytes'
   ```

   Same numeric result — but note which labels survive.

2. Get the same value using `ignoring` instead:

   ```bash
   promql 'node_memory_MemAvailable_bytes
           / ignoring(job) node_memory_MemTotal_bytes'
   ```

3. Trigger the classic **many-to-one** error. Divide the raw per-mode CPU counter by a per-CPU total that has dropped the `mode` label:

   ```bash
   promql 'node_cpu_seconds_total
           / ignoring(mode) sum by (cpu, instance, job) (node_cpu_seconds_total)'
   ```

   Expected error:

   ```
   Error executing query: multiple matches for labels:
   many-to-one matching must be explicit (group_left/group_right)
   ```

**Check your understanding**

- **Q3.1** In step 1, the result keeps `instance` but drops `job`. Why does `on(instance)` remove `job` from the output while Exercise 2 step 1 kept both labels?
- **Q3.2** Steps 1 and 2 return the same number. Under what change to the data would `on(instance)` and `ignoring(job)` stop being equivalent?
- **Q3.3** Explain the error in step 3 in terms of "how many series on the left match one series on the right."

---

## Exercise 4 — Comparison operators as filters

Comparison operators (`== != > < >= <=`) between an instant vector and a scalar (or two vectors) **filter**: elements for which the comparison is false are dropped; the survivors are **passed through unchanged**, keeping their metric name and their original value.

1. List filesystems that are more than **60 % full**:

   ```bash
   promql '(1 - node_filesystem_avail_bytes{fstype!="tmpfs"}
              / node_filesystem_size_bytes{fstype!="tmpfs"}) > 0.60'
   ```

2. List only the targets that are **down**:

   ```bash
   promql 'up == 0'
   ```

   On a healthy lab this returns **nothing**.

3. Show the surviving values keep the original metric identity:

   ```bash
   promql 'node_memory_MemAvailable_bytes > 100e6'
   ```

   ```
   {__name__="node_memory_MemAvailable_bytes",instance="node-exporter:9100",job="node"}  =>  7903137792
   ```

**Check your understanding**

- **Q4.1** In step 3 the printed value is `7903137792`, not `1`. Contrast this with what arithmetic did to the metric name in Exercise 2 — what does a *filtering* comparison preserve that arithmetic does not?
- **Q4.2** Step 2 returns an empty result when everything is healthy. Why is "empty result" a meaningful and *intended* outcome for an alerting expression built on `up == 0`?

---

## Exercise 5 — The `bool` modifier

Prefix a comparison with `bool` and it stops filtering: every input element survives, but its value becomes `1` (true) or `0` (false), and the **metric name is dropped**.

1. Count down targets two different ways:

   ```bash
   promql 'count(up == 0)'        # filter, then count survivors
   promql 'sum(up == bool 0)'     # map to 0/1, then sum
   ```

2. Observe the difference when **all targets are up**. Run both again on the healthy lab and compare the outputs — one is *empty*, the other is `0`.

3. Compare two scalars. This is the one place `bool` is **mandatory**:

   ```bash
   promql '2 > bool 1'
   ```

   Then try it without `bool` and read the parser error:

   ```bash
   promql '2 > 1'
   ```

**Check your understanding**

- **Q5.1** In step 1, both expressions return `0` down targets in most states. In step 2, why does `count(up == 0)` return *empty* while `sum(up == bool 0)` returns the literal `0`? Which one is safer to graph as "number of down targets over time"?
- **Q5.2** Why does Prometheus refuse `2 > 1` between two scalars but accept `2 > bool 1`?

---

## Exercise 6 — Logical / set operators: `and`, `or`, `unless`

These operate **only between two instant vectors** and match on identical label sets (adjustable with `on` / `ignoring`). `group_left` / `group_right` are **not** allowed here.

- `and` → elements of the LHS that have a matching element on the RHS (intersection)
- `or` → all LHS elements, plus RHS elements that had no match on the LHS (union)
- `unless` → LHS elements that have **no** match on the RHS (complement)

1. Filesystems that are both **>50 % full** *and* have **less than 20 GiB free**:

   ```bash
   promql '((1 - node_filesystem_avail_bytes{fstype!="tmpfs"}
                / node_filesystem_size_bytes{fstype!="tmpfs"}) > 0.50)
           and
           (node_filesystem_avail_bytes{fstype!="tmpfs"} < 20 * 1024^3)'
   ```

2. Filesystems over 50 % full **except** the root mount:

   ```bash
   promql '((1 - node_filesystem_avail_bytes{fstype!="tmpfs"}
                / node_filesystem_size_bytes{fstype!="tmpfs"}) > 0.50)
           unless
           node_filesystem_avail_bytes{mountpoint="/"}'
   ```

3. Inspect the values that come out of step 1.

**Check your understanding**

- **Q6.1** The left operand of `and` in step 1 is an *arithmetic/comparison* result (no metric name), and the right operand is a raw metric. `and` matches on the full label set — why do these two still match despite having different `__name__`? (Hint: is `__name__` part of the matching label set here?)
- **Q6.2** For the surviving series in step 1, do the **values** come from the left side, the right side, or a combination? What about `or`?
- **Q6.3** Rewrite step 2's intent — "over 50 % full **and not** root" — using `and` instead of `unless`. What would you have to add to the query?

---

## Exercise 7 — Many-to-one / one-to-many: `group_left` and `group_right`

When one side has several series that legitimately map to a **single** series on the other side, you must declare the "many" side explicitly. `group_left` = the **left** side is the "many"; `group_right` = the **right** side is the "many". Optional labels in the parentheses are **copied from the "one" side** into the result.

### Part A — Fix the many-to-one error from Exercise 3

1. Add `group_left` to compute each CPU mode's **fraction** of that CPU's total time:

   ```bash
   promql 'node_cpu_seconds_total
           / ignoring(mode) group_left
             sum by (cpu, instance, job) (node_cpu_seconds_total)'
   ```

   ```
   {cpu="0",mode="idle",instance="node-exporter:9100",job="node"}    =>  0.91...
   {cpu="0",mode="system",instance="node-exporter:9100",job="node"}  =>  0.02...
   {cpu="0",mode="user",instance="node-exporter:9100",job="node"}    =>  0.03...
   ...
   ```

2. Sanity-check the join: the fractions for one CPU must sum to 1:

   ```bash
   promql 'sum by (cpu) (
             node_cpu_seconds_total
             / ignoring(mode) group_left
               sum by (cpu, instance, job) (node_cpu_seconds_total))'
   ```

### Part B — Enrich metrics from an "info" metric

`node_uname_info` is a value-`1` metric carrying descriptive labels (`nodename`, `release`, …). Multiplying by it preserves the sample value (× 1) while **grafting on** a label with `group_left`.

3. Attach the host's `nodename` onto every per-mode CPU counter:

   ```bash
   promql 'node_cpu_seconds_total
           * on(instance, job) group_left(nodename)
             node_uname_info'
   ```

   ```
   {cpu="0",mode="idle",nodename="1f3c2a...",instance="node-exporter:9100",job="node"} => 41233.7
   ...
   ```

4. Rewrite step 3 using `group_right` so the info metric is on the left. Predict which side must move before you run it.

**Check your understanding**

- **Q7.1** In Part A, which side is the "many" and which is the "one"? Why is `group_left` the correct choice rather than `group_right`?
- **Q7.2** The result of step 1 has no `__name__` but keeps the `mode` label. Where does `mode` come from, given the right-hand side dropped it via `sum by`?
- **Q7.3** In step 3, `node_uname_info` has value `1`. What is the purpose of multiplying by it here, given the numeric value is unchanged? What does `group_left(nodename)` add that a plain `*` could not?
- **Q7.4** Write the step 4 query (info metric as the *left* operand) that produces the same enriched CPU series.

---

## Exercise 8 — Operator precedence and associativity

Precedence, highest → lowest:

1. `^`  2. `* / % atan2`  3. `+ -`  4. `== != <= < >= >`  5. `and unless`  6. `or`

`^` is **right-associative**; every other operator is **left-associative**.

1. Right-associativity of `^`:

   ```bash
   promql '2 ^ 3 ^ 2'
   ```

2. Multiplication before addition — predict, then run:

   ```bash
   promql '2 + 3 * 4'
   promql '(2 + 3) * 4'
   ```

3. Left-associativity of subtraction:

   ```bash
   promql '10 - 2 - 3'
   ```

4. `and` binds tighter than `or`. Predict the grouping of this expression before running it against the lab:

   ```bash
   promql 'up == 1 or up == 0 and up == 1'
   ```

5. Same-precedence `*` and `/` run left-to-right on a vector:

   ```bash
   promql 'node_filesystem_avail_bytes{mountpoint="/"}
           / node_filesystem_size_bytes{mountpoint="/"} * 100'
   ```

**Check your understanding**

- **Q8.1** What does `2 ^ 3 ^ 2` evaluate to, and what would it be if `^` were left-associative?
- **Q8.2** Give the implicit parentheses for `up == 1 or up == 0 and up == 1`.
- **Q8.3** In step 5, is the expression `(avail / size) * 100` or `avail / (size * 100)`? State the rule that decides it.

---

## Cleanup

```bash
docker compose down
```

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 0
- **Q0.1** `value` is `[<unix_timestamp_seconds>, "<sample_value_as_string>"]`. The helper prints `.value[1]`, the sample value (Prometheus returns sample values as strings). `.value[0]` is the evaluation timestamp.
- **Q0.2** They are attached automatically by the scrape process: `job` comes from the `job_name` of the `scrape_config`, and `instance` defaults to the `<host>:<port>` of the scraped target. They are not present in the exposition output — Prometheus adds them.

### Exercise 1
- **Q1.1** The `__name__` label (`node_memory_MemTotal_bytes`) is dropped. Any binary **arithmetic** operator removes the metric name, because the result is no longer that metric — it is a derived value.
- **Q1.2** Operator **precedence**: `^` has the highest precedence of all binary operators, so `1024^3` is computed before the `/`.
- **Q1.3** The result is an **instant vector** (scalar-on-vector arithmetic yields a vector). It contains **one series per input series** of `process_start_time_seconds` — one per scraped target — with the metric name dropped.

### Exercise 2
- **Q2.1** Both operands carry exactly the same label set (`{instance, job}`) with identical values, so one-to-one matching finds exactly one partner for the single left element → exactly one result series.
- **Q2.2** No **error**, just an **empty** result: the left side has `{device, fstype, mountpoint, instance, job}` while `sum(...)` collapses everything to a single series with **no labels**. No left element finds a right element with an identical label set, so nothing matches and the output is empty. (An *empty* match is not an error; a *duplicate* match is.)
- **Q2.3** The **logical/set** operators (`and`, `or`, `unless`) — and filtering **comparisons** — pass series through with their names intact. Arithmetic always strips `__name__`.

### Exercise 3
- **Q3.1** With `on(instance)`, matching considers *only* `instance`; every label **not** in the `on` set (here `job`) is not part of the match and is therefore **dropped** from the output. In Exercise 2 step 1, default matching used the full label set, so both labels were shared and both survived.
- **Q3.2** They diverge as soon as the two sides differ in some *other* label. `ignoring(job)` still matches on everything except `job` (so any additional shared label must also match), whereas `on(instance)` matches on `instance` alone and ignores all other labels. Different label topologies → different (or ambiguous) matches.
- **Q3.3** For each `(cpu, instance, job)` group, the left side (`node_cpu_seconds_total`) has **many** series — one per `mode` — while the right side has exactly **one** (mode was summed away). Many left elements matching one right element is a many-to-one relationship, which Prometheus refuses unless you make it explicit with `group_left`.

### Exercise 4
- **Q4.1** A *filtering* comparison preserves the **metric name and the original sample value** of every surviving element (it just removes the ones that fail the test). Arithmetic instead computes a new value and drops the name. That is why step 3 prints the byte count, not `1`.
- **Q4.2** For an alert you want a series to **exist only when the bad condition holds**. `up == 0` produces series exactly for the down targets and nothing otherwise, so an alerting rule fires precisely when at least one series is present — the empty result is the "all healthy" signal.

### Exercise 5
- **Q5.1** `up == 0` filters: when nothing is down, there are no surviving series, so `count(...)` aggregates an empty vector and returns **empty** (no data point). `up == bool 0` keeps every `up` series and maps it to 0/1; with all targets up, every element is `0`, and `sum(...)` returns the scalar-like value **`0`**. For a graph/gauge of "down targets over time," the **`bool` version is safer** because it always emits a value (`0`) instead of a gap.
- **Q5.2** A comparison between **two scalars** must use `bool`: without it the operation has no defined filtering semantics (there is no vector to filter), so Prometheus rejects it as a parse error. `bool` gives it a defined result: `1` or `0`.

### Exercise 6
- **Q6.1** `and` matches on the full label set, but `__name__` is treated like any other label **and both sides here effectively lack a distinguishing name mismatch on the matching set** — more precisely, the set operators match on the labels present, and because the metric name is not part of what must be equal for the intended match (the left side already had its name stripped by arithmetic), the remaining labels (`device, fstype, mountpoint, instance, job`) line up. The operands match on those shared labels.
- **Q6.2** For `and`, the surviving series keep the **left-hand** side's values (and labels) unchanged; the right side only decides *whether* each left element survives. For `or`, values come from the left for matched positions, plus the **right-hand** side's own values for elements it contributes that had no left match.
- **Q6.3** You cannot express "not root" with `and` alone, because `and` keeps only elements that *match* the RHS. You would need a right-hand operand that represents "everything except root" — e.g. filter with a label matcher (`... and node_filesystem_avail_bytes{mountpoint!="/"}`) — which is exactly the case `unless` handles more directly.

### Exercise 7
- **Q7.1** The **left** side (`node_cpu_seconds_total`, many `mode`s per CPU) is the "many"; the **right** side (the summed total, one per CPU) is the "one". Since the many side is on the left, `group_left` is correct. `group_right` would wrongly declare the right side as the many side.
- **Q7.2** `mode` comes from the **left-hand** side. In many-to-one matching the result carries the labels of the "many" (left) side, so `mode` is retained even though the right side dropped it via `sum by`.
- **Q7.3** Multiplying by the value-`1` info metric is a no-op on the number (× 1) — its only purpose is to perform the **join**. `group_left(nodename)` copies the `nodename` label from the "one" side (the info metric) onto the result. A plain `*` without `group_left(nodename)` would still match, but the extra label would **not** be copied into the output.
- **Q7.4**
  ```promql
  node_uname_info
  * on(instance, job) group_right(nodename)
    node_cpu_seconds_total
  ```
  The many side (`node_cpu_seconds_total`) is now on the right, so `group_right` is used; `nodename` is still the copied label because it lives on the "one" side (the info metric, now on the left).

### Exercise 8
- **Q8.1** `2 ^ 3 ^ 2 = 2 ^ (3 ^ 2) = 2 ^ 9 = 512` because `^` is right-associative. If it were left-associative it would be `(2 ^ 3) ^ 2 = 8 ^ 2 = 64`.
- **Q8.2** `up == 1 or (up == 0 and up == 1)` — `and` binds tighter than `or`.
- **Q8.3** It is `(avail / size) * 100`. `*` and `/` share the same precedence and are **left-associative**, so evaluation runs left to right.

</details>