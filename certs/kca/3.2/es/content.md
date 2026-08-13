# KCA 3.2 — `kyverno test`

**Dominio 3 — Kyverno CLI · Peso en el examen 3.0 %**

> **Alcance.** Este tema cubre el subcomando `kyverno test`: el arnés de pruebas unitarias declarativo y sin clúster que ejecuta políticas contra recursos de fixture y afirma un resultado esperado por cada terna (policy, rule, resource). *No* cubre `kyverno apply` (evaluación ad‑hoc, sin aserciones — tema 3.1) ni las pruebas de clúster de extremo a extremo con Chainsaw.

---

## 1. El problema en producción

Una `ClusterPolicy` de Kyverno en modo `Enforce` es una **compuerta de admisión síncrona y de alcance de todo el clúster**. Su radio de impacto es toda la superficie de la API que coincida. Los dos modos de fallo son asimétricos y ambos son costosos:

| Modo de fallo | Mecanismo | Síntoma en producción |
|---|---|---|
| **Falso positivo** (coincidencia excesiva) | Bloque `match` demasiado amplio, falta `exclude`, interacción `autogen` olvidada | Cada despliegue de `Deployment` falla la admisión. `kubectl apply` devuelve `admission webhook "validate.kyverno.svc-fail.kyverno.svc" denied the request`. El autoescalado de nodos se atasca porque los pods de DaemonSet son rechazados. Caída total. |
| **Falso negativo** (coincidencia insuficiente) | Error de tipeo en una expresión JMESPath, `apiVersion` incorrecto en `match.resources.kinds`, una `precondition` que silenciosamente evalúa a `false` | El control reporta "0 violaciones" para siempre. El auditor ve un PolicyReport en verde. Nada se aplica en realidad. Silencioso, y solo se descubre a la hora de la auditoría. |

El segundo es peor. Una política que nunca coincide con nada no produce *ninguna señal en absoluto* — `kubectl get polr -A` no muestra nada, y un reporte vacío es indistinguible del cumplimiento total. Este es el defecto más común en los repositorios de policy‑as‑code.

La respuesta arquitectónica es una **pirámide de pruebas de políticas**, y `kyverno test` es su capa base:

```
                 ┌───────────────────────────┐
                 │  Chainsaw / real cluster  │  e2e: webhook wiring, background scans,
                 │  (minutes, needs a cluster)│  generate lifecycle, RBAC, reports
                 ├───────────────────────────┤
                 │  kyverno apply --cluster  │  integration: policy vs. live resources
                 │  (seconds, needs kubeconfig)│
                 ├───────────────────────────┤
                 │      kyverno test         │  UNIT: policy vs. fixture, asserted,
                 │  (milliseconds, no cluster)│  hermetic, runs in a PR check
                 └───────────────────────────┘
```

`kyverno test` enlaza con la **misma biblioteca de motor** (`pkg/engine`) que ejecuta el controlador de admisión. No es una reimplementación ni un linter — la semántica de evaluación es la semántica de producción, menos el servidor de API. Esa fidelidad es lo que hace que valga la pena usarlo como compuerta de los merges, y la §10 documenta exactamente dónde tiene fugas la parte del "menos el servidor de API".

---

## 2. Dónde encaja `test` — compensaciones comparativas

| Herramienta | Requiere clúster | Aserciones | Fidelidad del motor | Tiempo real típico | Trabajo adecuado |
|---|---|---|---|---|---|
| `kyverno apply` | No (opcional `--cluster`) | Ninguna — imprime un reporte, uno lo lee | Motor completo | ~100 ms | Exploración, "¿qué le hace esta política a este YAML?" |
| **`kyverno test`** | **No** | **Declarativa, por regla, por recurso** | **Motor completo, contexto simulado** | **~200 ms–2 s** | **Compuerta de PR, suite de regresión, red de seguridad para refactors** |
| `kyverno apply --cluster` | Sí (kubeconfig de solo lectura) | Ninguna | Motor completo + contexto en vivo de `apiCall`/ConfigMap | Segundos | Verificación previa contra el inventario de un clúster real |
| Chainsaw (`kyverno/chainsaw`) | Sí (kind/k3d) | Sí, sobre el estado del clúster | Webhook real, servidor de API real | Minutos | Configuración de webhook, `generate` + `synchronize`, escaneos en segundo plano, pruebas de actualización |
| Pruebas Conftest / OPA `rego` | No | Sí | **Motor distinto** — no prueba nada sobre Kyverno | ~50 ms | No aplicable; una pila de políticas separada |
| `kubectl apply --dry-run=server` | Sí | Ninguna | Real, cadena completa | Segundos | Comprobación final de cordura antes del merge |

**La regla de decisión.** Si la aserción trata sobre *el veredicto del motor respecto a un manifiesto*, corresponde a `kyverno test`. Si trata sobre *el estado del clúster cambiando con el tiempo* — un recurso generado que aparece, un reporte que se escribe, `synchronize: true` propagando una edición — corresponde a Chainsaw. No intentes forzar lo segundo dentro de lo primero; escribirás pruebas que pasan mientras la política está rota en producción.

---

## 3. Anatomía del manifiesto `Test`

Desde Kyverno 1.11 el archivo de prueba es un objeto tipado bajo `cli.kyverno.io/v1alpha1`. Los archivos heredados sin versión (con `name:`/`policies:`/`results:` a secas y sin `apiVersion`) están obsoletos — migrálos (§8.3).

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label          # test suite name, surfaced in output
policies:                           # paths, relative to THIS file
  - policy.yaml
resources:                          # fixture manifests (may be multi-doc)
  - resources.yaml
variables: values.yaml              # OPTIONAL: mocked context (kind: Value)
userinfo: user-info.yaml            # OPTIONAL: mocked AdmissionReview.userInfo
results:                            # the assertions
  - policy: require-team-label      # metadata.name of the policy
    rule: check-team-label          # spec.rules[].name — see §7 for autogen
    kind: Pod                       # resource kind under test
    namespace: default              # OPTIONAL: disambiguates same-named fixtures
    resources:                      # metadata.name of one or more fixtures
      - good-pod
    result: pass                    # the EXPECTED engine verdict
```

### 3.1 El vocabulario de `result`

Esta es la tabla de mayor rendimiento del tema. El examen evalúa la distinción entre `fail` y `skip` sin descanso, y la producción también.

| `result` | Significado en el motor | Qué prueba | Causa común cuando es inesperado |
|---|---|---|---|
| `pass` | La regla **se aplicó**; el recurso **cumplió** | El camino feliz no se bloquea por accidente | — |
| `fail` | La regla **se aplicó**; el recurso **violó** | El control efectivamente atrapa la entrada mala | — |
| `skip` | La regla **no se aplicó** — `match`/`exclude` no la seleccionó, o una `precondition` evaluó a falso | El alcance es correcto (las exclusiones funcionan) | **Obtener `skip` donde esperabas `fail` es el bug del falso negativo.** `kinds` incorrecto, `apiVersion` incorrecto, variable de precondición sin resolver |
| `warn` | Un fallo que emerge como advertencia en lugar de una denegación — la semántica de `Audit` (`kyverno apply --audit-warn`) | Una política de aviso es de aviso | Afirmar `fail` sobre una política que moviste a `Audit` |
| `error` | El motor no pudo evaluar: patrón mal formado, fallo de sustitución de variables, JMESPath incorrecto | Nada — esto es una política rota | Falta una entrada en `variables`; `apiCall` sin clúster |

> **`skip` ≠ `pass`.** Un `skip` significa que la regla no tuvo opinión. Si tu suite solo afirma `pass`, una política cuyo bloque `match` rompiste seguirá en verde — cada recurso hace skip silenciosamente. **Cada regla validate necesita al menos un `fail` afirmado.** Tratá eso como un ítem de la lista de revisión.

### 3.2 Campos de mutación y generación

| Campo | Aplica a | Valor |
|---|---|---|
| `patchedResources` | reglas `mutate` | Ruta a un archivo YAML que contiene el **recurso exacto esperado tras la mutación** |
| `generatedResource` | reglas `generate` | Ruta a un archivo YAML que contiene el objeto generado esperado |
| `cloneSourceResource` | `generate` con `clone` | Ruta al objeto de origen que se clona |
| `isValidatingAdmissionPolicy: true` | VAP nativa / generada por Kyverno | Marca la fila como una aserción de ValidatingAdmissionPolicy |

---

## 4. Convención de disposición del repositorio

El repositorio upstream `kyverno/policies` usa esta disposición, y los fixtures del examen la siguen. Mantené las pruebas junto a la política — una prueba que vive a tres directorios de distancia se pudre.

```
policies/
└── governance/
    └── require-team-label/
        ├── require-team-label.yaml          # the ClusterPolicy
        ├── artifacthub-pkg.yml              # catalogue metadata
        └── .kyverno-test/
            ├── kyverno-test.yaml            # the Test object
            ├── resources.yaml               # fixtures
            └── values.yaml                  # optional mocked context
```

`kyverno test <dir>` recorre `<dir>` de forma **recursiva** y ejecuta cada archivo llamado `kyverno-test.yaml` (o `.yml`). Una sola invocación en la raíz del repositorio ejecuta toda la suite.

---

## 5. Ejemplo resuelto 1 — validate: `pass`, `fail`, y el `skip` obligatorio

### 5.1 `require-team-label.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
  annotations:
    policies.kyverno.io/title: Require team label
    policies.kyverno.io/category: Governance
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Every workload Pod must carry a non-empty `team` label so that cost
      allocation and incident routing can attribute it to an owning group.
      Platform namespaces are exempt.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-node-lease
                - kyverno
      validate:
        message: "The label `team` is required and must be non-empty on all Pods."
        pattern:
          metadata:
            labels:
              team: "?*"
```

> **Nota de versión.** `spec.validationFailureAction` es la ubicación de 1.10–1.12; Kyverno 1.13 la mueve a `spec.rules[].validate.failureAction` por regla y deprecia el campo a nivel de spec. Ambos se aceptan durante la ventana de deprecación. Confirmá cuál usa tu imagen de examen con `kyverno version`, y mantené la CLI en la **misma versión minor que el clúster** — la CLI lleva su propia copia del motor y su propia validación de esquema.

### 5.2 `resources.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
  namespace: default
  labels:
    team: payments
spec:
  containers:
    - name: app
      image: ghcr.io/example/app:1.4.2
---
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: default
  labels:
    app: checkout
spec:
  containers:
    - name: app
      image: ghcr.io/example/app:1.4.2
---
apiVersion: v1
kind: Pod
metadata:
  name: empty-label-pod
  namespace: default
  labels:
    team: ""
spec:
  containers:
    - name: app
      image: ghcr.io/example/app:1.4.2
---
apiVersion: v1
kind: Pod
metadata:
  name: system-pod
  namespace: kube-system
  labels:
    component: etcd
spec:
  containers:
    - name: etcd
      image: registry.k8s.io/etcd:3.5.15-0
```

`empty-label-pod` es deliberado: `"?*"` en un patrón de Kyverno significa "un carácter seguido de cualquier cantidad de caracteres", es decir, **no vacío**. Una etiqueta `team: ""` satisface "la clave existe" pero aún así debe fallar. Sin este fixture, cambiar `?*` por `*` — que *sí* coincide con vacío — es una regresión indetectable.

### 5.3 `.kyverno-test/kyverno-test.yaml`

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label
policies:
  - ../require-team-label.yaml
resources:
  - resources.yaml
results:
  - policy: require-team-label
    rule: check-team-label
    kind: Pod
    resources:
      - good-pod
    result: pass

  - policy: require-team-label
    rule: check-team-label
    kind: Pod
    resources:
      - bad-pod
      - empty-label-pod
    result: fail

  - policy: require-team-label
    rule: check-team-label
    kind: Pod
    namespace: kube-system
    resources:
      - system-pod
    result: skip
```

### 5.4 Ejecución

```console
$ kyverno version
Version: 1.13.2
Time: 2025-01-14T09:12:44Z
Git commit ID: 8e3f4b1c0d2a5e9f7b1c3d4e5f6a7b8c9d0e1f2a

$ kyverno test .
Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 4 resources ...
  Checking results ...

│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ ID │ POLICY               │ RULE              │ RESOURCE                        │ RESULT │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ 1  │ require-team-label   │ check-team-label  │ default/Pod/good-pod            │ Pass   │
│ 2  │ require-team-label   │ check-team-label  │ default/Pod/bad-pod             │ Pass   │
│ 3  │ require-team-label   │ check-team-label  │ default/Pod/empty-label-pod     │ Pass   │
│ 4  │ require-team-label   │ check-team-label  │ kube-system/Pod/system-pod      │ Pass   │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│

Test Summary: 4 tests passed and 0 tests failed

$ echo $?
0
```

> **Leé la columna `RESULT` correctamente.** Es el **veredicto de la prueba**, no el veredicto de la política. La fila 2 dice `Pass` porque el motor devolvió `fail` para `bad-pod` **y la prueba esperaba `fail`**. Un `Fail` en esa columna significa *que la aserción no se cumplió* — el resultado del motor difirió de lo que declaraste. Los candidatos pierden puntos al leer la fila 2 como "el pod malo fue permitido".

### 5.5 Una ejecución que falla

Ahora rompé la política: cambiá `exclude` para omitir `kube-system`.

```console
$ kyverno test .
Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 4 resources ...
  Checking results ...

│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ ID │ POLICY               │ RULE              │ RESOURCE                        │ RESULT │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ 1  │ require-team-label   │ check-team-label  │ default/Pod/good-pod            │ Pass   │
│ 2  │ require-team-label   │ check-team-label  │ default/Pod/bad-pod             │ Pass   │
│ 3  │ require-team-label   │ check-team-label  │ default/Pod/empty-label-pod     │ Pass   │
│ 4  │ require-team-label   │ check-team-label  │ kube-system/Pod/system-pod      │ Fail   │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│

Aggregated Failed Test Cases :
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ ID │ POLICY               │ RULE              │ RESOURCE                        │ RESULT │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ 1  │ require-team-label   │ check-team-label  │ kube-system/Pod/system-pod      │ Fail   │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│

Test Summary: 3 tests passed and 1 tests failed

$ echo $?
1
```

El código de salida distinto de cero es lo esencial: es lo que hace que el comando sea usable como compuerta de merge. `--fail-only` suprime las filas que pasan pero **no** cambia el código de salida.

---

## 6. Ejemplo resuelto 2 — mutación y `patchedResources`

Las pruebas de mutación afirman sobre el *documento de salida*, byte por byte tras la normalización de YAML. Esto es más estricto que una aserción validate y atrapa errores de clave de merge que un `pass`/`fail` nunca detectaría.

### 6.1 `add-default-requests.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-requests
  annotations:
    policies.kyverno.io/title: Add default resource requests
    policies.kyverno.io/category: Scheduling
    policies.kyverno.io/subject: Pod
spec:
  background: false
  rules:
    - name: add-default-requests
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        any:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                resources:
                  requests:
                    +(memory): "128Mi"
                    +(cpu): "100m"
```

Dos anclas de Kyverno son fundamentales aquí y ambas son material de examen:

| Ancla | Sintaxis | Semántica |
|---|---|---|
| Condicional | `(name): "*"` | Selecciona todo elemento de la lista cuyo `name` coincida; se usa como clave de merge para que el parche se aplique por contenedor |
| Agregar‑si‑ausente | `+(memory): "128Mi"` | Agrega el campo **solo cuando aún no está definido**; nunca sobrescribe un request explícito |

### 6.2 `resources.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27.3
    - name: sidecar
      image: ghcr.io/example/agent:2.1.0
      resources:
        requests:
          cpu: "500m"
```

### 6.3 `patched.yaml` — la salida esperada

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27.3
      resources:
        requests:
          memory: 128Mi
          cpu: 100m
    - name: sidecar
      image: ghcr.io/example/agent:2.1.0
      resources:
        requests:
          cpu: "500m"
          memory: 128Mi
```

Fijate en el contenedor `sidecar`: `cpu` se **preserva en `500m`** gracias a `+(cpu)`, mientras que `memory` se agrega. Si tu archivo patched muestra `cpu: 100m` ahí, el ancla está mal — y solo la prueba de mutación lo atrapa.

### 6.4 `values.yaml` — simulando el contexto de admisión

`request.operation` es un campo de AdmissionReview. No hay servidor de API, así que hay que suministrarlo. El fallback `|| 'BACKGROUND'` en la política previene un veredicto `error`, pero aun así deberías simular el valor real para que la prueba ejercite la rama `CREATE`.

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
globalValues:
  request.operation: CREATE
policies:
  - name: add-default-requests
    resources:
      - name: nginx
        values:
          request.object.metadata.namespace: default
namespaceSelector:
  - name: default
    labels:
      kubernetes.io/metadata.name: default
```

| Campo de `Value` | Propósito |
|---|---|
| `globalValues` | Pares clave/valor visibles para **cada** política y recurso |
| `policies[].rules[].values` | Acotado a una regla — usalo para simulaciones de `apiCall`/ConfigMap por regla |
| `policies[].resources[].values` | Acotado a un fixture — permite que un recurso tome un contexto distinto |
| `namespaceSelector` | Suministra las **labels** del namespace, que la CLI no puede consultar; requerido siempre que una política use `match.any.resources.namespaceSelector` |

### 6.5 La prueba y su ejecución

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: add-default-requests
policies:
  - ../add-default-requests.yaml
resources:
  - resources.yaml
variables: values.yaml
results:
  - policy: add-default-requests
    rule: add-default-requests
    kind: Pod
    resources:
      - nginx
    patchedResources: patched.yaml
    result: pass
```

```console
$ kyverno test . --detailed-results
Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 1 resource ...
  Checking results ...

│────│───────────────────────│─────────────────────────│───────────────────────│────────│
│ ID │ POLICY                │ RULE                    │ RESOURCE              │ RESULT │
│────│───────────────────────│─────────────────────────│───────────────────────│────────│
│ 1  │ add-default-requests  │ add-default-requests    │ default/Pod/nginx     │ Pass   │
│────│───────────────────────│─────────────────────────│───────────────────────│────────│

Test Summary: 1 tests passed and 0 tests failed
```

Cuando el parche no coincide, la CLI imprime un diff estructurado de esperado vs. real — esta es la recompensa de `--detailed-results`:

```console
$ kyverno test . --detailed-results
...
│ 1  │ add-default-requests  │ add-default-requests    │ default/Pod/nginx     │ Fail   │

Aggregated Failed Test Cases :
patched resource mismatch for default/Pod/nginx:
  spec.containers[1].resources.requests.cpu:
    expected: 500m
    actual:   100m

Test Summary: 0 tests passed and 1 tests failed
```

> **La trampa del defaulting del servidor de API.** `patched.yaml` debe contener **solo el manifiesto en crudo más el parche de Kyverno**. *No* pegues la salida de `kubectl get pod -o yaml`: el servidor de API inyecta `terminationMessagePath`, `imagePullPolicy`, `dnsPolicy`, `restartPolicy`, `serviceAccountName`, `status`, `metadata.uid`, y `creationTimestamp`. Ninguno de esos existe en la evaluación de la CLI, y cada uno de ellos hace que la comparación falle. La forma confiable de producir `patched.yaml` es ejecutar `kyverno apply` y copiar el recurso parcheado que emite — nunca el del clúster.

---

## 7. Reglas autogeneradas — el fallo de prueba más común

Cuando una política coincide con `Pod` y `spec.background` es `true` (o la anotación `pod-policies.kyverno.io/autogen-controllers` está definida), Kyverno **sintetiza reglas adicionales** para los controladores de pods, de modo que un `Deployment` malo se rechace a nivel de Deployment, con un error comprensible, en lugar de producir silenciosamente cero réplicas listas.

Las reglas generadas son visibles en la política almacenada:

```console
$ kubectl get clusterpolicy require-team-label -o jsonpath='{.spec.rules[*].name}{"\n"}'
check-team-label

$ kubectl get clusterpolicy require-team-label -o jsonpath='{.status.autogen.rules[*].name}{"\n"}'
autogen-check-team-label autogen-cronjob-check-team-label
```

| Kind del recurso coincidente | Nombre de regla a afirmar en `results` |
|---|---|
| `Pod` | `check-team-label` |
| `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `Job`, `ReplicationController` | `autogen-check-team-label` |
| `CronJob` | `autogen-cronjob-check-team-label` |

Afirmar el nombre de regla a secas contra un fixture de `Deployment` es el error clásico:

```console
$ kyverno test .
...
Error: test case has invalid rule: rule "check-team-label" not found in policy "require-team-label"
```

Forma correcta:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label-autogen
policies:
  - ../require-team-label.yaml
resources:
  - controllers.yaml
results:
  - policy: require-team-label
    rule: autogen-check-team-label
    kind: Deployment
    resources:
      - bad-deployment
    result: fail

  - policy: require-team-label
    rule: autogen-cronjob-check-team-label
    kind: CronJob
    resources:
      - bad-cronjob
    result: fail
```

La cobertura de autogen no es opcional en una suite seria. Una política puede ser perfectamente correcta para `Pod` y completamente incorrecta para `CronJob`, porque la regla autogen de CronJob reescribe la ruta a `spec.jobTemplate.spec.template.metadata.labels` — un patrón que asumía `spec.template.metadata` no sobrevivirá a la reescritura.

---

## 8. Superficie de la CLI

### 8.1 Flags

```console
$ kyverno test --help
Run tests from a local filesystem or a git repository.
...
```

| Flag | Efecto | Uso en producción |
|---|---|---|
| `-f, --file-name` | Nombre de archivo de prueba a descubrir (por defecto `kyverno-test.yaml`) | Solo cuando debés desviarte de la convención |
| `-t, --test-case-selector` | Ejecuta un subconjunto: `"policy=require-team-label, rule=check-team-label, resource=bad-pod"` | Iterar sobre un solo fallo en una suite de 400 pruebas |
| `--fail-only` | Imprime solo las filas que fallan (el código de salida no cambia) | Logs de CI — colapsa un muro de verde |
| `--detailed-results` | Expande el detalle por comprobación y los diffs de parche | Diagnosticar un desajuste de mutación |
| `--remove-color` | Elimina los escapes ANSI | **Siempre activado en CI**; de lo contrario los logs son ilegibles |
| `--registry` | Permite acceso de red a registries OCI | Solo reglas `imageVerify` / `imageData` |
| `-b, --git-branch` | Rama a usar cuando la ruta es una URL de Git | Probar una biblioteca upstream |

### 8.2 Ejecutar contra un repositorio Git

El argumento de ruta acepta una URL de Git, así que podés hacer pruebas de regresión de una biblioteca de políticas que consumís sin vendorizarla:

```console
$ kyverno test https://github.com/kyverno/policies/pod-security --git-branch main
Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
...
Test Summary: 62 tests passed and 0 tests failed
```

### 8.3 Andamiaje y migración

```console
# Generate a Test manifest skeleton instead of writing YAML from memory
$ kyverno create test --help

# Migrate legacy (unversioned) test files to cli.kyverno.io/v1alpha1 in place
$ KYVERNO_EXPERIMENTAL=true kyverno fix test . --save
Processing file ( .kyverno-test/kyverno-test.yaml )...
  WARNING: test file is not in the expected format
  OK
Done.
```

`kyverno fix test` también normaliza los campos singulares obsoletos (`resource:` → `resources:`, `patchedResource:` → `patchedResources:`). Ejecutalo una vez, commiteá el resultado, y dejá de mantener a mano la forma vieja.

### 8.4 Árboles de aserción (`checks`) — Kyverno 1.12+

Para aserciones más ricas que un solo veredicto — "la entrada del reporte debe llevar esta severidad", "el mensaje debe mencionar el nombre de la label" — las CLIs más nuevas aceptan un bloque `checks` respaldado por árboles de aserción de kyverno‑json:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label-checks
policies:
  - ../require-team-label.yaml
resources:
  - resources.yaml
checks:
  - match:
      resource:
        metadata:
          name: bad-pod
    assert:
      result: fail
      message: "(contains(@, 'team'))": true
```

Tratá esto como aditivo: `results` sigue siendo el mecanismo primario y relevante para el examen, y la disponibilidad de `checks` varía según la versión minor de la CLI. Verificá con `kyverno test --help` en la imagen que tenés delante antes de depender de ello.

---

## 9. Integración con CI

### 9.1 GitHub Actions

```yaml
name: kyverno-policy-tests

on:
  pull_request:
    paths:
      - 'policies/**'
      - '.github/workflows/kyverno-policy-tests.yaml'
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install Kyverno CLI
        uses: kyverno/action-install-cli@v0.2.0
        with:
          release: v1.13.2          # pin: must match the cluster's minor version

      - name: Report CLI version
        run: kyverno version

      - name: Validate policy syntax
        run: |
          find policies -name '*.yaml' -not -path '*/.kyverno-test/*' \
            -exec kyverno apply {} --resource /dev/null \; > /dev/null

      - name: Run policy unit tests
        run: kyverno test ./policies --remove-color --detailed-results
```

El job falla ante una salida distinta de cero de `kyverno test`. Sin clúster, sin kubeconfig, sin secretos — que es exactamente por qué esto corresponde a `pull_request` desde forks.

### 9.2 Target de Makefile

```makefile
KYVERNO_VERSION ?= 1.13.2
POLICY_DIR      ?= ./policies

.PHONY: test-policies
test-policies:
	@kyverno version | grep -q "Version: $(KYVERNO_VERSION)" \
		|| { echo "ERROR: expected Kyverno CLI $(KYVERNO_VERSION)"; exit 1; }
	kyverno test $(POLICY_DIR) --remove-color

.PHONY: test-policies-failed
test-policies-failed:
	kyverno test $(POLICY_DIR) --remove-color --fail-only --detailed-results
```

La aserción de versión no es paranoia. La CLI incrusta su propia compilación de motor; ejecutar pruebas con una CLI dos minors por delante del clúster produce pruebas en verde para semánticas que el clúster no implementa.

---

## 10. Verificación y diagnóstico de fallos

### 10.1 Síntoma → causa → solución

| Síntoma | Causa raíz | Solución |
|---|---|---|
| `Test Summary: 0 tests passed and 0 tests failed` | No se encontró ningún `kyverno-test.yaml` bajo la ruta | Verificá el nombre de archivo exacto, o pasá `-f`. Confirmá con `find . -name 'kyverno-test.y*ml'` |
| `Error: failed to load test file: ... unknown field` | Esquema heredado sin versión, o un campo singular obsoleto | `KYVERNO_EXPERIMENTAL=true kyverno fix test . --save` |
| `Error: test case has invalid rule: rule "X" not found` | Afirmar una regla de Pod contra un fixture de controlador | Usá `autogen-X` / `autogen-cronjob-X` (§7) |
| Esperabas `fail`, obtuviste `skip` | `match` no seleccionó el recurso: `kinds` incorrecto, group/version incorrecto, o un `exclude` demasiado amplio | `kyverno apply policy.yaml --resource resources.yaml` y leé la salida por regla |
| Esperabas `pass`, obtuviste `error` | Variable sin resolver — `request.*`, `serviceAccountName`, un contexto de ConfigMap o `apiCall` | Agregala a `variables: values.yaml`, o dale a la política un fallback `\|\| 'default'` |
| `variable substitution failed: ... variable ... not resolved` | Lo mismo que arriba, hecho explícito | `globalValues:` para hechos de todo el clúster, `policies[].resources[].values` para hechos por fixture |
| Esperabas `fail`, obtuviste `skip`, y la política usa `namespaceSelector` | La CLI no puede leer las labels de namespace | Agregá una entrada `namespaceSelector:` al objeto `Value` |
| `patched resource mismatch` en campos que nunca escribiste | `patched.yaml` fue copiado de un clúster en vivo | Regeneralo desde `kyverno apply`, no desde `kubectl get -o yaml` |
| Pasa localmente, falla en CI | Deriva de versión de la CLI | Fijá `release:` en la acción de instalación; afirmá la versión en el Makefile |
| La regla `imageVerify` devuelve `error` | Sin acceso a registry | Agregá `--registry`, o mové la aserción a Chainsaw |

### 10.2 La escalera de escalado del diagnóstico

Cuando una fila está en rojo y la tabla por sí sola no lo explica, escalá en este orden — cada paso cuesta más y revela más:

```console
# 1. Narrow to the single failing case
$ kyverno test . -t "policy=require-team-label, resource=bad-pod"

# 2. Expand the assertion detail and the patch diff
$ kyverno test . -t "policy=require-team-label, resource=bad-pod" --detailed-results

# 3. Drop the assertions entirely — see what the engine actually returns
$ kyverno apply ../require-team-label.yaml --resource resources.yaml --policy-report
apiVersion: policy.kyverno.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: merged
results:
- message: 'validation error: The label `team` is required and must be non-empty on
    all Pods. rule check-team-label failed at path /metadata/labels/team/'
  policy: require-team-label
  resources:
  - apiVersion: v1
    kind: Pod
    name: bad-pod
    namespace: default
  result: fail
  rule: check-team-label
  scored: true
  source: kyverno
summary:
  error: 0
  fail: 1
  pass: 1
  skip: 1
  warn: 0

# 4. Turn on engine tracing
$ kyverno test . --v=4 2>&1 | grep -i 'match\|precondition'

# 5. Compare against a real API server
$ kubectl apply -f resources.yaml --dry-run=server
```

El paso 3 es el que resuelve la mayoría de la confusión `skip`‑vs‑`fail`: `--policy-report` imprime el veredicto propio del motor con la ruta JSON que falla (`failed at path /metadata/labels/team/`), que te dice con precisión qué elemento del patrón rechazó el documento.

---

## 11. Lo que `kyverno test` no puede probar

Conocer el límite es una competencia de nivel senior, y el examen lo indaga como "¿qué herramienta usarías para verificar X?".

| Preocupación | Por qué la CLI no puede cubrirlo | A dónde corresponde |
|---|---|---|
| El webhook está registrado para los recursos correctos | Sin servidor de API, sin `ValidatingWebhookConfiguration` | Chainsaw; `kubectl get validatingwebhookconfigurations` |
| Comportamiento de `failurePolicy: Fail` cuando Kyverno está caído | Requiere un plano de control en ejecución para derribarlo | Chainsaw / prueba de caos |
| `generate` con `synchronize: true` propagando ediciones | Afirma estado a lo largo del tiempo, no una sola evaluación | Chainsaw |
| Resultados de escaneo en segundo plano y ciclo de vida del PolicyReport | El controlador de reportes es un componente del clúster | Chainsaw; `kubectl get polr -A` |
| Consultas de contexto en vivo de `apiCall` / ConfigMap | Simuladas vía `variables`, así que probás tu simulación | `kyverno apply --cluster`, luego Chainsaw |
| Verificación de firma de Cosign | Necesita registry + material de claves | `--registry`, y Chainsaw para el camino real |
| Interacción con otros webhooks de admisión (orden, cadenas de mutación) | Evaluación de un solo motor | `--dry-run=server` en un clúster real |
| Defaulting del servidor de API aplicado antes de que Kyverno vea el objeto | La CLI evalúa el manifiesto en crudo | `--dry-run=server` |
| RBAC para reglas `generate` (los permisos del controlador en segundo plano) | Sin subsistema RBAC en la CLI | Chainsaw |

La mitigación no es desconfiar de `kyverno test` — es ser explícito sobre la capa. Probá unitariamente aquí la lógica de veredicto de cada regla, donde cuesta 200 ms, y reservá el clúster para el puñado de comportamientos que genuinamente requieren uno.

---

## 12. Lista de verificación de examen y operativa

- [ ] El archivo de prueba se llama `kyverno-test.yaml`, vive bajo `.kyverno-test/`, y las rutas dentro de él son **relativas al archivo de prueba**.
- [ ] El manifiesto lleva `apiVersion: cli.kyverno.io/v1alpha1` y `kind: Test`.
- [ ] Cada regla validate tiene al menos un `pass` afirmado **y** un `fail` afirmado.
- [ ] Cada bloque `exclude` tiene un fixture que afirma `skip`.
- [ ] Los fixtures de controladores afirman `autogen-<rule>`; los fixtures de CronJob afirman `autogen-cronjob-<rule>`.
- [ ] Las reglas de mutación afirman `patchedResources`, construidas desde la salida de `kyverno apply` — nunca desde un clúster en vivo.
- [ ] Cada variable que la política referencia aparece en `variables: values.yaml`, o la política lleva un fallback `||`.
- [ ] Las políticas que usan `namespaceSelector` tienen una entrada `namespaceSelector:` correspondiente en el objeto `Value`.
- [ ] CI fija el release de la CLI y pasa `--remove-color`; el job usa el código de salida como compuerta.
- [ ] `kyverno test <repo-root>` está en verde antes de promover cualquier política de `Audit` a `Enforce`.

---

## Referencias

- Kyverno CLI — comando `test`: https://kyverno.io/docs/kyverno-cli/usage/test/
- Kyverno CLI — descripción general e instalación: https://kyverno.io/docs/kyverno-cli/
- Kyverno CLI — comando `apply`: https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno — autogeneración de reglas de controladores de pod: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — variables y contexto: https://kyverno.io/docs/writing-policies/variables/
- Kyverno — fuentes de datos externas (`apiCall`, ConfigMap): https://kyverno.io/docs/writing-policies/external-data-sources/
- Kyverno — reglas mutate y anclas: https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — reglas generate: https://kyverno.io/docs/writing-policies/generate/
- Kyverno — reportes de políticas: https://kyverno.io/docs/policy-reports/
- Kyverno — repositorio de código fuente: https://github.com/kyverno/kyverno
- Kyverno — biblioteca oficial de políticas (disposición canónica de pruebas): https://github.com/kyverno/policies
- Kyverno — GitHub Action de instalación de la CLI: https://github.com/kyverno/action-install-cli
- Chainsaw — pruebas de extremo a extremo para Kyverno: https://github.com/kyverno/chainsaw
- CNCF — currículas de certificación (KCA): https://github.com/cncf/curriculum
- Linux Foundation — Kyverno Certified Associate (KCA): https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/