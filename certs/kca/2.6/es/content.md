# Actualización de Kyverno

> KCA — Dominio 2 · Tema 2.6 · Peso en el examen 3.0
> Perfil: SRE / Arquitecto de Plataforma — grado de producción

Kyverno no es una carga de trabajo ordinaria. Se ejecuta **dentro de la ruta de admisión del API server de Kubernetes**: cada `CREATE`/`UPDATE`/`DELETE` que coincide con una policy es interceptado por su `MutatingWebhookConfiguration` y `ValidatingWebhookConfiguration` antes de persistirse en etcd. Una actualización, por lo tanto, toca tres cosas a la vez — un conjunto de controllers, un conjunto de CRDs muy grandes, y un conjunto de webhooks a nivel de cluster que pueden bloquear toda la superficie de la API si algo sale mal. Este tema trata sobre hacer esa actualización sin una caída, y diagnosticarla cuando falla.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 Por qué actualizar Kyverno es una operación del control-plane, no un despliegue de aplicación

Una actualización de un Deployment ordinario falla "localmente": la aplicación se degrada, los usuarios de esa aplicación ven errores. Kyverno falla "globalmente". Considerá el modo de falla que define cada decisión de diseño de abajo:

```
Client → kube-apiserver → [Kyverno webhook: failurePolicy=Fail] → etcd
                                    │
                          admission controller Pods are Terminating
                                    │
                                    ▼
             webhook call times out → apiserver rejects the request
```

Si el admission controller tiene `failurePolicy: Fail` y **todas** sus réplicas están no disponibles durante una actualización continua (rolling upgrade), el API server no puede satisfacer el webhook y **rechaza cada escritura coincidente en todo el cluster** — incluyendo, potencialmente, los mismos Pods que Kyverno necesita para volver a levantarse. Esta es la forma canónica en que un administrador inutiliza (bricks) un cluster con un motor de policies. Toda la estrategia de actualización existe para asegurar que el backend del webhook nunca tenga cero endpoints saludables.

### 1.2 Las tres cosas que se mueven durante una actualización

| Parte móvil | Qué es | Falla si se maneja mal |
|---|---|---|
| **Controllers** | 4 Deployments independientes (desde v1.10) | La actualización continua reduce la capacidad de admisión |
| **CRDs** | Esquemas de policy/report/request — documentos OpenAPI v3 muy grandes | `kubectl apply` falla en el límite de 262 144 bytes de anotación; desajuste de versión almacenada |
| **Configs de Webhook** | Objetos `*WebhookConfiguration` reconciliados dinámicamente | Reglas obsoletas apuntan a puertos/rutas de servicio viejos; `failurePolicy` bloquea el cluster |

### 1.3 La arquitectura de controllers divididos (el hecho más importante de una actualización)

Antes de **v1.10**, Kyverno se distribuía como un único Deployment monolítico llamado `kyverno`. Desde **v1.10** está dividido en cuatro controllers escalables de forma independiente:

| Deployment | Responsabilidad | ¿En la ruta caliente de admisión? |
|---|---|---|
| `kyverno-admission-controller` | Sirve los webhooks de mutación/validación | **Sí** — debe ser HA |
| `kyverno-background-controller` | Reglas `generate`, `mutateExisting`, reconciliación en segundo plano | No |
| `kyverno-reports-controller` | Construye `PolicyReport`/`ClusterPolicyReport` | No |
| `kyverno-cleanup-controller` | Eliminación de recursos por TTL/`CleanupPolicy` | No (webhook propio para cleanup) |

**Consecuencia para las actualizaciones:** un salto de monolito→dividido (pre-1.10 → 1.10+) es un *renombrado y cambio de topología*, no un simple cambio de imagen. El viejo Deployment `kyverno` se elimina y aparecen cuatro nuevos. Solo el admission controller es crítico en latencia, así que **solo este necesita estrictamente 3 réplicas para una actualización sin tiempo de inactividad** — los otros toleran una breve indisponibilidad.

### 1.4 Version skew — Kyverno ↔ Kubernetes

Kyverno depende del comportamiento de la api-machinery (versiones de admission review, librerías CEL, semántica de server-side apply). Cada minor de Kyverno se prueba contra una ventana estrecha y **deslizante** de minors de Kubernetes. Ejecutar fuera de esa ventana no es soportado y rutinariamente se rompe por diferencias sutiles de admission-review o CEL. Confirmá el par *antes* de tocar nada (la Sección 6 cita la matriz autoritativa).

---

## 2. Comparaciones técnicas y compromisos

### 2.1 Método de entrega de la actualización

| Método | Idempotente | Actualizaciones de CRD | Rollback | Mejor para |
|---|---|---|---|---|
| **Helm** (`helm upgrade`) | Sí | Gestionado vía plantillas del chart (`crds.install`) | `helm rollback` (con salvedades de esquema) | Estándar de producción |
| **Manifiesto crudo** (`install.yaml`) | Con `--server-side` | Manual, debe usar SSA/`replace` | Reaplicar el manifiesto anterior | Air-gapped / sin Helm |
| **GitOps** (Argo CD / Flux) | Sí | Necesita `ServerSideApply=true` + `Replace=true` en las opciones de sync | Git revert + sync | Flotas, auditabilidad |

> El directorio nativo `crds/` de Helm es **solo de instalación** — Helm nunca actualiza los CRDs colocados ahí. Kyverno deliberadamente distribuye los CRDs como *plantillas* (controladas por `crds.install=true`) para que `helm upgrade` pueda evolucionar los esquemas. Por eso "simplemente `helm upgrade`" realmente funciona para los CRDs de Kyverno, a diferencia de la mayoría de los charts.

### 2.2 Cómo aplicar los CRDs — aquí es donde las actualizaciones fallan más a menudo

Los CRDs de Kyverno (por ejemplo `clusterpolicies.kyverno.io`) cargan esquemas OpenAPI enormes.

| Comando | Resultado en los CRDs de Kyverno | Veredicto |
|---|---|---|
| `kubectl apply -f install.yaml` | Escribe la anotación `last-applied-configuration` → **excede los 262 144 bytes** → `metadata.annotations: Too long` | ❌ Falla |
| `kubectl apply --server-side -f install.yaml` | Sin anotación del lado del cliente; merge por field-manager | ✅ Recomendado |
| `kubectl replace -f` | Funciona pero necesita que el objeto ya exista; pierde cambios concurrentes | ⚠️ Alternativa |
| `kubectl create -f` | Funciona solo para la primera instalación | ❌ No para actualizaciones |

### 2.3 Secuencial vs. saltar versiones

| Estrategia | Riesgo | Postura oficial |
|---|---|---|
| **Minors secuenciales** (1.11 → 1.12 → 1.13) | Bajo; cada guía de migración se aplica una vez | **Recomendado — no saltar minors** |
| **Saltar minors** (1.11 → 1.13) | Cambios disruptivos acumulados, versiones de CRD almacenadas sin migrar | No soportado |

Kyverno recomienda explícitamente actualizar **de a un minor a la vez** y leer las notas de migración de cada release. Las actualizaciones de patch (1.12.3 → 1.12.5) son seguras de saltar.

### 2.4 Rolling in-place vs. blue-green

| Enfoque | Tiempo de inactividad | Complejidad | Cuándo |
|---|---|---|---|
| **Rolling** (admission ctrl HA, `maxUnavailable: 0`) | Ninguno | Baja | Por defecto |
| **Blue-green** (segunda instalación, conmutar los webhooks) | Ninguno | Alta | Saltos de topología mayores / cambios aversos al riesgo |

### 2.5 Matriz de compatibilidad representativa

*Ilustrativa del patrón deslizante — confirmá siempre los valores en vivo en la documentación citada antes de actualizar:*

| Kyverno | Kubernetes (probado) |
|---|---|
| 1.10.x | 1.24 – 1.26 |
| 1.11.x | 1.25 – 1.28 |
| 1.12.x | 1.26 – 1.29 |
| 1.13.x | 1.28 – 1.31 |
| 1.14.x | 1.29 – 1.32 |

La regla que nunca cambia: **cada minor de Kyverno soporta aproximadamente tres minors consecutivos de Kubernetes, y la ventana se desliza hacia adelante en cada release.** La tabla de arriba es una ayuda para la memoria, no la fuente de verdad.

---

## 3. Manifiestos completos e infraestructura

### 3.1 `values.yaml` HA ajustado para actualizaciones sin tiempo de inactividad

El admission controller nunca debe alcanzar cero endpoints saludables durante el despliegue. Esto significa ≥3 réplicas, un `PodDisruptionBudget`, anti-afinidad entre nodos, y una estrategia `RollingUpdate` que agrega un Pod antes de quitar uno.

```yaml
# values-ha.yaml — pass to: helm upgrade ... -f values-ha.yaml
# Chart: kyverno/kyverno (v1.12+ key layout)

# Manage CRDs through templates so `helm upgrade` evolves the schemas.
crds:
  install: true

# ---- Admission controller: the only latency-critical component ----
admissionController:
  replicas: 3                       # HA: survive one Pod down during rollout
  podDisruptionBudget:
    minAvailable: 2                 # never let voluntary eviction drop below 2
  antiAffinity:
    enabled: true                   # spread replicas across nodes
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0             # add-before-remove — endpoints never hit 0
  container:
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { memory: 512Mi }
  readinessProbe:
    httpGet: { path: /health/readiness, port: 9443, scheme: HTTPS }
    initialDelaySeconds: 5
    periodSeconds: 10
  livenessProbe:
    httpGet: { path: /health/liveness, port: 9443, scheme: HTTPS }

# ---- Non-critical controllers: single replica is acceptable ----
backgroundController:
  replicas: 1
  resources:
    requests: { cpu: 100m, memory: 128Mi }

reportsController:
  replicas: 1
  resources:
    requests: { cpu: 100m, memory: 128Mi }

cleanupController:
  replicas: 1

# ---- Webhook safety: keep Kyverno out of its own blast radius ----
config:
  # Namespaces Kyverno's webhooks must never intercept — including its own,
  # so a broken admission controller cannot block its own recovery.
  webhooks:
    - namespaceSelector:
        matchExpressions:
          - key: kubernetes.io/metadata.name
            operator: NotIn
            values:
              - kyverno
              - kube-system
```

### 3.2 Un PodDisruptionBudget (forma explícita, si no se usa el valor del chart)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kyverno-admission-controller
  namespace: kyverno
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/component: admission-controller
      app.kubernetes.io/part-of: kyverno
```

### 3.3 El objeto webhook que debés entender (solo lectura — Kyverno lo reconcilia)

**No** editás esto a mano; el admission controller lo genera y reconcilia a partir de las policies instaladas. Pero debés poder leerlo durante una actualización, porque `failurePolicy`, `service.port` y `namespaceSelector` son exactamente lo que se rompe.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: kyverno-resource-validating-webhook-cfg
  labels:
    webhook.kyverno.io/managed-by: kyverno
webhooks:
  - name: validate.kyverno.svc-fail
    failurePolicy: Fail            # ← the cluster-blocking knob
    timeoutSeconds: 10
    matchPolicy: Equivalent
    sideEffects: NoneOnDryRun
    admissionReviewVersions: ["v1"]
    clientConfig:
      service:
        namespace: kyverno
        name: kyverno-svc
        path: /validate/fail
        port: 443                  # ← must match the upgraded Service
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kyverno", "kube-system"]
```

### 3.4 Opciones de sync de GitOps (Argo CD) que hacen funcionar las actualizaciones de CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
spec:
  project: platform
  source:
    repoURL: https://kyverno.github.io/kyverno/
    chart: kyverno
    targetRevision: 3.2.6          # Helm chart version (≠ Kyverno app version)
    helm:
      valueFiles: [values-ha.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    syncOptions:
      - ServerSideApply=true       # avoids the 262 144-byte annotation limit
      - Replace=false
      - CreateNamespace=true
```

---

## 4. Comandos CLI reales y salida de terminal

### 4.1 Establecer el estado actual (siempre tomá una instantánea antes de actualizar)

```console
$ kubectl -n kyverno get deploy -o wide
NAME                             READY   UP-TO-DATE   AVAILABLE   IMAGES
kyverno-admission-controller     3/3     3            3           reg.kyverno.io/kyverno/kyverno:v1.11.4
kyverno-background-controller    1/1     1            1           reg.kyverno.io/kyverno/background-controller:v1.11.4
kyverno-cleanup-controller       1/1     1            1           reg.kyverno.io/kyverno/cleanup-controller:v1.11.4
kyverno-reports-controller       1/1     1            1           reg.kyverno.io/kyverno/reports-controller:v1.11.4

$ kubectl get crd | grep kyverno.io
admissionreports.kyverno.io              2024-02-11T09:14:02Z
backgroundscanreports.kyverno.io         2024-02-11T09:14:02Z
cleanuppolicies.kyverno.io               2024-02-11T09:14:02Z
clustercleanuppolicies.kyverno.io        2024-02-11T09:14:02Z
clusterpolicies.kyverno.io               2024-02-11T09:14:02Z
policies.kyverno.io                      2024-02-11T09:14:02Z
policyexceptions.kyverno.io              2024-02-11T09:14:02Z
updaterequests.kyverno.io                2024-02-11T09:14:02Z
```

### 4.2 Respaldar policies y CRs antes de tocar los CRDs

```console
$ kubectl get clusterpolicies.kyverno.io,policies.kyverno.io -A -o yaml > kyverno-policies-backup.yaml
$ kubectl get crd -l app.kubernetes.io/part-of=kyverno -o yaml > kyverno-crds-backup.yaml
$ wc -l kyverno-policies-backup.yaml
   842 kyverno-policies-backup.yaml
```

### 4.3 Ruta con Helm (recomendada)

```console
$ helm repo add kyverno https://kyverno.github.io/kyverno/
"kyverno" has been added to your repositories

$ helm repo update
Hang tight while we grab the latest from your chart repositories...
Update Complete. ⎈Happy Helming!⎈

$ helm search repo kyverno/kyverno --versions | head -5
NAME             CHART VERSION   APP VERSION   DESCRIPTION
kyverno/kyverno  3.2.6           v1.12.6       Kubernetes Native Policy Management
kyverno/kyverno  3.2.5           v1.12.5       Kubernetes Native Policy Management
kyverno/kyverno  3.1.4           v1.11.4       Kubernetes Native Policy Management
```

> Notá los dos números de versión: **versión del chart** (`3.2.6`) ≠ **versión de la app/Kyverno** (`v1.12.6`). Siempre fijá la versión del chart explícitamente.

```console
$ helm upgrade kyverno kyverno/kyverno \
    --namespace kyverno \
    --version 3.2.6 \
    --values values-ha.yaml \
    --atomic --timeout 5m
Release "kyverno" has been upgraded. Happy Helming!
NAME: kyverno
LAST DEPLOYED: Thu Aug 13 10:22:41 2026
NAMESPACE: kyverno
STATUS: deployed
REVISION: 7
```

`--atomic` revierte la release automáticamente si la actualización no se vuelve saludable dentro de `--timeout`. Este es el flag más valioso para una actualización desatendida de Kyverno.

### 4.4 Observar la actualización continua (los endpoints deben permanecer ≥1 todo el tiempo)

```console
$ kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=300s
Waiting for deployment "kyverno-admission-controller" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "kyverno-admission-controller" rollout to finish: 2 of 3 updated replicas are available...
deployment "kyverno-admission-controller" successfully rolled out

# In a second terminal — prove the webhook backend never emptied:
$ kubectl -n kyverno get endpoints kyverno-svc -w
NAME          ENDPOINTS                                         AGE
kyverno-svc   10.244.1.7:9443,10.244.2.9:9443,10.244.3.4:9443   41d
kyverno-svc   10.244.1.7:9443,10.244.2.9:9443                   41d   # 3→2, never 0
kyverno-svc   10.244.1.7:9443,10.244.2.9:9443,10.244.4.6:9443   41d   # new Pod added
```

### 4.5 Ruta con manifiesto crudo (air-gapped / sin Helm) — notá `--server-side`

```console
$ kubectl apply --server-side --force-conflicts \
    -f https://github.com/kyverno/kyverno/releases/download/v1.12.6/install.yaml
customresourcedefinition.apiextensions.k8s.io/clusterpolicies.kyverno.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/policies.kyverno.io serverside-applied
...
deployment.apps/kyverno-admission-controller serverside-applied
deployment.apps/kyverno-background-controller serverside-applied
```

Contrastá con la falla que produce el apply del lado del cliente (el error a reconocer en el examen y en producción):

```console
$ kubectl apply -f install.yaml
The CustomResourceDefinition "clusterpolicies.kyverno.io" is invalid:
metadata.annotations: Too long: must have at most 262144 bytes
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Lista de verificación posterior a la actualización

```console
# 1) Every controller reports the new image and is Available
$ kubectl -n kyverno get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
kyverno-admission-controller    reg.kyverno.io/kyverno/kyverno:v1.12.6
kyverno-background-controller   reg.kyverno.io/kyverno/background-controller:v1.12.6
kyverno-cleanup-controller      reg.kyverno.io/kyverno/cleanup-controller:v1.12.6
kyverno-reports-controller      reg.kyverno.io/kyverno/reports-controller:v1.12.6

# 2) Webhooks are healthy and point at the right service/port
$ kubectl get validatingwebhookconfigurations -l webhook.kyverno.io/managed-by=kyverno
NAME                                        WEBHOOKS   AGE
kyverno-resource-validating-webhook-cfg     1          41d
kyverno-policy-validating-webhook-cfg       1          41d

# 3) Existing policies still Ready (CRD schema migration didn't break them)
$ kubectl get cpol
NAME                    ADMISSION   BACKGROUND   READY   AGE
require-run-as-nonroot  true        true         True    41d
disallow-latest-tag     true        true         True    41d

# 4) A live smoke test — an offending Pod is actually rejected
$ kubectl run bad --image=nginx:latest --dry-run=server
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
policy disallow-latest-tag/... : validation error: Using a mutable image tag is not allowed.
```

Si el paso 4 es *silenciosamente permitido*, el webhook no está interceptando — el admission controller está levantado pero la config del webhook está obsoleta o no fue reconciliada.

### 5.2 Catálogo de fallas

| Síntoma | Causa raíz | Solución |
|---|---|---|
| `metadata.annotations: Too long: 262144 bytes` | `kubectl apply` del lado del cliente sobre CRDs gigantes | Reejecutar con `--server-side --force-conflicts` |
| Todo el cluster rechaza escrituras durante la actualización | `failurePolicy: Fail` + todos los Pods de admisión caídos | Asegurar 3 réplicas, `maxUnavailable: 0`, PDB `minAvailable: 2`; emergencia: eliminar el `*WebhookConfiguration` para desbloquear, luego dejar que Kyverno lo recree |
| `no matches for kind "Policy" in version "kyverno.io/v1"` | CRD no actualizado antes que los controllers | Aplicar los CRDs primero, luego los controllers |
| El viejo Deployment `kyverno` persiste tras una actualización pre-1.10 | Renombrado monolito→dividido incompleto | `kubectl -n kyverno delete deploy kyverno` tras confirmar que los 4 nuevos están Ready |
| Las policies muestran `READY: False` | Campo obsoleto (por ejemplo `validationFailureAction: enforce` en minúscula) | Migrar a PascalCase `Enforce`/`Audit`; reaplicar |
| Los reports dejan de actualizarse | Reports controller en crash-loop sobre el nuevo CRD | Revisar sus logs; verificar que los CRDs `reports.kyverno.io`/`wgpolicyk8s.io` fueron actualizados |
| `helm upgrade` deja CRDs eliminados atrás | Helm nunca elimina CRDs | `kubectl delete crd` manualmente solo tras confirmar que no queda ningún CR de ese kind |

### 5.3 Comandos de diagnóstico

```console
# Which API versions are actually stored for a CRD (migration health):
$ kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.status.storedVersions}'
["v1"]

# Confirm served/deprecated versions after upgrade:
$ kubectl get crd clusterpolicies.kyverno.io \
    -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
v1 served=true storage=true
v2beta1 served=true storage=false

# Admission controller readiness and recent errors:
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20 | grep -iE 'error|webhook|ready'

# Prove the webhook is reachable from the apiserver's perspective:
$ kubectl -n kyverno get endpoints kyverno-svc
NAME          ENDPOINTS                                         AGE
kyverno-svc   10.244.1.7:9443,10.244.2.9:9443,10.244.4.6:9443   41d
```

### 5.4 Rollback

```console
$ helm history kyverno -n kyverno
REVISION  UPDATED                   STATUS      CHART           APP VERSION
6         Wed Aug 12 18:03:11 2026  superseded  kyverno-3.1.4   v1.11.4
7         Thu Aug 13 10:22:41 2026  deployed    kyverno-3.2.6   v1.12.6

$ helm rollback kyverno 6 -n kyverno --wait
Rollback was a success! Happy Helming!
```

**Salvedad — el rollback de esquema no es gratis.** `helm rollback` revierte las imágenes de los controllers y las plantillas de webhook, pero un **esquema de CRD no se degrada automáticamente**, y cualquier CR ya escrito en una versión almacenada más nueva puede fallar la validación contra el esquema más viejo. Blue-green (Sección 2.4) es la ruta segura cuando una migración cambia las versiones de almacenamiento del CRD.

### 5.5 Reglas de oro

1. **Confirmá el par Kyverno↔Kubernetes** contra la matriz de compatibilidad en vivo primero.
2. **Nunca saltes una versión minor.** Leé cada guía de migración intermedia.
3. **Actualizá los CRDs antes que los controllers**, siempre con `--server-side`.
4. **Mantené el admission controller HA** (3 réplicas, `maxUnavailable: 0`, PDB) para que el backend del webhook nunca esté vacío.
5. **Tomá una instantánea** de policies + CRDs, y usá `--atomic` para que una mala actualización se revierta sola.
6. **Hacé una prueba de humo (smoke-test)** con un recurso que se sabe que ofende — "los Pods están corriendo" no es prueba de que los webhooks funcionan.

---

## 6. Referencias

- Kyverno — Métodos de instalación y actualización (Helm, manifiestos, CRDs): https://kyverno.io/docs/installation/
- Kyverno — Instalación de alta disponibilidad (conteos de réplicas, failure policy de webhook): https://kyverno.io/docs/installation/methods/#high-availability
- Kyverno — Matriz de compatibilidad Kubernetes / Kyverno (autoritativa): https://kyverno.io/docs/installation/#compatibility-matrix
- Kyverno — Actualización de Kyverno (actualizaciones secuenciales, manejo de CRD): https://kyverno.io/docs/installation/upgrading/
- Código fuente del Helm chart de Kyverno (plantillado de CRD, `crds.install`, values): https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Kyverno GitHub Releases (`install.yaml` por versión, notas de migración): https://github.com/kyverno/kyverno/releases
- Kyverno — Comportamiento de Webhooks y failurePolicy: https://kyverno.io/docs/introduction/admission-controllers/
- Kubernetes — Server-Side Apply (por qué los CRDs grandes necesitan `--server-side`): https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — Versionado de CustomResourceDefinitions (`storedVersions`, migración): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- CNCF — Currículo KCA (Kyverno Certified Associate): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf