# Tema 2.3 — Policy Engines for Platform Governance

> **CNPA · Dominio 2 (Platform Governance & Security) · Peso 4.0**
> Nivel: Platform Architect / SRE Senior. Este material asume que ya operás clústeres multi-tenant en producción y que conocés el flujo de `kube-apiserver`, RBAC y admission control a nivel conceptual.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El vacío que RBAC no cubre

RBAC responde a **quién puede ejecutar qué verbo sobre qué recurso** (`can user X `create` `pods` in namespace Y?`). Es un control de **autorización binaria por tipo de recurso**. Lo que RBAC estructuralmente **no puede** expresar es el **contenido** del objeto:

- Un `Deployment` que RBAC permite crear puede pedir `privileged: true`, montar `hostPath: /`, correr como `runAsUser: 0` o pedir `latest` como tag de imagen.
- RBAC no sabe correlacionar campos (“si `type: LoadBalancer`, entonces exigí la annotation de `internal`”).
- RBAC no puede exigir la *presencia* de una label (`team`, `cost-center`, `data-classification`) ni validar su valor contra un patrón.

Ese hueco —la **validación semántica del payload y su relación con la política organizacional**— es exactamente el territorio de los **policy engines**. En la taxonomía de plataforma esto es *policy-as-code*: la regla de gobierno se versiona, se testea, se promueve por entornos y se aplica de forma **determinística y auditable** en el mismo punto por el que pasa todo cambio de estado: el `kube-apiserver`.

### 1.2 El problema arquitectónico concreto

Una plataforma interna (IDP, *Internal Developer Platform*) sirve a decenas o cientos de squads. Los requisitos de gobierno son transversales y no negociables:

| Requisito de gobierno | Ejemplo concreto | Por qué falla “a mano” |
|---|---|---|
| **Baseline de seguridad** | Prohibir `hostNetwork`, `privileged`, `hostPath` | Un solo Pod mal configurado abre el nodo entero |
| **Supply chain** | Solo imágenes de `registry.corp.io` firmadas con cosign | Revisión manual no escala ni es auditable |
| **Higiene operativa** | `requests/limits` obligatorios, `livenessProbe` presente | Sin limits → noisy neighbor y OOM del nodo |
| **FinOps / traceabilidad** | Label `cost-center` obligatoria y validada | Sin ella no hay showback ni chargeback |
| **Multi-tenancy** | Cada namespace de tenant nace con `NetworkPolicy` default-deny y `ResourceQuota` | Olvidos → un tenant consume todo el clúster |

El **shift-left** (linters en CI, `conftest`, revisión en PR) es necesario pero **insuficiente**: no todo el tráfico de escritura al API pasa por tu CI. Controladores, operators, `kubectl apply` manual de un on-call a las 3am, Argo CD haciendo sync, un HPA escalando… todos escriben directo. **El único punto de estrangulamiento (choke point) por el que pasa el 100% de las mutaciones de estado es el `kube-apiserver`.** Por eso el enforcement de producción vive en el **admission control**, y el policy engine es el motor que decide.

### 1.3 Los tres verbos de un policy engine

Un motor maduro no solo dice “no”. Opera en tres modos:

1. **Validate (validar / rechazar)** — el objeto no cumple → se rechaza la request con un mensaje accionable. Enforcement duro.
2. **Mutate (mutar / remediar)** — se inyecta o corrige un campo antes de persistir (agregar `securityContext`, `imagePullPolicy`, sidecars, labels). *Defaults con opinión.*
3. **Generate (generar recursos derivados)** — al crearse un `Namespace`, generar automáticamente su `NetworkPolicy`, `ResourceQuota`, `LimitRange`, `RoleBinding`. *Golden path automático.*

A esto se suma el modo **audit / background scan**: evaluar recursos **ya existentes** contra las políticas actuales, sin bloquear, para medir la deuda de cumplimiento (útil al introducir una política nueva sin romper lo que ya corre).

---

## 2. La mecánica interna: el admission chain de Kubernetes

Antes de comparar motores hay que entender **dónde** se enchufan, porque de eso dependen sus garantías.

### 2.1 El pipeline de una request de escritura

```
kubectl apply ─▶ kube-apiserver
                    │
   1. Authentication  (¿quién sos?)
   2. Authorization   (RBAC/ABAC/Webhook — ¿podés hacerlo?)
   3. Admission Control:
        ├─ Mutating Admission (in-tree plugins → MutatingAdmissionWebhooks)
        │      · muta el objeto
        ├─ Object Schema Validation (OpenAPI, structural)
        └─ Validating Admission (ValidatingAdmissionWebhooks → ValidatingAdmissionPolicy CEL)
               · acepta o rechaza; NO puede mutar
   4. etcd (persistencia)
```

Puntos que definen el comportamiento en producción:

- **El orden importa**: **todas** las mutaciones ocurren *antes* de **todas** las validaciones. No podés mutar en respuesta a lo que validó otro webhook validante. Si querés “mutar y luego garantizar que la mutación quedó”, necesitás que **la misma política valide después de mutar** (Gatekeeper y Kyverno lo hacen re-evaluando en la fase validante).
- **Los webhooks mutantes se llaman en un orden no garantizado y potencialmente en varias pasadas** (`reinvocationPolicy: IfNeeded` reinvoca si otro webhook cambió el objeto). Esto genera problemas de idempotencia si tu mutación no es convergente.
- **`failurePolicy`** decide qué pasa si el webhook no responde:
  - `Fail` → *fail-closed*: si el motor está caído, **se rechaza la request**. Seguro pero peligroso: puede **bloquear todo el clúster**, incluidos los pods del propio motor de políticas.
  - `Ignore` → *fail-open*: si el motor está caído, **se admite sin evaluar**. Disponible pero inseguro (ventana de bypass).
- **`namespaceSelector` / `objectSelector`**: acotan a qué namespaces/objetos aplica el webhook. **Excluir el namespace del control plane y del propio motor es obligatorio** para no auto-bloquearte.
- **`timeoutSeconds`**: cada webhook suma latencia a *toda* request de escritura de su alcance. Un webhook lento degrada el API server entero.

### 2.2 El sustrato nativo: CEL y ValidatingAdmissionPolicy (VAP)

Desde **Kubernetes 1.30 (GA)**, el propio API server evalúa políticas **in-process** con **CEL** (*Common Expression Language*) vía `ValidatingAdmissionPolicy` — **sin webhook externo, sin binario que operar, sin latencia de red, y sin el problema de fail-closed que se auto-bloquea**. Es el sustrato sobre el que se está reconstruyendo el ecosistema (Gatekeeper y Kyverno pueden *generar* VAPs). En 1.32 llegó `MutatingAdmissionPolicy` (CEL mutante) en alpha/beta.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "require-cpu-limits"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  validations:
    - expression: >-
        object.spec.template.spec.containers.all(c,
          has(c.resources) && has(c.resources.limits) && ('cpu' in c.resources.limits))
      message: "Todo container debe declarar spec.resources.limits.cpu"
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "require-cpu-limits-binding"
spec:
  policyName: "require-cpu-limits"
  validationActions: ["Deny"]        # Deny | Warn | Audit — combinables
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: tenant
          operator: Exists
```

> **Fuente:** Dynamic Admission Control — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/ · ValidatingAdmissionPolicy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/

**Trade-off arquitectónico clave:** VAP elimina el *single point of failure* del webhook, pero **no tiene** mutación GA madura, ni `generate`, ni una librería de políticas reusable, ni verificación de firmas de imágenes, ni reporting cross-cluster. Por eso en 2025 la arquitectura de referencia es **híbrida**: VAP para las invariantes simples y de alta frecuencia (baratas, sin red), y un engine externo (Kyverno/Gatekeeper) para lo que VAP no cubre.

---

## 3. Comparativa técnica de los policy engines

### 3.1 Tabla maestra de trade-offs

| Dimensión | **OPA / Gatekeeper** | **Kyverno** | **ValidatingAdmissionPolicy (nativo)** | **jsPolicy** | **Cloud Custodian / Polaris** |
|---|---|---|---|---|---|
| **Lenguaje de política** | Rego (declarativo, datalog) | YAML declarativo (+CEL, +JMESPath) | CEL | JavaScript / TypeScript | YAML DSL / read-only checks |
| **Curva de aprendizaje** | Alta (Rego es un paradigma nuevo) | Baja (es “Kubernetes YAML”) | Media (CEL es acotado) | Baja para devs JS | Baja |
| **Validate** | ✅ | ✅ | ✅ | ✅ | Polaris: solo report |
| **Mutate** | ✅ (Assign/ModifySet) | ✅ (nativo, potente) | ⚠️ MutatingAdmissionPolicy (beta) | ✅ | ❌ |
| **Generate** | ❌ | ✅ (distintivo) | ❌ | ⚠️ manual | ❌ |
| **Verify images (cosign/notation)** | ⚠️ vía plugins externos | ✅ nativo (`verifyImages`) | ❌ | ❌ | ❌ |
| **Alcance** | Solo Kubernetes admission | Kubernetes admission + CLI + más | Solo Kubernetes admission | Solo Kubernetes admission | Cloud APIs (AWS/Azure/GCP) + K8s |
| **Reutiliza datos externos** | ✅ (data.inventory, external data) | ✅ (API calls, context, config maps) | ⚠️ limitado | ✅ (fetch en JS) | ✅ (cloud APIs) |
| **Testing** | `opa test`, `conftest` (maduro) | `kyverno test`, chainsaw | Poco tooling aún | Jest | Limitado |
| **Modelo de despliegue** | Webhook + controller | Webhook + controllers | In-process (sin webhook) | Webhook | Fuera de banda (scan) |
| **Portabilidad de la política** | Alta (Rego corre en cualquier lado) | Media (acoplada a K8s) | Baja (atada al API server) | Media | Baja |
| **Reporting de cumplimiento** | Audit + violations en CRDs | `PolicyReport` CRD (estándar) | Audit annotations/events | Manual | Nativo (report) |
| **Governance CNCF** | Graduated | Incubating | Kubernetes core | Sandbox-ish | Custodian: Incubating |

> Gatekeeper: https://open-policy-agent.github.io/gatekeeper/ · Kyverno: https://kyverno.io/docs/ · OPA: https://www.openpolicyagent.org/docs/

### 3.2 Cómo elegir (el criterio de arquitecto)

- **Elegí Kyverno** si tu equipo piensa en YAML, si necesitás `generate` (golden namespaces) o `verifyImages` (supply chain con cosign), y querés `PolicyReport` estándar. Es el camino de menor fricción para una IDP.
- **Elegí OPA/Gatekeeper** si ya usás **Rego en varios planos** (API gateways con OPA, Terraform con `conftest`, autorización de microservicios) y valorás **una sola gramática de política** en toda la organización; o si necesitás decisiones muy expresivas sobre datos relacionales.
- **Elegí VAP nativo** para las invariantes simples y críticas donde no querés depender de un pod externo (y como capa de defensa que sigue viva aunque el engine externo caiga).
- **Cloud Custodian / Polaris** son complementarios, no sustitutos: Custodian gobierna **recursos cloud** fuera de Kubernetes; Polaris es un **scorer read-only** para dashboards, no un enforcer.

**Anti-patrón:** desplegar Gatekeeper *y* Kyverno *y* VAP para la misma invariante. Multiplica webhooks, latencia y superficie de fallo. Una invariante, un dueño.

---

## 4. Manifiestos completos e infraestructura

### 4.1 Gatekeeper — ConstraintTemplate + Constraint (Rego)

El patrón de Gatekeeper es de **dos niveles**: una `ConstraintTemplate` define el *esquema del policy* y su Rego (la lógica reusable y parametrizable), y una o más `Constraint` la *instancian* con parámetros y alcance.

**ConstraintTemplate — exigir labels obligatorias:**

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
  annotations:
    description: >-
      Exige que los recursos porten un conjunto de labels que matcheen
      un patrón dado. Reusable vía parámetros.
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels        # Se vuelve un nuevo Kind de Constraint
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: object
                properties:
                  key:      { type: string }
                  allowedRegex: { type: string }
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels

        get_message(parameters, _default) := _default {
          not parameters.message
        }
        get_message(parameters, _default) := parameters.message {
          parameters.message
        }

        violation[{"msg": msg, "details": {"missing_labels": missing}}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_].key}
          missing := required - provided
          count(missing) > 0
          def_msg := sprintf("faltan labels obligatorias: %v", [missing])
          msg := get_message(input.parameters, def_msg)
        }

        violation[{"msg": msg}] {
          value := input.review.object.metadata.labels[key]
          expected := input.parameters.labels[_]
          expected.key == key
          expected.allowedRegex != ""
          not re_match(expected.allowedRegex, value)
          msg := sprintf("label <%v: %v> no matchea el patrón %v",
                         [key, value, expected.allowedRegex])
        }
```

**Constraint — instanciar contra namespaces de tenants:**

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: ns-must-have-owner-and-costcenter
spec:
  enforcementAction: deny          # deny | dryrun | warn
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Namespace"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    message: "Todo Namespace de tenant necesita labels 'owner' y 'cost-center' válidas."
    labels:
      - key: owner
        allowedRegex: "^[a-z0-9-]+@corp\\.io$"
      - key: cost-center
        allowedRegex: "^CC-[0-9]{4}$"
```

**Config de Gatekeeper — habilitar audit y excluir namespaces sensibles:**

```yaml
apiVersion: config.gatekeeper.sh/v1alpha1
kind: Config
metadata:
  name: config
  namespace: gatekeeper-system
spec:
  match:
    - excludedNamespaces: ["kube-system", "gatekeeper-system", "kube-node-lease"]
      processes: ["*"]
  # Replica recursos a la cache OPA para constraints que referencian data.inventory
  sync:
    syncOnly:
      - group: ""
        version: "v1"
        kind: "Namespace"
      - group: ""
        version: "v1"
        kind: "Pod"
```

### 4.2 Kyverno — validate + mutate + generate en una plataforma

**ClusterPolicy validante — baseline de seguridad de Pods (fail-closed real):**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pod-security-baseline
  annotations:
    policies.kyverno.io/title: Baseline de seguridad de Pods
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce      # Enforce (bloquea) | Audit (reporta)
  background: true                       # también escanea recursos existentes
  failurePolicy: Fail
  rules:
    - name: block-privileged
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system"]
      validate:
        message: "privileged/hostPath/hostNetwork están prohibidos en cargas de tenants."
        pattern:
          spec:
            =(hostNetwork): "false"
            =(hostPID): "false"
            containers:
              - =(securityContext):
                  =(privileged): "false"
                  =(allowPrivilegeEscalation): "false"
            =(volumes):
              - X(hostPath): "null"      # anchor de existencia negada
```

**Mutación — inyectar defaults con opinión (idempotente):**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-securitycontext-and-pullpolicy
spec:
  rules:
    - name: add-safe-securitycontext
      match:
        any:
          - resources: { kinds: ["Pod"] }
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              +(runAsNonRoot): true
              +(seccompProfile):
                +(type): RuntimeDefault
            containers:
              - (name): "*"
                securityContext:
                  +(allowPrivilegeEscalation): false
                  +(capabilities):
                    +(drop): ["ALL"]
    - name: pin-imagepullpolicy
      match:
        any:
          - resources: { kinds: ["Pod"] }
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                +(imagePullPolicy): IfNotPresent
```

> El `+()` es un *add-if-absent anchor*: solo agrega si el campo no existe → **idempotente**, seguro ante reinvocación del webhook.

**Generación — golden namespace automático (multi-tenancy):**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: bootstrap-tenant-namespace
spec:
  rules:
    - name: default-deny-netpol
      match:
        any:
          - resources:
              kinds: ["Namespace"]
              selector:
                matchLabels: { tenant: "true" }
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-all
        namespace: "{{request.object.metadata.name}}"
        synchronize: true      # si borran el hijo o cambia el padre, se reconcilia
        data:
          spec:
            podSelector: {}
            policyTypes: ["Ingress", "Egress"]
    - name: default-resourcequota
      match:
        any:
          - resources:
              kinds: ["Namespace"]
              selector:
                matchLabels: { tenant: "true" }
      generate:
        apiVersion: v1
        kind: ResourceQuota
        name: tenant-quota
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            hard:
              requests.cpu: "8"
              requests.memory: 16Gi
              limits.cpu: "16"
              limits.memory: 32Gi
              pods: "50"
```

**Supply chain — exigir firma cosign (keyless / Fulcio-Rekor):**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-corp-registry-signature
      match:
        any:
          - resources: { kinds: ["Pod"] }
      verifyImages:
        - imageReferences:
            - "registry.corp.io/*"
          failureAction: Enforce
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/corp/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

### 4.3 Instalación como infraestructura (Helm, reproducible)

```bash
# Kyverno — HA, con réplicas separadas del admission controller y el reports controller
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2 \
  --set reportsController.replicas=2 \
  --set admissionController.container.resources.limits.memory=384Mi \
  --version 3.x

# Gatekeeper — alternativa
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system --create-namespace \
  --set replicas=3 --set audit.interval=60
```

---

## 5. Comandos CLI y salidas de terminal reales

### 5.1 Verificar el estado del engine

```console
$ kubectl get pods -n kyverno
NAME                                             READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-7d9c8f4b6c-4xk2p    1/1     Running   0          6d
kyverno-admission-controller-7d9c8f4b6c-9lm7t    1/1     Running   0          6d
kyverno-background-controller-58f6d7c9d5-qz8vn   1/1     Running   0          6d
kyverno-reports-controller-6b7f9c8d4e-tk3wq      1/1     Running   0          6d

$ kubectl get clusterpolicy
NAME                                   ADMISSION   BACKGROUND   READY   AGE   MESSAGE
pod-security-baseline                  true        true         True    6d    Ready
default-securitycontext-and-pullpolicy true        true         True    6d    Ready
bootstrap-tenant-namespace             true        true         True    6d    Ready
require-signed-images                  true        true         True    6d    Ready
```

### 5.2 Ver los webhooks realmente registrados en el API server

```console
$ kubectl get validatingwebhookconfigurations
NAME                              WEBHOOKS   AGE
kyverno-policy-validating-webhook-cfg   1    6d
kyverno-resource-validating-webhook-cfg 1    6d

$ kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].failurePolicy}{"\t"}{.webhooks[0].timeoutSeconds}{"\n"}'
Fail    10
```

### 5.3 Probar el enforcement (el “no” accionable)

```console
$ kubectl run bad --image=nginx --privileged --restart=Never
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/bad was blocked due to the following policies

pod-security-baseline:
  block-privileged: 'validation error: privileged/hostPath/hostNetwork están
    prohibidos en cargas de tenants. rule block-privileged failed at path
    /spec/containers/0/securityContext/privileged/'
```

Gatekeeper produce un mensaje análogo:

```console
$ kubectl apply -f bad-namespace.yaml
Error from server (Forbidden): error when creating "bad-namespace.yaml":
admission webhook "validation.gatekeeper.sh" denied the request:
[ns-must-have-owner-and-costcenter] Todo Namespace de tenant necesita labels
'owner' y 'cost-center' válidas.
```

### 5.4 Confirmar que la mutación ocurrió

```console
$ kubectl run web --image=registry.corp.io/web:1.4 --restart=Never
pod/web created

$ kubectl get pod web -o jsonpath='{.spec.securityContext.runAsNonRoot}{"  "}{.spec.containers[0].imagePullPolicy}{"\n"}'
true  IfNotPresent

$ kubectl get pod web -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep policies
"policies.kyverno.io/last-applied-patches":"add-safe-securitycontext.default-securitycontext..."
```

### 5.5 Confirmar la generación de recursos derivados

```console
$ kubectl create ns team-payments && kubectl label ns team-payments tenant=true
namespace/team-payments created
namespace/team-payments labeled

$ kubectl get netpol,resourcequota -n team-payments
NAME                                           POD-SELECTOR   AGE
networkpolicy.networking.k8s.io/default-deny-all   <none>     3s

NAME                    AGE   REQUEST                                              LIMIT
resourcequota/tenant-quota  3s   requests.cpu: 0/8, requests.memory: 0/16Gi         limits.cpu: 0/16, limits.memory: 0/32Gi
```

### 5.6 Testear políticas fuera del clúster (shift-left, CI)

```console
$ kyverno apply pod-security-baseline.yaml --resource deployment-under-review.yaml
Applying 1 policy rule(s) to 1 resource(s)...

policy pod-security-baseline -> resource default/Deployment/api applied

pass: 0, fail: 1, warn: 0, error: 0, skip: 0

$ kyverno test .
Loading test  ( ./kyverno-test.yaml ) ...
  Test Count: 4
│ ID │ POLICY                │ RULE            │ RESOURCE          │ RESULT │
│ 1  │ pod-security-baseline │ block-privileged│ Pod/bad           │ Pass   │
│ 2  │ pod-security-baseline │ block-privileged│ Pod/good          │ Pass   │
│ 3  │ require-signed-images │ verify-...      │ Pod/unsigned      │ Pass   │
│ 4  │ require-signed-images │ verify-...      │ Pod/signed        │ Pass   │

Test Summary: 4 tests passed and 0 tests failed
```

Con OPA/Rego el equivalente en CI es `conftest` u `opa test`:

```console
$ opa test policy/ -v
PASS: 12/12
--------------------------------------------------------------------------------
data.k8srequiredlabels.test_missing_label: PASS (1.2ms)
data.k8srequiredlabels.test_bad_regex: PASS (0.9ms)
...

$ conftest test deployment.yaml -p policy/
FAIL - deployment.yaml - main - faltan labels obligatorias: {"cost-center"}
2 tests, 1 passed, 0 warnings, 1 failure
```

---

## 6. Guía de verificación y diagnóstico de fallas

### 6.1 Ladder de verificación (de barato a caro)

| Pregunta | Comando | Qué prueba |
|---|---|---|
| ¿El engine corre y está Ready? | `kubectl get clusterpolicy` / `kubectl get pods -n kyverno` | Liveness del motor |
| ¿El webhook está registrado y con qué `failurePolicy`? | `kubectl get validatingwebhookconfiguration -o yaml` | Que el API server realmente llama al motor |
| ¿La política bloquea lo que debe? | `kubectl apply` de un manifiesto *malo* → esperar el `denied` | Enforcement real, no solo “instalado” |
| ¿Muta idempotentemente? | aplicar dos veces, comparar `resourceVersion`/patches | Que no oscila entre webhooks |
| ¿Cuánta deuda de cumplimiento hay? | `kubectl get policyreport -A` / `kubectl get constraint` | Estado del parque existente |
| ¿Cuánta latencia agrega? | métrica `admission_review_duration` / `apiserver_admission_webhook_admission_duration_seconds` | Impacto en el API server |

### 6.2 Leer el reporting de cumplimiento

```console
$ kubectl get policyreport -A
NAMESPACE       NAME                         PASS   FAIL   WARN   ERROR   AGE
team-payments   cpol-pod-security-baseline   14     2      0      0       6d
team-orders     cpol-pod-security-baseline   31     0      0      0       6d

$ kubectl get policyreport -n team-payments cpol-pod-security-baseline \
    -o jsonpath='{range .results[?(@.result=="fail")]}{.resources[0].name}{" -> "}{.message}{"\n"}{end}'
legacy-cron-7  -> privileged/hostPath/hostNetwork están prohibidos...
legacy-cron-9  -> privileged/hostPath/hostNetwork están prohibidos...
```

Gatekeeper reporta violaciones en el estado del propio Constraint:

```console
$ kubectl get k8srequiredlabels ns-must-have-owner-and-costcenter \
    -o jsonpath='{.status.totalViolations}{"\n"}'
3
$ kubectl get k8srequiredlabels ns-must-have-owner-and-costcenter -o yaml | yq '.status.violations'
- enforcementAction: deny
  kind: Namespace
  message: 'faltan labels obligatorias: {"cost-center"}'
  name: sandbox-legacy
```

### 6.3 Síntomas, causa raíz y remediación

**Síntoma A — “Mi política no bloquea nada; todo pasa.”**

```console
$ kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].namespaceSelector}'
{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["team-payments"]}]}
```
- **Causa raíz:** el `namespaceSelector`/`objectSelector` excluye el namespace donde probás, **o** la política está en `validationFailureAction: Audit` en vez de `Enforce`, **o** `background`/admission están apagados.
- **Remediación:** verificá `spec.validationFailureAction: Enforce`, revisá `match`/`exclude`, y confirmá que el namespace no lleva label de exclusión. Reproducí con un recurso *malo* conocido.

**Síntoma B — “Todo el clúster se cayó: no puedo crear ni un Pod.”**

```console
$ kubectl run test --image=nginx
Error from server (InternalError): Internal error occurred: failed calling
webhook "validate.kyverno.svc-fail": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/validate/fail?timeout=10s":
dial tcp 10.96.0.42:443: connect: connection refused
```
- **Causa raíz clásica:** `failurePolicy: Fail` + el pod del engine caído (o su namespace sin recursos por un quota que la propia política impuso). Es el **deadlock de auto-bloqueo**.
- **Remediación de emergencia:** borrá la `ValidatingWebhookConfiguration` para restaurar el plano de escritura, recuperá el engine, reaplicá:
  ```console
  $ kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg
  validatingwebhookconfiguration.admissionregistration.k8s.io "..." deleted
  ```
- **Prevención estructural:** excluir *siempre* `kube-system`, el namespace del engine y el control plane; correr el admission controller con **≥3 réplicas** y `PodDisruptionBudget`; reservarle recursos para que no lo mate un `ResourceQuota` propio; considerar `failurePolicy: Ignore` para políticas no críticas y reservar `Fail` para las de seguridad dura.

**Síntoma C — “La request tarda muchísimo / timeouts intermitentes.”**

```console
$ kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration_seconds_bucket \
    | grep 'name="validate.kyverno.svc-fail"' | tail -3
apiserver_admission_webhook_...duration_seconds_bucket{...,le="2.5"} 4021
apiserver_admission_webhook_...duration_seconds_bucket{...,le="5"}   4118
apiserver_admission_webhook_...duration_seconds_bucket{...,le="+Inf"} 4290
```
- **Causa raíz:** una política hace llamadas a APIs externas (`verifyImages` contra Rekor, `context` con API calls) sin cache; o el `timeoutSeconds` es alto y el backend firma-verificación está lento.
- **Remediación:** subí réplicas del admission controller, acotá `match` (no evalúes Pods en todos los namespaces si solo importan los de tenant), habilitá caching de `verifyImages`, y **medí p99** de `admission_duration` como SLI del engine.

**Síntoma D — “La mutación entra en loop / el objeto ‘vibra’.”**
- **Causa raíz:** mutación **no idempotente** — el patch agrega un valor que otro webhook reescribe, y `reinvocationPolicy: IfNeeded` los reinvoca en ciclo.
- **Remediación:** usá *anchors* de existencia (`+()` en Kyverno, `pathTests`/`Assign` con condición en Gatekeeper) para que el patch sea **convergente** (aplicar N veces == aplicar una).

**Síntoma E — “La política nueva rechaza deploys viejos que antes funcionaban.”**
- **Causa raíz:** introdujiste una política en `Enforce` sin medir la deuda existente.
- **Remediación (rollout seguro):** desplegá primero en `Audit`/`dryrun`, leé el `PolicyReport`/`status.violations`, remediá o excluí los recursos legacy con un `exclude` explícito y *time-boxed*, y recién entonces pasá a `Enforce`. Esto es el mismo principio del CLAUDE.md de esta plataforma: *“introducir una política nueva sin romper lo que ya corre”*.

### 6.4 Checklist de producción antes de poner una política en `Enforce`

- [ ] Testeada con `kyverno test` / `opa test` en CI (casos *good* y *bad*).
- [ ] Desplegada primero en `Audit`; `PolicyReport` revisado; deuda legacy resuelta o excluida.
- [ ] `match`/`exclude` acotan el alcance; `kube-system` y el namespace del engine excluidos.
- [ ] Decisión consciente de `failurePolicy` (`Fail` solo para seguridad dura, con HA + PDB).
- [ ] `timeoutSeconds` mínimo viable; p99 de `admission_duration` monitoreado como SLI.
- [ ] Mutaciones probadas como **idempotentes** (aplicar dos veces no cambia el resultado).
- [ ] Runbook de emergencia documentado: cómo borrar el webhook para recuperar el clúster.
- [ ] Una invariante ↔ un engine (sin duplicar la misma regla en dos motores).

---

## 7. Referencias

- Kubernetes — Dynamic Admission Control: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Validating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — Mutating Admission Policy: https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- Kubernetes — Admission Controllers Reference: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- CEL — Common Expression Language spec: https://github.com/google/cel-spec
- Open Policy Agent — Documentación: https://www.openpolicyagent.org/docs/
- OPA Gatekeeper — Documentación: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Gatekeeper — Library de políticas: https://open-policy-agent.github.io/gatekeeper-library/website/
- Kyverno — Documentación: https://kyverno.io/docs/
- Kyverno — Políticas de ejemplo: https://kyverno.io/policies/
- Kyverno — Verify Images (cosign/notation): https://kyverno.io/docs/writing-policies/verify-images/
- Policy Report CRD (Kubernetes Policy WG): https://github.com/kubernetes-sigs/wg-policy-prototypes
- Sigstore / cosign: https://docs.sigstore.dev/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Cloud Custodian: https://cloudcustodian.io/docs/
- Polaris (Fairwinds): https://polaris.docs.fairwinds.com/
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf