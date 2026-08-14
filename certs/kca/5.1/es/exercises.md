# Ejercicios guiados — Tema 5.1: Validation Rules (Kyverno)

> **Certificación:** Kyverno Certified Associate (KCA) · **Dominio 5 — Validation** · Peso del tema: 2.91
> **Fuente base:** CNCF/Linux Foundation — *KCA Curriculum* → https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
> **Documentación oficial de apoyo:**
> - Validate rules → https://kyverno.io/docs/writing-policies/validate/
> - Preconditions → https://kyverno.io/docs/writing-policies/preconditions/
> - Kyverno CLI (`apply`, `test`) → https://kyverno.io/docs/kyverno-cli/
> - Policy Reports → https://kyverno.io/docs/policy-reports/

Estos ejercicios se probaron con **Kyverno 1.12+** (`apiVersion: kyverno.io/v1`) y **Kubernetes 1.29+**. Toda la mecánica es idéntica en 1.13. Donde una sintaxis cambió entre versiones se aclara en línea.

---

## Requisitos previos (setup, una sola vez)

1. Levantá un cluster efímero (podés usar `kind`):

   ```bash
   kind create cluster --name kca-lab
   ```

2. Instalá Kyverno con Helm (recomendado para el lab; el admission controller queda en HA opcional):

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace --version 3.2.6
   ```

3. Esperá a que el controlador esté listo:

   ```bash
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   ```

   Salida esperada:

   ```
   deployment "kyverno-admission-controller" successfully rolled out
   ```

4. Instalá la **Kyverno CLI** (por Krew):

   ```bash
   kubectl krew install kyverno
   kubectl kyverno version
   ```

   Salida esperada (aprox.):

   ```
   Version: 1.12.5
   Time: 2024-...
   Git commit ID: ...
   ```

5. Creá un namespace de trabajo:

   ```bash
   kubectl create namespace kca-51
   ```

**Preguntas de verificación**

- **Q0.1** ¿Qué componente de Kyverno intercepta las peticiones a la API de Kubernetes para las validation rules, y a través de qué objeto nativo del API server se registra?
- **Q0.2** Si el `kyverno-admission-controller` está caído, ¿qué determina si una petición `CREATE Pod` es aceptada o rechazada?

---

## Ejercicio 1 — Tu primera validation rule con `pattern` (modo Audit)

**Objetivo:** exigir un label obligatorio usando *pattern matching* (overlay), primero sin bloquear.

1. Guardá la política en `01-require-labels.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     background: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           # A partir de Kyverno 1.11 la acción se declara por-regla.
           # Enforce = bloquea en admission; Audit = solo reporta.
           failureAction: Audit
           message: "El label `team` es obligatorio en todos los Pods."
           pattern:
             metadata:
               labels:
                 team: "?*"      # ?* = al menos un carácter (no vacío)
   ```

2. Aplicá la política y verificá que quedó `Ready`:

   ```bash
   kubectl apply -f 01-require-labels.yaml
   kubectl get clusterpolicy require-team-label
   ```

   Salida esperada:

   ```
   NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
   require-team-label   true        true         True    5s    Ready
   ```

3. Creá un Pod **sin** el label:

   ```bash
   kubectl -n kca-51 run nginx --image=nginx:1.27
   ```

   Observá que el Pod **se crea igual** (estamos en `Audit`):

   ```
   pod/nginx created
   ```

4. Inspeccioná el resultado en el PolicyReport del namespace:

   ```bash
   kubectl -n kca-51 get policyreport -o wide
   kubectl -n kca-51 get policyreport -o yaml | grep -A6 'result: fail'
   ```

   Salida esperada (fragmento):

   ```yaml
       message: 'validation error: El label `team` es obligatorio en todos los Pods.
         rule check-team-label failed at path /metadata/labels/team/'
       policy: require-team-label
       result: fail
       rule: check-team-label
   ```

5. Ahora creá un Pod **con** el label y confirmá que pasa:

   ```bash
   kubectl -n kca-51 run web --image=nginx:1.27 --labels="team=payments"
   kubectl -n kca-51 get policyreport -o yaml | grep -B2 -A2 'result: pass'
   ```

**Preguntas de verificación**

- **Q1.1** ¿Qué diferencia hay entre `"?*"`, `"*"` y `"*?"` como valor de pattern? ¿Cuál usás para "cualquier valor no vacío"?
- **Q1.2** En modo `Audit`, ¿dónde se registra el fallo y qué NO ocurre respecto a la petición del usuario?
- **Q1.3** El campo `background: true` habilita el escaneo periódico de recursos ya existentes. ¿Por qué una regla que use `{{ request.userInfo.username }}` no puede evaluarse en un escaneo de background?

---

## Ejercicio 2 — Modo `Enforce`: bloqueo real en admission

**Objetivo:** ver la diferencia práctica entre `Audit` y `Enforce`, y leer la salida de un webhook que deniega.

1. Editá la política para que la regla bloquee. Cambiá **solo** `failureAction`:

   ```bash
   kubectl patch clusterpolicy require-team-label --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]'
   ```

2. Intentá crear un Pod sin el label:

   ```bash
   kubectl -n kca-51 run bad --image=nginx:1.27
   ```

   Salida esperada (la petición es **denegada**):

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/kca-51/bad was blocked due to the following policies

   require-team-label:
     check-team-label: 'validation error: El label `team` es obligatorio en todos los
       Pods. rule check-team-label failed at path /metadata/labels/team/'
   ```

3. Confirmá que el Pod anterior sin label (`nginx`, creado en el Ej. 1) **sigue existiendo**: `Enforce` no borra recursos preexistentes, solo bloquea nuevas peticiones.

   ```bash
   kubectl -n kca-51 get pod nginx
   ```

4. Probá un *override* por namespace: exceptuá `kube-system` de la aplicación estricta.

   ```yaml
   # Reemplazá el bloque validate de la regla por:
         validate:
           failureAction: Enforce
           failureActionOverrides:
             - action: Audit
               namespaces:
                 - kube-system
           message: "El label `team` es obligatorio en todos los Pods."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   Aplicá de nuevo con `kubectl apply -f 01-require-labels.yaml`.

**Preguntas de verificación**

- **Q2.1** El webhook que aparece en el error se llama `validate.kyverno.svc-fail`. ¿Qué implica el sufijo `-fail` sobre la `failurePolicy` del `ValidatingWebhookConfiguration`, y qué pasaría si el controlador de Kyverno no responde?
- **Q2.2** ¿Por qué `Enforce` no elimina el Pod `nginx` que ya existía sin label? ¿Qué mecanismo de Kyverno usarías para detectar recursos preexistentes no conformes?
- **Q2.3** Con `failureActionOverrides`, ¿qué acción efectiva tiene la regla sobre un Pod de `kube-system` y sobre uno de `kca-51`?

---

## Ejercicio 3 — Anchors: `()` condicional, `=()` igualdad y `X()` negación

**Objetivo:** dominar los anchors, que son la parte del pattern matching que más se confunde en el examen.

1. Creá `03-anchors.yaml` con el ejemplo canónico de **conditional anchor** `()`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: latest-requires-always
   spec:
     rules:
       - name: latest-pull-always
         match:
           any:
             - resources:
                 kinds: [Pod]
         validate:
           failureAction: Enforce
           message: "Si la imagen usa el tag `latest`, imagePullPolicy debe ser Always."
           pattern:
             spec:
               containers:
                 # (image) es un conditional anchor:
                 # SOLO si el valor coincide con "*:latest",
                 # se exige que los elementos hermanos (imagePullPolicy) validen.
                 - (image): "*:latest"
                   imagePullPolicy: Always
   ```

2. Aplicá y probá los dos caminos:

   ```bash
   kubectl apply -f 03-anchors.yaml

   # a) imagen con :latest y pullPolicy incorrecta -> BLOQUEA
   kubectl -n kca-51 run c1 --image=nginx:latest \
     --overrides='{"spec":{"containers":[{"name":"c1","image":"nginx:latest","imagePullPolicy":"IfNotPresent"}]}}'
   ```

   Salida esperada:

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   ...
   latest-pull-always: 'validation error: Si la imagen usa el tag `latest`,
     imagePullPolicy debe ser Always. rule latest-pull-always failed at path
     /spec/containers/0/imagePullPolicy/'
   ```

   ```bash
   # b) imagen con tag fijo -> el anchor no dispara, se PERMITE aunque pullPolicy no sea Always
   kubectl -n kca-51 run c2 --image=nginx:1.27 --labels=team=infra
   ```

   Salida esperada: `pod/c2 created`.

3. Agregá una segunda regla que use **equality anchor** `=()` y **negation anchor** `X()`. Añadila a `spec.rules`:

   ```yaml
       - name: securitycontext-hardening
         match:
           any:
             - resources:
                 kinds: [Pod]
         validate:
           failureAction: Audit
           message: "Reglas de securityContext no cumplidas."
           pattern:
             spec:
               containers:
                 - name: "*"
                   # =() igualdad: si securityContext EXISTE, entonces
                   # readOnlyRootFilesystem (si existe) debe ser true.
                   =(securityContext):
                     =(readOnlyRootFilesystem): true
                     # X() negación: la clave privileged NO debe estar presente.
                     X(privileged): true
   ```

4. Reaplicá y revisá los reportes de background:

   ```bash
   kubectl apply -f 03-anchors.yaml
   kubectl -n kca-51 get policyreport -o wide
   ```

**Preguntas de verificación**

- **Q3.1** Explicá con precisión la diferencia entre el conditional anchor `()` y el equality anchor `=()`. ¿Cuál "gatea" a los elementos hermanos y cuál solo restringe su propia clave?
- **Q3.2** En el paso 2b, el Pod `c2` con `nginx:1.27` se permitió aunque no declara `imagePullPolicy: Always`. ¿Por qué? ¿Qué habría pasado con `nginx` (sin tag, que Kubernetes interpreta como `:latest`)?
- **Q3.3** ¿Qué hace el negation anchor `X(privileged)` y en qué se diferencia de escribir `privileged: false`?
- **Q3.4** Nombrá el existence anchor `^()` y el global anchor `<()`. ¿Para qué sirve `^()` dentro de una lista?

---

## Ejercicio 4 — `deny` con `conditions` y JMESPath

**Objetivo:** validar lógica que un `pattern` no puede expresar (comparaciones numéricas, relaciones entre campos), usando `deny` + `conditions`.

1. Creá `04-deny-replicas.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: limit-replicas
   spec:
     rules:
       - name: max-3-replicas
         match:
           any:
             - resources:
                 kinds: [Deployment]
         # preconditions: gatea SI la regla se ejecuta (antes de validar)
         preconditions:
           all:
             - key: "{{ request.operation }}"
               operator: AnyIn
               value: [CREATE, UPDATE]
         validate:
           failureAction: Enforce
           message: >-
             Un Deployment no puede superar 3 réplicas
             (solicitaste {{ request.object.spec.replicas }}).
           deny:
             conditions:
               any:
                 - key: "{{ request.object.spec.replicas }}"
                   operator: GreaterThan
                   value: 3
   ```

2. Aplicá y probá:

   ```bash
   kubectl apply -f 04-deny-replicas.yaml
   kubectl -n kca-51 create deployment big --image=nginx:1.27 --replicas=5
   ```

   Salida esperada:

   ```
   error: failed to create deployment: admission webhook "validate.kyverno.svc-fail"
   denied the request:

   resource Deployment/kca-51/big was blocked due to the following policies

   limit-replicas:
     max-3-replicas: Un Deployment no puede superar 3 réplicas (solicitaste 5).
   ```

3. Confirmá que 3 réplicas pasan:

   ```bash
   kubectl -n kca-51 create deployment ok --image=nginx:1.27 --replicas=3
   ```

   Salida esperada: `deployment.apps/ok created`.

4. (Diagnóstico) Mirá cómo Kyverno resolvió las variables. Subí el nivel de log del admission controller y reproducí el bloqueo:

   ```bash
   kubectl -n kyverno logs deploy/kyverno-admission-controller | grep -i "max-3-replicas" | tail -n 3
   ```

**Preguntas de verificación**

- **Q4.1** ¿Cuál es la diferencia semántica entre un `precondition` y un `deny.conditions`? Si la condición de un `precondition` no se cumple, ¿la regla falla o se salta (skip)?
- **Q4.2** El bloque `conditions` acepta `any` y `all`. Describí la lógica booleana de cada uno y qué pasa si combinás ambos en la misma condición.
- **Q4.3** ¿Por qué se usa `deny` aquí en lugar de `pattern`? Da un caso concreto que `pattern` no puede validar.
- **Q4.4** ¿Qué operador usarías para exigir que `spec.replicas` esté dentro del conjunto `{1,2,3}` en una sola condición?

---

## Ejercicio 5 — `foreach`: validar cada elemento de una lista

**Objetivo:** aplicar una validación a **todos** los containers de un Pod, algo que un `pattern` con `- name: "*"` cubre parcialmente pero que `foreach` expresa con mensajes por-elemento y lógica más rica.

1. Creá `05-foreach-no-latest.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: disallow-latest-tag
   spec:
     rules:
       - name: require-image-tag
         match:
           any:
             - resources:
                 kinds: [Pod]
         validate:
           failureAction: Enforce
           message: "Todas las imágenes deben llevar un tag inmutable (no `latest`)."
           foreach:
             - list: "request.object.spec.containers"
               # dentro de foreach, {{ element }} es cada item de la lista
               pattern:
                 # el prefijo ! niega: la imagen NO debe terminar en :latest
                 image: "!*:latest"
             - list: "request.object.spec.initContainers || `[]`"
               pattern:
                 image: "!*:latest"
   ```

2. Aplicá y probá un Pod multi-container donde **uno** viola la regla:

   ```bash
   kubectl apply -f 05-foreach-no-latest.yaml

   cat <<'EOF' | kubectl -n kca-51 apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: multi
     labels: { team: data }
   spec:
     containers:
       - name: app
         image: nginx:1.27
       - name: sidecar
         image: busybox:latest      # <- viola
   EOF
   ```

   Salida esperada:

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/kca-51/multi was blocked due to the following policies

   disallow-latest-tag:
     require-image-tag: 'validation error: Todas las imágenes deben llevar un tag
       inmutable (no `latest`). rule require-image-tag[0] failed at path
       /spec/containers/1/image/'
   ```

3. Corregí el sidecar a `busybox:1.36` y confirmá que ahora pasa.

**Preguntas de verificación**

- **Q5.1** ¿Qué expresa el patrón `image: "!*:latest"`? Enumerá otros operadores que Kyverno admite en valores de pattern (además de `!`).
- **Q5.2** ¿Por qué en el segundo `foreach` se escribe `request.object.spec.initContainers || \`[]\``? ¿Qué pasaría con la evaluación si el Pod no tiene `initContainers` y no incluyéramos ese fallback?
- **Q5.3** Dentro de un bloque `foreach`, ¿a qué hace referencia la variable `{{ element }}` y `{{ elementIndex }}`? ¿En qué se diferencia de iterar con `- name: "*"` en un `pattern` clásico?

---

## Ejercicio 6 — Validación con CEL (`validate.cel`)

**Objetivo:** escribir la misma restricción del Ej. 4 con **Common Expression Language**, la vía alineada con las `ValidatingAdmissionPolicy` nativas de Kubernetes.

1. Creá `06-cel-replicas.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: limit-replicas-cel
   spec:
     rules:
       - name: max-3-replicas-cel
         match:
           any:
             - resources:
                 kinds: [Deployment]
         validate:
           failureAction: Enforce
           cel:
             expressions:
               # object = el recurso entrante; comparación evaluada por CEL
               - expression: "object.spec.replicas <= 3"
                 message: "Un Deployment no puede superar 3 réplicas."
   ```

2. Aplicá y probá:

   ```bash
   kubectl apply -f 06-cel-replicas.yaml
   kubectl -n kca-51 create deployment big-cel --image=nginx:1.27 --replicas=7
   ```

   Salida esperada:

   ```
   error: failed to create deployment: admission webhook "validate.kyverno.svc-fail"
   denied the request:

   resource Deployment/kca-51/big-cel was blocked due to the following policies

   limit-replicas-cel:
     max-3-replicas-cel: Un Deployment no puede superar 3 réplicas.
   ```

3. Añadí un `messageExpression` dinámico y una `variable` reutilizable. Reemplazá el bloque `cel`:

   ```yaml
           cel:
             variables:
               - name: replicas
                 expression: "object.spec.replicas"
             expressions:
               - expression: "variables.replicas <= 3"
                 messageExpression: >-
                   'Máximo permitido: 3 réplicas, se solicitaron ' +
                   string(variables.replicas) + '.'
   ```

   Reaplicá y volvé a intentar `--replicas=7`; ahora el mensaje incluye el número solicitado.

**Preguntas de verificación**

- **Q6.1** En una expresión CEL de Kyverno, ¿qué representan las variables `object`, `oldObject` y `request`? ¿Cuál usarías para comparar el estado nuevo contra el anterior en un `UPDATE`?
- **Q6.2** ¿Qué ventaja tiene `messageExpression` sobre `message`? ¿Por qué `string(variables.replicas)` requiere la conversión explícita?
- **Q6.3** La validación CEL de Kyverno se parece mucho a la `ValidatingAdmissionPolicy` nativa de Kubernetes. Nombrá dos capacidades que Kyverno agrega por encima de la VAP nativa (pensá en generación de reportes y en autogeneración de reglas).

---

## Ejercicio 7 — Testing offline: `kyverno apply` y `kyverno test`

**Objetivo:** validar políticas en CI **sin** cluster ni admission controller, usando la CLI. Esto es evaluado explícitamente en el examen.

1. Preparate un recurso de prueba `resources.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-sin-label
   spec:
     containers:
       - name: app
         image: nginx:1.27
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-con-label
     labels: { team: payments }
   spec:
     containers:
       - name: app
         image: nginx:1.27
   ```

2. Ejecutá la política del Ej. 1 contra esos recursos con `kyverno apply`:

   ```bash
   kubectl kyverno apply 01-require-labels.yaml --resource resources.yaml
   ```

   Salida esperada:

   ```
   Applying 1 policy rule(s) to 2 resource(s)...

   policy require-team-label -> resource default/Pod/pod-sin-label failed:
   1. check-team-label: validation error: El label `team` es obligatorio en todos
      los Pods. rule check-team-label failed at path /metadata/labels/team/

   pass: 1, fail: 1, warn: 0, error: 0, skip: 0
   ```

3. Ahora escribí un test declarativo reproducible. Creá `kyverno-test.yaml`:

   ```yaml
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Test
   metadata:
     name: require-team-label-test
   policies:
     - 01-require-labels.yaml
   resources:
     - resources.yaml
   results:
     - policy: require-team-label
       rule: check-team-label
       kind: Pod
       resources: [pod-con-label]
       result: pass
     - policy: require-team-label
       rule: check-team-label
       kind: Pod
       resources: [pod-sin-label]
       result: fail
   ```

4. Corré la suite:

   ```bash
   kubectl kyverno test .
   ```

   Salida esperada (aprox.):

   ```
   Loading test  ( kyverno-test.yaml ) ...
     Loading values/variables ...
     Loading policies ...
     Loading resources ...
     Applying 1 policy to 2 resources ...
     Checking results ...

   │───│───────────────────│──────────────────│─────────────────────────│────────│
   │ ID│ POLICY            │ RULE             │ RESOURCE                │ RESULT │
   │───│───────────────────│──────────────────│─────────────────────────│────────│
   │ 1 │ require-team-label│ check-team-label │ default/Pod/pod-con-label│ Pass   │
   │ 2 │ require-team-label│ check-team-label │ default/Pod/pod-sin-label│ Pass   │
   │───│───────────────────│──────────────────│─────────────────────────│────────│

   Test Summary: 2 tests passed and 0 tests failed
   ```

5. (Experimento) Cambiá en `kyverno-test.yaml` el `result: fail` del `pod-sin-label` por `pass` y volvé a correr. El summary debe reportar `1 tests failed`, demostrando que el test detecta cuando la política deja de comportarse como esperás.

**Preguntas de verificación**

- **Q7.1** En el paso 4, la fila 2 (`pod-sin-label`) dice `RESULT: Pass` aunque la política **falla** sobre ese Pod. Explicá por qué eso es correcto: ¿qué está comparando `kyverno test`?
- **Q7.2** ¿Qué diferencia práctica hay entre `kyverno apply` y `kyverno test`? ¿Cuál usarías en un pipeline de CI para evitar regresiones y por qué?
- **Q7.3** ¿Por qué estas herramientas no requieren un admission webhook ni contactar la API de Kubernetes? ¿Qué limitación tiene eso frente a variables como `{{ request.userInfo }}`?

---

## Limpieza

```bash
kubectl delete clusterpolicy require-team-label latest-requires-always \
  securitycontext-hardening limit-replicas disallow-latest-tag limit-replicas-cel \
  --ignore-not-found
kubectl delete namespace kca-51 --ignore-not-found
kind delete cluster --name kca-lab
```

---

## Respuestas

<details>
<summary>Mostrar / ocultar soluciones</summary>

### Ejercicio 0 — Setup

**Q0.1** El **admission controller** de Kyverno (`kyverno-admission-controller`). Se registra ante el API server mediante un objeto **`ValidatingWebhookConfiguration`** (para las validation rules) que Kyverno crea y mantiene dinámicamente según las políticas instaladas. Cada petición mutante/validante pasa por la fase de *admission* del API server, que llama al webhook por HTTPS.

**Q0.2** Lo determina la **`failurePolicy`** del `ValidatingWebhookConfiguration`. Kyverno crea webhooks con dos sufijos: `...svc-fail` (`failurePolicy: Fail`) para las reglas en `Enforce` y `...svc-ignore` (`failurePolicy: Ignore`) para las de `Audit`. Si el controlador está caído: las peticiones cubiertas por el webhook `Fail` son **rechazadas** por el API server (fail-closed); las cubiertas por el `Ignore` se **admiten** sin evaluar (fail-open). Por eso mantener HA del admission controller importa cuando hay reglas en `Enforce`.

### Ejercicio 1 — pattern / Audit

**Q1.1** En pattern matching de Kyverno `*` = cero o más caracteres, `?` = exactamente un carácter. Entonces:
- `"*"` acepta también el string vacío → **no** sirve para "no vacío".
- `"?*"` = un carácter obligatorio seguido de cero o más → **al menos un carácter** → es el idiomático para "presente y no vacío".
- `"*?"` es equivalente a `"?*"` en la práctica (también exige ≥1 carácter), pero `"?*"` es la forma convencional en la documentación.
Para "cualquier valor no vacío": **`"?*"`**.

**Q1.2** El fallo se registra en un **`PolicyReport`** (namespaced) o **`ClusterPolicyReport`** (cluster-scoped), como una entrada con `result: fail`. Lo que **NO** ocurre: la petición del usuario **no se bloquea**; el recurso se crea/actualiza normalmente. `Audit` es observabilidad, no *enforcement*.

**Q1.3** Un escaneo de **background** aplica la política a recursos que **ya existen** en `etcd`, fuera de una petición de admission. En ese contexto **no hay `AdmissionReview`**, por lo tanto no existe `request.userInfo`, `request.operation`, `request.roles`, etc. Kyverno **omite** en background las reglas que dependen de esas variables (y de hecho valida que no las uses si querés que corran en background). Solo `request.object` / datos del propio recurso están disponibles.

### Ejercicio 2 — Enforce

**Q2.1** El sufijo `-fail` indica que ese `ValidatingWebhookConfiguration` tiene **`failurePolicy: Fail`** (fail-closed). Si el controlador de Kyverno no responde (timeout, pods caídos), el API server **rechaza** las peticiones que caen bajo ese webhook. Es el trade-off de seguridad de `Enforce`: garantiza que ninguna petición esquive la política, a costa de acoplar la disponibilidad del cluster a la de Kyverno (mitigable con réplicas y `namespaceSelector`/exclusiones de namespaces críticos).

**Q2.2** Porque la validation rule solo actúa en la **fase de admission** de **nuevas** peticiones (`CREATE`/`UPDATE`); no reconcilia retroactivamente el estado existente. El Pod `nginx` entró antes de `Enforce`, así que ya está en `etcd`. Para detectar preexistentes no conformes se usa el **background scan** + **PolicyReports** (`kubectl get policyreport -A`), que evalúa lo que ya vive en el cluster sin borrarlo.

**Q2.3** `X(privileged): true` → *no responde a esta pregunta*; ver Q3.3. Para Q2.3: con `failureActionOverrides: [{action: Audit, namespaces: [kube-system]}]`, un Pod en `kube-system` se evalúa en modo **Audit** (solo reporta, no bloquea) y uno en `kca-51` se evalúa en modo **Enforce** (bloquea). Es la forma de tener enforcement global pero excluir namespaces de sistema para no romper el cluster.

### Ejercicio 3 — Anchors

**Q3.1** 
- **Conditional `()`**: es un *gate condicional sobre los hermanos*. Si la clave existe **y su valor coincide** con el pattern, entonces Kyverno **exige validar los elementos hermanos** (peers) del mismo nivel. Si el valor no coincide, **todo el bloque hermano se salta**. Ej: `(image): "*:latest"` → solo si la imagen es `latest` se exige `imagePullPolicy: Always`.
- **Equality `=()`**: opera **sobre su propia clave**. Si la clave **existe**, su valor **debe** coincidir con el pattern; si no existe, se ignora. **No** gatea a los hermanos.
Resumen: `()` condiciona a los **hermanos**; `=()` restringe únicamente a **sí misma**.

**Q3.2** Porque el valor de `image` en `c2` es `nginx:1.27`, que **no** coincide con `"*:latest"`, así que el conditional anchor **no dispara** y la restricción sobre `imagePullPolicy` nunca se evalúa. Con `nginx` **sin tag**: Kubernetes lo normaliza a `nginx:latest`, pero **el valor almacenado en el spec en el momento de admission puede ser `nginx` a secas** (la mutación del default de imagen no siempre ocurre antes del webhook), por lo que el anchor `"*:latest"` podría **no** matchear el string `nginx`. Por eso, en producción, para cazar el `latest` implícito se usa una regla que también contemple imágenes **sin tag** (p. ej. con `deny`/CEL sobre el parseo del tag), no solo el sufijo `:latest`.

**Q3.3** `X(privileged): true` es un **negation anchor**: exige que la clave `privileged` **no esté presente** en el recurso (su valor de referencia es irrelevante; lo que se valida es la *ausencia de la clave*). En cambio `privileged: false` exige que la clave **exista y valga `false`** — un Pod que **omite** `privileged` **fallaría** contra `privileged: false` pero **pasaría** contra `X(privileged)`. Negación = "prohibido que exista"; igualdad = "si aparece/o debe aparecer, con este valor".

**Q3.4** 
- **Existence `^()`**: se usa **dentro de listas/arrays**; exige que **al menos un** elemento de la lista satisfaga el sub-pattern (semántica "existe uno que...").
- **Global `<()`**: gatea la **regla entera**. Si el valor anclado con `<()` coincide, se valida todo el pattern; si no, se saltea la regla completa (útil combinado con `foreach` para condicionar globalmente).

### Ejercicio 4 — deny / conditions

**Q4.1** Un **`precondition`** decide **si la regla se ejecuta**: si sus condiciones no se cumplen, la regla se **saltea** (`skip`), **no** falla. Un **`deny.conditions`** es la **lógica de validación en sí**: si sus condiciones se cumplen, la petición se **deniega** (fail). Es decir, `precondition` = filtro de aplicabilidad; `deny.conditions` = criterio de rechazo. En el ejercicio, si la operación no es `CREATE`/`UPDATE`, la regla se saltea; si lo es y `replicas > 3`, se deniega.

**Q4.2** 
- **`all`**: verdadero solo si **todas** las condiciones del bloque son verdaderas (AND lógico).
- **`any`**: verdadero si **al menos una** es verdadera (OR lógico).
Si combinás `any` **y** `all` en el mismo `conditions`, el resultado es `any` **AND** `all` (ambos bloques deben dar verdadero; internamente cada uno con su propia semántica OR/AND).

**Q4.3** Porque `pattern` hace *overlay/structural matching* de valores y wildcards, pero **no evalúa comparaciones numéricas ni relaciones**. `replicas > 3`, `replicas` dentro de un rango, "el `limits.cpu` debe ser ≥ `requests.cpu`", o "la fecha de expiración es futura" **no** se expresan con pattern; requieren `deny.conditions` con operadores (`GreaterThan`, etc.) o CEL.

**Q4.4** El operador **`AnyIn`** (o `In`): `key: "{{ request.object.spec.replicas }}"`, `operator: AnyIn`, `value: [1,2,3]`. (Como es `deny`, la condición de *rechazo* sería la negación: para exigir que esté en el set, denegás con `AnyNotIn: [1,2,3]`.)

### Ejercicio 5 — foreach

**Q5.1** `image: "!*:latest"` = el valor de `image` **no** debe matchear `*:latest`, es decir la imagen **no** puede terminar en el tag `latest` (el prefijo `!` niega el pattern). Otros operadores admitidos en valores de pattern de Kyverno: `>` , `<`, `>=`, `<=` (comparaciones numéricas/cantidades), `|` (OR entre valores, p. ej. `"1|2|3"`), y combinaciones como `">1024"` para puertos. También `-` para rangos en algunos contextos.

**Q5.2** `request.object.spec.initContainers || \`[]\`` usa el operador JMESPath `||` para dar un **fallback a lista vacía** cuando `initContainers` es `null`/ausente. Si no lo incluyeras y el Pod **no** tuviera `initContainers`, el `list:` del `foreach` se resolvería a `null` y la iteración **fallaría o produciría un `error`** en la evaluación de esa regla (Kyverno no puede iterar sobre `null`). Con `|| \`[]\`` itera cero veces y la regla pasa limpiamente.

**Q5.3** Dentro de `foreach`, `{{ element }}` es **el item actual** de la `list` en cada iteración (p. ej. cada objeto container) y `{{ elementIndex }}` es su **índice** (0, 1, 2…). La diferencia con `- name: "*"` en un pattern clásico: el `foreach` te da **contexto por-elemento** (podés usar `element`/`elementIndex` en mensajes, `deny`, JMESPath y hasta otro nivel de validación), reporta el índice exacto que falló, y permite lógica no expresable como overlay; `- name: "*"` solo hace matching estructural uniforme sin acceso individual al elemento.

### Ejercicio 6 — CEL

**Q6.1** 
- `object`: el recurso **entrante** (el estado nuevo que se está admitiendo).
- `oldObject`: el estado **previo** del recurso (poblado solo en `UPDATE`/`DELETE`; es `null` en `CREATE`).
- `request`: el `AdmissionRequest` completo (`request.operation`, `request.userInfo`, `request.namespace`, etc.).
Para comparar nuevo vs. anterior en un `UPDATE` usás **`oldObject`** frente a `object` (p. ej. `object.spec.replicas >= oldObject.spec.replicas` para impedir reducir réplicas).

**Q6.2** `messageExpression` permite construir el mensaje **dinámicamente** con CEL, incrustando valores reales del recurso (el número solicitado, el nombre, etc.), mientras que `message` es un string estático (o con variables `{{ }}` limitadas). `string(variables.replicas)` necesita la conversión explícita porque CEL es **tipado**: `replicas` es un entero y el operador `+` sobre strings exige que **todos** los operandos sean `string`; concatenar un `int` sin convertir es un error de tipo en CEL.

**Q6.3** Sobre la `ValidatingAdmissionPolicy` nativa, Kyverno agrega, entre otras: (1) **generación automática de Policy Reports** (`PolicyReport`/`ClusterPolicyReport`) y modo **Audit** con historial, que la VAP nativa no produce; (2) **autogen** de reglas para Pod controllers (Deployment/DaemonSet/StatefulSet/CronJob…) a partir de una regla escrita para `Pod`; (3) **background scanning** de recursos preexistentes; (4) `PolicyException` y una experiencia unificada (mutación, generación, verificación de imágenes) en el mismo motor. La VAP nativa solo hace validación de admisión, sin reportes ni escaneo retroactivo.

### Ejercicio 7 — CLI testing

**Q7.1** `kyverno test` **no** valida "el recurso cumple la política"; valida "**el resultado de aplicar la política coincide con el `result` esperado que declaré**". En `kyverno-test.yaml` declaraste que `pod-sin-label` debe dar `result: fail`. Cuando Kyverno lo evalúa y efectivamente **falla**, eso **coincide** con lo esperado ⇒ el test se marca **`Pass`**. Es un test de *comportamiento de la política*, no del recurso.

**Q7.2** 
- **`kyverno apply`**: ejecuta políticas contra recursos y te **muestra el resultado real** (pass/fail/warn/skip). Es exploratorio/ad-hoc.
- **`kyverno test`**: compara el resultado real contra **expectativas declaradas** (`results:`) y devuelve exit code ≠ 0 si difieren.
Para **CI** usás **`kyverno test`**, porque falla el pipeline (regresión detectada) cuando una política deja de comportarse como esperás — es asertivo y reproducible, no requiere lectura humana de la salida.

**Q7.3** Porque ambas herramientas **evalúan el motor de políticas de Kyverno localmente**, cargando políticas y recursos desde archivos YAML; no hay `AdmissionReview` real ni llamada al API server. Limitación: variables que solo existen en una petición de admisión real — **`request.userInfo`**, `request.roles`, `request.operation` (salvo que la inyectes), datos de otros recursos vía API lookups — **no están disponibles** o hay que **simularlas** con un archivo de `values`/`variables` (`--values-file`). Por eso políticas dependientes de identidad/RBAC requieren datos de test explícitos para cubrirse offline.

</details>