# 5.4 Reglas de Mutación

> **Dominio 5 — Escritura de Políticas · Peso en el examen 2.91**
> Kyverno Certified Associate (KCA). Todo el contenido es original; toda afirmación externa está atribuida en **Referencias**.

---

## 1. El problema arquitectónico que resuelve la mutación

Kubernetes tiene dos mecanismos nativos para completar lo que el usuario no escribió:

1. **Defaulting de la API** — declarado en el esquema OpenAPI de un tipo integrado, compilado dentro del API server (`imagePullPolicy: Always` cuando el tag es `:latest`, `terminationGracePeriodSeconds: 30`). No podés extenderlo para tipos integrados.
2. **Defaulting de CRD** — `default:` en el esquema estructural de una `CustomResourceDefinition`. Solo para tus propias CRDs, y solo con valores estáticos.

Ninguno de los dos puede expresar política *organizacional*: "todo Pod en un namespace de tenant hereda la etiqueta de centro de costos del tenant", "todo pull de imagen se reescribe al mirror interno de Harbor", "toda carga de trabajo recibe `seccompProfile: RuntimeDefault` salvo que ya declare uno". Esa brecha es la razón de ser de la **admisión mutante**, y es el control de mayor apalancamiento que posee un equipo de plataforma — porque una mutación es el único tipo de política que *arregla* la petición en lugar de rechazarla.

### 1.1 Cuatro motores de producción

| Motor | Sin mutación | Con mutación |
|---|---|---|
| **Línea base de cumplimiento** (PSS `restricted`, seccomp, `runAsNonRoot`) | Cada equipo edita cada manifiesto; las reglas validate rechazan despliegues; fricción y shadow-IT | La plataforma define el default seguro; las reglas validate pasan a ser una red de contención que casi nunca se dispara |
| **Control de cadena de suministro** (registro air-gapped, pinning por digest) | Los manifiestos codifican `docker.io/...`; migrar de registro es una campaña de PRs a nivel organización | El registro se reescribe en la admisión; los manifiestos de origen siguen siendo portables |
| **Propagación de metadatos** (centro de costos, propietario, clasificación de datos) | Las etiquetas derivan; el chargeback y los selectores de network policy se pierden cargas de trabajo silenciosamente | Las etiquetas se derivan del Namespace en la admisión y se rellenan retroactivamente en objetos existentes |
| **Defaults de scheduling / topología** (tolerations, `topologySpreadConstraints`, `priorityClassName`, `nodeSelector`) | Cada chart reimplementa la ubicación de nodos; un cambio de taint rompe flotas enteras | Una regla, un rollout |

La propiedad distintiva: **la mutación traslada la carga de la corrección desde N equipos de aplicación hacia 1 equipo de plataforma**, y lo hace sin bifurcar los charts de Helm. Ese es el encuadre relevante para el examen y también el de producción.

### 1.2 Dónde corre la mutación dentro de la cadena de admisión

```
kubectl / controller
        │
        ▼
  API server: authn → authz
        │
        ▼
  ┌────────────────────────────────────────────┐
  │ MUTATING admission                         │
  │  1. built-in mutating plugins              │
  │  2. MutatingWebhookConfiguration webhooks  │  ← Kyverno admission controller
  │     (serial, ordered by config name)       │
  │  3. reinvocation pass (reinvocationPolicy: │
  │     IfNeeded) if any webhook mutated       │
  └────────────────────────────────────────────┘
        │
        ▼
  OpenAPI schema validation  ← a malformed patch is rejected HERE, not by Kyverno
        │
        ▼
  ┌────────────────────────────────────────────┐
  │ VALIDATING admission (parallel)            │  ← Kyverno validate rules, PSA
  └────────────────────────────────────────────┘
        │
        ▼
  etcd
```

Tres consecuencias que se malinterpretan constantemente en las revisiones de incidentes:

- **Los webhooks mutantes son seriales y se ordenan por el nombre de la configuración del webhook.** Dos inyectores que ambos agregan un contenedor (Kyverno + Istio) interactúan de forma dependiente del orden.
- **Kyverno registra su webhook mutante de recursos con `reinvocationPolicy: IfNeeded`.** Si otro webhook muta *después* de Kyverno, Kyverno se invoca una segunda vez. **Por lo tanto, toda regla mutate que escribas debe ser idempotente** — aplicarla dos veces debe producir el mismo objeto que aplicarla una vez. Un JSON patch de `add` a un array sin guarda es la regla no idempotente clásica y produce tolerations duplicadas o sidecars duplicados.
- **El patch lo valida el esquema del API server, no Kyverno.** Una regla que escribe `spec.contaienrs` produce un webhook exitoso seguido de un `strict decoding error` del API server. El `spec.schemaValidation` de Kyverno atrapa muchos de estos en el momento de admisión de la política, pero no todos.

### 1.3 Lo que Kyverno realmente devuelve

Kyverno no "edita el objeto". Calcula un **JSON Patch RFC 6902** contra el objeto entrante y lo devuelve codificado en base64 dentro del `AdmissionResponse`:

```json
{
  "allowed": true,
  "patchType": "JSONPatch",
  "patch": "W3sib3AiOiJhZGQiLCJwYXRoIjoiL3NwZWMvY29udGFpbmVycy8wL2ltYWdlUHVsbFBvbGljeSIsInZhbHVlIjoiSWZOb3RQcmVzZW50In1d"
}
```

que se decodifica como:

```json
[{"op":"add","path":"/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]
```

Cualquiera sea la sintaxis de autoría que uses — strategic merge, `patchesJson6902`, `foreach` — el formato en el cable siempre es este. Entender eso disuelve la mayor parte de la confusión sobre orden e idempotencia.

---

## 2. Anatomía de una regla mutate

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy            # or `Policy` for namespace scope
metadata:
  name: platform-defaults
  annotations:
    policies.kyverno.io/title: Platform Workload Defaults
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
spec:
  admission: true              # evaluate at admission time (default true)
  background: false            # background scanning; irrelevant for admission-time mutate
  failurePolicy: Fail          # per-policy webhook failurePolicy
  webhookTimeoutSeconds: 10    # per-policy webhook timeout (max 30)
  applyRules: All              # All | One — stop after the first matching rule
  rules:
    - name: default-image-pull-policy
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
                - UPDATE
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (image): "*:latest"
                imagePullPolicy: IfNotPresent
```

Obligatorios: `name`, `match` y exactamente un bloque `mutate`. Dentro de `mutate`, se puede usar exactamente **uno** de `patchStrategicMerge`, `patchesJson6902` o `foreach` por regla. `targets` y `mutateExistingOnPolicyUpdate` convierten la regla en una regla de *mutate-existing* (§8).

Las reglas se ejecutan **en el orden de declaración dentro de una política**. Entre políticas, el orden no es algo de lo que debas depender — si la regla B tiene que observar la salida de la regla A, poné ambas reglas en la misma política, en orden.

---

## 3. Estrategias de patch: comparación técnica

| | `patchStrategicMerge` | `patchesJson6902` | `foreach` |
|---|---|---|---|
| **Formato subyacente** | Strategic merge patch de Kubernetes + anchors de Kyverno | JSON Patch RFC 6902 | Cualquiera de los dos, aplicado por elemento de lista |
| **Semántica de listas** | Usa `patchMergeKey` de los struct tags de Go (`name` para containers, `containerPort` para ports, `mountPath` para volumeMounts) | Índice posicional o `-` para append | Iteración explícita, `{{ element }}` / `{{ elementIndex }}` |
| **Crea mapas padre faltantes** | Sí | **No** — un `add` a `/spec/tolerations/-` falla cuando `tolerations` está ausente | Hereda la sub-estrategia elegida |
| **Idempotente por construcción** | Sí para mapas; sí para listas con merge key | **No** para append a array (`/-`) | Depende |
| **Lógica condicional** | Anchors `()`, `+()`, `<()` | Solo `preconditions`, u operaciones `test` | `preconditions` por elemento |
| **Funciona con CRDs sin esquema Go** | Degrada a un merge JSON ingenuo — las listas se **reemplazan**, no se combinan | Sí, totalmente predecible | Sí |
| **Legibilidad a escala** | Alta | Baja | Media |
| **Uso típico** | Defaults, labels/annotations, campos de contenedor | Ediciones ordenadas, borrados por índice, claves escapadas, CRDs | Reescrituras por contenedor (imágenes, recursos, securityContext) |

### 3.1 La trampa de las CRDs

El strategic merge patch solo es "consciente de Kubernetes" para tipos cuyos structs de Go llevan tags `patchStrategy`/`patchMergeKey` — es decir, los integrados. Para una CRD, Kyverno no puede conocer la merge key, así que un `patchStrategicMerge` contra una lista dentro de un recurso personalizado **reemplaza la lista completa**. Para CRDs, preferí `patchesJson6902` o `foreach` + `patchesJson6902`. Esta es una de las sorpresas de producción más comunes cuando los equipos empiezan a mutar objetos `ArgoCD Application`, `Cluster` (CAPI) o `VirtualService`.

---

## 4. Strategic merge patch y los anchors de Kyverno

Los anchors son la extensión de Kyverno que vuelve condicional un patch declarativo.

| Anchor | Sintaxis | Válido en `mutate` | Semántica |
|---|---|---|---|
| **Condicional** | `(key)` | ✅ | Los campos hermanos en el mismo mapa se aplican **solo si** `key` existe y su valor coincide (se permiten comodines `*`, `?`). Dentro de una lista, además selecciona qué elementos se parchean. |
| **Agregar-si-no-existe** | `+(key)` | ✅ | Agrega `key` con el valor dado **solo cuando la clave está ausente**. Nunca sobrescribe. El subárbol completo es atómico — ver §4.2. |
| **Global** | `<(key)` | ✅ | La condición se evalúa contra el recurso en su conjunto; si falla, se omite el **patch entero**. |
| **Eliminación** | `key: null` | ✅ | Borrado estándar de strategic-merge. |
| Igualdad | `=(key)` | ❌ solo validate | |
| Existencia | `^(key)` | ❌ solo validate | |
| Negación | `X(key)` | ❌ solo validate | |

### 4.1 Anchor condicional — parchear solo lo que coincide

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: image-pull-policy-for-mutable-tags
spec:
  rules:
    - name: latest-to-ifnotpresent
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (image): "*:latest"
                imagePullPolicy: IfNotPresent
            initContainers:
              - (image): "*:latest"
                imagePullPolicy: IfNotPresent
```

`(image)` cumple dos funciones: es el *filtro* (solo los contenedores cuya imagen termina en `:latest`) y, como el mapa no tiene clave `name`, es el *selector* que Kyverno usa para encontrar el elemento destino. Los contenedores con un tag fijo o un digest quedan intactos.

### 4.2 Agregar-si-no-existe — el anchor de defaulting, y su trampa de atomicidad

Incorrecto (silenciosamente no hace nada para la mitad de tu flota):

```yaml
        patchStrategicMerge:
          spec:
            +(securityContext):
              runAsNonRoot: true
              seccompProfile:
                type: RuntimeDefault
```

Si un Pod ya tiene *cualquier* `spec.securityContext` — digamos `fsGroup: 2000` — el anchor ve la clave presente y omite **el subárbol entero**. El Pod no recibe ni `runAsNonRoot` ni `seccompProfile`. `+()` es atómico sobre el valor completo.

Correcto — anclá cada hoja, y dejá que el strategic merge cree el padre faltante:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pod-security-defaults
  annotations:
    policies.kyverno.io/title: Pod Security Standards Defaults
    policies.kyverno.io/description: >-
      Back-fills the pod- and container-level securityContext fields required by
      the restricted Pod Security Standard, without overriding values the
      workload author already set.
spec:
  admission: true
  background: false
  failurePolicy: Fail
  rules:
    - name: pod-level-defaults
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
                - UPDATE
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              +(runAsNonRoot): true
              +(seccompProfile):
                type: RuntimeDefault

    - name: container-level-defaults
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
                - UPDATE
      mutate:
        foreach:
          - list: request.object.spec.containers
            patchStrategicMerge:
              spec:
                containers:
                  - (name): "{{ element.name }}"
                    securityContext:
                      +(allowPrivilegeEscalation): false
                      +(privileged): false
                      +(capabilities):
                        drop:
                          - ALL
          - list: request.object.spec.initContainers || `[]`
            patchStrategicMerge:
              spec:
                initContainers:
                  - (name): "{{ element.name }}"
                    securityContext:
                      +(allowPrivilegeEscalation): false
                      +(capabilities):
                        drop:
                          - ALL
```

Notá que `+(capabilities)` sigue siendo atómico — deliberadamente. Si una carga de trabajo declara `capabilities: {add: [NET_BIND_SERVICE]}`, **no** le inyectamos silenciosamente `drop: [ALL]` cambiando su comportamiento en runtime; en su lugar, una regla validate separada lo marca. Elegir dónde la atomicidad es una característica y dónde es un defecto es la verdadera habilidad acá.

### 4.3 Anchor global — condicionar el patch completo a un estado no relacionado

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: quarantine-socket-mounters
spec:
  rules:
    - name: force-readonly-when-mounting-container-runtime-socket
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            <(volumes):
              - (hostPath):
                  path: "/var/run/containerd/containerd.sock"
            containers:
              - (name): "*"
                securityContext:
                  privileged: false
                  readOnlyRootFilesystem: true
```

El bloque `<(volumes)` afirma una condición sobre `spec.volumes`; **no** se parchea a sí mismo. Si ningún volumen monta el socket de containerd, la regla entera es un no-op. Sin el anchor global necesitarías una `precondition` con una expresión JMESPath `contains(...)` — el anchor mantiene la condición y el patch estructuralmente adyacentes.

### 4.4 Eliminación

```yaml
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              kubectl.kubernetes.io/last-applied-configuration: null
              scheduler.alpha.kubernetes.io/critical-pod: null
          spec:
            (hostNetwork): true
            hostNetwork: false
```

El segundo bloque se lee: *si* `hostNetwork` es `true`, ponelo en `false`. Escribir `hostNetwork: false` incondicionalmente también funcionaría, pero la forma condicional mantiene vacío el patch emitido para el 99% de los Pods que nunca lo definen — lo que mantiene limpios el rastro de auditoría y los Events.

---

## 5. JSON patches RFC 6902

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ingress-hardening
spec:
  rules:
    - name: add-proxy-limits
      match:
        any:
          - resources:
              kinds:
                - networking.k8s.io/v1/Ingress
              operations:
                - CREATE
                - UPDATE
      preconditions:
        all:
          - key: "{{ request.object.metadata.annotations || '{}' | keys(@) }}"
            operator: AllNotIn
            value:
              - nginx.ingress.kubernetes.io/proxy-body-size
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size"
            value: "8m"
          - op: add
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-read-timeout"
            value: "60"
```

### 5.1 Escapado de JSON Pointer — el defecto número uno de `patchesJson6902`

RFC 6901 reserva dos caracteres dentro de un segmento de puntero:

| Carácter literal en la clave | Debe escribirse como |
|---|---|
| `/` | `~1` |
| `~` | `~0` |

Así, la clave de annotation `nginx.ingress.kubernetes.io/proxy-body-size` se convierte en el segmento de ruta `nginx.ingress.kubernetes.io~1proxy-body-size`. Si te equivocás acá, el patch o bien apunta a una ruta anidada inexistente o el API server rechaza el objeto resultante. **El orden importa al escapar a mano: reemplazá primero `~`, después `/`.**

### 5.2 `add` no crea padres

```yaml
        patchesJson6902: |-
          - op: add
            path: "/spec/tolerations/-"
            value:
              key: workload-class
              operator: Equal
              value: batch
              effect: NoSchedule
```

Si el Pod no tiene `spec.tolerations`, esto falla. Dos formas seguras:

**(a) Protegé con una precondition y emití el array completo cuando esté ausente:**

```yaml
      preconditions:
        all:
          - key: "{{ request.object.spec.tolerations[?key=='workload-class'] | length(@) }}"
            operator: Equals
            value: 0
      mutate:
        patchStrategicMerge:
          spec:
            tolerations:
              - key: workload-class
                operator: Equal
                value: batch
                effect: NoSchedule
```

El strategic merge crea `tolerations` si está ausente, y la precondition hace que la regla sea idempotente frente a la reinvocación. **Este es el patrón que hay que usar.**

**(b) Dos operaciones, inicializando primero** — solo válido si aceptás pisar lo existente:

```yaml
        patchesJson6902: |-
          - op: add
            path: "/spec/tolerations"
            value: []            # DESTRUCTIVE if tolerations already exist
          - op: add
            path: "/spec/tolerations/-"
            value: { ... }
```

No pongas (b) en producción.

### 5.3 Cuándo `patchesJson6902` es genuinamente la herramienta correcta

- Borrar un elemento por índice: `- op: remove` / `path: "/spec/containers/2"`.
- Editar claves que contienen `/` o `~`.
- Editar CRDs donde el strategic merge reemplazaría listas.
- Guardas con `op: test`: `- op: test` / `path: "/spec/replicas"` / `value: 1` — el patch entero aborta si el test falla, lo que te da semántica atómica de compare-and-set dentro de un solo patch.

---

## 6. `foreach`: mutar listas elemento por elemento

`foreach` itera sobre una lista seleccionada por JMESPath y aplica un sub-patch por elemento. Dentro del bucle, `{{ element }}` es el ítem actual y `{{ elementIndex }}` su posición de base cero.

### 6.1 Reescritura de registro para un clúster air-gapped o con caché pull-through

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: rewrite-public-registries
  annotations:
    policies.kyverno.io/title: Redirect Public Registries to Internal Mirror
    policies.kyverno.io/description: >-
      Normalises every image reference and rewrites docker.io / quay.io / ghcr.io
      pulls to the internal Harbor proxy projects. Images already hosted on the
      internal registry are left untouched so the rule is idempotent under
      webhook reinvocation.
spec:
  admission: true
  background: false
  failurePolicy: Fail
  rules:
    - name: rewrite-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
                - UPDATE
      mutate:
        foreach:
          - list: request.object.spec.containers
            preconditions:
              all:
                - key: "{{ image_normalize(element.image) }}"
                  operator: NotEquals
                  value: "harbor.internal.example.net/*"
            patchStrategicMerge:
              spec:
                containers:
                  - (name): "{{ element.name }}"
                    image: >-
                      {{ regex_replace_all('^(docker\.io|quay\.io|ghcr\.io|registry\.k8s\.io)/(.*)$',
                         image_normalize(element.image),
                         'harbor.internal.example.net/$1/$2') }}

          - list: request.object.spec.initContainers || `[]`
            preconditions:
              all:
                - key: "{{ image_normalize(element.image) }}"
                  operator: NotEquals
                  value: "harbor.internal.example.net/*"
            patchStrategicMerge:
              spec:
                initContainers:
                  - (name): "{{ element.name }}"
                    image: >-
                      {{ regex_replace_all('^(docker\.io|quay\.io|ghcr\.io|registry\.k8s\.io)/(.*)$',
                         image_normalize(element.image),
                         'harbor.internal.example.net/$1/$2') }}
```

Por qué `image_normalize` primero: un `nginx` pelado no es `docker.io/nginx` textualmente. `image_normalize` expande la forma corta a su forma completamente calificada `registry/repository:tag` para que la regex tenga un componente de registro donde anclarse. Saltearlo es la razón por la que las políticas ingenuas de reescritura de registro destrozan `nginx:1.27` convirtiéndolo en `harbor.internal.example.net` con el tag perdido.

Efecto:

| Imagen de entrada | Normalizada | Salida |
|---|---|---|
| `nginx` | `docker.io/nginx:latest` | `harbor.internal.example.net/docker.io/nginx:latest` |
| `quay.io/prometheus/node-exporter:v1.8.2` | sin cambios | `harbor.internal.example.net/quay.io/prometheus/node-exporter:v1.8.2` |
| `harbor.internal.example.net/apps/api:2.1.0` | sin cambios | intacta (precondition) |

### 6.2 `order` e iteración destructiva

Cuando un `foreach` elimina elementos, iterá en orden **descendente** para que las eliminaciones tempranas no desplacen los índices de las posteriores:

```yaml
      mutate:
        foreach:
          - list: request.object.spec.template.spec.volumes
            order: Descending
            preconditions:
              all:
                - key: "{{ element.hostPath.path || '' }}"
                  operator: Equals
                  value: "/var/lib/kubelet"
            patchesJson6902: |-
              - op: remove
                path: "/spec/template/spec/volumes/{{ elementIndex }}"
```

`order` acepta `Ascending` (por defecto) o `Descending`.

### 6.3 `foreach` vs. un único strategic merge

Usá `patchStrategicMerge` a secas con `(name): "*"` cuando el valor parcheado es **idéntico** para todos los elementos. Usá `foreach` cuando el valor se **deriva del elemento** — una imagen reescrita, un default de recursos por contenedor calculado a partir del nombre del contenedor, un mount derivado de `VOLUME`. La versión con `foreach` cuesta una evaluación JMESPath por elemento; en un Pod de 40 contenedores eso es medible en el histograma de latencia del webhook, pero nunca es el cuello de botella.

---

## 7. Variables, contexto y JMESPath dentro de las mutaciones

Raíces disponibles en una regla mutate en tiempo de admisión:

| Variable | Contenido |
|---|---|
| `request.object` | El objeto entrante (posterior a cualquier mutación previa en el mismo pase de admisión) |
| `request.oldObject` | Estado previo en `UPDATE`/`DELETE`; `null` en `CREATE` |
| `request.operation` | `CREATE` \| `UPDATE` \| `DELETE` \| `CONNECT` |
| `request.userInfo` | `username`, `groups`, `uid` del solicitante |
| `request.namespace` | Namespace de la petición |
| `serviceAccountName`, `serviceAccountNamespace` | Divisiones de conveniencia de `request.userInfo.username` |
| `element`, `elementIndex` | Dentro de `foreach` |
| `target` | Dentro de una regla de **mutate-existing**: el objeto que se está parcheando (§8) |
| `images` | Referencias de imagen parseadas por Kyverno: `images.containers.<name>.{registry,path,name,tag,digest}` |

### 7.1 Traer contexto externo

```yaml
    - name: inject-tenant-defaults
      match:
        any:
          - resources:
              kinds:
                - Pod
      context:
        # 1. Read a ConfigMap in the Kyverno namespace
        - name: tenantcfg
          configMap:
            name: tenant-defaults
            namespace: platform-system
        # 2. Read the Pod's own Namespace object via the API
        - name: ns
          apiCall:
            urlPath: "/api/v1/namespaces/{{ request.namespace }}"
            jmesPath: "metadata.labels"
        # 3. Derive a value with pure JMESPath
        - name: costCenter
          variable:
            jmesPath: 'ns."company.io/cost-center"'
            default: "unassigned"
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              +(company.io/cost-center): "{{ costCenter }}"
              +(company.io/tier): "{{ tenantcfg.data.tier }}"
          spec:
            +(priorityClassName): "{{ tenantcfg.data.priorityClass }}"
```

Tres notas operativas:

- El contexto `configMap` se sirve desde una **caché de informer**; una edición del ConfigMap se propaga en segundos, no instantáneamente. No lo uses para nada con un requisito duro de consistencia.
- `apiCall` corre en la **ruta caliente de admisión**. Está acotado por `webhookTimeoutSeconds` (máx. 30, por defecto 10). Un `apiCall` a un API server agregado lento con `failurePolicy: Fail` va a tirar abajo las escrituras de tu clúster. Preferí el contexto `configMap`, o una `variable` derivada de datos que ya están en la petición.
- `default:` en un contexto `variable` es lo que evita que una etiqueta faltante haga fallar la regla entera. Sin él, una variable irresoluble hace que Kyverno falle la regla (y, con `failurePolicy: Fail`, la petición).

### 7.2 Funciones JMESPath que vale la pena memorizar para mutaciones

| Función | Uso en mutación |
|---|---|
| `regex_replace_all(regex, src, repl)` | Reescrituras de registro; expansión de grupos de captura `$1`/`${1}` |
| `regex_replace_all_literal(regex, src, repl)` | Lo mismo, con el reemplazo tratado literalmente |
| `image_normalize(image)` | Expandir referencias cortas de imagen antes de hacer matching |
| `to_upper` / `to_lower` | Normalización de labels/annotations |
| `split(str, sep)` / `join(sep, arr)` | Derivar valores a partir de nombres |
| `truncate(str, n)` | Encajar un valor derivado dentro del límite de 63 caracteres de una etiqueta |
| `sha256(str)` | Identificadores cortos estables |
| `semver_compare(a, constraint)` | Mutaciones condicionadas por versión |
| `add`, `subtract`, `multiply`, `divide` | Calcular valores de recursos (con conciencia de quantity) |
| `parse_json` / `to_string` | Valores de ConfigMap, que siempre son strings |
| `time_add`, `time_now_utc` | Annotations de TTL / expiración |

Atención al techo de longitud de las etiquetas: `truncate(to_lower(...), 63)` no es opcional cuando el origen es un campo de forma libre.

---

## 8. Mutar recursos **existentes**

Todo lo anterior corre en la admisión y por lo tanto solo afecta escrituras *futuras*. El `mutate.targets` de Kyverno extiende la misma gramática de reglas a objetos que ya están en etcd, ejecutados por el **controlador de background**.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-cost-center
  annotations:
    policies.kyverno.io/title: Propagate Cost Center From Namespace
spec:
  rules:
    - name: sync-to-deployments
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.\"company.io/cost-center\" || '' }}"
            operator: NotEquals
            value: ""
      mutate:
        mutateExistingOnPolicyUpdate: true
        targets:
          - apiVersion: apps/v1
            kind: Deployment
            namespace: "{{ request.object.metadata.name }}"
          - apiVersion: apps/v1
            kind: StatefulSet
            namespace: "{{ request.object.metadata.name }}"
        patchStrategicMerge:
          metadata:
            labels:
              company.io/cost-center: >-
                {{ request.object.metadata.labels."company.io/cost-center" }}
```

### 8.1 Semántica que tenés que internalizar

| Aspecto | Mutate en tiempo de admisión | Mutate-existing (`targets`) |
|---|---|---|
| Ejecutado por | controlador de admisión (in-band) | controlador de background (out-of-band) |
| Disparador | la propia petición que hizo match | la petición que hizo match, **más** la creación/actualización de la política si `mutateExistingOnPolicyUpdate: true` |
| Objeto parcheado | el objeto de la petición | todo objeto que coincida con `targets` |
| Modo de falla | petición denegada (`failurePolicy: Fail`) o permitida sin mutar (`Ignore`) | Event de Warning; la petición disparadora **no** se ve afectada |
| Variable del objeto parcheado | `request.object` | **`target`** |
| RBAC necesario | ninguno más allá del webhook | permisos explícitos de `update`/`patch` (§8.2) |
| Atomicidad | sí, una transacción de API | no — best-effort, consistencia eventual |

Dentro de una regla mutate-existing, `request.object` es el **disparador** y `target` es el **objeto que se está parcheando**. Confundirlos es el error de autoría más común:

```yaml
        patchStrategicMerge:
          metadata:
            annotations:
              # value taken from the TRIGGER (the Namespace)
              company.io/synced-from: "{{ request.object.metadata.name }}"
              # value taken from the TARGET (each Deployment)
              company.io/previous-replicas: "{{ target.spec.replicas }}"
```

### 8.2 RBAC — la razón por la que mutate-existing "no hace nada silenciosamente"

El controlador de background de Kyverno viene con permisos deliberadamente estrechos. Para dejarlo escribir en un tipo de recurso hay que agregar un ClusterRole agregable:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:background-controller:workload-mutation
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups:
      - apps
    resources:
      - deployments
      - statefulsets
    verbs:
      - get
      - list
      - watch
      - update
      - patch
```

Sin eso:

```
$ kubectl -n platform-system logs deploy/kyverno-background-controller | grep -i forbidden
E0813 11:04:22.118  mutate-existing  failed to update target  {"policy": "propagate-cost-center",
  "rule": "sync-to-deployments", "target": "apps/v1/Deployment/team-a/api",
  "error": "deployments.apps \"api\" is forbidden: User
  \"system:serviceaccount:platform-system:kyverno-background-controller\" cannot patch
  resource \"deployments\" in API group \"apps\" in the namespace \"team-a\""}
```

### 8.3 No apuntes a Pods

Casi todos los campos de un Pod son inmutables después de la creación — `spec.containers[*].image` es mutable, `securityContext`, `volumes` y `nodeSelector` no lo son. Una regla mutate-existing que apunta a Pods produce un flujo de eventos `Warning PolicyError` y nunca converge. **Apuntá al controlador** (`Deployment`, `StatefulSet`, `DaemonSet`, `CronJob`) y dejá que el rollout reemplace los Pods. Notá que esto significa que la mutación *no* se aplica a los Pods en ejecución hasta el próximo rollout — decilo explícitamente en la `description` de tu política, porque los operadores van a preguntar.

### 8.4 Protección contra bucles

Si el match del disparador y el selector de `targets` se solapan, cada patch genera un `UPDATE` que vuelve a disparar la regla. Kyverno detecta que un patch es un no-op y se detiene, así que una regla idempotente bien escrita converge después de una pasada. Una regla que escribe un valor cambiante (un timestamp, un contador, `time_now_utc()`) nunca converge y va a poner al controlador de background en un bucle caliente contra el API server. **Nunca escribas un valor no determinístico en una regla mutate-existing cuyo target también pueda ser su disparador.**

---

## 9. Auto-gen: reglas de Pod y controladores de Pod

Una regla que solo hace match con `Pod` se perdería todo Deployment — el Deployment se admite primero, y sus Pods los crea después el ServiceAccount del controller-manager (que tal vez hayas excluido). Kyverno resuelve esto **autogenerando** copias de tu regla para los controladores de Pod, reenraizando todas las rutas en `spec.template`.

```
$ kubectl get clusterpolicy pod-security-defaults -o yaml | yq '.spec.rules[].name'
pod-level-defaults
container-level-defaults
autogen-pod-level-defaults
autogen-container-level-defaults
autogen-cronjob-pod-level-defaults
autogen-cronjob-container-level-defaults
```

Controlalo con una annotation en la política:

```yaml
metadata:
  annotations:
    # Restrict to specific controllers
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet
    # Or disable entirely
    # pod-policies.kyverno.io/autogen-controllers: none
```

Reglas que rompen el auto-gen — memorizá estas, son típicas de examen y típicas de incidente:

1. **El bloque `match` incluye kinds distintos de `Pod`.** El auto-gen se omite para toda la regla. Si necesitás Pods y además una CRD, escribí dos reglas.
2. **La regla referencia `request.object.spec.containers` en un `context` o una `precondition`** mientras que la variante generada necesita `request.object.spec.template.spec.containers`. Kyverno reescribe las rutas dentro de `patchStrategicMerge` y `patchesJson6902`, y dentro de `foreach.list`, pero conviene verificar en lugar de asumir — leé la regla generada.
3. **`patchesJson6902` con rutas absolutas escritas a mano** — a la regla generada se le antepone `/spec/template`; confirmá que el resultado es el que pretendías.
4. **El auto-gen también produce reglas `Pod` para la creación directa de Pods.** Un Pod creado por un Job creado por un CronJob queda cubierto por las reglas `autogen-cronjob-*`.

---

## 10. Orden, idempotencia y conflictos

### 10.1 Dentro de una política

Las reglas se ejecutan de arriba hacia abajo. La regla 2 ve la salida de la regla 1. `spec.applyRules: One` detiene la ejecución tras la primera regla que hace match — útil para una cadena de fallback priorizada (reescribir para el tenant A, si no para el tenant B, si no el default).

### 10.2 Entre políticas

No están ordenadas de una manera de la que debas depender. Si tenés políticas `set-registry` y `pin-digest` y la segunda debe correr después de la primera, fusionalas en una sola política con dos reglas.

### 10.3 Frente a otros webhooks

El API server llama a los webhooks mutantes de forma serial, ordenados por el nombre de la `MutatingWebhookConfiguration`. La de Kyverno es `kyverno-resource-mutating-webhook-cfg`; la de Istio es típicamente `istio-sidecar-injector`. `i` < `k`, así que Istio corre primero y Kyverno ve el contenedor `istio-proxy` ya inyectado. Invertí eso con otro service mesh y tu `foreach` sobre `spec.containers` no va a ver el sidecar en la primera pasada — solo en la segunda pasada de `reinvocationPolicy: IfNeeded`.

**El requisito de corrección que esto impone:** toda regla mutate debe ser segura de aplicar dos veces. Probalo:

```
$ kyverno apply policies/ --resource out.yaml   # feed the mutated output back in
```

Si la salida de la segunda corrida difiere de su entrada, la regla no es idempotente. Arreglalo con una precondition o un anchor `+()`/`()`.

### 10.4 Interacción con `verifyImages`

Las reglas `verifyImages` con `mutateDigest: true` (el valor por defecto) reescriben `image: repo/app:1.2.3` como `image: repo/app:1.2.3@sha256:...` tras la verificación de firma. Si tu mutación de reescritura de registro corre después de eso, su regex debe tolerar un sufijo de digest. Anclar la regex en el prefijo del registro (`^(docker\.io|quay\.io)/(.*)$`) en lugar del tag es lo que vuelve seguro el §6.1 acá.

---

## 11. Verificación

### 11.1 Dry-run del lado del servidor — el comando individual de mayor valor

```
$ kubectl -n team-a apply --dry-run=server -f pod.yaml -o yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    company.io/cost-center: cc-4471
  name: web
  namespace: team-a
spec:
  containers:
  - image: harbor.internal.example.net/docker.io/nginx:latest
    imagePullPolicy: IfNotPresent
    name: web
    resources: {}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      privileged: false
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  ...
```

`--dry-run=server` ejecuta **la cadena de admisión real completa** — cada webhook, en el orden real, con las políticas y el contexto reales del clúster — y devuelve el objeto que el API server *habría* persistido, sin persistirlo. Nada más reproduce fielmente el entrelazado de webhooks. Convertilo en un paso obligatorio de tu pipeline de promoción de políticas.

### 11.2 Kyverno CLI — evaluación offline

```
$ kyverno apply policies/pod-security-defaults.yaml --resource tests/pod-plain.yaml

Applying 2 policy rule(s) to 1 resource(s)...

mutate policy pod-security-defaults applied to team-a/Pod/web:

apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: team-a
spec:
  containers:
  - image: nginx:1.27.1
    name: web
    resources: {}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      privileged: false
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
---

pass: 2, fail: 0, warn: 0, error: 0, skip: 0
```

Flags útiles:

| Flag | Propósito |
|---|---|
| `--resource <file\|dir>` | Recursos a evaluar (repetible) |
| `--cluster` | Obtener los recursos del clúster vivo en lugar de archivos |
| `--set <key>=<value>` / `--values-file` | Suministrar variables (`request.operation`, `request.userInfo`, contexto de ConfigMap) |
| `--policy-report` | Emitir un `PolicyReport` en lugar de salida legible por humanos |
| `--detailed-results` | Desglose por regla |
| `-v 4` | Trazado verboso del motor |

Para una regla que lee contexto, `--values-file` es obligatorio offline:

```yaml
# values.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
policies:
  - name: propagate-cost-center
    rules:
      - name: sync-to-deployments
        values:
          costCenter: cc-4471
namespaceSelector:
  - name: team-a
    labels:
      company.io/cost-center: cc-4471
```

### 11.3 Tests de regresión declarativos

`kyverno test` es lo que corresponde en CI. Para reglas mutate, afirmá el **objeto parcheado exacto**.

```yaml
# tests/kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: pod-security-defaults
policies:
  - ../policies/pod-security-defaults.yaml
resources:
  - resources/pod-plain.yaml
  - resources/pod-already-hardened.yaml
results:
  - policy: pod-security-defaults
    rule: pod-level-defaults
    kind: Pod
    resources:
      - web
    patchedResource: patched/pod-plain-patched.yaml
    result: pass
  - policy: pod-security-defaults
    rule: pod-level-defaults
    kind: Pod
    resources:
      - hardened
    result: skip
```

```
$ kyverno test tests/

Loading test  ( tests/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 2 policy rule(s) to 2 resource(s) ...
  Checking results ...

│───│──────────────────────│─────────────────────│──────────────────│────────│
│ # │ POLICY               │ RULE                │ RESOURCE         │ RESULT │
│───│──────────────────────│─────────────────────│──────────────────│────────│
│ 1 │ pod-security-defaults│ pod-level-defaults  │ team-a/Pod/web   │ Pass   │
│ 2 │ pod-security-defaults│ pod-level-defaults  │ team-a/Pod/harde │ Pass   │
│───│──────────────────────│─────────────────────│──────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

`patchedResource` es la aserción que atrapa los bugs de atomicidad de anchors (§4.2). Un `result: pass` por sí solo no lo haría — la regla "se aplicó", solo que no aplicó nada útil. **Fijá siempre `patchedResource` en los tests de mutate.**

### 11.4 Confirmar que el webhook está siquiera registrado

```
$ kubectl get mutatingwebhookconfigurations
NAME                                     WEBHOOKS   AGE
kyverno-policy-mutating-webhook-cfg      1          31d
kyverno-resource-mutating-webhook-cfg    2          31d
kyverno-verify-mutating-webhook-cfg      1          31d

$ kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.failurePolicy}{"\t"}{.timeoutSeconds}{"\t"}{.reinvocationPolicy}{"\n"}{end}'
mutate.kyverno.svc-fail	    Fail	 10	IfNeeded
mutate.kyverno.svc-ignore	Ignore	 10	IfNeeded
```

Kyverno mantiene esta configuración **dinámicamente**: la lista `rules` contiene solo los tipos de recurso que efectivamente coinciden con las políticas instaladas. Si instalás tu primera política que muta Ingress, el webhook adquiere una regla de `ingresses` unos segundos después. Si `rules` no lista tu kind, nunca va a ocurrir ninguna mutación — sin importar cuán correcta sea la política.

```
$ kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
    -o jsonpath='{.webhooks[0].rules}' | jq '.[].resources'
[ "pods", "pods/ephemeralcontainers" ]
[ "deployments", "statefulsets", "daemonsets", "jobs", "cronjobs" ]
```

### 11.5 Events

```
$ kubectl -n team-a get events --field-selector reason=PolicyApplied --sort-by=.lastTimestamp
LAST SEEN   TYPE     REASON          OBJECT          MESSAGE
12s         Normal   PolicyApplied   pod/web         policy pod-security-defaults/pod-level-defaults applied
12s         Normal   PolicyApplied   pod/web         policy rewrite-public-registries/rewrite-containers applied
```

Notá la asimetría en el reporte: **las reglas mutate se manifiestan como Events, no como entradas de `PolicyReport`** como sí hacen los resultados de `validate` y `verifyImages`. La evidencia autoritativa de que ocurrió una mutación es el objeto mutado en sí más estos Events. Construí tus dashboards en consecuencia.

---

## 12. Manual de diagnóstico de fallas

| Síntoma | Causa probable | Comando que lo demuestra |
|---|---|---|
| La política existe, nada se muta, no hay Events | Recurso filtrado por los `resourceFilters` del ConfigMap de Kyverno (los valores por defecto excluyen `kube-system`, el namespace de Kyverno y varios kinds) | `kubectl -n <kyverno-ns> get cm kyverno -o jsonpath='{.data.resourceFilters}'` |
| Lo mismo, y el namespace no está filtrado | El kind no está presente en las `rules` del webhook — la política no compiló | `kubectl get clusterpolicy <p> -o jsonpath='{.status.conditions}'` y revisar `READY` |
| `kubectl get clusterpolicy` muestra `READY: False` | La validación de esquema del patch falló en la admisión de la política | `kubectl describe clusterpolicy <p>` |
| Funciona para Pods, no para Deployments | Auto-gen omitido (el match incluye kinds distintos de Pod) o deshabilitado por annotation | `kubectl get clusterpolicy <p> -o yaml \| grep autogen-` |
| Mutación aplicada dos veces (toleration / sidecar duplicado) | Regla no idempotente + reentrada por `reinvocationPolicy: IfNeeded` | Reingresar la salida: `kyverno apply policies/ --resource mutated.yaml` |
| El anchor `+()` parece no hacer nada | La clave padre ya existe ⇒ se omite el subárbol entero (§4.2) | Comparar el mapa padre existente del objeto contra la clave anclada |
| `patchesJson6902` "path does not exist" | Padre faltante, o `/` sin escapar en una clave (RFC 6901) | Decodificar la ruta de la regla; verificar `~1`/`~0` |
| El objeto queda sin mutar silenciosamente durante una caída de Kyverno | `failurePolicy: Ignore` — falla abierto por diseño | `kubectl get mutatingwebhookconfiguration ... -o yaml \| grep failurePolicy` |
| Las escrituras de la API se cuelgan o dan 500 durante una caída de Kyverno | `failurePolicy: Fail` — falla cerrado | Lo mismo; además revisar la readiness del controlador |
| `context deadline exceeded` intermitente en la admisión | Contexto `apiCall` en la ruta caliente excediendo `webhookTimeoutSeconds` | Logs de Kyverno; métrica `kyverno_admission_review_duration_seconds` |
| Mutate-existing no hace nada | Falta el RBAC del controlador de background (§8.2) | `kubectl -n <kyverno-ns> logs deploy/kyverno-background-controller \| grep -i forbidden` |
| Mutate-existing entra en bucle infinito | Valor no determinístico en una regla que se autodispara (§8.4) | Avalancha de Events en el target; `kyverno_policy_results_total` en aumento |
| Un namespace queda exento sin motivo aparente | Una `PolicyException` hace match con él | `kubectl get polex -A` |
| Un error de resolución de variable mata la petición | Falta `default:` en un contexto `variable` | Logs de Kyverno: `variable substitution failed` |

Subí la verbosidad del motor cuando lo anterior no sea concluyente:

```
$ kubectl -n platform-system set env deploy/kyverno-admission-controller -- -v=4
deployment.apps/kyverno-admission-controller env updated

$ kubectl -n platform-system logs -f deploy/kyverno-admission-controller | grep -i mutate
I0813 11:41:07.552  engine.mutate  mutate rule applied successfully  {"policy":"pod-security-defaults",
  "rule":"pod-level-defaults","kind":"Pod","namespace":"team-a","name":"web",
  "patches":["{\"op\":\"add\",\"path\":\"/spec/securityContext\",\"value\":{\"runAsNonRoot\":true,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}}}"]}
```

Revertí la verbosidad después — `-v=4` en un clúster ocupado tiene un costo significativo en volumen de logs y CPU.

Métricas sobre las que alertar:

| Métrica | Alertar cuando |
|---|---|
| `kyverno_admission_review_duration_seconds` | el p99 se acerca a `webhookTimeoutSeconds` |
| `kyverno_admission_requests_total` | caída repentina ⇒ webhook desregistrado |
| `kyverno_policy_results_total{rule_type="mutate"}` | crecimiento inexplicado ⇒ bucle de mutate-existing |
| `kyverno_policy_execution_duration_seconds` | regresión por regla tras un cambio de política |

---

## 13. El panorama comparativo

| | **Kyverno `mutate`** | **Mutación de Gatekeeper** (`Assign`, `AssignMetadata`, `ModifySet`, `AssignImage`) | **`MutatingAdmissionPolicy`** (CEL in-tree) | **Webhook a medida** |
|---|---|---|---|---|
| Lenguaje | YAML + anchors + JMESPath | YAML, una CRD por forma de operación | Expresiones CEL + Apply-Configuration o JSON Patch | Go/Rust/… |
| Lógica Turing-completa | No (deliberadamente) | No | No | Sí |
| Datos externos en la admisión | ConfigMap, llamada a la API, registro de imágenes, Secret | Limitado (proveedor de `external data`, beta) | No — solo request/authorizer | Cualquier cosa |
| Mutar objetos **existentes** | Sí (`targets`) | No | No | Solo si construís un controlador |
| Componentes adicionales | Controladores de Kyverno | Controladores de Gatekeeper | **Ninguno** — corre dentro del API server | Los tuyos, para construir, escalar, certificar y atender guardias |
| Latencia agregada | un salto de red | un salto de red | en proceso | un salto de red |
| Radio de impacto en disponibilidad | webhook caído ⇒ fail-open o fail-closed | igual | ninguno | igual |
| Madurez para mutación | GA, biblioteca de políticas amplia | GA | beta a partir de Kubernetes 1.34 | n/a |
| Auto-gen para controladores de Pod | Sí | No | No | No |
| Mejor para | El caso general; cualquier cosa que necesite contexto externo o back-fill | Organizaciones ya estandarizadas en OPA/Rego para validación | Defaults simples, de ruta caliente y alto volumen, sin datos externos | Lógica genuinamente a medida que ningún motor de políticas puede expresar |

**Guía arquitectónica.** Donde una mutación es simple, estática y está en una ruta de alto QPS, `MutatingAdmissionPolicy` es estrictamente mejor — no cuesta un salto de red y no puede tirar abajo tu clúster. Donde una mutación necesita contexto externo (`ConfigMap`, `apiCall`), necesita tocar objetos que ya están en etcd (`targets`), o necesita auto-gen a través de controladores de Pod, Kyverno es la respuesta y actualmente no hay equivalente in-tree. Esperá un estado estable híbrido, no una migración. Un webhook a medida debería ser el último recurso: te estás comprometiendo a operar un componente en la ruta crítica de cada escritura del clúster.

---

## 14. Resumen enfocado en el examen

- Un bloque `mutate` por regla; exactamente uno de `patchStrategicMerge` | `patchesJson6902` | `foreach`.
- Anchors de mutate: `()` condicional, `+()` agregar-si-ausente, `<()` global. `=()`, `^()`, `X()` son **solo de validate**.
- `+()` es **atómico sobre su valor completo** — anclá hojas, no padres, cuando quieras defaulting parcial.
- `patchesJson6902` **no** crea padres faltantes; escapá `/` como `~1` y `~` como `~0` (RFC 6901).
- `foreach` provee `{{ element }}` y `{{ elementIndex }}`; usá `order: Descending` al eliminar.
- `targets` + `mutateExistingOnPolicyUpdate: true` = mutar existentes; requiere un ClusterRole etiquetado con `rbac.kyverno.io/aggregate-to-background-controller: "true"`; el objeto parcheado es `target`, el disparador es `request.object`.
- El auto-gen crea reglas `autogen-*` para los controladores de Pod, pero solo cuando la regla hace match **únicamente** con Pods.
- El webhook mutante de recursos de Kyverno usa `reinvocationPolicy: IfNeeded` ⇒ **las reglas deben ser idempotentes**.
- Verificá con `kubectl apply --dry-run=server -o yaml` (en el clúster) y `kyverno test` con `patchedResource` (CI).
- Los resultados de mutación aparecen como Events, no como entradas de `PolicyReport`.

---

## Referencias

**CNCF / certificación**
- Currículum KCA (CNCF): https://github.com/cncf/curriculum
- PDF del currículum KCA: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- Proyecto Kyverno (CNCF Incubating): https://kyverno.io/

**Documentación de Kyverno**
- Reglas mutate: https://kyverno.io/docs/writing-policies/mutate/
- Anchors (condicional, agregar-si-no-existe, global): https://kyverno.io/docs/writing-policies/validate/#anchors
- Preconditions: https://kyverno.io/docs/writing-policies/preconditions/
- Variables y contexto externo: https://kyverno.io/docs/writing-policies/external-data-sources/
- Filtros personalizados de JMESPath: https://kyverno.io/docs/writing-policies/jmespath/
- Autogeneración para controladores de Pod: https://kyverno.io/docs/writing-policies/autogen/
- Excepciones de políticas: https://kyverno.io/docs/writing-policies/exceptions/
- Verificación de imágenes (`mutateDigest`): https://kyverno.io/docs/writing-policies/verify-images/
- Kyverno CLI (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Instalación, configuración del webhook y del ConfigMap: https://kyverno.io/docs/installation/customization/
- Guía de troubleshooting: https://kyverno.io/docs/troubleshooting/
- Biblioteca de políticas listas para usar: https://kyverno.io/policies/

**Documentación de Kubernetes**
- Dynamic Admission Control (webhooks mutantes, orden, `reinvocationPolicy`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Control de admisión en Kubernetes: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Actualizar objetos de la API en el lugar con `kubectl patch` (strategic merge, merge keys): https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- Dry run del lado del servidor: https://kubernetes.io/docs/reference/using-api/api-concepts/#dry-run
- Mutating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Labels y selectores (límite de 63 caracteres en el valor): https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/

**Estándares**
- RFC 6902 — JavaScript Object Notation (JSON) Patch: https://datatracker.ietf.org/doc/html/rfc6902
- RFC 6901 — JavaScript Object Notation (JSON) Pointer (escapado `~0` / `~1`): https://datatracker.ietf.org/doc/html/rfc6901
- Especificación de JMESPath: https://jmespath.org/specification.html

**Comparativa**
- Mutación en OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/mutation/