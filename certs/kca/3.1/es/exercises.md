# KCA — Tema 3.1: `apply` (Kyverno CLI)

## Ejercicios guiados

El comando `kyverno apply` evalúa una o más políticas de Kyverno contra uno o más recursos e informa el resultado en cinco categorías: **pass**, **fail**, **warn**, **error**, **skip**. Se ejecuta **offline** de forma predeterminada (no requiere cluster, ni admission controller, ni kubeconfig), lo que lo convierte en la herramienta principal para probar políticas en pipelines de CI, hooks de pre-commit y desarrollo local. También puede ejecutarse **contra un cluster en vivo** con `--cluster`.

Estos ejercicios asumen un shell de Unix y la CLI de Kyverno (`kyverno`) en tu `PATH`. No se necesita ningún cluster de Kubernetes salvo donde se indique explícitamente.

> **Una nota sobre el esquema de políticas usado a continuación.** Desde Kyverno 1.11 la acción de validación reside en la regla, en `spec.rules[].validate.failureAction` (valores `Enforce` / `Audit`). El antiguo `spec.validationFailureAction` todavía funciona pero está deprecado. Todos los ejemplos usan la forma moderna por regla.
>
> **Una nota sobre la salida de la CLI.** El texto exacto y el dibujo de la tabla del renderizador varían ligeramente entre versiones de la CLI. El **contrato estable sobre el que se te evalúa** son las cinco categorías de resultado y el **código de salida del proceso** — considerá esos como autoritativos, no la decoración que los rodea.

---

### Ejercicio 0 — Preparación y verificación

1. Confirmá que la CLI está instalada e imprimí su versión:

   ```bash
   kyverno version
   ```

   Salida esperada (los números de versión diferirán):

   ```
   Version: v1.13.2
   Time: 2026-01-14T09:22:01Z
   Git commit ID: a1b2c3d
   ```

2. Creá un directorio de trabajo con dos subcarpetas, una para políticas y otra para recursos:

   ```bash
   mkdir -p kca-apply/policies kca-apply/resources
   cd kca-apply
   ```

3. Creá la primera política, `policies/require-team-label.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     background: false
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Enforce
           message: "The label 'team' is required on every Pod."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

4. Creá dos recursos. `resources/pod-good.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web-good
     labels:
       team: payments
   spec:
     containers:
       - name: nginx
         image: nginx:1.27
   ```

   `resources/pod-bad.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web-bad
   spec:
     containers:
       - name: nginx
         image: nginx:1.27
   ```

**Punto de comprensión**

- **Q0.1** — ¿Necesita `kyverno apply` un cluster en ejecución o un kubeconfig válido para evaluar estos archivos?
- **Q0.2** — En el patrón `team: "?*"`, ¿qué afirma `?*` y en qué se diferencia de `"*"`?

---

### Ejercicio 1 — Una sola política contra un solo recurso

1. Aplicá la política al Pod que cumple:

   ```bash
   kyverno apply policies/require-team-label.yaml --resource resources/pod-good.yaml
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   pass: 1, fail: 0, warn: 0, error: 0, skip: 0
   exit code: 0
   ```

2. Aplicá la misma política al Pod que no cumple:

   ```bash
   kyverno apply policies/require-team-label.yaml --resource resources/pod-bad.yaml
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   policy require-team-label -> resource default/Pod/web-bad failed:
   1. check-team-label: validation error: The label 'team' is required on every Pod. rule check-team-label failed at path /metadata/labels/team/

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

3. Aplicá la política a **ambos** recursos en una sola invocación (el flag `--resource` / `-r` es repetible):

   ```bash
   kyverno apply policies/require-team-label.yaml \
     -r resources/pod-good.yaml \
     -r resources/pod-bad.yaml
   echo "exit code: $?"
   ```

   Resumen esperado:

   ```
   pass: 1, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

**Punto de comprensión**

- **Q1.1** — ¿Cuál es el código de salida del proceso cuando al menos un recurso falla, y por qué este único hecho hace que `kyverno apply` sea usable como gate de CI?
- **Q1.2** — `web-bad` no tiene un `namespace` explícito, y sin embargo la salida lo informa como `default/Pod/web-bad`. ¿De dónde salió `default`?
- **Q1.3** — En el paso 3, un recurso pasó y otro falló. ¿Qué determinó el código de salida general — el pass, el fail, o la cantidad de cada uno?

---

### Ejercicio 2 — Directorios, múltiples políticas y el renderizador de tablas

1. Agregá una segunda política, `policies/disallow-latest-tag.yaml`, esta en modo **Audit**:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: disallow-latest-tag
   spec:
     background: false
     rules:
       - name: require-image-tag
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Audit
           message: "Using the mutable ':latest' tag is not allowed."
           pattern:
             spec:
               containers:
                 - image: "!*:latest"
   ```

2. Agregá un recurso que viola la nueva política, `resources/pod-latest.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web-latest
     labels:
       team: payments
   spec:
     containers:
       - name: nginx
         image: nginx:latest
   ```

3. Aplicá **cada política en `policies/`** a **cada recurso en `resources/`** pasando directorios, y renderizá el resultado como una tabla:

   ```bash
   kyverno apply policies/ --resource resources/ --table
   echo "exit code: $?"
   ```

   Salida esperada (columnas abreviadas):

   ```
   Applying 4 policy rule(s) to 3 resource(s)...

   ┌───┬──────────────────────┬───────────────────┬─────────────────────────┬────────┐
   │ # │ POLICY               │ RULE              │ RESOURCE                │ RESULT │
   ├───┼──────────────────────┼───────────────────┼─────────────────────────┼────────┤
   │ 1 │ require-team-label   │ check-team-label  │ default/Pod/web-good    │ Pass   │
   │ 2 │ require-team-label   │ check-team-label  │ default/Pod/web-bad     │ Fail   │
   │ 3 │ require-team-label   │ check-team-label  │ default/Pod/web-latest  │ Pass   │
   │ 4 │ disallow-latest-tag  │ require-image-tag │ default/Pod/web-good    │ Pass   │
   │ 5 │ disallow-latest-tag  │ require-image-tag │ default/Pod/web-bad     │ Pass   │
   │ 6 │ disallow-latest-tag  │ require-image-tag │ default/Pod/web-latest  │ Fail   │
   └───┴──────────────────────┴───────────────────┴─────────────────────────┴────────┘

   pass: 4, fail: 2, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

4. Para una vista por resultado más rica (incluyendo mensajes), usá `--detailed-results` en lugar de, o junto con, `--table`:

   ```bash
   kyverno apply policies/ --resource resources/ --detailed-results
   ```

**Punto de comprensión**

- **Q2.1** — El encabezado dice "Applying **4** policy rule(s) to **3** resource(s)", y sin embargo la tabla tiene 6 filas. Reconciliá estos números.
- **Q2.2** — `disallow-latest-tag` está en modo **Audit**. En el paso 3 su violación sobre `web-latest` sigue apareciendo como `Fail` y aun así llevó el código de salida a 1. ¿Por qué el modo Audit *no* la suavizó acá? (Anticipa el Ejercicio 3.)
- **Q2.3** — Pasás un directorio que también contiene un `README.md` y un `kustomization.yaml`. ¿Se atragantará `kyverno apply` con ellos? ¿Qué hace con los archivos que no son políticas ni recursos?

---

### Ejercicio 3 — Enforce vs Audit, `--audit-warn` y códigos de salida controlables

Las cinco categorías no son intercambiables, y `warn` existe específicamente para permitir que los hallazgos de Audit sean *visibles sin bloquear*.

1. Ejecutá solo la política de Audit contra el recurso infractor, **sin** ningún flag de suavizado:

   ```bash
   kyverno apply policies/disallow-latest-tag.yaml -r resources/pod-latest.yaml
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

2. Volvé a ejecutar con `--audit-warn`. Esto reclasifica las fallas producidas por reglas en **modo Audit** de `fail` a `warn`:

   ```bash
   kyverno apply policies/disallow-latest-tag.yaml -r resources/pod-latest.yaml --audit-warn
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   pass: 0, fail: 0, warn: 1, error: 0, skip: 0
   exit code: 0
   ```

3. Ahora hacé que las advertencias *también* bloqueen, sin tocar la política — configurá el código de salida devuelto para las advertencias:

   ```bash
   kyverno apply policies/disallow-latest-tag.yaml -r resources/pod-latest.yaml \
     --audit-warn --warn-exit-code 1
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   pass: 0, fail: 0, warn: 1, error: 0, skip: 0
   exit code: 1
   ```

4. Demostrá que `--audit-warn` **no** suaviza una regla **Enforce**. Ejecutá la política Enforce del Ejercicio 1 con el flag:

   ```bash
   kyverno apply policies/require-team-label.yaml -r resources/pod-bad.yaml --audit-warn
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

**Punto de comprensión**

- **Q3.1** — Describí el efecto exacto de `--audit-warn`. ¿Qué reglas toca y cuáles deja intactas?
- **Q3.2** — Querés un job de CI que *informe* los hallazgos de Audit pero *bloquee* solo ante violaciones de Enforce. ¿Qué único flag te da eso, y cuál es el código de salida cuando solo fallan reglas de Audit?
- **Q3.3** — Más adelante, el equipo de plataforma decide que los hallazgos de Audit también deberían bloquear, durante un sprint de hardening — pero te dicen que **no edites ninguna política**. ¿Qué combinación de flags logra esto, y por qué "no editar la política" es una restricción significativa (pensá en la diferencia entre la CLI y el admission controller)?

---

### Ejercicio 4 — Simular contexto de admisión: `--set` y un archivo `Values`

Offline no hay admission request, por lo que variables como `{{ request.operation }}`, `{{ request.userInfo }}` o el contexto de ConfigMap están ausentes. `kyverno apply` te permite **inyectarlas**.

1. Creá una política dependiente del contexto, `policies/require-owner-on-write.yaml`. Solo aplica en operaciones de escritura e incorpora la operación en su mensaje:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-owner-on-write
   spec:
     background: false
     rules:
       - name: check-owner
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         preconditions:
           all:
             - key: "{{ request.operation || 'BACKGROUND' }}"
               operator: NotEquals
               value: DELETE
         validate:
           failureAction: Enforce
           message: "ConfigMaps must carry annotation 'owner' (operation was {{ request.operation }})."
           pattern:
             metadata:
               annotations:
                 owner: "?*"
   ```

2. Creá `resources/cm.yaml` **sin** la anotación `owner`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: app-config
   data:
     LOG_LEVEL: info
   ```

3. Aplicá simulando una operación **CREATE** con `--set` (`-s`), que define una variable global como `key=value`:

   ```bash
   kyverno apply policies/require-owner-on-write.yaml -r resources/cm.yaml \
     --set request.operation=CREATE
   echo "exit code: $?"
   ```

   Salida esperada — la precondición pasa, la validación se ejecuta y falla:

   ```
   policy require-owner-on-write -> resource default/ConfigMap/app-config failed:
   1. check-owner: validation error: ConfigMaps must carry annotation 'owner' (operation was CREATE). ...

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

4. Ahora simulá una operación **DELETE**. La precondición evalúa a false, por lo que la regla se **omite** (skip) en lugar de fallar:

   ```bash
   kyverno apply policies/require-owner-on-write.yaml -r resources/cm.yaml \
     --set request.operation=DELETE
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   pass: 0, fail: 0, warn: 0, error: 0, skip: 1
   exit code: 0
   ```

5. Para cualquier cosa más grande que un par de variables, preferí un **archivo Values** en lugar de apilar flags `--set`. Creá `values.yaml`:

   ```yaml
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Values
   metadata:
     name: values
   globalValues:
     request.operation: DELETE
   ```

   Aplicá con `--values-file` (`-f`):

   ```bash
   kyverno apply policies/require-owner-on-write.yaml -r resources/cm.yaml \
     --values-file values.yaml
   ```

   Esto reproduce el resultado `skip: 1` del paso 4, ahora impulsado por un archivo que podés versionar junto con los tests de la política.

**Punto de comprensión**

- **Q4.1** — Sin `--set` ni un archivo Values, ¿a qué resolvería `{{ request.operation }}` bajo `kyverno apply`, y por qué es prudente el fallback `|| 'BACKGROUND'` en la precondición?
- **Q4.2** — Una precondición fallida produjo `skip`, no `fail`. Contrastá esto con una regla cuyo bloque `match` simplemente no selecciona el recurso — ¿eso también es un `skip`, o está completamente ausente de los conteos?
- **Q4.3** — ¿Cuándo recurrirías a un archivo `Values` (kind `Values`, apiVersion `cli.kyverno.io/v1alpha1`) en lugar de flags `--set` repetidos? Nombrá dos capacidades que el archivo tiene y `--set` no.

---

### Ejercicio 5 — Aplicar una política de mutate: previsualizar el recurso transformado

`apply` no es solo para `validate`. Contra una regla `mutate` imprime el **recurso mutado**, que es la forma de previsualizar una mutación antes de que llegue al cluster.

1. Creá `policies/add-safe-to-evict.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-safe-to-evict
   spec:
     background: false
     rules:
       - name: add-annotation
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         mutate:
           patchStrategicMerge:
             metadata:
               annotations:
                 cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
   ```

2. Aplicala al Pod bueno:

   ```bash
   kyverno apply policies/add-safe-to-evict.yaml -r resources/pod-good.yaml
   ```

   Salida esperada — el YAML emitido ahora lleva la anotación inyectada:

   ```yaml
   Applying 1 policy rule(s) to 1 resource(s)...

   mutate policy add-safe-to-evict applied to default/Pod/web-good:

   apiVersion: v1
   kind: Pod
   metadata:
     annotations:
       cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
     labels:
       team: payments
     name: web-good
     namespace: default
   spec:
     containers:
       - image: nginx:1.27
         name: nginx
   ---
   pass: 1, fail: 0, warn: 0, error: 0, skip: 0
   ```

**Punto de comprensión**

- **Q5.1** — Para una regla `mutate`, ¿qué significa realmente el conteo `pass`? ¿Implica `pass` que el recurso fue rechazado o aceptado?
- **Q5.2** — ¿Cómo usarías este comportamiento en un flujo de trabajo de revisión para permitir que una persona confirme *exactamente* qué hará una mutación antes de mergear la política?

---

### Ejercicio 6 — Salida legible por máquina, excepciones y conexión con CI

1. Emití los resultados como un **PolicyReport** de Kubernetes en lugar de texto para humanos, y escribilo en un archivo:

   ```bash
   kyverno apply policies/ --resource resources/ --policy-report -o report.yaml
   ```

   `report.yaml` (abreviado) usa la API de reportes del Working Group:

   ```yaml
   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: ClusterPolicyReport
   metadata:
     name: merged
   results:
     - policy: require-team-label
       rule: check-team-label
       result: fail
       resources:
         - apiVersion: v1
           kind: Pod
           name: web-bad
           namespace: default
     # ... one entry per policy/rule/resource ...
   summary:
     pass: 4
     fail: 2
     warn: 0
     error: 0
     skip: 0
   ```

2. Suprimí una violación conocida y aceptada con una **PolicyException** en lugar de debilitar la política. Creá `exception.yaml`:

   ```yaml
   apiVersion: kyverno.io/v2
   kind: PolicyException
   metadata:
     name: web-bad-team-label-exception
     namespace: default
   spec:
     exceptions:
       - policyName: require-team-label
         ruleNames:
           - check-team-label
     match:
       any:
         - resources:
             kinds:
               - Pod
             names:
               - web-bad
   ```

   > En versiones de Kyverno anteriores al GA de `kyverno.io/v2`, usá `apiVersion: kyverno.io/v2beta1` — el esquema es idéntico.

3. Aplicá el archivo de excepción con `--exception` (`-e`). El `web-bad` que antes fallaba ahora resuelve a `skip`:

   ```bash
   kyverno apply policies/require-team-label.yaml \
     -r resources/pod-bad.yaml \
     --exception exception.yaml
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   pass: 0, fail: 0, warn: 0, error: 0, skip: 1
   exit code: 0
   ```

4. Conectá todo esto en un gate de CI. Como `apply` devuelve código de salida 1 ante una falla, no se requiere parseo explícito:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   kyverno apply policies/ \
     --resource resources/ \
     --exception exceptions/ \
     --audit-warn \
     --detailed-results
   # Non-zero exit here fails the pipeline stage automatically.
   ```

5. *(Opcional, requiere un cluster.)* En lugar de archivos, evaluá los recursos que están **en vivo en el cluster** con `--cluster`; `-n` acota la búsqueda a un namespace:

   ```bash
   kyverno apply policies/require-team-label.yaml --cluster -n default
   ```

**Punto de comprensión**

- **Q6.1** — Una PolicyException convirtió un `fail` en un `skip`. Argumentá por qué eso es operativamente más seguro que editar `require-team-label` para que deje de coincidir con `web-bad`.
- **Q6.2** — En el script de CI del paso 4, ¿qué hallazgos todavía pueden hacer fallar el build, y cuáles simplemente se imprimen? Rastrealo a través de los flags.
- **Q6.3** — ¿Qué cambia fundamentalmente cuando agregás `--cluster`? Nombrá una cosa que se vuelve cierta offline-vs-cluster (la fuente de los recursos) y una variable que ya no necesita ser simulada.

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 0**

- **Q0.1** — No. `kyverno apply` se ejecuta completamente offline: lee el YAML de políticas y recursos del sistema de archivos y los evalúa en el proceso. Un cluster y un kubeconfig solo intervienen cuando agregás `--cluster` (o cuando una política necesita contexto que proporcionás de otra manera). Esto es precisamente por lo que encaja en el uso en CI y pre-commit.
- **Q0.2** — `?*` es un ancla de patrón de Kyverno que significa "un carácter obligatorio (`?`) seguido de cualquier cantidad de caracteres (`*`)" — es decir, **debe existir un valor no vacío**. El simple `"*"` coincide con cero o más caracteres, por lo que también aceptaría una cadena vacía. `?*` es el idiom para "esta label/anotación debe existir y no estar vacía".

**Ejercicio 1**

- **Q1.1** — El código de salida es **1** siempre que haya al menos un `fail` (y `warn` si optás por ello mediante `--warn-exit-code`). Un código de salida distinto de cero es el contrato universal que todo runner de CI ya entiende, así que `kyverno apply` se convierte en un gate sin parseo de salida: si sale con código distinto de cero, la etapa falla.
- **Q1.2** — Del valor predeterminado de Kyverno. Un recurso con namespace pero sin `metadata.namespace` se trata como si viviera en `default` a efectos de los reportes, reflejando cómo lo ubicaría `kubectl`. El `default` en `default/Pod/web-bad` es ese fallback, no algo que hayas escrito.
- **Q1.3** — La **presencia de cualquier `fail`**, no la proporción. Un solo recurso que falla fuerza el código de salida 1 sin importar cuántos hayan pasado. Un gate es "todo despejado o bloqueado", no "gana la mayoría".

**Ejercicio 2**

- **Q2.1** — "4 policy rule(s)" cuenta las **evaluaciones de reglas descubiertas en todas las políticas**, y "3 resource(s)" cuenta los recursos distintos. Las 6 filas de la tabla son las **combinaciones regla × recurso que efectivamente coincidieron**: dos políticas (una regla cada una) aplicadas a tres Pods = 6 evaluaciones. Los conteos por categoría del encabezado y el número de filas describen cosas distintas.
- **Q2.2** — Porque la CLI no tiene admission controller. Offline, `Audit` vs `Enforce` **no** cambia si algo se informa como falla de forma predeterminada — ambos aparecen como `fail`. La acción solo afecta el comportamiento en tiempo de ejecución del *cluster* (Audit = informar, Enforce = rechazar). Para que la CLI trate las fallas de Audit como no bloqueantes tenés que pedirlo explícitamente con `--audit-warn` (Ejercicio 3).
- **Q2.3** — No se atraganta. `kyverno apply` filtra las entradas por kind: los archivos que no son políticas de Kyverno ni recursos de Kubernetes reconocibles se ignoran. `README.md`, `kustomization.yaml` y archivos similares en un directorio pasado se omiten en lugar de causar un error.

**Ejercicio 3**

- **Q3.1** — `--audit-warn` reclasifica las fallas producidas por reglas en **modo `Audit`** del bucket `fail` al bucket `warn`. **No tiene efecto sobre las reglas en modo `Enforce`** — sus fallas siguen siendo `fail`. Como el código de salida predeterminado para las advertencias es 0, los hallazgos de Audit dejan de bloquear mientras que los de Enforce siguen bloqueando.
- **Q3.2** — `--audit-warn` solo. Cuando solo fallan reglas de Audit, se convierten en `warn`, `fail` queda en 0, y el código de salida es **0** (el build pasa pero las advertencias se imprimen). Las fallas de Enforce seguirían siendo `fail` y saldrían con 1.
- **Q3.3** — `--audit-warn --warn-exit-code 1`: las advertencias todavía se muestran como `warn`, pero el proceso ahora sale con **1** cuando hay cualquier advertencia presente, así que los hallazgos de Audit también bloquean. "No editar la política" importa porque el campo `failureAction` también gobierna el **admission controller en vivo** — cambiar Audit→Enforce ahí empezaría a *rechazar cargas de trabajo reales en el cluster*. Los flags de la CLI cambian solo el veredicto local/de CI, desacoplando "qué tan estricto es CI hoy" de "qué tan estricta es la admisión en producción".

**Ejercicio 4**

- **Q4.1** — Sin definir, `{{ request.operation }}` no tiene valor en modo offline; referenciarlo directamente arriesga un `error` de sustitución. El fallback `|| 'BACKGROUND'` hace que la precondición resuelva de forma determinista (a `BACKGROUND`) cuando no se inyecta ninguna operación, así que la política se degrada con elegancia en lugar de dar error. Cuando *sí* pasás `--set request.operation=CREATE`, ese valor gana.
- **Q4.2** — Son diferentes. Una **precondición fallida** es un `skip` explícito (la regla coincidió pero decidió no actuar). Una regla cuyo **bloque `match` no selecciona el recurso** no se evalúa en absoluto y está **ausente de los conteos** — no es ni pass, ni fail, ni skip. Regla práctica: `skip` = "coincidió, luego se retiró (precondición/excepción)"; no contado = "nunca coincidió".
- **Q4.3** — Recurrí a un archivo `Values` cuando tenés más que un puñado de variables, o cuando los valores deben diferir **por política, por regla o por recurso**, o cuando necesitás simular labels de `namespaceSelector`. Dos cosas que hace y `--set` no puede: (1) acotar valores a una política/regla/recurso específico en lugar de solo globalmente, y (2) proporcionar metadata de `namespaceSelector` para que la coincidencia basada en labels de namespace pueda probarse offline. También es versionable junto con los tests.

**Ejercicio 5**

- **Q5.1** — Para una regla `mutate`, `pass: 1` significa **que la mutación se calculó y aplicó con éxito al recurso** (la regla se ejecutó sin error y produjo un patch). No es un veredicto de aceptar/rechazar — las políticas de mutación transforman, no bloquean — así que `pass` acá se lee como "la transformación tuvo éxito", y el YAML impreso es el objeto resultante.
- **Q5.2** — Ejecutá `kyverno apply <mutate-policy> -r <sample-resources>` en el pull request y adjuntá (o hacé el diff de) el YAML emitido. Quien revisa ve los campos exactos que la mutación agrega/cambia sobre entradas representativas antes de que la política se mergee, detectando bloques `match` demasiado amplios o sobrescrituras no intencionadas mientras todavía es un diff, no un efecto secundario a nivel de todo el cluster.

**Ejercicio 6**

- **Q6.1** — Una `PolicyException` es un objeto acotado, nombrado y auditable: registra *qué* política/regla se exime, para *qué* recurso, y vive en el control de versiones (y, dentro del cluster, es en sí misma gobernable). La política mantiene su intención original y estricta para todos los demás recursos. Editar `require-team-label` para que deje de coincidir con `web-bad` debilita la regla de forma silenciosa y permanente, es fácil de sobre-ampliar, y borra el "por qué" — la excepción preserva la excepción como dato.
- **Q6.2** — Con `--audit-warn`, solo las fallas en modo **Enforce** caen en `fail` y pueden salir con código distinto de cero para hacer fallar el build; las fallas en modo **Audit** se convierten en `warn` y se imprimen pero no bloquean (no se define `--warn-exit-code`). Los recursos cubiertos por archivos en `exceptions/` se convierten en `skip` y nunca bloquean. Entonces: Enforce → bloquea; Audit → impreso; exceptuado → omitido.
- **Q6.3** — `--cluster` cambia la **fuente de los recursos**: en lugar de leer archivos YAML, Kyverno obtiene los objetos en vivo desde el API server (vía kubeconfig), opcionalmente acotados por `-n <namespace>`. Como estás evaluando objetos reales ya admitidos, el contexto derivado del cluster — más notablemente cosas como los namespaces reales de los recursos y su estado existente — ya no necesita ser simulado a mano con `--set`/`--values-file` como sí ocurre offline.

</details>

---

### Fuentes

- Kyverno CLI — referencia del comando `apply`: <https://kyverno.io/docs/kyverno-cli/usage/apply/>
- Kyverno CLI — resumen e instalación: <https://kyverno.io/docs/kyverno-cli/>
- Kyverno — Reglas de validación (Validate) y `failureAction`: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Reglas de mutación (Mutate): <https://kyverno.io/docs/writing-policies/mutate/>
- Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kubernetes Policy WG — API PolicyReport (`wgpolicyk8s.io/v1alpha2`): <https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report>
- CNCF Curriculum (KCA): <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>