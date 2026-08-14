# KCA 3.3 — `kyverno jp`: Ejercicios guiados

**Dominio:** Kyverno CLI · **Peso del tema:** 3 % · **Requiere cluster:** no (cada paso, salvo los opcionales del Ejercicio 7, corre completamente offline)

`kyverno jp` es el banco de trabajo JMESPath de la CLI. No aplica, prueba ni valida políticas — eso lo hacen `kyverno apply` y `kyverno test`. Lo que hace es permitirte evaluar *la expresión exacta* que una política evaluará, contra *los datos exactos* que la política verá, sin un servidor de API, sin un webhook y sin esperar a que una regla falle en un cluster. En la práctica, aquí es donde se gasta o se ahorra el 90 % del tiempo de depuración de Kyverno.

El comando tiene tres subcomandos:

| Subcomando | Propósito |
|---|---|
| `kyverno jp function` | El catálogo de funciones — nombres, firmas, notas |
| `kyverno jp parse` | Imprime el Árbol de Sintaxis Abstracta (AST) de una expresión |
| `kyverno jp query` | Evalúa una expresión contra una entrada JSON/YAML |

Trabajá los ejercicios en orden; cada uno se apoya en los archivos creados por el anterior.

---

## Ejercicio 0 — Preparar el banco de trabajo

**Objetivo:** confirmar la CLI, entender la superficie de `jp` y crear los fixtures que usan todos los ejercicios posteriores.

1. Verificá que la CLI esté presente y anotá la versión — el catálogo de funciones crece con casi cada release:

```bash
$ kyverno version
Version: 1.13.4
Time: 2025-02-11T15:22:47Z
Git commit ID: main/....
```

2. Inspeccioná el árbol de subcomandos:

```bash
$ kyverno jp -h
```

3. Creá un directorio de trabajo y el fixture principal:

```bash
mkdir -p ~/kca-3.3/queries && cd ~/kca-3.3
```

```bash
cat > pod-good.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: checkout-api
  namespace: payments
  creationTimestamp: "2026-08-01T09:15:00Z"
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/version: 1.29.3
    tier: backend
  annotations:
    owner: platform-team
    scale.example.io/replicas: "3"
spec:
  serviceAccountName: checkout
  securityContext:
    runAsNonRoot: true
  initContainers:
  - name: migrate
    image: docker.io/library/busybox:1.36
    command: ["sh", "-c", "echo migrating"]
  containers:
  - name: api
    image: registry.example.io/payments/checkout:1.29.3
    ports:
    - containerPort: 8080
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
  - name: metrics
    image: registry.example.io/observability/exporter:0.14.0
    ports:
    - containerPort: 9090
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
EOF
```

4. Hacé una prueba rápida (smoke-test) del evaluador:

```bash
$ kyverno jp query -i pod-good.yaml 'metadata.name'
"checkout-api"
```

**Comprobá tu comprensión**

- **Q0.1** — `jp query` aceptó un archivo YAML y, sin embargo, imprimió `"checkout-api"` con comillas. ¿Cuáles son los formatos de entrada y de salida de este comando, y por qué difieren?
- **Q0.2** — Nada en este ejercicio contactó a un cluster. ¿Qué variables de Kyverno *nunca* podrán, por lo tanto, resolverse con `jp query`, y qué debés hacer para trabajar con ellas?
- **Q0.3** — ¿Por qué una respuesta específica del tema como "`base64_decode` toma un string" es menos confiable que un comando? ¿Qué comando la reemplaza?

---

## Ejercicio 1 — `kyverno jp function`: el vocabulario

**Objetivo:** aprender a descubrir el conjunto de funciones en lugar de memorizarlo.

1. Imprimí el catálogo completo y contalo:

```bash
$ kyverno jp function | wc -l
```

2. Buscá una sola función:

```bash
$ kyverno jp function base64_decode
Name:      base64_decode
Signature: base64_decode(string) string
Note:      Decodes a base64 string
```

(El formato exacto del bloque varía entre releases — la línea que importa es `Signature`.)

3. Buscá varias a la vez, e incluí una que sea un built-in *estándar* de JMESPath en lugar de un filtro de Kyverno:

```bash
$ kyverno jp function to_upper semver_compare length
```

4. Pedí algo que no existe:

```bash
$ kyverno jp function totally_not_a_function
$ echo $?
```

5. Encontrá todas las funciones que tratan con el tiempo:

```bash
$ kyverno jp function | grep -i '^time'
```

**Comprobá tu comprensión**

- **Q1.1** — ¿Se resolvió `length` en el paso 3? ¿Qué te dice eso sobre cómo Kyverno ensambla su intérprete de JMESPath?
- **Q1.2** — Dos ingenieros discrepan sobre si `semver_compare('1.29.3', '>=1.30.0')` devuelve un booleano o un entero. ¿Qué único comando lo resuelve, y por qué leer el sitio web de Kyverno es una peor respuesta?
- **Q1.3** — Una política que funcionaba en un cluster Kyverno 1.14 falla en un cluster 1.9 con `function not found`. ¿Cómo te permite `jp function` confirmar el diagnóstico en segundos en cada lado?

---

## Ejercicio 2 — `kyverno jp query`: navegar un objeto real

**Objetivo:** los patrones de acceso principales — campos, proyecciones, filtros, multiselects — contra un manifiesto que reconocerás en un escenario de examen.

1. Escalares, con comillas y sin comillas:

```bash
$ kyverno jp query -i pod-good.yaml 'metadata.namespace'
"payments"

$ kyverno jp query -i pod-good.yaml -u 'metadata.namespace'
payments
```

2. Una proyección de lista:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[].image'
[
  "registry.example.io/payments/checkout:1.29.3",
  "registry.example.io/observability/exporter:0.14.0"
]
```

3. Compará el operador de aplanado (flatten) con el comodín (wildcard), luego contá:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[*].name'
$ kyverno jp query -i pod-good.yaml 'length(spec.containers)'
2
```

4. Una proyección de filtro — containers que **no** descartan todas las capabilities:

```bash
$ kyverno jp query -i pod-good.yaml "spec.containers[?securityContext.capabilities.drop == null].name"
[
  "metrics"
]
```

5. Un multiselect hash — construí un objeto de reporte compacto:

```bash
$ kyverno jp query -i pod-good.yaml "{pod: metadata.name, images: spec.containers[].image, replicas: metadata.annotations.\"scale.example.io/replicas\"}"
```

6. Lo mismo, legible por máquina:

```bash
$ kyverno jp query -c -i pod-good.yaml "{pod: metadata.name, n: length(spec.containers)}"
{"n":2,"pod":"checkout-api"}
```

7. Pedí algo que no está:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[0].livenessProbe.httpGet.path'
null
$ echo $?
0
```

**Comprobá tu comprensión**

- **Q2.1** — En el paso 4, el container `api` tiene `capabilities.drop`, y el container `metrics` no tiene `securityContext` en absoluto. ¿Por qué el filtro se evalúa igualmente sin problemas en lugar de fallar por la clave intermedia faltante?
- **Q2.2** — En el paso 6 pediste `{pod: ..., n: ...}` y obtuviste `{"n":..., "pod":...}`. ¿Por qué cambió el orden de las claves, y qué implica eso para scripts que parsean la salida de `jp query` por posición?
- **Q2.3** — El paso 7 devolvió `null` con código de salida `0`. ¿Por qué esa combinación es el resultado más peligroso de todo este tema cuando estás depurando una política que "pasa"?

---

## Ejercicio 3 — Comillas en el shell: la trampa que más tiempo cuesta

**Objetivo:** internalizar la colisión a tres bandas entre los literales de JMESPath, los raw strings de JMESPath y el shell.

JMESPath tiene dos formas de literal, y cada una colisiona con una regla de comillas distinta del shell:

| Construcción JMESPath | Sintaxis | Colisiona con |
|---|---|---|
| Literal JSON (números, booleanos, objetos) | `` `3` ``, `` `true` `` | backticks = sustitución de comandos dentro de `"…"` |
| Literal de raw string | `'nginx'` | comillas simples = comillas del shell |
| Identificador entrecomillado (claves con `.`, `/`, `-`) | `"app.kubernetes.io/name"` | comillas dobles = comillas del shell |

1. Solo literal → envolvé el argumento del shell en comillas **simples** (las comillas simples protegen los backticks):

```bash
$ kyverno jp query -i pod-good.yaml 'length(spec.containers) == `2`'
true
```

2. Solo raw string → envolvé el argumento del shell en comillas **dobles**:

```bash
$ kyverno jp query -i pod-good.yaml "spec.containers[?name == 'api'].image"
[
  "registry.example.io/payments/checkout:1.29.3"
]
```

3. Identificador entrecomillado + literal, sin raw string → las comillas simples siguen funcionando:

```bash
$ kyverno jp query -i pod-good.yaml 'to_number(metadata.annotations."scale.example.io/replicas") > `2`'
true
```

4. Ahora quitá `to_number` y observá cómo una comparación se rinde silenciosamente:

```bash
$ kyverno jp query -i pod-good.yaml 'metadata.annotations."scale.example.io/replicas" > `2`'
null
```

5. Un raw string *y* un literal en una misma expresión — escapá los backticks dentro de las comillas dobles:

```bash
$ kyverno jp query -i pod-good.yaml "length(spec.containers[?starts_with(name, 'a')]) == \`1\`"
true
```

6. La alternativa mantenible — ponelo en un archivo y usá `-q`:

```bash
cat > queries/one-a-container.jmespath <<'EOF'
length(spec.containers[?starts_with(name, 'a')]) == `1`
EOF
```

```bash
$ kyverno jp query -i pod-good.yaml -q queries/one-a-container.jmespath
true
```

7. Rompelo deliberadamente y leé los diagnósticos:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers['
$ echo $?
```

**Comprobá tu comprensión**

- **Q3.1** — El paso 4 devolvió `null`, no `false` ni un error. Enunciá la regla de JMESPath que produce esto, y explicá por qué una condición `deny` de Kyverno construida sobre ella estaría silenciosamente equivocada.
- **Q3.2** — Necesitás probar `regex_match('^gcr\.io/.*$', spec.containers[0].image)` desde un shell bash interactivo. Nombrá los dos caracteres que hacen peligroso el entrecomillado inline aquí, y dá la forma recomendada de ejecutarlo.
- **Q3.3** — Más allá de las comillas, nombrá dos razones operativas para mantener las expresiones en archivos `-q` en lugar del historial del shell.

---

## Ejercicio 4 — Proyecciones, pipes y alcance: la semántica que decide la corrección

**Objetivo:** entender *por qué* una expresión que se ve correcta devuelve `[]`.

1. Dos expresiones que difieren en un pipe:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[*].name[0]'
[]

$ kyverno jp query -i pod-good.yaml 'spec.containers[*].name | [0]'
"api"
```

2. Confirmá las formas con el AST:

```bash
$ kyverno jp parse 'spec.containers[*].name[0]'
$ kyverno jp parse 'spec.containers[*].name | [0]'
```

Salida representativa de una subexpresión (el formato difiere levemente entre releases):

```
ASTSubexpression {
  children: {
    ASTField {
      value: "spec"
    }
    ASTField {
      value: "containers"
    }
  }
}
```

3. Mostrá que un pipe reinicia el nodo actual:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.containers[].image | metadata.name'
null
```

4. Recolectá *todas* las imágenes de containers — el idiom que usan las políticas de Kyverno, porque `containers` por sí solo es una comprobación de seguridad incompleta:

```bash
$ kyverno jp query -i pod-good.yaml 'spec.[containers, initContainers, ephemeralContainers][].image'
[
  "docker.io/library/busybox:1.36",
  "registry.example.io/payments/checkout:1.29.3",
  "registry.example.io/observability/exporter:0.14.0"
]
```

5. Filtrá esa lista aplanada — fijate en el pipe, sin el cual el filtro se aplicaría *dentro* de la proyección:

```bash
$ kyverno jp query -i pod-good.yaml "spec.[containers, initContainers, ephemeralContainers][].image | [?starts_with(@, 'registry.example.io')]"
[
  "registry.example.io/payments/checkout:1.29.3",
  "registry.example.io/observability/exporter:0.14.0"
]
```

6. Inspeccioná la precedencia de operadores sin discutir sobre ella:

```bash
$ kyverno jp parse 'a || b && c'
$ kyverno jp parse 'a || b | c'
```

**Comprobá tu comprensión**

- **Q4.1** — Explicá, paso a paso, por qué `spec.containers[*].name[0]` se evalúa como `[]`.
- **Q4.2** — En el paso 4 el pod no tiene `ephemeralContainers`. Rastreá qué hacen la lista multiselect y el operador de aplanado con esa clave faltante, y por qué el resultado final tiene igualmente exactamente tres strings.
- **Q4.3** — A partir de los ASTs del paso 6, ordená `||`, `&&` y `|` por fuerza de ligado (binding), y dá la forma del árbol resultante para `a || b && c`.
- **Q4.4** — La política de imágenes de un colega solo comprueba `spec.containers[].image`. ¿Qué dos características de workload permiten a un atacante o a un desarrollador descuidado saltearla por completo?

---

## Ejercicio 5 — Los filtros propios de Kyverno

**Objetivo:** ejercitar los filtros que existen *solo* en el intérprete de Kyverno — la razón por la que `jp` existe como herramienta separada en lugar de una CLI de JMESPath genérica.

1. Manipulación de strings:

```bash
$ kyverno jp query -u "to_upper('kyverno')"
KYVERNO

$ kyverno jp query "split('registry.example.io/payments/checkout', '/')"
[
  "registry.example.io",
  "payments",
  "checkout"
]

$ kyverno jp query -u "truncate('kubernetes-is-verbose', \`10\`)"
kubernetes
```

2. Dos matchers distintos — regex y el patrón wildcard de Kyverno. Usá archivos de query, porque ambos necesitan raw strings y uno necesita anclas:

```bash
cat > queries/regex.jmespath <<'EOF'
regex_match('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$', metadata.name)
EOF
cat > queries/pattern.jmespath <<'EOF'
pattern_match('registry.example.io/*', spec.containers[0].image)
EOF
```

```bash
$ kyverno jp query -i pod-good.yaml -q queries/regex.jmespath
true
$ kyverno jp query -i pod-good.yaml -q queries/pattern.jmespath
true
```

3. Restricciones de versión:

```bash
$ kyverno jp query -i pod-good.yaml "semver_compare(metadata.labels.\"app.kubernetes.io/version\", '>=1.28.0')"
true
$ kyverno jp query -i pod-good.yaml "semver_compare(metadata.labels.\"app.kubernetes.io/version\", '>=1.30.0')"
false
```

4. Aritmética sobre cantidades de Kubernetes y duraciones de Go — algo que el JMESPath simple no puede hacer:

```bash
$ kyverno jp query "add('12Ki', '2Ki')"
"14Ki"
$ kyverno jp query 'divide(`10`, `4`)'
2.5
$ kyverno jp query 'modulo(`10`, `3`)'
1
```

5. Codificación y parseo — el patrón usado para leer datos estructurados desde un context de ConfigMap:

```bash
$ kyverno jp query -u "base64_decode('SGVsbG8sIEt5dmVybm8h')"
Hello, Kyverno!

$ kyverno jp query "parse_json('{\"limits\":{\"maxReplicas\":5}}').limits.maxReplicas"
5
```

6. Convertir un map en una lista iterable — el prerrequisito para `foreach` sobre labels o annotations:

```bash
$ kyverno jp query -i pod-good.yaml "sort_by(items(metadata.labels, 'key', 'value'), &key)"
[
  {
    "key": "app.kubernetes.io/name",
    "value": "checkout"
  },
  {
    "key": "app.kubernetes.io/version",
    "value": "1.29.3"
  },
  {
    "key": "tier",
    "value": "backend"
  }
]
```

