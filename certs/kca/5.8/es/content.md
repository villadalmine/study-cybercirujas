# 5.8 JSON Patches

> **Dominio:** Escritura de políticas de Kyverno · **Peso en el examen:** 2,91 %
> **Prerrequisitos:** 5.5 Reglas mutate, 5.3 Preconditions, 5.11 JMESPath

---

## 1. Motivación: el problema arquitectónico que resuelve JSON Patch

Todo controlador de admisión mutante tiene que responder una pregunta: *dado un objeto que el API server está a punto de persistir, ¿cómo expreso un cambio sobre él?* La respuesta ingenua —"mandá el objeto nuevo completo"— es inservible en un motor de políticas, porque quien escribe la política nunca vio el objeto. Una política que inyecta un sidecar en cada workload de una plataforma con 3000 namespaces no puede enumerar las 3000 especificaciones de Deployment sobre las que va a actuar. Tiene que expresar un **delta**.

Kubernetes ofrece tres dialectos de delta, y Kyverno expone dos de ellos. Al que la mayoría de los equipos de plataforma recurre primero es al **Strategic Merge Patch (SMP)**, expuesto por Kyverno como `mutate.patchStrategicMerge`. SMP es declarativo, tolerante, y crea por vos los objetos padre que falten. Es el default correcto. También tiene cuatro modos de falla duros que aparecen en producción, normalmente en el peor momento:

1. **No puede borrar.** SMP compone; no resta. Eliminar un volumen `hostPath`, un campo de `securityContext` demasiado permisivo, un flag obsoleto `--insecure-skip-tls-verify` de `containers[].args`, o un finalizer viejo no es expresable como un merge. Las directivas SMP de Kubernetes (`$patch: delete`, `$patch: replace`) cubren el caso de objeto de forma acotada y son hostiles de leer; el caso de *elemento escalar de lista* (como `args`) no lo cubren en absoluto.

2. **No puede direccionar posiciones.** `spec.containers[].args` es una lista de strings planos sin merge key. Bajo SMP, cualquier patch sobre `args` reemplaza la lista entera. Si querés cambiar el elemento `2` y dejar el resto intacto, SMP no tiene vocabulario para "elemento 2".

3. **Se degrada silenciosamente en CRDs.** La semántica de SMP viene de tags de structs de Go (`patchStrategy:"merge" patchMergeKey:"name"`) compiladas dentro del API server para los tipos nativos. Un `cert-manager.io/v1 Certificate` o un `argoproj.io/v1alpha1 Application` no tienen esos metadatos, así que el manejo de listas cae de vuelta a *replace*. Una política que "agrega un DNS name" a un `Certificate` va a descartar en silencio, sobre un CRD, todos los DNS names que ya estaban ahí. Esta clase de bug no hace fallar la petición de admisión — produce un objeto válido con el contenido equivocado.

4. **No tiene orden ni condicionales a nivel de patch.** Los merges no están ordenados. "Poné esto solo si aquel otro campo vale X ahora mismo" tiene que subir a las preconditions, y "hacé A, después B, y abortá ambas si la precondición se rompe entremedio" directamente no es expresable.

**JSON Patch, RFC 6902**, es la salida de emergencia para los cuatro casos. Es una *lista ordenada de operaciones imperativas* sobre un objeto direccionado con **JSON Pointer, RFC 6901**. Puede eliminar. Puede direccionar `containers/0/args/2`. No sabe nada de tags de structs de Go, así que se comporta idénticamente sobre un `Pod` y sobre un `Certificate`. Y trae una operación `test` que vuelve al patch condicional y atómico — si el `test` falla, se descarta el patch entero.

El precio es la precisión. JSON Patch no crea padres faltantes, no tolera un path que no existe, y sus índices de array se te corren apenas eliminás un elemento. En Kyverno esto se expone como `mutate.patchesJson6902`.

La regla práctica de producción, y la que evalúa el examen:

> **Adiciones y valores por defecto a nivel de campo → `patchStrategicMerge`. Eliminaciones, ediciones posicionales, secuencias ordenadas/atómicas, y CRDs sin metadatos de patch → `patchesJson6902`.**

---

## 2. RFC 6901: el modelo de direccionamiento

Un JSON Pointer es un string de cero o más *reference tokens*, cada uno prefijado por `/`. El string vacío `""` direcciona el documento completo.

```
/spec/template/spec/containers/0/image
│    │        │    │          │ └── the "image" member of that object
│    │        │    │          └──── array index 0 (zero-based, decimal, no leading zeros)
│    │        │    └───────────────  the "containers" member
└────┴────────┴────────────────────  nested object members
```

### 2.1 Escapado — el bug más común de `patchesJson6902`

Como `/` es el separador y `~` inicia un escape, ambos deben codificarse dentro de un token:

| Carácter literal en la clave | Se codifica como | Orden de decodificación |
|---|---|---|
| `~` | `~0` | decodificar `~1` **primero**, después `~0` |
| `/` | `~1` | (el orden inverso corrompe `~01`) |

Las claves de annotations y labels de Kubernetes están namespaceadas con `/`, así que **casi todo patch de annotation necesita `~1`**:

| Clave que querés tocar | JSON Pointer que tenés que escribir |
|---|---|
| `nginx.ingress.kubernetes.io/proxy-body-size` | `/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size` |
| `app.kubernetes.io/name` (label) | `/metadata/labels/app.kubernetes.io~1name` |
| `kubectl.kubernetes.io/last-applied-configuration` | `/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration` |
| `checksum/config` | `/spec/template/metadata/annotations/checksum~1config` |
| `owner` (sin barra) | `/metadata/labels/owner` |

Escribir `/metadata/annotations/nginx.ingress.kubernetes.io/proxy-body-size` no falla con "te olvidaste de escapar". Se parsea como un **pointer de cinco tokens** — `annotations` → `nginx.ingress.kubernetes.io` → `proxy-body-size` — y falla con un error de *missing path* que apunta al lugar equivocado. Presupuestá una hora de tu vida para esto si no lo internalizás ahora.

### 2.2 El token `-`

Dentro de un array, el token `-` significa *la posición después del último elemento*. Es válido **solo como destino de `add`** (RFC 6902 §4.1); `remove`, `replace`, `copy` y `move` contra `-` son errores.

```yaml
- op: add
  path: "/spec/containers/-"     # append
  value: { name: sidecar, image: ... }
```

### 2.3 Límites de índice

| Pointer | Array de longitud 3 | Resultado |
|---|---|---|
| `/list/0` | válido | primer elemento |
| `/list/2` | válido | último elemento |
| `/list/3` | solo `add` | equivalente a append |
| `/list/3` | `remove`, `replace` | **error** — fuera de rango |
| `/list/-` | solo `add` | append |
| `/list/01` | cualquier op | **error** — los ceros a la izquierda son ilegales |

---

## 3. RFC 6902: semántica exacta de las operaciones

Toda operación es un objeto con un miembro `op`. `path` es un JSON Pointer. `value` lleva JSON arbitrario. `from` es un JSON Pointer para `move` y `copy`.

| `op` | Miembros requeridos | ¿El destino debe existir? | Semántica | ¿Idempotente? |
|---|---|---|---|---|
| `add` | `path`, `value` | el **padre** debe existir | Miembro de objeto: crea **o reemplaza**. Índice de array: **inserta**, corriendo los elementos posteriores hacia la derecha. `-`: append. | Miembro de objeto: sí. Array: **no** |
| `remove` | `path` | **sí** | Elimina el miembro / elimina el elemento y corre hacia la izquierda | **No** — la segunda ejecución da error |
| `replace` | `path`, `value` | **sí** | Equivalente a `remove` y después `add`; falla si está ausente | Sí |
| `move` | `from`, `path` | **ambos** | `remove` en `from`, `add` en `path`. `from` no puede ser prefijo propio de `path` | No |
| `copy` | `from`, `path` | `from` sí | `add` en `path` una copia del valor de `from` | Objeto: sí. Array: no |
| `test` | `path`, `value` | **sí** | Igualdad JSON profunda. **La falla aborta el patch entero.** | Sí (pura) |

### 3.1 Atomicidad

RFC 6902 §5: *"si un documento JSON Patch viola un requisito normativo, o si una operación no es exitosa, la evaluación del documento JSON Patch DEBERÍA terminar y la aplicación del documento de patch completo NO SERÁ considerada exitosa."*

Esta es la propiedad que hace útil a `test`. Un patch es una transacción: o aterrizan todas las operaciones o ninguna. No hay mutación parcial.

### 3.2 `add` no es "add"

La línea peor leída de todo el RFC. Sobre un **miembro de objeto**, `add` es un upsert — si el miembro existe, su valor se *sobrescribe*:

```jsonc
// document
{ "metadata": { "annotations": { "team": "payments", "cost-center": "4412" } } }

// patch
[ { "op": "add", "path": "/metadata/annotations", "value": { "team": "sre" } } ]

// result — cost-center is GONE
{ "metadata": { "annotations": { "team": "sre" } } }
```

Sobre un **índice de array**, `add` inserta, no sobrescribe:

```jsonc
// document
{ "args": ["--v=2", "--leader-elect"] }

// patch
[ { "op": "add", "path": "/args/0", "value": "--config=/etc/app.yaml" } ]

// result — nothing was replaced, everything shifted
{ "args": ["--config=/etc/app.yaml", "--v=2", "--leader-elect"] }
```

### 3.3 Reglas de igualdad profunda de `test`

`test` compara valores JSON estructuralmente, no textualmente:

| Comparación | Resultado |
|---|---|
| `3` vs `3.0` | iguales (mismo valor numérico) |
| `"3"` vs `3` | **no** iguales (difiere el tipo) |
| `{"a":1,"b":2}` vs `{"b":2,"a":1}` | iguales (los miembros de objeto no están ordenados) |
| `[1,2]` vs `[2,1]` | **no** iguales (los arrays están ordenados) |
| `null` vs miembro ausente | **no** iguales — un `test` sobre un path ausente es un *error*, no un false |

Esa última fila importa: `test` no puede expresar "este campo está ausente". Para chequeos de ausencia en Kyverno, usá una **precondition**, no una op `test` — ver §7.

---

## 4. Los tres dialectos de patch de Kubernetes, lado a lado

| | JSON Patch (RFC 6902) | JSON Merge Patch (RFC 7386) | Strategic Merge Patch |
|---|---|---|---|
| `kubectl patch --type=` | `json` | `merge` | `strategic` (default) |
| Content-Type | `application/json-patch+json` | `application/merge-patch+json` | `application/strategic-merge-patch+json` |
| Estándar | IETF RFC 6902 | IETF RFC 7386 | específico de Kubernetes |
| Forma | array ordenado de ops | un documento parcial | un documento parcial + directivas |
| Borrar un campo | `op: remove` | ponerlo en `null` | `$patch: delete` / valor `null` |
| Manejo de listas | índice posicional | **reemplaza la lista entera** | merge por `patchMergeKey` cuando el tipo declara una, si no reemplaza |
| Funciona en CRDs | **sí, idénticamente** | sí | **se degrada a la semántica de listas de merge-patch** |
| Crea padres faltantes | **no** | sí | sí |
| Condicional | op `test` | no | solo anchors de Kyverno |
| Ordenado | **sí** | n/a | n/a |
| Funciona en endpoints `list` (no-recurso) | sí | sí | no |
| Campo de Kyverno | `mutate.patchesJson6902` | — | `mutate.patchStrategicMerge` |

Una demostración concreta de la fila "Manejo de listas", contra `spec.template.spec.containers` (que *sí* declara `patchMergeKey: name`) versus una lista de CRD (que no):

```console
$ kubectl patch deployment web --type=strategic \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","image":"web:2.1"}]}}}}'
deployment.apps/web patched
# → only the "app" container changed; the "sidecar" container is untouched.

$ kubectl patch certificate api-tls --type=merge \
    -p '{"spec":{"dnsNames":["api.example.com"]}}'
certificate.cert-manager.io/api-tls patched

$ kubectl get certificate api-tls -o jsonpath='{.spec.dnsNames}'
["api.example.com"]
# → the four other SANs that were in the list are gone. No error was raised.
```

La forma RFC 6902 de la misma intención es segura porque es explícita respecto de la posición:

```console
$ kubectl patch certificate api-tls --type=json \
    -p '[{"op":"add","path":"/spec/dnsNames/-","value":"api.example.com"}]'
certificate.cert-manager.io/api-tls patched

$ kubectl get certificate api-tls -o jsonpath='{.spec.dnsNames}'
["api.internal","api-canary.example.com","api.example.com"]
```

### 4.1 Los dos dialectos de mutate de Kyverno, tabla de decisión

| Requisito | `patchStrategicMerge` | `patchesJson6902` | Recomendación |
|---|---|---|---|
| Agregar una annotation / label | ✅ crea `metadata.annotations` si falta | ⚠️ falla si el mapa está ausente | **SMP** |
| Fijar un default de `resources` de contenedor | ✅ mergea por `name` del contenedor | ⚠️ necesita el índice | **SMP** |
| Agregar un contenedor a `containers` | ✅ mergea por `name`, idempotente | ⚠️ `add /…/-` duplica al reinvocarse | **SMP** |
| Eliminar un elemento de `args` / `command` | ❌ no es expresable | ✅ `op: remove` | **JSON Patch** |
| Eliminar un volumen / toleration por predicado | ⚠️ gimnasia de anchors | ✅ | **JSON Patch** |
| Reordenar `initContainers` | ❌ | ✅ `op: move` | **JSON Patch** |
| Cambiar un elemento de una lista sin clave | ❌ reemplaza la lista | ✅ direccionado por índice | **JSON Patch** |
| Mutar el campo lista de un CRD | ❌ reemplaza la lista | ✅ | **JSON Patch** |
| Compare-and-swap (concurrencia optimista) | ❌ | ✅ `op: test` | **JSON Patch** |
| Dos cambios que deben aterrizar juntos o no aterrizar | ❌ | ✅ atomicidad | **JSON Patch** |
| Condicional sobre un *valor* en otra parte del objeto | ✅ anchor condicional `()` | ✅ preconditions | cualquiera |
| Agregar solo cuando está ausente | ✅ anchor `+()` | ⚠️ requiere precondition | **SMP** |
| Legibilidad / revisabilidad | ✅ alta | ❌ baja | **SMP** |
| Auto-gen para controladores de Pod | ✅ maduro | ⚠️ verificá los paths generados | **SMP** |

Los anchors de SMP de Kyverno, para que la comparación esté completa:

| Anchor | Nombre | Válido en |
|---|---|---|
| `()` | Condicional | validate, mutate |
| `^()` | Existencia (al menos un elemento del array) | validate |
| `=()` | Igualdad / la clave debe existir | validate |
| `X()` | Negación | validate |
| `+()` | **Agregar-si-no-está-presente** | mutate |
| `<()` | Global | validate |

---

## 5. `patchesJson6902` en Kyverno: sintaxis y mecánica

### 5.1 Es un *string*, no una lista

Este es el segundo error de autoría más común. En el esquema del CRD de Kyverno, `mutate.patchesJson6902` está tipado como `string`, y contiene un array YAML (o JSON). Tiene que ser un escalar de bloque YAML:

```yaml
mutate:
  patchesJson6902: |-        # ← block scalar. The content is a STRING.
    - op: add
      path: "/spec/containers/-"
      value:
        name: otel-agent
        image: otel/opentelemetry-collector-contrib:0.104.0
```

Escribirlo como una secuencia YAML nativa:

```yaml
mutate:
  patchesJson6902:           # ← WRONG: this is a list, not a string
    - op: add
      path: "/spec/containers/-"
```

es rechazado por el API server en el momento de admisión de la política:

```console
$ kubectl apply -f inject-sidecar.yaml
The ClusterPolicy "inject-otel-agent" is invalid: spec.rules[0].mutate.patchesJson6902:
Invalid value: "array": spec.rules[0].mutate.patchesJson6902 in body must be of type string: "array"
```

### 5.2 El documento sobre el que se aplica el JSON Patch

Kyverno aplica el patch sobre el **objeto admitido completo**, no sobre un fragmento. Los paths son, por lo tanto, absolutos desde la raíz del objeto:

- Match sobre `Pod` → `/spec/containers/0/image`
- Match sobre `Deployment` → `/spec/template/spec/containers/0/image`
- Match sobre `CronJob` → `/spec/jobTemplate/spec/template/spec/containers/0/image`

Para las reglas `mutate` (admisión), el documento es `request.object` después de que cualquier regla anterior de la misma política ya lo mutó — las reglas dentro de una política se aplican **en orden de declaración**, y cada una ve la salida de la anterior.

### 5.3 Variables

Kyverno sustituye las expresiones JMESPath `{{ … }}` tanto en `path` como en `value` **antes** de que el patch se parsee como JSON. Dos consecuencias:

- Una variable que se expande a un array u objeto JSON se inserta como JSON estructurado cuando es el valor *entero* (sin comillas alrededor). Si la entrecomillás, obtenés un string.
- Una variable que no resuelve deja el documento de patch sintácticamente roto, lo que aparece como un error de parseo de JSON en lugar de un error de "variable no encontrada", salvo que la regla esté escrita con `failurePolicy`/preconditions para saltarse limpiamente.

```yaml
patchesJson6902: |-
  - op: replace
    path: "/spec/volumes"
    value: {{ request.object.spec.volumes[?!contains(keys(@), 'hostPath')] }}   # structured
  - op: add
    path: "/metadata/annotations/platform.example.com~1mutated-by"
    value: "{{ request.uid }}"                                                   # string
```

### 5.4 Anatomía completa de una regla

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: example
spec:
  rules:
    - name: example-rule
      match: { … }              # selection            (5.2)
      exclude: { … }            # de-selection         (5.2)
      preconditions: { … }      # cheap, clean SKIP    (5.3)
      context: [ … ]            # external data        (5.9)
      mutate:
        patchesJson6902: |-     # ordered, atomic ops  (this topic)
          - op: …
```

Las preconditions habilitan la regla; el patch se ejecuta solo si pasan. **Una precondition falsa produce `skip`; una op `test` fallida produce `error`.** Usá la primera para control de flujo y la segunda solo para invariantes genuinas de compare-and-swap.

---

## 6. Receta de producción A — eliminar un flag prohibido de un contenedor

**Problema.** Una auditoría a nivel de plataforma encontró workloads corriendo `kube-rbac-proxy` y varios operators con `--insecure-skip-tls-verify` o `--tls-min-version=VersionTLS10` en `args`. `args` es `[]string` sin merge key: SMP no puede tocar un elemento individual. Necesitás una eliminación quirúrgica que deje intacto todo el resto de los flags.

El enfoque basado en índices es una trampa — eliminar el elemento 1 renumera todo lo que viene después, así que un patch que elimina los índices `[1, 3]` en orden ascendente en realidad elimina los elementos originales 1 y 4. La técnica robusta es **reconstruir la lista con un filtro JMESPath y hacerle `replace` atómicamente**. Una sola operación, a salvo de índices, idempotente, y hace lo correcto cuando coinciden cero o muchos elementos.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: strip-insecure-tls-flags
  annotations:
    policies.kyverno.io/title: Strip Insecure TLS Flags
    policies.kyverno.io/category: Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Removes arguments that disable or downgrade TLS verification from every
      container and initContainer. Uses RFC 6902 because args is a keyless
      list of strings and Strategic Merge Patch can only replace it wholesale.
spec:
  background: false
  rules:
    - name: strip-args-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          # Only act when at least one container actually carries a banned flag.
          # Without this the rule would rewrite /spec/containers on every Pod
          # in the cluster, churning the object for no reason.
          - key: |-
              {{ request.object.spec.containers[?args] 
                 | length(@[?length(args[?starts_with(@, '--insecure-skip-tls-verify')
                                       || starts_with(@, '--tls-min-version=VersionTLS10')
                                       || starts_with(@, '--tls-min-version=VersionTLS11')]) > `0`]) }}
            operator: GreaterThan
            value: 0
      mutate:
        foreach:
          - list: "request.object.spec.containers"
            # Skip containers that have nothing to strip: a no-op replace would
            # still count as a mutation and would still churn the object.
            preconditions:
              all:
                - key: |-
                    {{ length(element.args[?starts_with(@, '--insecure-skip-tls-verify')
                                          || starts_with(@, '--tls-min-version=VersionTLS10')
                                          || starts_with(@, '--tls-min-version=VersionTLS11')]) }}
                  operator: GreaterThan
                  value: 0
            patchesJson6902: |-
              - op: replace
                path: "/spec/containers/{{ elementIndex }}/args"
                value: {{ element.args[?!(starts_with(@, '--insecure-skip-tls-verify')
                                       || starts_with(@, '--tls-min-version=VersionTLS10')
                                       || starts_with(@, '--tls-min-version=VersionTLS11'))] }}
```

`foreach` liga dos variables por iteración: `{{ element }}` (el ítem de la lista) y `{{ elementIndex }}` (su posición de base cero en la lista **original**). Como cada iteración emite un `replace` en un índice fijo — nunca un `remove` — los índices se mantienen estables durante todo el bucle. Este es el patrón al que hay que recurrir cada vez que te tiente eliminar elementos de lista por índice.

**Verificación con la CLI, antes de que la política llegue a un clúster:**

`resource.yaml`
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: metrics-proxy
  namespace: observability
spec:
  containers:
    - name: kube-rbac-proxy
      image: quay.io/brancz/kube-rbac-proxy:v0.18.0
      args:
        - "--secure-listen-address=0.0.0.0:8443"
        - "--insecure-skip-tls-verify=true"
        - "--upstream=http://127.0.0.1:8080/"
        - "--tls-min-version=VersionTLS10"
        - "--logtostderr=true"
    - name: exporter
      image: prom/node-exporter:v1.8.2
      args:
        - "--path.rootfs=/host"
```

```console
$ kyverno apply strip-insecure-tls-flags.yaml --resource resource.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy strip-insecure-tls-flags applied to observability/Pod/metrics-proxy:
apiVersion: v1
kind: Pod
metadata:
  annotations:
    policies.kyverno.io/last-applied-patches: |
      strip-args-containers.strip-insecure-tls-flags.kyverno.io: replaced /spec/containers/0/args
  name: metrics-proxy
  namespace: observability
spec:
  containers:
  - args:
    - --secure-listen-address=0.0.0.0:8443
    - --upstream=http://127.0.0.1:8080/
    - --logtostderr=true
    image: quay.io/brancz/kube-rbac-proxy:v0.18.0
    name: kube-rbac-proxy
  - args:
    - --path.rootfs=/host
    image: prom/node-exporter:v1.8.2
    name: exporter
---

pass: 1, fail: 0, warn: 0, error: 0, skip: 0
```

Dos cosas para leer en esa salida. El contenedor `exporter` **no** fue reescrito — su precondition interna era falsa, así que `foreach` salteó esa iteración. Y Kyverno estampó `policies.kyverno.io/last-applied-patches`, que es tu señal forense principal dentro del clúster (§11).

---

## 7. Receta de producción B — inyección idempotente de sidecar

**Problema.** Inyectar un agente de OpenTelemetry en workloads que se suscribieron. El patch obvio es `add /spec/containers/-`. También es el apagón clásico:

> Los mutating webhooks de Kubernetes pueden ser **reinvocados**. Cuando el API server tiene más de un mutating webhook y uno de ellos modifica el objeto, los webhooks cuya configuración declara `reinvocationPolicy: IfNeeded` son llamados de nuevo en una segunda pasada. El webhook mutante de recursos de Kyverno usa `IfNeeded`, así que **una regla `patchesJson6902` puede ejecutarse más de una vez sobre la misma petición de admisión**, y `add /list/-` no es idempotente. El resultado son dos sidecars idénticos, una colisión de puertos, y un CrashLoopBackOff que solo se reproduce en clústeres que casualmente tienen instalado un segundo mutating webhook.

Confirmá la configuración de reinvocación en tu clúster:

```console
$ kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.reinvocationPolicy}{"\n"}{end}'
mutate.kyverno.svc-fail	IfNeeded
mutate.kyverno.svc-ignore	IfNeeded
```

La solución es una **precondition de ausencia**. Una op `test` no puede expresar esto — un `test` sobre un path que no existe es un error, y no hay ningún pointer que signifique "ningún elemento cuyo `name` sea `otel-agent`".

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-otel-agent
  annotations:
    policies.kyverno.io/title: Inject OpenTelemetry Agent
    policies.kyverno.io/category: Observability
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
spec:
  background: false
  rules:
    - name: inject-agent-container
      match:
        any:
          - resources:
              kinds:
                - Pod
              selector:
                matchLabels:
                  observability.example.com/otel: "enabled"
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      preconditions:
        all:
          # Idempotency guard. Survives webhook reinvocation and re-admission
          # of an already-mutated Pod template.
          - key: "{{ request.object.spec.containers[?name=='otel-agent'] | length(@) }}"
            operator: Equals
            value: 0
          # A JSON Patch cannot create a missing parent. /spec/containers is
          # required by the Pod schema, so it is always present — but assert it
          # rather than assume it, because this same rule shape gets copied
          # onto CRDs where the parent really can be absent.
          - key: "{{ request.object.spec.containers | length(@) }}"
            operator: GreaterThan
            value: 0
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/containers/-"
            value:
              name: otel-agent
              image: otel/opentelemetry-collector-contrib:0.104.0
              imagePullPolicy: IfNotPresent
              args:
                - "--config=/conf/otel-agent-config.yaml"
              env:
                - name: OTEL_RESOURCE_ATTRIBUTES
                  value: "k8s.namespace.name={{ request.namespace }},k8s.pod.name={{ request.object.metadata.name || 'generated' }}"
                - name: GOMEMLIMIT
                  value: "160MiB"
              ports:
                - name: otlp-grpc
                  containerPort: 4317
                  protocol: TCP
                - name: otlp-http
                  containerPort: 4318
                  protocol: TCP
              resources:
                requests:
                  cpu: 50m
                  memory: 96Mi
                limits:
                  memory: 200Mi
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                runAsNonRoot: true
                runAsUser: 65534
                capabilities:
                  drop: ["ALL"]
                seccompProfile:
                  type: RuntimeDefault
              volumeMounts:
                - name: otel-agent-config
                  mountPath: /conf
                  readOnly: true
              livenessProbe:
                httpGet:
                  path: /
                  port: 13133
                initialDelaySeconds: 5
              readinessProbe:
                httpGet:
                  path: /
                  port: 13133
                initialDelaySeconds: 5
          - op: add
            path: "/spec/volumes/-"
            value:
              name: otel-agent-config
              configMap:
                name: otel-agent-config
                defaultMode: 420
```

⚠️ **La segunda operación es una falla latente.** `/spec/volumes` es opcional en un Pod. Si el Pod no tiene volúmenes en absoluto, el miembro está ausente y `add /spec/volumes/-` falla con *doc is missing path* — y como RFC 6902 es atómico, **la inyección del sidecar también se revierte**. Dos arreglos correctos:

**Arreglo 1 — hacer que el padre sea incondicional con una regla `patchStrategicMerge` previa** (SMP crea los padres faltantes; JSON Patch no):

