# 5.7 Variables y llamadas a la API en las políticas

**Dominio 5 — Aplicación de políticas · Peso en el examen: 2.91**

---

## 1. El problema de producción: la política es código, pero la decisión es dato

Una regla de Kyverno escrita enteramente con literales es una aserción *estática*. Puede responder "¿este Pod tiene `runAsNonRoot: true`?" No puede responder ninguna de las preguntas que realmente generan incidentes en una plataforma multi-tenant:

| Pregunta real de un equipo de plataforma | Por qué fallan los literales |
|---|---|
| "¿Está permitido este registry de imágenes **para este tenant**?" | La allowlist difiere por namespace y cambia semanalmente sin que se libere una política. |
| "¿Este namespace ya tiene 20 Services de tipo LoadBalancer?" | La respuesta vive en el API server, no en el `AdmissionReview`. |
| "¿El namespace está etiquetado `env=prod`?" | El `AdmissionReview` transporta el **objeto**, no el objeto Namespace al que pertenece. Las etiquetas del namespace *no* están en la solicitud. |
| "¿El usuario solicitante realmente tiene permiso para borrar en `kube-system`?" | Requiere un `SubjectAccessReview` — una llamada de **escritura** a la API durante la admisión. |
| "¿La imagen del contenedor corre como UID 0 **en su propia configuración**?" | La respuesta está en el blob de config OCI de la imagen en el registry, no en el manifiesto. |
| "¿Esta excepción de CVE sigue vigente, o expiró?" | Requiere aritmética de fechas contra `now`. |

Kyverno cierra esta brecha con dos mecanismos acoplados:

1. **Variables** — un motor de sustitución basado en JMESPath que inyecta datos de runtime en cualquier campo de la política antes de que la regla sea evaluada.
2. **Context** — una etapa de carga de datos por regla (`context[]`) que trae estado externo (ConfigMaps, la API de Kubernetes, registries, servicios HTTPS arbitrarios, entradas globales cacheadas) al espacio de nombres de las variables.

La consecuencia arquitectónica es lo que hay que internalizar para producción: **`context` se ejecuta sincrónicamente dentro de la ruta de llamada del webhook de admisión.** Cada `apiCall` que agregás es latencia agregada a *toda* escritura de API coincidente en el clúster y — si `failurePolicy: Fail` — una nueva dependencia cuya falla bloquea escrituras en todo el clúster. Las variables convierten a Kyverno de un linter en un componente de sistema distribuido con un presupuesto de latencia y un radio de impacto.

```
                        kube-apiserver
                              │ AdmissionReview (10s webhook timeout)
                              ▼
                 ┌──────────────────────────────┐
                 │ kyverno-admission-controller │
                 │                              │
   match/exclude │  1. rule selection           │  ← NO variables here
                 │  2. context[] load  ─────────┼──►  ConfigMap informer (cache, ~0ms)
                 │     (sequential, ordered)    ├──►  in-cluster API   (~1–20ms)
                 │                              ├──►  GlobalContextEntry (cache, ~0ms)
                 │                              ├──►  external service (RTT + TLS)
                 │                              └──►  OCI registry     (100–800ms)
                 │  3. variable substitution    │
                 │  4. preconditions            │
                 │  5. validate/mutate/generate │
                 └──────────────────────────────┘
                              │ AdmissionResponse
                              ▼
```

Los pasos 2 y 3 son el objeto de este tema.

---

## 2. El motor de sustitución

### 2.1 Sintaxis

Una variable es `{{ <expresión JMESPath> }}`. Kyverno recorre todo el cuerpo de la regla como un árbol sin tipo, encuentra los valores string que contienen `{{ … }}`, evalúa la expresión contra un **objeto de contexto**, y reemplaza el placeholder.

```yaml
message: "Pod {{ request.object.metadata.name }} in {{ request.namespace }} is invalid"
```

Dos comportamientos que hay que saber de memoria:

* **La sustitución de string completo preserva el tipo.** Si el string es *exactamente* `"{{ expr }}"` y `expr` evalúa a una lista o un objeto, el resultado es una lista/objeto real, no un string. Si el placeholder está embebido en texto circundante, el resultado se convierte a string.

  ```yaml
  value: "{{ teams }}"        # → ["payments","search"]   (a list)
  value: "team is {{ team }}" # → "team is payments"      (a string)
  ```

* **Escape.** Un `{{` literal se escribe `\{{`. Esto importa constantemente cuando una política genera plantillas de Helm, reglas de Prometheus o dashboards de Grafana vía `generate`.

  ```yaml
  expr: 'sum(rate(http_requests_total[5m])) by (job)'
  legend: '\{{ job }}'      # rendered literally as {{ job }}
  ```

* **Resolución anidada.** Kyverno resuelve variables dentro de variables, hasta una profundidad acotada: `{{ dictionary.data.{{ request.object.metadata.labels.tier }} }}` es legal pero hostil de leer — preferí una entrada de contexto `variable`.

### 2.2 Dónde se permiten y dónde no se permiten las variables

Este es el error de autoría de políticas más común de todos.

| Campo | ¿Variables? | Nota |
|---|---|---|
| `spec.rules[].match` / `exclude` | **No** (con excepciones acotadas y documentadas) | La selección de reglas ocurre antes de la sustitución. El webhook de validación de políticas lo rechaza. |
| `spec.rules[].name` | No | La identidad de la regla debe ser estable para los reportes. |
| `context[].configMap.name` / `.namespace` | Sí | Resuelto solo desde `request.*`. |
| `context[].apiCall.urlPath` | Sí | El clásico `"/api/v1/namespaces/{{ request.namespace }}/pods"`. |
| `preconditions` | Sí | Tanto `key` como `value`. |
| `validate.message` | Sí | Interpolado en el texto de denegación que ve el usuario. |
| `validate.pattern` / `anyPattern` | Sí | |
| `validate.deny.conditions` | Sí | |
| `validate.foreach[].*` | Sí, más `element`/`elementIndex` | |
| `mutate.patchStrategicMerge` / `patchesJson6902` | Sí | |
| `generate.data` / `clone` | Sí | |
| comportamiento de `spec.background` | — | Ver §2.4. |

Si colocás una variable en `match`, la creación de la política falla en la admisión:

```console
$ kubectl apply -f bad-policy.yaml
Error from server: error when creating "bad-policy.yaml": admission webhook
"validate-policy.kyverno.svc" denied the request: spec.rules[0].match: Invalid
value: "{{ request.object.metadata.labels.tier }}": variables are not allowed
in the match section
```

### 2.3 Variables incorporadas

| Variable | Disponible cuando | Contenido |
|---|---|---|
| `request.object` | CREATE, UPDATE, CONNECT | El recurso entrante. **`null` en DELETE.** |
| `request.oldObject` | UPDATE, DELETE | El estado anterior. La *única* fuente en DELETE. |
| `request.operation` | Solo en admisión | `CREATE` \| `UPDATE` \| `DELETE` \| `CONNECT` |
| `request.userInfo` | Solo en admisión | `{username, uid, groups, extra}` |
| `request.roles`, `request.clusterRoles` | Solo en admisión | Nombres de los roles asociados al solicitante. |
| `request.namespace` | Solo en admisión | Namespace de la solicitud (no necesariamente `object.metadata.namespace`). |
| `serviceAccountName` | Solo en admisión | Derivado de `system:serviceaccount:<ns>:<name>` → `<name>`. |
| `serviceAccountNamespace` | Solo en admisión | → `<ns>` |
| `images` | Siempre | Datos de imagen normalizados: `images.containers."<name>".{registry,path,name,tag,digest,reference}`; también `images.initContainers`, `images.ephemeralContainers`. |
| `element`, `elementIndex` | Dentro de `foreach` | Elemento actual de la lista y su índice base 0. |
| `@` | Dentro de `foreach`/pattern | Abreviatura del elemento actual. |
| `target` | `mutate.targets`, `generate` | El recurso *existente* que se está modificando, en oposición al disparador. |
| `globalContext.<name>` | Siempre | Ver §3.6. |

**Las imágenes normalizadas merecen una segunda mirada.** Kyverno canonicaliza `nginx` en `docker.io/nginx:latest`, así tus políticas nunca tienen que manejar los casos de registry implícito / tag implícito:

```console
$ kyverno jp query -i pod.yaml 'images.containers."web"'
{
  "digest": "",
  "image": "docker.io/nginx:1.27",
  "name": "web",
  "path": "nginx",
  "reference": "docker.io/nginx:1.27",
  "referenceWithTag": "docker.io/nginx:1.27",
  "registry": "docker.io",
  "tag": "1.27"
}
```

### 2.4 Modo admisión vs. modo background — una restricción dura

Kyverno evalúa las políticas dos veces: una vez en la ruta de admisión, y otra vez en los **escaneos de background** (el reports controller reevaluando recursos existentes para los `PolicyReport`s, y el background controller para `generate` / `mutateExisting`).

Los escaneos de background **no tienen `AdmissionReview`**. Por lo tanto `request.userInfo`, `request.roles`, `request.clusterRoles`, `serviceAccountName`, `serviceAccountNamespace` y `request.operation` no existen ahí. Kyverno rechaza la política en el momento de la creación en lugar de fallar en silencio:

```console
$ kubectl apply -f audit-user.yaml
Error from server: error when creating "audit-user.yaml": admission webhook
"validate-policy.kyverno.svc" denied the request: spec.background: Invalid
value: true: variables {{request.userInfo.username}} are not supported in
background mode. Set spec.background=false
```

La solución — y la respuesta de examen — es `spec.background: false`. El costo es que tales políticas no producen **ningún resultado de `PolicyReport` para recursos preexistentes**; solo actúan en el momento de la admisión. Sé explícito sobre ese compromiso en una revisión de diseño.

Un modismo defensivo que vas a ver a lo largo de la documentación de Kyverno protege `request.operation` para que una política se pueda reutilizar con seguridad en ambos modos:

```yaml
preconditions:
  all:
  - key: "{{ request.operation || 'BACKGROUND' }}"
    operator: AnyIn
    value:
    - CREATE
    - UPDATE
```

`||` es la **expresión-or** de JMESPath: devuelve el lado derecho cuando el izquierdo es `null` o "similar a falso". Es la herramienta principal para valores por defecto, y es lo que evita que las reglas den error ante campos ausentes.

---

## 3. `context[]` — la etapa de carga de datos

`context` es una lista **ordenada** evaluada de arriba hacia abajo, por regla, antes de las preconditions. Las entradas posteriores pueden referenciar a las anteriores. El `name` de la entrada se convierte en una variable de nivel superior.

### 3.1 Comparación de las fuentes de contexto

| Fuente | Mecanismo subyacente | Latencia típica en la ruta de admisión | Frescura | RBAC requerido | Mejor uso |
|---|---|---|---|---|---|
| `configMap` | Caché de informer de Kubernetes en el controlador | ~0 (en memoria) | Dirigida por watch, casi en tiempo real | `get/list/watch configmaps` (en los roles por defecto de Kyverno) | Allowlists, diccionarios de tenants, umbrales ajustables |
| `apiCall` (in-cluster, GET) | Llamada directa al `kube-apiserver` | 1–20 ms p50, cola no acotada | Fuertemente consistente (lectura directa) | Explícito, por recurso, debe agregarse | Contar recursos, leer etiquetas de namespace, chequeos entre objetos |
| `apiCall` (in-cluster, POST) | Llamada directa, escribe un objeto de review | 5–30 ms | Fuertemente consistente | `create subjectaccessreviews`, etc. | Política consciente de la autorización (`SubjectAccessReview`) |
| `apiCall` con `service` | HTTPS a un endpoint arbitrario | RTT de red + TLS; el costo dominante | Lo que diga el servicio | Ninguno in-cluster; necesita `caBundle` | Consultas a CMDB, scoring de riesgo externo, servidores de licencias |
| `imageRegistry` | Pull del manifiesto + config blob desde el registry OCI | 100–800 ms en frío, cacheado brevemente | Depende del registry | Ninguno in-cluster; necesita credenciales del registry | Leer etiquetas de imagen, `USER`, puertos expuestos, referencias a SBOM |
| `globalReference` (GlobalContextEntry) | Caché refrescada en background dentro de Kyverno | ~0 (en memoria) | Desactualizada hasta `refreshInterval` | Igual que `apiCall`, otorgado una sola vez | Consultas de alta frecuencia que de otro modo martillarían al API server |
| `variable` | Cómputo puro | 0 | — | — | Nombrar expresiones JMESPath intermedias, valores por defecto |

**La regla de ingeniería:** si una regla coincide con un recurso de alto QPS (Pods, Events, Leases) y necesita estado del clúster, usá un `GlobalContextEntry`, no un `apiCall` crudo. Si coincide con un recurso de bajo QPS (Namespaces, Ingresses), un `apiCall` directo está bien y te da consistencia fuerte.

### 3.2 `configMap`

```yaml
context:
- name: registries
  configMap:
    name: allowed-registries
    namespace: kyverno
```

Acceder a las claves:

```yaml
# simple key
{{ registries.data.default }}

# key containing '-' or '.' MUST be quoted in JMESPath
{{ registries.data."prod-allowlist" }}
```

**La trampa del array.** Los valores de un ConfigMap son siempre strings. Para usar uno como lista, parsealo explícitamente:

```yaml
- key: "{{ images.containers.*.registry }}"
  operator: AllIn
  value: "{{ parse_json(registries.data.\"prod-allowlist\") }}"
```

Almacenar el valor como YAML en el ConfigMap y usar `parse_yaml()` funciona igual de bien y es más amigable para los humanos que lo editan vía GitOps.

Si el ConfigMap no existe, la variable resuelve a `null` — **no** es un error duro en el momento de la carga; la falla aparece después como una variable sin resolver. Emparejalo siempre con un `default`:

```yaml
context:
- name: registries
  configMap:
    name: allowed-registries
    namespace: kyverno
- name: allowlist
  variable:
    jmesPath: 'parse_json(registries.data."prod-allowlist")'
    default: ["registry.internal.example.com"]
```

### 3.3 `apiCall` — GET

```yaml
context:
- name: nsdata
  apiCall:
    urlPath: "/api/v1/namespaces/{{ request.namespace }}"
    jmesPath: "metadata.labels"
```

`urlPath` es una ruta cruda de la API de Kubernetes. Acertala preguntándole al propio API server:

```console
$ kubectl get --raw "/api/v1/namespaces/payments" | jq '.metadata.labels'
{
  "environment": "prod",
  "kubernetes.io/metadata.name": "payments",
  "team": "payments"
}
```

```console
$ kubectl get --raw "/apis/networking.k8s.io/v1/namespaces/payments/ingresses" | jq '.items | length'
7
```

Construcción de rutas, para memorizar:

| Forma del recurso | Ruta |
|---|---|
| Core, con namespace | `/api/v1/namespaces/{ns}/{resource}` |
| Core, de alcance clúster | `/api/v1/{resource}` |
| Agrupado, con namespace | `/apis/{group}/{version}/namespaces/{ns}/{resource}` |
| Agrupado, de alcance clúster | `/apis/{group}/{version}/{resource}` |
| Seleccionado por etiqueta | agregar `?labelSelector=team%3Dpayments` |
| Seleccionado por campo | agregar `?fieldSelector=spec.nodeName%3Dnode-1` |

`jmesPath` se aplica **del lado de la respuesta del servidor**, y hacer la reducción ahí es una optimización real: `jmesPath: "items | length(@)"` evita que una lista de Pods de 4 MB se materialice en el espacio de nombres de variables y se re-serialice para cada expresión posterior.

### 3.4 `apiCall` — POST (política consciente de la autorización)

Algunas APIs de Kubernetes son de solo escritura: hacés `create` de un objeto de review y leés la respuesta desde su `status`. `SubjectAccessReview` es el caso canónico, y permite que una política de Kyverno delegue la pregunta "¿puede este usuario hacer X?" al propio autorizador del clúster en lugar de reimplementar RBAC en JMESPath.

```yaml
context:
- name: sar
  apiCall:
    urlPath: "/apis/authorization.k8s.io/v1/subjectaccessreviews"
    method: POST
    data:
    - key: kind
      value: SubjectAccessReview
    - key: apiVersion
      value: authorization.k8s.io/v1
    - key: spec
      value:
        user: "{{ request.userInfo.username }}"
        groups: "{{ request.userInfo.groups }}"
        resourceAttributes:
          namespace: "{{ request.namespace }}"
          verb: update
          group: ""
          resource: secrets
    jmesPath: "status.allowed"
```

`data[]` es una lista de pares `key`/`value` que Kyverno ensambla en el cuerpo JSON de la solicitud. `value` puede ser un escalar, una lista o un objeto, y recibe sustitución completa de variables.

### 3.5 `apiCall` con `service` — salir del clúster

```yaml
context:
- name: riskScore
  apiCall:
    service:
      url: https://risk-api.platform.svc.cluster.local:8443/v1/score
      caBundle: |
        -----BEGIN CERTIFICATE-----
        MIIBkTCCATegAwIBAgIQKDVeSMPvDQOnrKzMSLmXnjAKBggqhkjOPQQDAjAeMRww
        GgYDVQQDExNwbGF0Zm9ybS1pbnRlcm5hbC1jYTAeFw0yNjAxMDIwMDAwMDBaFw0z
        NjAxMDIwMDAwMDBaMB4xHDAaBgNVBAMTE3BsYXRmb3JtLWludGVybmFsLWNhMFkw
        EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEs0m9k1u5Vh0K0R0cQ3F0m2wZ9x1c1sQ0
        Hn8p4Q8bF2mV8i2p9rQ1s8v0Y5k1H8u2b1p3n5C0q8N4tM6uKKNCMEAwDgYDVR0P
        AQH/BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFDq3S3fWpxvW1Q8h
        3d0Yq3Hq5t4mMAoGCCqGSM49BAMCA0gAMEUCIQCz2Vv8Yk8k9F1a5H2Q4wJ0x8Q6
        Hb3W1s2V0m9Q8vQ0AgIgQ8n1S5m2p0Q3x8bV1a7t9K0Y6c2Q4H8u1p3W5m0V8k=
        -----END CERTIFICATE-----
    method: POST
    data:
    - key: images
      value: "{{ images.containers.*.reference }}"
    jmesPath: "score"
```

Dos requisitos duros y una advertencia de diseño:

* `caBundle` es **obligatorio** para las llamadas con `service` — Kyverno no va a omitir la verificación TLS. Pegá la cadena PEM que firma el endpoint.
* El endpoint debe sobrevivir a ser llamado en la ruta crítica de cada solicitud de admisión coincidente. Dale un presupuesto duro del lado del cliente.
* **Advertencia de diseño:** `service` convierte la autoría de políticas en una primitiva de solicitudes salientes. Cualquiera que pueda crear una `ClusterPolicy` puede hacer que la ServiceAccount de Kyverno emita solicitudes HTTPS arbitrarias que transportan datos del clúster. Tratá `create/update clusterpolicies` como un verbo privilegiado, ponelo detrás de una revisión GitOps, y considerá una NetworkPolicy que restrinja el egreso de Kyverno a una allowlist conocida.

### 3.6 `globalReference` y `GlobalContextEntry`

Un `GlobalContextEntry` (CRD introducido en Kyverno 1.11) mueve la búsqueda **fuera** de la ruta de admisión. Kyverno mantiene los datos en memoria y los refresca con un temporizador o vía un watch.

```yaml
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: cluster-ingress-hosts
spec:
  apiCall:
    urlPath: "/apis/networking.k8s.io/v1/ingresses"
    refreshInterval: 30s
```

O la forma basada en watch, que evita el polling por completo:

```yaml
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: all-namespaces
spec:
  kubernetesResource:
    group: ""
    version: v1
    resource: namespaces
```

Consumido por:

```yaml
context:
- name: takenHosts
  globalReference:
    name: cluster-ingress-hosts
    jmesPath: "items[].spec.rules[].host"
```

El compromiso es explícito y debe declararse en el diseño: **cambiás consistencia fuerte por latencia.** Con `refreshInterval: 30s`, dos Ingresses que reclaman el mismo host creados con 5 segundos de diferencia van a ser admitidos ambos. Para restricciones de unicidad que deban ser exactas, usá un `apiCall` directo y aceptá la latencia; para chequeos informativos, usá la entrada global.

Confirmá qué versión de la API sirve tu clúster antes de escribir el manifiesto:

```console
$ kubectl api-resources --api-group=kyverno.io | grep -i global
globalcontextentries   gctxentry   kyverno.io/v2alpha1   false   GlobalContextEntry
```

### 3.7 `imageRegistry`

```yaml
context:
- name: imageData
  imageRegistry:
    reference: "{{ element }}"
    jmesPath: "configData.config"
```

El objeto devuelto contiene `registry`, `repository`, `identifier`, `manifest` (el manifiesto OCI) y `configData` (el config blob de la imagen — lo que contiene `User`, `Entrypoint`, `Env`, `ExposedPorts`, `Labels`). Para registries privados:

```yaml
context:
- name: imageData
  imageRegistry:
    reference: "{{ element }}"
    imageRegistryCredentials:
      allowInsecureRegistry: false
      providers:
      - default
      secrets:
      - regcred-platform          # in the Kyverno namespace
```

Este es por lejos el tipo de contexto más costoso. Nunca lo asocies a una regla que coincida ampliamente sin preconditions que la acoten primero.

### 3.8 `variable`

Cómputo puro, sin E/S. Usalo agresivamente: nombra resultados intermedios, provee valores por defecto y mantiene legible `deny.conditions`.

```yaml
context:
- name: replicas
  variable:
    jmesPath: "request.object.spec.replicas"
    default: 1
- name: isProd
  variable:
    value: "{{ nsdata.environment || 'dev' }}"
```

---

## 4. Manifiestos completos de producción

### 4.1 RBAC — el prerrequisito que todos olvidan

Los controladores de Kyverno corren con privilegio mínimo. Un `apiCall` a cualquier cosa más allá de los valores por defecto **falla con un 403 hasta que se lo otorgues**. Desde Kyverno 1.10 los controladores son Deployments separados con ServiceAccounts separadas, y los permisos se otorgan a través de **ClusterRoles agregados**.

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:platform:context-reader
  labels:
    # These labels graft the rules onto Kyverno's own aggregated ClusterRoles.
    # Grant only to the controllers that actually need them.
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
rules:
- apiGroups: [""]
  resources: ["namespaces", "services", "resourcequotas", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:platform:sar-creator
  labels:
    # SubjectAccessReview is only meaningful at admission time — do not grant
    # it to the background or reports controllers.
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
rules:
- apiGroups: ["authorization.k8s.io"]
  resources: ["subjectaccessreviews"]
  verbs: ["create"]
```

Verificá que el permiso haya quedado aplicado, usando la propia identidad de la ServiceAccount:

```console
$ kubectl apply -f kyverno-context-rbac.yaml
clusterrole.rbac.authorization.k8s.io/kyverno:platform:context-reader created
clusterrole.rbac.authorization.k8s.io/kyverno:platform:sar-creator created

$ kubectl auth can-i list ingresses \
    --as=system:serviceaccount:kyverno:kyverno-admission-controller \
    --all-namespaces
yes

$ kubectl auth can-i create subjectaccessreviews \
    --as=system:serviceaccount:kyverno:kyverno-background-controller
no
```

El segundo `no` es correcto e intencional — privilegio mínimo por controlador.

### 4.2 Allowlist de registries por tenant (ConfigMap + variable + foreach)

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-allowlist
  namespace: kyverno
data:
  # Per-namespace allowlists. GitOps-managed; changing this needs no policy release.
  payments: |
    ["registry.internal.example.com", "ghcr.io"]
  search: |
    ["registry.internal.example.com"]
  # Fallback for namespaces with no explicit entry.
  _default: |
    ["registry.internal.example.com"]
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
  annotations:
    policies.kyverno.io/title: Restrict Image Registries per Tenant
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Every container image must originate from a registry explicitly allowed
      for the workload's namespace. The allowlist is read from a ConfigMap at
      admission time so it can be changed without redeploying policy.
spec:
  validationFailureAction: Enforce
  background: true
  webhookTimeoutSeconds: 10
  failurePolicy: Fail
  rules:
  - name: check-registry
    match:
      any:
      - resources:
          kinds:
          - Pod
    context:
    # 1. Pull the whole dictionary from the informer-backed cache (free).
    - name: allowlistCM
      configMap:
        name: registry-allowlist
        namespace: kyverno
    # 2. Select this namespace's entry, falling back to _default.
    - name: allowedRegistries
      variable:
        jmesPath: >-
          parse_json(
            allowlistCM.data."{{ request.namespace }}"
            || allowlistCM.data._default
          )
        default:
        - registry.internal.example.com
    preconditions:
      all:
      - key: "{{ request.operation || 'BACKGROUND' }}"
        operator: AnyIn
        value:
        - CREATE
        - UPDATE
    validate:
      message: >-
        Image registries {{ images.containers.*.registry | to_string(@) }} are not
        all permitted in namespace {{ request.namespace }}.
        Allowed: {{ allowedRegistries | to_string(@) }}.
      deny:
        conditions:
          all:
          - key: "{{ images.containers.*.registry }}"
            operator: AnyNotIn
            value: "{{ allowedRegistries }}"
```

Notá el uso de `AnyNotIn` dentro de un bloque **deny**: denegar cuando *cualquier* registry esté fuera de la lista. Acertar la polaridad en `deny` es una trampa frecuente del examen — las `deny.conditions` disparan la falla cuando evalúan a **verdadero**, lo inverso de `pattern`.

Comportamiento:

```console
$ kubectl -n payments run web --image=ghcr.io/example/web:1.4.0
pod/web created

$ kubectl -n search run web --image=ghcr.io/example/web:1.4.0
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/search/web was blocked due to the following policies

restrict-image-registries:
  check-registry: 'Image registries ["ghcr.io"] are not all permitted in namespace
    search. Allowed: ["registry.internal.example.com"].'
```

### 4.3 Estado del clúster vía `apiCall`: imponer un presupuesto de LoadBalancers

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: limit-loadbalancer-services
  annotations:
    policies.kyverno.io/title: Limit LoadBalancer Services per Namespace
    policies.kyverno.io/category: Cost Control
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Each LoadBalancer Service provisions a billable cloud load balancer.
      This policy counts existing LoadBalancer Services in the namespace via a
      live API call and denies creation beyond the namespace's declared quota,
      which is carried on the namespace as an annotation.
spec:
  validationFailureAction: Enforce
  background: false          # counts are only meaningful at admission time
  failurePolicy: Fail
  webhookTimeoutSeconds: 15
  rules:
  - name: check-lb-count
    match:
      any:
      - resources:
          kinds:
          - Service
    preconditions:
      all:
      - key: "{{ request.operation || 'BACKGROUND' }}"
        operator: Equals
        value: CREATE
      - key: "{{ request.object.spec.type }}"
        operator: Equals
        value: LoadBalancer
    context:
    - name: existingLBs
      apiCall:
        urlPath: "/api/v1/namespaces/{{ request.namespace }}/services"
        jmesPath: "items[?spec.type == 'LoadBalancer'] | length(@)"
    - name: nsObject
      apiCall:
        urlPath: "/api/v1/namespaces/{{ request.namespace }}"
        jmesPath: "metadata.annotations"
    - name: quota
      variable:
        jmesPath: 'to_number(nsObject."platform.example.com/lb-quota" || `2`)'
        default: 2
    validate:
      message: >-
        Namespace {{ request.namespace }} already has {{ existingLBs }} LoadBalancer
        Service(s); its quota is {{ quota }}. Use the shared Ingress controller or
        request a quota increase from the platform team.
      deny:
        conditions:
          all:
          - key: "{{ existingLBs }}"
            operator: GreaterThanOrEquals
            value: "{{ quota }}"
```

Notá que `context` está colocado **después** de `preconditions` en la intención: Kyverno evalúa las preconditions después de cargar el contexto, así que para *saltear* realmente la llamada a la API en Services que no son LoadBalancer deberías dividir el trabajo — el chequeo barato de tipo pertenece a un `match` sobre `Service` más una precondition, y el conteo caro solo se alcanza cuando la regla no es salteada. En rutas calientes, preferí dividir en dos reglas para que la regla que carga contexto coincida lo más estrechamente posible.

```console
$ kubectl -n payments get svc --field-selector spec.type=LoadBalancer
NAME       TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
gateway    LoadBalancer   10.96.14.203    203.0.113.41     443:31820/TCP  61d
legacy-lb  LoadBalancer   10.96.201.17    203.0.113.88     80:30991/TCP   14d

$ kubectl -n payments apply -f third-lb.yaml
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Service/payments/analytics was blocked due to the following policies

limit-loadbalancer-services:
  check-lb-count: 'Namespace payments already has 2 LoadBalancer Service(s); its
    quota is 2. Use the shared Ingress controller or request a quota increase from
    the platform team.'
```

### 4.4 Etiquetas de namespace — el dato que no está en la solicitud

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: prod-requires-pdb-and-probes
  annotations:
    policies.kyverno.io/title: Production Workloads Require Probes
    policies.kyverno.io/category: Reliability
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: probes-in-prod
    match:
      any:
      - resources:
          kinds:
          - Deployment
          - StatefulSet
    context:
    - name: nsLabels
      apiCall:
        urlPath: "/api/v1/namespaces/{{ request.namespace }}"
        jmesPath: "metadata.labels"
    - name: environment
      variable:
        value: "{{ nsLabels.environment || 'dev' }}"
    preconditions:
      all:
      - key: "{{ environment }}"
        operator: Equals
        value: prod
    validate:
      message: >-
        Namespace {{ request.namespace }} is environment={{ environment }};
        every container must declare both readinessProbe and livenessProbe.
      foreach:
      - list: "request.object.spec.template.spec.containers"
        deny:
          conditions:
            any:
            - key: "{{ element.readinessProbe || '' }}"
              operator: Equals
              value: ""
            - key: "{{ element.livenessProbe || '' }}"
              operator: Equals
              value: ""
```

> Kyverno también soporta `match.any[].resources.namespaceSelector` para coincidencia de namespaces basada en etiquetas, que es evaluada por el *API server* a través del `namespaceSelector` del webhook y no cuesta nada. Preferilo cuando solo necesitás *seleccionar*; usá el `apiCall` cuando necesitás el **valor** de la etiqueta dentro del cuerpo de la regla (en un mensaje, un umbral, un objeto generado).

### 4.5 Política consciente de la autorización con un `apiCall` POST

Esta regla bloquea el borrado de recursos que llevan la etiqueta `platform.example.com/protected: "true"` a menos que el solicitante realmente tenga derechos equivalentes a cluster-admin — según lo juzgue el propio autorizador del clúster, no una lista de usuarios hardcodeada.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: protect-critical-resources
  annotations:
    policies.kyverno.io/title: Protect Labelled Resources From Deletion
    policies.kyverno.io/category: Change Management
    policies.kyverno.io/severity: critical
spec:
  validationFailureAction: Enforce
  background: false          # uses request.userInfo — mandatory
  failurePolicy: Fail
  rules:
  - name: block-protected-delete
    match:
      any:
      - resources:
          kinds:
          - ConfigMap
          - Secret
          - Service
          - Deployment
          - StatefulSet
          - PersistentVolumeClaim
    preconditions:
      all:
      - key: "{{ request.operation }}"
        operator: Equals
        value: DELETE
      # On DELETE, request.object is null — read from oldObject.
      - key: "{{ request.oldObject.metadata.labels.\"platform.example.com/protected\" || 'false' }}"
        operator: Equals
        value: "true"
    context:
    # Ask the API server whether this identity may delete namespaces —
    # a proxy for "is genuinely a cluster operator".
    - name: sar
      apiCall:
        urlPath: "/apis/authorization.k8s.io/v1/subjectaccessreviews"
        method: POST
        data:
        - key: kind
          value: SubjectAccessReview
        - key: apiVersion
          value: authorization.k8s.io/v1
        - key: spec
          value:
            user: "{{ request.userInfo.username }}"
            groups: "{{ request.userInfo.groups }}"
            resourceAttributes:
              verb: delete
              group: ""
              resource: namespaces
        jmesPath: "status.allowed"
    validate:
      message: >-
        {{ request.oldObject.kind }}/{{ request.oldObject.metadata.name }} is
        labelled protected. User {{ request.userInfo.username }} is not authorised
        to delete it. Remove the label through the change-management process first.
      deny:
        conditions:
          all:
          - key: "{{ sar }}"
            operator: Equals
            value: false
```

```console
$ kubectl --context=dev-user -n payments delete secret payment-signing-key
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Secret/payments/payment-signing-key was blocked due to the following policies

protect-critical-resources:
  block-protected-delete: 'Secret/payment-signing-key is labelled protected. User
    dana@example.com is not authorised to delete it. Remove the label through the
    change-management process first.'

$ kubectl --context=cluster-admin -n payments delete secret payment-signing-key
secret "payment-signing-key" deleted
```

### 4.6 GlobalContextEntry: unicidad de hosts de Ingress sin martillar la API

```yaml
---
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: ingress-hosts
spec:
  apiCall:
    urlPath: "/apis/networking.k8s.io/v1/ingresses"
    refreshInterval: 20s
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: unique-ingress-hosts
  annotations:
    policies.kyverno.io/title: Advisory Ingress Host Uniqueness
    policies.kyverno.io/category: Networking
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Advisory check. Backed by a GlobalContextEntry refreshed every 20s, so two
      conflicting Ingresses created within the refresh window can both be admitted.
      Enforcement of true uniqueness belongs to the ingress controller.
spec:
  validationFailureAction: Audit
  background: true
  rules:
  - name: host-not-taken
    match:
      any:
      - resources:
          kinds:
          - Ingress
    context:
    - name: takenHosts
      globalReference:
        name: ingress-hosts
        # Exclude the object being updated so an in-place edit does not self-conflict.
        jmesPath: >-
          items[?!(metadata.name == '{{ request.object.metadata.name }}'
            && metadata.namespace == '{{ request.namespace }}')]
            .spec.rules[].host
    validate:
      message: >-
        Host(s) {{ request.object.spec.rules[].host | to_string(@) }} are already
        claimed by another Ingress in this cluster.
      deny:
        conditions:
          all:
          - key: "{{ request.object.spec.rules[].host }}"
            operator: AnyIn
            value: "{{ takenHosts || `[]` }}"
```

```console
$ kubectl get gctxentry
NAME            REFRESH   AGE
ingress-hosts   20s       4m11s

$ kubectl describe gctxentry ingress-hosts | tail -6
Status:
  Ready:  True
  Conditions:
    Message:               Global context entry is ready
    Reason:                Succeeded
    Status:                True
    Type:                  Ready
```

### 4.7 `imageRegistry` + `foreach`: rechazar imágenes cuya configuración corre como root

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: images-must-declare-nonroot-user
  annotations:
    policies.kyverno.io/title: Image Config Must Declare a Non-Root USER
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Inspects the OCI image config blob in the registry. An image whose USER is
      empty or 0 defaults to root even when the Pod omits securityContext, so this
      catches the failure at its source rather than patching every workload.
spec:
  validationFailureAction: Enforce
  background: false          # registry pulls are too expensive for background scans
  webhookTimeoutSeconds: 20
  failurePolicy: Ignore      # a registry outage must not block the cluster
  rules:
  - name: check-image-user
    match:
      any:
      - resources:
          kinds:
          - Pod
    preconditions:
      all:
      - key: "{{ request.operation || 'BACKGROUND' }}"
        operator: AnyIn
        value:
        - CREATE
        - UPDATE
    validate:
      message: "Image config declares a root or unset USER."
      foreach:
      - list: "request.object.spec.containers"
        context:
        - name: imageData
          imageRegistry:
            reference: "{{ element.image }}"
            jmesPath: "configData.config.User || ''"
        deny:
          conditions:
            any:
            - key: "{{ imageData }}"
              operator: AnyIn
              value:
              - ""
              - "0"
              - "root"
```

Acá hay codificadas dos decisiones de producción y ambas son deliberadas:

* `failurePolicy: Ignore` — un registry inalcanzable produce un contexto irresoluble. Con `Fail`, esa caída se convierte en una **caída de escrituras en todo el clúster**. La postura de seguridad es más débil; la postura de disponibilidad es la que te mantiene empleado. Compensalo con una política gemela en modo `Audit` más una alerta sobre `PolicyReport`.
* `background: false` — un escaneo del reports controller sobre 8.000 Pods emitiría 8.000 pulls al registry por intervalo de escaneo.

### 4.8 Mutación y generación dirigidas por variables

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-cost-centre
  annotations:
    policies.kyverno.io/title: Propagate Cost Centre From Namespace
    policies.kyverno.io/category: FinOps
spec:
  background: true
  rules:
  - name: add-cost-centre-label
    match:
      any:
      - resources:
          kinds:
          - Deployment
          - StatefulSet
          - CronJob
    context:
    - name: nsAnnotations
      apiCall:
        urlPath: "/api/v1/namespaces/{{ request.namespace }}"
        jmesPath: "metadata.annotations"
    - name: costCentre
      variable:
        value: '{{ nsAnnotations."finops.example.com/cost-centre" || "unallocated" }}'
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            finops.example.com/cost-centre: "{{ costCentre }}"
        spec:
          template:
            metadata:
              labels:
                finops.example.com/cost-centre: "{{ costCentre }}"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-tenant-netpol
  annotations:
    policies.kyverno.io/title: Generate a Default-Deny NetworkPolicy per Namespace
    policies.kyverno.io/category: Networking
spec:
  background: true
  rules:
  - name: default-deny
    match:
      any:
      - resources:
          kinds:
          - Namespace
    context:
    - name: tenant
      variable:
        value: '{{ request.object.metadata.labels.tenant || "shared" }}'
    preconditions:
      all:
      - key: "{{ request.object.metadata.labels.environment || 'dev' }}"
        operator: AnyIn
        value:
        - prod
        - staging
    generate:
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: default-deny-ingress
      namespace: "{{ request.object.metadata.name }}"
      synchronize: true
      data:
        metadata:
          labels:
            tenant: "{{ tenant }}"
            app.kubernetes.io/managed-by: kyverno
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
```

`synchronize: true` significa que el background controller reconcilia el objeto generado para siempre — y evalúa las mismas variables en modo **background**, que es exactamente por qué ninguna de las dos reglas puede referenciar `request.userInfo`.

---

## 5. JMESPath en Kyverno

Kyverno incluye JMESPath upstream más un amplio conjunto de funciones propias. La lista autoritativa es la que está compilada en *tu* binario:

```console
$ kyverno version
Version: v1.13.2
Time: 2026-01-19T09:41:07Z
Git commit ID: 4a1e0c93f2d9f2b6c1c3e2a91f8a0f2f1c7ab340

$ kyverno jp function | head -20
add(any, any) any
base64_decode(string) string
base64_encode(string) string
compare(string, string) number
concat(string, string) string
divide(any, any) any
equal_fold(string, string) bool
image_normalize(string) string
items(object|array, string, string) array[object]
label_match(object, object) bool
lookup(object|array, any) any
modulo(any, any) any
object_from_lists(array[string], array) object
parse_json(string) any
parse_yaml(string) any
path_canonicalize(string) string
pattern_match(string, string) bool
random(string) string
regex_match(string, any) bool
regex_replace_all(string, string|number, string|number) string

$ kyverno jp function | wc -l
57
```

Funciones a las que vas a recurrir repetidamente:

| Función | Uso |
|---|---|
| `parse_json(str)` / `parse_yaml(str)` | Convertir valores string de ConfigMap en estructuras |
| `to_number(str)`, `to_string(any)` | Coerción de tipos en `deny.conditions` y mensajes |
| `length(@)` | Contar a partir del resultado de un `apiCall` |
| `items(obj, 'k', 'v')` | Convertir un mapa en una lista para `foreach` |
| `object_from_lists(keys, vals)` | Inverso de `items` |
| `regex_match(pat, str)` | Convenciones de nombres, formas de referencias de imagen |
| `semver_compare(ver, constraint)` | Control de versiones de chart/aplicación |
| `time_since('', a, b)`, `time_after(a, b)` | Expiración de excepciones, frescura de certificados |
| `x509_decode(pem)` | Inspeccionar certificados dentro de Secrets |
| `split(str, sep)`, `trim_prefix(str, pre)` | Parseo de referencias |
| `sum(list)`, `add`, `subtract`, `divide` | Agregar presupuestos de resource requests |

`kyverno jp query` es la forma más rápida de iterar sobre una expresión sin un viaje de ida y vuelta al clúster:

```console
$ kubectl get --raw "/api/v1/namespaces/payments/services" > svc.json

$ kyverno jp query -i svc.json "items[?spec.type == 'LoadBalancer'] | length(@)"
2

$ kyverno jp query -i svc.json "items[].metadata.name | sort(@)"
[
  "gateway",
  "legacy-lb",
  "payments-api"
]

$ echo '{"data":{"prod-allowlist":"[\"a.io\",\"b.io\"]"}}' \
    | kyverno jp query 'parse_json(data."prod-allowlist") | length(@)'
2
```

---

## 6. Semántica de falla: qué pasa cuando una variable no resuelve

Acá es donde se origina la mayoría de los incidentes de producción. La cadena de comportamiento:

| Condición | Resultado |
|---|---|
| La expresión evalúa a `null` y hay un `default` definido | Se usa el `default`, la regla continúa |
| La expresión evalúa a `null`, sin `default`, con fallback `||` presente | Se usa el fallback |
| La expresión evalúa a `null`, nada más | **Error de sustitución de variable** → la regla falla |
| El `apiCall` devuelve 403 / 404 / timeout | Error de carga de contexto → la regla falla |
| La regla falla y `spec.failurePolicy: Fail` | **La solicitud a la API es rechazada** |
| La regla falla y `spec.failurePolicy: Ignore` | El error del webhook se traga; la solicitud es admitida; un evento/log lo registra |
| La regla falla durante un escaneo de background | Resultado de `PolicyReport` de tipo `error` |

La regla de diseño que se desprende: **`failurePolicy: Fail` + dependencia externa = un nuevo punto único de falla para las escrituras del clúster.** La matriz sobre la que deberías poder razonar en condiciones de examen y en una revisión de diseño:

| Fuente de contexto | ¿`failurePolicy: Fail` aceptable? | Fundamento |
|---|---|---|
| `configMap` | Sí | Caché en proceso; el modo de falla es "ConfigMap borrado", que es un error de tu propio GitOps. |
| `apiCall` in-cluster | Normalmente | Si el API server está caído, la admisión no está ocurriendo de todas formas. Cuidado con la deriva de RBAC después de las actualizaciones. |
| `globalReference` | Sí | Caché en proceso; agregá un `default` para la ventana de precalentamiento tras un reinicio del controlador. |
| `imageRegistry` | **No** | Las caídas de registries son comunes y externas. Usá `Ignore`. |
| `service` (externo) | **No** | Tu motor de políticas no debe heredar el SLO de un tercero. Usá `Ignore`. |

Emparejá siempre una política con `Ignore` con una política de reporte en modo `Audit` y una alerta sobre resultados de `PolicyReport` con `result: error`, de lo contrario el control deja de existir en silencio.

---

## 7. Verificación y diagnóstico

### 7.1 Offline: `kyverno apply` con un archivo de valores

Las variables que provienen de la admisión (`request.userInfo`, `request.operation`) no existen offline. Simulalas.

```yaml
# values.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
spec:
  globalValues:
    request.operation: CREATE
    request.userInfo.username: dana@example.com
  namespaceSelector:
  - name: search
    labels:
      environment: prod
  policies:
  - name: restrict-image-registries
    resources:
    - name: web
      values:
        allowlistCM.data.search: '["registry.internal.example.com"]'
        request.namespace: search
```

```console
$ kyverno apply restrict-image-registries.yaml \
    --resource pod-ghcr.yaml \
    --values-file values.yaml

Applying 1 policy rule(s) to 1 resource(s) with 1 variable file(s)...

policy restrict-image-registries -> resource search/Pod/web failed:
1. check-registry: Image registries ["ghcr.io"] are not all permitted in namespace
   search. Allowed: ["registry.internal.example.com"].

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

### 7.2 Offline contra un clúster vivo: `--cluster`

`--cluster` permite que las entradas `apiCall` y `configMap` resuelvan de verdad, usando **tus** credenciales de kubeconfig — que es precisamente por qué una política puede pasar acá y fallar en el clúster (vos sos cluster-admin; la ServiceAccount de Kyverno no lo es).

```console
$ kyverno apply limit-loadbalancer-services.yaml \
    --resource third-lb.yaml \
    --cluster \
    --values-file values.yaml

Applying 1 policy rule(s) to 1 resource(s) with 1 variable file(s)...

policy limit-loadbalancer-services -> resource payments/Service/analytics failed:
1. check-lb-count: Namespace payments already has 2 LoadBalancer Service(s); its
   quota is 2. Use the shared Ingress controller or request a quota increase from
   the platform team.

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

### 7.3 Pruebas de regresión: `kyverno test`

```yaml
# .kyverno-test/kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: registry-allowlist-tests
policies:
- ../restrict-image-registries.yaml
resources:
- ../resources/pod-internal.yaml
- ../resources/pod-ghcr.yaml
variables: ../values.yaml
results:
- policy: restrict-image-registries
  rule: check-registry
  resources:
  - web-internal
  kind: Pod
  result: pass
- policy: restrict-image-registries
  rule: check-registry
  resources:
  - web-ghcr
  kind: Pod
  result: fail
```

```console
$ kyverno test .kyverno-test/

Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│───│───────────────────────────│────────────────│───────────────────│────────│
│ # │ POLICY                    │ RULE           │ RESOURCE          │ RESULT │
│───│───────────────────────────│────────────────│───────────────────│────────│
│ 1 │ restrict-image-registries │ check-registry │ Pod/web-internal  │ Pass   │
│ 2 │ restrict-image-registries │ check-registry │ Pod/web-ghcr      │ Pass   │
│───│───────────────────────────│────────────────│───────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

Conectá esto a CI. Las políticas que llevan variables son las que se rompen silenciosamente cuando se renombra una clave de un ConfigMap.

### 7.4 Verificación dentro del clúster

```console
$ kubectl get clusterpolicy restrict-image-registries
NAME                        ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
restrict-image-registries   true        true         Enforce           True    12m   Ready

$ kubectl -n search create deployment web --image=ghcr.io/example/web:1.4.0 --dry-run=server
error: failed to create deployment: admission webhook "validate.kyverno.svc-fail"
denied the request:

resource Pod/search/web-6d9f4c8b7d-* was blocked due to the following policies

restrict-image-registries:
  check-registry: 'Image registries ["ghcr.io"] are not all permitted in namespace
    search. Allowed: ["registry.internal.example.com"].'
```

`--dry-run=server` ejecuta la cadena completa de admisión sin persistir — la forma más segura de probar una política `Enforce` en producción.

Los policy reports transportan los resultados del modo background, incluidos los errores de contexto:

```console
$ kubectl -n payments get policyreport
NAME                                   KIND         NAME       PASS   FAIL   WARN   ERROR   SKIP   AGE
0f0b8a5b-2a70-4a1f-9a58-1b1d4c0e7a11   Deployment   api        3      0      0      1       0      9m

$ kubectl -n payments get policyreport -o yaml | yq '.items[].results[] | select(.result=="error")'
message: 'failed to load context: failed to fetch data for APICall: ingresses.networking.k8s.io
  is forbidden: User "system:serviceaccount:kyverno:kyverno-reports-controller"
  cannot list resource "ingresses" in API group "networking.k8s.io" at the cluster scope'
policy: unique-ingress-hosts
result: error
rule: host-not-taken
```

Esa salida es la falla arquetípica de RBAC — notá que nombra al **reports controller**, no al admission controller, que es exactamente por qué las etiquetas de agregación de §4.1 deben aplicarse por controlador.

### 7.5 Logs de los controladores

```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=40 | grep -i "context\|variable"
2026-08-13T11:04:22Z  ERROR  engine.context  failed to add resource with dynamic
  client  {"policy": "limit-loadbalancer-services", "rule": "check-lb-count",
  "error": "services is forbidden: User \"system:serviceaccount:kyverno:kyverno-admission-controller\"
  cannot list resource \"services\" in API group \"\" in the namespace \"payments\""}
2026-08-13T11:04:22Z  ERROR  engine  failed to load context  {"kind": "Service",
  "namespace": "payments", "name": "analytics", "policy": "limit-loadbalancer-services",
  "rule": "check-lb-count"}
```

Subí la verbosidad temporalmente cuando una expresión se comporta mal:

```console
$ kubectl -n kyverno set env deploy/kyverno-admission-controller -- -v=4
deployment.apps/kyverno-admission-controller env updated

$ kubectl -n kyverno logs deploy/kyverno-admission-controller -f | grep "substitut"
2026-08-13T11:09:41Z  INFO  engine.variables  substituting variable
  {"variable": "{{ allowedRegistries }}", "value": ["registry.internal.example.com"]}
2026-08-13T11:09:41Z  INFO  engine.variables  substituting variable
  {"variable": "{{ images.containers.*.registry }}", "value": ["ghcr.io"]}
```

Revertilo después — `-v=4` es caro al QPS del clúster.

### 7.6 Tabla de diagnóstico

| Síntoma | Causa raíz | Primer comando |
|---|---|---|
| `variable substitution failed ... Unknown key` | Campo ausente en este objeto; error de tipeo; clave sin comillas con `-` o `.` | `kyverno jp query -i obj.json '<expr>'` |
| `is forbidden: User "system:serviceaccount:kyverno:..."` | Falta el ClusterRole agregado | `kubectl auth can-i <verb> <res> --as=system:serviceaccount:kyverno:<sa>` |
| Política rechazada al crearse: `variables ... not supported in background mode` | `request.userInfo`, etc. con `background: true` | Poner `spec.background: false` |
| Regla salteada en silencio, sin entrada en el reporte | La precondition evaluó falso — a menudo `request.operation` `null` en background | Agregar `|| 'BACKGROUND'`; revisar `kubectl describe polr` |
| La comparación de lista del ConfigMap nunca coincide | El valor es un **string** JSON, no una lista | Envolverlo en `parse_json()` |
| `context deadline exceeded` en el webhook | `apiCall`/registry más lento que `webhookTimeoutSeconds` | Subir el timeout, mover a `GlobalContextEntry`, o poner `failurePolicy: Ignore` |
| Funciona con `kyverno apply --cluster`, falla en el clúster | Vos sos cluster-admin; la ServiceAccount no | Comparar con `kubectl auth can-i --as=...` |
| El mensaje de denegación muestra `{{ … }}` literal | El placeholder fue escapado, o vive en un campo que no sustituye | Revisar `\{{` y §2.2 |
| `GlobalContextEntry` devuelve datos obsoletos/vacíos | El controlador se reinició; la caché no está caliente; `refreshInterval` demasiado largo | `kubectl describe gctxentry <name>` → condición `Ready` |
| Caída de escrituras en todo el clúster tras un cambio de política | `failurePolicy: Fail` + contexto externo fallado | `kubectl patch clusterpolicy <n> --type=merge -p '{"spec":{"failurePolicy":"Ignore"}}'` |

Rompé-el-vidrio de emergencia, en orden decreciente de radio de impacto:

```console
# 1. Downgrade a single policy to reporting only
$ kubectl patch clusterpolicy restrict-image-registries --type=merge \
    -p '{"spec":{"validationFailureAction":"Audit"}}'
clusterpolicy.kyverno.io/restrict-image-registries patched

# 2. Stop it failing closed
$ kubectl patch clusterpolicy restrict-image-registries --type=merge \
    -p '{"spec":{"failurePolicy":"Ignore"}}'
clusterpolicy.kyverno.io/restrict-image-registries patched

# 3. Remove the policy entirely — the webhook rule is reconfigured automatically
$ kubectl delete clusterpolicy restrict-image-registries
clusterpolicy.kyverno.io "restrict-image-registries" deleted
```

Una alternativa más acotada que borrar una política es una `PolicyException`, que recorta recursos específicos sin cambiar la postura de la política para todos los demás.

---

## 8. Modelo de rendimiento que deberías llevar a una revisión de diseño

| Decisión | Efecto sobre el p99 de admisión | Efecto sobre la corrección |
|---|---|---|
| `match` estrecho (kinds, `namespaceSelector`, `operations`) | La mayor ganancia — el webhook nunca es invocado | Ninguno |
| Poner preconditions baratas antes de reglas caras (dividir en reglas separadas) | Grande | Ninguno |
| Reducción con `jmesPath` en el propio `apiCall` | Moderado; evita materializar listas grandes | Ninguno |
| `GlobalContextEntry` en lugar de `apiCall` | Grande; lectura de memoria O(1) | Introduce desactualización de hasta `refreshInterval` |
| `background: false` en reglas caras | Elimina por completo la carga de tiempo de escaneo | Sin cobertura de `PolicyReport` sobre recursos existentes |
| `failurePolicy: Ignore` | Ninguno directamente; elimina el acoplamiento a la caída | El control pasa a ser de mejor esfuerzo |
| Subir `webhookTimeoutSeconds` | Empeora la latencia de cola para todo lo que coincida | Menos fallas espurias |

Dos números para tener presentes: el techo del timeout de webhooks de Kubernetes es **30 segundos**, y el valor por defecto de Kyverno es **10**. Una regla que hace un pull en frío al registry para seis contenedores puede plausiblemente exceder eso. Medí antes de desplegar — no lo asumas.

---

## 9. Resumen orientado al examen

* `{{ }}` delimita una expresión JMESPath; `\{{` la escapa.
* Las variables **no** funcionan en `match`/`exclude`.
* `context[]` es ordenado y carga **antes** de las preconditions; las entradas posteriores ven a las anteriores.
* Cinco tipos de contexto: `configMap`, `apiCall`, `imageRegistry`, `variable`, `globalReference`.
* `apiCall` soporta `urlPath` (in-cluster) o `service` (externo, `caBundle` obligatorio), y `method: GET|POST` con `data[]`.
* `request.object` es `null` en DELETE — usá `request.oldObject`.
* `request.userInfo` / `serviceAccountName` / `request.operation` fuerzan `spec.background: false`.
* `||` provee valores por defecto; `context[].variable.default` hace lo mismo de forma declarativa.
* Los valores de ConfigMap son strings — `parse_json` / `parse_yaml` antes de tratarlos como estructuras.
* Las `deny.conditions` disparan con **verdadero**; `pattern` pasa cuando coincide. Polaridad opuesta.
* Cada `apiCall` necesita RBAC otorgado vía un ClusterRole etiquetado `rbac.kyverno.io/aggregate-to-{admission,background,reports}-controller: "true"`.
* `GlobalContextEntry` cambia consistencia por latencia.
* `kyverno jp query` para depurar expresiones; `--values-file` para simular variables de admisión; `kyverno test` para CI; `--cluster` resuelve el contexto de verdad pero con *tus* credenciales.

---

## Referencias

- KCA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- Kyverno — Variables — https://kyverno.io/docs/writing-policies/variables/
- Kyverno — External Data Sources (`context`) — https://kyverno.io/docs/writing-policies/external-data-sources/
- Kyverno — Preconditions — https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — JMESPath custom functions — https://kyverno.io/docs/writing-policies/jmespath/
- Kyverno — Validate rules (`deny`, `foreach`, `pattern`) — https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Mutate rules — https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — Generate rules — https://kyverno.io/docs/writing-policies/generate/
- Kyverno — Policy definition, `failurePolicy`, `background`, webhook configuration — https://kyverno.io/docs/writing-policies/policy-settings/
- Kyverno — Exceptions — https://kyverno.io/docs/writing-policies/exceptions/
- Kyverno — CLI (`apply`, `test`, `jp`) — https://kyverno.io/docs/kyverno-cli/
- Kyverno — Customizing permissions / RBAC aggregation — https://kyverno.io/docs/installation/customization/
- Kyverno — Policy Reports — https://kyverno.io/docs/policy-reports/
- Kyverno — Security considerations — https://kyverno.io/docs/security/
- Kyverno — Troubleshooting — https://kyverno.io/docs/troubleshooting/
- Kyverno API reference (`ClusterPolicy`, `GlobalContextEntry`) — https://kyverno.io/docs/api-reference/
- Kyverno source — https://github.com/kyverno/kyverno
- JMESPath specification — https://jmespath.org/specification.html
- Kubernetes — Dynamic Admission Control (webhook timeouts, failure policy) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Authorization: checking API access (`SubjectAccessReview`) — https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — Using RBAC Authorization (aggregated ClusterRoles) — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes API concepts (resource paths) — https://kubernetes.io/docs/reference/using-api/api-concepts/
- OCI Image Specification — image config — https://github.com/opencontainers/image-spec/blob/main/config.md