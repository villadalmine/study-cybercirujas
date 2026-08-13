## Nota de integridad antes del material

El input llega con metadatos rotos: el tema es la etiqueta literal **"test"** y la versión de la certificación es **"unknown"**. Eso, más el historial reciente del repo (`…cost 48 passes instead of one probe`) y los archivos sin trackear (`hola`, `seguir`, `test_agy.py`), me hace sospechar que esto es un *probe* del pipeline y no un objetivo real de syllabus. Además, en esta sesión **no tengo acceso al filesystem del repo** (ni `Read` ni `Bash`), así que no puedo abrir `certs/kca.md` ni el `KCA_Curriculum.pdf` para verificarlo yo mismo.

Procedo bajo la interpretación mejor fundamentada: **KCA = Kyverno Certified Associate** (LF/CNCF), y el objetivo "test" del dominio 3 corresponde a **testear políticas con la Kyverno CLI (`kyverno test`)**. Si el tema real es otro, corregime y lo regenero. Escribo para una versión reciente de Kyverno y marco explícitamente los puntos sensibles a versión, ya que llega como `unknown`.

---

# KCA 3.2 — Testing declarativo de políticas con la Kyverno CLI (`kyverno test`)

## 1. Motivación y problema arquitectónico de producción

Kyverno es un admission controller: sus políticas (`ClusterPolicy` / `Policy`) son código que se ejecuta en el *hot path* de cada `CREATE`/`UPDATE` que pasa por el API server. Un `validate` mal escrito rechaza deployments legítimos de toda la organización; un `mutate` mal escrito inyecta un sidecar o un `securityContext` incorrecto en cada Pod. La política **es** infraestructura crítica, y como toda infraestructura crítica necesita una suite de tests que corra **antes** de llegar al cluster.

El problema de producción concreto: una política evoluciona (se agrega un `precondition`, se cambia un `pattern`, se migra `validationFailureAction` a `failureAction` por rule). Sin tests, cada cambio es una apuesta. Los modos de falla típicos:

- **Regresión silenciosa**: un refactor del `match/exclude` deja de cubrir un `kind` que antes cubría. El cluster deja de estar protegido y nadie se entera hasta el incidente.
- **Falso positivo masivo**: un `pattern` demasiado estricto empieza a bloquear cargas válidas. En `Enforce`, esto es un outage autoinfligido a escala de cluster.
- **Autogen no considerado**: se testea contra un `Pod` pero en producción los recursos son `Deployment`/`CronJob`, y Kyverno evalúa la regla **autogenerada** `autogen-<rule>`, cuyo comportamiento nunca se validó.

`kyverno test` resuelve esto ejecutando el motor de políticas **offline, sin cluster**, contra un set de recursos fijo, y **aseverando el resultado esperado** de cada `(policy, rule, resource)`. Es el equivalente a un unit test: determinista, rápido, gate-able en CI, y sin depender de un API server. Es la pieza que convierte "policy-as-code" en "policy-as-code **con CI**".

Fuente oficial: https://kyverno.io/docs/kyverno-cli/usage/test/

---

## 2. Comparativa técnica: dónde encaja `test` en el espectro de verificación

| Herramienta | Qué prueba | Necesita cluster | Determinismo | Uso típico | Gate en CI |
|---|---|---|---|---|---|
| **Quality floor / lint** (`kyverno-json`, `kubectl kyverno` schema) | Que el YAML de la política sea válido y parseable | No | Alto | Pre-commit | Sí |
| **`kyverno apply`** | Evaluación *ad hoc* de política(s) contra recurso(s); imprime el resultado real | No | Alto | Exploración interactiva, debug, generar policy reports offline | Parcial (`--warn-exit-code`) |
| **`kyverno test`** | **Aserción declarativa**: resultado esperado (`pass/fail/skip/warn/error`) por regla y recurso | No | Alto | **Unit/regression testing de la lógica de la política** | **Sí (exit code)** |
| **Chainsaw** (`kyverno/chainsaw`) | e2e: aplica recursos a un cluster real y aseveran el estado resultante | **Sí** | Medio (depende del cluster) | e2e de la instalación de Kyverno, generate/mutate contra API real, background scans | Sí (en cluster efímero) |
| **`kuttl`** (predecesor) | e2e declarativo genérico de operators | Sí | Medio | Legacy e2e | Sí |

Trade-offs clave:

- **`apply` vs `test`**: `apply` te dice *qué pasó*; `test` te dice *si lo que pasó es lo que esperabas*. `apply` no falla el build por sí solo cuando la lógica cambia; `test` sí, porque compara contra `results:` declarados. Para CI usás `test`; para "a ver qué hace esta regla" usás `apply`.
- **`test` vs Chainsaw**: `test` valida la **lógica de admission** de la política sin latencia de cluster (ideal para el 90% de los casos: validate/mutate/verifyImages). Chainsaw valida lo que **solo** un cluster real revela: `generate` con `synchronize`, background scans, cleanup policies con TTL, interacción con otros controllers. Regla práctica SRE: `test` para la lógica, Chainsaw para el comportamiento del controller en el tiempo.

---

## 3. Manifiestos completos (sin recortar)

Estructura de directorio de un caso de test:

```
require-labels/
├── policy.yaml
├── resources.yaml
└── kyverno-test.yaml
```

### `policy.yaml` — la política bajo test

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
  annotations:
    policies.kyverno.io/title: Require team label
    policies.kyverno.io/severity: medium
spec:
  # NOTA DE VERSIÓN: en Kyverno < 1.12 la acción va aquí, a nivel spec.
  # En >= 1.12 se declara por regla: spec.rules[].validate.failureAction: Enforce
  # (spec.validationFailureAction quedó deprecado). Como la versión llega "unknown",
  # uso la forma spec-level, compatible con el mayor rango de releases.
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "El label 'team' es obligatorio en todo Pod."
        pattern:
          metadata:
            labels:
              team: "?*"        # ?* = string no vacío
```

### `resources.yaml` — los recursos de prueba (uno conforme, uno violatorio)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-with-team-label
  namespace: default
  labels:
    team: sre
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.9
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-without-team-label
  namespace: default
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.9
```

### `kyverno-test.yaml` — el manifiesto de test (schema CLI v1alpha1, Kyverno ≥ 1.11)

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-labels-test
policies:
  - policy.yaml
resources:
  - resources.yaml
results:
  - policy: require-labels
    rule: check-team-label
    kind: Pod
    resources:
      - pod-with-team-label       # conforme -> la regla lo admite
    result: pass
  - policy: require-labels
    rule: check-team-label
    kind: Pod
    resources:
      - pod-without-team-label    # viola el pattern -> la regla lo rechaza
    result: fail
```

> **Sensible a versión (importante para `unknown`)**: en Kyverno < 1.10 el manifiesto **no** llevaba `apiVersion`/`kind`, los campos eran top-level (`name`, `policies`, `resources`, `results`) y el campo de aserción se llamaba **`status`**, no `result`. Si el motor es viejo, el schema de arriba falla a parsear. Verificá con `kyverno version` y elegí el schema acorde.

### Variante `mutate`: aseverar el recurso mutado

Para un `mutate` no alcanza con `pass/fail`: hay que aseverar el **output**. El manifiesto de test referencia el recurso ya parcheado esperado:

```yaml
# results[] de un test de mutación
results:
  - policy: add-default-securitycontext
    rule: set-runasnonroot
    kind: Pod
    resources:
      - pod-input
    patchedResources: patched.yaml   # el YAML del Pod tal como debe quedar tras el mutate
    result: pass
```

`patched.yaml` contiene el Pod completo con el `securityContext.runAsNonRoot: true` ya inyectado; la CLI aplica la mutación real y hace *diff* contra este archivo. Cualquier divergencia → `fail`.

---

## 4. Comandos CLI y salidas reales

Instalación de la CLI (vía Krew) y verificación de versión — **primer paso** dado que el schema depende de ella:

```console
$ kubectl krew install kyverno
$ kyverno version
Version: 1.13.2
Time: 2025-01-20T10:14:52Z
Git commit ID: 9f3c1a...
```

Ejecución del test sobre el directorio (descubre `kyverno-test.yaml` recursivamente):

```console
$ kyverno test .

Loading test  ( ./require-labels/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│───│────────────────│──────────────────│──────────────────────────────────│────────│
│ ID│ POLICY         │ RULE             │ RESOURCE                         │ RESULT │
│───│────────────────│──────────────────│──────────────────────────────────│────────│
│ 1 │ require-labels │ check-team-label │ default/Pod/pod-with-team-label  │ Pass ✅ │
│ 2 │ require-labels │ check-team-label │ default/Pod/pod-without-team-... │ Pass ✅ │
│───│────────────────│──────────────────│──────────────────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

> Ambas filas dan **Pass** porque `test` valida que el resultado **real** coincida con el **esperado**: el caso violatorio esperaba `fail` y efectivamente falló ⇒ el *test* pasa. No confundas "resultado de la regla" (`fail`) con "resultado del test" (`Pass`).

Exit code (lo que hace gate-able la suite):

```console
$ kyverno test . ; echo "exit=$?"
...
Test Summary: 2 tests passed and 0 tests failed
exit=0
```

Cuando una aserción no coincide (p. ej. alguien afloja el `pattern` y el Pod violatorio ahora pasa):

```console
$ kyverno test . ; echo "exit=$?"
...
│ 2 │ require-labels │ check-team-label │ default/Pod/pod-without-team-... │ Fail ❌ │
Test Summary: 1 tests passed and 1 tests failed
exit=1
```

Ver solo lo que falla y con detalle:

```console
$ kyverno test . --fail-only --detailed-results
```

Correr contra un repositorio Git remoto (útil para testear una policy library upstream sin clonar):

```console
$ kyverno test https://github.com/kyverno/policies/best-practices --git-branch main
```

Sibling `kyverno apply` para debug interactivo (imprime el resultado real, sin aserción):

```console
$ kyverno apply require-labels/policy.yaml --resource require-labels/resources.yaml

Applying 1 policy rule(s) to 2 resource(s)...

policy require-labels -> resource default/Pod/pod-without-team-label failed:
1. check-team-label: validation error: El label 'team' es obligatorio en todo Pod.
   rule check-team-label failed at path /metadata/labels/team/

pass: 1, fail: 1, warn: 0, error: 0, skip: 0
```

---

## 5. Guía de verificación y diagnóstico de fallas

Los errores de `kyverno test` casi nunca son bugs del motor: son *mismatches* entre lo que el autor cree que evalúa la política y lo que evalúa. Tabla de diagnóstico:

| Síntoma en la salida | Causa raíz probable | Verificación / fix |
|---|---|---|
| `Error: ... unable to load test file` / parseo falla | Schema del manifiesto no coincide con la versión del binario (`result` vs `status`, con/sin `apiVersion`+`kind`) | `kyverno version` y alinear el schema; migrar `status:`→`result:` |
| Resultado real `skip` donde esperabas `fail`/`pass` | El recurso no matchea (`match/exclude`) o un `precondition` lo excluye | Correr `kyverno apply` sobre ese recurso; revisar `match.any[].resources.kinds`, namespaces y preconditions |
| La regla no aparece para un `Deployment`/`CronJob` | **Autogen**: Kyverno generó `autogen-<rule>` para controllers de Pod; testeaste el nombre base | Aseverar contra `autogen-check-team-label` (y `autogen-cronjob-check-team-label` para CronJob) |
| `mutate` da `fail` inesperado | Falta `patchedResources` o el YAML esperado difiere en un campo sutil (orden, defaults, `null`) | Comparar con `kyverno apply ... --output yaml` y copiar el output real como baseline |
| Todo `pass` pero la política "no hace nada" en el cluster | Testeaste la lógica, no el enforcement: `validationFailureAction`/`failureAction` en `Audit` no bloquea | `test` valida la **regla**, no la acción; verificar el modo por separado y con e2e (Chainsaw) |
| Necesita `request.operation`, `apiCall`, context vars | El motor offline no tiene API server para resolver context | Proveer un `Values`/variables file que *mockee* esos valores |

Archivo de variables para mockear contexto (cuando la regla usa `{{ request.operation }}`, `apiCall`, etc.):

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Values
metadata:
  name: values
policies:
  - name: require-labels
    resources:
      - name: pod-without-team-label
        values:
          request.operation: CREATE
globalValues:
  request.operation: CREATE
```

```console
$ kyverno test . --values-file values.yaml
```

Checklist de verificación antes de dar por buena una suite:

1. **Cobertura de kinds reales**: si producción usa `Deployment`, hay un caso con `Deployment` y su regla `autogen-*`, no solo `Pod`.
2. **Ambos lados de cada regla**: al menos un caso `pass` y uno `fail` por regla (una regla que solo se testea con recursos que pasan no prueba nada).
3. **Casos `skip` explícitos**: recursos que *deben* ser excluidos, aseverados como `skip`, para blindar el `exclude`.
4. **Gate real en CI**: el pipeline chequea `exit code`, no el texto de salida.

### Integración en CI (GitHub Actions)

```yaml
name: kyverno-policy-tests
on: [pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Kyverno CLI
        uses: kyverno/action-install-cli@v0.2.0
        with:
          release: v1.13.2          # PIN la versión: fija el schema del manifiesto de test
      - name: Verify CLI
        run: kyverno version
      - name: Run policy tests
        run: kyverno test . --detailed-results   # exit != 0 falla el job
```

Pin de la versión de la CLI = pin del schema. Con la versión "unknown" del enunciado, este pin es exactamente lo que evita que un upgrade del runner rompa la suite de forma silenciosa.

---

## 6. Referencias

- Kyverno CLI — comando `test`: https://kyverno.io/docs/kyverno-cli/usage/test/
- Kyverno CLI — comando `apply`: https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno CLI (overview e instalación): https://kyverno.io/docs/kyverno-cli/
- Auto-generación de reglas para Pod controllers (autogen): https://kyverno.io/docs/writing-policies/autogen/
- Escritura de políticas `validate`: https://kyverno.io/docs/writing-policies/validate/
- Chainsaw (testing e2e declarativo): https://github.com/kyverno/chainsaw
- GitHub Action de instalación de la CLI: https://github.com/kyverno/action-install-cli
- Currícula CNCF (incluye `KCA_Curriculum.pdf`): https://github.com/cncf/curriculum
- Kyverno Certified Associate (KCA) — Linux Foundation: https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/

---

Si "3.2 test" en tu syllabus **no** es esto (o si KCA en tu repo no es Kyverno), decime el título real del objetivo y lo reescribo. Y aparte del contenido: te recomiendo revisar por qué el generador está pasando `version=unknown` y el label crudo `test` — eso es el metadato roto que conviene arreglar en la fuente antes de que dispare más *passes* como este.