# 2.2 Kyverno Custom Resource Definitions (CRDs)

## 1. Motivación: la política como objeto de la API de Kubernetes de primera clase

La apuesta arquitectónica de Kyverno es que **la política no es un lenguaje aparte que vive fuera del clúster — es un recurso de Kubernetes como cualquier otro**. Cada capacidad de Kyverno se expone a través de un `CustomResourceDefinition`. No es una decisión cosmética; es la elección de diseño portante que determina cómo operás la política a escala.

El problema de producción que esto resuelve: en una plataforma multi-tenant con decenas de namespaces y cientos de workloads, necesitás gobernanza (exigir `runAsNonRoot`, bloquear tags `:latest`, forzar límites de recursos, auto-generar `NetworkPolicy` para cada namespace nuevo). Las dos respuestas históricas eran ambas dolorosas:

- **Admission webhooks escritos a mano** (Go a medida, un `ValidatingWebhookConfiguration`, un Deployment, un Service, rotación de certificados). Cada regla es código que construís, desplegás y por el que te llaman de guardia.
- **OPA Gatekeeper**, que está basado en CRDs pero divide el modelo en dos: un `ConstraintTemplate` (lógica Rego) más un `Constraint` (parámetros), y tenés que aprender Rego.

La respuesta de Kyverno es que, como las políticas son CRDs, heredan el *entero* control plane de Kubernetes gratis:

| Capacidad | Cómo te lo dan los CRDs |
|---|---|
| Autoría | YAML plano — sin Rego, sin Go. La misma forma que un Deployment. |
| Control de acceso | RBAC estándar `Role`/`ClusterRole` sobre `clusterpolicies.kyverno.io`. |
| Almacenamiento y auditoría | etcd + el audit log del API server registran cada cambio de política. |
| Herramientas | `kubectl get/describe/explain/apply`, `kustomize`, `helm`, ArgoCD, Flux. |
| Validación | El esquema OpenAPI v3 del CRD rechaza políticas malformadas en el momento del `kubectl apply`, antes de que el controlador siquiera corra. |
| GitOps | Una política es un manifiesto en un repo; la detección de drift y el rollback son iguales que para cualquier workload. |
| Reporting | Los resultados *también* son CRDs (`PolicyReport`), así que `kubectl get polr` y Prometheus/Policy Reporter pueden consumirlos. |

La consecuencia para un SRE: **no hay ningún lenguaje de consulta ni almacén de estado específico de Kyverno que aprender o respaldar.** Si sabés Kubernetes, ya sabés cómo leer, asegurar, diferenciar y hacer rollback de una política de Kyverno. El trade-off — detallado en §2 — es que la expresividad está acotada por lo que permiten el esquema del CRD y el motor JMESPath/CEL, frente al Rego casi-Turing de Gatekeeper.

---

## 2. El panorama completo de CRDs de Kyverno

Kyverno trae **tres grupos de API**. Saber qué grupo es dueño de qué kind — y, algo crítico, **quién escribe cada objeto (vos vs. un controlador de Kyverno)** — es el modelo mental más útil para el examen y para el debugging.

```
$ kubectl api-resources --api-group=kyverno.io
NAME                     SHORTNAMES   APIVERSION           NAMESPACED   KIND
cleanuppolicies          cleanpol     kyverno.io/v2        true         CleanupPolicy
clustercleanuppolicies   ccleanpol    kyverno.io/v2        false        ClusterCleanupPolicy
clusterpolicies          cpol         kyverno.io/v1        false        ClusterPolicy
globalcontextentries     gctxentry    kyverno.io/v2alpha1  false        GlobalContextEntry
policies                 pol          kyverno.io/v1        true         Policy
policyexceptions         polex        kyverno.io/v2        true         PolicyException
updaterequests           ur           kyverno.io/v2        true         UpdateRequest

$ kubectl api-resources --api-group=reports.kyverno.io
NAME                            APIVERSION              NAMESPACED   KIND
admissionreports                reports.kyverno.io/v1   true         AdmissionReport
backgroundscanreports           reports.kyverno.io/v1   true         BackgroundScanReport
clusteradmissionreports         reports.kyverno.io/v1   false        ClusterAdmissionReport
clusterbackgroundscanreports    reports.kyverno.io/v1   false        ClusterBackgroundScanReport
ephemeralreports                reports.kyverno.io/v1   true         EphemeralReport
clusterephemeralreports         reports.kyverno.io/v1   false        ClusterEphemeralReport

$ kubectl api-resources --api-group=wgpolicyk8s.io
NAME                    SHORTNAMES   APIVERSION                NAMESPACED   KIND
clusterpolicyreports    cpolr        wgpolicyk8s.io/v1alpha2   false        ClusterPolicyReport
policyreports           polr         wgpolicyk8s.io/v1alpha2   true         PolicyReport
```

### 2.1 Tabla de referencia de CRDs

| Kind | Grupo / Versión | Alcance | ¿Lo escribís vos? | Propósito |
|---|---|---|---|---|
| **ClusterPolicy** | `kyverno.io/v1` | Cluster | ✅ | El objeto de política primario; las reglas aplican a todo el clúster. |
| **Policy** | `kyverno.io/v1` | Namespaced | ✅ | El mismo esquema de reglas, acotado a un namespace (autoservicio del tenant). |
| **PolicyException** | `kyverno.io/v2` | Namespaced | ✅ | Excepciones: eximir recursos específicos de reglas nombradas. |
| **CleanupPolicy** | `kyverno.io/v2` | Namespaced | ✅ | Borrado programado estilo TTL de los recursos que coinciden. |
| **ClusterCleanupPolicy** | `kyverno.io/v2` | Cluster | ✅ | Lo mismo, a nivel de todo el clúster. |
| **GlobalContextEntry** | `kyverno.io/v2alpha1` | Cluster | ✅ | Datos externos/de API cacheados y compartidos entre políticas (evita llamadas a la API por cada request). |
| **PolicyReport** | `wgpolicyk8s.io/v1alpha2` | Namespaced | ❌ (controlador) | Resultados agregados de pass/fail por namespace (estándar abierto de la CNCF). |
| **ClusterPolicyReport** | `wgpolicyk8s.io/v1alpha2` | Cluster | ❌ (controlador) | Resultados agregados para recursos de alcance de clúster. |
| **UpdateRequest** | `kyverno.io/v2` | Namespaced | ❌ (controlador) | Cola interna que impulsa `generate` y `mutateExisting`. |
| **AdmissionReport** / **BackgroundScanReport** (+ `Cluster*`, `Ephemeral*`) | `reports.kyverno.io/v1` | Ambos | ❌ (controlador) | Resultados intermedios por recurso que el reports-controller agrega en `PolicyReport`. |

**La distinción que más importa:** el bloque de arriba (`ClusterPolicy` … `GlobalContextEntry`) es la **entrada** que vos autorás. El bloque de abajo (`*Report`, `UpdateRequest`, `reports.kyverno.io/*`) es la **salida/estado** que escriben los controladores de Kyverno — lo leés, nunca lo editás a mano. Intentar `kubectl edit polr` es una señal de alerta en una entrevista y un no-op en la práctica (el controlador lo reconcilia de vuelta).

### 2.2 CRDs de Kyverno vs. las alternativas

| Dimensión | CRDs de Kyverno | CRDs de Gatekeeper | Webhook hecho a mano |
|---|---|---|---|
| # de CRDs para modelar una regla | 1 (`ClusterPolicy`) | 2 (`ConstraintTemplate` + `Constraint`) | 0 (pero el servidor es tuyo) |
| Lenguaje de autoría | YAML + JMESPath/CEL | Rego (en un campo del CRD) | Go/cualquiera |
| Validación de esquema de la política en sí | Sí (esquema OpenAPI del CRD) | Parcial (Rego es opaco al esquema) | Ninguna |
| Mutación | Sí (`mutate`) | Sí (CRDs Assign/ModifySet) | Sí |
| Generación de recursos | Sí (`generate` + `UpdateRequest`) | Sin equivalente nativo | Sí |
| CRD de reporting nativo | Sí (`PolicyReport`) | Sí (status en el Constraint) + `PolicyReport` vía export | Lo construís vos |
| Curva de aprendizaje | Baja (YAML de Kubernetes) | Alta (Rego) | Muy alta |

El costo de la ergonomía de un solo CRD de Kyverno es un **esquema de CRD más grande y más profundo** — el esquema OpenAPI de `ClusterPolicy` es uno de los más grandes del ecosistema, lo que crea un problema operativo real que se cubre en §7 (`kubectl apply` fallando por el tamaño de las anotaciones).

---

## 3. Anatomía de los CRDs de política: `ClusterPolicy` y `Policy`

`ClusterPolicy` y `Policy` comparten un `spec` idéntico; solo difieren en el alcance. El `spec` es una lista de `rules`, cada una de las cuales hace exactamente **una** de: `validate`, `mutate`, `generate` o `verifyImages`.

Una política multi-regla completa y sintácticamente válida que ejercita el esquema central:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: platform-baseline
  annotations:
    policies.kyverno.io/title: Platform Baseline
    policies.kyverno.io/category: Pod Security, Supply Chain
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Baseline guardrails: enforce non-root, mutate default resource
      requests, and auto-generate a default-deny NetworkPolicy per namespace.
spec:
  # Apply/skip background scanning of already-existing resources.
  background: true
  # Cluster-default action; can be overridden per-namespace or per-rule.
  validationFailureAction: Enforce
  validationFailureActionOverrides:
    - action: Audit          # softer in the sandbox namespaces
      namespaces:
        - sandbox-*
  # Webhook behavior if Kyverno itself is unreachable.
  failurePolicy: Fail
  webhookTimeoutSeconds: 10
  # If multiple rules match, evaluate all of them.
  applyRules: All
  rules:
    # ---- RULE 1: validate ----
    - name: require-run-as-non-root
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      validate:
        message: "Containers must set securityContext.runAsNonRoot=true."
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(runAsNonRoot): "true"

    # ---- RULE 2: mutate (defaulting) ----
    - name: default-resource-requests
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                resources:
                  requests:
                    +(memory): "128Mi"
                    +(cpu): "100m"

    # ---- RULE 3: generate (resource provisioning) ----
    - name: default-deny-networkpolicy
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
        synchronize: true          # keep the generated object reconciled
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

Campos clave del esquema que un SRE debe reconocer:

- **`match` / `exclude`** — selección. Ambos aceptan `any` (OR lógico de los selectores listados) y `all` (AND lógico). Los selectores filtran por `kinds`, `namespaces`, `names`, `selector` (labels), `annotations`, `operations`, y `subjects`/`roles`/`clusterRoles`.
- **`background`** — cuando es `true`, la regla también la evalúa el background scan contra recursos que *ya existen*, produciendo entradas de `PolicyReport`. `mutate`/`generate` sobre contexto disponible solo en tiempo de request no pueden correr en background.
- **`validationFailureAction`** — `Enforce` (bloquear en la admisión) vs `Audit` (permitir, pero registrar un `fail` en el reporte). En `kyverno.io/v1` está a nivel de `spec`; en `v2beta1`/`v2` se mueve **dentro de la regla** como `validate.failureAction`. Conocé ambos — esta es una trampa clásica de version-skew.
- **`failurePolicy`** — `Fail` vs `Ignore`, cableado directamente en el `ValidatingWebhookConfiguration` generado. `Fail` significa «si Kyverno está caído, rechazar el request» (fail-closed).
- **Anchors en los patrones** — `=(x)` anchor condicional («si x existe, debe coincidir»), `+(x)` agregar-si-ausente (mutate), `(x)` anchor de coincidencia, `X(...)` global. Son la gramática de overlay de Kyverno y aparecen por todo validate/mutate.

El mismo objeto como `Policy` namespaced difiere solo en el `kind` y la presencia de un `metadata.namespace`:

```yaml
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: team-a-baseline
  namespace: team-a
spec:
  validationFailureAction: Audit
  rules:
    - name: require-team-label
      match:
        any:
          - resources:
              kinds: [Pod, Deployment, Service]
      validate:
        message: "All resources must carry the 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"      # ?* = non-empty string
```

---

## 4. Los CRDs auxiliares, con manifiestos completos

### 4.1 `PolicyException` — excepciones gobernadas

Las excepciones son en sí mismas un CRD, así que eximir un workload es un acto auditable, controlado por RBAC y rastreado por GitOps — no una edición de la política.

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: allow-privileged-monitoring
  namespace: monitoring
spec:
  exceptions:
    - policyName: platform-baseline
      ruleNames:
        - require-run-as-non-root
        - autogen-require-run-as-non-root   # exempt the auto-generated variant too
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - monitoring
          names:
            - node-exporter-*
```

Fijate en el nombre de regla `autogen-*`: Kyverno auto-genera variantes de controladores de Pod a partir de las reglas de Pod (para Deployment/DaemonSet/StatefulSet/Job/CronJob). Una excepción con frecuencia debe nombrar **tanto** la regla base como su hermana autogen.

### 4.2 `CleanupPolicy` / `ClusterCleanupPolicy` — borrado programado

Un CRD (y controlador) dedicado al borrado basado en tiempo — sin `validate/mutate/generate` involucrados.

```yaml
apiVersion: kyverno.io/v2
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-completed-jobs
spec:
  match:
    any:
      - resources:
          kinds:
            - Job
  conditions:
    all:
      - key: "{{ target.status.succeeded || `0` }}"
        operator: Equals
        value: 1
  schedule: "*/10 * * * *"     # standard cron; controller deletes matches each run
```

### 4.3 `GlobalContextEntry` — datos cacheados compartidos

Introducido para evitar que cada admission request martille el API server o un endpoint externo. El controlador lo puebla y lo refresca; las políticas lo leen vía `context`.

```yaml
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: deployments-count
spec:
  apiCall:
    urlPath: "/apis/apps/v1/deployments"
    refreshInterval: 10m
```

### 4.4 `PolicyReport` / `ClusterPolicyReport` — el lado de la salida

Estos nunca los autorás vos. Un objeto representativo que produce el reports-controller:

```yaml
apiVersion: wgpolicyk8s.io/v1alpha2
kind: PolicyReport
metadata:
  name: cpol-platform-baseline
  namespace: team-a
scope:
  apiVersion: v1
  kind: Pod
  name: web-7d9f-xk2p9
summary:
  pass: 2
  fail: 1
  warn: 0
  error: 0
  skip: 0
results:
  - policy: platform-baseline
    rule: require-run-as-non-root
    result: fail
    severity: high
    category: Pod Security
    source: kyverno
    message: "validation error: Containers must set securityContext.runAsNonRoot=true."
    resources:
      - apiVersion: v1
        kind: Pod
        name: web-7d9f-xk2p9
        namespace: team-a
```

Como se ajusta al estándar abierto del **CNCF Policy Working Group** (`wgpolicyk8s.io`), el *mismo* objeto `PolicyReport` es consumible por Policy Reporter, Trivy-operator y cualquier herramienta compatible con el WG — no solo Kyverno.

### 4.5 Los CRDs de política más nuevos basados en CEL (Kyverno 1.14+)

Las versiones recientes de Kyverno introdujeron una familia paralela bajo el grupo **`policies.kyverno.io/v1alpha1`** que refleja el `ValidatingAdmissionPolicy` upstream de Kubernetes y se autora en **CEL** en lugar de overlays JMESPath: `ValidatingPolicy`, `ImageValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy`, `DeletingPolicy`. Según el snapshot del examen, estos pueden o no estar en el alcance; reconocé que son CRDs *adicionales*, no reemplazos de `ClusterPolicy`.

```yaml
apiVersion: policies.kyverno.io/v1alpha1
kind: ValidatingPolicy
metadata:
  name: require-labels-cel
spec:
  validationActions: [Deny]
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  validations:
    - expression: "has(object.metadata.labels) && 'team' in object.metadata.labels"
      message: "Pods must have a 'team' label."
```

---

## 5. Instalación, versionado y conversión de CRDs — la capa operativa

Los CRDs se instalan como parte del release de Kyverno. El chart de Helm los separa precisamente porque el ciclo de vida del CRD es independiente del ciclo de vida del controlador:

```
$ helm repo add kyverno https://kyverno.github.io/kyverno/
$ helm install kyverno-crds kyverno/kyverno-crds -n kyverno --create-namespace
$ helm install kyverno kyverno/kyverno -n kyverno
```

Dos realidades de producción:

1. **Múltiples versiones servidas + un conversion webhook.** `ClusterPolicy` se sirve en `v1`, `v2beta1`, `v2` simultáneamente. Un conversion webhook (parte de Kyverno) traduce entre las versiones almacenada y solicitada. Si el Service de admisión de Kyverno está degradado, **`kubectl get cpol` en sí puede fallar** porque el API server no puede convertir los objetos almacenados — un modo de falla que sorprende a quienes asumen que «las lecturas siempre funcionan».

2. **Tamaño del esquema del CRD.** El esquema de `ClusterPolicy` es enorme. Aplicar los CRDs con `kubectl apply` del lado del cliente escribe el objeto previo entero en la anotación `last-applied-configuration` y puede exceder el límite de metadata de 262 144 bytes:

```
$ kubectl apply -f kyverno-crds.yaml
The CustomResourceDefinition "clusterpolicies.kyverno.io" is invalid:
metadata.annotations: Too long: must have at most 262144 bytes
```

El arreglo — y la razón por la que la documentación lo exige — es el **server-side apply**:

```
$ kubectl apply --server-side --force-conflicts -f kyverno-crds.yaml
customresourcedefinition.apiextensions.k8s.io/clusterpolicies.kyverno.io serverside-applied
```

---

## 6. Comandos de CLI y salida real de terminal

Inspeccionar lo que existe:

```
$ kubectl get crds | grep -E 'kyverno|wgpolicy'
admissionreports.reports.kyverno.io                  2026-08-10T09:12:44Z
backgroundscanreports.reports.kyverno.io             2026-08-10T09:12:44Z
cleanuppolicies.kyverno.io                           2026-08-10T09:12:44Z
clusteradmissionreports.reports.kyverno.io           2026-08-10T09:12:44Z
clusterbackgroundscanreports.reports.kyverno.io      2026-08-10T09:12:44Z
clustercleanuppolicies.kyverno.io                    2026-08-10T09:12:44Z
clusterpolicies.kyverno.io                           2026-08-10T09:12:44Z
clusterpolicyreports.wgpolicyk8s.io                  2026-08-10T09:12:44Z
globalcontextentries.kyverno.io                      2026-08-10T09:12:44Z
policies.kyverno.io                                  2026-08-10T09:12:44Z
policyexceptions.kyverno.io                          2026-08-10T09:12:44Z
policyreports.wgpolicyk8s.io                         2026-08-10T09:12:44Z
updaterequests.kyverno.io                            2026-08-10T09:12:44Z
```

Confirmar que un CRD está efectivamente **Established** y **NamesAccepted** (un CRD puede existir pero no estar servido):

```
$ kubectl get crd clusterpolicies.kyverno.io \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
NamesAccepted=True
Established=True
```

Descubrir el esquema sin salir de la terminal — así es como aprendés los nombres de los campos en el examen:

```
$ kubectl explain clusterpolicy.spec.rules.validate
KIND:       ClusterPolicy
VERSION:    kyverno.io/v1

FIELD: validate <Object>

DESCRIPTION:
    Validation is used to validate matching resources.
FIELDS:
  allowExistingViolations   <boolean>
  anyPattern                <Object>
  cel                       <Object>
  deny                      <Object>
  failureAction             <string>
  foreach                   <[]Object>
  message                   <string>
  pattern                   <Object>
  podSecurity               <Object>
```

Listar las políticas y su estado agregado:

```
$ kubectl get cpol
NAME                ADMISSION   BACKGROUND   READY   AGE   MESSAGE
platform-baseline   true        true         True    3h    Ready

$ kubectl get polr -A
NAMESPACE   NAME                       KIND   NAME                PASS   FAIL   WARN   ERROR   SKIP   AGE
team-a      cpol-platform-baseline     Pod    web-7d9f-xk2p9      2      1      0      0        0      2h

$ kubectl get cpolr
NAME                   PASS   FAIL   WARN   ERROR   SKIP   AGE
cpol-platform-baseline 14     0      0      0        0      3h
```

Observar la maquinaria de `generate` a través de su CRD interno:

```
$ kubectl get ur -n kyverno
NAME             POLICY              RULETYPE   RESOURCEKIND   RESOURCENAME   STATE       AGE
ur-8f2kd         platform-baseline   generate   Namespace      team-b         Completed   12s
```

---

## 7. Verificación y diagnóstico de fallas

### 7.1 `kubectl apply` falla por el tamaño de las anotaciones del CRD
**Síntoma:** `metadata.annotations: Too long: must have at most 262144 bytes` al instalar/actualizar los CRDs.
**Causa:** El apply del lado del cliente almacena el esquema entero (enorme) en `kubectl.kubernetes.io/last-applied-configuration`.
**Arreglo:** `kubectl apply --server-side --force-conflicts -f <crds>` (o instalá vía el chart de Helm `kyverno-crds`). Confirmá: el apply imprime `serverside-applied`.

### 7.2 `kubectl get cpol` se cuelga o da error después de que Kyverno queda degradado
**Síntoma:** `Error from server: conversion webhook for kyverno.io/v1, Kind=ClusterPolicy failed: ... service "kyverno-svc" not found` — incluso para una simple **lectura**.
**Causa:** Las múltiples versiones servidas requieren el conversion webhook; si el Service/los Pods de admisión de Kyverno están caídos, la conversión falla.
**Diagnóstico:**
```
$ kubectl -n kyverno get pods
$ kubectl get validatingwebhookconfiguration | grep kyverno
$ kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.spec.conversion.strategy}{"\n"}'
Webhook
```
**Arreglo:** restaurá el Deployment/Service del admission-controller de Kyverno; las lecturas se recuperan una vez que el endpoint del webhook es alcanzable.

### 7.3 Una política se aplica pero nunca bloquea ni reporta
**Checklist:**
```
# 1. Is it Ready and set to Enforce/Audit as intended?
$ kubectl get cpol platform-baseline -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
True
# 2. Did the webhook actually register the rule's resource kinds?
$ kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[*].rules[*].resources}{"\n"}'
# 3. Is background scanning on, if you expect a report for existing resources?
$ kubectl get cpol platform-baseline -o jsonpath='{.spec.background}{"\n"}'
true
# 4. Is there a PolicyException silently exempting the target?
$ kubectl get polex -A
```

### 7.4 Version skew de CRD después de un upgrade
**Síntoma:** `strict decoding error: unknown field "spec.validationFailureAction"` (el campo se movió dentro de la regla en `v2beta1`/`v2`).
**Causa:** Manifiestos escritos para una versión servida, aplicados contra una versión de autoría por defecto más nueva.
**Arreglo:** fijá la versión que autorás (`apiVersion: kyverno.io/v1`) o migrá `validationFailureAction` → `validate.failureAction`. Inspeccioná las versiones servidas/almacenadas:
```
$ kubectl get crd clusterpolicies.kyverno.io \
    -o jsonpath='{.spec.versions[*].name}  stored={.status.storedVersions}{"\n"}'
v1 v2beta1 v2  stored=[v1]
```

### 7.5 CRD presente pero no `Established`
**Síntoma:** `kubectl get cpol` → `the server doesn't have a resource type "clusterpolicies"` justo después de instalar.
**Diagnóstico:** revisá la condición `Established` (§6). Si `NamesAccepted=False`, existe una colisión de nombres; si `Established=False`, el CRD todavía se está registrando — esperá o volvé a aplicar.

---

## 8. Referencias

- Kyverno — Custom Resources / Referencia de la API: https://kyverno.io/docs/policy-types/
- Kyverno — Esquema del CRD de política (`ClusterPolicy`/`Policy`): https://htmlpreview.github.io/?https://github.com/kyverno/kyverno/blob/main/docs/user/crd/index.html
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Kyverno — Policy Exceptions: https://kyverno.io/docs/exceptions/
- Kyverno — Cleanup Policies: https://kyverno.io/docs/policy-types/cleanup-policy/
- Kyverno — Instalación (requisito de server-side apply para los CRDs): https://kyverno.io/docs/installation/
- Kyverno — GlobalContextEntry / datos externos: https://kyverno.io/docs/policy-types/cluster-policy/external-data-sources/
- CNCF Policy WG — Estándar abierto PolicyReport (`wgpolicyk8s.io`): https://github.com/kubernetes-sigs/wg-policy-prototypes
- Kubernetes — Concepto de CustomResourceDefinitions y versionado/conversión: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Kubernetes — Server-Side Apply: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- CNCF Curriculum (KCA): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf