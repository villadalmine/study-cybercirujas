# CKS 4.4 — Guided Exercises: Static Analysis of User Workloads and Container Images

> **Domain:** Supply Chain Security (weight 5) — *Perform static analysis of user workloads and container images (e.g. Kubesec, KubeLinter)*
> **Exam version:** CKS 1.34
> **Format:** numbered steps you execute, followed by verification questions. All answers are in the collapsible section at the end.

---

## What "static analysis" means here, precisely

Static analysis in this domain means **deriving security conclusions from a manifest or an image's metadata without running it**. It is cheap, deterministic, and runs before the API server ever sees the object — which is exactly its value and exactly its limit:

| Layer | Tool class | Sees | Cannot see |
|---|---|---|---|
| Source manifest / Helm chart | Kubesec, KubeLinter, `trivy config`, Checkov | Author intent, YAML as written | API defaulting, mutating webhooks, live drift |
| Image config + layers | `skopeo inspect --config`, `crane config`, `docker history`, `trivy image --scanners secret` | `USER`, `ENV`, `ENTRYPOINT`, layer commands, baked secrets | Runtime behaviour, syscalls |
| Admission | PSA, Kyverno/Gatekeeper, kubesec-webhook | The *effective* object after defaulting and mutation | Post-admission mutation by controllers |
| Runtime | Falco, eBPF, audit log | Actual syscalls and process trees | Intent |

Static analysis is the **first** gate, not the only one. Exercise 8 makes the gap between "what the YAML said" and "what the cluster runs" concrete.

> ⚠️ **Version discipline.** Point values, check names, and flags below reflect **kubesec v2.14.x** and **KubeLinter v0.7.x**. Both projects change rules between releases. Never memorise a number — read the `scoring[].points` and `check:` fields in *your own* output. In the exam, the first command you run against an unfamiliar tool is `<tool> --help`.

---

## Exercise 0 — Lab environment and workspace

**Goal:** get both scanners installed, verify versions, and lay down a workspace you will reuse for every exercise.

1. Create the workspace:

```bash
mkdir -p ~/cks-4.4/{manifests,reports,chart}
cd ~/cks-4.4
```

2. Install Kubesec (static binary, no daemon, no cluster access required):

```bash
KUBESEC_VER=v2.14.2
curl -sSL "https://github.com/controlplaneio/kubesec/releases/download/${KUBESEC_VER}/kubesec_linux_amd64.tar.gz" \
  | tar -xz -C /tmp kubesec
sudo install -m 0755 /tmp/kubesec /usr/local/bin/kubesec
kubesec version
```

Expected:

```
2.14.2
```

3. Install KubeLinter:

```bash
curl -sSLO https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux.tar.gz
tar -xzf kube-linter-linux.tar.gz kube-linter
sudo install -m 0755 kube-linter /usr/local/bin/kube-linter
rm -f kube-linter-linux.tar.gz kube-linter
kube-linter version
```

Expected (version will differ):

```
0.7.2
```

4. If you cannot install binaries (locked-down node, air-gapped exam-like environment), both ship as containers:

```bash
docker run --rm -i kubesec/kubesec:v2 scan /dev/stdin < manifests/01-payments-api.yaml
docker run --rm -v "$PWD":/dir:ro stackrox/kube-linter:latest lint /dir/manifests
```

5. Install `jq` — every machine-readable workflow in this topic depends on it:

```bash
sudo apt-get install -y jq 2>/dev/null || sudo dnf install -y jq
jq --version
```

6. Read both help screens **now**, before you need them under time pressure:

```bash
kubesec scan --help
kube-linter lint --help
kube-linter checks list --help
```

**Verification questions**

- **Q0.1** — Neither tool asked for a kubeconfig, a cluster, or credentials. What does that tell you about *when* in the delivery pipeline these tools are meant to run, and what class of misconfiguration they can therefore never detect?
- **Q0.2** — You ran the containerised kubesec with `scan /dev/stdin`. Why does that argument work, and what would break if you instead ran `docker run --rm kubesec/kubesec:v2 scan manifests/01-payments-api.yaml`?
- **Q0.3** — In the CKS exam you are not allowed to browse arbitrary sites. If you are handed `kube-linter` and told to "enable only the checks that flag privileged containers", which single command gives you the authoritative check name without leaving the terminal?

---

## Exercise 1 — A deliberately hostile manifest: your first Kubesec scan

**Goal:** learn to read Kubesec's JSON output as a *rule engine result*, not as a grade.

1. Write the workload under test. This is a realistic "it works on my laptop" manifest — every one of its sins appears in real clusters:

```bash
cat > manifests/01-payments-api.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: payments-api
  namespace: default
spec:
  hostNetwork: true
  hostPID: true
  containers:
    - name: api
      image: registry.example.com/payments-api:latest
      securityContext:
        privileged: true
        capabilities:
          add: ["SYS_ADMIN", "NET_ADMIN"]
      volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock
  volumes:
    - name: docker-sock
      hostPath:
        path: /var/run/docker.sock
EOF
```

2. Scan it:

```bash
kubesec scan manifests/01-payments-api.yaml
```

Expected output (abridged; your point values may differ by version):

```json
[
  {
    "object": "Pod/payments-api.default",
    "valid": true,
    "fileName": "manifests/01-payments-api.yaml",
    "message": "Failed with a score of -88 points",
    "score": -88,
    "scoring": {
      "critical": [
        {
          "id": "CapSysAdmin",
          "selector": "containers[] .securityContext .capabilities .add == SYS_ADMIN",
          "reason": "CAP_SYS_ADMIN is the most privileged capability and should always be avoided",
          "points": -30
        },
        {
          "id": "Privileged",
          "selector": "containers[] .securityContext .privileged == true",
          "reason": "Privileged containers can allow almost completely unrestricted host access",
          "points": -30
        },
        {
          "id": "VolumeMountDockerSock",
          "selector": "volumes[] .hostPath .path == /var/run/docker.sock",
          "reason": "Mounting the docker.socket leaks information about other containers and can allow container breakout",
          "points": -9
        },
        {
          "id": "HostNetwork",
          "selector": ".spec .hostNetwork == true",
          "reason": "Sharing the host's network namespace permits processes in the pod to communicate with processes bound to the host's loopback adapter",
          "points": -9
        },
        {
          "id": "HostPID",
          "selector": ".spec .hostPID == true",
          "reason": "Sharing the host's PID namespace allows visibility of processes on the host, potentially leaking information such as environment variables and configuration",
          "points": -9
        },
        {
          "id": "CapabilitiesAdded",
          "selector": "containers[] .securityContext .capabilities .add",
          "reason": "Capabilities were added that increase the potential for container breakout",
          "points": -1
        }
      ],
      "advise": [
        { "id": "ApparmorAny", "selector": ".metadata .annotations .\"container.apparmor.security.beta.kubernetes.io/nginx\"", "reason": "Well defined AppArmor policies may provide greater protection from unknown threats.", "points": 3 },
        { "id": "AllowPrivilegeEscalation", "selector": "containers[] .securityContext .allowPrivilegeEscalation == false", "reason": "Ensure a non-root process can not gain more privileges", "points": 7 },
        { "id": "ServiceAccountName", "selector": ".spec .serviceAccountName", "reason": "Service accounts restrict Kubernetes API access and should be configured with least privilege", "points": 1 },
        { "id": "SeccompAny", "selector": ".metadata .annotations .\"container.seccomp.security.alpha.kubernetes.io/pod\"", "reason": "Seccomp profiles set minimum privilege and secure against unknown threats", "points": 1 },
        { "id": "RequestsCPU", "selector": "containers[] .resources .requests .cpu", "reason": "Enforcing CPU requests aids a fair balancing of resources across the cluster", "points": 1 },
        { "id": "LimitsMemory", "selector": "containers[] .resources .limits .memory", "reason": "Enforcing memory limits prevents DOS via resource exhaustion", "points": 1 }
      ],
      "passed": []
    }
  }
]
```

3. Extract just the numbers — this is the shape every CI script uses:

```bash
kubesec scan manifests/01-payments-api.yaml \
  | jq -r '.[] | "\(.object)\t\(.score)\t\(.message)"'
```

```
Pod/payments-api.default	-88	Failed with a score of -88 points
```

4. List only the critical findings, sorted by damage:

```bash
kubesec scan manifests/01-payments-api.yaml \
  | jq -r '.[].scoring.critical[] | "\(.points)\t\(.id)\t\(.reason)"' \
  | sort -n
```

5. Check the exit code — the single most important fact for automation:

```bash
kubesec scan manifests/01-payments-api.yaml >/dev/null; echo "exit=$?"
```

```
exit=2
```

6. Now feed it something that is *not* a workload and observe the failure mode:

```bash
cat > manifests/01b-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: payments-api
spec:
  selector:
    app: payments-api
  ports:
    - port: 443
      targetPort: 8443
EOF

kubesec scan manifests/01b-service.yaml; echo "exit=$?"
```

Record exactly what it prints and what exit code it returns. Do not assume — this behaviour is version-sensitive and it is precisely what silently breaks a naive `for f in manifests/*.yaml` loop.

**Verification questions**

- **Q1.1** — Add up the `points` values in the `critical` array by hand. Do they equal the reported `score`? What does that tell you about how the score is computed, and why is the *number* a poor thing to report to a security stakeholder?
- **Q1.2** — `Privileged` costs −30 and `CapSysAdmin` costs −30, but a privileged container already has every capability including `CAP_SYS_ADMIN`. Why does Kubesec charge for both, and what does this double-counting reveal about the design of rule-based scoring?
- **Q1.3** — The `advise` array contains `AllowPrivilegeEscalation` worth **+7**, the largest positive award in the ruleset. Given this pod is already `privileged: true`, what would actually change at runtime if you set `allowPrivilegeEscalation: false` and left everything else alone? What is the security lesson about optimising for the score?
- **Q1.4** — The `ApparmorAny` selector in the output literally references a container named `nginx`, but our container is named `api`. Explain what that selector is really doing and why the AppArmor award will not fire for this pod.
- **Q1.5** — Exit code 2, not 1. Why does that distinction matter in a `set -euo pipefail` CI script, and what is the difference between "the scan failed" and "the scanner failed"?
- **Q1.6** — Report what step 6 did with the `Service`. What is the operational consequence for a repo where manifests, Services, ConfigMaps and CRDs live in the same directory?

---

## Exercise 2 — Driving the score positive: iterative hardening

**Goal:** remediate the workload one control at a time and watch each rule flip from `advise`/`critical` to `passed`. This is how you learn the ruleset — not by reading it.

1. Write the hardened version. Every field here maps to a specific Kubesec rule and to the **Restricted** Pod Security Standard:

```bash
cat > manifests/02-payments-api-hardened.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: payments-api
  namespace: payments
  annotations:
    # Deprecated since Kubernetes 1.30 — kept here ONLY to demonstrate scanner lag.
    # See Q2.4 before you copy this into anything real.
    container.apparmor.security.beta.kubernetes.io/api: runtime/default
spec:
  serviceAccountName: payments-api
  automountServiceAccountToken: false
  hostNetwork: false
  hostPID: false
  hostIPC: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 20001
    runAsGroup: 20001
    fsGroup: 20001
    seccompProfile:
      type: RuntimeDefault
    appArmorProfile:
      type: RuntimeDefault
  containers:
    - name: api
      image: registry.example.com/payments-api@sha256:5f8f1a4e2c9b6d0a7e3c1b8f4d2a9c6e0b7d3f1a8c5e2b9d6f0a3c7e1b4d8f2a
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 20001
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "500m"
          memory: "512Mi"
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/app
  volumes:
    - name: tmp
      emptyDir: {}
    - name: cache
      emptyDir: {}
EOF
```

2. Scan it:

```bash
kubesec scan manifests/02-payments-api-hardened.yaml | jq '.[] | {score, message}'
```

Expected (approximate — read your own output):

```json
{
  "score": 18,
  "message": "Passed with a score of 18 points"
}
```

3. See exactly which rules you earned:

```bash
kubesec scan manifests/02-payments-api-hardened.yaml \
  | jq -r '.[].scoring.passed[] | "+\(.points)\t\(.id)"' | sort -rn
```

```
+7	AllowPrivilegeEscalation
+1	CapDropAll
+1	CapDropAny
+1	LimitsCPU
+1	LimitsMemory
+1	ReadOnlyRootFilesystem
+1	RequestsCPU
+1	RequestsMemory
+1	RunAsNonRoot
+1	RunAsUser10000
+1	SeccompAny
+1	ServiceAccountName
```

4. Diff the two scans mechanically — this is the artefact you attach to a change request:

```bash
diff <(kubesec scan manifests/01-payments-api.yaml \
        | jq -r '.[].scoring | (.critical//[])[].id' | sort) \
     <(kubesec scan manifests/02-payments-api-hardened.yaml \
        | jq -r '.[].scoring | (.critical//[])[].id' | sort)
```

5. Now break it deliberately, one field at a time, and re-scan after each edit. Do this **five times**, recording the delta:

```bash
# a) remove capabilities.drop
# b) set readOnlyRootFilesystem: false
# c) set runAsUser: 999
# d) delete resources.limits
# e) add hostIPC: true at pod level
```

```bash
for variant in a b c d e; do
  echo -n "$variant: "
  kubesec scan "manifests/02-variant-${variant}.yaml" | jq -r '.[].score'
done
```

**Verification questions**

- **Q2.1** — In step 5c you changed `runAsUser` from `20001` to `999`. The pod still does not run as root. Why did the score drop anyway, and what real-world attack does the `RunAsUser10000` rule (`runAsUser > 10000`) actually mitigate?
- **Q2.2** — `CapDropAll` and `CapDropAny` are separate rules worth +1 each, yet `drop: ["ALL"]` satisfies both. Construct a `capabilities` block that satisfies `CapDropAny` but **not** `CapDropAll`, and explain when that weaker form is legitimate in production.
- **Q2.3** — The manifest sets `readOnlyRootFilesystem: true` and then mounts two `emptyDir` volumes. Why is that pairing almost always necessary, and what specific runtime failure do you see if you set the flag without adding the writable mounts?
- **Q2.4** — The manifest carries **both** `container.apparmor.security.beta.kubernetes.io/api` (annotation) and `securityContext.appArmorProfile` (field). Which one does Kubernetes 1.34 honour, which one does Kubesec's `ApparmorAny` rule look for, and what is the correct engineering response when a scanner rewards a deprecated field?
- **Q2.5** — The hardened pod scores 18. A second manifest in the same repo scores 22 because it adds an AppArmor annotation and a PVC with `ReadWriteOnce`. Is the 22-point workload more secure? Justify your answer in terms of what the score is and is not.
- **Q2.6** — `automountServiceAccountToken: false` is arguably the highest-value line in this manifest, yet it earns **zero** Kubesec points. Explain the risk it removes, and state the general principle this illustrates about score-driven security programmes.
- **Q2.7** — The image reference is pinned by digest (`@sha256:...`) rather than by tag. Kubesec has no rule for this. Which supply-chain attack does the digest pin defeat, and which of the two tools in this exercise *does* flag `:latest`?

---

## Exercise 3 — Kubesec for machines: exit codes, templates, and server mode

**Goal:** make Kubesec usable inside a gate, a webhook, or an editor plugin.

1. Control the failure exit code explicitly:

```bash
kubesec scan --exit-code 0 manifests/01-payments-api.yaml >/dev/null; echo "exit=$?"
kubesec scan --exit-code 7 manifests/01-payments-api.yaml >/dev/null; echo "exit=$?"
```

```
exit=0
exit=7
```

2. Render a human-readable report with a Go template instead of JSON:

```bash
cat > reports/kubesec.tmpl <<'EOF'
{{ range . }}{{ .Object }} => {{ .Score }}
{{ range .Scoring.Critical }}  [CRIT] {{ .Points }} {{ .ID }}
{{ end }}{{ range .Scoring.Advise }}  [ADV ] +{{ .Points }} {{ .ID }}
{{ end }}{{ end }}
EOF

kubesec scan --format template --template "$(cat reports/kubesec.tmpl)" \
  manifests/01-payments-api.yaml
```

3. Start Kubesec in HTTP server mode — this is the same code path the admission webhook uses:

```bash
kubesec http 8080 &
sleep 1
curl -sSX POST --data-binary @manifests/01-payments-api.yaml \
  http://localhost:8080/scan | jq '.[] | {score, message}'
```

```json
{
  "score": -88,
  "message": "Failed with a score of -88 points"
}
```

4. Compare with the hosted public API, then think hard about it:

```bash
curl -sSX POST --data-binary @manifests/02-payments-api-hardened.yaml \
  https://v2.kubesec.io/scan | jq '.[].score'
```

5. Stop the local server:

```bash
kill %1
```

6. Build a threshold gate — Kubesec has no built-in "minimum score" flag, so you enforce it yourself:

```bash
cat > kubesec-gate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MIN=${MIN:-5}
rc=0
shopt -s nullglob
for f in manifests/*.yaml; do
  out=$(kubesec scan --exit-code 0 "$f" 2>/dev/null) || { echo "SKIP  $f (not a workload)"; continue; }
  echo "$out" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || { echo "SKIP  $f"; continue; }
  while IFS=$'\t' read -r obj score; do
    if (( score < MIN )); then
      echo "FAIL  $obj  score=$score  (min=$MIN)  [$f]"
      rc=1
    else
      echo "PASS  $obj  score=$score  [$f]"
    fi
  done < <(echo "$out" | jq -r '.[] | "\(.object)\t\(.score)"')
done
exit $rc
EOF
chmod +x kubesec-gate.sh
MIN=10 ./kubesec-gate.sh; echo "gate exit=$?"
```

**Verification questions**

- **Q3.1** — Remove `--exit-code 0` from the gate script and re-run it. Predict the output before you run it, then explain exactly which shell option killed the loop and why `|| true` on the `kubesec` call alone would still not be enough.
- **Q3.2** — In step 4 you POSTed a manifest to `v2.kubesec.io`, a third-party service. Enumerate what you disclosed. Under what circumstances is that acceptable, and what is the drop-in remediation that preserves the workflow?
- **Q3.3** — Kubesec's server mode makes it trivially deployable as a `ValidatingAdmissionWebhook`. Name two properties of score-based validation that make it a *poor* fit for a hard admission gate compared with Pod Security Admission or a Kyverno/Gatekeeper policy.
- **Q3.4** — The gate uses `MIN=10` as its threshold. A developer adds `resources.requests.cpu`, `resources.requests.memory` and a `serviceAccountName` to a still-`privileged: true` pod. Can they pass a threshold gate this way? Redesign the gate's pass condition in one sentence so that they cannot.
- **Q3.5** — Why does the script test `jq -e 'type == "array" and length > 0'` before parsing? What input shape would otherwise cause the `while read` loop to silently process nothing while still reporting success?

---

## Exercise 4 — KubeLinter: the second opinion

**Goal:** KubeLinter is a *check engine*, not a scorer. Learn its output shape, its default check set, and where it disagrees with Kubesec.

1. Lint the hostile manifest:

```bash
kube-linter lint manifests/01-payments-api.yaml
```

Expected (abridged):

```
KubeLinter v0.7.2

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not have a read-only root file system (check: no-read-only-root-fs, remediation: Set readOnlyRootFilesystem to true in your container's securityContext.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" is not set to runAsNonRoot (check: run-as-non-root, remediation: Set runAsUser to a non-zero number and runAsNonRoot to true in your pod or container securityContext. Refer to https://kubernetes.io/docs/tasks/configure-pod-container/security-context/ for details.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not have a CPU request (check: unset-cpu-requirements, remediation: Set CPU requests for your container.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not have a memory limit (check: unset-memory-requirements, remediation: Set memory limits for your container.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" is privileged (check: privileged-container, remediation: Do not run your container as privileged unless it is required.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not drop NET_RAW capability (check: drop-net-raw-capability, remediation: Add NET_RAW to the list of dropped capabilities in the container securityContext.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not specify a liveness probe (check: no-liveness-probe, remediation: Specify a liveness probe in your container.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not specify a readiness probe (check: no-readiness-probe, remediation: Specify a readiness probe in your container.)

Error: found 8 lint errors
```

2. Confirm the exit code:

```bash
kube-linter lint manifests/01-payments-api.yaml >/dev/null 2>&1; echo "exit=$?"
```

```
exit=1
```

3. Enumerate the checks that ran by default — do not memorise, query:

```bash
kube-linter checks list --format json \
  | jq -r '.[] | select(.default == true) | .name' | sort | column -c 100
```

4. Count how many checks exist in total versus how many are on by default:

```bash
kube-linter checks list --format json | jq 'length'
kube-linter checks list --format json | jq '[.[] | select(.default)] | length'
```

5. Inspect one check in full, including its template and parameters:

```bash
kube-linter checks list --format json \
  | jq '.[] | select(.name == "privileged-container")'
```

6. Lint the hardened manifest and note what *still* fails:

```bash
kube-linter lint manifests/02-payments-api-hardened.yaml
```

7. Get machine-readable output for a pipeline:

```bash
kube-linter lint --format json manifests/ \
  | jq -r '.Reports[] | "\(.Check)\t\(.Object.K8sObject.Name)\t\(.Diagnostic.Message)"'
```

8. Produce SARIF for GitHub code scanning / SonarQube ingestion:

```bash
kube-linter lint --format sarif manifests/ > reports/kube-linter.sarif
jq '.runs[0].results | length' reports/kube-linter.sarif
```

**Verification questions**

- **Q4.1** — KubeLinter reported `no-liveness-probe` and `no-readiness-probe`; Kubesec did not mention probes at all. Kubesec reported `hostPID` and the `docker.sock` mount as critical; KubeLinter's default set did not flag either. What does this divergence tell you about running only one static analyser, and what is the correct policy?
- **Q4.2** — `unset-cpu-requirements` and `no-liveness-probe` are reliability checks, not security checks. Argue *both* sides: why does a security linter ship them on by default, and what is the cost of leaving them on in a security gate?
- **Q4.3** — `drop-net-raw-capability` fires even on containers that are not privileged. What can a process do with `CAP_NET_RAW` that justifies a dedicated check, and why is dropping it insufficient on its own when the pod also sets `hostNetwork: true`?
- **Q4.4** — In step 6, the hardened manifest still produced lint errors. Name the two checks that must still be firing given the manifest in Exercise 2, and explain why a security-hardened pod can legitimately fail a default KubeLinter run.
- **Q4.5** — KubeLinter exits `1`; Kubesec exits `2`. Write the single line of shell that treats *either* tool's non-zero exit as a gate failure while still distinguishing "findings" from "tool crashed" (hint: consider what exit code a missing binary or a parse error produces).
- **Q4.6** — The object identifier printed is `default/payments-api /v1, Kind=Pod`. If the same manifest omitted `metadata.namespace`, what would KubeLinter print, and why does that matter when you are diffing lint reports across environments?

---

## Exercise 5 — Tuning KubeLinter: config file, custom checks, Helm charts

**Goal:** turn KubeLinter from a noisy default into an enforceable organisational standard.

1. Create a configuration file that starts from *all* built-in checks and subtracts deliberately:

```bash
cat > .kube-linter.yaml <<'EOF'
checks:
  # Start from every built-in check, then remove what we consciously accept.
  addAllBuiltIn: true
  exclude:
    # Availability checks belong to the reliability gate, not the security gate.
    - "unset-cpu-requirements"
    - "no-anti-affinity"
    - "no-liveness-probe"
    - "no-readiness-probe"
    - "minimum-three-replicas"
  include:
    # Non-default checks we DO want, because they are supply-chain relevant.
    - "latest-tag"
    - "no-read-only-root-fs"
    - "privileged-ports"
    - "unsafe-sysctls"

customChecks:
  - name: require-owner-label
    template: "required-label"
    params:
      key: "owner"
    scope:
      objectKinds:
        - DeploymentLike
    description: "Every workload must declare an owning team so findings can be routed."
    remediation: "Add metadata.labels.owner=<team-slack-handle> to the workload."

  - name: forbid-default-serviceaccount
    template: "non-existent-service-account"
    scope:
      objectKinds:
        - DeploymentLike
    description: "Workloads must not silently fall back to the default ServiceAccount."
    remediation: "Create a dedicated ServiceAccount and set spec.serviceAccountName."
EOF
```

2. Discover which templates you can build custom checks from, and what parameters each accepts:

```bash
kube-linter templates list --format json \
  | jq -r '.[] | "\(.key)\t\(.description)"' | head -40
```

Look specifically at one template's parameter schema:

```bash
kube-linter templates list --format json \
  | jq '.[] | select(.key == "required-label")'
```

3. Run with the config and observe the difference in volume:

```bash
kube-linter lint --config .kube-linter.yaml manifests/ 2>&1 | tail -5
kube-linter lint manifests/ 2>&1 | tail -5
```

4. Build a minimal Helm chart and lint it **without rendering it yourself**:

```bash
mkdir -p chart/templates
cat > chart/Chart.yaml <<'EOF'
apiVersion: v2
name: payments
version: 0.1.0
appVersion: "1.0.0"
EOF

cat > chart/values.yaml <<'EOF'
image:
  repository: registry.example.com/payments-api
  tag: latest
replicas: 1
EOF

cat > chart/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-payments
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels: { app: payments }
  template:
    metadata:
      labels: { app: payments }
    spec:
      containers:
        - name: api
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          securityContext:
            allowPrivilegeEscalation: true
EOF

kube-linter lint --config .kube-linter.yaml chart/
```

5. Now try to feed the *same* chart to Kubesec:

```bash
kubesec scan chart/templates/deployment.yaml; echo "exit=$?"
```

Record the failure precisely, then do it the way that works:

```bash
helm template payments ./chart > /tmp/rendered.yaml
kubesec scan /tmp/rendered.yaml | jq -r '.[] | "\(.object)\t\(.score)"'
```

6. Add a pre-commit hook so nobody has to remember to run this:

```bash
cat > .pre-commit-config.yaml <<'EOF'
repos:
  - repo: local
    hooks:
      - id: kube-linter
        name: kube-linter
        entry: kube-linter lint --config .kube-linter.yaml
        language: system
        files: ^(manifests|chart)/.*\.(ya?ml)$
        pass_filenames: false
EOF
```

**Verification questions**

- **Q5.1** — The config uses `addAllBuiltIn: true` plus an explicit `exclude` list, rather than `include`-ing the checks the team wants. Argue why the subtractive form is the safer default for a security baseline, and name the one situation where the additive form is correct.
- **Q5.2** — In step 5, Kubesec failed on `chart/templates/deployment.yaml` while KubeLinter handled the chart directory. Explain the architectural reason for this difference, and state the general rule for where in a Helm pipeline each tool belongs.
- **Q5.3** — `helm template` renders with `values.yaml` defaults. Your production deployment uses `values-prod.yaml`, which sets `securityContext.privileged: true` for a debug sidecar. What does your gate report, and what is the fix?
- **Q5.4** — The custom check `require-owner-label` uses `scope.objectKinds: [DeploymentLike]`. What does `DeploymentLike` expand to, and what happens to a bare `Pod` or a `CronJob` under that scope?
- **Q5.5** — You enabled `latest-tag`. A developer objects: "the image is also pinned by digest in the CD overlay, so the tag is irrelevant." Is the check still worth enforcing on the source manifest? Explain in terms of what an attacker controls.
- **Q5.6** — The pre-commit hook sets `pass_filenames: false`. What would go wrong with `pass_filenames: true` given how KubeLinter resolves cross-object checks such as `dangling-service` and `non-existent-service-account`?

---

## Exercise 6 — Static analysis of the container image itself

**Goal:** the syllabus says *"workloads **and container images**"*. Manifest linting says nothing about what is inside the image. Learn to interrogate an image's configuration and history without pulling or running it.

1. Read an image's config object straight from the registry — no `docker pull`, no daemon:

```bash
skopeo inspect --config docker://docker.io/library/nginx:1.27 \
  | jq '{user: .config.User, entrypoint: .config.Entrypoint, cmd: .config.Cmd, env: .config.Env, exposed: .config.ExposedPorts}'
```

Expected (abridged):

```json
{
  "user": "",
  "entrypoint": ["/docker-entrypoint.sh"],
  "cmd": ["nginx", "-g", "daemon off;"],
  "env": ["PATH=/usr/local/sbin:...", "NGINX_VERSION=1.27.3", "NJS_VERSION=0.8.7"],
  "exposed": { "80/tcp": {} }
}
```

2. The same with `crane` (from `go-containerregistry`), which many CI images already have:

```bash
crane config docker.io/library/nginx:1.27 | jq -r '.config.User // "(empty => root)"'
```

3. Read the build history statically — this is where leaked secrets live:

```bash
crane config docker.io/library/nginx:1.27 \
  | jq -r '.history[] | .created_by' | head -20
```

4. Build a deliberately bad image locally and audit it the same way:

```bash
cat > Dockerfile <<'EOF'
FROM ubuntu:24.04
ARG NPM_TOKEN
ENV DB_PASSWORD=s3cr3t-do-not-do-this
RUN apt-get update && apt-get install -y curl sudo
COPY app /opt/app
EXPOSE 22
CMD ["/opt/app/server"]
EOF

mkdir -p app && echo '#!/bin/sh' > app/server && chmod +x app/server
docker build -t bad-app:0.1 .
```

5. Statically analyse the Dockerfile — no build, no run:

```bash
trivy config Dockerfile
```

Expected (abridged):

```
Dockerfile (dockerfile)
=======================
Tests: 27 (SUCCESSES: 24, FAILURES: 3)
Failures: 3 (UNKNOWN: 0, LOW: 0, MEDIUM: 1, HIGH: 2, CRITICAL: 0)

HIGH: Specify at least 1 USER command in Dockerfile with non-root user as argument
──────────────────────────────────────────
Running containers with 'root' user can lead to a container escape situation...
See https://avd.aquasec.com/misconfig/ds002
──────────────────────────────────────────

HIGH: Sensitive data should not be used in the ARG or ENV commands
──────────────────────────────────────────
See https://avd.aquasec.com/misconfig/ds031
──────────────────────────────────────────

MEDIUM: Add HEALTHCHECK instruction in your Dockerfile
──────────────────────────────────────────
See https://avd.aquasec.com/misconfig/ds026
──────────────────────────────────────────
```

6. Scan the built image for secrets baked into layers — still static, no execution:

```bash
trivy image --scanners secret --severity HIGH,CRITICAL bad-app:0.1
docker image inspect bad-app:0.1 --format '{{.Config.User}} | {{join .Config.Env ","}}'
```

7. Connect image analysis back to the manifest. Deploy an image whose `USER` is root under a `runAsNonRoot: true` pod:

```bash
kubectl run root-image --image=bad-app:0.1 \
  --overrides='{"spec":{"containers":[{"name":"root-image","image":"bad-app:0.1","securityContext":{"runAsNonRoot":true}}]}}'
kubectl get pod root-image
kubectl describe pod root-image | grep -A3 -i 'Warning\|Error'
```

Expected:

```
NAME         READY   STATUS                       RESTARTS   AGE
root-image   0/1     CreateContainerConfigError   0          6s
```

```
  Warning  Failed     3s (x3 over 12s)  kubelet  Error: container has runAsNonRoot and image will run as root
```

8. Clean up:

```bash
kubectl delete pod root-image --ignore-not-found
```

**Verification questions**

- **Q6.1** — `skopeo inspect --config` returned `"user": ""`. What does an empty `Config.User` mean, and why is that field the single most useful thing to extract from an image config during a supply-chain review?
- **Q6.2** — In step 7 the pod failed with `CreateContainerConfigError`, not `CrashLoopBackOff`. At which stage did the check happen, which component enforced it, and why is `runAsNonRoot: true` *alone* insufficient if you cannot also pin `runAsUser`?
- **Q6.3** — `ENV DB_PASSWORD=s3cr3t` is visible in the image config forever. Suppose the developer instead writes `RUN echo $NPM_TOKEN > /tmp/.npmrc && npm ci && rm /tmp/.npmrc`. Is the token recoverable from the published image? Explain in terms of layers, and name the build feature that solves it correctly.
- **Q6.4** — `trivy config Dockerfile` and `kube-linter lint manifests/` both report "runs as root", from completely different inputs. Which one can be wrong, and in which direction? Give a concrete manifest+image pair where the manifest looks clean and the workload still runs as UID 0.
- **Q6.5** — `EXPOSE 22` triggered nothing in `trivy config` but KubeLinter ships an `ssh-port` check for manifests. Why is `EXPOSE` in a Dockerfile a weak signal, and what does it actually do at runtime in Kubernetes?
- **Q6.6** — You have 400 images in your registry. Write (in words) the static-analysis pass that finds every image running as root, using only `crane`/`skopeo` + `jq`, and explain why this beats waiting for a `runAsNonRoot` admission rejection in production.

---

## Exercise 7 — A CI gate that actually blocks

**Goal:** combine both scanners into one deterministic gate with an honest failure contract.

1. Write the gate:

```bash
cat > ci-static-analysis.sh <<'EOF'
#!/usr/bin/env bash
# Static analysis gate for Kubernetes workloads.
# Exit 0 = clean, 1 = policy findings, 2 = tooling/usage error.
set -uo pipefail

MANIFEST_DIR=${MANIFEST_DIR:-manifests}
MIN_SCORE=${MIN_SCORE:-5}
findings=0

command -v kubesec    >/dev/null || { echo "tooling: kubesec not found";    exit 2; }
command -v kube-linter>/dev/null || { echo "tooling: kube-linter not found"; exit 2; }
command -v jq         >/dev/null || { echo "tooling: jq not found";          exit 2; }

echo "== KubeLinter =="
kube-linter lint --config .kube-linter.yaml --format json "$MANIFEST_DIR" > /tmp/kl.json 2>/tmp/kl.err
kl_rc=$?
if (( kl_rc > 1 )); then
  echo "tooling: kube-linter failed (rc=$kl_rc)"; cat /tmp/kl.err; exit 2
fi
kl_count=$(jq '(.Reports // []) | length' /tmp/kl.json)
jq -r '(.Reports // [])[] | "  [\(.Check)] \(.Object.K8sObject.Namespace)/\(.Object.K8sObject.Name): \(.Diagnostic.Message)"' /tmp/kl.json
(( kl_count > 0 )) && findings=1
echo "  -> $kl_count check violation(s)"

echo "== Kubesec =="
shopt -s nullglob
for f in "$MANIFEST_DIR"/*.y*ml; do
  out=$(kubesec scan --exit-code 0 "$f" 2>/tmp/ks.err)
  if ! jq -e 'type=="array" and length>0' <<<"$out" >/dev/null 2>&1; then
    echo "  SKIP $f (no scannable workload)"
    continue
  fi
  while IFS=$'\t' read -r obj score crit; do
    if (( crit > 0 )); then
      echo "  FAIL $obj score=$score critical=$crit  <- hard block"
      findings=1
    elif (( score < MIN_SCORE )); then
      echo "  FAIL $obj score=$score (< $MIN_SCORE)"
      findings=1
    else
      echo "  PASS $obj score=$score"
    fi
  done < <(jq -r '.[] | "\(.object)\t\(.score)\t\((.scoring.critical // []) | length)"' <<<"$out")
done

exit $findings
EOF
chmod +x ci-static-analysis.sh
```

2. Run it against the bad directory, then against a clean one:

```bash
MANIFEST_DIR=manifests ./ci-static-analysis.sh; echo "gate=$?"
mkdir -p clean && cp manifests/02-payments-api-hardened.yaml clean/
MANIFEST_DIR=clean ./ci-static-analysis.sh; echo "gate=$?"
```

3. Prove the tooling-error path is distinguishable:

```bash
PATH=/nonexistent ./ci-static-analysis.sh; echo "gate=$?"
```

```
tooling: kubesec not found
gate=2
```

4. Add a waiver mechanism — because a gate with no waiver process gets disabled:

```bash
cat >> .kube-linter.yaml <<'EOF'
EOF
# In-manifest waiver, scoped to one object and one check:
#   metadata:
#     annotations:
#       ignore-check.kube-linter.io/privileged-container: "CSI node driver requires privileged mode; approved SEC-2291, expires 2026-12-01"
```

Apply it to a genuinely privileged workload and confirm the finding disappears:

```bash
kubectl create deploy csi-node --image=registry.example.com/csi:1.2 --dry-run=client -o yaml > manifests/03-csi.yaml
# hand-edit: add privileged: true, then the ignore-check annotation on the pod template metadata
kube-linter lint --config .kube-linter.yaml manifests/03-csi.yaml
```

**Verification questions**

- **Q7.1** — The gate treats "any Kubesec `critical` finding" as a hard block regardless of the total score. Why is that rule strictly better than a score threshold alone? Give the specific manifest that defeats a pure-threshold gate.
- **Q7.2** — Exit codes 0/1/2 are given distinct meanings. Why must "tooling error" be distinguishable from "policy violation" in a CI system, and what is the dangerous failure mode if both return 1?
- **Q7.3** — The waiver is an annotation inside the manifest itself, which means the person who introduces the risk also grants the exception. Describe two controls that make this acceptable, and one that does not (self-approval).
- **Q7.4** — `ignore-check.kube-linter.io/<check>` is applied where, exactly, for a Deployment — on `metadata.annotations` or on `spec.template.metadata.annotations`? Explain why the answer depends on the check's scope.
- **Q7.5** — Kubesec has **no** waiver mechanism at all. Given that, how do you run Kubesec in a repo that legitimately contains a privileged CSI DaemonSet, without either disabling the tool or accepting a permanently red build?
- **Q7.6** — The gate runs on `manifests/`, but your GitOps repo is the deployment source of truth and Argo CD applies Kustomize overlays. Where must the gate actually run to be meaningful, and what is the name of the failure it prevents?

---

## Exercise 8 — Auditing a live cluster with the same tools

**Goal:** apply static analysis to what the cluster is *actually running*, and measure the gap against the source manifests.

1. Deploy the hostile pod into a throwaway namespace (use a disposable cluster — kind/minikube):

```bash
kubectl create ns audit-lab
sed 's/namespace: default/namespace: audit-lab/' manifests/01-payments-api.yaml \
  | kubectl apply -f - 2>&1 | tail -2
```

If Pod Security Admission blocks it, note the message and then temporarily label the namespace:

```bash
kubectl label ns audit-lab pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl apply -n audit-lab -f manifests/01-payments-api.yaml
```

2. Export every workload in the cluster to disk, one file per object:

```bash
mkdir -p live
for kind in deployment daemonset statefulset cronjob job pod; do
  kubectl get "$kind" -A -o json 2>/dev/null \
    | jq -c '.items[]?' \
    | while read -r obj; do
        ns=$(jq -r '.metadata.namespace' <<<"$obj")
        name=$(jq -r '.metadata.name' <<<"$obj")
        jq 'del(.status, .metadata.managedFields, .metadata.uid, .metadata.resourceVersion, .metadata.generation, .metadata.creationTimestamp)' \
          <<<"$obj" > "live/${kind}_${ns}_${name}.json"
      done
done
ls live | wc -l
```

3. Lint the whole export at once:

```bash
kube-linter lint --config .kube-linter.yaml live/ --format json \
  | jq -r '.Reports[] | .Check' | sort | uniq -c | sort -rn | head -15
```

Expected shape:

```
     42 no-read-only-root-fs
     38 run-as-non-root
     31 unset-memory-requirements
     12 drop-net-raw-capability
      3 privileged-container
      1 host-network
```

4. Score every workload with Kubesec and rank the worst offenders:

```bash
for f in live/*.json; do
  kubesec scan "$f" --exit-code 0 2>/dev/null \
    | jq -r --arg f "$f" '.[]? | "\(.score)\t\(.object)\t\($f)"'
done | sort -n | head -10
```

5. **The critical experiment.** Scan the *source* manifest and the *live* object for the same pod and diff the scores:

```bash
kubesec scan manifests/01-payments-api.yaml | jq -r '.[].score'
kubesec scan live/pod_audit-lab_payments-api.json | jq -r '.[].score'
```

Then diff the rules that passed in each:

```bash
diff <(kubesec scan manifests/01-payments-api.yaml \
        | jq -r '.[].scoring | (.passed//[])[].id' | sort) \
     <(kubesec scan live/pod_audit-lab_payments-api.json \
        | jq -r '.[].scoring | (.passed//[])[].id' | sort)
```

6. Clean up:

```bash
kubectl delete ns audit-lab
```

**Verification questions**

- **Q8.1** — The live object scored *higher* than the source manifest even though nothing was hardened. Identify at least two fields the API server defaulted in, and explain which Kubesec rules they satisfied for free.
- **Q8.2** — Given Q8.1, is a live-object scan more or less trustworthy than a source-manifest scan? State clearly what each one measures and when you would run each.
- **Q8.3** — The export pipeline deletes `.status` and `.metadata.managedFields`. What breaks if you leave `managedFields` in, and what security-relevant information does `.status` contain that a *different* kind of audit would want?
- **Q8.4** — Your export includes `Pod` objects owned by Deployments, so every workload is counted twice. What does that do to the `uniq -c` ranking in step 3, and how do you filter owned pods out with one `jq` predicate?
- **Q8.5** — A mutating admission webhook (a service mesh injector) adds a sidecar with `NET_ADMIN` at admission time. Which of your two scan targets — source manifest or live export — sees it? What does that prove about the coverage limits of pre-commit static analysis?
- **Q8.6** — In step 1, PSA may have rejected the pod outright. If Pod Security Admission already blocks privileged pods at the API server, what is the residual value of running Kubesec and KubeLinter in CI at all? Give two concrete answers.

---

## Exercise 9 — Exam-speed drill (timed: 12 minutes total)

Do these without notes. Each is shaped like a CKS task.

1. **(3 min)** A file `/opt/task/deploy.yaml` scores negatively. Using `kubesec`, produce a list of *only* the critical rule IDs, one per line, into `/opt/task/critical.txt`. No JSON, no extra text.

2. **(3 min)** Using `kube-linter`, run **only** the checks `privileged-container`, `run-as-non-root` and `no-read-only-root-fs` against `/opt/task/manifests/`, with no default checks enabled. Write the command.

3. **(2 min)** Modify `/opt/task/deploy.yaml` so that `kubesec scan` reports a score of **at least 10** and reports zero critical findings. State the minimum set of fields you must add.

4. **(2 min)** Determine, without pulling the image or starting a container, whether `registry.example.com/app:2.1` runs as root.

5. **(2 min)** A pod is stuck in `CreateContainerConfigError` with the event `container has runAsNonRoot and image will run as root`. Give the two possible fixes and say which one you would choose in a hardened cluster, and why.

**Verification questions**

- **Q9.1** — For task 2, what happens if you pass `--include` without disabling defaults? Which flag or config key prevents the default set from being added?
- **Q9.2** — For task 3, could you reach a score of 10 by adding only `resources` and `serviceAccountName`? Show the arithmetic.
- **Q9.3** — For task 5, one of the two fixes weakens the cluster's security posture. Which one, and what is the exact control you would be surrendering?

---

## Reference: what these tools do *not* see

Commit this list to memory — it is the difference between a report and an assessment.

| Blind spot | Why static analysis misses it | Complementary control |
|---|---|---|
| API-server defaulting | Source YAML ≠ admitted object | Scan live export (Ex. 8) or use an admission webhook |
| Mutating webhooks / sidecar injection | Happens after CI | Admission-time policy (Kyverno, Gatekeeper) |
| RBAC granted to the ServiceAccount | Different object, often a different repo | `kubectl auth can-i --list --as=system:serviceaccount:ns:sa` |
| NetworkPolicy absence | Not a workload field | `kube-linter` has no default check; use Kyverno or a namespace-scoped audit |
| CVEs inside the image | Requires a vulnerability DB, not a rule engine | `trivy image`, Clair, Grype (CKS 4.3) |
| Runtime syscall abuse | Not expressible statically | Falco, seccomp `RuntimeDefault`, AppArmor |
| Secrets in Git | Not a Kubernetes field | `gitleaks`, `trivy fs --scanners secret` |
| Semantics of a `hostPath` | `/var/log` and `/` are both "a hostPath" | Kubesec special-cases `docker.sock` only — human review still required |

---

## Sources

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubesec — https://kubesec.io/ and https://github.com/controlplaneio/kubesec
- KubeLinter documentation — https://docs.kubelinter.io/
- KubeLinter checks reference — https://docs.kubelinter.io/#/generated/checks
- KubeLinter templates reference — https://docs.kubelinter.io/#/generated/templates
- KubeLinter source — https://github.com/stackrox/kube-linter
- Kubernetes — Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes — Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Trivy — Misconfiguration scanning — https://trivy.dev/latest/docs/scanner/misconfiguration/
- Aqua Vulnerability Database (Dockerfile checks DS002/DS026/DS031) — https://avd.aquasec.com/misconfig/
- OCI Image Specification — image configuration — https://github.com/opencontainers/image-spec/blob/main/config.md
- skopeo — https://github.com/containers/skopeo
- go-containerregistry / crane — https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every block</summary>

### Exercise 0

**A0.1** — No kubeconfig means the tools operate on *files*, so they belong as far left in the pipeline as possible: pre-commit hook, pull-request check, CI build stage — before anything is applied. The corollary is that they can never detect anything that only exists in the cluster: API-server defaulting, mutating admission webhooks (sidecar injection), the RBAC actually bound to the referenced ServiceAccount, NetworkPolicies in the namespace, node-level configuration, or drift introduced by `kubectl edit`. They analyse *intent as written*, not *state as running*.

**A0.2** — `scan /dev/stdin` works because the container's stdin is connected (`-i`) and kubesec accepts any readable path; `/dev/stdin` is a file handle to the piped YAML. The second form fails because `manifests/01-payments-api.yaml` is a path on the *host*, and the container filesystem has no such file — you would need `-v "$PWD":/work:ro` and then `scan /work/manifests/01-payments-api.yaml`. This is the classic containerised-CLI mistake and it costs exam minutes.

**A0.3** — `kube-linter checks list` (add `--format json | jq -r '.[].name'` to get bare names). The check is `privileged-container`. Both tools' `--help` and `checks list` / `templates list` subcommands are self-documenting; you never need external docs for the check catalogue.

---

### Exercise 1

**A1.1** — −30 −30 −9 −9 −9 −1 = **−88**, matching `score`. The score is a plain sum of matched rule weights: additive, unbounded, with no notion of exploitability, reachability, or blast radius. Reporting "−88" to a stakeholder is meaningless — it has no upper or lower bound and is not comparable across manifests of different shapes. Report the *rule IDs* and their reasons instead. The number is useful only as a monotonic regression signal ("this PR made it worse").

**A1.2** — Kubesec's rules are independent boolean selectors over the YAML; there is no dependency graph, so `privileged: true` and `capabilities.add: [SYS_ADMIN]` each match their own selector and each charge their own weight. Technically the second is redundant — `privileged` already grants the full capability set, disables seccomp/AppArmor confinement and gives unmasked `/proc` and all devices. The lesson: rule-based scoring **double-counts overlapping controls**, so scores are not additive measures of risk. Two manifests with the same score can have wildly different real exposure.

**A1.3** — Almost nothing. `allowPrivilegeEscalation` controls the `no_new_privs` bit, which governs whether a process can gain privileges via setuid binaries or file capabilities. A `privileged: true` container already starts with every capability, so there is nothing to escalate *to*; in fact the kubelet rejects `privileged: true` combined with `allowPrivilegeEscalation: false` as an invalid combination in many versions. Setting it purely to harvest +7 would move the score from −88 to −81 while changing the security posture by zero. The lesson: **a score is a proxy, and every proxy can be gamed**. Gate on the presence of critical findings, not on the total (see A7.1).

**A1.4** — Kubesec's AppArmor rule is a selector over a pod annotation whose *key* embeds the container name: `container.apparmor.security.beta.kubernetes.io/<container-name>`. The example selector text printed in the output hard-codes `nginx` because that is how the rule was authored/documented; the engine matches the annotation prefix for the actual container. Our pod has no `container.apparmor...` annotation of any kind, so the rule stays in `advise` and awards nothing. Additionally, that annotation form is deprecated in Kubernetes ≥1.30 (see A2.4).

**A1.5** — With `set -e`, *any* non-zero exit aborts the script, so a loop over manifests stops at the first failing file — you get a partial audit that looks complete. Distinguishing codes matters because "the scan ran and found problems" (a policy result you may want to collect for all files) is categorically different from "the scanner could not parse the file / crashed / is not installed" (a tooling failure that must abort loudly). Kubesec deliberately uses 2 for policy failure, leaving 1 free for usage/parse errors — so `--exit-code 0` lets you collect results and decide the gate outcome yourself from the JSON.

**A1.6** — Kubesec only understands workload kinds (Pod, Deployment, StatefulSet, DaemonSet, and similar pod-template carriers). Given a `Service` it does not return a zero score — it errors out with a non-zero exit and no usable JSON. Operationally, in a mixed directory a naive loop either aborts (with `set -e`) or records a bogus result. Every real gate must therefore filter by kind first, or tolerate the error explicitly and mark the file as skipped — and *log* the skip, because a silent skip is how a workload stops being scanned without anyone noticing.

---

### Exercise 2

**A2.1** — `RunAsUser10000` requires `runAsUser > 10000`, so UID 999 fails the selector. The rationale is **host UID collision**: container UIDs are the same numeric UIDs as on the host unless user namespaces are in play. Low UIDs (< 1000, and commonly < 10000) collide with real system accounts on the node — so a container process running as UID 999 owns files created on a `hostPath` mount as the host's UID 999, and gains access to any host-shared resource owned by that account. Choosing a high, unlikely-to-collide UID limits what a container escape or a shared-volume write can touch.

**A2.2** — `drop: ["NET_RAW", "SYS_MODULE", "SYS_PTRACE"]` satisfies `CapDropAny` (a non-empty drop list) but not `CapDropAll` (which requires `ALL` in the list). The weaker form is legitimate when the container genuinely needs a capability the runtime's default set provides — for example a network agent that needs `NET_BIND_SERVICE` for a port below 1024. Best practice is still `drop: ["ALL"]` followed by an explicit `add:` of the single required capability, which is both auditable and minimal; a hand-curated drop list silently inherits every future default capability the runtime adds.

**A2.3** — `readOnlyRootFilesystem: true` remounts `/` read-only inside the container. Almost every real process writes *somewhere*: `/tmp`, a cache directory, a PID file, a log spool, a language runtime's scratch space. Without writable `emptyDir` mounts at exactly those paths, the process fails at startup or first write with `EROFS` — typically `open /tmp/xxx: read-only file system`, visible as a `CrashLoopBackOff` with the error in `kubectl logs`. The control is only adoptable if you pair it with an explicit, enumerated set of writable mounts — which is itself valuable, because it forces you to know what your workload writes.

**A2.4** — Kubernetes 1.34 honours **`securityContext.appArmorProfile`** (the field, GA since 1.30); the annotation `container.apparmor.security.beta.kubernetes.io/<c>` is deprecated and slated for removal. Kubesec's `ApparmorAny` rule keys on the **annotation**. The correct response is *not* to add a deprecated annotation to farm points: fix the manifest to the supported field, and fix the *scanner* — upgrade it, open an issue, or add a custom rule/waiver. Writing deprecated API surface into manifests to satisfy a linter is how you accumulate a migration debt that breaks on the next cluster upgrade. This is the canonical example of **scanner lag**, and it is why you never treat a scanner's ruleset as the policy — the policy is the standard; the scanner is one imperfect implementation of it.

**A2.5** — No, not necessarily. The 22-point workload earned +3 for a deprecated AppArmor annotation (which may not even be enforced on a 1.34 cluster) and +2 for PVC properties that are storage-availability concerns, not security controls. Meanwhile it might be missing `automountServiceAccountToken: false` or be pinned to `:latest`. The score is **a sum of matched rules, not a risk measurement**: it has no denominator, no weighting by exploitability, and no awareness of the controls it has no rule for. Comparisons across different workloads are meaningless; only the delta on the *same* workload over time carries signal.

**A2.6** — It removes the automatic projection of a ServiceAccount token into `/var/run/secrets/kubernetes.io/serviceaccount/token`. That token is the single most valuable thing an attacker finds after compromising a container: it is a valid credential to the API server, and combined with over-broad RBAC it converts one compromised pod into cluster-wide access. Kubesec awards zero points because it has no rule for it. The principle: **the scanner's ruleset is not the policy**. A programme that only fixes what the scanner flags will systematically miss every control the tool has no rule for, and the ruleset is chosen by tool maintainers, not by your threat model.

**A2.7** — A digest pin defeats **tag mutation**: an attacker (or a careless CI job) who can push to the registry can repoint `:v1.2.3` or `:latest` at a different image, and every subsequent pull — including a node restart or a rescheduling event — silently runs the substituted image. A digest is content-addressed and cannot be repointed. Of the two tools, **KubeLinter** flags this, via the non-default `latest-tag` check (which you enabled in Exercise 5); Kubesec has no rule for image references at all.

---

### Exercise 3

**A3.1** — Without `--exit-code 0`, kubesec returns 2 on the first failing manifest. Under `set -e` the script aborts there, so you see results for one file and an exit status suggesting a crash. `|| true` on the `kubesec` call is not sufficient by itself because `set -o pipefail` is also active: in a pipeline like `kubesec scan "$f" | jq ...`, a non-zero status from *kubesec* propagates as the pipeline's status even though `jq` succeeded, and `|| true` appended after the whole pipeline masks genuine `jq` failures too. The clean solution is what the script does: capture kubesec's output with `--exit-code 0` (so 0 means "ran successfully"), then evaluate the policy decision from the JSON.

**A3.2** — You disclosed the full manifest: image registry hostnames and repository names, container and pod names, namespace, ServiceAccount name, environment variable *names* (and any values inlined in the manifest — which frequently includes credentials in real repos), volume paths, node selectors, and by inference your internal service topology. It is acceptable for public example manifests, training material, and open-source charts. It is not acceptable for anything describing production. The drop-in remediation is exactly step 3: run `kubesec http 8080` locally (or as a Deployment inside your own cluster) and point the same `curl` at it — identical API, identical output, no egress.

**A3.3** — First, **score-based validation is not deterministic policy**: the pass/fail boundary is an arbitrary integer, and adding unrelated positive rules (resources, serviceAccountName) can lift a genuinely dangerous object over the line. Second, **the ruleset is not versioned with your policy**: a kubesec upgrade can silently change point values and flip admission decisions for objects that did not change, which is an availability incident. Additionally it offers no namespace/label scoping, no dry-run/audit mode, no per-object exceptions, and no way to express "warn in staging, enforce in prod". PSA (built in, standards-based, three modes: `enforce`/`audit`/`warn`, namespace-scoped) and Kyverno/Gatekeeper (declarative, testable, versioned policies with exclusions) are all designed for that job.

**A3.4** — Yes, they can. +1 CPU request, +1 memory request, +1 CPU limit, +1 memory limit, +1 serviceAccountName, +7 allowPrivilegeEscalation… a privileged pod can accumulate positives while still scoring below zero overall, but on a *less* catastrophic manifest (say, only `hostPID: true` at −9) padding easily crosses a +10 threshold. The redesign: **fail if `scoring.critical` is non-empty, regardless of score** — i.e. `(( crit > 0 )) && fail`, with the numeric threshold applied only as an additional, secondary condition. That is exactly what the Exercise 7 gate does.

**A3.5** — kubesec emits a non-array JSON error object (or nothing at all) for unsupported kinds and parse errors. `jq -r '.[] | ...'` over a non-array either errors to stderr (discarded) or produces no lines; the `while read` loop then iterates zero times, `rc` stays 0, and the file is silently reported as clean. The `jq -e 'type=="array" and length>0'` guard converts that into an explicit `SKIP` line. **A skipped file must be logged**, because "no findings" and "not scanned" are indistinguishable in a summary and the second one is how coverage silently rots.

---

### Exercise 4

**A4.1** — The two tools implement different, only partially overlapping rulesets, derived from different threat models: Kubesec is a hand-curated pod-security scorer; KubeLinter is a general Kubernetes-object check engine that also covers reliability and cross-object consistency. Neither is a superset of the other, and neither is complete. The correct policy is to run **both** (plus a policy-as-code engine such as `trivy config`/Checkov/Kyverno CLI for the checks neither covers), union the findings, and treat the *union* as the baseline — while remembering that the union is still not the policy. Relying on a single scanner means adopting one vendor's opinion of what matters as your security programme.

**A4.2** — *For:* a workload without resource limits is a denial-of-service vector — one pod can starve every neighbour on the node, and a missing memory limit turns a memory leak (or a memory-amplification attack) into node-wide eviction. Missing probes mean a compromised or wedged container keeps receiving traffic. Availability is part of the CIA triad, so these are security checks under a broad reading. *Against:* mixing them into a security gate produces high-volume, low-severity noise that trains developers to ignore the gate and pressures teams into blanket waivers — which then also waive the real findings. The practical resolution is two gates with different blocking semantics: security findings block the merge; reliability findings warn or block only on a separate reliability check.

**A4.3** — `CAP_NET_RAW` permits opening raw and packet sockets: crafting arbitrary packets, ARP spoofing, DNS spoofing, sniffing traffic on the pod's interface, and ICMP-based tunnelling for exfiltration. It is in the container runtime's *default* capability set, so every container has it unless explicitly dropped — which is exactly why it deserves a dedicated check: the dangerous state is the default. With `hostNetwork: true` the pod shares the *node's* network namespace, so dropping `NET_RAW` limits packet crafting but the container still sees and can bind to every host interface, reach services bound to the host's loopback (kubelet's read-only port, node-local metadata endpoints, `127.0.0.1`-only admin interfaces), and bypass NetworkPolicy entirely — because NetworkPolicy selects pods by their own network identity, which a host-network pod does not have.

**A4.4** — `no-liveness-probe` and `no-readiness-probe` — the hardened manifest defines neither. (Depending on your version you may also see `unset-cpu-requirements`-family checks satisfied, since the manifest sets all four resource fields.) A security-hardened pod fails a default run because KubeLinter's default set is a *general best-practice* set, not a security set. This is the concrete motivation for Exercise 5: you must curate the check set to match the gate's purpose, or the gate's signal-to-noise ratio makes it unusable.

**A4.5** — 
```bash
kube-linter lint --config .kube-linter.yaml manifests/; rc=$?; (( rc > 1 )) && { echo "TOOLING ERROR"; exit 2; }; (( rc == 1 )) && findings=1
```
The distinguishing principle: KubeLinter uses **1** for "lint errors found" and reserves higher codes for usage/internal errors; a missing binary yields **127** from the shell, and a signal-killed process yields 128+N. So `rc == 1` is a policy result and `rc > 1` is a tooling failure. Never collapse them.

**A4.6** — With no `metadata.namespace`, KubeLinter prints `<no namespace>/payments-api`. This matters for diffing because the same chart rendered for `staging` and `prod` produces different object identifiers, so a naive text diff of two reports shows every line as changed. Normalise on the check name plus object name (or lint the un-namespaced source and let the overlay set the namespace) before diffing — and prefer the JSON/SARIF output, where the fields are separable, over the plain-text form.

---

### Exercise 5

**A5.1** — `addAllBuiltIn: true` + `exclude` is **fail-closed**: when the tool adds a new check in the next release, you get it automatically and must consciously decide to drop it. The additive `include` form is **fail-open**: new checks never fire, so your coverage silently freezes at the day you wrote the config, and nobody notices for two years. Subtractive is the right default for a security baseline. The additive form is correct when the gate has a narrowly defined purpose — for example a dedicated "supply chain" job that runs only `latest-tag`, `env-var-secret` and `privileged-container` and is deliberately separate from the broad baseline job.

**A5.2** — KubeLinter detects a chart directory (via `Chart.yaml`) and **renders the templates itself** with the chart's default values before linting, so it consumes Helm charts natively. Kubesec is a plain YAML parser with no templating engine: `{{ .Release.Name }}` is not valid YAML, so parsing fails. The general rule: **KubeLinter can sit before rendering; Kubesec must sit after it.** In a Helm pipeline, run `helm template` once and feed the rendered output to Kubesec (and, ideally, to KubeLinter too, so both tools see identical input).

**A5.3** — Your gate reports **clean**, because it linted the chart with `values.yaml` defaults, and the privileged sidecar only appears when `values-prod.yaml` is applied. This is a coverage hole disguised as a passing build. The fix is to render and scan **every values combination you actually deploy**: loop over `values-*.yaml`, run `helm template -f values-<env>.yaml`, and gate on each rendered output separately. The same reasoning applies to Kustomize: scan the rendered overlays, not the base.

**A5.4** — `DeploymentLike` is KubeLinter's built-in object-kind group covering objects that carry a pod template: Deployment, DaemonSet, StatefulSet, ReplicaSet, ReplicationController, Job, CronJob, and bare Pods. So both a bare `Pod` and a `CronJob` **are** in scope and will be checked. (If you want to restrict a check to a narrower set, list the explicit kinds instead of the group; `objectKinds: ["Any"]` widens to every object, including Services and ConfigMaps.)

**A5.5** — Yes, still worth enforcing. What the digest pin in the CD overlay protects is the *deployed* artefact; what `latest-tag` on the source manifest protects is everything that consumes the manifest *without* the overlay — local `kubectl apply`, a developer's kind cluster, a disaster-recovery restore, a copy-pasted snippet in an incident. More importantly, an attacker's goal is to find the one path that skips the hardened one. Defence in depth means the insecure pattern should not exist in the repo at all, so that no path can pick it up. It is also a strong lint signal for reviewers: a `:latest` in a diff is a reliable marker that the change bypassed the standard pipeline.

**A5.6** — Cross-object checks need the **whole object set in one lint invocation**. `dangling-service` asks "does any workload match this Service's selector?" and `non-existent-service-account` asks "does the referenced ServiceAccount exist in this set?" With `pass_filenames: true`, pre-commit passes only the *changed* files, so a lint run might see the Service but not its Deployment (or vice versa) and emit false positives — or, worse, see only the Deployment and miss a genuinely dangling Service. `pass_filenames: false` plus a `files:` regex means "run the whole directory whenever anything in it changes", which is both correct and, for a linter this fast, cheap.

---

### Exercise 6

**A6.1** — An empty `Config.User` means the image declares no `USER` instruction, so the container runs as **UID 0 (root)** inside its namespace unless the pod's `securityContext` overrides it. It is the highest-value single field because it tells you the *default* posture of every workload built from that image across every cluster and every team — and because it is the field most often wrong: base images from upstream (nginx, postgres, most language runtimes) frequently default to root, and every downstream Dockerfile that forgets `USER` inherits it. A registry-wide sweep of this one field finds systemic risk in minutes.

**A6.2** — The failure happened at **container creation**, before the image's entrypoint ever executed — the **kubelet** compared the effective UID from the image config against the pod's `runAsNonRoot: true` and refused to create the container. Hence `CreateContainerConfigError` rather than a crash loop. `runAsNonRoot: true` alone is insufficient because it is only a *predicate*, not an assignment: it accepts any non-zero UID the image happens to declare. If the image sets `USER 1` (or a UID that collides with a host system account, or a UID that owns files on a shared `hostPath`), the check passes while the security property you wanted does not hold. Pin `runAsUser` explicitly to a known, high, non-colliding UID and keep `runAsNonRoot: true` as the belt-and-braces assertion.

**A6.3** — **Yes, the token is still recoverable.** Each Dockerfile instruction creates a layer; deleting a file in a later layer only adds a whiteout entry — the earlier layer still contains the bytes and is distributed with the image. Anyone who pulls it can extract the layer tarball and read `/tmp/.npmrc`. (The `RUN echo … && npm ci && rm …` single-instruction form does avoid *this* particular case, since all three commands run in one layer — but the same secret typically also lands in `~/.npm/_logs`, in the build cache, and in the `history[].created_by` string, which is plaintext in the image config.) The correct solution is **BuildKit secret mounts**: `RUN --mount=type=secret,id=npmtoken …`, which exposes the secret at `/run/secrets/npmtoken` for the duration of that instruction only and never writes it to any layer or to the history. Multi-stage builds that discard the build stage are a partial mitigation but do not help if the secret lands in the final stage.

**A6.4** — **The manifest check can be wrong, in the unsafe direction.** KubeLinter's `run-as-non-root` inspects only the YAML: a manifest that sets no `runAsUser`/`runAsNonRoot` is flagged, and one that sets them is not — but a manifest can be *silent* on user and still be deployed from an image whose `USER` is root, and any check that reasons only about declared fields cannot see that. Concretely: a Deployment with `securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true}` — no `runAsUser`, no `runAsNonRoot` — looks well-hardened to a casual reader, passes several checks, and runs as **UID 0** if the image is `FROM ubuntu` with no `USER`. Only image-side analysis (`crane config … .config.User`) or an admission control that enforces `runAsNonRoot` closes that gap. `trivy config Dockerfile` cannot be wrong about the image's declared user, but it says nothing about how the pod overrides it.

**A6.5** — `EXPOSE` is **pure metadata**. It does not open a port, does not create a listener, and in Kubernetes it is ignored entirely — the kubelet never reads it, and reachability is determined by what the process actually binds plus the pod's network namespace and any NetworkPolicy. So an image with `EXPOSE 22` may run no SSH daemon at all, and an image with no `EXPOSE` may run one. It is a weak signal in both directions — a documentation hint. KubeLinter's `ssh-port` check on manifests is somewhat stronger because `containerPort: 22` at least reflects a deliberate declaration by the workload author, but it is *also* only metadata; the authoritative answer requires runtime inspection or a NetworkPolicy that denies the port outright.

**A6.6** — List every repository and tag (`crane ls <repo>` / registry catalogue API), then for each reference run `crane config <ref> | jq -r '.config.User'` and report every image where the value is empty, `"0"`, or `"root"`. It parallelises trivially, needs only registry read credentials, and never pulls a layer — `crane config` fetches the manifest and the small config blob only. It beats waiting for an admission rejection because: it is **proactive** (you find the 40 root images before anyone tries to deploy them into a restricted namespace, instead of discovering them one production incident at a time); it is **complete** (admission only tells you about images someone tried to run today, in namespaces that happen to enforce the policy); and it gives you a **remediation work-list** owned by the image maintainers rather than a stream of deployment failures owned by whoever was on call.

---

### Exercise 7

**A7.1** — A critical finding is a categorical statement — "this workload can escape to the host" — while the score is an unbounded sum in which unrelated positives offset it. Gating on criticals is therefore both stricter and more explainable. The defeating manifest for a pure-threshold gate: take a pod with `hostPID: true` (−9) and add `allowPrivilegeEscalation: false` (+7), all four resource fields (+4), `serviceAccountName` (+1), `readOnlyRootFilesystem` (+1), `runAsNonRoot` (+1), `runAsUser: 20001` (+1), `capabilities.drop: [ALL]` (+2), `seccompProfile` (+1) — total **+9**, comfortably over a `MIN_SCORE=5` threshold, while the pod can still read every process's environment and `/proc` on the node.

**A7.2** — If both return 1, a broken scanner is indistinguishable from a clean-but-noisy repo — and the far more dangerous inversion is that a *silently absent* or *crashing* scanner produces the same status as a passing scan if the script swallows errors. The gate then reports green while performing no analysis at all, sometimes for months. Distinct codes let the pipeline route the two outcomes differently: policy findings go to the PR as review comments and block the merge; tooling errors page the platform team and fail the build with a different message. "The gate was green because it never ran" is the canonical CI security failure.

**A7.3** — Acceptable controls: (1) **the waiver lives in the diff**, so it goes through the same code review as the risk it excuses — a second engineer must approve, and the annotation is greppable across the repo for audit; (2) **CODEOWNERS on the annotation pattern**, so a security-team review is mandatory for any file adding an `ignore-check.kube-linter.io/*` annotation, plus a required justification and an expiry date enforced by a periodic job that reports stale waivers. Not acceptable: **self-approval** — the author adding both the privileged container and its waiver in the same self-merged PR, with no second party and no expiry. That is not a waiver process; it is an opt-out.

**A7.4** — It depends on the **scope of the check**. Checks that evaluate the *pod spec* (`privileged-container`, `run-as-non-root`, `no-read-only-root-fs`) evaluate the pod template, so the annotation belongs on `spec.template.metadata.annotations`. Checks that evaluate the *top-level object* (`required-label` on the Deployment, `minimum-three-replicas`, `mismatching-selector`) need it on the Deployment's own `metadata.annotations`. When unsure, put it where the object identified in the finding's `(object: ns/name Kind=...)` line lives — that is the object the check matched.

**A7.5** — Kubesec is all-or-nothing per file, so you partition. Options, best first: (1) **segregate by directory** — keep the small set of legitimately privileged infrastructure workloads in `manifests/privileged/` with its own gate that asserts an *exact expected set* of critical findings (so a *new* critical finding on the CSI DaemonSet still fails), while `manifests/` runs the strict gate; (2) **maintain an expected-findings baseline file** and diff the current critical IDs against it, failing only on additions — the same technique used for suppressing known findings in any scanner without a waiver syntax; (3) least good, **exclude the file by path** in the gate script, which is a blunt instrument that also blinds you to future regressions in that file. In all cases record *why*, with an owner and an expiry, next to the exclusion.

**A7.6** — It must run on the **rendered output that Argo CD actually applies** — i.e. `kustomize build overlays/prod` (or `helm template` with the production values), in a pre-merge check on the GitOps repo, and ideally again as a pre-sync hook or an admission policy in the cluster. Linting only the base manifests is meaningless when an overlay can patch `securityContext.privileged: true` into any container. The failure it prevents is the **overlay/patch bypass** — hardening the base while the environment-specific patch quietly undoes it, which is the single most common way a passing static-analysis gate coexists with a privileged production workload.

---

### Exercise 8

**A8.1** — The API server defaults a large number of fields on admission. The two that matter most for Kubesec's ruleset: **`spec.serviceAccountName: default`** is populated even when the manifest omits it, satisfying the `ServiceAccountName` rule for +1; and depending on cluster configuration, **`spec.securityContext.seccompProfile.type: RuntimeDefault`** may be set by the kubelet's `SeccompDefault` feature or by a mutating policy, satisfying `SeccompAny` for +1. (Other defaults — `terminationGracePeriodSeconds`, `dnsPolicy`, `restartPolicy`, `imagePullPolicy`, `schedulerName` — do not map to rules but do change the object.) So the live object scores higher for reasons that reflect the API server's defaults, not the author's intent.

**A8.2** — They measure different things and neither dominates. The **source scan** measures *author intent and repository hygiene* — it is the right input for a merge gate, because it is what a reviewer can act on and what future copies of the manifest will inherit. The **live scan** measures *effective posture* — it is the right input for a cluster audit and a compliance report, because it includes defaulting, mutating webhooks and any manual drift. A `serviceAccountName: default` earned by API defaulting is *worse* security than an explicitly named least-privilege ServiceAccount, yet scores identically — so a live scan can flatter a cluster. Run both: source in CI, live on a schedule, and treat a divergence between them as its own finding.

**A8.3** — `metadata.managedFields` is server-side-apply bookkeeping: tens of kilobytes of nested field-ownership metadata per object. Leaving it in bloats the export enormously, slows both scanners, and — because it embeds field paths as map keys — can confuse selectors and make diffs unreadable. `.status` is dropped because it is not part of the desired state, but it is exactly what a *different* audit wants: `status.podIP`, `status.hostIP` and `status.nodeName` for blast-radius mapping, `status.containerStatuses[].imageID` for the **actually running image digest** (which is the ground truth for vulnerability correlation — the `spec` tag may have been repointed since the pod started), and `status.qosClass`. Static analysis of desired state and forensic analysis of observed state are separate passes with separate inputs.

**A8.4** — Every pod created by a Deployment is exported both as part of the Deployment's pod template *and* as a standalone Pod object, so each finding is counted at least twice (three times through the ReplicaSet if you export those too). The `uniq -c` ranking is inflated by a roughly constant factor, which is harmless for *ordering* but badly misleading for any absolute count you put in a report. Filter with an ownership predicate: `jq -c '.items[]? | select(.metadata.ownerReferences == null)'` — keep only pods with no controller owner (genuinely standalone pods, which are themselves worth flagging) and let the controller objects account for the rest.

**A8.5** — Only the **live export** sees the injected sidecar. The source manifest in Git has no such container; the mesh's mutating webhook adds it at admission time, after every CI gate has already passed. This proves the hard coverage limit of pre-commit static analysis: **it analyses the object you wrote, not the object that runs.** Anything injected by a mutating webhook — service-mesh proxies, logging sidecars, secret-injector init containers, node-agent volumes — is invisible to it, and those injected containers are frequently the most privileged thing in the pod (`NET_ADMIN` for iptables setup, `hostPath` mounts, root UID). Closing the gap requires either scanning live objects on a schedule or enforcing at admission, after mutation.

**A8.6** — Two concrete answers. (1) **Coverage of what PSA does not check.** PSA implements only the Pod Security Standards: privilege, capabilities, host namespaces, volume types, seccomp/AppArmor. It says nothing about `:latest` tags, missing resource limits, `automountServiceAccountToken`, missing probes, dangling Services, hard-coded secrets in env vars, or your organisation's `owner` label — all of which KubeLinter and Kubesec do cover. (2) **Shift-left feedback economics and non-uniform enforcement.** A rejection at `kubectl apply`/Argo-sync time is discovered late, by whoever is deploying, often out of hours, and after a green build — while a CI finding is discovered by the author, in the PR, with a remediation string attached. And PSA is enforced *per namespace*: any namespace without an `enforce` label, and every cluster in the fleet that has not been labelled yet, has no protection at all — CI covers them uniformly. Additionally, PSA has no concept of a `warn`-only *organisational* standard beyond the three built-in levels, and cannot express custom checks at all.

---

### Exercise 9

**Task 1:**
```bash
kubesec scan --exit-code 0 /opt/task/deploy.yaml \
  | jq -r '.[].scoring.critical[]?.id' > /opt/task/critical.txt
```
(The `?` on `critical[]` prevents an error if the array is absent.)

**Task 2:**
```bash
kube-linter lint --do-not-auto-add-defaults \
  --include privileged-container \
  --include run-as-non-root \
  --include no-read-only-root-fs \
  /opt/task/manifests/
```
Equivalent config-file form (more reliable across versions — verify flag names with `kube-linter lint --help`):
```yaml
checks:
  doNotAutoAddDefaults: true
  include: ["privileged-container", "run-as-non-root", "no-read-only-root-fs"]
```

**Task 3:** Remove every critical trigger (`privileged`, `capabilities.add`, `hostNetwork`, `hostPID`, `hostIPC`, any `docker.sock` hostPath) and add, at minimum: `allowPrivilegeEscalation: false` (+7), all four `resources` fields (+4). That is **11** — over the threshold with zero criticals. In practice also add `capabilities.drop: ["ALL"]` (+2), `readOnlyRootFilesystem: true` (+1), `runAsNonRoot: true` (+1), `runAsUser: 20001` (+1), `serviceAccountName` (+1) and `seccompProfile.type: RuntimeDefault` (+1) — because the point of the task is the posture, not the number.

**Task 4:**
```bash
skopeo inspect --config docker://registry.example.com/app:2.1 | jq -r '.config.User'
# or
crane config registry.example.com/app:2.1 | jq -r '.config.User'
```
Empty string, `"0"`, or `"root"` ⇒ it runs as root.

**Task 5:** Either (a) rebuild the image with a `USER <non-root-uid>` instruction (and `chown` whatever paths it needs), or (b) set `runAsUser: <non-zero>` explicitly in the pod's `securityContext` so the kubelet has a concrete non-root UID and no longer needs to consult the image. In a hardened cluster choose **(a)**, fixing the image: it makes the workload safe everywhere it is deployed, including clusters and namespaces that do not enforce `runAsNonRoot`, and it removes the possibility of a future manifest omitting the override. (b) is the correct *immediate* mitigation while the image rebuild is in flight, and both together are better than either alone. Note that (a) still requires the image's files to be readable/writable by the new UID — which is exactly the work that makes teams reach for the manifest override instead.

**A9.1** — If you pass `--include` without disabling defaults, the default check set is still added and your three checks are *added on top* — you get the full default noise plus the extras, which is not what the task asked for. `--do-not-auto-add-defaults` (CLI) / `checks.doNotAutoAddDefaults: true` (config) suppresses the default set so that `include` becomes the complete list.

**A9.2** — No. `resources` gives +4 (requests cpu/memory, limits cpu/memory) and `serviceAccountName` gives +1, for a total of **+5** — short of 10. You need `allowPrivilegeEscalation: false` (+7) to clear it comfortably, or the combination of `capabilities.drop: ["ALL"]` (+2), `readOnlyRootFilesystem` (+1), `runAsNonRoot` (+1) and `runAsUser > 10000` (+1) to reach exactly 10. Doing the arithmetic from the tool's own `scoring[].points` output — rather than from memory — is the transferable skill, since the weights differ by version.

**A9.3** — Fix (b), setting `runAsUser` in the manifest, is the weaker choice *if used as the permanent fix*: the image still ships a root default, so the security property depends entirely on every future manifest remembering the override. What you surrender is **defence in depth at the artefact layer** — the guarantee that the workload is safe regardless of how it is deployed. Any deployment path that skips your hardened templates (a debug `kubectl run`, another team reusing the image, a DR restore from an older manifest) runs it as root.

</details>