```yaml
    - name: ensure-volumes-exists
      match:
        any:
          - resources:
              kinds: [Pod]
              selector:
                matchLabels:
                  observability.example.com/otel: "enabled"
      mutate:
        patchStrategicMerge:
          spec:
            +(volumes): []          # add-if-not-present anchor
```

Declará esta regla **antes** de `inject-agent-container`; las reglas corren de arriba hacia abajo y la segunda ve la salida de la primera.

**Arreglo 2 — bifurcar el patch con una precondition**, manteniendo todo en un par de reglas:

```yaml
      preconditions:
        all:
          - key: "{{ request.object.spec.volumes || `[]` | length(@) }}"
            operator: Equals
            value: 0
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/volumes"
            value:
              - name: otel-agent-config
                configMap: { name: otel-agent-config, defaultMode: 420 }
```

El arreglo 1 es preferible: menos reglas que mantener sincronizadas, y la intención es legible en la revisión.

---

## 8. Receta de producción C — annotations, y la trampa de `add` que borra el mapa

Como `add` sobre un miembro de objeto lo *reemplaza* (§3.2), la forma "obvia" de volver seguro un patch de annotation es catastrófica:

```yaml
# NEVER DO THIS
patchesJson6902: |-
  - op: add
    path: "/metadata/annotations"      # ← destroys every existing annotation
    value: {}
  - op: add
    path: "/metadata/annotations/example.com~1owner"
    value: "platform-team"
```

En un Pod creado por un Deployment esto borra `kubectl.kubernetes.io/restartedAt`, las annotations de checksum que disparan los rollouts, el estado de `cni.projectcalico.org/*`, y cualquier cosa que haya escrito un webhook anterior. Es un patch con pérdida de datos y código de salida limpio.

| Enfoque | ¿Seguro cuando faltan las annotations? | ¿Preserva las existentes? | Veredicto |
|---|---|---|---|
| `patchStrategicMerge` sobre `metadata.annotations` | ✅ crea el mapa | ✅ | **Usá esto** |
| JSON Patch `add /metadata/annotations` y después la clave | ✅ | ❌ **borra todo** | Nunca |
| JSON Patch con un solo `add /metadata/annotations/key~1x` | ❌ da error si el mapa está ausente | ✅ | Solo detrás de una precondition |
| Dos reglas: SMP `+(annotations): {}` y después JSON Patch | ✅ | ✅ | Aceptable, verboso |

El caso legítimo de JSON Patch sobre annotations es la **eliminación**, que SMP no puede hacer:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sanitize-ingress-annotations
  annotations:
    policies.kyverno.io/title: Remove Snippet Annotations from Ingress
    policies.kyverno.io/category: Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/description: >-
      ingress-nginx configuration-snippet and server-snippet annotations allow
      arbitrary nginx configuration and have been the vector for several
      published CVEs. Strip them at admission rather than rejecting the Ingress,
      so that GitOps reconciliation does not loop on a permanently failing sync.
spec:
  background: false
  rules:
    - name: strip-configuration-snippet
      match:
        any:
          - resources:
              kinds:
                - networking.k8s.io/v1/Ingress
      preconditions:
        any:
          - key: "nginx.ingress.kubernetes.io/configuration-snippet"
            operator: AnyIn
            value: "{{ request.object.metadata.annotations || `{}` | keys(@) }}"
      mutate:
        patchesJson6902: |-
          - op: remove
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1configuration-snippet"

    - name: strip-server-snippet
      match:
        any:
          - resources:
              kinds:
                - networking.k8s.io/v1/Ingress
      preconditions:
        any:
          - key: "nginx.ingress.kubernetes.io/server-snippet"
            operator: AnyIn
            value: "{{ request.object.metadata.annotations || `{}` | keys(@) }}"
      mutate:
        patchesJson6902: |-
          - op: remove
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1server-snippet"
```

Dos reglas separadas, no un patch con dos ops `remove` — porque acá la atomicidad juega en contra. Un único patch que elimine ambas fallaría por completo en un Ingress que solo lleva una de las dos, y RFC 6902 revertiría la eliminación que *sí* se aplicó.

```console
$ kubectl apply -f evil-ingress.yaml
ingress.networking.k8s.io/shop created

$ kubectl get ingress shop -o jsonpath='{.metadata.annotations}' | jq
{
  "nginx.ingress.kubernetes.io/rewrite-target": "/",
  "policies.kyverno.io/last-applied-patches": "strip-configuration-snippet.sanitize-ingress-annotations.kyverno.io: removed /metadata/annotations/nginx.ingress.kubernetes.io~1configuration-snippet\n"
}
```

---

## 9. Receta de producción D — `mutate` sobre recursos existentes

`patchesJson6902` no se limita a la admisión. Con `mutate.targets`, el **background controller** de Kyverno parchea recursos que ya existen, disparado por un cambio en algún otro objeto. Acá es donde JSON Patch se gana el sueldo: la mutación en background corre repetidamente, así que la idempotencia y el compare-and-swap protegido con `test` pasan a ser estructurales.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-ingress-body-size
  annotations:
    policies.kyverno.io/title: Propagate proxy-body-size to Existing Ingresses
    policies.kyverno.io/category: Platform
    policies.kyverno.io/subject: Ingress, ConfigMap
spec:
  mutateExistingOnPolicyUpdate: true
  rules:
    - name: patch-existing-ingresses
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
              names:
                - ingress-tuning
              namespaces:
                - platform
      mutate:
        targets:
          - apiVersion: networking.k8s.io/v1
            kind: Ingress
            namespace: "*"
            selector:
              matchLabels:
                platform.example.com/managed: "true"
        patchesJson6902: |-
          - op: add
            path: "/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size"
            value: "{{ request.object.data.bodySize }}"
```

La mutación en background corre bajo la service account del **background controller**, que por defecto no puede tocar Ingresses. Otorgale el permiso con un ClusterRole agregable — los roles de Kyverno agregan por una label, así que nunca editás el RBAC propio de Kyverno:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:mutate-ingresses
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch
      - update
      - patch
```

Diagnosticando el caso de RBAC faltante, que es la falla más común de `mutateExisting`:

```console
$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=40 | grep -i forbidden
E0814 09:21:04.118  mutate  failed to update target resource
  {"policy":"propagate-ingress-body-size","rule":"patch-existing-ingresses",
   "target":"networking.k8s.io/v1/Ingress/shop/shop",
   "error":"ingresses.networking.k8s.io \"shop\" is forbidden: User
   \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot patch
   resource \"ingresses\" in API group \"networking.k8s.io\" in the namespace \"shop\""}

$ kubectl auth can-i patch ingresses.networking.k8s.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n shop
no

# after applying the aggregating ClusterRole (aggregation is not instantaneous —
# the controller-manager recomputes the aggregate role within a few seconds)
$ kubectl auth can-i patch ingresses.networking.k8s.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n shop
yes
```

---

## 10. Auto-gen y controladores de Pod

La funcionalidad de **auto-gen** de Kyverno clona una regla de `Pod` en reglas equivalentes para Deployment, StatefulSet, DaemonSet, Job, CronJob y ReplicaSet, de modo que una violación se detecte en el controlador y no solo en el Pod que el controlador crea. Para `patchStrategicMerge` esto es un re-anidado mecánico del patch bajo `spec.template`. Para `patchesJson6902` significa **reescribir prefijos de JSON Pointer**, y ahí conviene verificar en lugar de suponer.

Controlalo explícitamente:

```yaml
metadata:
  annotations:
    pod-policies.kyverno.io/autogen-controllers: "Deployment,StatefulSet,DaemonSet"
    # or, to opt out entirely:
    # pod-policies.kyverno.io/autogen-controllers: "none"
```

Inspeccioná lo que Kyverno generó realmente — las reglas generadas se escriben de vuelta en el `status`/`spec` de la política y son visibles en el objeto vivo:

```console
$ kubectl get clusterpolicy inject-otel-agent -o yaml | grep -A4 'name: autogen'
      name: autogen-inject-agent-container
      match:
        any:
        - resources:
            kinds:
            - Deployment
--
      name: autogen-cronjob-inject-agent-container
      match:
        any:
        - resources:
            kinds:
            - CronJob

$ kubectl get clusterpolicy inject-otel-agent -o jsonpath='{.spec.rules[?(@.name=="autogen-inject-agent-container")].mutate.patchesJson6902}'
- op: add
  path: "/spec/template/spec/containers/-"
  value:
    name: otel-agent
    ...
```

| Síntoma | Causa | Arreglo |
|---|---|---|
| La regla de autogen falla con *missing path* en Deployments | El prefijo del path no se reescribió como esperabas para tu versión de Kyverno | Escribí las reglas de los controladores explícitamente, poné `autogen-controllers: "none"` |
| La precondition de autogen sigue leyendo `request.object.spec.containers` | Las preconditions también se reescriben — verificá el JMESPath generado | Inspeccioná la regla generada; escribí reglas explícitas si no coincide |
| El sidecar aparece dos veces en los Pods de un Deployment | Dispararon tanto la regla de autogen para Deployment como la regla de Pod | La precondition de idempotencia (§7) vuelve no-op a la regla de nivel Pod |

**Regla práctica:** si una regla `patchesJson6902` es importante para la corrección, desactivá autogen y escribí cada tipo de controlador explícitamente. Las 30 líneas extra te compran una política cuyo comportamiento podés leer directamente en vez de inferirlo.

---

## 11. Verificación

### 11.1 Escalera de confianza

| Pregunta | Herramienta | ¿Requiere clúster? |
|---|---|---|
| ¿El documento de patch es JSON/YAML sintácticamente válido? | `kubectl apply` de la política (validación del esquema del CRD) | solo la política |
| ¿El patch se aplica a *este* recurso? | `kyverno apply -p policy.yaml --resource r.yaml` | no |
| ¿La salida mutada es exactamente la que espero, byte a byte? | `kyverno test` con `patchedResources` | no |
| ¿Se aplica en la cadena de admisión real, con otros webhooks? | `kubectl apply --dry-run=server -o yaml` | sí |
| ¿Se aplicó en producción? | annotation `policies.kyverno.io/last-applied-patches` | sí |
| ¿*Falló* en producción? | logs del admission controller, Events, PolicyReports | sí |

### 11.2 `kyverno test` — el arnés de regresión

Fijá la salida esperada exacta para que una edición de la política no pueda cambiar la mutación en silencio. Estructura de directorios:

```
policies/inject-otel-agent/
├── policy.yaml
├── resource.yaml
├── patched.yaml
└── kyverno-test.yaml
```

`kyverno-test.yaml`
```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: inject-otel-agent
policies:
  - policy.yaml
resources:
  - resource.yaml
results:
  - policy: inject-otel-agent
    rule: inject-agent-container
    kind: Pod
    resources:
      - api-server
    patchedResources: patched.yaml
    result: pass
  - policy: inject-otel-agent
    rule: inject-agent-container
    kind: Pod
    resources:
      - already-injected
    result: skip
```

```console
$ kyverno test policies/inject-otel-agent/

Loading test  ( policies/inject-otel-agent/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│───│─────────────────────│──────────────────────────│───────────────────────│────────│
│ # │ POLICY              │ RULE                     │ RESOURCE              │ RESULT │
│───│─────────────────────│──────────────────────────│───────────────────────│────────│
│ 1 │ inject-otel-agent   │ inject-agent-container   │ Pod/api-server        │ Pass   │
│ 2 │ inject-otel-agent   │ inject-agent-container   │ Pod/already-injected  │ Pass   │
│───│─────────────────────│──────────────────────────│───────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

Cuando el objeto producido se desvía de `patched.yaml`, la CLI imprime el diff y sale con código distinto de cero — que es exactamente lo que querés cableado en CI:

```console
$ kyverno test policies/inject-otel-agent/
...
│ 1 │ inject-otel-agent │ inject-agent-container │ Pod/api-server │ Fail │
...
Test Summary: 1 tests passed and 1 tests failed

Aggregated Failed Test Cases : 
│ 1 │ inject-otel-agent │ inject-agent-container │ Pod/api-server │ Fail │
patched resource diff:
   spec.containers[1].resources.limits.memory:
-    200Mi
+    256Mi

$ echo $?
1
```

### 11.3 Dry run del lado del servidor — la cadena de admisión completa

`kyverno apply` evalúa una política de forma aislada. El comportamiento en producción es la *composición* de todos los mutating webhooks, en el orden del API server, con reinvocación. Solo el API server puede mostrarte eso:

```console
$ kubectl apply -f pod.yaml --dry-run=server -o yaml \
  | yq '.spec.containers[].name'
api
otel-agent
istio-proxy

$ diff <(yq -P 'sort_keys(..)' pod.yaml) \
       <(kubectl apply -f pod.yaml --dry-run=server -o yaml | yq -P 'sort_keys(..)') \
  | head -30
```

El dry run del lado del servidor ejecuta los plugins de admisión y los webhooks y descarta el objeto; Kyverno respeta `dryRun` y no crea policy reports para él.

### 11.4 Evidencia dentro del clúster

```console
$ kubectl get pod api-server-7d9f5c8b4-x2klm \
    -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'
inject-agent-container.inject-otel-agent.kyverno.io: added /spec/containers/1
strip-args-containers.strip-insecure-tls-flags.kyverno.io: replaced /spec/containers/0/args

$ kubectl get events -n observability --field-selector reason=PolicyApplied \
    --sort-by=.lastTimestamp -o wide | tail -3
LAST SEEN   TYPE     REASON          OBJECT                  MESSAGE
12s         Normal   PolicyApplied   pod/api-server-x2klm    ClusterPolicy inject-otel-agent: rule inject-agent-container applied

$ kubectl get events -A --field-selector reason=PolicyError --sort-by=.lastTimestamp | tail -5
```

---

## 12. Diagnóstico de fallas

### 12.1 Decodificador de mensajes de error

El motor de patch que hay debajo de Kyverno y del API server es una implementación directa de RFC 6902, así que ambos exponen casi los mismos strings. Mensajes representativos y su causa real:

| Mensaje | Causa raíz | Arreglo |
|---|---|---|
| `add operation does not apply: doc is missing path: "/spec/volumes"` | Objeto/array padre ausente. JSON Patch nunca crea padres. | Precedelo con una regla SMP `+(volumes): []`, o bifurcá con una precondition |
| `remove operation does not apply: doc is missing key: hostNetwork` | Eliminar un campo opcional que este objeto no tiene | Protegé la regla con una precondition sobre la presencia de la clave; **no** uses `test` |
| `replace operation does not apply: doc is missing key: /spec/replicas` | `replace` requiere que el destino exista | Usá `add` (upsert en miembros de objeto) o condicioná con una precondition |
| `jsonpatch test operation does not apply` / `testing value /spec/replicas failed` | El `test` comparó desigual, o el path estaba ausente | CAS intencional → reintentar. No intencional → lo que querías era una precondition |
| `add operation does not apply: doc is missing path: "/metadata/annotations/foo.io/bar"` | `/` sin escapar en una clave de annotation | `~1` (§2.1) |
| `error in JSON patch: invalid character '{' looking for beginning of object key string` | Una variable `{{ }}` no resolvió y quedó en el documento | Corregí el JMESPath; agregá una precondition para que la regla se saltee cuando la fuente esté ausente |
| `spec.rules[0].mutate.patchesJson6902 in body must be of type string: "array"` | Escribiste una lista YAML en lugar de un escalar de bloque | `patchesJson6902: \|-` (§5.1) |
| `Index out of bounds` / `Unable to access invalid index: 3` | Operación basada en índice después de que un `remove` anterior corrió el array | Reconstruí la lista con un `replace` filtrado (§6) |
| `admission webhook "mutate.kyverno.svc-fail" denied the request` | La regla dio error y la `failurePolicy` del webhook es `Fail` | Leé el log del controlador para el error RFC 6902 envuelto |
| Objeto admitido **sin mutar**, sin error en ningún lado | La regla dio error y `failurePolicy: Ignore` | El caso peligroso — ver §12.3 |

### 12.2 Reproducir localmente una falla de producción

```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=200 \
    | grep -iE 'json.?patch|6902|mutate.*error'
E0814 09:44:19.882  mutate  failed to apply JSON Patch
  {"policy":"inject-otel-agent","rule":"inject-agent-container",
   "resource":"payments/Pod/checkout-6b7f9d",
   "error":"add operation does not apply: doc is missing path: \"/spec/volumes\""}

# Capture the offending object and replay it offline
$ kubectl get pod -n payments checkout-6b7f9d -o yaml \
    | yq 'del(.status, .metadata.uid, .metadata.resourceVersion,
              .metadata.creationTimestamp, .metadata.managedFields)' > repro.yaml

$ kyverno apply inject-otel-agent.yaml --resource repro.yaml -v 4
...
Applying 1 policy rule(s) to 1 resource(s)...

Error: failed to apply policy inject-otel-agent rule inject-agent-container on
resource payments/Pod/checkout-6b7f9d: add operation does not apply:
doc is missing path: "/spec/volumes"

pass: 0, fail: 0, warn: 0, error: 1, skip: 0
$ echo $?
1
```

### 12.3 `failurePolicy` y la clase de bug de deriva silenciosa

Esta es la propiedad operativa de mayor severidad de `patchesJson6902` y vale la pena enunciarla por separado:

| `spec.failurePolicy` | La operación de patch da error | ¿Visible para el usuario? | Consecuencia |
|---|---|---|---|
| `Fail` (default) | La petición de admisión es **rechazada** | ✅ ruidosamente — `kubectl` imprime el error del webhook | Los deploys se rompen. Ruidoso, corregible. |
| `Ignore` | El objeto se admite **sin la mutación** | ❌ nada en la salida del apply | Una política de "hardening" deja de endurecer en silencio. Los sidecars desaparecen. Nadie se entera hasta que hay un incidente. |

Si corrés con `failurePolicy: Ignore` — cosa que muchos equipos hacen, para que una caída de Kyverno no se convierta en una caída del clúster — **tenés que** compensar con detección:

1. Una política `validate` emparejada en modo `Audit` que afirme la poscondición (el sidecar existe, el flag está ausente). Las fallas de mutación aparecen entonces como fallas de PolicyReport.
2. Una alerta sobre la métrica `kyverno_policy_results_total{rule_result="error"}`.

```console
$ kubectl get polr -A -o json \
  | jq -r '.items[].results[] | select(.result=="fail" or .result=="error")
           | "\(.policy)/\(.rule)\t\(.result)\t\(.message)"' | sort | uniq -c | sort -rn | head
     31 require-otel-agent/agent-present	fail	validation error: workloads labeled otel=enabled must carry the otel-agent container

$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
$ curl -s localhost:8000/metrics | grep 'kyverno_policy_results_total.*error'
kyverno_policy_results_total{policy_name="inject-otel-agent",rule_name="inject-agent-container",rule_result="error",rule_type="mutation",...} 31
```

31 mutaciones fallidas, cero errores en cualquier `kubectl apply`. Esa brecha es exactamente lo que te compra `failurePolicy: Ignore`, y el emparejamiento con un validate en audit es cómo la cerrás.

---

## 13. `kubectl patch` — el mismo dialecto al alcance del operador

Todo lo anterior aplica textualmente a `kubectl patch --type=json`; es la forma más rápida de construir intuición sobre RFC 6902 antes de comprometerlo en una política.

```console
# remove a probe that is flapping during an incident
$ kubectl patch deployment web --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/containers/0/livenessProbe"}]'
deployment.apps/web patched

# compare-and-swap: only scale if we are still at 3 replicas
$ kubectl patch deployment web --type=json -p '[
    {"op":"test","path":"/spec/replicas","value":3},
    {"op":"replace","path":"/spec/replicas","value":8}
  ]'
deployment.apps/web patched

# the same command once someone else has already scaled it
$ kubectl patch deployment web --type=json -p '[
    {"op":"test","path":"/spec/replicas","value":3},
    {"op":"replace","path":"/spec/replicas","value":8}
  ]'
Error from server: jsonpatch test operation does not apply
# → the replace did NOT happen. Atomicity did its job.

# escaping, on the command line
$ kubectl patch ingress shop --type=json \
    -p '[{"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size","value":"50m"}]'
ingress.networking.k8s.io/shop patched

# reorder initContainers
$ kubectl patch deployment web --type=json \
    -p '[{"op":"move","from":"/spec/template/spec/initContainers/2","path":"/spec/template/spec/initContainers/0"}]'
deployment.apps/web patched

# subresources take patches too
$ kubectl patch pod api --subresource=status --type=json \
    -p '[{"op":"replace","path":"/status/conditions/0/status","value":"False"}]'

# always rehearse against the server first
$ kubectl patch deployment web --type=json --dry-run=server -o yaml \
    -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]' \
  | yq '.spec.template.spec.containers[0].resources'
requests:
  cpu: 100m
  memory: 128Mi
limits:
  memory: 512Mi
```

**Interacción con server-side apply.** Un JSON Patch es una escritura de tipo client-side apply; toma la propiedad de los campos bajo el field manager `kubectl-patch`. Si el objeto además es reconciliado por Argo CD o Flux con `--server-side`, tu patch crea un propietario en conflicto y la siguiente sincronización o lo revierte o falla con un conflicto. Parcheá imperativamente durante los incidentes; codificá la intención duradera como una política de Kyverno o en Git.

---

## 14. Orden, rendimiento y costo

| Aspecto | Comportamiento | Guía práctica |
|---|---|---|
| Orden de las reglas dentro de una política | Secuencial; la regla *n* ve la salida de la regla *n−1* | Poné las reglas SMP que crean padres antes de las reglas JSON Patch |
| Orden de las políticas entre sí | No garantizado | Nunca hagas que una política dependa de la mutación de otra |
| Reinvocación de webhooks | `IfNeeded` → las reglas pueden correr dos veces por petición | Todo `add /list/-` necesita una precondition de ausencia |
| Sustitución de variables | Corre antes del parseo de JSON, por petición | Mantené el JMESPath superficial; un `foreach` sobre 30 contenedores son 30 sustituciones |
| Presupuesto de latencia | Los mutating webhooks están en el camino crítico de toda escritura | Un `match` acotado (kinds, namespaces, label selectors) es la palanca más grande, no la complejidad del patch |
| `background: true` | Habilita la reevaluación periódica | Poné `background: false` en las reglas que referencian `request.userInfo`, `request.uid` o `request.operation` — no están disponibles fuera de la admisión |
| Skip vs error | Precondition falsa → `skip`; op fallida → `error` | Usá preconditions para control de flujo, `test` solo para CAS genuino |

---

## 15. Checklist de examen

- `patchesJson6902` es un **string** (escalar de bloque `|-`), no una lista YAML.
- Escapado de JSON Pointer: `~` → `~0`, `/` → `~1`. Las annotations y labels casi siempre necesitan `~1`.
- `-` significa append y es legal **solo** para `add`.
- `add` sobre un miembro de objeto **reemplaza**; sobre un índice de array **inserta** y corre los elementos.
- `remove` y `replace` **requieren** que el destino exista; `add` requiere que exista el **padre**.
- JSON Patch **nunca crea padres faltantes** — ese es el trabajo del Strategic Merge Patch.
- Un patch es **atómico**: una sola op fallida descarta el patch entero.
- La falla de `test` es un **error**, no un skip; los chequeos de ausencia van en las **preconditions**.
- Eliminar varios elementos de un array por índice es un bug — reconstruí la lista con un `replace` filtrado con JMESPath.
- `add /spec/containers/-` **no es idempotente**; la reinvocación del webhook lo duplica.
- Los paths son absolutos desde la raíz del objeto: `/spec/...` para Pod, `/spec/template/spec/...` para Deployment, `/spec/jobTemplate/spec/template/spec/...` para CronJob.
- `foreach` te da `{{ element }}` y `{{ elementIndex }}`.
- Anchors de SMP: `()` condicional, `+()` agregar-si-no-está-presente (mutate), `=()` igualdad, `^()` existencia, `X()` negación, `<()` global.
- `failurePolicy: Ignore` convierte un patch roto en deriva silenciosa — emparejalo con una política validate en `Audit`.
- `mutate.targets` + `mutateExistingOnPolicyUpdate` necesitan RBAC extra agregado con `rbac.kyverno.io/aggregate-to-background-controller: "true"`.
- Verificá con `kyverno apply` (rápido), `kyverno test` + `patchedResources` (regresión), `kubectl apply --dry-run=server` (cadena completa).

---

## Referencias

**Estándares**
- RFC 6902 — JavaScript Object Notation (JSON) Patch: https://datatracker.ietf.org/doc/html/rfc6902
- RFC 6901 — JavaScript Object Notation (JSON) Pointer: https://datatracker.ietf.org/doc/html/rfc6901
- RFC 7386 — JSON Merge Patch: https://datatracker.ietf.org/doc/html/rfc7386
- Playground interactivo de JSON Patch: https://jsonpatch.me/

**Kyverno**
- Reglas mutate (`patchesJson6902`, `patchStrategicMerge`, anchors, `foreach`): https://kyverno.io/docs/policy-types/cluster-policy/mutate/
- Mutar recursos existentes (`targets`, RBAC): https://kyverno.io/docs/policy-types/cluster-policy/mutate/#mutate-existing-resources
- Preconditions: https://kyverno.io/docs/policy-types/cluster-policy/preconditions/
- JMESPath en Kyverno: https://kyverno.io/docs/policy-types/cluster-policy/jmespath/
- Reglas auto-gen para controladores de Pod: https://kyverno.io/docs/policy-types/cluster-policy/autogen/
- Kyverno CLI — `apply` y `test`: https://kyverno.io/docs/kyverno-cli/usage/apply/ · https://kyverno.io/docs/kyverno-cli/usage/test/
- Policy Reports: https://kyverno.io/docs/policy-reports/
- Personalización de permisos / agregación RBAC: https://kyverno.io/docs/installation/customization/#customizing-permissions
- Configuración de políticas (`failurePolicy`, `background`, `webhookConfiguration`): https://kyverno.io/docs/policy-types/cluster-policy/policy-settings/
- Biblioteca de políticas de Kyverno — ejemplos de mutación: https://kyverno.io/policies/?policytypes=mutate

**Kubernetes**
- Actualizar objetos de la API en el lugar con `kubectl patch`: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- Dynamic Admission Control — webhooks, `reinvocationPolicy`, `failurePolicy`: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Server-Side Apply y gestión de campos: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Conceptos de la API — content types de patch: https://kubernetes.io/docs/reference/using-api/api-concepts/#patch-and-apply
- Mutating Admission Policy (mutación basada en CEL con `patchType: JSONPatch`; verificá el estado actual del feature gate para tu versión): https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- Referencia de `kubectl patch`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_patch/

**Implementación**
- `evanphx/json-patch` — la implementación de RFC 6902 que usan Kubernetes y Kyverno: https://github.com/evanphx/json-patch
- Strategic merge patch de `k8s.io/apimachinery`: https://github.com/kubernetes/apimachinery/tree/master/pkg/util/strategicpatch

**Currícula**
- Currícula KCA (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf