# 703.3 — Gestión de paquetes en Kubernetes

**Certificación:** LPI DevOps Tools Engineer — Examen 701-100, versión 2.0.0
**Peso del tema:** 3.33
**Nivel:** Platform Architect / Senior SRE

---

## 1. El problema arquitectónico

Una aplicación de Kubernetes nunca es un solo objeto. Un único servicio HTTP sin estado en producción es, como mínimo, un `Deployment`, un `Service`, un `ServiceAccount`, un `ConfigMap`, una referencia a un `Secret`, un `HorizontalPodAutoscaler`, un `PodDisruptionBudget`, una `NetworkPolicy` y un `Ingress` o `HTTPRoute`. Nueve objetos de la API que deben crearse en un orden válido, mutarse juntos, versionarse juntos y — algo crítico — *eliminarse* juntos cuando la aplicación se da de baja.

`kubectl apply -f ./manifests/` no resuelve ninguno de los cuatro problemas que importan a escala:

**Problema 1 — Parametrización.** El mismo servicio corre en `dev`, `staging` y tres regiones de producción. El noventa y cinco por ciento del YAML es idéntico; el delta son la cantidad de réplicas, los resource requests, los tags de imagen, los hostnames y un feature flag. Copiar y pegar el directorio cinco veces produce cinco artefactos que divergen en un trimestre. No existe un `$VARIABLE` en el modelo de objetos de Kubernetes — el API server consume JSON completamente resuelto, así que la parametrización *debe* ocurrir del lado del cliente, antes de emitir la petición.

**Problema 2 — Agrupamiento y ciclo de vida.** El API server no tiene ningún concepto de "aplicación". Nada en etcd dice que esos nueve objetos son una unidad. Borrá el directorio de Git y `kubectl apply` no hará absolutamente nada: apply es aditivo. Los objetos `NetworkPolicy` huérfanos de un servicio dado de baja son un riesgo real y frecuente en producción — siguen aplicando reglas para cargas de trabajo que ya no existen, y son invisibles en cualquier dashboard que liste Deployments.

**Problema 3 — Orden y readiness.** Una `CustomResourceDefinition` debe estar registrada antes que cualquier custom resource que la use, o el mapeo de manifiesto a objeto del lado del cliente falla directamente. Un `Job` de migración de esquema debe completarse antes de que ruede el nuevo `Deployment`. Un `Namespace` debe existir antes que cualquier cosa dentro de él.

**Problema 4 — Rollback.** "Revertir el deploy" es trivial para un `Deployment` (`kubectl rollout undo`) e imposible para la *aplicación*: revertir un Deployment no revierte el ConfigMap que lee, los límites del HPA que cambiaron con él, ni el campo del CRD que introdujo la nueva versión.

La gestión de paquetes de Kubernetes es la disciplina de resolver los cuatro con un artefacto versionado y reproducible. El objetivo del examen cubre las dos herramientas que dominan el ecosistema — **Helm** y **Kustomize** — más el modelo de repositorios y distribución que las rodea.

> **Alcance del objetivo.** LPI publica las áreas de conocimiento clave autoritativas de 703.3 en la página de objetivos del examen citada en §11. Este material cubre, con profundidad de producción: la estructura y el templating de charts de Helm, el ciclo de vida de las releases y su modelo de almacenamiento, los repositorios de charts incluyendo registries OCI, la procedencia de charts, bases/overlays/patches/generators de Kustomize, y el diagnóstico de fallas en ambos.

---

## 2. El panorama y sus compromisos

Compiten dos filosofías. El **templating** (Helm, Jsonnet) trata los manifiestos como texto a generar; la herramienta no entiende Kubernetes hasta el último momento. El **overlaying** (Kustomize) trata los manifiestos como datos estructurados a fusionar; la herramienta entiende el modelo de objetos pero no tiene variables.

| Dimensión | Manifiestos crudos + `apply` | Kustomize | Helm 3 | Jsonnet / Tanka | cdk8s | Operator + OLM |
|---|---|---|---|---|---|---|
| Modelo de parametrización | ninguno (o `envsubst`) | patch estructural (sin variables) | Go `text/template` + Sprig | lenguaje funcional completo | lenguaje de propósito general (TS/Py/Go) | campos del spec del CRD |
| Validez de entrada garantizada | n/a | sí — los patches son YAML/JSON | **no** — la salida puede ser texto arbitrario | sí | sí | sí |
| Agrupamiento / identidad de release | ninguno | ninguno (solo en build) | **sí** — objeto de release en el clúster | ninguno | ninguno | sí (instancia del CR) |
| Rollback atómico | no | no | **sí** — `helm rollback` | no | no | definido por el operator |
| Borrado de recursos eliminados | manual | manual (o `--prune`) | **sí** — automático en el upgrade | manual | manual | sí (ownerRefs) |
| Primitivas de ordenamiento | manual | manual | kind sorter + hooks + weights | manual | manual | lógica del operator |
| Distribución | Git | Git | **`index.yaml` de repo / registry OCI** | Git / jsonnet-bundler | npm/PyPI | imagen de catálogo OLM |
| Procedencia criptográfica | separada (cosign sobre Git) | separada | **`.prov` integrado** + firma OCI | ninguna | ninguna | firma de imagen |
| Reconciliación day-2 | ninguna | ninguna | ninguna (CLI imperativa) | ninguna | ninguna | **continua** |
| Curva de aprendizaje | trivial | baja | media | alta | media (necesita un runtime) | alta |
| Modo de falla principal | drift | el patch apunta silenciosamente a nada | errores de espacios/indentación en templates | complejidad del lenguaje | toolchain de build en CI | los bugs del operator son a nivel clúster |

**Lectura arquitectónica de esta tabla.** Helm es la única entrada que lleva la *identidad de release al clúster*, y esa única propiedad es la razón por la que domina la distribución de terceros: cuando instalás la base de datos de otro, necesitás un comando para eliminarla por completo. Kustomize gana para el código de aplicación propio, porque la fuente de verdad sigue siendo YAML válido que cualquier herramienta puede lintear, y porque no hay una capa de templating entre lo que leés y lo que recibe el API server.

La respuesta madura de producción no es "elegí uno". Es:

- **Kustomize para las aplicaciones propias** — tus servicios, en tu monorepo, donde la base la escribe el mismo equipo que la opera.
- **Helm para todo lo que consumís** — ingress controllers, cert-manager, Prometheus, bases de datos — porque vienen de upstream como charts y querés su camino de desinstalación.
- **Kustomize como post-renderer sobre Helm** cuando a un chart upstream le falta el único campo que necesitás. Esta es la vía de escape que elimina la necesidad de forkear charts (§6.4).

---

## 3. Helm: arquitectura e internals

### 3.1 Anatomía de un chart

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

Tres reglas que sorprenden a la gente:

1. **`crds/` no es `templates/crds/`.** Los archivos bajo `crds/` son YAML plano — sin templating, sin values. Helm los instala *antes* de renderizar cualquier otra cosa, los saltea si el CRD ya existe, y **nunca los actualiza ni los borra**. Esto es deliberado: borrar un CRD cascadea a cada custom resource del clúster, incluyendo las que tu release no creó. Actualizar esquemas de CRD es responsabilidad de un operator, no de un chart.
2. **Cualquier cosa en `templates/` que renderice a salida vacía se descarta.** Así funcionan los condicionales — un manifiesto entero envuelto en `{{- if .Values.x }}` produce un documento con solo espacios en blanco que Helm descarta.
3. **`.helmignore` controla qué entra en el `.tgz`**, usando sintaxis de `.gitignore`. Olvidarlo es la forma en que `.git/` y los secrets de CI terminan publicados en un repositorio de charts público.

### 3.2 `Chart.yaml` — la forma de la API v2

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

`condition` y `tags` son las dos formas de apagar subcharts. `condition` lee una ruta booleana en los values (si están separadas por coma, gana la primera ruta existente); `tags` agrupa varios subcharts bajo un mismo interruptor (`--set tags.helpers=false`). `alias` permite incluir el mismo chart dos veces bajo nombres distintos.

**`version` versus `appVersion` es una distinción favorita del examen y también una distinción operativa real.** `version` es lo que el repositorio indexa y lo que selecciona `--version`; cambiar los templates del chart *obliga* a incrementarla. `appVersion` es metadata sobre el software empaquetado y típicamente alimenta el tag de imagen por defecto. Un chart en `1.9.0` puede traer `appVersion: 2.32.0`; un arreglo solo de templates produce `1.9.1` con un `appVersion` sin cambios.

### 3.3 El pipeline de renderizado

Entender el orden exacto es lo que separa depurar de adivinar:

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

El paso 5 es texto puro. Helm no sabe que está produciendo YAML en ese punto — que es exactamente por qué un `toYaml` sin indentar produce un error de parseo en el paso 6 con un número de línea que se refiere a la salida *renderizada*, no a tu template.

**Precedencia de values**, de menor a mayor:

| Rango | Origen |
|---|---|
| 1 | `values.yaml` del subchart |
| 2 | `values.yaml` del chart padre |
| 3 | Values del chart padre que direccionan al subchart por nombre, y `global:` |
| 4 | Archivos `-f/--values`, **de izquierda a derecha** (gana el último archivo) |
| 5 | `--set-file` |
| 6 | `--set-string`, `--set`, `--set-json` (gana el último flag) |

Dos comportamientos de coalescencia que causan incidentes:

- **Los mapas se fusionan; los arrays se reemplazan.** `--set ingress.hosts[0].host=a.example.io` no agrega a la lista por defecto, reemplaza el elemento 0 y deja el resto. Para vaciar una lista, hay que setearla explícitamente a `[]` con `--set-json`.
- **`null` borra.** Setear una clave a `null` en un archivo de override elimina la clave heredada de un padre — la única forma de desactivar un valor por defecto de un subchart.

### 3.4 La trampa del upgrade: cómo trata `helm upgrade` los values previos

El comportamiento por defecto de Helm 3 no es "fusionar con lo que ya está desplegado". La lógica es:

| Flags | Comportamiento |
|---|---|
| *(ninguno)*, **y sin `-f`/`--set` provisto** | Los values previos suministrados por el usuario se copian tal cual |
| *(ninguno)*, **y con algún `-f`/`--set` provisto** | Los values previos del usuario se **descartan por completo**; solo aplica lo que pasaste ahora, sobre los defaults del chart |
| `--reuse-values` | Los values previos son la base; `-f`/`--set` se fusionan encima |
| `--reset-values` | Se ignoran los values previos; defaults del chart + `-f`/`--set` |
| `--reset-then-reuse-values` | Defaults del chart, luego los values de la release previa, luego `-f`/`--set` (Helm ≥ 3.14) |

La segunda fila es la trampa. Un operador que instaló con `-f prod-values.yaml` y después corre `helm upgrade checkout ./chart --set image.tag=2.32.1` revierte silenciosamente cada override de producción al default del chart — cantidad de réplicas, límites de recursos, todo. **La disciplina es pasar siempre el conjunto completo de values en cada upgrade**, desde un archivo en Git, y nunca depender de que el clúster recuerde.

### 3.5 Orden de instalación (el kind sorter)

Helm ordena los objetos renderizados por kind antes de aplicarlos, usando una tabla fija en `pkg/releaseutil/kind_sorter.go`. El orden de instalación empieza:

```
Namespace → NetworkPolicy → ResourceQuota → LimitRange → PodSecurityPolicy
→ PodDisruptionBudget → ServiceAccount → Secret → ConfigMap → StorageClass
→ PersistentVolume → PersistentVolumeClaim → CustomResourceDefinition
→ ClusterRole → ClusterRoleBinding → Role → RoleBinding → Service
→ DaemonSet → Pod → ReplicaSet → Deployment → HorizontalPodAutoscaler
→ StatefulSet → Job → CronJob → Ingress → APIService
```

La desinstalación no es simplemente el orden inverso — es una tabla separada, diseñada para que las cargas de trabajo se detengan antes de que desaparezcan el RBAC y el almacenamiento de los que dependen.

**El sorter no espera.** Ordena el *envío* de los objetos, no su readiness. Un `Deployment` enviado después de un `Job` no espera a que el Job se complete. El ordenamiento por readiness requiere hooks (§3.6) o `--wait`.

### 3.6 Hooks

Un hook es un manifiesto común que lleva `helm.sh/hook`. Helm lo quita del manifiesto principal de la release, lo aplica en el punto declarado del ciclo de vida, y **espera a que alcance un estado listo** antes de continuar.

| Anotación | Valores |
|---|---|
| `helm.sh/hook` | `pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`, `pre-delete`, `post-delete`, `pre-rollback`, `post-rollback`, `test` |
| `helm.sh/hook-weight` | entero entrecomillado, aplicado en orden **ascendente** dentro de una fase |
| `helm.sh/hook-delete-policy` | `before-hook-creation` (por defecto), `hook-succeeded`, `hook-failed` |

Dos propiedades con peso operativo real:

1. **Los recursos de hook no forman parte del manifiesto de la release.** Por lo tanto *no* los borra `helm uninstall` salvo que una delete policy los elimine, y *no* se reconcilian en el upgrade. Los `Job` de hook de vida larga se acumulan en los namespaces durante años.
2. **Un hook fallido aborta la release.** Que falle un `pre-upgrade` significa que el upgrade nunca toca el Deployment — que es precisamente lo que querés para una migración de esquema.

### 3.7 Almacenamiento de la release y el merge a tres vías

Helm 3 almacena cada revisión como un `Secret` (por defecto; `--history-max` limita la retención a 10):

```
name:  sh.helm.release.v1.<release>.v<revision>
type:  helm.sh/release.v1
data:  release = base64( gzip( JSON ) )        ← then base64 again by the Secret encoding
labels: name, owner=helm, status, version, modifiedAt
```

El JSON contiene la metadata de la release, la configuración *suministrada por el usuario*, el manifiesto completamente renderizado, y el chart mismo. Esa última parte importa: los charts van embebidos, así que un chart enorme (cientos de CRDs) puede exceder el límite de 1 MiB por objeto de etcd — ver §9.

En el **upgrade**, Helm computa un **strategic merge patch a tres vías** a partir de:

- el manifiesto registrado en la release *anterior* (el estado "viejo" que Helm cree poseer),
- el manifiesto recién renderizado ("nuevo"),
- el **objeto vivo** leído del API server.

Por eso Helm 3 deja correctamente en paz los campos que posee otro controlador (un HPA escribiendo `spec.replicas`, un service mesh inyectando un sidecar) mientras sigue eliminando los campos que el chart mismo quitó. Para los tipos built-in usa strategic merge (respetando `patchMergeKey`); para custom resources sin una struct de Go disponible cae a un JSON merge patch, donde **las listas se reemplazan por completo**.

`--force` evita todo esto y emite un `PUT` de reemplazo. Es un último recurso, y falla en objetos con campos inmutables poblados por el servidor (`Service.spec.clusterIP`).

> Helm 4 mueve la ruta de apply a **server-side apply** con field managers, lo que cambia sustancialmente la semántica de conflictos. Todo lo descrito acá es el comportamiento de Helm 3.x al que apunta el objetivo 701-100 v2.0; verificá `helm version` y las notas de release del binario que realmente ejecutás.

### 3.8 La función `lookup` y por qué es peligrosa

`lookup` consulta el clúster vivo durante el renderizado:

```yaml
{{- $existing := lookup "v1" "Secret" .Release.Namespace "checkout-tls" }}
{{- if $existing }}
tls.crt: {{ index $existing.data "tls.crt" }}
{{- end }}
```

Devuelve un **mapa vacío durante `helm template` y en dry-run del lado del cliente**, porque no existe conexión con la API. Un chart que genera una contraseña solo cuando el Secret está ausente por lo tanto la regenerará en cada render de GitOps, o producirá un manifiesto con un campo vacío. Los charts que usan `lookup` no son renderizables de forma segura offline — lo que rompe el modelo de Argo CD (§10) y cualquier flujo de `helm template | kubectl diff`. Usá `--dry-run=server` cuando necesites renderizar fielmente un chart con `lookup`.

---

## 4. Un chart de producción completo

Lo siguiente es un chart completo y autoconsistente. No se omite nada.

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

`required` hace fallar el render con tu mensaje en lugar de mandar un string vacío a producción. `fail` es su hermano incondicional, usado dentro de bloques `if` para rechazar combinaciones inválidas.

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

Dos detalles que vale nombrar explícitamente. El `{{- if not .Values.autoscaling.enabled }}` alrededor de `replicas` es obligatorio cuando hay un HPA presente: si el chart siempre emite `replicas`, cada `helm upgrade` pelea con el HPA y devuelve la flota al default del chart. Y la anotación `checksum/config` es el idiom canónico de Helm para rollouts disparados por configuración — Kustomize resuelve el mismo problema con hashes de generador (§7.4).

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

Notá `$.Values` dentro del `range`: `.` se reasigna al elemento del bucle, así que al contexto raíz hay que llegar a través de `$`. Este es el error de templating más común en charts reales.

### 4.7 `templates/job-migrate.yaml` — un hook `pre-upgrade`

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

`hook-delete-policy: before-hook-creation` es lo que hace esto idempotente — el nombre de un `Job` no se puede reutilizar, así que sin eso el segundo upgrade falla con `jobs.batch "…-migrate" already exists`.

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

El esquema se verifica en `install`, `upgrade`, `lint` y `template`. Forzar que `image.repository` apunte a tu propio registry desde el esquema es un control de cadena de suministro barato y efectivo: un archivo de values que apunte a Docker Hub falla en tiempo de render, en CI, antes de llegar a un clúster.

---

## 5. Helm en la línea de comandos

### 5.1 Ciclo de autoría

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

`helm lint` renderiza con los defaults del chart, así que un `required` sobre un value sin default hace fallar el lint por diseño. Linteá explícitamente el archivo de values de cada entorno.

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

`--validate` envía la salida renderizada al API server para validación de esquema sin persistirla — atrapa un campo mal escrito que `lint` no puede:

```console
$ helm template checkout charts/checkout-api -f env/prod/values.yaml --validate
Error: unable to build kubernetes objects from release manifest: error validating "": error validating data: ValidationError(Deployment.spec.template.spec.containers[0]): unknown field "resource" in io.k8s.api.core.v1.Container
```

### 5.2 Dependencias

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

`helm dependency build` instala exactamente lo que fija `Chart.lock` — ese es el comando de CI. `helm dependency update` vuelve a resolver y reescribe el lock — ese es el comando humano. Usar `update` en CI destruye la reproducibilidad.

### 5.3 Instalar, actualizar, inspeccionar

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

`helm get values` sin `--all` muestra solo lo que suministró el operador — es la forma más rápida de responder "¿qué está realmente sobrescrito en prod?".

**Siempre hacé diff antes de actualizar.** El plugin `helm-diff` no es opcional en un entorno de producción:

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

### 5.4 Rollback y desinstalación

```console
$ helm rollback checkout 1 -n payments --wait --timeout 5m
Rollback was a success! Happy Helming!

$ helm history checkout -n payments
REVISION	UPDATED                 	STATUS    	CHART             	APP VERSION	DESCRIPTION
1       	Thu Sep  3 09:14:22 2026	superseded	checkout-api-1.9.0	2.32.0     	Install complete
2       	Thu Sep  3 10:02:11 2026	superseded	checkout-api-1.9.1	2.32.1     	Upgrade complete
3       	Thu Sep  3 10:31:56 2026	deployed  	checkout-api-1.9.0	2.32.0     	Rollback to 1
```

El rollback crea una **nueva revisión** — el historial es solo de agregado, nunca se reescribe. Eso es lo que hace confiable el rastro de auditoría.

```console
$ helm uninstall checkout -n payments --keep-history
release "checkout" uninstalled

$ helm list -n payments --uninstalled
NAME    	NAMESPACE	REVISION	UPDATED                              	STATUS    	CHART             	APP VERSION
checkout	payments 	4       	2026-09-03 11:07:02.9012 +0000 UTC   	uninstalled	checkout-api-1.9.0	2.32.0
```

`--keep-history` deja el registro de la release para que `helm rollback` pueda resucitar la aplicación. Sin eso, los Secrets de la release se borran y la release desaparece. Los objetos anotados con `helm.sh/resource-policy: keep` sobreviven a la desinstalación de todos modos — la protección estándar para objetos `PersistentVolumeClaim`.

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

## 6. Distribución: repositorios, OCI, procedencia, post-rendering

### 6.1 Repositorios HTTP clásicos

Un repositorio de charts es un servidor web estático que aloja archivos `.tgz` y un `index.yaml`:

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

`helm search repo` consulta tus índices cacheados localmente; `helm search hub` consulta Artifact Hub por red. Una caché desactualizada es la razón por la que `helm search repo` "no encuentra" una versión que existe — `helm repo update` primero, siempre.

### 6.2 Registries OCI — el default actual

Desde Helm 3.8 el soporte OCI es GA y es la dirección del camino: un registry para imágenes y charts, un modelo de autenticación, una política de retención, una historia de firma.

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

**No hay `index.yaml` en el modelo OCI** — el listado de tags del registry *es* el índice. En consecuencia, `helm search repo` no funciona contra OCI; el descubrimiento usa la API del registry (`crane ls`, `oras repo tags`, o la UI del registry). Los tags de chart deben ser SemVer válido, porque Helm mapea la versión del chart directamente al tag OCI; un sufijo de metadata `+build` se reescribe a `_` porque `+` es ilegal en un tag.

Media types usados: config `application/vnd.cncf.helm.config.v1+json`, capa de chart `application/vnd.cncf.helm.chart.content.v1.tar+gzip`, capa de procedencia `application/vnd.cncf.helm.chart.provenance.v1.prov`.

### 6.3 Procedencia y firma

El mecanismo nativo de Helm es una firma PGP separada sobre el digest SHA-256 del chart y su `Chart.yaml`:

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

El `--keyring` debe ser un keyring en **formato GnuPG v1**; GnuPG moderno usa un keybox, así que hay que exportar primero: `gpg --export-secret-keys > ~/.gnupg/secring.gpg`.

Para charts alojados en OCI, el ecosistema prefiere cada vez más **Sigstore/cosign**, porque firma el digest del manifiesto con el mismo tooling y motor de políticas que se usa para las imágenes de contenedor:

```console
$ cosign sign --yes registry.example.io/charts/checkout-api:1.9.0
$ cosign verify \
    --certificate-identity-regexp '^https://git\.example\.io/payments/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.io/charts/checkout-api:1.9.0
```

Aplicalo en admisión (Kyverno/Gatekeeper/policy-controller) en lugar de confiar en que cada operador se acuerde de `--verify`.

### 6.4 Post-renderers — parchear charts upstream sin forkear

Un post-renderer es cualquier ejecutable que lee el manifiesto renderizado por stdin y escribe el manifiesto modificado por stdout. Combinado con Kustomize elimina casi toda razón para forkear un chart de terceros.

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

Helm registra el manifiesto **post-renderizado** en el Secret de la release, así que tanto `helm get manifest` como el merge a tres vías ven la forma parcheada. `path: /spec/template/metadata/annotations/example.io~1owner` muestra el escapado de JSON Pointer — un `/` dentro de una clave se escribe `~1`, y `~` es `~0`.

---

## 7. Kustomize

### 7.1 Modelo

Kustomize toma un conjunto de manifiestos válidos (una *base*) y aplica transformaciones tipadas (un *overlay*). No hay variables ni lenguaje de templates: cada archivo de entrada es un manifiesto que `kubectl apply -f` aceptaría por sí solo. La salida es el conjunto transformado. Kustomize viene integrado en `kubectl` (`kubectl kustomize`, `kubectl apply -k`), y también se distribuye como binario independiente — el binario standalone suele ir varias versiones adelante, lo que importa para campos nuevos.

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

Notá que `scaleTargetRef.name: checkout-api` *no* lleva el prefijo puesto a mano. El transformador integrado `nameReference` de Kustomize sabe que el `scaleTargetRef.name` de un HPA apunta a un Deployment y lo reescribe a `prod-checkout-api` automáticamente. Este grafo de referencias de nombres es el valor central de Kustomize sobre `sed`, y cubre ServiceAccounts en pod specs, nombres de ConfigMap/Secret en volúmenes y `envFrom`, servicios de backend de Ingress, y más.

`components/tracing/kustomization.yaml` — un *component* es un fragmento de overlay que puede componerse en varios overlays:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

patches:
  - path: patch-otel-sidecar.yaml
    target:
      kind: Deployment
```

### 7.4 Generadores, hashes y semántica de rollout

`configMapGenerator` y `secretGenerator` agregan un hash del contenido al nombre del objeto:

```console
$ kubectl kustomize overlays/prod-eu-west-1 | grep -A3 '^  name: prod-checkout-config'
  name: prod-checkout-config-9f6h2tk84d
```

Como la referencia de volumen del Deployment se reescribe al nombre con hash, **cambiar el contenido del ConfigMap cambia el pod template y dispara un rollout automáticamente**. Esta es la respuesta de Kustomize a la anotación `checksum/config`, y es estrictamente mejor: además garantiza que un pod que hace rollback obtenga la configuración correspondiente.

El costo es basura: los ConfigMaps con hash viejos se acumulan para siempre a menos que haya pruning en juego. Poner `disableNameSuffixHash: true` evita la basura y **elimina silenciosamente el disparador de rollout** — el clásico incidente "cambié la config y no pasó nada".

### 7.5 `includeSelectors` — la mina de la inmutabilidad

El campo deprecado `commonLabels` inyecta labels en `Deployment.spec.selector` y `Service.spec.selector` además de en la metadata. `spec.selector` en un Deployment es **inmutable**. Agregar una entrada de `commonLabels` a un overlay que ya tiene un Deployment vivo produce, por lo tanto, un error imposible de arreglar con apply y fuerza un borrado/recreación — una caída.

El campo moderno `labels:` deja `includeSelectors` en `false` por defecto, que es lo correcto. Definí los labels del selector una sola vez, en la base, y no los cambies nunca. Si tenés que agregar un label de selector a una carga de trabajo viva, el único camino seguro es un renombre blue/green.

### 7.6 CLI de Kustomize

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

`kubectl diff` sale con código 1 cuando hay una diferencia — eso es una funcionalidad, no una falla. En CI, `kubectl diff -k … ; [ $? -le 1 ]` es la guarda correcta.

**Inflar un chart de Helm dentro de Kustomize** requiere el binario standalone; `kubectl kustomize` se niega porque no invoca ejecutables externos:

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

Este camino usa `helm template` internamente — **no hay objeto de release ni `helm rollback`**. Cambiás el ciclo de vida de Helm por las transformaciones de Kustomize.

---

## 8. Elegir entre ambos: una matriz de decisión

| Situación | Usar | Por qué |
|---|---|---|
| Componente de terceros (ingress, cert-manager, Prometheus) | Helm | Upstream distribuye un chart; necesitás una desinstalación limpia |
| Componente de terceros que necesita un campo no soportado | Helm + `--post-renderer` | Evita forkear; el patch sobrevive a los upgrades |
| Tu propio microservicio, 3–8 entornos | Kustomize | Las bases siguen siendo YAML válido; sin depurar templates |
| Tu propio servicio publicado a otros equipos | Helm | Artefacto versionado, values como contrato de API, validado por esquema |
| Config que debe disparar un rollout al cambiar | Generadores de Kustomize, o `checksum/config` de Helm | Ambos funcionan; los generadores además corrigen la corrección del rollback |
| Necesita un deploy atómico, todo o nada, con reversión automática | `--atomic` de Helm | Nada más lo ofrece de fábrica |
| Topología condicional compleja a lo largo de decenas de clústeres | Jsonnet/Tanka o herramientas basadas en CUE | Los templates de Go se degradan pasadas ~5 condiciones anidadas |
| Reconciliado continuamente, con operaciones day-2 | Operator + OLM | Solo un controlador puede hacer backups, failover, upgrades conscientes de versión |

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Escalera de verificación — ejecutar en este orden

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

### 9.2 Catálogo de fallas

**`another operation (install/upgrade/rollback) is in progress`**

```console
$ helm upgrade checkout charts/checkout-api -n payments -f env/prod/values.yaml
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

La ejecución anterior fue matada (timeout de CI, `Ctrl-C`, runner desalojado) dejando la release en `pending-upgrade`. Helm no tiene timeout de lock; el estado queda trabado hasta que lo limpies.

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

Alguien agregó un label dependiente de la versión a `selectorLabels`. Ningún flag de `helm upgrade` arregla esto — `--force` emite un reemplazo, que falla la misma validación. Los remedios, en orden de preferencia:

1. Revertir el cambio del chart para que el selector coincida con el objeto vivo.
2. Blue/green: desplegar bajo un nuevo nombre de release, mover el tráfico, borrar la release vieja.
3. Último recurso, con ventana de caída: `kubectl delete deploy/... --cascade=orphan`, después hacer el upgrade para que Helm adopte los pods huérfanos, y dejar que el nuevo ReplicaSet tome el control.

La misma clase cubre `StatefulSet` (solo `replicas`, `template`, `updateStrategy`, `persistentVolumeClaimRetentionPolicy`, `minReadySeconds` y `ordinals` son mutables), `Job.spec.template`, `Service.spec.clusterIP`, y la reducción de `PVC.spec.resources.requests.storage`.

**`no matches for kind … in version …`**

```console
$ helm install checkout charts/checkout-api -n payments -f env/prod/values.yaml
Error: INSTALLATION FAILED: unable to build kubernetes objects from release manifest: resource mapping not found for name: "checkout-limits" namespace: "payments" from "": no matches for kind "RateLimitPolicy" in version "policies.example.io/v1alpha1"
ensure CRDs are installed first
```

Helm convierte todo el manifiesto renderizado en objetos tipados *antes* de aplicar nada, así que un CR cuyo CRD todavía no está registrado hace fallar la instalación entera — incluso si el CRD está en el mismo chart, si vive en `templates/` en lugar de `crds/`.

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

`.Capabilities.APIVersions` se puebla del documento de discovery del clúster vivo y está **vacío en `helm template`** salvo que pases `--api-versions policies.example.io/v1alpha1`. Ese flag es esencial en pipelines de renderizado en CI.

**`exists and cannot be imported into the current release`**

```console
$ helm install checkout charts/checkout-api -n payments -f env/prod/values.yaml
Error: INSTALLATION FAILED: Unable to continue with install: Service "checkout-checkout-api" in namespace "payments" exists and cannot be imported into the current release: invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"; annotation validation error: missing key "meta.helm.sh/release-name": must be set to "checkout"; annotation validation error: missing key "meta.helm.sh/release-namespace": must be set to "payments"
```

Un objeto creado fuera de Helm (o por un despliegue previo no-Helm) bloquea la instalación. Helm **adoptará** cualquier objeto que lleve la metadata de propiedad correcta:

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

Este truco de tres anotaciones es el camino de migración soportado desde manifiestos hechos a mano hacia Helm sin borrar objetos vivos que están sirviendo tráfico.

**El YAML renderizado está sintácticamente roto**

```console
$ helm template checkout charts/checkout-api -f env/prod/values.yaml
Error: YAML parse error on checkout-api/templates/deployment.yaml: error converting YAML to JSON: yaml: line 61: mapping values are not allowed in this context
```

El número de línea se refiere al archivo *renderizado*, no a tu template. `--debug` imprime la salida renderizada junto con el error:

```console
$ helm template checkout charts/checkout-api -f env/prod/values.yaml --debug 2>&1 | sed -n '55,65p'
        resources:
        limits:
            memory: 512Mi
          requests:
            cpu: 250m
```

Acá `toYaml . | nindent 10` debería haber sido `nindent 12`. Regla práctica: `nindent` para el bloque completo (emite el salto de línea inicial), `indent` solo cuando el salto de línea ya está presente, y siempre usá `include` en lugar de `template` al hacer pipe — `template` es una sentencia y no se puede pipear.

**Fallas de hooks y recursos de hook huérfanos**

```console
$ helm upgrade checkout charts/checkout-api -n payments -f env/prod/values.yaml --atomic
Error: UPGRADE FAILED: pre-upgrade hooks failed: 1 error occurred:
	* job checkout-checkout-api-migrate failed: BackoffLimitExceeded

$ kubectl -n payments logs job/checkout-checkout-api-migrate --tail=20
migrate: applying 0042_add_settlement_ref.sql
ERROR: relation "settlement" does not exist (SQLSTATE 42P01)
migrate: rollback complete
```

El Deployment nunca fue tocado — el hook hizo su trabajo. Notá que con `hook-delete-policy: before-hook-creation,hook-succeeded`, un Job *fallido* se deja deliberadamente atrás para que puedas leer sus logs; se borra al inicio del siguiente intento.

**El Secret de la release excede el límite de objeto de etcd**

```console
$ helm install big-operator ./big-operator -n platform
Error: create: failed to create: Secret "sh.helm.release.v1.big-operator.v1" is invalid: data: Too long: may not be more than 1048576 bytes
```

El chart comprimido más el manifiesto renderizado exceden 1 MiB. Mitigaciones: mover los CRDs a `crds/` (se instalan fuera del manifiesto templado), recortar `.helmignore` para que fixtures de test y documentación no se empaqueten, dividir el chart, o instalar los CRDs por separado con `--skip-crds`.

**Un patch de Kustomize que no apunta a nada**

```console
$ kustomize build overlays/prod-eu-west-1
Error: no matches for Id apps_v1_Deployment|payments|checkout-apy; failed to find unique target for patch apps_v1_Deployment|checkout-apy
```

Un patch JSON6902 con un target que no coincide es un error. Un **strategic merge patch listado bajo el deprecado `patchesStrategicMerge` sin recurso coincidente se ignora silenciosamente** en algunas versiones — por eso todo patch debería escribirse bajo `patches:` con un `target:` explícito. Verificá con:

```console
$ kubectl kustomize overlays/prod-eu-west-1 | yq '. | select(.kind=="Deployment") | .spec.template.spec.containers[0].resources'
{"requests":{"cpu":"400m","memory":"384Mi"},"limits":{"memory":"768Mi"}}
```

**Sorpresas al fusionar listas en Kustomize**

Un strategic merge patch fusiona las listas de contenedores por la clave `name`, así que parchear `containers[].env` **reemplaza la lista `env` completa** de ese contenedor en lugar de agregarle elementos — `env` tiene `patchMergeKey: name` con `patchStrategy: merge`, pero solo cuando ambos lados son procesados por la lógica de strategic merge contra un tipo de Go conocido. Para custom resources, Kustomize no tiene esquema y cae a reemplazar las listas por completo. Cuando necesitás ediciones quirúrgicas de listas en un CR, usá JSON6902 con un índice explícito o `-` (agregar al final):

```yaml
- op: add
  path: /spec/rules/-
  value:
    host: checkout.eu-west-1.example.io
```

**Podar recursos eliminados**

Ni `kubectl apply -f` ni `kubectl apply -k` borran los objetos que sacaste de la fuente — la mayor brecha operativa frente a Helm. Opciones:

```console
# ApplySet-based pruning (alpha/beta depending on your kubectl and cluster;
# behind an env gate). Verify support before relying on it in production.
$ KUBECTL_APPLYSET=true kubectl apply -k overlays/prod-eu-west-1 \
    --prune --applyset=configmaps/checkout-applyset --namespace payments

# Or let a GitOps controller own pruning: Argo CD `prune: true`, Flux `prune: true`.
```

**Cadenas de salida dependientes de la versión.** La redacción exacta de los mensajes de error de Helm y Kustomize cambia entre versiones menores. Hacé coincidir la *forma* del error — "immutable", "already exists / cannot be imported", "another operation in progress", "no matches for kind" — no la cadena literal, y nunca en una verificación automatizada.

### 9.3 Inspeccionar el objeto de release directamente

Cuando `helm` mismo se comporta mal, leé el Secret:

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

## 10. Gestión de paquetes bajo GitOps

Ambos controladores consumen charts, pero con semánticas fundamentalmente distintas — esto determina si los hooks de Helm y `lookup` funcionan siquiera.

| Aspecto | Argo CD | Flux (`HelmRelease`) |
|---|---|---|
| Mecanismo | ejecuta `helm template` y luego aplica la salida él mismo | ejecuta acciones reales de Helm vía el SDK de Helm |
| Secret de release en el clúster | **no** | **sí** |
| `helm ls` lo muestra | no | sí |
| Hooks de Helm | no se ejecutan (Argo los mapea a sus propios sync hooks) | se ejecutan normalmente |
| `lookup` | devuelve vacío | funciona (conexión real al clúster) |
| `helm rollback` | n/a — Argo revierte re-sincronizando el commit de Git | sí, más `remediation` automática en caso de falla |
| Corrección de drift | continua, vía su propio diff | vía `driftDetection` |

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

**Consecuencia arquitectónica:** un chart que depende de hooks para la migración de esquema se comporta correctamente bajo Flux y saltea silenciosamente la migración bajo Argo CD salvo que además anotes el Job con `argocd.argoproj.io/hook: PreSync`. Los charts pensados para ambos deben llevar los dos conjuntos de anotaciones — no entran en conflicto.

---

## 11. Qué hay que saber hacer sin ayuda

- Explicar `version` vs `appVersion`, y `apiVersion: v2` vs `v1` en `Chart.yaml`.
- Nombrar cada directorio de un chart y decir qué hacen `crds/`, `templates/_*.tpl` y `charts/`.
- Enunciar el orden completo de precedencia de values y predecir el resultado de `helm upgrade` cuando se pasa `-f` sin `--reuse-values`.
- Agregar un repositorio, buscarlo, instalar una versión específica de un chart, actualizar, inspeccionar el historial y hacer rollback.
- Leer `helm get values`, `helm get manifest` y `helm get hooks`, y decir qué prueba cada uno.
- Explicar dónde almacena Helm 3 el estado de la release y por qué no hay Tiller.
- Escribir un Job de hook con las anotaciones `hook`, `hook-weight` y `hook-delete-policy` correctas, y explicar por qué la delete policy es necesaria para la idempotencia.
- Empaquetar, firmar, verificar y publicar un chart tanto en un repositorio HTTP como en un registry OCI.
- Construir una base y un overlay de Kustomize, aplicar un strategic-merge patch y un patch JSON6902, y usar un `configMapGenerator`.
- Explicar por qué los hashes de los generadores causan rollouts, y qué rompe `disableNameSuffixHash: true`.
- Explicar por qué `commonLabels` / `includeSelectors: true` pueden romper un Deployment existente.
- Diagnosticar: lock de pending-upgrade, falla por campo inmutable, falla de render por CRD faltante, y el error de adopción por metadata de propiedad.

---

## 12. Referencias

**Objetivos del examen**
- LPI DevOps Tools Engineer, objetivos del Examen 701 — https://www.lpi.org/our-certifications/exam-701-objectives/

**Helm**
- Índice de la documentación de Helm — https://helm.sh/docs/
- Charts (estructura, `Chart.yaml`, dependencias, archivos de esquema) — https://helm.sh/docs/topics/charts/
- Chart Template Guide — https://helm.sh/docs/chart_template_guide/
- Objetos integrados y funciones de template — https://helm.sh/docs/chart_template_guide/builtin_objects/ · https://helm.sh/docs/chart_template_guide/function_list/
- Chart hooks — https://helm.sh/docs/topics/charts_hooks/
- Chart tests — https://helm.sh/docs/topics/chart_tests/
- Library charts — https://helm.sh/docs/topics/library_charts/
- Repositorios de charts — https://helm.sh/docs/topics/chart_repository/
- Registries OCI — https://helm.sh/docs/topics/registries/
- Procedencia e integridad — https://helm.sh/docs/topics/provenance/
- Temas avanzados (post-renderers, `lookup`, backends de almacenamiento) — https://helm.sh/docs/topics/advanced/
- Custom Resource Definitions en charts — https://helm.sh/docs/chart_best_practices/custom_resource_definitions/
- Buenas prácticas de charts — https://helm.sh/docs/chart_best_practices/
- Referencia de `helm upgrade` (`--atomic`, `--reuse-values`, `--history-max`) — https://helm.sh/docs/helm/helm_upgrade/
- Referencia de `helm rollback` — https://helm.sh/docs/helm/helm_rollback/
- Referencia de `helm template` (`--api-versions`, `--show-only`, `--validate`) — https://helm.sh/docs/helm/helm_template/
- Cambios desde Helm 2 (merge a tres vías, almacenamiento de releases) — https://helm.sh/docs/faq/changes_since_helm2/
- Código fuente (kind sorter, lógica de values en upgrade) — https://github.com/helm/helm

**Kustomize**
- Referencia del archivo kustomization — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/
- Patches (`patches`, SMP, JSON6902) — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/patches/
- Generadores (`configMapGenerator`, `secretGenerator`) — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/
- `labels` y `commonLabels` — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/labels/
- Components — https://kubectl.docs.kubernetes.io/guides/config_management/components/
- Gestión declarativa con Kustomize — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Código fuente — https://github.com/kubernetes-sigs/kustomize

**Kubernetes**
- Server-Side Apply y gestión de campos — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Gestión declarativa con `kubectl apply` (merge a tres vías) — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- CustomResourceDefinitions — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Labels recomendados — https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
- Referencia de `kubectl` — https://kubernetes.io/docs/reference/kubectl/

**Distribución, firma, GitOps**
- Artifact Hub — https://artifacthub.io/
- OCI Distribution Specification — https://github.com/opencontainers/distribution-spec
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/
- `HelmRelease` de Flux — https://fluxcd.io/flux/components/helm/helmreleases/
- Argo CD y Helm — https://argo-cd.readthedocs.io/en/stable/user-guide/helm/
- Operator Lifecycle Manager — https://olm.operatorframework.io/docs/
- kubeconform — https://github.com/yannh/kubeconform
- Plugin helm-diff — https://github.com/databus23/helm-diff