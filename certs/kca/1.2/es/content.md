# Tema 1.2 — YAML Manifests (KCA)

> Perfil: SRE / Platform Architect. Peso en examen: 4.5. El objetivo de este tema no es "aprender a escribir un YAML", sino entender que el manifiesto **es** el contrato con la API de Kubernetes, que YAML es un lenguaje con semántica de tipos propia (y trampas serias en producción), y que la diferencia entre `create`, `apply` y Server-Side Apply define quién es dueño de cada campo de un objeto vivo.

---

## 1. Motivación y problema arquitectónico de producción

Kubernetes es un **sistema declarativo con reconciliación continua**. No le decís "creá 3 pods"; le declarás "quiero que existan 3 réplicas" y un bucle de control (el `controller-manager`) trabaja permanentemente para que el **estado observado** (`status`) converja al **estado deseado** (`spec`). El manifiesto YAML es la representación serializada de ese estado deseado.

El problema arquitectónico que esto resuelve es el de la **fuente de verdad reproducible**. En un sistema imperativo (`kubectl run`, `kubectl scale`, `kubectl expose`) el estado del cluster es el resultado acumulado de una secuencia de comandos que nadie registró, no es auditable, no es revisable en un PR, y no se puede recrear en otro cluster. El manifiesto declarativo invierte eso:

```
Git (manifiestos) ──apply──> API Server ──persist──> etcd
                                  │
                                  ▼
                          Controllers (reconcile loop)
                                  │
                                  ▼
                     Estado real del cluster (status)
```

Esto es el fundamento de **GitOps**: el repositorio Git es la fuente de verdad, un agente (Argo CD, Flux) hace `apply` continuo, y cualquier *drift* (un `kubectl edit` manual en producción) se detecta y se revierte porque el estado real dejó de coincidir con el manifiesto versionado.

**Por qué YAML y no otra cosa.** La API de Kubernetes es JSON puro sobre HTTP; YAML es solo la capa de autoría humana. `kubectl` toma tu YAML, lo convierte a JSON (vía `sigs.k8s.io/yaml`) y lo envía al API Server. YAML gana como formato de autoría por tres razones: admite comentarios (JSON no), permite multi-documento en un solo archivo, y su indentación reduce el ruido sintáctico de llaves y comillas. El costo es que **YAML tiene inferencia de tipos**, y ahí viven la mayoría de los bugs de producción de este tema (sección 3).

---

## 2. Anatomía de un manifiesto: el contrato con la API

Todo objeto de Kubernetes comparte cuatro campos de nivel superior. Son obligatorios (salvo `status`, que es de solo lectura para el usuario):

```yaml
apiVersion: apps/v1        # Group/Version: identifica el esquema y su estabilidad
kind: Deployment           # El tipo de recurso dentro de ese Group/Version
metadata:                  # Identidad y datos organizativos del objeto
  name: web
  namespace: production
  labels:
    app: web
  annotations:
    kubernetes.io/change-cause: "rollout v2.3.1"
spec:                      # Estado DESEADO — lo que vos declarás
  replicas: 3
status:                    # Estado OBSERVADO — lo escribe el controller, NO vos
  availableReplicas: 3
```

### 2.1 Group / Version / Kind (GVK)

`apiVersion` codifica **grupo** y **versión**:

| `apiVersion` | Grupo | Significado |
|---|---|---|
| `v1` | core (grupo vacío) | Pod, Service, ConfigMap, Secret, Namespace, PVC |
| `apps/v1` | `apps` | Deployment, StatefulSet, DaemonSet, ReplicaSet |
| `batch/v1` | `batch` | Job, CronJob |
| `networking.k8s.io/v1` | `networking.k8s.io` | Ingress, NetworkPolicy |
| `rbac.authorization.k8s.io/v1` | RBAC | Role, RoleBinding, ClusterRole |

El sufijo de versión indica **madurez y garantías de compatibilidad**:

| Sufijo | Ejemplo | Estabilidad | Garantía |
|---|---|---|---|
| `v1alpha1` | `flowcontrol.apiserver.k8s.io/v1alpha1` | Alpha | Puede desaparecer sin aviso; deshabilitado por defecto |
| `v1beta1` | `policy/v1beta1` | Beta | Puede cambiar; **históricamente** habilitado por defecto |
| `v1` | `apps/v1` | Estable (GA) | Compatibilidad mantenida durante toda la vida de la major |

