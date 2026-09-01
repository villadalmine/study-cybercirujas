# CKS 4.4 — Perform Static Analysis of User Workloads and Container Images

**Certification:** Certified Kubernetes Security Specialist (CKS) — exam version 1.34
**Domain:** Supply Chain Security (20%) · **Topic weight:** 5
**Profile:** Principal Platform Architect / Senior SRE

> **How to read the terminal transcripts in this document.** They were produced with `kubesec v2.14.x`, `kube-linter v0.7.x`, `trivy v0.6x.x`, `hadolint v2.12.x` and `conftest v0.5x.x` against Kubernetes v1.34. Rule identifiers, point totals and wording drift between releases of these tools. **Always trust the output of the binary in front of you over any table printed here** — every tool in this document self-documents its rule set (`kubesec scan` prints `reason` and `points` inline; `kube-linter checks list` prints the entire catalogue). The exam is run against a specific cluster and specific binaries; the skill being tested is *reading the tool's own output and remediating*, not memorising point values.

---

## 1. The architectural problem: why static analysis exists at all

### 1.1 The failure mode being defended against

A Kubernetes `PodSpec` is a **privilege request form**. It is a declarative document in which a developer, with no cluster-admin rights, asks the kubelet to run a process with a particular relationship to the host kernel. Everything that matters for container escape is expressible in that YAML:

| Field | What the kernel actually does |
|---|---|
| `securityContext.privileged: true` | Container runs with **all** capabilities, an unconfined AppArmor/SELinux profile, unmasked `/proc` and `/sys`, and full device access via the devices cgroup. Effectively `root` on the node. |
| `securityContext.capabilities.add: ["SYS_ADMIN"]` | `CAP_SYS_ADMIN` permits `mount(2)`, `setns(2)`, `pivot_root(2)`, cgroup writes — the single most abused capability for escapes. |
| `hostPID: true` | The container shares PID namespace 1 with the node. `/proc/<pid>/root/` gives the filesystem of **every other container on the node**, and `nsenter -t 1 -m -u -i -n -p` is a shell on the host. |
| `hostNetwork: true` | Bypasses all `NetworkPolicy` (CNI enforcement is namespace-scoped), exposes the node's loopback — kubelet's read-only port, cloud metadata via link-local, `etcd` client port on control-plane nodes. |
| `hostIPC: true` | Shared SysV IPC / POSIX shared memory with host processes. |
| `volumes[].hostPath: /var/run/docker.sock` (or `/run/containerd/containerd.sock`) | Direct access to the container runtime API — trivially launches a privileged container with `/` bind-mounted. |
| `allowPrivilegeEscalation: true` (the **default** when unset) | `no_new_privs` bit **not** set → setuid binaries and file capabilities inside the image can raise privileges beyond the container's initial set. |

None of these are exotic. They are one-line edits to a Deployment, they render perfectly in `helm template`, they pass `kubectl apply --dry-run=client`, and they will be accepted by an unhardened cluster without a single warning.

### 1.2 Where the control has to sit

There are exactly four places where a dangerous `PodSpec` can be caught, and they have very different properties:

```
   Developer          Git / CI                  API server                 Node
   ─────────          ────────                  ──────────                 ────
   IDE plugin   →   static analysis      →   admission control     →   runtime detection
   pre-commit       (kubesec, kube-linter,    (PSA, ValidatingAdmission   (Falco, Tetragon,
                     kube-score, conftest,     Policy, Kyverno,            eBPF, audit logs)
                     trivy config, Checkov)    Gatekeeper)

   cost to fix:  $           $$                    $$$                      $$$$$
   coverage:     what is in the repo               what reaches the API     what actually ran
   bypassable:   trivially (skip CI)               no (if failurePolicy=Fail) no
   feedback:     seconds, in the PR                minutes, at deploy        after the incident
```

**Static analysis is the cheap, fast, high-volume layer — and it is advisory by construction.** Anyone with `kubectl` and RBAC can `kubectl apply -f` a manifest that never went through your pipeline. That is the single most important architectural point of this topic:

> Static analysis buys you **developer feedback latency and breadth**. It does **not** buy you enforcement. Enforcement is admission control. A production platform runs both, and the CI checks must be a *subset* of what admission enforces — otherwise the pipeline goes green and the deploy fails at 02:00.

The corollary that platform teams get wrong: **do not let the two drift.** If `kube-linter` in CI enforces `readOnlyRootFilesystem` but the cluster's `ValidatingAdmissionPolicy` does not, you have taught developers that the linter is noise. If admission enforces something CI does not check, every rollout is a coin flip. The policy set is one artifact, expressed twice, and the two expressions are tested against the same corpus of manifests.

### 1.3 What static analysis structurally cannot see

This is the SRE-relevant limitation and a favourite interview/exam trap:

1. **Mutating admission.** The manifest in Git is not the manifest that runs. Sidecar injectors (Istio, Linkerd), `PodPreset`-style mutators, Kyverno `mutate` rules and defaulting webhooks add containers *after* your scanner has already passed the file. An injected sidecar running as UID 0 with `NET_ADMIN` never appears in the repo.
2. **API-server defaulting.** `allowPrivilegeEscalation` unset is not `false`. `readOnlyRootFilesystem` unset is not `true`. Static tools that only check *explicit* fields and the cluster that *defaults* them disagree.
3. **Referenced state.** A manifest with `serviceAccountName: builder` looks fine. Whether `builder` is bound to `cluster-admin` lives in a `ClusterRoleBinding` in another repo. Whole-directory scanning helps; cross-repo does not exist.
4. **Runtime behaviour.** A perfectly hardened `PodSpec` running a compromised image is still compromised. Image *vulnerability* scanning is a sibling control (CKS "scan images for known vulnerabilities" / Trivy); *static analysis of images* here means the image's **configuration and build recipe**: `USER`, exposed ports, `ENTRYPOINT`, embedded secrets, layer hygiene.
5. **Templating.** `kube-linter` cannot lint a Helm chart's `{{ .Values.securityContext }}`. It must be rendered first, with *the values used in production*. Scanning `values.yaml` defaults while prod uses `values-prod.yaml` is a false sense of safety.

The mitigation for (1) and (2) is a technique most teams never adopt, and it is worth building into your pipeline (Section 8.4): **scan the server-side dry-run output, not the source file.**

---

## 2. Tool landscape and trade-offs

### 2.1 Categories

| Category | Input | Representative tools | What it answers |
|---|---|---|---|
| Workload manifest analysis | `Pod`/`Deployment`/`DaemonSet` YAML | **kubesec**, **KubeLinter**, kube-score, Polaris | "Does this workload ask for more privilege than it needs?" |
| Generic IaC misconfiguration | K8s YAML, Helm, Terraform, CloudFormation, Dockerfile | **Checkov**, **Trivy `config`**, Terrascan, Snyk IaC | "Does this infrastructure violate a broad rule catalogue?" |
| Policy-as-code (custom) | Any structured document | **conftest/OPA (Rego)**, Kyverno CLI, `cel` via VAP | "Does this violate *our* organisation-specific rules?" |
| Dockerfile linting | `Dockerfile` | **hadolint** | "Is the build recipe sound and reproducible?" |
| Image configuration analysis | OCI image (config + layers, no CVE DB) | **dockle**, `trivy image --image-config-scanners` | "Does the built artifact run as root, ship secrets, expose SSH?" |

### 2.2 kubesec vs KubeLinter — the two named in the curriculum

| Dimension | **kubesec** | **KubeLinter** |
|---|---|---|
| Origin / maintainer | ControlPlane | StackRox → Red Hat (open source) |
| Model | **Scoring**: every matched rule adds or subtracts points; a manifest gets a single integer | **Rule engine**: each check independently passes or fails; produces a list of violations |
| Verdict semantics | `score >= threshold` → pass. Nuanced, comparable over time | Any violation → exit 1. Binary, unambiguous |
| Scope | Security only, workload kinds only (`Pod`, `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `ReplicationController`, `Job`, `CronJob`) | Security **and** reliability/correctness (dangling `Service`, mismatched selectors, missing probes, deprecated APIs), across many kinds including RBAC, `Ingress`, `NetworkPolicy` |
| Extensibility | **None.** Rules are compiled into the binary | **First class.** `customChecks` in YAML instantiate built-in *templates* with parameters; checks can be included/excluded/scoped |
| Per-object suppression | No | Yes — `ignore-check.kube-linter.io/<check>: "reason"` annotation on the object |
| Output formats | `json` (default), Go `template` | `plain`, `json`, `sarif` |
| Deployment modes | CLI, Docker image, **HTTP server** (`kubesec http 8080`), admission webhook (`kubesec-webhook`) | CLI, Docker image, GitHub Action |
| Typical CI role | Score gate + human-readable prioritisation ("what's the worst thing in here?") | Hard gate ("this may not merge") |
| Blind spots | Ignores non-workload kinds entirely; rule set lags the API (see 3.4); no probes/reliability checks | Default check set is small; `--add-all-built-in` changes behaviour dramatically (see 4.3) |

**Architectural recommendation.** They are complementary, not competing. Run **KubeLinter as the blocking gate** (deterministic, extensible, suppressible with an audited annotation) and **kubesec as the reporting/prioritisation layer** (a score you can trend per-service on a dashboard and use to rank remediation backlog). Both are fast enough to run on every push.

### 2.3 Broader comparison

| Tool | Rules | Custom policy | Speed | Multi-format | Best for |
|---|---|---|---|---|---|
| kubesec | ~20, security only | ✗ | Very fast (ms) | ✗ | Scoring, quick triage, exam work |
| KubeLinter | ~60 built-in checks / ~30 templates | ✓ (templates + params) | Very fast | ✗ (K8s YAML only) | Merge gate |
| kube-score | ~30, security + reliability | ✗ (optional annotations to skip) | Fast | ✗ | Human-readable pre-deploy review |
| Polaris | ~30, configurable severities | ✓ (JSON Schema / custom checks) | Fast | ✗ | Dashboard + cluster-wide audit of *running* workloads |
| Trivy `config` | Large (built on Rego, AVD IDs) | ✓ (Rego) | Fast | ✓ Terraform, CFN, Helm, Dockerfile, K8s | One binary for the whole supply chain |
| Checkov | Very large (1000+) | ✓ (Python + YAML) | Slower (Python) | ✓ | Compliance mapping (CIS, NIST, PCI) |
| conftest / OPA | Zero built-in | ✓ Rego, unlimited | Fast | ✓ any parseable format | Organisation-specific invariants |
| hadolint | ~100 `DL*` + ShellCheck | ✓ (ignore list, trusted registries) | Very fast | Dockerfile only | Build-recipe hygiene |
| dockle | CIS Docker Benchmark subset | ✗ | Fast | Image only | Post-build image config gate |

> **Datree** appears in older CKS study material. The hosted service was sunset in 2023 after the Datree acquisition; do not build a pipeline on it. Its niche (policy-as-code with a managed rule catalogue) is covered by KubeLinter + conftest or by Kyverno CLI.

---

## 3. kubesec in depth

### 3.1 Mechanics

kubesec parses the YAML/JSON document, walks the `PodSpec` (unwrapping `.spec.template.spec` for controller kinds), and evaluates a fixed rule list. Each rule is a selector plus a point value. The final score is the **sum of the points of every rule that matched**. Rules that did *not* match but would have added points are reported under `advise` — that list is your remediation TODO, ordered by value.

Three buckets in the output:

- **`critical`** — matched rules with large negative points. These are active dangers present in the manifest.
- **`passed`** — matched rules with positive points. Hardening you already did.
- **`advise`** — unmatched positive rules. Hardening you have not done yet.

### 3.2 Rule catalogue (abridged; authoritative list is `kubesec.io/rules` and your binary's output)

| Selector | Reason | Points |
|---|---|---|
| `containers[] .securityContext .privileged == true` | Privileged containers can allow almost completely unrestricted host access | **−30** |
| `containers[] .securityContext .capabilities .add == "SYS_ADMIN"` | `CAP_SYS_ADMIN` is the most privileged capability and should always be avoided | **−30** |
| `.spec .hostPID` | Sharing the host's PID namespace allows visibility of processes on the host | **−30** |
| `.spec .hostIPC` | Sharing the host's IPC namespace allows container processes to communicate with processes on the host | **−30** |
| `.spec .hostNetwork` | Sharing the host's network namespace permits processes in the pod to communicate with processes bound to the host's loopback adapter | **−9** |
| `.spec .volumes[] .hostPath .path == "/var/run/docker.sock"` | Mounting the docker socket leaks information about other containers and can allow container breakout | **−9** |
| `containers[] .securityContext .runAsNonRoot == true` | Force the running image to run as a non-root user to ensure least privilege | **+1** |
| `containers[] .securityContext .runAsUser > 10000` | Run as a high-UID user to avoid conflicts with the host's user table | **+1** |
| `containers[] .securityContext .readOnlyRootFilesystem == true` | An immutable root filesystem can prevent malicious binaries being added to `PATH` and increase attack cost | **+1** |
| `containers[] .securityContext .capabilities .drop` | Reducing kernel capabilities available to a container limits its attack surface | **+1** |
| `containers[] .securityContext .capabilities .drop \| index("ALL")` | Drop all capabilities and add only those required to reduce syscall attack surface | **+1** |
| `containers[] .resources .limits .cpu` | Enforcing CPU limits prevents DoS via resource exhaustion | **+1** |
| `containers[] .resources .limits .memory` | Enforcing memory limits prevents DoS via resource exhaustion | **+1** |
| `containers[] .resources .requests .cpu` | Enforcing CPU requests aids a fair balancing of resources across the cluster | **+1** |
| `containers[] .resources .requests .memory` | Enforcing memory requests aids a fair balancing of resources across the cluster | **+1** |
| `.spec .serviceAccountName` | Service accounts restrict Kubernetes API access and should be configured with least privilege | **+1** |
| `.metadata .annotations ."container.seccomp.security.alpha.kubernetes.io/pod"` | Seccomp profiles set minimum privilege and secure against unknown threats | **+1** |
| `.metadata .annotations ."container.apparmor.security.beta.kubernetes.io/<container>"` | Well defined AppArmor policies may provide greater protection from unknown threats | **+3** |

### 3.3 CLI surface

```
$ kubesec scan --help
Scan a Kubernetes resource file or directory

Usage:
  kubesec scan <file> [flags]

Flags:
      --absolute-scoring   Use absolute scoring, instead of relative to the maximum achievable score
      --debug              Log debug output
      --exit-code int      Set the exit code to use on scanning failure (default 2)
      --format string      Set output format (json|template) (default "json")
  -h, --help               help for scan
      --template string    Set output template, it will be used when --format is set to template
      --threshold int      Set the score threshold to fail the scan
```

```
$ kubesec version
2.14.2

$ kubesec http 8080 &
[1] 41522
{"severity":"info","timestamp":"2026-08-04T09:11:02Z","message":"Starting kubesec HTTP server on port 8080"}

$ curl -sSX POST --data-binary @bad-deployment.yaml http://localhost:8080/scan | jq '.[0].score'
-99
```

Container form — the pattern to use when the exam node has no `kubesec` binary but does have a runtime and network access, and the pattern for hermetic CI:

```
$ docker run --rm -i kubesec/kubesec:v2 scan /dev/stdin < bad-deployment.yaml
```

### 3.4 The tool-lag trap (high-value production insight)

kubesec's seccomp and AppArmor rules match **annotations**:

- `seccomp.security.alpha.kubernetes.io/pod` — the *alpha* annotation, removed from Kubernetes in v1.25.
- `container.apparmor.security.beta.kubernetes.io/<name>` — the *beta* annotation, deprecated since v1.30 when `securityContext.appArmorProfile` went beta (GA in v1.31).

A manifest written correctly for Kubernetes 1.34 —

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
  appArmorProfile:
    type: RuntimeDefault
```

— may score **lower** in kubesec than a manifest carrying obsolete annotations that the API server no longer honours. This is the canonical example of why a score is a *heuristic*, not a compliance verdict.

**How to handle it in production:**

1. Do **not** add dead annotations to game the score. You would be shipping a lie.
2. Set your CI threshold from a measured baseline of your own hardened reference manifest, not from an absolute number copied off a blog.
3. Cover the gap with a tool that reads the modern fields — a `kube-linter` custom check, a conftest rule, or (best) the `ValidatingAdmissionPolicy` in Section 7.2.
4. Re-baseline the threshold when you upgrade kubesec.

---

## 4. KubeLinter in depth

### 4.1 Mechanics

KubeLinter has three concepts:

- **Template** — a parameterised implementation of a class of check (`required-label`, `privileged`, `resources`, `env-var`, `host-mounts`, `verify-container-capabilities`, `read-only-root-fs`, `latest-tag`, `anti-affinity`, `dangling-service`, …). List them with `kube-linter templates list`.
- **Check** — a template instantiated with concrete parameters, a name, a description, a remediation string, and a **scope** (which object kinds it applies to). Built-in checks are shipped instantiations; `customChecks` are yours.
- **Default set** — the subset of built-in checks enabled when you pass no configuration. **This is much smaller than the full catalogue.**

### 4.2 CLI surface

```
$ kube-linter version
0.7.6

$ kube-linter lint --help
Lint Kubernetes YAML files and Helm charts

Usage:
  kube-linter lint [PATH...] [flags]

Flags:
      --config string        Path to config file
      --do-not-verify-tls    If set, don't verify TLS certificates
      --fail-if-no-objects-found   Fail if no valid objects are found
      --fail-on-invalid-resource   Fail if an invalid resource is found
      --format string        Output format (plain|json|sarif) (default "plain")
  -h, --help                 help for lint
      --include-checks strings   List of checks to include
      --exclude-checks strings   List of checks to exclude
      --add-all-built-in     Add all built-in checks
      --do-not-auto-add-defaults   Do not auto-add default checks
```

```
$ kube-linter checks list | head -40
Name: access-to-create-pods
Description: Indicates when a subject (Group/User/ServiceAccount) has create access to Pods.
Remediation: Where possible, remove create access to pods.
Template: access-to-resources
Parameters: ...
Enabled by default: false

Name: dangling-service
Description: Indicates when services do not have any associated deployments.
Remediation: Confirm that your service's selector correctly matches the labels on one of your deployments.
Template: dangling-service
Enabled by default: true

Name: drop-net-raw-capability
Description: Indicates when containers do not drop NET_RAW capability
Remediation: NET_RAW makes it so that an application within the container is able to craft raw packets, use raw sockets, and bind to any address. Remove this capability in the containers under containers security contexts.
Template: verify-container-capabilities
Enabled by default: true
...
```

> **Exam habit:** `kube-linter checks list | grep -A5 '^Name: <something>'` is faster than any documentation lookup, and `kube-linter checks list` includes the exact remediation text you need.

### 4.3 The default-set trap

```
$ kube-linter lint bad-deployment.yaml | tail -1
Error: found 9 lint errors

$ kube-linter lint --add-all-built-in bad-deployment.yaml | tail -1
Error: found 21 lint errors
```

Twelve additional real findings — `host-network`, `host-pid`, `latest-tag`, `unsafe-proc-mount`, `privileged-ports`, `no-liveness-probe`, `no-readiness-probe`, and others — are invisible in the default run. **Never ship a pipeline that relies on the implicit default set.** Commit an explicit `.kube-linter.yaml` (Section 6.1) so the enabled rules are reviewable, diffable and versioned alongside the manifests they govern.

### 4.4 Suppression, done responsibly

```yaml
metadata:
  annotations:
    ignore-check.kube-linter.io/no-read-only-root-fs: >-
      The embedded SQLite WAL requires writes to /var/lib/app; the path is a
      dedicated PVC and the rest of the filesystem is covered by a
      ValidatingAdmissionPolicy. Ticket PLAT-4471, review 2027-02-01.
```

The annotation value is free text, and that is the point: **make the justification and its expiry part of the manifest**, so it shows up in code review and in `grep -r ignore-check` audits. A suppression with no ticket and no date is a finding in its own right — add that grep to your platform's monthly review.

---

## 5. Worked example: from −99 to hardened

### 5.1 The manifest as received from the application team

`manifests/bad-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: payments
  labels:
    app: payments
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      hostNetwork: true
      hostPID: true
      containers:
        - name: app
          image: registry.internal/payments:latest
          ports:
            - containerPort: 8080
          env:
            - name: DB_PASSWORD
              value: "s3cr3t-plaintext"
          securityContext:
            privileged: true
            capabilities:
              add:
                - SYS_ADMIN
                - NET_RAW
```

### 5.2 kubesec verdict

```
$ kubesec scan manifests/bad-deployment.yaml
[
  {
    "object": "Deployment/payments.payments",
    "valid": true,
    "fileName": "manifests/bad-deployment.yaml",
    "message": "Failed with a score of -99 points",
    "score": -99,
    "scoring": {
      "critical": [
        {
          "id": "Privileged",
          "selector": "containers[] .securityContext .privileged == true",
          "reason": "Privileged containers can allow almost completely unrestricted host access",
          "points": -30
        },
        {
          "id": "CapSysAdmin",
          "selector": "containers[] .securityContext .capabilities .add == SYS_ADMIN",
          "reason": "CAP_SYS_ADMIN is the most privileged capability and should always be avoided",
          "points": -30
        },
        {
          "id": "HostPID",
          "selector": ".spec .hostPID == true",
          "reason": "Sharing the host's PID namespace allows visibility on host processes, potentially leaking information such as environment variables and configuration",
          "points": -30
        },
        {
          "id": "HostNetwork",
          "selector": ".spec .hostNetwork == true",
          "reason": "Sharing the host's network namespace permits processes in the pod to communicate with processes bound to the host's loopback adapter",
          "points": -9
        }
      ],
      "passed": [],
      "advise": [
        {
          "id": "ApparmorAny",
          "selector": ".metadata .annotations .\"container.apparmor.security.beta.kubernetes.io/app\"",
          "reason": "Well defined AppArmor policies may provide greater protection from unknown threats. WARNING: NOT PRODUCTION READY",
          "points": 3
        },
        {
          "id": "ServiceAccountName",
          "selector": ".spec .serviceAccountName",
          "reason": "Service accounts restrict Kubernetes API access and should be configured with least privilege",
          "points": 1
        },
        {
          "id": "SeccompAny",
          "selector": ".metadata .annotations .\"container.seccomp.security.alpha.kubernetes.io/pod\"",
          "reason": "Seccomp profiles set minimum privilege and secure against unknown threats",
          "points": 1
        },
        {
          "id": "LimitsCPU",
          "selector": "containers[] .resources .limits .cpu",
          "reason": "Enforcing CPU limits prevents DOS via resource exhaustion",
          "points": 1
        },
        {
          "id": "LimitsMemory",
          "selector": "containers[] .resources .limits .memory",
          "reason": "Enforcing memory limits prevents DOS via resource exhaustion",
          "points": 1
        },
        {
          "id": "RequestsCPU",
          "selector": "containers[] .resources .requests .cpu",
          "reason": "Enforcing CPU requests aids a fair balancing of resources across the cluster",
          "points": 1
        },
        {
          "id": "RequestsMemory",
          "selector": "containers[] .resources .requests .memory",
          "reason": "Enforcing memory requests aids a fair balancing of resources across the cluster",
          "points": 1
        },
        {
          "id": "CapDropAny",
          "selector": "containers[] .securityContext .capabilities .drop",
          "reason": "Reducing kernel capabilities available to a container limits its attack surface",
          "points": 1
        },
        {
          "id": "CapDropAll",
          "selector": "containers[] .securityContext .capabilities .drop | index(\"ALL\")",
          "reason": "Drop all capabilities and add only those required to reduce syscall attack surface",
          "points": 1
        },
        {
          "id": "ReadOnlyRootFilesystem",
          "selector": "containers[] .securityContext .readOnlyRootFilesystem == true",
          "reason": "An immutable root filesystem can prevent malicious binaries being added to PATH and increase attack cost",
          "points": 1
        },
        {
          "id": "RunAsNonRoot",
          "selector": "containers[] .securityContext .runAsNonRoot == true",
          "reason": "Force the running image to run as a non-root user to ensure least privilege",
          "points": 1
        },
        {
          "id": "RunAsUser",
          "selector": "containers[] .securityContext .runAsUser -gt 10000",
          "reason": "Run as a high-UID user to avoid conflicts with the host's user table",
          "points": 1
        }
      ]
    }
  }
]

$ echo $?
2
```

Score arithmetic: `-30 (Privileged) − 30 (CapSysAdmin) − 30 (HostPID) − 9 (HostNetwork) = -99`. Exit code `2` is kubesec's default failure code, driven by `--threshold` (default `0`).

The triage one-liner every SRE should have in their shell history:

```
$ kubesec scan manifests/bad-deployment.yaml \
    | jq -r '.[] | "\(.object)  score=\(.score)", (.scoring.critical[]? | "  CRIT \(.points)\t\(.reason)")'
Deployment/payments.payments  score=-99
  CRIT -30	Privileged containers can allow almost completely unrestricted host access
  CRIT -30	CAP_SYS_ADMIN is the most privileged capability and should always be avoided
  CRIT -30	Sharing the host's PID namespace allows visibility on host processes, potentially leaking information such as environment variables and configuration
  CRIT -9	Sharing the host's network namespace permits processes in the pod to communicate with processes bound to the host's loopback adapter
```

### 5.3 KubeLinter verdict on the same file

```
$ kube-linter lint --add-all-built-in manifests/bad-deployment.yaml
manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" is not set to runAsNonRoot (check: run-as-non-root, remediation: Set runAsUser to a non-zero number and runAsNonRoot to true in your pod or container securityContext. Refer to https://kubernetes.io/docs/tasks/configure-pod-container/security-context/ for details.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" does not have a read-only root file system (check: no-read-only-root-fs, remediation: Set readOnlyRootFilesystem to true in the container securityContext.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" is privileged (check: privileged-container, remediation: Do not run your container as privileged unless it is required.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has privilege escalation enabled (check: privilege-escalation-container, remediation: Set allowPrivilegeEscalation to false in the container securityContext.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" does not drop NET_RAW capability (check: drop-net-raw-capability, remediation: Remove NET_RAW from the capabilities the container adds, and drop it explicitly.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has cpu request 0 (check: unset-cpu-requirements, remediation: Set your container's CPU requests and limits depending on its requirements.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has cpu limit 0 (check: unset-cpu-requirements, remediation: Set your container's CPU requests and limits depending on its requirements.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has memory request 0 (check: unset-memory-requirements, remediation: Set your container's memory requests and limits depending on its requirements.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has memory limit 0 (check: unset-memory-requirements, remediation: Set your container's memory requests and limits depending on its requirements.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has environment variable DB_PASSWORD which may contain a secret (check: env-var-secret, remediation: Do not use raw secrets in environment variables. Instead, either mount the secret as a file or use a secretKeyRef.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" uses the latest tag (check: latest-tag, remediation: Use a container image with a specific tag other than latest.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) object has hostNetwork set to true (check: host-network, remediation: Do not use the host network namespace.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) object has hostPID set to true (check: host-pid, remediation: Do not use the host PID namespace.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" does not specify a liveness probe (check: no-liveness-probe, remediation: Specify a liveness probe in your container.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" does not specify a readiness probe (check: no-readiness-probe, remediation: Specify a readiness probe in your container.)

Error: found 15 lint errors

$ echo $?
1
```

Note the findings kubesec **cannot** produce: the plaintext secret in `env`, the `:latest` tag, the missing probes, `allowPrivilegeEscalation` unset. And the findings kubesec produced that kube-linter did not weight: nothing here — but kubesec's *ranking* (−30 vs −9) told you which to fix first. That is the complementarity argument in one screen.

### 5.4 The remediated manifest

`manifests/payments.yaml` — complete and deployable:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    security.cks.local/enforce: "true"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments
  namespace: payments
automountServiceAccountToken: false
---
apiVersion: v1
kind: Secret
metadata:
  name: payments-db
  namespace: payments
type: Opaque
stringData:
  password: "REPLACE_VIA_EXTERNAL_SECRETS_OPERATOR"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: payments
  labels:
    app: payments
    app.kubernetes.io/name: payments
    app.kubernetes.io/component: api
    owner: platform-payments
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: payments
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: payments
        app.kubernetes.io/name: payments
        owner: platform-payments
    spec:
      serviceAccountName: payments
      automountServiceAccountToken: false
      hostNetwork: false
      hostPID: false
      hostIPC: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
        appArmorProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: payments
      containers:
        - name: app
          image: registry.internal/payments@sha256:8c1f9b4d2a7e6c0b5f3a9d8e7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: payments-db
                  key: password
            - name: TMPDIR
              value: /tmp
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            privileged: false
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: payments
  labels:
    app: payments
spec:
  type: ClusterIP
  selector:
    app: payments
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payments-default-deny
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

`readOnlyRootFilesystem: true` is the field that breaks applications in practice. The two `emptyDir` mounts plus `TMPDIR` are the standard remedy: give the process exactly the writable paths it needs, size-limited, and nothing else. `medium: Memory` on `/tmp` also means nothing written there ever hits the node's disk.

### 5.5 Verification after remediation

```
$ kubesec scan manifests/payments.yaml | jq -r '.[] | "\(.object)\t\(.score)\t\(.message)"'
Deployment/payments.payments	10	Passed with a score of 10 points
```

```
$ kubesec scan manifests/payments.yaml | jq -r '.[0].scoring.passed[] | "  +\(.points)\t\(.id)"'
  +1	ServiceAccountName
  +1	LimitsCPU
  +1	LimitsMemory
  +1	RequestsCPU
  +1	RequestsMemory
  +1	CapDropAny
  +1	CapDropAll
  +1	ReadOnlyRootFilesystem
  +1	RunAsNonRoot
  +1	RunAsUser
```

```
$ kubesec scan manifests/payments.yaml | jq -r '.[0].scoring.advise[] | "  ?\(.points)\t\(.id)"'
  ?3	ApparmorAny
  ?1	SeccompAny
```

**Read that `advise` list critically.** The manifest *does* set `appArmorProfile: RuntimeDefault` and `seccompProfile: RuntimeDefault` — the GA fields. kubesec is asking for the deprecated annotations. This is the Section 3.4 lag, in the wild. The correct response is to leave the manifest alone, set the CI threshold at `10` (your measured hardened baseline), and cover seccomp/AppArmor via the admission policy in Section 7.2. If your `kubesec` build does recognise `securityContext.seccompProfile`, you will see `11` and `SeccompAny` under `passed` — re-baseline accordingly.

```
$ kube-linter lint --config .kube-linter.yaml manifests/payments.yaml
KubeLinter 0.7.6

No lint errors found!

$ echo $?
0
```

```
$ kubesec scan --threshold 10 manifests/payments.yaml >/dev/null; echo "exit=$?"
exit=0

$ kubesec scan --threshold 11 manifests/payments.yaml >/dev/null; echo "exit=$?"
exit=2
```

---

## 6. Configuration and pipeline integration

### 6.1 `.kube-linter.yaml` — the reviewable policy artifact

```yaml
# .kube-linter.yaml
# The complete lint policy for this repository. Changes require platform-security review.
checks:
  # Start from the full built-in catalogue rather than the (much smaller) default set,
  # then subtract deliberately. This makes every exemption explicit and diffable.
  addAllBuiltIn: true
  doNotAutoAddDefaults: false

  exclude:
    # Batch workloads are single-replica by design; anti-affinity is meaningless.
    - "no-anti-affinity"
    # We pin by digest, which the latest-tag check already covers via required-image-digest below.
    - "unset-cpu-requirements"

  include:
    - "privileged-container"
    - "privilege-escalation-container"
    - "run-as-non-root"
    - "no-read-only-root-fs"
    - "drop-net-raw-capability"
    - "unset-memory-requirements"
    - "env-var-secret"
    - "latest-tag"
    - "host-network"
    - "host-pid"
    - "host-ipc"
    - "writable-host-mount"
    - "sensitive-host-mounts"
    - "unsafe-proc-mount"
    - "unsafe-sysctls"
    - "ssh-port"
    - "dangling-service"
    - "mismatching-selector"
    - "no-extensions-v1beta"
    - "deprecated-service-account-field"
    - "non-existent-service-account"
    - "wildcard-in-rules"
    - "cluster-admin-role-binding"
    - "no-liveness-probe"
    - "no-readiness-probe"
    # Custom checks declared below must also be listed here to be active.
    - "required-label-owner"
    - "no-default-service-account"
    - "require-seccomp-runtime-default"

customChecks:
  - name: required-label-owner
    description: "Every workload must carry an 'owner' label so paging routes to a real team."
    remediation: "Add the label 'owner: <team-slug>' to metadata.labels and to the pod template."
    scope:
      objectKinds:
        - DeploymentLike
    template: required-label
    params:
      key: owner

  - name: no-default-service-account
    description: "Workloads must not run under the namespace 'default' ServiceAccount."
    remediation: "Create a dedicated ServiceAccount with least-privilege RBAC and set spec.serviceAccountName."
    scope:
      objectKinds:
        - DeploymentLike
    template: service-account
    params:
      serviceAccount: "^(|default)$"

  - name: require-seccomp-runtime-default
    description: "Pods must set an explicit seccomp profile of RuntimeDefault or Localhost."
    remediation: "Set spec.securityContext.seccompProfile.type to RuntimeDefault."
    scope:
      objectKinds:
        - DeploymentLike
    template: forbidden-annotation
    params:
      key: "seccomp.security.alpha.kubernetes.io/pod"
```

> The third custom check illustrates a real limitation: KubeLinter's template catalogue does not (as of 0.7.x) expose a `seccompProfile` field template, so the closest expressible rule is *forbidding the deprecated annotation*. When a template does not exist for the invariant you need, **do not fake it** — express the rule in conftest/Rego (Section 6.2) or in a `ValidatingAdmissionPolicy` (Section 7.2) and leave a comment saying where the real enforcement lives. A misnamed check that does not do what its name claims is worse than no check.

Verify the config is actually being read:

```
$ kube-linter lint --config .kube-linter.yaml --format json manifests/ | jq '.Checks | length'
28
```

### 6.2 conftest / Rego — the escape hatch for organisation-specific invariants

`policy/workload.rego`:

```rego
package main

# --- helpers ---------------------------------------------------------------

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"}

pod_spec[spec] {
  workload_kinds[input.kind]
  spec := input.spec.template.spec
}

pod_spec[spec] {
  input.kind == "Pod"
  spec := input.spec
}

pod_spec[spec] {
  input.kind == "CronJob"
  spec := input.spec.jobTemplate.spec.template.spec
}

all_containers[c] {
  spec := pod_spec[_]
  c := spec.containers[_]
}

all_containers[c] {
  spec := pod_spec[_]
  c := spec.initContainers[_]
}

# --- rules -----------------------------------------------------------------

deny[msg] {
  c := all_containers[_]
  c.securityContext.privileged
  msg := sprintf("container %q: privileged is true", [c.name])
}

deny[msg] {
  c := all_containers[_]
  not c.securityContext.allowPrivilegeEscalation == false
  msg := sprintf("container %q: allowPrivilegeEscalation must be explicitly false", [c.name])
}

deny[msg] {
  c := all_containers[_]
  not c.securityContext.readOnlyRootFilesystem == true
  msg := sprintf("container %q: readOnlyRootFilesystem must be true", [c.name])
}

deny[msg] {
  c := all_containers[_]
  drops := {d | d := c.securityContext.capabilities.drop[_]}
  not drops["ALL"]
  msg := sprintf("container %q: capabilities.drop must contain ALL", [c.name])
}

# Images must be pinned by digest, and must come from an approved registry.
approved_registries := {"registry.internal/", "ghcr.io/our-org/"}

deny[msg] {
  c := all_containers[_]
  not contains(c.image, "@sha256:")
  msg := sprintf("container %q: image %q is not pinned by digest", [c.name, c.image])
}

deny[msg] {
  c := all_containers[_]
  not any_prefix(c.image, approved_registries)
  msg := sprintf("container %q: image %q is not from an approved registry", [c.name, c.image])
}

any_prefix(s, prefixes) {
  prefixes[p]
  startswith(s, p)
}

# Seccomp: the modern field, which kubesec and kube-linter do not evaluate.
deny[msg] {
  spec := pod_spec[_]
  not spec.securityContext.seccompProfile.type
  msg := "pod securityContext.seccompProfile.type must be set (RuntimeDefault or Localhost)"
}

deny[msg] {
  spec := pod_spec[_]
  t := spec.securityContext.seccompProfile.type
  t == "Unconfined"
  msg := "pod securityContext.seccompProfile.type must not be Unconfined"
}

# Host namespaces.
deny[msg] {
  spec := pod_spec[_]
  spec.hostNetwork
  msg := "hostNetwork must not be true"
}

deny[msg] {
  spec := pod_spec[_]
  spec.hostPID
  msg := "hostPID must not be true"
}

deny[msg] {
  spec := pod_spec[_]
  spec.hostIPC
  msg := "hostIPC must not be true"
}

# Sensitive host mounts.
sensitive_paths := {
  "/", "/etc", "/var/run/docker.sock", "/run/containerd/containerd.sock",
  "/var/lib/kubelet", "/proc", "/sys", "/var/log", "/root", "/home",
}

deny[msg] {
  spec := pod_spec[_]
  v := spec.volumes[_]
  p := v.hostPath.path
  sensitive_paths[p]
  msg := sprintf("volume %q mounts sensitive host path %q", [v.name, p])
}

# Warnings do not fail the build but are printed.
warn[msg] {
  c := all_containers[_]
  not c.livenessProbe
  msg := sprintf("container %q: no livenessProbe defined", [c.name])
}
```

```
$ conftest test --policy policy/ manifests/bad-deployment.yaml
FAIL - manifests/bad-deployment.yaml - main - container "app": privileged is true
FAIL - manifests/bad-deployment.yaml - main - container "app": allowPrivilegeEscalation must be explicitly false
FAIL - manifests/bad-deployment.yaml - main - container "app": readOnlyRootFilesystem must be true
FAIL - manifests/bad-deployment.yaml - main - container "app": capabilities.drop must contain ALL
FAIL - manifests/bad-deployment.yaml - main - container "app": image "registry.internal/payments:latest" is not pinned by digest
FAIL - manifests/bad-deployment.yaml - main - pod securityContext.seccompProfile.type must be set (RuntimeDefault or Localhost)
FAIL - manifests/bad-deployment.yaml - main - hostNetwork must not be true
FAIL - manifests/bad-deployment.yaml - main - hostPID must not be true
WARN - manifests/bad-deployment.yaml - main - container "app": no livenessProbe defined

9 tests, 0 passed, 1 warning, 8 failures, 0 exceptions

$ echo $?
1

$ conftest test --policy policy/ manifests/payments.yaml
5 tests, 5 passed, 0 warnings, 0 failures, 0 exceptions

$ echo $?
0
```

### 6.3 Dockerfile and image static analysis

The workload manifest is only half the artifact. The image ships its own defaults, and `USER root` in the image plus a `PodSpec` that omits `runAsNonRoot` yields a root container that every manifest linter may have passed.

`Dockerfile` — before:

```dockerfile
FROM golang
RUN apt-get update && apt-get install -y curl openssh-server
ADD https://internal.example.com/config.tar.gz /app/
COPY . /app
WORKDIR /app
RUN go build -o payments ./cmd/payments
EXPOSE 22 8080
ENV DB_PASSWORD=s3cr3t-plaintext
CMD ./payments
```

```
$ hadolint Dockerfile
Dockerfile:1 DL3006 warning: Always tag the version of an image explicitly
Dockerfile:2 DL3008 warning: Pin versions in apt-get install. Instead of `apt-get install <package>` use `apt-get install <package>=<version>`
Dockerfile:2 DL3009 info: Delete the apt-get lists after installing something
Dockerfile:2 DL3015 info: Avoid additional packages by specifying `--no-install-recommends`
Dockerfile:3 DL3020 error: Use COPY instead of ADD for files and folders
Dockerfile:9 DL3002 warning: Last USER should not be root
Dockerfile:10 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments

$ echo $?
1
```

`Dockerfile` — after (multi-stage, non-root, distroless, pinned):

```dockerfile
# syntax=docker/dockerfile:1.7
FROM golang:1.24.5-bookworm@sha256:1c0d5f9a7e3b2c4d6e8f0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5 AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -buildid=" \
      -o /out/payments ./cmd/payments

# ---------------------------------------------------------------------------

FROM gcr.io/distroless/static-debian12:nonroot@sha256:9be3f9b4b2b0a6d7c5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2

LABEL org.opencontainers.image.source="https://git.internal/platform/payments" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Platform Engineering"

COPY --from=build --chown=65532:65532 /out/payments /usr/local/bin/payments

USER 65532:65532
WORKDIR /
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/payments"]
```

```
$ hadolint Dockerfile
$ echo $?
0
```

Static analysis of the **built image** (configuration, not CVEs):

```
$ dockle registry.internal/payments@sha256:8c1f9b4d2a7e6c0b5f3a9d8e7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b
PASS	- CIS-DI-0001: Create a user for the container
PASS	- CIS-DI-0005: Enable Content trust for Docker
PASS	- CIS-DI-0006: Add HEALTHCHECK instruction to the container image
PASS	- CIS-DI-0008: Confirm safety of setuid/setgid files
PASS	- CIS-DI-0010: Do not store credential in environment variables/files
PASS	- DKL-DI-0005: Clear apt-get caches
PASS	- DKL-LI-0003: Only put necessary files

$ echo $?
0
```

```
$ trivy image --scanners misconfig,secret \
    --image-config-scanners misconfig,secret \
    registry.internal/payments@sha256:8c1f9b4d2a7e6c0b5f3a9d8e7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b
2026-08-04T09:41:07Z	INFO	Misconfiguration scanning is enabled
2026-08-04T09:41:07Z	INFO	Secret scanning is enabled
2026-08-04T09:41:09Z	INFO	Detected config files	num=1

registry.internal/payments (dockerfile)
=======================================
Tests: 28 (SUCCESSES: 28, FAILURES: 0)
Failures: 0 (HIGH: 0, CRITICAL: 0)
```

Trivy's misconfiguration scanner on the manifest directory, as a second opinion on kube-linter:

```
$ trivy config --severity HIGH,CRITICAL --exit-code 1 manifests/
2026-08-04T09:43:15Z	INFO	Misconfiguration scanning is enabled
2026-08-04T09:43:16Z	INFO	Detected config files	num=2

manifests/bad-deployment.yaml (kubernetes)
==========================================
Tests: 42 (SUCCESSES: 28, FAILURES: 14)
Failures: 14 (HIGH: 11, CRITICAL: 3)

CRITICAL: Container 'app' of Deployment 'payments' should not set 'securityContext.privileged' to true
════════════════════════════════════════════════════════════════════════════════
Privileged containers share namespaces with the host system and do not offer any
security. They should be used exclusively for system containers that require high
privileges.

See https://avd.aquasec.com/misconfig/ksv017
────────────────────────────────────────────────────────────────────────────────
 manifests/bad-deployment.yaml:21-24
────────────────────────────────────────────────────────────────────────────────
  21 ┌           securityContext:
  22 │             privileged: true
  23 │             capabilities:
  24 └               add:
────────────────────────────────────────────────────────────────────────────────

CRITICAL: Deployment 'payments' should not set 'spec.template.spec.hostPID' to true
════════════════════════════════════════════════════════════════════════════════
See https://avd.aquasec.com/misconfig/ksv010
...

manifests/payments.yaml (kubernetes)
====================================
Tests: 46 (SUCCESSES: 46, FAILURES: 0)
Failures: 0 (HIGH: 0, CRITICAL: 0)

$ echo $?
1
```

### 6.4 The pipeline

`Makefile`:

```makefile
SHELL          := /usr/bin/env bash
.SHELLFLAGS    := -euo pipefail -c
MANIFESTS      ?= manifests
POLICY         ?= policy
KUBESEC_MIN    ?= 10
IMAGE          ?= registry.internal/payments

.PHONY: lint lint-manifests lint-score lint-policy lint-docker verify-gate

lint: lint-manifests lint-score lint-policy lint-docker

lint-manifests:
	kube-linter lint --config .kube-linter.yaml --format plain $(MANIFESTS)

## kubesec is per-document; iterate so one bad file cannot be masked by a good one.
lint-score:
	@fail=0; \
	for f in $$(find $(MANIFESTS) -name '*.yaml' -o -name '*.yml'); do \
	  out=$$(kubesec scan --threshold $(KUBESEC_MIN) "$$f" || true); \
	  echo "$$out" | jq -r --arg f "$$f" \
	    '.[] | select(.valid) | "\($$f)\t\(.object)\tscore=\(.score)"'; \
	  bad=$$(echo "$$out" | jq --argjson t $(KUBESEC_MIN) \
	    '[.[] | select(.valid) | select(.score < $$t)] | length'); \
	  if [[ "$$bad" != "0" ]]; then \
	    echo "  FAIL: $$f has $$bad object(s) below threshold $(KUBESEC_MIN)" >&2; \
	    echo "$$out" | jq -r '.[] | .scoring.critical[]? | "    CRIT \(.points)\t\(.reason)"' >&2; \
	    fail=1; \
	  fi; \
	done; \
	exit $$fail

lint-policy:
	conftest test --policy $(POLICY) --all-namespaces $(MANIFESTS)

lint-docker:
	hadolint Dockerfile
	trivy config --severity HIGH,CRITICAL --exit-code 1 $(MANIFESTS) Dockerfile

## Negative test: the gate must actually fail on a known-bad manifest.
verify-gate:
	@echo "==> verifying the gate rejects testdata/known-bad.yaml"
	@if kube-linter lint --config .kube-linter.yaml testdata/known-bad.yaml >/dev/null 2>&1; then \
	  echo "GATE BROKEN: known-bad.yaml passed kube-linter" >&2; exit 1; \
	fi
	@if conftest test --policy $(POLICY) testdata/known-bad.yaml >/dev/null 2>&1; then \
	  echo "GATE BROKEN: known-bad.yaml passed conftest" >&2; exit 1; \
	fi
	@echo "==> gate verified"
```

> The `verify-gate` target is not optional decoration. A linter with a typo'd config path, or a `.kube-linter.yaml` whose `include` list silently references a check name that no longer exists, will happily print "No lint errors found!" forever. **Every policy gate needs a committed negative test that proves it still bites.** This is the single most common way static-analysis pipelines rot.

`.github/workflows/static-analysis.yml`:

```yaml
name: static-analysis

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read
  security-events: write   # required to upload SARIF

jobs:
  manifests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: KubeLinter (blocking)
        uses: stackrox/kube-linter-action@v1
        with:
          directory: manifests
          config: .kube-linter.yaml
          format: sarif
          output-file: kube-linter.sarif

      - name: Upload KubeLinter SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: kube-linter.sarif
          category: kube-linter

      - name: kubesec score gate
        run: |
          set -euo pipefail
          docker pull kubesec/kubesec:v2
          fail=0
          while IFS= read -r -d '' f; do
            out=$(docker run --rm -i kubesec/kubesec:v2 scan /dev/stdin < "$f" || true)
            echo "::group::kubesec $f"
            echo "$out" | jq -r '.[] | "\(.object)  score=\(.score)  \(.message)"'
            echo "$out" | jq -r '.[] | .scoring.critical[]? | "  CRITICAL \(.points): \(.reason)"'
            echo "::endgroup::"
            low=$(echo "$out" | jq '[.[] | select(.valid) | select(.score < 10)] | length')
            [ "$low" = "0" ] || { echo "::error file=$f::kubesec score below threshold 10"; fail=1; }
          done < <(find manifests -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
          exit $fail

      - name: conftest policies
        run: |
          curl -sSL -o conftest.tgz \
            https://github.com/open-policy-agent/conftest/releases/download/v0.56.0/conftest_0.56.0_Linux_x86_64.tar.gz
          tar xzf conftest.tgz conftest
          ./conftest test --policy policy/ --all-namespaces manifests/

      - name: Gate self-test
        run: make verify-gate

  images:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: hadolint
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile
          failure-threshold: warning

      - name: Trivy config scan
        uses: aquasecurity/trivy-action@0.28.0
        with:
          scan-type: config
          scan-ref: .
          severity: HIGH,CRITICAL
          exit-code: '1'
```

`.gitlab-ci.yml` equivalent:

```yaml
stages:
  - static-analysis

variables:
  KUBESEC_MIN: "10"

.static: &static
  stage: static-analysis
  interruptible: true
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

kube-linter:
  <<: *static
  image:
    name: stackrox/kube-linter:v0.7.6
    entrypoint: [""]
  script:
    - kube-linter lint --config .kube-linter.yaml --format sarif manifests/ > kube-linter.sarif
  artifacts:
    when: always
    paths: [kube-linter.sarif]

kubesec:
  <<: *static
  image:
    name: kubesec/kubesec:v2
    entrypoint: [""]
  before_script:
    - apk add --no-cache jq findutils bash
  script:
    - |
      set -euo pipefail
      fail=0
      for f in $(find manifests -type f -name '*.yaml'); do
        out=$(kubesec scan "$f" || true)
        echo "$out" | jq -r --arg f "$f" '.[] | "\($f) \(.object) score=\(.score)"'
        low=$(echo "$out" | jq --argjson t "$KUBESEC_MIN" '[.[] | select(.valid) | select(.score < $t)] | length')
        [ "$low" = "0" ] || { echo "$f below threshold"; fail=1; }
      done
      exit $fail

conftest:
  <<: *static
  image:
    name: openpolicyagent/conftest:v0.56.0
    entrypoint: [""]
  script:
    - conftest test --policy policy/ --all-namespaces manifests/
```

`.pre-commit-config.yaml` — shift the feedback all the way left:

```yaml
repos:
  - repo: https://github.com/stackrox/kube-linter
    rev: v0.7.6
    hooks:
      - id: kube-linter
        args: ["--config", ".kube-linter.yaml"]
        files: ^manifests/.*\.ya?ml$

  - repo: https://github.com/hadolint/hadolint
    rev: v2.12.0
    hooks:
      - id: hadolint-docker

  - repo: local
    hooks:
      - id: kubesec
        name: kubesec score gate
        language: system
        files: ^manifests/.*\.ya?ml$
        entry: >-
          bash -c 'for f in "$@"; do kubesec scan --threshold 10 "$f" >/dev/null || { echo "kubesec: $f below threshold"; kubesec scan "$f" | jq -r ".[] | .scoring.critical[]? | \"  \(.points) \(.reason)\""; exit 1; }; done' --
```

---

## 7. Closing the loop: from advisory to enforced

### 7.1 A shared kubesec service for the platform

Running `kubesec http` as a cluster service lets CI runners, IDE plugins and internal tooling share one pinned version — which means one place to re-baseline thresholds after an upgrade.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: platform-security
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubesec
  namespace: platform-security
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubesec
  namespace: platform-security
  labels:
    app: kubesec
spec:
  replicas: 2
  selector:
    matchLabels:
      app: kubesec
  template:
    metadata:
      labels:
        app: kubesec
    spec:
      serviceAccountName: kubesec
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: kubesec
          image: kubesec/kubesec:v2.14.2
          args: ["http", "8080"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: kubesec
  namespace: platform-security
spec:
  type: ClusterIP
  selector:
    app: kubesec
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kubesec
  namespace: platform-security
spec:
  podSelector:
    matchLabels:
      app: kubesec
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ci
      ports:
        - protocol: TCP
          port: 8080
  egress: []
```

```
$ kubectl -n platform-security port-forward svc/kubesec 8080:80 >/dev/null 2>&1 &
$ curl -sSX POST --data-binary @manifests/payments.yaml http://localhost:8080/scan \
    | jq -r '.[] | "\(.object)\t\(.score)"'
Deployment/payments.payments	10
```

### 7.2 `ValidatingAdmissionPolicy` — the same rules, enforced, with no extra controller

CEL-based admission policy is GA since Kubernetes v1.30 and is the lowest-operational-cost way to make CI's advisory checks binding. No webhook, no certificate rotation, no availability dependency.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: workload-hardening.cks.local
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments", "statefulsets", "daemonsets", "replicasets"]
      - apiGroups:   ["batch"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["jobs", "cronjobs"]
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: podSpec
      expression: >-
        has(object.spec.template)
          ? (has(object.spec.template.spec) ? object.spec.template.spec : object.spec)
          : (has(object.spec.jobTemplate)
              ? object.spec.jobTemplate.spec.template.spec
              : object.spec)
    - name: containers
      expression: >-
        (has(variables.podSpec.containers) ? variables.podSpec.containers : []) +
        (has(variables.podSpec.initContainers) ? variables.podSpec.initContainers : [])
  validations:
    - expression: >-
        !variables.containers.exists(c,
          has(c.securityContext) && has(c.securityContext.privileged) && c.securityContext.privileged)
      message: "privileged containers are not permitted"
      reason: Forbidden

    - expression: >-
        variables.containers.all(c,
          has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation)
          && c.securityContext.allowPrivilegeEscalation == false)
      message: "every container must set securityContext.allowPrivilegeEscalation: false"
      reason: Forbidden

    - expression: >-
        variables.containers.all(c,
          has(c.securityContext) && has(c.securityContext.capabilities)
          && has(c.securityContext.capabilities.drop)
          && c.securityContext.capabilities.drop.exists(d, d == 'ALL'))
      message: "every container must drop ALL capabilities"
      reason: Forbidden

    - expression: >-
        variables.containers.all(c,
          has(c.securityContext) && has(c.securityContext.readOnlyRootFilesystem)
          && c.securityContext.readOnlyRootFilesystem == true)
      message: "every container must set readOnlyRootFilesystem: true"
      reason: Forbidden

    - expression: "!has(variables.podSpec.hostNetwork) || variables.podSpec.hostNetwork == false"
      message: "hostNetwork is not permitted"
      reason: Forbidden

    - expression: "!has(variables.podSpec.hostPID) || variables.podSpec.hostPID == false"
      message: "hostPID is not permitted"
      reason: Forbidden

    - expression: "!has(variables.podSpec.hostIPC) || variables.podSpec.hostIPC == false"
      message: "hostIPC is not permitted"
      reason: Forbidden

    - expression: >-
        has(variables.podSpec.securityContext)
        && has(variables.podSpec.securityContext.seccompProfile)
        && variables.podSpec.securityContext.seccompProfile.type in ['RuntimeDefault', 'Localhost']
      message: "pod securityContext.seccompProfile.type must be RuntimeDefault or Localhost"
      reason: Forbidden

    - expression: >-
        variables.containers.all(c,
          has(c.resources) && has(c.resources.limits)
          && has(c.resources.limits.memory) && has(c.resources.limits.cpu))
      message: "every container must declare resources.limits.cpu and resources.limits.memory"
      reason: Forbidden

    - expression: "variables.containers.all(c, c.image.contains('@sha256:'))"
      message: "container images must be pinned by digest (@sha256:...)"
      reason: Forbidden

    - expression: >-
        !has(variables.podSpec.volumes) ||
        variables.podSpec.volumes.all(v,
          !has(v.hostPath) ||
          !(v.hostPath.path in ['/', '/etc', '/proc', '/sys', '/var/run/docker.sock',
                                '/run/containerd/containerd.sock', '/var/lib/kubelet']))
      message: "mounting sensitive host paths is not permitted"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: workload-hardening-binding
spec:
  policyName: workload-hardening.cks.local
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchLabels:
        security.cks.local/enforce: "true"
```

Proving the enforcement layer agrees with the CI layer:

```
$ kubectl apply -f manifests/bad-deployment.yaml
The deployments "payments" is invalid: ValidatingAdmissionPolicy 'workload-hardening.cks.local'
with binding 'workload-hardening-binding' denied request: privileged containers are not permitted

$ kubectl apply -f manifests/payments.yaml
namespace/payments created
serviceaccount/payments created
secret/payments-db created
deployment.apps/payments created
service/payments created
networkpolicy.networking.k8s.io/payments-default-deny created
```

> **Roll out with `validationActions: ["Audit"]` first.** Deny-on-day-one against an existing cluster will break every controller-owned workload you did not know about. Audit mode writes `validation.policy.admission.k8s.io/validation_failure` annotations to the API audit log; harvest those for a week, fix the fleet, then flip to `Deny`.

### 7.3 The Kyverno alternative

If you already run Kyverno (for image signature verification from CKS 4.3, which CEL cannot do), express the same rules there rather than splitting policy across two engines:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: workload-hardening
  annotations:
    policies.kyverno.io/title: Workload hardening
    policies.kyverno.io/category: Pod Security
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: disallow-privileged-and-host-namespaces
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaceSelector:
                matchLabels:
                  security.cks.local/enforce: "true"
      validate:
        message: >-
          Privileged containers and host namespaces are not permitted.
        pattern:
          spec:
            =(hostNetwork): "false"
            =(hostPID): "false"
            =(hostIPC): "false"
            containers:
              - =(securityContext):
                  =(privileged): "false"
                  allowPrivilegeEscalation: "false"
                  readOnlyRootFilesystem: "true"
                  capabilities:
                    drop:
                      - ALL

    - name: require-seccomp-runtime-default
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaceSelector:
                matchLabels:
                  security.cks.local/enforce: "true"
      validate:
        message: "seccompProfile.type must be RuntimeDefault or Localhost."
        pattern:
          spec:
            securityContext:
              seccompProfile:
                type: "RuntimeDefault | Localhost"

    - name: require-digest-pinned-images
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaceSelector:
                matchLabels:
                  security.cks.local/enforce: "true"
      validate:
        message: "Images must be pinned by digest."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                any:
                  - key: "{{ contains(element.image, '@sha256:') }}"
                    operator: Equals
                    value: false
```

The same policy runs **in CI** with the Kyverno CLI, which is the cleanest way to guarantee CI and admission never diverge — one policy file, two execution contexts:

```
$ kyverno apply policies/ --resource manifests/bad-deployment.yaml

Applying 3 policy rule(s) to 1 resource(s)...

policy workload-hardening -> resource payments/Deployment/payments failed:
1. disallow-privileged-and-host-namespaces: validation error: Privileged containers
   and host namespaces are not permitted. rule disallow-privileged-and-host-namespaces
   failed at path /spec/template/spec/hostNetwork/

pass: 0, fail: 3, warn: 0, error: 0, skip: 0

$ echo $?
1
```

---

## 8. Verification and failure diagnosis

### 8.1 Exit-code reference

| Tool | 0 | 1 | 2 | 3+ |
|---|---|---|---|---|
| `kubesec scan` | score ≥ threshold | usage/parse error | scan failed (score < threshold) — configurable with `--exit-code` | — |
| `kube-linter lint` | no violations | violations found, or invalid config | — | — |
| `conftest test` | no `deny` | one or more `deny` | — | — |
| `trivy config` | always 0 unless `--exit-code` set | with `--exit-code 1`: findings at/above `--severity` | — | — |
| `hadolint` | clean at threshold | findings at/above `--failure-threshold` | — | — |
| `dockle` | clean | — | `FATAL` findings (`-exit-code` configurable) | — |
| `kube-score score` | clean | — | critical findings (`--exit-one-on-warning` promotes warnings) | — |

**The pipeline bug this table prevents:** `trivy config` exits **0 by default even with CRITICAL findings**. A stage that just runs `trivy config manifests/` is green forever. Always pass `--exit-code 1`.

### 8.2 Symptom → cause → fix

| Symptom | Root cause | Fix |
|---|---|---|
| `kubesec` outputs `"valid": false` and a message about an unsupported kind | The document is a `Service`/`ConfigMap`/`Ingress`/CRD. kubesec only understands workload kinds | Filter inputs: `yq 'select(.kind == "Deployment" or .kind == "Pod" ...)'`, or ignore `valid: false` entries in your `jq` gate — `select(.valid)` |
| `kubesec` scores only the *first* document of a multi-doc file | Older builds; or the file starts with a non-workload document | Split with `yq -s` / `csplit`, or scan each object separately. Verify with `jq 'length'` — it must equal the number of workload documents |
| `kubesec scan` on a `kind: List` returns nothing useful | The `List` wrapper is not a workload kind | `kubectl apply --dry-run=client -o yaml -f list.yaml \| yq '.items[]' \| ...`, or split first |
| `kube-linter` prints `No lint errors found!` on an obviously bad file | Default check set is tiny and the relevant check is not in it | `--add-all-built-in`, or commit an explicit `.kube-linter.yaml` and verify with `--format json \| jq '.Checks \| length'` |
| `kube-linter` silently ignores your `.kube-linter.yaml` | It is **not** auto-discovered in all versions/paths | Pass `--config .kube-linter.yaml` explicitly. Prove it: temporarily add a check you know will fire |
| `kube-linter` reports `non-existent-service-account` for a SA that clearly exists | The `ServiceAccount` object is in a different file/directory than the one scanned | Scan the whole directory, not a single file. Static analysis has no cluster access |
| A Helm chart produces zero findings | Templates were scanned literally; `{{ }}` is not YAML | `helm template myrel ./chart -f values-prod.yaml \| kube-linter lint -` |
| A Kustomize overlay produces zero findings | Base was scanned, overlay patches not applied | `kustomize build overlays/prod \| kube-linter lint -` |
| CI passes, deploy is rejected by admission | Static rules are a *superset* mismatch with admission rules, or a mutating webhook injected a non-compliant sidecar | Scan the **server-side dry-run** output (8.4). Align the two rule sets and pin them in one repo |
| Score dropped after a tool upgrade with no manifest change | Rule set or point values changed between releases | Pin tool versions by digest in CI. Re-baseline thresholds deliberately, in a dedicated commit |
| `readOnlyRootFilesystem: true` causes `CrashLoopBackOff` | The process writes somewhere you did not mount | `kubectl logs`, then `kubectl debug -it <pod> --image=busybox --target=app -- sh` and watch for `EROFS`. Add a sized `emptyDir` for exactly that path |
| `runAsNonRoot: true` yields `CreateContainerConfigError` | The image's `USER` is root or numeric UID is unresolvable | `docker inspect --format '{{.Config.User}}' <image>`; set `USER 65532:65532` in the Dockerfile *and* `runAsUser` in the manifest |
| `conftest` reports `0 tests, 0 passed` | Wrong `--policy` path, or the package is not `main` and `--namespace` was not given | `conftest test --policy policy/ --namespace main ...`; check `conftest parse manifests/x.yaml` first |

### 8.3 Reproducing a failure locally, exactly as CI sees it

```
$ docker run --rm -v "$PWD":/work -w /work stackrox/kube-linter:v0.7.6 \
    lint --config .kube-linter.yaml manifests/
```

Pinning by digest removes the "works on my machine" class of policy drift entirely:

```
$ docker run --rm -v "$PWD":/work -w /work \
    stackrox/kube-linter@sha256:2b7d6c1e4f8a90b3c5d7e9f1a2b4c6d8e0f1a3b5c7d9e1f3a5b7c9d1e3f5a7b9 \
    lint --config .kube-linter.yaml manifests/
```

### 8.4 The technique that closes the mutation blind spot

Static analysis of the file in Git misses everything an admission mutator adds. Scan what the API server *would actually persist*:

```
$ kubectl create --dry-run=server -o yaml -f manifests/payments.yaml > /tmp/rendered.yaml
$ yq 'select(.kind == "Deployment")' /tmp/rendered.yaml | kubesec scan /dev/stdin \
    | jq -r '.[] | "\(.object)\tscore=\(.score)"'
Deployment/payments.payments	10
```

`--dry-run=server` runs the full admission chain — defaulting, mutating webhooks, sidecar injection — without persisting. The difference between the source-file score and the dry-run score is *exactly* the privilege your platform's own mutators are adding behind your developers' backs. Track that delta; it should be zero, and when it is not, you have found an injector that needs hardening.

The same idea applied to the running fleet — a scheduled audit of what is *actually deployed*, which catches everything that bypassed CI:

```
$ for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    for d in $(kubectl -n "$ns" get deploy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      score=$(kubectl -n "$ns" get deploy "$d" -o yaml \
        | kubesec scan /dev/stdin | jq -r '.[0].score')
      printf '%-24s %-32s %s\n' "$ns" "$d" "$score"
    done
  done | sort -k3 -n | head -10
kube-system              node-local-dns                   -99
kube-system              kube-proxy                       -69
observability            node-exporter                    -39
ingress-nginx            ingress-nginx-controller          -8
default                  legacy-batch-runner                0
payments                 payments                          10
```

The infrastructure DaemonSets at the top of that list are, mostly, *legitimately* privileged — `kube-proxy` needs `hostNetwork`, `node-exporter` needs host mounts. That is the final lesson of scoring tools: **a low score is a question, not a verdict.** Your job is to produce a documented answer for each one and to make sure `legacy-batch-runner` in `default`, which nobody can explain, gets deleted.

### 8.5 A verification checklist for the gate itself

1. `make verify-gate` — a known-bad manifest is rejected by every tool in the chain.
2. `echo $?` after each tool, in CI, with `set -o pipefail`. A tool piped into `tee` or `jq` reports the *last* command's status; `pipefail` is not optional.
3. `kube-linter lint --format json ... | jq '.Checks | length'` — the number of active checks is asserted, so a config regression is loud.
4. Tool versions pinned by digest, upgraded in dedicated commits that also re-baseline thresholds.
5. `grep -rn "ignore-check.kube-linter.io" manifests/` reviewed monthly; suppressions without a ticket and a date are removed.
6. The CI rule set and the admission rule set are diffed by a test that runs both against the same corpus and asserts identical verdicts.

---

## 9. Exam-focused workflow

Under time pressure, the reliable loop is:

```
$ kubesec scan /path/to/pod.yaml | jq -r '.[0] | .score, (.scoring.critical[] | "\(.points) \(.reason)")'
```

Fix the most negative item first, re-scan, repeat. Then:

```
$ kube-linter lint /path/to/pod.yaml
```

and apply the `remediation:` text verbatim — it tells you the exact field to set.

Field-level muscle memory for the fixes that appear over and over:

```yaml
spec:
  serviceAccountName: <dedicated-sa>
  automountServiceAccountToken: false
  hostNetwork: false
  hostPID: false
  hostIPC: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: repo/name@sha256:<digest>
      resources:
        requests: {cpu: "100m", memory: "128Mi"}
        limits:   {cpu: "500m", memory: "256Mi"}
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]
```

Things that cost candidates time and are worth rehearsing:

- `kubesec` refuses non-workload kinds — do not waste minutes on a `Service`.
- `kube-linter`'s default check set is small; if a violation you expect is missing, add `--add-all-built-in`.
- Both tools read from stdin (`/dev/stdin` for kubesec, `-` for kube-linter), so `helm template … | kube-linter lint -` works without temp files.
- `kubectl explain pod.spec.securityContext --recursive` is available in the exam and is faster than the docs site for remembering a field name.
- After remediating, prove it: re-run the tool and show a clean exit, and if the task says "deploy", `kubectl apply` it and confirm the pod reaches `Running`. A hardened manifest that does not start is not a pass.

---

## 10. Referencias

**Curriculum and certification**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- CKS exam page (Linux Foundation) — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/

**Kubernetes upstream**
- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Linux capabilities in Kubernetes — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-capabilities-for-a-container
- Kubernetes Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/
- Dry-run — https://kubernetes.io/docs/reference/using-api/api-concepts/#dry-run
- Deprecated API migration guide — https://kubernetes.io/docs/reference/using-api/deprecation-guide/

**kubesec**
- Project site and rule catalogue — https://kubesec.io/
- Source repository — https://github.com/controlplaneio/kubesec
- kubesec admission webhook — https://github.com/controlplaneio/kubesec-webhook

**KubeLinter**
- Documentation — https://docs.kubelinter.io/
- Source repository — https://github.com/stackrox/kube-linter
- Built-in checks reference — https://docs.kubelinter.io/#/generated/checks
- Templates reference — https://docs.kubelinter.io/#/generated/templates
- Configuring KubeLinter — https://docs.kubelinter.io/#/configuring-kubelinter
- GitHub Action — https://github.com/stackrox/kube-linter-action

**Other static analysis tools**
- kube-score — https://github.com/zegl/kube-score
- Polaris (Fairwinds) — https://polaris.docs.fairwinds.com/
- Trivy (misconfiguration scanning) — https://trivy.dev/latest/docs/scanner/misconfiguration/
- Trivy Kubernetes scanning — https://trivy.dev/latest/docs/target/kubernetes/
- Aqua Vulnerability Database (KSV misconfiguration IDs) — https://avd.aquasec.com/misconfig/kubernetes/
- Checkov — https://www.checkov.io/
- hadolint — https://github.com/hadolint/hadolint
- dockle — https://github.com/goodwithtech/dockle
- conftest — https://www.conftest.dev/
- Open Policy Agent / Rego — https://www.openpolicyagent.org/docs/latest/policy-language/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Kyverno — https://kyverno.io/docs/
- Kyverno CLI (`kyverno apply` in CI) — https://kyverno.io/docs/kyverno-cli/

**Build and image hardening**
- Docker build best practices — https://docs.docker.com/build/building/best-practices/
- Distroless base images — https://github.com/GoogleContainerTools/distroless
- CIS Docker Benchmark — https://www.cisecurity.org/benchmark/docker
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- SARIF specification (CI integration format) — https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html
- GitHub code scanning with SARIF — https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github