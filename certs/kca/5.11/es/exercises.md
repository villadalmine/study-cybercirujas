# Tema 5.11 — Common Expression Language (CEL): ejercicios guiados

> **Rol en los ejercicios:** estás operando un cluster real como platform engineer que codifica políticas *dentro del API server* en lugar de desplegar webhooks externos. CEL es el motor de expresiones compartido detrás de cuatro superficies de Kubernetes: las **validation rules** de los CRD (`x-kubernetes-validations`), **ValidatingAdmissionPolicy** (VAP), las **`matchConditions`** de los admission webhooks y la librería CEL del **authorizer**. Estos labs recorren las cuatro.

**Requisitos previos**

- Un cluster corriendo **Kubernetes v1.30+** (la release en la que `ValidatingAdmissionPolicy` y las `matchConditions` de webhooks llegaron a GA; las validation rules de CRD son GA desde v1.29). Sirve tanto `kind create cluster --image kindest/node:v1.30.0` como `minikube start --kubernetes-version=v1.30.0`.
- `kubectl` en la misma versión menor que el servidor.
- Permisos de cluster-admin (vas a crear CRDs y objetos de política con alcance de cluster).

**Fuentes de referencia (oficiales)**

- CEL en Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Validation rules de CRD — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- ValidatingAdmissionPolicy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- `matchConditions` de webhooks — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#matching-requests-matchconditions
- Definición del lenguaje CEL — https://github.com/google/cel-spec/blob/master/doc/langdef.md
- CEL playground (prueba de expresiones fuera del cluster) — https://playcel.undistro.io/

Creá un namespace descartable para que la limpieza sea trivial:

```bash
kubectl create namespace cel-lab
```

---

## Ejercicio 1 — CEL dentro de un CRD: `x-kubernetes-validations`

**Objetivo:** imponer invariantes entre campos y por elemento que OpenAPI puro (`minimum`, `pattern`, `required`) no puede expresar, usando `self`, la guarda `has()` y la macro `all()`.

1. Escribí el CRD. Fijate en que las dos reglas están adjuntas al **nodo objeto `spec`**, así que dentro de ellas `self` es el objeto `spec`.

```yaml
# scalingpolicy-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: scalingpolicies.training.example.com
spec:
  group: training.example.com
  scope: Namespaced
  names:
    plural: scalingpolicies
    singular: scalingpolicy
    kind: ScalingPolicy
    shortNames: ["sp"]
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
              required: ["minReplicas", "maxReplicas"]
              properties:
                minReplicas:
                  type: integer
                  minimum: 0
                maxReplicas:
                  type: integer
                  minimum: 1
                tiers:
                  type: array
                  maxItems: 16          # bounds the cost estimator — see Exercise 5
                  items:
                    type: string
              x-kubernetes-validations:
                - rule: "self.minReplicas <= self.maxReplicas"
                  message: "minReplicas cannot be larger than maxReplicas"
                - rule: "!has(self.tiers) || self.tiers.all(t, t.startsWith('tier-'))"
                  message: "every tier must be prefixed with 'tier-'"
                  fieldPath: ".tiers"
```

```bash
kubectl apply -f scalingpolicy-crd.yaml
```

```text
customresourcedefinition.apiextensions.k8s.io/scalingpolicies.training.example.com created
```

2. Aplicá un objeto **válido**:

```bash
kubectl apply -n cel-lab -f - <<'EOF'
apiVersion: training.example.com/v1
kind: ScalingPolicy
metadata:
  name: good
spec:
  minReplicas: 2
  maxReplicas: 10
  tiers: ["tier-a", "tier-b"]
EOF
```

```text
scalingpolicy.training.example.com/good created
```

3. Rompé la regla entre campos:

```bash
kubectl apply -n cel-lab -f - <<'EOF'
apiVersion: training.example.com/v1
kind: ScalingPolicy
metadata: { name: bad-range }
spec: { minReplicas: 10, maxReplicas: 3 }
EOF
```

```text
The ScalingPolicy "bad-range" is invalid: spec: Invalid value: "object": minReplicas cannot be larger than maxReplicas
```

4. Rompé la regla por elemento (mirá cómo `fieldPath` mueve el error a `spec.tiers`):

```bash
kubectl apply -n cel-lab -f - <<'EOF'
apiVersion: training.example.com/v1
kind: ScalingPolicy
metadata: { name: bad-tier }
spec:
  minReplicas: 1
  maxReplicas: 3
  tiers: ["tier-a", "gold"]
EOF
```

```text
The ScalingPolicy "bad-tier" is invalid: spec.tiers: Invalid value: "array": every tier must be prefixed with 'tier-'
```

**Comprobá tu comprensión**

- **1a.** En la regla `self.minReplicas <= self.maxReplicas`, ¿a qué se enlaza exactamente `self`, y a qué se enlazaría si la misma regla estuviera puesta bajo el nodo `minReplicas`?
- **1b.** ¿Por qué la segunda regla se escribe `!has(self.tiers) || self.tiers.all(...)` en lugar de solo `self.tiers.all(...)`? ¿Qué error en tiempo de ejecución aparece si sacás la guarda `has()` y enviás un objeto sin `tiers`?
- **1c.** ¿Qué efecto tiene `fieldPath: ".tiers"` sobre el error que ve el usuario, y por qué eso importa en objetos grandes?

---

## Ejercicio 2 — Transition rules e inmutabilidad con `oldSelf`

**Objetivo:** hacer que un campo se pueda escribir una sola vez. Una regla que referencia `oldSelf` es una **transition rule**: el API server solo la evalúa en `UPDATE`, cuando existe un valor previo.

1. Agregá un campo `storageClass` inmutable. Editá el CRD para insertar esta property bajo `spec.properties` y volvé a aplicarlo:

```yaml
                storageClass:
                  type: string
                  x-kubernetes-validations:
                    - rule: "self == oldSelf"
                      message: "storageClass is immutable once set"
```

```bash
kubectl apply -f scalingpolicy-crd.yaml
```

2. Creá un objeto con el campo seteado y después intentá cambiarlo:

```bash
kubectl apply -n cel-lab -f - <<'EOF'
apiVersion: training.example.com/v1
kind: ScalingPolicy
metadata: { name: locked }
spec: { minReplicas: 1, maxReplicas: 5, storageClass: "fast-ssd" }
EOF

kubectl patch -n cel-lab scalingpolicy locked --type merge -p '{"spec":{"storageClass":"slow-hdd"}}'
```

```text
scalingpolicy.training.example.com/locked created
The ScalingPolicy "locked" is invalid: spec.storageClass: Invalid value: "string": storageClass is immutable once set
```

3. Confirmá que la creación del paso 2 tuvo éxito aunque `self == oldSelf` parezca que debería haber saltado. No saltó en el CREATE: no había `oldSelf`.

**Comprobá tu comprensión**

- **2a.** ¿Por qué el `CREATE` inicial tuvo éxito en vez de fallar por la regla `self == oldSelf`?
- **2b.** Un colega quiere volver inmutable, de ahora en adelante, un campo opcional *ya existente*, pero puede haber objetos actuales que no lo tengan seteado. ¿Qué construcción de CEL permite que una transition rule tolere "el valor viejo estaba ausente", y cómo se escribe a grandes rasgos? (Pista: `optionalOldSelf`.)
- **2c.** La inmutabilidad también podría lograrse con un mutating webhook que rechace cambios. Dá una ventaja operativa concreta de expresarla como transition rule de CEL en su lugar.

---

## Ejercicio 3 — `ValidatingAdmissionPolicy` sobre recursos nativos

**Objetivo:** imponer una regla de cluster sobre `Deployments` — recursos que **no** son tuyos — sin desplegar ningún servidor de webhook. Esta es la división VAP + `ValidatingAdmissionPolicyBinding`: la **policy** contiene la lógica; el **binding** decide *dónde* aplica y *qué acción* toma.

1. Creá la policy (solo lógica: no hace nada hasta que se la asocie con un binding):

```yaml
# replica-policy.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: replica-limit.policy.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  validations:
    - expression: "!has(object.spec.replicas) || object.spec.replicas <= 5"
      message: "Deployment replicas must not exceed 5 in this cluster"
      reason: Invalid
```

2. Creá el binding, acotado a cualquier namespace que lleve la label `cel-demo=true`, y poné la acción de aplicación en **Deny**:

```yaml
# replica-binding.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: replica-limit.binding.example.com
spec:
  policyName: replica-limit.policy.example.com
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        cel-demo: "true"
```

```bash
kubectl apply -f replica-policy.yaml
kubectl apply -f replica-binding.yaml
kubectl label namespace cel-lab cel-demo=true
```

3. Probá el límite. Un Deployment que cumple es admitido; uno sobredimensionado es denegado:

```bash
kubectl create deployment ok  -n cel-lab --image=nginx --replicas=3
kubectl create deployment nope -n cel-lab --image=nginx --replicas=8
```

```text
deployment.apps/ok created
error: failed to create deployment: deployments.apps "nope" is forbidden: ValidatingAdmissionPolicy 'replica-limit.policy.example.com' with binding 'replica-limit.binding.example.com' denied request: Deployment replicas must not exceed 5 in this cluster
```

4. Demostrá el alcance. Creá el mismo objeto en un namespace **sin** la label y mirá cómo pasa:

```bash
kubectl create deployment nope -n default --image=nginx --replicas=8
```

```text
deployment.apps/nope created
```

**Comprobá tu comprensión**

- **3a.** Hacen falta dos objetos (`ValidatingAdmissionPolicy` y `...Binding`). ¿De qué se ocupa cada uno, y por qué esa separación es útil cuando la misma policy tiene que aplicarse distinto en `prod` que en `dev`?
- **3b.** `validationActions` acepta `Deny`, `Warn` y `Audit`. Describí una secuencia de rollout segura para una policy nueva en un cluster con mucho tráfico usando esos valores.
- **3c.** La expresión se protege con `!has(object.spec.replicas)`. Dado que `replicas` tiene un default de `1`, ¿esa guarda es estrictamente necesaria acá? ¿Qué variable sería `null` en una request `DELETE`, y por qué eso hace que la protección defensiva sea un hábito que conviene mantener?

---

## Ejercicio 4 — Variables, `matchConditions`, `messageExpression` y el `authorizer`

**Objetivo:** construir una policy realista de procedencia de imágenes sobre Pods que (a) saltee namespaces del sistema de forma barata, (b) factorice la lógica en **variables** reutilizables, (c) arme un mensaje dinámico y (d) otorgue una excepción según el RBAC de quien llama, vía la librería del **authorizer**.

1. Creá la policy:

```yaml
# image-policy.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: image-registry.policy.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchConditions:
    - name: skip-system-namespaces
      expression: "!(namespaceObject.metadata.name in ['kube-system', 'kube-node-lease'])"
  variables:
    - name: registry
      expression: "'registry.example.com/'"
    - name: containers
      expression: "object.spec.containers"
    - name: fromApprovedRegistry
      expression: "variables.containers.all(c, c.image.startsWith(variables.registry))"
    - name: callerMayBypass
      expression: >
        authorizer.group('policy.example.com').resource('imagebypass')
          .namespace(request.namespace).check('use').allowed()
  validations:
    - expression: "variables.fromApprovedRegistry || variables.callerMayBypass"
      messageExpression: >
        'all Pod images must come from ' + variables.registry +
        ' (or the caller must be granted use on imagebypass)'
      reason: Forbidden
```

```bash
kubectl apply -f image-policy.yaml
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: { name: image-registry.binding.example.com }
spec:
  policyName: image-registry.policy.example.com
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels: { cel-demo: "true" }
EOF
```

2. Un Pod que viene del registry equivocado es denegado; el mensaje se construye en el momento de la evaluación:

```bash
kubectl run bad --image=docker.io/library/nginx -n cel-lab
```

```text
Error from server (Forbidden): pods "bad" is forbidden: ValidatingAdmissionPolicy 'image-registry.policy.example.com' with binding 'image-registry.binding.example.com' denied request: all Pod images must come from registry.example.com/ (or the caller must be granted use on imagebypass)
```

3. Demostrá que la `matchCondition` corta el circuito. Creá el mismo Pod infractor en `kube-system`: la policy ni siquiera evalúa sus `validations`:

```bash
kubectl run bad --image=docker.io/library/nginx -n kube-system
```

```text
pod/bad created
```

**Comprobá tu comprensión**

- **4a.** Una request que coincide con `matchConstraints` todavía puede quedar excluida por una `matchCondition`. ¿Cuál es la diferencia semántica entre no pasar una `matchCondition` y no pasar una `validation`? ¿Cuál de las dos puede *denegar* una request?
- **4b.** Las variables se declaran como una lista ordenada y se referencian como `variables.<nombre>`. Dá dos razones (una sobre legibilidad, otra sobre **costo/rendimiento**) para mover `object.spec.containers.all(...)` a una variable en vez de escribirla inline en cada validation.
- **4c.** La llamada al `authorizer` hace una comprobación estilo SubjectAccessReview dentro de la expresión. ¿Qué válvula de escape del mundo real implementa `callerMayBypass`, y qué objeto de RBAC crearías para otorgar efectivamente `use` sobre `imagebypass`?
- **4d.** ¿Cuándo preferirías `messageExpression` sobre el campo estático `message`, y a qué tipo debe evaluar `messageExpression`?

---

## Ejercicio 5 — Diagnóstico: type checking, presupuesto de costo y parametrización

**Objetivo:** ejercitar las tres cosas que más suelen sorprender a quienes escriben CEL en producción: el **type checker no bloqueante**, el **estimador de costo** que rechaza iteración sin límites en tiempo de escritura, y las policies **parametrizadas** vía `paramKind`/`paramRef`.

1. **El type checking es una advertencia, no una barrera.** Introducí un error de tipos deliberado y observá que el objeto igual se *crea*, con una advertencia estampada en `status`:

```bash
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: { name: typecheck-demo.example.com }
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["deployments"]
  validations:
    - expression: "object.spec.replicas <= '5'"   # int <= string — nonsense
      message: "bogus"
EOF

kubectl get validatingadmissionpolicy typecheck-demo.example.com \
  -o jsonpath='{.status.typeChecking}{"\n"}'
```

```text
validatingadmissionpolicy.admissionregistration.k8s.io/typecheck-demo.example.com created
{"expressionWarnings":[{"fieldRef":"spec.validations[0].expression","warning":"apps/v1, Kind=Deployment: ERROR: <input>:1:20: found no matching overload for '_<=_' applied to '(int, string)'\n"}]}
```

2. **El estimador de costo rechaza la iteración sin límites en el registro del CRD.** Intentá registrar un CRD que itera una lista **sin `maxItems`**: el estimador tiene que asumir que la lista podría ser enorme y se niega:

```bash
kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: { name: costbombs.training.example.com }
spec:
  group: training.example.com
  scope: Namespaced
  names: { plural: costbombs, singular: costbomb, kind: CostBomb }
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
              properties:
                items:
                  type: array          # NOTE: no maxItems
                  items: { type: string }
              x-kubernetes-validations:
                - rule: "self.items.all(x, x.size() < 100)"
EOF
```

```text
The CustomResourceDefinition "costbombs.training.example.com" is invalid: spec.versions[0].schema.openAPIV3Schema.properties[spec].x-kubernetes-validations[0].rule: Forbidden: contributed to estimated rule & messageExpression cost total exceeding cost limit for entire OpenAPIv3 schema
```

3. Arreglalo agregando `maxItems: 100` y un `maxLength` en los items de tipo string, y volvé a aplicarlo: ahora se registra, porque el estimador puede acotar el trabajo.

4. **Parametrizá una policy.** Externalizá el techo de réplicas a un ConfigMap para que pueda cambiar sin editar la policy. `params` queda enlazado al objeto referenciado:

```bash
kubectl create namespace policy-config
kubectl create configmap replica-limits -n policy-config --from-literal=maxReplicas=3

kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: { name: param-replica.policy.example.com }
spec:
  paramKind: { apiVersion: v1, kind: ConfigMap }
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
  validations:
    - expression: "object.spec.replicas <= int(params.data.maxReplicas)"
      messageExpression: "'replicas exceed the configured limit of ' + params.data.maxReplicas"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: { name: param-replica.binding.example.com }
spec:
  policyName: param-replica.policy.example.com
  validationActions: ["Deny"]
  paramRef:
    name: replica-limits
    namespace: policy-config
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchLabels: { cel-demo: "true" }
EOF

kubectl create deployment big -n cel-lab --image=nginx --replicas=4
```

```text
error: failed to create deployment: deployments.apps "big" is forbidden: ValidatingAdmissionPolicy 'param-replica.policy.example.com' with binding 'param-replica.binding.example.com' denied request: replicas exceed the configured limit of 3
```

5. Antes de poner en producción una expresión cruda, probala fuera del cluster en el CEL playground (https://playcel.undistro.io/) o con `kubectl apply --dry-run=server`, que ejecuta toda la cadena de admission sin persistir nada.

**Comprobá tu comprensión**

- **5a.** ¿El type checking de CEL es bloqueante o informativo? ¿Por qué solo puede ser de *mejor esfuerzo*, dado que una policy puede coincidir con muchos Kinds vía comodines?
- **5b.** Explicá, en términos del **estimador** de costo frente al **presupuesto** de costo en tiempo de ejecución, por qué omitir `maxItems`/`maxLength` provoca un rechazo *en tiempo de escritura* y no una falla *en tiempo de ejecución*. ¿Cuál es la regla práctica para cualquier campo del schema que una regla CEL itere o mida?
- **5c.** En el binding parametrizado, ¿qué hace `parameterNotFoundAction: Deny`, y cómo cambia esa elección el modo de falla si alguien borra el ConfigMap `replica-limits`?
- **5d.** `params.data.maxReplicas` está envuelto en `int(...)`. ¿Por qué? ¿Cuál es el tipo CEL de un valor de `data` de un ConfigMap?

---

## Limpieza

```bash
kubectl delete validatingadmissionpolicybinding \
  replica-limit.binding.example.com image-registry.binding.example.com param-replica.binding.example.com --ignore-not-found
kubectl delete validatingadmissionpolicy \
  replica-limit.policy.example.com image-registry.policy.example.com \
  param-replica.policy.example.com typecheck-demo.example.com --ignore-not-found
kubectl delete crd scalingpolicies.training.example.com costbombs.training.example.com --ignore-not-found
kubectl delete namespace cel-lab policy-config --ignore-not-found
```

---

## Respuestas

<details>
<summary>Mostrar las respuestas de todos los ejercicios</summary>

### Ejercicio 1

- **1a.** `self` se enlaza al **objeto `spec`** (un map con las claves `minReplicas`, `maxReplicas`, `tiers`), porque la regla está adjunta al nodo del schema `spec`. Si la regla estuviera bajo el nodo `minReplicas`, `self` se enlazaría al **valor entero** escalar de `minReplicas` — y ya no podrías alcanzar `maxReplicas`, porque las reglas CEL solo ven *hacia abajo* desde donde están ancladas. Por eso las reglas entre campos deben vivir en el nodo ancestro común.
- **1b.** `tiers` es opcional. Acceder a `self.tiers` cuando el campo está ausente lanza `no such key: tiers` y la regla falla como error de evaluación. `has(self.tiers)` verifica la presencia; `!has(self.tiers) || …` corta el circuito para que la macro `all()` solo corra cuando el campo existe. Sin la guarda, un objeto sin `tiers` es rechazado con un error del estilo `... rule ... failed: no such key: tiers`. (Forma equivalente con optional chaining: `self.?tiers.orValue([]).all(...)`.)
- **1c.** `fieldPath: ".tiers"` reubica el error de la API desde el nodo de anclaje (`spec`) hacia `spec.tiers`, de modo que el `Invalid value` devuelto apunta al subcampo infractor. En objetos grandes esa es la diferencia entre que el usuario vea "algo en spec está mal" y "tu lista `tiers` está mal", lo cual importa para la UX y para las herramientas que parsean errores a nivel de campo.

### Ejercicio 2

- **2a.** `self == oldSelf` es una **transition rule**: referencia `oldSelf`, que solo existe en `UPDATE`. En el `CREATE` inicial no hay objeto previo, así que la regla **no se evalúa** y la creación tiene éxito. Las transition rules nunca se disparan en create.
- **2b.** Usá **`optionalOldSelf`**: marcá la regla con `optionalOldSelf: true` y referenciá `oldSelf` como un valor `Optional`, por ejemplo `oldSelf.hasValue() ? self == oldSelf.value() : true`. Esto permite que la regla tolere objetos anteriores a la existencia del campo (`oldSelf` ausente) y a la vez lo bloquee una vez seteado.
- **2c.** Corre **in-process en el API server**: no hay webhook externo que desplegar, escalar, asegurar con TLS ni mantener en alta disponibilidad; no hay salto de red que pueda dar timeout o fallar en abierto, y la inmutabilidad se impone igual durante las autocomprobaciones del API server y durante los upgrades. (Tampoco puede ser sorteada por una caída del webhook con `failurePolicy: Ignore`.)

### Ejercicio 3

- **3a.** La `ValidatingAdmissionPolicy` contiene la **lógica reutilizable** (`matchConstraints`, `validations`, `variables`). El `ValidatingAdmissionPolicyBinding` contiene la **decisión de despliegue**: a qué recursos/namespaces aplica (`matchResources`), qué acción tomar (`validationActions`) y qué params alimentarla. Una policy puede tener muchos bindings — por ejemplo un binding `Deny` en los namespaces de `prod` y uno `Warn` en `dev` — sin duplicar la expresión.
- **3b.** Desplegala primero como `Audit` (registra en el audit log, no deniega nada), inspeccioná las anotaciones de auditoría para ver con qué frecuencia *habría* saltado y sobre qué workloads; promovela a `Warn` (muestra una advertencia a `kubectl`/clientes pero sigue admitiendo) para avisar a los responsables; recién entonces pasala a `Deny`. Podés listar varias acciones a la vez, por ejemplo `["Deny","Audit"]`.
- **3c.** Estrictamente, `replicas` toma el default `1` antes de que corra la validating admission, así que acá la guarda no es obligatoria para los `Deployments`. Pero el hábito importa: en una request `DELETE` **`object` es `null`** (y en `CREATE`, `oldObject` es `null`). Acceder dentro de un objeto `null` lanza un error de evaluación, así que protegerse con `has()`/optional chaining evita que una policy falle en operaciones que no pensabas restringir.

### Ejercicio 4

- **4a.** Que una `matchCondition` no se cumpla significa que la request queda **excluida por completo de la policy**: las `validations` nunca corren y la request sigue adelante (sujeta a otras policies). Que falle una `validation` (bajo un binding `Deny`) **rechaza** la request. Las `matchConditions` filtran; solo las `validations` deniegan. Además las `matchConditions` se evalúan primero y son el lugar barato para cortar el circuito ante tráfico de alto volumen o del sistema.
- **4b.** *Legibilidad:* un único `fromApprovedRegistry` con nombre expresa la intención, y la `validation` se lee como `fromApprovedRegistry || callerMayBypass`. *Costo/rendimiento:* las variables se **evalúan de forma perezosa y se memoizan** — el escaneo de contenedores corre como máximo una vez por request aunque se la referencie en varias validations o en `messageExpression`, en lugar de re-iterar la lista cada vez. Eso te mantiene cómodamente por debajo del presupuesto de costo en tiempo de ejecución por request.
- **4c.** `callerMayBypass` es una **exención de emergencia (break-glass)**: cualquier identidad a la que RBAC le permita `use` sobre el recurso virtual `imagebypass` (grupo `policy.example.com`) saltea la verificación de registry. Se otorga con un `ClusterRole` que contenga una regla `{apiGroups: ["policy.example.com"], resources: ["imagebypass"], verbs: ["use"]}` y un `RoleBinding`/`ClusterRoleBinding` al sujeto de confianza. `imagebypass` no necesita ser un objeto real de la API: el authorizer hace una revisión de acceso contra el grafo de RBAC, no un GET.
- **4d.** Usá `messageExpression` cuando el mensaje tenga que incluir **datos de ejecución** (el valor infractor, el límite configurado, el registry). Debe evaluar a un **`string`**; si da error o devuelve algo que no es string, Kubernetes recae en el `message` estático.

### Ejercicio 5

- **5a.** El type checking es **informativo (no bloqueante)**: la policy se crea con las advertencias registradas en `status.typeChecking.expressionWarnings`. Solo puede ser de mejor esfuerzo porque los `matchConstraints` de una policy pueden coincidir con muchos Kinds (incluidos comodines o CRDs que el checker no puede resolver del todo); el checker verifica tipos contra cada tipo coincidente que puede descubrir y reporta incompatibilidades, pero no puede garantizar cobertura, así que advierte en lugar de bloquear.
- **5b.** El **estimador** calcula un costo *de peor caso* de forma estática, en tiempo de escritura, usando los límites declarados en el schema (`maxItems`, `maxLength`, `maxProperties`). Sin un límite, asume un máximo muy grande, la estimación se pasa del límite de costo por schema y el CRD/policy es **rechazado al escribirlo**. El **presupuesto en tiempo de ejecución** es un techo aparte que se aplica *durante* cada evaluación y detiene una expresión que efectivamente se vuelve demasiado cara. Regla práctica: **poné un `maxItems`/`maxLength`/`maxProperties` explícito en todo campo que una regla CEL itere o mida**, para que el estimador pueda acotar el trabajo y admitir tu policy.
- **5c.** `parameterNotFoundAction: Deny` significa que si el `paramRef` no resuelve a **ningún objeto**, la request se deniega en lugar de admitirse silenciosamente (`Allow` es la otra opción). Así que borrar el ConfigMap `replica-limits` pone la policy en modo **fail-closed**: todas las escrituras de Deployments que coincidan son denegadas hasta que se restaure el parámetro, que suele ser el default seguro para un control de seguridad.
- **5d.** Los valores de `data` de un ConfigMap son siempre **`string`** en CEL (el schema del ConfigMap tipa `data` como `map[string]string`). Comparar un string con un entero es un error de tipos, así que hay que convertirlo con `int(params.data.maxReplicas)` antes de la comparación numérica.

</details>