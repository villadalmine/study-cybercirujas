# 5.9 Autogen Rules

**Dominio 5 — Escritura y operación de políticas · Peso en el examen: 2.91**

---

## 1. Motivación: el problema arquitectónico que resuelve autogen

### 1.1 El Pod es el punto de aplicación, pero nadie crea Pods

En un clúster real, el Pod es una *salida*, no una *entrada*. El objeto que envía una persona o un pipeline de CI es un `Deployment`, un `StatefulSet`, un `CronJob`, un `Rollout` de Argo, un release de Helm. El Pod se materializa varios saltos de controlador después:

```
user ──apply──> Deployment ──deployment-controller──> ReplicaSet ──replicaset-controller──> Pod
user ──apply──> CronJob    ──cronjob-controller────> Job        ──job-controller────────> Pod
```

Cada uno de esos saltos es una petición `CREATE` distinta al API server y, por lo tanto, una revisión de admisión distinta. Esto produce tres modos de fallo diferenciados que quien escribe políticas tiene que razonar explícitamente.

**Modo de fallo A — escribís la regla solo contra `Pod`.**
El `Deployment` se admite. `kubectl apply` devuelve éxito. CI queda en verde. Se crea el ReplicaSet. Después, el *controlador de ReplicaSet* intenta crear el Pod, Kyverno lo deniega, y el fallo queda enterrado en `ReplicaSet.status.conditions` y en un evento `FailedCreate`. Tres consecuencias, todas malas en producción:

- **Fallo parcial silencioso.** El estado declarado se acepta; el estado en ejecución nunca converge. Las herramientas de GitOps reportan `Synced/Healthy` sobre el Deployment mientras existen cero Pods o —peor— el ReplicaSet anterior sigue sirviendo tráfico y nadie se entera durante días.
- **Atribución equivocada.** La petición denegada la hace `system:serviceaccount:kube-system:replicaset-controller`. Tu log de auditoría, tu `PolicyReport` y tus alertas apuntan todos a un controlador del sistema, no a la persona que empujó el cambio.
- **Amplificación por reintentos.** El controlador de ReplicaSet reintenta con backoff, indefinidamente. Un único Deployment malo se convierte en un flujo permanente de revisiones de admisión, eventos y ruido de reconciliación.

**Modo de fallo B — escribís la regla solo contra los controladores.**
Los Pods sueltos evitan la política por completo — y los Pods sueltos son exactamente lo que va a usar quien tenga RBAC de `create pods` con intenciones de atacar, y exactamente lo que producen `kubectl run`, `kubectl debug` y muchos operadores. Además tenés que escribir a mano la misma lógica contra tres profundidades de anidamiento distintas (`spec.containers`, `spec.template.spec.containers`, `spec.jobTemplate.spec.template.spec.containers`), duplicada entre seis o siete kinds. Eso es N× las reglas, N× el drift y N× la probabilidad de que la variante de `Job` diverja calladamente de la de `Deployment` después de una refactorización.

**Modo de fallo C — escribís las dos a mano.**
Correcto, e imposible de mantener. Una política de "requerir `runAsNonRoot`" se convierte en unas 180 líneas de YAML casi duplicado. Quienes revisan dejan de leerlo.

### 1.2 Qué hace realmente autogen

El subsistema de **auto-generación** de Kyverno resuelve esto a nivel del controlador y no a nivel de la autoría. Escribís **una** regla que coincide con `Pod`. El controlador de políticas de Kyverno sintetiza entonces reglas derivadas para los controladores de pods, realizando dos transformaciones mecánicas:

1. **Reescritura del match** — `kinds: [Pod]` se convierte en `kinds: [DaemonSet, Deployment, Job, StatefulSet, ...]` en una regla derivada, y en `kinds: [CronJob]` en una segunda (CronJob necesita su propia regla por el nivel extra de anidamiento `jobTemplate`).
2. **Reescritura de rutas** — cada ruta relativa al pod spec en el patrón de `validate`, el parche de `mutate`, el bloque `verifyImages`, las precondiciones y las entradas de contexto se reenraíza bajo `spec.template` (o `spec.jobTemplate.spec.template`).

Las reglas derivadas son **reglas reales, evaluadas**. No son documentación. Aparecen en `status.autogen.rules`, aparecen por nombre en los resultados de `PolicyReport` y en los mensajes de denegación y —esto es crítico— determinan el contenido de los `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration` gestionados dinámicamente por Kyverno. **Autogen determina por lo tanto el radio de alcance de tu webhook**, lo que lo convierte en un asunto de latencia y disponibilidad, no solo de ergonomía.

### 1.3 La consecuencia de segundo orden: mutación y rollouts

Para las reglas `mutate` la elección no es meramente cosmética, y esta es la parte que más gente se equivoca:

- Una mutación aplicada al **controlador** modifica `spec.template.spec`, lo que cambia el hash del pod-template, lo que **dispara una actualización rodante** y es **visible en `kubectl get deploy -o yaml`**. Tu herramienta de GitOps va a ver el drift y puede pelearse con vos salvo que configures `ignoreDifferences`.
- Una mutación aplicada **solo al Pod** no causa rollout ni drift, pero es invisible en el objeto declarado y se reaplica silenciosamente en cada recreación de Pod. Si Kyverno alguna vez no está disponible o se borra la política, los Pods de reemplazo arrancan *sin* la mutación — una regresión de seguridad lenta y silenciosa.

Ninguna de las dos es correcta universalmente. Autogen hace que la elección sea explícita y controlable; la anotación es donde la expresás.

---

## 2. Comparación técnica y compromisos

### 2.1 Dónde aplicar

| Estrategia | Pods sueltos cubiertos | Controladores cubiertos | Fallo visible para quien lo envía | Cantidad de reglas | Carga del webhook | Uso típico |
|---|---|---|---|---|---|---|
| Match solo `Pod`, autogen **deshabilitado** | Sí | No (la denegación llega tarde, al crear el Pod) | No — enterrado en eventos `FailedCreate` | 1 | Solo Pods (la menor) | Reglas *intrínsecamente* a nivel de Pod (`nodeName`, `ephemeralContainers`, campos inyectados por el scheduler) |
| Match solo controladores, escrito a mano | **No** | Sí | Sí | 6–7 | Solo controladores | Reglas sobre campos propios del controlador (`replicas`, `updateStrategy`, `podManagementPolicy`) |
| Match `Pod` + controladores, escrito a mano | Sí | Sí | Sí | 7–8, duplicadas | La mayor | Nunca, si autogen puede hacerlo |
| Match `Pod`, **autogen por defecto** | Sí | Sí | Sí | 1 autorada, 2 generadas | Pods + todos los controladores de pods | **Opción por defecto** para cualquier regla a nivel de pod spec |
| Match `Pod`, autogen con **lista restringida** | Sí | Solo los kinds listados | Sí, para los kinds listados | 1 autorada, 1–2 generadas | Reducida | Clústeres que prohíben directamente algunos kinds de workload, o donde la latencia del webhook sobre un kind caliente es inaceptable |

### 2.2 La anotación `pod-policies.kyverno.io/autogen-controllers`

La superficie de control para `ClusterPolicy` / `Policy` (API v1 de Kyverno) es una única anotación en los **metadatos de la política** — no en la regla.

| Valor de la anotación | Efecto | Cuándo usarlo |
|---|---|---|
| *(ausente)* | Kyverno aplica su conjunto de controladores por defecto incorporado | Casi siempre |
| `Deployment,StatefulSet` | Genera reglas **solo** para los kinds listados | Realmente prohibís `DaemonSet`/`CronJob` mediante RBAC o una política aparte, y querés una huella de webhook menor |
| `none` | Autogen totalmente deshabilitado para **toda la política** (todas sus reglas) | Semántica exclusiva de Pod, o escribiste a mano las reglas de los controladores |
| Un kind que no está en la lista conocida de Kyverno | Se ignora — Kyverno solo conoce los controladores de pods incorporados | Los CRD personalizados (`Rollout`, `CloneSet`) **no** son objetivos de autogen; esas reglas se escriben explícitamente |

> **No memorices el conjunto de controladores por defecto.** Ha cambiado entre releases menores de Kyverno (en particular respecto de si `ReplicaSet` y `ReplicationController` están en el conjunto por defecto). El conjunto que usa tu clúster es descubrible — leé `status.autogen.rules` sobre una política aplicada, como se muestra en §4.2. Tratar el valor por defecto como una constante fija es la fuente más común del "la política pasó en staging y dejó pasar el workload en prod".

### 2.3 Soporte por tipo de regla

| Tipo de regla | Comportamiento de autogen | Notas para producción |
|---|---|---|
| `validate.pattern` / `anyPattern` | Soportado completamente | El caso más confiable; el patrón se reenraíza bajo `spec.template` |
| `validate.deny` con `conditions` | Soportado, pero el JMESPath/CEL que escribiste a mano contra `request.object.spec.*` **hay que** revisarlo — la reescritura de expresiones escritas a mano es la parte frágil |
| `validate.podSecurity` | Soportado | Preferible a los patrones PSS hechos a mano precisamente porque autogen y la subregla se mantienen juntos |
| `validate.cel` | Soportado en versiones recientes | Verificá el CEL generado en `status.autogen.rules`, no en la documentación |
| `mutate.patchStrategicMerge` | Soportado | Acordate del efecto secundario del rollout (§1.3) |
| `mutate.patchesJson6902` | **Frágil** — los punteros JSON son absolutos, y reenraizarlos no siempre es correcto | Preferí el strategic merge, o poné `autogen-controllers: none` y escribí las reglas de los controladores explícitamente |
| `verifyImages` | Soportado | Autogen es lo que hace que la verificación de firmas cubra Deployments y no solo Pods |
| `generate` | **No aplica** — las reglas generate crean recursos, no inspeccionan pod specs | Nunca esperes salida de autogen acá |

### 2.4 Mapa de reescritura de rutas

Esta tabla es el modelo mental que necesitás para leer un mensaje de denegación y saber qué regla generada se disparó.

| Ruta en tu regla de `Pod` | Deployment / DaemonSet / StatefulSet / Job / ReplicaSet / ReplicationController | CronJob |
|---|---|---|
| `metadata.labels` | `spec.template.metadata.labels` | `spec.jobTemplate.spec.template.metadata.labels` |
| `metadata.annotations` | `spec.template.metadata.annotations` | `spec.jobTemplate.spec.template.metadata.annotations` |
| `spec.containers[]` | `spec.template.spec.containers[]` | `spec.jobTemplate.spec.template.spec.containers[]` |
| `spec.initContainers[]` | `spec.template.spec.initContainers[]` | `spec.jobTemplate.spec.template.spec.initContainers[]` |
| `spec.ephemeralContainers[]` | `spec.template.spec.ephemeralContainers[]` | `spec.jobTemplate.spec.template.spec.ephemeralContainers[]` |
| `spec.volumes[]` | `spec.template.spec.volumes[]` | `spec.jobTemplate.spec.template.spec.volumes[]` |
| `spec.securityContext` | `spec.template.spec.securityContext` | `spec.jobTemplate.spec.template.spec.securityContext` |
| `spec.serviceAccountName` | `spec.template.spec.serviceAccountName` | `spec.jobTemplate.spec.template.spec.serviceAccountName` |

### 2.5 Nombrado de las reglas generadas — memorizalo, es relevante para el examen y para el diagnóstico

| Nombre de la regla autorada | Generada para controladores estándar | Generada para CronJob |
|---|---|---|
| `validate-image-tag` | `autogen-validate-image-tag` | `autogen-cronjob-validate-image-tag` |

Los prefijos `autogen-` y `autogen-cronjob-` aparecen textualmente en:

- los mensajes de denegación de admisión,
- `results[].rule` de `PolicyReport` / `ClusterPolicyReport`,
- el bloque `results:` de un manifiesto `Test` de la CLI de Kyverno,
- la salida de `kyverno apply`.

Un `kyverno test` que afirma `rule: validate-image-tag` contra un recurso `Deployment` **va a fallar**, porque la regla que realmente se disparó es `autogen-validate-image-tag`. Esta es la causa número uno de CI en rojo sobre una política por lo demás correcta.

---

## 3. Manifiestos completos

### 3.1 Política base que se apoya en el autogen por defecto

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-pinned-image-tags
  annotations:
    policies.kyverno.io/title: Require pinned image tags
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Mutable tags such as ':latest' make a rollout non-reproducible and defeat
      admission-time image verification. This policy is authored once against
      Pod; Kyverno auto-generates the equivalent rules for pod controllers.
    # No pod-policies.kyverno.io/autogen-controllers annotation:
    # the built-in default controller set applies. Read status.autogen.rules
    # after applying to confirm which kinds your Kyverno version covers.
spec:
  validationFailureAction: Enforce   # Kyverno >=1.12 also supports the
                                     # per-rule spec.rules[].validate.failureAction
  background: true
  rules:
    - name: validate-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          The mutable tag ':latest' is not allowed. Pin an immutable tag or,
          preferably, a digest (image@sha256:...).
        pattern:
          spec:
            containers:
              - image: "!*:latest"

    - name: require-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          An explicit image tag or digest is required; untagged images resolve
          to ':latest' implicitly.
        pattern:
          spec:
            containers:
              - image: "*:*"
```

Esto autora 2 reglas y produce 4 reglas generadas: `autogen-validate-image-tag`, `autogen-cronjob-validate-image-tag`, `autogen-require-image-tag`, `autogen-cronjob-require-image-tag`.

### 3.2 Restringir el conjunto de controladores generados

Usá esto cuando el contrato de workloads del clúster realmente excluye algunos kinds y querés una lista `rules[].resources` del webhook más acotada.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-nonroot-runtime
  annotations:
    policies.kyverno.io/title: Require non-root runtime
    # Explicit, reviewable, and reduces the webhook match set.
    # DaemonSet is deliberately excluded: node-level agents in this cluster
    # are exempted through a dedicated policy with a namespaceSelector.
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,Job,CronJob
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-runasnonroot
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          Containers must run as a non-root user. Set
          securityContext.runAsNonRoot=true at the pod or container level.
        anyPattern:
          - spec:
              securityContext:
                runAsNonRoot: true
              containers:
                - securityContext:
                    runAsNonRoot: "true | *"
          - spec:
              containers:
                - securityContext:
                    runAsNonRoot: true
```

### 3.3 Deshabilitar autogen deliberadamente (`none`)

Un campo a nivel de Pod que **no tiene sentido** en la plantilla de un controlador, combinado con una precondición para que la regla juzgue solamente los Pods que la persona creó directamente:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-direct-node-binding
  annotations:
    policies.kyverno.io/title: Forbid explicit spec.nodeName
    policies.kyverno.io/description: >-
      spec.nodeName bypasses the scheduler entirely, defeating taints,
      topology spread and every scheduling guardrail. It is set legitimately
      only by the scheduler itself, on an already-created Pod.
    # Autogen is disabled: a controller template that sets nodeName is a
    # separate, rarer problem handled by its own rule, and generating
    # Deployment/CronJob variants here would only widen the webhook for no gain.
    pod-policies.kyverno.io/autogen-controllers: none
spec:
  validationFailureAction: Enforce
  background: false        # nodeName is always set on running Pods; a
                           # background scan would flag every Pod in the cluster
  rules:
    - name: deny-nodename-on-create
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
      preconditions:
        all:
          # Only judge Pods that a user submitted directly. Controller-created
          # Pods are covered by the controller-level policies.
          - key: "{{ request.object.metadata.ownerReferences[0].kind || '' }}"
            operator: Equals
            value: ""
      validate:
        message: >-
          Setting spec.nodeName directly bypasses the scheduler and is not
          permitted. Use nodeSelector, affinity or tolerations.
        deny:
          conditions:
            all:
              - key: "{{ request.object.spec.nodeName || '' }}"
                operator: NotEquals
                value: ""
```

### 3.4 Una regla mutate, y su consecuencia sobre el rollout

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-seccomp-runtimedefault
  annotations:
    policies.kyverno.io/title: Default seccompProfile to RuntimeDefault
    # Autogen ON (default). The mutation lands in spec.template.spec on
    # controllers, which is durable across Pod recreation but CHANGES the
    # pod-template hash and therefore triggers one rolling update per workload
    # the first time this policy is applied. Roll it out in a maintenance window.
spec:
  rules:
    - name: set-runtimedefault-seccomp
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            +(securityContext):
              +(seccompProfile):
                type: RuntimeDefault
```

El ancla add-if-not-present `+()` es esencial acá: sin ella, el parche sobrescribiría un perfil `Localhost` puesto intencionalmente.

### 3.5 Antipatrón: hacer match de `Pod` **y** de un controlador en la misma regla

```yaml
# ANTI-PATTERN — do not copy.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: broken-mixed-match
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-labels
      match:
        any:
          - resources:
              kinds:
                - Pod
                - Deployment     # <-- this is what breaks it
      validate:
        message: "app.kubernetes.io/name label is required"
        pattern:
          metadata:
            labels:
              app.kubernetes.io/name: "?*"
```

Se rompen dos cosas. Primero, autogen queda suprimido para una regla que hace match de kinds más allá de `Pod` — Kyverno no va a sintetizar variantes, así que `StatefulSet`, `DaemonSet`, `Job` y `CronJob` quedan **sin cubrir**. Segundo, el único patrón `metadata.labels` ahora se evalúa contra las etiquetas *propias del Deployment* en lugar de las de la plantilla de pod, lo cual es una afirmación distinta de la que querías hacer. La forma correcta es §3.1: hacer match solo de `Pod` y dejar que autogen produzca las variantes correctamente enraizadas.

### 3.6 `verifyImages` con autogen

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-internal-registry-signatures
  annotations:
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet,Job,CronJob
spec:
  validationFailureAction: Enforce
  background: false          # signature verification is an admission-time concern
  webhookTimeoutSeconds: 30  # cosign verification is network-bound; the default 10s
                             # is not enough when the registry is remote
  rules:
    - name: verify-signed-images
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "registry.internal.example.com/*"
          failureAction: Enforce
          verifyDigest: true
          required: true
          mutateDigest: true    # rewrites tag -> digest in the admitted object
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEXAMPLEPUBLICKEYDATAGOESHERE
                      REPLACEWITHYOURREALCOSIGNPUBLICKEYBASE64ENCODEDVALUEXXXXXXXX==
                      -----END PUBLIC KEY-----
                    rekor:
                      url: https://rekor.sigstore.dev
```

Fijate cómo `mutateDigest: true` interactúa con autogen: en un `Deployment`, el digest se escribe en `spec.template.spec.containers[].image`, lo que —de nuevo— cambia el hash del pod-template. Eso es deseable (el digest fijado queda ahora en el objeto declarado) pero hay que conciliarlo con tu herramienta de GitOps.

### 3.7 Test de la CLI de Kyverno que afirma los nombres de las reglas generadas

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-pinned-image-tags
policies:
  - policy.yaml
resources:
  - resources.yaml
results:
  # Authored rule — fires on a bare Pod.
  - policy: require-pinned-image-tags
    rule: validate-image-tag
    kind: Pod
    resources:
      - bad-pod
    result: fail

  # Generated rule for standard controllers.
  - policy: require-pinned-image-tags
    rule: autogen-validate-image-tag
    kind: Deployment
    resources:
      - bad-deployment
    result: fail

  - policy: require-pinned-image-tags
    rule: autogen-validate-image-tag
    kind: StatefulSet
    resources:
      - good-statefulset
    result: pass

  # Generated rule for CronJob — different prefix, different path depth.
  - policy: require-pinned-image-tags
    rule: autogen-cronjob-validate-image-tag
    kind: CronJob
    resources:
      - bad-cronjob
    result: fail
```

---

## 4. Recorrido por la CLI con salida real de terminal

> Las salidas de abajo son de Kyverno 1.13.x sobre Kubernetes v1.31. El formato de los mensajes y el conjunto de controladores por defecto varían entre releases — reproducilas en tu propio clúster en lugar de confiar en la transcripción.

### 4.1 Aplicar la política

```console
$ kubectl apply -f require-pinned-image-tags.yaml
clusterpolicy.kyverno.io/require-pinned-image-tags created

$ kubectl get clusterpolicy require-pinned-image-tags
NAME                        ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
require-pinned-image-tags   true        true         Enforce           True    8s    Ready
```

`READY=True` significa que el controlador de políticas terminó de calcular las reglas de autogen **y** que la configuración de webhook del API server convergió. Una política que nunca llega a Ready no está aplicando nada.

### 4.2 Leer las reglas generadas — la verdad de fondo

```console
$ kubectl get clusterpolicy require-pinned-image-tags \
    -o jsonpath='{range .status.autogen.rules[*]}{.name}{"\n"}{end}'
autogen-validate-image-tag
autogen-cronjob-validate-image-tag
autogen-require-image-tag
autogen-cronjob-require-image-tag
```

Y los kinds que cada una cubre realmente — **así es como descubrís el conjunto de controladores por defecto de tu versión**:

```console
$ kubectl get clusterpolicy require-pinned-image-tags -o yaml \
    | yq '.status.autogen.rules[] | {"rule": .name, "kinds": .match.any[0].resources.kinds}'
rule: autogen-validate-image-tag
kinds:
  - DaemonSet
  - Deployment
  - Job
  - StatefulSet
  - ReplicaSet
  - ReplicationController
rule: autogen-cronjob-validate-image-tag
kinds:
  - CronJob
...
```

Inspeccioná el patrón reescrito para confirmar la profundidad de la ruta:

```console
$ kubectl get clusterpolicy require-pinned-image-tags -o yaml \
    | yq '.status.autogen.rules[1].validate.pattern'
spec:
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - image: '!*:latest'
```

### 4.3 Confirmar que el webhook se amplió

```console
$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules[*].resources}{"\n"}{end}'
validate.kyverno.svc-ignore	[]
validate.kyverno.svc-fail	["cronjobs","daemonsets","deployments","jobs","pods","replicasets","replicationcontrollers","statefulsets"]
```

Si falta `deployments` en esa lista, autogen no ocurrió — ninguna cantidad de depuración de la política va a ayudar hasta que eso se arregle.

### 4.4 Aplicación a nivel del controlador (autogen funcionando)

```console
$ kubectl create deployment web --image=nginx:latest
error: failed to create deployment: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Deployment/default/web was blocked due to the following policies

require-pinned-image-tags:
  autogen-validate-image-tag: 'validation error: The mutable tag '':latest'' is not
    allowed. Pin an immutable tag or, preferably, a digest (image@sha256:...). rule
    autogen-validate-image-tag failed at path /spec/template/spec/containers/0/image/'
```

Quien lo envía recibe un error inmediato, atribuible y accionable en el momento del `kubectl`. Compará con la ruta del CronJob:

```console
$ kubectl create cronjob backup --image=busybox --schedule="0 3 * * *" -- /bin/true
error: failed to create cronjob: admission webhook "validate.kyverno.svc-fail" denied the request:

resource CronJob/default/backup was blocked due to the following policies

require-pinned-image-tags:
  autogen-cronjob-require-image-tag: 'validation error: An explicit image tag or digest
    is required; untagged images resolve to '':latest'' implicitly. rule autogen-cronjob-require-image-tag
    failed at path /spec/jobTemplate/spec/template/spec/containers/0/image/'
```

Nombre de regla distinto, profundidad de ruta distinta — ambos derivados de la misma regla autorada de ocho líneas.

### 4.5 El contrafáctico: autogen deshabilitado

```console
$ kubectl annotate clusterpolicy require-pinned-image-tags \
    pod-policies.kyverno.io/autogen-controllers=none --overwrite
clusterpolicy.kyverno.io/require-pinned-image-tags annotated

$ kubectl create deployment web --image=nginx:latest
deployment.apps/web created                        # <-- admitted!

$ kubectl get deploy,rs,pod -l app=web
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   0/1     0            0           18s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-6f9c7d8b7d   1         0         0       18s

$ kubectl describe rs web-6f9c7d8b7d | tail -12
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  4s (x5 over 18s)   replicaset-controller  Error creating: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/web-6f9c7d8b7d- was blocked due to the following policies

require-pinned-image-tags:
  validate-image-tag: 'validation error: The mutable tag '':latest'' is not allowed.
    Pin an immutable tag or, preferably, a digest (image@sha256:...). rule validate-image-tag
    failed at path /spec/containers/0/image/'
```

Esta transcripción **es** la motivación de toda la funcionalidad. `kubectl` reportó éxito, el Deployment existe, `READY 0/1`, y el error real está a tres llamadas de `kubectl describe` de distancia, atribuido a `replicaset-controller`, reintentando para siempre. Restaurá la anotación:

```console
$ kubectl annotate clusterpolicy require-pinned-image-tags \
    pod-policies.kyverno.io/autogen-controllers- --overwrite
clusterpolicy.kyverno.io/require-pinned-image-tags annotated
```

### 4.6 Evaluación offline con la CLI

```console
$ kyverno version
Version: 1.13.2
Time: 2025-02-11T09:41:03Z
Git commit ID: main/9d1f0a7

$ kyverno apply require-pinned-image-tags.yaml --resource bad-deployment.yaml

Applying 2 policy rule(s) to 1 resource(s)...

policy require-pinned-image-tags -> resource default/Deployment/web failed:
1. autogen-validate-image-tag: validation error: The mutable tag ':latest' is not allowed.
Pin an immutable tag or, preferably, a digest (image@sha256:...). rule autogen-validate-image-tag
failed at path /spec/template/spec/containers/0/image/

pass: 0, fail: 1, warn: 0, error: 0, skip: 3
```

```console
$ kyverno test .

Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 2 policy rule(s) to 4 resource(s) ...
  Checking results ...

│────│───────────────────────────│───────────────────────────────────│─────────────────────────│────────│
│ ID │ POLICY                    │ RULE                              │ RESOURCE                │ RESULT │
│────│───────────────────────────│───────────────────────────────────│─────────────────────────│────────│
│ 1  │ require-pinned-image-tags │ validate-image-tag                │ v1/Pod/bad-pod          │ Pass   │
│ 2  │ require-pinned-image-tags │ autogen-validate-image-tag        │ apps/v1/Deployment/...  │ Pass   │
│ 3  │ require-pinned-image-tags │ autogen-validate-image-tag        │ apps/v1/StatefulSet/... │ Pass   │
│ 4  │ require-pinned-image-tags │ autogen-cronjob-validate-image-tag│ batch/v1/CronJob/...    │ Pass   │
│────│───────────────────────────│───────────────────────────────────│─────────────────────────│────────│

Test Summary: 4 tests passed and 0 tests failed
```

(Acá `RESULT: Pass` significa "el resultado observado coincidió con el `result:` que afirmaste" — incluidos los `fail` afirmados.)

### 4.7 Los reportes del escaneo en background también llevan los nombres generados

```console
$ kubectl get policyreport -n production -o yaml \
    | yq '.items[].results[] | select(.policy=="require-pinned-image-tags") | {"rule": .rule, "kind": .resources[0].kind, "name": .resources[0].name, "result": .result}'
rule: autogen-validate-image-tag
kind: Deployment
name: legacy-api
result: fail
rule: validate-image-tag
kind: Pod
name: legacy-api-7c8d9f4b6c-x2knp
result: fail
```

Fijate en el **hallazgo duplicado**: el Deployment falla por la regla generada y su Pod falla por la regla autorada. Eso es esperado y correcto —ambos objetos incumplen— pero cualquier dashboard que cuente resultados `fail` crudos va a sobre-reportar. Deduplicá por owner reference, o contá violaciones por workload de nivel superior.

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Escalera de verificación

Ejecutá estos pasos en orden; cada escalón es barato y cada uno descarta una clase distinta de error.

| # | Pregunta | Comando | Esperado |
|---|---|---|---|
| 1 | ¿La política fue aceptada y convergió? | `kubectl get cpol <name>` | `READY True` |
| 2 | ¿Se generaron reglas siquiera? | `kubectl get cpol <name> -o jsonpath='{.status.autogen.rules[*].name}'` | No vacío, con nombres `autogen-*` presentes |
| 3 | ¿Qué kinds están cubiertos? | `yq '.status.autogen.rules[].match.any[0].resources.kinds'` | El conjunto que pretendías |
| 4 | ¿La profundidad de la ruta es la correcta? | `yq '.status.autogen.rules[].validate.pattern'` | `spec.template.spec...` / `spec.jobTemplate.spec.template.spec...` |
| 5 | ¿Se amplió el webhook? | `kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg -o yaml` | Los recursos objetivo listados |
| 6 | ¿Deniega realmente? | `kubectl create deployment ... --dry-run=server` | Denegado, con un nombre de regla `autogen-*` |
| 7 | ¿Hay regresiones? | `kyverno test .` en CI | Todas las afirmaciones pasan |

### 5.2 Síntoma → causa → arreglo

**El Deployment se admite, los Pods nunca aparecen, `FailedCreate` en los eventos del ReplicaSet.**
Autogen está apagado para esa política o para ese kind. Revisá los pasos 2/3 de arriba. Causas: `pod-policies.kyverno.io/autogen-controllers: none`, una lista restringida que omite el kind, o la regla haciendo match de kinds extra junto con `Pod` (§3.5). Arreglá la anotación o dividí la regla.

**`kyverno test` falla con `Not found` sobre el nombre de la regla.**
Afirmaste el nombre de la regla autorada contra un recurso de tipo controlador. Cambialo a `autogen-<rule>` para los controladores estándar y `autogen-cronjob-<rule>` para CronJob. Este es el fallo de CI más común con autogen.

**La política bloquea Deployments pero un Pod suelto se cuela (o al revés).**
Casi siempre es una expresión JMESPath/CEL escrita a mano que referencia `request.object.spec.*`. El reescritor de autogen es confiable para bloques `pattern` declarativos y frágil para expresiones que escribiste vos. Diferenciá los dos cuerpos de regla:

```console
$ kubectl get cpol <name> -o yaml | yq '.spec.rules[] | select(.name=="<rule>")' > /tmp/authored.yaml
$ kubectl get cpol <name> -o yaml | yq '.status.autogen.rules[] | select(.name=="autogen-<rule>")' > /tmp/generated.yaml
$ diff -u /tmp/authored.yaml /tmp/generated.yaml
```

Cualquier referencia a `request.object.spec.` que **no** haya sido reescrita a `request.object.spec.template.spec.` es tu bug. Arreglalo reestructurando hacia un patrón declarativo, o poniendo `autogen-controllers: none` y autorando las reglas de los controladores explícitamente.

**Una política basada en selector de etiquetas hace match de los Pods pero no de sus Deployments.**
`match.any[].resources.selector.matchLabels` se evalúa contra las `metadata.labels` **propias** del objeto que hizo match. En un Deployment esas son las etiquetas del Deployment, que con frecuencia difieren de `spec.template.metadata.labels`. Verificalo con:

```console
$ kubectl get deploy <name> -o jsonpath='{.metadata.labels}{"\n"}{.spec.template.metadata.labels}{"\n"}'
```

Si difieren, o bien imponés la convención de que los controladores lleven las etiquetas de su plantilla de pod, o bien pasás a un `namespaceSelector` / `preconditions` sobre un campo que exista en ambos niveles.

**Aplicar una política `mutate` disparó un reinicio rodante en todo el clúster.**
Comportamiento esperado y documentado (§1.3, §3.4). La mutación aterrizó en `spec.template.spec`, cambiando el hash del pod-template. Prevención: aplicá las políticas de mutación con un escalonado equivalente al de `validationFailureAction` — desplegá primero en `Audit`/solo-reporte, revisá el `PolicyReport`, y recién después aplicá en una ventana de mantenimiento. Si un rollout es genuinamente inaceptable, poné `autogen-controllers: none` y aceptá la mutación solo sobre Pods, entendiendo que no es duradera en el objeto declarado.

**Aparecieron latencia o timeouts del webhook después de agregar una política.**
Autogen expandió el webhook a `deployments`, `replicasets`, `jobs`, etc. En un clúster ocupado, `replicasets` en particular es un recurso de alta rotación. Mitigalo restringiendo `autogen-controllers` a los kinds que la gente realmente envía (típicamente `Deployment,StatefulSet,DaemonSet,Job,CronJob` — dejando afuera `ReplicaSet`/`ReplicationController`, cuyos Pods igual quedan cubiertos por la regla de Pod autorada), y subiendo `webhookTimeoutSeconds` solo después de confirmar que Kyverno no está falto de recursos:

```console
$ kubectl top pods -n kyverno
NAME                                            CPU(cores)   MEMORY(bytes)
kyverno-admission-controller-6d4f8b7c9d-9v2ql   142m         421Mi
kyverno-background-controller-7b6c5d84f-tzq4x   38m          186Mi
kyverno-reports-controller-59f7d6c4b8-hj8wn     91m          512Mi
```

**Un CRD de workload personalizado (`Rollout`, `CloneSet`, `SparkApplication`) no está cubierto.**
Autogen solo conoce los controladores de pods incorporados. No hay ningún valor de anotación que agregue un CRD. Escribí una regla explícita que haga match de ese kind con la ruta correcta a la plantilla de pod — y agregale un test de la CLI, porque nada lo va a generar ni mantener por vos.

**Actualizaste Kyverno y la cobertura cambió.**
El conjunto de controladores por defecto no es una API estable. Fijá el comportamiento del que dependés escribiendo la lista explícitamente en la anotación, y afirmá la cobertura en CI:

```console
$ kubectl get cpol -o json \
  | jq -r '.items[] | select(.status.autogen.rules != null)
           | .metadata.name as $p
           | .status.autogen.rules[]
           | "\($p)\t\(.name)\t\(.match.any[0].resources.kinds | join(","))"' \
  | column -t
require-pinned-image-tags  autogen-validate-image-tag          DaemonSet,Deployment,Job,StatefulSet,ReplicaSet,ReplicationController
require-pinned-image-tags  autogen-cronjob-validate-image-tag  CronJob
require-nonroot-runtime    autogen-check-runasnonroot          Deployment,StatefulSet,Job
require-nonroot-runtime    autogen-cronjob-check-runasnonroot  CronJob
```

Guardá un snapshot de esa salida y diferencialo en cada actualización de Kyverno. Es la prueba de regresión más barata posible para la cobertura de políticas.

### 5.3 Una nota sobre los tipos de política basados en CEL

Los releases recientes de Kyverno introducen kinds de política nativos en CEL (`ValidatingPolicy`, `ImageValidatingPolicy`, `MutatingPolicy`, …) alineados con el `ValidatingAdmissionPolicy` upstream. Estos **no** usan la anotación `pod-policies.kyverno.io/autogen-controllers`; autogen es un campo de primera clase en el spec, aproximadamente así:

```yaml
spec:
  autogen:
    podControllers:
      controllers:
        - deployments
        - cronjobs
```

El grupo de API y la disposición de los campos de estos tipos todavía están evolucionando. No los escribas de memoria — confirmalo en tu clúster antes de apoyarte en ello:

```console
$ kubectl api-resources | grep -i policies.kyverno.io
$ kubectl explain validatingpolicy.spec.autogen --recursive
```

Para el examen KCA, el modelo dirigido por anotaciones de `ClusterPolicy` en `kyverno.io/v1` descrito arriba es la materia principal.

---

## Referencias

- Kyverno — Auto-Gen Rules for Pod Controllers: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — Índice de documentación (la página de autogen se mueve entre las secciones *Writing Policies* y *Policy Types → ClusterPolicy* según el release; usá el selector de versión): https://kyverno.io/docs/
- Kyverno — Definición de políticas y estructura de reglas: https://kyverno.io/docs/writing-policies/
- Kyverno — Reglas validate: https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Reglas mutate: https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — Verify Images: https://kyverno.io/docs/writing-policies/verify-images/
- Kyverno CLI — `apply`: https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno CLI — `test`: https://kyverno.io/docs/kyverno-cli/usage/test/
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Kyverno — Biblioteca de políticas de ejemplo (toda política a nivel de pod que hay ahí se apoya en autogen): https://kyverno.io/policies/
- Kyverno — implementación de autogen, fuente de verdad para el conjunto de controladores por defecto y la lógica de reescritura: https://github.com/kyverno/kyverno/tree/main/pkg/autogen
- Kyverno — notas de release (los valores por defecto de autogen han cambiado entre versiones menores): https://github.com/kyverno/kyverno/releases
- Kubernetes — Deployments y la cadena Deployment → ReplicaSet → Pod: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — CronJob y el anidamiento de `jobTemplate`: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes — Dynamic Admission Control (reglas de webhook, failure policy, timeouts): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- CNCF — Currículum de Kyverno Certified Associate (KCA): https://github.com/cncf/curriculum