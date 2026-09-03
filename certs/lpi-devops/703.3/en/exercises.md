# 703.3 Kubernetes Package Management — Guided Exercises

**LPI DevOps Tools Engineer · Exam 701-100 · Version 2.0.0 · Weight 3.33**

> Official objectives: <https://www.lpi.org/our-certifications/exam-701-objectives/>

These exercises are hands-on. You type every command, you read every output, and after each block you answer the verification questions before moving on. The answers are collapsed at the end — resist opening them early; the point is to predict the behaviour, then confirm it.

Everything runs against a disposable local cluster. Nothing here needs a cloud account, and nothing costs money.

---

## Lab 0 — Environment

### Steps

1. Create a throwaway cluster and confirm the control plane answers:

```bash
$ kind create cluster --name lpi703 --image kindest/node:v1.32.0
Creating cluster "lpi703" ...
 ✓ Ensuring node image (kindest/node:v1.32.0) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-lpi703"

$ kubectl get nodes
NAME                    STATUS   ROLES           AGE   VERSION
lpi703-control-plane    Ready    control-plane   41s   v1.32.0
```

2. Confirm the Helm client version. Everything below works on Helm **3.14 or newer**; flags that need a specific minimum are flagged inline.

```bash
$ helm version
version.BuildInfo{Version:"v3.17.1", GitCommit:"980d8ac1939e39138101364400756af2bdee1da5", GitTreeState:"clean", GoVersion:"go1.23.6"}
```

3. Create a working directory and a namespace for the labs:

```bash
$ mkdir -p ~/lpi703 && cd ~/lpi703
$ kubectl create namespace pkg
namespace/pkg created
```

4. Note that Helm 3 has **no cluster-side component**. Prove it:

```bash
$ kubectl get pods -A | grep -i tiller
$ echo $?
1
```

### Verification questions

- **Q1.** Helm 2 required `tiller`, a Deployment running in `kube-system` with broad RBAC. Helm 3 removed it. Where does the *authorisation* for `helm install` now come from, and what practical security consequence does that have in a multi-tenant cluster?
- **Q2.** `helm version` reports only a client version. What determines whether a chart you install will actually work on this cluster's API surface, and which two mechanisms let a chart author express that requirement?

---

## Exercise 1 — Chart anatomy: what a "package" actually is

### Steps

1. Scaffold a chart and inspect the layout:

```bash
$ helm create web
Creating web

$ find web -type f | sort
web/.helmignore
web/Chart.yaml
web/charts/.gitkeep          # empty in a fresh scaffold
web/templates/NOTES.txt
web/templates/_helpers.tpl
web/templates/deployment.yaml
web/templates/hpa.yaml
web/templates/ingress.yaml
web/templates/service.yaml
web/templates/serviceaccount.yaml
web/templates/tests/test-connection.yaml
web/values.yaml
```

2. Read the chart metadata:

```bash
$ cat web/Chart.yaml
apiVersion: v2
name: web
description: A Helm chart for Kubernetes
type: application
version: 0.1.0
appVersion: "1.16.0"
```

3. Edit `web/Chart.yaml` to make the two version fields tell different stories, and add a Kubernetes constraint:

```yaml
apiVersion: v2
name: web
description: Production reference web tier for LPI 703.3
type: application
version: 0.2.0          # the chart's own SemVer — bumped on every chart change
appVersion: "1.27.2"    # the version of the software being deployed
kubeVersion: ">=1.28.0-0"
maintainers:
  - name: platform-team
    email: platform@example.com
```

4. Ask Helm to show you what a consumer would see without installing anything:

```bash
$ helm show chart ./web
apiVersion: v2
appVersion: 1.27.2
description: Production reference web tier for LPI 703.3
kubeVersion: '>=1.28.0-0'
...

$ helm show values ./web | head -20
replicaCount: 1

image:
  repository: nginx
  pullPolicy: IfNotPresent
  # Overrides the image tag whose default is the chart appVersion.
  tag: ""
...
```

5. Create a chart that deliberately cannot be installed and observe the failure:

```bash
$ helm create common && sed -i 's/^type: application/type: library/' common/Chart.yaml
$ rm common/templates/*.yaml common/templates/NOTES.txt
$ helm install c ./common -n pkg
Error: INSTALLATION FAILED: library charts are not installable
```

### Verification questions

- **Q3.** A colleague bumps `appVersion` from `1.27.2` to `1.27.3` and pushes the chart to the repository without touching `version`. Consumers running `helm repo update && helm upgrade` see no change. Why? Which field is the *package* version in SemVer terms?
- **Q4.** `apiVersion: v2` in `Chart.yaml` is not the Kubernetes API version. What does it select, and what did the equivalent `apiVersion: v1` chart use instead of the `dependencies:` block?
- **Q5.** What is a `type: library` chart *for*, given that it cannot be installed? Name the mechanism a consuming chart uses to pull templates out of it.
- **Q6.** The scaffold's `values.yaml` ships `image.tag: ""`. Look at the rendered Deployment in the next exercise and explain what value ends up in the image reference — and why an empty default is safer than hard-coding `latest`.

---

## Exercise 2 — Render before you install: `template`, `lint`, `--dry-run`

### Steps

1. Render the chart entirely client-side and read the result:

```bash
$ helm template web ./web --namespace pkg | head -30
---
# Source: web/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: web
  labels:
    helm.sh/chart: web-0.2.0
    app.kubernetes.io/name: web
    app.kubernetes.io/instance: web
    app.kubernetes.io/version: "1.27.2"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true
---
# Source: web/templates/service.yaml
apiVersion: v1
kind: Service
...
```

2. Restrict the output to a single template — indispensable on charts that render 40 objects:

```bash
$ helm template web ./web --show-only templates/deployment.yaml \
    --set replicaCount=3 --set image.tag=1.27.2-alpine | grep -E 'replicas|image:'
  replicas: 3
          image: "nginx:1.27.2-alpine"
```

3. Lint it:

```bash
$ helm lint ./web
==> Linting ./web
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

4. Break a template on purpose and lint again:

```bash
$ sed -i 's/{{- if .Values.autoscaling.enabled }}/{{- if .Values.autoscaling.enabld }}/' web/templates/hpa.yaml
$ helm lint ./web
==> Linting ./web
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

5. That is the trap. Restore the file and instead break the *YAML shape*:

```bash
$ sed -i 's/{{- if .Values.autoscaling.enabld }}/{{- if .Values.autoscaling.enabled }}/' web/templates/hpa.yaml
$ cat >> web/templates/service.yaml <<'EOF'
  badIndent: true
EOF
$ helm lint ./web
==> Linting ./web
[INFO] Chart.yaml: icon is recommended
[ERROR] templates/: error validating "": error validating data: ValidationError(Service): unknown field "badIndent" in io.k8s.api.core.v1.Service

Error: 1 chart(s) linted, 1 chart(s) failed
```

6. Undo that, then compare the three "don't really install it" modes:

```bash
$ sed -i '/badIndent/d' web/templates/service.yaml

# (a) pure client-side render, no cluster contact at all
$ helm template web ./web >/dev/null && echo "no API server needed"
no API server needed

# (b) client dry-run: contacts the cluster for capabilities + name collision
$ helm install web ./web -n pkg --dry-run | head -6
NAME: web
LAST DEPLOYED: Thu Sep  3 10:14:22 2026
NAMESPACE: pkg
STATUS: pending-install
REVISION: 1
NOTES:

# (c) server dry-run: the API server validates and admission runs (Helm 3.13+)
$ helm install web ./web -n pkg --dry-run=server >/dev/null && echo "server accepted the objects"
server accepted the objects
```

7. Show what a rendered-but-invalid object looks like when only the server can catch it:

```bash
$ helm template web ./web --set resources.limits.memory=128 | grep -A3 resources:
$ helm install web ./web -n pkg --dry-run=server --set 'resources.limits.memory=128'
Error: INSTALLATION FAILED: unable to build kubernetes objects from release manifest: error validating "": error validating data: ValidationError(Deployment.spec.template.spec.containers[0].resources.limits.memory): invalid type for io.k8s.apimachinery.pkg.api.resource.Quantity: got "integer", expected "string"
```

### Verification questions

- **Q7.** Step 4 shows `helm lint` reporting success on a chart with a misspelled value reference (`.Values.autoscaling.enabld`). Explain precisely why the linter is blind to it, and state the Go template setting that would turn that silence into an error.
- **Q8.** Rank `helm template`, `helm install --dry-run`, and `helm install --dry-run=server` by how much they can prove about a chart. For each, name one class of defect it catches that the weaker one does not.
- **Q9.** Inside `helm template`, what do `.Capabilities.APIVersions` and `.Release.IsUpgrade` evaluate to, and what CI failure mode does that create for a chart that renders a `PodDisruptionBudget` only when `.Capabilities.APIVersions.Has "policy/v1"`?
- **Q10.** You have a chart with 60 templates and only need to eyeball the CronJob. Give the exact flag, and explain what happens if the file you name renders to nothing.

---

## Exercise 3 — Release lifecycle and where Helm keeps its state

### Steps

1. Install for real, waiting for readiness:

```bash
$ helm install web ./web -n pkg --create-namespace --wait --timeout 2m
NAME: web
LAST DEPLOYED: Thu Sep  3 10:19:41 2026
NAMESPACE: pkg
STATUS: deployed
REVISION: 1
NOTES:
1. Get the application URL by running these commands:
  export POD_NAME=$(kubectl get pods --namespace pkg -l "app.kubernetes.io/name=web,app.kubernetes.io/instance=web" -o jsonpath="{.items[0].metadata.name}")
  ...

$ helm list -n pkg
NAME  NAMESPACE  REVISION  UPDATED                                 STATUS    CHART      APP VERSION
web   pkg        1         2026-09-03 10:19:41.118203 -03:00 -03   deployed  web-0.2.0  1.27.2
```

2. Find the release state. It is not a file on your laptop:

```bash
$ kubectl get secret -n pkg -l owner=helm
NAME                        TYPE                 DATA   AGE
sh.helm.release.v1.web.v1   helm.sh/release.v1   1      38s

$ kubectl get secret -n pkg sh.helm.release.v1.web.v1 -o jsonpath='{.metadata.labels}' | tr ',' '\n'
{"modifiedAt":"1788440381"
"name":"web"
"owner":"helm"
"status":"deployed"
"version":"1"}
```

3. Decode it. The payload is base64 → gzip → JSON, wrapped in the Secret's own base64:

```bash
$ kubectl get secret -n pkg sh.helm.release.v1.web.v1 -o jsonpath='{.data.release}' \
  | base64 -d | base64 -d | gunzip | jq '{name, version, info: .info.status, chart: .chart.metadata.version, config}'
{
  "name": "web",
  "version": 1,
  "info": "deployed",
  "chart": "0.2.0",
  "config": null
}
```

4. Upgrade twice, so you have history to work with:

```bash
$ helm upgrade web ./web -n pkg --set replicaCount=3 --wait
Release "web" has been upgraded. Happy Helming!
NAME: web
LAST DEPLOYED: Thu Sep  3 10:22:03 2026
NAMESPACE: pkg
STATUS: deployed
REVISION: 2

$ helm upgrade web ./web -n pkg --set replicaCount=3 --set image.tag=1.29.9-does-not-exist \
    --wait --timeout 45s
Error: UPGRADE FAILED: context deadline exceeded

$ helm history web -n pkg
REVISION  UPDATED                   STATUS      CHART      APP VERSION  DESCRIPTION
1         Thu Sep  3 10:19:41 2026  superseded  web-0.2.0  1.27.2       Install complete
2         Thu Sep  3 10:22:03 2026  deployed    web-0.2.0  1.27.2       Upgrade complete
3         Thu Sep  3 10:23:30 2026  failed      web-0.2.0  1.27.2       Upgrade "web" failed: context deadline exceeded
```

5. Look at the damage the failed upgrade left behind:

```bash
$ kubectl get pods -n pkg
NAME                   READY   STATUS             RESTARTS   AGE
web-6d4bcbb7c5-2zqkl   1/1     Running            0          3m
web-6d4bcbb7c5-9wgtn   1/1     Running            0          3m
web-6d4bcbb7c5-hz4rv   1/1     Running            0          3m
web-7f9c98d4b8-tp7xk   0/1     ImagePullBackOff   0          70s
```

6. Roll back and confirm the release pointer moves forward, never backward:

```bash
$ helm rollback web 2 -n pkg --wait
Rollback was a success! Happy Helming!

$ helm history web -n pkg
REVISION  UPDATED                   STATUS      CHART      APP VERSION  DESCRIPTION
1         Thu Sep  3 10:19:41 2026  superseded  web-0.2.0  1.27.2       Install complete
2         Thu Sep  3 10:22:03 2026  superseded  web-0.2.0  1.27.2       Upgrade complete
3         Thu Sep  3 10:23:30 2026  failed      web-0.2.0  1.27.2       Upgrade "web" failed: context deadline exceeded
4         Thu Sep  3 10:25:12 2026  deployed    web-0.2.0  1.27.2       Rollback to 2
```

7. Repeat the bad upgrade the way a pipeline should do it:

```bash
$ helm upgrade web ./web -n pkg --set image.tag=1.29.9-does-not-exist \
    --atomic --wait --timeout 45s
Error: UPGRADE FAILED: context deadline exceeded
Error: release web failed, and has been rolled back due to atomic being set

$ helm list -n pkg
NAME  NAMESPACE  REVISION  UPDATED                                 STATUS    CHART      APP VERSION
web   pkg        6         2026-09-03 10:27:05.442901 -03:00 -03   deployed  web-0.2.0  1.27.2

$ kubectl get pods -n pkg --no-headers | wc -l
3
```

8. Inspect what Helm believes it owns:

```bash
$ helm get manifest web -n pkg | grep -c '^kind:'
4
$ helm get values web -n pkg
USER-SUPPLIED VALUES:
replicaCount: 3
$ helm get metadata web -n pkg          # Helm 3.13+
NAME: web
CHART: web
VERSION: 0.2.0
APP_VERSION: 1.27.2
NAMESPACE: pkg
REVISION: 6
STATUS: deployed
DEPLOYED_AT: 2026-09-03T10:27:05-03:00
```

### Verification questions

- **Q11.** Release state lives in Secrets in the release namespace. Give two operational consequences: one for a user who has `get secrets` in that namespace, and one for what happens to `helm list` if someone runs `kubectl delete secret -l owner=helm -n pkg` while the workloads keep running.
- **Q12.** After the rollback in step 6, the history shows revision 4 as `deployed` and revision 2 as `superseded`. Why does Helm create a *new* revision instead of reactivating revision 2, and what does that give you that an in-place restore would not?
- **Q13.** In step 4, the failed upgrade left three healthy old Pods and one broken new Pod, and the release status was `failed` — yet nothing was undone. Contrast that with step 7. Name the flag, state exactly what it implies about `--wait`, and give one reason a team might still *not* want it on every upgrade.
- **Q14.** `helm get manifest` and `kubectl get -o yaml` can disagree. Name two distinct causes of that divergence, and say which command Helm's own upgrade logic consults.
- **Q15.** Set `HELM_DRIVER=configmap` and re-run `helm list -n pkg`. Predict the output before running it, then explain the one production reason someone would deliberately choose the `secret` driver over `configmap` — and the reason neither is enough for very large releases.

---

## Exercise 4 — Values: precedence, types and schema validation

### Steps

1. Build a layered configuration exactly as a real pipeline does — chart defaults, then an environment file, then a per-release override, then a flag:

```bash
$ cat > prod.yaml <<'EOF'
replicaCount: 4
image:
  tag: "1.27.2"
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi
EOF

$ cat > canary.yaml <<'EOF'
replicaCount: 1
podAnnotations:
  release-channel: canary
EOF

$ helm upgrade web ./web -n pkg -f prod.yaml -f canary.yaml --set replicaCount=2 --wait
Release "web" has been upgraded. Happy Helming!
```

2. Ask Helm which value actually won, and where the rest came from:

```bash
$ helm get values web -n pkg
USER-SUPPLIED VALUES:
image:
  tag: 1.27.2
podAnnotations:
  release-channel: canary
replicaCount: 2
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi

$ helm get values web -n pkg --all | grep -A2 serviceAccount
serviceAccount:
  annotations: {}
  automount: true
```

3. Demonstrate the type trap in `--set`:

```bash
$ helm template web ./web --set image.tag=1.27 --show-only templates/deployment.yaml | grep image:
          image: "nginx:1.27"

$ helm template web ./web --set podAnnotations.build=00123 --show-only templates/deployment.yaml | grep -A2 annotations
      annotations:
        build: "123"

$ helm template web ./web --set-string podAnnotations.build=00123 --show-only templates/deployment.yaml | grep -A2 annotations
      annotations:
        build: "00123"
```

4. Demonstrate the *merge* trap — maps merge, lists replace:

```bash
$ cat > lists.yaml <<'EOF'
tolerations:
  - key: workload
    operator: Equal
    value: web
    effect: NoSchedule
  - key: zone
    operator: Exists
    effect: NoSchedule
EOF

$ helm template web ./web -f lists.yaml --set 'tolerations[0].key=only-this' \
    --show-only templates/deployment.yaml | grep -A6 tolerations:
      tolerations:
        - effect: NoSchedule
          key: only-this
          operator: Equal
          value: web
        - effect: NoSchedule
          key: zone
          operator: Exists
```

5. Now add a contract, so bad values fail before anything reaches the API server:

```bash
$ cat > web/values.schema.json <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["replicaCount", "image"],
  "properties": {
    "replicaCount": { "type": "integer", "minimum": 1, "maximum": 10 },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": {
        "repository": { "type": "string", "minLength": 1 },
        "tag": { "type": "string" },
        "pullPolicy": { "enum": ["Always", "IfNotPresent", "Never"] }
      }
    }
  }
}
EOF

$ helm template web ./web --set replicaCount=40
Error: values don't meet the specifications of the schema(s) in the following chart(s):
web:
- replicaCount: Must be less than or equal to 10

$ helm template web ./web --set image.pullPolicy=ifnotpresent
Error: values don't meet the specifications of the schema(s) in the following chart(s):
web:
- image.pullPolicy: image.pullPolicy must be one of the following: "Always", "IfNotPresent", "Never"

$ helm template web ./web --set image.tag=1.27 >/dev/null
Error: values don't meet the specifications of the schema(s) in the following chart(s):
web:
- image.tag: Invalid type. Expected: string, given: number
```

6. Fix the last one and confirm the schema now passes:

```bash
$ helm template web ./web --set-string image.tag=1.27 >/dev/null && echo OK
OK
```

7. Examine how upgrades treat previously supplied values:

```bash
$ helm upgrade web ./web -n pkg --set replicaCount=2 --wait >/dev/null
$ helm get values web -n pkg
USER-SUPPLIED VALUES:
replicaCount: 2

$ helm upgrade web ./web -n pkg -f prod.yaml --wait >/dev/null
$ helm upgrade web ./web -n pkg --set podAnnotations.owner=sre --reuse-values --wait >/dev/null
$ helm get values web -n pkg | head -8
USER-SUPPLIED VALUES:
image:
  tag: 1.27.2
podAnnotations:
  owner: sre
replicaCount: 4
```

### Verification questions

- **Q16.** Write the full precedence order for: chart `values.yaml`, a parent chart overriding a subchart, `-f a.yaml`, `-f b.yaml`, `--set`, `--set-string`. Which of these silently *replaces* rather than merges?
- **Q17.** In step 3, `--set podAnnotations.build=00123` produced `"123"`. Explain the two separate conversions that happen — one in Helm's `--set` parser and one when the value is emitted into YAML — and name the two flags that avoid each.
- **Q18.** In step 4, `--set 'tolerations[0].key=only-this'` did not delete the second toleration but did mutate the first. Reconcile that with "lists replace, maps merge", and state what `--set tolerations=null` would do.
- **Q19.** `values.schema.json` rejected `replicaCount=40` during `helm template`, with no cluster involved. List every Helm subcommand that enforces the schema, and explain why schema validation is strictly stronger than "the API server will reject it anyway".
- **Q20.** A pipeline uses `--reuse-values` on every upgrade. Six months later nobody can explain why a removed value is still active. Describe the failure, and name the two flags (one classic, one added in Helm 3.14) that give deterministic behaviour instead.

---

## Exercise 5 — Template mechanics you will actually debug

### Steps

1. Read the scaffold's named templates:

```bash
$ sed -n '1,40p' web/templates/_helpers.tpl
{{/*
Expand the name of the chart.
*/}}
{{- define "web.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "web.fullname" -}}
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
```

2. Add a ConfigMap that exercises the idioms that break in production — `toYaml`/`nindent`, `required`, `tpl`, and `default`:

```bash
$ cat > web/templates/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "web.fullname" . }}-config
  labels:
    {{- include "web.labels" . | nindent 4 }}
data:
  ENVIRONMENT: {{ required "config.environment is mandatory" .Values.config.environment | quote }}
  LOG_LEVEL: {{ .Values.config.logLevel | default "info" | quote }}
  BACKEND_URL: {{ tpl .Values.config.backendUrl . | quote }}
  extra.yaml: |
    {{- toYaml .Values.config.extra | nindent 4 }}
EOF

$ cat >> web/values.yaml <<'EOF'

config:
  environment: ""
  logLevel: ""
  backendUrl: "http://{{ .Release.Name }}-api.{{ .Release.Namespace }}.svc.cluster.local:8080"
  extra:
    timeouts:
      read: 30s
      write: 30s
EOF
```

3. Trigger the guard, then satisfy it:

```bash
$ helm template web ./web --show-only templates/configmap.yaml
Error: execution error at (web/templates/configmap.yaml:8:23): config.environment is mandatory

$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/configmap.yaml
---
# Source: web/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
  labels:
    helm.sh/chart: web-0.2.0
    app.kubernetes.io/name: web
    app.kubernetes.io/instance: web
    app.kubernetes.io/version: "1.27.2"
    app.kubernetes.io/managed-by: Helm
data:
  ENVIRONMENT: "prod"
  LOG_LEVEL: "info"
  BACKEND_URL: "http://web-api.pkg.svc.cluster.local:8080"
  extra.yaml: |
    timeouts:
      read: 30s
      write: 30s
```

4. Break the indentation deliberately — the single most common Helm bug:

```bash
$ sed -i 's/toYaml .Values.config.extra | nindent 4/toYaml .Values.config.extra | indent 4/' web/templates/configmap.yaml
$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/configmap.yaml | tail -5
  extra.yaml: |
        timeouts:
      read: 30s
      write: 30s
```

5. Restore it, then wire the ConfigMap into the Deployment so config changes actually restart Pods:

```bash
$ sed -i 's/toYaml .Values.config.extra | indent 4/toYaml .Values.config.extra | nindent 4/' web/templates/configmap.yaml
$ sed -i 's|^      annotations:|      annotations:\n        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . \| sha256sum }}|' web/templates/deployment.yaml

$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/deployment.yaml | grep checksum
        checksum/config: 4bd0a2b8b3f2eea8d1f5f0a1b1d5a10d0c2c1b1e2f5a9f8f4a6c2d8e7b3f1a0c

$ helm template web ./web -n pkg --set config.environment=prod --set config.logLevel=debug \
    --show-only templates/deployment.yaml | grep checksum
        checksum/config: 9a2f7d1c4e8b0a3f6c5d2e1b8f7a4c9d0e3b6a1f2c5d8e7b4a9f0c3d6e1b8a2f
```

6. Explore cluster-aware rendering with `lookup` — the pattern for not regenerating secrets on every upgrade:

```bash
$ cat > web/templates/secret.yaml <<'EOF'
{{- $name := printf "%s-db" (include "web.fullname" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name -}}
{{- $pw := "" -}}
{{- if $existing -}}
{{- $pw = index $existing.data "password" | b64dec -}}
{{- else -}}
{{- $pw = randAlphaNum 24 -}}
{{- end }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}
type: Opaque
data:
  password: {{ $pw | b64enc | quote }}
EOF

$ helm upgrade web ./web -n pkg --set config.environment=prod --wait >/dev/null
$ kubectl get secret -n pkg web-db -o jsonpath='{.data.password}' | base64 -d; echo
Xr7kQm2ZpL9vT4bNc8sHwJ1e

$ helm upgrade web ./web -n pkg --set config.environment=prod --wait >/dev/null
$ kubectl get secret -n pkg web-db -o jsonpath='{.data.password}' | base64 -d; echo
Xr7kQm2ZpL9vT4bNc8sHwJ1e

$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/secret.yaml | grep password
  password: "d0FyMmtMOXBUN3ZOYzhzSHdKMWU="
```

7. Inspect the built-in objects available to every template:

```bash
$ cat > /tmp/builtins.tpl <<'EOF'
{{- printf "release=%s ns=%s isInstall=%v isUpgrade=%v revision=%d" .Release.Name .Release.Namespace .Release.IsInstall .Release.IsUpgrade (int .Release.Revision) }}
{{ printf "kube=%s major=%s minor=%s" .Capabilities.KubeVersion.Version .Capabilities.KubeVersion.Major .Capabilities.KubeVersion.Minor }}
{{ printf "hasAutoscalingV2=%v" (.Capabilities.APIVersions.Has "autoscaling/v2") }}
EOF
$ cp /tmp/builtins.tpl web/templates/zz-debug.yaml
$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/zz-debug.yaml
---
# Source: web/templates/zz-debug.yaml
release=web ns=pkg isInstall=true isUpgrade=false revision=1
kube=v1.32.0 major=1 minor=32
hasAutoscalingV2=true
$ rm web/templates/zz-debug.yaml
```

### Verification questions

- **Q21.** `include "web.labels" . | nindent 4` appears everywhere in the scaffold, but the Helm docs also define `template`. Give the one capability `include` has that `template` does not, and explain why that difference makes `template` unusable in the line above.
- **Q22.** Step 4 produced YAML where the first line was indented 8 spaces and the rest 4. Explain the mechanical difference between `indent` and `nindent` that causes exactly that shape.
- **Q23.** The `checksum/config` annotation changed when `logLevel` changed. What concrete Kubernetes behaviour does that trigger, and what happens *without* the annotation when you change a ConfigMap that is mounted as a volume versus consumed via `envFrom`?
- **Q24.** In step 6, `helm template` printed a *different* password than the one stored in the cluster. Explain why, and describe the production accident this causes if a CI job renders manifests with `helm template` and applies them with `kubectl apply`.
- **Q25.** `required` fires at render time; `values.schema.json` fires before render. A value must be a non-empty string matching `^[a-z0-9-]+$`. Which mechanism do you choose, and why is `required` alone insufficient here?

---

## Exercise 6 — Dependencies, conditions, aliases and globals

### Steps

1. Build a small umbrella chart over two local subcharts:

```bash
$ helm create cache >/dev/null
$ mkdir platform && cd platform
$ cat > Chart.yaml <<'EOF'
apiVersion: v2
name: platform
description: Umbrella chart for the LPI 703.3 lab
type: application
version: 1.0.0
appVersion: "2026.09"
dependencies:
  - name: web
    version: "0.2.0"
    repository: "file://../web"
  - name: cache
    version: "0.1.0"
    repository: "file://../cache"
    alias: sessioncache
    condition: sessioncache.enabled
    tags:
      - stateful
EOF
$ mkdir -p templates && cat > values.yaml <<'EOF'
global:
  imageRegistry: registry.example.com
  environment: prod

web:
  replicaCount: 3
  config:
    environment: prod

sessioncache:
  enabled: false
  replicaCount: 1
EOF
```

2. Resolve the dependencies and read what Helm wrote:

```bash
$ helm dependency update .
Saving 2 charts
Deleting outdated charts

$ ls charts/
cache-0.1.0.tgz  web-0.2.0.tgz

$ cat Chart.lock
dependencies:
- name: web
  repository: file://../web
  version: 0.2.0
- name: cache
  repository: file://../cache
  version: 0.1.0
digest: sha256:4d61b0e3c7a1e4c9f1a7d2b8e5c0f3a6d9b2e8c1f4a7d0b3e6c9f2a5d8b1e4c7
generated: "2026-09-03T10:41:19.884215-03:00"
```

3. Confirm the condition works, and confirm the alias trap:

```bash
$ helm template plat . -n pkg | grep -c 'kind: Deployment'
1

$ helm template plat . -n pkg --set sessioncache.enabled=true | grep -c 'kind: Deployment'
2

# The trap: the ORIGINAL chart name no longer controls anything
$ helm template plat . -n pkg --set cache.enabled=true | grep -c 'kind: Deployment'
1
```

4. Show that a subchart's own name still governs its resource names unless overridden:

```bash
$ helm template plat . -n pkg --set sessioncache.enabled=true | grep -E '^  name: plat'
  name: plat-web
  name: plat-cache
```

5. Prove global value propagation, and prove that ordinary values do *not* propagate:

```bash
$ cat > ../web/templates/zz-globals.yaml <<'EOF'
{{- printf "web sees registry=%v environment=%v topLevel=%v" .Values.global.imageRegistry .Values.global.environment (.Values.someTopLevel | default "<nil>") }}
EOF
$ helm dependency update . >/dev/null
$ helm template plat . -n pkg --set someTopLevel=xyz --show-only charts/web/templates/zz-globals.yaml
---
# Source: platform/charts/web/templates/zz-globals.yaml
web sees registry=registry.example.com environment=prod topLevel=<nil>
```

6. Reproduce a build from the lock file, the way CI must:

```bash
$ rm -rf charts/
$ helm dependency build .
Saving 2 charts
Deleting outdated charts

$ helm dependency list .
NAME    VERSION  REPOSITORY          STATUS
web     0.2.0    file://../web       unpacked
cache   0.1.0    file://../cache     unpacked
```

7. Break reproducibility on purpose and watch `build` refuse:

```bash
$ sed -i 's/version: "0.2.0"/version: "0.3.0"/' Chart.yaml
$ helm dependency build .
Error: the lock file (Chart.lock) is out of sync with the dependencies file (Chart.yaml). Please update the dependencies
$ sed -i 's/version: "0.3.0"/version: "0.2.0"/' Chart.yaml && helm dependency build . >/dev/null
$ rm ../web/templates/zz-globals.yaml && helm dependency update . >/dev/null && cd ..
```

### Verification questions

- **Q26.** `helm dependency update` and `helm dependency build` both populate `charts/`. State exactly which one reads `Chart.lock`, which one writes it, and which one belongs in a CI pipeline — with the reason.
- **Q27.** With `alias: sessioncache`, `--set cache.enabled=true` did nothing. Explain the rule, and write the `condition:` line you would need if the same chart were also included a second time under alias `pagecache`.
- **Q28.** A subchart reads `.Values.image.repository`. From the umbrella chart, give the two different ways to set it — one through the subchart's key and one through `global` — and state which one the subchart author must have explicitly supported.
- **Q29.** `charts/` now contains committed `.tgz` files. Argue both sides: what do you gain by committing them (vendoring), and what do you gain by committing only `Chart.lock`? Which is required for an air-gapped build?
- **Q30.** A subchart ships a CRD in `crds/`. The umbrella chart is upgraded with a newer subchart whose CRD gained a field. Predict what Helm does, and state the operational procedure that is actually required.

---

## Exercise 7 — Repositories: package, index, HTTP, OCI and provenance

### Steps

1. Package the chart and inspect the artifact:

```bash
$ cd ~/lpi703
$ helm package web
Successfully packaged chart and saved it to: /home/user/lpi703/web-0.2.0.tgz

$ tar tzf web-0.2.0.tgz | head
web/Chart.yaml
web/values.yaml
web/values.schema.json
web/templates/NOTES.txt
web/templates/_helpers.tpl
web/templates/configmap.yaml
web/templates/deployment.yaml
...
```

2. Confirm `.helmignore` is doing its job:

```bash
$ echo "secret-notes.txt" >> web/.helmignore
$ echo "do not ship me" > web/secret-notes.txt
$ helm package web >/dev/null && tar tzf web-0.2.0.tgz | grep -c secret-notes
0
```

3. Build a classic HTTP chart repository — an `index.yaml` plus tarballs, nothing more:

```bash
$ mkdir -p repo && mv web-0.2.0.tgz repo/
$ helm package cache -d repo/ >/dev/null
$ helm repo index repo/ --url http://127.0.0.1:8879
$ head -25 repo/index.yaml
apiVersion: v1
entries:
  cache:
  - apiVersion: v2
    appVersion: 1.16.0
    created: "2026-09-03T10:52:44.109827-03:00"
    description: A Helm chart for Kubernetes
    digest: 2f1e7c9d4b8a0e3f6c5d2b1a8f7e4c9d0b3a6f1e2c5d8b7a4e9f0c3d6b1a8e2f
    name: cache
    type: application
    urls:
    - http://127.0.0.1:8879/cache-0.1.0.tgz
    version: 0.1.0
  web:
  - apiVersion: v2
    appVersion: 1.27.2
    created: "2026-09-03T10:52:44.110412-03:00"
    ...
generated: "2026-09-03T10:52:44.108991-03:00"
```

4. Serve it and consume it as a client would:

```bash
$ (cd repo && python3 -m http.server 8879 >/tmp/repo.log 2>&1 &)
$ helm repo add lpilab http://127.0.0.1:8879
"lpilab" has been added to your repositories

$ helm repo update lpilab
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "lpilab" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm search repo lpilab
NAME          CHART VERSION  APP VERSION  DESCRIPTION
lpilab/cache  0.1.0          1.16.0       A Helm chart for Kubernetes
lpilab/web    0.2.0          1.27.2       Production reference web tier for LPI 703.3

$ helm install fromrepo lpilab/web -n pkg --set config.environment=prod --wait >/dev/null
$ helm list -n pkg --filter fromrepo
NAME      NAMESPACE  REVISION  STATUS    CHART      APP VERSION
fromrepo  pkg        1         deployed  web-0.2.0  1.27.2
```

5. Publish a second version and observe that clients do not see it until they refresh:

```bash
$ sed -i 's/^version: 0.2.0/version: 0.3.0/' web/Chart.yaml
$ helm package web -d repo/ >/dev/null
$ helm repo index repo/ --url http://127.0.0.1:8879 --merge repo/index.yaml

$ helm search repo lpilab/web --versions
NAME        CHART VERSION  APP VERSION  DESCRIPTION
lpilab/web  0.2.0          1.27.2       Production reference web tier for LPI 703.3

$ helm repo update lpilab >/dev/null && helm search repo lpilab/web --versions
NAME        CHART VERSION  APP VERSION  DESCRIPTION
lpilab/web  0.3.0          1.27.2       Production reference web tier for LPI 703.3
lpilab/web  0.2.0          1.27.2       Production reference web tier for LPI 703.3
```

6. Pull without installing — the auditing move before you trust a third-party chart:

```bash
$ helm pull lpilab/web --version 0.3.0 --untar --untardir /tmp/audit
$ diff -r /tmp/audit/web web >/dev/null && echo "identical"
identical
```

7. Now do the same with an OCI registry, which is where charts live in 2026:

```bash
$ docker run -d --name lpireg -p 5000:5000 registry:2 >/dev/null
$ helm push repo/web-0.3.0.tgz oci://localhost:5000/charts
Pushed: localhost:5000/charts/web:0.3.0
Digest: sha256:8c1f0a5d2e7b4c9a6f3d0b8e5c2a1f7d4b9e6c3a0f8d5b2e7c4a1f9d6b3e0c8a

$ helm show chart oci://localhost:5000/charts/web --version 0.3.0 | head -4
apiVersion: v2
appVersion: 1.27.2
description: Production reference web tier for LPI 703.3
kubeVersion: '>=1.28.0-0'

$ helm install oci-web oci://localhost:5000/charts/web --version 0.3.0 \
    -n pkg --set config.environment=prod --wait >/dev/null
$ helm list -n pkg --filter oci-web
NAME     NAMESPACE  REVISION  STATUS    CHART      APP VERSION
oci-web  pkg        1         deployed  web-0.3.0  1.27.2
```

8. Sign a chart and verify it. Note the GnuPG format trap:

```bash
$ gpg --quick-generate-key "LPI Lab <lab@example.com>" default default never
$ gpg --export-secret-keys > ~/.gnupg/secring.gpg     # Helm needs the legacy keyring format

$ helm package web --sign --key 'LPI Lab' --keyring ~/.gnupg/secring.gpg -d repo/
Successfully packaged chart and saved it to: /home/user/lpi703/repo/web-0.3.0.tgz

$ cat repo/web-0.3.0.tgz.prov | head -12
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

apiVersion: v2
appVersion: 1.27.2
description: Production reference web tier for LPI 703.3
...
files:
  web-0.3.0.tgz: sha256:5f2c1a8d...
-----BEGIN PGP SIGNATURE-----
...

$ gpg --export > ~/.gnupg/pubring.gpg
$ helm verify repo/web-0.3.0.tgz --keyring ~/.gnupg/pubring.gpg
Signed by: LPI Lab <lab@example.com>
Using Key With Fingerprint: 9C1A0F4B8D2E7A6C3F5B0D9E8C2A1F7D4B6E3C09
Chart Hash Verified: sha256:5f2c1a8d...

$ printf '\0' >> repo/web-0.3.0.tgz
$ helm verify repo/web-0.3.0.tgz --keyring ~/.gnupg/pubring.gpg
Error: sha256 hash of web-0.3.0.tgz does not match the value in the provenance file
```

### Verification questions

- **Q31.** A chart repository is "just an HTTP server". List the minimum set of things it must serve, and explain why `helm repo add` of a repository with 400 charts is instant while `helm install` of one of them makes a second request.
- **Q32.** In step 5, `helm search repo` showed the stale version until `helm repo update` ran. Where does that stale data live on disk, and what is the exam-relevant difference between `helm search repo` and `helm search hub`?
- **Q33.** Compare a classic HTTP repository with an OCI registry on three axes: how versions are discovered, how authentication works, and what `helm search repo` can do for each. What is the practical consequence of the third?
- **Q34.** Provenance verification failed after appending one byte. Explain what the `.prov` file contains, why `--verify` on `helm install` protects against a compromised *mirror* but not against a compromised *chart author*, and where the public key must be for CI to check it.
- **Q35.** You must guarantee a build produced today can be reproduced byte-for-byte in two years, with the upstream repository offline. Give the concrete artifacts you archive and the exact commands a future engineer runs.

---

## Exercise 8 — Hooks, CRDs and chart tests

### Steps

1. Add a pre-upgrade migration Job and a post-install notifier:

```bash
$ cat > web/templates/migrate-job.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "web.fullname" . }}-migrate
  labels:
    {{- include "web.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 0
  template:
    metadata:
      name: {{ include "web.fullname" . }}-migrate
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: busybox:1.36
          command: ["sh", "-c", "echo 'applying schema {{ .Chart.AppVersion }}'; sleep 5; echo done"]
EOF

$ cat > web/templates/prewarm-job.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "web.fullname" . }}-prewarm
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: prewarm
          image: busybox:1.36
          command: ["sh", "-c", "echo warming {{ include \"web.fullname\" . }}"]
EOF
```

2. Install a fresh release and watch the ordering:

```bash
$ helm install hooked ./web -n pkg --set config.environment=prod --wait --timeout 3m
NAME: hooked
LAST DEPLOYED: Thu Sep  3 11:05:12 2026
NAMESPACE: pkg
STATUS: deployed
REVISION: 1

$ kubectl get events -n pkg --sort-by=.lastTimestamp | grep -E 'hooked-(migrate|prewarm)|hooked-[0-9a-f]{9,}' | head
0s   Normal   SuccessfulCreate   job/hooked-migrate     Created pod: hooked-migrate-x7k2p
0s   Normal   Completed          job/hooked-migrate     Job completed
0s   Normal   ScalingReplicaSet  deployment/hooked      Scaled up replica set hooked-6d4bcbb7c5 to 1
0s   Normal   SuccessfulCreate   job/hooked-prewarm     Created pod: hooked-prewarm-m9d4t
```

3. Confirm hooks are not part of the release manifest:

```bash
$ helm get manifest hooked -n pkg | grep -c 'kind: Job'
0
$ helm get hooks hooked -n pkg | grep -E '^kind:|helm.sh/hook:'
    "helm.sh/hook": pre-install,pre-upgrade
kind: Job
    "helm.sh/hook": post-install,post-upgrade
kind: Job
    "helm.sh/hook": test
kind: Pod
```

4. Make a hook fail and observe what Helm does with the release:

```bash
$ sed -i 's|echo .applying schema.*done|exit 1|' web/templates/migrate-job.yaml
$ helm upgrade hooked ./web -n pkg --set config.environment=prod --wait --timeout 90s
Error: UPGRADE FAILED: pre-upgrade hooks failed: 1 error occurred:
	* job hooked-migrate failed: BackoffLimitExceeded

$ helm history hooked -n pkg
REVISION  UPDATED                   STATUS      CHART      APP VERSION  DESCRIPTION
1         Thu Sep  3 11:05:12 2026  deployed    web-0.3.0  1.27.2       Install complete
2         Thu Sep  3 11:09:44 2026  failed      web-0.3.0  1.27.2       pre-upgrade hooks failed: ...

$ kubectl get job -n pkg hooked-migrate
NAME             STATUS     COMPLETIONS   DURATION   AGE
hooked-migrate   Failed     0/1           68s        68s
```

5. Restore the hook, then run the chart's tests:

```bash
$ sed -i 's|exit 1|echo "applying schema {{ .Chart.AppVersion }}"; sleep 5; echo done|' web/templates/migrate-job.yaml
$ helm upgrade hooked ./web -n pkg --set config.environment=prod --wait >/dev/null

$ cat web/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "web.fullname" . }}-test-connection"
  labels:
    {{- include "web.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['{{ include "web.fullname" . }}:{{ .Values.service.port }}']
  restartPolicy: Never

$ helm test hooked -n pkg --logs
NAME: hooked
LAST DEPLOYED: Thu Sep  3 11:12:30 2026
NAMESPACE: pkg
STATUS: deployed
REVISION: 3
TEST SUITE:     hooked-test-connection
Last Started:   Thu Sep  3 11:13:02 2026
Last Completed: Thu Sep  3 11:13:09 2026
Phase:          Succeeded

POD LOGS: hooked-test-connection
Connecting to hooked:80 (10.96.184.22:80)
saving to 'index.html'
index.html           100% |********************************|   615  0:00:00 ETA
```

6. Add a CRD the way Helm expects, and observe the asymmetry:

```bash
$ mkdir -p web/crds && cat > web/crds/widget.yaml <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.lab.lpi.org
spec:
  group: lab.lpi.org
  names:
    kind: Widget
    listKind: WidgetList
    plural: widgets
    singular: widget
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                size: { type: string }
EOF

$ helm install crdtest ./web -n pkg --set config.environment=prod --wait >/dev/null
$ kubectl get crd widgets.lab.lpi.org
NAME                  CREATED AT
widgets.lab.lpi.org   2026-09-03T14:16:02Z

$ helm get manifest crdtest -n pkg | grep -c CustomResourceDefinition
0

$ sed -i 's/size: { type: string }/size: { type: string }\n                color: { type: string }/' web/crds/widget.yaml
$ helm upgrade crdtest ./web -n pkg --set config.environment=prod --wait >/dev/null
$ kubectl get crd widgets.lab.lpi.org -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties}'; echo
{"size":{"type":"string"}}

$ helm uninstall crdtest -n pkg >/dev/null
$ kubectl get crd widgets.lab.lpi.org --no-headers
widgets.lab.lpi.org   2026-09-03T14:16:02Z
```

### Verification questions

- **Q36.** List the hook events Helm fires around an upgrade, in order, and place `--wait` correctly relative to them. Which hooks run if `helm upgrade` fails during resource application?
- **Q37.** `helm get manifest` showed zero Jobs but `helm get hooks` showed two. Explain the ownership consequence: what happens to a `hook-succeeded` hook resource on `helm uninstall`, and what happens to one with no `hook-delete-policy` at all?
- **Q38.** `helm.sh/hook-weight: "-5"` is quoted. What breaks if you write `-5` unquoted, and what is the tie-breaking order for two hooks with the same weight?
- **Q39.** Step 6 showed a CRD installed on first install, *not* updated on upgrade, and *not* removed on uninstall. Give the design reason for all three behaviours, and describe the two chart-authoring strategies teams use to work around the upgrade gap — with the risk of each.
- **Q40.** `helm test` succeeded here, but a test Pod that hangs will block a pipeline. Name the flag that bounds it, and explain why chart tests are hooks rather than ordinary templates.

---

## Exercise 9 — Production diagnostics

### Steps

1. Create drift by hand, then let Helm correct it:

```bash
$ helm upgrade web ./web -n pkg --set config.environment=prod --set replicaCount=3 --wait >/dev/null
$ kubectl scale deployment web -n pkg --replicas=0
deployment.apps/web scaled
$ kubectl get deploy web -n pkg
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    0/0     0            0           54m

$ helm upgrade web ./web -n pkg --set config.environment=prod --set replicaCount=3 --wait >/dev/null
$ kubectl get deploy web -n pkg
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    3/3     3            3           55m
```

2. Add a field by hand that the chart does not manage, and see it survive:

```bash
$ kubectl annotate deployment web -n pkg observed-by=sre-oncall
deployment.apps/web annotated
$ helm upgrade web ./web -n pkg --set config.environment=prod --set replicaCount=3 --wait >/dev/null
$ kubectl get deploy web -n pkg -o jsonpath='{.metadata.annotations.observed-by}'; echo
sre-oncall
```

3. Preview an upgrade as a diff instead of a wall of YAML:

```bash
$ helm plugin install https://github.com/databus23/helm-diff
Installed plugin: diff

$ helm diff upgrade web ./web -n pkg --set config.environment=prod --set replicaCount=5
pkg, web, Deployment (apps) has changed:
  ...
  spec:
-   replicas: 3
+   replicas: 5
    selector:
  ...
```

4. Manufacture a stuck release — the incident every Helm operator eventually meets:

```bash
$ helm upgrade web ./web -n pkg --set config.environment=prod \
    --set image.tag=1.29.9-does-not-exist --wait --timeout 10m &
$ sleep 12 && kill %1
$ helm list -n pkg --filter '^web$'
NAME  NAMESPACE  REVISION  UPDATED                                 STATUS           CHART      APP VERSION
web   pkg        9         2026-09-03 11:31:02.771 -03:00 -03      pending-upgrade  web-0.3.0  1.27.2

$ helm upgrade web ./web -n pkg --set config.environment=prod --wait
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

5. Resolve it — first the supported way, then the escape hatch:

```bash
$ helm rollback web -n pkg --wait
Rollback was a success! Happy Helming!

# If rollback is also refused, the release pointer must be moved by hand:
$ kubectl get secret -n pkg -l owner=helm,name=web --sort-by=.metadata.name -o name | tail -3
secret/sh.helm.release.v1.web.v8
secret/sh.helm.release.v1.web.v9
secret/sh.helm.release.v1.web.v10
$ kubectl delete secret -n pkg sh.helm.release.v1.web.v9      # the pending revision only
$ helm list -n pkg --filter '^web$'
NAME  NAMESPACE  REVISION  UPDATED                                 STATUS    CHART      APP VERSION
web   pkg        10        2026-09-03 11:33:47.220 -03:00 -03      deployed  web-0.3.0  1.27.2
```

6. Understand `--force` before someone hands it to you as a fix:

```bash
$ kubectl get pods -n pkg -l app.kubernetes.io/instance=web -o name | wc -l
3
$ helm upgrade web ./web -n pkg --set config.environment=prod --force --wait
Release "web" has been upgraded. Happy Helming!
$ kubectl get svc web -n pkg -o jsonpath='{.spec.clusterIP}'; echo
10.96.184.22
```

7. Prune orphaned history and confirm uninstall semantics:

```bash
$ helm history web -n pkg | wc -l
11
$ helm upgrade web ./web -n pkg --set config.environment=prod --history-max 5 --wait >/dev/null
$ helm history web -n pkg | wc -l
6

$ helm uninstall fromrepo -n pkg --keep-history
release "fromrepo" uninstalled
$ helm list -n pkg --uninstalled
NAME      NAMESPACE  REVISION  UPDATED                              STATUS      CHART      APP VERSION
fromrepo  pkg        1         2026-09-03 10:55:11.02 -03:00 -03    uninstalled web-0.2.0  1.27.2
$ helm rollback fromrepo 1 -n pkg --wait
Rollback was a success! Happy Helming!
```

### Verification questions

- **Q41.** Step 1 reset `replicas` from 0 back to 3; step 2 left a hand-added annotation alone. Name the patch strategy Helm 3 uses, state the three inputs it consumes, and derive both outcomes from it.
- **Q42.** Given step 1's behaviour, explain the concrete production hazard of a chart that hard-codes `spec.replicas` while an HPA manages the same Deployment — and give the exact chart construct the scaffold uses to avoid it.
- **Q43.** A release is stuck in `pending-upgrade` and `helm rollback` refuses. Explain what that status *means* in the storage backend, why deleting the newest release Secret works, and the specific data-loss risk of deleting the wrong one.
- **Q44.** `--force` "fixed" a stuck upgrade for a colleague. Explain what it actually does to resources Kubernetes considers immutable, and name two object types where it causes a visible outage.
- **Q45.** `--history-max 5` trimmed history to five revisions. State the default, the storage cost of an unbounded history in a cluster with 300 releases, and what you lose when the window trims a revision you later wanted to roll back to.
- **Q46.** Contrast `helm uninstall` with and without `--keep-history` on three points: `helm list` visibility, whether the name can be reused immediately, and whether `helm rollback` is possible.

---

## Exercise 10 — Kustomize: the templating-free alternative

### Steps

1. Build a base with no templating at all:

```bash
$ mkdir -p kust/base && cd kust/base
$ cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27.0
          ports:
            - containerPort: 80
          envFrom:
            - configMapRef:
                name: api-config
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
EOF
$ cat > service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
    - port: 80
      targetPort: 80
EOF
$ cat > kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
labels:
  - pairs:
      app.kubernetes.io/part-of: lpi703
    includeSelectors: false
configMapGenerator:
  - name: api-config
    literals:
      - LOG_LEVEL=info
EOF
```

2. Add a production overlay that changes the base without editing it:

```bash
$ cd .. && mkdir -p overlays/prod && cd overlays/prod
$ cat > resources-patch.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  template:
    spec:
      containers:
        - name: api
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
EOF
$ cat > kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: pkg
namePrefix: prod-
resources:
  - ../../base
replicas:
  - name: api
    count: 4
images:
  - name: nginx
    newTag: 1.27.2
configMapGenerator:
  - name: api-config
    behavior: merge
    literals:
      - LOG_LEVEL=warn
patches:
  - path: resources-patch.yaml
    target:
      kind: Deployment
      name: api
EOF
```

3. Render and read the result carefully:

```bash
$ kubectl kustomize . | grep -E '^(kind|  name|    name)|replicas:|image:|LOG_LEVEL'
kind: ConfigMap
  name: prod-api-config-9h2f4k8m6t
  LOG_LEVEL: warn
kind: Service
  name: prod-api
kind: Deployment
  name: prod-api
  replicas: 4
          image: nginx:1.27.2

$ kubectl kustomize . | grep -A2 'configMapRef'
            - configMapRef:
                name: prod-api-config-9h2f4k8m6t
```

4. Apply it and change one literal:

```bash
$ kubectl apply -k . >/dev/null
$ kubectl get deploy -n pkg prod-api
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
prod-api   4/4     4            4           28s

$ sed -i 's/LOG_LEVEL=warn/LOG_LEVEL=debug/' kustomization.yaml
$ kubectl apply -k . 
configmap/prod-api-config-3d7b1e5c0a created
deployment.apps/prod-api configured
service/prod-api unchanged

$ kubectl rollout status deploy/prod-api -n pkg
deployment "prod-api" successfully rolled out
$ kubectl get cm -n pkg | grep prod-api-config
prod-api-config-3d7b1e5c0a   1      12s
prod-api-config-9h2f4k8m6t   1      2m
```

5. Combine the two tools — Helm renders, Kustomize post-processes:

```bash
$ cd ~/lpi703
$ cat > kustomize-render.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > /tmp/pr/all.yaml
cd /tmp/pr && kubectl kustomize .
EOF
$ chmod +x kustomize-render.sh
$ mkdir -p /tmp/pr && cat > /tmp/pr/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - all.yaml
patches:
  - patch: |-
      - op: add
        path: /metadata/annotations/policy.example.com~1reviewed
        value: "true"
    target:
      kind: Deployment
EOF

$ helm template postrender ./web -n pkg --set config.environment=prod \
    --post-renderer ./kustomize-render.sh | grep -B1 'policy.example.com'
  annotations:
    policy.example.com/reviewed: "true"
```

6. Note the versions in play — a classic support-ticket cause:

```bash
$ kubectl version --client -o yaml | grep -A1 kustomizeVersion
kustomizeVersion: v5.4.2

$ kustomize version
v5.5.0
```

### Verification questions

- **Q47.** The generated ConfigMap was named `prod-api-config-9h2f4k8m6t`, and changing one literal produced a new name plus a Deployment rollout. Name the mechanism, and explain what a plain Helm chart must do to get the same effect (you built it in Exercise 5).
- **Q48.** Step 4 left the old ConfigMap in the cluster. State why `kubectl apply -k` does not remove it, and name the flag that does — along with the reason it is dangerous.
- **Q49.** State the fundamental design difference between Helm and Kustomize regarding *when* configuration is resolved, and derive from it two things Kustomize structurally cannot do and one class of bug it structurally cannot have.
- **Q50.** Kustomize has no release object. Given that, answer: how do you know which cluster resources came from `overlays/prod`, how do you roll back, and what replaces `helm history`?
- **Q51.** `kubectl kustomize` reported v5.4.2 while standalone `kustomize` reported v5.5.0. Describe the failure mode this produces in a team, and give the rule you would put in the project README.
- **Q52.** The post-renderer in step 5 mutated Helm's output before it reached the cluster. Explain why this is safer than forking an upstream chart, and name the one thing it does *not* let you change.

---

## Cleanup

```bash
$ helm uninstall web hooked fromrepo oci-web -n pkg 2>/dev/null
$ kubectl delete -k ~/lpi703/kust/overlays/prod
$ kubectl delete crd widgets.lab.lpi.org
$ docker rm -f lpireg
$ kind delete cluster --name lpi703
$ pkill -f "http.server 8879"
```

---

<details>
<summary><strong>Answers</strong></summary>

### Lab 0

**A1.** Helm 3 is a pure client. It builds manifests locally and talks to the API server using **your kubeconfig credentials**, so `helm install` can only do what your RBAC already allows. Consequence: there is no longer a single privileged in-cluster identity that every user borrows. In Helm 2, a namespaced user could reach cluster-admin-level power through Tiller's ServiceAccount; in Helm 3, a tenant restricted to namespace `pkg` cannot install a chart that creates a ClusterRole — the request is rejected by the API server, not by Helm. The release Secrets also live in the release namespace, so tenant isolation follows normal namespace RBAC. See <https://helm.sh/docs/faq/changes_since_helm2/>.

**A2.** Compatibility is determined by the API groups/versions the *target cluster* serves versus what the chart's templates emit. Two mechanisms express it: (a) `kubeVersion` in `Chart.yaml`, a SemVer range Helm enforces before install (`Error: chart requires kubeVersion: >=1.28.0-0 which is incompatible with Kubernetes v1.27.4`); and (b) `.Capabilities.APIVersions.Has "<group>/<version>"` inside templates, letting one chart render different objects per cluster. Also relevant is the Helm/Kubernetes version-skew policy: <https://helm.sh/docs/topics/version_skew/>.

### Exercise 1

**A3.** `version` is the chart package's SemVer and is the *only* field the repository index and the resolver compare. `appVersion` is free-form metadata describing the packaged software; it is not a package version and takes no part in dependency resolution or `helm search` version selection. Bumping only `appVersion` republishes the same coordinates, so `helm repo update` sees no newer chart and `helm upgrade` is a no-op. Rule: any change inside the chart directory — templates, values, defaults, `appVersion` — requires a `version` bump. See <https://helm.sh/docs/topics/charts/#the-chartyaml-file>.

**A4.** `apiVersion` in `Chart.yaml` selects the **chart format**: `v1` is the Helm 2 format, `v2` is the Helm 3 format. `v2` adds the `type` field, moves dependencies into `Chart.yaml`, and adds `dependencies[].condition/tags/import-values`. A `v1` chart declared its dependencies in a separate `requirements.yaml` (with overrides in `requirements.lock`). Helm 3 still installs `v1` charts, which is why you occasionally meet `requirements.yaml` in old repositories.

**A5.** A library chart is a **template-only package**: it exports `define`d named templates for other charts to `include`, and ships no renderable templates of its own (files must be prefixed `_`, e.g. `_pod.tpl`). It exists to remove copy-paste from a fleet of charts — one place defines the standard Deployment skeleton, security context, and label set. Consumers add it under `dependencies:` like any other chart and call `{{ include "common.deployment" . }}`. Helm refuses to install it because it would produce zero Kubernetes objects. See <https://helm.sh/docs/topics/library_charts/>.

**A6.** The scaffold's deployment renders `image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"`, so the empty default falls through to `appVersion` — here `1.27.2`. That is safer than `latest` for two reasons: the deployed version is pinned and recorded in the release, so `helm history`/`helm get metadata` tell you what is actually running; and `latest` combined with `imagePullPolicy: Always` makes Pod restarts silently change the running software, which is unreproducible and destroys rollback semantics — `helm rollback` would restore the same floating tag.

### Exercise 2

**A7.** Go's `text/template` resolves a missing map key to the zero value rather than an error. `.Values.autoscaling.enabld` is a missing key on a map, so it evaluates to `<no value>`/nil, which `if` treats as false. Nothing errors; the HPA is simply never rendered, and `helm lint` — which lints what was *produced* — sees valid YAML and reports success. The setting that changes this is Go's `missingkey=error` option, which Helm exposes through **`helm template --debug` does not enable it**; the supported route is `helm lint --strict` (turns warnings into failures) combined with `values.schema.json` to constrain the value surface, and rendering with `--set` of a known-good value set in CI. The structural fix is the schema: an unknown key can be rejected with `"additionalProperties": false`.

**A8.** Weakest to strongest:
1. `helm template` — pure client-side. Catches Go template syntax errors, `required` failures, schema violations, and YAML that will not parse. Never contacts the API server, so it works in an air-gapped CI runner.
2. `--dry-run` (client) — everything above, plus release-name collision against the storage backend, real `.Capabilities` from the live cluster's discovery, and correct `.Release.IsUpgrade`.
3. `--dry-run=server` (3.13+) — everything above, plus API server schema validation (unknown fields, wrong types like the `memory: 128` integer), admission webhooks, and OPA/Kyverno policy rejection; `lookup` also resolves. Catches "renders fine, cluster refuses it".

**A9.** In `helm template`, `.Capabilities.APIVersions` is populated from a **built-in default list** compiled into the Helm client (not from your cluster) unless you pass `--api-versions`, and `.Release.IsUpgrade` is always `false` while `.Release.IsInstall` is always `true`. Failure mode: a chart gated on `policy/v1` renders the PDB in CI because Helm's default list contains it, but the deployment target is an older or trimmed cluster that only serves `policy/v1beta1` — CI is green, `helm install` fails at apply time. Conversely, a chart gated on a CRD-provided group (e.g. `monitoring.coreos.com/v1` for ServiceMonitor) renders *nothing* in CI, so the golden-file test silently loses coverage. Fix: pass `--api-versions` explicitly in CI, or use `--dry-run=server`.

**A10.** `helm template <rel> <chart> --show-only templates/cronjob.yaml` (repeatable; the path is relative to the chart root, and `-s` is the short form). If the named template renders to nothing — the whole file is inside a false `if` — Helm exits non-zero with `Error: could not find template templates/cronjob.yaml in chart`. That error is genuinely useful: it distinguishes "I typed the path wrong" from "the feature is disabled", but it does mean `--show-only` in a CI script needs `|| true` handling if the object is conditional.

### Exercise 3

**A11.** (a) Release Secrets contain the full rendered manifest, which includes every `kind: Secret` the chart created. A user with `get secrets` in the namespace can read `sh.helm.release.v1.*`, decode it, and recover application secrets even if RBAC on the individual Secret objects were tighter — so "read Secrets in this namespace" is effectively "read everything Helm ever deployed here", and history retention extends that backwards in time. (b) Deleting the release Secrets deletes Helm's *only* record. `helm list` shows nothing, `helm history` is gone, and `helm upgrade` fails with `Error: ... release: not found`. The workloads keep running untouched — Kubernetes has no idea Helm existed — leaving orphaned resources that must be adopted by re-installing with the same names or cleaned up by label (`app.kubernetes.io/managed-by=Helm`).

**A12.** Helm's storage is **append-only**; a release's "current" revision is the highest-numbered non-superseded record. A rollback re-applies revision 2's manifest but writes it as revision 4 with `DESCRIPTION: Rollback to 2`. That gives you an immutable audit trail — you can see that a rollback happened, when, and from what — and it makes rollback itself reversible: you can `helm rollback web 3` to get back to the state you rolled away from. An in-place restore would rewrite history and make "why is production running the old image?" unanswerable.

**A13.** The flag is `--atomic`. It **implies `--wait`** — Helm blocks until all resources report ready (or `--timeout` expires) and, on any failure, automatically performs a rollback to the previous deployed revision, leaving the release `deployed` rather than `failed`. Reasons a team may not want it everywhere: (1) it converts a partial failure into a full rollback, which for a large release means twice the churn and can be slower and more disruptive than fixing forward; (2) `--wait` semantics are wrong for charts whose Pods legitimately never become Ready without external action (a Job-driven chart, or a StatefulSet awaiting manual PVC provisioning), so `--atomic` would roll back a perfectly good install on timeout; (3) it hides the broken intermediate state you might need for diagnosis.

**A14.** Divergence causes: (1) **mutating admission** — sidecar injectors (Istio, Linkerd), defaulting webhooks, and the API server's own defaults add fields the manifest never had; (2) **out-of-band changes** — `kubectl edit`, an HPA writing `spec.replicas`, an operator reconciling the object, or another controller adding annotations. Helm's upgrade logic consults **all three**: the *old* stored manifest, the *new* rendered manifest, and the *live* object, which is precisely the three-way merge. `helm get manifest` shows only what Helm rendered — it is intent, not reality.

**A15.** `HELM_DRIVER=configmap helm list -n pkg` prints an **empty list**: the driver determines where Helm looks, and nothing was ever written to ConfigMaps, so the releases are invisible. Reason to prefer `secret` (the default since Helm 3): release payloads routinely contain Secret manifests, and Secrets are the object type covered by encryption-at-rest (`EncryptionConfiguration`) and by tighter default RBAC — ConfigMaps are not encrypted at rest and are far more widely readable. Neither is enough for very large releases because both objects are capped at roughly **1 MiB** in etcd; a chart rendering hundreds of objects (or embedding large CRDs) exceeds it and fails to save, which is why Helm supports the `sql` driver (PostgreSQL) for large-scale installations. See <https://helm.sh/docs/topics/advanced/#storage-backends>.

### Exercise 4

**A16.** Lowest to highest precedence:
1. Subchart's own `values.yaml`
2. Parent chart's `values.yaml` (the parent's `subchartname:` block overrides the subchart's defaults)
3. `-f a.yaml`
4. `-f b.yaml` (later `-f` wins over earlier)
5. `--set`
6. `--set-string` / `--set-json` / `--set-file` — same tier as `--set`; among them, last one on the command line wins.

Merging is a deep merge for **maps**. **Lists are replaced wholesale**, not concatenated — that is the one that silently replaces. `null` is also special: setting a key to `null` deletes it from the merged result rather than setting it to nil.

**A17.** Two independent conversions. (1) Helm's `strvals` parser types the right-hand side: a bare token that parses as a number becomes an **int64**, so `00123` becomes the integer `123` and the leading zeros are gone before any template runs. (2) When that value is emitted into YAML in a context that demands a string (annotation values must be strings), Helm quotes the integer, so you see `"123"`. Avoid (1) with `--set-string podAnnotations.build=00123`, which forces the value to a Go string, or `--set-json 'podAnnotations={"build":"00123"}'` for full control of the type. The same trap bites `--set image.tag=1.27` (float `1.27`, and `1.10` would become `1.1`) and `--set nodeSelector.rack=01` — always `--set-string` for identifiers that look numeric.

**A18.** Both statements are true at different levels. `--set 'tolerations[0].key=only-this'` does **not** supply a new list; the index syntax navigates *into* the existing merged list and sets a leaf, so the merge happens element-wise and element 1 is untouched. The "lists replace" rule applies when a value **file** or a whole-list `--set` provides the list itself: `-f lists.yaml` after another file with `tolerations` discards the earlier list entirely. `--set tolerations=null` sets the key to null, which removes it from the merged values — the template's `{{- with .Values.tolerations }}` then renders nothing, dropping all tolerations.

**A19.** The schema is enforced by `helm install`, `helm upgrade`, `helm rollback`, `helm template`, and `helm lint` — including for subchart values, where each chart's own schema validates its own subtree. It is strictly stronger than server-side validation because: (a) it runs **before** rendering, so a bad value fails in milliseconds locally with a message naming the value path, instead of after a partial apply; (b) it validates *semantics the API server cannot know* — `replicaCount` between 1 and 10, an enum of allowed environments, a required field with no sane default; (c) it catches values that render into **valid but wrong** manifests, which the API server would accept happily; and (d) with `"additionalProperties": false` it catches typo'd keys, the exact class of bug `helm lint` missed in Exercise 2. See <https://helm.sh/docs/topics/charts/#schema-files>.

**A20.** `--reuse-values` merges the new `--set`/`-f` on top of the values stored in the *previous release*, so every upgrade accumulates state that exists nowhere in Git. Removing a value from your pipeline's values file has no effect — the old value is resurrected from the release record forever, and the only way to see it is `helm get values`. The deterministic alternatives: **`--reset-values`**, which discards stored values and uses chart defaults plus exactly what this invocation supplies; and **`--reset-then-reuse-values`** (Helm 3.14+), which resets to chart defaults, then re-applies the previous *user-supplied* values, then this invocation's — useful when chart defaults changed but you want to keep operator overrides. The best practice is neither flag: pass the complete set of values on every upgrade, from version control.

### Exercise 5

**A21.** `include` returns the rendered template **as a string**, so its output can be piped into other functions. `template` is a statement that writes directly to the output stream and returns nothing. Because `nindent 4` is a function that must receive a string argument, `{{ template "web.labels" . | nindent 4 }}` is a parse/semantic error — there is no value to pipe. Every place a named template's output needs indenting, quoting, hashing (`sha256sum`), or capturing into a variable, it must be `include`. See <https://helm.sh/docs/howto/charts_tips_and_tricks/>.

**A22.** `indent N` prefixes N spaces to **every line including the first**. `nindent N` emits a **newline first**, then indents every line by N. In `extra.yaml: |` the template call sits on its own line after `{{-`, which chomps the preceding newline; `nindent 4` supplies that newline back, so line 1 lands at column 4 like the rest. With `indent 4`, the chomped newline is never restored, so the first line is appended to the existing 4-space indentation already on the source line — 4 + 4 = 8 — while subsequent lines get only the function's 4. Rule of thumb: after `{{-` on its own line, use `nindent`; inline after existing text, use `indent`.

**A23.** The annotation lives on the **Pod template** (`spec.template.metadata.annotations`), so changing it changes the Pod template hash, which makes the Deployment controller create a new ReplicaSet and perform a rolling update. Without it: a ConfigMap **mounted as a volume** is updated in place by the kubelet (eventually — up to the sync period plus cache TTL, typically ~1 minute), so the file changes under a running process that will not notice unless it watches the file; a ConfigMap consumed via **`envFrom`/`env.valueFrom`** is injected only at container start and is **never** updated — the Pod keeps the old values until it is recreated for some unrelated reason, which is the classic "I changed the config an hour ago and nothing happened" incident.

**A24.** `lookup` performs a live API read, and during `helm template` (and client-side `--dry-run`) there is no API connection, so it returns an **empty map**. The `if $existing` branch is false, `randAlphaNum 24` runs, and a brand-new password is printed. The accident: a CI job that renders with `helm template` and applies with `kubectl apply -f` regenerates the database password **on every pipeline run**, overwriting the working Secret while the running Pods still hold the old one in their environment — the application starts failing authentication at the next Pod restart, hours later, with no obvious connection to the deploy. Mitigations: use `helm upgrade` (which has cluster access) rather than template-and-apply; or drop the generate-in-template pattern entirely in favour of an external secret manager (External Secrets Operator, Vault) or a `pre-install` hook Job that creates the Secret exactly once.

**A25.** Use **`values.schema.json`**, with `{"type":"string","minLength":1,"pattern":"^[a-z0-9-]+$"}`. `required` only proves the value is non-empty at the moment that one template line renders: it cannot express a pattern, it fires only if that template is actually reached (a value used solely inside a disabled `if` is never checked), it produces an error naming a file and line rather than a value path, and it runs after rendering has already started so the failure ordering is non-deterministic across templates. The schema validates the whole values tree up front, before any rendering, and is checked by `helm lint` and `helm template` alike. Use both if you like: the schema as the contract, `required` as a last-resort guard.

### Exercise 6

**A26.** `helm dependency update` **reads `Chart.yaml`, re-resolves the version ranges against the repositories, downloads the tarballs into `charts/`, and (over)writes `Chart.lock`.** `helm dependency build` **reads `Chart.lock` and downloads exactly the pinned versions**, refusing to run if the lock is out of sync with `Chart.yaml`. CI must use **`build`**: it is reproducible — a dependency declared as `version: "^2.1.0"` will silently pull 2.9.0 six months later under `update`, changing what ships without any commit to your repository. `update` is a deliberate, reviewed, human action that produces a `Chart.lock` diff.

**A27.** `condition` is a **path into the top-level parent's values**, and the alias determines the key under which a dependency's values live. With `alias: sessioncache`, the subchart's values are at `.Values.sessioncache`, so the condition must be `sessioncache.enabled` — `cache.enabled` points at a key nothing reads. For a second inclusion under `pagecache`, that entry needs its own `condition: pagecache.enabled` (each dependency entry carries its own condition), and both entries name the same `name: cache` with different aliases. Note `condition` accepts a comma-separated list and the **first path that resolves to a boolean wins**, which is how charts support both a new and a legacy toggle: `condition: sessioncache.enabled,cache.enabled`.

**A28.** (1) Through the subchart's key: `--set web.image.repository=registry.example.com/web`, or the equivalent block in the parent's `values.yaml`. This always works — the parent's `<subchartname>:` block is merged over the subchart's own defaults, and it is the mechanism the umbrella pattern is built on. (2) Through `global`: `--set global.imageRegistry=registry.example.com`, which is injected into **every** chart in the tree as `.Values.global.*`. This only has an effect if the **subchart author wrote a template that reads it** (e.g. `{{ .Values.global.imageRegistry | default .Values.image.registry }}`); `global` is a propagation mechanism, not a magic override. Charts that support it document it explicitly.

**A29.** Vendoring the `.tgz` files: the build has **zero network dependency**, the exact bytes are in your VCS and are auditable in code review, and an upstream repository going away or a maintainer force-replacing a version cannot break or silently change you. Cost: large binaries in Git, noisy diffs, and easy drift between `Chart.yaml` and what is actually vendored. Committing only `Chart.lock`: small, readable diffs, and the digest still pins exactly what was resolved — but you need network access to a live repository at build time, and you are trusting that the repository still serves those bytes. **Air-gapped builds require the vendored tarballs** (or a mirrored internal repository/OCI registry populated ahead of time). Add `charts/*.tgz` to `.gitignore` only if you have that mirror.

**A30.** Helm installs files in `crds/` **only on first install**, and never updates or deletes them: on upgrade the new CRD file is ignored entirely, so the added field remains unavailable and any CR using it is rejected; on uninstall the CRD and all its custom resources are left in place. This is deliberate — a CRD deletion cascades to **every custom resource in the cluster**, including ones other releases own, so Helm refuses to make that decision. The required procedure is out-of-band and explicit: `kubectl apply --server-side -f charts/<sub>/crds/` (or `kubectl replace -f`) **before** running `helm upgrade`, ideally as a documented pre-upgrade step in the release runbook. See <https://helm.sh/docs/chart_best_practices/custom_resource_definitions/>.

### Exercise 7

**A31.** A chart repository must serve exactly two things over HTTP(S): an **`index.yaml`** at the repository root, and the **chart tarballs** at the URLs listed in that index (they may live anywhere — S3, a CDN, another host — because each entry carries absolute `urls`). `helm repo add`/`update` fetches only `index.yaml`, which is why it is instant regardless of chart count and why `helm search repo` is a purely local operation against the cached index. `helm install lpilab/web` then resolves the version in the cached index to a `urls` entry and makes a **second** request for the tarball itself. No server-side API, no database, no dynamic behaviour — GitHub Pages or a bucket is a complete implementation. See <https://helm.sh/docs/topics/chart_repository/>.

**A32.** The cached indexes live under `$HELM_REPOSITORY_CACHE`, by default `~/.cache/helm/repository/<name>-index.yaml`, with the repository list in `~/.config/helm/repositories.yaml`. `helm search repo` searches **only those local caches** — it is offline and instant, and it is stale until `helm repo update`. `helm search hub` queries the **Artifact Hub** API over the network across all public repositories you have *not* added, returns a URL rather than an installable `repo/chart` reference, and therefore requires you to `helm repo add` the discovered repository before you can install from it.

**A33.** (a) **Version discovery**: HTTP repos enumerate every version in `index.yaml`, so the client can list them offline; OCI has no index file — versions are registry **tags**, discovered per-chart through the registry's tag-list API. (b) **Authentication**: HTTP repos use basic auth or client certs configured per-repo in `repositories.yaml` (`--username/--password`); OCI uses the standard registry token flow via `helm registry login`, which reuses the same credentials and infrastructure as your container images (and `~/.docker/config.json`). (c) **`helm search repo` works only for HTTP repositories** — there is nothing to add or cache for OCI. The consequence: with OCI you must already know the chart's full reference (`oci://host/path/name --version X`), so discovery moves out of Helm and into the registry UI or a catalogue like Artifact Hub, and scripts that did `helm search repo | grep` need rewriting. See <https://helm.sh/docs/topics/registries/>.

**A34.** The `.prov` file is a **clear-signed PGP message** containing the chart's `Chart.yaml` metadata plus a `files:` block with the SHA-256 of the tarball; `helm verify` (or `helm install --verify`) checks the signature against your keyring *and* recomputes the tarball hash. It protects against a compromised mirror or a MITM because those parties cannot produce a valid signature for altered bytes. It does **not** protect against a compromised author: if the attacker holds the signing key, a malicious chart is signed correctly and verifies perfectly — provenance proves *origin and integrity*, not *safety*. For CI, the signer's **public** key must be in a keyring the runner can read, passed with `--keyring`; the standard mistake is exporting the *secret* keyring instead, and the second standard mistake is Helm's inability to read GnuPG 2.1+'s `.kbx` store, which is why the exercise runs `gpg --export`/`--export-secret-keys` into legacy `.gpg` files first. See <https://helm.sh/docs/topics/provenance/>.

**A35.** Archive: (1) the exact chart tarball `web-0.3.0.tgz` and its `.prov`; (2) all dependency tarballs — i.e. a chart packaged with `charts/` populated, or the vendored `charts/*.tgz` plus `Chart.lock`; (3) the complete values files used, from version control at the release commit; (4) the **container images** the chart references, by digest, mirrored into your own registry (a chart is useless if `nginx:1.27.2` has been retagged or deleted); and (5) the Helm client version used. Future reproduction: `helm verify web-0.3.0.tgz --keyring pub.gpg`, then `helm template web ./web-0.3.0.tgz -f values-prod.yaml` to compare against the archived rendered manifest, then `helm upgrade --install web ./web-0.3.0.tgz -f values-prod.yaml`. Pin images by `@sha256:` digest in the values, not by tag — that is the only part of this that is genuinely immutable.

### Exercise 8

**A36.** For `helm upgrade`: `pre-upgrade` → (apply resources) → `post-upgrade`. `--wait` applies **between** resource application and `post-upgrade`: Helm waits for the release's resources to be ready before firing post hooks, and it also waits for each hook's own resource to complete before proceeding to the next hook weight. Full event set: `pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`, `pre-delete`, `post-delete`, `pre-rollback`, `post-rollback`, `test`. If the upgrade fails during resource application, `pre-upgrade` has already run and `post-upgrade` does **not** run — which is exactly why a `pre-upgrade` migration must be idempotent and backward-compatible: the new code may never arrive, and the old code keeps running against the migrated schema.

**A37.** Hook resources are **not part of the release manifest**, so Helm does not consider them release-owned content: they are created, watched, and then handled purely according to `helm.sh/hook-delete-policy`. With `hook-succeeded`, the Job is deleted as soon as it completes, so `helm uninstall` finds nothing to remove. With **no** delete policy, the default is `before-hook-creation` — the resource is left in the cluster after the release completes and is deleted only the next time the same hook runs. That leftover is **not deleted by `helm uninstall`**, which is the standard source of orphaned Jobs and their Pods accumulating in a namespace long after the release is gone. If you want a hook cleaned up on both paths, set `hook-succeeded,hook-failed` (or `before-hook-creation,hook-succeeded`, keeping failures around for debugging). See <https://helm.sh/docs/topics/charts_hooks/>.

**A38.** Kubernetes annotation values must be strings. Unquoted `-5` renders as a YAML integer and the API server rejects the object: `cannot unmarshal number into Go struct field ObjectMeta.metadata.annotations of type string`. Helm sorts hooks by weight **ascending** (negative first) and executes them in that order, waiting for each to complete before starting the next weight. Ties are broken deterministically by **resource kind** (Helm's install-order list — Namespace, ResourceQuota, ... , ConfigMap, Secret, ... , Job, ...) and then by **name**, alphabetically. Never rely on the tie-break; assign distinct weights when order matters.

**A39.** (1) **Installed on first install** so that a chart shipping an operator works out of the box — the CRD must exist before any CR in `templates/` can be applied, and `crds/` is applied first, in a separate pass, with the API server given time to register it. (2) **Not updated on upgrade** because a CRD update can be destructive: narrowing a schema, removing a served version, or changing the storage version can render existing custom resources unreadable across the *whole cluster*, including CRs belonging to other releases. (3) **Not deleted on uninstall** because deleting a CRD garbage-collects every CR of that type cluster-wide — an irreversible, cross-tenant data loss triggered by removing one release. Workarounds: **(a)** put the CRD in `templates/` instead, usually gated behind `--set crds.install=true` and `helm.sh/resource-policy: keep`; you gain upgrades and lose Helm's guaranteed pre-templates ordering, and you risk two releases fighting over the same cluster-scoped object. **(b)** Ship a **`pre-upgrade` hook Job** that applies the CRDs with `kubectl apply --server-side`; you get ordering and upgrades but the Job needs cluster-scoped RBAC, which is itself a privilege escalation surface. Many production charts choose (c): a separate `<name>-crds` chart with its own release lifecycle.

**A40.** `helm test <rel> --timeout 5m` bounds it (default 5 minutes); combine with `--logs` so a timeout still surfaces the Pod output. Chart tests are hooks (`helm.sh/hook: test`) rather than ordinary templates because they must be **excluded from the release manifest** — a test Pod is not part of the deployed application and must not be created by `helm install`, must not be reconciled, and must not appear in `helm get manifest` or block `helm upgrade`. Being a hook lets `helm test` create them on demand, wait for the Pod phase, report Succeeded/Failed, and clean up per `hook-delete-policy`. See <https://helm.sh/docs/topics/chart_tests/>.

### Exercise 9

**A41.** Helm 3 uses a **three-way strategic merge patch**, computed from: (1) the **old manifest** stored in the release Secret, (2) the **new manifest** just rendered, and (3) the **live object** read from the API server. `spec.replicas` was 3 in the old manifest and 3 in the new one, but 0 live — the field is chart-managed and the live value diverges from the declared value, so the patch sets it back to 3. The hand-added annotation appears **only** in the live object; it is absent from both the old and new manifests, so Helm has no instruction to remove it and the patch leaves it alone. The general rule: Helm reverts drift on fields it declares, and ignores fields it never declared. (Helm 2's two-way merge compared only old and new manifests, so it did not correct the replicas.) See <https://helm.sh/docs/faq/changes_since_helm2/#improved-upgrade-strategy-3-way-strategic-merge-patches>.

**A42.** If the chart always renders `spec.replicas: 3` while an HPA has scaled the Deployment to 40 under load, the next `helm upgrade` — even one that changes nothing else — patches replicas back to 3 and instantly drops 92% of the capacity, mid-traffic. The HPA will scale back up, but only at its own rate, so you get a real outage window. The scaffold avoids it by **omitting the field entirely** when autoscaling is on:
```yaml
{{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
{{- end }}
```
An undeclared field is not drift, so the three-way merge leaves the HPA's value untouched. (Server-side apply with a separate field manager is the newer, more general answer to the same problem.)

**A43.** `pending-upgrade` means Helm wrote a new release record marked "in progress" and then **died before finishing** — killed, network partition, CI timeout. On the next invocation Helm sees a non-terminal status and refuses with `another operation is in progress`, because it cannot tell your interrupted run from a concurrent one still working; `helm rollback` refuses for the same reason. Deleting the newest release Secret removes the in-progress record, so the previous `deployed` revision becomes the highest and Helm's view is consistent again. The risk of deleting the wrong Secret: if you delete the last **`deployed`** revision instead of the pending one, you destroy the record of what is actually running — Helm's next upgrade computes its three-way patch from an older manifest and will happily delete resources that the (now-forgotten) revision added. Always confirm with `kubectl get secret -l owner=helm,name=<rel> -L version,status` before deleting, and delete exactly the `pending-*` one. Verify no other process is genuinely mid-upgrade first.

**A44.** `--force` makes Helm use **`replace`** semantics (a full object PUT / delete-and-recreate) instead of a patch. On immutable fields it "works" by destroying and recreating the object rather than failing. Two visible-outage cases: (1) **Service** — a recreate drops the object, so its `spec.clusterIP` and the associated Endpoints/NodePort are reallocated; every client caching that IP, plus any external DNS or firewall rule pinned to the NodePort, breaks. (2) **Deployment/StatefulSet with a changed `spec.selector`** (immutable) — Helm deletes the controller, which with the default cascade takes all of its Pods, so the workload goes to zero replicas and is rebuilt from scratch; for a StatefulSet this also means an ordered, one-by-one restart of stateful members. `--force` is not a fix for a stuck release — it is a way to convert "Helm refused" into "Helm deleted production".

**A45.** The default is `--history-max 10` (0 means unlimited). With 300 releases and unbounded history, every revision is a Secret holding the full gzipped manifest — a few hundred KB each for a non-trivial chart — so etcd grows into the gigabytes, `kubectl get secrets -A` becomes slow, and API server watch caches and backups grow with it; the practical failure is etcd exceeding its `--quota-backend-bytes` and going read-only cluster-wide. What you lose when the window trims: `helm rollback <rel> <n>` for a trimmed `n` returns `Error: release: not found` — you can no longer roll back to that state with Helm, and must reconstruct it by re-installing the corresponding chart version and values from Git. That is the real argument for keeping chart version + values in version control: history retention is a cache, not a backup.

**A46.** (1) **`helm list` visibility**: a plain uninstall removes the release entirely — it appears nowhere; with `--keep-history` it appears under `helm list --uninstalled` (or `--all`) with status `uninstalled`. (2) **Name reuse**: after a plain uninstall the name is immediately free; with `--keep-history` the name is still taken, and `helm install <same-name>` fails with `cannot re-use a name that is still in use` — you must `helm uninstall` again (without the flag) first. (3) **Rollback**: impossible after a plain uninstall (no records); possible with `--keep-history` — `helm rollback <rel> <rev>` recreates the resources from the kept manifest, which is the one supported way to undo an accidental uninstall.

### Exercise 10

**A47.** The mechanism is Kustomize's **configMapGenerator** (and `secretGenerator`), which appends a **hash of the content** to the object name and rewrites every reference to it — `configMapRef`, `volumes[].configMap`, `env.valueFrom.configMapKeyRef` — throughout the rendered set. Changing a literal changes the hash, which changes the name, which changes the Pod template, which forces a rolling update; and it is atomic, because the new ConfigMap exists before the new Pods reference it. A plain Helm chart gets the same effect with the **`checksum/config` Pod-template annotation** built in Exercise 5: `{{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}`. The difference is that Helm mutates the ConfigMap in place (so a rollback of the Deployment does not roll back the ConfigMap), while Kustomize creates a new immutable object per content version.

**A48.** `kubectl apply -k` applies the rendered set; it has no memory of what a previous render contained, so an object that disappears from the output is simply never mentioned again and stays in the cluster. The flag is **`--prune`** (with `-l <selector>` or, better, `--prune-allowlist`/`--applyset`), which deletes resources matching the selector that are not in the current apply. It is dangerous because pruning is driven by a **label selector, not by ownership**: too broad a selector deletes objects created by other overlays, other tools, or by hand, and a temporarily incomplete render (a typo'd `resources:` entry) prunes healthy production objects. This is the single largest structural advantage Helm holds over raw Kustomize: the release record makes removal explicit and scoped.

**A49.** Helm resolves configuration at **render time**, by executing a Turing-complete Go template program over a values tree. Kustomize resolves it at **overlay time**, by structurally merging and patching complete, already-valid YAML. Consequences — two things Kustomize structurally cannot do: (1) **conditionally emit an entire resource based on a flag** (`if .Values.ingress.enabled`) — an overlay can patch or exclude a resource by editing `resources:`, but there is no boolean-driven generation; (2) **compute values** — no loops over a list to generate N objects, no string functions, no `randAlphaNum`, no `lookup`. One class of bug it cannot have: **rendering invalid YAML**. Every input and output is parseable YAML at every step, so indentation bugs, whitespace-chomping bugs, and "the map became a string" bugs — the entire `nindent`/`toYaml` family from Exercise 5 — do not exist. Kustomize also cannot ship a *packaged, versioned, discoverable artifact* the way a chart repository does, which is the other half of "package management".

**A50.** (a) **Provenance**: only by labels you put there yourself — `labels:`/`commonLabels` in the overlay, plus `namePrefix` conventions. Nothing is automatic; `app.kubernetes.io/managed-by` has no equivalent. (b) **Rollback**: `git revert` the overlay commit and re-run `kubectl apply -k` — the state lives in version control, not in the cluster. This is strictly Git-based, which is why Kustomize pairs naturally with a GitOps controller (Argo CD, Flux) that stores sync history and provides a rollback UI. (c) `helm history` is replaced by the **Git log** of the overlay directory, plus `kubectl rollout history` for per-workload revisions. The trade is explicit: Helm keeps operational state in the cluster; Kustomize keeps it all in Git and has nothing to get stuck in `pending-upgrade`.

**A51.** `kubectl` **vendors** a specific Kustomize version, and it lags the standalone binary — often by several releases. Failure mode: a developer writes a kustomization using a field or transformer only present in v5.5.0, verifies it with `kustomize build`, commits, and the CI runner (or another developer, or the cluster's GitOps controller) uses `kubectl apply -k` with the older embedded version, which either errors on an unknown field or — worse — **silently ignores it**, producing a valid-looking but wrong manifest. README rule: *"Always render and apply with the standalone `kustomize` binary pinned in `.tool-versions`: `kustomize build overlays/prod | kubectl apply -f -`. Never use `kubectl apply -k`."* Pin the same version in CI and in the GitOps controller.

**A52.** A **post-renderer** is an executable that receives Helm's rendered manifest on stdin and returns the modified manifest on stdout; Helm then applies *that* and stores it in the release record. It is safer than forking an upstream chart because you keep tracking upstream: `helm upgrade` to a new chart version costs nothing, there is no merge conflict, and your modification is a small, reviewable patch expressing exactly your delta — the classic use being injecting an annotation, a sidecar, or a nodeSelector that the chart does not parameterise. What it does **not** let you change: anything Helm resolves *before* rendering — the chart's `values.schema.json` validation, `required` failures, hook *scheduling* (hooks are extracted from the manifest by Helm and are not part of what the post-renderer's changes affect on the applied release in the same way), and CRDs in `crds/`, which bypass the template pipeline entirely. If the chart refuses to render your values, no post-renderer can help. See <https://helm.sh/docs/topics/advanced/#post-rendering>.

</details>

---

## Sources

- LPI Exam 701 Objectives, version 2.0 — <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Helm — Charts — <https://helm.sh/docs/topics/charts/>
- Helm — Chart Template Guide — <https://helm.sh/docs/chart_template_guide/>
- Helm — Chart Repository Guide — <https://helm.sh/docs/topics/chart_repository/>
- Helm — OCI Registries — <https://helm.sh/docs/topics/registries/>
- Helm — Chart Hooks — <https://helm.sh/docs/topics/charts_hooks/>
- Helm — Chart Tests — <https://helm.sh/docs/topics/chart_tests/>
- Helm — Library Charts — <https://helm.sh/docs/topics/library_charts/>
- Helm — Provenance and Integrity — <https://helm.sh/docs/topics/provenance/>
- Helm — Advanced Topics (storage backends, post-rendering) — <https://helm.sh/docs/topics/advanced/>
- Helm — Changes Since Helm 2 (three-way merge, no Tiller) — <https://helm.sh/docs/faq/changes_since_helm2/>
- Helm — Custom Resource Definitions best practice — <https://helm.sh/docs/chart_best_practices/custom_resource_definitions/>
- Helm — Version Support Policy — <https://helm.sh/docs/topics/version_skew/>
- Kubernetes — Declarative Management using Kustomize — <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/>
- Kustomize — Kustomization file reference — <https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/>