# 4.1 Aplicando Políticas en el Cluster

> **Nota de alcance.** La versión del temario KCA no está especificada, por lo que este material se ancla a la superficie de políticas estable actual de Kubernetes (v1.30 / v1.31) y señala el hito GA de cada primitiva. `PodSecurityPolicy` (PSP) fue **eliminado en v1.25** — si todavía conservás objetos PSP, están inertes y deben migrarse a los mecanismos que se describen abajo.

---

## 1. Motivación: el problema arquitectónico

### 1.1 El API server es el único camino de escritura — así que es el único lugar donde la política puede *garantizarse*

Toda mutación del estado del cluster — venga de `kubectl`, de un controlador GitOps (Argo CD, Flux), del bucle de reconciliación de un operator propio, o de un token de service account comprometido — es una escritura al `kube-apiserver`, que luego persiste en `etcd`. Nada llega a `etcd` sin atravesar el pipeline de peticiones del API server. Ese pipeline es el **único punto de estrangulamiento** donde una regla puede aplicarse contra *todos* los escritores simultáneamente.

Por eso el "shift-left" por sí solo (lintear YAML en CI, `conftest` en un pipeline) es necesario pero **no suficiente**. CI valida lo que *vos* empujás. No valida:

- Un pod privilegiado creado por un operator reconciliando un CRD de terceros.
- `kubectl apply` ejecutado por un ingeniero de guardia a las 03:00 saltándose el pipeline.
- La corrección de drift de GitOps re-aplicando un manifiesto que un atacante mutó en el repo.
- Un workload creado por un token de ServiceAccount robado desde dentro del cluster.

La taxonomía que importa en producción es **gates vs. guardrails** (barreras vs. barandillas):

- **Gate (validating):** rechazar la petición. El objeto malo nunca existe. Fail-closed.
- **Guardrail (mutating):** reparar silenciosamente la petición (inyectar `runAsNonRoot`, agregar un sidecar, fijar un default). El objeto se admite, corregido.

### 1.2 El pipeline de admisión (donde vive la política)

```
                       kube-apiserver request lifecycle
  ┌──────────────┐   ┌───────────────┐   ┌──────────────────┐   ┌─────────────┐   ┌────────────────────┐   ┌───────┐
  │ Authentication│──▶│ Authorization │──▶│ Mutating admission│──▶│ Schema /    │──▶│ Validating admission│──▶│ etcd  │
  │ (who are you) │   │ (RBAC/ABAC/   │   │ (webhooks +       │   │ OpenAPI     │   │ (PSA, VAP, webhooks,│   │ (write)│
  │               │   │  Node/Webhook)│   │  MutatingAdmPolicy)│  │ validation  │   │  Gatekeeper/Kyverno)│   │       │
  └──────────────┘   └───────────────┘   └──────────────────┘   └─────────────┘   └────────────────────┘   └───────┘
        401                 403               mutate object          422 invalid          403 Forbidden        stored
```

Datos clave de ordenamiento que te van a evaluar y que vas a depurar en producción:

1. **La autorización (RBAC) corre primero.** La política de admisión asume que el llamador ya fue autorizado a ejecutar el verbo. RBAC responde *"¿puede esta identidad hacer X?"*; la admisión responde *"¿es aceptable este objeto específico?"*. Son capas de política complementarias.
2. **La mutación ocurre antes que la validación.** Un webhook mutating o una `MutatingAdmissionPolicy` puede inyectar un campo que una etapa *posterior* de validación luego verifica. Por eso "agregar un `securityContext` por defecto, luego forzar `restricted`" funciona — pero solo si el ordenamiento se mantiene.
3. **La admisión validating es la última línea antes de `etcd`.** Si dice `Forbidden`, el objeto nunca existió.

### 1.3 Los modos de fallo que la política existe para prevenir

| Sin política en el cluster | Consecuencia concreta en producción |
|---|---|
| Pods corren privileged / `hostPID` / `hostPath: /` | Escape de contenedor → root del nodo → toma del cluster (movimiento lateral) |
| Sin `resources.limits` | Un vecino ruidoso hace OOM-kill de un nodo; expulsión en cascada |
| Imágenes `:latest` / sin tag | Rollouts no reproducibles, drift de versión silencioso, sin ancla de rollback |
| Red de pods plana (sin `NetworkPolicy`) | Un front-end comprometido puede llegar directo a la base de datos |
| Sin labels requeridos (`owner`, `cost-center`) | Radio de impacto no rastreable, sin propiedad durante un incidente |

---

## 2. Los mecanismos de política — comparación técnica

Hay dos *familias* de aplicación y una capa de autorización adyacente:

- **In-tree, sin salto de red:** RBAC, ResourceQuota/LimitRange, **Pod Security Admission (PSA)**, **ValidatingAdmissionPolicy (VAP)**. Evaluadas dentro del proceso del API server.
- **Webhooks de admisión out-of-tree:** **OPA Gatekeeper**, **Kyverno**. Una llamada de red desde el API server hacia un pod.
- **Política de dataplane:** **NetworkPolicy** — no es admisión en absoluto; la aplica el CNI en runtime.

### 2.1 Matriz de trade-offs

| Dimensión | RBAC | Pod Security Admission | ValidatingAdmissionPolicy | OPA Gatekeeper | Kyverno | NetworkPolicy |
|---|---|---|---|---|---|---|
| Punto de aplicación | etapa authz | admisión (in-tree) | admisión (in-tree) | **webhook** validating | **webhook** validating+mutating | dataplane CNI |
| Lenguaje de política | ninguno (verbos/recursos) | perfiles fijos | **CEL** | **Rego** | YAML/JMESPath+CEL | selectores de label |
| ¿Puede **mutar**? | ✗ | ✗ | ✗ (ver MAP §7) | ✗ (assign mutations, beta) | ✓ (nativo) | n/a |
| ¿Puede **generar** recursos? | ✗ | ✗ | ✗ | ✗ | ✓ | n/a |
| ¿Dependencia externa / pod para correr? | no | no | no | **sí** (pods de controlador + certs) | **sí** (pods del ctlr de admisión) | plugin CNI |
| Salto de red por petición (latencia) | ninguno | ninguno | ninguno | ~ms + riesgo | ~ms + riesgo | ninguno (async) |
| Modo de fallo | determinista | fail-closed (in-tree) | `failurePolicy: Fail/Ignore` | `failurePolicy` del webhook | `failurePolicy` del webhook | fail-closed una vez que una política selecciona el pod |
| Radio de impacto de disponibilidad | ninguno | ninguno | ninguno | **puede atascar el API server** | **puede atascar el API server** | ninguno |
| Lógica custom / búsquedas cross-object | no | no | limitada (solo params) | ✓ (Rego, `data`) | ✓ (búsquedas en API, context) | no |
| Estado GA | GA | **GA v1.25** | **GA v1.30** | maduro (v3.x) | maduro (v1.x) | GA |
| Mejor uso | *quién puede actuar* | baseline de hardening de pods | validación nativa, sin dependencias | restricciones organizacionales complejas, entornos OPA | mutar+generar+validar, verificación de imágenes | segmentación este-oeste |

### 2.2 Cómo elegir (la decisión que la mayoría de los equipos equivocan)

- **Empezá con PSA + NetworkPolicy + RBAC.** Son in-tree, gratis, y no se pueden dejar offline. PSA te da el baseline `restricted` de hardening de pods con cero piezas móviles.
- **Recurrí a `ValidatingAdmissionPolicy` (CEL) antes que a un webhook** cuando la regla sea *pura validación* ("debe fijar un límite de memoria", "imagen de un registry aprobado"). Es in-tree — sin controlador que correr, sin cert que rotar, sin caída fail-open.
- **Recurrí a Kyverno o Gatekeeper** cuando necesités lo que CEL/PSA no pueden hacer: **mutación** (inyectar defaults), **generación** (auto-crear una `NetworkPolicy` default-deny por namespace), **verificación de firma de imágenes**, o búsquedas cross-resource. Kyverno es nativo de YAML y hace mutar+generar; Gatekeeper es Rego e integra con el ecosistema OPA más amplio.

> **Regla arquitectónica práctica:** preferí el mecanismo más cercano al núcleo del API server. Cada webhook que agregás es una nueva dependencia de disponibilidad para *toda escritura en el cluster*.

---

## 3. Manifiestos completos, listos para producción

### 3.1 Pod Security Admission — opt-in por namespace + default a nivel de cluster

**Aplicación por namespace** (los tres modos son independientes: `enforce` rechaza, `audit` registra una anotación, `warn` devuelve una advertencia al cliente):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    # Hard gate: reject non-compliant pods.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    # Audit trail in the API audit log (does not block).
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
    # Client-facing warning at apply time (does not block).
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
```

**Default a nivel de cluster** para que un namespace *recién creado* no quede silenciosamente sin protección. Esto se cablea al API server, no se aplica con `kubectl`:

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"        # cluster-wide floor for namespaces without labels
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: ["kube-system"]   # infra pods that legitimately need privilege
```

El API server se arranca entonces con:

```
--admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
```

Los tres **Pod Security Standards** que los labels referencian:

| Standard | Significado | Uso típico |
|---|---|---|
| `privileged` | sin restricciones | namespaces confiables de infra / CNI / CSI |
| `baseline` | bloquea escaladas de privilegio conocidas (`hostNetwork`, `privileged`, `hostPath`, la mayoría de las caps) | workloads generales |
| `restricted` | endurecido: `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `drop: ["ALL"]`, `allowPrivilegeEscalation: false` | regulado / multi-tenant |

### 3.2 ValidatingAdmissionPolicy — CEL nativo, sin webhook (GA v1.30)

**Política 1 — todo contenedor debe declarar un límite de memoria.** In-tree, cero dependencias externas.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-resource-limits
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: containers
      expression: "object.spec.containers"
  validations:
    - expression: >-
        variables.containers.all(c,
          has(c.resources) && has(c.resources.limits) && has(c.resources.limits.memory))
      message: "every container must set spec.containers[].resources.limits.memory"
      reason: Invalid
```

Enlazala — una política no hace nada hasta que un **binding** la activa y declara la acción (`Deny` / `Warn` / `Audit`):

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-resource-limits-binding
spec:
  policyName: require-resource-limits
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        policy.example.com/limits: "enforce"
```

**Política 2 — chequeo parametrizado de registry permitido.** La lista de permitidos vive en un `ConfigMap` (`paramKind`), así los equipos de plataforma cambian los datos de la política sin editar la política:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: allowed-image-registries
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          params.data['registries'].split(',').exists(r, c.image.startsWith(r)))
      messageExpression: >-
        "container image must come from an approved registry: " + params.data['registries']
      reason: Forbidden
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: approved-registries
  namespace: policy-system
data:
  registries: "registry.example.com/,gcr.io/prod-project/"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: allowed-image-registries-binding
spec:
  policyName: allowed-image-registries
  validationActions: ["Deny", "Audit"]
  paramRef:
    name: approved-registries
    namespace: policy-system
    parameterNotFoundAction: Deny     # fail closed if the ConfigMap is missing
  matchResources:
    namespaceSelector: {}             # all namespaces
```

### 3.3 OPA Gatekeeper — ConstraintTemplate (Rego) + Constraint

Gatekeeper separa la *regla* (un `ConstraintTemplate` reutilizable que genera un CRD) de la *instancia* (un `Constraint` que la parametriza y le da alcance):

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

        violation[{"msg": msg}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("missing required labels: %v", [missing])
        }
```

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: ns-must-have-owner
spec:
  enforcementAction: deny          # deny | dryrun | warn
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Namespace"]
  parameters:
    labels: ["owner"]
```

### 3.4 Kyverno — validar, mutar, generar (los tres superpoderes)

**Validar** — bloquear tags de imagen mutables:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce   # Enforce = block; Audit = report only
  background: true                    # also scan pre-existing resources
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Using a mutable image tag (':latest' or untagged) is not allowed."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

> Kyverno 1.12+ deprecia el `validationFailureAction` a nivel de spec en favor del `validate.failureAction` por regla. Fijá tu política a la versión de Kyverno instalada.

**Mutar** — inyectar un `securityContext` por defecto endurecido (una *guardrail*, no un gate):

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
              kinds: ["Pod"]
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              runAsNonRoot: true
              seccompProfile:
                type: RuntimeDefault
```

**Generar** — auto-crear una `NetworkPolicy` default-deny en cada namespace nuevo (`synchronize` la mantiene reparada si alguien la elimina):

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

### 3.5 NetworkPolicy — default-deny + allow explícito

El patrón de segmentación más importante: denegar todo, luego re-abrir exactamente lo que el workload necesita. Notá que una política de egress default-deny **también bloquea DNS**, así que debés re-permitir explícitamente el puerto 53 o toda resolución de nombres en el namespace falla:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}                 # selects every pod in the namespace
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: payments
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-from-frontend
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8443
```

> `NetworkPolicy` solo se aplica si tu CNI la soporta (Calico, Cilium, Antrea, Weave). Con solo flannel, estos objetos se almacenan y se **ignoran silenciosamente** — una clásica falsa sensación de seguridad. Verificá con tu CNI, no con `kubectl get netpol`.

### 3.6 La primitiva cruda — ValidatingWebhookConfiguration

Gatekeeper y Kyverno registran uno de estos. Entenderlo es lo que te permite *depurar una caída* cuando se portan mal. Dos campos críticos para producción: `failurePolicy` y el `namespaceSelector` que debe excluir el propio namespace del webhook para evitar un deadlock de arranque.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-policy.example.com
webhooks:
  - name: image-policy.example.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail            # Fail = block writes if webhook is down (fail-closed)
    timeoutSeconds: 5
    clientConfig:
      service:
        name: image-policy-webhook
        namespace: policy-system
        path: /validate
        port: 443
      caBundle: <base64-encoded-PEM>
    rules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
        scope: Namespaced
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "policy-system"]   # never gate your own controllers
```

---

## 4. CLI y salidas de terminal

### 4.1 Pod Security Admission en acción

```console
$ kubectl label namespace payments \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/warn=restricted
namespace/payments labeled

$ kubectl -n payments run nginx --image=nginx
Error from server (Forbidden): pods "nginx" is forbidden: violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type
  to "RuntimeDefault" or "Localhost")
```

**Ejecutá un dry-run de una política más estricta contra un namespace vivo *antes* de aplicarla** — esto revela qué pods existentes se romperían, sin bloquear nada:

```console
$ kubectl label --dry-run=server --overwrite namespace legacy \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "legacy" violate the new PodSecurity enforce level "restricted:latest"
Warning: batch-runner-7f9c: allowPrivilegeEscalation != false, runAsNonRoot != true
namespace/legacy labeled (server dry run)
```

### 4.2 ValidatingAdmissionPolicy

```console
$ kubectl get validatingadmissionpolicy
NAME                        VALIDATIONS   PARAMKIND   AGE
allowed-image-registries    1             ConfigMap   6m
require-resource-limits     1             <unset>     6m

$ kubectl get validatingadmissionpolicybinding
NAME                               POLICYNAME                 PARAMREF              AGE
allowed-image-registries-binding   allowed-image-registries   approved-registries   6m
require-resource-limits-binding    require-resource-limits    <unset>               6m

$ kubectl apply -f pod-nolimits.yaml
Error from server (Forbidden): error when creating "pod-nolimits.yaml": pods "cache" is forbidden:
ValidatingAdmissionPolicy 'require-resource-limits' with binding 'require-resource-limits-binding'
denied request: every container must set spec.containers[].resources.limits.memory
```

### 4.3 Gatekeeper

```console
$ kubectl get constrainttemplate
NAME                AGE
k8srequiredlabels   12m

$ kubectl apply -f ns-noowner.yaml
Error from server (Forbidden): error when creating "ns-noowner.yaml":
admission webhook "validation.gatekeeper.sh" denied the request:
[ns-must-have-owner] missing required labels: {"owner"}

$ kubectl get k8srequiredlabels ns-must-have-owner \
    -o jsonpath='{.status.totalViolations}'
7
```

### 4.4 Kyverno

```console
$ kubectl get cpol
NAME                          ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
add-default-securitycontext   true        true         Audit             True    9m
disallow-latest-tag           true        true         Enforce           True    9m
default-deny-networkpolicy    true        true         Audit             True    9m

$ kubectl -n dev run web --image=nginx:latest
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/dev/web was blocked due to the following policies

disallow-latest-tag:
  require-image-tag: 'validation error: Using a mutable image tag (":latest" or untagged)
    is not allowed. rule require-image-tag failed at path /spec/containers/0/image/'

# Background scan results (does not block; reports on pre-existing resources)
$ kubectl get policyreport -A
NAMESPACE   NAME                                   PASS   FAIL   WARN   ERROR   SKIP   AGE
dev         cpol-disallow-latest-tag               12     3      0      0       0      9m
```

### 4.5 RBAC — la primera capa de política

```console
$ kubectl auth can-i create pods --namespace payments \
    --as system:serviceaccount:ci:deployer
yes

$ kubectl auth can-i delete namespaces \
    --as system:serviceaccount:ci:deployer
no
```

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Confirmar que cada mecanismo está realmente cableado

```console
# Is the PodSecurity admission plugin even enabled? (managed clusters vary)
$ kubectl get --raw='/readyz?verbose' | grep -i admission
[+]poststarthook/start-kube-apiserver-admission-initializer ok

# Are policies loaded and bound?
$ kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding
$ kubectl get constrainttemplate,constraints -A
$ kubectl get cpol,polr,cpolr -A

# Is the webhook the API server will call actually registered?
$ kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration
```

### 5.2 El incidente de producción número uno: un webhook atasca el API server

Un webhook validating/mutating con `failurePolicy: Fail` cuyos pods de respaldo están insalubres va a **rechazar toda escritura que coincida en todo el cluster**, incluyendo las escrituras necesarias para arreglarlo. Síntomas y triage:

```console
# Symptom: everything times out with a webhook error
$ kubectl apply -f anything.yaml
Error from server (InternalError): Internal error occurred: failed calling webhook
"validate.kyverno.svc-fail": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/validate?timeout=10s": context deadline exceeded

# Triage 1 — is the admission controller alive?
$ kubectl -n kyverno get pods
NAME                                   READY   STATUS             RESTARTS   AGE
kyverno-admission-controller-6d…-x     0/1     CrashLoopBackOff   8          21m

# Triage 2 — break glass: temporarily set the webhook to fail-open, or delete it
$ kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
```

**Defensas de diseño (construilas *antes* del incidente):**

- Excluir los namespaces del plano de control (`kube-system`, el propio namespace del controlador de política) vía `namespaceSelector` — §3.6.
- Correr los controladores en HA (≥2 réplicas, `PodDisruptionBudget`, anti-afinidad).
- Mantener `timeoutSeconds` bajo (5s) para que un webhook lento se degrade en lugar de colgarse.
- Considerar `failurePolicy: Ignore` para las mutaciones *guardrail* y reservar `Fail` para gates de seguridad genuinos — un trade-off explícito de disponibilidad-vs-seguridad, no un accidente.

### 5.3 Bugs de ordenamiento mutación-antes-de-validación

Si una política mutate de Kyverno debería inyectar `runAsNonRoot: true` pero un gate PSA `restricted` igual rechaza el pod, la mutación **no se aplicó primero**. Diagnosticá con dry-run del lado del servidor, que corre la cadena de admisión *entera* y devuelve el objeto final:

```console
$ kubectl apply --dry-run=server -o yaml -f pod.yaml | grep -A3 securityContext
  securityContext:
    runAsNonRoot: true          # <- present ⇒ mutation ran; absent ⇒ mutate policy didn't match
    seccompProfile:
      type: RuntimeDefault
```

Si el campo está ausente, el bloque `match` de la política mutate no seleccionó el recurso (`kinds` equivocado, namespace excluido, o el controlador estaba caído).

### 5.4 Depurar denegaciones metódicamente

1. **Leé el string del error** — cada mecanismo se nombra *a sí mismo* y la regla que falla (`ValidatingAdmissionPolicy 'X' with binding 'Y'`, `[constraint-name]`, `rule <name> failed at path <json-path>`). El path te dice el campo exacto.
2. **Bugs de lógica CEL / Rego** — para VAP, probá la expresión en aislamiento; `failurePolicy: Fail` significa que un *error de compilación en el propio CEL* se reporta como una denegación, no se saltea. Chequeá `kubectl describe validatingadmissionpolicy <name>` en busca de advertencias `TypeChecking`.
3. **Confusión audit vs. enforce** — una política en modo `audit`/`Audit`/`dryrun` **no** bloquea; escribe en los reportes/audit log. Si "la política no funciona", primero confirmá que está en modo de aplicación (`validationActions: ["Deny"]`, `enforcementAction: deny`, `validationFailureAction: Enforce`).
4. **Alcance del selector** — los bindings y constraints solo actúan sobre lo que sus `matchResources` / `match` seleccionan. `kubectl get ns --show-labels` para confirmar que el namespace objetivo lleva el label que el binding requiere.

### 5.5 Verificar que NetworkPolicy realmente se aplica (no solo se almacena)

```console
$ kubectl -n payments run probe --rm -it --image=nicolaka/netshoot -- \
    curl -m 3 http://database.payments.svc:5432
curl: (28) Connection timed out after 3001 milliseconds
command terminated with exit code 28    # <- good: default-deny is enforced by the CNI

# If it CONNECTS despite a default-deny policy, your CNI does not enforce NetworkPolicy.
```

---

## 6. Qué viene después (trayectoria a observar)

- **MutatingAdmissionPolicy (MAP)** — la contraparte CEL-nativa de VAP para *mutación*, alpha en v1.32. Apunta a mover las guardrails de inyección de defaults in-tree, eliminando el riesgo de disponibilidad de los webhooks mutating. Cuando madure, el caso de "Kyverno para un default simple" se debilita del mismo modo que VAP ya desplazó a los webhooks validating simples.
- **La dirección es inequívoca:** empujar la política *dentro* del API server (CEL) y fuera de los webhooks dependientes de red donde sea que la lógica lo permita — menos piezas móviles, sin superficie de caídas fail-open.

---

## Referencias

- Admission controllers reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- CEL in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Dynamic Admission Control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Enforce Pod Security Standards with namespace labels — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Enforce Pod Security Standards by configuring the built-in admission controller — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- RBAC authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Open Policy Agent / Rego — https://www.openpolicyagent.org/docs/latest/
- Kyverno documentation — https://kyverno.io/docs/
- Kyverno policy library — https://kyverno.io/policies/
- KCA / CNCF curriculum — https://github.com/cncf/curriculum