7. Tiempo. El fixture se creó el `2026-08-01T09:15:00Z`:

```bash
$ kyverno jp query -i pod-good.yaml "time_since('', metadata.creationTimestamp, '2026-08-13T09:15:00Z')"
"288h0m0s"

$ kyverno jp query -i pod-good.yaml "time_before(metadata.creationTimestamp, '2026-08-10T00:00:00Z')"
true
```

8. Ahora corré una no determinista dos veces:

```bash
$ kyverno jp query "random('[0-9a-z]{5}')"
$ kyverno jp query "random('[0-9a-z]{5}')"
```

9. *(Avanzado, opcional)* Introspección de certificados:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
  -subj "/CN=kyverno-demo" -days 30 -out /tmp/demo.pem 2>/dev/null
{ echo 'cert: |'; sed 's/^/  /' /tmp/demo.pem; } > cert.yaml
```

```bash
$ kyverno jp query -i cert.yaml -u 'x509_decode(cert).Subject.CommonName'
kyverno-demo

$ kyverno jp query -i cert.yaml 'x509_decode(cert).subject.commonName'
null
```

**Comprobá tu comprensión**

- **Q5.1** — El JMESPath estándar no tiene noción de `12Ki`. ¿Qué deben hacer `add`/`subtract`/`sum` con sus argumentos string antes de operar, y qué dos casos de uso de políticas de Kubernetes desbloquea esto?
- **Q5.2** — Tanto `regex_match` como `pattern_match` devolvieron `true`. ¿Cuál es la diferencia en su lenguaje de coincidencia, y cuál es seguro entregar a un equipo de aplicación que no escribe expresiones regulares?
- **Q5.3** — En el paso 6, ¿por qué el ejercicio envolvió `items(...)` en `sort_by(..., &key)`? ¿Qué hace el `&`?
- **Q5.4** — El paso 8 da una respuesta distinta en cada corrida, y `time_now()` se comporta igual. ¿Qué significa eso para una regla de mutación que las usa, y para reproducir una decisión de política a posteriori?
- **Q5.5** — El segundo comando del paso 9 devolvió `null`. Dá la razón precisa, y enunciá la regla general que ilustra sobre la salida de `x509_decode`.

---

## Ejercicio 6 — Depurar una política como lo harías en producción

**Objetivo:** el bucle por el que existe este tema — sacar una expresión de una política, alimentarla con los datos que le pasaría admission, y encontrar el bug offline.

1. Escribí la política bajo investigación. Se supone que exige que toda imagen provenga de `registry.example.io`, y nunca deniega nada:

```bash
cat > require-registry.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-approved-registry
spec:
  validationFailureAction: Enforce
  background: false
  rules:
  - name: approved-registry-only
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "All images must come from registry.example.io"
      deny:
        conditions:
          all:
          - key: "{{ request.object.spec.containers[].image | contains(@, 'registry.example.io') }}"
            operator: Equals
            value: false
EOF
```

2. Reconstruí los datos que ve la regla. Construí el envoltorio `request` con el propio `jp` — sin necesidad de herramientas extra:

```bash
$ kyverno jp query -i pod-good.yaml \
  "{request: {operation: 'CREATE', userInfo: {username: 'system:serviceaccount:ci:deployer'}, object: @}}" \
  > admission.json

$ kyverno jp query -i admission.json -u 'request.object.metadata.name'
checkout-api
```

3. Evaluá la expresión de la regla de forma literal — todo lo que está entre las `{{ }}`:

```bash
$ kyverno jp query -i admission.json "request.object.spec.containers[].image | contains(@, 'registry.example.io')"
false
```

4. Aislá el operando y la función por separado:

```bash
$ kyverno jp query -i admission.json 'request.object.spec.containers[].image'
$ kyverno jp query "contains(['a/b', 'a/c'], 'a')"
$ kyverno jp query "contains('a/b/c', 'a/b')"
```

5. Escribí la expresión corregida en un archivo de query:

```bash
cat > queries/approved-registry.jmespath <<'EOF'
length(request.object.spec.[containers, initContainers, ephemeralContainers][].image) ==
length(request.object.spec.[containers, initContainers, ephemeralContainers][].image | [?starts_with(@, 'registry.example.io')])
EOF
```

```bash
$ kyverno jp query -i admission.json -q queries/approved-registry.jmespath
false
```

6. Averiguá *cuál* imagen es la culpable:

```bash
$ kyverno jp query -i admission.json "request.object.spec.[containers, initContainers, ephemeralContainers][].image | [?!starts_with(@, 'registry.example.io')]"
[
  "docker.io/library/busybox:1.36"
]
```

7. Producí un fixture que pase y volvé a correr, para haber probado ambas ramas:

```bash
sed 's|docker.io/library/busybox:1.36|registry.example.io/base/busybox:1.36|' pod-good.yaml > pod-fixed.yaml
kyverno jp query -i pod-fixed.yaml \
  "{request: {operation: 'CREATE', object: @}}" > admission-fixed.json
```

```bash
$ kyverno jp query -i admission-fixed.json -q queries/approved-registry.jmespath
true
```

**Comprobá tu comprensión**

- **Q6.1** — Enunciá exactamente por qué la expresión original devolvió `false` para un pod cuyas imágenes principales *sí* coinciden. ¿Qué hace `contains` cuando su primer argumento es un array?
- **Q6.2** — Incluso después de arreglar `contains`, la regla original habría seguido estando mal de una segunda forma, independiente. ¿Cuál era, y qué paso de este ejercicio la expuso?
- **Q6.3** — El paso 2 construyó el envoltorio `request` con un multiselect hash. ¿Qué dos variables de Kyverno usadas comúnmente en políticas siguen sin poder reproducirse de esta manera, y cómo las proveerías?
- **Q6.4** — La expresión corregida devuelve `true` cuando el pod cumple, pero el bloque `deny.conditions` de la política compara contra `false`. Explicá por qué eso es correcto y no está invertido.

---

## Ejercicio 7 — Integrar `jp` en un flujo de trabajo

**Objetivo:** usar `jp` como un componente — en un pipeline de shell, contra objetos vivos y en CI.

1. Stdin en lugar de `-i`:

```bash
$ cat pod-good.yaml | kyverno jp query 'metadata.name'
"checkout-api"
```

2. Capturá un valor en una variable de shell — para esto sirve `-u`:

```bash
$ IMG=$(kyverno jp query -u -i pod-good.yaml 'spec.containers[0].image')
$ echo "$IMG"
registry.example.io/payments/checkout:1.29.3
```

Compará con el mismo comando sin `-u`, y fijate en los caracteres `"` literales que terminan dentro de `$IMG`.

3. *(Opcional — requiere un cluster)* Consultá un objeto vivo:

```bash
$ kubectl run probe --image=registry.example.io/base/busybox:1.36 --restart=Never --dry-run=client -o json \
  | kyverno jp query 'spec.containers[].image'
```

```bash
$ kubectl get pods -A -o json \
  | kyverno jp query -c "items[?!starts_with(spec.containers[0].image, 'registry.example.io')].{ns: metadata.namespace, name: metadata.name}"
```

4. Un gate de CI. `jp query` sale con un código distinto de cero ante un error de sintaxis o de evaluación, pero un resultado *false* sigue siendo una corrida exitosa, así que debés comprobar el valor:

```bash
cat > gate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
result=$(kyverno jp query -u -i "$1" -q queries/approved-registry.jmespath)
if [[ "$result" != "true" ]]; then
  echo "FAIL: $1 uses images outside registry.example.io" >&2
  kyverno jp query -i "$1" "spec.[containers, initContainers, ephemeralContainers][].image | [?!starts_with(@, 'registry.example.io')]" >&2
  exit 1
fi
echo "OK: $1"
EOF
chmod +x gate.sh
```

5. Notá que el archivo de query del Ejercicio 6 espera una forma de AdmissionReview. Adaptalo para manifiestos desnudos y corré el gate sobre ambos fixtures:

```bash
sed 's/request\.object\.//g' queries/approved-registry.jmespath > queries/approved-registry-bare.jmespath
sed -i 's|queries/approved-registry.jmespath|queries/approved-registry-bare.jmespath|' gate.sh
```

```bash
$ ./gate.sh pod-fixed.yaml
OK: pod-fixed.yaml
$ ./gate.sh pod-good.yaml
FAIL: pod-good.yaml uses images outside registry.example.io
[
  "docker.io/library/busybox:1.36"
]
$ echo $?
1
```

**Comprobá tu comprensión**

- **Q7.1** — ¿Por qué el script del gate compara la salida con el string `true` en lugar de basarse solo en el código de salida?
- **Q7.2** — En el paso 5 tuviste que quitar `request.object.` de la query. ¿Qué te dice esto sobre reutilizar una misma expresión tanto para la depuración en tiempo de admission como para el linting estático de manifiestos, y cómo evitarías el `sed` en un repositorio real?
- **Q7.3** — `kyverno test` también corre offline en CI. ¿Qué te da `jp query` que `kyverno test` no da, y en qué punto de la escritura de una política usás cada uno?

---

## Referencia rápida

```bash
kyverno jp function                       # full catalogue
kyverno jp function NAME [NAME...]        # signature + note
kyverno jp parse 'EXPR'                   # AST; settles precedence and projection questions
kyverno jp parse -f FILE                  # AST from a file
kyverno jp query -i INPUT 'EXPR'          # evaluate against JSON/YAML
kyverno jp query -q FILE -i INPUT         # expression from a file (use this for anything non-trivial)
cat obj.json | kyverno jp query 'EXPR'    # input from stdin
  -u / --unquoted                         # print bare strings (for shell capture)
  -c / --compact                          # single-line JSON (for machine consumption)
```

Regla general para las comillas:

| La expresión contiene | Envoltura del shell |
|---|---|
| `` `literals` `` y/o `"quoted.identifiers"` | `'single quotes'` |
| solo `'raw strings'` | `"double quotes"` |
| ambos, o regexes con `$` | `-q query file` |

Familias de filtros propios en las que ser fluido (confirmá siempre las firmas con `kyverno jp function NAME` en *tu* versión): string (`to_upper`, `to_lower`, `trim`, `trim_prefix`, `split`, `replace`, `replace_all`, `truncate`, `compare`, `equal_fold`), matching (`regex_match`, `pattern_match`, `regex_replace_all`, `label_match`), aritmética (`add`, `subtract`, `multiply`, `divide`, `modulo`, `round`, `sum`), conversión (`to_boolean`, `parse_json`, `parse_yaml`, `base64_encode`, `base64_decode`, `items`, `object_from_lists`, `path_canonicalize`), versionado (`semver_compare`), tiempo (`time_since`, `time_now`, `time_now_utc`, `time_add`, `time_parse`, `time_utc`, `time_before`, `time_after`, `time_truncate`, `time_to_cron`), y seguridad (`x509_decode`, `random`).

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A0.1** — La entrada es JSON *o* YAML; `jp query` deserializa el YAML al mismo modelo de datos genérico sobre el que opera JMESPath. La salida siempre es JSON, porque el resultado de una expresión es un valor JSON, y JSON es lo que consume una herramienta posterior (o la propia sustitución de variables de Kyverno). Por eso un resultado de tipo string aparece con sus comillas; `-u` las quita, pero solo cuando el resultado realmente es un string.

**A0.2** — Cualquier cosa proveniente de un `context` en tiempo de admission: búsquedas de `configmap`, resultados de `apiCall`, datos de `imageRegistry`, entradas de `globalReference`, y los campos `serviceAccountName`/`userInfo` que vienen del AdmissionRequest en lugar del objeto. `jp` evalúa expresiones contra datos que vos le entregás, así que debés reconstruir esos datos por tu cuenta — volcá el ConfigMap o la respuesta de la API en tu archivo de entrada bajo la misma clave a la que la política los liga en su `context`, luego evaluá la expresión sin cambios.

**A0.3** — El catálogo de funciones es específico de cada release: se agregan filtros (y ocasionalmente cambian de firma) a lo largo de las versiones de Kyverno, así que cualquier lista escrita es una instantánea de una versión. `kyverno jp function NAME` informa lo que ejecutará el binario que realmente estás corriendo — que tiene la misma semántica de binario que el controlador de Kyverno de la versión correspondiente.

### Ejercicio 1

**A1.1** — Sí, `length` se resuelve. Kyverno no corre un conjunto de funciones "solo de Kyverno" junto a JMESPath; construye un único intérprete de JMESPath y registra sus filtros propios en la única tabla de funciones de ese intérprete. `jp function` recorre esa tabla, así que los built-ins y los filtros propios aparecen juntos — que es también por qué una expresión de Kyverno puede mezclar libremente `length`, `sort_by` y `semver_compare` en una sola línea.

**A1.2** — `kyverno jp function semver_compare`, que imprime la firma (`semver_compare(string, string) bool`). El sitio web documenta la versión con la que se construyó la documentación; tu cluster corre una versión específica, y ambas se desincronizan. El binario es la fuente de verdad para el binario.

**A1.3** — Corré `kyverno jp function <name>` con cada versión de la CLI (o hacé `kubectl exec` dentro de la imagen del controlador respectivo). Una entrada faltante del lado más viejo confirma que la expresión depende de un filtro que esa versión no tiene — el arreglo es o bien una subida de versión o bien una expresión reescrita en términos de filtros que ambas versiones provean.

### Ejercicio 2

**A2.1** — JMESPath propaga la ausencia como `null` en lugar de lanzar un error. `securityContext` falta en `metrics`, así que `securityContext.capabilities` se evalúa como `null`, y `null.drop` es de nuevo `null`. La comparación `null == null` es `true`, así que el container queda seleccionado. Esta "navegación null-safe" es la razón por la que los filtros sobre objetos heterogéneos de Kubernetes funcionan en absoluto — y por la que pueden seleccionar silenciosamente más de lo que pretendías.

**A2.2** — Un multiselect hash produce un map, que es serializado por el codificador JSON de Go; ese codificador ordena las claves del map alfabéticamente. Por lo tanto, el orden de las claves de salida es alfabético, no el orden del origen, y ningún consumidor debe depender del orden posicional — parseá por clave (`jq '.pod'`) o usá `-u` con una única expresión escalar.

**A2.3** — Porque `null` es indistinguible de "la comprobación pasó" en un contexto booleano posterior, y el código de salida no te da ninguna advertencia. Un error de tipeo en una ruta de campo, un entrecomillado incorrecto de una clave con puntos, o una proyección que se colapsó a nada, todos producen `null` con exit 0. En una política esto se convierte en una regla que no coincide con nada y no deniega nada — un dashboard verde que encubre un control no aplicado. Tratá un `null` de `jp query` como "probá que esto es intencional", nunca como una aprobación.

### Ejercicio 3

**A3.1** — Para los operadores de orden (`<`, `<=`, `>`, `>=`), la especificación de JMESPath dice que si alguno de los operandos no es un número, el resultado es `null` — no `false`, y no un error. Los valores de las annotations son siempre strings en Kubernetes, así que la comparación nunca produce un booleano. Una condición `deny` que compara ese `null` contra `true`/`false` nunca se dispara, así que la regla es inerte mientras sigue apareciendo en el reporte de la política como configurada. El arreglo es `to_number(...)` sobre la annotation antes de comparar.

**A3.2** — La barra invertida (`\.` en el regex, que bash puede consumir dentro de comillas dobles) y `$` (expansión de parámetros dentro de comillas dobles; las referencias de captura tipo `$1` en `regex_replace_all` tienen el mismo problema). Los regexes anclados también necesitan `^`/`$` intactos. Poné la expresión en un archivo y corré `kyverno jp query -i input.yaml -q queries/regex.jmespath`, donde no se aplica ningún entrecomillado del shell en absoluto.

**A3.3** — (1) La expresión se vuelve revisable y comparable (diffable): vive en git junto a la política, así que un cambio en una condición relevante para la seguridad pasa por code review. (2) Es reutilizable por CI sin volver a entrecomillar, eliminando la clase de bug donde la expresión probada localmente difiere en un carácter escapado de la que corre en el pipeline. (Una tercera: el texto idéntico puede pegarse en las `{{ }}` de la política sin desescaparlo.)

### Ejercicio 4

**A4.1** — `spec.containers[*]` inicia una proyección: todo lo que está a su derecha se aplica a cada elemento y los resultados se recolectan. `.name` produce un string por container. `[0]` es una expresión de índice, e indexar un *string* (un no-array) produce `null` en JMESPath. Las proyecciones descartan los resultados `null`, así que ambos elementos se caen y la lista recolectada queda vacía: `[]`. Agregar `| [0]` primero termina la proyección — el lado izquierdo del pipe se evalúa como la lista completa `["api","metrics"]` — y recién entonces se aplica `[0]` a esa lista.

**A4.2** — La lista multiselect `spec.[containers, initContainers, ephemeralContainers]` evalúa cada expresión contra `spec`; el `ephemeralContainers` faltante se vuelve `null`, dando `[[api, metrics], [migrate], null]`. El operador de aplanado `[]` fusiona todo elemento que sea un array y conserva todo elemento que no lo sea, produciendo `[api, metrics, migrate, null]`. El `.image` final es una proyección sobre esa lista: tres objetos container producen tres strings, y `null.image` produce `null`, que la proyección descarta. Quedan tres strings.

**A4.3** — `&&` liga más fuerte, luego `||`, luego `|` (el pipe es el operador de menor precedencia en JMESPath). Por lo tanto, `a || b && c` se parsea como `ASTOrExpression{ ASTField(a), ASTAndExpression{ ASTField(b), ASTField(c) } }` — es decir, `a || (b && c)`. `a || b | c` se parsea como `ASTPipe{ ASTOrExpression{a, b}, c }`.

**A4.4** — `initContainers` y `ephemeralContainers`. Un init container corre con el mismo acceso a los volúmenes y (a menos que se restrinja por separado) la misma libertad de registry, y un ephemeral container puede inyectarse en un pod en ejecución vía `kubectl debug`. Cualquier regla de imagen, capability o registry que enumere solo `spec.containers` es saltéable por cualquiera de los dos. El idiom `spec.[containers, initContainers, ephemeralContainers][]` existe precisamente para esto.

### Ejercicio 5

**A5.1** — Primero parsean cada argumento string a un valor tipado: una `resource.Quantity` de Kubernetes (`12Ki`, `250m`, `2Gi`) o una `time.Duration` de Go (`12h`, `30m`), recurriendo por defecto a un número simple. La aritmética ocurre sobre el valor tipado y el resultado se vuelve a serializar en la misma forma. Esto desbloquea (1) la gobernanza de recursos — sumar los requests/limits de los containers y comparar el total contra un presupuesto de namespace, y (2) la aritmética de tiempo/duración — calcular ventanas de expiración y períodos de gracia dentro de una regla.

**A5.2** — `regex_match` toma una expresión regular completa (sintaxis RE2: anclas, clases de caracteres, cuantificadores, alternación, grupos de captura). `pattern_match` toma el lenguaje de patrones wildcard mucho más pequeño de Kyverno — esencialmente `*` para "cualquier secuencia" y `?` para "cualquier carácter individual" — la misma coincidencia usada en los bloques `match`/`exclude` de Kyverno. Entregá `pattern_match` a los equipos de aplicación: no tiene modos de falla de backtracking catastrófico ni de anclaje accidental, y un error en él sub-coincide de forma visible en lugar de sobre-coincidir silenciosamente.

**A5.3** — `items()` convierte un map en una lista de objetos clave/valor, y el orden de iteración de un map no es algo en lo que debas confiar; ordenar hace que la salida sea estable para que los diffs, los tests y los golden files no fluctúen. El `&` crea una *referencia de expresión* — pasa la expresión `key` a `sort_by` como un valor a evaluar una vez por elemento, en lugar de evaluarla inmediatamente en el alcance actual. `sort_by`, `max_by`, `min_by` y `map` toman una.

**A5.4** — Una regla de mutación que usa `random()` o `time_now()` produce un resultado distinto en cada evaluación, así que no es idempotente: volver a correrla (un escaneo en segundo plano, una re-admission al actualizar, una llamada de webhook reintentada) puede seguir cambiando el objeto, y dos evaluaciones de la misma entrada no son comparables. También significa que una decisión de política no puede reproducirse a posteriori solo a partir del objeto — debés haber capturado el valor en el momento. Confiná estas funciones a mutaciones genuinamente de una sola vez (generar un sufijo de nombre en CREATE) y nunca las uses en condiciones `validate`.

**A5.5** — `x509_decode` devuelve el certificado serializado (marshalled) a partir de las estructuras `crypto/x509` de Go, así que los nombres de los campos son los nombres exportados y capitalizados de Go: `Subject`, `Issuer`, `NotBefore`, `NotAfter`, `SerialNumber`, `DNSNames`. Los identificadores de JMESPath distinguen mayúsculas de minúsculas, así que `subject.commonName` no coincide con nada y la navegación null-safe devuelve `null` en lugar de fallar. La regla general: nunca adivines la forma de la salida de una función — imprimí el objeto completo (`x509_decode(cert)`) una vez, luego escribí la ruta contra lo que realmente ves.

### Ejercicio 6

**A6.1** — `contains` está sobrecargado. Cuando el primer argumento es un *string*, comprueba una subcadena; cuando es un *array*, comprueba la **pertenencia por igualdad exacta**. `request.object.spec.containers[].image` es un array, así que la expresión preguntó "¿es el string exacto `registry.example.io` uno de los elementos?" — ningún elemento es igual a él, así que la respuesta es `false`. Las imágenes solo *empiezan con* él. El operador correcto para una prueba de prefijo sobre cada elemento es `starts_with(@, '…')` dentro de un filtro, aplicado después de que un pipe termina la proyección.

**A6.2** — Solo inspeccionó `spec.containers`, así que el init container `docker.io/library/busybox:1.36` nunca fue examinado. El paso 6 lo expuso: la expresión corregida, extendida a `spec.[containers, initContainers, ephemeralContainers][]`, devuelve `false` para un pod cuyos dos containers ordinarios cumplen completamente, y el filtro de diagnóstico nombra la imagen infractora. Dos bugs independientes — una función incorrecta y una ruta de campo incompleta — dieron la casualidad de cancelarse en el mismo síntoma de "la política nunca deniega nada".

**A6.3** — Cualquier cosa que Kyverno resuelva desde un `context` (`configMap`, `apiCall`, `imageRegistry`, `globalReference`) y los metadatos de imagen bajo `images.containers.<name>` que la maquinaria de verificación de imágenes puebla. Las proveés agregando las mismas claves a tu documento de entrada bajo los nombres que liga el `context` — por ejemplo, volcá el `.data` del ConfigMap en una clave de nivel superior que coincida con el `name` de la entrada del context, luego evaluá la expresión sin cambios.

**A6.4** — La condición es una condición *deny*: se dispara cuando el conjunto de condiciones se satisface. La expresión afirma "todas las imágenes están aprobadas"; la regla deniega cuando eso es igual a `false`, es decir, cuando al menos una imagen no está aprobada. Un pod que cumple evalúa la expresión como `true`, la condición `true Equals false` no se satisface, y la admission procede. Leer un bloque `deny` como si fuera un bloque `pattern` es una fuente frecuente de políticas invertidas — evaluá la expresión con `jp query` contra un fixture que cumple y otro que no cumple, como hace el paso 7, y confirmá ambas ramas antes de publicar.

### Ejercicio 7

**A7.1** — El código de salida y el valor del resultado responden preguntas distintas. `jp query` sale con un código distinto de cero cuando no pudo *evaluar* la expresión (error de sintaxis, archivo de entrada malo, error de tipo en una llamada a función); sale con cero siempre que la evaluación tuvo éxito — incluso cuando la respuesta es `false`, e incluso cuando la respuesta es `null`. Un gate que confía solo en el código de salida deja pasar todo manifiesto que no cumple y toda ruta de campo mal tipeada. Comparar el valor impreso con el literal `true` también rechaza `null`, que es exactamente el comportamiento que querés.

**A7.2** — La expresión está acoplada a la *forma* de su entrada, no solo a los campos que lee: en admission el objeto está anidado bajo `request.object`, mientras que un manifiesto en disco es el objeto mismo. En lugar de `sed`, normalizá la entrada en vez de la expresión — envolvé los manifiestos desnudos en la forma de admission una sola vez (`kyverno jp query -i pod.yaml "{request: {object: @}}"`, como en el paso 2 del Ejercicio 6) y mantené exactamente una copia de la expresión, la misma que también aparece dentro de las `{{ }}` de la política. Una expresión, un lugar para revisar, un lugar para arreglar.

**A7.3** — `kyverno test` prueba que una política completa produce los resultados esperados de pass/fail/skip para un conjunto de recursos; es la suite de regresión, y es lo que corrés en CI en cada cambio. `jp query` prueba a qué se evalúa una *única subexpresión* contra una entrada específica, que es lo que necesitás mientras la política sigue estando mal y todavía no sabés cuál de sus cinco cláusulas es la culpable. El orden en la práctica: `jp function` para encontrar el filtro, `jp parse` para confirmar que la expresión se parsea de la forma que pensás, `jp query` para confirmar que devuelve el valor que esperás sobre datos reales, luego pegala en la política y fijá el comportamiento con `kyverno test`.

</details>

---

## Fuentes

- CNCF Curriculum (KCA) — <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- Documentación de Kyverno — <https://kyverno.io/docs/>
- Kyverno CLI, comando `jp` — <https://kyverno.io/docs/kyverno-cli/usage/jp/>
- Filtros propios JMESPath de Kyverno — <https://kyverno.io/docs/writing-policies/jmespath/>
- Especificación de JMESPath (proyecciones, pipes, precedencia de operadores, semántica de comparación) — <https://jmespath.org/specification.html>
- Tutorial de JMESPath — <https://jmespath.org/tutorial.html>
- Código fuente de Kyverno — <https://github.com/kyverno/kyverno>
- Referencia de la API de Kubernetes, spec del Pod (`containers`, `initContainers`, `ephemeralContainers`) — <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/>