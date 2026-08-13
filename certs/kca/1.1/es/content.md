# Kyverno Policies & Rules

> KCA · Domain 1 · Topic 1.1 · Exam weight **4.51%**
> Policy-as-code para el control de admisión, la mutación y la generación de recursos en Kubernetes — escrito como CRDs nativos de Kubernetes.

---

## 1. Motivación: la brecha de control de admisión en clústeres productivos

Un API server de Kubernetes acepta cualquier manifiesto que sea *estructuralmente* válido y pase RBAC. No le importa si tu `Deployment` define límites de recursos, si el tag de la imagen es `:latest`, si `runAsNonRoot` está seteado, o si un namespace nuevo tiene una `NetworkPolicy` de default-deny. En un clúster productivo multi-tenant, esa permisividad es el problema: la brecha entre "el API lo acepta" y "el equipo de plataforma lo considera seguro para ejecutar" es exactamente donde viven los incidentes — un pod sin límite de memoria que hace OOM-kill a sus vecinos del nodo, un tag `:latest` mutable que se corre silenciosamente entre rollouts, un namespace sin aislamiento de red.

Podés cerrar esa brecha en tres lugares:

- **A la izquierda, en CI** — `kubeconform`, `conftest`, `kyverno apply` en un pipeline. Feedback rápido, pero evitable: cualquiera con credenciales `kubectl apply` se saltea CI por completo.
- **En la puerta, en el control de admisión** — un webhook que el API server llama *sincrónicamente* antes de persistir el objeto. Inevitable para todo lo que pasa por el API. Acá viven las reglas `validate`/`mutate` de Kyverno.
- **Después de los hechos, en el reporting** — escaneos en segundo plano de lo que ya está corriendo, expuestos como reportes. Captura la deriva y las violaciones preexistentes que anteceden a la policy.

La apuesta arquitectónica de Kyverno es que la policy debería expresarse como **recursos de Kubernetes en YAML**, usando los mismos idiomas de pattern-matching y overlay que los operadores ya conocen de `kubectl` y de los strategic-merge patches — no como un lenguaje aparte (Rego) con su propio modelo mental. El trade-off es expresividad vs. accesibilidad, y es la comparación central de este topic.

Kyverno corre como un conjunto de controladores dentro del clúster y se registra a sí mismo como objetos dinámicos **`ValidatingWebhookConfiguration`** y **`MutatingWebhookConfiguration`**. Fundamentalmente, **solo registra webhooks para los kinds de recursos que tus policies instaladas realmente referencian** — instalá una policy que matchee solo `Pods` y el API server solo es llamado para pods, no para cada `ConfigMap` y `Secret`. Esto es lo que mantiene acotados la latencia de admisión y el blast radius sobre el API server.

---

## 2. El modelo de objetos: Policy, ClusterPolicy y Rule

Dos kinds de policy y una forma de rule. Todo en este topic es una composición de estos.

```
ClusterPolicy (cluster-scoped)  ─┐
Policy       (namespace-scoped) ─┴─▶ spec.rules[]  ─▶  each rule has exactly ONE action:
                                                        validate | mutate | generate | verifyImages
```

### 2.1 Policy vs. ClusterPolicy

| | `ClusterPolicy` | `Policy` |
|---|---|---|
| API kind | `kyverno.io/v1 · ClusterPolicy` | `kyverno.io/v1 · Policy` |
| Alcance | Todo el clúster, todos los namespaces | Un solo namespace |
| Nombre corto en `kubectl` | `cpol` | `pol` |
| Puede matchear recursos cluster-scoped (Namespace, Node, PV) | Sí | No — solo recursos namespaced dentro de su namespace |
| Owner típico | Equipo de plataforma / seguridad | Equipo de aplicación, guardrails self-service |
| Precedencia | Ambas aplican; un recurso se evalúa contra cada policy que matchee, de cualquiera de los dos kinds | |

**Regla práctica:** los baselines de plataforma son `ClusterPolicy`; las excepciones delegadas y namespace-locales o las reglas específicas de un equipo son `Policy`.

### 2.2 Los cuatro tipos de rule — tabla de decisión

| Tipo de rule | Qué hace | Corre en admisión | Corre en segundo plano | ¿Muta el request? | Uso canónico |
|---|---|---|---|---|---|
| `validate` | Acepta/rechaza o reporta según un pattern o condiciones | ✅ | ✅ (solo reporte) | ❌ | Requerir limits, prohibir `:latest`, aplicar PSA |
| `mutate` | Inyecta/superpone/elimina campos | ✅ | ✅ (mutate-existing) | ✅ | Agregar `securityContext` por defecto, inyectar labels de sidecar |
| `generate` | Crea *otros* recursos cuando aparece un trigger | ✅ (trigger) | ✅ (sync) | ❌ (crea objetos nuevos) | `NetworkPolicy` por defecto, sincronizar `ConfigMap`/`Secret` |
| `verifyImages` | Verifica firmas/attestations de imágenes (Cosign/Notary) | ✅ | ✅ | ✅ (puede agregar digest) | Supply-chain: solo imágenes firmadas |

Una sola policy puede llevar múltiples reglas, pero **cada regla contiene exactamente uno** de estos bloques. Mezclar `validate` y `mutate` en una misma regla es un error de validación.

### 2.3 Anatomía de una rule

```yaml
rules:
  - name: <unique-within-policy>          # required
    match:                                # which resources this rule applies to
      any: | all: [...]
    exclude:                              # carve-outs from the match set
      any: | all: [...]
    preconditions:                        # extra JMESPath gates before the action
      any: | all: [...]
    context: [...]                        # external data: ConfigMap, API call, image data
    validate: {...}  # ─┐
    mutate:   {...}  #  ├─ exactly ONE of these
    generate: {...}  #  │
    verifyImages: [] # ─┘
```

**Los selectores `match`/`exclude`** usan `any` (OR lógico entre bloques) o `all` (AND lógico), cada bloque filtrando por:

- `resources` — `kinds`, `names`, `namespaces`, `selector` (label), `operations` (`CREATE`/`UPDATE`/`DELETE`/`CONNECT`)
- `subjects`, `roles`, `clusterRoles` — la *identidad* que hace el request (desde `AdmissionReview.userInfo`)

---

## 3. `validate` — el núcleo de la aplicación en admisión

### 3.1 `Enforce` vs. `Audit`

Esta es la perilla más consecuente del topic.

| | `Enforce` | `Audit` |
|---|---|---|
| Comportamiento ante una violación | **Bloquea** el request de admisión | **Permite**, registra una entrada de falla en un `PolicyReport` |
| Efecto de cara al estudiante | `kubectl apply` devuelve un error | el apply tiene éxito, la violación es visible en los reportes |
| Uso en rollout productivo | Estado final, tras el soak | Siempre el *primer* estado de una policy nueva — medir el blast radius antes de bloquear |
| Dónde se setea | `spec.validationFailureAction` (v1) **o** por-regla `validate.failureAction` (v2beta1+) | igual |

> **Nota de versión.** En `kyverno.io/v1` el campo es `spec.validationFailureAction` y desde Kyverno **1.10** sus valores van capitalizados `Enforce`/`Audit` (los antiguos en minúscula `enforce`/`audit` todavía parsean con un warning de deprecación). En `kyverno.io/v2beta1`+ la ubicación recomendada es **por regla** bajo `validate.failureAction`, así que distintas reglas de una misma policy pueden enforce-ar o audit-ar de forma independiente. Preferí la forma por-regla para policies nuevas.

**Patrón productivo estándar:** enviá cada policy nueva como `Audit`, observá el conteo de fallas del `PolicyReport` durante un ciclo de release, corregí o exceptuá a los infractores, y después pasá a `Enforce`.

### 3.2 Estilos de validación

Kyverno te da tres formas de expresar "¿es aceptable este recurso?":

1. **`pattern`** — un overlay que el recurso debe matchear (estilo strategic-merge, con anchors).
2. **`anyPattern`** — una lista de patterns; el recurso debe matchear *al menos uno* (OR lógico).
3. **`deny.conditions`** — condiciones JMESPath imperativas; si evalúan a verdadero, se deniega.
4. **`foreach`** — itera una lista (p. ej. `spec.containers`) y aplica `pattern`/`deny` por elemento.
5. **`cel`** — expresiones CEL (Kyverno 1.11+), para paridad con `ValidatingAdmissionPolicy` nativo.

#### Anchors de pattern — la gramática que tenés que saber para el examen

| Anchor | Nombre | Significado |
|---|---|---|
| *(ninguno)* | Default | El campo debe existir y matchear |
| `()` | Conditional | *Si* el campo con anchor matchea, el pattern hermano debe matchear; si no, se saltea |
| `=()` | Equality | El campo **debe** existir e igualar el valor |
| `X()` | Negation | El campo **no** debe existir |
| `^()` | Existence | Para arrays: **al menos un** elemento debe matchear |
| `<()` | Global | Si el anchor matchea *en cualquier lado*, aplicar el pattern a *todos* los elementos |
| `+()` | Add-if-absent | (solo mutate) agregar el valor si el campo falta |

Wildcards dentro de valores string: `*` (cero-o-más chars), `?` (exactamente un char), `?*` (uno-o-más = "no vacío"), y un `!` inicial para negación (`"!*:latest"` = "no debe terminar en `:latest`").

### 3.3 Manifiesto completo — requerir requests y limits de recursos

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-requests-limits
  annotations:
    policies.kyverno.io/title: Require Requests and Limits
    policies.kyverno.io/category: Resource Management
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Audit        # start in Audit; flip to Enforce after soak
  background: true                      # also evaluate pre-existing pods in reports
  rules:
    - name: validate-resources
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          CPU and memory resource requests and limits are required
          for every container.
        pattern:
          spec:
            containers:
              - name: "*"               # applies to every container
                resources:
                  requests:
                    memory: "?*"        # must be non-empty
                    cpu: "?*"
                  limits:
                    memory: "?*"
```

Como la regla matchea `Pod`, la **autogen** de Kyverno la expande silenciosamente a reglas equivalentes para `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob`, `ReplicaSet` y `ReplicationController` — así que escribís la regla del pod una sola vez y se aplica sobre los controladores que crean pods. (Más sobre autogen en §7.)

### 3.4 Manifiesto completo — prohibir el tag `:latest` (y las imágenes sin tag)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "An explicit image tag is required (no untagged images)."
        pattern:
          spec:
            containers:
              - image: "*:*"            # must contain a tag separator
    - name: forbid-latest-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Using the mutable ':latest' tag is not allowed."
        pattern:
          spec:
            containers:
              - image: "!*:latest"      # negation: must NOT end in :latest
```

### 3.5 Manifiesto completo — denegar root con `foreach` + `deny.conditions`

`pattern` es declarativo y limpio para chequeos de forma; `deny.conditions` con JMESPath es la herramienta cuando necesitás lógica booleana, defaults, o razonar sobre campos *ausentes*.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-non-root
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: run-as-non-root
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Containers must set securityContext.runAsNonRoot=true."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  # element.securityContext.runAsNonRoot, defaulting to false if absent
                  - key: "{{ element.securityContext.runAsNonRoot || `false` }}"
                    operator: NotEquals
                    value: true
```

El idioma `|| `false`` es la forma JMESPath de tratar "campo ausente" como "default inseguro" — una fuente clásica de bypasses de policy si te lo olvidás. Un `pattern` por sí solo no puede expresar "campo faltante → falla" sin el anchor de negación; `deny.conditions` lo hace explícito.

#### Operadores JMESPath disponibles en `conditions`/`preconditions`

`Equals`, `NotEquals`, `In`, `NotIn`, `AnyIn`, `AllIn`, `AnyNotIn`, `AllNotIn`, `GreaterThan`, `GreaterThanOrEquals`, `LessThan`, `LessThanOrEquals`, `DurationGreaterThan(OrEquals)`, `DurationLessThan(OrEquals)`.

---

## 4. `mutate` — defaulting y normalización en admisión

La mutación corre **antes** de la validación en la cadena de admisión, así que una regla `mutate` puede aportar un default conforme que una regla `validate` hermana después confirma. Tres motores:

| Motor | Campo | Mejor para |
|---|---|---|
| Strategic-merge | `patchStrategicMerge` | Agregar/superponer campos en tipos conocidos de Kubernetes (usa el anchor `+()`) |
| JSON Patch (RFC 6902) | `patchesJson6902` | `add`/`replace`/`remove` precisos en paths JSON explícitos |
| Iteración | `foreach` | Mutación por-elemento de una lista |

### 4.1 Manifiesto completo — agregar un `securityContext` por defecto (add-if-absent)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-securitycontext
spec:
  rules:
    - name: set-runasnonroot
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"                  # conditional anchor: select every container
                securityContext:
                  +(runAsNonRoot): true      # add-if-absent: never overwrite an explicit value
                  +(allowPrivilegeEscalation): false
```

El anchor `+()` es lo que hace que la mutación sea **no destructiva**: si un workload ya setea `runAsNonRoot: false` deliberadamente (y está exceptuado en otro lado), la mutación lo deja tranquilo en vez de invertirlo silenciosamente.

### 4.2 `patchesJson6902` para ediciones precisas

```yaml
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/labels/team"
            value: "platform"
          - op: replace
            path: "/spec/containers/0/imagePullPolicy"
            value: "Always"
```

**Trade-off:** JSON6902 apunta a índices exactos (`/containers/0/...`) — frágil si el orden del array cambia; usá `foreach` cuando necesites semántica de "cada container" con la precisión de un JSON-patch.

---

## 5. `generate` — recursos acompañantes y corrección de deriva

`generate` crea recursos *nuevos* disparados por la admisión de otro recurso. La feature estrella es **`synchronize: true`**: el recurso generado es poseído y reconciliado por el controlador de segundo plano de Kyverno — editalo o borralo por fuera de banda y se restaura; actualizá la fuente y las copias downstream lo siguen.

### 5.1 Manifiesto completo — `NetworkPolicy` de default-deny para cada namespace nuevo

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-networkpolicy
spec:
  rules:
    - name: create-default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true                 # reconcile if edited/deleted
        data:
          spec:
            podSelector: {}               # all pods in the namespace
            policyTypes:
              - Ingress
              - Egress
```

### 5.2 `clone` en vez de `data` — sincronizar un Secret desde una fuente de verdad

```yaml
      generate:
        apiVersion: v1
        kind: Secret
        name: regcred
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        clone:
          namespace: platform-system
          name: regcred                   # master copy; updates propagate to all clones
```

`background: true` es **obligatorio** para la sincronización — el controlador de segundo plano es lo que reconcilia los clones tras la creación inicial en tiempo de admisión.

---

## 6. Flujo de CLI — instalar, aplicar, testear, inspeccionar

### 6.1 Instalar y confirmar los controladores

```console
$ helm repo add kyverno https://kyverno.github.io/kyverno/
$ helm install kyverno kyverno/kyverno -n kyverno --create-namespace

$ kubectl -n kyverno get pods
NAME                                             READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-7d9f8c6b4-2xqzt     1/1     Running   0          48s
kyverno-background-controller-5c7b9d8f6-l9k2m    1/1     Running   0          48s
kyverno-cleanup-controller-6b8c7d9e4-p4rzn       1/1     Running   0          48s
kyverno-reports-controller-8d6f5c7b9-w7t3q       1/1     Running   0          48s
```

Cuatro controladores, cada uno con un trabajo distinto: **admission** (webhooks), **background** (generate + mutate-existing + escaneos), **reports** (PolicyReports), **cleanup** (TTL de CleanupPolicy).

### 6.2 Aplicar una policy y observar el registro del webhook

```console
$ kubectl apply -f require-requests-limits.yaml
clusterpolicy.kyverno.io/require-requests-limits created

$ kubectl get cpol
NAME                      ADMISSION   BACKGROUND   READY   AGE
require-requests-limits   true        true         True    12s

$ kubectl get validatingwebhookconfigurations | grep kyverno
kyverno-resource-validating-webhook-cfg   2   18s
kyverno-policy-validating-webhook-cfg     1   6m
```

Notá que el webhook de recursos solo aparece **después** de que existe una policy que matchee — registro dinámico en acción. `READY: True` significa que la policy compiló y su webhook está vivo; `False` significa un error de compilación o de webhook que tenés que inspeccionar con `kubectl describe cpol`.

### 6.3 Testear la aplicación contra un pod malo

```console
$ cat pod-bad.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-bad
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      # no resources block

$ kubectl apply -f pod-bad.yaml
Error from server: error when creating "pod-bad.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/default/nginx-bad was blocked due to the following policies

require-requests-limits:
  validate-resources: 'validation error: CPU and memory resource requests and
    limits are required for every container. rule validate-resources failed at path
    /spec/containers/0/resources/'
```

Ese mensaje de denegación — nombre de policy, nombre de regla, el `message`, y el path JSON que falla — es el formato exacto que emite Kyverno y vale la pena reconocerlo en el examen.

### 6.4 Evaluación offline con `kyverno apply` (CI / sin necesidad de clúster)

```console
$ kyverno apply require-requests-limits.yaml --resource pod-bad.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy require-requests-limits -> resource default/Pod/nginx-bad failed:
1. validate-resources: validation error: CPU and memory resource requests and
   limits are required for every container. rule validate-resources failed at
   path /spec/containers/0/resources/

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

### 6.5 El framework `kyverno test` — afirmar resultados esperados

`kyverno-test.yaml` liga policies + recursos + resultados esperados en una suite de regresión:

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-requests-limits
policies:
  - require-requests-limits.yaml
resources:
  - resources.yaml
results:
  - policy: require-requests-limits
    rule: validate-resources
    resource: nginx-bad
    kind: Pod
    result: fail
  - policy: require-requests-limits
    rule: validate-resources
    resource: nginx-good
    kind: Pod
    result: pass
```

```console
$ kyverno test .

Executing require-requests-limits...
│───│──────────────────────────│───────────────────│──────────│────────│
│ ID│ POLICY                   │ RULE              │ RESOURCE │ RESULT │
│───│──────────────────────────│───────────────────│──────────│────────│
│ 1 │ require-requests-limits  │ validate-resources│ nginx-bad│ Pass   │
│ 2 │ require-requests-limits  │ validate-resources│ nginx-good│ Pass  │
│───│──────────────────────────│───────────────────│──────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

(`RESULT: Pass` acá significa "el resultado real coincidió con el resultado *esperado* en `results:`", no que el recurso pasó la policy.)

---

## 7. Autogen: la expansión pod-controlador que no debés pelear

Cuando una regla matchea `Pod`, Kyverno auto-genera reglas paralelas para los controladores que producen pods, prefijándolas con `autogen-`. Por esto una sola policy pod-scoped también bloquea un `Deployment` malo.

```console
$ kubectl get cpol require-requests-limits -o yaml | grep -A2 'autogen'
    pod-policies.kyverno.io/autogen-controllers: DaemonSet,Deployment,Job,StatefulSet,CronFlow...
```

Controlalo con la annotation:

