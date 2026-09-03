# 703.3 — Kubernetes Package Management

**Certification:** LPI DevOps Tools Engineer — Exam 701-100, version 2.0.0
**Topic weight:** 3.33
**Level:** Platform Architect / Senior SRE

---

## 1. The architectural problem

A Kubernetes application is never one object. A single stateless HTTP service in production is, at minimum, a `Deployment`, a `Service`, a `ServiceAccount`, a `ConfigMap`, a `Secret` reference, an `HorizontalPodAutoscaler`, a `PodDisruptionBudget`, a `NetworkPolicy`, and an `Ingress` or `HTTPRoute`. Nine API objects that must be created in a valid order, mutated together, versioned together, and — critically — *removed* together when the application is decommissioned.

`kubectl apply -f ./manifests/` solves none of the four problems that matter at scale:

**Problem 1 — Parameterisation.** The same service runs in `dev`, `staging`, and three production regions. Ninety-five percent of the YAML is identical; the delta is replica counts, resource requests, image tags, hostnames, and a feature flag. Copy-pasting the directory five times produces five artefacts that drift within one quarter. There is no `$VARIABLE` in the Kubernetes object model — the API server consumes fully-resolved JSON, so parameterisation *must* happen client-side, before the request is issued.

**Problem 2 — Grouping and lifecycle.** The API server has no concept of "application". Nothing in etcd says these nine objects are one unit. Delete the directory from Git and `kubectl apply` will happily do nothing: apply is additive. Orphaned `NetworkPolicy` objects from a decommissioned service are a real and common production hazard — they keep enforcing rules for workloads that no longer exist, and they are invisible in any dashboard that lists Deployments.

**Problem 3 — Ordering and readiness.** A `CustomResourceDefinition` must be registered before any custom resource that uses it, or the client-side manifest-to-object mapping fails outright. A schema migration `Job` must complete before the new `Deployment` rolls. A `Namespace` must exist before anything in it.

**Problem 4 — Rollback.** "Revert the deploy" is trivial for a `Deployment` (`kubectl rollout undo`) and impossible for the *application*: reverting a Deployment does not revert the ConfigMap it reads, the HPA bounds that changed with it, or the CRD field that the new version introduced.

Kubernetes package management is the discipline of solving all four with a versioned, reproducible artefact. The exam objective covers the two tools that dominate the ecosystem — **Helm** and **Kustomize** — plus the repository and distribution model around them.

> **Objective scope.** LPI publishes the authoritative key-knowledge areas for 703.3 at the exam objectives page cited in §11. This material covers, at production depth: Helm chart structure and templating, the release lifecycle and its storage model, chart repositories including OCI registries, chart provenance, Kustomize bases/overlays/patches/generators, and the diagnosis of failures in both.

---

## 2. The landscape and its trade-offs

Two philosophies compete. **Templating** (Helm, Jsonnet) treats manifests as text to be generated; the tool does not understand Kubernetes until the last moment. **Overlaying** (Kustomize) treats manifests as structured data to be merged; the tool understands the object model but has no variables.

| Dimension | Raw manifests + `apply` | Kustomize | Helm 3 | Jsonnet / Tanka | cdk8s | Operator + OLM |
|---|---|---|---|---|---|---|
| Parameterisation model | none (or `envsubst`) | structural patch (no variables) | Go `text/template` + Sprig | full functional language | general-purpose language (TS/Py/Go) | CRD spec fields |
| Input validity guaranteed | n/a | yes — patches are YAML/JSON | **no** — output can be arbitrary text | yes | yes | yes |
| Grouping / release identity | none | none (build-time only) | **yes** — release object in-cluster | none | none | yes (CR instance) |
| Atomic rollback | no | no | **yes** — `helm rollback` | no | no | operator-defined |
| Deletion of removed resources | manual | manual (or `--prune`) | **yes** — automatic on upgrade | manual | manual | yes (ownerRefs) |
| Ordering primitives | manual | manual | kind sorter + hooks + weights | manual | manual | operator logic |
| Distribution | Git | Git | **repo `index.yaml` / OCI registry** | Git / jsonnet-bundler | npm/PyPI | OLM catalog image |
| Cryptographic provenance | detached (cosign on Git) | detached | **built-in `.prov`** + OCI signing | none | none | image signing |
| Day-2 reconciliation | none | none | none (imperative CLI) | none | none | **continuous** |
| Learning curve | trivial | low | medium | high | medium (needs a runtime) | high |
| Primary failure mode | drift | patch silently targets nothing | whitespace/indent errors in templates | language complexity | build toolchain in CI | operator bugs are cluster-wide |

**Architectural reading of this table.** Helm is the only entry that carries *release identity into the cluster*, and that single property is why it owns third-party distribution: when you install someone else's database, you need one command to remove it completely. Kustomize wins for first-party application code, because the source of truth stays valid YAML that any tool can lint, and because there is no templating layer between what you read and what the API server receives.

The mature production answer is not "pick one". It is:

- **Kustomize for the applications you own** — your services, in your monorepo, where the base is authored by the same team that operates it.
- **Helm for everything you consume** — ingress controllers, cert-manager, Prometheus, databases — because those come from upstream as charts and you want their uninstall path.
- **Kustomize as a post-renderer over Helm** when an upstream chart lacks the one field you need. This is the escape hatch that removes the need to fork charts (§6.4).

---

## 3. Helm: architecture and internals

### 3.1 Chart anatomy

```
charts/checkout-api/
├── Chart.yaml            # metadata + dependency declarations (required)
├── Chart.lock            # resolved dependency versions + digest (generated)
├── values.yaml           # default configuration (required by convention)
├── values.schema.json    # JSON Schema, enforced on install/upgrade/lint/template
├── README.md
├── LICENSE
├── crds/                 # CRDs — installed first, NEVER templated, NEVER upgraded
│   └── ratelimitpolicy.yaml
├── charts/               # vendored subcharts (.tgz), written by `helm dependency update`
├── templates/
│   ├── _helpers.tpl      # files starting with _ emit no manifests
│   ├── NOTES.txt         # rendered and printed after install
│   ├── serviceaccount.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── hpa.yaml
│   ├── pdb.yaml
│   ├── networkpolicy.yaml
│   ├── job-migrate.yaml
│   └── tests/
│       └── test-connection.yaml
└── .helmignore
```

Three rules that surprise people:

1. **`crds/` is not `templates/crds/`.** Files under `crds/` are plain YAML — no templating, no values. Helm installs them *before* rendering anything else, skips them if the CRD already exists, and **never upgrades or deletes them**. This is deliberate: deleting a CRD cascades to every custom resource in the cluster, including ones your release did not create. Upgrading CRD schemas is an operator responsibility, not a chart responsibility.
2. **Anything in `templates/` that renders to empty output is dropped.** This is how conditionals work — an entire manifest wrapped in `{{- if .Values.x }}` produces a whitespace-only document that Helm discards.
3. **`.helmignore` controls what goes into the `.tgz`**, using `.gitignore` syntax. Forgetting it is how `.git/` and CI secrets end up published to a public chart repository.

### 3.2 `Chart.yaml` — the API v2 form

```yaml
apiVersion: v2                    # v2 = Helm 3; v1 charts still install but lack `dependencies`
name: checkout-api
description: Checkout API — synchronous payment authorisation edge service
type: application                 # application | library
version: 1.9.0                    # SemVer2, version of the CHART
appVersion: "2.32.0"              # version of the SOFTWARE (quoted: it is a string)
kubeVersion: ">=1.27.0-0"         # hard gate; install fails if the cluster is older
home: https://internal.example.io/checkout
sources:
  - https://git.example.io/payments/checkout-api
maintainers:
  - name: Payments Platform
    email: payments-platform@example.io
keywords:
  - payments
  - edge
annotations:
  artifacthub.io/changes: |
    - kind: security
      description: Drop NET_RAW and enforce runAsNonRoot
dependencies:
  - name: common
    version: "2.31.3"
    repository: https://charts.example.io/library
    tags:
      - helpers
  - name: redis
    version: "20.6.1"
    repository: oci://registry.example.io/charts
    condition: redis.enabled       # subchart is rendered only if this value is true
    alias: sessioncache            # subchart appears under .Values.sessioncache
    import-values:
      - child: service.ports.redis
        parent: sessionCachePort
```

`condition` and `tags` are the two ways to switch subcharts off. `condition` reads a boolean path in values (first existing path wins if comma-separated); `tags` groups several subcharts under one switch (`--set tags.helpers=false`). `alias` lets the same chart be included twice under different names.

**`version` versus `appVersion` is an exam-favourite distinction and a real operational one.** `version` is what the repository indexes and what `--version` selects; changing the chart's templates *must* bump it. `appVersion` is metadata about the packaged software and typically feeds the default image tag. A chart at `1.9.0` may ship `appVersion: 2.32.0`; a template-only fix produces `1.9.1` with an unchanged `appVersion`.

### 3.3 The rendering pipeline

Understanding the exact order is what separates debugging from guessing:

```
1. Load chart          → chart + all subcharts (from charts/, resolved via Chart.lock)
2. Coalesce values     → single merged map (precedence below)
3. Validate            → values.schema.json (parent and each subchart's own schema)
4. Build render context→ .Values .Release .Chart .Capabilities .Files .Template
5. Execute templates   → Go text/template + Sprig + Helm-specific funcs → a text blob
6. Split & parse       → split on ^---, parse YAML into unstructured objects
7. Sort                → kind sorter (InstallOrder / UninstallOrder)
8. Extract hooks       → objects with helm.sh/hook leave the main manifest
9. Send to API server  → create (install) or 3-way merge patch (upgrade)
10. Record             → write release Secret
```

Step 5 is pure text. Helm does not know it is producing YAML at that point — which is exactly why an unindented `toYaml` produces a parse error at step 6 with a line number that refers to the *rendered* output, not your template.

**Values precedence**, lowest to highest:

| Rank | Source |
|---|---|
| 1 | Subchart `values.yaml` |
| 2 | Parent chart `values.yaml` |
| 3 | Parent chart values addressing the subchart by name, and `global:` |
| 4 | `-f/--values` files, **left to right** (later file wins) |
| 5 | `--set-file` |
| 6 | `--set-string`, `--set`, `--set-json` (later flag wins) |

Two coalescing behaviours that cause incidents:

- **Maps merge; arrays replace.** `--set ingress.hosts[0].host=a.example.io` does not append to the default list, it replaces element 0 and leaves the rest. To empty a list, set it to `[]` explicitly with `--set-json`.
- **`null` deletes.** Setting a key to `null` in an override file removes the key inherited from a parent — the only way to unset a subchart default.

### 3.4 The upgrade footgun: how `helm upgrade` treats previous values

Helm 3's default is not "merge with what is already deployed". The logic is:

| Flags | Behaviour |
|---|---|
| *(none)*, **and no `-f`/`--set` supplied** | Previous user-supplied values are copied forward verbatim |
| *(none)*, **and any `-f`/`--set` supplied** | Previous user-supplied values are **discarded entirely**; only what you passed now applies, on top of chart defaults |
| `--reuse-values` | Previous values are the base; `-f`/`--set` merge on top |
| `--reset-values` | Previous values ignored; chart defaults + `-f`/`--set` |
| `--reset-then-reuse-values` | Chart defaults, then previous release values, then `-f`/`--set` (Helm ≥ 3.14) |

The second row is the trap. An operator who installed with `-f prod-values.yaml` and later runs `helm upgrade checkout ./chart --set image.tag=2.32.1` silently reverts every production override to the chart default — replica counts, resource limits, the lot. **The discipline is to always pass the complete value set on every upgrade**, from a file in Git, and never to rely on the cluster remembering.

### 3.5 Install order (the kind sorter)

Helm sorts rendered objects by kind before applying, using a fixed table in `pkg/releaseutil/kind_sorter.go`. The install order begins:

```
Namespace → NetworkPolicy → ResourceQuota → LimitRange → PodSecurityPolicy
→ PodDisruptionBudget → ServiceAccount → Secret → ConfigMap → StorageClass
→ PersistentVolume → PersistentVolumeClaim → CustomResourceDefinition
→ ClusterRole → ClusterRoleBinding → Role → RoleBinding → Service
→ DaemonSet → Pod → ReplicaSet → Deployment → HorizontalPodAutoscaler
→ StatefulSet → Job → CronJob → Ingress → APIService
```

Uninstall is not simply the reverse — it is a separate table, designed so that workloads stop before the RBAC and storage they depend on disappear.

**The sorter does not wait.** It orders the *submission* of objects, not their readiness. A `Deployment` submitted after a `Job` does not wait for the Job to complete. Readiness ordering requires hooks (§3.6) or `--wait`.

### 3.6 Hooks

A hook is an ordinary manifest carrying `helm.sh/hook`. Helm removes it from the main release manifest, applies it at the declared point in the lifecycle, and **waits for it to reach a ready state** before continuing.

| Annotation | Values |
|---|---|
| `helm.sh/hook` | `pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`, `pre-delete`, `post-delete`, `pre-rollback`, `post-rollback`, `test` |
| `helm.sh/hook-weight` | quoted integer, applied in **ascending** order within a phase |
| `helm.sh/hook-delete-policy` | `before-hook-creation` (default), `hook-succeeded`, `hook-failed` |

Two properties with real operational weight:

1. **Hook resources are not part of the release manifest.** They are therefore *not* deleted by `helm uninstall` unless a delete policy removes them, and they are *not* reconciled on upgrade. Long-lived hook `Job` objects accumulate in namespaces for years.
2. **A failed hook aborts the release.** `pre-upgrade` failing means the upgrade never touches the Deployment — which is precisely what you want for a schema migration.

### 3.7 Release storage and the three-way merge

Helm 3 stores each revision as a `Secret` (default; `--history-max` caps retention at 10):

```
name:  sh.helm.release.v1.<release>.v<revision>
type:  helm.sh/release.v1
data:  release = base64( gzip( JSON ) )        ← then base64 again by the Secret encoding
labels: name, owner=helm, status, version, modifiedAt
```

The JSON contains the release metadata, the *user-supplied* config, the fully rendered manifest, and the chart itself. That last part matters: charts are embedded, so a huge chart (hundreds of CRDs) can exceed etcd's 1 MiB object limit — see §9.

On **upgrade**, Helm computes a **three-way strategic merge patch** from:

- the manifest recorded in the *previous* release (the "old" state Helm believes it owns),
- the newly rendered manifest ("new"),
- the **live object** read from the API server.

This is why Helm 3 correctly leaves fields alone that another controller owns (an HPA writing `spec.replicas`, a service mesh injecting a sidecar) while still removing fields that the chart itself dropped. For built-in types it uses strategic merge (respecting `patchMergeKey`); for custom resources with no Go struct available it falls back to a JSON merge patch, where **lists replace wholesale**.

`--force` bypasses all of this and issues a `PUT` replace. It is a last resort, and it fails on objects with server-populated immutable fields (`Service.spec.clusterIP`).

> Helm 4 moves the apply path to **server-side apply** with field managers, which changes conflict semantics substantially. Everything described here is the Helm 3.x behaviour that the 701-100 v2.0 objective targets; check `helm version` and the release notes for the binary you actually run.

### 3.8 The `lookup` function and why it is dangerous

`lookup` queries the live cluster during rendering:

```yaml
{{- $existing := lookup "v1" "Secret" .Release.Namespace "checkout-tls" }}
{{- if $existing }}
tls.crt: {{ index $existing.data "tls.crt" }}
{{- end }}
```

It returns an **empty map during `helm template` and client-side dry-run**, because no API connection exists. A chart that generates a password only when the Secret is absent will therefore regenerate it on every GitOps render, or produce a manifest with an empty field. Charts that use `lookup` are not safely renderable offline — which breaks Argo CD's model (§10) and any `helm template | kubectl diff` workflow. Use `--dry-run=server` when you must render a `lookup` chart faithfully.

---

## 4. A complete production chart

The following is a full, self-consistent chart. Nothing is elided.

### 4.1 `values.yaml`

```yaml
replicaCount: 3

image:
  repository: registry.example.io/payments/checkout-api
  pullPolicy: IfNotPresent
  tag: ""                     # defaults to .Chart.AppVersion

imagePullSecrets:
  - name: registry-example-io

nameOverride: ""
fullnameOverride: ""

serviceAccount:
  create: true
  automount: false
  annotations: {}
  name: ""

podAnnotations: {}
podLabels: {}

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL

service:
  type: ClusterIP
  port: 8080
  metricsPort: 9090

resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    memory: 512Mi              # deliberately no CPU limit: throttling hurts p99

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 30
  targetCPUUtilizationPercentage: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300

pdb:
  enabled: true
  maxUnavailable: 1

networkPolicy:
  enabled: true
  ingressNamespaceSelector:
    kubernetes.io/metadata.name: ingress-nginx
  egressCIDRs:
    - 10.64.0.0/16

config:
  logLevel: info
  upstreamTimeoutMs: 800
  featureFlags:
    asyncSettlement: false

database:
  host: ""                     # required — enforced by `required` in the template
  port: 5432
  name: checkout
  existingSecret: checkout-db-credentials

migration:
  enabled: true
  image:
    repository: registry.example.io/payments/checkout-migrate
    tag: ""

topologySpreadEnabled: true
nodeSelector: {}
tolerations: []
affinity: {}
```

### 4.2 `templates/_helpers.tpl`

```yaml
{{/*
Base chart name, overridable. Truncated to 63 chars: the RFC 1123 label limit
that applies to most Kubernetes name fields.
*/}}
{{- define "checkout-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified name. If the release name already contains the chart name we do
not repeat it, which keeps `helm install checkout-api ./checkout-api` readable.
*/}}
{{- define "checkout-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "checkout-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. These land in Deployment.spec.selector, which is IMMUTABLE.
Nothing version-dependent may appear here, or every chart bump breaks upgrade.
*/}}
{{- define "checkout-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "checkout-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Full label set for metadata. Safe to change between revisions.
*/}}
{{- define "checkout-api.labels" -}}
helm.sh/chart: {{ include "checkout-api.chart" . }}
{{ include "checkout-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: payments
{{- end }}

{{- define "checkout-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "checkout-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference with an appVersion fallback, so a chart-only change does not
require re-stating the tag.
*/}}
{{- define "checkout-api.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}
```

### 4.3 `templates/serviceaccount.yaml`

```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "checkout-api.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount }}
{{- end }}
```

### 4.4 `templates/configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "checkout-api.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
data:
  application.yaml: |
    server:
      port: {{ .Values.service.port }}
      shutdownGracePeriodMs: 25000
    logging:
      level: {{ .Values.config.logLevel }}
      format: json
    upstream:
      timeoutMs: {{ .Values.config.upstreamTimeoutMs }}
    database:
      host: {{ required "database.host is required — set it per environment" .Values.database.host }}
      port: {{ .Values.database.port }}
      name: {{ .Values.database.name }}
    features:
      {{- toYaml .Values.config.featureFlags | nindent 6 }}
```

`required` fails the render with your message rather than shipping an empty string into production. `fail` is its unconditional sibling, used inside `if` blocks to reject invalid combinations.

### 4.5 `templates/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "checkout-api.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      {{- include "checkout-api.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        # Forces a pod rollout whenever the rendered ConfigMap changes. Without
        # this, `helm upgrade` updates the ConfigMap and the running pods keep
        # serving the old configuration until something else restarts them.
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "checkout-api.labels" . | nindent 8 }}
        {{- with .Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "checkout-api.serviceAccountName" . }}
      automountServiceAccountToken: false
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      terminationGracePeriodSeconds: 45
      {{- if .Values.topologySpreadEnabled }}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              {{- include "checkout-api.selectorLabels" . | nindent 14 }}
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              {{- include "checkout-api.selectorLabels" . | nindent 14 }}
      {{- end }}
      containers:
        - name: checkout-api
          image: {{ include "checkout-api.image" . | quote }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          ports:
            - name: http
              containerPort: {{ .Values.service.port }}
              protocol: TCP
            - name: metrics
              containerPort: {{ .Values.service.metricsPort }}
              protocol: TCP
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.database.existingSecret }}
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.database.existingSecret }}
                  key: password
          startupProbe:
            httpGet:
              path: /healthz/start
              port: http
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet:
              path: /healthz/live
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: config
              mountPath: /etc/checkout
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          configMap:
            name: {{ include "checkout-api.fullname" . }}
        - name: tmp
          emptyDir:
            sizeLimit: 128Mi
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

Two details worth naming explicitly. `{{- if not .Values.autoscaling.enabled }}` around `replicas` is mandatory when an HPA is present: if the chart always emits `replicas`, every `helm upgrade` fights the HPA and resets the fleet to the chart default. And the `checksum/config` annotation is the canonical Helm idiom for config-triggered rollouts — Kustomize solves the same problem with generator hashes (§7.4).

### 4.6 `templates/service.yaml`, `hpa.yaml`, `pdb.yaml`, `networkpolicy.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "checkout-api.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
    - port: {{ .Values.service.metricsPort }}
      targetPort: metrics
      protocol: TCP
      name: metrics
  selector:
    {{- include "checkout-api.selectorLabels" . | nindent 4 }}
```

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "checkout-api.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "checkout-api.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
  {{- with .Values.autoscaling.behavior }}
  behavior:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
```

```yaml
{{- if .Values.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "checkout-api.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
spec:
  maxUnavailable: {{ .Values.pdb.maxUnavailable }}
  selector:
    matchLabels:
      {{- include "checkout-api.selectorLabels" . | nindent 6 }}
{{- end }}
```

```yaml
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "checkout-api.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "checkout-api.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              {{- toYaml .Values.networkPolicy.ingressNamespaceSelector | nindent 14 }}
      ports:
        - protocol: TCP
          port: {{ .Values.service.port }}
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: {{ .Values.service.metricsPort }}
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    {{- range .Values.networkPolicy.egressCIDRs }}
    - to:
        - ipBlock:
            cidr: {{ . }}
      ports:
        - protocol: TCP
          port: {{ $.Values.database.port }}
    {{- end }}
{{- end }}
```

Note `$.Values` inside the `range`: `.` is rebound to the loop element, so the root context must be reached through `$`. This is the single most common templating mistake in real charts.

### 4.7 `templates/job-migrate.yaml` — a `pre-upgrade` hook

```yaml
{{- if .Values.migration.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "checkout-api.fullname" . }}-migrate
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 2
  activeDeadlineSeconds: 600
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      name: {{ include "checkout-api.fullname" . }}-migrate
      labels:
        {{- include "checkout-api.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: migration
    spec:
      restartPolicy: Never
      serviceAccountName: {{ include "checkout-api.serviceAccountName" . }}
      automountServiceAccountToken: false
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: migrate
          image: "{{ .Values.migration.image.repository }}:{{ default .Chart.AppVersion .Values.migration.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          args: ["migrate", "up", "--timeout", "540s"]
          env:
            - name: DB_HOST
              value: {{ required "database.host is required" .Values.database.host | quote }}
            - name: DB_NAME
              value: {{ .Values.database.name | quote }}
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.database.existingSecret }}
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.database.existingSecret }}
                  key: password
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
{{- end }}
```

`hook-delete-policy: before-hook-creation` is what makes this idempotent — a `Job` name cannot be reused, so without it the second upgrade fails with `jobs.batch "…-migrate" already exists`.

### 4.8 `templates/tests/test-connection.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "checkout-api.fullname" . }}-test-readiness"
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "checkout-api.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: registry.example.io/base/curl:8.9.1
      command:
        - /bin/sh
        - -c
        - |
          set -eu
          URL="http://{{ include "checkout-api.fullname" . }}:{{ .Values.service.port }}/healthz/ready"
          for i in $(seq 1 30); do
            code=$(curl -s -o /dev/null -w '%{http_code}' "$URL" || true)
            echo "attempt ${i}: HTTP ${code}"
            [ "$code" = "200" ] && exit 0
            sleep 2
          done
          echo "readiness endpoint never returned 200"
          exit 1
```

### 4.9 `values.schema.json`

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "title": "checkout-api values",
  "type": "object",
  "required": ["image", "service", "database"],
  "additionalProperties": true,
  "properties": {
    "replicaCount": {
      "type": "integer",
      "minimum": 1,
      "maximum": 100
    },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": {
        "repository": {
          "type": "string",
          "pattern": "^registry\\.example\\.io/"
        },
        "tag": { "type": "string" },
        "pullPolicy": {
          "type": "string",
          "enum": ["Always", "IfNotPresent", "Never"]
        }
      }
    },
    "service": {
      "type": "object",
      "required": ["port"],
      "properties": {
        "type": {
          "type": "string",
          "enum": ["ClusterIP", "NodePort", "LoadBalancer"]
        },
        "port": { "type": "integer", "minimum": 1, "maximum": 65535 },
        "metricsPort": { "type": "integer", "minimum": 1, "maximum": 65535 }
      }
    },
    "database": {
      "type": "object",
      "required": ["host", "existingSecret"],
      "properties": {
        "host": { "type": "string", "minLength": 1 },
        "port": { "type": "integer" },
        "name": { "type": "string" },
        "existingSecret": { "type": "string", "minLength": 1 }
      }
    },
    "autoscaling": {
      "type": "object",
      "properties": {
        "enabled": { "type": "boolean" },
        "minReplicas": { "type": "integer", "minimum": 1 },
        "maxReplicas": { "type": "integer", "minimum": 1 },
        "targetCPUUtilizationPercentage": {
          "type": "integer", "minimum": 1, "maximum": 100
        }
      }
    }
  }
}
```

The schema is checked on `install`, `upgrade`, `lint`, and `template`. Enforcing `image.repository` to your own registry in the schema is a cheap, effective supply-chain control: a values file pointing at Docker Hub fails at render time, in CI, before it reaches a cluster.

---

## 5. Helm on the command line

### 5.1 Authoring loop

```console
$ helm create checkout-api
Creating checkout-api

$ helm lint charts/checkout-api --values env/prod/values.yaml
==> Linting charts/checkout-api
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed

$ helm lint charts/checkout-api
==> Linting charts/checkout-api
[ERROR] values.yaml: - database.host is required — set it per environment
[INFO] Chart.yaml: icon is recommended

Error: 1 chart(s) linted, 1 chart(s) failed
```

`helm lint` renders with the chart defaults, so a `required` on a value with no default fails the lint by design. Lint each environment's values file explicitly.

```console
$ helm template checkout charts/checkout-api \
    --namespace payments \
    --values env/prod/values.yaml \
    --show-only templates/deployment.yaml \
  | head -25
---
# Source: checkout-api/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-checkout-api
  namespace: payments
  labels:
    helm.sh/chart: checkout-api-1.9.0
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/instance: checkout
    app.kubernetes.io/version: "2.32.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: payments
spec:
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
      app.kubernetes.io/instance: checkout
```

`--validate` sends the rendered output to the API server for schema validation without persisting it — it catches a misspelled field that `lint` cannot:

```console
$ helm template checkout charts/checkout-api -f env/prod/values.yaml --validate
Error: unable to build kubernetes objects from release manifest: error validating "": error validating data: ValidationError(Deployment.spec.template.spec.containers[0]): unknown field "resource" in io.k8s.api.core.v1.Container
```

### 5.2 Dependencies

```console
$ helm dependency update charts/checkout-api
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "example-library" chart repository
...Successfully got an update from the "bitnami" chart repository
Update Complete. ⎈Happy Helming!⎈
Saving 2 charts
Downloading common from repo https://charts.example.io/library
Pulled: registry.example.io/charts/redis:20.6.1
Digest: sha256:6b1e9f3c4a5d2e8f7b0c1a9d3e5f7a2b4c6d8e0f1a3b5c7d9e1f3a5b7c9d1e3f
Deleting outdated charts

$ cat charts/checkout-api/Chart.lock
dependencies:
- name: common
  repository: https://charts.example.io/library
  version: 2.31.3
- name: redis
  repository: oci://registry.example.io/charts
  version: 20.6.1
digest: sha256:9f2c1a4b7d8e3f0a5c6b9d2e4f1a8c3b7e5d0f2a9c4b6e8d1f3a5c7b9e2d4f6a
generated: "2026-09-03T08:41:07.113442Z"

$ helm dependency list charts/checkout-api
NAME    VERSION  REPOSITORY                          STATUS
common  2.31.3   https://charts.example.io/library   ok
redis   20.6.1   oci://registry.example.io/charts    ok
```

`helm dependency build` installs exactly what `Chart.lock` pins — that is the CI command. `helm dependency update` re-resolves and rewrites the lock — that is the human command. Using `update` in CI destroys reproducibility.

### 5.3 Install, upgrade, inspect

```console
$ helm upgrade --install checkout charts/checkout-api \
    --namespace payments --create-namespace \
    --values env/prod/values.yaml \
    --atomic --timeout 8m --wait-for-jobs \
    --history-max 20
Release "checkout" does not exist. Installing it now.
NAME: checkout
LAST DEPLOYED: Thu Sep  3 09:14:22 2026
NAMESPACE: payments
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
checkout-api 2.32.0 is deployed as release "checkout" in namespace "payments".

Service endpoint (cluster-internal):
  http://checkout-checkout-api.payments.svc.cluster.local:8080

Verify with:
  kubectl -n payments rollout status deploy/checkout-checkout-api
  helm test checkout -n payments
```

```console
$ helm list -n payments
NAME    	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART             	APP VERSION
checkout	payments 	1       	2026-09-03 09:14:22.481903 +0000 UTC   	deployed	checkout-api-1.9.0	2.32.0

$ helm history checkout -n payments
REVISION	UPDATED                 	STATUS    	CHART             	APP VERSION	DESCRIPTION
1       	Thu Sep  3 09:14:22 2026	superseded	checkout-api-1.9.0	2.32.0     	Install complete
2       	Thu Sep  3 10:02:11 2026	deployed  	checkout-api-1.9.1	2.32.1     	Upgrade complete

$ helm get values checkout -n payments
USER-SUPPLIED VALUES:
autoscaling:
  maxReplicas: 30
  minReplicas: 6
database:
  host: checkout-db.payments.svc.cluster.local
image:
  tag: 2.32.1

$ helm get values checkout -n payments --all -o json | jq '.resources'
{
  "limits": { "memory": "512Mi" },
  "requests": { "cpu": "250m", "memory": "256Mi" }
}

$ helm get manifest checkout -n payments | grep -c '^kind:'
7

$ helm get hooks checkout -n payments | grep 'helm.sh/hook'
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook": test
```

`helm get values` without `--all` shows only what the operator supplied — this is the fastest way to answer "what is actually overridden in prod?".

**Always diff before upgrading.** The `helm-diff` plugin is not optional in a production environment:

```console
$ helm plugin install https://github.com/databus23/helm-diff
Downloading https://github.com/databus23/helm-diff/releases/download/v3.10.0/helm-diff-linux-amd64.tgz
Installed plugin: diff

$ helm diff upgrade checkout charts/checkout-api \
    -n payments -f env/prod/values.yaml
payments, checkout-checkout-api, Deployment (apps) has changed:
  ...
      spec:
        containers:
        - name: checkout-api
-         image: "registry.example.io/payments/checkout-api:2.32.0"
+         image: "registry.example.io/payments/checkout-api:2.32.1"
          resources:
            requests:
-             cpu: 250m
+             cpu: 400m
  ...
payments, checkout-checkout-api, HorizontalPodAutoscaler (autoscaling) has changed:
  ...
      spec:
-       minReplicas: 3
+       minReplicas: 6
```

### 5.4 Rollback and uninstall

```console
$ helm rollback checkout 1 -n payments --wait --timeout 5m
Rollback was a success! Happy Helming!

$ helm history checkout -n payments
REVISION	UPDATED                 	STATUS    	CHART             	APP VERSION	DESCRIPTION
1       	Thu Sep  3 09:14:22 2026	superseded	checkout-api-1.9.0	2.32.0     	Install complete
2       	Thu Sep  3 10:02:11 2026	superseded	checkout-api-1.9.1	2.32.1     	Upgrade complete
3       	Thu Sep  3 10:31:56 2026	deployed  	checkout-api-1.9.0	2.32.0     	Rollback to 1
```

Rollback creates a **new revision** — history is append-only, never rewritten. This is what makes the audit trail trustworthy.

```console
$ helm uninstall checkout -n payments --keep-history
release "checkout" uninstalled

$ helm list -n payments --uninstalled
NAME    	NAMESPACE	REVISION	UPDATED                              	STATUS    	CHART             	APP VERSION
checkout	payments 	4       	2026-09-03 11:07:02.9012 +0000 UTC   	uninstalled	checkout-api-1.9.0	2.32.0
```

`--keep-history` leaves the release record so `helm rollback` can resurrect the application. Without it, the release Secrets are deleted and the release is gone. Objects annotated `helm.sh/resource-policy: keep` survive uninstall either way — the standard protection for `PersistentVolumeClaim` objects.

### 5.5 Tests

```console
$ helm test checkout -n payments --logs
NAME: checkout
LAST DEPLOYED: Thu Sep  3 10:02:11 2026
NAMESPACE: payments
STATUS: deployed
REVISION: 2
TEST SUITE:     checkout-checkout-api-test-readiness
Last Started:   Thu Sep  3 10:04:40 2026
Last Completed: Thu Sep  3 10:04:47 2026
Phase:          Succeeded

POD LOGS: checkout-checkout-api-test-readiness
attempt 1: HTTP 503
attempt 2: HTTP 200
```

---

## 6. Distribution: repositories, OCI, provenance, post-rendering

### 6.1 Classic HTTP repositories

A chart repository is a static web server holding `.tgz` files and an `index.yaml`:

```console
$ helm package charts/checkout-api --destination dist/
Successfully packaged chart and saved it to: dist/checkout-api-1.9.0.tgz

$ helm repo index dist/ --url https://charts.example.io/payments
$ head -20 dist/index.yaml
apiVersion: v1
entries:
  checkout-api:
  - apiVersion: v2
    appVersion: "2.32.0"
    created: "2026-09-03T08:52:14.7731Z"
    description: Checkout API — synchronous payment authorisation edge service
    digest: 3f8a1c92b7d4e60f5a2c8b1d9e3f7a0c4b6d8e2f1a5c7b9d3e5f7a1c3b5d7e9f
    home: https://internal.example.io/checkout
    name: checkout-api
    type: application
    urls:
    - https://charts.example.io/payments/checkout-api-1.9.0.tgz
    version: 1.9.0
generated: "2026-09-03T08:52:14.7628Z"
```

```console
$ helm repo add example https://charts.example.io/payments
"example" has been added to your repositories

$ helm repo update example
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "example" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm search repo checkout --versions
NAME                 	CHART VERSION	APP VERSION	DESCRIPTION
example/checkout-api 	1.9.0        	2.32.0     	Checkout API — synchronous payment authorisation…
example/checkout-api 	1.8.0        	2.31.4     	Checkout API — synchronous payment authorisation…

$ helm search hub ingress-nginx --max-col-width 60
URL                                                    CHART VERSION  APP VERSION  DESCRIPTION
https://artifacthub.io/packages/helm/ingress-nginx/…   4.13.3         1.13.3       Ingress controller for Kubernetes using NGINX…
```

`helm search repo` queries your locally cached indexes; `helm search hub` queries Artifact Hub over the network. A stale cache is the reason `helm search repo` "cannot find" a version that exists — `helm repo update` first, always.

### 6.2 OCI registries — the current default

Since Helm 3.8, OCI support is GA and is the direction of travel: one registry for images and charts, one auth model, one retention policy, one signing story.

```console
$ helm registry login registry.example.io -u ci-publisher --password-stdin < ~/.ci-token
Login Succeeded

$ helm push dist/checkout-api-1.9.0.tgz oci://registry.example.io/charts
Pushed: registry.example.io/charts/checkout-api:1.9.0
Digest: sha256:c1d3e5f7a9b2c4d6e8f0a1b3c5d7e9f1a3b5c7d9e1f3a5b7c9d1e3f5a7b9c1d3

$ helm show chart oci://registry.example.io/charts/checkout-api --version 1.9.0 | head -6
Pulled: registry.example.io/charts/checkout-api:1.9.0
Digest: sha256:c1d3e5f7a9b2c4d6e8f0a1b3c5d7e9f1a3b5c7d9e1f3a5b7c9d1e3f5a7b9c1d3
apiVersion: v2
appVersion: "2.32.0"
description: Checkout API — synchronous payment authorisation edge service
name: checkout-api

$ helm install checkout oci://registry.example.io/charts/checkout-api \
    --version 1.9.0 -n payments -f env/prod/values.yaml
```

There is **no `index.yaml` in the OCI model** — the registry's tag listing *is* the index. Consequently `helm search repo` does not work against OCI; discovery uses the registry API (`crane ls`, `oras repo tags`, or the registry UI). Chart tags must be valid SemVer, because Helm maps the chart version directly onto the OCI tag; a `+build` metadata suffix is rewritten to `_` since `+` is illegal in a tag.

Media types used: config `application/vnd.cncf.helm.config.v1+json`, chart layer `application/vnd.cncf.helm.chart.content.v1.tar+gzip`, provenance layer `application/vnd.cncf.helm.chart.provenance.v1.prov`.

### 6.3 Provenance and signing

Helm's native mechanism is a detached PGP signature over the chart's SHA-256 digest and its `Chart.yaml`:

```console
$ helm package charts/checkout-api --sign \
    --key 'Payments Platform' \
    --keyring ~/.gnupg/secring.gpg \
    --destination dist/
Password for key "Payments Platform" >
Successfully packaged chart and saved it to: dist/checkout-api-1.9.0.tgz

$ cat dist/checkout-api-1.9.0.tgz.prov
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

apiVersion: v2
appVersion: "2.32.0"
name: checkout-api
version: 1.9.0
...
files:
  checkout-api-1.9.0.tgz: sha256:3f8a1c92b7d4e60f5a2c8b1d9e3f7a0c4b6d8e2f1a5c7b9d3e5f7a1c3b5d7e9f
-----BEGIN PGP SIGNATURE-----
...
-----END PGP SIGNATURE-----

$ helm verify dist/checkout-api-1.9.0.tgz --keyring ~/.gnupg/pubring.gpg
Signed by: Payments Platform <payments-platform@example.io>
Using Key With Fingerprint: 9C4F1A2B7D8E3F05C6B9D2E4F1A8C3B7E5D0F2A9
Chart Hash Verified: sha256:3f8a1c92b7d4e60f5a2c8b1d9e3f7a0c4b6d8e2f1a5c7b9d3e5f7a1c3b5d7e9f

$ helm install checkout example/checkout-api --version 1.9.0 --verify -n payments
```

The `--keyring` must be a **GnuPG v1 format** keyring; modern GnuPG uses a keybox, so export first: `gpg --export-secret-keys > ~/.gnupg/secring.gpg`.

For OCI-hosted charts the ecosystem increasingly prefers **Sigstore/cosign**, because it signs the manifest digest with the same tooling and policy engine used for container images:

```console
$ cosign sign --yes registry.example.io/charts/checkout-api:1.9.0
$ cosign verify \
    --certificate-identity-regexp '^https://git\.example\.io/payments/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.io/charts/checkout-api:1.9.0
```

Enforce it at admission (Kyverno/Gatekeeper/policy-controller) rather than trusting every operator to remember `--verify`.

### 6.4 Post-renderers — patching upstream charts without forking

A post-renderer is any executable that reads the rendered manifest on stdin and writes the modified manifest on stdout. Combined with Kustomize it removes almost every reason to fork a third-party chart.

`kustomize/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - all.yaml
patches:
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: .*-controller
    patch: |-
      - op: add
        path: /spec/template/spec/topologySpreadConstraints
        value:
          - maxSkew: 1
            topologyKey: topology.kubernetes.io/zone
            whenUnsatisfiable: DoNotSchedule
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: ingress-nginx
      - op: add
        path: /spec/template/metadata/annotations/example.io~1owner
        value: platform-network
```

`kustomize/post-render.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cat > all.yaml
exec kustomize build .
```

```console
$ chmod +x kustomize/post-render.sh
$ helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --version 4.13.3 -n ingress-nginx --create-namespace \
    -f env/prod/ingress-values.yaml \
    --post-renderer ./kustomize/post-render.sh
```

Helm records the **post-rendered** manifest in the release Secret, so `helm get manifest` and the three-way merge both see the patched form. `path: /spec/template/metadata/annotations/example.io~1owner` shows JSON Pointer escaping — `/` inside a key is written `~1`, and `~` is `~0`.

---

## 7. Kustomize

### 7.1 Model

Kustomize takes a set of valid manifests (a *base*) and applies typed transformations (an *overlay*). There are no variables and no template language: every input file is a manifest that `kubectl apply -f` would accept on its own. The output is the transformed set. Kustomize is built into `kubectl` (`kubectl kustomize`, `kubectl apply -k`), and also ships standalone — the standalone binary is usually several versions ahead, which matters for newer fields.

```
deploy/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── serviceaccount.yaml
│   └── config/
│       └── application.yaml
├── components/
│   └── tracing/
│       ├── kustomization.yaml
│       └── patch-otel-sidecar.yaml
└── overlays/
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patch-resources.yaml
    └── prod-eu-west-1/
        ├── kustomization.yaml
        ├── patch-resources.yaml
        ├── patch-affinity.yaml
        └── hpa.yaml
```

### 7.2 Base

`base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
    spec:
      serviceAccountName: checkout-api
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: checkout-api
          image: registry.example.io/payments/checkout-api:2.32.0
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: http
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: config
              mountPath: /etc/checkout
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          configMap:
            name: checkout-config
        - name: tmp
          emptyDir: {}
```

`base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - serviceaccount.yaml

labels:
  - pairs:
      app.kubernetes.io/name: checkout-api
      app.kubernetes.io/part-of: payments
    includeSelectors: false      # CRITICAL: see §7.5

configMapGenerator:
  - name: checkout-config
    files:
      - config/application.yaml
    options:
      labels:
        app.kubernetes.io/component: config

images:
  - name: registry.example.io/payments/checkout-api
    newTag: 2.32.0
```

### 7.3 Overlay

`overlays/prod-eu-west-1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: payments
namePrefix: prod-

resources:
  - ../../base
  - hpa.yaml

components:
  - ../../components/tracing

commonAnnotations:
  example.io/environment: prod-eu-west-1
  example.io/owner: payments-platform

labels:
  - pairs:
      example.io/environment: prod-eu-west-1
    includeSelectors: false

replicas:
  - name: checkout-api
    count: 6

images:
  - name: registry.example.io/payments/checkout-api
    newTag: 2.32.1
    digest: ""

configMapGenerator:
  - name: checkout-config
    behavior: merge           # merge | replace | create
    literals:
      - LOG_LEVEL=info
      - UPSTREAM_TIMEOUT_MS=800

secretGenerator:
  - name: checkout-db-credentials
    type: Opaque
    envs:
      - db.env
    options:
      disableNameSuffixHash: false

patches:
  # Strategic merge patch — declarative, respects patchMergeKey on containers
  - path: patch-resources.yaml
    target:
      kind: Deployment
      name: checkout-api

  # JSON 6902 patch — precise, positional, the only way to reorder or delete
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: checkout-api
    patch: |-
      - op: add
        path: /spec/template/spec/topologySpreadConstraints
        value:
          - maxSkew: 1
            topologyKey: topology.kubernetes.io/zone
            whenUnsatisfiable: DoNotSchedule
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: checkout-api
      - op: replace
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: IfNotPresent

  # Delete a resource that the base ships but this environment must not have
  - target:
      kind: Service
      name: checkout-api-debug
    patch: |-
      $patch: delete
      apiVersion: v1
      kind: Service
      metadata:
        name: checkout-api-debug

replacements:
  - source:
      kind: ConfigMap
      name: checkout-config
      fieldPath: metadata.name
    targets:
      - select:
          kind: Deployment
          name: checkout-api
        fieldPaths:
          - spec.template.spec.volumes.[name=config].configMap.name
```

`overlays/prod-eu-west-1/patch-resources.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
spec:
  template:
    spec:
      containers:
        - name: checkout-api      # the merge key — must match the base
          resources:
            requests:
              cpu: 400m
              memory: 384Mi
            limits:
              memory: 768Mi
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:MaxRAMPercentage=70"
```

`overlays/prod-eu-west-1/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 6
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

Note that `scaleTargetRef.name: checkout-api` is *not* prefixed by hand. Kustomize's built-in `nameReference` transformer knows that an HPA's `scaleTargetRef.name` points at a Deployment and rewrites it to `prod-checkout-api` automatically. This name-reference graph is Kustomize's core value over `sed`, and it covers ServiceAccounts in pod specs, ConfigMap/Secret names in volumes and `envFrom`, Ingress backend services, and more.

`components/tracing/kustomization.yaml` — a *component* is an overlay fragment that can be composed into several overlays:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

patches:
  - path: patch-otel-sidecar.yaml
    target:
      kind: Deployment
```

### 7.4 Generators, hashes, and rollout semantics

`configMapGenerator` and `secretGenerator` append a content hash to the object name:

```console
$ kubectl kustomize overlays/prod-eu-west-1 | grep -A3 '^  name: prod-checkout-config'
  name: prod-checkout-config-9f6h2tk84d
```

Because the Deployment's volume reference is rewritten to the hashed name, **changing the ConfigMap content changes the pod template and triggers a rollout automatically**. This is Kustomize's answer to the `checksum/config` annotation, and it is strictly better: it also guarantees that a rolling-back pod gets the matching config.

The cost is garbage: old hashed ConfigMaps accumulate forever unless pruning is in play. Setting `disableNameSuffixHash: true` avoids the garbage and **silently removes the rollout trigger** — the classic "I changed the config and nothing happened" incident.

### 7.5 `includeSelectors` — the immutability landmine

The deprecated `commonLabels` field injects labels into `Deployment.spec.selector` and `Service.spec.selector` as well as metadata. `spec.selector` on a Deployment is **immutable**. Adding a `commonLabels` entry to an overlay that already has a live Deployment therefore produces an unfixable-by-apply error and forces a delete/recreate — an outage.

The modern `labels:` field defaults `includeSelectors` to `false`, which is correct. Set the selector labels once, in the base, and never change them. If you must add a selector label to a live workload, the only safe path is a blue/green rename.

### 7.6 Kustomize CLI

```console
$ kustomize version
v5.7.1

$ kubectl kustomize overlays/prod-eu-west-1 | head -30
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    example.io/environment: prod-eu-west-1
    example.io/owner: payments-platform
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/part-of: payments
    example.io/environment: prod-eu-west-1
  name: prod-checkout-api
  namespace: payments
---
apiVersion: v1
data:
  LOG_LEVEL: info
  UPSTREAM_TIMEOUT_MS: "800"
  application.yaml: |
    server:
      port: 8080
    logging:
      level: info
kind: ConfigMap
metadata:
  annotations:
    example.io/environment: prod-eu-west-1
  labels:
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/component: config
  name: prod-checkout-config-9f6h2tk84d
  namespace: payments

$ kubectl diff -k overlays/prod-eu-west-1
diff -u -N /tmp/LIVE-3910/apps.v1.Deployment.payments.prod-checkout-api /tmp/MERGED-2288/apps.v1.Deployment.payments.prod-checkout-api
--- /tmp/LIVE-3910/apps.v1.Deployment.payments.prod-checkout-api
+++ /tmp/MERGED-2288/apps.v1.Deployment.payments.prod-checkout-api
@@ -42,7 +42,7 @@
         - name: checkout-api
-          image: registry.example.io/payments/checkout-api:2.32.0
+          image: registry.example.io/payments/checkout-api:2.32.1
           resources:
             requests:
-              cpu: 250m
+              cpu: 400m
exit status 1

$ kubectl apply -k overlays/prod-eu-west-1 --server-side --field-manager=platform-gitops
serviceaccount/prod-checkout-api serverside-applied
configmap/prod-checkout-config-9f6h2tk84d serverside-applied
service/prod-checkout-api serverside-applied
deployment.apps/prod-checkout-api serverside-applied
horizontalpodautoscaler.autoscaling/prod-checkout-api serverside-applied
```

`kubectl diff` exits 1 when there is a difference — that is a feature, not a failure. In CI, `kubectl diff -k … ; [ $? -le 1 ]` is the correct guard.

**Inflating a Helm chart inside Kustomize** requires the standalone binary; `kubectl kustomize` refuses because it will not shell out to external executables:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmGlobals:
  chartHome: ./charts
helmCharts:
  - name: ingress-nginx
    repo: https://kubernetes.github.io/ingress-nginx
    version: 4.13.3
    releaseName: ingress-nginx
    namespace: ingress-nginx
    valuesFile: values-prod.yaml
```

```console
$ kubectl kustomize .
error: must specify --enable-helm

$ kustomize build --enable-helm .
# renders the chart, then applies every Kustomize transformation on top
```

This path uses `helm template` internally — there is **no release object and no `helm rollback`**. You trade Helm's lifecycle for Kustomize's transformations.

---

## 8. Choosing between them: a decision matrix

| Situation | Use | Why |
|---|---|---|
| Third-party component (ingress, cert-manager, Prometheus) | Helm | Upstream ships a chart; you need a clean uninstall |
| Third-party component that needs one unsupported field | Helm + `--post-renderer` | Avoids forking; patch survives upgrades |
| Your own microservice, 3–8 environments | Kustomize | Bases stay valid YAML; no template debugging |
| Your own service published to other teams | Helm | Versioned artefact, values as the API contract, schema-validated |
| Config that must trigger a rollout on change | Kustomize generators, or Helm `checksum/config` | Both work; generators also fix rollback correctness |
| Needs an atomic, all-or-nothing deploy with automatic revert | Helm `--atomic` | Nothing else offers it out of the box |
| Complex conditional topology across dozens of clusters | Jsonnet/Tanka or CUE-based tools | Go templates degrade past ~5 nested conditions |
| Continuously reconciled, with day-2 operations | Operator + OLM | Only a controller can do backups, failover, version-aware upgrades |

---

## 9. Verification and failure diagnosis

### 9.1 Verification ladder — run these in order

```console
# 1. Does it render at all?
$ helm template checkout charts/checkout-api -f env/prod/values.yaml > /dev/null && echo RENDER_OK
RENDER_OK

# 2. Is the rendered YAML well-formed and are the values within schema?
$ helm lint charts/checkout-api -f env/prod/values.yaml --strict

# 3. Does the API server accept every object's schema?
$ helm template checkout charts/checkout-api -f env/prod/values.yaml --validate > /dev/null

# 4. Does it violate cluster policy?
$ helm template checkout charts/checkout-api -f env/prod/values.yaml \
    | kubeconform -strict -summary -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
Summary: 7 resources found parsing stdin - Valid: 7, Invalid: 0, Errors: 0, Skipped: 0

# 5. What exactly changes in the live cluster?
$ helm diff upgrade checkout charts/checkout-api -n payments -f env/prod/values.yaml

# 6. Apply, wait, and revert automatically on failure
$ helm upgrade --install checkout charts/checkout-api -n payments \
    -f env/prod/values.yaml --atomic --timeout 8m --wait-for-jobs

# 7. Prove the workload is actually serving
$ kubectl -n payments rollout status deploy/checkout-checkout-api --timeout=5m
$ helm test checkout -n payments --logs
```

### 9.2 Failure catalogue

**`another operation (install/upgrade/rollback) is in progress`**

```console
$ helm upgrade checkout charts/checkout-api -n payments -f env/prod/values.yaml
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

The previous run was killed (CI timeout, `Ctrl-C`, evicted runner) leaving the release in `pending-upgrade`. Helm has no lock timeout; the state is stuck until you clear it.

```console
$ helm list -n payments --pending
NAME    	NAMESPACE	REVISION	UPDATED                              	STATUS         	CHART             	APP VERSION
checkout	payments 	5       	2026-09-03 12:41:07 +0000 UTC        	pending-upgrade	checkout-api-1.9.2	2.32.2

$ helm history checkout -n payments
REVISION	UPDATED                 	STATUS         	CHART             	APP VERSION	DESCRIPTION
4       	Thu Sep  3 11:58:03 2026	deployed       	checkout-api-1.9.1	2.32.1     	Upgrade complete
5       	Thu Sep  3 12:41:07 2026	pending-upgrade	checkout-api-1.9.2	2.32.2     	Preparing upgrade

# Preferred: roll back to the last good revision. This clears the lock and
# reconciles the cluster to a known state in one action.
$ helm rollback checkout 4 -n payments --wait
Rollback was a success! Happy Helming!

# Only if rollback itself is stuck: delete the pending revision's record.
# The cluster objects are untouched; you are editing Helm's bookkeeping.
$ kubectl -n payments delete secret sh.helm.release.v1.checkout.v5
secret "sh.helm.release.v1.checkout.v5" deleted
```

**`field is immutable`**

```console
$ helm upgrade checkout charts/checkout-api -n payments -f env/prod/values.yaml
Error: UPGRADE FAILED: cannot patch "checkout-checkout-api" with kind Deployment: Deployment.apps "checkout-checkout-api" is invalid: spec.selector: Invalid value: v1.LabelSelector{MatchLabels:map[string]string{"app.kubernetes.io/instance":"checkout", "app.kubernetes.io/name":"checkout-api", "app.kubernetes.io/version":"2.32.2"}, MatchExpressions:[]v1.LabelSelectorRequirement(nil)}: field is immutable
```

Someone added a version-dependent label to `selectorLabels`. No `helm upgrade` flag fixes this — `--force` issues a replace, which fails the same validation. The remedies, in order of preference:

1. Revert the chart change so the selector matches the live object.
2. Blue/green: deploy under a new release name, shift traffic, delete the old release.
3. Last resort, with an outage window: `kubectl delete deploy/... --cascade=orphan`, then upgrade so Helm adopts the orphaned pods, then let the new ReplicaSet take over.

The same class covers `StatefulSet` (only `replicas`, `template`, `updateStrategy`, `persistentVolumeClaimRetentionPolicy`, `minReadySeconds` and `ordinals` are mutable), `Job.spec.template`, `Service.spec.clusterIP`, and `PVC.spec.resources.requests.storage` shrinking.

**`no matches for kind … in version …`**

```console
$ helm install checkout charts/checkout-api -n payments -f env/prod/values.yaml
Error: INSTALLATION FAILED: unable to build kubernetes objects from release manifest: resource mapping not found for name: "checkout-limits" namespace: "payments" from "": no matches for kind "RateLimitPolicy" in version "policies.example.io/v1alpha1"
ensure CRDs are installed first
```

Helm converts the whole rendered manifest into typed objects *before* applying anything, so a CR whose CRD is not yet registered fails the entire install — even though the CRD is in the same chart, if it lives in `templates/` rather than `crds/`.

```console
$ kubectl get crd ratelimitpolicies.policies.example.io
Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "ratelimitpolicies.policies.example.io" not found

# Fix in the chart: move the CRD to crds/ (installed before rendering),
# or guard the CR so it only renders when the API is present:
```

```yaml
{{- if .Capabilities.APIVersions.Has "policies.example.io/v1alpha1" }}
apiVersion: policies.example.io/v1alpha1
kind: RateLimitPolicy
...
{{- end }}
```

`.Capabilities.APIVersions` is populated from the live cluster's discovery document and is **empty in `helm template`** unless you pass `--api-versions policies.example.io/v1alpha1`. That flag is essential in CI rendering pipelines.

**`exists and cannot be imported into the current release`**

```console
$ helm install checkout charts/checkout-api -n payments -f env/prod/values.yaml
Error: INSTALLATION FAILED: Unable to continue with install: Service "checkout-checkout-api" in namespace "payments" exists and cannot be imported into the current release: invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"; annotation validation error: missing key "meta.helm.sh/release-name": must be set to "checkout"; annotation validation error: missing key "meta.helm.sh/release-namespace": must be set to "payments"
```

An object created outside Helm (or by a previous non-Helm deployment) blocks the install. Helm will **adopt** any object that carries the correct ownership metadata:

```console
$ kubectl -n payments label   svc/checkout-checkout-api app.kubernetes.io/managed-by=Helm --overwrite
service/checkout-checkout-api labeled
$ kubectl -n payments annotate svc/checkout-checkout-api \
    meta.helm.sh/release-name=checkout \
    meta.helm.sh/release-namespace=payments --overwrite
service/checkout-checkout-api annotated

$ helm install checkout charts/checkout-api -n payments -f env/prod/values.yaml
NAME: checkout
STATUS: deployed
REVISION: 1
```

This three-annotation trick is the supported migration path from hand-rolled manifests to Helm without deleting live traffic-serving objects.

**Rendered YAML is syntactically broken**

```console
$ helm template checkout charts/checkout-api -f env/prod/values.yaml
Error: YAML parse error on checkout-api/templates/deployment.yaml: error converting YAML to JSON: yaml: line 61: mapping values are not allowed in this context
```

The line number refers to the *rendered* file, not your template. `--debug` prints the rendered output alongside the error:

```console
$ helm template checkout charts/checkout-api -f env/prod/values.yaml --debug 2>&1 | sed -n '55,65p'
        resources:
        limits:
            memory: 512Mi
          requests:
            cpu: 250m
```

Here `toYaml . | nindent 10` should have been `nindent 12`. Rule of thumb: `nindent` for the whole block (it emits the leading newline), `indent` only when the newline is already present, and always use `include` rather than `template` when piping — `template` is a statement and cannot be piped.

**Hook failures and orphaned hook resources**

```console
$ helm upgrade checkout charts/checkout-api -n payments -f env/prod/values.yaml --atomic
Error: UPGRADE FAILED: pre-upgrade hooks failed: 1 error occurred:
	* job checkout-checkout-api-migrate failed: BackoffLimitExceeded

$ kubectl -n payments logs job/checkout-checkout-api-migrate --tail=20
migrate: applying 0042_add_settlement_ref.sql
ERROR: relation "settlement" does not exist (SQLSTATE 42P01)
migrate: rollback complete
```

The Deployment was never touched — the hook did its job. Note that with `hook-delete-policy: before-hook-creation,hook-succeeded`, a *failed* Job is deliberately left behind so you can read its logs; it is deleted at the start of the next attempt.

**Release Secret exceeds the etcd object limit**

```console
$ helm install big-operator ./big-operator -n platform
Error: create: failed to create: Secret "sh.helm.release.v1.big-operator.v1" is invalid: data: Too long: may not be more than 1048576 bytes
```

The gzipped chart plus rendered manifest exceeds 1 MiB. Mitigations: move CRDs into `crds/` (they are installed outside the templated manifest), trim `.helmignore` so test fixtures and docs are not packaged, split the chart, or install CRDs separately with `--skip-crds`.

**Kustomize patch that targets nothing**

```console
$ kustomize build overlays/prod-eu-west-1
Error: no matches for Id apps_v1_Deployment|payments|checkout-apy; failed to find unique target for patch apps_v1_Deployment|checkout-apy
```

A JSON6902 patch with a non-matching target is an error. A **strategic merge patch listed under the deprecated `patchesStrategicMerge` with no matching resource is silently ignored** in some versions — which is why every patch should be written under `patches:` with an explicit `target:`. Verify with:

```console
$ kubectl kustomize overlays/prod-eu-west-1 | yq '. | select(.kind=="Deployment") | .spec.template.spec.containers[0].resources'
{"requests":{"cpu":"400m","memory":"384Mi"},"limits":{"memory":"768Mi"}}
```

**Kustomize list merge surprises**

A strategic merge patch merges container lists by the `name` key, so patching `containers[].env` **replaces the whole `env` list** for that container rather than appending — `env` has `patchMergeKey: name` with `patchStrategy: merge`, but only when both sides are processed by the strategic merge logic against a known Go type. For custom resources, Kustomize has no schema and falls back to replacing lists entirely. When you need surgical list edits on a CR, use JSON6902 with an explicit index or `-` (append):

```yaml
- op: add
  path: /spec/rules/-
  value:
    host: checkout.eu-west-1.example.io
```

**Pruning removed resources**

Neither `kubectl apply -f` nor `kubectl apply -k` deletes objects you removed from the source — the single biggest operational gap versus Helm. Options:

```console
# ApplySet-based pruning (alpha/beta depending on your kubectl and cluster;
# behind an env gate). Verify support before relying on it in production.
$ KUBECTL_APPLYSET=true kubectl apply -k overlays/prod-eu-west-1 \
    --prune --applyset=configmaps/checkout-applyset --namespace payments

# Or let a GitOps controller own pruning: Argo CD `prune: true`, Flux `prune: true`.
```

**Version-dependent output strings.** The exact wording of Helm and Kustomize error messages shifts between minor versions. Match on the *shape* of the error — "immutable", "already exists / cannot be imported", "another operation in progress", "no matches for kind" — not on the literal string, and never in an automated check.

### 9.3 Inspecting the release object directly

When `helm` itself misbehaves, read the Secret:

```console
$ kubectl -n payments get secret -l owner=helm,name=checkout
NAME                             TYPE                 DATA   AGE
sh.helm.release.v1.checkout.v4   helm.sh/release.v1   1      64m
sh.helm.release.v1.checkout.v5   helm.sh/release.v1   1      3m

$ kubectl -n payments get secret sh.helm.release.v1.checkout.v5 \
    -o jsonpath='{.data.release}' | base64 -d | base64 -d | gzip -d | jq '.info'
{
  "first_deployed": "2026-09-03T09:14:22.481903Z",
  "last_deployed": "2026-09-03T12:41:07.220144Z",
  "deleted": "",
  "description": "Preparing upgrade",
  "status": "pending-upgrade"
}

$ kubectl -n payments get secret sh.helm.release.v1.checkout.v5 \
    -o jsonpath='{.data.release}' | base64 -d | base64 -d | gzip -d \
    | jq -r '.manifest' | grep -c '^kind:'
7
```

---

## 10. Package management under GitOps

Both controllers consume charts, but with fundamentally different semantics — this determines whether Helm hooks and `lookup` work at all.

| Aspect | Argo CD | Flux (`HelmRelease`) |
|---|---|---|
| Mechanism | runs `helm template`, then applies the output itself | runs real Helm actions via the Helm SDK |
| Release Secret in cluster | **no** | **yes** |
| `helm ls` shows it | no | yes |
| Helm hooks | not executed (Argo maps them to its own sync hooks) | executed normally |
| `lookup` | returns empty | works (real cluster connection) |
| `helm rollback` | n/a — Argo reverts by re-syncing the Git commit | yes, plus automatic `remediation` on failure |
| Drift correction | continuous, via its own diff | via `driftDetection` |

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: checkout
  namespace: payments
spec:
  interval: 10m
  chart:
    spec:
      chart: checkout-api
      version: "1.9.x"
      sourceRef:
        kind: HelmRepository
        name: example-oci
        namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
    cleanupOnFail: true
  driftDetection:
    mode: enabled
  valuesFrom:
    - kind: ConfigMap
      name: checkout-values-prod
  values:
    image:
      tag: "2.32.1"
    autoscaling:
      minReplicas: 6
```

**Architectural consequence:** a chart that relies on hooks for schema migration behaves correctly under Flux and silently skips the migration under Argo CD unless you also annotate the Job with `argocd.argoproj.io/hook: PreSync`. Charts intended for both must carry both annotation sets — they do not conflict.

---

## 11. What to be able to do, unaided

- Explain `version` vs `appVersion`, and `apiVersion: v2` vs `v1` in `Chart.yaml`.
- Name every directory in a chart and state what `crds/`, `templates/_*.tpl`, and `charts/` each do.
- State the full values precedence order and predict the outcome of `helm upgrade` when `-f` is passed without `--reuse-values`.
- Add a repository, search it, install a specific chart version, upgrade, inspect history, and roll back.
- Read `helm get values`, `helm get manifest`, and `helm get hooks`, and say what each proves.
- Explain where Helm 3 stores release state and why there is no Tiller.
- Write a hook Job with the correct `hook`, `hook-weight` and `hook-delete-policy` annotations, and explain why the delete policy is required for idempotency.
- Package, sign, verify, and push a chart to both an HTTP repository and an OCI registry.
- Build a Kustomize base and overlay, apply a strategic-merge patch and a JSON6902 patch, and use a `configMapGenerator`.
- Explain why generator hashes cause rollouts, and what `disableNameSuffixHash: true` breaks.
- Explain why `commonLabels` / `includeSelectors: true` can break an existing Deployment.
- Diagnose: pending-upgrade lock, immutable-field failure, missing-CRD render failure, and the ownership-metadata adoption error.

---

## 12. References

**Exam objectives**
- LPI DevOps Tools Engineer, Exam 701 objectives — https://www.lpi.org/our-certifications/exam-701-objectives/

**Helm**
- Helm documentation index — https://helm.sh/docs/
- Charts (structure, `Chart.yaml`, dependencies, schema files) — https://helm.sh/docs/topics/charts/
- Chart Template Guide — https://helm.sh/docs/chart_template_guide/
- Built-in objects and template functions — https://helm.sh/docs/chart_template_guide/builtin_objects/ · https://helm.sh/docs/chart_template_guide/function_list/
- Chart hooks — https://helm.sh/docs/topics/charts_hooks/
- Chart tests — https://helm.sh/docs/topics/chart_tests/
- Library charts — https://helm.sh/docs/topics/library_charts/
- Chart repositories — https://helm.sh/docs/topics/chart_repository/
- OCI registries — https://helm.sh/docs/topics/registries/
- Provenance and integrity — https://helm.sh/docs/topics/provenance/
- Advanced topics (post-renderers, `lookup`, storage backends) — https://helm.sh/docs/topics/advanced/
- Custom Resource Definitions in charts — https://helm.sh/docs/chart_best_practices/custom_resource_definitions/
- Chart best practices — https://helm.sh/docs/chart_best_practices/
- `helm upgrade` reference (`--atomic`, `--reuse-values`, `--history-max`) — https://helm.sh/docs/helm/helm_upgrade/
- `helm rollback` reference — https://helm.sh/docs/helm/helm_rollback/
- `helm template` reference (`--api-versions`, `--show-only`, `--validate`) — https://helm.sh/docs/helm/helm_template/
- Changes since Helm 2 (three-way merge, release storage) — https://helm.sh/docs/faq/changes_since_helm2/
- Source (kind sorter, upgrade value logic) — https://github.com/helm/helm

**Kustomize**
- Kustomization file reference — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/
- Patches (`patches`, SMP, JSON6902) — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/patches/
- Generators (`configMapGenerator`, `secretGenerator`) — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/
- `labels` and `commonLabels` — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/labels/
- Components — https://kubectl.docs.kubernetes.io/guides/config_management/components/
- Declarative management with Kustomize — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Source — https://github.com/kubernetes-sigs/kustomize

**Kubernetes**
- Server-Side Apply and field management — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Declarative management with `kubectl apply` (three-way merge) — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- CustomResourceDefinitions — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Recommended labels — https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
- `kubectl` reference — https://kubernetes.io/docs/reference/kubectl/

**Distribution, signing, GitOps**
- Artifact Hub — https://artifacthub.io/
- OCI Distribution Specification — https://github.com/opencontainers/distribution-spec
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/
- Flux `HelmRelease` — https://fluxcd.io/flux/components/helm/helmreleases/
- Argo CD and Helm — https://argo-cd.readthedocs.io/en/stable/user-guide/helm/
- Operator Lifecycle Manager — https://olm.operatorframework.io/docs/
- kubeconform — https://github.com/yannh/kubeconform
- helm-diff plugin — https://github.com/databus23/helm-diff