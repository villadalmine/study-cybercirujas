# 5.10 Cleanup Policies

> **Dominio de examen 5 — Applying Kyverno · Peso: 2.91**
> Kyverno Certified Associate (KCA). Este tema cubre el subsistema de *borrado declarativo* de Kyverno: `CleanupPolicy`, `ClusterCleanupPolicy` y el mecanismo TTL basado en el label `cleanup.kyverno.io/ttl`. Todo lo que sigue asume Kyverno ≥ 1.11 con la división en cuatro controllers (admission / background / reports / **cleanup**).

---

## 1. Motivación y el problema de producción

Todo cluster de Kubernetes tiene fugas. No de memoria — de *objetos*. El API server es un datastore de propósito general, y no hay un garbage collector integrado para la gran mayoría de los tipos de recursos. Kubernetes trae exactamente tres primitivas de limpieza acotadas:

- **GC en cascada por owner-reference** — borra los hijos cuando se elimina un padre (el grafo `metadata.ownerReferences` que recorre el garbage collector de `kube-controller-manager`).
- **`ttlSecondsAfterFinished`** — borra objetos `Job` un tiempo fijo después de completarse (el controller TTL-after-finished).
- **Límites de historial de CronJob** — `successfulJobsHistoryLimit` / `failedJobsHistoryLimit`.

Todo lo que quede fuera de esos tres vive para siempre a menos que un humano o un operador lo borre. En producción esto se manifiesta como:

- **Pods bare huérfanos** dejados atrás por un `kubectl run` imperativo, operadores que fallaron, o workloads desalojados que quedaron en `Failed`/`Succeeded`.
- **ConfigMaps/Secrets obsoletos** de releases de Helm, rotación de certificados, o pipelines de CI que crean objetos por build.
- **Namespaces efímeros expirados** de entornos de PR-preview y sandboxes de tenants de vida corta.
- **PVCs, Ingresses y NetworkPolicies abandonados** cuyo workload propietario se eliminó pero que no tenían owner reference.
- **Hinchazón de etcd y presión sobre la watch-cache**: cada objeto que persiste consume espacio en etcd, infla las respuestas `LIST`, ralentiza los resyncs de los informers, y aumenta el blast radius de un `kubectl get` sobre todo el cluster. Un cluster con 200k objetos muertos tiene una latencia del control-plane más lenta de forma medible.

El problema arquitectónico es que la lógica de limpieza es **política transversal (cross-cutting)**, no lógica de workload. Codificar «borrar cualquier Pod que lleve `Succeeded` más de una hora» dentro del Helm chart de cada equipo es inaplicable y no auditable. La respuesta de Kyverno es mover el borrado al mismo plano de políticas declarativo y con alcance de cluster que ya gobierna `validate`/`mutate`/`generate` — con los mismos selectores `match`/`exclude`, el mismo contexto JMESPath, ejecución restringida por RBAC, eventos, métricas, y un rastro de auditoría adyacente a `PolicyReport`.

Existen dos mecanismos complementarios:

| Mecanismo | Kind / disparador | Quién decide *qué* borrar | Quién decide *cuándo* |
|---|---|---|---|
| **Cleanup Policy** | `CleanupPolicy` (con namespace), `ClusterCleanupPolicy` (cluster) | El equipo de plataforma, vía `match`/`exclude`/`conditions` | Un `schedule` cron en la política |
| **Label TTL** | label `cleanup.kyverno.io/ttl` en cualquier recurso | El autor del recurso (autogestión) | Un tiempo absoluto o una duración en el valor del label |

Las Cleanup Policies son **gobernanza centralizada** («la plataforma recolecta»); el label TTL es **autogestión descentralizada** («el dueño fija su propia expiración»). Ambos son ejecutados por el mismo **cleanup controller** y ambos están restringidos por RBAC mediante el mismo ClusterRole agregado.

---

## 2. Arquitectura y mecánica interna

### 2.1 El cleanup controller

Desde la división de controllers de la 1.10, el cleanup corre en un `Deployment` dedicado — `kyverno-cleanup-controller` — separado del webhook de admission. Este aislamiento importa operativamente: un bug de cleanup no puede frenar la admission, y los dos escalan de forma independiente. El cleanup controller hace tres tareas:

1. Sirve un **webhook de admission validating** para los propios objetos `CleanupPolicy`/`ClusterCleanupPolicy` (rechaza expresiones cron inválidas, conditions malformadas, etc.).
2. Corre el **reconciliador de TTL** que observa (watch) los recursos que llevan `cleanup.kyverno.io/ttl`.
3. Sirve un **endpoint `/cleanup`** HTTPS autenticado que realiza el match + evaluación de conditions + borrado reales para las políticas programadas.

### 2.2 La descarga vía CronJob — el detalle que casi todos pasan por alto

Kyverno **no** ejecuta un scheduler en proceso para las cleanup policies. En cambio, por cada `CleanupPolicy`/`ClusterCleanupPolicy`, el cleanup controller **genera un `CronJob` de Kubernetes** en el namespace de Kyverno, propiedad de la política. Cuando ese CronJob se dispara, su Job Pod hace una llamada `wget`/`curl` autenticada de vuelta al endpoint `/cleanup` del cleanup controller (sobre TLS, usando el CA montado), y el controller entonces evalúa `match`/`exclude`/`conditions` contra el estado vivo del cluster y emite las llamadas `DELETE`.

```
┌────────────────┐  reconciles   ┌──────────────────────────┐
│ ClusterCleanup │──────────────▶│  generated CronJob        │
│ Policy (cron)  │  owns         │  (kyverno namespace)      │
└────────────────┘               └───────────┬──────────────┘
                                     fires    │  HTTPS + CA
                                              ▼
                                 ┌──────────────────────────┐
                                 │ kyverno-cleanup-controller│
                                 │  /cleanup endpoint         │
                                 │  match/exclude/conditions  │
                                 │  → DELETE via K8s API      │
                                 └──────────────────────────┘
```

Consecuencias para los SREs:
- La **resolución mínima es de un minuto** — heredás la semántica de los CronJob de Kubernetes, así que los schedules por debajo del minuto son imposibles.
- Borrar una Cleanup Policy **hace garbage-collect de su CronJob** vía owner reference.
- Si el Service del cleanup controller es inalcanzable desde el Job Pod (una `NetworkPolicy` que bloquea el egress, por ejemplo), los Job Pods del CronJob fallan y *no se limpia nada* — y sin embargo la política sigue mostrándose sana. Diagnosticá en la capa del CronJob/Job, no solo en la política.

### 2.3 La variable de candidato: `target`

Dentro de `conditions`, el recurso que se está evaluando en ese momento se expone como **`{{ target }}`**. Escribís JMESPath sobre `target.metadata`, `target.spec`, `target.status`, etc. Esta es la diferencia clave respecto de las reglas validate (que exponen `request.object`): el cleanup es un *reconcile* sobre objetos existentes, así que no hay admission request — solo un `target`.

---

## 3. Análisis comparativo y trade-offs

### 3.1 El cleanup de Kyverno vs. las primitivas nativas de Kubernetes

| Capacidad | `CleanupPolicy` | Label TTL | `ttlSecondsAfterFinished` | Límites de historial de CronJob | GC por owner-ref |
|---|---|---|---|---|---|
| Aplica a kinds arbitrarios | ✅ cualquier GVK que Kyverno pueda borrar | ✅ cualquier objeto con label | ❌ solo Jobs | ❌ Jobs de un CronJob | ✅ pero solo vía propiedad |
| Basado en conditions (campos status/spec) | ✅ JMESPath/CEL sobre `target` | ❌ solo tiempo | ❌ | ❌ | ❌ |
| Gobernanza central (autor ≠ dueño) | ✅ | ❌ lo fija el dueño | ❌ | ❌ | ❌ |
| Autogestión por objeto | vía selectores `match` | ✅ | ✅ | ✅ | ✅ |
| Granularidad temporal | ≥ 1 min (cron) | absoluta o duración | segundos | basada en conteo | orientada a eventos |
| Requiere permisos RBAC extra | ✅ (rol agregado) | ✅ (el mismo) | ❌ | ❌ | ❌ |
| Rastro de auditoría / eventos / métricas | ✅ | ✅ | limitado | limitado | limitado |
| Control de propagación del borrado | ✅ `deletionPropagationPolicy` | ❌ | ❌ | ❌ | Foreground/Background/Orphan al borrar |

### 3.2 El cleanup de Kyverno vs. "janitors" externos

| | Kyverno Cleanup | `kube-janitor` / `k8s-ttl-controller` | GitOps prune (Argo CD / Flux) |
|---|---|---|---|
| Modelo de políticas | El mismo motor que validate/mutate/generate | Motor de anotaciones/reglas independiente | Reconciliación de estado deseado |
| Borra el drift *no gestionado* | ✅ | ✅ | ❌ solo poda lo que Git declaró alguna vez |
| Expresividad de conditions | JMESPath + CEL, llamadas a la API con `context` | reglas al estilo JMESPath | n/a |
| Plano único de políticas | ✅ un operador, un modelo de RBAC | ➕ otro operador que mantener | preocupación aparte |
| Mejor para | Gobernanza + recolección ad-hoc en toda la flota | Entornos ligeros de solo TTL | Reconciliar recursos propiedad de Git |

**Regla general:** usá **owner references** para los ciclos de vida padre/hijo (gratis, orientado a eventos, sin RBAC); usá el **label TTL** para la expiración autogestionada de objetos individuales; usá **Cleanup Policies** cuando la plataforma deba imponer la recolección basada en *conditions* (status, antigüedad, ausencia de propietario) sobre recursos que no le pertenecen; usá **GitOps prune** solo para objetos que Git declaró.

### 3.3 Trade-offs de `deletionPropagationPolicy`

| Valor | Comportamiento | Usar cuando |
|---|---|---|
| `Foreground` | Borra los dependientes *antes* de que el owner retorne; el owner se bloquea hasta que los hijos desaparecen | Necesitás garantía de que la cascada se completó (p. ej., borrar un Deployment y confirmar que sus Pods desaparecieron) |
| `Background` (default de K8s) | Borra el owner de inmediato, el GC recolecta los hijos de forma asíncrona | Importa el throughput; la consistencia eventual es aceptable |
| `Orphan` | Borra solo el owner, deja los hijos | Flujos de re-parenting / adopción; desvinculación deliberada |

Si no se define, aplica el default del API server (`Background` para la mayoría de los kinds).

---

## 4. Manifiestos completos y sintácticamente válidos

### 4.1 RBAC — el prerrequisito que todos olvidan

El cleanup controller de Kyverno viene, por defecto, **sin permiso de delete** sobre tus kinds de workload. Lo extendés creando un `ClusterRole` que lleve el label de agregación `rbac.kyverno.io/aggregate-to-cleanup-controller: "true"`. El rol `kyverno:cleanup-controller` de Kyverno tiene un `aggregationRule` que los incorpora automáticamente — no hace falta re-vincular (rebind).

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:cleanup-controller:extra
  labels:
    app.kubernetes.io/part-of: kyverno
    # This label is what makes the rules take effect for cleanup:
    rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
rules:
  - apiGroups: [""]
    resources: ["pods", "configmaps"]
    verbs: ["get", "list", "watch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "delete"]
```

> `get`, `list` y `watch` son necesarios para que el controller pueda *encontrar* candidatos; `delete` es necesario para recolectarlos. Omití `list`/`watch` y el controller no encuentra nada, en silencio.

### 4.2 `ClusterCleanupPolicy` — recolectar Pods huérfanos (bare)

Borra los Pods **sin** owner references (es decir, no gestionados por un ReplicaSet/Job/etc.) que están en una fase terminal, cada 10 minutos.

```yaml
apiVersion: kyverno.io/v2beta1
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-bare-terminal-pods
spec:
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
  conditions:
    all:
      # No controller owns this Pod → it is "bare"
      - key: "{{ target.metadata.ownerReferences[] || `[]` | length(@) }}"
        operator: Equals
        value: 0
      # …and it has finished (Succeeded or Failed)
      - key: "{{ target.status.phase }}"
        operator: AnyIn
        value:
          - Succeeded
          - Failed
  deletionPropagationPolicy: Foreground
  schedule: "*/10 * * * *"
```

### 4.3 `ClusterCleanupPolicy` — Deployments escalados a cero marcados para eliminación

```yaml
apiVersion: kyverno.io/v2beta1
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-empty-flagged-deployments
spec:
  match:
    any:
      - resources:
          kinds:
            - Deployment
          selector:
            matchLabels:
              canremove: "true"
  conditions:
    any:
      - key: "{{ target.spec.replicas }}"
        operator: Equals
        value: 0
  schedule: "*/15 * * * *"
```

### 4.4 `CleanupPolicy` con namespace — recolectar Jobs Completed de más de 24 h en un tenant

`CleanupPolicy` tiene namespace; su `match` está implícitamente acotado a `metadata.namespace`. Esto usa `time_since` para calcular la antigüedad respecto de `.status.completionTime`.

```yaml
apiVersion: kyverno.io/v2beta1
kind: CleanupPolicy
metadata:
  name: cleanup-old-completed-jobs
  namespace: team-ci
spec:
  match:
    any:
      - resources:
          kinds:
            - Job
  conditions:
    all:
      - key: "{{ target.status.succeeded || `0` }}"
        operator: GreaterThanOrEquals
        value: 1
      # Age since completion exceeds 24h → time_since returns "HH:MM:SS",
      # compare the total hours crossing the day boundary.
      - key: "{{ time_since('', '{{ target.status.completionTime }}', '') }}"
        operator: GreaterThan
        value: "24:00:00"
  schedule: "0 * * * *"
```

### 4.5 Label TTL — expiración por objeto autogestionada

No se requiere ningún objeto de política más allá del permiso de RBAC de 4.1. El autor del recurso estampa un label; el reconciliador de TTL lo borra cuando el reloj del label expira. Tres formas de valor aceptadas:

```yaml
# a) Relative duration (Go-style): delete 2 hours after the label is observed
apiVersion: v1
kind: Pod
metadata:
  name: debug-shell
  labels:
    cleanup.kyverno.io/ttl: 2h
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "infinity"]
---
# b) Absolute RFC3339 timestamp: delete at a wall-clock instant
apiVersion: v1
kind: ConfigMap
metadata:
  name: pr-1234-preview-config
  labels:
    cleanup.kyverno.io/ttl: "2026-08-20T00:00:00Z"
data:
  env: preview
---
# c) Date-only: delete at 00:00 UTC on that date
apiVersion: v1
kind: Secret
metadata:
  name: temp-signing-key
  labels:
    cleanup.kyverno.io/ttl: "2026-08-31"
type: Opaque
stringData:
  key: rotate-me
```

Forzá el label en la admission con una política mutate/validate acompañante, para que los namespaces efímeros siempre lleven una expiración — cerrando el ciclo entre la gobernanza de admission y el cleanup.

---

## 5. Recorrido por la CLI con salida de terminal real

### 5.1 Confirmar que el cleanup controller está corriendo

```console
$ kubectl -n kyverno get deploy
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    1/1     1            1           9d
kyverno-background-controller   1/1     1            1           9d
kyverno-cleanup-controller      1/1     1            1           9d
kyverno-reports-controller      1/1     1            1           9d
```

### 5.2 Aplicar e inspeccionar una política

```console
$ kubectl apply -f cleanup-bare-terminal-pods.yaml
clustercleanuppolicy.kyverno.io/cleanup-bare-terminal-pods created

$ kubectl get clustercleanuppolicy
NAME                          SCHEDULE       AGE
cleanup-bare-terminal-pods    */10 * * * *   12s

$ kubectl describe clustercleanuppolicy cleanup-bare-terminal-pods | sed -n '1,25p'
Name:         cleanup-bare-terminal-pods
Kind:         ClusterCleanupPolicy
API Version:  kyverno.io/v2beta1
Spec:
  Deletion Propagation Policy:  Foreground
  Schedule:                     */10 * * * *
Status:
  Conditions:
    Message:               Ready
    Reason:                Succeeded
    Status:                True
    Type:                  Ready
  Last Execution Time:     2026-08-13T18:20:00Z
Events:
  Type    Reason         Age    From             Message
  ----    ------         ----   ----             -------
  Normal  PolicyApplied  8m     kyverno-cleanup  successfully deleted the target resources
```

### 5.3 Observar el CronJob autogenerado (la descarga hecha visible)

```console
$ kubectl -n kyverno get cronjob
NAME                                 SCHEDULE       SUSPEND   ACTIVE   LAST SCHEDULE   AGE
cleanup-bare-terminal-pods-3f2a9c1   */10 * * * *   False     0        3m12s           41m

$ kubectl -n kyverno get cronjob cleanup-bare-terminal-pods-3f2a9c1 \
    -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
ClusterCleanupPolicy/cleanup-bare-terminal-pods
```

### 5.4 Demostrar que la recolección ocurrió de extremo a extremo

```console
$ kubectl run orphan --image=busybox:1.36 --restart=Never --command -- /bin/false
pod/orphan created

$ kubectl get pod orphan
NAME     READY   STATUS   RESTARTS   AGE
orphan   0/1     Error    0          6s          # phase=Failed, zero ownerReferences

# …wait for the next */10 tick…
$ kubectl get pod orphan
Error from server (NotFound): pods "orphan" not found

$ kubectl -n kyverno logs deploy/kyverno-cleanup-controller | grep -i deleted | tail -1
"cleaned up target resource" logger=cleanup policy=cleanup-bare-terminal-pods kind=Pod name=orphan namespace=default
```

### 5.5 El label TTL en acción

```console
$ kubectl apply -f debug-shell.yaml
pod/debug-shell created

$ kubectl get pod debug-shell --show-labels
NAME          READY   STATUS    RESTARTS   AGE   LABELS
debug-shell   1/1     Running   0          5s    cleanup.kyverno.io/ttl=2h

# 2 hours later:
$ kubectl get pod debug-shell
Error from server (NotFound): pods "debug-shell" not found
```

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Escalera de verificación (de la más barata a la más cara)

1. **¿Se aceptó la política?** — `kubectl get clustercleanuppolicy` la devuelve; el webhook validating rechaza cron/conditions inválidos al momento de aplicar.
2. **¿Está Ready?** — `status.conditions[type=Ready].status == True`.
3. **¿Se materializó el schedule?** — existe un `CronJob` correspondiente en el namespace `kyverno`, propiedad de la política.
4. **¿Los Jobs corren y tienen éxito?** — `kubectl -n kyverno get jobs` muestra `COMPLETIONS 1/1`, no `0/1` con backoff.
5. **¿Los objetos realmente desaparecieron?** — la prueba definitiva: el target queda `NotFound` después de un tick.
6. **Rastro de auditoría** — eventos `PolicyApplied` en la política y `"cleaned up target resource"` en el log del controller.

### 6.2 Catálogo de fallos

| Síntoma | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|
| Nunca se borra nada; sin errores | **Falta RBAC** — el controller puede `list` pero no `delete` (o ni siquiera puede `list`) | `kubectl -n kyverno logs deploy/kyverno-cleanup-controller \| grep -i forbidden` muestra `pods is forbidden ... cannot delete` | Agregá el kind a un ClusterRole agregado (§4.1) con `get,list,watch,delete` |
| Política `Ready`, el CronJob existe, pero los Job Pods dan `Error` | El Job Pod no puede alcanzar el Service del cleanup controller (egress de NetworkPolicy, DNS, TLS) | `kubectl -n kyverno logs job/<generated-job>` → connection refused / timeout | Permití el egress desde el namespace `kyverno` hacia el Service del cleanup controller; verificá el montaje del CA |
| Se saltean algunos targets | **Desajuste de condition/JMESPath** — `target.status.phase` vacío, comparación de tipo equivocada, ownerReferences null | Probá la expresión en dry-run: `kubectl get pod x -o json \| jq '<expr>'`; ojo con `Equals 0` (número) vs `"0"` (string) | Protegé con `|| \`[]\``, usá el operador correcto (`AnyIn`, `GreaterThan`), hacé coincidir el tipo del valor |
| El objeto se niega a borrarse | Un **finalizer** en el target lo mantiene en `Terminating` | `kubectl get <obj> -o jsonpath='{.metadata.finalizers}'` | Resolvé el controller del finalizer; Kyverno emite `DELETE`, no fuerza la eliminación de finalizers |
| Política rechazada al aplicar | Cron inválido o condition malformada | `kubectl apply` devuelve textualmente el error del webhook validating de cleanup | Corregí el `schedule` (cron de 5 campos, ≥ 1 min) o el esquema de la condition |
| Borra de más | `match` demasiado amplio / falta `exclude` | Probá los selectores contra el estado vivo antes de habilitar; empezá con un `selector.matchLabels` acotado | Agregá `exclude` para `kube-system`, `kyverno` y los namespaces protegidos; controlá con un label canary |
| Label TTL ignorado | El mismo hueco de RBAC, o valor malformado | Log del controller: `invalid cleanup value`/`forbidden`; verificá que el label parsee como duración/RFC3339/fecha | Corregí el formato del valor; otorgá delete sobre ese kind |

### 6.3 Observabilidad

- **Eventos:** `kubectl get events -A --field-selector reason=PolicyApplied` (recolecciones exitosas) y `reason=PolicyError` (fallos).
- **Logs:** `kubectl -n kyverno logs deploy/kyverno-cleanup-controller -f` — cada delete y cada `forbidden`.
- **Métricas:** el cleanup controller expone métricas de Prometheus (p. ej. un contador como `kyverno_cleanup_controller_deletedobjects_total`, etiquetado por política y kind de recurso). Alertá sobre la tasa de delete — un pico repentino suele ser un `match` mal acotado; una línea plana en una política que debería estar activa suele indicar los fallos de NetworkPolicy/RBAC de arriba, que son *silenciosos* en la capa de la política.

### 6.4 Checklist de despliegue seguro

1. Otorgá el RBAC (§4.1) **antes** que la política — de lo contrario los primeros ticks fallan en silencio.
2. Empezá acotado: `selector.matchLabels: { canremove: "true" }` más un `exclude` para los namespaces de sistema.
3. Poné primero un schedule **largo** (`0 * * * *`), verificá las recolecciones en el log, y después ajustá.
4. Ampliá el `match` solo después de confirmar cero borrados colaterales durante un ciclo completo.
5. Nunca dejes que una cleanup policy haga match con `kube-system` ni con el propio `kyverno`.

---

## Referencias

- Kyverno — *Cleanup Policies* (escritura de políticas): https://kyverno.io/docs/writing-policies/cleanup/
- Kyverno — *TTL-based cleanup* (label `cleanup.kyverno.io/ttl`): https://kyverno.io/docs/writing-policies/cleanup/#cleanup-label
- Kyverno — *ClusterCleanupPolicy / CleanupPolicy* referencia de la API: https://kyverno.io/docs/kyverno-policies/ y https://htmlpreview.github.io/?https://github.com/kyverno/kyverno/blob/main/docs/user/crd/index.html
- Kyverno — *Controllers* (división admission / background / reports / cleanup): https://kyverno.io/docs/high-availability/
- Kyverno — *Customizing Permissions* (ClusterRoles agregados, `rbac.kyverno.io/aggregate-to-cleanup-controller`): https://kyverno.io/docs/installation/customization/#roles-and-permissions
- Kyverno — *JMESPath* y filtros de tiempo (`time_since`, `time_now`): https://kyverno.io/docs/writing-policies/jmespath/
- Kubernetes — *Garbage Collection* (owner references, políticas de propagación): https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubernetes — *Automatic cleanup of finished Jobs* (`ttlSecondsAfterFinished`): https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/
- CNCF — *Kyverno Certified Associate (KCA) Curriculum*: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf