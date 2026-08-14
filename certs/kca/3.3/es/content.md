# 3.3 — `kyverno jp`: JMESPath como la superficie de depuración de Kyverno

**Certificación:** Kyverno Certified Associate (KCA) · **Dominio 3 — Kyverno CLI** · **Peso del tema: 3.0**

Este tema cubre la familia de subcomandos `jp` de la CLI de Kyverno — `kyverno jp query`, `kyverno jp parse` y `kyverno jp function` — y, de forma inseparable, el dialecto de JMESPath que esos comandos exponen: el mismo motor de expresiones que resuelve cada `{{ ... }}` en un `ClusterPolicy`, cada `context[].apiCall.jmesPath`, cada clave de `preconditions` y cada operando de `deny.conditions`.

---

## 1. El problema en producción: tu lenguaje de políticas no tiene REPL, y su runtime es la ruta de admisión

### 1.1 Dónde se ejecuta realmente JMESPath

Un `ClusterPolicy` de Kyverno no se evalúa contra tu recurso. Se evalúa contra un documento JSON sintético — el **contexto de la política** — que Kyverno ensambla por cada solicitud de admisión. Entender este documento es todo el tema; todo lo que hace `kyverno jp` es permitirte mantener ese documento quieto e interrogarlo de forma offline.

```
                        kube-apiserver
                              │
                  AdmissionReview (JSON)
                              │
                              ▼
        ┌───────────────────────────────────────────┐
        │ Kyverno admission webhook (kyverno-svc)   │
        │                                           │
        │  1. Policy cache lookup (match/exclude)   │
        │  2. Build POLICY CONTEXT:                 │
        │       request.{operation,object,oldObject,│
        │                userInfo,namespace,...}    │
        │       serviceAccountName                  │
        │       serviceAccountNamespace             │
        │       images.{containers,initContainers,  │
        │               ephemeralContainers}        │
        │       element / elementIndex  (foreach)   │
        │       @  (current value, in patterns)     │
        │  3. Resolve context[] entries IN ORDER    │
        │       configMap | apiCall | imageRegistry │
        │       | variable | globalReference        │
        │       ...each may apply a jmesPath        │
        │  4. Substitute {{ }}  ← JMESPath engine   │
        │  5. Evaluate preconditions ← JMESPath     │
        │  6. Evaluate rule                         │
        │       validate.pattern  ← JMESPath in @   │
        │       validate.deny.conditions ← JMESPath │
        │       mutate.patchStrategicMerge ← {{ }}  │
        │       generate.data ← {{ }}               │
        └───────────────────────────────────────────┘
                              │
                    AdmissionResponse (allow/deny)
```

Los pasos 3–6 son todos un mismo lenguaje. Una sola clave mal escrita, un `kubernetes.io/arch` sin comillas, una proyección que aplana un nivel de más — y la regla o bien falla en abierto (audit, silencioso), falla en cerrado (`Enforce`, y ahora `CREATE Pod` está roto en todo el clúster), o da error durante la sustitución y deja toda la política fuera de servicio.

### 1.2 Por qué iterar dentro del clúster es el bucle equivocado

El bucle ingenuo de depuración para una expresión rota es: editar la política → `kubectl apply` → crear un Pod de prueba → leer `kubectl describe polr` o los logs de Kyverno → repetir. Cada propiedad de ese bucle es hostil:

| Propiedad del bucle dentro del clúster | Consecuencia |
|---|---|
| El ida y vuelta es de 10–60 s (reconciliación de la config del webhook + refresco de la caché de políticas) | 5 iteraciones sobre un bug de comillas cuestan una pausa para el café |
| `failurePolicy: Fail` + `Enforce` | Una expresión mal formada sobre un `match` amplio bloquea cargas de trabajo reales mientras depurás |
| Timeout del webhook (por defecto `--webhookTimeout=10`, máx. 30 s) | Un `apiCall` que agregaste para *probar* una expresión ahora está en la ruta crítica de cada CREATE |
| Los errores se reportan como una falla de sustitución, no como una posición en JMESPath | `variable substitution failed` te dice *que* se rompió, no *dónde* |
| El documento de contexto nunca se imprime | Estás adivinando la entrada, así que no podés distinguir una expresión equivocada de una suposición equivocada sobre la entrada |
| Los Policy Reports son eventualmente consistentes | Podés leer un `PolicyReport` generado por la revisión *anterior* de la política |

`kyverno jp` colapsa todo eso en un bucle de menos de un segundo, offline, sin clúster, donde **la entrada es un archivo que vos controlás**. Esta es la misma razón por la que los SRE prefieren `promtool query instant` antes que hacer clic en Grafana: querés la evaluación aislada del mecanismo de entrega.

### 1.3 La afirmación arquitectónica que vale la pena internalizar

> En Kyverno, JMESPath no es una comodidad para leer campos. Es el sistema de tipos, la estrategia de manejo de null, la capa aritmética y el flujo de control de tus políticas. Casi todo "bug de Kyverno" reportado por un equipo de plataforma es un bug de JMESPath, y `kyverno jp` es la única herramienta que puede probarlo de forma aislada.

---

## 2. `kyverno jp` — anatomía de los tres subcomandos

```
$ kyverno jp --help
Provides a command-line interface to JMESPath, enhanced with Kyverno specific custom functions.

Usage:
  kyverno jp [command]

Available Commands:
  function    Provides function informations.
  parse       Parses jmespath expression and shows corresponding AST.
  query       Provides a command-line interface to JMESPath, enhanced with Kyverno specific custom functions.

Flags:
  -h, --help   help for jp

Use "kyverno jp [command] --help" for more information about a command.
```

| Subcomando | Responde la pregunta | ¿Lee un recurso? | Uso típico |
|---|---|---|---|
| `kyverno jp function [name...]` | "¿Existe esta función en **mi** build, y cuál es su firma exacta?" | No | Chequeo de deriva de versión; descubrir el conjunto de funciones personalizadas |
| `kyverno jp parse '<expr>'` | "¿Cómo *agrupa* el parser mi expresión?" | No | Bugs de precedencia, bugs de comillas, confusión pipe-vs-subexpresión |
| `kyverno jp query -i <file> '<expr>'` | "¿Qué devuelve realmente esta expresión para esta entrada?" | Sí (archivo o stdin) | 95 % del trabajo real |

### 2.1 `kyverno jp query`

```
$ kyverno jp query --help
Provides a command-line interface to JMESPath, enhanced with Kyverno specific custom functions.

Usage:
  kyverno jp query [-i input] [-q query|query]... [flags]

Examples:
  # Evaluate query
  kyverno jp query -i object.yaml 'request.object.metadata.name'

  # Evaluate query
  echo '{ "foo": "bar" }' | kyverno jp query 'foo'

  # Evaluate multiple queries
  kyverno jp query -i object.yaml 'request.object.metadata.name' 'request.object.metadata.namespace'

  # Evaluate query from a file
  kyverno jp query -i object.yaml -q query-file

Flags:
      --compact          Produce compact JSON output that omits non essential whitespace
  -h, --help             help for query
  -i, --input string     Input file or data (json or yaml)
  -q, --query strings    Query file (multiple can be passed)
  -u, --unquoted         Print unquoted strings
```

Cuatro comportamientos que importan operacionalmente:

1. **La entrada es JSON *o* YAML.** El YAML se convierte a JSON antes de evaluar, así que `spec.containers[].image` funciona directamente contra un `pod.yaml`. Por esto podés hacer `jp query` sobre un manifiesto sacado directamente de git.
2. **stdin es una entrada de primera clase.** Omití `-i` y usá un pipe. Esto es lo que hace posible el prototipado con `kubectl get --raw` (ver §5.2).
3. **`-u/--unquoted`** quita las comillas JSON de un resultado escalar de tipo string — obligatorio cuando querés incrustar el resultado en una variable de shell, inútil (e ignorado) para arrays/objetos.
4. **Múltiples queries** pueden pasarse posicionalmente o mediante `-q` repetido; cuando se evalúa más de una, cada resultado va precedido por un encabezado prefijado con `#` que nombra la query.

### 2.2 `kyverno jp parse`

`parse` imprime el árbol de sintaxis abstracta sin evaluar nada. Su único trabajo es responder *"¿leyó el parser lo que quise decir?"* — que es exactamente el modo de falla de `|` (pipe) frente a `.` (subexpresión) y de la precedencia de operadores en torno a `&&`, `||`, `!` y las comparaciones.

### 2.3 `kyverno jp function`

La enumeración autoritativa de cada función **en el binario que tenés en la mano**. El conjunto de funciones de Kyverno es la unión de dos blancos móviles — las funciones integradas de la *community edition* de JMESPath y las funciones personalizadas propias de Kyverno — y ambos crecen entre releases menores. Nunca confíes en la lista de funciones de un blog post; confiá en `kyverno jp function`.

---

## 3. El dialecto: JMESPath community edition + funciones personalizadas de Kyverno

### 3.1 Dos capas, un solo namespace

| Capa | Provista por | Ejemplos | Estabilidad |
|---|---|---|---|
| Lenguaje base + integradas | `jmespath-community/go-jmespath` | `length`, `keys`, `values`, `contains`, `starts_with`, `ends_with`, `join`, `sort_by`, `map`, `max_by`, `to_number`, `to_string`, `type`, `not_null`, `items`, `from_items`, `group_by`, `zip`, `let` | Sigue la spec de la community (JEPs); Kyverno la actualiza en releases menores |
| Funciones personalizadas de Kyverno | `kyverno/pkg/engine/jmespath` | `parse_json`, `parse_yaml`, `time_*`, `semver_compare`, `regex_match`, `label_match`, `x509_decode`, `add`/`subtract`/`divide`/`multiply`/`modulo`, `base64_*`, `path_canonicalize`, `image_normalize`, `lookup`, `random`, `truncate`, `split`, `to_upper`, `to_lower`, `trim*`, `replace*`, `compare`, `equal_fold`, `object_from_lists` | Agregadas por release menor de Kyverno |

Como ambas capas comparten un solo namespace, **las colisiones de nombres y el shadowing son reales**: la community edition agregó `split`, `replace`, `trim`, `lower`/`upper`, `items` y `pad_left`/`pad_right` después de que Kyverno ya había publicado equivalentes personalizados. En un build dado, solo `kyverno jp function <name>` te dice qué firma ganó.

```
$ kyverno jp function truncate
Name: truncate
  Signature: truncate(string, number) string
  Note: length argument must be enclosed in backticks; ',' is a literal character
```

```
$ kyverno jp function | head -32
Name: abs
  Signature: abs(number) number

Name: add
  Signature: add(any, any) any
  Note: does arithmetic addition of two specified values of numbers, quantities, and durations

Name: avg
  Signature: avg(array[number]) number

Name: base64_decode
  Signature: base64_decode(string) string

Name: base64_encode
  Signature: base64_encode(string) string

Name: ceil
  Signature: ceil(number) number

Name: compare
  Signature: compare(string, string) number

Name: contains
  Signature: contains(array|string, any) boolean

Name: divide
  Signature: divide(any, any) any
  Note: divisor must be non zero
```

```
$ kyverno jp function | grep -c '^Name:'
77
```

> **Hábito de nivel examen.** Cuando una pregunta o una tarea dice "qué función convierte un string codificado en JSON en un objeto", la respuesta es `parse_json` — pero el reflejo que querés es `kyverno jp function | grep -i json`, porque el mismo reflejo es el que te salva en producción frente a una versión que no instalaste.

### 3.2 Las funciones personalizadas que cargan peso real de políticas

| Función | Firma | Por qué la necesita un equipo de plataforma |
|---|---|---|
| `parse_json` | `parse_json(string) any` | Los valores de un ConfigMap son strings. Cualquier allowlist estructurada guardada en un ConfigMap debe pasar por esto antes de poder indexarse. |
| `parse_yaml` | `parse_yaml(string) any` | Igual, para claves de ConfigMap codificadas en YAML — muy común para blobs de configuración por tenant. |
| `add` / `subtract` / `multiply` / `divide` / `modulo` | `(any, any) any` | Operan sobre **números, cantidades de Kubernetes (`100m`, `2Gi`) y duraciones de Go (`1h30m`)**. Esta es la única forma sensata de comparar `resources.requests.memory` contra un presupuesto. |
| `semver_compare` | `semver_compare(string, string) boolean` | Coincidencia de restricciones sobre tags de imagen / versiones de chart: `semver_compare('1.28.3', '>=1.27.0 <2.0.0')`. |
| `regex_match` | `regex_match(string, string\|number) boolean` | Coincidencia RE2; el caballo de batalla para convenciones de nombres y prefijos de registry. |
| `pattern_match` | `pattern_match(string, string\|number) boolean` | El matcher de *comodines* de Kyverno (`*`, `?`), no regex — coincide con la semántica usada por `match.resources.names`. |
| `label_match` | `label_match(object, object) boolean` | Comparación de subconjunto de mapas de labels — evita armar a mano cadenas de `&&` por clave. |
| `time_now_utc` / `time_before` / `time_after` / `time_diff` / `time_since` / `time_add` / `time_to_cron` | ver `jp function` | Anotaciones de expiración, ventanas de mantenimiento, reglas de "no deploys los viernes". |
| `x509_decode` | `x509_decode(string) object` | Decodifica un certificado PEM/DER en un objeto estructurado — políticas de rotar-antes-de-expirar sobre Secrets `kubernetes.io/tls`. |
| `image_normalize` | `image_normalize(string) string` | Expande `nginx` → referencias canónicas del estilo `docker.io/nginx:latest` para que los chequeos de prefijo no puedan eludirse con formas abreviadas. |
| `path_canonicalize` | `path_canonicalize(string) string` | Normaliza `/etc/../etc/passwd` antes de las decisiones de permitir/denegar hostPath — una clase genuina de bypass. |
| `lookup` | `lookup(object\|array, string\|number) any` | Indexado dinámico de claves — JMESPath no tiene `obj[expr]`; `lookup` es la vía de escape. |
| `object_from_lists` | `object_from_lists(array, array) object` | Construye un mapa a partir de arrays paralelos, p. ej. emparejando nombres de contenedores con imágenes. |

---

## 4. Construir la entrada: la técnica de mayor valor

### 4.1 El documento de contexto, reconstruido a mano

Tu política dice `{{ request.object.spec.containers[].image }}`. Tu `pod.yaml` no tiene clave `request`. Por eso los principiantes quitan el prefijo cuando prueban con `jp` — y después publican la expresión sin probar. **No quites el prefijo. Construí el envoltorio.**

`request-create-pod.yaml` — una reconstrucción fiel y mínima del contexto de política de Kyverno para un `CREATE Pod` en el namespace `prod-payments`:

```yaml
# request-create-pod.yaml
# A hand-built Kyverno policy context. Query it with the EXACT expressions
# that appear inside {{ }} in the policy under test.
request:
  operation: CREATE
  namespace: prod-payments
  userInfo:
    username: system:serviceaccount:prod-payments:deployer
    groups:
      - system:serviceaccounts
      - system:serviceaccounts:prod-payments
      - system:authenticated
  oldObject: null
  object:
    apiVersion: v1
    kind: Pod
    metadata:
      name: web-frontend-6d4c9f8b7-2xk9p
      namespace: prod-payments
      labels:
        app.kubernetes.io/name: web-frontend
        acme.io/cost-center: cc-4417
        acme.io/tier: frontend
      annotations:
        acme.io/owner: payments-platform@acme.example
        acme.io/expires-at: "2026-09-30T00:00:00Z"
        kubectl.kubernetes.io/last-applied-configuration: |
          {"apiVersion":"v1","kind":"Pod"}
    spec:
      serviceAccountName: web-frontend
      nodeSelector:
        kubernetes.io/arch: amd64
      initContainers:
        - name: migrate
          image: ghcr.io/acme/db-migrate:2.4.1
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
      containers:
        - name: app
          image: ghcr.io/acme/web-frontend:1.28.3
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
        - name: envoy-sidecar
          image: docker.io/envoyproxy/envoy:v1.29.1
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true

# Kyverno also injects these at the top level of the context:
serviceAccountName: deployer
serviceAccountNamespace: prod-payments
```

Ahora toda expresión se puede probar tal cual:

```
$ kyverno jp query -i request-create-pod.yaml 'request.object.metadata.name'
"web-frontend-6d4c9f8b7-2xk9p"
```

```
$ kyverno jp query -i request-create-pod.yaml -u 'request.object.metadata.name'
web-frontend-6d4c9f8b7-2xk9p
```

```
$ kyverno jp query -i request-create-pod.yaml 'request.object.spec.[containers, initContainers, ephemeralContainers][].image'
[
  "ghcr.io/acme/web-frontend:1.28.3",
  "docker.io/envoyproxy/envoy:v1.29.1",
  "ghcr.io/acme/db-migrate:2.4.1"
]
```

Esa última expresión es el idiom canónico de Kyverno para "cada imagen en el Pod, incluyendo los init y ephemeral containers". Notá lo que sobrevive: `ephemeralContainers` está **ausente** en la entrada. La multiselect-list produce un elemento `null`, el flatten lo conserva, y la proyección `.image` lo descarta silenciosamente. Una concatenación `[]` ingenua en la mayoría de los otros lenguajes lanzaría una excepción.

### 4.2 Generar el contexto desde un clúster vivo en lugar de a mano

```
$ kubectl get pod web-frontend-6d4c9f8b7-2xk9p -n prod-payments -o json \
    | jq '{request: {operation: "CREATE", namespace: .metadata.namespace, object: .}}' \
    > request-live.yaml
```

```
$ kyverno jp query -i request-live.yaml 'request.object.spec.containers[].name'
[
  "app",
  "envoy-sidecar"
]
```

Para objetos vivos, recordá que el API server ya rellenó valores por defecto (`serviceAccountName`, `terminationGracePeriodSeconds`, `imagePullPolicy`, el volumen `kube-api-access-*`). Una política que pasa contra un objeto vivo puede aún fallar contra el objeto *enviado* en el momento de la admisión, y viceversa. Cuando la distinción importa, capturá el payload real desde los logs de Kyverno con `-v 4` en lugar de desde `kubectl get`.

---

## 5. Sesiones de trabajo: de la expresión a la política

### 5.1 Sesión 1 — una allowlist de registry, probada antes de publicarse

**Requisito:** cada imagen debe provenir de `ghcr.io/acme/` o `docker.io/envoyproxy/`.

Paso 1 — obtener la lista cruda (hecho arriba). Paso 2 — encontrar las *violaciones*, no las coincidencias, porque la condición de deny necesita un conjunto de violaciones no vacío:

```
$ kyverno jp query -i request-create-pod.yaml \
    'request.object.spec.[containers, initContainers, ephemeralContainers][].image | [?!starts_with(@, '"'"'ghcr.io/acme/'"'"') && !starts_with(@, '"'"'docker.io/envoyproxy/'"'"')]'
[]
```

Vacío — este Pod pasa. Ahora probá que la regla efectivamente *se dispara*. Mutá la entrada in situ y volvé a ejecutar:

```
$ sed 's|docker.io/envoyproxy/envoy:v1.29.1|quay.io/envoyproxy/envoy:v1.29.1|' request-create-pod.yaml > request-bad.yaml
$ kyverno jp query -i request-bad.yaml \
    'request.object.spec.[containers, initContainers, ephemeralContainers][].image | [?!starts_with(@, `"ghcr.io/acme/"`) && !starts_with(@, `"docker.io/envoyproxy/"`)] | length(@)'
1
```

Arriba aparecen dos estilos de literal: `'raw string'` y `` `"json string"` ``. Ambos son JMESPath válido; §5.5 explica cuándo el shell te obliga a elegir.

> **El bypass que te acabás de perder.** `starts_with` contra un `nginx` pelado devuelve `false`, así que `nginx` sería *reportado como una violación* — correcto acá. Pero una política escrita como una **allowlist de prefijos con `contains`** dejaría pasar `evil.example/ghcr.io/acme/x`. Y una referencia corta como `acme/web:1.0` se resuelve en runtime a `docker.io/acme/web:1.0`, que tu chequeo de prefijo nunca ve. Normalizá primero:

```
$ echo '{"images":["nginx","acme/web:1.0","ghcr.io/acme/web-frontend:1.28.3"]}' \
    | kyverno jp query 'images[].image_normalize(@)'
[
  "docker.io/nginx:latest",
  "docker.io/acme/web:1.0",
  "ghcr.io/acme/web-frontend:1.28.3"
]
```

### 5.2 Sesión 2 — prototipar un `context.apiCall.jmesPath` contra la API viva

La entrada de contexto `apiCall` es el constructo más peligroso de Kyverno: pone un ida y vuelta al API server vivo en la ruta de admisión. Equivocarse en su `jmesPath` significa o bien una falla de sustitución (política fuera de servicio) o un `null` silencioso (la regla falla en abierto). Prototipalo contra el *mismo* endpoint que llamará el webhook:

```
$ kubectl get --raw "/api/v1/namespaces/prod-payments/resourcequotas" \
    | kyverno jp query 'items[].{name: metadata.name, hardMem: status.hard."limits.memory", usedMem: status.used."limits.memory"}'
[
  {
    "hardMem": "64Gi",
    "name": "prod-payments-quota",
    "usedMem": "41Gi"
  }
]
```

Ahora reducilo al único escalar que la política necesita, y verificá la aritmética:

```
$ kubectl get --raw "/api/v1/namespaces/prod-payments/resourcequotas" \
    | kyverno jp query -u 'items[0] | subtract(status.hard."limits.memory", status.used."limits.memory")'
23Gi
```

`subtract` sobre dos cantidades de Kubernetes devuelve una cantidad. Esto es exactamente por qué hacer las cuentas a mano en `deny.conditions` con `to_number` falla: `to_number('64Gi')` no es 68719476736.

El `.` antes de una clave entre comillas es obligatorio: `status.hard."limits.memory"`. Sin las comillas, JMESPath lee `limits` y `memory` como dos campos anidados y devuelve `null` — un `null` silencioso que falla en abierto.

```
$ kubectl get --raw "/api/v1/namespaces/prod-payments/resourcequotas" \
    | kyverno jp query 'items[0].status.hard.limits.memory'
null
```

> `null` es el enemigo. Nunca es un error, se propaga, y en modo `Audit` se ve exactamente como "sin violaciones".

Dos prototipos más de `apiCall` que vale la pena memorizar:

```
$ kubectl get --raw "/api/v1/namespaces/prod-payments/pods" \
    | kyverno jp query 'items | length(@)'
14
```

```
$ kubectl get --raw "/apis/networking.k8s.io/v1/namespaces/prod-payments/ingresses" \
    | kyverno jp query 'items[].spec.rules[].host | sort(@)'
[
  "api.acme.example",
  "checkout.acme.example",
  "www.acme.example"
]
```

### 5.3 Sesión 3 — una allowlist en ConfigMap y `parse_json`

Las entradas de contexto `configMap` exponen el ConfigMap bajo `<name>.data.<key>`, y **cada valor es un string**. Los datos estructurados deben parsearse.

```yaml
# allowed-registries-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: acme-registry-policy
  namespace: kyverno
data:
  # Deliberately stored as a JSON string: ConfigMap values are always strings.
  allowlist: |
    {
      "prod-payments":  ["ghcr.io/acme/", "docker.io/envoyproxy/"],
      "prod-search":    ["ghcr.io/acme/"],
      "_default":       ["ghcr.io/acme/"]
    }
  maxCpuPerContainer: "2"
```

Prototipá la cadena exacta que usará la política — parsear, luego indexar dinámicamente con `lookup`, con un fallback:

```
$ kubectl get cm acme-registry-policy -n kyverno -o json \
    | kyverno jp query 'parse_json(data.allowlist)'
{
  "_default": [
    "ghcr.io/acme/"
  ],
  "prod-payments": [
    "ghcr.io/acme/",
    "docker.io/envoyproxy/"
  ],
  "prod-search": [
    "ghcr.io/acme/"
  ]
}
```

```
$ kubectl get cm acme-registry-policy -n kyverno -o json \
    | kyverno jp query "lookup(parse_json(data.allowlist), 'prod-payments')"
[
  "ghcr.io/acme/",
  "docker.io/envoyproxy/"
]
```

```
$ kubectl get cm acme-registry-policy -n kyverno -o json \
    | kyverno jp query "lookup(parse_json(data.allowlist), 'sandbox-ci') || lookup(parse_json(data.allowlist), '_default')"
[
  "ghcr.io/acme/"
]
```

Ese `||` es el idiom de seguridad ante null. La or-expression de JMESPath trata `null`, `false`, `""`, `[]` y `{}` como falso, así que también funciona como operador de valor por defecto — y es lo que evita que Kyverno lance `variable substitution failed` sobre un namespace ausente del mapa.

`lookup` existe porque JMESPath **no tiene sintaxis de clave computada**: no podés escribir `map[key]` donde `key` es una expresión. Todo intento de escribir `parse_json(data.allowlist).{{request.namespace}}` es un hack de concatenación de strings que se rompe con el primer namespace que contenga un guion.

### 5.4 Sesión 4 — tiempo, semver y certificados

Anotación de expiración:

```
$ kyverno jp query -i request-create-pod.yaml -u \
    'request.object.metadata.annotations."acme.io/expires-at"'
2026-09-30T00:00:00Z
```

```
$ kyverno jp query -i request-create-pod.yaml \
    'time_before(time_now_utc(), request.object.metadata.annotations."acme.io/expires-at")'
true
```

```
$ kyverno jp query -i request-create-pod.yaml -u \
    'time_diff(time_now_utc(), request.object.metadata.annotations."acme.io/expires-at")'
1152h0m0s
```

Piso de versión basado en el tag — notá el split de `image` en `:` antes de comparar:

```
$ kyverno jp query -i request-create-pod.yaml \
    "request.object.spec.containers[?name=='app'].image | [0] | split(@, ':') | [1] | semver_compare(@, '>=1.27.0')"
true
```

Expiración de certificado — **descubrí la forma, no la memorices**:

```
$ kubectl get secret acme-ingress-tls -n prod-payments -o json \
    | kyverno jp query 'x509_decode(base64_decode(data."tls.crt")) | keys(@)'
[
  "AuthorityKeyId",
  "BasicConstraintsValid",
  "Extensions",
  "IsCA",
  "Issuer",
  "PublicKey",
  "PublicKeyAlgorithm",
  "SerialNumber",
  "Signature",
  "SignatureAlgorithm",
  "Subject",
  "SubjectKeyId",
  "Validity"
]
```

```
$ kubectl get secret acme-ingress-tls -n prod-payments -o json \
    | kyverno jp query 'x509_decode(base64_decode(data."tls.crt")).Validity'
{
  "NotAfter": "2026-11-14T09:12:44Z",
  "NotBefore": "2026-08-16T09:12:44Z"
}
```

La forma de salida de `x509_decode` ha cambiado entre releases de Kyverno. `keys(@)` contra tu propio binario es un chequeo de dos segundos que sobrevive a cualquier documentación que copies.

### 5.5 La matriz de escapado — donde la mayoría de las sesiones de `jp` mueren en realidad

Se apilan tres capas de comillas: **shell → YAML → JMESPath**. No se ponen de acuerdo sobre `'`, `"` y `` ` ``.

| Constructo JMESPath | Significado | Dentro de un arg de `bash` con comillas dobles | Dentro de un arg de `bash` con comillas simples | Dentro de una política YAML |
|---|---|---|---|---|
| `'text'` (literal de string crudo) | String literal, sin escapes | Seguro: `"... 'text' ..."` | Hay que romper la comilla: `'"'"'text'"'"'` | Seguro dentro de un escalar YAML con comillas dobles |
| `` `"text"` `` (literal JSON) | Literal, tipado como JSON | **PELIGROSO** — los backticks son sustitución de comandos | Seguro | Seguro, pero a YAML no le gusta un `` ` `` inicial; poné el escalar entre comillas |
| `` `true` `` / `` `42` `` | Literal booleano/numérico JSON | **PELIGROSO** | Seguro | Seguro cuando el escalar está entre comillas |
| `"key.with.dots"` (identificador entre comillas) | Nombre de campo que contiene `.`, `/`, `-` | Hay que escapar: `\"key\"` | Seguro | Usá comillas simples de YAML alrededor de toda la expresión |
| `\|` (pipe) | Detiene una proyección | Seguro si está entre comillas | Seguro | Seguro |

Regla práctica que elimina toda la clase de bugs:

> **Envolvé la expresión JMESPath en comillas simples de shell; usá `'literales crudos'` solo cuando sea imprescindible, de lo contrario preferí identificadores entre comillas dobles.** Cuando necesitás ambos, poné la expresión en un archivo y usá `-q`.

```
$ cat > q-registry.jmespath <<'EOF'
request.object.spec.[containers, initContainers, ephemeralContainers][].image
  | [?!starts_with(@, `"ghcr.io/acme/"`) && !starts_with(@, `"docker.io/envoyproxy/"`)]
EOF
$ kyverno jp query -i request-bad.yaml -q q-registry.jmespath
[
  "quay.io/envoyproxy/envoy:v1.29.1"
]
```

Un archivo de query saca por completo al shell de la ecuación y es revisable en git junto a la política.

### 5.6 `kyverno jp parse` — leer la precedencia en lugar de adivinarla

```
$ kyverno jp parse 'request.object.metadata.name'
ASTSubexpression {
  children: {
    ASTSubexpression {
      children: {
        ASTField {
          value: "request"
        }
        ASTField {
          value: "object"
        }
    ASTField {
      value: "metadata"
    }
    ASTField {
      value: "name"
    }
}
```

El valor de `parse` es comparativo. Considerá el clásico bug del pipe:

```
$ kyverno jp query -i request-create-pod.yaml 'request.object.spec.containers[].name | length(@)'
2
```

```
$ kyverno jp query -i request-create-pod.yaml 'request.object.spec.containers[].length(@)'
[
  3,
  14
]
```

De apariencia idéntica, completamente diferentes: sin el pipe, `length(@)` se aplica *dentro* de la proyección a cada elemento (la longitud del **nombre** de cada contenedor); con el pipe, la proyección se cierra primero y `length` se aplica al array. `parse` muestra la diferencia estructural — `ASTPipe` en la raíz frente a `ASTProjection` — antes de que publiques una política que cuenta caracteres en lugar de contenedores.

**Esta es la causa número uno de "mi condición `deny` compara la cosa equivocada" en Kyverno.** Cada vez que una función sigue a un `[]` o `[*]`, preguntate si querías cerrar la proyección.

---

## 6. De la expresión verificada a la política de producción

Cada `{{ }}` de abajo fue producido por las sesiones anteriores. Esa es la disciplina que se enseña: **ninguna expresión entra en un manifiesto hasta que `kyverno jp query` haya impreso su valor.**

### 6.1 Una política de validación con una allowlist por namespace respaldada por un ConfigMap

```yaml
# policy-registry-allowlist.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
  annotations:
    policies.kyverno.io/title: Restrict Image Registries
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Images must originate from a registry prefix allowlisted for the target
      namespace. The allowlist is read from a ConfigMap so it can be changed
      without re-deploying the policy. References are normalised with
      image_normalize() so that short forms such as "nginx" cannot bypass the
      prefix check.
spec:
  background: true
  # Kyverno >= 1.12: failureAction lives on the rule. On Kyverno <= 1.11 use
  # the policy-level `spec.validationFailureAction: Enforce` instead.
  rules:
    - name: validate-registry-prefix
      match:
        any:
          - resources:
              kinds:
                - Pod
      # Do not police the platform's own namespaces.
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      context:
        # 1. Load the allowlist ConfigMap.
        - name: registryPolicy
          configMap:
            name: acme-registry-policy
            namespace: kyverno
        # 2. Parse the JSON string and select this namespace's entry,
        #    falling back to "_default". Verified in §5.3.
        - name: allowedPrefixes
          variable:
            jmesPath: >-
              lookup(parse_json(registryPolicy.data.allowlist), '{{ request.namespace }}')
              || lookup(parse_json(registryPolicy.data.allowlist), '_default')
            default: []
        # 3. Normalise every image reference in the Pod. Verified in §5.1.
        - name: allImages
          variable:
            jmesPath: >-
              request.object.spec.[containers, initContainers, ephemeralContainers][].image_normalize(@)
            default: []
      preconditions:
        all:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
          - key: "{{ length(allowedPrefixes) }}"
            operator: GreaterThan
            value: 0
      validate:
        failureAction: Enforce
        message: >-
          Image(s) {{ allImages[?!starts_with(@, allowedPrefixes[0])] | join(', ', @) }}
          are not from an allowlisted registry for namespace {{ request.namespace }}.
          Allowed prefixes: {{ join(', ', allowedPrefixes) }}.
        foreach:
          - list: "allImages"
            deny:
              conditions:
                all:
                  # element is the current image; count how many allowlisted
                  # prefixes it matches. Zero matches => deny.
                  - key: >-
                      {{ length(allowedPrefixes[?starts_with('{{ element }}', @)]) }}
                    operator: Equals
                    value: 0
```

Dos notas de ingeniería que se espera que haga un candidato KCA:

* Las entradas de `context` se resuelven **en orden de declaración**, y las entradas posteriores pueden referenciar a las anteriores (`allowedPrefixes` lee `registryPolicy`). Reordenálas y obtenés `Unknown key "registryPolicy" in path`.
* `variable.default` es la forma soportada de hacer que una entrada de contexto sea segura ante null. Sin ella, un namespace ausente del ConfigMap convierte una validación en un **error de sustitución**, y un error de sustitución en modo `Enforce` es una denegación con un mensaje poco útil.

### 6.2 Una política de mutación impulsada por aritmética de cantidades

```yaml
# policy-default-memory-limit.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-memory-limit-from-request
  annotations:
    policies.kyverno.io/title: Default Memory Limit From Request
    policies.kyverno.io/category: Resource Management
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Containers that declare a memory request but no memory limit receive a
      limit of 1.5x their request. The multiplication is performed by the
      JMESPath multiply() function, which understands Kubernetes quantities;
      to_number() would silently mis-handle the Gi/Mi suffixes.
spec:
  background: false
  rules:
    - name: set-memory-limit
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        foreach:
          - list: "request.object.spec.containers"
            preconditions:
              all:
                - key: "{{ element.resources.requests.memory || '' }}"
                  operator: NotEquals
                  value: ""
                - key: "{{ element.resources.limits.memory || '' }}"
                  operator: Equals
                  value: ""
            patchStrategicMerge:
              spec:
                containers:
                  - name: "{{ element.name }}"
                    resources:
                      limits:
                        memory: "{{ multiply(element.resources.requests.memory, `1.5`) }}"
```

Verificá la aritmética antes de confiar en ella:

```
$ echo '{"req":"512Mi"}' | kyverno jp query -u 'multiply(req, `1.5`)'
768Mi
```

```
$ echo '{"req":"1Gi"}' | kyverno jp query -u 'multiply(req, `1.5`)'
1536Mi
```

Contrastá con el instinto equivocado, que una sesión de `jp` expone en segundos:

```
$ echo '{"req":"512Mi"}' | kyverno jp query 'to_number(req) * `1.5`'
Error: SyntaxError: Unknown char: '*'
```

```
$ echo '{"req":"512Mi"}' | kyverno jp query 'multiply(to_number(req), `1.5`)'
Error: invalid type for: 512Mi, expected: [number]
```

### 6.3 Una política de validación sobre la expiración de certificados

```yaml
# policy-tls-secret-expiry.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-tls-secret-validity-window
  annotations:
    policies.kyverno.io/title: Require Minimum TLS Certificate Validity
    policies.kyverno.io/category: Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Rejects kubernetes.io/tls Secrets whose certificate expires in less than
      14 days, so that a short-lived or already-expired certificate is never
      installed on an Ingress.
spec:
  background: false
  rules:
    - name: check-notafter
      match:
        any:
          - resources:
              kinds:
                - Secret
              selector:
                matchLabels:
                  acme.io/managed-tls: "true"
      preconditions:
        all:
          - key: "{{ request.object.type || '' }}"
            operator: Equals
            value: kubernetes.io/tls
      context:
        - name: notAfter
          variable:
            jmesPath: >-
              x509_decode(base64_decode(request.object.data."tls.crt")).Validity.NotAfter
            default: ""
        - name: minValidUntil
          variable:
            jmesPath: "time_add(time_now_utc(), '336h')"
      validate:
        failureAction: Enforce
        message: >-
          Certificate in this Secret expires at {{ notAfter }}, which is less
          than 14 days away (threshold {{ minValidUntil }}).
        deny:
          conditions:
            any:
              - key: "{{ notAfter }}"
                operator: Equals
                value: ""
              - key: "{{ time_before(notAfter, minValidUntil) }}"
                operator: Equals
                value: true
```

```
$ kyverno jp query -u 'time_add(time_now_utc(), `"336h"`)' <<< '{}'
2026-08-27T14:22:09Z
```

---

## 7. La escalera de verificación

`jp` es el primer peldaño. Una política no está verificada hasta que haya subido los cuatro, y cada peldaño atrapa una clase que el peldaño de abajo no puede ver.

| Peldaño | Comando | Prueba | No puede probar |
|---|---|---|---|
| 1. Expresión | `kyverno jp query -i ctx.yaml '<expr>'` | La expresión parsea y devuelve el valor/tipo que esperás para una entrada dada | Que Kyverno construya ese contexto; que la regla haga match |
| 2. Política vs. recurso | `kyverno apply policy.yaml --resource pod.yaml` | Match/exclude, preconditions, sustitución, resultado de la regla — offline, sin clúster | Comportamiento frente a entradas de contexto que necesitan una API viva (a menos que se mockeen) |
| 3. Suite de regresión | `kyverno test .` | Pass/fail esperado por tupla (política, regla, recurso), en CI, para siempre | El orden real de admisión, los timeouts del webhook, el RBAC del SA de Kyverno |
| 4. Clúster | `kubectl apply --dry-run=server -f pod.yaml` | El webhook real, RBAC real, latencia real de `apiCall` | Nada — pero es el peldaño más lento y disruptivo |

### 7.1 Peldaño 2

```
$ kyverno apply policy-registry-allowlist.yaml \
    --resource pod-bad.yaml \
    --values-file values.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy restrict-image-registries -> resource prod-payments/Pod/web-frontend failed:
1. validate-registry-prefix: Image(s) quay.io/envoyproxy/envoy:v1.29.1 are not from an
   allowlisted registry for namespace prod-payments. Allowed prefixes: ghcr.io/acme/,
   docker.io/envoyproxy/.

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

`--values-file` provee lo que la CLI no puede obtener — `request.operation`, `request.namespace`, y cualquier entrada de contexto que elijas mockear:

```yaml
# values.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
policies:
  - name: restrict-image-registries
    rules:
      - name: validate-registry-prefix
        values:
          registryPolicy.data.allowlist: |
            {"prod-payments": ["ghcr.io/acme/", "docker.io/envoyproxy/"], "_default": ["ghcr.io/acme/"]}
    resources:
      - name: web-frontend
        values:
          request.operation: CREATE
          request.namespace: prod-payments
```

### 7.2 Peldaño 3

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: restrict-image-registries
policies:
  - policy-registry-allowlist.yaml
resources:
  - resources.yaml
variables: values.yaml
results:
  - policy: restrict-image-registries
    rule: validate-registry-prefix
    resources:
      - web-frontend-good
    kind: Pod
    result: pass
  - policy: restrict-image-registries
    rule: validate-registry-prefix
    resources:
      - web-frontend-bad
    kind: Pod
    result: fail
  - policy: restrict-image-registries
    rule: validate-registry-prefix
    resources:
      - web-frontend-shortref
    kind: Pod
    result: fail
```

```
$ kyverno test .

Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 3 resources ...
  Checking results ...

│───│────────────────────────────│─────────────────────────│───────────────────────────────│────────│
│ # │ POLICY                     │ RULE                    │ RESOURCE                      │ RESULT │
│───│────────────────────────────│─────────────────────────│───────────────────────────────│────────│
│ 1 │ restrict-image-registries  │ validate-registry-prefix│ default/Pod/web-frontend-good │ Pass   │
│ 2 │ restrict-image-registries  │ validate-registry-prefix│ default/Pod/web-frontend-bad  │ Pass   │
│ 3 │ restrict-image-registries  │ validate-registry-prefix│ default/Pod/web-frontend-shor…│ Pass   │
│───│────────────────────────────│─────────────────────────│───────────────────────────────│────────│

Test Summary: 3 tests passed and 0 tests failed
```

`RESULT: Pass` acá significa *"el resultado observado igualó al resultado esperado"* — la fila 2 esperaba `fail` y obtuvo `fail`. Confundir esto con "el recurso pasó la política" es una trampa clásica de KCA.

### 7.3 Peldaño 4

```
$ kubectl apply --dry-run=server -f pod-bad.yaml
Error from server: error when creating "pod-bad.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/prod-payments/web-frontend was blocked due to the following policies

restrict-image-registries:
  validate-registry-prefix: 'Image(s) quay.io/envoyproxy/envoy:v1.29.1 are not from
    an allowlisted registry for namespace prod-payments. Allowed prefixes:
    ghcr.io/acme/, docker.io/envoyproxy/.'
```

---

## 8. Diagnóstico de fallas: síntoma → causa → reproducción con `jp`

| Síntoma en el clúster | Causa raíz | Reproducir / arreglar con `jp` |
|---|---|---|
| La regla nunca se dispara; el reporte muestra `skip` | La precondición evalúa a `null`/`false` porque una clave está ausente | `kyverno jp query -i ctx.yaml '<precondition key expr>'` → si es `null`, agregá `\|\| 'default'` o un `variable.default` |
| `variable substitution failed: Unknown key "x" in path` | La expresión referencia una clave que no existe y no tiene fallback | La misma query; arreglá con `\|\| ''`, `not_null()`, o `context[].variable.default` |
| `Error: SyntaxError: Expected tRbracket, received: tOr` (o similar) | Expresión mal formada — normalmente `[]`, `()` o comillas desbalanceadas | `kyverno jp parse '<expr>'`; bisecá acortando la expresión hasta que parsee |
| `unknown function: to_uppr` | Error de tipeo, o la función no existe en **esta** versión de Kyverno | `kyverno jp function \| grep -i upp` |
| `invalid type for: <nil>, expected: [array object string]` | `length()`/`keys()` aplicado a un `null` de un lookup fallido | Consultá la subexpresión sola; el último paso no-null es donde se rompe |
| Condición de deny con `GreaterThan` da error o nunca se dispara | Comparar un **string** con un **número**; o comparar cantidades como números | `kyverno jp query '...\| type(@)'` — debe ser `number` para los operadores aritméticos, o usá `add`/`subtract` que entienden cantidades/duraciones |
| La condición compara conteos de caracteres en lugar de conteos de ítems | `length(@)` dentro de una proyección en lugar de después de un pipe | `kyverno jp parse` en ambas formas; buscá `ASTPipe` vs `ASTProjection` |
| La regla pasa para un Pod que claramente la viola | La proyección descartó los `null` y produjo `[]`, así que el filtro no encontró nada | Consultá la lista intermedia; verificá que `length(@)` sea lo que esperás |
| Funciona sobre un objeto vivo, falla en la admisión (o viceversa) | El rellenado de defaults del API server difiere entre el objeto enviado y el almacenado | Capturá el payload real desde `kubectl logs -n kyverno deploy/kyverno-admission-controller -v 4`, reconstruí el archivo de contexto |
| `apiCall` devuelve `null` y la política falla en abierto | `urlPath` equivocado, o la ServiceAccount de Kyverno carece de RBAC para ese recurso | `kubectl get --raw "<urlPath>" \| kyverno jp query '<jmesPath>'`, luego `kubectl auth can-i --as=system:serviceaccount:kyverno:kyverno-admission-controller get <resource>` |
| Un campo con `/` o `.` siempre resuelve a `null` | Identificador sin comillas | `... .annotations."acme.io/owner"` — poné el segmento entre comillas |
| Un literal con backtick quedó vacío en el shell | `` ` `` disparó la sustitución de comandos dentro de `"` | Volvé a ejecutar con comillas simples, o mové la expresión a un archivo `-q` |

### 8.1 Un diagnóstico resuelto

Reportado: *"la política del label de cost-center pasa para Pods que no tienen ese label."*

```
$ kyverno jp query -i request-create-pod.yaml 'request.object.metadata.labels."acme.io/cost-center"'
"cc-4417"
```

```
$ kyverno jp query -i request-no-labels.yaml 'request.object.metadata.labels."acme.io/cost-center"'
null
```

```
$ kyverno jp query -i request-no-labels.yaml 'regex_match(`"^cc-[0-9]{4}$"`, request.object.metadata.labels."acme.io/cost-center" || `""`)'
false
```

```
$ kyverno jp query -i request-no-labels.yaml 'regex_match(`"^cc-[0-9]{4}$"`, request.object.metadata.labels."acme.io/cost-center")'
Error: invalid type for: <nil>, expected: [string number]
```

Diagnóstico completo en tres comandos: la política original usaba la segunda forma, sin default, el motor lanzó un error de sustitución, y la regla se registró como `error` en lugar de `fail` — lo que el dashboard del equipo contaba como "sin violación". El arreglo es la guarda `|| \`""\``, más alertar sobre el tipo de resultado `error`, no solo `fail`.

---

## 9. Trade-offs que un Platform Architect debe poder defender

### 9.1 `kyverno jp query` frente a los vecinos

| Herramienta | Dialecto | Funciones personalizadas de Kyverno | Lee YAML | Correcta cuando |
|---|---|---|---|---|
| `kyverno jp query` | JMESPath (community) + Kyverno | **Sí** | Sí | Prototipar cualquier cosa que vaya a vivir dentro de un `ClusterPolicy` |
| `jp` (CLI de JMESPath upstream) | JMESPath | No | No (solo JSON) | Aprender JMESPath base; rechazará `parse_json`, `time_*`, `semver_compare` |
| `jq` | Lenguaje jq | No | No | Manipulación de datos ad-hoc en shell; **no puede** validar una expresión de Kyverno |
| `yq` | Estilo jq sobre YAML | No | Sí | Edición de manifiestos, no prototipado de políticas |
| `kubectl -o jsonpath` | JSONPath | No | n/a | Extracción rápida de campos; gramática distinta, semántica de null distinta |
| `kubectl -o custom-columns` | Subconjunto de JSONPath | No | n/a | Reportes tabulares |

La trampa: `jq` evaluará con gusto algo *que se parece* a tu expresión y te dará una confianza que no ganaste. Una proyección de JMESPath y un `.[]` de `jq` difieren en el manejo de null, y la aritmética de Kyverno sobre `2Gi` no existe ni en `jq` ni en el `jp` upstream.

### 9.2 JMESPath frente a CEL dentro de Kyverno

Los releases recientes de Kyverno (1.14+) agregaron tipos de política basados en CEL (`ValidatingPolicy` y afines) junto a los clásicos `ClusterPolicy`/`Policy`. Ambos motores vienen en el mismo binario; solo uno es alcanzable desde `kyverno jp`.

| Dimensión | JMESPath (`ClusterPolicy` / `Policy`) | CEL (`ValidatingPolicy`, `ValidatingAdmissionPolicy`) |
|---|---|---|
| REPL offline | **`kyverno jp query`** | Sin subcomando `jp` equivalente |
| Aritmética de cantidades de Kubernetes | `add`/`subtract`/`multiply`/`divide` sobre `2Gi`, `100m`, `1h` | Biblioteca `quantity()` |
| Manejo de null | `null` silencioso, se propaga — riesgo de fallar en abierto | Los errores son explícitos; tipos `has()` / `optional` |
| Límites de costo/complejidad | Ninguno — una expresión costosa es tu problema | Presupuesto de costo impuesto por el runtime |
| Descarga al API server | Kyverno puede *generar* un `ValidatingAdmissionPolicy` a partir de un subconjunto de reglas | Nativo |
| Mutación, generación, verificación de imágenes | Soporte completo | Más acotado (según el tipo de política / versión de K8s) |
| Superficie del examen KCA | **Esto es lo que se evalúa** | Periférico |

La arquitectura pragmática en 2026: escribí validaciones simples y de alto volumen para que puedan descargarse a `ValidatingAdmissionPolicy` (sin salto de webhook), y reservá el `ClusterPolicy` de JMESPath para mutación, generación, contexto `imageRegistry` y cualquier cosa que necesite `apiCall`. `kyverno jp` sigue siendo la herramienta de depuración para la segunda mitad.

### 9.3 El costo de una expresión en la ruta de admisión

| Constructo en una regla | Latencia agregada por solicitud de admisión | Radio de impacto de la falla |
|---|---|---|
| JMESPath puro sobre `request.object` | microsegundos | Ninguno más allá de la regla |
| Entrada de contexto `configMap` | ~0 (cacheado por el informer) | Valor obsoleto si el informer se atrasa |
| `variable` + `parse_json` de un blob grande | submilisegundo, pero por solicitud | CPU en el admission controller |
| `apiCall` (dentro del clúster) | 1 ida y vuelta al API server, típicamente 2–20 ms | Cuenta contra `--webhookTimeout`; la lentitud del API server se vuelve lentitud de admisión |
| `apiCall` a un `service` externo | RTT de red, sin cota en la práctica | Con `failurePolicy: Fail`, una caída externa se vuelve una caída de admisión en todo el clúster |
| Contexto `imageRegistry` | Ida y vuelta al registry, 50–500 ms | Una caída del registry bloquea la creación de Pods |
| `globalReference` (GlobalContextEntry) | ~0 en la admisión; refrescado en un intervalo | Ventana de obsolescencia igual al intervalo de refresco |

Esta tabla es por qué el flujo de trabajo con `jp` importa más allá de la comodidad: **cada `apiCall` que prototipás offline con `kubectl get --raw` es uno sobre el que no iteraste dentro de la ruta de admisión.** Y cuando un `apiCall` pesado es inevitable, la entrada de contexto `globalReference` saca el costo de la ruta de solicitud por completo — pero igual prototipás su `jmesPath` con `jp`.

---

## 10. Referencia de comandos para tener en la memoria muscular

```
# Discover the function set of the binary you actually have
$ kyverno jp function
$ kyverno jp function parse_json
$ kyverno jp function | grep -i time

# Evaluate against a file (JSON or YAML)
$ kyverno jp query -i request.yaml 'request.object.metadata.name'
$ kyverno jp query -i request.yaml -u 'request.object.metadata.name'     # no quotes
$ kyverno jp query -i request.yaml --compact 'request.object.spec.containers[].name'

# Evaluate against stdin — the live-cluster prototyping loop
$ kubectl get pod NAME -n NS -o json | kyverno jp query 'spec.containers[].image'
$ kubectl get --raw "/api/v1/namespaces/NS/resourcequotas" | kyverno jp query 'items[0].status.hard'

# Several queries at once
$ kyverno jp query -i request.yaml 'request.operation' 'request.namespace'

# Query from a file — no shell quoting at all
$ kyverno jp query -i request.yaml -q query.jmespath

# Inspect the parse tree when precedence is suspect
$ kyverno jp parse 'spec.containers[].name | length(@)'

# Climb the ladder
$ kyverno apply policy.yaml --resource pod.yaml --values-file values.yaml
$ kyverno test .
$ kubectl apply --dry-run=server -f pod.yaml
```

### Checklist antes de mergear cualquier expresión de Kyverno

1. `kyverno jp function <name>` para cada función no obvia usada — confirma que existe en tu versión objetivo.
2. `kyverno jp query` contra una entrada que **pasa** *y* una entrada que **falla**. Una regla probada solo contra el camino feliz no está probada.
3. `kyverno jp query` contra una entrada donde el campo está **ausente**. Si el resultado es `null`, agregá `|| default` o `variable.default`.
4. `kyverno jp parse` si la expresión contiene una función después de `[]`, o mezcla `&&`/`||`/`!` con comparaciones.
5. `type(@)` sobre cualquier operando que alimente `GreaterThan`/`LessThan`/aritmética.
6. Mové la expresión a un archivo `-q` si el escapado del shell requirió más de un nivel de escape.
7. Recién entonces: `kyverno apply` → `kyverno test` → dry run del lado del servidor.

---

## Referencias

**Currículum y certificación**

- Currículum KCA (CNCF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- Repositorio de currículum de CNCF — https://github.com/cncf/curriculum
- Página del programa Kyverno Certified Associate (KCA) — https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/

**Kyverno CLI**

- Panorama de la CLI de Kyverno — https://kyverno.io/docs/kyverno-cli/
- Referencia del comando `kyverno jp` — https://kyverno.io/docs/kyverno-cli/usage/jp/
- `kyverno apply` — https://kyverno.io/docs/kyverno-cli/usage/apply/
- `kyverno test` — https://kyverno.io/docs/kyverno-cli/usage/test/
- Instalación de la CLI — https://kyverno.io/docs/kyverno-cli/install/

**JMESPath en Kyverno**

- JMESPath en Kyverno (catálogo de funciones personalizadas) — https://kyverno.io/docs/writing-policies/jmespath/
- Variables y el contexto de la política — https://kyverno.io/docs/writing-policies/variables/
- Fuentes de datos externas: `configMap`, `apiCall`, `imageRegistry`, `variable`, `globalReference` — https://kyverno.io/docs/writing-policies/external-data-sources/
- Preconditions — https://kyverno.io/docs/writing-policies/preconditions/
- Reglas validate y `deny.conditions` — https://kyverno.io/docs/writing-policies/validate/
- Reglas mutate — https://kyverno.io/docs/writing-policies/mutate/
- Implementación de funciones JMESPath de Kyverno (fuente de verdad para las firmas) — https://github.com/kyverno/kyverno/tree/main/pkg/engine/jmespath

**Lenguaje JMESPath**

- Especificación de JMESPath — https://jmespath.org/specification.html
- Tutorial y ejemplos de JMESPath — https://jmespath.org/tutorial.html
- JMESPath Community edition (el dialecto que Kyverno incrusta) — https://jmespath.site/
- `jmespath-community/go-jmespath` — https://github.com/jmespath-community/go-jmespath
- JMESPath Enhancement Proposals (JEPs) — https://github.com/jmespath-community/jmespath.spec/tree/main/jep

**Kubernetes**

- Control de admisión dinámico (timeouts del webhook, `failurePolicy`) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Cantidades de recursos — https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/quantity/
- `kubectl get --raw` y acceso a la API — https://kubernetes.io/docs/reference/using-api/api-concepts/