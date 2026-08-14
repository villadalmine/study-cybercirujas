# KCA 3.3 — `kyverno jp`: Guided Exercises

**Domain:** Kyverno CLI · **Topic weight:** 3 % · **Cluster required:** no (every step except the optional ones in Exercise 7 runs entirely offline)

`kyverno jp` is the CLI's JMESPath workbench. It does not apply, test or validate policies — that is `kyverno apply` and `kyverno test`. What it does is let you evaluate *the exact expression* a policy will evaluate, against *the exact data* the policy will see, without an API server, without a webhook, and without waiting for a rule to fail in a cluster. In practice this is where 90 % of Kyverno debugging time is either spent or saved.

The command has three subcommands:

| Subcommand | Purpose |
|---|---|
| `kyverno jp function` | The function catalogue — names, signatures, notes |
| `kyverno jp parse` | Prints the Abstract Syntax Tree of an expression |
| `kyverno jp query` | Evaluates an expression against JSON/YAML input |

Work through the exercises in order; each one builds on files created by the previous one.

---

## Exercise 0 — Set up the workbench

**Goal:** confirm the CLI, understand the `jp` surface, and create the fixtures used by every later exercise.

1. Verify the CLI is present and note the version — the function catalogue grows with almost every release:

```bash
$ kyverno version
Version: 1.13.4
Time: 2025-02-11T15:22:47Z
Git commit ID: main/....
```

2. Inspect the subcommand tree:

```bash
$ kyverno jp -h
```

3. Create a working directory and the primary fixture:

```bash
mkdir -p ~/kca-3.3/queries && cd ~/kca-3.3
```

```bash
cat > pod-good.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: checkout-api
  namespace: payments
  creationTimestamp: "2026-08-01T09:15:00Z"
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/version: 1.29.3
    tier: backend
  annotations:
    owner: platform-team
    scale.example.io/replicas: "3"
spec:
  serviceAccountName: checkout
  securityContext:
    runAsNonRoot: true
  initContainers:
  - name: migrate
    image: docker.io/library/busybox:1.36
    command: ["sh", "-c", "echo migrating"]
  containers:
  - name: api
    image: registry.example.io/payments/checkout:1.29.3
    ports:
    - containerPort: 8080
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
  - name: metrics
    image: registry.example.io/observability/exporter:0.14.0
    ports:
    - containerPort: 9090
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
EOF
```

4. Smoke-test the evaluator:

```bash
$ kyverno jp query -i pod-good.yaml 'metadata.name'
"checkout-api"
```

**Check your understanding**

- **Q0.1** — `jp query` accepted a YAML file, yet it printed `"checkout-api"` with quotes. What are the input and output formats of this command, and why do they differ?
- **Q0.2** — Nothing in this exercise contacted a cluster. Which Kyverno variables can therefore *never* be resolved by `jp query`, and what must you do to work with them?
- **Q0.3** — Why is a topic-specific answer like "`base64_decode` takes one string" less reliable than a command? Which command replaces it?

---

## Exercise 1 — `kyverno jp function`: the vocabulary

**Goal:** learn to discover the function set instead of memorising it.

1. Print the whole catalogue and count it:

```bash
$ kyverno jp function | wc -l
```

2. Look up a single function:

```bash
$ kyverno jp function base64_decode
Name:      base64_decode
Signature: base64_decode(string) string
Note:      Decodes a base64 string
```

(The exact layout of the block varies between releases — the line that matters is `Signature`.)

3. Look up several at once, and include one that is a *standard* JMESPath built-in rather than a Kyverno filter:

```bash
$ kyverno jp function to_upper semver_compare length
```

4. Ask for something that does not exist:

```bash
$ kyverno jp function totally_not_a_function
$ echo $?
```

5. Find every function that deals with time:

```bash
$ kyverno jp function | grep -i '^time'
```

**Check your understanding**

- **Q1.1** — Did `length` resolve in step 3? What does that tell you about how Kyverno assembles its JMESPath interpreter?
- **Q1.2** — Two engineers disagree about whether `semver_compare('1.29.3', '>=1.30.0')` returns a boolean or an integer. Which single command settles it, and why is reading the Kyverno website a worse answer?
- **Q1.3** — A policy that worked on a Kyverno 1.14 cluster fails on a 1.9 cluster with `function not found`. How does `jp function` let you confirm the diagnosis in seconds on each side?

---

## Exercise 2 — `kyverno jp query`: navigating a real object

**Goal:** the core access patterns — fields, projections, filters, multiselects — against a manifest you will recognise in an exam scenario.

1. Scalars, quoted and unquoted:

```bash
$ kyverno jp query -i pod-good.yaml 'metadata.namespace'
"payments"

$ kyverno jp query -i pod-good.yaml -u 'metadata.namespace'
payments
```

2. A list projection:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[].image'
[
  "registry.example.io/payments/checkout:1.29.3",
  "registry.example.io/observability/exporter:0.14.0"
]
```

3. Compare the flatten operator with the wildcard, then count:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[*].name'
$ kyverno jp query -i pod-good.yaml 'length(spec.containers)'
2
```

4. A filter projection — containers that do **not** drop all capabilities:

```bash
$ kyverno jp query -i pod-good.yaml "spec.containers[?securityContext.capabilities.drop == null].name"
[
  "metrics"
]
```

5. A multiselect hash — build a compact report object:

```bash
$ kyverno jp query -i pod-good.yaml "{pod: metadata.name, images: spec.containers[].image, replicas: metadata.annotations.\"scale.example.io/replicas\"}"
```

6. The same, machine-readable:

```bash
$ kyverno jp query -c -i pod-good.yaml "{pod: metadata.name, n: length(spec.containers)}"
{"n":2,"pod":"checkout-api"}
```

7. Ask for something that is not there:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[0].livenessProbe.httpGet.path'
null
$ echo $?
0
```

**Check your understanding**

- **Q2.1** — In step 4, the `api` container has `capabilities.drop`, the `metrics` container has no `securityContext` at all. Why does the filter still evaluate cleanly instead of erroring on the missing intermediate key?
- **Q2.2** — In step 6 you asked for `{pod: ..., n: ...}` and got `{"n":..., "pod":...}`. Why did the key order change, and what does that imply for scripts that parse `jp query` output by position?
- **Q2.3** — Step 7 returned `null` with exit code `0`. Why is that combination the single most dangerous result in this whole topic when you are debugging a policy that "passes"?

---

## Exercise 3 — Shell quoting: the trap that costs the most time

**Goal:** internalise the three-way collision between JMESPath literals, JMESPath raw strings, and the shell.

JMESPath has two literal forms, and each collides with a different shell quoting rule:

| JMESPath construct | Syntax | Collides with |
|---|---|---|
| JSON literal (numbers, booleans, objects) | `` `3` ``, `` `true` `` | backticks = command substitution inside `"…"` |
| Raw string literal | `'nginx'` | single quotes = shell quoting |
| Quoted identifier (keys with `.`, `/`, `-`) | `"app.kubernetes.io/name"` | double quotes = shell quoting |

1. Literal only → wrap the shell argument in **single** quotes (single quotes protect backticks):

```bash
$ kyverno jp query -i pod-good.yaml 'length(spec.containers) == `2`'
true
```

2. Raw string only → wrap the shell argument in **double** quotes:

```bash
$ kyverno jp query -i pod-good.yaml "spec.containers[?name == 'api'].image"
[
  "registry.example.io/payments/checkout:1.29.3"
]
```

3. Quoted identifier + literal, no raw string → single quotes still work:

```bash
$ kyverno jp query -i pod-good.yaml 'to_number(metadata.annotations."scale.example.io/replicas") > `2`'
true
```

4. Now remove `to_number` and watch a comparison silently give up:

```bash
$ kyverno jp query -i pod-good.yaml 'metadata.annotations."scale.example.io/replicas" > `2`'
null
```

5. Both a raw string *and* a literal in one expression — escape the backticks inside double quotes:

```bash
$ kyverno jp query -i pod-good.yaml "length(spec.containers[?starts_with(name, 'a')]) == \`1\`"
true
```

6. The maintainable alternative — put it in a file and use `-q`:

```bash
cat > queries/one-a-container.jmespath <<'EOF'
length(spec.containers[?starts_with(name, 'a')]) == `1`
EOF
```

```bash
$ kyverno jp query -i pod-good.yaml -q queries/one-a-container.jmespath
true
```

7. Break it deliberately and read the diagnostics:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers['
$ echo $?
```

**Check your understanding**

- **Q3.1** — Step 4 returned `null`, not `false` and not an error. State the JMESPath rule that produces this, and explain why a Kyverno `deny` condition built on it would be quietly wrong.
- **Q3.2** — You need to test `regex_match('^gcr\.io/.*$', spec.containers[0].image)` from an interactive bash shell. Name the two characters that make inline quoting hazardous here, and give the recommended way to run it.
- **Q3.3** — Beyond quoting, name two operational reasons to keep expressions in `-q` files rather than shell history.

---

## Exercise 4 — Projections, pipes, and scope: the semantics that decide correctness

**Goal:** understand *why* an expression that looks right returns `[]`.

1. Two expressions that differ by one pipe:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[*].name[0]'
[]

$ kyverno jp query -i pod-good.yaml 'spec.containers[*].name | [0]'
"api"
```

2. Confirm the shapes with the AST:

```bash
$ kyverno jp parse 'spec.containers[*].name[0]'
$ kyverno jp parse 'spec.containers[*].name | [0]'
```

Representative output for a subexpression (formatting differs slightly between releases):

```
ASTSubexpression {
  children: {
    ASTField {
      value: "spec"
    }
    ASTField {
      value: "containers"
    }
  }
}
```

3. Show that a pipe resets the current node:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[].image | metadata.name'
null
```

4. Collect *all* container images — the idiom Kyverno policies use, because `containers` alone is an incomplete security check:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.[containers, initContainers, ephemeralContainers][].image'
[
  "docker.io/library/busybox:1.36",
  "registry.example.io/payments/checkout:1.29.3",
  "registry.example.io/observability/exporter:0.14.0"
]
```

5. Filter that flattened list — note the pipe, without which the filter would apply *inside* the projection:

```bash
$ kyverno jp query -i pod-good.yaml "spec.[containers, initContainers, ephemeralContainers][].image | [?starts_with(@, 'registry.example.io')]"
[
  "registry.example.io/payments/checkout:1.29.3",
  "registry.example.io/observability/exporter:0.14.0"
]
```

6. Inspect operator precedence without arguing about it:

```bash
$ kyverno jp parse 'a || b && c'
$ kyverno jp parse 'a || b | c'
```

**Check your understanding**

- **Q4.1** — Explain, step by step, why `spec.containers[*].name[0]` evaluates to `[]`.
- **Q4.2** — In step 4 the pod has no `ephemeralContainers`. Trace what the multiselect list and the flatten operator do with that missing key, and why the final result still has exactly three strings.
- **Q4.3** — From the ASTs in step 6, rank `||`, `&&` and `|` by binding strength, and give the resulting tree shape for `a || b && c`.
- **Q4.4** — A colleague's image policy checks `spec.containers[].image` only. Which two workload features let an attacker or a careless developer bypass it entirely?

---

## Exercise 5 — Kyverno's custom filters

**Goal:** exercise the filters that exist *only* in Kyverno's interpreter — the reason `jp` exists as a separate tool instead of a generic JMESPath CLI.

1. String manipulation:

```bash
$ kyverno jp query -u "to_upper('kyverno')"
KYVERNO

$ kyverno jp query "split('registry.example.io/payments/checkout', '/')"
[
  "registry.example.io",
  "payments",
  "checkout"
]

$ kyverno jp query -u "truncate('kubernetes-is-verbose', \`10\`)"
kubernetes
```

2. Two different matchers — regex and Kyverno's wildcard pattern. Use query files, because both need raw strings and one needs anchors:

```bash
cat > queries/regex.jmespath <<'EOF'
regex_match('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$', metadata.name)
EOF
cat > queries/pattern.jmespath <<'EOF'
pattern_match('registry.example.io/*', spec.containers[0].image)
EOF
```

```bash
$ kyverno jp query -i pod-good.yaml -q queries/regex.jmespath
true
$ kyverno jp query -i pod-good.yaml -q queries/pattern.jmespath
true
```

3. Version constraints:

```bash
$ kyverno jp query -i pod-good.yaml "semver_compare(metadata.labels.\"app.kubernetes.io/version\", '>=1.28.0')"
true
$ kyverno jp query -i pod-good.yaml "semver_compare(metadata.labels.\"app.kubernetes.io/version\", '>=1.30.0')"
false
```

4. Arithmetic over Kubernetes quantities and Go durations — not something plain JMESPath can do:

```bash
$ kyverno jp query "add('12Ki', '2Ki')"
"14Ki"
$ kyverno jp query 'divide(`10`, `4`)'
2.5
$ kyverno jp query 'modulo(`10`, `3`)'
1
```

5. Encoding and parsing — the pattern used to read structured data out of a ConfigMap context:

```bash
$ kyverno jp query -u "base64_decode('SGVsbG8sIEt5dmVybm8h')"
Hello, Kyverno!

$ kyverno jp query "parse_json('{\"limits\":{\"maxReplicas\":5}}').limits.maxReplicas"
5
```

6. Turning a map into an iterable list — the prerequisite for `foreach` over labels or annotations:

```bash
$ kyverno jp query -i pod-good.yaml "sort_by(items(metadata.labels, 'key', 'value'), &key)"
[
  {
    "key": "app.kubernetes.io/name",
    "value": "checkout"
  },
  {
    "key": "app.kubernetes.io/version",
    "value": "1.29.3"
  },
  {
    "key": "tier",
    "value": "backend"
  }
]
```

7. Time. The fixture was created on `2026-08-01T09:15:00Z`:

```bash
$ kyverno jp query -i pod-good.yaml "time_since('', metadata.creationTimestamp, '2026-08-13T09:15:00Z')"
"288h0m0s"

$ kyverno jp query -i pod-good.yaml "time_before(metadata.creationTimestamp, '2026-08-10T00:00:00Z')"
true
```

8. Now run a non-deterministic one twice:

```bash
$ kyverno jp query "random('[0-9a-z]{5}')"
$ kyverno jp query "random('[0-9a-z]{5}')"
```

9. *(Advanced, optional)* Certificate introspection:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
  -subj "/CN=kyverno-demo" -days 30 -out /tmp/demo.pem 2>/dev/null
{ echo 'cert: |'; sed 's/^/  /' /tmp/demo.pem; } > cert.yaml
```

```bash
$ kyverno jp query -i cert.yaml -u 'x509_decode(cert).Subject.CommonName'
kyverno-demo

$ kyverno jp query -i cert.yaml 'x509_decode(cert).subject.commonName'
null
```

**Check your understanding**

- **Q5.1** — Standard JMESPath has no notion of `12Ki`. What must `add`/`subtract`/`sum` do to their string arguments before operating, and which two Kubernetes policy use cases does this unlock?
- **Q5.2** — `regex_match` and `pattern_match` both returned `true`. What is the difference in their matching language, and which one is safe to hand to an application team that does not write regular expressions?
- **Q5.3** — In step 6, why did the exercise wrap `items(...)` in `sort_by(..., &key)`? What does the `&` do?
- **Q5.4** — Step 8 gives a different answer each run, and `time_now()` behaves the same way. What does that mean for a mutation rule that uses them, and for reproducing a policy decision after the fact?
- **Q5.5** — Step 9's second command returned `null`. Give the precise reason, and state the general rule it illustrates about `x509_decode` output.

---

## Exercise 6 — Debugging a policy the way you would in production

**Goal:** the loop that this topic exists for — take an expression out of a policy, feed it the data admission would feed it, and find the bug offline.

1. Write the policy under investigation. It is meant to require that every image comes from `registry.example.io`, and it never denies anything:

```bash
cat > require-registry.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-approved-registry
spec:
  validationFailureAction: Enforce
  background: false
  rules:
  - name: approved-registry-only
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "All images must come from registry.example.io"
      deny:
        conditions:
          all:
          - key: "{{ request.object.spec.containers[].image | contains(@, 'registry.example.io') }}"
            operator: Equals
            value: false
EOF
```

2. Reconstruct the data the rule sees. Build the `request` wrapper with `jp` itself — no extra tooling needed:

```bash
$ kyverno jp query -i pod-good.yaml \
  "{request: {operation: 'CREATE', userInfo: {username: 'system:serviceaccount:ci:deployer'}, object: @}}" \
  > admission.json

$ kyverno jp query -i admission.json -u 'request.object.metadata.name'
checkout-api
```

3. Evaluate the rule's expression verbatim — everything between the `{{ }}`:

```bash
$ kyverno jp query -i admission.json "request.object.spec.containers[].image | contains(@, 'registry.example.io')"
false
```

4. Isolate the operand and the function separately:

```bash
$ kyverno jp query -i admission.json 'request.object.spec.containers[].image'
$ kyverno jp query "contains(['a/b', 'a/c'], 'a')"
$ kyverno jp query "contains('a/b/c', 'a/b')"
```

5. Write the corrected expression into a query file:

```bash
cat > queries/approved-registry.jmespath <<'EOF'
length(request.object.spec.[containers, initContainers, ephemeralContainers][].image) ==
length(request.object.spec.[containers, initContainers, ephemeralContainers][].image | [?starts_with(@, 'registry.example.io')])
EOF
```

```bash
$ kyverno jp query -i admission.json -q queries/approved-registry.jmespath
false
```

6. Find out *which* image is at fault:

```bash
$ kyverno jp query -i admission.json "request.object.spec.[containers, initContainers, ephemeralContainers][].image | [?!starts_with(@, 'registry.example.io')]"
[
  "docker.io/library/busybox:1.36"
]
```

7. Produce a passing fixture and re-run, so you have proved both branches:

```bash
sed 's|docker.io/library/busybox:1.36|registry.example.io/base/busybox:1.36|' pod-good.yaml > pod-fixed.yaml
kyverno jp query -i pod-fixed.yaml \
  "{request: {operation: 'CREATE', object: @}}" > admission-fixed.json
```

```bash
$ kyverno jp query -i admission-fixed.json -q queries/approved-registry.jmespath
true
```

**Check your understanding**

- **Q6.1** — State exactly why the original expression returned `false` for a pod whose main images *do* match. What does `contains` do when its first argument is an array?
- **Q6.2** — Even after fixing `contains`, the original rule would still have been wrong in a second, independent way. What was it, and which step of this exercise exposed it?
- **Q6.3** — Step 2 built the `request` wrapper with a multiselect hash. Which two Kyverno variables commonly used in policies still cannot be reproduced this way, and how would you supply them?
- **Q6.4** — The corrected expression returns `true` when the pod is compliant, but the policy's `deny.conditions` block compares against `false`. Explain why that is correct rather than inverted.

---

## Exercise 7 — Wiring `jp` into a workflow

**Goal:** use `jp` as a component — in a shell pipeline, against live objects, and in CI.

1. Stdin instead of `-i`:

```bash
$ cat pod-good.yaml | kyverno jp query 'metadata.name'
"checkout-api"
```

2. Capture a value into a shell variable — this is what `-u` is for:

```bash
$ IMG=$(kyverno jp query -u -i pod-good.yaml 'spec.containers[0].image')
$ echo "$IMG"
registry.example.io/payments/checkout:1.29.3
```

Compare with the same command without `-u`, and note the literal `"` characters that end up inside `$IMG`.

3. *(Optional — requires a cluster)* Query a live object:

```bash
$ kubectl run probe --image=registry.example.io/base/busybox:1.36 --restart=Never --dry-run=client -o json \
  | kyverno jp query 'spec.containers[].image'
```

```bash
$ kubectl get pods -A -o json \
  | kyverno jp query -c "items[?!starts_with(spec.containers[0].image, 'registry.example.io')].{ns: metadata.namespace, name: metadata.name}"
```

4. A CI gate. `jp query` exits non-zero on a syntax or evaluation error, but a *false* result is still a successful run, so you must test the value:

```bash
cat > gate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
result=$(kyverno jp query -u -i "$1" -q queries/approved-registry.jmespath)
if [[ "$result" != "true" ]]; then
  echo "FAIL: $1 uses images outside registry.example.io" >&2
  kyverno jp query -i "$1" "spec.[containers, initContainers, ephemeralContainers][].image | [?!starts_with(@, 'registry.example.io')]" >&2
  exit 1
fi
echo "OK: $1"
EOF
chmod +x gate.sh
```

5. Note that the query file from Exercise 6 expects an AdmissionReview shape. Adapt it for bare manifests and run the gate on both fixtures:

```bash
sed 's/request\.object\.//g' queries/approved-registry.jmespath > queries/approved-registry-bare.jmespath
sed -i 's|queries/approved-registry.jmespath|queries/approved-registry-bare.jmespath|' gate.sh
```

```bash
$ ./gate.sh pod-fixed.yaml
OK: pod-fixed.yaml
$ ./gate.sh pod-good.yaml
FAIL: pod-good.yaml uses images outside registry.example.io
[
  "docker.io/library/busybox:1.36"
]
$ echo $?
1
```

**Check your understanding**

- **Q7.1** — Why does the gate script compare the output to the string `true` rather than relying on the exit code alone?
- **Q7.2** — In step 5 you had to strip `request.object.` from the query. What does this tell you about reusing one expression for both admission-time debugging and static manifest linting, and how would you avoid the `sed` in a real repository?
- **Q7.3** — `kyverno test` also runs offline in CI. What does `jp query` give you that `kyverno test` does not, and at which point in authoring a policy do you use each?

---

## Quick reference

```bash
kyverno jp function                       # full catalogue
kyverno jp function NAME [NAME...]        # signature + note
kyverno jp parse 'EXPR'                   # AST; settles precedence and projection questions
kyverno jp parse -f FILE                  # AST from a file
kyverno jp query -i INPUT 'EXPR'          # evaluate against JSON/YAML
kyverno jp query -q FILE -i INPUT         # expression from a file (use this for anything non-trivial)
cat obj.json | kyverno jp query 'EXPR'    # input from stdin
  -u / --unquoted                         # print bare strings (for shell capture)
  -c / --compact                          # single-line JSON (for machine consumption)
```

Quoting rule of thumb:

| Expression contains | Shell wrapper |
|---|---|
| `` `literals` `` and/or `"quoted.identifiers"` | `'single quotes'` |
| `'raw strings'` only | `"double quotes"` |
| both, or regexes with `$` | `-q` query file |

Custom-filter families to be fluent in (always confirm signatures with `kyverno jp function NAME` on *your* version): string (`to_upper`, `to_lower`, `trim`, `trim_prefix`, `split`, `replace`, `replace_all`, `truncate`, `compare`, `equal_fold`), matching (`regex_match`, `pattern_match`, `regex_replace_all`, `label_match`), arithmetic (`add`, `subtract`, `multiply`, `divide`, `modulo`, `round`, `sum`), conversion (`to_boolean`, `parse_json`, `parse_yaml`, `base64_encode`, `base64_decode`, `items`, `object_from_lists`, `path_canonicalize`), versioning (`semver_compare`), time (`time_since`, `time_now`, `time_now_utc`, `time_add`, `time_parse`, `time_utc`, `time_before`, `time_after`, `time_truncate`, `time_to_cron`), and security (`x509_decode`, `random`).

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1** — Input is JSON *or* YAML; `jp query` deserialises YAML into the same generic data model JMESPath operates on. Output is always JSON, because the result of an expression is a JSON value, and JSON is what a downstream tool (or Kyverno's own variable substitution) consumes. A string result therefore appears with its quotes; `-u` strips them, but only when the result really is a string.

**A0.2** — Anything sourced from a `context` at admission time: `configmap` lookups, `apiCall` results, `imageRegistry` data, `globalReference` entries, and the `serviceAccountName`/`userInfo` fields that come from the AdmissionRequest rather than the object. `jp` evaluates expressions against data you hand it, so you must reconstruct that data yourself — dump the ConfigMap or API response into your input file under the same key the policy's `context` binds it to, then evaluate the expression unchanged.

**A0.3** — The function catalogue is release-specific: filters are added (and occasionally change signature) across Kyverno versions, so any written list is a snapshot of one version. `kyverno jp function NAME` reports what the binary you are actually running will execute — which is the same binary semantics as the Kyverno controller of the matching version.

### Exercise 1

**A1.1** — Yes, `length` resolves. Kyverno does not run a "Kyverno-only" function set alongside JMESPath; it builds one JMESPath interpreter and registers its custom filters into that interpreter's single function table. `jp function` walks that table, so built-ins and custom filters appear together — which is also why a Kyverno expression can freely mix `length`, `sort_by` and `semver_compare` in one line.

**A1.2** — `kyverno jp function semver_compare`, which prints the signature (`semver_compare(string, string) bool`). The website documents whatever version the docs were built from; your cluster runs a specific version, and the two drift. The binary is the source of truth for the binary.

**A1.3** — Run `kyverno jp function <name>` with each CLI version (or `kubectl exec` into the respective controller image). A missing entry on the older side confirms that the expression depends on a filter that version does not have — the fix is either a version bump or an expression rewritten in terms of filters both versions provide.

### Exercise 2

**A2.1** — JMESPath propagates absence as `null` instead of raising. `securityContext` is missing on `metrics`, so `securityContext.capabilities` evaluates to `null`, and `null.drop` is `null` again. The comparison `null == null` is `true`, so the container is selected. This "null-safe navigation" is why filters over heterogeneous Kubernetes objects work at all — and why they can silently select more than you intended.

**A2.2** — A multiselect hash produces a map, which is serialised by Go's JSON encoder; that encoder sorts map keys alphabetically. Output key order is therefore alphabetical, not source order, and no consumer may depend on positional order — parse by key (`jq '.pod'`) or use `-u` with a single scalar expression.

**A2.3** — Because `null` is indistinguishable from "the check passed" in a boolean context downstream, and the exit code gives you no warning. A typo in a field path, a wrong quoting of a dotted key, or a projection that collapsed to nothing all yield `null` with exit 0. In a policy this becomes a rule that matches nothing and denies nothing — a green dashboard covering an unenforced control. Treat a `null` from `jp query` as "prove this is intentional", never as a pass.

### Exercise 3

**A3.1** — For the ordering operators (`<`, `<=`, `>`, `>=`), the JMESPath specification says that if either operand is not a number, the result is `null` — not `false`, and not an error. Annotation values are always strings in Kubernetes, so the comparison never produces a boolean. A `deny` condition comparing that `null` against `true`/`false` never fires, so the rule is inert while still appearing in the policy report as configured. The fix is `to_number(...)` on the annotation before comparing.

**A3.2** — The backslash (`\.` in the regex, which bash may consume inside double quotes) and `$` (parameter expansion inside double quotes; `$1`-style capture references in `regex_replace_all` have the same problem). Anchored regexes also need `^`/`$` intact. Put the expression in a file and run `kyverno jp query -i input.yaml -q queries/regex.jmespath`, where no shell quoting applies at all.

**A3.3** — (1) The expression becomes reviewable and diffable: it lives in git next to the policy, so a change to a security-relevant condition goes through code review. (2) It is reusable by CI without re-quoting, eliminating the class of bug where the expression that was tested locally differs by one escaped character from the one that runs in the pipeline. (A third: the identical text can be pasted into the policy's `{{ }}` without unescaping.)

### Exercise 4

**A4.1** — `spec.containers[*]` starts a projection: everything to its right is applied to each element and the results are collected. `.name` yields a string per container. `[0]` is an index expression, and indexing a *string* (a non-array) yields `null` in JMESPath. Projections discard `null` results, so both elements drop out and the collected list is empty: `[]`. Adding `| [0]` first terminates the projection — the pipe's left side evaluates to the complete list `["api","metrics"]` — and only then is `[0]` applied to that list.

**A4.2** — The multiselect list `spec.[containers, initContainers, ephemeralContainers]` evaluates each expression against `spec`; the missing `ephemeralContainers` becomes `null`, giving `[[api, metrics], [migrate], null]`. The flatten operator `[]` merges any element that is an array and keeps any element that is not, producing `[api, metrics, migrate, null]`. The trailing `.image` is a projection over that list: three container objects yield three strings, and `null.image` yields `null`, which the projection discards. Three strings remain.

**A4.3** — `&&` binds tightest, then `||`, then `|` (the pipe is the lowest-precedence operator in JMESPath). `a || b && c` therefore parses as `ASTOrExpression{ ASTField(a), ASTAndExpression{ ASTField(b), ASTField(c) } }` — that is, `a || (b && c)`. `a || b | c` parses as `ASTPipe{ ASTOrExpression{a, b}, c }`.

**A4.4** — `initContainers` and `ephemeralContainers`. An init container runs with the same access to volumes and (unless separately constrained) the same registry freedom, and an ephemeral container can be injected into a running pod via `kubectl debug`. Any image, capability or registry rule that enumerates only `spec.containers` is bypassable through either. The `spec.[containers, initContainers, ephemeralContainers][]` idiom exists precisely for this.

### Exercise 5

**A5.1** — They parse each string argument into a typed value first: a Kubernetes `resource.Quantity` (`12Ki`, `250m`, `2Gi`) or a Go `time.Duration` (`12h`, `30m`), falling back to a plain number. The arithmetic happens on the typed value and the result is re-serialised in the same form. This unlocks (1) resource governance — summing container requests/limits and comparing the total against a namespace budget, and (2) time/duration arithmetic — computing expiry windows and grace periods inside a rule.

**A5.2** — `regex_match` takes a full regular expression (RE2 syntax: anchors, character classes, quantifiers, alternation, capture groups). `pattern_match` takes Kyverno's much smaller wildcard pattern language — essentially `*` for "any sequence" and `?` for "any single character" — the same matching used in Kyverno's `match`/`exclude` blocks. Hand `pattern_match` to application teams: it has no catastrophic-backtracking or accidental-anchoring failure modes, and a mistake in it under-matches visibly rather than over-matching silently.

**A5.3** — `items()` converts a map into a list of key/value objects, and map iteration order is not something you should rely on; sorting makes the output stable so that diffs, tests and golden files do not flap. The `&` creates an *expression reference* — it passes the expression `key` to `sort_by` as a value to be evaluated once per element, rather than evaluating it immediately in the current scope. `sort_by`, `max_by`, `min_by` and `map` all take one.

**A5.4** — A mutation rule using `random()` or `time_now()` produces a different result on every evaluation, so it is not idempotent: re-running it (background scan, re-admission on update, a retried webhook call) can keep changing the object, and two evaluations of the same input are not comparable. It also means a policy decision cannot be reproduced after the fact from the object alone — you must have captured the value at the time. Confine these functions to genuinely one-shot mutations (generating a name suffix on CREATE) and never use them in `validate` conditions.

**A5.5** — `x509_decode` returns the certificate marshalled from Go's `crypto/x509` structures, so the field names are Go's exported, capitalised names: `Subject`, `Issuer`, `NotBefore`, `NotAfter`, `SerialNumber`, `DNSNames`. JMESPath identifiers are case-sensitive, so `subject.commonName` matches nothing and the null-safe navigation returns `null` instead of erroring. The general rule: never guess the shape of a function's output — print the whole object (`x509_decode(cert)`) once, then write the path against what you actually see.

### Exercise 6

**A6.1** — `contains` is overloaded. When the first argument is a *string*, it tests for a substring; when it is an *array*, it tests for **membership by exact equality**. `request.object.spec.containers[].image` is an array, so the expression asked "is the exact string `registry.example.io` one of the elements?" — no element equals it, so the answer is `false`. The images merely *start with* it. The correct operator for a prefix test on each element is `starts_with(@, '…')` inside a filter, applied after a pipe terminates the projection.

**A6.2** — It only inspected `spec.containers`, so the `docker.io/library/busybox:1.36` init container was never examined. Step 6 exposed it: the corrected expression, extended to `spec.[containers, initContainers, ephemeralContainers][]`, returns `false` for a pod whose two ordinary containers are fully compliant, and the diagnostic filter names the offending image. Two independent bugs — a wrong function and an incomplete field path — happened to cancel into the same symptom of "the policy never denies anything".

**A6.3** — Anything Kyverno resolves from a `context` (`configMap`, `apiCall`, `imageRegistry`, `globalReference`) and the image metadata under `images.containers.<name>` that the image-verification machinery populates. You supply them by adding the same keys to your input document under the names the `context` binds — for example dump the ConfigMap's `.data` into a top-level key matching the context entry's `name`, then evaluate the expression unchanged.

**A6.4** — The condition is a *deny* condition: it fires when the condition set is satisfied. The expression states "all images are approved"; the rule denies when that equals `false`, i.e. when at least one image is not approved. A compliant pod evaluates the expression to `true`, the condition `true Equals false` is not satisfied, and admission proceeds. Reading a `deny` block as though it were a `pattern` block is a frequent source of inverted policies — evaluate the expression with `jp query` against both a compliant and a non-compliant fixture, as step 7 does, and confirm both branches before shipping.

### Exercise 7

**A7.1** — Exit code and result value answer different questions. `jp query` exits non-zero when it could not *evaluate* the expression (syntax error, bad input file, type error in a function call); it exits zero whenever evaluation succeeded — including when the answer is `false`, and including when the answer is `null`. A gate that trusts the exit code alone passes every non-compliant manifest and every mistyped field path. Comparing the printed value to the literal `true` also rejects `null`, which is exactly the behaviour you want.

**A7.2** — The expression is coupled to the *shape* of its input, not just to the fields it reads: at admission the object is nested under `request.object`, while a manifest on disk is the object itself. Rather than `sed`, normalise the input instead of the expression — wrap bare manifests into the admission shape once (`kyverno jp query -i pod.yaml "{request: {object: @}}"`, as in Exercise 6 step 2) and keep exactly one copy of the expression, the one that also appears inside the policy's `{{ }}`. One expression, one place to review, one place to fix.

**A7.3** — `kyverno test` proves that a whole policy produces the expected pass/fail/skip results for a set of resources; it is the regression suite, and it is what you run in CI on every change. `jp query` proves what a *single sub-expression* evaluates to against a specific input, which is what you need while the policy is still wrong and you do not yet know which of its five clauses is at fault. The order in practice: `jp function` to find the filter, `jp parse` to confirm the expression parses the way you think, `jp query` to confirm it returns the value you expect on real data, then paste it into the policy and lock the behaviour in with `kyverno test`.

</details>

---

## Sources

- CNCF Curriculum (KCA) — <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- Kyverno documentation — <https://kyverno.io/docs/>
- Kyverno CLI, `jp` command — <https://kyverno.io/docs/kyverno-cli/usage/jp/>
- Kyverno JMESPath custom filters — <https://kyverno.io/docs/writing-policies/jmespath/>
- JMESPath specification (projections, pipes, operator precedence, comparison semantics) — <https://jmespath.org/specification.html>
- JMESPath tutorial — <https://jmespath.org/tutorial.html>
- Kyverno source — <https://github.com/kyverno/kyverno>
- Kubernetes API reference, Pod spec (`containers`, `initContainers`, `ephemeralContainers`) — <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/>