> **Nota de producción:** desde la política de deprecación de APIs, apoyarse en `beta`/`alpha` es deuda técnica: `extensions/v1beta1 Ingress` y `policy/v1beta1 PodSecurityPolicy` fueron **removidos**, no solo deprecados. Fijar siempre la `apiVersion` GA disponible en tu versión de cluster.

La tripleta (Group, Version, Kind) es el **GVK**. El API Server lo mapea a un **GVR** (Group, Version, Resource) — el `Resource` es el nombre en plural y minúsculas del endpoint REST (`deployments`). Ese mapeo es lo que `kubectl api-resources` expone.

### 2.2 Cómo `kubectl` procesa el manifiesto

```
YAML ──(sigs.k8s.io/yaml)──> JSON ──> POST/PATCH /apis/apps/v1/namespaces/production/deployments
                                          │
                              admission (mutating → validating) ──> etcd
```

Detalle crítico: **Kubernetes convierte YAML a JSON antes de validar tipos**. Esto significa que las trampas de tipado de YAML (sección 3) se resuelven en el parser de YAML, *antes* de que la API vea nada. Un `no` que YAML convirtió a `false` llega a la API ya como booleano JSON; la API nunca vio el string `"no"`.

---

## 3. YAML como lenguaje: mecánica interna y trampas de producción

YAML tiene tres estructuras de nodo: **scalars** (valores), **sequences** (listas) y **mappings** (diccionarios). La indentación con **espacios** (nunca tabs) define la jerarquía.

```yaml
# mapping
metadata:
  name: web            # scalar string
  replicas: 3          # scalar int
# sequence de mappings
containers:
  - name: app          # el guion inicia un elemento
    image: nginx:1.27
  - name: sidecar
    image: envoy:1.31
```

### 3.1 El problema de la inferencia de tipos (la trampa más peligrosa)

El parser de YAML de Kubernetes (go-yaml v2, semántica **YAML 1.1**) infiere el tipo de un escalar sin comillas. Esto produce coerciones silenciosas:

| Escribís | YAML lo interpreta como | Consecuencia |
|---|---|---|
| `country: NO` | booleano `false` | El famoso **"Norway problem"** |
| `enabled: yes` | booleano `true` | `y, yes, on, true` → true (y variantes en mayúsculas) |
| `version: 1.10` | float `1.1` | ¡Se pierde el `0`! Un tag de imagen se corrompe |
| `build: 010` | octal `8` (en 1.1) | Ceros a la izquierda = octal |
| `time: 22:22` | sexagesimal (base 60) → `1342` | Times y ratios se destruyen |
| `zip: 08540` | error / octal inválido | El `8` no es dígito octal válido |
| `sha: 0xFF` | entero `255` | Prefijo hex |
| `value:` (vacío) | `null` | No es string vacío |

**Booleanos YAML 1.1 completos que coercionan:** `y Y yes Yes YES n N no No NO true True TRUE false False FALSE on On ON off Off OFF`.

**Caso real de fallo:**

```yaml
# ❌ MAL — el port label termina siendo el booleano false
metadata:
  labels:
    environment: no          # -> false, y los labels DEBEN ser strings -> error de validación
    release: 1.10            # -> "1.1" tras round-trip (drift silencioso)
```

```yaml
# ✅ BIEN — forzar string con comillas
metadata:
  labels:
    environment: "no"
    release: "1.10"
```

> **Regla de oro SRE:** todo valor que **debe** ser string (versiones, tags de imagen, códigos de país, IDs numéricos, valores de ConfigMap) va **entre comillas**. Los valores en `data:` de un ConfigMap **deben** ser strings; `data: { replicas: 3 }` es un error de validación — usar `replicas: "3"`.

### 3.2 Comillas: simples vs dobles

| Estilo | Escapes | Interpola | Uso |
|---|---|---|---|
| Sin comillas | — | — | Solo cuando el tipo inferido es el correcto |
| `'simples'` | Solo `''` → `'` | No | String literal; nada se interpreta |
| `"dobles"` | `\n \t \" \\` etc. | Sí | Cuando necesitás secuencias de escape |

```yaml
a: 'C:\path'          # backslash literal
b: "line1\nline2"     # salto de línea real
c: 'it''s here'       # comilla simple escapada
```

### 3.3 Block scalars: literal `|` y folded `>` (y chomping)

Fundamentales para meter scripts o archivos de config dentro de un ConfigMap sin destruir los saltos de línea:

```yaml
data:
  # LITERAL: preserva cada salto de línea tal cual
  nginx.conf: |
    server {
      listen 80;
      location / { proxy_pass http://backend; }
    }

  # FOLDED: los saltos simples se convierten en espacios; línea en blanco = salto real
  description: >
    Este texto largo
    se pliega en una sola línea.

  # LITERAL con strip (-): elimina el salto final. Sin él, queda un \n al final.
  token: |-
    eyJhbGciOiJIUzI1NiJ9
```

**Indicadores de chomping** (controlan los saltos de línea finales):

| Indicador | Nombre | Efecto en el `\n` final |
|---|---|---|
| `|` / `>` | clip (default) | Deja **un solo** `\n` |
| `|-` / `>-` | strip | Elimina **todos** los `\n` finales |
| `|+` / `>+` | keep | Conserva **todos** los `\n` finales |

> Trampa: un `token: |` (clip) mete un `\n` al final del secret; si es una API key, la autenticación falla silenciosamente. Para credenciales usar siempre `|-`.

### 3.4 Anchors (`&`), aliases (`*`) y merge keys (`<<`)

Permiten DRY dentro de un mismo documento. Muy usado en `docker-compose` y helpers; **soportado por el parser de Kubernetes** pero con una advertencia:

```yaml
# Define un anchor
resources: &default-resources
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 256Mi }

containers:
  - name: app
    resources: *default-resources         # alias: copia el nodo entero
  - name: sidecar
    resources:
      <<: *default-resources              # merge key: hereda y sobreescribe
      limits: { cpu: 200m, memory: 64Mi } # override parcial
```

> **Advertencia de producción:** los anchors se resuelven **en el parser, antes de llegar a la API**. El objeto que queda en etcd ya está "aplanado" — Kubernetes no sabe que existió el anchor. Por eso GitOps con anchors es frágil (el `kubectl get -o yaml` no muestra anchors) y por eso las herramientas de plantillado (Kustomize, Helm) son preferibles a los anchors para reutilización real. Además, los anchors habilitan el ataque **"YAML bomb" / billion laughs** (expansión exponencial); los parsers serios limitan la profundidad.

### 3.5 Multi-documento (`---`) y `...`

Un solo archivo puede contener varios objetos separados por `---`. Es la forma idiomática de agrupar recursos relacionados:

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: web-config }
data: { LOG_LEVEL: "info" }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: web }
spec: { replicas: 3, selector: { matchLabels: { app: web } }, template: {} }
```

`kubectl apply -f archivo.yaml` aplica **todos** los documentos en orden. Un documento vacío entre `---` (por ejemplo, generado por un template Helm cuando una condición es falsa) es válido y se ignora.

---

## 4. Comparativas técnicas (tablas de trade-offs)

### 4.1 YAML vs JSON como formato de manifiesto

| Criterio | YAML | JSON |
|---|---|---|
| Comentarios | Sí (`#`) | No |
| Multi-documento | Sí (`---`) | No (un objeto raíz) |
| Inferencia de tipos | **Sí (peligrosa)** | No (tipos explícitos) |
| Verbosidad | Baja | Alta |
| Sensible a indentación | Sí (fuente de bugs) | No |
| Ambigüedad de parseo | Alta (Norway problem) | Nula |
| Uso en Kubernetes | Autoría humana | Transporte API / `-o json` |

**Conclusión SRE:** autorás en YAML, pero para *scripting* y validación programática convertí a JSON (`kubectl get -o json | jq`), donde no hay ambigüedad de tipos.

### 4.2 Imperativo vs Declarativo

| Aspecto | Imperativo (`create`, `run`, `scale`, `edit`) | Declarativo (`apply`) |
|---|---|---|
| Qué expresa | *Cómo* (acciones) | *Qué* (estado final) |
| Fuente de verdad | El cluster (efímera) | El manifiesto en Git |
| Idempotencia | No (`create` falla si existe) | Sí (`apply` converge) |
| Auditabilidad | Nula | Total (PR, historia Git) |
| GitOps | Incompatible | Base del modelo |
| Uso recomendado | Debug, one-off, aprender | **Producción** |

### 4.3 `create` vs `apply` vs `replace`

| Comando | Si NO existe | Si YA existe | Preserva campos de otros? | Merge |
|---|---|---|---|---|
| `kubectl create` | Lo crea | **Error** `AlreadyExists` | — | — |
| `kubectl apply` | Lo crea | Hace **merge** de cambios | **Sí** | 3-way |
| `kubectl replace` | **Error** `NotFound` | **Reemplaza entero** (destructivo) | **No** | ninguno |

`replace` es un `PUT`: sobreescribe el objeto completo y **descarta** cualquier campo que el manifiesto no incluya (por ejemplo, valores que un webhook o autoscaler haya escrito). `apply` es un `PATCH` inteligente.

### 4.4 Client-Side Apply (CSA) vs Server-Side Apply (SSA)

| Aspecto | Client-Side Apply | Server-Side Apply (`--server-side`) |
|---|---|---|
| Dónde ocurre el merge | En `kubectl` (cliente) | En el **API Server** |
| Cómo recuerda el estado previo | Annotation `last-applied-configuration` | Campo `.metadata.managedFields` |
| Tipo de merge | 3-way (previo + live + nuevo) | Field-level, por *field manager* |
| Detección de conflictos | No | **Sí** (`--force-conflicts` para forzar) |
| Peso de la annotation | Duplica el objeto en un annotation | No la usa |
| Multi-controlador (Argo + HPA) | Se pisan | **Coexisten** por ownership de campos |
| Recomendación actual | Legacy | **Preferido** en producción/GitOps |

**El problema que resuelve SSA:** con CSA, si un HPA escala tu Deployment a 10 réplicas y luego hacés `apply` de un manifiesto que dice `replicas: 3`, se pisan mutuamente (fight). Con SSA, `replicas` puede ser *ownership* del HPA y tu apply no lo toca si no declarás ese campo. Cada campo tiene un dueño registrado en `managedFields`.

### 4.5 Tipos de patch (para `kubectl patch` y para entender los merges)

| Tipo | Flag | Semántica | Listas |
|---|---|---|---|
| Strategic Merge Patch | `--type strategic` (default) | Conoce el esquema de K8s; hace merge inteligente | Merge por `patchMergeKey` (ej. `name`) |
| JSON Merge Patch (RFC 7386) | `--type merge` | Genérico; reemplaza el valor entero de una clave | **Reemplaza** la lista completa |
| JSON Patch (RFC 6902) | `--type json` | Operaciones `add/remove/replace` por path | Por índice explícito |

```bash
# Strategic: agrega un container sin borrar los existentes (usa el merge key 'name')
kubectl patch deployment web --type strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"web","image":"nginx:1.27"}]}}}}'

# JSON Patch: operación quirúrgica por path
kubectl patch deployment web --type json -p \
  '[{"op":"replace","path":"/spec/replicas","value":5}]'
```

---

## 5. Manifiestos completos (sin recortar)

### 5.1 Stack de producción en un solo multi-documento

```yaml
# ==============================================================
# web-stack.yaml — ConfigMap + Deployment + Service + HPA
# apply: kubectl apply -f web-stack.yaml
# ==============================================================
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
  namespace: production
data:
  LOG_LEVEL: "info"           # comillas: fuerza string
  MAX_CONN: "512"             # sería int sin comillas -> error en data:
  nginx.conf: |               # block literal: preserva formato
    worker_processes auto;
    events { worker_connections 1024; }
    http {
      server {
        listen 8080;
        location /healthz { return 200 'ok'; }
        location / { proxy_pass http://127.0.0.1:3000; }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: production
  labels:
    app: web
    tier: frontend
  annotations:
    kubernetes.io/change-cause: "release 2.3.1"
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0        # zero-downtime
  selector:
    matchLabels:
      app: web                 # DEBE coincidir con template.labels
  template:
    metadata:
      labels:
        app: web
        tier: frontend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: nginx:1.27.2   # tag inmutable, NUNCA :latest en prod
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: web-config
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 15
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: nginx-conf
          configMap:
            name: web-config
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: production
spec:
  type: ClusterIP
  selector:
    app: web                   # enruta a los Pods con este label
  ports:
    - name: http
      port: 80
      targetPort: http         # referencia al puerto POR NOMBRE
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

> **Detalle de ownership (SSA):** cuando el HPA ajusta `spec.replicas`, ese campo pasa a ser propiedad del `hpa` field manager. Si tu manifiesto de GitOps sigue declarando `replicas: 3` bajo Server-Side Apply, generarás un conflicto de campo. **Solución de producción:** eliminá `replicas` del manifiesto una vez que el HPA está activo (dejá que el HPA sea el dueño).

---

## 6. Comandos CLI y salidas de terminal reales

### 6.1 Validación **antes** de aplicar (el paso que la gente saltea)

```console
$ kubectl apply -f web-stack.yaml --dry-run=server
namespace/production created (server dry run)
configmap/web-config created (server dry run)
deployment.apps/web created (server dry run)
service/web created (server dry run)
horizontalpodautoscaler.autoscaling/web created (server dry run)
```

`--dry-run=server` envía el objeto al API Server y ejecuta **admission + validación de esquema** sin persistir. `--dry-run=client` solo valida localmente (no detecta, p. ej., que un webhook rechazará el pod). **En producción usá `server`.**

### 6.2 Ver el diff contra el estado vivo

```console
$ kubectl diff -f web-stack.yaml
diff -u -N /tmp/LIVE-123/apps.v1.Deployment.production.web /tmp/MERGED-456/apps.v1.Deployment.production.web
--- /tmp/LIVE-123/apps.v1.Deployment.production.web
+++ /tmp/MERGED-456/apps.v1.Deployment.production.web
@@ -12,7 +12,7 @@
   template:
     spec:
       containers:
-      - image: nginx:1.27.1
+      - image: nginx:1.27.2
         name: web
$ echo $?
1        # exit code 1 = hay diferencias (útil en CI/CD)
```

### 6.3 Aplicar (Server-Side) y verificar el rollout

```console
$ kubectl apply -f web-stack.yaml --server-side --field-manager=gitops
namespace/production serverside-applied
configmap/web-config serverside-applied
deployment.apps/web serverside-applied
service/web serverside-applied
horizontalpodautoscaler.autoscaling/web serverside-applied

$ kubectl -n production rollout status deployment/web
Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 2 of 3 updated replicas are available...
deployment "web" successfully rolled out
```

### 6.4 Descubrir campos válidos sin salir de la terminal (`explain`)

```console
$ kubectl explain deployment.spec.strategy.rollingUpdate
KIND:       Deployment
VERSION:    apps/v1

FIELD: rollingUpdate <RollingUpdateDeployment>

DESCRIPTION:
    Rolling update config params. Present only if DeploymentStrategyType =
    RollingUpdate.

FIELDS:
  maxSurge      <IntOrString>
    The maximum number of pods that can be scheduled above the desired number...
  maxUnavailable <IntOrString>
    The maximum number of pods that can be unavailable during the update...

$ kubectl explain deployment --recursive | head -20    # árbol completo de campos
```

`kubectl explain` lee el **OpenAPI schema** del propio API Server, así que siempre refleja tu versión exacta de cluster. Es la referencia autoritativa, no la documentación web.

### 6.5 Generar un manifiesto base de forma imperativa (scaffolding)

```console
$ kubectl create deployment web --image=nginx:1.27.2 \
    --dry-run=client -o yaml > web.yaml
$ kubectl create service clusterip web --tcp=80:8080 \
    --dry-run=client -o yaml >> web.yaml
```

Patrón idiomático: usar comandos imperativos con `--dry-run=client -o yaml` para **generar el esqueleto**, luego editarlo y aplicarlo declarativamente. Esto ahorra tiempo en el examen y evita errores de indentación a mano.

### 6.6 Inspeccionar el ownership de campos (SSA)

```console
$ kubectl -n production get deployment web --show-managed-fields -o yaml | \
    yq '.metadata.managedFields[] | {manager: .manager, operation: .operation}'
{"manager": "gitops", "operation": "Apply"}
{"manager": "kube-controller-manager", "operation": "Update"}
{"manager": "hpa", "operation": "Apply"}       # el HPA es dueño de spec.replicas
```

---

## 7. Guía de verificación y diagnóstico de fallas

### 7.1 Herramientas de validación estática (pre-cluster, para CI)

| Herramienta | Qué valida | Necesita cluster |
|---|---|---|
| `kubectl apply --dry-run=client` | Sintaxis + esquema local | No |
| `kubectl apply --dry-run=server` | Esquema + admission + webhooks | Sí |
| `kubeconform` | Contra esquemas OpenAPI (sucesor de kubeval) | No |
| `kustomize build \| kubectl apply` | Renderizado de overlays | No (build) |
| `yamllint` | Estilo y sintaxis YAML pura | No |
| `conftest` / OPA | Políticas custom (Rego) | No |

```console
$ kubeconform -strict -summary web-stack.yaml
Summary: 5 resources found in 1 file - Valid: 5, Invalid: 0, Errors: 0, Skipped: 0
```

### 7.2 Fallas frecuentes, causa y diagnóstico

**A) Error de indentación / tabs**

```console
$ kubectl apply -f web.yaml
error: error parsing web.yaml: error converting YAML to JSON: yaml: line 14:
  found character that cannot start any token
```
> Causa casi siempre: un **tab** en vez de espacios. Diagnóstico: `cat -A web.yaml | grep -nP '\t'` (los tabs aparecen como `^I`). YAML **prohíbe tabs** para indentación.

**B) El selector no coincide con las labels del template**

```console
$ kubectl apply -f web.yaml
The Deployment "web" is invalid: spec.template.metadata.labels:
  Invalid value: map[string]string{"app":"web2"}:
  `selector` does not match template `labels`
```
> Causa: `spec.selector.matchLabels` **debe** ser un subconjunto de `spec.template.metadata.labels`. El selector es inmutable tras crear el Deployment.

**C) El "Norway problem" — un valor booleano donde esperabas string**

```console
$ kubectl apply -f cfg.yaml
The ConfigMap "region" is invalid: data[country]:
  Invalid value: false: a valid config key must consist of alphanumeric characters
```
> Causa: `country: NO` se convirtió en el booleano `false`. Fix: `country: "NO"`.

**D) Cantidad de recursos mal formada**

```console
$ kubectl apply -f web.yaml
Deployment.apps "web" is invalid: spec.template.spec.containers[0].resources.limits[memory]:
  Invalid value: "256M i": ... must match the regex ...
```
> Causa: espacio en `256M i`, o confusión de unidades. Recordar: `Mi`=mebibyte (2^20), `M`=megabyte (10^6). CPU: `500m`=0.5 core. **Nunca** un espacio dentro de la cantidad.

**E) `apply` sobre un objeto creado con `create` (annotation faltante)**

```console
$ kubectl apply -f web.yaml
Warning: resource deployments/web is missing the
  kubernetes.io/last-applied-configuration annotation which is required by
  kubectl apply. kubectl apply should only be used on resources created
  declaratively...
```
> Causa: el objeto se creó imperativamente y no tiene la annotation base para el 3-way merge de CSA. Migrar a Server-Side Apply (`--server-side`) elimina el problema de raíz, porque SSA no usa esa annotation.

**F) Conflicto de field manager (Server-Side Apply)**

```console
$ kubectl apply -f web.yaml --server-side
error: Apply failed with 1 conflict: conflict with "hpa" using autoscaling/v2:
  .spec.replicas
Please review the fields above--they currently have another manager. Resolve
the conflict by:
* using --force-conflicts to overwrite ...
```
> Causa: intentás poseer `spec.replicas`, campo del HPA. **Fix correcto:** quitar `replicas` del manifiesto (no `--force-conflicts`, que solo pospone la pelea).

### 7.3 Checklist de verificación de un manifiesto antes del merge

```console
# 1. Lint puro de YAML
$ yamllint web-stack.yaml

# 2. Validación de esquema sin cluster
$ kubeconform -strict web-stack.yaml

# 3. Validación con admission real
$ kubectl apply -f web-stack.yaml --dry-run=server

# 4. Diff contra producción
$ kubectl diff -f web-stack.yaml

# 5. Aplicar y confirmar convergencia
$ kubectl apply -f web-stack.yaml --server-side --field-manager=gitops
$ kubectl -n production rollout status deploy/web
```

---

## 8. Referencias

- **KCA / KCNA Curriculum (CNCF)** — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- **Kubernetes — Managing Resources (declarative apply)** — https://kubernetes.io/docs/concepts/cluster-administration/manage-deployment/
- **Kubernetes — Declarative Management with Configuration Files** — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- **Kubernetes — Server-Side Apply** — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- **Kubernetes — Object Management with kubectl (imperative vs declarative)** — https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/
- **Kubernetes — Understanding Kubernetes Objects (spec/status)** — https://kubernetes.io/docs/concepts/overview/working-with-objects/kubernetes-objects/
- **Kubernetes — API Versioning & deprecation policy** — https://kubernetes.io/docs/reference/using-api/deprecation-policy/
- **Kubernetes — Update API objects with kubectl patch** — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- **Kubernetes — Resource units (CPU/memory quantities)** — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- **YAML 1.2.2 Specification** — https://yaml.org/spec/1.2.2/
- **kubeconform (validador de esquema)** — https://github.com/yannh/kubeconform
- **Kustomize** — https://kubectl.docs.kubernetes.io/references/kustomize/