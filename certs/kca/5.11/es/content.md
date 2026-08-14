# Tema 5.11 — Common Expression Language (CEL)

> Peso en el examen: 2.91 · Dominio 5 (Extensibilidad y Políticas) · Perfil: SRE de producción / Arquitecto de Plataforma

---

## 1. Motivación: el problema arquitectónico que resuelve CEL

Todo control plane de Kubernetes necesita una forma de decir **"este objeto no está permitido"** o **"este campo debe satisfacer esta relación"** *antes* de que el objeto se persista en etcd. Históricamente existían exactamente dos mecanismos, y ambos tienen costos estructurales:

1. **Validación por schema OpenAPI v3** (`type`, `minimum`, `pattern`, `enum`, `required`). Esto valida *un campo por vez* contra una restricción estática. No puede expresar **invariantes entre campos** (`minReplicas <= maxReplicas`), **reglas de transición** (`replicas solo puede crecer`), ni nada condicional. Es estructuralmente incapaz de lógica relacional.

2. **Admission webhooks** (`ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`). Son arbitrariamente potentes — ejecutás Go (o lo que sea) en un pod — pero pagás por esa potencia en todos los ejes que importan en producción:
   - **Un salto de red en el camino crítico de escritura.** Cada `CREATE`/`UPDATE` de los recursos que coincidan se convierte en una llamada HTTP síncrona desde `kube-apiserver` hacia tu Service del webhook. Latencia, handshakes TLS y timeouts quedan ahora entre el usuario y etcd.
   - **Una nueva dependencia de disponibilidad.** Con `failurePolicy: Fail`, si el pod de tu webhook está caído, *la API de ese recurso está caída*. Así es como un webhook defectuoso tumba un cluster entero — incluyendo su propio camino de recuperación (no podés hacer `kubectl apply` del arreglo si el webhook lo bloquea).
   - **Superficie operativa.** Certificados (rotación de `caBundle`), un Deployment, un Service, HPA, PodDisruptionBudgets, y todo un ciclo de vida de releases — para lo que muchas veces es un `if` de cinco líneas.
   - **Sin garantía de terminación, sin cota de costo.** Código arbitrario puede entrar en bucle, reservar memoria o colgarse.

El **problema arquitectónico de producción** es entonces: *¿cómo obtenés políticas relacionales, condicionales y entre campos — el poder de un webhook — sin la latencia, la dependencia de disponibilidad, la maquinaria de certificados y la ejecución no acotada?*

**CEL es la respuesta.** [Common Expression Language](https://github.com/google/cel-spec) es un lenguaje de expresiones pequeño y **no Turing-completo** de Google. Su propiedad definitoria es que **no es un lenguaje de propósito general**: no tiene bucles, no tiene recursión no acotada, y el costo de ejecución de todo programa puede ser **estimado estáticamente antes de ejecutarse**. Esa única propiedad es la que hace seguro embeberlo *dentro* de `kube-apiserver` y evaluarlo *en proceso, por request*, con una cota superior de costo garantizada y terminación garantizada.

Kubernetes embebe CEL en varios subsistemas:

| Subsistema | Campo | GA en | Qué valida |
|---|---|---|---|
| Schema de CRD | `x-kubernetes-validations` | v1.29 | Reglas entre campos / de transición en custom resources |
| `ValidatingAdmissionPolicy` (VAP) | `spec.validations[].expression` | v1.30 | Admission validante en proceso para *cualquier* recurso |
| `MutatingAdmissionPolicy` | `spec.mutations[]` | alpha (v1.32) | Mutación en proceso vía CEL / JSON Patch |
| Admission webhooks | `webhooks[].matchConditions[].expression` | v1.30 | Acota *qué* requests llegan al webhook (pre-filtro en proceso) |
| Autenticación estructurada | Mapeos/validación de claims en `AuthenticationConfiguration` | v1.30 (beta) | Mapeo y validación de claim JWT → usuario |

El resto de este tema se centra en los dos sobre los que te van a examinar y que vas a usar a diario: **reglas de validación en CRD** y **`ValidatingAdmissionPolicy`**. Comparten el mismo runtime de CEL, modelo de costo y superficie de diagnóstico.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Admission con CEL (`ValidatingAdmissionPolicy`) vs. admission webhooks

| Dimensión | `ValidatingAdmissionPolicy` (CEL) | `ValidatingWebhookConfiguration` |
|---|---|---|
| Lugar de ejecución | **En proceso** dentro de `kube-apiserver` | Fuera de proceso, `POST` HTTP a un Service |
| Latencia agregada | Sub-milisegundo (sin red) | RTT de red + TLS + serialización; acotada por `timeoutSeconds` |
| Impacto en disponibilidad | Ninguno — no corre ningún componente extra | El pod del webhook se vuelve un SPOF; `failurePolicy: Fail` puede dejar la API inutilizable |
| Lenguaje | CEL (acotado, con terminación garantizada) | Código arbitrario (Go, Python, …) |
| Seguridad de tipos | **En tiempo de compilación**, verificada contra el schema destino | Solo en runtime — un typo falla con tráfico en vivo |
| Modelo de costo | Estimado estáticamente + presupuestado en runtime | No acotado; el timeout/escalado son tuyos |
| I/O externa (bases de datos, APIs) | **Imposible por diseño** | Permitida (y un footgun habitual) |
| Mutación | Solo vía `MutatingAdmissionPolicy` (alpha) | Sí (`MutatingWebhookConfiguration`) |
| Entrega | `kubectl apply` de un objeto | Deployment + Service + certificados TLS + rotación de CA |
| Parametrización | `paramKind` / `paramRef` nativos (un CRD como configuración) | Hacela vos mismo (ConfigMap, flags) |
| Reutilizable entre clusters | Sí (YAML puramente declarativo) | Requiere distribuir una imagen |
| Orden respecto de los webhooks | Corre **después** de los mutating webhooks, **antes** de los validating webhooks (aplica el orden de fases mutating→validating) | — |

**Regla de decisión (mirada de SRE):** si la política es una función pura del objeto, del objeto anterior, del request y de parámetros estáticos — usá una `ValidatingAdmissionPolicy`. Recurrí a un webhook **solo** cuando genuinamente necesitás llamar al mundo exterior (un sistema de inventario externo, un servicio de firma de imágenes, una API de licenciamiento) o necesitás mutación en una versión anterior al alpha de `MutatingAdmissionPolicy`. Todo lo demás es más barato, más seguro y de mayor disponibilidad como CEL.

### 2.2 Admission con CEL vs. motores de políticas externos

| | VAP (CEL, in-tree) | OPA Gatekeeper (Rego) | Kyverno |
|---|---|---|---|
| Runtime | En `kube-apiserver` | Pods de webhook | Pods de webhook |
| Lenguaje de políticas | CEL | Rego | YAML (+ CEL, JMESPath) |
| Componentes extra a ejecutar | **Ninguno** | Controlador de Gatekeeper + webhook | Controladores de Kyverno + webhook |
| Modo de falla de disponibilidad | No puede tumbar la API | Caída del webhook → riesgo de `failurePolicy` | Igual |
| Mutación | Alpha (`MutatingAdmissionPolicy`) | Limitada (CRDs assign/mutation) | Madura (reglas mutate) |
| Generar/clonar recursos | No | No | Sí (reglas generate) |
| Verificación de imágenes / datos externos | No (sin I/O) | Vía external data providers | Sí (`verifyImages`, llamadas a APIs) |
| Auditoría/escaneo en segundo plano de objetos existentes | Solo vía la acción audit | Sí (estado de las constraints) | Sí (policy reports) |
| Costo de aprendizaje | Bajo (CEL es pequeño) | Alto (Rego es un cambio de paradigma) | Bajo–medio |

**Trade-off:** VAP es el *default* correcto para validación porque elimina toda una capa de infraestructura. Gatekeeper/Kyverno siguen justificados cuando necesitás **mutación, generación de recursos, verificación de imágenes, datos externos o reportes de políticas a nivel organización sobre objetos preexistentes** — capacidades que la admission con CEL deliberadamente no tiene. Muchos equipos de plataforma hoy corren un híbrido: VAP para los casos validantes baratos, Kyverno para mutación/generación.

### 2.3 Dónde corre CEL, y qué puede ver cada superficie

| Superficie | Variables raíz disponibles | Retorna |
|---|---|---|
| CRD `x-kubernetes-validations` | `self`, `oldSelf` (solo en reglas de transición) | `bool` |
| VAP `validations[].expression` | `object`, `oldObject`, `request`, `params`, `namespaceObject`, `authorizer`, `variables` | `bool` |
| VAP `matchConditions[].expression` | igual que arriba (menos `variables`) | `bool` |
| VAP `variables[].expression` | igual (más las `variables` anteriores) | `any` |
| VAP `messageExpression` | igual | `string` |
| VAP `auditAnnotations[].valueExpression` | igual | `string` o `null` |
| Webhook `matchConditions[].expression` | `object`, `oldObject`, `request`, `authorizer` | `bool` |

---

## 3. Manifiestos completos (sin recortes)

### 3.1 CRD con reglas de validación entre campos, de formato y de transición

Fijate en las dos sutilezas con las que tropiezan los SREs: (a) una regla adjunta a un nodo enlaza `self` al *valor de ese nodo*, así que la lógica entre campos vive en el nodo **padre**; (b) `oldSelf` solo está disponible en **reglas de transición** y únicamente cuando el valor anterior existe.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: crontabs.stable.example.com
spec:
  group: stable.example.com
  names:
    kind: CronTab
    plural: crontabs
    singular: crontab
    shortNames: [ct]
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [minReplicas, maxReplicas, replicas, schedule]
              # Cross-field invariants live on the parent object node,
              # because only here does `self` see all sibling fields.
              x-kubernetes-validations:
                - rule: "self.minReplicas <= self.maxReplicas"
                  message: "minReplicas must not exceed maxReplicas"
                - rule: "self.replicas >= self.minReplicas && self.replicas <= self.maxReplicas"
                  messageExpression: >-
                    'replicas (' + string(self.replicas) +
                    ') must be within [' + string(self.minReplicas) +
                    ', ' + string(self.maxReplicas) + ']'
                # Conditional rule: image pull policy required only for prod tier.
                - rule: "self.tier != 'prod' || has(self.image)"
                  message: "prod tier requires an explicit image"
              properties:
                minReplicas:
                  type: integer
                  minimum: 0
                maxReplicas:
                  type: integer
                tier:
                  type: string
                  enum: ["dev", "staging", "prod"]
                image:
                  type: string
                replicas:
                  type: integer
                  # Transition rule: scale-up only. `oldSelf` is the prior value.
                  x-kubernetes-validations:
                    - rule: "self >= oldSelf"
                      message: "replicas can only be scaled up, never down"
                schedule:
                  type: string
                  # RE2 POSIX class [[:space:]] avoids CEL/YAML backslash escaping.
                  x-kubernetes-validations:
                    - rule: "self.matches('^[0-9*/,-]+([[:space:]]+[0-9*/,-]+){4}$')"
                      message: "schedule must be a valid 5-field cron expression"
```

### 3.2 `ValidatingAdmissionPolicy` — ciclo de vida completo (CRD de parámetros → policy → binding → objeto de parámetros)

Esta es la forma canónica de producción: la política se escribe **una vez**, y los umbrales por entorno los provee un **objeto de parámetros** (una instancia de CRD), seleccionado por el binding. Esa separación es lo que permite que VAP escale a muchos namespaces sin editar la política.

**Paso A — el CRD de parámetros** (configuración como recurso):

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: replicalimits.rules.example.com
spec:
  group: rules.example.com
  names:
    kind: ReplicaLimit
    plural: replicalimits
    singular: replicalimit
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            maxReplicas:
              type: integer
              minimum: 1
          required: [maxReplicas]
```

**Paso B — la política** (con `matchConditions`, `variables`, `messageExpression`, `auditAnnotations`):

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "replica-limit.policy.example.com"
spec:
  failurePolicy: Fail          # runtime eval error -> deny (not Ignore)
  paramKind:
    apiVersion: rules.example.com/v1
    kind: ReplicaLimit
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  # Cheap pre-filter, evaluated before validations; keeps kube-system exempt.
  matchConditions:
    - name: 'exclude-privileged-namespaces'
      expression: '!(object.metadata.namespace in ["kube-system", "kube-node-lease"])'
  # Named, reusable sub-expressions. Evaluated lazily, in order.
  variables:
    - name: replicas
      expression: "object.spec.replicas"
    - name: maxReplicas
      # Null-safe: fall back to 5 if the param omits the field.
      expression: "has(params.maxReplicas) ? params.maxReplicas : 5"
  validations:
    - expression: "variables.replicas <= variables.maxReplicas"
      reason: Forbidden
      # messageExpression must return a string; falls back to `message` on error.
      messageExpression: >-
        'Deployment ' + object.metadata.name + ' requests ' +
        string(variables.replicas) + ' replicas but the limit is ' +
        string(variables.maxReplicas)
  # Recorded into the API audit log regardless of allow/deny.
  auditAnnotations:
    - key: "observed-replicas"
      valueExpression: "'replicas=' + string(variables.replicas)"
```

**Paso C — el binding** (acopla la política a un alcance y a un objeto de parámetros):

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "replica-limit-binding.example.com"
spec:
  policyName: "replica-limit.policy.example.com"
  # Deny | Warn | Audit — can combine, e.g. [Deny] in prod, [Warn,Audit] to canary.
  validationActions: [Deny]
  paramRef:
    name: "replica-limit-prod"
    namespace: "policy-params"
    # If the referenced param object is missing at eval time:
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: production
```

**Paso D — el objeto de parámetros** (el umbral real, por entorno):

```yaml
apiVersion: rules.example.com/v1
kind: ReplicaLimit
metadata:
  name: replica-limit-prod
  namespace: policy-params
maxReplicas: 8
```

### 3.3 Una política pura y autocontenida (sin parámetros) usando el `authorizer` y las librerías de IP

Dos patrones de nivel producción: una **verificación de RBAC dentro de admission** (solo los usuarios que ya podrían hacer `update` sobre el subrecurso `scale` pueden fijar un conteo alto de réplicas), y la **librería de IP/CIDR** para validar un rango de origen de un LoadBalancer.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "guardrails.policy.example.com"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  variables:
    - name: highScale
      expression: "has(object.spec.replicas) && object.spec.replicas > 20"
    - name: canScale
      # Ask the built-in authorizer: could this same user update deployments/scale?
      expression: >-
        authorizer.group('apps').resource('deployments').subresource('scale')
          .namespace(object.metadata.namespace).check('update').allowed()
  validations:
    - expression: "!variables.highScale || variables.canScale"
      reason: Forbidden
      messageExpression: >-
        '>20 replicas requires update permission on deployments/scale in namespace ' +
        object.metadata.namespace
    # Reject containers without resource limits (cross-list quantifier).
    - expression: >-
        object.spec.template.spec.containers.all(c,
          has(c.resources) && has(c.resources.limits) &&
          'memory' in c.resources.limits)
      message: "every container must set a memory limit"
```

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Camino feliz — crear la política, bindearla, observar una denegación

```console
$ kubectl apply -f param-crd.yaml
customresourcedefinition.apiextensions.k8s.io/replicalimits.rules.example.com created

$ kubectl apply -f policy.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/replica-limit.policy.example.com created

$ kubectl apply -f binding.yaml
validatingadmissionpolicybinding.admissionregistration.k8s.io/replica-limit-binding.example.com created

$ kubectl -n policy-params apply -f param.yaml
replicalimit.rules.example.com/replica-limit-prod created

$ kubectl get validatingadmissionpolicy
NAME                                  VALIDATIONS   PARAMKIND                         AGE
replica-limit.policy.example.com      1             ReplicaLimit.rules.example.com    41s

$ kubectl label namespace app-prod environment=production
namespace/app-prod labeled

# Attempt a Deployment that violates the limit (maxReplicas=8, requesting 10):
$ kubectl -n app-prod apply -f nginx-10-replicas.yaml
Error from server (Forbidden): error when creating "nginx-10-replicas.yaml": deployments.apps "nginx" is forbidden: ValidatingAdmissionPolicy 'replica-limit.policy.example.com' with binding 'replica-limit-binding.example.com' denied request: Deployment nginx requests 10 replicas but the limit is 8
```

### 4.2 La red de seguridad en tiempo de compilación (esta es la característica estrella)

Las expresiones CEL son **verificadas de tipos contra el schema destino cuando se crea la política**. Un typo en un campo falla *en el momento del `kubectl apply`*, no con tráfico de producción en vivo — exactamente el modo de falla que un webhook no puede prevenir.

```console
$ cat broken-policy.yaml
...
  validations:
    - expression: "object.spec.replica <= 5"   # 'replica' — typo, should be 'replicas'
...

$ kubectl apply -f broken-policy.yaml
The ValidatingAdmissionPolicy "broken.policy.example.com" is invalid:
spec.validations[0].expression: Invalid value: "object.spec.replica <= 5":
compilation failed: ERROR: <input>:1:13: undefined field 'replica'
 | object.spec.replica <= 5
 | ............^
```

Para recursos que coinciden de forma laxa (por ejemplo, `resources: ["*"]`), el API server no siempre puede resolver el tipo en tiempo de compilación, así que en vez de fallar **registra advertencias en `.status.typeChecking`** — exponiendo bugs probables sin bloquear:

```console
$ kubectl get validatingadmissionpolicy replica-limit.policy.example.com -o yaml
...
status:
  observedGeneration: 1
  typeChecking:
    expressionWarnings:
      - fieldRef: spec.validations[0].expression
        warning: |-
          apps/v1, Kind=Deployment: ERROR: <input>:1:13: undefined field 'replica'
           | object.spec.replica <= 5
           | ............^
```

### 4.3 Rechazo por estimación de costo

Si el **peor costo estimado estáticamente** de una expresión excede el límite por expresión (por ejemplo, `all()` anidados sobre listas no acotadas), la política se rechaza al crearse:

```console
$ kubectl apply -f expensive-policy.yaml
The ValidatingAdmissionPolicy "expensive.policy.example.com" is invalid:
spec.validations[0].expression: Forbidden: estimated cost of the expression
exceeds the cost limit for the resource
```

### 4.4 Validación de CRD en acción

```console
$ kubectl apply -f crontab-crd.yaml
customresourcedefinition.apiextensions.k8s.io/crontabs.stable.example.com created

$ cat bad-crontab.yaml
apiVersion: stable.example.com/v1
kind: CronTab
metadata: {name: nightly}
spec:
  minReplicas: 5
  maxReplicas: 2         # violates minReplicas <= maxReplicas
  replicas: 3
  schedule: "0 0 * * *"

$ kubectl apply -f bad-crontab.yaml
The CronTab "nightly" is invalid: spec: Invalid value: "object": minReplicas must not exceed maxReplicas

# Transition rule: scale-down is blocked on UPDATE, not on CREATE.
$ kubectl patch crontab nightly --type merge -p '{"spec":{"replicas":1}}'
The CronTab "nightly" is invalid: spec.replicas: Invalid value: "integer": replicas can only be scaled up, never down
```

### 4.5 Hacer un canary seguro de una política con `Warn` + `Audit` antes de `Deny`

```console
# Flip the binding to non-blocking to measure blast radius first.
$ kubectl patch validatingadmissionpolicybinding replica-limit-binding.example.com \
    --type merge -p '{"spec":{"validationActions":["Warn","Audit"]}}'
validatingadmissionpolicybinding.admissionregistration.k8s.io/replica-limit-binding.example.com patched

$ kubectl -n app-prod apply -f nginx-10-replicas.yaml
Warning: Deployment nginx requests 10 replicas but the limit is 8
deployment.apps/nginx created

# The Audit action lands structured annotations in the API audit log:
$ jq 'select(.annotations["validation.policy.admission.k8s.io/validation_failure"])' \
     /var/log/kube-apiserver/audit.log | head
{
  "annotations": {
    "validation.policy.admission.k8s.io/validation_failure":
      "[{\"message\":\"Deployment nginx requests 10 replicas but the limit is 8\",\"policy\":\"replica-limit.policy.example.com\",\"binding\":\"replica-limit-binding.example.com\",\"expressionIndex\":0,\"validationActions\":[\"Warn\",\"Audit\"]}]",
    "observed-replicas": "replicas=10"
  }
}
```

Este camino de canary — primero `Warn`/`Audit`, leer el audit log para dimensionar el radio de impacto, y luego promover a `Deny` — es el patrón de rollout seguro y no tiene equivalente en la validación por schema a secas.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 El modelo de costo — el origen de los dos rechazos más comunes

CEL en Kubernetes está acotado en **dos** etapas independientes. Saber cuál etapa te rechazó te dice qué arreglar.

| Etapa | Constante (default del apiserver) | Se aplica cuando | Síntoma |
|---|---|---|---|
| Estimación **estática por expresión** | `10,000,000` (`StaticEstimatedCostLimit`) | Se **crea** la policy/CRD | `Forbidden: estimated cost … exceeds the cost limit` |
| Agregado **estático por CRD** | `100,000,000` (`StaticEstimatedCRDCostLimit`) | Se **crea** el CRD | CRD rechazado: costo total de las reglas demasiado alto |
| Presupuesto **de runtime por request** (VAP) | `10,000,000` (`RuntimeCELCostBudget`) | En cada **evaluación** de admission | Request denegado: se excedió el presupuesto de costo en runtime |
| Presupuesto de runtime de **matchConditions** | `1,000,000` (`RuntimeCELCostBudgetMatchConditions`) | Fase de match de webhook/VAP | Costo de la fase de match excedido |

El estimador es **pesimista**: usa los límites del schema (`maxItems`, `maxLength`) como el tamaño de listas/strings. Una expresión como `object.spec.a.all(x, object.spec.b.exists(y, x == y))` cuesta aproximadamente `len(a) × len(b)`. **Si tus campos de tipo lista no tienen `maxItems`/`maxLength`, el estimador asume el máximo y el costo explota.** El arreglo casi siempre es *"acotá el campo en el schema"*, no *"reescribí la expresión"*.

```console
# Diagnose an unbounded field feeding an expensive quantifier:
$ kubectl explain crontab.spec.hosts
KIND:     CronTab
FIELD:    hosts <[]string>
    (no maxItems -> estimator assumes worst case)
```

Agregá `maxItems: 100` a `hosts` y la estimación baja varios órdenes de magnitud.

### 5.2 Errores de evaluación en runtime y `failurePolicy`

En runtime una expresión CEL puede fallar — lo más común es una **desreferencia de null** (`object.spec.foo` cuando `foo` no está) o una conversión de tipos incorrecta. Lo que pasa después lo gobierna `failurePolicy`:

- `failurePolicy: Fail` (default) → el request es **denegado**.
- `failurePolicy: Ignore` → la validación que falló se **omite** (el objeto es admitido en lo que respecta a esa política).

**Este es el bug de producción #1:** una expresión que asume que un campo opcional existe empieza a denegar (o ignorar) tráfico silenciosamente en el momento en que alguien omite ese campo. Defendete con:

| Técnica | Ejemplo | Efecto |
|---|---|---|
| Macro `has()` | `has(object.spec.replicas) && object.spec.replicas > 3` | Verificar presencia antes de acceder |
| Encadenamiento opcional | `object.?spec.?replicas.orValue(1)` | Devolver un default en vez de fallar |
| Orden con cortocircuito | `has(x) && x.y == 1` | `&&` / `\|\|` se detienen en el primer operando decisivo |
| Default vía `variables` | computar una vez, reutilizar | Centralizar la lógica null-safe |

```yaml
    # WRONG — errors (and, under Fail, denies) when replicas is unset:
    - expression: "object.spec.replicas <= 5"
    # RIGHT — presence-guarded, no runtime error:
    - expression: "!has(object.spec.replicas) || object.spec.replicas <= 5"
```

### 5.3 La trampa del escapado de regex / strings

Los literales de string de CEL interpretan escapes con barra invertida, y YAML *también* procesa barras invertidas en escalares con **comillas dobles**. Un regex `\d` necesita entonces escaparse dos veces, lo cual es una fuente frecuente de coincidencias que fallan en silencio:

| Lo que querés (RE2) | Fuente CEL | YAML con comilla simple | YAML con comilla doble |
|---|---|---|---|
| `\d` | `\\d` | `'\\d'` | `"\\\\d"` |
| `\s` | `\\s` | `'\\s'` | `"\\\\s"` |

Regla práctica: **usá YAML con comillas simples para las reglas CEL**, y preferí las clases POSIX (`[[:digit:]]`, `[[:space:]]`) que no necesitan ninguna barra invertida. Una regla que "nunca coincide con nada" casi siempre es este bug.

### 5.4 Verificación de tipos, advertencias y matching

```console
# Is the policy type-clean against every matched Kind?
$ kubectl get validatingadmissionpolicy replica-limit.policy.example.com \
    -o jsonpath='{.status.typeChecking.expressionWarnings}'
[]        # empty == clean

# Why did my policy not fire? Verify the binding scope actually matches.
$ kubectl get validatingadmissionpolicybinding replica-limit-binding.example.com \
    -o jsonpath='{.spec.matchResources.namespaceSelector}{"\n"}'
{"matchLabels":{"environment":"production"}}

$ kubectl get ns app-prod --show-labels
NAME       STATUS   AGE   LABELS
app-prod   Active   3h    environment=production,kubernetes.io/metadata.name=app-prod
```

Una política que "no hace nada" casi siempre falla alguna de estas tres verificaciones, en este orden: (1) **existe un binding** y nombra a la política; (2) `validationActions` incluye `Deny` (una política **sin binding**, o con solo `Audit`, nunca bloquea); (3) el request está realmente **en alcance** (`matchConstraints` en la política *y* `matchResources` en el binding aplican ambos, en conjunción lógica).

### 5.5 Iteración local rápida sin cluster

Probá la lógica CEL contra objetos de ejemplo antes de tocar siquiera el API server:

```console
$ go install github.com/google/cel-go/repl@latest
$ cel-repl
> object.spec.replicas <= 5
... (bind `object` to a sample and evaluate)
```

o con el `cel-playground` de la comunidad, o `kubectl-validate` para chequeo offline de CRDs/manifiestos. Iterar acá convierte un viaje de ida y vuelta de "compilación fallida" por el API server en un bucle local de menos de un segundo.

### 5.6 Checklist de diagnóstico

- **Deniega inesperadamente en algunos objetos** → una desreferencia de null bajo `failurePolicy: Fail`; agregá `has()` / `?.orValue()`.
- **Nunca coincide / el regex falla en silencio** → doble escapado; pasá a YAML con comillas simples o a clases `[[:...]]`.
- **Rechazado al crear con "estimated cost exceeds limit"** → acotá el campo lista/string ofensor con `maxItems`/`maxLength`; no te limites a reescribir el CEL.
- **La política no tiene efecto** → falta el binding, `Deny` no está en `validationActions`, o hay un desajuste de alcance entre `matchConstraints` y `matchResources`.
- **`params` es null en runtime** → definí `paramRef.parameterNotFoundAction`, o protegé con `has(params...)` / defaults en `variables`.
- **Una regla entre campos "no ve" a un campo hermano en un CRD** → movela hacia arriba, al nodo objeto padre, donde `self` ve ambos campos.
- **Una regla de transición falla en CREATE** → `oldSelf` solo existe en UPDATE con un valor previo; una regla que lo referencia se omite en CREATE por diseño.

---

## 6. Referencias

- Especificación de CEL (Google): https://github.com/google/cel-spec
- Definición del lenguaje CEL: https://github.com/google/cel-spec/blob/master/doc/langdef.md
- Kubernetes — Panorama de CEL y librerías extendidas: https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes — Validating Admission Policy: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — Mutating Admission Policy (alpha): https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- Kubernetes — Reglas de validación en CRD (`x-kubernetes-validations`): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Kubernetes — `matchConditions` de webhooks (pre-filtro CEL): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#matching-requests-matchconditions
- Kubernetes — Configuración de autenticación estructurada (mapeo/validación de claims con CEL): https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration
- KEP-3488 — CEL para Admission Control (`ValidatingAdmissionPolicy`): https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/3488-cel-admission-control
- KEP-2876 — Lenguaje de expresiones de validación para CRDs: https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/2876-crd-validation-expression-language
- cel-go (runtime embebible y REPL): https://github.com/google/cel-go
- Currículum de la CNCF (temario fuente): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf