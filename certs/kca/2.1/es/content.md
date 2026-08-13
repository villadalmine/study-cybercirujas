# 2.1 — Instalación y configuración basada en Helm (Kyverno)

> Dominio 2 · *Instalación, configuración y actualizaciones* · Peso del objetivo **3.0**
> Lector objetivo: ingeniero de Plataforma/SRE que opera Kyverno como plano de control de admisión a nivel de todo el clúster en producción.

---

## 1. Motivación: por qué Helm, y el problema arquitectónico de producción que resuelve

Kyverno no es una carga de trabajo que dejás caer en un namespace. Es un **plano de control de admisión en banda (in-band)**: registra objetos `ValidatingWebhookConfiguration` y `MutatingWebhookConfiguration` que el kube-apiserver invoca **de forma síncrona en la ruta de escritura de cada petición a la API que coincida**. Eso coloca a Kyverno directamente en la ruta crítica de `kubectl apply`, de los controladores reconciliando, y del scheduler asignando (binding) Pods. Un error de instalación acá no degrada una funcionalidad — puede atascar el clúster entero.

Tres propiedades acopladas hacen frágil una instalación artesanal con `kubectl apply`, y son exactamente lo que el chart codifica correctamente:

1. **Ciclo de vida de los CRDs.** Kyverno distribuye ~11 CRDs (`ClusterPolicy`, `Policy`, `PolicyException`, `CleanupPolicy`, los CRDs intermedios de reportes, `GlobalContextEntry`, `UpdateRequest`) más los CRDs de reportes de `wgpolicyk8s.io`. Las carpetas nativas `crds/` de Helm se instalan pero **nunca se actualizan** con `helm upgrade` (una limitación documentada de Helm). Kyverno por lo tanto distribuye los CRDs como **templates regulares** en un sub-chart controlado por `crds.install`, de modo que `helm upgrade` efectivamente reconcilia los cambios de esquema de los CRDs entre versiones menores. Una instalación con manifiesto crudo te deja diffear y re-aplicar los CRDs a mano en cada bump.

2. **El deadlock de bootstrap / self-DoS.** Los webhooks de Kyverno pueden coincidir con la creación de Pods. Si esos webhooks también coincidieran con los propios Pods de Kyverno, o con los Pods del plano de control de kube-system, entonces una caída de Kyverno (o una política mala) bloquearía la recreación del propio Kyverno, de la CNI, de CoreDNS — un clúster irrecuperable. El chart distribuye una lista de permitidos **`config.resourceFilters`** que excluye `kube-system`, `kube-public`, `kube-node-lease`, el namespace de Kyverno, los Nodes, los TokenReviews y los objetos de reporte, más un **`webhooks.namespaceSelector`** que excluye el namespace de Kyverno a nivel del apiserver. Estos son enclavamientos de seguridad (safety interlocks), no cosmética.

3. **HA es una topología, no un conteo de réplicas.** Desde la **v1.10** el monolito se dividió en cuatro controladores escalados de forma independiente con distintos modelos de concurrencia (ver §2). "Hacelo HA" significa *escalá el admission controller horizontalmente, pero mantené los controladores de background/reports/cleanup como singletons con leader election, agregá anti-affinity, agregá un PodDisruptionBudget, y ajustá el `failurePolicy`*. Eso es una docena de valores correlacionados — precisamente lo que un `values.yaml` existe para contener bajo control de versiones y GitOps.

**La disyuntiva central que configurás en 2.1** es *fuerza de aplicación (enforcement) vs. disponibilidad del clúster*: `failurePolicy: Fail` te da una garantía de seguridad dura (ninguna escritura sin revisar) al costo de acoplar la disponibilidad de escritura del clúster al uptime de Kyverno; `failurePolicy: Ignore` falla abierto (fail open). Helm es donde hacés esa decisión explícita, revisable y reversible.

---

## 2. Comparaciones técnicas y disyuntivas

### 2.1 Método de instalación

| Método | Actualizaciones de CRDs | Valores por defecto de seguridad de webhooks | Topología HA | Ajuste a GitOps | Cuándo usar |
|---|---|---|---|---|---|
| **Chart de Helm** (`kyverno/kyverno`) | Gestionado vía templates de CRDs + `crds.install` | Distribuye `resourceFilters` + `namespaceSelector` | Valores de primera clase (`admissionController.replicas`, PDB, anti-affinity) | Excelente (`helm template` → Flux/Argo) | **Por defecto para producción** |
| `install.yaml` crudo (`kubectl apply -f`) | Re-aplicación manual en cada versión | Valores por defecto empaquetados, difíciles de sobrescribir | Fijo en el manifiesto | Pobre — deriva por edición en el lugar | Lab rápido / bootstrap air-gapped |
| Kustomize sobre `install.yaml` | Manual | Overlays de parches | Parches de overlay | Bueno | Equipos estandarizados en Kustomize |
| `HelmRelease` de Flux/Argo envolviendo el chart | Igual que Helm | Igual que Helm | Igual que Helm | El mejor | Flota / multi-clúster |

### 2.2 Los cuatro controladores (división post-1.10) — lo que estás instalando en realidad

| Controlador | Deployment | Modelo de escalado | Radio de impacto de la falla | Valor HA |
|---|---|---|---|---|
| **Admission** | `kyverno-admission-controller` | Horizontal, **todas las réplicas activas** detrás de un Service; el apiserver balancea las llamadas al webhook | En la ruta de escritura síncrona — una caída bloquea las escrituras coincidentes si `failurePolicy: Fail` | `replicas: 3` |
| **Background** | `kyverno-background-controller` | **Singleton con leader election** (uno activo) | Mutate/generate sobre recursos *existentes* se detiene; sin impacto en la ruta de escritura | `replicas: 2` (1 en standby) |
| **Reports** | `kyverno-reports-controller` | Singleton con leader election | La generación de `PolicyReport` se estanca; solo observabilidad | `replicas: 2` |
| **Cleanup** | `kyverno-cleanup-controller` | Singleton con leader election; corre un webhook respaldado por CronJob | Las eliminaciones por TTL/`CleanupPolicy` se pausan | `replicas: 2` |

> Punto clave de examen: **solo el admission controller se beneficia de >1 réplica *activa*.** Los otros tres corren 1 activo + N en standby; subir sus `replicas` compra un failover más rápido, no throughput.

### 2.3 `failurePolicy` — la decisión central de producción

| Ajuste | Comportamiento cuando Kyverno es inalcanzable | Postura de seguridad | Postura de disponibilidad | Uso típico |
|---|---|---|---|---|
| `Fail` (por defecto para validating) | Las escrituras a la API que coinciden son **rechazadas** | Fuerte: ningún cambio sin revisar se cuela | Caída de Kyverno ⇒ escrituras bloqueadas en todo el clúster (para recursos coincidentes) | Líneas base de seguridad aplicadas con HA + PDB |
| `Ignore` | Las escrituras que coinciden son **admitidas sin revisar** | Más débil: brecha durante la caída | El clúster sigue aceptando escrituras | Mutation/generation, o mientras se estabiliza el rollout |
| `features.forceFailurePolicyIgnore.enabled: true` | Fuerza **todos** los webhooks gestionados a Ignore sin importar la política | Fail-open global | Máxima disponibilidad | Break-glass / onboarding inicial |

### 2.4 Los dos charts

| Chart | Instala | ¿Contiene políticas? |
|---|---|---|
| `kyverno/kyverno` | El motor: CRDs, RBAC, 4 controladores, ConfigMaps, webhooks dinámicos | **No** — cero políticas por defecto |
| `kyverno/kyverno-policies` | El conjunto de políticas de Pod Security Standards (baseline / restricted) como objetos `ClusterPolicy` | Sí |

Instalar solo `kyverno` no aplica **nada** — Kyverno registra un webhook de recursos solo *después* de que exista una política que coincida. Por eso `kyverno-resource-validating-webhook-cfg` muestra `0` webhooks en una instalación fresca del motor (ver §5).

---

## 3. Manifiestos completos de producción

### 3.1 `values-ha.yaml` — motor endurecido y de alta disponibilidad

```yaml
# values-ha.yaml — Kyverno engine, production HA profile
# Compatible with chart 3.3.x (Kyverno v1.13.x). Pin exact versions in the release.

# ---- CRDs: install AND allow helm upgrade to reconcile schema drift ----
crds:
  install: true
  annotations:
    "helm.sh/resource-policy": keep   # do NOT delete CRDs (and their CRs) on `helm uninstall`

# ---- Cluster-wide engine configuration (rendered into ConfigMap "kyverno") ----
config:
  # Namespaces/kinds Kyverno must NEVER intercept. Appended to the chart's safe defaults.
  # Format: '[Kind,Namespace,Name]', wildcards allowed.
  resourceFiltersExcludeNamespaces:
    - kube-system
    - kube-public
    - kube-node-lease
  resourceFilters:
    - '[Event,*,*]'
    - '[*,kube-system,*]'
    - '[*,kube-public,*]'
    - '[*,kube-node-lease,*]'
    - '[Node,*,*]'
    - '[APIService,*,*]'
    - '[TokenReview,*,*]'
    - '[SubjectAccessReview,*,*]'
    - '[SelfSubjectAccessReview,*,*]'
    - '[*,kyverno,kyverno*]'          # never intercept our own namespace
    - '[*,gatekeeper-system,*]'       # avoid cross-admission-controller loops
    - '[*,flux-system,*]'
  # Exclude the Kyverno namespace at the apiserver webhook level (belt-and-suspenders).
  webhooks:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kyverno, kube-system]
  webhookAnnotations:
    "cert-manager.io/inject-ca-from-secret": "kyverno/kyverno-svc.kyverno.svc.kyverno-tls-ca"
  # Emit events for policy successes too (useful during rollout; noisier).
  generateSuccessEvents: false

# ---- Feature flags ----
features:
  logging:
    format: json
  admissionReports:
    enabled: true
  aggregateReports:
    enabled: true
  policyReports:
    enabled: true
  backgroundScan:
    enabled: true
    backgroundScanInterval: 1h
    backgroundScanWorkers: 2
  # Leave OFF in prod until you have decided the fail-open story deliberately.
  forceFailurePolicyIgnore:
    enabled: false
  # Generate native ValidatingAdmissionPolicy from Kyverno policies where possible (K8s 1.30+).
  generateValidatingAdmissionPolicy:
    enabled: false

# ========================= ADMISSION CONTROLLER (write path) =========================
admissionController:
  replicas: 3                          # active/active behind the Service
  podDisruptionBudget:
    minAvailable: 2                    # survive a node drain without losing quorum
  antiAffinity:
    enabled: true                      # spread the 3 replicas across nodes
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/component: admission-controller
  priorityClassName: system-cluster-critical
  serviceMonitor:
    enabled: true                      # Prometheus Operator scrape of :8000/metrics
  container:
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { memory: 512Mi }      # NO cpu limit — avoid throttling on the write path
  initContainer:
    resources:
      requests: { cpu: 10m, memory: 64Mi }
      limits:   { memory: 128Mi }
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  webhookTimeoutSeconds: 10            # apiserver waits at most this long per call

# ========================= BACKGROUND CONTROLLER (existing resources) =========================
backgroundController:
  enabled: true
  replicas: 2                          # 1 active (leader) + 1 warm standby
  podDisruptionBudget:
    minAvailable: 1
  serviceMonitor:
    enabled: true
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { memory: 256Mi }

# ========================= REPORTS CONTROLLER (PolicyReports) =========================
reportsController:
  enabled: true
  replicas: 2
  podDisruptionBudget:
    minAvailable: 1
  serviceMonitor:
    enabled: true
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { memory: 512Mi }

# ========================= CLEANUP CONTROLLER (TTL / CleanupPolicy) =========================
cleanupController:
  enabled: true
  replicas: 2
  podDisruptionBudget:
    minAvailable: 1
  serviceMonitor:
    enabled: true
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { memory: 128Mi }
```

### 3.2 `values-policies.yaml` — el pack de políticas de Pod Security Standards

```yaml
# values-policies.yaml — kyverno/kyverno-policies chart
# Roll out in Audit first, promote to Enforce per-namespace once report noise is clean.
podSecurityStandard: baseline          # baseline | restricted
podSecuritySeverity: medium
validationFailureAction: Audit         # Audit first; flip to Enforce after triage
# Scope enforcement without touching cluster infra namespaces:
podSecurityPolicies: []                # (chart selects the standard's rule set)
includeRestrictedPolicies: []
customLabels: {}
background: true                       # also scan pre-existing workloads
```

### 3.3 `HelmRelease` de Flux (envoltura GitOps, opcional pero típica de producción)

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kyverno
  namespace: kyverno
spec:
  interval: 30m
  chart:
    spec:
      chart: kyverno
      version: "3.3.4"                 # PIN exactly; never float in prod
      sourceRef:
        kind: HelmRepository
        name: kyverno
        namespace: flux-system
  install:
    crds: CreateReplace
    createNamespace: true
  upgrade:
    crds: CreateReplace                # let Flux reconcile CRD schema on upgrade
  valuesFrom:
    - kind: ConfigMap
      name: kyverno-values-ha
```

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Agregar repo, fijar versión, previsualizar

```console
$ helm repo add kyverno https://kyverno.github.io/kyverno/
"kyverno" has been added to your repositories

$ helm repo update kyverno
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "kyverno" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm search repo kyverno --versions | head -5
NAME                     	CHART VERSION	APP VERSION	DESCRIPTION
kyverno/kyverno          	3.3.4        	v1.13.4    	Kubernetes Native Policy Management
kyverno/kyverno          	3.3.3        	v1.13.3    	Kubernetes Native Policy Management
kyverno/kyverno-policies 	3.3.4        	v1.13.4    	Kubernetes Pod Security Standards ...
kyverno/kyverno-crds     	3.3.4        	v1.13.4    	Kyverno CRDs

# Render locally and diff BEFORE touching the cluster — this is the audit gate.
$ helm template kyverno kyverno/kyverno --version 3.3.4 -n kyverno \
    -f values-ha.yaml | kubectl apply --dry-run=server -f - | tail -6
clusterrole.rbac.authorization.k8s.io/kyverno:admission-controller ... (server dry run)
deployment.apps/kyverno-admission-controller created (server dry run)
deployment.apps/kyverno-background-controller created (server dry run)
deployment.apps/kyverno-reports-controller created (server dry run)
deployment.apps/kyverno-cleanup-controller created (server dry run)
configmap/kyverno created (server dry run)
```

### 4.2 Instalar (motor), esperando la disponibilidad (readiness)

```console
$ helm install kyverno kyverno/kyverno \
    --namespace kyverno --create-namespace \
    --version 3.3.4 \
    -f values-ha.yaml \
    --wait --timeout 5m
NAME: kyverno
LAST DEPLOYED: Thu Aug 13 14:22:07 2026
NAMESPACE: kyverno
STATUS: deployed
REVISION: 1
NOTES:
Chart version: 3.3.4
Kyverno version: v1.13.4
Thank you for installing kyverno! Your release is named kyverno.
...
```

### 4.3 Instalar el pack de políticas (release separada)

```console
$ helm install kyverno-policies kyverno/kyverno-policies \
    --namespace kyverno --version 3.3.4 \
    -f values-policies.yaml --wait
NAME: kyverno-policies
STATUS: deployed
REVISION: 1
```

### 4.4 Inspeccionar la release y los valores efectivos

```console
$ helm list -n kyverno
NAME            	NAMESPACE	REVISION	STATUS  	CHART          	APP VERSION
kyverno         	kyverno  	1       	deployed	kyverno-3.3.4  	v1.13.4
kyverno-policies	kyverno  	1       	deployed	kyverno-policies-3.3.4	v1.13.4

# Only the values that DIFFER from chart defaults — the review artifact:
$ helm get values kyverno -n kyverno
USER-SUPPLIED VALUES:
admissionController:
  antiAffinity:
    enabled: true
  podDisruptionBudget:
    minAvailable: 2
  replicas: 3
...
```

### 4.5 Ruta de actualización (bump del chart = reconcile de CRDs)

```console
$ helm upgrade kyverno kyverno/kyverno -n kyverno \
    --version 3.4.0 -f values-ha.yaml \
    --wait --timeout 5m
Release "kyverno" has been upgraded. Happy Helming!
NAME: kyverno
REVISION: 2
STATUS: deployed

$ helm history kyverno -n kyverno
REVISION	UPDATED                 	STATUS    	CHART        	APP VERSION	DESCRIPTION
1       	Thu Aug 13 14:22:07 2026	superseded	kyverno-3.3.4	v1.13.4    	Install complete
2       	Thu Aug 13 15:01:44 2026	deployed  	kyverno-3.4.0	v1.14.0    	Upgrade complete
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 El chequeo de salud de los cuatro controladores

```console
$ kubectl -n kyverno get pods
NAME                                             READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-7d8f6c9b45-abcde    1/1     Running   0          3m
kyverno-admission-controller-7d8f6c9b45-fghij    1/1     Running   0          3m
kyverno-admission-controller-7d8f6c9b45-klmno    1/1     Running   0          3m
kyverno-background-controller-6c5b4d8f9-pqrst    1/1     Running   0          3m
kyverno-cleanup-controller-5f7c9d6b8-uvwxy       1/1     Running   0          3m
kyverno-reports-controller-8d6f5c7b9-zabcd       1/1     Running   0          3m
```

Esperado: **3 réplicas de admission** Ready, **1+** de cada uno de los otros controladores. Si ves solo un Pod de admission, tu sobrescritura de `admissionController.replicas` no se aplicó — revisá `helm get values`.

### 5.2 CRDs presentes

```console
$ kubectl get crds | grep -E 'kyverno.io|wgpolicyk8s.io'
admissionreports.kyverno.io                      2026-08-13T14:22:05Z
backgroundscanreports.kyverno.io                 2026-08-13T14:22:05Z
cleanuppolicies.kyverno.io                        2026-08-13T14:22:05Z
clusteradmissionreports.kyverno.io               2026-08-13T14:22:05Z
clustercleanuppolicies.kyverno.io                2026-08-13T14:22:05Z
clusterpolicies.kyverno.io                        2026-08-13T14:22:05Z
globalcontextentries.kyverno.io                  2026-08-13T14:22:05Z
policies.kyverno.io                               2026-08-13T14:22:05Z
policyexceptions.kyverno.io                       2026-08-13T14:22:05Z
updaterequests.kyverno.io                         2026-08-13T14:22:05Z
clusterpolicyreports.wgpolicyk8s.io              2026-08-13T14:22:05Z
policyreports.wgpolicyk8s.io                      2026-08-13T14:22:05Z
```

### 5.3 Webhooks dinámicos — el chequeo contraintuitivo

```console
$ kubectl get validatingwebhookconfigurations | grep kyverno
kyverno-policy-validating-webhook-cfg      1     3m
kyverno-resource-validating-webhook-cfg    0     3m     # ← 0 is CORRECT on a fresh engine
kyverno-exception-validating-webhook-cfg   1     3m
kyverno-cleanup-validating-webhook-cfg     1     3m
kyverno-ttl-validating-webhook-cfg         1     3m
```

`kyverno-resource-validating-webhook-cfg` lleva **0 webhooks hasta que exista una política que coincida con recursos reales**. Kyverno reconstruye estas configuraciones dinámicamente a partir de las políticas instaladas para minimizar el overhead del apiserver. Después de instalar `kyverno-policies`, volvé a chequear — el conteo se vuelve distinto de cero:

```console
$ kubectl get clusterpolicies
NAME                             ADMISSION   BACKGROUND   READY   AGE
disallow-capabilities            true        true         True    2m
disallow-host-namespaces         true        true         True    2m
disallow-privileged-containers   true        true         True    2m
...
$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[*].name}'
validate.kyverno.svc-fail  validate.kyverno.svc-ignore
```

### 5.4 Config y TLS

```console
$ kubectl -n kyverno get configmap kyverno -o jsonpath='{.data.resourceFilters}' | head -c 200
[Event,*,*][*,kube-system,*][*,kube-public,*][*,kube-node-lease,*][Node,*,*]...

$ kubectl -n kyverno get secret | grep tls
kyverno-svc.kyverno.svc.kyverno-tls-ca    kubernetes.io/tls   2   4m
kyverno-svc.kyverno.svc.kyverno-tls-pair  kubernetes.io/tls   2   4m
```

Kyverno auto-genera y rota sus certificados de CA/serving del webhook en esos dos Secrets. Si faltan, el apiserver no puede establecer TLS hacia el webhook y toda petición que coincida falla.

### 5.5 Prueba de humo de la ruta de aplicación (enforcement)

```console
$ kubectl run bad --image=nginx --privileged --dry-run=server
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/bad was blocked due to the following policies

disallow-privileged-containers:
  privileged-containers: 'validation error: Privileged mode is disallowed.
    rule privileged-containers failed at path /spec/containers/0/securityContext/privileged/'
```

Un `denied the request` de `validate.kyverno.svc-fail` es prueba de que la cadena completa funciona: apiserver → webhook → motor de políticas → veredicto.

### 5.6 Catálogo de fallas

| Síntoma | Causa raíz probable | Diagnóstico | Solución |
|---|---|---|---|
| `context deadline exceeded` / `failed calling webhook ... i/o timeout` en **todos** los applies | Admission controller caído/sobrecargado, o `webhookTimeoutSeconds` demasiado bajo | `kubectl -n kyverno get pods`; `kubectl -n kyverno logs deploy/kyverno-admission-controller` | Restaurar réplicas; subir el timeout; si es emergencia, `helm upgrade --set features.forceFailurePolicyIgnore.enabled=true` para fallar abierto |
| **No se puede crear NINGÚN Pod, ni siquiera en kube-system** | `resourceFilters` / `namespaceSelector` mal configurados — namespaces del sistema no excluidos | `kubectl get cm kyverno -n kyverno -o yaml` e inspeccionar los filtros | Restaurar los `resourceFilters` por defecto del chart; **break-glass**: `kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg` |
| `helm upgrade` tiene éxito pero los campos de política nuevos son rechazados | CRDs no actualizados (instalados vía `crds/` nativo o `crds.install: false`) | `kubectl get crd clusterpolicies.kyverno.io -o yaml \| grep -A2 versions` | Poner `crds.install: true`; para Flux usar `crds: CreateReplace` |
| Admission controller en `CrashLoopBackOff`, OOMKilled | Límite de memoria demasiado bajo para el volumen de políticas/reportes | `kubectl -n kyverno describe pod` → `Reason: OOMKilled` | Subir `admissionController.container.resources.limits.memory`; quitar los límites de CPU |
| No aparecen objetos `PolicyReport` | Reports controller caído, o `features.policyReports.enabled: false` | `kubectl get polr -A`; revisar los logs de `kyverno-reports-controller` | Habilitar la feature; reiniciar el controlador |
| El throttling de CPU dispara la latencia en la ruta de escritura | Un **límite** de CPU seteado en el contenedor de admission | `kubectl top pod`; revisar `resources.limits.cpu` | Quitar el límite de CPU (solo requests) — estándar para webhooks críticos en latencia |
| Dos background controllers activos haciendo trabajo duplicado | Leader election deshabilitado/roto | `kubectl -n kyverno get lease \| grep kyverno` | Asegurar el RBAC para `coordination.k8s.io/leases`; se espera un solo holder |

### 5.7 Rollback limpio

```console
$ helm rollback kyverno 1 -n kyverno --wait
Rollback was a success! Happy Helming!
```

> Como está seteado `crds.annotations."helm.sh/resource-policy": keep`, `helm uninstall` deja los CRDs (y cualquier CR de `PolicyReport`/política) intactos. Eliminarlos es un segundo paso **deliberado** (`kubectl delete crd -l app.kubernetes.io/part-of=kyverno`), nunca un efecto secundario del uninstall.

---

## 6. Referencias

- Kyverno — Installation (methods, HA, controllers): https://kyverno.io/docs/installation/
- Kyverno — Helm installation: https://kyverno.io/docs/installation/methods/
- Kyverno — High Availability installation: https://kyverno.io/docs/high-availability/
- Kyverno Helm chart (`kyverno/kyverno`) values reference: https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Kyverno charts repository (Artifact Hub): https://artifacthub.io/packages/helm/kyverno/kyverno
- Kyverno — Container Flags & config (ConfigMap, resourceFilters, webhooks): https://kyverno.io/docs/installation/customization/
- Kyverno — Pod Security policy pack (`kyverno-policies`): https://kyverno.io/policies/pod-security/
- Kyverno — Webhook / failurePolicy behavior: https://kyverno.io/docs/installation/customization/#configuring-webhooks
- Kyverno — Controllers overview (admission / background / reports / cleanup): https://kyverno.io/docs/installation/#security-vs-operability
- Helm — CRD management limitation: https://helm.sh/docs/chart_best_practices/custom_resource_definitions/
- Kubernetes — Dynamic Admission Control (`failurePolicy`, `namespaceSelector`, `timeoutSeconds`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- KCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf