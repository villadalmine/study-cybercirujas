# Tema 3.4: Uso de Policy Engines y Admission Controllers para Governance

## 1. Motivación y el problema arquitectónico de producción

En un clúster de Kubernetes multi-tenant, el punto de convergencia de *toda* mutación de estado es el `kube-apiserver`. Cada `kubectl apply`, cada reconciliación de un controller, cada pipeline de CI/CD que despliega, termina siendo un `HTTP PUT/POST/PATCH` contra el API server. Ese estrangulamiento (choke point) es también la única frontera donde una organización puede imponer, de forma no evadible, reglas de gobernanza: *"ningún Pod corre como root"*, *"todo objeto lleva el label `cost-center`"*, *"las imágenes solo provienen de `registry.corp.internal`"*, *"ningún `Service` de tipo `LoadBalancer` sin anotación de aprobación de red"*.

El error arquitectónico clásico es intentar hacer cumplir estas reglas **fuera** de esa frontera: linters en CI, revisiones de PR, wikis con convenciones. Todo eso es *advisory* — se evade con un `kubectl apply` directo, con un operador que crea objetos programáticamente, o simplemente con un pipeline que nadie actualizó. La gobernanza confiable **debe** vivir en el admission chain del API server, porque es el único lugar por el que **absolutamente todo** pasa antes de persistirse en `etcd`.

El problema que resuelven los **admission controllers** y **policy engines**:

- **Prevención vs. detección.** Un policy engine en modo *enforce* rechaza el objeto *antes* de que exista. Compararlo con un scanner que corre cada 5 minutos y encuentra el Pod privilegiado *después* de que ya está minando cripto: la diferencia entre un firewall y un post-mortem.
- **Mutación consistente.** Inyectar sidecars (service mesh), defaults de seguridad (`securityContext`), labels de facturación, `imagePullSecrets` — sin que cada equipo tenga que recordarlo.
- **Policy-as-Code.** Las reglas dejan de ser prosa en Confluence y pasan a ser objetos versionados, revisables en Git, testeables en CI, y con historial de auditoría.
- **Soberanía del platform team.** Permite delegar namespaces a los equipos de producto sin darles `cluster-admin`, poniendo guardarraíles (guardrails) que ni siquiera un usuario con RBAC amplio dentro de su namespace puede violar.

### El admission chain: dónde encaja cada pieza

Una petición al API server atraviesa esta secuencia. Entender el **orden** es la base de todo diagnóstico:

```
                         kube-apiserver
   ┌──────────────────────────────────────────────────────────────┐
   │ 1. Authentication  (¿quién sos?)                               │
   │ 2. Authorization   (RBAC/ABAC — ¿podés hacer esto?)           │
   │ 3. MUTATING admission                                          │
   │      ├─ mutating controllers built-in (DefaultStorageClass…)  │
   │      ├─ MutatingAdmissionWebhook  ──► Kyverno / Gatekeeper /   │
   │      │                                sidecar injectors        │
   │      └─ (alpha) MutatingAdmissionPolicy (CEL)                  │
   │ 4. Object Schema Validation (OpenAPI, structural)             │
   │ 5. VALIDATING admission                                        │
   │      ├─ validating controllers built-in (PodSecurity, …)      │
   │      ├─ ValidatingAdmissionWebhook ──► Gatekeeper / Kyverno   │
   │      └─ ValidatingAdmissionPolicy (CEL, GA en 1.30)           │
   │ 6. Persist to etcd                                            │
   └──────────────────────────────────────────────────────────────┘
```

Reglas de oro que se derivan del orden y que aparecen en producción:

1. **Mutating siempre antes que validating.** Un webhook que muta el objeto se ejecuta antes que cualquier validación. Por eso Kyverno puede *mutar* para agregar un default y *luego* otra política *valida* que el default esté presente.
2. **Los mutating webhooks se re-invocan.** Como un mutating webhook puede cambiar el objeto de forma que dispare otro mutating webhook, el API server los reejecuta (según `reinvocationPolicy`). El orden relativo entre webhooks del mismo tipo **no está garantizado** entre configuraciones distintas.
3. **Los built-in corren primero dentro de su fase.** `PodSecurity` (validating built-in) corre en la fase 5 junto con tus webhooks; no lo controlás por orden, sí por labels de namespace.

---

## 2. El panorama de herramientas y comparativa técnica

Existen cuatro grandes familias de mecanismos. La decisión arquitectónica central de este tema es **cuál usar para qué**, porque no son mutuamente excluyentes: un clúster de producción serio suele correr **PSA + una de {VAP, Gatekeeper, Kyverno}** simultáneamente.

### 2.1 Los cuatro mecanismos

| Mecanismo | Motor / lenguaje | Muta | Valida | Genera recursos | Fuera del clúster |
|---|---|---|---|---|---|
| **Pod Security Admission (PSA)** | Built-in, sin lenguaje (labels) | No | Sí (solo Pods) | No | No |
| **ValidatingAdmissionPolicy (VAP)** | Built-in, **CEL** | No (validación) | Sí | No | No |
| **OPA/Gatekeeper** | Webhook, **Rego** (OPA) | Sí (mutation) | Sí | No (nativo) | No |
| **Kyverno** | Webhook, **YAML declarativo** | Sí | Sí | Sí (`generate`) | No |

> **Nota histórica clave:** `PodSecurityPolicy` (PSP) fue **deprecada en 1.21 y removida en 1.25**. Si un examen o una base de código lo menciona como opción vigente, está desactualizado. Su reemplazo es la dupla **PSA** (para los tres perfiles estándar) + **un policy engine** (para todo lo que PSA no cubre, que es mucho).

### 2.2 Trade-offs: webhook externo vs. CEL in-process

La distinción arquitectónica más importante es **in-process (VAP/PSA)** vs. **out-of-process webhook (Gatekeeper/Kyverno)**.

| Dimensión | VAP / PSA (in-process, CEL) | Gatekeeper / Kyverno (webhook) |
|---|---|---|
| **Latencia añadida** | ~microsegundos (evaluación en el mismo proceso) | Red + serialización: 1–50 ms típico por request |
| **Punto único de falla** | Ninguno nuevo (es el propio API server) | El Deployment del webhook: si cae, con `failurePolicy: Fail` **bloquea el clúster** |
| **Disponibilidad** | Igual a la del control plane | Requiere HA (≥3 réplicas), PDB, y exclusión de su propio namespace |
| **Expresividad** | CEL: validación pura, sin I/O, sin estado externo | Rego/YAML: puede consultar otros objetos (data replication), external data, mutación, generación |
| **Mutación** | No (VAP solo valida; MutatingAdmissionPolicy es alpha) | Sí |
| **Generación de recursos** | No | Solo Kyverno (`generate`, `cleanup`) |
| **Curva de aprendizaje** | CEL (moderada) | Rego (alta) / Kyverno YAML (baja) |
| **Upgrade / dependencias** | Cero: viene con Kubernetes | Componente externo que versionar, upgradear y monitorear |
| **Fallo seguro** | No aplica (no hay webhook que se caiga) | `failurePolicy` decide: `Fail` (seguro pero frágil) vs `Ignore` (disponible pero con gap de política) |

**El trade-off central del webhook** es `failurePolicy`:

- `failurePolicy: Fail` → si el webhook no responde (pod caído, timeout, cert vencido), el API server **rechaza** la operación. Seguro (fail-closed) pero convierte a tu policy engine en dependencia crítica del clúster. Un Gatekeeper mal configurado puede impedir hasta que se cree un Pod nuevo del propio Gatekeeper: **deadlock**.
- `failurePolicy: Ignore` → si el webhook no responde, el API server **admite** la operación sin evaluar la política. Disponible (fail-open) pero abre una ventana donde objetos no conformes entran al clúster.

Por eso la recomendación de producción es: **empujar todo lo que se pueda a VAP/PSA (in-process, sin punto de falla)** y reservar los webhooks para lo que genuinamente los necesita (mutación, generación, consultas cross-objeto).

### 2.3 Rego vs. CEL vs. Kyverno YAML — cuándo cada uno

| Caso de uso | Recomendación | Por qué |
|---|---|---|
| "Ningún Pod privilegiado / restringir `securityContext`" | **PSA (restricted)** | Es exactamente para lo que existe; cero código |
| Validación simple sobre campos del propio objeto | **VAP (CEL)** | Sin webhook, sin operador que mantener |
| Requiere consultar *otros* objetos (ej. unicidad de Ingress host) | **Gatekeeper** o **Kyverno** | Necesitan cache replicado del cluster state |
| Inyectar sidecar / default securityContext | **Kyverno (mutate)** o Gatekeeper mutation | VAP no muta |
| Auto-crear NetworkPolicy/ResourceQuota por namespace nuevo | **Kyverno (generate)** | Único con generación nativa |
| Lógica de política muy compleja, reutilizable, con tests unitarios | **Gatekeeper (Rego)** | Rego + `conftest`/OPA test es maduro para lógica compleja |

---

## 3. Manifiestos completos de producción

### 3.1 Pod Security Admission — el guardarraíl base

PSA no se configura con CRDs sino con **labels en el namespace**. Tres perfiles (`privileged`, `baseline`, `restricted`) × tres modos (`enforce`, `audit`, `warn`).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-payments
  labels:
    # ENFORCE: rechaza Pods que violen el perfil restricted
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.31
    # AUDIT: registra violaciones en el audit log del API server (no bloquea)
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.31
    # WARN: devuelve un warning al cliente (kubectl) pero admite
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.31
```

**Patrón de rollout seguro** (nunca poner `enforce: restricted` de golpe en un namespace con cargas existentes): primero `warn` + `audit`, observás las violaciones, corregís las cargas, y recién ahí subís `enforce`.

Un Pod que cumple `restricted` para poder correr en ese namespace:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: compliant-app
  namespace: team-payments
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: registry.corp.internal/payments/api:1.4.2
      securityContext:
        allowPrivilegeEscalation: false
        privileged: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]
```

Configuración a nivel clúster (un `AdmissionConfiguration` cargado por el API server vía `--admission-control-config-file`) para fijar un default global y exenciones:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        # los componentes de sistema no deben quedar atrapados por PSA
        usernames: []
        runtimeClasses: []
        namespaces: ["kube-system", "kube-node-lease"]
```

### 3.2 ValidatingAdmissionPolicy (CEL) — governance in-process

VAP es **GA desde Kubernetes 1.30**. Se compone de dos objetos: la `ValidatingAdmissionPolicy` (la lógica) y la `ValidatingAdmissionPolicyBinding` (a qué recursos se aplica). Esta separación permite reusar una política con distintos scopes.

Política: limitar réplicas y forzar el registry corporativo, todo sin un solo webhook externo:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "deployment-governance.corp.internal"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  # variables reutilizables, evaluadas una vez
  variables:
    - name: containers
      expression: "object.spec.template.spec.containers"
    - name: replicas
      expression: "object.spec.replicas"
  validations:
    - expression: "variables.replicas <= 20"
      message: "El numero de replicas no puede exceder 20 (politica de capacidad)."
      reason: Invalid
    - expression: >-
        variables.containers.all(c,
          c.image.startsWith('registry.corp.internal/'))
      messageExpression: >-
        "Todas las imagenes deben venir de registry.corp.internal/. Imagen invalida detectada."
      reason: Forbidden
```

Binding, con un `matchResources` por labels de namespace para no aplicar a `kube-system`:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "deployment-governance-binding"
spec:
  policyName: "deployment-governance.corp.internal"
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease"]
```

Un ejemplo de CEL más sofisticado usando `params` (una política parametrizada por un ConfigMap/CRD), que es la forma idiomática de VAP para reglas configurables:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "replica-limit.corp.internal"
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  validations:
    - expression: "object.spec.replicas <= int(params.data['maxReplicas'])"
      messageExpression: >-
        "El maximo de replicas permitido es " + params.data['maxReplicas']
```

### 3.3 OPA/Gatekeeper — ConstraintTemplate + Constraint (Rego)

Gatekeeper introduce dos capas: la `ConstraintTemplate` (define un *tipo* de constraint y su Rego) y el `Constraint` (una *instancia* con parámetros). Esto genera dinámicamente un CRD nuevo por cada template.

`ConstraintTemplate` que exige un conjunto de labels:

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
          msg := sprintf("Faltan labels requeridos: %v", [missing])
        }
```

El `Constraint` (instancia) que lo aplica a Namespaces exigiendo `cost-center` y `owner`:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: ns-must-have-cost-labels
spec:
  enforcementAction: deny        # deny | dryrun | warn
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Namespace"]
  parameters:
    labels: ["cost-center", "owner"]
```

Config de Gatekeeper para **replicar objetos al cache de OPA** (necesario cuando una política consulta *otros* objetos, ej. unicidad de hosts de Ingress):

```yaml
apiVersion: config.gatekeeper.sh/v1alpha1
kind: Config
metadata:
  name: config
  namespace: gatekeeper-system
spec:
  sync:
    syncOnly:
      - group: "networking.k8s.io"
        version: "v1"
        kind: "Ingress"
      - group: ""
        version: "v1"
        kind: "Namespace"
```

### 3.4 Kyverno — validate, mutate y generate en YAML

Kyverno no requiere aprender un lenguaje nuevo; las políticas son YAML. Su ventaja diferencial es `mutate` y `generate`.

Política de **validación** (imágenes solo del registry corporativo), con `validationFailureAction: Enforce`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce   # Enforce | Audit
  background: true
  rules:
    - name: validate-registry
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Las imagenes deben provenir de registry.corp.internal/"
        pattern:
          spec:
            containers:
              - image: "registry.corp.internal/*"
```

Política de **mutación** (inyectar un `securityContext` seguro por defecto):

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
            containers:
              - (name): "*"
                securityContext:
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop: ["ALL"]
```

Política de **generación** (crear automáticamente una `NetworkPolicy` default-deny en cada namespace nuevo — patrón de zero-trust):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-networkpolicy
spec:
  rules:
    - name: default-deny
      match:
        any:
          - resources:
              kinds: ["Namespace"]
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-ingress
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes: ["Ingress"]
```

### 3.5 Un ValidatingWebhookConfiguration crudo (lo que Gatekeeper/Kyverno instalan por debajo)

Entender el objeto de bajo nivel es esencial para el diagnóstico, porque es lo que realmente registra el webhook en el API server:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: gatekeeper-validating-webhook-configuration
webhooks:
  - name: validation.gatekeeper.sh
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 3
    failurePolicy: Ignore          # <-- decisión crítica de disponibilidad
    matchPolicy: Exact
    rules:
      - apiGroups:   ["*"]
        apiVersions: ["*"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["*"]
        scope: "*"
    namespaceSelector:
      matchExpressions:
        # nunca dejar que el webhook se valide a si mismo -> deadlock
        - key: admission.gatekeeper.sh/ignore
          operator: DoesNotExist
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["gatekeeper-system", "kube-system"]
    clientConfig:
      service:
        namespace: gatekeeper-system
        name: gatekeeper-webhook-service
        path: /v1/admit
      caBundle: <BASE64_CA>
```

Los dos campos que causan el 90% de los incidentes: `failurePolicy` (fail-open vs fail-closed) y `namespaceSelector` (la exclusión que previene el deadlock del propio componente y de `kube-system`).

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 PSA en acción

Intentar crear un Pod privilegiado en un namespace `restricted`:

```console
$ kubectl label ns team-payments \
    pod-security.kubernetes.io/enforce=restricted --overwrite
namespace/team-payments labeled

$ kubectl run bad --image=nginx -n team-payments
Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false (container "bad" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "bad" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "bad" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "bad" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Probar el modo `warn` antes de aplicar `enforce` (rollout seguro):

```console
$ kubectl label ns team-payments \
    pod-security.kubernetes.io/warn=restricted --overwrite
namespace/team-payments labeled

$ kubectl run test --image=nginx -n team-payments
Warning: would violate PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
pod/test created
```

### 4.2 ValidatingAdmissionPolicy

```console
$ kubectl apply -f deployment-governance-policy.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/deployment-governance.corp.internal created

$ kubectl apply -f deployment-governance-binding.yaml
validatingadmissionpolicybinding.admissionregistration.k8s.io/deployment-governance-binding created

$ kubectl create deployment big --image=docker.io/library/nginx --replicas=50
error: failed to create deployment: deployments.apps "big" is forbidden: ValidatingAdmissionPolicy 'deployment-governance.corp.internal' with binding 'deployment-governance-binding' denied request: El numero de replicas no puede exceder 20 (politica de capacidad).

$ kubectl create deployment ok --image=docker.io/library/nginx --replicas=3
error: failed to create deployment: deployments.apps "ok" is forbidden: ValidatingAdmissionPolicy 'deployment-governance.corp.internal' with binding 'deployment-governance-binding' denied request: Todas las imagenes deben venir de registry.corp.internal/. Imagen invalida detectada.
```

Inspeccionar las políticas registradas:

```console
$ kubectl get validatingadmissionpolicy
NAME                                        VALIDATIONS   PARAMKIND   AGE
deployment-governance.corp.internal         2             <unset>     4m

$ kubectl get validatingadmissionpolicybinding
NAME                             POLICYNAME                            AGE
deployment-governance-binding    deployment-governance.corp.internal   4m
```

### 4.3 Gatekeeper

```console
$ kubectl apply -f template-required-labels.yaml
constrainttemplate.templates.gatekeeper.sh/k8srequiredlabels created

$ kubectl get crd | grep gatekeeper
k8srequiredlabels.constraints.gatekeeper.sh   2026-08-07T14:22:10Z

$ kubectl apply -f constraint-ns-labels.yaml
k8srequiredlabels.constraints.gatekeeper.sh/ns-must-have-cost-labels created

$ kubectl create ns orphan
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [ns-must-have-cost-labels] Faltan labels requeridos: {"cost-center", "owner"}
```

Ver el estado de violaciones auditadas (Gatekeeper audita cada 60s el estado *existente* del clúster, no solo admisión):

```console
$ kubectl get k8srequiredlabels ns-must-have-cost-labels -o jsonpath='{.status.totalViolations}'
7

$ kubectl get k8srequiredlabels ns-must-have-cost-labels \
    -o jsonpath='{range .status.violations[*]}{.kind}/{.name}: {.message}{"\n"}{end}'
Namespace/default: Faltan labels requeridos: {"cost-center", "owner"}
Namespace/team-legacy: Faltan labels requeridos: {"cost-center"}
```

### 4.4 Kyverno

```console
$ kubectl apply -f restrict-registries.yaml
clusterpolicy.kyverno.io/restrict-image-registries created

$ kubectl get clusterpolicy
NAME                          ADMISSION   BACKGROUND   READY   AGE
restrict-image-registries     true        true         True    30s

$ kubectl run evil --image=docker.io/library/nginx
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/evil was blocked due to the following policies

restrict-image-registries:
  validate-registry: 'validation error: Las imagenes deben provenir de
    registry.corp.internal/. rule validate-registry failed at path /spec/containers/0/image/'
```

Ver los reports de política (Kyverno produce `PolicyReport` CRDs — la vía idiomática de auditar):

```console
$ kubectl get policyreport -A
NAMESPACE      NAME                              PASS   FAIL   WARN   ERROR   AGE
default        cpol-restrict-image-registries    12     3      0      0       6m
team-payments  cpol-restrict-image-registries    40     0      0      0       6m
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 El incidente #1: el clúster "se congela" (webhook deadlock)

**Síntoma:**

```console
$ kubectl apply -f anything.yaml
Error from server (InternalError): Internal error occurred: failed calling webhook
"validation.gatekeeper.sh": failed to call webhook: Post
"https://gatekeeper-webhook-service.gatekeeper-system.svc:443/v1/admit?timeout=3s":
dial tcp 10.96.0.42:443: connect: connection refused
```

**Causa raíz:** El webhook tiene `failurePolicy: Fail`, y su backend (los pods de Gatekeeper/Kyverno) está caído — o peor, el propio namespace del webhook quedó atrapado por su regla, impidiendo que sus pods se reprogramen.

**Diagnóstico:**

```console
$ kubectl -n gatekeeper-system get pods
NAME                                  READY   STATUS             RESTARTS   AGE
gatekeeper-controller-manager-xxx     0/1     CrashLoopBackOff   9          22m

$ kubectl get validatingwebhookconfiguration \
    gatekeeper-validating-webhook-configuration \
    -o jsonpath='{.webhooks[0].failurePolicy}  {.webhooks[0].namespaceSelector}'
Fail   {}     # <-- sin namespaceSelector: el webhook se aplica a si mismo
```

**Remediación de emergencia** (romper el deadlock desactivando el webhook):

```console
$ kubectl delete validatingwebhookconfiguration \
    gatekeeper-validating-webhook-configuration
validatingwebhookconfiguration.admissionregistration.k8s.io deleted
# el API server vuelve a admitir; ahora se arregla el backend y se reinstala
```

**Prevención permanente:** (a) excluir el propio namespace y `kube-system` vía `namespaceSelector`; (b) usar `failurePolicy: Ignore` para reglas no críticas; (c) `timeoutSeconds` bajo (2–3s); (d) HA con ≥3 réplicas y un `PodDisruptionBudget`.

### 5.2 El incidente #2: la política "no hace nada"

**Diagnóstico ordenado** — recorrer el chain de arriba hacia abajo:

```console
# 1. ¿El webhook está registrado y con las rules correctas?
$ kubectl get validatingwebhookconfiguration -o wide

# 2. ¿El namespaceSelector está excluyendo el namespace objetivo sin querer?
$ kubectl get ns team-payments --show-labels

# 3. ¿La accion es Enforce o Audit? (error clasico: quedó en Audit/dryrun)
$ kubectl get clusterpolicy restrict-image-registries \
    -o jsonpath='{.spec.validationFailureAction}'
Audit    # <-- por eso admite; deberia ser Enforce

# 4. ¿El backend está sano y recibiendo requests?
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20
```

Para VAP, el error más común es un `validationActions` sin `Deny`:

```console
$ kubectl get validatingadmissionpolicybinding deployment-governance-binding \
    -o jsonpath='{.spec.validationActions}'
["Audit"]    # <-- solo audita; falta "Deny" para bloquear
```

### 5.3 El incidente #3: certificado del webhook vencido

`failurePolicy: Fail` + cert TLS vencido = el mismo deadlock, con un error revelador:

```console
$ kubectl apply -f pod.yaml
Error from server (InternalError): Internal error occurred: failed calling webhook
"validate.kyverno.svc-fail": failed to call webhook: Post "...": x509: certificate
has expired or is not yet valid: current time 2026-08-07T14:00:00Z is after
2026-08-01T00:00:00Z
```

Verificación proactiva del `caBundle` vs. el secret del cert:

```console
$ kubectl get validatingwebhookconfiguration kyverno-policy-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | \
    openssl x509 -noout -enddate
notAfter=Nov  5 14:22:10 2026 GMT
```

### 5.4 Testing de políticas *antes* de producción

- **Modo `warn`/`audit`/`dryrun` primero, `enforce` después.** Nunca introducir una política nueva directamente en `enforce` en namespaces con cargas vivas.
- **Gatekeeper:** `gator test` valida ConstraintTemplates contra manifiestos fixture en CI, sin clúster:

```console
$ gator test --filename=policies/ --filename=fixtures/bad-pod.yaml
FAIL  ns-must-have-cost-labels  Namespace/orphan: Faltan labels requeridos
1 failed, 4 passed
```

- **Kyverno:** `kyverno test` corre suites declarativas (`kyverno-test.yaml`) en pipeline.
- **VAP:** el `--dry-run=server` ejecuta la política sin persistir, y `validationActions: ["Audit"]` deja rastro en el audit log antes de sumar `Deny`.

### 5.5 Checklist de verificación de gobernanza de producción

| Verificación | Comando / evidencia |
|---|---|
| Los webhooks excluyen su propio ns y `kube-system` | `kubectl get validatingwebhookconfiguration -o yaml \| grep -A5 namespaceSelector` |
| `failurePolicy` es consciente (Fail vs Ignore documentado) | inspección del objeto webhook |
| Backend del policy engine con HA + PDB | `kubectl get pdb,deploy -n <engine-ns>` |
| Certs del webhook con >30 días de vigencia | `openssl x509 -enddate` sobre el `caBundle` |
| PSA en `enforce:baseline` mínimo cluster-wide | labels de namespace / `AdmissionConfiguration` |
| Reportes de auditoría revisados | `kubectl get policyreport -A` / `.status.violations` |
| Políticas versionadas en Git y testeadas en CI | `gator test` / `kyverno test` en el pipeline |

---

## 6. Referencias

- Kubernetes — Admission Controllers Reference: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — Dynamic Admission Control (webhooks): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Validating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — CEL en Kubernetes: https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes — Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Enforce Pod Security Standards with Namespace Labels: https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- OPA Gatekeeper — Documentación: https://open-policy-agent.github.io/gatekeeper/website/docs/
- OPA Gatekeeper — Library de políticas: https://open-policy-agent.github.io/gatekeeper-library/website/
- Open Policy Agent — Lenguaje Rego: https://www.openpolicyagent.org/docs/latest/policy-language/
- Kyverno — Documentación: https://kyverno.io/docs/
- Kyverno — Políticas de ejemplo: https://kyverno.io/policies/
- CNCF Cloud Native Security Whitepaper: https://github.com/cncf/tag-security/tree/main/community/resources/security-whitepaper
- CNPE Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf