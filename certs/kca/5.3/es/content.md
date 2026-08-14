# 5.3 Background Scans

> **Dominio 5 — Aplicar políticas en producción · Peso en el examen: 2.91**
> Aplica a Kyverno 1.10 → 1.14 (la arquitectura de cuatro controladores). Donde un comportamiento cambió dentro de ese rango, se señala en línea. Verificá la versión exacta que fija el examen con `kyverno version` y `kubectl -n kyverno get deploy -o wide`.

---

## 1. El problema arquitectónico: el admission control es un control puntual en el tiempo

Un `ValidatingWebhookConfiguration` es un control **preventivo y orientado a eventos**. El API server llama al admission controller de Kyverno únicamente cuando existe un `AdmissionRequest` — es decir, en `CREATE`, `UPDATE`, `DELETE` o `CONNECT` para las reglas con las que el webhook está registrado. En el instante en que el objeto se persiste en etcd, Kyverno no vuelve a mirarlo jamás salvo que alguien lo toque.

Esa única propiedad produce toda una familia de puntos ciegos en producción. Cada uno de ellos es un patrón de incidente real, no teórico:

| # | Punto ciego | Por qué el admission no puede verlo | Latencia de detección típica sin background scans |
|---|---|---|---|
| 1 | **Policy escrita después de las cargas de trabajo** | Los 4.000 Pods anteriores a `require-run-as-nonroot` nunca fueron enviados al webhook | Para siempre |
| 2 | **Policy modificada en el lugar** | Endurecer un `pattern` no vuelve a registrar nada; los objetos existentes no se readmiten | Hasta el próximo redespliegue de cada carga de trabajo |
| 3 | **Caída de Kyverno con `failurePolicy: Ignore`** | El API server falla en abierto; las requests se admiten sin evaluar | Para siempre (silencioso) |
| 4 | **Deriva de contexto** — la policy lee un ConfigMap, un `apiCall` o un registro de imágenes, y *eso* cambió | El recurso no cambió, así que no se genera ningún `AdmissionRequest` | Para siempre |
| 5 | **Revocación de firma / re-tag de imagen** (`verifyImages`) | El tag mutable ahora resuelve a un digest distinto, o la clave fue revocada | Para siempre |
| 6 | **Exclusiones por `resourceFilters` / `namespaceSelector`** | Excluidos deliberadamente del webhook para proteger el control plane | Para siempre |
| 7 | **Namespace reetiquetado** | `namespaceSelector` deja de coincidir (o empieza a hacerlo) sin tocar la carga de trabajo | Hasta la próxima escritura de la carga de trabajo |
| 8 | **Un upgrade del cluster elimina una API** | Nadie escribió el objeto; cambió la representación del lado del servidor | Hasta el próximo `kubectl apply` |
| 9 | **`kubectl edit` mientras la policy estaba en `Audit`** | Audit nunca bloqueó nada | Para siempre |
| 10 | **`--dry-run=server` / bypass vía API agregada o restore directo de etcd** | Las rutas de restore (Velero, snapshot de etcd) pueden saltear los webhooks o competir con ellos | Para siempre |

La respuesta de Kyverno es un segundo plano de control, **detectivo**: un controlador que reevalúa periódicamente cada policy contra cada objeto *vivo* y escribe los veredictos en custom resources `PolicyReport` / `ClusterPolicyReport`. Esa reevaluación periódica es el **background scan**.

### 1.1 Los dos controles son complementarios, no redundantes

```
                       ┌──────────────────────────── PREVENTIVE ───────────────────────────┐
  kubectl apply ─────▶ kube-apiserver ─▶ ValidatingWebhook ─▶ kyverno-admission-controller
                            │                                          │
                            │                                          ├─▶ allow / deny (Enforce)
                            │                                          └─▶ EphemeralReport (admission)
                            ▼
                          etcd  ◀────────────── live cluster state
                            │
                            │  LIST/WATCH every `backgroundScanInterval`
                            ▼
        ┌──────────────── DETECTIVE ─────────────────┐
        kyverno-reports-controller  ──▶ EphemeralReport (background scan)
                    │
                    └──▶ aggregation ──▶ PolicyReport / ClusterPolicyReport
                                                │
                                                └──▶ Policy Reporter · Prometheus · SIEM · OPA-free dashboards
```

El modelo mental que hay que llevarse al examen y a producción:

* **El admission control decide.** Es lo único que puede decir *no*.
* **El background scan observa.** Nunca puede bloquear, ni mutar, ni borrar. Sólo te dice la verdad sobre lo que hay en el cluster ahora mismo.
* Un cluster con policies en `Enforce` y **sin** background scan tiene una postura de cumplimiento *desconocida* para todo lo creado antes de que la policy existiera.
* Un cluster con background scan y **sólo** policies en `Audit` tiene *visibilidad perfecta* y *cero* enforcement.

---

## 2. Dónde viven los background scans en la arquitectura de Kyverno

Desde **Kyverno 1.10** el deployment monolítico `kyverno` se dividió en cuatro controladores escalables de forma independiente. Saber qué hace cada controlador es directamente relevante para el examen, porque "background" es una palabra sobrecargada en Kyverno.

| Deployment | Responsabilidad | ¿Ejecuta *background scans*? | Modelo de escalado |
|---|---|---|---|
| `kyverno-admission-controller` | Sirve los webhooks de validación/mutación; evalúa `validate`, `mutate`, `verifyImages` en admisión; escribe los `EphemeralReport`s de admisión | **No** | HA, N réplicas, todas activas (stateless detrás de un Service) |
| `kyverno-background-controller` | Reconcilia reglas `generate` y reglas `mutate` con `targets` (mutateExisting) mediante objetos `UpdateRequest` | **No** — esto es *procesamiento* en background, no *escaneo* en background | Con elección de líder |
| `kyverno-reports-controller` | **Ejecuta los background scans**; agrega los reportes efímeros en `PolicyReport`/`ClusterPolicyReport` | **Sí — este es el que lo hace** | Con elección de líder; limitado en memoria por las cachés de los informers |
| `kyverno-cleanup-controller` | `CleanupPolicy` / `ClusterCleanupPolicy`, borrado por TTL | No | Con elección de líder |

> **Trampa de examen.** El *background controller* **no** ejecuta background scans. `generate` y `mutateExisting` son su trabajo. Si dejan de aparecer los reportes de background scan, mirás `kyverno-reports-controller`; si una `NetworkPolicy` generada deja de sincronizarse, mirás `kyverno-background-controller`.

### 2.1 El linaje de las CRD de reportes

Kyverno escribe objetos de reporte intermedios y de vida corta, y luego los agrega. Las CRD intermedias fueron renombradas a lo largo de las versiones — esta es la fuente número uno de "la doc dice X pero mi cluster tiene Y".

| Línea de Kyverno | CRD intermedias (vida corta) | CRD agregadas, de cara al usuario |
|---|---|---|
| 1.8 – 1.9 | `reportchangerequests.kyverno.io`, `clusterreportchangerequests.kyverno.io` | `policyreports` / `clusterpolicyreports` (`wgpolicyk8s.io/v1alpha2`) |
| 1.10 | `admissionreports.kyverno.io/v1alpha2`, `backgroundscanreports.kyverno.io/v1alpha2` (+ variantes `cluster*`) | igual |
| 1.11+ | consolidadas en `ephemeralreports.reports.kyverno.io/v1` y `clusterephemeralreports.reports.kyverno.io/v1` | igual |

La API **agregada** es estable y es sobre la que construís:

* `PolicyReport` — con namespace (`polr`)
* `ClusterPolicyReport` — de alcance de cluster (`cpolr`)
* Group/version: `wgpolicyk8s.io/v1alpha2`, propiedad del **Policy WG** de Kubernetes, *no* de Kyverno. Trivy-operator, Falco sidekick, exporters de kube-bench y otros escriben la misma forma. Por eso vale la pena aprender la API de reportes independientemente de Kyverno.

Desde 1.10 el modelo de agregación es **un reporte por recurso escaneado**, nombrado según el `uid` del recurso y con un `ownerReference` hacia él, de modo que Kubernetes recolecta los reportes cuando el recurso muere. Las versiones más viejas producían un reporte por namespace (`polr-ns-<namespace>`), por eso los runbooks antiguos te dicen que hagas `kubectl get polr polr-ns-default` y el tuyo no existe.

---

## 3. `spec.background`: el interruptor, y el contexto que te cuesta

Cada `Policy` y `ClusterPolicy` lleva un booleano:

```yaml
spec:
  background: true    # default
```

* `background: true` (por defecto) — la policy participa en los background scans. Sus reglas `validate` y `verifyImages` se reevalúan contra los recursos vivos en cada intervalo.
* `background: false` — la policy se evalúa **sólo** en admisión. No aporta **nada** a los resultados del background scan.

### 3.1 Por qué alguna vez lo pondrías en `false`

Un background scan no tiene `AdmissionRequest`. No hay usuario, ni grupo, ni service account, ni cadena de impersonación, ni flag `dryRun` — el reports controller simplemente leyó un objeto de etcd. Kyverno, entonces, sintetiza un contexto de policy mínimo, y un conjunto bien definido de variables queda no disponible.

| Variable | Disponible en admisión | Disponible en background scan | Notas |
|---|---|---|---|
| `request.object` | ✅ | ✅ | El objeto vivo tal como lo devuelve el API server |
| `request.oldObject` | ✅ (en UPDATE) | ❌ (siempre vacío) | En un scan no existe un estado "anterior" |
| `request.userInfo.username` | ✅ | ❌ | No existe un solicitante |
| `request.userInfo.groups` | ✅ | ❌ | |
| `request.roles` / `request.clusterRoles` | ✅ | ❌ | |
| `serviceAccountName` / `serviceAccountNamespace` | ✅ | ❌ | Derivadas de `userInfo` |
| `request.operation` | ✅ (`CREATE`/`UPDATE`/`DELETE`) | ⚠️ sintético | Tratá su valor como un detalle de implementación; las versiones recientes reportan `BACKGROUND`. No ramifiques sobre él en una policy habilitada para background. |
| `images` (del contexto de `verifyImages`) | ✅ | ✅ | Se vuelve a resolver contra el registro |
| `{{ configMap.… }}`, `{{ apiCall }}`, `{{ globalReference }}` | ✅ | ✅ | Se releen en cada scan — esto es lo que hace detectable la deriva de contexto |

Kyverno **lo impone estáticamente**. Su propio webhook de validación de policies rechaza una policy que combine `background: true` con una variable prohibida:

```console
$ kubectl apply -f restrict-privileged-to-platform-team.yaml
Error from server: error when creating "restrict-privileged-to-platform-team.yaml": \
admission webhook "validate-policy.kyverno.svc" denied the request: \
spec.rules[0].validate.deny.conditions: variable {{request.userInfo.groups}} is not allowed \
in background mode. Set spec.background=false to disable background mode for this policy rule.
```

### 3.2 La consecuencia de diseño

Cualquier policy cuya decisión dependa de **quién** hizo algo es intrínsecamente no escaneable, porque la identidad no es una propiedad del objeto almacenado. En producción esto parte tu catálogo de policies en dos:

| Familia de policy | Entrada de la decisión | `background` | Cobertura detectiva |
|---|---|---|---|
| **Policies de postura** — "los Pods no deben correr como root", "las imágenes deben venir de `registry.internal`", "los PVC deben fijar una storageClass" | El objeto en sí | `true` | Completa |
| **Policies de autorización** — "sólo `system:serviceaccount:platform:deployer` puede fijar `hostNetwork`", "sólo los miembros de `sre` pueden borrar un `PersistentVolume`" | El solicitante | `false` | **Ninguna** — compensá con los audit logs del API server |

> **Guía arquitectónica.** Preferí postura sobre autorización donde ambas puedan expresar la misma regla. `background: false` es un agujero permanente e invisible en tu reporte de cumplimiento. Si tenés que escribir una regla basada en identidad, emparejala con una regla de postura habilitada para background que capture el estado resultante, y alertá sobre el audit log para la dimensión de identidad.

### 3.3 Qué tipos de regla producen resultados de background scan

| Tipo de regla | Se evalúa en background scan | Produce resultados en reportes | Gestionada por |
|---|---|---|---|
| `validate` (pattern / deny / cel / foreach) | ✅ | ✅ `pass` / `fail` / `warn` / `skip` / `error` | reports-controller |
| `verifyImages` | ✅ (vuelve a resolver digests, revalida firmas/attestations) | ✅ | reports-controller |
| `mutate` (plano, en tiempo de admisión) | ❌ | ❌ | sólo el admission-controller |
| `mutate` con `targets` (mutateExisting) | ❌ — se reconcilia, no se escanea | ❌ | background-controller vía `UpdateRequest` |
| `generate` | ❌ — se reconcilia, no se escanea | ❌ | background-controller vía `UpdateRequest` |

Por esto un cluster lleno de policies `generate` muestra una lista `polr` vacía y no hay nada roto.

### 3.4 Semántica de los resultados

| `result` | Significado | Causa habitual |
|---|---|---|
| `pass` | Regla evaluada, recurso conforme | — |
| `fail` | Regla evaluada, el recurso la viola | El hallazgo que te importa. `Enforce` y `Audit` producen ambos `fail` en un scan — un scan **nunca bloquea** |
| `warn` | Resultado sin puntuar (`scored: false`) | Policies consultivas; los resultados quedan fuera del score pass/fail |
| `skip` | La regla no aplicó | `preconditions` falsas, `exclude` coincidió, o coincidió una `PolicyException` |
| `error` | La regla no pudo evaluarse | Denegación de RBAC, `apiCall` inalcanzable, timeout del registro, variable mal formada, CRD no servida |

`error` es el que destruye silenciosamente un programa de cumplimiento: una regla no evaluada parece "sin fallos" en un dashboard ingenuo. **Alertá sobre `error`, no sólo sobre `fail`.**

---

## 4. Trade-offs y superficie de ajuste

### 4.1 Reportes en tiempo de admisión vs background scans

Ambos alimentan el mismo `PolicyReport`. Se pueden habilitar de forma independiente.

| Dimensión | Reportes de admisión (`--admissionReports`) | Background scans (`--backgroundScan`) |
|---|---|---|
| Disparador | Cada `AdmissionRequest` que coincida | Temporizador (`--backgroundScanInterval`) + cambio de policy |
| Frescura | Sub-segundo | Hasta un intervalo de retraso |
| Cubre recursos preexistentes | ❌ | ✅ |
| Detecta deriva de contexto (ConfigMap/apiCall/registro) | ❌ | ✅ |
| Sobrevive a una ventana de caída de Kyverno | ❌ | ✅ (se sana en el siguiente scan) |
| Carga sobre el API server | Proporcional a la tasa de cambio | Proporcional a `recursos × policies` por intervalo |
| Churn de objetos en etcd | Alto en clusters ocupados (un reporte efímero por admisión) | Acotado, periódico |
| Policies conscientes de la identidad (`background: false`) | ✅ | ❌ |
| Puede bloquear | ✅ (`Enforce`) | ❌ nunca |

**Recomendación de producción para clusters grandes:** mantené `backgroundScan=true`, y considerá `admissionReports=false` si tu tasa de cambio es alta y sólo necesitás postura periódica. Conservás el enforcement (el bloqueo lo hace el admission controller, no los reportes) y te sacás de encima la amplificación de escrituras en etcd por admisión.

### 4.2 Flags del reports-controller

Se fijan con `--flag=value` en el contenedor `kyverno-reports-controller`, o a través de Helm.

| Flag | Por defecto | Efecto | Cuándo cambiarlo |
|---|---|---|---|
| `--backgroundScan` | `true` | Interruptor maestro del escaneo en background | `false` para correr Kyverno puramente como puerta de admisión |
| `--backgroundScanInterval` | `1h` | Período de barrido completo | Alargarlo (`4h`, `24h`) en clusters con >20k objetos escaneados; acortarlo sólo con margen medido |
| `--backgroundScanWorkers` | `2` | Concurrencia de la cola de trabajo del scan | Subirlo para acortar el wall-clock del barrido; sube la QPS al API server y la CPU del controlador |
| `--skipResourceFilters` | `true` | **`true` = los `resourceFilters` del ConfigMap son IGNORADOS por el scan** | Poner `false` para que los background scans respeten las mismas exclusiones que la admisión |
| `--admissionReports` | `true` | Emitir reportes efímeros desde la admisión | `false` para reducir el churn de etcd |
| `--aggregateReports` | `true` | Agregar efímeros → `PolicyReport` | Dejarlo activo; `false` te deja con los efímeros crudos |
| `--policyReports` | `true` | Emitir reportes para las policies de Kyverno | — |
| `--validatingAdmissionPolicyReports` | `false` (1.11+) | Reportar también los resultados de las `ValidatingAdmissionPolicy` nativas | Habilitar al migrar reglas a CEL/VAP y querer un único panel |
| `--enablePolicyException` | `false` | Respetar los objetos `PolicyException` (→ resultados `skip`) | Habilitar con un `--exceptionNamespace` restringido |
| `--enableConfigMapCaching` | `true` | Cachear las búsquedas de contexto `configMap` | `false` si necesitás que los scans vean los cambios de ConfigMap de inmediato |
| `--maxAPICallResponseLength` | `2000000` | Tope en bytes de la respuesta de `apiCall` | Subirlo para contextos `apiCall` grandes, a costa de memoria |

> **La polaridad de `--skipResourceFilters` es el detalle más pasado por alto de este tema.** El nombre se lee como "saltear estos recursos"; en realidad significa "saltear la *aplicación* de los filtros". Por defecto `true` ⇒ tu exclusión cuidadosamente curada de `kube-system` **no** aplica a los background scans, y tu dashboard de reportes se llena de hallazgos del control plane.

### 4.3 Background scans de Kyverno vs otras herramientas de postura

| Herramienta | Alcance | API de reportes | Enforcement | Encaje |
|---|---|---|---|---|
| **Background scan de Kyverno** | Cualquier recurso de Kubernetes, guiado por las mismas policies que aplican en admisión | PolicyReport de `wgpolicyk8s.io` | Sí, vía la misma policy en admisión | Única fuente de verdad para las policies — un artefacto, dos controles |
| `audit` de Gatekeeper (`auditInterval`) | Cualquier recurso que coincida con un `Constraint` | Estado en el objeto `Constraint` (+ `violations`) | Sí, vía el mismo constraint | Diseño equivalente; las violaciones viven en el status del constraint, así que el reporte por recurso necesita herramientas extra |
| Trivy-operator | Imágenes, cargas de trabajo, RBAC, configuración de infra | Compatible con PolicyReport + CRD propias | No | Orientada a vulnerabilidades, no a policies |
| Polaris | Buenas prácticas de cargas de trabajo | JSON/dashboard propios | Webhook opcional | Chequeos fijos y opinados |
| kube-bench / kube-hunter | Benchmarks CIS de nodos y control plane | JSON propio | No | Nivel host, complementa a Kyverno; Kyverno no puede ver los flags del kubelet |
| Falco | Syscalls en runtime | Eventos | No | Runtime, no estado deseado — ortogonal |
| `ValidatingAdmissionPolicy` nativa | CEL sobre cualquier recurso | Ninguna de forma nativa (Kyverno puede generarlas) | Sí | Sin control detectivo incorporado — exactamente el hueco que llenan los reportes VAP de Kyverno |

---

## 5. Manifiestos completos

### 5.1 Una policy de postura escaneable en background

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-requests-limits
  annotations:
    policies.kyverno.io/title: Require CPU and memory requests and limits
    policies.kyverno.io/category: Resource Management
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Unbounded Pods make the scheduler's fit decisions meaningless and let a single
      workload evict its neighbours. This policy is authored to be background-scannable
      so that the fleet that predates it is inventoried, not merely gated going forward.
spec:
  # Explicit. The default is true, but stating it makes the detective posture
  # of this policy a reviewable property of the manifest.
  background: true
  # Cluster-wide report + block on new/updated objects.
  validationFailureAction: Audit          # 1.13+: prefer spec.rules[].validate.failureAction
  # Evaluate every rule, do not stop at the first match.
  applyRules: All
  rules:
    - name: validate-resources
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
                - kube-node-lease
                - kube-public
                - kyverno
      validate:
        # 1.13+: per-rule action supersedes spec.validationFailureAction
        failureAction: Audit
        # 1.13+: do not block UPDATEs to resources that were already violating.
        # Critical for incremental remediation of findings surfaced by the scan.
        allowExistingViolations: true
        message: >-
          CPU/memory requests and limits are required.
          Pod "{{ request.object.metadata.name }}" is missing at least one of them.
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    cpu: "?*"
                    memory: "?*"
                  limits:
                    memory: "?*"
```

Aplicarla y ver cómo el scan levanta los objetos preexistentes:

```console
$ kubectl apply -f require-resource-requests-limits.yaml
clusterpolicy.kyverno.io/require-resource-requests-limits created

$ kubectl get cpol require-resource-requests-limits \
    -o custom-columns='NAME:.metadata.name,BACKGROUND:.spec.background,ACTION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status'
NAME                               BACKGROUND   ACTION   READY
require-resource-requests-limits   true         Audit    True
```

> Prestá atención al comportamiento de **autogen**: Kyverno sintetiza silenciosamente reglas `autogen-validate-resources` para `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob`, `ReplicaSet` y `ReplicationController`. Los background scans también las evalúan, así que un único Deployment no conforme produce hallazgos *tanto* en el Deployment como en sus Pods. Deduplicá por owner en los dashboards, o restringí el autogen con la anotación `pod-policies.kyverno.io/autogen-controllers`.

### 5.2 Una policy que *no puede* escanearse

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-hostpath-to-platform-team
  annotations:
    policies.kyverno.io/severity: high
spec:
  # MANDATORY: the rule reads request.userInfo, which does not exist in a scan.
  # Kyverno's policy webhook rejects this manifest if background is left at true.
  background: false
  validationFailureAction: Enforce
  rules:
    - name: only-platform-may-mount-hostpath
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          - key: "{{ request.object.spec.volumes[?hostPath != null] | length(@) }}"
            operator: GreaterThan
            value: 0
      validate:
        message: >-
          hostPath volumes may only be created by members of the platform-team group.
          Requester "{{ request.userInfo.username }}" is not authorised.
        deny:
          conditions:
            all:
              - key: "platform-team"
                operator: AnyNotIn
                value: "{{ request.userInfo.groups }}"
```

La policy de postura compensatoria — esta *sí* es escaneable e inventaría todo montaje `hostPath` existente sin importar quién lo creó:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: audit-hostpath-usage
spec:
  background: true
  validationFailureAction: Audit
  rules:
    - name: no-hostpath
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "hostPath volumes are not permitted outside the platform namespaces."
        pattern:
          spec:
            =(volumes):
              - X(hostPath): "null"
```

### 5.3 Ajuste del reports-controller — valores de Helm

```yaml
# values-reports.yaml — Helm chart kyverno/kyverno 3.x
reportsController:
  replicas: 1                       # leader-elected; >1 buys failover, not throughput
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 4Gi                   # informer caches scale with scanned object count
  # Reports controller is the memory hot spot. Do NOT set a CPU limit: throttling
  # during a sweep stretches the scan past the interval and queues compound.
  serviceMonitor:
    enabled: true
    namespace: monitoring
    interval: 30s
  priorityClassName: system-cluster-critical
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule

features:
  admissionReports:
    enabled: true
  aggregateReports:
    enabled: true
  policyReports:
    enabled: true
  validatingAdmissionPolicyReports:
    enabled: false
  backgroundScan:
    enabled: true
    backgroundScanWorkers: 4        # --backgroundScanWorkers
    backgroundScanInterval: 2h      # --backgroundScanInterval
    skipResourceFilters: false      # honour config.resourceFilters during scans
  policyExceptions:
    enabled: true
    namespace: kyverno-exceptions
  configMapCaching:
    enabled: true

config:
  # Excluded from admission AND — because skipResourceFilters is false — from scans.
  resourceFilters:
    - "[Event,*,*]"
    - "[*,kube-system,*]"
    - "[*,kube-public,*]"
    - "[*,kube-node-lease,*]"
    - "[Node,*,*]"
    - "[Node/*,*,*]"
    - "[APIService,*,*]"
    - "[APIService/*,*,*]"
    - "[TokenReview,*,*]"
    - "[SubjectAccessReview,*,*]"
    - "[SelfSubjectAccessReview,*,*]"
    - "[Binding,*,*]"
    - "[Pod/binding,*,*]"
    - "[ReplicaSet,*,*]"
    - "[ReplicaSet/*,*,*]"
    - "[EphemeralReport,*,*]"
    - "[ClusterEphemeralReport,*,*]"
    - "[ClusterRole,*,kyverno:*]"
    - "[ClusterRoleBinding,*,kyverno:*]"
    - "[ServiceAccount,kyverno,kyverno*]"
    - "[ConfigMap,kyverno,kyverno]"
    - "[Deployment,kyverno,kyverno*]"
```

```console
$ helm upgrade --install kyverno kyverno/kyverno \
    --namespace kyverno --create-namespace \
    --version 3.3.4 \
    -f values-reports.yaml
Release "kyverno" has been upgraded. Happy Helming!
NAME: kyverno
NAMESPACE: kyverno
STATUS: deployed
REVISION: 7
```

### 5.4 Ajuste sin Helm — un patch estratégico

```yaml
# reports-controller-args.patch.yaml
spec:
  template:
    spec:
      containers:
        - name: controller
          args:
            - --caSecretName=kyverno-svc.kyverno.svc.kyverno-tls-ca
            - --tlsSecretName=kyverno-svc.kyverno.svc.kyverno-tls-pair
            - --backgroundScan=true
            - --backgroundScanInterval=2h
            - --backgroundScanWorkers=4
            - --skipResourceFilters=false
            - --admissionReports=false
            - --aggregateReports=true
            - --policyReports=true
            - --enablePolicyException=true
            - --exceptionNamespace=kyverno-exceptions
            - --enableConfigMapCaching=true
            - --loggingFormat=json
            - --v=2
```

```console
$ kubectl -n kyverno patch deploy kyverno-reports-controller \
    --type strategic --patch-file reports-controller-args.patch.yaml
deployment.apps/kyverno-reports-controller patched

$ kubectl -n kyverno rollout status deploy/kyverno-reports-controller
Waiting for deployment "kyverno-reports-controller" rollout to finish: 1 old replicas are pending termination...
deployment "kyverno-reports-controller" successfully rolled out
```

### 5.5 RBAC para escanear custom resources

El reports controller sólo puede escanear aquello sobre lo que puede hacer `list` y `watch`. Kyverno trae un `ClusterRole` agregado; lo extendés con una etiqueta, nunca editando los roles propios de Kyverno (Helm los va a sobrescribir).

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:reports-controller:platform-crds
  labels:
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
rules:
  - apiGroups: ["acid.zalan.do"]
    resources: ["postgresqls"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates", "issuers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways", "httproutes"]
    verbs: ["get", "list", "watch"]
```

Las etiquetas de agregación, una por controlador — confundirlas es un clásico incidente autoinfligido:

| Etiqueta | Otorga a |
|---|---|
| `rbac.kyverno.io/aggregate-to-admission-controller: "true"` | admission controller |
| `rbac.kyverno.io/aggregate-to-background-controller: "true"` | background controller (`generate`/`mutateExisting` — necesita verbos de **escritura**) |
| `rbac.kyverno.io/aggregate-to-reports-controller: "true"` | reports controller (alcanza con **sólo lectura**) |
| `rbac.kyverno.io/aggregate-to-cleanup-controller: "true"` | cleanup controller (necesita `delete`) |

### 5.6 Una `PolicyException` y su efecto sobre los resultados del scan

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: legacy-cache-hostpath-waiver
  namespace: kyverno-exceptions
  annotations:
    waiver.internal/ticket: SEC-4471
    waiver.internal/expires: "2026-12-31"
spec:
  exceptions:
    - policyName: audit-hostpath-usage
      ruleNames:
        - no-hostpath
        - autogen-no-hostpath
  match:
    any:
      - resources:
          kinds:
            - Pod
            - StatefulSet
          namespaces:
            - legacy
          names:
            - "legacy-cache*"
```

Efecto: en el próximo scan, esos recursos pasan de `fail` a **`skip`** en el reporte — visible, atribuible y contable, que es exactamente la propiedad que pide un auditor. Estrechar silenciosamente el bloque `match` de la policy haría desaparecer el mismo hallazgo sin dejar rastro.

### 5.7 Un `PolicyReport` agregado tal como lo produce un scan

```yaml
apiVersion: wgpolicyk8s.io/v1alpha2
kind: PolicyReport
metadata:
  name: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
  namespace: prod
  labels:
    app.kubernetes.io/managed-by: kyverno
  ownerReferences:
    - apiVersion: v1
      kind: Pod
      name: legacy-cache-0
      uid: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
scope:
  apiVersion: v1
  kind: Pod
  name: legacy-cache-0
  namespace: prod
  uid: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
summary:
  pass: 3
  fail: 1
  warn: 0
  error: 0
  skip: 1
results:
  - source: kyverno
    policy: require-resource-requests-limits
    rule: validate-resources
    category: Resource Management
    severity: medium
    result: fail
    scored: true
    message: >-
      CPU/memory requests and limits are required. Pod "legacy-cache-0" is missing
      at least one of them. rule validate-resources failed at path /spec/containers/0/resources/limits/
    timestamp:
      seconds: 1786594800
      nanos: 0
    resources:
      - apiVersion: v1
        kind: Pod
        name: legacy-cache-0
        namespace: prod
        uid: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
  - source: kyverno
    policy: audit-hostpath-usage
    rule: no-hostpath
    result: skip
    scored: true
    message: rule skipped due to policy exception legacy-cache-hostpath-waiver
    timestamp:
      seconds: 1786594800
      nanos: 0
    resources:
      - apiVersion: v1
        kind: Pod
        name: legacy-cache-0
        namespace: prod
        uid: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
```

---

## 6. Recorrido por la CLI con salida real

### 6.1 Confirmar que el escáner está corriendo y cómo está configurado

```console
$ kubectl -n kyverno get deploy
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    3/3     3            3           41d
kyverno-background-controller   1/1     1            1           41d
kyverno-cleanup-controller      1/1     1            1           41d
kyverno-reports-controller      1/1     1            1           41d

$ kubectl -n kyverno get deploy kyverno-reports-controller \
    -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}'
--caSecretName=kyverno-svc.kyverno.svc.kyverno-tls-ca
--tlsSecretName=kyverno-svc.kyverno.svc.kyverno-tls-pair
--backgroundScan=true
--backgroundScanInterval=2h
--backgroundScanWorkers=4
--skipResourceFilters=false
--admissionReports=false
--aggregateReports=true
--policyReports=true
--enablePolicyException=true
--exceptionNamespace=kyverno-exceptions
--loggingFormat=json
--v=2
```

### 6.2 Inventariar qué policies son realmente escaneables

```console
$ kubectl get cpol -o custom-columns=\
'NAME:.metadata.name,BACKGROUND:.spec.background,ACTION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status'
NAME                                 BACKGROUND   ACTION    READY
audit-hostpath-usage                 true         Audit     True
disallow-latest-tag                  true         Audit     True
require-resource-requests-limits     true         Audit     True
require-run-as-nonroot               true         Enforce   True
restrict-hostpath-to-platform-team   false        Enforce   True
verify-internal-image-signatures     true         Enforce   True

$ # The compliance hole, in one line:
$ kubectl get cpol,pol -A -o json \
    | jq -r '.items[] | select(.spec.background == false) | "\(.kind)/\(.metadata.name)"'
ClusterPolicy/restrict-hostpath-to-platform-team
```

### 6.3 Leer los reportes

```console
$ kubectl get polr -A
NAMESPACE   NAME                                   KIND          NAME              PASS   FAIL   WARN   ERROR   SKIP   AGE
legacy      3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa   Pod           legacy-cache-0    3      1      0      0       1      12m
legacy      7b1d0e55-2af9-41c0-8f22-1a9c3ee0b7d1   StatefulSet   legacy-cache      3      1      0      0       1      12m
prod        9c44a012-77b5-4a10-b0e1-5d2f8a6c9e34   Deployment    checkout-api      6      0      0      0       0      12m
prod        c0de1f88-1122-4b33-9911-77aa55bb33cc   Pod           batch-loader-9x2   4      2      0      1       0      12m

$ kubectl get cpolr
NAME                                   KIND               NAME              PASS   FAIL   WARN   ERROR   SKIP   AGE
1c9b77aa-4402-4b6a-8a10-3d5e9f0a1122   ClusterRoleBinding cluster-admin-ci   0      1      0      0       0     12m
```

Agregar la postura de toda la flota — la consulta que realmente ponés en un dashboard:

```console
$ kubectl get polr -A -o json \
  | jq -r '[.items[].results[]? | select(.result=="fail")] | group_by(.policy)
           | map({policy: .[0].policy, failures: length}) | sort_by(-.failures) | .[]
           | "\(.failures)\t\(.policy)"'
41	require-resource-requests-limits
18	disallow-latest-tag
7	require-run-as-nonroot
2	audit-hostpath-usage

$ # Errors — the results that look like "no finding" but are actually "no evaluation"
$ kubectl get polr,cpolr -A -o json \
  | jq -r '.items[].results[]? | select(.result=="error")
           | "\(.policy)/\(.rule)\t\(.message)"' | sort -u
verify-internal-image-signatures/check-signature	failed to fetch image descriptor: GET https://registry.internal/v2/: dial tcp 10.42.9.7:443: i/o timeout
```

### 6.4 Forzar un re-escaneo inmediato

No existe `kubectl kyverno rescan`. Hay tres formas soportadas de hacer que el reports controller reevalúe sin esperar al intervalo:

```console
$ # 1. Touch the policy — a spec change bumps resourceVersion and invalidates cached verdicts.
$ kubectl annotate cpol require-resource-requests-limits rescan="$(date +%s)" --overwrite
clusterpolicy.kyverno.io/require-resource-requests-limits annotated

$ # 2. Delete the aggregated reports; the controller rebuilds them.
$ kubectl delete polr --all -A
policyreport.wgpolicyk8s.io "3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa" deleted
policyreport.wgpolicyk8s.io "7b1d0e55-2af9-41c0-8f22-1a9c3ee0b7d1" deleted
policyreport.wgpolicyk8s.io "9c44a012-77b5-4a10-b0e1-5d2f8a6c9e34" deleted
policyreport.wgpolicyk8s.io "c0de1f88-1122-4b33-9911-77aa55bb33cc" deleted

$ # 3. Restart the controller (blunt; drops in-flight work and rewarms informers).
$ kubectl -n kyverno rollout restart deploy/kyverno-reports-controller
deployment.apps/kyverno-reports-controller restarted
```

### 6.5 El equivalente en CLI — escaneo en background offline y en CI

`kyverno apply --cluster` ejecuta la misma evaluación del motor contra el estado vivo del cluster, desde tu workstation o un runner de CI, sin tocar el reports controller. Así validás el *radio de impacto* de una policy antes de mergearla.

```console
$ kyverno version
Version: 1.13.4
Time: 2025-03-11T09:41:22Z

$ kyverno apply ./policies/ --cluster --namespace prod --policy-report

Applying 9 policy rule(s) to 214 resource(s)...

----------------------------------------------------------------------
POLICY REPORT:
----------------------------------------------------------------------
apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: clusterpolicyreport
results:
- message: 'validation error: CPU/memory requests and limits are required. rule validate-resources
    failed at path /spec/containers/0/resources/limits/'
  policy: require-resource-requests-limits
  resources:
  - apiVersion: v1
    kind: Pod
    name: batch-loader-9x2
    namespace: prod
    uid: c0de1f88-1122-4b33-9911-77aa55bb33cc
  result: fail
  rule: validate-resources
  scored: true
  source: kyverno
  timestamp:
    nanos: 0
    seconds: 1786594800
- message: validation rule 'validate-resources' passed.
  policy: require-resource-requests-limits
  resources:
  - apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
    namespace: prod
    uid: 9c44a012-77b5-4a10-b0e1-5d2f8a6c9e34
  result: pass
  rule: autogen-validate-resources
  scored: true
  source: kyverno
  timestamp:
    nanos: 0
    seconds: 1786594800
summary:
  error: 0
  fail: 2
  pass: 205
  skip: 7
  warn: 0
```

Una puerta pre-merge que hace fallar el pipeline si una policy candidata marcaría algo que ya está corriendo:

```console
$ kyverno apply ./candidate-policy.yaml --cluster --policy-report -o out.yaml
$ yq '.summary.fail' out.yaml
41
$ test "$(yq '.summary.fail' out.yaml)" -eq 0 || {
    echo "candidate policy would flag 41 live resources; ship it as Audit first"; exit 1; }
candidate policy would flag 41 live resources; ship it as Audit first
```

> Este es el flujo de promoción estándar: **escribir → `Audit` + background scan → medir el conteo de fallos → remediar hasta cero → pasar a `Enforce`**. Ir directo a `Enforce` en un cluster que no escaneaste es la forma de descubrir a las 03:00 que un `StatefulSet` no puede reprogramarse.

### 6.6 Métricas

```console
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
$ curl -s localhost:8000/metrics | grep -m2 '^kyverno_policy_results_total'
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-resource-requests-limits",policy_namespace="",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_namespace="prod",resource_request_operation="",rule_execution_cause="background_scan",rule_name="validate-resources",rule_result="fail",rule_type="validate"} 41
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-resource-requests-limits",policy_namespace="",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_namespace="prod",resource_request_operation="CREATE",rule_execution_cause="admission_request",rule_name="validate-resources",rule_result="pass",rule_type="validate"} 1183
```

La etiqueta que importa es **`rule_execution_cause`**: `background_scan` vs `admission_request`. Es lo que te permite demostrar, en un gráfico, que el control detectivo está vivo.

```yaml
# PrometheusRule — three alerts that cover the real failure modes
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-background-scan
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: kyverno-background-scan
      rules:
        - alert: KyvernoBackgroundScanStalled
          # No background-scan result has been recorded in 3x the scan interval.
          expr: |
            sum(increase(kyverno_policy_results_total{rule_execution_cause="background_scan"}[6h])) == 0
          for: 30m
          labels:
            severity: critical
          annotations:
            summary: Kyverno background scans have produced no results in 6h
            description: >-
              The detective control is dark. Pre-existing and drifted resources are not
              being evaluated. Check kyverno-reports-controller logs and RBAC.

        - alert: KyvernoPolicyEvaluationErrors
          # `error` results are unevaluated rules masquerading as clean.
          expr: |
            sum by (policy_name) (
              increase(kyverno_policy_results_total{rule_result="error"}[15m])
            ) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: 'Kyverno policy {{ $labels.policy_name }} is erroring, not evaluating'

        - alert: KyvernoReportsControllerRestarting
          expr: |
            increase(kube_pod_container_status_restarts_total{
              namespace="kyverno", container="controller",
              pod=~"kyverno-reports-controller-.*"}[30m]) > 2
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: reports-controller is crash-looping (commonly OOMKilled during a sweep)
```

---

## 7. Operar background scans a escala

### 7.1 El modelo de costo

El trabajo por barrido ≈ `Σ sobre policies ( recursos coincidentes × reglas )`, más un `LIST` a la API por cada `GroupVersionKind` escaneado por resync del informer, más una escritura de reporte por cada recurso cuyo veredicto cambió.

| Presión | Dónde impacta | Síntoma | Palanca |
|---|---|---|---|
| Cachés de informer para cada kind escaneado | **memoria** del reports-controller | `OOMKilled`, crash-loop durante el barrido | Subir el límite de memoria; acotar los bloques `match`; `skipResourceFilters=false`; excluir kinds de alta cardinalidad (`Event`, `ReplicaSet`, `EndpointSlice`) |
| Evaluación de reglas | **CPU** del reports-controller | El barrido no termina antes del siguiente tick; las colas se acumulan | Subir `backgroundScanWorkers`; alargar `backgroundScanInterval`; **nunca** fijar un límite de CPU que estrangule el barrido |
| Objetos de reporte | tamaño de **etcd**, fan-out de watches del apiserver | Crecimiento de la DB de etcd, `LIST` lento sobre `polr` | Reducir la cantidad de recursos coincidentes; `admissionReports=false`; mantener `aggregateReports=true` |
| Búsquedas `apiCall` / de registro en el contexto de la policy | Dependencia externa | Resultados `error`, timeouts | `enableConfigMapCaching`; usar `GlobalContextEntry` (1.11+) en vez de un `apiCall` por evaluación |
| Duplicación por autogen | Todo lo anterior ×2 | Hallazgos duplicados por carga de trabajo | `pod-policies.kyverno.io/autogen-controllers: none` donde alcance la cobertura a nivel de Pod |

### 7.2 Regla práctica de dimensionamiento

* < 5.000 objetos escaneados: los valores por defecto (`1h`, 2 workers, 512Mi) están bien.
* 5.000 – 50.000: `backgroundScanInterval: 2h`, `backgroundScanWorkers: 4–8`, límite de memoria 2–4Gi, `skipResourceFilters: false`.
* \> 50.000: acotá las policies con `namespaceSelector`, considerá `admissionReports: false`, `backgroundScanInterval: 6h–24h`, límite de memoria ≥ 8Gi, y medí la duración del barrido antes de tocar la cantidad de workers.

**Medí siempre la duración del barrido antes de acortar el intervalo.** Si un barrido tarda más que el intervalo, construiste una cola que nunca se drena y el controlador terminará quedándose sin memoria.

### 7.3 Consumir los reportes

Los objetos `PolicyReport` crudos son una API, no un producto. En producción, poné un consumidor delante de ellos:

* **Policy Reporter** (`kyverno/policy-reporter`) — UI, métricas de Prometheus por policy/namespace/severidad, y destinos para Slack, Elasticsearch, Loki, S3, Teams y webhooks. Es el consumidor de referencia y habla la API `wgpolicyk8s.io`, así que también ingiere reportes de Trivy-operator.
* **kube-state-metrics custom resource state** — si ya corrés KSM y querés los resúmenes de los reportes como métricas de primera clase sin otro deployment:

```yaml
# kube-state-metrics CustomResourceStateMetrics config
kind: CustomResourceStateMetrics
spec:
  resources:
    - groupVersionKind:
        group: wgpolicyk8s.io
        version: v1alpha2
        kind: PolicyReport
      metricNamePrefix: policyreport
      labelsFromPath:
        namespace: [metadata, namespace]
        scope_kind: [scope, kind]
        scope_name: [scope, name]
      metrics:
        - name: summary_fail
          help: "Failing results in this PolicyReport"
          each:
            type: Gauge
            gauge:
              path: [summary, fail]
        - name: summary_error
          help: "Errored results in this PolicyReport"
          each:
            type: Gauge
            gauge:
              path: [summary, error]
```

---

## 8. Verificación y diagnóstico de fallos

### 8.1 Triage ordenado: "los reportes están vacíos"

```console
$ # 1 — Is the scanner even deployed and healthy?
$ kubectl -n kyverno get pods -l app.kubernetes.io/component=reports-controller
NAME                                          READY   STATUS    RESTARTS   AGE
kyverno-reports-controller-6d9c7f4b58-p2xkq   1/1     Running   0          14m

$ # 2 — Is background scanning switched on?
$ kubectl -n kyverno get deploy kyverno-reports-controller \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'backgroundScan|policyReports|aggregate'
"--backgroundScan=true"
"--backgroundScanInterval=2h"
"--backgroundScanWorkers=4"
"--aggregateReports=true"
"--policyReports=true"

$ # 3 — Does the policy opt in to background mode?
$ kubectl get cpol my-policy -o jsonpath='{.spec.background}{"\n"}'
false                                   # <-- root cause in a large fraction of cases

$ # 4 — Is the policy Ready?
$ kubectl describe cpol my-policy | sed -n '/Status/,$p'
Status:
  Conditions:
    Message:  Ready
    Reason:   Succeeded
    Status:   True
    Type:     Ready
  Rule Count:
    Generate:   0
    Mutate:     0
    Validate:   1
    Verify images: 0

$ # 5 — Is anything being excluded before it reaches the engine?
$ kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n' | head
[Event,*,*]
[*,kube-system,*]
[*,kube-public,*]
[*,kube-node-lease,*]
[Node,*,*]

$ # 6 — What is the controller actually saying?
$ kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=50 | grep -iE 'error|forbidden|skip'
```

### 8.2 Síntoma → causa → solución

| Síntoma | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|
| `kubectl get polr -A` no devuelve absolutamente nada | `--backgroundScan=false` o `--policyReports=false` | Inspeccionar los args del controlador | Reactivarlos; `features.backgroundScan.enabled=true` |
| Algunas policies reportan, una nunca lo hace | Esa policy tiene `background: false` | `kubectl get cpol -o custom-columns=...BACKGROUND...` | Quitar la variable dependiente de identidad, o aceptar el hueco y agregar una policy de postura compensatoria |
| La policy es rechazada en `kubectl apply` | `background: true` + `request.userInfo` / `serviceAccountName` / `request.roles` | Leer literalmente el mensaje de denegación del webhook | Poner `background: false` (§5.2) |
| Reportes llenos de `result: error`, mensaje `... is forbidden: User "system:serviceaccount:kyverno:kyverno-reports-controller" cannot list resource ...` | Falta RBAC para una CRD | `kubectl auth can-i list <resource> --as=system:serviceaccount:kyverno:kyverno-reports-controller` | `ClusterRole` agregado con `rbac.kyverno.io/aggregate-to-reports-controller: "true"` (§5.5) |
| Hallazgos de `kube-system` a pesar de los `resourceFilters` | `--skipResourceFilters=true` (por defecto) | Revisar el flag | `--skipResourceFilters=false` |
| Los resultados quedan viejos después de editar la policy | Veredicto cacheado indexado por el `resourceVersion` de la policy, todavía no re-encolado | Comparar el `timestamp` del reporte con el cambio de `metadata.resourceVersion` de la policy | Anotar la policy para bumpear el `resourceVersion`, o borrar los reportes (§6.4) |
| Hallazgos duplicados por carga de trabajo | Las reglas de autogen reportan tanto sobre el controlador como sobre el Pod | Buscar nombres de `rule` con prefijo `autogen-` en los resultados | Deduplicar por `ownerReference` aguas abajo, o fijar `pod-policies.kyverno.io/autogen-controllers` |
| Una policy en `Enforce` muestra `fail` para un recurso vivo, pero no se bloqueó nada | El background scan **nunca** bloquea; el recurso es anterior a la policy | Comportamiento esperado | Remediar el recurso; `Enforce` sólo protege escrituras futuras |
| No se puede actualizar un recurso en violación para arreglar un campo no relacionado | `Enforce` + `allowExistingViolations: false` | Denegación de admisión en UPDATE | `allowExistingViolations: true` (1.13+), o pasar temporalmente a `Audit` |
| reports-controller `OOMKilled` en cada intervalo | Cachés de informer para kinds de alta cardinalidad | `kubectl -n kyverno describe pod ...` → `Last State: Terminated, Reason: OOMKilled` | Subir el límite de memoria; `skipResourceFilters=false`; excluir `Event`/`ReplicaSet`; alargar el intervalo |
| El barrido nunca completa; la profundidad de la cola crece | Intervalo más corto que la duración del barrido, o throttling de CPU | Correlacionar la tasa de `rule_execution_cause="background_scan"` con el intervalo; revisar `container_cpu_cfs_throttled_seconds_total` | Alargar el intervalo, subir los workers, quitar el límite de CPU |
| Los hallazgos desaparecieron sin registro de exención | Alguien estrechó el `match`/`exclude` de la policy | `kubectl get cpol <name> -o yaml \| diff` contra Git | Usar una `PolicyException` en su lugar — produce resultados `skip` auditables (§5.6) |
| `verifyImages` reporta `error` de forma intermitente | Rate-limit del registro o timeout de red durante el scan | El mensaje de error contiene el host del registro | Caché pull-through del registro, `imagePullSecrets` para el reports controller, alargar el intervalo |

### 8.3 Laboratorio de verificación de punta a punta

```console
$ # A. Create a violating resource BEFORE the policy exists.
$ kubectl create ns bgscan-demo
namespace/bgscan-demo created

$ kubectl -n bgscan-demo run legacy --image=nginx:latest --restart=Never
pod/legacy created

$ # B. Now install a background-enabled Audit policy.
$ kubectl apply -f require-resource-requests-limits.yaml
clusterpolicy.kyverno.io/require-resource-requests-limits created

$ # C. Admission never saw this Pod. Prove the scan does.
$ kubectl get polr -n bgscan-demo
No resources found in bgscan-demo namespace.        # not scanned yet — wait for the tick

$ kubectl annotate cpol require-resource-requests-limits force-rescan="1" --overwrite
clusterpolicy.kyverno.io/require-resource-requests-limits annotated

$ sleep 20 && kubectl get polr -n bgscan-demo
NAME                                   KIND   NAME     PASS   FAIL   WARN   ERROR   SKIP   AGE
5e77b1a0-9f31-4c88-a2d3-6b0c4e91fa22   Pod    legacy   0      1      0      0       0      8s

$ kubectl get polr -n bgscan-demo -o jsonpath='{.items[0].results[0].message}{"\n"}'
CPU/memory requests and limits are required. Pod "legacy" is missing at least one of them.

$ # D. Confirm the finding came from the scan, not from admission.
$ curl -s localhost:8000/metrics \
    | grep 'rule_execution_cause="background_scan"' \
    | grep 'resource_namespace="bgscan-demo"'
kyverno_policy_results_total{...,resource_namespace="bgscan-demo",rule_execution_cause="background_scan",rule_result="fail",rule_type="validate"} 1

$ # E. Prove the report is owned by the resource and is GC'd with it.
$ kubectl delete pod -n bgscan-demo legacy
pod "legacy" deleted
$ kubectl get polr -n bgscan-demo
No resources found in bgscan-demo namespace.

$ kubectl delete ns bgscan-demo
namespace "bgscan-demo" deleted
```

---

## 9. Resumen orientado al examen

| Afirmación | ¿Verdadera? |
|---|---|
| Los background scans pueden bloquear un recurso no conforme | **No.** Sólo reportan. El bloqueo es exclusivo de la admisión. |
| `spec.background` vale `true` por defecto | **Sí.** |
| El `kyverno-background-controller` ejecuta los background scans | **No.** Lo hace el `kyverno-reports-controller`. El background controller maneja `generate` y `mutateExisting`. |
| Las reglas `generate` y `mutate` producen resultados de background scan | **No.** Sólo `validate` y `verifyImages`. |
| Una policy que usa `request.userInfo` puede correr en modo background | **No.** Kyverno rechaza la policy salvo que tenga `background: false`. |
| El intervalo de scan por defecto es 1 hora | **Sí** (`--backgroundScanInterval=1h`). |
| `--skipResourceFilters=true` significa que el scan saltea los recursos filtrados | **No.** Significa que se saltean *los filtros*, así que esos recursos **sí** se escanean. Por defecto es `true`. |
| `PolicyReport` es una API propiedad de Kyverno | **No.** Es `wgpolicyk8s.io/v1alpha2`, del Policy Working Group de Kubernetes. |
| Una `PolicyException` hace desaparecer los hallazgos de los reportes | **No.** Los convierte en `result: skip`, que sigue siendo visible y contable. |
| `Enforce` arregla o borra retroactivamente las violaciones existentes | **No.** Reporta `fail` y bloquea solamente las escrituras futuras. |

**La versión en una sola oración:** los background scans son el control detectivo de Kyverno — el reports controller reevalúa las reglas `validate` y `verifyImages` de cada policy con `background: true` contra el estado vivo del cluster cada `backgroundScanInterval`, escribiendo los veredictos en `PolicyReport`/`ClusterPolicyReport`; nunca bloquean, cuestan memoria en proporción a los recursos que observan, y son el único mecanismo capaz de decirte la verdad sobre los recursos que tu webhook nunca vio.

---

## Referencias

- KCA curriculum (CNCF): <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- CNCF curriculum repository: <https://github.com/cncf/curriculum>
- Kyverno Certified Associate — exam page: <https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/>
- Kyverno documentation (root): <https://kyverno.io/docs/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kyverno — Background processing / `spec.background`: <https://kyverno.io/docs/writing-policies/background/>
- Kyverno — Installation customization and container flags: <https://kyverno.io/docs/installation/customization/>
- Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno — `validate` rules: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Auto-generation rules for Pod controllers: <https://kyverno.io/docs/writing-policies/autogen/>
- Kyverno — Monitoring and metrics: <https://kyverno.io/docs/monitoring/>
- Kyverno — Troubleshooting: <https://kyverno.io/docs/troubleshooting/>
- Kyverno CLI — `apply`: <https://kyverno.io/docs/kyverno-cli/usage/apply/>
- Kyverno policy library: <https://kyverno.io/policies/>
- Kyverno source: <https://github.com/kyverno/kyverno>
- Kyverno Helm chart: <https://github.com/kyverno/kyverno/tree/main/charts/kyverno>
- Kyverno chart on ArtifactHub: <https://artifacthub.io/packages/helm/kyverno/kyverno>
- Policy Reporter (report consumer, UI and metrics): <https://github.com/kyverno/policy-reporter>
- Kubernetes Policy WG — PolicyReport CRD specification: <https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report>
- Kubernetes — Dynamic Admission Control: <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Kubernetes — Validating Admission Policy: <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- Kubernetes — Using RBAC authorization (aggregated ClusterRoles): <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>
- kube-state-metrics — Custom Resource State metrics: <https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/extend/customresourcestate-metrics.md>