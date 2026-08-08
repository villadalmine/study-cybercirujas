# Ejercicios guiados — 3.4 Using Policy Engines and Admission Controllers for Governance

> **Requisitos previos.** Un cluster de laboratorio donde tengas permisos de `cluster-admin` y acceso al `control-plane` (idealmente `kind` o `minikube`, no un cluster productivo). Kubernetes **1.30 o superior** para el Ejercicio 2 (`ValidatingAdmissionPolicy` llega a GA en 1.30). `kubectl`, `helm` y `curl` instalados. Trabajá siempre contra un namespace desechable.
>
> ```bash
> kind create cluster --name gov-lab --image kindest/node:v1.30.0
> kubectl create namespace tenant-a
> ```
>
> **Advertencia de gobernanza:** las políticas que vas a instalar interceptan *todo* el tráfico de escritura del API server. Un webhook mal configurado con `failurePolicy: Fail` puede dejar el cluster sin poder crear Pods. Por eso el laboratorio empieza en modo auditoría y sólo al final pasa a `Deny`/`Enforce`.

---

## Ejercicio 1 — Mapear la cadena de admisión antes de tocar nada

**Objetivo:** entender *dónde* en el ciclo de vida de una request se ejecutan las políticas, y confirmar qué admission controllers ya están activos por defecto.

1. Observá el orden real de la cadena de admisión. Una request de escritura atraviesa, en este orden: **Authentication → Authorization → Mutating admission → Object schema validation → Validating admission → etcd**. Listá los admission plugins compilados y habilitados por defecto en tu API server:

   ```bash
   kubectl -n kube-system get pod -l component=kube-apiserver \
     -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep admission
   ```

   Salida esperada (en `kind`, los plugins van implícitos porque no se pasa el flag, así que puede salir vacío). Para ver la lista efectiva, consultá directamente el manifiesto estático del control-plane:

   ```bash
   docker exec gov-lab-control-plane \
     grep -A1 'enable-admission-plugins\|NodeRestriction' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

   Salida esperada (recortada):

   ```
   - --enable-admission-plugins=NodeRestriction
   ```

2. Verificá que los dos admission controllers *dinámicos* (los que permiten enchufar políticas externas) estén activos. Están habilitados por defecto desde hace muchas versiones:

   ```bash
   kubectl api-resources --api-group=admissionregistration.k8s.io
   ```

   Salida esperada:

   ```
   NAME                              SHORTNAMES   APIVERSION                             NAMESPACED   KIND
   mutatingwebhookconfigurations                  admissionregistration.k8s.io/v1        false        MutatingWebhookConfiguration
   validatingadmissionpolicies                    admissionregistration.k8s.io/v1        false        ValidatingAdmissionPolicy
   validatingadmissionpolicybindings              admissionregistration.k8s.io/v1        false        ValidatingAdmissionPolicyBinding
   validatingwebhookconfigurations                admissionregistration.k8s.io/v1        false        ValidatingWebhookConfiguration
   ```

3. Mirá los webhooks que ya existen (puede que haya alguno de un CNI o del cloud provider):

   ```bash
   kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
   ```

**Preguntas de comprensión (E1):**

- **1.a** Si una política tiene que *inyectar* un valor por defecto (por ejemplo un sidecar o un label), ¿tiene que ser un mutating o un validating webhook, y por qué el orden de la cadena lo obliga?
- **1.b** ¿Por qué un `MutatingWebhookConfiguration` y un `ValidatingWebhookConfiguration` son recursos *cluster-scoped* (`NAMESPACED = false`) y no namespaced?
- **1.c** Un compañero propone validar el request *después* de que el objeto se persiste en etcd, en un controller que reacciona a los eventos. ¿Qué garantía pierde frente a un validating admission webhook?

---

## Ejercicio 2 — Política nativa con `ValidatingAdmissionPolicy` y CEL (sin motor externo)

**Objetivo:** aplicar la vía *in-tree* de Kubernetes (GA en 1.30) que evalúa expresiones **CEL** dentro del propio API server, sin desplegar ningún pod extra ni pagar el salto de red de un webhook.

1. Creá la política. Exige que todo `Deployment` lleve el label `team` y prohíbe la imagen `:latest`:

   ```yaml
   # vap-guardrails.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: deployment-guardrails
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
         - apiGroups:   ["apps"]
           apiVersions: ["v1"]
           operations:  ["CREATE", "UPDATE"]
           resources:   ["deployments"]
     validations:
       - expression: "'team' in object.metadata.labels"
         message: "Todo Deployment debe declarar el label 'team'."
         reason: Invalid
       - expression: >-
           object.spec.template.spec.containers.all(c, !c.image.endsWith(':latest'))
         message: "No se permite el tag ':latest'; fijá una versión inmutable."
         reason: Invalid
   ```

   ```bash
   kubectl apply -f vap-guardrails.yaml
   ```

2. Una `ValidatingAdmissionPolicy` **por sí sola no hace nada**: sólo se activa cuando un `ValidatingAdmissionPolicyBinding` la enlaza a un conjunto de recursos y define la acción. Empezá en modo no destructivo con `Audit` + `Warn`:

   ```yaml
   # vap-binding.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: deployment-guardrails-binding
   spec:
     policyName: deployment-guardrails
     validationActions: ["Warn", "Audit"]
     matchResources:
       namespaceSelector:
         matchLabels:
           kubernetes.io/metadata.name: tenant-a
   ```

   ```bash
   kubectl apply -f vap-binding.yaml
   ```

3. Probá con un Deployment que viola ambas reglas. En modo `Warn` la creación **se permite**, pero el API server devuelve un warning:

   ```bash
   kubectl -n tenant-a create deployment nginx --image=nginx:latest
   ```

   Salida esperada:

   ```
   Warning: Todo Deployment debe declarar el label 'team'.
   Warning: No se permite el tag ':latest'; fijá una versión inmutable.
   deployment.apps/nginx created
   ```

4. Ahora endurecé la política. Editá el binding y cambiá la acción a `Deny`:

   ```bash
   kubectl patch validatingadmissionpolicybinding deployment-guardrails-binding \
     --type=json -p='[{"op":"replace","path":"/spec/validationActions","value":["Deny"]}]'
   ```

5. Repetí la creación de un Deployment infractor y verificá que ahora se rechaza:

   ```bash
   kubectl -n tenant-a create deployment bad --image=redis:latest
   ```

   Salida esperada:

   ```
   error: failed to create deployment: deployments.apps "bad" is forbidden:
   ValidatingAdmissionPolicy 'deployment-guardrails' with binding
   'deployment-guardrails-binding' denied request: No se permite el tag ':latest'; fijá una versión inmutable.
   ```

6. Confirmá que un Deployment correcto pasa limpio:

   ```bash
   kubectl -n tenant-a create deployment good --image=nginx:1.27 --dry-run=client -o yaml \
     | kubectl label --local -f - team=payments -o yaml \
     | kubectl apply -f -
   ```

   Salida esperada: `deployment.apps/good created`.

**Preguntas de comprensión (E2):**

- **2.a** ¿Cuál es la diferencia funcional entre las acciones `Warn`, `Audit` y `Deny` de un binding, y cuál es la secuencia correcta para introducir una política nueva en un cluster con inquilinos reales?
- **2.b** La expresión usa `containers.all(c, ...)`. ¿Qué devuelve `all()` sobre una lista vacía, y qué implicación de seguridad tiene eso para un Pod sin containers (que igual no es válido, pero conceptualmente)?
- **2.c** Frente a un `ValidatingWebhookConfiguration` que apunta a un pod externo (OPA/Gatekeeper, Kyverno), enumerá **dos** ventajas concretas de `ValidatingAdmissionPolicy` y **una** limitación importante.
- **2.d** ¿Por qué `failurePolicy: Fail` es *mucho* menos peligroso en una `ValidatingAdmissionPolicy` que en un webhook externo?

---

## Ejercicio 3 — Kyverno: validate, mutate y generate

**Objetivo:** usar un policy engine declarativo (sin Rego) para las tres operaciones de gobernanza: **rechazar**, **mutar por defecto** y **generar** recursos derivados.

1. Instalá Kyverno con Helm y esperá a que esté listo:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   ```

2. **Validate.** Prohibí que los Pods corran como root. Empezá siempre en `Audit`:

   ```yaml
   # kyverno-runasnonroot.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-run-as-non-root
   spec:
     validationFailureAction: Audit    # cambia a Enforce cuando esté validado
     background: true
     rules:
       - name: check-runasnonroot
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         validate:
           message: "El Pod debe declarar securityContext.runAsNonRoot: true."
           pattern:
             spec:
               =(securityContext):
                 =(runAsNonRoot): true
               containers:
                 - =(securityContext):
                     =(runAsNonRoot): true
   ```

   ```bash
   kubectl apply -f kyverno-runasnonroot.yaml
   ```

   > **Nota de versión:** en Kyverno ≥ 1.12 `spec.validationFailureAction` está *deprecado* a favor de `spec.rules[].validate.failureAction`. Ambos funcionan en 1.12; en 1.13+ usá el per-rule.

3. **Mutate.** Inyectá un label por defecto sólo si no existe (anchor `+()` = "add if not present"):

   ```yaml
   # kyverno-default-label.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-default-team-label
   spec:
     rules:
       - name: add-team-label
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         mutate:
           patchStrategicMerge:
             metadata:
               labels:
                 +(team): "unassigned"
   ```

   ```bash
   kubectl apply -f kyverno-default-label.yaml
   kubectl -n tenant-a run probe --image=nginx:1.27 --restart=Never
   kubectl -n tenant-a get pod probe -o jsonpath='{.metadata.labels}'
   ```

   Salida esperada:

   ```
   {"run":"probe","team":"unassigned"}
   ```

4. **Generate.** Materializá una `NetworkPolicy` default-deny en cada namespace nuevo, y mantenela sincronizada:

   ```yaml
   # kyverno-default-netpol.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: generate-default-deny
   spec:
     rules:
       - name: default-deny-per-ns
         match:
           any:
             - resources:
                 kinds: ["Namespace"]
         generate:
           apiVersion: networking.k8s.io/v1
           kind: NetworkPolicy
           name: default-deny
           namespace: "{{request.object.metadata.name}}"
           synchronize: true
           data:
             spec:
               podSelector: {}
               policyTypes: ["Ingress", "Egress"]
   ```

   ```bash
   kubectl apply -f kyverno-default-netpol.yaml
   kubectl create namespace tenant-b
   kubectl -n tenant-b get networkpolicy
   ```

   Salida esperada:

   ```
   NAME           POD-SELECTOR   AGE
   default-deny   <none>         2s
   ```

5. Revisá el informe de políticas que Kyverno genera automáticamente en modo `Audit` (recurso `PolicyReport`):

   ```bash
   kubectl -n tenant-a get policyreport -o wide
   ```

   Salida esperada (recortada):

   ```
   NAME                          KIND   NAME     PASS   FAIL   WARN   ERROR   SKIP   AGE
   pol-...                       Pod    probe    1      1      0      0      0      30s
   ```

**Preguntas de comprensión (E3):**

- **3.a** ¿Qué hace el campo `synchronize: true` en una regla `generate` si alguien borra a mano la `NetworkPolicy` generada? ¿Y si edita la `ClusterPolicy` de origen?
- **3.b** Los anchors de Kyverno `=()` (conditional) y `+()` (add-if-absent) hacen cosas distintas. Explicá por qué el patrón de `runAsNonRoot` usa `=()` y no exige el campo siempre.
- **3.c** ¿Por qué `background: true` es relevante y qué mide `PolicyReport` que un simple `Deny` en admisión *no* podría medir sobre los recursos ya existentes?
- **3.d** Kyverno ejecuta primero las reglas `mutate` y luego las `validate` sobre el objeto ya mutado. Si tenés una policy que muta el label `team` y otra que lo valida, ¿en qué orden hay que confiar y por qué eso replica la cadena nativa de admisión?

---

## Ejercicio 4 — OPA/Gatekeeper: `ConstraintTemplate` + `Constraint` con Rego

**Objetivo:** modelar la misma clase de guardrail con el motor de propósito general (Rego), entendiendo la separación template/constraint que permite parametrizar y reutilizar políticas entre equipos.

1. Instalá Gatekeeper:

   ```bash
   helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
   helm repo update
   helm install gatekeeper gatekeeper/gatekeeper -n gatekeeper-system --create-namespace
   kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager
   ```

2. Definí un `ConstraintTemplate` (el *qué* se puede validar, con la lógica Rego) que exige labels arbitrarios:

   ```yaml
   # gk-required-labels-template.yaml
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
             msg := sprintf("faltan labels obligatorios: %v", [missing])
           }
   ```

   ```bash
   kubectl apply -f gk-required-labels-template.yaml
   ```

3. Instanciá un `Constraint` (el *dónde* y con qué parámetros). Fijate que el `kind` del constraint es exactamente el `names.kind` del template:

   ```yaml
   # gk-ns-owner-constraint.yaml
   apiVersion: constraints.gatekeeper.sh/v1beta1
   kind: K8sRequiredLabels
   metadata:
     name: ns-must-have-owner
   spec:
     enforcementAction: dryrun    # dryrun = audita sin bloquear; luego deny
     match:
       kinds:
         - apiGroups: [""]
           kinds: ["Namespace"]
     parameters:
       labels: ["owner"]
   ```

   ```bash
   kubectl apply -f gk-ns-owner-constraint.yaml
   ```

4. Con `enforcementAction: dryrun`, creá un namespace sin el label. **Se permite**, pero Gatekeeper registra la violación en el status del constraint tras el próximo ciclo de audit:

   ```bash
   kubectl create namespace no-owner
   sleep 60   # esperá un ciclo de auditoría
   kubectl get k8srequiredlabels ns-must-have-owner \
     -o jsonpath='{.status.totalViolations}{"\n"}'
   ```

   Salida esperada: un entero ≥ `1`.

5. Endurecé a `deny` y probá el rechazo en admisión:

   ```bash
   kubectl patch k8srequiredlabels ns-must-have-owner \
     --type=merge -p '{"spec":{"enforcementAction":"deny"}}'
   kubectl create namespace still-no-owner
   ```

   Salida esperada:

   ```
   Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
   [ns-must-have-owner] faltan labels obligatorios: {"owner"}
   ```

**Preguntas de comprensión (E4):**

- **4.a** ¿Por qué Gatekeeper separa `ConstraintTemplate` de `Constraint`? Dá un caso concreto donde un solo template se reutilice en tres constraints distintos.
- **4.b** En Rego, la regla se llama `violation` y el resultado *positivo* (que la regla "matchee") significa **rechazo**. ¿Cómo se compara ese modelo mental con Kyverno, donde escribís el `pattern` que el recurso *debe cumplir*?
- **4.c** ¿Qué es el ciclo de *audit* de Gatekeeper y por qué te deja detectar recursos preexistentes que violan una política nueva, cosa que la admisión nunca ve?
- **4.d** Comparado con `ValidatingAdmissionPolicy` (Ejercicio 2), ¿qué te da Rego que CEL no, y qué costo operacional agrega desplegar Gatekeeper?

---

## Ejercicio 5 — Blindar el propio plano de gobernanza (`failurePolicy` y alcance)

**Objetivo:** entender el mayor riesgo operativo de los admission webhooks externos —dejar el cluster inoperable— y las mitigaciones estándar: `namespaceSelector` de exclusión, `matchConditions` y `timeoutSeconds`.

1. Inspeccioná el webhook de validación que instaló Kyverno y mirá su `failurePolicy` y sus exclusiones:

   ```bash
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{.webhooks[0].failurePolicy}{"\n"}{.webhooks[0].namespaceSelector}{"\n"}'
   ```

   Salida esperada (recortada) — notá cómo excluye los namespaces del sistema:

   ```
   Fail
   {"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["kube-system","kyverno"]}]}
   ```

2. Simulá el escenario de fallo. Si un webhook `Fail` apunta a un servicio caído y **no** excluye a `kube-system`, el propio control-plane no puede reconciliar. Comprobá que los namespaces críticos están fuera del alcance de *tus* políticas agregando un `matchConditions` que excluya cargas del sistema en una `ValidatingAdmissionPolicy`:

   ```yaml
   # vap-scope-guard.yaml (fragmento del spec)
   spec:
     matchConditions:
       - name: exclude-system-namespaces
         expression: >-
           !(request.namespace in ['kube-system', 'kube-node-lease', 'gatekeeper-system', 'kyverno'])
   ```

3. Verificá el `timeoutSeconds` de los webhooks externos (un timeout alto multiplica la latencia de cada request de escritura del cluster):

   ```bash
   kubectl get mutatingwebhookconfigurations -o custom-columns=\
   NAME:.metadata.name,TIMEOUT:.webhooks[*].timeoutSeconds,POLICY:.webhooks[*].failurePolicy
   ```

**Preguntas de comprensión (E5):**

- **5.a** Explicá la disyuntiva `failurePolicy: Fail` vs `Ignore` en términos de **seguridad** (fail-closed) vs **disponibilidad** (fail-open). ¿Qué elegirías para una política de "prohibir imágenes sin firmar" y qué para una de "inyectar un label de costeo"?
- **5.b** ¿Por qué es una práctica obligatoria excluir `kube-system` (y el namespace del propio policy engine) del alcance de los webhooks? Describí la falla en cascada que ocurre si no se hace y el engine se cae.
- **5.c** ¿Qué problema resuelve `matchConditions` (CEL) que `namespaceSelector`/`objectSelector` no pueden expresar, y por qué reducir el conjunto de objetos que llegan a evaluarse importa para el rendimiento del API server?

---

## Respuestas

<details>
<summary>Ver respuestas (E1–E5)</summary>

### Ejercicio 1

- **1.a** Tiene que ser un **mutating** webhook. La cadena ejecuta *mutating admission antes que validating admission* y antes del schema validation. Sólo en la fase de mutación se permite modificar el objeto (mediante un JSONPatch); un validating webhook no puede alterar el objeto, sólo aceptarlo o rechazarlo. Además, el resultado de la mutación es lo que después validan las etapas posteriores, por eso los defaults se inyectan primero.
- **1.b** Porque una `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` describe una *intercepción del propio API server* para uno o más recursos (potencialmente de cualquier namespace, o recursos cluster-scoped como `Namespace` o `PersistentVolume`). El objeto de configuración vive en el plano de control, no dentro de un namespace; su `namespaceSelector`/`objectSelector` es lo que acota *qué* se intercepta.
- **1.c** Pierde la capacidad de **rechazar** la escritura: para cuando el controller reacciona por evento, el objeto ya está persistido en etcd y ya pudo haber sido actuado (por ejemplo, un Pod ya fue schedulado). El validating admission webhook es la última barrera *síncrona* antes de la persistencia; la validación post-hoc sólo puede *remediar* (borrar/parchar) después del hecho, con una ventana de inconsistencia.

### Ejercicio 2

- **2.a** `Warn` devuelve el mensaje como warning HTTP pero **permite** la operación; `Audit` la registra en el audit log (annotation `validation.policy.admission.k8s.io/...`) sin afectar al usuario ni al request; `Deny` la **rechaza**. La secuencia correcta de rollout es: `Audit` (medir impacto sobre lo real sin molestar) → `Warn` (avisar a los equipos, generar fricción visible) → `Deny` (enforcement). Nunca empezar en `Deny` sobre un cluster con inquilinos.
- **2.b** `all()` sobre una lista vacía devuelve **`true`** (cuantificador universal vacío = verdadero). Implicación: una regla del tipo "todos los containers cumplen X" *no atrapa* el caso de cero containers; si eso importa, hay que añadir una validación explícita de `size(containers) > 0`. Es el error clásico de las políticas basadas en `all()`.
- **2.c** Ventajas de `ValidatingAdmissionPolicy`: (1) se evalúa **dentro del API server**, sin salto de red a un pod externo → menor latencia y sin punto de fallo adicional; (2) no hay que operar, escalar ni certificar (TLS) un deployment de webhook, y no puede tumbar el cluster si "se cae" porque no existe como servicio separado. Limitación importante: **CEL es más restringido que Rego** — no puede hacer lookups de otros recursos del cluster de forma nativa (sin `paramKind`/parámetros predefinidos), no genera ni muta recursos (sólo valida), y expresa lógica menos rica que un lenguaje de políticas completo.
- **2.d** Porque `ValidatingAdmissionPolicy` corre *en proceso* dentro del API server: no hay un servicio externo que pueda estar caído. `failurePolicy: Fail` ahí sólo dispara si la *expresión CEL* falla en compilar/evaluar (error de tipos), no por indisponibilidad de red. En un webhook externo, `Fail` significa "si el pod del engine no responde, rechazo todo", lo que puede dejar el cluster inoperable.

### Ejercicio 3

- **3.a** Con `synchronize: true`, Kyverno **reconcilia** el recurso generado: si alguien borra la `NetworkPolicy`, Kyverno la vuelve a crear; si se edita la `ClusterPolicy` de origen (el `data`), propaga el cambio a todos los recursos ya generados. Sin `synchronize` (o `false`), el recurso se crea una sola vez y queda huérfano (drift permitido).
- **3.b** `=()` es un anchor *condicional*: "si el campo existe, entonces debe cumplir este valor". Se usa en `runAsNonRoot` para no romper Pods que legítimamente definen el `securityContext` en otro nivel, validando el valor sólo cuando el campo está presente en ese nivel. `+()` es *add-if-absent*: pone un default sólo si el campo falta, sin pisar lo que el usuario ya definió. Son operaciones opuestas: uno valida, el otro muta con default.
- **3.c** `background: true` hace que Kyverno escanee **periódicamente los recursos ya existentes** en el cluster contra la política, no sólo los nuevos que pasan por admisión. `PolicyReport` acumula ese resultado (PASS/FAIL por recurso). Un `Deny` en admisión sólo ve escrituras nuevas; jamás te dice cuántos de los 500 Pods que *ya corren* violarían la política nueva. Eso es clave para planificar un rollout de `Enforce`.
- **3.d** Hay que confiar en que **mutate corre antes que validate** (Kyverno respeta el orden de la cadena de admisión nativa: primero muta, luego valida sobre el objeto ya mutado). Por eso una política que inyecta `team=unassigned` y otra que valida la presencia de `team` funcionan juntas: la validación ve el objeto ya con el label puesto. Invertir mentalmente ese orden lleva a falsos rechazos.

### Ejercicio 4

- **4.a** El `ConstraintTemplate` define la **lógica** (el Rego) y publica un CRD nuevo; el `Constraint` es una **instancia parametrizada** que dice a qué recursos aplicar y con qué parámetros/acción. Ejemplo: un único template `K8sRequiredLabels` reutilizado en tres constraints — uno que exige `owner` en Namespaces, otro que exige `cost-center` en Deployments de producción, y otro que exige `data-classification` en PVCs. Una sola pieza de Rego, tres guardrails.
- **4.b** Son modelos **invertidos**. En Gatekeeper/Rego describís la **violación**: si la regla `violation` produce resultados, el recurso se rechaza (describís lo *malo*). En Kyverno con `validate.pattern` describís lo que el recurso **debe cumplir** (describís lo *bueno*); si no matchea el patrón, falla. Rego = "detectá lo prohibido"; Kyverno pattern = "exigí lo requerido".
- **4.c** El *audit* de Gatekeeper es un bucle en segundo plano que reevalúa **todos los recursos existentes** contra todos los constraints cada cierto intervalo (`--audit-interval`) y escribe las violaciones en `status.violations`/`totalViolations` de cada constraint. La admisión sólo intercepta escrituras nuevas; el audit es lo que te muestra la deuda preexistente antes de pasar a `deny`.
- **4.d** Rego es un lenguaje de políticas **Turing-incompleto pero muy expresivo**: comprehensions, conjuntos, joins, y con `data`/replicación de recursos puede correlacionar *varios* objetos del cluster (por ejemplo "ningún Ingress puede repetir un host ya usado por otro"), algo que CEL en una `ValidatingAdmissionPolicy` no hace nativamente. El costo: desplegás y operás Gatekeeper (controller + audit + webhook con TLS), sumás latencia de red por request y un punto de fallo que hay que excluir de `kube-system` y monitorear.

### Ejercicio 5

- **5.a** `Fail` (fail-closed): si el engine no responde, se **rechaza** la operación → prioriza seguridad, arriesga disponibilidad. `Ignore` (fail-open): si no responde, se **permite** → prioriza disponibilidad, arriesga que pase algo prohibido. Para "prohibir imágenes sin firmar" (control de seguridad crítico de la supply chain) → `Fail`: mejor bloquear que dejar entrar un artefacto no verificado. Para "inyectar un label de costeo" (conveniencia operativa) → `Ignore`: un label faltante no justifica frenar los deploys de todo el cluster.
- **5.b** Si el webhook es `Fail` y no excluye `kube-system` ni el namespace del propio engine, y el engine se cae, entonces **ninguna** escritura en esos namespaces se puede completar — incluidos los Pods del propio policy engine que intentan reprogramarse, los componentes de sistema y el scheduler/controllers. Es una falla en cascada auto-bloqueante: el engine no puede recuperarse porque su propia recreación requiere pasar por el webhook que él mismo debería atender. Por eso `kube-system` y el namespace del engine siempre se excluyen (fail-open localizado).
- **5.c** `matchConditions` evalúa **CEL sobre el contenido del request** (campos del objeto, usuario, verbo, etc.), no sólo labels de namespace/objeto como los selectores. Permite filtrar por lógica arbitraria: "sólo si `request.userInfo.username != 'system:...'`" o "sólo si el objeto tiene tal spec". Reducir el conjunto de requests que realmente llegan a la evaluación de la política (o al salto de red del webhook) baja la latencia añadida a *cada* escritura del cluster y descarga al API server: la evaluación cara sólo corre sobre los objetos que de verdad importan.

</details>

---

## Fuentes

- Kubernetes — *Dynamic Admission Control* (webhooks, orden de la cadena, `failurePolicy`, `matchConditions`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — *Validating Admission Policy* (CEL, bindings, `validationActions`; GA en 1.30): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — *Admission Controllers Reference* (plugins compilados y por defecto): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — *Common Expression Language in Kubernetes*: https://kubernetes.io/docs/reference/using-api/cel/
- Kyverno — *Documentation* (validate/mutate/generate, anchors, PolicyReport): https://kyverno.io/docs/
- Open Policy Agent Gatekeeper — *How to use Gatekeeper* (ConstraintTemplate, Constraint, audit): https://open-policy-agent.github.io/gatekeeper/website/docs/
- Open Policy Agent — *Policy Language (Rego)*: https://www.openpolicyagent.org/docs/latest/policy-language/
- CNCF — *CNPE Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf