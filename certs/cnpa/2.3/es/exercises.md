# Ejercicios guiados — Tema 2.3: Policy Engines for Platform Governance

Estos ejercicios recorren los tres motores de políticas que el CNPA espera que un platform engineer sepa comparar y operar: **OPA Gatekeeper**, **Kyverno** y las **ValidatingAdmissionPolicies (VAP)** nativas de Kubernetes basadas en CEL. La idea es que no solo apliques manifiestos, sino que entiendas *dónde* se ejecuta la política (el admission chain), *cuándo* (validating vs mutating) y *qué* garantías da cada modo (`enforce` vs `audit`).

## Prerrequisitos

- Un cluster de prueba desechable (kind, minikube o k3d). **No** ejecutes estos ejercicios contra producción: vas a instalar admission webhooks que interceptan escrituras a la API.
- `kubectl` v1.30+ (las VAP llegaron a GA en 1.30).
- Acceso `cluster-admin`.

Verificá el punto de partida:

```bash
kubectl version -o yaml | grep -A1 serverVersion
kubectl auth can-i create validatingadmissionpolicies
```

Salida esperada:

```
serverVersion:
  major: "1"
  minor: "30"
yes
```

> Contexto conceptual: un policy engine para governance se inserta como **admission controller** en la cadena de la API. El orden real es: autenticación → autorización (RBAC) → *mutating admission* → *validating admission* → persistencia en etcd. Los tres motores de este tema viven en la fase de admission, y esa posición es la que les permite rechazar o modificar objetos *antes* de que existan. Referencia: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/

---

## Ejercicio 1 — OPA Gatekeeper: ConstraintTemplate + Constraint

Gatekeeper separa el *qué* del *dónde*: un `ConstraintTemplate` define la regla en Rego y genera un CRD nuevo; un `Constraint` (una instancia de ese CRD) decide a qué objetos aplica y con qué parámetros.

**Paso 1.** Instalá Gatekeeper:

```bash
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.17/deploy/gatekeeper.yaml
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager
```

Salida esperada (final):

```
deployment "gatekeeper-controller-manager" successfully rolled out
```

**Paso 2.** Confirmá que Gatekeeper registró sus webhooks:

```bash
kubectl get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
  -o jsonpath='{.webhooks[*].name}'; echo
```

Salida esperada:

```
validation.gatekeeper.sh check-ignore-label.gatekeeper.sh
```

**Paso 3.** Creá un `ConstraintTemplate` que exige labels arbitrarios. La lógica va en Rego, dentro del bloque `violation`:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels

        violation[{"msg": msg, "details": {"missing_labels": missing}}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("you must provide labels: %v", [missing])
        }
```

Aplicalo y esperá a que el CRD generado esté disponible:

```bash
kubectl apply -f k8srequiredlabels-template.yaml
kubectl get crd k8srequiredlabels.constraints.gatekeeper.sh
```

Salida esperada:

```
constrainttemplate.templates.gatekeeper.sh/k8srequiredlabels created
NAME                                            CREATED AT
k8srequiredlabels.constraints.gatekeeper.sh     2025-04-01T10:12:03Z
```

**Paso 4.** Instanciá un `Constraint` que obligue a todos los `Namespace` a tener el label `owner`:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: ns-must-have-owner
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Namespace"]
  parameters:
    labels: ["owner"]
```

```bash
kubectl apply -f ns-owner-constraint.yaml
```

**Paso 5.** Probá la política, primero violándola y luego cumpliéndola:

```bash
kubectl create ns proyecto-sin-owner
kubectl create ns proyecto-con-owner
kubectl label ns proyecto-con-owner owner=plataforma --overwrite 2>/dev/null || true
kubectl create ns proyecto-ok --dry-run=server -o name && echo "creado"
```

La primera línea debe fallar:

```
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [ns-must-have-owner] you must provide labels: {"owner"}
```

Un namespace *con* el label pasa. Para crearlo con label en un solo paso:

```bash
kubectl create -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: proyecto-con-owner
  labels:
    owner: plataforma
EOF
```

Salida esperada:

```
namespace/proyecto-con-owner created
```

### Preguntas de comprensión — Bloque 1

1. ¿Por qué Gatekeeper separa el `ConstraintTemplate` del `Constraint`? ¿Qué ventaja operativa da respecto de escribir la regla y su alcance en un solo objeto?
2. En el Rego del Paso 3, `missing := required - provided` usa una operación de conjuntos. ¿Qué pasaría si `count(missing) > 0` no estuviera? ¿La regla seguiría siendo correcta?
3. El error del Paso 5 lo devuelve el webhook, no el kube-apiserver por sí mismo. ¿En qué fase del admission chain ocurre esto y por qué el objeto nunca llega a etcd?

---

## Ejercicio 2 — Enforce vs audit: `enforcementAction` y el dry-run de governance

En una plataforma real casi nunca activás una política nueva en modo `deny` directo: primero medís cuánto rompería. Gatekeeper soporta esto con `spec.enforcementAction` y con un **audit loop** que reporta violaciones de objetos *ya existentes* sin bloquearlos.

**Paso 1.** Cambiá el constraint anterior a modo `dryrun` para observar sin bloquear:

```bash
kubectl patch k8srequiredlabels ns-must-have-owner --type=merge \
  -p '{"spec":{"enforcementAction":"dryrun"}}'
```

**Paso 2.** Ahora la creación que antes fallaba, pasa:

```bash
kubectl create ns proyecto-sin-owner-2
```

Salida esperada:

```
namespace/proyecto-sin-owner-2 created
```

**Paso 3.** Forzá un ciclo de audit y leé las violaciones acumuladas en el `status` del constraint (Gatekeeper audita cada 60 s por defecto):

```bash
kubectl get k8srequiredlabels ns-must-have-owner \
  -o jsonpath='{.status.totalViolations}{"\n"}'
kubectl get k8srequiredlabels ns-must-have-owner \
  -o jsonpath='{range .status.violations[*]}{.name}{" -> "}{.message}{"\n"}{end}'
```

Salida esperada (los números dependen de cuántos namespaces sin `owner` tengas):

```
3
proyecto-sin-owner    -> you must provide labels: {"owner"}
proyecto-sin-owner-2  -> you must provide labels: {"owner"}
default               -> you must provide labels: {"owner"}
```

**Paso 4.** Compará los tres valores posibles. Poné el constraint en `warn` y observá que la operación *procede* pero el cliente recibe un aviso:

```bash
kubectl patch k8srequiredlabels ns-must-have-owner --type=merge \
  -p '{"spec":{"enforcementAction":"warn"}}'
kubectl create ns proyecto-sin-owner-3
```

Salida esperada:

```
Warning: [ns-must-have-owner] you must provide labels: {"owner"}
namespace/proyecto-sin-owner-3 created
```

**Paso 5.** Devolvé la política a `deny` cuando ya midaste el impacto:

```bash
kubectl patch k8srequiredlabels ns-must-have-owner --type=merge \
  -p '{"spec":{"enforcementAction":"deny"}}'
```

### Preguntas de comprensión — Bloque 2

1. ¿Cuál es la diferencia práctica, desde el punto de vista del cliente y del objeto persistido, entre `dryrun`, `warn` y `deny`?
2. El audit loop reportó `default` como violación aunque nadie intentó crearlo recién. ¿Qué mecanismo detecta violaciones de objetos preexistentes, y por qué es imprescindible en un rollout gradual de governance?
3. Un compañero propone activar toda política nueva directamente en `deny`. Dá dos argumentos, en términos de riesgo operativo, para exigir una fase `dryrun`/`audit` previa.

---

## Ejercicio 3 — Kyverno: policy de validación sin Rego

Kyverno es Kubernetes-native: las políticas son YAML declarativo (patterns, no un lenguaje aparte). Comparalo mentalmente con Gatekeeper mientras lo hacés.

**Paso 1.** Instalá Kyverno:

```bash
kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

Salida esperada (final):

```
deployment "kyverno-admission-controller" successfully rolled out
```

**Paso 2.** Creá una `ClusterPolicy` que exija el label `team` en todo Pod. Fijate que la acción (`Enforce`/`Audit`) se declara por regla con `failureAction`, que es la forma vigente desde Kyverno 1.12 (el antiguo `spec.validationFailureAction` a nivel de spec está deprecado):

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
        failureAction: Enforce
        message: "El label 'team' es obligatorio en todo Pod."
        pattern:
          metadata:
            labels:
              team: "?*"
```

```bash
kubectl apply -f require-team-label.yaml
```

**Paso 3.** El `"?*"` es un pattern de Kyverno que significa "cualquier valor no vacío". Probá un Pod sin el label:

```bash
kubectl run nginx-malo --image=nginx:1.27
```

Salida esperada:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/nginx-malo was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: El label ''team'' es obligatorio en todo Pod.
    rule check-team-label failed at path /metadata/labels/team/'
```

**Paso 4.** Ahora uno que cumple:

```bash
kubectl run nginx-ok --image=nginx:1.27 --labels=team=plataforma
```

Salida esperada:

```
pod/nginx-ok created
```

**Paso 5.** Kyverno emite `PolicyReport`s en background aunque la policy sea `Enforce`. Miralos:

```bash
kubectl get policyreport -A
```

Salida esperada (abreviada):

```
NAMESPACE   NAME                                   KIND   NAME        PASS   FAIL   WARN
default     <hash>                                 Pod    nginx-ok    1      0      0
```

### Preguntas de comprensión — Bloque 3

1. La policy usa `pattern` en vez de código. ¿Qué gana y qué pierde Kyverno respecto de Gatekeeper/Rego al usar un DSL declarativo en lugar de un lenguaje de propósito general?
2. En el Paso 2, `failureAction: Enforce` vive dentro de la regla, no en el `spec`. ¿Qué flexibilidad habilita poner la acción por regla en una policy con varias reglas?
3. `background: true` afecta a los `PolicyReport`. ¿Sobre qué conjunto de recursos actúa el background scan y en qué se parece al audit loop de Gatekeeper del Ejercicio 2?

---

## Ejercicio 4 — Kyverno mutate y generate: governance que *repara* y *provisiona*

Validar es solo la mitad del gobierno de plataforma. Los platform engineers usan políticas para **inyectar defaults seguros** (mutate) y para **provisionar recursos base** por namespace (generate) sin que el equipo de aplicación tenga que recordarlos.

**Paso 1.** Policy de mutación: forzar `runAsNonRoot: true` en todo Pod que no lo declare. `+(...)` es un *anchor* de Kyverno que aplica el valor solo si la clave no existe:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-run-as-nonroot
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
            securityContext:
              +(runAsNonRoot): true
```

```bash
kubectl apply -f default-run-as-nonroot.yaml
kubectl run nginx-mutado --image=nginx:1.27 --labels=team=plataforma
kubectl get pod nginx-mutado -o jsonpath='{.spec.securityContext.runAsNonRoot}{"\n"}'
```

Salida esperada:

```
pod/nginx-mutado created
true
```

**Paso 2.** Policy de generación: crear automáticamente una `NetworkPolicy` default-deny en cada namespace nuevo. `synchronize: true` mantiene el recurso alineado con la policy si alguien lo edita o borra:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-default-netpol
spec:
  rules:
    - name: default-deny-ingress-egress
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

```bash
kubectl apply -f generate-default-netpol.yaml
kubectl create ns tenant-a
kubectl -n tenant-a get networkpolicy default-deny
```

Salida esperada:

```
namespace/tenant-a created
NAME           POD-SELECTOR   AGE
default-deny   <none>         2s
```

**Paso 3.** Comprobá la sincronización: borrá la NetworkPolicy y verificá que Kyverno la recrea:

```bash
kubectl -n tenant-a delete networkpolicy default-deny
sleep 3
kubectl -n tenant-a get networkpolicy default-deny
```

Salida esperada:

```
networkpolicy.networking.k8s.io "default-deny" deleted
NAME           POD-SELECTOR   AGE
default-deny   <none>         1s
```

### Preguntas de comprensión — Bloque 4

1. Una policy `mutate` corre en la fase de *mutating admission* y una `validate` en la de *validating admission*. Si tenés ambas para el mismo Pod, ¿en qué orden se ejecutan y por qué ese orden hace que la validación vea el objeto ya mutado?
2. ¿Qué diferencia hay entre `synchronize: true` y `synchronize: false` en una `generate` rule cuando un usuario edita a mano el recurso generado?
3. El anchor `+(runAsNonRoot)` solo agrega el valor si la clave falta. ¿Por qué es preferible eso a sobrescribir siempre el valor, desde el punto de vista de no pisar decisiones legítimas del equipo de aplicación?

---

## Ejercicio 5 — ValidatingAdmissionPolicy nativa (CEL): governance sin webhook

Desde Kubernetes 1.30 el propio API server evalúa políticas escritas en **CEL (Common Expression Language)**, sin instalar ningún motor externo ni webhook. Es más liviano y elimina el fallo de disponibilidad del webhook, a costa de menos expresividad que Rego. El patrón vuelve a separar la regla (`ValidatingAdmissionPolicy`) de su alcance (`ValidatingAdmissionPolicyBinding`).

**Paso 1.** Definí la policy: limitar los `Deployment` a 5 réplicas como máximo:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "demo-replica-limit.example.com"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  validations:
    - expression: "object.spec.replicas <= 5"
      message: "El número de réplicas del Deployment no puede superar 5."
```

```bash
kubectl apply -f vap-replica-limit.yaml
```

**Paso 2.** Una policy sin binding **no hace nada**: el binding es lo que la activa y decide su alcance. Aplicalo solo en namespaces con label `environment=prod`:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "demo-replica-limit-binding.example.com"
spec:
  policyName: "demo-replica-limit.example.com"
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: prod
```

```bash
kubectl apply -f vap-replica-limit-binding.yaml
kubectl create ns prod-app
kubectl label ns prod-app environment=prod
```

**Paso 3.** Probá el límite en `prod-app`:

```bash
kubectl -n prod-app create deployment web --image=nginx:1.27 --replicas=8
```

Salida esperada:

```
error: failed to create deployment: deployments.apps "web" is forbidden:
ValidatingAdmissionPolicy 'demo-replica-limit.example.com' with binding
'demo-replica-limit-binding.example.com' denied request: El número de réplicas
del Deployment no puede superar 5.
```

**Paso 4.** El mismo comando en un namespace *sin* el label `environment=prod` no dispara la policy (el binding no matchea):

```bash
kubectl create ns dev-app
kubectl -n dev-app create deployment web --image=nginx:1.27 --replicas=8
```

Salida esperada:

```
deployment.apps/web created
```

**Paso 5.** Cambiá el binding a modo auditable sin bloquear, para un rollout gradual como el del Ejercicio 2:

```bash
kubectl patch validatingadmissionpolicybinding \
  demo-replica-limit-binding.example.com --type=merge \
  -p '{"spec":{"validationActions":["Warn","Audit"]}}'
kubectl -n prod-app create deployment web2 --image=nginx:1.27 --replicas=8
```

Salida esperada:

```
Warning: Validation failed for ValidatingAdmissionPolicy 'demo-replica-limit.example.com' with binding 'demo-replica-limit-binding.example.com': El número de réplicas del Deployment no puede superar 5.
deployment.apps/web2 created
```

### Preguntas de comprensión — Bloque 5

1. ¿Qué ventaja de disponibilidad y latencia tiene una VAP nativa frente a Gatekeeper o Kyverno, que corren como webhooks externos? ¿Qué relación tiene esto con `failurePolicy`?
2. Una VAP sin `ValidatingAdmissionPolicyBinding` está aplicada en el cluster pero no bloquea nada. ¿Por qué el diseño separa policy y binding, y qué te permite hacer con un binding que no podrías con la policy sola?
3. `validationActions` acepta `Deny`, `Warn` y `Audit` combinables. ¿Cómo mapea esto a los modos `deny`/`warn`/`dryrun` de Gatekeeper del Ejercicio 2, y dónde aparece el resultado de un `Audit`?

---

## Ejercicio 6 — Elegir el motor: síntesis de governance

Sin ejecutar nada, resolvé estos escenarios de diseño. Es el tipo de decisión de arquitectura que el CNPA evalúa en este tema.

**Escenario A.** El equipo de seguridad necesita bloquear imágenes sin firmar (verificación de firmas cosign/sigstore) y rechazar Pods con `hostNetwork: true`, y quiere que las políticas se puedan versionar en Git como CRDs de Kubernetes sin aprender un lenguaje nuevo.

**Escenario B.** Una regla que compara *entre sí* dos campos de objetos distintos con lógica compleja de conjuntos, reutilizando librerías Rego que la organización ya mantiene para su CI de OPA fuera de Kubernetes.

**Escenario C.** Un límite simple de campo (`replicas <= 5`, imágenes de un registry permitido) en un cluster donde el equipo de plataforma quiere el mínimo de componentes instalados y ningún punto de fallo de webhook.

Para cada escenario, elegí **OPA Gatekeeper**, **Kyverno** o **VAP nativa** y justificá con un criterio técnico (expresividad, dependencias, mutate/generate, disponibilidad).

### Preguntas de comprensión — Bloque 6

1. ¿Cuál de los tres motores es el único que puede **mutar** y **generar** recursos además de validar, y por qué eso lo hace el más completo para self-service de plataforma?
2. ¿Qué motor introduce la dependencia operativa más liviana y por qué, aun así, no reemplaza a los otros dos en todos los casos?
3. Los tres viven en el admission chain. Nombrá una clase de política de governance que **no** se puede implementar solo con admission control y que necesita un componente que observe el estado *después* de la persistencia (runtime/continuous scanning).

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1 — Gatekeeper: template + constraint

1. **Separación template/constraint.** El `ConstraintTemplate` es la lógica reutilizable (el "qué") y genera un CRD; el `Constraint` es una instancia parametrizada (el "dónde" y "con qué valores"). Ventaja operativa: una sola plantilla `K8sRequiredLabels` sirve para decenas de constraints distintos (namespaces con `owner`, Deployments con `cost-center`, etc.) sin duplicar Rego. Además, el CRD generado permite versionar y auditar cada constraint como un objeto de primera clase de Kubernetes, y delegar su edición a equipos sin tocar el Rego.

2. **`count(missing) > 0`.** Rego evalúa reglas como *queries* que producen violaciones solo cuando **todas** sus expresiones son verdaderas (se unifican). Sin `count(missing) > 0`, el bloque `violation` intentaría generarse siempre, y el `sprintf` con un `missing` vacío reportaría "you must provide labels: []" incluso cuando no falta ningún label. La regla dejaría de ser correcta: marcaría como violación a objetos que cumplen. Esa línea es la condición de guarda que hace que la violación exista *solo* cuando el conjunto de faltantes es no vacío.

3. **Fase del admission chain.** El error lo devuelve el `ValidatingWebhookConfiguration` de Gatekeeper durante la fase de **validating admission**, que ocurre *después* de autenticación, autorización (RBAC) y mutating admission, pero **antes** de escribir en etcd. Como la validación rechaza la request en esa fase, el objeto nunca se persiste: no hay un Namespace "a medio crear" que limpiar. Ese es el valor de hacer governance en admission y no post-hoc.

### Bloque 2 — Enforce vs audit

1. **`dryrun` / `warn` / `deny`.** En los tres el objeto se evalúa contra la política. La diferencia es qué pasa con la operación y el cliente: `deny` rechaza la request y el objeto **no** se persiste; `warn` deja que la operación **proceda** (el objeto se crea) pero devuelve un `Warning:` al cliente; `dryrun` **no** bloquea ni avisa al cliente en el momento de la escritura, solo registra la violación en el audit (`status`), útil para medir impacto en silencio.

2. **Audit loop.** Gatekeeper corre un ciclo de auditoría periódico (por defecto cada 60 s) que reevalúa los objetos **ya existentes** en el cluster contra los constraints y escribe las violaciones en `status.violations` del constraint. Por eso apareció `default`, que existía desde antes de la política. Es imprescindible en un rollout gradual porque te dice cuánto del *estado actual* incumpliría una política antes de ponerla en `deny`: sin eso, activarías `deny` a ciegas.

3. **Riesgo de `deny` directo.** (a) Podés bloquear pipelines de CD y a operadores legítimos de golpe si el estado existente ya viola la regla, provocando un incidente autoinfligido. (b) No tenés forma de estimar el alcance ("¿cuántos equipos rompo?") sin una fase de medición; `dryrun`/`audit` te da esa métrica y permite avisar a los dueños antes de endurecer.

### Bloque 3 — Kyverno validate

1. **DSL vs lenguaje general.** Kyverno gana en **accesibilidad y mantenibilidad**: las políticas son YAML con patterns, legibles por cualquiera que ya sepa manifiestos de Kubernetes, sin curva de aprendizaje de Rego. Pierde en **expresividad**: lógica arbitraria, comparaciones cruzadas complejas o reutilización de librerías externas son más limitadas que en Rego (aunque Kyverno agregó CEL y `foreach`/JMESPath para casos avanzados). El trade-off es DSL declarativo específico de dominio vs lenguaje de propósito general.

2. **`failureAction` por regla.** Ponerlo dentro de la regla permite que una misma `ClusterPolicy` tenga reglas en modos distintos: p. ej. una regla madura en `Enforce` y otra recién agregada en `Audit`, conviviendo. A nivel de spec estarías forzado a un único modo para toda la policy, lo que dificulta el rollout incremental regla por regla.

3. **`background: true`.** El background scan reevalúa los recursos **ya existentes** en el cluster (no solo los que pasan por admission en vivo) y produce/actualiza `PolicyReport`s. Es el equivalente conceptual del audit loop de Gatekeeper: ambos dan visibilidad del cumplimiento del *estado actual* independientemente de si la política bloquea escrituras nuevas. Nota: algunas reglas con contexto de admission (p. ej. que dependen de `AdmissionReview`) no pueden evaluarse en background.

### Bloque 4 — Kyverno mutate y generate

1. **Orden mutate → validate.** El mutating admission corre **antes** que el validating admission en la cadena del API server. Por eso, si un Pod entra sin `runAsNonRoot`, la policy `mutate` lo inyecta primero y la policy `validate` (propia o de otro motor) ve el objeto **ya mutado**. Esto evita rechazar objetos que una mutación habría vuelto conformes, y es la razón por la que defaults seguros por mutación reducen los rechazos.

2. **`synchronize`.** Con `synchronize: true`, Kyverno trata el recurso generado como *owned*: si alguien lo edita o lo borra, lo revierte/recrea para mantenerlo alineado con la policy (como viste al borrar la NetworkPolicy). Con `synchronize: false`, Kyverno lo genera una sola vez y no vuelve a tocarlo: las ediciones manuales posteriores persisten y un borrado no se recrea. `true` es para invariantes de plataforma no negociables; `false`, para un scaffold inicial que el equipo puede personalizar.

3. **Anchor `+(...)` (add-if-absent).** Solo agrega el valor si la clave no existe, así que respeta las decisiones legítimas del equipo de aplicación que ya declaró `runAsNonRoot: false` por una necesidad real (o cualquier otro valor), en lugar de pisarlo silenciosamente. Sobrescribir siempre haría que la plataforma tomara una decisión que quizá rompe cargas legítimas y que el dueño no puede anular: el default seguro debe ser un *piso*, no una imposición ciega. (Si la intención fuera prohibir `false`, eso corresponde a una regla `validate`, no a un mutate que pise.)

### Bloque 5 — ValidatingAdmissionPolicy (CEL)

1. **Disponibilidad y latencia.** La VAP la evalúa el propio kube-apiserver, in-process: no hay un pod de webhook externo al que llamar por red, así que no agrega latencia de red ni un componente que pueda caerse. En un webhook, si el pod está caído, `failurePolicy: Fail` bloquea las escrituras (fail-closed) y `Ignore` las deja pasar sin política (fail-open); ambas son malas. La VAP elimina esa clase de fallo porque no hay backend que pueda estar indisponible aparte del propio API server.

2. **Policy vs binding.** El diseño separa la *definición* de la regla de su *activación y alcance*. Una `ValidatingAdmissionPolicy` sin binding está registrada pero inerte. El `ValidatingAdmissionPolicyBinding` es el que la enciende y define a qué namespaces/recursos aplica (vía `matchResources`, selectors) y con qué acción (`validationActions`). Esto te permite: reutilizar una misma policy con bindings distintos por entorno (p. ej. `Deny` en prod, `Warn` en dev), y activar/desactivar governance moviendo el binding sin tocar la lógica.

3. **`validationActions` ↔ modos de Gatekeeper.** `Deny` ≈ `deny` (rechaza la request); `Warn` ≈ `warn` (procede y devuelve `Warning:` al cliente); `Audit` ≈ `dryrun` (no bloquea; el resultado se registra como *audit annotation* en el audit log del API server, no en el status del objeto). Son combinables: `["Warn","Audit"]` avisa al cliente y además deja rastro en el audit log, ideal para el rollout gradual del Ejercicio 2.

### Bloque 6 — Elegir el motor

- **Escenario A → Kyverno.** Verificación de firmas de imágenes (regla `verifyImages` con cosign/sigstore) y validaciones tipo `hostNetwork: true` son su fuerte, todo en YAML declarativo versionable en Git sin aprender un lenguaje nuevo. Es el criterio de accesibilidad + capacidades de supply chain.
- **Escenario B → OPA Gatekeeper.** Lógica compleja de conjuntos y comparaciones cruzadas, reutilizando librerías **Rego** ya mantenidas para el CI de OPA fuera del cluster. El criterio es expresividad y reutilización del ecosistema OPA existente.
- **Escenario C → VAP nativa (CEL).** Reglas de campo simples (`replicas <= 5`, registry permitido) con **cero componentes instalados** y sin punto de fallo de webhook. El criterio es dependencia mínima y disponibilidad.

1. **Kyverno** es el único de los tres que valida, **muta** y **genera** (los otros dos, en su núcleo de este temario, se centran en validación; Gatekeeper tiene mutación vía `Assign` pero no generación de recursos). Poder inyectar defaults y provisionar recursos base por namespace lo vuelve el más completo para *self-service*: el equipo de aplicación crea un namespace y la plataforma le materializa NetworkPolicies, quotas y defaults seguros sin intervención manual.

2. **VAP nativa** es la de menor peso operativo: no instalás nada, corre en el API server y no agrega un webhook que pueda caerse. Aun así no reemplaza a los otros porque **no muta ni genera** y su expresividad (CEL) es más acotada que Rego para lógica compleja o para features de supply chain como verificación de firmas.

3. **Runtime / continuous scanning.** Cualquier política sobre lo que *ocurre después* de admitir el objeto: detección de un container que en runtime hace `exec` sospechoso, un proceso que escala privilegios, drift de configuración por un actor externo, o una CVE que aparece en una imagen *ya desplegada*. El admission control solo ve el momento de la escritura; para el estado en ejecución hacen falta herramientas de runtime security / continuous compliance (p. ej. Falco, o el scanning continuo de un motor que reevalúe el cluster en vivo).

</details>

---

### Fuentes oficiales

- CNCF CNPA Curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes — Admission Controllers Reference: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — Validating Admission Policy: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — CEL en la API: https://kubernetes.io/docs/reference/using-api/cel/
- OPA Gatekeeper — Documentación: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Open Policy Agent — Rego / Policy Language: https://www.openpolicyagent.org/docs/latest/policy-language/
- Kyverno — Documentación (validate, mutate, generate, verifyImages): https://kyverno.io/docs/