```yaml
metadata:
  annotations:
    pod-policies.kyverno.io/autogen-controllers: none   # disable entirely
    # or restrict: "Deployment,StatefulSet"
```

**Gotcha de diagnóstico:** cuando se rechaza un Deployment, la denegación nombra la regla `autogen-<yourrule>`, no `<yourrule>`. Los estudiantes que escribieron una regla de Pod y ven `autogen-` en el error están mirando la *misma* regla expandida — no una segunda policy.

---

## 8. Verificación y diagnóstico de fallas

### 8.1 ¿Está sana la policy?

```console
$ kubectl get cpol
NAME                      ADMISSION   BACKGROUND   READY   AGE
require-requests-limits   true        true         True    5m

$ kubectl describe cpol require-requests-limits | tail -n 8
Status:
  Conditions:
    Type:    Ready
    Status:  True
  Rule Count:
    Validate:  1
  Autogen:
    Rules:  ...
Events:  <none>
```

`READY: False` → corré `kubectl describe` y leé `Status.Conditions` para ver el error de compilación (JMESPath malo, anchor inválido, kind desconocido).

### 8.2 ¿Qué decidió? — Policy Reports

Los reportes son el registro autoritativo para las policies en `Audit` y los escaneos de segundo plano, almacenados como CRDs `wgpolicyk8s.io/v1alpha2` (estándar del Policy WG, compartido con otros engines).

```console
$ kubectl get polr -A
NAMESPACE   NAME                                   PASS   FAIL   WARN   ERROR   SKIP   AGE
default     e8f3c2a1-4b5d-6e7f-8a9b-0c1d2e3f4a5b   2      1      0       0      0      9m

$ kubectl get clusterpolicyreport
NAME                      PASS   FAIL   WARN   ERROR   SKIP   AGE
clusterpolicyreport       14     2      0       0      0      9m

$ kubectl describe polr e8f3c2a1-4b5d-6e7f-8a9b-0c1d2e3f4a5b | grep -A6 'Results'
Results:
  Message:   validation error: CPU and memory resource requests and limits are required
  Policy:    require-requests-limits
  Rule:      validate-resources
  Result:    fail
  Scored:    true
  Severity:  medium
```

Desde Kyverno 1.10 los reportes son **uno por recurso, nombrado por el UID del recurso** — las vistas agregadas vienen de `kubectl get polr -A` o de la UI de Policy Reporter.

### 8.3 Cuando el webhook mismo se porta mal

El `failurePolicy` del webhook decide qué pasa cuando Kyverno es *inalcanzable* (crasheado, evicted, partición de red):

| `failurePolicy` | Si Kyverno está caído | Riesgo |
|---|---|---|
| `Fail` (default para enforce) | El API server **rechaza** el request | Una caída de Kyverno puede congelar todas las escrituras del clúster — un DoS autoinfligido |
| `Ignore` | El API server **permite** el request | Las policies se saltean silenciosamente durante la caída — una brecha de seguridad |

```console
$ kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].failurePolicy}{"\n"}'
Fail

# Symptom of a Fail-mode outage: EVERY apply times out
$ kubectl apply -f any-pod.yaml
Error from server (InternalError): Internal error occurred: failed calling webhook
"validate.kyverno.svc-fail": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/validate/fail?timeout=10s":
context deadline exceeded
```

Escalera de diagnóstico para ese error: (1) `kubectl -n kyverno get pods` — ¿está el admission controller Running? (2) chequeá el service/endpoints `kubectl -n kyverno get ep kyverno-svc`; (3) tail de logs; (4) si el controlador está realmente trabado y bloqueando el clúster, `kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg` es el break-glass de emergencia (Kyverno lo recrea al recuperarse).

### 8.4 Leer los logs del controlador

```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20 | grep -i error
E1213 ... "failed to load context" err="JMESPath query failed" \
  policy="require-run-as-non-root" rule="run-as-non-root"
```

Un error de JMESPath en los logs pero `READY: True` en la policy significa que la regla compiló pero falla *en tiempo de evaluación* sobre inputs específicos — normalmente un null-dereference que el idioma `|| `default`` arreglaría.

### 8.5 Referencia rápida de diagnóstico

| Síntoma | Causa probable | Primer comando |
|---|---|---|
| Policy creada pero no se aplica nada | `validationFailureAction: Audit` | `kubectl get cpol -o yaml \| grep FailureAction` |
| `cpol` muestra `READY: False` | Error de compilación (anchor/JMESPath/kind) | `kubectl describe cpol <name>` |
| Deployment bloqueado, el error dice `autogen-…` | Expansión autogen de tu regla de Pod | esperado — es la misma regla |
| Todos los applies dan timeout | `failurePolicy: Fail` + Kyverno caído | `kubectl -n kyverno get pods` |
| La mutación no se aplica a pods existentes | mutate-existing necesita `background` + RBAC | chequear logs del background-controller |
| El recurso generado sigue desapareciendo | `synchronize: false` y algo lo borra | setear `synchronize: true` |

---

## 9. Dónde encaja Kyverno: comparación de engines

| | **Kyverno** | **OPA / Gatekeeper** | **ValidatingAdmissionPolicy (nativo)** |
|---|---|---|---|
| Lenguaje | Patterns YAML + JMESPath/CEL | Rego | CEL |
| Instalación | CRDs + controladores | CRDs + controladores | Integrado en el API server (GA 1.30) |
| Validate | ✅ | ✅ | ✅ |
| Mutate | ✅ (nativo) | ⚠️ CRD de mutación aparte | ✅ (MutatingAdmissionPolicy, más nuevo) |
| Generar recursos como side-effect | ✅ | ❌ | ❌ |
| Verificación de imágenes | ✅ (`verifyImages`) | ⚠️ vía datos externos | ❌ |
| Policy reports | ✅ (CRDs del Policy WG) | ✅ (status de constraint) | ⚠️ limitado |
| Runtime extra para operar | Sí (pods de Kyverno) | Sí (pods de Gatekeeper) | **No** — cero componentes extra |
| Curva de aprendizaje | Baja (idiomas Kubernetes-native) | Alta (Rego) | Media (CEL) |
| Mejor cuando | Querés mutate+generate+verify en una sola herramienta Kubernetes-native | Necesitás lógica arbitraria / ya invertiste en Rego | Querés validación sin add-on y estás en ≥1.30 |

**Posicionamiento:** Kyverno gana donde necesitás el *ciclo de vida completo* — validate, mutate, generate y verificación de supply-chain — expresado de la forma en que Kubernetes ya expresa las cosas, al costo de correr sus controladores. `ValidatingAdmissionPolicy` nativo es la elección correcta para validación pura sin footprint operativo; Gatekeeper es la elección cuando tus policies necesitan lógica Turing-completa que solo podés expresar en Rego.

---

## 10. References

- Kyverno — Policies & Rules (concepts): https://kyverno.io/docs/policy-types/cluster-policy/
- Kyverno — Validate rules: https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Mutate rules: https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — Generate rules: https://kyverno.io/docs/writing-policies/generate/
- Kyverno — Match / exclude selectors: https://kyverno.io/docs/writing-policies/match-exclude/
- Kyverno — Preconditions & JMESPath operators: https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — Autogen for pod controllers: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Kyverno — Kyverno CLI (`apply` / `test`): https://kyverno.io/docs/kyverno-cli/
- Kyverno — Installation & controllers: https://kyverno.io/docs/installation/
- Kubernetes — Dynamic admission control (webhooks, `failurePolicy`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes Policy WG — PolicyReport CRDs (`wgpolicyk8s.io`): https://github.com/kubernetes-sigs/wg-policy-prototypes
- CNCF — KCA (Kyverno Certified Associate) curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf